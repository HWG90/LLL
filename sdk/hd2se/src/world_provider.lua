-- Read-only World/Entity provider contract. The bridge is injected by a trusted
-- host integration; this module contains no addresses, native calls or profiles.
local P = {}
local type, pairs, pcall, error = type, pairs, pcall, error
local getmetatable, rawget, rawequal = getmetatable, rawget, rawequal
local function pack(...) return {n = select('#', ...), ...} end
local function bounded_integer(value, maximum)
    return type(value) == 'number' and value >= 1 and value <= maximum and value % 1 == 0
end
local function stable_key(value)
    return type(value) == 'string' and #value > 0 and #value <= 256 and not value:find('%c')
end
local function raw_reference(value)
    local kind = type(value)
    return kind == 'table' or kind == 'userdata' or kind == 'cdata' or kind == 'string'
        or (kind == 'number' and value == value and value ~= math.huge and value ~= -math.huge)
end
local function array(value, maximum)
    if type(value) ~= 'table' or getmetatable(value) ~= nil then return nil, 'adapter_contract' end
    local count, largest = 0, 0
    for key, reference in pairs(value) do
        count = count + 1
        if count > maximum or not bounded_integer(key, maximum) or not raw_reference(reference) then return nil, 'adapter_contract' end
        if key > largest then largest = key end
    end
    if largest ~= count then return nil, 'adapter_contract' end
    local out = {}
    for index = 1, count do out[index] = rawget(value, index) end
    return out
end
local function keyed(value, maximum, key_for)
    local references, why = array(value, maximum)
    if not references then return nil, why end
    local result, identities, raw_seen = {}, {}, {}
    for index, reference in ipairs(references) do
        local key = key_for(reference)
        if not stable_key(key) or identities[key] or raw_seen[reference] then return nil, 'adapter_contract' end
        identities[key], raw_seen[reference] = true, true
        result[index] = { raw = reference, key = key }
    end
    return result
end
local function description(value)
    local visiting, fields, bytes = {}, 0, 0
    local function copy(source, depth)
        local kind = type(source)
        if kind == 'boolean' then return source end
        if kind == 'number' and source == source and source ~= math.huge and source ~= -math.huge then return source end
        if kind == 'string' then
            bytes = bytes + #source
            if #source <= 8192 and bytes <= 65536 then return source end
            return nil, 'invalid_description'
        end
        if kind ~= 'table' or depth > 8 or visiting[source] or getmetatable(source) ~= nil then return nil, 'invalid_description' end
        visiting[source] = true
        local result = {}
        for key, item in pairs(source) do
            fields = fields + 1
            if fields > 1024 then return nil, 'invalid_description' end
            if type(key) == 'string' then
                bytes = bytes + #key
                if #key == 0 or #key > 128 or bytes > 65536 then return nil, 'invalid_description' end
            elseif not bounded_integer(key, 2147483647) then return nil, 'invalid_description' end
            local copied, why = copy(item, depth + 1)
            if why then return nil, why end
            result[key] = copied
        end
        visiting[source] = nil
        return result
    end
    if type(value) ~= 'table' then return nil, 'invalid_description' end
    return copy(value, 1)
end

