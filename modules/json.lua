-- modules/json.lua - bounded JSON decoder for SnowDesktop widget sandboxes.
--
-- The widget VM exposes string/table/math/utf8 but no JSON library, so packages
-- that read an HTTP API must carry their own decoder. The extra feature here is
-- `skip`: object keys whose values are dropped without being materialised.
-- TickTick's full-sync response is mostly note bodies, subtasks and ordering
-- metadata the board never draws, so skipping is what keeps the parse inside
-- the VM's per-callback quota.
--
-- Hot paths compare bytes instead of slicing characters, because the sandbox
-- charges for allocation and a snapshot skip would otherwise create tens of
-- thousands of one-character strings.

local json = {}

-- The sandbox has no setmetatable, so JSON null is a plain unique table.
local null = {}
json.null = null

local MAX_DEPTH = 64
local MAX_BYTES = 8 * 1024 * 1024

local find = string.find
local byte = string.byte
local sub = string.sub
local concat = table.concat

local QUOTE = 34
local BACKSLASH = 92
local COMMA = 44
local COLON = 58
local OPEN_OBJECT = 123
local CLOSE_OBJECT = 125
local OPEN_ARRAY = 91
local CLOSE_ARRAY = 93

-- Byte-level whitespace skip. A pattern call here would be one host-bridge
-- round trip per key; the VM quota is counted in those, and a big project
-- response has thousands of keys.
local function skipSpace(text, index)
    local length = #text
    while index <= length do
        local char = byte(text, index)
        if char == 32 or char == 9 or char == 13 or char == 10 then
            index = index + 1
        else
            break
        end
    end
    return index
end

-- Byte index of the closing quote, or nil when the string never ends. Escaped
-- quotes are skipped two bytes at a time, which keeps this linear and lets the
-- pattern matcher do the scanning. The second result says whether the string
-- holds any escape at all, so callers can skip the unescape pass entirely.
local function stringEnd(text, index)
    local cursor = index + 1
    local escaped = false
    while true do
        local hit = find(text, '["\\]', cursor)
        if not hit then return nil, escaped end
        if byte(text, hit) == BACKSLASH then
            escaped = true
            cursor = hit + 2
        else
            return hit, escaped
        end
    end
end

local escapes = {
    ['"'] = '"',
    ["\\"] = "\\",
    ["/"] = "/",
    b = "\b",
    f = "\f",
    n = "\n",
    r = "\r",
    t = "\t",
}

local function hexCode(text, index)
    local digits = sub(text, index + 1, index + 4)
    if #digits < 4 or find(digits, "[^%x]") then return nil end
    return tonumber(digits, 16)
end

local function decodeString(text, index)
    local stop, escaped = stringEnd(text, index)
    if not stop then return nil, index, "unterminatedString" end
    local raw = sub(text, index + 1, stop - 1)
    if not escaped then
        return raw, stop + 1
    end

    local parts = {}
    local count = 0
    local cursor, limit = 1, #raw
    while cursor <= limit do
        local hit = find(raw, "\\", cursor, true)
        if not hit then
            count = count + 1
            parts[count] = sub(raw, cursor)
            break
        end
        if hit > cursor then
            count = count + 1
            parts[count] = sub(raw, cursor, hit - 1)
        end

        local escape = sub(raw, hit + 1, hit + 1)
        if escapes[escape] then
            count = count + 1
            parts[count] = escapes[escape]
            cursor = hit + 2
        elseif escape == "u" then
            local code = hexCode(raw, hit + 1)
            if not code then return nil, index, "invalidUnicodeEscape" end
            cursor = hit + 6
            if code >= 0xD800 and code <= 0xDBFF and sub(raw, cursor, cursor + 1) == "\\u" then
                local low = hexCode(raw, cursor + 1)
                if low and low >= 0xDC00 and low <= 0xDFFF then
                    code = 0x10000 + (code - 0xD800) * 0x400 + (low - 0xDC00)
                    cursor = cursor + 6
                end
            end
            count = count + 1
            if code <= 0x10FFFF and not (code >= 0xD800 and code <= 0xDFFF) then
                parts[count] = utf8.char(code)
            else
                parts[count] = "\239\191\189"
            end
        else
            return nil, index, "invalidEscape"
        end
    end
    return concat(parts, "", 1, count), stop + 1
