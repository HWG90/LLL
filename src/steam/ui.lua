-- Independent manager frontend with optional MCM integration.
return function(loader, platform, controls, report, input_driver)
    local self = {}
    local menu, view, capture, input, console_surface, raw
    local hotkey_held, suppress_toggle, hotkey_deferred = false, false, false
    local failed_shortcut
    local preferences=LLL_UI_PREFERENCES or dofile("src/ui/preferences.lua")
    local initialize
    local api = LLL_UI_CORE.new(nil, function(msg)
        report("LLL UI", msg)
    end)
    controls.bind(api, "origins")
    loader.manager_preferences_changed=function(values)
        if api.menu_toggle_key~=values.menu_toggle_key then hotkey_held,suppress_toggle=true,true end
        api.menu_toggle_key=values.menu_toggle_key
        api.apply_key,api.focus_key=values.apply_key,values.focus_key
        if menu then menu.ui_scale,menu.font_scale=values.ui_scale,values.font_scale end
    end
    loader.manager_preferences_changed(preferences.get(loader))
    loader.reset_manager_window=function()
        if menu then menu.window_width,menu.window_height,menu.window_x,menu.window_y=nil,nil,nil,nil end
    end
    self.api = api
    api.diagnostics = loader.diagnostics
    api.diagnostics_surface = loader.diagnostics_surface
    api.author_navigation = true
    api.loader_summary = controls.provenance_summary or controls.summary
    local function manager_failure()
        return input_driver and input_driver.manager_failure and input_driver.manager_failure()
    end
    local function require_manager_input()
        local failure=manager_failure()
        if failure then error(failure,2)end
    end
    function self.open()
        local recovering=manager_failure()
        if recovering then
            local released,why=input_driver.manager_release()
            if not released then return false,why end
        end
        if input_driver and not input_driver.manager_available() then return false,'Input lease belongs to another owner' end
        local mcm = rawget(_G, 'DBFMCM')
        if mcm and type(mcm) ~= 'table' then return false, 'MCM provider unavailable' end
        if not menu and initialize then
            local ok, why = pcall(initialize)
            if not ok then
                self.close()
                self.unavailable = tostring(why)
                return false, self.unavailable
            end
        end
        if not menu then
            return false, self.unavailable or "Native manager unavailable"
        end
        mcm = rawget(_G, "DBFMCM")
        if mcm and type(mcm) ~= 'table' then return false, 'MCM provider unavailable' end
        if mcm and type(mcm.close) == "function" then
            local ok, why = mcm.close()
            if ok == false then
                return false, why
            end
        end
        if failed_shortcut or recovering then
            failed_shortcut=nil
            hotkey_held,suppress_toggle=true,true
        end
        self.open_pending = true
        menu.visible = true
        return true
    end
    function self.close()
        local failed=manager_failure()
        if console_surface then console_surface.release() end
        self.open_pending = false
        if menu then
            menu.visible = false
        end
        local ok, why = true, nil
        if input_driver then
            ok,why=input_driver.manager_release()
        elseif capture then
            ok, why = capture.release()
        end
        if failed or manager_failure() then failed_shortcut='down' end
        if raw then
            local released,problem
            if input_driver then released,problem=pcall(raw.release,ok==true)
            else released,problem=pcall(raw.release) end
            if not released then ok,why=false,tostring(problem);report('LLL UI',why) end
        end
        if view then
            view.release()
        end
        return ok, why
    end
    loader.close_manager = self.close
    loader.input_status = function()
        local owner_capture=input_driver and input_driver.capture or capture
        return owner_capture and owner_capture.status() or { active = false }
    end
    loader.open_manager = function()
        local ok, why = self.open()
        assert(ok, why)
    end
    local sr = rawget(_G, "stingray")
    if not sr or not sr.Window or not platform.settings then
        self.unavailable = "Native GUI unavailable"
        return self
    end
    local input_platform=platform
    if input_driver then
        input_driver.set_manager_busy(function()return self.open_pending or (menu and menu.visible) or false end)
        -- The manager's engine-keyboard mode receives pointer-only samples.
        -- Advertise captured keys only when this reader owns a keyboard lease.
        local manager_keyboard_mask=false
        if platform.manager_engine_keyboard~=true then manager_keyboard_mask=platform.keyboard_capture_mask end
        input_platform=setmetatable({pointer_snapshot=input_driver.manager_snapshot,
            release_pointer=input_driver.manager_release,
            keyboard_capture_mask=manager_keyboard_mask},
            {__index=platform})
    end
    raw = LLL_STEAM_INPUT.new(sr,input_platform)
    local foreground = false
    local function mcm_binding(provider)
        if type(provider) ~= 'table' then return end
        local query = rawget(provider, 'menu_binding_status')
        if type(query) ~= 'function' then return end
        local status = query()
        if type(status) == 'table' and rawget(_G, 'DBFMCM') == provider then
            return rawget(status, 'global_key')
        end
    end
    local function shortcut_state(focused)
        local shortcut = api.menu_toggle_key or 45
        local down = raw.down(shortcut)
        if failed_shortcut then
            -- After native capture fails, the engine may report zero before a
            -- still-held key repeats. Observe a whole hidden down/up cycle.
            if not (menu and (menu.visible or self.open_pending)) then
                if failed_shortcut=='down' and down then failed_shortcut='up'
                elseif failed_shortcut=='up' and not down then failed_shortcut=nil end
            end
            hotkey_held,hotkey_deferred=down,failed_shortcut~=nil
            return false,false,focused
        end
        local edge = down and not hotkey_held
        if not down then
            hotkey_deferred = false
        elseif edge then
            if focused == nil then focused = sr.Window.has_focus() == true end
            -- MCM runs before this frontend and may already have closed on this
            -- edge. Its published binding owns the whole press, until release.
            if focused then
                local ok, binding = pcall(mcm_binding, rawget(_G, 'DBFMCM'))
                hotkey_deferred = ok and binding == shortcut
            end
        end
        hotkey_held = down
        return down and not hotkey_deferred, edge, focused
    end
    function self.tick()
        raw.frame()
        local down, edge, focused = shortcut_state()
        if down and edge and focused then
            local ok,why=self.open()
            if not ok then report('LLL UI',why) end
        end
    end
    initialize = function()
        capture=input_driver and input_driver.capture or LLL_UI_CAPTURE.new(nil,sr.Window,function(message)report('LLL UI',message)end)
        view=LLL_UI_VIEW.new(sr)
        view.set_font_source(LLL_UI_FONT.new())
        menu=LLL_UI_MENU.new(api,view.measure)
        self.menu=menu
        LLL_UI_METADATA_EDITOR.install(api,loader,controls,function()return menu end)
        loader.manager_preferences_changed(preferences.get(loader))
        if loader.diagnostics and loader.diagnostics_surface then console_surface=loader.diagnostics_surface(loader.diagnostics) end
        local saved=loader.get_loader_option and loader.get_loader_option('manager_window')
        if type(saved)=='table' then
            menu.window_width,menu.window_height,menu.window_x,menu.window_y=saved.width,saved.height,saved.x,saved.y
        end
        menu.on_geometry_changed=function(geometry)
            if loader.save_loader_option and geometry then
                local ok,why=loader.save_loader_option('manager_window',{
                    width=geometry.width,height=geometry.height,x=geometry.x,y=geometry.y})
                if not ok then report('LLL UI',why) end
            end
        end
        input={mouse=raw.mouse,wheel=raw.wheel}
        suppress_toggle=raw.down(api.menu_toggle_key or 45)
        function input.down(code)
            if not foreground then return false end
            if code==121 and failed_shortcut then return false end
            if menu.capture then return raw.down(code) end
            local shortcut=api.menu_toggle_key or 45
            if code==shortcut and code~=121 then return false end
            if code==121 then
                if hotkey_deferred then return false end
                if suppress_toggle then
                    if not raw.down(shortcut) then suppress_toggle=false end
                    return false
                end
                code=shortcut
            end
            return raw.down(code)
        end
        local hidden_clean=false
        function self.tick(dt)
            raw.frame()
            local ok,why=pcall(function()
                local showing=menu.visible or self.open_pending
                foreground=sr.Window.has_focus()==true
                if not foreground and showing then
                    local released,problem=self.close()
                    if not released then report('LLL UI',tostring(problem))end
                    showing=false
                end
                if foreground then
                    local down,edge=shortcut_state(true)
                    if down and edge and not showing and manager_failure() then
                        local opened,problem=self.open()
                        if not opened then failed_shortcut='up';report('LLL UI',tostring(problem))end
                    end
                else hotkey_held, hotkey_deferred = true, true end
                raw.visible(foreground and (menu.visible or self.open_pending))
                if menu.visible or self.open_pending then require_manager_input()end
                if self.open_pending then
                    if not foreground then self.open_pending=false;menu.visible=false
                    else
                        local held=false
                        for _,code in ipairs({1,2,4,5,6}) do held=held or raw.down(code) end
                        menu.visible=not held
                        if not held then self.open_pending=false end
                    end
                end
                local provider=rawget(_G,'DBFMCM')
                if not foreground or (provider and provider.is_open and provider.is_open()) then menu.visible=false end
                local was=menu.visible
                menu.tick(console_surface and console_surface.filter(input,menu.visible,dt) or input)
                if menu.visible then require_manager_input()end
                if menu.visible and not was and provider and provider.close then
                    local released,problem=provider.close()
                    if released==false then menu.visible=false;report('LLL UI',tostring(problem)) end
                end
                if showing and not menu.visible and not self.open_pending then
                    local released,problem=self.close()
                    if not released then report('LLL UI',tostring(problem))end
                end
                local acquired,problem=true,nil
                -- Keyboard retirement must be acknowledged before the manager
                -- cursor lease may restore; hidden frames never retry it.
                if not manager_failure() then acquired,problem=capture.sync(menu.visible or self.open_pending,foreground) end
                if not acquired then self.close();report('LLL UI',tostring(problem)) end
                if not menu.visible then
                    if not self.open_pending then raw.visible(false)end
                    if not hidden_clean then
                        menu.advance(dt);menu.compose()
                        if console_surface then console_surface.release() end
                        view.release();hidden_clean=true
                    end
                    return
                end
                hidden_clean=false
                local width,height=sr.Gui.resolution()
                if type(width)~='number' or type(height)~='number' or width<=0 or height<=0 then self.close();menu.recover();return end
                menu.advance(dt)
                local commands=menu.compose(width,height)
                if console_surface then
                    local g=menu.parent_geometry
                    local bounds=g and {x=g.x,y=g.y,w=g.width*g.scale,h=g.height*g.scale}
                    for _,command in ipairs(console_surface.compose(width,height,bounds,menu.visible)) do commands[#commands+1]=command end
                end
                view.draw(commands)
            end)
            if not ok then self.close();menu.recover();report('LLL UI',tostring(why)) end
        end
        report('LLL UI','Steam manager initialized; engine input and window cursor ownership')
    end
    report('LLL UI','Steam manager ready on configured shortcut')
    return self
end
