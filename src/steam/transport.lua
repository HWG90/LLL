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
    if not incoming then pcall(outgoing.close,outgoing);error('Filesystem response pipe unavailable: '..tostring(why)) end
    incoming:setvbuf('no')
    local failure,listener
    local function close_streams()
        -- Closing one broken stream must not prevent closing the other.
        local writing,reading=outgoing,incoming
        outgoing,incoming=nil,nil
        if writing then pcall(writing.close,writing) end
        if reading then pcall(reading.close,reading) end
    end
    local function exchange(bytes)
        assert(outgoing:write(integer(#bytes),bytes));assert(outgoing:flush())
        local header=assert(incoming:read(4),'Filesystem service disconnected')
        assert(#header==4,'Truncated filesystem response header')
        local a,b,c,d=header:byte(1,4)
        local count=a+b*256+c*65536+d*16777216
        assert(count>=8 and count<=67108864,'Invalid filesystem response length')
        local reply=assert(incoming:read(count),'Filesystem response unavailable')
        assert(#reply==count,'Truncated filesystem response')
        assert(reply:sub(1,4)==bytes:sub(1,4),'Stale filesystem response')
        return reply
    end
    function self.exchange(bytes)
        -- Caller mistakes happen before the failure boundary and do not close
        -- a healthy connection. Framing/stream failures cannot be retried.
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
            close_streams()
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
        close_streams()
    end
    return self
end
