-- One explicit asynchronous screenshot. This facade has no update/timer work.
local M={}
function M.new(platform)
    local directory=assert(platform.screenshot_directory):gsub('\\','/'):gsub('/+$','')
    local session=assert(platform.screenshot_session)
    assert(type(session)=='string'and session:match('^[a-z0-9_]+$')and #session<=96)
    local self={version=1,output_directory=directory}
    local values={async=true,game_window=true,format='png',color_space='sdr',max_jobs=1}
    self.capabilities=setmetatable({},{__index=values,__metatable=false,
        __newindex=function()error('Screenshot capabilities are read-only',2)end})
    local serial,issued,current,closing=0,nil,nil,false
    local states={pending=true,succeeded=true,failed=true,cancelled=true}
    local function text(value,limit)
        return type(value)=='string'and #value>0 and #value<=limit and not value:find('%c')
    end
    local function canonical(path)return path:gsub('\\','/'):lower()end
    local function output(path)
        if not text(path,32760)then return false end
        local normalized=path:gsub('\\','/')
        if normalized:sub(1,#directory+1):lower()~=directory:lower()..'/'then return false end
        local name=normalized:sub(#directory+2)
        if #name>128 or name:find('..',1,true)
            or not name:match('^[A-Za-z0-9_%-][A-Za-z0-9_. %-]*%.[Pp][Nn][Gg]$')then return false end
        local stem=name:match('^([^.]+)'):upper()
        if stem:match('[ .]$')then return false end
        return stem~='CON'and stem~='PRN'and stem~='AUX'and stem~='NUL'
            and not stem:match('^COM[0-9]$')and not stem:match('^LPT[0-9]$')
    end
    local function record()
        local r=current
        return {job_token=r.job_token,output_token=r.output_token,output_path=r.output_path,
            state=r.state,reason=r.reason,width=r.width,height=r.height,elapsed_ms=r.elapsed_ms,
            uncertain=r.uncertain==true,cancel_requested=r.cancel_requested==true}
    end
    local function owned(job,output_token)
        return current and current.job_token==job and current.output_token==output_token
    end
    local function clock()
        local ok,value=pcall(platform.now)
        if ok and type(value)=='number'and value==value and value>=0 and value<math.huge then return value end
    end
    local function uncertain(why)
        current.uncertain=true
        current.reason='Capture acknowledgement unavailable: '..tostring(why):sub(1,200)
        return record()
    end
    local function consume(reply)
        if type(reply)~='table'or not states[reply.state]or not text(reply.id,32)
            or #reply.id~=32 or not reply.id:match('^[0-9a-f]+$')
            or not text(reply.output_path,32760)or canonical(reply.output_path)~=canonical(current.output_path)
            or(current.id and current.id~=reply.id)then
            return uncertain('Invalid backend identity')
        end
        for _,key in ipairs({'error','width','height','elapsed_ms'})do
            local n=reply[key]
            if type(n)~='number'or n<0 or n>=4294967296 or n%1~=0 then
                return uncertain('Invalid backend metrics')
            end
        end
        if reply.state=='succeeded'and(reply.error~=0 or reply.width==0 or reply.height==0
            or reply.width>16384 or reply.height>16384 or reply.width*reply.height>67108864)then
            return uncertain('Invalid success dimensions')
        end
        current.id,current.state=reply.id,reply.state
        current.width,current.height,current.elapsed_ms=reply.width,reply.height,reply.elapsed_ms
        current.uncertain=false
        current.reason=reply.error~=0 and string.format('Screenshot error 0x%08x',reply.error)or nil
        return record()
    end
    function self.new_job_token()
        if closing then return nil,'Screenshot service is closing'end
        if current and current.state=='pending'then return nil,'Screenshot already active or unconfirmed'end
        if serial>=4294967295 then return nil,'Screenshot token counter exhausted'end
        serial=serial+1;issued='lll-shot:'..session..':'..string.format('%.0f',serial)
        return issued
    end
    function self.request(intent)
        if closing then return nil,'Screenshot service is closing'end
        if current and current.state=='pending'then return nil,'Screenshot already active or unconfirmed'end
        if type(intent)~='table'or intent.job_token~=issued or not issued
            or not text(intent.output_token,256)or not output(intent.output_path)then
            return nil,'Latest unused job token and safe output PNG path required'
        end
        local now=clock();if not now then return nil,'Application clock unavailable'end
        local pending={job_token=intent.job_token,output_token=intent.output_token,
            output_path=intent.output_path,state='pending',next_poll=now+.1}
        issued=nil
        local previous=current;current=pending
        local ok,reply,why=pcall(platform.screenshot_request,pending.output_path)
        if not ok then return uncertain(reply)end
        if reply==nil or reply==false then current=previous;return nil,why or 'Screenshot rejected'end
        return consume(reply)
    end
    function self.status(job,output_token)
        if not owned(job,output_token)then return nil,'Screenshot identity is stale or not owned'end
        if current.state~='pending'or not current.id then return record()end
        local now=clock();if not now then return uncertain('Application clock unavailable')end
        if now<current.next_poll then return record()end
        current.next_poll=now+.1
        local ok,reply,why=pcall(platform.screenshot_status,current.id)
        if not ok or not reply then return uncertain(ok and why or reply)end
        return consume(reply)
    end
    function self.cancel(job,output_token)
        if not owned(job,output_token)then return false,nil,'Screenshot identity is stale or not owned'end
        if current.state~='pending'then return true,record()end
        if not current.id then return false,record()end
        local reply
        if current.cancel_ack then
            reply=self.status(job,output_token)
        else
            local now=clock()
            if current.cancel_requested and now and now<current.next_poll then return false,record()end
            current.cancel_requested=true
            local ok,value,why=pcall(platform.screenshot_cancel,current.id)
            if now then current.next_poll=now+.1 end
            if not ok or not value then return false,uncertain(ok and why or value)end
            reply=consume(value)
            current.cancel_ack=not reply.uncertain
        end
        return reply.state~='pending',reply
    end
    local driver={}
    function driver.close()
        closing=true;issued=nil
        if not current or current.state~='pending'then return true end
        local done=self.cancel(current.job_token,current.output_token)
        return done,not done and 'Screenshot worker retirement pending'or nil
    end
    return self,driver
end
return M
