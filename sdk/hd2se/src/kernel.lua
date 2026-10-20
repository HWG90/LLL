-- HD2SE experimental kernel. Pure Lua 5.1; no injection, FFI or game hooks.
local K = { api = 1, version = "0.1.0-dev" }
local type, pairs, ipairs, next, rawget = type, pairs, ipairs, next, rawget
local select, unpack = select, unpack
local create, resume, status = coroutine.create, coroutine.resume, coroutine.status
local sub, format = string.sub, string.format
local sort, remove = table.sort, table.remove
local function pack(...) return { n = select("#", ...), ... } end
-- LuaJIT permits yielding through pcall. A host callback must finish in this
-- invocation: its phase, lifecycle flags and borrowed native lease cannot wait.
-- Lua 5.1 cannot close a suspended coroutine; never retain or resume it here.
local function invoke(fn, ...)
    local thread = create(fn)
    local values = pack(resume(thread, ...))
    if values[1] and status(thread) ~= "dead" then return false, "callback_yielded" end
    return unpack(values, 1, values.n)
end
local function message(value)
    local kind = type(value)
    if kind == "string" then return sub(value, 1, 512) end
    if kind == "number" then return format("%.17g", value) end
    if kind == "boolean" then return value and "true" or "false" end
    if kind == "nil" then return "nil" end
    -- Formatting an arbitrary error object would execute its __tostring,
    -- including side effects or a yield outside the guarded callback region.
    return "non-scalar error (" .. kind .. ")"
