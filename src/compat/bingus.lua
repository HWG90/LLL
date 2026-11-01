-- Boot Mod Loader's additions to the Bingus Shared Loader API (on_shutdown, game) and
-- Chef Shared Loader's (on_update), plus look-alikes of Mod Options Menu v1.2 and Mod
-- Bindings Menu v2.3 for mods written for those loaders. Their rows live in HD2 Mod
-- Setting GUI (see compat/settings_window.lua): the in-game tabs needed ffi.
local M = {}
local MOUSE = { ["mouse 3"] = { "middle button **", "middle", "middle button" },
                ["mouse 4"] = { "x button 1 **", "extra_1", "x button 1" },
                ["mouse 5"] = { "x button 2 **", "extra_2", "x button 2" } }
local FROM_MBM = { middle = "mouse 3", extra_1 = "mouse 4", extra_2 = "mouse 5" }
M.MOUSE, M.FROM_MBM = MOUSE, FROM_MBM

-- One alternative of a Mod Bindings Menu spec as the window's key name and its trigger;
-- nil for what the window cannot hold (controller, modifiers, wheel, left/right mouse).
local function alternative(a)
    local button, device, trigger = a, "keyboard", "press"
    if type(a) == "table" then
        if type(a.modifiers) == "table" and a.modifiers[1] ~= nil then return nil end
        button, device, trigger = a.button, a.device or "keyboard", a.trigger or "press"
    end
    if type(button) ~= "string" or (trigger ~= "press" and trigger ~= "release" and trigger ~= "hold") then return nil end
    button = string.lower(button)
    if device == "mouse" then
        button = FROM_MBM[button]
        if button == nil then return nil end
    elseif device ~= "keyboard" then
        return nil
    end
    return button, trigger
end
function M.default(spec)
    if spec == nil then return "", "press" end
    local list = (type(spec) == "table" and spec.button == nil) and spec or { spec }
    for _, a in ipairs(list) do
        local name, trigger = alternative(a)
        if name ~= nil then return name, trigger end
    end
    return "", "press"
end

