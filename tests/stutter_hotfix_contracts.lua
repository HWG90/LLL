local old_update=update
local old_open,old_loader=io.open,LiveLuaLoader
io.open=function()return {write=function()end,close=function()end}end
local follower_released=false
local log_follower={release=function()follower_released=true end,tick=function()end}
LiveLuaLoader={register_log=function()end,records={['live/dbf_mcm']={on_update=function()if log_follower then log_follower.tick()end end}}}
local reads,changed=0,true
local live={catalog={demo={project={},dir='demo',path='demo/main.lua'}},entries={}}
live.auto_reload=function()return true end;live.enabled=function()return true end;live.restart_only=function()return false end
live.fingerprint=function()reads=reads+1;return tostring(reads)end
local platform={changed=function()local result=changed;changed=false;return result end,files=function()end,stat=function()end}
local api={revision=1,mods={lll_management={values={enabled=true},controls={status={label='Loaded',disabled=false}}}}}
local controls={bindings={{api=api,handle={}}},refresh=function()api.revision=api.revision+1 end,provenance_snapshot=function()end}
local function refresh_catalog()controls.refresh()end
local camera={LOG_NAME='Freecam.log',LOG_EVERY=1}
local reader={paths={},candidates={},poll=function()end,discover=function()end}
local function camera_step()return camera.LOG_EVERY end
local function tick()live.fingerprint('demo');platform.changed('unused');refresh_catalog();camera_step();reader.poll()end
update=function()tick()end
local prior_update=update
update=function()prior_update()end
local original_fingerprint,original_refresh=live.fingerprint,controls.refresh
local hotfix=dofile('examples/stutter_hotfix.lua')
hotfix.on_enable()
assert(not follower_released,'Startup must defer hook discovery until the first frame')
hotfix.on_update()
assert(follower_released and log_follower==nil and LiveLuaLoader.register_log==nil,'Both active ingestion routes must be removed')
assert(reader.register()==false,'Explicit external log registration must stay removed')
assert(hotfix.on_update==nil,'Removed ingestion must not install a polling callback')
assert(camera.LOG_EVERY==30,'Routine camera statistics must be throttled')
local first=live.fingerprint('demo');assert(reads==1)
assert(live.fingerprint('demo')==first and reads==1)
changed=true;assert(live.fingerprint('demo')~=first and reads==2)
live.fingerprint('demo',true);assert(reads==3)
controls.refresh();assert(api.revision==1,'Idle revision must stay stable')
hotfix.on_disable();assert(live.fingerprint==original_fingerprint and controls.refresh==original_refresh)
assert(camera.LOG_EVERY==1,'Camera diagnostic interval must restore')
local function stripped(fn)
    local copy=assert(loadstring(string.dump(fn,true)))
    for i=1,80 do local name,value=debug.getupvalue(fn,i);if not name then break end;debug.setupvalue(copy,i,value)end
    return copy
end
refresh_catalog=stripped(refresh_catalog);tick=stripped(tick)
prior_update=stripped(prior_update);update=stripped(update)
changed=true;hotfix.on_enable();hotfix.on_update()
live.fingerprint('demo');local after=reads;live.fingerprint('demo');assert(reads==after,'Stripped R30 bytecode must use the same safe cache')
hotfix.on_disable();assert(live.fingerprint==original_fingerprint and controls.refresh==original_refresh)
update=old_update
io.open,LiveLuaLoader=old_open,old_loader
print('PASS reversible R30 hotfix: idle cache, watcher edit, forced confirmation and revision suppression')
