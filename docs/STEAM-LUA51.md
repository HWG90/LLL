# Current Steam Lua 5.1 backend

Supported Steam build: 25988413, Windows x64. The build and helper check exact game file hashes; later builds require fresh verification. This backend preserves the stock startup return values and update/shutdown callbacks.

The shipped VM is Lua 5.1. LuaJIT `ffi`, `bit` and `jit` are unavailable. A literal dependency check refuses those imports before executing a mod. Dynamic imports cannot be fully established statically. Native mods need individual ports; an enabled discovery entry does not prove a working mod.

LLL uses a normal external helper for filesystem notifications, metadata and active pointer input. The startup launcher verifies its content-addressed filename/hash and waits on a bounded readiness event. Both local pipe clients must belong to the same process. No native hooks, game-memory access or game input-registration changes are used. The helper's own message-only window receives raw mouse input while an input lease is active.

## Build

Requirements: Python 3.14 with `lupa.lua51` and `lz4`, Windows x64, and Visual Studio 2022 Community C build tools in the configured build script location. Use the original installed files of the supported game build.

From the standalone LLL repository:

```powershell
py -3.14 tools/build_steam_service.py --output dist/review/steam-service
$env:LLL_TEST_STEAM_SERVICE=(Resolve-Path dist/review/steam-service).Path
py -3.14 tests/test_steam_service.py
py -3.14 tests/test_steam_launcher.py
py -3.14 tests/test_steam_runtime.py
py -3.14 tests/test_steam_input.py
py -3.14 tests/test_steam_capture_service.py
py -3.14 tests/test_steam_input_service.py
py -3.14 tests/test_steam_catalog_lifetime.py
py -3.14 tests/test_steam_native_preflight.py
py -3.14 tools/build_steam_release.py --game 'C:/path/to/Helldivers 2' --service dist/review/steam-service --output dist/review/steam-candidate
```

The normal builder excludes the development command relay. Outputs include a startup patch, content-addressed helper, ZIP, generated runtime and build receipt. Its default mode embeds the resolved game path supplied to the builder for local review/deployment. Public packages use `--portable --release-label R32-steam-lua51-preview.1`: the installer writes a per-install game-path binding, and the launcher validates that path and the exact game/helper hashes before starting. The helper belongs in `%LOCALAPPDATA%/LLL/Helldivers2/Service`, separately from the game resource patch. Do not assume a generic mod-manager ZIP import installs the external helper. See [portable installation and rollback](STEAM-PREVIEW-INSTALL.txt).

`tools/deploy_steam_release.py` is a guarded update tool for an existing reviewed startup patch. It requires the game closed and an explicit SHA256 preimage, preserves configuration, creates a rollback archive and verifies installed bytes. It refuses unknown archive contents. It is not a general clean-install installer. Keep other mods and saved settings separate.

## Verification boundary

The deployed port has user-confirmed F8 open/close/reopen, mouse click/drag/scroll and normal-control restoration. Its quiet 30-second loader sample measured 134 ms over 3,469 callbacks (4.47 ms/s, 1 ms worst). The clock has 1 ms resolution; this does not measure whole-game frame time.

The large incompatible Photo camera source's complete failed-load check fell from 2,365 ms / +602,983 KB to 34 ms / +21,172 KB after streaming native preflight. The camera source was refused before execution. A subsequent follow-up also replaces the declared-import token array for portable modules; see [the compatibility inventory](STEAM-COMPATIBILITY.md). That follow-up is now installed in the review candidate; its import-scanner performance figures remain offline measurements.

The shared input service also has live consumer evidence: a bounded 60-second observer recorded 1,230 successful snapshots, absolute raw movement totals dx=5,618 / dy=762, and closed -> menu -> camera -> menu -> closed transitions. Final ownership was empty with no pending restoration. The observer wrapped existing requests only; it restored its wrapper and was removed. No wheel activity occurred in that sample, so it does not prove live wheel delivery. This observer did not measure aggregate runtime cost.

The user confirmed War Journalist's camera/menu transitions and normal return, while reporting that movement keys also move the native player during freecam. A later MCM test likewise confirmed scrolling, settings and close/reopen but reported native movement while its menu was open. Mouse-look capture works; gameplay keyboard/action isolation remains unfinished. The service must not be represented as suppressing gameplay movement keys. See the shared API document for ownership and cleanup.

The catalog/import follow-up is installed and acknowledged by a fresh startup log. Completed scans now retire removed project watches; failed/incomplete scans retain their prior catalog and watches. The actual Windows helper fixture measured small listings falling from 1.980 to 0.082 ms and 96 files/12 directories from 2.858 to 0.894 ms over 400 iterations. Those are isolated listing measurements, not final live aggregate cost. The portable launcher/installer changes are covered by isolated fixtures; separate clean-machine gameplay acceptance is pending.
