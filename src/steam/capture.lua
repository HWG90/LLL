-- Engine cursor lease. Does not install native message or process hooks.
local M = {}
function M.new(_, window, log)
    local self = {active=false}
    local saved, external
    local fields = {{'mouse_focus','set_mouse_focus','focus'}, {'show_cursor','set_show_cursor','cursor'}, {'clip_cursor','set_clip_cursor','clip'}}
    local modes={menu={focus=false,cursor=true,clip=true},camera={focus=false,cursor=false,clip=true}}
    local function snapshot()
        return {focus=window.mouse_focus(), cursor=window.show_cursor(), clip=window.clip_cursor()}
    end
    local function restore(value)
        if not value then return true end
        for _, field in ipairs(fields) do
            local ok, result = pcall(window[field[2]], value[field[3]])
            if not ok or result == false then return false, 'Cursor restoration refused: ' .. field[1] end
        end
        for _, field in ipairs(fields) do
            local ok, result = pcall(window[field[1]])
            if not ok or result ~= value[field[3]] then return false, 'Cursor restoration pending: ' .. field[1] end
        end
        return true
    end
    local function read_field(field)
        local ok,value=pcall(window[field[1]])
        if not ok then return nil,'Cursor readback failed: '..field[1]..': '..tostring(value) end
        if type(value)~='boolean' then return nil,'Invalid cursor state: '..field[1] end
        return value
    end
    local function closing(why)
        external.active,external.closing=false,true
        return false,why
    end
    local function external_current(field)
        local value,why=read_field(field)
        if why then return false,why end
        local key=field[3]
        -- Focus changes may already have restored an original flag. Do not
        -- rewrite it, or retain a restoration job that has already completed.
        if value==external.saved[key] then external.changed[key]=nil;return true end
        if value~=external.expected[key] then return false,'Cursor state belongs to another owner: '..field[1] end
        return true
    end
    function self.acquire(owner)
        if type(owner) ~= 'string' or owner == '' then return nil, 'Owner name required' end
        if saved or external then return nil, 'Input lease already owned' end
        local ok,baseline=pcall(snapshot)
        if not ok then return nil,tostring(baseline) end
        for _,field in ipairs(fields)do
            if type(baseline[field[3]])~='boolean' then return nil,'Invalid cursor state: '..field[1] end
        end
        external = {owner=owner, token={}, saved=baseline,changed={},expected={},active=false,closing=false}
        return external.token
    end
    function self.owns(token) return external ~= nil and external.token == token end
    function self.activate(token,mode)
        if not self.owns(token) then return false,'Input lease not owned' end
        mode=mode or 'menu'
        local target=modes[mode]
        if not target then return false,'Unsupported input mode' end
        if external.closing then return false,'Input lease restoration pending' end
        if external.active then
            if external.mode~=mode then return false,'Release the input lease before changing mode' end
            return true
        end
        if external.saved.focus~=true then return false,'Close the other input owner first' end
        -- A reservation never authorizes overwriting a new baseline owner.
        for _,field in ipairs(fields)do
            local value,why=read_field(field)
            if why then return closing(why) end
            if value~=external.saved[field[3]] then return closing('Cursor baseline changed: '..field[1]) end
        end
        for _,field in ipairs(fields)do
            local key=field[3]
            if external.saved[key]~=target[key] then
                external.changed[key],external.expected[key]=true,external.saved[key]
                local applied,result=pcall(window[field[2]],target[key])
                if applied and result~=false then external.expected[key]=target[key] end
                local value,why=read_field(field)
                if not why then
                    if value==external.saved[key] then external.changed[key]=nil
                    elseif value==target[key] then external.expected[key]=target[key] end
                end
                if not applied or result==false then return closing('Cursor acquisition refused: '..field[1]) end
                if why then return closing(why) end
                if value~=target[key] then return closing('Cursor acquisition readback failed: '..field[1]) end
            end
        end
        for _,field in ipairs(fields)do
            local value,why=read_field(field)
            if why then return closing(why) end
            if value~=target[field[3]] then return closing('Cursor acquisition readback failed: '..field[1]) end
        end
        external.active,external.mode=true,mode
        return true
    end
    function self.set_mode(token,mode)
        if not self.owns(token) then return false,'Input lease not owned' end
        local target=modes[mode]
        if not target then return false,'Unsupported input mode' end
        if external.closing or not external.active then return false,'Input lease inactive or restoring' end
        if external.mode==mode then return true end
        local previous=modes[external.mode]
        -- Unlike restoration, changing mode cannot adopt a field that another
        -- owner has reset to our baseline. Check the whole active state first.
        for _,field in ipairs(fields)do
            local value,why=read_field(field)
            if why then return closing(why) end
            if value~=previous[field[3]] then return closing('Cursor state belongs to another owner: '..field[1]) end
        end
        for _,field in ipairs(fields)do
            local key=field[3]
            if previous[key]~=target[key] then
                external.changed[key],external.expected[key]=true,previous[key]
                local applied,result=pcall(window[field[2]],target[key])
                if applied and result~=false then external.expected[key]=target[key] end
                local value,why=read_field(field)
                if not why then
                    if value==external.saved[key] then external.changed[key]=nil
                    elseif value==target[key] then external.expected[key]=target[key] end
                end
                if not applied or result==false then return closing('Cursor mode change refused: '..field[1]) end
                if why then return closing(why) end
                if value~=target[key] then return closing('Cursor mode change readback failed: '..field[1]) end
            end
        end
        for _,field in ipairs(fields)do
            local value,why=read_field(field)
            if why then return closing(why) end
            if value~=target[field[3]] then return closing('Cursor mode change readback failed: '..field[1]) end
        end
        external.mode=mode
        return true
    end
    function self.release(token)
        if token ~= nil then
            if not self.owns(token) then return false, 'Input lease not owned' end
            external.active,external.closing=false,true
            -- Check every changed field before making any restoration write.
            for _,field in ipairs(fields)do
                if external.changed[field[3]] then
                    local ok,why=external_current(field)
                    if not ok then return false,why end
                end
            end
            for _,field in ipairs(fields)do
                local key=field[3]
                if external.changed[key] then
                    local ok,why=external_current(field)
                    if not ok then return false,why end
                    if external.changed[key] then
                        local applied,result=pcall(window[field[2]],external.saved[key])
                        if applied and result~=false then external.expected[key]=external.saved[key] end
                        local value,problem=read_field(field)
                        if not problem and value==external.saved[key] then external.changed[key]=nil end
                        if not applied or result==false then return false,'Cursor restoration refused: '..field[1] end
                        if problem then return false,problem end
                        if value~=external.saved[key] then return false,'Cursor restoration pending: '..field[1] end
                    end
                end
            end
            external=nil
            return true
        end
        if external then return false, 'Input lease belongs to another owner' end
        self.active=false
        local ok, why = restore(saved)
        if ok then saved=nil end
        return ok, why
    end
    function self.status()
        return {owner=external and external.owner or (saved and 'lll' or nil),
            active=external and external.active or self.active,mode=external and external.mode or nil,
            pending_restore=external and external.closing or (saved ~= nil and not self.active),
            transport='engine-window', native_gate=false}
    end
    function self.sync(visible, focused)
        if not visible or not focused then
            if saved then return self.release() end
            return true
        end
        if external then return false, 'Input lease belongs to ' .. external.owner end
        if saved and not self.active then return false, 'Previous cursor restoration pending' end
        if not saved then
            saved=snapshot()
            if saved.focus ~= true then saved=nil; return false, 'Close the other input owner first' end
        end
        local ok, why = pcall(function()
            if window.mouse_focus() ~= false then assert(window.set_mouse_focus(false) ~= false) end
            if window.show_cursor() ~= true then assert(window.set_show_cursor(true) ~= false) end
            if window.clip_cursor() ~= true then assert(window.set_clip_cursor(true) ~= false) end
            assert(window.mouse_focus()==false and window.show_cursor()==true and window.clip_cursor()==true, 'Cursor acquisition readback failed')
        end)
        if not ok then self.release(); return false, tostring(why) end
        if not self.active then log('Engine window cursor lease acquired') end
        self.active=true
        return true
    end
    function self.shutdown()
        if external then local ok,why=self.release(external.token); if not ok then return false,why end end
        return self.release()
    end
    return self
end
return M
