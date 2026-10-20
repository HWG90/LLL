local Core=dofile('src/ui/core.lua')
local Menu=dofile('src/ui/menu.lua')
local Theme=dofile('src/ui/theme.lua')
local Preferences=dofile('src/ui/preferences.lua')
local function has(commands,label)
    for _,c in ipairs(commands) do if c.full_text==label then return c end end
end
local function export(name,commands,w,h)
    local f=assert(io.open('tests/tmp/ui-'..name..'.json','w'))
    f:write('{"width":'..w..',"height":'..h..',"commands":[')
    for i,c in ipairs(commands) do
        local text=(c.text or ''):gsub('\\','\\\\'):gsub('"','\\"'):gsub('\n','\\n'):gsub('\r','\\r'):gsub('\t','\\t')
        f:write((i>1 and ',' or '')..string.format('{"type":"%s","x":%.3f,"y":%.3f,"w":%.3f,"h":%.3f,"size":%.3f,"depth":%.3f,"a":%.3f,"c":[%d,%d,%d],"text":"%s"}',c.type,c.x,c.y,c.w or 0,c.h or 0,c.size or 0,Theme.depth(c),c.a,c.c[1],c.c[2],c.c[3],text))
    end
    f:write(']}');f:close()
end
local controls={}
for col,count in ipairs({16,30}) do
    for index=1,count do controls[#controls+1]={type='toggle',id='col'..col..'_'..index,column=col,label=(col==1 and 'Left ' or 'Right ')..string.format('%02d',index),default=false} end
end
local api=Core.new()
local handle=api.register({id='columns',name='Uneven columns',pages={{id='main',name='Two-column settings',dynamic=true,controls=controls}}})
api.author_navigation=true
local menu=Menu.new(api)
menu.visible=true;menu.window_width=1800;menu.window_height=820
menu.expand_all()
local commands=menu.compose(1920,1080)
assert(menu.display_total==30 and has(commands,'Left 01') and has(commands,'Right 01'))
assert(has(commands,'Insert Close   Tab Apply   F6 Focus   Right-click Actions'),'Unconfigured manager hint must use Insert')
local g=menu.parent_geometry
menu.wheel(-240,g.x+(g.width-50)*g.scale,g.y+400*g.scale)
commands=menu.compose(1920,1080)
assert(menu.scroll==6 and has(commands,'Left 05') and has(commands,'Right 07'),'uneven columns use their own offset away from zero')
export('columns',commands,1920,1080)
menu.key(117);menu.row=35;commands=menu.compose(1920,1080)
assert(has(commands,'Right 19'),'keyboard selection remains in the correct column viewport')
menu.window_width=1100;commands=menu.compose(1920,1080)
assert(menu.display_total==46,'narrow windows flatten both columns before calculating widths')
for _,c in ipairs(commands) do if c.type=='text' then assert(c.x+c.text_width<=menu.parent_geometry.x+menu.parent_geometry.width*menu.parent_geometry.scale+.01) end end
export('compact',commands,1920,1080)
-- Drag the settings scrollbar through the real pointer path, then cancel on close.
menu.row=1;menu.key(117);commands=menu.compose(1920,1080)
local thumb
for _,c in ipairs(commands) do if c.scrollbar=='settings' then thumb=c end end
assert(thumb)
local mx,my,down=thumb.x+2,thumb.y+thumb.h/2,false
local input={down=function(code)return code==1 and down end,mouse=function()return mx,my end}
menu.tick(input);down=true;menu.tick(input);my=my-100;menu.tick(input)
assert(menu.scroll>0,'scrollbar owns a continuous drag')
down=false;menu.tick(input)
local previous=menu.scroll;my=my+100;menu.tick(input);assert(menu.scroll==previous,'released scrollbar stops moving')
menu.visible=false;menu.compose(1920,1080);menu.tick(input)
menu.visible=true;menu.tick(input);assert(menu.scroll==previous,'closed menu cancels drag')
-- Native renderer: field/text depth stays stable when unrelated rows are inserted.
local allocated,destroyed,serial=0,0,0
local live_ids,events={},{}
local world={}
local sr={Application={worlds=function()return {world}end,main_world=function()return world end},World={create_screen_gui=function()return {}end,destroy_gui=function()end},Vector3=function(x,y,z)return {x=x,y=y,z=z}end,Vector2=function(x,y)return {x=x,y=y}end,Color=function(a,r,g,b)return {a,r,g,b}end,Gui={}}
local function allocate(kind,position)
    allocated=allocated+1;serial=serial+1
    live_ids[serial]={type=kind,z=position.z};events[#events+1]='allocate';return serial
end
sr.Gui.rect=function(_,position)return allocate('rect',position)end
sr.Gui.text=function(_,_,_,_,_,position)return allocate('text',position)end
local function destroy(_,id)assert(live_ids[id]);live_ids[id]=nil;destroyed=destroyed+1;events[#events+1]='destroy'end
sr.Gui.destroy_rect=destroy;sr.Gui.destroy_text=destroy
local view=dofile('src/ui/view.lua').new(sr)
local baseline={{type='rect',x=0,y=0,w=400,h=100,c=Theme.palette.background,a=1,layer=90},{type='rect',x=5,y=5,w=390,h=34,c=Theme.palette.selected,a=1,layer=95},{type='rect',x=200,y=7,w=175,h=29,c=Theme.palette.field,a=1,layer=100},{type='text',x=220,y=10,text='OFF',size=20,c=Theme.palette.white,a=1,layer=100}}
view.draw(baseline);local initial=allocated;view.draw(baseline);assert(allocated==initial,'unchanged native primitives are retained')
baseline[2].c=Theme.palette.hover;events={};view.draw(baseline)
assert(allocated==initial+1 and destroyed==1,'hover replaces only the row; field and text stay retained')
local field_id,text_id
for id,item in pairs(live_ids)do if item.z==100 then field_id=id elseif item.z==101 then text_id=id end end
assert(field_id and text_id)
table.insert(baseline,2,{type='rect',x=0,y=105,w=5,h=5,c=Theme.palette.line,a=1,layer=95})
events={};view.draw(baseline)
local alloc_seen=false
for _,event in ipairs(events)do if event=='allocate' then alloc_seen=true else assert(not alloc_seen,'destroy stale IDs before allocations') end end
for _,item in pairs(live_ids)do assert(item.z==90 or item.z==95 or item.z==100 or item.z==101,'command counts must not drift depth') end
view.release();assert(next(live_ids)==nil,'all native primitives release')
-- Actual game screenshot exposed native extents smaller than drawn glyphs.
-- Exercise the native measurement route, not the desktop preview font alone.
sr.Gui.text_extents=function(_,value,_,size)return {x=0},{x=#value*size*.35}end
local measured_view=dofile('src/ui/view.lua').new(sr)
measured_view.draw(baseline)
assert(measured_view.measure('M',20)>=20*.62)
assert(measured_view.measure('Runtime Texture',20)>=15*20*.62)
local overflow_api=Core.new();overflow_api.author_navigation=true
overflow_api.register({id='overflow',name='Live Lua Loader',pages={{id='long',name='[Needs attention] Runtime Texture Diagnostics and Recovery',dynamic=true,controls={}}}})
local overflow_menu=Menu.new(overflow_api,measured_view.measure);overflow_menu.visible=true;overflow_menu.expand_all()
for _,dimensions in ipairs({{640,360},{1920,1080},{3100,1748}})do
    for _,font_scale in ipairs({1,1.3})do
        overflow_menu.font_scale=font_scale
        local composed=overflow_menu.compose(dimensions[1],dimensions[2]);local bounds=overflow_menu.parent_geometry
        local right=bounds.x+(overflow_menu.sidebar_width-15)*bounds.scale
        local label=assert(has(composed,'[Needs attention] Runtime Texture Diagnostics and Recovery'))
        assert(label.x+#label.text*label.size*.62<=right+.01,'sidebar must fit even when native metrics underestimate width')
    end
end
measured_view.release();assert(next(live_ids)==nil)
-- Audit the actual composed control and popup depths.
local popup_api=Core.new()
local popup_handle=popup_api.register({id='editors',name='Editor controls',pages={{id='main',name='Controls',controls={{type='toggle',id='enabled',label='Enabled',default=false},{type='choice',id='mode',label='Selection',choices={'First','Second','Third'},default=1,presentation='dropdown'},{type='color',id='color',label='Accent color',default='#DDB869'},{type='keybind',id='key',label='Open / close',default=119},{type='slider',id='size',label='Scale',min=.75,max=1.5,step=.05,default=1}}}}})
local editors=Menu.new(popup_api);editors.visible=true;editors.focus='settings'
local normal=editors.compose(1920,1080)
local max_row,min_field,min_text=0,math.huge,math.huge
for _,c in ipairs(normal) do
    if c.ui_role=='setting_row' then max_row=math.max(max_row,Theme.depth(c)) end
    if c.type=='rect' and c.w==175 and c.h==29 then min_field=math.min(min_field,Theme.depth(c)) end
    if c.text=='OFF' then min_text=math.min(min_text,Theme.depth(c)) end
end
assert(Theme.depth(normal[1])<max_row and max_row<min_field and min_field<min_text)
assert(has(normal,'F8'),'readable key names replace VK numbers')
export('controls',normal,1920,1080)
editors.dropdown={mod=popup_api.mods.editors,control=popup_api.mods.editors.controls.mode,selected=1,scroll=0,x=850,top=500}
local popup=editors.compose(1920,1080)
local surface,selection,label
for _,c in ipairs(popup) do
    if c.popup and c.ui_role=='surface' then surface=Theme.depth(c) end
    if c.popup and c.ui_role=='selection' then selection=Theme.depth(c) end
    if c.popup and c.text=='First' then label=Theme.depth(c) end
end
assert(surface and selection and label and surface<selection and selection<label)
export('dropdown',popup,1920,1080)
editors.dropdown=nil;editors.color_picker={mod=popup_api.mods.editors,control=popup_api.mods.editors.controls.color,rgb={221,184,105}}
export('picker',editors.compose(1920,1080),1920,1080)
editors.color_picker=nil;editors.key(36);assert(popup_handle.preview('enabled')==false,'Home no longer resets settings')
-- Failed preference writes cannot change runtime state; shared registrations agree.
local config,fail,changed={},false,0
local loader={get_loader_option=function(key)return config[key]end,save_loader_option=function(key,value)if fail then return false,'write failed' end;config[key]=value;return true end,manager_preferences_changed=function()changed=changed+1 end}
assert(Preferences.page(loader).controls[2].default==45,'Manager key reset must offer Insert')
assert(not Preferences.set(loader,'menu_toggle_key',27))
assert(Preferences.set(loader,'menu_toggle_key',46) and Preferences.get(loader).menu_toggle_key==46)
fail=true;assert(not Preferences.set(loader,'ui_scale',1.25) and Preferences.get(loader).ui_scale==1 and changed==1);fail=false
assert(Preferences.set(loader,'font_scale',1.2))
local settings=Core.new();settings.register({id='preferences',name='Manager',pages={Preferences.page(loader)}})
local settings_menu=Menu.new(settings);settings_menu.visible=true;settings_menu.font_scale=1.2;settings_menu.ui_scale=1.25
export('settings',settings_menu.compose(1920,1080),1920,1080)
for _,dimensions in ipairs({{640,360},{1920,1080},{3440,1440}}) do
    for _,scale in ipairs({.75,1,1.5}) do
        settings_menu.ui_scale=scale;settings_menu.compose(dimensions[1],dimensions[2]);local bounds=settings_menu.parent_geometry
        assert(bounds.x>=0 and bounds.y>=0 and bounds.x+bounds.width*bounds.scale<=dimensions[1]+.01 and bounds.y+bounds.height*bounds.scale<=dimensions[2]+.01)
    end
end
local overview_loader={order={"live/armor_editor","archive_tools","live/camera"},modules={["live/armor_editor"]="loaded",archive_tools="loaded",["live/camera"]="disabled"},records={archive_tools={Author="CowboyBingus"}},origins={["live/armor_editor"]={owner="lll_live"},archive_tools={owner="lll_archive"}},refresh=function()end,get_loader_option=loader.get_loader_option,save_loader_option=loader.save_loader_option}
overview_loader.compatibility={implementation="Live Lua Loader",modules=overview_loader.modules}
local overview_live={catalog={["live/armor_editor"]={id="armor_editor",kind="lll",source_root="LLL/Mods",metadata={name="Epic LUT",author="Goose"}},["live/camera"]={id="camera",kind="lll",source_root="LLL/Mods",metadata={name="Camera tools",author="Goose"}}}}
local overview_api=Core.new();overview_api.author_navigation=true
local overview_controls=dofile('src/controls.lua')(overview_loader,overview_live,function()end)
overview_controls.bind(overview_api,"origins");overview_controls.refresh()
overview_api.loader_summary=overview_controls.provenance_summary
overview_api.menu_toggle_key=Preferences.get(overview_loader).menu_toggle_key
local overview_menu=Menu.new(overview_api);overview_menu.visible=true;overview_menu.expand_all()
export('overview',overview_menu.compose(1920,1080),1920,1080)
overview_menu.page=2;overview_menu.font_scale=1.2;overview_menu.ui_scale=1.25
export('settings',overview_menu.compose(1920,1080),1920,1080)

local Console=dofile('src/ui/diagnostics.lua')
local model=Console.shared();local console_owner=model.attach('LLL','fixture.log')
model.record('LLL','R26 UI review fixture; offline only');model.window.visible=true
local console=Console.surface(model)
local console_commands=console.compose(1920,1080,{x=210,y=130,w=1500,h=820},true)
local background_depth,text_depth
for _,command in ipairs(console_commands) do
    if command.type=='rect' and command.c==Theme.palette.background then background_depth=Theme.depth(command) end
    if command.type=='text' then text_depth=Theme.depth(command) end
end
-- The palette is vendored per module, so compare semantic depth rather than table identity.
local minimum=math.huge
for _,command in ipairs(console_commands) do if command.type=='rect' then minimum=math.min(minimum,Theme.depth(command)) end end
assert(minimum==390 and text_depth==401,'console surface is below console text')
export('console',console_commands,1920,1080)
model.window.command_text="dbfhud.global.opacity = 20";model.window.input_focused=true
export('console-input',console.compose(1920,1080,{x=210,y=130,w=1500,h=820},true),1920,1080)
console.release();model.detach(console_owner)
overview_menu.window_width=1100;overview_menu.window_height=660;overview_menu.font_scale=1.3;overview_menu.ui_scale=1.5
export('screenshot-scale',overview_menu.compose(2226,1347),2226,1347)
overview_menu.collapse_all()
export('collapsed-startup',overview_menu.compose(1920,1080),1920,1080)
overview_menu.open_context(850,600,{{label='Open',run=function()end},{label='Edit metadata',run=function()end},{label='Collapse all',run=function()end}})
export('right-click',overview_menu.compose(1920,1080),1920,1080)
local metadata_loader={get_loader_option=function(key)if key=='metadata_overrides' then return {} end end,save_loader_option=function()return true end,provenance_snapshot=function()return {{name='live/example',display_name='Example mod',author='Goose',owner='lll_live'}}end}
dofile('src/ui/metadata_editor.lua').install(overview_api,metadata_loader,{refresh=function()end},function()return overview_menu end)
assert(overview_api.open_metadata('live/example'))
export('metadata-editor',overview_menu.compose(1920,1080),1920,1080)
overview_controls.close()
print('PASS UI refresh: uneven columns, compact layout, pointer scrollbars, stable retained depth, popup surface audit, key labels, failed preference writes and scaled bounds')
