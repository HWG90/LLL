-- Retains SDK handles across real catalog/level changes and verifies rejection.
local M = {}
function M.new(host, log, transition)
    local api, world, retained_world, retained_entity, epoch, stopped
    local controller = {}
    local function inspect()
        local current = host:status().world_epoch
        if retained_world and epoch ~= current then
            local entities, world_reason = world.units(retained_world, 1)
            local info, entity_reason
            if retained_entity then info, entity_reason = world.describe(retained_entity) end
            local passed = entities == nil and world_reason == 'stale_handle'
                and (not retained_entity or (info == nil and entity_reason == 'stale_handle'))
            log('SCENE_STALE_HANDLES', {passed=passed,previous_epoch=epoch,epoch=current,
                reason=transition(),world_reason=world_reason,entity_reason=entity_reason})
            retained_world,retained_entity=nil,nil
            assert(passed, 'scene transition failed to revoke retained SDK handles')
        end
        if retained_world then return end
        local worlds, meta = world.list(32)
        assert(worlds, meta)
        local best, count = nil, -1
        for _, handle in ipairs(worlds) do
            local entities, inventory = world.units(handle, 1)
            if entities then
                if inventory.total > count then
                    if retained_entity then world.release(retained_entity) end
                    if best then world.release(best) end
                    best,count,retained_entity=handle,inventory.total,entities[1]
                else
                    for _, entity in ipairs(entities) do world.release(entity) end
                    world.release(handle)
                end
            else world.release(handle) end
        end
        retained_world,epoch=best,current
        log('SCENE_BASELINE',{epoch=epoch,worlds=meta.total,units=count,has_entity=retained_entity~=nil})
    end
    controller.definition={manifest={id='hd2se_scene_observer',version=1,api=1,
        capabilities={'world.read','entities.read'},services={world=1}},
        start=function(value)
            api,world,stopped=value,assert(value.services.get('world',1)),false
            api.on_cleanup(function() stopped=true;retained_world,retained_entity=nil,nil;return true end)
        end}
    function controller:step()
        if stopped then return end
        assert(api.tasks.defer('update',inspect))
    end
    return controller
end
return M
