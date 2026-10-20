-- Opt-in isolated-DLL comparison; never a gameplay/FPS claim.
local guard=dofile('src/vendor/bsl_jit_guard.lua')
local budget=dofile('src/jit_budget.lua')
local integration=dofile('src/jit_churn.lua')
local function trial(enabled)
    jit.flush()
    local service
    local cache=budget.start(jit,nil,function()end,{guard=function(state)
        service=integration.start(guard,jit,state,{supported=true,jit_supported=true},function()end,{handle=enabled})
        return service
    end})
    assert(cache.watching())
    local funcs={}
    for i=1,100 do funcs[i]=assert(loadstring('local t={a=1,b=2};return function()local n=0;for i=1,100 do for k,v in pairs(t)do n=n+v end end;return n end','@benchmark_'..tostring(enabled)..'_'..i))()end
    local function frames(n)for _=1,n do for i=1,#funcs do funcs[i]()end end end
    jit.off(frames)
    local t=os.clock();frames(200);local transition=os.clock()-t
    frames(3800)
    local before=cache.churn.aborts
    t=os.clock();frames(1000);local steady=os.clock()-t
    local tail=cache.churn.aborts-before
    assert(cache.close())
    print(string.format('BENCH handle=%s first_200_ms=%.3f steady_1000_ms=%.3f steady_aborts=%d handled=%d',tostring(enabled),transition*1000,steady*1000,tail,cache.churn.handled))
    if enabled then assert(tail<=50 and cache.churn.handled>=100)else assert(tail>=10000 and cache.churn.handled==0)end
end
trial(false);trial(true);trial(true);trial(false)
