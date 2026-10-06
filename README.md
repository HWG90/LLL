## R25 metadata convention

Owned-mod creation and release manifests default to author **Goose**. Loose scripts use matching `<id>.json` sidecars; folder mods retain `manifest.json`, `mod.json`, or `metadata.json`. Unknown/external authors are not replaced or inherited from the shared Mods directory. See [metadata usage](docs/MOD-METADATA.txt). R25 source/package is ready for a future loader update; this does not hot-replace an existing running VM.

## R24 source and local candidate

The current source adds source/author grouping, a resizable standalone manager, bounded text and connector geometry, and the shared MCM/LLL diagnostics console. It also adds privately captured Lua dependencies and Windows signatures, capability queries, after-startup callbacks, startup health/copy diagnostics, and a 64 MiB shared LuaJIT code budget with bounded observed-flush growth.

See [the R24 API and parity checklist](docs/R24-API-AND-PARITY.txt). The earlier R20 download links below remain historical published artifacts; R24 source does not imply that those ZIPs include these changes. Exact in-game visual/input acceptance remains a separate validation step. Experimental screenshot-camera motion is unresolved and is not bundled.

# Live Lua Loader (LLL)

Independent Lua loader and F9 mod manager for Helldivers 2. Discovers archive
addons, loads loose scripts, watches completed edits and waits for owned cleanup
before replacing a script. MCM integration is optional.

## Downloads

- [R20 candidate prerelease](https://github.com/HWG90/LLL/releases/tag/R20-candidate) — grouped mod list and permanent input-restoration fixes.
- [Download the R20 candidate ZIP](https://github.com/HWG90/LLL/releases/download/R20-candidate/LiveLuaLoader-0.1.2-R20-grouping-candidate.zip)
- [R20 SHA256 checksum](https://github.com/HWG90/LLL/releases/download/R20-candidate/LiveLuaLoader-0.1.2-R20-grouping-candidate-SHA256.txt)
- [R18 stable release](https://github.com/HWG90/LLL/releases/tag/R18)

Import the ready-made ZIP into a supported mod manager or follow its README.txt
for direct installation. No compiler, Python, MDL, MCM, Bingus loader or DBF HUD
installation is required by LLL. Individual mods may have dependencies. Requires
Windows x64 and Steam build 25480438.

## R20 changes

The manager's left list groups LLL live scripts, archive addons loaded through
LLL, genuine MDL/Bingus runtime registries, and unknown or conflicting ownership.
Each mod shows its runtime status separately from its source location. A script
in an MDL folder does not imply that MDL loaded it. External entries are read-only,
identities are deduplicated, and LLL's Bingus compatibility facade is not counted
as a second loader. Group headings show loaded-report counts.

Input cleanup retains the original cursor snapshot if restoration fails, supports
safe retry, and refuses a new handoff until the previous menu releases ownership.
See [grouping details](docs/MANAGER-GROUPING.txt).

All 22 offline contract groups and package checks pass. R20 is a prerelease;
combined live visual/input validation is pending. R18 remains the stable release.
The separate R19 update-compatibility experiment is not included in R20.

## Mod author guide

[Port a Bingus or archived Lua mod to live loading](docs/MOD-MIGRATION.md): tested
lifecycle examples, persistent settings, cleanup, asset limits and verification.

Loose scripts belong in `%LOCALAPPDATA%/LLL/Helldivers2/Mods`. Existing MDL and
CowboyBingus locations are also scanned. Saved settings use indented Lua tables
with stable ordering; older single-line settings remain compatible.

## Source and development

ARCHITECTURE.txt describes the modules and retained lean improvements. Original
Lua, native helper C, build tools and contract tests are included in this repo.
The candidate ZIP includes a `source/` directory with pinned build inputs and
generated runtime source. Required stock callback bytecode and the native helper
are disclosed in CONTENTS-NOTICES.txt; binary inputs are excluded from Git.

Development builds require Python 3 and the supported game's LuaJIT DLL. Extract
`source/`, then run `python tools/build_release.py --output dist/release`.
MSVC x64 is required only to rebuild the helper. `python tests/run.py` runs
isolated LuaJIT contracts after packaging; it does not attach to the game.

Compatibility adapters support a subset of third-party APIs; universal mod
compatibility is not claimed. Experimental camera code is excluded.
No repository-wide open-source license has been selected.
