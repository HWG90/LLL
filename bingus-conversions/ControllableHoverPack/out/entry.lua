-- HD2-Addon: mods/cowboybingus/hover_pack_cancel
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
local runtime_write=(function()
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
local create_api=(function()
-- Windows adapter on top of Bingus Shared Runtime v1. memory is the api of
-- src/bingus_memory.lua extended by src/bingus_write.lua; the build passes it
-- with the core, src/bingus_runtime.lua. The runtime declares the Windows
-- functions under private, versioned names and provides the protection check,
-- checked writes, module handles, module hashes (computed once per session for
-- every mod that asks) and the clock (seconds; it allocates nothing). This file
-- adds what this mod needs: reads at plain-number addresses that allocate
-- nothing but a returned string, pointers as numbers, writes whose destination
-- the caller just checked, its write-size limit and the focus check.
return function(runtime, memory)
    assert(type(memory) == 'table' and type(memory.write) == 'function',
        'bingus_memory.lua and bingus_write.lua v1 are required')
    local native = memory.windows
    local ffi, windows = native.ffi, native.kernel32
    -- Private names (__asm__ labels) and a named function-pointer type,
    -- declared once per process: ffi.cdef keeps the first declaration of a
    -- name for the whole game, and a function-pointer type written in a cast
    -- string would add C types to the table every mod shares on every use.
    if not pcall(ffi.typeof, 'hd2chp_read_memory') then
        ffi.cdef [[
            typedef int (*hd2chp_read_memory)(void *process, uint64_t address, uint64_t buffer, size_t size, uint32_t *done);
            uint32_t hd2chp_GetCurrentProcessId(void) __asm__("GetCurrentProcessId");
            int32_t hd2chp_GetForegroundWindow(void) __asm__("GetForegroundWindow");
            uint32_t hd2chp_GetWindowThreadProcessId(intptr_t window, uint32_t *pid) __asm__("GetWindowThreadProcessId");
        ]]
    end
    local kernel, user = ffi.load('kernel32'), ffi.load('user32')
    local process = windows.GetCurrentProcess()
    local api = {distance = memory.distance, module = memory.module, module_hash = memory.module_hash,
        time = memory.time}

    -- Every accepted Windows user address is below 2^47, so a Lua number holds
    -- each byte address exactly.
    function api.address(pointer)
        local value = memory.address(pointer)
        assert(value >= 0x10000 and value < 0x800000000000, 'Address outside bounds')
        return value
    end

    -- The runtime's ReadProcessMemory, cast once to a type whose address and
    -- buffer are uint64_t and whose count is two 32-bit words: a read creates
    -- no pointer or 64-bit cdata. ReadProcessMemory does not call back into Lua.
    local read_memory = ffi.cast('hd2chp_read_memory', windows.ReadProcessMemory)
    local count = ffi.new('uint32_t[2]')
    local function read_to(address, size, destination)
        return read_memory(process, address, destination, size, count) ~= 0 and count[0] == size and count[1] == 0
    end
    -- read(address, size): the bytes as a string (one reused scratch buffer),
    -- so a read allocates only the returned string.
    -- read(address, size, into, offset): the bytes copied into a caller buffer
    -- {data, address, size} at offset, and true: nothing is allocated, which
    -- is what the per-frame snapshot uses. nil when they cannot all be read.
    -- A pointer cdata address is accepted and converted.
    local MAX_READ = 32768
    local scratch = ffi.new('uint8_t[?]', MAX_READ)
    local scratch_address = tonumber(ffi.cast('uintptr_t', scratch))
    function api.read(address, size, into, offset)
        if type(size) ~= 'number' or size < 1 or size > MAX_READ or size % 1 ~= 0 then return nil end
        if type(address) ~= 'number' then address = memory.address(address) end
        if not into then
            if not read_to(address, size, scratch_address) then return nil end
            return ffi.string(scratch, size)
        end
        offset = offset or 0
        if offset < 0 or offset + size > into.size then return nil end
        return read_to(address, size, into.address + offset) or nil
    end

    -- The user-mode pointer stored at bytes[offset+1 .. offset+8], as a number.
    function api.pointer(bytes, offset)
        local value = memory.pointer(bytes, offset)
        return value and memory.address(value)
    end

    -- The largest write is one 280-byte settings record: refuse anything else
    -- before the protection query.
    local MAX_WRITE = 280
    function api.writable_data(address, size)
        return size >= 1 and size <= MAX_WRITE and memory.writable_data(address, size)
    end
    -- checked: the caller verified this destination with writable_data moments
    -- before, in the same call (the settings creation checks all four before
    -- writing any), so the write makes no second query. Any other write is
    -- checked by the runtime right before writing.
    local done = ffi.new('size_t[1]')
    local done32 = ffi.cast('uint32_t *', done)
    function api.write(address, bytes, checked)
        if #bytes < 1 or #bytes > MAX_WRITE then return false end
        local destination = ffi.cast('void *', address)
        if not checked then return memory.write(destination, bytes) end
        return windows.WriteProcessMemory(process, destination, bytes, #bytes, done) ~= 0
            and done32[0] == #bytes and done32[1] == 0
    end

    -- The process ID once per session and one reused output word. A window
    -- handle is 32-bit significant on 64-bit Windows, which documents
    -- truncating it and sign-extending it again: taken as int32_t and passed as
    -- intptr_t, the check creates no pointer cdata.
    local process_id, window_process = kernel.hd2chp_GetCurrentProcessId(), ffi.new('uint32_t[1]')
    function api.focused()
        local window = user.hd2chp_GetForegroundWindow()
        if window == 0 then return false end
        user.hd2chp_GetWindowThreadProcessId(window, window_process)
        return window_process[0] == process_id
    end
    return api
end

end)()
local policy=(function()
local M={}
-- A new flight must observe release before a fresh press can cancel it.
function M.step(state,s)
    if not s or not s.flight then
        state.key=nil;state.armed=false;state.down=false;state.sent=false
        return false
    end
    if state.key~=s.key then
        state.key=s.key;state.armed=not s.down;state.down=s.down;state.sent=false
        return false
    end
    local press=s.down and not state.down
    state.down=s.down
    if not s.down then state.armed=true end
    if state.armed and press and not state.sent then
        state.sent=true
        return true
    end
    return false
end
return M

end)()
local settings=(function()
local ffi,bit=require('ffi'),require('bit')
local M={}
local function u(b,o)local v=ffi.new('uint32_t[1]');ffi.copy(v,b:sub(o+1,o+4),4);return tonumber(v[0])end
local function word(n)return ffi.string(ffi.new('uint32_t[1]',n),4)end
local CUTOFF=ffi.string(ffi.new('float[1]',1/1024),4)
local function current(api,s)
    for _,g in ipairs(s.guards)do if api.read(g.address,#g.bytes)~=g.bytes then return false end end
    return true
end
-- Follow both native maps afresh: the engine can compact/reallocate this array.
function M.inspect(api,game,target)
    local s={guards={}}
    local function read(a,n)
        local b=assert(api.read(a,n),'Hover settings unreadable')
        s.guards[#s.guards+1]={address=a,bytes=b};return b
    end
    local function ptr(b,o)return assert(api.pointer(b,o),'Hover settings pointer unavailable')end
    if api.pointer(read(game+0x2ce1d78,8))~=target.manager then return nil end
    local jm=target.manager
    local function slot(offset,key)
        local h=read(jm+offset,20);local cap,empty,mult=u(h,8),u(h,12),u(h,16)
        assert(cap>0 and cap<=256 and bit.band(cap,cap-1)==0,'Unsupported settings map')
        assert(key~=empty,'Invalid settings key')
        local product=tonumber(ffi.cast('uint32_t',ffi.new('uint64_t',key)*ffi.new('uint64_t',mult)))
        local data=ptr(h)
        for probe=0,cap-1 do
            local address=data+8*bit.band(product+probe,cap-1);local row=read(address,8)
            if u(row,0)==key or u(row,0)==empty then
                return {address=address,bytes=row,index=u(row,0)==key and u(row,4) or nil}
            end
        end
        error('Hover settings map full')
    end
    local entity_slot=slot(32,target.pack)
    if not entity_slot.index or entity_slot.index==0xffffffff then return nil end
    local count=u(read(jm+12,4),0)
    assert(count<=64 and entity_slot.index<count,'Invalid pack registry index')
    local entity=ptr(read(ptr(read(jm+56,8))+8*entity_slot.index,8))
    if read(entity,20)~=target.identity then return nil end
    local cap=u(read(jm+4,4),0);local n=u(read(jm+152,4),0)
    assert(cap>0 and cap<=256 and n<=cap,'Invalid settings count')
    s.forward=slot(96,target.pack);s.index=s.forward.index
    local data=ptr(read(jm+160,8))
    if s.index and s.index~=0xffffffff then
        assert(s.index<n,'Invalid settings index')
        local reverse=slot(128,s.index)
        assert(reverse.index==target.pack,'Settings owner mismatch')
        s.address=data+280*s.index;s.bytes=read(s.address,280)
    else
        assert(n<cap,'No free hover settings slot')
        s.index=n;s.address=data+280*n;s.previous=read(s.address,280)
        s.reverse=slot(128,n)
        assert(not s.reverse.index or s.reverse.index==0xffffffff,'Settings slot already owned')
        s.count_address=jm+152;s.count_bytes=word(n)
        -- Same six-entry resource table as game.dll+508c60. Copy the current
        -- resource, including other archive mods; never write shared settings.
        local owner=ptr(read(game+0x2ce41b8,8))
        local resources=ptr(read(owner+0xf14780,8));local headers=read(resources,96)
        for i=0,5 do
            if headers:sub(i*16+1,i*16+8)==target.identity:sub(1,8) then
                local index=u(headers,i*16+8);assert(index<3,'Invalid hover resource index')
                s.bytes=read(resources+96+280*index,280);break
            end
        end
        assert(s.bytes,'Hover resource unavailable');s.create=true
    end
    return s
end
-- Undo creation writes i..1 after write i failed (failure path only: each
-- undo write is checked again).
local function undo(api,writes,i)
    for j=i,1,-1 do assert(api.write(writes[j][1],writes[j][2]),'Settings rollback failed')end
end
-- Publish a normal engine-owned override in existing free storage. No
-- allocations or native function calls. Native pack destruction removes and
-- compacts these records through both maps. Returns the override, inspected again.
local function create(api,game,target,s,original)
    local writes={{s.address,s.previous,s.bytes},{s.reverse.address,s.reverse.bytes,word(s.index)..word(target.pack)},
        {s.count_address,s.count_bytes,word(s.index+1)},
        {s.forward.address,s.forward.bytes,word(target.pack)..word(s.index)}}
    -- All or nothing: every destination is checked (one protection query each)
    -- before anything is written, so a refused one leaves memory untouched.
    -- The writes follow in this same call and are not checked a second time.
    -- No frame/native callback occurs between them; a failed write undoes the
    -- earlier ones.
    for _,w in ipairs(writes)do assert(api.writable_data(w[1],#w[3]),'Settings storage is not writable data')end
    for i,w in ipairs(writes)do
        if not api.write(w[1],w[3],true) then undo(api,writes,i);error('Could not create per-pack hover settings')end
    end
    s=assert(M.inspect(api,game,target),'New hover override unavailable')
    assert(not s.create and s.bytes:sub(157,160)==original,'New hover override mismatch')
    return s
end
function M.cancel(api,game,target,state)
    -- A mission transition can invalidate data after the input snapshot.
    -- Retry read-only preflight; errors after mutation still reach cleanup.
    local ok,s=pcall(M.inspect,api,game,target)
    if not ok or not s then
        state.settings_waits=(state.settings_waits or 0)+1
        state.last_settings_error=ok and 'Hover pack changed' or tostring(s)
        return false
    end
    local original=s.bytes:sub(157,160);local duration=ffi.new('float[1]');ffi.copy(duration,original,4)
    assert(duration[0]>1/1024 and duration[0]<86400 and s.bytes:byte(154)==1,'Unsupported hover duration mode')
    if not current(api,s) then return false end
    if s.create then s=create(api,game,target,s,original) end
    if not current(api,s) then return false end
    local lease={manager=target.manager,pack=target.pack,identity=target.identity,key=target.key,original=original}
    state.lease=lease -- keep cleanup information even if a write reports failure
    if not api.write(s.address+156,CUTOFF) then
        assert(api.write(s.address+156,original),'Hover duration rollback failed')
        state.lease=nil;error('Could not shorten hover duration')
    end
    assert(api.read(s.address+156,4)==CUTOFF,'Hover duration write not retained')
    return true
end
-- true once the lease is settled (restored, or its pack proven gone); false
-- and why while it waits (settings unreadable or changing), keeping the lease.
function M.restore(api,game,state)
    local lease=state.lease;if not lease then return true end
    -- Retain the identity lease until we can resolve it or prove it is gone.
    -- Never turn a temporarily unavailable read into a permanent hook stop.
    local ok,s=pcall(M.inspect,api,game,lease)
    if not ok then
        state.restore_waits=(state.restore_waits or 0)+1
        state.last_restore_error=tostring(s);return false,state.last_restore_error
    end
    if not s or s.create then state.lease=nil;return true end
    if not current(api,s) then return false,'Hover settings changed' end
    -- Do not overwrite a later native/other-mod edit, or use a stale address.
    if s.bytes:sub(157,160)==CUTOFF then
        assert(api.write(s.address+156,lease.original),'Could not restore hover duration')
        assert(api.read(s.address+156,4)==lease.original,'Hover restoration not retained')
        state.restorations=(state.restorations or 0)+1
    end
    state.lease=nil;return true
end
-- The settings writer runs on about two frames per flight: the cancellation
-- and the restoration. Compiled, it took about 6 KB of the LuaJIT code cache
-- that the game and every mod share (the whole mod 14,294 -> 8,241 bytes and
-- 20 -> 14 traces, measured in the game's lua51.dll), and those frames were
-- not faster for it in a test process. true selects this chunk, the second
-- true every function in it: nothing else is affected and nothing is flushed.
if jit and jit.off then jit.off(true,true) end
return M

end)()
local patch=(function()
local ffi,bit=require('ffi'),require('bit')
local M={}
-- A snapshot allocates nothing on idle and flight frames. Every read lands in
-- one reused arena (8-byte aligned) through api.read(address, size, into,
-- offset), addresses are plain numbers, fields decode in place and pointers
-- from two 32-bit halves. The read budget, 160 reads, and the arena size bound
-- every snapshot (the largest read, the avatar registry block, is 228 bytes).
local READS,ARENA=160,160*0x48
local arena=ffi.new('uint8_t[?]',ARENA)
local words=ffi.cast('uint32_t *',arena)
local into={data=arena,address=tonumber(ffi.cast('uintptr_t',arena)),size=ARENA}
-- An 8-byte resource ID as its two 32-bit words.
local function resource(hex)
    local id=ffi.new('uint32_t[2]')
    ffi.copy(id,(hex:gsub('..',function(x)return string.char(tonumber(x,16))end)):reverse(),8)
    return id[0],id[1]
end
local AVATAR_LOW,AVATAR_HIGH=resource('4d1c334d294dfa97')
local HOVER_LOW,HOVER_HIGH=resource('5ec80f4f1cdb66cf')
-- Waiting reasons, raised as the same two objects every time.
local WAIT_READ={hover_wait=true,reason='waiting_for_read'}
local WAIT_POINTER={hover_wait=true,reason='waiting_for_pointer'}
-- Every field a snapshot returns: one table, reused by every snapshot. Its
-- values hold until the next snapshot.
local S={mission_type=0,down=false,active=false,flight=false,key='',identity='',manager=0,pack=0}
-- The kept layout (see "Kept layout" below): where the full resolution found
-- the local avatar, its equipment row, the pack and their identity records.
-- stage is how far it got: 0 none, 1 avatar, 2 equipment row, 3 jump-pack
-- registry (ji nil: the backpack is no jump pack), 4 everything.
local L={stage=0,aw={0,0,0,0,0,0},ew={0,0,0,0,0,0}}
local function forget()L.stage=0 end

-- The running snapshot: adapter, game.dll address, reads and arena bytes used.
local reader,base,reads,used=nil,0,0,0
local game_pointer,game_address
local function address_of(game)
    if type(game)=='number' then return game end
    if game~=game_pointer then game_pointer,game_address=game,tonumber(ffi.cast('uintptr_t',game)) end
    return game_address
end
local function u(o)return words[o/4]end
-- A failed read or pointer also drops the kept layout: an address that no
-- longer reads must not be tried again on every frame.
local function read(address,size)
    reads=reads+1;assert(reads<=READS and used+size<=ARENA,'Hover read budget exceeded')
    local o=used
    if not reader.read(address,size,into,o) then forget();error(WAIT_READ,0) end
    used=o+size+(-size)%8
    return o
end
-- The user-mode pointer stored at arena offset o, as a number.
local function pointer(o)
    local p=words[o/4+1]*4294967296+words[o/4]
    if p<0x10000 or p>=0x800000000000 then forget();error(WAIT_POINTER,0) end
    return p
end
-- True when the 8 bytes at arena offset o hold pointer p (no range check).
local function holds(o,p)return words[o/4+1]*4294967296+words[o/4]==p end
-- The float at arena offset o, decoded from its bits. A NaN loaded through a
-- float cdata can become a non-number value in the game's NaN-tagged LuaJIT;
-- decoded here it is a plain NaN.
local function float(o)
    local w=words[o/4];local e,m=bit.band(bit.rshift(w,23),0xff),bit.band(w,0x7fffff)
    local v
    if e==0xff then v=m==0 and math.huge or 0/0 elseif e==0 then v=m*2^-149 else v=(m+0x800000)*2^(e-150) end
    if w>=0x80000000 then return -v end
    return v
end
local function global(rva)return pointer(read(base+rva,8))end
-- Low 32 bits of key*mult from 16-bit halves: exact in doubles, no 64-bit cdata.
local function hash(key,mult)
    local kl,kh,ml,mh=bit.band(key,0xffff),bit.rshift(key,16),bit.band(mult,0xffff),bit.rshift(mult,16)
    return kl*ml+bit.band(kh*ml+kl*mh,0xffff)*65536
end
local function lookup(h,key,limit)
    local cap,empty,mult=u(h+8),u(h+12),u(h+16)
    if cap==0 then return nil end
    assert(cap<=limit and bit.band(cap,cap-1)==0,'Unsupported hover map')
    local product=hash(key,mult)
    local data=pointer(h)
    for probe=0,math.min(cap,64)-1 do
        local row=read(data+8*bit.band(product+probe,cap-1),8)
        if u(row)==key then local i=u(row+4);if i~=0xffffffff then return i end;return nil end
        if u(row)==empty then return nil end
    end
end
-- The 24-byte records at arena offsets a and b hold the same bytes.
local function same_record(a,b)
    for i=0,5 do if words[a/4+i]~=words[b/4+i] then return false end end
    return true
end
-- Keep the 24-byte record at arena offset o in t, or compare it with t.
local function keep(t,o)for i=0,5 do t[i+1]=words[o/4+i] end end
local function kept(t,o)
    for i=0,5 do if t[i+1]~=words[o/4+i] then return false end end
    return true
end

-- Full resolution -------------------------------------------------------------
-- True, or nil and why.
local function mission()
    local mode=read(global(0x2ce1850),0x44)
    -- +0x40 is a mission type, not a boolean. Native player logic at 602d20
    -- accepts 1..7; Evacuate High-Value Assets uses 2 on the supported build.
    S.mission_type=u(mode+0x40)
    if u(mode+8)==0 or S.mission_type<1 or S.mission_type>7 then return nil,'waiting_for_mission'end
    return true
end
-- The local player's unit, or nil and why.
local function local_unit()
    local pm=global(0x2ce1618);local counts=read(pm+0x84,8)
    assert(u(counts)<=4 and u(counts+4)<=4,'Unsupported player count')
    if u(counts)==0 or u(counts+4)==0 then return nil,'waiting_for_player'end
    local player=read(pointer(read(pm+0xe8,8)),24)
    if bit.band(arena[player+20],1)==0 then return nil,'waiting_for_player'end
    local unit=u(read(pm+0x3a8,4))
    if unit==0x7fff then return nil,'waiting_for_avatar'end
    L.pm,L.unit=pm,unit
    return unit
end
-- The local avatar's entity record (arena offset), or nil and why.
local function avatar_record(unit)
    local owner=global(0x2ce41b8)
    local ei=lookup(read(owner+0xf24990,20),unit,1048576)
    if not ei then return nil,'waiting_for_avatar'end
    assert(ei<262144,'Unsupported entity index')
    L.avatar=owner+0xf349e0+ei*24
    local avatar=read(L.avatar,24)
    if u(avatar)~=AVATAR_LOW or u(avatar+4)~=AVATAR_HIGH or bit.band(arena[avatar+20],1)==0 then
        return nil,'waiting_for_avatar'
    end
    return avatar
end
-- The avatar manager and the avatar's index in it, or nil and why.
local function avatar_slot(avatar)
    local am=global(0x2ce1ee0)
    local ai=lookup(read(am+0xf8,20),u(avatar+8),64)
    if not ai then return nil,'waiting_for_avatar'end
    local count=u(read(am+0x6c,4))
    assert(count<=8 and ai<count,'Unsupported avatar index')
    local slot=pointer(read(am+0x110+ai*8,8))
    assert(same_record(read(slot,24),avatar),'Avatar identity mismatch')
    L.am,L.ai,L.am_slot=am,ai,slot;keep(L.aw,avatar);L.stage=1
    return am,ai
end
-- The equipped backpack's entity ID, or nil and why. Equipped backpack, then
-- reverse ownership: never choose the first pack.
local function backpack(avatar)
    local equipment=global(0x2ce18e8)
    local qi=lookup(read(equipment+40,20),u(avatar+8),8192)
    if not qi then return nil,'no_backpack'end
    assert(qi<4096,'Unsupported equipment index')
    local ids=pointer(read(equipment+64,8));local slot=pointer(read(ids+qi*8,8))
    assert(same_record(read(slot,24),avatar),'Equipment identity mismatch')
    local rows=pointer(read(equipment+80,8))
    L.eq,L.qi,L.eq_ids,L.eq_slot,L.eq_rows,L.pack_at=equipment,qi,ids,slot,rows,rows+qi*48+12;L.stage=2
    local pack_id=u(read(L.pack_at,4))
    if pack_id==0 or pack_id==0xffffffff then return nil,'no_backpack'end
    return pack_id
end
-- The jump-pack manager, the pack's registry index and its entity record, or
-- nil and why.
local function jump_pack(pack_id)
    local jm=global(0x2ce1d78)
    L.jm,L.pack_id=jm,pack_id
    local ji=lookup(read(jm+32,20),pack_id,128)
    if not ji then L.ji=nil;L.stage=3;return nil,'no_jump_pack'end
    local counts=read(jm+16,8);local total,owned=u(counts),u(counts+4)
    assert(owned<=total and total<=64,'Unsupported jump-pack registry')
    if ji>=owned then return nil,'pack_not_owned'end
    local entries=pointer(read(jm+56,8));local address=pointer(read(entries+ji*8,8))
    local entity=read(address,24)
    assert(u(entity+8)==pack_id,'Pack identity mismatch')
    local hover=u(entity)==HOVER_LOW and u(entity+4)==HOVER_HIGH
    if hover and bit.band(arena[entity+20],1)==0 then return nil,'pack_not_owned'end
    L.ji,L.jm_entries,L.entity,L.hover=ji,entries,address,hover;keep(L.ew,entity);L.stage=3
    if not hover then return nil,'not_hover_pack'end
    return jm,ji,entity
end
-- The pack's row in the attachment registry (arena offset of its owner), or nil
-- and why.
local function attached(pack_id,avatar)
    local attach=global(0x2ce1f88)
    local bi=lookup(read(attach+32,20),pack_id,8192)
    if not bi then return nil,'pack_not_attached'end
    assert(bi<4096,'Unsupported attachment index')
    local rows=pointer(read(attach+64,8))
    if u(read(rows+bi*48+4,4))~=u(avatar+8) then return nil,'pack_not_attached'end
    L.attach,L.attach_rows,L.owner_at=attach,rows,rows+bi*48+4
    return true
end
-- S.down, S.active and S.flight from the avatar's movement flags, the pack's
-- five state bytes (states: the registry's state array) and the jump input.
local function pack_state(am,ai,states,ji)
    local flags=read(am+0x53d900+ai*0x1240+0xf88,24)
    local ps=read(states+ji*5,5)
    for i=0,4 do assert(arena[ps+i]<=1,'Unsupported pack flags')end
    -- The native input helper maps pair (2,15) to slot 15. +8 is its held time.
    local held=float(read(am+0x150+ai*0xa7aec+0x1b68+15*32,32)+8)
    assert(held==held and held>=0 and held<86400,'Invalid jump input')
    S.down=held>0
    S.active=arena[ps]==1
    S.flight=S.active and arena[ps+1]==0 and arena[ps+4]==1 and bit.band(u(flags+12),4)~=0
        and bit.band(u(flags+12),0x30)==0 and bit.band(u(flags+8),0x80000000)==0
end
-- S.key (avatar record, pack record and manager) and S.identity (the pack
-- record's first 20 bytes), built again only when those bytes change.
local key_words,key_manager={0,0,0,0,0,0,0,0,0,0,0,0},nil
local function same_key(avatar,entity,jm)
    if jm~=key_manager then return false end
    for i=0,5 do
        if key_words[i+1]~=words[avatar/4+i] or key_words[i+7]~=words[entity/4+i] then return false end
    end
    return true
end
local function identify(avatar,entity,jm)
    if same_key(avatar,entity,jm) then return end
    S.key=ffi.string(arena+avatar,24)..ffi.string(arena+entity,24)..tostring(jm)
    S.identity=ffi.string(arena+entity,20)
    for i=0,5 do key_words[i+1],key_words[i+7]=words[avatar/4+i],words[entity/4+i] end
    key_manager=jm
end
-- Everything from the registry roots down (39 reads with a hover pack, after
-- the mission check), keeping the layout as it goes.
local function resolve()
    forget()
    local unit,reason=local_unit();if not unit then return nil,reason end
    local avatar;avatar,reason=avatar_record(unit);if not avatar then return nil,reason end
    local am,ai=avatar_slot(avatar);if not am then return nil,ai end
    local pack_id;pack_id,reason=backpack(avatar);if not pack_id then return nil,reason end
    local jm,ji,entity=jump_pack(pack_id);if not jm then return nil,ji end
    local ok;ok,reason=attached(pack_id,avatar);if not ok then return nil,reason end
    L.states=pointer(read(jm+80,8))
    pack_state(am,ai,L.states,ji)
    L.stage=4
    identify(avatar,entity,jm)
    S.manager,S.pack=jm,pack_id
    return S
end

-- Kept layout -----------------------------------------------------------------
-- Between resolutions only the mode, the unit, the pack's state bytes, flags
-- and input change. Each frame reads the identity records at their kept
-- addresses and the registry slots and array pointers that lead to them (one
-- read per registry: its counts and array pointers sit together), at most 14
-- reads after the mission check instead of 39. false when any of it differs
-- (or a stage was never kept): resolve() then runs in the same frame. A
-- cancellation always resolves afresh before it writes (see fly).
local function check_avatar()
    if u(read(L.pm+0x3a8,4))~=L.unit then return nil end
    local avatar=read(L.avatar,24);if not kept(L.aw,avatar) then return nil end
    -- Count (+0x6c) through the avatar's slot (+0x110 + 8 ai) in one read.
    local ai=L.ai;local block=read(L.am+0x6c,0xac+ai*8);local count=u(block)
    if count>8 or ai>=count or not holds(block+0xa4+ai*8,L.am_slot) then return nil end
    return avatar
end
-- The kept equipment row's pack ID, or nil when the row moved.
local function check_equipment()
    local block=read(L.eq+64,24) -- the identity (+64) and row (+80) arrays
    if not holds(block,L.eq_ids) or not holds(block+16,L.eq_rows) then return nil end
    if not holds(read(L.eq_ids+L.qi*8,8),L.eq_slot) then return nil end
    return u(read(L.pack_at,4))
end
-- The pack's entity record (arena offset) and the registry block, false when
-- the registry or the record moved, or nil and why.
local function check_pack(pack_id)
    local block=read(L.jm+16,72) -- counts (+16), map (+32), entries (+56), states (+80)
    if not L.ji then
        if lookup(block+16,pack_id,128) then return false end
        return nil,'no_jump_pack'
    end
    local total,owned=u(block),u(block+4)
    if owned>total or total>64 or L.ji>=owned or not holds(block+40,L.jm_entries) then return false end
    if not holds(read(L.jm_entries+L.ji*8,8),L.entity) then return false end
    local entity=read(L.entity,24);if not kept(L.ew,entity) then return false end
    if not L.hover then return nil,'not_hover_pack' end
    if L.stage<4 or not holds(block+64,L.states) then return false end
    return entity
end
local function warm()
    local avatar=check_avatar();if not avatar or L.stage<2 then return false end
    local pack_id=check_equipment();if not pack_id then return false end
    if pack_id==0 or pack_id==0xffffffff then return nil,'no_backpack'end
    if L.stage<3 or pack_id~=L.pack_id then return false end
    local entity,reason=check_pack(pack_id);if not entity then return entity,reason end
    if not holds(read(L.attach+64,8),L.attach_rows) or u(read(L.owner_at,4))~=u(avatar+8) then return false end
    pack_state(L.am,L.ai,L.states,L.ji)
    identify(avatar,entity,L.jm)
    S.manager,S.pack=L.jm,pack_id
    return S
end

-- The local player's hover pack: S, or nil and why. Reads only; a read or
-- pointer that is not available yet raises WAIT_READ or WAIT_POINTER. fresh
-- skips the kept layout and resolves everything again.
function M.snapshot(api,game,fresh)
    reader,base,reads,used=api,address_of(game),0,0
    local ok,reason=mission();if not ok then forget();return nil,reason end
    if L.stage>0 and not fresh then
        local s;s,reason=warm();if s~=false then return s,reason end
        reads,used=0,0
    end
    return resolve()
end
-- The snapshot, or nil and why. Registries can disagree briefly while a
-- mission/player is removed; this phase only reads, so a failed snapshot is
-- rejected (with its kept layout) and the next update retries.
local function read_snapshot(api,game,state,fresh)
    local ok,s,reason=pcall(M.snapshot,api,game,fresh)
    if not ok then
        forget()
        if type(s)=='table' and s.hover_wait then reason=s.reason else
            state.snapshot_waits=(state.snapshot_waits or 0)+1
            state.last_snapshot_error=tostring(s);reason='waiting_for_game_data'
        end
        s=nil
    end
    state.snapshot_status=s and 'valid' or reason
    state.mission_type=s and s.mission_type or nil
    return s,reason
end
-- Before a cancellation the pack is located afresh from the registry roots: it
-- must be the same pack (same key) in the same flight with the jump held.
local function confirmed(api,game,s,state)
    local key=s.key
    local again=read_snapshot(api,game,state,true)
    return again~=nil and again.key==key and again.flight and again.down
end
-- A flight frame: focus check and the policy; when it asks for a cancellation,
-- the focus check runs again and the pack is located afresh right before the
-- settings write (which checks its own guards again).
local function fly(api,game,s,state)
    if not api.focused() then M.policy.step(state,nil);return 'waiting_for_game_focus'end
    if not M.policy.step(state,s) then return 'watching_hover'end
    if not api.focused() or not confirmed(api,game,s,state) then
        M.policy.step(state,nil);return 'snapshot_changed'
    end
    if not M.settings.cancel(api,game,s,state) then
        M.policy.step(state,nil);return 'snapshot_changed'
    end
    state.cancellations=(state.cancellations or 0)+1
    return 'cancel_requested'
end
-- Idle gate -------------------------------------------------------------------
-- Waiting for work: after a full check that found nothing to do, with no
-- cancellation lease held, M.idle answers the next frames before apply, its
-- pcall and the report (the loader calls it first):
--   outside a mission: 59 frames with no read, then the full check (a mission
--   start is noticed up to 1 s late, during its drop);
--   in a mission without a usable hover pack (no player or avatar yet, no
--   backpack, another backpack, a pack not owned or not attached): 29 frames
--   with no read (a hover pack picked up is noticed up to 0.5 s late);
--   hover pack worn and inactive: 29 frames, each reading only the pack's state
--   row (one 5-byte read at its kept address). Every flight and the native
--   landing assistance need state +0 (active) set, so a set +0 or a failed read
--   ends the wait at once and the same frame runs the full check.
-- The full check every 30th frame renews the identity proof: after a respawn,
-- a pack swap or a registry move the kept row can belong to nothing, and a
-- flight is then seen up to 29 frames late (a player cannot fly that soon
-- after a respawn or a pickup). The window counts updates, never the clock.
local IDLE_SHIP,IDLE_MISSION=60,30
local NO_HOVER={waiting_for_player=true,waiting_for_avatar=true,no_backpack=true,no_jump_pack=true,
    not_hover_pack=true,pack_not_owned=true,pack_not_attached=true}
local gate_row=ffi.new('uint8_t[8]')
local gate_into={data=gate_row,address=tonumber(ffi.cast('uintptr_t',gate_row)),size=8}
-- true answers this frame (nothing to do); false runs the full check.
function M.idle(api,state)
    local left=state.idle_left
    if not left or left<=1 or state.lease then state.idle_left=0;return false end
    state.idle_left=left-1
    local at=state.idle_at
    if at~=0 and not (api.read(at,5,gate_into,0) and gate_row[0]==0) then state.idle_left=0;return false end
    return true
end
-- After a full check: how many frames the gate may answer, and what it reads.
local function arm(state,status)
    local left,at=0,0
    if state.lease then left=0
    elseif status=='waiting_for_mission' then left=IDLE_SHIP
    elseif NO_HOVER[status] then left=IDLE_MISSION
    elseif status=='waiting_for_hover' and not S.active and L.stage==4 then left,at=IDLE_MISSION,L.states+L.ji*5
    end
    state.idle_left,state.idle_at=left,at
end

local function work(api,game,state)
    local s,reason=read_snapshot(api,game,state)
    if state.lease then
        if s and s.key==state.lease.key and s.active then return 'native_descent' end
        if not M.settings.restore(api,game,state) then return 'restore_pending' end
        M.policy.step(state,nil)
    end
    -- Without a hover-pack snapshot there is nothing to focus-gate: skip the
    -- window/process system calls on every such frame.
    if not s then M.policy.step(state,nil);return reason end
    -- Without a flight the policy only resets and no cancellation can start,
    -- so the focus check could not change the outcome.
    if not s.flight then M.policy.step(state,s);return 'waiting_for_hover'end
    return fly(api,game,s,state)
end
function M.apply(api,game,exe,state)
    local status=work(api,game,state)
    arm(state,status)
    return status
end
-- Undo this mod's change to the game and start afresh (the loader calls it
-- when the mod pauses, stops or shuts down): the restore's result (true, or
-- false and why while it waits), and the policy forgets the flight, so a
-- flight in progress needs a release and a new press before it can be
-- cancelled.
function M.cleanup(api,game,state)
    state.idle_left=0;M.policy.step(state,nil)
    return M.settings.restore(api,game,state)
end
-- The snapshot's stages are straight-line code that runs once per frame.
-- Compiled, they took about 34 KB of the LuaJIT code cache that the game and
-- every mod share (the whole mod 44,464 bytes in the game's lua51.dll) to
-- save about 2 us per frame in a test process. Interpreted, the helpers they
-- call (reads, pointers, map probes, record compares, the float decoder) still
-- compile and the mod's machine code stays near 10 KB. This marks only these
-- functions; it flushes nothing. The callers of M.snapshot (read_snapshot,
-- work, M.apply) are interpreted too: a trace started in one of them aborts
-- at the snapshot ("blacklisted") and would retry on every full check. The
-- idle gate (M.idle, arm) and the policy still compile.
if jit and jit.off then
    for _,stage in ipairs({mission,local_unit,avatar_record,avatar_slot,backpack,jump_pack,attached,pack_state,
        resolve,check_avatar,check_equipment,check_pack,warm,M.snapshot,read_snapshot,work,M.apply})do
        jit.off(stage)
    end
end
return M

end)()
local install=(function()
-- runtime: src/bingus_runtime.lua (v1). Its guard holds the update chain: the
-- updates below this mod run outside pcall, so their errors reach the game
-- unchanged; this mod's work runs after them under pcall. 8 of its own errors
-- stop it, counted per burst (a count starts again after 3600 clean frames).
-- An error below pauses it: the hover duration is restored, the flight
-- forgotten, and the work resumes once the updates below have returned on 60
-- frames in a row (8 such errors stop it). The first failure survives
-- shutdown, here and in BingusRuntime.statuses.ControllableHoverPack.
return function(create_api,patch,build,runtime)
    if rawget(_G,'HoverPackCancel') then return end
    local state={revision=build.revision,cancellations=0,updates=0,active=false}
    rawset(_G,'HoverPackCancel',state)
    local api,last_report
    -- The log file with the status and counters. Defined once, outside report:
    -- a closure built inside report would make report uncompilable (UCLO
    -- before every early return) on every frame that reports.
    local function write_log(status)
        local logger=rawget(_G,'CowboyBingusModLoader')
        local f=logger and logger.open_log and logger.open_log('ControllableHoverPack.log');if not f then return end
        f:write(build.revision..'\n'..status..'\n')
        for _,key in ipairs({'updates','cancellations','restorations','snapshot_waits','settings_waits','restore_waits'}) do
            f:write(key..'='..tostring(state[key] or 0)..'\n')
        end
        for _,key in ipairs({'snapshot_status','mission_type','last_snapshot_error','last_settings_error','last_restore_error'}) do
            f:write(key..'='..tostring(state[key] or 'none')..'\n')
        end
        f:close()
    end
    local function report(status,force)
        state.status=status
        if not force and rawget(_G,'CowboyBingusDiagnostics')~=true then return end
        local now=api and api.time() or 0
        if not force and last_report and now-last_report<2 then return end
        last_report=now
        print('[ControllableHoverPack] '..build.revision..': '..status)
        pcall(write_log,status)
    end
    local ok,adapter,game,exe=pcall(function()
        local loader=rawget(_G,'CowboyBingusModLoader')
        assert(type(loader)=='table' and type(loader.api)=='number' and loader.api>=1
            and type(loader.version)=='number' and loader.version>=12,'Bingus Shared Loader v11 / API 1 is required')
        local a=create_api();local g,e=a.module('game.dll'),a.module(nil)
        assert(g and e,'Required modules unavailable')
        assert(a.module_hash(g)==build.game_sha256 and a.module_hash(e)==build.exe_sha256,'Unsupported game build')
        assert(type(update)=='function','Game update unavailable')
        return a,g,e
    end)
    if not ok then report(tostring(adapter),true);return end
    api=adapter
    -- restore_logged: the first restore that raised is logged, once per
    -- session. After a stop: retry_pending, a lease is left to restore;
    -- retry_frame, updates since the stop; retry_next, the next attempt's.
    local restore_logged,retry_pending,retry_frame,retry_next,shutting_down,guard=false,false,0,1,false,nil
    -- patch.cleanup restores the hover duration and forgets the flight: true
    -- and why it still waits (nil once restored), or false and why it raised.
    local function cleanup()
        local ok,result,reason=pcall(patch.cleanup,api,game,state)
        if ok then return true,reason end
        reason=tostring(result)
        if not restore_logged then restore_logged=true;report('restore_failed: '..reason,true)end
        return false,reason
    end
    -- After a stop the guard runs nothing of this mod. A lease the stop could
    -- not restore is tried again on the 1st, 2nd, 4th ... 512th update after
    -- it (10 attempts over about 8.5 s at 60 FPS), so a short read failure
    -- such as a mission transition can pass. An attempt that raises and one
    -- that keeps the lease count alike; after the last, one line names why.
    -- Updates are counted; the clock is not read.
    local RETRY_LAST=512
    local function retry_restore()
        retry_frame=retry_frame+1
        if retry_frame<retry_next then return end
        local _,reason=cleanup()
        if not state.lease then retry_pending=false
        elseif retry_next<RETRY_LAST then retry_next=retry_next*2
        else
            retry_pending=false
            report('restore_abandoned after 10 retries: '..tostring(reason or 'hover duration not restored'),true)
        end
    end
    -- The last restore attempt and report, with the first failure, at shutdown.
    local function finish()
        state.active=false;retry_pending=false
        local failure=guard.status.first_failure
        local ran=cleanup()
        report((ran and not state.lease and 'stopped' or 'restore_failed')..(failure and ' after: '..failure or ''),true)
    end
    -- Every frame the guard runs this mod: the work, after the game's update.
    -- An error here goes to the guard, which counts it. The patch's idle gate
    -- (hover_data.lua M.idle), if it has one, answers frames with nothing to
    -- do first: no snapshot, pcall or report. It never raises; any frame it
    -- does not answer gets the full check.
    local idle=patch.idle
    local function after()
        state.updates=state.updates+1;state.active=false
        if idle and idle(api,state) then return end
        local status=patch.apply(api,game,exe,state)
        state.active=status=='watching_hover' or status=='native_descent'
        report(tostring(status))
    end
    -- The guard calls after under pcall, so a trace started at its entry
    -- aborts where it returns ("NYI: return to lower frame") and retries
    -- forever, filling LuaJIT's 64-slot penalty cache. It has no loop: it
    -- runs interpreted, and the gate and snapshot helpers it calls still
    -- compile. This marks only this function; it flushes nothing.
    if jit and jit.off then jit.off(after) end
    -- An update below raised: restore and start afresh while the guard pauses
    -- this mod. A restore that cannot finish now raises, and the guard stops
    -- the mod instead, as it did on every such error before.
    local function pause()
        state.active=false
        cleanup()
        if state.lease then error('hover duration not restored',0) end
    end
    -- The guard stopped this mod (it calls this once, also at shutdown).
    local function stop()
        if shutting_down then return finish() end
        state.active=false
        cleanup()
        retry_pending,retry_frame,retry_next=state.lease~=nil,0,1
    end
    local PREFIX='ControllableHoverPack '
    local function log(line)
        if line:sub(1,#PREFIX)==PREFIX then line=line:sub(#PREFIX+1) end
        report(line,true)
    end
    local installed,problem=pcall(function()
        guard=runtime.guard({name='ControllableHoverPack',after=after,pause=pause,stop=stop,log=log,env=_G}).install()
    end)
    if not installed then report(tostring(problem),true);return end
    -- After a stop the guard runs nothing of this mod, so the restore attempts
    -- above run here, before the guarded update. Every frame pays one boolean
    -- test and a tail call (unmeasured in game), so that a stop cannot leave a
    -- pack's hover duration cut; errors from below still reach the game
    -- unchanged.
    local guarded_update,guarded_shutdown=update,shutdown
    update=function(...)
        if retry_pending then retry_restore() end
        return guarded_update(...)
    end
    -- A running guard calls stop at shutdown (first failure already known);
    -- a stopped one does not, so the last attempt and report happen here.
    shutdown=function(...)
        shutting_down=true
        if not guard.running() then finish() end
        return guarded_shutdown(...)
    end
    report('waiting_for_mission',true)
end

end)()
patch.policy=policy;patch.settings=settings
install(function()return create_api(runtime,runtime_write.extend(runtime_memory.new(runtime)))end,patch,{revision='v1.8.1-26088801',game_sha256='6D1D4D3BC6FC84801D9F8F1B310E13A603D07409F3D9495D74B42E1D0BB1C08F',exe_sha256='0ACC07DEBE04714AE04281E1A66BD2EB9D3D85232953E32A93C8A3DD0874EABE'},runtime)
