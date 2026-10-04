local time=0
return {
 live_lua_api=1,
 on_enable=function() print('[LiveLuaLoader demo] enabled') end,
 on_update=function(dt) time=time+dt end,
 on_disable=function() print('[LiveLuaLoader demo] disabled after '..time..' seconds') end
}
