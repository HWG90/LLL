-- Stock Stingray GUI; build-checked loaded main HUD font with compatibility fallback.
local M = {}
local theme = LLL_UI_THEME or dofile("src/ui/theme.lua")
function M.new(sr, preview_only)
    local gui, world
    local ids = {}
    local G = sr.Gui
    local self = {}
    local preview_view = not preview_only and M.new(sr, true) or nil
    local popup_view = not preview_only and M.new(sr, true) or nil
    local function live()
        for _, w in pairs(sr.Application.worlds() or {}) do
            if w == world then
                return true
            end
        end
        return false
    end
    local metrics = {}
    local font_source,active_font,font_key
    local function font_id()return active_font and sr.IdString64.from_hex(active_font.font) or "core/performance_hud/debug" end
    local function bind_font()
        if not active_font or not gui then return true end
        local ok,value=pcall(function()
            local material=G.material(gui,sr.IdString64.from_hex(active_font.material))
            return material and sr.Material.set_texture(material,sr.IdString64.from_hex("88BAC99B00000000"),sr.IdString64.from_hex(active_font.atlas))~=false
        end)
        return ok and value
    end
    function self.set_font_source(source)
        font_source=source
        if preview_view then preview_view.set_font_source(source) end
        if popup_view then popup_view.set_font_source(source) end
    end
    function self.accept_font(descriptor)
        local key=descriptor and table.concat({descriptor.font,descriptor.material,descriptor.atlas},"|")
        if key~=font_key then metrics={};self.clear();font_key=key;active_font=descriptor end
        if gui and not bind_font() then active_font=nil;font_key=nil;metrics={};self.clear() end
        if preview_view then preview_view.accept_font(active_font) end
        if popup_view then popup_view.accept_font(active_font) end
        self.font_name=active_font and "Main HUD" or "Compatibility fallback"
    end
    function self.refresh_font()
        local descriptor
        if font_source and G.material and sr.Material and sr.Material.set_texture then
            local ok,value=pcall(font_source.resolve,sr)
            if ok and type(value)=="table" then descriptor=value end
        end
        self.accept_font(descriptor)
    end
    function self.measure(glyph, size)
        local key = glyph .. "|" .. size
        if metrics[key] then
            return metrics[key]
        end
        -- Some game font extents report an advance smaller than the drawn glyph.
        -- Keep the stock-font estimate as a floor, including whole-word queries.
        local width = 0
        for _ in string.gmatch(glyph, "[%z\1-\127\194-\244][\128-\191]*") do
            width = width + size * 0.62
        end
        if gui and live() and type(G.text_extents) == "function" then
            local ok, value = pcall(function()
                if active_font then
                    local lo,hi=G.text_extents(gui,glyph,font_id(),size)
                    return hi.x-lo.x
                end
                local lo, hi = G.text_extents(gui, "M" .. glyph, font_id(), size)
                local base_lo, base_hi =
                    G.text_extents(gui, "M", font_id(), size)
                return (hi.x - lo.x) - (base_hi.x - base_lo.x)
            end)
            if ok and type(value) == "number" and value > 0 and value < 1000 then
                width = active_font and value or math.max(width, value)
            end
            metrics[key] = width
        end
        return width
    end
    function self.clear()
        if gui and live() then
            for _, item in ipairs(ids) do
                pcall(G["destroy_" .. item.type], gui, item.id)
            end
        end
        ids = {}
    end
    function self.release()
        if preview_view then
            preview_view.release()
        end
        if popup_view then
            popup_view.release()
        end
        if gui and live() then
            self.clear()
            sr.World.destroy_gui(world, gui)
        end
        gui, world = nil, nil
    end
    function self.draw(commands)
        self.refresh_font()
        if preview_view then
            local menu, preview, popup = {}, {}, {}
            for _, c in ipairs(commands) do
                local destination = c.hud_preview and preview or (c.popup and popup or menu)
                destination[#destination + 1] = c
            end
            preview_view.draw(preview)
            popup_view.draw(popup)
            commands = menu
        end
        if #commands == 0 then
            self.release()
            return
        end
        if gui and not live() then
            gui, world = nil, nil
            ids = {}
        end
        if not gui then
            local main = sr.Application.main_world()
            world = main
            for _, w in pairs(sr.Application.worlds() or {}) do
                if w ~= main then
                    world = w
                    break
                end
            end
            if not world then
                return
            end
            gui = sr.World.create_screen_gui(world, "scale", 1, 1)
            if active_font and not bind_font() then active_font=nil;font_key=nil;metrics={} end
        end
        local old_ids = ids
        ids = {}
        local signatures = {}
        for index, c in ipairs(commands) do
            local z = theme.depth(c)
            signatures[index] = table.concat({
                c.type,
                c.text or "",
                c.x,
                c.y,
                c.w or 0,
                c.h or 0,
                c.size or 0,
                c.a,
                c.c[1],
                c.c[2],
                c.c[3],
                z,
                font_key or "fallback",
                c.font_resource or "",
                c.font_material or "",
            }, "|")
        end
        -- Destroy all stale IDs before allocations: engines may reuse IDs immediately.
        for index, old in ipairs(old_ids) do
            if old.signature ~= signatures[index] then
                pcall(G["destroy_" .. old.type], gui, old.id)
                old_ids[index] = false
            end
        end
        for index, c in ipairs(commands) do
            local z = theme.depth(c)
            local signature = signatures[index]
            local old = old_ids[index]
            if old and old.signature == signature then
                ids[#ids + 1] = old
            else
                local color = sr.Color(math.floor(c.a * 255 + 0.5), c.c[1], c.c[2], c.c[3])
                local value
                if c.type == "rect" then
                    value = G.rect(gui, sr.Vector3(c.x, c.y, z), sr.Vector2(c.w, c.h), color)
                else
                    local font, material =
                        font_id(), active_font and sr.IdString64.from_hex(active_font.material) or "core/performance_hud/debug"
                    if c.font_resource then
                        font, material = c.font_resource, c.font_material
                    end
                    value =
                        G.text(gui, c.text, font, c.size, material, sr.Vector3(c.x, c.y, z), color)
                end
                if value then
                    ids[#ids + 1] = { type = c.type, id = value, signature = signature }
                else
                    ids[#ids + 1] = { type = c.type, id = nil, signature = nil }
                end
            end
        end
    end
    return self
end
return M
