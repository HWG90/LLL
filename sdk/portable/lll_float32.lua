-- Standalone IEEE754 binary32 data, Lua 5.1. No require/globals/native pointers.
-- API v1: to_bits/from_bits/round; write(value,order)/read(bytes,offset,order).
-- Byte offsets are 1-based; order is le(default)/be. NaN writes are 0x7fc00000.
-- array(count,initial=0): 0-based :get/:set/:fill(value,start=0,count=remaining),
-- :copy(source,source_start=0,dest_start=0,count=source_remaining),
-- :export(start=0,count=remaining,order), :import(bytes,offset=1,start=0,count=remaining,order).
-- Mutators return true; import returns next byte offset; read returns value,next.
-- :view(start,count) shares data; :length/:alive query it. Only the owning array
-- may :release(); release is idempotent and invalidates all views/nested views.
local floor,frexp,ldexp=math.floor,math.frexp,math.ldexp
local char,concat=string.char,table.concat
local HUGE=math.huge
local SIGN,FRAC,INF,NAN=2147483648,8388608,2139095040,2143289344
local NEG_ZERO=-1/HUGE
local MAX_ELEMENTS,CHUNK=262144,256 -- 1MiB encoded per array/export.
local function integer(value,minimum,maximum,label)
    if type(value)=='number'and value>=minimum and value<=maximum and value==floor(value)then return value end
    error(label..' must be a finite integer in range',3)
end
local function number(value)
    if type(value)=='number'then return value end
    error('Float value must be a number',3)
end
local function even(value)
    local result=floor(value)
    local fraction=value-result
    if fraction>0.5 or fraction==0.5 and result%2==1 then return result+1 end
    return result
end
local function to_bits(value)
    number(value)
    if value~=value then return NAN end
    local sign=0
    if value<0 or value==0 and 1/value==-HUGE then sign=SIGN;value=-value end
    if value==HUGE then return sign+INF end
    if value==0 then return sign end
    local mantissa,exponent=frexp(value)
    if exponent < -125 then
        -- Scaling by a power of two is exact; rounding can reach the minimum
        -- normal word directly, without a second rounding operation.
        return sign+even(ldexp(value,149))
    end
    local significand=even(mantissa*16777216)
    if significand==16777216 then significand=FRAC;exponent=exponent+1 end
    if exponent>=129 then return sign+INF end
    return sign+(exponent+126)*FRAC+significand-FRAC
end
local function decode(bits)
    local negative=bits>=SIGN
    local magnitude=bits%SIGN
    local exponent=floor(magnitude/FRAC)
    local fraction=magnitude%FRAC
    if exponent==255 then
        if fraction~=0 then return 0/0 end
        return negative and -HUGE or HUGE
    end
    if magnitude==0 then return negative and NEG_ZERO or 0 end
    local value
    if exponent==0 then value=ldexp(fraction,-149)
    else value=ldexp(FRAC+fraction,exponent-150)end
    return negative and -value or value
end
local function from_bits(bits)return decode(integer(bits,0,4294967295,'Float bits'))end
local function canonical(bits)return bits%SIGN>INF and NAN or bits end
local function big(order)
    assert(order==nil or order=='le'or order=='be','Byte order must be le or be')
    return order=='be'
