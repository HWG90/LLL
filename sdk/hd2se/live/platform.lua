-- OS thread/build metadata only. Never reads or writes native game objects.
local P = {}
function P.new(expected)
    local ffi = require('ffi')
    ffi.cdef[[
        uint32_t HD2SE_Live_GetCurrentThreadId_v1(void) __asm__("GetCurrentThreadId");
        void *HD2SE_Live_GetModuleHandleA_v1(const char *) __asm__("GetModuleHandleA");
        uint64_t HD2SE_Live_GetTickCount64_v1(void) __asm__("GetTickCount64");
    ]]
    local windows = ffi.load('kernel32')
    local function timestamp(name)
        local module = windows.HD2SE_Live_GetModuleHandleA_v1(name)
        if module == nil then return nil, 'module_unavailable' end
        local bytes = ffi.cast('const uint8_t *', module)
        if bytes[0] ~= 77 or bytes[1] ~= 90 then return nil, 'invalid_module_header' end
        local offset = tonumber(ffi.cast('const uint32_t *', bytes + 60)[0])
        if offset < 64 or offset > 4096 or tonumber(ffi.cast('const uint32_t *', bytes + offset)[0]) ~= 0x4550 then
            return nil, 'invalid_module_header'
        end
        return tonumber(ffi.cast('const uint32_t *', bytes + offset + 8)[0])
    end
    local platform = {}
    function platform.current_thread() return tonumber(windows.HD2SE_Live_GetCurrentThreadId_v1()) end
    function platform.clock() return tonumber(windows.HD2SE_Live_GetTickCount64_v1()) / 1000 end
    function platform.validate()
        local exe, why = timestamp(nil)
        if not exe then return false, why end
        local game, problem = timestamp('game.dll')
        if not game then return false, problem end
        if exe ~= expected.exe_timestamp or game ~= expected.game_timestamp then return false, 'unsupported_loaded_build' end
        if _VERSION ~= 'Lua 5.1' or not jit or jit.version ~= 'LuaJIT 2.1.0-alpha' then return false, 'unsupported_lua_runtime' end
        return true
    end
    return platform
end
return P
