local Core=dofile('src/ui/core.lua')
local Menu=dofile('src/ui/menu.lua')
local Preferences=dofile('src/ui/preferences.lua')
local config,fail={},false
local loader={get_loader_option=function(key)return config[key]end,save_loader_option=function(key,value)if fail then return false,'write refused' end;config[key]=value;return true end}
assert(Preferences.get(loader).apply_key==9 and Preferences.get(loader).focus_key==117)
assert(not Preferences.set(loader,'apply_key',119),'conflicting bindings must be rejected')
assert(Preferences.set(loader,'apply_key',116) and Preferences.get(loader).apply_key==116)
assert(not Preferences.set(loader,'focus_key',116))
local api=Core.new();api.author_navigation=true
local handle=api.register({id='example',name='Example',categories={{id='author',name='Goose'}},pages={{id='main',name='Settings',category='author',controls={{id='enabled',type='toggle',label='Enabled',default=false},{id='key',type='keybind',label='Shortcut',default=70}}}}})
local menu=Menu.new(api);menu.visible=true
assert(#menu.sidebar()==1,'initial root must be closed even in author-navigation mode')
menu.expand_all();assert(#menu.sidebar()==3)
menu.collapse_all();assert(#menu.sidebar()==1)
menu.focus='settings';assert(handle.edit('enabled',true));menu.key(9)
assert(handle.get('enabled')==true and menu.focus=='settings','Tab confirms rather than switching focus')
menu.key(117);assert(menu.focus=='mods')
api.apply_key=116;assert(handle.edit('enabled',false));menu.key(9);assert(handle.get('enabled')==true)
menu.key(116);assert(handle.get('enabled')==false,'Apply binding is configurable')
-- A key-binding capture owns Tab before Apply and the internal toggle event.
menu.focus='settings';menu.row=2;menu.key(13);assert(menu.capture)
menu.key(9);assert(not menu.capture and handle.preview('key')==9)
assert(handle.get('key')==70,'rebinding remains a draft on confirmation pages')
menu.key(116);assert(handle.get('key')==9)
-- Right-click follows the real pointer path without activating the setting.
menu.row=1;local commands=menu.compose(1920,1080);local row
for _,command in ipairs(commands)do if command.ui_role=='setting_row' and command.focused then row=command end end
assert(row)
local right=false;local mx,my=row.x+10,row.y+12
local input={down=function(key)return key==2 and right end,mouse=function()return mx,my end}
menu.tick(input);right=true;menu.tick(input)
assert(menu.context_menu and #menu.context_menu.actions==3)
assert(handle.preview('enabled')==false,'right click must not toggle values')
local popup=menu.compose(1920,1080);local visible=false
for _,command in ipairs(popup)do if command.context_action then visible=true end end
assert(visible,'context actions are actually composed')
menu.key(27);assert(not menu.context_menu and menu.visible)
-- In-game metadata: atomic local override, failed-save draft retention and lock.
loader.provenance_snapshot=function()return {{name='live/test',display_name='Original name',author='Unknown author',owner='lll_live',description='Original description'}}end
local refreshed=0
dofile('src/ui/metadata_editor.lua').install(api,loader,{refresh=function()refreshed=refreshed+1 end},function()return menu end)
assert(api.can_edit_metadata() and api.open_metadata('live/test'))
local editor=api.mods.lll_metadata_editor;local edit=editor.handle
assert(edit.edit('name','Custom mod: Mk. II') and edit.edit('author','Goose') and edit.edit('description','A description with punctuation!'))
assert(config.metadata_overrides==nil)
fail=true;assert(not edit.confirm('metadata'))
assert(edit.preview('name')=='Custom mod: Mk. II' and config.metadata_overrides==nil,'failed writes retain drafts')
fail=false;menu.key(116)
assert(config.metadata_overrides['live/test'].author=='Goose' and refreshed==1)
assert(edit.edit('author','Other'));edit.discard('metadata')
assert(config.metadata_overrides['live/test'].author=='Goose')
config.metadata_editing=false;assert(not api.open_metadata('live/test'))
assert(edit.edit('author','Locked'));assert(not edit.confirm('metadata'))
assert(config.metadata_overrides['live/test'].author=='Goose')
config.metadata_editing=true
local provenance=dofile('src/provenance.lua')({order={'live/test'},modules={['live/test']='loaded'},origins={['live/test']={owner='lll_live'}},get_loader_option=loader.get_loader_option},{catalog={['live/test']={id='test',kind='lll',source_root='fixture'}}},{})
assert(provenance[1].author=='Goose' and provenance[1].display_name=='Custom mod: Mk. II' and provenance[1].owner=='lll_live','metadata must not change runtime ownership')
print('PASS collapsed startup, Tab/custom Apply, capture priority, real right-click popup, metadata drafts/persistence/lock and fixed owner identity')
