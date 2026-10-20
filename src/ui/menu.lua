-- MCM layout/controller. Drawing is isolated from registry and settings storage.
local M = {}
local geometry = LLL_UI_GEOMETRY or dofile("src/ui/geometry.lua")
local text = LLL_UI_TEXT or dofile("src/ui/text.lua")
local theme = LLL_UI_THEME or dofile("src/ui/theme.lua")
local input_module = LLL_UI_INPUT or dofile("src/ui/input.lua")
local render_module = LLL_UI_RENDER or dofile("src/ui/render.lua")
M.flow, M.rich, M.width = text.flow, text.rich, text.width
function M.new(api, measure)
    local self = {
        visible = false,
        focus = "mods",
        selected = 1,
        page = 1,
        row = 1,
        mod_scroll = 0,
        scroll = 0,
        notice = "",
        capture = false,
    }
    local state = {}
    state.tree_expanded = {}
    state.tree_scroll = 0
    state.tree_manual = false
    state.tree_max = 0
    state.nav_bounds = nil
    state.nav_scroll = 0
    state.nav_mod = nil
    state.expanded = {}
    state.wheel_bounds = nil
    state.wheel_remainder = 0
    state.manual_scroll = false

    self.sidebar_width = 330
    self.help_scroll = 0
    state.help_bounds = nil
    state.help_key = nil
    state.hits = {}
    state.current = nil
    state.held = {}
    local active
    function self.expand_all()
        for _,mod in ipairs(api.list()) do
            state.tree_expanded[mod.id]=true
            for _,category in ipairs(mod.categories or {}) do state.expanded[mod.id.."/"..category.id]=true end
        end
    end
    function self.collapse_all()
        state.tree_expanded={};state.expanded={};state.tree_scroll=0;self.context_menu=nil
    end
    function self.open_context(x,y,actions)
        self.context_menu={x=x,y=y,actions=actions,selected=1}
    end
    function self.apply()
        local mod,page=active()
        if not mod or not page then return false end
        if not page.require_confirmation then self.notice="Settings apply immediately";return true end
        local called,ok,why=pcall(mod.handle.confirm,page.id)
        self.notice=called and ok and (why or "Applied and saved") or tostring(called and why or ok)
        return called and ok
    end
    function self.recover()
        self.visible = false
        self.context_menu=nil
        self.capture = false
        self.text_edit = nil
        self.color_picker = nil
        self.dropdown = nil
        self.mouse_held = false
        state.scroll_drag = nil
        self.pointer_x,self.pointer_y=nil,nil
        state.drag = nil
        state.window_drag = nil
        state.resize_drag = nil
        state.color_drag = nil
        state.palette_drag = nil
        state.split_drag = nil
        self.notice = "Menu closed after an error; "..theme.key_name(api.menu_toggle_key or 45).." reopens it"
    end
    active=function()
        local mods = api.list()
        self.selected = math.max(1, math.min(self.selected, #mods))
        state.current = mods[self.selected]
        if state.current then
            self.page = math.max(1, math.min(self.page, #state.current.pages))
            return state.current, state.current.pages[self.page]
        end
    end
    local function selectable(page)
        local rows = {}
        for _, c in ipairs(page and page.controls or {}) do
            if c.type ~= "text" and c.type ~= "section" then
                rows[#rows + 1] = c
            end
        end
        return rows
    end
    local function change(c, direction)
        if not state.current or c.disabled then
            return
        end
        local h = state.current.handle
        local ok, err = true
        if c.type == "button" then
            if direction == 0 then
                ok, err = (h.queue or h.activate)(c.id)
            end
        elseif c.type == "input" then
            self.text_edit =
                { mod = state.current, control = c, text = (h.preview or h.get)(c.id), replace = true }
            self.notice = "Type name; Enter accepts"
            return
        elseif c.type == "keybind" then
            self.capture = c
            self.notice = "Press a key. Escape cancels."
            return
        elseif c.type == "color" then
            self.color_picker =
                { mod = state.current, control = c, rgb = api.color_rgb((h.preview or h.get)(c.id)) }
            return
        else
            local v = (h.preview or h.get)(c.id)
            if c.type == "toggle" then
                v = not v
            elseif c.type == "choice" then
                v = (v - 1 + (direction == 0 and 1 or direction)) % #c.choices + 1
            elseif c.type == "slider" then
                v = math.max(
                    c.min,
                    math.min(c.max, v + (direction == 0 and 1 or direction) * c.step)
                )
            else
                return
            end
            ok, err = (h.edit or h.set)(c.id, v)
        end
        self.notice = ok
                and (c.page and c.page.require_confirmation and "Pending confirmation" or "Saved")
            or ("Could not save: " .. tostring(err))
    end
    function self.finish_color_field()
        local e = self.text_edit
        if not e or not e.color_channel then
            return true
        end
        if not self.color_picker then
            self.text_edit = nil
            return true
        end
        if e.color_channel == "hex" then
            local ok, rgb = pcall(api.color_rgb, e.text)
            if not ok then
                self.notice = "Use six HEX digits"
                return false
            end
            self.color_picker.rgb = rgb
        else
            local n = tonumber(e.text)
            if not n or n % 1 ~= 0 or n < 0 or n > 255 then
                self.notice = "RGB channels: integers 0-255"
                return false
            end
            self.color_picker.rgb[e.color_channel] = n
        end
        self.color_picker.hue, self.color_picker.saturation, self.color_picker.brightness =
            api.rgb_hsv(self.color_picker.rgb)
        self.text_edit = nil
        self.notice = "Color preview updated"
        return true
    end
    function self.commit_color()
        if not self.finish_color_field() then
            return
        end
        local p = self.color_picker
        if not p then
            return
        end
        local called, ok, err = pcall(p.mod.handle.edit or p.mod.handle.set, p.control.id, p.rgb)
        if called and ok then
            self.notice = p.control.page.require_confirmation and "Pending confirmation" or "Saved"
            self.color_picker = nil
        else
            self.notice = tostring(called and err or ok)
        end
    end
    function self.key(code, ctrl, shift)
        if self.capture then
            local mod=active();local c=self.capture;self.capture=false
            if code~=27 and mod then
                local called,ok,why=pcall(mod.handle.edit or mod.handle.set,c.id,code)
                self.notice=called and ok and "Binding saved" or tostring(called and why or ok)
            end
            return
        end
        if self.context_menu then
            local popup=self.context_menu
            if code==27 then self.context_menu=nil
            elseif code==38 or code==40 then popup.selected=math.max(1,math.min(#popup.actions,popup.selected+(code==38 and -1 or 1)))
            elseif code==13 then local action=popup.actions[popup.selected];self.context_menu=nil;if action and not action.disabled then action.run() end end
            return
        end
        if self.visible and code==(api.apply_key or 9) and self.text_edit and not self.text_edit.color_channel then
            self.key(13,ctrl,shift);if not self.text_edit then self.apply() end;return
        end
        if code == 121 then
            state.drag = nil
            state.window_drag = nil
        state.resize_drag = nil
            self.dropdown = nil
            self.text_edit = nil
            self.color_picker = nil
        end
        if code == 121 then
            self.visible = not self.visible
            self.capture = false
            return
        end -- Internal toggle event; frontend maps the configured physical key.
        if not self.visible then
            return
        end
        if self.text_edit then
            local e = self.text_edit
            if code == 27 then
                self.text_edit = nil
                return
            end
            if code == (api.apply_key or 9) and e.color_channel then
                self.finish_color_field()
                if not self.text_edit then
                    self.commit_color()
                    if not self.color_picker then self.apply() end
                end
                return
            end
            if code == 13 then
                if e.color_channel then
                    self.finish_color_field()
                    return
                end
                local value = e.control.type == "input" and e.text or tonumber(e.text)
                if
                    e.control.type ~= "input"
                    and (
                        not value
                        or value ~= value
                        or value < e.control.min
                        or value > e.control.max
                    )
                then
                    self.notice = "Enter a number from " .. e.control.min .. " to " .. e.control.max
                    return
                end
                local called, ok, err =
                    pcall(e.mod.handle.edit or e.mod.handle.set, e.control.id, value)
                if not called or not ok then
                    self.notice = tostring(called and err or ok)
                    return
                end
                self.notice = e.control.page
                        and e.control.page.require_confirmation
                        and "Pending confirmation"
                    or "Saved"
                self.text_edit = nil
                return
            end
            if ctrl and code == 65 then
                e.replace = true
                return
            end
            if code == 8 then
                if e.replace then
                    e.text = ""
                else
                    e.text = string.sub(e.text, 1, -2)
                end
                e.replace = false
                return
            end
            if code == 46 then
                e.text = ""
                e.replace = false
                return
            end
            local char
            if code >= 48 and code <= 57 then
                char = string.char(code)
            elseif code >= 96 and code <= 105 then
                char = tostring(code - 96)
            elseif code == 189 or code == 109 then
                char = "-"
            elseif code == 190 or code == 110 then
                char = "."
            end
            if e.control and e.control.type == "input" then
                if code >= 65 and code <= 90 then
                    char = e.control.free_text and (shift and string.char(code) or string.lower(string.char(code))) or string.char(code)
                elseif code == 32 then
                    char = " "
                end
            end
            if e.color_channel == "hex" and code >= 65 and code <= 70 then
                char = string.char(code)
            end
            if e.control and e.control.free_text then
                local plain={[186]=";",[187]="=",[188]=",",[191]="/",[192]="`",[219]="[",[220]="\\",[221]="]",[222]="'"}
                local shifted={[186]=":",[187]="+",[188]="<",[189]="_",[190]=">",[191]="?",[192]="~",[219]="{",[220]="|",[221]="}",[222]='"'}
                char=(shift and shifted[code] or plain[code]) or char
            end
            if char and not ctrl then
                if e.replace then
                    e.text = ""
                    e.replace = false
                end
                if #e.text < (e.control and e.control.type == "input" and (e.control.max_length or 48) or 24) then
                    e.text = e.text .. char
                end
            end
            return
        end
        if self.color_picker then
            if code == 27 then
                self.color_picker = nil
                return
            end
            if code == 13 or code==(api.apply_key or 9) then
                self.commit_color()
                if code==(api.apply_key or 9) and not self.color_picker then self.apply() end
            end
            return
        end
        if self.dropdown then
            local d = self.dropdown
            if code == 27 then
                self.dropdown = nil
                return
            end
            if code == 38 or code == 40 or code == 33 or code == 34 then
                local step = code == 33 and -8 or (code == 34 and 8 or (code == 38 and -1 or 1))
                d.selected = math.max(1, math.min(#d.control.choices, d.selected + step))
                if d.selected <= d.scroll then
                    d.scroll = d.selected - 1
                end
                if d.selected > d.scroll + 8 then
                    d.scroll = d.selected - 8
                end
                return
            end
            if code == 13 or code==(api.apply_key or 9) then
                local ok, err = (d.mod.handle.edit or d.mod.handle.set)(d.control.id, d.selected)
                self.notice = ok
                        and (d.control.page and d.control.page.require_confirmation and "Pending confirmation" or "Saved")
                    or tostring(err)
                self.dropdown = nil
                if ok and code==(api.apply_key or 9) then self.apply() end
                return
            end
            return
        end
        state.manual_scroll = false
        state.tree_manual = false
        local mod, page = active()
        if not mod then
            if code == 27 then
                self.visible = false
            end
            return
        end
        if self.capture then
            local c = self.capture
            self.capture = false
            if code ~= 27 then
                local ok, err = (mod.handle.edit or mod.handle.set)(c.id, code)
                self.notice = ok
                        and (c.page and c.page.require_confirmation and "Pending confirmation" or "Binding saved")
                    or tostring(err)
            end
            return
        end
        if code == 27 then
            self.visible = false
            return
        end
        if code==(api.apply_key or 9) then self.apply();return end
        if code == (api.focus_key or 117) then
            self.focus = self.focus == "mods" and "settings" or "mods"
            return
        end
        if code == 33 or code == 34 then
            self.page = (self.page - 1 + (code == 33 and -1 or 1)) % #mod.pages + 1
            self.row = 1
            self.scroll = 0
            return
        end
        if self.focus == "mods" then
            if code == 38 or code == 40 then
                self.selected =
                    math.max(1, math.min(#api.list(), self.selected + (code == 38 and -1 or 1)))
                self.page = 1
                self.row = 1
                self.scroll = 0
            elseif code == 13 or code == 39 then
                self.focus = "settings"
            end
        else
            local rows = selectable(page)
            self.row = math.max(1, math.min(self.row, #rows))
            local c = rows[self.row]
            if code == 38 or code == 40 then
                self.row = math.max(1, math.min(#rows, self.row + (code == 38 and -1 or 1)))
            elseif c and (code == 37 or code == 39 or code == 13) then
                change(c, code == 13 and 0 or (code == 37 and -1 or 1))
            end
        end
    end
    function self.sidebar()
        local rows = {}
        for index, mod in ipairs(api.list()) do
            local open = state.tree_expanded[mod.id] == true
            rows[#rows + 1] = { kind = "mod", mod = mod, index = index, open = open, depth = 0 }
            if open then
                local nodes = self.navigation(mod)
                for _, node in ipairs(nodes) do
                    if
                        not (
                            #(mod.categories or {}) == 1
                            and mod.categories[1].name == "HUD"
                            and node.kind == "category"
                            and node.depth == 0
                        )
                    then
                        local item = {}
                        for k, v in pairs(node) do
                            item[k] = v
                        end
                        item.mod = mod
                        item.mod_index = index
                        item.depth = node.depth + 1
                        if #(mod.categories or {}) == 1 and mod.categories[1].name == "HUD" then
                            item.depth = math.max(1, item.depth - 1)
                        end
                        rows[#rows + 1] = item
                    end
                end
            end
        end
        return rows
    end
    function self.navigation(mod)
        local rows = {}
        local function children(parent, depth)
            for _, category in ipairs(mod.categories or {}) do
                if category.parent == parent then
                    local key = mod.id .. "/" .. category.id
                    local open = state.expanded[key] == true
                    rows[#rows + 1] = {
                        kind = "category",
                        category = category,
                        key = key,
                        open = open,
                        depth = depth,
                    }
                    if open then
                        children(category.id, depth + 1)
                    end
                end
            end
            for index, page in ipairs(mod.pages) do
                if page.category == parent then
                    rows[#rows + 1] = { kind = "page", page = page, index = index, depth = depth }
                end
            end
        end
        children(nil, 0)
        return rows
    end
    state.text_age = {}
    state.elapsed = 0
    function self.advance(dt)
        if self.visible then
            state.elapsed = state.elapsed + math.max(0, math.min(1, tonumber(dt) or 0))
        else
            state.elapsed = 0
            state.text_age = {}
        end
    end
    local context = {self=self,state=state,api=api,measure=measure,menu=M,
        geometry=geometry,theme=theme,active=active,selectable=selectable,change=change}
    input_module.install(context)
    render_module.install(context)
    return self
end
return M
