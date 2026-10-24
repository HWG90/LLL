local PORT51={kind=type,number=tonumber}
-- Read the already loaded HUD font; exact-build gates precede descriptor reads.
-- Layout provenance: Epic LUT src/platform/ui_font.lua and Pick-your-bots
-- Test36 Source/replace_automatons.lua:7061-7089. No scan or memory writes.
local F={}
local HIGH=4294967296
local function u32(bytes,offset)
    offset=offset or 0
    if PORT51.kind(bytes)~='string' or #bytes<offset+4 then return nil end
    local a,b,c,d=bytes:byte(offset+1,offset+4)
    return a+b*256+c*65536+d*16777216
end
local function hash(bytes)
    if PORT51.kind(bytes)~='string' or #bytes~=8 then return nil end
    local lo,hi=u32(bytes),u32(bytes,4)
    if lo==0 and hi==0 then return nil end
    return string.format('%08x%08x',hi,lo)
end
local function pointer(bytes)
    if PORT51.kind(bytes)~='string' or #bytes~=8 then return nil end
    local lo,hi=u32(bytes),u32(bytes,4)
    if hi>=0x8000 then return nil end
    local address=hi*HIGH+lo
    if address<0x10000 or address>0x800000000000-32 then return nil end
    return address
end
function F.new(memory,game,at)
    local function ensure_memory()
        if memory then return end
        local path=assert(os.getenv('LOCALAPPDATA'))..'/LLL/Helldivers2/Native/hd2_nativeinfo_f6d3465944c1aea1.dll'
        local entry=assert(package.loadlib(path,'luaopen_hd2_nativeinfo'))
        local native=assert(entry())
        game=assert(native.module_base('game.dll'))
        memory={read=native.read_memory,address=function(value)return value end}
    end

    local self={}
    function self.resolve(sr)
        local ready=pcall(ensure_memory);if not ready then return nil end

        if not memory or PORT51.kind(memory.read)~='function' or PORT51.kind(memory.address)~='function' then return nil end
        if not sr or not sr.IdString64 or PORT51.kind(sr.IdString64.from_hex)~='function'
            or not sr.Application or PORT51.kind(sr.Application.can_get)~='function' then return nil end
        local ok,descriptor=pcall(function()
            -- Bingus memory.address converts pointers, never module names.
            -- Keep names separate so a Lua string's buffer cannot become the
            -- PE base (and silently leave the UI on the debug fallback).
            local module=game
            if PORT51.kind(module)=='string' then
                if PORT51.kind(memory.module)~='function' then return nil end
                module=memory.module(module)
                if module==nil then return nil end
            end
            local base=memory.address(module)
            if PORT51.kind(base)~='number' or base<0x10000 or base>=0x800000000000 or base~=math.floor(base) then return nil end
            local function read_address(address,count) return memory.read(at and at(address) or address,count) end
            local function read(offset,count) return read_address(base+offset,count) end
            local pe=u32(read(0x3c,4))
            if not pe or pe<0x40 or pe>0x1000 or u32(read(pe,4))~=0x4550
                or u32(read(pe+8,4))~=0x6AD7C05D
                or u32(read(pe+80,4))~=0x3382000
                or u32(read(pe+88,4))~=0x2ED14F0 then return nil end
            local font,atlas=hash(read(0x312D998,8)),hash(read(0x312E618,8))
            local owner=pointer(read(0x3180C08,8))
            local material=owner and hash(read_address(owner+24,8))
            if not font or not atlas or not material then return nil end
            local I,app=sr.IdString64,sr.Application
            if not app.can_get('font',I.from_hex(font))
                or not app.can_get('texture',I.from_hex(atlas))
                or not app.can_get('material',I.from_hex(material)) then return nil end
            return {font=font,material=material,atlas=atlas}
        end)
        if ok then return descriptor end
        return nil
    end
    return self
end
return F
