-- Windows x64 filesystem transport; never reads or writes another process.
local ffi = require("ffi")
local bit = require("bit")
ffi.cdef([[
typedef struct {uint32_t attr;uint32_t times[6];uint32_t high;uint32_t low;uint32_t reserved[2];char name[260];char alternate[14];} LLLP_FIND_DATA_V1;
typedef struct {uint32_t attr;uint32_t times[6];uint32_t high;uint32_t low;} LLLP_FILE_ATTRIBUTES_V1;
int LLLP_lll_file_attributes(const char *,int,void *) __asm__("GetFileAttributesExA");
void *LLLP_lll_watch(const char *,int,uint32_t) __asm__("FindFirstChangeNotificationA");
int LLLP_lll_watch_next(void *) __asm__("FindNextChangeNotification");
int LLLP_lll_watch_close(void *) __asm__("FindCloseChangeNotification");
uint32_t LLLP_lll_wait(void *,uint32_t) __asm__("WaitForSingleObject");
uint32_t LLLP_lll_error(void) __asm__("GetLastError");
void *LLLP_FindFirstFileA(const char *, LLLP_FIND_DATA_V1 *) __asm__("FindFirstFileA");
int LLLP_FindNextFileA(void *, LLLP_FIND_DATA_V1 *) __asm__("FindNextFileA"); int LLLP_FindClose(void *) __asm__("FindClose");
uint32_t LLLP_lll_tick_count(void) __asm__("GetTickCount");
uint32_t LLLP_GetModuleFileNameA(void *,char *,uint32_t) __asm__("GetModuleFileNameA");
void *LLLP_GetModuleHandleA(const char *) __asm__("GetModuleHandleA"); int LLLP_CreateDirectoryA(const char *,void *) __asm__("CreateDirectoryA");
void *LLLP_CreateFileA(const char *,uint32_t,uint32_t,void *,uint32_t,uint32_t,void *) __asm__("CreateFileA");
int LLLP_GetFileSizeEx(void *,int64_t *) __asm__("GetFileSizeEx");int LLLP_ReadFile(void *,void *,uint32_t,uint32_t *,void *) __asm__("ReadFile");
int LLLP_SetFilePointerEx(void *,int64_t,int64_t *,uint32_t) __asm__("SetFilePointerEx");
int LLLP_CloseHandle(void *) __asm__("CloseHandle");int LLLP_WriteFile(void *,const void *,uint32_t,uint32_t *,void *) __asm__("WriteFile");
int LLLP_MoveFileExA(const char *,const char *,uint32_t) __asm__("MoveFileExA");int LLLP_DeleteFileA(const char *) __asm__("DeleteFileA");
]])
local library = ffi.load("kernel32")
local k = {}
for _, name in ipairs({"LLLP_lll_file_attributes","LLLP_lll_watch","LLLP_lll_watch_next","LLLP_lll_watch_close","LLLP_lll_wait","LLLP_lll_error","LLLP_FindFirstFileA","LLLP_FindNextFileA","LLLP_FindClose","LLLP_lll_tick_count","LLLP_GetModuleFileNameA","LLLP_GetModuleHandleA","LLLP_CreateDirectoryA","LLLP_CreateFileA","LLLP_GetFileSizeEx","LLLP_ReadFile","LLLP_SetFilePointerEx","LLLP_CloseHandle","LLLP_WriteFile","LLLP_MoveFileExA","LLLP_DeleteFileA"}) do k[name] = library[name] end
local invalid = ffi.cast("void *", -1)
-- Other mods may have declared these exports with their own struct typedef.
-- Rebind the ABI with an opaque buffer pointer to avoid FFI type-name conflicts.
local find_first = ffi.cast("void *(*)(const char *, void *)", k.LLLP_FindFirstFileA)
local find_next = ffi.cast("int (*)(void *, void *)", k.LLLP_FindNextFileA)
local P = {}
local watches, absent = {}, {}
local watch_attributes = ffi.new("LLLP_FILE_ATTRIBUTES_V1[1]")
function P.changed(directory)
    local handle = watches[directory]
    if not handle then
        if absent[directory] and k.LLLP_lll_file_attributes(directory, 0, watch_attributes) == 0 then
            local error = k.LLLP_lll_error()
            if error == 2 or error == 3 then
                return false
            end
        end
        handle = k.LLLP_lll_watch(directory, 1, 31)
        if handle == invalid then
            local error = k.LLLP_lll_error()
            if error == 2 or error == 3 then
                local was = absent[directory]
                absent[directory] = true
                return not was
            end
            return true
        end
        absent[directory] = nil
        watches[directory] = handle
        return true
    end
    local result = k.LLLP_lll_wait(handle, 0)
    if result == 258 then
        return false
    end
    if result ~= 0 or k.LLLP_lll_watch_next(handle) == 0 then
        k.LLLP_lll_watch_close(handle)
        watches[directory] = nil
    end
    return true
