Live Lua Loader 0.1.8 � R31 Helldivers manager

READY TO USE
No build step, Python, compiler, MDL, MCM, Bingus, DBF HUD or developer checkout is required.
Requires Windows x64 and Helldivers 2 Steam build 25480438. The game supplies LuaJIT, GUI APIs and its main HUD font (compatibility fallback when unavailable). The original LLL native helper is embedded, verified and extracted automatically.

INSTALL — MOD MANAGER (OPTIONAL)
Import this ZIP into Arsenal/HD2MM, enable Live Lua Loader R31 Helldivers manager, and give it winning startup-loader priority. In Arsenal's default priority order, place it last. Disable other shared startup loaders (MDL/Bingus). Deploy while the game is closed, then launch normally.
Other gameplay/utility mods are installed separately; this ZIP contains no third-party mods.

INSTALL — DIRECT COPY
For a clean installation, copy the three files inside data/ into the game's data/ folder. Launch normally. There is no separate bootstrap/tool to install.
If 9ba626afa44a3aa3.patch_0 already exists, do not overwrite it: use your mod manager to allocate/manage patch priority, or rename all three files to the same unused higher .patch_N number after disabling the other shared loader. Keep track of that number for removal.

USE
F8 opens the independent LLL manager; Escape closes it. Review script status, enable/disable supported loose scripts, Refresh discovery or Reload a selected script. Auto-reload watches completed edits. MCM integration is optional.
Runtime creates %LOCALAPPDATA%/LLL/Helldivers2/{Mods,Settings,Logs} and LLL.cfg automatically.
Copy a complete loose mod folder containing mod.lua and its required assets/libraries into Mods/. Loose .lua files are also supported. The optional examples/heartbeat.lua can be copied there as a smoke test; it changes no gameplay.
Existing MDL/CowboyBingus folders are compatibility search locations only; they need not exist. Archived Bingus-compatible addons are discovered from separately installed game patches.
Each mod is responsible for its own dependencies and cleanup. Archive-only addons without a reload contract require a new game session for changes. The MDL API adapter supports a subset, not universal compatibility.

CHECK STARTUP
Logs/LiveLuaLoader.log should identify 0.1.7 (R31 Helldivers manager). The manager should open without MCM/HUD installed. Check module counts and errors. Test a loose script edit and its cleanup on the recipient's machine.

UNINSTALL
Close the game. Remove/disable LLL through your manager and redeploy, or remove ONLY the three LLL .patch_N files copied for direct installation. Your other mod files and saves are retained.
The Local AppData LLL folder can be retained for settings/mods or removed separately after backing up anything wanted. No existing MDL or Bingus folder is modified by uninstalling LLL.

VALIDATION AND LIMITS
Offline isolated LuaJIT lifecycle/discovery/menu/cleanup and package checks pass. Native helper uses Windows system DLLs only. This exact R31 Helldivers manager package has not been live tested on a clean installation.
Unsupported game builds are refused. Non-ASCII paths and the full range of third-party addons still need recipient testing.
The experimental free camera is NOT included. Existing loose mods, loadouts, presets and personal settings are NOT bundled.

LEFT MOD LIST
Groups identify actual loader ownership reports separately from script location. Each mod shows Loaded, Loading, Disabled, Discovered, Not installed or Needs attention. A file in MDL Mods does not imply an MDL runtime instance. Genuine external loader registry entries are read-only; ambiguous/lost ownership is shown honestly. This candidate is based on R18 and retains its game-build/callback constraints.

R24 RELIABILITY AND MANAGER
Source/status groups contain author subgroups; missing metadata is Unknown author. Drag window edges/corners to resize. Width, height and position save in LLL.cfg. Long labels scroll within bounded widths; description paragraphs wrap and scroll. Connector trunks stop at child junctions and clip below group headers.

With either manager open, press grave/tilde to toggle the shared diagnostics window. The LLL and MCM surfaces share one bounded event stream and window state, using the existing parent input lease. Close/handoff releases console interactions; gameplay does not acquire a console hotkey.

