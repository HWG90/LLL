-- Total compiled-code capacity, not Lua heap or individual machine-code area size.
local M = {DEFAULT_KB=65536, CEILING_KB=262144, TRACE_KEY=-1765235912}
function M.start(library, settings, report, hooks)
    hooks=hooks or {};settings=settings or {}
    local clock=hooks.clock or os.time
    local registry=hooks.registry or (debug and debug.getregistry)
    local state={requested_kb=M.DEFAULT_KB,accepted=false,growths=0,flushes=0,skipped=0,watcher=false,closed=false}
    local function limit(value,fallback)
        return type(value)=='number' and value==math.floor(value) and value>=M.DEFAULT_KB and value<=M.CEILING_KB and value or fallback
    end
    state.requested_kb=limit(settings.start_kb,M.DEFAULT_KB)
    state.ceiling_kb=math.max(state.requested_kb,limit(settings.ceiling_kb,M.CEILING_KB))
    state.cooldown_seconds=type(settings.cooldown_seconds)=='number' and math.max(1,math.min(300,settings.cooldown_seconds)) or 30
    local opt=type(library)=='table' and type(library.opt)=='table' and library.opt.start
    local attach=type(library)=='table' and library.attach
    local applying=false;local last_growth;local handler
    local suspended=0
    function state.pause()suspended=suspended+1 end
    function state.resume()suspended=math.max(0,suspended-1)end
    local heap=hooks.heap or function()return collectgarbage("count")end
    state.traces=8000
    local function emit(message) if report then pcall(report,'LLL JIT',message) end end
    local function apply(kb,cause)
        applying=true
        local ok,why=pcall(opt,'maxmcode='..kb,'maxtrace='..state.traces)
        applying=false;state.requested_kb=kb
        if ok then state.capacity_kb=kb;state.mcode_kb=kb;state.accepted=true;state.managed=true;state.expanded=true
        else state.error=tostring(why) end
        emit('Total machine-code limit requested '..kb..' KiB; API accepted='..tostring(ok)..'; cause='..cause..(ok and '' or '; '..state.error))
        return ok
    end
    local function events()
        if type(registry)~='function' then return nil end
        local ok,value=pcall(registry)
        return ok and type(value)=='table' and type(rawget(value,'_VMEVENTS'))=='table' and rawget(value,'_VMEVENTS') or nil
    end
    function state.watching()
        local values=events()
        return state.watcher and not state.closed and values and rawget(values,M.TRACE_KEY)==handler or false
    end
    function state.close()
        if state.closed then return true end
        if state.watching() then
            local ok,why=pcall(attach,handler)
            if not ok then return false,tostring(why) end
        end
        state.closed=true;state.watcher=false;return true
    end
    if type(opt)~='function' then state.error='jit.opt.start unavailable';emit(state.error);return state end
    if not apply(state.requested_kb,'startup') then return state end
    -- Actual installed LuaJIT 2.1.0-alpha was tested: trace event slot and payload.
    -- A flush supplies no reason. Never claim exhaustion; policy uses observed flushes.
    if library.version~='LuaJIT 2.1.0-alpha' or type(attach)~='function' or type(registry)~='function' then
        state.reason='Adaptive observer unavailable for this API/version';emit(state.reason);return state
    end
    local values=events()
    if values and rawget(values,M.TRACE_KEY)~=nil then
        state.reason='Existing trace observer retained; adaptive growth unavailable while it owns the slot';emit(state.reason);return state
    end
    handler=function(what)
        if what~='flush' or state.closed or applying then return end
        state.flushes=state.flushes+1
        if suspended>0 then state.skipped=state.skipped+1;return end
        local now=clock()
        if state.capacity_kb>=state.ceiling_kb or (last_growth and now-last_growth<state.cooldown_seconds) then
            state.skipped=state.skipped+1;return
        end
        last_growth=now
        local target=math.min(state.capacity_kb*2,state.ceiling_kb)
        local old_traces=state.traces
        local ok,usage=pcall(heap)
        if ok and type(usage)=="number" and usage<24*1024 then state.traces=math.min(state.traces*2,16000) end
        if apply(target,'observed flush; cause not exposed') then state.growths=state.growths+1 else state.traces=old_traces end
    end
    if type(library.off)=='function' then pcall(library.off,handler,true) end
    local ok,why=pcall(attach,handler,'trace')
    state.watcher=ok
    if not ok then state.reason=tostring(why)
    elseif not state.watching() then
        pcall(attach,handler);state.watcher=false;state.reason='Trace slot validation failed'
    end
    emit(state.watcher and ('Observed-flush growth enabled; ceiling '..state.ceiling_kb..' KiB; debounce '..state.cooldown_seconds..' s; no forced flush') or state.reason)
    return state
end
return M
