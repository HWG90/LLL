-- The LuaJIT boot runtime's in-process Steam service. Same byte protocol and same caller contract as transport.lua,
-- answered by native/steam_inproc.c inside the runtime (package.preload 'hd2.lll_host') instead of the external
-- service's pipes: no launcher, no pipe, no helper process. nativeinfo() gives ui/font the two nativeinfo calls it
-- uses, for this process only, so no nativeinfo DLL loads either.
local M={}
local ffi,host
local function connect()
    if host then return host end
    ffi=require('ffi')
    local module=require('hd2.lll_host')
    assert(type(module)=='table' and module.version==1 and type(module.exchange)=='userdata'
        and type(module.read_memory)=='userdata' and type(module.module_base)=='userdata','LLL in-process service unavailable')
    host={exchange=ffi.cast('uint32_t(*)(const char *,uint32_t,const char **)',module.exchange),
        read_memory=ffi.cast('int(*)(uint64_t,void *,uint32_t)',module.read_memory),
        module_base=ffi.cast('uint64_t(*)(const char *)',module.module_base),reply=ffi.new('const char *[1]')}
    return host
end
function M.nativeinfo()
    local native=connect()
    return {module_base=function(name)
        if type(name)~='string' or #name==0 or name:find('%z') then return nil end
        local base=tonumber(native.module_base(name))
        return base~=0 and base or nil
    end,read_memory=function(address,count)
        if type(address)~='number' or type(count)~='number' or count<1 or count>16777216 or count~=math.floor(count) then return nil end
        local buffer=ffi.new('uint8_t[?]',count)
        if native.read_memory(address,buffer,count)~=1 then return nil end
        return ffi.string(buffer,count)
    end}
end
return setmetatable(M,{__call=function(_,config)
    local self={}
    assert(type(config)=='table','LLL service configuration required')
    local native=connect()
    local failure,listener
    local function exchange(bytes)
        local count=native.exchange(bytes,#bytes,native.reply)
        assert(count>=8 and count<=67108864,'Filesystem service stopped')
        local reply=ffi.string(native.reply[0],count)
        assert(reply:sub(1,4)==bytes:sub(1,4),'Stale filesystem response')
        return reply
    end
    function self.exchange(bytes)
        -- Caller mistakes happen before the failure boundary and do not close
        -- a healthy connection. A refused request cannot be retried.
        assert(type(bytes)=='string'and #bytes>=12 and #bytes<=67108864,'Invalid filesystem request')
        local a,b,c,d=bytes:byte(9,12)
        assert(a+b*256+c*65536+d*16777216<=#bytes-12,'Invalid filesystem request path length')
        if bytes:sub(1,4)=='\0\0\0\0'or bytes:sub(5,8)=='\0\0\0\0'then
            assert(bytes==string.rep('\0',12),'Invalid filesystem startup request')
        end
        assert(not failure,failure)
        local ok,reply=pcall(exchange,bytes)
        if not ok then
            failure='Filesystem service unavailable: '..tostring(reply)
            if listener then pcall(listener,failure) end
            error(failure,2)
        end
        return reply
    end
    function self.failure()return failure end
    function self.on_failure(fn)
        assert(type(fn)=='function','Transport failure callback required')
        listener=fn
        if failure then pcall(listener,failure) end
    end
    function self.close()
        failure=failure or 'Filesystem transport closed'
    end
    return self
end})
