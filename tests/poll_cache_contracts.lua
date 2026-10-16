local Cache=dofile('src/poll_cache.lua')
local Project=dofile('src/project.lua')
local function fixture(legacy)
 local files={['loader.cfg']='return {}',
 ['mods/demo/manifest.json']='{"name":"Demo","lll":{"entry":"main.lua","modules":["src/helper.lua"]}}',
 ['mods/demo/main.lua']='local h=mod.require("src/helper");return {live_lua_api=1,on_enable=function()rawset(_G,"CACHE_PROJECT_VALUE",h.value) end,on_disable=function()rawset(_G,"CACHE_PROJECT_STOPS",(CACHE_PROJECT_STOPS or 0)+1);return true end}',
 ['mods/demo/src/helper.lua']='return {value=1}',
 ['mods/demo/config/defaults.cfg']='{}',['mods/loose.lua']='return true'}
 local watch,counts,dirs={}, {read=0,stat=0,refresh=0},{'demo'}
 local platform={roots={{kind='lll',path='mods'}},live='mods',loader_config='loader.cfg',settings='settings',
 files=function(path)if path=='mods'then return{'loose.lua'},nil,dirs end;return{},nil,{}end,
 directories=function()return dirs end,
 changed=function(path)local v=watch[path];watch[path]=false;return v==true end,
 read=function(path)counts.read=counts.read+1;return files[path]end,
 stat=function(path)counts.stat=counts.stat+1;return files[path]end,
 write=function(path,text)files[path]=text;return true end,mkdir=function()return true end}
 local live=dofile('src/live.lua')(platform,function()end);live.scan()
 if legacy then live.fingerprint=function(name,force)local entry=assert(live.catalog[name]);if entry.project then return Project.fingerprint(platform,entry,assert(Project.descriptor(platform,entry.dir)))end;return live.source(name,force)end end
 local controls={selected='demo',expanded={},bindings={},
 provenance_snapshot=function()local entry=live.catalog['live/demo'];return{{name='demo',state='loaded',description=entry.metadata and entry.metadata.description}}end,
 refresh=function(...)counts.refresh=counts.refresh+1;return'updated',nil,select('#',...),nil end}
 local function refresh_catalog()assert(live);controls.refresh()end
 local manager={refresh=function()return refresh_catalog()end,frame=function()end,get_loader_option=live.get_loader_option}
 return files,watch,counts,platform,live,controls,manager,dirs
end
local function pack(...)return{n=select('#',...),...}end
for _,legacy in ipairs({true,false})do
 local files,watch,n,p,live,controls,manager=fixture(legacy)
 local old_fp,old_refresh=live.fingerprint,controls.refresh
 local handle=Cache.install(manager);local first=live.fingerprint('live/demo')
 local reads,stats=n.read,n.stat
 for i=1,40 do assert(live.fingerprint('live/demo')==first)end
 assert(n.read==reads and n.stat==stats,'Idle project must perform no reads/stats')
 files['mods/demo/src/helper.lua']='return {value=2}';watch['mods/demo']=true
 local second=live.fingerprint('live/demo');assert(second~=first,'Changed helper must recompute even with an underlying watcher cache')
 reads=n.read;assert(live.fingerprint('live/demo',true)==second and n.read>reads,'Second-poll confirmation must force original reads')
 -- Catalog notifications from output files must not cause a project scan.
 watch.mods=true;live.scan();reads,stats=n.read,n.stat;assert(live.fingerprint('live/demo')==second and n.read==reads and n.stat==stats)
 -- Loose-file edits retain stamp checks, including after unrelated catalog scans.
 local loose=live.fingerprint('live/loose');files['mods/loose.lua']='return false';assert(live.fingerprint('live/loose')~=loose)
 local entry=live.catalog['live/demo'];entry.project.restart_only=true;reads,stats=n.read,n.stat
 assert(live.fingerprint('live/demo')==nil and n.read==reads and n.stat==stats,'Restart-only projects must not be polled/reloaded')
 entry.project.restart_only=false;watch['mods/demo']=true;assert(live.fingerprint('live/demo')==second)
 local r=pack(controls.refresh(false,nil));assert(r.n==4 and r[1]=='updated'and r[3]==2)
 controls.refresh();assert(n.refresh==1,'Unchanged manager refresh must be skipped')
 controls.selected='other';controls.refresh();assert(n.refresh==2)
 controls.expanded.group=true;controls.refresh();assert(n.refresh==3)
 live.catalog['live/demo'].metadata={description='New description'};controls.refresh();assert(n.refresh==4,'Public metadata changes must remain visible')
 local api={mods={lll_management={values={a=true}}}};controls.bindings[1]={api=api,handle={}}
 controls.refresh();api.mods.lll_management.values.a=false;controls.refresh();assert(n.refresh==6,'Explicit controls updates must refresh')
 assert(handle.owned()and handle.release()and handle.release()and live.fingerprint==old_fp and controls.refresh==old_refresh)
