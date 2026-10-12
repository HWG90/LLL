-- Loose-script catalog and MDL API 2 lifecycle adapter.
return function(platform, report)
    local self = { entries = {}, catalog = {}, settings = {} }
    local sources, metadata_cache = {}, {}
    local project=LLL_PROJECT or dofile("src/project.lua")
    local prepared,instances,retained_instances={},{},{}
    local last_names
    local function valid(id)
        return type(id) == "string" and string.match(id, "^[%w_-]+$")
    end
    local function config(path)
        local data = path and platform.read(path, 1048576)
        if not data then
            return {}
        end
        local chunk = loadstring(data, "@" .. path)
        if not chunk then
            return {}
        end
        setfenv(chunk, {})
        local ok, value = pcall(chunk)
        return ok and type(value) == "table" and value or {}
    end
    local mdl = config(platform.loader_config)
    if next(mdl) == nil then
        mdl = config(platform.migrated_config)
    end
    if next(mdl) == nil then
        mdl = config(platform.mdl_config)
    end
    local serialize = (LLL_CONFIG or dofile("src/config.lua")).serialize
    function self.loader_option(name)
        return mdl[name]
    end
    function self.save_loader_option(name, value)
        local old = mdl[name]
        mdl[name] = value
        local ok, text = pcall(serialize, mdl)
        if not ok or not platform.loader_config or not platform.write(platform.loader_config, "return " .. text .. "\n") then
            mdl[name] = old
            return false, "Could not save loader option"
        end
        return true
    end
    function self.scan(force)
        if platform.changed then
            local changed = false
            for _, root in ipairs(platform.roots or { { kind = "lll", path = platform.live } }) do
                if root.path and platform.changed(root.path) then
                    changed = true
                end
            end
            if not force and last_names and not changed then
                return last_names
            end
            if changed or force then
                sources = {}
            end
        end
        if force then
            sources = {}
            metadata_cache = {}
        end
        local names = {}
        local seen = {}
        for _, root in ipairs(platform.roots or { { kind = "lll", path = platform.live } }) do
            if root.path then
                local candidates = {}
                local root_files, _, root_dirs = platform.files(root.path)
                for _, file in ipairs(root_files) do
                    local id = string.match(file, "^([%w_-]+)%.lua$")
                    if id then
                        candidates[#candidates + 1] = {
                            id = id,
                            path = root.path .. "/" .. file,
                            metadata_id = id,
                            dir = root.path,
                            kind = root.kind,
                        }
                    end
                end
                if platform.directories then
                    for _, id in ipairs(root_dirs or platform.directories(root.path)) do
                        if valid(id) then
                            local dir=root.path.."/"..id
                            local declared
                            if root.kind~="mdl" then
                                local ok,value=pcall(project.descriptor,platform,dir)
                                if ok then declared=value else report("live/"..id,"Manifest refused: "..tostring(value))end
                            end
                            if root.kind~="mdl" and not declared then
                                local main=platform.stat and platform.stat(dir.."/main.lua") or platform.read(dir.."/main.lua",16777216)
                                if main then declared={entry="main.lua",defaults="config/defaults.cfg",invalid=true}end
                            end
                            local path = dir .. "/" .. (declared and declared.entry or "mod.lua")
                            local exists
                            if platform.stat then
                                exists = platform.stat(path)
                            else
                                exists = platform.read(path, 16777216)
                            end
                            if exists then
                                candidates[#candidates + 1] = {
                                    id = id,
                                    path = path,
                                    dir = root.path .. "/" .. id,
                                    kind = root.kind,
                                    project = declared,
                                }
                            end
                        end
                    end
                end
                table.sort(candidates, function(a, b)
                    if a.id==b.id then
                        local af,bf=a.dir~=root.path,b.dir~=root.path
                        if af~=bf then return af end
                    end
                    return a.path < b.path
                end)
                for _, entry in ipairs(candidates) do
                    entry.source_root = root.path
                    if LLL_METADATA then
                        local key=entry.dir.."/"..(entry.metadata_id or "")
                        local signature
                        if platform.stat then
                            local stamps={}
                            for _,file in ipairs(LLL_METADATA.files(entry.metadata_id))do stamps[#stamps+1]=platform.stat(entry.dir.."/"..file) or "-"end
                            signature=table.concat(stamps,"|")
                        end
                        local cached = metadata_cache[key]
                        if signature and cached and cached.signature == signature then
                            entry.metadata = cached.value
                        else
                            entry.metadata = LLL_METADATA.read(platform, entry.dir, entry.metadata_id)
                            metadata_cache[key] =
                                { signature = signature, value = entry.metadata }
                        end
                    end
                    local gated = root.kind == "mdl"
                        or (type(mdl.enabled) == "table" and mdl.enabled[entry.id] ~= nil)
                    local name = "live/" .. entry.id
                    if not seen[name] then
                        seen[name] = true
                        self.catalog[name] = entry
                        if
                            not gated
                            or (type(mdl.enabled) == "table" and mdl.enabled[entry.id] == true)
                        then
                            self.entries[name] = entry
                            names[#names + 1] = name
                        else
                            self.entries[name] = nil
                        end
                    end
                end
            end
        end
        for name in pairs(self.catalog) do
            if not seen[name] then self.catalog[name] = nil end
        end
        last_names = names
        return names
    end
    function self.enabled(name)
        return self.entries[name] ~= nil
    end
    function self.auto_reload()
        if mdl.auto_reload ~= nil then
            return mdl.auto_reload ~= false
        end
        return not (type(mdl.ui) == "table" and mdl.ui.auto_reload == false)
    end
    function self.set_auto_reload(value)
        local previous = mdl.auto_reload
        mdl.auto_reload = value == true
        local ok, text = pcall(serialize, mdl)
        if
            not ok
            or not platform.loader_config
            or not platform.write(platform.loader_config, "return " .. text .. "\n")
        then
            mdl.auto_reload = previous
            return false, "Auto-reload preference could not be saved"
        end
        return true
    end
    function self.set_enabled(name, value)
        local entry = assert(self.catalog[name], "Unknown live script")
        local old = mdl.enabled
        mdl.enabled = mdl.enabled or {}
        local previous = mdl.enabled[entry.id]
        mdl.enabled[entry.id] = value == true
        local ok, text = pcall(serialize, mdl)
        if
            not ok
            or not platform.loader_config
            or not platform.write(platform.loader_config, "return " .. text .. "\n")
        then
            mdl.enabled[entry.id] = previous
            if not old then
                mdl.enabled = nil
            end
            return false, "Loader selection could not be saved"
        end
        self.entries[name] = value and entry or nil
        last_names = nil
        return true
    end
    function self.source(name, force)
        local entry = assert(self.catalog[name] or self.entries[name], "Unknown live mod")
        local stamp = platform.stat and platform.stat(entry.path)
        local cached = sources[name]
        if
            not force
            and stamp
            and cached
            and cached.path == entry.path
            and cached.stamp == stamp
        then
            return cached.text
        end
        local text = assert(platform.read(entry.path, 16777216), "Live source unreadable")
        local after = platform.stat and platform.stat(entry.path)
        if stamp and stamp == after then
            sources[name] = { path = entry.path, stamp = stamp, text = text }
        else
            sources[name] = nil
        end
        return text
    end
    function self.fingerprint(name,force)
        local entry=assert(self.catalog[name] or self.entries[name],"Unknown live mod")
        if not entry.project then return self.source(name,force)end
        local spec=assert(project.descriptor(platform,entry.dir),"LLL project manifest missing")
        return project.fingerprint(platform,entry,spec)
    end
    function self.restart_only(name)
        local entry=self.catalog[name] or self.entries[name]
        return entry and entry.project and entry.project.restart_only==true or false
    end
    function self.preflight(name)
        local entry = assert(self.catalog[name] or self.entries[name], "Unknown live mod")
        if entry.project then
            local spec=assert(project.descriptor(platform,entry.dir),"LLL project manifest missing")
            prepared[name]=project.snapshot(platform,entry,spec)
            return prepared[name].chunks[spec.entry]
        end
        return assert(loadstring(self.source(name, true), "@" .. entry.path))
    end
    function self.load(name)
        local entry = assert(self.catalog[name] or self.entries[name])
        local definition
        if entry.project then
            if not prepared[name] then self.preflight(name)end
            local snapshot=prepared[name];prepared[name]=nil
            local value,context=project.instantiate(platform,entry,snapshot,report)
            definition=value
            if instances[name] and instances[name].retain_until_exit then retained_instances[#retained_instances+1]=instances[name]end
            instances[name]=context
        else definition = self.preflight(name)() end
        assert(type(definition) == "table", "Live mod must return a lifecycle table")
        if definition.live_lua_api == 1 then
            assert(type(definition.on_disable) == "function", "LLL live mod requires cleanup")
            local context=instances[name]
            if context then
                local disable=definition.on_disable
                definition.on_disable=function(...)
                    context.console_active=false
                    local done,why=disable(...)
                    if done~=false then context.release_console()end
                    return done,why
                end
                if definition.on_cleanup_poll then
                    local poll=definition.on_cleanup_poll
                    definition.on_cleanup_poll=function(...)
                        local done,why=poll(...);if done==true then context.release_console()end;return done,why
                    end
                end
            end
            return definition
        end
        assert(
            type(definition.on_enable) == "function",
            "Unsupported live lifecycle: expected LLL API 1 or MDL on_enable(context)"
        )
        local cleanups, globals = {}, {}
        local settings_path = platform.settings
            and platform.settings .. "/mdl_" .. entry.id .. ".lua"
        local settings = config(settings_path)
        if
            next(settings) == nil
            and type(mdl.settings) == "table"
            and type(mdl.settings[entry.id]) == "table"
        then
            for key, value in pairs(mdl.settings[entry.id]) do
                settings[key] = value
            end
        end
        local ctx = {
            api = 2,
            id = entry.id,
            dir = entry.dir,
            settings = settings,
            config_dir=instances[name] and instances[name].config_dir,
            config=instances[name] and instances[name].config,
            loader = rawget(_G, "CowboyBingusModLoader"),
        }
        function ctx.log(...)
            local parts = {}
            for i = 1, select("#", ...) do
                parts[#parts + 1] = tostring(select(i, ...))
            end
            report(name, table.concat(parts, " "))
        end
        function ctx.on_cleanup(fn)
            assert(type(fn) == "function")
            cleanups[#cleanups + 1] = fn
        end
        function ctx.global(key, value)
            assert(type(key) == "string")
            local saved = globals[key]
            if not saved then
                saved = { previous = rawget(_G, key) }
                globals[key] = saved
            end
            saved.owned = value
            rawset(_G, key, value)
            return value
        end
        function ctx.set(key, value)
            local previous = settings[key]
            settings[key] = value
            local ok, text = pcall(serialize, settings)
            if
                not ok
                or not settings_path
                or not platform.write(settings_path, "return " .. text .. "\n")
            then
                settings[key] = previous
                error("Settings could not be saved")
            end
        end
        local cleanup_started, waiting, base_failure = false, false, nil
        local cleanup_index
        local function finish_cleanup()
            while cleanup_index and cleanup_index > 0 do
                local ok, done, why = pcall(cleanups[cleanup_index])
                if not ok then
                    error(done)
                end
                if done == false then
                    return false, why or "pending"
                end
                cleanup_index = cleanup_index - 1
            end
            cleanups = {}
            for key, saved in pairs(globals) do
                if rawget(_G, key) == saved.owned then
                    rawset(_G, key, saved.previous)
                end
            end
            globals = {}
            return true
        end
        local function poll_cleanup(dt)
            if not cleanup_started then
                return nil, "Cleanup was not started"
            end
            if waiting or base_failure then
                if type(definition.on_cleanup_poll) ~= "function" then
                    return nil, base_failure or "Deferred MDL cleanup requires on_cleanup_poll"
                end
                local done, why = definition.on_cleanup_poll(ctx, dt)
                if done ~= true then
                    return done, why
                end
                waiting = false
                base_failure = nil
            end
            return finish_cleanup()
        end
        local function disable()
            if cleanup_started then
                return false, "pending"
            end
            cleanup_started = true
            if instances[name] then instances[name].console_active=false end
            cleanup_index = #cleanups
            if definition.on_disable then
                local ok, done, why = pcall(definition.on_disable, ctx)
                if not ok then
                    base_failure = done
                    error(done)
                end
                if done == false then
                    waiting = true
                    return false, why or "pending"
                end
            end
            return finish_cleanup()
        end
        if instances[name] then ctx.on_cleanup(instances[name].release_console)end
        return {
            live_lua_api = 1,
            name = definition.name or definition.Name,
            author = definition.author or definition.Author,
            on_enable = function()
                return definition.on_enable(ctx)
            end,
            on_update = definition.on_update and function(dt)
                return definition.on_update(ctx, dt)
            end,
            on_disable = disable,
            on_cleanup_poll = poll_cleanup,
            mdl_context = ctx,
        }
    end
    function self.forget_removed(name)
        assert(not self.catalog[name], "Available script cannot be forgotten")
        self.entries[name], sources[name] = nil, nil
    end
    return self
end
