-- Port test (not upstream): the native Wwise SetState path of the build-26088801 port, offline, with a stubbed plugin
-- module, export lookup and memory read. The "export" is an FFI callback, so a call that passes the checks really
-- goes through the same function-pointer call the mod makes in the game. Cases: match -> one call; prologue
-- mismatch, unreadable code, wrong RVA, unresolved export -> no call; a failing AKRESULT is reported; no plugin ->
-- no path (install keeps upstream's 'unavailable' refusal); and Mod.new counts a mission only when the state was set.
-- Usage: luajit test_native_set_state.lua <project root (the port copy)>
local root = assert(arg[1], 'project root required')
local ffi = require('ffi')
local Mod = dofile(root .. '/src/sound_systems_rebalanced.lua')
local W = Mod.WWISE
local passed = 0
local function test(name, fn) fn(); passed = passed + 1 end

local calls, result = {}, 1
local callback = ffi.cast('int32_t (*)(const char *, const char *)', function(group, value)
    calls[#calls + 1] = ffi.string(group) .. '=' .. ffi.string(value)
    return result
end)
local export = tonumber(ffi.cast('uintptr_t', callback))
local function world(options)
    options = options or {}
    local module = nil
    if not options.no_module then module = export - W.rva + (options.shift or 0) end
    local api = {}
    function api.module(name) assert(name == W.module, name) return module end
    function api.distance(a, b) return tonumber(ffi.cast('uintptr_t', a)) - b end
    function api.read(address, size)
        assert(tonumber(ffi.cast('uintptr_t', address)) == export and size == #W.prologue, 'read elsewhere')
        if options.unreadable then return nil end
        return options.bytes or W.prologue
    end
    local function get_proc(m, name)
        assert(m == module and name == W.export, 'looked up something else')
        if options.no_export then return nil end
        return ffi.cast('void *', callback)
    end
    local lines = {}
    local set = Mod.native_set_state(api, function(line) lines[#lines + 1] = line end, get_proc)
    return set, lines
end

test('prologue is the 31 bytes recorded in MAP.json', function()
    assert(#W.prologue == 31 and W.rva == 0xDA120 and W.success == 1)
end)
test('match: one call with the names, true', function()
    calls, result = {}, 1
    local set, lines = world()
    assert(set(Mod.GROUP, Mod.ROOM) == true and #calls == 1 and calls[1] == 'environment_shiphub_room=shiphub_view')
    assert(#lines == 0, table.concat(lines))
end)
for _, case in ipairs({{'prologue mismatch', {bytes = W.prologue:sub(1, 30) .. '\0'}, 'differs from the expected prologue'},
                       {'unreadable code page', {unreadable = true}, 'is unreadable'},
                       {'export at another RVA', {shift = 16}, 'not at its expected RVA'},
                       {'export does not resolve', {no_export = true}, 'did not resolve'}}) do
    test(case[1] .. ': no call, logged, false', function()
        calls = {}
        local set, lines = world(case[2])
        assert(set(Mod.GROUP, Mod.ROOM) == false, case[1])
        assert(#calls == 0, case[1] .. ': called unchecked')
        assert(#lines == 1 and lines[1]:find(case[3], 1, true) and lines[1]:find('nothing was called', 1, true), lines[1])
    end)
end
test('a failing AKRESULT is reported', function()
    calls, result = {}, 2
    local set, lines = world()
    assert(set(Mod.GROUP, Mod.ROOM) == false and #calls == 1 and lines[1]:find('returned 2', 1, true))
    result = 1
end)
test('no plugin loaded: no native path', function()
    assert(world({no_module = true}) == nil)
end)
test('Mod.new counts a mission only when the state was set', function()
    local LAYOUT = {game_rva = 0x100, state_offset = 0x40}
    local module, object = ffi.new('uint8_t[?]', 0x200), ffi.new('uint8_t[?]', 0x80)
    ffi.cast('uint64_t *', module + LAYOUT.game_rva)[0] = ffi.cast('uint64_t', ffi.cast('uintptr_t', object))
    ffi.cast('uint32_t *', object + LAYOUT.state_offset)[0] = 6
    local api = {read_into = function(address, size, buffer) ffi.copy(buffer, ffi.cast('void *', address), size) return true end}
    for _, answer in ipairs({false, true}) do
        local state, lines = {missions = 0}, {}
        local n = 0
        local instance = Mod.new(api, module, function() n = n + 1 return answer end,
            function(line) lines[#lines + 1] = line end, state, LAYOUT)
        instance.step(0.25)
        assert(n == 1, 'set_state not tried once')
        assert(state.missions == (answer and 1 or 0), 'missions ' .. state.missions .. ' for ' .. tostring(answer))
        assert(#lines == (answer and 1 or 0), table.concat(lines, '|'))
    end
end)
print(string.format('PASS: %d native SetState port tests (%s)', passed, jit and jit.version or _VERSION))
