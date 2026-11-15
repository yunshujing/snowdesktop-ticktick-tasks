-- modules/ticktick.lua - pure projections for TickTick's Open API.
--
-- Everything here is side-effect free and host-API free so `snowwidget test`
-- can exercise it without a network or a running SnowDesktop. The shapes come
-- from the official Open API:
--
--   GET  /open/v1/project                 bare array of projects (kind=GROUP is a folder)
--   GET  /open/v1/project/{id}/data       { project, tasks, columns? }
--   POST /open/v1/project/{p}/task/{t}/complete
--
-- Due dates arrive as "2026-11-14T18:00:00.000+0800". The board needs the
-- instant plus the user's own calendar day, so parseDue returns epoch
-- milliseconds (and, for a bare "YYYY-MM-DD", its civil day index) and the
-- caller asks the host (time.parts) for the remaining day fields.

local json = module.require("modules/json.lua")

local ticktick = {}

-- The sandbox enforces a per-callback execution quota, and a very large
-- project response can hit it mid-decode. That arrives as a Lua error, which
-- would otherwise abort the whole event handler and leave the board stuck on
-- "syncing". Catching it here turns it into a normal parse failure: that one
-- project is skipped and every other list still renders.
local function decode(text, skip)
    local ok, value, err = pcall(json.decode, text, skip and { skip = skip } or nil)
    if not ok then return nil, "quotaExceeded" end
    return value, err
end

-- Civil-from-days: calendar fields for an epoch day number.
function ticktick.civilDate(dayIdx)
    local z = dayIdx + 719468
    local era = math.floor(z / 146097)
    local dayOfEra = z - era * 146097
    local yearOfEra = math.floor((dayOfEra - math.floor(dayOfEra / 1460)
        + math.floor(dayOfEra / 36524) - math.floor(dayOfEra / 146096)) / 365)
    local year = yearOfEra + era * 400
    local dayOfYear = dayOfEra - (365 * yearOfEra + math.floor(yearOfEra / 4)
        - math.floor(yearOfEra / 100))
    local monthPrime = math.floor((5 * dayOfYear + 2) / 153)
    local day = dayOfYear - math.floor((153 * monthPrime + 2) / 5) + 1
    local month = monthPrime < 10 and monthPrime + 3 or monthPrime - 9
    if month <= 2 then year = year + 1 end
    return { year = year, month = month, day = day }
end

local TASK_SKIP = {
    desc = true,
    reminders = true,
    exDate = true,
    attachments = true,
    comments = true,
    childIds = true,
    etag = true,
    kind = true,
    repeatFrom = true,
    createdTime = true,
    modifiedTime = true,
    deleted = true,
    isFloating = true,
    timeZone = true,
    startDate = true,
    tags = true,
}

-- Howard Hinnant's civil-from-days, inverted: epoch day number for a date.
function ticktick.daysFromCivil(year, month, day)
    local adjusted = month <= 2 and year - 1 or year
    local era = math.floor(adjusted / 400)
    local yearOfEra = adjusted - era * 400
    local monthPrime = (month + 9) % 12
    local dayOfYear = math.floor((153 * monthPrime + 2) / 5) + day - 1
    local dayOfEra = yearOfEra * 365 + math.floor(yearOfEra / 4)
        - math.floor(yearOfEra / 100) + dayOfYear
    return era * 146097 + dayOfEra - 719468
end

-- TickTick writes "2026-11-14T18:00:00.000+0800" (and occasionally a "Z" or a
-- colon in the offset). A value without an offset is taken as UTC.
--
-- A bare "YYYY-MM-DD" carries no instant: it is a calendar day, so the second
-- return value is that day's civil index and the caller must not run the UTC
-- midnight through time.parts (west of UTC that lands on the previous day).
function ticktick.parseDue(value)
    if type(value) ~= "string" then return nil end
    local year, month, day, hour, minute, second, rest = value:match(
        "^(%d%d%d%d)%-(%d%d)%-(%d%d)[T ](%d%d):(%d%d):(%d%d)(.*)$")
    if not year then
        -- All-day tasks sometimes arrive as a bare date.
        local y, m, d = value:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
        if not y then return nil end
        local dayIdx = ticktick.daysFromCivil(tonumber(y), tonumber(m), tonumber(d))
        return dayIdx * 86400000, dayIdx
    end

    local seconds = ticktick.daysFromCivil(
        tonumber(year), tonumber(month), tonumber(day)) * 86400
        + tonumber(hour) * 3600 + tonumber(minute) * 60 + tonumber(second)

    local fraction = rest:match("^%.(%d+)")
    local milliseconds = fraction and math.floor(tonumber("0." .. fraction) * 1000) or 0

    local sign, offsetHour, offsetMinute = rest:match("([%+%-])(%d%d):?(%d%d)")
    if sign then
        local offset = tonumber(offsetHour) * 3600 + tonumber(offsetMinute) * 60
        seconds = sign == "+" and seconds - offset or seconds + offset
    end
    return seconds * 1000 + milliseconds