end
-- Real module lifecycle: helper reloads are still safe and invalid edits preserve live code.
local files,watch,n,p,live,controls,public=fixture(true)
local handle=Cache.install(public)
local old_loader,old_compat=LiveLuaLoader,CowboyBingusModLoader
local manager=dofile('src/manager.lua')({available=function()return true end,require=live.load,preflight=live.preflight,can_retry=function()return true end,evict=function()end,report=function()end},{'live/demo'})
assert(CACHE_PROJECT_VALUE==1)
files['mods/demo/src/helper.lua']='return {value=3}';watch['mods/demo']=true
local changed=live.fingerprint('live/demo');assert(changed==live.fingerprint('live/demo',true));assert(manager.reload('live/demo')and CACHE_PROJECT_VALUE==3)
local stops=CACHE_PROJECT_STOPS
files['mods/demo/src/helper.lua']='return {';watch['mods/demo']=true;live.fingerprint('live/demo')
assert(not manager.reload('live/demo')and CACHE_PROJECT_VALUE==3 and CACHE_PROJECT_STOPS==stops,'Invalid edit must not stop working instance')
manager.shutdown();handle.release();LiveLuaLoader,CowboyBingusModLoader=old_loader,old_compat;CACHE_PROJECT_VALUE,CACHE_PROJECT_STOPS=nil,nil
-- Anonymous shipped bytecode and foreign replacements retain safe ownership.
local files,watch,n,p,live,controls,manager=fixture(true)
local original=manager.refresh;local copy=assert(loadstring(string.dump(original,true)));for i=1,80 do local name,v=debug.getupvalue(original,i);if not name then break end;debug.setupvalue(copy,i,v)end;manager.refresh=copy
local handle=Cache.install(manager);live.fingerprint('live/demo');local foreign=function()return'foreign'end;live.fingerprint=foreign;assert(handle.release()and live.fingerprint==foreign)
-- A failed original fingerprint is retried instead of caching partial/failure state.
local files,watch,n,p,live,controls,manager=fixture(true);local old=live.fingerprint;local fail=true
live.fingerprint=function(...)if fail then error('original failure',0)end;return old(...)end
local handle=Cache.install(manager);assert(not pcall(live.fingerprint,'live/demo'));fail=false;assert(live.fingerprint('live/demo'));handle.release()
-- Disabled auto-reload still gives explicit loads a valid baseline, then notices edits on enable.
local files,watch,n,p,live,controls,manager=fixture(true);local automatic=false;live.auto_reload=function()return automatic end
local handle=Cache.install(manager);local baseline=live.fingerprint('live/demo');assert(baseline);local reads=n.read
files['mods/demo/src/helper.lua']='return {value=8}';watch['mods/demo']=true
assert(live.fingerprint('live/demo')==baseline and n.read==reads);automatic=true;assert(live.fingerprint('live/demo')~=baseline);handle.release()
-- A failed changed read must invalidate the old success and retry without a second watcher event.
local files,watch,n,p,live,controls,manager=fixture(true);local original=live.fingerprint;local fail=false
live.fingerprint=function(...)if fail then error('temporary source error',0)end;return original(...)end
local handle=Cache.install(manager);local baseline=live.fingerprint('live/demo');files['mods/demo/src/helper.lua']='return {value=9}';watch['mods/demo']=true;fail=true
assert(not pcall(live.fingerprint,'live/demo'));fail=false;assert(live.fingerprint('live/demo')~=baseline);handle.release()
-- The maintenance project is default-enabled on a fresh scan without rewriting saved config.
local files,watch,n,p,live,controls,manager,dirs=fixture(true);local saved=files['loader.cfg']
dirs[#dirs+1]='lll_poll_cache';files['mods/lll_poll_cache/manifest.json']='{"name":"LLL Poll Cache","lll":{"entry":"main.lua","modules":["src/poll_cache.lua"],"restart_only":true}}';files['mods/lll_poll_cache/main.lua']='return {}';watch.mods=true
local names=live.scan();assert(live.entries['live/lll_poll_cache']and live.restart_only('live/lll_poll_cache')and files['loader.cfg']==saved,'New maintenance addon must default-enable without changing options')
-- A cold boot can call on_enable before the public manager exists; first update installs.
local old_mod,old_manager=mod,LiveLuaLoader;local module_read=assert(io.open('examples/poll_cache_fix/main.lua','rb'));local main=module_read:read('*a');module_read:close()
local env=setmetatable({mod={require=function()return Cache end}},{__index=_G});env._G=env
local chunk=assert(loadstring(main,'poll-cache-project'));setfenv(chunk,env);local definition=chunk();definition.on_enable();assert(type(definition.on_update)=='function')
env.LiveLuaLoader=manager;local original=live.fingerprint;definition.on_update();assert(definition.on_update==nil and live.fingerprint~=original);assert(definition.on_disable()and live.fingerprint==original)
mod,LiveLuaLoader=old_mod,old_manager
print('PASS LLL poll cache: old/new/stripped runtimes, zero idle project IO, edits/forced confirmation, real safe hot reload, restart policy, metadata/select/expand updates, error retry and CAS cleanup')