end

-- Advance past one value without building it.
--
-- The fast path counts brackets only and never looks inside strings, which is
-- roughly ten times cheaper than a string-aware scan and is what makes a
-- snapshot affordable. It can be fooled by a bracket inside a string, so its
-- result is validated (matching closer, delimiter or end of document after it)
-- and `json.decode` falls back to the string-aware pass when the whole
-- document fails to parse.
local brackets = "[%[%]{}]"
local stringTokens = '["%[%]{}]'
local delimiter = "[,}%] \t\r\n]"
local closers = { [OPEN_OBJECT] = CLOSE_OBJECT, [OPEN_ARRAY] = CLOSE_ARRAY }

local function skipBalanced(text, index)
    local expected = closers[byte(text, index)]
    local depth = 0
    local cursor = index
    while true do
        local hit = find(text, brackets, cursor)
        if not hit then return nil end
        local token = byte(text, hit)
        if token == OPEN_OBJECT or token == OPEN_ARRAY then
            depth = depth + 1
        else
            depth = depth - 1
            if depth == 0 then
                if token ~= expected then return nil end
                return hit + 1
            end
        end
        cursor = hit + 1
    end
end

local function skipQuoted(text, index)
    local depth = 0
    local cursor = index
    while true do
        local hit = find(text, stringTokens, cursor)
        if not hit then return nil end
        local token = byte(text, hit)
        if token == QUOTE then
            local stop = stringEnd(text, hit)
            if not stop then return nil end
            cursor = stop + 1
        elseif token == OPEN_OBJECT or token == OPEN_ARRAY then
            depth = depth + 1
            cursor = hit + 1
        else
            depth = depth - 1
            if depth == 0 then return hit + 1 end
            cursor = hit + 1
        end
    end
end

