-- Commands and matching hit regions; no native input or resources.
local MODULE = {}
function MODULE.install(context)
    local self,state,api,measure,M = context.self,context.state,context.api,context.measure,context.menu
    local geometry,theme = context.geometry,context.theme
    local active,selectable,change = context.active,context.selectable,context.change
    function self.compose(w, h)
        if not self.visible or not w or not h or w<=0 or h<=0 then
            state.hits = {}
            state.drag = nil
            state.window_drag = nil
            state.resize_drag = nil
            state.scroll_drag = nil
            self.pointer_x,self.pointer_y=nil,nil
            self.dropdown = nil
            self.text_edit = nil
            self.color_picker = nil
            return {}
        end
        local commands = {}
        state.hits = {}
        local g = geometry.bounds(w,h,self.window_width,self.window_height,self.window_x,self.window_y,self.ui_scale)
        self.window_width,self.window_height,self.window_x,self.window_y = g.width,g.height,g.x,g.y
        self.parent_geometry = g
        local font_scale=math.max(.8,math.min(1.3,self.font_scale or 1))
        local W,H,s,ox,oy = g.width,g.height,g.scale,g.x,g.y
        self.visible_rows = math.max(1,math.floor((H-327)/34))
        local tree_visible = math.max(1,math.floor((H-280)/31))
        self.sidebar_width = math.max(300,math.min(self.sidebar_manual and self.sidebar_width or math.max(300,math.min(360,W*.23)), W-600))
        local visible_text_age = {}
        local visible_switches={}
        state.switch_visual=state.switch_visual or {}
        self.window_x, self.window_y = ox, oy
        local T = theme.palette
        local white, muted, accent, selection_text = T.white, T.muted, T.focus, T.white
        local shape_layer = theme.layers.shell
        local function hovering(x,y,rw,rh)
            return self.pointer_x and self.pointer_y and self.pointer_x >= ox+x*s and self.pointer_x <= ox+(x+rw)*s and self.pointer_y >= oy+y*s and self.pointer_y <= oy+(y+rh)*s
        end
        local function rect(x, y, rw, rh, color, a)
            commands[#commands + 1] = {
                type = "rect",
                x = ox + x * s,
                y = oy + y * s,
                w = rw * s,
                h = rh * s,
                c = color,
                a = a or 1,
                layer = shape_layer,
                ui_role = (color == T.panel or color == T.background or color == T.header) and "surface" or ((color == T.selected or color == T.hover) and "selection" or "control"),
            }
        end
        local function mark(role,control_id)
            local command=commands[#commands]
            command.ui_role=role;command.control_id=control_id
            command.layer=theme.layers[role] or command.layer
        end
        -- Four edge strips never cover the interior when native handles are retained.
        local function border(x,y,width,height,color,id)
            local stroke=math.min(2,width/2,height/2)
            for _,edge in ipairs({{x,y,width,stroke},{x,y+height-stroke,width,stroke},
                {x,y+stroke,stroke,height-2*stroke},{x+width-stroke,y+stroke,stroke,height-2*stroke}}) do
                rect(edge[1],edge[2],edge[3],edge[4],color)
                mark("control_frame",id)
            end
        end
        local function text(x, y, value, size, color)
            local full = tostring(value)
            local width = math.max(0, (W-25) - x) * s
            local single = string.gsub(full, "[\r\n]+", " ")
            local visible = M.flow(single, width, (size or 20) * s * font_scale, 0, measure)
            commands[#commands + 1] = {
                type = "text",
                x = ox + x * s,
                y = oy + y * s,
                text = visible,
                full_text = full,
                text_width = width,
                size = (size or 20) * s * font_scale,
                c = color or white,
                a = 1,
                layer = theme.layers.text_control,
            }
        end
        local function bounded(x, y, value, size, color, width)
            local key = tostring(value) .. "|" .. x .. "|" .. y .. "|" .. width
            local animate = hovering(x,y-5,width,28) or (self.focus == "settings" and self.focused_label == tostring(value))
            local age=state.text_age[key]
            if not age or age.active~=animate then age={start=state.elapsed,active=animate} end
            visible_text_age[key]=age
            width = math.max(0, math.min(width, (W-25) - x))
            local result = M.flow(string.gsub(tostring(value), "[\r\n]+", " "), width * s, size * s * font_scale, animate and (state.elapsed - age.start) or 0, measure)
            text(x, y, result, size, color)
            commands[#commands].full_text = tostring(value)
            commands[#commands].text_width = width * s
        end
        local function hit(x, y, rw, rh, fn, right)
            state.hits[#state.hits + 1] = { x = ox + x * s, y = oy + y * s, w = rw * s, h = rh * s, click = fn, right=right }
        end
        local function scrollbar(role,x,y,height,total,visible,offset)
            if total<=visible then return end
            local thumb=math.max(20,height*visible/total)
            local travel=height-thumb;local maximum=total-visible
            local progress=math.max(0,math.min(1,offset/maximum));local ty=y+travel*(1-progress)
            rect(x,y,4,height,T.line)
            rect(x-1,ty,6,thumb,hovering(x-7,y,18,height) and T.focus or T.border)
            commands[#commands].scrollbar=role
            hit(x-7,y,18,height,function(_,my)
                local local_y=(my-oy)/s
                local grab=local_y>=ty and local_y<=ty+thumb and local_y-ty or thumb/2
                state.scroll_drag={move=function(pointer_y)
                    local position=((pointer_y-oy)/s-grab-y)/travel
                    local value=math.floor((1-math.max(0,math.min(1,position)))*maximum+.5)
                    if role=="mods" then state.tree_scroll=value;state.tree_manual=true
                    elseif role=="settings" then self.scroll=value;state.manual_scroll=true
                    elseif role=="help" then self.help_scroll=value
                    elseif role=="dropdown" and self.dropdown then self.dropdown.scroll=value end
                end}
                state.scroll_drag.move(my)
            end)
        end
        shape_layer=86
        rect(5,-5,W,H,{5,6,7},.7)
        shape_layer=theme.layers.shell
        rect(0, 0, W, H, T.border)
        rect(1, 1, W-2, H-2, T.background, 0.99)
        rect(1, 60, self.sidebar_width-1, H-120, T.panel)
        rect(1, (H-60), W-2, 59, T.header)
        rect(self.sidebar_width, 60, 1, H-120, T.line)
        rect(18, H-46, 3, 30, accent)
        -- Inset workspace frames, with squared industrial corners.
        border(10,154,self.sidebar_width-22,H-222,T.line,"navigation_panel")
        border(self.sidebar_width+12,202,W-self.sidebar_width-26,H-270,T.border,"settings_panel")
        for index=#commands-7,#commands do commands[index].layer=92 end
        local function hazard(y,height,period)
            for line=0,height-1,2 do
                for band=-1,math.ceil(W/period) do
                    local left=band*period+period/2-line
                    local start=math.max(2,left)
                    local finish=math.min(W-2,left+period/2)
                    if finish>start then
                        rect(start,y+line,finish-start,math.min(2,height-line),T.focus)
                        commands[#commands].hazard_stripe=true
                    end
                end
            end
        end
        hazard(H-14,12,26);hazard(2,3,30)
        -- Winged skull silhouette: native geometry, independent of font or game assets.
        local skull={"0000011111100000","0001111111111000","0011111111111100","0111111111111110",
            "0110001110001110","0110001110001110","0111110101111110","0011110001111100",
            "0001111111111000","0000111111110000","0000101010100000","0000101010100000"}
        local px,py,unit=20,H-43,2
        for row,bits in ipairs(skull) do
            local run
            for col=1,#bits+1 do
                if bits:sub(col,col)=="1" then run=run or col
                elseif run then
                    rect(px+(run-1)*unit,py+(#skull-row)*unit,(col-run)*unit,unit,T.focus)
                    commands[#commands].brand_skull=true;run=nil
                end
            end
        end
        for side=-1,1,2 do
            for feather=0,3 do
                rect(side<0 and px-10+feather*2 or px+30,py+9+feather*3,10-feather*2,2,T.focus)
                commands[#commands].brand_skull=true
            end
        end
        shape_layer = theme.layers.control
        hit(0, (H-60), W, 60, function(mx, my)
            if state.drag or self.capture then
                return
            end
            state.window_drag =
                { dx = mx - ox, dy = my - oy, max_x = math.max(0, w - W * s), max_y = math.max(
                    0,
                    h - H * s
                ) }
        end)
        state.wheel_bounds = { x = ox, y = oy + 196 * s, w = W * s, h = (H-316) * s, split = ox
            + self.sidebar_width * s }
        text(65, (H-43), "LIVE LUA LOADER", theme.typography.title, white)
        rect(W-220,H-45,150,30,hovering(W-220,H-45,150,30) and T.field_hover or T.field)
        text(W-210,H-38,"Settings",18,white)
        hit(W-220,H-45,150,30,function()
            for index,owner in ipairs(api.list()) do
                for page_index,candidate in ipairs(owner.pages) do
                    if candidate.id=="manager_settings" then
                        self.selected,self.page,self.row,self.scroll=index,page_index,1,0
                        state.manual_scroll=false;self.focus="settings";return
                    end
                end
            end
        end)
        rect((W-55), (H-45), 38, 30, T.field)
        text((W-43), (H-38), "X", 20, white)
        hit((W-55), (H-45), 38, 30, function()
            self.visible = false
            self.capture = false
            self.dropdown = nil
            self.text_edit = nil
            self.color_picker = nil
        end)
        text(25, (H-105), "LOADER SOURCES", 16, muted)
        local mods = api.list()
        local mod, page = active()
        local sidebar = self.sidebar()
        local layout={}
        local top,bottom=H-118,160
        for index,entry in ipairs(sidebar) do
            local name=entry.kind=="mod" and entry.mod.name or (entry.kind=="category" and entry.category.name or entry.page.name)
            local status,badge
            if entry.kind=="page" then status=name:match("^%[([^%]]+)%]");name=name:gsub("^%[[^%]]+%]%s*","") end
            if entry.kind=="category" then
                local loaded,total=name:match("%((%d+) loaded / (%d+)%)")
                if loaded then badge=loaded.."/"..total;name=name:gsub("%s*%(%d+ loaded / %d+%)","") end
                name=name:gsub("^LLL live scripts$","Live scripts"):gsub("^Archive addons via LLL$","Archive addons"):gsub("^Unknown / conflicting owner$","Needs review")
            end
            local icon_x=18+entry.depth*18
            local label_x=icon_x+22
            local label_width=self.sidebar_width-22-label_x-(badge and 50 or 0)
            local font=entry.kind=="mod" and 18 or 16
            local lines=M.rich(name,label_width*s,font*s*font_scale,measure)
            local labels={}
            local line_height=math.ceil(font*font_scale)+4
            local max_lines=math.max(1,math.floor((top-bottom-8)/line_height))
            for line_index=1,math.min(max_lines,#lines) do
                local parts={};for _,span in ipairs(lines[line_index].spans) do parts[#parts+1]=span.text end
                labels[#labels+1]=table.concat(parts)
            end
            if #lines>max_lines then labels[max_lines]=M.flow(labels[max_lines],math.max(0,label_width*s-M.width("...",font*s*font_scale,measure)),font*s*font_scale,0,measure).."..." end
            layout[index]={entry=entry,name=name,status=status,badge=badge,icon_x=icon_x,label_x=label_x,label_width=label_width,font=font,labels=labels,line_height=math.ceil(font*font_scale)+4,height=math.max(32,#labels*(math.ceil(font*font_scale)+4)+8)}
        end
        local tail,count=0,0
        for index=#layout,1,-1 do if tail+layout[index].height>top-bottom then break end;tail=tail+layout[index].height;count=count+1 end
        state.tree_max=math.max(0,#sidebar-count)
        state.tree_scroll=math.max(0,math.min(state.tree_scroll,state.tree_max))
        if not state.tree_manual then
            for index,node in ipairs(sidebar) do
                if node.kind=="mod" and node.index==self.selected and index<=state.tree_scroll then state.tree_scroll=index-1 end
            end
        end
        local y=top;local visible=0;local centers={}
        for index=state.tree_scroll+1,#layout do
            local node=layout[index];local entry=node.entry
            if y-node.height<bottom then break end
            local baseline=y-node.line_height
            local cy=baseline+node.font*font_scale*.4;centers[index]=cy
            local selected=entry.kind=="page" and entry.mod_index==self.selected and entry.index==self.page
                or entry.kind=="mod" and entry.index==self.selected and not entry.open
            rect(12,y-node.height+2,self.sidebar_width-28,node.height-4,selected and T.selected or (hovering(12,y-node.height+2,self.sidebar_width-28,node.height-4) and T.hover or T.panel))
            commands[#commands].layer=theme.layers.row
            if entry.depth>0 then
                local parent=index-1
                while parent>0 and sidebar[parent].depth>=entry.depth do parent=parent-1 end
                local parent_y=centers[parent] or top-2
                local spine=18+(entry.depth-1)*18+7
                local junction=cy
                local trunk_top=math.max(junction,math.min(top-2,parent_y))
                rect(spine,junction,1,trunk_top-junction,T.border)
                commands[#commands].tree_branch={row_y=oy+(cy-6)*s,junction=oy+junction*s,top=oy+trunk_top*s,parent=parent}
                rect(spine,junction,node.icon_x-spine+4,1,T.border)
            end
            if entry.kind~="page" then
                rect(node.icon_x+3,cy-1,9,2,muted);mark("indicator","tree/"..index)
                if not entry.open then rect(node.icon_x+6,cy-4,2,9,muted);mark("indicator","tree/"..index)end
            elseif node.status then
                local status_color=node.status=="Loaded" and T.enabled or (node.status=="Disabled" and T.disabled or T.brass)
                rect(node.icon_x+4,cy-2,6,6,status_color);mark("indicator","status/"..index)
            end
            for line_index,label in ipairs(node.labels) do
                bounded(node.label_x,baseline-(line_index-1)*node.line_height,label,node.font,selected and white or (entry.kind=="category" and T.brass or white),node.label_width)
                commands[#commands].full_text=entry.kind=="page" and entry.page.name or node.name
                commands[#commands].navigation_label=true
                commands[#commands].navigation_depth=entry.depth
            end
            if node.badge then bounded(self.sidebar_width-66,cy-5,node.badge,13,muted,44)end
            hit(12,y-node.height+2,self.sidebar_width-28,node.height-4,function()
                if entry.kind=="mod" then
                    self.selected=entry.index;state.tree_expanded[entry.mod.id]=not entry.open;self.page=1
                elseif entry.kind=="category" then state.expanded[entry.key]=not entry.open
                else self.selected,self.page=entry.mod_index,entry.index end
                self.row,self.scroll=1,0;state.manual_scroll=false;state.tree_manual=true;self.focus="settings"
            end)
            local node_hit=state.hits[#state.hits]
            node_hit.right=function(mx,my)
                local actions={{label=entry.kind=="page" and "Open" or "Expand / Collapse",run=node_hit.click},{label="Collapse all",run=self.collapse_all},{label="Expand all",run=self.expand_all}}
                if entry.kind=="page" and entry.page.resource_id and api.open_metadata then
                    actions[#actions+1]={label="Edit metadata",disabled=not api.can_edit_metadata(),run=function()local ok,why=api.open_metadata(entry.page.resource_id);if not ok then self.notice=why end end}
                end
                self.open_context(mx,my,actions)
            end
            y=y-node.height;visible=visible+1
        end
        self.mod_scroll=state.tree_scroll
        scrollbar("mods",self.sidebar_width-9,bottom,top-bottom,#sidebar,math.max(1,visible),state.tree_scroll)
        if not mod then
            text(365, (H-150), "No mods registered. See the author example.", 24)
        else
            bounded(self.sidebar_width+24,H-108,page.name,theme.typography.heading,white,W-self.sidebar_width-48)
            if mod.name~="Live Lua Loader" then bounded(self.sidebar_width+24,H-81,mod.name,14,muted,W-self.sidebar_width-48)end
            bounded(self.sidebar_width+24,90,
                "Page "..self.page.." / "..#mod.pages.."  |  PgUp / PgDn",
                theme.typography.hint,muted,
                page.require_confirmation and W-364-self.sidebar_width-24 or W-self.sidebar_width-48)
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
                bounded(self.sidebar_width+24,112,"CONFIRM REQUIRED ("..pending..")",
                    theme.typography.hint,accent,W-self.sidebar_width-48)
                rect((W-340), 81, 135, 29, T.field)
                text((W-330), 90, "APPLY", 18, accent)
                rect((W-190), 81, 135, 29, T.field)
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
            local resettable=selected and selected.default~=nil and not selected.disabled and selected.type~="button"
            rect(20,116,self.sidebar_width-40,30,resettable and T.field or T.panel)
            bounded(30,123,"RESET SETTING",15,resettable and white or T.disabled,self.sidebar_width-60)
            hit(20,116,self.sidebar_width-40,30,function()
                if not resettable then return end
                local ok,why=(mod.handle.edit or mod.handle.set)(selected.id,selected.default)
                self.notice=ok and "Default restored" or tostring(why)
            end)
            local settings_x = self.sidebar_width + 24
            local available = (W-25) - settings_x
            local wide = available < 1050 or type(page.render_preview) ~= "function"
            for _, control in ipairs(page.controls) do
                if control.column and available >= 1050 then wide = false end
            end
            local row_width = math.min(800,wide and available or available / 2 - 12)
            local column_stride=row_width+24
            local display, columns, ordinal = {}, {0,0}, 0
            local selected_at, selected_column = 1, 1
            for _, control in ipairs(page.controls) do
                if control.type=="section" and control.label:match("^LIVE LUA LOADER R%d+") then
                    -- The application header already identifies the loader.
                else
                if control.type ~= "text" and control.type ~= "section" then ordinal=ordinal+1 end
                local col = wide and 1 or (control.column == 2 and 2 or 1)
                if control.type=="text" then
                    for _,line in ipairs(M.rich(control.label,row_width*s,18*s*font_scale,measure)) do
                        local parts={};for _,span in ipairs(line.spans) do parts[#parts+1]=span.text end
                        columns[col]=columns[col]+1
                        display[#display+1]={control=control,label=table.concat(parts),column=col,line=columns[col],row=ordinal}
                    end
                else
                    columns[col]=columns[col]+1
                    display[#display+1]={control=control,label=control.label,column=col,line=columns[col],row=ordinal}
                    if control==selected then selected_at,selected_column=columns[col],col end
                end
            end
                end
            self.display_total=math.max(columns[1],columns[2])
            local function column_offset(col)
                return math.min(self.scroll,math.max(0,columns[col]-self.visible_rows))
            end
            local selected_offset=column_offset(selected_column)
            if not state.manual_scroll and selected_at<=selected_offset then self.scroll=selected_at-1 end
            if not state.manual_scroll and selected_at>selected_offset+self.visible_rows then self.scroll=selected_at-self.visible_rows end
            self.scroll=math.max(0,math.min(self.scroll,math.max(0,self.display_total-self.visible_rows)))
            for i, entry in ipairs(display) do
                local c=entry.control
                local offset=column_offset(entry.column)
                if entry.line>offset and entry.line<=offset+self.visible_rows then
                    local col=entry.column
                    local x=settings_x+(col-1)*column_stride
                    local y=(H-157)-(entry.line-offset-1)*34
                    local selected_row=entry.row
                    local row_index = selected_row
                    local row_hover = not self.dropdown and not self.color_picker and hovering(x-5,y-7,row_width+5,30)
                    rect(x-5,y-7,row_width+5,30,c==selected and T.selected or (row_hover and T.hover or (i%2==0 and T.panel or T.background)))
                    commands[#commands].layer=theme.layers.row
                    commands[#commands].ui_role="setting_row"
                    commands[#commands].hovered=row_hover==true
                    commands[#commands].focused=c==selected and self.focus=="settings"
                    rect(x-5,y-7,2,30,c==selected and (self.focus=="settings" and T.focus or T.border) or T.background)
                    commands[#commands].layer=theme.layers.focus
                    self.focused_label=selected and selected.label
                    local color = c.disabled and muted or accent
                    local informational = c.type == "text" or c.type == "section"
                    local label = entry.label or ""
                    local button_label,button_width,choice_width,choice_total
                    if c.type=="choice" then
                        local value=(mod.handle.preview or mod.handle.get)(c.id)
                        local presentation=c.presentation or "combined"
                        local arrows=presentation=="dropdown" and 0 or 60
                        choice_width=math.max(180,math.min(row_width-160-arrows,M.width(tostring(c.choices[value]),18*s*font_scale,measure)/s+(presentation=="selector" and 24 or 60)))
                        choice_total=choice_width+arrows
                    end
                    if c.type=="button" or c.type=="keybind" then
                        local value=(mod.handle.preview or mod.handle.get)(c.id)
                        button_label=c.type=="button" and (c.button_label or c.label or "Activate") or (value==0 and "BIND KEY" or theme.key_name(value))
                        button_width=math.max(175,math.min(row_width-80,M.width(button_label,18*s*font_scale,measure)/s+24))
                    end
                    local label_width = informational and row_width or math.min(260,math.max(0,row_width - (choice_total and choice_total+18 or (button_width and button_width+14 or 290))))
                    bounded(
                        x,
                        y,
                        label,
                        18,
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
                        local vx = x + math.min(280,row_width-290) - 245
                        local function select()
                            self.row = row_index
                            self.focus = "settings"
                        end
                        hit(x - 5, y - 7, row_width + 5, 34, function()
                            select()
                        end,function(mx,my)
                            select()
                            local actions={
                                {label="Apply page",run=self.apply},
                                {label="Discard page",run=function()owner.handle.discard(page.id);self.notice="Pending edits discarded" end},
                                {label="Reset setting",disabled=control.disabled or control.default==nil or control.type=="button",run=function()
                                    local ok,why=(owner.handle.edit or owner.handle.set)(control.id,control.default);self.notice=ok and "Default restored" or tostring(why)
                                end},
                            }
                            if control.type=="keybind" then actions[#actions+1]={label="Rebind key",disabled=control.disabled,run=function()change(control,0)end}end
                            self.open_context(mx,my,actions)
                        end)
                        if c.type == "slider" then
                            if state.drag and state.drag.mod == mod and state.drag.control == c then
                                value = state.drag.value
                            end
                            local track = vx + 245
                            local width = 180
                            local fraction =
                                math.max(0, math.min(1, (value - c.min) / (c.max - c.min)))
                            rect(track, y + 5, width, 5, T.line)
                            rect(track, y + 5, width * fraction, 5, color)
                            mark("fill",mod.id.."/"..c.id)
                            rect(track + width * fraction - 6, y - 2, 12, 19, color)
                            mark("indicator",mod.id.."/"..c.id)
                            local editing = self.text_edit
                                and self.text_edit.mod == mod
                                and self.text_edit.control == c
                            rect(
                                vx + 435,
                                y - 5,
                                90,
                                29,
                                editing and T.selected
                                    or (c == selected and T.field_hover or T.field)
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
                                state.drag = d
                                d.move(mx)
                            end)
                        elseif c.type == "input" then
                            local editing = self.text_edit and self.text_edit.control == c
                            hit(vx + 245, y - 5, 250, 29, function()
                                select()
                                change(control, 0)
                            end)
                            rect(
                                vx + 245,
                                y - 5,
                                250,
                                29,
                                c == selected and T.field_hover or T.field
                            )
                            bounded(
                                vx + 255,
                                y,
                                editing and self.text_edit.text .. "|" or value,
                                18,
                                c == selected and selection_text or white,
                                230
                            )
                        elseif c.type == "color" then
                            rect(vx + 300, y - 3, 34, 23, api.color_rgb(value));mark("indicator",mod.id.."/"..c.id)
                            rect(
                                vx + 350,
                                y - 5,
                                175,
                                29,
                                c == selected and T.field_hover or T.field
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
                            hit(vx + 245, y - 5, 175, 29, function()
                                select()
                                change(control, 0)
                            end)
                            rect(
                                vx + 245,
                                y - 5,
                                175,
                                29,
                                c == selected and T.field_hover or T.field
                            )
                            local id=mod.id.."/"..c.id
                            local sx=vx+249
                            local target=value and 28 or 4
                            local visual=state.switch_visual[id] or {value=value,position=target,start=state.elapsed,from=target}
                            if visual.value~=value then visual={value=value,position=visual.position,from=visual.position,start=state.elapsed} end
                            local progress=math.min(1,math.max(0,(state.elapsed-visual.start)/.12))
                            visual.position=visual.from+(target-visual.from)*progress
                            visible_switches[id]=visual
                            rect(sx+2,y+1,52,17,c.disabled and T.panel or (value and T.selected or {52,56,59}))
                            mark("fill",id)
                            border(sx,y-1,56,21,c.disabled and T.line or (value and T.focus or T.border_hover),id)
                            rect(sx+visual.position,y+3,24,13,c.disabled and T.disabled or (value and T.focus or T.muted))
                            mark("indicator",id);commands[#commands].indicator_kind="sliding_switch"
                            text(
                                vx + 325,
                                y,
                                value and "ON" or "OFF",
                                19,
                                c.disabled and muted or (c == selected and selection_text or white)
                            )
                            mark("text_control",mod.id.."/"..c.id);commands[#commands].indicator_kind="toggle_label"
                        elseif c.type == "choice" then
                            local presentation = c.presentation or "combined"
                            local chosen = c == selected and selection_text or white
                            local symbol = c == selected and selection_text or color
                            local cw=choice_width
                            local cx=x+math.min(280,row_width-cw-60)+(presentation=="dropdown" and 0 or 30)
                            local previous_x,next_x=cx-30,cx+cw+3
                            if presentation ~= "dropdown" then
                                rect(
                                    previous_x,
                                    y - 5,
                                    27,
                                    29,
                                    c == selected and T.field_hover or T.field
                                )
                                text(previous_x + 7, y, "<", 18, symbol)
                                mark("text_control",mod.id.."/"..c.id);commands[#commands].indicator_kind="choice_previous"
                                rect(
                                    next_x,
                                    y - 5,
                                    27,
                                    29,
                                    c == selected and T.field_hover or T.field
                                )
                                text(next_x + 7, y, ">", 18, symbol)
                                mark("text_control",mod.id.."/"..c.id);commands[#commands].indicator_kind="choice_next"
                                hit(previous_x, y - 5, 27, 29, function()
                                    select()
                                    change(control, -1)
                                end)
                                hit(next_x, y - 5, 27, 29, function()
                                    select()
                                    change(control, 1)
                                end)
                            end
                            rect(cx, y - 5, cw, 29, c == selected and T.field_hover or T.field)
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
                                    c == selected and T.field_hover or T.field
                                )
                                mark("indicator",mod.id.."/"..c.id)
                                text(cx + cw - 20, y, "v", 18, symbol)
                                mark("text_control",mod.id.."/"..c.id);commands[#commands].indicator_kind="choice_dropdown"
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
                            local label,bw=button_label,button_width
                            local bx=x+math.min(280,row_width-bw)
                            hit(bx,y-5,bw,29,function()select();change(control,0)end)
                            rect(bx,y-5,bw,29,c==selected and T.field_hover or T.field)
                            bounded(bx+12,y,label,18,c==selected and selection_text or color,bw-24)
                            mark("text_control",mod.id.."/"..c.id);commands[#commands].indicator_kind=c.type=="button" and "button_label" or "binding_label"

                        end
                    end
                end
            end
            scrollbar("settings", (W-20), 196, H-330, self.display_total, self.visible_rows, self.scroll)
            if self.display_total > self.visible_rows then
                text(
                    365,
                    166,
                    "Rows "
                        .. (self.scroll + 1)
                        .. "-"
                        .. math.min(self.scroll + self.visible_rows, self.display_total)
                        .. " of "
                        .. self.display_total,
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
            if wide and available-row_width-24>=260 then
                local dx=settings_x+row_width+24
                local dw=available-row_width-24
                local dy=H-168
                rect(dx-8,204,dw+8,H-360,T.panel);commands[#commands].layer=92
                local first=#commands+1
                border(dx-8,204,dw+8,H-360,T.line,"detail_panel")
                for index=first,#commands do commands[index].layer=92 end
                bounded(dx,dy,"SELECTION DETAILS",theme.typography.hint,T.focus,dw-12)
                bounded(dx,dy-30,selected and selected.label or page.name,theme.typography.heading,white,dw-12)
                local detail=selected and selected.description or mod.description or "Select a setting to view its details."
                local line_height=math.ceil(18*font_scale)+5
                local maximum=math.max(1,math.floor((H-438)/line_height))
                for index,line in ipairs(M.rich(detail,(dw-12)*s,18*s*font_scale,measure)) do
                    if index>maximum then break end
                    local parts={};for _,span in ipairs(line.spans)do parts[#parts+1]=span.text end
                    bounded(dx,dy-62-(index-1)*line_height,table.concat(parts),18,muted,dw-12)
                end
            end
            local help = selected and selected.description or mod.description
            local key = mod.id .. "/" .. page.id .. "/" .. tostring(help)
            if state.help_key ~= key then
                self.help_scroll = 0
                state.help_key = key
            end
            local hx = self.sidebar_width + 35
            local hw = (W-40) - hx
            local lines = M.rich(help, hw * s, 18 * s * font_scale, measure)
            local help_line_height=math.ceil(18*font_scale)+4
            local visible = math.max(1,math.floor(64/help_line_height))
            self.help_scroll = math.min(self.help_scroll, math.max(0, #lines - visible))
            state.help_bounds =
                { x = ox + hx * s, y = oy + 126 * s, w = hw * s, h = 64 * s, maximum = math.max(
                    0,
                    #lines - visible
                ) }
            for index = self.help_scroll + 1, math.min(#lines, self.help_scroll + visible) do
                local line = lines[index]
                local tx = hx
                local ty = 190 - help_line_height - (index - self.help_scroll - 1) * help_line_height
                for _, span in ipairs(line.spans) do
                    text(
                        tx,
                        ty,
                        span.text,
                        line.size / (s * font_scale),
                        span.style == "plain" and muted
                            or (span.style == "emphasis" and white or accent)
                    )
                    tx = tx + span.width / s
                end
            end
            scrollbar("help", (W-30), 126, 64, #lines, visible, self.help_scroll)
        end
        hit(self.sidebar_width - 6, 196, 12, H-310, function()
            state.split_drag = { ox = ox, scale = s }
        end)
        text(
            25,
            32,
            theme.key_name(api.menu_toggle_key or 45).." Close   "..theme.key_name(api.apply_key or 9).." Apply   "..theme.key_name(api.focus_key or 117).." Focus   Right-click Actions",
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
            rect(x - 2, top - height - 2, 254, height + 4, T.border)
            commands[#commands].ui_role="frame"
            rect(x, top - height, 250, height, T.panel)
            for index = d.scroll + 1, math.min(#d.control.choices, d.scroll + count) do
                local y = top - 29 - (index - d.scroll - 1) * 31
                local choice = index
                if index == d.selected then
                    rect(x + 3, y - 4, 234, 30, T.selected)
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
                commands[index].layer = theme.overlay_layer(commands[index],theme.layers.popup)
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
                state.color_drag = { ox = ox, oy = oy, scale = s, dx = (mx - ox) / s - px, dy = (my - oy)
                        / s
                    - py }
            end)
            rect(px - 2, py - 2, 704, 434, T.border)
            commands[#commands].ui_role="frame"
            rect(px, py, 700, 430, T.panel)
            rect(px + 650, py + 389, 32, 30, T.field)
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
                state.palette_drag = spectrum
                spectrum(mx, my)
            end)
            hit(px + 262, py + 160, 25, 204, function(mx, my)
                state.palette_drag = value_slider
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
            rect(px + 550, py + 78, 130, 32, T.field)
            text(px + 560, py + 88, "SAVE SWATCH", 16, accent)
            hit(px + 550, py + 78, 130, 32, function()
                local ok, err = api.save_swatch(p.rgb)
                self.notice = ok and "Custom swatch saved" or tostring(err)
            end)
            rect(px + 550, py + 119, 130, 32, T.field)
            text(px + 557, py + 129, "REPLACE", 16, p.selected_swatch and accent or muted)
            hit(px + 550, py + 119, 130, 32, function()
                if not p.selected_swatch then
                    self.notice = "Select a saved swatch first"
                    return
                end
                local ok, err = api.replace_swatch(p.selected_swatch, p.rgb)
                self.notice = ok and "Selected swatch replaced" or tostring(err)
            end)
            rect(px + 20, py + 20, 300, 32, T.field)
            text(px + 35, py + 29, "USE COLOR", 18, accent)
            hit(px + 20, py + 20, 300, 32, function()
                self.commit_color()
            end)
            rect(px + 370, py + 20, 310, 32, T.field)
            text(px + 390, py + 29, "CANCEL", 18, white)
            hit(px + 370, py + 20, 310, 32, function()
                self.color_picker = nil
                self.text_edit = nil
            end)
            for index = start, #commands do
                commands[index].popup = true
                commands[index].layer = theme.overlay_layer(commands[index],theme.layers.picker)
            end
        end
        for _, edge in ipairs({
            {"left",0,0,8,H},{"right",W-8,0,8,H},{"bottom",0,0,W,8},{"top",0,H-8,W,8},
            {"left_bottom",0,0,14,14},{"right_bottom",W-14,0,14,14},
            {"left_top",0,H-14,14,14},{"right_top",W-14,H-14,14,14},
        }) do
            local name=edge[1]
            if string.find(name,"_",1,true) then
                local right=string.find(name,"right",1,true)~=nil
                local top=string.find(name,"top",1,true)~=nil
                local color=(state.resize_drag and state.resize_drag.edge==name or hovering(edge[2],edge[3],edge[4],edge[5])) and T.brass or T.focus
                local x=right and W-15 or 3
                local y=top and H-6 or 3
                rect(x,y,12,3,color)
                commands[#commands].resize_handle=name;mark("indicator","resize/"..name)
                rect(right and W-6 or 3,top and H-15 or 3,3,12,color)
                commands[#commands].resize_handle=name;mark("indicator","resize/"..name)
            end
            hit(edge[2],edge[3],edge[4],edge[5],function(mx,my)
                if state.drag or self.capture then return end
                state.resize_drag={edge=name,x=mx,y=my,geometry=g}
            end)
        end
        if self.context_menu then
            local popup=self.context_menu
            local pw=250;local ph=#popup.actions*34+8
            local px=math.max(2,math.min(W-pw-2,(popup.x-ox)/s))
            local py=math.max(2,math.min(H-ph-2,(popup.y-oy)/s-ph))
            local start=#commands+1
            hit(-ox/s,-oy/s,w/s,h/s,function()self.context_menu=nil end,function()self.context_menu=nil end)
            rect(px-1,py-1,pw+2,ph+2,T.border);commands[#commands].ui_role="frame"
            rect(px,py,pw,ph,T.panel)
            for index,action in ipairs(popup.actions) do
                local y=py+ph-34*index
                rect(px+3,y,pw-6,32,(popup.selected==index or hovering(px+3,y,pw-6,32)) and T.selected or T.panel)
                bounded(px+12,y+8,action.label,18,action.disabled and T.disabled or white,pw-24)
                hit(px+3,y,pw-6,32,function()
                    self.context_menu=nil
                    if not action.disabled then local ok,why=pcall(action.run);if not ok then self.notice=tostring(why) end end
                end)
            end
            for index=start,#commands do commands[index].popup=true;commands[index].context_action=true;commands[index].layer=theme.overlay_layer(commands[index],theme.layers.picker)end
        end
        local field_count=#commands
        for index=1,field_count do
            local field=commands[index]
            if field.type=="rect" and (field.c==T.field or field.c==T.field_hover) then
                local x,y=(field.x-ox)/s,(field.y-oy)/s
                local edge_color=hovering(x,y,field.w/s,field.h/s) and T.border_hover or T.border
                local start=#commands+1
                border(x,y,field.w/s,field.h/s,edge_color,field.control_id)
                for j=start,#commands do
                    commands[j].popup=field.popup
                    commands[j].layer=field.popup and field.layer+1 or theme.layers.control_frame
                end
            end
        end
        state.switch_visual=visible_switches
        state.text_age = visible_text_age
        return commands
    end
end
return MODULE
