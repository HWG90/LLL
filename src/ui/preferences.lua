-- Loader-owned manager preferences, shared by each frontend registration.
local M={}
M.defaults={menu_toggle_key=119,apply_key=9,focus_key=117,ui_scale=1,font_scale=1}
function M.get(loader)
    local saved=loader.get_loader_option and loader.get_loader_option("manager_ui") or {}
    if type(saved)~="table" then saved={} end
    local result={}
    for key,default in pairs(M.defaults) do result[key]=type(saved[key])=="number" and saved[key]==saved[key] and math.abs(saved[key])<math.huge and saved[key] or default end
    if result.menu_toggle_key%1~=0 or result.menu_toggle_key<7 or result.menu_toggle_key>255 or result.menu_toggle_key==27 or (result.menu_toggle_key>=16 and result.menu_toggle_key<=18) then result.menu_toggle_key=119 end
    for _,key in ipairs({"apply_key","focus_key"}) do
        local value=result[key]
        if value%1~=0 or value<7 or value>255 or value==27 or (value>=16 and value<=18) then result[key]=M.defaults[key] end
    end
    if result.apply_key==result.menu_toggle_key or result.focus_key==result.menu_toggle_key or result.apply_key==result.focus_key then result.apply_key,result.focus_key=9,117 end
    result.ui_scale=math.max(.75,math.min(1.5,result.ui_scale))
    result.font_scale=math.max(.8,math.min(1.3,result.font_scale))
    return result
end
function M.set(loader,key,value)
    if not M.defaults[key] then return false,"Unknown manager preference" end
    if type(value)~="number" or value~=value then return false,"Numeric manager preference required" end
    if (key=="menu_toggle_key" or key=="apply_key" or key=="focus_key") and (value%1~=0 or value<7 or value>255 or value==27 or (value>=16 and value<=18)) then return false,"Choose a non-mouse key other than Escape or a modifier" end
    if key=="ui_scale" and (value<.75 or value>1.5) or key=="font_scale" and (value<.8 or value>1.3) then return false,"Scale outside supported range" end
    if not loader.save_loader_option then return false,"Loader preference storage unavailable" end
    local values=M.get(loader)
    if key=="menu_toggle_key" or key=="apply_key" or key=="focus_key" then
        for _,other in ipairs({"menu_toggle_key","apply_key","focus_key"}) do if other~=key and values[other]==value then return false,"This key is already bound to another manager action" end end
    end
    values[key]=value
    local ok,why=loader.save_loader_option("manager_ui",values)
    if not ok then return false,why end
    if loader.manager_preferences_changed then loader.manager_preferences_changed(values) end
    if loader.changed then loader.changed() end
    return true
end
function M.page(loader)
    local values=M.get(loader)
    local controls={{type="section",label="MANAGER APPEARANCE"}}
    for _,item in ipairs({
        {"menu_toggle_key","Open / close",type="keybind"},
        {"apply_key","Confirm / Apply",type="keybind"},
        {"focus_key","Switch focus",type="keybind"},
        {"ui_scale","UI scale",min=.75,max=1.5,step=.05},
        {"font_scale","Font size",min=.8,max=1.3,step=.05},
    }) do
        local key=item[1]
        controls[#controls+1]={id="manager_"..key,label=item[2],type=item.type or "slider",default=M.defaults[key],min=item.min,max=item.max,step=item.step,
            disabled=not loader.save_loader_option,
            description="Saved in LLL.cfg; shared by the independent manager and MCM registration.",
            validate=function(value)local ok,why=M.set(loader,key,value);assert(ok,why);return true end}
    end
    controls[#controls+1]={id="manager_metadata_editing",type="toggle",label="Allow metadata edits",default=not loader.get_loader_option or loader.get_loader_option("metadata_editing")~=false,disabled=not loader.save_loader_option,
        description="Controls local Name, Author and Description overrides. Runtime owner and resource identity stay fixed.",
        validate=function(value)local ok,why=loader.save_loader_option("metadata_editing",value);assert(ok,why);return true end,
        on_change=function()if loader.changed then loader.changed() end end}
    controls[#controls+1]={id="manager_reset_window",type="button",label="Window placement",button_label="Reset window",disabled=not loader.save_loader_option,
        on_activate=function()
            local ok,why=loader.save_loader_option("manager_window",{});assert(ok,why)
            if loader.reset_manager_window then loader.reset_manager_window() end
            return "Window placement reset"
        end}
    return {id="manager_settings",name="Manager settings",dynamic=true,controls=controls}
end
return M
