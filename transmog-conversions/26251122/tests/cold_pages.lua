-- Cold code pages, offline, in stock LuaJIT.
--
-- Build 26088801 keeps code the game has not run yet unreadable: a read that
-- touches such a page fails as a whole. These cases run the port's own
-- GameContract, Adapter and NativeGrid over the captured current images, with
-- chosen pages failing to read the way they do in the game, and check that
-- cold code is waited for, never concluded gone, and found once it can be read.
--
-- usage: luajit cold_pages.lua <foundation.lua> <armory.lua> <game.dll image>
--        <live .text overlay | -> <exe image>
-- The images must be of the build the sources' symbol tables name: 26088801
-- is evidence/game-26088801.dll with transmog-live-text.bin over it; 26251122
-- is evidence/game-26251122.dll, a merged live capture that already holds its
-- decrypted .text, so its overlay is `-` (none).
-- Read-only. No game process, no native calls. Prints one JSON line.
local foundation_path,armory_path,game_path,text_path,exe_path=...
assert(exe_path,'usage: luajit cold_pages.lua foundation armory game.dll text exe')

local function slurp(path)local f=assert(io.open(path,'rb'));local s=f:read('*a');f:close();return s end
local sources={slurp(foundation_path),slurp(armory_path)}

-- The bundle's modules by name, loaded as globals the way the bundle's locals
-- see each other.
local function load_module(name)
 for _,text in ipairs(sources)do
  local head='local '..name..' = (function()'
  local a=text:find(head,1,true)
  if a then
   local b=assert(text:find('\nend)()',a,true),'module end not found: '..name)
   local code='return (function()'..text:sub(a+#head,b+#'\nend)()'-1)
   local chunk=assert(loadstring(code,'@'..name))
   local value=chunk();rawset(_G,name,value);return value
  end
 end
 error('module not in the bundle: '..name)
end

-- A controllable clock: the modules time-slice and rate-limit by os.clock().
local now=0
os.clock=function()return now end

-- Memory: the captured game.dll with the live .text over it, and the exe.
local game_image=slurp(game_path)
local text=text_path=='-'and''or slurp(text_path)
game_image=game_image:sub(1,0x1000)..text..game_image:sub(0x1000+#text+1)
local exe_image=slurp(exe_path)
local GAME,EXE=0x180000000,0x140000000
-- A heap of zeros outside both images, for the game objects a screen reading
-- follows; they are written into it through `patched`.
local HEAP,heap_image=0x200000000,string.rep('\0',0x400000)
local PAGE=4096
local cold={}          -- absolute page address -> true
local patched={}       -- absolute address -> byte string, laid over memory
local counts={reads=0,failed=0}
local function image_of(at)
 if at>=GAME and at<GAME+#game_image then return game_image,GAME end
 if at>=EXE and at<EXE+#exe_image then return exe_image,EXE end
 if at>=HEAP and at<HEAP+#heap_image then return heap_image,HEAP end
end
local function read(at,n)
 counts.reads=counts.reads+1
 local image,base=image_of(at)
 if not image or n<1 or at+n>base+#image then counts.failed=counts.failed+1;return nil end
 local first=at-at%PAGE
 for page=first,at+n-1,PAGE do if cold[page]then counts.failed=counts.failed+1;return nil end end
 local s=image:sub(at-base+1,at-base+n)
 for address,bytes in pairs(patched)do
  if address<at+n and address+#bytes>at then
   local parts={}
   for i=1,n do
    local o=at+i-1-address
    parts[i]=(o>=0 and o<#bytes)and bytes:sub(o+1,o+1)or s:sub(i,i)
   end
   s=table.concat(parts)
  end
 end
 return s
end
local function set_cold(address,length)
 for page=address-address%PAGE,address+(length or 1)-1,PAGE do cold[page]=true end
end
local function warm_all()cold={}end

local process={
 module=function(name)if name=='game.dll'then return GAME end;if name==nil then return EXE end end,
 read=function(at,n)if type(at)~='number'or n<1 then return nil end;return read(at,n)end,
 same=function(at,bytes)return read(at,#bytes)==bytes end,
 data=function(at)return read(at,8)~=nil end,
 executable=function(at)return read(at,1)~=nil end,
}

for _,name in ipairs({'GameTerms','GameEngineLayout','GameCatalogLayout','GameCustomizationLayout','GameGridLayout',
 'GameGridSymbols','GameArmoryLayout','GameArmorySymbols','GameRenderLayout','GameRenderSymbols','GamePackageLayout',
 'GamePackageSymbols','GameImage','NativeDisassembler','GameDecode','GameContract','CompatSpec','CatalogCompat','Adapter',
 'BootGame','NativeGridFocus','NativeGridModel','NativeGridProducers','NativeGrid','NativeGridRenewal'})do load_module(name)end

local checks,results={},{}
local function check(ok,what)assert(ok,what);checks[#checks+1]=what end
local function unhex(h)return(h:gsub('%x%x',function(p)return string.char(tonumber(p,16))end))end

---------------------------------------------------------------------------
-- 1. The game contract.
local mods={GameContract=GameContract,GameArmorySymbols=GameArmorySymbols,GameRenderSymbols=GameRenderSymbols,
 GamePackageSymbols=GamePackageSymbols,BootExtras=true}
local tables=BootGame.tables(mods)
local function contract(reports)
 local c=GameContract.new{process=process,image=GameImage,tables=tables,decode=GameDecode.decode,
  report=function(k,v)reports[#reports+1]=k..'='..tostring(v)end}
 for _=1,100000 do if c:step()=='ready'then return c end end
 error('contract did not finish')
end
local function symbol(c,name)return c.symbols[name]end

warm_all()
local baseline=contract({})
local warm_states={}
for name,entry in pairs(baseline.capabilities)do warm_states[name]=entry.state end
results.contract_warm=warm_states
check(baseline.symbols.set_uv.state=='proven'and baseline.symbols.model_widget_update.state=='proven',
 'contract: every staged witness is proven on the captured current image')

-- In the game at startup: set_uv, text_template, model_widget_update and the
-- actor code were unreadable (HD2Transmog.log, 2026-10-25 03:35).
local COLD_SYMBOLS={'set_uv','text_template','text_plain','model_widget_update','actor_ready','offer_to_kit','ui_render'}
for _,name in ipairs(COLD_SYMBOLS)do
 local spec=baseline.symbols[name].spec
 set_cold((spec.module=='game'and GAME or EXE)+spec.rva,#spec.bytes/2)
end
local reports={}
local c=contract(reports)
for _,name in ipairs(COLD_SYMBOLS)do
 check(symbol(c,name).state=='cold','contract: unreadable '..name..' is cold, not missing')
 check(c.proposals[name]==nil,'contract: no search proposal ("gone") for cold '..name)
end
check(symbol(c,'kit_registry').state=='cold'or symbol(c,'kit_registry').state=='proven',
 'contract: a global read out of a cold function waits with it')
check(symbol(c,'actor_manager').state=='cold','contract: actor_manager, read from cold offer_to_kit, is cold')
for _,name in ipairs({'extras','model','previews','render'})do
 local state,why=c:capability(name)
 check(state=='unknown'and tostring(why):find(GameContract.COLD,1,true)~=nil,
  'contract: capability '..name..' is unknown while its code is cold ('..tostring(why)..')')
end
check(c:capability('packages')=='pass','contract: an unaffected capability still passes')
local address,why=c:address('set_uv')
check(address==nil and why:find(GameContract.COLD,1,true),'contract: address() of cold code is nil and says not loaded yet')
local described=c:describe()
check(described:find('symbol\tset_uv\tcold',1,true)~=nil,'contract: game-contract.txt names cold symbols')

-- Asked every frame while cold: one read a second at most.
local before=counts.reads
for _=1,600 do c:address('set_uv');c:capability('extras')end
check(counts.reads-before<=2*(#COLD_SYMBOLS+4),'contract: cold rechecks are rate limited ('..(counts.reads-before)..' reads for 1200 asks)')

-- The game runs the code: everything is found again and passes.
warm_all();now=now+5
for _,name in ipairs({'extras','model','previews','render'})do
 check(c:capability(name)=='pass','contract: capability '..name..' passes once its code can be read')
end
check(c:address('set_uv')==GAME+baseline.symbols.set_uv.spec.rva,'contract: set_uv proven at its staged address after warming')
check(symbol(c,'actor_manager').state=='proven','contract: derived global proven after its function warmed')
local loaded=0;for _,line in ipairs(reports)do if line:find('game.symbol.loaded',1,true)then loaded=loaded+1 end end
check(loaded>=#COLD_SYMBOLS,'contract: each symbol that loaded later is reported')

-- Code that can be read and differs is still missing and off, never cold.
local spec=baseline.symbols.show_model.spec
patched[GAME+spec.rva]='\204\204\204\204'
local c2=contract({})
check(symbol(c2,'show_model').state=='missing','contract: readable but different code is missing')
check(c2:capability('extras')=='off','contract: a capability with changed code is off')
patched={}

---------------------------------------------------------------------------
-- 2. The startup UI and catalogue adapters.
local function run_adapter(spec,target)
 local reports={}
 local a=Adapter.new(nil,function(k,v)reports[#reports+1]=k..'='..tostring(v)end,
  {base=GAME,read=function(at,n)return read(at,n)end},spec,target,nil,nil)
 local steps=0
 while steps<200000 do
  steps=steps+1
  local ok,phase=pcall(a.step,a)
  if not ok then return a,'error: '..tostring(phase),steps,reports end
  if phase=='ready'or a.phase=='awaiting'or a.phase=='failed'then break end
 end
 return a,a.phase,steps,reports
end
local function globals_of(a,target)
 if target=='catalog'then local b=a:data_bridge();return{b.armor_catalog,b.progression}end
 local b=a:debug_bridge();return{b.menu_global,b.manager_global,b.session_global}
end
for _,case in ipairs({{CatalogCompat,'catalog',{'gear_catalog_categories','progression_owned_layout'}},{CompatSpec,'armory',{'manager','font','armory_registration'}}})do
 local spec,target,hidden=case[1],case[2],case[3]
 warm_all()
 local warm,phase=run_adapter(spec,target)
 check(phase=='ready','adapter '..target..': resolves on the warm captured image')
 local expected=globals_of(warm,target)
 -- Cold: the witnesses of some required patterns, plus every 9th code page.
 warm_all()
 local header=GameImage.parse(function(rva,n)return read(GAME+rva,n)end)
 local sections=0
 for _,section in ipairs(header.sections)do if section.exec then
  sections=sections+1
  for page=section.rva,section.rva+section.size-1,PAGE*9 do cold[GAME+page]=true end
 end end
 local by_name={};for _,s in ipairs(spec)do by_name[s.name]=s end
 for _,name in ipairs(hidden)do set_cold(GAME+by_name[name].wake_rva,#by_name[name].hex/2)end
 local a,cold_phase,_,reports=run_adapter(spec,target)
 check(cold_phase=='awaiting','adapter '..target..': cold pages make it wait for its witnesses, not fail ('..tostring(cold_phase)..')')
 check((a.cold_pages or 0)>0,'adapter '..target..': unreadable pages were skipped ('..tostring(a.cold_pages)..')')
 local waiting={};for _,name in ipairs(a.waiting)do waiting[name]=true end
 for _,name in ipairs(hidden)do check(waiting[name],'adapter '..target..': waits for '..name)end
 -- Waiting reads only the witnesses, at most once a second.
 before=counts.reads
 for _=1,300 do a:step()end
 check(counts.reads==before,'adapter '..target..': no reads within the wake second')
 now=now+1.5;a:step()
 check(counts.reads-before<=#a.waiting,'adapter '..target..': one small read per witness per wake')
 -- The game runs that code: a fresh full scan finds what the warm one did.
 warm_all();now=now+1.5
 local steps=0
 while a.phase~='ready'and steps<200000 do steps=steps+1;a:step()end
 check(a.phase=='ready'and a.cold_retries==1,'adapter '..target..': rescans and resolves once the witnesses can be read')
 local found=globals_of(a,target)
 for i=1,#expected do check(found[i]==expected[i],'adapter '..target..': global '..i..' equals the warm resolution')end
end

---------------------------------------------------------------------------
-- 2b. A launch with the mission loadout code unreadable.
-- Build 26251122 keeps the mission loadout screen's code unreadable until that
-- screen first opens (live page probe, LLtM batch 2808, 2026-10-29 19:43).
-- These witnesses lie in it; the ship Armory must not wait for them.
local LOADOUT={'session','loadout_registration','loadout_flags','loadout_state','local_slot','record_peer',
 'loadout_payload','player_card_address','player_card_payload','loadout_view_setter','loadout_view_stratagems',
 'equipment_button_owner','equipment_button_size','equipment_button_top_attachment','gear_payload'}
local function loadout_pages(names,make)
 for _,spec in ipairs({CompatSpec,CatalogCompat})do for _,s in ipairs(spec)do
  for _,name in ipairs(names)do if s.name==name then make(GAME+s.wake_rva,#s.hex/2)end end
 end end
end
local function warm_pages(address,length)
 for page=address-address%PAGE,address+length-1,PAGE do cold[page]=nil end
end
-- The screens, as the game lays them out, over fake objects: the menu, the UI
-- manager with the ship Armory registered, and the mission's Equipment
-- controller with its Armor picker up for the local player in slot 0.
local L,C,FONT=GameGridLayout,GameCustomizationLayout,GameArmoryLayout.ui_font
local MENU_GLOBAL,MANAGER_GLOBAL,SESSION_GLOBAL,MATERIAL_GLOBAL=GAME+0x2e38160,GAME+0x2ce2040,GAME+0x2e38228,GAME+0x3180c08
local EQUIPMENT,SESSION,MENU,MANAGER,MATERIAL,SHIP=HEAP,HEAP+0x280000,HEAP+0x290000,HEAP+0x2a0000,HEAP+0x2b0000,HEAP+0x300000
local function le(n,size)local t={};for i=1,size do t[i]=string.char(n%256);n=math.floor(n/256)end;return table.concat(t)end
local function put(at,bytes)patched[at]=bytes end
local function visible_grid(grid)
 local bar,W=grid+L.grid.scrollbar,L.widget
 put(bar+W.alpha,le(0x3f800000,4))                                        -- 1.0
 put(bar+W.scale_x,le(0x3f800000,4));put(bar+W.scale_y,le(0x3f800000,4))
 put(bar+W.world_x,le(0x42c80000,4));put(bar+W.world_y,le(0x42c80000,4))  -- 100.0
 put(bar+W.width,le(0x43c80000,4));put(bar+W.height,le(0x43c80000,4))    -- 400.0
end
local function show(screen_id)
 patched={}
 put(MENU_GLOBAL,le(MENU,8));put(MANAGER_GLOBAL,le(MANAGER,8));put(SESSION_GLOBAL,le(SESSION,8));put(MATERIAL_GLOBAL,le(MATERIAL,8))
 put(MATERIAL+FONT.material_hash,'\1\2\3\4\5\6\7\8')
 local state=MENU+L.menu.state
 put(state+L.menu.screen,le(screen_id,4));put(state+L.menu.stack,le(screen_id,4));put(state+L.menu.depth,le(1,4))
 local R=L.ui_manager
 put(MANAGER+R.controller_count,le(1,4))
 put(MANAGER+R.controllers+R.controller_pointer,le(SHIP,8));put(MANAGER+R.controllers+R.controller_type,le(R.armory_type,4))
 visible_grid(SHIP+L.armory.grid)
 local B,E=C.loadout_bucket,L.equipment
 put(MANAGER+B.at+B.at_0x00,le(B.at_0x00_active,4));put(MANAGER+B.at+B.owner,le(EQUIPMENT,8));put(MANAGER+B.at+B.type,le(B.type_loadout,4))
 put(EQUIPMENT+E.view,le(E.view_equipment,4));put(EQUIPMENT+E.picker,'\1');put(EQUIPMENT+E.at_0x2818,le(E.at_0x2818_picker,4))
 local peer='\17\0\0\1\0\0\16\1'
 put(SESSION+L.session.peer,peer);put(EQUIPMENT+E.slot_peer,peer)
 visible_grid(EQUIPMENT+E.grid)
end
local function rescanned(reports)
 for _,line in ipairs(reports)do if line=='adapter.status=current_witnesses_available_rescanning'then return true end end
 return false
end

warm_all()
local warm_ui=run_adapter(CompatSpec,'armory')
local warm_catalog=run_adapter(CatalogCompat,'catalog')
local warm_globals,warm_data=globals_of(warm_ui,'armory'),warm_catalog:data_bridge()
loadout_pages(LOADOUT,set_cold)

local cat,cat_phase=run_adapter(CatalogCompat,'catalog')
check(cat_phase=='ready','launch: the catalogue resolver resolves with the loadout code unreadable ('..tostring(cat_phase)..')')
local data=cat:data_bridge()
check(data.armor_catalog==warm_data.armor_catalog and data.progression==warm_data.progression,
 'launch: the catalogue resolves the armor catalogue and progression of the warm resolution')
check(data.players==GAME+0x2ce1618,'launch: the catalogue resolves the players global from code the game runs at startup')

local ui,ui_phase,_,ui_reports=run_adapter(CompatSpec,'armory')
check(ui_phase=='ready','launch: the Armory adapter resolves with the loadout code unreadable ('..tostring(ui_phase)..')')
local found=globals_of(ui,'armory')
for i=1,#warm_globals do check(found[i]==warm_globals[i],'launch: Armory global '..i..' equals the warm resolution')end
check(ui:debug_bridge().deployment_picker_proven==false,'launch: the Equipment layout is unproven while its code is unreadable')
local waits={};for _,name in ipairs(ui.waiting or{})do waits[name]=true end
for _,name in ipairs(LOADOUT)do
 if name~='gear_payload'then check(waits[name],'launch: the Armory adapter watches '..name)end
end
check(not waits.deployment_picker_grid,'launch: a witness that was read is not watched')

show(L.screen.armory)
local reading,why=ui:sample()
check(reading and reading.kind=='armory','launch: the ship Armory is read right after launch ('..tostring(why)..')')
show(L.screen.equipment)
reading,why=ui:sample()
check(reading==nil,'launch: no Equipment reading while its layout is unproven ('..tostring(why)..')')

-- Watching reads only the witnesses, at most once a second.
before=counts.reads
for _=1,300 do ui:step();cat:step()end
check(counts.reads==before,'launch: no reads within the wake second')
now=now+1.5;ui:step();cat:step()
check(counts.reads-before<=#ui.waiting,'launch: one small read per watched witness per wake')

-- Part of the loadout code loads: no rescan until all of it can be read.
loadout_pages({'session','loadout_registration','loadout_flags','loadout_state'},warm_pages)
now=now+1.5
for _=1,10 do ui:step()end
check(ui.phase=='ready'and ui.cold_retries==0,'launch: no rescan while part of the loadout code is unreadable')

-- The loadout screen opens and the game runs its code: the same full scan
-- from pristine state, after which the Equipment readings are on.
patched={};warm_all();now=now+1.5
local steps=0
while steps<200000 and not(ui.phase=='ready'and ui.cold_retries==1)do steps=steps+1;ui:step()end
check(ui.phase=='ready'and ui.cold_retries==1 and rescanned(ui_reports),'launch: the Armory adapter rescans once the loadout code can be read')
check(ui:debug_bridge().deployment_picker_proven==true and ui.waiting==nil,'launch: the rescan proves the Equipment layout')
found=globals_of(ui,'armory')
for i=1,#warm_globals do check(found[i]==warm_globals[i],'launch: after the rescan Armory global '..i..' equals the warm resolution')end
show(L.screen.equipment)
reading,why=ui:sample()
check(reading and reading.kind=='deployment','launch: the Equipment screen is read after the rescan ('..tostring(why)..')')
show(L.screen.armory)
reading,why=ui:sample()
check(reading and reading.kind=='armory','launch: the ship Armory is still read after the rescan ('..tostring(why)..')')
for _=1,300 do now=now+1.5;cat:step()end
check(cat.phase=='ready'and cat.cold_retries==0,'launch: the catalogue resolver keeps its resolution when the loadout code loads')

-- Right after launch the ship has not run extra_booster_host yet either. The
-- catalogue waits for it, as the Armory adapter does, and never resolves
-- without the players global (live 2026-10-30: it resolved 4 s before that
-- code ran, and the local player stayed unread for the whole launch).
patched={};warm_all();loadout_pages(LOADOUT,set_cold)
local booster;for _,s in ipairs(CatalogCompat)do if s.name=='extra_booster_host'then booster=s end end
set_cold(GAME+booster.wake_rva,#booster.hex/2)
local early,early_phase=run_adapter(CatalogCompat,'catalog')
check(early_phase=='awaiting','launch: the catalogue waits for the startup code that holds the players global ('..tostring(early_phase)..')')
warm_pages(GAME+booster.wake_rva,#booster.hex/2);now=now+1.5
steps=0
while early.phase~='ready'and steps<200000 do steps=steps+1;early:step()end
check(early.phase=='ready'and early:data_bridge().players==GAME+0x2ce1618,
 'launch: once that code has run the catalogue resolves with the players global')
patched={};warm_all()

---------------------------------------------------------------------------
-- 3. The Armory equipment grid.
-- The progression global the catalogue resolver proves (progression_owned_layout).
local PROGRESSION=GAME+0x2e38230
local function run_grid(progression)
 local reports={}
 local bridge={base=GAME,read=function(at,n)return read(at,n)end,verify=function()return true end,
  manager_global=GAME+0x2ce2040,menu_global=GAME+0x2e38160,progression_global=progression}
 local g=NativeGrid.new(bridge,function(k,v)reports[#reports+1]=k..'='..tostring(v)end,{},nil)
 local phase,why
 for _=1,200000 do phase,why=g:step();if phase~='resolving'then break end end
 return g,phase,why,reports
end
local function proven(reports)
 local names={}
 for _,line in ipairs(reports)do
  local name,what=line:match('^grid%.([%w_]+)=(.*)$')
  if name and what:find('verified',1,true)then names[name]=true end
 end
 return names
end
local function reported(reports,key)
 local value;for _,line in ipairs(reports)do local k,v=line:match('^([%w_.]+)=(.*)$');if k==key then value=v end end
 return value
end
-- Where a grid pattern is in the captured image.
local function locate(name)
 for _,p in ipairs(GameGridSymbols.PATTERNS)do if p.name==name then
  local bytes=unhex(p.hex)
  local ignore={};for _,r in ipairs(p.wild or{})do for o=r[1],r[2]do ignore[o+1]=true end end
  local at=game_image:find(bytes:sub(1,8),0x1001,true)
  while at do
   local same=true
   for j=1,#bytes do if not ignore[j]and bytes:byte(j)~=game_image:byte(at+j-1)then same=false;break end end
   if same then return GAME+at-1 end
   at=game_image:find(bytes:sub(1,8),at+1,true)
  end
 end end
 error('pattern not located: '..name)
end
warm_all()
local grid,phase,_,warm_reports=run_grid(nil)
check(phase=='ready','grid: resolves on the warm captured image')
check(#grid.cold_parts==0 and not grid:cold('selection'),'grid: nothing is cold on the warm image')
check(reported(warm_reports,'grid.progression')=='selection','grid: warm progression comes from the selection proof')
local warm_proven=proven(warm_reports)
local _,agree_phase,_,agree_reports=run_grid(PROGRESSION)
check(agree_phase=='ready'and reported(agree_reports,'grid.progression')=='selection and catalog',
 'grid: the catalogue progression agrees with the selection proof')
local _,_,_,conflict_reports=run_grid(PROGRESSION+8)
check(reported(conflict_reports,'grid.progression')=='unavailable'and not proven(conflict_reports).selection,
 'grid: a catalogue progression that differs from the selection proof is refused')

-- Joining a mission in progress: the ship Armory never ran, so the code of
-- selection, commit_source and thumbnail is still unreadable (HD2Transmog.log,
-- 2026-10-29 00:29: "selection is not loaded yet" until the Armory opened).
-- The pod's picker has everything else.
for _,name in ipairs({'selection','commit_source','thumbnail'})do set_cold(locate(name),64)end
local pod,pod_phase,pod_why,pod_reports=run_grid(PROGRESSION)
check(pod_phase=='ready','grid: made at once without the Armory-only code ('..tostring(pod_why)..')')
check(pod:cold('selection')and pod:cold('commit_source')and pod:cold('thumbnail')and #pod.cold_parts==3,
 'grid: the parts left out are named cold ('..table.concat(pod.cold_parts,',')..')')
check(reported(pod_reports,'grid.cold_parts')=='selection,commit_source,thumbnail','grid: the cold parts are reported')
check(reported(pod_reports,'grid.progression')=='catalog','grid: progression comes from the catalogue while selection is cold')
local pod_proven=proven(pod_reports)
for _,name in ipairs({'deployment_apply','list_clear','list_append','list_finish','highlight','logical_solver','logical_groups'})do
 check(pod_proven[name],'grid: the pod presentation keeps '..name)
end
check(not pod:cold('deployment_apply'),'grid: the armor setter is not cold in the pod')
local _,_,_,lone_reports=run_grid(nil)
check(reported(lone_reports,'grid.progression')=='unavailable','grid: without the catalogue a cold selection leaves no progression')

-- Other optional parts on cold pages: left out and named, never a failed grid.
warm_all()
for _,name in ipairs({'deployment_apply','detail_input'})do set_cold(locate(name),64)end
local cold_grid,cold_phase,cold_why,cold_reports=run_grid(PROGRESSION)
check(cold_phase=='ready'and cold_grid:cold('deployment_apply')and cold_grid:cold('detail_input'),
 'grid: optional functions on cold pages leave a ready grid with them named cold ('..tostring(cold_why)..')')
local cold_proven=proven(cold_reports)
check(not cold_proven.deployment_apply and not cold_proven.detail_input,'grid: the cold optional parts are left out')
-- A required function on a cold page still fails the scan as cold, to be retried.
warm_all();set_cold(locate('consume'),64)
local required,required_phase,required_why=run_grid(PROGRESSION)
check(required_phase=='failed'and required.cold==true and tostring(required_why):find('not loaded yet',1,true)~=nil,
 'grid: a required function on a cold page fails as cold ('..tostring(required_why)..')')
warm_all()
local again,again_phase,_,again_reports=run_grid(PROGRESSION)
check(again_phase=='ready'and #again.cold_parts==0,'grid: the scan after the code loaded resolves complete')
local again_proven=proven(again_reports)
for name in pairs(warm_proven)do check(again_proven[name],'grid: rescan proves '..name..' like the warm scan')end

---------------------------------------------------------------------------
-- 4. Renewing a grid that was made with cold parts.
local function stub(phase,cold)return{phase=phase,cold_parts=cold or{}}end
local made=0
local spare
local function make()made=made+1;spare=stub('resolving');return spare end
local r=NativeGridRenewal.new()
local partial=stub('ready',{'selection','commit_source','thumbnail'})
check(r:step(partial,false,nil,make)==partial and made==0,'renewal: none while no picker is open')
local current,line=r:step(partial,true,'deployment',make)
check(current==spare and made==1 and tostring(line):find('scanning again for selection',1,true),'renewal: a picker opening starts one')
check(r:step(spare,true,'deployment',make)==spare and made==1,'renewal: the new grid is used while it resolves')
spare.phase='ready';spare.cold_parts={'selection','commit_source','thumbnail'}
local kept=spare
current=r:step(spare,true,'deployment',make)
check(current==kept and made==1,'renewal: an equally complete new grid is kept, and not renewed again in the same opening')
r:step(current,false,'deployment',make)
check(r:step(current,true,'deployment',make)==current and made==1,'renewal: a screen where a renewal found nothing new is not renewed again')
current,line=r:step(current,true,'armory',make)
check(current==spare and made==2,'renewal: another screen may still renew')
spare.phase='ready';spare.cold_parts={'thumbnail'}
local better=spare
check(r:step(spare,true,'armory',make)==better,'renewal: a more complete grid is kept')
r:step(better,false,'armory',make)
current=r:step(better,true,'armory',make)
check(current==spare and made==3,'renewal: a screen where it found more may renew again')
spare.phase='failed'
check(r:step(spare,true,'armory',make)==better,'renewal: a failed new grid gives the previous one back')
local whole=stub('ready')
r:step(whole,false,'armory',make)
check(r:step(whole,true,'armory',make)==whole and made==3,'renewal: a complete grid is never renewed')
local capped=NativeGridRenewal.new();local partial_grid=stub('ready',{'a','b','c','d','e'})
for i=1,NativeGridRenewal.ATTEMPTS+2 do
 capped:step(partial_grid,false,'armory',make)
 local s=capped:step(partial_grid,true,'armory',make)
 if s~=partial_grid then
  local cold={};for j=1,#partial_grid.cold_parts-1 do cold[j]=partial_grid.cold_parts[j]end
  s.phase='ready';s.cold_parts=cold;partial_grid=capped:step(s,true,'armory',make)
 end
end
check(#partial_grid.cold_parts==5-NativeGridRenewal.ATTEMPTS,'renewal: at most '..NativeGridRenewal.ATTEMPTS..' renewals per screen')
-- A picker that closed before its renewal resolved was not open for the game
-- to run its code: finding nothing new then does not end that screen's
-- renewals (live 2026-10-30: a one-second Armory visit left preview_notify
-- cold for the launch, and variant previews failed).
local brief=NativeGridRenewal.new()
check(brief:step(stub('ready',{'category_text','preview_notify'}),true,'armory',make)==spare,'renewal: a brief Armory opening starts one')
local pending=spare
brief:step(pending,false,'armory',make)
pending.phase='ready';pending.cold_parts={'category_text','preview_notify'}
check(brief:step(pending,false,'armory',make)==pending,'renewal: its equal grid is kept')
local before_made=made
check(brief:step(pending,true,'armory',make)==spare and made==before_made+1,
 'renewal: a screen whose picker closed before the renewal resolved renews at its next opening')

print(string.format('{"pass":true,"checks":%d,"reads":%d,"failed_reads":%d}',#checks,counts.reads,counts.failed))
