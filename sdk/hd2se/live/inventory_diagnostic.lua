-- Read-only native inventory shape/count evidence. No Unit getters or writes.
local file,next_scan,last
local function stats(value)
    if type(value)~='table' then return 'type='..type(value) end
    local count,largest,noninteger,duplicate=0,0,0,0
    local types,seen={},{}
    for key,ref in pairs(value)do
        count=count+1
        if type(key)=='number'and key%1==0 and key>=1 then largest=math.max(largest,key)else noninteger=noninteger+1 end
        local kind=type(ref);types[kind]=(types[kind]or 0)+1
        if seen[ref]then duplicate=duplicate+1 end;seen[ref]=true
    end
    local text={'count='..count,'largest='..largest,'noninteger='..noninteger,'duplicates='..duplicate,'metatable='..type(getmetatable(value))}
    for _,kind in ipairs({'userdata','table','number','string','boolean','cdata','function'})do if types[kind]then text[#text+1]=kind..'='..types[kind]end end
    return table.concat(text,' ')
end
return {
    live_lua_api=1,
    on_enable=function()
        file=assert(LiveLuaLoader.compatibility.open_log('HD2SE_InventoryDiagnostic.log'))
        next_scan,last=0,nil
    end,
    on_update=function(dt)
        -- Simulation dt can be zero while a photo/menu pause is active.
        local now=os.time();if now<next_scan then return end;next_scan=now+2
        local sr=stingray
        local ok,text=pcall(function()
            local worlds=sr.Application.worlds()
            local rows={'worlds '..stats(worlds)}
            if type(worlds)=='table'then
                local count=0
                for _,world in pairs(worlds)do
                    count=count+1;if count>64 then rows[#rows+1]='world_limit=64';break end
                    rows[#rows+1]='world='..count..' units '..stats(sr.World.units(world))
                    rows[#rows+1]='world='..count..' levels '..stats(sr.World.levels(world))
                end
            end
            return table.concat(rows,'\n')
        end)
        text=ok and text or(type(text)=='string'and text or'non_string_error')
        if text~=last then file:write(os.date('!%Y-%m-%dT%H:%M:%SZ'),'\n',text,'\n');file:flush();last=text end
    end,
    on_disable=function()
        if file then file:write('DIAGNOSTIC_CLEANUP_ACK\n');file:close();file=nil end
        return true
    end,
}
