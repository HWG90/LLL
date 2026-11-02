-- Port to Steam build 26088801, the one non-data edit (native-work/megapack-port/SoundSystemsRebalanced/NOTES.md):
-- the engine no longer registers stingray.Wwise.set_state. That binding called the Wwise plugin's exported
-- AK::SoundEngine::SetState(const char *, const char *), which the already-loaded plugin still exports. No DLL is
-- loaded: the plugin must already be in the process. Before every call the export must resolve at its expected RVA
-- and its first bytes, read with ReadProcessMemory (api.read: the page may be unreadable until the game first runs
-- it), must equal the expected prologue; otherwise nothing is called and one line is logged.
Mod.WWISE = {
    module = 'wwise_pluginw64_release.dll',
    export = '?SetState@SoundEngine@AK@@YA?AW4AKRESULT@@PEBD0@Z',
    rva = 0xDA120, -- the current plugin file's export table
    -- The export's first 31 bytes (whole, position-independent instructions) in the build-25480438 plugin, built from
    -- the same Wwise SDK 2024.1.9.8920 library. The current file is encrypted on disk: a live match is the check.
    prologue = '\064\083\069\051\201\076\139\218\072\139\217\072\133\201\117\005\069\139\209\235\074\068\015\182\001'
        .. '\065\186\197\157\028\129',
    success = 1, -- AK_Success
}

-- A set_state(group, value) calling the plugin's SetState after those checks (true when Wwise accepted the state,
-- false when it was refused or not called), or nil when the plugin is not loaded. get_proc(module, name) is for
-- tests; by default kernel32's GetProcAddress under a private FFI name.
function Mod.native_set_state(api, note, get_proc)
    local W = Mod.WWISE
    if not api.module(W.module) then return nil end
    get_proc = get_proc or function(module, name)
        if not pcall(ffi.typeof, 'struct ssr_port1_sentinel') then
            ffi.cdef([[struct ssr_port1_sentinel { int unused; };
                void *ssr_port1_GetProcAddress(void *module, const char *name) __asm__("GetProcAddress");]])
        end
        local address = ffi.load('kernel32').ssr_port1_GetProcAddress(module, name)
        if address == nil then return nil end
        return address
    end
    return function(group, value)
        local module = api.module(W.module)
        local address = module and get_proc(module, W.export)
        local why
        if not module then why = 'the Wwise plugin is not loaded'
        elseif not address then why = 'the SetState export did not resolve'
        elseif api.distance(address, module) ~= W.rva then why = 'the SetState export is not at its expected RVA'
        else
            local bytes = api.read(address, #W.prologue)
            if bytes == nil then why = 'the SetState code is unreadable'
            elseif bytes ~= W.prologue then why = 'the SetState code differs from the expected prologue' end
        end
        if why then
            note('Wwise state not set: ' .. why .. '; nothing was called.')
            return false
        end
        local result = ffi.cast('int32_t (*)(const char *, const char *)', address)(group, value)
        if result ~= W.success then
            note('Wwise state not set: SetState returned ' .. tostring(result) .. '.')
            return false
        end
        return true
    end
end

