local factory = dofile("src/live.lua")
local files = {
    ["mdl.cfg"] = "return {enabled={shared=true,enabled=true,paused=false},settings={enabled={level=3}}}",
    ["lll/shared.lua"] = "return {live_lua_api=1,on_disable=function()end}",
    ["mdl/shared/mod.lua"] = 'error("Lower priority copy must not run")',
    ["mdl/paused/mod.lua"] = 'error("Disabled MDL mod must not run")',
    ["mdl/enabled/mod.lua"] = [[
 return {on_enable=function(ctx)
  assert(ctx.api==2 and ctx.id=='enabled' and ctx.dir=='mdl/enabled')
  assert(ctx.settings.level==3 or ctx.settings.level==4)
  ctx.on_cleanup(function() table.insert(_G.cleanup_order,'first') end)
  ctx.on_cleanup(function() table.insert(_G.cleanup_order,'second') end)
  ctx.global('LLL_TEST_GLOBAL','owned');ctx.set('level',4)
 end,on_update=function(ctx,dt)assert(ctx.settings.level==4 and dt==.25);_G.mdl_tick=true end,
 on_disable=function(ctx) table.insert(_G.cleanup_order,'disable') end}
 ]],
}
local p = {
    roots = {
        { kind = "lll", path = "lll" },
        { kind = "mdl", path = "mdl" },
        {
            kind = "bingus",
            path = "bingus",
        },
    },
    mdl_config = "mdl.cfg",
    settings = "own_settings",
    read = function(path)
        return files[path]
    end,
    files = function(path)
        if path == "lll" then
            return { "shared.lua" }
        end
        return {}
    end,
    directories = function(path)
        if path == "mdl" then
            return { "paused", "shared", "enabled" }
        end
        return {}
    end,
    write = function(path, data)
        files[path] = data
        return true
    end,
}
local catalog = factory(p, function() end)
local names = catalog.scan()
assert(#names == 2 and catalog.entries["live/shared"].kind == "lll")
assert(not catalog.entries["live/paused"])
_G.cleanup_order = {}
_G.LLL_TEST_GLOBAL = "previous"
local record = catalog.load("live/enabled")
assert(record.mdl_context.settings.level == 3)
record.on_enable()
record.on_update(0.25)
assert(mdl_tick and LLL_TEST_GLOBAL == "owned")
assert(files["own_settings/mdl_enabled.lua"]:find("4", 1, true))
assert(files["mdl.cfg"]:find("level=3", 1, true), "MDL configuration was modified")
record.on_disable()
assert(LLL_TEST_GLOBAL == "previous")
assert(table.concat(cleanup_order, ",") == "disable,second,first")
record = catalog.load("live/enabled")
assert(record.mdl_context.settings.level == 4)
record.on_enable()
LLL_TEST_GLOBAL = "later-owner"
record.on_disable()
assert(LLL_TEST_GLOBAL == "later-owner", "Another owner global was overwritten")
_G.LLL_TEST_GLOBAL = nil
_G.cleanup_order = nil
_G.mdl_tick = nil
print(
    "PASS legacy roots, own-folder priority, saved MDL enabled state, API 2 callback context, private settings persistence, reverse cleanup and conditional global restoration"
)

local status_core = dofile(
    [[src/ui/core.lua]]
)
local status_api = status_core.new()
_G.DBFMCM = status_api
local status_loader = {
    order = { "mods/test/one", "live/two" },
    modules = { ["mods/test/one"] = "not installed", ["live/two"] = "loaded" },
    records = { ["live/two"] = {} },
}
local panel = dofile("src/status.lua")(
    status_loader,
    { count = 3, diagnostics = "files=10" },
    function() end
)
panel.refresh()
assert(status_api.mods.live_lua_loader and #status_api.mods.live_lua_loader.pages == 2)
assert(status_api.mods.live_lua_loader.pages[1].controls[2].label:find("Loaded: 1", 1, true))
status_loader.modules["live/two"] = "update failed: sample"
panel.refresh()
assert(status_api.mods.live_lua_loader.pages[2].controls[4].label:find("update failed", 1, true))
panel.close()
assert(not status_api.mods.live_lua_loader)
_G.DBFMCM = nil
print(
    "PASS status page registration, counts, live status refresh and cleanup against current MCM API"
)

files["lll/enabled/mod.lua"] = files["mdl/enabled/mod.lua"]:gsub("mdl/enabled", "lll/enabled")
p.directories = function(path)
    if path == "lll" then
        return { "enabled", "paused" }
    elseif path == "mdl" then
        return { "enabled", "paused", "shared" }
    end
    return {}
end
files["lll/paused/mod.lua"] = 'error("Migrated disabled MDL mod must not run")'
local migrated = factory(p, function() end)
local migrated_names = migrated.scan()
assert(
    #migrated_names == 2
        and migrated.entries["live/enabled"].kind == "lll"
        and not migrated.entries["live/paused"]
)
_G.cleanup_order = {}
_G.LLL_TEST_GLOBAL = "before-migration"
local migrated_record = migrated.load("live/enabled")
migrated_record.on_enable()
migrated_record.on_update(0.25)
migrated_record.on_disable()
assert(LLL_TEST_GLOBAL == "before-migration" and files["mdl.cfg"]:find("level=3", 1, true))
p.loader_config = "lll/LLL.cfg"
p.migrated_config = "lll/MDL.cfg"
files[p.migrated_config] = files["mdl.cfg"]
files["mdl.cfg"] = nil
local copied = factory(p, function() end)
assert(#copied.scan() == 2, "Copied MDL.cfg must preserve enabled state without original folder")
files[p.loader_config] = "return {enabled={enabled=false}}"
local own = factory(p, function() end)
own.scan()
assert(not own.entries["live/enabled"], "LLL config takes priority")
_G.cleanup_order = nil
_G.LLL_TEST_GLOBAL = nil
_G.mdl_tick = nil
print(
    "PASS MDL lifecycle migration to LLL: own-folder priority, context, settings, cleanup, disabled gate and copied configuration"
)
