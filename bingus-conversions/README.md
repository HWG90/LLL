# Bingus conversions — Steam build 26251122 (LuaJIT)

CowboyBingus's Helldivers 2 mods (each Zero-Clause BSD, see its `LICENSE`), converted for the LuaJIT VM
(`docs/LUAJIT-LIVE.md`). Steam delivered build 26251122 on 2026-10-29. Each option's `26251122/` folder is its port
from the 26088801 conversion below, changing build data only unless noted:

- `<resource>.lua`: the built entry as plain Lua. Some are installed wrapped in a `loadstring` blob; the receipt's
  `sha256` is the installed body either way.
- `<resource>.diff`: against the 26088801 entry.
- `receipt.json`: every edit (kind, old, new, count), both builds' hashes and the re-derived code checks.
- `live/`: the option's own read-only probes, run through Link's Link to Memory.

`26251122-live/megapack_26251122_readonly.lua` checks every changed value in game.

Status on Proton, 2026-10-31. All 24 were installed on 2026-10-29 at 17:00 with the game closed. The 18:21 launch's
read-only check gave ok=46 bad=0 wait=2; the two waits are Better Lobby Management checks on lobby pages the game had
not run yet.

| Option | 26251122 |
|---|---|
| All 24 | exe and game.dll SHA-256 gates; the build number in revision and message strings |
| EnemyCollisionSynchronized | enabled/position/rotation 0x806640/0x820AF0/0x820E10, body getter 0xD65790. **Accepted in game on 2026-10-31**: over a 2.5-hour session it accepted 810 units and realigned 246, with no skips or retries |
| SentryAimRetention | pose getter 0x1F3020, raycast 0x87BB20, world id 0x826BC0. The first port left the world-id call at the old address (a bare `ret` on this build), so the raycast read an empty physics world and a mission crashed on 2026-10-30. Fixed the same night, keeping revision data-v8.6: a 2.5-hour session then ran without an error, holding aim 291 times and pausing fire 341 times. data-v8.7 (2026-10-31) also skips the terrain check while the game world's physics slot is empty |
| BetterStratagemBounce | the settings buffer is 82376 bytes (was 82384); the 82384 build refused with "Incomplete stratagem settings", the new one plans all 105 flags. Reinstalled at 18:32 |
| ArmoryPreviewCache | package acquire/release 0x2F01E0/0x2F0440, image create/destroy/register 0x2EA520/0x2EA930/0x2ED540, texture formats 0x16F48B0; 5 code checks re-derived |
| BetterLobbyManagement | PlayFab layout and members 0x9561B0/0x956232, continent ids 0x205D100; 7 code checks re-derived |
| ConsistentVaulting | 9 physics functions moved; `flags` 0x8205B0; controller vtable 0x17430A8 |
| KnowYourConstellation | tag hash table 0x2069D70, byte-identical; rosters unchanged |
| ReinforcementBeaconsFixed | scene-graph getter 0x28D310 |
| ShallowWaterDiving | 5 `.rdata` floats, each +0x20 |
| SoundSystemsRebalanced | the Wwise plugin's `SetState` export is at 0xDA130, prologue unchanged |
| ClickableScrollbars | 1 code check re-derived |
| ArcThrowerRevamped, ControllableHoverPack, FlameDamageFixed, FoliagePassThrough, GalacticMenuHotkey, HellpodDropHold, HellpodSteeringUnlocked, HolsterYourShield, LaserSentryCooldown, ModBindingsMenu, ModOptionsMenu, StickyGrenadeHandles, StratagemHeroExpanded | hash gates and build strings only |
| MatchYourColors | not here yet: its 26251122 build (with backpack recolouring) is still being tested |

## Steam build 26088801: the base

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
| FoliagePassThrough | installed, applied (95 projectiles; 4 left out). 2026-10-28: refuses at load while SHODAN Stat Editor's offline Foliage Pass-Through edit is in the game data (it set one rocket to template 2, the build-25480438 value; 2 is the back-face query in 26088801) |
| FlameDamageFixed, LaserSentryCooldown | installed 2026-10-25 (Bingus Shared Loader's `loader.jit` check removed, `LOADER-CHECK-EDIT.txt`); both initialize, the Laser Sentry heat record applies |
| ControllableHoverPack | installed 2026-10-25 with the hover duration +0x9C (6.0 s, confirmed live); accepted in game |

Updated 2026-10-29 (all four installed 2026-10-28 22:59 local into the Megapack package and its deployed archives; not yet run in game):

| Option | Status |
|---|---|
| HellpodDropHold | the "unexpected type hash" was stratagem pods (`0x73F8498B…` is an existing pod type in both builds; the player-pod hashes keep their avatar-spawn sites): no re-map; the port is installed as built |
| EnemyCollisionSynchronized | live L1–L5 passed (profile keys unchanged, main bodies on layer 52, layer names 11/14/55 as in 25480438); its routine checks now run right before first use instead of at load (`out/logic.diff`) |
| SentryAimRetention | the game never runs its two turret speed setters, so it now does their work itself (registry lookup, owner bit, verified write, then the replication routine `0xE69780`, checked in full); the horizontal setter's body was read live and equals the prediction (`out/logic.diff`) |
| HolsterYourShield | installed 2026-10-25, but disabled itself at load ("game function unreadable: send_held"): its three game functions are now checked right before the first move instead of at load |

On 2026-10-29 at 06:19 Steam updated the game to build 26251122. Every option in this section checks the 26088801
exe and game.dll hashes and refuses to run on the new build; the 26251122 ports are in each option's `26251122/`
folder (top of this file).
