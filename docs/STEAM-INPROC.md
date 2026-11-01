# In-process Steam service (LuaJIT boot runtime)

When the LuaJIT boot runtime takes over (Proton only; native Windows refuses the runtime DLL with error 577), its
embedded LLL needs no Steam helper, launcher, cffi or nativeinfo DLL. The helper's byte protocol is answered inside
the game by `native/steam_inproc.c`, which the runtime compiles in (HD2 repo `runtime-modules/vm-poc/lll_host.c`)
and hands to Lua as `package.preload['hd2.lll_host']`. `src/steam/transport_inproc.lua` replaces
`src/steam/transport.lua`; `platform.lua`, `input.lua`, `input_service.lua`, `screenshot_service.lua` and
`capture.lua` are unchanged, so `input_service`, `capture_service`, `mod.set`, config folders and discovery behave as
with the helper. The PUC (Lua 5.1) build keeps the external service, launcher, cffi and nativeinfo.

| Ops | In-process |
|---|---|
| 0 handshake | The service's two stock SHA-256 pins, checked once against the running exe and game.dll; pid and paths of this process |
| 1–9 files, watches, poll, close | `steam_files.c` / `steam_service.c` operations into a reply buffer (no request/response files) |
| 10–12 pointer | `steam_pointer.c` snapshots. With a game mouse registration (one RawInput target per process), a read-only `WH_GETMESSAGE` hook on the target window's thread reads the packets the game receives; without one, the helper's own sink |
| 13–15 screenshot | Refused with `ERROR_NOT_SUPPORTED`: Wine's `graphicscapture.dll` is a stub, so the helper's WGC capture also fails on Proton. The facade still gives `output_directory` and `new_job_token`, which War Journalist's host worker uses |
| 16–18 keyboard | `steam_keyboard.c` unchanged; its `RegisterHotKey` worker thread runs in the game process |

`transport_inproc.lua`'s `nativeinfo()` gives `ui/font` nativeinfo's `module_base` and `read_memory` for this process.
cffi needs nothing new: the runtime has always answered `package.loadlib(…,'luaopen_hd2_cffi')` with its proxy over
LuaJIT's ffi by symbol; the embedded LLL now names no file (`hd2-runtime:ffi`).

The service writes `%LOCALAPPDATA%/LLL/Helldivers2/Steam/inprocess.log`: the hash check, which pointer reader each
lease used, the first screenshot refusal, close.

## Tests

`native/test_steam_inproc.c` runs under Wine against the real external service and compares every reply byte for byte
(screenshot requests excepted), then the pointer reader selection and a fatal request:

    x86_64-w64-mingw32-gcc -std=c11 -O2 -Wall -Wextra -municode -Inative -o test_steam_inproc.exe native/test_steam_inproc.c -lbcrypt -luser32
    wine test_steam_inproc.exe <lll_steam_service_*.exe for this build> <game root>

The HD2 runtime repo's `runtime-modules/boot-26251122/inproc_test/` runs `src/steam/platform.lua` over
`transport_inproc.lua` with the runtime's own registration code.
