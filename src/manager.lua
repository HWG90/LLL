-- Original coordinator. Dependencies are injected for isolated validation.
local queue_factory = LLL_CLEANUP_QUEUE or dofile("src/cleanup_queue.lua")
return function(host, entries)
    assert(not rawget(_G, "CowboyBingusModLoader"), "Another Shared Loader is active")
    assert(not rawget(_G, "LiveLuaLoader"), "Live Lua Loader is already active")
    local loader = {
        api = 1,
        version = 1,
        modules = {},
        records = {},
        errors = {},
        pending_cleanup = {},
        origins = {},
    }
    local cleanup_queue = queue_factory()
    local compat =
        { api = 1, version = 18, modules = loader.modules, implementation = "Live Lua Loader" }
    compat.open_log = host.open_log
    compat.log_directory = host.log_directory
    loader.log_directory = host.log_directory
    loader.compatibility = compat
    local function status(name, value)
        if loader.modules[name] == value then
            return
        end
        loader.modules[name] = value
        pcall(host.report, name, value)
        if loader.changed then
            pcall(loader.changed)
        end
    end
    local callbacks=(LLL_AFTER_STARTUP or dofile("src/after_startup.lua"))(function(name)return loader.modules[name]end,
        function(name,message)pcall(host.report,name,message)end,function(name)return loader.records[name]end)
    loader.after_startup=callbacks.register
    compat.after_startup=loader.after_startup
    loader.capabilities=(LLL_CAPABILITIES or dofile("src/capabilities.lua"))({logs=type(host.open_log)=="function",
        discovery=host.discovery_supported==true,after_startup=true,health=host.health~=nil,jit_budget=host.jit_budget~=nil,
        live_loading=true,deferred_cleanup=true,protected_runtime=host.protected_runtime==true,
        diagnostics=host.diagnostics~=nil,author_groups=true,resizable_manager=true})
    compat.capabilities=loader.capabilities
    compat.discovery=host.discovery_state
    compat.revision="LLL-R24"
    loader.diagnostics=host.diagnostics
    loader.health=host.health and host.health.public
    compat.health=loader.health
    compat.jit=host.jit_budget
    local function lifecycle_call(fn,...)
        if host.jit_budget and host.jit_budget.pause then host.jit_budget.pause() end
        local function pack(...)return {n=select("#",...),...}end
        local result=pack(pcall(fn,...))
        if host.jit_budget and host.jit_budget.resume then host.jit_budget.resume() end
        return unpack(result,1,result.n)
    end
    -- Ownership stays with the old record until explicit async acknowledgement.
    local function cleanup(name, record, final_state, completed)
        if loader.pending_cleanup[name] then
            return false, "pending"
        end
        local function finish()
            if loader.records[name] ~= record then
                return false, "Lifecycle ownership changed"
            end
            loader.records[name] = nil
            loader.pending_cleanup[name] = nil
            status(name, final_state)
            if completed then
                return completed()
            end
            return true
        end
        local ok, done, why = true, nil, nil
        if record.on_disable then
            ok, done, why = lifecycle_call(record.on_disable)
        end
        if loader.records[name] ~= record then
            return false, "Lifecycle ownership changed"
        end
        if ok and done ~= false then
            return finish()
        end
        local problem = ok and (why or "Cleanup returned false") or done
        if type(record.on_cleanup_poll) == "function" then
            local job = { name = name, record = record, final_state = final_state }
            loader.pending_cleanup[name] = job
            cleanup_queue.add(job, function(dt)
                if loader.records[name] ~= record or loader.pending_cleanup[name] ~= job then
                    if loader.pending_cleanup[name] == job then
                        loader.pending_cleanup[name] = nil
                    end
                    return true
                end
                local ready, reason = record.on_cleanup_poll(dt)
                if ready == true then
                    finish()
                    return true
                end
                return ready, reason
            end)
            if ok then
                status(name, "cleanup pending")
            else
                status(name, "cleanup failed: " .. tostring(problem))
            end
            return false, "pending"
        end
        status(name, "cleanup failed: " .. tostring(problem))
        return false, problem
    end
    local function load(name)
        local other = rawget(_G, "HD2ModLoader")
        local previous = other and other.modules and other.modules[name]
        if previous == "loading" or previous == "loaded" then
            loader.origins[name] = { owner = "mdl", registry = other }
            status(name, previous)
            return
        end
        local ok, available = pcall(host.available, name)
        if not ok then
            status(name, "lookup failed: " .. tostring(available))
            return
        end
        if not available then
            status(name, "not installed")
            return
        end
        local can_live = false
        if host.can_retry then
            local ok, value = pcall(host.can_retry, name)
            can_live = ok and value == true
        end
        loader.origins[name] = { owner = can_live and "lll_live" or "lll_archive" }
        status(name, "loading")
        callbacks.begin(name)
        local marker
        if host.health then local ok,value=pcall(host.health.before);if ok then marker=value end end
        local function finish_health()
            if host.health and marker then local ok,why=pcall(host.health.after,name,marker);if not ok then pcall(host.report,name,"Health observer failed: "..tostring(why))end end
            callbacks.ending()
        end
        local success, result = pcall(host.require, name)
        if not success then
            status(name, "load failed: " .. tostring(result))
            finish_health()
            return
        end
        if type(result) == "table" and result.live_lua_api == 1 then
            loader.records[name] = result
            if result.on_enable then
                local enabled, why = pcall(result.on_enable)
                if not enabled then
                    cleanup(name, result, "enable failed: " .. tostring(why))
                    finish_health()
                    return
                end
            end
        end
        status(name, "loaded")
        finish_health()
    end
    function loader.retry(name)
        if not host.can_retry or not host.can_retry(name) then
            return false, "Retry is available only for managed live scripts"
        end
        if loader.modules[name] == "loaded" then
            return loader.reload(name)
        end
        if loader.modules[name] == "loading" or loader.records[name] then
            return false, "Unresolved lifecycle ownership; restart required"
        end
        local valid, problem = pcall(host.preflight, name)
        if not valid then
            return false, problem
        end
        host.evict(name)
        load(name)
        return loader.modules[name] == "loaded", loader.modules[name]
    end
    function loader.reload(name)
        local record = loader.records[name]
        if
            loader.modules[name] ~= "loaded"
            or not record
            or type(record.on_disable) ~= "function"
        then
            return false, "This mod has no supported cleanup contract; restart required"
        end
        if host.preflight then
            local valid, problem = pcall(host.preflight, name)
            if not valid then
                return false, problem
            end
        end
        local ok, why = cleanup(name, record, "disabled")
        if not ok then
            return false, why
        end
        host.evict(name)
        load(name)
        return loader.modules[name] == "loaded", loader.modules[name]
    end
    function loader.set_enabled(name, wanted)
        wanted = wanted == true
        if not host.can_retry or not host.can_retry(name) then
            return false, "Archive addon has no managed live lifecycle; restart required"
        end
        local active = loader.modules[name] == "loaded"
        if loader.records[name] and not active then
            return false, "Unresolved lifecycle ownership; restart required"
        end
        if active == wanted then
            return true
        end
        if not wanted then
            local record = loader.records[name]
            if not record or type(record.on_disable) ~= "function" then
                return false, "Cleanup contract unavailable; restart required"
            end
            local function save_disable()
                if not host.save_enabled then
                    return true
                end
                local called, ok, why = pcall(host.save_enabled, name, false)
                if not called or not ok then
                    host.evict(name)
                    load(name)
                    return false, called and why or ok
                end
                return true
            end
            return cleanup(name, record, "disabled", save_disable)
        else
            if loader.records[name] then
                return false, "Unresolved lifecycle ownership; restart required"
            end
            local ok, why = pcall(host.preflight, name)
            if not ok then
                return false, why
            end
            host.evict(name)
            load(name)
            if loader.modules[name] ~= "loaded" then
                return false, loader.modules[name]
            end
        end
        if host.save_enabled then
            local ok, why = host.save_enabled(name, wanted)
            if not ok then
                if wanted then
                    local record = loader.records[name]
                    cleanup(name, record, "disabled")
                else
                    host.evict(name)
                    load(name)
                end
                return false, why
            end
        end
        return true
    end
    function loader.frame(dt)
        if next(loader.pending_cleanup) then
            for _, failure in ipairs(cleanup_queue.frame(dt)) do
                local job = failure.owner
                if
                    loader.pending_cleanup[job.name] == job
                    and loader.records[job.name] == job.record
                then
                    status(job.name, "cleanup failed: " .. tostring(failure.error))
                end
            end
        end
        for _, name in ipairs(loader.order) do
            local record = loader.records[name]
            if
                loader.modules[name] == "loaded"
                and record
                and type(record.on_update) == "function"
            then
                local ok, why = pcall(record.on_update, dt)
                if
                    not ok
                    and loader.records[name] == record
                    and loader.modules[name] == "loaded"
                then
                    cleanup(name, record, "update failed: " .. tostring(why))
                end
            end
        end
    end
    function loader.shutdown()
        callbacks.close()
        for i = #loader.order, 1, -1 do
            local name = loader.order[i]
            local record = loader.records[name]
            if loader.modules[name] == "loaded" and record and record.on_disable then
                cleanup(name, record, "disabled")
            end
        end
    end
    rawset(_G, "CowboyBingusModLoader", compat)
    rawset(_G, "LiveLuaLoader", loader)
    loader.order = {}
    local seen = {}
    for _, name in ipairs(entries) do
        if not seen[name] then
            seen[name] = true
            loader.order[#loader.order + 1] = name
            load(name)
        end
    end
    callbacks.finish()
    function loader.add(name, enabled)
        if seen[name] then
            return false
        end
        seen[name] = true
        loader.order[#loader.order + 1] = name
        if enabled == false then
            status(name, "disabled")
        else
            load(name)
        end
        return loader.modules[name] == "loaded"
    end
    function loader.forget_removed()
        local retired, retained, order = {}, 0, {}
        for _, name in ipairs(loader.order) do
            local missing = string.match(name, "^live/") and loader.live_catalog
                and not loader.live_catalog[name]
            local state = loader.modules[name]
            local origin = loader.origins[name]
            if missing and not loader.records[name] and not loader.pending_cleanup[name]
                and state ~= "loaded" and state ~= "loading"
                and not (origin and origin.registry) then
                host.evict(name)
                loader.modules[name], loader.errors[name], loader.origins[name] = nil, nil, nil
                seen[name] = nil
                retired[#retired + 1] = name
            else
                order[#order + 1] = name
                if missing then retained = retained + 1 end
            end
        end
        loader.order = order
        return retired, retained
    end
    return loader
end
