## Release 0.1.8 / R31

[Download R31](https://github.com/HWG90/LLL/releases/tag/R31). Helldivers-styled manager with sliding switches, bounded layout, main HUD font, Tab acceptance, direct diagnostics without external mod-log ingestion. Includes modular folder projects and typed console commands. See [release notes](docs/RELEASE-NOTES.txt), [UI/log configuration](docs/EPIC-UI-PARITY.txt) and [installation](docs/README.txt).

The full isolated test suite and package integrity checks pass. R31 rendering and log behavior still need in-game validation; publishing this release does not deploy it.

## R30 modular projects and console candidate

Native folder projects use a small `main.lua`, a manifest-selected entry, separate `src/` modules and shipped JSON CFG defaults. User overrides live outside the mod folder. Private imports and dependency-aware preflight/reload are implemented; legacy mods remain supported. See [project layout](docs/MODULAR-PROJECTS.txt).

The LLL console has command input, execution feedback and history. `dbfhud.global.opacity = 20` applies 20% to all weapon panel backgrounds through the HUD settings writer. Mods register typed command surfaces for menu and hidden settings; cleanup removes their commands after acknowledgement. See [console usage](docs/CONSOLE-COMMANDS.txt).

Maintained MCM, HUD, Epic LUT and DBF have modular LLL review builders/packages. DBF remains restart-only. Packages and offline checks do not establish native/game acceptance; nothing is deployed by these builders.

## R29 layout and layering candidate

Adaptive navigation width, aligned geometric expanders, actual-parent connectors, status markers, separate counts and wrapped names. Content uses one page heading and compact rows. Control backgrounds, inner frames, fills, indicators and text have explicit separate depths; regression checks exercise recycled native IDs across changing states.

Build into `dist/releases/layout-20261010`. Source, test receipt and approximate previews are review artifacts; this candidate is not deployed or live-accepted.

## R28 interactions candidate

Right-click actions, editable Open/Close/Apply/Focus bindings, Tab to confirm and collapsed startup trees. In-game metadata editing provides Name, Author and Description drafts, local persistence, Discard and a future lock flag (enabled by default). Local overrides update author grouping without changing runtime ownership or third-party manifests.

Build: `py -3 tools/build_release.py --output dist/releases/interaction-20261010`. Offline interaction and persistence checks are separate from live acceptance. This candidate is not deployed.

## R27 screenshot repair candidate

Native glyph and whole-word widths retain the conservative font-width floor, preventing small native extents from admitting sidebar text beyond its allotted width. Tests exercise the native measurement path with deliberately underestimated metrics. All four resize corners now have visible grips with hover/drag feedback.

Build into `dist/releases/text-bounds-20261010`. The supplied screenshot confirms the R26 overflow and missing grips; R27 is packaged for local validation, not yet live-proven. Approximate desktop-font previews cannot establish game clipping.

## R26 UI review candidate

LLL now uses the suite's quieter UI, stable background/control/text depths and separate text, theme, pointer and render modules. Source/author groups keep their existing runtime ownership and read-only external entries. Manager Settings provides a rebindable Open/Close key (F8 default), UI scale, font size and window reset. Apply, Discard and Reset Setting use buttons.

Uneven columns keep their own viewport positions. Sidebar, settings, help and dropdown scrollbars support dragging. Long labels scroll only while hovered/focused; informational rows wrap. Cursor restoration is verified and idle LLL cannot release another frontend's native input gate.

Build: `py -3 tools/build_release.py --output dist/releases/ui-refresh-20261009`. [Design and layer audit](docs/UI-REFRESH.txt). Offline checks and approximate compose previews are separate from in-game acceptance. This candidate is not installed or published.

## R25 metadata convention

Owned-mod creation and release manifests default to author **Goose**. Loose scripts use matching `<id>.json` sidecars; folder mods retain `manifest.json`, `mod.json`, or `metadata.json`. Unknown/external authors are not replaced or inherited from the shared Mods directory. See [metadata usage](docs/MOD-METADATA.txt). R25 source/package is ready for a future loader update; this does not hot-replace an existing running VM.

## R24 source and local candidate

The current source adds source/author grouping, a resizable standalone manager, bounded text and connector geometry, and the shared MCM/LLL diagnostics console. It also adds privately captured Lua dependencies and Windows signatures, capability queries, after-startup callbacks, startup health/copy diagnostics, and a 64 MiB shared LuaJIT code budget with bounded observed-flush growth.

See [the R24 API and parity checklist](docs/R24-API-AND-PARITY.txt). The earlier R20 download links below remain historical published artifacts; R24 source does not imply that those ZIPs include these changes. Exact in-game visual/input acceptance remains a separate validation step. Experimental screenshot-camera motion is unresolved and is not bundled.

# Live Lua Loader (LLL)

Independent Lua loader and F8 mod manager for Helldivers 2. Discovers archive
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
