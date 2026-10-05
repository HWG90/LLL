local platform = LLL_PLATFORM
local previous_text
local previous_path=platform.log_directory and platform.log_directory.."/LiveLuaLoader.log"
if previous_path then
    local file=io.open(previous_path,"rb")
    if file then previous_text=file:read(65536);file:close() end
end
local log = platform.open_log("LiveLuaLoader.log")
local diagnostic_service = LLL_DIAGNOSTICS and LLL_DIAGNOSTICS.shared()
local diagnostic_path = platform.log_directory and platform.log_directory .. "/LiveLuaLoader.log"
local diagnostic_owner = diagnostic_service and diagnostic_service.attach("LLL", diagnostic_path)
if log then
    log:write("Live Lua Loader 0.1.6 (R24 grouping candidate); API 1 compatibility\n")
end
local guarded, why = pcall(platform.guard)
if not guarded then
    if log then
        log:write("Refused startup: " .. tostring(why) .. "\n")
        log:close()
    end
    if diagnostic_service then diagnostic_service.detach(diagnostic_owner) end
    print("[LiveLuaLoader] Refused startup: " .. tostring(why))
    return
end
local entries = LLL_LEGACY
local ok, discovered, warnings, diagnostics, archive_copies = pcall(LLL_DISCOVER, platform)
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
    if diagnostic_service then pcall(diagnostic_service.record,"LLL",name .. ": " .. state,nil,nil,diagnostic_path) end
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
local code_budget = LLL_JIT_BUDGET and LLL_JIT_BUDGET.start(LLL_TRUST.jit, live.loader_option("jit_code_cache"), report)
local health
if LLL_HEALTH then
    local public={header={},changes={}}
    local function note(message)public.header[#public.header+1]=message;report("Health",message)end
    local observer
    local ok,value=pcall(LLL_HEALTH.observer,_G,{collect=collectgarbage,jit=LLL_TRUST.jit,clock=os.clock,
        flushes=code_budget and function()return code_budget.flushes end,watching=code_budget and code_budget.watching})
    if ok then observer=value;note(LLL_HEALTH.describe_start(observer.initial))else note("Observer unavailable: "..tostring(value))end
    local started="Started: "..os.date("%Y-%m-%d %H:%M:%S")
    if log then log:write(started.."\n")end
    note("Previous session: "..LLL_HEALTH.previous_session(previous_text))
    if platform.health then
        local ok,exe_stamp=pcall(LLL_HEALTH.image_stamp,platform.health.ffi,platform.health.kernel,nil)
        local game_ok,game_stamp=pcall(LLL_HEALTH.image_stamp,platform.health.ffi,platform.health.kernel,"game.dll")
        if ok and game_ok then note("Build stamps: "..LLL_HEALTH.hex(exe_stamp).." / "..LLL_HEALTH.hex(game_stamp))end
        for _,folder in ipairs({(os.getenv("APPDATA") or "").."/Arrowhead/Helldivers2/dumps",(os.getenv("LOCALAPPDATA") or "").."/CrashDumps"})do
            local ok,lines=pcall(LLL_HEALTH.crashes,platform.health.ffi,platform.health.kernel,folder,io.open,function(time)return os.date("%Y-%m-%d %H:%M:%S",time)end)
            if ok then for _,line in ipairs(lines)do note(line)end else note("Crash summary unavailable")end
        end
    end
    health={public=public,before=function()return observer and observer.mark()end,
        after=function(name,mark,stage)
            if observer and mark then
                local result=observer.changes(mark);local text=LLL_HEALTH.describe(result)
                if stage then text=string.sub((public.changes[name] or "").."; "..stage..": "..text,1,4096) end
                public.changes[name]=text;report(name,"Health: "..text)
            end
        end}
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
    health=health,jit_budget=code_budget,diagnostics=diagnostic_service,
    discovery_supported=LLL_DISCOVER~=nil,discovery_state=ok and (#discovered .. " declared entries") or "failed",protected_runtime=LLL_TRUST~=nil,
}, entries)
if ok then
    manager.discovery_warnings = warnings
end
manager.diagnostics = diagnostic_service
manager.diagnostics_surface = LLL_DIAGNOSTICS and LLL_DIAGNOSTICS.surface
report("Startup","Startup finished; after-startup callbacks drained")
if log then log:write("Startup finished\n")end
manager.get_loader_option = live.loader_option
manager.save_loader_option = live.save_loader_option
manager.jit_budget = code_budget
manager.live_catalog = live.catalog
manager.discovery_diagnostics = diagnostics
manager.discovery_copies = archive_copies
if archive_copies then
    for name,description in pairs(archive_copies.by_name)do report(name,description)end
    for _,description in ipairs(archive_copies.notes)do report("Discovery",description)end
end
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
manager.clear_removed_entries = function()
    refresh_catalog(true)
    local retired, retained = manager.forget_removed()
    for _, name in ipairs(retired) do
        live.forget_removed(name)
        source_cache[name], pending_edits[name] = nil, nil
        report(name, "Removed stale loader record; saved settings retained")
    end
    controls.refresh()
    return #retired, retained
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
        if ui then local ok,why=ui.close();if ok==false then report("LLL UI cleanup",why);return false end end
        if code_budget then
            local ok,why=code_budget.close()
            if not ok then report("LLL JIT cleanup",why);return false end
        end
        if diagnostic_service and diagnostic_owner then diagnostic_service.detach(diagnostic_owner);diagnostic_owner=nil end
        if update == wrapper then
            update = prior
        end
        if log then
            log:close()
            log = nil
        end
        return true
    end
    manager.detach = function()
        if retiring then
            return not next(manager.pending_cleanup) and (not code_budget or code_budget.closed), "pending"
        end
        retiring = true
        if ui then
            ui.close()
        end
        controls.close()
        status_page.close()
        manager.shutdown()
        if code_budget then code_budget.close() end
        if platform.close_watches then
            platform.close_watches()
        end
        if next(manager.pending_cleanup) then
            return false, "pending"
        end
        return finish_detach()
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
        if code_budget then code_budget.close() end
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