The shared LuaJIT machine-code limit starts at 64 MiB (65536 KiB), with 8000 traces. Observed flushes can double the code limit to 128 and 256 MiB, at most once every 30 seconds. Trace limits grow to 16000 only while Lua heap usage is below 24 MiB. Flush events do not expose causes: diagnostics say observed flush, not exhaustion. No forced flush, dummy allocation or initial Lua-heap reserve is performed. An existing trace observer is retained; adaptive growth then remains unavailable. The code limit stays configured after loader removal rather than guessing a previous limit.

Read-only feature declarations and bounded after_startup callbacks support mod-author detection. Startup health records build stamps, prior-session state, newest available crash summaries, and per-load CPU time, heap changes and shared-state changes. Archive diagnostics identify active and hidden copies and retain that metadata in the persisted cache. Private captured Lua dependencies and private Windows declarations protect loader operations from ordinary builtin/library replacements and conflicting external cdefs; intentional modifications of public loader/engine state and other hosts' internals are not isolated.

Exact R24 package remains subject to fresh-launch visual, dragging, console handoff and input-restoration checks. It contains no experimental camera change: independent screenshot-camera movement is still unresolved.

R25 METADATA
Owned creation/package metadata defaults to Goose. Loose mods use per-ID JSON sidecars; unrelated shared-folder manifests are not inherited. Folder manifests retain their established conventions. See MOD-METADATA.txt.

R26 UI REFRESH
F8 remains the default; Manager Settings can change Open/Close, UI scale and font size. Window reset and selected-setting defaults use buttons. Apply and Discard have no extra shortcuts. See UI-REFRESH.txt for layering, provenance and manual acceptance checks.

R27 TEXT BOUNDS AND RESIZE GRIPS
Native text widths no longer fall below the conservative stock-font estimate. The regression exercises underestimated native metrics at small, normal and screenshot-sized resolutions with scaled text. Four visible corner grips show hover/active drag state. Offline desktop-font previews alone do not prove native clipping; this repair requires an in-game check.

R28 INTERACTIONS AND METADATA
Trees start closed. Right-click a setting for Apply, Discard, Reset or Rebind;
right-click a sidebar node for Open, Expand/Collapse, Collapse all or Expand all.
Individual mod pages also provide Edit metadata. Open/Close defaults to F8,
Confirm/Apply to Tab and Focus to F6; each is rebindable in Manager settings.
Key captures and text editors own their input before Apply. Tab commits an active
text field before confirming the page; validation failures retain the editor.
Metadata Name/Author/Description are local overrides in LLL.cfg metadata_overrides.
Apply saves all fields together. Discard preserves existing values. Failed writes
retain drafts. Manager settings includes Allow metadata edits (enabled by default)
backed by metadata_editing; locking also rejects Apply in an already-open editor.
Resource identity, source, runtime ownership and third-party files are preserved.
This candidate is built/tested, not deployed or live-accepted.

R29 LAYOUT AND INDICATOR LAYERS
Adaptive sidebar width, separate count badges, short source labels and status
markers leave more space for names. Long names wrap to available viewport height with explicit
ellipsis only when longer; expanders use geometric strokes in an aligned column.
Connector trunks reference actual ancestors rather than preceding siblings.
The selected page alone is highlighted while its root is expanded. Manual sidebar
width remains adjustable. One page heading replaces repeated loader/page titles;
control rows are compact and informational text wraps without a repeated banner.
Layer order: shell 90, rows 95, focus 99, controls 100, inner frames 101,
fills 102, indicators 103, text 109. Popup bands preserve the same role offsets.
Indicators and glyphs are audited through hover/value/selection transitions,
including native handle retention and immediate ID reuse. The test receipt is
an offline native API fixture; exact game appearance remains unverified.

R30 MODULAR PROJECTS AND CONSOLE
See MODULAR-PROJECTS.txt and CONSOLE-COMMANDS.txt. Folder templates are now the default. Console input supports registered typed setters/getters/actions. Review packages are undeployed; native activation and visual acceptance remain separate checks.

Helldivers UI review candidate: see EPIC-UI-PARITY.txt for layout/font, sliding switches, source log ingestion and verbose_launch configuration.
