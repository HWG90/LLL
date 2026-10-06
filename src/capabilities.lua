-- Read-only feature declaration; session success is reported by the corresponding service.
return function(features)
    local values={api=1,implementation='Live Lua Loader',revision='R25'}
    for key,value in pairs(features)do values[key]=value end
    return setmetatable({},{__index=values,__metatable=false,__newindex=function()error('Loader capabilities are read-only',2)end})
end
