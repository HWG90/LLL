-- Standard Lua file streams over two local pipes. No in-game native extension.
return function(config)
    local self={}
    local function integer(value)
        return string.char(value%256,math.floor(value/256)%256,math.floor(value/65536)%256,math.floor(value/16777216)%256)
    end
    local prefix='\\\\.\\pipe\\' .. assert(config.pipe)
    local outgoing=io.open(prefix..'_request','wb')
    if not outgoing and config.launcher then
        local launcher=assert(io.popen(config.launcher,'r'),'Cannot start LLL filesystem service launcher')
        -- Wait only for the bounded startup parent. Reading to EOF could wait
        -- for a long-lived GUI child that inherited the output stream.
        launcher:close()
        outgoing=io.open(prefix..'_request','wb')
    end
    assert(outgoing,'LLL filesystem service unavailable after startup')
    outgoing:setvbuf('no')
    local incoming,why=io.open(prefix..'_response','rb')
    if not incoming then outgoing:close();error('Filesystem response pipe unavailable: '..tostring(why)) end
    incoming:setvbuf('no')
    function self.exchange(bytes)
        assert(#bytes<=67108864,'Filesystem request too large')
        assert(outgoing:write(integer(#bytes),bytes));assert(outgoing:flush())
        local header=assert(incoming:read(4),'Filesystem service disconnected')
        assert(#header==4,'Truncated filesystem response header')
        local a,b,c,d=header:byte(1,4)
        local count=a+b*256+c*65536+d*16777216
        assert(count>=8 and count<=67108864,'Invalid filesystem response length')
        local reply=assert(incoming:read(count),'Filesystem response unavailable')
        assert(#reply==count,'Truncated filesystem response')
        return reply
    end
    function self.close()outgoing:close();incoming:close()end
    return self
end
