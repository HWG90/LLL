-- Bounded read-only discovery inside the existing game's Lua update callback.
local token = 'hd2se-bindings-20261013-3'
local file, elapsed, finished
local function write(event, value)
    if file then file:write(token, ' ', event, ' ', tostring(value), '\n'); file:flush() end
end
local function call(label, fn, ...)
    local ok, value = pcall(fn, ...)
    write(label .. '.ok', ok)
    write(label .. '.type', type(value))
    if not ok or type(value) ~= 'table' then write(label .. '.value', value) end
    return ok and value or nil
end
local function inspect()
    local sr = rawget(_G, 'stingray') or {}
    for _, namespace in ipairs({'Application', 'World', 'Unit', 'Vector3', 'IdString64'}) do
        local ns = sr[namespace]
        write('namespace.' .. namespace, type(ns))
        if type(ns) == 'table' then
            local names = {}
            for name, fn in pairs(ns) do if type(name) == 'string' and type(fn) == 'function' then names[#names + 1] = name end end
            table.sort(names)
            write('functions.' .. namespace, table.concat(names, ','))
        end
    end
    if not sr.Application or type(sr.Application.worlds) ~= 'function' then return end
    local worlds = call('worlds', sr.Application.worlds)
    if type(worlds) ~= 'table' then return end
    local again = sr.Application.worlds()
    for _, first in pairs(worlds) do
        for _, second in pairs(again) do
            if first == second then write('world.equality', rawequal(first, second)); break end
        end
        local initial = sr.World.units(first)
        local repeated = sr.World.units(first)
        local first_unit = next(initial) and select(2, next(initial))
        if first_unit then
            for _, candidate in pairs(repeated) do
                if first_unit == candidate then
                    write('unit.equality', rawequal(first_unit, candidate))
                    write('unit.metatable', type(getmetatable(first_unit)))
                    break
                end
            end
        end
        break
    end
    write('global_candidates', (function()
        local names = {}
        for key, value in pairs(_G) do
            if type(key) == 'string' and type(value) == 'table' and (key:lower():find('world') or key:lower():find('session') or key:lower():find('game')) then names[#names + 1] = key end
        end
        table.sort(names); return table.concat(names, ',')
    end)())
    local world_count = 0
    for _, world in pairs(worlds) do
        world_count = world_count + 1
        if world_count > 32 then write('inventory_limit', true); break end
        write('world.' .. world_count .. '.type', type(world))
        write('world.' .. world_count .. '.private_ref', world)
        if type(sr.World.levels) == 'function' then
            local levels = call('levels.' .. world_count, sr.World.levels, world)
            local level_count = 0
            if type(levels) == 'table' then
                local levels_again = sr.World.levels(world)
                for _, level in pairs(levels) do
                    level_count = level_count + 1
                    if level_count <= 2 then
                        write('level.' .. world_count .. '.' .. level_count .. '.type', type(level))
                        write('level.' .. world_count .. '.' .. level_count .. '.private_ref', level)
                        for _, candidate in pairs(levels_again) do if level == candidate then write('level.equality', rawequal(level, candidate)); break end end
                    end
                end
            end
            write('level_count.' .. world_count, level_count)
        end
        local units = sr.World and type(sr.World.units) == 'function' and call('units.' .. world_count, sr.World.units, world)
        if type(units) == 'table' then
            local count, samples = 0, 0
            for _, unit in pairs(units) do
                count = count + 1
                if count > 32768 then write('unit_limit', true); break end
                if samples < 3 then
                    samples = samples + 1
                    local prefix = 'unit.' .. world_count .. '.' .. samples
                    write(prefix .. '.type', type(unit))
                    write(prefix .. '.private_ref', unit)
                    local alive = sr.Unit and type(sr.Unit.alive) == 'function' and call(prefix .. '.alive', sr.Unit.alive, unit)
                    if alive then
                        if type(sr.Unit.num_cameras) == 'function' then call(prefix .. '.cameras', sr.Unit.num_cameras, unit) end
                        if type(sr.Unit.id) == 'function' then call(prefix .. '.id', sr.Unit.id, unit) end
                        if type(sr.Unit.resource_name) == 'function' and sr.IdString64 and type(sr.IdString64.to_hex) == 'function' then
                            local resource = call(prefix .. '.resource', sr.Unit.resource_name, unit)
                            if resource then call(prefix .. '.resource_hex', sr.IdString64.to_hex, resource) end
                        end
                    end
                end
            end
            write('world.' .. world_count .. '.unit_count', count)
        end
    end
    write('world_count', world_count)
    for _, flag in ipairs({'DISABLE_PHYSICS','DISABLE_RENDERING','DISABLE_SOUND'}) do write('flag.' .. flag, sr.Application[flag]) end
    if sr.IdString64 and type(sr.IdString64.from_hex) == 'function' and type(sr.Application.can_get) == 'function' then
        call('photo_light_asset', sr.Application.can_get, 'unit', sr.IdString64.from_hex('e07f49224f0a5759'))
        call('camera_asset', sr.Application.can_get, 'unit', sr.IdString64.from_hex('465f4895f3dc98d1'))
    end
    write('DISCOVERY_COMPLETE', true)
end
return {
    live_lua_api = 1,
    on_enable = function()
        local loader = assert(rawget(_G, 'LiveLuaLoader'), 'LLL unavailable')
        file = assert(loader.compatibility.open_log('HD2SE_BindingsProbe.log'))
        elapsed, finished = 0, false
        write('READY', token)
        write('lua', _VERSION)
        write('jit', jit and jit.version or 'none')
    end,
    on_update = function(dt)
        if finished then return end
        elapsed = elapsed + (tonumber(dt) or 0)
        if elapsed >= 0.25 then
            finished = true
            local ok, why = pcall(inspect)
            write('inspection.ok', ok)
            if not ok then write('inspection.error', why) end
        end
    end,
    on_disable = function()
        finished = true
        write('CLEANUP', true)
        if file then file:close(); file = nil end
        return true
    end,
}
