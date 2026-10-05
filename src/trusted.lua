-- Snapshot only loader dependencies; mod code still executes in its normal environment.
local M = {}
function M.capture(environment)
    local snapshot = {}
    local next, type = next, type
    local function copy(value)
        local result = {}
        if type(value) == "table" then for key, item in next, value do result[key] = item end end
        return result
    end
    for _, name in ipairs({"assert","error","pcall","xpcall","type","tostring","tonumber","rawget","rawset","rawequal","pairs","ipairs","next","select","unpack","loadstring","loadfile","dofile","setfenv","getfenv","setmetatable","getmetatable","collectgarbage","print"}) do
        snapshot[name] = environment[name]
    end
    for _, name in ipairs({"string","table","math","io","os","debug","coroutine","package"}) do snapshot[name] = copy(environment[name]) end
    local original_require = environment.require
    local ffi = copy(original_require("ffi"))
    local bit = copy(original_require("bit"))
    snapshot.jit = copy(environment.jit)
    snapshot.jit.opt = copy(snapshot.jit.opt)
    snapshot.require = function(name)
        if name == "ffi" then return ffi end
        if name == "bit" then return bit end
        if name == "jit" then return snapshot.jit end
        return original_require(name)
    end
    return snapshot
end
return M