function P.create(host, adapter, profile)
    if type(host) ~= 'table' or type(host.issue_handle) ~= 'function' or type(host.resolve_handle) ~= 'function'
        or type(host.release_handle) ~= 'function' then return nil, 'invalid_host' end
    if type(adapter) ~= 'table' then return nil, 'invalid_adapter' end
    for _, key in ipairs({'with_read_guard', 'worlds', 'units', 'world_key', 'entity_key', 'describe'}) do
        if type(adapter[key]) ~= 'function' then return nil, 'invalid_adapter' end
    end
    if type(profile) ~= 'table' or type(profile.builds) ~= 'table' or next(profile.builds) == nil
        or type(profile.validate) ~= 'function' then return nil, 'invalid_profile' end
    local max_worlds, max_entities = profile.max_worlds, profile.max_entities
    if max_worlds == nil then max_worlds = 32 end
    if max_entities == nil then max_entities = 4096 end
    if not bounded_integer(max_worlds, 256) or not bounded_integer(max_entities, 65536) then return nil, 'invalid_profile_limits' end
    local worlds, units, world_key, entity_key, describe = adapter.worlds, adapter.units, adapter.world_key, adapter.entity_key, adapter.describe
    local with_read_guard = adapter.with_read_guard
    local function world_snapshot() return keyed(worlds(), max_worlds, world_key) end
    local function live_world(envelope)
        local snapshot, why = world_snapshot()
        if not snapshot then return nil, why end
        for _, item in ipairs(snapshot) do
            if rawequal(item.raw, envelope.world) and item.key == envelope.world_key then return true end
        end
        return nil, 'stale_world'
    end
    local function resolve(context, handle, kind)
        local value, why = host:resolve_handle(handle, kind, context.plugin)
        if not value then return nil, why end
        if type(value) ~= 'table' or value.kind ~= kind or not raw_reference(value.world) or not stable_key(value.world_key)
            or (kind == 'entity' and (not raw_reference(value.raw) or not stable_key(value.entity_key))) then return nil, 'invalid_handle' end
        return value
    end
    local function limit(value, maximum)
        if value == nil then return maximum end
        if not bounded_integer(value, maximum) then return nil, 'invalid_limit' end
        return value
    end
    local function guarded(context, fn)
        local allocated = {}
        local function issue(kind, value)
            local handle, why = host:issue_handle(kind, value, context.plugin)
            if handle then allocated[#allocated + 1] = handle end
            return handle, why
        end
        local calls, completed, active, values = 0, false, true, nil
        local success, accepted, why = pcall(with_read_guard, function()
            -- A delayed or repeated callback must never touch native objects.
            if not active then return nil, 'read_guard_contract' end
            calls = calls + 1
            if calls ~= 1 then return nil, 'read_guard_contract' end
            values = pack(fn(issue))
            completed = true
            return true
        end)
        active = false
        local valid = success and accepted == true and calls == 1 and completed
        if not valid or values[1] == nil then
            for _, handle in ipairs(allocated) do host:release_handle(handle, context.plugin) end
        end
        if not success then error(accepted, 0) end
        if not valid then
            if calls == 0 and accepted ~= true then
                return nil, type(why) == 'string' and why:sub(1, 256) or 'read_guard_unavailable'
            end
            return nil, 'read_guard_contract'
        end
        return unpack(values, 1, values.n)
    end
    local functions = {}
    function functions.list(context, requested)
        local maximum, why = limit(requested, max_worlds)
        if not maximum then return nil, why end
        return guarded(context, function(issue)
            local snapshot, reason = world_snapshot()
            if not snapshot then return nil, reason end
            local result = {}
            for index = 1, math.min(maximum, #snapshot) do
                local item = snapshot[index]
                local handle, failure = issue('world', {raw = item.raw, world = item.raw, world_key = item.key, kind = 'world'})
                if not handle then return nil, failure end
                result[index] = handle
            end
            return result, {total = #snapshot, returned = #result, truncated = #result < #snapshot}
        end)
    end
    function functions.units(context, handle, requested)
        local maximum, why = limit(requested, max_entities)
        if not maximum then return nil, why end
        local world, reason = resolve(context, handle, 'world')
        if not world then return nil, reason end
        return guarded(context, function(issue)
            local live, failure = live_world(world)
            if not live then return nil, failure end
            local snapshot, problem = keyed(units(world.raw), max_entities, entity_key)
            if not snapshot then return nil, problem end
            local result = {}
            for index = 1, math.min(maximum, #snapshot) do
                local item = snapshot[index]
                local entity, rejected = issue('entity', {raw = item.raw, world = world.raw, world_key = world.world_key, entity_key = item.key, kind = 'entity'})
                if not entity then return nil, rejected end
                result[index] = entity
            end
            return result, {total = #snapshot, returned = #result, truncated = #result < #snapshot}
        end)
    end
    function functions.describe(context, handle)
        local entity, why = resolve(context, handle, 'entity')
        if not entity then return nil, why end
        return guarded(context, function()
            local live, reason = live_world(entity)
            if not live then return nil, reason end
            local snapshot, failure = keyed(units(entity.world), max_entities, entity_key)
            if not snapshot then return nil, failure end
            for _, item in ipairs(snapshot) do
                if rawequal(item.raw, entity.raw) and item.key == entity.entity_key then return description(describe(entity.raw)) end
            end
            return nil, 'stale_entity'
        end)
    end
    function functions.release(context, handle)
        local value, why = resolve(context, handle, 'world')
        if not value and why == 'handle_type_mismatch' then value, why = resolve(context, handle, 'entity') end
        if not value then return nil, why end
        return host:release_handle(handle, context.plugin)
    end
    return {name = 'world', major = 1, scope = 'engine', phase = 'update', capabilities = {'world.read', 'entities.read'},
        builds = profile.builds, validate = profile.validate, evidence = profile.evidence or 'bridge contract prototype', methods = functions}
end

return P
