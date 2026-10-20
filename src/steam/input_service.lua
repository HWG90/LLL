-- One helper connection, with exclusive cursor ownership for manager and mods.
local M={}
function M.new(platform,window,capture)
    local service,driver={version=1},{}
    local capabilities={menu=true,camera=type(platform.camera_snapshot)=='function',
        relative_mouse=type(platform.camera_snapshot)=='function',coordinates='client-top-left'}
    service.capabilities=setmetatable({},{__index=capabilities,__metatable=false,
        __newindex=function()error('Input capabilities are read-only',2)end})
    local lease,manager_reader,manager_busy=nil,false,function()return false end
    local mcm_frontend
    local sampled,sample_taken=false,false
    local manager_sample
    local sample={}
    local sample_keys={'x','y','width','height','buttons','wheel','dx','dy'}
    local invalid={valid=false,x=0,y=0,width=0,height=0,buttons=0,wheel=0,dx=0,dy=0}
    local function foreground()
        local ok,value=pcall(window.has_focus)
        return ok and value==true
    end
    local function valid_frontend(token)
        return token~=nil and mcm_frontend~=nil and mcm_frontend.token==token
            and rawget(_G,'DBFMCM')==mcm_frontend.provider
            and rawget(mcm_frontend.provider,'shared_input_service')==service
    end
    local function mcm_busy(frontend)
        if frontend and not valid_frontend(frontend) then return true end
        local provider=rawget(_G,'DBFMCM')
        if not provider then return false end
        if type(provider)~='table' then return true end
        if type(provider.input_status)=='function' then
            local ok,value=pcall(provider.input_status)
            if not ok or type(value)~='table' or value.pending_restore then return true end
            if frontend then
                if type(value.active)~='boolean' or type(value.pending_restore)~='boolean' then return true end
                if value.owner~=nil and value.owner~='DBF MCM' then return true end
                if value.active and value.owner~='DBF MCM' then return true end
            elseif value.owner or value.active then return true end
        elseif frontend then
            return true
        end
        if type(provider.is_open)~='function' then return true end
        local ok,value=pcall(provider.is_open)
        if frontend then return not ok or type(value)~='boolean' end
        return not ok or value~=false
    end
    local function manager_is_busy()
        local ok,value=pcall(manager_busy)
        return not ok or value==true
    end
    local function close_lease(reason)
        local current=lease
        if not current then return true end
        current.active=false
        current.reason=reason or current.reason or 'Released'
        sampled,sample_taken=false,false
        local pointer_ok,pointer_why=true,nil
        if current.reader then
            local ok,value=pcall(platform.release_pointer)
            pointer_ok=ok and value==true
            if pointer_ok then current.reader=false
            else pointer_why=ok and 'Pointer release refused' or tostring(value) end
        end
        local restored,why=true,nil
        if current.capture then
            restored,why=capture.release(current.token)
            if restored then current.capture=false end
        end
        if pointer_ok and restored then lease=nil;return true end
        current.reason=pointer_why or why or 'Input restoration pending'
        return false,current.reason
    end
    function service.register_frontend(role,provider)
        if role~='mcm' or type(provider)~='table' or rawget(_G,'DBFMCM')~=provider
            or rawget(provider,'shared_input_service')~=service
            or type(provider.is_open)~='function' or type(provider.input_status)~='function' then
            return nil,'Published MCM frontend for this service required'
        end
        if mcm_frontend and (mcm_frontend.provider==provider or (lease and lease.frontend)) then
            return nil,'MCM frontend already registered or restoring'
        end
        local token={}
        mcm_frontend={token=token,provider=provider}
        return token
    end
    function service.unregister_frontend(token)
        if token==nil or not mcm_frontend or mcm_frontend.token~=token then
            return false,'MCM frontend registration not owned'
        end
        if lease and lease.frontend==token then return false,'Release MCM input before unregistering' end
        mcm_frontend=nil
        return true
    end
    function service.acquire(owner,mode,frontend)
        if type(owner)~='string' or owner=='' or #owner>128 or owner:find('%c') then
            return nil,'Owner name required (1-128 printable bytes)'
        end
        mode=mode or 'menu'
        if mode~='menu' and mode~='camera' then return nil,'Unsupported input mode' end
        if frontend~=nil and (not valid_frontend(frontend) or owner~='DBF MCM' or mode~='menu') then
            return nil,'MCM frontend registration not owned or mode unsupported'
        end
        if mode=='camera' and not capabilities.camera then return nil,'Relative camera input unavailable' end
        if lease or manager_reader or manager_is_busy() or mcm_busy(frontend) then return nil,'Input lease already owned' end
        if not foreground() then return nil,'Game is not foreground' end
        local status=capture.status()
        if status.owner or status.pending_restore then return nil,'Cursor lease already owned or restoring' end
        local token,why=capture.acquire(owner)
        if not token then return nil,why end
        lease={token=token,owner=owner,mode=mode,frontend=frontend,active=false,capture=true,reader=false}
        local ok;ok,why=capture.activate(token,mode)
        if not ok then
            local restored=close_lease(why)
            return nil,why,not restored and token or nil
        end
        lease.active=true
        sampled,sample_taken=false,false
        return token
    end
    function service.owns(token)
        return token~=nil and lease~=nil and lease.token==token and lease.active
    end
    function service.release(token)
        if token==nil or not lease or lease.token~=token then return false,'Input lease not owned' end
        return close_lease('Released')
    end
    function service.snapshot(token)
        if not service.owns(token) then return nil,'Input lease inactive or not owned' end
        if not foreground() or mcm_busy(lease.frontend) then
            close_lease('Input ownership lost')
            return nil,'Input ownership lost'
        end
        if not sampled then
            local current=lease
            current.reader=true -- A failed request may still have started the reader.
            local read=current.mode=='camera' and platform.camera_snapshot or platform.pointer_snapshot
            local ok,value=pcall(read)
            if not ok or type(value)~='table' or value.valid~=true then
                close_lease(ok and 'Pointer foreground unavailable' or tostring(value))
                return nil,ok and 'Pointer foreground unavailable' or tostring(value)
            end
            sample.valid=true
            for _,key in ipairs(sample_keys)do sample[key]=value[key] or 0 end
            sampled=true
        end
        if sample_taken then sample.wheel,sample.dx,sample.dy=0,0,0 end
        sample_taken=true
        return sample
    end
    function service.status()
        return {owner=lease and lease.owner or nil,mode=lease and lease.mode or nil,
            frontend=lease and lease.frontend and 'mcm' or nil,
            active=lease~=nil and lease.active,pending_restore=lease~=nil and not lease.active,
            reason=lease and lease.reason or nil}
    end
    function driver.set_manager_busy(fn)manager_busy=assert(fn)end
    function driver.begin_frame()
        sampled,sample_taken=false,false
        manager_sample=nil
        if lease and lease.active and (not foreground() or mcm_busy(lease.frontend)) then close_lease('Input ownership lost') end
    end
    function driver.manager_available()
        return lease==nil
    end
    function driver.manager_snapshot()
        if lease or not foreground() then return invalid end
        if manager_sample then return manager_sample end
        manager_reader=true
        manager_sample=platform.pointer_snapshot()
        return manager_sample
    end
    function driver.manager_release()
        manager_sample=nil
        local ok,why=true,nil
        if manager_reader then
            local called,value=pcall(platform.release_pointer)
            ok=called and value==true
            if ok then manager_reader=false else why=called and 'Manager pointer release refused' or tostring(value) end
        end
        if not lease then
            local restored,problem=capture.release()
            if not restored then ok,why=false,problem end
        end
        return ok,why
    end
    function driver.close()
        local ok,why=close_lease('Loader shutting down')
        local manager_ok,manager_why=driver.manager_release()
        return ok and manager_ok,why or manager_why
    end
    driver.capture=capture
    return service,driver
end
return M
