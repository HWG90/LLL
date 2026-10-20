local guard=dofile('src/vendor/bsl_jit_guard.lua')
local budget=dofile('src/jit_budget.lua')
local integration=dofile('src/jit_churn.lua')
local function abort(g,f,pc,code)
    g.event('start',1,f,pc);g.event('abort',1,f,pc,code or 7)
end
local writes=0
local g=guard.new({handle=true,identity=function()return 1000 end,
    locate=function()return {find=function()return 0 end,value=function()return 72 end,
        bump=function()writes=writes+1 end,retry_now=function()return true end}end,
    info=function()return '@test',10 end})
local f=function()end
for _=1,guard.CHURN_ABORTS do abort(g,f,2)end
assert(writes==0)
abort(g,f,2);assert(writes==1 and g.public.handled==1)
for _=1,40 do abort(g,f,2,guard.RETRY)end
assert(writes==1,'Immediate retry events are not penalized')
local unknown=integration.start(guard,jit,{},{supported=true,jit_supported=false},function()end)
for _=1,20 do abort(unknown,f,2)end
assert(unknown.public.handled==0 and not unknown.public.located)
local bounded=guard.new({handle=false,max_records=2})
for i=1,100 do abort(bounded,f,i)end
assert(bounded.public.limited and bounded.public.aborts==2,'Allocation budget must bound new starts')

-- One shared observer: closed/replaced callback remains owned by its new provider.
local events={};local key=budget.TRACE_KEY
local library={version='LuaJIT 2.1.0-alpha',opt={start=function()end},off=function()end}
library.attach=function(fn,kind)if kind then events[key]=fn elseif events[key]==fn then events[key]=nil end end
local seen=0
local c=budget.start(library,nil,function()end,{registry=function()return {_VMEVENTS=events}end,
    guard=function()return {public={},event=function()seen=seen+1 end}end})
events[key]('start');events[key]('abort');assert(seen==2)
c.pause();events[key]('flush');c.resume();assert(c.growths==0)
local old=events[key];assert(c.close());old('abort');assert(seen==2)
local peer=function()end;events[key]=peer
local constructed=false
c=budget.start(library,nil,nil,{registry=function()return {_VMEVENTS=events}end,
    guard=function()constructed=true end})
assert(not c.watching() and not constructed and events[key]==peer)

-- Real game LuaJIT DLL in this test process: 100 independent NYI trace starts.
local service
local current=budget.start(jit,nil,function()end,{guard=function(cache)
    service=integration.start(guard,jit,cache,{supported=true,jit_supported=true},function()end)
    return service
end})
assert(current.watching() and service)
local funcs={}
for i=1,100 do
    funcs[i]=assert(loadstring('local t={a=1,b=2};return function()local n=0;for i=1,100 do for k,v in pairs(t)do n=n+v end end;return n end','@churn_contract_'..i))()
end
local function frames(count)
    for _=1,count do for i=1,#funcs do assert(funcs[i]()==300)end end
end
jit.off(frames)
frames(4000)
assert(current.churn.starts>0 and current.churn.handled>0 and current.churn.located,current.churn.mode)
local before=current.churn.aborts
frames(1000)
local after=current.churn.aborts
assert(after-before<=50,'Handled trace starts must stop repeated compilation churn: '..(after-before))
assert(current.close() and not current.watching())
print('PASS bounded churn threshold, retry exclusion, unknown fingerprint, single observer ownership/close, real DLL blacklisting; starts='..current.churn.starts..', handled='..current.churn.handled..', later aborts='..(after-before)..' (isolated process)')
