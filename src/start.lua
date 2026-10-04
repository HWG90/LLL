local platform = LLL_PLATFORM
local log = platform.open_log("LiveLuaLoader.log")
if log then
    log:write("Live Lua Loader 0.1.2 (R20 grouping candidate); API 1 compatibility\n")
end
local guarded, why = pcall(platform.guard)
if not guarded then
    if log then
        log:write("Refused startup: " .. tostring(why) .. "\n")
        log:close()
    end
    print("[LiveLuaLoader] Refused startup: " .. tostring(why))
    return
end
local entries = LLL_LEGACY
local ok, discovered, warnings, diagnostics = pcall(LLL_DISCOVER, platform)
if ok then
    for _, name in ipairs(discovered) do
        entries[#entries + 1] = name
    end
    if log then
        if diagnostics then
            log:write(diagnostics .. "\n")
        end
        log:write("Discovery: " .. #discovered .. " entries\n")
        for _, warning in ipairs(warnings or {}) do
            log:write(warning .. "\n")
        end
    end
else
    if log then
        log:write("Discovery failed: " .. tostring(discovered) .. "\n")
    end
    print("[LiveLuaLoader] Discovery failed: " .. tostring(discovered))
end
local function report(name, state)
    print("[LiveLuaLoader] " .. name .. ": " .. state)
    if log then
        log:write(name .. ": " .. state .. "\n")
    end
end
local live = LLL_LIVE(platform, report)
local source_cache = {}
local pending_edits = {}
for _, name in ipairs(live.scan()) do
    entries[#entries + 1] = name
end
if log then
    for _, root in ipairs(platform.roots or {}) do
        log:write("Search " .. root.kind .. ": " .. root.path .. "\n")
    end
end
local manager = LLL_MANAGER({
    available = function(name)
        if live.catalog[name] then
            return pcall(live.source, name)
        end
        return stingray.Application.can_get("lua", name)
    end,
    require = function(name)
        if live.catalog[name] then
            source_cache[name] = live.source(name)
            return live.load(name)
        end
        return require(name)
    end,
    preflight = function(name)
        if live.catalog[name] then
            live.preflight(name)
        end
    end,
    can_retry = function(name)
        return live.catalog[name] ~= nil
    end,
    save_enabled = live.set_enabled,
    evict = function(name)
        package.loaded[name] = nil
    end,
    open_log = platform.open_log,
    log_directory = platform.log_directory,
    report = report,
}, entries)
if ok then
    manager.discovery_warnings = warnings
end
manager.live_catalog = live.catalog
manager.discovery_diagnostics = diagnostics
manager.auto_reload = live.auto_reload
manager.set_auto_reload = live.set_auto_reload
local controls = LLL_CONTROLS(manager, live, report)
local ui
local built, value = pcall(LLL_UI, manager, platform, controls, report)
if built then
    ui = value
else
    report("LLL UI", value)
end
local function refresh_catalog(force)
    local found = live.scan(force)
    local all = {}
    for name in pairs(live.catalog) do
        all[#all + 1] = name
    end
    table.sort(all)
    for _, name in ipairs(all) do
        if manager.modules[name] == nil then
            manager.add(name, live.enabled(name))
        end
    end
    controls.follow(rawget(_G, "DBFMCM"))
    controls.refresh()
    return #all, found
end
manager.refresh = function()
    return refresh_catalog(true)
end
refresh_catalog()
-- Diagnostics now live at the bottom of the one LLL Mods page.
local status_page = { refresh = function() end, close = function() end }
status_page.refresh()
local clock = 0
local last_poll = platform.now and platform.now()
local retiring = false
local finish_detach
local function tick(dt)
    if retiring then
        manager.frame(dt)
        if not next(manager.pending_cleanup) and finish_detach then
            finish_detach()
        end
        return
    end
    manager.frame(dt)
    if ui and ui.tick then
        ui.tick(dt)
    end
    local now = platform.now and platform.now()
    clock = now and (now - last_poll) or (clock + (tonumber(dt) or 1 / 60))
    if now and now < last_poll then
        clock = 0.5
    end
    if clock < 0.5 then
        return
    end
    clock = 0
    if now then
        last_poll = now
    end
    local shown, problem = pcall(status_page.refresh)
    if not shown then
        report("LLL status", tostring(problem))
    end
    local _, names = refresh_catalog()
    for _, name in ipairs(names) do
        local valid, text = pcall(live.source, name, pending_edits[name] ~= nil)
        if manager.modules[name] == nil then
            manager.add(name)
        elseif
            live.auto_reload()
            and live.enabled(name)
            and valid
            and text
            and source_cache[name]
            and text ~= source_cache[name]
        then
            if pending_edits[name] == text then
                local success, problem = manager.retry(name)
                if not success and log then
                    log:write(name .. ": reload refused: " .. tostring(problem) .. "\n")
                end
                -- Suppress repeated failed reloads until another edit.
                source_cache[name] = text
                pending_edits[name] = nil
            else
                pending_edits[name] = text
            end
        else
            pending_edits[name] = nil
        end
    end
end
-- Preserve all prior callback results and trailing nils.
local function pack(...)
    return { n = select("#", ...), ... }
end
local prior = update
if type(prior) == "function" then
    local wrapper
    wrapper = function(dt, ...)
        local result = pack(prior(dt, ...))
        tick(dt)
        return unpack(result, 1, result.n)
    end
    update = wrapper
    finish_detach = function()
        if update == wrapper then
            update = prior
        end
        if log then
            log:close()
            log = nil
        end
    end
    manager.detach = function()
        if retiring then
            return not next(manager.pending_cleanup), "pending"
        end
        retiring = true
        if ui then
            ui.close()
        end
        controls.close()
        status_page.close()
        manager.shutdown()
        if platform.close_watches then
            platform.close_watches()
        end
        if next(manager.pending_cleanup) then
            return false, "pending"
        end
        finish_detach()
        return true
    end
else
    manager.frame_hook = "No global update callback; explicit LiveLuaLoader.frame(dt) required"
end
local old_shutdown = shutdown
if type(old_shutdown) == "function" then
    shutdown = function(...)
        if ui then
            ui.close()
        end
        controls.close()
        status_page.close()
        manager.shutdown()
        if platform.close_watches then
            platform.close_watches()
        end
        if log then
            log:close()
            log = nil
        end
        return old_shutdown(...)
    end
end
