# Live Lua Loader (LLL)

## 0.1.0 / R18

Independent Lua loader and F9 status manager for Helldivers 2. Discovers archive
addons, loads loose scripts, watches completed edits and waits for owned cleanup
before replacement. MCM integration is optional.

Download the ready-made R18 ZIP from Releases. Import it into a supported mod
manager or follow README.txt for direct installation. No compiler, Python, MDL,
MCM, Bingus loader or DBF HUD installation is required by LLL. Individual mods
may have their own dependencies. Requires Windows x64 and Steam build 25480438.

Loose scripts belong in `%LOCALAPPDATA%/LLL/Helldivers2/Mods`. Existing MDL and
CowboyBingus locations are also scanned. Saved settings use indented Lua tables
with stable ordering; older single-line settings remain compatible.

## Mod author guide

[Port a Bingus or archived Lua mod to live loading](docs/MOD-MIGRATION.md): lifecycle examples, settings, cleanup, asset limits and verification against R18.

## Source and development

ARCHITECTURE.txt describes the modules and retained lean improvements. Original
Lua, native helper C, build tools and contract tests are included in this repo.
The source release ZIP additionally provides the pinned native helper, required
stock callback bytecode and generated runtime source for the release build.
These binary inputs are excluded from Git and disclosed in CONTENTS-NOTICES.txt.

Development builds require Python 3 and the supported game's LuaJIT DLL. Extract
the source ZIP, then run `python tools/build_release.py --output dist/release`.
MSVC x64 is only required to rebuild the helper. `python tests/run.py` runs
isolated LuaJIT contracts after packaging; it does not attach to the game.

## Validation

R18 passes offline discovery, config roundtrip, lifecycle, menu, watcher/cache,
cleanup and package checks. The native source builds and its input tests pass.
The exact R18 package has not been live tested on a clean installation.
Compatibility adapters support a subset of third-party APIs; universal mod
compatibility is not claimed. Experimental camera code is excluded.

No repository-wide open-source license has been selected.
