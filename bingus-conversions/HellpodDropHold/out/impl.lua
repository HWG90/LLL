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
local runtime_write = (function()
-- bingus_write.lua, version 1: the write side of Bingus Shared Runtime.
-- Canonical copy: github.com/CowboyBingus/BingusSharedRuntime, runtime/bingus_write.lua.
--
-- Loading: the chunk returns {VERSION = 1, extend = function(api)} and installs
-- nothing. A mod that writes vendors byte-identical copies of all three files
-- and runs each once when it loads:
--   local runtime = <bingus_runtime.lua>
--   local memory = <bingus_memory.lua>.new(runtime)
--   <bingus_write.lua>.extend(memory)   -- adds write and write_batch; returns memory
--
-- extend(api) takes an api from bingus_memory.lua (version 1) and adds:
--   api.write(address, bytes [, size])   bytes: a string, or a buffer with size.
--                                        true when every byte landed
--   api.write_batch(base, size, changes) several writes inside [base, base + size)
--                                        under one check: changes = {{offset, bytes},
--                                        ...}. true and the count, or false and how
--                                        many writes landed, so the caller can undo them
--   api.windows.kernel32.WriteProcessMemory, bound like the read-side functions
-- write takes a pointer cdata; write_batch a pointer or a number.
--
-- Writes go only into memory that is already committed, private and read-write:
-- never code, read-only, guard or module image pages. Each write checks its whole
-- range with api.writable_data right before writing (one VirtualQuery per memory
-- region, about 0.29 ms each in game; api.queries counts them), so write only on
-- frames that act. Nothing here changes page protection or allocates memory
-- pages. WriteProcessMemory is declared under a private, versioned name
-- (bingus_write1_*, an __asm__ label naming the real export), at most once per
-- version in the whole game; the marker type bingus_write1_declared is this
-- file's sentinel.
local write = {VERSION = 1}

local type, error, pcall = type, error, pcall

local SENTINEL = 'bingus_write1_declared'
local DECLARATIONS = [[
    typedef struct bingus_write1_declared bingus_write1_declared;
    int bingus_write1_WriteProcessMemory(void *process, void *address, const void *buffer, size_t size,
                                         size_t *done) __asm__("WriteProcessMemory");
]]

local bound
-- The bound function, declared at most once per version in the whole game.
local function bind(ffi)
    if bound then return bound end
    if not pcall(ffi.typeof, SENTINEL) then ffi.cdef(DECLARATIONS) end
    bound = ffi.load('kernel32').bingus_write1_WriteProcessMemory
    return bound
end

function write.extend(api)
    if type(api) ~= 'table' or type(api.writable_data) ~= 'function' or type(api.windows) ~= 'table' then
        error('bingus_write.lua: extend(api) needs an api from bingus_memory.lua', 2)
    end
    local windows = api.windows
    local ffi, kernel = windows.ffi, windows.kernel32
    local write_memory = bind(ffi)
    kernel.WriteProcessMemory = write_memory
    local process = kernel.GetCurrentProcess()
    -- The 64-bit count is read back as two 32-bit words: reading the 64-bit value
    -- boxes a new cdata in interpreted code. Only the call writes this buffer.
    local done = ffi.new('size_t[1]')
    local done32 = ffi.cast('uint32_t *', done)

    -- bytes: a string, or a buffer with size. Checked right before the write.
    function api.write(address, bytes, size)
        size = size or #bytes
        if not api.writable_data(address, size) then return false end
        return write_memory(process, address, bytes, size, done) ~= 0 and done32[0] == size
    end

    -- Stops at the first failure and returns false and how many writes landed.
    function api.write_batch(base, size, changes)
        if not api.writable_data(base, size) then return false, 0 end
        local start = ffi.cast('uint8_t *', base)
        for index = 1, #changes do
            local offset, bytes = changes[index][1], changes[index][2]
            if offset < 0 or offset + #bytes > size
                or write_memory(process, start + offset, bytes, #bytes, done) == 0
                or done32[0] ~= #bytes then
                return false, index - 1
            end
        end
        return true, #changes
    end

    return api
end

return write

end)()
local create_api = (function()
-- The memory API the hold and the loader use, on top of Bingus Shared Runtime v1:
-- runtime is the core (src/bingus_runtime.lua) and memory the api of
-- src/bingus_memory.lua extended by src/bingus_write.lua, byte-identical copies
-- that the build embeds and passes in. The runtime declares its Windows
-- functions under private, versioned FFI names, checks pages and hashes each
-- game module once per session for every mod.
--
-- This adapter adds reads at plain-number addresses into a buffer the caller
-- keeps, also given by its number address: read_to(address, size, destination).
-- The runtime's read_into takes pointer cdata, which a number address would have
-- to be cast to on every read (16 bytes of garbage each). The hold follows game
-- pointers it reads as numbers, so it reads only through read_to and allocates
-- nothing per read. Writes go through the runtime's checked write_batch, which
-- takes a number base and queries the page right before the write.
return function(runtime, memory)
    assert(type(runtime) == 'table' and type(memory) == 'table' and type(memory.write_batch) == 'function',
        'bingus_memory.lua and bingus_write.lua v1 are required')
    local native = memory.windows
    local ffi, kernel = native.ffi, native.kernel32
    -- A private name, declared once per process: ffi.cdef keeps the first
    -- declaration of a name for the whole game. The cast below uses this named
    -- type, because a function-pointer type written out in a string adds C types
    -- to the table every mod shares each time it is used.
    if not pcall(ffi.typeof, 'hellpod_drop_hold1_read_memory') then
        ffi.cdef [[
            typedef int (*hellpod_drop_hold1_read_memory)(void *process, uint64_t address, uint64_t buffer,
                                                          size_t size, uint32_t *read);
        ]]
    end
    -- The runtime's bound ReadProcessMemory, taking the address and the
    -- destination as uint64_t (the same register as a pointer on x64) and the
    -- byte count as two 32-bit words: a call creates no cdata.
    local read_memory = ffi.cast('hellpod_drop_hold1_read_memory', kernel.ReadProcessMemory)
    local process = kernel.GetCurrentProcess()
    local count = ffi.new('uint32_t[2]')
    local function read_to(address, size, destination)
        return read_memory(process, address, destination, size, count) ~= 0 and count[0] == size and count[1] == 0
    end
    return {
        module = memory.module, module_hash = memory.module_hash, verify_build = memory.verify_build,
        address = memory.address, read_to = read_to, writable_data = memory.writable_data,
        write_batch = memory.write_batch,
    }
end

end)()
local hold = (function()
-- Holds the local player's own drop pod while the player cannot see the world, and
-- lets it fall once they can. Mechanics (game.dll RVAs of Steam build 25480438;
-- docs/TECHNICAL.md has the evidence; build 26088801 values: hdh-port/MAP.json):
-- - A loading period starts while the game state ([game+0x3326340] + 0xAC21C) is
--   5 or 6 (preparing the ship or a mission: the loading screen), or while a
--   loading presenter is open in the UI's PresenterManager ([game+0x347CE28] +
--   0x4288: HUD, menu and popup presenter at +8, +12, +16, the menu stack's five
--   ids at +20 and its depth at +40; menu presenter 2 is LoadingMission, 4
--   LoadingTutorial).
-- - It lasts, in a mission, while a join is still finishing (is_hotjoining,
--   [game+0x347CEF0] + 92135) or a cutscene plays ([game+0x346D530] + 6412: the
--   current scene, then the queued one). A joining player's game queues
--   ship_teleporter_network_join (15) on the ship; it clears is_hotjoining and
--   interrupts that cutscene only when its synchronized tasks are done in the
--   mission state, while the host has already spawned that player's drop: the pod
--   falls unseen. In a live join on 2026-10-05 (v1.0) state 6 ended before the pod
--   existed, and the pod had landed before the player could see it.
-- - The HellpodComponent manager is [game+0x3326D58]. Each active pod has an
--   entity record (64-bit type hash, entity id, unit, network id, flags with
--   bit 0 = owned by this machine), a 160-byte local state and a 20-byte
--   networked state (phase: 0 falling, 1 braking, 2 landed; then position).
-- - The machine that owns a pod moves it down by
--   ((1 - t) * braking_velocity + t * initial_velocity) * dt every frame and
--   publishes the result. t is the float at local state +32: 1 at spawn, and it
--   only decays toward 0 while braking, and only while above 0.
-- - A player's own machine creates and owns that player's drop pod, also when
--   joining a mission in progress. Holding is one write of t on that machine:
--   t_hold makes the step 0.5 m/s * dt. Releasing writes the saved t back.
local ffi = require('ffi')

local hold = {
    game_rva = 0x2CE1508, state_offset = 0xAC29C,
    ui_state_rva = 0x2E38160, presenters_offset = 0x4290, stack_offset = 0x429C, max_depth = 5,
    -- The cutscene manager (current scene id, then the queued one) and, for the log,
    -- the session object's client state and hotjoin flags (is_hotjoining, has_hotjoined).
    cutscene_rva = 0x2E28780, scene_offset = 6412,
    session_rva = 0x2E38228, client_state_offset = 91288, hotjoin_offset = 92143,
    manager_rva = 0x2CE1F18, header_offset = 36, header_size = 84, max_capacity = 4096,
    settings_rva = 0x2CE41B8, settings_table_offset = 15812008, settings_slots = 16,
    settings_records = 256, settings_size = 104, settings_count = 64,
    record_size = 24, local_size = 160, net_size = 20, factor_offset = 32,
    -- Seconds: the idle and pod-check poll interval, and the longest hold.
    poll = 0.25, cap = 120,
    -- The held pod still sinks this fast (m/s): a zero step would give the
    -- game's look rotation and landing ray a zero direction.
    hold_speed = 0.5, scan_chunk = 256,
    -- Seconds the event log keeps following the game state and presenters after
    -- a loading screen or a hold ends.
    watch = 30,
}
-- Game states behind a loading screen: 5 preparing the ship, 6 preparing a mission.
local PREPARING = {[5] = true, [6] = true}
-- Menu presenters that are loading screens: LoadingMission and LoadingTutorial.
local LOADING = {[2] = true, [4] = true}
-- Names for the event log (game.dll's presenter name tables 0x21DD450 and 0x21DC810).
local HUD_NAMES = {[0] = 'none', 'intro', 'ship', 'mission', 'tutorial'}
local MENU_NAMES = {[0] = 'none', 'main', 'loading mission', 'loading ship', 'loading tutorial', 'armory',
    [13] = 'mission end', [14] = 'loadout', [15] = 'hologram', [23] = 'mission summary', [24] = 'load', [25] = 'join'}
-- Cutscene names (game.dll 0x117E950).
local SCENE_NAMES = {[0] = 'none', 'mission extraction', 'ship bridge hellpod launch', 'ship bridge intro',
    'ship clan station reveal', 'ship cryogenic intro', 'ship hellpod launch', 'ship intro',
    'ship mission return failure', 'ship mission return success', 'ship name resource loading', 'ship planet arrival',
    'ship planet departure', 'ship teleporter arrival', 'ship teleporter deeplink join', 'ship teleporter network join',
    'tutorial avatar respawn', 'tutorial cape ceremony', 'tutorial intro', 'tutorial outro', 'tutorial outro to ship'}
-- Game states in which a playing cutscene keeps a loading period going: the mission and its preparation.
local SCENE_STATES = {[4] = true, [6] = true}
-- The player drop pod types: entity hash halves and HellpodComponent variant.
local TYPES = {
    {low = 0x1928D3E2, high = 0xE58163E7, variant = 2, name = 'initial spawn'},  -- 0xE58163E71928D3E2
    {low = 0xA9D6D849, high = 0xEF9EB729, variant = 1, name = 'reinforce'},      -- 0xEF9EB729A9D6D849
}
hold.types = TYPES
local HIGH, LOWEST, USER_END = 4294967296, 0x10000, 0x800000000000

-- Every read lands in one of these buffers, made once and addressed by number,
-- and is decoded in place: a check allocates nothing.
local function buffer(ctype, count)
    local data = ffi.new(ctype, count)
    return data, tonumber(ffi.cast('uintptr_t', data))
end
local words, words_at = buffer('uint32_t[?]', 21)       -- a pointer (0-1) or the 84-byte manager header
local state, state_at = buffer('uint32_t[?]', 1)        -- the game state
local signals, signals_at = buffer('uint32_t[?]', 9)    -- HUD, menu, popup presenter, five stack ids, depth
local scenes, scenes_at = buffer('uint32_t[?]', 2)      -- current and queued cutscene
local client, client_at = buffer('uint32_t[?]', 1)      -- the client state, for the log
local joining, joining_at = buffer('uint8_t[?]', 2)     -- is_hotjoining, has_hotjoined, for the log
local record, record_at = buffer('uint32_t[?]', 6)      -- hash low, high, id, unit, network id, flags
local phase, phase_at = buffer('uint32_t[?]', 1)
local factor, factor_at = buffer('float[?]', 1)
local height, height_at = buffer('float[?]', 1)
local variant, variant_at = buffer('uint32_t[?]', 1)
local speeds, speeds_at = buffer('float[?]', 4)         -- initial velocity, braking height, braking velocity, time
local slots, slots_at = buffer('uint32_t[?]', 64)       -- 16 settings slots: hash low, high, index, padding
local pointers, pointers_at = buffer('uint32_t[?]', 512) -- up to 256 entity record pointers
local cell = ffi.new('float[1]')

local function valid_pointer(value)
    if value < LOWEST or value >= USER_END then return nil end
    return value
end
local function is_power_of_two(value)
    while value > 1 and value % 2 == 0 do value = value / 2 end
    return value == 1
end
-- The user-mode pointer stored at address, as a number, or nil.
local function pointer_at(api, address)
    if not api.read_to(address, 8, words_at) then return nil end
    return valid_pointer(words[0] + words[1] * HIGH)
end
-- A float as the game stores it: its 4 bytes and the rounded value.
local function float_bytes(value)
    cell[0] = value
    return ffi.string(cell, 4), cell[0]
end

-- Reads the game state and the presenters into state and signals: true while the
-- player cannot see the world (a preparing state, or a loading presenter open or
-- anywhere on the menu stack), false when they can, nil when either cannot be read
-- or makes no sense.
local function loading_screen(api, game)
    local object = pointer_at(api, game + hold.game_rva)
    if not object or not api.read_to(object + hold.state_offset, 4, state_at) then return nil end
    local ui = pointer_at(api, game + hold.ui_state_rva)
    if not ui or not api.read_to(ui + hold.presenters_offset, 36, signals_at) then return nil end
    local depth = signals[8]
    if depth > hold.max_depth then return nil end
    if PREPARING[state[0]] or LOADING[signals[1]] then return true end
    for index = 0, depth - 1 do
        if LOADING[signals[3 + index]] then return true end
    end
    return false
end

-- Reads the join flags and the cutscene manager (after loading_screen, which read the
-- state): true while, in the mission or its preparation, a join is still finishing
-- (is_hotjoining) or a cutscene plays or waits; false when not; nil when neither can be
-- read. Both end in the client's synchronized-tasks-done (0xAD4520), which clears
-- is_hotjoining and interrupts the cutscene. Unreadable values show as 255 or 9999 in
-- the log and never count.
local function still_covered(api, game)
    local session_object = pointer_at(api, game + hold.session_rva)
    local flags_read = session_object and api.read_to(session_object + hold.client_state_offset, 4, client_at)
        and api.read_to(session_object + hold.hotjoin_offset, 2, joining_at)
    if not flags_read then client[0], joining[0], joining[1] = 255, 255, 255 end
    local manager = pointer_at(api, game + hold.cutscene_rva)
    local scenes_read = manager and api.read_to(manager + hold.scene_offset, 8, scenes_at)
    if not scenes_read then scenes[0], scenes[1] = 9999, 9999 end
    if not (flags_read or scenes_read) then return nil end
    local scene = scenes_read and (scenes[0] ~= 0 or scenes[1] ~= 0)
    local joining_now = flags_read and joining[0] == 1
    return SCENE_STATES[state[0]] == true and (scene or joining_now) or false
end

-- The state and presenters just read (and the cutscene and join flags when read), in
-- words, for the event log.
local function describe_signals(extended)
    local ids = {}
    for index = 0, math.min(signals[8], hold.max_depth) - 1 do
        local id = signals[3 + index]
        ids[#ids + 1] = MENU_NAMES[id] or tostring(id)
    end
    local text = string.format('game state %d, hud %s, menu %s, popup %d, menu stack [%s]', state[0],
        HUD_NAMES[signals[0]] or tostring(signals[0]), MENU_NAMES[signals[1]] or tostring(signals[1]), signals[2],
        table.concat(ids, ', '))
    if not extended then return text end
    return text .. string.format(', cutscene %s (next %s), client state %d, hotjoining %d, hotjoined %d',
        SCENE_NAMES[scenes[0]] or tostring(scenes[0]), SCENE_NAMES[scenes[1]] or tostring(scenes[1]), client[0],
        joining[0], joining[1])
end

-- Whether the state, a presenter (or, when read, the cutscene or a join flag) changed
-- since the last call; keeps the last values in session.seen (numbers, so a
-- comparison allocates nothing).
local function signals_changed(session, extended)
    local seen = session.seen
    local changed = seen[0] ~= state[0]
    seen[0] = state[0]
    for index = 0, 8 do
        if seen[index + 1] ~= signals[index] then
            changed, seen[index + 1] = true, signals[index]
        end
    end
    if not extended then return changed end
    local values = seen.extended
    if values[1] ~= scenes[0] or values[2] ~= scenes[1] or values[3] ~= client[0] or values[4] ~= joining[0]
        or values[5] ~= joining[1] then
        changed = true
        values[1], values[2], values[3], values[4], values[5] = scenes[0], scenes[1], client[0], joining[0], joining[1]
    end
    return changed
end

-- The manager's active count and array addresses, in one reused table; nil and
-- 'no_manager' before the manager exists, nil and 'manager_layout' when its
-- header makes no sense.
local view = {}
local function read_manager(api, game)
    local manager = pointer_at(api, game + hold.manager_rva)
    if not manager then return nil, 'no_manager' end
    if not api.read_to(manager + hold.header_offset, hold.header_size, words_at) then return nil, 'manager_layout' end
    -- words[i] holds manager + 36 + 4 * i.
    local capacity, total, active = words[0], words[2], words[3]
    if capacity > hold.max_capacity or total > capacity or active > total then return nil, 'manager_layout' end
    view.manager, view.active = manager, active
    view.records = valid_pointer(words[13] + words[14] * HIGH)
    view.locals = valid_pointer(words[17] + words[18] * HIGH)
    view.nets = valid_pointer(words[19] + words[20] * HIGH)
    -- The entity-id map (+64 slots, +72 capacity, a power of two, +76 empty key, +80 multiplier).
    view.map, view.map_capacity = valid_pointer(words[7] + words[8] * HIGH), words[9]
    view.map_empty, view.map_multiplier = words[10], words[11]
    if active > 0 and not (view.records and view.locals and view.nets and view.map and view.map_capacity > 0
        and view.map_capacity <= 65536 and view.map_capacity % 1 == 0 and is_power_of_two(view.map_capacity)) then
        return nil, 'manager_layout'
    end
    return view
end

-- (a * b) mod 2^32 for 32-bit a and b, exact in doubles: a is split into 16-bit halves.
local function mul32(a, b)
    local a_low, a_high = a % 65536, math.floor(a / 65536)
    return (a_low * b + (a_high * (b % 65536)) % 65536 * 65536) % HIGH
end

-- The index the manager's own entity-id map gives for id, or nil. The game probes
-- slot (probe + id * multiplier) & (capacity - 1) until the key or the empty key.
local map_slot, map_slot_at = buffer('uint32_t[?]', 2)
local function map_index(api, v, id)
    local start = mul32(id, v.map_multiplier)
    for probe = 0, math.min(v.map_capacity, 64) - 1 do
        local slot = (start + probe) % v.map_capacity
        if not api.read_to(v.map + slot * 8, 8, map_slot_at) then return nil end
        if map_slot[0] == v.map_empty then return nil end
        if map_slot[0] == id then return map_slot[1] end
    end
    return nil
end

-- Reads the entity record at address into record; the pod type when it is a
-- player drop pod this machine owns, else nil.
local function own_drop_pod(api, address)
    if not address or not api.read_to(address, hold.record_size, record_at) then return nil end
    if record[5] % 2 ~= 1 then return nil end
    for _, kind in ipairs(TYPES) do
        if record[0] == kind.low and record[1] == kind.high then return kind end
    end
    return nil
end

local function phase_of(api, v, index)
    if not api.read_to(v.nets + index * hold.net_size, 4, phase_at) then return nil end
    return phase[0]
end

-- One reused result: the pod's index, entity id, record address and type.
local found = {}
local function candidate(api, v, index, address, skip)
    local kind = own_drop_pod(api, address)
    if not kind or skip[record[2]] then return nil end
    local id = record[2]
    local current = phase_of(api, v, index)
    if current ~= 0 and current ~= 1 then return nil end
    -- The manager's own map must agree: this entity id lives at this index.
    if map_index(api, v, id) ~= index then return nil end
    found.index, found.id, found.record, found.kind = index, id, address, kind
    return found
end

-- The first of this machine's own drop pods that is still falling or braking and
-- not in skip (entity ids handled already), or nil. Reads the record pointers in
-- chunks of up to 256.
local function find_pod(api, v, skip)
    local first = 0
    while first < v.active do
        local count = math.min(v.active - first, hold.scan_chunk)
        if not api.read_to(v.records + first * 8, count * 8, pointers_at) then return nil end
        for slot = 0, count - 1 do
            local address = valid_pointer(pointers[slot * 2] + pointers[slot * 2 + 1] * HIGH)
            local pod = candidate(api, v, first + slot, address, skip)
            if pod then return pod end
        end
        first = first + count
    end
    return nil
end

-- The pod at held.index still has the same record, entity id, type and owner.
-- The manager compacts its arrays when a pod goes, so an index can change.
local function same_pod(api, v, held, index)
    if index >= v.active or not api.read_to(v.records + index * 8, 8, words_at) then return false end
    if words[0] + words[1] * HIGH ~= held.record then return false end
    return own_drop_pod(api, held.record) == held.kind and record[2] == held.id and map_index(api, v, held.id) == index
end

-- The held pod's current index; nil and 'gone' when the manager no longer has
-- it; nil and 'unknown' when the manager could not be read, so the hold must be
-- kept and checked again.
local function locate(api, v, held)
    if same_pod(api, v, held, held.index) then return held.index end
    local first = 0
    while first < v.active do
        local count = math.min(v.active - first, hold.scan_chunk)
        if not api.read_to(v.records + first * 8, count * 8, pointers_at) then return nil, 'unknown' end
        for slot = 0, count - 1 do
            if pointers[slot * 2] + pointers[slot * 2 + 1] * HIGH == held.record
                and same_pod(api, v, held, first + slot) then
                return first + slot
            end
        end
        first = first + count
    end
    return nil, 'gone'
end

-- The manager view and the held pod's index, as locate; 'unknown' when the
-- manager cannot be read.
local function find_held(api, game, held)
    local v, problem = read_manager(api, game)
    if not v then return nil, nil, problem == 'no_manager' and 'gone' or 'unknown' end
    local index, why = locate(api, v, held)
    return v, index, why
end

local function settings_record(api, table_address, index, kind)
    if index >= hold.settings_count then return nil end
    local address = table_address + hold.settings_records + index * hold.settings_size
    if not api.read_to(address, 4, variant_at) or not api.read_to(address + 20, 16, speeds_at) then return nil end
    local initial, braking, target_time = speeds[0], speeds[2], speeds[3]
    if variant[0] ~= kind.variant or not (target_time > 0) then return nil end
    if not (braking > hold.hold_speed and initial > braking and initial <= 5000) then return nil end
    return initial, braking
end

-- The pod type's initial and braking velocity from its HellpodComponent settings
-- (16 open-addressed slots from the hash's low 4 bits, then 104-byte records at
-- +256); nil when the table or the record make no sense.
local function velocities(api, game, kind)
    local owner = pointer_at(api, game + hold.settings_rva)
    local table_address = owner and pointer_at(api, owner + hold.settings_table_offset)
    if not table_address or not api.read_to(table_address, hold.settings_slots * 16, slots_at) then return nil end
    local slot = kind.low % hold.settings_slots
    for _ = 1, hold.settings_slots do
        local low, high = slots[slot * 4], slots[slot * 4 + 1]
        if low == kind.low and high == kind.high then
            return settings_record(api, table_address, slots[slot * 4 + 2], kind)
        end
        if low == 0 and high == 0 then return nil end
        slot = (slot + 1) % hold.settings_slots
    end
    return nil
end

-- The pod's height (networked position z) for the event log, or -1.
local function height_of(api, v, index)
    if not api.read_to(v.nets + index * hold.net_size + 12, 4, height_at) then return -1 end
    return height[0]
end

local function factor_address(v, index)
    return v.locals + index * hold.local_size + hold.factor_offset
end

-- Writes value's 4 bytes at address and reads them back: one page check, right
-- before the store.
local function store(api, address, bytes, value)
    if not api.write_batch(address, 4, {{0, bytes}}) then return false end
    return api.read_to(address, 4, factor_at) and factor[0] == value
end

local function note(session, text)
    if session.note then session.note(text) end
end

-- Holds the found pod: true, or false and why the mod must stop, or nil and why
-- this pod is left alone.
local function start_hold(api, game, session, v, pod)
    local initial, braking = velocities(api, game, pod.kind)
    if not initial then return false, 'drop_pod_settings_unrecognized' end
    local address = factor_address(v, pod.index)
    if not api.read_to(address, 4, factor_at) then return false, 'drop_pod_unreadable' end
    local saved = factor[0]
    -- Anything outside the game's own 0..1 was written by someone else.
    if not (saved >= 0 and saved <= 1) then
        session.done[pod.id] = true
        return nil, 'drop_pod_speed_set_elsewhere'
    end
    local bytes, value = float_bytes((hold.hold_speed - braking) / (initial - braking))
    local held = {id = pod.id, record = pod.record, kind = pod.kind, index = pod.index, saved = saved,
                  value = value, held_for = 0}
    if not same_pod(api, v, held, pod.index) then return nil, 'drop_pod_moved' end
    if not store(api, address, bytes, value) then return false, 'drop_pod_not_writable' end
    session.held = held
    note(session, string.format('holding %s pod %d at %.0f m (speed factor %.3f -> %.3f)', pod.kind.name,
        pod.id, height_of(api, v, pod.index), saved, value))
    return true
end

-- Puts the saved factor back on the held pod, only over this mod's own value.
-- Returns true, or false and why (a failed write). The hold is forgotten unless
-- the manager could not be read: then it is kept and released at a later poll.
local function release(api, game, session, reason)
    local held = session.held
    if not held then return true end
    local v, index, why = find_held(api, game, held)
    if why == 'unknown' then
        held.retry = reason
        return true
    end
    session.held, session.done[held.id] = nil, true
    if not index then
        note(session, 'released pod ' .. held.id .. ' (' .. reason .. '): the pod is gone')
        return true
    end
    local address = factor_address(v, index)
    if not api.read_to(address, 4, factor_at) or factor[0] ~= held.value then
        note(session, 'released pod ' .. held.id .. ' (' .. reason .. '): left unchanged, its speed changed elsewhere')
        return true
    end
    local bytes, value = float_bytes(held.saved)
    if not store(api, address, bytes, value) then return false, 'drop_pod_release_failed' end
    note(session, string.format('released pod %d (%s) after %.1f s at %.0f m', held.id, reason, held.held_for,
        height_of(api, v, index)))
    return true
end
hold.release = release

-- Whether the player cannot see the world. A forced session (test builds only)
-- treats every moment as loading.
-- loading_screen, plus an event when the state or a presenter changed while the log
-- follows them (session.watch seconds after a loading screen or a hold).
-- Notes every own drop pod the first time it is seen during a loading period or the
-- watch after it: when it appeared, against the signals, is the timing evidence.
local function sight_pods(api, v, session)
    local first = 0
    while first < v.active do
        local count = math.min(v.active - first, hold.scan_chunk)
        if not api.read_to(v.records + first * 8, count * 8, pointers_at) then return end
        for slot = 0, count - 1 do
            local kind = own_drop_pod(api, valid_pointer(pointers[slot * 2] + pointers[slot * 2 + 1] * HIGH))
            local id = kind and record[2]
            if id and not session.sighted[id] then
                session.sighted[id] = true
                note(session, string.format('own %s pod %d seen at %.0f m, phase %s', kind.name, id,
                    height_of(api, v, first + slot), tostring(phase_of(api, v, first + slot))))
            end
        end
        first = first + count
    end
end

-- One check of the signals: loading (true while a loading screen is up, false when
-- not, nil when unreadable) and, when extended, scene (true while a cutscene plays in
-- the mission or its preparation). Notes a change while the log follows the signals.
local function observe(api, game, session, extended)
    local up = loading_screen(api, game)
    if up == nil then return nil, false end
    local scene = extended and still_covered(api, game) or false
    if session.watch > 0 and signals_changed(session, extended) then note(session, describe_signals(extended)) end
    return up, scene
end

-- Whether a loading period goes on: a loading screen, or a cutscene in the mission
-- after one. A forced session (test builds only) treats every moment as loading.
local function screen_up(api, game, session)
    local up, scene = observe(api, game, session, true)
    if session.force then return true end
    if up == nil then return nil end
    return up or scene
end

-- Polls 4 times a second. Only a loading screen starts a loading period; a cutscene
-- alone never does. For hold.watch seconds after one, the log keeps following the
-- signals and the own pods.
local function idle(api, game, session, dt)
    local watching = session.watch > 0
    if watching then session.watch = session.watch - dt end
    session.since_poll = session.since_poll + dt
    if session.since_poll < hold.poll then return true end
    session.since_poll = 0
    local up = observe(api, game, session, watching)
    if watching then
        local v = read_manager(api, game)
        if v then sight_pods(api, v, session) end
    end
    if not (up or session.force) then return true end
    session.loading, session.last_active, session.scan_wait = true, -1, 0
    if not session.force then
        session.done, session.sighted = {}, {}
        note(session, 'loading screen up')
    end
    return nil
end

-- While a loading period lasts: every frame, a new own pod is held at once.
-- The pods are scanned when the active count changed, and every 0.25 s.
local function loading(api, game, session, dt)
    session.watch = hold.watch
    local up = screen_up(api, game, session)
    if up == nil then return true end
    if not up then
        session.loading, session.since_poll = false, 0
        note(session, 'loading screen gone')
        return true
    end
    local v, problem = read_manager(api, game)
    if not v then return problem ~= 'manager_layout', problem end
    session.scan_wait = session.scan_wait - dt
    if v.active == session.last_active and session.scan_wait > 0 then return true end
    session.last_active, session.scan_wait = v.active, hold.poll
    sight_pods(api, v, session)
    local pod = find_pod(api, v, session.done)
    if not pod then return true end
    local ok, why = start_hold(api, game, session, v, pod)
    if ok == nil then note(session, 'pod ' .. pod.id .. ' left alone: ' .. why) end
    return ok ~= false, why
end

-- 'present', 'gone' or 'unknown', checked at each holding poll.
local function held_state(api, game, held)
    local _, index, why = find_held(api, game, held)
    if index then
        held.index = index
        return 'present'
    end
    return why
end

-- The reason to release now, other than the end of the cover, if any.
local function due(session, held)
    if held.retry then return held.retry end
    if session.force and held.held_for >= session.force then return 'test hold ended' end
    if held.held_for >= hold.cap then return 'longest hold' end
    return nil
end

-- While holding: every frame, the cover is checked, and its end releases the pod in
-- that frame, so the player sees it already falling (v1.1 waited 1.5 s after the
-- end, and the pod looked stuck in the air). 4 times a second, the pod is checked to
-- still be there.
local function holding(api, game, session, dt)
    local held = session.held
    held.held_for = held.held_for + dt
    session.since_poll = session.since_poll + dt
    local reason = due(session, held)
    -- A retry waits for the next poll, so an unreadable manager costs reads only
    -- 4 times a second.
    if reason and (not held.retry or session.since_poll >= hold.poll) then
        session.since_poll = 0
        return release(api, game, session, reason)
    end
    session.watch = hold.watch
    local up, scene = observe(api, game, session, true)
    if up == false and not scene and not session.force and not held.retry then
        session.loading = false
        note(session, 'loading screen and cutscene gone')
        return release(api, game, session, 'loading screen gone')
    end
    if session.since_poll < hold.poll then return true end
    session.since_poll = 0
    if held_state(api, game, held) == 'gone' then
        session.held, session.done[held.id] = nil, true
        note(session, 'pod ' .. held.id .. ' is gone')
    end
    return true
end

-- A fresh session: polls at once.
function hold.session(force)
    return {since_poll = hold.poll, loading = false, last_active = -1, scan_wait = 0, done = {}, sighted = {},
            force = force, watch = 0, seen = {extended = {}}}
end

-- One frame. Returns true, or false and why the mod must stop.
function hold.update(api, game, session, dt)
    if not (type(dt) == 'number' and dt > 0 and dt < 10) then dt = 0 end
    if session.held then return holding(api, game, session, dt) end
    if session.loading then return loading(api, game, session, dt) end
    if idle(api, game, session, dt) then return true end
    return loading(api, game, session, 0)
end

hold.loading_screen = loading_screen
-- These functions run 4 times a second, or every frame only while a loading
-- screen is up, and stay interpreted: compiled, they would add machine code to
-- the game's shared code cache for no gain. Interpreted, a check still
-- allocates nothing.
local functions = {valid_pointer = valid_pointer, is_power_of_two = is_power_of_two, mul32 = mul32,
    still_covered = still_covered, sight_pods = sight_pods,
    map_index = map_index, pointer_at = pointer_at, float_bytes = float_bytes,
    loading_screen = loading_screen, describe_signals = describe_signals, signals_changed = signals_changed,
    read_manager = read_manager, own_drop_pod = own_drop_pod, phase_of = phase_of,
    candidate = candidate, find_pod = find_pod, same_pod = same_pod, locate = locate, find_held = find_held,
    settings_record = settings_record, velocities = velocities, height_of = height_of,
    factor_address = factor_address, store = store, note = note, start_hold = start_hold, release = release,
    observe = observe, screen_up = screen_up, idle = idle, loading = loading, held_state = held_state, due = due,
    holding = holding, session = hold.session, update = hold.update}
-- A name bound to nothing would drop out of the table above: count them.
local listed = 0
for name, check in pairs(functions) do
    assert(type(check) == 'function', name)
    if jit and jit.off then jit.off(check) end
    listed = listed + 1
end
assert(listed == 36, 'drop_hold.lua: a function is missing from the interpreted list')
return hold

end)()
local install_loader = (function()
-- The mod's lifecycle on bingus_runtime.lua's update guard (the family's
-- update-chain policy):
-- - the earlier update runs outside pcall, so its errors reach the game unchanged;
-- - after the earlier update has returned, the hold runs its frame: a poll every
--   0.25 s while no loading screen is up, every frame while one is;
-- - a refusal (a layout or setting the hold cannot verify) stops the mod at once;
--   its own errors stop it after 8 in a burst;
-- - after an error in an update below this mod, the mod releases a held pod and
--   starts afresh once the updates below have returned on 60 frames in a row;
--   8 such errors in a burst stop it, with the pod released. When the mod stops
--   it releases the pod too; the game quitting writes nothing.
-- The log keeps the status and the last events (loading screens, holds, releases).
local function install(create_api, hold, build, runtime)
    if _G.HellpodDropHold then return end
    local state = {revision = build.revision, active = false, status = '', events = {}}
    _G.HellpodDropHold = state  -- lint-ok: R8 the mod's one status table, named after the mod like every family mod's
    local clock = 0
    local function flush()
        pcall(function()
            local logger = rawget(_G, 'CowboyBingusModLoader')
            local file = logger and logger.open_log and logger.open_log('HellpodDropHold.log')
            if not file then return end
            file:write(build.revision .. '\n' .. state.status .. '\n')
            for _, line in ipairs(state.events) do file:write(line .. '\n') end
            file:close()
        end)
    end
    local function report(status, active)
        state.active = active
        if state.status == status then return end
        state.status = status
        print('[HellpodDropHold] ' .. build.revision .. ': ' .. status)
        flush()
    end
    -- Events are rare (a few per mission load); the file keeps the last 40.
    local function note(text)
        local events = state.events
        events[#events + 1] = string.format('%9.2f s  %s', clock, text)
        if #events > 40 then table.remove(events, 1) end
        print('[HellpodDropHold] ' .. text)
        flush()
    end
    -- Both game modules must be the supported build (SHA-256, read once per session for
    -- every mod); any other build gets no change at all.
    local function start()
        if type(runtime) ~= 'table' or type(runtime.guard) ~= 'function' then
            return nil, 'bingus_runtime.lua v1 is required'
        end
        local api = create_api()
        local supported, why = api.verify_build({exe_sha256 = build.exe_sha256, game_sha256 = build.game_sha256})
        if not supported then return nil, why .. '; no change applied' end
        if type(update) ~= 'function' then return nil, 'game update unavailable; no change applied' end
        return api, api.address(api.module('game.dll'))
    end
    local started, api, game = pcall(start)
    if not started or not api then report(tostring(started and game or api), false); return end
    local session, guard
    local function fresh()
        session = hold.session(build.test_hold_seconds)
        session.note = note
    end
    fresh()
    report(build.test_hold_seconds and ('test build: every own drop pod is held for '
        .. build.test_hold_seconds .. ' s') or 'waiting_for_loading_screen', true)
    local frame_dt = 0
    local function step(dt) frame_dt = dt end
    local function frame()
        if type(frame_dt) == 'number' and frame_dt > 0 and frame_dt < 10 then clock = clock + frame_dt end
        local running, reason = hold.update(api, game, session, frame_dt)
        if running == false then guard.stop(reason) end
    end
    -- Releases a held pod; a failed write raises.
    local function release(reason)
        local released, problem = hold.release(api, game, session, reason)
        if not released then error(problem, 0) end
    end
    -- After an error below: release, then start afresh (the next frame polls at once).
    local function pause()
        release('paused')
        fresh()
    end
    -- At shutdown nothing is written: the game is freeing its memory.
    local function stop(reason)
        if reason ~= 'shutdown' then release('stopped') end
    end
    local prefix = 'HellpodDropHold '
    local function log(line)
        if line:sub(1, #prefix) == prefix then line = line:sub(#prefix + 1) end
        report(line, false)
    end
    local installed, problem = pcall(function()
        guard = runtime.guard({name = 'HellpodDropHold', step = step, after = frame, stop = stop,
            pause = pause, log = log, env = _G}).install()
    end)
    if not installed then report(tostring(problem), false) end
end
-- Every function here stays interpreted, like the hold's own. A trace started in
-- step always aborted on returning into the guard's pcall frame, and one started
-- in frame on entering hold.update (jit.off); both kept retrying (19-45 and 19-33
-- failed recordings per game-shaped ledger replay, 2026-10-17), each holding one
-- of LuaJIT's 64 failed-start slots. The rest (the log, start, pause, stop) is
-- cold and could only add aborting starts (a closure is NYI). Interpreted, step
-- and frame cost a few bytecodes a frame.
if jit and jit.off then jit.off(install, true) end
return install

end)()
local function create_runtime_api() return create_api(runtime, runtime_write.extend(runtime_memory.new(runtime))) end
install_loader(create_runtime_api, hold, {revision = 'data-v1.2.1-26088801', exe_sha256 = '0ACC07DEBE04714AE04281E1A66BD2EB9D3D85232953E32A93C8A3DD0874EABE', game_sha256 = '6D1D4D3BC6FC84801D9F8F1B310E13A603D07409F3D9495D74B42E1D0BB1C08F', test_hold_seconds = nil}, runtime)
