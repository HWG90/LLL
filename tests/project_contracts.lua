local files={
 ['mods/alpha/manifest.json']='{"name":"Alpha","author":"Goose","lll":{"entry":"main.lua","modules":["src/helper.lua","src/cycle.lua"]}}',
 ['mods/alpha/main.lua']='local a=mod.require("src.helper");assert(a==mod.require("src/helper.lua"));return {live_lua_api=1,on_enable=function()rawset(_G,"PROJECT_VALUE",a.value) end,on_disable=function()rawset(_G,"PROJECT_STOPS",(PROJECT_STOPS or 0)+1);return true end}',
 ['mods/alpha/src/helper.lua']='mod.scope.private_value="alpha";return {value=1}',
 ['mods/alpha/src/cycle.lua']='return mod.require("src.cycle")',
 ['mods/alpha/config/defaults.cfg']='{"enabled":true,"nested":{"a":1,"b":2}}',
 ['settings/alpha/config.cfg']='{"nested":{"a":7}}',
 ['mods/alpha.lua']='error("Folder project must win over the legacy file")',
 ['mods/beta/manifest.json']='{"name":"Beta","lll":{"entry":"main.lua","modules":["src/helper.lua"]}}',
 ['mods/beta/main.lua']='local h=mod.require("src.helper");return {live_lua_api=1,on_enable=function()end,on_disable=function()return true end}',
 ['mods/beta/src/helper.lua']='mod.scope.private_value="beta";return {value=99}',
 ['mods/beta/config/defaults.cfg']='{}',
 ['loader.cfg']='return {}',
}
local failed=false;local dirs={}
local platform={roots={{kind='lll',path='mods'}},settings='settings',loader_config='loader.cfg',directories=function()return {'alpha','beta'}end,
 files=function(path)if path=='mods'then return {'alpha.lua'},nil,{'alpha','beta'}end;return {},nil,{}end,
 read=function(path)return files[path]end,stat=function(path)return files[path]end,
 write=function(path,value)if failed then return false end;files[path]=value;return true end,mkdir=function(path)dirs[path]=true;return true end}
