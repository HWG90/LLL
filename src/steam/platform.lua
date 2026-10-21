-- Steam Lua 5.1 transport. The native helper uses no Lua state layout or hooks.
local P = {}
local release=type(LLL_STEAM_SERVICE)=='table' and LLL_STEAM_SERVICE.release
P.revision=type(release)=='string' and #release<=96 and release:match('^[%w][%w%._%-]*$') and release or 'R31-steam-lua51-candidate'
P.runtime, P.native_ffi = 'Lua 5.1', false
P.source_notifications=true
local sr = assert(stingray, 'Stingray runtime unavailable')
local base = assert(os.getenv('LOCALAPPDATA'), 'LOCALAPPDATA unavailable') .. '/LLL/Helldivers2'
local function read(path, limit)
    local file = io.open(path, 'rb')
    if not file then return end
    local size = file:seek('end')
    if not size or size > (limit or 67108864) then file:close(); return end
    file:seek('set', 0)
    local value = file:read('*a'); file:close()
    return value
end
local function u32(bytes, at)
    assert(type(bytes) == 'string' and at >= 1 and at + 3 <= #bytes, 'Truncated filesystem reply')
    local a,b,c,d = bytes:byte(at, at + 3)
    return a + b * 256 + c * 65536 + d * 16777216
end
local function integer(value)
    assert(value >= 0 and value < 4294967296 and value == math.floor(value), 'Invalid filesystem integer')
    return string.char(value % 256, math.floor(value / 256) % 256,
        math.floor(value / 65536) % 256, math.floor(value / 16777216) % 256)
end
local function text(bytes, at)
    local length = u32(bytes, at)
    assert(at + 3 + length <= #bytes, 'Truncated filesystem string')
    return bytes:sub(at + 4, at + 3 + length), at + 4 + length
end
local transport=LLL_STEAM_TRANSPORT(LLL_STEAM_SERVICE)
P.transport_failure=transport.failure
P.on_transport_failure=transport.on_failure
local proof=transport.exchange(integer(0)..integer(0)..integer(0))
assert(u32(proof, 1) == 0 and u32(proof, 5) == 0, 'Steam filesystem helper refused this game build')
local pid = u32(proof, 9)
assert(pid == sr.Application.process_id(), 'Filesystem proof belongs to another process')
local position
P.exe, position = text(proof, 13)
P.root = text(proof, position)
P.data, P.local_app_data = P.root .. '/data', os.getenv('LOCALAPPDATA')
local sequence = 0
local function call(operation, path, bytes)
    assert(type(path) == 'string' and #path > 0 and #path <= 32760 and not path:find('%z'), 'Invalid filesystem path')
    sequence = sequence % 4294967295 + 1
    local reply=transport.exchange(integer(sequence)..integer(operation)..integer(#path)..path..(bytes or ''))
    assert(u32(reply, 1) == sequence, 'Stale filesystem response')
    return u32(reply, 5), reply
end
P.screenshot_directory=base..'/Screenshots'
P.screenshot_session=LLL_STEAM_SERVICE.pipe
local function screenshot_reply(status,reply)
    if status~=0 then return nil,string.format('Screenshot request refused (0x%08x)',status)end
    assert(#reply>=36,'Truncated screenshot reply')
    local states={'pending','succeeded','failed','cancelled'}
    local state=states[u32(reply,9)]
    assert(state,'Invalid screenshot state')
    local id,at=text(reply,29)
    local path;path,at=text(reply,at)
    assert(at==#reply+1,'Trailing screenshot reply bytes')
    return {state=state,error=u32(reply,13),width=u32(reply,17),height=u32(reply,21),
        elapsed_ms=u32(reply,25),id=id,output_path=path}
end
function P.screenshot_request(path)return screenshot_reply(call(13,path))end
function P.screenshot_status(id)return screenshot_reply(call(14,id))end
function P.screenshot_cancel(id)return screenshot_reply(call(15,id))end
P.read = read
function P.write(path, bytes) return call(5, path, bytes) == 0 end
function P.mkdir(path) return call(3, path) == 0 end
function P.guard()
    return {supported=true, reason=nil, exe_sha256=LLL_STEAM_BUILDS.exe_sha256,
        game_sha256=LLL_STEAM_BUILDS.game_sha256, lua_sha256='embedded Lua 5.1',
        jit_supported=false, lua_runtime='Lua 5.1', native_ffi=false}
end
function P.now() return sr.Application.time_since_launch() end
local function stamp(reply, at)
    return string.format('%08x%08x:%08x%08x', u32(reply, at), u32(reply, at + 4), u32(reply, at + 8), u32(reply, at + 12))
end
function P.stat(path)
    local status, reply = call(2, path)
    if status ~= 0 or math.floor(u32(reply, 9) / 16) % 2 == 1 then return end
    return stamp(reply, 13)
end
function P.files(directory, pattern)
    local status, reply = call(1, directory)
    local files, stamps, directories = {}, {}, {}
    if status ~= 0 then return files, stamps, directories, status end
    local at = 9
    local match = pattern and ('^' .. pattern:gsub('([%^%$%(%)%%%.%[%]%+%-])', '%%%1'):gsub('%*', '.*'):gsub('%?', '.') .. '$')
    while at <= #reply do
        local attributes, value = u32(reply, at), stamp(reply, at + 4)
        local name; name, at = text(reply, at + 20)
        if math.floor(attributes / 16) % 2 == 1 then directories[#directories + 1] = name
        elseif not match or name:match(match) then files[#files + 1] = name; stamps[name] = value end
    end
    return files, stamps, directories, 0
end
function P.directories(directory) local _,_,directories = P.files(directory); return directories end
local watches, generations, last_poll = {}, {}, -1
function P.changed(directory)
    local watch = watches[directory]
    if not watch then
        local status, reply = call(4, directory)
        assert(status == 0, 'Cannot register filesystem notification')
        watch = {index=u32(reply, 9), generation=0}; watches[directory] = watch
        last_poll = -1
    end
    local now = P.now()
    if now < last_poll or now - last_poll >= 0.45 then
        local status,reply=call(8,'poll');assert(status==0,'Filesystem event check failed');last_poll=now
        local bytes=reply:sub(9)
        assert(u32(bytes, 1) == pid, 'Filesystem events belong to another process')
        local count = u32(bytes, 5)
        assert(count <= 256 and #bytes == 8 + count * 4, 'Invalid filesystem event state')
        generations = {}
        for index = 1, count do generations[index] = u32(bytes, 5 + index * 4) end
    end
    local current = generations[watch.index] or 1
    local changed = current ~= watch.generation
    watch.generation = current
    return changed
end
function P.close_watches() assert(call(9,'close')==0);watches,generations,last_poll={},{},-1 end
function P.unwatch(path)
    local status=call(7,path)
    if status==0 then watches[path]=nil;last_poll=-1 end
    return status==0
end
local pointer={}
local function signed(bytes,at)
    local value=u32(bytes,at)
    return value>=2147483648 and value-4294967296 or value
end
function P.pointer_snapshot()
    local status,reply=call(10,'pointer')
    assert(status==0 and #reply==36,'Pointer service unavailable')
    pointer.valid=u32(reply,9)==1
    pointer.x,pointer.y=signed(reply,13),signed(reply,17)
    pointer.width,pointer.height=u32(reply,21),u32(reply,25)
    pointer.buttons,pointer.wheel=u32(reply,29),signed(reply,33)
    return pointer
end
function P.release_pointer() return call(11,'pointer')==0 end
local camera_pointer={}
function P.camera_snapshot()
    local status,reply=call(12,'pointer-v1')
    assert(status==0 and #reply==44,'Relative pointer service unavailable')
    camera_pointer.valid=u32(reply,9)==1
    camera_pointer.x,camera_pointer.y=signed(reply,13),signed(reply,17)
    camera_pointer.width,camera_pointer.height=u32(reply,21),u32(reply,25)
    camera_pointer.buttons,camera_pointer.wheel=u32(reply,29),signed(reply,33)
    camera_pointer.dx,camera_pointer.dy=signed(reply,37),signed(reply,41)
    return camera_pointer
end
-- Exact helper ABI 16-18. Preparing reserves cleanup authority before any I/O;
-- only a matching release acknowledgement retires that private authority.
local keyboard_mask=('00331f08ffe1ff03feffff27fffffff7ff0003003f0000fc010000f804000000'):gsub('%x%x',function(value)return string.char(tonumber(value,16))end)
P.keyboard_capture_mask=keyboard_mask
P.keyboard_scope='registered gameplay key whitelist; F12/Win/system shortcuts excluded'
local keyboard_owner,keyboard_client=nil,0
local function keyboard_owned(handle)
    return handle~=nil and keyboard_owner and keyboard_owner.handle==handle and keyboard_owner
end
local function keyboard_error(status)
    return string.format('Keyboard request refused (0x%08x)',status)
end
function P.keyboard_prepare()
    if keyboard_owner then return nil,'Keyboard request already owned or restoring' end
    if keyboard_client>=4294967295 then return nil,'Keyboard client IDs exhausted' end
    keyboard_client=keyboard_client+1
    local handle={}
    keyboard_owner={handle=handle,client=keyboard_client,generation=0,attempted=false,sample={}}
    return handle
end
function P.keyboard_acquire(handle)
    local current=keyboard_owned(handle)
    if not current then return false,'Keyboard request not owned' end
    if current.attempted then return current.accepted==true,current.reason end
    current.attempted=true -- An exchange failure may follow native registration.
    local ok,accepted,why=pcall(function()
        local status,reply=call(16,'keyboard-v1',integer(1)..integer(current.client)..keyboard_mask)
        if status~=0 then return false,keyboard_error(status) end
        assert(#reply==56 and u32(reply,9)==1 and u32(reply,13)==current.client,'Invalid keyboard acquisition acknowledgement')
        local generation,state=u32(reply,17),u32(reply,21)
        assert(generation>0 and state>=1 and state<=5,'Invalid keyboard generation or state')
        assert(reply:sub(25,56)==keyboard_mask,'Keyboard capture mask changed')
        current.generation=generation
        if state~=1 and state~=2 then return false,'Keyboard acquisition inactive (state '..state..')' end
        return true
    end)
    if not ok then why=tostring(accepted);accepted=false end
    current.accepted,current.reason=accepted==true,why
    return current.accepted,why
end
function P.keyboard_snapshot(handle,mode)
    local current=keyboard_owned(handle)
    if not current then return nil,'Keyboard request not owned' end
    if not current.accepted or current.generation==0 then return nil,current.reason or 'Keyboard acquisition unacknowledged' end
    local value=mode=='menu'and 0 or mode=='camera'and 1
    if value==nil then return nil,'Unsupported keyboard pointer mode' end
    local ok,result,why=pcall(function()
        local status,reply=call(17,'keyboard-v1',integer(current.client)..integer(current.generation)..integer(value))
        if status~=0 then return nil,keyboard_error(status) end
        assert(#reply==88 and u32(reply,45)==1 and u32(reply,49)==current.generation,'Invalid keyboard snapshot acknowledgement')
        local state=u32(reply,53)
        assert(state>=1 and state<=5,'Invalid keyboard snapshot state')
        local sample=current.sample
        sample.valid=u32(reply,9)==1
        sample.x,sample.y=signed(reply,13),signed(reply,17)
        sample.width,sample.height=u32(reply,21),u32(reply,25)
        sample.buttons,sample.wheel=u32(reply,29),signed(reply,33)
        sample.dx,sample.dy=signed(reply,37),signed(reply,41)
        sample.keyboard_active=state==2
        sample.keyboard_state,sample.keyboard_generation=state,current.generation
        sample.keyboard_keys,sample.keyboard_mask=reply:sub(57,88),keyboard_mask
        if state>=3 then current.accepted=false;current.reason='Keyboard lease inactive (state '..state..')' end
        return sample
    end)
    if not ok then return nil,tostring(result) end
    return result,why
end
function P.keyboard_release(handle)
    local current=keyboard_owned(handle)
    if not current then return false,'Keyboard request not owned' end
    local ok,released,why=pcall(function()
        local status,reply=call(18,'keyboard-v1',integer(current.client)..integer(current.generation))
        if status~=0 then return false,keyboard_error(status) end
        assert(#reply==20 and u32(reply,9)==1 and u32(reply,13)==current.client,'Invalid keyboard release acknowledgement')
        local generation=u32(reply,17)
        assert(current.generation==0 or generation==current.generation,'Stale keyboard release generation')
        return true
    end)
    if not ok then why=tostring(released);released=false end
    if released==true then keyboard_owner=nil;return true end
    current.reason=why or 'Keyboard restoration unacknowledged'
    return false,current.reason
end
function P.hash(bytes)
    local status, reply = call(6, 'hash', bytes)
    assert(status == 0 and #reply == 16, 'Resource hashing failed')
    return string.format('%08x%08x', u32(reply, 13), u32(reply, 9))
end
function P.archive(path)
    local file = io.open(path, 'rb')
    if not file then return end
    local size = file:seek('end')
    if not size or size > 67108864 then file:close(); return end
    file:seek('set', 0)
    local reader = {size=size, bytes=0, reads=0}
    function reader.read(at, count)
        assert(file and at >= 0 and count >= 0 and at + count <= size, 'Invalid archive read')
        assert(file:seek('set', at))
        local value = file:read(count)
        reader.reads = reader.reads + 1; reader.bytes = reader.bytes + (value and #value or 0)
        return value
    end
    function reader.close() if file then file:close(); file=nil end end
    return reader
end
P.live, P.settings, P.log_directory = base .. '/Mods', base .. '/Settings', base .. '/Logs'
for _, directory in ipairs({P.live, P.settings, P.log_directory}) do assert(P.mkdir(directory)) end
P.loader_config, P.migrated_config = base .. '/LLL.cfg', base .. '/MDL.cfg'
P.mdl_config = P.local_app_data .. '/MDL/Helldivers2/MDL.cfg'
P.roots = {{kind='lll',path=P.live}, {kind='mdl',path=P.local_app_data .. '/MDL/Helldivers2/Mods'},
    {kind='bingus',path=P.local_app_data .. '/CowboyBingus/Helldivers2/Mods'},
    {kind='bingus',path=P.local_app_data .. '/CowboyBingus/Helldivers2'},
    {kind='previous',path=P.local_app_data .. '/LiveLuaLoader/Helldivers2/Mods'}}
function P.open_log(name)
    if type(name) ~= 'string' or not name:match('^[%w_-]+%.log$') then return end
    return io.open(P.log_directory .. '/' .. name, 'wb')
end
return P
