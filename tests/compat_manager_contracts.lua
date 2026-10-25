-- The real manager (src/manager.lua) with the compatibility object attached. Run by
-- tests/test_compat.py after compat_contracts.lua; uses its archives.
local fixture = dofile("tests/tmp/compat/fixture.lua")
local root = fixture.root
local function read_file(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local text = f:read("*a"); f:close(); return text
end
local clock = 0
stingray = {
    Keyboard = { button_id = function() return nil end, button = function() return 0 end, pressed = function() return false end },
    Mouse = { button_id = function() return nil end },
    Window = { has_focus = function() return true end },
    Application = { time_since_launch = function() return clock end, main_world = function() return "world" end,
                    build_identifier = function() return "26088801" end, can_get = function() return true end },
    Gui = { resolution = function() return 1920, 1080 end },
}
local reports = {}
local function report(name, line) reports[#reports + 1] = tostring(name) .. ": " .. tostring(line) end
local files = { "9ba626afa44a3aa3.patch_0", "9ba626afa44a3aa3.patch_1" }
local platform = {
    data = root .. "/data",
    files = function() return files end,
    read = function(path) return read_file(path) end,
    hash = function(name) return fixture.hashes[name] or "0000000000000000" end,
}
local names, _, _, _, details, extras = dofile("src/discovery.lua")(platform, true)
local compat = dofile("src/compat.lua").new({ platform = platform, report = report, details = details, extras = extras,
    engine = function() return stingray end, settings_dir = root .. "/settings", checked = true })
local ordered = compat.order(names)
-- Two Bingus-style mods through the game's require: one returns hooks, one hooks update itself.
local returned_ticks, hooked_ticks, hooked_shutdowns = 0, 0, 0
local game = {
    ["mods/test/bingus"] = function()
        return { update = function() returned_ticks = returned_ticks + 1 end, shutdown = function() end }
    end,
    ["mods/test/hooker"] = function()
        local previous = update
        update = function(dt) hooked_ticks = hooked_ticks + 1; if previous then return previous(dt) end end
        return { update = function() error("a mod that hooked update must not have its returned update driven") end }
    end,
}
ordered[#ordered + 1] = "mods/test/hooker"
update = function() end
CowboyBingusModLoader, LiveLuaLoader, ModOptionsMenu, ModBindingsMenu = nil, nil, nil, nil
local manager = dofile("src/manager.lua")({
    available = function() return true end,
    require = function(name)
        if compat.handles(name) then return compat.require(name) end
        return game[name]()
    end,
    report = report, open_log = function() return nil end, revision = "compat-test", compat = compat,
}, ordered)
local L = LiveLuaLoader
assert(L == manager and type(CowboyBingusModLoader.on_shutdown) == "function" and CowboyBingusModLoader.game.build_identifier == "26088801",
    "The Bingus API carries Boot Mod Loader's additions")
assert(ModOptionsMenu and ModBindingsMenu, "Look-alikes set before the mods load")
for _, name in ipairs({ "mods/test/lib", "mods/test/needs-lib", "mods/test/boot", "mods/test/bingus", "mods/test/hooker" }) do
    assert(L.modules[name] == "loaded", name .. ": " .. tostring(L.modules[name]))
end
assert(L.records["mods/test/needs-lib"] and L.records["mods/test/boot"] and L.records["mods/test/bingus"], "Chef mods and returned hooks are records")
assert(not L.records["mods/test/hooker"], "A mod that hooked update keeps its own hook")
update(0.016); L.frame(0.016); update(0.016); L.frame(0.016)
assert(returned_ticks == 2 and hooked_ticks == 2, "Returned hooks driven once a frame; the update hook runs as before")
assert(compat.chef.shared["test.boot.init"] == true, "The boot script's init ran on enable")
L.shutdown()
assert(compat.chef.shared["test.boot.shutdown"] == 3, "Boot shutdown ran after init + two updates")
print("PASS compat with the manager on " .. (rawget(_G, "jit") and jit.version or _VERSION) .. ": records, adopted hooks, untouched update hooks, Bingus additions, look-alikes, boot lifecycle")
