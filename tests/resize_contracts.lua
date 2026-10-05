local G=dofile('src/ui/geometry.lua')
for _,view in ipairs({{1920,1080},{640,360},{3440,1440}})do
 for _,edge in ipairs({'left','right','top','bottom','left_top','right_bottom'})do
  local base=G.bounds(view[1],view[2],1500,820)
  for _,delta in ipairs({-10000,-100,100,10000})do
   local g=G.drag(base,edge,delta,delta)
   assert(g.width>=1100 and g.height>=660 and g.x>=0 and g.y>=0)
   assert(g.x+g.width*g.scale<=view[1]+.01 and g.y+g.height*g.scale<=view[2]+.01)
  end
 end
end
local core=dofile('src/ui/core.lua').new()
core.author_navigation=true
core.register({id='sizing',name='Sizing',pages={{id='a',name='Page',controls={{type='text',label=string.rep('wide ',80),description=string.rep('paragraph words ',200)}}}}})
local menu=dofile('src/ui/menu.lua').new(core)
menu.visible=true;menu.window_width=1100;menu.window_height=660
local commands=menu.compose(1920,1080);assert(menu.parent_geometry.width==1100 and menu.visible_rows<12)
local before=menu.parent_geometry;local held=false;local mx,my=before.x+before.width*before.scale-2,before.y+before.height*.5*before.scale
local input={down=function(key)return key==1 and held end,mouse=function()return mx,my end}
local saved=0;menu.on_geometry_changed=function()saved=saved+1 end
held=true;menu.tick(input);mx=mx+180;menu.tick(input);menu.compose(1920,1080)
held=false;menu.tick(input)
assert(menu.window_width>1100 and saved==1,'real pointer path resizes and persists on release')
for _,c in ipairs(menu.compose(1920,1080))do
 if c.tree_branch then assert(c.y==c.tree_branch.junction and c.y+c.h<=menu.parent_geometry.y+(menu.parent_geometry.height-137)*menu.parent_geometry.scale+.01)end
 if c.type=='text' then assert(c.text_width and c.x+c.text_width<=menu.parent_geometry.x+(menu.parent_geometry.width-25)*menu.parent_geometry.scale+.01)end
end
assert(#menu.compose(0,0)==0)
menu.recover();assert(not menu.visible and not menu.capture)
print('PASS bounded edge/corner resize, actual mouse drag persistence, narrow rows, whole-text bounds and recovery')
