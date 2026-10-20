-- Offline public-contract tests. Mock providers do not establish native/game behavior.
local K = dofile('sdk/hd2se/src/kernel.lua')
local BUILD = {exe_sha256 = string.rep('a', 64), game_sha256 = string.rep('b', 64)}
local OTHER = {exe_sha256 = string.rep('c', 64), game_sha256 = string.rep('b', 64)}
local cases, failed = 0, {}
local function pack(...) return {n = select('#', ...), ...} end
local function eq(actual, expected, reason)
    assert(actual == expected, (reason or 'value differs') .. ': expected ' .. tostring(expected) .. ', got ' .. tostring(actual))
end
local function ok(value, reason) assert(value, tostring(reason or 'expected success')); return value end
local function refused(value, reason)
    assert(value == nil or value == false, 'expected refusal, got ' .. tostring(value))
    assert(type(reason) == 'string' and #reason > 0, 'refusal must explain why')
end
local function host(options)
    options = options or {}
    options.build = options.build or BUILD
    options.queue_limit = options.queue_limit or 256
    options.max_tasks_per_pump = options.max_tasks_per_pump or 64
    return K.new(options)
end
local function plugin(id, start, extra)
    local manifest = {id = id, version = 1, api = 1}
    for key, value in pairs(extra or {}) do manifest[key] = value end
    return {manifest = manifest, start = start or function() end}
end
local function load_api(h, id, extra)
    local api
    ok(h:load({plugin(id or 'example', function(value) api = value end, extra)}))
    return api
end
local function provider(h, methods, extra)
    local spec = {name = 'world', major = 1, scope = 'portable', capabilities = {'world.read'}, methods = methods}
    for key, value in pairs(extra or {}) do spec[key] = value end
    ok(h:register_provider(spec))
end
local function test(name, fn)
    cases = cases + 1
    local success, reason = xpcall(fn, debug.traceback)
    if success then print('PASS ' .. name)
    else failed[#failed + 1] = name .. ': ' .. tostring(reason); print('FAIL ' .. name .. ': ' .. tostring(reason)) end
end

print('RUNTIME ' .. _VERSION .. ' / ' .. (jit and jit.version or 'no JIT'))

test('provider facade preserves dot arguments, false and nil return slots', function()
    local h, observed = host()
    provider(h, {echo = function(context, ...)
        observed = {context = context, args = pack(...)}
        return false, nil, 'last', nil
    end})
    local api = load_api(h, 'example', {capabilities = {'world.read'}, services = {world = 1}})
    eq(api.id, 'example')
    ok(api.capabilities.has('world.read'))
    local service = ok(api.services.get('world', 1))
    local result = pack(service.echo('first', nil, 3, nil))
    eq(result.n, 4); eq(result[1], false); eq(result[2], nil); eq(result[3], 'last'); eq(result[4], nil)
    eq(observed.args.n, 4); eq(observed.args[1], 'first'); eq(observed.args[2], nil); eq(observed.args[3], 3)
    eq(observed.context.plugin, 'example'); eq(observed.context.world_epoch, h:status().world_epoch)
end)

test('provider and facade major version mismatch is refused', function()
    local h = host()
    provider(h, {read = function() return 42 end})
    local api = load_api(h)
    refused(api.services.get('world', 2))
    refused(h:register_provider({name = 'world', major = 1, scope = 'portable', capabilities = {}, methods = {}}))
end)

test('engine provider requires an exact build and structural validator', function()
    local h = host()
    refused(h:register_provider({name = 'native', major = 1, scope = 'engine', capabilities = {'native.read'}, methods = {read = function() end}}))
    refused(h:register_provider({name = 'native', major = 1, scope = 'engine', capabilities = {'native.read'}, methods = {read = function() end}, builds = {BUILD}}))
end)

test('unsupported engine build is registered unavailable and never invoked', function()
    local h, invoked, started = host({build = OTHER}), 0, 0
    provider(h, {read = function() invoked = invoked + 1 end}, {scope = 'engine', builds = {BUILD}, validate = function() return true end})
    refused(h:load({plugin('example', function() started = started + 1 end, {capabilities = {'world.read'}, services = {world = 1}})}))
    eq(started, 0); eq(invoked, 0)
end)

test('structural validation failure denies an otherwise matching build', function()
    local h, started = host(), 0
    provider(h, {read = function() error('must never run') end}, {scope = 'engine', builds = {BUILD}, validate = function() return false, 'layout mismatch' end})
    refused(h:load({plugin('example', function() started = started + 1 end, {capabilities = {'world.read'}})}))
    eq(started, 0)
end)

test('provider validator error remains unavailable instead of escaping', function()
    local h, started = host(), 0
    provider(h, {read = function() end}, {scope = 'engine', builds = {BUILD}, validate = function() error('bad validator') end})
    refused(h:load({plugin('example', function() started = started + 1 end, {capabilities = {'world.read'}})}))
    eq(started, 0)
end)

test('provider validator cannot reenter host lifecycle before registration commits', function()
    local h, validated = host(), false
    load_api(h)
    provider(h, {read = function() return true end}, {scope = 'engine', builds = {BUILD}, validate = function()
        refused(h:load({plugin('nested')}))
        refused(h:register_provider({name = 'nested', major = 1, scope = 'portable', methods = {read = function() end}}))
        refused(h:stop('example')); refused(h:shutdown()); refused(h:advance_world()); refused(h:pump('update'))
        validated = true; return true
    end})
    ok(validated); eq(#h:status().plugins, 1)
end)

test('engine phase guard and context follow actual host pump', function()
    local h, count, context = host(), 0
    provider(h, {read = function(value) count = count + 1; context = value; return 42 end}, {scope = 'engine', builds = {BUILD}, validate = function(build) eq(build.exe_sha256, BUILD.exe_sha256); return true end, phase = 'update'})
    local api = load_api(h, 'example', {capabilities = {'world.read'}, services = {world = 1}})
    local service = ok(api.services.get('world', 1))
    refused(service.read())
    ok(api.tasks.defer('update', function() eq(service.read(), 42) end))
    h:pump('render'); eq(count, 0)
    h:pump('update'); eq(count, 1); eq(context.phase, 'update'); eq(context.plugin, 'example')
end)

test('provider ownership check is reevaluated on every invocation', function()
    local h, allowed, calls = host(), true, 0
    provider(h, {read = function() calls = calls + 1; return 42 end}, {check = function(context) eq(context.plugin, 'example'); return allowed, 'ownership changed' end})
    local api = load_api(h, 'example', {capabilities = {'world.read'}, services = {world = 1}})
    local service = ok(api.services.get('world', 1))
    eq(service.read(), 42); allowed = false; refused(service.read()); eq(calls, 1)
end)

test('provider checks cannot mutate host lifecycle or forge method context', function()
    local h, checked, called = host(), false, false
    local expected_epoch = h:status().world_epoch
    provider(h, {read = function(context)
        called = true; eq(context.plugin, 'example'); eq(context.world_epoch, expected_epoch); eq(context.phase, nil)
        refused(h:stop('example')); refused(h:pump('update')); return 42
    end}, {check = function(context)
        refused(h:load({plugin('nested')}))
        refused(h:register_provider({name = 'nested', major = 1, scope = 'portable', methods = {read = function() end}}))
        refused(h:stop('example')); refused(h:shutdown()); refused(h:advance_world()); refused(h:pump('update'))
        context.plugin, context.world_epoch, context.phase = 'forged', -1, 'render'
        checked = true; return true
    end})
    local api = load_api(h); local service = ok(api.services.get('world', 1))
    eq(service.read(), 42); ok(checked); ok(called); eq(h:status().world_epoch, expected_epoch)
end)

test('recursive service calls are bounded and dispatch state recovers', function()
    local h, service, calls = host({max_call_depth = 3}), nil, 0
    provider(h, {read = function(context, remaining)
        calls = calls + 1
        if remaining == 0 then return 42 end
        return service.read(remaining - 1)
    end})
    local api = load_api(h); service = ok(api.services.get('world', 1))
    refused(service.read(100)); assert(calls <= 3 and calls >= 1)
    eq(service.read(0), 42); eq(service.read(1), 42)
    ok(h:stop('example'))
end)

test('dependency sorting is deterministic across input permutations', function()
    local function order(ids)
        local h, started, specs = host(), {}, {}
        local dependencies = {a = {}, b = {a = 1}, c = {b = 1}, d = {a = 1}}
        for _, id in ipairs(ids) do
            specs[#specs + 1] = plugin(id, function(api) started[#started + 1] = api.id end, {dependencies = dependencies[id]})
        end
        ok(h:load(specs)); eq(started[1], 'a')
        local positions = {}; for index, id in ipairs(started) do positions[id] = index end
        assert(positions.a < positions.b and positions.b < positions.c and positions.a < positions.d)
        return table.concat(started, ',')
    end
    eq(order({'d', 'c', 'b', 'a'}), order({'b', 'a', 'd', 'c'}))
end)

test('missing dependency preflight runs no plugin code', function()
    local h, started = host(), 0
    local function start() started = started + 1 end
    refused(h:load({plugin('a', start), plugin('b', start, {dependencies = {missing = 1}})}))
    eq(started, 0)
end)

test('dependency cycle preflight runs no plugin code', function()
    local h, started = host(), 0
    local function start() started = started + 1 end
    refused(h:load({plugin('a', start, {dependencies = {b = 1}}), plugin('b', start, {dependencies = {a = 1}})}))
    eq(started, 0)
end)

test('dependency and kernel API minimums fail before start', function()
    local h, started = host(), 0
    local function start() started = started + 1 end
    refused(h:load({plugin('a', start), plugin('b', start, {dependencies = {a = 2}})})); eq(started, 0)
    refused(h:load({plugin('future', start, {api = 2})})); eq(started, 0)
end)

test('duplicate identities reject the batch before startup', function()
    local h, started = host(), 0
    local function start() started = started + 1 end
    refused(h:load({plugin('duplicate', start), plugin('duplicate', start)})); eq(started, 0)
end)

test('host event namespace cannot be acquired through a plugin identity', function()
    local h, started = host(), 0
    local function start() started = started + 1 end
    refused(h:load({plugin('hd2se', start)})); refused(h:load({plugin('hd2se.child', start)})); eq(started, 0)
    eq(load_api(h, 'hd2seish').id, 'hd2seish')
end)

test('sparse definitions and malformed manifest requirements reject before startup', function()
    local h, started = host(), 0
    local function start() started = started + 1 end
    refused(h:load({[2] = plugin('sparse', start)}))
    refused(h:load({plugin('sparse', start, {capabilities = {[2] = 'world.read'}})}))
    refused(h:load({plugin('bad_dependency', start, {dependencies = {dep = '1'}})}))
    refused(h:load({plugin('bad_service', start, {services = {[1] = 1}})}))
    refused(h:load({plugin('bad_version', start, {version = 0})}))
    eq(started, 0)
end)

test('malformed provider methods, capabilities and build arrays are refused', function()
    local h = host()
    refused(h:register_provider({name = 'bad_methods', major = 1, scope = 'portable', capabilities = {}, methods = {read = true}}))
    refused(h:register_provider({name = 'sparse_caps', major = 1, scope = 'portable', capabilities = {[2] = 'world.read'}, methods = {read = function() end}}))
    refused(h:register_provider({name = 'duplicate_caps', major = 1, scope = 'portable', capabilities = {'world.read', 'world.read'}, methods = {read = function() end}}))
    refused(h:register_provider({name = 'sparse_builds', major = 1, scope = 'engine', capabilities = {}, methods = {read = function() end}, builds = {[2] = BUILD}, validate = function() return true end}))
    refused(h:register_provider({name = 'hidden_bad_build', major = 1, scope = 'engine', capabilities = {}, methods = {read = function() end}, builds = {BUILD, nil, false}, validate = function() return true end}))
    refused(h:register_provider({name = 'bad_hash', major = 1, scope = 'engine', capabilities = {}, methods = {read = function() end}, builds = {{exe_sha256 = 'bad', game_sha256 = BUILD.game_sha256}}, validate = function() return true end}))
end)

test('startup failure reverses newly loaded ownership and preserves earlier plugins', function()
    local h, retained, cleanup, stale = host(), nil, {}, nil
    retained = load_api(h, 'retained')
    refused(h:load({
        plugin('a', function(api)
            stale = api
            api.on_cleanup(function() cleanup[#cleanup + 1] = 'a'; return true end)
            api.tasks.defer('update', function() error('rolled-back task must never run') end)
        end),
        plugin('b', function(api)
            api.on_cleanup(function() cleanup[#cleanup + 1] = 'b'; return true end)
            error('startup deliberately fails')
        end, {dependencies = {a = 1}}),
    }))
    eq(table.concat(cleanup, ','), 'b,a')
    refused(stale.tasks.defer('update', function() end))
    local ran = false; ok(retained.tasks.defer('update', function() ran = true end)); h:pump('update'); ok(ran)
end)

test('startup rollback retains dependencies while a dependent cleanup is pending', function()
    local h, release_ready, dependent, dependency, facade, order = host(), false, nil, nil, nil, {}
    refused(h:load({
        plugin('dep', function(api)
            dependency = api
            ok(api.services.publish('dep.read', 1, {read = function() return 42 end}))
            facade = ok(api.services.get('dep.read', 1))
            api.on_cleanup(function() order[#order + 1] = 'dep'; return true end)
        end),
        plugin('consumer', function(api)
            dependent = api
            api.on_cleanup(function() order[#order + 1] = 'consumer'; return release_ready end)
            error('startup fails after acquiring a resource')
        end, {dependencies = {dep = 1}}),
    }))
    eq(table.concat(order, ','), 'consumer')
    refused(dependent.tasks.defer('update', function() end)); refused(h:stop('dep'))
    refused(dependency.tasks.defer('update', function() end)); refused(facade.read())
    refused(h:load({plugin('later', nil, {dependencies = {dep = 1}})}))
    release_ready = true; ok(h:stop('consumer')); ok(h:stop('dep'))
    eq(table.concat(order, ','), 'consumer,consumer,dep')
end)

test('published services are namespaced, dependency-owned and revoked on stop', function()
    local h, facade, publisher = host(), nil, nil
    ok(h:load({
        plugin('dep', function(api)
            publisher = api
            ok(api.services.publish('dep.counter', 1, {read = function(context, value) eq(context.plugin, 'consumer'); return value, nil, false end}))
            refused(api.services.publish('someone.counter', 1, {read = function() end}))
        end),
        plugin('consumer', function(api) facade = ok(api.services.get('dep.counter', 1)) end, {dependencies = {dep = 1}}),
    }))
    local result = pack(facade.read('value')); eq(result.n, 3); eq(result[1], 'value'); eq(result[3], false)
    ok(h:stop('consumer')); refused(facade.read('value')); ok(h:stop('dep'))
    refused(publisher.services.publish('dep.again', 1, {read = function() end}))
end)

test('queued events isolate callbacks and enforce plugin-owned emission', function()
    local h, seen = host(), 0
    local api = load_api(h)
    ok(api.events.on('example.changed', function() error('expected callback failure') end))
    ok(api.events.on('example.changed', function(payload) eq(payload.value, 42); seen = seen + 1 end))
    refused(api.events.emit('another.changed', {})); refused(api.events.emit('hd2se.world_changed', {}))
    ok(api.events.emit('example.changed', {value = 42})); eq(seen, 0)
    h:pump('update'); eq(seen, 1); assert(#h:status().errors >= 1)
end)

test('subscription and task cancellation prevents queued callbacks', function()
    local h, called = host(), 0
    local api = load_api(h)
    local cancel_event = ok(api.events.on('host.ready', function() called = called + 1 end))
    local cancel_task = ok(api.tasks.defer('update', function() called = called + 1 end))
    eq(type(cancel_event), 'function'); eq(type(cancel_task), 'function')
    ok(h:emit('host.ready', {})); cancel_event(); cancel_task(); h:pump('update'); eq(called, 0)
end)

test('task queue bound refuses overflow and recovers after drain', function()
    local h, calls = host({queue_limit = 2}), 0
    local api = load_api(h)
    local function task() calls = calls + 1 end
    ok(api.tasks.defer('update', task)); ok(api.tasks.defer('update', task)); refused(api.tasks.defer('update', task))
    h:pump('update'); eq(calls, 2); eq(h:status().queued_tasks, 0)
    ok(api.tasks.defer('update', task)); h:pump('update'); eq(calls, 3)
end)

test('event queue bound refuses overflow and recovers after drain', function()
    local h, calls = host({queue_limit = 2}), 0
    local api = load_api(h); ok(api.events.on('host.ready', function() calls = calls + 1 end))
    ok(h:emit('host.ready', {})); ok(h:emit('host.ready', {})); refused(h:emit('host.ready', {}))
    h:pump('update'); eq(calls, 2); eq(h:status().queued_events, 0)
    ok(h:emit('host.ready', {})); h:pump('update'); eq(calls, 3)
end)

test('pump budget and nested deferral prevent same-pump bursts', function()
    local h, calls = host({max_tasks_per_pump = 1}), {}
    local api = load_api(h)
    ok(api.tasks.defer('update', function()
        calls[#calls + 1] = 'first'
        ok(api.tasks.defer('update', function() calls[#calls + 1] = 'nested' end))
    end))
    ok(api.tasks.defer('update', function() calls[#calls + 1] = 'second' end))
    h:pump('update'); eq(table.concat(calls, ','), 'first')
    h:pump('update'); eq(table.concat(calls, ','), 'first,second')
    h:pump('update'); eq(table.concat(calls, ','), 'first,second,nested')
end)

test('nested task waits for next pump even with spare budget', function()
    local h, calls = host(), 0
    local api = load_api(h)
    ok(api.tasks.defer('update', function() calls = calls + 1; ok(api.tasks.defer('update', function() calls = calls + 1 end)) end))
    h:pump('update'); eq(calls, 1); h:pump('update'); eq(calls, 2)
end)

test('pump rejects reentrancy while isolating a failing task', function()
    local h, completed, nested = host(), false, nil
    local api = load_api(h)
    ok(api.tasks.defer('update', function() nested = pack(h:pump('update')); error('task fault') end))
    ok(api.tasks.defer('update', function() completed = true end))
    h:pump('update'); ok(completed); refused(nested[1], nested[2]); assert(#h:status().errors >= 1)
end)

test('world advancement revokes handles and queued work but emits lifecycle event', function()
    local h, calls, changes = host(), 0, 0
    local api = load_api(h)
    local handle = ok(h:issue_handle('entity', {value = 42}, 'example'))
    ok(api.events.on('host.stale', function() calls = calls + 1 end))
    ok(api.events.on('hd2se.world_changed', function() changes = changes + 1 end))
    ok(api.tasks.defer('update', function() calls = calls + 1 end)); ok(h:emit('host.stale', {}))
    local epoch = h:status().world_epoch
    h:advance_world(); eq(h:status().world_epoch, epoch + 1); refused(h:resolve_handle(handle, 'entity'))
    h:pump('update'); eq(calls, 0); eq(changes, 1)
end)

test('handles enforce kind, host identity, release and owner lifetime', function()
    local h, another = host(), host()
    load_api(h)
    local value = {answer = 42}
    local handle = ok(h:issue_handle('entity', value, 'example'))
    eq(h:resolve_handle(handle, 'entity'), value)
    refused(h:resolve_handle(handle, 'texture')); refused(another:resolve_handle(handle, 'entity'))
    refused(h:resolve_handle(handle, 'entity', 'another')); refused(h:release_handle(handle, 'another'))
    eq(h:resolve_handle(handle, 'entity', 'example'), value)
    refused(h:resolve_handle({}, 'entity')); h:release_handle(handle); refused(h:resolve_handle(handle, 'entity'))
    local owned = ok(h:issue_handle('entity', value, 'example')); ok(h:stop('example')); refused(h:resolve_handle(owned, 'entity'))
end)

test('stopping dependents is refused before revoking the dependency', function()
    local h, calls, dep = host(), 0, nil
    ok(h:load({plugin('dep', function(api) dep = api end), plugin('consumer', nil, {dependencies = {dep = 1}})}))
    refused(h:stop('dep'))
    ok(dep.tasks.defer('update', function() calls = calls + 1 end)); h:pump('update'); eq(calls, 1)
    ok(h:stop('consumer')); ok(h:stop('dep')); refused(dep.tasks.defer('update', function() end))
end)

test('cleanup acknowledges explicitly, runs LIFO and retries only pending callbacks', function()
    local h, api, called, attempt = host(), nil, {}, 0
    ok(h:load({plugin('example', function(value)
        api = value
        api.on_cleanup(function() called[#called + 1] = 'done'; return true end)
        api.on_cleanup(function() called[#called + 1] = 'false'; return attempt >= 3 end)
        api.on_cleanup(function() called[#called + 1] = 'nil'; if attempt >= 2 then return true end end)
        api.on_cleanup(function() called[#called + 1] = 'error'; if attempt == 0 then error('release pending') end; return true end)
    end)}))
    refused(h:stop('example')); eq(table.concat(called, ','), 'error')
    refused(api.tasks.defer('update', function() end))
    attempt = 1; refused(h:stop('example')); eq(table.concat(called, ','), 'error,error,nil')
    attempt = 2; refused(h:stop('example')); eq(table.concat(called, ','), 'error,error,nil,nil,false')
    attempt = 3; ok(h:stop('example')); eq(table.concat(called, ','), 'error,error,nil,nil,false,false,done')
end)

test('registries, cleanup stack and diagnostic history obey configured bounds', function()
    local h = host({max_plugins = 1, max_providers = 1, max_handles = 1, max_subscriptions = 1, max_cleanups = 1, max_errors = 2})
    provider(h, {read = function() return true end})
    refused(h:register_provider({name = 'second', major = 1, scope = 'portable', capabilities = {}, methods = {read = function() end}}))
    local api = load_api(h)
    refused(h:load({plugin('second')}))
    local first = ok(h:issue_handle('entity', {}, 'example')); refused(h:issue_handle('entity', {}, 'example'))
    h:release_handle(first); ok(h:issue_handle('entity', {}, 'example'))
    local cancel = ok(api.events.on('host.ready', function() end)); refused(api.events.on('host.other', function() end))
    cancel(); ok(api.events.on('host.other', function() end))
    ok(api.on_cleanup(function() return true end)); refused(api.on_cleanup(function() return true end))
    for index = 1, 3 do local value = index; ok(api.tasks.defer('update', function() error('fault ' .. value) end)) end
    h:pump('update'); eq(#h:status().errors, 2)
end)

test('host lifecycle mutations refuse reentry during startup, pump and cleanup', function()
    local h, api, checks = host(), nil, 0
    local function blocked()
        refused(h:load({plugin('nested')}))
        refused(h:register_provider({name = 'nested', major = 1, scope = 'portable', capabilities = {}, methods = {read = function() end}}))
        refused(h:stop('example')); refused(h:advance_world()); refused(h:shutdown())
        checks = checks + 1
    end
    ok(h:load({plugin('example', function(value) api = value; blocked(); api.on_cleanup(function() blocked(); return true end) end)}))
    ok(api.tasks.defer('update', blocked)); h:pump('update'); ok(h:stop('example')); eq(checks, 3)
end)

test('shutdown cleans plugins in reverse dependency order', function()
    local h, order = host(), {}
    local function start(api) api.on_cleanup(function() order[#order + 1] = api.id; return true end) end
    ok(h:load({plugin('c', start, {dependencies = {b = 1}}), plugin('a', start), plugin('b', start, {dependencies = {a = 1}})}))
    ok(h:shutdown()); eq(table.concat(order, ','), 'c,b,a'); eq(h:status().queued_tasks, 0); eq(h:status().handles, 0)
end)

test('status returns isolated snapshots instead of mutable kernel records', function()
    local h = host()
    provider(h, {read = function() return true end})
    local api = load_api(h)
    ok(api.tasks.defer('update', function() error('create diagnostic') end)); h:pump('update')
    local before = h:status(); local epoch, count, original_message = before.world_epoch, #before.errors, before.errors[1].message
    before.world_epoch = -1; before.plugins[1].id = 'mutated'; before.providers[1].capabilities[1] = 'mutated'; before.errors[1].message = 'mutated'
    before.plugins.injected = {}; before.providers.injected = {}; before.errors[#before.errors + 1] = 'injected'
    local after = h:status(); eq(after.world_epoch, epoch); eq(after.plugins.injected, nil); eq(after.providers.injected, nil); eq(#after.errors, count)
    eq(after.plugins[1].id, 'example'); eq(after.providers[1].capabilities[1], 'world.read'); eq(after.errors[1].message, original_message)
end)

test('throwing provider descriptors cannot strand registration state', function()
    local h = host()
    refused(h:register_provider(setmetatable({}, {__index = function() error('broken descriptor') end})))
    provider(h, {read = function() return 42 end})
    local api = load_api(h)
    eq(ok(api.services.get('world', 1)).read(), 42)
    ok(h:shutdown())
end)

test('overlapping plugin namespaces are rejected before any batch startup', function()
    local h, started = host(), 0
    refused(h:load({plugin('author.child', function() started = started + 1 end), plugin('author', function() started = started + 1 end)}))
    eq(started, 0)
    ok(h:load({plugin('author.child')}))
    refused(h:load({plugin('author')}))
    ok(h:stop('author.child')); ok(h:load({plugin('author')}))
    refused(h:load({plugin('author.child')}))
    ok(h:shutdown())
end)

test('yielding task cannot suspend the pump or consume later callbacks', function()
    local h, began, completed, leaked = host(), 0, 0, nil
    local api = load_api(h)
    ok(api.tasks.defer('update', function()
        began = began + 1; leaked = coroutine.running(); coroutine.yield('not a completed task')
        completed = completed + 100
    end))
    ok(api.tasks.defer('update', function() completed = completed + 1 end))
    eq(h:pump('update'), 2); eq(began, 1); eq(completed, 1); eq(coroutine.status(leaked), 'suspended')
    eq(h:status().errors[1].message, 'callback_yielded')
    ok(api.tasks.defer('update', function() completed = completed + 1 end)); eq(h:pump('update'), 1); eq(completed, 2)
    eq(coroutine.status(leaked), 'suspended'); ok(h:stop('example'))
end)

test('yielding event isolates subscribers and preserves delivery parameters', function()
    local h, leaked, calls = host(), nil, 0
    local api = load_api(h); local payload = {answer = 42}; local epoch = h:status().world_epoch
    ok(api.events.on('host.ready', function(value, context)
        eq(value, payload); eq(context.topic, 'host.ready'); eq(context.world_epoch, epoch)
        leaked = coroutine.running(); coroutine.yield(); calls = calls + 100
    end))
    ok(api.events.on('host.ready', function(value, context)
        eq(value, payload); eq(context.topic, 'host.ready'); eq(context.world_epoch, epoch); calls = calls + 1
    end))
    ok(h:emit('host.ready', payload)); eq(h:pump('update'), 0); eq(calls, 1)
    eq(h:status().errors[1].message, 'callback_yielded'); eq(coroutine.status(leaked), 'suspended')
    ok(h:advance_world()); ok(h:stop('example'))
end)

test('yielding plugin startup rolls back partial resources and releases loading state', function()
    local h, api, facade, leaked, cleaned = host(), nil, nil, nil, 0
    refused(h:load({plugin('example', function(value)
        api = value
        ok(api.services.publish('example.read', 1, {read = function() return 42 end}))
        facade = ok(api.services.get('example.read', 1))
        ok(h:issue_handle('entity', {}, 'example'))
        ok(api.events.on('host.ready', function() error('aborted subscriber') end))
        ok(api.tasks.defer('update', function() error('aborted task') end))
        ok(api.on_cleanup(function() cleaned = cleaned + 1; return true end))
        leaked = coroutine.running(); coroutine.yield('startup suspended')
        return true
    end)}))
    eq(cleaned, 1); eq(#h:status().plugins, 0); eq(h:status().handles, 0); eq(h:status().queued_tasks, 0)
    eq(h:status().errors[1].message, 'callback_yielded'); eq(coroutine.status(leaked), 'suspended')
    refused(api.tasks.defer('update', function() end)); refused(facade.read())
    load_api(h, 'another'); eq(h:pump('update'), 0); ok(h:shutdown())
end)

test('yielding cleanup remains pending and retries the callback without resuming it', function()
    local h, attempt, released, leaked = host(), 0, 0, nil
    local api = load_api(h)
    ok(api.on_cleanup(function() released = released + 1; return true end))
    ok(api.on_cleanup(function()
        attempt = attempt + 1
        if attempt == 1 then leaked = coroutine.running(); coroutine.yield('release pending') end
        return true
    end))
    refused(h:stop('example')); eq(attempt, 1); eq(released, 0); eq(h:status().plugins[1].state, 'stopping')
    eq(h:status().errors[1].message, 'callback_yielded'); refused(api.tasks.defer('update', function() end))
    ok(h:stop('example')); eq(attempt, 2); eq(released, 1); eq(coroutine.status(leaked), 'suspended')
    load_api(h, 'another'); ok(h:shutdown())
end)

test('yielding engine validator remains unavailable and releases registration state', function()
    local h, leaked = host(), nil
    provider(h, {read = function() error('unverified native function') end}, {scope = 'engine', builds = {BUILD}, validate = function(build)
        eq(build.exe_sha256, BUILD.exe_sha256); eq(build.game_sha256, BUILD.game_sha256)
        leaked = coroutine.running(); coroutine.yield('not validated'); return true
    end})
    local api = load_api(h)
    local available, why = api.capabilities.has('world.read'); eq(available, false); eq(why, 'callback_yielded')
    refused(api.services.get('world', 1)); eq(coroutine.status(leaked), 'suspended')
    ok(h:register_provider({name = 'another', major = 1, scope = 'portable', methods = {read = function() return true end}}))
    ok(h:shutdown())
end)

test('yielding ownership check prevents method dispatch and restores call depth', function()
    local h, leaked, calls, should_yield = host({max_call_depth = 1}), nil, 0, true
    provider(h, {read = function(context, ...)
        eq(context.plugin, 'example'); calls = calls + 1; return ...
    end}, {check = function(context)
        eq(context.plugin, 'example')
        if should_yield then leaked = coroutine.running(); coroutine.yield(); return true end
        return true
    end})
    local api = load_api(h); local service = ok(api.services.get('world', 1))
    local value, why = service.read(42); eq(value, nil); eq(why, 'callback_yielded'); eq(calls, 0)
    should_yield = false
    local result = pack(service.read(false, nil, 42, nil)); eq(result.n, 4); eq(result[1], false); eq(result[3], 42)
    eq(calls, 1); eq(coroutine.status(leaked), 'suspended'); ok(h:shutdown())
end)

test('yielding service method restores call depth and preserves later return slots', function()
    local h, leaked = host({max_call_depth = 1}), nil
    provider(h, {
        suspend = function(context, value) eq(context.plugin, 'example'); eq(value, 42); leaked = coroutine.running(); coroutine.yield('partial result'); return 'resumed' end,
        echo = function(context, ...) eq(context.plugin, 'example'); return ... end,
    })
    local api = load_api(h); local service = ok(api.services.get('world', 1))
    local value, why = service.suspend(42); eq(value, nil); eq(why, 'provider_error')
    eq(h:status().errors[1].message, 'callback_yielded')
    local result = pack(service.echo(false, nil, 'last', nil)); eq(result.n, 4); eq(result[1], false); eq(result[3], 'last')
    eq(coroutine.status(leaked), 'suspended'); ok(h:stop('example'))
end)

test('yielding descriptor getters cannot strand registration or publish a partial provider', function()
    local h, leaked = host(), nil
    local spec = setmetatable({}, {__index = function()
        leaked = coroutine.running(); coroutine.yield('descriptor incomplete'); return 'world'
    end})
    refused(h:register_provider(spec)); eq(#h:status().providers, 0); eq(h:status().errors[1].message, 'callback_yielded')
    provider(h, {read = function() return true end}); load_api(h); eq(coroutine.status(leaked), 'suspended'); ok(h:shutdown())
end)

test('error formatting never executes user tostring and bounds diagnostic strings', function()
    local h, formatted = host(), 0
    local object = setmetatable({}, {__tostring = function() formatted = formatted + 1; coroutine.yield('unsafe formatting'); return 'forged' end})
    provider(h, {object_error = function() error(object) end, string_error = function() error(string.rep('x', 2048)) end})
    local api = load_api(h); local service = ok(api.services.get('world', 1))
    refused(service.object_error()); refused(service.string_error())
    eq(formatted, 0); eq(h:status().errors[1].message, 'non-scalar error (table)'); assert(#h:status().errors[2].message <= 512)
    ok(h:shutdown())
end)

test('yield isolation still enforces queue and per-pump budgets', function()
    local h, nested, other, overflow = host({queue_limit = 2, max_tasks_per_pump = 1}), 0, 0, nil
    local api = load_api(h)
    ok(api.tasks.defer('update', function()
        ok(api.tasks.defer('update', function() nested = nested + 1 end))
        overflow = pack(api.tasks.defer('update', function() error('queue overflow task') end))
        coroutine.yield()
    end))
    ok(api.tasks.defer('update', function() other = other + 1 end))
    eq(h:pump('update'), 1); eq(nested, 0); eq(other, 0); refused(overflow[1], overflow[2]); eq(h:status().queued_tasks, 2)
    eq(h:pump('update'), 1); eq(other, 1); eq(nested, 0)
    eq(h:pump('update'), 1); eq(other, 1); eq(nested, 1); ok(h:shutdown())
end)

test('externally resumed abandoned callback cannot regain stopped owner APIs', function()
    local h, leaked, denied, native_calls = host(), nil, nil, 0
    provider(h, {read = function() native_calls = native_calls + 1; return 42 end})
    local api = load_api(h); local service = ok(api.services.get('world', 1))
    ok(api.tasks.defer('update', function()
        leaked = coroutine.running(); coroutine.yield()
        denied = {pack(api.tasks.defer('update', function() end)), pack(api.services.get('world', 1)), pack(service.read())}
    end))
    eq(h:pump('update'), 1); ok(h:stop('example'))
    -- Lua 5.1 cannot forcibly close a leaked coroutine. The kernel never resumes
    -- it; owner guards must still reject its public SDK/native service access.
    ok(coroutine.resume(leaked)); eq(coroutine.status(leaked), 'dead')
    for _, result in ipairs(denied) do refused(result[1], result[2]) end
    eq(native_calls, 0); eq(h:status().queued_tasks, 0)
end)

if #failed > 0 then io.stdout:flush(); error(tostring(#failed) .. ' of ' .. tostring(cases) .. ' HD2SE contract cases failed:\n' .. table.concat(failed, '\n')) end
print('PASS ' .. tostring(cases) .. ' HD2SE contract cases; mock providers, no native/game proof')
io.stdout:flush()
