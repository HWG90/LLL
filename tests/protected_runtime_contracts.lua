local saved_type,saved_next,saved_pairs,saved_assert,saved_error,saved_require,saved_dofile=type,next,pairs,assert,error,require,dofile
local saved_global={};for _,key in ipairs({'pcall','xpcall','type','tostring','tonumber','rawget','rawset','rawequal','pairs','ipairs','next','select','unpack','loadstring','loadfile','dofile','setmetatable','getmetatable','collectgarbage','print','require'})do saved_global[key]=_G[key]end
local trusted=saved_dofile('src/trusted.lua').capture(_G)
local env=setmetatable({_G=_G},{__index=function(_,key)if trusted[key]~=nil then return trusted[key]end;return _G[key]end})
local function protected(path)
 local file=trusted.io.open(path,'rb');local text=file:read('*a');file:close()
 local fn=saved_assert(trusted.loadstring(text,'@'..path));trusted.setfenv(fn,env);return fn()
end
local platform_text
local f=trusted.io.open('tests/tmp/speed-native.lua','rb');platform_text=f:read('*a');f:close()
local chunk=saved_assert(trusted.loadstring(platform_text));trusted.setfenv(chunk,env);local P=chunk()
local discover=protected('src/discovery.lua');env.LLL_CLEANUP_QUEUE=protected('src/cleanup_queue.lua');env.LLL_AFTER_STARTUP=protected('src/after_startup.lua');env.LLL_CAPABILITIES=protected('src/capabilities.lua')
local factory=protected('src/manager.lua');local old_loader,old_compat=LiveLuaLoader,CowboyBingusModLoader
_G.LiveLuaLoader=nil;_G.CowboyBingusModLoader=nil
local ffi=saved_require('ffi');ffi.cdef[[int GetFileAttributesExA(int,int,int);int CreateFileA(int);int ReadFile(int,int,int);]]
local broken=function()local info=trusted.debug.getinfo(2,'Sl');saved_error('replaced global used by '..trusted.tostring(info and info.short_src)..':'..trusted.tostring(info and info.currentline))end
for key in saved_next,saved_global do _G[key]=broken end

string.match=broken;string.sub=broken;string.gsub=broken;string.gmatch=broken;string.byte=broken;table.sort=broken;table.concat=broken;io.open=broken;os.getenv=broken
ffi.new=broken;ffi.cast=broken;ffi.string=broken
local names,warnings=discover(P,true);saved_assert(#names==1 and names[1]=='mods/test/accepted')
local log=saved_assert(P.open_log('private_builtin_test.log'));saved_assert(log:write('protected logging\n'));log:close()
local n=0
local loader=factory({available=function()return true end,can_retry=function()return true end,preflight=function()end,
 require=function()return{live_lua_api=1,on_enable=function()n=n+1 end,on_disable=function()return true end}end,
 report=function(name,state)local file=saved_assert(P.open_log('private_lifecycle_test.log'));file:write(name,': ',state);file:close()end,
 save_enabled=function()return true end,evict=function()end}, {})
saved_assert(loader.add('live/trusted') and n==1)
saved_assert(loader.reload('live/trusted') and n==2)
saved_assert(loader.set_enabled('live/trusted',false) and not loader.records['live/trusted'])
loader.shutdown()
for key,value in saved_next,saved_global do _G[key]=value end
for _,name in ipairs({'string','table','io','os'})do for key,value in saved_next,trusted[name]do _G[name][key]=value end end
local private_ffi=trusted.require('ffi');ffi.new=private_ffi.new;ffi.cast=private_ffi.cast;ffi.string=private_ffi.string
_G.LiveLuaLoader=old_loader;_G.CowboyBingusModLoader=old_compat
print('PASS replaced Lua globals/library members/FFI functions and conflicting Windows exports preserve real discovery/logging/lifecycle')