end
function P.close_watches()
    for path, handle in pairs(watches) do
        k.LLLP_lll_watch_close(handle)
        watches[path] = nil
    end
end
function P.now()
    return k.LLLP_lll_tick_count() / 1000
end
local attributes = ffi.new("LLLP_FILE_ATTRIBUTES_V1[1]")
function P.stat(path)
    if k.LLLP_lll_file_attributes(path, 0, attributes) == 0 or bit.band(attributes[0].attr, 16) ~= 0 then
        return nil
    end
    return string.format(
        "%08x%08x:%08x%08x",
        tonumber(attributes[0].high),
        tonumber(attributes[0].low),
        tonumber(attributes[0].times[5]),
        tonumber(attributes[0].times[4])
    )
end
function P.read(path, limit)
    local f = k.LLLP_CreateFileA(path, 0x80000000, 7, nil, 3, 128, nil)
    if f == invalid then
        return nil
    end
    local size = ffi.new("int64_t[1]")
    local result
    if k.LLLP_GetFileSizeEx(f, size) ~= 0 and size[0] >= 0 and size[0] <= (limit or 67108864) then
        local n = tonumber(size[0])
        local buf = ffi.new("uint8_t[?]", math.max(n, 1))
        local got = ffi.new("uint32_t[1]")
        if k.LLLP_ReadFile(f, buf, n, got, nil) ~= 0 and got[0] == n then
            result = ffi.string(buf, n)
        end
    end
    k.LLLP_CloseHandle(f)
    return result
end
-- Keep one handle per archive and read only the index and declaration prefixes.
function P.archive(path)
    local f = k.LLLP_CreateFileA(path, 0x80000000, 7, nil, 3, 128, nil)
    if f == invalid then
        return nil
    end
    local size = ffi.new("int64_t[1]")
    if k.LLLP_GetFileSizeEx(f, size) == 0 or size[0] < 0 or size[0] > 67108864 then
        k.LLLP_CloseHandle(f)
        return nil
    end
    local reader = { size = tonumber(size[0]) }
    local closed = false
    local got = ffi.new("uint32_t[1]")
    local capacity = 4096
    local buffer = ffi.new("uint8_t[4096]")
    local n = math.min(capacity, reader.size)
    local head
    if k.LLLP_ReadFile(f, buffer, n, got, nil) ~= 0 and got[0] == n then
        head = ffi.string(buffer, n)
    end
    if not head then
        k.LLLP_CloseHandle(f)
        return nil
    end
    reader.bytes = n
    reader.reads = 1
    function reader.read(offset, n)
        assert(
            not closed and offset >= 0 and n >= 0 and offset + n <= reader.size,
            "Invalid archive read"
        )
        if offset + n <= #head then
            return string.sub(head, offset + 1, offset + n)
        end
        if n > capacity then
            buffer = ffi.new("uint8_t[?]", n)
            capacity = n
        end
        if
            k.LLLP_SetFilePointerEx(f, offset, nil, 0) == 0
            or k.LLLP_ReadFile(f, buffer, n, got, nil) == 0
            or got[0] ~= n
        then
            return nil
        end
        reader.bytes = reader.bytes + n
        reader.reads = reader.reads + 1
        return ffi.string(buffer, n)
    end
    function reader.close()
        if not closed then
            closed = true
            k.LLLP_CloseHandle(f)
        end
    end
    return reader
