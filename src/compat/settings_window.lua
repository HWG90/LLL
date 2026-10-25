-- Options and keys of mods written for Mod Options Menu, Mod Bindings Menu and Chef
-- Shared Loader, edited in HD2 Mod Setting GUI outside the game. The files are the
-- ones Boot Mod Loader writes (format: github.com/pat-pat-patrick/boot-mod-loader), so
-- a player's values carry between loaders. In the game's settings folder:
--   <name>_options.json  the list, written when it changes;
--   <name>_settings.txt  key=value lines ending "#end", written whole by the window
--                        and read again once a second (a changed value reaches the
--                        mod's on_change callbacks);
--   <name>.log           one line per change applied, for the window's status line.
local M = {}
M.NONE = setmetatable({}, { __tostring = function() return "[]" end })
M.MAX_CHOICES = 32

function M.text(value, limit)
    if type(value) == "function" then
        local ok, result = pcall(value)
        if not ok then return nil end
        value = result
    end
    if type(value) ~= "string" then return nil end
    local text = string.gsub(string.gsub(string.gsub(value, "%c", " "), "^%s+", ""), "%s+$", "")
    local _, chars = string.gsub(text, "[^\128-\191]", "")
    if text == "" or chars > limit then return nil end
    return text
end

function M.json(v)
    if v == M.NONE then return "[]" end
    local kind = type(v)
    if kind == "string" then
        return '"' .. string.gsub(v, '[%c"\\]', function(c)
            if c == '"' then return '\\"' elseif c == "\\" then return "\\\\" elseif c == "\n" then return "\\n" end
            return string.format("\\u%04x", string.byte(c))
        end) .. '"'
    elseif kind == "number" then
        if v ~= v or v == math.huge or v == -math.huge then return "null" end
        return string.format("%.10g", v)
    elseif kind == "boolean" then
        return v and "true" or "false"
    elseif kind == "table" then
        local out = {}
        if #v > 0 then
            for _, x in ipairs(v) do out[#out + 1] = M.json(x) end
            return "[" .. table.concat(out, ",") .. "]"
        end
        local keys = {}
        for k in pairs(v) do keys[#keys + 1] = k end
        table.sort(keys)
        for _, k in ipairs(keys) do out[#out + 1] = M.json(k) .. ":" .. M.json(v[k]) end
        return "{" .. table.concat(out, ",") .. "}"
    end
    return "null"
end

local function snap(o, v)
    if type(v) ~= "number" or not (v > -math.huge and v < math.huge) then return nil end
    local steps = o.step > 0 and math.floor((v - o.min) / o.step + 0.5) or nil
    local s = steps and o.min + steps * o.step or v
    s = math.min(o.max, math.max(o.min, s))
    return tonumber(string.format("%." .. o.decimals .. "f", s))
end
M.snap = snap

local function valid(o, v)
    if o.kind == "toggle" then return type(v) == "boolean" end
    if o.kind == "key" then return type(v) == "string" end
    if type(v) ~= "number" or v ~= v then return false end
    if o.kind == "choice" then return v % 1 == 0 and v >= 1 and v <= #o.choices end
    return v >= o.min and v <= o.max
end
M.valid = valid

local function encode(o, v)
    if o.kind == "toggle" then return v and "true" or "false" end
    if o.kind == "key" then return v end
    if o.kind == "choice" then return tostring(v) end
    return string.format("%.6g", v)
end

local function decode(o, text)
    if type(text) ~= "string" then return nil end
    text = string.match(text, "^%s*(.-)%s*$")
    if o.kind == "key" then return string.lower(text) end
    if o.kind == "toggle" then
        if text == "true" then return true elseif text == "false" then return false end
        return nil
    end
    local v = tonumber(text)
    if v ~= nil and o.kind == "slider" then v = snap(o, v) end
    if v ~= nil and valid(o, v) then return v end
    return nil
end
M.decode = decode

-- An option from a registration (Mod Options Menu's rules; "key" for bindings), or nil and why.
function M.option(id, spec)
    if type(id) ~= "string" or id == "" or #id > 96 or string.find(id, "%c") or type(spec) ~= "table" then
        return nil, "invalid option registration"
    end
    local o = { id = id, kind = spec.type, label = M.text(spec.label, 64), profile = spec.profile == true, gap = spec.gap == true }
    if o.label == nil then return nil, "invalid option registration" end
    if spec.description ~= nil then
        o.description = M.text(spec.description, 400)
        if o.description == nil then return nil, "invalid description" end
    end
    if o.kind == "toggle" then
        if spec.default ~= nil and type(spec.default) ~= "boolean" then return nil, "invalid default" end
        o.default = spec.default == true
    elseif o.kind == "choice" then
        local list = spec.choices
        if type(list) ~= "table" or #list < 2 or #list > M.MAX_CHOICES then
            return nil, "choices must list 2 to " .. M.MAX_CHOICES .. " names"
        end
        o.choices = {}
        for i, c in ipairs(list) do
            o.choices[i] = M.text(c, 48)
            if o.choices[i] == nil then return nil, "invalid choice name" end
        end
        o.default = spec.default == nil and 1 or spec.default
    elseif o.kind == "slider" then
        local lo, hi, step = spec.min, spec.max, spec.step or 1
        if type(lo) ~= "number" or type(hi) ~= "number" or type(step) ~= "number" or not (lo < hi)
            or not (step >= 0) or step > hi - lo or not (lo > -math.huge and hi < math.huge) then
            return nil, "slider needs min < max and 0 <= step <= max - min"
        end
        local d = 0
        while step > 0 and d < 3 and math.abs(step * 10 ^ d - math.floor(step * 10 ^ d + 0.5)) > 1e-6 do d = d + 1 end
        if step == 0 then d = 3 end
        if lo % 1 ~= 0 and d < 1 then d = 1 end
        o.min, o.max, o.step, o.decimals = lo, hi, step, d
        o.default = spec.default == nil and lo or spec.default
        if type(o.default) == "number" then o.default = snap(o, o.default) end
    elseif o.kind == "key" then
        o.default = type(spec.default) == "string" and string.lower(spec.default) or ""
    else
        return nil, "type must be toggle, choice, slider or key"
    end
    if not valid(o, o.default) then return nil, "invalid default" end
    return o
end

local function same(a, b)
    if a.kind ~= b.kind or a.default ~= b.default then return false end
    if a.kind == "choice" then return #a.choices == #b.choices end
    if a.kind == "slider" then return a.min == b.min and a.max == b.max and a.step == b.step end
    return true
end

function M.new(dir, report, file)
    file = file or io
    local self = { dir = dir, groups = {}, list = {}, names = {}, options = {}, values = {}, callbacks = {}, at = 0, every = 1, text = M.text }
    local function say(message) if report then pcall(report, "Settings window", message) end end
    local function read_values(path)
        local ok, f = pcall(file.open, path, "rb")
        if not ok or f == nil then return {} end
        local okr, text = pcall(f.read, f, "*a")
        pcall(f.close, f)
        local out = {}
        if okr and type(text) == "string" then
            for k, v in string.gmatch(text, "([^=\r\n]+)=([^\r\n]*)") do out[k] = v end
        end
        return out
    end
    -- A list for one mod, file <prefix>_<base> (Boot Mod Loader's names, so values carry
    -- over). `keys` lists are shown as a Keys page under the title of the same mod's
    -- options (`partner`), as the window merges lists by title.
    function self.group(key, title, prefix, keys, partner, base)
        local g = self.groups[key]
        if g then return g end
        base = string.match(string.gsub(string.lower(base or key), "[^%w]+", "_"), "^_*(.-)_*$")
        if base == "" then base = "mod" end
        local name = prefix .. "_" .. base
        while self.names[name] do name = name .. "_" end
        self.names[name] = true
        g = { key = key, title = title, name = name, keys = keys == true, partner = partner, options = {}, by_key = {},
              dirty = true, write = false, file_values = dir and read_values(dir .. "/" .. name .. "_settings.txt") or {} }
        self.groups[key] = g
        self.list[#self.list + 1] = g
        return g
    end
    -- Register an option (spec as Mod Options Menu, plus type "key") in a list.
    -- `carry(id)` may return a value saved by an older menu, used when the window has none.
    function self.register(g, id, spec, carry)
        local o, why = M.option(id, spec)
        if not o then return false, why end
        local had = self.options[id]
        if had then
            if same(had, o) then return true end
            return false, "option already registered differently"
        end
        local key = string.gsub(id, "[^%w_]", "_")
        while g.by_key[key] ~= nil do key = key .. "_" end
        o.key, o.group = key, g
        g.options[#g.options + 1] = o
        g.by_key[key] = o
        self.options[id] = o
        local v = decode(o, g.file_values[key])
        if v == nil then
            if carry then v = decode(o, carry(id)) end
            g.write = true
        end
        if v == nil then v = o.default end
        self.values[id] = v
        if spec.profiles == true then g.profiles = true end
        g.dirty = true
        return true
    end
    function self.get(id) return self.values[id] end
    function self.option_of(id) return self.options[id] end
    function self.set(id, value)
        local o = self.options[id]
        if not o then return false, "unknown option" end
        if o.kind == "slider" and type(value) == "number" then value = snap(o, value) end
        if o.kind == "key" and type(value) == "string" then value = string.lower(value) end
        if not valid(o, value) then return false, "invalid value" end
        if self.values[id] ~= value then
            self.values[id] = value
            o.group.write = true
            for _, fn in ipairs(self.callbacks[id] or {}) do
                local ok, err = pcall(fn, value, id)
                if not ok then say("on_change of " .. id .. " failed: " .. tostring(err)) end
            end
        end
        return true
    end
    function self.on_change(id, fn, limit)
        if type(id) ~= "string" or type(fn) ~= "function" then return false, "invalid callback" end
        local list = self.callbacks[id] or {}
        if limit and #list >= limit then return false, "too many callbacks" end
        list[#list + 1] = fn
        self.callbacks[id] = list
        return function()
            for i = #list, 1, -1 do if list[i] == fn then table.remove(list, i) end end
        end
    end
    local function profile_key(g)
        for _, o in ipairs(g.options) do if o.profile then return o.key end end
        for _, o in ipairs(g.options) do
            if o.kind == "choice" and string.match(o.id, "([^%.]+)$") == "profile" then return o.key end
        end
        return nil
    end
    function self.export(g)
        if not dir then return end
        local opts = {}
        for _, o in ipairs(g.options) do
            local e = { key = o.key, type = o.kind, default = o.default, min = o.min, max = o.max, step = o.step,
                        name = o.label, hint = o.description, gap = o.gap or nil }
            if o.choices then
                e.choices = {}
                for i, c in ipairs(o.choices) do e.choices[i] = c end
            end
            opts[#opts + 1] = e
        end
        local title, pages = g.title, M.NONE
        if g.keys then
            title = g.partner and g.partner.title or g.title
            local keys = {}
            for i, o in ipairs(g.options) do keys[i] = o.key end
            pages = { { name = "Keys", keys = keys } }
        end
        local text = M.json({ title = title, version = "", settings = g.name .. "_settings.txt", pages = pages,
                              options = opts, menu_owned = M.NONE, profile = profile_key(g), profiles = g.profiles or nil }) .. "\n"
        local path = dir .. "/" .. g.name .. "_options.json"
        local okr, f = pcall(file.open, path, "rb")
        if okr and f ~= nil then
            local _, old = pcall(f.read, f, "*a")
            pcall(f.close, f)
            if old == text then return end
        end
        local okw, w = pcall(file.open, path, "wb")
        if not okw or w == nil then say(g.title .. ": " .. g.name .. "_options.json not written") return end
        pcall(w.write, w, text)
        pcall(w.close, w)
        say(string.format("%s: %d %s -> %s_options.json", title, #g.options, g.keys and "key(s)" or "option(s)", g.name))
    end
    local function text_of(g)
        local lines = {}
        for _, o in ipairs(g.options) do lines[#lines + 1] = o.key .. "=" .. encode(o, self.values[o.id]) end
        lines[#lines + 1] = "#end"
        return table.concat(lines, "\n") .. "\n"
    end
    local function write(g, path)
        local text = text_of(g)
        local ok, w = pcall(file.open, path, "wb")
        if not ok or w == nil then return false end
        pcall(w.write, w, text)
        pcall(w.close, w)
        g.text = text
        return true
    end
    -- One list: written when new or changed here, else read again; window changes applied.
    function self.tick_group(g)
        if g.dirty then g.dirty = false; self.export(g) end
        if not dir then return end
        local path = dir .. "/" .. g.name .. "_settings.txt"
        if g.write then g.write = false; write(g, path) end
        local ok, f = pcall(file.open, path, "rb")
        if not ok or f == nil then
            if not g.failed then write(g, path) end
            g.failed = true
            return
        end
        g.failed = nil
        local okr, text = pcall(f.read, f, "*a")
        pcall(f.close, f)
        if not okr or type(text) ~= "string" or text == g.text then return end
        if not string.find(text, "\n#end%s*$") then return end
        g.text = text
        local found, profile = {}, profile_key(g)
        for k, v in string.gmatch(text, "([^=\r\n]+)=([^\r\n]*)") do
            local o = g.by_key[k]
            local value = o and decode(o, v)
            if value ~= nil and self.values[o.id] ~= value then
                found[#found + 1] = { o = o, value = value }
                if k == profile then found = { found[#found] } break end
            end
        end
        if found[1] ~= nil and found[1].o.key == profile then g.write = true end
        local changed = {}
        for _, c in ipairs(found) do
            self.values[c.o.id] = c.value
            changed[#changed + 1] = c.o.key .. "=" .. encode(c.o, c.value)
            for _, fn in ipairs(self.callbacks[c.o.id] or {}) do
                local okc, err = pcall(fn, c.value, c.o.id)
                if not okc then say("on_change of " .. c.o.id .. " failed: " .. tostring(err)) end
            end
        end
        if g.write then g.write = false; write(g, path) end
        if #changed == 0 then return end
        local line = os.date("%H:%M:%S ") .. "settings window: applied " .. table.concat(changed, " ")
        say(g.title .. ": " .. line)
        local okl, lf = pcall(file.open, dir .. "/" .. g.name .. ".log", "a")
        if okl and lf ~= nil then pcall(lf.write, lf, line .. "\n"); pcall(lf.close, lf) end
    end
    function self.tick(dt, force)
        self.at = self.at - ((type(dt) == "number" and dt > 0 and dt < 10) and dt or 0.016)
        if self.at > 0 and not force then return end
        self.at = self.every
        for _, g in ipairs(self.list) do
            local ok, err = pcall(self.tick_group, g)
            if not ok and not g.said then g.said = true; say(g.name .. ": " .. tostring(err)) end
        end
    end
    return self
end
return M