-- engine(): the stingray table. caller(): the addon name registering, or nil.
function M.new(window, report, engine, caller, paths)
    local self = { updates = {}, update_order = {}, shutdowns = {}, frame = 0, keys = {}, bindings = {} }
    local function say(message) if report then pcall(report, "Bingus compatibility", message) end end
    local function sr() local ok, value = pcall(engine); return ok and type(value) == "table" and value or nil end
    -- ------------------------------------------------------------ Bingus API additions
    function self.extend(compat)
        compat.on_shutdown = function(a, b)
            local fn = type(a) == "function" and a or b
            if type(fn) ~= "function" then return false, "on_shutdown needs a function" end
            self.shutdowns[#self.shutdowns + 1] = fn
            return true
        end
        compat.on_update = function(id, fn)
            if type(id) ~= "string" or (fn ~= nil and type(fn) ~= "function") then return false, "on_update needs an id and a function" end
            if self.updates[id] == nil and fn ~= nil then self.update_order[#self.update_order + 1] = id end
            self.updates[id] = fn
            return true
        end
        local game = { checked = paths and paths.checked == true }
        local engine_table = sr()
        local ok, id = pcall(function() return engine_table.Application.build_identifier() end)
        if ok and type(id) == "string" then game.build_identifier = id end
        compat.game = game
        return compat
    end
    -- ------------------------------------------------------------ Mod Options Menu look-alike
    local old_values
    local function old(id)
        if old_values == nil then
            old_values = {}
            local path = paths and paths.mom_values
            local okf, f = pcall(io.open, path or "", "rb")
            if okf and f then
                local _, text = pcall(f.read, f, "*a")
                pcall(f.close, f)
                for k, v in string.gmatch(type(text) == "string" and text or "", "([^\t\r\n]+)\t([^\r\n]*)") do old_values[k] = v end
            end
        end
        return old_values[id]
    end
    local function tail_of(addon) return addon and string.match(addon, "([%w_%-]+)$") or nil end
    local function options_group(spec, addon)
        local title
        if spec.mod ~= nil then
            title = window.text and window.text(spec.mod, 40) or nil
            if title == nil then return nil, "invalid mod name" end
        end
        local mod_id = spec.mod_id
        if mod_id ~= nil and (type(mod_id) ~= "string" or #mod_id > 64 or not string.find(mod_id, "^[%w_%.%-/:]+$")) then
            return nil, "invalid mod_id"
        end
        local tail = tail_of(addon)
        title = title or (tail and (string.gsub(tail, "[_%-]", " "))) or "Unnamed mod"
        local key = mod_id or addon or title
        local g = window.group("mom:" .. key, title, "mom", false, nil, mod_id or tail or title)
        if addon then
            self.titles = self.titles or {}
            self.titles[addon] = g
            local keys = window.groups["mbm:" .. addon]
            if keys then keys.partner = g; keys.dirty = true end
        end
        return g
    end
    local options = {
        api = 1, version = 3, max_mods = 1000, max_options = 1000, revision = "LLL-compat", window = "HD2 Mod Setting GUI",
        register_option = function(id, spec)
            local ok, done, why = pcall(function()
                if type(spec) ~= "table" then return false, "invalid option registration" end
                local g, reason = options_group(spec, caller())
                if not g then return false, reason end
                if spec.type == "key" then return false, "type must be toggle, choice or slider" end
                return window.register(g, id, spec, old)
            end)
            if not ok then return false, tostring(done) end
            return done, why
        end,
        get = function(id) return window.get(id) end,
        set = function(id, value) return window.set(id, value) end,
        on_change = function(id, fn) local ok, why = window.on_change(id, fn); return ok and true or false, why end,
        ready = function() return true end,
    }
    self.options = options
    -- ------------------------------------------------------------ Mod Bindings Menu look-alike
    local function ids(device)
        local t = self.keys[device]
        if t then return t end
        t = {}
        local f = type(device) == "table" and rawget(device, "button_name") or nil
        if type(f) == "function" then
            for id = 0, 511 do
                local ok, n = pcall(f, id)
                if ok and type(n) == "string" and t[string.lower(n)] == nil then t[string.lower(n)] = id end
            end
        end
        self.keys[device] = t
        return t
    end
    -- A key name -> { {device, id}, ... }: keyboard names on the keyboard, "mouse 3/4/5" on either device.
    function self.resolve(name)
        if name == nil or name == "" then return nil end
        local e = sr()
        if not e then return nil end
        local kb, mouse = rawget(e, "Keyboard"), rawget(e, "Mouse")
        local devices = MOUSE[name] and { kb, mouse } or { kb }
        local found = {}
        for _, n in ipairs(MOUSE[name] or { name }) do
            for _, d in ipairs(devices) do
                local id
                -- Builds name the lookup button_index or button_id.
                for _, field in ipairs({ "button_index", "button_id" }) do
                    local f = type(d) == "table" and rawget(d, field) or nil
                    if id == nil and type(f) == "function" then
                        local ok, value = pcall(f, n)
                        if ok and type(value) == "number" then id = value end
                    end
                end
                if id == nil and type(d) == "table" then id = ids(d)[n] end
                if id ~= nil then found[#found + 1] = { d, id } end
            end
        end
        return found[1] and found or nil
    end
    -- Keys count only while the game window has focus.
    function self.allowed()
        if self.guard_frame == self.frame then return self.guard_ok end
        self.guard_frame = self.frame
        local ok = true
        local e = sr()
        local window_table = e and rawget(e, "Window")
        local f = type(window_table) == "table" and rawget(window_table, "has_focus") or nil
        if type(f) == "function" then
            local okf, focus = pcall(f)
            if okf and focus == false then ok = false end
        end
        self.guard_ok = ok
        return ok
    end
    function self.key_state(name, how)
        local resolved = self.resolve(name)
        if not resolved then return false end
        for _, button in ipairs(resolved) do
            local f = rawget(button[1], how)
            if type(f) == "function" then
                local ok, v = pcall(f, button[2])
                if ok and (v == true or (type(v) == "number" and v > 0.5)) then return self.allowed() end
            end
        end
        return false
    end
    local function is_down(id)
        local b = self.bindings[id]
        if b == nil then return nil end
        return self.key_state(window.get(id), b.how)
    end
    self.is_down = is_down
    local bindings
    bindings = {
        api = 1, version = 4, capacity = 1000, revision = 0, loader = "Live Lua Loader", window = "HD2 Mod Setting GUI",
        extended = { devices = { "keyboard", "mouse" }, triggers = { "press", "release", "hold" }, count = 0 },
        register_binding = function(id, label, slot, opts)
            local ok, done, why = pcall(function()
                if type(id) ~= "string" or id == "" or #id > 96 or string.find(id, "%c")
                    or (slot ~= nil and type(slot) ~= "number") or (opts ~= nil and type(opts) ~= "table") then
                    return false, "invalid binding registration"
                end
                opts = opts or {}
                local text = type(label) == "number" and id or label
                local had = self.bindings[id]
                if had then
                    if had.label == text and had.slot == slot then return true end
                    return false, "binding already registered differently"
                end
                local addon = caller()
                local category = opts.category ~= nil and window.text(opts.category, 64) or nil
                if opts.category ~= nil and category == nil then return false, "invalid binding category" end
                local tail = tail_of(addon)
                local title = category or (tail and (string.gsub(tail, "[_%-]", " "))) or "Unnamed mod"
                local partner = addon and self.titles and self.titles[addon] or nil
                local g = window.group("mbm:" .. (addon or category or "?"), title, "mbm", true, partner, tail or title)
                local default, trigger = M.default(opts.default)
                local registered, reason = window.register(g, id, { type = "key", label = text, default = default })
                if not registered then return false, reason end
                self.bindings[id] = { label = text, slot = slot, trigger = trigger,
                                      how = trigger == "hold" and "button" or (trigger == "release" and "released" or "pressed") }
                bindings.revision = bindings.revision + 1
                bindings.extended.count = bindings.extended.count + 1
                return true
            end)
            if not ok then return false, tostring(done) end
            return done, why
        end,
        is_down = is_down,
        ready = function() return true end,
        poll = function(list, out)
            if type(list) ~= "table" or type(out) ~= "table" then return false, "invalid poll arguments" end
            for _, field in ipairs({ "down", "pressed", "released", "last" }) do
                if out[field] == nil then out[field] = {} elseif type(out[field]) ~= "table" then return false, "invalid poll arguments" end
            end
            for i = 1, #list do
                local down = is_down(list[i])
                local was = out.last[i] == true
                out.down[i] = down
                out.pressed[i] = down == true and not was
                out.released[i] = was and down ~= true
                out.last[i] = down == true
            end
            return true
        end,
        set_binding = function(id, spec)
            if self.bindings[id] == nil then return false, "not an extended binding" end
            local name
            if spec == nil then name = window.option_of(id).default
            elseif type(spec) == "table" and spec.button == nil and spec[1] == nil then name = ""
            else
                name = M.default(spec)
                if name == "" then return false, "invalid binding" end
            end
            return window.set(id, name)
        end,
        binding = function(id)
            local b = self.bindings[id]
            if b == nil then return nil end
            local name = window.get(id)
            if name == nil or name == "" then return {} end
            local mouse = MOUSE[name] ~= nil
            local button = name
            if mouse then for k, v in pairs(FROM_MBM) do if v == name then button = k end end end
            return { { mouse and "mouse" or "keyboard", button, modifiers = {}, trigger = b.trigger } }
        end,
        binding_info = function(id)
            local b = self.bindings[id]
            if b == nil then return nil end
            local name, o = window.get(id), window.option_of(id)
            return { backend = "extended", state = (name == "" and o.default ~= "") and "cleared" or (name == o.default and "default" or "set") }
        end,
    }
    self.bindings_api = bindings
    -- Set the look-alikes where nothing else defines them. `skip` names a real menu mod
    -- among the entries about to load, which then keeps its own global.
    function self.install(skip)
        local installed = {}
        if rawget(_G, "ModOptionsMenu") == nil and not (skip and skip.options) then
            rawset(_G, "ModOptionsMenu", options); installed[#installed + 1] = "ModOptionsMenu"
        end
        if rawget(_G, "ModBindingsMenu") == nil and not (skip and skip.bindings) then
            rawset(_G, "ModBindingsMenu", bindings); installed[#installed + 1] = "ModBindingsMenu"
        end
        if installed[1] then say("look-alikes set: " .. table.concat(installed, ", ") .. " (rows in HD2 Mod Setting GUI)") end
        return installed
    end
    function self.tick(dt)
        self.frame = self.frame + 1
        for _, id in ipairs(self.update_order) do
            local fn = self.updates[id]
            if fn then
                local ok, why = pcall(fn, dt)
                if not ok then self.updates[id] = nil; say("on_update " .. id .. " dropped: " .. tostring(why)) end
            end
        end
        window.tick(dt)
    end
    -- After the game's shutdown chain: each on_shutdown function, then the window's last write.
    function self.after_shutdown()
        for _, fn in ipairs(self.shutdowns) do
            local ok, why = pcall(fn)
            if not ok then say("on_shutdown failed: " .. tostring(why)) end
        end
        self.shutdowns = {}
        window.tick(0, true)
    end
    return self
end
return M
