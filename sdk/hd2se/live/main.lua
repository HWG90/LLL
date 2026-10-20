-- LLL host adapter. Shared native object access stays inside actual on_update.
local Kernel = mod.require('src.kernel')
local WorldProvider = mod.require('src.world_provider')
local Bridge = mod.require('src.stingray_bridge')
local Platform = mod.require('live.platform')
local Profile = mod.require('live.profile')
local Validation = mod.require('live.validation')
local SceneObserver = mod.require('live.scene_observer')
local host, bridge, platform, validator, file, public, previous_public
local elapsed, ready, scan_count, stopping, natural = 0, false, 0, false, {}
local observer, last_transition
local failure_cleanup_logged
local next_scan
local token = 'HD2SE-live-20261013-1'
local function quote(value)
    return '"' .. value:gsub('[%z\1-\31\\"]', function(char)
        local escapes = {['"']='\\"', ['\\']='\\\\', ['\n']='\\n', ['\r']='\\r', ['\t']='\\t'}
        return escapes[char] or string.format('\\u%04x', char:byte())
    end) .. '"'
end
local function scalar(value)
    local kind = type(value)
    if kind == 'string' then return quote(value) end
    if kind == 'boolean' then return value and 'true' or 'false' end
    if kind == 'number' and value == value and math.abs(value) < math.huge then return tostring(value) end
    return 'null'
end
local function log(event, fields)
    if not file then return end
    local parts = {'"token":' .. quote(token), '"event":' .. quote(event), '"time":' .. scalar(os.date('!%Y-%m-%dT%H:%M:%SZ'))}
    local names = {}
    for key in pairs(fields or {}) do names[#names + 1] = key end
    table.sort(names)
    for _, key in ipairs(names) do parts[#parts + 1] = quote(key) .. ':' .. scalar(fields[key]) end
    file:write('{', table.concat(parts, ','), '}\n'); file:flush()
    mod.log(event)
end
local function record_scene(why)
    local before = host:status().world_epoch
    local ok, reason = host:advance_world()
    if not ok then error(reason) end
    log('WORLD_TRANSITION', {reason=why, before=before, after=host:status().world_epoch})
    last_transition=why
    natural.transitions = (natural.transitions or 0) + 1
end
local function expose()
    previous_public = rawget(_G, 'HD2SE')
    assert(previous_public == nil, 'Another HD2SE instance already owns the namespace')
    public = {api=1,version='0.1.1-live-candidate',ready=false}
    function public.load(definitions) return host:load(definitions) end
    function public.stop(id) return host:stop(id) end
    function public.status()
        local result = host:status()
        result.bridge = bridge:status()
        result.validation = validator:status()
        return result
    end
    rawset(_G, 'HD2SE', public)
end
local function close()
    if public then public.ready = false end
    if host then
        local ok, why = host:shutdown()
        if not ok then log('CLEANUP_PENDING', {reason=why}); return false, why end
    end
    if rawget(_G, 'HD2SE') == public then rawset(_G, 'HD2SE', previous_public) end
    log('CLEANUP_ACK', {handles=host and host:status().handles or 0})
    if file then file:close(); file = nil end
    host, bridge, platform, validator, public = nil, nil, nil, nil, nil
    return true
end
return {
    live_lua_api=1,
    on_enable=function()
        local loader = assert(rawget(_G,'LiveLuaLoader'))
        file = assert(loader.compatibility.open_log('HD2SE_LiveValidation.log'))
        platform = Platform.new(Profile)
        local supported, why = platform.validate()
        assert(supported, why)
        host = Kernel.new({build={exe_sha256=Profile.exe_sha256,game_sha256=Profile.game_sha256},max_handles=65536})
        bridge = assert(Bridge.new(stingray,{current_thread=platform.current_thread,on_transition=record_scene,
            max_worlds=Profile.max_worlds,max_entities=Profile.max_entities,position=false}))
        assert(host:register_provider(assert(WorldProvider.create(host,bridge.adapter,Profile.create(platform)))))
        validator = Validation.new(stingray,host,log)
        assert(host:load({validator.definition}))
        expose()
        elapsed,ready,scan_count,stopping,natural,observer,last_transition,failure_cleanup_logged=0,false,0,false,{},nil,nil,false
        next_scan=platform.clock()
        log('READY',{thread=platform.current_thread(),exe_sha256=Profile.exe_sha256,game_sha256=Profile.game_sha256,
            lua_sha256=Profile.lua_sha256,position=false,validation_scope='real enumeration and owned native world/unit lifecycle'})
    end,
    on_update=function(dt)
        if stopping then return end
        -- Menus/photo pause can supply dt=0 while native lifetimes still change.
        local now=platform.clock()
        if now<next_scan then return end
        next_scan=now+0.5
        local ok, why = bridge:update(function()
            if observer then observer:step() else validator:step() end
            assert(host:pump('update'))
            local validation=validator:status()
            if validation.failed and not validation.cleanup_done then
                local released,reason=validator:cleanup()
                if released then
                    log('VALIDATION_FAILURE_CLEANUP_ACK',{reason=validation.reason})
                    failure_cleanup_logged=true
                elseif not failure_cleanup_logged then
                    log('VALIDATION_FAILURE_CLEANUP_PENDING',{reason=reason})
                    failure_cleanup_logged=true
                end
                validation=validator:status()
            end
            if not observer and (validation.done or (validation.failed and validation.cleanup_done)) then
                observer=SceneObserver.new(host,log,function()return last_transition end)
                assert(host:load({observer.definition}))
            end
        end)
        if not ok then log('SCAN_REFUSED',{reason=why}); return end
        scan_count = scan_count + 1
        if not ready then
            ready,public.ready=true,true
            local status=bridge:status()
            log('ENGINE_ACTIVE',{worlds=status.worlds,entities=status.entities,thread=status.thread})
        end
    end,
    on_disable=function() stopping=true;return close() end,
    on_cleanup_poll=function() return close() end,
}
