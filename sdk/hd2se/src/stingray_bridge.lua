-- Borrowed Stingray Lua API bridge. No native addresses or memory dereferences.
-- The host must call update only from its actual engine update callback.
local B = {}
local function finite(value)
    return type(value) == 'number' and value == value and value ~= math.huge and value ~= -math.huge
end
local function integer(value, maximum) return finite(value) and value >= 1 and value % 1 == 0 and value <= maximum end
local function message(value) return type(value) == 'string' and value:sub(1, 256) or 'bridge_error' end
local function inventory_error(location, problem, maximum, count, detail)
    local text = 'invalid_engine_inventory:' .. location .. ':' .. problem .. ' limit=' .. maximum
    if count then text = text .. ' observed_count=' .. count end
    if detail then text = text .. ' ' .. detail end
    error(text, 0)
end
local function array(value, maximum, location)
    if type(value) ~= 'table' then inventory_error(location, 'not_table', maximum, nil, 'type=' .. type(value)) end
    if getmetatable(value) ~= nil then inventory_error(location, 'metatable', maximum) end
    local count, largest, seen = 0, 0, {}
    for key, reference in pairs(value) do
        count = count + 1
        if count > maximum then inventory_error(location, 'entry_limit', maximum, count) end
        if type(key) ~= 'number' then inventory_error(location, 'key_type', maximum, count, 'type=' .. type(key)) end
        if not finite(key) or key < 1 or key % 1 ~= 0 then
            inventory_error(location, 'key_shape', maximum, count)
        end
        if key > maximum then
            -- Only bounded array index metadata is printable; never stringify an
            -- engine reference, arbitrary table key or possible native address.
            local detail = key <= 2147483647 and ('index=' .. string.format('%.0f', key)) or 'index=out_of_range'
            inventory_error(location, 'index_limit', maximum, count, detail)
        end
        local kind = type(reference)
        if kind ~= 'userdata' and kind ~= 'table' then inventory_error(location, 'reference_type', maximum, count, 'type=' .. kind .. ' index=' .. key) end
        if seen[reference] then inventory_error(location, 'duplicate_reference', maximum, count, 'index=' .. key) end
        seen[reference] = true
        if key > largest then largest = key end
    end
    if largest ~= count then inventory_error(location, 'sparse', maximum, count, 'largest_index=' .. largest) end
    local out = {}
    for index = 1, count do out[index] = rawget(value, index) end
    return out
end
local function same_levels(first, second)
    if #first ~= #second then return false end
    local used = {}
    for _, reference in ipairs(first) do
        local found
        for index, other in ipairs(second) do
            if not used[index] and reference == other then found = index; break end
        end
        if not found then return false end
        used[found] = true
    end
    return true
