-- HD2-Addon: mods/cowboybingus/consistent_vaulting
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
-- The mod's Windows adapter. Memory access and the clock come from Bingus
-- Shared Runtime (bingus_memory.lua with bingus_write.lua, passed in): reads into reused buffers; writes only into committed
-- private read-write memory, checked right before the write with one
-- VirtualQuery per region; module hashes read once per session for every mod;
-- all Windows functions under private, versioned names. This file adds the clock
-- and the build-locked native bindings.
return function(runtime, memory)
    local ffi = require('ffi')
    assert(ffi.abi('64bit'), 'Windows x64 is required')
    assert(type(memory) == 'table' and type(memory.time) == 'function', 'Bingus Shared Runtime memory api required')
    -- api.time is the runtime's: seconds from the performance counter, without
    -- boxing a 64-bit count (it was GetTickCount64 / 1000 here). Only time
    -- differences are used.
    local api = memory
    local native_cache
    function api.native(game,exe)
        if native_cache then return native_cache end
        local function pointer_at(address)
            return assert(api.pointer(api.read(address,8)), 'Native binding unavailable')
        end
        local bindings={
            {0x2ce1500,0x2874ed0,{{0x18,0x81e4d0},{0x38,0x8205b0},{0xa8,0x820720}}},
            {0x2ce1548,0x2875170,{{0,0x8557b0},{0x28,0x8565e0},{0x68,0x8573a0}}},
            {0x2ce14e8,0x2875080,{{0,0x826bc0},{0x68,0x805010},{0x80,0x880600}}},
        }
        for _,binding in ipairs(bindings) do
            local table_address=pointer_at(game+binding[1])
            assert(api.distance(table_address,exe)==binding[2], 'Unsupported native table')
            for _,entry in ipairs(binding[3]) do
                assert(api.distance(pointer_at(table_address+entry[1]),exe)==entry[2], 'Unsupported native function')
            end
        end
        assert(api.read(game+0xab9040,12)=='\072\139\196\072\137\088\008\072\137\104\032\086',
            'Native exit validator changed')
        assert(api.read(game+0xab5ba0,16)=='\064\085\083\086\087\065\084\065\086\065\087\072\141\108\036\208',
            'Native vault driver changed')
        if native_cache then return native_cache end
        local valid=ffi.cast('uint64_t (*)(uint32_t)',exe+0x81e4d0)
        local flags=ffi.cast('uint32_t (*)(uint32_t)',exe+0x8205b0)
        local motion=ffi.cast('void (*)(uint32_t,float *,float *)',exe+0x820720)
        local mover=ffi.cast('uint32_t (*)(uint32_t,uint32_t)',exe+0x8557b0)
        local dimensions=ffi.cast('void *(*)(uint32_t)',exe+0x8573a0)
        local position=ffi.cast('void (*)(uint32_t,float *)',exe+0x8565e0)
        local basis=ffi.cast('void *(*)(void *,const float *,const float *)',game+0x15b3180)
        local rotation=ffi.cast('void (*)(float *,const void *)',game+0x15ae780)
        -- RCX is unused in this build; RDX is the validated avatar entity.
        local classify=ffi.cast('int32_t (*)(void *,const void *,const float *,const float *)',game+0xab9040)
        local world_id=ffi.cast('uint32_t (*)(const void *)',exe+0x826bc0)
        local query=ffi.cast('uint32_t (*)(uint32_t,uint32_t,uint32_t,uint32_t,uint32_t,const void *,void *,uint32_t)',exe+0x880600)
        local drive=ffi.cast('void (*)(void *,float)',game+0xab5ba0)
        local detect=ffi.cast('uint32_t (*)(void *,float)',game+0xab7ec0)
        assert(api.read(game+0xab9870,16)=='\072\139\196\072\137\088\008\085\086\087\065\084\065\085\065\086',
            'Native approach geometry routine changed')
        -- RCX is unused. The remaining arguments and all outputs are private.
        local approach=ffi.cast('uint8_t (*)(void *,const void *,float *,float *,float *,float *)',game+0xab9870)
        local override=ffi.cast('void (*)(void *,const void *,const void *)',game+0x8492a0)
        local function aligned(size)
            local storage=ffi.new('uint8_t[?]',size+15)
            local address=tonumber(ffi.cast('uintptr_t',storage))
            return storage,storage+(16-address%16)%16
        end
        local native={}
        function native.ensure_override(manager,entity)
            assert(api.read(game+0x8492a0,16)=='\072\137\092\036\008\072\137\108\036\016\072\137\116\036\024\087',
                'Native avatar override routine changed')
            -- 510370 reads start/count at +4/+8. An empty modifier leaves all
            -- fields unchanged; 832d40 creates the entity-owned record if absent.
            local empty=ffi.new('uint32_t[3]')
            override(manager,entity,empty)
        end
        local function f32(n) return tonumber(ffi.new('float[1]',n)[0]) end
        function native.actor(id)
            if id==0xffffffff or valid(id)==0 then return {valid=false} end
            local first,second=ffi.new('float[3]'),ffi.new('float[3]')
            local bits=tonumber(flags(id))
            motion(id,first,second)
            if valid(id)==0 then return nil end
            local x,y,z=tonumber(first[0]),tonumber(first[1]),tonumber(first[2])
            return {valid=true,flags=bits,motion_squared=f32(f32(f32(y*y)+f32(x*x))+f32(z*z))}
        end
        -- The mover's dimensions only need to be readable: read into one
        -- reused buffer, without a string per check.
        local probe=ffi.new('uint8_t[20]')
        function native.mover_position(unit,name)
            local id=mover(unit,name)
            local data=dimensions(id)
            assert(data~=nil and api.read_into(data,20,probe),'Local mover unavailable')
            local out=ffi.new('float[3]')
            position(id,out)
            return {tonumber(out[0]),tonumber(out[1]),tonumber(out[2])}
        end
        function native.exit(entity,target,direction)
            local matrix_owner,matrix=aligned(64)
            local rotation_owner,quat=aligned(16)
            local forward=ffi.new('float[3]',direction)
            local up=ffi.new('float[3]',{0,0,1})
            local point=ffi.new('float[3]',target)
            basis(matrix,forward,up)
            rotation(ffi.cast('float *',quat),matrix)
            local result=tonumber(classify(nil,entity,point,ffi.cast('float *',quat)))
            -- Keep the backing allocations rooted until all native reads finish.
            assert(matrix_owner~=nil and rotation_owner~=nil)
            return result
        end
        function native.context_matches(controller_bytes)
            assert(#controller_bytes==0x2b0,'Invalid local controller copy')
            local owner,copy=aligned(0x2b0)
            ffi.copy(copy,controller_bytes,0x2b0)
            ffi.cast('uint32_t *',copy+4)[0]=0
            -- Stage zero only performs the original approach search and writes
            -- its new geometry into this private copy; it cannot start a vault.
            local result=tonumber(detect(copy,0))
            if ffi.cast('uint32_t *',copy+4)[0]~=1 then return false,'native_approach_blocked',nil,result end
            for offset=0x1e8,0x210,4 do
                local previous=ffi.new('float[1]')
                ffi.copy(previous,controller_bytes:sub(offset+1,offset+4),4)
                local current=tonumber(ffi.cast('float *',copy+offset)[0])
                local delta=math.abs(current-tonumber(previous[0]))
                if delta~=delta or delta>0.02 then
                    local fresh=ffi.string(copy,0x2b0)
                    assert(owner~=nil)
                    return false,'native_approach_geometry_changed',fresh
                end
            end
            local fresh=ffi.string(copy,0x2b0)
            assert(owner~=nil)
            return true,nil,fresh
        end
        function native.raised_approach(controller_bytes,unit,name,direction,reach)
            -- Reuse the native five-slice ledge search at the existing 2.5
            -- allowance, without temporarily changing real avatar settings.
            if #controller_bytes~=0x2b0 or type(reach)~='number' or reach~=reach
                or reach<=0 or reach>1.5 then return nil,'unsupported_raised_reach' end
            local norm=0
            for i=1,3 do
                local v=direction[i]
                if type(v)~='number' or v~=v or math.abs(v)>1.001 then return nil,'unsupported_raised_direction' end
                norm=norm+v*v
            end
            if math.abs(norm-1)>0.001 or math.abs(direction[3])>0.001 then return nil,'unsupported_raised_direction' end
            local id=mover(unit,name)
            local data=dimensions(id)
            local shape=data~=nil and api.read(data,20)
            if not shape then return nil,'raised_mover_unavailable' end
            local dims=ffi.new('float[5]');ffi.copy(dims,shape,20)
            local radius,minimum=tonumber(dims[3]),tonumber(dims[4])
            if radius~=radius or minimum~=minimum or radius<=0 or radius>0.5
                or minimum<0 or minimum>=2.5 then return nil,'unsupported_raised_mover' end
            local root=ffi.new('float[3]');position(id,root)
            for i=0,2 do
                if root[i]~=root[i] or math.abs(root[i])>=100000 then return nil,'raised_mover_unavailable' end
            end
            local args=ffi.new('uint8_t[52]')
            ffi.cast('uint32_t *',args)[0]=unit
            ffi.copy(args+4,root,12)
            ffi.copy(args+16,shape:sub(13,16),4)
            ffi.copy(args+20,shape:sub(9,12),4)
            ffi.copy(args+24,ffi.new('float[3]',direction),12)
            ffi.copy(args+36,ffi.new('float[3]',{minimum,2.5,reach}),12)
            local out=ffi.new('float[8]')
            if approach(nil,args,out,out+3,out+6,out+7)==0 then return nil,'raised_approach_no_ledge' end
            local owner,copy=aligned(0x2b0)
            ffi.copy(copy,controller_bytes,0x2b0)
            ffi.cast('uint32_t *',copy+4)[0]=1
            ffi.copy(copy+488,out,32)
            ffi.copy(copy+520,args+24,12)
            local fresh=ffi.string(copy,0x2b0)
            assert(owner~=nil)
            return fresh
        end
        function native.query_basis(direction)
            local owner,matrix=aligned(64)
            local forward=ffi.new('float[3]',direction)
            local up=ffi.new('float[3]',{0,0,1})
            basis(matrix,forward,up)
            local bytes=ffi.string(matrix,64)
            assert(owner~=nil)
            return bytes
        end
        function native.refresh_query(record,world)
            assert(#record==128,'Invalid query descriptor')
            -- Match the existing worker's 56-byte descriptor, using private
            -- copies and output storage. No scheduler records are modified.
            local record_owner,copy=aligned(128)
            local output_owner,out=aligned(48)
            ffi.copy(copy,record,128)
            local descriptor=ffi.new('uint64_t[7]')
            descriptor[2]=ffi.cast('uintptr_t',copy+16)
            descriptor[3]=ffi.cast('uintptr_t',copy+80)
            descriptor[4]=ffi.cast('uintptr_t',copy+92)
            descriptor[5]=ffi.cast('uint64_t *',copy+8)[0]
            local tail=ffi.cast('uint32_t *',descriptor)
            tail[12]=ffi.cast('uint32_t *',copy+116)[0]
            tail[13]=ffi.cast('uint32_t *',copy+108)[0]
            local count=tonumber(query(world_id(world),2,1,5,0x05a5271a,descriptor,out,1))
            local bytes=ffi.string(out,44)
            assert(record_owner~=nil and output_owner~=nil)
            return bytes,math.min(count,1)
        end
        function native.retry(controller)
            -- This is the game's original eligibility/check/start routine.
            -- Zero dt avoids advancing movement timers a second time.
            drive(controller,0)
        end
        native_cache=native
        return native
    end
    return api
end

end)()
local patch = (function()
local ffi, bit = require('ffi'), require('bit')
local M = {}
local INVALID = 0xffffffff
-- Fields decode from the string's bytes with arithmetic: no cdata, cast or copy
-- per field.
local function u32(b,o)
    local b0,b1,b2,b3=b:byte(o+1,o+4)
    return ((b3*256+b2)*256+b1)*256+b0
end
local function u16(b,o)
    local b0,b1=b:byte(o+1,o+2)
    return b1*256+b0 -- lint-ok: R14 slope_assist.lua decodes alike; each module loads and is tested alone
end
-- The float with bits w. A NaN loaded through a float cdata can become a
-- non-number value in the game's NaN-tagged LuaJIT; decoded here it is a plain
-- NaN.
local function float_bits(w)
    local e,m=bit.band(bit.rshift(w,23),0xff),bit.band(w,0x7fffff)
    local v
    if e==0xff then v=m==0 and math.huge or 0/0 elseif e==0 then v=m*2^-149 else v=(m+0x800000)*2^(e-150) end
    if w>=0x80000000 then return -v end
    return v
end
local function number(b,o) return float_bits(u32(b,o)) end
local function finite(n) return n == n and math.abs(n) < 100000 end
-- n rounded to float32 through one reused cell (its inputs are finite).
local rounding=ffi.new('float[1]')
local function f32(n) rounding[0]=n;return rounding[0] end
-- The low 32 bits of a*b for 32-bit a and b, exact in doubles: no 64-bit cdata.
local function low_product(a,b)
    local a_low,b_low=a%65536,b%65536
    return (a_low*b_low+(((a-a_low)/65536*b_low+a_low*(b-b_low)/65536)%65536)*65536)%4294967296
end
local function vector(b,o)
    local v = {number(b,o),number(b,o+4),number(b,o+8)}
    assert(finite(v[1]) and finite(v[2]) and finite(v[3]), 'Invalid vector')
    return v
end
local function normalize(v)
    local length = f32(math.sqrt(f32(f32(f32(v[1]^2)+f32(v[2]^2))+f32(v[3]^2))))
    if length < 0.0001 then return nil end
    return {f32(v[1]/length),f32(v[2]/length),f32(v[3]/length)}
end
local function pair(unit,actor)
    return ffi.string(ffi.new('uint32_t[2]',{unit,actor}),8)
end

-- Only guards independent of the eight-byte query fields belong to an epoch.
-- This allows restoration after manual input is released, but not after reuse.
function M.same_epoch(api,s)
    for _,g in ipairs(s.epoch) do
        if api.read(g.address,#g.bytes) ~= g.bytes then return false end
    end
    return true
end

-- Held writes: the stage-2 writes a previous check prepared, still in place.
-- The next check reads its hits as the restore would leave them, so its plan
-- is the one it would make after restoring. Writes start at a hit's +28.
local HIT_PAIR=28
local function unheld(held,bytes,address,offset)
    for _,w in ipairs(held.writes) do
        local finish=offset+#w.after
        if w.address==address+offset and bytes:sub(offset+1,finish)==w.after then
            return bytes:sub(1,offset)..w.before..bytes:sub(finish+1)
        end
    end
    return bytes
end
local function held_hit(held,bytes,address) return unheld(held,bytes,address,HIT_PAIR) end
local function held_controller(held,bytes,address)
    for slot=0,9 do bytes=unheld(held,bytes,address,0x30+44*slot+HIT_PAIR) end
    return bytes
end

-- Snapshot reads: each is complete or raises, and is a guard (verified again
-- before writes); epoch guards also decide whether held or prepared writes
-- still belong to this batch (M.same_epoch).
local function record(s,address,bytes,epoch)
    local guard={address=address,bytes=bytes}
    s.guards[#s.guards+1]=guard
    if epoch then s.epoch[#s.epoch+1]=guard end
    return guard
end
local function read(api,s,address,size,epoch)
    local bytes = assert(api.read(address,size),'Game data unavailable')
    assert(#bytes==size,'Short game read')
    record(s,address,bytes,epoch)
    return bytes
end
-- A guard read through a view holds the restored bytes; it is checked through
-- the same view (keeps) while the writes stay held.
local function read_held(api,s,held,view,address,size)
    local bytes = assert(api.read(address,size),'Game data unavailable')
    assert(#bytes==size,'Short game read')
    local guard=record(s,address,bytes)
    if held then bytes=view(held,bytes,address);guard.bytes=bytes;guard.view=view end
    return bytes
end
local function pointer(api,bytes,offset)
    return assert(api.pointer(bytes,offset),'Game pointer unavailable')
end
local function global(api,s,game,rva,epoch) return pointer(api,read(api,s,game+rva,8,epoch)) end
-- The value stored for key in a game hash map whose header bytes are given.
local function lookup(api,s,header,key,limit)
    local capacity,empty,mult=u32(header,8),u32(header,12),u32(header,16)
    assert(capacity<=limit and capacity>0 and bit.band(capacity,capacity-1)==0,'Unsupported map')
    local data=pointer(api,header)
    -- Keep the low product exact even for a full uint32 key/multiplier.
    -- It does not depend on the probe index, so it is computed once.
    local low=low_product(key,mult)
    for probe=0,math.min(capacity,128)-1 do
        local slot=bit.band(low+probe,capacity-1)
        local row=read(api,s,data+slot*8,8)
        if u32(row,0)==key then return u32(row,4) end
        if u32(row,0)==empty then return nil end
    end
    return nil
end

-- Counted per stage reached, as diagnostics.
local function count_stage(state,stage)
    if not state then return end
    local key='stage_'..stage
    state[key]=(state[key] or 0)+1
end

-- The mission gate, first in every snapshot. Outside a mission a check stops
-- here, so it must not allocate: the mode pointer and the mode record are read
-- with api.read_into into one reused buffer and decode in place. Their
-- addresses take the api's address values, made once per game base and per
-- mode record address. True in a mission; a snapshot that goes on records both
-- reads as its first guards (mission_guards).
local gate=ffi.new('uint8_t[80]')
local gate_words,gate_record=ffi.cast('uint32_t *',gate),gate+8
local GATE_POINTER=ffi.typeof('uint8_t *')
local gate_game,gate_global,gate_mode,gate_mode_address
local function mission_gate(api,game)
    if game~=gate_game then gate_game,gate_global=game,game+0x2ce1850 end
    assert(api.read_into(gate_global,8,gate),'Game data unavailable')
    -- The mode record's address (api.pointer's rule: at least 0x10000, below 2^47).
    local high=gate_words[1]
    local mode=high<0x8000 and high*4294967296+gate_words[0]
    assert(mode and mode>=0x10000,'Game pointer unavailable')
    if mode~=gate_mode then
        gate_mode,gate_mode_address=mode,type(game)=='number' and mode or ffi.cast(GATE_POINTER,mode)
    end
    assert(api.read_into(gate_mode_address,0x44,gate_record),'Game data unavailable')
    return gate_words[4]~=0 and gate_words[18]>=1 and gate_words[18]<=7
end
local function mission_guards(s)
    record(s,gate_global,ffi.string(gate,8))
    record(s,gate_mode_address,ffi.string(gate_record,0x44))
end

-- The local player's unit reference (in a mission), else nil and why.
local function local_unit(api,s,game)
    local pm=global(api,s,game,0x2ce1618,true)
    local counts=read(api,s,pm+0x84,8)
    assert(u32(counts,0)<=4 and u32(counts,4)<=4,'Unsupported player count')
    if u32(counts,0)==0 or u32(counts,4)==0 then return nil,'waiting_for_local_player' end
    local player=read(api,s,pointer(api,read(api,s,pm+0xe8,8,true)),24,true)
    if bit.band(player:byte(21),1)==0 then return nil,'waiting_for_local_player' end
    local unit_ref=u32(read(api,s,pm+0x3a8,4,true),0)
    if unit_ref==0x7fff then return nil,'waiting_for_local_avatar' end
    return unit_ref
end

-- The local avatar entity of unit_ref: its address and bytes, else nil and why.
local function local_entity(api,s,owner,unit_ref)
    local ei=lookup(api,s,read(api,s,owner+0xf24990,20),unit_ref,1048576)
    if not ei or ei==INVALID then return nil,'waiting_for_local_avatar' end
    assert(ei<262144,'Unsupported entity index')
    local entity_address=owner+0xf349e0+ei*24
    local entity=read(api,s,entity_address,24,true)
    -- Resource 0x4d1c334d294dfa97, kept as bytes to avoid floating-point hashing.
    assert(entity:sub(1,8)=='\151\250\077\041\077\051\028\077','Unsupported avatar resource')
    if bit.band(entity:byte(21),1)==0 then return nil,'waiting_for_local_avatar' end
    return entity_address,entity
end

-- The avatar index of id, checked against the avatar count and the registry.
local function avatar_index(api,s,manager,id,entity)
    local ai=lookup(api,s,read(api,s,manager+0xf8,20),id,64)
    if not ai or ai==INVALID then return nil end
    local n=u32(read(api,s,manager+0x6c,4),0)
    assert(n<=8 and ai<n,'Unsupported avatar index')
    assert(read(api,s,pointer(api,read(api,s,manager+0x110+ai*8,8,true)),24,true)==entity,'Avatar registry mismatch')
    return ai
end

-- The epoch's query IDs (and, at stage 2, its phase) become epoch guards; true
-- when the manual vault input is held.
local function manual_input(api,s,manager,ai)
    -- The late retry temporarily returns stage 3 to stage 2. The query IDs,
    -- entity and records still define the epoch across that native call.
    read(api,s,s.controller+8,40,true)
    if s.stage==2 then read(api,s,s.controller+4,4,true) end
    s.input_address=manager+0x150+ai*0xa7aec+0x1b68+14*32
    s.manual_bytes=read(api,s,s.input_address,1)
    if s.manual_bytes:byte()==0 then return false end
    s.manual=true
    return true
end

-- Match A88020/A88160 before re-entering the original local driver.
local function driver_refuses(flags,controller)
    local climbing=bit.band(u32(flags,12),0x200)~=0
    local excluded=bit.band(u32(flags,0),0x404000)~=0
        or bit.band(u32(flags,4),0x8000000)~=0
        or bit.band(u32(flags,8),0x20084000)~=0
        or bit.band(u32(flags,12),0x5181c)~=0
        or bit.band(u32(flags,16),9)~=0
    return climbing or excluded or bit.band(u32(flags,0),2)==0 or controller:byte(0x215)~=0
end

-- The local controller (as the restore of held writes would leave it) and the
-- avatar's movement flags; nil at stage 3 while the native driver would refuse
-- a retry.
local function controller_flags(api,s,held,manager,ai)
    local controller=read_held(api,s,held,held_controller,s.controller,0x2b0)
    s.controller_bytes=controller
    s.flags_address=manager+ai*0x1240+0x53e888
    local flags=read(api,s,s.flags_address,24)
    if s.stage~=3 then return flags end
    -- +532 is pending climb readiness. +533 only reports an automatic
    -- step; A8A710 can retain it across later failed detections. A88160
    -- does not use that report as an eligibility veto. Never clear it.
    s.prior_step_report=controller:byte(0x216)~=0
    if driver_refuses(flags,controller) then return nil end
    return flags
end

-- The query scheduler, its job table and query count. At stage 3, Lua runs
-- after consumption: retained descriptors and private discovery queries need
-- an idle scheduler (else nil and why).
local function query_scheduler(api,s,game,manager)
    local scheduler=pointer(api,read(api,s,manager+0x28,8,true))
    local jobs=read(api,s,scheduler+0x40000,100,true)
    local total=u32(jobs,0)
    if s.stage~=3 then
        assert(total>0 and total<=2048,'Unsupported query count')
        return scheduler,jobs,total
    end
    if total~=0 then return nil,'waiting_for_idle_query_scheduler' end
    for job=0,7 do
        if u32(jobs,12+job*12)~=1 then return nil,'waiting_for_query_workers' end
    end
    s.world=global(api,s,game,0x2e271f8,true)
    return scheduler,jobs,total
end

-- True when a completed worker job covers query.
local function completed(jobs,query)
    local done=false
    for job=0,7 do
        local start,finish,state=u32(jobs,4+job*12),u32(jobs,8+job*12),u32(jobs,12+job*12)
        if query-1>=start and query-1<finish and state==1 then done=true end
    end
    return done
end

-- The scheduler record of query for hit slot (address, bytes, hit address),
-- else nil and why. Ownership must be established for the whole batch before
-- any shared descriptor becomes a guard, so this read is not one. Reused
-- records are never our epoch: only discovery at stage 3 rebuilds them.
local function owned_record(api,s,scheduler,query,slot,discovery)
    local address=scheduler+(query-1)*128
    local record=assert(api.read(address,128),'Game data unavailable')
    assert(#record==128,'Short game read')
    local hit_address=s.controller+0x30+44*slot
    local output=api.pointer(record)
    if not output or api.distance(output,hit_address)~=0 then
        if s.stage~=3 then error('Query output is not local controller data') end
        if discovery~=true then return nil,'retained_query_reused' end
        s.rebuild_queries=true
    end
    return {address=address,bytes=record,hit_address=hit_address}
end

-- The ten query records of the batch, each owned by its local hit slot, else
-- nil and why.
local function query_records(api,s,epoch,scheduler,jobs,total,discovery)
    local seen,records={},{}
    for slot=0,9 do
        local query=u32(epoch,4+slot*4)
        assert(query>0 and query<=(s.stage==3 and 2048 or total) and not seen[query],'Unsupported query ID')
        seen[query]=true
        if s.stage==2 and not completed(jobs,query) then return nil,'waiting_for_query_workers' end
        local row,why=owned_record(api,s,scheduler,query,slot,discovery)
        if not row then return nil,why end
        records[#records+1]=row
    end
    return records
end

-- A9BE10 / 175BA70's fixed query metadata for a rebuilt slot. Geometry is
-- populated only after a successful fresh native approach in M.refresh.
local function query_template(row,entity)
    local template=ffi.new('uint8_t[128]')
    ffi.cast('uintptr_t *',template)[0]=ffi.cast('uintptr_t',row.hit_address)
    ffi.cast('uint32_t *',template+0x68)[0]=0x05a5271a
    ffi.cast('uint32_t *',template+0x74)[0]=u32(entity,12)
    ffi.cast('uint16_t *',template+0x78)[0]=1
    template[0x7c],template[0x7d],template[0x7e]=2,1,5
    return ffi.string(template,128),0
end

-- A slot's own descriptor, verified, and its result count.
local function query_descriptor(api,s,row,entity)
    local record=row.bytes
    assert(read(api,s,row.address,128,true)==record,'Query changed during snapshot')
    assert(u32(record,0x68)==0x05a5271a and u32(record,0x74)==u32(entity,12), 'Query identity mismatch')
    assert(record:byte(0x7d)==2 and record:byte(0x7e)==1 and record:byte(0x7f)==5,'Unsupported query type')
    assert(u16(record,0x78)==1 and u16(record,0x7a)<=1,'Unsupported query capacity')
    if s.stage==3 then
        assert(record:sub(9,16)==string.rep('\0',8) and u32(record,0x6c)==0,
            'Unsupported retained query options')
    end
    return record,u16(record,0x7a)
end

-- Each slot's descriptor and local hit, read as the restore of held writes
-- would leave it.
local function read_hits(api,s,held,records,entity)
    for i,row in ipairs(records) do
        local record,count
        if s.rebuild_queries then record,count=query_template(row,entity)
        else record,count=query_descriptor(api,s,row,entity) end
        local hit=read_held(api,s,held,held_hit,row.hit_address,44)
        s.hits[#s.hits+1]={slot=i-1,address=row.hit_address,bytes=hit,
            count=count,position=s.rebuild_queries and {0,0,0} or vector(hit,0),normal_z=number(hit,20),
            unit=u32(hit,28),actor=u32(hit,32),record=record}
    end
end

-- The effective settings record: the avatar's override, or the shared
-- component record of its resource.
local function vault_settings(api,s,manager,owner,id,entity)
    local override=lookup(api,s,read(api,s,manager+0x547cb0,20),id,64)
    if override and override~=INVALID then
        assert(override<8,'Unsupported settings override')
        return read(api,s,manager+0x547d64+override*0x354,852)
    end
    local component=pointer(api,read(api,s,owner+0xf14680,8))
    -- This resource's two-slot map is verified at runtime, not assumed index zero.
    local map=read(api,s,component,32)
    local index
    for slot=0,1 do
        if map:sub(slot*16+1,slot*16+8)==entity:sub(1,8) then index=u32(map,slot*16+8) end
    end
    assert(index and index<1,'Unsupported AvatarComponent map')
    return read(api,s,component+32+index*852,852)
end

-- The cosine of the settings' surface angle, in float32 steps.
local function surface_threshold(settings)
    local angle=number(settings,0x98)
    assert(angle>0 and angle<90,'Unsupported surface angle')
    return f32(math.cos(f32(angle*f32(math.pi/180))))
end

-- The local movement and mover records.
local function movement_records(api,s,game,id)
    local movement=global(api,s,game,0x2ce1708)
    local mi=lookup(api,s,read(api,s,movement+0x48a0,20),id,1048576)
    assert(mi and mi~=INVALID and mi<8192,'Movement record unavailable')
    local move=read(api,s,pointer(api,read(api,s,movement+0x48c8,8))+mi*132,132)
    local mover=read(api,s,pointer(api,read(api,s,movement+0x48d0,8))+mi*164,164)
    return move,mover
end

-- Ground contact, the vault height it allows and the native mover position.
local function mover_state(api,s,game,exe,settings,flags,move)
    local ground=bit.band(u32(flags,8),4)==0 and bit.band(u32(flags,12),0x26)==0 and move:byte(16)==0
    s.max_height=number(settings,ground and 0x104 or 0x108)
    s.ground=ground
    assert(s.max_height>0 and s.max_height<=3,'Unsupported vault height')
    s.native=assert(api.native(game,exe),'Native validation unavailable')
    s.ground_reach=number(settings,0x10c)
    s.root=s.native.mover_position(s.unit,s.mover_name)
    assert(s.root and finite(s.root[1]) and finite(s.root[2]) and finite(s.root[3]),'Mover position unavailable')
end

-- The horizontal camera direction, or the avatar's own motion direction while
-- its movement flags select it; nil without length.
local function vault_direction(api,s,game,manager,ai,id,flags)
    local camera=vector(read(api,s,global(api,s,game,0x2e287d0)+0x1c,12),0)
    camera[3]=0
    local direction=normalize(camera)
    if bit.band(u32(flags,8),0x8000)~=0 then
        -- A6B790 uses this entity's bit 79 to choose its motion direction.
        assert(u32(read(api,s,manager+ai*0x1240+0x53e15c,4),0)==id,'Direction state identity mismatch')
        direction=normalize(vector(read(api,s,manager+0x150+ai*0xa7aec+171698*4,12),0))
    end
    return direction
end

-- The local avatar from the mission gate down: owner, entity address and bytes,
-- manager and avatar index, else nil and why.
local function local_avatar(api,s,game)
    if not mission_gate(api,game) then return nil,'waiting_for_mission' end
    mission_guards(s)
    local unit_ref,why=local_unit(api,s,game)
    if not unit_ref then return nil,why end
    local owner=global(api,s,game,0x2ce41b8,true)
    local entity_address,entity=local_entity(api,s,owner,unit_ref)
    if not entity_address then return nil,entity end
    local manager=global(api,s,game,0x2ce1ee0,true)
    local ai=avatar_index(api,s,manager,u32(entity,8),entity)
    if not ai then return nil,'waiting_for_local_avatar' end
    return owner,entity_address,entity,manager,ai
end
-- The same from the slope snapshot of this check (avatar), which resolved this
-- chain with the same checks: its reads become this snapshot's guards (and
-- epoch guards) as the vault's own reads would, and are verified again before
-- any write like every other guard.
local function slope_avatar(s,avatar)
    for _,g in ipairs(avatar.identity) do record(s,g.address,g.bytes,g.epoch) end
    return avatar.key.owner,avatar.entity,avatar.entity_bytes,avatar.key.manager,avatar.ai
end

-- avatar: the slope snapshot of this check, when it resolved the local avatar
-- in full, else nil.
function M.snapshot(api,game,exe,state,discovery,held,avatar)
    local s = {epoch={},guards={},hits={}}
    local owner,entity_address,entity,manager,ai
    if avatar then owner,entity_address,entity,manager,ai=slope_avatar(s,avatar)
    else owner,entity_address,entity,manager,ai=local_avatar(api,s,game) end
    if not owner then return nil,entity_address end
    local id=u32(entity,8)
    local why
    s.controller=manager+0x53e1b8+ai*0x1240
    assert(u32(read(api,s,s.controller+0x2ac,4,true),0)==id,'Controller identity mismatch')
    local epoch=read(api,s,s.controller+4,44)
    s.stage=u32(epoch,0)
    count_stage(state,s.stage)
    if s.stage~=2 and s.stage~=3 then return nil,'waiting_for_vault_query' end
    if not manual_input(api,s,manager,ai) then return nil,'waiting_for_manual_vault' end
    local flags=controller_flags(api,s,held,manager,ai)
    if not flags then return nil,'native_vault_state_retained' end
    local scheduler,jobs,total=query_scheduler(api,s,game,manager)
    if not scheduler then return nil,jobs end
    local records
    records,why=query_records(api,s,epoch,scheduler,jobs,total,discovery)
    if not records then return nil,why end
    read_hits(api,s,held,records,entity)
    local settings=vault_settings(api,s,manager,owner,id,entity)
    s.normal_threshold=surface_threshold(settings)
    local move,mover=movement_records(api,s,game,id)
    s.unit=u32(entity,12);s.mover_name=u32(mover,76)
    mover_state(api,s,game,exe,settings,flags,move)
    local direction=vault_direction(api,s,game,manager,ai,id,flags)
    if not direction then return nil,'waiting_for_direction' end
    s.direction=direction
    s.entity=entity_address
    s.query_bytes=epoch
    return s
end

-- Reuse the native exit validator, then expose just one validated result to the
-- existing selector. Normal metadata is preferred; fallback is manual only.
function M.plan(s,trace)
    if not s or not s.manual then return {} end
    local fallback,chosen
    for _,hit in ipairs(s.hits) do
        local height=f32(hit.position[3]-s.root[3])
        local row
        if trace then
            row={slot=hit.slot,count=hit.count,unit=hit.unit,normal_z=hit.normal_z,height=height,
                normal_threshold=s.normal_threshold,max_height=s.max_height,min_height=s.min_height,
                position=hit.position,source_height=number(hit.record,72)-s.root[3],
                target_height=number(hit.record,100)-s.root[3]}
            trace[#trace+1]=row
        end
        local reason
        if hit.count~=1 or hit.unit==0 then reason='no_hit'
        elseif not finite(hit.normal_z) or hit.normal_z<=s.normal_threshold then reason='surface_angle'
        elseif s.min_height and height<s.min_height then reason='below_ledge_minimum'
        elseif height>s.max_height then reason='height'
        else
            local actor=s.native.actor(hit.actor)
            assert(actor and type(actor.valid)=='boolean','Actor validation unavailable')
            local speed=actor.motion_squared or 0
            assert(finite(speed) and speed>=0,'Invalid actor motion')
            if not actor.valid or speed<=1 then
                local veto=actor.valid and bit.band(actor.flags,0x100000)~=0
                if row then row.actor_valid=actor.valid;row.motion_squared=speed;row.metadata_veto=veto end
                if not veto or not fallback then
                    local exit=s.native.exit(s.entity,hit.position,s.direction)
                    assert(exit==3 or exit==4 or exit==5,'Unsupported exit result')
                    if row then row.exit=exit end
                    if exit~=5 then
                        reason=veto and 'metadata_fallback' or 'accepted'
                        if veto then fallback=hit else chosen=hit end
                    else reason='native_exit' end
                else reason='fallback_already_found' end
            else
                reason='actor_motion'
                if row then row.actor_valid=actor.valid;row.motion_squared=speed end
            end
        end
        if row then row.result=reason end
        if chosen then break end
    end
    local metadata=false
    if not chosen then chosen=fallback;metadata=chosen~=nil end
    if not chosen then return {} end
    local writes={}
    for _,hit in ipairs(s.hits) do
        local original=hit.bytes:sub(29,36)
        local replacement
        if hit==chosen then
            replacement=metadata and pair(hit.unit,INVALID) or original
        elseif hit.slot<chosen.slot and hit.count==1 and hit.unit~=0 then
            replacement=pair(0,hit.actor)
        else replacement=original end
        if replacement~=original then
            writes[#writes+1]={address=hit.address+28,before=original,after=replacement}
        end
    end
    return writes,{slot=chosen.slot,metadata=metadata}
end

-- Every query write lies in the local controller, inside [controller,
-- controller+0x1e8): the phase at +4 and the ten 44-byte hits from +0x30. One
-- protection query covers a whole commit or restore.
local CONTROLLER_SPAN=0x1e8
local function write_controller(api,controller,writes,field)
    local changes={}
    for i,w in ipairs(writes) do changes[i]={api.distance(w.address,controller),w[field]} end
    return api.write_batch(controller,CONTROLLER_SPAN,changes)
end

-- The first write whose bytes in memory differ from its field, or nil.
local function first_mismatch(api,writes,field)
    for _,w in ipairs(writes) do
        if api.read(w.address,#w[field])~=w[field] then return w end
    end
    return nil
end

-- Writes the original bytes back wherever a write is still in place, with one
-- protection query, and reads each back.
local function restore_in_place(api,pending)
    local back={}
    for i=#pending.writes,1,-1 do
        local w=pending.writes[i]
        if api.read(w.address,#w.after)==w.after then back[#back+1]=w end
    end
    if #back==0 then return true end
    return write_controller(api,pending.snapshot.controller,back,'before') and not first_mismatch(api,back,'before')
end

function M.restore(api,pending)
    if not pending or not M.same_epoch(api,pending.snapshot) then return true end
    return restore_in_place(api,pending)
end

-- A failed write may land in part: a byte mix of the original and the new
-- bytes is ours to undo. False only when undoing it failed.
local function undo_partial(api,s,w)
    local current=api.read(w.address,#w.before)
    if not current or current==w.before or current==w.after or not M.same_epoch(api,s) then return true end
    for j=1,#current do
        local c=current:byte(j)
        if c~=w.before:byte(j) and c~=w.after:byte(j) then return true end
    end
    return api.write(w.address,w.before) and api.read(w.address,#w.before)==w.before
end

-- Writes a commit with one protection query: the epoch, the input and every
-- original are verified first, each write is read back after. pending.writes
-- gets every write before the attempt, so a rollback can undo any of them.
-- Returns nil when all landed, else 'changed' (nothing written: the data
-- changed, or protection was refused as the separate check used to report),
-- 'write' (a write failed) or 'restore' (undoing a partial write failed).
local function commit(api,s,pending,writes)
    if not M.same_epoch(api,s) or api.read(s.input_address,1)~=s.manual_bytes
        or first_mismatch(api,writes,'before') then return 'changed' end
    for _,w in ipairs(writes) do pending.writes[#pending.writes+1]=w end
    local written,landed=write_controller(api,s.controller,writes,'after')
    if not written and landed==0 and not api.writable_data(s.controller,CONTROLLER_SPAN) then return 'changed' end
    local failed=writes[landed+1]
    if written then failed=first_mismatch(api,writes,'after') end
    if not failed then return nil end
    return undo_partial(api,s,failed) and 'write' or 'restore'
end

-- Stage 2 is inside native frame processing, which a Lua update can miss
-- entirely. At stage 3, cast the retained local query shapes again into private
-- storage, then let the original driver consume one freshly validated result.
-- A8A140's ten-query geometry, reconstructed privately from a successful fresh
-- A8A710 approach. Calling the producer itself would modify the shared scheduler.

-- The fresh approach of a complete local controller copy with finite
-- geometry: its endpoints, direction, span, width and length, else nil.
local function fresh_geometry(s,fresh)
    if type(fresh)~='string' or #fresh~=0x2b0 or u32(fresh,4)~=1
        or u32(fresh,684)~=u32(s.controller_bytes,684) or #s.hits~=10 then return nil end
    for offset=488,528,4 do
        if not finite(number(fresh,offset)) then return nil end
    end
    local first,last,direction=vector(fresh,488),vector(fresh,500),vector(fresh,520)
    local dx,dy,dz=f32(last[1]-first[1]),f32(last[2]-first[2]),f32(last[3]-first[3])
    local length=f32(math.sqrt(f32(f32(f32(dy*dy)+f32(dx*dx))+f32(dz*dz))))
    return first,last,direction,number(fresh,512),number(fresh,516),length
end

-- True when span, width, length and a horizontal unit direction fit the batch.
local function geometry_fits(span,width,length,direction)
    local norm=direction[1]^2+direction[2]^2+direction[3]^2
    return not (span<=0.1 or span>3.5 or width<=0 or width>1 or length<0.05 or length>2
        or math.abs(norm-1)>0.001 or math.abs(direction[3])>0.001)
end

-- Native forward/up basis must remain horizontal and orthonormal. Ignore
-- its translation, which each query below replaces explicitly.
local function basis_matches(matrix,direction)
    if type(matrix)~='string' or #matrix~=64 then return false end
    local expected={direction[2],-direction[1],0,0,direction[1],direction[2],0,0,0,0,1,0}
    for i,want in ipairs(expected) do
        local actual=number(matrix,(i-1)*4)
        if not finite(actual) or math.abs(actual-want)>0.001 then return false end
    end
    return true
end

-- The first and last source positions: half a slice in from each endpoint,
-- lowered by the box's vertical half-extent.
local function endpoints(first,last,direction,depth)
    local near,far={},{}
    for axis=1,3 do
        local shift=axis==3 and -f32(0.05) or 0
        near[axis]=f32(f32(f32(depth*direction[axis])+first[axis])+shift)
        far[axis]=f32(f32(last[axis]-f32(depth*direction[axis]))+shift)
    end
    return near,far
end

-- One slot's private descriptor: the retained record with the native basis,
-- the interpolated source and target, and the slice box.
local function reprojected_record(hit,matrix,near,far,span,width,depth)
    local record=ffi.new('uint8_t[128]');ffi.copy(record,hit.record,128)
    ffi.copy(record+16,matrix,64)
    local source,target=ffi.cast('float *',record+64),ffi.cast('float *',record+92)
    local t=f32(hit.slot/9)
    for axis=1,3 do
        local start=f32(f32(near[axis]*f32(1-t))+f32(far[axis]*t))
        source[axis-1]=start
        target[axis-1]=axis==3 and f32(f32(-span+start)+f32(f32(0.05)+f32(0.05))) or start
    end
    source[3]=1
    ffi.copy(record+80,ffi.new('float[3]',{f32(width*0.5),depth,f32(0.05)}),12)
    return ffi.string(record,128)
end

function M.reproject(s,fresh)
    local first,last,direction,span,width,length=fresh_geometry(s,fresh)
    if not first or not geometry_fits(span,width,length,direction) or not s.native.query_basis then
        return nil,'unsupported_fresh_approach'
    end
    local matrix=s.native.query_basis(direction)
    if not basis_matches(matrix,direction) then return nil,'unsupported_query_basis' end
    local depth=f32(f32(length/10)*0.5)
    local near,far=endpoints(first,last,direction,depth)
    local records={}
    for i,hit in ipairs(s.hits) do
        if hit.slot~=i-1 or #hit.record~=128 then return nil,'unsupported_fresh_approach' end
        records[i]=reprojected_record(hit,matrix,near,far,span,width,depth)
    end
    for i,record in ipairs(records) do s.hits[i].record=record end
    s.controller_bytes=fresh;s.reprojected=true
    return true
end

-- Rebuilt queries: no shared descriptor survives, so neither an old hit count
-- nor old geometry may authorize a cast, including the raised-top fallback.
-- True, else nil, why and the native approach reason.
local function rebuilt_context(s,state,matched,why,fresh)
    if not fresh or (not matched and why~='native_approach_geometry_changed') then
        return nil,'fresh_approach_unavailable',why
    end
    matched,why=M.reproject(s,fresh)
    if not matched then return nil,why or 'native_approach_changed_or_blocked' end
    state.query_rebuilds=(state.query_rebuilds or 0)+1
    state.context_reprojections=(state.context_reprojections or 0)+1
    return true
end

-- The native approach context of a refresh: true when the retained (or
-- reprojected) geometry may be cast, else nil, why and, for rebuilt queries,
-- the native approach reason.
local function approach_context(s,state)
    local matched,why,fresh,code=s.native.context_matches(s.controller_bytes)
    state.last_approach_reason=why or (matched and 'matched' or 'unknown')
    state.last_approach_code=code
    if s.rebuild_queries then return rebuilt_context(s,state,matched,why,fresh) end
    if not matched and why=='native_approach_geometry_changed' and fresh then
        matched,why=M.reproject(s,fresh)
        if matched then state.context_reprojections=(state.context_reprojections or 0)+1 end
    end
    if not matched then return nil,why or 'native_approach_changed_or_blocked' end
    return true
end

-- True when a query's source and target stay near and in front of the
-- native mover (1.5 units horizontally, 5 vertically).
local function cast_in_reach(s,record)
    for _,offset in ipairs({64,92}) do
        local v=vector(record,offset)
        local dx,dy=v[1]-s.root[1],v[2]-s.root[2]
        if dx*dx+dy*dy>2.25 or math.abs(v[3]-s.root[3])>5
            or dx*s.direction[1]+dy*s.direction[2]<-0.15 then
            return false
        end
    end
    return true
end

-- Casts a slot's query again into private storage; the hit takes the result.
local function recast(s,state,hit)
    local bytes,count=s.native.refresh_query(hit.record,s.world)
    assert(type(bytes)=='string' and #bytes==44 and (count==0 or count==1),'Invalid refreshed query')
    state.fresh_queries=(state.fresh_queries or 0)+1
    hit.bytes,hit.count=bytes,count
    hit.position,hit.normal_z=vector(bytes,0),number(bytes,20)
    hit.unit,hit.actor=u32(bytes,28),u32(bytes,32)
end

function M.refresh(s,state)
    local ready,why,approach=approach_context(s,state)
    if not ready then return nil,why,approach end
    local originals={}
    for i,hit in ipairs(s.hits) do
        originals[i]=hit.bytes
        if s.rebuild_queries or hit.count==1 then
            -- Retained geometry must remain near and in front of this avatar.
            -- A fresh cast prevents old hits from surviving removed obstacles.
            if not cast_in_reach(s,hit.record) then return nil,'retained_query_out_of_reach' end
            recast(s,state,hit)
        end
    end
    return originals
end

-- True when a hit lies beyond the 1.5-unit horizontal reach or behind the
-- avatar's direction.
local function out_of_reach(s,hit)
    local dx,dy=hit.position[1]-s.root[1],hit.position[2]-s.root[2]
    return dx*dx+dy*dy>2.25 or dx*s.direction[1]+dy*s.direction[2]<-0.15
end

-- True while every snapshot guard still holds its bytes.
local function guards_hold(api,s)
    for _,g in ipairs(s.guards) do
        if api.read(g.address,#g.bytes)~=g.bytes then return false end
    end
    return true
end

-- Read-only, fresh native probes decide whether an input window needs any
-- assistance. Ordinary candidates take priority. Nothing is slowed or changed
-- merely because Space was pressed, or because old retained hits look usable.

-- The candidate search's snapshot of a consumed query for the avatar the
-- slope check verified, else nil and why. Match the main query path's
-- handling of transient unavailable snapshots. Native validation errors after
-- a snapshot still reach loader cleanup.
local function candidate_snapshot(api,game,exe,state,owner)
    local ok,s,why=pcall(M.snapshot,api,game,exe,nil,true)
    if not ok then state.candidate_error=tostring(s);return nil,'candidate_snapshot_unavailable' end
    if not s or s.stage~=3 then return nil,why or 'waiting_for_consumed_query' end
    if api.distance(s.entity,owner.entity)~=0 then return nil,'candidate_identity_changed' end
    return s
end

-- True when a grounded avatar at the default climb height may replace a
-- blocked, changed, out-of-reach or missing ordinary approach with the
-- independent raised search.
local function raised_wanted(s,originals,reason,approach_reason)
    if originals or not s.ground or not (math.abs(s.max_height-1.95)<0.001) or not s.native.raised_approach then
        return false
    end
    return reason=='native_approach_blocked' or reason=='native_approach_geometry_changed'
        or reason=='retained_query_out_of_reach'
        or reason=='fresh_approach_unavailable' and approach_reason=='native_approach_blocked'
end

-- The raised search's fresh approach, reprojected into the private queries,
-- else nil and why.
local function raised_context(s,state)
    local fresh,why=s.native.raised_approach(s.controller_bytes,s.unit,s.mover_name,s.direction,s.ground_reach)
    if not fresh then return nil,why or 'raised_approach_unavailable' end
    local ready;ready,why=M.reproject(s,fresh)
    if not ready then return nil,why end
    state.raised_approach_rebuilds=(state.raised_approach_rebuilds or 0)+1
    return fresh
end

-- A higher-top discovery cast does not consume retained hits. Requiring
-- the original low-height approach to succeed first makes that discovery
-- circular. Only this private, bounded search may continue on a context
-- rejection; ordinary/slope retries require matched or freshly rebuilt geometry.
local function context_usable(originals,reason,raised_fresh)
    return originals or reason=='native_approach_blocked' or reason=='native_approach_geometry_changed'
        or reason=='native_approach_changed_or_blocked' or raised_fresh
end

-- The diagnostics trace of one candidate search.
local function new_trace(api,s,originals,reason)
    return {time=api.time(),root=s.root,direction=s.direction,ground=s.ground,
        context=originals and (s.reprojected and 'reprojected' or 'matched') or reason,
        passes={ordinary={},slope={},raised={}}}
end

-- The steep-slope selection, or nil and 'ordinary_candidate_retained' while
-- an ordinary candidate exists.
local function slope_pass(s,trace)
    local _,ordinary=M.plan(s,trace.passes.ordinary)
    if ordinary then return nil,'ordinary_candidate_retained' end
    s.normal_threshold=f32(math.cos(f32(65*f32(math.pi/180))))
    local _,selected=M.plan(s,trace.passes.slope)
    return selected
end

-- True when a downward cast's start and target stay near and in front of the
-- native mover and the start lies above the target.
local function raised_in_reach(s,start,target)
    local dx,dy=start[1]-s.root[1],start[2]-s.root[2]
    local tx,ty=target[1]-s.root[1],target[2]-s.root[2]
    return not (dx*dx+dy*dy>2.25 or tx*tx+ty*ty>2.25 or start[3]<target[3]
        or math.abs(start[3]-s.root[3])>5 or math.abs(target[3]-s.root[3])>5
        or dx*s.direction[1]+dy*s.direction[2]<-0.15
        or tx*s.direction[1]+ty*s.direction[2]<-0.15)
end

-- The room a query box needs above a top at the allowed surface angle: its
-- vertical extent plus its horizontal footprint's rise, else nil.
local function probe_clearance(record,baseline)
    local size=vector(record,80)
    for _,dimension in ipairs(size) do
        if dimension<=0 or dimension>0.5 then return nil end
    end
    local extent=math.abs(number(record,24))*size[1]
        +math.abs(number(record,40))*size[2]+math.abs(number(record,56))*size[3]
    local horizontal=0
    for axis=0,2 do
        local x,y=number(record,16+axis*16),number(record,20+axis*16)
        horizontal=horizontal+math.sqrt(x*x+y*y)*size[axis+1]
    end
    if not finite(extent) or extent<=0 or extent>0.25
        or not finite(horizontal) or horizontal<=0 or horizontal>0.5
        or baseline<0.7 or baseline>1 then return nil end
    return extent+horizontal*math.sqrt(math.max(0,1-baseline*baseline))/baseline+0.01
end

-- Raise only the start of a private downward cast; leave its end, shape,
-- filter, ignored unit and returned normals untouched. Anchor the discovery
-- ceiling to the current native mover, not the potentially clipped/low
-- retained approach ceiling, and reserve space for the full box over a top at
-- the allowed surface angle. True, else nil and why.
local function raise_hit(s,state,hit,baseline)
    local start,target=vector(hit.record,64),vector(hit.record,92)
    if not raised_in_reach(s,start,target) then return nil,'raised_query_out_of_reach' end
    local clearance=probe_clearance(hit.record,baseline)
    if not clearance then return nil,'unsupported_probe_extent' end
    local ceiling=f32(s.root[3]+s.max_height+clearance)
    if target[3]>=ceiling then return nil,'raised_query_out_of_reach' end
    local raised=ffi.string(ffi.new('float[1]',ceiling),4)
    local record=hit.record:sub(1,72)..raised..hit.record:sub(77)
    local b,count=s.native.refresh_query(record,s.world)
    assert(type(b)=='string' and #b==44 and (count==0 or count==1),'Invalid raised query')
    state.raised_queries=(state.raised_queries or 0)+1
    hit.bytes,hit.count=b,count;hit.position,hit.normal_z=vector(b,0),number(b,20)
    hit.unit,hit.actor=u32(b,28),u32(b,32)
    hit.record=record -- Private trace reports the cast actually performed.
    return true
end

-- The higher-top selection: every slot cast again from above the 2.5-unit
-- allowance, at the original surface angle. Nil and why when a slot cannot be.
local function ledge_pass(s,state,trace,baseline)
    s.normal_threshold=baseline;s.max_height=2.5;s.min_height=0.5
    for _,hit in ipairs(s.hits) do
        local raised,why=raise_hit(s,state,hit,baseline)
        if not raised then return nil,why end
    end
    local _,selected=M.plan(s,trace.passes.raised)
    state.raised_trace=trace
    return selected
end

-- The assisted candidate: kind ('slope' or 'ledge') and selection, or nil, nil
-- and why when a pass gives up. The ledge pass runs for a grounded avatar at
-- the default climb height when no steep candidate was selected.
local function assisted_selection(s,state,trace,originals)
    local baseline=s.normal_threshold
    local selected,why
    if originals then
        selected,why=slope_pass(s,trace)
        if why then return nil,nil,why end
    end
    if selected or not s.ground or not (math.abs(s.max_height-1.95)<0.001) then return 'slope',selected end
    selected,why=ledge_pass(s,state,trace,baseline)
    if why then return nil,nil,why end
    if not originals then state.raised_context_fallbacks=(state.raised_context_fallbacks or 0)+1 end
    return 'ledge',selected
end

-- True when the raised search, repeated, returns the same context within
-- 0.02 units.
local function raised_unchanged(s,raised_fresh)
    local fresh=s.native.raised_approach(s.controller_bytes,s.unit,s.mover_name,s.direction,s.ground_reach)
    if type(fresh)~='string' or #fresh~=0x2b0 or u32(fresh,4)~=1
        or u32(fresh,684)~=u32(raised_fresh,684) then return false end
    for offset=488,528,4 do
        local v=number(fresh,offset)
        if not finite(v) or math.abs(v-number(raised_fresh,offset))>0.02 then return false end
    end
    return true
end

-- Why the candidate may not be granted (its approach context or a guard
-- changed), else nil.
local function commit_blocked(api,s,raised_fresh)
    if raised_fresh then
        if not raised_unchanged(s,raised_fresh) then return 'raised_context_changed_before_commit' end
    elseif s.reprojected and not s.native.context_matches(s.controller_bytes) then
        return 'native_context_changed_before_commit'
    end
    if not guards_hold(api,s) then return 'candidate_changed' end
    return nil
end

local function assist_candidate(api,game,exe,state,owner)
    local s,why=candidate_snapshot(api,game,exe,state,owner)
    if not s then return nil,why end
    local originals,reason,approach_reason=M.refresh(s,state)
    local raised_fresh
    if raised_wanted(s,originals,reason,approach_reason) then
        raised_fresh,why=raised_context(s,state)
        if not raised_fresh then return nil,why end
        reason='fresh_raised_approach'
    end
    if not context_usable(originals,reason,raised_fresh) then return nil,reason end
    local trace=new_trace(api,s,originals,reason)
    state.candidate_trace=trace
    local kind,selected
    kind,selected,why=assisted_selection(s,state,trace,originals)
    if why then return nil,why end
    if not selected then return nil,'no_usable_assisted_candidate' end
    local hit=s.hits[selected.slot+1]
    if out_of_reach(s,hit) then return nil,'candidate_out_of_reach' end
    why=commit_blocked(api,s,raised_fresh)
    if why then return nil,why end
    state.candidate_height=hit.position[3]-s.root[3]
    state.candidate_normal_z=hit.normal_z
    return kind,kind=='ledge' and 'validated_raised_top' or 'validated_steep_candidate'
end

function M.assist_candidate(api,game,exe,state,owner)
    local previous=state.candidate_trace
    local kind,reason=assist_candidate(api,game,exe,state,owner)
    state.candidate_results=state.candidate_results or {}
    state.candidate_results[reason]=(state.candidate_results[reason] or 0)+1
    if state.candidate_trace~=previous then state.candidate_trace.result=reason end
    return kind,reason
end

-- The writes of a late retry: the chosen fresh hit (its actor cleared for a
-- metadata fallback), every other originally nonempty slot's unit cleared, and
-- the phase back to 2.
local function retry_writes(s,originals,selected)
    local chosen=s.hits[selected.slot+1]
    local writes={}
    for i,hit in ipairs(s.hits) do
        local before=originals[i]
        if hit==chosen then
            local after=hit.bytes
            if selected.metadata then after=after:sub(1,32)..pair(INVALID,0):sub(1,4)..after:sub(37) end
            if before~=after then writes[#writes+1]={address=hit.address,before=before,after=after} end
        elseif u32(before,28)~=0 then
            writes[#writes+1]={address=hit.address+28,before=before:sub(29,36),after=pair(0,u32(before,32))}
        end
    end
    writes[#writes+1]={address=s.controller+4,before=pair(3,0):sub(1,4),after=pair(2,0):sub(1,4)}
    return writes
end

-- Restores the retry's writes and gives up with reason.
local function rollback(api,state,pending,reason)
    local restored=M.restore(api,pending)
    state.pending=nil
    return false,restored and reason or 'query_restore_failed',false
end

local function count_retry(state,s,selected)
    state.prepared=(state.prepared or 0)+1
    if selected.metadata then state.metadata_fallbacks=(state.metadata_fallbacks or 0)+1 end
    state.retry_calls=(state.retry_calls or 0)+1
    if s.reprojected then state.reprojected_retries=(state.reprojected_retries or 0)+1 end
    if s.prior_step_report then state.step_report_retries=(state.step_report_retries or 0)+1 end
end

local function count_start(state,s,started)
    if not started then return end
    state.native_starts=(state.native_starts or 0)+1
    if s.reprojected then state.reprojected_starts=(state.reprojected_starts or 0)+1 end
    if s.prior_step_report then state.step_report_starts=(state.step_report_starts or 0)+1 end
end

-- True when the native driver entered climbing (same epoch, climbing flag).
local function native_started(api,s)
    if not M.same_epoch(api,s) then return false end
    local flags=api.read(s.flags_address,24)
    return flags and bit.band(u32(flags,12),0x200)~=0 or false
end

-- Exposes the fresh result, runs the original driver with zero dt and restores.
local function retry_commit(api,s,state,writes,selected)
    local pending={snapshot=s,writes={}}
    state.pending=pending
    local failure=commit(api,s,pending,writes)
    if failure=='changed' then
        local restored=M.restore(api,pending);state.pending=nil
        return restored,restored and 'query_changed_before_commit' or 'query_restore_failed',false
    end
    if failure then return rollback(api,state,pending,failure=='write' and 'query_write_failed' or 'query_restore_failed') end
    if not M.same_epoch(api,s) or api.read(s.input_address,1)~=s.manual_bytes then
        return rollback(api,state,pending,'query_changed_before_retry')
    end
    count_retry(state,s,selected)
    local called,reason=pcall(s.native.retry,s.controller)
    if not called then return rollback(api,state,pending,'native_retry_failed: '..tostring(reason)) end
    local started=native_started(api,s)
    local restored=M.restore(api,pending);state.pending=nil
    if not restored then return false,'query_restore_failed',false end
    count_start(state,s,started)
    return true,started and 'native_local_vault_started' or 'native_local_retry_rejected',started
end

function M.retry_consumed(api,s,state)
    -- The native selectors read shared scheduler counts. Private rebuilding
    -- is discovery-only; never let foreign counts reach local consumption.
    if s.rebuild_queries then return true,'retained_query_reused',false end
    local now=api.time()
    if state.last_retry_at and now-state.last_retry_at<0.1 then
        return true,'waiting_for_retry_interval',false
    end
    state.last_retry_at=now
    local originals,reason=M.refresh(s,state)
    if not originals then return true,reason,false end
    local _,selected=M.plan(s)
    if not selected then return true,'native_vault_checks_retained',true end
    if out_of_reach(s,s.hits[selected.slot+1]) then return true,'retained_query_out_of_reach',false end
    local writes=retry_writes(s,originals,selected)
    if s.reprojected and not s.native.context_matches(s.controller_bytes) then
        return true,'native_context_changed_before_commit',false
    end
    if not guards_hold(api,s) then return true,'query_changed_before_commit',false end
    return retry_commit(api,s,state,writes,selected)
end

-- The previous check's prepared writes while their epoch is unchanged, else
-- nil. A changed epoch (consumed or reused batch) drops them unwritten, as
-- M.restore does.
local function held_writes(api,state)
    local pending=state.pending
    if not pending then return nil end
    if not M.same_epoch(api,pending.snapshot) then state.pending=nil;return nil end
    return pending
end

-- Restores the held writes that are still in place, as M.restore does once the
-- epoch is confirmed (held_writes, this check).
local function release(api,state,held)
    if not restore_in_place(api,held) then return false end
    state.pending=nil
    return true
end

-- True when this check would prepare exactly the held writes from unchanged
-- data: they stay in place, with no restore, no new write and no protection
-- query. The snapshot of this check has just read every guard (its epoch
-- among them) and nothing was written since, so they are not read a second
-- time: keeping writes nothing, and the next check reads them all again. The
-- held writes and the input are read again, as before a commit.
local function keeps(api,s,held,writes)
    if #writes~=#held.writes then return false end
    for i,w in ipairs(writes) do
        local h=held.writes[i]
        if w.address~=h.address or w.before~=h.before or w.after~=h.after then return false end
    end
    for _,w in ipairs(held.writes) do
        if api.read(w.address,#w.after)~=w.after then return false end
    end
    return api.read(s.input_address,1)==s.manual_bytes
end

-- Idle gate: the slope check of this poll has just resolved and verified the
-- local avatar, so its controller's phase word (one read, at the address the
-- slope snapshot hands over) and the input that check read decide whether a
-- vault check can act at all. The word is read into one reused cell, without
-- allocating. Stages are counted as the full snapshot counts them; anything
-- else goes on to the full snapshot.
local phase_word=ffi.new('uint32_t[1]')
local function vault_idle(api,state,avatar)
    if not api.read_into(avatar.vault_phase,4,phase_word) then return nil end
    local stage=phase_word[0]
    local idle=stage~=2 and stage~=3 and 'waiting_for_vault_query' or not avatar.manual and 'waiting_for_manual_vault'
    if idle then count_stage(state,stage) end
    return idle
end

local function prepared(state,pending,selected)
    state.pending=pending
    state.prepared=(state.prepared or 0)+1
    if selected.metadata then state.metadata_fallbacks=(state.metadata_fallbacks or 0)+1 end
    state.last_slot=selected.slot
    return true,selected.metadata and 'local_manual_metadata_fallback_prepared' or 'local_manual_alternative_prepared',true
end

-- Commits a new stage-2 plan: guards verified, one batch, epoch and input
-- verified again after it.
local function prepare(api,s,state,writes,selected)
    if not guards_hold(api,s) then return true,'query_changed_before_commit',false end
    -- A failed API may write partially: the rollback covers every attempted write.
    local pending={snapshot=s,writes={}}
    local failure=commit(api,s,pending,writes)
    if failure then
        local restored=M.restore(api,pending)
        if failure=='changed' then return restored,restored and 'query_changed_before_commit' or 'query_restore_failed',false end
        return false,restored and failure=='write' and 'query_write_failed' or 'query_restore_failed',false
    end
    if not M.same_epoch(api,s) or api.read(s.input_address,1)~=s.manual_bytes then
        local restored=M.restore(api,pending)
        return restored,restored and 'query_changed_after_commit' or 'query_restore_failed',false
    end
    return prepared(state,pending,selected)
end

-- Stage 2: keep the held writes when the plan is unchanged, else restore them
-- and prepare the new plan.
local function plan_batch(api,s,state,held)
    local planned,writes,selected=pcall(M.plan,s)
    if held then
        if planned and keeps(api,s,held,writes) then return prepared(state,{snapshot=s,writes=held.writes},selected) end
        if not release(api,state,held) then return false,'query_restore_failed',false end
    end
    if not planned then return false,'validation_failed: '..tostring(writes),false end
    if #writes==0 then return true,'native_vault_checks_retained',true end
    return prepare(api,s,state,writes,selected)
end

-- Stage 3: the retained batch, through a late native retry.
local function retry(api,s,state)
    local called,accepted,why,active=pcall(M.retry_consumed,api,s,state)
    if not called then
        local restored=M.restore(api,state.pending);state.pending=nil
        return false,restored and 'validation_failed: '..tostring(accepted) or 'query_restore_failed',false
    end
    state.last_retry_reason=why
    return accepted,why,active
end

-- One check after the snapshot (ok, s, reason as pcall returned them).
local function vault_check(api,state,held,ok,s,reason)
    -- Without a new stage-2 plan there is nothing to keep: restore first, as
    -- every check did before it read the batch.
    if held and not (ok and s and s.stage==2) then
        if not release(api,state,held) then return false,'query_restore_failed',false end
        held=nil
    end
    if not ok then return true,'waiting_for_game_data: '..tostring(s),false end
    if not s then return true,reason,false end
    state.observed_queries=(state.observed_queries or 0)+1
    if s.stage==3 then return retry(api,s,state) end
    return plan_batch(api,s,state,held)
end

local function apply(api,game,exe,state)
    local held=held_writes(api,state)
    if M.assistance then
        local accepted,reason=M.assistance.step(api,game,exe,state)
        if not accepted then return false,reason,false end
    end
    local avatar=state.avatar;state.avatar=nil
    -- The slope check of this poll found no mission (false): its mission gate
    -- reads would answer the same. Held writes still go through the snapshot,
    -- whose failure restores them.
    if avatar==false and not held then return true,'waiting_for_mission',false end
    local idle=avatar and not held and vault_idle(api,state,avatar)
    if idle then return true,idle,false end
    return vault_check(api,state,held,pcall(M.snapshot,api,game,exe,state,nil,held,avatar and avatar.identity and avatar))
end

-- One check. state.busy tells the loader whether a check after the game's
-- update is needed: query writes held, a slope assist or its press window, or
-- a vault check past its idle gates (a query and the input both present).
function M.apply(api,game,exe,state)
    local observed=state.observed_queries
    local accepted,reason,active=apply(api,game,exe,state)
    state.busy=state.observed_queries~=observed or state.pending~=nil or state.slope_lease~=nil
        or state.assist_intent~=nil
    -- A check that found nothing to do lets the slope assistance's idle gate
    -- answer the next frames (M.idle).
    if M.assistance then M.assistance.settle(accepted and not state.busy) end
    return accepted,reason,active
end

-- The idle gate, before each check (archive_loader.lua): true when this frame
-- needs no check (slope_assist.lua A.idle). Never raises.
function M.idle(api,state)
    local assistance=M.assistance
    return assistance~=nil and assistance.idle(api,state)
end

function M.stop(api,game,exe,state)
    local queries=M.restore(api,state.pending)
    if queries then state.pending=nil end
    local slopes=not M.assistance or M.assistance.stop(api,game,exe,state)
    return queries and slopes
end

-- Machine code: the checks of every frame stay compiled: the idle gate, the
-- snapshot, plan and keep of a held vault query. Retries, commits, restores and
-- candidate searches run at most a few times per vault; compiled they only took
-- more of the LuaJIT code cache that the game and every mod share, with no
-- measurable gain in the game's lua51.dll, so they stay interpreted. The idle
-- gate (M.idle) stays interpreted like slope_assist.lua's A.idle: a trace from
-- it follows the returns into every update wrapper below. Nothing is flushed.
if jit and jit.off then
    for _,fn in ipairs({fresh_geometry,geometry_fits,basis_matches,endpoints,reprojected_record,M.reproject,
        rebuilt_context,approach_context,cast_in_reach,recast,M.refresh,candidate_snapshot,raised_wanted,raised_context,
        context_usable,new_trace,slope_pass,raised_in_reach,probe_clearance,raise_hit,ledge_pass,assisted_selection,
        raised_unchanged,commit_blocked,assist_candidate,M.assist_candidate,write_controller,first_mismatch,
        restore_in_place,M.restore,undo_partial,commit,out_of_reach,retry_writes,guards_hold,rollback,count_retry,
        count_start,native_started,retry_commit,M.retry_consumed,release,prepare,prepared,retry,M.stop,M.idle}) do
        jit.off(fn)
    end
end
return M

end)()
local assistance = (function()
local ffi,bit=require('ffi'),require('bit')
local A={limit=65,radius=3}
local INVALID=0xffffffff
-- Fields decode from the string's bytes with arithmetic: no cdata, cast or copy
-- per field.
local function u(b,o)
    local b0,b1,b2,b3=b:byte((o or 0)+1,(o or 0)+4)
    return ((b3*256+b2)*256+b1)*256+b0 -- lint-ok: R14 vault_data.lua decodes alike; each module loads and is tested alone
end
-- The float with bits w. A NaN loaded through a float cdata can become a
-- non-number value in the game's NaN-tagged LuaJIT; decoded here it is a plain
-- NaN.
local function float_bits(w)
    local e,m=bit.band(bit.rshift(w,23),0xff),bit.band(w,0x7fffff)
    local v
    if e==0xff then v=m==0 and math.huge or 0/0 elseif e==0 then v=m*2^-149 else v=(m+0x800000)*2^(e-150) end
    if w>=0x80000000 then return -v end
    return v
end
local function f(b,o)return float_bits(u(b,o)) end
local function bytes(v)return ffi.string(ffi.new('float[1]',v),4) end
local function finite(v)return v==v and math.abs(v)<100000 end
local function vec(b,o)return {f(b,o),f(b,o+4),f(b,o+8)} end
local COS=math.cos(A.limit*math.pi/180)
-- What an assist writes, built once: steep mode the two slide angles and the
-- slope cosine, ledge mode the ground climb height.
local ASSIST={enter=bytes(65),exit=bytes(60),slope=bytes(COS),height=bytes(2.5)}
local SLOPE_CELLS,LEDGE_CELLS={'enter','exit','slope'},{'height'}
-- Both angles lie in one settings record (+152 and +172): one batch.
local ANGLE_OFFSET,ANGLE_SPAN={enter=0,exit=20},24

-- Snapshot reads: each is complete or raises; a guard read is verified again
-- before and after writes (guarded).
local function read(api,s,a,n,guard)
    local b=assert(api.read(a,n),'Slope data unavailable');assert(#b==n,'Short slope read')
    if guard then s.guards[#s.guards+1]={address=a,bytes=b} end
    return b
end
local function ptr(api,b,o) return assert(api.pointer(b,o),'Slope pointer unavailable') end
local function global(api,s,game,rva) return ptr(api,read(api,s,game+rva,8,true)) end
-- The low 32 bits of a*b for 32-bit a and b, exact in doubles: no 64-bit cdata.
local function low_product(a,b)
    local a_low,b_low=a%65536,b%65536
    return (a_low*b_low+(((a-a_low)/65536*b_low+a_low*(b-b_low)/65536)%65536)*65536)%4294967296
end
-- The value stored for id in the game hash map at a (header and rows are guards).
local function lookup(api,s,a,id,limit)
    local h=read(api,s,a,20,true)
    local cap,empty,mult=u(h,8),u(h,12),u(h,16)
    assert(cap>0 and cap<=limit and bit.band(cap,cap-1)==0,'Unsupported slope map')
    local data=ptr(api,h)
    local low=low_product(id,mult)
    for i=0,math.min(cap,128)-1 do
        local slot=bit.band(low+i,cap-1)
        local row=read(api,s,data+slot*8,8,true)
        if u(row)==id then return u(row,4) end
        if u(row)==empty then return nil end
    end
end

-- Light reads: the identity chain and the input, read on every check, land in
-- one reused arena through api.read_into (the same ReadProcessMemory as
-- api.read) and decode in place, so an idle check creates no string, table or
-- pointer. Addresses are plain numbers here and reach the api as its own
-- address values: numbers when the game base is a number (the test fixtures),
-- else uint8_t pointers like api.pointer's, made once per address. Each read
-- is recorded (address, size, kind); a snapshot that goes on past the light
-- gate turns its records into guards, in read order: SLOPE ones into its own,
-- VAULT ones (EPOCH: also epoch guards) into the identity the vault snapshot of
-- the same check takes over instead of reading that chain again. The kinds
-- match the guards the vault snapshot gives these reads itself.
local SLOPE,VAULT,EPOCH=1,2,4
local CHAIN,OWNED=SLOPE+VAULT,SLOPE+VAULT+EPOCH
-- A slot holds the largest light read (0x44 bytes). 208 slots cover the most
-- reads one snapshot can make: 7 for the player, 2 globals, two maps of up to
-- 1 + 128 and 1 + 64 rows, the entity, the avatar count, the registry pair
-- and the input.
local SLOT,SLOTS=72,208
local arena=ffi.new('uint8_t[?]',SLOT*SLOTS)
local words=ffi.cast('uint32_t *',arena)
local slots={}
for i=0,SLOTS-1 do slots[i]=arena+i*SLOT end
local recorded_address,recorded_size=ffi.new('double[?]',SLOTS),ffi.new('int32_t[?]',SLOTS)
local recorded_kind=ffi.new('uint8_t[?]',SLOTS)
local reads=0
local POINTER=ffi.typeof('uint8_t *')
local numeric,pointers,cached=false,{},0
local function api_address(n)
    if numeric then return n end
    local p=pointers[n]
    if p then return p end
    if cached>=1024 then pointers,cached={},0 end
    p=ffi.cast(POINTER,n);pointers[n]=p;cached=cached+1
    return p
end
local game_object,game_number
local function base_of(game)
    numeric=type(game)=='number'
    if numeric then return game end
    if game~=game_object then game_object,game_number=game,tonumber(ffi.cast('uintptr_t',game)) end
    return game_number
end
-- Reads size bytes at address into the next slot; its index, or raises.
local function light_read(api,address,size,kind)
    local slot=reads
    assert(slot<SLOTS,'Slope read budget exceeded')
    assert(api.read_into(api_address(address),size,slots[slot]),'Slope data unavailable')
    recorded_address[slot],recorded_size[slot],recorded_kind[slot]=address,size,kind
    reads=slot+1
    return slot
end
local function word(slot,offset) return words[slot*18+offset/4] end
local function byte_at(slot,offset) return arena[slot*SLOT+offset] end
-- The user-mode pointer at offset of a slot as a number (api.pointer's rule:
-- at least 0x10000 and below 2^47), else raises.
local function light_pointer(slot,offset)
    local high=word(slot,offset+4)
    local value=high<0x8000 and high*4294967296+word(slot,offset)
    return assert(value and value>=0x10000 and value,'Slope pointer unavailable')
end
local function light_global(api,base,rva,kind) return light_pointer(light_read(api,base+rva,8,kind),0) end
-- True when the 8 bytes at offset of a slot hold pointer p (no range check).
local function holds(slot,offset,p) return word(slot,offset+4)*4294967296+word(slot,offset)==p end
-- The value stored for id in the game hash map at address (header and rows are guards).
local function light_lookup(api,address,id,limit)
    local h=light_read(api,address,20,CHAIN)
    local cap,empty=word(h,8),word(h,12)
    assert(cap>0 and cap<=limit and bit.band(cap,cap-1)==0,'Unsupported slope map')
    local data=light_pointer(h,0)
    local low=low_product(id,word(h,16))
    for i=0,math.min(cap,128)-1 do
        local row=light_read(api,data+bit.band(low+i,cap-1)*8,8,CHAIN)
        local key=word(row,0)
        if key==id then return word(row,4) end
        if key==empty then return nil end
    end
end

-- True while a mission runs (the mode pointer and record).
local function in_mission(api,base)
    local mode=light_read(api,light_global(api,base,0x2ce1850,CHAIN),0x44,CHAIN)
    return word(mode,8)~=0 and word(mode,0x40)>=1 and word(mode,0x40)<=7
end
-- The local player's unit reference while a mission runs, else nil and why.
local found_pm
local function local_ref(api,base)
    if not in_mission(api,base) then return nil,'outside_mission' end
    local pm=light_global(api,base,0x2ce1618,OWNED)
    local counts=light_read(api,pm+0x84,8,VAULT)
    assert(word(counts,0)<=4 and word(counts,4)<=4,'Unsupported player count')
    if word(counts,0)==0 or word(counts,4)==0 then return nil,'no_local_avatar' end
    if bit.band(byte_at(light_read(api,light_pointer(light_read(api,pm+0xe8,8,OWNED),0),24,OWNED),20),1)==0 then
        return nil,'no_local_avatar'
    end
    found_pm=pm
    return word(light_read(api,pm+0x3a8,4,OWNED),0)
end

-- Resource 0x4d1c334d294dfa97 as two 32-bit words.
local AVATAR_LOW,AVATAR_HIGH=0x294dfa97,0x4d1c334d
-- The identity found by the light reads: the avatar's unit reference, ID and
-- unit, owner and manager, its avatar index, the slot and address of its
-- entity record, and the registry's pointer to that record.
local found_ref,found_id,found_unit,found_owner,found_manager,found_ai,found_entity,found_address,found_registry
-- The avatar entity of ref: its slot, else nil and why.
local function avatar_entity(api,key,owner,ref)
    local ei=light_lookup(api,owner+0xf24990,ref,1048576)
    if not ei or ei==INVALID then return nil,'gone' end
    assert(ei<262144,'Unsupported entity index')
    local address=owner+0xf349e0+ei*24
    local entity=light_read(api,address,24,OWNED)
    if word(entity,0)~=AVATAR_LOW or word(entity,4)~=AVATAR_HIGH then return nil,'gone' end
    if key and (key.id~=word(entity,8) or key.unit~=word(entity,12)) then return nil,'gone' end
    if not key and bit.band(byte_at(entity,20),1)==0 then return nil,'no_local_avatar' end
    found_entity,found_address=entity,address
    return entity
end

-- The 24-byte records in slots a and b hold the same bytes.
local function same_record(a,b)
    for offset=0,20,4 do
        if word(a,offset)~=word(b,offset) then return false end
    end
    return true
end
-- The avatar index of id, checked against the avatar count and the registry.
local function avatar_index(api,manager,id,entity)
    local ai=light_lookup(api,manager+0xf8,id,64)
    if not ai or ai==INVALID then return nil end
    assert(ai<word(light_read(api,manager+0x6c,4,VAULT),0) and ai<8,'Unsupported avatar index')
    found_registry=light_pointer(light_read(api,manager+0x110+ai*8,8,OWNED),0)
    assert(same_record(light_read(api,found_registry,24,OWNED),entity),'Avatar registry mismatch')
    return ai
end

-- Resolves the local avatar, or with a saved key that same avatar, through
-- light reads: true, else nil and why. A saved identity is used only for
-- cleanup. It can locate the original avatar after registry compaction or a
-- local-player switch, never grant a new lease.
local function identify(api,base,key)
    local ref,why
    if key then ref=key.ref else ref,why=local_ref(api,base) end
    if not ref then return nil,why end
    if ref==0x7fff then return nil,'gone' end
    local owner,manager=light_global(api,base,0x2ce41b8,OWNED),light_global(api,base,0x2ce1ee0,OWNED)
    if key and (api.distance(api_address(owner),key.owner)~=0 or api.distance(api_address(manager),key.manager)~=0) then
        return nil,'gone'
    end
    local entity
    entity,why=avatar_entity(api,key,owner,ref)
    if not entity then return nil,why end
    local id=word(entity,8)
    local ai=avatar_index(api,manager,id,entity)
    if not ai then return nil,'gone' end
    found_ref,found_id,found_unit,found_owner,found_manager,found_ai=ref,id,word(entity,12),owner,manager,ai
    return true
end

-- The kept identity: identify() without a saved key keeps where it found the
-- local avatar (player manager, unit reference, entity record and its bytes,
-- avatar index and the registry's pointer). While the input stays released a
-- check only verifies it: the input at the kept index, the mission, the unit
-- reference, the entity record at the kept address (resource, ID, unit and
-- alive flag) and the registry slot at the kept index, 6 reads instead of 18.
-- A difference, a press or a failed check resolves everything again
-- (identify) before anything is armed or written.
local kept=false
local kept_pm,kept_ref,kept_owner,kept_manager,kept_ai,kept_address,kept_registry
local kept_entity={0,0,0,0,0,0}
-- True when the chain just resolved found the kept identity again.
local function kept_matches()
    if not kept or found_pm~=kept_pm or found_ref~=kept_ref or found_owner~=kept_owner or found_manager~=kept_manager
        or found_ai~=kept_ai or found_address~=kept_address or found_registry~=kept_registry then return false end
    for i=0,5 do if word(found_entity,i*4)~=kept_entity[i+1] then return false end end
    return true
end
-- renewed: the last snapshot replaced a kept identity with a different one.
-- The idle gate (A.idle) reads the input at the kept index only, so a press
-- made while the identity changed unseen is not a fresh press (A.step).
local renewed=false
local function keep_identity()
    renewed=kept and not kept_matches()
    kept_pm,kept_ref,kept_owner,kept_manager,kept_ai=found_pm,found_ref,found_owner,found_manager,found_ai
    kept_address,kept_registry=found_address,found_registry
    for i=0,5 do kept_entity[i+1]=word(found_entity,i*4) end
    kept=true
end
-- true when the kept identity holds, nil and why outside a mission, else false.
local function verify_identity(api,base)
    if not in_mission(api,base) then kept=false;return nil,'outside_mission' end
    if word(light_read(api,kept_pm+0x3a8,4,OWNED),0)~=kept_ref then return false end
    local entity=light_read(api,kept_address,24,OWNED)
    for i=0,5 do if word(entity,i*4)~=kept_entity[i+1] then return false end end
    if not holds(light_read(api,kept_manager+0x110+kept_ai*8,8,OWNED),0,kept_registry) then return false end
    found_ref,found_id,found_unit,found_owner,found_manager,found_ai=kept_ref,kept_entity[3],kept_entity[4],
        kept_owner,kept_manager,kept_ai
    found_entity,found_address=entity,kept_address
    return true
end

-- The light snapshot of an idle check: the input released. One table, reused
-- by every idle check; vault_phase is the address of the avatar's vault
-- controller phase word, which the vault check reads next.
local IDLE={manual=false}
-- The manual climb input of avatar index ai.
local function input_address(manager,ai) return manager+0x150+ai*0xa7aec+0x1b68+14*32 end
-- True when the input is released (a light read, a guard).
local function released(api)
    local input=light_read(api,input_address(found_manager,found_ai),1,SLOPE)
    return byte_at(input,0)==0
end
-- The snapshot goes on past the light gate: its light reads become guards, in
-- read order (SLOPE: its own; VAULT: s.identity, the identity chain's guards
-- for the vault snapshot of this check), and the identity takes the api's
-- address values. Returns the snapshot and the entity record's bytes.
local function adopt(vault_phase)
    local s={guards={},identity={}}
    for slot=0,reads-1 do
        local kind=recorded_kind[slot]
        if kind~=0 then
            local g={address=api_address(recorded_address[slot]),bytes=ffi.string(slots[slot],recorded_size[slot])}
            if bit.band(kind,SLOPE)~=0 then s.guards[#s.guards+1]=g end
            if bit.band(kind,VAULT)~=0 then s.identity[#s.identity+1]=g;g.epoch=bit.band(kind,EPOCH)~=0 end
        end
    end
    s.entity=api_address(found_address);s.ai=found_ai;s.vault_phase=vault_phase
    s.key={ref=found_ref,id=found_id,unit=found_unit,owner=api_address(found_owner),manager=api_address(found_manager)}
    s.entity_bytes=ffi.string(slots[found_entity],24)
    return s,s.entity_bytes
end

-- The local movement and mover records.
local function mover_records(api,s,game,id)
    local mm=global(api,s,game,0x2ce1708)
    local mi=lookup(api,s,mm+0x48a0,id,1048576)
    assert(mi and mi~=INVALID and mi<8192,'Movement unavailable')
    local move=read(api,s,ptr(api,read(api,s,mm+0x48c8,8,true))+mi*132,132)
    local mover_address=ptr(api,read(api,s,mm+0x48d0,8,true))+mi*164
    local mover=read(api,s,mover_address,164)
    read(api,s,mover_address+76,16,true)
    return move,mover
end

-- The mover's handle and character controller object, verified through the
-- handle pool, the mover record and the shared mover definition.
local function controller_object(api,s,exe,mover)
    local handle=u(mover,88)
    local pool=ptr(api,read(api,s,exe+0x286a768+bit.rshift(handle,30)*0x810,8,true))
    local h=read(api,s,pool,56,true)
    local index=bit.band(handle,u(h,40))
    assert(index>=0 and index<u(h,36) and bit.band(handle,u(h,52))~=0,'Invalid mover handle')
    local layout=u(h,28)
    local start=ptr(api,h)+index*bit.band(layout,65535)
    assert(u(read(api,s,start+bit.band(bit.rshift(layout,16),255),4,true))==handle,'Reused mover handle')
    local record=read(api,s,start+bit.rshift(layout,24),32,true)
    assert(u(record,8)==s.key.unit,'Mover belongs to another unit')
    local definition,object=ptr(api,record,16),ptr(api,record,24)
    local def=read(api,s,definition,28,true)
    assert(u(def)==u(mover,76),'Mover name mismatch')
    assert(api.distance(ptr(api,read(api,s,object,8,true)),exe+0x17430a8)==0,'Unsupported character controller')
    local up=vec(read(api,s,object+80,12,true),0)
    assert(math.abs(up[1])+math.abs(up[2])+math.abs(up[3]-1)<0.001,'Unsupported up vector')
    -- Preserve the separate 70-degree support/drop limit and shared definition.
    assert(math.abs(f(def,20)-50*math.pi/180)<0.001 and math.abs(f(def,24)-70*math.pi/180)<0.001,
        'Unsupported mover definition')
    assert(math.abs(f(read(api,s,object+100,4,true))-math.cos(70*math.pi/180))<0.001,'Unsupported support filter')
    return handle,object
end

-- The effective settings record: the avatar's own override, whose angle and
-- height cells an assist may write, or the shared component record. Only the
-- span an assist uses is read: walking speed (+12) through ground climb height
-- (+260), 252 of the record's 852 bytes; SETTINGS maps record offsets into it.
local SETTINGS_FROM,SETTINGS_SIZE=12,252
local SETTINGS={walk=0,enter=152-12,exit=172-12,height=260-12}
local function settings_record(api,s,entity)
    local manager=s.key.manager
    local oi=lookup(api,s,manager+0x547cb0,s.key.id,64)
    if oi and oi~=INVALID then
        assert(oi<8,'Unsupported avatar override')
        local base=manager+0x547d64+oi*852
        local settings=read(api,s,base+SETTINGS_FROM,SETTINGS_SIZE)
        s.cells.enter=base+152;s.cells.exit=base+172;s.cells.height=base+260
        return settings
    end
    local component=ptr(api,read(api,s,s.key.owner+0xf14680,8,true))
    local map=read(api,s,component,32,true);local found=false
    for i=0,1 do
        if map:sub(i*16+1,i*16+8)==entity:sub(1,8) and u(map,i*16+8)==0 then found=true end
    end
    assert(found,'Unsupported avatar resource map')
    return read(api,s,component+32+SETTINGS_FROM,SETTINGS_SIZE)
end

-- The settings an assist checks and the current bytes of every cell it may write.
local function settings_values(api,s,settings)
    -- Native allocation has a fixed eight-record capacity in this build.
    s.override_count=u(read(api,s,s.key.manager+0x547d60,4,true))
    assert(s.override_count<=8,'Unsupported override count')
    local at=SETTINGS
    s.walk=f(settings,at.walk);s.enter=f(settings,at.enter);s.exit=f(settings,at.exit);s.ground_max=f(settings,at.height)
    assert(finite(s.walk) and s.walk>0 and s.walk<=10,'Unsupported walking speed')
    s.values={cap=read(api,s,s.cells.cap,4),slope=read(api,s,s.cells.slope,4)}
    -- The override's cells are in the settings just read (arm reads each cell
    -- again right before writing it).
    if s.cells.enter then
        s.values.enter=settings:sub(at.enter+1,at.enter+4);s.values.exit=settings:sub(at.exit+1,at.exit+4)
        s.values.height=settings:sub(at.height+1,at.height+4)
    end
end

-- Input, movement flags, ground contact and the native mover position.
local function motion(api,s,game,exe,move)
    local manager,ai=s.key.manager,s.ai
    s.manual=read(api,s,manager+0x150+ai*0xa7aec+0x1b68+14*32,1,true):byte()~=0
    local flags=read(api,s,manager+0x53e888+ai*0x1240,24,true)
    s.climbing=bit.band(u(flags,12),0x200)~=0
    s.eligible=bit.band(u(flags),2)~=0 and bit.band(u(flags),0x404000)==0
        and bit.band(u(flags,4),0x8000000)==0 and bit.band(u(flags,8),0x20084000)==0
        and bit.band(u(flags,12),0x5181c)==0 and bit.band(u(flags,16),9)==0
    s.ground=bit.band(u(flags,8),4)==0 and bit.band(u(flags,12),0x26)==0
        and move:byte(16)==0 and move:byte(13)==0
    local n=vec(move,20);local length=math.sqrt(n[1]^2+n[2]^2+n[3]^2)
    s.normal_z=finite(length) and length>0.99 and length<1.01 and n[3]/length or -1
    s.native=assert(api.native(game,exe),'Native slope support unavailable')
    s.root=s.native.mover_position(s.key.unit,s.mover_name)
    assert(s.root and finite(s.root[1]) and finite(s.root[2]) and finite(s.root[3]),'Invalid mover position')
end

-- An idle check through the kept identity: IDLE, nil and why outside a
-- mission, or false when the chain must be resolved (a press or a difference).
-- The input comes first, at the kept avatar index: a press resolves the full
-- chain anyway, so a press check makes one read more than before, not six. A
-- released input counts only once the identity holds.
local function kept_idle(api,base)
    found_manager,found_ai=kept_manager,kept_ai
    if not released(api) then return false end
    local found,why=verify_identity(api,base)
    if not found then return found,why end
    IDLE.vault_phase=api_address(found_manager+0x53e1b8+found_ai*0x1240+4)
    return IDLE
end

-- light: no lease, so a released input ends the check after the identity.
-- verify: the previous check also ended there, so the kept identity may stand
-- in for the full chain while the input stays released.
function A.snapshot(api,game,exe,key,light,verify)
    reads=0
    local base=base_of(game)
    if verify and not key and kept then
        local idle,outside=kept_idle(api,base)
        if idle~=false then return idle,outside end
        reads=0
    end
    local found,why=identify(api,base,key)
    if not key then if found then keep_identity() else kept=false;renewed=false end end
    if not found then return nil,why end
    local vault_phase=api_address(found_manager+0x53e1b8+found_ai*0x1240+4)
    -- With no lease and the manual input released, A.step uses only the
    -- input state. The mover, controller, settings and flags are read and
    -- validated in full as soon as the input is pressed, and on every
    -- lease check.
    if light and not key and released(api) then
        IDLE.vault_phase=vault_phase
        return IDLE
    end
    local s,entity=adopt(vault_phase)
    local manager,ai,id=s.key.manager,s.ai,s.key.id
    assert(u(read(api,s,manager+0x53e1b8+ai*0x1240+0x2ac,4,true))==id,'Vault identity mismatch')
    local direction=manager+0x53e134+ai*0x1240
    assert(u(read(api,s,direction+40,4,true))==id,'Movement direction identity mismatch')
    local move,mover=mover_records(api,s,game,id)
    local handle,object=controller_object(api,s,exe,mover)
    s.manager=manager;s.handle=handle;s.object=object;s.mover_name=u(mover,76)
    s.cells={cap=direction+8,slope=object+96}
    settings_values(api,s,settings_record(api,s,entity))
    if key then return s end
    motion(api,s,game,exe,move)
    return s
end

local function guarded(api,s)
    for _,g in ipairs(s.guards) do if api.read(g.address,#g.bytes)~=g.bytes then return false end end
    return true
end
local function same(api,a,b)
    return a.id==b.id and a.unit==b.unit and a.ref==b.ref
        and api.distance(a.manager,b.manager)==0 and api.distance(a.owner,b.owner)==0
end

-- Restores the owned angles with one protection query; after a failure the
-- remaining ones are still tried one by one, as every restore is.
local function restore_angles(api,s,angles)
    local changes={}
    for i,w in ipairs(angles) do changes[i]={ANGLE_OFFSET[w.name],w.before} end
    local restored,landed=api.write_batch(s.cells.enter,ANGLE_SPAN,changes)
    if not restored then
        for i=landed+2,#angles do api.write(s.cells[angles[i].name],angles[i].before) end
    end
    for _,w in ipairs(angles) do
        if api.read(s.cells[w.name],4)~=w.before then restored=false end
    end
    return restored
end

-- A refused protection check before any write of a region (nil) is reported as
-- data that changed before the commit, as the separate check did; any other
-- failure is a failed write (false).
local function refused(api,address,size,landed)
    if landed==0 and not api.writable_data(address,size) then return nil end
    return false
end

-- Writes an assist with one protection query per region: the angles share the
-- settings record, the slope cosine is in the controller object and the ledge
-- height is alone. Each write is read back. True, nil (refused) or false.
local function write_cells(api,s,writes)
    if writes[1].name=='enter' then
        local written,landed=api.write_batch(s.cells.enter,ANGLE_SPAN,
            {{ANGLE_OFFSET.enter,writes[1].after},{ANGLE_OFFSET.exit,writes[2].after}})
        if not written then return refused(api,s.cells.enter,ANGLE_SPAN,landed) end
        if not api.write(s.cells.slope,writes[3].after) then return refused(api,s.cells.slope,4,0) end
    elseif not api.write(s.cells.height,writes[1].after) then
        return refused(api,s.cells.height,4,0)
    end
    for _,w in ipairs(writes) do
        if api.read(s.cells[w.name],4)~=w.after then return false end
    end
    return true
end

-- True when the cell holds this write's bytes, or a byte mix of a partial
-- write (every byte from before or after).
local function owned(w,current)
    if current==w.after then return true end
    if not (w.partial and current and current~=w.before) then return false end
    for j=1,4 do
        local c=current:byte(j)
        if c~=w.before:byte(j) and c~=w.after:byte(j) then return false end
    end
    return true
end

-- Restores one lease write on release; owned angles are collected for one
-- batch. False when the cell cannot be read or restored.
local function release_cell(api,s,lease,w,angles)
    local address=s.cells[w.name]
    -- A replacement mover has its own defaults; never restore into it.
    if w.name=='slope' and (lease.handle~=s.handle or api.distance(lease.object,s.object)~=0) then address=nil end
    if not address then return true end
    local current=api.read(address,4)
    if current==nil then return false end
    if not owned(w,current) then return true end
    if ANGLE_OFFSET[w.name] then angles[#angles+1]=w;return true end
    return api.write(address,w.before) and api.read(address,4)==w.before
end

function A.stop(api,game,exe,state)
    local lease=state.slope_lease
    if not lease then return true end
    local ok,s,why=pcall(A.snapshot,api,game,exe,lease.key)
    if not ok then return false end
    if not s then
        if why=='gone' then state.slope_lease=nil;return true end
        return false
    end
    -- Verified once before the writes: between here and them only these cells
    -- are read and written.
    if not guarded(api,s) then return false end
    local restored,angles=true,{}
    for i=#lease.writes,1,-1 do
        if not release_cell(api,s,lease,lease.writes[i],angles) then restored=false end
    end
    if #angles>0 and not restore_angles(api,s,angles) then restored=false end
    if restored then state.slope_lease=nil end
    return restored
end

-- Decisions use actual native climbing and ground contact, not query readiness.
-- Stable steep support has no timer that would unexpectedly drop a stationary
-- player. It remains walking-only inside the original three-metre area.
function A.keep(lease,s,now)
    if not s.eligible then return false,'ineligible' end
    local dx,dy,dz=s.root[1]-lease.anchor[1],s.root[2]-lease.anchor[2],s.root[3]-lease.anchor[3]
    if dx*dx+dy*dy>A.radius^2 or math.abs(dz)>3 then return false,'left_area' end
    if s.climbing then
        if now>lease.started+8 then return false,'climb_timeout' end
        lease.phase='climb';lease.last_climb=now;return true
    end
    if lease.phase=='attempt' then return now<=lease.started+1.25,'attempt_timeout' end
    if lease.kind=='ledge' then return false,'ledge_climb_finished' end
    if s.ground and s.normal_z>=COS then
        lease.air_since=nil
        if s.normal_z<math.cos(44*math.pi/180) then
            lease.phase='support';lease.flat_since=nil;return true
        end
        lease.flat_since=lease.flat_since or now
        return now-lease.flat_since<0.35,'flat_ground'
    end
    lease.air_since=lease.air_since or now
    return now-lease.air_since<0.25,'unsupported'
end

-- Ends the assist with this status, restoring every cell it still owns.
local function finish(api,game,exe,state,reason)
    state.slope_status=reason
    -- Cleared only when set: storing nil under a key the table lacks inserts it,
    -- and with the checks of idle frames gated that insert can rehash the
    -- state table (an allocation) on the next full check.
    if state.assist_intent~=nil then state.assist_intent=nil end
    if state.slope_lease then state.slope_last_release=reason end
    if state.slope_lease and state.slope_lease.kind=='ledge' and reason=='attempt_timeout' then
        state.ledge_attempt_expiries=(state.ledge_attempt_expiries or 0)+1
    end
    if not A.stop(api,game,exe,state) then return false,'slope_restore_failed' end
    return true
end

-- The snapshot still shows the lease's avatar and mover, and the bytes it wrote.
local function lease_holds(api,lease,s)
    if not same(api,lease.key,s.key) or lease.handle~=s.handle or api.distance(lease.object,s.object)~=0 then
        return false,'identity_changed'
    end
    for _,w in ipairs(lease.writes) do
        if s.values[w.name]~=w.after then return false,'settings_changed' end
    end
    return true
end

-- No movement cap during detection or a rejected attempt: it is applied only
-- after this assisted attempt actually enters native climbing. Returns nothing
-- once capped, else the step's result.
local function cap_speed(api,game,exe,state,s,lease)
    local cap=f(s.values.cap)
    if not finite(cap) or not guarded(api,s) then return finish(api,game,exe,state,'speed_cap_unavailable') end
    local w={name='cap',before=s.values.cap,after=bytes(cap>=0 and math.min(cap,s.walk) or s.walk),partial=true}
    lease.writes[#lease.writes+1]=w
    if not api.write(s.cells.cap,w.after) or api.read(s.cells.cap,4)~=w.after then
        local restored=A.stop(api,game,exe,state)
        return false,restored and 'speed_cap_write_failed' or 'slope_restore_failed'
    end
    w.partial=false;lease.speed_capped=true
end

-- Counts the phases the lease enters.
local function count_phase(state,lease,previous)
    if lease.phase=='climb' and previous~='climb' then
        state.slope_climbs=(state.slope_climbs or 0)+1
        if lease.kind=='ledge' then state.ledge_climbs=(state.ledge_climbs or 0)+1 end
    end
    if lease.phase=='support' and previous~='support' then state.slope_landings=(state.slope_landings or 0)+1 end
end

-- One poll of an armed lease: keep it, cap the speed once it climbs, or end it.
local function hold(api,game,exe,state,s,now)
    local lease=state.slope_lease
    local holds,why=lease_holds(api,lease,s)
    if not holds then return finish(api,game,exe,state,why) end
    local previous=lease.phase
    local keep
    keep,why=A.keep(lease,s,now)
    if not keep then return finish(api,game,exe,state,why) end
    if lease.kind=='slope' and lease.phase~='attempt' and not lease.speed_capped then
        local result,reason=cap_speed(api,game,exe,state,s,lease)
        if result~=nil then return result,reason end
    end
    count_phase(state,lease,previous)
    state.slope_status=lease.phase;return true
end

-- The default slide settings: 45 and 40 degrees, slope cosine of 50 degrees.
local function default_slide(s)
    return not (s.enter~=45 or s.exit~=40 or math.abs(f(s.values.slope)-math.cos(50*math.pi/180))>0.001)
end
-- A ledge assist needs ground contact and the default ground climb height.
local function ledge_unfit(kind,s)
    return kind=='ledge' and (not s.ground or math.abs(s.ground_max-1.95)>0.001)
end

-- True when this poll checks for a candidate: a fresh press opened a 1.25 s
-- window for this avatar, eligible and not climbing yet; at most every 0.1 s,
-- with default slide settings and unchanged guards.
local function candidate_due(api,state,s,now,rising)
    state.slope_status='waiting_for_manual_climb'
    if rising then state.assist_intent={key=s.key,deadline=now+1.25} end
    if not s.manual or not s.eligible or s.climbing then state.assist_intent=nil;return false end
    local intent=state.assist_intent
    if not intent or now>intent.deadline or not same(api,intent.key,s.key) then state.assist_intent=nil;return false end
    if intent.checked and now-intent.checked<0.1 then return false end
    intent.checked=now
    if not default_slide(s) then state.slope_status='custom_slope_settings_retained';return false end
    return guarded(api,s)
end

-- The assist a fresh native candidate check allows here: 'slope', 'ledge' or nil.
local function validated_kind(api,game,exe,state,s)
    state.candidate_checks=(state.candidate_checks or 0)+1
    local kind,reason
    if A.candidate then kind,reason=A.candidate(api,game,exe,state,s) end
    state.candidate_reason=reason or 'candidate_validator_unavailable'
    if kind~='slope' and kind~='ledge' or ledge_unfit(kind,s) or not guarded(api,s) then return nil end
    return kind
end

-- Without its own settings record the avatar gets one from the original
-- AvatarComponent modifier routine: a zero-count modifier descriptor copies the
-- base record into an engine-owned local override. Returns the new snapshot
-- while it still allows this assist.
local function with_override(api,game,exe,state,s,kind)
    if s.override_count>=8 then state.slope_status='override_capacity_reached';return nil end
    s.native.ensure_override(s.manager,s.entity)
    state.slope_overrides=(state.slope_overrides or 0)+1
    local fresh=A.snapshot(api,game,exe)
    if not fresh or not same(api,s.key,fresh.key) or not fresh.cells.enter or not fresh.manual or not fresh.eligible
        or not default_slide(fresh) or ledge_unfit(kind,fresh) or not guarded(api,fresh) then return nil end
    return fresh
end

-- Arms the lease: every cell must still hold what the snapshot read; the guards
-- were verified after the last native call (the candidate check or the override
-- creation) and are verified again after the writes.
local function arm(api,game,exe,state,s,kind,now)
    local lease={key=s.key,handle=s.handle,object=s.object,anchor=s.root,started=now,kind=kind,phase='attempt',writes={}}
    state.slope_lease=lease
    state.assist_intent=nil
    local names=kind=='ledge' and LEDGE_CELLS or SLOPE_CELLS
    for _,name in ipairs(names) do
        if api.read(s.cells[name],4)~=s.values[name] then return finish(api,game,exe,state,'slope_changed_before_commit') end
    end
    -- Every write is in the lease before the attempt: a failed one may land in
    -- part, and the restore decides per cell what is ours.
    for _,name in ipairs(names) do
        lease.writes[#lease.writes+1]={name=name,before=s.values[name],after=ASSIST[name],partial=true}
    end
    local written=write_cells(api,s,lease.writes)
    if written==nil then return finish(api,game,exe,state,'slope_changed_before_commit') end
    if not written then
        local restored=A.stop(api,game,exe,state)
        return false,restored and 'slope_write_failed' or 'slope_restore_failed'
    end
    for _,w in ipairs(lease.writes) do w.partial=false end
    if not guarded(api,s) then return finish(api,game,exe,state,'slope_changed_after_commit') end
    state.slope_arms=(state.slope_arms or 0)+1
    if kind=='ledge' then state.ledge_arms=(state.ledge_arms or 0)+1 end
    state.slope_status='attempt'
    return true
end

-- The idle gate. After a check that found nothing to do (A.settle, called by
-- the patch with the whole check's answer), the next frames are answered by
-- A.idle in the loader's step, before its check: no pcall, apply or report.
-- With the local avatar found and its input released a gated frame makes one
-- read, the input byte at the kept avatar index; outside a mission or without
-- a local avatar it makes none. A press, an unreadable input, work in progress
-- (state.busy, which a fresh start clears) or the end of the window runs the
-- full check on that same frame, so a press reaches it with no frame lost.
-- Windows are counted in frames, without a clock call. Every GATE_MISSION-th
-- frame of a mission the full check verifies the identity: until then a
-- respawn, a teammate leaving (registry compaction) or the mission's end can
-- leave the kept index stale, and a tap shorter than the rest of the window is
-- missed; a held press is seen at the full check (tests/test_slope.lua). 10
-- frames: about 0.17 s at 60 FPS, for 1.6 reads per idle frame on average (30
-- frames: 0.5 s for 1.2). Outside a mission nothing can be pressed: every
-- GATE_OUTSIDE-th frame looks for one. A check that raised is not gated.
local GATE_MISSION,GATE_OUTSIDE=10,60
local gate_frames,gate_input=0,nil
-- What this check allows (A.step): frames and the input address, or 0.
local gate_due,gate_due_input=0,nil
local gate_byte=ffi.new('uint8_t[1]')
function A.idle(api,state)
    if gate_frames<=0 or state.busy~=false then return false end
    gate_frames=gate_frames-1
    if gate_input==nil or api.read_into(gate_input,1,gate_byte) and gate_byte[0]==0 then return true end
    gate_frames=0
    return false
end
-- idle: the whole check (slope and vault) found nothing to do.
function A.settle(idle)
    if idle and gate_due>0 then gate_frames,gate_input=gate_due-1,gate_due_input else gate_frames,gate_input=0,nil end
end

-- The local avatar was not resolved (ok: the snapshot returned, with why):
-- the step's result. A transition or unavailable data needs a fresh release.
local function unresolved(api,game,exe,state,ok,why)
    state.slope_down=true
    -- false: outside a mission, which the vault check need not read again.
    if ok and why=='outside_mission' then state.avatar=false end
    if ok then gate_due=why=='outside_mission' and GATE_OUTSIDE or GATE_MISSION end
    return finish(api,game,exe,state,ok and 'waiting_for_avatar' or 'waiting_for_slope_data')
end
-- No lease and the input released: nothing else runs, nor needs the time; the
-- gate may read the input at this avatar index on the next frames.
local function released_idle(state)
    gate_due,gate_due_input=GATE_MISSION,api_address(input_address(found_manager,found_ai))
    state.slope_status='waiting_for_manual_climb'
    if state.assist_intent~=nil then state.assist_intent=nil end
    return true
end

function A.step(api,game,exe,state)
    -- state.avatar: this poll's verified local avatar, for the vault check
    -- that follows in the same poll (vault_data.lua), else nil.
    state.avatar=nil
    gate_due,gate_due_input=0,nil
    local light=not state.slope_lease
    local ok,s,why=pcall(A.snapshot,api,game,exe,nil,light,light and state.slope_down==false)
    if not ok or not s then return unresolved(api,game,exe,state,ok,why) end
    -- A new identity: a press already held is not a fresh one.
    if renewed then state.slope_down=true;renewed=false end
    state.avatar=s
    local rising=s.manual and state.slope_down==false
    state.slope_down=s.manual
    if not state.slope_lease and not s.manual then return released_idle(state) end
    local now=api.time()
    if state.slope_lease then return hold(api,game,exe,state,s,now) end
    if not candidate_due(api,state,s,now,rising) then return true end
    local kind=validated_kind(api,game,exe,state,s)
    if not kind then return true end
    if not s.cells.enter then
        s=with_override(api,game,exe,state,s,kind)
        if not s then return true end
    end
    return arm(api,game,exe,state,s,kind,now)
end

-- Machine code: the helpers of every check compile: the light reads, their
-- decoding, map probes and record compare, and the full snapshot's string read
-- helpers. The straight-line stages that call them (the identity chain, the
-- snapshot and the step) run once per check and stay interpreted, like the
-- rest, which runs while the input is held or an assist is armed: there system
-- calls dominate. Compiled, the whole idle check became one long trace per
-- check state, about 100 KB more of the LuaJIT code cache that the game and
-- every mod share in a session, for about 1 us less per idle frame in the game's
-- lua51.dll (offline). The idle gate (A.idle) stays interpreted too: compiled,
-- its trace followed the returns into the loader and the update wrappers below
-- it, 110 traces and 125 KB of machine code over the ledger tape (pass B, KB
-- cv-idle-gate-2026-10-17) instead of 9 traces and 1.4 KB. true selects this
-- chunk, the second true every function in it; the helpers are compiled again
-- by name. Nothing is flushed.
if jit and jit.off then
    jit.off(true,true)
    for _,fn in ipairs({u,float_bits,f,read,ptr,global,lookup,api_address,light_read,word,byte_at,light_pointer,
        holds,low_product,light_lookup,same_record}) do jit.on(fn) end
end
return A

end)()
local install_loader = (function()
return function(create_api,patch,build,runtime)
    if rawget(_G,'ConsistentVaulting') then return end
    local state={revision=build.revision,active=false,prepared=0,metadata_fallbacks=0,observed_queries=0,
        updates=0,polls=0,fresh_queries=0,retry_calls=0,native_starts=0}
    rawset(_G,'ConsistentVaulting',state)
    local api,last_report
    local function report(status,active,force)
        local changed=state.status~=status
        state.active=active
        state.status=status
        if not force and rawget(_G,'CowboyBingusDiagnostics')~=true then return end
        local now=api and api.time and api.time() or 0
        if not force and last_report and now-last_report<2 then return end
        if not force and not changed and not (api and api.time) then return end
        last_report=now
        print('[ConsistentVaulting] '..build.revision..': '..status)
        pcall(function()
            local logger=rawget(_G,'CowboyBingusModLoader')
            local file=logger and logger.open_log and logger.open_log('ConsistentVaulting.log')
            if not file then return end
            file:write(build.revision..'\n'..status..'\n')
            file:write('observed_queries='..state.observed_queries..'\nprepared='..state.prepared
                ..'\nmetadata_fallbacks='..state.metadata_fallbacks..'\n')
            for _,key in ipairs({'updates','polls','stage_0','stage_1','stage_2','stage_3',
                'fresh_queries','retry_calls','native_starts','context_reprojections','query_rebuilds','reprojected_retries','reprojected_starts',
                'step_report_retries','step_report_starts',
                'slope_arms','slope_overrides','slope_climbs','slope_landings',
                'candidate_checks','raised_queries','raised_context_fallbacks','raised_approach_rebuilds','ledge_arms','ledge_climbs','ledge_attempt_expiries'}) do
                file:write(key..'='..tostring(state[key] or 0)..'\n')
            end
            file:write('last_phase='..tostring(state.phase or 'startup')..'\n')
            file:write('last_retry_reason='..tostring(state.last_retry_reason or 'none')..'\n')
            file:write('last_approach_reason='..tostring(state.last_approach_reason or 'none')..'\n')
            file:write('last_approach_code='..tostring(state.last_approach_code or 'none')..'\n')
            file:write('slope_status='..tostring(state.slope_status or 'startup')..'\n')
            file:write('slope_last_release='..tostring(state.slope_last_release or 'none')..'\n')
            file:write('candidate_reason='..tostring(state.candidate_reason or 'none')..'\n')
            file:write('candidate_height='..tostring(state.candidate_height or 'none')..'\n')
            file:write('candidate_normal_z='..tostring(state.candidate_normal_z or 'none')..'\n')
            file:write('last_candidate_snapshot_error='..tostring(state.candidate_error or 'none')..'\n')
            local outcomes={}
            for reason in pairs(state.candidate_results or {}) do outcomes[#outcomes+1]=reason end
            table.sort(outcomes)
            for _,reason in ipairs(outcomes) do
                file:write('candidate_result_'..reason..'='..state.candidate_results[reason]..'\n')
            end
            -- Retain the last fresh search across input release/waiting states.
            -- Its age and mover origin prevent attribution to a new position.
            local trace=state.raised_trace or state.candidate_trace
            if trace then
                file:write('probe_scope='..(state.raised_trace and 'last_raised_search' or 'last_search')..'\n')
                file:write('probe_approach_context='..tostring(trace.context or 'unknown')..'\n')
                file:write(string.format('probe_age_seconds=%.3f\nprobe_result=%s\nprobe_ground=%s\n',
                    math.max(0,now-trace.time),tostring(trace.result),tostring(trace.ground)))
                file:write(string.format('probe_native_mover=%.6f,%.6f,%.6f\n',unpack(trace.root)))
                file:write(string.format('probe_direction=%.6f,%.6f,%.6f\n',unpack(trace.direction)))
                for _,pass in ipairs({'ordinary','slope','raised'}) do
                    for _,row in ipairs(trace.passes[pass]) do
                        file:write(string.format('probe_%s_slot_%d=count:%d unit:%u height:%.6f max:%.6f normal_z:%.6f threshold:%.6f source_height:%.6f target_height:%.6f hit:%.6f,%.6f,%.6f motion:%s exit:%s veto:%s min:%s result:%s\n',
                            pass,row.slot,row.count,row.unit,row.height,row.max_height,row.normal_z,row.normal_threshold,
                            row.source_height,row.target_height,row.position[1],row.position[2],row.position[3],
                            tostring(row.motion_squared),tostring(row.exit),tostring(row.metadata_veto),tostring(row.min_height),tostring(row.result)))
                    end
                end
            end
            file:close()
        end)
    end
    local ok,adapter,game,exe=pcall(function()
        local loader=rawget(_G,'CowboyBingusModLoader')
        assert(type(loader)=='table' and type(loader.api)=='number' and loader.api>=1
            and type(loader.version)=='number' and loader.version>=5,
            'Bingus Shared Loader loader-v4 or newer / API 1 or newer is required')
        local adapter=create_api()
        local game_base,exe_base=adapter.module('game.dll'),adapter.module(nil)
        assert(game_base and exe_base,'Required modules unavailable')
        assert(adapter.module_hash(game_base)==build.game_sha256,'Unsupported game module')
        assert(adapter.module_hash(exe_base)==build.exe_sha256,'Unsupported executable')
        assert(type(update)=='function','Game update unavailable')
        return adapter,game_base,exe_base
    end)
    if not ok then report(tostring(adapter),false,true);return end
    api=adapter
    -- The update chain is runtime.guard's (bingus_runtime.lua): the previous
    -- update runs outside pcall, so its errors reach the game unchanged; 8 of
    -- this mod's own errors in a burst stop it; after an error in an update
    -- below, the mod restores its changes, pauses and resumes once the updates
    -- below have returned on 60 frames in a row (8 such errors in a burst stop
    -- it); the first failure survives shutdown. stopped: the guard has stopped
    -- this mod and its stop work ran. skipped: the last check after the game's
    -- update did not run (idle).
    local guard,stopped,skipped=nil,false,false
    local function release()
        if patch.stop then return patch.stop(api,game,exe,state) end
        local restored=patch.restore(api,state.pending)
        if restored then state.pending=nil end
        return restored
    end
    -- Cleanup never raises into the game's update or shutdown; an error in it
    -- counts as a failed restore.
    local function cleanup() local called,restored=pcall(release);return called and restored end
    -- A fresh start, as after loading. A successful cleanup has already dropped
    -- the held query writes and the slope lease; this drops what else carries
    -- over between checks: the press window, the input edge (a fresh release is
    -- needed again), the retry interval, the avatar handed over within a check
    -- and the work in progress.
    local function reset()
        state.assist_intent=nil;state.slope_down=nil;state.last_retry_at=nil
        state.avatar=nil;state.busy=nil;state.active=false
        skipped=false
    end
    -- The patch raised: restore and start fresh, then raise the error again for
    -- the guard to count. A restore that fails stops the mod at once.
    local function failed(problem)
        if not cleanup() then return guard.stop(tostring(problem)) end
        reset()
        error(problem,0)
    end
    local function check(phase)
        if stopped then return end
        state.polls=state.polls+1;state.phase=phase
        local called,accepted,reason,active=pcall(patch.apply,api,game,exe,state)
        if not called then return failed(accepted) end
        -- A refusal stops the mod and is its first failure.
        if not accepted then return guard.stop(tostring(reason)) end
        report(tostring(reason),active==true,false)
    end
    -- One check per frame, before the game's update. Work that starts right
    -- after a skipped check gets that check now, still before the game's update,
    -- so it advances exactly as with two checks per frame (an assist armed with a
    -- climb already started caps its speed before the update, not one frame
    -- later).
    -- The patch's idle gate (vault_data.lua M.idle), if it has one, answers
    -- idle frames before the check: no pcall, apply or report. It never
    -- raises; any frame it does not answer gets the full check.
    local idle=patch.idle
    local function step()
        state.updates=state.updates+1
        if idle and idle(api,state) then return end
        check('before_update')
        if skipped and state.busy~=false then skipped=false;check('before_update') end
    end
    -- A second check after the game's update runs only while something is in
    -- progress (state.busy from the patch: held query writes, a slope assist or
    -- its press window, a vault check past its idle gates), because the update
    -- and other shared-loader/HUD wrappers may change that data. Idle, the next
    -- frame's check sees the same state before the next update. The native
    -- engine retains ownership of query scheduling.
    local function after()
        skipped=state.busy==false
        if not skipped then check('after_update') end
    end
    -- Once, when the guard stops this mod (a refusal, a failed restore after an
    -- error, 8 errors in a burst, a failed pause) or at shutdown: restore and
    -- report. At shutdown the first failure, if any, is kept in the status.
    local function stop(reason)
        stopped=true
        local restored=cleanup()
        if reason~='shutdown' then return report(restored and reason or 'local_restore_failed',false,true) end
        local failure=guard.status.first_failure
        report((restored and 'stopped' or 'local_restore_failed')..(failure and ' after: '..failure or ''),false,true)
    end
    -- An update below this mod raised: restore and start fresh. A restore that
    -- fails raises, and the guard stops the mod.
    local function pause()
        if not cleanup() then error('local_restore_failed',0) end
        reset()
    end
    local installed,why=pcall(function()
        guard=runtime.guard({name='ConsistentVaulting',env=_G,step=step,after=after,stop=stop,pause=pause,
            log=function(line) report(line,state.active,true) end}).install()
    end)
    if not installed then report(tostring(why),false,true);return end
    report('waiting_for_mission',false,true)
end

end)()
patch.assistance = assistance
assistance.candidate = patch.assist_candidate
install_loader(function() return create_api(runtime, runtime_write.extend(runtime_memory.new(runtime))) end, patch, {revision = 'data-v8.9.1-26251122', exe_sha256 = '257FD7DE21A04E8668E02E5C820EDF3435176FBDE3569765255CC52A5EA20F9D', game_sha256 = '61DCFCD201DACBF3545C97BEB8A5A6186E9850D2670BF60B0E058320B477F6DF'}, runtime)
