local M=dofile('src/jit_budget.lua')
local clock=0
local cache=M.start(jit,nil,function()end,{clock=function()return clock end})
assert(cache.accepted and cache.watching() and cache.capacity_kb==65536)
jit.flush();assert(cache.capacity_kb==131072 and cache.growths==1)
jit.flush();assert(cache.capacity_kb==131072)
clock=31;jit.flush();assert(cache.capacity_kb==262144 and cache.growths==2)
local calls=0;local next_handler=function(what)if what=='flush'then calls=calls+1 end end
jit.attach(next_handler,'trace');assert(cache.close());jit.flush();assert(calls==1)
local occupied=M.start(jit,nil,function()end);assert(occupied.accepted and not occupied.watcher)
occupied.close();jit.flush();assert(calls==2)
jit.attach(next_handler)
print('PASS installed game LuaJIT 2.1.0-alpha: real observed-flush growth, debounce, native opt acceptance and retained observer cleanup (test process only)')
