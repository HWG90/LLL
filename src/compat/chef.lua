-- Mods written for Chef Shared Loader (github.com/Th3chef/Chef-Shared-Loader, its
-- docs/MODDING.md): the `chef` helpers (api 1-3) each mod is handed, its addon and
-- boot-style runners, and its shared services. LLL is not a sandbox: there is no
-- lockdown here, and helpers LLL cannot back (unit kinds and watches, the view
-- camera, textures, particles, the resource index) answer nil or false and are
-- false in `chef.has`. Options and keys are rows in HD2 Mod Setting GUI.
local M = {}
M.VERSION = "1.2.0"
M.TOP = 1000
local HOOKS = { "init", "update", "render", "shutdown" }

local function readonly(t)
    return setmetatable({}, { __index = t, __newindex = function() error("read-only", 2) end, __metatable = false })
end
local function numbers(v)
    local out = {}
    for part in string.gmatch(tostring(v or ""), "%d+") do out[#out + 1] = tonumber(part) end
    return out
end
function M.version_at_least(have, want)
    local a, b = numbers(have), numbers(want)
    for i = 1, math.max(#a, #b) do
        local x, y = a[i] or 0, b[i] or 0
        if x ~= y then return x > y end
    end
    return true
end
local function clean(name) return (string.gsub(string.lower(name), "[^%w%-]", function(c) return string.format("_%02x", string.byte(c)) end)) end
-- Plain data as a Lua literal (no functions or cycles, 16 deep).
local function serialize(v, depth, seen, out)
    local kind = type(v)
    if kind == "string" then out[#out + 1] = string.format("%q", v)
    elseif kind == "number" then
        if v ~= v or v == math.huge or v == -math.huge then error("number not finite") end
        out[#out + 1] = string.format("%.17g", v)
    elseif kind == "boolean" then out[#out + 1] = tostring(v)
    elseif kind == "table" then
        if depth > 16 then error("more than 16 deep") end
        if seen[v] then error("a cycle") end
        seen[v] = true
        out[#out + 1] = "{"
        for k, x in pairs(v) do
            if type(k) ~= "string" and type(k) ~= "number" then error("key of type " .. type(k)) end
            out[#out + 1] = "["; serialize(k, depth + 1, seen, out); out[#out + 1] = "]="
            serialize(x, depth + 1, seen, out); out[#out + 1] = ","
        end
        out[#out + 1] = "}"
        seen[v] = nil
    else error("a " .. kind .. " cannot be saved") end
end

-- ctx: engine() -> stingray; report(name, line); window (settings_window); keys
-- (compat/bingus: resolve, key_state); log_dir; previous_dir; modules() -> loader
-- states; view() -> an LLL view or nil; file (io-like); require (the game's).
function M.new(ctx)
    local self = { mods = {}, shared = {}, listeners = {}, exports = {}, waiting = {}, started = false, world_id = 0,
                   draws = {}, lines = {}, frame = 0, session = {}, session_at = -1 }
    local file = ctx.file or io
    local function sr() local ok, value = pcall(ctx.engine); return ok and type(value) == "table" and value or nil end
    local function say(name, message) pcall(ctx.report, name, message) end
    local function now()
        local e = sr()
        local ok, value = pcall(function() return e.Application.time_since_launch() end)
        if ok and type(value) == "number" then return value end
        return os.clock()
    end
    local function call(path, ...)
        local e = sr()
        local table_name, fn_name = string.match(type(path) == "string" and path or "", "^([%w_]+)%.([%w_]+)$")
        if not table_name then return nil, "expected 'Table.function'" end
        local holder = e and rawget(e, table_name)
        if type(holder) ~= "table" then holder = rawget(_G, table_name) end
        local fn = type(holder) == "table" and holder[fn_name] or nil
        if type(fn) ~= "function" then return nil, path .. " is not in the engine" end
        local result = { pcall(fn, ...) }
        if not result[1] then return nil, tostring(result[2]) end
        return unpack(result, 2, table.maxn(result))
    end
    self.call = call
    -- A device's button or axis index; builds name the lookup <kind>_index or <kind>_id.
    local function index_of(device, kind, name)
        for _, field in ipairs({ kind .. "_index", kind .. "_id" }) do
            local id = call(device .. "." .. field, name)
            if type(id) == "number" then return id end
        end
        return nil
    end
    -- An engine constructor (Vector3, Color, ...), or nil.
    local function construct(ctor, ...)
        local e = sr()
        local fn = e and rawget(e, ctor)
        if type(fn) ~= "function" then fn = rawget(_G, ctor) end
        if type(fn) ~= "function" then return nil end
        local ok, value = pcall(fn, ...)
        return ok and value or nil
    end
    -- ------------------------------------------------------------ world and session
    local world_seen
    local function world()
        local main = call("Application.main_world")
        return main
    end
    local function session()
        local t = now()
        if t - self.session_at < 1 and self.session_at >= 0 then return self.session end
        self.session_at = t
        local s = { in_session = false, host = true, players = 1 }
        local game_session = call("Network.game_session")
        s.peer = call("Network.peer_id")
        if game_session ~= nil then
            s.in_session = true
            local host = call("GameSession.game_session_host", game_session)
            if host ~= nil and s.peer ~= nil then s.host = host == s.peer end
            local others = call("GameSession.other_peers", game_session)
            if type(others) == "table" then
                local n = 0
                for _ in pairs(others) do n = n + 1 end
                s.players = n + 1
            end
        end
        self.session = s
        return s
    end
    -- ------------------------------------------------------------ events
    local function on(m, event, fn)
        if type(event) ~= "string" or type(fn) ~= "function" then return nil end
        local list = self.listeners[event] or {}
        self.listeners[event] = list
        local entry = { fn = fn, mod = m, errors = 0 }
        list[#list + 1] = entry
        return function()
            for i = #list, 1, -1 do if list[i] == entry then table.remove(list, i) end end
        end
    end
    local function emit(event, ...)
        local list = self.listeners[event]
        if not list then return 0 end
        local ran = 0
        for i = #list, 1, -1 do
            local entry = list[i]
            if entry then
                local ok, why = pcall(entry.fn, ...)
                ran = ran + 1
                if not ok then
                    entry.errors = entry.errors + 1
                    say(entry.mod and entry.mod.name or "chef", "listener for " .. event .. " failed: " .. tostring(why))
                    if entry.errors >= 20 then table.remove(list, i) end
                end
            end
        end
        return ran
    end
    self.emit = emit
    -- ------------------------------------------------------------ drawing
    local function color(r, g, b, a) return { r = tonumber(r) or 255, g = tonumber(g) or 255, b = tonumber(b) or 255, a = tonumber(a) or 255 } end
    local function draw(kind, x, y, w, h, c, layer, text, size)
        if type(x) ~= "number" or type(y) ~= "number" or x ~= x or y ~= y then return end
        c = type(c) == "table" and c or color()
        local cmd = { type = kind, x = x, y = y, w = w, h = h, a = math.max(0, math.min(1, (c.a or 255) / 255)),
                      c = { c.r or 255, c.g or 255, c.b or 255 }, layer = tonumber(layer) or 900, text = text, size = size }
        if #self.draws < 20000 then self.draws[#self.draws + 1] = cmd end
    end
    -- The view draws for every mod; made on first use (measuring included).
    local function ensure_view()
        if self.view == nil and ctx.view then
            local ok, value = pcall(ctx.view)
            self.view = ok and value or false
        end
        return self.view
    end
    local function measure(s, px)
        local view = ensure_view()
        if view and view.measure then
            local ok, w = pcall(view.measure, s, px)
            if ok and type(w) == "number" then return w end
        end
        return #s * px * 0.62
    end
    local function text_fit(s, px, w)
        s = string.upper(tostring(s))
        if measure(s, px) <= w then return s end
        while #s > 0 and measure(s .. "...", px) > w do s = string.sub(s, 1, -2) end
        return s .. "..."
    end
    local function text_wrap(s, px, w, most)
        most = most or 64
        local lines, line = {}, ""
        for word in string.gmatch(string.upper(tostring(s)), "%S+") do
            local candidate = line == "" and word or (line .. " " .. word)
            if measure(candidate, px) <= w or line == "" then line = candidate
            else lines[#lines + 1] = line; line = word end
            if #lines >= most then break end
        end
        if line ~= "" and #lines < most then lines[#lines + 1] = line end
        return lines
    end
    local function scan(fill, top, bottom, c, layer)
        for y = math.floor(bottom), math.ceil(top) - 1 do
            local x0, x1 = fill(y + 0.5)
            if x0 and x1 and x1 > x0 then draw("rect", x0, y, x1 - x0, 1, c, layer) end
        end
    end
    -- ------------------------------------------------------------ per mod
    local function settings_path(m) return ctx.log_dir and (ctx.log_dir .. "/lll_chef_" .. clean(m.name) .. ".txt") end
    local function load_settings(m)
        m.values = {}
        local path = settings_path(m)
        local ok, f = pcall(file.open, path or "", "rb")
        if not ok or not f then return end
        local _, text = pcall(f.read, f, "*a")
        pcall(f.close, f)
        for k, kind, v in string.gmatch(type(text) == "string" and text or "", "([^\t\r\n]+)\t(%a)\t([^\r\n]*)") do
            if kind == "b" then m.values[k] = v == "true" elseif kind == "n" then m.values[k] = tonumber(v)
            elseif kind == "s" then m.values[k] = (string.gsub(v, "\\(%d%d%d)", function(d) return string.char(tonumber(d)) end)) end
        end
    end
    local function flush_settings(m, force)
        if not m.values_dirty or (not force and now() < (m.save_at or 0)) then return end
        local path = settings_path(m)
        if not path then return end
        local lines = {}
        for k, v in pairs(m.values) do
            local kind = type(v) == "boolean" and "b" or (type(v) == "number" and "n" or "s")
            local text = kind == "s" and string.gsub(v, "[%c\\]", function(c) return string.format("\\%03d", string.byte(c)) end) or tostring(v)
            lines[#lines + 1] = k .. "\t" .. kind .. "\t" .. text
        end
        table.sort(lines)
        local ok, f = pcall(file.open, path, "wb")
        if ok and f then pcall(f.write, f, table.concat(lines, "\n") .. "\n"); pcall(f.close, f) end
        m.values_dirty, m.save_at = false, now() + 3
    end
    local function stop(m)
        if m.stopped then return end
        m.stopped = true
        for _, t in ipairs(m.timers) do t.dead = true end
        for _, unsubscribe in ipairs(m.unsubscribe) do pcall(unsubscribe) end
        for event, list in pairs(self.listeners) do
            for i = #list, 1, -1 do if list[i].mod == m then table.remove(list, i) end end
        end
        for unit, w in pairs(m.spawned) do
            if call("Unit.alive", unit) == true then call("World.destroy_unit", w, unit) end
            m.spawned[unit] = nil
        end
        flush_settings(m, true)
        if m.log_handle then pcall(m.log_handle.close, m.log_handle); m.log_handle = nil end
    end
    self.stop = stop
    local function timer(m, every, fn, once)
        local t = { every = every, at = now() + every, fn = fn, once = once, errors = 0 }
        m.timers[#m.timers + 1] = t
        return { cancel = function() t.dead = true end, active = function() return not t.dead end }
    end

    function self.object(name, info)
        info = info or {}
        local m = { name = name, timers = {}, unsubscribe = {}, spawned = {}, notices = {}, options = info.options or {} }
        load_settings(m)
        self.mods[name] = m
        local chef = { api = 3, loader_version = M.VERSION, name = name, implementation = "Live Lua Loader", TOP = M.TOP,
                       options = m.options, log_directory = ctx.log_dir, previous_directory = ctx.previous_dir }
        m.chef = chef
        local caps = { api = 3, after_startup = true, settings = true, share = true, events = true, require = true, bind = true,
                       menu = true, shims = true, dev = false, logs = true, own_log = true, units = true, spawn = true,
                       timers = true, budget = false, session = true, settings_file = false, shapes = true,
                       sprite_sheets = false, notify = true, typed = true, key_labels = true, save_table = true, mods = true }
        chef.capabilities = readonly(caps)
        function chef.has(what) return what == "api" or caps[what] == true end
        function chef.log(fmt, ...)
            local line = select("#", ...) > 0 and string.format(tostring(fmt), ...) or tostring(fmt)
            if m.log_handle then pcall(m.log_handle.write, m.log_handle, line .. "\n"); pcall(m.log_handle.flush, m.log_handle)
            else say(name, line) end
        end
        chef.log_file = ctx.log_dir and (ctx.log_dir .. "/LiveLuaLoader.log") or nil
        function chef.own_log(log_name)
            if type(log_name) ~= "string" or not string.match(log_name, "^[%w_%-]+$") or #log_name > 48
                or string.sub(log_name, 1, 11) == "chef_loader" or not ctx.log_dir then return false end
            local path = ctx.log_dir .. "/" .. log_name .. ".log"
            local okr, old = pcall(file.open, path, "rb")
            local mode = "ab"
            if okr and old then
                local size = old:seek("end")
                pcall(old.close, old)
                if size and size > 1048576 then mode = "wb" end
            end
            local ok, f = pcall(file.open, path, mode)
            if not ok or not f then return false end
            m.log_handle, chef.log_file = f, path
            return true
        end
        function chef.time() return now() end
        chef.call = call
        function chef.call_kind(path, kind, ...) return call(path, ...) end
        -- world, camera and units
        function chef.world() return world() end
        function chef.world_id() return self.world_id end
        function chef.in_mission() return false end
        function chef.camera() return nil end
        function chef.world_to_screen() return nil end
        function chef.watch()
            local w = { items = {}, generation = 0 }
            function w.pause() end
            function w.resume() end
            function w.refresh() end
            function w.stop() end
            return w
        end
        function chef.mission_kinds() end
        -- input
        local keys = ctx.keys
        function chef.key_down(key) return keys.key_state(string.lower(tostring(key)), "button") end
        function chef.key_pressed(key) return keys.key_state(string.lower(tostring(key)), "pressed") end
        function chef.key_known(key) return keys.resolve(string.lower(tostring(key))) ~= nil end
        function chef.mouse_down(button)
            local id = index_of("Mouse", "button", button)
            if id == nil then return false end
            local v = call("Mouse.button", id)
            return (v == true or (type(v) == "number" and v > 0.5)) and keys.allowed()
        end
        function chef.cursor()
            local id = index_of("Mouse", "axis", "cursor")
            local v = id and call("Mouse.axis", id) or nil
            if v == nil then return nil end
            return v.x, v.y
        end
        function chef.wheel()
            local id = index_of("Mouse", "axis", "wheel")
            local v = id and call("Mouse.axis", id) or nil
            return v and v.y or 0
        end
        function chef.typed()
            local strokes = call("Keyboard.keystrokes")
            local out = {}
            if type(strokes) == "table" then
                for _, s in ipairs(strokes) do if type(s) == "string" and not string.find(s, "%c") then out[#out + 1] = s end end
            end
            return table.concat(out), type(strokes) == "table" and strokes or {}
        end
        function chef.key_label(key)
            local k = tostring(key or "")
            return (string.gsub(string.upper(k), "^LEFT ", "L"))
        end
        -- drawing
        function chef.screen()
            local w, h = call("Gui.resolution")
            if type(w) ~= "number" then return 1920, 1080 end
            return w, h
        end
        chef.color = color
        function chef.rect(x, y, w, h, c, layer) draw("rect", x, y, w, h, c, layer) end
        function chef.text(x, y, s, px, c, layer)
            s = string.upper(tostring(s)); px = tonumber(px) or 7
            draw("text", x, y, nil, nil, c, layer, s, px)
            return measure(s, px)
        end
        function chef.text_width(s, px) return measure(string.upper(tostring(s)), tonumber(px) or 7) end
        chef.text_fit = text_fit
        chef.text_wrap = text_wrap
        function chef.lang() return nil end
        function chef.tr(s) return s end
        function chef.sprite(x, y, rows, cell, colors, layer)
            if type(rows) ~= "table" or type(colors) ~= "table" then return end
            cell = tonumber(cell) or 1
            for i, row in ipairs(rows) do
                for j = 1, #row do
                    local c = colors[string.sub(row, j, j)]
                    if c then draw("rect", x + (j - 1) * cell, y + (#rows - i) * cell, cell, cell, c, layer) end
                end
            end
        end
        function chef.bitmap() return false end
        function chef.bitmap_uv() return false end
        function chef.ui_textures() end
        function chef.texture_sizes() end
        function chef.sprite_sheet() return nil end
        function chef.line(x1, y1, z1, x2, y2, z2, c)
            self.lines[#self.lines + 1] = { x1, y1, z1, x2, y2, z2, type(c) == "table" and c or color() }
        end
        function chef.triangle(x1, y1, x2, y2, x3, y3, c, layer)
            local ys = { y1, y2, y3 }
            scan(function(y)
                local xs = {}
                for _, e in ipairs({ { x1, y1, x2, y2 }, { x2, y2, x3, y3 }, { x3, y3, x1, y1 } }) do
                    local ax, ay, bx, by = e[1], e[2], e[3], e[4]
                    if (y >= math.min(ay, by)) and (y < math.max(ay, by)) and ay ~= by then
                        xs[#xs + 1] = ax + (y - ay) * (bx - ax) / (by - ay)
                    end
                end
                if #xs < 2 then return nil end
                table.sort(xs)
                return xs[1], xs[#xs]
            end, math.max(ys[1], ys[2], ys[3]), math.min(ys[1], ys[2], ys[3]), c, layer)
        end
        function chef.circle(x, y, r, c, layer)
            scan(function(yy)
                local d = r * r - (yy - y) ^ 2
                if d < 0 then return nil end
                d = math.sqrt(d)
                return x - d, x + d
            end, y + r, y - r, c, layer)
        end
        function chef.ring(x, y, r_in, r_out, c, layer)
            for yy = math.floor(y - r_out), math.ceil(y + r_out) - 1 do
                local dy = yy + 0.5 - y
                local outer = r_out * r_out - dy * dy
                if outer >= 0 then
                    outer = math.sqrt(outer)
                    local inner = r_in * r_in - dy * dy
                    if inner > 0 then
                        inner = math.sqrt(inner)
                        draw("rect", x - outer, yy, outer - inner, 1, c, layer)
                        draw("rect", x + inner, yy, outer - inner, 1, c, layer)
                    else
                        draw("rect", x - outer, yy, 2 * outer, 1, c, layer)
                    end
                end
            end
        end
        function chef.arc() return false end
        function chef.notify(text, seconds, r, g, b)
            if #m.notices >= 3 then table.remove(m.notices, 1) end
            m.notices[#m.notices + 1] = { text = string.upper(tostring(text)), until_time = now() + (tonumber(seconds) or 4), c = color(r, g, b) }
        end
        -- shared services
        function chef.after_startup(fn)
            if type(fn) ~= "function" then return false end
            if self.started then local ok, why = pcall(fn); if not ok then say(name, "after_startup: " .. tostring(why)) end; return true end
            self.waiting[#self.waiting + 1] = { fn = fn, mod = m }
            return true
        end
        function chef.save(key, value)
            if type(key) ~= "string" or not string.match(key, "^[%w_%.%-]+$") then return false end
            if value ~= nil and type(value) ~= "boolean" and type(value) ~= "number" and type(value) ~= "string" then return false end
            if type(value) == "string" and #value > 512 then return false end
            if m.values[key] ~= value then m.values[key] = value; m.values_dirty = true end
            return true
        end
        function chef.load(key, default)
            local v = m.values[key]
            if v == nil then return default end
            return v
        end
        function chef.share(key, value) self.shared[key] = value end
        function chef.shared(key) return self.shared[key] end
        function chef.on(event, fn)
            local unsubscribe = on(m, event, fn)
            return unsubscribe
        end
        chef.emit = emit
        function chef.require(target, want)
            local value = self.exports[target]
            if value == nil then return nil, target .. " is not running" end
            if want ~= nil then
                local have = type(value) == "table" and value.version or nil
                if not M.version_at_least(have, want) then return nil, target .. " " .. tostring(have) .. " is older than " .. tostring(want) end
            end
            return value
        end
        -- options and keys (HD2 Mod Setting GUI)
        local window = ctx.window
        local function groups()
            if not m.group then
                local tail = string.match(name, "([^/]+)$") or name
                local title = m.title or string.gsub(tail, "[_%-]", " ")
                m.group = window.group("chef:" .. name, title, "lll", false, nil, tail)
                m.keys = window.group("chef-keys:" .. name, title, "lll", true, m.group, tail .. "_keys")
            end
            return m.group, m.keys
        end
        function chef.title(text)
            local t = window.text(text, 64)
            if not t then return false end
            m.title = t
            if m.group then m.group.title = t; m.group.dirty = true; m.keys.dirty = true end
            return true
        end
        local function full(id) return name .. "#" .. tostring(id) end
        function chef.option(id, spec)
            if type(id) ~= "string" or not string.match(id, "^[%w_%.%-]+$") or type(spec) ~= "table" then return nil, "invalid option" end
            local g, k = groups()
            local copy = {}
            for key, v in pairs(spec) do copy[key] = v end
            if copy.type == "slider" and copy.step == nil then copy.step = 0 end
            local ok, why = window.register(copy.type == "key" and k or g, full(id), copy)
            if not ok then return nil, why end
            return window.get(full(id))
        end
        function chef.get(id) return window.get(full(id)) end
        function chef.set(id, value) return window.set(full(id), value) end
        function chef.on_change(id, fn)
            local unsubscribe, why = window.on_change(full(id), function(value) fn(value) end, 64)
            if not unsubscribe then return false, why end
            m.unsubscribe[#m.unsubscribe + 1] = unsubscribe
            return true
        end
        function chef.bind(id, default_key, label)
            local _, k = groups()
            local ok, why = window.register(k, full(id), { type = "key", label = label or id, default = default_key and string.lower(default_key) or "" })
            if not ok then return nil, why end
            local b = {}
            function b.key() local v = window.get(full(id)); return (v == nil or v == "") and "off" or v end
            function b.pressed() local v = window.get(full(id)); return v ~= nil and v ~= "" and keys.key_state(v, "pressed") end
            function b.down() local v = window.get(full(id)); return v ~= nil and v ~= "" and keys.key_state(v, "button") end
            return b
        end
        -- units, spawning
        local function alive(u) return u ~= nil and call("Unit.alive", u) == true end
        local function node_ok(u, node)
            local count = call("Unit.num_scene_graph_items", u)
            return type(count) ~= "number" or (node >= 1 and node <= count)
        end
        function chef.unit_kind() return nil end
        function chef.unit_alive(u) return alive(u) end
        function chef.unit_position(u, node)
            node = node or 1
            if not alive(u) or not node_ok(u, node) then return nil end
            local p = call("Unit.world_position", u, node)
            if p == nil then return nil end
            return p.x, p.y, p.z
        end
        function chef.unit_rotation(u, node)
            node = node or 1
            if not alive(u) or not node_ok(u, node) then return nil end
            local q = call("Unit.world_rotation", u, node)
            local f = q and call("Quaternion.forward", q)
            if f == nil then return nil end
            return f.x, f.y, f.z, math.atan2(-f.x, f.y)
        end
        function chef.unit_node(u, node_name)
            if not alive(u) or call("Unit.has_node", u, node_name) ~= true then return nil end
            return call("Unit.node", u, node_name)
        end
        function chef.units_near() return {} end
        function chef.spawn(id, x, y, z)
            local w = world()
            if w == nil then return nil, "no world" end
            local resource = id
            if type(id) == "string" and string.match(id, "^%x+$") and #id == 16 then resource = call("IdString64.from_hex", id) or id end
            if call("Application.can_get", "unit", resource) == false then return nil, tostring(id) .. " is not loaded" end
            local position = construct("Vector3", x or 0, y or 0, z or 0)
            local unit, why = call("World.spawn_unit", w, resource, position)
            if unit == nil then return nil, why or "spawn refused" end
            m.spawned[unit] = w
            return unit
        end
        function chef.despawn(u)
            local w = m.spawned[u]
            if not w then return false end
            m.spawned[u] = nil
            if alive(u) then call("World.destroy_unit", w, u) end
            return true
        end
        function chef.link(child, parent, node, child_node)
            local w = world()
            if not alive(child) or not alive(parent) or w == nil then return false end
            if type(node) == "string" then node = chef.unit_node(parent, node) end
            return call("World.link_unit", w, child, child_node or 1, parent, node or 1) ~= nil
        end
        function chef.unlink(child)
            local w = world()
            if not alive(child) or w == nil then return false end
            return call("World.unlink_unit", w, child) ~= nil
        end
        function chef.particles() return nil end
        function chef.stop_particles() return false end
        function chef.lights(u) if not alive(u) then return 0 end return call("Unit.num_lights", u) or 0 end
        function chef.light(u, i)
            if not alive(u) then return nil end
            local light = call("Unit.light", u, i)
            if light == nil then return nil end
            return {
                set_color = function(r, g, b) return call("Light.set_color", light, construct("Vector3", (r or 0) / 255, (g or 0) / 255, (b or 0) / 255)) end,
                set_intensity = function(v) return call("Light.set_intensity", light, v) end,
                set_enabled = function(on_off) return call("Light.set_enabled", light, on_off == true) end,
                set_falloff = function(a, b) call("Light.set_falloff_start", light, a); return call("Light.set_falloff_end", light, b) end,
                set_shadows = function(on_off) return call("Light.set_casts_shadows", light, on_off == true) end,
            }
        end
        -- timers
        function chef.after(s, fn) if type(fn) ~= "function" then return nil end return timer(m, tonumber(s) or 0, fn, true) end
        function chef.every(s, fn) if type(fn) ~= "function" then return nil end return timer(m, math.max(0, tonumber(s) or 0), fn, false) end
        function chef.spread(list, n, fn, done, opts)
            local i, t = 0, nil
            local world_at = self.world_id
            t = { every = 0, at = 0, errors = 0, spread = true, fn = function()
                if self.world_id ~= world_at and not (opts and opts.keep) then t.dead = true; if done then pcall(done, false) end; return end
                for _ = 1, math.max(1, n or 1) do
                    i = i + 1
                    if i > #list then t.dead = true; if done then pcall(done, true) end; return end
                    fn(list[i], i)
                end
            end }
            m.timers[#m.timers + 1] = t
            return { cancel = function() t.dead = true end, active = function() return not t.dead end, progress = function() return math.min(i, #list), #list end }
        end
        function chef.budget() return 2 end
        -- game and session
        function chef.setting() return nil end
        function chef.in_session() return session().in_session end
        function chef.is_host() return session().host end
        function chef.players() return session().players end
        function chef.peer_id() return session().peer end
        -- saved tables
        local function table_path(table_name)
            return ctx.log_dir and (ctx.log_dir .. "/lll_chef_data_" .. clean(name) .. "__" .. clean(tostring(table_name)) .. ".lua")
        end
        function chef.save_table(table_name, t)
            local out = {}
            local ok, why = pcall(serialize, t, 0, {}, out)
            if not ok then return false, why end
            local text = "return " .. table.concat(out)
            if #text > 262144 then return false, "more than 256 KB" end
            local okf, f = pcall(file.open, table_path(table_name) or "", "wb")
            if not okf or not f then return false, "file not written" end
            pcall(f.write, f, text); pcall(f.close, f)
            return true
        end
        function chef.load_table(table_name)
            local okf, f = pcall(file.open, table_path(table_name) or "", "rb")
            if not okf or not f then return nil, "not saved" end
            local _, text = pcall(f.read, f, "*a")
            pcall(f.close, f)
            local chunk, why = loadstring(type(text) == "string" and text or "", "=" .. tostring(table_name))
            if not chunk then return nil, why end
            setfenv(chunk, {})
            local ok, value = pcall(chunk)
            if not ok then return nil, value end
            return value
        end
        function chef.mods()
            local list = {}
            local states = ctx.modules and ctx.modules() or {}
            for mod_name, state in pairs(states) do list[#list + 1] = { name = mod_name, state = state } end
            table.sort(list, function(a, b) return a.name < b.name end)
            return list
        end
        return chef, m
    end
    -- ------------------------------------------------------------ running mods
    -- A copy of the game's globals for one mod: `_G` is that copy, engine tables are
    -- reachable through rawget, and the game's callbacks start as empty stubs.
    local function environment(chef)
        local env = {}
        for k, v in pairs(_G) do env[k] = v end
        env._G = env
        env.chef = chef
        local stubs = {}
        for _, hook in ipairs(HOOKS) do stubs[hook] = function() end; env[hook] = stubs[hook] end
        env.require = function(target, ...)
            if target == "ffi" or target == "jit" then error("the game has no " .. target .. " since 7.2.0", 2) end
            if self.exports[target] ~= nil then return self.exports[target] end
            if ctx.declared and ctx.declared(target) then return package.loaded[target] or true end
            return ctx.require(target, ...)
        end
        env.ffi, env.jit = false, false
        return env, stubs
    end
    local function hooks_of(result)
        if type(result) ~= "table" then return nil end
        local hooks = {}
        for _, hook in ipairs(HOOKS) do if type(rawget(result, hook)) == "function" then hooks[hook] = rawget(result, hook) end end
        return next(hooks) and hooks or nil
    end
    local function has_functions(result)
        if type(result) ~= "table" then return false end
        for _, v in pairs(result) do if type(v) == "function" then return true end end
        return false
    end
    -- An LLL record (API 1) for hooks: init once on enable, update (and render) each frame, shutdown on disable.
    local function record(name, hooks, m)
        local started = false
        return { live_lua_api = 1, name = name,
            on_enable = function()
                if hooks.init and not started then started = true; hooks.init() end
                return true
            end,
            on_update = function(dt)
                if hooks.update then hooks.update(dt) end
                if hooks.render then hooks.render() end
            end,
            on_disable = function()
                local ok, why = true, nil
                if hooks.shutdown then ok, why = pcall(hooks.shutdown) end
                if m then stop(m) end
                if not ok then say(name, "shutdown failed: " .. tostring(why)) end
                return true
            end }
    end
    self.record = record
    local function finish(name, m, value)
        if value == nil then value = true end
        self.exports[name] = value
        package.loaded[name] = value
        return value
    end
    -- `-- HD2-Addon:` written for Chef: `chef` is `...`, its globals are its own.
    function self.run_addon(name, source, info)
        local chef, m = self.object(name, info)
        local chunk, why = loadstring(source, "@" .. name)
        if not chunk then stop(m); error(why, 0) end
        local env, stubs = environment(chef)
        setfenv(chunk, env)
        local ok, result = pcall(chunk, chef)
        if not ok then stop(m); error(result, 0) end
        finish(name, m, result)
        local hooks = hooks_of(result)
        if not hooks and not has_functions(result) then
            hooks = {}
            for _, hook in ipairs(HOOKS) do
                if env[hook] ~= stubs[hook] and type(env[hook]) == "function" then
                    local captured = hook
                    hooks[hook] = function(...) return env[captured](...) end
                end
            end
            if not next(hooks) then hooks = nil end
        end
        return record(name, hooks or {}, m)
    end
    -- `-- HD2-Boot:`: global init, update, render and shutdown in the mod's own environment.
    function self.run_boot(name, source, info)
        local chef, m = self.object(name, info)
        local chunk, why = loadstring(source, "@" .. name)
        if not chunk then stop(m); error(why, 0) end
        local env, stubs = environment(chef)
        setfenv(chunk, env)
        local ok, result = pcall(chunk)
        if not ok then stop(m); error(result, 0) end
        finish(name, m, result)
        local hooks = {}
        for _, hook in ipairs(HOOKS) do
            if type(env[hook]) == "function" and env[hook] ~= stubs[hook] then
                local captured = hook
                hooks[hook] = function(...) return env[captured](...) end
            end
        end
        return record(name, hooks, m)
    end
    -- A Bingus-style mod (loaded by the game's require) that returned hooks and did not
    -- hook the game's update itself: drive its hooks, as Chef Shared Loader does.
    function self.adopt(name, result, update_before)
        if type(result) ~= "table" or rawget(result, "live_lua_api") ~= nil then return result end
        local hooks = hooks_of(result)
        if not hooks or rawget(_G, "update") ~= update_before then return result end
        self.exports[name] = result
        return record(name, hooks, nil)
    end
    function self.export(name, value) if value ~= nil then self.exports[name] = value end end
    function self.started_all()
        if self.started then return end
        self.started = true
        for _, w in ipairs(self.waiting) do
            local ok, why = pcall(w.fn)
            if not ok then say(w.mod.name, "after_startup: " .. tostring(why)) end
        end
        self.waiting = {}
        emit("startup")
    end
    -- ------------------------------------------------------------ each frame
    local function flush_draws()
        local t = now()
        local y = nil
        for _, m in pairs(self.mods) do
            for i = #m.notices, 1, -1 do
                local n = m.notices[i]
                if t > n.until_time then table.remove(m.notices, i)
                else
                    local w, h = 1920, 1080
                    local rw, rh = call("Gui.resolution")
                    if type(rw) == "number" then w, h = rw, rh end
                    y = (y or h - 60) - 28
                    draw("rect", w / 2 - 300, y - 6, 600, 26, color(10, 10, 10, 190), M.TOP + 930)
                    draw("text", w / 2 - 290, y, nil, nil, n.c, M.TOP + 931, n.text, 18)
                end
            end
        end
        local view = self.view
        if view == nil and #self.draws > 0 then view = ensure_view() end
        if view then pcall(view.draw, self.draws) end
        self.draws = {}
        if #self.lines > 0 then
            local w = world()
            if w ~= nil then
                local lines = self.line_object and self.line_world == w and self.line_object or nil
                if not lines then lines = call("World.create_line_object", w); self.line_object, self.line_world = lines, w end
                if lines ~= nil then
                    call("LineObject.reset", lines)
                    for _, l in ipairs(self.lines) do
                        local c = l[7]
                        call("LineObject.add_line", lines, construct("Color", c.a or 255, c.r, c.g, c.b), construct("Vector3", l[1], l[2], l[3]), construct("Vector3", l[4], l[5], l[6]))
                    end
                    call("LineObject.dispatch", w, lines)
                end
            end
            self.lines = {}
        end
    end
    function self.tick(dt)
        self.frame = self.frame + 1
        local w = world()
        if w ~= nil and w ~= world_seen then
            world_seen = w
            self.world_id = self.world_id + 1
            emit("world", self.world_id, false)
        end
        local t = now()
        for _, m in pairs(self.mods) do
            if not m.stopped then
                for i = #m.timers, 1, -1 do
                    local timer_entry = m.timers[i]
                    if timer_entry.dead then table.remove(m.timers, i)
                    elseif t >= timer_entry.at then
                        local ok, why = pcall(timer_entry.fn)
                        if not ok then
                            timer_entry.errors = timer_entry.errors + 1
                            say(m.name, "timer failed: " .. tostring(why))
                            if timer_entry.errors >= 20 or timer_entry.spread then timer_entry.dead = true end
                        end
                        if timer_entry.once then timer_entry.dead = true else timer_entry.at = t + timer_entry.every end
                    end
                end
                flush_settings(m, false)
            end
        end
        flush_draws()
    end
    function self.shutdown()
        emit("shutdown")
        for _, m in pairs(self.mods) do flush_settings(m, true) end
        if self.view and self.view.release then pcall(self.view.release) end
    end
    return self
end
return M
