-- main.lua - Tasks for TickTick, a SnowDesktop API v2 task board.
--
-- TickTick has no "today" endpoint, so the board reads the Open API and
-- projects the calendar day itself:
--
--   GET  /open/v1/project                        [ { id, name, color, ... } ]
--   GET  /open/v1/project/{id}/data              { project, tasks, columns? }
--   POST /open/v1/project/{p}/task/{t}/complete  200, no body
--
-- The personal API token is stored as a DPAPI secret and injected by the host
-- as "Authorization: Bearer …" at send time, so the token never reaches Lua,
-- storage, logs or the preview renderer.

local ticktick = module.require("modules/ticktick.lua")

-- The same web client runs on two hosts: dida365.com is the mainland build
-- (滴答清单), ticktick.com the international one. Accounts do not cross over,
-- so the host is a setting rather than a guess.
local SERVERS = {
    dida = {
        id = "dida",
        api = "https://api.dida365.com",
        web = "https://dida365.com/webapp",
        origin = "https://dida365.com",
    },
    ticktick = {
        id = "ticktick",
        api = "https://api.ticktick.com",
        web = "https://ticktick.com/webapp",
        origin = "https://ticktick.com",
    },
}
local DEFAULT_SERVER = "dida"
local DEFAULT_INTERVAL = 300            -- seconds between snapshots
local FLASH_MS = 520                    -- strike-through before a row leaves
local TOAST_MS = 4200
local DUE_SOON_MS = 60 * 60 * 1000      -- next hour turns the time amber

local glyph = {
    refresh = utf8.char(0xF13D),
    open = utf8.char(0xF15C),
    settings = utf8.char(0xF6A9),
    done = utf8.char(0xF13C),
    link = utf8.char(0xF15B),
}

local WEEKDAYS = {
    en = { "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" },
    zh = { "日", "一", "二", "三", "四", "五", "六" },
}
local MONTHS = {
    "Jan", "Feb", "Mar", "Apr", "May", "Jun",
    "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
}

local sorts = { "due", "priority", "manual", "project" }
local sortKeys = {
    due = "lua_widget.ticktick_tasks.sort_due",
    priority = "lua_widget.ticktick_tasks.sort_priority",
    manual = "lua_widget.ticktick_tasks.sort_manual",
    project = "lua_widget.ticktick_tasks.sort_project",
}

local views = { "today", "week", "projects", "months" }
local viewKeys = {
    today = "lua_widget.ticktick_tasks.view_today",
    week = "lua_widget.ticktick_tasks.view_week",
    projects = "lua_widget.ticktick_tasks.view_projects",
    months = "lua_widget.ticktick_tasks.view_months",
}

local tooltipSupported = false

local settings = {
    presets = {
        {
            id = "frosted",
            label = l10n.tr("lua_widget.ticktick_tasks.preset_frosted"),
            default = true,
            values = {
                bg = 0x0B0B10,
                border = 0xFFFFFF,
                alpha = 0.16,
                borderAlpha = 0.10,
                gradientEndA = 0.16,
            },
        },
        {
            id = "solid",
            label = l10n.tr("lua_widget.ticktick_tasks.preset_solid"),
            values = {
                bg = 0x1A1A1E,
                border = 0xFFFFFF,
                alpha = 0.96,
                borderAlpha = 0.10,
                gradientEndA = 0.34,
            },
        },
        {
            id = "clear",
            label = l10n.tr("lua_widget.ticktick_tasks.preset_clear"),
            values = {
                bg = 0x000000,
                border = 0x000000,
                alpha = 0,
                borderAlpha = 0,
                gradientEndA = 0,
            },
        },
    },
    fields = {
        {
            key = "token",
            label = l10n.tr("lua_widget.ticktick_tasks.settings_token"),
            description = l10n.tr("lua_widget.ticktick_tasks.settings_token_help"),
            -- A personal API token, stored as a DPAPI secret and injected as
            -- "Authorization: Bearer …" at send time.
            type = "password",
            required = true,
            validationMessage = l10n.tr("lua_widget.ticktick_tasks.settings_token_missing"),
        },
        {
            key = "server",
            label = l10n.tr("lua_widget.ticktick_tasks.settings_server"),
            description = l10n.tr("lua_widget.ticktick_tasks.settings_server_help"),
            type = "select",
            default = DEFAULT_SERVER,
            options = { "dida", "ticktick" },
            optionLabels = {
                l10n.tr("lua_widget.ticktick_tasks.server_dida"),
                l10n.tr("lua_widget.ticktick_tasks.server_ticktick"),
            },
        },
        {
            key = "interval",
            label = l10n.tr("lua_widget.ticktick_tasks.settings_interval"),
            type = "duration",
            unit = "seconds",
            default = DEFAULT_INTERVAL,
            min = 60,
            max = 3600,
            step = 30,
        },
        {
            key = "view",
            label = l10n.tr("lua_widget.ticktick_tasks.settings_view"),
            type = "select",
            default = "today",
            options = views,
            optionLabels = {
                l10n.tr("lua_widget.ticktick_tasks.view_today"),
                l10n.tr("lua_widget.ticktick_tasks.view_week"),
                l10n.tr("lua_widget.ticktick_tasks.view_projects"),
                l10n.tr("lua_widget.ticktick_tasks.view_months"),
            },
        },
        {
            key = "folderLabel",
            label = l10n.tr("lua_widget.ticktick_tasks.settings_folder"),
            description = l10n.tr("lua_widget.ticktick_tasks.settings_folder_help"),
            type = "text",
            default = "",
            maxLength = 40,
            validationMessage = l10n.tr("lua_widget.ticktick_tasks.settings_folder_invalid"),
        },
        {
            key = "sort",
            label = l10n.tr("lua_widget.ticktick_tasks.settings_sort"),
            type = "select",
            default = "due",
            options = sorts,
            optionLabels = {
                l10n.tr("lua_widget.ticktick_tasks.sort_due"),
                l10n.tr("lua_widget.ticktick_tasks.sort_priority"),
                l10n.tr("lua_widget.ticktick_tasks.sort_manual"),
                l10n.tr("lua_widget.ticktick_tasks.sort_project"),
            },
        },
    },
}

-- A value read back from storage may be stale, hand-edited or from an older
-- build, so every enum goes through the same list the settings UI offers.
local function oneOf(value, list, fallback)
    for index = 1, #list do
        if list[index] == value then return value end
    end
    return fallback
end

