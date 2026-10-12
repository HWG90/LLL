-- UI colors and readable key labels.
local M={}
M.palette = {
    background = { 12, 14, 16 },
    panel = { 19, 21, 23 },
    header = { 25, 27, 29 },
    border = { 62, 66, 69 },
    border_hover = { 106, 111, 114 },
    line = { 34, 37, 40 },
    white = { 234, 235, 228 },
    muted = { 154, 159, 159 },
    brass = { 221, 184, 105 },
    focus = { 244, 202, 53 },
    hover = { 29, 31, 33 },
    selected = { 43, 39, 24 },
    text_selection = { 48, 117, 158 },
    field = { 29, 31, 34 },
    field_hover = { 39, 42, 45 },
    enabled = { 176, 205, 176 },
    disabled = { 105, 111, 113 },
}
-- Match Epic workspace hierarchy while retaining the loader font-scale preference.
M.typography={body=18,heading=21,title=27,hint=16}
function M.key_name(code)
    local names={[8]='Backspace',[9]='Tab',[13]='Enter',[16]='Shift',[17]='Ctrl',[18]='Alt',[27]='Esc',[32]='Space',
        [33]='Page Up',[34]='Page Down',[35]='End',[36]='Home',[37]='Left',[38]='Up',[39]='Right',[40]='Down',[45]='Insert',[46]='Del'}
    if names[code]then return names[code]end
    if code>=48 and code<=90 then return string.char(code)end
    if code>=112 and code<=135 then return 'F'..tostring(code-111)end
    if code>=96 and code<=105 then return 'Num '..tostring(code-96)end
    return 'VK '..tostring(code)
end

M.layers={shell=90,row=95,focus=99,control=100,control_frame=101,fill=102,indicator=103,text_control=108,preview=110,popup=200,picker=300,console=400}
function M.overlay_layer(command,base)
    return base+(command.type=="text" and 8 or command.ui_role=="indicator" and 3 or command.ui_role=="fill" and 2 or command.ui_role=="control_frame" and 1 or command.ui_role=="frame" and -11 or command.ui_role=="surface" and -10 or command.ui_role=="selection" and -5 or 0)
end
function M.depth(command)
    return (command.layer or M.layers.control)+(command.type=="text" and 1 or 0)
end
return M
