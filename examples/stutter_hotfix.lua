-- Temporary R30 maintenance fix; disable this entry to restore the old functions.
local originals={}
local function up(fn,wanted)
    if type(fn)~='function' then return end
    for i=1,80 do
        local name,value=debug.getupvalue(fn,i)
        if not name then return end
        if name==wanted then return value end
    end
end
local function find_tick(root)
    local queue,seen={root},{}
    local at=1
    while at<=#queue and at<=256 do
        local fn=queue[at];at=at+1
        if type(fn)=='function' and not seen[fn] then
            seen[fn]=true
            for i=1,80 do
                local name,value=debug.getupvalue(fn,i)
                if not name then break end
                if name=='tick' and up(value,'live') and up(value,'platform') then return value end
                if type(value)=='function' then queue[#queue+1]=value end
            end
        end
    end
end
local function find_tables(root)
    local queue,seen={root},{}
    local at=1
    local live,platform,controls,camera,reader
    while at<=#queue and at<=512 do
        local fn=queue[at];at=at+1
        if type(fn)=='function' and not seen[fn] then
            seen[fn]=true
            for i=1,80 do
                local name,value=debug.getupvalue(fn,i)
                if not name then break end
                if type(value)=='function' then queue[#queue+1]=value
                elseif type(value)=='table' then
                    if type(rawget(value,'paths'))=='table' and type(rawget(value,'candidates'))=='table'
                        and type(rawget(value,'poll'))=='function' and type(rawget(value,'discover'))=='function' then reader=value end
                    if rawget(value,'LOG_NAME')=='Freecam.log' and type(rawget(value,'LOG_EVERY'))=='number' then camera=value end
                    if type(rawget(value,'fingerprint'))=='function' and type(rawget(value,'catalog'))=='table'
                        and type(rawget(value,'auto_reload'))=='function' and type(rawget(value,'entries'))=='table' then live=value end
                    if type(rawget(value,'changed'))=='function' and type(rawget(value,'files'))=='function'
                        and type(rawget(value,'stat'))=='function' then platform=value end
                    if type(rawget(value,'refresh'))=='function' and type(rawget(value,'bindings'))=='table'
                        and type(rawget(value,'provenance_snapshot'))=='function' then controls=value end
                end
            end
        end
    end
    return live,platform,controls,camera,reader
end
local function state(api)
    local mod=api.mods and api.mods.lll_management
    if not mod then return '' end
    local parts={}
    for key,value in pairs(mod.values or {})do parts[#parts+1]='v:'..key..'='..tostring(value)end
    for key,control in pairs(mod.controls or {})do
        parts[#parts+1]='c:'..key..'='..tostring(control.label)..':'..tostring(control.disabled)
    end
    table.sort(parts);return table.concat(parts,'|')
end
local function stop_mcm_ingestion(loader)
    local record=loader and loader.records and loader.records['live/dbf_mcm']
    local queue,seen={record and record.on_update},{}
    local stopped=0;local at=1
    while at<=#queue and at<=256 do
        local fn=queue[at];at=at+1
        if type(fn)=='function' and not seen[fn] then
            seen[fn]=true
            for i=1,80 do
                local name,value=debug.getupvalue(fn,i);if not name then break end
                if name=='log_follower' and type(value)=='table' and type(value.release)=='function' then
                    value.release();debug.setupvalue(fn,i,nil);stopped=stopped+1
                elseif type(value)=='function' then queue[#queue+1]=value
                elseif type(value)=='table' and type(rawget(value,'on_update'))=='function' then queue[#queue+1]=rawget(value,'on_update')end
            end
        end
    end
    return stopped
end
local definition={live_lua_api=1}
local function apply()
    local tick=find_tick(update)
    local live,platform,controls
    if tick then
        live=up(tick,'live');platform=up(tick,'platform')
        controls=up(up(tick,'refresh_catalog'),'controls')
    else live,platform,controls=find_tables(update)end
    assert(live,'R30 catalog unavailable; no changes applied')
    assert(platform,'R30 platform unavailable; no changes applied')
    assert(controls,'R30 controls unavailable; no changes applied')
    assert(type(platform.changed)=='function','R30 watcher unavailable; no changes applied')
    local _,_,_,camera,reader=find_tables(update)
    if camera then originals.camera=camera;originals.log_every=camera.LOG_EVERY;camera.LOG_EVERY=30 end
    originals.live=live;originals.fingerprint=live.fingerprint
    originals.controls=controls;originals.refresh=controls.refresh
    local cache={}
    originals.wrapped=function(name,force)
        local entry=live.catalog[name] or live.entries[name]
        if not live.auto_reload() or not live.enabled(name) or live.restart_only(name) then return nil end
        if not entry or not entry.project then return originals.fingerprint(name,force)end
        local changed=platform.changed(entry.dir)
        local prior=cache[name]
        if not force and not changed and prior and prior.path==entry.path then return prior.value end
        local value=originals.fingerprint(name,force)
        cache[name]={path=entry.path,value=value};return value
    end
    originals.wrapped_refresh=function(...)
        local function mark()
            local parts={tostring(controls.selected)}
            for key,value in pairs(controls.expanded or {})do parts[#parts+1]='expanded:'..key..'='..tostring(value)end
            for _,row in ipairs(controls.provenance_snapshot() or {})do
                for _,key in ipairs({'name','state','owner','source','author','display_name','description'})do
                    local value=tostring(row[key]);parts[#parts+1]=#value..':'..value
                end
            end
            local loader=rawget(_G,'LiveLuaLoader')
            if loader and loader.get_loader_option then
                for _,key in ipairs({'manager_ui','manager_window','auto_reload'})do
                    local value=loader.get_loader_option(key)
                    if type(value)=='table' then for k,v in pairs(value)do parts[#parts+1]=key..':'..k..'='..tostring(v)end
                    else parts[#parts+1]=key..'='..tostring(value)end
                end
            end
            for _,binding in ipairs(controls.bindings)do parts[#parts+1]=tostring(binding.api)..tostring(binding.handle)..tostring(binding.inside)..state(binding.api)end
            table.sort(parts);return table.concat(parts,'|')
        end
        local current=mark()
        if originals.refresh_mark==current then return end
        local before={}
        for _,binding in ipairs(controls.bindings)do
            before[binding]={revision=binding.api.revision,handle=binding.handle,state=state(binding.api)}
        end
        local result=originals.refresh(...)
        for _,binding in ipairs(controls.bindings)do
            local prior=before[binding]
            if prior and prior.handle==binding.handle and prior.state==state(binding.api)then
                binding.api.revision=prior.revision
            end
        end
        originals.refresh_mark=mark()
        return result
    end
    live.fingerprint=originals.wrapped;controls.refresh=originals.wrapped_refresh
    -- This deliberate removal persists for the process when the hotfix is disabled.
    if reader then
        reader.poll=function()end;reader.discover=function()end
        reader.register=function()return false,'Mod-log ingestion removed'end
        reader.paths={};reader.candidates={};reader.count=0;reader.candidate_count=0
    end
    local loader=rawget(_G,'LiveLuaLoader')
    if loader then loader.register_log=nil end
    local stopped=stop_mcm_ingestion(loader)
    print('[Mod-log removal] LLL ingestion disabled; MCM followers stopped='..stopped)
    local file=io.open(os.getenv('LOCALAPPDATA')..'/LLL/Helldivers2/Logs/Mod-log-removal.txt','w')
    if file then file:write('LLL ingestion disabled; MCM followers stopped='..stopped..'\n');file:close()end
    print('[Stutter hotfix] ACTIVE: change-driven project fingerprints and idle MCM revision suppression')
end
definition.on_enable=function()
    -- Initial modules load before start.lua installs the update wrapper.
    -- Resolve its closures on the first frame, after bootstrap completes.
    definition.on_update=function()
        apply()
        definition.on_update=nil
    end
end
definition.on_disable=function()
    if originals.camera and originals.camera.LOG_EVERY==30 then originals.camera.LOG_EVERY=originals.log_every end
    if originals.live and originals.live.fingerprint==originals.wrapped then originals.live.fingerprint=originals.fingerprint end
    if originals.controls and originals.controls.refresh==originals.wrapped_refresh then originals.controls.refresh=originals.refresh end
    print('[Stutter hotfix] RESTORED original maintenance functions')
    return true
end
return definition
