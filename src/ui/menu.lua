-- MCM layout/controller. Drawing is isolated from registry and settings storage.
local M = {}
local geometry = LLL_UI_GEOMETRY or dofile("src/ui/geometry.lua")
-- Whole-glyph viewport: never split UTF-8 or draw outside the allotted width.
function M.flow(value, width, size, time, measure)
    local glyphs = {}
    for glyph in string.gmatch(tostring(value), "[%z\1-\127\194-\244][\128-\191]*") do
        glyphs[#glyphs + 1] = glyph
    end
    local widths, total = {}, 0
    for i, g in ipairs(glyphs) do
        widths[i] = (measure and measure(g, size)) or size * 0.62
        total = total + widths[i]
    end
    if total <= width then
        return tostring(value), false
    end
    local last = #glyphs
    local tail = 0
    while last > 1 and tail + widths[last] <= width do
        tail = tail + widths[last]
        last = last - 1
    end
    last = math.min(#glyphs, last + 1)
    local travel = math.max(0, last - 1)
    local duration = travel * 0.25
    local phase = math.max(0, time or 0) % (duration * 2 + 3)
    local offset = phase < 1.5 and 0
        or phase < 1.5 + duration and math.floor((phase - 1.5) / 0.25)
        or phase < 3 + duration and travel
        or travel - math.floor((phase - 3 - duration) / 0.25)
    local first = math.max(1, math.min(last, offset + 1))
    local visible, used = {}, 0
    for i = first, #glyphs do
        if used + widths[i] > width then
            break
        end
        visible[#visible + 1] = glyphs[i]
        used = used + widths[i]
    end
    return table.concat(visible), true
end
-- Renderer-independent lightweight rich text: paragraphs, lists, headings and emphasis.
function M.rich(value, width, size, measure)
    local lines = {}
    value = string.gsub(tostring(value or ""), "\r\n", "\n")
    for paragraph in string.gmatch((value .. "\n"), "(.-)\n") do
        local heading, body = string.match(paragraph, "^(#+)%s+(.+)$")
        local font = heading and size + 3 or size
        body = body or paragraph
        body = string.gsub(body, "^%s*[-*]%s+", "• ")
        local spans, line, used = {}, {}, 0
        local strong, emphasis = false, false
        local function flush()
            lines[#lines + 1] = { spans = line, size = font }
            line = {}
            used = 0
        end
        local function add(word, style)
            local glyphs = {}
            for glyph in string.gmatch(word, "[%z\1-\127\194-\244][\128-\191]*") do
                glyphs[#glyphs + 1] = glyph
            end
            for _, glyph in ipairs(glyphs) do
                local gw = (measure and measure(glyph, font)) or font * 0.62
                if used + gw > width and #line > 0 then
                    flush()
                end
                if not (glyph == " " and #line == 0) then
                    local last = line[#line]
                    if last and last.style == style then
                        last.text = last.text .. glyph
                        last.width = last.width + gw
                    else
                        line[#line + 1] = { text = glyph, style = style, width = gw }
                    end
                    used = used + gw
                end
            end
        end
        local index = 1
        while index <= #body do
            if string.sub(body, index, index + 1) == "**" then
                strong = not strong
                index = index + 2
            elseif string.sub(body, index, index) == "*" then
                emphasis = not emphasis
                index = index + 1
            else
                local stop = string.find(body, "*", index, true) or (#body + 1)
                local chunk = string.sub(body, index, stop - 1)
                for word in string.gmatch(chunk, "%S+%s*") do
                    local ww = 0
                    for glyph in string.gmatch(word, "[%z\1-\127\194-\244][\128-\191]*") do
                        ww = ww + ((measure and measure(glyph, font)) or font * 0.62)
                    end
                    if used + ww > width and #line > 0 then
                        flush()
                    end
                    add(
                        word,
                        heading and "heading"
                            or strong and "strong"
                            or emphasis and "emphasis"
                            or "plain"
                    )
                end
                index = stop
            end
        end
        flush()
    end
    return lines
end
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
    local tree_expanded = {}
    local tree_scroll = 0
    local tree_manual = false
    local tree_max = 0
    local nav_bounds
    local nav_scroll = 0
    local nav_mod
    local expanded = {}
    local wheel_bounds
    local wheel_remainder = 0
    local manual_scroll = false
    local drag, window_drag, color_drag, palette_drag, split_drag, resize_drag
    self.sidebar_width = 330
    self.help_scroll = 0
    local help_bounds
    local help_key
    local hits = {}
    local current
    local held = {}
    function self.recover()
        self.visible = false
        self.capture = false
        self.text_edit = nil
        self.color_picker = nil
        self.dropdown = nil
        self.mouse_held = false
        drag = nil
        window_drag = nil
        resize_drag = nil
        color_drag = nil
        palette_drag = nil
        split_drag = nil
        self.notice = "Menu closed after an error; F10 reopens it"
    end
    local function active()
        local mods = api.list()
        self.selected = math.max(1, math.min(self.selected, #mods))
        current = mods[self.selected]
        if current then
            self.page = math.max(1, math.min(self.page, #current.pages))
            return current, current.pages[self.page]
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
        if not current or c.disabled then
            return
        end
        local h = current.handle
        local ok, err = true
        if c.type == "button" then
            if direction == 0 then
                ok, err = (h.queue or h.activate)(c.id)
            end
        elseif c.type == "input" then
            self.text_edit =
                { mod = current, control = c, text = (h.preview or h.get)(c.id), replace = true }
            self.notice = "Type name; Enter accepts"
            return
        elseif c.type == "keybind" then
            self.capture = c
            self.notice = "Press a key. Escape cancels."
            return
        elseif c.type == "color" then
            self.color_picker =
                { mod = current, control = c, rgb = api.color_rgb((h.preview or h.get)(c.id)) }
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
    function self.key(code, ctrl)
        if code == 121 then
            drag = nil
            window_drag = nil
        resize_drag = nil
            self.dropdown = nil
            self.text_edit = nil
            self.color_picker = nil
        end
        if code == 121 then
            self.visible = not self.visible
            self.capture = false
            return
        end -- F10
        if not self.visible then
            return
        end
        if self.text_edit then
            local e = self.text_edit
            if code == 27 then
                self.text_edit = nil
                return
            end
            if code == 9 and e.color_channel then
                self.finish_color_field()
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
                    char = string.char(code)
                elseif code == 32 then
                    char = " "
                end
            end
            if e.color_channel == "hex" and code >= 65 and code <= 70 then
                char = string.char(code)
            end
            if char and not ctrl then
                if e.replace then
                    e.text = ""
                    e.replace = false
                end
                if #e.text < (e.control and e.control.type == "input" and 48 or 24) then
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
            if code == 13 then
                self.commit_color()
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
            if code == 13 then
                local ok, err = (d.mod.handle.edit or d.mod.handle.set)(d.control.id, d.selected)
                self.notice = ok
                        and (d.control.page and d.control.page.require_confirmation and "Pending confirmation" or "Saved")
                    or tostring(err)
                self.dropdown = nil
                return
            end
            return
        end
        manual_scroll = false
        tree_manual = false
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
        if page.require_confirmation and (code == 120 or code == 119) then
            local ok, err
            if code == 120 then
                ok, err = mod.handle.confirm(page.id)
            else
                ok, err = mod.handle.discard(page.id)
            end
            self.notice = ok
                    and (code == 120 and ("Confirmed and saved" .. (err and "; " .. tostring(err) or "")) or "Pending edits discarded")
                or tostring(err)
            return
        end
        if code == 9 then
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
            elseif c and code == 36 and c.type ~= "button" then
                local ok, err = (mod.handle.edit or mod.handle.set)(c.id, c.default)
                self.notice = ok and "Default restored" or tostring(err)
            end
        end
    end
    function self.sidebar()
        local rows = {}
        for index, mod in ipairs(api.list()) do
            local open = api.author_navigation or tree_expanded[mod.id] == true
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
                    local open = expanded[key] ~= false
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
    function self.wheel(delta, x, y)
        if not self.visible or self.capture or not wheel_bounds or not x or not y then
            return
        end
        if self.dropdown then
            local d = self.dropdown
            d.scroll = math.max(
                0,
                math.min(math.max(0, #d.control.choices - 8), d.scroll - delta / 120 * 3)
            )
            d.scroll = math.floor(d.scroll)
            return
        end
        if
            help_bounds
            and x >= help_bounds.x
            and x <= help_bounds.x + help_bounds.w
            and y >= help_bounds.y
            and y <= help_bounds.y + help_bounds.h
        then
            self.help_scroll = math.max(
                0,
                math.min(help_bounds.maximum, self.help_scroll - math.floor(delta / 120) * 3)
            )
            return
        end
        if
            nav_bounds
            and x >= nav_bounds.x
            and x <= nav_bounds.x + nav_bounds.w
            and y >= nav_bounds.y
            and y <= nav_bounds.y + nav_bounds.h
        then
            nav_scroll =
                math.max(0, math.min(nav_bounds.maximum, nav_scroll - math.floor(delta / 120) * 3))
            return
        end
        local b = wheel_bounds
        if x < b.x or x > b.x + b.w or y < b.y or y > b.y + b.h then
            return
        end
        wheel_remainder = wheel_remainder + delta
        local steps = wheel_remainder >= 0 and math.floor(wheel_remainder / 120)
            or math.ceil(wheel_remainder / 120)
        wheel_remainder = wheel_remainder - steps * 120
        if steps == 0 then
            return
        end
        local mod, page = active()
        if not mod then
            return
        end
        if x < b.split then
            tree_scroll = math.max(0, math.min(tree_max, tree_scroll - steps * 3))
            tree_manual = true
        else
            self.scroll =
                math.max(0, math.min(math.max(0, #page.controls - (self.visible_rows or 12)), self.scroll - steps * 3))
            manual_scroll = true
        end
    end
    function self.tick(input)
        if not self.visible then
            local down = input.down(121)
            if down and not held[121] then
                self.key(121)
            end
            held[121] = down
            return
        end
        if
            not self.color_picker
            and not drag
            and not window_drag
            and not resize_drag
            and not self.text_edit
            and input.wheel
            and input.mouse
        then
            local delta = input.wheel()
            local x, y = input.mouse()
            self.wheel(delta, x, y)
        end
        for code = 1, 255 do
            local down = input.down(code)
            if down and not held[code] and code ~= 1 then
                self.key(code, input.down(17))
            end
            held[code] = down
        end
        if self.visible and input.mouse then
            local x, y = input.mouse()
            if x and y and input.down(1) and not self.mouse_held then
                local valid = self.finish_color_field()
                if
                    self.text_edit
                    and self.text_edit.control
                    and self.text_edit.control.type == "input"
                then
                    self.key(13)
                    valid = self.text_edit == nil
                end
                if valid then
                    self.text_edit = nil
                end
                for i = #hits, 1, -1 do
                    local h = hits[i]
                    if x >= h.x and x <= h.x + h.w and y >= h.y and y <= h.y + h.h then
                        if valid then
                            h.click(x, y)
                        end
                        break
                    end
                end
            end
            if palette_drag then
                if not self.color_picker or not input.down(1) then
                    palette_drag = nil
                elseif x and y then
                    palette_drag(x, y)
                end
            end
            if color_drag then
                if not self.color_picker or not input.down(1) then
                    color_drag = nil
                elseif x and y then
                    self.color_picker.x = math.max(
                        0,
                        math.min(800, (x - color_drag.ox) / color_drag.scale - color_drag.dx)
                    )
                    self.color_picker.y = math.max(
                        0,
                        math.min(390, (y - color_drag.oy) / color_drag.scale - color_drag.dy)
                    )
                end
            end
            if split_drag then
                if not self.visible or not input.down(1) then
                    split_drag = nil
                elseif x then
                    self.sidebar_width =
                        math.max(250, math.min(650, (x - split_drag.ox) / split_drag.scale))
                end
            end
            if resize_drag then
                if not input.down(1) then
                    resize_drag = nil
                    if self.on_geometry_changed then self.on_geometry_changed(self.parent_geometry) end
                elseif x and y then
                    local g = geometry.drag(resize_drag.geometry, resize_drag.edge, x-resize_drag.x, y-resize_drag.y)
                    self.window_width,self.window_height,self.window_x,self.window_y = g.width,g.height,g.x,g.y
                end
            end
            if window_drag then
                if not self.visible or not input.down(1) then
                    if self.visible and self.on_geometry_changed then self.on_geometry_changed(self.parent_geometry) end
                    window_drag = nil
        resize_drag = nil
                elseif x and y then
                    self.window_x = math.max(0, math.min(window_drag.max_x, x - window_drag.dx))
                    self.window_y = math.max(0, math.min(window_drag.max_y, y - window_drag.dy))
                end
            end
            if drag then
                if not self.visible then
                    drag = nil
                elseif input.down(1) then
                    if x then
                        drag.move(x)
                    end
                else
                    local ok, err = (drag.mod.handle.edit or drag.mod.handle.set)(
                        drag.control.id,
                        drag.value
                    )
                    self.notice = ok
                            and (drag.control.page and drag.control.page.require_confirmation and "Pending confirmation" or "Saved")
                        or ("Could not save: " .. tostring(err))
                    drag = nil
                end
            end
            self.mouse_held = input.down(1)
        else
            self.mouse_held = input.down(1)
        end
    end
    local text_age = {}
    local elapsed = 0
    function self.advance(dt)
        if self.visible then
            elapsed = elapsed + math.max(0, math.min(1, tonumber(dt) or 0))
        else
            elapsed = 0
            text_age = {}
        end
    end
    function self.compose(w, h)
        if not self.visible or not w or not h or w<=0 or h<=0 then
            hits = {}
            drag = nil
            window_drag = nil
        resize_drag = nil
            self.dropdown = nil
            self.text_edit = nil
            self.color_picker = nil
            return {}
        end
        local commands = {}
        hits = {}
        local g = geometry.bounds(w,h,self.window_width,self.window_height,self.window_x,self.window_y)
        self.window_width,self.window_height,self.window_x,self.window_y = g.width,g.height,g.x,g.y
        self.parent_geometry = g
        local W,H,s,ox,oy = g.width,g.height,g.scale,g.x,g.y
        self.visible_rows = math.max(1,math.floor((H-350)/38))
        local tree_visible = math.max(1,math.floor((H-250)/31))
        self.sidebar_width = math.max(250,math.min(self.sidebar_width, W-800))
        local visible_text_age = {}
        self.window_x, self.window_y = ox, oy
        local white = { 224, 230, 234 }
        local muted = { 145, 156, 165 }
        local accent = { 244, 202, 53 }
        local selection_text = { 24, 30, 35 }
        local function rect(x, y, rw, rh, color, a)
            commands[#commands + 1] = {
                type = "rect",
                x = ox + x * s,
                y = oy + y * s,
                w = rw * s,
                h = rh * s,
                c = color,
                a = a or 1,
            }
        end
        local function text(x, y, value, size, color)
            local full = tostring(value)
            local width = math.max(0, (W-25) - x) * s
            local single = string.gsub(full, "[\r\n]+", " ")
            local visible = M.flow(single, width, (size or 20) * s, elapsed, measure)
            commands[#commands + 1] = {
                type = "text",
                x = ox + x * s,
                y = oy + y * s,
                text = visible,
                full_text = full,
                text_width = width,
                size = (size or 20) * s,
                c = color or white,
                a = 1,
            }
        end
        local function bounded(x, y, value, size, color, width)
            local key = tostring(value) .. "|" .. x .. "|" .. y .. "|" .. width
            if not text_age[key] then
                text_age[key] = elapsed
            end
            visible_text_age[key] = text_age[key]
            width = math.max(0, math.min(width, (W-25) - x))
            local result = M.flow(string.gsub(tostring(value), "[\r\n]+", " "), width * s, size * s, elapsed - text_age[key], measure)
            text(x, y, result, size, color)
            commands[#commands].full_text = tostring(value)
            commands[#commands].text_width = width * s
        end
        local function hit(x, y, rw, rh, fn)
            hits[#hits + 1] = { x = ox + x * s, y = oy + y * s, w = rw * s, h = rh * s, click = fn }
        end
        local function scrollbar(role, x, y, height, total, visible, offset)
            if total <= visible then
                return
            end
            local thumb = math.max(20, height * visible / total)
            local travel = height - thumb
            local maximum = total - visible
            local progress = math.max(0, math.min(1, offset / maximum))
            rect(x, y, 5, height, { 52, 61, 68 })
            rect(x - 1, y + travel * (1 - progress), 7, thumb, accent)
            commands[#commands].scrollbar = role
        end
        rect(0, 0, W, H, { 16, 20, 24 }, 0.98)
        rect(0, (H-60), W, 60, { 28, 33, 38 })
        rect(self.sidebar_width, 60, 2, H-120, muted)
        hit(0, (H-60), W, 60, function(mx, my)
            if drag or self.capture then
                return
            end
            window_drag =
                { dx = mx - ox, dy = my - oy, max_x = math.max(0, w - W * s), max_y = math.max(
                    0,
                    h - H * s
                ) }
        end)
        wheel_bounds = { x = ox, y = oy + 196 * s, w = W * s, h = (H-316) * s, split = ox
            + self.sidebar_width * s }
        text(30, (H-43), "LIVE LUA LOADER", 28, accent)
        rect((W-55), (H-45), 38, 30, { 65, 73, 80 })
        text((W-43), (H-38), "X", 20, white)
        hit((W-55), (H-45), 38, 30, function()
            self.visible = false
            self.capture = false
            self.dropdown = nil
            self.text_edit = nil
            self.color_picker = nil
        end)
        text(25, (H-105), "MODS", 18, muted)
        local mods = api.list()
        local mod, page = active()
        local sidebar = self.sidebar()
        tree_max = math.max(0, #sidebar - tree_visible)
        tree_scroll = math.max(0, math.min(tree_scroll, tree_max))
        if not tree_manual then
            for i, node in ipairs(sidebar) do
                if node.kind == "mod" and node.index == self.selected then
                    if i <= tree_scroll then
                        tree_scroll = i - 1
                    elseif i > tree_scroll + tree_visible then
                        tree_scroll = i - tree_visible
                    end
                end
            end
        end
        self.mod_scroll = tree_scroll
        for i = tree_scroll + 1, math.min(#sidebar, tree_scroll + tree_visible) do
            local entry = sidebar[i]
            local y = (H-149) - (i - tree_scroll - 1) * 31
            local x = 25 + entry.depth * 16
            if entry.kind == "mod" then
                local selected = entry.index == self.selected
                if selected then
                    rect(15, y - 6, self.sidebar_width - 30, 30, accent)
                end
                bounded(
                    x,
                    y,
                    (entry.open and "[-] " or "[+] ") .. entry.mod.name,
                    20,
                    selected and selection_text or white,
                    self.sidebar_width - 15 - x
                )
                hit(15, y - 6, self.sidebar_width - 30, 30, function()
                    self.selected = entry.index
                    tree_expanded[entry.mod.id] = not entry.open
                    self.page = 1
                    self.row = 1
                    self.scroll = 0
                    self.focus = "settings"
                    tree_manual = true
                end)
            else
                local last = true
                for next_index = i + 1, #sidebar do
                    local next_entry = sidebar[next_index]
                    if next_entry.mod ~= entry.mod or next_entry.depth < entry.depth then
                        break
                    end
                    if next_entry.depth == entry.depth then
                        last = false
                        break
                    end
                end
                local anchor = i-1
                while anchor > 0 and sidebar[anchor].mod == entry.mod and sidebar[anchor].depth > entry.depth do anchor=anchor-1 end
                local anchor_y = (H-149) - (anchor-tree_scroll-1)*31 + 6
                local junction = y+6
                local top = math.max(junction,math.min(H-137,anchor_y))
                rect(x-10,junction,1,top-junction,muted)
                commands[#commands].tree_branch = {last=last,row_y=oy+y*s,junction=oy+junction*s,top=oy+top*s}
                rect(x - 10, y + 6, 9, 1, muted)
                if entry.kind == "category" then
                    bounded(
                        x,
                        y,
                        (entry.open and "v " or "> ") .. entry.category.name,
                        18,
                        accent,
                        self.sidebar_width - 15 - x
                    )
                    hit(15, y - 6, self.sidebar_width - 30, 30, function()
                        expanded[entry.key] = not entry.open
                        tree_manual = true
                    end)
                else
                    local selected = entry.mod_index == self.selected and entry.index == self.page
                    if api.author_navigation and selected then
                        rect(x - 3, y - 5, self.sidebar_width - x - 12, 28, { 40, 47, 54 })
                    end
                    bounded(
                        x,
                        y,
                        entry.page.name,
                        api.author_navigation and 20 or 18,
                        selected and accent or white,
                        self.sidebar_width - 15 - x
                    )
                    hit(15, y - 6, self.sidebar_width - 30, 30, function()
                        self.selected = entry.mod_index
                        self.page = entry.index
                        self.row = 1
                        self.scroll = 0
                        manual_scroll = false
                        self.focus = "settings"
                        tree_manual = true
                    end)
                end
            end
        end
        scrollbar("mods", self.sidebar_width - 10, 140, H-262, #sidebar, tree_visible, tree_scroll)
        if not mod then
            text(365, (H-150), "No mods registered. See the author example.", 24)
        else
            bounded(self.sidebar_width + 35, (H-108), mod.name, 28, accent, (W-55) - self.sidebar_width)
            bounded(self.sidebar_width + 35, (H-146), page.name, 22, white, (W-55) - self.sidebar_width)
            text(
                self.sidebar_width + 35,
                90,
                "Page " .. self.page .. " / " .. #mod.pages .. "  |  PgUp / PgDn",
                16,
                muted
            )
            if api.loader_summary then
                bounded(25, 90, api.loader_summary(), 14, accent, self.sidebar_width - 40)
            end
            if page.require_confirmation then
                local pending = 0
                for _ in pairs(page.pending) do
                    pending = pending + 1
                end
                for _ in pairs(page.actions) do
                    pending = pending + 1
                end
                text((W-650), 90, "CONFIRM REQUIRED (" .. pending .. ")", 16, accent)
                rect((W-340), 81, 135, 29, { 65, 73, 80 })
                text((W-330), 90, "APPLY", 18, accent)
                rect((W-190), 81, 135, 29, { 65, 73, 80 })
                text((W-180), 90, "DISCARD", 18, white)
                hit((W-340), 81, 135, 29, function()
                    local ok, err = mod.handle.confirm(page.id)
                    self.notice = ok
                            and ("Confirmed and saved" .. (err and "; " .. tostring(err) or ""))
                        or tostring(err)
                end)
                hit((W-190), 81, 135, 29, function()
                    mod.handle.discard(page.id)
                    self.notice = "Pending edits discarded"
                end)
            end
            local rows = selectable(page)
            self.row = math.max(1, math.min(self.row, #rows))
            local selected = rows[self.row]
            -- Scroll by control index; retain headings as ordinary display rows.
            local selected_at = 1
            for i, c in ipairs(page.controls) do
                if c == selected then
                    selected_at = i
                end
            end
            if not manual_scroll and selected_at <= self.scroll then
                self.scroll = selected_at - 1
            end
            if not manual_scroll and selected_at > self.scroll + self.visible_rows then
                self.scroll = selected_at - self.visible_rows
            end
            self.scroll = math.max(0, math.min(self.scroll, math.max(0, #page.controls - self.visible_rows)))
            local selected_row = 0
            local columns = { 0, 0 }
            local wide = type(page.render_preview) ~= "function"
            for _, control in ipairs(page.controls) do
                if control.column then
                    wide = false
                end
            end
            local settings_x = self.sidebar_width + 35
            local available = (W-25) - settings_x
            local row_width = wide and available or available / 2 - 30
            if available < 1050 then wide = true end
            for i, c in ipairs(page.controls) do
                if c.type ~= "text" and c.type ~= "section" then
                    selected_row = selected_row + 1
                end
                if i > self.scroll and i <= self.scroll + self.visible_rows then
                    local col = wide and 1 or (c.column or 1)
                    columns[col] = columns[col] + 1
                    local x = settings_x + (col - 1) * (available / 2)
                    local y = (H-197) - (columns[col] - 1) * 38
                    local row_index = selected_row
                    if c == selected then
                        rect(x - 5, y - 7, row_width + 5, 34, accent)
                    end
                    local color = c.disabled and muted or accent
                    local informational = c.type == "text" or c.type == "section"
                    local label = c.label or ""
                    local label_width = informational and row_width or row_width - 290
                    bounded(
                        x,
                        y,
                        label,
                        20,
                        c.disabled and muted
                            or (
                                c == selected and selection_text
                                or (c.type == "section" and accent or white)
                            ),
                        label_width
                    )
                    if c.type ~= "text" and c.type ~= "section" then
                        local value = (mod.handle.preview or mod.handle.get)(c.id)
                        local control = c
                        local owner = mod
                        local vx = x + row_width - 525
                        local function select()
                            self.row = row_index
                            self.focus = "settings"
                        end
                        hit(x - 5, y - 7, row_width + 5, 34, function()
                            select()
                        end)
                        if c.type == "slider" then
                            if drag and drag.mod == mod and drag.control == c then
                                value = drag.value
                            end
                            local track = vx + 245
                            local width = 180
                            local fraction =
                                math.max(0, math.min(1, (value - c.min) / (c.max - c.min)))
                            rect(track, y + 5, width, 5, { 78, 87, 94 })
                            rect(track, y + 5, width * fraction, 5, color)
                            rect(track + width * fraction - 6, y - 2, 12, 19, color)
                            local editing = self.text_edit
                                and self.text_edit.mod == mod
                                and self.text_edit.control == c
                            rect(
                                vx + 435,
                                y - 5,
                                90,
                                29,
                                editing and { 76, 82, 88 }
                                    or (c == selected and accent or { 35, 42, 48 })
                            )
                            local display = editing and self.text_edit.text .. "|"
                                or string.gsub(string.gsub(string.format("%.3f", value), "0+$", ""), "%.$", "")
                            bounded(
                                vx + 440,
                                y,
                                display,
                                18,
                                editing and accent or (c == selected and selection_text or white),
                                80
                            )
                            hit(vx + 435, y - 5, 90, 29, function()
                                if control.disabled then
                                    return
                                end
                                select()
                                self.text_edit = {
                                    mod = owner,
                                    control = control,
                                    text = tostring(
                                        (owner.handle.preview or owner.handle.get)(control.id)
                                    ),
                                    replace = true,
                                }
                                self.notice = "Type value; Enter saves, Escape cancels"
                            end)
                            hit(track - 8, y - 7, width + 16, 34, function(mx)
                                if control.disabled then
                                    return
                                end
                                select()
                                local d = {
                                    mod = owner,
                                    control = control,
                                    value = (owner.handle.preview or owner.handle.get)(control.id),
                                }
                                function d.move(px)
                                    local f = math.max(
                                        0,
                                        math.min(1, (px - (ox + track * s)) / (width * s))
                                    )
                                    d.value = math.min(
                                        control.max,
                                        control.min
                                            + math.floor(
                                                    f * (control.max - control.min) / control.step
                                                        + 0.5
                                                )
                                                * control.step
                                    )
                                end
                                drag = d
                                d.move(mx)
                            end)
                        elseif c.type == "input" then
                            local editing = self.text_edit and self.text_edit.control == c
                            hit(vx + 275, y - 5, 250, 29, function()
                                select()
                                change(control, 0)
                            end)
                            rect(
                                vx + 275,
                                y - 5,
                                250,
                                29,
                                c == selected and accent or { 35, 42, 48 }
                            )
                            bounded(
                                vx + 285,
                                y,
                                editing and self.text_edit.text .. "|" or value,
                                18,
                                c == selected and selection_text or white,
                                230
                            )
                        elseif c.type == "color" then
                            rect(vx + 300, y - 3, 34, 23, api.color_rgb(value))
                            rect(
                                vx + 350,
                                y - 5,
                                175,
                                29,
                                c == selected and accent or { 35, 42, 48 }
                            )
                            bounded(
                                vx + 360,
                                y,
                                value,
                                18,
                                c == selected and selection_text or white,
                                155
                            )
                            hit(vx + 295, y - 7, 230, 34, function()
                                if control.disabled then
                                    return
                                end
                                select()
                                self.color_picker = {
                                    mod = owner,
                                    control = control,
                                    rgb = api.color_rgb(
                                        (owner.handle.preview or owner.handle.get)(control.id)
                                    ),
                                }
                            end)
                        elseif c.type == "toggle" then
                            hit(vx + 350, y - 5, 175, 29, function()
                                select()
                                change(control, 0)
                            end)
                            rect(
                                vx + 350,
                                y - 5,
                                175,
                                29,
                                c == selected and accent or { 24, 30, 35 }
                            )
                            rect(vx + 354, y - 1, 36, 21, { 65, 73, 80 })
                            if value then
                                rect(vx + 358, y + 3, 28, 13, white)
                            end
                            text(
                                vx + 405,
                                y,
                                value and "ON" or "OFF",
                                19,
                                c.disabled and muted or (c == selected and selection_text or white)
                            )
                        elseif c.type == "choice" then
                            local presentation = c.presentation or "combined"
                            local chosen = c == selected and selection_text or white
                            local symbol = c == selected and selection_text or color
                            local cx = presentation == "dropdown" and vx + 245 or vx + 275
                            local cw = presentation == "dropdown" and 280 or 220
                            if presentation ~= "dropdown" then
                                rect(
                                    vx + 245,
                                    y - 5,
                                    27,
                                    29,
                                    c == selected and accent or { 65, 73, 80 }
                                )
                                text(vx + 252, y, "<", 18, symbol)
                                rect(
                                    vx + 498,
                                    y - 5,
                                    27,
                                    29,
                                    c == selected and accent or { 65, 73, 80 }
                                )
                                text(vx + 505, y, ">", 18, symbol)
                                hit(vx + 245, y - 5, 27, 29, function()
                                    select()
                                    change(control, -1)
                                end)
                                hit(vx + 498, y - 5, 27, 29, function()
                                    select()
                                    change(control, 1)
                                end)
                            end
                            rect(cx, y - 5, cw, 29, c == selected and accent or { 35, 42, 48 })
                            bounded(
                                cx + 9,
                                y,
                                tostring(c.choices[value]),
                                18,
                                chosen,
                                cw - (presentation == "selector" and 20 or 55)
                            )
                            if presentation ~= "selector" then
                                -- Reserve an opaque indicator cell above the value text.
                                rect(
                                    cx + cw - 32,
                                    y - 5,
                                    32,
                                    29,
                                    c == selected and accent or { 35, 42, 48 }
                                )
                                text(cx + cw - 20, y, "v", 18, symbol)
                                hit(cx, y - 5, cw, 29, function()
                                    if control.disabled then
                                        return
                                    end
                                    select()
                                    self.dropdown = {
                                        mod = owner,
                                        control = control,
                                        selected = value,
                                        scroll = math.max(
                                            0,
                                            math.min(math.max(0, #control.choices - 8), value - 4)
                                        ),
                                        x = cx,
                                        top = y - 8,
                                    }
                                end)
                            end
                        else
                            hit(vx + 350, y - 5, 175, 29, function()
                                select()
                                change(control, 0)
                            end)
                            rect(
                                vx + 350,
                                y - 5,
                                175,
                                29,
                                c == selected and accent or { 65, 73, 80 }
                            )
                            local label = c.type == "button"
                                    and (c.button_label or c.label or "Activate")
                                or (value == 0 and "BIND KEY" or "VK " .. tostring(value))
                            bounded(
                                vx + 362,
                                y,
                                label,
                                18,
                                c == selected and selection_text or color,
                                151
                            )
                        end
                    end
                end
            end
            scrollbar("settings", (W-20), 196, H-364, #page.controls, self.visible_rows, self.scroll)
            if #page.controls > self.visible_rows then
                text(
                    365,
                    166,
                    "Rows "
                        .. (self.scroll + 1)
                        .. "-"
                        .. math.min(self.scroll + self.visible_rows, #page.controls)
                        .. " of "
                        .. #page.controls,
                    16,
                    muted
                )
            end
            if type(page.render_preview) == "function" then
                local ok, preview = pcall(
                    page.render_preview,
                    { x = ox + 950 * s, y = oy + 285 * s, w = 460 * s, h = 350 * s, scale = s }
                )
                if ok and type(preview) == "table" then
                    for _, command in ipairs(preview) do
                        command.layer = 110
                        command.hud_preview = true
                        commands[#commands + 1] = command
                    end
                end
            end
            local help = selected and selected.description or mod.description
            local key = mod.id .. "/" .. page.id .. "/" .. tostring(help)
            if help_key ~= key then
                self.help_scroll = 0
                help_key = key
            end
            local hx = self.sidebar_width + 35
            local hw = (W-40) - hx
            local lines = M.rich(help, hw * s, 18 * s, measure)
            local visible = 3
            self.help_scroll = math.min(self.help_scroll, math.max(0, #lines - visible))
            help_bounds =
                { x = ox + hx * s, y = oy + 126 * s, w = hw * s, h = 64 * s, maximum = math.max(
                    0,
                    #lines - visible
                ) }
            for index = self.help_scroll + 1, math.min(#lines, self.help_scroll + visible) do
                local line = lines[index]
                local tx = hx
                local ty = 177 - (index - self.help_scroll - 1) * 22
                for _, span in ipairs(line.spans) do
                    text(
                        tx,
                        ty,
                        span.text,
                        line.size / s,
                        span.style == "plain" and muted
                            or (span.style == "emphasis" and white or accent)
                    )
                    tx = tx + span.width / s
                end
            end
            scrollbar("help", (W-30), 126, 64, #lines, visible, self.help_scroll)
        end
        hit(self.sidebar_width - 6, 196, 12, H-310, function()
            split_drag = { ox = ox, scale = s }
        end)
        text(
            25,
            32,
            "F9 Close   Tab Focus   Arrows Change   Enter Select   Home Default",
            17,
            muted
        )
        -- Show the actual status, not a fixed character slice of a Lua error.
        local notice = string.gsub(self.notice, "[%w_./\\-]+%.lua:%d+:%s*", "")
        local lines, line = {}, ""
        for word in string.gmatch(notice, "%S+") do
            if #line > 0 and #line + #word + 1 > 58 then
                lines[#lines + 1] = line
                line = word
            else
                line = #line == 0 and word or line .. " " .. word
            end
        end
        if #line > 0 then
            lines[#lines + 1] = line
        end
        for i, message in ipairs(lines) do
            text((W-600), 32 + (#lines - i) * 20, message, 15, accent)
        end
        if self.dropdown then
            local overlay_start = #commands + 1
            local d = self.dropdown
            local count = math.min(8, #d.control.choices)
            local height = count * 31 + 8
            local top = math.max(height + 8, math.min(752, d.top))
            local x = d.x
            -- Overlay hit regions take priority and consume outside clicks.
            hit(-ox / s, -oy / s, w / s, h / s, function()
                self.dropdown = nil
            end)
            rect(x - 2, top - height - 2, 254, height + 4, accent)
            rect(x, top - height, 250, height, { 24, 30, 35 })
            for index = d.scroll + 1, math.min(#d.control.choices, d.scroll + count) do
                local y = top - 29 - (index - d.scroll - 1) * 31
                local choice = index
                if index == d.selected then
                    rect(x + 3, y - 4, 234, 30, accent)
                end
                bounded(
                    x + 8,
                    y,
                    tostring(d.control.choices[index]),
                    18,
                    index == d.selected and selection_text or white,
                    226
                )
                hit(x + 3, y - 4, 234, 30, function()
                    local ok, err = (d.mod.handle.edit or d.mod.handle.set)(d.control.id, choice)
                    self.notice = ok
                            and (d.control.page and d.control.page.require_confirmation and "Pending confirmation" or "Saved")
                        or tostring(err)
                    self.dropdown = nil
                end)
            end
            scrollbar(
                "dropdown",
                x + 243,
                top - height + 4,
                height - 8,
                #d.control.choices,
                count,
                d.scroll
            )
            for index = overlay_start, #commands do
                commands[index].popup = true
                commands[index].layer = 200
            end
            if #d.control.choices > count then
                hit(x + 237, top - height, 13, height, function(_, my)
                    local f = 1 - math.max(
                        0,
                        math.min(1, (my - (oy + (top - height) * s)) / (height * s))
                    )
                    d.scroll = math.floor(f * (#d.control.choices - count) + 0.5)
                end)
            end
        end
        if self.color_picker then
            local p = self.color_picker
            local start = #commands + 1
            local px, py = p.x or 400, p.y or 195
            hit(-ox / s, -oy / s, w / s, h / s, function()
                self.color_picker = nil
                self.text_edit = nil
            end)
            hit(px - 2, py - 2, 704, 434, function() end)
            hit(px, py + 385, 700, 45, function(mx, my)
                color_drag = { ox = ox, oy = oy, scale = s, dx = (mx - ox) / s - px, dy = (my - oy)
                        / s
                    - py }
            end)
            rect(px - 2, py - 2, 704, 434, accent)
            rect(px, py, 700, 430, { 24, 30, 35 })
            rect(px + 650, py + 389, 32, 30, { 65, 73, 80 })
            text(px + 660, py + 396, "X", 20, white)
            hit(px + 650, py + 389, 32, 30, function()
                self.color_picker = nil
                self.text_edit = nil
            end)
            text(px + 20, py + 397, "COLOR - RGB / HEX / SWATCHES", 22, accent)
            local hue, saturation, brightness = api.rgb_hsv(p.rgb)
            p.hue = p.hue or hue
            p.saturation = p.saturation or saturation
            p.brightness = p.brightness or brightness
            for col = 0, 15 do
                for row = 0, 11 do
                    rect(
                        px + 20 + col * 14,
                        py + 160 + row * 17,
                        15,
                        18,
                        api.hsv_rgb(col / 15, row / 11, p.brightness)
                    )
                end
            end
            for row = 0, 15 do
                rect(
                    px + 262,
                    py + 160 + row * 12.75,
                    25,
                    13.75,
                    api.hsv_rgb(p.hue, p.saturation, row / 15)
                )
            end
            rect(px + 17 + p.hue * 224, py + 157 + p.saturation * 204, 6, 6, white)
            rect(px + 259, py + 158 + p.brightness * 204, 31, 3, white)
            local function spectrum(mx, my)
                p.hue = math.max(0, math.min(1, ((mx - ox) / s - px - 20) / 224))
                p.saturation = math.max(0, math.min(1, ((my - oy) / s - py - 160) / 204))
                p.rgb = api.hsv_rgb(p.hue, p.saturation, p.brightness)
            end
            local function value_slider(mx, my)
                p.brightness = math.max(0, math.min(1, ((my - oy) / s - py - 160) / 204))
                p.rgb = api.hsv_rgb(p.hue, p.saturation, p.brightness)
            end
            hit(px + 20, py + 160, 224, 204, function(mx, my)
                palette_drag = spectrum
                spectrum(mx, my)
            end)
            hit(px + 262, py + 160, 25, 204, function(mx, my)
                palette_drag = value_slider
                value_slider(mx, my)
            end)
            rect(px + 595, py + 287, 85, 65, p.rgb)
            local fields = {
                { key = 1, label = "R", value = p.rgb[1] },
                { key = 2, label = "G", value = p.rgb[2] },
                { key = 3, label = "B", value = p.rgb[3] },
                { key = "hex", label = "HEX", value = api.color_hex(p.rgb) },
            }
            for index, field in ipairs(fields) do
                local fy = py + 343 - (index - 1) * 42
                text(px + 315, fy, field.label, 20, white)
                rect(px + 370, fy - 5, 210, 30, { 55, 63, 70 })
                local editing = self.text_edit and self.text_edit.color_channel == field.key
                text(
                    px + 380,
                    fy,
                    editing and self.text_edit.text .. "|" or tostring(field.value),
                    20,
                    editing and accent or white
                )
                hit(px + 370, fy - 5, 210, 30, function()
                    self.text_edit = {
                        color_channel = field.key,
                        text = string.gsub(tostring(field.value), "^#", ""),
                        replace = true,
                    }
                end)
            end
            text(px + 20, py + 126, "CUSTOM SWATCHES", 17, muted)
            for index, hex in ipairs(api.swatches()) do
                local sx = px + 20 + (index - 1) * 43
                if p.selected_swatch == index then
                    rect(sx - 3, py + 76, 41, 36, accent)
                end
                rect(sx, py + 79, 35, 30, api.color_rgb(hex))
                hit(sx, py + 79, 35, 30, function()
                    p.selected_swatch = index
                    p.rgb = api.color_rgb(hex)
                    p.hue, p.saturation, p.brightness = api.rgb_hsv(p.rgb)
                end)
            end
            rect(px + 550, py + 78, 130, 32, { 65, 73, 80 })
            text(px + 560, py + 88, "SAVE SWATCH", 16, accent)
            hit(px + 550, py + 78, 130, 32, function()
                local ok, err = api.save_swatch(p.rgb)
                self.notice = ok and "Custom swatch saved" or tostring(err)
            end)
            rect(px + 550, py + 119, 130, 32, { 65, 73, 80 })
            text(px + 557, py + 129, "REPLACE", 16, p.selected_swatch and accent or muted)
            hit(px + 550, py + 119, 130, 32, function()
                if not p.selected_swatch then
                    self.notice = "Select a saved swatch first"
                    return
                end
                local ok, err = api.replace_swatch(p.selected_swatch, p.rgb)
                self.notice = ok and "Selected swatch replaced" or tostring(err)
            end)
            rect(px + 20, py + 20, 300, 32, { 65, 73, 80 })
            text(px + 35, py + 29, "USE COLOR", 18, accent)
            hit(px + 20, py + 20, 300, 32, function()
                self.commit_color()
            end)
            rect(px + 370, py + 20, 310, 32, { 65, 73, 80 })
            text(px + 390, py + 29, "CANCEL", 18, white)
            hit(px + 370, py + 20, 310, 32, function()
                self.color_picker = nil
                self.text_edit = nil
            end)
            for index = start, #commands do
                commands[index].popup = true
                commands[index].layer = 300
            end
        end
        if self.dropdown then
            -- Popup primitives follow ordinary content and occupy a higher plane.
            for _, command in ipairs(commands) do
                if command.popup then
                    command.layer = 200
                end
            end
        end
        for _, edge in ipairs({
            {"left",0,0,8,H},{"right",W-8,0,8,H},{"bottom",0,0,W,8},{"top",0,H-8,W,8},
            {"left_bottom",0,0,14,14},{"right_bottom",W-14,0,14,14},
            {"left_top",0,H-14,14,14},{"right_top",W-14,H-14,14,14},
        }) do
            local name=edge[1]
            hit(edge[2],edge[3],edge[4],edge[5],function(mx,my)
                if drag or self.capture then return end
                resize_drag={edge=name,x=mx,y=my,geometry=g}
            end)
        end
        text_age = visible_text_age
        return commands
    end
    return self
end
return M
