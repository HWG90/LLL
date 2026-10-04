"""Original bounded reader/writer for locally supplied Stingray Lua archives."""
import struct
LUA_TYPE = 0xA14E8DFA2CD117E2
def hash_name(name):
    value = name.encode('ascii'); m = 0xC6A4A7935BD1E995; mask = (1 << 64)-1
    h = len(value)*m & mask
    for at in range(0,len(value)//8*8,8):
        k = int.from_bytes(value[at:at+8],'little')*m & mask
        k ^= k >> 47; k = k*m & mask
        h = (h ^ k)*m & mask
    tail = value[len(value)//8*8:]
    if tail: h = (h ^ int.from_bytes(tail,'little'))*m & mask
    h ^= h >> 47; h = h*m & mask; return h ^ (h >> 47)
def read(data):
    if len(data)<104 or struct.unpack_from('<I',data)[0]!=0xF0000011: raise ValueError('Invalid archive')
    count=struct.unpack_from('<I',data,8)[0]
    if count>100000 or 104+80*count>len(data): raise ValueError('Invalid table')
    result={}
    for i in range(count):
        name,kind,offset=struct.unpack_from('<3Q',data,104+i*80)
        size=struct.unpack_from('<I',data,160+i*80)[0]
        if offset<104+count*80 or offset+size>len(data): raise ValueError('Invalid range')
        result[name]=(kind,data[offset:offset+size])
    return result
def write(resources):
    count=len(resources);start=(104+80*count+15)//16*16;data=bytearray(start)
    for i,(name,body) in enumerate(resources.items()):
        offset=len(data);data.extend(body);data.extend(b'\0'*(-len(data)%16))
        struct.pack_into('<7Q6I',data,104+i*80,name,LUA_TYPE,offset,0,0,0,0,len(body),0,0,16,16,i)
    struct.pack_into('<III20sQQ24s',data,0,0xF0000011,1,count,b'',len(data),0,b'')
    struct.pack_into('<IIQIIII',data,72,0,0,LUA_TYPE,count,0,16,16)
    return bytes(data)
