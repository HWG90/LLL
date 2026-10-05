local loader=assert(LiveLuaLoader)
assert(loader.capabilities and loader.capabilities.api==1)
loader.after_startup(function()
 local file=loader.compatibility.open_log('LLL_AfterStartupExample.log')
 if file then file:write('Initial module startup completed\n');file:close()end
end)