local project=dofile('src/project.lua')
local live=dofile('src/live.lua')(platform,function()end)
local names=live.scan();assert(#names==2 and live.catalog['live/alpha'].path=='mods/alpha/main.lua')
local spec=project.descriptor(platform,'mods/alpha')
local snapshot=project.snapshot(platform,live.catalog['live/alpha'],spec)
local definition,context=project.instantiate(platform,live.catalog['live/alpha'],snapshot,function()end)
assert(context.config.nested.a==7 and context.config.nested.b==2,'saved overrides must preserve new nested defaults')
assert(context.scope.private_value=='alpha' and _G.private_value==nil and _G.mod==nil)
definition.on_enable();assert(PROJECT_VALUE==1)
local _,beta=project.instantiate(platform,live.catalog['live/beta'],project.snapshot(platform,live.catalog['live/beta'],project.descriptor(platform,'mods/beta')),function()end)
assert(beta.scope.private_value=='beta' and context.scope.private_value=='alpha','same module IDs stay private to each mod')
assert(not pcall(context.require,'../beta/main.lua') and not pcall(context.read,'C:/file'))
assert(not pcall(context.require,'src.cycle'),'circular imports must fail clearly')
failed=true;assert(not context.set('enabled',false) and context.config.enabled==true)
failed=false;assert(context.set('label','Quote " slash \\ newline\n'))
local decoded=dofile('src/metadata.lua').decode(files['settings/alpha/config.cfg']);assert(decoded.label=='Quote " slash \\ newline\n')
local cycle={};cycle.self=cycle;assert(not context.set('bad',cycle),'invalid cyclic config must return a failure')
-- A helper syntax error must be refused before the currently active mod cleans up.
local old_loader,old_compat=LiveLuaLoader,CowboyBingusModLoader
local manager=dofile('src/manager.lua')({available=function()return true end,require=live.load,preflight=live.preflight,can_retry=function()return true end,evict=function()end,report=function()end},names)
assert(manager.modules['live/alpha']=='loaded')
local before=PROJECT_STOPS or 0;local fingerprint=live.fingerprint('live/alpha')
files['mods/alpha/src/helper.lua']='return {'
assert(live.fingerprint('live/alpha')~=fingerprint)
assert(not manager.reload('live/alpha') and manager.modules['live/alpha']=='loaded' and (PROJECT_STOPS or 0)==before)
files['mods/alpha/src/helper.lua']='return {value=2}'
assert(manager.reload('live/alpha') and PROJECT_VALUE==2 and PROJECT_STOPS==before+1)
files['mods/alpha/config/defaults.cfg']='not JSON'
assert(not manager.reload('live/alpha') and PROJECT_VALUE==2 and PROJECT_STOPS==before+1)
files['mods/alpha/config/defaults.cfg']='{"new_default":42}'
assert(manager.reload('live/alpha'))
-- Freeze the compiled project snapshot between preflight and activation.
live.preflight('live/alpha');files['mods/alpha/src/helper.lua']='return {value=3}'
local frozen=live.load('live/alpha');frozen.on_enable();assert(PROJECT_VALUE==2,'activation must use the preflighted source snapshot')
manager.shutdown();LiveLuaLoader,CowboyBingusModLoader=old_loader,old_compat
PROJECT_VALUE,PROJECT_STOPS=nil,nil
-- Missing literal imports are checked before cleanup; comments are ignored.
files['mods/alpha/main.lua']='-- mod.require("src/not-real")\nreturn {live_lua_api=1,on_disable=function()return true end}'
assert(live.preflight('live/alpha'))
files['mods/alpha/main.lua']='return mod.require("src/missing")'
assert(not pcall(live.preflight,'live/alpha'))
-- Console command ownership stays paused until deferred cleanup acknowledges.
platform.command_bus=dofile('src/commands.lua').new()
files['mods/alpha/main.lua']='return {live_lua_api=1,on_enable=function()mod.expose("owned",{value={get=function()return 1 end}})end,on_disable=function()return false,"pending" end,on_cleanup_poll=function()return true end}'
local owned_live=dofile('src/live.lua')(platform,function()end);local owned_names=owned_live.scan()
local owned_manager=dofile('src/manager.lua')({available=function()return true end,require=owned_live.load,preflight=owned_live.preflight,can_retry=function()return true end,evict=function()end,report=function()end},owned_names)
assert(platform.command_bus.execute('owned.value'))
assert(not owned_manager.set_enabled('live/alpha',false))
assert(not platform.command_bus.execute('owned.value'),'retiring owner must not accept commands')
owned_manager.frame(.016)
assert(#platform.command_bus.list()==0,'acknowledged cleanup must remove the provider')
owned_manager.shutdown();LiveLuaLoader,CowboyBingusModLoader=old_loader,old_compat
local changed=true
platform.changed=function()local value=changed;changed=false;return value end
local cached_live=dofile('src/live.lua')(platform,function()end)
cached_live.catalog['live/alpha']=live.catalog['live/alpha']
local first=cached_live.fingerprint('live/alpha')
local read_before=platform.read;local reads=0
platform.read=function(...)reads=reads+1;return read_before(...)end
assert(cached_live.fingerprint('live/alpha')==first and reads==0,'Idle project fingerprint must not read manifest or sources')
files['mods/alpha/src/helper.lua']='return {value=4}';changed=true
assert(cached_live.fingerprint('live/alpha')~=first and reads>0,'Watcher must detect helper edits')
reads=0;cached_live.fingerprint('live/alpha',true);assert(reads>0,'Edit confirmation must bypass cache')
platform.read=read_before;platform.changed=nil
print('PASS native folder discovery/priority, private imports/caches, config, safe reload, frozen snapshot and change-driven fingerprints')
