-- One-shot API inventory for the current Steam runtime. No native process hooks.
if rawget(_G, 'LLL_STEAM_PROBE_STARTED') then return end
rawset(_G, 'LLL_STEAM_PROBE_STARTED', true)
local lines = {'LLL Steam startup probe; Lua=' .. tostring(_VERSION)}
local function inventory(name, value)
    local names = {}
    if type(value) == 'table' then
        for key, member in pairs(value) do
            if type(key) == 'string' then names[#names + 1] = key .. ':' .. type(member) end
        end
        table.sort(names)
    end
    lines[#lines + 1] = name .. '=' .. type(value) .. ' ' .. table.concat(names, ', ')
end
inventory('_G', _G)
local sr = rawget(_G, 'stingray')
inventory('stingray', sr)
for _, name in ipairs({'Application','Window','Gui','Keyboard','Mouse','Input','FileSystem','Filesystem','PackageManager','Lua','System'}) do
    inventory('stingray.' .. name, type(sr) == 'table' and sr[name])
end
for _, name in ipairs({'io','os','package','debug','jit','bit'}) do inventory(name, rawget(_G, name)) end
local file
local opened, result = pcall(function()
    if type(io) == 'table' and type(io.open) == 'function' then
        return io.open(LLL_STEAM_PROBE_LOG, 'wb')
    end
end)
if opened then file = result end
local function report(message)
    pcall(print, '[LLL Steam probe] ' .. message)
    if file then
        local ok = pcall(function() file:write(message .. '\n'); file:flush() end)
        if not ok then pcall(function() file:close() end); file = nil end
    end
end
for _, line in ipairs(lines) do report(line) end
local gui, world
local marker_done = not (type(sr) == 'table' and sr.World and sr.Gui and sr.Application
    and type(sr.Application.main_world) == 'function' and type(sr.World.create_screen_gui) == 'function'
    and type(sr.Gui.text) == 'function' and sr.Vector3 and sr.Color)
local function marker()
    if marker_done then return end
    local current = sr.Application.main_world()
    if not current then return end
    marker_done = true
    local ok, why = pcall(function()
        world = current
        gui = sr.World.create_screen_gui(world, 'scale', 1, 1)
        sr.Gui.text(gui, 'LLL Steam Lua startup active | io=' .. type(io) .. ' package=' .. type(package),
            'core/performance_hud/debug', 22, 'core/performance_hud/debug',
            sr.Vector3(40, 180, 999), sr.Color(255, 40, 255, 120))
    end)
    report(ok and 'visible startup marker created' or 'visible marker unavailable: ' .. tostring(why))
end
local old_shutdown = rawget(_G, 'shutdown')
if type(old_shutdown) == 'function' then
    shutdown = function(...)
        if gui and world and type(sr.Application.worlds) == 'function' then
            for _, current in pairs(sr.Application.worlds() or {}) do
                if current == world then pcall(sr.World.destroy_gui, world, gui); break end
            end
            gui, world = nil, nil
        end
        if file then pcall(function() file:close() end); file = nil end
        return old_shutdown(...)
    end
end
local previous = rawget(_G, 'update')
if type(previous) == 'function' then
    local frames = 0
    local wrapper
    local function pack(...) return {n=select('#', ...), ...} end
    wrapper = function(...)
        if frames >= 3 and marker_done then return previous(...) end
        local result = pack(previous(...))
        frames = frames + 1
        if frames <= 3 then report('native update callback ' .. frames) end
        if not marker_done and (frames == 1 or frames % 60 == 0) then
            local ok, why = pcall(marker)
            if not ok then marker_done = true; report('marker failed: ' .. tostring(why)) end
        end
        if frames >= 3600 then marker_done = true end
        if frames >= 3 and marker_done then
            if update == wrapper then update = previous end
            report('probe detached; original update restored')
            if file then pcall(function() file:close() end); file = nil end
        end
        return unpack(result, 1, result.n)
    end
    update = wrapper
else
    report('no global update callback')
    if file then pcall(function() file:close() end); file = nil end
end
