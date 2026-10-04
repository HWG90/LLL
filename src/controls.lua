-- Both frontends bind this authoritative loader state; neither owns selection settings.
return function(loader, live, report)
    local self = { bindings = {}, groups = {}, group_count = 0, expanded = {} }
    local syncing = false
    local function readable(value)
        return value:gsub("[_-]+", " "):gsub("(%l)(%u)", "%1 %2"):gsub("(%a)([%w]*)", function(a, b)
            return a:upper() .. b
        end)
    end
    local function folder(name)
        local entry = live.catalog[name]
        local metadata = entry and entry.metadata
        local declared = loader.records and loader.records[name]
        if LLL_METADATA then
            local fields = LLL_METADATA.fields(declared)
            if not (metadata and metadata.author) and fields.author then
                metadata = fields
            end
        end
        if metadata and metadata.author then
            return "declared/" .. metadata.author,
                metadata.author,
                metadata.name or name:match("([^/]+)$")
        end
        local author, child = name:match("^mods/([^/]+)/(.+)$")
        if author then
            return "mods/" .. author, author, metadata and metadata.name or child
        end
        local entry = live.catalog[name]
        if entry then
            local root = (entry.source_root or entry.dir):gsub("\\", "/"):gsub("/+$", "")
            return root, root:match("([^/]+)$") or root, metadata and metadata.name or entry.id
        end
        local parent, leaf = name:match("^(.*)/([^/]+)$")
        if parent then
            return parent, parent:match("([^/]+)$"), leaf
        end
        return nil, nil, name
    end
    local function definition()
        local categories = {}
        local seen = {}
        local pages = {
            {
                id = "overview",
                name = "Overview",
                dynamic = true,
                controls = {
                    { type = "section", label = "LIVE LUA LOADER R20" },
                    {
                        type = "button",
                        id = "open_manager",
                        label = "Loader window",
                        button_label = "Open manager",
                        on_activate = function()
                            assert(loader.open_manager, "Manager unavailable")
                            loader.open_manager()
                        end,
                    },
                    {
                        type = "button",
                        id = "refresh",
                        label = "Refresh discovery",
                        button_label = "Refresh",
                        on_activate = function()
                            loader.refresh()
                            self.refresh()
                            return "Discovery refreshed"
                        end,
                    },
                    {
                        type = "toggle",
                        id = "auto_reload",
                        label = "Auto-reload Lua changes",
                        default = loader.auto_reload and loader.auto_reload() or false,
                        disabled = not loader.set_auto_reload,
                        description = "Reload enabled lifecycle scripts after an edit stays unchanged across two scans. Compile before cleanup; invalid edits preserve the working instance. Saved in LLL.cfg. Manual reload remains available.",
                        on_change = function(value)
                            local ok, why = loader.set_auto_reload(value)
                            assert(ok, why)
                            self.refresh()
                        end,
                    },
                    {
                        type = "text",
                        label = "Live scripts support enable, disable and reload. Archive addons without cleanup require a restart.",
                    },
                },
            },
        }
        for index, name in ipairs(loader.order) do
            local path, parent, child = folder(name)
            local category
            if path then
                if not self.groups[path] then
                    self.group_count = self.group_count + 1
                    self.groups[path] = "author_" .. self.group_count
                end
                category = self.groups[path]
                if not seen[category] then
                    seen[category] = true
                    categories[#categories + 1] = { id = category, name = parent }
                end
            end
            local target = name
            local id = "entry_" .. index
            local managed = live.catalog[name] ~= nil
            local controls =
                { { type = "text", label = loader.modules[name] or "unknown", description = name } }
            controls[#controls + 1] = {
                type = "toggle",
                id = id .. "_enabled",
                label = "Enabled",
                default = loader.modules[name] == "loaded",
                disabled = not managed,
                description = managed
                        and "Changes apply immediately and save to LLL.cfg. Disable runs cleanup."
                    or "Archive addon without a supported live lifecycle. Use your mod manager and restart.",
                on_change = function(value)
                    if syncing then
                        return
                    end
                    local ok, why = loader.set_enabled(target, value)
                    self.refresh()
                    if not ok then
                        report(target, "Selection refused: " .. tostring(why))
                        error(why)
                    end
                end,
            }
            controls[#controls + 1] = {
                type = "button",
                id = id .. "_reload",
                label = "Reload script",
                button_label = "Reload",
                disabled = not managed or loader.modules[name] ~= "loaded",
                description = "Compile first, clean up, then load the edited source. Unresolved cleanup requires restart.",
                on_activate = function()
                    local ok, why = loader.reload(target)
                    self.refresh()
                    assert(ok, why)
                    return "Reloaded " .. target
                end,
            }
            pages[#pages + 1] = {
                id = id,
                name = readable(child),
                category = category,
                dynamic = true,
                controls = controls,
            }
        end
        return {
            id = "lll_management",
            name = "Live Lua Loader",
            description = "R20 mod manager. F9 opens the independent window. All changes use shared loader state.",
            categories = categories,
            pages = pages,
        }
    end
    local function author_pages(spec)
        local pages = { spec.pages[1] }
        local assigned = {}
        for _, category in ipairs(spec.categories) do
            local rows = {}
            for index = 2, #spec.pages do
                local page = spec.pages[index]
                if page.category == category.id then
                    assigned[index] = true
                    rows[#rows + 1] = { type = "section", label = page.name }
                    for _, control in ipairs(page.controls) do
                        rows[#rows + 1] = control
                    end
                end
            end
            pages[#pages + 1] = {
                id = category.id,
                name = category.name,
                style = "author",
                dynamic = true,
                controls = rows,
            }
        end
        local other = {}
        for index = 2, #spec.pages do
            if not assigned[index] then
                local page = spec.pages[index]
                other[#other + 1] = { type = "section", label = page.name }
                for _, control in ipairs(page.controls) do
                    other[#other + 1] = control
                end
            end
        end
        if #other > 0 then
            pages[#pages + 1] =
                { id = "other_mods", name = "Other mods", dynamic = true, controls = other }
        end
        return { id = spec.id, name = spec.name, description = spec.description, pages = pages }
    end
    local function origin_pages(spec)
        local snapshot = (LLL_PROVENANCE or dofile("src/provenance.lua"))(loader, live)
        local pages, categories, by_name = { spec.pages[1] }, {}, {}
        for index = 2, #spec.pages do
            by_name[spec.pages[index].controls[1].description] = spec.pages[index]
        end
        local groups = {
            { "lll_live", "LLL live scripts" },
            { "lll_archive", "Archive addons via LLL" },
            { "mdl", "MDL registry" },
            { "bingus", "Bingus registry" },
            { "unknown", "Unknown / conflicting owner" },
        }
        for _, group in ipairs(groups) do
            local count, loaded = 0, 0
            for _, row in ipairs(snapshot) do
                if row.owner == group[1] then
                    count = count + 1
                    if row.loaded then
                        loaded = loaded + 1
                    end
                end
            end
            if count > 0 then
                categories[#categories + 1] = {
                    id = "source_" .. group[1],
                    name = group[2] .. " (" .. loaded .. " loaded / " .. count .. ")",
                }
            end
        end
        for index, row in ipairs(snapshot) do
            local old = by_name[row.name]
            self.external_ids = self.external_ids or {}
            if not old and not self.external_ids[row.name] then
                self.external_count = (self.external_count or 0) + 1
                self.external_ids[row.name] = "external_" .. self.external_count
            end
            local details = "Runtime owner: "
                .. row.owner
                .. "\nSource: "
                .. row.source
                .. "\nResource: "
                .. row.name
            local controls = {
                { type = "text", label = "Status: " .. row.state, description = details },
                {
                    type = "text",
                    label = "Source: " .. row.source,
                    description = "Discovery location is not evidence of which loader ran the mod.",
                },
            }
            local managed = old and live.catalog[row.name] and (row.owner == "lll_live")
            if old then
                for position = 2, #old.controls do
                    local copy = {}
                    for key, value in pairs(old.controls[position]) do
                        copy[key] = value
                    end
                    if copy.type == "toggle" then
                        copy.default = row.loaded
                    end
                    if not managed then
                        copy.disabled = true
                    end
                    controls[#controls + 1] = copy
                end
            end
            local short = row.loaded and "Loaded"
                or row.state == "loading" and "Loading"
                or row.state == "disabled" and "Disabled"
                or row.state == "not installed" and "Not installed"
                or row.state == "discovered" and "Discovered"
                or "Needs attention"
            pages[#pages + 1] = {
                id = old and old.id or self.external_ids[row.name],
                name = "[" .. short .. "] " .. (old and old.name or readable(
                    row.name:match("([^/]+)$") or row.name
                )),
                category = "source_" .. row.owner,
                dynamic = true,
                controls = controls,
            }
        end
        return {
            id = spec.id,
            name = spec.name,
            description = spec.description,
            categories = categories,
            pages = pages,
        }
    end
    function self.provenance_summary()
        local rows = (LLL_PROVENANCE or dofile("src/provenance.lua"))(loader, live)
        local count = 0
        for _, row in ipairs(rows) do
            if row.loaded then
                count = count + 1
            end
        end
        return "Loaded: " .. count .. "   Listed: " .. #rows
    end
    function self.summary()
        local loaded, failed = 0, 0
        for _, name in ipairs(loader.order) do
            local state = loader.modules[name]
            if state == "loaded" then
                loaded = loaded + 1
            elseif state ~= "disabled" and state ~= "not installed" then
                failed = failed + 1
            end
        end
        return "Loaded: "
            .. loaded
            .. "   Failed / pending: "
            .. failed
            .. "   Total: "
            .. #loader.order
    end
    local function enclosed(spec)
        local rows = {
            spec.pages[1].controls[1],
            spec.pages[1].controls[2],
            spec.pages[1].controls[3],
            spec.pages[1].controls[4],
        }
        local function child(page)
            local target = page.id
            rows[#rows + 1] = {
                type = "button",
                id = "select_" .. target,
                label = "    " .. page.name,
                button_label = "Select",
                description = page.controls[1].description .. "\n" .. page.controls[1].label,
                on_activate = function()
                    self.selected = target
                    self.refresh()
                end,
            }
            if self.selected == target then
                for _, control in ipairs(page.controls) do
                    rows[#rows + 1] = control
                end
            end
        end
        for _, category in ipairs(spec.categories) do
            local target = category.id
            rows[#rows + 1] = {
                type = "button",
                id = "expand_" .. target,
                label = category.name,
                button_label = self.expanded[target] and "[-]" or "[+]",
                on_activate = function()
                    self.expanded[target] = not self.expanded[target]
                    self.refresh()
                end,
            }
            if self.expanded[target] then
                for index = 2, #spec.pages do
                    local page = spec.pages[index]
                    if page.category == target then
                        child(page)
                    end
                end
            end
        end
        for index = 2, #spec.pages do
            if not spec.pages[index].category then
                child(spec.pages[index])
            end
        end
        local loaded, failed, disabled, missing = 0, 0, 0, 0
        for _, name in ipairs(loader.order) do
            local state = loader.modules[name]
            if state == "loaded" then
                loaded = loaded + 1
            elseif state == "disabled" then
                disabled = disabled + 1
            elseif state == "not installed" then
                missing = missing + 1
            else
                failed = failed + 1
            end
        end
        rows[#rows + 1] = { type = "section", label = "Loader status" }
        rows[#rows + 1] = {
            type = "text",
            label = "Loaded: " .. loaded .. "   Failed / pending: " .. failed,
            description = "Counts reflect loader lifecycle state. Successful initialization does not prove gameplay behavior. Select a mod above for its current status and source path.",
        }
        rows[#rows + 1] = {
            type = "text",
            label = "Disabled: "
                .. disabled
                .. "   Not installed: "
                .. missing
                .. "   Total: "
                .. #loader.order,
        }
        rows[#rows + 1] = {
            type = "text",
            label = "Discovery diagnostics",
            description = loader.discovery_diagnostics
                or "Archive and live-script discovery; Refresh checks for new scripts.",
        }
        return {
            id = spec.id,
            name = spec.name,
            description = spec.description,
            pages = { { id = "mods", name = "Mods", dynamic = true, controls = rows } },
        }
    end
    function self.bind(api, inside)
        if not api or type(api.register) ~= "function" then
            return
        end
        for _, binding in ipairs(self.bindings) do
            if binding.api == api then
                if inside then
                    binding.inside = inside
                    binding.signature = nil
                end
                return binding
            end
        end
        local binding = { api = api, inside = inside }
        self.bindings[#self.bindings + 1] = binding
        return binding
    end
    function self.follow(api)
        if self.provider == api then
            return
        end
        if self.provider then
            for index = #self.bindings, 1, -1 do
                local binding = self.bindings[index]
                if binding.api == self.provider then
                    if binding.handle then
                        pcall(binding.handle.unregister)
                    end
                    table.remove(self.bindings, index)
                end
            end
        end
        self.provider = api
        self.bind(api, "authors")
    end
    function self.refresh()
        local spec = definition()
        local signature = ""
        for _, group in ipairs(spec.categories) do
            signature = signature .. group.id .. group.name
        end
        for _, page in ipairs(spec.pages) do
            signature = signature .. page.id .. page.name .. (page.category or "")
        end
        for _, binding in ipairs(self.bindings) do
            local api = binding.api
            local bound_spec = spec
            local bound_signature = signature
            if binding.inside then
                bound_spec = binding.inside == "origins" and origin_pages(spec)
                    or binding.inside == "authors" and author_pages(spec)
                    or enclosed(spec)
                bound_signature = ""
                for _, category in ipairs(bound_spec.categories or {}) do
                    bound_signature = bound_signature .. category.id .. category.name
                end
                for _, page in ipairs(bound_spec.pages) do
                    bound_signature = bound_signature
                        .. page.id
                        .. page.name
                        .. (page.category or "")
                    for _, control in ipairs(page.controls) do
                        bound_signature = bound_signature
                            .. (control.id or "")
                            .. control.label
                            .. (control.button_label or "")
                            .. tostring(control.disabled)
                            .. tostring(control.default)
                    end
                end
            end
            if
                binding.signature ~= bound_signature
                or not binding.handle
                or not (api.mods and api.mods.lll_management)
            then
                if binding.handle then
                    pcall(binding.handle.unregister)
                end
                local ok, handle = pcall(api.register, bound_spec)
                if ok then
                    binding.handle = handle
                    binding.signature = bound_signature
                else
                    report("LLL manager", tostring(handle))
                end
            end
            local mod = api.mods and api.mods.lll_management
            if mod and binding.handle and not binding.inside then
                syncing = true
                if mod.controls.auto_reload then
                    mod.values.auto_reload = loader.auto_reload and loader.auto_reload() or false
                end
                for index, name in ipairs(loader.order) do
                    local page = mod.pages[index + 1]
                    local toggle = mod.controls["entry_" .. index .. "_enabled"]
                    local reload = mod.controls["entry_" .. index .. "_reload"]
                    page.controls[1].label = loader.modules[name] or "unknown"
                    toggle.disabled = live.catalog[name] == nil
                    reload.disabled = live.catalog[name] == nil or loader.modules[name] ~= "loaded"
                    -- Native core rejects writes to disabled controls; update read-only display directly.
                    mod.values[toggle.id] = loader.modules[name] == "loaded"
                end
                syncing = false
                api.revision = api.revision + 1
            end
        end
    end
    function self.primary()
        local api = self.provider
        local mod = api and api.mods and api.mods.lll_management
        if not mod then
            return
        end
        if type(api.surface) ~= "function" then
            return mod
        end
        local surface = api.surface(mod.handle)
        local copy = {}
        for key, value in pairs(mod) do
            copy[key] = value
        end
        copy.handle = {
            get = surface.get,
            preview = surface.preview,
            set = surface.set,
            edit = surface.set,
            queue = surface.activate,
            activate = surface.activate,
            confirm = surface.confirm,
            discard = surface.discard,
            reset = function(key)
                return surface.set(key, mod.controls[key].default)
            end,
        }
        return copy
    end
    function self.close()
        for _, b in ipairs(self.bindings) do
            if b.handle then
                pcall(b.handle.unregister)
            end
        end
        self.bindings = {}
    end
    loader.changed = self.refresh
    return self
end
