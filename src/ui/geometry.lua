-- Logical window dimensions plus physical viewport bounds; no native input operations.
local M = {}
local function number(value, fallback)
    return type(value) == "number" and value == value and value > -math.huge and value < math.huge and value or fallback
end
function M.bounds(w, h, width, height, x, y)
    local s = math.min(w / 1920, h / 1080)
    local W = math.max(1100, math.min(w / s, number(width,1500)))
    local H = math.max(660, math.min(h / s, number(height,820)))
    local ox = math.max(0, math.min(w-W*s, number(x,(w-W*s)/2)))
    local oy = math.max(0, math.min(h-H*s, number(y,(h-H*s)/2)))
    return {width=W,height=H,x=ox,y=oy,scale=s,viewport_width=w,viewport_height=h}
end
function M.drag(g, edge, dx, dy)
    local W,H,x,y = g.width,g.height,g.x,g.y
    if string.find(edge,"left",1,true) then W=W-dx/g.scale end
    if string.find(edge,"right",1,true) then W=W+dx/g.scale end
    if string.find(edge,"bottom",1,true) then H=H-dy/g.scale end
    if string.find(edge,"top",1,true) then H=H+dy/g.scale end
    local next = M.bounds(g.viewport_width,g.viewport_height,W,H,x,y)
    if string.find(edge,"left",1,true) then next.x=x+(g.width-next.width)*g.scale end
    if string.find(edge,"bottom",1,true) then next.y=y+(g.height-next.height)*g.scale end
    return M.bounds(g.viewport_width,g.viewport_height,next.width,next.height,next.x,next.y)
end
return M
