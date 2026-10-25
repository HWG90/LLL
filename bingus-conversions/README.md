# Bingus conversions — Steam build 26088801 (LuaJIT)

CowboyBingus's Helldivers 2 mods (each Zero-Clause BSD, see its `LICENSE`), converted from Steam
build 25480438 to 26088801 for the LuaJIT VM (`docs/LUAJIT-LIVE.md`). Each is the upstream LuaJIT
source at the Vanilla Plus Megapack's pinned revision with its build data remapped: no Lua 5.1
compatibility layer and no `cffi`. Where code changed beyond build data, the option's `NOTES.md`
says so (mostly: code pages that are no-access until the game first runs them are now read through
ReadProcessMemory and checked right before first use).

Per option: `MAP.json` (every build-specific constant: old, new, evidence, confidence), `NOTES.md`
(what is verified, every memory write and its evidence, read-only live checks), `out/` (built
entries, diffs against upstream, build receipt, upstream test results) and `live/` (the read-only
probes, run through Link's Link to Memory). Archives are built from `out/`; the full working files
(build scripts, tools, evidence) live in the porting workspace.

Status on Proton, 2026-10-25 (read-only checks on the ship, in menus and in a mission, then installed):

| Option | Status |
|---|---|
| ModOptionsMenu 1.2.1 | installed, working (native MODS tab) |
| MatchYourColors 1.5 | installed, working (recolors; weapon source lease build) |
| BetterStratagemBounce | installed, applied (105 flags); header-tail check dropped (varies in 26088801) |
| HellpodSteeringUnlocked | installed, works in missions |
| StickyGrenadeHandles | installed, applied |
| StratagemHeroExpanded | installed, applied (108 stratagems) |
| ReinforcementBeaconsFixed | installed, waiting for a reinforcement |
| SoundSystemsRebalanced | installed; `stingray.Wwise.set_state` is gone, so it calls the Wwise plugin's exported `SetState` after a byte check (matched live); music bank rebuilt for the current banks |
| ModBindingsMenu | installed, working |
| ClickableScrollbars | installed |
| GalacticMenuHotkey | installed, ready |
| ArmoryPreviewCache | installed; briefing-widget offsets unconfirmed (fails safe) |
| KnowYourConstellation | installed; roster regenerated for 26088801 (new Defiler units unnamed) |
| BetterLobbyManagement | installed; Lobby Region and squad chat off (4 code ranges encrypted in every capture) |
| ArcThrowerRevamped | installed, charge record ready |
| ConsistentVaulting | installed |
| ShallowWaterDiving | installed, depth option registered |
| FoliagePassThrough | installed, applied (95 projectiles; 4 left out) |
| FlameDamageFixed, HolsterYourShield, LaserSentryCooldown | built; Bingus Shared Loader's `loader.jit` check removed (`LOADER-CHECK-EDIT.txt`), install pending |
| ControllableHoverPack | built; hover duration +0x9C confirmed 6.0 s live, rebuild with it accepted pending |
| HellpodDropHold | built; live pods carry a type hash it does not expect: re-map pending |
| SentryAimRetention | built; behavior ids confirmed live (309/208/214); speed setters never decrypted in play: binds only after their byte check |
| EnemyCollisionSynchronized | built; collision-layer check unconfirmed: do not install yet |
