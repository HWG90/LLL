-- Consumer example; the host must register a validated world provider first.
return {
    manifest = {
        id = "entity_inspector", version = 1, api = 1,
        capabilities = { "world.read", "entities.read" }, services = { world = 1 },
    },
    start = function(api)
        local world = assert(api.services.get("world", 1))
        local function inspect()
            local worlds, why = world.list(8)
            if not worlds then error(why) end
            for _, world_handle in ipairs(worlds) do
                local entities, reason = world.units(world_handle, 64)
                if entities then
                    for _, entity in ipairs(entities) do
                        local info = world.describe(entity)
                        if info then api.events.emit("entity_inspector.observed", info) end
                        world.release(entity)
                    end
                elseif reason then
                    api.events.emit("entity_inspector.unavailable", { reason = reason })
                end
                world.release(world_handle)
            end
        end
        assert(api.events.on("hd2se.world_changed", function() api.tasks.defer("update", inspect) end))
        assert(api.tasks.defer("update", inspect))
    end,
}
