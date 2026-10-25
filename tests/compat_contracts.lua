-- Chef Shared Loader and Boot Mod Loader compatibility. Run by tests/test_compat.py, which
-- builds the archives and fixture. Fake engine only; real archive files and real files.
local fixture = dofile("tests/tmp/compat/fixture.lua")
local root = fixture.root
local function read_file(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local text = f:read("*a"); f:close(); return text
end
local function write_file(path, text) local f = assert(io.open(path, "wb")); f:write(text); f:close() end

-- ------------------------------------------------------------ fake engine
local clock, world_handle, focus = 0, { id = "world-1" }, true
local down, pressed = {}, {}
local key_ids = { w = 1, f6 = 2, ["left shift"] = 3, p = 4, ["x button 1"] = 5 }
local key_names = {}
for k, v in pairs(key_ids) do key_names[v] = k end
local spawned, destroyed = {}, {}
stingray = {
    Keyboard = { button_id = function(n) return key_ids[n] end, button_name = function(id) return key_names[id] end,
                 button = function(id) return down[id] and 1 or 0 end, pressed = function(id) return pressed[id] == true end,
                 released = function() return false end, keystrokes = function() return { "a", "b" } end },
    Mouse = { button_id = function(n) return ({ left = 0, right = 1, middle = 2, extra_1 = 3 })[n] end, button = function() return 0 end,
              axis_id = function(n) return ({ cursor = 2, wheel = 1 })[n] end, axis = function(id) return id == 2 and { x = 10, y = 20 } or { x = 0, y = 1 } end },
    Window = { has_focus = function() return focus end },
    Application = { time_since_launch = function() return clock end, main_world = function() return world_handle end,
                    build_identifier = function() return "26088801" end, can_get = function() return true end },
    Gui = { resolution = function() return 1920, 1080 end },
    World = { spawn_unit = function(w, name, pos) local u = { name = name, alive = true }; spawned[#spawned + 1] = u; return u end,
              destroy_unit = function(w, u) u.alive = false; destroyed[#destroyed + 1] = u end },
    Unit = { alive = function(u) return type(u) == "table" and u.alive == true end, world_position = function() return { x = 1, y = 2, z = 3 } end,
             num_scene_graph_items = function() return 4 end },
    Network = { game_session = function() return nil end, peer_id = function() return "peer-1" end },
    Vector3 = function(x, y, z) return { x = x, y = y, z = z } end,
}
local engine = function() return stingray end
local reports = {}
local function report(name, line) reports[#reports + 1] = tostring(name) .. ": " .. tostring(line) end
local function reported(pattern)
    for _, line in ipairs(reports) do if string.find(line, pattern, 1, true) then return true end end
    return false
end

-- ------------------------------------------------------------ discovery
local files = { "9ba626afa44a3aa3.patch_0", "9ba626afa44a3aa3.patch_1" }
local platform = {
    data = root .. "/data", settings = root .. "/lll",
    files = function() local stamps = {}; for _, f in ipairs(files) do stamps[f] = "1" end; return files, stamps end,
    read = function(path) return read_file(path) end,
    write = function(path, text) write_file(path, text); return true end,
    hash = function(name) return fixture.hashes[name] or "0000000000000000" end,
}
local discover = dofile("src/discovery.lua")
local names, warnings, _, _, details, extras = discover(platform, true)
assert(#warnings == 0, tostring(warnings[1]))
local found = {}
for _, n in ipairs(names) do found[n] = true end
assert(found["mods/test/needs-lib"] and found["mods/test/lib"] and found["mods/test/boot"] and found["mods/test/bingus"], "Chef names with '-' and HD2-Boot are entries")
assert(not found["mods/test/lib/options/large"], "An options file is not an entry")
assert(details["mods/test/needs-lib"].chef and details["mods/test/needs-lib"].kind == "addon", "chef = ... marks a Chef addon")
assert(details["mods/test/boot"].kind == "boot" and details["mods/test/boot"].chef, "HD2-Boot is Chef-style")
assert(not details["mods/test/bingus"].chef, "A Bingus-style mod keeps the game's require")
local needs = details["mods/test/needs-lib"].requires
assert(#needs == 2 and needs[1].name == "chef-shared-loader" and needs[1].version == "1.0.0" and needs[2].name == "mods/test/lib", "HD2-Requires lines")
assert(#extras == 1 and extras[1].kind == "options" and extras[1].target == "mods/test/lib", "Options file recorded for its mod")
-- The v4 cache carries the same details.
local names2, _, diagnostics2, _, details2, extras2 = discover(platform)
assert(string.find(diagnostics2, "cached catalog", 1, true), "Second scan uses the cache")
assert(#names2 == #names and details2["mods/test/needs-lib"].chef and details2["mods/test/needs-lib"].offset == details["mods/test/needs-lib"].offset
    and #details2["mods/test/needs-lib"].requires == 2 and #extras2 == 1 and extras2[1].target == "mods/test/lib", "Cache keeps details and extras")

-- ------------------------------------------------------------ the compatibility object
local drawn
local view = { draw = function(commands) drawn = commands end, measure = function(s, px) return #s * px end, release = function() end }
local Compat = dofile("src/compat.lua")
local compat = Compat.new({ platform = platform, report = report, details = details, extras = extras, engine = engine,
    settings_dir = root .. "/settings", checked = true, view = function() return view end,
    modules = function() return { ["mods/test/lib"] = "loaded" } end, require = function(n) return "game:" .. n end })
local ordered, refused = compat.order(names)
local position = {}
for i, n in ipairs(ordered) do position[n] = i end
assert(position["mods/test/lib"] < position["mods/test/needs-lib"], "Requirements start first")
local refusals = {}
for _, r in ipairs(refused) do refusals[r.name] = r.reason end
assert(refusals["mods/test/missing"] and string.find(refusals["mods/test/missing"], "not installed", 1, true), "Missing requirement refused")
assert(refusals["mods/test/too-new"] and string.find(refusals["mods/test/too-new"], "9.0.0", 1, true), "Too new a loader requirement refused")
assert(compat.handles("mods/test/needs-lib") and compat.handles("mods/test/boot") and not compat.handles("mods/test/bingus"))
assert(compat.options["mods/test/lib"].size == "large" and compat.options["mods/test/lib"].nested.a == 1, "Options merged")

-- Boot Mod Loader / Bingus API additions and the look-alikes.
local bingus_api = { api = 1, version = 18 }
compat.extend(bingus_api)
assert(type(bingus_api.on_shutdown) == "function" and type(bingus_api.on_update) == "function" and bingus_api.game.build_identifier == "26088801")
ModOptionsMenu, ModBindingsMenu = nil, nil
local installed = compat.install({ "mods/test/lib" })
assert(#installed == 2 and ModOptionsMenu.api == 1 and ModOptionsMenu.version == 3 and ModBindingsMenu.version == 4)
ModOptionsMenu, ModBindingsMenu = nil, nil
compat.install({ "mods/cowboybingus/mod_options_menu" })
assert(ModOptionsMenu == nil and ModBindingsMenu ~= nil, "A real Mod Options Menu keeps its global")
ModOptionsMenu = compat.bingus.options

-- ------------------------------------------------------------ loading Chef mods
compat.loading = "mods/test/lib"
local lib_record = compat.require("mods/test/lib")
compat.loading = nil
assert(lib_record.live_lua_api == 1 and package.loaded["mods/test/lib"].version == "1.2.0" and package.loaded["mods/test/lib"].value == "large",
    "chef is ..., options reach chef.options, the module is exported")
local needs_record = compat.require("mods/test/needs-lib")
assert(package.loaded["mods/test/needs-lib"].lib == package.loaded["mods/test/lib"], "chef.require finds another mod's exports")
assert(rawget(_G, "helper_global") == nil, "A Chef addon's globals stay its own")
needs_record.on_enable(); needs_record.on_update(0.016); needs_record.on_update(0.016)
assert(needs_record.on_disable() == true)
local boot = compat.require("mods/test/boot")
boot.on_enable(); boot.on_update(0.016)
assert(rawget(_G, "calls") == nil and type(rawget(_G, "update")) ~= "function" or rawget(_G, "update") == nil, "Boot globals stay in its environment")
boot.on_disable()
local chef_core = compat.chef
-- Saved values survive into a new object for the same mod.
local again = chef_core.object("mods/test/needs-lib")
assert(again.load("ticks") == 2 and again.load("stopped") == true, "chef.save/load persist between launches")

-- ------------------------------------------------------------ chef helpers
local chef = chef_core.object("mods/test/helpers", { options = { fast = true } })
assert(chef.api == 3 and chef.has("menu") and chef.has("api") and not chef.has("dev") and chef.options.fast)
assert(not pcall(function() chef.capabilities.menu = false end), "Capabilities are read-only")
local got = {}
local unsubscribe = chef.on("test.event", function(a, b) got[#got + 1] = a + b end)
assert(chef.emit("test.event", 1, 2) == 1 and got[1] == 3); unsubscribe()
assert(chef.emit("test.event", 1, 2) == 0)
chef.share("test.value", 42); assert(chef.shared("test.value") == 42)
-- Options and keys become HD2 Mod Setting GUI rows under the mod's title.
assert(chef.title("Helper Test"))
assert(chef.option("size", { type = "choice", label = "Size", choices = { "Small", "Large" }, default = 2 }) == 2)
local changed
chef.on_change("size", function(v) changed = v end)
assert(chef.set("size", 1) and chef.get("size") == 1 and changed == 1)
local ping = chef.bind("ping", "F6", "Ping")
assert(ping.key() == "f6")
pressed[2] = true; assert(ping.pressed())
-- The focus guard is asked once a frame.
focus = false; compat.tick(0.016); assert(not ping.pressed(), "No keys without focus")
focus = true; compat.tick(0.016); assert(ping.pressed()); pressed[2] = nil
down[1] = true; assert(chef.key_down("W") and chef.key_known("left shift") and not chef.key_known("nope")); down[1] = nil
local x, y = chef.cursor(); assert(x == 10 and y == 20 and chef.wheel() == 1 and chef.typed() == "ab")
-- Timers.
local fired, every_count, spread_items = 0, 0, {}
chef.after(1, function() fired = fired + 1 end)
local repeating = chef.every(0.5, function() every_count = every_count + 1 end)
chef.spread({ "a", "b", "c" }, 2, function(item) spread_items[#spread_items + 1] = item end, function(ok) spread_items.done = ok end)
clock = 0.6; compat.tick(0.6); clock = 1.2; compat.tick(0.6); repeating.cancel(); clock = 2; compat.tick(0.8)
assert(fired == 1 and every_count == 2 and #spread_items == 3 and spread_items.done == true, "after/every/spread")
-- Drawing reaches the view; a new world bumps world_id.
chef.rect(1, 2, 3, 4, chef.color(255, 0, 0, 128), 900)
assert(chef.text(5, 6, "hello", 10) == 50)
chef.circle(100, 100, 3)
chef.notify("saved", 5)
compat.tick(0.016)
assert(drawn and drawn[1].type == "rect" and drawn[1].c[1] == 255 and math.abs(drawn[1].a - 128 / 255) < 1e-6)
local texts = 0
for _, c in ipairs(drawn) do if c.type == "text" then texts = texts + 1; assert(c.text == string.upper(c.text)) end end
assert(texts == 2, "Text and the notice are drawn in capitals")
local first_world = chef.world_id()
world_handle = { id = "world-2" }; compat.tick(0.016)
assert(chef.world_id() == first_world + 1)
-- Spawning is undone when the mod stops.
local unit = assert(chef.spawn("units/test", 1, 2, 3))
assert(chef.unit_position(unit) == 1)
chef_core.stop(chef_core.mods["mods/test/helpers"])
assert(destroyed[1] == unit, "Spawned units are destroyed when the mod stops")
-- Saved tables round trip; functions are refused.
assert(chef.save_table("state", { a = 1, b = { "x", true } }))
local t = chef.load_table("state"); assert(t.a == 1 and t.b[1] == "x" and t.b[2] == true)
assert(not chef.save_table("bad", { f = function() end }))
-- Version comparison.
local Chef = dofile("src/compat/chef.lua")
assert(Chef.version_at_least("1.2.0", "1.1") and not Chef.version_at_least("1.0.9", "1.1") and Chef.version_at_least("2", "1.9.9"))

-- ------------------------------------------------------------ Mod Options / Bindings Menu look-alikes
compat.loading = "mods/test/bingus"
assert(ModOptionsMenu.register_option("bingus.speed", { type = "slider", label = "Speed", min = 0, max = 10, step = 0.5, default = 2.25 }))
assert(ModOptionsMenu.get("bingus.speed") == 2.5, "Slider defaults snap to the step")
assert(not ModOptionsMenu.register_option("bingus.speed", { type = "toggle", label = "Speed" }), "A changed spec is refused")
local option_changes = {}
ModOptionsMenu.on_change("bingus.speed", function(v) option_changes[#option_changes + 1] = v end)
assert(ModBindingsMenu.register_binding("bingus.ping", "Ping", nil, { default = { button = "p", trigger = "hold" } }))
assert(ModBindingsMenu.register_binding("bingus.side", "Side", nil, { default = { device = "mouse", button = "extra_1" } }))
compat.loading = nil
down[4] = true; assert(ModBindingsMenu.is_down("bingus.ping") == true); down[4] = nil
assert(ModBindingsMenu.is_down("bingus.unknown") == nil)
local poll = {}
down[4] = true; ModBindingsMenu.poll({ "bingus.ping" }, poll); assert(poll.pressed[1] and poll.down[1])
ModBindingsMenu.poll({ "bingus.ping" }, poll); assert(not poll.pressed[1] and poll.down[1]); down[4] = nil
assert(ModBindingsMenu.binding("bingus.side")[1][1] == "mouse" and ModBindingsMenu.binding("bingus.side")[1][2] == "extra_1")
assert(ModBindingsMenu.set_binding("bingus.ping", "w") and ModBindingsMenu.binding_info("bingus.ping").state == "set")
assert(ModBindingsMenu.set_binding("bingus.ping", {}) and ModBindingsMenu.binding_info("bingus.ping").state == "cleared")
assert(ModBindingsMenu.set_binding("bingus.ping", nil) and ModBindingsMenu.binding_info("bingus.ping").state == "default")
-- Bingus additions run.
local updates, shutdowns = 0, 0
bingus_api.on_update("test", function() updates = updates + 1 end)
bingus_api.on_update("bad", function() error("boom") end)
bingus_api.on_shutdown(function() shutdowns = shutdowns + 1 end)
compat.tick(0.016); compat.tick(0.016)
assert(updates == 2 and reported("on_update bad dropped"), "on_update runs; an erroring one is dropped")

-- ------------------------------------------------------------ the settings window's files
compat.window.tick(0, true)
local dir = root .. "/settings"
local list = read_file(dir .. "/mom_bingus_options.json")
assert(list and string.find(list, '"title":"bingus"', 1, true) and string.find(list, '"settings":"mom_bingus_settings.txt"', 1, true), "Options list written")
local keys = read_file(dir .. "/mbm_bingus_options.json")
assert(keys and string.find(keys, '"name":"Keys"', 1, true) and string.find(keys, '"title":"bingus"', 1, true), "Keys page under the mod's title")
local helper = read_file(dir .. "/lll_helpers_options.json")
assert(helper and string.find(helper, '"title":"Helper Test"', 1, true), "chef.title names the list")
local settings = read_file(dir .. "/mom_bingus_settings.txt")
assert(settings and string.find(settings, "bingus_speed=2.5", 1, true) and string.find(settings, "#end", 1, true))
-- The window changes a value: applied once a second, on_change called, a log line written.
write_file(dir .. "/mom_bingus_settings.txt", "bingus_speed=7\n#end\n")
compat.window.tick(1)
assert(ModOptionsMenu.get("bingus.speed") == 7 and option_changes[#option_changes] == 7, "A window change applies")
assert(string.find(read_file(dir .. "/mom_bingus.log") or "", "applied bingus_speed=7", 1, true))
-- A half-written file waits for the next read.
write_file(dir .. "/mom_bingus_settings.txt", "bingus_speed=3\n")
compat.window.tick(1)
assert(ModOptionsMenu.get("bingus.speed") == 7, "A half-written file is not applied")
compat.after_shutdown()
assert(shutdowns == 1, "on_shutdown runs after the game's shutdown")
print("PASS compat on " .. (rawget(_G, "jit") and jit.version or _VERSION) .. ": Chef headers and cache, requirements, Chef addon/boot runners, chef helpers, Bingus additions, MOM/MBM look-alikes, settings window")
