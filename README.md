# Live Lua Loader (LLL)

Private development source for the Helldivers 2 Lua loader. This export contains the current lean loader with deferred cleanup, archive addon discovery, loose-script loading, lifecycle adapters, status integration and the independent manager.

Loose scripts live under `%LOCALAPPDATA%/LLL/Helldivers2/Mods`. Existing MDL and CowboyBingus locations are also scanned. Mods own their cleanup; failed restoration blocks replacement. Compatibility does not imply every third-party mod works, and offline checks do not prove live input or rendering.

## Build

Windows x64, Python 3 and MSVC 2022 are required. Run `python tools/build_native_lean.py`, then `python tools/build.py --callbacks PATH_TO_LOCAL_STOCK_RESOURCE --game-root PATH_TO_GAME`. The stock callback resource must include its eight-byte Lua envelope and match the supported hash. Native helper binaries and original game callbacks are local build inputs, excluded from Git. Building does not deploy or launch the game.

`python tests/run.py` uses the installed game's LuaJIT DLL in an isolated Python process. Lua contract fixtures are in `tests/`; they use synthetic resources. Build-specific guards reject unsupported installations.

## Scope

Includes original loader Lua, archive/build utilities, native input helper C source and contract fixtures. Excludes extracted game code/assets, compiled binaries, deployment packages, saved settings, logs, camera research and other mods. This is a source checkpoint, not a public release or a claim of complete live validation. No license has been selected for this private checkpoint.