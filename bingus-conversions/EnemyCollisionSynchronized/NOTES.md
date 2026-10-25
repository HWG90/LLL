# Enemy Collision Synchronized v2.13.0 — port to game build 26088801

Offline, static port. Nothing was installed; the game folder, `~/.config/hd2arsenal`, `<steam-library>` (read only:
binaries hashed, data folder listed) and `upstream-bingus/` were not written; the game process was not touched.
Source: `upstream-bingus/EnemyCollisionSynchronized` (tag `v2.13.0`; every pinned file equals the lock; the pack copy
is identical).

**Status: built; not cleared for install until live checks L1, L4 and L5 pass** (install gate below).

Rebuild: `python3 -I tools/scan_assets.py && python3 -I tools/build_map.py && python3 -I -B build.py --tests &&
python3 -I tools/make_probe.py` (build_map ≈ 1 min).

## Files

| File | What |
| --- | --- |
| `MAP.json` | 789 rows (38 high, 751 medium, 0 low): 2 pins, 11 native-API rows, 32 layout/global rows, the claw names, a comment, and one row per data line of the generated allowlist `src/corpse_profiles.lua` (744). Global sweeps, cluster stats and callee comparisons are in the header. |
| `tools/sweep.py` | witness machinery: every old RIP xref of a global (numpy disp32 scan + capstone), `bindiff.migrate` unique windows, instruction alignment around each site; whole-function / linear cluster sweeps. |
| `tools/build_map.py` | computes every row from the captures (nothing typed in by hand). |
| `tools/scan_assets.py` → `tools/asset-scan.json` | attempt to compare the 21 profiles' asset hashes with the installed data (blocked, see below). |
| `build.py` | copy, remap, assemble with upstream `scripts/module.py build_module()` (compile step captured), reproduce v26 with a private non-GC64 LuaJIT, archive, LuaJIT checks, tests. |
| `out/wrapper.lua` (plaintext payload), `out/option_entry.lua`, `out/985c9039ef17db8e.lua.main`, `out/9ba626afa44a3aa3.patch_0` (+ empty `.stream`/`.gpu_resources`) | the option: ONE resource, `mods/cowboybingus/corpse_collision_repair`, in the pack's `discoverable_resource()` shape with the plaintext wrapper as payload. |
| `out/build-receipt.json`, `out/TESTS.json`, `out/wrapper.diff` | hashes, the 26 replaced lines, reproduction, tests. |
| `live/ecs_readonly.lua` | read-only probe L0–L5. |

## What changed (build data only; 26 wrapper lines)

