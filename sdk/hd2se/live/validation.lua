-- Finite, opt-in validation of actual Stingray world/Unit lifetimes.
-- Native writes target only an empty private world and its own camera units.
-- step() queues work; the host pumps it inside the actual engine update.
local V = {}
local CAMERA_RESOURCE = '465f4895f3dc98d1'
local MAX_STEPS, MAX_WAIT, MAX_WORLDS, MAX_UNITS = 64, 10, 32, 32768
local names = {'enumerate', 'create_world', 'world_added', 'destroy_unit',
    'unit_destroyed', 'replacement', 'release_world', 'world_retired'}
local function reason(value)
    return type(value) == 'string' and value:sub(1, 512) or 'non_string_error'
end
local function demand(value, why)
    if not value then error(reason(why or 'validation_assertion'), 0) end
    return value
end
local function inventory(value, maximum)
    demand(type(value) == 'table', 'native_inventory_not_table')
    local count, largest, seen = 0, 0, {}
    for key, reference in pairs(value) do
        count = count + 1
        demand(count <= maximum and type(key) == 'number' and key >= 1
            and key % 1 == 0 and key <= maximum, 'native_inventory_limit')
        demand(reference ~= nil and not seen[reference], 'duplicate_native_identity')
        seen[reference] = true
        if key > largest then largest = key end
    end
    demand(largest == count, 'sparse_native_inventory')
    return value
end

