local Core=dofile('src/ui/core.lua')
local Menu=dofile('src/ui/menu.lua')
local Theme=dofile('src/ui/theme.lua')
local api=Core.new();api.author_navigation=true
local controls={
 {id='enabled',type='toggle',label='Enabled',default=true},
 {id='scale',type='slider',label='Scale',min=0,max=10,step=1,default=5},
 {id='combined',type='choice',label='Combined',choices={'First','Second'},default=1},
 {id='selector',type='choice',label='Selector',choices={'First','Second'},default=1,presentation='selector'},
 {id='dropdown',type='choice',label='Dropdown',choices={'First','Second'},default=1,presentation='dropdown'},
 {id='run',type='button',label='Action',button_label='Run action',on_activate=function()end},
}
local handle=api.register({id='layout',name='Live Lua Loader',categories={{id='live',name='LLL live scripts (2 loaded / 10)'},{id='archive',name='Archive addons via LLL (41 loaded / 41)'},{id='unknown',name='Unknown / conflicting owner (0 loaded / 3)'}},pages={
 {id='overview',name='Overview',dynamic=true,controls=controls},
 {id='settings',name='Manager settings',dynamic=true,controls={}},
 {id='long',name='[Needs attention] Runtime Texture Diagnostics and Recovery',category='live',dynamic=true,controls={}},
}})
local menu=Menu.new(api);menu.visible=true;menu.expand_all()
local world={};local ids,free={},{};local serial=0
local function allocate(gui,kind,pos,w,h,value)
 local id=table.remove(free);if not id then serial=serial+1;id=serial end
 assert(not ids[id]);ids[id]={gui=gui,kind=kind,x=pos.x,y=pos.y,z=pos.z,w=w,h=h,text=value};return id
end
local function destroy(gui,kind,id)
 local item=assert(ids[id],'destroyed handle is not live');assert(item.gui==gui and item.kind==kind)
 ids[id]=nil;free[#free+1]=id
end
local sr={Application={worlds=function()return {world}end,main_world=function()return world end},World={create_screen_gui=function()return {}end,destroy_gui=function()end},Vector3=function(x,y,z)return {x=x,y=y,z=z}end,Vector2=function(x,y)return {x=x,y=y}end,Color=function(...)return {...}end,Gui={}}
sr.Gui.rect=function(gui,pos,size)return allocate(gui,'rect',pos,size.x,size.y)end
sr.Gui.text=function(gui,text,_,size,_,pos)return allocate(gui,'text',pos,#text*size*.62,size,text)end
sr.Gui.destroy_rect=function(gui,id)destroy(gui,'rect',id)end
sr.Gui.destroy_text=function(gui,id)destroy(gui,'text',id)end
local view=dofile('src/ui/view.lua').new(sr)
local states,indicators,labels=0,0,0
local function audit(commands)
 view.draw(commands)
 for _,command in ipairs(commands)do
  if command.ui_role=='indicator' or command.indicator_kind then
   local depth=Theme.depth(command);local native
   for _,item in pairs(ids)do
    if item.x==command.x and item.y==command.y and item.z==depth and item.kind==command.type then native=item;break end
   end
   assert(native,'indicator missing from native primitive set')
   if command.type=='text' then labels=labels+1 else indicators=indicators+1 end
   local cw=command.w or #command.text*command.size*.62;local ch=command.h or command.size
   for _,other in ipairs(commands)do
    if other.type=='rect' and other.ui_role~='indicator' and not other.popup and not command.popup then
     local contains=other.x<=command.x and other.y<=command.y and other.x+other.w>=command.x+cw and other.y+other.h>=command.y+ch
     if contains then assert(Theme.depth(other)<depth,'background can occlude indicator at same/higher depth')end
    end
   end
  end
 end
 states=states+1
end
for _,width in ipairs({1100,1500,1800})do
 for _,font in ipairs({1,1.3})do
  menu.window_width=width;menu.window_height=820;menu.font_scale=font
  local commands=menu.compose(2226,1347)
  local root,settings,long_lines=0,0,0
  for _,command in ipairs(commands)do
   if command.navigation_label then
    assert(#command.text*command.size*.62<=command.text_width+.01,'navigation text exceeds its viewport')
    if command.full_text=='Live Lua Loader' then root=root+1;assert(command.text=='Live Lua Loader','root name should not crop')end
    if command.full_text=='Manager settings' then settings=settings+1;assert(command.text=='Manager settings','settings name should not crop')end
    if command.full_text=='[Needs attention] Runtime Texture Diagnostics and Recovery' then long_lines=long_lines+1 end
   end
   if command.tree_branch then assert(command.tree_branch.parent>0,'connector must reference its actual parent')end
  end
  assert(root==1 and settings==1 and long_lines>=1 and long_lines<=10)
  audit(commands)
  for _,checked in ipairs({false,true,false,true})do
   handle.set('enabled',checked);handle.set('scale',checked and 10 or 0)
   menu.row=checked and 3 or 1
   local g=menu.parent_geometry
   menu.pointer_x,menu.pointer_y=g.x+(menu.sidebar_width+32)*g.scale,g.y+(g.height-157)*g.scale
   audit(menu.compose(2226,1347))
  end
 end
end
view.release();assert(next(ids)==nil,'native cleanup must release recycled indicator handles')
local report=assert(io.open('tests/tmp/layer-order-audit.json','w'))
report:write(string.format('{"evidence":"Offline native API fixture; live acceptance pending","states":%d,"rectangle_indicators_checked":%d,"glyph_indicators_checked":%d,"missing_indicators":0,"occluding_backgrounds":0}',states,indicators,labels));report:close()
print('PASS responsive navigation, wrapped labels, actual-parent connectors and '..states..' native retention states with recycled IDs and visible indicators')
