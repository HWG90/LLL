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
-- The mod's Windows adapter over Bingus Shared Runtime v1: the memory api of
-- src/bingus_memory.lua extended by src/bingus_write.lua (vendored
-- byte-identical; the build embeds them and passes the api in). The runtime
-- declares its Windows functions only under private, versioned FFI names, so
-- another mod's declarations cannot change them, and it reads each module's
-- SHA-256 once per session for every mod. Writes go only into committed private
-- read-write memory, checked with one protection query per region right before
-- the write.
local ffi = require('ffi')
local HIGH = 4294967296

-- The user-mode pointer stored little-endian at buffer[offset .. offset + 7]
-- of a byte buffer the mod keeps (filled by read_into), as uint8_t *, or nil:
-- memory.pointer's rules for a string, without first copying the bytes into one.
local function pointer_at(buffer, offset)
    if buffer[offset + 6] ~= 0 or buffer[offset + 7] ~= 0 then return nil end
    local value = buffer[offset] + buffer[offset + 1] * 256 + buffer[offset + 2] * 65536
        + buffer[offset + 3] * 16777216 + (buffer[offset + 4] + buffer[offset + 5] * 256) * HIGH
    if value < 0x10000 or value >= 0x800000000000 then return nil end
    return ffi.cast('uint8_t *', value)
end

return function(runtime, memory)
    assert(type(runtime) == 'table' and type(runtime.guard) == 'function', 'bingus_runtime.lua v1 is required')
    assert(type(memory) == 'table' and type(memory.write) == 'function', 'bingus_memory.lua and bingus_write.lua are required')
    return {
        module = memory.module, module_hash = memory.module_hash,
        read = memory.read, read_into = memory.read_into, pointer = memory.pointer, pointer_at = pointer_at,
        distance = memory.distance, writable_data = memory.writable_data, write = memory.write,
    }
end

