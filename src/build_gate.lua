-- Startup-only SHA256 gate. Shared Runtime caches successful reads by UTF-16 path.
-- Native adapters must retain their own exact expected build pair.
local M = {}
function M.check(runtime, memory, builds, lua_sha)
    local result = {supported=false, reason='build check unavailable', exe_sha256='unavailable',
        game_sha256='unavailable', lua_sha256='unavailable', jit_supported=false}
    local ok, api = pcall(memory.new, runtime)
    if not ok then result.reason='build check failed: '..tostring(api);return result end
    local function hash(name)
        local module=api.module(name)
        assert(module~=nil, 'module unavailable: '..(name or 'executable'))
        local value=api.module_hash(module)
        assert(type(value)=='string' and #value==64 and value:match('^%x+$'), 'invalid module hash')
        return value:upper()
    end
    local checked, why=pcall(function()
        -- Read both for useful diagnostics even if the first fails.
        local exe_ok, exe=pcall(hash,nil)
        local game_ok, game=pcall(hash,'game.dll')
        if exe_ok then result.exe_sha256=exe end
        if game_ok then result.game_sha256=game end
        assert(exe_ok and game_ok, not exe_ok and exe or game)
        for _,build in ipairs(builds or {}) do
            if exe==build.exe_sha256 and game==build.game_sha256 then
                result.supported=true;result.reason=nil;break
            end
        end
        if not result.supported then result.reason='unsupported game build';return end
        -- Unknown LuaJIT leaves the game gate intact, but forbids native JIT access.
        local jit_ok, value=pcall(hash,'lua51.dll')
        if jit_ok then result.lua_sha256=value end
        result.jit_supported=jit_ok and value==lua_sha
    end)
    if not checked then result.supported=false;result.reason='build check failed: '..tostring(why) end
    return result
end
return M