local function skipValue(text, index, safe)
    local char = byte(text, index)
    if char == QUOTE then
        local stop = stringEnd(text, index)
        if not stop then return nil end
        return stop + 1
    end
    if char == OPEN_OBJECT or char == OPEN_ARRAY then
        if not safe then
            local stop = skipBalanced(text, index)
            if stop then
                local follower = byte(text, skipSpace(text, stop))
                if follower == nil or follower == COMMA
                    or follower == CLOSE_OBJECT or follower == CLOSE_ARRAY then
                    return stop
                end
            end
        end
        return skipQuoted(text, index)
    end
    return find(text, delimiter, index) or (#text + 1)
end

-- Byte-level number scan: digits, one optional fraction, one optional
-- exponent. Like skipSpace this avoids host-bridge calls, which is what a
-- project response with thousands of priority/sortOrder fields runs into.
local function decodeNumber(text, index)
    local length = #text
    local cursor = index
    if byte(text, cursor) == 45 then cursor = cursor + 1 end -- '-'
    local digits = 0
    while cursor <= length do
        local char = byte(text, cursor)
        if char >= 48 and char <= 57 then
            digits = digits + 1
            cursor = cursor + 1
        else
            break
        end
    end
    if digits == 0 then return nil, index, "invalidNumber" end
    if byte(text, cursor) == 46 then -- '.'
        cursor = cursor + 1
        while cursor <= length do
            local char = byte(text, cursor)
            if char >= 48 and char <= 57 then cursor = cursor + 1 else break end
        end
    end
    local char = byte(text, cursor)
    if char == 101 or char == 69 then -- 'e' / 'E'
        local after = cursor + 1
        local sign = byte(text, after)
        if sign == 43 or sign == 45 then after = after + 1 end
        local exponentDigits = 0
        while after <= length do
            local digit = byte(text, after)
            if digit >= 48 and digit <= 57 then
                exponentDigits = exponentDigits + 1
                after = after + 1
            else
                break
            end
        end
        if exponentDigits > 0 then cursor = after end
    end
    local value = tonumber(sub(text, index, cursor - 1))
    if not value then return nil, index, "invalidNumber" end
    return value, cursor
end

local decodeValue

local function decodeObject(text, index, skip, depth, safe)
    local object = {}
    local cursor = skipSpace(text, index + 1)
    if byte(text, cursor) == CLOSE_OBJECT then return object, cursor + 1 end

    while true do
        cursor = skipSpace(text, cursor)
        if byte(text, cursor) ~= QUOTE then
            return nil, cursor, "expectedObjectKey"
        end
        local key, afterKey, keyError = decodeString(text, cursor)
        if not key then return nil, cursor, keyError end
        cursor = skipSpace(text, afterKey)
        if byte(text, cursor) ~= COLON then
            return nil, cursor, "expectedColon"
        end
        cursor = skipSpace(text, cursor + 1)

        if skip and skip[key] then
            local nextIndex = skipValue(text, cursor, safe)
            if not nextIndex then return nil, cursor, "unterminatedValue" end
            cursor = nextIndex
        else
            local value, nextIndex, valueError = decodeValue(text, cursor, skip, depth + 1, safe)
            if value == nil then return nil, cursor, valueError or "invalidValue" end
            object[key] = value
            cursor = nextIndex
        end

        cursor = skipSpace(text, cursor)
        local token = byte(text, cursor)
        if token == CLOSE_OBJECT then return object, cursor + 1 end
        if token ~= COMMA then return nil, cursor, "expectedCommaOrBrace" end
        cursor = skipSpace(text, cursor + 1)
        if byte(text, cursor) == CLOSE_OBJECT then
            return nil, cursor, "trailingComma"
        end
    end
end

local function decodeArray(text, index, skip, depth, safe)
    local array = {}
    local count = 0
    local cursor = skipSpace(text, index + 1)
    if byte(text, cursor) == CLOSE_ARRAY then return array, cursor + 1 end

    while true do
        local value, nextIndex, valueError = decodeValue(text, cursor, skip, depth + 1, safe)
        if value == nil then return nil, cursor, valueError or "invalidValue" end
        count = count + 1
        array[count] = value
        cursor = skipSpace(text, nextIndex)
        local token = byte(text, cursor)
        if token == CLOSE_ARRAY then return array, cursor + 1 end
        if token ~= COMMA then return nil, cursor, "expectedCommaOrBracket" end
        cursor = skipSpace(text, cursor + 1)
        if byte(text, cursor) == CLOSE_ARRAY then
            return nil, cursor, "trailingComma"
        end
    end
end

decodeValue = function(text, index, skip, depth, safe)
    if depth > MAX_DEPTH then return nil, nil, "nestingTooDeep" end
    index = skipSpace(text, index)
    if index > #text then return nil, nil, "unexpectedEnd" end

    local char = byte(text, index)
    if char == OPEN_OBJECT then
        return decodeObject(text, index, skip, depth, safe)
    elseif char == OPEN_ARRAY then
        return decodeArray(text, index, skip, depth, safe)
    elseif char == QUOTE then
        return decodeString(text, index)
    elseif char == 116 then -- 't'
        if sub(text, index, index + 3) == "true" then return true, index + 4 end
        return nil, index, "invalidLiteral"
    elseif char == 102 then -- 'f'
        if sub(text, index, index + 4) == "false" then return false, index + 5 end
        return nil, index, "invalidLiteral"
    elseif char == 110 then -- 'n'
        if sub(text, index, index + 3) == "null" then return null, index + 4 end
        return nil, index, "invalidLiteral"
    end
    return decodeNumber(text, index)
end

-- decode(text, options?) -> value, errorCode
-- options.skip: table keyed by object key name; matching values are discarded.
-- A JSON null becomes json.null; nil always means the document was rejected.
function json.decode(text, options)
    if type(text) ~= "string" or text == "" then return nil, "emptyInput" end
    if #text > MAX_BYTES then return nil, "inputTooLarge" end

    local skip = options and options.skip or nil
    local start = skipSpace(text, 1)
    local value, _, err = decodeValue(text, start, skip, 0, skip == nil)
    if value ~= nil or skip == nil then
        if value == nil then return nil, err or "invalidJson" end
        return value
    end

    -- A bracket inside a skipped string can end the fast scan early. Retrying
    -- with the string-aware scan is cheap insurance for that rare document.
    local retried, _, retryErr = decodeValue(text, start, skip, 0, true)
    if retried == nil then return nil, retryErr or err or "invalidJson" end
    return retried
end

function json.isNull(value)
    return value == null
end

return json
