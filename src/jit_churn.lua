-- One event consumer, owned by jit_budget; no frame callback or polling.
local M = {}
function M.start(guard, library, cache, build, report, options)
    options=options or {}
    local native, notes
    local allowed=build and build.supported==true and build.jit_supported==true
    if allowed then
        local ok,value=pcall(function()return guard.native(require('ffi'))end)
        if ok then native=value else notes=tostring(value) end
    else notes='native access refused: LuaJIT/game fingerprint not supported' end
    local info
    local ok,util=pcall(require,'jit.util')
    if ok and type(util)=='table' and type(util.funcinfo)=='function' then
        local funcinfo=util.funcinfo
        info=function(func,pc)local row=funcinfo(func,pc);return row.source,row.currentline end
    elseif debug and type(debug.getinfo)=='function' then
        local getinfo=debug.getinfo
        info=function(func)local row=getinfo(func,'S');return row.source,row.linedefined end
    end
    local service
    local function log()
        if not service then return end
        local lines={};service.add_lines(lines)
        for _,line in ipairs(lines) do report('LLL JIT',line) end
    end
    service=guard.new({identity=native and native.identity,
        locate=native and function()return native.locate(cache)end,
        handle=allowed and options.handle~=false, info=info, log=log,
        clock=options.clock or os.time, notes=notes})
    service.describe=log
    return service
end
return M
