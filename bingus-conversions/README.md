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

On 2026-10-29 at 06:19 Steam updated the game to build 26251122. Every option here checks the 26088801 exe and
game.dll hashes and refuses to run on the new build. The 26251122 ports are not published here.
