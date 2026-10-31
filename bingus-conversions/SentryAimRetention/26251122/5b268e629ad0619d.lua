-- HD2-Addon: mods/cowboybingus/sentry_aim_retention
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
-- The Windows adapter. Reads, protection checks, writes, modules, their
-- SHA-256, the build check and the clock come from Bingus Shared Runtime v1:
-- memory is bingus_memory.lua's api extended by bingus_write.lua (private FFI
-- names; module hashes are read once per session for every mod). The write
-- into a range verified earlier in the same check, the terrain query and the
-- native sentry calls stay here. runtime (bingus_runtime.lua) is the core the
-- loader takes its guard from.
return function(runtime, memory)
    local ffi, bit = require('ffi'), require('bit')
    local kernel = memory.windows.kernel32
    local write_memory = assert(kernel.WriteProcessMemory, 'The memory api needs bingus_write.lua')
    -- Private names, declared once per game: ffi.cdef keeps the first
    -- declaration of a name for the whole game, so plain names could bind to
    -- another mod's. The game functions api.bind calls get named
    -- function-pointer types: each parse of a function-pointer type string
    -- adds C types (35 per bind) to the table every mod shares, which is never
    -- freed; a typedef name adds none, and neither does a declaration skipped
    -- here.
    if not pcall(ffi.typeof, 'sentry_aim_raycast_fn') then
        ffi.cdef [[
            typedef void (*sentry_aim_retention_fn)(void *, uint32_t, uint32_t, uint8_t);
            typedef void (*sentry_aim_speed_fn)(void *, float);
            typedef void (*sentry_aim_fire_mode_fn)(void *, uint32_t, uint32_t);
            typedef uint32_t (*sentry_aim_world_id_fn)(const void *);
            typedef uint32_t (*sentry_aim_raycast_fn)(uint32_t, const void *, const void *, float, uint32_t,
                uint32_t, uint32_t, uint32_t, uint32_t, void *, uint32_t);
        ]]
    end
    -- The routine the turret speed setters end with (network id, field hash,
    -- field address), declared on its own: a block above declared by another
    -- copy of this file would not have it.
    if not pcall(ffi.typeof, 'sentry_aim_replicate_fn') then
        ffi.cdef [[ typedef void (*sentry_aim_replicate_fn)(uint32_t, uint32_t, void *); ]]
    end
    -- time: seconds as a Lua number from the performance counter, read without
    -- allocating (the 64-bit tick count this adapter read before was boxed,
    -- 16 bytes per call in interpreted code). Still one call per check once a
    -- sentry has been seen (pinned in tests/test_snapshot.lua).
    local api = {read = memory.read, read_into = memory.read_into, pointer = memory.pointer,
        address = memory.address, distance = memory.distance, writable_data = memory.writable_data, module = memory.module,
        module_hash = memory.module_hash, verify_build = memory.verify_build, time = memory.time}

    -- checked: the caller verified [address, address + #bytes) with
    -- writable_data earlier in the same check, so the write does not repeat
    -- that query (about 0.29 ms in game). Otherwise memory.write checks its
    -- range. The runtime's write always checks, so this write without a check
    -- stays here, through the WriteProcessMemory bingus_write.lua bound.
    local process, done = kernel.GetCurrentProcess(), ffi.new('size_t[1]')
    local done32 = ffi.cast('uint32_t *', done)
    function api.write(address, bytes, checked)
        if not checked then return memory.write(address, bytes) end
        return write_memory(process, address, bytes, #bytes, done) ~= 0 and done32[0] == #bytes
    end
    -- The ray from origin to target: its start, unit direction and length, or
    -- nil when the points lie within 5 cm of each other.
    -- Reused ray buffers: a query allocates no buffer (one query at a time; the
    -- game runs this Lua on one thread).
    local from,to,dir=ffi.new('float[3]'),ffi.new('float[3]'),ffi.new('float[3]')
    local outputs={}
    local function terrain_ray(origin,target)
        assert(#origin==12 and #target==12,'Invalid terrain ray points')
        ffi.copy(from,origin,12);ffi.copy(to,target,12)
        local length=0
        for i=0,2 do
            local delta=tonumber(to[i]-from[i])
            assert(delta==delta and math.abs(delta)<100000,'Invalid terrain ray')
            dir[i]=delta;length=length+delta*delta
        end
        length=math.sqrt(length)
        if length<0.05 then return nil end
        assert(length<2000,'Terrain ray outside sentry range')
        for i=0,2 do dir[i]=dir[i]/length end
        return from,dir,length
    end
    -- Do not ignore the entire unit or stop at its first surface: solid
    -- terrain can sit behind a fence, including within the same unit.
    local function behind_cover(query,classify)
        local capacity=32
        local out,count=query(2,capacity)
        local nearest,cover
        for i=0,math.min(count,capacity)-1 do
            local solid,hit=classify(out,i)
            if solid and (not nearest or hit.distance<nearest.distance) then nearest=hit end
            if hit.reason=='destructible_cover' then cover=cover or hit end
        end
        if nearest then return true,nearest end
        -- A truncated result cannot establish obstruction. Leave that case to
        -- native ballistics instead of latching an unproven permanent pause.
        if count>capacity then return false,{reason='cover_query_limit',hits=count} end
        return false,cover or {reason='clear'}
    end
    -- Private-buffer adapter, also exercised with a synthetic terrain query.
    function api.cast_terrain(raycast,id,unit,origin,target,target_unit,actor_filter)
        local from,dir,length=terrain_ray(origin,target)
        if not from then return false end
        assert(id>=0 and id<4,'Invalid physics world')
        -- Match the native static-obstacle preset: closest collection, actor
        -- class 3, damage filter and flags 0x80000009. The native filter admits
        -- only bodies with the static bit. Character/ragdoll volumes, including
        -- initial overlaps around the muzzle, must not act as a firing veto.
        local function query(collection,capacity)
            local out=outputs[capacity]
            if not out then out=ffi.new('uint32_t[?]',11*capacity);outputs[capacity]=out end
            -- Nothing of an earlier query may read as a hit of this one.
            ffi.fill(out,44*capacity)
            local count=tonumber(raycast(id,from,dir,length,collection,3,0x393d9518,0x80000009,unit,out,capacity))
            assert(count and count>=0 and count==math.floor(count),'Invalid terrain hit count')
            return out,count
        end
        local function classify(out,index)
            local hit=out+11*index
            local distance=tonumber(ffi.cast('float *',hit)[6])
            assert(distance==distance and distance>=0 and distance<=length+0.05,'Invalid terrain hit')
            local hit_unit,actor=tonumber(hit[7]),tonumber(hit[8])
            local detail={hit_unit=hit_unit,hit_actor=actor,target_unit=target_unit,distance=distance,length=length}
            if target_unit and hit_unit==target_unit then detail.reason='target_surface';return false,detail end
            -- A surface endpoint is legal; only geometry before it can veto.
            if distance>=length-0.05 then detail.reason='endpoint';return false,detail end
            detail.filter=actor_filter and actor_filter(actor,hit_unit) or nil
            if detail.filter==0x04a8fbf9 then
                -- Native destructible cover includes fences. A collision here
                -- does not prove that the weapon cannot penetrate/destroy it.
                detail.reason='destructible_cover';return false,detail
            end
            detail.reason='static_obstruction';return true,detail
        end
        local out,count=query(1,1)
        if count==0 then return false,{reason='clear'} end
        local blocked,detail=classify(out,0)
        if detail.reason~='destructible_cover' then return blocked,detail end
        return behind_cover(query,classify)
    end
    -- The native actor/body mapping. Never dereference an unchecked actor handle
    -- or infer cover type from a recycled body index.
    -- The uint32 at byte offset o of b, or nil without b.
    local function word_at(b,o)
        if not b then return nil end
        local v=ffi.new('uint32_t[1]');ffi.copy(v,b:sub(o+1,o+4),4);return tonumber(v[0])
    end
    local function read_pointer(a)return api.pointer(api.read(a,8))end
    -- The actor's pool header, entry and collision record, or nil unless the
    -- handle resolves to this unit.
    local function actor_entry(exe,actor,unit)
        local world_index=math.floor(actor/0x40000000)
        local pool=exe+0x2411200+64*(math.floor(actor/0x10000000)%4+10*world_index)
        local h=api.read(pool,56);if not h then return nil end
        local layout=word_at(h,28);local stride=layout%65536
        local identity=math.floor(layout/65536)%256;local offset=math.floor(layout/0x1000000)
        local index=bit.band(actor,word_at(h,40));local base=api.pointer(h)
        if not base or index<0 or index>=word_at(h,36) or bit.band(actor,word_at(h,52))==0
            or stride<40 or stride>512 or identity+4>stride or offset+40>stride then return nil end
        local entry=base+index*stride;local key=api.read(entry+identity,4)
        if word_at(key,0)~=actor then return nil end
        local record=api.read(entry+offset,40)
        if not record or word_at(record,12)~=unit then return nil end
        return {world_index=world_index,pool=pool,h=h,entry=entry,identity=identity,offset=offset,key=key,
            record=record}
    end
    -- The actor's physics body, checked against the actor and the unit.
    local function actor_body(exe,e,actor,unit)
        local world_slot=exe+0x2861d88+176*e.world_index;local world=read_pointer(world_slot)
        if not world then return false end
        local bodies=read_pointer(world+24);local body_index=bit.band(word_at(e.record,20),0xffffff)
        if not bodies or body_index>=262144 then return false end
        local address=bodies+160*body_index;local body=api.read(address,160)
        if not body or word_at(body,144)~=actor or word_at(body,148)~=unit then return false end
        e.world_slot,e.world,e.bodies,e.address,e.body=world_slot,world,bodies,address,body
        return true
    end
    -- The body's collision filter: true and its name word, or nil without a
    -- valid property table.
    local function filter_name(exe,e)
        local properties=read_pointer(exe+0x286d338);if not properties then return nil end
        local count=word_at(api.read(properties+248,4),0);local names=read_pointer(properties+256)
        local filter=bit.band(word_at(e.body,108),127)
        if not count or count>128 or filter>=count or not names then return nil end
        e.properties,e.count,e.names,e.filter=properties,count,names,filter
        return true,api.read(names+4*filter,4)
    end
    -- Every link read again: an actor, body or table that changed meanwhile
    -- gives no filter.
    local function unchanged(exe,e,name)
        return api.read(e.pool,56)==e.h and api.read(e.entry+e.identity,4)==e.key
            and api.read(e.entry+e.offset,40)==e.record and read_pointer(e.world_slot)==e.world
            and read_pointer(e.world+24)==e.bodies and api.read(e.address,160)==e.body
            and read_pointer(exe+0x286d338)==e.properties and read_pointer(e.properties+256)==e.names
            and word_at(api.read(e.properties+248,4),0)==e.count and api.read(e.names+4*e.filter,4)==name
    end
    function api.actor_filter(exe,actor,unit)
        local e=actor_entry(exe,actor,unit)
        if not e or not actor_body(exe,e,actor,unit) then return nil end
        local named,name=filter_name(exe,e)
        if not named or not unchanged(exe,e,name) then return nil end
        return word_at(name,0)
    end
    -- Once per session: aim_data keeps the bound natives (across a pause too).
    function api.bind(game,exe)
        -- Signatures and entity/record identity are checked before each call.
        local flag = ffi.cast('sentry_aim_retention_fn',game+0x6c9a50)
        local replicate = ffi.cast('sentry_aim_replicate_fn',game+0xe69780)
        local mode = ffi.cast('sentry_aim_fire_mode_fn',game+0x761700)
        local world_id = ffi.cast('sentry_aim_world_id_fn',exe+0x826bc0)
        local raycast = ffi.cast('sentry_aim_raycast_fn',exe+0x87bb20)
        local function ptr(address)
            return assert(api.pointer(api.read(address,8)),'Pose pointer unavailable')
        end
        -- Reused buffers: a word or the job table is read without allocating.
        local word,jobs=ffi.new('uint32_t[1]'),ffi.new('uint32_t[72]')
        local function uint(address)
            assert(api.read_into(address,4,word),'Pose metadata unavailable')
            return tonumber(word[0])
        end
        -- The path from the unit table to a unit's object, checked in full; the
        -- object's pose code is checked here, once per path.
        local poses,pose_count={},0
        local function locate_pose(units,unit)
            local index=unit%0x400000
            assert(index<uint(units+0x98),'Unit index unavailable')
            local generations=ptr(units+0xa0)
            local generation=string.char(math.floor(unit/0x400000)%256)
            assert(api.read(generations+index,1)==generation,'Unit generation changed')
            local slot=ptr(units+0x88)+8*index;local object=ptr(slot)
            assert(uint(object+8)==unit,'Fire node unavailable')
            assert(api.read(ptr(ptr(object)+0xe8),5)=='\x48\x8d\x41\x60\xc3','Unsupported pose layout')
            return {units=units,index=index,generations=generations,generation=generation,slot=slot,
                object=object,nodes=uint(object+0x70)}
        end
        -- The turret speed setters' work (game.dll 0x105cff0 horizontal,
        -- 0x105cf00 vertical), which the game never runs in play, so their
        -- code cannot be checked: the entity's id (+8), nothing for the
        -- invalid id; its slot in the turret registry's id map; nothing unless
        -- this machine owns the registry's entity (+0x14 bit 0); the speed into
        -- its control record (+8 horizontal, +12 vertical); then the field is
        -- queued for replication under its hash with the entity's network id
        -- (+0x10). The write checks its range first; only a write that landed
        -- is replicated. The registry's entity must be the one given.
        local speed_bits=ffi.new('float[1]')
        local function set_speed(entity,speed,offset,hash)
            local id=word_at(api.read(entity+8,4),0)
            assert(id,'Turret entity unavailable')
            if id==word_at(api.read(game+0x2e3f0d0,4),0) then return end
            local manager=read_pointer(game+0x2ce1f30)
            local h=manager and api.read(manager+0x28,20)
            local count=manager and word_at(api.read(manager+0x14,4),0)
            assert(h and count,'Turret registry unavailable')
            local slots,capacity,empty,multiplier=api.pointer(h),word_at(h,8),word_at(h,12),word_at(h,16)
            if capacity==0 then return end
            assert(slots and capacity<=8192 and bit.band(capacity,capacity-1)==0,'Unsupported turret registry')
            local start=tonumber(ffi.cast('uint32_t',ffi.new('uint64_t',id)*multiplier))
            local index
            for probe=0,math.min(capacity,128)-1 do
                local slot=api.read(slots+8*bit.band(start+probe,capacity-1),8)
                assert(slot,'Turret registry unavailable')
                if word_at(slot,0)==id then index=word_at(slot,4);break end
                if word_at(slot,0)==empty then return end
            end
            assert(index,'Entity map probe bound exceeded')
            if index==0xffffffff then return end
            assert(index<count,'Component index out of range')
            local records,controls=read_pointer(manager+0x40),read_pointer(manager+0x58)
            local record=records and read_pointer(records+8*index)
            assert(record and controls,'Turret registry unavailable')
            assert(api.address(record)==api.address(entity),'Component identity mismatch')
            local flags,network=api.read(record+0x14,1),word_at(api.read(record+0x10,4),0)
            assert(flags and network,'Turret entity unavailable')
            if bit.band(flags:byte(1),1)==0 then return end
            local field=controls+16*index+offset
            speed_bits[0]=speed;local bytes=ffi.string(speed_bits,4)
            if not api.write(field,bytes) or api.read(field,4)~=bytes then return end
            replicate(network,hash,field)
        end
        return {
            retention=function(id,enabled) flag(nil,id,2,enabled and 1 or 0) end,
            horizontal=function(entity,speed) set_speed(entity,speed,8,0xcc0b45e5) end,
            vertical=function(entity,speed) set_speed(entity,speed,12,0x9d5d6cc7) end,
            fire_mode=function(manager,id,value) mode(manager,id,value) end,
            terrain_path=function(unit,origin,target,target_unit)
                -- The native ray workers use this scheduler. Query only after
                -- consumption, using private inputs/output; never enqueue work.
                local scheduler=api.pointer(api.read(game+0x2e38988,8))
                local world=api.pointer(api.read(game+0x2e271f8,8))
                if not scheduler or not world or uint(scheduler)~=0 then return nil end
                if not api.read_into(scheduler+0x40008,288,jobs) then return nil end
                for i=0,23 do if jobs[3*i+2]~=1 then return nil end end
                -- The raycast reads this world's physics scene from its slot
                -- (exe+0x2861d70, 0xb0 apart) without a check; the slot can be
                -- empty while the world is listed (crash 2026-10-30 23:11).
                local id=tonumber(world_id(world))
                if id<4 and not api.pointer(api.read(exe+0x2861d70+0xb0*id,8)) then return nil end
                return api.cast_terrain(raycast,id,unit,origin,target,target_unit,
                    function(actor,owner)return api.actor_filter(exe,actor,owner)end)
            end,
            pose=function(unit,node)
                -- Read the same matrix selected by UnitApi.world_pose, without
                -- invoking an engine virtual function on a possibly stale unit.
                -- The path to the unit's object is kept per unit while the unit
                -- table, the unit's generation, its slot and the object's unit
                -- id stay the same.
                local units=ptr(exe+0x1ab76f8)
                local p=poses[unit]
                if not (p and p.units==units and api.read(p.generations+p.index,1)==p.generation
                    and ptr(p.slot)==p.object and uint(p.object+8)==unit) then
                    p=locate_pose(units,unit);poses[unit]=p;pose_count=pose_count+1
                    -- Bounded: units are recycled, so a long session forgets old paths.
                    if pose_count>64 then poses={[unit]=p};pose_count=1 end
                end
                assert(node<p.nodes,'Fire node unavailable')
                local matrix=api.read(ptr(p.object+0x88)+64*node,64)
                assert(api.read(p.generations+p.index,1)==p.generation,'Pose identity changed')
                return matrix
            end,
        }
    end
    return api
end

end)()
local patch = (function()
local ffi,bit=require('ffi'),require('bit')
local M={}
local ZERO=string.rep('\0',4)
-- Four-byte little-endian fields decode from the string's bytes: no cdata, no
-- substring and no type punning per field. A field must lie inside b.
local function u(b,o)
    local b1,b2,b3,b4=b:byte(o+1,o+4)
    assert(b4,'Field outside the bytes read')
    return b1+b2*256+b3*65536+b4*16777216
end
-- IEEE 754 single precision, exactly (subnormals, infinities and NaN included).
local function f(b,o)
    local b1,b2,b3,b4=b:byte(o+1,o+4)
    assert(b4,'Field outside the bytes read')
    local sign=b4>=128 and -1 or 1
    local exponent=(b4%128)*2+math.floor(b3/128)
    local mantissa=((b3%128)*256+b2)*256+b1
    if exponent==255 then return mantissa==0 and sign*math.huge or 0/0 end
    if exponent==0 then return sign*math.ldexp(mantissa,-149) end
    return sign*math.ldexp(mantissa+8388608,exponent-150)
end
local function word(n) return ffi.string(ffi.new('uint32_t[1]',n),4) end
local function ticks(b)
    local v=ffi.new('uint64_t[1]');ffi.copy(v,b,8);return tonumber(v[0])
end
local function tickword(n) return ffi.string(ffi.new('uint64_t[1]',n),8) end
local function finite(n) return n==n and math.abs(n)<100000 end
local function vector(b)
    return b and #b==12 and finite(f(b,0)) and finite(f(b,4)) and finite(f(b,8))
end
local function nonzero(b) return f(b,0)~=0 or f(b,4)~=0 or f(b,8)~=0 end
local function fromhex(h) return (h:gsub('..',function(p)return string.char(tonumber(p,16))end)) end
-- Resource identity and BehaviorComponent defaults from this build's data.
local profiles={
    [fromhex('701de358cfd685ef')]={name='Gatling',behavior=214,fire_gate={pause=16,resume=4}},
    [fromhex('bb26ba7638e4cd37')]={name='Machine gun',behavior=313,fire_gate={pause=14,resume=3}},
    [fromhex('a8a8ffcf360f0756')]={name='Laser cannon',behavior=309},
    [fromhex('c6e986dc68950737')]={name='Rocket',behavior=611},
    [fromhex('582896febac30c82')]={name='Flamethrower',behavior=208},
    [fromhex('742dce3b2e81a051')]={name='Mortar',behavior=320},
    [fromhex('8b2f0938183a05b2')]={name='EMS mortar',behavior=324},
}
-- EMS mortar uses the same mechanism, with its own resource/profile identity.
M.profiles=profiles
local signatures={
    {0x6c9a50,'405741574883ec283b1572567702450fb6f94c8b15878461'},
    -- Build 26088801 never runs its two turret speed setters (0x105cf00,
    -- 0x105cff0) in play: their code pages stay unreadable, so their bytes can
    -- never be checked. api.bind does their work itself and calls only the
    -- routine they end with, which queues the field for replication; it is
    -- checked here in full (221 bytes, through its ret).
    {0xe69780,'48896c241856415641574883ec30488b0523aae7014d8bf0448bfa8be9488b700880be1d300000000f85a000000048897c2458488b7e1081f9ff7f00000f84860000004c8b0dfe7ce70148895c2450498b4140488b9868010000498b4138ff5008488bc88bd5ffd385c07e588b074803c0896c242044897c24244c897424280f104424200f1144c7088b07ffc0890780be1c3000000074073d000800007525488b1e488b05777de701488bcbff5070488bd7e8294c0000488b05627de701488bcbff5078488b5c2450488b7c2458488b6c24604883c430415f415e5ec3'},
    {0x761700,'48894c24085355565741574883ec20'},
}
M.signatures=signatures
-- The field decoders, for the tests.
M.fields={u=u,f=f}
local function matches(api,guards)
    for _,g in ipairs(guards) do
        if api.read(g.address,#g.bytes)~=g.bytes then return false end
    end
    return true
end

-- Reads that must succeed in full, and pointers that must be user-mode.
local function need(api,a,n)
    local b=api.read(a,n);assert(b and #b==n,'Runtime read unavailable');return b
end
local function into(api,a,n,buffer)
    assert(api.read_into(a,n,buffer),'Runtime read unavailable')
end
local function need_pointer(api,b)
    return assert(api.pointer(b),'Runtime pointer unavailable')
end
local NULL=string.rep('\0',8)

-- Guards and windows ------------------------------------------------------------
-- A guard holds bytes that must still be at its address. at is that address as
-- a number: a guard inside memory this check already read (a window) is
-- compared with those bytes instead of being read again.
local function number_of(api,p) if type(p)=='number' then return p end return api.address(p) end
local function guard(api,list,address,bytes)
    list[#list+1]={address=address,bytes=bytes,at=number_of(api,address)}
end
-- Records bytes read at address as window windows.n (window tables are reused).
local function window(api,windows,address,bytes)
    local n=windows.n+1;windows.n=n
    local w=windows[n];if not w then w={};windows[n]=w end
    w.at=number_of(api,address);w.bytes=bytes
    return bytes
end
-- true or false when a window holds the guard's range, nil otherwise.
local function covered(windows,g)
    for k=1,windows.n do
        local w=windows[k];local o=g.at-w.at
        if o>=0 and o+#g.bytes<=#w.bytes then return w.bytes:sub(o+1,o+#g.bytes)==g.bytes end
    end
end
-- Whether every guard still holds; only those outside the windows are read.
local function verified(api,guards,windows)
    for k=1,#guards do
        local g=guards[k];local same=covered(windows,g)
        if same==nil then same=api.read(g.address,#g.bytes)==g.bytes end
        if not same then return false end
    end
    return true
end

-- Cold resolution: registries, maps and components -------------------------------
-- An entity's index in a native hash map, or nil when absent. On a hit the map
-- header and the slot become guards.
local function lookup(api,manager,off,id,limit,guards)
    local h=need(api,manager+off,20);local c=u(h,8)
    if c==0 then return nil end
    assert(c<=limit and bit.band(c,c-1)==0,'Unsupported entity map')
    local data=need_pointer(api,h:sub(1,8));local empty,mul=u(h,12),u(h,16)
    local product=ffi.new('uint64_t',id)*ffi.new('uint64_t',mul)
    for probe=0,math.min(c,128)-1 do
        local slot=bit.band(tonumber(ffi.cast('uint32_t',product))+probe,c-1)
        local address=data+slot*8;local row=need(api,address,8)
        if u(row,0)==id then
            guard(api,guards,manager+off,h);guard(api,guards,address,row)
            return u(row,4)
        end
        if u(row,0)==empty then return nil end
    end
    error('Entity map probe bound exceeded')
end
-- A component's address and bytes in a native array of stride-byte entries;
-- the array pointer becomes a guard.
local function component(api,manager,off,index,stride,size,guards)
    local b=need(api,manager+off,8);local p=need_pointer(api,b)
    guard(api,guards,manager+off,b)
    return p+index*stride,need(api,p+index*stride,size)
end
-- The check decodes the targeting root, header and pointer chunks in place
-- (targeting). Only a sentry needs them as strings: its guards are verified
-- against the windows, and its registries come from the header. Built at most
-- once per check, when the first sentry needs them; unchanged bytes give the
-- interned strings of earlier checks (no allocation).
local function materialize(api,c)
    if c.strings then return end
    c.strings=true
    local w,b,k,reg=c.windows,c.buf,c.kept,c.reg
    window(api,w,c.at.tm,k.tmb)
    reg.th=window(api,w,k.th,ffi.string(b.head8,84))
    for n=0,reg.chunks do window(api,w,c.chunk_at[n],ffi.string(b.chunk8[n],b.chunk_size[n])) end
end
-- The behavior and turret registries of this check (read once per check, only
-- when a sentry needs them), or nil while a root is empty.
local function components(api,game,c)
    materialize(api,c)
    local reg=c.reg
    if reg.bm~=nil then return reg.bm and reg end
    local w,at=c.windows,c.at
    local bmb=window(api,w,at.bm,need(api,at.bm,8))
    local rmb=window(api,w,at.rm,need(api,at.rm,8))
    if bmb==NULL or rmb==NULL then reg.bm=false;return nil end
    -- Pointers and the addresses made from them are kept while their bytes are
    -- unchanged: no new pointer value per check.
    local k=c.kept
    if bmb~=k.bmb then k.bmb,k.bm=bmb,need_pointer(api,bmb);k.bh=k.bm+32 end
    if rmb~=k.rmb then k.rmb,k.rm=rmb,need_pointer(api,rmb);k.rh=k.rm+8 end
    local rh=window(api,w,k.rh,need(api,k.rh,88));local bh=window(api,w,k.bh,need(api,k.bh,80))
    assert(u(rh,16)<=u(rh,12) and u(rh,12)<=u(rh,0) and u(rh,0)<=4096,'Unsupported turret registry')
    assert(u(bh,0)<=16384,'Unsupported behavior registry')
    reg.bm,reg.rm,reg.bmb,reg.rmb,reg.rh,reg.bh=k.bm,k.rm,bmb,rmb,rh,bh
    local rtb,ntb=reg.th:sub(69,76),reg.th:sub(77,84)
    if rtb~=k.rtb then k.rtb,k.rt=rtb,need_pointer(api,rtb) end
    if ntb~=k.ntb then k.ntb,k.nt=ntb,need_pointer(api,ntb) end
    reg.rt,reg.nt=k.rt,k.nt
    return reg
end
-- The roots, the registry's array pointers, the entity pointer and the
-- entity's identity bytes. The authority byte is checked on every check.
local function entity_guards(api,game,reg,e)
    local guards={}
    for _,g in ipairs({{game+0x2ce1ef0,reg.tmb},{game+0x2ce18f0,reg.bmb},{game+0x2ce1f30,reg.rmb},
        {reg.tm+360,reg.th:sub(53,60)},{reg.tm+376,reg.th:sub(69,76)},{reg.tm+384,reg.th:sub(77,84)},
        {reg.ep+8*e.index,e.pointer},{e.address,e.key}}) do
        guard(api,guards,g[1],g[2])
    end
    return guards
end
-- The target's unit, so its collision surface is not mistaken for terrain. Its
-- guard is the target entity's identity; target removal must never prevent
-- restoring a sentry, so it stays apart from the sentry's guards.
local function locate_target(api,game,id)
    local scratch={}
    local fm=need_pointer(api,need(api,game+0x2ce1e78,8))
    local fi=lookup(api,fm,73808,id,131072,scratch)
    if not fi or fi==0xffffffff then return nil end
    assert(fi<16384,'Target faction index out of range')
    local slot=need_pointer(api,need(api,fm+73832,8))+8*fi
    local address=need_pointer(api,need(api,slot,8));local target=need(api,address,20)
    assert(u(target,8)==id,'Target identity changed')
    local guards={};guard(api,guards,address,target)
    return {id=id,unit=u(target,12),guards=guards}
end
-- The firing layout of a Gatling or machine gun: weapon and trigger slots, the
-- fire nodes, the native selection clock and their guards.
local function locate_fire(api,game,e)
    local clock_root=need(api,game+0x2ce14f8,8)
    local selection_guards={};guard(api,selection_guards,game+0x2ce14f8,clock_root)
    local wm=need_pointer(api,need(api,game+0x2ce1ea0,8))
    local guards={}
    local wi=lookup(api,wm,48,e.id,32768,guards)
    assert(wi and wi~=0xffffffff and wi<16384,'Weapon data unavailable')
    local _,we=component(api,wm,72,wi,8,8,guards)
    assert(we==e.pointer,'Weapon identity mismatch')
    local wr,record=component(api,wm,88,wi,1008,228,guards)
    local mode_address=component(api,wm,96,wi,12,12,guards)
    local count=u(record,216)
    assert(count>0 and count<=24,'Invalid sentry fire nodes')
    local nodes={}
    for i=0,count-1 do nodes[i]=u(record,120+4*i) end
    guard(api,guards,game+0x2ce1ea0,need(api,game+0x2ce1ea0,8))
    local cmb=need(api,game+0x2ce1810,8);local cm=need_pointer(api,cmb)
    guard(api,guards,game+0x2ce1810,cmb)
    local ci=lookup(api,cm,40,e.id,32768,guards)
    assert(ci and ci~=0xffffffff and ci<16384,'Weapon trigger unavailable')
    -- The trigger array and its manager are guards too: the trigger's address is kept.
    local triggers=need(api,cm+88,8);guard(api,guards,cm+88,triggers)
    return {wm=wm,cm=cm,wm_header=wm+48,cm_header=cm+40,clock_root_address=game+0x2ce14f8,
        guards=guards,selection_guards=selection_guards,clock_root=clock_root,
        clock_address=need_pointer(api,clock_root)+24,node_address=wr+216,nodes=nodes,count=count,
        mode_address=mode_address,trigger_address=need_pointer(api,triggers)+ci,
        index=ffi.new('uint32_t[2]'),network=ffi.new('uint32_t[3]'),trigger=ffi.new('uint8_t[1]'),
        clock=ffi.new('uint32_t[2]')}
end
-- The layout of a locally authoritative sentry whose three map entries agree,
-- or nil: addresses and indices that stay put while its guards hold, reused
-- read buffers and the row the checks refresh in place.
local function locate(api,game,reg,e)
    local guards=entity_guards(api,game,reg,e)
    local ti=lookup(api,reg.tm,336,e.id,16384,guards)
    local bi=lookup(api,reg.bm,64,e.id,32768,guards)
    local ri=lookup(api,reg.rm,40,e.id,8192,guards)
    if ti~=e.index or not bi or not ri or bi==0xffffffff or ri==0xffffffff then return nil end
    assert(bi<u(reg.bh,0) and ri<u(reg.rh,12),'Component index out of range')
    local _,be=component(api,reg.bm,88,bi,8,8,guards)
    local _,re=component(api,reg.rm,64,ri,8,8,guards)
    assert(be==e.pointer and re==e.pointer,'Component identity mismatch')
    local ba=component(api,reg.bm,96,bi,504,160,guards)
    local ca=component(api,reg.rm,88,ri,16,16,guards)
    local i=e.index
    local L={index=i,pointer=e.pointer,address=e.address,key=e.key,guards=guards,profile=e.profile,
        behavior_address=ba,control_address=ca,runtime_address=reg.rt+208*i,network_address=reg.nt+24*i,
        behavior=ffi.new('uint32_t[40]'),control=ffi.new('uint32_t[4]'),runtime=ffi.new('uint32_t[8]'),
        network=ffi.new('uint32_t[6]')}
    L.bytes={behavior=ffi.cast('uint8_t *',L.behavior),control=ffi.cast('uint8_t *',L.control),
        runtime=ffi.cast('uint8_t *',L.runtime)}
    L.floats={behavior=ffi.cast('float *',L.behavior),control=ffi.cast('float *',L.control),
        runtime=ffi.cast('float *',L.runtime)}
    L.at={point=L.bytes.behavior+28,deadline=L.bytes.behavior+152,raw=L.bytes.runtime+8,
        computed=L.bytes.runtime+20,horizontal=L.bytes.control+8,vertical=L.bytes.control+12,
        node=L.bytes.behavior+8,target=L.bytes.behavior+24,source=L.bytes.behavior+96,has=L.bytes.behavior+120}
    local transition={}
    for _,o in ipairs({{8,4},{24,4},{96,4},{120,1}}) do guard(api,transition,ba+o[1],string.rep('\0',o[2])) end
    L.row={id=e.id,key=e.key,entity=e.address,guards=guards,transition_guards=transition,
        profile=e.profile.name,behavior_address=ba,transition_address=ba+8,authority_address=e.address+20,
        raw_address=L.runtime_address+8,computed_address=L.runtime_address+20,
        flags_address=L.network_address+16,control_address=ca}
    if e.profile.fire_gate then
        L.fire=locate_fire(api,game,e)
        L.row.selection={address=ba+152,guards=L.fire.selection_guards}
        L.row.fire={manager=L.fire.wm,mode_address=L.fire.mode_address,guards=L.fire.guards,
            unit=u(e.bytes,12),pause=e.profile.fire_gate.pause,resume=e.profile.fire_gate.resume}
    end
    return L
end

-- Refresh: the live fields of a located sentry ----------------------------------
local function check_components(L)
    local b,c,bf,cf,rf=L.bytes.behavior,L.bytes.control,L.floats.behavior,L.floats.control,L.floats.runtime
    assert(L.behavior[0]==L.profile.behavior,'Unsupported sentry behavior')
    assert(b[120]<=1 and c[0]<=1,'Unsupported component flags')
    assert(finite(rf[2]) and finite(rf[3]) and finite(rf[4]) and finite(rf[5]) and finite(rf[6])
        and finite(rf[7]) and finite(bf[7]) and finite(bf[8]) and finite(bf[9]),'Invalid aim vector')
    assert(finite(cf[2]) and cf[2]>=0 and cf[2]<=1000 and finite(cf[3]) and cf[3]>=0 and cf[3]<=1000,
        'Invalid turret speeds')
end
-- The fire fields: node, mode, trigger and the selection clock. False when the
-- weapon or trigger moved (the sentry is located again).
local function refresh_fire(api,game,L,s,windows)
    local F=L.fire
    -- The weapon and trigger map headers and arrays, one read each; a manager
    -- that is gone reads as moved.
    local wh,ch=api.read(F.wm_header,56),api.read(F.cm_header,56)
    if not wh or not ch then return false end
    window(api,windows,F.wm_header,wh);window(api,windows,F.cm_header,ch)
    if not verified(api,F.guards,windows) then return false end
    if need(api,F.clock_root_address,8)~=F.clock_root then return false end
    into(api,F.node_address,8,F.index)
    local count,index=F.index[0],F.index[1]
    assert(count==F.count and index<count,'Invalid sentry fire nodes')
    into(api,F.mode_address,12,F.network);into(api,F.trigger_address,1,F.trigger)
    into(api,F.clock_address,8,F.clock)
    local node=F.nodes[index]
    assert(node<1024 and F.network[0]<=8,'Invalid sentry weapon state')
    assert(F.trigger[0]<=1,'Invalid sentry trigger')
    local fire=s.fire
    fire.node,fire.mode,fire.trigger=node,F.network[0],F.trigger[0]==1
    fire.target_unit,fire.target_guards,fire.pose,fire.terrain_blocked,fire.query=nil,nil,nil,nil,nil
    s.selection.deadline=ffi.string(L.at.deadline,8)
    s.selection.now=F.clock[0]+F.clock[1]*4294967296
    -- The target is located once per target; prepare_fire checks its guard
    -- around the terrain query and marks it stale when it no longer holds.
    if fire.target_stale then L.target=nil;fire.target_stale=nil end
    if s.target~=0 and s.runtime_target==s.target then
        local T=L.target
        if not (T and T.id==s.target) then T=locate_target(api,game,s.target);L.target=T end
        if T then fire.target_unit,fire.target_guards=T.unit,T.guards end
    end
    return true
end
-- Reads the live components into the sentry's buffers and decodes its row.
-- Unchanged string fields are interned strings: they allocate nothing.
local function refresh(api,game,L,windows)
    into(api,L.behavior_address,160,L.behavior);into(api,L.control_address,16,L.control)
    into(api,L.runtime_address,32,L.runtime);into(api,L.network_address,24,L.network)
    check_components(L)
    local s,at,b=L.row,L.at,L.behavior
    s.node,s.target,s.source_flags,s.has=b[2],b[6],b[24],L.bytes.behavior[120]==1
    s.point=ffi.string(at.point,12)
    s.runtime_target,s.raw,s.computed=L.runtime[0],ffi.string(at.raw,12),ffi.string(at.computed,12)
    s.flags=L.network[4]
    s.horizontal,s.vertical=ffi.string(at.horizontal,4),ffi.string(at.vertical,4)
    s.enabled=L.bytes.control[0]==1
    local t=s.transition_guards
    t[1].bytes,t[2].bytes=ffi.string(at.node,4),ffi.string(at.target,4)
    t[3].bytes,t[4].bytes=ffi.string(at.source,4),ffi.string(at.has,1)
    if L.fire then return refresh_fire(api,game,L,s,windows) end
    return true
end

-- The check: targeting entries, classified once per pointer --------------------
-- A cache keeps, per targeting index, the entity pointer seen there (two
-- 32-bit halves) and its class: false (not a sentry this machine controls),
-- true (a sentry), plus the sentry's layout. Entries are classified again when
-- their pointer changes and on every RESCAN-th check: authority can change in
-- place, and a new entity can take a removed one's address and index (a new
-- sentry is then found within RESCAN checks, about a quarter of a second).
-- Layouts are verified on every check from the memory the check read.
local RESCAN=30
-- Read buffers, made once per cache: the targeting root and header, the
-- pointer chunks (one per 256 entries, made when first needed), an entity
-- header and the mission mode record.
local function buffers()
    local b={root=ffi.new('uint32_t[2]'),head=ffi.new('uint32_t[21]'),entity=ffi.new('uint32_t[6]'),
        mode_at=ffi.new('uint32_t[2]'),mode=ffi.new('uint32_t[17]'),chunks={},chunk8={},chunk_size={}}
    b.root8,b.head8=ffi.cast('uint8_t *',b.root),ffi.cast('uint8_t *',b.head)
    b.entity8,b.mode_at8=ffi.cast('uint8_t *',b.entity),ffi.cast('uint8_t *',b.mode_at)
    return b
end
function M.new_cache()
    return {lo={},hi={},class={},layouts={},checks=0,active=0,windows={n=0},rows={},reg={},kept={},
        chunk_at={},addr={},pointer={},buf=buffers()}
end
local function forget(c,from)
    for i=from,c.active-1 do
        c.lo[i],c.hi[i],c.class[i],c.layouts[i],c.addr[i],c.pointer[i]=nil,nil,nil,nil,nil,nil
    end
    c.active=from
end
-- The sentry profiles by the two 32-bit words of their resource identity, so
-- an entity header is classified from its buffer without a string.
local profile_words={}
for key,profile in pairs(profiles) do
    assert(not profile_words[u(key,0)],'Ambiguous sentry resource word')
    profile_words[u(key,0)]={u(key,4),profile}
end
-- The roots' addresses in game.dll, kept per module base.
local function roots(c,game)
    if c.game~=game then
        c.game=game
        c.at={tm=game+0x2ce1ef0,bm=game+0x2ce18f0,rm=game+0x2ce1f30}
    end
    return c.at
end
-- The pointer chunks of this check, read in place: chunk n holds entries
-- n*256 .. n*256+255 as 32-bit halves.
local function read_chunks(api,c,b,active)
    local last=math.floor((active-1)/256)
    for n=0,last do
        local first=n*256
        local address=c.chunk_at[n]
        if not address then address=c.kept.ep+8*first;c.chunk_at[n]=address end
        if not b.chunks[n] then b.chunks[n]=ffi.new('uint32_t[512]');b.chunk8[n]=ffi.cast('uint8_t *',b.chunks[n]) end
        local size=math.min(256,active-first)*8
        into(api,address,size,b.chunks[n]);b.chunk_size[n]=size
    end
    return last
end
-- This check's targeting registry, or nil. The root, header and pointer chunks
-- are decoded in place; pointers become addresses only when they change.
local function targeting(api,game,c)
    local w,at,k,b=c.windows,roots(c,game),c.kept,c.buf;w.n=0;c.strings=false
    local reg=c.reg;reg.bm=nil
    into(api,at.tm,8,b.root)
    local lo,hi=b.root[0],b.root[1]
    if lo==0 and hi==0 then return nil end
    if lo~=k.tm_lo or hi~=k.tm_hi then
        local tmb=ffi.string(b.root8,8)
        k.tm_lo,k.tm_hi,k.tmb,k.tm=lo,hi,tmb,need_pointer(api,tmb);k.th=k.tm+308
    end
    into(api,k.th,84,b.head)
    local h=b.head
    local cap,total,active=h[0],h[3],h[4]
    assert(active<=total and total<=cap and cap<=8192,'Unsupported targeting registry')
    if active==0 then return nil end
    if h[13]~=k.ep_lo or h[14]~=k.ep_hi then
        local epb=ffi.string(b.head8+52,8)
        k.ep_lo,k.ep_hi,k.epb,k.ep=h[13],h[14],epb,need_pointer(api,epb)
        for i in pairs(c.chunk_at) do c.chunk_at[i]=nil end
    end
    reg.tm,reg.tmb,reg.th,reg.active,reg.ep=k.tm,k.tmb,nil,active,k.ep
    reg.chunks=read_chunks(api,c,b,active)
    return reg
end
-- The layout of entry i whose pointer changed (or a rescan), or nil when it is
-- not a sentry this machine controls. Sets the entry's class. The entity
-- address is kept while the entry's pointer is unchanged, and the header is
-- decoded from its buffer: classifying another entity allocates nothing.
local function classify(api,game,c,reg,i)
    local b=c.buf
    local address=c.addr[i]
    if not address then
        local pointer=ffi.string(b.chunk8[math.floor(i/256)]+(i%256)*8,8)
        address=need_pointer(api,pointer);c.addr[i],c.pointer[i]=address,pointer
    end
    into(api,address,24,b.entity)
    local words=profile_words[b.entity[0]]
    local profile=words and words[1]==b.entity[1] and words[2] or nil
    c.class[i]=profile~=nil and bit.band(b.entity8[20],3)==1
    if not c.class[i] or not components(api,game,c) then return nil end
    local entity=ffi.string(b.entity8,24)
    return locate(api,game,reg,{index=i,pointer=c.pointer[i],address=address,bytes=entity,
        key=entity:sub(1,20),profile=profile,id=u(entity,8)})
end
-- A cached layout still valid this check: its entity keeps the same identity
-- and authority and every guard holds.
local function current(api,game,c,L)
    local w=c.windows
    local entity=api.read(L.address,24)
    if not entity then return false end
    window(api,w,L.address,entity)
    if bit.band(entity:byte(21),3)~=1 then c.class[L.index]=false;return false end
    return components(api,game,c)~=nil and verified(api,L.guards,w)
end
-- The row of entry i, or nil: a cached layout while it holds, otherwise the
-- entry is classified (and a sentry located) again.
local function entry_row(api,game,c,reg,i,moved)
    local L=c.layouts[i]
    if L and not moved and current(api,game,c,L) and refresh(api,game,L,c.windows) then return L.row end
    c.layouts[i]=nil
    L=classify(api,game,c,reg,i)
    if not L then return nil end
    c.layouts[i]=L
    assert(refresh(api,game,L,c.windows),'Sentry changed while located')
    return L.row
end
-- One targeting entry of a check: its row (added to rows) when it is a sentry
-- this machine controls. Returns 1 while the entry is not classified as
-- something else (a sentry, or one not yet settled), otherwise 0.
local function visit(api,game,c,reg,i,rescan,rows)
    local chunk,at=c.buf.chunks[math.floor(i/256)],(i%256)*2
    local lo,hi=chunk[at],chunk[at+1]
    local moved=lo~=c.lo[i] or hi~=c.hi[i]
    c.lo[i],c.hi[i]=lo,hi
    if moved then c.addr[i]=nil end
    if not (moved or rescan or c.class[i]~=false) then return 0 end
    local row=entry_row(api,game,c,reg,i,moved)
    if row then rows[#rows+1]=row end
    return c.class[i]~=false and 1 or 0
end
-- c.idle is true after a check that found no targeting registry, or only
-- entries classified as not being a sentry this machine controls (M.idle).
function M.snapshot(api,game,c)
    c=c or M.new_cache()
    c.checks=c.checks+1;c.idle=false
    local rows=c.rows
    for k=#rows,1,-1 do rows[k]=nil end
    local reg=targeting(api,game,c)
    if not reg then forget(c,0);c.idle=true;return rows,'waiting_for_sentries' end
    -- Another targeting registry (a new mission): every entry is new.
    if reg.tmb~=c.tmb then forget(c,0);c.tmb=reg.tmb end
    if reg.active<c.active then forget(c,reg.active) end
    c.active=reg.active
    local rescan=c.checks%RESCAN==0
    -- Entries still a sentry, or not yet settled (a sentry whose components or
    -- maps are not ready is classified again on every check).
    local unsettled=0
    for i=0,reg.active-1 do unsettled=unsettled+visit(api,game,c,reg,i,rescan,rows) end
    c.idle=unsettled==0
    return rows,#rows==0 and 'waiting_for_sentries' or 'observing'
end
-- Whether a mission runs: the mode record at [game.dll+0x2ce1850] (68 bytes;
-- a mission is word +8 set and word +0x40 in 1..7, as other mods read it).
-- Nil when it cannot be read. Two reads, decoded in place; the record's
-- address is kept while its pointer is unchanged.
local MISSION_EVERY=2*RESCAN
local function in_mission(api,game,c)
    local b,k=c.buf,c.kept
    if c.mode_game~=game then c.mode_game,c.mode_global=game,game+0x2ce1850 end
    if not api.read_into(c.mode_global,8,b.mode_at) then return nil end
    local lo,hi=b.mode_at[0],b.mode_at[1]
    if lo==0 and hi==0 then return false end
    if lo~=k.mode_lo or hi~=k.mode_hi then
        local record=api.pointer(ffi.string(b.mode_at8,8))
        if not record then return nil end
        k.mode_lo,k.mode_hi,k.mode=lo,hi,record
    end
    if not api.read_into(k.mode,0x44,b.mode) then return nil end
    return b.mode[2]~=0 and b.mode[16]>=1 and b.mode[16]<=7
end
-- The idle gate, run by the loader before each frame's check. While the last
-- check found no sentry this machine controls (c.idle; nothing is held, paused
-- or requested then), a frame only counts as a check: no read, no allocation.
-- In a mission the next full check is the next RESCAN-th, which classifies
-- every entry again, so a new sentry, a changed registry or an ownership
-- change is found within RESCAN frames (0.5 s at 60 FPS), as an in-place
-- sentry already was. Outside a mission no sentry can exist: no rescan runs,
-- and the mission is checked every MISSION_EVERY-th frame (two reads), so a
-- mission start is seen within 59 frames (1 s at 60 FPS, 2 s at 30 FPS),
-- seconds before anyone can land and call in a sentry. A mission record that
-- cannot be read counts as a mission (the rescan runs).
-- Returns true when this frame needs no check.
function M.idle(api,game,state)
    local c=state.layout
    if not c or not c.idle then return false end
    local checks=c.checks+1
    if checks%RESCAN==0 then
        if c.outside==nil or checks%MISSION_EVERY==0 then c.outside=in_mission(api,game,c)==false end
        if not c.outside then return false end
    end
    c.checks=checks
    return true
end

local function writable(api,s)
    return api.writable_data(s.flags_address,4) and api.writable_data(s.raw_address,24)
        and api.writable_data(s.control_address+8,8)
end
local function same(a,b)
    return a.key==b.key and a.flags_address==b.flags_address
        and a.control_address==b.control_address and a.raw_address==b.raw_address
end

-- Whether a lease may be restored: the same entity, this machine still controls
-- it, and its control memory is private read-write data. Returns nothing to go
-- on, or the release's result. A removed/moved entity owns no writable lease
-- here. Never follow an old slot.
local function release_gate(api,s)
    if not matches(api,s.guards) then return true,'retired' end
    if s.authority_address then
        local flags=api.read(s.authority_address,1)
        if not flags or bit.band(flags:byte(1),1)==0 then return true,'authority_changed' end
    end
    if not writable(api,s) then return false,'restore_memory_unavailable' end
end
-- Whether current holds our write w, whole or cut short at any byte.
local function owned(current,w)
    for cut=0,12 do
        if current==w.after:sub(1,cut)..w.before:sub(cut+1) then return true end
    end
    return false
end
-- Rolls back the aim writes of a hold that did not complete. A derived aim
-- changed by the engine is no longer ours to restore. Returns false when a
-- rollback failed; every owned control is still released.
local function rollback_aim(api,lease,s)
    local restored=true
    for _,w in ipairs(lease.aim_writes or {}) do
        local current=api.read(w.address,12)
        if not current then restored=false
        elseif owned(current,w) and current~=w.before then
            -- writable() verified raw_address..+24 just before. A write inside
            -- that range does not repeat the query; any other one checks itself.
            local checked=w.address>=s.raw_address and w.address+12<=s.raw_address+24
            local called,written=pcall(api.write,w.address,w.before,checked)
            if not called or not written or api.read(w.address,12)~=w.before then restored=false end
        end
    end
    return restored
end
-- Restores both turret speeds still at our zero. Speed changes made by native
-- behavior or another mod are not overwritten.
local function release_speeds(api,native,lease,s)
    local restored=true
    for _,axis in ipairs({{'horizontal',8},{'vertical',12}}) do
        if lease[axis[1]] then
            local address=s.control_address+axis[2];local current=api.read(address,4)
            if current==ZERO then
                local called=pcall(native[axis[1]],s.entity,f(s[axis[1]],0))
                if not called or api.read(address,4)~=s[axis[1]] then restored=false
                else lease[axis[1]]=nil end
            elseif not current then restored=false
            else lease[axis[1]]=nil end
        end
    end
    return restored
end
-- Clears the retention bit while it is still set.
local function release_flag(api,native,lease,s)
    local current=api.read(s.flags_address,4)
    if not current then return false end
    if bit.band(u(current,0),2)~=0 then
        local called=pcall(native.retention,s.id,false)
        if not called or api.read(s.flags_address,4)~=word(bit.band(u(current,0),bit.bnot(2))) then return false end
    end
    lease.flag=nil
    return true
end
function M.release(api,native,lease)
    local s=lease.snapshot
    local done,why=release_gate(api,s)
    if done~=nil then return done,why end
    local restored=true
    if not lease.completed then restored=rollback_aim(api,lease,s) end
    if not release_speeds(api,native,lease,s) then restored=false end
    if lease.flag and not release_flag(api,native,lease,s) then restored=false end
    return restored,restored and 'restored' or 'restore_incomplete'
end

-- A hold may start: no native disable bit, unchanged identity and transition
-- state, and this machine still controls the sentry.
local function may_hold(api,s)
    if s.flags~=0 or not matches(api,s.guards) or not matches(api,s.transition_guards or {}) then return false end
    if not s.authority_address then return true end
    local flags=api.read(s.authority_address,1)
    return flags and bit.band(flags:byte(1),3)==1
end
-- Set the native retention bit first: the engine skips its target-source
-- prepass and fallback path while this bit is owned. AI itself keeps running.
-- Each control is journaled in the lease before its setter runs.
local function hold_controls(api,native,s,lease)
    native.retention(s.id,true)
    if api.read(s.flags_address,4)~=word(2) then return false,'hold_flag_failed' end
    for _,axis in ipairs({{'horizontal',8},{'vertical',12}}) do
        lease[axis[1]]=true
        native[axis[1]](s.entity,0)
        if api.read(s.control_address+axis[2],4)~=ZERO then return false,'hold_speed_failed' end
    end
    return true
end
-- Write the recorded aim into both aim fields, each journaled before its write.
local function hold_aim(api,s,record,lease)
    lease.aim_writes={}
    -- acquire's writable() check verified raw_address..+24 in this check; it holds
    -- both aim fields (computed_address is raw_address+12). No repeated query.
    for _,w in ipairs({{address=s.raw_address,before=s.raw,after=record.raw},
        {address=s.computed_address,before=s.computed,after=record.computed}}) do
        lease.aim_writes[#lease.aim_writes+1]=w
        if not api.write(w.address,w.after,true) then return false,'hold_aim_failed' end
    end
    if api.read(s.raw_address,12)~=record.raw or api.read(s.computed_address,12)~=record.computed then
        return false,'hold_aim_verify_failed'
    end
    return true
end
local function acquire(api,native,s,record,state)
    if not may_hold(api,s) then return true,'busy' end
    if not writable(api,s) then return false,'hold_memory_unavailable' end
    -- The lease keeps its own copy: the row is refreshed in place on every
    -- check, and the hold must keep the turret speeds it saved here.
    local held={};for k,v in pairs(s) do held[k]=v end
    local lease={snapshot=held,flag=true};record.lease=lease
    local ok,why=hold_controls(api,native,s,lease)
    if not ok then return false,why end
    if s.raw~=record.raw then state.late_aim=state.late_aim+1 end
    ok,why=hold_aim(api,s,record,lease)
    if not ok then return false,why end
    state.holds=state.holds+1
    lease.completed=true
    return true,'holding'
end

-- Refresh map guards even when component addresses did not move. A hash-table
-- replacement alone invalidates the old guards and must not retire a live hold
-- without restoring its controls. The saved turret speeds stay.
local function relocate_lease(lease,s)
    local held=lease.snapshot
    for k,v in pairs(s) do
        if k~='horizontal' and k~='vertical' then held[k]=v end
    end
end
-- The aim record of a row: the same instance keeps it; another instance
-- elsewhere releases it first. Returns true and the record (or nil), or false
-- and the failure.
local function aim_record(api,native,state,s)
    local record=state.records[s.id]
    if record and record.snapshot.key==s.key then
        if record.lease then relocate_lease(record.lease,s) end
        record.snapshot=s
    elseif record and not same(record.snapshot,s) then
        if record.lease then
            local ok,why=M.release(api,native,record.lease);if not ok then return false,why end
        end
        record=nil;state.records[s.id]=nil
    end
    return true,record
end
-- A hold ends when the sentry tracks or scans again, is disabled, or its speeds
-- or other disable bits changed. A non-target point on the firing node is the
-- dead-target fallback, not scanning; a zero point is the observed transition
-- placeholder. It also ends when the engine explicitly reclaimed targeting:
-- restore our speed overrides and wait for a fresh target rather than fighting it.
local function hold_ended(s,tracking,scan)
    if tracking or scan or not s.enabled or s.horizontal~=ZERO or s.vertical~=ZERO
        or bit.band(s.flags,bit.bnot(2))~=0 then return true end
    return bit.band(s.flags,2)==0
end
local function release_hold(api,native,state,record)
    local ok,why=M.release(api,native,record.lease);if not ok then return false,why end
    record.lease=nil;record.raw=nil;state.releases=state.releases+1
    return true
end
-- Records the aim of a synchronized target, or holds it once that target is
-- lost (a scan forgets it instead). Returns true and the record (or nil), or
-- false and the failure.
local function track_or_hold(api,native,state,s,record,tracking,scan)
    if tracking and not (record and record.lease) and s.flags==0 and s.runtime_target==s.target then
        record={snapshot=s,node=s.node,source_point=s.point,raw=s.raw,computed=s.computed}
        state.records[s.id]=record
    elseif record and record.raw and not record.lease and not tracking and s.enabled then
        if scan then record.raw=nil
        else
            local ok,why=acquire(api,native,s,record,state)
            if not ok then return false,why end
        end
    end
    return true,record
end
-- One aim row: returns true and its record (or nil), or false and the failure.
local function aim_row(api,native,state,s)
    local ok,result=aim_record(api,native,state,s)
    if not ok then return false,result end
    local record=result
    local tracking=s.enabled and s.has and s.target~=0 and bit.band(s.source_flags,1)~=0
    local scan=record and s.has and s.target==0 and bit.band(s.source_flags,32)~=0
        and s.node~=record.node and nonzero(s.point) and s.point~=record.source_point
    if record and record.lease and hold_ended(s,tracking,scan) then
        ok,result=release_hold(api,native,state,record)
        if not ok then return false,result end
    end
    ok,result=track_or_hold(api,native,state,s,record,tracking,scan)
    if ok and result then result.latest=s end
    return ok,result
end
local function release_unseen_aim(api,native,state,stamp)
    for id,record in pairs(state.records) do
        if record.seen~=stamp then
            if record.lease then
                local ok,why=M.release(api,native,record.lease);if not ok then return false,why end
            end
            state.records[id]=nil
        end
    end
    return true
end
function M.step(api,native,rows,state)
    state.records=state.records or {}
    state.holds=state.holds or 0;state.releases=state.releases or 0;state.late_aim=state.late_aim or 0
    -- Records seen in this step carry its stamp (no table per step).
    state.observed=#rows;local holding=0
    local stamp=(state.aim_stamp or 0)+1;state.aim_stamp=stamp
    for _,s in ipairs(rows) do
        local ok,result=aim_row(api,native,state,s)
        if not ok then return false,result end
        if result then result.seen=stamp end
        if result and result.lease then holding=holding+1 end
    end
    local ok,why=release_unseen_aim(api,native,state,stamp)
    if not ok then return false,why end
    state.holding=holding
    return true,holding>0 and 'holding' or (#rows>0 and 'observing' or 'waiting_for_sentries'),holding>0
end
-- The aim step stays interpreted, as the single step it replaced always was in
-- the game's LuaJIT 2.1.0-alpha: its traces abort on pairs() and on leaving the
-- row loop. acquire and release, which compiled before, keep compiling.
if jit and jit.off then
    for _,fn in ipairs({relocate_lease,aim_record,hold_ended,release_hold,track_or_hold,aim_row,
        release_unseen_aim,M.step}) do
        jit.off(fn,true)
    end
end

-- A short adjustment may keep firing. A broad or prolonged sweep cannot.
-- Separate enter/exit angles and a settle interval avoid rapid mode toggling.
M.fire_policy={settle_seconds=0.06,sweep_seconds=0.20,reselection_seconds=0.10}
local function direction(x,y,z)
    local length=math.sqrt(x*x+y*y+z*z)
    assert(finite(length) and length>0.00001,'Invalid firing direction')
    return {x/length,y/length,z/length}
end
local function angle(a,b)
    return math.deg(math.acos(math.max(-1,math.min(1,a[1]*b[1]+a[2]*b[2]+a[3]*b[3]))))
end
function M.fire_geometry(s)
    local pose=s.fire.pose
    assert(pose and #pose==64 and vector(pose:sub(17,28)) and vector(pose:sub(49,60)),
        'Invalid muzzle pose')
    local forward=direction(f(pose,16),f(pose,20),f(pose,24))
    local aim=direction(f(s.computed,0)-f(pose,48),f(s.computed,4)-f(pose,52),f(s.computed,8)-f(pose,56))
    return forward,angle(forward,aim)
end
local function fire_identity(api,s)
    local authority=s.authority_address and api.read(s.authority_address,1)
    return matches(api,s.guards) and matches(api,s.fire.guards)
        and (not s.authority_address or (authority and bit.band(authority:byte(1),3)==1))
end
function M.release_selection(api,lease)
    local s=lease.snapshot
    if not fire_identity(api,s) or not matches(api,s.selection.guards)
        or api.read(s.behavior_address+8,4)~=word(12) then return true end
    local current=api.read(s.selection.address,8)
    if not current then return false end
    local ours=current==lease.after
    if not lease.completed then
        for cut=0,8 do
            if current==lease.after:sub(1,cut)..lease.before:sub(cut+1) then ours=true;break end
        end
    end
    -- The native handler consumes the request by setting its own new deadline.
    if not ours or current==lease.before then return true end
    if not api.writable_data(s.selection.address,8) then return false end
    -- The deadline was verified just above; the write does not repeat it.
    local ok,written=pcall(api.write,s.selection.address,lease.before,true)
    return ok and written and api.read(s.selection.address,8)==lease.before
end

-- A pending request is released once the sentry tracks again, leaves the
-- firing node or is disabled, and forgotten once the native handler replaced
-- the deadline it holds.
local function follow_selection(api,r,s,tracking)
    r.selection.snapshot=s
    if tracking or not s.enabled or s.node~=12 then
        if not M.release_selection(api,r.selection) then return false,'selection_restore_failed' end
        r.selection=nil
        return true
    end
    local current=api.read(s.selection.address,8)
    if not current then return false,'selection_read_failed' end
    if current~=r.selection.after then r.selection=nil end
    return true
end
-- The new deadline for one request after a target loss on the firing node, or
-- nil when the pending deadline is not within a second or no retry is due.
local function selection_due(r,s)
    local q=s.selection;local deadline=ticks(q.deadline)
    local remaining=deadline-q.now
    -- Bound retries if native perception repeatedly offers a target
    -- that is immediately invalidated again.
    local due=math.max(q.now,(r.last_selection or 0)+M.fire_policy.reselection_seconds*1000000)
    if s.enabled and s.node==12 and not r.selection and q.now>0
        and q.now<9007199254740991 and remaining>0 and remaining<=1000000 and due<deadline then
        return due
    end
end
local function request_selection(api,state,r,s,due)
    local q=s.selection
    if not fire_identity(api,s) or not matches(api,q.guards)
        or not matches(api,s.transition_guards or {})
        or api.read(q.address,8)~=q.deadline then return false,'selection_identity_changed' end
    if not api.writable_data(q.address,8) then return false,'selection_memory_unavailable' end
    r.selection={snapshot=s,before=q.deadline,after=tickword(due)}
    -- Only expire the pending query. Native perception, scoring,
    -- range checks and target assignment still choose the enemy.
    -- The deadline was verified just above; the write does not repeat it.
    if not api.write(q.address,r.selection.after,true)
        or api.read(q.address,8)~=r.selection.after then return false,'selection_request_failed' end
    r.selection.completed=true;r.last_selection=due;state.reselections=state.reselections+1
    return true
end
local function selection_row(api,state,s)
    local r=state.fire_records[s.id]
    local tracking=s.enabled and s.node==12 and s.has and s.target~=0
        and bit.band(s.source_flags,1)~=0
    if r.selection then
        local ok,why=follow_selection(api,r,s,tracking)
        if not ok then return false,why end
    end
    if tracking then r.selection_armed=true
    elseif r.selection_armed and s.target==0 then
        r.selection_armed=false -- one request per observed target loss
        local due=selection_due(r,s)
        if due then return request_selection(api,state,r,s,due) end
    elseif not s.enabled or s.node~=12 then r.selection_armed=false end
    return true
end
function M.selection_step(api,rows,state)
    state.reselections=state.reselections or 0
    local pending=0
    for _,s in ipairs(rows) do
        if s.selection then
            local ok,why=selection_row(api,state,s)
            if not ok then return false,why end
            if state.fire_records[s.id].selection then pending=pending+1 end
        end
    end
    state.selections=pending
    return true
end
function M.release_fire(api,native,lease)
    local s=lease.snapshot
    if not fire_identity(api,s) then return true end
    local current=api.read(s.fire.mode_address,4)
    if not current then return false end
    -- Restore only the no-fire mode owned by this module.
    if current~=ZERO then return true end
    if not api.writable_data(s.fire.mode_address,4) then return false end
    local ok=pcall(native.fire_mode,s.fire.manager,s.id,lease.mode)
    return ok and api.read(s.fire.mode_address,4)==word(lease.mode)
end
-- Restores a fire record's pending selection request, then its no-fire mode.
local function release_fire_record(api,native,r)
    if r.selection and not M.release_selection(api,r.selection) then return false,'selection_restore_failed' end
    if r.lease and not M.release_fire(api,native,r.lease) then return false,'fire_restore_failed' end
    return true
end
-- The fire record for a row. Another instance under the same id releases the
-- old record first; leases follow fresh maps after native compaction.
local function fire_record(api,native,state,s)
    local r=state.fire_records[s.id]
    if r and r.snapshot.key~=s.key then
        local ok,why=release_fire_record(api,native,r)
        if not ok then return nil,why end
        r=nil
    end
    r=r or {};state.fire_records[s.id]=r;r.snapshot=s
    if r.lease then r.lease.snapshot=s end
    if r.selection then r.selection.snapshot=s end
    return r
end
local function fire_tracking(s)
    local tracking=s.enabled and s.has and s.target~=0 and bit.band(s.source_flags,1)~=0
    return tracking,tracking and s.runtime_target==s.target
end
-- A retained direction does not imply that there is still a target to shoot.
-- Never reopen a paused burst merely because it is held. Clearance results
-- belong to one target.
local function fire_terrain(r,s,synced,now)
    if r.terrain_target~=s.target then r.terrain_blocked=nil;r.terrain_checked_at=nil;r.query=nil end
    r.terrain_target=s.target
    if synced and s.fire.terrain_blocked~=nil then
        r.terrain_blocked=s.fire.terrain_blocked;r.query=s.fire.query;r.terrain_checked_at=now
    end
    r.terrain_age=r.terrain_checked_at and now-r.terrain_checked_at or nil
end
local function fire_reason(unavailable,tracking,obstructed)
    return unavailable and (tracking and 'aim_pending' or 'target_lost')
        or (obstructed and 'terrain_blocked' or nil)
end
-- Aim held within the resume angle for settle_seconds moves the anchor.
local function fire_settle(r,aligned,forward,now)
    if aligned then
        r.settled_since=r.settled_since or now
        if now-r.settled_since>=M.fire_policy.settle_seconds then
            r.anchor=forward;r.sweep_since=nil
        end
    else r.settled_since=nil end
end
-- Starts the firing-sweep timer on a turn away from the anchor; returns the
-- turn in degrees. Uses r.synced and r.error of this check.
local function fire_sweep(r,s,forward,aligned,now)
    local travel=angle(r.anchor,forward)
    -- Time with shot permission closed is not a continuing firing sweep.
    if r.lease then r.sweep_since=nil end
    if not s.fire.trigger then
        r.anchor=forward;r.sweep_since=nil
    elseif not aligned and (travel>0.5 or (r.synced and r.error>s.fire.resume)) then
        r.sweep_since=r.sweep_since or now
    end
    return travel
end
-- A broad turn: aim far off target, a wide turn with the trigger held, or a
-- firing sweep that stays unsettled too long.
local function fire_broad(r,s,travel,now)
    return (r.synced and r.error>s.fire.pause)
        or (s.fire.trigger and travel>s.fire.pause)
        or (s.fire.trigger and r.sweep_since and now-r.sweep_since>=M.fire_policy.sweep_seconds)
end
-- Updates the record from this check's aim; returns forward, tracking,
-- unavailable, obstructed, broad and settled.
local function assess_fire(r,s,now)
    local forward,error_angle=M.fire_geometry(s)
    r.error=error_angle;r.anchor=r.anchor or forward
    local tracking,synced=fire_tracking(s)
    fire_terrain(r,s,synced,now)
    local unavailable=not synced and s.fire.trigger
    local obstructed=tracking and r.terrain_blocked==true
    r.reason=fire_reason(unavailable,tracking,obstructed)
    r.synced=synced;r.travel=angle(r.anchor,forward)
    local aligned=synced and not obstructed and error_angle<=s.fire.resume
    fire_settle(r,aligned,forward,now)
    local broad=fire_broad(r,s,fire_sweep(r,s,forward,aligned,now),now)
    if not r.reason and broad then r.reason='sweep' end
    local settled=aligned and now-r.settled_since>=M.fire_policy.settle_seconds
    return forward,tracking,unavailable,obstructed,broad,settled
end
-- Losing a target is not itself a broad turn. A close replacement with a
-- fresh clear ray can use the ordinary short-turn allowance. A broad turn or
-- obstruction observed during the pause cancels this shortcut; those pauses
-- still require settled alignment. Returns whether the handoff applies now.
local function fire_handoff(r,s,broad,obstructed)
    if r.lease and s.fire.mode~=0 then r.lease=nil end -- engine/another mod changed the mode
    if r.lease and (broad or obstructed) then r.lease.handoff=false end
    return r.lease and r.lease.handoff and r.synced
        and s.fire.terrain_blocked==false and r.error<=s.fire.pause and not broad
end
local function resume_fire(api,native,state,r,forward)
    if not M.release_fire(api,native,r.lease) then return false,'fire_restore_failed' end
    r.lease=nil;r.anchor=forward;r.sweep_since=nil
    state.fire_resumes=state.fire_resumes+1
    return true
end
local function pause_fire(api,native,state,r,s,handoff)
    if not fire_identity(api,s) or not matches(api,s.transition_guards or {}) then return false,'fire_identity_changed' end
    if not api.writable_data(s.fire.mode_address,4) then return false,'fire_memory_unavailable' end
    r.lease={snapshot=s,mode=s.fire.mode,handoff=handoff}
    -- Journal before invoking the native setter.
    native.fire_mode(s.fire.manager,s.id,0)
    if api.read(s.fire.mode_address,4)~=ZERO then return false,'fire_pause_failed' end
    state.fire_pauses=state.fire_pauses+1
    return true
end
-- One firing row: returns its record, or nil and the failure.
local function fire_row(api,native,state,s,now)
    local r,why=fire_record(api,native,state,s)
    if not r then return nil,why end
    local forward,tracking,unavailable,obstructed,broad,settled=assess_fire(r,s,now)
    local handoff=fire_handoff(r,s,broad,obstructed)
    local ok=true
    if r.lease and (settled or handoff or (not tracking and not s.fire.trigger) or not s.enabled) then
        ok,why=resume_fire(api,native,state,r,forward)
    elseif not r.lease and (broad or unavailable or obstructed) and s.enabled and s.fire.mode~=0 then
        ok,why=pause_fire(api,native,state,r,s,unavailable and not broad and not obstructed)
    end
    if not ok then return nil,why end
    return r
end
local function release_unseen_fire(api,native,state,stamp)
    for id,r in pairs(state.fire_records) do
        if r.seen~=stamp then
            local ok,why=release_fire_record(api,native,r)
            if not ok then return false,why end
            state.fire_records[id]=nil
        end
    end
    return true
end
function M.fire_step(api,native,rows,state,now)
    state.fire_records=state.fire_records or {}
    state.fire_pauses=state.fire_pauses or 0;state.fire_resumes=state.fire_resumes or 0
    -- Records seen in this step carry its stamp (no table per step).
    local paused=0
    local stamp=(state.fire_stamp or 0)+1;state.fire_stamp=stamp
    for _,s in ipairs(rows) do
        if s.fire then
            local r,why=fire_row(api,native,state,s,now)
            if not r then return false,why end
            r.seen=stamp
            if r.lease then paused=paused+1 end
        end
    end
    local ok,why=release_unseen_fire(api,native,state,stamp)
    if not ok then return false,why end
    state.fire_paused=paused
    return true
end
-- The fire path stays interpreted, as the single fire_step it replaced always
-- was: in the game's LuaJIT 2.1.0-alpha its traces abort in fire_geometry's
-- field decoding and on pairs(). Compiled one by one, these helpers added
-- 8.3 KB of machine code to the cache every mod and the game share (offline
-- median 29.7 -> 38.0 KB) for the same time per call (about 3.0 us in the
-- game's lua51.dll). The functions they call compile as before.
if jit and jit.off then
    for _,fn in ipairs({release_fire_record,fire_record,fire_tracking,fire_terrain,fire_reason,fire_settle,
        fire_sweep,fire_broad,assess_fire,fire_handoff,resume_fire,pause_fire,fire_row,release_unseen_fire,
        M.fire_step}) do
        jit.off(fn,true)
    end
end

-- Verifies the native setters, the pose getter and the terrain query once per
-- session, then binds them. Build 26088801 maps some code pages only once the
-- game has run them: until then their bytes cannot be read. Code that cannot
-- be read yet gives nil (M.apply checks again later); code that reads
-- differently is refused.
local function native_code(api,address,expected,why)
    local found=api.read(address,#expected)
    if found==nil then return false end
    assert(found==expected,why)
    return true
end
local function bind_natives(api,game,exe)
    local ready=true
    for _,s in ipairs(signatures) do
        ready=native_code(api,game+s[1],fromhex(s[2]),'Unsupported native sentry setter') and ready
    end
    if not ready then return nil end
    local pose_signature=fromhex('40534883ec204863dae872d6eaff488bc84c8b0041ff90e8')
    assert(exe,'Unsupported engine pose getter')
    ready=native_code(api,exe+0x1f3020,pose_signature,'Unsupported engine pose getter')
    for _,s in ipairs({
        {0x826bc0,'33c04c8d0547b403020f1f800000000049390cc0740cffc083f80475f3'},
        {0x87bb20,'488bc4f30f11582089480855535657415441554156415748'},
        {0x87bb80,'488d15c961fe014181e40080000033f644896424680fae5c24508b4c24500fbae90f894c24500fae54245083ff047205448bfeeb0c4869cfb00000004c8b7c1120'},
    }) do
        ready=native_code(api,exe+s[1],fromhex(s[2]),'Unsupported terrain query') and ready
    end
    if not ready then return nil end
    return api.bind(game,exe)
end
-- The muzzle pose of a firing row and, while it tracks a synchronized target,
-- the terrain clearance to that target.
-- The snapshot verified every guard of the row in this check; the pose getter
-- checks the unit itself. The transition fields are read again in one read.
local transition_window={n=0}
local function prepare_fire(api,native,s)
    s.fire.pose=native.pose(s.fire.unit,s.fire.node)
    if not (s.enabled and s.has and s.target~=0 and s.runtime_target==s.target
        and bit.band(s.source_flags,1)~=0) then return end
    -- Test the current target point before ballistic/lead correction.
    -- A low target remains legal when the terrain does not occlude it.
    if s.fire.target_unit then
        if matches(api,s.fire.target_guards) then
            s.fire.terrain_blocked,s.fire.query=native.terrain_path(
                s.fire.unit,s.fire.pose:sub(49,60),s.raw,s.fire.target_unit)
        end
        if not matches(api,s.fire.target_guards) then
            s.fire.terrain_blocked,s.fire.query,s.fire.target_stale=nil,nil,true
        end
    end
    transition_window.n=0
    window(api,transition_window,s.transition_address,need(api,s.transition_address,113))
    assert(verified(api,s.transition_guards,transition_window),'Terrain target changed')
end
-- Whether a target loss inside the next game update could matter: a sentry
-- tracks a target, holds aim, pauses fire or waits on a search request.
local function engaged(rows,state)
    if state.holding>0 or state.fire_paused>0 or state.selections>0 then return true end
    for k=1,#rows do
        local s=rows[k]
        if s.has and s.target~=0 then return true end
    end
    return false
end
-- engaged's traces aborted on every check (return to the pcall'd apply's
-- caller); it stays interpreted. M.idle runs every frame under the loader's
-- pcall'd step and would abort the same way. in_mission runs once per 60
-- frames, called from the interpreted gate (its traces aborted there: 8 in
-- three game-shaped replays); it stays interpreted too.
if jit and jit.off then jit.off(engaged);jit.off(M.idle);jit.off(in_mission) end
-- One check. The layout cache lives in state.layout; a failed snapshot drops
-- it, so the next check locates every sentry again.
function M.apply(api,game,exe,state)
    state.engaged=false
    state.layout=state.layout or M.new_cache()
    local ok,rows,reason=pcall(M.snapshot,api,game,state.layout)
    if not ok then state.layout=nil;return false,tostring(rows),false end
    if #rows==0 and not state.native then return true,reason,false end
    if not state.native then
        -- Until every native's code can be read and matches: no hold, fire
        -- pause or search request (the sentries keep the game's own behavior),
        -- and the natives are checked again after 1 s.
        local now=api.time()
        if state.native_retry and now<state.native_retry then return true,'waiting_for_natives',false end
        state.native=bind_natives(api,game,exe)
        if not state.native then state.native_retry=now+1;return true,'waiting_for_natives',false end
    end
    for _,s in ipairs(rows) do
        if s.fire then prepare_fire(api,state.native,s) end
    end
    local accepted,why=M.fire_step(api,state.native,rows,state,api.time())
    if not accepted then return false,why,false end
    accepted,why=M.selection_step(api,rows,state)
    if not accepted then return false,why,false end
    local accepted,why,active=M.step(api,state.native,rows,state)
    if accepted then state.engaged=engaged(rows,state) end
    if accepted and state.fire_paused>0 then return true,'firing_paused',true end
    return accepted,why,active
end

-- Restores every fire record's search request and fire mode. A record that
-- could not be restored stays for the next attempt.
local function stop_fire(api,state)
    local ok=true
    for id,r in pairs(state.fire_records or {}) do
        local selection_ok=not r.selection or M.release_selection(api,r.selection)
        local fire_ok=not r.lease or M.release_fire(api,state.native,r.lease)
        if selection_ok and fire_ok then state.fire_records[id]=nil else ok=false end
    end
    return ok
end
-- Releases every aim hold. A hold that could not be restored stays.
local function stop_aim(api,state)
    local ok=true
    for id,record in pairs(state.records or {}) do
        if record.lease then
            local restored=M.release(api,state.native,record.lease)
            if restored then state.records[id]=nil else ok=false end
        else state.records[id]=nil end
    end
    return ok
end
function M.stop(api,game,exe,state)
    local fire_ok=stop_fire(api,state)
    return stop_aim(api,state) and fire_ok
end
-- Stopping runs once per stop or shutdown and never compiled (its traces abort
-- on pairs()); it stays interpreted. The releases it calls compile as before.
if jit and jit.off then
    for _,fn in ipairs({stop_fire,stop_aim,M.stop}) do jit.off(fn,true) end
end
return M

end)()
local install_loader = (function()
return function(create_api,patch,build,runtime)
    if rawget(_G,'SentryAimRetention') then return end
    local state={revision=build.revision,active=false,updates=0,polls=0,
        observed=0,holding=0,holds=0,releases=0,late_aim=0,records={},
        fire_paused=0,fire_pauses=0,fire_resumes=0,fire_records={},reselections=0,selections=0,engaged=false}
    rawset(_G,'SentryAimRetention',state)
    local api,game,exe,last_log,guard
    -- The last clearance query of a fire record.
    local function log_query(file,r)
        local q=r.query
        file:write(string.format('clearance=%s hit_unit=%s target_unit=%s hit_distance=%.3f target_distance=%.3f hit_actor=%s age=%.3f hit_filter=%s\n',
            q.reason,tostring(q.hit_unit),tostring(q.target_unit),q.distance or 0,q.length or 0,
            tostring(q.hit_actor),r.terrain_age or 0,q.filter and string.format('%08x',q.filter) or 'unknown'))
    end
    local function log_fire_records(file)
        for id,r in pairs(state.fire_records) do
            file:write(string.format('fire_sentry=%d paused=%s error_degrees=%.2f reason=%s terrain=%s synced=%s travel_degrees=%.2f target=%d runtime_target=%d\n',
                id,tostring(r.lease~=nil),r.error or 0,r.reason or 'tracking_or_settling',tostring(r.terrain_blocked),
                tostring(r.synced),r.travel or 0,r.snapshot.target,r.snapshot.runtime_target))
            if r.query then log_query(file,r) end
        end
    end
    local function log_aim_records(file)
        for id,r in pairs(state.records) do
            local s=r.latest or r.snapshot
            file:write(string.format('sentry=%d type=%s node=%d target=%d hold=%s\n',
                id,s.profile,s.node,s.target,tostring(r.lease~=nil)))
        end
    end
    -- The diagnostics log: the counters, every fire record and every aim record.
    local function write_log(status)
        local logger=rawget(_G,'CowboyBingusModLoader')
        local file=logger and logger.open_log and logger.open_log('SentryAimRetention.log');if not file then return end
        file:write(build.revision..'\n'..status..'\n')
        for _,key in ipairs({'updates','polls','observed','holding','holds','releases','late_aim',
            'fire_paused','fire_pauses','fire_resumes','reselections'}) do
            file:write(key..'='..tostring(state[key])..'\n')
        end
        log_fire_records(file)
        log_aim_records(file)
        file:close()
    end
    -- force: write the log now, without the diagnostics opt-in or the 2 s
    -- spacing, and print the status unless quiet (the guard has already printed
    -- its own line for a stop or a pause).
    local function report(status,active,force,quiet)
        state.status=status;state.active=active
        if not force and rawget(_G,'CowboyBingusDiagnostics')~=true then return end
        local now=api and api.time and api.time() or 0
        if not force and last_log and now-last_log<2 then return end
        last_log=now
        if force and not quiet then print('[SentryAimRetention] '..build.revision..': '..status) end
        pcall(write_log,status)
    end
    -- report never compiled while it built the log closure (its returns closed
    -- upvalues, which the game's LuaJIT does not compile); it stays interpreted
    -- so the shared code cache is unchanged. The log helpers compile as before.
    if jit and jit.off then jit.off(report,true) end
    -- Restores every hold, fire pause and search request this mod owns: aim,
    -- retention bit, turret speeds, fire mode and selection deadline. A record
    -- that could not be restored stays for the next attempt.
    local function restore()
        local called,restored=pcall(patch.stop,api,game,exe,state)
        return called and restored
    end
    -- After a full restore nothing is in progress, so the next check starts as
    -- on a fresh load. The session counters stay, and so do the bound natives:
    -- their signatures are verified once per session.
    local function fresh_start()
        state.observed,state.holding,state.fire_paused,state.selections=0,0,0,0
        -- Nothing in progress: the check after the game update waits for the
        -- next frame's first check, and the next check locates every sentry again.
        state.last_reason='waiting_for_sentries';state.engaged=false;state.layout=nil
    end
    -- The mod's own check raised or refused. Everything it holds is restored
    -- and the next frame starts afresh; the error goes to the guard, which logs
    -- one line per burst and stops the mod after 8 errors in a burst. Without a
    -- full restore the mod stops at once.
    local function failed(problem)
        if not restore() then return guard.stop(problem) end
        fresh_start();report(problem,false)
        error(problem,0)
    end
    local function check()
        state.polls=state.polls+1
        local called,accepted,reason,active=pcall(patch.apply,api,game,exe,state)
        if not called or not accepted then return failed(tostring(called and reason or accepted)) end
        state.last_reason=reason
        report(reason,active==true)
    end
    -- The idle gate runs first: while no sentry this machine controls exists,
    -- a frame between the periodic checks ends here, before pcall, apply and
    -- report (status and counters stay as the last check left them; polls
    -- counts the checks that ran).
    local idle=patch.idle
    local function step()
        state.updates=state.updates+1
        if idle and idle(api,game,state) then return end
        check()
    end
    -- step returns into the guard's pcall on every frame; its traces would
    -- abort there, so it stays interpreted.
    if jit and jit.off then jit.off(step) end
    local function after()
        -- The second check, after the game update, catches a target lost inside
        -- that update before the next frame. It runs only while a sentry is
        -- engaged (tracks a target, holds aim, pauses fire or waits on a search
        -- request); otherwise nothing it could see needs an answer this frame,
        -- and the next frame's first check sees the same state.
        if state.engaged then check() end
    end
    -- after also returns into the guard's pcall on every frame (6 aborted
    -- traces in 3000 waiting frames offline); it stays interpreted too.
    if jit and jit.off then jit.off(after) end
    -- An update below this mod raised. The guard skips this mod until the
    -- updates below have returned on 60 frames in a row. A failed restore
    -- raises, and the guard stops the mod.
    local function pause()
        if not restore() then error('the sentry controls could not be restored',0) end
        fresh_start();report('paused_after_update_error',false,true,true)
    end
    -- Runs once: when the guard stops the mod (reason), or at shutdown, where
    -- the status keeps the first failure.
    local function stop(reason)
        local restored=restore()
        if reason~='shutdown' then return report(reason..(restored and '' or '; restore_failed'),false,true,true) end
        local status=restored and 'stopped' or 'restore_failed'
        local failure=guard.status.first_failure
        report(failure and status..' after: '..failure or status,false,true)
    end
    -- The guard's few lines: the first error of a burst, pause, resume and stop.
    local function log(line)
        print('[SentryAimRetention] '..build.revision..': '..(line:gsub('^SentryAimRetention ','')))
    end
    local ok,why=pcall(function()
        local loader=rawget(_G,'CowboyBingusModLoader')
        assert(type(loader)=='table' and type(loader.api)=='number' and loader.api>=1
            and type(loader.version)=='number' and loader.version>=7,
            'Bingus Shared Loader loader-v6 or newer / API 1 or newer is required')
        -- The runtime's build check hashes each module file at most once per
        -- session for every mod on the runtime: 'game modules unavailable' or
        -- 'unsupported game build'.
        api=create_api()
        assert(api.verify_build(build))
        game,exe=api.module('game.dll'),api.module(nil)
        assert(type(update)=='function','Game update unavailable')
        -- The previous update runs outside pcall, so its errors reach the game
        -- unchanged; the first failure survives shutdown.
        guard=runtime.guard({name='SentryAimRetention',env=_G,step=step,after=after,pause=pause,stop=stop,log=log})
        guard.install()
    end)
    if not ok then report(tostring(why),false,true);return end
    report('waiting_for_sentries',false,true)
end

end)()
install_loader(function() return create_api(runtime, runtime_write.extend(runtime_memory.new(runtime))) end, patch, {revision = 'data-v8.7-26251122', exe_sha256 = '257FD7DE21A04E8668E02E5C820EDF3435176FBDE3569765255CC52A5EA20F9D', game_sha256 = '61DCFCD201DACBF3545C97BEB8A5A6186E9850D2670BF60B0E058320B477F6DF'}, runtime)
