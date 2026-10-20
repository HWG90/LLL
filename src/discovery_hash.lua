local ffi = require("ffi")
local bit = require("bit")
ffi.cdef([[typedef union {uint64_t full;uint32_t half[2];} LLL_U64;]])
local function identity(value)
    local parts = ffi.new("LLL_U64")
    parts.full = value
    return string.format("%08x%08x", tonumber(parts.half[1]), tonumber(parts.half[0]))
end
local mix = ffi.new("uint64_t", 0xc6a4a793ULL) * 0x100000000ULL + 0x5bd1e995ULL
local function xor(a, b)
    local x, y = ffi.new("LLL_U64"), ffi.new("LLL_U64")
    x.full = a
    y.full = b
    x.half[0] = bit.bxor(x.half[0], y.half[0])
    x.half[1] = bit.bxor(x.half[1], y.half[1])
    return x.full
end
local function hash(name)
    local h = ffi.new("uint64_t", #name) * mix
    local p = ffi.cast("const uint8_t *", name)
    local stop = #name - #name % 8
    for i = 0, stop - 1, 8 do
        local word = ffi.new("uint64_t", 0)
        for j = 7, 0, -1 do
            word = word * 256 + p[i + j]
        end
        word = word * mix
        word = xor(word, word / 0x800000000000ULL)
        word = word * mix
        h = xor(h, word) * mix
    end
    local tail = ffi.new("uint64_t", 0)
    for j = #name - 1, stop, -1 do
        tail = tail * 256 + p[j]
    end
    if stop < #name then
        h = xor(h, tail) * mix
    end
    h = xor(h, h / 0x800000000000ULL) * mix
    h = xor(h, h / 0x800000000000ULL)
    return identity(h)
end
return hash
