-- Synthetic bridge contracts only. These tests do not validate game bindings.
local K = dofile('sdk/hd2se/src/kernel.lua')
local P = dofile('sdk/hd2se/src/world_provider.lua')
local BUILD = {exe_sha256 = string.rep('a', 64), game_sha256 = string.rep('b', 64)}
local cases, failed = 0, {}
local function pack(...) return {n = select('#', ...), ...} end
local function eq(actual, expected) assert(actual == expected, 'expected ' .. tostring(expected) .. ', got ' .. tostring(actual)) end
local function ok(value, reason) assert(value, tostring(reason or 'expected success')); return value end
local function refused(value, reason, expected)
    eq(value, nil); assert(type(reason) == 'string' and #reason > 0, 'missing refusal reason')
    if expected then eq(reason, expected) end
end
local function test(name, fn)
    cases = cases + 1
    local success, why = xpcall(fn, debug.traceback)
    if success then print('PASS world: ' .. name)
    else failed[#failed + 1] = name .. ': ' .. tostring(why); print('FAIL world: ' .. name .. ': ' .. tostring(why)) end
end
local function plugin(h, id)
    local api
    ok(h:load({{manifest = {id = id, version = 1, api = 1}, start = function(value) api = value end}}))
    return api, ok(api.services.get('world', 1))
end
local function update(h, api, fn)
    local completed, problem = false, nil
    ok(api.tasks.defer('update', function()
        local success, why = xpcall(fn, debug.traceback)
        completed = true
        if not success then problem = why end
    end))
    h:pump('update'); ok(completed, 'task was not run')
    if problem then error(problem, 0) end
end
local function fixture(options)
    options = options or {}
    local entity = {key = 'entity:7:1', record = {id = 'unit', position = {x = 1, y = 2, z = 3}, alive = false}}
    local world = {key = 'world:4:1', members = {entity}}
    local state = {worlds = {world}, calls = 0, guard_calls = 0, guarded = false}
    local function touch()
        assert(state.guarded, 'bridge access escaped protected read lifetime')
        state.calls = state.calls + 1
    end
    local adapter = {
        with_read_guard = function(fn)
            state.guard_calls = state.guard_calls + 1
            if state.guard_mode == 'denied' then return false, 'world_not_ready' end
            if state.guard_mode == 'zero' then return true end
            if state.guard_mode == 'delayed' then state.delayed_callback = fn; return true end
            state.guarded = true
            local values = pack(pcall(fn))
            if state.guard_mode == 'repeated' then fn() end
            state.guarded = false
            if state.pending then local pending = state.pending; state.pending = nil; pending() end
            if not values[1] then
                if state.guard_mode == 'swallow' then return true end
                error(values[2], 0)
            end
            if state.guard_mode == 'false_after' then return false end
            return true
        end,
        worlds = function() touch(); return state.worlds end,
        units = function(value) touch(); if state.on_units then state.on_units(value) end; return value.members end,
        world_key = function(value) touch(); return value.key end,
        entity_key = function(value) touch(); return value.key end,
        describe = function(value) touch(); return value.record end,
    }
    local profile = {builds = {BUILD}, validate = function() return true end, max_worlds = options.max_worlds or 4, max_entities = options.max_entities or 8}
    local h = K.new({build = BUILD, max_handles = options.max_handles or 32})
    ok(h:register_provider(ok(P.create(h, adapter, profile))))
    local api, facade = plugin(h, 'example')
    return h, api, facade, state, world, entity, adapter, profile
end
local function handles(h, api, facade)
    local world, entity
    update(h, api, function()
        world = ok(facade.list())[1]
        entity = ok(facade.units(world))[1]
    end)
    return world, entity
end

test('constructor requires trusted adapter and an explicit profile', function()
    local h, _, _, _, _, _, adapter, profile = fixture()
    local value, reason = P.create(h, adapter); refused(value, reason, 'invalid_profile')
    adapter.with_read_guard = nil
    value, reason = P.create(h, adapter, profile); refused(value, reason, 'invalid_adapter')
end)

test('constructor rejects absent bridge methods and invalid bounded limits', function()
    local h, _, _, _, _, _, adapter, profile = fixture()
    local value, reason = P.create(h, adapter); refused(value, reason, 'invalid_profile')
    local missing = {}; for key, fn in pairs(adapter) do missing[key] = fn end; missing.describe = nil
    value, reason = P.create(h, missing, profile); refused(value, reason, 'invalid_adapter')
    for _, count in ipairs({0, -1, 257, 1.5, math.huge, false}) do
        profile.max_worlds = count; value, reason = P.create(h, adapter, profile); refused(value, reason, 'invalid_profile_limits')
    end
    profile.max_worlds = 4; profile.max_entities = 65537
    value, reason = P.create(h, adapter, profile); refused(value, reason, 'invalid_profile_limits')
end)

test('facade gives fresh opaque handles and copied semantic records', function()
    local h, api, facade, _, raw_world, raw_entity = fixture()
    update(h, api, function()
        local first, second = ok(facade.list()), ok(facade.list())
        eq(#first, 1); eq(#second, 1); assert(first[1] ~= second[1]); assert(first[1] ~= raw_world)
        eq(next(first[1]), nil)
        local units = ok(facade.units(first[1])); eq(#units, 1); assert(units[1] ~= raw_entity); eq(next(units[1]), nil)
        local record = ok(facade.describe(units[1])); eq(record.id, 'unit'); eq(record.alive, false)
        assert(record ~= raw_entity.record and record.position ~= raw_entity.record.position)
        record.position.x = -100; record.id = 'changed'
        local again = ok(facade.describe(units[1])); eq(again.position.x, 1); eq(again.id, 'unit')
        ok(facade.release(units[1])); ok(facade.release(first[1])); ok(facade.release(second[1])); eq(h:status().handles, 0)
    end)
end)

test('phase guard runs before the adapter', function()
    local h, api, facade, state = fixture()
    local value, reason = facade.list(); refused(value, reason, 'wrong_phase'); eq(state.calls, 0)
    local completed = false
    ok(api.tasks.defer('render', function()
        value, reason = facade.list(); completed = true
    end)); h:pump('render'); ok(completed); refused(value, reason, 'wrong_phase'); eq(state.calls, 0)
end)

test('unsupported profile is unavailable and never calls its bridge', function()
    local h, _, _, state, _, _, adapter, profile = fixture()
    local other = K.new({build = {exe_sha256 = string.rep('c', 64), game_sha256 = BUILD.game_sha256}})
    ok(other:register_provider(ok(P.create(other, adapter, profile))))
    local api
    ok(other:load({{manifest = {id = 'example', version = 1, api = 1}, start = function(value) api = value end}}))
    local value, reason = api.services.get('world', 1); refused(value, reason, 'unsupported_build'); eq(state.calls, 0)
    eq(h:status().handles, 0)
end)

test('entity identity change on the same native reference is stale', function()
    local h, api, facade, _, _, raw_entity = fixture()
    local _, entity = handles(h, api, facade)
    raw_entity.key = 'entity:7:2'
    update(h, api, function() local value, reason = facade.describe(entity); refused(value, reason, 'stale_entity') end)
end)

test('world identity change on the same native reference is stale', function()
    local h, api, facade, _, raw_world = fixture()
    local world, entity = handles(h, api, facade)
    raw_world.key = 'world:4:2'
    update(h, api, function()
        local value, reason = facade.units(world); refused(value, reason, 'stale_world')
        value, reason = facade.describe(entity); refused(value, reason, 'stale_world')
        ok(facade.release(entity)); ok(facade.release(world))
    end)
end)

test('entity and world disappearance is reevaluated on every read', function()
    local h, api, facade, state, raw_world = fixture()
    local world, entity = handles(h, api, facade)
    raw_world.members = {}
    update(h, api, function() local value, reason = facade.describe(entity); refused(value, reason, 'stale_entity') end)
    state.worlds = {}
    update(h, api, function()
        local value, reason = facade.describe(entity); refused(value, reason, 'stale_world')
        value, reason = facade.units(world); refused(value, reason, 'stale_world')
        eq(#ok(facade.list()), 0)
    end)
end)

test('equal generation keys on replacement references do not revive old handles', function()
    local h, api, facade, state, raw_world, raw_entity = fixture()
    local world, entity = handles(h, api, facade)
    raw_world.members = {{key = raw_entity.key, record = raw_entity.record}}
    update(h, api, function() local value, reason = facade.describe(entity); refused(value, reason, 'stale_entity') end)
    state.worlds = {{key = raw_world.key, members = raw_world.members}}
    update(h, api, function() local value, reason = facade.units(world); refused(value, reason, 'stale_world') end)
end)

test('another plugin cannot resolve or release caller-owned handles', function()
    local h, api, facade = fixture()
    local world, entity = handles(h, api, facade)
    local another_api, another = plugin(h, 'another')
    update(h, another_api, function()
        local value, reason = another.units(world); refused(value, reason, 'handle_owner_mismatch')
        value, reason = another.describe(entity); refused(value, reason, 'handle_owner_mismatch')
        value, reason = another.release(world); refused(value, reason, 'handle_owner_mismatch')
        value, reason = another.release(entity); refused(value, reason, 'handle_owner_mismatch')
    end)
    eq(h:status().handles, 2)
    update(h, api, function() ok(facade.describe(entity)); ok(facade.release(entity)); ok(facade.release(world)) end)
end)

test('host epoch, owner stop, wrong kind and forged handle invalidate access', function()
    local h, api, facade = fixture()
    local world, entity = handles(h, api, facade)
    update(h, api, function()
        local value, reason = facade.describe(world); refused(value, reason, 'handle_type_mismatch')
        value, reason = facade.units(entity); refused(value, reason, 'handle_type_mismatch')
        value, reason = facade.release({}); refused(value, reason, 'stale_handle')
    end)
    ok(h:advance_world()); eq(h:status().handles, 0)
    update(h, api, function()
        local value, reason = facade.describe(entity); refused(value, reason, 'stale_handle')
        value, reason = facade.units(world); refused(value, reason, 'stale_handle')
    end)
    handles(h, api, facade); ok(h:stop('example')); eq(h:status().handles, 0)
    local value, reason = facade.list(); refused(value, reason, 'plugin_inactive')
end)

test('enumeration honors requested limits and rejects invalid limits before bridge calls', function()
    local h, api, facade, state, raw_world, raw_entity = fixture()
    state.worlds[2] = {key = 'world:5:1', members = {}}
    raw_world.members[2] = {key = 'entity:8:1', record = raw_entity.record}
    update(h, api, function()
        local worlds, worlds_info = facade.list(1); ok(worlds); eq(#worlds, 1)
        eq(worlds_info.total, 2); eq(worlds_info.returned, 1); eq(worlds_info.truncated, true)
        local entities, entities_info = facade.units(worlds[1], 1); ok(entities); eq(#entities, 1)
        eq(entities_info.total, 2); eq(entities_info.returned, 1); eq(entities_info.truncated, true)
        local before = state.calls
        for _, argument in ipairs({0, -1, 1.5, '1', false, math.huge, 5}) do
            local value, reason = facade.list(argument); refused(value, reason, 'invalid_limit')
        end
        for _, argument in ipairs({0, -1, 1.5, '1', false, math.huge, 9}) do
            local value, reason = facade.units(worlds[1], argument); refused(value, reason, 'invalid_limit')
        end
        eq(state.calls, before)
    end)
end)

test('over-cap bridge collections fail even when the caller requests one result', function()
    local h, api, facade, state, raw_world = fixture({max_worlds = 1, max_entities = 1})
    local world
    update(h, api, function() world = ok(facade.list())[1] end)
    state.worlds[2] = {key = 'world:5:1', members = {}}
    update(h, api, function() local value, reason = facade.list(1); refused(value, reason, 'adapter_contract') end)
    state.worlds[2] = nil
    raw_world.members[2] = {key = 'entity:8:1', record = {}}
    update(h, api, function() local value, reason = facade.units(world, 1); refused(value, reason, 'adapter_contract') end)
    eq(h:status().handles, 1)
end)

test('malformed arrays and unstable or duplicate identities are refused without allocation', function()
    local h, api, facade, state, raw_world = fixture()
    local original = state.worlds
    local invalid = {{[2] = raw_world}, {raw_world, surprise = raw_world}, {raw_world, raw_world}, setmetatable({raw_world}, {})}
    for _, worlds in ipairs(invalid) do
        state.worlds = worlds
        update(h, api, function() local value, reason = facade.list(); refused(value, reason, 'adapter_contract') end)
        eq(h:status().handles, 0)
    end
    state.worlds = {raw_world, {key = raw_world.key, members = {}}}
    update(h, api, function() local value, reason = facade.list(); refused(value, reason, 'adapter_contract') end)
    state.worlds = original
    for _, key in ipairs({'', 42, string.rep('x', 257), 'world\0001'}) do
        raw_world.key = key
        update(h, api, function() local value, reason = facade.list(); refused(value, reason, 'adapter_contract') end)
    end
    eq(h:status().handles, 0)
end)

test('world handle allocation failure rolls back all partial handles', function()
    local h, api, facade, state = fixture({max_handles = 2})
    state.worlds[2], state.worlds[3] = {key = 'world:5:1', members = {}}, {key = 'world:6:1', members = {}}
    update(h, api, function() local value, reason = facade.list(); refused(value, reason, 'handle_limit') end)
    eq(h:status().handles, 0)
end)

test('entity allocation failure preserves the world and rolls back partial entity handles', function()
    local h, api, facade, _, raw_world = fixture({max_handles = 2})
    raw_world.members[2] = {key = 'entity:8:1', record = {}}
    update(h, api, function()
        local world = ok(facade.list())[1]
        local value, reason = facade.units(world); refused(value, reason, 'handle_limit'); eq(h:status().handles, 1)
        ok(facade.release(world)); eq(h:status().handles, 0)
    end)
end)

test('a trusted host allocation exception rolls back handles and reaches core fault isolation', function()
    local h, api, facade, state = fixture()
    state.worlds[2] = {key = 'world:5:1', members = {}}
    local original, calls = h.issue_handle, 0
    h.issue_handle = function(self, ...)
        calls = calls + 1
        if calls == 2 then error('synthetic allocator exception') end
        return original(self, ...)
    end
    update(h, api, function() local value, reason = facade.list(); refused(value, reason, 'provider_error') end)
    h.issue_handle = original; eq(h:status().handles, 0); eq(#h:status().errors, 1)
end)

test('adapter exceptions remain core-isolated and return no partial result', function()
    local h, api, facade, state = fixture()
    state.worlds[2] = setmetatable({}, {__index = function() error('synthetic generation lookup exception') end})
    update(h, api, function() local value, reason = facade.list(); refused(value, reason, 'provider_error') end)
    eq(h:status().handles, 0); eq(#h:status().errors, 1)
end)

test('unsafe cyclic metatable nonfinite and oversized description values fail closed', function()
    local h, api, facade, _, _, raw_entity = fixture()
    local _, entity = handles(h, api, facade)
    local cycle = {}; cycle.self = cycle
    local deep, cursor = {}, nil; cursor = deep
    for _ = 1, 8 do cursor.child = {}; cursor = cursor.child end
    local wide = {}; for index = 1, 1025 do wide[index] = true end
    local invalid = {cycle, deep, wide, setmetatable({}, {}), {fn = function() end}, {userdata = io.stdout},
        {thread = coroutine.create(function() end)}, {nan = 0/0}, {infinity = math.huge}, {text = string.rep('x', 8193)}, {[{}] = true}}
    for _, record in ipairs(invalid) do
        raw_entity.record = record
        update(h, api, function() local value, reason = facade.describe(entity); refused(value, reason, 'invalid_description') end)
    end
    raw_entity.record = {safe = true}
    update(h, api, function() eq(ok(facade.describe(entity)).safe, true) end)
end)

test('guard denial invokes no bridge reads and still permits releasing host records', function()
    local h, api, facade, state = fixture()
    local world, entity = handles(h, api, facade)
    local before = state.calls
    state.guard_mode = 'denied'
    update(h, api, function()
        local value, reason = facade.list(); refused(value, reason, 'world_not_ready')
        value, reason = facade.units(world); refused(value, reason, 'world_not_ready')
        value, reason = facade.describe(entity); refused(value, reason, 'world_not_ready')
        ok(facade.release(entity)); ok(facade.release(world))
    end)
    eq(state.calls, before); eq(h:status().handles, 0); eq(#h:status().errors, 0)
end)

test('guard protects inventories generation checks and description until copying completes', function()
    local h, api, facade, state, raw_world, raw_entity = fixture()
    local world, entity = handles(h, api, facade)
    state.on_units = function(value)
        eq(value, raw_world); ok(state.guarded)
        -- Simulate an integration deferring destruction while a reader owns it.
        state.pending = function() raw_entity.key = 'entity:7:2'; raw_world.members = {} end
    end
    local guards = state.guard_calls
    update(h, api, function()
        eq(ok(facade.describe(entity)).id, 'unit')
        local value, reason = facade.describe(entity); refused(value, reason, 'stale_entity')
        ok(facade.release(entity)); ok(facade.release(world))
    end)
    eq(state.guard_calls, guards + 2); eq(#h:status().errors, 0)
end)

test('malformed zero repeated and false-after-callback guards fail closed with rollback', function()
    for _, mode in ipairs({'zero', 'repeated', 'false_after'}) do
        local h, api, facade, state = fixture()
        state.guard_mode = mode
        update(h, api, function() local value, reason = facade.list(); refused(value, reason, 'read_guard_contract') end)
        eq(h:status().handles, 0); eq(#h:status().errors, 0)
    end
    local h, api, facade, state = fixture()
    local world
    update(h, api, function() world = ok(facade.list())[1] end)
    state.guard_mode = 'false_after'
    update(h, api, function() local value, reason = facade.units(world); refused(value, reason, 'read_guard_contract') end)
    eq(h:status().handles, 1)
end)

test('delayed callbacks and swallowed incomplete callbacks cannot publish handles', function()
    local h, api, facade, state = fixture()
    state.guard_mode = 'delayed'
    update(h, api, function() local value, reason = facade.list(); refused(value, reason, 'read_guard_contract') end)
    local calls = state.calls
    local value, reason = state.delayed_callback(); refused(value, reason, 'read_guard_contract')
    eq(state.calls, calls); eq(h:status().handles, 0)
    state.guard_mode = 'swallow'
    state.worlds = {setmetatable({}, {__index = function() error('callback incomplete') end})}
    update(h, api, function() value, reason = facade.list(); refused(value, reason, 'read_guard_contract') end)
    eq(h:status().handles, 0); eq(#h:status().errors, 0)
end)

test('consumer example queues copied observations and releases every generated handle', function()
    local h, _, _, _, _, raw_entity = fixture({max_worlds = 8, max_entities = 64})
    local observed = {}
    ok(h:load({
        {manifest = {id = 'observer', version = 1, api = 1}, start = function(api)
            ok(api.events.on('entity_inspector.observed', function(record) observed[#observed + 1] = record end))
        end},
        dofile('sdk/hd2se/examples/entity_inspector.lua'),
    }))
    h:pump('update'); eq(#observed, 0); eq(h:status().handles, 0)
    h:pump('update'); eq(#observed, 1); eq(observed[1].id, 'unit')
    assert(observed[1] ~= raw_entity.record); eq(h:status().handles, 0); eq(#h:status().errors, 0)
end)

test('consumer example releases disappeared entities without emitting stale observations', function()
    local h, _, _, state, raw_world = fixture({max_worlds = 8, max_entities = 64})
    state.on_units = function()
        state.pending = function() raw_world.members = {} end
    end
    local observed = 0
    ok(h:load({
        {manifest = {id = 'observer', version = 1, api = 1}, start = function(api)
            ok(api.events.on('entity_inspector.observed', function() observed = observed + 1 end))
        end},
        dofile('sdk/hd2se/examples/entity_inspector.lua'),
    }))
    h:pump('update'); h:pump('update')
    eq(observed, 0); eq(h:status().handles, 0); eq(#h:status().errors, 0)
end)

if #failed > 0 then error(tostring(#failed) .. ' of ' .. tostring(cases) .. ' World/Entity contract cases failed:\n' .. table.concat(failed, '\n')) end
print('PASS ' .. tostring(cases) .. ' World/Entity contract cases; synthetic bridge, no native/game proof')
io.stdout:flush()
