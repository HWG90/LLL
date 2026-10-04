local discovery = dofile("src/discovery.lua")
local bytes = {}
local names = { "9ba626afa44a3aa3.patch_2", "9ba626afa44a3aa3.patch_10" }
for _, name in ipairs(names) do
    local f = assert(io.open("tests/tmp/" .. name, "rb"))
    bytes[name] = f:read("*a")
    f:close()
end
local saved, opens, closes, writes = nil, 0, 0, 0
local stamps = {}
for _, name in ipairs(names) do
    stamps[name] = "one"
end
local p = {
    data = "archives",
    settings = "cache",
    files = function()
        return names, stamps
    end,
    read = function(path)
        return saved
    end,
    write = function(path, text)
        saved = text
        writes = writes + 1
        return true
    end,
    archive = function(path)
        local data = bytes[path:match("([^/]+)$")]
        opens = opens + 1
        local closed = false
        return {
            size = #data,
            read = function(offset, n)
                assert(not closed and offset >= 0 and offset + n <= #data)
                return data:sub(offset + 1, offset + n)
            end,
            close = function()
                assert(not closed)
                closed = true
                closes = closes + 1
            end,
        }
    end,
}
local first, warnings = discovery(p)
assert(#first == 1 and first[1] == "mods/test/accepted" and #warnings == 0)
assert(opens == closes and writes == 1)
local old = opens
local fresh = dofile("src/discovery.lua")
local cached, _, details = fresh(p)
assert(
    #cached == 1 and opens == old and details:find("cached catalog", 1, true),
    "New loader must use persisted cache"
)
stamps[names[1]] = "two"
discovery(p)
assert(opens > old, "Metadata change must invalidate cache")
old = opens
saved = saved:gsub("mods/test/accepted", "mods/test/imposter")
discovery(p)
assert(opens > old, "Corrupt catalog must rescan")
old = opens
discovery(p, true)
assert(opens > old, "Explicit discovery must bypass cache")
names[#names + 1] = "9ba626afa44a3aa3.patch_99"
stamps[names[#names]] = "one"
bytes[names[#names]] = "bad"
local before = writes
local _, bad = discovery(p)
assert(
    #bad == 1 and opens == closes and writes == before,
    "Malformed archive must close reader and block cache replacement"
)
print(
    "PASS bounded archive reads, close on failure, persisted cache, metadata invalidation, corruption and forced discovery"
)
LLL_METADATA = dofile("src/metadata.lua")
local texts = { ["root/demo.lua"] = "return {live_lua_api=1,on_disable=function()end}" }
local version = 1
local changed = true
local reads, lists = 0, 0
local transport = {
    roots = { { kind = "lll", path = "root" } },
    settings = "settings",
    read = function(path)
        reads = reads + 1
        return texts[path]
    end,
    files = function()
        lists = lists + 1
        return { "demo.lua" }, {}, {}
    end,
    directories = function()
        error("Duplicate directory traversal")
    end,
    changed = function()
        local value = changed
        changed = false
        return value
    end,
    stat = function(path)
        return texts[path] and tostring(version)
    end,
    write = function(path, text)
        texts[path] = text
        return true
    end,
}
local live = dofile("src/live.lua")(transport, function() end)
local found = live.scan()
assert(#found == 1)
live.source(found[1])
reads = 0
lists = 0
live.scan()
live.source(found[1])
assert(reads == 0 and lists == 0, "Unchanged cycle must not list or read scripts")
texts["root/demo.lua"] = "return {live_lua_api=1,number=2,on_disable=function()end}"
version = 2
changed = true
assert(live.source(found[1]):find("number=2", 1, true))
assert(reads == 1)
live.source(found[1], true)
assert(reads == 2, "Stable edit confirmation must force a second content read")
live.scan(true)
assert(lists == 1, "Refresh must force a catalog scan")
assert(live.set_enabled(found[1], false) == false, "Missing config path must fail cleanly")
print(
    "PASS idle zero-content-read watcher, shared directory enumeration, edit detection, second-read confirmation and forced Refresh"
)

local native = dofile("tests/tmp/speed-native.lua")
local folder = "tests/tmp/watch-fixture"
assert(native.changed(folder))
assert(not native.changed(folder))
assert(native.write(folder .. "/probe.lua", "a"))
assert(native.changed(folder), "Real file creation must notify watcher")
assert(native.stat(folder .. "/probe.lua"))
assert(native.write(folder .. "/probe.lua", "b"))
assert(native.changed(folder), "Real replacement must notify watcher")
assert(os.remove(folder .. "/probe.lua"))
assert(native.changed(folder))
assert(not native.stat(folder .. "/probe.lua"))
native.close_watches()
print("PASS real Windows create/replace/delete notifications, stat and watcher cleanup")
local ffi = require("ffi")
local load = ffi.load
local key = false
local mouse_held = false
local foreground = true
local extracts, loads, draws = 0, 0, 0
local data = {}
local local_menu
ffi.load = function(name)
    if name == "user32" then
        return {
            lll_ui_key = function(code)
                return ((code == 120 and key) or (code == 1 and mouse_held)) and 32768 or 0
            end,
            lll_ui_foreground = function()
                return foreground and ffi.cast("void *", 1) or nil
            end,
            lll_ui_window_process = function(window, out)
                out[0] = 123
                return 1
            end,
        }
    end
    if name == "kernel32" then
        return {
            lll_ui_process = function()
                return 123
            end,
        }
    end
    loads = loads + 1
    return {
        mcm_wheel = function()
            return 0
        end,
    }
end
local previous =
    { LLL_UI_CORE, LLL_UI_CAPTURE, LLL_UI_VIEW, LLL_UI_MENU, LLL_NATIVE, stingray, DBFMCM }
LLL_UI_CORE = {
    new = function()
        return {}
    end,
}
LLL_UI_CAPTURE = {
    new = function()
        return {
            release = function() end,
            sync = function()
                return true
            end,
        }
    end,
}
LLL_UI_VIEW = {
    new = function()
        return {
            release = function() end,
            measure = function()
                return 1
            end,
            draw = function()
                draws = draws + 1
            end,
        }
    end,
}
LLL_UI_MENU = {
    new = function()
        local_menu = {
            visible = false,
            tick = function(input)
                if input.down(121) then
                    local_menu.visible = not local_menu.visible
                end
            end,
            advance = function() end,
            compose = function()
                return {}
            end,
            recover = function() end,
        }
        return local_menu
    end,
}
LLL_NATIVE = { name = "helper.dll", bytes = "exact helper" }
stingray = { Window = {}, Gui = {
    resolution = function()
        return 1920, 1080
    end,
} }
DBFMCM = nil
local loader = {}
local ui = dofile("src/ui.lua")(loader, {
    settings = "settings",
    read = function(path)
        return data[path]
    end,
    write = function(path, text)
        extracts = extracts + 1
        data[path] = text
        return true
    end,
}, { bind = function() end }, function() end)
ui.tick()
assert(
    extracts == 0 and loads == 0 and not ui.menu,
    "Closed manager must not load native helper or construct GUI"
)
foreground = false
key = true
ui.tick()
assert(loads == 0, "F9 outside game must not initialize UI")
key = false
ui.tick()
foreground = true
key = true
ui.tick()
assert(extracts == 1 and loads == 1 and ui.menu.visible)
ui.tick()
assert(ui.menu.visible, "Opening F9 press must not immediately close menu")
key = false
ui.tick()
key = true
ui.tick()
assert(not ui.menu.visible)
ui.open()
assert(ui.menu.visible and loads == 1)
ui.close()
assert(not ui.menu.visible)
key = false
mouse_held = true
ui.open()
ui.tick()
assert(
    ui.open_pending and not ui.menu.visible,
    "Open Manager must wait for the activating mouse button release"
)
ui.tick()
assert(ui.open_pending and not ui.menu.visible)
mouse_held = false
ui.tick()
assert(not ui.open_pending and ui.menu.visible, "Released click must open the queued manager")
ui.close()
mouse_held = true
ui.open()
foreground = false
ui.tick()
assert(not ui.open_pending and not ui.menu.visible, "Focus loss cancels queued open")
ffi.load = load
LLL_UI_CORE, LLL_UI_CAPTURE, LLL_UI_VIEW, LLL_UI_MENU, LLL_NATIVE, stingray, DBFMCM =
    unpack(previous, 1, 7)
print(
    "PASS lazy native/GUI initialization, foreground-gated F9, held-key suppression, reopen and close"
)
