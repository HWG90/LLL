# Live Lua Loader (LLL)

> **Branch `LLL_JIT_Live`:** the game's Lua VM as LuaJIT 2.1 at boot, LLL in its own LuaJIT build
> (no helper, no cffi DLL). Working on Linux/Proton; native Windows refuses the runtime DLL (error
> 577). See [docs/LUAJIT-LIVE.md](docs/LUAJIT-LIVE.md). The CowboyBingus mods used to test the VM
> (Mod Options Menu, Match Your Colors on build 26088801) are kept outside this repository.

Lua loader and in-game mod manager for Helldivers 2.

> **NOT FOR THE LIVE GAME UNLESS YOU ARE ON LINUX. IT WILL NOT WORK ON WINDOWS.**
>
> The current CFFI release is for **Linux with Proton only**, on Steam build
> **26088801**. Native Windows CFFI loading fails with system error 577.

## Current Steam preview

[Download R35 Linux/Proton + CFFI](https://github.com/HWG90/LLL/releases/tag/R35-26088801-linux-cffi.1).
This includes the corrected CFFI pointer arithmetic, Insert open/close fix,
native HUD font helper, external input service, and native launcher.
Exact game-file fingerprints are checked before installation and startup.

Extract the complete ZIP, close the game, and follow `README.txt`. The included
`install_proton.py` installs the startup patch, service, launcher and native
modules together, preserves settings and mods, and saves a rollback receipt.
Python 3 is required on Linux; no compiler is needed to install the prebuilt ZIP.
See the [installation and removal instructions](docs/STEAM-PREVIEW-INSTALL.txt).

The manager defaults to **Insert**. Its open/close binding is configurable; existing
saved bindings are preserved. Mouse click, drag and scroll work. Individual Lua
mods belong in `%LOCALAPPDATA%/LLL/Helldivers2/Mods`.

The game uses Lua 5.1. This release exposes `require("cffi")`; it does not alias
LuaJIT `ffi`, `bit` or `jit`. Older
mods that depend on them need individual ports. LLL refuses declared incompatible
imports before execution. A discovered or enabled entry alone does not prove a
working mod. MCM and third-party mods are not bundled.

LLL's manager now captures gameplay keyboard input. In the current game, the
user confirmed that W/A/S/D, Shift, Ctrl and Space were blocked while the
manager's keyboard and mouse controls worked; closing with Insert restored
normal movement. Other menus and cameras must opt in to keyboard capture through
the shared input service and read its key bitmap. Existing mouse-only consumers
keep their previous behavior. Windows keys, F12 and reserved system shortcuts
are excluded. The matching Photo adapter also passed human checks: freecam
W/A/S/D, Shift and Ctrl moved the camera while the diver stayed still;
menu/camera switching worked, and closing restored normal movement.

## Changes in this preview

- Insert as the default manager key for fresh configurations; valid saved bindings stay unchanged.
- Gameplay keyboard capture for LLL and opt-in consumers, with owned cleanup on close or foreground loss.
- Menu/camera transitions retain the keyboard lease instead of releasing and reacquiring it.
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

The deployed R34 manager has user-confirmed keyboard capture, working menu
keyboard/mouse input and restored movement after closing. A quiet 30-second
sample measured **9.00 ms/s** inclusive loader time, **7 ms** worst tick and zero
keyboard-helper calls. A 90-second mixed menu/camera/idle sample measured
**14.15 ms/s**, with one **13 ms** close transition including **8 ms** in keyboard
release; whole-helper CPU averaged **1.91 ms/s** over that mostly idle sample.
Lua timings include observer overhead and child mod callbacks; these are not
exclusive LLL CPU, pure active-capture cost or whole-game frame time. The older
**4.47 ms/s** base-port result is historical and not directly comparable. See
[input validation](docs/STEAM-INPUT-SERVICE.md) for the sample counts and limits.

The R33 screenshot implementation survived repeated user-operated 3840x2160 SDR
captures and Photo Mode close/reopen. R34's native helper adds hotkey capture;
its screenshot job and WinRT factory components are unchanged from that
live-tested implementation, and their native fixtures pass.
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
