-- Synthetic native weak references. Game validation is performed separately.
local B = dofile('sdk/hd2se/src/stingray_bridge.lua')
local K = dofile('sdk/hd2se/src/kernel.lua')
local P = dofile('sdk/hd2se/src/world_provider.lua')
local cases, failed = 0, {}
local function eq(actual, expected) assert(actual == expected, 'expected ' .. tostring(expected) .. ', got ' .. tostring(actual)) end
local function ok(value, reason) assert(value, tostring(reason or 'expected success')); return value end
local function inventory_refusal(reason, location, problem, maximum)
    local prefix = 'invalid_engine_inventory:' .. location .. ':' .. (problem or '')
    eq(reason:sub(1, #prefix), prefix)
    if maximum then ok(reason:find('limit=' .. maximum, 1, true)) end
    ok(#reason <= 256)
end
local function test(name, fn)
    cases = cases + 1
    local success, reason = xpcall(fn, debug.traceback)
    if success then print('PASS Stingray: ' .. name)
    else failed[#failed + 1] = name .. ': ' .. tostring(reason); print('FAIL Stingray: ' .. name .. ': ' .. tostring(reason)) end
end
local function copy_array(value) local result = {}; for i, entry in ipairs(value) do result[i] = entry end; return result end
local world_mt = {__eq = function(a, b) return a.native == b.native end, __index = function(value, key) return value.native[key] end}
local function wrapper(native) return setmetatable({native = native}, world_mt) end
local function unit(address, generation) return {address = address, generation = generation, live = true, resource = '465f4895f3dc98d1'} end
local function fixture(options)
    options = options or {}
    local entity = unit(7, 1)
    local data = {units = {entity}, levels = {{address = 3}}, revision = 'scene:1'}
    local world = wrapper(data)
    local state = {worlds = {world}, thread = 41, calls = 0, resource_calls = 0, position_calls = 0, transitions = {}}
    local function native()
        ok(state.engine_update, 'native binding called outside synthetic engine update')
        state.calls = state.calls + 1
    end
    local sr = {
        Application = {worlds = function()
            native(); if state.fail_worlds then error('world_scan_failure') end
            if state.inventories and state.inventories.worlds then return state.inventories.worlds.value end
            if state.raw_worlds then return state.raw_worlds end
            local result = {}
            for i, ref in ipairs(state.worlds) do result[i] = state.rewrap and wrapper(ref.native) or ref end
            return result
        end},
        World = {
            units = function(ref)
                native(); if state.fail_units then error('unit_scan_failure') end
                if state.inventories and state.inventories.units then return state.inventories.units.value end
                return copy_array(ref.units)
            end,
            levels = function(ref)
                native(); if state.fail_levels then error('level_scan_failure') end
                if state.inventories and state.inventories.levels then return state.inventories.levels.value end
                return copy_array(ref.levels)
            end,
        },
        Unit = {
            alive = function(ref) native(); if state.fail_alive then error('alive_scan_failure') end; return ref.live == true end,
            resource_name = function(ref)
                native(); ok(ref.live, 'dead reference reached resource getter'); state.resource_calls = state.resource_calls + 1
                if state.kill_in_resource then ref.live = false end
                return ref.resource
            end,
            world_position = function(ref, node) native(); ok(ref.live); eq(node, 1); state.position_calls = state.position_calls + 1; return {1, 2, 3} end,
            id = function() error('Unit.id must never define weak reference identity') end,
        },
        IdString64 = {to_hex = function(value) native(); return value end},
        Vector3 = {x = function(v) native(); return v[1] end, y = function(v) native(); return v[2] end, z = function(v) native(); return v[3] end},
    }
    options.current_thread = options.current_thread or function() return state.thread end
    options.on_transition = options.on_transition or function(reason) state.transitions[#state.transitions + 1] = reason end
    local bridge = ok(B.new(sr, options))
    local function update(fn)
        state.engine_update = true
        local success, reason = bridge:update(fn or function() end)
        state.engine_update = false
        return success, reason
    end
    return bridge, state, world, entity, sr, update
end
local function read(bridge, fn) return bridge.adapter.with_read_guard(fn) end
local function identity(bridge, update)
    local world, entity, world_key, entity_key
    ok(update(function()
        ok(read(bridge, function()
            world = bridge.adapter.worlds()[1]
            entity = bridge.adapter.units(world)[1]
            world_key, entity_key = bridge.adapter.world_key(world), bridge.adapter.entity_key(entity)
        end))
    end))
    return world, entity, world_key, entity_key
end

test('construction requires actual bindings thread identity and a scene signal', function()
    local _, state, _, _, sr = fixture()
    local value, reason = B.new(sr, {}); eq(value, nil); eq(reason, 'current_thread_required')
    sr.World.levels = nil
    value, reason = B.new(sr, {current_thread = function() return state.thread end}); eq(value, nil); eq(reason, 'scene_signal_required')
    ok(B.new(sr, {current_thread = function() return state.thread end, scene_key = function(ref) return ref.revision end}))
    sr.Unit.alive = nil
    value, reason = B.new(sr, {current_thread = function() return 1 end}); eq(value, nil); eq(reason, 'missing_engine_binding')
end)

test('constructor limits and level inventory bounds remain explicit and finite', function()
    local _, _, _, _, sr = fixture()
    for _, limits in ipairs({{max_worlds = 0}, {max_entities = 65537}, {max_registry = false}, {max_levels = 513}}) do
        limits.current_thread = function() return 1 end
        local value, reason = B.new(sr, limits); eq(value, nil); eq(reason, 'invalid_bridge_limits')
    end
    local value, reason = B.new(sr, 7); eq(value, nil); eq(reason, 'invalid_bridge_options')
    local bridge, _, world, _, _, update = fixture({max_levels = 1})
    identity(bridge, update); world.native.levels[2] = {address = 4}
    value, reason = update(); eq(value, nil); inventory_refusal(reason, 'levels', nil, 1); eq(bridge:status().generation, 1)
end)

test('bridge confines borrowed reads to same-thread synchronous engine update', function()
    local bridge, state, _, _, _, update = fixture()
    local calls = state.calls
    local accepted, reason = read(bridge, function() error('must not run') end); eq(accepted, false); eq(reason, 'outside_engine_update')
    eq(state.calls, calls)
    local success, why = pcall(bridge.adapter.worlds); eq(success, false); eq(why, 'outside_read_guard')
    identity(bridge, update); state.thread = 42
    local value; value, reason = update(); eq(value, nil); eq(reason, 'wrong_engine_thread')
    state.thread = 41
    ok(update(function()
        state.thread = 42
        accepted, reason = read(bridge, function() error('must not run') end)
        eq(accepted, false); eq(reason, 'wrong_engine_thread')
        state.thread = 41
    end))
end)

test('native weak reference identities remain stable without Unit.id or pointer text', function()
    local bridge, state, _, _, _, update = fixture()
    local world, entity, world_key, entity_key = identity(bridge, update)
    local again_world, again_entity, again_world_key, again_entity_key = identity(bridge, update)
    eq(world, again_world); eq(entity, again_entity); eq(world_key, again_world_key); eq(entity_key, again_entity_key)
    ok(world_key:match('^world:%d+:%d+$')); ok(entity_key:match('^entity:%d+:%d+$'))
    eq(#state.transitions, 0)
end)

test('equal newly wrapped worlds canonicalize to the retained engine reference', function()
    local bridge, state, _, _, _, update = fixture()
    local world, entity, world_key, entity_key = identity(bridge, update)
    state.rewrap = true
    local next_world, next_entity, next_world_key, next_entity_key = identity(bridge, update)
    ok(rawequal(world, next_world)); ok(rawequal(entity, next_entity)); eq(world_key, next_world_key); eq(entity_key, next_entity_key)
    eq(#state.transitions, 0)
end)

test('dead weak references and a replacement at the same address get different keys', function()
    local bridge, _, world, original, _, update = fixture()
    local _, old_ref, _, old_key = identity(bridge, update)
    original.live = false; local replacement = unit(original.address, 2); world.native.units = {replacement}
    local _, new_ref, _, new_key = identity(bridge, update)
    eq(old_ref, original); eq(new_ref, replacement); assert(old_key ~= new_key)
    ok(update(function()
        local success, why = pcall(function() read(bridge, function() bridge.adapter.describe(old_ref) end) end)
        eq(success, false); eq(why, 'stale_entity')
        ok(read(bridge, function() eq(bridge.adapter.describe(new_ref).alive, true) end))
    end))
end)

test('dead members disappear from fresh reads without reaching any unsafe getter', function()
    local bridge, state, _, entity, _, update = fixture()
    local world = identity(bridge, update)
    ok(update(function()
        entity.live = false
        ok(read(bridge, function() eq(#bridge.adapter.units(world), 0) end))
        local success, why = pcall(function() read(bridge, function() bridge.adapter.describe(entity) end) end)
        eq(success, false); eq(why, 'stale_entity')
    end))
    eq(state.resource_calls, 0); eq(state.position_calls, 0)
end)

test('unknown live members introduced after scan wait for the next complete commit', function()
    local bridge, _, world, _, _, update = fixture()
    local ref = identity(bridge, update)
    ok(update(function()
        world.native.units[2] = unit(8, 1)
        local success, why = pcall(function() read(bridge, function() bridge.adapter.units(ref) end) end)
        eq(success, false); eq(why, 'inventory_changed')
    end))
    ok(update(function() ok(read(bridge, function() eq(#bridge.adapter.units(ref), 2) end)) end))
end)

test('same world scene replacement advances generation before update consumers', function()
    local bridge, state, world, _, _, update = fixture()
    local _, _, old_world_key, old_entity_key = identity(bridge, update)
    world.native.levels = {{address = 4}}
    local _, _, new_world_key, new_entity_key = identity(bridge, update)
    eq(bridge:status().generation, 2); eq(#state.transitions, 1); eq(state.transitions[1], 'scene_changed')
    assert(old_world_key ~= new_world_key and old_entity_key ~= new_entity_key)
end)

test('level ordering alone does not invent a scene transition', function()
    local bridge, state, world, _, _, update = fixture()
    world.native.levels[2] = {address = 4}
    identity(bridge, update)
    world.native.levels = {world.native.levels[2], world.native.levels[1]}
    identity(bridge, update); eq(#state.transitions, 0); eq(bridge:status().generation, 1)
end)

test('world disappearance and later recreation change lifetime generation', function()
    local bridge, state, world, entity, _, update = fixture()
    local _, _, old_key = identity(bridge, update)
    state.worlds = {}; ok(update()); eq(bridge:status().generation, 2); eq(bridge:status().worlds, 0); eq(bridge:status().entities, 0)
    eq(#state.transitions, 1); eq(state.transitions[1], 'world_removed')
    state.worlds = {wrapper({units = {entity}, levels = world.native.levels})}
    local _, _, new_key = identity(bridge, update); assert(old_key ~= new_key)
end)

test('failed partial scans preserve committed registry generation and transition state', function()
    local bridge, state, world, _, _, update = fixture()
    local _, _, world_key, entity_key = identity(bridge, update)
    state.worlds[2] = wrapper({units = {unit(8, 1)}, levels = {}})
    for _, failure in ipairs({'fail_worlds', 'fail_units', 'fail_levels', 'fail_alive'}) do
        state[failure] = true
        local invoked = false; local success, why = update(function() invoked = true end)
        eq(success, nil); ok(type(why) == 'string'); eq(invoked, false)
        eq(bridge:status().worlds, 1); eq(bridge:status().entities, 1); eq(bridge:status().generation, 1); eq(#state.transitions, 0)
        state[failure] = false
    end
    state.worlds[2] = nil
    local _, _, retained_world_key, retained_entity_key = identity(bridge, update)
    eq(world_key, retained_world_key); eq(entity_key, retained_entity_key); eq(world.native.units[1].live, true)
end)

test('duplicate world wrappers and rejected transition callbacks cannot partially commit', function()
    local bridge, state, world, _, _, update = fixture()
    identity(bridge, update)
    state.worlds[2] = wrapper(world.native)
    local value, reason = update(); eq(value, nil); eq(reason, 'duplicate_world_identity'); eq(bridge:status().worlds, 1)
    local another, _, another_world, _, _, another_update = fixture({on_transition = function() return false end})
    identity(another, another_update); another_world.native.levels = {{address = 5}}
    value, reason = another_update(); eq(value, nil); eq(reason, 'transition_rejected'); eq(another:status().generation, 1)
    eq(another:status().active, false)
end)

test('inventory and registry limits refuse complete scans without partial commitment', function()
    local bridge, state, world, _, _, update = fixture({max_worlds = 1, max_entities = 1, max_registry = 2})
    identity(bridge, update)
    world.native.units[2] = unit(8, 1)
    local success, reason = update(); eq(success, nil); inventory_refusal(reason, 'units', nil, 1); eq(bridge:status().entities, 1)
    world.native.units[2] = nil; state.worlds[2] = wrapper({units = {}, levels = {}})
    success, reason = update(); eq(success, nil); inventory_refusal(reason, 'worlds', nil, 1); eq(bridge:status().worlds, 1)
    local another, _, another_world, _, _, another_update = fixture({max_registry = 2})
    identity(another, another_update); another_world.native.units[2] = unit(8, 1)
    success, reason = another_update(); eq(success, nil); eq(reason, 'registry_limit'); eq(another:status().entities, 1)
end)

test('refusal diagnostics identify inventory location shape and safe count metadata', function()
    local bridge, state, world, entity, _, update = fixture({max_worlds = 4, max_entities = 4, max_levels = 4})
    local _, _, retained_world_key, retained_entity_key = identity(bridge, update)
    local forbidden = setmetatable({}, {__tostring = function() error('native reference was stringified') end})
    local scenarios = {
        {location = 'worlds', value = false, problem = 'not_table', detail = 'type=boolean'},
        {location = 'levels', value = setmetatable({}, {}), problem = 'metatable'},
        {location = 'units', value = {[forbidden] = entity}, problem = 'key_type', detail = 'type=table'},
        {location = 'units', value = {[0] = entity}, problem = 'key_shape', detail = 'observed_count=1'},
        {location = 'units', value = {[5] = entity}, problem = 'index_limit', detail = 'index=5'},
        {location = 'units', value = {[1e30] = entity}, problem = 'index_limit', detail = 'index=out_of_range'},
        {location = 'units', value = {'untrusted reference value'}, problem = 'reference_type', detail = 'type=string'},
        {location = 'units', value = {forbidden, forbidden}, problem = 'duplicate_reference', detail = 'observed_count=2'},
        {location = 'units', value = {[2] = entity}, problem = 'sparse', detail = 'largest_index=2'},
    }
    for _, scenario in ipairs(scenarios) do
        state.inventories = {[scenario.location] = {value = scenario.value}}
        local invoked = false
        local success, reason = update(function() invoked = true end)
        eq(success, nil); inventory_refusal(reason, scenario.location, scenario.problem, 4)
        if scenario.detail then ok(reason:find(scenario.detail, 1, true)) end
        eq(invoked, false); eq(bridge:status().worlds, 1); eq(bridge:status().entities, 1); eq(bridge:status().generation, 1)
    end
    state.inventories = nil
    local _, _, world_key, entity_key = identity(bridge, update)
    eq(world_key, retained_world_key); eq(entity_key, retained_entity_key); eq(world.native.units[1], entity)
end)

test('default descriptions copy only validated alive and resource metadata', function()
    local bridge, state, _, entity, _, update = fixture()
    identity(bridge, update)
    ok(update(function()
        ok(read(bridge, function()
            local record = bridge.adapter.describe(entity)
            eq(record.alive, true); eq(record.resource_id, '465f4895f3dc98d1'); eq(record.position, nil); eq(record.raw, nil)
            record.resource_id = 'changed'; eq(bridge.adapter.describe(entity).resource_id, entity.resource)
        end))
    end))
    eq(state.position_calls, 0)
end)

test('position reads require explicit option and death during metadata refuses a result', function()
    local bridge, state, _, entity, _, update = fixture({position = true})
    identity(bridge, update)
    ok(update(function() ok(read(bridge, function() local record = bridge.adapter.describe(entity); eq(record.position.x, 1); eq(record.position.z, 3) end)) end))
    eq(state.position_calls, 1); state.kill_in_resource = true
    ok(update(function()
        local success, why = pcall(function() read(bridge, function() bridge.adapter.describe(entity) end) end)
        eq(success, false); eq(why, 'stale_entity')
    end))
end)

test('guards and update callbacks reject yielding and revoke escaped borrowed access', function()
    local bridge, _, _, _, _, update = fixture()
    local suspended
    local success, why = update(function()
        read(bridge, function() suspended = coroutine.running(); coroutine.yield(); bridge.adapter.worlds() end)
    end)
    eq(success, nil); eq(why, 'yield_not_allowed'); eq(bridge:status().active, false)
    ok(update(function()
        ok(read(bridge, function()
            local resumed, result = coroutine.resume(suspended)
            eq(resumed, false); eq(result, 'outside_read_guard')
            eq(#bridge.adapter.worlds(), 1)
        end))
    end))
    local accepted, reason = read(bridge, function() error('must not run') end); eq(accepted, false); eq(reason, 'outside_engine_update')
    success, why = update(function() coroutine.yield() end); eq(success, nil); eq(why, 'yield_not_allowed')
    ok(update())
end)

test('reentry and invalid thread identities refuse before native access', function()
    local bridge, state, _, _, _, update = fixture()
    ok(update(function()
        local value, reason = bridge:update(function() end); eq(value, nil); eq(reason, 'bridge_busy')
        ok(read(bridge, function()
            local accepted, why = read(bridge, function() error('must not run') end); eq(accepted, false); eq(why, 'read_guard_reentry')
        end))
    end))
    local before = state.calls; state.thread = 0
    local value, reason = update(); eq(value, nil); eq(reason, 'invalid_thread_identity'); eq(state.calls, before)
end)

test('provider bridge integration invalidates actual facade handles before scene consumers', function()
    local host
    local bridge, _, world, _, _, update = fixture({on_transition = function() ok(host:advance_world()) end})
    local build = {exe_sha256 = string.rep('a', 64), game_sha256 = string.rep('b', 64)}
    host = K.new({build = build})
    local api, facade, old_entity, changes = nil, nil, nil, 0
    ok(host:register_provider(ok(P.create(host, bridge.adapter, {builds = {build}, validate = function() return true end}))))
    ok(host:load({{manifest = {id = 'consumer', version = 1, api = 1}, start = function(value) api = value; facade = ok(api.services.get('world', 1)) end}}))
    ok(api.tasks.defer('update', function()
        local worlds = ok(facade.list()); old_entity = ok(facade.units(worlds[1]))[1]
        eq(ok(facade.describe(old_entity)).resource_id, '465f4895f3dc98d1')
        ok(facade.release(worlds[1]))
    end))
    ok(update(function() host:pump('update') end)); eq(host:status().handles, 1); eq(#host:status().errors, 0)
    ok(api.events.on('hd2se.world_changed', function()
        changes = changes + 1
        local value, reason = facade.describe(old_entity); eq(value, nil); eq(reason, 'stale_handle')
    end))
    world.native.levels = {{address = 10}}
    ok(update(function() host:pump('update') end))
    eq(host:status().handles, 0); eq(host:status().world_epoch, 2); eq(changes, 1); eq(#host:status().errors, 0)
end)

test('world additions after the baseline revoke the inventory epoch before consumers', function()
    local host, changes = K.new(), 0
    local bridge, state, _, _, _, update = fixture({on_transition = function(reason)
        eq(reason, 'world_added'); changes = changes + 1; ok(host:advance_world())
    end})
    identity(bridge, update); eq(changes, 0)
    local handle = ok(host:issue_handle('world', {}))
    state.worlds[2] = wrapper({units = {}, levels = {}})
    ok(update(function()
        local value, reason = host:resolve_handle(handle, 'world'); eq(value, nil); eq(reason, 'stale_handle')
    end))
    eq(changes, 1); eq(bridge:status().generation, 2); eq(bridge:status().worlds, 2)
end)

if #failed > 0 then error(tostring(#failed) .. ' of ' .. tostring(cases) .. ' Stingray bridge cases failed:\n' .. table.concat(failed, '\n')) end
print('PASS ' .. tostring(cases) .. ' Stingray bridge cases; synthetic native APIs, no game proof')
