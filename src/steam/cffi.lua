-- Optional native module. Normal package.loadlib only; failures leave LLL usable.
local M={}
function M.open(config)
    if not config then return {available=false,reason='not configured'} end
    local path=config.path
    if type(path)~='string' or #path==0 or #path>32760 or path:find('%z') then
        return {available=false,reason='invalid cffi module path'}
    end
    if type(package)~='table' or type(package.loadlib)~='function' or type(package.loaded)~='table' then
        return {available=false,reason='package.loadlib unavailable'}
    end
    if package.loaded.cffi~=nil then return {available=false,reason='cffi already registered'} end
    local ok,entry,why=pcall(package.loadlib,path,'luaopen_hd2_cffi')
    if not ok then return {available=false,reason=tostring(entry)} end
    if type(entry)~='function' then return {available=false,reason=tostring(why or 'native loader refused cffi')} end
    local success,module=pcall(entry)
    if not success then return {available=false,reason=tostring(module)} end
    if type(module)~='table' then return {available=false,reason='native bootstrap did not return a validated module'} end
    for _,name in ipairs({'cdef','load','typeof','new','cast','tonumber'}) do
        if type(module[name])~='function' then return {available=false,reason='incomplete cffi module: '..name} end
    end
    package.loaded.cffi=module
    return {available=true,module_name='cffi',legacy_ffi_alias=false}
end
return M
