-- Exact-build, read-only discovery of the already loaded game HUD font.
local Font = dofile('src/ui/font.lua')
local base, owner = 0x180000000, 0x270010000
local function u32(value)
    local bytes = {}
    for i = 1, 4 do
        bytes[i] = string.char(value % 256)
        value = math.floor(value / 256)
    end
    return table.concat(bytes)
end
local function u64(lo, hi)
    return u32(lo) .. u32(hi or 0)
end
local image = {
    [base + 0x3c] = u32(0x110),
    [base + 0x110] = u32(0x4550),
    [base + 0x118] = u32(0x6AB3B43F),
    [base + 0x160] = u32(0x4744000),
    [base + 0x168] = u32(0xECDA6F),
    [base + 0x3772268] = u64(0xfedcba98, 0x76543210),
    [base + 0x3772EE8] = u64(0x13572468, 0xabcdef01),
    [base + 0x37C5478] = u64(owner % 4294967296, math.floor(owner / 4294967296)),
    [owner + 24] = u64(0x55667788, 0x11223344),
}
local reads, frame, availability = {}, 1, true
local memory = {
    address = function(value)
        return value
    end,
    read = function(address, size)
        reads[#reads + 1] = address
        local bytes = image[address]
        assert(bytes == nil or #bytes == size, 'Unexpected read size')
        return bytes
    end,
}
local sr = {
    IdString64 = {
        from_hex = function(value)
            return { hex = value, frame = frame }
        end,
    },
    Application = {
        can_get = function(kind, value)
            assert(value.frame == frame, 'Retained temporary native resource ID')
            return availability ~= kind and availability ~= false
        end,
    },
}
local source = Font.new(memory, base)
local function expected()
    local got = source.resolve(sr)
    assert(
        got
            and got.font == '76543210fedcba98'
            and got.atlas == 'abcdef0113572468'
            and got.material == '1122334455667788',
        'Resource hashes lost their exact 64-bit bytes'
    )
    for _, value in pairs(got) do
        assert(type(value) == 'string', 'Native ID escaped resolver')
    end
end
expected()
frame = 2
expected()
local function rejects(address, bytes, reason)
    local prior = image[address]
    image[address] = bytes
    reads = {}
    assert(source.resolve(sr) == nil, reason)
    image[address] = prior
end
for _, address in ipairs({ base + 0x110, base + 0x118, base + 0x160, base + 0x168 }) do
    rejects(address, u32(0), 'Mismatched PE accepted')
    for _, at in ipairs(reads) do
        assert(at < base + 0x10000, 'Mismatched build read font globals')
    end
end
rejects(base + 0x3c, u32(0x1001), 'Out-of-range PE header accepted')
for _, address in ipairs({ base + 0x3772268, base + 0x3772EE8, owner + 24 }) do
    rejects(address, u64(0), 'Zero resource hash accepted')
    rejects(address, nil, 'Unavailable resource bytes accepted')
end
rejects(base + 0x37C5478, u64(0), 'Null owner accepted')
rejects(base + 0x37C5478, u64(1), 'Low owner accepted')
rejects(base + 0x37C5478, u64(0, 0x8000), 'Non-user pointer accepted')
availability = false
assert(source.resolve(sr) == nil, 'Unloaded font resources accepted')
for _, kind in ipairs({ 'font', 'texture', 'material' }) do
    availability = kind
    assert(source.resolve(sr) == nil, 'Unavailable ' .. kind .. ' accepted')
end
availability = true
assert(Font.new(nil, base).resolve(sr) == nil and source.resolve({}) == nil, 'Missing API did not fall back')
-- Real Bingus reads take pointer cdata. Existing engine.at converts every
-- module and material-owner address immediately before the read.
local address_read = memory.read
local conversions = 0
memory.read = function(address, size)
    assert(type(address) == 'table' and address.address, 'Unconverted native read address')
    return address_read(address.address, size)
end
local converted = Font.new(memory, base, function(address)
    conversions = conversions + 1
    return { address = address }
end)
assert(converted.resolve(sr) and conversions == 9, 'Address adapter missed a font/owner read')
memory.read = function()
    error('read unavailable')
end
assert(source.resolve(sr) == nil, 'Read failure escaped font discovery')
print(
    'PASS loaded HUD font: exact PE, checked pointers, exact resource bytes, fresh frame-local IDs and read-only fallback'
)
-- Verify the actual loader view binds the atlas and uses main-font metrics/text.
local world={};local material_calls,text_calls,serial=0,{},0
sr.Application.worlds=function()return {world}end
sr.Application.main_world=function()return world end
sr.World={create_screen_gui=function()return {}end,destroy_gui=function()end}
sr.Vector2=function(x,y)return {x=x,y=y}end
sr.Vector3=function(x,y,z)return {x=x,y=y,z=z}end
sr.Color=function(...)return {...}end
local function fresh(id)assert(type(id)=='table' and id.frame==frame,'view retained frame-local resource ID')end
sr.Material={set_texture=function(_,slot,atlas)fresh(slot);fresh(atlas);assert(atlas.hex=='abcdef0113572468');return true end}
sr.Gui={material=function(_,id)fresh(id);material_calls=material_calls+1;return {}end,
    text=function(_,text,font,size,material)
        if type(font)=='table' then fresh(font);fresh(material)end
        text_calls[#text_calls+1]={font=font,text=text};serial=serial+1;return serial
    end,
    rect=function()serial=serial+1;return serial end,
    destroy_rect=function()end,destroy_text=function()end,
    text_extents=function(_,text,font,size)fresh(font);return {x=0},{x=#text*size*.5}end}
local descriptor={font='76543210fedcba98',atlas='abcdef0113572468',material='1122334455667788'}
local view=dofile('src/ui/view.lua').new(sr)
local ready=true
view.set_font_source({resolve=function()return ready and descriptor or nil end})
view.refresh_font()
local commands={{type='text',x=10,y=10,text='Main text',size=18,c={255,255,255},a=1}}
view.draw(commands)
assert(view.font_name=='Main HUD' and material_calls>0 and type(text_calls[#text_calls].font)=='table')
assert(view.measure('Label',18)==45,'main font must use its actual width rather than debug-font estimates')
frame=frame+1;view.refresh_font();view.draw(commands)
ready=false;view.refresh_font();view.draw(commands)
assert(view.font_name=='Compatibility fallback' and type(text_calls[#text_calls].font)=='string')
view.release()
print('PASS loader main font atlas binding, native width, frame-local IDs, retention and compatibility recovery')
