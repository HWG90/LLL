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
-- The mod's Windows adapter over Bingus Shared Runtime v1: src/bingus_runtime.lua
-- (the core), src/bingus_memory.lua (reads) and src/bingus_write.lua (checked
-- writes), vendored byte-identical. The build embeds them and passes the core
-- and the memory api, the read side extended by the write side. The runtime
-- declares its Windows functions only under private, versioned FFI names, so
-- another mod's declarations cannot change them, and it reads each module's
-- SHA-256 once per session for every mod. Writes go only into committed private
-- read-write memory, checked with one protection query per region right before
-- the write. read_into reads into a buffer the caller keeps and allocates
-- nothing; the patch's checks use it.
return function(runtime, memory)
    assert(type(memory) == 'table' and type(memory.write_batch) == 'function',
        'bingus_memory.lua and bingus_write.lua v1 are required')
    return {
        module = memory.module, module_hash = memory.module_hash,
        read = memory.read, read_into = memory.read_into, pointer = memory.pointer, distance = memory.distance,
        writable_data = memory.writable_data, write = memory.write, write_batch = memory.write_batch,
    }
end

end)()
local patch = (function()
-- Ownership and layout checks keep the write confined to the base avoidance flag.
local ffi = require('ffi')
local patch = {
    manager_rva = 0x2e287d8, owner_rva = 0x2e38250,
    owner_offset = 0x7c8810, size = 69688,
}
-- The flag's values. Mission initialization sets the game's own value, 1; it is
-- the only value this mod ever replaces, with its own value, 0. Any other value
-- in an otherwise valid manager was written by someone else and is left alone.
local GAME_VALUE, OWN_VALUE = 1, 0
local HIGH = 4294967296

-- Every read lands in one of these buffers, made once, and is decoded in place
-- into numbers: a check allocates nothing (no string, pointer or 64-bit cdata).
-- The addresses it reads are cdata made once per game module and once per
-- manager address (slots and fields below).
local words = ffi.new('uint32_t[6]')  -- a pointer (words 0-1), or the 24-byte set
local word = ffi.new('uint32_t[1]')   -- a record or link count
local flag = ffi.new('uint8_t[1]')    -- the enable byte
local dims = ffi.new('float[4]')      -- width, half width, cell, reciprocal

local slots_game, manager_slot, owner_slot
local function slots(game)
    if game ~= slots_game then
        slots_game, manager_slot, owner_slot = game, game + patch.manager_rva, game + patch.owner_rva
    end
    return manager_slot, owner_slot
end
local fields_manager, at_flag, at_records, at_links, at_set, at_dims
local function fields(manager)
    if manager ~= fields_manager then
        local base = ffi.cast('uint8_t *', manager)
        fields_manager, at_flag, at_records, at_links = manager, base, base + 32772, base + 65544
        at_set, at_dims = base + 65552, base + 69672
    end
end

-- The user-mode pointer stored at address, as a number; nil when unreadable,
-- null or out of range (the runtime's pointer rules).
local function pointer_at(api, address)
    if not api.read_into(address, 8, words) then return nil end
    local high = words[1]
    if high >= 0x8000 then return nil end
    local value = words[0] + high * HIGH
    if value < 0x10000 then return nil end
    return value
end
local function count_at(api, address)
    if not api.read_into(address, 4, word) then return nil end
    return word[0]
end

local function near(a, b)
    return a == a and math.abs(a - b) <= math.max(0.00001, math.abs(b) * 0.00001)
end
-- An exact +0.0: all four bytes zero.
local function zero(value)
    return value == 0 and 1 / value > 0
end
-- Aboard ship this storage exists but has not been initialized: every field zero.
local function blank(records, links)
    return flag[0] == 0 and records == 0 and links == 0
        and words[0] == 0 and words[1] == 0 and words[2] == 0 and words[3] == 0 and words[4] == 0 and words[5] == 0
        and zero(dims[0]) and zero(dims[1]) and zero(dims[2]) and zero(dims[3])
end
-- Record and link bounds, the set's self-pointer and the map geometry of an
-- initialized manager, from the buffers just read. The flag is classified apart
-- (see patch.apply).
local function layout_valid(manager, records, links)
    local width, half, cell, reciprocal = dims[0], dims[1], dims[2], dims[3]
    return records <= 1024 and links <= 8192
        and words[1] < 0x8000 and words[0] + words[1] * HIGH - manager == 65576
        and words[2] == 1024 and words[3] <= 1024 and words[4] == 3
        and width >= 64 and width <= 16384
        and near(half, width / 2) and near(cell, width / 64) and near(reciprocal, 1 / cell)
end

-- One reused view of the manager, so a poll allocates no table.
local view = {set = {0, 0, 0, 0, 0, 0}, dims = {0, 0, 0, 0}}
-- The manager as read now: the view when it is initialized and its layout is
-- valid, otherwise nil, whether to keep polling, and the status.
local function inspect(api, game)
    local manager_address, owner_address = slots(game)
    local manager, owner = pointer_at(api, manager_address), pointer_at(api, owner_address)
    if not manager or not owner then return nil, true, 'waiting_for_mission' end
    if manager - owner ~= patch.owner_offset then return nil, false, 'avoidance_owner_mismatch' end
    fields(manager)
    local read_flag = api.read_into(at_flag, 1, flag)
    local records, links = count_at(api, at_records), count_at(api, at_links)
    local read_set, read_dims = api.read_into(at_set, 24, words), api.read_into(at_dims, 16, dims)
    if not (read_flag and records and links and read_set and read_dims) then
        return nil, false, 'avoidance_fields_unreadable'
    end
    if blank(records, links) then return nil, true, 'waiting_for_mission', manager end
    if not layout_valid(manager, records, links) then return nil, false, 'avoidance_layout_mismatch' end
    view.manager, view.owner, view.enabled = manager, owner, flag[0]
    local set, dimensions = view.set, view.dims
    for i = 0, 5 do set[i + 1] = words[i] end
    for i = 0, 3 do dimensions[i + 1] = dims[i] end
    return view
end

-- This mod's own write: the manager and owner addresses, set and dimensions of
-- the manager it cleared, as numbers, so tracking costs no read or allocation.
local function remember(own, v)
    own.manager, own.owner = v.manager, v.owner
    own.set, own.dims = own.set or {}, own.dims or {}
    for i = 1, 6 do own.set[i] = v.set[i] end
    for i = 1, 4 do own.dims[i] = v.dims[i] end
end
local function forget(own)
    own.manager = nil
end
local function owns(own, v)
    if own.manager ~= v.manager or own.owner ~= v.owner then return false end
    for i = 1, 6 do if own.set[i] ~= v.set[i] then return false end end
    for i = 1, 4 do if own.dims[i] ~= v.dims[i] then return false end end
    return true
end

-- The set and the dimensions just read, against the view.
local function same_set(v)
    for i = 0, 5 do if words[i] ~= v.set[i + 1] then return false end end
    return true
end
local function same_dims(v)
    for i = 0, 3 do if dims[i] ~= v.dims[i + 1] then return false end end
    return true
end
-- Recheck identity and the exact target immediately before a write. Mission
-- initialization can reset this manager between checks.
local function stable(api, game, v, expected)
    local manager_address, owner_address = slots(game)
    local manager, owner = pointer_at(api, manager_address), pointer_at(api, owner_address)
    fields(v.manager)
    return manager == v.manager and owner == v.owner
        and api.read_into(at_flag, 1, flag) and flag[0] == expected
        and api.read_into(at_set, 24, words) and same_set(v)
        and api.read_into(at_dims, 16, dims) and same_dims(v)
end

-- The single write. One memory-protection query, right before the one-byte
-- store, requires the whole manager to be committed private read-write data
-- (never executable or module pages). Only a refused write queries again, to
-- report which check failed. Returns nothing on success, else the failure.
local CLEAR, RESTORE = {{0, '\0'}}, {{0, '\1'}}
local function write_flag(api, v, change, value)
    fields(v.manager)
    if not api.write_batch(at_flag, patch.size, change) then
        if not api.writable_data(at_flag, patch.size) then return 'avoidance_is_not_writable_private_data' end
        return 'avoidance_data_write_failed'
    end
    if not api.read_into(at_flag, 1, flag) or flag[0] ~= value then return 'avoidance_data_write_failed' end
end

local function clear(api, game, v, own)
    if not stable(api, game, v, GAME_VALUE) then return true, 'waiting_for_stable_mission', false end
    local failure = write_flag(api, v, CLEAR, OWN_VALUE)
    if failure then return false, failure, false end
    remember(own, v)
    return true, 'avoidance_settings_ready', true
end

-- Waiting for work. The work is a flag change: mission initialization sets the
-- game's 1 in place, in the storage that sits blank (all zero) aboard ship. The
-- manager and owner keep their addresses from the ship into the mission (ledger
-- tape 20261017-000228: one address pair for the whole session). So after a full
-- check, a poll reads only the flag byte (one 1-byte ReadProcessMemory): the value
-- the full check saw means nothing to do. Any other value, or a failed read, runs
-- the full check on that same poll, so a mission reset is still cleared within
-- one poll (100 ms), as before: a joiner's pod is spawned at once, during loading,
-- so the drop can need the cleared flag right after initialization.
-- Every REVALIDATE-th poll is a full check anyway: it notices what the flag
-- alone cannot show (the manager going blank after a mission, new pointers, a
-- layout or ownership change) at most REVALIDATE polls (1 s) late; before, at
-- most one poll late.
local REVALIDATE = 10
-- The watch lives in own (the caller's table), next to the record of the write.
local function arm(own, manager, value)
    own.watch_manager, own.watch_value, own.watch_left = manager, value, REVALIDATE - 1
end

-- true: the flag holds the value the last full check saw and no full check is
-- due; the poll is done. false: run patch.apply now (the watch is dropped).
-- Allocates nothing.
function patch.idle(api, own)
    local manager, left = own.watch_manager, own.watch_left
    if manager == nil then return false end
    if left <= 0 then own.watch_manager = nil; return false end
    fields(manager)
    if not api.read_into(at_flag, 1, flag) or flag[0] ~= own.watch_value then
        own.watch_manager = nil
        return false
    end
    own.watch_left = left - 1
    return true
end

-- accepted (false stops the mod), status, active. own is the caller's table
-- for this mod's write. The flag is written only over the game's own value:
-- 0 needs nothing, 1 is cleared again (mission initialization reset it), and
-- any other value belongs to another writer: it is left alone and reported,
-- and polling goes on. A check that read the flag of a blank or valid manager,
-- and needs no recheck at the next poll, arms the watch with that value.
function patch.apply(api, game, own)
    own.watch_manager = nil
    local v, polling, status, blank_manager = inspect(api, game)
    if not v then
        forget(own)
        if blank_manager then arm(own, blank_manager, 0) end
        return polling, status, false
    end
    if v.enabled == OWN_VALUE then
        if not owns(own, v) then forget(own) end
        arm(own, v.manager, OWN_VALUE)
        return true, 'avoidance_settings_ready', true
    end
    forget(own)
    if v.enabled ~= GAME_VALUE then
        arm(own, v.manager, v.enabled)
        return true, 'avoidance_flag_set_by_another_writer', false
    end
    local accepted, cleared, active = clear(api, game, v, own)
    if active then arm(own, v.manager, OWN_VALUE) end
    return accepted, cleared, active
end

-- Puts the game's own value back, only over this mod's own write: the flag must
-- still hold 0 in the manager, owner, set and dimensions this mod cleared, with
-- the layout still valid, rechecked right before the store. Anything else is
-- left alone. Forgets the write either way. Returns ok (false: the write
-- failed) and the outcome.
-- The watch is dropped: the next poll (after a resume) runs the full check.
function patch.restore(api, game, own)
    own.watch_manager = nil
    if own.manager == nil then return true, 'nothing_to_restore' end
    local v = inspect(api, game)
    local ours = v and v.enabled == OWN_VALUE and owns(own, v)
    forget(own)
    if not ours or not stable(api, game, v, OWN_VALUE) then return true, 'avoidance_left_unchanged' end
    local failure = write_flag(api, v, RESTORE, GAME_VALUE)
    if failure then return false, failure end
    return true, 'avoidance_restored'
end
-- The poll runs ten times a second and stays interpreted, as apply always did
-- (its traces aborted). Compiled, these functions would add about 6.6 KB to the
-- game's shared code cache to save about 0.25 us per frame (offline, game's
-- lua51.dll); interpreted, a check still allocates nothing.
if jit and jit.off then
    for _, check in ipairs({slots, fields, pointer_at, count_at, near, zero, blank, layout_valid, inspect, remember,
        forget, owns, same_set, same_dims, stable, write_flag, clear, arm, patch.idle, patch.apply, patch.restore}) do
        jit.off(check)
    end
end
return patch

end)()
local install_loader = (function()
-- The mod's lifecycle on bingus_runtime.lua's update guard (the family's
-- update-chain policy):
-- - the earlier update runs outside pcall, so its errors reach the game unchanged;
-- - every 100 ms, after the earlier update has returned, the patch checks the
--   avoidance flag and clears it over the game's own value;
-- - a refusal (a layout the patch cannot verify) stops the mod at once; its own
--   errors stop it after 8 in a burst;
-- - after an error in an update below this mod, the mod puts the game's value
--   back over its own write and starts afresh: once the updates below have
--   returned on 60 frames in a row it checks again. 8 such errors in a burst
--   stop it, with the game's value put back. The game quitting writes nothing.
return function(create_api, patch, build, runtime)
    if _G.HellpodSteeringUnlocked then return end
    local state = {revision = build.revision, active = false, status = ''}
    _G.HellpodSteeringUnlocked = state
    local function report(status, active)
        state.active = active
        if state.status == status then return end
        state.status = status
        print('[HellpodSteeringUnlocked] ' .. build.revision .. ': ' .. status)
        pcall(function()
            local logger=rawget(_G,'CowboyBingusModLoader')
            local file=logger and logger.open_log and logger.open_log('HellpodSteeringUnlocked.log')
            if file then file:write(build.revision .. '\n' .. status .. '\n'); file:close() end
        end)
    end
    local ok, api, game = pcall(function()
        assert(type(runtime) == 'table' and type(runtime.guard) == 'function', 'bingus_runtime.lua v1 is required')
        local api = create_api()
        local exe, game = api.module(nil), api.module('game.dll')
        assert(exe and game, 'Required game modules unavailable')
        assert(api.module_hash(exe) == build.exe_sha256, 'Unsupported executable; no change applied')
        assert(api.module_hash(game) == build.game_sha256, 'Unsupported game module; no change applied')
        assert(type(update) == 'function', 'Game update unavailable; no change applied')
        return api, game
    end)
    if not ok then report(tostring(api), false); return end
    report('waiting_for_mission', false)
    local POLL, own, guard = 0.1, {}, nil
    local elapsed, frame_dt = POLL, 0
    local function step(dt) frame_dt = dt end
    -- Because mission initialization resets the flag, it is checked every 100 ms.
    -- Between full checks the patch's idle gate (steering_patch.lua patch.idle)
    -- answers a poll with one read of the flag byte: no apply, no report.
    local idle = patch.idle
    local function poll()
        local dt = frame_dt
        elapsed = elapsed + ((type(dt) == 'number' and dt == dt and dt > 0) and dt or 0)
        if elapsed < POLL then return end
        elapsed = 0
        if idle and idle(api, own) then return end
        local accepted, reason, active = patch.apply(api, game, own)
        if not accepted then return guard.stop(reason) end
        report(tostring(reason), active == true)
    end
    -- Puts the game's value back over this mod's own write; a failed write raises.
    local function restore()
        local restored, outcome = patch.restore(api, game, own)
        if outcome ~= 'nothing_to_restore' then report(state.status .. '; ' .. outcome, false) end
        if not restored then error(outcome, 0) end
    end
    -- The first frame after the resume checks at once.
    local function pause()
        elapsed = POLL
        restore()
    end
    -- At shutdown nothing is written: the game is freeing its memory and the
    -- flag no longer matters.
    local function stop(reason)
        if reason ~= 'shutdown' then restore() end
    end
    local prefix = 'HellpodSteeringUnlocked '
    local function log(line)
        if line:sub(1, #prefix) == prefix then line = line:sub(#prefix + 1) end
        report(line, false)
    end
    -- The guard calls step and poll under pcall, so a trace started at either's
    -- entry aborts where it returns ("NYI: return to lower frame") and retries
    -- whenever LuaJIT's 64 penalty slots have evicted it. Neither has a loop:
    -- they run interpreted (a few bytecodes per frame, and the patch's checks
    -- were interpreted already).
    if type(jit) == 'table' and type(jit.off) == 'function' then
        jit.off(step)
        jit.off(poll)
    end
    local installed, problem = pcall(function()
        guard = runtime.guard({name = 'HellpodSteeringUnlocked', step = step, after = poll, stop = stop,
            pause = pause, log = log, env = _G}).install()
    end)
    if not installed then report(tostring(problem), false) end
end

end)()
local function create_runtime_api() return create_api(runtime, runtime_write.extend(runtime_memory.new(runtime))) end
install_loader(create_runtime_api, patch, {revision = 'data-v7.5.1-26251122', exe_sha256 = '257FD7DE21A04E8668E02E5C820EDF3435176FBDE3569765255CC52A5EA20F9D', game_sha256 = '61DCFCD201DACBF3545C97BEB8A5A6186E9850D2670BF60B0E058320B477F6DF'}, runtime)