end

-- Project colours are "#RRGGBB"; anything else falls back to a stable palette.
function ticktick.parseHexColor(value)
    if type(value) ~= "string" then return nil end
    local hex = value:match("^#?(%x%x%x%x%x%x)$")
    if not hex then return nil end
    return tonumber(hex, 16)
end

local fallbackColors = {
    0x4772FA, 0xE8574A, 0xF5A623, 0x2ECC71, 0x9B51E0,
    0x00B8D9, 0xEB5A9E, 0x6B7A8F,
}

function ticktick.fallbackColor(key)
    local hash = 0
    for index = 1, #key do
        hash = (hash * 31 + string.byte(key, index)) % 100003
    end
    return fallbackColors[hash % #fallbackColors + 1]
end

local function trim(value)
    return (value:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function isComplete(status)
    return status == 2 or status == true or status == "2"
end

-- Checklist items use 1 for done; tasks use 2. They never mean the same field.
local function isItemDone(status)
    return status == 1 or status == 2 or status == true
        or status == "1" or status == "2"
end

local function normalizeTask(raw, projectId)
    if type(raw) ~= "table" or raw.deleted == true then return nil end

    local id = raw.id
    if type(id) ~= "string" or id == "" then return nil end

    local status = raw.status
    if status == -1 or status == "-1" then return nil end

    local title = raw.title
    if type(title) ~= "string" or title == "" then title = raw.content end
    if type(title) ~= "string" then title = "" end
    title = trim(title:gsub("[\r\n]+", " "))
    if title == "" then title = " " end

    local priority = tonumber(raw.priority) or 0
    if priority ~= 1 and priority ~= 3 and priority ~= 5 then priority = 0 end

    local project = raw.projectId
    if type(project) ~= "string" or project == "" then project = projectId end
    if type(project) ~= "string" then project = "" end

    local itemsDone, itemsTotal = 0, 0
    local items = raw.items
    if type(items) == "table" then
        for index = 1, #items do
            local item = items[index]
            if type(item) == "table" then
                itemsTotal = itemsTotal + 1
                if isItemDone(item.status) then itemsDone = itemsDone + 1 end
            end
        end
    end

    local dueMs, dueDay = ticktick.parseDue(raw.dueDate)
    return {
        id = id,
        projectId = project,
        title = title,
        open = not isComplete(status),
        -- The web API spells this isAllDay, the Open API spells it allDay.
        allDay = raw.allDay == true or raw.isAllDay == true or dueDay ~= nil,
        priority = priority,
        dueMs = dueMs,
        -- Set only for a bare "YYYY-MM-DD": the calendar day the user picked,
        -- independent of the machine's time zone.
        dueDay = dueDay,
        itemsDone = itemsDone,
        itemsTotal = itemsTotal,
        sortOrder = tonumber(raw.sortOrder) or 0,
        columnId = type(raw.columnId) == "string" and raw.columnId or nil,
    }
end

local function normalizeProject(raw)
    if type(raw) ~= "table" or raw.deleted == true then return nil end
    local id = raw.id
    if type(id) ~= "string" or id == "" then return nil end
    local name = type(raw.name) == "string" and trim(raw.name) or ""
    local groupId = type(raw.groupId) == "string" and raw.groupId or nil
    local groupName = type(raw.groupName) == "string" and trim(raw.groupName) or nil
    return {
        id = id,
        -- Keep an empty name empty: the UI has a localized "Untitled list"
        -- fallback, and printing a raw ObjectId there reads like an id leak.
        name = name,
        inbox = id:sub(1, 5) == "inbox",
        color = ticktick.parseHexColor(raw.color) or ticktick.fallbackColor(id),
        closed = raw.closed == true,
        sortOrder = tonumber(raw.sortOrder) or 0,
        groupId = groupId,
        groupName = groupName,
        kind = type(raw.kind) == "string" and raw.kind or nil,
    }
end

-- parseProjects(body) -> { project, ... } | nil, errorCode
-- GET /open/v1/project returns a bare array of projects.
function ticktick.parseProjects(body)
    if type(body) ~= "string" or body == "" then return nil, nil, "emptyInput" end
    local doc, err = decode(body)
    if not doc then return nil, nil, err end
    if type(doc) ~= "table" then return nil, nil, "invalidProjects" end

    local list, folders = {}, {}
    for index = 1, #doc do
        local raw = doc[index]
        -- A folder may arrive as its own entry; remember its name and keep it
        -- out of the project list.
        if type(raw) == "table" and raw.kind == "GROUP" then
            local id = raw.id
            if type(id) == "string" and id ~= "" then
                folders[id] = {
                    id = id,
                    name = type(raw.name) == "string" and trim(raw.name) or "",
                }
            end
        else
            local project = normalizeProject(raw)
            if project and not project.closed then list[#list + 1] = project end
        end
    end
    table.sort(list, function(left, right)
        return left.sortOrder < right.sortOrder
    end)
    -- Folders named by a project's own groupName are learned here too.
    for index = 1, #list do
        local project = list[index]
        if project.groupId and project.groupName and not folders[project.groupId] then
            folders[project.groupId] = { id = project.groupId, name = project.groupName }
        end
    end
    return list, folders
end

-- parseProjectTasks(body, projectId) -> { task, ... } | nil, errorCode
-- GET /open/v1/project/{id}/data returns { project, tasks }.
function ticktick.parseProjectTasks(body, projectId)
    if type(body) ~= "string" or body == "" then return nil, nil, "emptyInput" end
    local doc, err = decode(body, TASK_SKIP)
    if not doc then return nil, nil, err end
    if type(doc) ~= "table" or type(doc.tasks) ~= "table" then
        return nil, nil, "missingTasks"
    end

    local list = {}
    for index = 1, #doc.tasks do
        local task = normalizeTask(doc.tasks[index], projectId)
        -- The Open API hands back completed tasks too; the board never shows them.
        if task and task.open then list[#list + 1] = task end
    end

    -- Kanban projects also return their columns; list projects omit the field.
    local columns = nil
    if type(doc.columns) == "table" and #doc.columns > 0 then
        columns = {}
        for index = 1, #doc.columns do
            local raw = doc.columns[index]
            if type(raw) == "table" and type(raw.id) == "string" and raw.id ~= "" then
                columns[#columns + 1] = {
                    id = raw.id,
                    name = type(raw.name) == "string" and trim(raw.name) or "",
                    sortOrder = tonumber(raw.sortOrder) or 0,
                }
            end
        end
        table.sort(columns, function(left, right)
            return left.sortOrder < right.sortOrder
        end)
        if #columns == 0 then columns = nil end
    end
    return list, columns
end

-- An open task counts as due today when its local calendar day matches, so
-- timed and all-day tasks share one comparison and DST never shifts a row.
-- `due` keeps the day/date ordering; the other two modes let the user pick what
-- leads. All-day first only makes sense in due order, so it is not applied to
-- priority or manual sorting.
local function before(left, right)
    -- Undated tasks have no dayIdx at all; comparing nil with a number throws.
    local leftDay, rightDay = left.dayIdx, right.dayIdx
    if leftDay and rightDay then
        if leftDay ~= rightDay then return leftDay < rightDay end
    elseif leftDay ~= rightDay then
        return leftDay ~= nil
    end
    if left.allDay ~= right.allDay then return left.allDay end
    -- Undated tasks sort last: a project list can hold them, a day list cannot.
    local leftDue, rightDue = left.dueMs, right.dueMs
    if leftDue and rightDue then
        if leftDue ~= rightDue then return leftDue < rightDue end
    elseif leftDue ~= rightDue then
        return leftDue ~= nil
    end
    if left.priority ~= right.priority then return left.priority > right.priority end
    return left.sortOrder < right.sortOrder
end

local function byPriority(left, right)
    if left.priority ~= right.priority then return left.priority > right.priority end
    local leftDue, rightDue = left.dueMs, right.dueMs
    if leftDue and rightDue then
        if leftDue ~= rightDue then return leftDue < rightDue end
    elseif leftDue ~= rightDue then
        return leftDue ~= nil
    end
    return left.sortOrder < right.sortOrder
end

local function byManual(left, right)
    if left.sortOrder ~= right.sortOrder then return left.sortOrder < right.sortOrder end
    local leftDue, rightDue = left.dueMs, right.dueMs
    if leftDue and rightDue then return leftDue < rightDue end
    return leftDue ~= nil
end

local function byProject(left, right, order)
    local leftOrder = order[left.projectId] or 9999
    local rightOrder = order[right.projectId] or 9999
    if leftOrder ~= rightOrder then return leftOrder < rightOrder end
    return before(left, right)
end

local function sortWith(list, mode, order)
    if mode == "priority" then
        table.sort(list, byPriority)
    elseif mode == "manual" then
        table.sort(list, byManual)
    elseif mode == "project" and order then
        table.sort(list, function(left, right) return byProject(left, right, order) end)
    else
        table.sort(list, before)
    end
end

local function projectOrder(state)
    local map = {}
    local list = state.list or {}
    for index = 1, #list do map[list[index].id] = index end
    return map
end

-- compose(state, options) -> { rows, count, overdue, counts, order, capped }
-- options.today: local day index of today (see daysFromCivil)
-- options.days: 1 for the today board, 7 for the week board
-- options.perDay: tasks shown per day in the week board (the rest are counted)
-- options.hidden: set of task ids to leave out (completed and already flashed)
function ticktick.compose(state, options)
    local today = options.today
    local days = options.days or 1
    local perDay = options.perDay or 999
    local hidden = options.hidden
    local off = options.off

    local overdue, buckets = {}, {}
    for index = 1, #state.tasks do
        local task = state.tasks[index]
        local skipped = off and off[task.projectId]
        if task.open and not skipped and task.dueMs and task.dayIdx
            and not (hidden and hidden[task.id]) then
            local offset = task.dayIdx - today
            if offset < 0 then
                overdue[#overdue + 1] = task
            elseif offset < days then
                local bucket = buckets[offset + 1]
                if not bucket then
                    bucket = {}
                    buckets[offset + 1] = bucket
                end
                bucket[#bucket + 1] = task
            end
        end
    end

    local order = projectOrder(state)
    sortWith(overdue, options.sort, order)
    for index = 1, days do
        local bucket = buckets[index]
        if bucket then sortWith(bucket, options.sort, order) end
    end

    local rows, counts, capped = {}, {}, 0
    local function tally(task)
        counts[task.projectId] = (counts[task.projectId] or 0) + 1
    end

    if #overdue > 0 then
        rows[#rows + 1] = { kind = "group", overdue = true, count = #overdue }
        for index = 1, #overdue do
            rows[#rows + 1] = { kind = "task", task = overdue[index], overdue = true }
            tally(overdue[index])
        end
    end

    local count = #overdue
    for offset = 1, days do
        local bucket = buckets[offset]
        if bucket and #bucket > 0 then
            -- A week board allocates a few rows per day instead of spending the
            -- whole body on today; the header still reports the day's total.
            local shown = math.min(#bucket, perDay)
            -- The today board usually needs no day header, but once an overdue
            -- block sits above it the day needs its own label or its rows read
            -- as overdue too.
            if days > 1 or #overdue > 0 then
                rows[#rows + 1] = {
                    kind = "group", dayIdx = today + offset - 1, count = #bucket,
                }
            end
            for index = 1, shown do
                rows[#rows + 1] = { kind = "task", task = bucket[index] }
                tally(bucket[index])
            end
            capped = capped + (#bucket - shown)
            count = count + #bucket
        end
    end

    -- Project tally, most active first; `order` above is the list index and is
    -- still in scope here, so the tally gets its own name.
    local orderList = {}
    for id in pairs(counts) do orderList[#orderList + 1] = id end
    table.sort(orderList, function(left, right)
        if counts[left] ~= counts[right] then return counts[left] > counts[right] end
        local leftProject = state.projects[left]
        local rightProject = state.projects[right]
        local leftOrder = leftProject and leftProject.sortOrder or 0
        local rightOrder = rightProject and rightProject.sortOrder or 0
        return leftOrder < rightOrder
    end)

    return {
        rows = rows,
        count = count,
        overdue = #overdue,
        capped = capped,
        counts = counts,
        order = orderList,
    }
end

-- A day header is shorter than a task row; the layout uses the same numbers.
ticktick.groupCost = 0.50
ticktick.columnCost = 0.50

-- composeProjects(state, options) -> same shape as compose, grouped by project.
-- options.perProject caps each list, options.hidden drops completed rows, and
-- options.today lets the header report overdue work. Undated tasks belong here:
-- a project list is a place, not a date.
function ticktick.composeProjects(state, options)
    local hidden = options and options.hidden
    local perProject = options and options.perProject or 999
    local today = options and options.today

    local off = options and options.off
    local buckets, total, overdue = {}, 0, 0
    for index = 1, #state.tasks do
        local task = state.tasks[index]
        if task.open and not (hidden and hidden[task.id])
            and not (off and off[task.projectId]) then
            local bucket = buckets[task.projectId]
            if not bucket then
                bucket = {}
                buckets[task.projectId] = bucket
            end
            bucket[#bucket + 1] = task
            total = total + 1
            if task.dayIdx and today and task.dayIdx < today then
                overdue = overdue + 1
            end
        end
    end

    local order = projectOrder(state)
    local active, shown = {}, {}
    local projectList = state.list or {}
    for index = 1, #projectList do
        local project = projectList[index]
        local bucket = buckets[project.id]
        if bucket and #bucket > 0 then
            sortWith(bucket, options and options.sort, order)
            active[#active + 1] = project.id
            shown[project.id] = math.min(#bucket, perProject)
        end
    end

    local rows, counts, capped, list = {}, {}, 0, {}
    local columnsOf = state.columns or {}
    for index = 1, #active do
        local id = active[index]
        local bucket = buckets[id]
        local emitted = 0
        if shown[id] > 0 then
            rows[#rows + 1] = { kind = "group", projectId = id, count = #bucket }
            local columns = columnsOf[id]
            if columns and #columns > 0 then
                -- Kanban lists carry their own columns; keep the board's order
                -- and collect tasks without a column at the end.
                local byColumn, leftovers = {}, {}
                for position = 1, #bucket do
                    local task = bucket[position]
                    local columnId = task.columnId
                    if columnId and columnId ~= "" then
                        local slot = byColumn[columnId]
                        if not slot then
                            slot = {}
                            byColumn[columnId] = slot
                        end
                        slot[#slot + 1] = task
                    else
                        leftovers[#leftovers + 1] = task
                    end
                end
                local function emitColumn(columnId, name, tasks)
                    sortWith(tasks, options and options.sort, order)
                    rows[#rows + 1] = {
                        kind = "column", projectId = id, columnId = columnId,
                        name = name, count = #tasks,
                    }
                    for position = 1, #tasks do
                        rows[#rows + 1] = { kind = "task", task = tasks[position] }
                    end
                    emitted = emitted + #tasks
                end
                for position = 1, #columns do
                    local column = columns[position]
                    local tasks = byColumn[column.id]
                    if tasks and #tasks > 0 then
                        emitColumn(column.id, column.name, tasks)
                        byColumn[column.id] = nil
                    end
                end
                -- Columns the API did not describe (renamed or stale ids).
                for columnId, tasks in pairs(byColumn) do
                    emitColumn(columnId, "", tasks)
                end
                if #leftovers > 0 then emitColumn(nil, nil, leftovers) end
            else
                for position = 1, shown[id] do
                    rows[#rows + 1] = { kind = "task", task = bucket[position] }
                end
                emitted = shown[id]
            end
            list[#list + 1] = id
        end
        capped = capped + (#bucket - emitted)
        counts[id] = #bucket
    end

    return {
        rows = rows,
        count = total,
        overdue = overdue,
        capped = capped,
        counts = counts,
        order = list,
        byProject = true,
    }
end


-- composeMonths(state, options) -> same shape as compose, grouped by month.
-- Undated tasks collect into a trailing group so nothing silently disappears.
function ticktick.composeMonths(state, options)
    local hidden = options and options.hidden
    local off = options and options.off
    local today = options and options.today
    local mode = options and options.sort
    local order = projectOrder(state)

    local buckets, keys, undated = {}, {}, {}
    local total, overdue = 0, 0
    for index = 1, #state.tasks do
        local task = state.tasks[index]
        if task.open and not (hidden and hidden[task.id])
            and not (off and off[task.projectId]) then
            total = total + 1
            if task.dayIdx and today and task.dayIdx < today then
                overdue = overdue + 1
            end
            if task.dayIdx then
                local date = ticktick.civilDate(task.dayIdx)
                local key = date.year * 100 + date.month
                local bucket = buckets[key]
                if not bucket then
                    bucket = { year = date.year, month = date.month, tasks = {} }
                    buckets[key] = bucket
                    keys[#keys + 1] = key
                end
                bucket.tasks[#bucket.tasks + 1] = task
            else
                undated[#undated + 1] = task
            end
        end
    end
    table.sort(keys)

    local rows, counts, list = {}, {}, {}
    local function emit(year, month, tasks, undatedGroup)
        sortWith(tasks, mode, order)
        rows[#rows + 1] = {
            kind = "group", year = year, month = month,
            undated = undatedGroup or nil, count = #tasks,
        }
        for index = 1, #tasks do
            rows[#rows + 1] = { kind = "task", task = tasks[index] }
            counts[tasks[index].projectId] = (counts[tasks[index].projectId] or 0) + 1
        end
    end

    for index = 1, #keys do
        local bucket = buckets[keys[index]]
        emit(bucket.year, bucket.month, bucket.tasks)
    end
    if #undated > 0 then emit(nil, nil, undated, true) end

    for id in pairs(counts) do list[#list + 1] = id end
    table.sort(list, function(left, right)
        if counts[left] ~= counts[right] then return counts[left] > counts[right] end
        return (order[left] or 9999) < (order[right] or 9999)
    end)

    return {
        rows = rows, count = total, overdue = overdue, capped = 0,
        counts = counts, order = list,
    }
end

-- Fixtures for the catalog preview. Rows are
-- "title|project|color|priority|dayOffset|allDay|HH:MM" separated by ";".
function ticktick.previewState(spec, todayIdx, todayStartMs)
    local state = { projects = {}, list = {}, tasks = {} }
    local seen = {}

    local function project(name, color)
        local id = "p" .. tostring(#state.list + 1)
        if not seen[name] then
            local value = {
                id = id,
                name = name,
                inbox = false,
                color = ticktick.parseHexColor(color) or ticktick.fallbackColor(name),
                closed = false,
                sortOrder = #state.list,
            }
            seen[name] = value
            state.projects[id] = value
            state.list[#state.list + 1] = value
            -- The first two fixture lists share a folder so the filter panel's
            -- folder row is exercised by previews.
            if #state.list <= 2 then
                value.groupId = "g1"
                value.groupName = "00.计划"
                state.folders = { g1 = { id = "g1", name = "00.计划" } }
            end
            -- The first fixture list behaves like a kanban board so previews
            -- exercise the column grouping.
            if #state.list == 1 then
                state.columns = state.columns or {}
                state.columns[value.id] = {
                    { id = "c1", name = "1月", sortOrder = 1 },
                    { id = "c2", name = "2月", sortOrder = 2 },
                }
                value.kanban = true
            end
        end
        return seen[name]
    end

    for row in tostring(spec or ""):gmatch("[^;]+") do
        local fields = {}
        for field in (row .. "|"):gmatch("([^|]*)|") do fields[#fields + 1] = field end
        if #fields >= 5 and fields[1] ~= "" then
            local offset = tonumber(fields[5]) or 0
            local allDay = fields[6] == "1"
            local hour, minute = 9, 0
            if fields[7] and fields[7] ~= "" then
                local h, m = fields[7]:match("^(%d%d?):(%d%d)$")
                hour, minute = tonumber(h) or 9, tonumber(m) or 0
            end
            local value = project(fields[2] ~= "" and fields[2] or "Inbox", fields[3])
            state.tasks[#state.tasks + 1] = {
                id = "t" .. tostring(#state.tasks + 1),
                projectId = value.id,
                title = fields[1],
                open = true,
                allDay = allDay,
                priority = tonumber(fields[4]) or 0,
                dueMs = todayStartMs + offset * 86400000
                    + (allDay and 0 or (hour * 3600 + minute * 60) * 1000),
                itemsDone = 0,
                itemsTotal = 0,
                repeats = false,
                sortOrder = #state.tasks + 1,
                dayIdx = todayIdx + offset,
                hour = allDay and 0 or hour,
                min = allDay and 0 or minute,
                columnId = (state.columns and state.columns[value.id])
                    and (offset < 0 and "c1" or "c2") or nil,
            }
        end
    end
    return state
end

return ticktick
