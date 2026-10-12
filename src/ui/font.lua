-- Existing game HUD font resources, read through the already verified runtime.
-- Layout provenance: Pick-your-bots Test36 Source/replace_automatons.lua,
-- lines 7061-7089. The installed DLL matches this exact PE and Epic's SHA256
-- build gate. No signature scan, new native binding, asset load, or memory write.
local F = {}
local HIGH = 4294967296
local function u32(bytes, offset)
    offset = offset or 0
    if type(bytes) ~= 'string' or #bytes < offset + 4 then
        return nil
    end
    local a, b, c, d = bytes:byte(offset + 1, offset + 4)
    return a + b * 256 + c * 65536 + d * 16777216
end
local function hash(bytes)
    if type(bytes) ~= 'string' or #bytes ~= 8 then
        return nil
    end
    local lo, hi = u32(bytes), u32(bytes, 4)
    if lo == 0 and hi == 0 then
        return nil
    end
    return string.format('%08x%08x', hi, lo)
end
local function pointer(bytes)
    if type(bytes) ~= 'string' or #bytes ~= 8 then
        return nil
    end
    local lo, hi = u32(bytes), u32(bytes, 4)
    if hi >= 0x8000 then
        return nil
    end
    local address = hi * HIGH + lo
    if address < 0x10000 or address > 0x800000000000 - 32 then
        return nil
    end
    return address
end
function F.new(memory, game, at)
    local self = {}
    function self.resolve(sr)
        if not memory or type(memory.read) ~= 'function' or type(memory.address) ~= 'function' then
            return nil
        end
        if
            not sr
            or not sr.IdString64
            or type(sr.IdString64.from_hex) ~= 'function'
            or not sr.Application
            or type(sr.Application.can_get) ~= 'function'
        then
            return nil
        end
        local ok, descriptor = pcall(function()
            local base = memory.address(game)
            if type(base) ~= 'number' or base < 0x10000 or base >= 0x800000000000 or base ~= math.floor(base) then
                return nil
            end
            local function read_address(address, count)
                return memory.read(at and at(address) or address, count)
            end
            local function read(offset, count)
                return read_address(base + offset, count)
            end
            local pe = u32(read(0x3c, 4))
            if
                not pe
                or pe < 0x40
                or pe > 0x1000
                or u32(read(pe, 4)) ~= 0x4550
                or u32(read(pe + 8, 4)) ~= 0x6AB3B43F
                or u32(read(pe + 80, 4)) ~= 0x4744000
                or u32(read(pe + 88, 4)) ~= 0xECDA6F
            then
                return nil
            end
            local font, atlas = hash(read(0x3772268, 8)), hash(read(0x3772EE8, 8))
            local owner = pointer(read(0x37C5478, 8))
            local material = owner and hash(read_address(owner + 24, 8))
            if not font or not atlas or not material then
                return nil
            end
            -- IdString64 values use frame-local native storage. Retain hex
            -- strings only and reconstruct each temporary at its consuming call.
            local I, app = sr.IdString64, sr.Application
            if
                not app.can_get('font', I.from_hex(font))
                or not app.can_get('texture', I.from_hex(atlas))
                or not app.can_get('material', I.from_hex(material))
            then
                return nil
            end
            return { font = font, material = material, atlas = atlas }
        end)
        if ok then
            return descriptor
        end
        return nil
    end
    return self
end
return F
