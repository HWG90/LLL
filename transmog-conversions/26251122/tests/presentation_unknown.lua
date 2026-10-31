-- The Armory list holds armors newer than the catalogue's reference data. The
-- presentation must replay those items of the game's own list as they were,
-- never borrow them for a card, and never claim them as owned.
--
-- usage: luajit presentation_unknown.lua <foundation.lua> <armory.lua>
-- Prints one JSON line.
local foundation_path,armory_path=...
assert(armory_path,'usage: luajit presentation_unknown.lua foundation armory')
local function slurp(path)local f=assert(io.open(path,'rb'));local s=f:read('*a');f:close();return s end
local sources={slurp(foundation_path),slurp(armory_path)}
local function load_module(name)
 for _,text in ipairs(sources)do
  local head='local '..name..' = (function()'
  local a=text:find(head,1,true)
  if a then
   local b=assert(text:find('\nend)()',a,true))
   local value=assert(loadstring('return (function()'..text:sub(a+#head,b+#'\nend)()'-1),'@'..name))()
   rawset(_G,name,value);return value
  end
 end
 error('module not in the bundle: '..name)
end
for _,name in ipairs({'GameTerms','GameEngineLayout','GameCatalogLayout','GameCustomizationLayout','GameGridLayout'})do load_module(name)end
local P=load_module('NativeGridPresentation')
local Grid=GameGridLayout.grid

local checks=0
local function check(ok,what)assert(ok,what);checks=checks+1 end
local function item(offer,kit)
 return{offer_id=offer,kit_id=kit,owned=kit~=nil,group_key=7,flag_a=0,flag_b=1}
end
-- Three owned armors the catalogue knows and one it cannot name.
local entries={item(101,'armor:0000000a'),item(102,'armor:0000000b'),item(103,nil),item(104,'armor:0000000c')}
local function source()
 return{kind=Grid.kind_armor,compact=false,columns=3,layout_verified=true,base_row_height=100,header_height=20,
  root_geometry={x=0,y=0,width=900,height=600},entries=entries,item_count=4,row_count=2,group_count=1,content=220,
  rows={{count=3,first_item=0,height=120},{count=1,first_item=3,height=100}},groups={{key=7,first_row=0,first_item=0}},
  selected_offer_id=101,marker_offer_id=0,scroll_value=0}
end
local cards={{key='v1',kind='variant',kit_id='armor:0000000b'},{key='+',kind='create',kit_id='armor:0000000a'}}
local plan=P.prepare(source(),cards,{allow_create=true})
check(plan.proposed.item_count==6,'the two cards and all four game items are laid out')
local replayed
for _,v in ipairs(plan.proposed.entries)do if v.offer_id==103 then replayed=v end end
check(replayed and replayed.kit_id==nil and replayed.owned==false,'the unnamed game item is replayed as it was listed')
for _,id in ipairs(plan.owned_ids)do check(id~=nil,'only named armors are claimed as owned')end
check(#plan.owned_ids==3,'three owned armors are verified, the unnamed one is not')
check(P.matches(plan.proposed,plan.proposed),'the readback of the rebuilt list matches with the unnamed item in it')
local tampered={}
for k,v in pairs(plan.proposed)do tampered[k]=v end
tampered.entries={}
for i,v in ipairs(plan.proposed.entries)do
 local c={};for k,x in pairs(v)do c[k]=x end
 if c.offer_id==103 then c.owned=true end
 tampered.entries[i]=c
end
check(not P.matches(tampered,plan.proposed),'an unnamed item read back as owned is a mismatch')
-- A card can never borrow an armor the catalogue cannot name.
local ok,why=pcall(P.prepare,source(),{{key='v',kind='variant',kit_id=nil},{key='+',kind='create',kit_id='armor:0000000a'}},{allow_create=true})
check(not ok,'a card without a named donor is refused ('..tostring(why)..')')
-- Registered (clothing) entries stay strict.
ok,why=pcall(P.prepare,source(),cards,{allow_create=true,registered_entries={item(200,nil)}})
check(not ok and tostring(why):find('owned Armor identity required',1,true),'a registered entry without identity is refused')
-- An item that claims to be owned without a name is still refused.
entries[3]={offer_id=103,kit_id=nil,owned=true,group_key=7,flag_a=0,flag_b=1}
ok=pcall(P.prepare,source(),cards,{allow_create=true})
check(not ok,'an owned item without a name is refused')
print(string.format('{"pass":true,"checks":%d}',checks))
