-- Independent LLL mod consuming the public HD2SE facade, without engine access.
local extender, registered, finished, file
local ID = 'hd2se_consumer_example'
return {
    live_lua_api=1,
    on_enable=function()
        file=assert(LiveLuaLoader.compatibility.open_log('HD2SE_Consumer.log'))
        file:write('WAITING_FOR_PUBLIC_SDK\n');file:flush()
    end,
    on_update=function()
        if registered then return end
        local candidate=rawget(_G,'HD2SE')
        if not candidate or not candidate.ready then return end
        extender=candidate
        local ok,why=extender.load({{
            manifest={id=ID,version=1,api=1,capabilities={'world.read','entities.read'},services={world=1}},
            start=function(api)
                local world=assert(api.services.get('world',1))
                assert(api.tasks.defer('update',function()
                    local worlds,meta=world.list(32)
                    assert(worlds,meta)
                    local sample,units_count
                    for _,handle in ipairs(worlds)do
                        local units,info=world.units(handle,1)
                        assert(units,info)
                        if units[1] and not sample then
                            sample=assert(world.describe(units[1]));units_count=info.total
                        end
                        for _,entity in ipairs(units)do assert(world.release(entity))end
                        assert(world.release(handle))
                    end
                    assert(sample and sample.alive==true and type(sample.resource_id)=='string')
                    file:write('PUBLIC_CONSUMER_PASS worlds=',meta.total,' sample_world_units=',units_count,
                        ' resource_id=',sample.resource_id,' handle_type=table raw_engine_access=false\n');file:flush()
                    finished=true
                end))
                api.on_cleanup(function()
                    if file then file:write('CONSUMER_CLEANUP_ACK\n');file:flush()end
                    return true
                end)
            end,
        }})
        assert(ok,why);registered=true
    end,
    on_disable=function()
        if registered then
            local ok,why=extender.stop(ID)
            if not ok then return false,why end
            registered=false
        end
        if file then file:write('LLL_CONSUMER_DISABLED completed=',tostring(finished==true),'\n');file:close();file=nil end
        return true
    end,
}
