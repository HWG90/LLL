-- LLL-native maintenance project; all dependencies are bundled beside this file.
local Cache=mod.require('src/poll_cache')
local handle
local definition={live_lua_api=1}
definition.on_enable=function()
 -- LLL finishes installing its own callbacks after loading initial projects.
 definition.on_update=function()
  local manager=assert(rawget(_G,'LiveLuaLoader'),'LLL manager unavailable')
  handle=Cache.install(manager)
  definition.on_update=nil
  print('[LLL Poll Cache] Change-driven script checks active; hot reload retained')
 end
end
definition.on_disable=function()
 if handle then handle.release();handle=nil end
 return true
end
return definition
