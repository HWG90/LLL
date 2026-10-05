local snapshot = dofile("src/provenance.lua")
local loader = {
    order = { "live/demo", "archive", "live/disabled", "missing" },
    modules = {
        ["live/demo"] = "loaded",
        archive = "loaded",
        ["live/disabled"] = "disabled",
        missing = "not installed",
    },
    records = {},
    origins = { ["live/demo"] = { owner = "lll_live" }, archive = { owner = "lll_archive" } },
    refresh = function() end,
}
loader.compatibility = { implementation = "Live Lua Loader", modules = loader.modules }
local live = {
    catalog = {
        ["live/demo"] = { id = "demo", kind = "mdl", source_root = "MDL/Mods" },
        ["live/disabled"] = { id = "disabled", kind = "mdl", source_root = "MDL/Mods" },
        ["live/new"] = { id = "new", kind = "lll", source_root = "LLL/Mods" },
    },
}
local env = { CowboyBingusModLoader = loader.compatibility }
local function find(rows, name)
    for _, row in ipairs(rows) do
        if row.name == name then
            return row
        end
    end
end
live.catalog["live/demo"].metadata = { author = "  Nova  " }
loader.records.archive = { Author = "Guest Author" }
local rows = snapshot(loader, live, env)
assert(find(rows, "live/demo").author == "Nova")
assert(find(rows, "archive").author == "Guest Author")
assert(find(rows, "live/new").author == "Unknown author")
assert(
    #rows == 5
        and find(rows, "live/demo").owner == "lll_live"
        and find(rows, "live/demo").source:find("MDL/Mods", 1, true)
)
assert(find(rows, "live/disabled").state == "disabled" and not find(rows, "live/new").loaded)
assert(find(rows, "archive").owner == "lll_archive")
env.HD2ModLoader = { modules = { ["external_mdl"] = "loaded", [123] = "loaded" } }
env.CowboyBingusModLoader = { modules = { ["external_bingus"] = "loaded" } }
rows = snapshot(loader, live, env)
assert(
    #rows == 7
        and find(rows, "external_mdl").owner == "mdl"
        and find(rows, "external_bingus").owner == "bingus"
)
env.HD2ModLoader.modules["live/demo"] = "loaded"
rows = snapshot(loader, live, env)
assert(
    #rows == 7 and find(rows, "live/demo").owner == "unknown" and not find(rows, "live/demo").loaded
)
env.HD2ModLoader.modules["live/demo"] = nil
loader.order[#loader.order + 1] = "external_mdl"
loader.modules.external_mdl = "loaded"
loader.origins.external_mdl = { owner = "mdl", registry = env.HD2ModLoader }
env.HD2ModLoader = nil
assert(
    find(snapshot(loader, live, env), "external_mdl").state == "unverified previous loader report"
)
local shared = { modules = { shared_external = "loaded" } }
local aliased = snapshot(loader, live, { HD2ModLoader = shared, CowboyBingusModLoader = shared })
assert(
    find(aliased, "shared_external").owner == "unknown" and find(aliased, "shared_external").loaded
)
local old_mdl, old_bingus = HD2ModLoader, CowboyBingusModLoader
HD2ModLoader = { modules = { external_mdl = "loaded" } }
CowboyBingusModLoader = loader.compatibility
local core = dofile("src/ui/core.lua").new()
local controls = dofile("src/controls.lua")(loader, live, function() end)
controls.bind(core, "origins")
controls.refresh()
local spec = core.mods.lll_management
assert(spec and #spec.categories >= 3)
for _, control in ipairs(spec.pages[1].controls) do
    assert(control.id ~= "open_manager", "Redundant manager button in own menu")
end
assert(loader.provenance_snapshot == controls.provenance_snapshot)
assert(type(loader.provenance_snapshot()[1].loaded) == "boolean")
local ids = {}
for _, page in ipairs(spec.pages) do
    assert(not ids[page.id])
    ids[page.id] = true
end
local external_id
for _, page in ipairs(spec.pages) do
    if page.name:find("External Mdl", 1, true) then
        external_id = page.id
    end
end
assert(external_id and controls.provenance_summary():find("Loaded: 3", 1, true))
HD2ModLoader.modules.external_mdl = "disabled"
controls.refresh()
spec = core.mods.lll_management
local saw
for _, page in ipairs(spec.pages) do
    if page.id == external_id then
        saw = page.name:find("[Disabled]", 1, true)
    end
end
assert(saw)
core.author_navigation = true
HD2ModLoader.modules.external_mdl = "loaded"
CowboyBingusModLoader = { modules = { external_bingus = "loaded" } }
controls.refresh()
local menu = dofile("src/ui/menu.lua").new(core)
assert(#menu.sidebar() > #spec.pages)
menu.visible = true
assert(#menu.compose(1920, 1080) > 0)
local preview = assert(io.open("tests/tmp/grouping-preview.txt", "w"))
preview:write(
    "Illustrative offline fixture; not a live game capture.\n"
        .. controls.provenance_summary()
        .. "\n"
)
for _, node in ipairs(menu.sidebar()) do
    local title = node.kind == "mod" and node.mod.name
        or node.kind == "category" and node.category.name
        or node.page.name
    preview:write(string.rep("  ", node.depth) .. title .. "\n")
end
preview:close()
local author_ids = {}
for _, category in ipairs(core.mods.lll_management.categories) do
    if category.parent then
        assert(category.parent:find("source_", 1, true) == 1)
        author_ids[category.parent .. "/" .. category.name] = category.id
    end
end
assert(author_ids["source_lll_live/Nova"] and author_ids["source_lll_archive/Guest Author"])
assert(author_ids["source_lll_live/Unknown author"])
controls.refresh()
for _, category in ipairs(core.mods.lll_management.categories) do
    if category.parent then assert(author_ids[category.parent .. "/" .. category.name] == category.id) end
end
local second = dofile("src/ui/core.lua").new()
controls.bind(second, "origins_mcm")
controls.refresh()
for index, page in ipairs(core.mods.lll_management.pages) do
    assert(second.mods.lll_management.pages[index].id == page.id)
end
menu.notice = string.rep("Very long status message ", 120)
menu.sidebar_width = 650
for _, dimensions in ipairs({{1920,1080},{640,360}}) do
    for _, command in ipairs(menu.compose(dimensions[1], dimensions[2])) do
        if command.type == "text" and command.text_width then
            assert(command.x + command.text_width <= dimensions[1] + 0.01)
            local glyphs = 0
            for _ in command.text:gmatch("[%z\1-\127\194-\244][\128-\191]*") do glyphs = glyphs + 1 end
            assert(glyphs * command.size * 0.62 <= command.text_width + 0.01)
            assert(not command.text:find("\n", 1, true))
        end
    end
end
print("PASS source/author hierarchy, missing metadata, stable shared page/category IDs and bounded narrow-screen text")
controls.close()
HD2ModLoader = old_mdl
CowboyBingusModLoader = old_bingus
print(
    "PASS runtime/source separation, MDL folder without MDL owner, compatibility alias exclusion, external registries, conflicts, deduplication, lost owner, stable rows and grouped sidebar compose"
)
