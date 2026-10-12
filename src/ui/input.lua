-- Pointer, wheel and drag ownership.
local MODULE = {}
function MODULE.install(context)
    local self,state,api,measure,M = context.self,context.state,context.api,context.measure,context.menu
    local geometry,theme = context.geometry,context.theme
    local active,selectable,change = context.active,context.selectable,context.change
    function self.wheel(delta, x, y)
        if not self.visible or self.capture or not state.wheel_bounds or not x or not y then
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
            state.help_bounds
            and x >= state.help_bounds.x
            and x <= state.help_bounds.x + state.help_bounds.w
            and y >= state.help_bounds.y
            and y <= state.help_bounds.y + state.help_bounds.h
        then
            self.help_scroll = math.max(
                0,
                math.min(state.help_bounds.maximum, self.help_scroll - math.floor(delta / 120) * 3)
            )
            return
        end
        if
            state.nav_bounds
            and x >= state.nav_bounds.x
            and x <= state.nav_bounds.x + state.nav_bounds.w
            and y >= state.nav_bounds.y
            and y <= state.nav_bounds.y + state.nav_bounds.h
        then
            state.nav_scroll =
                math.max(0, math.min(state.nav_bounds.maximum, state.nav_scroll - math.floor(delta / 120) * 3))
            return
        end
        local b = state.wheel_bounds
        if x < b.x or x > b.x + b.w or y < b.y or y > b.y + b.h then
            return
        end
        state.wheel_remainder = state.wheel_remainder + delta
        local steps = state.wheel_remainder >= 0 and math.floor(state.wheel_remainder / 120)
            or math.ceil(state.wheel_remainder / 120)
        state.wheel_remainder = state.wheel_remainder - steps * 120
        if steps == 0 then
            return
        end
        local mod, page = active()
        if not mod then
            return
        end
        if x < b.split then
            state.tree_scroll = math.max(0, math.min(state.tree_max, state.tree_scroll - steps * 3))
            state.tree_manual = true
        else
            self.scroll =
                math.max(0, math.min(math.max(0, (self.display_total or #page.controls) - (self.visible_rows or 12)), self.scroll - steps * 3))
            state.manual_scroll = true
        end
    end
    function self.tick(input)
        if not self.visible then
            self.pointer_x,self.pointer_y=nil,nil
            state.scroll_drag=nil
            local down = input.down(121)
            if down and not state.held[121] then
                self.key(121)
            end
            state.held[121] = down
            return
        end
        if
            not self.color_picker
            and not state.drag
            and not state.window_drag
            and not state.resize_drag
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
            if down and not state.held[code] and code ~= 1 and code ~= 2 then
                self.key(code, input.down(17), input.down(16))
            end
            state.held[code] = down
        end
        if self.visible and input.mouse then
            local x, y = input.mouse()
            self.pointer_x,self.pointer_y=x,y
            if x and y and input.down(2) and not self.right_held and not self.capture and not self.text_edit and not self.color_picker then
                for i=#state.hits,1,-1 do
                    local hit=state.hits[i]
                    if hit.right and x>=hit.x and x<=hit.x+hit.w and y>=hit.y and y<=hit.y+hit.h then hit.right(x,y);break end
                end
            end
            self.right_held=input.down(2)
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
                for i = #state.hits, 1, -1 do
                    local h = state.hits[i]
                    if x >= h.x and x <= h.x + h.w and y >= h.y and y <= h.y + h.h then
                        if valid then
                            h.click(x, y)
                        end
                        break
                    end
                end
            end
            if state.scroll_drag then
                if not input.down(1) then state.scroll_drag=nil
                elseif y then state.scroll_drag.move(y) end
            end
            if state.palette_drag then
                if not self.color_picker or not input.down(1) then
                    state.palette_drag = nil
                elseif x and y then
                    state.palette_drag(x, y)
                end
            end
            if state.color_drag then
                if not self.color_picker or not input.down(1) then
                    state.color_drag = nil
                elseif x and y then
                    self.color_picker.x = math.max(
                        0,
                        math.min(800, (x - state.color_drag.ox) / state.color_drag.scale - state.color_drag.dx)
                    )
                    self.color_picker.y = math.max(
                        0,
                        math.min(390, (y - state.color_drag.oy) / state.color_drag.scale - state.color_drag.dy)
                    )
                end
            end
            if state.split_drag then
                if not self.visible or not input.down(1) then
                    state.split_drag = nil
                elseif x then
                    self.sidebar_manual=true
                    self.sidebar_width =
                        math.max(300, math.min(650, (x - state.split_drag.ox) / state.split_drag.scale))
                end
            end
            if state.resize_drag then
                if not input.down(1) then
                    state.resize_drag = nil
                    if self.on_geometry_changed then self.on_geometry_changed(self.parent_geometry) end
                elseif x and y then
                    local g = geometry.drag(state.resize_drag.geometry, state.resize_drag.edge, x-state.resize_drag.x, y-state.resize_drag.y)
                    self.window_width,self.window_height,self.window_x,self.window_y = g.width,g.height,g.x,g.y
                end
            end
            if state.window_drag then
                if not self.visible or not input.down(1) then
                    if self.visible and self.on_geometry_changed then self.on_geometry_changed(self.parent_geometry) end
                    state.window_drag = nil
        state.resize_drag = nil
                elseif x and y then
                    self.window_x = math.max(0, math.min(state.window_drag.max_x, x - state.window_drag.dx))
                    self.window_y = math.max(0, math.min(state.window_drag.max_y, y - state.window_drag.dy))
                end
            end
            if state.drag then
                if not self.visible then
                    state.drag = nil
                elseif input.down(1) then
                    if x then
                        state.drag.move(x)
                    end
                else
                    local ok, err = (state.drag.mod.handle.edit or state.drag.mod.handle.set)(
                        state.drag.control.id,
                        state.drag.value
                    )
                    self.notice = ok
                            and (state.drag.control.page and state.drag.control.page.require_confirmation and "Pending confirmation" or "Saved")
                        or ("Could not save: " .. tostring(err))
                    state.drag = nil
                end
            end
            self.mouse_held = input.down(1)
        else
            self.mouse_held = input.down(1)
        end
    end
end
return MODULE
