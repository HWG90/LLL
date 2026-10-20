# Live Lua Loader (LLL)

Lua loader and in-game mod manager for Helldivers 2 on Windows x64.

## Current Steam preview

[Download R33 Steam Lua 5.1 preview](https://github.com/HWG90/LLL/releases/tag/R33-steam-lua51-preview.1).
This preview targets Steam build **25988413** and checks the exact game-file
fingerprints. The older [R31 release](https://github.com/HWG90/LLL/releases/tag/R31)
targets the previous build.

Extract the preview ZIP and follow its `README.txt`. With the game closed, run
the included PowerShell installer with your game folder. It installs the startup
patch and external helper together, preserves existing settings and mods, and
saves a rollback receipt. No compiler or Python is required. See the
[installation and removal instructions](docs/STEAM-PREVIEW-INSTALL.txt).

The manager defaults to **Insert**. Its open/close binding is configurable; existing
saved bindings are preserved. Mouse click, drag and scroll work. Individual Lua
mods belong in `%LOCALAPPDATA%/LLL/Helldivers2/Mods`.

The game now uses Lua 5.1. LuaJIT `ffi`, `bit` and `jit` are unavailable; older
mods that depend on them need individual ports. LLL refuses declared incompatible
imports before execution. A discovered or enabled entry alone does not prove a
working mod. MCM and third-party mods are not bundled.

**Gameplay keyboard suppression remains unfinished.** Movement keys can still
reach the diver while a menu or free camera is open. The shared input service
provides exclusive menu/camera ownership, mouse-look capture, relative mouse
deltas and cleanup; it must not be treated as a gameplay keyboard gate.

## Changes in this preview

- Insert as the default manager key for fresh configurations; valid saved bindings stay unchanged.
- Shared asynchronous SDR game-window screenshots for cooperating mods, with capture work in the external helper.
- WinRT factory cleanup that fixes the helper crash on a later screenshot job.
- Dead-helper transport failures retire helper-dependent UI and maintenance once, without repeated pipe attempts.
- Startup support for the current Steam Lua 5.1 VM and automatic external-helper startup.
- Working manager mouse input and shared menu/camera leases for cooperating mods.
- Foreground-loss cleanup, token-checked restoration and registered MCM ownership.
- Manager hotkey deferral when it shares MCM's binding.
- Streaming import checks that avoid building large token arrays.
- In-memory catalog listings and retirement of watches for removed projects after a completed scan.
- Portable installation, game-build checks, owned-file rollback and conflicting-loader refusal.

The deployed base port has user-confirmed manager open/close/reopen, mouse
interaction and normal controls after closing. A quiet 30-second loader sample
measured **4.47 ms/s** aggregate and **1 ms** worst callback. These are earlier
base-port measurements, not a fresh benchmark of every change in this release
or whole-game frame time. The latest catalog/import changes have startup
acknowledgement and offline checks; their final live cost remains unmeasured.

The screenshot helper has survived repeated user-operated 3840x2160 SDR captures
and Photo Mode close/reopen. The helper code is unchanged in this preview's
rebuilt Insert-default startup package. The existing installation already uses
a saved Insert binding; the new fresh-configuration default has offline checks.
See [screenshot validation](docs/STEAM-SCREENSHOTS.md) for the bounded helper CPU
sample and remaining HDR, colorimetry and gameplay-input limits.

The portable installer is tested with isolated filesystem fixtures. It has not
yet had a separate clean-machine gameplay acceptance test. See
[compatibility and validation limits](docs/STEAM-LUA51.md).

## Mod authors and development

- [Steam backend and build instructions](docs/STEAM-LUA51.md)
- [Shared input API](docs/STEAM-INPUT-SERVICE.md)
- [Shared screenshot API candidate and validation limits](docs/STEAM-SCREENSHOTS.md)
- [Compatibility inventory](docs/STEAM-COMPATIBILITY.md)
- [Modular projects](docs/MODULAR-PROJECTS.txt)
- [Migration guide](docs/MOD-MIGRATION.md)
- [Typed console commands](docs/CONSOLE-COMMANDS.txt)

Build from the maintained standalone repository using the explicit output paths
in the Steam backend instructions. The normal release excludes the temporary
developer command relay. Source, tests and helper C code are included in Git;
native binaries are built separately. Historical LuaJIT build instructions and
release notes apply to their corresponding older game build.

Required stock startup-callback preservation and third-party helper notices are
disclosed in the package. No game executable, DLL, font, personal settings or
third-party mods are distributed. No repository-wide open-source license has
been selected.
