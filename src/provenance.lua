-- Runtime ownership and discovery location are separate facts.
return function(loader, live, environment)
    environment = environment or _G
    local order, seen, rows = {}, {}, {}
    local function include(name)
        if type(name) == "string" and not seen[name] then
            seen[name] = true
            order[#order + 1] = name
        end
    end
    for _, name in ipairs(loader.order or {}) do
        include(name)
    end
    local registries = {}
    for _, item in ipairs({
        { "mdl", environment.HD2ModLoader },
        { "bingus", environment.CowboyBingusModLoader },
    }) do
        local registry = item[2]
        if
            type(registry) == "table"
            and registry ~= loader
            and registry ~= loader.compatibility
            and registry.modules ~= loader.modules
            and registry.implementation ~= "Live Lua Loader"
            and type(registry.modules) == "table"
        then
            registries[item[1]] = registry
        end
    end
    if registries.mdl and registries.mdl == registries.bingus then
        registries = { unknown = registries.mdl }
    end
    local extra = {}
    for name in pairs(live.catalog or {}) do
        if type(name) == "string" then
            extra[#extra + 1] = name
        end
    end
    for _, registry in pairs(registries) do
        for name in pairs(registry.modules) do
            if type(name) == "string" then
                extra[#extra + 1] = name
            end
        end
    end
    table.sort(extra)
    for _, name in ipairs(extra) do
        include(name)
    end
    for _, name in ipairs(order) do
        local entry = live.catalog[name]
        local owned = loader.origins and loader.origins[name]
        local reports = {}
        for kind, registry in pairs(registries) do
            local status = registry.modules[name]
            if type(status) == "string" then
                reports[#reports + 1] = { kind = kind, status = status, registry = registry }
            end
        end
        local owner, state = "unknown", loader.modules[name] or "discovered"
        local own = owned and (owned.owner == "lll_live" or owned.owner == "lll_archive")
        local active_reports = {}
        for _, report in ipairs(reports) do
            if report.status == "loaded" or report.status == "loading" then
                active_reports[#active_reports + 1] = report
            end
        end
        if
            #active_reports > 1
            or (own and (state == "loaded" or state == "loading") and #active_reports > 0)
        then
            state = "conflicting loader reports"
        elseif #active_reports == 1 then
            owner, state = active_reports[1].kind, active_reports[1].status
        elseif own then
            owner = owned.owner
        elseif owned and owned.registry then
            if
                registries[owned.owner] ~= nil
                and type(registries[owned.owner].modules[name]) == "string"
            then
                owner, state = owned.owner, registries[owned.owner].modules[name]
            else
                state = "unverified previous loader report"
            end
        elseif #reports == 1 then
            owner, state = reports[1].kind, reports[1].status
        elseif entry then
            owner = "lll_live"
            if state == "loaded" then
                owner, state = "unknown", "unverified loaded report"
            end
        end
        local source = entry
                and ((entry.kind or "unknown") .. " folder: " .. (entry.source_root or entry.dir or "unknown"))
            or (
                name:match("^mods/cowboybingus/") and "Bingus-compatible archive resource"
                or "Archive or unknown source"
            )
        local declared = loader.records and loader.records[name]
        local metadata = entry and entry.metadata
        local author = metadata and (metadata.author or metadata.Author)
        if not author and type(declared) == "table" then
            author = declared.author or declared.Author
        end
        if not author then
            for _, report in ipairs(reports) do
                local record = report.registry.records and report.registry.records[name]
                if type(record) == "table" then author = record.author or record.Author end
                if author then break end
            end
        end
        author = type(author) == "string" and author:gsub("^%s+", ""):gsub("%s+$", "") or nil
        if author == "" then author = nil end
        rows[#rows + 1] = {
            name = name,
            author = author or "Unknown author",
            owner = owner,
            state = state,
            loaded = state == "loaded",
            source = source,
        }
    end
    return rows
end