end
local function position(data,at,width)
    assert(type(data)=='string','Byte source must be a string')
    return integer(at==nil and 1 or at,1,#data-width+1,'Byte offset')
end
local function read_word(data,at,be)
    local a,b,c,d=data:byte(at,at+3)
    if be then return a*16777216+b*65536+c*256+d end
    return a+b*256+c*65536+d*16777216
end
local function write_word(bits,be)
    local a,b,c,d=bits%256,floor(bits/256)%256,floor(bits/65536)%256,floor(bits/16777216)
    if be then return char(d,c,b,a)end
    return char(a,b,c,d)
end
local M={version=1,max_elements=MAX_ELEMENTS,to_bits=to_bits,from_bits=from_bits}
function M.round(value)return decode(to_bits(value))end
function M.write(value,order)return write_word(to_bits(value),big(order))end
function M.read(data,at,order)
    local be=big(order);at=position(data,at,4)
    return decode(read_word(data,at,be)),at+4
end

-- Shared methods and weak handle records keep storage private. Lua-owned words
-- are not addresses; views retain the allocation until its owner releases it.
local records=setmetatable({},{__mode='k'})
local methods={}
local handle_type={__index=methods,__metatable=false,
    __newindex=function()error('Float array handles do not expose storage',2)end}
local function handle(owner,start,count,owns)
    local value=setmetatable({},handle_type)
    records[value]={owner=owner,start=start,count=count,owns=owns}
    return value
end
local function record(value)
    local item=records[value]
    assert(item and item.owner.alive,'Float array is not owned or has been released')
    return item
end
local function range(item,start,count)
    start=integer(start==nil and 0 or start,0,item.count,'Array start')
    count=integer(count==nil and item.count-start or count,0,item.count-start,'Array count')
    return start,count
end
function M.array(count,initial)
    count=integer(count,0,MAX_ELEMENTS,'Array length')
    local bits=to_bits(initial==nil and 0 or initial)
    local owner={alive=true,words={}}
    for index=1,count do owner.words[index]=bits end
    return handle(owner,0,count,true)
end
function methods:length()return record(self).count end
function methods:alive()local item=records[self];return item~=nil and item.owner.alive end
function methods:get(index)
    local item=record(self);index=integer(index,0,item.count-1,'Array index')
    return decode(item.owner.words[item.start+index+1])
end
function methods:set(index,value)
    local item=record(self);index=integer(index,0,item.count-1,'Array index')
    item.owner.words[item.start+index+1]=to_bits(value)
    return true
end
function methods:fill(value,start,count)
    local item=record(self);start,count=range(item,start,count)
    local bits=to_bits(value)
    for index=item.start+start+1,item.start+start+count do item.owner.words[index]=bits end
    return true
end
function methods:copy(source,source_start,dest_start,count)
    local target,origin=record(self),record(source)
    source_start,count=range(origin,source_start,count)
    dest_start=integer(dest_start==nil and 0 or dest_start,0,target.count-count,'Array destination')
    local first,last=origin.start+source_start,target.start+dest_start
    if origin.owner==target.owner and last>first and last<first+count then
        for index=count,1,-1 do target.owner.words[last+index]=origin.owner.words[first+index]end
    else
        for index=1,count do target.owner.words[last+index]=origin.owner.words[first+index]end
    end
    return true
end
function methods:export(start,count,order)
    local item=record(self);start,count=range(item,start,count)
    local be=big(order)
    local parts,chunks,n={},{},0
    for index=item.start+start+1,item.start+start+count do
        n=n+1;parts[n]=write_word(item.owner.words[index],be)
        if n==CHUNK then
            chunks[#chunks+1]=concat(parts,'',1,n)
            for at=1,n do parts[at]=nil end
            n=0
        end
    end
    if n>0 then chunks[#chunks+1]=concat(parts,'',1,n)end
    return concat(chunks)
end
function methods:import(data,at,start,count,order)
    local item=record(self);start,count=range(item,start,count)
    local be=big(order);at=position(data,at,count*4)
    local next_at=at+count*4
    for index=item.start+start+1,item.start+start+count do
        item.owner.words[index]=canonical(read_word(data,at,be));at=at+4
    end
    return next_at
end
function methods:view(start,count)
    local item=record(self);start,count=range(item,start,count)
    return handle(item.owner,item.start+start,count,false)
end
function methods:release()
    local item=records[self]
    assert(item and item.owns,'Release the owning float array, not a view')
    item.owner.alive,item.owner.words=false,nil
    return true
end
local capabilities={float32=true,round_to_nearest_even=true,mutable_arrays=true,views=true,
    native_memory=false,native_pointers=false,native_calls=false,ffi=false}
M.capabilities=setmetatable({},{__index=capabilities,__metatable=false,
    __newindex=function()error('Float capabilities are read-only',2)end})
return M
