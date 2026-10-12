local Bus=dofile('src/commands.lua')
local service=Bus.new();local owner={console_active=true}
local saved,fail=nil,false
local hud={config={panel_opacity=.8,third_person_opacity=.4,text_opacity=1,weapon_panels={one={panel_opacity=.9,color='red'},two={panel_opacity=.6}}}}
hud.configure=function(values)for key,value in pairs(values)do hud.config[key]=value end end
hud.save_tuning=function()if fail then return false,'write refused' end;saved=hud.config.panel_opacity;return true end
hud.reload_settings=function()return true,'Reloaded settings' end
local release=dofile(assert(os.getenv('LLL_HUD_CONSOLE_SOURCE'),'HUD console source path required'))(hud,{expose=function(namespace,spec)return service.register(namespace,owner,spec)end})
local ok,message=service.execute('dbfhud.global.opacity = 20')
assert(ok and saved==.2 and hud.config.panel_opacity==.2 and hud.config.third_person_opacity==.2)
assert(hud.config.weapon_panels.one.panel_opacity==.2 and hud.config.weapon_panels.two.panel_opacity==.2)
assert(hud.config.weapon_panels.one.color=='red' and hud.config.text_opacity==1,'panel command must preserve colors and text opacity')
assert(service.execute('get dbfhud.global.opacity'))
assert(not service.execute('dbfhud.global.opacity = 120'))
assert(not service.execute('dbfhud.global.opacity = "20"'))
assert(not service.execute('os.execute = "something"'))
assert(service.execute('run dbfhud.reload_settings'))
fail=true;assert(not service.execute('dbfhud.global.opacity = 50'))
assert(hud.config.panel_opacity==.2 and hud.config.weapon_panels.one.panel_opacity==.2,'failed save must restore all panel overrides')
fail=false;assert(service.execute('dbfhud.settings.text_opacity = 0.7') and hud.config.text_opacity==.7)
owner.console_active=false;assert(not service.execute('dbfhud.global.opacity = 60'))
owner.console_active=true;release();assert(not service.execute('dbfhud.global.opacity = 60'))
assert(#service.list()==0 and service.execute('help'))
-- Console surface: pointer focus, keyboard typing, execution and history.
local model=dofile('src/ui/diagnostics.lua').new();model.commands=Bus.new()
local actual=0;local drop=model.commands.register('demo',{}, {value={type='number',get=function()return actual end,set=function(value)actual=value;return true end}})
model.window.visible=true
local surface=dofile('src/ui/diagnostics.lua').surface(model)
local keys={};local mx,my=0,0
local input={down=function(key)return keys[key]==true end,mouse=function()return mx,my end,wheel=function()return 0 end}
surface.filter(input,true)
local commands=surface.compose(1920,1080,{x=0,y=600,w=1100,h=400},true)
local found=false
for _,command in ipairs(commands)do if command.text=='help | namespace.field = value' then found=true end end
assert(found,'console input field is composed')
local bounds=surface.bounds;mx,my=bounds.x+80,bounds.y+42
keys[1]=true;surface.filter(input,true);keys[1]=false;surface.filter(input,true)
local function press(key)
 keys[key]=true;local filtered=surface.filter(input,true);assert(not filtered.down(key),'typing key leaked into parent menu');keys[key]=false;surface.filter(input,true)
end
for _,key in ipairs({68,69,77,79,190,86,65,76,85,69,32,187,32,50,48})do press(key)end
press(13);assert(actual==20,'typed assignment did not execute')
press(38);assert(model.window.command_text=='demo.value = 20','history recall failed')
keys[27]=true;local filtered=surface.filter(input,true);assert(not filtered.down(27),'first Escape should leave command focus');keys[27]=false;surface.filter(input,true)
assert(not model.window.input_focused)
model.window.input_focused=true;model.window.command_text='demo.v'
commands=surface.compose(1920,1080,{x=0,y=600,w=1100,h=400},true)
local popup
for _,command in ipairs(commands)do
 if command.text=='demo.value' then popup=command;assert(command.layer>400,'suggestion text must cover console content')end
end
assert(popup,'typing must produce suggestion popup')
press(9);assert(model.window.command_text=='demo.value' and actual==20,'Tab must complete without executing')
model.window.command_text='demo.';press(27);assert(model.window.input_focused,'Escape must dismiss suggestions before releasing focus')
press(27);assert(not model.window.input_focused)
assert(model.commands.suggest('run demo.')[1]==nil,'run must exclude scalar fields')
assert(model.commands.suggest('get demo.v')[1].text=='get demo.value')
local paused={console_active=false}
local remove_paused=model.commands.register('paused',paused,{flag={get=function()error('suggestions must not invoke getters')end,set=function()error('suggestions must not invoke setters')end,type='boolean'}})
assert(#model.commands.suggest('paused.')==0,'retiring owners must not be suggested')
paused.console_active=true
assert(model.commands.suggest('paused.flag = t')[1].text=='paused.flag = true')
remove_paused();assert(#model.commands.suggest('paused.')==0,'released providers must disappear immediately')
model.window.visible=false;model.window.input_focused=false;model.window.command_text='abcdef'
press(192);assert(model.window.visible and model.window.input_focused and model.window.command_text=='abcdef','console shortcut must focus input without inserting grave')
keys[8]=true;surface.filter(input,true,.01);assert(model.window.command_text=='abcde')
for _=1,3 do surface.filter(input,true,.1)end
assert(model.window.command_text=='abcde','repeat must wait for initial delay')
surface.filter(input,true,.1);assert(model.window.command_text=='abcd','held Backspace must repeat')
keys[8]=false;surface.filter(input,true,.1);local after=model.window.command_text
surface.filter(input,true,.1);assert(model.window.command_text==after,'release must stop repeat')
keys[13]=true;surface.filter(input,true,.01);local history_count=#model.window.command_history
for _=1,8 do surface.filter(input,true,.1)end
assert(#model.window.command_history==history_count,'held Enter must not repeat execution')
keys[13]=false;surface.filter(input,true,.01)
surface.release();assert(not model.window.input_focused)
drop()
print('PASS console input/history/focus, typed commands, owner retirement, 20-percent global/per-weapon panel opacity, hidden settings and save rollback')
