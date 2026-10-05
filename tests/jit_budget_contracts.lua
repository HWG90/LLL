local M=dofile('src/jit_budget.lua')
local events={};local now=0;local writes={};local reenter=false
local library={version='LuaJIT 2.1.0-alpha',opt={}}
library.attach=function(fn,event)
 if event then events[M.TRACE_KEY]=fn
 else for key,value in pairs(events)do if value==fn then events[key]=nil end end end
end
library.opt.start=function(setting)writes[#writes+1]=setting;if reenter and events[M.TRACE_KEY]then events[M.TRACE_KEY]('flush')end end
local b=M.start(library,nil,function()end,{registry=function()return{_VMEVENTS=events}end,clock=function()return now end})
assert(writes[1]=='maxmcode=65536' and b.watching())
reenter=true;events[M.TRACE_KEY]('flush');assert(b.capacity_kb==131072 and b.growths==1)
events[M.TRACE_KEY]('flush');assert(b.capacity_kb==131072 and b.skipped==1)
now=31;events[M.TRACE_KEY]('flush');assert(b.capacity_kb==262144 and b.growths==2)
now=100;events[M.TRACE_KEY]('flush');assert(#writes==3)
local replacement=function()end;events[M.TRACE_KEY]=replacement
assert(b.close() and events[M.TRACE_KEY]==replacement)
local n=#writes;local occupied=M.start(library,nil,nil,{registry=function()return{_VMEVENTS=events}end})
assert(not occupied.watcher and events[M.TRACE_KEY]==replacement and #writes==n+1)
events={};library.opt.start=function()error('rejected')end
local fail=M.start(library);assert(not fail.accepted and not fail.watcher)
print('PASS 64MiB total cache, observed-flush doubling/debounce/cap, reentry guard, retained observer/replacement and API failure')
