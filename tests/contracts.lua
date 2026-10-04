local manager = dofile("src/manager.lua")
local calls = {}
local stops = 0
local loaded = {}
local fail_cleanup = false
local host = {
    open_log = function() end,
    report = function() end,
    available = function(name)
        if name == "lookup" then
            error("lookup")
        end
        return name ~= "missing"
    end,
    require = function(name)
        calls[#calls + 1] = name
        if name == "bad" then
            error("entry")
        end
        if name == "legacy" then
            return true
        end
        return {
            live_lua_api = 1,
            on_enable = function()
                loaded[name] = (loaded[name] or 0) + 1
            end,
            on_update = function(dt)
                if name == "framebad" then
                    error("frame")
                end
            end,
            on_disable = function()
                if fail_cleanup then
                    error("cleanup")
                end
                stops = stops + 1
            end,
        }
    end,
    evict = function() end,
}
_G.HD2ModLoader = { modules = { other = "loaded" } }
local m =
    manager(host, { "missing", "lookup", "bad", "legacy", "good", "good", "other", "framebad" })
assert(CowboyBingusModLoader.api == 1 and CowboyBingusModLoader.modules == m.modules)
assert(m.modules.good == "loaded" and loaded.good == 1)
assert(m.modules.missing == "not installed" and m.modules.other == "loaded")
assert(m.modules.bad:match("load failed") and m.modules.lookup:match("lookup failed"))
assert(not m.reload("legacy"))
assert(m.reload("good") and loaded.good == 2 and stops == 1)
m.frame(0.1)
assert(m.modules.framebad:match("update failed") and stops == 2)
fail_cleanup = true
assert(not m.reload("good"))
assert(loaded.good == 2)
assert(not pcall(manager, host, {}))
_G.LiveLuaLoader = nil
_G.CowboyBingusModLoader = nil
_G.HD2ModLoader = nil
local replacement_loader
local generation = 0
local cleanup_count = 0
local replacement_host = {
    available = function()
        return true
    end,
    report = function() end,
    preflight = function() end,
    evict = function() end,
    require = function()
        generation = generation + 1
        local own = generation
        return {
            live_lua_api = 1,
            on_enable = function() end,
            on_disable = function()
                cleanup_count = cleanup_count + 1
            end,
            on_update = function()
                if own == 1 then
                    assert(replacement_loader.reload("replacement"))
                    error("retired update failed")
                end
            end,
        }
    end,
}
replacement_loader = manager(replacement_host, { "replacement" })
replacement_loader.frame(0.1)
assert(
    generation == 2
        and cleanup_count == 1
        and replacement_loader.records.replacement
        and replacement_loader.modules.replacement == "loaded",
    "retired callback must preserve its active replacement"
)
replacement_loader.frame(0.1)
assert(cleanup_count == 1)
replacement_loader.shutdown()
assert(cleanup_count == 2)
_G.LiveLuaLoader = nil
_G.CowboyBingusModLoader = nil
print(
    "PASS retired update failure preserves replacement lifecycle record and does not double-clean"
)
local discover = dofile("src/discovery.lua")
local function read(path)
    local f = assert(io.open(path, "rb"))
    local d = f:read("*a")
    f:close()
    return d
end
local names, warnings = discover({
    data = "tests/tmp",
    files = function()
        return {
            "9ba626afa44a3aa3.patch_2",
            "9ba626afa44a3aa3.patch_10",
            "9ba626afa44a3aa3.patch_11",
            "9ba626afa44a3aa3.patch_12",
        }
    end,
    read = read,
})
assert(#names == 1 and names[1] == "mods/test/accepted", table.concat(names, ","))
assert(#warnings == 1)
assert(loadfile("dist/runtime.lua"))
assert(loadfile("src/platform.lua"))
local loaded_names = {}
_G.stingray = { Application = {
    can_get = function()
        return true
    end,
} }
local old_require = require
_G.require = function(name)
    if name == "ffi" or name == "bit" then
        return old_require(name)
    end
    loaded_names[#loaded_names + 1] = name
    return true
end
local frames = 0
_G.update = function()
    frames = frames + 1
    return "frame", nil, 3, nil
end
_G.shutdown = function()
    return "shutdown", nil
end
_G.live_source =
    "return {live_lua_api=1,on_enable=function() _G.enables=(_G.enables or 0)+1 end,on_disable=function() _G.disables=(_G.disables or 0)+1 end}"
local function pack(...)
    return { n = select("#", ...), ... }
end
local result = pack(assert(loadfile("tests/tmp/bootstrap.lua"))(17, nil, 29))
assert(stock_calls == 1 and result.n == 4 and result[1] == "stock" and result[3] == 42)
assert(#loaded_names == 14 and LiveLuaLoader.modules[loaded_names[1]] == "loaded")
assert(enables == 1 and LiveLuaLoader.modules["live/demo"] == "loaded")
result = pack(update(0.1))
assert(frames == 1 and result.n == 4 and result[1] == "frame" and result[3] == 3)
assert(LiveLuaLoader.auto_reload() == true)
assert(LiveLuaLoader.set_auto_reload(false))
live_source = live_source .. " -- edit"
update(0.6)
update(0.6)
assert(enables == 1 and disables == nil, "off must preserve active instance")
assert(LiveLuaLoader.set_auto_reload(true))
update(0.6)
assert(enables == 1 and disables == nil, "first observation must debounce")
live_source = live_source .. " -- rapid write"
update(0.6)
assert(enables == 1 and disables == nil, "new write resets stability check")
update(0.6)
assert(enables == 2 and disables == 1)
live_source = "invalid Lua syntax!"
update(0.6)
assert(enables == 2 and disables == 1, "Syntax error unloaded the working mod")
new_live_source = "invalid new Lua syntax!"
update(0.6)
assert(LiveLuaLoader.modules["live/new"]:match("load failed"))
new_live_source =
    "return {live_lua_api=1,on_enable=function()_G.new_enabled=true end,on_disable=function()_G.new_enabled=false end}"
update(0.6)
update(0.6)
assert(
    new_enabled and LiveLuaLoader.modules["live/new"] == "loaded",
    "Corrected new script did not dynamically load"
)
live_source =
    'return {live_lua_api=1,on_enable=function()error("enable fail")end,on_disable=function()end}'
update(0.6)
update(0.6)
assert(LiveLuaLoader.modules["live/demo"]:match("enable failed"))
live_source =
    "return {live_lua_api=1,on_enable=function()_G.recovered=true end,on_disable=function()end}"
update(0.6)
update(0.6)
assert(recovered and LiveLuaLoader.modules["live/demo"] == "loaded")
result = pack(shutdown())
assert(result.n == 2 and result[1] == "shutdown")
_G.require = old_require
print(
    "PASS complete synthetic bootstrap: original startup exactly once, nil tuples, legacy startup without Bingus, live edit reload, syntax failure preserves active mod, new-script error recovery, enable-failure edit recovery, update/shutdown forwarding"
)
print(
    "PASS API 1, registry deduplication, lookup/load/frame failure isolation, cleanup-gated reload, conflict guard, numeric priority, unmarked shadow, hash validation, malformed archive, runtime syntax"
)

local original_tostring = tostring
_G.tostring = function(value)
    if type(value) == "cdata" then
        return "opaque engine value"
    end
    return original_tostring(value)
end
local safe_names = dofile("src/discovery.lua")({
    data = "tests/tmp",
    files = function()
        return { "9ba626afa44a3aa3.patch_2" }
    end,
    read = function(path)
        local f = assert(io.open(path, "rb"))
        local s = f:read("*a")
        f:close()
        return s
    end,
})
_G.tostring = original_tostring
assert(#safe_names == 2, "Native resource keys must survive engine cdata tostring overrides")
print("PASS discovery retains distinct native identities with overridden engine cdata tostring")

_G.LiveLuaLoader = nil
_G.CowboyBingusModLoader = nil
local manager = assert(loadfile("src/manager.lua"))()({
    available = function()
        return false
    end,
    require = function() end,
    log_directory = "fixture/Logs",
    open_log = function() end,
    report = function() end,
}, {})
assert(
    manager.log_directory == "fixture/Logs"
        and CowboyBingusModLoader.log_directory == "fixture/Logs",
    "compat log directory is visible before addons initialize"
)
_G.LiveLuaLoader = nil
_G.CowboyBingusModLoader = nil
print("PASS shared log-directory compatibility field")
