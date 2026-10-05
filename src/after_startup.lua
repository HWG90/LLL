-- One-shot callbacks after initial module startup, with bounded reentrant registration.
return function(status,report,record,health)
    local queue,accepted,next_index,ready,running,closed={},0,1,false,false,false
    local registering,current,refused
    local self={}
    local function drain()
        if running or closed then return end
        running=true
        while next_index<=#queue do
            local item=queue[next_index];queue[next_index]=false;next_index=next_index+1
            if not item.owner or (status(item.owner)=='loaded' and (not item.record or record(item.owner)==item.record)) then
                current=item.owner
                report("After startup","running "..(item.owner or "anonymous callback"))
                local mark
                if health then local ok,value=pcall(health.before);if ok then mark=value end end
                local ok,why=pcall(item.fn)
                if health and mark then pcall(health.after,item.owner or "after_startup",mark,"after_startup") end
                current=nil
                report("After startup","completed "..(item.owner or "anonymous callback"))
                if not ok then report(item.owner or 'after_startup','Callback failed: '..tostring(why)) end
            else report(item.owner,'After-startup callback skipped: module not loaded or ownership changed') end
        end
        running=false
    end
    function self.register(fn)
        if closed then return false,'Loader is shutting down' end
        if type(fn)~='function' then return false,'after_startup needs a function' end
        if accepted>=256 then if not refused then refused=true;report('After startup','callback limit (256) reached; later registrations refused')end;return false,'after_startup callback limit (256) reached' end
        accepted=accepted+1
        local owner=current or registering
        queue[#queue+1]={fn=fn,owner=owner,record=owner and record(owner)}
        if ready and not registering then drain() end
        return true
    end
    function self.begin(name)registering=name end
    function self.ending()registering=nil;if ready then drain() end end
    function self.finish()ready=true;drain() end
    function self.close()closed=true;queue={} end
    return self
end
