local core = dofile("src/ui/core.lua")
local factory = dofile("src/live.lua")
local manager = dofile("src/manager.lua")
local files = {
    ["config"] = "return {enabled={paused=false}}",
    ["mods/paused.lua"] = "return {live_lua_api=1,on_enable=function()_G.starts=(_G.starts or 0)+1 end,on_disable=function()_G.stops=(_G.stops or 0)+1 end}",
    ["mods/active.lua"] = "return {live_lua_api=1,on_enable=function()end,on_disable=function()end}",
}
local save_fails = false
local listing = { "paused.lua", "active.lua" }
local platform = {
    roots = { { kind = "lll", path = "mods" } },
    loader_config = "config",
    settings = "settings",
    files = function()
        return listing
    end,
    read = function(p)
        return files[p]
    end,
    write = function(p, v)
        if save_fails then
            return false
        end
        files[p] = v
        return true
    end,
}
local live = factory(platform, function() end)
local initial = live.scan()
assert(#initial == 1 and live.catalog["live/paused"] and not live.entries["live/paused"])
_G.CowboyBingusModLoader = nil
_G.LiveLuaLoader = nil
local m = manager({
    available = function(name)
        return live.catalog[name] ~= nil or name == "archive"
    end,
    require = function(name)
        if name == "archive" then
            return true
        end
        return live.load(name)
    end,
    preflight = live.preflight,
    can_retry = function(name)
        return live.catalog[name] ~= nil
    end,
    save_enabled = live.set_enabled,
    evict = function() end,
    report = function() end,
}, initial)
m.auto_reload = live.auto_reload
m.set_auto_reload = live.set_auto_reload
m.add("live/paused", false)
m.add("archive")
m.refresh = function()
    live.scan()
    for name in pairs(live.catalog) do
        if not m.modules[name] then
            m.add(name, live.enabled(name))
        end
    end
    return #m.order
end
local opens = 0
m.open_manager = function()
    opens = opens + 1
end
local controls = dofile("src/controls.lua")(m, live, function() end)
local standalone = core.new()
local native = core.new()
controls.bind(standalone)
controls.bind(native)
controls.refresh()
local h1 = standalone.mods.lll_management.handle
local h2 = native.mods.lll_management.handle
local key = "entry_2_enabled"
assert(h1.get(key) == false and h2.get(key) == false)
assert(h1.set(key, true))
assert(
    m.modules["live/paused"] == "loaded"
        and h2.get(key) == true
        and starts == 1
        and live.enabled("live/paused")
)
assert(h2.set(key, false))
assert(
    m.modules["live/paused"] == "disabled"
        and h1.get(key) == false
        and stops == 1
        and not live.enabled("live/paused")
)
local restored = factory(platform, function() end)
restored.scan()
assert(not restored.enabled("live/paused"), "disabled selection survives a fresh catalog")
assert(
    not m.set_enabled("archive", false) and m.modules.archive == "loaded",
    "archive addons without lifecycle cannot be falsely disabled"
)
assert(h1.get("auto_reload") == true and h2.get("auto_reload") == true)
assert(h1.set("auto_reload", false) and h2.get("auto_reload") == false)
assert(
    factory(platform, function() end).auto_reload() == false,
    "auto-reload preference persists across a new loader instance"
)
save_fails = true
assert(
    not live.set_auto_reload(true) and live.auto_reload() == false,
    "failed save restores preference"
)
save_fails = false
assert(h2.set("auto_reload", true) and h1.get("auto_reload") == true)
save_fails = true
assert(not m.set_enabled("live/paused", true))
assert(
    m.modules["live/paused"] == "disabled" and not live.enabled("live/paused"),
    "persistence failure rolls enable back"
)
save_fails = false
assert(m.set_enabled("live/paused", true))
assert(h2.activate("entry_2_reload"))
assert(m.modules["live/paused"] == "loaded" and starts == 4, "reload routes through cleanup")
listing[#listing + 1] = "new.lua"
files["mods/new.lua"] = "return {live_lua_api=1,on_enable=function()end,on_disable=function()end}"
assert(h1.activate("refresh"))
h1 = standalone.mods.lll_management.handle
h2 = native.mods.lll_management.handle
assert(
    m.modules["live/new"] == "loaded" and #native.mods.lll_management.pages == 5,
    "Refresh adds new files to both menus"
)
assert(h2.get(key) == true, "Refresh preserves and synchronizes committed state")
assert(h2.activate("open_manager") and opens == 1)
local author_surface = core.new()
controls.bind(author_surface, "authors")
controls.refresh()
assert(
    author_surface.mods.lll_management.handle.set(key, false)
        and h1.get(key) == false
        and h2.get(key) == false,
    "author page changes reach both existing frontends"
)
assert(
    h2.set(key, true) and author_surface.mods.lll_management.handle.get(key) == true,
    "other frontend changes reach author pages"
)
controls.follow(native)
controls.refresh()
assert(
    #native.mods.lll_management.pages > 1 and native.mods.lll_management.pages[1].name == "Overview"
)
h2 = native.mods.lll_management.handle
local surface_calls = 0
native.surface = function(handle)
    surface_calls = surface_calls + 1
    return {
        get = handle.get,
        preview = handle.preview,
        set = handle.edit,
        activate = handle.queue,
        confirm = handle.confirm,
        discard = handle.discard,
    }
end
local shared = controls.primary()
assert(shared.handle.get(key) == h2.get(key) and surface_calls == 1)
assert(
    shared.handle.edit(key, false)
        and native.mods.lll_management.handle.get(key) == false
        and h1.get(key) == false
)
shared = controls.primary()
assert(shared.handle.edit(key, true))
files["mods/paused.lua"] = "invalid lua"
assert(
    not m.reload("live/paused") and m.modules["live/paused"] == "loaded",
    "compile failure preserves the live instance"
)
controls.close()
assert(not standalone.mods.lll_management and not native.mods.lll_management)
m.shutdown()
_G.CowboyBingusModLoader = nil
_G.LiveLuaLoader = nil
print(
    "PASS manager: two-way controls, persisted enable/disable, Refresh, opening button, cleanup reload, save rollback, syntax rollback and archive limits"
)

local tree_loader = {
    order = {
        "mods/cowboybingus/vanilla_plus_megapack",
        "mods/cowboybingus/better_stratagem_bounce",
        "mods/other_author/better_stratagem_bounce",
        "live/demo",
    },
    modules = {},
    refresh = function() end,
}
for _, name in ipairs(tree_loader.order) do
    tree_loader.modules[name] = "loaded"
end
local tree_live = {
    catalog = {
        ["live/demo"] = { id = "demo", source_root = "C:/LLL/Mods", dir = "C:/LLL/Mods/demo" },
    },
}
local tree = dofile("src/controls.lua")(tree_loader, tree_live, function() end)
local tree_api = core.new(nil, function() end)
tree.bind(tree_api)
tree.refresh()
local mod = tree_api.mods.lll_management
assert(
    #mod.categories == 3
        and mod.categories[1].name == "cowboybingus"
        and mod.categories[2].name == "other_author"
        and mod.categories[3].name == "Mods"
)
assert(
    mod.pages[2].name == "Vanilla Plus Megapack" and mod.pages[3].name == "Better Stratagem Bounce"
)
assert(
    mod.pages[3].name == mod.pages[4].name
        and mod.pages[3].category ~= mod.pages[4].category
        and mod.pages[3].id ~= mod.pages[4].id,
    "duplicate child labels preserve separate identities"
)
local menu = dofile("src/ui/menu.lua").new(tree_api)
local rows = menu.navigation(mod)
local parents = 0
for _, row in ipairs(rows) do
    if row.kind == "category" then
        parents = parents + 1
    end
end
assert(parents == 3, "real tree navigation contains expandable categories")
local category = mod.pages[2].category
tree_loader.order[#tree_loader.order + 1] = "mods/cowboybingus/hellpod_steering_unlocked"
tree_loader.modules[tree_loader.order[#tree_loader.order]] = "loaded"
tree.refresh()
mod = tree_api.mods.lll_management
assert(
    mod.pages[2].category == category
        and mod.pages[#mod.pages].category == category
        and #mod.categories == 3,
    "Refresh retains stable parent identity"
)
tree.close()
print(
    "PASS author-folder tree, readable children, duplicate names, distinct source paths and stable Refresh categories"
)

local metadata = dofile("src/metadata.lua")
_G.LLL_METADATA = metadata
local decoded = metadata.decode(
    [[{"Author":{"Name":"Declared Author"},"Name":"Readable Mod","options":[true,false,null],"text":"a\nb"}]]
)
assert(
    metadata.fields(decoded).author == "Declared Author"
        and metadata.fields(decoded).name == "Readable Mod"
)
assert(not pcall(metadata.decode, '{"Author":os.execute("bad")}'))
local info = metadata.read({
    read = function(path)
        if path == "dir/manifest.json" then
            return [[{"Author":"Manifest Author","Name":"Manifest Child"}]]
        end
    end,
}, "dir")
assert(info.author == "Manifest Author" and info.path == "dir/manifest.json")
tree_live.catalog["live/demo"].metadata = info
local enclosed_api = core.new(nil, function() end)
local closed = dofile("src/controls.lua")(tree_loader, tree_live, function() end)
closed.bind(enclosed_api, true)
closed.refresh()
assert(
    #enclosed_api.list() == 1
        and #enclosed_api.mods.lll_management.pages == 1
        and enclosed_api.mods.lll_management.pages[1].name == "Mods"
)
local grouped = enclosed_api.mods.lll_management
local manifest_group
for key, c in pairs(grouped.controls) do
    if c.label == "Manifest Author" then
        manifest_group = key
    end
end
assert(manifest_group and grouped.handle.activate(manifest_group))
grouped = enclosed_api.mods.lll_management
assert(grouped.controls.select_entry_4.label == "    Manifest Child")
assert(grouped.pages[1].controls[#grouped.pages[1].controls - 2].label:find("Loaded: 5", 1, true))
assert(grouped.handle.activate(manifest_group))
assert(
    not enclosed_api.mods.lll_management.controls.select_entry_4,
    "collapse removes children inside page"
)
closed.close()
_G.LLL_METADATA = nil
print(
    "PASS enclosed single Mods page, author metadata precedence, manifest safety, folder fallback, collapse and lifecycle counts"
)

local author_api = core.new()
local mirror = core.new()
local author_controls = dofile("src/controls.lua")(tree_loader, tree_live, function() end)
author_controls.bind(author_api, "authors")
author_controls.bind(mirror, true)
author_controls.refresh()
local authors = author_api.mods.lll_management
assert(#author_api.list() == 1 and #authors.categories == 0 and #authors.pages == 4)
assert(authors.pages[2].name == "cowboybingus" and authors.pages[3].name == "other_author")
assert(
    authors.controls.entry_1_enabled and authors.controls.entry_5_enabled,
    "all child controls retain stable IDs across author pages"
)
assert(#mirror.mods.lll_management.pages == 1, "MCM remains one Mods page")
author_api.author_navigation = true
author_api.loader_summary = author_controls.summary
local author_menu = dofile("src/ui/menu.lua").new(author_api)
assert(
    #author_menu.sidebar() == 5,
    "authors appear under the single LLL entry without extra expansion"
)
author_menu.visible = true
local commands = author_menu.compose(1920, 1080)
local summary = false
for _, command in ipairs(commands) do
    if command.text and command.text:find("Loaded: 5", 1, true) then
        summary = true
    end
end
assert(summary, "counts remain visible independently of selected author page")
author_controls.close()
print("PASS independent author pages, stable child IDs, one MCM Mods page and persistent counts")
