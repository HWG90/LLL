local H=dofile('src/vendor/bsl_health.lua')
local heap,clock=100,0
local globals={string={format=string.format}}
local observer=H.observer(globals,{collect=function(option,value)if option=='count'then return heap end;return 200 end,clock=function()return clock end})
globals.background=true
local mark=observer.mark();clock=.02;heap=120;globals.from_mod=true;globals.string.format=function()end
local result=observer.changes(mark)
assert(result.heap_kb==20 and result.ms==20 and result.added.total==1 and result.replaced.total==1)
assert(H.describe(result):find('heap +20 KB',1,true))
local previous=H.previous_session('Live Lua Loader R24\nStarted: yesterday\nAfter startup: running mod\nAfter startup: completed mod\nStartup finished\n')
assert(not previous:find('callbacks ran',1,true))
assert(H.previous_session('Live Lua Loader R24\nStarted: yesterday\nStartup finished\nAfter startup: running mod\n'):find('callbacks ran',1,true))
assert(not pcall(H.read_dump,{seek=function()end,read=function()return 'bad'end}))
print('PASS health heap/time/global/library attribution, live-reload before baseline, previous-session callback state and malformed dump refusal')