local function config()
    local interval = tonumber(storage.get("interval")) or DEFAULT_INTERVAL
    interval = math.max(60, math.min(3600, math.floor(interval)))

    local view = oneOf(storage.get("view"), views, "today")
    local server = SERVERS[storage.get("server") or ""] or SERVERS[DEFAULT_SERVER]

    local folderLabel = storage.get("folderLabel")
    if type(folderLabel) ~= "string" then folderLabel = "" end
    folderLabel = folderLabel:gsub("^%s+", ""):gsub("%s+$", "")

    local sort = oneOf(storage.get("sort"), sorts, "due")

    -- Lists the user switched off in the context menu, kept as a comma list.
    local off, ids = {}, {}
    local rawOff = storage.get("projectsOff")
    if type(rawOff) == "string" and rawOff ~= "" then
        for id in rawOff:gmatch("[^,]+") do
            if not off[id] then
                off[id] = true
                ids[#ids + 1] = id
            end
        end
        table.sort(ids)
    end

    return {
        intervalMs = interval * 1000, view = view, server = server,
        sort = sort, off = off, offKey = table.concat(ids, ","),
        folderLabel = folderLabel,
    }
end

local function isZh()
    return (l10n.language() or ""):sub(1, 2) == "zh"
end

local function weekdayLabel(wday)
    local names = isZh() and WEEKDAYS.zh or WEEKDAYS.en
    return names[wday] or ""
end

local function palette(_context)
    -- Text follows the host's resolved foreground (contentTheme), not the theme
    -- name: a dark glass material can still report mode "light".
    local snapshot = widget.theme()
    local darkInk = snapshot ~= nil and snapshot.contentTheme == 1
    if darkInk then
        return {
            glass = 0xFFFFFF, glassAlpha = 0.62,
            line = 0x000000, lineAlpha = 0.10,
            ink = 0x1B1B21, ink2 = 0x4E4E58, muted = 0x71717B, faint = 0x9C9CA4,
            accent = 0x3D63F5, onAccent = 0xFFFFFF,
            good = 0x15803D, bad = 0xC9372B, warn = 0xA96A00,
            track = 0x000000, trackAlpha = 0.08,
            priority = { [0] = 0x8A8A94, [1] = 0x1F5FBF, [3] = 0xA96A00, [5] = 0xC9372B },
            hair = 1,
        }
    end
    return {
        glass = 0xFFFFFF, glassAlpha = 0.07,
        line = 0xFFFFFF, lineAlpha = 0.14,
        ink = 0xECECF1, ink2 = 0xC4C4CE, muted = 0x9A9AA6, faint = 0x6F6F7C,
        accent = 0x8FA5FF, onAccent = 0x101426,
        good = 0x6BD69B, bad = 0xF0786D, warn = 0xF0B44C,
        track = 0xFFFFFF, trackAlpha = 0.14,
        priority = { [0] = 0x7C7C88, [1] = 0x86A8FF, [3] = 0xF0B44C, [5] = 0xF0786D },
        hair = 1,
    }
end

-- ---------------------------------------------------------------------------
-- Calendar
-- ---------------------------------------------------------------------------

local civilDate = ticktick.civilDate

-- Everything the board calls "today" comes from the host's local calendar, so a
-- due date never drifts when the machine changes time zone.
local function clock()
    local now = time.now()
    local parts = time.parts(now)
    local midnight = (parts.hour or 0) * 3600000 + (parts.min or 0) * 60000
        + (parts.sec or 0) * 1000 + (parts.millisecond or 0)
    return {
        now = now,
        parts = parts,
        dayIdx = ticktick.daysFromCivil(parts.year, parts.month, parts.day),
        startMs = now - midnight,
        hour = parts.hour or 0,
        min = parts.min or 0,
    }
end

-- ---------------------------------------------------------------------------
-- Request pipeline
--
-- The host refuses to send a Cookie header: only Authorization / Api-Key may
-- carry credentials, and only as secret descriptors. That rules out the private
-- web API, so the widget uses the official Open API instead: one Bearer token,
-- no cookies, no CSRF.
--
--   GET  /open/v1/project                        -> [ { id, name, color, ... } ]
--   GET  /open/v1/project/{id}/data              -> { project, tasks }
--   POST /open/v1/project/{p}/task/{t}/complete  -> 200, no body
-- ---------------------------------------------------------------------------

local function requestHeaders(model)
    local headers = { Accept = "application/json" }
    if model.tokenRef then
        headers.Authorization = { secretRef = model.tokenRef, prefix = "Bearer " }
    end
    return headers
end

local function enqueue(model, kind, url, extra)
    for index = 1, #model.pending do
        local job = model.pending[index]
        if job.kind == kind and job.url == url then return false end
    end
    model.pending[#model.pending + 1] = {
        kind = kind, url = url,
        -- A response is only applied while its generation is still current, so
        -- a server or token switch cannot splice the old account's rows in.
        gen = model.gen,
        method = extra and extra.method or nil,
        body = extra and extra.body or nil,
        maxBytes = extra and extra.maxBytes or nil,
        taskId = extra and extra.taskId or nil,
        projectId = extra and extra.projectId or nil,
    }
    return true
end

-- A sync that never answers (the host occasionally drops the completion) or
-- fails transiently is retried a few times before the card appears; a token
-- that needs re-pasting after every hiccup is worse than a short wait.
local function scheduleRetry(model, reason)
    model.failures = (model.failures or 0) + 1
    if model.failures <= 3 then
        model.error = nil
        model.errorDetail = reason .. "#retry" .. tostring(model.failures)
        schedule.after("retry", 3000 * model.failures)
        return
    end
    model.error = reason
    model.errorDetail = reason
end

local function pump(model)
    while model.inFlight < 2 and #model.pending > 0 do
        local job = table.remove(model.pending, 1)
        local arguments = {
            url = job.url,
            method = job.method or (job.body and "POST" or "GET"),
            headers = requestHeaders(model),
            timeoutMs = 12000,
            cacheSeconds = 0,
            maxBytes = job.maxBytes or model.maxBytes,
        }
        if job.body then arguments.body = job.body end

        local taskId, taskError = task.start("network.request", arguments)
        if not taskId then
            -- Nothing else will arrive for this cycle, so stop the spinner
            -- instead of leaving the footer on "syncing" forever.
            model.syncing = false
            model.dataPending = 0
            model.projectsInFlight = false
            if taskError == "permissionRevoked" then
                model.error = "auth"
                model.errorDetail = taskError
            else
                -- A refused start (quota, transient host error) deserves the
                -- same retry ladder as a dropped response, not an instant
                -- "offline" card.
                scheduleRetry(model, "network")
                model.errorDetail = taskError
            end
            return
        end
        model.tasks[taskId] = job
        model.inFlight = model.inFlight + 1
    end
end

local function poll(model, force)
    if model.preview then return end
    model.tokenRef = storage.get("token")
    model.hasToken = model.tokenRef ~= nil
    if not model.tokenRef then return end
    if model.syncing and not force then return end
    -- Forcing a refresh while the list request is already in flight would fetch
    -- every project twice; the in-flight one will fan out anyway.
    if model.projectsInFlight then return end
    model.syncing = true
    model.projectsInFlight = true
    model.syncStarted = time.monotonic()
    enqueue(model, "projects", config().server.api .. "/open/v1/project")
    pump(model)
end

-- A sync that stops answering is retired from both the render path and the
-- frame heartbeat; without this the footer would sit on "syncing" until the
-- next poll, and a dead request would never surface as an error.
local function expireSync(model)
    if not model.syncing or not model.syncStarted then return false end
    if time.monotonic() - model.syncStarted <= 15000 then return false end
    model.syncing = false
    model.projectsInFlight = false
    model.dataPending = 0
    scheduleRetry(model, "timeout")
    return true
end

local function findTask(model, id)
    local state = model.state
    if not state then return nil end
    for index = 1, #state.tasks do
        if state.tasks[index].id == id then return state.tasks[index] end
    end
    return nil
end

local function completeTask(model, id)
    if model.preview or model.done[id] or model.completing[id] then return end
    local entry = findTask(model, id)
    if not entry then return end
    if not id:match("^[%w_%-]+$") or not entry.projectId:match("^[%w_%-]+$") then return end

    -- Optimistic: the row keeps its place, strikes through, then leaves.
    model.completing[id] = true
    model.done[id] = { at = time.monotonic() }
    -- A host timer retires the row even if the animation loop stalls.
    schedule.after("done:" .. id, FLASH_MS)
    enqueue(model, "complete",
        config().server.api .. "/open/v1/project/" .. entry.projectId
        .. "/task/" .. id .. "/complete",
        { method = "POST", maxBytes = 16 * 1024, taskId = id })
    pump(model)
end

-- ---------------------------------------------------------------------------
-- Data
-- ---------------------------------------------------------------------------

local function indexTasks(list)
    for index = 1, #list do
        local entry = list[index]
        if entry.dueDay then
            -- A bare "YYYY-MM-DD" already names a calendar day. Running its UTC
            -- midnight through the local zone would move it a day earlier for
            -- anyone west of UTC, so the parsed day is used as-is.
            entry.dayIdx = entry.dueDay
            entry.hour, entry.min = 0, 0
        elseif entry.dueMs then
            local parts = time.parts(entry.dueMs)
            entry.dayIdx = ticktick.daysFromCivil(parts.year, parts.month, parts.day)
            entry.hour = parts.hour or 0
            entry.min = parts.min or 0
        end
    end
end

-- One request per project, so the flat task list is rebuilt from those slices
-- and a failed project only costs that project's rows.
local function rebuildState(model)
    local byProject = model.byProject or {}
    local projects = model.projects or {}
    local tasks = {}
    for projectId, list in pairs(byProject) do
        if projects[projectId] then
            for index = 1, #list do tasks[#tasks + 1] = list[index] end
        end
    end
    model.state = {
        projects = model.projects, list = model.projectList, tasks = tasks,
        columns = model.columns,
    }
    model.stateVersion = (model.stateVersion or 0) + 1
end

local function applyProjects(model, body)
    local list, folders, err = ticktick.parseProjects(body)
    if not list then
        model.error = "parse"
        model.errorDetail = err
        return false
    end

    model.projects, model.projectList = {}, list
    model.folders = folders or {}
    model.byProject = model.byProject or {}
    model.columns = model.columns or {}
    for index = 1, #list do model.projects[list[index].id] = list[index] end
    -- Keep the previous rows on screen while the refresh runs; only lists that
    -- disappeared are dropped here, so a poll never blanks the board.
    for id in pairs(model.byProject) do
        if not model.projects[id] then model.byProject[id] = nil end
    end
    model.error = nil
    model.errorDetail = nil

    -- Count only what this call actually queued. A forced refresh that lands
    -- while the previous fan-out is still running finds every URL already
    -- pending; counting those again would leave dataPending above zero for
    -- ever and pin the footer on "syncing" until the timeout ladder fired.
    local root = config().server.api .. "/open/v1/project/"
    local queued = 0
    for index = 1, #list do
        local project = list[index]
        if enqueue(model, "data", root .. project.id .. "/data",
            { projectId = project.id, maxBytes = model.maxBytes }) then
            queued = queued + 1
        end
    end
    model.dataPending = queued
    model.syncing = queued > 0 or model.inFlight > 0
    model.parseFailed = 0
    rebuildState(model)
    if #list == 0 then
        model.loadedAt = time.now()
        -- An account with no open projects still has to confirm the token.
        if model.justConnected then
            model.justConnected = false
            model.toast = {
                text = l10n.tr("lua_widget.ticktick_tasks.toast_connected", "0"),
                big = true,
            }
            model.toastAt = time.monotonic()
        end
    end
    return true
end

local function applyProjectData(model, job, body)
    local list, columns, err = ticktick.parseProjectTasks(body, job.projectId)
    if not list then
        -- One unreadable project must not take the whole board down: the other
        -- lists still have rows, and the previous rows for this one stay up.
        -- Only a cycle that parsed nothing surfaces as an error (see below).
        model.parseFailed = (model.parseFailed or 0) + 1
        model.errorDetail = "parse:" .. tostring(job.projectId) .. ":" .. tostring(err)
        return false
    end
    indexTasks(list)
    model.byProject = model.byProject or {}
    model.columns = model.columns or {}
    model.byProject[job.projectId] = list
    model.columns[job.projectId] = columns
    rebuildState(model)

    -- A task the server still reports as open was un-completed elsewhere, so it
    -- has to come back instead of staying hidden for the rest of the session.
    local restored = false
    for index = 1, #list do
        local id = list[index].id
        if model.hidden[id] and not model.done[id] then
            model.hidden[id] = nil
            restored = true
        end
    end
    if restored then model.hiddenVersion = model.hiddenVersion + 1 end
    return true
end

local function loadPreview(model)
    local spec = storage.get("previewTasks")
    if type(spec) ~= "string" or spec == "" then return end
    local now = clock()
    model.state = ticktick.previewState(spec, now.dayIdx, now.startMs)
    model.folders = model.state.folders or {}
    model.loadedAt = now.now
    model.error = nil
    model.stateVersion = (model.stateVersion or 0) + 1
end


local function boardFor(model, cfg, dayIdx, view, perDay)
    if not model.state then return nil end
    local key = table.concat({
        view, tostring(dayIdx), tostring(perDay),
        cfg.sort, cfg.offKey,
        tostring(model.stateVersion or 0), tostring(model.hiddenVersion or 0),
    }, "|")
    local cached = model.boards[key]
    if cached then return cached end

    local board
    if view == "months" then
        board = ticktick.composeMonths(model.state, {
            today = dayIdx,
            hidden = model.hidden,
            sort = cfg.sort,
            off = cfg.off,
        })
    elseif view == "projects" then
        board = ticktick.composeProjects(model.state, {
            today = dayIdx,
            perProject = perDay,
            hidden = model.hidden,
            sort = cfg.sort,
            off = cfg.off,
        })
    else
        board = ticktick.compose(model.state, {
            today = dayIdx,
            days = view == "week" and 7 or 1,
            perDay = perDay,
            hidden = model.hidden,
            sort = cfg.sort,
            off = cfg.off,
        })
    end
    -- A handful of keys covers both the today/week probes and a resize; the
    -- table is dropped wholesale rather than growing with every span.
    if model.boardCount >= 8 then
        model.boards, model.boardCount = {}, 0
    end
    model.boards[key] = board
    model.boardCount = model.boardCount + 1
    return board
end

local function projectOf(model, id)
    local state = model.state
    local project = state and state.projects[id]
    if project then return project end
    return {
        id = id, name = "", inbox = false, closed = false,
        color = ticktick.fallbackColor(id or ""),
    }
end

local function projectName(project)
    if project.inbox then return l10n.tr("lua_widget.ticktick_tasks.inbox") end
    if project.name and project.name ~= "" then return project.name end
    return l10n.tr("lua_widget.ticktick_tasks.project_unnamed")
end

-- ---------------------------------------------------------------------------
-- Drawing helpers
-- ---------------------------------------------------------------------------

-- The frame measures the same labels several times (row text, clip width,
-- centring); one small cache keeps that off the host bridge.
local measureCache, measureCount = {}, 0
local function measure(text, size, bold)
    local key = text .. "|" .. tostring(size) .. "|" .. (bold and "1" or "0")
    local hit = measureCache[key]
    if hit then return hit end
    local metrics = draw.measureText(text, size, 0, bold or false)
    if measureCount >= 512 then
        measureCache, measureCount = {}, 0
    end
    measureCache[key] = metrics
    measureCount = measureCount + 1
    return metrics
end

local function textAt(text, x, y, size, color, maxWidth, bold, alpha)
    draw.text(x, y, text, size, color, maxWidth, bold or false, true, 0, alpha or 1)
end

-- measureText() with a maxWidth reports the wrapped block height while
-- draw.text(..., singleLine=true) paints one line, so single-line labels are
-- centred on a plain line box.
local function textMid(text, x, centerY, size, color, maxWidth, bold, alpha)
    local metrics = measure("Ag", size, bold)
    textAt(text, x, centerY - metrics.height / 2, size, color, maxWidth, bold, alpha)
end

-- room caps the label when it must not run into what sits to its left; the
-- text is clipped from the right edge, so it can never grow past `right`.
local function textRight(text, right, centerY, size, color, bold, alpha, room)
    local metrics = measure(text, size, bold)
    local width = math.min(metrics.width, room or metrics.width)
    textAt(text, right - width, centerY - metrics.height / 2, size, color,
        math.max(1, width + 1), bold, alpha)
    return width
end

local function textWidth(text, size, bold)
    return measure(text, size, bold).width
end

local function clamp(value, low, high)
    if value < low then return low end
    if value > high then return high end
    return value
end

-- Centre a single-line label inside a box and report the width it may use.
-- Clamping first matters: centring on a label wider than the box pushes its
-- start left of the box, and the host clips from there instead of centring.
local function centeredBox(text, boxLeft, boxWidth, size, bold, room)
    local maxWidth = math.max(1, math.min(boxWidth, room or boxWidth))
    local width = math.min(textWidth(text, size, bold), maxWidth)
    return boxLeft + (boxWidth - width) / 2, width
end

local function regionSpec(spec, tooltip)
    if tooltip and tooltipSupported then spec.tooltip = tooltip end
    interaction.region(spec)
end

-- A circle ring: a rounded rect whose radius is half its size is exact.
local function ring(cx, cy, radius, color, thickness, alpha)
    if radius < 1 then return end
    draw.strokeRect(cx - radius, cy - radius, radius * 2, radius * 2, color,
        radius, math.max(1, thickness), alpha)
end

local function disc(cx, cy, radius, color, alpha)
    if radius < 1 then return end
    draw.rect(cx - radius, cy - radius, radius * 2, radius * 2, color, radius, alpha)
end

local function checkMark(cx, cy, radius, color, thickness, alpha)
    local weight = math.max(1.2, thickness * 1.15)
    draw.line(cx - radius * 0.42, cy + radius * 0.02,
        cx - radius * 0.10, cy + radius * 0.34, weight, color, alpha)
    draw.line(cx - radius * 0.10, cy + radius * 0.34,
        cx + radius * 0.46, cy - radius * 0.30, weight, color, alpha)
end

-- ---------------------------------------------------------------------------
-- Labels
-- ---------------------------------------------------------------------------

local function dayLabel(dayIdx, todayIdx, todayWday)
    local delta = dayIdx - todayIdx
    if delta == 0 then return l10n.tr("lua_widget.ticktick_tasks.day_today") end
    if delta == 1 then return l10n.tr("lua_widget.ticktick_tasks.day_tomorrow") end

    -- Weekday arithmetic from the known weekday of today.
    local wday = ((todayWday - 1 + delta) % 7) + 1
    local date = civilDate(dayIdx)
    if isZh() then
        return string.format("%d月%d日 · 周%s", date.month, date.day, weekdayLabel(wday))
    end
    return string.format("%s %d · %s", MONTHS[date.month], date.day, weekdayLabel(wday))
end

-- TickTick stores the wall-clock time the user picked, so the row prints those
-- fields directly instead of asking the host for a locale-formatted timestamp
-- (whose "short" style still carries a date).
local function clockText(hour, minute)
    if isZh() then return string.format("%02d:%02d", hour, minute) end
    local display = hour % 12
    if display == 0 then display = 12 end
    return string.format("%d:%02d %s", display, minute, hour < 12 and "AM" or "PM")
end

local function dueTimeText(entry)
    return clockText(entry.hour or 0, entry.min or 0)
end

local function overdueText(entry, todayIdx)
    local delta = todayIdx - entry.dayIdx
    if entry.allDay then
        if delta == 1 then return l10n.tr("lua_widget.ticktick_tasks.day_yesterday") end
        local date = civilDate(entry.dayIdx)
        return string.format("%d/%d", date.month, date.day)
    end
    local timeText = dueTimeText(entry)
    if delta == 1 then
        return l10n.tr("lua_widget.ticktick_tasks.day_yesterday") .. " " .. timeText
    end
    local date = civilDate(entry.dayIdx)
    return string.format("%d/%d %s", date.month, date.day, timeText)
end

-- ---------------------------------------------------------------------------
-- Frame
-- ---------------------------------------------------------------------------

local function buildFrame(context, model)
    local width = layout.contentWidth()
    local height = layout.contentHeight()
    if width < 40 or height < 22 then return nil end

    local c = palette(context)
    local cfg = config()
    local now = clock()
    local compact = layout.rows() <= 1
    local short = math.min(width, height)
    local hair = math.max(1, short * 0.0022)
    c.hair = hair

    local inset = short * 0.045
    local left = inset
    local right = width - inset
    local top = inset
    local bottom = height - inset
    local usableWidth = math.max(1, right - left)
    local usableHeight = math.max(1, bottom - top)

    local rowUnit = ui.metrics().layoutRowHeight
    local headerHeight = math.min(usableHeight * 0.24, rowUnit * 1.30)
    local footerHeight = math.min(usableHeight * 0.15, rowUnit * 0.92)
    local bodyTop = top + headerHeight
    local bodyBottom = bottom - footerHeight

    local titleFont, metaFont, rowHeight, bodyHeight
    if compact then
        headerHeight, footerHeight = usableHeight, 0
        bodyTop, bodyBottom = top, top
        bodyHeight = usableHeight
        titleFont = math.min(rowUnit * 0.50, usableHeight * 0.24)
        metaFont = titleFont * 0.76
        rowHeight = usableHeight
    else
        bodyHeight = math.max(1, bodyBottom - bodyTop)
        -- Row type is capped by the row unit and by the width: a tall narrow
        -- card must not get headline rows, and a wide one must not get
        -- billboard-size titles. The date keeps a visible step below the
        -- title (0.76) instead of matching it, so the eye lands on the task.
        titleFont = math.min(rowUnit * 0.50, bodyHeight * 0.28, usableHeight * 0.16,
            usableWidth * 0.047)
        metaFont = math.max(titleFont * 0.62,
            math.min(titleFont * 0.76, rowUnit * 0.36, headerHeight * 0.26,
                usableWidth * 0.033))
        rowHeight = clamp(rowUnit * 1.02, titleFont * 1.72, bodyHeight / 2.35)
    end

    local parts = now.parts
    if model.toast and time.monotonic() - (model.toastAt or 0) >= TOAST_MS then
        model.toast = nil
    end
    expireSync(model)
    -- The board scrolls, so every row is kept; the host clamps the viewport and
    -- draws the scrollbar.
    local board = nil
    if not compact then
        board = boardFor(model, cfg, now.dayIdx, cfg.view, 999)
    end

    local rows, used = {}, 0
    if board then
        rows = board.rows
        for index = 1, #rows do
            local kind = rows[index].kind
            if kind == "task" then
                used = used + 1
            elseif kind == "column" then
                used = used + ticktick.columnCost
            else
                used = used + ticktick.groupCost
            end
        end
    end

    return {
        context = context, model = model, c = c, cfg = cfg,
        width = width, height = height, short = short, hair = hair,
        left = left, right = right, top = top, bottom = bottom,
        usableWidth = usableWidth, usableHeight = usableHeight,
        headerHeight = headerHeight, footerHeight = footerHeight,
        bodyTop = bodyTop, bodyBottom = bodyBottom, bodyHeight = bodyHeight,
        bodyWidth = usableWidth,
        rowUnit = rowUnit, rowHeight = rowHeight,
        titleFont = titleFont, metaFont = metaFont,
        -- The row's right-hand date is the second thing people read after the
        -- title, so it is set at the title's size; only the project label and
        -- the item count stay one step below.
        dateFont = titleFont,
        headerFont = math.max(7, math.min(rowUnit * 0.32, headerHeight * 0.28)),
        dayFont = math.min(headerHeight * 0.54, rowUnit * 0.84),
        clock = now, parts = parts,
        compact = compact,
        board = board, rows = rows,
        contentHeight = math.max(0, math.floor(used * rowHeight + rowHeight * 0.24)),
        todayIdx = now.dayIdx, todayWday = parts.wday,
        thisMonth = parts.year * 100 + parts.month,
        view = cfg.view,
    }
end

-- ---------------------------------------------------------------------------
-- Header
-- ---------------------------------------------------------------------------

local function drawViewPills(f, midY, centerX, pillHeight, maxWidth)
    local c = f.c
    local pillRadius = pillHeight / 2
    local font = math.max(7, math.min(f.metaFont, pillHeight * 0.46))
    local labels, widths, total = {}, {}, 0
    for index = 1, #views do
        local label = l10n.tr(viewKeys[views[index]])
        local width = textWidth(label, font, false) + pillHeight * 0.66
        labels[index], widths[index] = label, width
        total = total + width
    end
    total = total + pillHeight * 0.12
    if maxWidth and total > maxWidth then return false end

    local x = centerX - total / 2
    draw.rect(x, midY - pillHeight / 2, total, pillHeight, c.track, pillRadius,
        c.trackAlpha)

    for index = 1, #views do
        local id = views[index]
        local label, width = labels[index], widths[index]
        local active = f.view == id
        if active then
            draw.rect(x, midY - pillHeight / 2, width, pillHeight, c.glass, pillRadius,
                c.glassAlpha * 2.4)
            draw.strokeRect(x, midY - pillHeight / 2, width, pillHeight, c.line,
                pillRadius, f.hair, c.lineAlpha * 1.2)
        end
        local boxX, boxWidth = centeredBox(label, x, width, font, false, width - 4)
        textMid(label, boxX, midY, font, active and c.ink or c.muted, boxWidth, false)
        regionSpec({
            key = "view:" .. id,
            shape = { type = "roundedRect", x = x, y = midY - pillHeight / 2,
                width = width, height = pillHeight, radius = pillRadius },
            cursor = "hand",
            events = { click = { id = "view.set", value = id },
                contextMenu = { id = "task.menu", scope = "component" } },
            accessibility = { role = "button", label = label },
        })
        x = x + width
    end
    return true
end

local function drawHeader(f)
    local c = f.c
    local midY = f.top + f.headerHeight / 2

    local dayText = tostring(f.parts.day)
    local dayWidth = textWidth(dayText, f.dayFont, true)
    textMid(dayText, f.left, midY, f.dayFont, c.ink, dayWidth + 1, true)

    local dividerX = f.left + dayWidth + f.dayFont * 0.38
    draw.line(dividerX, midY - f.dayFont * 0.40, dividerX, midY + f.dayFont * 0.40,
        f.hair, c.line, c.lineAlpha * 1.4)

    local monthText = isZh() and string.format("%d月", f.parts.month) or MONTHS[f.parts.month]
    local weekdayText = isZh() and ("周" .. weekdayLabel(f.parts.wday))
        or weekdayLabel(f.parts.wday)
    local smallFont = math.max(7, math.min(f.headerFont, f.headerHeight * 0.30))
    local stackGap = f.headerHeight * 0.29
    local textX = dividerX + f.dayFont * 0.36
    textMid(monthText, textX, midY - stackGap, smallFont, c.ink2, 0, false, 0.92)
    textMid(weekdayText, textX, midY + stackGap, smallFont, c.muted)

    -- Counts sit at the far right; the view switch lives in the footer.
    local total = f.board and f.board.count or 0
    local overdue = f.board and f.board.overdue or 0
    local countsFont = math.min(f.titleFont, f.headerHeight * 0.34)
    local metaX = textX + math.max(textWidth(monthText, smallFont, false),
        textWidth(weekdayText, smallFont, false)) + f.dayFont * 0.62
    local right = f.right
    local candidates = {
        l10n.tr("lua_widget.ticktick_tasks.header_counts_both",
            l10n.formatNumber(total), l10n.formatNumber(overdue)),
        l10n.tr("lua_widget.ticktick_tasks.header_counts", l10n.formatNumber(total)),
    }
    if f.board then
        for index = 1, #candidates do
            local candidate = candidates[index]
            if right - textWidth(candidate, countsFont, false) > metaX then
                textRight(candidate, right, midY, countsFont, c.ink2, false, 0.92)
                break
            end
        end
    end
end

-- ---------------------------------------------------------------------------
-- Rows
-- ---------------------------------------------------------------------------

local function drawGroupRow(f, row, y, height)
    local c = f.c
    local midY = y + height / 2
    local font = math.max(7, math.min(f.titleFont * 0.74, f.metaFont * 1.06))
    local lineStart

    if row.year then
        local label = isZh() and string.format("%d年%d月", row.year, row.month)
            or string.format("%s %d", MONTHS[row.month], row.year)
        local color = (row.year * 100 + row.month == f.thisMonth) and c.ink2 or c.faint
        textMid(label, f.left, midY, font, color, f.bodyWidth, true)
        lineStart = f.left + textWidth(label, font, true) + f.hair * 6
    elseif row.undated then
        local label = l10n.tr("lua_widget.ticktick_tasks.group_undated")
        textMid(label, f.left, midY, font, c.faint, f.bodyWidth, true)
        lineStart = f.left + textWidth(label, font, true) + f.hair * 6
    elseif row.kind == "column" then
        -- A kanban column sits under its project: a short rule plus the name.
        local label = (row.name and row.name ~= "")
            and row.name or l10n.tr("lua_widget.ticktick_tasks.group_no_column")
        local inset = f.titleFont * 1.1
        local named = row.name and row.name ~= ""
        draw.line(f.left + inset * 0.45, midY - height * 0.34,
            f.left + inset * 0.45, midY + height * 0.34,
            math.max(1, f.hair * 1.4), named and c.accent or c.line,
            named and 0.85 or c.lineAlpha)
        textMid(label, f.left + inset, midY, font, named and c.ink2 or c.faint,
            f.bodyWidth - inset, true)
        lineStart = f.left + inset + textWidth(label, font, true) + f.hair * 6
    elseif row.projectId then
        -- Project groups carry the list's own colour, the way the app's sidebar
        -- does, so a list is recognisable without reading its name.
        local project = projectOf(f.model, row.projectId)
        local name = projectName(project)
        local dot = math.max(1.8, font * 0.24)
        disc(f.left + dot, midY, dot, project.color, 0.95)
        local textX = f.left + dot * 2 + font * 0.55
        textMid(name, textX, midY, font, c.ink2, f.bodyWidth * 0.72, true)
        lineStart = textX + math.min(textWidth(name, font, true), f.bodyWidth * 0.72)
            + f.hair * 6
    else
        local label = row.overdue and l10n.tr("lua_widget.ticktick_tasks.group_overdue")
            or dayLabel(row.dayIdx, f.todayIdx, f.todayWday)
        local color = row.overdue and c.bad or c.faint
        textMid(label, f.left, midY, font, color, f.bodyWidth, true)
        lineStart = f.left + textWidth(label, font, true) + f.hair * 6
    end

    if lineStart < f.right - f.dayFont * 2 then
        draw.line(lineStart, midY, f.right - font * 1.9, midY, f.hair, c.line,
            c.lineAlpha * 0.75)
    end
    textRight(l10n.formatNumber(row.count), f.right, midY, font, c.faint, false, 0.8)
end

local function drawTaskRow(f, row, y, height)
    local c = f.c
    local model = f.model
    local entry = row.task
    local project = projectOf(model, entry.projectId)
    local flash = model.done[entry.id]
    local progress = flash and clamp((time.monotonic() - flash.at) / FLASH_MS, 0, 1) or 0

    local hoverKey = "task:" .. entry.id
    local checkKey = "check:" .. entry.id
    -- A row cut by the viewport must not register a hit area over the footer.
    local regionTop = math.max(y, f.clipTop or y)
    local regionBottom = math.min(y + height, f.clipBottom or (y + height))
    local rowClickable = regionBottom - regionTop > 2
    local hovered = interaction.isHovered(hoverKey)
    local checkHovered = interaction.isHovered(checkKey)
    local radius = math.min(height * 0.23, f.titleFont * 0.78)
    local midY = y + height / 2
    local cx = f.left + radius + f.hair * 2
    local rowRadius = math.min(height * 0.28, f.hair * 9)

    if hovered then
        draw.rect(f.left - f.short * 0.012, y + 1, f.bodyWidth + f.short * 0.024,
            height - 2, c.glass, rowRadius, c.glassAlpha * 1.7)
    end

    local accent = c.priority[entry.priority] or c.priority[0]
    local checked = progress > 0.18
    if checked then
        disc(cx, midY, radius, accent, 0.95 * clamp(progress * 2, 0, 1))
    elseif checkHovered then
        -- Hovering the ring previews the check without touching the server.
        disc(cx, midY, radius - f.hair, accent, 0.16)
    end
    ring(cx, midY, radius, accent, f.hair * 1.6,
        (entry.priority == 0 and 0.55 or 0.85) * (1 - progress * 0.2))
    if checked then
        checkMark(cx, midY, radius, c.onAccent, f.hair * 1.6,
            clamp((progress - 0.18) / 0.3, 0, 1))
    elseif checkHovered then
        checkMark(cx, midY, radius, accent, f.hair * 1.5, 0.6)
    end

    local titleX = cx + radius + f.hair * 7
    local titleAlpha = 1 - progress * 0.55

    -- Right block: time (with its date when overdue), item count and project.
    local timeText, timeColor = nil, c.ink2
    if f.view == "months" then
        -- Inside a month the day is the useful part, even for today.
        if entry.dueMs then
            local date = civilDate(entry.dayIdx)
            if entry.allDay then
                timeText = string.format("%d/%d", date.month, date.day)
            else
                timeText = string.format("%d/%d %s", date.month, date.day,
                    dueTimeText(entry))
            end
            if entry.dayIdx and entry.dayIdx < f.todayIdx then timeColor = c.bad end
        end
    elseif f.view == "projects" then
        -- A list mixes days, so the date matters more than the clock.
        if entry.dueMs then
            local date = civilDate(entry.dayIdx)
            if entry.allDay then
                timeText = string.format("%d/%d", date.month, date.day)
            elseif entry.dayIdx == f.todayIdx then
                timeText = dueTimeText(entry)
            else
                timeText = string.format("%d/%d %s", date.month, date.day,
                    dueTimeText(entry))
            end
            if entry.dayIdx and entry.dayIdx < f.todayIdx then timeColor = c.bad end
        end
    elseif row.overdue then
        -- An overdue all-day task needs its day ("Yesterday", "11/3"), not the
        -- word "all day" — the colour alone does not say how late it is.
        timeText = overdueText(entry, f.todayIdx)
    elseif entry.allDay then
        timeText = l10n.tr("lua_widget.ticktick_tasks.all_day")
    else
        timeText = dueTimeText(entry)
    end
    if row.overdue then
        timeColor = c.bad
    elseif entry.dueMs and entry.dayIdx == f.todayIdx
        and entry.dueMs >= f.clock.now and entry.dueMs - f.clock.now <= DUE_SOON_MS then
        timeColor = c.warn
    end

    local metaLeft = f.right
    if timeText then
        local timeWidth = textWidth(timeText, f.dateFont, false)
        local timeX = f.right - timeWidth
        textMid(timeText, timeX, midY, f.dateFont, timeColor, timeWidth + 1, false,
            titleAlpha)
        metaLeft = timeX - f.dateFont * 0.9
    end
    if entry.itemsTotal > 0 then
        local itemText = l10n.tr("lua_widget.ticktick_tasks.items", entry.itemsDone,
            entry.itemsTotal)
        local itemWidth = textWidth(itemText, f.metaFont, false)
        textMid(itemText, metaLeft - itemWidth, midY, f.metaFont, c.faint,
            itemWidth + 1, false, titleAlpha * 0.9)
        metaLeft = metaLeft - itemWidth - f.metaFont * 0.7
    end

    local projectText = f.view == "projects" and "" or projectName(project)
    local titleFloor = f.bodyWidth * 0.45
    local roomForProject = metaLeft - titleX - titleFloor
    if projectText ~= "" and roomForProject > f.metaFont * 2.4 then
        local projectWidth = math.min(textWidth(projectText, f.metaFont, false),
            roomForProject - f.metaFont * 1.6)
        if projectWidth > f.metaFont * 1.2 then
            local projectX = metaLeft - f.metaFont * 0.75 - projectWidth
            disc(projectX - f.metaFont * 0.62, midY, math.max(1.5, f.metaFont * 0.17),
                project.color, 0.95 * titleAlpha)
            textMid(projectText, projectX, midY, f.metaFont, c.muted, projectWidth,
                false, titleAlpha * 0.85)
            metaLeft = projectX - f.metaFont * 0.9
        end
    end

    local titleLimit = math.max(1, metaLeft - titleX)
    local titleWidth = math.min(textWidth(entry.title, f.titleFont, false), titleLimit)
    textMid(entry.title, titleX, midY, f.titleFont, c.ink, titleLimit, false, titleAlpha)

    if progress > 0.05 then
        local strikeWidth = titleWidth * clamp((progress - 0.05) / 0.45, 0, 1)
        draw.line(titleX - f.hair, midY, titleX + strikeWidth, midY,
            math.max(1, f.titleFont * 0.075), c.ink, 0.55 * (1 - progress * 0.5))
    end

    if rowClickable then
        regionSpec({
            key = hoverKey,
            shape = { type = "roundedRect", x = f.left, y = regionTop,
                width = f.bodyWidth, height = regionBottom - regionTop,
                radius = rowRadius },
            cursor = "hand",
            events = {
                click = { id = "task.open", value = entry.id },
                contextMenu = { id = "task.menu", scope = "component", value = entry.id },
            },
            accessibility = { role = "button", label = entry.title },
        }, l10n.tr("lua_widget.ticktick_tasks.tooltip_task"))

        regionSpec({
            key = checkKey,
            shape = { type = "roundedRect", x = cx - radius * 1.3, y = midY - radius * 1.3,
                width = radius * 2.6, height = radius * 2.6, radius = radius * 1.3 },
            cursor = "hand",
            events = { click = { id = "task.complete", value = entry.id } },
            accessibility = {
                role = "button",
                label = l10n.tr("lua_widget.ticktick_tasks.complete_label", entry.title),
            },
        }, l10n.tr("lua_widget.ticktick_tasks.tooltip_complete"))
    end
end

local function drawRows(f)
    if #f.rows == 0 then return end
    -- The host owns the wheel, clamping and the scrollbar; the component only
    -- maps content coordinates into the viewport and clips.
    local scroll = interaction.scroll({
        key = "rows",
        shape = { type = "rect", x = f.left, y = f.bodyTop,
            width = f.bodyWidth, height = f.bodyHeight },
        contentHeight = math.max(1, f.contentHeight),
    })
    local offset = scroll and scroll.offset or 0
    local topPad = f.rowHeight * 0.12

    f.clipTop, f.clipBottom = f.bodyTop, f.bodyBottom
    draw.pushClip(f.left - 2, f.bodyTop, f.bodyWidth + 4, f.bodyHeight)
    local y = f.bodyTop + topPad - offset
    for index = 1, #f.rows do
        local row = f.rows[index]
        local height = f.rowHeight
        if row.kind == "group" then
            height = f.rowHeight * ticktick.groupCost
        elseif row.kind == "column" then
            height = f.rowHeight * ticktick.columnCost
        end
        if y + height > f.bodyTop - 1 and y < f.bodyBottom + 1 then
            if row.kind == "task" then
                drawTaskRow(f, row, y, f.rowHeight)
            else
                drawGroupRow(f, row, y, height)
            end
        end
        y = y + height
    end
    draw.popClip()
end

-- ---------------------------------------------------------------------------
-- Footer
-- ---------------------------------------------------------------------------

local function drawFooter(f)
    local c, model = f.c, f.model
    local midY = f.bodyBottom + f.footerHeight / 2
    local font = math.max(7, f.metaFont * 0.94)

    local statusText, statusColor, shortStatus
    if model.toast and not model.toast.big then
        statusText = model.toast.text
        statusColor = model.toast.error and c.bad or c.good
    elseif not model.tokenRef then
        statusText = l10n.tr("lua_widget.ticktick_tasks.status_unlinked")
        statusColor = c.accent
    elseif model.error then
        statusText = l10n.tr("lua_widget.ticktick_tasks.status_offline")
        statusColor = c.bad
    elseif model.syncing or not model.loadedAt then
        statusText = l10n.tr("lua_widget.ticktick_tasks.status_syncing")
        statusColor = c.muted
    elseif (model.parseFailed or 0) > 0 then
        -- One list was too large to decode in a single callback; the rest of
        -- the board is fine, so say "partly" instead of pretending all is well.
        statusText = l10n.tr("lua_widget.ticktick_tasks.status_partial")
        statusColor = c.warn
    else
        local syncedParts = time.parts(model.loadedAt)
        local syncedClock = clockText(syncedParts.hour or 0, syncedParts.min or 0)
        statusText = l10n.tr("lua_widget.ticktick_tasks.footer_synced", syncedClock)
        -- On a narrow card the prefix is what gives way, not the state: the
        -- dot and the bare clock still say "this is when it last synced".
        shortStatus = syncedClock
        statusColor = c.muted
    end
    shortStatus = shortStatus or statusText

    local dotRadius = math.max(1.6, font * 0.20)
    local textX = f.left + dotRadius * 2 + font * 0.55
    -- Reserve the width of the longest normal status line, not the live text:
    -- a status that changes every few seconds must not move the view switch.
    -- The sample clock follows the locale, so English ("11:59 PM") reserves
    -- more room than Chinese ("23:59") instead of clipping itself.
    local statusReserve = textWidth(l10n.tr("lua_widget.ticktick_tasks.footer_synced",
        clockText(23, 59)), font, false) + font * 0.4
    local statusWidth = math.min(textWidth(statusText, font, false), statusReserve)
    local shortWidth = math.min(textWidth(shortStatus, font, false), statusReserve)

    local rightEdge = f.right
    local refreshLeft = f.right
    -- Manual refresh: a compact glyph button, always reachable.
    local buttonSize = math.min(f.footerHeight * 0.78, font * 2.0)
    if not f.model.filterOpen and buttonSize > 6 then
        local bx = rightEdge - buttonSize
        local hovered = interaction.isHovered("refresh-button")
        draw.rect(bx, midY - buttonSize / 2, buttonSize, buttonSize, c.glass,
            buttonSize / 2, hovered and c.glassAlpha * 3 or c.glassAlpha * 1.8)
        draw.fluent(glyph.refresh, bx + buttonSize * 0.26, midY - buttonSize * 0.24,
            buttonSize * 0.48, hovered and c.ink or c.muted)
        regionSpec({
            key = "refresh-button",
            shape = { type = "roundedRect", x = bx, y = midY - buttonSize / 2,
                width = buttonSize, height = buttonSize, radius = buttonSize / 2 },
            cursor = "hand",
            events = { click = { id = "refresh" } },
            accessibility = { role = "button",
                label = l10n.tr("lua_widget.ticktick_tasks.menu_refresh") },
        })
        refreshLeft = bx
        rightEdge = rightEdge - buttonSize - f.metaFont * 0.6
    end

    if f.model.filterOpen then
        local doneLabel = l10n.tr("lua_widget.ticktick_tasks.filter_done")
        local allLabel = l10n.tr("lua_widget.ticktick_tasks.menu_show_all")
        local height = math.min(f.footerHeight * 0.72, font * 1.9)
        local allWidth = textWidth(allLabel, font, false) + font * 1.6
        local doneWidth = textWidth(doneLabel, font, true) + font * 1.6
        local gap = font * 0.6
        local x = f.right - doneWidth - gap - allWidth
        draw.rect(x, midY - height / 2, allWidth, height, c.glass, height / 2,
            c.glassAlpha * 1.8)
        local allX, allBox = centeredBox(allLabel, x, allWidth, font, false,
            allWidth - 2)
        textMid(allLabel, allX, midY, font, c.muted, allBox, false)
        regionSpec({
            key = "filter-all",
            shape = { type = "roundedRect", x = x, y = midY - height / 2,
                width = allWidth, height = height, radius = height / 2 },
            cursor = "hand",
            events = { click = { id = "filter.all" } },
            accessibility = { role = "button", label = allLabel },
        })
        local doneX = x + allWidth + gap
        draw.rect(doneX, midY - height / 2, doneWidth, height, c.accent, height / 2, 0.95)
        local labelX, labelBox = centeredBox(doneLabel, doneX, doneWidth, font, true,
            doneWidth - 2)
        textMid(doneLabel, labelX, midY, font, c.onAccent, labelBox, true)
        regionSpec({
            key = "filter-done",
            shape = { type = "roundedRect", x = doneX, y = midY - height / 2,
                width = doneWidth, height = height, radius = height / 2 },
            cursor = "hand",
            events = { click = { id = "filter.close" } },
            accessibility = { role = "button", label = doneLabel },
        })
        return
    end
    -- Filter entry: a chip that reports how many lists are switched off.
    local offCount = 0
    for _ in pairs(f.cfg.off) do offCount = offCount + 1 end
    local filterLabel = offCount > 0
        and l10n.tr("lua_widget.ticktick_tasks.filter_on", l10n.formatNumber(offCount))
        or l10n.tr("lua_widget.ticktick_tasks.filter_off")
    local filterWidth = textWidth(filterLabel, font, true) + font * 1.5
    local filterHeight = math.min(f.footerHeight * 0.72, font * 1.9)
    if filterWidth < f.bodyWidth * 0.34 then
        draw.rect(rightEdge - filterWidth, midY - filterHeight / 2, filterWidth,
            filterHeight, c.glass, filterHeight / 2, c.glassAlpha * 1.8)
        draw.strokeRect(rightEdge - filterWidth, midY - filterHeight / 2, filterWidth,
            filterHeight, c.line, filterHeight / 2, f.hair, c.lineAlpha)
        local boxX, boxWidth = centeredBox(filterLabel, rightEdge - filterWidth,
            filterWidth, font, true, filterWidth - 2)
        textMid(filterLabel, boxX, midY, font, offCount > 0 and c.accent or c.muted,
            boxWidth, true)
        regionSpec({
            key = "filter-button",
            shape = { type = "roundedRect", x = rightEdge - filterWidth,
                y = midY - filterHeight / 2, width = filterWidth,
                height = filterHeight, radius = filterHeight / 2 },
            cursor = "hand",
            events = { click = { id = "filter.open" } },
            accessibility = { role = "button", label = filterLabel },
        })
        rightEdge = rightEdge - filterWidth - f.metaFont * 0.9
    end

    -- View switch. The band is reserved from fixed widths, never from the live
    -- status text or filter count: those change every few seconds and made the
    -- switch jump and vanish mid-refresh.
    local filterReserve = textWidth(l10n.tr("lua_widget.ticktick_tasks.filter_on", "99"),
        font, true) + font * 1.5
    local rightLimit = refreshLeft - filterReserve - f.metaFont * 1.5
    local pillHeight = math.min(f.footerHeight * 0.74, f.rowUnit * 0.74)
    local widgetCenter = f.left + f.bodyWidth / 2

    local function drawSwitch(leftEdge)
        local space = rightLimit - leftEdge
        if space <= pillHeight * 3.2 then return false end
        local centered = math.min(widgetCenter - leftEdge, rightLimit - widgetCenter) * 2
        if centered > 0
            and drawViewPills(f, midY, widgetCenter, pillHeight, centered) then
            return true
        end
        local gapCenter = (leftEdge + rightLimit) / 2
        if drawViewPills(f, midY, gapCenter, pillHeight, space) then return true end
        return drawViewPills(f, midY, gapCenter, pillHeight * 0.85, space)
    end

    -- The dot is always drawn: its colour is the state cue that survives every
    -- width, and a red dot must never disappear behind the view switch.
    disc(f.left + dotRadius, midY, dotRadius, statusColor, 0.9)

    local shownStatus = nil
    if drawSwitch(textX + statusReserve + font * 1.2) then
        shownStatus = statusText
    elseif drawSwitch(textX + shortWidth + font * 1.2) then
        -- The prefix ("Synced", "同步于") is the first thing to go.
        shownStatus = shortStatus
    elseif drawSwitch(textX) then
        -- A narrow card needs the switch more than it needs the text.
        shownStatus = nil
    end

    if shownStatus then
        local width = shownStatus == statusText and statusWidth or shortWidth
        textMid(shownStatus, textX, midY, font, statusColor, width + 1, false, 0.95)
    end
end

-- ---------------------------------------------------------------------------
-- Empty, setup and error states
-- ---------------------------------------------------------------------------

local function drawButton(f, x, y, width, height, label, actionId, primary)
    local c = f.c
    local hoverKey = "btn:" .. actionId .. ":" .. label
    local hovered = interaction.isHovered(hoverKey)
    local radius = math.min(height / 2, f.hair * 10)
    if primary then
        draw.rect(x, y, width, height, c.accent, radius, hovered and 1 or 0.94)
    else
        draw.rect(x, y, width, height, c.glass, radius,
            hovered and c.glassAlpha * 2.6 or c.glassAlpha * 1.6)
        draw.strokeRect(x, y, width, height, c.line, radius, f.hair,
            hovered and c.lineAlpha * 1.6 or c.lineAlpha)
    end
    local font = math.max(7, math.min(f.metaFont, height * 0.42))
    local boxX, boxWidth = centeredBox(label, x, width, font, true, width - f.hair * 6)
    textMid(label, boxX, y + height / 2, font, primary and c.onAccent or c.ink,
        boxWidth, true)
    regionSpec({
        key = hoverKey,
        shape = { type = "roundedRect", x = x, y = y, width = width, height = height,
            radius = radius },
        cursor = "hand",
        events = { click = { id = actionId } },
        accessibility = { role = "button", label = label },
    })
end

-- A centred notice: icon, title, hint and up to two buttons.
local function drawNotice(f, kind, title, hint, actions)
    local c = f.c
    local areaTop = f.bodyTop
    local areaBottom = f.bodyBottom
    local centerY = (areaTop + areaBottom) / 2
    local centerX = f.left + f.bodyWidth / 2

    local iconRadius = math.min((areaBottom - areaTop) * 0.16, f.rowUnit * 0.44)
    local titleFont = math.max(9, math.min(f.titleFont * 1.06, f.rowUnit * 0.48))
    local hintFont = math.max(7, f.metaFont)
    local buttonHeight = math.min(f.rowUnit * 0.78, (areaBottom - areaTop) * 0.22)
    local buttonFont = math.max(7, buttonHeight * 0.38)

    local hintWidth = f.bodyWidth * 0.84
    local hintLines = 0
    if hint and hint ~= "" then
        hintLines = math.max(1, math.floor(textWidth(hint, hintFont, false) / hintWidth) + 1)
    end
    local blockHeight = iconRadius * 2 + f.metaFont * 1.1 + titleFont * 1.5
        + hintLines * hintFont * 1.55
        + (#actions > 0 and buttonHeight + f.metaFont or 0)
    local y = centerY - blockHeight / 2

    local iconCY = y + iconRadius
    if kind == "error" then
        disc(centerX, iconCY, iconRadius, c.bad, 0.12)
        ring(centerX, iconCY, iconRadius, c.bad, f.hair * 1.8, 0.85)
        local mark = iconRadius * 0.40
        draw.line(centerX - mark, iconCY - mark, centerX + mark, iconCY + mark,
            math.max(1.4, f.hair * 1.8), c.bad, 0.9)
        draw.line(centerX + mark, iconCY - mark, centerX - mark, iconCY + mark,
            math.max(1.4, f.hair * 1.8), c.bad, 0.9)
    else
        disc(centerX, iconCY, iconRadius, c.accent, 0.14)
        ring(centerX, iconCY, iconRadius, c.accent, f.hair * 1.8,
            kind == "setup" and 0.9 or 0.75)
        checkMark(centerX, iconCY, iconRadius * 0.92, c.accent, f.hair * 1.9, 0.95)
    end

    y = iconCY + iconRadius + f.metaFont * 1.1
    local titleX, titleWidth = centeredBox(title, f.left, f.bodyWidth, titleFont, true)
    textMid(title, titleX, y + titleFont * 0.7, titleFont, c.ink, titleWidth, true)
    y = y + titleFont * 1.5

    if hintLines > 0 then
        local hintLeft = f.left + (f.bodyWidth - hintWidth) / 2
        local natural = textWidth(hint, hintFont, false)
        if natural <= hintWidth then
            -- A short hint reads as a caption, so it is centred like the title.
            textMid(hint, centerX - natural / 2, y + hintFont * 0.78, hintFont,
                c.muted, natural + 1, false, 0.95)
        else
            draw.text(hintLeft, y, hint, hintFont, c.muted, hintWidth, false, false,
                hintLines * hintFont * 1.55, 0.95)
        end
        y = y + hintLines * hintFont * 1.55
    end

    if #actions > 0 then
        y = y + f.metaFont
        local gap = f.metaFont * 0.55
        local widths, total = {}, 0
        for index = 1, #actions do
            widths[index] = math.max(buttonHeight * 2.4,
                textWidth(actions[index].label, buttonFont, true) + buttonHeight * 0.9)
            total = total + widths[index] + (index > 1 and gap or 0)
        end
        local x = centerX - total / 2
        if total > f.bodyWidth * 0.96 then
            -- Two labels wider than a narrow card: shrink the buttons (not the
            -- gaps) instead of letting the row spill past the rounded edges.
            local gaps = gap * (#actions - 1)
            local room = math.max(1, f.bodyWidth * 0.96 - gaps)
            local scale = room / math.max(1, total - gaps)
            for index = 1, #widths do widths[index] = widths[index] * scale end
            total = room + gaps
            x = centerX - total / 2
        end
        for index = 1, #actions do
            drawButton(f, x, y, widths[index], buttonHeight, actions[index].label,
                actions[index].id, actions[index].primary)
            x = x + widths[index] + gap
        end
    end
end

local function noticeFor(f)
    local model = f.model
    if not model.tokenRef then
        return "setup",
            l10n.tr("lua_widget.ticktick_tasks.setup_title"),
            l10n.tr("lua_widget.ticktick_tasks.setup_hint"),
            {
                { label = l10n.tr("lua_widget.ticktick_tasks.action_settings"),
                    id = "settings.open", primary = true },
                { label = l10n.tr("lua_widget.ticktick_tasks.action_open"),
                    id = "app.open" },
            }
    end
    if model.error == "auth" then
        return "error",
            l10n.tr("lua_widget.ticktick_tasks.error_auth_title"),
            l10n.tr("lua_widget.ticktick_tasks.error_auth_hint"),
            {
                { label = l10n.tr("lua_widget.ticktick_tasks.action_settings"),
                    id = "settings.open", primary = true },
                { label = l10n.tr("lua_widget.ticktick_tasks.action_open"),
                    id = "app.open" },
            }
    end
    if model.error and not model.state then
        local timeout = model.error == "timeout"
        if timeout then
            -- A silent hang almost always means the stored secret can no
            -- longer be decrypted, so send the user straight to settings.
            return "error",
                l10n.tr("lua_widget.ticktick_tasks.error_timeout_title"),
                l10n.tr("lua_widget.ticktick_tasks.error_timeout_hint"),
                {
                    { label = l10n.tr("lua_widget.ticktick_tasks.action_settings"),
                        id = "settings.open", primary = true },
                    { label = l10n.tr("lua_widget.ticktick_tasks.action_retry"),
                        id = "refresh" },
                }
        end
        if model.error == "parse" then
            -- The network is fine; saying "offline" would send the user to
            -- check a router that is not the problem.
            return "error",
                l10n.tr("lua_widget.ticktick_tasks.error_parse_title"),
                l10n.tr("lua_widget.ticktick_tasks.error_parse_hint"),
                {
                    { label = l10n.tr("lua_widget.ticktick_tasks.action_retry"),
                        id = "refresh", primary = true },
                }
        end
        return "error",
            l10n.tr(model.error == "tooLarge"
                and "lua_widget.ticktick_tasks.error_big_title"
                or "lua_widget.ticktick_tasks.error_offline_title"),
            l10n.tr(model.error == "tooLarge"
                and "lua_widget.ticktick_tasks.error_big_hint"
                or "lua_widget.ticktick_tasks.error_offline_hint"),
            {
                { label = l10n.tr("lua_widget.ticktick_tasks.action_retry"),
                    id = "refresh", primary = true },
                { label = l10n.tr("lua_widget.ticktick_tasks.action_settings"),
                    id = "settings.open" },
            }
    end
    if model.state and #f.rows == 0 then
        -- Only blame the filter when it actually hides something; an empty day
        -- with a filter on is still just an empty day.
        local hiddenByFilter = 0
        for index = 1, #model.state.tasks do
            local entry = model.state.tasks[index]
            if entry.open and f.cfg.off[entry.projectId] then
                hiddenByFilter = hiddenByFilter + 1
            end
        end
        if hiddenByFilter > 0 then
            return "empty",
                l10n.tr("lua_widget.ticktick_tasks.empty_filtered_title"),
                l10n.tr("lua_widget.ticktick_tasks.empty_filtered_hint"),
                {
                    { label = l10n.tr("lua_widget.ticktick_tasks.menu_show_all"),
                        id = "project.all", primary = true },
                }
        end
        local week = f.view == "week"
        -- An empty day is the normal case for many accounts, and it looks
        -- exactly like a broken widget. Name the next task instead.
        local nextTask = nil
        if not week then
            for index = 1, #model.state.tasks do
                local entry = model.state.tasks[index]
                -- A task that was just checked off is still in the snapshot but
                -- must not be named as "next"; neither must a hidden list's.
                if entry.open and entry.dueMs and entry.dayIdx
                    and not model.hidden[entry.id] and not f.cfg.off[entry.projectId]
                    and entry.dueMs >= f.clock.now
                    and (not nextTask or entry.dueMs < nextTask.dueMs) then
                    nextTask = entry
                end
            end
        end
        if nextTask then
            return "empty",
                l10n.tr("lua_widget.ticktick_tasks.empty_today_title"),
                l10n.tr("lua_widget.ticktick_tasks.empty_today_next", nextTask.title,
                    dayLabel(nextTask.dayIdx, f.todayIdx, f.todayWday)),
                {
                    { label = l10n.tr("lua_widget.ticktick_tasks.view_week"),
                        id = "view.week", primary = true },
                    { label = l10n.tr("lua_widget.ticktick_tasks.action_open"),
                        id = "app.open" },
                }
        end
        local months = f.view == "months"
        local projects = f.view == "projects"
        return "empty",
            l10n.tr(months and "lua_widget.ticktick_tasks.empty_months_title"
                or (projects and "lua_widget.ticktick_tasks.empty_projects_title"
                    or (week and "lua_widget.ticktick_tasks.empty_week_title"
                        or "lua_widget.ticktick_tasks.empty_today_title"))),
            l10n.tr(months and "lua_widget.ticktick_tasks.empty_months_hint"
                or (projects and "lua_widget.ticktick_tasks.empty_projects_hint"
                    or (week and "lua_widget.ticktick_tasks.empty_week_hint"
                        or "lua_widget.ticktick_tasks.empty_today_hint"))),
            {
                { label = l10n.tr("lua_widget.ticktick_tasks.action_open"),
                    id = "app.open", primary = true },
                { label = l10n.tr("lua_widget.ticktick_tasks.action_refresh"),
                    id = "refresh" },
            }
    end
    if not model.state then
        return "setup",
            l10n.tr("lua_widget.ticktick_tasks.status_syncing"),
            l10n.tr("lua_widget.ticktick_tasks.hint_syncing"),
            {}
    end
    return nil
end

-- A floating confirmation for connection changes: the settings window has no
-- save button, so the board itself says whether the token landed.
local function drawToast(f)
    local toast = f.model.toast
    if not toast or not toast.big then return end
    local c = f.c
    local font = math.max(8, f.titleFont * 0.92)
    local pad = font * 0.85
    -- A narrow card would otherwise push the pill past both edges.
    local width = math.min(textWidth(toast.text, font, true) + pad * 2 + font * 1.5,
        f.bodyWidth - pad)
    local height = font * 1.25 + pad * 1.1
    local x = f.left + (f.bodyWidth - width) / 2
    local y = f.bodyBottom - height - f.metaFont * 0.7
    local radius = height / 2

    draw.rect(x, y, width, height, c.accent, radius, 0.96)
    local iconX = x + pad + font * 0.35
    checkMark(iconX, y + height / 2, font * 0.42, c.onAccent, f.hair * 1.7, 1)
    textMid(toast.text, iconX + font * 0.85, y + height / 2, font, c.onAccent,
        width - (iconX - x) - pad - font * 0.4, true)
end

-- An in-widget list of projects: the host owns right-click, so the filter has
-- to live on the surface itself.
local function drawFilterBoard(f)
    local c, model = f.c, f.model
    local cfg = f.cfg
    if not model.state then return end
    local rowHeight = math.min(f.rowHeight * 0.8, f.titleFont * 2.3)
    local y = f.bodyTop + rowHeight * 0.3
    local title = l10n.tr("lua_widget.ticktick_tasks.filter_title")
    textMid(title, f.left, y + rowHeight * 0.5, f.titleFont, c.ink, f.bodyWidth, true)
    y = y + rowHeight * 1.1

    -- One entry per folder (when projects carry a groupId) plus every project.
    local entries, folders = {}, {}
    local projects = model.state.list or {}
    for index = 1, #projects do
        local project = projects[index]
        if project.groupId then
            local folder = folders[project.groupId]
            if not folder then
                local known = model.folders and model.folders[project.groupId]
                folder = {
                    kind = "folder", id = project.groupId,
                    name = known and known.name or "", count = 0,
                }
                folders[project.groupId] = folder
                entries[#entries + 1] = folder
            end
            folder.count = folder.count + 1
        end
        entries[#entries + 1] = { kind = "project", project = project,
            depth = project.groupId and 1 or 0 }
    end

    local scroll = interaction.scroll({
        key = "filter-rows",
        shape = { type = "rect", x = f.left, y = y, width = f.bodyWidth,
            height = math.max(1, f.bodyBottom - y) },
        contentHeight = math.max(1, math.floor(#entries * rowHeight)),
    })
    local offset = scroll and scroll.offset or 0

    draw.pushClip(f.left - 2, y, f.bodyWidth + 4, math.max(1, f.bodyBottom - y))
    for index = 1, #entries do
        local entry = entries[index]
        local cy = y - offset + rowHeight * (index - 0.5)
        if cy + rowHeight / 2 < y - 1 or cy - rowHeight / 2 > f.bodyBottom + 1 then
            cy = nil
        end
        if cy then
        if entry.kind == "folder" then
            local name = entry.name ~= "" and entry.name
                or (cfg.folderLabel ~= "" and cfg.folderLabel
                    or l10n.tr("lua_widget.ticktick_tasks.filter_folder"))
            textMid(name, f.left + f.metaFont * 0.4, cy, f.metaFont, c.faint, f.bodyWidth * 0.7, true)
            textRight(l10n.formatNumber(entry.count), f.right - f.titleFont * 1.6, cy,
                f.metaFont, c.faint, false, 0.85)
            local top = math.max(cy - rowHeight / 2, y)
            local bottom = math.min(cy + rowHeight / 2, f.bodyBottom)
            regionSpec({
                key = "filter-folder:" .. entry.id,
                shape = { type = "rect", x = f.left, y = top,
                    width = f.bodyWidth, height = bottom - top },
                cursor = "hand",
                events = { click = { id = "filter.folder", value = entry.id } },
                accessibility = { role = "button", label = name },
            })
        else
            local project = entry.project
            local on = not cfg.off[project.id]
            local inset = entry.depth > 0 and f.titleFont * 1.2 or 0
            local dot = math.max(1.8, f.metaFont * 0.24)
            disc(f.left + inset + dot, cy, dot, project.color, on and 0.95 or 0.4)
            local name = projectName(project)
            textMid(name, f.left + inset + dot * 2 + f.metaFont * 0.7, cy, f.titleFont,
                on and c.ink or c.muted, f.bodyWidth - inset - f.titleFont * 3, false,
                on and 1 or 0.7)

            local box = math.min(rowHeight * 0.46, f.titleFont * 0.82)
            local bx = f.right - box
            if on then
                draw.rect(bx, cy - box / 2, box, box, c.accent, box * 0.28, 0.95)
                checkMark(bx + box / 2, cy, box * 0.62, c.onAccent, f.hair * 1.5, 1)
            else
                ring(bx + box / 2, cy, box / 2, c.faint, f.hair * 1.5, 0.9)
            end

            local top = math.max(cy - rowHeight / 2, y)
            local bottom = math.min(cy + rowHeight / 2, f.bodyBottom)
            regionSpec({
                key = "filter:" .. project.id,
                shape = { type = "rect", x = f.left, y = top,
                    width = f.bodyWidth, height = bottom - top },
                cursor = "hand",
                events = { click = { id = "filter.toggle", value = project.id } },
                accessibility = { role = "button", label = name },
            })
        end
        end
    end
    draw.popClip()
end

-- ---------------------------------------------------------------------------
-- Compact bar (one row tall)
-- ---------------------------------------------------------------------------

local function drawCompactBar(f)
    local c, model = f.c, f.model
    local midY = f.top + f.usableHeight / 2
    local labelFont = math.min(f.usableHeight * 0.34, f.rowUnit * 0.60)
    local metaFont = math.max(labelFont * 0.62,
        math.min(f.usableHeight * 0.20, f.rowUnit * 0.36))

    local dateText = isZh()
        and string.format("%d月%d日 周%s", f.parts.month, f.parts.day,
            weekdayLabel(f.parts.wday))
        or string.format("%s %d · %s", MONTHS[f.parts.month], f.parts.day,
            weekdayLabel(f.parts.wday))
    local dateRoom = f.bodyWidth * 0.5
    textMid(dateText, f.left, midY, labelFont, c.ink, dateRoom, true)
    local x = f.left + math.min(textWidth(dateText, labelFont, true), dateRoom)
        + metaFont * 1.2

    draw.line(x, midY - labelFont * 0.40, x, midY + labelFont * 0.40, f.hair, c.line,
        c.lineAlpha * 1.4)
    x = x + metaFont * 1.2

    if not model.tokenRef then
        regionSpec({
            key = "compact",
            shape = { type = "rect", x = 0, y = 0, width = f.width, height = f.height },
            cursor = "hand",
            events = { click = { id = "settings.open" } },
            accessibility = { role = "button",
                label = l10n.tr("lua_widget.ticktick_tasks.compact_setup") },
        })
        textRight(l10n.tr("lua_widget.ticktick_tasks.compact_setup"), f.right, midY,
            metaFont, c.accent, false, 0.95, f.right - x)
        return
    end
    if model.error and not model.state then
        textRight(l10n.tr("lua_widget.ticktick_tasks.error_offline_title"), f.right,
            midY, metaFont, c.bad, false, 0.95, f.right - x)
        return
    end

    local board = boardFor(model, f.cfg, f.todayIdx, f.view,
        f.view == "week" and 2 or 999)
    local count = board and board.count or 0
    local overdue = board and board.overdue or 0
    local countsText = overdue > 0
        and l10n.tr("lua_widget.ticktick_tasks.header_counts_both",
            l10n.formatNumber(count), l10n.formatNumber(overdue))
        or l10n.tr("lua_widget.ticktick_tasks.header_counts", l10n.formatNumber(count))
    textMid(countsText, x, midY, metaFont, c.muted, f.bodyWidth * 0.34, false)

    local first
    if board then
        for index = 1, #board.rows do
            if board.rows[index].kind == "task" then
                first = board.rows[index]
                break
            end
        end
    end
    if not first then return end

    local timeText
    if first.overdue then
        timeText = overdueText(first.task, f.todayIdx)
    elseif first.task.allDay then
        timeText = l10n.tr("lua_widget.ticktick_tasks.all_day")
    else
        timeText = dueTimeText(first.task)
    end
    local timeWidth = textWidth(timeText, metaFont, false)
    local dot = math.max(1.6, metaFont * 0.19)
    local prefixX = x + textWidth(countsText, metaFont, false) + metaFont * 1.5
    local titleX = prefixX + dot * 2 + metaFont * 0.5
    local room = f.right - timeWidth - metaFont * 1.1 - titleX
    if room > metaFont * 3 then
        local project = projectOf(model, first.task.projectId)
        disc(prefixX, midY, dot, project.color, 0.95)
        textMid(first.task.title, titleX, midY, metaFont, c.ink2, room, false, 0.95)
        textRight(timeText, f.right, midY, metaFont,
            first.overdue and c.bad or c.ink2, false, 0.9)
    end
    -- Without room for the title, a bare time ("Yesterday") would be a riddle;
    -- the date and the counts already carry the strip at that width.
end

-- ---------------------------------------------------------------------------
-- Render
-- ---------------------------------------------------------------------------

local function render(context, model)
    local f = buildFrame(context, model)
    if not f then return end

    regionSpec({
        key = "board",
        shape = { type = "rect", x = 0, y = 0, width = f.width, height = f.height },
        events = { contextMenu = { id = "task.menu", scope = "component" } },
        accessibility = { role = "group",
            label = l10n.tr("lua_widget.ticktick_tasks.name") },
    })

    if f.compact then
        drawCompactBar(f)
        return
    end

    drawHeader(f)
    drawFooter(f)

    if f.model.filterOpen and f.model.state then
        drawFilterBoard(f)
        return
    end

    local kind, title, hint, actions = noticeFor(f)
    if kind then
        drawNotice(f, kind, title, hint, actions or {})
        return
    end

    drawRows(f)
    drawToast(f)
end

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

-- Declared before setup because setup primes the frame heartbeat.
local ensureFrames

local function setup(context)
    local model = {
        state = nil,
        loadedAt = nil,
        syncing = false,
        error = nil,
        errorDetail = nil,
        pending = {},
        tasks = {},
        inFlight = 0,
        done = {},
        hidden = {},
        completing = {},
        toast = nil,
        toastAt = 0,
        framePending = false,
        preview = context.preview == true,
        filterOpen = false,
        serverId = DEFAULT_SERVER,
        stateVersion = 0,
        hiddenVersion = 0,
        boards = {},
        boardCount = 0,
        -- Data caches must exist before the first response lands: a fresh
        -- instance never goes through resetData, and the "keep old rows" pass
        -- in applyProjects iterates byProject on the very first sync.
        projects = {},
        projectList = {},
        folders = {},
        columns = {},
        byProject = {},
        dataPending = 0,
        failures = 0,
        parseFailed = 0,
        justConnected = false,
        projectsInFlight = false,
        syncStarted = nil,
        -- Bumped whenever the account context changes (token, server, reset):
        -- responses carrying an older generation are dropped on arrival.
        gen = 0,
        maxBytes = widget.hasFeature("task.network.largeResponse")
            and 4 * 1024 * 1024 or 1024 * 1024,
    }
    model.tokenRef = storage.get("token")
    model.hasToken = model.tokenRef ~= nil
    model.serverId = config().server.id

    widget.setTitle(l10n.tr("lua_widget.ticktick_tasks.name"))
    tooltipSupported = widget.hasFeature("interaction.tooltip")

    schedule.every("poll", config().intervalMs, { whenHidden = "pause" })
    -- Settings pages do not always deliver settings.changed for text fields;
    -- a cheap probe makes a paste take effect within seconds instead of minutes.
    schedule.every("probe", 5000, { whenHidden = "pause" })
    if model.preview then
        -- The catalog renders the board, not the "connect" card; a password
        -- setting has no value in preview, so stand one in.
        model.tokenRef = "preview"
        loadPreview(model)
    else
        poll(model, true)
        ensureFrames(model)
    end
    return model
end

local function resetData(model)
    model.gen = (model.gen or 0) + 1
    -- Queued (not yet sent) requests belong to the old context; in-flight ones
    -- cannot be recalled, so their generation is checked on arrival instead.
    model.pending = {}
    model.syncing = false
    model.syncStarted = nil
    model.filterOpen = false
    model.projectsInFlight = false
    model.state = nil
    model.projects, model.projectList = {}, {}
    model.folders = {}
    model.columns = {}
    model.byProject = {}
    model.dataPending = 0
    model.failures = 0
    model.parseFailed = 0
    model.loadedAt = nil
    model.error = nil
    model.errorDetail = nil
    model.hidden = {}
    model.done = {}
    model.completing = {}
    model.boards, model.boardCount = {}, 0
    model.stateVersion = model.stateVersion + 1
    model.hiddenVersion = model.hiddenVersion + 1
end

function ensureFrames(model)
    local wanted = model.toast ~= nil or model.syncing
    if not wanted then
        for _ in pairs(model.done) do
            wanted = true
            break
        end
    end
    if wanted then
        -- requestFrame is id-based and coalesces, so re-asking every frame is
        -- safe; latching on a flag lost the loop whenever one frame was dropped.
        animation.requestFrame("flash")
        model.framePending = true
    elseif model.framePending then
        animation.cancelFrame("flash")
        model.framePending = false
    end
end

local function pruneFlashes(model)
    local monotonicNow = time.monotonic()
    local changed = false
    for id, flash in pairs(model.done) do
        if monotonicNow - flash.at >= FLASH_MS then
            model.done[id] = nil
            model.hidden[id] = true
            changed = true
        end
    end
    if changed then model.hiddenVersion = model.hiddenVersion + 1 end
    if model.toast and monotonicNow - model.toastAt >= TOAST_MS then
        model.toast = nil
    end
end

-- Reconciles the optimistic row with the server's answer.
local function finishCompletion(model, id, ok, status)
    model.completing[id] = nil
    if ok then
        model.toast = { text = l10n.tr("lua_widget.ticktick_tasks.toast_done") }
    else
        model.done[id] = nil
        schedule.cancel("done:" .. id)
        -- The flash may already have retired the row; a failed write has to
        -- bring it back.
        if model.hidden[id] then
            model.hidden[id] = nil
            model.hiddenVersion = model.hiddenVersion + 1
        end
        model.toast = { text = l10n.tr("lua_widget.ticktick_tasks.toast_failed"), error = true }
    end
    model.toastAt = time.monotonic()
end

local function openTask(model, id)
    if model.preview or not widget.hasFeature("task.shell.openUri") then return end
    local entry = findTask(model, id)
    if not entry then return end
    if not id:match("^[%w_%-]+$") or not entry.projectId:match("^[%w_%-]+$") then return end
    task.start("shell.openUri", {
        url = config().server.web .. "/#p/" .. entry.projectId .. "/tasks/" .. id,
    })
end

-- The hidden-list set is one comma-separated storage value; every writer goes
-- through these two helpers so the encoding stays identical.
local function readOff()
    local off = {}
    local raw = storage.get("projectsOff")
    if type(raw) == "string" then
        for item in raw:gmatch("[^,]+") do off[item] = true end
    end
    return off
end

local function writeOff(off)
    local ids = {}
    for item in pairs(off) do ids[#ids + 1] = item end
    table.sort(ids)
    storage.set("projectsOff", table.concat(ids, ","))
end

local function toggleOff(id)
    if id == "" then return end
    local off = readOff()
    if off[id] then off[id] = nil else off[id] = true end
    writeOff(off)
end

local function event(_context, model, value)
    if value.kind == "schedule" and (value.id == "probe" or value.id == "poll") then
        -- A token written from the settings page should light the board even if
        -- settings.changed never arrives; the probe also covers region switches.
        local token = storage.get("token")
        local server = config().server
        local hasToken = token ~= nil
        if hasToken ~= model.hasToken or server.id ~= model.serverId then
            model.tokenRef = token
            model.hasToken = hasToken
            model.serverId = server.id
            model.justConnected = hasToken
            resetData(model)
            poll(model, true)
            widget.invalidate()
            return
        end
        if value.id == "poll" then
            poll(model, false)
            ensureFrames(model)
        end
        return
    elseif value.kind == "task.complete" then
        local job = model.tasks[value.taskId]
        if not job then
            -- A completion we cannot match means this cycle lost its
            -- bookkeeping; stop the spinner instead of waiting forever.
            if model.inFlight == 0 and model.syncing then
                model.syncing = false
                model.projectsInFlight = false
                model.dataPending = 0
            end
            widget.invalidate()
            return
        end
        model.tasks[value.taskId] = nil
        model.inFlight = math.max(0, model.inFlight - 1)

        if job.gen ~= model.gen then
            -- A response from before a token/server switch: never mix accounts.
            if job.kind == "projects" then model.projectsInFlight = false end
            if model.inFlight == 0 and model.dataPending == 0 then
                model.syncing = false
            end
            pump(model)
            widget.invalidate()
            return
        end

        local body = value.ok and value.value and value.value.body or nil
        -- The docs put the HTTP status on the event for failures; value.status
        -- only exists on success.
        local status = value.status or (value.value and value.value.status) or 0

        if job.kind == "projects" then
            model.projectsInFlight = false
            if value.ok and body and body ~= "" then
                if not applyProjects(model, body) then
                    model.syncing = false
                end
            elseif value.error == "httpStatus" and (status == 401 or status == 403) then
                model.syncing = false
                model.error = "auth"
                model.errorDetail = "http" .. tostring(status)
            else
                model.syncing = false
                if value.error == "secretUnavailable" then
                    model.error = "auth"
                else
                    scheduleRetry(model, value.error == "responseTooLarge" and "tooLarge"
                        or (value.error or "network"))
                end
                model.errorDetail = value.error
            end
        elseif job.kind == "data" then
            if value.ok and body and body ~= "" then
                applyProjectData(model, job, body)
            elseif value.error == "httpStatus" and status == 404 then
                -- The project disappeared between the list and the fetch.
                model.byProject[job.projectId] = nil
                rebuildState(model)
            elseif value.error == "httpStatus" and (status == 401 or status == 403) then
                model.error = "auth"
                model.errorDetail = "http" .. tostring(status)
            else
                model.error = value.error or "network"
                model.errorDetail = value.error
            end
            model.dataPending = math.max(0, model.dataPending - 1)
            if model.dataPending == 0 then
                model.syncing = false
                if not model.error then
                    model.failures = 0
                    model.loadedAt = time.now()
                    -- Every project failed to parse: that is a real error, and
                    -- an empty board would otherwise read as "no tasks".
                    if (model.parseFailed or 0) > 0
                        and (not model.state or #model.state.tasks == 0) then
                        model.error = "parse"
                    elseif model.justConnected then
                        model.justConnected = false
                        local total = 0
                        if model.state then
                            for index = 1, #model.state.tasks do
                                if model.state.tasks[index].open then total = total + 1 end
                            end
                        end
                        model.toast = {
                            text = l10n.tr("lua_widget.ticktick_tasks.toast_connected",
                                l10n.formatNumber(total)),
                            big = true,
                        }
                        model.toastAt = time.monotonic()
                    end
                end
            end
        else
            local id = job.taskId
            if id then
                if value.ok and status >= 200 and status < 300 then
                    finishCompletion(model, id, true)
                else
                    finishCompletion(model, id, false, status)
                end
            end
        end

        pump(model)
        ensureFrames(model)
        widget.invalidate()
        return
    elseif value.kind == "schedule" and value.id == "retry" then
        poll(model, true)
        ensureFrames(model)
        widget.invalidate()
        return
    elseif value.kind == "schedule" and value.id and value.id:sub(1, 5) == "done:" then
        local id = value.id:sub(6)
        if model.done[id] then
            model.done[id] = nil
            model.hidden[id] = true
            model.hiddenVersion = model.hiddenVersion + 1
            widget.invalidate()
            ensureFrames(model)
        end
        return
    elseif value.kind == "frame" and value.id == "flash" then
        model.framePending = false
        pruneFlashes(model)
        expireSync(model)
        widget.invalidate()
        ensureFrames(model)
        return
    elseif value.kind == "visibility" then
        if value.visible then
            poll(model, false)
            widget.invalidate()
        end
        return
    elseif value.kind == "settings.changed" then
        local keys = value.keys or {}
        for index = 1, #keys do
            local key = keys[index]
            if key == "token" then
                model.tokenRef = storage.get("token")
                model.hasToken = model.tokenRef ~= nil
                model.justConnected = true
                resetData(model)
                if model.tokenRef then
                    model.toast = {
                        text = l10n.tr("lua_widget.ticktick_tasks.toast_checking"),
                        big = true,
                    }
                    model.toastAt = time.monotonic()
                    poll(model, true)
                end
            elseif key == "server" then
                model.serverId = config().server.id
                resetData(model)
                poll(model, true)
            elseif key == "interval" then
                schedule.every("poll", config().intervalMs, { whenHidden = "pause" })
            elseif key == "view" or key == "sort" or key == "projectsOff"
                or key == "folderLabel" then
                widget.invalidate()
            end
        end
        return
    elseif value.kind ~= "action" then
        return
    end

    if value.id == "refresh" then
        if model.syncing then
            model.toast = { text = l10n.tr("lua_widget.ticktick_tasks.status_syncing") }
            model.toastAt = time.monotonic()
            ensureFrames(model)
            widget.invalidate()
            return
        end
        model.error = nil
        model.errorDetail = nil
        poll(model, true)
        ensureFrames(model)
    elseif value.id == "sort.set" then
        storage.set("sort", oneOf(tostring(value.value or "due"), sorts, "due"))
        widget.invalidate()
    elseif value.id == "filter.open" then
        -- Without a snapshot there is no list to tick; the notice card is the
        -- only thing on screen and a filter panel over it would be a dead end.
        if model.state then model.filterOpen = true end
        widget.invalidate()
    elseif value.id == "filter.close" then
        model.filterOpen = false
        widget.invalidate()
    elseif value.id == "filter.all" or value.id == "project.all" then
        storage.set("projectsOff", "")
        widget.invalidate()
    elseif value.id == "filter.folder" then
        local groupId = tostring(value.value or "")
        local targets = {}
        local projects = model.state and (model.state.list or {}) or {}
        if groupId ~= "" then
            for index = 1, #projects do
                local project = projects[index]
                if project.groupId == groupId then targets[#targets + 1] = project.id end
            end
        end
        if #targets > 0 then
            local off = readOff()
            local allOff = true
            for index = 1, #targets do
                if not off[targets[index]] then allOff = false end
            end
            for index = 1, #targets do
                if allOff then off[targets[index]] = true else off[targets[index]] = nil end
            end
            writeOff(off)
            widget.invalidate()
        end
    elseif value.id == "filter.toggle" or value.id == "project.toggle" then
        toggleOff(tostring(value.value or ""))
        widget.invalidate()
    elseif value.id == "view.week" then
        storage.set("view", "week")
        widget.invalidate()
    elseif value.id == "view.set" then
        storage.set("view", oneOf(tostring(value.value or "today"), views, "today"))
        widget.invalidate()
    elseif value.id == "task.complete" then
        completeTask(model, tostring(value.value or ""))
        ensureFrames(model)
        widget.invalidate()
    elseif value.id == "task.open" then
        openTask(model, tostring(value.value or ""))
    elseif value.id == "app.open" then
        if widget.hasFeature("task.shell.openUri") then
            task.start("shell.openUri", { url = config().server.web })
        end
    elseif value.id == "settings.open" then
        widget.openSettings()
    end
end

local function menu(_context, model, request)
    if request.id ~= "task.menu" then return nil end

    local items = {}
    if request.value and model.state then
        local id = tostring(request.value)
        local entry = findTask(model, id)
        if entry then
            items[#items + 1] = {
                id = "task.open", value = id,
                label = l10n.tr("lua_widget.ticktick_tasks.menu_open_task"),
                icon = glyph.open, iconFont = "fluent",
            }
            items[#items + 1] = {
                id = "task.complete", value = id,
                label = l10n.tr("lua_widget.ticktick_tasks.menu_complete"),
                icon = glyph.done, iconFont = "fluent",
            }
            items[#items + 1] = { type = "separator" }
        end
    end

    local cfg = config()
    items[#items + 1] = {
        id = "refresh",
        label = l10n.tr("lua_widget.ticktick_tasks.menu_refresh"),
        icon = glyph.refresh, iconFont = "fluent",
    }
    for index = 1, #views do
        items[#items + 1] = {
            id = "view.set", value = views[index],
            label = l10n.tr(viewKeys[views[index]]),
            icon = glyph.settings, iconFont = "fluent",
            checked = cfg.view == views[index],
        }
    end

    items[#items + 1] = { type = "separator" }
    items[#items + 1] = {
        id = "app.open",
        label = l10n.tr("lua_widget.ticktick_tasks.menu_open"),
        icon = glyph.link, iconFont = "fluent",
    }
    items[#items + 1] = {
        id = "settings.open",
        label = l10n.tr("lua_widget.ticktick_tasks.menu_settings"),
        icon = glyph.settings, iconFont = "fluent",
    }
    return ui.menu(items)
end

local function dispose(_context, model)
    schedule.cancel("poll")
    schedule.cancel("probe")
    if model.framePending then animation.cancelFrame("flash") end
    for taskId in pairs(model.tasks) do
        task.cancel(taskId)
    end
end

return widget.define({
    name = l10n.tr("lua_widget.ticktick_tasks.name"),
    useCustomStyle = true,
    followPersonalizationDefault = true,
    bg = 0x0B0B10,
    border = 0xFFFFFF,
    alpha = 0.16,
    borderAlpha = 0.10,
    gradientEndA = 0.16,
    settings = settings,
    setup = setup,
    render = render,
    event = event,
    menu = menu,
    dispose = dispose,
})