end
function P.files(directory, pattern)
    local result, stamps, dirs = {}, {}, {}
    local data = ffi.new("LLLP_FIND_DATA_V1[1]")
    local f = find_first(directory .. "/" .. (pattern or "*"), data)
    if f == invalid then
        return result
    end
    repeat
        if bit.band(data[0].attr, 16) == 0 then
            local name = ffi.string(data[0].name)
            result[#result + 1] = name
            stamps[name] = string.format(
                "%08x%08x:%08x%08x",
                tonumber(data[0].high),
                tonumber(data[0].low),
                tonumber(data[0].times[5]),
                tonumber(data[0].times[4])
            )
        else
            local name = ffi.string(data[0].name)
            if name ~= "." and name ~= ".." then
                dirs[#dirs + 1] = name
            end
        end
    until find_next(f, data) == 0
    k.LLLP_FindClose(f)
    return result, stamps, dirs
end
local path = ffi.new("char[32768]")
local n = k.LLLP_GetModuleFileNameA(nil, path, 32768)
assert(n > 0 and n < 32768, "Cannot resolve game executable")
P.exe = ffi.string(path, n)
P.root = assert(string.match(P.exe, "^(.*)[/\\]bin[/\\][^/\\]+$"), "Unexpected game layout")
P.data = P.root .. "/data"
function P.guard()
    local module = k.LLLP_GetModuleHandleA("game.dll")
    assert(module ~= nil, "game.dll unavailable")
    local b = ffi.cast("uint8_t *", module)
    assert(b[0] == 77 and b[1] == 90, "Invalid game.dll PE")
    local offset = tonumber(ffi.cast("uint32_t *", b + 60)[0])
    assert(offset < 4096 and ffi.cast("uint32_t *", b + offset)[0] == 0x4550, "Invalid PE header")
    assert(
        tonumber(ffi.cast("uint32_t *", b + offset + 8)[0]) == 1790161983,
        "Unsupported game build"
    )
end
local base = os.getenv("LOCALAPPDATA")
if base then
    P.local_app_data = base
    P.roots = {
        { kind = "lll", path = base .. "/LLL/Helldivers2/Mods" },
        { kind = "mdl", path = base .. "/MDL/Helldivers2/Mods" },
        { kind = "bingus", path = base .. "/CowboyBingus/Helldivers2/Mods" },
        { kind = "bingus", path = base .. "/CowboyBingus/Helldivers2" },
        { kind = "previous", path = base .. "/LiveLuaLoader/Helldivers2/Mods" },
    }
    P.loader_config = base .. "/LLL/Helldivers2/LLL.cfg"
    P.migrated_config = base .. "/LLL/Helldivers2/MDL.cfg"
    P.mdl_config = base .. "/MDL/Helldivers2/MDL.cfg"
    for _, segment in ipairs({ "LLL", "Helldivers2" }) do
        base = base .. "/" .. segment
        k.LLLP_CreateDirectoryA(base, nil)
    end
    P.live = base .. "/Mods"
    k.LLLP_CreateDirectoryA(P.live, nil)
    P.settings = base .. "/Settings"
    k.LLLP_CreateDirectoryA(P.settings, nil)
    base = base .. "/Logs"
    k.LLLP_CreateDirectoryA(base, nil)
    P.log_directory = base
end
function P.directories(directory)
    local result = {}
    local data = ffi.new("LLLP_FIND_DATA_V1[1]")
    local f = find_first(directory .. "/*", data)
    if f == invalid then
        return result
    end
    repeat
        local name = ffi.string(data[0].name)
        if bit.band(data[0].attr, 16) ~= 0 and name ~= "." and name ~= ".." then
            result[#result + 1] = name
        end
    until find_next(f, data) == 0
    k.LLLP_FindClose(f)
    return result
end
function P.write(path, value)
    local temporary = path .. ".tmp"
    local f = k.LLLP_CreateFileA(temporary, 0x40000000, 0, nil, 2, 128, nil)
    if f == invalid then
        return false
    end
    local got = ffi.new("uint32_t[1]")
    local ok = k.LLLP_WriteFile(f, value, #value, got, nil) ~= 0 and got[0] == #value
    k.LLLP_CloseHandle(f)
    if not ok then
        k.LLLP_DeleteFileA(temporary)
        return false
    end
    return k.LLLP_MoveFileExA(temporary, path, 9) ~= 0
end
function P.open_log(name)
    if not base or type(name) ~= "string" or not string.match(name, "^[%w_-]+%.log$") then
        return nil
    end
    local f = k.LLLP_CreateFileA(base .. "/" .. name, 0x40000000, 1, nil, 2, 128, nil)
    if f == invalid then
        return nil
    end
    local closed = false
    local out = {}
    function out:write(...)
        if closed then
            return nil
        end
        for i = 1, select("#", ...) do
            local value = tostring(select(i, ...))
            local got = ffi.new("uint32_t[1]")
            if k.LLLP_WriteFile(f, value, #value, got, nil) == 0 or got[0] ~= #value then
                return nil
            end
        end
        return self
    end
    function out:flush()
        return not closed
    end
    function out:close()
        if not closed then
            closed = true
            k.LLLP_CloseHandle(f)
        end
        return true
    end
    return out
end

-- Health reader facade uses private, cached Windows signatures.
P.health = {ffi=ffi,kernel={FindFirstFileA=find_first,FindNextFileA=find_next,
    FindClose=k.LLLP_FindClose,GetLastError=k.LLLP_lll_error,GetModuleHandleA=k.LLLP_GetModuleHandleA}}
return P
