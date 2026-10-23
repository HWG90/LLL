-- One helper connection, with exclusive cursor ownership for manager and mods.
local M={}
function M.new(platform,window,capture)
    local service,driver={version=1},{}
    local keyboard_mask=platform.keyboard_capture_mask
    local keyboard=type(platform.keyboard_prepare)=='function'and type(platform.keyboard_acquire)=='function'
        and type(platform.keyboard_snapshot)=='function'and type(platform.keyboard_release)=='function'
        and type(keyboard_mask)=='string'and #keyboard_mask==32
    local capabilities={menu=true,camera=type(platform.camera_snapshot)=='function',
        relative_mouse=type(platform.camera_snapshot)=='function',coordinates='client-top-left',
        keyboard=keyboard,keyboard_mask=keyboard and keyboard_mask or nil,
        keyboard_scope=keyboard and (platform.keyboard_scope or 'registered-keys') or nil}
    service.capabilities=setmetatable({},{__index=capabilities,__metatable=false,
        __newindex=function()error('Input capabilities are read-only',2)end})
    local lease,manager_reader,manager_busy=nil,false,function()return false end
    local mcm_frontend
    local sampled,sample_taken=false,false
    local manager_sample
    local manager_keyboard,manager_failed
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
        -- A request whose acknowledgement was lost may already own hotkeys.
        -- Keep its private handle and cursor lease until exact release ACK.
        if current.keyboard then
            local ok,value,why=pcall(platform.keyboard_release,current.keyboard)
            if not ok or value~=true then
                current.reason=ok and (why or 'Keyboard release refused') or tostring(value)
                return false,current.reason
            end
            current.keyboard=nil
        end
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
    function service.acquire(owner,mode,frontend,options)
        if type(owner)~='string' or owner=='' or #owner>128 or owner:find('%c') then
            return nil,'Owner name required (1-128 printable bytes)'
        end
        mode=mode or 'menu'
        if mode~='menu' and mode~='camera' then return nil,'Unsupported input mode' end
        if frontend~=nil and (not valid_frontend(frontend) or owner~='DBF MCM' or mode~='menu') then
            return nil,'MCM frontend registration not owned or mode unsupported'
        end
        if mode=='camera' and not capabilities.camera then return nil,'Relative camera input unavailable' end
        if options~=nil and (type(options)~='table'or options.keyboard~=nil and type(options.keyboard)~='boolean') then
            return nil,'Invalid input options'
        end
        local want_keyboard=options~=nil and options.keyboard==true
        if want_keyboard and not keyboard then return nil,'Keyboard capture unavailable' end
        if lease or manager_reader or manager_keyboard or manager_is_busy() or mcm_busy(frontend) then return nil,'Input lease already owned' end
        if not foreground() then return nil,'Game is not foreground' end
        local status=capture.status()
        if status.owner or status.pending_restore then return nil,'Cursor lease already owned or restoring' end
        local token,why=capture.acquire(owner)
        if not token then return nil,why end
        lease={token=token,owner=owner,mode=mode,frontend=frontend,active=false,capture=true,reader=false}
        local called,ok;called,ok,why=pcall(capture.activate,token,mode)
        if not called then why=tostring(ok);ok=false end
        if ok and want_keyboard then
            called,lease.keyboard,why=pcall(platform.keyboard_prepare)
            if not called then why=tostring(lease.keyboard);lease.keyboard=nil;ok=false
            elseif not lease.keyboard then ok=false
            else
                called,ok,why=pcall(platform.keyboard_acquire,lease.keyboard)
                if not called then why=tostring(ok);ok=false end
            end
        end
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
    function service.set_mode(token,mode)
        if not service.owns(token) then return false,'Input lease inactive or not owned' end
        if mode~='menu'and mode~='camera' then return false,'Unsupported input mode' end
        if mode=='camera'and (not capabilities.camera or lease.frontend) then return false,'Camera mode unavailable for this lease' end
        if lease.mode==mode then return true end
        if not foreground() or mcm_busy(lease.frontend) then
            close_lease('Input ownership lost')
            return false,'Input ownership lost'
        end
        local called,ok,why=pcall(capture.set_mode,token,mode)
        if not called then why=tostring(ok);ok=false end
        if ok~=true then
            why=why or 'Cursor mode change refused'
            close_lease(why)
            return false,why
        end
        lease.mode=mode
        sampled,sample_taken=false,false
        return true
    end
    local function keyboard_sample(value)
        return type(value)=='table'and (value.keyboard_state==1 or value.keyboard_state==2)
            and value.keyboard_active==(value.keyboard_state==2)
            and type(value.keyboard_keys)=='string'and #value.keyboard_keys==32
            and type(value.keyboard_mask)=='string'and #value.keyboard_mask==32
    end
    local function copy_sample(value)
        sample.valid=value.valid==true
        for _,key in ipairs(sample_keys)do sample[key]=value[key] or 0 end
        sample.keyboard_active=value.keyboard_active
        sample.keyboard_state=value.keyboard_state
        sample.keyboard_generation=value.keyboard_generation
        sample.keyboard_keys=value.keyboard_keys
        sample.keyboard_mask=value.keyboard_mask
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
            local ok,value
            if current.keyboard then ok,value=pcall(platform.keyboard_snapshot,current.keyboard,current.mode)
            else ok,value=pcall(current.mode=='camera' and platform.camera_snapshot or platform.pointer_snapshot) end
            local arming=current.keyboard and type(value)=='table'and value.keyboard_state==1
            if not ok or type(value)~='table' or value.valid~=true and not arming or current.keyboard and not keyboard_sample(value) then
                close_lease(ok and 'Pointer foreground unavailable' or tostring(value))
                return nil,ok and 'Pointer foreground unavailable' or tostring(value)
            end
            copy_sample(value)
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
            reason=lease and lease.reason or nil,keyboard=lease~=nil and lease.keyboard~=nil}
    end
    function driver.set_manager_busy(fn)manager_busy=assert(fn)end
    function driver.begin_frame()
        sampled,sample_taken=false,false
        manager_sample=nil
        if lease and lease.active and (not foreground() or mcm_busy(lease.frontend)) then close_lease('Input ownership lost') end
        if manager_keyboard and not manager_failed and not foreground() then driver.manager_release() end
    end
    function driver.manager_available()
        return lease==nil and not manager_failed
    end
    function driver.manager_failure()return manager_failed end
    function driver.manager_snapshot()
        if lease then return invalid end
        if not foreground() then
            if not manager_failed and (manager_keyboard or manager_reader) then driver.manager_release() end
            return invalid
        end
        if manager_sample then return manager_sample end
        if manager_failed then return invalid end
        if keyboard and platform.manager_engine_keyboard~=true and not manager_keyboard then
            local called,handle,why=pcall(platform.keyboard_prepare)
            if not called or not handle then
                manager_failed=called and (why or 'Keyboard preparation refused') or tostring(handle)
                return invalid
            end
            manager_keyboard=handle -- Store before the first native exchange.
            local ok;called,ok,why=pcall(platform.keyboard_acquire,handle)
            if not called or ok~=true then
                manager_failed=called and (why or 'Keyboard acquisition refused') or tostring(ok)
                return invalid
            end
        end
        manager_reader=true
        if manager_keyboard then
            local ok,value=pcall(platform.keyboard_snapshot,manager_keyboard,'menu')
            local arming=type(value)=='table'and value.keyboard_state==1
            if not ok or type(value)~='table'or value.valid~=true and not arming or not keyboard_sample(value) then
                manager_failed=ok and 'Keyboard foreground unavailable' or tostring(value)
                return invalid
            end
            manager_sample=value
        else manager_sample=platform.pointer_snapshot() end
        return manager_sample
    end
    function driver.manager_release()
        manager_sample=nil
        if lease then return true end -- Never release a shared owner's backend.
        local ok,why=true,nil
        if manager_keyboard then
            local called,value,problem=pcall(platform.keyboard_release,manager_keyboard)
            if not called or value~=true then
                manager_failed=called and (problem or 'Manager keyboard release refused') or tostring(value)
                return false,manager_failed
            end
            manager_keyboard=nil
        end
        if manager_reader then
            local called,value=pcall(platform.release_pointer)
            ok=called and value==true
            if ok then manager_reader=false else why=called and 'Manager pointer release refused' or tostring(value) end
        end
        if not lease then
            local restored,problem=capture.release()
            if not restored then ok,why=false,problem end
        end
        if ok then manager_failed=nil end
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