end
local function scalar_scene(value)
    return (type(value) == 'string' and #value > 0 and #value <= 256) or finite(value)
end
local function run_sync(fn, before_resume)
    local thread = coroutine.create(fn)
    if before_resume then before_resume(thread) end
    local success, reason = coroutine.resume(thread)
    if not success then return nil, message(reason) end
    if coroutine.status(thread) ~= 'dead' then return nil, 'yield_not_allowed' end
    return true
end

function B.new(sr, options)
    if options == nil then options = {} end
    if type(options) ~= 'table' then return nil, 'invalid_bridge_options' end
    if type(sr) ~= 'table' or type(sr.Application) ~= 'table' or type(sr.Application.worlds) ~= 'function'
        or type(sr.World) ~= 'table' or type(sr.World.units) ~= 'function'
        or type(sr.Unit) ~= 'table' or type(sr.Unit.alive) ~= 'function'
        or type(sr.Unit.resource_name) ~= 'function' or type(sr.IdString64) ~= 'table'
        or type(sr.IdString64.to_hex) ~= 'function' then return nil, 'missing_engine_binding' end
    if type(options.current_thread) ~= 'function' then return nil, 'current_thread_required' end
    if options.on_transition ~= nil and type(options.on_transition) ~= 'function' then return nil, 'invalid_transition_callback' end
    if options.scene_key ~= nil and type(options.scene_key) ~= 'function' then return nil, 'invalid_scene_key' end
    if options.scene_key == nil and type(sr.World.levels) ~= 'function' then return nil, 'scene_signal_required' end
    local max_worlds, max_entities, max_registry, max_levels = options.max_worlds, options.max_entities, options.max_registry, options.max_levels
    if max_worlds == nil then max_worlds = 32 end
    if max_entities == nil then max_entities = 32768 end
    if max_registry == nil then max_registry = 65536 end
    if max_levels == nil then max_levels = 256 end
    if not integer(max_worlds, 256) or not integer(max_entities, 65536) or not integer(max_registry, 262144)
        or not integer(max_levels, 512) then return nil, 'invalid_bridge_limits' end
    local position = options.position == true
    if options.position ~= nil and type(options.position) ~= 'boolean' then return nil, 'invalid_position_option' end
    if position and (type(sr.Unit.world_position) ~= 'function' or type(sr.Vector3) ~= 'table'
        or type(sr.Vector3.x) ~= 'function' or type(sr.Vector3.y) ~= 'function' or type(sr.Vector3.z) ~= 'function') then
        return nil, 'missing_position_binding'
    end
    local application_worlds, world_units, alive = sr.Application.worlds, sr.World.units, sr.Unit.alive
    local world_levels, scene_key = sr.World.levels, options.scene_key
    local resource_name, to_hex = sr.Unit.resource_name, sr.IdString64.to_hex
    local world_position = sr.Unit.world_position
    local vector_x, vector_y, vector_z
    if position then vector_x, vector_y, vector_z = sr.Vector3.x, sr.Vector3.y, sr.Vector3.z end
    local current_thread, on_transition = options.current_thread, options.on_transition
    local bridge, adapter = {}, {}
    local worlds, world_map, entity_map, serial, generation = {}, {}, {}, 0, 1
    local expected_thread, busy, active, borrowing, ready = nil, false, false, false, false
    local function thread_id()
        local value = current_thread()
        if not integer(value, 4294967295) then error('invalid_thread_identity', 0) end
        return value
    end
    local function borrowed()
        if not active or not borrowing or coroutine.running() ~= borrowing then error('outside_read_guard', 0) end
        if thread_id() ~= expected_thread then error('wrong_engine_thread', 0) end
    end
    local function find_world(reference, inventory)
        for _, record in ipairs(inventory) do if reference == record.raw then return record end end
    end
    local function scene(reference)
        if scene_key then
            local value = scene_key(reference)
            if not scalar_scene(value) then error('invalid_scene_key', 0) end
            return value
        end
        return array(world_levels(reference), max_levels, 'levels')
    end
    local function scene_equal(first, second)
        if scene_key then return first == second end
        return same_levels(first, second)
    end
    local function scan()
        local next_worlds, next_world_map, next_entities, next_serial, changed = {}, {}, {}, serial, nil
        local count, matched = 0, {}
        for _, reference in ipairs(array(application_worlds(), max_worlds, 'worlds')) do
            if find_world(reference, next_worlds) then error('duplicate_world_identity', 0) end
            local old = find_world(reference, worlds)
            if old and matched[old] then error('duplicate_world_identity', 0) end
            local revision = scene(reference)
            if old then
                matched[old] = true
                if not scene_equal(old.scene, revision) then changed = 'scene_changed' end
            else
                next_serial = next_serial + 1
                if ready then changed = changed or 'world_added' end
            end
            local record = {raw = old and old.raw or reference, serial = old and old.serial or next_serial, scene = revision, entities = {}}
            next_worlds[#next_worlds + 1], next_world_map[record.raw] = record, record
            count = count + 1
            if count > max_registry then error('registry_limit', 0) end
            for _, unit in ipairs(array(world_units(reference), max_entities, 'units')) do
                if alive(unit) == true then
                    if next_entities[unit] then error('duplicate_entity_identity', 0) end
                    local previous = entity_map[unit]
                    if previous and alive(previous.raw) ~= true then previous = nil end
                    if not previous then next_serial = next_serial + 1 end
                    local entity = {raw = previous and previous.raw or unit, serial = previous and previous.serial or next_serial, world = record}
                    next_entities[entity.raw] = entity
                    record.entities[#record.entities + 1] = entity
                    count = count + 1
                    if count > max_registry then error('registry_limit', 0) end
                end
            end
        end
        for _, old in ipairs(worlds) do
            if not matched[old] and changed ~= 'scene_changed' then changed = 'world_removed' end
        end
        local next_generation = generation + (changed and 1 or 0)
        for _, world in ipairs(next_worlds) do
            world.key = 'world:' .. world.serial .. ':' .. next_generation
            for _, entity in ipairs(world.entities) do entity.key = 'entity:' .. entity.serial .. ':' .. next_generation end
        end
        return {worlds = next_worlds, world_map = next_world_map, entities = next_entities, serial = next_serial,
            generation = next_generation, transition = changed}
    end
    local function current_worlds()
        local result, found = {}, {}
        for _, reference in ipairs(array(application_worlds(), max_worlds, 'worlds')) do
            local record = find_world(reference, worlds)
            if not record or found[record] or not scene_equal(record.scene, scene(reference)) then error('inventory_changed', 0) end
            found[record], result[#result + 1] = true, record.raw
        end
        -- A disappearance can only commit at the next update, before host pump.
        if #result ~= #worlds then error('inventory_changed', 0) end
        return result
    end
    local function current_entities(world)
        local record = world_map[world]
        if not record then error('stale_world', 0) end
        local members, found = {}, {}
        for _, reference in ipairs(array(world_units(record.raw), max_entities, 'units')) do
            if alive(reference) == true then
                local entity = entity_map[reference]
                if not entity or entity.world ~= record or found[entity] then error('inventory_changed', 0) end
                found[entity], members[#members + 1] = true, entity.raw
            end
        end
        return members, found
    end
    function adapter.with_read_guard(callback)
        if type(callback) ~= 'function' then return false, 'invalid_guard_callback' end
        if not active or not ready then return false, 'outside_engine_update' end
        if borrowing then return false, 'read_guard_reentry' end
        if thread_id() ~= expected_thread then return false, 'wrong_engine_thread' end
        local success, reason = run_sync(callback, function(thread) borrowing = thread end)
        borrowing = false
        if not success then error(reason, 0) end
        return true
    end
    function adapter.worlds() borrowed(); return current_worlds() end
    function adapter.units(reference)
        borrowed(); current_worlds()
        local members = current_entities(reference)
        return members
    end
    function adapter.world_key(reference)
        borrowed()
        local record = world_map[reference]
        if not record then error('stale_world', 0) end
        return record.key
    end
    function adapter.entity_key(reference)
        borrowed()
        local record = entity_map[reference]
        if not record or alive(reference) ~= true then error('stale_entity', 0) end
        return record.key
    end
    function adapter.describe(reference)
        borrowed()
        local entity = entity_map[reference]
        if not entity or alive(reference) ~= true then error('stale_entity', 0) end
        current_worlds()
        local _, membership = current_entities(entity.world.raw)
        if not membership[entity] or alive(reference) ~= true then error('stale_entity', 0) end
        local resource = to_hex(resource_name(reference))
        if type(resource) ~= 'string' or #resource ~= 16 or not resource:match('^[0-9a-fA-F]+$') then error('invalid_resource_id', 0) end
        if alive(reference) ~= true then error('stale_entity', 0) end
        local record = {alive = true, resource_id = resource:lower()}
        if position then
            local vector = world_position(reference, 1)
            local x, y, z = vector_x(vector), vector_y(vector), vector_z(vector)
            if not finite(x) or not finite(y) or not finite(z) then error('invalid_position', 0) end
            record.position = {x = x, y = y, z = z}
        end
        if alive(reference) ~= true then error('stale_entity', 0) end
        return record
    end
    function bridge:update(callback)
        if type(callback) ~= 'function' then return nil, 'invalid_update_callback' end
        if busy then return nil, 'bridge_busy' end
        local success, identity = pcall(thread_id)
        if not success then return nil, message(identity) end
        if expected_thread and identity ~= expected_thread then return nil, 'wrong_engine_thread' end
        local update_thread = identity
        busy = true
        local inventory
        success, identity = run_sync(function() inventory = scan() end)
        if not success then busy = false; return nil, identity end
        if inventory.transition and on_transition then
            success, identity = run_sync(function()
                if on_transition(inventory.transition) == false then error('transition_rejected', 0) end
            end)
            if not success then busy = false; return nil, identity end
        end
        success, identity = pcall(thread_id)
        if not success or identity ~= update_thread then busy = false; return nil, success and 'wrong_engine_thread' or message(identity) end
        worlds, world_map, entity_map, serial, generation = inventory.worlds, inventory.world_map, inventory.entities, inventory.serial, inventory.generation
        expected_thread, ready, active = expected_thread or update_thread, true, true
        success, identity = run_sync(callback)
        active, borrowing, busy = false, false, false
        if not success then return nil, identity end
        return true
    end
    function bridge:status()
        local entities = 0; for _ in pairs(entity_map) do entities = entities + 1 end
        return {ready = ready, active = active, generation = generation, worlds = #worlds, entities = entities, thread = expected_thread}
    end
    bridge.adapter = adapter
    return bridge
end

return B
