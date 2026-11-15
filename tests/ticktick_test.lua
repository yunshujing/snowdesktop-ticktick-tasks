local ticktick = module.require("modules/ticktick.lua")

local function same(actual, expected, label)
    if actual ~= expected then
        error(string.format("%s: expected %s, got %s", label,
            tostring(expected), tostring(actual)), 2)
    end
end

local function truthy(value, label)
    if not value then error(label, 2) end
end

local function falsy(value, label)
    if value then error(label, 2) end
end

-- Fixtures are invented; every id, name and date below is made up.
local function task(overrides)
    local value = {
        id = "x", projectId = "p1", title = "t", open = true, allDay = false,
        priority = 0, dueMs = 0, itemsDone = 0, itemsTotal = 0, repeats = false,
        sortOrder = 0, dayIdx = 0, hour = 9, min = 0,
    }
    for key, item in pairs(overrides or {}) do value[key] = item end
    return value
end

return {
    ["parses due dates with every offset shape"] = function()
        local base = ticktick.daysFromCivil(2026, 11, 14) * 86400000
        same(ticktick.parseDue("2026-11-14T18:00:00.000+0800"), base + 10 * 3600000,
            "compact offset")
        same(ticktick.parseDue("2026-11-14T18:00:00.000+08:00"), base + 10 * 3600000,
            "colon offset")
        same(ticktick.parseDue("2026-11-14T10:00:00Z"), base + 10 * 3600000, "zulu")
        same(ticktick.parseDue("2026-11-14"), base, "bare date")
        local _, bareDay = ticktick.parseDue("2026-11-14")
        same(bareDay, ticktick.daysFromCivil(2026, 11, 14), "bare date keeps its day")
        same(ticktick.parseDue("2026-11-14T10:00:00.250Z"), base + 10 * 3600000 + 250,
            "milliseconds")
        same(ticktick.parseDue("2026-11-13T22:00:00.000-0200"), base + 0, "negative offset")
        same(ticktick.parseDue("nonsense"), nil, "garbage")
        same(ticktick.parseDue(nil), nil, "nil")
    end,

    ["reads the project list"] = function()
        local list, folders, err = ticktick.parseProjects([[
[
  {"id": "pWork", "name": "Work", "color": "#E8574A", "sortOrder": 10},
  {"id": "pLife", "name": " Life ", "color": "not-a-color", "sortOrder": 20},
  {"id": "pOld", "name": "Archive", "color": "#6B7A8F", "closed": true, "sortOrder": 30},
  {"id": "inbox9001", "name": "", "sortOrder": 40}
]
]])
        truthy(list, "parse failed: " .. tostring(err))
        same(#list, 3, "closed project dropped")
        same(list[1].name, "Work", "name")
        same(list[2].name, "Life", "name trimmed")
        same(list[2].color, ticktick.fallbackColor("pLife"), "colour fallback")
        same(list[3].inbox, true, "inbox by id prefix")
    end,

    ["reads one project's tasks"] = function()
        local tasks, err = ticktick.parseProjectTasks([[
{"project": {"id": "pWork"}, "tasks": [
  {"id": "t1", "projectId": "pWork", "title": "Write", "priority": 5, "status": 0,
   "dueDate": "2026-11-14T18:00:00.000+0800", "allDay": false,
   "items": [{"status": 2}, {"status": 0}], "repeatFlag": "RRULE:FREQ=WEEKLY"},
  {"id": "t2", "projectId": "pWork", "title": "", "content": "Buy milk", "allDay": true},
  {"id": "t3", "projectId": "pWork", "title": "Done", "status": 2}
]}
]], "pWork")
        truthy(tasks, "parse failed: " .. tostring(err))
        same(#tasks, 2, "completed task dropped")
        same(tasks[1].title, "Write", "title")
        same(tasks[1].itemsDone, 1, "done items")
        same(tasks[1].repeats, true, "repeat flag")
        same(tasks[2].title, "Buy milk", "content as title")
        same(tasks[2].allDay, true, "open API allDay key")
    end,

    ["treats a bare due date as a calendar day"] = function()
        local tasks, _, err = ticktick.parseProjectTasks([[
{"project": {"id": "p1"}, "tasks": [
  {"id": "a", "projectId": "p1", "title": "All day", "dueDate": "2026-11-14"}
]}
]], "p1")
        truthy(tasks, "parse failed: " .. tostring(err))
        same(tasks[1].dueDay, ticktick.daysFromCivil(2026, 11, 14), "civil day")
        same(tasks[1].allDay, true, "bare date means all day")
    end,

    ["reads kanban columns and groups by them"] = function()
        local tasks, columns = ticktick.parseProjectTasks([[
{"project": {"id": "pWork", "viewMode": "kanban"},
 "columns": [
   {"id": "c2", "name": "2月", "sortOrder": 20},
   {"id": "c1", "name": "1月", "sortOrder": 10}
 ],
 "tasks": [
   {"id": "a", "projectId": "pWork", "title": "Jan task", "columnId": "c1"},
   {"id": "b", "projectId": "pWork", "title": "Feb task", "columnId": "c2"},
   {"id": "c", "projectId": "pWork", "title": "Loose"}
 ]}
]], "pWork")
        truthy(tasks, "tasks parsed")
        truthy(columns, "columns parsed")
        same(#columns, 2, "two columns")
        same(columns[1].name, "1月", "sorted by sortOrder")
        same(tasks[3].columnId, nil, "no column id on the loose task")

        local state = {
            projects = { pWork = { id = "pWork" } },
            list = { { id = "pWork", sortOrder = 1 } },
            columns = { pWork = columns },
            tasks = tasks,
        }
        local board = ticktick.composeProjects(state, { today = 10 })
        same(board.rows[1].kind, "group", "project group first")
        same(board.rows[2].kind, "column", "column group")
        same(board.rows[2].name, "1月", "first column")
        same(board.rows[3].task.id, "a", "january task")
        same(board.rows[4].name, "2月", "second column")
        same(board.rows[5].task.id, "b", "february task")
        same(board.rows[6].kind, "column", "leftover column last")
        same(board.rows[6].columnId, nil, "leftover column has no id")
        same(board.rows[7].task.id, "c", "loose task")
    end,

    ["rejects a project payload without tasks"] = function()
        local tasks, _, err = ticktick.parseProjectTasks('{"project":{}}', "p")
        same(tasks, nil, "no tasks")
        same(err, "missingTasks", "error code")
        same(select(3, ticktick.parseProjects("")), "emptyInput", "empty projects")
    end,


    ["composes the today board with overdue first"] = function()
        local floating = task({ id = "floating", projectId = "p1", dayIdx = 10 })
        floating.dueMs = nil
        local state = {
            projects = { p1 = { id = "p1", sortOrder = 1 }, p2 = { id = "p2", sortOrder = 2 } },
            tasks = {
                task({ id = "late", projectId = "p1", dayIdx = 9, dueMs = 300, hour = 10 }),
                task({ id = "later", projectId = "p1", dayIdx = 8, dueMs = 200, hour = 10 }),
                task({ id = "early", projectId = "p2", dayIdx = 10, dueMs = 500, hour = 8 }),
                task({ id = "allday", projectId = "p2", dayIdx = 10, allDay = true, dueMs = 400 }),
                task({ id = "tomorrow", projectId = "p1", dayIdx = 11, dueMs = 900 }),
                task({ id = "done", projectId = "p1", dayIdx = 10, open = false }),
                floating,
                task({ id = "hidden", projectId = "p1", dayIdx = 10 }),
            },
        }
        local board = ticktick.compose(state, { today = 10, days = 1, hidden = { hidden = true } })
        same(board.count, 4, "visible count")
        same(board.overdue, 2, "overdue count")
        same(board.rows[1].kind, "group", "overdue group first")
        same(board.rows[1].overdue, true, "marked overdue")
        same(board.rows[2].task.id, "later", "oldest overdue first")
        same(board.rows[3].task.id, "late", "newer overdue second")
        same(board.rows[4].kind, "group", "today gets its own header below overdue")
        same(board.rows[4].dayIdx, 10, "header names today")
        same(board.rows[5].task.id, "allday", "all-day before timed")
        same(board.rows[6].task.id, "early", "timed task after all-day")
        same(board.counts.p1, 2, "project tally")
        same(board.order[1], "p1", "tallied project first")
    end,

    ["composes project groups including undated tasks"] = function()
        local undated = task({ id = "b", projectId = "p1" })
        undated.dueMs = nil
        undated.dayIdx = nil
        local state = {
            projects = { p1 = { id = "p1", sortOrder = 1 }, p2 = { id = "p2", sortOrder = 2 } },
            list = { { id = "p1", sortOrder = 1 }, { id = "p2", sortOrder = 2 } },
            tasks = {
                task({ id = "a", projectId = "p1", dueMs = 500 }),
                undated,
                task({ id = "c", projectId = "p2", dueMs = 100 }),
                task({ id = "done", projectId = "p1", open = false }),
            },
        }
        local board = ticktick.composeProjects(state, { today = 10, perProject = 5 })
        same(board.count, 3, "undated task counted")
        same(board.byProject, true, "flagged as project board")
        same(board.rows[1].kind, "group", "first row is a group")
        same(board.rows[1].projectId, "p1", "projects follow their order")
        same(board.rows[2].task.id, "a", "dated task first")
        same(board.rows[3].task.id, "b", "undated task last")
        same(board.rows[4].projectId, "p2", "second project group")

        local capped = ticktick.composeProjects(state, { today = 10, perProject = 1 })
        same(capped.capped, 1, "one task capped away")
    end,

    ["composes the week board into day groups"] = function()
        local state = {
            projects = {},
            tasks = {
                task({ id = "today", dayIdx = 10, dueMs = 100 }),
                task({ id = "d1", dayIdx = 11, dueMs = 100 }),
                task({ id = "d1b", dayIdx = 11, dueMs = 200 }),
                task({ id = "d7", dayIdx = 16, dueMs = 100 }),
                task({ id = "d8", dayIdx = 17, dueMs = 100 }),
            },
        }
        local week = ticktick.compose(state, { today = 10, days = 7 })
        same(week.count, 4, "week count")
        local groups, days = 0, {}
        for index = 1, #week.rows do
            if week.rows[index].kind == "group" then
                groups = groups + 1
                days[groups] = week.rows[index].dayIdx
            end
        end
        same(groups, 3, "group count")
        same(days[1], 10, "today group")
        same(days[2], 11, "tomorrow group")
        same(days[3], 16, "sixth day group")
    end,

    ["sorts by priority and by manual order"] = function()
        local state = {
            projects = { p1 = { id = "p1", sortOrder = 1 } },
            list = { { id = "p1", sortOrder = 1 } },
            tasks = {
                task({ id = "low", projectId = "p1", priority = 1, dueMs = 100, sortOrder = 1 }),
                task({ id = "high", projectId = "p1", priority = 5, dueMs = 300, sortOrder = 3 }),
                task({ id = "mid", projectId = "p1", priority = 3, dueMs = 200, sortOrder = 2 }),
            },
        }
        local byPriority = ticktick.composeProjects(state, { today = 10, sort = "priority" })
        same(byPriority.rows[2].task.id, "high", "priority first")
        same(byPriority.rows[3].task.id, "mid", "medium second")
        same(byPriority.rows[4].task.id, "low", "low last")

        local manual = ticktick.composeProjects(state, { today = 10, sort = "manual" })
        same(manual.rows[2].task.id, "low", "manual order 1")
        same(manual.rows[3].task.id, "mid", "manual order 2")
        same(manual.rows[4].task.id, "high", "manual order 3")
    end,

    ["groups tasks by month with undated last"] = function()
        local undated = task({ id = "u", projectId = "p1" })
        undated.dueMs = nil
        undated.dayIdx = nil
        local state = {
            projects = {}, list = { { id = "p1", sortOrder = 1 } },
            tasks = {
                task({ id = "jan", projectId = "p1",
                    dayIdx = ticktick.daysFromCivil(2027, 1, 15), dueMs = 1 }),
                task({ id = "nov", projectId = "p1",
                    dayIdx = ticktick.daysFromCivil(2026, 11, 20), dueMs = 2 }),
                undated,
            },
        }
        local board = ticktick.composeMonths(state, {
            today = ticktick.daysFromCivil(2026, 11, 15),
        })
        same(board.count, 3, "all tasks counted")
        same(board.rows[1].kind, "group", "first row is a group")
        same(board.rows[1].year, 2026, "first year")
        same(board.rows[1].month, 11, "first month")
        same(board.rows[2].task.id, "nov", "november task")
        same(board.rows[3].year, 2027, "second group year")
        same(board.rows[4].task.id, "jan", "january task")
        same(board.rows[5].undated, true, "undated group last")
        same(board.rows[6].task.id, "u", "undated task")
    end,

    ["sorts by list when asked"] = function()
        local state = {
            projects = {},
            list = { { id = "p1", sortOrder = 1 }, { id = "p2", sortOrder = 2 } },
            tasks = {
                task({ id = "b", projectId = "p2", dayIdx = 10, dueMs = 100 }),
                task({ id = "a", projectId = "p1", dayIdx = 10, dueMs = 200 }),
                task({ id = "c", projectId = "p1", dayIdx = 10, dueMs = 300 }),
            },
        }
        local board = ticktick.compose(state, { today = 10, days = 1, sort = "project" })
        same(board.rows[1].task.id, "a", "first list, earlier due")
        same(board.rows[2].task.id, "c", "first list, later due")
        same(board.rows[3].task.id, "b", "second list after")
    end,

    ["skips hidden projects in every view"] = function()
        local state = {
            projects = { p1 = { id = "p1", sortOrder = 1 }, p2 = { id = "p2", sortOrder = 2 } },
            list = { { id = "p1", sortOrder = 1 }, { id = "p2", sortOrder = 2 } },
            tasks = {
                task({ id = "a", projectId = "p1", dayIdx = 10, dueMs = 100 }),
                task({ id = "b", projectId = "p2", dayIdx = 10, dueMs = 200 }),
            },
        }
        local off = { p2 = true }
        local today = ticktick.compose(state, { today = 10, days = 1, off = off })
        same(today.count, 1, "day view filtered")
        local projects = ticktick.composeProjects(state, { today = 10, off = off })
        same(projects.count, 1, "project view filtered")
        same(#projects.rows, 2, "one group plus one task")
    end,



    ["builds preview fixtures"] = function()
        local state = ticktick.previewState(
            "Write the weekly note|Work|#E8574A|5|0|0|18:00;" ..
            "Buy milk|Life|#2ECC71|0|0|1|;Stale|Life|#2ECC71|1|-1|0|09:00",
            100, 0)
        same(#state.tasks, 3, "task count")
        same(#state.list, 2, "project count")
        same(state.tasks[1].hour, 18, "hour")
        same(state.tasks[1].dayIdx, 100, "today index")
        same(state.tasks[2].allDay, true, "all day fixture")
        same(state.tasks[3].dayIdx, 99, "overdue fixture")
        same(state.projects[state.tasks[1].projectId].name, "Work", "project link")
    end,

    ["parses hex colours"] = function()
        same(ticktick.parseHexColor("#E8574A"), 0xE8574A, "with hash")
        same(ticktick.parseHexColor("4772fa"), 0x4772FA, "without hash")
        same(ticktick.parseHexColor("blue"), nil, "named colour")
        same(ticktick.parseHexColor(nil), nil, "nil")
    end,
}
