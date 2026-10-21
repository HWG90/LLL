-- Portable data only. No FFI, native addresses, global aliases or background work.
local floor, char = math.floor, string.char
local MOD, MAX, SIGN = 4294967296, 4294967295, 2147483648
local function integer(value, minimum, maximum, label)
    if type(value)=='number' and value>=minimum and value<=maximum and value==floor(value) then return value end
    error(label..' must be a finite integer in range',3)
end
local function word(value)
    value=integer(value,-SIGN,MAX,'Word')
    return value<0 and value+MOD or value
end
local function signed(value)return value>=SIGN and value-MOD or value end
local powers={[0]=1}
for index=1,32 do powers[index]=powers[index-1]*2 end
local function shift(value)return word(value)%32 end

-- Three small nibble tables, built once. Each binary word operation uses eight
-- lookups per operand and allocates no intermediate table.
local ands, ors, xors = {}, {}, {}
for a=0,15 do
    for b=0,15 do
        local left,right,both,either,different,place=a,b,0,0,0,1
        for _=1,4 do
            local x,y=left%2,right%2
            if x==1 and y==1 then both=both+place end
            if x==1 or y==1 then either=either+place end
            if x~=y then different=different+place end
            left,right,place=floor(left/2),floor(right/2),place*2
        end
        local index=a*16+b+1
        ands[index],ors[index],xors[index]=both,either,different
    end
end
local function combine(a,b,lookup)
    local result,place=0,1
    for _=1,8 do
        result=result+lookup[(a%16)*16+b%16+1]*place
        a,b,place=floor(a/16),floor(b/16),place*16
    end
    return result
end
local function fold(lookup)
    return function(first,...)
        local result=word(first)
        for index=1,select('#',...)do result=combine(result,word(select(index,...)),lookup)end
        return signed(result)
    end
end
local bit={band=fold(ands),bor=fold(ors),bxor=fold(xors)}
function bit.tobit(value)return signed(word(value))end
function bit.bnot(value)return signed(MAX-word(value))end
function bit.lshift(value,count)
    value=word(value);count=shift(count)
    -- Reduce before multiplying so every intermediate stays exact below 2^32.
    return signed((value%powers[32-count])*powers[count])
end
function bit.rshift(value,count)return signed(floor(word(value)/powers[shift(count)]))end
function bit.arshift(value,count)return floor(signed(word(value))/powers[shift(count)])end
function bit.rol(value,count)
    value=word(value);count=shift(count)
    if count==0 then return signed(value)end
    return signed((value%powers[32-count])*powers[count]+floor(value/powers[32-count]))
end
function bit.ror(value,count)
    value=word(value);count=shift(count)
    if count==0 then return signed(value)end
    return signed(floor(value/powers[count])+(value%powers[count])*powers[32-count])
end
local function octets(value)
    return value%256,floor(value/256)%256,floor(value/65536)%256,floor(value/16777216)
end
function bit.bswap(value)
    local a,b,c,d=octets(word(value))
    return signed(a*16777216+b*65536+c*256+d)
end
local hex, alphabet = {}, '0123456789abcdef'
for value=0,255 do
    hex[value+1]=alphabet:sub(floor(value/16)+1,floor(value/16)+1)..alphabet:sub(value%16+1,value%16+1)
end
function bit.tohex(value,digits)
    value=word(value)
    digits=digits==nil and 8 or integer(digits,-8,8,'Hex digits')
    local a,b,c,d=octets(value)
    local text=hex[d+1]..hex[c+1]..hex[b+1]..hex[a+1]
    if digits<0 then return text:sub(9+digits):upper()end
    return text:sub(9-digits)
end

local bytes={}
local function big(order)
    assert(order==nil or order=='le' or order=='be','Byte order must be le or be')
    return order=='be'
end
local function position(data,at,width)
    assert(type(data)=='string','Byte source must be a string')
    at=at==nil and 1 or at
    return integer(at,1,#data-width+1,'Byte offset')
end
local function read32(data,at,be)
    local a,b,c,d=data:byte(at,at+3)
    if be then return a*16777216+b*65536+c*256+d end
    return a+b*256+c*65536+d*16777216
end
function bytes.read_u16(data,at,order)
    local be=big(order);at=position(data,at,2)
    local a,b=data:byte(at,at+1)
    return be and a*256+b or a+b*256,at+2
end
function bytes.read_i16(data,at,order)
    local value,next_at=bytes.read_u16(data,at,order)
    return value>=32768 and value-65536 or value,next_at
end
function bytes.read_u32(data,at,order)
    local be=big(order);at=position(data,at,4)
    return read32(data,at,be),at+4
end
function bytes.read_i32(data,at,order)
    local value,next_at=bytes.read_u32(data,at,order)
    return signed(value),next_at
end
function bytes.read_u64(data,at,order)
    local be=big(order);at=position(data,at,8)
    if be then return read32(data,at+4,true),read32(data,at,true),at+8 end
    return read32(data,at,false),read32(data,at+4,false),at+8
end
local function write16(value,be)
    local a,b=value%256,floor(value/256)
    if be then return char(b,a)end
    return char(a,b)
end
local function write32(value,be)
    local a,b,c,d=octets(value)
    if be then return char(d,c,b,a)end
    return char(a,b,c,d)
end
function bytes.write_u16(value,order)return write16(integer(value,0,65535,'u16'),big(order))end
function bytes.write_i16(value,order)
    value=integer(value,-32768,32767,'i16')
    return write16(value<0 and value+65536 or value,big(order))
end
function bytes.write_u32(value,order)return write32(integer(value,0,MAX,'u32'),big(order))end
function bytes.write_i32(value,order)
    value=integer(value,-SIGN,SIGN-1,'i32')
    return write32(value<0 and value+MOD or value,big(order))
end
function bytes.write_u64(low,high,order)
    low=integer(low,0,MAX,'u64 low word');high=integer(high,0,MAX,'u64 high word')
    local be=big(order)
    local a,b,c,d=octets(low)
    local e,f,g,h=octets(high)
    if be then return char(h,g,f,e,d,c,b,a)end
    return char(a,b,c,d,e,f,g,h)
end
local capabilities={bit32=true,integer_codecs=true,u64_parts=true,float32=false,
    mutable_buffers=false,native_memory=false,native_calls=false,ffi=false}
return {version=1,bit=bit,bytes=bytes,capabilities=setmetatable({},{__index=capabilities,
    __metatable=false,__newindex=function()error('Portable capabilities are read-only',2)end})}