end
local function integer(n) return type(n) == "number" and n >= 1 and n % 1 == 0 and n < 2147483648 end
local function name(n) return type(n) == "string" and #n <= 128 and n:match("^[a-z][a-z0-9_.]*$") ~= nil end
local function keys(t)
    local result = {}
    for key in pairs(t) do result[#result + 1] = key end
    sort(result)
    return result
end
local function copy_list(t)
    if type(t) ~= "table" then return nil end
    local out, seen = {}, {}
    for i, value in ipairs(t) do
        if not name(value) or seen[value] then return nil end
        out[i], seen[value] = value, true
    end
    for key in pairs(t) do if not integer(key) or key > #out then return nil end end
    return out
end
local function copy_versions(t)
    if type(t) ~= "table" then return nil end
    local out = {}
    for key, value in pairs(t) do
        if not name(key) or not integer(value) then return nil end
        out[key] = value
    end
    return out
end
local function sha(value) return type(value) == "string" and #value == 64 and value:match("^[0-9a-f]+$") ~= nil end
local function identity(value)
    if type(value) ~= "table" or not sha(value.exe_sha256) or not sha(value.game_sha256) then return nil end
    return { exe_sha256 = value.exe_sha256, game_sha256 = value.game_sha256 }
end
local function methods(value)
    if type(value) ~= "table" or next(value) == nil then return nil end
    local out = {}
    for key, fn in pairs(value) do
        if not name(key) or type(fn) ~= "function" then return nil end
        out[key] = fn
    end
    return out
end

function K.new(options)
    options = options or {}
    local limits = {
        queue_limit = options.queue_limit or 256,
        max_tasks_per_pump = options.max_tasks_per_pump or 64,
        max_errors = options.max_errors or 32,
        max_plugins = options.max_plugins or 128,
        max_handles = options.max_handles or 4096,
        max_subscriptions = options.max_subscriptions or 1024,
        max_providers = options.max_providers or 256,
        max_cleanups = options.max_cleanups or 256,
        max_call_depth = options.max_call_depth or 32,
    }
    for key, value in pairs(limits) do assert(integer(value), "invalid limit: " .. key) end
    local build = identity(options.build)
    local host = {}
    local plugins, providers, capabilities = {}, {}, {}
    local tasks, events, subscriptions, errors, order = {}, {}, {}, {}, {}
    local handles, handle_count, epoch, phase, pumping = {}, 0, 1, nil, false
    local loading, stopping, transitioning, registering = false, false, false, false
    local call_depth = 0

    local function fault(owner, where, why)
        if #errors >= limits.max_errors then remove(errors, 1) end
        errors[#errors + 1] = { plugin = owner, operation = where, message = message(why) }
    end
    local function usable(record)
        return plugins[record.id] == record and (record.state == "starting" or record.state == "active")
    end
    local function guard(record)
        if not usable(record) then return nil, "plugin_inactive" end
        return true
    end
    local function capability(key)
        local provider = capabilities[key]
        if not provider then return false, "capability_unavailable: " .. message(key) end
        if provider.owner and not usable(provider.owner) then return false, "provider_inactive" end
        return provider.available, provider.reason
    end
    local function drop_provider(provider)
        if providers[provider.name] == provider then providers[provider.name] = nil end
        for _, key in ipairs(provider.capabilities) do
            if capabilities[key] == provider then capabilities[key] = nil end
        end
    end
    local function install_provider(spec, owner)
        if type(spec) ~= "table" or not name(spec.name) or not integer(spec.major) then return nil, "invalid_provider" end
        if providers[spec.name] then return nil, "provider_exists" end
        local count = 0
        for _ in pairs(providers) do count = count + 1 end
        if count >= limits.max_providers then return nil, "provider_limit" end
        local funcs, caps = methods(spec.methods), copy_list(spec.capabilities or {})
        if not funcs or not caps then return nil, "invalid_provider_methods_or_capabilities" end
        if spec.phase ~= nil and spec.phase ~= "update" and spec.phase ~= "render" then return nil, "invalid_phase" end
        if spec.check ~= nil and type(spec.check) ~= "function" then return nil, "invalid_check" end
        for _, key in ipairs(caps) do if capabilities[key] then return nil, "capability_exists: " .. key end end
        local scope = spec.scope or "portable"
        if scope ~= "portable" and scope ~= "engine" then return nil, "invalid_scope" end
        if scope == "engine" then
            if type(spec.validate) ~= "function" or type(spec.builds) ~= "table" then return nil, "invalid_engine_profile" end
            local count = 0
            for key, candidate in pairs(spec.builds) do
                count = count + 1
                if not integer(key) or not identity(candidate) then return nil, "invalid_engine_profile" end
            end
            if count == 0 then return nil, "invalid_engine_profile" end
            for i = 1, count do if not identity(rawget(spec.builds, i)) then return nil, "invalid_engine_profile" end end
        end
        local provider = {
            name = spec.name, major = spec.major, scope = scope, methods = funcs,
            capabilities = caps, phase = spec.phase, check = spec.check, owner = owner,
            available = true, evidence = type(spec.evidence) == "string" and spec.evidence:sub(1, 128) or "prototype",
        }
        if scope == "engine" then
            provider.available, provider.reason = false, "unsupported_build"
            local matched = false
            if type(spec.builds) == "table" and build then
                for _, candidate in ipairs(spec.builds) do
                    local target = identity(candidate)
                    if target and target.exe_sha256 == build.exe_sha256 and target.game_sha256 == build.game_sha256 then matched = true end
                end
            end
            if matched then
                provider.reason = "binding_unverified"
                if type(spec.validate) == "function" then
                    local ok, accepted, why = invoke(spec.validate, identity(build))
                    provider.available = ok and accepted == true
                    provider.reason = provider.available and nil or message(ok and (why or "binding_unverified") or accepted)
                end
            end
        end
        providers[provider.name] = provider
        for _, key in ipairs(caps) do capabilities[key] = provider end
        if owner then owner.providers[#owner.providers + 1] = provider end
        return true
    end
    function host:register_provider(spec)
        if loading or pumping or stopping or transitioning or registering or call_depth > 0 then return nil, "host_busy" end
        registering = true
        local values = pack(invoke(install_provider, spec))
        registering = false
        if not values[1] then fault("host", "register_provider", values[2]); return nil, "invalid_provider" end
        return unpack(values, 2, values.n)
    end
    local function service(record, key, major)
        if not guard(record) then return nil, "plugin_inactive" end
        local provider = providers[key]
        if not provider then return nil, "service_unavailable" end
        if provider.major ~= major then return nil, "service_version_mismatch" end
        if not provider.available then return nil, provider.reason end
        local view = {}
        for method, fn in pairs(provider.methods) do
            view[method] = function(...)
                if not guard(record) then return nil, "plugin_inactive" end
                if providers[key] ~= provider or (provider.owner and not usable(provider.owner)) then return nil, "provider_inactive" end
                if provider.phase and provider.phase ~= phase then return nil, "wrong_phase" end
                if call_depth >= limits.max_call_depth then return nil, "service_recursion_limit" end
                call_depth = call_depth + 1
                local values = pack(invoke(function(...)
                    if provider.check then
                        local check_context = { plugin = record.id, world_epoch = epoch, phase = phase }
                        local ok, accepted, why = invoke(provider.check, check_context)
                        if not ok or accepted ~= true then return nil, message(ok and (why or "context_unavailable") or accepted) end
                    end
                    local context = { plugin = record.id, world_epoch = epoch, phase = phase }
                    return fn(context, ...)
                end, ...))
                call_depth = call_depth - 1
                if not values[1] then fault(record.id, key .. "." .. method, values[2]); return nil, "provider_error" end
                return unpack(values, 2, values.n)
            end
        end
        return view
    end
    local function compact(list, record)
        local result = {}
        for _, entry in ipairs(list) do if entry.owner ~= record and not entry.cancelled then result[#result + 1] = entry end end
        return result
    end
    local function revoke(record)
        tasks, subscriptions = compact(tasks, record), compact(subscriptions, record)
        events = compact(events, record)
        for _, provider in ipairs(record.providers) do drop_provider(provider) end
        record.providers = {}
        for handle, entry in pairs(handles) do
            if entry.owner == record then handles[handle] = nil; handle_count = handle_count - 1 end
        end
    end
    local function enqueue_event(topic, payload, owner)
        if not name(topic) then return nil, "invalid_topic" end
        if #events >= limits.queue_limit then return nil, "event_queue_full" end
        events[#events + 1] = { topic = topic, payload = payload, owner = owner, epoch = epoch }
        return true
    end
    local function api_for(record)
        local api = { id = record.id, api = K.api, capabilities = {}, services = {}, events = {}, tasks = {} }
        function api.capabilities.has(key)
            if not guard(record) then return false, "plugin_inactive" end
            return capability(key)
        end
        function api.services.get(key, major) return service(record, key, major) end
        function api.services.publish(key, major, funcs)
            if not guard(record) then return nil, "plugin_inactive" end
            if not name(key) or key:sub(1, #record.id + 1) ~= record.id .. "." then return nil, "namespace_not_owned" end
            return install_provider({ name = key, major = major, methods = funcs, scope = "portable" }, record)
        end
        function api.events.on(topic, fn)
            if not guard(record) then return nil, "plugin_inactive" end
            if not name(topic) or type(fn) ~= "function" then return nil, "invalid_subscription" end
            subscriptions = compact(subscriptions)
            if #subscriptions >= limits.max_subscriptions then return nil, "subscription_limit" end
            local entry = { topic = topic, fn = fn, owner = record }
            subscriptions[#subscriptions + 1] = entry
            return function() entry.cancelled = true end
        end
        function api.events.emit(topic, payload)
            if not guard(record) then return nil, "plugin_inactive" end
            if not name(topic) or topic:sub(1, #record.id + 1) ~= record.id .. "." then return nil, "namespace_not_owned" end
            return enqueue_event(topic, payload, record)
        end
        function api.tasks.defer(target, fn)
            if not guard(record) then return nil, "plugin_inactive" end
            if (target ~= "update" and target ~= "render") or type(fn) ~= "function" then return nil, "invalid_task" end
            tasks = compact(tasks)
            if #tasks >= limits.queue_limit then return nil, "task_queue_full" end
            local entry = { phase = target, fn = fn, owner = record, epoch = epoch }
            tasks[#tasks + 1] = entry
            return function() entry.cancelled = true end
        end
        function api.on_cleanup(fn)
            if not guard(record) then return nil, "plugin_inactive" end
            if type(fn) ~= "function" then return nil, "invalid_cleanup" end
            if #record.cleanups >= limits.max_cleanups then return nil, "cleanup_limit" end
            record.cleanups[#record.cleanups + 1] = fn
            return true
        end
        return api
    end
    local function finish_stop(record)
        record.state = "stopping"
        revoke(record)
        -- Stop at the first unacknowledged release; preserve LIFO dependencies.
        while #record.cleanups > 0 do
            local ok, accepted = invoke(record.cleanups[#record.cleanups])
            if not ok then fault(record.id, "cleanup", accepted) end
            if not ok or accepted ~= true then return nil, "cleanup_pending: " .. record.id end
            remove(record.cleanups)
        end
        plugins[record.id] = nil
        for i = #order, 1, -1 do if order[i] == record then remove(order, i) end end
        record.state = "stopped"
        return true
    end
    local function rollback(loaded)
        for i = #loaded, 1, -1 do
            local record = loaded[i]
            -- Do not tear down a dependency while a dependent's release is pending.
            local blocked = false
            for _, other in pairs(plugins) do
                if other ~= record and other.dependencies[record.id] then blocked = true end
            end
            if blocked then record.state = "stopping"; revoke(record)
            else finish_stop(record) end
        end
    end
    function host:load(definitions)
        if loading or pumping or stopping or transitioning or registering or call_depth > 0 then return nil, "host_busy" end
        if type(definitions) ~= "table" then return nil, "invalid_definitions" end
        local pending, count = {}, 0
        for _ in pairs(plugins) do count = count + 1 end
        local total = 0
        for _, definition in ipairs(definitions) do
            if type(definition) ~= "table" or type(definition.manifest) ~= "table" or type(definition.start) ~= "function" then return nil, "invalid_definition" end
            local m = definition.manifest
            if not name(m.id) or not integer(m.version) or m.api ~= K.api then return nil, "invalid_manifest" end
            if m.id == "hd2se" or m.id:sub(1, 6) == "hd2se." then return nil, "reserved_plugin_id" end
            if plugins[m.id] or pending[m.id] then return nil, "plugin_exists: " .. m.id end
            local function overlaps(id)
                return m.id:sub(1, #id + 1) == id .. "." or id:sub(1, #m.id + 1) == m.id .. "."
            end
            for id in pairs(plugins) do if overlaps(id) then return nil, "plugin_namespace_overlap" end end
            for id in pairs(pending) do if overlaps(id) then return nil, "plugin_namespace_overlap" end end
            local deps, caps, required = copy_versions(m.dependencies or {}), copy_list(m.capabilities or {}), copy_versions(m.services or {})
            if not deps or not caps or not required then return nil, "invalid_requirements" end
            pending[m.id] = { id = m.id, version = m.version, dependencies = deps, capabilities = caps, services = required, start = definition.start }
            count, total = count + 1, total + 1
        end
        for key in pairs(definitions) do if not integer(key) or key > total then return nil, "invalid_definitions" end end
        if count > limits.max_plugins then return nil, "plugin_limit" end
        for _, record in pairs(pending) do
            for id, minimum in pairs(record.dependencies) do
                local dep = pending[id] or plugins[id]
                if not dep or dep.version < minimum or (plugins[id] and not usable(dep)) then return nil, "dependency_unavailable: " .. id end
            end
        end
        local sequence, marked, visiting = {}, {}, {}
        local function visit(id)
            if marked[id] or not pending[id] then return true end
            if visiting[id] then return nil, "dependency_cycle: " .. id end
            visiting[id] = true
            for _, dep in ipairs(keys(pending[id].dependencies)) do
                local ok, why = visit(dep)
                if not ok then return nil, why end
            end
            visiting[id], marked[id] = nil, true
            sequence[#sequence + 1] = pending[id]
            return true
        end
        for _, id in ipairs(keys(pending)) do local ok, why = visit(id); if not ok then return nil, why end end
        loading = true
        local loaded = {}
        for _, record in ipairs(sequence) do
            local why
            for _, key in ipairs(record.capabilities) do local ok, reason = capability(key); if not ok then why = reason; break end end
            if not why then
                for key, major in pairs(record.services) do
                    local provider = providers[key]
                    if not provider or provider.major ~= major or not provider.available then why = "service_unavailable: " .. key; break end
                end
            end
            if why then rollback(loaded); loading = false; return nil, why end
            record.state, record.cleanups, record.providers = "starting", {}, {}
            plugins[record.id], order[#order + 1], loaded[#loaded + 1] = record, record, record
            local ok, result, reason = invoke(record.start, api_for(record))
            record.start = nil
            if not ok or result == false then
                fault(record.id, "start", ok and (reason or "start_rejected") or result)
                rollback(loaded); loading = false
                return nil, "start_failed: " .. record.id
            end
            record.state = "active"
        end
        loading = false
        return true
    end
    function host:stop(id)
        if loading or pumping or stopping or transitioning or registering or call_depth > 0 then return nil, "host_busy" end
        local record = plugins[id]
        if not record then return nil, "plugin_unknown" end
        for _, other in pairs(plugins) do
            if other ~= record and other.dependencies[id] then return nil, "dependent_loaded: " .. other.id end
        end
        stopping = true
        local ok, why = finish_stop(record)
        stopping = false
        return ok, why
    end
    function host:shutdown()
        if loading or pumping or stopping or transitioning or registering or call_depth > 0 then return nil, "host_busy" end
        for i = #order, 1, -1 do
            local ok, why = self:stop(order[i].id)
            if not ok then return nil, why end
        end
        return true
    end
    function host:emit(topic, payload)
        return enqueue_event(topic, payload)
    end
    function host:pump(target)
        if loading or pumping or stopping or transitioning or registering or call_depth > 0 then return nil, "host_busy" end
        if target ~= "update" and target ~= "render" then return nil, "invalid_phase" end
        pumping, phase = true, target
        local batch, delivery = tasks, {}
        tasks = {}
        if target == "update" then delivery, events = events, {} end
        local ran = 0
        -- Reserve space for deferred batch items before executing callbacks.
        local executable = {}
        for _, task in ipairs(batch) do
            if not task.cancelled and usable(task.owner) and task.epoch == epoch then
                if task.phase == target and #executable < limits.max_tasks_per_pump then executable[#executable + 1] = task
                else tasks[#tasks + 1] = task end
            end
        end
        for _, event in ipairs(delivery) do
            if event.epoch == epoch and (not event.owner or usable(event.owner)) then
                local listeners = {}
                for _, entry in ipairs(subscriptions) do listeners[#listeners + 1] = entry end
                for _, entry in ipairs(listeners) do
                    if not entry.cancelled and usable(entry.owner) and entry.topic == event.topic then
                        local ok, why = invoke(entry.fn, event.payload, { topic = event.topic, world_epoch = epoch })
                        if not ok then fault(entry.owner.id, "event: " .. event.topic, why) end
                    end
                end
            end
        end
        for _, task in ipairs(executable) do
            if not task.cancelled and usable(task.owner) and task.epoch == epoch then
                local ok, why = invoke(task.fn)
                if not ok then fault(task.owner.id, "task", why) end
                ran = ran + 1
            end
        end
        subscriptions = compact(subscriptions)
        pumping, phase = false, nil
        return ran
    end
    function host:advance_world()
        if loading or pumping or stopping or transitioning or registering or call_depth > 0 then return nil, "host_busy" end
        transitioning = true
        epoch, handles, handle_count, tasks, events = epoch + 1, {}, 0, {}, {}
        local ok, why = enqueue_event("hd2se.world_changed", { world_epoch = epoch })
        transitioning = false
        return ok, why
    end
    function host:issue_handle(kind, value, owner)
        if not name(kind) or value == nil then return nil, "invalid_handle" end
        local record = owner and plugins[owner]
        if owner and (not record or not usable(record)) then return nil, "plugin_inactive" end
        if handle_count >= limits.max_handles then return nil, "handle_limit" end
        local handle = {}
        handles[handle] = { kind = kind, value = value, owner = record, epoch = epoch }
        handle_count = handle_count + 1
        return handle
    end
    function host:resolve_handle(handle, kind, owner)
        local entry = handles[handle]
        if not entry or entry.epoch ~= epoch or (entry.owner and not usable(entry.owner)) then return nil, "stale_handle" end
        if entry.kind ~= kind then return nil, "handle_type_mismatch" end
        if owner and (not entry.owner or entry.owner.id ~= owner) then return nil, "handle_owner_mismatch" end
        return entry.value
    end
    function host:release_handle(handle, owner)
        local entry = handles[handle]
        if not entry then return nil, "stale_handle" end
        if owner and (not entry.owner or entry.owner.id ~= owner) then return nil, "handle_owner_mismatch" end
        handles[handle], handle_count = nil, handle_count - 1
        return true
    end
    function host:status()
        local result = { api = K.api, version = K.version, world_epoch = epoch, plugins = {}, providers = {}, errors = {}, queued_tasks = #tasks, queued_events = #events, handles = handle_count }
        for _, id in ipairs(keys(plugins)) do
            local record = plugins[id]
            result.plugins[#result.plugins + 1] = { id = id, version = record.version, state = record.state, pending_cleanups = #record.cleanups }
        end
        for _, key in ipairs(keys(providers)) do
            local p = providers[key]
            local caps = {}
            for i, cap in ipairs(p.capabilities) do caps[i] = cap end
            result.providers[#result.providers + 1] = { name = key, major = p.major, scope = p.scope, phase = p.phase, available = p.available, reason = p.reason, evidence = p.evidence, capabilities = caps }
        end
        for i, e in ipairs(errors) do result.errors[i] = { plugin = e.plugin, operation = e.operation, message = e.message } end
        return result
    end
    return host
end

return K
