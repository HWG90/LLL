local create_api = (function()
return function()
    local ffi = require('ffi')
    assert(ffi.abi('64bit'), 'Windows x64 is required')
    -- Every Windows function has a private name (an __asm__ label naming the
    -- real export): LuaJIT keeps the first prototype declared for a name in the
    -- whole shared state, so another mod's declaration of the real names can no
    -- longer change the prototype this mod calls with.
    ffi.cdef [[
        void *hd2ecs_GetModuleHandleA(const char *name) __asm__("GetModuleHandleA");
        void *hd2ecs_GetCurrentProcess(void) __asm__("GetCurrentProcess");
        uint64_t hd2ecs_GetTickCount64(void) __asm__("GetTickCount64");
        void *hd2ecs_GetCurrentThread(void) __asm__("GetCurrentThread");
        int hd2ecs_QueryThreadCycleTime(void *thread, void *cycles) __asm__("QueryThreadCycleTime");
        int hd2ecs_QueryPerformanceCounter(void *counter) __asm__("QueryPerformanceCounter");
        int hd2ecs_QueryPerformanceFrequency(void *frequency) __asm__("QueryPerformanceFrequency");
        int hd2ecs_ReadProcessMemory(void *process, const void *address, void *buffer, size_t size,
                                     size_t *read) __asm__("ReadProcessMemory");
        int hd2ecs_ReadProcessMemoryAt(void *process, uintptr_t address, void *buffer, size_t size,
                                       size_t *read) __asm__("ReadProcessMemory");
    ]]
    -- Declared once per process: parsing it again would add new C types each time.
    if not pcall(ffi.typeof,'hd2ecs_address_cell') then
        ffi.cdef('typedef union { const void *pointer; struct { uint32_t low, high; }; } hd2ecs_address_cell;')
    end
    local kernel = ffi.load('kernel32')
    local process = kernel.hd2ecs_GetCurrentProcess()
    local api = {}
    function api.time() return tonumber(kernel.hd2ecs_GetTickCount64()) / 1000 end
    local frequency=ffi.new('int64_t[1]')
    local performance_counter=kernel.hd2ecs_QueryPerformanceCounter
    local performance_frequency=kernel.hd2ecs_QueryPerformanceFrequency
    assert(performance_frequency(frequency)~=0 and frequency[0]>0,'Performance clock unavailable')
    local ticks_per_second=tonumber(frequency[0])
    -- Read the counter as two 32-bit halves: indexing a 64-bit integer boxes a
    -- new cdata on every call, and the clock runs on every budget check.
    local halves=ffi.new('uint32_t[2]')
    function api.clock() performance_counter(halves);return (halves[0]+halves[1]*4294967296)/ticks_per_second end
    -- Optional read-only diagnostic counter. Raw cycles must not be converted
    -- to milliseconds: CPU timer frequency/implementation varies by hardware.
    local has_cycles,query_cycles=pcall(function()
        return kernel.hd2ecs_QueryThreadCycleTime
    end)
    if has_cycles then
        -- Two 32-bit halves avoid boxing a 64-bit cdata per call. The pseudo
        -- handle always names the calling thread, so it is fetched once.
        local cycle_halves,thread=ffi.new('uint32_t[2]'),kernel.hd2ecs_GetCurrentThread()
        function api.thread_cycles()
            if query_cycles(thread,cycle_halves)~=0 then return cycle_halves[0]+cycle_halves[1]*4294967296 end
        end
    end

    function api.module(name)
        local handle = kernel.hd2ecs_GetModuleHandleA(name)
        if handle == nil then return nil end
        return ffi.cast('uint8_t *', handle)
    end

    -- ReadProcessMemory does not call back into Lua. Copy to a Lua string before
    -- reusing this scratch space; no borrowed memory survives a read.
    local buffer,count=ffi.new('uint8_t[32768]'),ffi.new('size_t[1]')
    -- The copied byte count is compared as two 32-bit halves: reading the 64-bit
    -- count itself makes a new cdata object on every interpreted call.
    local count_halves=ffi.cast('uint32_t *',count)
    -- A number address (an integer below 2^47) is passed as an integer, so the
    -- caller makes no pointer object for it.
    local read_at=kernel.hd2ecs_ReadProcessMemoryAt
    function api.read(address, size)
        if type(size)~='number' or size<1 or size>32768 or size%1~=0 then return nil end
        if type(address)=='number' then
            if address<0x10000 or address>=0x800000000000 or address%1~=0
                or read_at(process, address, buffer, size, count) == 0
                or count_halves[0] ~= size or count_halves[1] ~= 0 then return nil end
            return ffi.string(buffer, size)
        end
        if kernel.hd2ecs_ReadProcessMemory(process, address, buffer, size, count) == 0
            or count_halves[0] ~= size or count_halves[1] ~= 0 then
            return nil
        end
        return ffi.string(buffer, size)
    end

    -- Validation view: the same copy into a separate scratch buffer, returned
    -- as a pointer instead of a new Lua string. Valid until the next view;
    -- compared in place, or copied out at once (a capture of several guarded
    -- words), never stored.
    local view_buffer=ffi.new('uint8_t[32768]')
    -- A number address is taken as api.read takes it: no pointer object.
    function api.view(address, size)
        if type(size)~='number' or size<1 or size>32768 or size%1~=0 then return nil end
        if type(address)=='number' then
            if address<0x10000 or address>=0x800000000000 or address%1~=0
                or read_at(process, address, view_buffer, size, count) == 0
                or count_halves[0] ~= size or count_halves[1] ~= 0 then return nil end
            return view_buffer
        end
        if kernel.hd2ecs_ReadProcessMemory(process, address, view_buffer, size, count) == 0
            or count_halves[0] ~= size or count_halves[1] ~= 0 then
            return nil
        end
        return view_buffer
    end
    -- The view copies the same memory api.read does. Anything that replaces
    -- api.read (a replay, a counting wrapper) breaks this pairing, and callers
    -- then fall back to string reads through the replacement.
    api.view_read=api.read

    -- One pointer object per decoded value. A pointer cdata is immutable, so the
    -- same object for the same value cannot be told apart from a fresh cast, and
    -- an interpreted call then allocates nothing. Weak values: objects nobody
    -- holds any more are collected as usual.
    local pointers,byte=setmetatable({},{__mode='v'}),string.byte
    function api.pointer(bytes, offset)
        offset = offset or 0
        if not bytes or offset < 0 or offset + 8 > #bytes then return nil end
        -- Little-endian decode straight from the string: exact below 2^53, and
        -- every value from 2^47 up is rejected, as before.
        local b1,b2,b3,b4,b5,b6,b7,b8=byte(bytes,offset+1,offset+8)
        local value=b1+b2*256+b3*65536+b4*16777216+(b5+b6*256+b7*65536+b8*16777216)*4294967296
        if value < 0x10000 or value >= 0x800000000000 then return nil end
        local pointer=pointers[value]
        if not pointer then pointer=ffi.cast('uint8_t *', value);pointers[value]=pointer end
        return pointer
    end

    -- A 'uint8_t *' becomes a number through this cell, read back as two 32-bit
    -- halves: converting it to a 64-bit integer makes a new cdata object on
    -- every interpreted call. One union, not two views of the same memory, so
    -- compiled code sees the store. Other values take the plain conversion.
    local cell,byte_pointer=ffi.new('hd2ecs_address_cell'),ffi.typeof('uint8_t *')
    local function slot_number(pointer) cell.pointer=pointer;return cell.low+cell.high*4294967296 end
    function api.distance(first, second)
        if ffi.istype(byte_pointer,first) and ffi.istype(byte_pointer,second) then
            -- Exact below 2^53, like the 64-bit difference.
            local a,b=slot_number(first),slot_number(second)
            if a<9007199254740992 and b<9007199254740992 then return a-b end
        end
        return tonumber(ffi.cast('intptr_t', first) - ffi.cast('intptr_t', second))
    end

    function api.address(pointer)
        -- All accepted Windows user addresses are below 2^47, so a Lua number
        -- represents each byte address exactly. Formatted pointer strings are
        -- display output and must not determine read-cache identity.
        local value=ffi.istype(byte_pointer,pointer) and slot_number(pointer) or tonumber(ffi.cast('uintptr_t',pointer))
        assert(value>=0x10000 and value<0x800000000000,'Address outside bounds')
        return value
    end

    function api.bind(game,exe)
        local function pointer(address)
            return assert(api.pointer(api.read(address,8)),'Physics binding unavailable')
        end
        local binding=pointer(game+0x2ce1500)
        assert(api.distance(binding,exe)==0x2874ed0,'Unsupported physics API')
        for _,entry in ipairs({{8,0x806790},{0x60,0x820c40},{0x68,0x820f60}}) do
            assert(api.distance(pointer(binding+entry[1]),exe)==entry[2],'Unsupported physics function')
        end
        -- Build 26088801: code pages stay unreadable until the game first runs
        -- them, so these comparisons run right before each command's first use
        -- (ready below) instead of at load.
        local setter_prologue='\x48\x89\x5c\x24\x08\x48\x89\x6c'
        -- Entire captured routine, including its ownership gate and final
        -- update-byte store. Full comparison rejects a changed/detoured body.
        local stop_hex='48895c2408574883ec60488b4138448bc24969d8b82b00004a8b3cc048035948488bcfe838e0d4ff80b8c40600000074558b4f08e807266b004885c07448f64014017442448b480c33d2c6442450000f57c0f30f11442448448bc1488b0d56106702895424408954243888542430488d542478f30f11442428c744242001000000e86af4a900c683a42b000000488b5c24704883c4605fc3'
        local stop_bytes=stop_hex:gsub('..',function(pair)return string.char(tonumber(pair,16)) end)
        -- Compared before the first stop (ready('stop')).
        -- Existing owner-routed completion request. Verify all chained unwind
        -- fragments, including the remote branch and owned queue checks.
        local completion_hex='48895c24184889542410564883ec70488bf1418bd8418bc8e82329c1ff4885c00f8472010000f64014014889bc24800000000f84f20000008b501081faff7f0000742e488b05cecda801488b4808e83d75c1ff84c0741a488b0d2a0ebe018bd3488b89a8b30000e884839affe91f010000488b0d20a4a8018bd3e8710a6eff84c00f840901000033ff488d461c8bcf9039180f84f8000000ffc14883c04083f92072ed8bcf488d86240800000f1f400039180f84d8000000ffc14883c04081f98000000072ea8bcbe87328c1ff4885c00f84ba000000f64014010f84b0000000448b480c488d94248800000040887c24500f57c0f30f11442448448bc3f30f1005afeafe00488bce897c2440897c2438c644243001f30f11442428c744242001000000e8c8f6ffffeb668b701081feff7f0000750433ffeb23488b0de89fa801488b4140488bb860010000488b4138ff5008488bc88bd6ffd7488bf88bcbe8dd24c1ff41b901000000c7442460010000004c8d442460c744246404000000488bd74889442468b9326c6621e8a0569aff488bbc2480000000488b9c24900000004883c4705ec3'
        local completion_bytes=completion_hex:gsub('..',function(pair)return string.char(tonumber(pair,16)) end)
        -- Each command's routines, compared right before its first use: an
        -- unreadable page (not resident yet) makes that command wait, uncalled,
        -- and is read again at most once a second; different bytes refuse it.
        local checks={
            pose={{exe+0x820c40,setter_prologue,'Position setter changed'},
                {exe+0x820f60,setter_prologue,'Rotation setter changed'}},
            stop={{game+0x7b76a0,stop_bytes,'Ragdoll stop routine changed'}},
            completion={{game+0x12573a0,completion_bytes,'Corpse completion request changed'}},
        }
        local verified,refused,retry={disable=true},{},{}
        local function ready(kind)
            if verified[kind] then return true end
            if refused[kind] then error(refused[kind],0) end
            local now=api.time()
            if retry[kind] and now<retry[kind] then return false end
            for _,check in ipairs(checks[kind]) do
                local bytes=api.read(check[1],#check[2])
                if bytes==nil then retry[kind]=now+1;return false end
                if bytes~=check[2] then refused[kind]=check[3];error(check[3],0) end
            end
            verified[kind]=true;return true
        end
        local request_completion=ffi.cast('void (*)(void *,uintptr_t,uint32_t)',game+0x12573a0)
        local stop_sync=ffi.cast('void (*)(void *,uint32_t)',game+0x7b76a0)
        local position=ffi.cast('void (*)(uint32_t,const float *)',exe+0x820c40)
        local rotation=ffi.cast('void (*)(uint32_t,const float *)',exe+0x820f60)
        local enabled=ffi.cast('void (*)(const uint32_t *,uint32_t,uint32_t)',exe+0x806790)
        -- These engine wrappers validate the actor handle and enqueue native
        -- physics commands. They never write a body pose or broad-phase record
        -- directly. The queue owns copies of the input vectors.
        local function aligned(values)
            local storage=ffi.new('uint8_t[31]')
            local pointer=ffi.cast('float *',storage+(16-tonumber(ffi.cast('uintptr_t',storage)%16))%16)
            for i=1,#values do pointer[i-1]=values[i] end
            return storage,pointer
        end
        return {
            ready=ready,
            stop_sync=function(manager,index)stop_sync(manager,index) end,
            request_completion=function(entity)
                -- Resolve each time; never keep a scene/service pointer.
                local service=pointer(game+0x2e28758)
                assert(api.read(service,24),'Corpse completion service unavailable')
                request_completion(service,0,entity)
            end,
            pose=function(actor,pos,quat)
                local p_owner,p=aligned(pos);local q_owner,q=aligned(quat)
                rotation(actor,q);position(actor,p)
                assert(p_owner~=nil and q_owner~=nil)
            end,
            disable=function(actor)
                local ids=ffi.new('uint32_t[1]',actor)
                enabled(ids,1,0)
            end,
        }
    end
    return api
end

end)()
local profiles = (function()
-- Generated by scripts/generate_profiles.py from profiles/catalog.json. Do not edit.
-- Exact resource, skeleton, main-body and auxiliary actor allowlists.
local profiles = {
    ['\059\238\251\018\066\231\248\220']={name="Impaler",nodes=139,bodies=15,finish_disabled=false,main={ -- lint-ok: R14 generated from profiles/catalog.json
        0x9b115563,0x58d886fb,0x5a4bbaa2,0x1fba9b23,0xacb975d0,0xe411e02e,0x8329f875,0x4014953a,0xc1466369,0xf69f42da,0x73bc7ae4,0xce7e106a,0x38f24831,0xf452db4a,0x9b47948d},
        disabled_main={},actors={
            [0x06041d5c]=0xf69f42da,
            [0x0a4517aa]=0xc1466369,
            [0x0aec1ca8]=0xacb975d0,
            [0x0be61734]=0x4508030c,
            [0x0bf0d87a]=0xf452db4a,
            [0x1245edba]=0xcb0c4b47,
            [0x1ff1c46a]=0x91c08b37,
            [0x50b19c0a]=0xbc852b90,
            [0x5f3a2d43]=0xa5dd6396,
            [0x6635646b]=0x47cd28d0,
            [0x681424d1]=0x4014953a,
            [0x6c0f2f68]=0x38f24831,
            [0x70f1db61]=0x9b47948d,
            [0x82219dbd]=0xb9b5a67f,
            [0x8668a205]=0x80f85d7b,
            [0x879c1a75]=0x5a4bbaa2,
            [0x87a058bf]=0x9b115563,
            [0x92d0871f]=0x0135b322,
            [0x9a7b92fa]=0xce7e106a,
            [0x9f5aae0c]=0x8329f875,
            [0xa3d491d1]=0x9b115563,
            [0xa4ab9dfd]=0x73bc7ae4,
            [0xc35018a3]=0x9b115563,
            [0xe42bf5f2]=0xe411e02e,
            [0xed574a1d]=0x9b115563,
            [0xed967ef1]=0xdb63f30c,
            [0xf6c42514]=0x58d886fb,
            [0xf91972b9]=0x1fba9b23,
        }},
    ['\148\235\211\007\028\161\129\163']={name="Burrowing Spewer",nodes=102,bodies=14,finish_disabled=false,main={ -- lint-ok: R14 generated from profiles/catalog.json
        0x9b115563,0x0f0196b3,0xc96f8166,0xae5a7e64,0xdcb76f26,0x1ecb5822,0x0f5d4be0,0x12fd8f94,0x341adbcc,0xd66758f9,0x8b9102b4,0xfa1accaf,0x6e8366df,0x0f5f005b},
        disabled_main={},actors={
            [0x312d55bb]=0x0e835875,
            [0x4ea4da87]=0x09a026f5,
            [0x573a0652]=0x1c5f3be4,
            [0xa3d491d1]=0xbccf91e5,
            [0xbc01b5fd]=0x0f0196b3,
            [0xc947ded4]=0xbccf91e5,
        }},
    ['\194\023\090\036\147\002\087\239']={name="Automaton assault walker",nodes=104,bodies=10,finish_disabled=false,main={ -- lint-ok: R14 generated from profiles/catalog.json
        0x9b115563,0x09a026f5,0x748f4281,0x8e1c9de6,0x4cb04651,0x5d8553b4,0xb7681bdc,0x1fb60c2a,0xbcbfce4f,0xc0e8f3b9},
        corpse_dynamic_main={[0x09a026f5]=true,[0xb7681bdc]=true,[0x1fb60c2a]=true},
        disabled_main={[0xb7681bdc]=true,[0x1fb60c2a]=true,[0xbcbfce4f]=true,[0xc0e8f3b9]=true},actors={
            [0x24a81ad3]=0x372f0418,
            [0x29bdbcff]=0x8e1c9de6,
            [0x2d729a79]=0xf9baf117,
            [0x3326c96e]=0x48741b07,
            [0x33dc3693]=0x46ddad11,
            [0x6f2078a8]=0x46ddad11,
            [0x807a2fe2]=0x4cb04651,
            [0x83498e9e]=0x748f4281,
            [0x87e4519b]=0x9b115563,
            [0xb2d0e941]=0x8eb19d6a,
            [0xcd2f2b20]=0x9b115563,
            [0xce7c02c9]=0x5d8553b4,
            [0xe55b4e87]=0x8eb19d6a,
            [0xfbb9eb3d]=0x372f0418,
            [0xfd9562d4]=0x9b115563,
        }},
    ['\155\008\114\209\253\034\112\204']={name="Nursing Spewer",nodes=99,bodies=14,finish_disabled=false,main={ -- lint-ok: R14 generated from profiles/catalog.json
        0x9b115563,0x0f0196b3,0xc96f8166,0xae5a7e64,0xdcb76f26,0x1ecb5822,0x0f5d4be0,0x12fd8f94,0x341adbcc,0xd66758f9,0x8b9102b4,0xfa1accaf,0x6e8366df,0x0f5f005b},
        disabled_main={},actors={
            [0x312d55bb]=0x0e835875,
            [0x4ea4da87]=0x09a026f5,
            [0x573a0652]=0x1c5f3be4,
            [0xa3d491d1]=0xbccf91e5,
            [0xbc01b5fd]=0x0f0196b3,
        }},
    ['\183\145\213\172\100\082\174\204']={name="Bile Spewer tier 2",nodes=99,bodies=14,finish_disabled=false,main={ -- lint-ok: R14 generated from profiles/catalog.json
        0x9b115563,0x0f0196b3,0xc96f8166,0xae5a7e64,0xdcb76f26,0x1ecb5822,0x0f5d4be0,0x12fd8f94,0x341adbcc,0xd66758f9,0x8b9102b4,0xfa1accaf,0x6e8366df,0x0f5f005b},
        disabled_main={},actors={
            [0x312d55bb]=0x0e835875,
            [0x4ea4da87]=0x09a026f5,
            [0x573a0652]=0x1c5f3be4,
            [0xa3d491d1]=0xbccf91e5,
            [0xbc01b5fd]=0x0f0196b3,
        }},
    ['\070\001\230\229\204\153\170\054']={name="Bile Spewer",nodes=117,bodies=14,finish_disabled=false,main={ -- lint-ok: R14 generated from profiles/catalog.json
        0x9b115563,0x0f0196b3,0xc96f8166,0xae5a7e64,0xdcb76f26,0x1ecb5822,0x0f5d4be0,0x12fd8f94,0x341adbcc,0xd66758f9,0x8b9102b4,0xfa1accaf,0x6e8366df,0x0f5f005b},
        disabled_main={},actors={
            [0x312d55bb]=0x0e835875,
            [0x4ea4da87]=0x09a026f5,
            [0x573a0652]=0x1c5f3be4,
            [0xa3d491d1]=0xbccf91e5,
            [0xbc01b5fd]=0x0f0196b3,
        }},
    ['\175\183\081\008\255\203\063\214']={name="Illuminate tripod tier 2",nodes=151,bodies=10,finish_disabled=true,main={ -- lint-ok: R14 generated from profiles/catalog.json
        0x9b115563,0x54efdee3,0xb4a6064f,0xa7f9b6c7,0xc6b89048,0xe225767c,0xb1332141,0xa76ee4c6,0x9615b731,0x18ca9123},
        disabled_main={[0x9b115563]=true,[0x54efdee3]=true,[0xb4a6064f]=true,[0xa7f9b6c7]=true,[0xc6b89048]=true,[0xe225767c]=true,[0xb1332141]=true,[0xa76ee4c6]=true,[0x9615b731]=true,[0x18ca9123]=true},actors={
            [0x0143255a]=0xa7f9b6c7,
            [0x0410bac8]=0xe225767c,
            [0x105602e6]=0x8c5570c9,
            [0x1fcfcae3]=0xb4a6064f,
            [0x2434f4a4]=0x9615b731,
            [0x251fe443]=0x8c5570c9,
            [0x285484ce]=0x8c5570c9,
            [0x29ca953e]=0x18ca9123,
            [0x37236374]=0xe9b4fd2d,
            [0x3d43b4b1]=0x8c5570c9,
            [0x43a3844e]=0x8c5570c9,
            [0x470cf2c5]=0xb4a6064f,
            [0x4bca1f07]=0xa7f9b6c7,
            [0x53db7fab]=0x8c5570c9,
            [0x58a98e8a]=0x8c5570c9,
            [0x599c3f71]=0xb1332141,
            [0x7394dd4e]=0xe225767c,
            [0x764e448d]=0x54efdee3,
            [0x84ffdd57]=0x18ca9123,
            [0x8ffb63db]=0xa7f9b6c7,
            [0x918bc99f]=0x8c5570c9,
            [0x9212fdd7]=0x8c5570c9,
            [0x9ee677a7]=0x8c5570c9,
            [0xa7e3257e]=0xb1332141,
            [0xb7ff9cb7]=0x8c5570c9,
            [0xb875a8c9]=0xe90e668d,
            [0xc7134a8c]=0x18ca9123,
            [0xcabc21d4]=0xa76ee4c6,
            [0xcd871ca9]=0xc6b89048,
            [0xcec2d2ea]=0xb4a6064f,
            [0xd48608a6]=0xb1332141,
            [0xdf038f71]=0x9615b731,
            [0xecf00ed4]=0x9615b731,
            [0xee8b6459]=0x78678dbb,
            [0xf2931585]=0xe225767c,
            [0xf8720bf5]=0x8c5570c9,
            [0xfbb9eb3d]=0x8c5570c9,
        }},
    ['\007\241\190\055\123\002\045\242']={name="Illuminate war machine",nodes=124,bodies=6,finish_disabled=false,main={ -- lint-ok: R14 generated from profiles/catalog.json
        0x9b115563,0xad3058fd,0x730d4fce,0x963fef84,0x98f66bd1,0x26059f72},
        disabled_main={},actors={
            [0x02a72e9d]=0x1fc641f6,
            [0x03bf2ea0]=0x3e2ee4c1,
            [0x0d213aba]=0x7ce6544d,
            [0x14231a1f]=0xe9b8ff15,
            [0x1f02fa15]=0x1fc641f6,
            [0x4d0ec52f]=0x98829f00,
            [0x568574e3]=0xe9b8ff15,
            [0x6f16b93e]=0x3e2ee4c1,
            [0x7320fca3]=0xe9b8ff15,
            [0x750e1696]=0x1fc641f6,
            [0x8eebeedd]=0x3e2ee4c1,
            [0xc6597663]=0xe9b8ff15,
            [0xcc90682d]=0x7ce6544d,
            [0xd8af4506]=0xe9b8ff15,
            [0xda16193c]=0x1fc641f6,
            [0xdd53208d]=0x98829f00,
            [0xe9e90424]=0x98829f00,
            [0xed78bda7]=0x3e2ee4c1,
            [0xf4b7d5ca]=0x98829f00,
        }},
    ['\074\221\172\081\090\174\094\150']={name="Illuminate tripod",nodes=151,bodies=10,finish_disabled=true,main={ -- lint-ok: R14 generated from profiles/catalog.json
        0x9b115563,0x54efdee3,0xb4a6064f,0xa7f9b6c7,0xc6b89048,0xe225767c,0xb1332141,0xa76ee4c6,0x9615b731,0x18ca9123},
        disabled_main={[0x9b115563]=true,[0x54efdee3]=true,[0xb4a6064f]=true,[0xa7f9b6c7]=true,[0xc6b89048]=true,[0xe225767c]=true,[0xb1332141]=true,[0xa76ee4c6]=true,[0x9615b731]=true,[0x18ca9123]=true},actors={
            [0x0143255a]=0xa7f9b6c7,
            [0x0410bac8]=0xe225767c,
            [0x105602e6]=0x8c5570c9,
            [0x1fcfcae3]=0xb4a6064f,
            [0x2434f4a4]=0x9615b731,
            [0x251fe443]=0x8c5570c9,
            [0x285484ce]=0x8c5570c9,
            [0x29ca953e]=0x18ca9123,
            [0x37236374]=0xe9b4fd2d,
            [0x3d43b4b1]=0x8c5570c9,
            [0x43a3844e]=0x8c5570c9,
            [0x470cf2c5]=0xb4a6064f,
            [0x4bca1f07]=0xa7f9b6c7,
            [0x53db7fab]=0x8c5570c9,
            [0x58a98e8a]=0x8c5570c9,
            [0x599c3f71]=0xb1332141,
            [0x7394dd4e]=0xe225767c,
            [0x764e448d]=0x54efdee3,
            [0x84ffdd57]=0x18ca9123,
            [0x8ffb63db]=0xa7f9b6c7,
            [0x918bc99f]=0x8c5570c9,
            [0x9212fdd7]=0x8c5570c9,
            [0x9ee677a7]=0x8c5570c9,
            [0xa7e3257e]=0xb1332141,
            [0xb7ff9cb7]=0x8c5570c9,
            [0xb875a8c9]=0xe90e668d,
            [0xc7134a8c]=0x18ca9123,
            [0xcabc21d4]=0xa76ee4c6,
            [0xcd871ca9]=0xc6b89048,
            [0xcec2d2ea]=0xb4a6064f,
            [0xd48608a6]=0xb1332141,
            [0xdf038f71]=0x9615b731,
            [0xecf00ed4]=0x9615b731,
            [0xee8b6459]=0x78678dbb,
            [0xf2931585]=0xe225767c,
            [0xf8720bf5]=0x8c5570c9,
            [0xfbb9eb3d]=0x8c5570c9,
        }},
    ['\221\175\204\204\242\023\046\158']={name="Bile Titan",nodes=175,bodies=15,finish_disabled=false,main={ -- lint-ok: R14 generated from profiles/catalog.json
        0x9b115563,0xdbd48a04,0x26787c5c,0xae5a7e64,0xdcb76f26,0x1ecb5822,0xc96f8166,0x6e8366df,0x0f5f005b,0x8b9102b4,0xfa1accaf,0x341adbcc,0xd66758f9,0x0f5d4be0,0x12fd8f94},
        disabled_main={},actors={
            [0x004c2c42]=0xdbd48a04,
            [0x039b7f81]=0x21077081,
            [0x10d33410]=0x341adbcc,
            [0x16a59ba2]=0xda85c105,
            [0x19e6fe8a]=0xfa1accaf,
            [0x19f2209c]=0x80e4f7f2,
            [0x1c48292d]=0xfa1accaf,
            [0x23c531ba]=0x6e8366df,
            [0x30e170ff]=0x12fd8f94,
            [0x3be56210]=0xdcb76f26,
            [0x3c46b53c]=0x18dd1e91,
            [0x3c5f0e49]=0xae5a7e64,
            [0x3f30dc56]=0x8b9102b4,
            [0x463a2568]=0x0f5d4be0,
            [0x46423f6e]=0x0f5d4be0,
            [0x47c28216]=0xfa1accaf,
            [0x49a925ae]=0x12fd8f94,
            [0x52d737df]=0x9b115563,
            [0x53db293f]=0xdbd48a04,
            [0x55a57f36]=0x341adbcc,
            [0x55ccc732]=0xd66758f9,
            [0x57b8072f]=0x8c5570c9,
            [0x5a842311]=0xdcb76f26,
            [0x5aadc52d]=0xd66758f9,
            [0x608de44e]=0xc96f8166,
            [0x60f53b5b]=0x1fe1649b,
            [0x651dd67f]=0xc96f8166,
            [0x6a8802b7]=0x1fe1649b,
            [0x6ab1c769]=0x12fd8f94,
            [0x71b2acb6]=0x9b115563,
            [0x7465e8ae]=0xfa1accaf,
            [0x77b2ae41]=0xdbd48a04,
            [0x7ee26daa]=0xd66758f9,
            [0x840ad440]=0x6e8366df,
            [0x89b9e04b]=0x8e1b5638,
            [0x8f13cb1f]=0x0f5f005b,
            [0x903fca3c]=0xc548cf56,
            [0x97f4290d]=0x1ecb5822,
            [0xa01a23bf]=0x9b115563,
            [0xa3dc7cf4]=0x9b115563,
            [0xa482b282]=0xd66758f9,
            [0xa77ec7c7]=0x8b9102b4,
            [0xaa9b9408]=0x0f5f005b,
            [0xb64845ef]=0x18dd1e91,
            [0xb6f6fd4b]=0x0f5f005b,
            [0xb7619f4e]=0x9b115563,
            [0xcac731dd]=0x1ecb5822,
            [0xce53b2c0]=0x1fe1649b,
            [0xd3f3095b]=0xae5a7e64,
            [0xd95fa79e]=0xdbe688f2,
            [0xdb3959e5]=0x12fd8f94,
            [0xe61823ad]=0xad0baf4d,
            [0xef27d4ee]=0x0f5f005b,
            [0xf1f5a7e7]=0x18dd1e91,
        }},
    ['\227\054\040\013\018\141\126\211']={name="Automaton spawner walker",nodes=210,bodies=15,finish_disabled=false,main={ -- lint-ok: R14 generated from profiles/catalog.json
        0x9b115563,0xa3db6464,0x6176721a,0x7f4baf16,0x3811f3cc,0xe4d20fe4,0x45a5d6bd,0x56189626,0x7f397e6d,0xb46dad07,0x6d44c60d,0xc63e0340,0xf0e212f0,0x6de398f6,0xb9b5a67f},
        disabled_main={},actors={
            [0x01ffd62e]=0xf0e212f0,
            [0x039f6e2f]=0xc919e14f,
            [0x03bd6c46]=0xb9b00b54,
            [0x0798ea0b]=0x9b115563,
            [0x0985c473]=0x0017206e,
            [0x0a90fe0c]=0xa3db6464,
            [0x0ba985e6]=0x95333e74,
            [0x0c66ca0e]=0xe4d20fe4,
            [0x0e55ef13]=0xe9ecca21,
            [0x1d167824]=0x6176721a,
            [0x1fb4084c]=0xe4d20fe4,
            [0x2410afc6]=0x9b115563,
            [0x3c48d0c9]=0x1532b593,
            [0x3dc58c92]=0x742da994,
            [0x44d0b43a]=0x7f397e6d,
            [0x45b8cacf]=0x57f106ae,
            [0x4ee68b3c]=0xa4923700,
            [0x5476f807]=0x9b115563,
            [0x55e6b6dd]=0x6176721a,
            [0x5a19e30b]=0xa3db6464,
            [0x5c8d78c7]=0xb122d4b0,
            [0x5cdf5a40]=0xb9b00b54,
            [0x5e44c962]=0xc3034eb8,
            [0x63f3fa41]=0x9b115563,
            [0x69ee871d]=0xc63e0340,
            [0x71290938]=0x7f397e6d,
            [0x74fe2609]=0x063273a4,
            [0x79c05f1c]=0x1fa54006,
            [0x7f16501c]=0xc6b84aef,
            [0x8762b50f]=0x9b115563,
            [0x87e4519b]=0x9b115563,
            [0x8ac8e73d]=0xa4923700,
            [0x8b9f3268]=0x95333e74,
            [0x8e885165]=0x9b115563,
            [0x92744e31]=0x9f6fc899,
            [0x940469dd]=0x3ad27028,
            [0x94451200]=0x9b115563,
            [0x9ea7fa9f]=0x45a5d6bd,
            [0xa0389869]=0x3811f3cc,
            [0xa120e458]=0x6de398f6,
            [0xa93ac296]=0x976d2073,
            [0xaca4ad55]=0x3811f3cc,
            [0xb038f623]=0x9b115563,
            [0xb0b93242]=0x61d12eda,
            [0xb7e47c2b]=0x2c30eee8,
            [0xbb34edee]=0x6d44c60d,
            [0xbdcfda3b]=0xbe9bf707,
            [0xbf3f38bd]=0xd17db882,
            [0xc45a18a3]=0x9b115563,
            [0xc53c7025]=0x976d2073,
            [0xc919245d]=0x747ef0ba,
            [0xcbbfa308]=0x2c30eee8,
            [0xd2dcdd55]=0x9b115563,
            [0xe21afe57]=0x56189626,
            [0xe7306164]=0x7f4baf16,
            [0xeb531a20]=0x6d44c60d,
            [0xf18a6723]=0x56189626,
            [0xf5e59381]=0x9b115563,
            [0xf6aa9cd2]=0xc63e0340,
            [0xfb24a5ea]=0xb46dad07,
            [0xfb53ec91]=0x976d2073,
        }},
    ['\170\250\163\033\164\072\011\150']={name="Terminid dragon",nodes=164,bodies=15,finish_disabled=false,main={ -- lint-ok: R14 generated from profiles/catalog.json
        0x9b115563,0x4b9e7b38,0x668f6a68,0x1030dbaf,0x6891a026,0x9653729b,0x90d91d27,0x6f2c148b,0x71a96497,0xa6585cd3,0xd0db16a9,0x1841c4d5,0x6c288500,0x8cdb60bc,0x220047a7},
        disabled_main={},actors={
            [0x004c2c42]=0xe242c80d,
            [0x039b7f81]=0xcf8445b9,
            [0x10d33410]=0xa6585cd3,
            [0x16a59ba2]=0x68d3fb30,
            [0x19e6fe8a]=0x541fae0e,
            [0x19f2209c]=0x80e4f7f2,
            [0x1b002036]=0x2647e642,
            [0x1c48292d]=0x541fae0e,
            [0x23c531ba]=0x6f2c148b,
            [0x30e170ff]=0x75e05d03,
            [0x3be56210]=0x6891a026,
            [0x3c46b53c]=0x8939410d,
            [0x3c5f0e49]=0x1030dbaf,
            [0x3f30dc56]=0x71a96497,
            [0x408d8403]=0x1841c4d5,
            [0x44016264]=0xd3f287d6,
            [0x463a2568]=0xd0db16a9,
            [0x46423f6e]=0xd0db16a9,
            [0x47c28216]=0x541fae0e,
            [0x49a925ae]=0x75e05d03,
            [0x4b57d58b]=0x8cdb60bc,
            [0x52d737df]=0x9b115563,
            [0x53db293f]=0xe242c80d,
            [0x55a57f36]=0xa6585cd3,
            [0x55ccc732]=0x3523339d,
            [0x57b8072f]=0x8c5570c9,
            [0x5a842311]=0x6891a026,
            [0x5aadc52d]=0x3523339d,
            [0x5e181e2d]=0x7efc7ff4,
            [0x608de44e]=0x90d91d27,
            [0x60f53b5b]=0x2bae612c,
            [0x651dd67f]=0x90d91d27,
            [0x6a8802b7]=0x2bae612c,
            [0x6ab1c769]=0x75e05d03,
            [0x6fa21947]=0xf85a589c,
            [0x71b2acb6]=0x9b115563,
            [0x7465e8ae]=0x541fae0e,
            [0x77b2ae41]=0xe242c80d,
            [0x7ee26daa]=0x3523339d,
            [0x802fe193]=0x6caccdd9,
            [0x840ad440]=0x6f2c148b,
            [0x89b9e04b]=0xc80e43c8,
            [0x8e9de399]=0x8eb0ff62,
            [0x8f13cb1f]=0xfc573edc,
            [0x903fca3c]=0x303f460f,
            [0x97f4290d]=0x9653729b,
            [0xa01a23bf]=0x9b115563,
            [0xa3dc7cf4]=0x9b115563,
            [0xa482b282]=0x3523339d,
            [0xa77ec7c7]=0x71a96497,
            [0xa7c7fa0d]=0x193fe3e3,
            [0xaa9b9408]=0xfc573edc,
            [0xb64845ef]=0x8939410d,
            [0xb6f6fd4b]=0xfc573edc,
            [0xb7619f4e]=0x9b115563,
            [0xc6644231]=0x6c288500,
            [0xc8118f77]=0x3ed1f07b,
            [0xcac731dd]=0x9653729b,
            [0xccb69ff6]=0x220047a7,
            [0xce53b2c0]=0x2bae612c,
            [0xd3f3095b]=0x1030dbaf,
            [0xd95fa79e]=0x0b5fd0b4,
            [0xdb3959e5]=0x75e05d03,
            [0xe61823ad]=0xd2fd31e4,
            [0xef27d4ee]=0xfc573edc,
            [0xf1f5a7e7]=0x8939410d,
        }},
    ['\094\096\171\244\146\035\032\107']={name="Acid Charger",nodes=138,bodies=15,finish_disabled=false,main={ -- lint-ok: R14 generated from profiles/catalog.json
        0x9b115563,0x58d886fb,0x5a4bbaa2,0x1fba9b23,0xacb975d0,0xe411e02e,0x8329f875,0x4014953a,0xc1466369,0xf69f42da,0x73bc7ae4,0xce7e106a,0x38f24831,0xf452db4a,0x9b47948d},
        disabled_main={},actors={
            [0x0be61734]=0x4508030c,
            [0x0c1a03a6]=0x73bc7ae4,
            [0x0f578594]=0x564e8bcc,
            [0x18f490f9]=0xe64ac2fe,
            [0x1e2dfe08]=0x9b47948d,
            [0x1ff1c46a]=0x91c08b37,
            [0x201edb75]=0xe411e02e,
            [0x26480fa9]=0xce7e106a,
            [0x292c4f7f]=0x9b115563,
            [0x36f081c0]=0xf452db4a,
            [0x3e0c625f]=0x8329f875,
            [0x47405e14]=0x38f24831,
            [0x4c1fe16d]=0xc1466369,
            [0x4e884507]=0x9b115563,
            [0x57177953]=0x1fba9b23,
            [0x5f2485fd]=0xf69f42da,
            [0x61a8a415]=0xe411e02e,
            [0x6d151e1b]=0x9b115563,
            [0x6f662c60]=0xacb975d0,
            [0x705c7df3]=0xacb975d0,
            [0x721e0952]=0x73bc7ae4,
            [0x75a5244f]=0x9b47948d,
            [0x82219dbd]=0xb9b5a67f,
            [0x837d120d]=0x58d886fb,
            [0x879c1a75]=0x5a4bbaa2,
            [0x87a058bf]=0x9b115563,
            [0x900f945b]=0x4014953a,
            [0x92117bdc]=0x139899e4,
            [0x929bdf01]=0xb0368f97,
            [0x9738443f]=0xbf117365,
            [0x9ff3e081]=0xc1466369,
            [0xa3d491d1]=0x9b115563,
            [0xbbaa3755]=0x58d886fb,
            [0xbbd1a69d]=0xe64ac2fe,
            [0xc581670e]=0xe38c6308,
            [0xc79200d4]=0x1901e4fb,
            [0xcab4db4c]=0x01172b31,
            [0xd294967b]=0x1fba9b23,
            [0xd90601f5]=0x42831670,
            [0xe3da2507]=0x9b115563,
            [0xe7414eac]=0x9b115563,
            [0xeab0621d]=0xce7e106a,
            [0xf64c750a]=0x42831670,
            [0xf6c42514]=0x58d886fb,
            [0xf6ca3127]=0x9b115563,
            [0xf786b2b4]=0x38f24831,
        }},
    ['\140\034\028\019\043\185\183\010']={name="Burrowing Charger",nodes=129,bodies=15,finish_disabled=false,main={ -- lint-ok: R14 generated from profiles/catalog.json
        0x9b115563,0x58d886fb,0x5a4bbaa2,0x1fba9b23,0xacb975d0,0xe411e02e,0x8329f875,0x4014953a,0xc1466369,0xf69f42da,0x73bc7ae4,0xce7e106a,0x38f24831,0xf452db4a,0x9b47948d},
        disabled_main={},actors={
            [0x0be61734]=0x4508030c,
            [0x0f578594]=0x564e8bcc,
            [0x1e2dfe08]=0x9b47948d,
            [0x1ff1c46a]=0x91c08b37,
            [0x201edb75]=0xe411e02e,
            [0x292c4f7f]=0x9b115563,
            [0x36f081c0]=0xf452db4a,
            [0x3e0c625f]=0x8329f875,
            [0x47405e14]=0x38f24831,
            [0x4c1fe16d]=0xc1466369,
            [0x4e884507]=0x9b115563,
            [0x57177953]=0x1fba9b23,
            [0x5f2485fd]=0xf69f42da,
            [0x6d151e1b]=0x9b115563,
            [0x6f662c60]=0xacb975d0,
            [0x721e0952]=0x73bc7ae4,
            [0x82219dbd]=0xb9b5a67f,
            [0x837d120d]=0x58d886fb,
            [0x879c1a75]=0x5a4bbaa2,
            [0x87a058bf]=0x9b115563,
            [0x900f945b]=0x4014953a,
            [0x92117bdc]=0x139899e4,
            [0x929bdf01]=0xb0368f97,
            [0xa3d491d1]=0x9b115563,
            [0xbbaa3755]=0x58d886fb,
            [0xbbd1a69d]=0xe64ac2fe,
            [0xc581670e]=0xe38c6308,
            [0xc79200d4]=0x1901e4fb,
            [0xc947ded4]=0xbccf91e5,
            [0xcab4db4c]=0x01172b31,
            [0xd90601f5]=0x42831670,
            [0xe3da2507]=0x9b115563,
            [0xe7414eac]=0x9b115563,
            [0xeab0621d]=0xce7e106a,
            [0xf6c42514]=0x58d886fb,
            [0xf6ca3127]=0x9b115563,
        }},
    ['\003\120\137\060\101\071\082\253']={name="Charger bull (unnamed entity variant)",nodes=127,bodies=15,finish_disabled=false,main={ -- lint-ok: R14 generated from profiles/catalog.json
        0x9b115563,0x58d886fb,0x5a4bbaa2,0x1fba9b23,0xacb975d0,0xe411e02e,0x8329f875,0x4014953a,0xc1466369,0xf69f42da,0x73bc7ae4,0xce7e106a,0x38f24831,0xf452db4a,0x9b47948d},
        disabled_main={},actors={
            [0x0be61734]=0x4508030c,
            [0x0f578594]=0x564e8bcc,
            [0x1e2dfe08]=0x9b47948d,
            [0x1ff1c46a]=0x91c08b37,
            [0x201edb75]=0xe411e02e,
            [0x292c4f7f]=0x9b115563,
            [0x36f081c0]=0xf452db4a,
            [0x3e0c625f]=0x8329f875,
            [0x47405e14]=0x38f24831,
            [0x4c1fe16d]=0xc1466369,
            [0x4e884507]=0x9b115563,
            [0x57177953]=0x1fba9b23,
            [0x5f2485fd]=0xf69f42da,
            [0x6d151e1b]=0x9b115563,
            [0x6f662c60]=0xacb975d0,
            [0x721e0952]=0x73bc7ae4,
            [0x82219dbd]=0xb9b5a67f,
            [0x837d120d]=0x58d886fb,
            [0x879c1a75]=0x5a4bbaa2,
            [0x87a058bf]=0x9b115563,
            [0x900f945b]=0x4014953a,
            [0x92117bdc]=0x139899e4,
            [0x929bdf01]=0xb0368f97,
            [0xa3d491d1]=0x9b115563,
            [0xbbaa3755]=0x58d886fb,
            [0xbbd1a69d]=0xe64ac2fe,
            [0xc581670e]=0xe38c6308,
            [0xc79200d4]=0x1901e4fb,
            [0xcab4db4c]=0x01172b31,
            [0xd90601f5]=0x42831670,
            [0xe3da2507]=0x9b115563,
            [0xe7414eac]=0x9b115563,
            [0xeab0621d]=0xce7e106a,
            [0xf6c42514]=0x58d886fb,
            [0xf6ca3127]=0x9b115563,
        }},
    ['\122\034\063\051\226\222\242\048']={name="Automaton jammer spawner walker",nodes=210,bodies=15,finish_disabled=false,main={ -- lint-ok: R14 generated from profiles/catalog.json
        0x9b115563,0xa3db6464,0x6176721a,0x7f4baf16,0x3811f3cc,0xe4d20fe4,0x45a5d6bd,0x56189626,0x7f397e6d,0xb46dad07,0x6d44c60d,0xc63e0340,0xf0e212f0,0x6de398f6,0xb9b5a67f},
        disabled_main={},actors={
            [0x01ffd62e]=0xf0e212f0,
            [0x039f6e2f]=0xc919e14f,
            [0x03bd6c46]=0xb9b00b54,
            [0x0798ea0b]=0x9b115563,
            [0x0985c473]=0x0017206e,
            [0x0a90fe0c]=0xa3db6464,
            [0x0ba985e6]=0x95333e74,
            [0x0c66ca0e]=0xe4d20fe4,
            [0x0e55ef13]=0xe9ecca21,
            [0x1d167824]=0x6176721a,
            [0x1fb4084c]=0xe4d20fe4,
            [0x2410afc6]=0x9b115563,
            [0x3c48d0c9]=0x1532b593,
            [0x3dc58c92]=0x742da994,
            [0x44d0b43a]=0x7f397e6d,
            [0x45b8cacf]=0x57f106ae,
            [0x4ee68b3c]=0xa4923700,
            [0x5476f807]=0x9b115563,
            [0x55e6b6dd]=0x6176721a,
            [0x5a19e30b]=0xa3db6464,
            [0x5c8d78c7]=0xb122d4b0,
            [0x5cdf5a40]=0xb9b00b54,
            [0x5e44c962]=0xc3034eb8,
            [0x63f3fa41]=0x9b115563,
            [0x69ee871d]=0xc63e0340,
            [0x71290938]=0x7f397e6d,
            [0x74fe2609]=0x063273a4,
            [0x79c05f1c]=0x1fa54006,
            [0x7f16501c]=0xc6b84aef,
            [0x8762b50f]=0x9b115563,
            [0x87e4519b]=0x9b115563,
            [0x8ac8e73d]=0xa4923700,
            [0x8b9f3268]=0x95333e74,
            [0x8e885165]=0x9b115563,
            [0x92744e31]=0x9f6fc899,
            [0x940469dd]=0x3ad27028,
            [0x94451200]=0x9b115563,
            [0x9ea7fa9f]=0x45a5d6bd,
            [0xa0389869]=0x3811f3cc,
            [0xa120e458]=0x6de398f6,
            [0xa93ac296]=0x976d2073,
            [0xaca4ad55]=0x3811f3cc,
            [0xb038f623]=0x9b115563,
            [0xb0b93242]=0x61d12eda,
            [0xb7e47c2b]=0x2c30eee8,
            [0xbb34edee]=0x6d44c60d,
            [0xbdcfda3b]=0xbe9bf707,
            [0xbf3f38bd]=0xd17db882,
            [0xc45a18a3]=0x9b115563,
            [0xc53c7025]=0x976d2073,
            [0xc919245d]=0x747ef0ba,
            [0xcbbfa308]=0x2c30eee8,
            [0xd2dcdd55]=0x9b115563,
            [0xe21afe57]=0x56189626,
            [0xe7306164]=0x7f4baf16,
            [0xeb531a20]=0x6d44c60d,
            [0xf18a6723]=0x56189626,
            [0xf5e59381]=0x9b115563,
            [0xf6aa9cd2]=0xc63e0340,
            [0xfb24a5ea]=0xb46dad07,
            [0xfb53ec91]=0x976d2073,
        }},
    ['\136\061\051\056\035\226\033\096']={name="Nursing Spewer mission variant",nodes=99,bodies=14,finish_disabled=false,main={ -- lint-ok: R14 generated from profiles/catalog.json
        0x9b115563,0x0f0196b3,0xc96f8166,0xae5a7e64,0xdcb76f26,0x1ecb5822,0x0f5d4be0,0x12fd8f94,0x341adbcc,0xd66758f9,0x8b9102b4,0xfa1accaf,0x6e8366df,0x0f5f005b},
        disabled_main={},actors={
            [0x312d55bb]=0x0e835875,
            [0x4ea4da87]=0x09a026f5,
            [0x573a0652]=0x1c5f3be4,
            [0xa3d491d1]=0xbccf91e5,
            [0xbc01b5fd]=0x0f0196b3,
        }},
    ['\151\164\151\208\132\203\004\239']={name="Gloom Bile Titan",nodes=175,bodies=15,finish_disabled=false,main={ -- lint-ok: R14 generated from profiles/catalog.json
        0x9b115563,0xdbd48a04,0x26787c5c,0xae5a7e64,0xdcb76f26,0x1ecb5822,0xc96f8166,0x6e8366df,0x0f5f005b,0x8b9102b4,0xfa1accaf,0x341adbcc,0xd66758f9,0x0f5d4be0,0x12fd8f94},
        disabled_main={},actors={
            [0x004c2c42]=0xdbd48a04,
            [0x039b7f81]=0x21077081,
            [0x10d33410]=0x341adbcc,
            [0x16a59ba2]=0xda85c105,
            [0x19e6fe8a]=0xfa1accaf,
            [0x19f2209c]=0x80e4f7f2,
            [0x1c48292d]=0xfa1accaf,
            [0x23c531ba]=0x6e8366df,
            [0x30e170ff]=0x12fd8f94,
            [0x3be56210]=0xdcb76f26,
            [0x3c46b53c]=0x18dd1e91,
            [0x3c5f0e49]=0xae5a7e64,
            [0x3f30dc56]=0x8b9102b4,
            [0x463a2568]=0x0f5d4be0,
            [0x46423f6e]=0x0f5d4be0,
            [0x47c28216]=0xfa1accaf,
            [0x49a925ae]=0x12fd8f94,
            [0x52d737df]=0x9b115563,
            [0x53db293f]=0xdbd48a04,
            [0x55a57f36]=0x341adbcc,
            [0x55ccc732]=0xd66758f9,
            [0x57b8072f]=0x8c5570c9,
            [0x5a842311]=0xdcb76f26,
            [0x5aadc52d]=0xd66758f9,
            [0x608de44e]=0xc96f8166,
            [0x60f53b5b]=0x1fe1649b,
            [0x651dd67f]=0xc96f8166,
            [0x6a8802b7]=0x1fe1649b,
            [0x6ab1c769]=0x12fd8f94,
            [0x71b2acb6]=0x9b115563,
            [0x7465e8ae]=0xfa1accaf,
            [0x77b2ae41]=0xdbd48a04,
            [0x7ee26daa]=0xd66758f9,
            [0x840ad440]=0x6e8366df,
            [0x89b9e04b]=0x8e1b5638,
            [0x8f13cb1f]=0x0f5f005b,
            [0x903fca3c]=0xc548cf56,
            [0x97f4290d]=0x1ecb5822,
            [0xa01a23bf]=0x9b115563,
            [0xa3dc7cf4]=0x9b115563,
            [0xa482b282]=0xd66758f9,
            [0xa77ec7c7]=0x8b9102b4,
            [0xaa9b9408]=0x0f5f005b,
            [0xb64845ef]=0x18dd1e91,
            [0xb6f6fd4b]=0x0f5f005b,
            [0xb7619f4e]=0x9b115563,
            [0xcac731dd]=0x1ecb5822,
            [0xce53b2c0]=0x1fe1649b,
            [0xd3f3095b]=0xae5a7e64,
            [0xd95fa79e]=0xdbe688f2,
            [0xdb3959e5]=0x12fd8f94,
            [0xe61823ad]=0xad0baf4d,
            [0xef27d4ee]=0x0f5f005b,
            [0xf1f5a7e7]=0x18dd1e91,
        }},
    ['\153\011\069\213\215\095\255\058']={name="Charger bull",nodes=127,bodies=15,finish_disabled=false,main={ -- lint-ok: R14 generated from profiles/catalog.json
        0x9b115563,0x58d886fb,0x5a4bbaa2,0x1fba9b23,0xacb975d0,0xe411e02e,0x8329f875,0x4014953a,0xc1466369,0xf69f42da,0x73bc7ae4,0xce7e106a,0x38f24831,0xf452db4a,0x9b47948d},
        disabled_main={},actors={
            [0x0be61734]=0x4508030c,
            [0x0f578594]=0x564e8bcc,
            [0x1e2dfe08]=0x9b47948d,
            [0x1ff1c46a]=0x91c08b37,
            [0x201edb75]=0xe411e02e,
            [0x292c4f7f]=0x9b115563,
            [0x36f081c0]=0xf452db4a,
            [0x3e0c625f]=0x8329f875,
            [0x47405e14]=0x38f24831,
            [0x4c1fe16d]=0xc1466369,
            [0x4e884507]=0x9b115563,
            [0x57177953]=0x1fba9b23,
            [0x5f2485fd]=0xf69f42da,
            [0x6d151e1b]=0x9b115563,
            [0x6f662c60]=0xacb975d0,
            [0x721e0952]=0x73bc7ae4,
            [0x82219dbd]=0xb9b5a67f,
            [0x837d120d]=0x58d886fb,
            [0x879c1a75]=0x5a4bbaa2,
            [0x87a058bf]=0x9b115563,
            [0x900f945b]=0x4014953a,
            [0x92117bdc]=0x139899e4,
            [0x929bdf01]=0xb0368f97,
            [0xa3d491d1]=0x9b115563,
            [0xbbaa3755]=0x58d886fb,
            [0xbbd1a69d]=0xe64ac2fe,
            [0xc581670e]=0xe38c6308,
            [0xc79200d4]=0x1901e4fb,
            [0xcab4db4c]=0x01172b31,
            [0xd90601f5]=0x42831670,
            [0xe3da2507]=0x9b115563,
            [0xe7414eac]=0x9b115563,
            [0xeab0621d]=0xce7e106a,
            [0xf6c42514]=0x58d886fb,
            [0xf6ca3127]=0x9b115563,
        }},
    ['\176\100\198\152\255\205\127\026']={name="Charger",nodes=127,bodies=15,finish_disabled=false,main={ -- lint-ok: R14 generated from profiles/catalog.json
        0x9b115563,0x58d886fb,0x5a4bbaa2,0x1fba9b23,0xacb975d0,0xe411e02e,0x8329f875,0x4014953a,0xc1466369,0xf69f42da,0x73bc7ae4,0xce7e106a,0x38f24831,0xf452db4a,0x9b47948d},
        disabled_main={},actors={
            [0x0be61734]=0x4508030c,
            [0x0f578594]=0x564e8bcc,
            [0x1e2dfe08]=0x9b47948d,
            [0x1ff1c46a]=0x91c08b37,
            [0x201edb75]=0xe411e02e,
            [0x292c4f7f]=0x9b115563,
            [0x36f081c0]=0xf452db4a,
            [0x3e0c625f]=0x8329f875,
            [0x47405e14]=0x38f24831,
            [0x4c1fe16d]=0xc1466369,
            [0x4e884507]=0x9b115563,
            [0x57177953]=0x1fba9b23,
            [0x5f2485fd]=0xf69f42da,
            [0x6d151e1b]=0x9b115563,
            [0x6f662c60]=0xacb975d0,
            [0x721e0952]=0x73bc7ae4,
            [0x82219dbd]=0xb9b5a67f,
            [0x837d120d]=0x58d886fb,
            [0x879c1a75]=0x5a4bbaa2,
            [0x87a058bf]=0x9b115563,
            [0x900f945b]=0x4014953a,
            [0x92117bdc]=0x139899e4,
            [0x929bdf01]=0xb0368f97,
            [0xa3d491d1]=0x9b115563,
            [0xbbaa3755]=0x58d886fb,
            [0xbbd1a69d]=0xe64ac2fe,
            [0xc581670e]=0xe38c6308,
            [0xc79200d4]=0x1901e4fb,
            [0xcab4db4c]=0x01172b31,
            [0xd90601f5]=0x42831670,
            [0xe3da2507]=0x9b115563,
            [0xe7414eac]=0x9b115563,
            [0xeab0621d]=0xce7e106a,
            [0xf6c42514]=0x58d886fb,
            [0xf6ca3127]=0x9b115563,
        }},
    ['\076\172\179\103\236\209\091\160']={name="Charger tier 2",nodes=127,bodies=15,finish_disabled=false,main={ -- lint-ok: R14 generated from profiles/catalog.json
        0x9b115563,0x58d886fb,0x5a4bbaa2,0x1fba9b23,0xacb975d0,0xe411e02e,0x8329f875,0x4014953a,0xc1466369,0xf69f42da,0x73bc7ae4,0xce7e106a,0x38f24831,0xf452db4a,0x9b47948d},
        disabled_main={},actors={
            [0x0be61734]=0x4508030c,
            [0x0f578594]=0x564e8bcc,
            [0x1e2dfe08]=0x9b47948d,
            [0x1ff1c46a]=0x91c08b37,
            [0x201edb75]=0xe411e02e,
            [0x292c4f7f]=0x9b115563,
            [0x36f081c0]=0xf452db4a,
            [0x3e0c625f]=0x8329f875,
            [0x47405e14]=0x38f24831,
            [0x4c1fe16d]=0xc1466369,
            [0x4e884507]=0x9b115563,
            [0x57177953]=0x1fba9b23,
            [0x5f2485fd]=0xf69f42da,
            [0x6d151e1b]=0x9b115563,
            [0x6f662c60]=0xacb975d0,
            [0x721e0952]=0x73bc7ae4,
            [0x82219dbd]=0xb9b5a67f,
            [0x837d120d]=0x58d886fb,
            [0x879c1a75]=0x5a4bbaa2,
            [0x87a058bf]=0x9b115563,
            [0x900f945b]=0x4014953a,
            [0x92117bdc]=0x139899e4,
            [0x929bdf01]=0xb0368f97,
            [0xa3d491d1]=0x9b115563,
            [0xbbaa3755]=0x58d886fb,
            [0xbbd1a69d]=0xe64ac2fe,
            [0xc581670e]=0xe38c6308,
            [0xc79200d4]=0x1901e4fb,
            [0xcab4db4c]=0x01172b31,
            [0xd90601f5]=0x42831670,
            [0xe3da2507]=0x9b115563,
            [0xe7414eac]=0x9b115563,
            [0xeab0621d]=0xce7e106a,
            [0xf6c42514]=0x58d886fb,
            [0xf6ca3127]=0x9b115563,
        }},
}
return profiles

end)()
local patch = (function(...)
-- Corpse collision repair and renewed-motion containment. The resource -- lint-ok: R15 the scan steps share one poll's upvalues; splitting the file changes the chunk interface of every test and the Megapack component: follow-up
-- allowlist is generated data in src/corpse_profiles.lua (from
-- profiles/catalog.json); the module wrapper passes it in as this chunk's
-- argument.
local profiles=...
assert(type(profiles)=='table','Corpse profiles unavailable')
for _,p in pairs(profiles) do
    p.main_names={};for _,name in ipairs(p.main) do p.main_names[name]=true end
end
local claws = {[0x92d0871f]=true,[0x6635646b]=true,[0x50b19c0a]=true}
-- The 8-byte resource keys by their two little-endian words, so an entity
-- header seen through a view finds its profile without making a string.
local resource_words={}
for key in pairs(profiles) do
    local b1,b2,b3,b4,b5,b6,b7,b8=key:byte(1,8)
    local low=b1+b2*256+b3*65536+b4*16777216
    resource_words[low]=resource_words[low] or {}
    resource_words[low][b5+b6*256+b7*65536+b8*16777216]=key
end

local ffi,bit=require('ffi'),require('bit')
-- interval: seconds of frame time between polls. It was 1/30 s on
-- GetTickCount64, which advances in 15.625 ms steps, so polls came every
-- third step: 46.9 ms (21 Hz) at 60 FPS and above, every other frame (15 Hz)
-- at 30 FPS. The frame time now drives the poll (archive_loader.lua) at that
-- same measured period, so the poll rate does not rise.
local M={profiles=profiles,interval=3/64,max_entities=128,max_units=4,budget_seconds=.001}
M.completion_grace=1
-- Corpse re-check backoff. A corpse's collision is repaired at conversion
-- (about 0.2 s after); recordings show no collider of a settled corpse moving
-- again, and every gap under 2.5 cm from 1 s after conversion (KB
-- corpse-recheck-backoff-2026-10-17). So a corpse that needed no command on
-- every inspection for corpse_settle_polls polls is inspected again after
-- 2, 4, 8 ... polls, at most corpse_recheck_polls (about 3-4 s); one that
-- needs a command starts over. 0 turns the backoff off.
M.corpse_settle_polls=24
M.corpse_recheck_polls=64
local ZERO8=string.rep('\0',8)
local byte,ldexp,floor=string.byte,math.ldexp,math.floor
-- Little-endian decode from the copied bytes. Unlike an FFI cast, this makes
-- no cdata object when the interpreter, not a compiled trace, runs it.
local function u32(b,o)
    o=o or 0
    assert(o>=0 and o+4<=#b,'Scalar outside copied data')
    local b1,b2,b3,b4=byte(b,o+1,o+4)
    return b1+b2*256+b3*65536+b4*16777216
end
-- The same word in a scratch view (api.view's buffer) at a fixed offset the
-- caller has bounded: no Lua string is made for it.
local function view_u32(v,o) return v[o]+v[o+1]*256+v[o+2]*65536+v[o+3]*16777216 end
-- One IEEE single from copied bytes, by arithmetic. A NaN loaded through an FFI
-- float can reach Lua as a value that is not a number in this NaN-tagged
-- LuaJIT; here every NaN is Lua's own 0/0, which finite() rejects.
local function float_at(b,o)
    local b1,b2,b3,b4=byte(b,o+1,o+4)
    local exponent,mantissa=(b4%128)*2+floor(b3/128),(b3%128)*65536+b2*256+b1
    local value
    if exponent==255 then value=mantissa==0 and math.huge or 0/0
    elseif exponent==0 then value=ldexp(mantissa,-149)
    else value=ldexp(mantissa+8388608,exponent-150) end
    if b4>=128 then return -value end
    return value
end
local function floats(b,o,n)
    assert(o>=0 and n<=16 and o+n*4<=#b,'Matrix outside copied data')
    local out={};for i=1,n do out[i]=float_at(b,o+(i-1)*4) end;return out
end
M.floats=floats -- for tests: the decoder poses use
local function phase(api,name)
    if api.profiler then return api.profiler.phase(name) end
end
-- Build 26088801 port: a command runs only once its routines compared equal
-- (native.ready); a native table without ready (the offline fixtures) counts
-- as compared, as upstream's load-time check did.
local function native_ready(state,kind)
    local ready=state.native.ready
    if ready==nil or ready(kind) then return true end
    state.native_waits=(state.native_waits or 0)+1;return false
end
local function detail(api,name)
    if api.profiler then api.profiler.detail(name) end
end
local function finite(n) return type(n)=='number' and n==n and math.abs(n)<100000 end

-- Havok body translations and unit matrices use the same world-space node
-- origin. Shape-local geometry remains in the existing shape. Remove skeletal
-- scale from the orientation; do not resize or replace a collision shape.
local RIGID_FIELDS={1,2,3,5,6,7,9,10,11,13,14,15}
local function unit3(a,b,c)
    local n=math.sqrt(a*a+b*b+c*c);if not finite(n) or n<0.001 then return nil end
    return a/n,b/n,c/n
end
-- Numeric core of M.rigid: position XYZ then quaternion XYZW, or nil. It builds
-- no tables, so poses that turn out aligned cost no garbage. Same arithmetic,
-- in the same order, as the table form it replaced.
local function rigid_values(matrix)
    for i=1,12 do if not finite(matrix[RIGID_FIELDS[i]]) then return nil end end
    local x1,x2,x3=unit3(matrix[1],matrix[2],matrix[3]);if not x1 then return nil end
    local y1,y2,y3=unit3(matrix[5],matrix[6],matrix[7]);if not y1 then return nil end
    local z1,z2,z3=unit3(matrix[9],matrix[10],matrix[11]);if not z1 then return nil end
    if math.abs(x1*y1+x2*y2+x3*y3)>.025 or math.abs(x1*z1+x2*z2+x3*z3)>.025
        or math.abs(y1*z1+y2*z2+y3*z3)>.025 then return nil end
    local c1,c2,c3=x2*y3-x3*y2,x3*y1-x1*y3,x1*y2-x2*y1
    if c1*z1+c2*z2+c3*z3<.99 then return nil end
    -- Column-major matrix to XYZW quaternion.
    local trace=x1+y2+z3
    local s,a,b,c,d
    if trace>0 then
        s=math.sqrt(trace+1)*2;a,b,c,d=(y3-z2)/s,(z1-x3)/s,(x2-y1)/s,s/4
    elseif x1>y2 and x1>z3 then
        s=math.sqrt(1+x1-y2-z3)*2;a,b,c,d=s/4,(y1+x2)/s,(z1+x3)/s,(y3-z2)/s
    elseif y2>z3 then
        s=math.sqrt(1+y2-x1-z3)*2;a,b,c,d=(y1+x2)/s,s/4,(z2+y3)/s,(z1-x3)/s
    else
        s=math.sqrt(1+z3-x1-y2)*2;a,b,c,d=(z1+x3)/s,(z2+y3)/s,s/4,(x2-y1)/s
    end
    local length=math.sqrt(a^2+b^2+c^2+d^2)
    if not finite(length) or length<.001 then return nil end
    return matrix[13],matrix[14],matrix[15],a/length,b/length,c/length,d/length
end

-- M.rigid's numbers, for a pose that may not be a 16-number table.
local function rigid_pose(matrix)
    if type(matrix)~='table' or #matrix~=16 then return nil end
    return rigid_values(matrix)
end

function M.rigid(matrix)
    local px,py,pz,qx,qy,qz,qw=rigid_pose(matrix)
    if not px then return nil end
    return {px,py,pz},{qx,qy,qz,qw}
end

local function settled(unit)
    local profile=profiles[unit.resource]
    return profile and unit.settled and unit.main_enabled~=nil
        and unit.main_enabled+(unit.main_disabled or 0)==profile.bodies
        and unit.main_static==unit.main_enabled
end

local function command_guards(actor)
    -- Most inspected auxiliaries already align and never receive a command.
    -- Keep their copied guard bytes compact until a real action needs the
    -- usual fresh identity/motion checks. This never rereads stale addresses.
    local b=actor.guard_source
    if not actor.guards and b then
        -- b[6] is the whole 160-byte body copied this poll; slice its motion
        -- and identity words exactly as they were read.
        actor.guards={{address=b[1],bytes=b[2]},{address=b[3],bytes=b[4]},
            {address=b[5]+64,bytes=b[6]:sub(65,68)},{address=b[5]+144,bytes=b[6]:sub(145,152)}}
    end
end

function M.plan(unit)
    local profile=profiles[unit.resource]
    -- Recorded assault-walker Corpses retain a dynamic torso and rocket pods.
    -- They must not block auxiliary repair on the fixed base. This exception
    -- is Corpse-only; it never relaxes RagdollSync stopping/completion gates.
    local mixed=profile and profile.corpse_dynamic_main and unit.corpse and unit.settled
        and unit.main_enabled~=nil and unit.main_enabled+(unit.main_disabled or 0)==profile.bodies
        and unit.main_static>0 and unit.main_static+(unit.main_dynamic_allowed or 0)==unit.main_enabled
    if not settled(unit) and not mixed then return {} end
    local actions={}
    for _,a in ipairs(unit.actors) do
        if a.enabled and a.stable and not a.registered and profile.actors[a.name]==a.node_hash then
            if profile.name=='Impaler' and claws[a.name] then
                command_guards(a)
                actions[#actions+1]={kind='disable',actor=a}
            elseif a.motion==0 and a.pose~=a.node_pose then
                local px,py,pz,qx,qy,qz,qw=rigid_values(a.node_pose)
                local ox,oy,oz,rx,ry,rz,rw=rigid_values(a.pose)
                if px and ox then
                    local distance=math.sqrt((px-ox)^2+(py-oy)^2+(pz-oz)^2)
                    local rotation=math.abs(qx*rx+qy*ry+qz*rz+qw*rw)
                    -- 2.5 cm / half a degree avoid rewriting an already aligned
                    -- stationary corpse. There is no upper gap cutoff: the
                    -- recorded 27 m failure must remain repairable.
                    if distance>.025 or rotation<.9999904807207345 then
                        command_guards(a)
                        actions[#actions+1]={kind='pose',actor=a,position={px,py,pz},rotation={qx,qy,qz,qw},
                            gap=distance,degrees=math.deg(2*math.acos(math.min(1,rotation)))}
                    end
                end
            end
        end
    end
    return actions
end

-- Compares expected bytes with a copied block at offset without creating a
-- substring. Copied game data is unique per poll, so every :sub() allocated.
local function ranges_equal(a,a_offset,b,b_offset,n)
    if a_offset<0 or b_offset<0 or a_offset+n>#a or b_offset+n>#b then return false end
    for i=1,n do if byte(a,a_offset+i)~=byte(b,b_offset+i) then return false end end
    return true
end
local function matches(block,offset,expected) return ranges_equal(block,offset,expected,0,#expected) end
-- The same comparison against a scratch view of `size` copied bytes.
local function view_matches(view,size,offset,expected)
    local n=#expected
    if offset<0 or offset+n>size then return false end
    for i=1,n do if view[offset+i-1]~=byte(expected,i) then return false end end
    return true
end
-- One guard against fresh game bytes: through the view when the adapter has
-- one (no Lua string), otherwise through an ordinary read.
local function viewable(api) return api.view~=nil and api.view_read==api.read end
local function unchanged(api,g)
    local n=#g.bytes
    if viewable(api) then
        local view=api.view(g.address,n)
        return view~=nil and view_matches(view,n,0,g.bytes)
    end
    return api.read(g.address,n)==g.bytes
end
-- Copies size bytes at address with one view, so several guarded words that
-- lie close together cost one copy instead of one read each (the snapshot's
-- guard takes their bytes from it). Without the paired view, or if the copy
-- fails, the result is false or nil and each word is read on its own, exactly
-- as before.
local function capture(api,address,size) return viewable(api) and api.view(address,size) end

-- Sort order for compile: one comparator for every plan, not a new closure per
-- plan. sort_numbers is set only for the duration of the sort.
local sort_numbers
local function by_address(a,b) return sort_numbers[a]<sort_numbers[b] end
-- Grouping plan for one guard list, kept as parallel number arrays rather than
-- a table per guard. The list's entries and their address/bytes are recorded,
-- so any change to the list forces a fresh plan exactly as before.
local function compile(api,guards)
    local n=#guards
    local c={count=n,entries={},addresses={},bytes={},numbers={},order={},first={},last={},start={},size={}}
    local numbers,order=c.numbers,c.order
    for i=1,n do
        local g=guards[i]
        c.entries[i]=g;c.addresses[i]=g.address;c.bytes[i]=g.bytes
        numbers[i]=api.address(g.address);order[i]=i
    end
    sort_numbers=numbers;table.sort(order,by_address);sort_numbers=nil
    local groups=0
    for k=1,n do
        local i=order[k]
        local number,length=numbers[i],#guards[i].bytes
        if groups==0 or number>c.start[groups]+c.size[groups]+128 or number+length-c.start[groups]>4096 then
            groups=groups+1;c.first[groups]=k;c.start[groups]=number;c.size[groups]=length
        else c.size[groups]=math.max(c.size[groups],number+length-c.start[groups]) end
        c.last[groups]=k
    end
    c.groups=groups
    return c
end

local function current(compiled,guards)
    if not compiled or compiled.count~=#guards then return false end
    for i=1,compiled.count do
        local g=guards[i]
        if g~=compiled.entries[i] or g.address~=compiled.addresses[i] or g.bytes~=compiled.bytes[i] then return false end
    end
    return true
end

local function same(api,guards)
    local previous=phase(api,'validation')
    local result=true
    if not api.address or #guards<2 then
        for _,g in ipairs(guards) do if not unchanged(api,g) then result=false;break end end
        phase(api,previous);return result
    end
    local compiled=guards.compiled
    if not current(compiled,guards) then compiled=compile(api,guards);guards.compiled=compiled end
    local order,numbers=compiled.order,compiled.numbers
    for group=1,compiled.groups do
        local start,size=compiled.start[group],compiled.size[group]
        local address=guards[order[compiled.first[group]]].address
        local view=viewable(api) and api.view(address,size) or nil
        local block=not view and api.read(address,size)
        local whole=view~=nil or (block and #block==size)
        for k=compiled.first[group],compiled.last[group] do
            local check=guards[order[k]]
            local ok
            if view then ok=view_matches(view,size,numbers[order[k]]-start,check.bytes)
            elseif whole then ok=matches(block,numbers[order[k]]-start,check.bytes)
            else ok=unchanged(api,check) end
            if not ok then result=false;break end
        end
        if not result then break end
    end
    phase(api,previous);return result
end
M.same=same

-- Distance and degrees between a pose (position XYZ then rotation XYZW, seven
-- numbers) and a kept position and rotation.
local function separation(pose,old,oldq)
    local distance=math.sqrt((pose[1]-old[1])^2+(pose[2]-old[2])^2+(pose[3]-old[3])^2)
    local cosine=math.min(1,math.abs(pose[4]*oldq[1]+pose[5]*oldq[2]+pose[6]*oldq[3]+pose[7]*oldq[4]))
    return distance,math.deg(2*math.acos(cosine))
end

-- Motion sample scratch, refilled by every M.fling_action call and read only
-- within it, so a sample makes no table: the root body's pose, and each main
-- body's pose relative to it by the body's index in main_bodies (one table per
-- index, made up front for the largest profile), each as seven numbers.
-- History keeps copies (kept_pose, kept_limbs), made only when it starts or
-- restarts.
local root_pose,limb_poses,limb_capacity={0,0,0,0,0,0,0},{},0
local function limb_scratch(n)
    for i=limb_capacity+1,n do limb_poses[i]={0,0,0,0,0,0,0} end
    limb_capacity=math.max(limb_capacity,n)
end
do
    local most=0
    for _,p in pairs(profiles) do most=math.max(most,p.bodies) end
    limb_scratch(most)
end
-- Body id -> stamp of the last sample that had it: an id repeats within a
-- sample when it already has the current stamp. Nothing is emptied per sample
-- (an id an error left behind has an older stamp); the table is replaced once
-- it has gathered 1024 new ids (about 68 ragdolls of 15 bodies), which bounds
-- it below 2048 entries. Ragdolls sampled in turn reuse their ids.
local limb_seen,seen_ids,sample_stamp={},0,0

-- The root's pose into scratch; false when it is not rigid.
local function sample_root(matrix)
    local px,py,pz,qx,qy,qz,qw=rigid_pose(matrix)
    if not px then return false end
    local r=root_pose
    r[1],r[2],r[3],r[4],r[5],r[6],r[7]=px,py,pz,qx,qy,qz,qw
    return true
end

-- A body's pose relative to the root's, written into pose; false when the
-- body's pose is not rigid. Inverse root rotation applied to the displacement,
-- and conjugate(root) multiplied by body rotation. A coherent whole-corpse
-- turn is not flapping.
local function relative_pose(matrix,pose)
    local bx,by,bz,qx,qy,qz,qw=rigid_pose(matrix)
    if not bx then return false end
    local r=root_pose
    local x,y,z,w=-r[4],-r[5],-r[6],r[7]
    local dx,dy,dz=bx-r[1],by-r[2],bz-r[3]
    local tx,ty,tz=2*(y*dz-z*dy),2*(z*dx-x*dz),2*(x*dy-y*dx)
    pose[1],pose[2],pose[3],pose[4],pose[5],pose[6],pose[7]=
        dx+w*tx+y*tz-z*ty,dy+w*ty+z*tx-x*tz,dz+w*tz+x*ty-y*tx,
        w*qx+x*qw+y*qz-z*qy,w*qy-x*qz+y*qw+z*qx,w*qz+x*qy-y*qx+z*qw,w*qw-x*qx-y*qy-z*qz
    return true
end

-- Every main body's relative pose into scratch, in main_bodies order. Returns
-- how many bodies it sampled, or nil when a pose is not rigid, a body id
-- repeats or the root is not among them.
local function sample_limbs(bodies,root_id)
    -- ipairs visits at most #bodies entries.
    if #bodies>limb_capacity then limb_scratch(#bodies) end
    if seen_ids>=1024 then limb_seen,seen_ids={},0 end
    sample_stamp=sample_stamp+1
    local seen,stamp,sampled=limb_seen,sample_stamp,0
    for i,body in ipairs(bodies) do
        local id=body.id
        local mark=seen[id]
        if mark==stamp or not relative_pose(body.pose,limb_poses[i]) then return nil end
        if mark==nil then seen_ids=seen_ids+1 end
        seen[id]=stamp;sampled=i
    end
    if seen[root_id]~=stamp then return nil end
    return sampled
end

-- History's own copies of a scratch pose (position, rotation) and of each
-- body's relative pose by body id: history never holds a scratch table.
local function kept_pose(pose)
    return {pose[1],pose[2],pose[3]},{pose[4],pose[5],pose[6],pose[7]}
end
local function kept_limbs(bodies,sampled)
    local limbs={}
    for i=1,sampled do
        local position,rotation=kept_pose(limb_poses[i])
        limbs[bodies[i].id]={position=position,rotation=rotation}
    end
    return limbs
end

-- An armed sample's limbs: a main body other than the root that stays more
-- than 0.5 m or 15 degrees from its kept relative pose for at least 100 ms.
-- Returns its id, distance and degrees; nil when there is none; false when
-- history lacks one of the bodies.
local function limb_excursion(bodies,root_id,previous,now)
    local excursions=previous.excursions or {}
    previous.excursions=excursions
    for i,body in ipairs(bodies) do
        local id=body.id
        local old=previous.limbs[id]
        if not old then return false end
        local ld,la=separation(limb_poses[i],old.position,old.rotation)
        if id~=root_id and (ld>.5 or la>15) then
            local started=excursions[id]
            if started and now-started>=.1 then return id,ld,la end
            excursions[id]=started or now
        else excursions[id]=nil end
    end
    return nil
end

-- Client-side containment of motion restarting after a fixed corpse has had
-- time to settle. History contains numeric identities and copied poses only.
-- A fixed flag alone is insufficient: the recording includes normal final
-- corrections after that transition, before the root becomes stationary.
function M.fling_action(unit,state,now)
    state.fling_history=state.fling_history or {}
    local history=state.fling_history
    local key=unit.unit
    local root=unit.root_body
    local profile=profiles[unit.resource]
    if not settled(unit) or unit.corpse or unit.owner~=false
        or unit.active~=true or unit.update_enabled~=true then
        if key then history[key]=nil end
        return nil
    end
    -- Tripod settings intentionally disable every main actor on landing.
    -- Once this completed fixed state persists, finish through the same native
    -- stop/owner route. Never read disabled Havok bodies or resurrect collision.
    if profile.finish_disabled and unit.main_enabled==0 then
        local previous=history[key]
        if not previous or not previous.disabled or previous.entity~=unit.id
            or previous.resource~=unit.resource or previous.members~=unit.main_signature
            or now<=previous.last or now-previous.last>1 then
            history[key]={disabled=true,entity=unit.id,resource=unit.resource,
                members=unit.main_signature,since=now,last=now,samples=1}
        else
            previous.last=now;previous.samples=previous.samples+1
            if previous.samples>=3 and now-previous.since>=1 then
                return {distance=0,degrees=0,actor=unit.root_id,cause='landed_disabled'}
            end
        end
        return nil
    end
    if not root or not sample_root(root.pose) then history[key]=nil;return nil end
    local bodies=unit.main_bodies
    if not bodies or #bodies~=unit.main_enabled then history[key]=nil;return nil end
    local sampled=sample_limbs(bodies,root.id)
    if not sampled then history[key]=nil;return nil end
    local previous=history[key]
    if not previous or previous.entity~=unit.id or previous.resource~=unit.resource
        or previous.actor~=root.id or previous.members~=unit.main_signature or previous.enabled~=unit.main_enabled
        or now<=previous.last or now-previous.last>1 then
        local position,rotation=kept_pose(root_pose)
        history[key]={entity=unit.id,resource=unit.resource,actor=root.id,members=unit.main_signature,
            enabled=unit.main_enabled,position=position,rotation=rotation,limbs=kept_limbs(bodies,sampled),
            since=now,last=now,samples=1,armed=false}
        return nil
    end
    previous.last=now;previous.samples=previous.samples+1
    local distance,degrees=separation(root_pose,previous.position,previous.rotation)
    if previous.armed then
        -- Experimental containment thresholds, not engine-defined limits.
        if distance>.75 or degrees>20 then
            return {distance=distance,degrees=degrees,actor=root.id,
                cause=distance>.75 and 'translation' or 'rotation'}
        end
        local actor,ld,la=limb_excursion(bodies,root.id,previous,now)
        if actor==false then history[key]=nil;return nil end
        if actor then
            return {distance=distance,degrees=degrees,actor=actor,limb_distance=ld,limb_degrees=la,
                cause=ld>.5 and 'limb_translation' or 'limb_rotation'}
        end
    elseif distance>.25 or degrees>10 then
        previous.position,previous.rotation=kept_pose(root_pose);previous.limbs=kept_limbs(bodies,sampled)
        previous.since=now;previous.samples=1
    elseif previous.samples>=3 and now-previous.since>=1 then
        previous.armed=true;state.fling_armed=(state.fling_armed or 0)+1
    end
    return nil
end

-- Module-relative addresses (a base plus a constant) are made once per pair of
-- module bases, which the loader passes in unchanged every poll, instead of as
-- new pointer objects every poll.
local based_game,based_exe,mode_slot,world_slots,manager_slots=nil,nil,nil,{},{}
local function rebase(game,exe)
    if rawequal(game,based_game) and rawequal(exe,based_exe) then return end
    based_game,based_exe,mode_slot=game,exe,game+0x2ce1850
    manager_slots[false],manager_slots[true]=game+0x2ce1af8,game+0x2ce1ad8
    for index=0,3 do world_slots[index]=exe+0x2861d88+176*index end
end
-- The getter's slot object is reused only while the vtable pointer read this
-- poll has the same value, so the address read is always this poll's.
local getter_vtable,getter_slot
local function checked_world(api,exe,index,read,state)
    local reference=read(world_slots[index] or exe+0x2861d88+176*index,8)
    if reference==ZERO8 then return nil end
    local world=assert(api.pointer(reference),'Physics world unavailable')
    local vt=assert(api.pointer(read(world,8)),'Physics vtable unavailable')
    if vt~=getter_vtable then getter_vtable,getter_slot=vt,vt+136 end
    local getter=assert(api.pointer(read(getter_slot,8)),'Physics getter unavailable')
    local offset=api.distance(getter,exe)
    if offset~=0xd658d0 then
        state.getter_failures=(state.getter_failures or 0)+1
        state.last_getter_failure=string.format(
            'Body getter changed: world_index=%d world=%.0f vtable=%.0f actual=%.0f expected=%.0f offset=%.0f',
            index,api.address(world),api.address(vt),api.address(getter),api.address(exe+0xd658d0),offset)
        error(state.last_getter_failure)
    end
    state.getter_checks=(state.getter_checks or 0)+1
    return world
end

-- M.snapshot's helpers are made once, not as new closures every poll.
-- begin_snapshot points them at the poll's api, state and exe and empties their
-- tables (keeping emptied ones for reuse), so nothing copied or decoded in one
-- poll is used in another: the same lifetime as when they were made per poll.
local read,fetch,cached,pointer,world_for,pool_for,guard,begin_snapshot,snapshot_totals
local body_arrays={}
do
    local api,state,exe,used,calls
    -- pool_tables keeps one table per pool index across polls so a poll
    -- refills it instead of making a new one; pools says which were filled in
    -- this poll, and only those are used.
    local cache,worlds,pools,pool_tables,spare={},{},{},{},{}
    function begin_snapshot(a,s,e)
        api,state,exe,used,calls=a,s,e,0,0
        for key,sizes in pairs(cache) do
            for size in pairs(sizes) do sizes[size]=nil end
            spare[#spare+1]=sizes;cache[key]=nil
        end
        for index in pairs(worlds) do worlds[index]=nil end
        for index in pairs(body_arrays) do body_arrays[index]=nil end
        for index in pairs(pools) do pools[index]=nil end
    end
    function snapshot_totals() return used,calls end
    function read(address,size)
        assert(size>0 and size<=32768,'Read size outside bounds')
        used=used+size;calls=calls+1
        assert(used<=4*1024*1024 and calls<=18000,'Snapshot budget exceeded')
        local b=assert(api.read(address,size),'Data unavailable');assert(#b==size,'Short read');return b
    end
    -- Like read, but through the scratch view while it stays paired with
    -- api.read: the bytes are then valid only until the next view and no Lua
    -- string is made. Counted against the same snapshot budget.
    function fetch(address,size)
        if not viewable(api) then return read(address,size) end
        assert(size>0 and size<=32768,'Read size outside bounds')
        used=used+size;calls=calls+1
        assert(used<=4*1024*1024 and calls<=18000,'Snapshot budget exceeded')
        return assert(api.view(address,size),'Data unavailable')
    end
    function cached(address,size,optional)
        local key=api.address(address)
        local sizes=cache[key]
        if not sizes then sizes=table.remove(spare) or {};cache[key]=sizes end
        if sizes[size]==nil then
            if optional then
                local ok,bytes=pcall(read,address,size);sizes[size]=ok and bytes or false
            else sizes[size]=read(address,size) end
        end
        return sizes[size] or nil
    end
    function pointer(b,o) return assert(api.pointer(b,o),'Pointer unavailable') end
    -- These decoded values share the existing copied-byte cache's lifetime:
    -- one snapshot/poll only. Actor/body identities and mutation guards remain
    -- fresh. No resolved address is retained in state or across polls.
    function world_for(index)
        local world=worlds[index]
        if world~=nil then
            if world then state.getter_checks=(state.getter_checks or 0)+1 end
            return world or nil
        end
        world=checked_world(api,exe,index,cached,state)
        worlds[index]=world or false
        state.world_metadata_decodes=(state.world_metadata_decodes or 0)+1
        return world
    end
    function pool_for(index)
        local pool=pools[index]
        if not pool then
            local b=cached(exe+0x2411200+64*index,56)
            local layout=u32(b,28)
            pool=pool_tables[index] or {};pool_tables[index]=pool
            pool.base,pool.count,pool.mask,pool.generation=pointer(b),u32(b,36),u32(b,40),u32(b,52)
            pool.stride,pool.identity_offset,pool.data_offset=
                bit.band(layout,65535),bit.band(bit.rshift(layout,16),255),bit.rshift(layout,24)
            pools[index]=pool
            state.pool_metadata_decodes=(state.pool_metadata_decodes or 0)+1
        end
        return pool
    end
    -- With view (a capture() made just before, no other view in between) the
    -- guarded bytes are copied out of it at offset instead of read again.
    function guard(list,address,size,view,offset)
        local b=view and ffi.string(view+offset,size) or read(address,size);list[#list+1]={address=address,bytes=b};return b
    end
end
-- Like guard, but fills entry i in place (a new entry the first time): the
-- manager globals' list is kept across polls, so its two entries cost no table.
local function keep(list,i,address,size)
    local b,entry=read(address,size),list[i]
    if entry then entry.address,entry.bytes=address,b else list[i]={address=address,bytes=b} end
    return b
end
-- With consume, units are handed over one by one and never collected, so the
-- returned and selected lists stay empty and the globals' list is reused (its
-- grouping plan dropped, so every poll groups its guards afresh). Without
-- consume, the caller keeps the units: fresh lists, as before.
local EMPTY,RAGDOLL_FIRST,CORPSE_FIRST,manager_globals={},{false,true},{true,false},{[false]={},[true]={}}
local function no_units(consume) if consume then return EMPTY end;return {} end
local function manager_lists(corpse,consume)
    if not consume then return {},{} end
    local globals=manager_globals[corpse];globals.compiled=nil;return globals,EMPTY
end

-- M.snapshot in named steps. scan_poll points them at the poll (its api,
-- state, exe, consume and budget, then the mission mode it reads) and
-- scan_manager at the manager being scanned. Every value is set in the same
-- poll before a step reads it; nothing is used by a later poll.
local scan_poll,scan_steps
do
    local api,state,exe,consume,budget,preflight_due
    local mode_reference,mode,mode_bytes
    local corpse,manager_name,manager,active,entities,pointers,runtime,sync,sync_number,globals,selected
    -- The entity address of the entry being visited (the listing's number),
    -- recorded in its unit for the corpse re-check backoff.
    local visit_address
    -- sync_counts[k] is the count of entry sync_first+k, copied this poll
    -- after the last inspection; sync_first is nil when there is none.
    local manager_count,sync_first,sync_last,sync_counts=0,nil,nil,{}
    local SYNC_WINDOW,CLOCK_EVERY=16,8

    -- The unit's record and identity guards: its entity header, the mission
    -- mode and its manager entry.
    local function new_unit(index,entity,e)
        local u={resource=e:sub(1,8),id=u32(e,8),unit=u32(e,12),corpse=corpse,address=visit_address,
            owner=bit.band(u32(e,20),1)~=0,active=index<active,manager=manager,index=index,
            guards={},main={},main_bodies={},main_pose_guards={},registered={},actors={},
            main_enabled=0,main_static=0,main_disabled=0,main_dynamic_allowed=0}
        u.guards[#u.guards+1]={address=entity,bytes=e}
        u.guards[#u.guards+1]={address=mode_slot,bytes=mode_reference}
        u.guards[#u.guards+1]={address=mode+8,bytes=mode_bytes:sub(9,12)}
        u.guards[#u.guards+1]={address=entities+index*8,bytes=pointers:sub(index*8+1,index*8+8)}
        return u
    end
    -- A ragdoll's main-body members from its runtime record r, each guarded.
    local function main_members(u,profile,r)
        local b=read(r,profile.bodies*712)
        local members={}
        for i=0,profile.bodies-1 do
            local id=u32(b,i*712)
            assert(id~=0xffffffff and not u.main[id],'Invalid main actor membership')
            u.main[id]=profile.main[i+1];u.registered[id]=true
            members[#members+1]=tostring(id);if i==0 then u.root_id=id end
            u.guards[#u.guards+1]={address=r+i*712,bytes=b:sub(i*712+1,i*712+8)}
            local n=u32(b,i*712+12);assert(n<=9,'Sub-actor bounds changed')
            for j=0,n-1 do u.registered[u32(b,i*712+28+j*76)]=true end
        end
        u.main_signature=table.concat(members,':')
    end
    -- A ragdoll's runtime record and sync counts; false when they do not match
    -- the profile.
    local function ragdoll_runtime(u,profile,quick)
        local r=runtime+u.index*11192
        local meta=guard(u.guards,r+11160,32)
        if u32(meta,0)~=profile.bodies or meta:byte(13)>1 or meta:byte(14)~=0 or meta:sub(17,24)~=ZERO8 then return false end
        u.update_enabled=meta:byte(13)==1;u.update_address=r+11172
        local s=sync+u.index*432
        -- The eligibility check read the word at s for this entity this poll,
        -- and no native call runs in between: its bytes become the guard's
        -- instead of a second read. The guard is validated with the others,
        -- as before. The rotation count (+184) and flag (+428) lie within 245
        -- bytes: one copy, each still with its own guard.
        local pc=string.char(quick%256,floor(quick/256)%256,floor(quick/65536)%256,floor(quick/16777216))
        local sv=capture(api,s+184,245);u.guards[#u.guards+1]={address=s,bytes=pc}
        local rc,flag=guard(u.guards,s+184,4,sv,0),guard(u.guards,s+428,1,sv,244)
        if u32(pc)~=profile.bodies or u32(rc)~=profile.bodies or flag:byte()~=0 then return false end
        main_members(u,profile,r)
        return true
    end
    -- The unit object: generation, identity and skeleton size, then the
    -- skeleton's node matrices. Returns the unit's slot and nodes.
    local function skeleton(u,profile)
        local registry=pointer(guard(u.guards,exe+0x1ab76f8,8))
        local uh=cached(registry,0xa8);local slot_index=u.unit%0x400000
        assert(slot_index<u32(uh,0x98),'Unit index changed')
        local gen_address=pointer(uh,0xa0)+slot_index
        assert(guard(u.guards,gen_address,1)==string.char(math.floor(u.unit/0x400000)),'Unit generation changed')
        local slot=pointer(uh,0x88)+slot_index*8
        -- The unit object's identity (+8), skeleton size (+0x70) and node
        -- pointer (+0x88) words lie within 136 bytes: one copy. Each keeps its
        -- own guard, checked in the same order.
        local object=pointer(guard(u.guards,slot,8));local v=capture(api,object+8,0x88)
        assert(u32(guard(u.guards,object+8,4,v,0))==u.unit,'Unit identity changed')
        local node_count=u32(guard(u.guards,object+0x70,4,v,0x68))
        assert(node_count==profile.nodes,'Skeleton changed')
        local node_pointer=pointer(guard(u.guards,object+0x88,8,v,0x80))
        return slot_index,read(node_pointer,node_count*64)
    end
    -- The unit's actor handles, inline or behind a pointer; nil for none.
    local function actor_handles(u,slot_index)
        local list=pointer(guard(u.guards,exe+0x286d030,8))+slot_index*24
        local ah=guard(u.guards,list,24);local flags=u32(ah,4)
        assert(bit.band(flags,0x40000000)~=0 and bit.band(u32(ah),0x3fffffff)==u.unit,'Actor list identity changed')
        local n=bit.band(flags,127)
        if n==0 then return nil end
        local actor_pointer=bit.band(flags,0x80000000)~=0 and list+8 or pointer(ah,8)
        return guard(u.guards,actor_pointer,n*4),n
    end
    -- The pool and index of the row actor_row decoded last (this actor's).
    local row_pool,row_ai
    -- An actor's pool row: its identity word and 40 data bytes, each as copied
    -- bytes and a zero-based offset into them. Rows copied together are
    -- decoded in place: a row's own bytes and addresses are made only when a
    -- guard or a command needs them.
    local function actor_row(id)
        local pool=pool_for(bit.band(bit.rshift(id,28),3)+10*bit.rshift(id,30))
        local ai=bit.band(id,pool.mask)
        assert(ai<pool.count and bit.band(id,pool.generation)~=0,'Expired actor')
        local stride=pool.stride
        local identity_offset,data_offset=pool.identity_offset,pool.data_offset
        row_pool,row_ai=pool,ai
        if stride<=256 and identity_offset+4<=stride and data_offset+40<=stride then
            local first=ai-ai%16
            local size=math.min(16,pool.count-first)*stride
            -- Actor rows may be copied together. Havok bodies must remain
            -- individual: disabled body slots are off-limits.
            local rows=cached(pool.base+first*stride,size,true)
            if rows then
                local base=(ai-first)*stride
                return rows,base+identity_offset,rows,base+data_offset
            end
        end
        local entry=pool.base+ai*stride
        return read(entry+identity_offset,4),0,read(entry+data_offset,40),0
    end
    -- The current row's identity and data addresses, made only when needed.
    local function row_addresses()
        local pool=row_pool
        local entry=pool.base+row_ai*pool.stride
        return entry+pool.identity_offset,entry+pool.data_offset
    end
    -- n bytes at zero-based offset o of copied bytes b, as their own string.
    local function slice(b,o,n)
        if o==0 and #b==n then return b end
        return b:sub(o+1,o+n)
    end
    -- An enabled actor's physics body, copied whole and checked against the
    -- actor. Returns its address, bytes (a scratch view when the adapter has
    -- one: valid only until the next view), motion word and collision filter.
    local function actor_body(u,id,ab,ao)
        local world_index=bit.rshift(id,30)
        local world=assert(world_for(world_index),'Physics world unavailable')
        local bi=bit.band(u32(ab,ao+20),0xffffff);assert(bi<262144,'Body index changed')
        local base=body_arrays[world_index]
        if not base then base=pointer(cached(world+24,8));body_arrays[world_index]=base end
        local body_address=base+160*bi
        local body=fetch(body_address,160)
        local word=type(body)=='string' and u32 or view_u32
        assert(word(body,144)==id and word(body,148)==u.unit,'Physics body identity changed')
        return body_address,body,word(body,64),bit.band(word(body,108),127)
    end
    -- The body's 160 bytes as a string: kept for guards, commands and poses.
    local function copied(body)
        if type(body)=='string' then return body end
        return ffi.string(body,160)
    end
    -- Whether the body's first 64 bytes equal the node matrix at offset.
    local function matrix_equal(nodes,offset,body)
        if type(body)=='string' then return ranges_equal(nodes,offset,body,0,64) end
        if offset<0 or offset+64>#nodes then return false end
        for i=0,63 do if byte(nodes,offset+i+1)~=body[i] then return false end end
        return true
    end
    -- An enabled main body: counted, its motion and identity guarded, its pose
    -- guarded and (ragdolls only) decoded.
    local function count_main_body(u,profile,id,name,body_address,body,motion)
        u.main_enabled=u.main_enabled+1
        u.main_static=u.main_static+(motion==0 and 1 or 0)
        if u.corpse and motion~=0 and profile.corpse_dynamic_main and profile.corpse_dynamic_main[name] then
            u.main_dynamic_allowed=u.main_dynamic_allowed+1
        end
        u.guards[#u.guards+1]={address=body_address+64,bytes=body:sub(65,68)}
        u.guards[#u.guards+1]={address=body_address+144,bytes=body:sub(145,152)}
        local pose_guard={address=body_address,bytes=body:sub(1,64)}
        u.main_pose_guards[#u.main_pose_guards+1]=pose_guard
        -- Corpse-phase planning uses primary identity/motion, not decoded
        -- primary transforms. Keep every guard.
        local main_body={id=id,pose=not u.corpse and floats(body,0,16) or nil,guards={pose_guard}}
        u.main_bodies[#u.main_bodies+1]=main_body
        -- The root's only guard is its pose guard, already in main_pose_guards.
        if id==u.root_id then u.root_body=main_body;u.root_in_pose_guards=true end
    end
    -- Whether M.plan could act on an auxiliary actor: the same authored
    -- mapping, registration, claw and static-body tests it applies. A static
    -- body whose bytes equal its node is already aligned (M.plan compares the
    -- identical table and skips it), so it needs no record.
    local function actionable(profile,ab,ao,registered,motion,body,nodes)
        local name,node=u32(ab,ao+24),u32(ab,ao+28)
        local claw=profile.name=='Impaler' and claws[name]
        return profile.actors[name] and node<#nodes/64 and not registered
            and profile.actors[name]==u32(ab,ao+32)
            and (claw or (motion==0 and not matrix_equal(nodes,node*64,body)))
    end
    -- An actor record's node pose (decoded once per node and unit) and pose.
    -- Copied matrices are immutable during the poll. Exact byte equality proves
    -- no pose repair is due; all nonidentical matrices retain the rigid checks.
    local function poses(nodes,node_matrices,node,body)
        local node_pose=node_matrices[node]
        if not node_pose then
            node_pose=floats(nodes,node*64,16);node_matrices[node]=node_pose
        end
        return node_pose,ranges_equal(nodes,node*64,body,0,64) and node_pose or floats(body,0,16)
    end
    -- One actor of the unit: its row; a main actor's guards and counts; an
    -- enabled actor's body; a record for an auxiliary actor M.plan could act on.
    -- A main actor's row guards: its data, then its identity.
    local function main_row(u,ib,io,ab,ao)
        local identity_address,address=row_addresses()
        u.guards[#u.guards+1]={address=address,bytes=slice(ab,ao,40)}
        u.guards[#u.guards+1]={address=identity_address,bytes=slice(ib,io,4)}
    end
    local function inspect_actor(u,profile,id,main_names,nodes,node_matrices)
        local ib,io,ab,ao=actor_row(id)
        assert(u32(ib,io)==id,'Actor generation changed')
        assert(u32(ab,ao+12)==u.unit,'Actor owner changed')
        local name,node=u32(ab,ao+24),u32(ab,ao+28)
        local enabled=bit.band(u32(ab,ao+16),1)~=0
        local is_main=u.corpse and profile.main_names[name] or u.main[id]
        if is_main then
            assert((u.corpse or name==u.main[id]) and not main_names[name], 'Main actor names changed')
            main_names[name]=true
            main_row(u,ib,io,ab,ao)
            if not enabled and profile.disabled_main[name] then u.main_disabled=u.main_disabled+1 end
        end
        -- Disabled tentacles can retain differently tagged body IDs. They are
        -- never repair targets. Skip their bodies entirely; undeclared disabled
        -- primaries still block settlement.
        if not enabled then return end
        detail(api,'bodies')
        local body_address,body,motion,filter=actor_body(u,id,ab,ao)
        -- Main bodies keep their bytes as guards: copy them out of the view
        -- before anything else takes one.
        if is_main then body=copied(body);count_main_body(u,profile,id,name,body_address,body,motion) end
        local registered=u.registered[id] or is_main or filter==52 or filter==48 or filter==83
        if not actionable(profile,ab,ao,registered,motion,body,nodes) then return end
        body=copied(body)
        local node_pose,pose=poses(nodes,node_matrices,node,body)
        -- The copied body block is kept whole; command_guards slices the same
        -- bytes only if a command needs them. Fresh identity and motion are
        -- validated again at command dispatch; aligned actors need no extra
        -- read pass.
        local identity_address,address=row_addresses()
        local a={id=id,name=name,node=node,node_hash=u32(ab,ao+32),enabled=enabled,motion=motion,
            registered=registered,pose=pose,node_pose=node_pose,
            guard_source={identity_address,slice(ib,io,4),address,slice(ab,ao,40),body_address,body}}
        a.stable=true;u.actors[#u.actors+1]=a
    end
    -- The unit's actors, in handle order; invalid handles are skipped.
    local function inspect_actors(u,profile,handles,n,nodes)
        local main_names,node_matrices={},{}
        for i=0,n-1 do
            detail(api,'actors')
            local id=u32(handles,i*4)
            if id~=0xffffffff then inspect_actor(u,profile,id,main_names,nodes,node_matrices) end
        end
    end
    -- One listed, eligible unit, read and checked in full. The caller runs it
    -- in pcall: a failed read or check skips the unit. nil when it does not
    -- qualify this poll.
    local function inspect(index,entity,e,profile,quick)
        local u=new_unit(index,entity,e)
        if not corpse and not ragdoll_runtime(u,profile,quick) then return nil end
        u.settled=true
        detail(api,'skeleton')
        local slot_index,nodes=skeleton(u,profile)
        detail(api,'actors')
        local handles,n=actor_handles(u,slot_index)
        if not handles then return nil end
        inspect_actors(u,profile,handles,n,nodes)
        if not same(api,u.guards) then return nil end
        return u
    end
    -- A unit inspected in full goes to consume once the manager's globals still
    -- hold, or without consume into the manager's selected list.
    local function hand_over(unit)
        if not consume then selected[#selected+1]=unit;return end
        if same(api,globals) then
            for _,g in ipairs(globals) do unit.guards[#unit.guards+1]=g end
            -- inspect verified the unit's own guards and the globals were just
            -- verified, with no native call since: consume need not compare
            -- them again before its first native call (verified is cleared by
            -- the first one).
            unit.verified=true
            consume(unit)
        else
            if state.fling_history then state.fling_history[unit.unit]=nil end
            state.skipped=(state.skipped or 0)+1
        end
    end
    -- Inspects a listed, eligible unit and records the outcome.
    -- The poll's first inspection sets its 1 ms deadline (one clock read) and
    -- runs the read-only preflight: the exact getter path the corpse reader
    -- uses, checked before any unit's bodies. World 2 hosts the captured enemy
    -- actors; absence during loading is normal.
    local function first_inspection()
        if budget and not budget.deadline and api.clock then budget.deadline=api.clock()+M.budget_seconds end
        if not preflight_due then return end
        preflight_due=false
        state.preflight_getter='checking'
        state.preflight_getter=world_for(2) and 'verified' or 'waiting_for_world'
    end
    local function inspect_listed(index,entity,e,profile,quick)
        first_inspection()
        if budget then budget.inspected=budget.inspected+1 end
        phase(api,'snapshot')
        detail(api,'metadata')
        local profile_start=api.profiler and api.clock()
        local profile_reads=api.profiler and api.profiler.reads
        local ok,unit=pcall(inspect,index,entity,e,profile,quick)
        -- The inspection took views and its commands may have changed the
        -- game: sync counts are copied afresh for the next listed entry.
        sync_first=nil
        if ok and unit then hand_over(unit)
        elseif not ok then state.skipped=(state.skipped or 0)+1;state.last_skip=tostring(unit) end
        if (not ok or not unit) and state.fling_history then state.fling_history[u32(e,12)]=nil end
        if api.profiler then api.profiler.unit(profile.name,profile_start,profile_reads,ok and unit or nil) end
    end
    -- One manager entry: its header and, for a listed resource, the cheap
    -- lifecycle check before counting against the expensive-unit limit or
    -- reading any skeleton. True once 32 units are selected.
    -- The ragdoll's sync count at index, or nil when unreadable. One view
    -- copies the counts of up to SYNC_WINDOW entries from index on (432-byte
    -- stride, only as many as this poll may still scan) into sync_counts, so
    -- the following listed entries cost no read of their own. Without the
    -- paired view, or if it fails, each count is read on its own as before.
    local function sync_count(index)
        if sync_first and index>=sync_first and index<=sync_last then return sync_counts[index-sync_first] end
        local n=math.min(manager_count-index,SYNC_WINDOW,budget and M.max_entities-budget.scanned+1 or SYNC_WINDOW)
        local view=n>1 and viewable(api) and api.view(sync_number+index*432,(n-1)*432+4)
        if not view then
            local b=api.read(sync_number+index*432,4)
            return b and #b==4 and u32(b) or nil
        end
        for k=0,n-1 do sync_counts[k]=view_u32(view,k*432) end
        sync_first,sync_last=index,index+n-1
        return sync_counts[0]
    end
    -- The entry's header (24 bytes) through the view when there is one: an
    -- unlisted resource then makes no string. Returns the header's bytes (a
    -- string, made only for a listed resource) and its profile, or nil.
    local function header(entity)
        if not viewable(api) then
            local e=api.read(entity,24)
            return e,e and profiles[e:sub(1,8)]
        end
        local v=api.view(entity,24)
        local keys=v and resource_words[view_u32(v,0)]
        local key=keys and keys[view_u32(v,4)]
        if not key then return nil end
        return ffi.string(v,24),profiles[key]
    end
    -- The listing: which entries of a manager hold a listed resource, kept
    -- across polls in state.listings so an idle poll reads no entry header.
    -- It is a hint for where to look, never data to act on: an entry it names
    -- has its header read afresh before inspection, and everything a command
    -- depends on is read and guarded in that poll, as before. Entities are
    -- classified by address (the header's resource words; the unit word is
    -- kept for clearing motion history). The whole pointer array is compared
    -- with the last poll's (an interned string: one comparison, no
    -- allocation); only a changed array is walked, and only addresses not
    -- seen before cost a header view. An entity can be freed and another
    -- allocated at the same address between two polls, leaving the array
    -- unchanged: a rolling verification re-reads ceil(count/16) headers of
    -- the manager scanned first in each poll (the managers alternate), so
    -- every entry is checked again within 32 polls (1.5-2 s).
    local SWEEP_POLLS=16
    local listing
    local function listing_of(is_corpse)
        local all=state.listings
        if not all then all={};state.listings=all end
        local l=all[is_corpse]
        if not l then l={known={},units={},stamps={},listed={},n=0,size=0,stamp=0,sweep=0};all[is_corpse]=l end
        return l
    end
    -- The entity address at entry index of the copied pointer array, as a
    -- number (no pointer object); 0 when it is not a user address.
    local function address_at(index)
        local b1,b2,b3,b4,b5,b6,b7,b8=byte(pointers,index*8+1,index*8+8)
        local value=b1+b2*256+b3*65536+b4*16777216+(b5+b6*256+b7*65536+b8*16777216)*4294967296
        if value<0x10000 or value>=0x800000000000 then return 0 end
        return value
    end
    -- The resource key (false when not listed) and unit word of the entity
    -- at address, from a fresh header; nil when the header is unreadable.
    local function classify(address)
        if viewable(api) then
            local v=api.view(address,24)
            if not v then return nil end
            local keys=resource_words[view_u32(v,0)]
            local key=keys and keys[view_u32(v,4)]
            if not key then return false end
            return key,view_u32(v,12)
        end
        local e=api.read(address,24)
        if not e or #e~=24 then return nil end
        local key=e:sub(1,8)
        if not profiles[key] then return false end
        return key,u32(e,12)
    end
    -- Forgets addresses the array no longer holds, once they outnumber it.
    local function prune(l,count)
        if l.size<=2*count+64 then return end
        local known,units,stamps,stamp,size=l.known,l.units,l.stamps,l.stamp,0
        for address,seen in pairs(stamps) do
            if seen~=stamp then stamps[address]=nil;known[address]=nil;units[address]=nil else size=size+1 end
        end
        l.size=size
    end
    -- Rebuilds the listed entry indices from this poll's pointer array. At
    -- most M.max_entities new addresses are classified per poll; the rest
    -- wait for the next (the listing stays incomplete and the poll counts as
    -- yielded).
    -- The listing's key for a valid address, classifying it while the poll
    -- may still (left > 0). Returns the key (nil: not classified) and left.
    -- An unreadable header counts as unlisted: the rolling verification
    -- reads it again within 32 polls, and the array's next change reclassifies
    -- nothing it already knows.
    local function key_of(l,address,left)
        local key=l.known[address]
        if key==nil and left>0 then
            left=left-1
            local unit
            key,unit=classify(address)
            if key==nil then key=false;state.listing_unreadable=(state.listing_unreadable or 0)+1 end
            l.known[address],l.units[address]=key,unit
            state.listing_classified=(state.listing_classified or 0)+1
        end
        if l.stamps[address]==nil then l.size=l.size+1 end
        l.stamps[address]=l.stamp
        return key,left
    end
    local function relist(l,count)
        l.stamp=l.stamp+1
        local listed,n,left,complete=l.listed,0,M.max_entities,true
        for index=0,count-1 do
            local address=address_at(index)
            local key
            if address~=0 then key,left=key_of(l,address,left) else key=false end
            if key==nil then complete=false elseif key then n=n+1;listed[n]=index end
        end
        for i=n+1,l.n do listed[i]=nil end
        l.n,l.count,l.complete,l.pointers=n,count,complete,complete and pointers or nil
        prune(l,count)
        if not complete and budget then budget.yielded=true end
    end
    -- Re-reads a few known entries' headers (the rolling verification); a
    -- changed one is reclassified and the listing rebuilt.
    local function verify(l,count)
        local known,units=l.known,l.units
        for _=1,math.ceil(count/SWEEP_POLLS) do
            local index=l.sweep%count;l.sweep=index+1
            local address=address_at(index)
            local key=known[address]
            if key~=nil then
                local fresh,unit=classify(address)
                if fresh~=nil and (fresh~=key or fresh and units[address]~=unit) then
                    known[address],units[address],l.pointers=fresh,unit,nil
                    state.listing_changes=(state.listing_changes or 0)+1
                end
            end
        end
    end
    -- Whether the corpse at address waits for its next re-check: its unit's
    -- backoff record (consume keeps it) names this address and is not due.
    -- Records are kept only by M.apply's polls.
    local function backed_off(address)
        local checks=state.corpse_checks
        local record=checks and checks[listing.units[address]]
        return record~=nil and record.address==address and state.fling_scan<record.due
    end
    -- A listed entry: the cheap lifecycle check (ragdolls: the sync count),
    -- then a fresh header for an eligible one. A header that no longer
    -- matches the listing is skipped this poll and classified afresh by the
    -- next poll's rebuild.
    local function visit(index)
        local address=address_at(index)
        local key=listing.known[address]
        local profile=key and profiles[key]
        if not profile then return false end
        if corpse and backed_off(address) then
            state.corpse_rechecks_deferred=(state.corpse_rechecks_deferred or 0)+1
            return false
        end
        local quick=not corpse and sync_count(index)
        if corpse or quick==profile.bodies then
            local entity=api.pointer(pointers,index*8)
            local e,fresh=header(entity)
            visit_address=address
            if fresh==profile then inspect_listed(index,entity,e,profile,quick)
            else
                listing.known[address],listing.pointers=nil,nil
                state.listing_changes=(state.listing_changes or 0)+1
            end
        elseif state.fling_history then state.fling_history[listing.units[address]]=nil end
        phase(api,'discovery')
        return #selected>=32
    end
    -- The clock is a system call: it is read every CLOCK_EVERY scanned listed
    -- entries and after every inspection (about a hundred reads), not before
    -- every entry, and only once the poll's first inspection has set the
    -- deadline (inspect_listed): a poll that inspects nothing reads no clock.
    -- The 1 ms deadline stays soft.
    local function exhausted()
        if not budget then return nil end
        -- A deadline seen by the first manager also ends the second's scan.
        if budget.yielded or budget.scanned>=M.max_entities or budget.inspected>=M.max_units then return true end
        if budget.scanned==0 or not api.clock or not budget.deadline then return false end
        if budget.scanned%CLOCK_EVERY~=0 and budget.inspected==budget.clocked then return false end
        budget.clocked=budget.inspected
        return api.clock()>=budget.deadline
    end
    -- The first listed position whose entry index is at or after cursor
    -- (wrapping to the first), by bisection of the ascending listed indices.
    local function listed_from(cursor)
        local listed,low,high=listing.listed,1,listing.n
        while low<high do
            local middle=floor((low+high)/2)
            if listed[middle]<cursor then low=middle+1 else high=middle end
        end
        if listed[low]<cursor then return 1 end
        return low
    end
    -- The manager's listed entries from its rotating cursor (an entry index),
    -- within the poll's budget. Unlisted entries cost nothing.
    local function scan_entities(count)
        local n=listing.n
        if n==0 then return end
        local listed=listing.listed
        local first=listed_from((state.cursors[manager_name] or 0)%count)
        for step=0,n-1 do
            if exhausted() then budget.yielded=true;break end
            local index=listed[(first-1+step)%n+1]
            state.cursors[manager_name]=(index+1)%count
            if budget then budget.scanned=budget.scanned+1 end
            if visit(index) then break end
        end
    end
    -- The manager's slot: the bytes copied with the mode slot this poll
    -- (in_mission), or its own read without the paired view.
    local slot_bytes={}
    local function manager_slot()
        local b=slot_bytes[corpse]
        if not b then return keep(globals,1,manager_slots[corpse],8) end
        local entry=globals[1]
        if entry then entry.address,entry.bytes=manager_slots[corpse],b
        else globals[1]={address=manager_slots[corpse],bytes=b} end
        return b
    end
    -- The manager's header, read through its kept globals, with its bounds
    -- checked. Returns the header bytes and the entry count.
    local function manager_header()
        manager=pointer(manager_slot())
        local h=keep(globals,2,manager,88)
        local capacity,count=u32(h,corpse and 16 or 4),u32(h,corpse and 24 or 12)
        active=u32(h,corpse and 28 or 16)
        state[manager_name..'_count']=count
        assert(active<=count and count<=capacity and capacity<=8192 and count<=(corpse and 512 or 2048),'Manager bounds changed')
        if not corpse then assert(u32(h,20)<=active,'Owner partition changed') end
        return h,count
    end
    -- Without consume, the manager's selected units are returned with its
    -- globals once those still hold. With consume, each streamed unit was
    -- checked against them just before its commands; no pointers or unfinished
    -- writes are retained.
    local function collect(result)
        if consume then return end
        if not same(api,globals) then
            state.skipped=(state.skipped or 0)+1
            for _,u in ipairs(selected) do if state.fling_history then state.fling_history[u.unit]=nil end end
            return
        end
        for _,u in ipairs(selected) do
            for _,g in ipairs(globals) do u.guards[#u.guards+1]=g end
            result[#result+1]=u
        end
    end
    local function scan_manager(is_corpse,result,first)
        phase(api,'discovery')
        corpse,manager_name=is_corpse,is_corpse and 'corpse' or 'ragdoll'
        globals,selected=manager_lists(corpse,consume)
        local h,count=manager_header()
        manager_count,sync_first=count,nil
        listing=listing_of(corpse)
        if count>0 then
            entities,runtime,sync=pointer(h,corpse and 64 or 56),pointer(h,72),pointer(h,80)
            pointers=read(entities,count*8)
            if first then verify(listing,count) end
            if pointers~=listing.pointers then relist(listing,count) end
            -- Sync count reads take a number address: no pointer object per entry.
            if listing.n>0 and not corpse then sync_number=api.address(sync) end
            scan_entities(count)
        end
        collect(result)
    end
    -- The mode slot and both manager slots lie within 0x2b0 bytes of
    -- game.dll's data: one view copies all three. A slot is compared as two
    -- words with last poll's (slot_low/slot_high by slot key: 0 for the mode,
    -- false and true for the managers); an unchanged one keeps last poll's
    -- bytes, so no string is made for it. The manager slots are taken from
    -- the view only in a mission, before any other view.
    local SLOT_SPAN=0x2b0
    local slot_low,slot_high,slot_view={},{},nil
    local function slot_from(offset,key,kept)
        local low,high=view_u32(slot_view,offset),view_u32(slot_view,offset+4)
        if kept and slot_low[key]==low and slot_high[key]==high then return kept end
        slot_low[key],slot_high[key]=low,high
        return ffi.string(slot_view+offset,8)
    end
    local function read_mode_slot()
        slot_view=viewable(api) and api.view(mode_slot,SLOT_SPAN) or nil
        if not slot_view then slot_low[0]=nil;return api.read(mode_slot,8) end
        return slot_from(0,0,mode_reference)
    end
    local function read_manager_slots()
        if not slot_view then slot_bytes[false],slot_bytes[true]=nil,nil;return end
        slot_bytes[false]=slot_from(0x2a8,false,slot_bytes[false])
        slot_bytes[true]=slot_from(0x288,true,slot_bytes[true])
    end
    -- The mission mode. The recorded client mission had +8=1 and +0x40=2.
    -- Back on the ship, +8 became zero while +0x40 stayed 2. Do not use that
    -- second field as a mission selector; entity/profile/lifecycle guards
    -- remain mandatory.
    local function in_mission()
        mode_reference=read_mode_slot()
        mode=api.pointer(mode_reference)
        state.mission_flag=0;state.mode_field_40=0
        if not mode then return false end
        -- A read, not a view: the slot view stays valid for the managers.
        mode_bytes=read(mode,0x44)
        state.mission_flag=u32(mode_bytes,8);state.mode_field_40=u32(mode_bytes,0x40)
        if state.mission_flag==0 then return false end
        read_manager_slots()
        return true
    end
    -- The mission check, then both managers. Returns nil outside a mission.
    function scan_poll(a,s,e,c,b)
        api,state,exe,consume,budget=a,s,e,c,b
        if not in_mission() then state.preflight_getter='waiting_for_mission';return nil end
        -- The physics getter preflight runs before the poll's first
        -- inspection (inspect_listed): a poll that inspects nothing makes none
        -- of its 3 reads.
        preflight_due=true
        if state.preflight_getter=='waiting_for_mission' or state.preflight_getter==nil then
            state.preflight_getter='waiting_for_unit'
        end
        local result=no_units(consume)
        state.cursors=state.cursors or {}
        -- Alternate first ownership of the shared budget so neither manager can
        -- starve the other. Cursors are indices only; pointers are always reread.
        state.manager_turn=not state.manager_turn
        for i,is_corpse in ipairs(state.manager_turn and RAGDOLL_FIRST or CORPSE_FIRST) do scan_manager(is_corpse,result,i==1) end
        return result
    end
    scan_steps={scan_poll,in_mission,scan_manager,collect,manager_header,scan_entities,exhausted,visit,inspect_listed,first_inspection,key_of,backed_off,
        relist,verify,classify,prune,listed_from,read_mode_slot,read_manager_slots,slot_from,manager_slot}
end

function M.snapshot(api,game,exe,state,consume,budget)
    phase(api,'discovery')
    begin_snapshot(api,state,exe);rebase(game,exe)
    local result=scan_poll(api,state,exe,consume,budget)
    if not result then return no_units(consume),'waiting_for_mission' end
    state.read_bytes,state.read_calls=snapshot_totals()
    return result,'ready'
end
-- Machine code: before the split, nothing outside the per-unit inspection
-- compiled in the game's LuaJIT (begin_snapshot's pairs() and the creation of
-- the inspection closure aborted every trace through M.snapshot), so these
-- steps stay interpreted. The inspection steps and hand_over compile as the
-- closure's body did.
if jit and jit.off then
    jit.off(M.snapshot)
    for _,fn in ipairs(scan_steps) do jit.off(fn) end
end
scan_steps=nil

-- A settled remote ragdoll still receiving network corrections nudges its
-- skeleton a few centimetres every tenth of a second, and each nudge
-- requalified the same auxiliary actor: one recorded Acid Charger received 389
-- realignments in 4.3 s. The first correction stays immediate. A small repeat
-- on the same actor, unit and entity waits out the rest of the cooldown; a
-- large repeat still applies at once.
M.repose_cooldown=1
M.repose_bypass_m=.1
M.repose_bypass_degrees=5
local function defer_repeats(state,u,actions,now)
    local recent,kept=state.reposed,nil
    for i,action in ipairs(actions) do
        local last=action.kind=='pose' and recent[action.actor.id]
        local hold=last and last.unit==u.unit and last.entity==u.id and now>=last.at
            and now-last.at<M.repose_cooldown and action.gap<=M.repose_bypass_m
            and (action.degrees or 0)<=M.repose_bypass_degrees
        if hold then
            state.reposes_deferred=(state.reposes_deferred or 0)+1
            if not kept then kept={};for j=1,i-1 do kept[j]=actions[j] end end
        elseif kept then kept[#kept+1]=action end
    end
    return kept or actions
end

-- Empties a table in place (or makes one), so a reset costs no new table.
local function emptied(t) if not t then return {} end;for key in pairs(t) do t[key]=nil end;return t end
-- A fresh start: no motion history, stop, scan position or cooldown survives
-- into the next poll. Leaving a mission does this, and so does the loader when
-- an update below the mod fails. The mod holds nothing in the game itself.
function M.reset(state)
    state.fling_history,state.fling_stopped=emptied(state.fling_history),emptied(state.fling_stopped)
    state.cursors,state.reposed=emptied(state.cursors),emptied(state.reposed)
    state.listings,state.corpse_checks=emptied(state.listings),emptied(state.corpse_checks)
end
-- consume is made once, not as a new closure every poll: begin_apply points it
-- at the poll's api, state and time before each snapshot.
local poll_budget,apply_consume,begin_apply={}
do
    local api,state,now
    -- n is nil when M.apply read no time: the first unit reads it.
    function begin_apply(a,s,n) api,state,now=a,s,n end
    -- Whether the unit's own and global guards still hold. A unit the snapshot
    -- just verified (see hand_over) holds until this unit's first native
    -- call, which clears verified; every later check compares afresh.
    local function holds(u) return u.verified or same(api,u.guards) end
    local function read_time()
        if now==nil then now=api.time and api.time() or 0 end
    end
    -- The corpse re-check backoff (M.corpse_settle_polls): a corpse that
    -- needed no command keeps a record by unit, with its entity address and
    -- identity; one that needs a command, or a new entity, starts over.
    local function note_corpse(u,actions,stopped)
        if not u.corpse then return end
        local clean=actions==0 and not stopped
        local checks=state.corpse_checks
        if not checks then checks={};state.corpse_checks=checks end
        if not clean or not u.address or M.corpse_recheck_polls<=0 then checks[u.unit]=nil;return end
        local scan,record=state.fling_scan,checks[u.unit]
        if not record or record.address~=u.address or record.entity~=u.id then
            record={address=u.address,entity=u.id,since=scan,wait=0,due=0};checks[u.unit]=record
        end
        record.seen=scan
        if scan-record.since<M.corpse_settle_polls then return end
        record.wait=math.min(math.max(record.wait*2,2),M.corpse_recheck_polls)
        record.due=scan+record.wait
    end
    local function consume(u)
        read_time()
        state.observed=state.observed+1
        state.accepted_units=(state.accepted_units or 0)+1
        phase(api,'planning')
        local actions=M.plan(u)
        if api.profiler then
            u.profile_lifecycle=u.corpse and (#actions>0 and 'corpse_repair' or settled(u) and 'corpse_aligned' or 'corpse_other')
                or (u.update_enabled==false and 'ragdoll_stopped' or settled(u) and 'ragdoll_settled' or 'ragdoll_dynamic')
        end
        local stopped=state.fling_stopped[u.unit]
        note_corpse(u,#actions,stopped)
        actions=defer_repeats(state,u,actions,now)
        if #actions==0 and not stopped and u.corpse then return end
        if stopped and stopped.requested and u.corpse and u.active
            and stopped.resource==u.resource and holds(u) then
            -- Conversion creates a new entity while retaining the unit handle.
            -- Observe the phase; a submitted request alone is not success.
            state.completion_corpse_observed=(state.completion_corpse_observed or 0)+1
            state.fling_stopped[u.unit]=nil;stopped=nil
        end
        if stopped and (stopped.entity~=u.id or stopped.resource~=u.resource
            or stopped.members~=u.main_signature or u.corpse or u.update_enabled) then
            state.fling_stopped[u.unit]=nil;stopped=nil
        end
        -- No actions means this outer identity pass is redundant. Motion samples
        -- still need identity AND pose validation below: they can arm a later
        -- stop even when this poll issues no command.
        local planned=#actions>0 or stopped~=nil
        if not planned then state.guard_passes_skipped=(state.guard_passes_skipped or 0)+1 end
        if not planned or holds(u) then
            for _,action in ipairs(actions) do
                if holds(u) and same(api,action.actor.guards)
                    and native_ready(state,action.kind=='disable' and 'disable' or 'pose') then
                    u.verified=nil
                    if action.kind=='disable' then
                        phase(api,'native');state.native.disable(action.actor.id)
                        state.claws_disabled=(state.claws_disabled or 0)+1
                    else
                        phase(api,'native');state.native.pose(action.actor.id,action.position,action.rotation)
                        state.realignments=(state.realignments or 0)+1
                        local entry=state.reposed[action.actor.id]
                        if entry then entry.unit,entry.entity,entry.at=u.unit,u.id,now
                        else state.reposed[action.actor.id]={unit=u.unit,entity=u.id,at=now} end
                        if u.corpse and u.main_static<u.main_enabled then
                            state.mixed_corpse_realignments=(state.mixed_corpse_realignments or 0)+1
                        end
                        state.max_gap=math.max(state.max_gap or 0,action.gap)
                        state.last_unit=u.unit;state.last_actor=action.actor.id
                    end
                else state.skipped=(state.skipped or 0)+1 end
            end
            local stop,finish_handoff,request_completion
            local validate_motion=planned or (not u.corpse and u.owner==false and u.active==true
                and u.update_enabled==true and settled(u))
            -- A snapshot unit's root guard is one of its main pose guards
            -- (root_in_pose_guards): comparing it again would repeat a view.
            if not validate_motion or (holds(u) and same(api,u.main_pose_guards or EMPTY)
                and (not u.root_body or u.root_in_pose_guards or same(api,u.root_body.guards or EMPTY))) then
                if stopped then
                    stopped.last_scan=state.fling_scan
                    finish_handoff=u.owner and u.active and settled(u)
                    request_completion=u.owner==false and u.active and settled(u) and not stopped.requested
                        and stopped.stopped_at and now-stopped.stopped_at>=M.completion_grace
                end
                phase(api,'motion')
                stop=M.fling_action(u,state,now)
            else state.fling_history[u.unit]=nil end
            if finish_handoff and holds(u) and native_ready(state,'stop') then
                -- The component's runtime is copied unchanged when ownership
                -- moves (native 0x7a4b30). Finish ONLY a stop we previously
                -- made, through the routine's normal owned-Corpse branch.
                -- It may transition the entity, so do not read old storage.
                phase(api,'native');state.native.stop_sync(u.manager,u.index)
                state.fling_handoffs=(state.fling_handoffs or 0)+1
                state.fling_stopped[u.unit]=nil
            elseif request_completion and holds(u) and native_ready(state,'completion') then
                -- A remote stop never requests Corpse conversion. Ask its
                -- owner through the existing engine path once, after a grace
                -- period. No ownership, timer, or replication storage edits.
                stopped.requested=true
                state.completion_requests=(state.completion_requests or 0)+1
                state.last_completion_unit=u.unit;state.last_completion_entity=u.id
                state.last_completion_uptime=now
                phase(api,'native');state.native.request_completion(u.id)
                -- Native completion may invalidate entity storage. Read none
                -- of this snapshot again after the request.
            elseif stop and holds(u) and same(api,u.main_pose_guards or EMPTY) and native_ready(state,'stop') then
                -- Run last: this routine changes update_enabled, invalidating
                -- this snapshot's guards. The remote-only gate avoids its
                -- locally-owned force-Corpse branch. No pose is rewound.
                phase(api,'native');state.native.stop_sync(u.manager,u.index)
                state.fling_stops=(state.fling_stops or 0)+1
                state.last_fling_unit=u.unit;state.last_fling_entity=u.id
                state.last_fling_type=profiles[u.resource].name;state.last_fling_reason=stop.cause
                state.last_fling_uptime=now
                state.last_fling_distance=stop.distance;state.last_fling_degrees=stop.degrees
                state.last_fling_actor=stop.actor
                state.last_fling_limb_distance=stop.limb_distance or 0
                state.last_fling_limb_degrees=stop.limb_degrees or 0
                if stop.limb_distance then state.fling_limb_stops=(state.fling_limb_stops or 0)+1 end
                if stop.cause=='landed_disabled' then state.landed_disabled_stops=(state.landed_disabled_stops or 0)+1 end
                state.max_fling_distance=math.max(state.max_fling_distance or 0,stop.distance)
                if api.read(u.update_address,1)=='\0' then
                    state.fling_stops_verified=(state.fling_stops_verified or 0)+1
                    state.fling_history[u.unit]=nil
                    state.fling_stopped[u.unit]={entity=u.id,resource=u.resource,members=u.main_signature,
                        last_scan=state.fling_scan,stopped_at=now}
                end
            elseif stop then
                -- A race at dispatch breaks the observation interval too.
                state.fling_history[u.unit]=nil
            end
        else
            state.fling_history[u.unit]=nil
        end
    end
    apply_consume=consume
end

-- Every 256 polls, forgets backoff records of corpses not inspected for 256
-- polls (a waiting corpse is inspected at least every corpse_recheck_polls):
-- the game disposed of them.
local function prune_corpse_checks(state)
    local checks=state.corpse_checks
    if not checks or state.fling_scan%256~=0 then return end
    for unit,record in pairs(checks) do
        if state.fling_scan-record.seen>256 then checks[unit]=nil end
    end
end
-- Expires repose cooldowns and motion histories older than now allows.
local function expire(state,now)
    for id,entry in pairs(state.reposed) do
        if now<entry.at or now-entry.at>=M.repose_cooldown then state.reposed[id]=nil end
    end
    for key,entry in pairs(state.fling_history) do
        if now<entry.last or now-entry.last>1 then
            state.max_revisit_seconds=math.max(state.max_revisit_seconds or 0,now-entry.last)
            state.history_expirations=(state.history_expirations or 0)+1
            state.fling_history[key]=nil
        end
    end
end

function M.apply(api,game,exe,state)
    phase(api,'maintenance')
    state.reposed=state.reposed or {}
    state.fling_history=state.fling_history or {}
    state.fling_stopped=state.fling_stopped or {}
    state.fling_scan=(state.fling_scan or 0)+1
    -- The time is a system call: read here only when a cooldown or history
    -- may expire, otherwise by the poll's first unit (consume). A poll that
    -- keeps neither and hands over no unit reads no clock.
    local now
    if next(state.reposed)~=nil or next(state.fling_history)~=nil then
        now=api.time and api.time() or 0
        expire(state,now)
    end
    prune_corpse_checks(state)
    for key,entry in pairs(state.fling_stopped) do
        -- Count successful scans rather than wall time: a paused application
        -- must not forget a stop immediately before an ownership handoff.
        if state.fling_scan-entry.last_scan>256 then state.fling_stopped[key]=nil end
    end
    state.observed=0
    begin_apply(api,state,now);local consume,budget=apply_consume,poll_budget
    -- The deadline is set by the poll's first inspection (inspect_listed).
    budget.scanned,budget.inspected,budget.yielded,budget.deadline=0,0,nil,nil
    budget.clocked=0
    local units,reason=M.snapshot(api,game,exe,state,consume,budget)
    -- Snapshot substitutes used by policy tests may return complete units.
    if state.observed==0 then for _,u in ipairs(units) do consume(u) end end
    phase(api,'maintenance')
    state.scan_entities=(state.scan_entities or 0)+budget.scanned
    state.deep_inspections=(state.deep_inspections or 0)+budget.inspected
    if budget.yielded then state.budget_yields=(state.budget_yields or 0)+1 end
    -- Off a mission the first poll forgets everything; later ones find it
    -- forgotten already and skip the reset.
    if reason=='ready' then state.forgotten=false
    elseif not state.forgotten then M.reset(state);state.forgotten=true end
    state.completion_pending=0
    for _,entry in pairs(state.fling_stopped) do
        if entry.requested then state.completion_pending=state.completion_pending+1 end
    end
    return true,reason,reason=='ready'
end
return M

end)(profiles)
local profiler = (function()
-- Bounded, observational telemetry. Never changes game state or GC policy.
local P = {}
local stages={'discovery','snapshot','validation','planning','motion','native','maintenance','logging'}
local sections={'metadata','skeleton','actors','bodies'}
local counters={'scan_entities','deep_inspections','budget_yields','realignments','claws_disabled','fling_stops','completion_requests','history_expirations','guard_passes_skipped'}
local lifecycles={ragdoll_settled=true,ragdoll_dynamic=true,ragdoll_stopped=true,
    corpse_aligned=true,corpse_repair=true,corpse_other=true,unclassified=true,rejected=true}
local buckets={.1,.25,.5,1,2,4,8,16,33,100,1000,math.huge}
local function stats()return {count=0,total=0,maximum=0,histogram={},over2=0,over8=0,over16=0,over33=0}end
local function record(row,ms)
    row.count=row.count+1;row.total=row.total+ms;row.maximum=math.max(row.maximum,ms)
    if ms>2 then row.over2=row.over2+1 end
    if ms>8 then row.over8=row.over8+1 end
    if ms>16 then row.over16=row.over16+1 end
    if ms>33 then row.over33=row.over33+1 end
    for i,upper in ipairs(buckets)do if ms<=upper then row.histogram[i]=(row.histogram[i] or 0)+1;break end end
end
local function percentile(row)
    if row.count==0 then return 0 end
    local seen=0
    for i,upper in ipairs(buckets)do seen=seen+(row.histogram[i] or 0);if seen>=row.count*.95 then return upper end end
end
local function probe(fn,...)
    if type(fn)~='function' then return nil end
    local ok,value=pcall(fn,...)
    if ok and type(value)=='number' and value==value and math.abs(value)<math.huge then return value end
end
local function sorted_keys(rows)local keys={};for key in pairs(rows)do keys[#keys+1]=key end;table.sort(keys);return keys end

function P.new(api,revision)
    local clock=api.clock or api.time
    local p={rows={},details={},units={},workloads={},worst={},revisits={},before={},
        stats=stats(),window=stats(),chain=stats(),chain_window=stats(),intervals=stats(),
        scopes={mission=stats(),outside_mission=stats()},polls=0,updates=0,reads=0,bytes=0,
        total=0,maximum=0,output_max=0,finish_max=0,finish_total=0,started=clock(),
        unit_count=0,workload_count=0,late_revisits=0,max_late_revisit=0,revisit_evictions=0,
        cycles_total=0,cycles_samples=0,revision=revision}
    p.window_at=p.started
    for _,name in ipairs(stages)do p.rows[name]={ms=0,reads=0,bytes=0,read_ms=0,sampled_reads=0,poll_ms=0,max_poll_ms=0,window_ms=0}end
    for _,name in ipairs(sections)do p.details[name]={sampled_ms=0,reads=0,bytes=0}end
    local function close_detail(now)
        if p.sample and p.current=='snapshot' and p.detail_current and p.detail_at then
            local row=p.details[p.detail_current];row.sampled_ms=row.sampled_ms+(now-p.detail_at)*1000
        end
        p.detail_at=nil
    end
    local function close_phase(now)
        close_detail(now)
        if p.current then
            local row=p.rows[p.current];local ms=(now-p.phase_at)*1000
            row.ms=row.ms+ms;row.poll_ms=row.poll_ms+ms;row.window_ms=row.window_ms+ms
        end
        p.phase_at=now
    end
    function p.detail(name)
        if not p.running or not p.sample or not p.details[name] then return end
        local now=clock();close_detail(now)
        p.detail_current=name
        if now and p.current=='snapshot' then p.detail_at=now end
    end
    function p.phase(name)
        local old=p.current
        if p.running and p.rows[name] then
            local now=clock();close_phase(now);p.current=name
            if p.sample and name=='snapshot' and p.detail_current then p.detail_at=now end
        end
        return old
    end
    function p.begin(state)
        p.running=true;p.current='maintenance';p.start=clock();p.phase_at=p.start
        p.read_start=p.reads;p.byte_start=p.bytes;p.sample=p.polls%30==0
        p.detail_current=nil;p.detail_at=nil
        p.cycle_start=probe(api.thread_cycles);p.heap_start=probe(collectgarbage,'count')
        for _,row in pairs(p.rows)do row.poll_ms=0 end
        for _,key in ipairs(counters)do p.before[key]=state and state[key] or 0 end
        p.poll_worst_unit=nil;p.poll_worst_unit_ms=0;p.poll_worst_unit_kind=nil
    end
    function p.update_started()
        local now=clock();p.updates=p.updates+1
        if p.last_update and now>=p.last_update then record(p.intervals,(now-p.last_update)*1000)end
        p.last_update=now;return now
    end
    -- A failed update is only noticed on the next call: counted, not timed.
    function p.update_finished(start,ok)
        if not ok then p.update_errors=(p.update_errors or 0)+1 end
        if not start then return end
        local elapsed=(clock()-start)*1000
        record(p.chain,elapsed);record(p.chain_window,elapsed)
    end
    local function add_unit(rows,key,elapsed,reads)
        local row=rows[key]
        if not row then row={count=0,ms=0,max=0,reads=0};rows[key]=row end
        row.count=row.count+1;row.ms=row.ms+elapsed;row.max=math.max(row.max,elapsed);row.reads=row.reads+reads
    end
    function p.unit(name,start,reads,unit)
        if not p.running then return end
        local now=clock();local elapsed=(now-start)*1000
        if not p.units[name] then
            if p.unit_count>=64 then name='Other' else p.unit_count=p.unit_count+1 end
        end
        add_unit(p.units,name,elapsed,p.reads-reads)
        local kind=type(unit)=='table' and unit.profile_lifecycle or 'rejected'
        if not lifecycles[kind] then kind='unclassified' end
        local owner=type(unit)=='table' and (unit.owner==true and 'owned' or unit.owner==false and 'remote') or 'unknown'
        owner=owner or 'unknown'
        local key=name..' lifecycle='..kind..' ownership='..owner
        if not p.workloads[key] then
            if p.workload_count>=128 then key='Other lifecycle=unclassified ownership=unknown'
            else p.workload_count=p.workload_count+1 end
        end
        add_unit(p.workloads,key,elapsed,p.reads-reads)
        if elapsed>p.poll_worst_unit_ms then p.poll_worst_unit=name;p.poll_worst_unit_kind=kind;p.poll_worst_unit_ms=elapsed end
        -- Numeric identities live only in this fixed-size observation cache.
        -- It has no role in repair decisions and is never written to the log.
        if type(unit)=='table' and type(unit.unit)=='number' then
            local slot=unit.unit%256+1;local old=p.revisits[slot]
            if kind=='ragdoll_settled' and unit.owner==false and unit.active==true and unit.update_enabled==true then
                if old and old.unit==unit.unit and old.id==unit.id and old.resource==unit.resource then
                    local gap=now-old.at
                    if gap>1 then p.late_revisits=p.late_revisits+1;p.max_late_revisit=math.max(p.max_late_revisit,gap)end
                    old.at=now
                else
                    if old then p.revisit_evictions=p.revisit_evictions+1 end
                    p.revisits[slot]={unit=unit.unit,id=unit.id,resource=unit.resource,at=now}
                end
            elseif old and old.unit==unit.unit then p.revisits[slot]=nil end
        end
    end
    function p.finish(state)
        local now=clock();close_phase(now)
        local cycle_end=probe(api.thread_cycles);local heap_end=probe(collectgarbage,'count')
        p.running=false
        local elapsed=(now-p.start)*1000
        p.polls=p.polls+1;p.total=p.total+elapsed;p.maximum=math.max(p.maximum,elapsed)
        record(p.stats,elapsed);record(p.window,elapsed)
        local scope=state.mission_flag==1 and 'mission' or 'outside_mission'
        record(p.scopes[scope],elapsed)
        if scope=='outside_mission' then for slot in pairs(p.revisits)do p.revisits[slot]=nil end end
        local cycles=p.cycle_start and cycle_end and cycle_end>=p.cycle_start and cycle_end-p.cycle_start or nil
        if cycles then p.cycles_samples=p.cycles_samples+1;p.cycles_total=p.cycles_total+cycles end
        for _,row in pairs(p.rows)do row.max_poll_ms=math.max(row.max_poll_ms,row.poll_ms)end
        state.read_calls=p.reads-p.read_start;state.read_bytes=p.bytes-p.byte_start
        state.performance_last_ms=elapsed;state.performance_max_ms=p.maximum
        if #p.worst<8 or elapsed>p.worst[#p.worst].wall_ms then
            local event={poll=p.polls,at_s=now-p.started,wall_ms=elapsed,cycles=cycles,
                heap_delta_kb=p.heap_start and heap_end and heap_end-p.heap_start or nil,
                scope=scope,reads=state.read_calls,bytes=state.read_bytes,phases={},actions={},
                ragdolls=state.ragdoll_count or 0,corpses=state.corpse_count or 0,
                enemy=p.poll_worst_unit or 'none',lifecycle=p.poll_worst_unit_kind or 'none',enemy_ms=p.poll_worst_unit_ms}
            for _,name in ipairs(stages)do event.phases[name]=p.rows[name].poll_ms end
            for _,key in ipairs(counters)do event.actions[key]=(state[key] or 0)-p.before[key]end
            p.worst[#p.worst+1]=event;table.sort(p.worst,function(a,b)return a.wall_ms>b.wall_ms end)
            if #p.worst>8 then p.worst[9]=nil end
        end
        local overhead=(clock()-now)*1000;p.finish_total=p.finish_total+overhead;p.finish_max=math.max(p.finish_max,overhead)
    end
    local function stat_line(prefix,row)
        return string.format('%s_count=%d mean_ms=%.4f p95_upper_ms=%.4f max_ms=%.4f over2=%d over8=%d over16=%d over33=%d',
            prefix,row.count,row.total/math.max(1,row.count),percentile(row),row.maximum,row.over2,row.over8,row.over16,row.over33)
    end
    function p.text(state)
        local now=clock();local seconds=math.max(.001,now-p.started)
        local dominant,dominant_ms='none',0
        for _,name in ipairs(stages)do if p.rows[name].ms>dominant_ms then dominant,dominant_ms=name,p.rows[name].ms end end
        local flags={}
        if p.maximum>2 then flags[#flags+1]='slow_mod_poll' end
        if p.output_max>2 then flags[#flags+1]='slow_diagnostic_output' end
        if (state.budget_yields or 0)>0 then flags[#flags+1]='work_deferred' end
        if p.late_revisits>0 then flags[#flags+1]='late_ragdoll_revisit' end
        local lines={'Enemy Collision Synchronized performance '..revision..' schema=2',
            'scope=mod_callback; wall times include possible descheduling; phases exclusive; reads timed one poll in 30',
            'wrapped_update includes vanilla and earlier hooks only, excludes this mod and later hooks; not GPU FPS or network latency',
            'native=dispatch only; thread cycles are raw, not milliseconds; Lua heap deltas cover the shared VM and do not prove GC pauses',
            string.format('seconds=%.2f polls=%d update_calls=%d update_calls_per_second=%.2f',seconds,p.polls,p.updates,p.updates/seconds),
            string.format('mod_ms_mean=%.4f mod_ms_p95_upper=%.4f mod_ms_max=%.4f mod_ms_per_second=%.4f',p.total/math.max(1,p.polls),percentile(p.stats),p.maximum,p.total/seconds),
            string.format('profiler_output_ms_max=%.4f profiler_finish_ms_max=%.4f profiler_finish_ms_total=%.4f dominant_phase=%s flags=%s',p.output_max,p.finish_max,p.finish_total,dominant,table.concat(flags,',')),
            stat_line('poll',p.stats),stat_line('mission_poll',p.scopes.mission),stat_line('outside_mission_poll',p.scopes.outside_mission),
            string.format('window_polls=%d seconds=%.2f mod_ms_per_second=%.4f ',p.window.count,now-p.window_at,p.window.total/math.max(.001,now-p.window_at))..stat_line('window',p.window),
            stat_line('wrapped_update',p.chain),stat_line('window_wrapped_update',p.chain_window),stat_line('update_interval',p.intervals),
            'wrapped_update_errors='..tostring(p.update_errors or 0),
            string.format('thread_cycle_samples=%d thread_cycles_total=%.0f late_ragdoll_revisits=%d max_late_revisit_seconds=%.4f revisit_cache_slots=256 revisit_cache_evictions=%d',p.cycles_samples,p.cycles_total,p.late_revisits,p.max_late_revisit,p.revisit_evictions)}
        for _,name in ipairs(stages)do
            local row=p.rows[name]
            lines[#lines+1]=string.format('phase=%s ms=%.4f max_poll_ms=%.4f window_ms=%.4f reads=%d bytes=%d sampled_read_ms=%.4f sampled_reads=%d',name,row.ms,row.max_poll_ms,row.window_ms,row.reads,row.bytes,row.read_ms,row.sampled_reads)
        end
        for _,name in ipairs(sections)do
            local row=p.details[name]
            lines[#lines+1]=string.format('snapshot_section=%s sampled_ms=%.4f sampled_reads=%d sampled_bytes=%d',name,row.sampled_ms,row.reads,row.bytes)
        end
        for _,name in ipairs(sorted_keys(p.units))do
            local row=p.units[name];lines[#lines+1]=string.format('enemy=%s inspections=%d mean_ms=%.4f max_ms=%.4f reads=%d',name,row.count,row.ms/row.count,row.max,row.reads)
        end
        for _,key in ipairs(sorted_keys(p.workloads))do
            local row=p.workloads[key];lines[#lines+1]=string.format('workload=%s inspections=%d mean_ms=%.4f max_ms=%.4f reads=%d',key,row.count,row.ms/row.count,row.max,row.reads)
        end
        for i,event in ipairs(p.worst)do
            local parts={string.format('slow_poll_rank=%d poll=%d at_s=%.4f wall_ms=%.4f thread_cycles=%s heap_delta_kb=%s scope=%s reads=%d bytes=%d ragdolls=%d corpses=%d enemy=%s lifecycle=%s enemy_ms=%.4f',
                i,event.poll,event.at_s,event.wall_ms,tostring(event.cycles or 'unavailable'),tostring(event.heap_delta_kb or 'unavailable'),event.scope,event.reads,event.bytes,event.ragdolls,event.corpses,event.enemy,event.lifecycle,event.enemy_ms)}
            for _,name in ipairs(stages)do parts[#parts+1]=string.format('%s_ms=%.4f',name,event.phases[name])end
            for _,key in ipairs(counters)do parts[#parts+1]=key..'='..event.actions[key]end
            lines[#lines+1]=table.concat(parts,' ')
        end
        for _,key in ipairs(counters)do lines[#lines+1]=key..'='..tostring(state[key] or 0)end
        for _,key in ipairs({'world_metadata_decodes','pool_metadata_decodes'})do
            lines[#lines+1]=key..'='..tostring(state[key] or 0)
        end
        for _,key in ipairs({'ragdoll_count','corpse_count','skipped','retries'})do lines[#lines+1]=key..'='..tostring(state[key] or 0)end
        lines[#lines+1]='history_expiry_age_max_seconds='..tostring(state.max_revisit_seconds or 0)
        return table.concat(lines,'\n')..'\n'
    end
    function p.flush(state,force)
        local now=clock()
        if not force and now-(p.last_output or p.started)<10 then return end
        p.last_output=now
        local ok,written=pcall(function()
            local logger=rawget(_G,'CowboyBingusModLoader')
            local file=logger and logger.open_log and logger.open_log('EnemyCollisionSynchronized-Performance.log');if not file then return false end
            local success,result=pcall(function()return file:write(p.text(state))end)
            local closed=file:close();return success and result~=nil and closed~=nil
        end)
        p.output_max=math.max(p.output_max,(clock()-now)*1000)
        if ok and written then
            p.window=stats();p.chain_window=stats();p.window_at=clock()
            for _,row in pairs(p.rows)do row.window_ms=0 end
        end
    end
    -- Install the read wrapper last so failed setup leaves the original API intact.
    local read=api.read
    api.read=function(address,size)
        if not p.running then return read(address,size)end
        local row=p.rows[p.current]
        p.reads=p.reads+1;p.bytes=p.bytes+size;row.reads=row.reads+1;row.bytes=row.bytes+size
        if p.sample then
            local detail=p.current=='snapshot' and p.detail_current and p.details[p.detail_current]
            if detail then detail.reads=detail.reads+1;detail.bytes=detail.bytes+size end
            local start=clock();local bytes=read(address,size)
            row.read_ms=row.read_ms+(clock()-start)*1000;row.sampled_reads=row.sampled_reads+1;return bytes
        end
        return read(address,size)
    end
    local view=api.view
    -- Wrap the view only while it is paired with the read wrapped above, and
    -- keep the wrapped pair paired.
    if view and api.view_read==read then
        api.view_read=api.read
        api.view=function(address,size)
            if not p.running then return view(address,size) end
            local row=p.rows[p.current]
            p.reads=p.reads+1;p.bytes=p.bytes+size;row.reads=row.reads+1;row.bytes=row.bytes+size
            if p.sample then
                local start=clock();local result=view(address,size)
                row.read_ms=row.read_ms+(clock()-start)*1000;row.sampled_reads=row.sampled_reads+1;return result
            end
            return view(address,size)
        end
    end
    return p
end
return P

end)()
local runtime = (function()
-- bingus_runtime.lua, version 1: the core of Bingus Shared Runtime.
-- Canonical copy: github.com/CowboyBingus/BingusSharedRuntime, runtime/bingus_runtime.lua.
--
-- Helldivers 2 runs the game and every Lua mod in one LuaJIT state, with one
-- global update chain. This file gives a mod the update guard every mod used
-- to write by hand, and the session table all runtime copies share. It uses no
-- FFI and no system function.
--
-- Loading: each runtime file is one chunk that returns a table and installs
-- nothing until the mod asks. A mod vendors byte-identical copies of the files
-- it needs and runs each once when it loads:
--   local runtime = <bingus_runtime.lua>              -- this file: shared(), guard()
--   local memory = <bingus_memory.lua>.new(runtime)   -- reads, page checks, module hashes, time()
--   <bingus_write.lua>.extend(memory)                 -- checked writes, added to memory
-- A mod that never touches memory vendors this file alone; one that only reads
-- vendors this file and bingus_memory.lua.
--
-- Copies of different versions can run in the same game. Their session state
-- lives in one global table, BingusRuntime = {hashes, statuses, versions,
-- hash_reads}, which every copy of every version shares.
--
-- runtime.shared([globals]) -> BingusRuntime, created or repaired.
-- runtime.guard(options) -> guard: the update and shutdown wrappers. The
-- previous update runs outside pcall, so its errors reach the game unchanged
-- (P1); the first failure survives shutdown as "stopped after: <reason>" (P2);
-- 8 errors stop the mod, counted per burst so rare transient errors never add
-- up (P3); a mod that can restore its state pauses after an error below it and
-- resumes when the updates below run cleanly again; every argument and return
-- value passes through; a status table per mod lands in BingusRuntime.statuses.
--
-- Per-frame cost of a guard: the mod's step under pcall, a few boolean tests
-- and stores and two integer counters around the previous update; no
-- allocation, closure or system call. Unmeasured in game.
local runtime = {VERSION = 1}

local type, pcall, error, tostring, rawget, rawset, ipairs = type, pcall, error, tostring, rawget, rawset, ipairs

-- Session state shared by every copy of every version ----------------------------

local SHARED = 'BingusRuntime'
local SHARED_TABLES = {'hashes', 'statuses', 'versions'}

-- Another copy, another version or another mod may have left the table
-- incomplete (even `BingusRuntime = {}`): missing or broken fields are filled in,
-- so one stray assignment cannot stop every mod on the runtime.
function runtime.shared(globals)
    globals = globals or _G
    local shared = rawget(globals, SHARED)
    if type(shared) ~= 'table' then
        shared = {}
        rawset(globals, SHARED, shared)
    end
    for _, field in ipairs(SHARED_TABLES) do
        if type(rawget(shared, field)) ~= 'table' then rawset(shared, field, {}) end
    end
    if type(rawget(shared, 'hash_reads')) ~= 'number' then rawset(shared, 'hash_reads', 0) end
    rawset(rawget(shared, 'versions'), runtime.VERSION, true)
    return shared
end

-- Update guard -----------------------------------------------------------------------

-- options:
--   name    key in BingusRuntime.statuses (required, one guard per name)
--   step    function(dt, ...) before the previous update, every frame while running
--   after   function() after the previous update returned, while running
--   stop    function(reason) once, when the guard stops or the game shuts down;
--           its errors are kept in status.stop_error, never raised
--   pause   function(reason), optional: an update below this mod raised; restore
--           the game state and reset the mod to a fresh start. With it the guard
--           pauses (no step, no after) and resumes once the updates below have
--           returned on `resume` frames in a row (default 60). Without it such an
--           error stops the guard. A pause that raises stops the guard.
--   log     function(line) for the guard's few lines (errors, pauses, resumes, stop)
--   errors  errors that stop the guard (default 8), counted separately for the
--           mod's own step and after and for the updates below it. A count starts
--           again after `clean` frames without such an error (default 3600, about a
--           minute at 60 FPS), so rare transient errors never add up to a stop.
--   env     the table holding update and shutdown (default _G)
-- guard.install() wraps env.update and env.shutdown and returns the guard.
-- guard.stop(reason) stops it from the mod (a refusal counts as the first failure).
-- guard.running() is true from install until a stop or shutdown.
-- guard.status: {name, version, state, installed, errors, lower_errors, pauses,
--   first_error, burst_error, first_failure, stop_error}; state is 'new', 'running',
--   'paused: <reason>', 'stopped: <reason>', then at shutdown 'stopped' or
--   'stopped after: <first failure>'.
function runtime.guard(options)
    local name = options.name
    if type(name) ~= 'string' or name == '' then error('guard name required', 0) end
    local shared = runtime.shared(options.env)
    if shared.statuses[name] and shared.statuses[name].installed then error('guard ' .. name .. ' already installed', 0) end
    local status = {name = name, version = runtime.VERSION, state = 'new', installed = false, errors = 0,
        lower_errors = 0, pauses = 0}
    shared.statuses[name] = status
    local step, after_step, stop_work, pause_work, log = options.step, options.after, options.stop, options.pause,
        options.log
    local limit, resume_after, clean_after = options.errors or 8, options.resume or 60, options.clean or 3600
    local previous_update, previous_shutdown
    local in_previous, stopped, paused, failed = false, false, false, false
    local clean_run, lower_run = 0, 0

    local function note(line)
        if log then pcall(log, line) end
    end

    local function halt(reason)
        if stopped then return end
        stopped, paused = true, false
        status.first_failure = status.first_failure or reason
        status.state = 'stopped: ' .. reason
        note(name .. ' stopped: ' .. reason)
        if stop_work then
            local ok, why = pcall(stop_work, reason)
            if not ok then status.stop_error = tostring(why) end
        end
    end

    -- The mod's own step or after raised: one log line per burst of errors.
    local function failed_step(problem)
        failed, clean_run = true, 0
        status.errors = status.errors + 1
        local text = tostring(problem)
        status.first_error = status.first_error or text
        if status.errors == 1 then
            status.burst_error = text
            note(name .. ' error: ' .. text)
        end
        if status.errors >= limit then halt('stopped after ' .. limit .. ' errors: ' .. status.burst_error) end
    end

    -- An update below this mod raised (seen on the next frame).
    local function failed_below()
        lower_run = 0
        status.lower_errors = status.lower_errors + 1
        if not pause_work then return halt('the previous update failed') end
        if status.lower_errors >= limit then
            return halt('stopped after ' .. limit .. ' failed updates below this mod')
        end
        if paused then return end
        paused = true
        status.pauses = status.pauses + 1
        status.state = 'paused: the previous update failed'
        note(name .. ' paused: the previous update failed')
        local ok, why = pcall(pause_work, 'the previous update failed')
        if not ok then halt('pause failed: ' .. tostring(why)) end
    end

    local function resume_when_clean()
        if paused and lower_run >= resume_after then
            paused = false
            status.state = 'running'
            note(name .. ' resumed after ' .. resume_after .. ' clean frames')
        end
    end

    -- Counts a frame without an own error, which also clears an old burst.
    local function count_clean()
        if failed then return end
        clean_run = clean_run + 1
        if clean_run == clean_after then status.errors = 0 end
    end

    local function finish(...)
        in_previous = false
        lower_run = lower_run + 1
        if lower_run == clean_after then status.lower_errors = 0 end
        if not stopped and not paused then
            if after_step then
                local ok, problem = pcall(after_step)
                if not ok then failed_step(problem) end
            end
            count_clean()
        end
        return ...
    end

    -- The previous update runs outside pcall: its errors (value and traceback)
    -- reach the game unchanged. One that raised leaves in_previous set, and the
    -- next frame pauses (or stops) this mod and keeps forwarding.
    local function update(...)
        failed = false
        if in_previous then
            in_previous = false
            if not stopped then failed_below() end
        end
        resume_when_clean()
        if step and not stopped and not paused then
            local ok, problem = pcall(step, ...)
            if not ok then failed_step(problem) end
        end
        in_previous = true
        return finish(previous_update(...))
    end

    local function shutdown(...)
        if in_previous then
            in_previous = false
            status.first_failure = status.first_failure or 'the previous update failed'
        end
        local failure = status.first_failure
        if not stopped then
            stopped = true
            if stop_work then
                local ok, why = pcall(stop_work, 'shutdown')
                if not ok then status.stop_error = tostring(why) end
            end
        end
        status.state = failure and ('stopped after: ' .. failure) or 'stopped'
        if previous_shutdown then return previous_shutdown(...) end
    end

    local guard = {status = status}

    function guard.install()
        local env = options.env or _G
        if status.installed then error('guard ' .. name .. ' already installed', 0) end
        previous_update = rawget(env, 'update')
        if type(previous_update) ~= 'function' then error('game update unavailable', 0) end
        previous_shutdown = rawget(env, 'shutdown')
        rawset(env, 'update', update)
        rawset(env, 'shutdown', shutdown)
        status.installed, status.state = true, 'running'
        return guard
    end

    function guard.stop(reason)
        halt(tostring(reason))
    end

    function guard.running()
        return status.installed and not stopped
    end

    return guard
end

return runtime

end)()
local runtime_memory = (function()
-- bingus_memory.lua, version 1: the read side of Bingus Shared Runtime.
-- Canonical copy: github.com/CowboyBingus/BingusSharedRuntime, runtime/bingus_memory.lua.
--
-- Loading: the chunk returns {VERSION = 1, new = function(runtime)} and
-- installs nothing. A mod vendors a byte-identical copy next to
-- bingus_runtime.lua and runs each file once when it loads:
--   local runtime = <bingus_runtime.lua>
--   local memory = <bingus_memory.lua>.new(runtime)   -- the api below
--   <bingus_write.lua>.extend(memory)                 -- optional: checked writes
-- This file only reads memory, page information and module files; it never
-- changes memory or page protection. A mod whose build refuses sources that can
-- modify memory vendors bingus_runtime.lua and this file only.
--
-- Windows functions are declared under private, versioned FFI names
-- (bingus_memory1_*, each with an __asm__ label naming the real export), at
-- most once per version in the whole game. ffi.cdef keeps the first prototype
-- of a name for the whole game, so a plain name would bind to whatever another
-- mod declared first. Copies of other versions declare their own names.
--
-- memory.new(runtime) -> api. runtime is the table bingus_runtime.lua returns:
-- its shared table keeps module hashes for the session. Each api has its own
-- buffers and counters; every api of one copy shares the bound functions.
--   api.read(address, size)        the bytes as a string, or nil when they cannot
--                                  all be read; allocates only that string
--   api.read_into(address, size, buffer)  into a buffer the caller keeps: true or
--                                  false, no allocation
--   api.pointer(bytes [, offset])  the user-mode pointer stored little-endian at
--                                  bytes[offset+1 .. offset+8], as uint8_t *, or nil
--   api.address(pointer)           a pointer, number or integer cdata as a Lua number
--   api.distance(a, b)             api.address(a) - api.address(b)
--   api.writable_data(address, size)  true when [address, address + size) is
--                                  committed private read-write memory: never code,
--                                  read-only, guard or module image pages
--   api.queries                    page queries made so far (one per memory region)
--   api.time()                     seconds from the performance counter (a Lua number)
--   api.module([name])             a loaded module's base as uint8_t *, or nil;
--                                  no name: the executable
--   api.module_hash(module)        SHA-256 (uppercase hex) of the module's file, read
--                                  once per session for every mod (BingusRuntime.hashes)
--   api.verify_build(build)        build = {exe_sha256, game_sha256}: true, or false and why
--   api.windows                    {ffi, kernel32, bcrypt}: the bound functions under
--                                  their Windows names, for calls the api does not cover
-- Addresses are pointer cdata (read, read_into) or pointers, numbers and integer
-- cdata (address, distance, writable_data).
--
-- Cost per call: read and read_into one ReadProcessMemory (about 1-2 us in game);
-- writable_data one VirtualQuery per memory region in the range (about 0.29 ms
-- each in game), so check only on frames that act; time() one
-- QueryPerformanceCounter (unmeasured in game). read_into, address, distance,
-- writable_data and time allocate nothing, interpreted or compiled.
local memory = {VERSION = 1}

local type, error, pcall, tonumber, ipairs, pairs = type, error, pcall, tonumber, ipairs, pairs
local max, format, concat = math.max, string.format, table.concat

local HIGH = 4294967296
local MEM_COMMIT, MEM_PRIVATE, PAGE_READWRITE = 0x1000, 0x20000, 4

-- Windows functions ----------------------------------------------------------------

-- The region record is MEMORY_BASIC_INFORMATION with each 64-bit field read as
-- two 32-bit halves, and the cell turns a pointer into two halves through one
-- union (one base, so compiled code sees the store): neither allocates when read.
-- The region record is also this file's sentinel: once it exists, every
-- declaration below exists too.
local PREFIX = 'bingus_memory1_'
local SENTINEL = 'bingus_memory1_region'
local DECLARATIONS = [[
    typedef struct bingus_memory1_region {
        uint32_t base_low, base_high, allocation_base_low, allocation_base_high;
        uint32_t allocation_protection; uint16_t partition, reserved;
        uint32_t size_low, size_high, state, protection, type, padding;
    } bingus_memory1_region;
    typedef union bingus_memory1_cell {
        const void *pointer;
        struct { uint32_t low, high; };
    } bingus_memory1_cell;
    void *bingus_memory1_GetModuleHandleA(const char *name) __asm__("GetModuleHandleA");
    uint32_t bingus_memory1_GetModuleFileNameW(void *module, uint16_t *path, uint32_t capacity) __asm__("GetModuleFileNameW");
    void *bingus_memory1_GetCurrentProcess(void) __asm__("GetCurrentProcess");
    int bingus_memory1_ReadProcessMemory(void *process, const void *address, void *buffer, size_t size,
                                         size_t *done) __asm__("ReadProcessMemory");
    uint32_t bingus_memory1_VirtualQuery(uint64_t address, bingus_memory1_region *region, size_t size) __asm__("VirtualQuery");
    int bingus_memory1_QueryPerformanceCounter(uint32_t *count) __asm__("QueryPerformanceCounter");
    int bingus_memory1_QueryPerformanceFrequency(uint32_t *frequency) __asm__("QueryPerformanceFrequency");
    void *bingus_memory1_CreateFileW(const uint16_t *path, uint32_t access, uint32_t share, void *security,
                                     uint32_t disposition, uint32_t flags, void *template_file) __asm__("CreateFileW");
    int bingus_memory1_ReadFile(void *file, void *buffer, uint32_t size, uint32_t *done, void *overlapped) __asm__("ReadFile");
    int bingus_memory1_CloseHandle(void *handle) __asm__("CloseHandle");
    int32_t bingus_memory1_BCryptOpenAlgorithmProvider(void **algorithm, const uint16_t *name, const uint16_t *provider,
                                                       uint32_t flags) __asm__("BCryptOpenAlgorithmProvider");
    int32_t bingus_memory1_BCryptCloseAlgorithmProvider(void *algorithm, uint32_t flags) __asm__("BCryptCloseAlgorithmProvider");
    int32_t bingus_memory1_BCryptCreateHash(void *algorithm, void **hash, void *object, uint32_t object_size,
                                            const void *secret, uint32_t secret_size, uint32_t flags) __asm__("BCryptCreateHash");
    int32_t bingus_memory1_BCryptHashData(void *hash, const void *data, uint32_t size, uint32_t flags) __asm__("BCryptHashData");
    int32_t bingus_memory1_BCryptFinishHash(void *hash, void *digest, uint32_t size, uint32_t flags) __asm__("BCryptFinishHash");
    int32_t bingus_memory1_BCryptDestroyHash(void *hash) __asm__("BCryptDestroyHash");
]]
local FUNCTIONS = {
    kernel32 = {'GetModuleHandleA', 'GetModuleFileNameW', 'GetCurrentProcess', 'ReadProcessMemory', 'VirtualQuery',
                'QueryPerformanceCounter', 'QueryPerformanceFrequency', 'CreateFileW', 'ReadFile', 'CloseHandle'},
    bcrypt = {'BCryptOpenAlgorithmProvider', 'BCryptCloseAlgorithmProvider', 'BCryptCreateHash',
              'BCryptHashData', 'BCryptFinishHash', 'BCryptDestroyHash'},
}

local bound, ticks_per_second
-- {ffi, kernel32, bcrypt}, each library table holding the functions above under
-- their Windows names. Declared at most once per version in the whole game.
local function bind()
    if bound then return bound end
    local ffi = require('ffi')
    if not ffi.abi('64bit') then error('Windows x64 is required', 0) end
    if not pcall(ffi.typeof, SENTINEL) then ffi.cdef(DECLARATIONS) end
    local result = {ffi = ffi}
    for library, names in pairs(FUNCTIONS) do
        local loaded, functions = ffi.load(library), {}
        for _, name in ipairs(names) do functions[name] = loaded[PREFIX .. name] end
        result[library] = functions
    end
    local frequency = ffi.new('uint32_t[2]')
    if result.kernel32.QueryPerformanceFrequency(frequency) == 0 then error('performance counter unavailable', 0) end
    ticks_per_second = frequency[0] + frequency[1] * HIGH
    bound = result
    return bound
end

-- Module files ---------------------------------------------------------------------

-- SHA-256 (uppercase hex) of the file at path (a UTF-16 string buffer).
local function sha256(windows, path)
    local ffi, kernel, bcrypt = windows.ffi, windows.kernel32, windows.bcrypt
    local file = kernel.CreateFileW(path, 0x80000000, 7, nil, 3, 0x08000000, nil)
    if file == ffi.cast('void *', -1) then error('cannot read the module file', 0) end
    local algorithm, hash = ffi.new('void *[1]'), ffi.new('void *[1]')
    local ok, result = pcall(function()
        local id = ffi.new('uint16_t[7]', {83, 72, 65, 50, 53, 54, 0})  -- "SHA256"
        if bcrypt.BCryptOpenAlgorithmProvider(algorithm, id, nil, 0) ~= 0 then error('SHA-256 unavailable', 0) end
        if bcrypt.BCryptCreateHash(algorithm[0], hash, nil, 0, nil, 0, 0) ~= 0 then
            error('SHA-256 unavailable', 0)
        end
        local buffer, count = ffi.new('uint8_t[1048576]'), ffi.new('uint32_t[1]')
        while true do
            if kernel.ReadFile(file, buffer, 1048576, count, nil) == 0 then error('module file read failed', 0) end
            if count[0] == 0 then break end
            if bcrypt.BCryptHashData(hash[0], buffer, count[0], 0) ~= 0 then error('SHA-256 failed', 0) end
        end
        local digest, hex = ffi.new('uint8_t[32]'), {}
        if bcrypt.BCryptFinishHash(hash[0], digest, 32, 0) ~= 0 then error('SHA-256 failed', 0) end
        for i = 0, 31 do hex[i + 1] = format('%02X', digest[i]) end
        return concat(hex)
    end)
    if hash[0] ~= nil then bcrypt.BCryptDestroyHash(hash[0]) end
    if algorithm[0] ~= nil then bcrypt.BCryptCloseAlgorithmProvider(algorithm[0], 0) end
    kernel.CloseHandle(file)
    if not ok then error(result, 0) end
    return result
end

-- The SHA-256 of a loaded module's file, read once per session for every mod:
-- kept in the shared table by file path.
local function module_hash(runtime, windows, module)
    local ffi = windows.ffi
    local path = ffi.new('uint16_t[32768]')
    local length = windows.kernel32.GetModuleFileNameW(module, path, 32768)
    if length == 0 or length >= 32768 then error('module file name unavailable', 0) end
    local shared = runtime.shared()
    local key = 'sha256:' .. ffi.string(path, length * 2)
    local cached = shared.hashes[key]
    if cached then return cached end
    local hex = sha256(windows, path)
    shared.hash_reads = shared.hash_reads + 1
    shared.hashes[key] = hex
    return hex
end

-- The api --------------------------------------------------------------------------

function memory.new(runtime)
    if type(runtime) ~= 'table' or type(runtime.shared) ~= 'function' then
        error('bingus_memory.lua: new(runtime) needs the table bingus_runtime.lua returns', 2)
    end
    runtime.shared()
    local windows = bind()
    local ffi, kernel = windows.ffi, windows.kernel32
    local read_memory, query, query_counter = kernel.ReadProcessMemory, kernel.VirtualQuery,
        kernel.QueryPerformanceCounter
    local process = kernel.GetCurrentProcess()
    -- ReadProcessMemory reports its count as a 64-bit size: it is read back as two
    -- 32-bit words, because reading the 64-bit value boxes a new cdata in
    -- interpreted code. Only the call writes this buffer.
    local done = ffi.new('size_t[1]')
    local done32 = ffi.cast('uint32_t *', done)
    local region, region_size = ffi.new(SENTINEL), ffi.sizeof(SENTINEL)
    local cell, counter = ffi.new('bingus_memory1_cell'), ffi.new('uint32_t[2]')
    local scratch_size = 256
    local scratch = ffi.new('uint8_t[?]', scratch_size)
    local ticks = ticks_per_second
    local api = {queries = 0, windows = windows}

    -- A pointer, number or integer cdata as a number, without allocating: a
    -- pointer passes through the cell. Exact below 2^53 (user-mode addresses
    -- end at 2^47).
    local function address_of(address)
        if type(address) == 'number' then return address end
        if type(address) == 'cdata' then
            local integer = tonumber(address)
            if integer then return integer end
        end
        cell.pointer = address
        return cell.low + cell.high * HIGH
    end

    function api.module(name)
        local handle = kernel.GetModuleHandleA(name)
        if handle == nil then return nil end
        return ffi.cast('uint8_t *', handle)
    end

    -- The bytes at address as a string, or nil when they cannot all be read.
    -- Allocates only the returned string.
    function api.read(address, size)
        if size > scratch_size then
            scratch_size = max(size, scratch_size * 2)
            scratch = ffi.new('uint8_t[?]', scratch_size)
        end
        if read_memory(process, address, scratch, size, done) == 0 or done32[0] ~= size then
            return nil
        end
        return ffi.string(scratch, size)
    end

    -- Into a buffer the caller keeps: no allocation at all.
    function api.read_into(address, size, buffer)
        return read_memory(process, address, buffer, size, done) ~= 0 and done32[0] == size
    end

    -- The user-mode pointer stored little-endian at bytes[offset+1 .. offset+8].
    function api.pointer(bytes, offset)
        offset = offset or 0
        if type(bytes) ~= 'string' or offset < 0 or offset + 8 > #bytes then return nil end
        local b1, b2, b3, b4, b5, b6, b7, b8 = bytes:byte(offset + 1, offset + 8)
        if b7 ~= 0 or b8 ~= 0 then return nil end
        local value = b1 + b2 * 256 + b3 * 65536 + b4 * 16777216 + (b5 + b6 * 256) * HIGH
        if value < 0x10000 or value >= 0x800000000000 then return nil end
        return ffi.cast('uint8_t *', value)
    end

    api.address = address_of

    function api.distance(first, second)
        return address_of(first) - address_of(second)
    end

    -- True when [address, address + size) is committed private read-write memory:
    -- never code, read-only, guard or module image pages. One VirtualQuery per
    -- region, each answered in the region record (no allocation).
    function api.writable_data(address, size)
        if type(size) ~= 'number' or size <= 0 then return false end
        local cursor = address_of(address)
        local finish = cursor + size
        while cursor < finish do
            api.queries = api.queries + 1
            if query(cursor, region, region_size) ~= region_size then return false end
            if region.state ~= MEM_COMMIT or region.type ~= MEM_PRIVATE or region.protection ~= PAGE_READWRITE then
                return false
            end
            local region_end = region.base_low + region.base_high * HIGH + region.size_low + region.size_high * HIGH
            if region_end <= cursor then return false end
            cursor = region_end
        end
        return true
    end

    -- Seconds since an arbitrary start (boot), from the performance counter read
    -- as two 32-bit halves into a reused buffer; the frequency is read once.
    function api.time()
        query_counter(counter)
        return (counter[0] + counter[1] * HIGH) / ticks
    end

    function api.module_hash(module)
        return module_hash(runtime, windows, module)
    end

    -- build: {exe_sha256, game_sha256}. true, or false and why.
    function api.verify_build(build)
        local exe, game = api.module(nil), api.module('game.dll')
        if not exe or not game then return false, 'game modules unavailable' end
        if api.module_hash(exe) ~= build.exe_sha256 or api.module_hash(game) ~= build.game_sha256 then
            return false, 'unsupported game build'
        end
        return true
    end

    return api
end

return memory

end)()
local install_loader = (function()
return function(create_api,patch,build,runtime,runtime_memory)
    if rawget(_G,'CorpseCollisionRepair') then return end
    local state={revision=build.revision,active=false,updates=0,polls=0,observed=0,
        realignments=0,claws_disabled=0,skipped=0,retries=0,max_gap=0}
    rawset(_G,'CorpseCollisionRepair',state)
    local api,last_log
    -- Diagnostics are off unless CowboyBingusDiagnostics = true before this mod
    -- initializes. Only then does the profiler run (timed reads, thread cycle
    -- queries, a performance log every 10 s) and is the status log rewritten
    -- during play, at most every 2 s. Startup, pauses, stops and shutdown always
    -- write it.
    local diagnostics=rawget(_G,'CowboyBingusDiagnostics')==true
    local function report(status,active,force)
        state.status=status;state.active=active
        if not force and not diagnostics then return end
        local now=api and api.time() or 0
        if not force and last_log and now-last_log<2 then return end
        last_log=now
        if force then print('[CorpseCollisionRepair] '..build.revision..': '..status) end
        pcall(function()
            local logger=rawget(_G,'CowboyBingusModLoader')
            local file=logger and logger.open_log and logger.open_log('CorpseCollisionRepair.log');if not file then return end
            file:write(build.revision..'\n'..status..'\n')
            for _,key in ipairs({'updates','polls','observed','realignments','claws_disabled','skipped','retries','pauses',
                'accepted_units','guard_passes_skipped','preflight_getter','getter_checks','getter_failures','last_getter_failure',
                'mission_flag','mode_field_40','native_waits',
                'max_gap','last_unit','last_actor','read_bytes','read_calls','last_skip','profiler_failures',
                'fling_armed','fling_stops','fling_stops_verified','fling_handoffs','max_fling_distance',
                'last_fling_unit','last_fling_entity','last_fling_type','last_fling_reason',
                'fling_limb_stops','last_fling_actor','last_fling_limb_distance','last_fling_limb_degrees',
                'landed_disabled_stops','mixed_corpse_realignments','reposes_deferred',
                'completion_requests','completion_corpse_observed','completion_pending',
                'last_completion_unit','last_completion_entity','last_completion_uptime',
                'last_fling_distance','last_fling_degrees','last_fling_uptime'}) do
                file:write(key..'='..tostring(state[key] or 0)..'\n')
            end
            file:close()
        end)
    end
    local ok,game,exe=pcall(function()
        local loader=rawget(_G,'CowboyBingusModLoader')
        assert(type(loader)=='table' and type(loader.api)=='number' and loader.api>=1
            and type(loader.version)=='number' and loader.version>=9,
            'Bingus Shared Loader loader-v8 or newer / API 1 or newer is required')
        api=create_api()
        -- The module hashes come from the runtime's session cache: each module
        -- file is read at most once per session, for every mod together.
        local verified,why=runtime_memory.new(runtime).verify_build(build)
        if not verified then error(why,0) end
        assert(type(update)=='function','Game update unavailable')
        local g,e=api.module('game.dll'),api.module(nil)
        state.native=api.bind(g,e)
        return g,e
    end)
    if not ok then report(tostring(game),false,true);return end
    local profiler,original_read,original_view,original_view_read
    original_read,original_view,original_view_read=api.read,api.view,api.view_read
    local function disable_profiler()
        profiler=nil;api.profiler=nil;api.read=original_read;api.view=original_view;api.view_read=original_view_read
        state.profiler_failures=(state.profiler_failures or 0)+1
    end
    if diagnostics and patch.profiler then
        local created,value=pcall(patch.profiler.new,api,build.revision)
        if created then profiler=value;api.profiler=value else disable_profiler() end
    end
    local function telemetry(method,...)
        if not profiler then return end
        local called,value=pcall(profiler[method],...)
        if called then return value end
        disable_profiler()
    end
    -- The update chain runs through runtime.guard (bingus_runtime.lua): the
    -- previous update runs outside pcall and its errors reach the game
    -- unchanged; after such an error below this mod it pauses (no poll, so no
    -- native command; patch.reset forgets every unit, motion history, stop,
    -- scan position and cooldown) and polls afresh once the updates below have
    -- returned on 60 frames in a row; 8 errors below in a burst stop it; the
    -- first failure survives shutdown (BingusRuntime.statuses). One exception
    -- (docs/TECHNICAL.md): a poll that raises is retried on the next poll, and
    -- 8 raised polls in a row stop the mod; a successful poll resets that
    -- count and a pause keeps it. These are mostly transient races with the
    -- game (units despawning in the middle of a read) whose real-play rate is
    -- unmeasured; counted in the guard's bursts, they could stop the mod in the
    -- middle of a mission. So the poll is caught and counted here, and only
    -- other errors in the mod's own frame reach the guard.
    local ERRORS=8
    local guard,next_poll,raised,first_raised,resumed,update_start=nil,0,0,nil,false,nil
    -- elapsed: frame time since the last poll; frame_dt: this frame's.
    local elapsed,frame_dt=math.huge,nil
    -- failure: the first failure in this mod's own words; status: its stop text.
    local failure,stop_status
    -- The mod refuses (a poll declined) or gives up (raised polls in a row).
    local function give_up(reason,status)
        failure,stop_status=failure or reason,status or reason
        guard.stop(reason)
    end
    local function poll_failed(why)
        state.retries=state.retries+1;state.last_skip=why
        raised=raised+1;if raised==1 then first_raised=why end
        if raised<ERRORS then report('waiting_for_stable_data',false)
        else give_up(first_raised,'stopped after: '..first_raised) end
    end
    -- The poll clock is the frame time the game passes to update (step keeps
    -- it), so a frame makes no Windows call to decide whether a poll is due.
    -- Without a number frame time it falls back to api.time.
    local function due()
        local dt=frame_dt;frame_dt=nil
        if type(dt)=='number' and dt>=0 and dt<3600 then
            elapsed=elapsed+dt
            if elapsed<patch.interval then return false end
            elapsed=0;return true
        end
        local now=api.time();if now<next_poll then return false end
        next_poll=now+patch.interval;return true
    end
    local function check()
        if not due() then return end
        state.polls=state.polls+1
        telemetry('begin',state)
        local called,accepted,reason,active=pcall(patch.apply,api,game,exe,state)
        if profiler then
            state.read_calls=profiler.reads-profiler.read_start
            state.read_bytes=profiler.bytes-profiler.byte_start
            telemetry('phase','logging')
        end
        if not called then poll_failed(tostring(accepted))
        elseif not accepted then give_up(tostring(reason))
        else raised=0;report(reason,active==true) end
        telemetry('finish',state);telemetry('flush',state)
    end
    -- After the updates below returned: the first frame after a pause reports
    -- the resume, then the poll runs when due.
    local function after()
        if resumed then resumed=false;report('resumed_after_60_clean_frames',false,true) end
        state.updates=state.updates+1
        telemetry('update_finished',update_start,true);update_start=nil
        check()
    end
    -- An update below raised: report once, forget what the polls learned and
    -- poll again as soon as the mod resumes. A reset that raises stops the mod.
    local function pause()
        state.pauses=(state.pauses or 0)+1
        telemetry('update_finished',nil,false)
        report('paused_after_update_error',false,true)
        next_poll,elapsed=0,math.huge;patch.reset(state)
        resumed=true
    end
    -- The guard's stop reasons in this mod's status texts.
    local function stop_text(reason)
        if reason=='stopped after '..ERRORS..' failed updates below this mod' then return 'stopped_after_'..ERRORS..'_update_errors' end
        local why=reason:match('^pause failed: (.*)$')
        return why and 'pause_failed: '..why or reason
    end
    -- At shutdown, the final status; an update below that raised right before
    -- it counts as the failure. Protected: it never raises into the chain.
    local function shut_down()
        if not failure and guard.status.first_failure=='the previous update failed' then
            failure='stopped_after_update_error';telemetry('update_finished',nil,false)
        end
        report(failure and 'stopped after: '..failure or 'stopped',false,true)
        telemetry('flush',state,true)
    end
    local function stop(reason)
        state.native=nil
        if reason=='shutdown' then
            local done,why=pcall(shut_down);if not done then state.shutdown_error=tostring(why) end
            return
        end
        local status=stop_status or stop_text(reason)
        failure=failure or status
        report(status,false,true)
        telemetry('flush',state,true)
    end
    -- The guard's line for the first of a burst of the mod's own errors (the
    -- poll is caught above) goes to the status log once. Its pause, resume and
    -- stop lines are covered by the reports above.
    local NAME='EnemyCollisionSynchronized'
    local function log(line)
        if line:sub(1,#NAME+8)==NAME..' error: ' then report(line,state.active,true) end
    end
    -- step runs before the update below, every frame while running: it keeps
    -- the frame time for the poll clock (and starts the update's timing with
    -- diagnostics).
    local function step(dt)
        frame_dt=dt
        if profiler then update_start=telemetry('update_started') end
    end
    -- The per-frame hooks stay interpreted: a trace started in them could
    -- follow their returns into every update wrapper below this mod.
    if jit and jit.off then for _,fn in ipairs({step,after,check,due}) do jit.off(fn) end end
    guard=runtime.guard({name=NAME,step=step,after=after,stop=stop,pause=pause,log=log,env=_G}).install()
    report('waiting_for_mission',false,true)
end

end)()
patch.profiler = profiler
install_loader(create_api, patch, {revision = 'v2.13.0-26088801', exe_sha256 = '0ACC07DEBE04714AE04281E1A66BD2EB9D3D85232953E32A93C8A3DD0874EABE', game_sha256 = '6D1D4D3BC6FC84801D9F8F1B310E13A603D07409F3D9495D74B42E1D0BB1C08F'}, runtime, runtime_memory)
