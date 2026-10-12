local Core=dofile('src/ui/core.lua')
local Menu=dofile('src/ui/menu.lua')
local api=Core.new()
local handle=api.register({id='desktop',name='Desktop layout',pages={{id='main',name='Settings',require_confirmation=true,controls={
    {id='power',type='toggle',label='Enabled',default=false},
    {id='name',type='input',label='Name',default='Original'},
    {id='color',type='color',label='Color',default='#112233'},
    {id='scale',type='slider',label='Scale',min=0,max=10,step=1,default=5},
}}}})
local menu=Menu.new(api);menu.visible=true;menu.focus='settings';menu.window_height=820
local first_gap,first_size
for _,width in ipairs({1100,1500,1800,2200})do
    menu.window_width=width
    local commands=menu.compose(2560,1440)
    local switch,label,skull,stripes
    for _,command in ipairs(commands)do
        if command.indicator_kind=='sliding_switch' then switch=command end
        if command.full_text=='Enabled' and not label then label=command end
        if command.brand_skull then skull=true end
        if command.hazard_stripe then stripes=true end
    end
    assert(switch and label and skull and stripes)
    local g=menu.parent_geometry
    local gap=(switch.x-label.x)/g.scale
    if first_gap then assert(math.abs(gap-first_gap)<1,'expanding windows must not spread value controls')
        assert(label.size==first_size,'resizing must preserve text scale')
    else first_gap,first_size=gap,label.size end
    assert(gap<330,'switch stays within short pointer travel of its label')
end
menu.text_edit={mod=api.mods.desktop,control=api.mods.desktop.pages[1].controls[2],text='Edited',replace=false}
menu.key(9);assert(handle.get('name')=='Edited' and not menu.text_edit,'Tab commits and applies text draft')
local color=api.mods.desktop.pages[1].controls[3]
menu.color_picker={mod=api.mods.desktop,control=color,rgb={17,34,51}}
menu.text_edit={color_channel=1,text='200',replace=false}
menu.key(9);assert(not menu.text_edit and not menu.color_picker and handle.get('color')=='#C82233','Tab accepts color input and applies page')
print('PASS sliding switches, fixed pointer distances/text size, shell branding and Tab text/color acceptance')
