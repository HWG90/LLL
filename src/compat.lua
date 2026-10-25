-- Mods written for Chef Shared Loader and Boot Mod Loader, on Live Lua Loader. One
-- object over src/compat/: start.lua orders the discovered entries with it and hands it
-- to the manager, which lets it load Chef-style entries, adopt returned hooks, tick
-- once a frame and shut down. Boot Mod Loader's mods are Bingus-style and load as before.
local Settings = LLL_COMPAT_SETTINGS or dofile("src/compat/settings_window.lua")
local Bingus = LLL_COMPAT_BINGUS or dofile("src/compat/bingus.lua")
local Chef = LLL_COMPAT_CHEF or dofile("src/compat/chef.lua")
local M = {}
local LOADER_NAMES = { ["chef-shared-loader"] = true, ["chef-loader"] = true }

-- o: platform, report(name, line), details (discovery: name -> detail), extras
-- (discovery: options/lang resources), engine() -> stingray, modules() -> states,
-- view() -> an LLL view, checked (the build gate passed), settings_dir, file, require.
function M.new(o)
    local self = { details = o.details or {}, loading = nil, options = {} }
    local function env(name)
        local v = os.getenv(name)
        return v and (string.gsub(string.gsub(v, "\\", "/"), "/+$", "")) or nil
    end
    local appdata, localdata = env("APPDATA"), env("LOCALAPPDATA")
    local dir = o.settings_dir or (appdata and appdata .. "/Arrowhead/Helldivers2")
    local window = Settings.new(dir, o.report, o.file)
    -- The addon registering: the one loading now, else the nearest archive chunk on the stack.
    local function caller()
        if self.loading then return self.loading end
        for level = 2, 40 do
            local info = debug.getinfo(level, "S")
            if not info then break end
            local name = string.match(info.source or "", "^@?(mods/[%w_%-/]+)$")
            if name then return name end
        end
        return nil
    end
    local bingus = Bingus.new(window, o.report, o.engine, caller,
        { checked = o.checked, mom_values = localdata and (localdata .. "/CowboyBingus/Helldivers2/Logs/ModOptionsMenu.values") })
    self.window, self.bingus = window, bingus
    -- A resource's source text, read from its archive (the envelope's length and type checked).
    function self.read(detail)
        local platform = o.platform
        if not detail or not platform or not platform.data then return nil, "no archive location" end
        local path = platform.data .. "/" .. detail.archive
        local data
        if platform.archive then
            local reader = platform.archive(path)
            if not reader then return nil, "archive not opened" end
            local ok, value = pcall(reader.read, detail.offset, detail.length)
            pcall(reader.close)
            data = ok and value or nil
        elseif platform.read then
            local whole = platform.read(path)
            data = whole and string.sub(whole, detail.offset + 1, detail.offset + detail.length)
        end
        if type(data) ~= "string" or #data ~= detail.length then return nil, "resource unreadable" end
        local a, b, c, d = string.byte(data, 1, 4)
        local kind = string.byte(data, 5)
        if a + b * 256 + c * 65536 + d * 16777216 ~= detail.length - 8 or kind ~= 2 then return nil, "not a source resource" end
        return string.sub(data, 9)
    end
    -- Arsenal options folders (`-- HD2-Options:`): tables merged one level deep per mod.
    for _, extra in ipairs(o.extras or {}) do
        if extra.kind == "options" then
            local ok, why = pcall(function()
                local source = assert(self.read(extra))
                local chunk = assert(loadstring(source, "@" .. extra.target .. " (options)"))
                setfenv(chunk, {})
                local value = chunk()
                assert(type(value) == "table", "options must return a table")
                local into = self.options[extra.target] or {}
                self.options[extra.target] = into
                for k, v in pairs(value) do
                    if type(v) == "table" and type(into[k]) == "table" then
                        for k2, v2 in pairs(v) do into[k][k2] = v2 end
                    else
                        into[k] = v
                    end
                end
            end)
            if not ok and o.report then pcall(o.report, extra.target, "options file refused: " .. tostring(why)) end
        end
    end
    local chef = Chef.new({ engine = o.engine, report = o.report, window = window, keys = bingus, log_dir = dir,
                            previous_dir = localdata, modules = o.modules, view = o.view, file = o.file,
                            require = o.require or require, declared = function(name) return self.details[name] ~= nil end })
    self.chef = chef
    -- Requirements first (`-- HD2-Requires:`); a mod whose requirement is missing, too old or in
    -- a circle is left out with the reason. Everything else keeps its discovery order.
    function self.order(names)
        local present, ordered, refused, state = {}, {}, {}, {}
        for _, name in ipairs(names) do present[name] = true end
        local function visit(name, chain)
            if state[name] == "done" then return true end
            if state[name] == "refused" then return false, name .. " is not started" end
            if state[name] == "visiting" then return false, "requirements in a circle: " .. chain end
            state[name] = "visiting"
            local detail = self.details[name]
            for _, need in ipairs(detail and detail.requires or {}) do
                local why
                if LOADER_NAMES[need.name] then
                    if need.version and not Chef.version_at_least(Chef.VERSION, need.version) then
                        why = name .. " needs Chef Shared Loader " .. need.version .. " (this layer is " .. Chef.VERSION .. ")"
                    end
                elseif not present[need.name] then
                    why = name .. " needs " .. need.name .. (need.version and (" " .. need.version .. " or newer") or "") .. " (not installed)"
                else
                    local ok, reason = visit(need.name, chain .. " -> " .. need.name)
                    if not ok then why = name .. " needs " .. need.name .. ": " .. tostring(reason) end
                end
                if why then
                    state[name] = "refused"
                    refused[#refused + 1] = { name = name, reason = why }
                    return false, why
                end
            end
            state[name] = "done"
            ordered[#ordered + 1] = name
            return true
        end
        for _, name in ipairs(names) do visit(name, name) end
        return ordered, refused
    end
    function self.handles(name)
        local detail = self.details[name]
        return detail ~= nil and (detail.kind == "boot" or detail.chef == true)
    end
    function self.require(name)
        local detail = self.details[name]
        local source, why = self.read(detail)
        if not source then error(why, 0) end
        local info = { options = self.options[name] or {} }
        if detail.kind == "boot" then return chef.run_boot(name, source, info) end
        return chef.run_addon(name, source, info)
    end
    function self.adopt(name, result, update_before)
        if self.handles(name) then return result end
        chef.export(name, result)
        return chef.adopt(name, result, update_before)
    end
    function self.extend(compat) return bingus.extend(compat) end
    -- Look-alikes of Mod Options/Bindings Menu, unless the real menu is among the entries.
    function self.install(entries)
        local skip = {}
        for _, name in ipairs(entries or {}) do
            if string.find(name, "mod_options_menu", 1, true) then skip.options = true end
            if string.find(name, "mod_bindings_menu", 1, true) then skip.bindings = true end
        end
        return bingus.install(skip)
    end
    function self.started() chef.started_all() end
    function self.tick(dt) bingus.tick(dt); chef.tick(dt) end
    function self.shutdown() chef.shutdown() end
    function self.after_shutdown() bingus.after_shutdown() end
    return self
end
return M
