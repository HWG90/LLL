local runtime=(function()
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
local runtime_memory=(function()
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
local base=(function()
return function()
    local ffi = require('ffi')
    assert(ffi.abi('64bit'), 'Windows x64 is required')
    -- Every Windows function has a private name (an __asm__ label naming the
    -- real export). LuaJIT keeps the first prototype declared for a name in the
    -- whole shared state: another mod's declaration of the real names cannot
    -- change the prototypes this mod calls with, and this mod leaves the real
    -- names to the mods that declare them.
    ffi.cdef [[
        void *hd2apc_GetModuleHandleA(const char *name) __asm__("GetModuleHandleA");
        uint32_t hd2apc_GetModuleFileNameW(void *module, uint16_t *path, uint32_t capacity)
            __asm__("GetModuleFileNameW");
        void *hd2apc_GetCurrentProcess(void) __asm__("GetCurrentProcess");
        int hd2apc_ReadProcessMemory(void *process, const void *address, void *buffer, size_t size,
                                     size_t *read) __asm__("ReadProcessMemory");
        int hd2apc_ReadProcessMemoryTo(void *process, uint64_t address, uint64_t buffer, size_t size,
                                       uint32_t *read) __asm__("ReadProcessMemory");
        void *hd2apc_CreateFileW(const uint16_t *path, uint32_t access, uint32_t share, void *security,
                                 uint32_t disposition, uint32_t flags, void *template_file) __asm__("CreateFileW");
        int hd2apc_ReadFile(void *file, void *buffer, uint32_t size, uint32_t *read, void *overlapped)
            __asm__("ReadFile");
        int hd2apc_CloseHandle(void *handle) __asm__("CloseHandle");
        int32_t hd2apc_BCryptOpenAlgorithmProvider(void **algorithm, const uint16_t *name,
                                                   const uint16_t *provider, uint32_t flags)
            __asm__("BCryptOpenAlgorithmProvider");
        int32_t hd2apc_BCryptCloseAlgorithmProvider(void *algorithm, uint32_t flags)
            __asm__("BCryptCloseAlgorithmProvider");
        int32_t hd2apc_BCryptCreateHash(void *algorithm, void **hash, void *object, uint32_t object_size,
                                        const void *secret, uint32_t secret_size, uint32_t flags)
            __asm__("BCryptCreateHash");
        int32_t hd2apc_BCryptHashData(void *hash, const void *data, uint32_t size, uint32_t flags)
            __asm__("BCryptHashData");
        int32_t hd2apc_BCryptFinishHash(void *hash, void *digest, uint32_t size, uint32_t flags)
            __asm__("BCryptFinishHash");
        int32_t hd2apc_BCryptDestroyHash(void *hash) __asm__("BCryptDestroyHash");
    ]]
    local kernel, bcrypt = ffi.load('kernel32'), ffi.load('bcrypt')
    local process = kernel.hd2apc_GetCurrentProcess()
    -- ReadProcessMemoryTo is the same export with the address and destination
    -- as uint64_t (the same register as a pointer on x64) and the byte count
    -- read back as two 32-bit words: a call creates no pointer or 64-bit cdata.
    local read_to = kernel.hd2apc_ReadProcessMemoryTo
    local copied = ffi.new('uint32_t[2]')
    local api = {}

    function api.module(name)
        local handle = kernel.hd2apc_GetModuleHandleA(name)
        if handle == nil then return nil end
        return ffi.cast('uint8_t *', handle)
    end

    -- read(address, size) returns the bytes as a string. read(address, size,
    -- into, offset) copies them into a caller buffer {data, address, size} at
    -- offset and returns true; address is a number and nothing is allocated,
    -- which is what the per-frame state check uses.
    function api.read(address, size, into, offset)
        if into then
            offset = offset or 0
            if type(address) ~= 'number' or offset < 0 or offset + size > into.size then return nil end
            if read_to(process, address, into.address + offset, size, copied) == 0
                or copied[0] ~= size or copied[1] ~= 0 then return nil end
            return true
        end
        local buffer, count = ffi.new('uint8_t[?]', size), ffi.new('size_t[1]')
        if kernel.hd2apc_ReadProcessMemory(process, address, buffer, size, count) == 0 or count[0] ~= size then -- lint-ok: R14 Know Your Constellation copies this reader
            return nil
        end
        return ffi.string(buffer, size)
    end

    function api.pointer(bytes, offset)
        offset = offset or 0
        if not bytes or offset < 0 or offset + 8 > #bytes then return nil end
        local value = ffi.new('uintptr_t[1]')
        ffi.copy(value, bytes:sub(offset + 1, offset + 8), 8)
        if value[0] < 0x10000 or value[0] >= 0x800000000000 then return nil end
        return ffi.cast('uint8_t *', value[0])
    end

    function api.module_hash(module)
        local path = ffi.new('uint16_t[32768]')
        local length = kernel.hd2apc_GetModuleFileNameW(module, path, 32768)
        assert(length > 0 and length < 32768, 'Cannot resolve module file')
        local file = kernel.hd2apc_CreateFileW(path, 0x80000000, 7, nil, 3, 0x08000000, nil)
        assert(file ~= ffi.cast('void *', -1), 'Cannot read module file')
        local algorithm, hash = ffi.new('void *[1]'), ffi.new('void *[1]')
        local ok, result = pcall(function()
            local name = ffi.new('uint16_t[7]', {83, 72, 65, 50, 53, 54, 0})
            assert(bcrypt.hd2apc_BCryptOpenAlgorithmProvider(algorithm, name, nil, 0) == 0, 'SHA256 unavailable')
            assert(bcrypt.hd2apc_BCryptCreateHash(algorithm[0], hash, nil, 0, nil, 0, 0) == 0, 'SHA256 creation failed')
            local buffer, count = ffi.new('uint8_t[1048576]'), ffi.new('uint32_t[1]')
            while true do
                assert(kernel.hd2apc_ReadFile(file, buffer, 1048576, count, nil) ~= 0, 'Module file read failed')
                if count[0] == 0 then break end
                assert(bcrypt.hd2apc_BCryptHashData(hash[0], buffer, count[0], 0) == 0, 'SHA256 update failed')
            end
            local digest, hex = ffi.new('uint8_t[32]'), {}
            assert(bcrypt.hd2apc_BCryptFinishHash(hash[0], digest, 32, 0) == 0, 'SHA256 finish failed')
            for i = 0, 31 do hex[#hex + 1] = string.format('%02X', digest[i]) end
            return table.concat(hex)
        end)
        if hash[0] ~= nil then bcrypt.hd2apc_BCryptDestroyHash(hash[0]) end
        if algorithm[0] ~= nil then bcrypt.hd2apc_BCryptCloseAlgorithmProvider(algorithm[0], 0) end
        kernel.hd2apc_CloseHandle(file)
        if not ok then error(result) end
        return result
    end
    return api
end

end)()
local platform=(function()
return function(base)
    local ffi=require('ffi')
    -- Private names with __asm__ labels, as in read_api.lua: another mod's
    -- declaration of the real names cannot change these prototypes.
    ffi.cdef[[
        uint64_t hd2apc_GetTickCount64(void) __asm__("GetTickCount64");
        uint32_t hd2apc_GetTickCount(void) __asm__("GetTickCount");
        uint32_t hd2apc_GetCurrentThreadId(void) __asm__("GetCurrentThreadId");
        uint32_t hd2apc_GetCurrentProcessId(void) __asm__("GetCurrentProcessId");
        int hd2apc_GetProcessTimes(void *,void *,void *,void *,void *) __asm__("GetProcessTimes");
        int hd2apc_GlobalMemoryStatusEx(void *status) __asm__("GlobalMemoryStatusEx");
        int hd2apc_K32GetProcessMemoryInfo(void *process,void *counters,uint32_t size) __asm__("K32GetProcessMemoryInfo");
    ]]
    local kernel=ffi.load('kernel32');local api=base()
    local main_thread=kernel.hd2apc_GetCurrentThreadId()
    -- GetTickCount64's 64-bit result is boxed as cdata on every interpreted
    -- call. GetTickCount returns the low 32 bits of the same tick count as a
    -- plain number; the high word is carried here (it changes every 49.7 days).
    local ticks=tonumber(kernel.hd2apc_GetTickCount64())
    local tick_high,tick_low=math.floor(ticks/4294967296),ticks%4294967296
    function api.time()
        local low=kernel.hd2apc_GetTickCount()
        if low<tick_low then tick_high=tick_high+1 end
        tick_low=low
        return (tick_high*4294967296+low)/1000
    end
    function api.assert_thread()assert(kernel.hd2apc_GetCurrentThreadId()==main_thread,'Wrong update thread')end
    local process=kernel.hd2apc_GetCurrentProcess()
    local process_times=ffi.new('uint64_t[4]')
    assert(kernel.hd2apc_GetProcessTimes(process,process_times,process_times+1,process_times+2,process_times+3)~=0)
    api.process_id=tonumber(kernel.hd2apc_GetCurrentProcessId())
    local creation_words=ffi.cast('uint32_t *',process_times)
    api.process_created_filetime_hex=string.format('%08x%08x',tonumber(creation_words[1]),tonumber(creation_words[0]))
    -- Both structures are filled by the calls below and read back through
    -- one 32-bit view each: 64-bit fields decode from two halves, so a poll
    -- creates no cdata.
    local memory=ffi.new('uint64_t[8]');local process_memory=ffi.new('uint64_t[10]')
    local memory_words=ffi.cast('uint32_t *',memory);local process_words=ffi.cast('uint32_t *',process_memory)
    local function qword(words,index)return words[index*2]+words[index*2+1]*4294967296 end
    -- Bound once; the private prototypes need no cast. Never cast per poll:
    -- anonymous function ctypes are not collected by LuaJIT, and per-poll
    -- casts exhausted its type table after about 8,163 memory polls.
    local global=kernel.hd2apc_GlobalMemoryStatusEx
    local private=kernel.hd2apc_K32GetProcessMemoryInfo
    function api.memory()
        memory_words[0]=64;process_words[0]=80
        assert(global(memory)~=0 and private(process,process_memory,80)~=0,'Memory telemetry unavailable')
        -- MEMORYSTATUSEX: available physical RAM at +16, available commit at +32.
        return qword(memory_words,2),qword(process_words,9),qword(memory_words,4)
    end
    local original=api.read
    function api.read(address,size,into,offset)
        if type(size)~='number' or size<1 or size>32768 or size%1~=0 then return nil end
        return original(address,size,into,offset)
    end
    return api
end

end)()
local dependencies=(function()
-- Read-only reproduction of the native default-attachment/package lookups.
-- Never calls the allocating configuration builders or edits preview slots.
local ffi=require('ffi')
local bit=require('bit')
local M={}
local dword=ffi.new('uint32_t[1]');local qword=ffi.new('uint64_t[1]')
local zero=string.rep('\0',8)
local function u32(b,o)ffi.copy(dword,b:sub(o+1,o+4),4);return tonumber(dword[0])end
local function raw(b,o)return b:sub(o+1,o+8)end
local function hex(b)return(b:reverse():gsub('.',function(v)return string.format('%02x',v:byte())end))end
local function unhex(s)return(s:gsub('..',function(v)return string.char(tonumber(v,16))end)):reverse()end
function M.new(api,game)
    local function read(p,n)local bytes=assert(api.read(p,n),'Dependency memory unavailable');return bytes end
    local function ptr(p)local value=assert(api.pointer(read(p,8)),'Dependency pointer unavailable');return value end
    local self={defaults={},attachments={},identity=nil,known_weapons={}}
    function self:refresh()
        local database=ptr(game+0x2ce41b8);local definitions=ptr(database+0xf148d8)
        local groups=u32(read(game+0x2e493c8,4),0)
        assert(groups>0 and groups<=64,'Attachment group bounds')
        local gp=read(game+0x31812e0,groups*8)
        local map=read(game+0x3154f90,28)
        local storage=assert(api.pointer(map));local count=u32(map,8)
        assert(count>0 and count<=262144 and bit.band(count,count-1)==0,'Package mapping bounds')
        local headers,identity={},read(database+0xf148d8,8)..gp..map
        for i=0,groups-1 do
            local h=read(assert(api.pointer(gp,i*8)),16)
            assert(u32(h,8)<=4096,'Attachment row bounds')
            headers[#headers+1]=h;identity=identity..h
        end
        if self.identity==identity then return end
        local by_number,by_hash={},{}
        local total=0
        local function package(id)
            ffi.copy(qword,id,8)
            local start=tonumber((qword[0]*u32(map,24))%count)
            for probe=0,math.min(count,256)-1 do
                local row=read(storage+((start+probe)%count)*16,16)
                if raw(row,0)==id then return raw(row,8)~=zero and hex(raw(row,8)) or nil end
                if raw(row,0)==raw(map,16)then return nil end
            end
            return nil -- Bounded unresolved lookup, never an invented package.
        end
        for _,h in ipairs(headers)do
            local n=u32(h,8);total=total+n;assert(total<=8192,'Attachment catalogue bound')
            local rows=n>0 and assert(api.pointer(h)) or nil
            for first=0,n-1,256 do
                local amount=math.min(256,n-first);local bytes=read(rows+first*88,amount*88)
                for j=0,amount-1 do
                    local o=j*88;local id=raw(bytes,o+32)
                    if id~=zero then
                        local kinds={};local kn=u32(bytes,o+56)
                        assert(kn<=16,'Attachment kind bounds')
                        if kn>0 then
                            local kb=read(assert(api.pointer(bytes,o+48)),kn*4)
                            for k=0,kn-1 do kinds[u32(kb,k*4)]=true end
                        end
                        local entry={id=hex(id),package=package(id),kinds=kinds}
                        by_number[u32(bytes,o+8)]=entry;by_hash[entry.id]=entry
                    end
                end
            end
        end
        local defaults,known={},{}
        local buckets=read(definitions,658*16)
        local fallback=read(game+0x1fc7988,320)
        for i=0,657 do
            local id=raw(buckets,i*16)
            if id~=zero then
                local index=u32(buckets,i*16+8);assert(index<329,'Weapon configuration index bounds')
                local config=read(definitions+10528+index*46600,120)
                local selected={}
                for j=0,9 do
                    local kind=u32(config,j*8)
                    if kind<1 or kind>9 then break end
                    if not selected[kind]then selected[kind]=by_number[u32(config,j*8+4)]end
                end
                local allowed={}
                for j=0,9 do local kind=u32(config,80+j*4);if kind==0 then break end;allowed[kind]=true end
                for kind=0,9 do if not selected[kind] and allowed[kind]then
                    local candidate=by_number[u32(fallback,kind*32)]
                    if candidate and candidate.kinds[kind]then selected[kind]=candidate end
                end end
                local entries={}
                for kind=0,9 do if selected[kind]then entries[#entries+1]=selected[kind].id end end
                defaults[hex(id)]=entries;known[hex(id)]=true
            end
        end
        self.defaults,self.attachments,self.known_weapons=defaults,by_hash,known
        self.identity=identity
    end
    function self:resolve(item)
        local result,seen={},{}
        local function add(ids)
            for _,id in ipairs(ids or {})do
                local a=self.attachments[id]
                if a and a.package and not seen[a.package]then
                    seen[a.package]=true;result[#result+1]=a.package
                end
            end
        end
        add(self.defaults[item.id]);add(item.attachments)
        return result
    end
    function self:queued()
        local p=ptr(game+0x2e38190);local ring=read(p+50448,8+128*200)
        local head,tail=u32(ring,0),u32(ring,4)
        assert(head<128 and tail<128,'Weapon queue bounds')
        local rows={}
        while head~=tail do
            local o=8+head*200;local n=u32(ring,o+80);assert(n<=10,'Weapon dependency count')
            local id=hex(raw(ring,o+64));local attachments,seen={},{}
            for j=0,n-1 do
                local a=hex(raw(ring,o+88+j*8))
                if self.attachments[a] and not seen[a]then attachments[#attachments+1]=a;seen[a]=true end
            end
            if self.known_weapons[id]then rows[id]=attachments end
            head=(head+1)%128
        end
        return rows
    end
    return self
end
return M

end)()
local native=(function()
-- The only game mutations are balanced calls to the game's package lease API.
-- All thumbnail cards, render targets, queues and executable bytes remain owned
-- and updated by the game. Layouts are specific to the fingerprinted build.
local ffi=require('ffi')
local bit=require('bit')
local M={}
local word=ffi.new('uint32_t[1]')
local pointer_value=ffi.new('uintptr_t[1]')
local function pointer_key(p)
    pointer_value[0]=ffi.cast('uintptr_t',p);return ffi.string(pointer_value,8)
end
local zero=string.rep('\0',8)
local function u32(s,o) assert(s and o+4<=#s,'Short field');ffi.copy(word,s:sub(o+1,o+4),4);return tonumber(word[0])end
local function raw64(s,o) assert(s and o+8<=#s,'Short identifier');return s:sub(o+1,o+8)end
local function hex(s) return (s:reverse():gsub('.',function(c)return string.format('%02x',c:byte())end))end
local function unhex(s)
    assert(type(s)=='string' and #s==16 and not s:find('[^0-9a-f]'),'Invalid identifier')
    return (s:gsub('..',function(c)return string.char(tonumber(c,16))end)):reverse()
end
M.hex,M.unhex=hex,unhex

-- The lease table's 1024 rows (16 bytes each: identifier, 64-bit count), read
-- into one reused buffer and decoded in place.
local LEASE_ROWS=ffi.new('uint32_t[4096]')
local LEASE_BUFFER={address=tonumber(ffi.cast('uintptr_t',LEASE_ROWS)),size=16384}
-- test_calls: {acquire=fn,release=fn} stand-ins for the two native lease
-- functions (tests only).
function M.new(api,game,exe,signatures,dependencies,test_calls)
    local function read(p,n)
        assert(n>0 and n<=32768,'Read exceeds bound')
        local bytes=api.read(p,n);assert(bytes,'Native data unavailable');return bytes
    end
    local function ptr(p)
        local value=api.pointer(read(p,8));assert(value,'Native pointer unavailable');return value
    end
    -- Code pages that are not resident yet cannot be read (ReadProcessMemory fails): those checks run right
    -- before the first native call instead (checked below); a native is never called unchecked.
    local pending={}
    for _,s in ipairs(signatures)do
        local bytes=(s.hex:gsub('..',function(v)return string.char(tonumber(v,16))end))
        local at=(s.module=='game' and game or exe)+s.rva
        local now=api.read(at,#bytes)
        if now then assert(now==bytes,'Native instruction mismatch') else pending[#pending+1]={at,bytes} end
    end
    local function checked(call)
        if #pending==0 then return call end
        return function(...)
            for i=#pending,1,-1 do
                local now=api.read(pending[i][1],#pending[i][2])
                assert(now,'Native code not resident yet');assert(now==pending[i][2],'Native instruction mismatch')
                pending[i]=nil
            end
            return call(...)
        end
    end
    local root_api=ptr(game+0x2ce14c8)
    assert(root_api==exe+0x2870240,'Unexpected script API')
    local app=ptr(root_api+16)
    assert(ptr(app+752)==exe+0x2f0260 and ptr(app+768)==exe+0x2f04c0,'Unexpected package API')
    local calls=test_calls or {}
    local acquire=calls.acquire or ffi.cast('void (*)(void *,const uint64_t *,uint32_t)',game+0x11912f0)  -- lint-ok: R2 once per session in native.new (v23 cast; only the test stand-in is new)
    local release=calls.release or ffi.cast('void (*)(void *,const uint64_t *,uint32_t)',game+0x1191480)  -- lint-ok: R2 once per session in native.new (v23 cast; only the test stand-in is new)
    acquire,release=checked(acquire),checked(release)
    local argument=ffi.new('uint64_t[1]')
    local self={api=api}
    local dependency=dependencies and dependencies.new(api,game)
    local catalog_owner
    local kits,presets,weapons={},{},{}

    function self:owner()
        local p=ptr(game+0x2e381e8)
        local h=read(p,32)
        assert(u32(h,8)==1024 and u32(h,24)==2 and raw64(h,16)==zero,'Unexpected lease table')
        assert(api.pointer(h)==p+32,'Unexpected lease storage')
        local allocator=ptr(p+16416)
        return pointer_key(p)..pointer_key(allocator),p
    end
    -- Package identifiers as hex text, made once per identifier and session
    -- (bounded: the cache restarts past 8192 identifiers).
    local hex_ids,hex_count={},0
    local function hex_of(low,high)
        local row=hex_ids[high]
        local text=row and row[low]
        if text then return text end
        if hex_count>=8192 then hex_ids,hex_count={},0 end
        row=hex_ids[high];if not row then row={};hex_ids[high]=row end
        text=bit.tohex(high,8)..bit.tohex(low,8)
        row[low]=text;hex_count=hex_count+1
        return text
    end
    -- One reused table of the table's rows (identifier -> count) and the
    -- identifiers it holds: the next decode replaces it, so callers read the
    -- counts they need before decoding again.
    local rows,listed,row_ids={},0,{}
    function self:references()
        local owner,p=self:owner()
        for i=1,listed do rows[row_ids[i]]=nil end
        listed=0
        assert(api.read(tonumber(ffi.cast('uintptr_t',p))+32,16384,LEASE_BUFFER,0),'Native data unavailable')
        local w=LEASE_ROWS
        for i=0,4092,4 do
            local low,high=w[i],w[i+1]
            if low~=0 or high~=0 then
                -- Counts are 64-bit natively; reject high-word or implausible values.
                assert(w[i+3]==0,'Invalid package reference count')
                local count=w[i+2];assert(count>0 and count<1000000,'Invalid package references')
                local id=hex_of(low,high)
                rows[id]=count;listed=listed+1;row_ids[listed]=id
            end
        end
        return rows,listed,owner,p
    end
    function self:valid_leases(leases,owner)
        local current_rows,_,current=self:references()
        if current~=owner then return false end
        for id in pairs(leases)do if not current_rows[id]then return false end end
        return true
    end
    function self:acquire(id,owner)
        local before,n,current,p=self:references()
        if current~=owner or (not before[id] and n>=1008)then return false end
        local count=before[id] or 0
        ffi.copy(argument,unhex(id),8);acquire(p,argument,1)
        local after,_,check=self:references()
        assert(check==owner and after[id]==count+1,'Package acquire did not balance')
        return true
    end
    function self:release(id,owner)
        local before,_,current,p=self:references()
        -- A reset manager has already retired its own package references.
        if current~=owner or not before[id]then return false end
        local count=before[id]
        ffi.copy(argument,unhex(id),8);release(p,argument,1)
        local after,_,check=self:references()
        assert(check==owner and (after[id] or 0)==count-1,'Package release did not balance')
        return true
    end
    local function catalog()
        local ko,po,wo=ptr(game+0x2ce16a8),ptr(game+0x2e38230),ptr(game+0x2ce41b8)
        local wt=ptr(wo+0xf14008)
        local kp=ptr(ko);local kc=u32(read(ko+8,4),0)
        local pc=u32(read(po+7392,4),0)
        assert(kc>0 and kc<=1024 and pc>0 and pc<=4096,'Catalogue bounds changed')
        local key=table.concat({pointer_key(ko),pointer_key(kp),kc,pointer_key(po),pc,pointer_key(wt)},':')
        if key==catalog_owner then return end
        kits,presets,weapons={},{},{}
        local pointers=read(kp,kc*8)
        for i=0,kc-1 do
            local row=read(assert(api.pointer(pointers,i*8)),48)
            local id=raw64(row,32)
            if id~=zero then kits[u32(row,0)]=hex(id)end
        end
        for first=0,pc-1,1024 do
            local n=math.min(1024,pc-first);local rows=read(po+761060+first*24,n*24)
            for i=0,n-1 do presets[u32(rows,i*24+4)]=u32(rows,i*24+8)end
        end
        local buckets=read(wt,1100*16);local records=read(wt+17600,550*32)
        for i=0,1099 do
            local id=raw64(buckets,i*16)
            if id~=zero then
                local index=u32(buckets,i*16+8);assert(index<550,'Weapon record bound changed')
                local package_id=raw64(records,index*32+8)
                if package_id~=zero then weapons[hex(id)]=hex(package_id)end
            end
        end
        catalog_owner=key
    end
    function self:resolve(item)
        if not catalog_owner then catalog()end
        if item.kind==0 or item.kind==1 then return weapons[item.id] end
        if item.kind>=2 and item.kind<=4 then
            local raw=unhex(item.id)
            if u32(raw,4)~=0 then return nil end
            return kits[presets[u32(raw,0)]]
        end
    end
    function self:resolve_all(item)
        local base=self:resolve(item);local result=base and {base} or {}
        if not base then return result end
        if dependency and item.kind<=1 then
            for _,id in ipairs(dependency:resolve(item))do
                if id~=base then result[#result+1]=id end
            end
        end
        return result
    end
    function self:snapshot()
        local owner=self:owner()
        local sm=ptr(game+0x2e38160);local stack=read(sm+0x429c,24);local depth=u32(stack,20)
        local top=depth>=1 and depth<=5 and u32(stack,(depth-1)*4) or -1
        local ui=ptr(game+0x2e380c8);local world=api.pointer(read(ui+15432,8))
        local blocked=u32(read(ui+15892,4),0)~=0
        -- Gameplay states cannot display thumbnails or run startup prewarming.
        -- Keep owner/world information so the policy can release old leases.
        if top~=5 and top~=14 and depth~=0 then
            return {owner=owner,world=world and pointer_key(world),menu=false,prefetch=false,
                    blocked=blocked,top=top,items={},active=false,states={}}
        end
        local tm=ptr(game+0x2e380b0);local h=read(tm,12464)
        assert(ptr(game+0x2e380b0)==tm and u32(h,11344)==7,'Thumbnail manager changed')
        local active=u32(h,11356);assert(active==0xffffffff or active<6,'Invalid thumbnail active card')
        local items,states={},{}
        for card=0,5 do
            local off=1816*card;local state=u32(h,off+1832);local count=u32(h,off+1836)
            assert(state<=8 and count<=15,'Invalid thumbnail card')
            states[#states+1]=state
            for i=0,count-1 do
                local at=off+32+i*120;local kind=u32(h,at+100)
                if state~=0 and kind<=4 then
                    local id=raw64(h,at+24)
                    if id~=zero then items[#items+1]={kind=kind,id=hex(id),finished=state==8 or u32(h,at+104)==4}end
                end
            end
        end
        -- The transient UI flag toggles during normal thumbnail work. It is
        -- not a world-lifetime signal and must never invalidate held leases.
        local menu=top==5 and world~=nil
        if top==14 and world~=nil then
            -- Briefing has its own controller. State 11 alone must not enable
            -- asset work during a controller teardown or unrelated transition.
            local dispatch=api.pointer(read(game+0x2ce2040,8))
            if dispatch then
                local count=u32(read(dispatch+5740,4),0)
                assert(count<=64,'UI dispatch bound changed')
                local matches=0
                if count>0 then
                    local rows=read(dispatch+5744,count*16)
                    for i=0,count-1 do
                        if u32(rows,i*16+8)==231 and api.pointer(rows,i*16)then matches=matches+1 end
                    end
                end
                menu=matches==1
            end
        end
        -- Global package leases do not require a thumbnail world. During the
        -- bounded startup window, an initialized UI world with an empty state
        -- stack and idle preview manager can warm dependencies before Armory.
        local prefetch=world~=nil and depth==0 and active==0xffffffff
        if menu or prefetch then
            catalog()
            if dependency then
                dependency:refresh()
                local queued=dependency:queued()
                for _,item in ipairs(items)do item.attachments=queued[item.id]end
            end
        end
        return {owner=owner,world=world and pointer_key(world),menu=menu,
                prefetch=prefetch,blocked=blocked,top=top,items=items,active=active~=0xffffffff,states=states}
    end
    return self
end
return M

end)()
local policy=(function()
-- Bounded resource leases, foreground lookahead and learned startup prewarming.
local M={}
function M.new_memory_guard()
    local g={trips=0,active=false}
    -- now may be a clock function: it is read only when the guard trips or
    -- recovers, so a healthy poll reads no clock.
    function g:tick(now,free,commit) -- lint-ok: R10 ported from v23 unchanged; split into named steps is a follow-up (differential harness ready)
        local reason=free<2*1024^3 and 'low_physical_memory' or
                     commit<2*1024^3 and 'low_commit_headroom' or nil
        if (reason or self.active) and type(now)=='function' then now=now() end
        if reason then
            if not self.active then
                self.trips=self.trips+1;self.last_reason=reason
                self.trigger_free_mib=math.floor(free/1048576)
                self.trigger_commit_mib=math.floor(commit/1048576)
            end
            self.active=true;self.last_low=now;self.healthy_since=nil
            return reason
        end
        if not self.active then return nil end
        if free>=4*1024^3 and commit>=4*1024^3 then
            self.healthy_since=self.healthy_since or now
            if now-self.last_low>=30 and now-self.healthy_since>=5 then
                self.active=false;self.healthy_since=nil;return nil
            end
        else self.healthy_since=nil end
        return 'memory_recovery_cooldown'
    end
    return g
end
function M.new(adapter,options)
    options=options or {}
    local self={adapter=adapter,limit=options.limit or 128,leases={},learned={},learn_order={},
                owner=nil,world=nil,acquires=0,releases=0,hits=0,unresolved=0,retired=0,prewarms=0,
                dependency_acquires=0,startup_acquires=0,foreground_pending=0,
                prewarm=options.prewarm~=false,pressure=false}
    local function key(item)return item.kind..':'..item.id end
    -- profile_changed: remember() ran since the profile was last saved, so its
    -- encoding may differ; the save throttle encodes only then.
    function self:remember(item)
        self.profile_changed=true
        local k=key(item)
        if not self.learned[k] then
            self.learned[k]={kind=item.kind,id=item.id};self.learn_order[#self.learn_order+1]=k
            if #self.learn_order>192 then self.learned[table.remove(self.learn_order,1)]=nil end
        elseif self.learn_order[#self.learn_order]~=k then
            -- Background/startup traverse this list newest first. A revisit
            -- must refresh priority even when the item was learned long ago.
            for i,known in ipairs(self.learn_order)do
                if known==k then table.remove(self.learn_order,i);break end
            end
            self.learn_order[#self.learn_order+1]=k
        end
        if item.attachments then
            local copy={};for i=1,math.min(10,#item.attachments)do copy[i]=item.attachments[i]end
            self.learned[k].attachments=copy
        end
        return self.learned[k]
    end
    function self:profile()
        local out={};for _,k in ipairs(self.learn_order)do out[#out+1]=self.learned[k]end;return out
    end
    function self:evict(id)
        local lease=self.leases[id];if not lease then return end
        self.adapter:release(id,lease.owner);self.leases[id]=nil;self.releases=self.releases+1
    end
    function self:clear()
        if next(self.leases) and not self.adapter:valid_leases(self.leases,self.owner)then
            self:retire();self.quarantined=true;return
        end
        for id in pairs(self.leases)do self:evict(id)end
    end
    function self:retire()
        -- Native manager replacement owns teardown; never release against its successor.
        for _ in pairs(self.leases)do self.retired=self.retired+1 end
        self.leases={}
    end
    -- A tick is settled when repeating it with the same snapshot and pressure
    -- would only add the same hit and unresolved counts: it acquired nothing,
    -- every protected request is leased and no clock-dependent startup window
    -- is open. replay() records such a repeat without running it.
    self.settled,self.tick_hits,self.tick_unresolved=false,0,0
    function self:replay()
        self.hits=self.hits+self.tick_hits;self.unresolved=self.unresolved+self.tick_unresolved
    end
    local tick
    function self:tick(s,now,pressure)
        local hits,unresolved=self.hits,self.unresolved
        self.settled=tick(self,s,now,pressure)==true
        self.tick_hits,self.tick_unresolved=self.hits-hits,self.unresolved-unresolved
    end
    tick=function(self,s,now,pressure) -- lint-ok: R10 ported from v23 unchanged; split into named steps is a follow-up (differential harness ready)
        if self.owner and self.owner~=s.owner then self:retire()end
        self.owner=s.owner
        if next(self.leases) and not self.adapter:valid_leases(self.leases,self.owner)then
            self:retire();self.quarantined=true
        end
        if self.quarantined then self.status='lease_ownership_lost_restart_required';return true end
        self.started=self.started or now
        local startup=self.prewarm and not s.menu and not self.seen_menu and now-self.started<60 and s.prefetch
        if self.world and self.world~=s.world and not (not self.seen_menu and s.menu)then self:clear();self.pressure=false end
        self.world=s.world
        if s.menu then self.seen_menu=true end
        -- Outside the menu a closed startup window never reopens for the same
        -- snapshot. An open one closes with the clock alone, so a tick inside
        -- it is never settled.
        if not s.menu and not startup then self:clear();self.pressure=false;self.status='outside_ship_ui';return true end
        if pressure then self:clear();self.pressure=true;self.status='memory_pressure';return not startup end
        self.pressure=false
        local wanted,protected={},{}
        local function add(item,background)
            local ids
            if self.adapter.resolve_all then ids=self.adapter:resolve_all(item)
            else local id=self.adapter:resolve(item);ids=id and {id} or {}end
            if #ids==0 then self.unresolved=self.unresolved+1 end
            for index,id in ipairs(ids)do
                if not protected[id]then
                    protected[id]=true;wanted[#wanted+1]={id=id,prewarm=background,dependency=index>1}
                end
            end
        end
        -- Touch the current group in reverse so newest-first prewarming keeps
        -- the same order as foreground requests. Repeated identical snapshots
        -- finish with identical profile bytes, avoiding needless disk writes.
        for i=#s.items,1,-1 do self:remember(s.items[i])end
        for _,item in ipairs(s.items)do
            if not item.finished then add(self.learned[key(item)],false)end
        end
        for _,item in ipairs(s.items)do if item.finished then add(self.learned[key(item)],false)end end
        -- Background learning is useful before opening a menu, but foreground
        -- generation owns priority and never waits for the persistent profile.
        if self.prewarm and not s.active and not s.blocked then
            for i=#self.learn_order,1,-1 do
                add(self.learned[self.learn_order[i]],true)
                if #wanted>=self.limit then break end
            end
        end
        -- Protect only requests that fit. Oversized profiles must not make
        -- every held package unevictable, starving the foreground forever.
        protected={}
        for i=1,math.min(self.limit,#wanted)do protected[wanted[i].id]=true end
        local added=0
        self.foreground_pending=0
        for _,request in ipairs(wanted)do
            local id=request.id
            if self.leases[id]then self.leases[id].used=now;self.hits=self.hits+1
            elseif added<4 and protected[id]then
                local n,victim,oldest=0,nil,math.huge
                for held,l in pairs(self.leases)do
                    n=n+1
                    if not protected[held] and l.used<oldest then victim,oldest=held,l.used end
                end
                if n>=self.limit and victim then self:evict(victim);n=n-1 end
                if n<self.limit and self.adapter:acquire(id,self.owner)then
                    self.leases[id]={owner=self.owner,used=now};added=added+1;self.acquires=self.acquires+1
                    if request.prewarm then self.prewarms=self.prewarms+1 end
                    if request.dependency then self.dependency_acquires=self.dependency_acquires+1 end
                    if startup then self.startup_acquires=self.startup_acquires+1 end
                end
            end
            if not request.prewarm and not self.leases[id]then self.foreground_pending=self.foreground_pending+1 end
        end
        -- A fixed count bound is enforced even for profiles larger than the cache.
        self.status=startup and 'startup_dependency_prewarm' or
            (s.blocked and 'thumbnail_ui_busy' or (s.active and 'foreground_lookahead' or 'resident'))
        -- Settled only at a fixed point: this tick acquired nothing (a lease it
        -- added is a hit next tick) and every protected request is leased (one
        -- that is not is retried next tick, and whether that acquire succeeds
        -- depends on the game's package table).
        if startup or added>0 then return false end
        for i=1,math.min(self.limit,#wanted)do if not self.leases[wanted[i].id]then return false end end
        return true
    end
    return self
end
return M

end)()
local profile=(function()
local M={}
function M.decode(text,build)
    local items={}
    if type(text)~='string' or #text>65536 or text:sub(-1)~='\n' then return items,false end
    local header,body=text:match('^([^\r\n]+)\r?\n(.*)$')
    local legacy=header=='ArmoryPreviewCache1 '..build
    if not legacy and header~='ArmoryPreviewCache2 '..build then return items,false end
    local seen={}
    for line in body:gmatch('[^\r\n]+')do
        local base,extra=line:match('^([^|]+)|?(.*)$')
        local kind,id
        if base then kind,id=base:match('^([0-4]):([0-9a-f]+)$')end
        if kind and #id==16 and not seen[base] and id~='0000000000000000' and (not legacy or extra=='')then
            local attachments,valid,unique={},true,{}
            if extra~=''then
                if extra:find('[^0-9a-f,]') or extra:sub(1,1)==',' or extra:sub(-1)==',' or extra:find(',,',1,true)then valid=false end
                for value in extra:gmatch('[^,]+')do
                    if #value~=16 or value=='0000000000000000' or unique[value] or #attachments>=10 then valid=false;break end
                    unique[value]=true;attachments[#attachments+1]=value
                end
            end
            if valid then
                seen[base]=true;items[#items+1]={kind=tonumber(kind),id=id,attachments=not legacy and attachments or nil}
            end
            if #items==192 then break end
        end
    end
    return items,true
end
function M.encode(items,build)
    local lines={'ArmoryPreviewCache2 '..build}
    for _,item in ipairs(items)do
        lines[#lines+1]=item.kind..':'..item.id..'|'..table.concat(item.attachments or {},',')
    end
    return table.concat(lines,'\n')..'\n'
end
function M.options(text)
    local result={enabled=true,prewarm=true,images=true,disk=false,verify_gate=false}
    for key,value in (text or ''):gmatch('([%w_]+)%s*=%s*([01])')do
        if key=='enabled' or key=='prewarm' or key=='images' or key=='verify_gate'then result[key]=value=='1'end
    end
    return result
end
return M

end)()
local signatures=(function()
return {
    {module='game',rva=0x11912f0,hex='4585c00f8475010000415641574883ec38'},
    {module='game',rva=0x1191301,hex='48895c24504c8bfa48896c24584c8bf1488974246048897c24304c896424284c8d25a9b0ff014c896c24204c8d2d79b1ff01418be866660f1f840000000000418b560833c0498b37458b46184c0fafc6448d4aff85d27459498b0e0f1f40008bd84903d84923d948c1e3044803d94839330f84f7000000ffc03bc272e24d8b5e104c8bd133c0660f1f8400000000008bd84903d84923d948c1e3044903da488b0b493bcb740d483bce7408ffc03bc272de33db48893348c7430801000000488b155a5cb4014c8d054bbcff00488b7b08498bcc4c8bce488d4216493bc5480f42caba1600000048890d325cb401e82d4736ff4c8b05265cb401488d0d4795fb00ffc04c8bcf4863d04903d04889150d5cb401488d15e6bafb00e811af410048837b08017514488b059b00b501488bce488b5010ff92f00200004983c7084883ed010f85f8feffff4c8b6c24204c8b642428488b7c2430488b742460488b6c2458488b5c24504883c438415f415e'},
    {module='game',rva=0x119146e,hex='c3'},
    {module='game',rva=0x119146f,hex='48ff4308e947ffffff'},
    {module='game',rva=0x1191480,hex='4585c00f8460010000415641574883ec38'},
    {module='game',rva=0x1191491,hex='48895c24504c8bfa48896c24584c8bf148897424604c896424284c8d251eafff014c896c24204c8d2deeafff0148897c2430418be866660f1f840000000000498b374885f60f84d9000000418b4e0833c0418b5618480fafd6448d49ff85c90f84bf0000004d8b060f1f80000000008bd84803da4923d948c1e3044903d8483933740bffc03bc172e6e996000000488b7b084885ff0f8489000000488b15ed5ab4014c8d05debaff0048ffcf498bcc4c8bce48897b08488d4216493bc5480f42caba1600000048890dc25ab401e8bd4536ff4c8b05b65ab401488d0dd793fb00ffc04c8bcf4863d04903d04889159d5ab401488d150eb9fb00e8a1ad410048837b0800751f488bd6498bcee85f264100488b0520ffb401488bce488b5010ff92000300004983c7084883ed010f850dffffff4c8b6c24204c8b642428488b7c2430488b742460488b6c2458488b5c24504883c438415f415e'},
    {module='game',rva=0x11915e9,hex='c3'},
}

end)()
local image_native=(function()
-- Build-locked UI presentation and render-texture ownership adapter.
-- Never edits code, card states, avatar work or generation completion flags.
-- Cached UI bindings use the native registration and widget invalidation contract.
local ffi=require('ffi')
local bit=require('bit')
local M={}
local scalar=ffi.new('uint32_t[1]')
local fp=ffi.new('float[4]')
local packed=ffi.new('uint64_t[2]')
local pointer_value=ffi.new('uintptr_t[1]')
local function pointer_key(p)
    -- The host may redact tostring(cdata). Preserve all address bits instead.
    pointer_value[0]=ffi.cast('uintptr_t',p);return ffi.string(pointer_value,8)
end
local function u32(s,o)ffi.copy(scalar,s:sub(o+1,o+4),4);return tonumber(scalar[0])end
local function float(s,o)ffi.copy(fp,s:sub(o+1,o+4),4);return tonumber(fp[0])end
local function raw(s,o,n)return s:sub(o+1,o+n)end
local function finite(n)return n==n and math.abs(n)<1000000 end
-- Grid request identity, not the working camera pose. 0x10F1CE0 changes
-- item+8 (weapon/cape angle) and +84 (cosmetic framing) during generation.
-- Grid kind and record style select the original request's camera preset.
function M.key(layout,item,variant)
    return layout..variant..raw(item,24,16)..raw(item,48,8)
        ..raw(item,64,8)..raw(item,88,16)
end

-- verify_gate: everything a snapshot result feeds into the image tick, per
-- part, as strings to compare between two decodes.
local DIGEST_FIELDS={'context','view','screen','layout','descriptor_id','capture_id','complete',
    'can_freeze','can_freeze_idle','can_freeze_rebind','can_freeze_visible','quiescent','blank_cards',
    'expected_count','width','height','bytes','tile_width','tile_height','controller_kind'}
function M.digest(s)
    local out={}
    for _,k in ipairs(DIGEST_FIELDS)do out[#out+1]=tostring(s[k])end
    for _,k in ipairs({'manager','world','owner','atlas'})do out[#out+1]=s[k] and pointer_key(s[k]) or '-' end
    local parts={screen=table.concat(out,'\1')}
    out={}
    for _,item in ipairs(s.items)do
        out[#out+1]=table.concat({item.key or '-',tostring(item.ready),tostring(item.pixels_ready),
            item.card,item.index,item.rectangle,item.preview or '-'},'\2')
    end
    parts.items=table.concat(out,'\1')
    out={};local shown={}
    for _,w in ipairs(s.widgets)do
        out[#out+1]=table.concat({w.key,pointer_key(w.widget),w.record_pointer,w.visual,tostring(w.bound),
            tostring(w.invalidated),tostring(w.named_material),tostring(w.native_ready),tostring(w.pixels_ready),
            w.indices,tostring(w.box_width),tostring(w.box_height),w.fit},'\2')
        shown[#shown+1]=table.concat({w.uv,w.size,tostring(w.alpha),tostring(w.spinner_alpha)},'\2')
    end
    parts.widgets=table.concat(out,'\1');parts.presentation=table.concat(shown,'\1')
    out={}
    for _,e in ipairs(s.registry or {})do out[#out+1]=pointer_key(e)end
    parts.registry=table.concat(out)
    out={}
    for c=0,5 do
        local source=s.source_cards and s.source_cards[c]
        out[#out+1]=source and (source.state..':'..source.stamp) or '-'
    end
    parts.cards=table.concat(out,'\1')
    return parts
end

-- One reused read buffer: 8-byte aligned, with byte, 32-bit and float views.
-- Only ReadProcessMemory writes it, so views never alias Lua stores.
local function buffer(size)
    local keep=ffi.new('uint64_t[?]',math.ceil(size/8))
    local bytes=ffi.cast('uint8_t *',keep)
    return {keep=keep,data=bytes,bytes=bytes,address=tonumber(ffi.cast('uintptr_t',keep)),size=size,
        u32=ffi.cast('uint32_t *',keep),f32=ffi.cast('float *',keep)}
end
-- A pointer field as a number (two 32-bit halves), nil when it is not a
-- plausible user-mode address; word is the field's 32-bit index.
local function pointer(b,word)
    local v=b.u32[word]+b.u32[word+1]*4294967296
    if v<0x10000 or v>=0x800000000000 then return nil end
    return v
end

-- The state check (docs/UPDATE_GATE.md). Each refresh reads what the image
-- snapshot and the asset policy consume into reused buffers and copies the
-- words they use into a signature with one fixed region per component. A
-- component whose words differ from the previous refresh gets a new version.
-- Nothing is allocated. Cost per refresh: 3 reads outside a thumbnail screen;
-- on one, 2 controller reads, the manager, the atlas descriptor, the preview
-- queue header (+1-2 reads while previews are queued) and the screen block
-- (grid: 1; pre-select: 1 + 3 widget record pointers; briefing: 1 + 6).
-- POLICY holds what only the asset policy reads (UI blocked flag, lease table
-- pointer, item status), so its changes never cost an image tick.
local UI,CONTROLLER,MANAGER,DESCRIPTOR,QUEUE,SCREEN,POLICY=0,1,2,3,4,5,6
local REGION={[0]=0,32,48,1648,1680,4624,7632}
local WORDS=7760
-- Item words the snapshot and the policy read: request identity (+24..+40,
-- +48..+56, +64..+72, +88..+104), crop rectangle (+56..+72) and kind (+100);
-- status (+104) goes to POLICY. The generator rewrites the camera fields +8
-- and +84.
local ITEM_WORDS={6,7,8,9,12,13,14,15,16,17,22,23,24,25}
-- Record words: visual (+0), type (+8), card/slot (+60), invalidation (+68)
-- and style (+72).
local RECORD_WORDS={0,1,2,15,16,17,18}
local BRIEFING_KINDS={[0]=2,3,4,0,0,1}
function M.state(api,game)
    local read=api.read
    local base=tonumber(ffi.cast('uintptr_t',game))
    local G,STACK,UIB,DPTR,DROWS=buffer(0x140),buffer(24),buffer(464),buffer(8),buffer(4+64*16)
    local MB,DESC,QH,QROWS=buffer(12464),buffer(104),buffer(8),buffer(127*200)
    local SMALL,META,TAILS,LEASE=buffer(480),buffer(24892),buffer(6*8),buffer(40)
    local cur,prev=ffi.new('uint32_t[?]',WORDS),ffi.new('uint32_t[?]',WORDS)
    local clen,plen=ffi.new('int32_t[7]'),ffi.new('int32_t[7]')
    local tails_ok=ffi.new('bool[6]')
    local lease_words,lease_prev=ffi.new('uint32_t[12]'),ffi.new('uint32_t[12]')
    -- No previous signature yet: the first refresh reports every component.
    for k=0,6 do clen[k]=-1;plen[k]=-1 end
    local self={G=G,STACK=STACK,UI=UIB,DPTR=DPTR,DROWS=DROWS,MB=MB,DESC=DESC,QH=QH,QROWS=QROWS,
        SMALL=SMALL,META=META,TAILS=TAILS,tails_ok=tails_ok,base=base,
        refreshes=0,image_version=0,policy_version=0,lease_version=0,lease_checked=false}
    local function words(b,first,count,w)
        local src=b.u32
        for i=0,count-1 do cur[w+i]=src[first+i] end
        return w+count
    end
    local function records(b,first,count,w)
        local src=b.u32
        for r=0,count-1 do
            local at=first+r*20
            for j=1,7 do cur[w]=src[at+RECORD_WORDS[j]];w=w+1 end
        end
        return w
    end
    local function tail(i,address,w)
        local ok=read(address,8,TAILS,i*8)
        tails_ok[i]=ok==true
        cur[w]=ok and 1 or 2
        if ok then cur[w+1]=TAILS.u32[i*2];cur[w+2]=TAILS.u32[i*2+1];return w+3 end
        return w+1
    end
    local function grid(address,w)
        local ok=read(address+597772,24892,META,0)
        self.meta_ok,self.meta_address=ok==true,address
        cur[w]=ok and 1 or 2;w=w+1
        if not ok then return w end
        -- Rows, row heights/index table, scroll position, item count, grid kind,
        -- columns and anchor (+597772..+602104), every record's identity, type,
        -- card/slot, invalidation and style, then row ranges, owned cards and the
        -- visible window (+622584..+622664). Scrolling remaps widgets to other
        -- records without any manager change; these fields move with it.
        w=words(META,0,1083,w)
        w=records(META,1083,256,w)
        return words(META,6203,20,w)
    end
    -- A briefing loadout is shown when all six records hold their slot's
    -- request (the manager item exists, has the expected kind) and each widget
    -- still points at its record: as in snapshot().
    local function loadout(owner)
        local m,r=MB.u32,SMALL.u32
        for index=0,5 do
            local card,slot=r[index*20+15],r[index*20+16]
            if card>=6 or slot>=15 then return false end
            local st,n=m[card*454+458],m[card*454+459]
            if st==0 or slot>=n then return false end
            local kind=m[card*454+8+slot*30+25]
            if kind>4 or r[index*20+2]~=3 or kind~=BRIEFING_KINDS[index]
                or not tails_ok[index] or pointer(TAILS,index*2)~=owner+454792+index*80 then return false end
        end
        return true
    end
    -- Globals block: the thumbnail manager, UI, state machine, preview queue
    -- and lease table pointers. Returns the UI and POLICY write positions.
    local function read_globals()
        local w,p=REGION[UI],REGION[POLICY]
        local ok=self.probed or read(base+0x2e380b0,0x140,G,0)
        self.g_ok=ok==true;cur[w]=ok and 1 or 2;w=w+1
        local tm,ui,sm,preview,lease
        if ok then
            w=words(G,0,2,w);w=words(G,6,2,w);w=words(G,44,2,w);w=words(G,56,2,w)
            p=words(G,78,2,p)
            tm,ui,sm,preview,lease=pointer(G,0),pointer(G,6),pointer(G,44),pointer(G,56),pointer(G,78)
        end
        self.tm,self.ui,self.sm,self.preview,self.lease=tm,ui,sm,preview,lease
        return w,p
    end
    -- State stack: depth and top. Returns the controller kind of a thumbnail
    -- screen (Armory 226, briefing 231).
    local function read_stack(w)
        self.stack_ok,self.depth,self.top=false,nil,nil
        if not self.sm then return w end
        local ok=self.probed or read(self.sm+0x429c,24,STACK,0)
        self.stack_ok=ok==true;cur[w]=ok and 1 or 2;w=w+1
        if not ok then return w end
        local depth=STACK.u32[5]
        local top=depth>=1 and depth<=5 and STACK.u32[depth-1] or nil
        cur[w]=depth;cur[w+1]=top or 0xffffffff;w=w+2
        self.depth,self.top=depth,top
        return w,top==5 and 226 or (top==14 and 231 or nil)
    end
    -- UI block: the UI world, and the blocked flag for the policy.
    local function read_ui(w,p)
        self.ui_ok=false
        if not self.ui then return w,p end
        local ok=read(self.ui+15432,464,UIB,0)
        self.ui_ok=ok==true;cur[w]=ok and 1 or 2;w=w+1
        if not ok then return w,p end
        w=words(UIB,0,2,w);p=words(UIB,115,1,p)
        return w,p,pointer(UIB,0)
    end
    local function reset_screen()
        self.dptr_ok,self.rows_ok,self.mb_ok,self.desc_ok,self.qh_ok,self.qrows_ok=false,false,false,false,false,false
        self.small_ok,self.meta_ok,self.jobs,self.screen=false,false,0,nil
        for i=0,5 do tails_ok[i]=false end
    end
    -- The dispatch rows are a fixed 64-row array after their count: one read,
    -- or the count and the rows when the array cannot be read whole.
    local function read_rows(d)
        if read(d+5740,4+64*16,DROWS,0)then return true end
        local ok=read(d+5740,4,DROWS,0)
        local n=ok and DROWS.u32[0]
        if n and n>0 and n<=64 then ok=read(d+5744,n*16,DROWS,4)end
        return ok==true
    end
    -- The controller registered for kind (and whether several are), and how
    -- many briefing controllers are registered.
    local function find_owner(kind,n)
        local found,ambiguous,briefing=nil,0,0
        for i=0,n-1 do
            local row=1+i*4
            local k=DROWS.u32[row+2]
            if k==kind then
                if found then ambiguous=1 end
                found=pointer(DROWS,row)
            end
            if k==231 and pointer(DROWS,row)then briefing=briefing+1 end
        end
        return found,ambiguous,briefing
    end
    -- The rows' count and the owner found in them (with ambiguity and the
    -- briefing controller count).
    local function row_words(d,kind,w)
        local rok=read_rows(d)
        self.rows_ok=rok;cur[w]=rok and 1 or 2;w=w+1
        local n=rok and DROWS.u32[0]
        if n then cur[w]=n;w=w+1 end
        if not (n and n<=64) then return w end
        local found,ambiguous,briefing=find_owner(kind,n)
        cur[w]=found and found%4294967296 or 0;cur[w+1]=found and math.floor(found/4294967296) or 0
        cur[w+2]=ambiguous;cur[w+3]=briefing
        return w+4,found
    end
    -- CONTROLLER: dispatch pointer and rows. Returns the screen's owner.
    local function read_controller(kind)
        local w=REGION[CONTROLLER]
        local ok=read(base+0x2ce2040,8,DPTR,0)
        self.dptr_ok=ok==true;cur[w]=ok and 1 or 2;w=w+1
        local d=ok and pointer(DPTR,0)
        if ok then w=words(DPTR,0,2,w)end
        local owner
        if d then w,owner=row_words(d,kind,w)end
        clen[CONTROLLER]=w-REGION[CONTROLLER]
        self.owner=owner
        return owner
    end
    -- One card's state and count and, while it is busy, per item the words the
    -- snapshot reads (identity, crop rectangle, kind) and its status (POLICY).
    local function card_words(m,c,w,p)
        local at=c*454
        local st,n=m[at+458],m[at+459]  -- +1832, +1836
        cur[w]=st;cur[w+1]=n;w=w+2
        if st==0 or n>15 then return w,p end
        for i=0,n-1 do
            local item=at+8+i*30    -- +32+i*120
            for j=1,14 do cur[w]=m[item+ITEM_WORDS[j]];w=w+1 end
            cur[p]=m[item+26];p=p+1 -- +104 status
        end
        return w,p
    end
    -- MANAGER: one read of the thumbnail manager. Returns the working atlas.
    local function read_manager(p)
        local w=REGION[MANAGER]
        local ok=read(self.tm,12464,MB,0)
        self.mb_ok=ok==true;cur[w]=ok and 1 or 2;w=w+1
        local atlas
        if ok then
            local m=MB.u32
            cur[w]=m[2836];w=w+1                -- +11344
            w=words(MB,4,4,w)                   -- +16..+32: layout, tile size
            for c=0,5 do w,p=card_words(m,c,w,p)end
            cur[w]=m[2839];cur[w+1]=m[2847];w=w+2  -- active +11356, phase +11388
            w=words(MB,2848,2,w)                -- +11392 layout
            w=words(MB,2850,2,w)                -- atlas +11400
            local count=m[2856]                 -- registry +11424
            cur[w]=count;w=w+1
            if count<=128 then w=words(MB,2858,count*2,w)end
            atlas=pointer(MB,2850)
        end
        clen[MANAGER]=w-REGION[MANAGER]
        self.atlas=atlas
        return atlas,p
    end
    local function read_descriptor(atlas)
        local w=REGION[DESCRIPTOR]
        if atlas then
            local ok=read(atlas,104,DESC,0)
            self.desc_ok=ok==true;cur[w]=ok and 1 or 2;w=w+1
            if ok then w=words(DESC,0,26,w)end
        end
        clen[DESCRIPTOR]=w-REGION[DESCRIPTOR]
    end
    -- The occupied preview rows, oldest first, in at most two reads.
    local function read_jobs(preview,head,tail_index)
        local jobs=(tail_index-head)%128
        local first=math.min(jobs,128-head)
        local ok=jobs==0 or read(preview+50456+head*200,first*200,QROWS,0)
        if ok and jobs>first then ok=read(preview+50456,(jobs-first)*200,QROWS,first*200)end
        return jobs,ok==true
    end
    -- Per queued job: identity, slot count and slots.
    local function job_words(jobs,w)
        for r=0,jobs-1 do
            local row=r*50
            local n=QROWS.u32[row+20]  -- +80 slot count
            w=words(QROWS,row+16,2,w)  -- +64 identity
            cur[w]=n;w=w+1
            if n>10 then break end
            w=words(QROWS,row+22,n*2,w) -- +88 slots
        end
        return w
    end
    local function queue_words(preview,w)
        local ok=read(preview+50448,8,QH,0)
        self.qh_ok=ok==true;cur[w]=ok and 1 or 2;w=w+1
        if not ok then return w end
        local head,tail_index=QH.u32[0],QH.u32[1]
        cur[w]=head;cur[w+1]=tail_index;w=w+2
        if head>=128 or tail_index>=128 then return w end
        local jobs,rok=read_jobs(preview,head,tail_index)
        self.qrows_ok=rok;cur[w]=rok and 1 or 2;w=w+1
        if not rok then return w end
        self.jobs=jobs
        return job_words(jobs,w)
    end
    -- QUEUE: the preview queue header and its occupied rows.
    local function read_queue()
        local w=REGION[QUEUE]
        if self.preview then w=queue_words(self.preview,w)end
        clen[QUEUE]=w-REGION[QUEUE]
    end
    -- Briefing: the six loadout records and their widgets' record pointers;
    -- the picker grid when they do not form a loadout.
    local function briefing_words(owner,w)
        local ok=read(owner+454792,480,SMALL,0)
        self.small_ok=ok==true;cur[w]=ok and 1 or 2;w=w+1
        if ok then
            w=records(SMALL,0,6,w)
            for index=0,5 do w=tail(index,owner+422832+index*5464+1984,w)end
        end
        if ok and self.mb_ok and loadout(owner)then self.screen='briefing_loadout';return w end
        self.screen='briefing_grid'
        return grid(owner+864096,w)
    end
    -- Armory: the pre-select records and mode block (one read) and its three
    -- widgets' record pointers; the grid when no pre-select is shown.
    local function armory_words(owner,w)
        local control=owner+280216
        local ok=read(control+37728,256,SMALL,0)
        self.small_ok=ok==true;cur[w]=ok and 1 or 2;w=w+1
        if ok then
            w=words(SMALL,60,4,w)       -- mode block (+37968)
            w=records(SMALL,0,3,w)
        end
        if ok and SMALL.bytes[244]==0 and SMALL.u32[60]<6 then
            self.screen='preselect'
            for index=0,2 do w=tail(index,control+5256+index*12304+1984,w)end
            return w
        end
        self.screen='grid'
        return grid(owner+523752,w)
    end
    -- SCREEN: the block of the screen shown.
    local function read_screen(kind,owner,atlas)
        local w=REGION[SCREEN]
        if atlas and owner then
            cur[w]=kind;w=w+1
            if kind==231 then w=briefing_words(owner,w)else w=armory_words(owner,w)end
        end
        clen[SCREEN]=w-REGION[SCREEN]
    end
    local function component_changed(k)
        if clen[k]~=plen[k] then return true end
        local r=REGION[k]
        for i=r,r+clen[k]-1 do if cur[i]~=prev[i]then return true end end
        return false
    end
    -- Versions: the image tick reads every component but POLICY; the asset
    -- policy reads neither the atlas descriptor nor the screen block.
    local function count_versions()
        local image,policy=false,false
        for k=0,6 do
            if component_changed(k)then
                if k~=POLICY then image=true end
                if k~=DESCRIPTOR and k~=SCREEN then policy=true end
            end
        end
        if image then self.image_version=self.image_version+1 end
        if policy then self.policy_version=self.policy_version+1 end
        return image
    end
    function self:refresh()
        self.refreshes=self.refreshes+1
        cur,prev=prev,cur;clen,plen=plen,clen
        for k=0,6 do clen[k]=0 end
        local w,p=read_globals()
        local kind,world
        w,kind=read_stack(w)
        self.probed=false
        w,p,world=read_ui(w,p)
        clen[UI]=w-REGION[UI]
        self.kind,self.world=kind,world
        reset_screen()
        -- The rest only while a thumbnail screen can be shown, in the order
        -- snapshot() needs it.
        if self.tm and self.sm and self.ui and kind and world then
            local owner=read_controller(kind)
            local atlas
            atlas,p=read_manager(p)
            read_descriptor(atlas)
            read_queue()
            read_screen(kind,owner,atlas)
        end
        clen[POLICY]=p-REGION[POLICY]
        return count_versions()
    end
    -- The idle gate's check (install.lua): the globals block and the state
    -- stack, the first two reads of a refresh, into the view's buffers (the
    -- signature stays as the last refresh left it). 2 reads, nothing
    -- allocated. When the frame is not idle, the next refresh in the same
    -- callback uses these two reads instead of making them again; unprobe()
    -- (before the game update) drops them. Returns the thumbnail manager
    -- pointer (0 when none), the stack depth and its top (-1 outside depth
    -- 1..5), or nil when a read fails or there is no state machine.
    function self:probe()
        self.probed=false
        if not read(base+0x2e380b0,0x140,G,0)then return nil end
        local sm=pointer(G,44)
        if not sm or not read(sm+0x429c,24,STACK,0)then return nil end
        self.probed=true
        local depth=STACK.u32[5]
        local top=depth>=1 and depth<=5 and STACK.u32[depth-1] or -1
        return pointer(G,0) or 0,depth,top
    end
    function self:unprobe()self.probed=false end
    -- Interpreted, like the gate that calls it (install.lua).
    local loaded=rawget(_G,'package') and package.loaded
    local jit_module=rawget(_G,'jit') or (loaded and loaded.jit)
    if jit_module and jit_module.off then jit_module.off(self.probe)end
    -- The lease table owner (header and allocator), read by the policy step
    -- only: 2 reads, own version.
    function self:refresh_lease()
        local lease=self.lease
        for i=0,11 do lease_words[i]=0 end
        if lease then
            lease_words[0]=1;lease_words[1]=lease%4294967296;lease_words[2]=math.floor(lease/4294967296)
            if read(lease,32,LEASE,0)then
                lease_words[0]=lease_words[0]+2
                local h=LEASE.u32
                lease_words[3],lease_words[4],lease_words[5]=h[0],h[1],h[2]
                lease_words[6],lease_words[7],lease_words[8]=h[4],h[5],h[6]
            end
            if read(lease+16416,8,LEASE,32)then
                lease_words[0]=lease_words[0]+4
                lease_words[9],lease_words[10]=LEASE.u32[8],LEASE.u32[9]
            end
        end
        local same=self.lease_checked
        for i=0,11 do if lease_words[i]~=lease_prev[i]then same=false end;lease_prev[i]=lease_words[i]end
        self.lease_checked=true
        if not same then self.lease_version=self.lease_version+1 end
        return not same
    end
    return self
end

function M.new(api,game,exe,signatures,test_calls,state) -- lint-ok: R10 ported from v23 unchanged; split into named steps is a follow-up (differential harness ready)
    local function read(p,n)
        local bytes=assert(api.read(p,n),'Image memory unavailable');return bytes
    end
    local function ptr(p)return api.pointer(read(p,8))end
    -- Code pages that are not resident yet cannot be read (ReadProcessMemory fails): those checks run right
    -- before the first native call instead (checked below); a native is never called unchecked.
    local pending={}
    for _,s in ipairs(signatures)do
        local bytes=s.hex:gsub('..',function(v)return string.char(tonumber(v,16))end)
        local at=(s.module=='game' and game or exe)+s.rva
        local now=api.read(at,#bytes)
        if now then assert(now==bytes,'Image instruction mismatch') else pending[#pending+1]={at,bytes} end
    end
    local function checked(call)
        if #pending==0 then return call end
        return function(...)
            for i=#pending,1,-1 do
                local now=api.read(pending[i][1],#pending[i][2])
                assert(now,'Image code not resident yet');assert(now==pending[i][2],'Image instruction mismatch')
                pending[i]=nil
            end
            return call(...)
        end
    end
    local root=assert(ptr(game+0x2ce14c8));assert(root==exe+0x2870240,'Image API root mismatch')
    local app=assert(ptr(root+16))
    for off,rva in pairs({[368]=0x2ea5a0,[400]=0x2ea9b0,[528]=0x2ed5c0})do
        assert(ptr(app+off)==exe+rva,'Image application API mismatch')
    end
    assert(u32(read(exe+0x16f5510,4),0)==32,'Unexpected texture format size')
    local calls=test_calls or {}
    local create=calls.create or ffi.cast('void *(*)(int,int,int,int,uint32_t,uint8_t)',exe+0x2ea5a0)
    local destroy=calls.destroy or ffi.cast('void (*)(void *)',exe+0x2ea9b0)
    local register=calls.register or ffi.cast('void (*)(uint32_t,void *)',exe+0x2ed5c0)
    local set_texture=calls.texture or ffi.cast('void (*)(void *,uint32_t,void *)',game+0x12e16f0)
    local set_uv=calls.uv or ffi.cast('void (*)(void *,uint64_t,uint64_t)',game+0x12d6c00)
    local set_size=calls.size or ffi.cast('void (*)(void *,uint64_t)',game+0x12dee70)
    local set_alpha=calls.alpha or ffi.cast('void (*)(void *,float)',game+0x12e07e0)
    local material=calls.material or ffi.cast('void (*)(void *,uint64_t,uint8_t)',game+0x12e7510)
    local register_image=calls.register_image or ffi.cast('void (*)(void *,void *)',game+0x1229090)
    create,destroy,register=checked(create),checked(destroy),checked(register)
    set_texture,set_uv,set_size,set_alpha=checked(set_texture),checked(set_uv),checked(set_size),checked(set_alpha)
    material,register_image=checked(material),checked(register_image)
    local byte=calls.byte or function(p,v)ffi.cast('uint8_t *',p)[0]=v end
    local image_material=ffi.new('uint64_t',0x27ef0643)*0x100000000+0x5506e446
    local bindings={}
    local self={prune_checks=0,prune_changes=0,prune_reconciles=0,prune_misses=0,digest=M.digest}
    local retired={}
    local working_backup,restore_working
    state=state or M.state(api,game)
    local WIDGET,ELEMENT,COLUMNS,IDENTITY=buffer(2008),buffer(88),buffer(4),buffer(8)
    local function need(ok)return assert(ok,'Image memory unavailable')end
    local function text(b,offset,n)return ffi.string(b.bytes+offset,n)end
    local function cast(v)return v and ffi.cast('uint8_t *',v)end
    -- Widget fields at +0..+704 and +1984..+2008 in one read; the two reads the
    -- ungated snapshot made, and their failure, if that read fails.
    local function load_widget(address)
        if not api.read(address,2008,WIDGET,0)then
            need(api.read(address,704,WIDGET,0));need(api.read(address+1984,24,WIDGET,1984))
        end
    end
    -- An initialized private material, or the named thumbnail template.
    local function supported(a)
        local lo,hi=a.u32[152],a.u32[153]
        return (lo==0 and hi==0 and pointer(a,150)~=nil) or (lo==0x5506e446 and hi==0x27ef0643)
    end
    -- Configured weapon slots observed in the native preview queue, keyed by the
    -- request identity. A weapon's applied pattern and attachments live here, not
    -- in the thumbnail request record, so this is the only appearance signal the
    -- cache can key on. The queue only holds work while a preview is generating,
    -- so the last observation per identity is remembered for the session.
    local preview_observed={}
    local function observe_previews(st)
        local preview=pointer(st.G,56)
        if not preview then return end
        if not st.qh_ok then need(api.read(preview+50448,8,st.QH,0))end
        local head,tail=st.QH.u32[0],st.QH.u32[1]
        assert(head<128 and tail<128,'Preview queue bounds changed')
        local rows=st.QROWS
        local index,jobs=head,0
        while index~=tail and jobs<16 do
            if not st.qrows_ok then need(api.read(preview+50456+index*200,200,rows,jobs*200))end
            local count=rows.u32[jobs*50+20]
            assert(count<=10,'Preview queue dependency bound changed')
            preview_observed[text(rows,jobs*200+64,8)]=text(rows,jobs*200+88,count*8)
            index=(index+1)%128;jobs=jobs+1
        end
    end
    -- Native state 8 describes a request, not pixels in a newly allocated
    -- replacement. Track completed card regions that the swap left blank.
    local blank_working
    local function controller(kind)
        if not kind then
            local sm=ptr(game+0x2e38160);if not sm then return end
            local st=read(sm+0x429c,24);local depth=u32(st,20)
            local top=depth>=1 and depth<=5 and u32(st,(depth-1)*4)
            kind=top==5 and 226 or (top==14 and 231 or nil)
            if not kind then return end
        end
        local d=ptr(game+0x2ce2040);if not d then return end
        local n=u32(read(d+5740,4),0);assert(n<=64,'Image dispatch bounds')
        local rows=n>0 and read(d+5744,n*16) or ''
        local found
        for i=0,n-1 do if u32(rows,i*16+8)==kind then
            assert(not found,'Ambiguous image controller');found=api.pointer(rows,i*16)
        end end
        return found,kind
    end
    local function uv(element,bytes)
        ffi.copy(packed,bytes,16);set_uv(element,packed[0],packed[1])
    end
    local function size(element,bytes)
        ffi.copy(packed,bytes,8);set_size(element,packed[0])
    end
    -- Returns how many bindings were released. A dry pass (verify_gate) only
    -- counts the bindings a real pass would release.
    local function reconcile(clear,dry) -- lint-ok: R10 ported from v23 unchanged; split into named steps is a follow-up (differential harness ready)
        if not next(bindings)then return 0 end
        local owner,kind=controller()
        local ui=ptr(game+0x2e380c8)
        local world=ui and ptr(ui+15432)
        local tm=ptr(game+0x2e380b0)
        local atlas=tm and ptr(tm+11400)
        local keep,released={},0
        for _,b in pairs(bindings)do
            local kept=false
            -- Fixed embedded widget offsets are valid only while this exact
            -- controller remains registered. Never dereference a departed UI.
            if owner==b.owner and kind==b.controller_kind and world==b.world and atlas then
                local current=read(b.widget+1984,8)
                local flags=u32(read(b.element,4),0)
                -- Briefing keeps its controller/widgets while retiring their
                -- materials on picker entry. The texture setter clones this
                -- material unconditionally: a cleared pointer crashes natively.
                -- A replacement material also ends our binding's ownership.
                local material_pointer=read(b.element+328,8)
                if bit.band(flags,0x3c0000)==0xc0000 and api.pointer(material_pointer)
                    and material_pointer==b.material_pointer then
                    local record=api.pointer(current)
                    local same=current==b.record_pointer and record
                        and read(record,8)==b.visual and read(record+60,8)==b.indices
                    local owned=same and read(record+68,1)=='\0'
                        and read(b.widget+2005,1)~='\0'
                    if not clear and owned then keep[pointer_key(b.widget)]=b;kept=true
                    elseif not dry then
                        -- Remove our texture before any detached atlas is freed.
                        -- Never restore an old transparent snapshot every frame.
                        set_texture(b.element,984135806,atlas)
                        if clear and owned then
                            byte(record+68,1)
                            set_alpha(b.element,0);set_alpha(b.widget+616,1)
                        end
                    end
                end
            end
            if not kept then released=released+1 end
        end
        if not dry then bindings=keep end
        return released
    end
    function self:restore(return_working)
        if return_working and restore_working then restore_working()end
        reconcile(true)
    end
    -- The gate: reference is the state version the last full snapshot decoded;
    -- verified says the bindings were checked against that state; dropped says
    -- a prune released a binding since, which the next tick must follow up.
    local reference,verified,dropped
    -- Whether prune() has bindings to check before the game update.
    function self:bound()return next(bindings)~=nil end
    -- The idle gate (install.lua): no binding to check, no retired texture to
    -- drain and no released binding the next tick must follow up.
    function self:quiet()return next(bindings)==nil and #retired==0 and not dropped end
    -- Before the game update. The bindings depend only on state the refresh
    -- covers, so they are checked on the first prune after a full snapshot (a
    -- remap there can leave a binding whose new item has no crop; this prune
    -- releases it, as every prune did) and whenever the refresh sees a change
    -- since that snapshot. Otherwise the per-binding reads are skipped. This is
    -- the frame's second state check (the first follows the game update, in
    -- tick); it runs only while images are bound.
    function self:prune()
        if not next(bindings)then return end
        if verified and reference then
            self.prune_checks=self.prune_checks+1
            state:refresh()
            if state.image_version==reference then
                if not self.verify or reconcile(false,true)==0 then return end
                self.prune_misses=self.prune_misses+1
            else self.prune_changes=self.prune_changes+1 end
        end
        self.prune_reconciles=self.prune_reconciles+1
        if reconcile(false)>0 then dropped=true end
        verified=true
    end
    -- After the game update: one refresh, true when nothing the last full
    -- snapshot decoded has changed and no binding was released since.
    function self:unchanged()
        state:refresh()
        return reference~=nil and state.image_version==reference and not dropped
    end
    local function descriptor(atlas)
        local d=read(atlas,104)
        assert(u32(d,8)==0 and u32(d,12)==0 and u32(d,28)==1 and u32(d,32)==1
            and d:byte(100)==1,'Unsupported thumbnail texture descriptor')
        local w,h=u32(d,20),u32(d,24)
        assert(w>=64 and h>=64 and w<=4096 and h<=16384,'Thumbnail dimensions exceed bounds')
        return d,w,h
    end
    -- A widget's fields: a is the widget read (+0..+704, +1984..+2008), rec
    -- the 80-byte record string.
    local function widget_row(result,address,a,rec,item)
        local p=cast(address)
        return {key=item.key,owner=result.owner,world=result.world,controller_kind=result.controller_kind,
            widget=p,element=p+272,record_pointer=text(a,1984,8),
            visual=raw(rec,0,8),bound=a.bytes[2005]~=0,invalidated=rec:byte(69)~=0,
            named_material=a.u32[152]==0x5506e446 and a.u32[153]==0x27ef0643,
            native_ready=item.ready,pixels_ready=item.pixels_ready,
            indices=raw(rec,60,8),uv=text(a,548,16),size=text(a,284,8),
            alpha=a.f32[85],spinner_alpha=a.f32[171],
            box_width=a.f32[3]*a.f32[7],box_height=a.f32[4]*a.f32[8],fit=a.u32[500]}
    end
    local function widget(result,address,rec,item)
        load_widget(address)
        if bit.band(WIDGET.u32[68],0x3c0000)~=0xc0000 or not supported(WIDGET)then return end
        result.widgets[#result.widgets+1]=widget_row(result,address,WIDGET,rec,item)
    end
    -- Handoff boundaries that keep the current request (the switch boundary,
    -- can_freeze, is set by snapshot):
    --   idle:    every card complete, so the whole request is retained.
    --   rebind:  every card complete, but an earlier visible handoff left some
    --            completed regions blank in the working atlas. images.lua
    --            detaches only when those regions' visible tiles hold crops.
    --   visible: every card backing a visible tile is complete and no card is
    --            composing, so a short visit keeps what the player saw.
    local function idle_gate(result,mb,by_index,owned) -- lint-ok: R10 ported from v23 unchanged; split into named steps is a follow-up (differential harness ready)
        local m=mb.u32
        local ok=#result.widgets>0 and #result.items==result.expected_count
        for c=0,5 do if m[c*454+458]~=0 and not owned[c]then
            result.can_freeze=false;ok=false
        end end
        for _,item in pairs(by_index)do if not item.key then ok=false end end
        -- The registry includes hidden widgets from the screen we just left.
        -- An idle detach is allowed only when every visible consumer can be
        -- rebound in this callback. Hidden consumers are moved to fresh too.
        result.registry={};local mapped={};local visible_ready=true
        for _,w in ipairs(result.widgets)do
            mapped[pointer_key(w.element)]=true
            if w.fit<1 or w.fit>3 or not finite(w.box_width) or not finite(w.box_height)
                or w.box_width<=0 or w.box_height<=0 then ok=false end
            if not w.pixels_ready then visible_ready=false end
        end
        local visible=ok and not result.complete and result.quiescent
            and result.blank_cards==0 and visible_ready
        -- Registry reads cost one native read per consumer. Skip them only on
        -- generation ticks where no handoff could be accepted; a complete
        -- request always lists them because restore_working rebinds them.
        if result.can_freeze or result.complete or visible then
            local n=m[2856];assert(n<=128,'Image registry bounds')
            for i=0,n-1 do
                local element=assert(pointer(mb,2858+i*2))
                result.registry[#result.registry+1]=cast(element)
                if ok and not mapped[pointer_key(element)]then
                    need(api.read(element,88,ELEMENT,0))
                    if bit.band(ELEMENT.u32[0],0x3c0000)~=0xc0000 or ELEMENT.f32[21]~=0 then
                        ok=false
                    end
                end
            end
        end
        result.can_freeze_idle=ok and result.complete and result.blank_cards==0
        result.can_freeze_rebind=ok and result.complete and result.blank_cards>0
        result.can_freeze_visible=ok and visible
    end
    -- The ungated snapshot, decoded from the state's buffers instead of a read
    -- per field. It asserts at the same fields; a buffer whose refresh read
    -- failed is read again at the ungated size first, so a failure raises the
    -- same error at the same point.
    local function owner_of(st,kind)
        need(st.dptr_ok or api.read(st.base+0x2ce2040,8,st.DPTR,0))
        local d=pointer(st.DPTR,0);if not d then return nil end
        local rows=st.DROWS
        if not st.rows_ok then
            need(api.read(d+5740,4,rows,0))
            local n=rows.u32[0];assert(n<=64,'Image dispatch bounds')
            if n>0 then need(api.read(d+5744,n*16,rows,4))end
        end
        local n=rows.u32[0];assert(n<=64,'Image dispatch bounds')
        local found
        for i=0,n-1 do if rows.u32[i*4+3]==kind then
            assert(not found,'Ambiguous image controller');found=pointer(rows,1+i*4)
        end end
        return found
    end
    local function widget_pointer(st,index,address)
        if not st.tails_ok[index]then need(api.read(address,8,st.TAILS,index*8))end
        return pointer(st.TAILS,index*2)
    end
    local function decode(st) -- lint-ok: R10,R11 ported from v23 unchanged; split into named steps is a follow-up (differential harness ready)
        local result={items={},widgets={},expected_count=0}
        local G,MB,DESC=st.G,st.MB,st.DESC
        need(st.g_ok or api.read(st.base+0x2e380b0,0x140,G,0))
        local sm,ui,tm=pointer(G,44),pointer(G,6),pointer(G,0)
        if not tm then return result end
        -- The detached render texture is globally allocated through the engine
        -- application API, not owned by the transient Armory UI world. Preserve
        -- it while the thumbnail manager survives, even with no active menu.
        result.context=pointer_key(tm);result.manager=cast(tm)
        if not sm or not ui then return result end
        need(st.stack_ok or api.read(sm+0x429c,24,st.STACK,0))
        local depth=st.STACK.u32[5]
        local top=depth>=1 and depth<=5 and st.STACK.u32[depth-1]
        local kind=top==5 and 226 or (top==14 and 231 or nil)
        if not kind then return result end
        need(st.ui_ok or api.read(ui+15432,8,st.UI,0))
        local world=pointer(st.UI,0);if not world then return result end
        local owner=owner_of(st,kind)
        result.world=cast(world);result.controller_kind=kind;result.owner=cast(owner)
        result.view=pointer_key(world)..string.char(kind)..(owner and pointer_key(owner) or '')
        need(st.mb_ok or api.read(tm,12464,MB,0))
        local m=MB.u32
        local atlas=pointer(MB,2850)
        if not atlas then return result end
        need(st.desc_ok or api.read(atlas,104,DESC,0))
        local d=DESC.u32
        assert(d[2]==0 and d[3]==0 and d[7]==1 and d[8]==1
            and DESC.bytes[99]==1,'Unsupported thumbnail texture descriptor')
        local w,h=d[5],d[6]
        assert(w>=64 and h>=64 and w<=4096 and h<=16384,'Thumbnail dimensions exceed bounds')
        local atlas_pointer=cast(atlas)
        result.atlas=atlas_pointer;result.width=w;result.height=h;result.bytes=w*h*4
        result.descriptor_id=text(DESC,0,8)
        result.layout=text(MB,16,16)..text(MB,11392,8)..text(DESC,8,28)
        -- Appearance observation is an optimization; a transient queue read must
        -- never invalidate the sample.
        pcall(observe_previews,st)
        local by_index,ids={},{}
        result.source_cards={};result.blank_cards=0
        if blank_working and (blank_working.atlas~=atlas_pointer or blank_working.id~=result.descriptor_id
            or blank_working.context~=result.context or blank_working.manager~=result.manager)then blank_working=nil end
        local active,all_complete,safe,nonempty=m[2839],true,true,0
        local phase=m[2847]
        for c=0,5 do
            local at=c*1816;local state,n=m[c*454+458],m[c*454+459]
            assert(state<=8 and n<=15,'Image card bounds')
            if state~=0 then
                local stamp={string.char(n)}
                result.expected_count=result.expected_count+n
                nonempty=nonempty+1
                if state~=8 then all_complete=false end
                if state~=3 and state~=4 and state~=5 then safe=false end
                for i=0,n-1 do
                    local o=at+32+i*120;local item_kind=m[o/4+25]
                    local input=text(MB,o,104)
                    stamp[#stamp+1]=M.key('',input,'')..text(MB,o+56,16)
                    if item_kind<=4 then
                        local item={input=input,card=c,index=i,ready=state==8,rectangle=text(MB,o+56,16),
                            preview=preview_observed[text(MB,o+24,8)]}
                        by_index[c*15+i]=item
                    end
                end
                result.source_cards[c]={state=state,stamp=table.concat(stamp)}
            end
            local source=result.source_cards[c]
            if blank_working and blank_working.cards[c]then
                if not source or state~=8 or source.stamp~=blank_working.cards[c]then
                    blank_working.cards[c]=nil
                else result.blank_cards=result.blank_cards+1 end
            end
        end
        for _,item in pairs(by_index)do
            item.pixels_ready=item.ready and not (blank_working and blank_working.cards[item.card])
        end
        result.complete=nonempty>0 and all_complete and active==0xffffffff
        result.can_freeze=nonempty>0 and safe and active<6 and (phase==4 or phase==5)
        -- Nothing is composing into the working atlas: every nonempty card is
        -- queued/preparing (3/4/5) or complete (8), and the single active card,
        -- if any, is still preparing. States 6/7 finalize into the atlas.
        local quiet=nonempty>0
        for c=0,5 do
            local source=result.source_cards[c]
            if source and source.state~=3 and source.state~=4 and source.state~=5
                and source.state~=8 then quiet=false end
        end
        if active~=0xffffffff then
            local source=active<6 and result.source_cards[active]
            if not source or source.state<3 or source.state>5 or (phase~=4 and phase~=5)then quiet=false end
        end
        result.quiescent=quiet
        result.tile_width=MB.f32[6];result.tile_height=MB.f32[7]
        if not owner then result.can_freeze=false;return result end
        local small=st.SMALL
        if kind==231 then
            if not st.small_ok then need(api.read(owner+454792,480,small,0))end
            local expected={2,3,4,0,0,1};local slots={};local valid=true
            for index=0,5 do
                local rec=text(small,index*80,80)
                local card,slot=u32(rec,60),u32(rec,64)
                local item=card<6 and slot<15 and by_index[card*15+slot]
                local address=owner+422832+index*5464
                if not item or u32(rec,8)~=3 or u32(item.input,100)~=expected[index+1]
                    or widget_pointer(st,index,address+1984)~=owner+454792+index*80 then valid=false;break end
                slots[#slots+1]={rec=rec,item=item,address=address}
            end
            if valid then
                result.screen='briefing_loadout';local owned={}
                for index,slot in ipairs(slots)do
                    local item,rec=slot.item,slot.rec
                    item.key=M.key(result.layout,item.input,'briefing_loadout'..string.char(index-1)..raw(rec,0,8)..raw(rec,72,4))
                    result.items[#result.items+1]=item;owned[item.card]=true
                    ids[#ids+1]=string.char(item.card,item.index)..item.key
                    widget(result,slot.address,rec,item)
                end
                result.capture_id=pointer_key(atlas)..table.concat(ids)
                idle_gate(result,MB,by_index,owned)
                return result
            end
        end
        local control=owner+280216
        -- The pre-select records (+37728) and mode block (+37968) are one read.
        local pre=false
        if kind==226 then
            if not st.small_ok then need(api.read(control+37968,16,small,240))end
            pre=small.bytes[244]==0 and small.u32[60]<6
        end
        if pre then
            local mode=small.u32[63];assert(mode<=2,'Pre-select mode bounds')
            result.screen=mode==0 and 'weapon_preselect' or 'cosmetic_preselect'
            if not st.small_ok then need(api.read(control+37728,240,small,0))end
            local owned={[small.u32[60]]=true}
            local variant='preselect'..text(small,252,4)
            for index=0,2 do
                local rec=text(small,index*80,80)
                local card,slot=u32(rec,60),u32(rec,64)
                local item=card<6 and slot<15 and by_index[card*15+slot]
                if item and owned[card] and u32(rec,8)==3 then
                    item.key=M.key(result.layout,item.input,variant..raw(rec,0,8)..raw(rec,72,4))
                    result.items[#result.items+1]=item
                    ids[#ids+1]=string.char(card,slot)..item.key
                    local address=control+5256+index*12304
                    if widget_pointer(st,index,address+1984)==control+37728+index*80 then widget(result,address,rec,item)end
                end
            end
            if #result.items>0 then result.capture_id=pointer_key(atlas)..table.concat(ids)end
            idle_gate(result,MB,by_index,owned)
            return result
        end
        result.screen=kind==231 and 'briefing_grid' or 'grid'
        local grid=owner+(kind==231 and 864096 or 523752)
        local meta=st.META
        if not (st.meta_ok and st.meta_address==grid)then need(api.read(grid+597772,24892,meta,0))end
        local g=meta.u32
        local count=g[0];assert(count<=12,'Image grid row bounds')
        -- Every nonempty card must belong to this grid. Empty cards do not
        -- render, so small categories can hand over the completed old atlas too.
        local owned={}
        for i=0,5 do
            local card=g[6205+i*3]              -- +622592
            if card<6 then owned[card]=true end
        end
        for c=0,5 do if m[c*454+458]~=0 and not owned[c]then result.can_freeze=false end end
        local grid_kind=text(meta,4280,4)       -- +602052
        -- Resolve every requested item through its grid record, including
        -- offscreen cards. Record style distinguishes alternate camera presets.
        for index=0,255 do
            local r=1083+index*20               -- record at +602104
            local card,slot=g[r+15],g[r+16]
            local item=card<6 and slot<15 and by_index[card*15+slot]
            if item and g[r+2]==3 then
                local key=M.key(result.layout,item.input,grid_kind..text(meta,r*4,8)..text(meta,r*4+72,4))
                assert(not item.key or item.key==key,'Ambiguous grid request identity')
                if not item.key then
                    item.key=key;result.items[#result.items+1]=item
                    -- Slot moves are new atlas work even if the semantic key
                    -- remains the same (for example when the grid scrolls).
                    ids[#ids+1]=string.char(item.card,item.index)..key
                end
            end
        end
        result.capture_id=pointer_key(atlas)..table.concat(ids)
        for row=0,count-1 do
            local rb=grid+2816+row*44752
            need(api.read(rb+44724,4,COLUMNS,0))
            local columns=COLUMNS.u32[0];assert(columns<=4,'Image grid column bounds')
            for col=0,columns-1 do
                local address=rb+9192+col*11112
                load_widget(address)
                local record=pointer(WIDGET,496)
                local record_offset=record and record-(grid+602104) or -1
                if record_offset>=0 and record_offset<256*80 and record_offset%80==0 then
                    local r=1083+record_offset/4
                    local card,index=g[r+15],g[r+16]
                    local item=card<6 and index<15 and by_index[card*15+index]
                    if item and item.key and g[r+2]==3 and bit.band(WIDGET.u32[68],0x3c0000)==0xc0000
                        and supported(WIDGET) then
                        result.widgets[#result.widgets+1]=widget_row(result,address,WIDGET,text(meta,r*4,80),item)
                    end
                end
            end
        end
        idle_gate(result,MB,by_index,owned)
        return result
    end
    -- fresh: decode what unchanged() just read (nothing ran in between).
    -- Otherwise the state is read again, which also records the mod's own
    -- writes since.
    function self:snapshot(fresh)
        if not fresh then state:refresh()end
        local result=decode(state)
        reference,verified,dropped=state.image_version,false,false
        return result
    end
    -- verify_gate only: an independent read and decode that leaves the gate's
    -- state and reference untouched.
    local peek_state
    function self:peek()
        peek_state=peek_state or M.state(api,game)
        peek_state:refresh()
        return decode(peek_state)
    end
    function self:capture(s)
        if #s.widgets==0 or #s.items==0 then return end
        local p={atlas=s.atlas,layout=s.layout,bytes=s.bytes,descriptor_id=s.descriptor_id,entries={}}
        for _,item in ipairs(s.items)do
            -- State 8 is the native per-card completion contract. Other cards
            -- can still be generating; their pixels must never enter this map.
            if item.ready and item.pixels_ready~=false then
            -- Recovered 0x10F0CB0 crop formula; fixture tests compare this with
            -- the actual native-bound UVs, rather than duplicating expectations.
            local r=item.rectangle
            local x=float(r,0)+1/s.tile_width
            local y=(1-float(r,4)-float(r,12))/6+item.card/6+1/s.tile_height
            local w=float(r,8)-2/s.tile_width
            local h=float(r,12)/6-2/s.tile_height
            assert(finite(x) and finite(y) and w>0 and h>0 and x>=0 and y>=0
                and x+w<=1.001 and y+h<=1.001,'Invalid completed image rectangle')
            local pixels_w,pixels_h=w*s.tile_width,h*s.tile_height*6
            fp[0],fp[1],fp[2],fp[3]=x,y,x+w,y+h
            p.entries[item.key]={uv=ffi.string(fp,16),width=pixels_w,height=pixels_h,
                preview=item.preview}
            end
        end
        if not next(p.entries)then return end
        return p
    end
    function self:freeze(s,p)
        local same_request=(s.can_freeze_idle or s.can_freeze_rebind or s.can_freeze_visible)
            and p.request_id==s.capture_id
        assert((s.can_freeze or same_request)
            and s.atlas==p.atlas and s.layout==p.layout,'Unsafe atlas handoff')
        assert(ptr(game+0x2e380b0)==s.manager and ptr(s.manager+11400)==p.atlas,'Atlas owner changed')
        local d,w,h=descriptor(p.atlas);assert(raw(d,0,8)==p.descriptor_id,'Atlas generation changed')
        -- Same API and six arguments as the native atlas creator. Command 14
        -- creates the replacement before command 31 registers it for later draws.
        local fresh=create(w,h,1,0,3400165836,1)
        if fresh==nil then return end
        fresh=ffi.cast('uint8_t *',fresh)
        register(3400165836,fresh)
        ffi.cast('void **',s.manager+11400)[0]=fresh
        -- Rebind every native registered consumer, including hidden leftovers,
        -- before the old atlas can become independently releasable. apply()
        -- restores retained crops for the active screen in this same callback.
        for _,element in ipairs(s.registry or {})do set_texture(element,984135806,fresh)end
        -- The game owns fresh and will destroy it normally. Only the detached
        -- original belongs to us; never return it to the working atlas slot.
        local texture={handle=p.atlas,replacement=fresh,bytes=p.bytes,id=p.descriptor_id,width=w,height=h}
        blank_working={atlas=fresh,id=read(fresh,8),context=s.context,manager=s.manager,cards={}}
        for c,source in pairs(s.source_cards)do
            if source.state==8 then blank_working.cards[c]=source.stamp end
        end
        if s.can_freeze_idle and p.request_id==s.capture_id then
            working_backup={texture=texture,context=s.context,manager=s.manager,
                request=pointer_key(fresh)..s.capture_id:sub(9),layout=s.layout}
        else working_backup=nil end
        return texture
    end
    -- Textures whose ownership the last apply checked. A tick the gate skips
    -- checks them again (one 8-byte read each), as apply did every frame.
    local shown,shown_count={},0
    function self:check_textures()
        for i=1,shown_count do
            local t=shown[i]
            local ok=not t.destroyed and not t.returned
            if ok then
                need(api.read(t.address,8,IDENTITY,0))
                ok=IDENTITY.u32[0]==t.id_low and IDENTITY.u32[1]==t.id_high
            end
            assert(ok,'Cached texture ownership changed')
        end
    end
    -- The fourth result counts widgets with a crop that stayed unbound (fit,
    -- ratio or material not usable yet); the ungated tick retried those every
    -- frame. The fifth counts widgets whose material and registration this
    -- apply initialized: those writes change what the next snapshot decodes.
    function self:apply(s,entries) -- lint-ok: R10 ported from v23 unchanged; split into named steps is a follow-up (differential harness ready)
        local hits,misses,early,unresolved,initialized=0,0,0,0,0
        local checked={}
        shown_count=0
        for _,w in ipairs(s.widgets)do
            local entry=entries[w.key]
            if entry and w.box_width>0 and w.box_height>0 and w.fit>=1 and w.fit<=3 then
                local ratio=w.fit==1 and math.max(entry.width/w.box_width,entry.height/w.box_height)
                    or (w.fit==2 and entry.height/w.box_height or entry.width/w.box_width)
                if not (finite(ratio) and ratio>0)then unresolved=unresolved+1
                else
                    local t=entry.texture
                    if not checked[t]then
                        assert(not t.destroyed and not t.returned
                            and read(t.handle,8)==t.id,'Cached texture ownership changed')
                        checked[t]=true
                        if not t.address then
                            local b1,b2,b3,b4,b5,b6,b7,b8=t.id:byte(1,8)
                            t.address=tonumber(ffi.cast('uintptr_t',t.handle))
                            t.id_low=b1+b2*256+b3*65536+b4*16777216
                            t.id_high=b5+b6*256+b7*65536+b8*16777216
                        end
                        shown_count=shown_count+1;shown[shown_count]=t
                    end
                    if not w.bound or w.invalidated or w.named_material then
                        initialized=initialized+1
                        local tm=assert(ptr(game+0x2e380b0))
                        assert(u32(read(tm+11424,4),0)<128,'Image registration full')
                        -- Freshly recreated widgets still reference the named
                        -- thumbnail template. Clone the private material using
                        -- the normal native contract before binding our texture.
                        material(w.element,image_material,1)
                        -- A missing template may leave initialization without
                        -- a material. Do not enter the native texture setter.
                        if ptr(w.element+328)then
                            register_image(tm,w.element)
                            -- This byte means the UI has an image, not that the
                            -- native card finished. Native destruction unregisters
                            -- it; new requests invalidate it through record+68.
                            byte(w.widget+2005,1)
                            byte(assert(api.pointer(w.record_pointer))+68,0)
                        end
                    end
                    local material_pointer=read(w.element+328,8)
                    if api.pointer(material_pointer)then
                        set_texture(w.element,984135806,entry.texture.handle)
                        -- The setter can privatize a shared material. Track the
                        -- final instance, not the pointer from before that call.
                        w.material_pointer=read(w.element+328,8)
                        bindings[pointer_key(w.widget)]=w
                        uv(w.element,entry.uv)
                        fp[0],fp[1]=entry.width/ratio,entry.height/ratio
                        size(w.element,ffi.string(fp,8))
                        set_alpha(w.widget+616,0);set_alpha(w.element,1)
                        hits=hits+1
                        if not w.native_ready then early=early+1 end
                    else misses=misses+1;unresolved=unresolved+1 end
                end
            else
                misses=misses+1
                if entry then unresolved=unresolved+1 end
            end
        end
        -- Presentation follows the cache. A crop whose key the cache no longer
        -- holds (the weapon was re-configured, or the entry was evicted) must
        -- stop being drawn, so the widget is handed back to the native pipeline
        -- and its own render becomes visible as soon as it is composed.
        local tm=ptr(game+0x2e380b0)
        local atlas=tm and ptr(tm+11400)
        if atlas then
            for key,b in pairs(bindings)do
                if not entries[b.key]and b.world==s.world and b.owner==s.owner then
                    local record=api.pointer(read(b.widget+1984,8))
                    local material_pointer=read(b.element+328,8)
                    if material_pointer==b.material_pointer then
                        set_texture(b.element,984135806,atlas)
                        if record and read(b.widget+1984,8)==b.record_pointer
                            and read(record,8)==b.visual and read(record+60,8)==b.indices
                            and read(b.widget+2005,1)~='\0' then
                            byte(record+68,1)
                            set_alpha(b.element,0);set_alpha(b.widget+616,1)
                        end
                    end
                    bindings[key]=nil
                end
            end
        end
        return hits,misses,early,unresolved,initialized
    end
    local function destroy_owned(t)
        if t.destroyed or t.returned then return end
        local tm=ptr(game+0x2e380b0)
        assert(not tm or ptr(tm+11400)~=t.handle,'Refusing to release the game working atlas')
        local d=read(t.handle,8)
        assert(raw(d,0,8)==t.id,'Retained texture identity changed')
        destroy(t.handle)
        t.destroyed=true
    end
    restore_working=function()
        local backup=working_backup
        if not backup or backup.texture.destroyed or backup.texture.returned then return end
        local s=self:snapshot();local t=backup.texture
        -- Idle retention leaves a blank replacement behind native state-8
        -- cards. If those exact requests are still current during disable or
        -- pressure cleanup, return the real pixels to native ownership first.
        -- A different request/manager/layout already owns its own generation.
        if s.context~=backup.context or s.manager~=backup.manager or s.capture_id~=backup.request
            or s.layout~=backup.layout or not s.complete or s.atlas~=t.replacement then working_backup=nil;return end
        assert(read(t.handle,8)==t.id,'Idle backup texture identity changed')
        register(3400165836,t.handle)
        ffi.cast('void **',s.manager+11400)[0]=t.handle
        for _,element in ipairs(s.registry or {})do set_texture(element,984135806,t.handle)end
        t.returned=true
        destroy(t.replacement)
        blank_working=nil
        working_backup=nil
    end
    function self:destroy(t)
        if t.retired or t.destroyed then return end
        if (t.pins or 0)>0 then retired[#retired+1]=t else destroy_owned(t)end
        t.retired=true
    end
    function self:drain()
        for i=#retired,1,-1 do
            if (retired[i].pins or 0)==0 then destroy_owned(retired[i]);table.remove(retired,i)end
        end
    end
    return self
end
return M

end)()
local images=(function()
-- Retain complete atlases immediately, before native layout changes destroy them.
-- Native requests continue normally; cached images replace presentation only.
local M={}
function M.new(adapter,options)
    local self={adapter=adapter,entries={},textures={},bytes=0,hits=0,misses=0,
        retained=0,released=0,late_switches=0,early_hits=0,pending_drops=0,
        ready_items=0,missing_ready_items=0,pending_items=0,partial_retained=0,
        idle_retained=0,visible_retained=0,evicted=0,ticks=0,
        grid_hits=0,preselect_hits=0,briefing_hits=0,clear_count=0,
        rendered_items=0,refreshed=0,changed_items=0,reappeared=0,
        gated_ticks=0,full_changed=0,full_pending=0,full_pressure=0,full_retry=0,gate_misses=0,
        status='learning_images',enabled=options.images~=false,verify=options.verify_gate==true}
    adapter.verify=self.verify
    local pending,context,last_capture,view
    -- The gate (docs/UPDATE_GATE.md). touched: textures the last full tick
    -- marked as used; applied: that tick bound crops; retry: its apply left a
    -- widget with a crop unbound, which the ungated tick retried every frame,
    -- or initialized a widget's material, which the next snapshot must read
    -- back; pressured: it ran under memory pressure (the tick after pressure
    -- ends does work).
    local touched,touched_count,applied,retry,pressured={},0,false,false,false
    local verify_reference
    -- A retained crop describes one native render. Cards stop being complete
    -- when the native pipeline re-queues them (screen rebuild, scroll, or an
    -- appearance change such as a weapon pattern), and whatever they render
    -- next supersedes the crop captured before it. Keys stay marked until a
    -- capture adopts their new pixels.
    local rendered={}
    local function count_surface(screen,hits)
        if screen=='grid' then
            self.grid_hits=self.grid_hits+hits
        elseif screen=='weapon_preselect' or screen=='cosmetic_preselect' then
            self.preselect_hits=self.preselect_hits+hits
        elseif screen=='briefing_grid' or screen=='briefing_loadout' then
            self.briefing_hits=self.briefing_hits+hits
        end
    end
    local function reset_request()
        pending=nil;last_capture=nil;self.pending_items=0
        self.ready_items=0;self.missing_ready_items=0;self.blank_ready_items=0
        self.rendered_items=0;self.changed_items=0
        self.last_hits=0;self.last_misses=0;self.last_early_hits=0
    end
    function self:before()
        adapter:prune()
    end
    -- Whether before() has work: bindings to check.
    function self:bound()return adapter.bound==nil or adapter:bound()end
    -- The idle gate (install.lua): the last full tick saw no thumbnail screen
    -- and bound nothing, nothing is pending or waiting for a retry, it ran
    -- without memory pressure and the adapter has no binding or retired
    -- texture left. A skipped tick would then only repeat a gated tick that
    -- adds nothing.
    function self:quiet()
        if not self.enabled then return true end
        return self.screen=='none' and not pending and not retry and not pressured and not applied
            and (adapter.quiet==nil or adapter:quiet())
    end
    function self:clear(reason)
        if #self.textures>0 then self.clear_count=self.clear_count+1;self.last_clear_reason=reason or 'cleanup'end
        adapter:restore(true)
        self.entries={};rendered={};reset_request()
        -- Remove each reference only after its release succeeds, for retryable cleanup.
        while #self.textures>0 do
            local t=self.textures[#self.textures]
            adapter:destroy(t)
            self.bytes=self.bytes-t.bytes;self.released=self.released+1
            table.remove(self.textures)
        end
        self.status='learning_images'
    end
    local function release_superseded()
        local used,unused={},false
        for _,entry in pairs(self.entries)do used[entry.texture]=true end
        for _,t in ipairs(self.textures)do if not used[t]then unused=true;break end end
        if not unused then return false end
        -- A more complete atlas can replace earlier partial copies. Unbind
        -- cached UI references before releasing any now-unreferenced texture.
        adapter:restore()
        for i=#self.textures,1,-1 do
            local t=self.textures[i]
            if not used[t]then
                adapter:destroy(t);self.bytes=self.bytes-t.bytes
                self.released=self.released+1;table.remove(self.textures,i)
            end
        end
        return true
    end
    local function retain(s,candidate,idle)
        if candidate.bytes>128*1024*1024 then self.status='image_budget_full';return s,false end
        local protected={}
        for _,item in ipairs(s.items)do
            local entry=self.entries[item.key]
            if entry then protected[entry.texture]=true end
        end
        while #self.textures>=8 or self.bytes+candidate.bytes>128*1024*1024 do
            local victim,index
            for i,t in ipairs(self.textures)do
                if not protected[t] and (not victim or (t.used or 0)<(victim.used or 0))then victim,index=t,i end
            end
            if not victim then self.status='image_budget_full';return s,false end
            adapter:restore()
            for key,entry in pairs(self.entries)do if entry.texture==victim then self.entries[key]=nil end end
            adapter:destroy(victim);table.remove(self.textures,index)
            self.bytes=self.bytes-victim.bytes;self.released=self.released+1;self.evicted=self.evicted+1
            s=adapter:snapshot()
        end
        local texture=adapter:freeze(s,candidate)
        if not texture then return s,false end
        texture.used=self.ticks
        self.textures[#self.textures+1]=texture
        self.bytes=self.bytes+texture.bytes;self.retained=self.retained+1
        if idle then self.idle_retained=self.idle_retained+1 end
        if not candidate.all_complete then self.partial_retained=self.partial_retained+1 end
        for key,value in pairs(candidate.entries)do
            -- Count only crops that replaced an existing crop; a first capture
            -- of a re-rendered item is a miss, not a refresh.
            if self.entries[key] and rendered[key]then self.refreshed=self.refreshed+1 end
            value.texture=texture;self.entries[key]=value;rendered[key]=nil
        end
        s.atlas=texture.replacement
        if release_superseded()then s=adapter:snapshot()end
        return s,true
    end
    -- Choose a same-request handoff. A visible handoff runs only while a
    -- visible tile has no crop at all, so warm visits keep the single
    -- whole-request refresh and never allocate an extra replacement atlas.
    -- A rebind handoff follows it once the offscreen cards finish; tiles over
    -- the regions it left blank must already be served from retained crops.
    local function handoff_mode(s)
        if s.can_freeze_idle then return 'idle' end
        if s.can_freeze_rebind then
            for _,w in ipairs(s.widgets)do
                if not w.pixels_ready and not self.entries[w.key]then return nil end
            end
            return 'idle'
        end
        if s.can_freeze_visible then
            for _,w in ipairs(s.widgets)do
                if not self.entries[w.key]then return 'visible' end
            end
        end
        return nil
    end
    -- verify_gate: compare what a full snapshot would decode now with the
    -- decode taken right after the last full tick. Any difference is a change
    -- the gate did not see.
    local PARTS={'screen','items','widgets','presentation','registry','cards'}
    local function gate_missed()
        local now=adapter.digest(adapter:peek())
        local missed=false
        for _,part in ipairs(PARTS)do
            if now[part]~=verify_reference[part]then
                local key='gate_misses_'..part
                self[key]=(self[key] or 0)+1;missed=true
            end
        end
        if missed then self.gate_misses=self.gate_misses+1 end
        return missed
    end
    local full
    function self:tick(pressure)
        if not self.enabled then self.status='images_disabled';return end
        self.ticks=self.ticks+1
        -- One state refresh. When nothing the last full tick decoded has
        -- changed, nothing is pending and no widget waits for a retry, a full
        -- tick would only repeat that tick: re-send the same texture, UV, size
        -- and opacity (native code keeps them on bound widgets) and add the
        -- same counts. The skipped tick adds those counts, marks the same
        -- textures used and repeats the texture ownership check.
        local unchanged=adapter.unchanged and adapter:unchanged()
        if unchanged and not pressure and not pressured and not pending and not retry
            and not (self.verify and gate_missed())then
            self.gated_ticks=self.gated_ticks+1
            self.hits=self.hits+self.last_hits;self.misses=self.misses+self.last_misses
            self.early_hits=self.early_hits+self.last_early_hits
            count_surface(self.screen,self.last_hits)
            for i=1,touched_count do touched[i].used=self.ticks end
            self.changed_items=0
            if applied then adapter:check_textures()end
            if adapter.drain then adapter:drain()end
            return
        end
        if unchanged==false then self.full_changed=self.full_changed+1
        elseif pressure or pressured then self.full_pressure=self.full_pressure+1
        elseif pending then self.full_pending=self.full_pending+1
        elseif retry then self.full_retry=self.full_retry+1 end
        touched_count,applied,retry,pressured=0,false,false,pressure==true
        full(unchanged~=nil,pressure)
        if self.verify then verify_reference=adapter.digest(adapter:peek())end
    end
    full=function(fresh,pressure) -- lint-ok: R10 ported from v23 unchanged; split into named steps is a follow-up (differential harness ready)
        local s=adapter:snapshot(fresh);self.screen=s.screen or 'none'
        self.widget_count=#s.widgets;self.named_material_widgets=0
        for _,w in ipairs(s.widgets)do if w.named_material then self.named_material_widgets=self.named_material_widgets+1 end end
        if context~=s.context or pressure then
            self:clear(pressure and 'memory_pressure' or 'thumbnail_manager_changed');context=s.context
        end
        if view~=s.view then reset_request();view=s.view end
        if adapter.drain then adapter:drain()end
        if pressure or not s.context or not s.atlas then
            reset_request()
            self.status=pressure and 'image_memory_pressure' or
                (s.context and 'waiting_for_thumbnail_screen' or 'waiting_for_image_world');return
        end
        if not s.capture_id then
            reset_request()
            self.status='waiting_for_thumbnail_screen';return
        end
        self.status='learning_images'
        if pending and (pending.atlas~=s.atlas or pending.layout~=s.layout)then
            pending=nil;self.pending_items=0;self.pending_drops=self.pending_drops+1
        end
        if pending and pending.request_id~=s.capture_id then
            local candidate=pending;pending=nil;self.pending_items=0
            if s.can_freeze then
                s=retain(s,candidate,false)
            else self.late_switches=self.late_switches+1 end
        end
        -- A weapon's pattern or attachment change never alters the thumbnail
        -- request identity, so it is detected from the configured slots the
        -- preview queue reports. Retire the superseded crop immediately: the
        -- widget returns to the native pipeline, which presents the re-render as
        -- soon as that item composes, and the v17 pass captures it afterwards.
        local changed=0
        for _,item in ipairs(s.items)do
            local entry=self.entries[item.key]
            if entry and entry.preview and item.preview and entry.preview~=item.preview then
                self.entries[item.key]=nil;changed=changed+1
                if pending then pending.entries[item.key]=nil end
            end
        end
        self.changed_items=changed
        if changed>0 then self.reappeared=self.reappeared+changed end
        local hits,misses,early,unresolved,initialized=adapter:apply(s,self.entries)
        applied,retry=true,(unresolved or 0)>0 or (initialized or 0)>0
        self.last_early_hits=early or 0;self.early_hits=self.early_hits+self.last_early_hits
        self.hits=self.hits+hits;self.misses=self.misses+misses
        self.last_hits=hits;self.last_misses=misses
        count_surface(s.screen,hits)
        for _,item in ipairs(s.items)do
            local entry=self.entries[item.key];if entry then entry.texture.used=self.ticks end
        end
        local ready,missing,superseded={},0,0
        self.blank_ready_items=0
        for _,item in ipairs(s.items)do
            -- A card that is not complete has been re-queued, so the item's
            -- next completion produces pixels that supersede our crop.
            if not item.ready then rendered[item.key]=true end
            if item.ready and item.pixels_ready==false then self.blank_ready_items=self.blank_ready_items+1 end
            if item.ready and item.pixels_ready~=false then
            ready[#ready+1]=item.key
            if not self.entries[item.key]then missing=missing+1
            elseif rendered[item.key]then missing=missing+1;superseded=superseded+1 end
        end end
        self.ready_items=#ready;self.missing_ready_items=missing;self.rendered_items=superseded
        local capture_id=s.capture_id..table.concat(ready)
        if capture_id~=last_capture then
            last_capture=capture_id
            -- Refresh partial metadata as cards finish, or remove it when
            -- native generation restarts. This never detaches the active work.
            pending=missing>0 and adapter:capture(s) or nil
            self.pending_items=0
            if pending then
                pending.request_id=s.capture_id;pending.all_complete=s.complete
                for _ in pairs(pending.entries)do self.pending_items=self.pending_items+1 end
            end
        end
        local mode=pending and pending.request_id==s.capture_id and handoff_mode(s)
        if mode then
            local kept
            s,kept=retain(s,pending,mode=='idle')
            if kept and mode=='visible' then self.visible_retained=self.visible_retained+1 end
            if kept then
                pending=nil;self.pending_items=0
                -- The idle working replacement has no pixels yet. Bind the
                -- completed original before this callback returns to the UI.
                local new_hits,new_misses,new_early,new_unresolved,new_initialized=adapter:apply(s,self.entries)
                retry=(new_unresolved or 0)>0 or (initialized or 0)+(new_initialized or 0)>0
                self.hits=self.hits+new_hits-hits;self.misses=self.misses+new_misses-misses
                self.early_hits=self.early_hits+(new_early or 0)-(early or 0)
                count_surface(s.screen,new_hits-hits)
                hits,misses,early=new_hits,new_misses,new_early
                self.last_hits=hits;self.last_misses=misses;self.last_early_hits=early or 0
                self.missing_ready_items=0
                self.rendered_items=0
            end
        end
        if self.status~='image_budget_full'then
            self.status=hits>0 and 'showing_retained_images' or (pending and 'completed_cards_ready_to_retain' or 'learning_images')
        end
        -- The textures an unchanged next tick would mark used.
        for _,item in ipairs(s.items)do
            local entry=self.entries[item.key]
            if entry then
                local t,listed=entry.texture,false
                for i=1,touched_count do if touched[i]==t then listed=true;break end end
                if not listed then touched_count=touched_count+1;touched[touched_count]=t end
            end
        end
    end
    return self
end
return M

end)()
local image_signatures=(function()
return {
    {module='game',rva=0x12e16f0,hex='48895c24084889742410574883ec20498bd88bfa488bf1e8e45c0000488bd0e8'},
    {module='game',rva=0x12d6c00,hex='4c8944241848895424104883ec28f30f1081140100000f2e4424387a357533f3'},
    {module='game',rva=0x12dee70,hex='48895c241848896c24204889542410565741574883ec20f30f10410c488bda0f'},
    {module='game',rva=0x12e07e0,hex='40574883ec20f30f104144488bf90f2ec17a237521f701000000080f84770100'},
    {module='exe',rva=0x2ea5a0,hex='48896c2410488974241857415641574883ec40488b054ed27c01458bf9418bf0'},
    {module='exe',rva=0x2ea9b0,hex='48895c2408574883ec20488b1d47ce7c01488bf9488b833803000080b8f81500'},
    {module='exe',rva=0x2ed5c0,hex='4c8bc28bd1488b0d3ca27c01488b8938030000e9a8c0e1ff488bcbc340535753'},
    {module='game',rva=0x12e7510,hex='48895c2408574883ec20410fb6f8488bd94885d2750f488b5c24304883c4205f'},
    {module='game',rva=0x1229090,hex='40534883ec204533c9488bda488b150df0c001418bc9448b82a02c00004585c0'},
}

end)()
local install=(function()
return function(create_api,native,policy,profile,signatures,build,image_native,images,image_signatures,dependencies)
    if rawget(_G,'ArmoryPreviewCache')then return end
    local state={revision=build.revision,status='starting',frames=0,
        policy_steps_skipped=0,policy_steps_full=0,policy_gate_misses=0,idle_frames=0}
    rawset(_G,'ArmoryPreviewCache',state)
    local previous,previous_shutdown=update,shutdown
    if type(previous)~='function'then state.status='disabled: update unavailable';return end
    local directory=os.getenv('LOCALAPPDATA')
    local path=directory and directory..'/ArmoryPreviewCache'
    local function read_file(name,limit)
        local f=path and io.open(path..name,'rb');if not f then return nil end
        local s=f:read((limit or 16384)+1);f:close();return s
    end
    -- Settings are read on the first update, like the learned profile. A read
    -- during resource loading was observed to miss an existing file in-game.
    local options
    local function load_settings()
        if options then return end
        local text=read_file('.ini',1024)
        options=profile.options(text)
        state.settings=text and 'file' or 'defaults'
    end
    local memory_guard=policy.new_memory_guard()
    local api,adapter,cache,image_cache,started,stopped,last_log,last_save,elapsed
    local baseline,baseline_world,last_profile
    -- The shared UI/thumbnail state view (image_native.state) and what the
    -- policy step last read: its snapshot, the state versions then and the
    -- pressure reason its last policy tick ran with.
    local watch,last_s,policy_version,lease_version,policy_pressure
    local guard
    local build_key=build.game_sha256..' '..build.exe_sha256
    elapsed=0
    local function log(force)
        if not force and rawget(_G,'CowboyBingusDiagnostics')~=true then return end
        local now=api and api.time() or 0
        if not force and last_log and now-last_log<2 then return end
        last_log=now
        pcall(function() -- lint-ok: R10 ported from v23 unchanged; split into named steps is a follow-up (differential harness ready)
            local logger=rawget(_G,'CowboyBingusModLoader')
            local f=logger and logger.open_log and logger.open_log('ArmoryPreviewCache.log');if not f then return end
            f:write(build.revision..'\nstatus='..state.status..'\n')
            if api and api.process_id then
                f:write('process_id='..api.process_id..'\nprocess_created_filetime_hex='..api.process_created_filetime_hex..'\n')
            end
            f:write('asset_residency_cache=1\nrendered_image_cache='..(image_cache and image_cache.enabled and '1' or '0')..'\nmax_packages=128\n')
            if image_cache then
                f:write('image_status='..image_cache.status..'\nimage_screen='..(image_cache.screen or 'none')..'\n')
                for _,key in ipairs({'bytes','hits','misses','last_hits','last_misses','early_hits','last_early_hits','retained','released','late_switches','pending_drops','ready_items','missing_ready_items','blank_ready_items','rendered_items','refreshed','changed_items','reappeared','pending_items','partial_retained','idle_retained','visible_retained','evicted','grid_hits','preselect_hits','briefing_hits','clear_count','widget_count','named_material_widgets',
                    'ticks','gated_ticks','full_changed','full_pending','full_pressure','full_retry','gate_misses',
                    'gate_misses_screen','gate_misses_items','gate_misses_widgets','gate_misses_presentation',
                    'gate_misses_registry','gate_misses_cards'})do
                    f:write('image_'..key..'='..tostring(image_cache[key] or 0)..'\n')
                end
                local a=image_cache.adapter or {}
                for _,key in ipairs({'prune_checks','prune_changes','prune_reconciles','prune_misses'})do
                    f:write('image_'..key..'='..tostring(a[key] or 0)..'\n')
                end
                f:write('image_atlases='..#image_cache.textures..'\n')
                f:write('image_last_clear_reason='..(image_cache.last_clear_reason or '')..'\n')
            end
            f:write('disk_enabled=false\ndisk_status=removed_after_v7_crash\n')
            f:write('settings='..(state.settings or 'pending')..'\n')
            f:write('prewarm='..(options and tostring(options.prewarm) or 'pending')..'\n')
            f:write('verify_gate='..(options and tostring(options.verify_gate) or 'pending')..'\n')
            if watch then f:write('state_refreshes='..watch.refreshes..'\n')end
            for _,key in ipairs({'frames','idle_frames','disabled_reason','disabled_frame','last_top','last_items','last_active','last_blocked','free_mib','commit_headroom_mib','private_growth_mib','pressure_reason','profile_error','disk_error','last_error',
                'policy_steps_skipped','policy_steps_full','policy_gate_misses','last_guard'})do
                local value=state[key];if value==nil then value=''end
                f:write(key..'='..tostring(value)..'\n')
            end
            f:write('memory_guard_trips='..memory_guard.trips..'\n')
            for _,key in ipairs({'last_reason','trigger_free_mib','trigger_commit_mib'})do
                f:write('memory_guard_'..key..'='..tostring(memory_guard[key] or '')..'\n')
            end
            if cache then
                local count=0;for _ in pairs(cache.leases)do count=count+1 end
                f:write('resident_packages='..count..'\nlearned_items='..#cache.learn_order..'\n')
                for _,key in ipairs({'acquires','releases','hits','unresolved','retired','prewarms','dependency_acquires','startup_acquires','foreground_pending'})do f:write(key..'='..tostring(cache[key] or 0)..'\n')end
            end
            f:close()
        end)
    end
    local function save(force)
        if not cache or not path then return end
        local now=api.time();if not force and last_save and now-last_save<5 then return end
        last_save=now
        -- Only remember() changes the learned list: without it the encoding
        -- equals the saved text, so the throttled save skips encoding it.
        if not force and cache.profile_changed==false then return end
        local text=profile.encode(cache:profile(),build_key)
        if text==last_profile then cache.profile_changed=false;return end
        local ok,why=pcall(function()
            local f=assert(io.open(path..'.profile.tmp','wb'));assert(f:write(text));f:close()
            -- Windows rename does not replace an existing destination. Keep a
            -- recoverable backup during replacement; decode rejects truncation.
            os.remove(path..'.profile.bak')
            os.rename(path..'.profile',path..'.profile.bak')
            assert(os.rename(path..'.profile.tmp',path..'.profile'))
            os.remove(path..'.profile.bak')
        end)
        if ok then last_profile=text;cache.profile_changed=false else state.profile_error=tostring(why)end
    end
    local function cleanup()
        if image_cache then
            local ok,why=pcall(image_cache.clear,image_cache)
            if not ok then state.last_error='image cleanup: '..tostring(why)end
        end
        if cache then
            pcall(save,true)
            local ok,why=pcall(cache.clear,cache)
            if not ok then state.last_error='cleanup: '..tostring(why)end
        end
    end
    local function initialize()
        if started then return end
        started=true
        local loader=rawget(_G,'CowboyBingusModLoader')
        assert(loader and loader.api==1,'Bingus Shared Loader API 1 required')
        api=create_api();api.assert_thread()
        local game,exe=assert(api.module('game.dll')),assert(api.module(nil))
        -- The shared runtime's memory api hashes each module once per session
        -- for every mod (build.memory, set by scripts/module.py).
        if build.memory then assert(build.memory.verify_build(build),'Unsupported game build')
        else assert(api.module_hash(game)==build.game_sha256 and api.module_hash(exe)==build.exe_sha256,'Unsupported game build')end
        adapter=native.new(api,game,exe,signatures,dependencies)
        cache=policy.new(adapter,options)
        watch=image_native and image_native.state and image_native.state(api,game)
        if images and options.images then
            local image_adapter=image_native.new(api,game,exe,image_signatures,nil,watch)
            image_cache=images.new(image_adapter,options)
        end
        local learned,valid=profile.decode(read_file('.profile',65536),build_key)
        if not valid then learned=profile.decode(read_file('.profile.bak',65536),build_key)end
        for _,item in ipairs(learned)do cache:remember(item)end
    end
    -- The fields the policy tick reads from a native snapshot, for verify_gate.
    local function policy_digest(s)
        local out={tostring(s.owner),tostring(s.world),tostring(s.menu),tostring(s.prefetch),
            tostring(s.blocked),tostring(s.top),tostring(s.active),table.concat(s.states or {},',')}
        for _,item in ipairs(s.items)do
            out[#out+1]=item.kind..':'..item.id..':'..tostring(item.finished)..':'..table.concat(item.attachments or {},',')
        end
        return table.concat(out,'|')
    end
    -- Whether this step can reuse the last native snapshot: everything that
    -- snapshot read is in the state view and unchanged since. The view reads
    -- the manager, controller rows and preview queue only on a thumbnail
    -- screen with a UI world; with an empty state stack or no world the
    -- native snapshot still reads the manager, so those steps read afresh.
    -- The weapon/kit catalogues and attachment tables it verifies are static
    -- game data; every fresh step verifies them as before.
    local function reusable(refreshes)
        if not watch or not last_s then return false end
        if watch.refreshes==refreshes then watch:refresh()end
        watch:refresh_lease()
        if not (watch.g_ok and watch.stack_ok and watch.ui_ok) or watch.depth==0
            or (watch.kind and not watch.world)then return false end
        return watch.policy_version==policy_version and watch.lease_version==lease_version
    end
    -- Memory telemetry (GlobalMemoryStatusEx and K32GetProcessMemoryInfo,
    -- unmeasured in game) feeds the memory guard. Its pressure reason changes
    -- what a step does only in a menu, in the startup prewarm window, while
    -- leases or rendered images are held, or while the guard is tripped or
    -- recovering: then memory is polled every step, as before. Otherwise (in a
    -- mission, on the ship outside a menu) a poll would only refresh the log's
    -- figures, so it runs every MEMORY_IDLE_POLL seconds. Entering a menu polls
    -- on that step: the snapshot is read first.
    local MEMORY_IDLE_POLL=2
    local memory_wait=0
    local function memory_matters(s)
        return s.menu or s.prefetch or memory_guard.active or next(cache.leases)~=nil
            or (image_cache~=nil and #image_cache.textures>0)
    end
    local function poll_memory(s,seconds)
        memory_wait=memory_wait-seconds
        if memory_wait>0 and not memory_matters(s)then return end
        memory_wait=MEMORY_IDLE_POLL
        local free,private,commit=api.memory()
        if not s.menu or baseline_world~=s.world then baseline=private;baseline_world=s.world end
        baseline=baseline or private
        local growth=math.max(0,private-baseline)
        state.free_mib=math.floor(free/1048576);state.private_growth_mib=math.floor(growth/1048576)
        state.commit_headroom_mib=math.floor(commit/1048576)
        state.pressure_reason=memory_guard:tick(api.time,free,commit)
    end
    -- The idle gate. A frame is idle when neither the image tick nor the
    -- asset step could do anything but repeat itself: no Armory or briefing
    -- on the state stack, no lease held, the startup prewarm window closed (or
    -- the stack not empty, which it needs), no memory pressure or guard, no
    -- profile save pending, the image cache quiet (images.quiet) and the
    -- thumbnail manager the last full frame saw. An idle frame makes 2 reads
    -- (image_native.state probe) and nothing else: no thread check, clock,
    -- memory poll or allocation. With rendered images held, memory is still
    -- polled every MEMORY_IDLE_POLL seconds (a full frame), so pressure keeps
    -- releasing them. The same 2 reads serve the ship and missions.
    local gate_tm,startup_closed=nil,false
    local function quiet()
        if not watch or not last_s or options.verify_gate then return false end
        if next(cache.leases)~=nil or memory_guard.active or state.pressure_reason~=nil then return false end
        if path and cache.profile_changed==true and not state.profile_error then return false end
        return image_cache==nil or image_cache:quiet()
    end
    local function idle(seconds)
        if not quiet()then return false end
        if image_cache~=nil and #image_cache.textures>0 and memory_wait<=0 then return false end
        -- The log's last_* fields keep the last working frame's values.
        local tm,depth,top=watch:probe()
        if not tm or tm~=gate_tm or top==5 or top==14 or (depth==0 and not startup_closed)then return false end
        state.idle_frames=state.idle_frames+1
        -- The 50 ms step clock runs on as if each step had found nothing to
        -- do, so the first working frame steps exactly when it would have.
        elapsed=elapsed+seconds
        if elapsed>=.05 then memory_wait=memory_wait-elapsed;elapsed=0 end
        return true
    end
    -- The gate runs interpreted (about 300 bytecodes): a trace through it
    -- would follow the returns into every update wrapper below this mod in
    -- the hook chain and fill the game's shared code cache.
    local loaded=rawget(_G,'package') and package.loaded
    local jit_module=rawget(_G,'jit') or (loaded and loaded.jit)
    if jit_module and jit_module.off then
        jit_module.off(quiet);jit_module.off(idle)
    end
    -- After a full policy tick at now: the startup window never reopens once
    -- a menu was seen or 60 s passed since the first tick (policy.lua).
    local function note_startup(now)
        if startup_closed then return end
        startup_closed=not cache.prewarm or cache.seen_menu==true
            or (cache.started~=nil and now-cache.started>=60)
    end
    -- step checks the update thread before the pre-update image refresh when
    -- bindings exist; the frame after the update checks it when step did not
    -- (same callback, same thread) and the frame is not idle: one
    -- GetCurrentThreadId per working frame, none on an idle one (it only reads).
    local thread_checked=false
    local function frame(dt) -- lint-ok: R10 ported from v23 unchanged; split into named steps is a follow-up (differential harness ready)
        state.frames=state.frames+1
        if not stopped then load_settings()end
        if stopped or not options.enabled then state.status=stopped and state.status or 'disabled_by_config';log(false);return end
        if not started then
            local ok,why=pcall(initialize)
            if not ok then guard.stop('disabled: '..tostring(why));return end
        end
        local frame_seconds=type(dt)=='number' and math.max(0,math.min(dt,.25)) or 0
        if idle(frame_seconds)then log(false);return end
        if not thread_checked then api.assert_thread()end
        local refreshes=watch and watch.refreshes
        -- Presentation runs every callback, independent of the slower asset
        -- residency budget. A 50 ms image poll would itself add visible delay.
        if image_cache then image_cache:tick(state.pressure_reason~=nil)end
        if watch then gate_tm=watch.tm or 0 end
        elapsed=elapsed+frame_seconds
        if elapsed<.05 then return end
        local seconds=elapsed
        elapsed=0
        -- Memory telemetry and the guard run as poll_memory says. The native snapshot
        -- and the policy tick run unless the snapshot is reusable, the last
        -- policy tick was settled and the pressure reason is unchanged: that
        -- tick would only add the same hit counts, which replay() adds.
        local s,reuse=last_s,reusable(refreshes)
        if reuse and options.verify_gate then
            local ok,now=pcall(adapter.snapshot,adapter)
            if not ok or policy_digest(now)~=policy_digest(last_s)then
                state.policy_gate_misses=state.policy_gate_misses+1;reuse=false
            end
        end
        if not reuse then
            local ok
            ok,s=pcall(adapter.snapshot,adapter)
            if not ok then
                -- Loading screens can temporarily remove managers. Retain no new
                -- leases; cleanup only through revalidated ownership.
                last_s=nil
                cleanup();state.status='waiting_for_ui';state.last_error=tostring(s);log(false);return
            end
            last_s=s
            if watch then policy_version,lease_version=watch.policy_version,watch.lease_version end
        end
        poll_memory(s,seconds)
        state.last_top=s.top;state.last_items=#s.items;state.last_active=s.active
        state.last_blocked=s.blocked
        if reuse and cache.settled and state.pressure_reason==policy_pressure then
            cache:replay();state.policy_steps_skipped=state.policy_steps_skipped+1
        else
            local now=api.time()
            cache:tick(s,now,state.pressure_reason~=nil)
            note_startup(now)
            policy_pressure=state.pressure_reason;state.policy_steps_full=state.policy_steps_full+1
        end
        state.status=cache.status
        -- Persist learned entries after menu interaction, or during shutdown.
        if not s.menu and not s.active then save(false) end
        log(false)
    end
    -- The update chain is the shared runtime's guard (BingusSharedRuntime):
    -- the previous update runs outside pcall; an update below that raises
    -- pauses the mod (cleanup hands every widget back to the native pipeline
    -- and releases the leases) until 60 clean frames, then it resumes; 8 own
    -- errors or 8 failures below in a burst stop it; the first failure
    -- survives shutdown.
    local last_dt
    local function step(dt)
        last_dt=dt
        -- The last frame's probe is not this frame's state.
        if watch and watch.unprobe then watch:unprobe()end
        thread_checked=image_cache~=nil and not stopped and image_cache:bound()
        if thread_checked then api.assert_thread();image_cache:before()end
    end
    local function after()frame(last_dt)end
    local function pause(reason)
        cleanup();last_s=nil;state.status='paused: '..reason;log(true)
    end
    local function stop(reason)
        stopped=true;cleanup()
        if reason=='shutdown' then
            local failure=guard.status.first_failure
            state.status=failure and 'stopped after: '..failure or 'stopped'
        else
            state.status=reason;state.disabled_reason=reason;state.disabled_frame=state.frames
        end
        log(true)
    end
    guard=build.runtime.guard({name='ArmoryPreviewCache',step=step,after=after,pause=pause,stop=stop,
        log=function(line)state.last_guard=line end,env=_G}).install()
    -- A guard stopped earlier runs no stop work at shutdown: report it here.
    local guarded_shutdown=shutdown
    shutdown=function(...)
        if not guard.running()then
            local failure=guard.status.first_failure
            state.status=failure and 'stopped after: '..failure or 'stopped';log(true)
        end
        return guarded_shutdown(...)
    end
    log(true)
end

end)()
install(function()return platform(base)end,native,policy,profile,signatures,{revision='v23.1',game_sha256='6D1D4D3BC6FC84801D9F8F1B310E13A603D07409F3D9495D74B42E1D0BB1C08F',exe_sha256='0ACC07DEBE04714AE04281E1A66BD2EB9D3D85232953E32A93C8A3DD0874EABE',runtime=runtime,memory=runtime_memory.new(runtime)},image_native,images,image_signatures,dependencies)
