-- Persistent synthetic lifecycle contracts. These establish validator behavior,
-- not live game proof; all engine objects here are ordinary Lua tables.
local K = dofile('sdk/hd2se/src/kernel.lua')
local P = dofile('sdk/hd2se/src/world_provider.lua')
local B = dofile('sdk/hd2se/src/stingray_bridge.lua')
local V = dofile('sdk/hd2se/live/validation.lua')
local cases, failed = 0, {}
local function eq(actual, expected)
    assert(actual == expected, 'expected ' .. tostring(expected) .. ', got ' .. tostring(actual))
end
local function ok(value, why) assert(value, tostring(why or 'expected success')); return value end
local function test(name, fn)
    cases = cases + 1
    local success, why = xpcall(fn, debug.traceback)
    if success then print('PASS validation: ' .. name)
    else failed[#failed + 1] = name .. ': ' .. tostring(why); print('FAIL validation: ' .. name .. ': ' .. tostring(why)) end
end
local function fixture(options)
    options = options or {}
    local build = {exe_sha256 = string.rep('1', 64), game_sha256 = string.rep('2', 64)}
    local first = {alive = true, resource = string.rep('a', 16)}
    local second = {alive = true, resource = string.rep('b', 16)}
    local main = {units = {first, second}, levels = {{}}}
    local other = {units = {}, levels = {}}
    local state = {worlds = {main, other}, borrowed_worlds = {main, other}, borrowed_units = {first, second},
        frame = 0, releases = 0, destroys = 0, spawns = 0, engine_update = false, logs = {}}
    local function native() ok(state.engine_update, 'native call outside actual update') end
    local function retire(reference)
        for _, unit in ipairs(reference.units) do unit.alive = false end
        reference.units = {}
        for index = #state.worlds, 1, -1 do
            if rawequal(state.worlds[index], reference) then table.remove(state.worlds, index) end
        end
    end
    local sr = {Application = {}, World = {}, Unit = {}, IdString64 = {}}
    sr.Application.worlds = function()
        native()
        if state.retire_at and state.frame >= state.retire_at then
            retire(state.private_world); state.retire_at = nil
        end
        return state.worlds
    end
    sr.Application.main_world = function() native(); return main end
    sr.Application.can_get = function(kind, resource) native(); return kind == 'unit' and resource == '465f4895f3dc98d1' end
    sr.Application.new_world = function()
        native()
        if options.return_borrowed then return main end
        state.private_world = {units = {}, levels = {}, owned = true}
        state.worlds[#state.worlds + 1] = state.private_world
        return state.private_world
    end
    sr.Application.release_world = function(reference)
        native(); ok(rawequal(reference, state.private_world) and reference.owned, 'borrowed world released')
        state.releases = state.releases + 1
        if options.release_delay then state.retire_at = state.frame + options.release_delay
        else retire(reference) end
        if options.release_throws_after_retirement then error('native_error_after_retirement') end
    end
    sr.World.units = function(reference) native(); return reference.units end
    sr.World.levels = function(reference) native(); return reference.levels end
    sr.World.spawn_unit = function(reference, resource)
        native(); ok(rawequal(reference, state.private_world), 'spawn targeted borrowed world')
        state.spawns = state.spawns + 1
        local unit = {alive = true, resource = resource}
        if options.revive_old and state.spawns == 2 then unit = state.first_camera; unit.alive = true end
        reference.units[#reference.units + 1] = unit
        if state.spawns == 1 then state.first_camera = unit end
        return unit
    end
    sr.World.destroy_unit = function(reference, unit)
        native(); ok(rawequal(reference, state.private_world) and rawequal(unit, state.first_camera), 'borrowed unit destroyed')
        state.destroys = state.destroys + 1
        if options.keep_destroyed_alive then return end
        unit.alive = false
        for index = #reference.units, 1, -1 do
            if rawequal(reference.units[index], unit) then table.remove(reference.units, index) end
        end
    end
    sr.Unit.alive = function(unit) native(); return unit and unit.alive == true or false end
    sr.Unit.resource_name = function(unit) native(); ok(unit.alive, 'dead native reference dereferenced'); return unit.resource end
    sr.IdString64.to_hex = function(value) native(); return value end
    sr.IdString64.from_hex = function(value) native(); return value end

    local host = K.new({build = build})
    local bridge = ok(B.new(sr, {current_thread = function() return 23 end,
        on_transition = function() ok(host:advance_world()) end}))
    local provider = ok(P.create(host, bridge.adapter, {builds = {build}, max_entities = 32768,
        validate = function() return true end}))
    local original_describe = provider.methods.describe
    if options.bad_reason or options.not_nil_rejection then
        provider.methods.describe = function(context, handle)
            local value = host:resolve_handle(handle, 'entity', context.plugin)
            if value and rawequal(value.raw, state.first_camera) and state.first_camera.alive == false then
                if options.not_nil_rejection then return false, 'stale_entity' end
                return nil, options.bad_reason
            end
            return original_describe(context, handle)
        end
    end
    ok(host:register_provider(provider))
    local controller = V.new(sr, host, function(event, fields)
        for _, value in pairs(fields) do
            ok(type(value) == 'string' or type(value) == 'number' or type(value) == 'boolean', 'nonprimitive log field')
        end
        state.logs[#state.logs + 1] = {event = event, fields = fields}
    end)
    ok(host:load({controller.definition}))
    local core_resolve = host.resolve_handle
    function host:resolve_handle(handle, kind, owner)
        local value, why = core_resolve(self, handle, kind, owner)
        if state.corrupt_owned_identity and value and kind == 'world' and rawequal(value.world, state.private_world) then
            return {world = main}
        end
        return value, why
    end
    local function update(fn)
        state.frame = state.frame + 1
        state.engine_update = true
        local accepted, why = bridge:update(fn or function() controller:step(); ok(host:pump('update')) end)
        state.engine_update = false
        ok(accepted, why)
    end
    local function add_unrelated()
        local unit = {alive = true, resource = string.rep('c', 16)}
        local reference = {units = {unit}, levels = {{}}}
        state.worlds[#state.worlds + 1] = reference
        state.borrowed_worlds[#state.borrowed_worlds + 1] = reference
        state.borrowed_units[#state.borrowed_units + 1] = unit
    end
    local function run(before)
        for _ = 1, 64 do
            if before then before(controller:status()) end
            update()
            local status = controller:status()
            if status.done or status.failed then return status end
        end
        error('validator_did_not_finish')
    end
    local function untouched()
        for _, unit in ipairs(state.borrowed_units) do eq(unit.alive, true) end
        for _, reference in ipairs(state.borrowed_worlds) do
            local found = false
            for _, current in ipairs(state.worlds) do if rawequal(current, reference) then found = true end end
            ok(found, 'borrowed world was removed')
        end
    end
    local function event(name)
        for _, entry in ipairs(state.logs) do if entry.event == name then return entry.fields end end
    end
    local function failed_once()
        eq(controller:status().failed, true); eq(controller:status().done, false)
        local count = 0
        for _, entry in ipairs(state.logs) do if entry.event == 'VALIDATION_FAIL' then count = count + 1 end end
        eq(count, 1); eq(event('CONTROLLED_LIFECYCLE_PASS'), nil)
    end
    return {controller = controller, host = host, state = state, update = update, run = run,
        add_unrelated = add_unrelated, untouched = untouched, event = event, failed_once = failed_once}
end

test('normal owned lifecycle records native death and stale_entity without touching borrowed objects', function()
    local f = fixture(); local status = f.run()
    eq(status.done, true); eq(status.failed, false); eq(status.owned, false)
    eq(f.event('DESTRUCTION_PASS').native_alive, false); eq(f.event('DESTRUCTION_PASS').sdk_reason, 'stale_entity')
    eq(f.state.releases, 1); eq(f.state.destroys, 1); eq(f.state.spawns, 2)
    eq(f.host:status().handles, 0); eq(#f.host:status().errors, 0); f.untouched()
end)
test('startup catalog changes revoke SDK handles but genuine native death and owned reacquisition still pass', function()
    local f, added = fixture(), {}
    local status = f.run(function(current)
        if (current.stage == 'destroy_unit' or current.stage == 'unit_destroyed' or current.stage == 'replacement')
            and not added[current.stage] then
            added[current.stage] = true; f.add_unrelated()
        end
    end)
    eq(status.done, true); eq(status.failed, false)
    eq(f.event('DESTRUCTION_PASS').native_alive, false); eq(f.event('DESTRUCTION_PASS').sdk_reason, 'stale_handle')
    eq(f.event('REPLACEMENT_PASS').old_sdk_reason, 'stale_handle')
    eq(f.event('REPLACEMENT_PASS').old_native_alive, false)
    eq(f.state.releases, 1); eq(f.state.destroys, 1); eq(f.state.spawns, 2)
    eq(f.host:status().handles, 0); eq(#f.host:status().errors, 0); f.untouched()
end)
test('a transition-cancelled deferred stage is rescheduled in the new epoch', function()
    local f = fixture(); f.update(); eq(f.controller:status().stage, 'create_world')
    ok(f.controller:step()); f.add_unrelated()
    f.update(); eq(f.controller:status().stage, 'world_added')
    local status = f.run(); eq(status.done, true); eq(status.failed, false); f.untouched()
end)
test('a stale SDK token cannot prove destruction while native old reference is still alive', function()
    local f, added = fixture({keep_destroyed_alive = true}), false
    local status = f.run(function(current)
        if current.stage == 'unit_destroyed' and not added then added = true; f.add_unrelated() end
    end)
    eq(status.failed, true); ok(status.reason:find('owned_unit_destruction_timeout', 1, true))
    eq(f.event('DESTRUCTION_PASS'), nil); f.failed_once()
    f.update(function() ok(f.controller:cleanup()) end)
    eq(f.controller:status().owned, false); eq(f.state.releases, 1); f.untouched()
end)
test('unexpected nil rejection fails and failed-run cleanup retains ownership until native retirement', function()
    local f = fixture({bad_reason = 'provider_inactive', release_delay = 3})
    eq(f.run().failed, true); f.failed_once(); eq(f.event('DESTRUCTION_PASS'), nil)
    f.update(function()
        local accepted, why = f.controller:cleanup(); eq(accepted, false); eq(why, 'world_retirement_pending')
        eq(f.controller:status().owned, true); eq(f.controller:status().cleanup_done, false)
        eq(f.controller:cleanup(), false)
    end)
    eq(f.state.releases, 1)
    f.update(function() eq(f.controller:cleanup(), false) end); eq(f.state.releases, 1)
    for _ = 1, 4 do f.update(function() f.controller:cleanup() end) end
    eq(f.controller:status().cleanup_done, true); eq(f.controller:status().owned, false)
    eq(f.controller:status().failed, true); eq(f.controller:status().done, false)
    eq(f.state.releases, 1); eq(f.event('VALIDATION_CLEANUP_PASS').after_failure, true)
    f.update(function() ok(f.host:stop('hd2se_validation')) end)
    eq(f.host:status().handles, 0); eq(#f.host:status().errors, 0); f.untouched()
end)
test('a nonnil value with a stale reason is never accepted as a safe SDK rejection', function()
    local f = fixture({not_nil_rejection = true})
    eq(f.run().failed, true); eq(f.event('DESTRUCTION_PASS'), nil); f.failed_once()
    f.update(function() ok(f.controller:cleanup()) end); f.untouched()
end)
test('wrong cached owned-world identity fails rather than selecting a borrowed world', function()
    local f = fixture()
    local status = f.run(function(current)
        if current.stage == 'destroy_unit' then f.state.corrupt_owned_identity = true end
    end)
    eq(status.failed, true); eq(status.reason, 'owned_sdk_world_identity_mismatch')
    eq(f.state.destroys, 0); f.failed_once()
    f.update(function() ok(f.controller:cleanup()) end); eq(f.state.releases, 1); f.untouched()
end)
test('successfully returned asynchronous world release is never called a second time', function()
    local f = fixture({release_delay = 3}); local status = f.run()
    eq(status.done, true); eq(status.failed, false); eq(f.state.releases, 1)
    eq(f.event('WORLD_RETIRE_PASS').replacement_native_alive, false); f.untouched()
end)
test('an exception after real retirement keeps failure visible and cleanup never repeats native release', function()
    local f = fixture({release_throws_after_retirement = true})
    eq(f.run().failed, true); f.failed_once(); eq(f.state.releases, 1)
    f.update(function() ok(f.controller:cleanup()) end)
    eq(f.state.releases, 1); eq(f.controller:status().cleanup_done, true)
    eq(f.controller:status().owned, false); eq(f.controller:status().failed, true); f.untouched()
end)
test('revived old native identity fails despite a newly issued replacement SDK handle', function()
    local f = fixture({revive_old = true}); eq(f.run().failed, true)
    eq(f.controller:status().reason, 'old_unit_reference_revived'); eq(f.event('REPLACEMENT_PASS'), nil)
    f.failed_once(); f.update(function() ok(f.controller:cleanup()) end); f.untouched()
end)
test('new_world returning an existing identity never permits borrowed-world release', function()
    local f = fixture({return_borrowed = true}); eq(f.run().failed, true); f.failed_once()
    f.update(function() eq(f.controller:cleanup(), false) end)
    eq(f.state.releases, 0); eq(f.state.destroys, 0); eq(f.state.spawns, 0); f.untouched()
end)

if #failed > 0 then error(table.concat(failed, '\n'), 0) end
print('PASS validation contracts: ' .. cases .. ' cases; synthetic only, no live proof')
return {passed = cases, failed = #failed}
