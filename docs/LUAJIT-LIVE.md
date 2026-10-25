# LuaJIT Live — Steam build 26088801

Helldivers 2's current build runs its scripts in PUC Lua 5.1. LuaJIT Live replaces that VM with
LuaJIT 2.1 at boot, so the stock scripts, Live Lua Loader and mods run with JIT, `ffi` and `bit`.

## Status

| | |
|---|---|
| Linux / Proton | Working since 2026-10-24: stock scripts boot in LuaJIT, LLL runs, 53–55 mods load, original native callbacks served through a bridge to the engine's PUC VM. |
| Native Windows | Untested. The game has refused other custom DLLs there with system error 577 (`ERROR_INVALID_IMAGE_HASH`), so a refusal is expected. The package only reports the outcome. |
| Drop-in package on Proton | Pending its first boot. |

Measured on Proton against PUC (same session layout): engine callbacks 14.5 vs 23.2 ms/s, mods
1.9–5.2× faster, Lua heap about 36 vs 44 MB with the engine's timed collector driving LuaJIT.

## How it works

1. The boot resource `f476df93691895fa` starts with `src/luajit_live/prologue_dropin.lua`. It writes
   the runtime DLL it carries to `data/hd2_luajit_runtime_<hash>.dll`, checks it byte for byte and
   loads it. The outcome goes to `%LOCALAPPDATA%\HD2-LuaJIT-boot-result.txt`.
2. The runtime creates the LuaJIT state, bridges the engine's natives from the PUC VM, translates
   the stock bytecode (exact original bytes to recovered source), runs the stock startup and then
   LLL, and forwards the engine's init/update/render/shutdown to LuaJIT.
3. LLL runs its own LuaJIT build (`tools/build_luajit_live.py`): files, folders and module reads go
   through `ffi`, so it needs no external helper and no cffi module.
4. If the runtime is refused, the rest of the boot chunk is LLL R35's own boot, unchanged (Lua 5.1).

## Building

```
python tools/build_luajit_live.py --game "<Helldivers 2>" --capture-helper mcm_input_d5c4d9333fc3.dll --output lll_luajit_26088801.lua
python tools/build_luajit_live_package.py --lll-archive <R35 boot patch_0> --lll-source <R35 boot source> \
  --lua51-32 <32-bit Lua 5.1.4> --runtime <runtime DLL> --mom <MOM archive> --myc <MYC archive> --output <zip>
```

The first prints SHA-256 `76f43c365fa86e951144b303811ea0beb8d9026caf0719f97108e4a6b5339710` for the
LLL build in runtime `hd2_luajit_runtime_0aa7ada7ec5a86ce.dll`. `steam_resources.py` needs the
`lz4` module. The runtime's own C source is not in this repository.

## Installing

Import the release zip into HD2 Arsenal, enable "LuaJIT VM + Live Lua Loader" (and the ports you
want), disable any other LLL and the Megapack's copies of the same mods, then Purge / Deploy. Its
README covers the result file and removal.

## Known limits

- LLL's LuaJIT build has no shared input service (the Steam helper provides it), so mods that need
  it (DBF-MCM, DBF freecam) do not enable.
- `require('cffi')` returns the runtime's alias over LuaJIT's `ffi`, so mods ported to the Lua 5.1
  VM keep loading. Plain `ffi` is the target once LuaJIT is confirmed everywhere.
- Hellpod Drop Hold's Lua 5.1 port fails to load (`PORT51` missing in its implementation).

## Ports

`ports/ModOptionsMenu` and `ports/MatchYourColors`: the original LuaJIT mods with build data
remapped for 26088801 and checked in game. See `docs/LUAJIT-LIVE-NOTICES.txt` for contents and
licences.