end)()
local patch = (function()
local ffi, bit = require('ffi'), require('bit')
local band, rshift, ldexp, abs = bit.band, bit.rshift, math.ldexp, math.abs
local patch = {}
local unavailable = {}
-- The player manager global, and the spawn state of a pending reinforcement.
local PLAYER_MANAGER, PENDING = 0x2CE1618, string.char(2, 0, 0, 0)

-- Read buffers kept for the session: every read goes into one of these
-- (api.read_into, no string per read) and is decoded in place. Each holds one
-- kind of data, so nothing a snapshot still decodes is overwritten by another
-- read; a second snapshot in the same frame overwrites them only after the
-- first has copied out everything it keeps.
local function buffer(size) return ffi.new('uint8_t[?]', size) end
local MODE, PLAYERS, ENTITY = buffer(0x44), buffer(0x440), buffer(24)
local REINFORCEMENT, POSITIONS = buffer(0x58), buffer(0x60)
local ENTITIES, USED = buffer(128*8), buffer(128*4)
local POINTER, ROW, COORDINATES, BYTE = buffer(8), buffer(8), buffer(12), buffer(1)
-- The idle gate's own buffers: the player manager global and the spawn state.
local MANAGER, SPAWN = buffer(8), buffer(4)
local STRATAGEMS, SOURCE_LOOKUP, REGISTRY = buffer(0x80), buffer(20), buffer(0xA8)
-- The stratagem rows grow to the largest count seen (at most 512 x 64 B).
local rows, rows_size = nil, 0

local function u32(b, offset)
    return b[offset] + 256*b[offset+1] + 65536*b[offset+2] + 16777216*b[offset+3]
end
-- A float decoded from its bits: nil for NaN or infinity. Loading the value
-- through a float cdata instead can turn a NaN into a value that is not a Lua
-- number in this NaN-tagged LuaJIT, where math.abs or a comparison would raise.
local function float(b, offset)
    local bits = u32(b, offset)
    local exponent = band(rshift(bits, 23), 0xff)
    if exponent == 255 then return nil end
    local mantissa = band(bits, 0x7fffff)
    local value = exponent == 0 and ldexp(mantissa, -149) or ldexp(mantissa + 0x800000, exponent - 150)
    if bits >= 0x80000000 then return -value end
    return value
end
local function vector(b, offset)
    local x, y, z = float(b, offset), float(b, offset+4), float(b, offset+8)
    if not (x and y and z) or abs(x) > 100000 or abs(y) > 100000 or abs(z) > 100000 then return nil end
    return {x, y, z}
end
local function xy_bytes(v)
    return ffi.string(ffi.new('float[2]', {v[1], v[2]}), 8)
end
local function same_xy(a,b)
    return a and b and math.abs(a[1]-b[1]) < 0.05 and math.abs(a[2]-b[2]) < 0.05
end
local function first_unused(beacons,mask)
    local first,count=nil,0
    for _,beacon in ipairs(beacons or {}) do
        if bit.band(beacon.used,mask)==0 then
            first=first or beacon
            count=count+1
        end
    end
    return first,count
end
-- The correction's write. api.write checks memory protection itself, once,
-- right before the store: existing private read-write data only. Only a
-- refused write queries again, to keep the status for non-writable data.
local function write_xy(api,address,bytes)
    if api.write(address,bytes) then return true end
    assert(api.writable_data(address,#bytes),'Target is not existing private writable data')
    return false
end

-- Each address below comes from the build-locked read-only native/data trace.
-- Pointer following is read-only. The only write site is player_manager+0x10C.
--
-- A snapshot reads through one reader: {api, game, exe, stage}. stage names
-- the data being read: missing data raises "waiting for game data" at that
-- stage (retried on the next check), malformed data an assertion naming it.
local function wait_for_data(reader)
    error({kind=unavailable,status='waiting_for_game_data:'..reader.stage},0)
end
-- All size bytes into buffer, or "waiting for game data": api.read_into never
-- returns part of a range.
local function read(reader, address, size, into)
    if not reader.api.read_into(address,size,into) then wait_for_data(reader) end
    return into
end
local function data_pointer(reader,b,offset)
    offset=offset or 0
    if u32(b,offset)==0 and u32(b,offset+4)==0 then wait_for_data(reader) end
    local value=reader.api.pointer_at(b,offset)
    if not value then error('Invalid spawn data pointer: '..reader.stage) end
    return value
end
local function pointer(reader,address) return data_pointer(reader,read(reader,address,8,POINTER)) end
local function global(reader,rva,name)
    reader.stage=name
    return pointer(reader,reader.game+rva)
end
-- The table index of key in the lookup whose header starts at header+offset,
-- or nil.
local function lookup(reader, header, offset, key)
    local capacity, empty, multiplier = u32(header,offset+8), u32(header,offset+12), u32(header,offset+16)
    if capacity == 0 then return nil end
    assert(capacity <= 1048576 and bit.band(capacity,capacity-1)==0, 'Invalid lookup capacity')
    local table_address = data_pointer(reader,header,offset)
    -- Exact low word of key x multiplier: Lua doubles cannot multiply two
    -- arbitrary uint32s exactly, so the multiplier goes in 16-bit halves; each
    -- partial product stays below 2^49, where tobit wraps exactly.
    local low = multiplier % 65536
    local product = bit.tobit(key*low + (key*((multiplier-low)/65536)) % 65536 * 65536)
    for probe=0,math.min(capacity,128)-1 do
        local slot = bit.band(product+probe,capacity-1)
        read(reader,table_address+8*slot,8,ROW)
        if u32(ROW,0)==key then
            local index=u32(ROW,4)
            if index~=0xffffffff then return index end
            return nil
        end
        if u32(ROW,0)==empty then return nil end
    end
    return nil
end

-- The mission mode, then (in gameplay modes 1..7 only) the player manager and
-- its player block: a new snapshot with the mode and, in a mission, the
-- identity, the pending spawn's address and the player count; also the
-- available-player count. Aboard the ship (mode 0) this is the whole check.
local function session(reader)
    read(reader,global(reader,0x2ce1850,'mission_mode'),0x44,MODE)
    local mode=u32(MODE,8)>0 and u32(MODE,0x40) or 0
    -- Outside gameplay the plan only resets, reading nothing else.
    if mode<1 or mode>7 then return {mode=mode},0 end
    local pm = global(reader,PLAYER_MANAGER,'player_manager')
    read(reader,pm,0x440,PLAYERS)
    local count, available = u32(PLAYERS,0x84),u32(PLAYERS,0x88)
    assert(count<=4 and available<=4, 'Unsupported player layout')
    -- The identity is the player manager pointer itself: == and ~= compare two
    -- pointers by address, allocating nothing. The game replaces tostring, which
    -- prints every cdata as '[cdata (deleted)]', so a string identity never changed.
    return {identity=pm, address=pm+0x10C, count=count, mode=mode, beacons={}, automatic={}},available
end

-- The local player's identity, spawn state, use bit and pending spawn, from
-- the player block session read. True when this machine owns the local player.
local function local_player(reader,snapshot)
    reader.stage='local_player'
    read(reader,data_pointer(reader,PLAYERS,0xE8),24,ENTITY)
    snapshot.id, snapshot.owned = u32(ENTITY,8),bit.band(ENTITY[20],1)==1
    snapshot.state, snapshot.use_bit = u32(PLAYERS,0x2E0),u32(PLAYERS,0x3B4)
    snapshot.position=vector(PLAYERS,0x10C)
    -- The pending XY as the write and restore need it: compared and written
    -- only while a spawn is pending (state 2), so only then kept as a string.
    if snapshot.state==2 then snapshot.original=ffi.string(PLAYERS+0x10C,8) end
    snapshot.countdown=float(PLAYERS,0x12C)
    snapshot.unit_ref=u32(PLAYERS,0x3A8)
    assert(snapshot.use_bit<32, 'Unsupported player-use bit')
    return snapshot.owned
end

-- The reinforcement manager's records and the count of active records; with
-- positioned, also the position manager's block. A beacon position is only
-- compared while a reinforcement is queued or pending (states 1 and 2).
local function beacon_managers(reader,positioned)
    read(reader,global(reader,0x2ce1b78,'reinforcement_manager'),0x58,REINFORCEMENT)
    local active=u32(REINFORCEMENT,12)
    assert(active<=128 and active<=u32(REINFORCEMENT,8), 'Unsupported reinforcement layout')
    if positioned and active>0 then read(reader,global(reader,0x2ce1ce0,'position_manager'),0x60,POSITIONS) end
    return active
end

-- A beacon's position through the position manager's lookup, or nil.
local function beacon_position(reader,id)
    local index=lookup(reader,POSITIONS,0x28,id)
    if not index then return nil end
    assert(index<u32(POSITIONS,8), 'Position index outside live data')
    return vector(read(reader,data_pointer(reader,POSITIONS,0x50)+index*12,12,COORDINATES),0)
end

-- Every active reinforcement record: id, ownership, position (in states 1
-- and 2, through the position manager's lookup, or nil) and use bits. The
-- entity pointers and use bits are read once for all records.
local function beacon_records(reader,snapshot)
    local positioned=snapshot.state==1 or snapshot.state==2
    local active=beacon_managers(reader,positioned)
    if active>0 then
        reader.stage='reinforcement_records'
        read(reader,data_pointer(reader,REINFORCEMENT,0x38),8*active,ENTITIES)
        read(reader,data_pointer(reader,REINFORCEMENT,0x48),4*active,USED)
        for i=0,active-1 do
            read(reader,data_pointer(reader,ENTITIES,8*i),24,ENTITY)
            local id=u32(ENTITY,8)
            snapshot.beacons[#snapshot.beacons+1]={id=id, owned=bit.band(ENTITY[20],1)==1,
                position=positioned and beacon_position(reader,id) or nil, used=u32(USED,4*i)}
        end
    end
end

-- Solo: the active stratagem rows, read at once, and their count.
local function stratagem_rows(reader)
    read(reader,global(reader,0x2ce1860,'automatic_anchor_manager'),0x80,STRATAGEMS)
    local n=u32(STRATAGEMS,0x34)
    assert(n<=512, 'Unsupported active stratagem count')
    if n==0 then return 0 end
    if n*64>rows_size then rows,rows_size=buffer(n*64),n*64 end
    read(reader,data_pointer(reader,STRATAGEMS,0x78),n*64,rows)
    return n
end

-- Solo: every automatic-reinforcement dummy with a usable position.
local function automatic_anchors(reader,snapshot)
    local n=stratagem_rows(reader)
    for i=0,n-1 do
        local base=i*64
        -- Current automatic-reinforcement producer ACCC96 / ACCEC5 (26088801: AE8EF6 / AE9125, type 0x7F).
        if u32(rows,base+12)==0x7F then
            local v=vector(rows,base+16)
            if v then snapshot.automatic[#snapshot.automatic+1]={
                key=ffi.string(rows+base+16,12),position=v} end
        end
    end
end

-- The source unit's world position through the unit registry: entity index,
-- engine reference, registry slot and generation, scene-graph object.
local function unit_position(reader,em,index)
    assert(index<262144, 'Entity index outside supported bound')
    local engine_ref=u32(read(reader,em+15944160+24*index,24,ENTITY),12)
    reader.stage='source_unit_registry'
    read(reader,pointer(reader,reader.exe+0x1ab76f8),0xA8,REGISTRY)
    local slot,generation=bit.band(engine_ref,0x3fffff),bit.rshift(engine_ref,22)
    assert(slot<u32(REGISTRY,0x98), 'Unit slot outside registry')
    local generations=data_pointer(reader,REGISTRY,0xA0)
    assert(read(reader,generations+slot,1,BYTE)[0]==generation, 'Unit generation changed')
    local objects=data_pointer(reader,REGISTRY,0x88)
    local object=pointer(reader,objects+8*slot)
    local vtable=pointer(reader,object)
    assert(reader.api.distance(pointer(reader,vtable+0xE8),reader.exe)==0x28d3a0, 'Unsupported unit scene-graph layout')
    return vector(read(reader,pointer(reader,object+0x88)+0x30,12,COORDINATES),0)
end

-- Solo: the position a death anchor freezes. Reproduces AC5BB0's
-- unit-world-position read, without calling native code; the fallback
-- position when the local player has no source unit.
local function source_position(reader,unit_ref)
    local em=global(reader,0x2ce41b8,'source_entity_manager')
    local index=unit_ref~=0x7fff and lookup(reader,read(reader,em+15878544,20,SOURCE_LOOKUP),0,unit_ref) or nil
    if index then return unit_position(reader,em,index) end
    return vector(read(reader,global(reader,0x2e287d0,'fallback_position')+0x3C,12,COORDINATES),0)
end

local function snapshot(api, game, exe)
    local reader={api=api,game=game,exe=exe,stage='mission_mode'}
    local snapshot,available=session(reader)
    -- Native player logic accepts gameplay modes 1..7, including defense (2).
    if snapshot.mode<1 or snapshot.mode>7 or snapshot.count==0 or available==0 then return snapshot end
    if not local_player(reader,snapshot) then return snapshot end
    beacon_records(reader,snapshot)
    if snapshot.count~=1 then return snapshot end
    automatic_anchors(reader,snapshot)
    -- The source position is read only when an anchor is captured (see
    -- patch.source): solo frames that capture nothing skip its ~12 reads.
    snapshot.reader=reader
    return snapshot
end

-- Converts "waiting for game data" into nil and its status; any other error
-- (an unsupported layout) is raised again.
local function settle(ok,result)
    if ok then return result end
    if type(result)=='table' and result.kind==unavailable then return nil,result.status end
    error(result,0)
end

function patch.snapshot(api,game,exe)
    return settle(pcall(snapshot,api,game,exe))
end

-- Solo: the source position of this snapshot's local player, read now, or
-- nil; nil and the waiting status when its game data is unavailable. A
-- snapshot that already carries a source (generated tests) keeps it.
function patch.source(current)
    if current.source~=nil or not current.reader then return current.source end
    local source,waiting=settle(pcall(source_position,current.reader,current.unit_ref))
    current.source=source
    return source,waiting
end

-- Pure event tracking; never adjusts a live pod, timers, use bits or network state.

-- Whether an automatic dummy with this key was in the previous snapshot.
local function was_present(automatic, key)
    local present=false
    for _,old in ipairs(automatic or {}) do
        if old.key==key then present=true end
    end
    return present
end

-- Automatic dummy type 0x7C exists before its reinforcement component.
-- Freeze the source once, so a moving corpse/camera cannot move the target later.
-- The source is read here, for the first new dummy only: no source (nil)
-- captures nothing, as before. Returns the waiting status when the source's
-- game data is unavailable, or nil.
-- After the idle gate, previous is its baseline: its rows are those of the
-- last solo landing on this player manager (an earlier death's anchor that is
-- still listed is not new), or nil when none was seen. With no rows known,
-- only a lone row can be the death's anchor; several are ambiguous and
-- capture nothing.
local function capture_anchor(previous, current, state)
    if not (current.count==1 and (current.state==1 or current.state==2) and not state.anchor) then return nil end
    if not previous.automatic and #current.automatic~=1 then return nil end
    for _,auto in ipairs(current.automatic) do
        if not was_present(previous.automatic,auto.key) then
            local source,waiting=patch.source(current)
            if source then state.anchor={key=auto.key, position=auto.position, source=source} end
            return waiting
        end
    end
    return nil
end

-- Why this check cannot correct the spawn, before any beacon is considered;
-- nil when it may.
local function spawn_blocked(previous, current, state)
    if current.state~=2 then return 'waiting_for_reinforcement' end
    if previous.state~=2 and previous.state~=1 and previous.state~=3 then
        return 'initial_deployment_unchanged'
    end
    -- Alive (3) straight to pending (2) with no queued frame: the gate never
    -- read the beacons' use bits before this spawn, so no beacon can be
    -- associated with it safely. Whether this happens in game is unmeasured.
    if previous.unobserved then return 'pending_without_queue_skipped' end
    if state.pending then return 'reinforcement_already_centered' end
    if not current.position or not current.countdown or current.countdown~=current.countdown
        or current.countdown<=0.1 or current.countdown>5.1 then
        return 'spawn_window_unavailable'
    end
    return nil
end

-- Whether the beacon with this id already had the local use bit set.
local function used_before(beacons, id, mask)
    local used=false
    for _,old in ipairs(beacons or {}) do
        if old.id==id and bit.band(old.used,mask)~=0 then used=true end
    end
    return used
end

-- The beacons with a position whose local use bit was set since the previous snapshot.
local function newly_used(previous, current, mask)
    local selected={}
    for _,beacon in ipairs(current.beacons) do
        if bit.band(beacon.used,mask)~=0 and beacon.position and not used_before(previous.beacons,beacon.id,mask) then
            selected[#selected+1]=beacon
        end
    end
    return selected
end

-- AC7280 chooses the first unused record. AC83F0 marks it only when the
-- beacon is locally owned, so a teammate's beacon can stay unused through the
-- local queue commit. Preserve that observed selection: the candidate, or nil.
local function unmarked_remote(previous, current, mask)
    local old=first_unused(previous.beacons,mask)
    local candidate,unused_count=first_unused(current.beacons,mask)
    if candidate and candidate.owned==false and candidate.position
        and ((old and old.owned==false and old.id==candidate.id and same_xy(old.position,candidate.position))
             or (not old and unused_count==1)) then
        return candidate
    end
    return nil
end

-- The one beacon this spawn belongs to and how it was associated, or nil.
local function associated_beacon(previous, current, mask)
    local selected=newly_used(previous,current,mask)
    local beacon,association=selected[1],'used'
    if #selected==0 and current.count>1 and previous.state==1 then
        local candidate=unmarked_remote(previous,current,mask)
        if candidate then beacon,association=candidate,'unmarked_remote' end
    end
    if #selected>1 or not beacon then return nil end
    return beacon,association
end

-- The correction's target, the beacon's position or solo the frozen source
-- of its anchor, within the supported range of the pending spawn.
local function placement(current, state, beacon, association)
    local target,kind=beacon.position,'beacon'
    if current.count==1 then
        if not state.anchor or not same_xy(state.anchor.position,beacon.position) then
            return nil,'solo_anchor_unavailable'
        end
        target,kind=state.anchor.source,'solo'
    end
    local dx,dy=target[1]-current.position[1],target[2]-current.position[2]
    if dx*dx+dy*dy>512*512 then return nil,'placement_outside_supported_range' end
    return {bytes=xy_bytes(target),target={target[1],target[2]},kind=kind,beacon=beacon.id,
            association=association,beacon_position=beacon.position},'ready'
end

-- Forgets every association, as when game data becomes unavailable (a fresh start).
local function forget(state)
    state.previous,state.anchor,state.pending,state.spawn,state.landed=nil,nil,nil,nil,nil
end

function patch.plan(current, state)
    local previous=state.previous
    state.previous=current
    -- Another player manager, local player, player count or mode, a mode
    -- outside gameplay, not owned here, or no reinforcement under way.
    if not previous or previous.identity~=current.identity or previous.id~=current.id
        or previous.count~=current.count or previous.mode~=current.mode
        or current.mode<1 or current.mode>7 or not current.owned
        or current.state==3 or current.state==0 then
        state.anchor,state.pending=nil,nil
        return nil,'waiting_for_reinforcement'
    end
    local waiting=capture_anchor(previous,current,state)
    -- Unavailable source data forgets every association, as an unavailable
    -- snapshot does (the source used to be part of every solo snapshot).
    if waiting then forget(state);return nil,waiting end
    local blocked=spawn_blocked(previous,current,state)
    if blocked then return nil,blocked end
    local beacon,association=associated_beacon(previous,current,bit.lshift(1,current.use_bit))
    if not beacon then return nil,'beacon_association_unavailable' end
    return placement(current,state,beacon,association)
end

-- Whether the re-read changed the pending spawn the plan was made for.
local function spawn_changed(current, fresh)
    return fresh.identity~=current.identity or fresh.id~=current.id or fresh.unit_ref~=current.unit_ref
        or fresh.use_bit~=current.use_bit
        or fresh.count~=current.count or fresh.mode~=current.mode or not fresh.owned or fresh.state~=2
        or not fresh.countdown or fresh.countdown<=0.1 or fresh.countdown>5.1
        or fresh.original~=current.original
end

-- Whether the re-read still associates the planned beacon with this spawn.
local function beacon_kept(fresh, plan)
    local found=false
    local mask=bit.lshift(1,fresh.use_bit)
    local first=first_unused(fresh.beacons,mask)
    for _,b in ipairs(fresh.beacons) do
        if b.id==plan.beacon and same_xy(b.position,plan.beacon_position) then
            if plan.association=='unmarked_remote' then
                found=b.owned==false and first and first.id==b.id and bit.band(b.used,mask)==0
            else
                found=bit.band(b.used,mask)~=0
            end
        end
    end
    return found
end

-- The single write and its read-back. A refused or partial write puts the
-- original XY back while the spawn is still pending, and stops the correction.
local function write_correction(api, fresh, plan)
    local written=write_xy(api,fresh.address,plan.bytes)
    local actual=api.read(fresh.address,8)
    if not written or actual~=plan.bytes then
        -- Same field, while the original spawn record is still pending.
        if api.read(fresh.address-0x10C+0x2E0,4)==PENDING then
            api.write(fresh.address,fresh.original)
        end
        error('Spawn data write failed; correction stopped')
    end
end

-- Keeps what the write replaced, so patch.restore can put it back, and the
-- correction for the log.
local function record_correction(state, current, fresh, plan)
    plan.address,plan.original=fresh.address,fresh.original
    state.pending=plan
    state.corrections=(state.corrections or 0)+1
    state.last={kind=plan.kind,beacon=plan.beacon,association=plan.association,from=current.position,to=plan.target}
end

-- The idle gate. Only the local player's own spawn state starts work (3
-- alive, 1 dead and queued, 2 pod pending, 0 before the first deployment);
-- teammates' deaths and beacons start nothing. Between deaths a check reads
-- the player manager global and that state: two reads, no allocation. The
-- manager's address is decoded as a number and compared with the last one;
-- the state's address (a pointer) is made once per manager, which the game
-- replaces per mission, and a new manager forgets the last state. The spawn
-- state, or nil and the waiting status; an invalid non-null pointer raises.
local HIGH = 4294967296
local function spawn_state(api, game, state)
    local global=state.manager_global
    if not global or state.manager_game~=game then
        global=game+PLAYER_MANAGER
        state.manager_global,state.manager_game=global,game
    end
    if not api.read_into(global,8,MANAGER) then return nil,'waiting_for_game_data:player_manager' end
    local low,high=u32(MANAGER,0),u32(MANAGER,4)
    if low==0 and high==0 then return nil,'waiting_for_game_data:player_manager' end
    local manager=low+high*HIGH
    if manager~=state.manager then
        local pm=api.pointer_at(MANAGER,0)
        if not pm then error('Invalid spawn data pointer: player_manager') end
        state.manager,state.spawn_address,state.spawn,state.landed=manager,pm+0x2E0,nil,nil
    end
    if not api.read_into(state.spawn_address,4,SPAWN) then return nil,'waiting_for_game_data:spawn_state' end
    return u32(SPAWN,0)
end

-- Waiting at the gate: no snapshot to compare against; alive (3) or before the
-- first deployment (0) ends any association, as the plan does.
local function wait(state, spawn)
    state.previous=nil
    if spawn==3 or spawn==0 then state.anchor,state.pending=nil,nil end
    return true,'waiting_for_reinforcement',false
end

-- What the plan compares the first full snapshot after the gate with, in place
-- of the alive snapshots no longer read: the same identity, local player,
-- player count and mode; the spawn state the gate saw last (so 0 -> 2, the
-- initial deployment, stays excluded); no beacons; the anchor rows of the last
-- solo landing, or nil. Nil when the gate saw no state before (a new player
-- manager or a fresh start) or only a queued or pending one: the plan then
-- starts afresh, as before.
local function baseline(current, last, landed)
    if last==nil or last==1 or last==2 then return nil end
    return {identity=current.identity,id=current.id,count=current.count,mode=current.mode,owned=current.owned,
        state=last,beacons={},automatic=landed,unobserved=true}
end

-- After a full check: while queued or pending the next check runs in full
-- again; otherwise it waits at the gate, keeping a solo snapshot's anchor rows
-- so the next death's baseline knows which rows are not new.
local function track(state, current)
    state.spawn=current.state
    if current.state==1 or current.state==2 then return end
    state.previous=nil
    state.landed=current.state and current.count==1 and current.automatic or nil
end

-- A reinforcement is in progress when the last full snapshot was queued or
-- pending: then every check is a full one (the snapshot reads the manager and
-- the state itself); otherwise it starts at the gate.
function patch.apply(api,game,exe,state)
    local previous=state.previous
    local tracking=previous~=nil and (previous.state==1 or previous.state==2)
    local last
    if not tracking then
        local spawn,waiting=spawn_state(api,game,state)
        if not spawn then forget(state);return true,waiting,false end
        last,state.spawn=state.spawn,spawn
        if spawn~=1 and spawn~=2 then return wait(state,spawn) end
    end
    local current,waiting=patch.snapshot(api,game,exe)
    if not current then forget(state);return true,waiting,false end
    if not tracking then state.previous=baseline(current,last,state.landed) end
    local plan,reason=patch.plan(current,state)
    track(state,current)
    if not plan then return true,reason,false end
    -- Re-read every identity and association immediately before the single write.
    local fresh,waiting=patch.snapshot(api,game,exe)
    if not fresh then forget(state);return true,waiting,false end
    if spawn_changed(current,fresh) then return true,'spawn_changed_before_write',false end
    if not beacon_kept(fresh,plan) then return true,'beacon_changed_before_write',false end
    write_correction(api,fresh,plan)
    record_correction(state,current,fresh,plan)
    return true,plan.kind..'_spawn_centered',true
end

-- Puts back the original XY of this mod's correction, only while the same
-- player manager's spawn is still pending and its XY still holds exactly the
-- bytes this mod wrote; anything else is left alone. Then forgets every
-- association, as when game data becomes unavailable (a fresh start).
-- Returns ok (false: the write failed) and the outcome.
function patch.restore(api,game,state)
    local pending=state.pending
    forget(state)
    if not (pending and pending.address and pending.original) then return true,'nothing_to_restore' end
    local pm=api.pointer(api.read(game+PLAYER_MANAGER,8))
    if not pm or pm+0x10C~=pending.address or api.read(pm+0x2E0,4)~=PENDING
        or api.read(pending.address,8)~=pending.bytes then
        return true,'correction_left_unchanged'
    end
    if not api.write(pending.address,pending.original) or api.read(pending.address,8)~=pending.original then
        return false,'correction_restore_failed'
    end
    return true,'correction_restored'
end

-- Machine code: as before these functions were split, or less. The snapshot
-- created its read helpers as closures on every call, which LuaJIT 2.1.0-alpha
-- does not compile, so its straight-line steps, patch.snapshot and patch.apply
-- never compiled, and the plan only its first check. The read helpers, the two
-- record loops and that check still compile; the steps below stay
-- interpreted. As the first call of beacon_records and automatic_anchors, the
-- manager steps keep a trace from starting at those functions' entries while
-- their loops compile. The solo source position compiled only inside a trace
-- after the anchor loop; its few steps now run interpreted around compiled
-- reads, no slower in the game's lua51.dll (offline); it now runs only when
-- an anchor is captured, through patch.source, also interpreted. The byte
-- decoders (u32, float, vector) replace the float cdata loads and string
-- slices they decoded from; they compile into the same reader traces. Nothing
-- is flushed. The idle gate's steps (spawn_state, wait, baseline, track) stay
-- interpreted too: the only code that runs between deaths adds no trace, and
-- the reader traces above now run only while a reinforcement is in progress.
if jit and jit.off then
    for _,fn in ipairs({session,local_player,beacon_managers,stratagem_rows,unit_position,source_position,snapshot,
        settle,patch.snapshot,patch.source,was_present,capture_anchor,spawn_blocked,used_before,newly_used,unmarked_remote,
        associated_beacon,placement,forget,spawn_state,wait,baseline,track,spawn_changed,beacon_kept,write_correction,
        record_correction,patch.apply}) do
        jit.off(fn)
    end
end
return patch

end)()
local install_loader = (function()
-- The mod's lifecycle on bingus_runtime.lua's update guard (the family's
-- update-chain policy):
-- - the earlier update runs outside pcall, so its errors reach the game unchanged;
-- - one check before the earlier update, and a second after it only while a
--   reinforcement is in progress;
-- - the reader refuses an unsupported layout, and a failed write stops the
--   correction, by raising: either stops the mod at once, as before; errors in
--   the mod's own code stop it after 8 in a burst;
-- - after an error in an update below this mod, the mod puts back a pending
--   correction that still holds its bytes and forgets every association: once the
--   updates below have returned on 60 frames in a row it checks again. 8 such
--   errors in a burst stop it, with its correction put back. The game quitting
--   writes nothing.
return function(create_api,patch,build,runtime)
    if rawget(_G,'ReinforcementBeaconFixData') then return end
    local state={revision=build.revision,active=false,corrections=0}
    rawset(_G,'ReinforcementBeaconFixData',state)
    local function report(status,active)
        state.active=active
        if state.status==status then return end
        state.status=status
        print('[ReinforcementBeaconsFixed] '..build.revision..': '..status)
        pcall(function()
            local logger=rawget(_G,'CowboyBingusModLoader')
            local file=logger and logger.open_log and logger.open_log('ReinforcementBeaconsFixed.log')
            if not file then return end
            file:write(build.revision..'\n'..status..'\ncorrections='..state.corrections..'\n')
            if state.last then
                file:write(string.format('%s beacon=%d from=%.6f,%.6f to=%.6f,%.6f association=%s\n',
                    state.last.kind,state.last.beacon,state.last.from[1],state.last.from[2],
                    state.last.to[1],state.last.to[2],state.last.association or 'used'))
            end
            file:close()
        end)
    end
    local ok,api,game,exe=pcall(function()
        local loader=rawget(_G,'CowboyBingusModLoader')
        assert(type(loader)=='table' and type(loader.api)=='number' and loader.api>=1,
            'Bingus Shared Loader API 1 or newer is required')
        assert(type(runtime)=='table' and type(runtime.guard)=='function','bingus_runtime.lua v1 is required')
        local api=create_api()
        local game,exe=api.module('game.dll'),api.module(nil)
        assert(game and exe,'Required modules unavailable')
        assert(api.module_hash(game)==build.game_sha256,'Unsupported game module')
        assert(api.module_hash(exe)==build.exe_sha256,'Unsupported executable')
        assert(type(update)=='function','Game update unavailable')
        return api,game,exe
    end)
    if not ok then report(tostring(api),false);return end
    report('waiting_for_reinforcement',false)
    local guard
    local function check()
        local called,accepted,reason,active=pcall(patch.apply,api,game,exe,state)
        if not called then return guard.stop(tostring(accepted)) end
        if not accepted then return guard.stop(tostring(reason)) end
        report(tostring(reason),active==true)
    end
    -- The second boundary only matters while a reinforcement is in progress:
    -- on the ship, while waiting for data or while alive, skip the repeat.
    local function after()
        local last=state.previous
        if last and last.owned and last.mode>=1 and last.mode<=7 and (last.state==1 or last.state==2) then
            check()
        end
    end
    -- Puts back a pending correction that still holds this mod's bytes and
    -- starts afresh; a failed write raises.
    local function restore()
        local restored,outcome=patch.restore(api,game,state)
        if outcome~='nothing_to_restore' then report(state.status..'; '..outcome,false) end
        if not restored then error(outcome,0) end
    end
    -- At shutdown nothing is written: the game is freeing its memory.
    local function stop(reason)
        if reason~='shutdown' then restore() end
    end
    local prefix='ReinforcementBeaconsFixed '
    local function log(line)
        if line:sub(1,#prefix)==prefix then line=line:sub(#prefix+1) end
        report(line,false)
    end
    local installed,problem=pcall(function()
        guard=runtime.guard({name='ReinforcementBeaconsFixed',step=check,after=after,stop=stop,
            pause=restore,log=log,env=_G}).install()
    end)
    if not installed then report(tostring(problem),false) end
end

end)()
local function create_runtime_api() return create_api(runtime, runtime_write.extend(runtime_memory.new(runtime))) end
install_loader(create_runtime_api, patch, {revision = 'data-v4.6.1-26088801', exe_sha256 = '0ACC07DEBE04714AE04281E1A66BD2EB9D3D85232953E32A93C8A3DD0874EABE', game_sha256 = '6D1D4D3BC6FC84801D9F8F1B310E13A603D07409F3D9495D74B42E1D0BB1C08F'}, runtime)
