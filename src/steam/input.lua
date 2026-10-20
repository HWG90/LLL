-- Documented Stingray controller API; ids are resolved once, closed UI reads one key.
local M = {}
local names = {[8]='backspace',[9]='tab',[13]='enter',[16]='left shift',[17]='left ctrl',[18]='left alt',
    [20]='caps lock',[27]='esc',[32]='space',[33]='page up',[34]='page down',[35]='end',[36]='home',
    [37]='left',[38]='up',[39]='right',[40]='down',[45]='insert',[46]='delete',
    [186]='semicolon',[187]='equal',[188]='comma',[189]='minus',[190]='period',[191]='slash',
    [192]='backtick',[219]='open bracket',[220]='backslash',[221]='close bracket',[222]='quote'}
for code=48,57 do names[code]=string.char(code) end
for code=65,90 do names[code]=string.char(code+32) end
for code=112,135 do names[code]='f' .. (code-111) end
function M.new(sr,platform)
    local self, ids, cache = {}, {}, {}
    local mouse_names = {[1]='left',[2]='right',[4]='middle',[5]='extra_1',[6]='extra_2'}
    local mouse_bits={[1]=1,[2]=2,[4]=4,[5]=8,[6]=16}
    local visible,leased,pointer,wheel_taken=false,false,nil,false
    local external=platform and type(platform.pointer_snapshot)=='function'
    local function snapshot()
        if not external or not visible then return end
        if not pointer then
            leased=true
            pointer=platform.pointer_snapshot()
        end
        return pointer
    end
    function self.visible(value)
        visible=value==true
        if not visible and leased then
            assert(platform.release_pointer(),'Cannot release pointer reader')
            leased=false
        end
        if not visible then pointer=nil end
    end
    function self.release()self.visible(false)end
    local function resolve(code)
        if ids[code] ~= nil then return ids[code] end
        local device, name = mouse_names[code] and sr.Mouse or sr.Keyboard, mouse_names[code] or names[code]
        local ok, id = false, nil
        if name then ok,id=pcall(device.button_id,name) end
        ids[code]=ok and type(id)=='number' and {device=device,id=id} or false
        return ids[code]
    end
    for code=1,255 do resolve(code) end
    local cursor_id = sr.Mouse.axis_id('cursor')
    local wheel_id = sr.Mouse.axis_id('wheel')
    function self.frame()
        for code in pairs(cache) do cache[code]=nil end
        pointer,wheel_taken=nil,false
    end
    function self.down(code)
        if cache[code] ~= nil then return cache[code] end
        if external and visible and mouse_bits[code] then
            local value=snapshot()
            cache[code]=value.valid and math.floor(value.buttons/mouse_bits[code])%2==1 or false
            return cache[code]
        end
        local binding=resolve(code)
        local value=binding and binding.device.button(binding.id)
        cache[code]=value==true or (type(value)=='number' and value>0.5) or false
        return cache[code]
    end
    function self.mouse()
        if external then
            local value=snapshot()
            if not value or not value.valid or value.width<=0 or value.height<=0 then return end
            local width,height=sr.Gui.resolution()
            return value.x*width/value.width,height-value.y*height/value.height
        end
        if cursor_id == nil then return end
        local value=sr.Mouse.axis(cursor_id)
        if value then return value.x,value.y end
    end
    function self.wheel()
        if external then
            if wheel_taken then return 0 end
            wheel_taken=true
            local value=snapshot()
            return value and value.valid and value.wheel or 0
        end
        if wheel_id == nil then return 0 end
        local value=sr.Mouse.axis(wheel_id)
        return value and value.y*120 or 0
    end
    return self
end
return M