| Row | Old | New | Evidence |
| --- | --- | --- | --- |
| pins | F5FEE03D… / 2E2C3B7C… | 0ACC07DE… / 6D1D4D3B… | hashed from the install |
| physics binding global (game) | 0x3326338 | 0x2CE1500 | 40/40 xrefs agree; the new capture holds `exe+0x2874ED0` there (old: `exe+0x27CD910`) |
| binding table (exe) | 0x27CD910 | 0x2874ED0 | registration function (old 0x7800B0 / new 0x807350) fills the same 32 slots in the same order |
| slot 8 disable actors | 0x77F4F0 | 0x806790 | 226 = 226 instructions identical apart from relocations |
| slot 0x60 set position | 0x799880 | 0x820C40 | 61 = 61 identical; same prologue bytes |
| slot 0x68 set rotation | 0x799BA0 | 0x820F60 | 60 = 60 identical; same prologue bytes |
| ragdoll stop routine (game) | 0x7ABD00 | 0x7B76A0 | unique window; 37 = 37 instructions, 152 bytes, relocations only |
| `stop_hex` | old 152 bytes | new 152 bytes | the new routine's bytes |
| completion request (game) | 0x13C0350 | 0x12573A0 | unique window; 100 = 100 instructions, 422 bytes, relocations only; data refs = live-verified globals |
| `completion_hex` | old 422 bytes | new 422 bytes | the new routine's bytes |
| completion service (game) | 0x346D500 | 0x2E28758 | 40/40 xrefs agree; also the stop routine's data ref |
| mission mode slot | 0x33266A0 | 0x2CE1850 | 40/40 (matches the Reinforcement Beacons port) |
| ragdoll manager slot | 0x3326948 | 0x2CE1AF8 | 7/7 (+ the initializer's new store at 0x5717B5) |
| corpse manager slot | 0x3326920 | 0x2CE1AD8 | 40/40 |
| corpse slot in the mode-slot view | 0x280 | **0x288** | derived (slots no longer equidistant); ragdoll 0x2A8 unchanged; span 0x2B0 still covers both |
| physics world slots (exe) | 0x27BA8A8 | 0x2861D88 | 6/6; stride 0xB0 in 89 aligned pairs |
| body getter (exe, vtable+136) | 0xD0CFA0 | 0xD658D0 | unique byte-identical getter pair in each exe at the same vtable slot; 93/93 havok-world functions identical |
| actor pools (exe) | 0x2369B00 | 0x2411200 | 9/9 (matches Sentry Aim Retention) |
| unit registry (exe) | 0x1A100F0 | 0x1AB76F8 | 40/40 (matches Reinforcement Beacons, Sentry Aim Retention) |
| actor lists (exe) | 0x27C5B40 | 0x286D030 | 33/33 |

"n/n" = agreeing / mapped xref windows (each sweep stops at 40 agreeing); no global has a disagreeing window
(one masked window in the ragdoll initializer was set aside, not counted).

Unchanged, witnessed (aligned instruction pairs with the same displacement/immediate and no changed pair): ragdoll
header (+4/+12/+16/+20/+56/+72/+80), corpse header (+16/+24/+28/+64/+72), entity +8 id and +0x14 bit 0 owned,
runtime stride 11192 and meta +11160/+11172/+11173/+11176, sync stride 432 (+184, +428), member stride 712 / sub
stride 76, mode +8 / +0x40, pool record layout, registry layout (+0x88/+0x98/+0xA0, 22-bit index), actor-list
record, unit object (+0x60 scene graph: +0x70 node count, +0x88 node matrices, 64 bytes each), world body array
(+0x18, ×160, `& 0xFFFFFF`). Callees of the two routines align; their only differences are internal game layouts
consistent with the known build changes (entity component table, session block +8).

## Native commands (the mod writes no memory; these are its "writes") and their witnesses

| Command | Target | Witnesses |
| --- | --- | --- |
| `stop_sync(manager, index)` | game 0x7B76A0 (byte-compared before use) | routine identical; manager/index from the witnessed ragdoll layout; remote-only gate unchanged |
| `request_completion(service, 0, entity id)` | game 0x12573A0 (byte-compared) | routine identical; service global 40/40; entity id +8 witnessed |
| `pose(actor, pos, quat)` | exe 0x820F60 then 0x820C40 via the binding table (slots checked at bind) | functions identical; actor id from the witnessed actor list; target = node matrix at `[obj+0x88] + node*64` (witnessed); the actor's node / node hash / name must equal the profile |
| `disable(actor)` (3 Impaler claws) | exe 0x806790 | function identical; claw names must match an allowlisted Impaler actor |

## Medium rows and the install gate

* **Allowlist (744 profile rows) and claw names — runtime-guarded.** Asset-derived (21 resources, 680 actor
  mappings). The catalog's build-25480438 asset hashes could not be compared with this build: the game's data is now
  in 57 DirectStorage `DSAR` containers (chunk compression type 3, presumably GDeflate; no decoder offline). Every
  value is compared with the live unit before any command (resource key, node count, body count, ordered main names,
  actor name → node hash), so a changed asset makes the unit skipped, not mis-commanded. **L5** confirms the 21
  profiles still match live units.
* **Body fields (+64/+108/+144/+148) and actor row fields (+12/+16/+24/+28/+32) — runtime-guarded.** The modules
  that use them are identical (physics actor 422/432, havok world 93/93); +144/+148 (id/unit) and +12 (owner) are
  compared with the actor and unit before use; +20 is witnessed directly (set_position).
* **Install gate — `data.filters` (layers 52/48/83), not runtime-guarded.** Bodies on these collision layers are
  never acted on. Layer numbers come from the physics settings resource (in the DSAR data). If they were renumbered, a
  body the old build excluded could be posed when its actor is on the allowlist. **L4** reports the layers of main
  and allowlisted auxiliary bodies; do not install until main/ragdoll bodies show the expected layers.
* `data.member_fields` (+12 count, +28 ids: only mark actors as "registered", i.e. excluded), `data.bounds`
  (sanity bounds), the `0x7A4B30` comment: medium, no command depends on them.

## Risks / not verified

* **Code pages at load:** `api.bind` reads the stop (152 B) and completion (422 B) routines and the two setter
  prologues with ReadProcessMemory when the mod loads (upstream logic, kept). If those game.dll/exe pages are not yet
  resident at boot, the read fails and the mod disables itself for the session (safe, but inactive). L1 reports
  readability. Changing that to a check right before first use would be a logic change, not done here.
* Gameplay effect, multiplayer authority and contact damage remain unverified (as upstream).

## Tests (`out/TESTS.json`)

Upstream offline suites, port vs unmodified upstream, workspace Windows LuaJIT (GC64) under Wine (private prefix),
fixtures' global addresses mapped for the port run (22 occurrences, counted):

| Suite | Port | Upstream |
| --- | --- | --- |
| test_module, test_snapshot, test_loader, test_metadata_cache, test_repose_cooldown, test_profiler, test_profiler_detail, test_profiler_behavior, test_profiles.py | pass | pass |
| test_ffi_names | Wine page fault (exit 5) | same |
| test_performance | 3 PASS lines, then fails at line 413 | same |

Identical results: the two failures are environment (Wine / the GC64 JIT), not the port. Under Linux GC64 LuaJIT
most suites fail for both (no kernel32). test_repair / test_fling / test_settlement / test_completion need
`tests/fixtures` (private recordings, absent): not run. Reproduction: the unmodified wrapper compiled with a private
non-GC64 LuaJIT equals the lock's resource SHA-256 (`F25F51BD…`) and the v26 option resource byte for byte.
GC64 check: the option entry and wrapper compile with `loadstring` (FR2 set); the entry, run in a host table
(loader API 1, no game), loads its payload and stops in its own pcall (`active=false`, update untouched).

## Read-only in-game checks (`live/ecs_readonly.lua`)

B = game.dll base, X = exe base. Reads only.

* **L0** `CorpseCollisionRepair.log`: revision `v2.13.0-26088801`, no "Unsupported…", "Physics binding
  unavailable", "Ragdoll stop routine changed" or "Corpse completion request changed".
* **L1** (ship) `ptr(B+0x2CE1500) - X == 0x2874ED0`; slots +8/+0x60/+0x68 = X+0x806790/0x820C40/0x820F60, the last two
  starting `48895c240848896c`; 152 bytes at B+0x7B76A0 and 422 bytes at B+0x12573A0 readable and equal to the new
  `stop_hex`/`completion_hex`; `ptr(B+0x2E28758)` non-null.
* **L2** (mission) `ptr(B+0x2CE1850)`: +8 = 1 in a mission (0 on the ship), +0x40 = 2. Ragdoll manager
  `ptr(B+0x2CE1AF8)`: active ≤ count ≤ capacity ≤ 8192, owned (+20) ≤ active; corpse manager `ptr(B+0x2CE1AD8)`
  (+16/+24/+28). Listed entities print id/unit/owned and, for ragdolls, runtime body count (= profile bodies), update
  byte (0/1), sync counts.
* **L3** `ptr(X+0x2861D88+176*i)` worlds; `ptr(ptr(world)+136) - X == 0xD658D0`.
* **L4** per listed unit (≤ 6): registry slot object id == unit, node count == profile nodes, generation; per actor:
  row identity, owner == unit, body id/unit match, layers. **Gate:** the layer histogram (`main:` / `aux:`).
* **L5** per unit: main names found == profile count; every allowlisted aux actor's node hash equals the profile.
