local json = module.require("modules/json.lua")

local function same(actual, expected, label)
    if actual ~= expected then
        error(string.format("%s: expected %s, got %s", label,
            tostring(expected), tostring(actual)), 2)
    end
end

local function truthy(value, label)
    if not value then error(label, 2) end
end

return {
    ["decodes objects, arrays and scalars"] = function()
        local value = json.decode('{"a":1,"b":[true,false,null],"c":"x","d":{}}')
        same(value.a, 1, "a")
        same(value.b[1], true, "b1")
        same(value.b[2], false, "b2")
        truthy(json.isNull(value.b[3]), "null sentinel")
        same(value.c, "x", "c")
        same(#value.d, 0, "empty object")
    end,

    ["decodes numbers in every JSON shape"] = function()
        local value = json.decode("[-1, 2.5, 1e3, -2.5E-2, 0, 1024]")
        same(value[1], -1, "negative")
        same(value[2], 2.5, "decimal")
        same(value[3], 1000, "exponent")
        same(value[4], -0.025, "signed exponent")
        same(value[5], 0, "zero")
        same(value[6], 1024, "integer")
    end,

    ["decodes escapes, unicode and surrogate pairs"] = function()
        local value = json.decode('"line\\nbreak \\"quoted\\" tab\\t \\u4e2d\\u6587 \\ud83d\\ude00 end"')
        same(value, 'line\nbreak "quoted" tab\t 中文 😀 end', "escaped text")
    end,

    ["keeps raw UTF-8 bytes untouched"] = function()
        local value = json.decode('{"name":"alice"}')
        same(value.name, "alice", "utf8")
    end,

    ["tolerates whitespace and an empty array"] = function()
        local value = json.decode(' \n\t{ "a" : [ ] , "b" : 1 } \n ')
        same(#value.a, 0, "empty array")
        same(value.b, 1, "b")
    end,

    ["skip drops named subtrees at every depth"] = function()
        local payload = '{"keep":1,"order":[{"id":"a"},{"id":"b"}],' ..
            '"nested":{"order":[1,2],"ok":true},"prompt":{"parts":[{"x":1}]}}'
        local value = json.decode(payload, { skip = { order = true, prompt = true } })
        same(value.keep, 1, "keep")
        same(value.order, nil, "top level skip")
        same(value.prompt, nil, "top level prompt skip")
        same(value.nested.ok, true, "nested survivor")
        same(value.nested.order, nil, "nested skip")
    end,

    ["skip handles strings containing braces and quotes"] = function()
        local payload = '{"skipMe":{"text":"a\\"}]}b","list":[[1],[2]]},"keep":7}'
        local value = json.decode(payload, { skip = { skipMe = true } })
        same(value.keep, 7, "kept after tricky skip")
    end,

    ["rejects malformed documents"] = function()
        local value = json.decode('{"a":}')
        same(value, nil, "missing value")
        value = json.decode('{"a":1')
        same(value, nil, "unterminated object")
        value = json.decode('[1,2,]')
        same(value, nil, "trailing comma")
        value = json.decode("")
        same(value, nil, "empty input")
    end,

    ["projects a large skipped payload quickly"] = function()
        -- The shape of one project's /open/v1/project/{id}/data response at
        -- scale: 300 tasks, each carrying a long note body, a checklist and
        -- reminders the board never draws. Skipping is what keeps this inside
        -- the VM's per-callback quota.
        local note = string.rep("x", 200)
        local items = '{"status":0,"title":"step"},{"status":2,"title":"done"}'
        local reminders = '{"trigger":"TRIGGER:-PT15M","type":"relative"}'
        local tasks = {}
        for index = 1, 120 do
            tasks[index] = '{"id":"t' .. index .. '","projectId":"p1",' ..
                '"title":"Task ' .. index .. '","desc":"' .. note .. '",' ..
                '"dueDate":"2026-11-14T18:00:00.000+0800","allDay":false,' ..
                '"priority":3,"status":0,"sortOrder":' .. index .. ',' ..
                '"items":[' .. items .. '],"reminders":[' .. reminders .. '],' ..
                '"tags":["home","errand"],"etag":"abc' .. index .. '"}'
        end
        local payload = '{"project":{"id":"p1","name":"Inbox"},' ..
            '"tasks":[' .. table.concat(tasks, ",") .. ']}'
        truthy(#payload > 40 * 1024, "fixture is project sized")

        local skip = { desc = true, items = true, reminders = true, tags = true,
            etag = true }
        local value = json.decode(payload, { skip = skip })
        same(#value.tasks, 120, "task count")
        same(value.tasks[1].title, "Task 1", "title survives")
        same(value.tasks[120].desc, nil, "note bodies dropped")
        same(value.tasks[120].items, nil, "checklists dropped")
    end,
}