function V.new(sr, host, log_callback)
    assert(type(sr) == 'table' and type(host) == 'table', 'validation host required')
    assert(type(log_callback) == 'function', 'validation logger required')
    local A, W, U, ID = sr.Application, sr.World, sr.Unit, sr.IdString64
    local controller = {}
    local api, world, stage, steps, wait = nil, nil, 1, 0, 0
    local done, failed, failure, cleanup_done = false, false, nil, false
    local queued, queued_epoch, cancel_task = false, nil, nil
    local owned_world, owned_units, held = nil, {}, {}
    local creation_uncertain, initial_main, preexisting = false, nil, {}
    local baseline_world, baseline_unit, baseline_epoch
    local own_world_handle, old_unit, replacement
    local cleanup_notice

    local function emit(event, fields) log_callback(event, fields or {}) end
    local function owns_anything()
        return creation_uncertain or (owned_world ~= nil and not owned_world.retired)
    end
    local function fail(why)
        if failed then return end
        failed, failure = true, reason(why)
        -- A logging failure cannot turn an uncertain native outcome into success.
        pcall(emit, 'VALIDATION_FAIL', {stage = names[stage] or 'complete',
            reason = failure, steps = steps, owned_world = owns_anything(),
            created_units = #owned_units})
    end
    local function binding(table_value, key)
        demand(type(table_value) == 'table' and type(table_value[key]) == 'function',
            'missing_binding:' .. key)
        return table_value[key]
    end
    local function native_worlds()
        return inventory(binding(A, 'worlds')(), MAX_WORLDS)
    end
    local function present(reference)
        for _, item in ipairs(native_worlds()) do
            if rawequal(item, reference) then return true end
        end
        return false
    end
    local function alive(reference)
        local value = binding(U, 'alive')(reference)
        demand(value == true or value == false, 'invalid_native_alive_result')
        return value
    end
    local function safe_owned_world()
        demand(owned_world and owned_world.acquired and owned_world.is_new
            and owned_world.raw ~= nil and not preexisting[owned_world.raw],
            'unverified_world_ownership')
        demand(not rawequal(owned_world.raw, initial_main), 'owned_world_is_initial_main')
        if A and type(A.main_world) == 'function' then
            demand(not rawequal(owned_world.raw, A.main_world()), 'owned_world_is_current_main')
        end
        return owned_world.raw
    end
    local function member(world_reference, unit_reference)
        for _, candidate in ipairs(inventory(binding(W, 'units')(world_reference), MAX_UNITS)) do
            if rawequal(candidate, unit_reference) then return true end
        end
        return false
    end
    local function remember(handles)
        for _, handle in ipairs(handles) do held[handle] = true end
        return handles
    end
    local function release(handle)
        if not handle then return end
        local accepted, why = world.release(handle)
        demand(accepted == true or why == 'stale_handle', why or 'handle_release_refused')
        held[handle] = nil
    end
    local function worlds()
        local handles, meta = world.list(MAX_WORLDS)
        demand(handles, meta)
        demand(type(meta) == 'table' and meta.truncated == false and #handles == meta.total,
            'incomplete_sdk_world_inventory')
        remember(handles)
        return handles, meta
    end
    local function units(world_handle, maximum)
        local handles, meta = world.units(world_handle, maximum)
        demand(handles, meta)
        demand(type(meta) == 'table' and type(meta.total) == 'number'
            and meta.total >= #handles, 'invalid_sdk_unit_metadata')
        remember(handles)
        return handles, meta
    end
    local function describe(handle)
        local description, why = world.describe(handle)
        demand(description, why)
        demand(description.alive == true and type(description.resource_id) == 'string'
            and #description.resource_id == 16, 'invalid_copied_entity_metadata')
        return description
    end
    local function refusal(call, expected)
        local value, why = call()
        demand(value == nil and why == expected, 'expected_' .. expected .. '_got_' .. reason(why))
        return why
    end
    local function destroyed_refusal(handle)
        -- Global catalog changes revoke handles too. Either explicit rejection
        -- is safe only after the retained native weak reference proves death.
        demand(old_unit and alive(old_unit.raw) == false, 'old_unit_reference_still_alive')
        local value, why = world.describe(handle)
        demand(value == nil and (why == 'stale_entity' or why == 'stale_handle'),
            'expected_stale_entity_or_stale_handle_got_' .. reason(why))
        return why
    end
    local function find_owned_world()
        local raw_world = safe_owned_world()
        demand(present(raw_world), 'owned_world_no_longer_present')
        local found
        for _, handle in ipairs(worlds()) do
            -- Private resolution is restricted to recognizing this owned object.
            local value, why = host:resolve_handle(handle, 'world', api.id)
            demand(value, why)
            if rawequal(value.world, raw_world) then
                demand(not found, 'duplicate_owned_sdk_world')
                found = handle
            else release(handle) end
        end
        demand(present(raw_world), 'owned_world_retired_during_sdk_lookup')
        return demand(found, 'owned_world_missing_from_sdk')
    end
    local function current_owned_world_handle()
        local raw_world = safe_owned_world()
        demand(present(raw_world), 'owned_world_no_longer_present')
        if own_world_handle then
            local value, why = host:resolve_handle(own_world_handle, 'world', api.id)
            if value then
                demand(rawequal(value.world, raw_world), 'owned_sdk_world_identity_mismatch')
                return own_world_handle
            end
            demand(why == 'stale_handle', why or 'owned_sdk_world_resolution_failed')
            release(own_world_handle)
        end
        own_world_handle = find_owned_world()
        return own_world_handle
    end
    local function find_owned_unit(record)
        demand(owned_world and rawequal(record.world, owned_world.raw), 'owned_unit_world_mismatch')
        local found
        local handles, meta = units(current_owned_world_handle(), 8)
        demand(meta.truncated == false, 'owned_world_unit_inventory_truncated')
        for _, handle in ipairs(handles) do
            local value, why = host:resolve_handle(handle, 'entity', api.id)
            demand(value, why)
            if rawequal(value.raw, record.raw) and rawequal(value.world, owned_world.raw) then
                demand(not found, 'duplicate_owned_sdk_unit')
                found = handle
            else release(handle) end
        end
        return demand(found, 'owned_unit_missing_from_sdk')
    end
    local function spawn_owned()
        local raw_world = safe_owned_world()
        demand(present(raw_world), 'owned_world_no_longer_present')
        local resource = binding(ID, 'from_hex')(CAMERA_RESOURCE)
        if A and type(A.can_get) == 'function' then
            demand(A.can_get('unit', resource) == true, 'camera_resource_unavailable')
        end
        local raw_unit = binding(W, 'spawn_unit')(raw_world, resource)
        demand(raw_unit ~= nil, 'owned_camera_spawn_returned_nil')
        -- Record the exact acquired pair before any further native call.
        local record = {raw = raw_unit, world = raw_world, dead = false}
        owned_units[#owned_units + 1] = record
        demand(alive(raw_unit), 'spawned_camera_not_alive')
        return record
    end

    -- This routine deliberately uses no phase-bound SDK facade. It is also the
    -- plugin's cleanup closure, invoked on the host's actual Lua update thread.
    local function cleanup_native()
        if creation_uncertain then return false, 'world_creation_outcome_unknown' end
        if not owned_world then return true end
        if owned_world.retired then return true end
        local raw_world = safe_owned_world()
        local is_present = present(raw_world)
        if is_present then
            for _, record in ipairs(owned_units) do
                local is_alive = alive(record.raw)
                record.dead = not is_alive
                if is_alive then
                    demand(member(raw_world, record.raw), 'owned_unit_left_private_world')
                end
            end
            if not owned_world.release_returned then
                owned_world.release_attempted = true
                local accepted = binding(A, 'release_world')(raw_world)
                if accepted == false then return false, 'native_world_release_refused' end
                owned_world.release_returned = true
            end
            -- A successful native return is never repeated; retain refs while
            -- world disappearance and all weak-reference deaths are pending.
            if present(raw_world) then return false, 'world_retirement_pending' end
        end
        for _, record in ipairs(owned_units) do
            if alive(record.raw) then return false, 'owned_unit_death_pending' end
            record.dead = true
        end
        owned_world.retired = true
        return true
    end

    function controller:cleanup()
        if cancel_task then cancel_task(); cancel_task = nil end
        queued = false
        local ok, accepted, why = pcall(cleanup_native)
        if not ok then accepted, why = false, reason(accepted) end
        if accepted == true then
            local first_acknowledgement = not cleanup_done
            cleanup_done = true
            held = {}
            if first_acknowledgement and failed then
                pcall(emit, 'VALIDATION_CLEANUP_PASS', {after_failure = true,
                    owned_world = owns_anything(), created_units = #owned_units,
                    native_release_returned = owned_world and owned_world.release_returned == true or false})
            end
            return true
        end
        local notice = reason(why or 'native_cleanup_pending')
        if cleanup_notice ~= notice then
            cleanup_notice = notice
            pcall(emit, 'VALIDATION_CLEANUP_PENDING', {reason = notice, owned_world = owns_anything()})
        end
        return false, notice
    end

    local stages = {}
    function stages.enumerate()
        local world_handles, meta = worlds()
        demand(#world_handles > 0, 'no_real_worlds')
        local largest, samples, total_units = -1, 0, 0
        for _, handle in ipairs(world_handles) do
            local entity_handles, info = units(handle, 8)
            total_units = total_units + info.total
            for _, entity in ipairs(entity_handles) do describe(entity); samples = samples + 1 end
            if info.total > largest and #entity_handles > 0 then
                release(baseline_unit); release(baseline_world)
                baseline_world, baseline_unit, largest = handle, entity_handles[1], info.total
                for index = 2, #entity_handles do release(entity_handles[index]) end
            else
                for _, entity in ipairs(entity_handles) do release(entity) end
                release(handle)
            end
        end
        demand(baseline_world and baseline_unit and samples > 0, 'no_real_entity_sample')
        baseline_epoch = host:status().world_epoch
        emit('ENUMERATION_PASS', {worlds = meta.total, total_units = total_units,
            sampled_entities = samples, largest_world_units = largest, world_epoch = baseline_epoch})
        stage = 2
    end
    function stages.create_world()
        for _, reference in ipairs(native_worlds()) do preexisting[reference] = true end
        initial_main = binding(A, 'main_world')()
        local create_world = binding(A, 'new_world')
        creation_uncertain = true
        local reference = create_world()
        creation_uncertain = false
        demand(reference ~= nil, 'private_world_creation_returned_nil')
        -- Acquisition is recorded immediately; a returned borrowed identity is
        -- retained as an error obligation and can never pass the release guard.
        owned_world = {raw = reference, acquired = true, is_new = not preexisting[reference]}
        safe_owned_world()
        demand(present(reference), 'new_private_world_not_registered')
        emit('OWNED_WORLD_CREATED', {was_main_world = false, borrowed_identity = false})
        stage = 3
    end
    function stages.world_added()
        refusal(function() return world.units(baseline_world, 1) end, 'stale_handle')
        refusal(function() return world.describe(baseline_unit) end, 'stale_handle')
        demand(host:status().world_epoch > baseline_epoch, 'world_addition_did_not_advance_epoch')
        release(baseline_unit); release(baseline_world)
        own_world_handle = find_owned_world()
        emit('WORLD_ADDITION_PASS', {old_world_reason = 'stale_handle', old_unit_reason = 'stale_handle',
            world_epoch = host:status().world_epoch})
        old_unit = spawn_owned()
        emit('OWNED_UNIT_CREATED', {resource_id = CAMERA_RESOURCE})
        stage = 4
    end
    function stages.destroy_unit()
        old_unit.handle = find_owned_unit(old_unit)
        local info = describe(old_unit.handle)
        demand(info.resource_id == CAMERA_RESOURCE, 'owned_camera_resource_mismatch')
        local raw_world = safe_owned_world()
        demand(present(raw_world) and alive(old_unit.raw) and member(raw_world, old_unit.raw),
            'owned_unit_destroy_guard_failed')
        demand(not old_unit.destroy_attempted, 'duplicate_unit_destroy_attempt')
        old_unit.destroy_attempted = true
        local accepted = binding(W, 'destroy_unit')(raw_world, old_unit.raw)
        demand(accepted ~= false, 'native_unit_destroy_refused')
        old_unit.destroy_returned = true
        emit('OWNED_UNIT_DESTROY_REQUESTED', {resource_id = info.resource_id})
        stage, wait = 5, 0
    end
    function stages.unit_destroyed()
        if alive(old_unit.raw) then
            wait = wait + 1
            demand(wait < MAX_WAIT, 'owned_unit_destruction_timeout')
            return
        end
        old_unit.dead = true
        local rejected = destroyed_refusal(old_unit.handle)
        emit('DESTRUCTION_PASS', {native_alive = false, sdk_reason = rejected,
            waited_steps = wait, resource_id = CAMERA_RESOURCE})
        replacement = spawn_owned()
        stage = 6
    end
    function stages.replacement()
        replacement.handle = find_owned_unit(replacement)
        local info = describe(replacement.handle)
        demand(info.resource_id == CAMERA_RESOURCE, 'replacement_camera_resource_mismatch')
        demand(alive(replacement.raw) and alive(old_unit.raw) == false
            and not rawequal(old_unit.raw, replacement.raw), 'old_unit_reference_revived')
        local rejected = destroyed_refusal(old_unit.handle)
        emit('REPLACEMENT_PASS', {resource_id = info.resource_id, old_native_alive = false,
            replacement_alive = true, same_native_reference = false, old_sdk_reason = rejected})
        stage = 7
    end
    function stages.release_world()
        local accepted, why = cleanup_native()
        demand(accepted == true or (owned_world and owned_world.release_returned),
            why or 'owned_world_release_not_acknowledged')
        emit('OWNED_WORLD_RELEASE_REQUESTED', {created_units = #owned_units})
        stage, wait = 8, 0
    end
    function stages.world_retired()
        if present(owned_world.raw) or alive(replacement.raw) then
            wait = wait + 1
            demand(wait < MAX_WAIT, 'owned_world_retirement_timeout')
            return
        end
        demand(alive(old_unit.raw) == false, 'old_unit_reference_revived_at_retirement')
        refusal(function() return world.units(own_world_handle, 1) end, 'stale_handle')
        refusal(function() return world.describe(replacement.handle) end, 'stale_handle')
        refusal(function() return world.describe(old_unit.handle) end, 'stale_handle')
        local snapshot = host:status()
        demand(snapshot.handles == 0 and #snapshot.errors == 0, 'host_handles_or_errors_remain')
        owned_world.retired = true
        for _, record in ipairs(owned_units) do record.dead = true end
        held, cleanup_done = {}, true
        emit('WORLD_RETIRE_PASS', {world_absent = true, replacement_native_alive = false,
            old_native_alive = false, sdk_world_reason = 'stale_handle',
            sdk_unit_reason = 'stale_handle', handles = snapshot.handles,
            errors = #snapshot.errors, world_epoch = snapshot.world_epoch})
        emit('CONTROLLED_LIFECYCLE_PASS', {steps = steps, resource_id = CAMERA_RESOURCE,
            borrowed_worlds_released = 0, borrowed_units_destroyed = 0,
            handles = snapshot.handles, errors = #snapshot.errors,
            natural_mission_transition_proven = false})
        done, stage = true, 9
    end

    function controller:step()
        if done then return true end
        if failed then return false, failure end
        if not api then return false, 'validation_not_started' end
        local epoch = host:status().world_epoch
        -- advance_world can cancel a queued task before its callback executes.
        if queued and queued_epoch == epoch then return false, 'validation_task_pending' end
        queued, queued_epoch = true, epoch
        local cancel, why = api.tasks.defer('update', function()
            queued, cancel_task = false, nil
            if done or failed then return end
            steps = steps + 1
            local ok, problem = pcall(function()
                demand(steps <= MAX_STEPS, 'validation_step_limit')
                demand(stages[names[stage]], 'invalid_validation_stage')()
            end)
            if not ok then fail(problem) end
        end)
        if not cancel then queued = false; fail(why); return false, failure end
        cancel_task = cancel
        return true
    end
    function controller:status()
        return {done = done, failed = failed, stage = names[stage] or 'complete',
            steps = steps, reason = failure, owned = owns_anything(),
            created_units = #owned_units, cleanup_done = cleanup_done,
            creation_uncertain = creation_uncertain,
            world_release_returned = owned_world and owned_world.release_returned == true or false}
    end
    controller.definition = {
        manifest = {id = 'hd2se_validation', api = 1, version = 1,
            capabilities = {'world.read', 'entities.read'}, services = {world = 1}},
        start = function(sdk)
            demand(not api, 'validation_already_started')
            api = sdk
            local service, why = api.services.get('world', 1)
            world = demand(service, why)
            demand(api.on_cleanup(function() return controller:cleanup() end), 'cleanup_registration_failed')
            return true
        end,
    }
    return controller
end

return V
