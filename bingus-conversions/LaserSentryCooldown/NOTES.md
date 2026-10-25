# Laser Sentry Cooldown v1.1.1 → Steam build 26088801 (offline port)

Source: `upstream-bingus/LaserSentryCooldown` (git `v1.1.1`, clean). Every file the lock pins for this option
matches it and the pinned `VanillaPlusMegapack/components/LaserSentryCooldown` copy byte for byte; `build.py`
checks both. Old build 25480438, new build 26088801 (game.dll `6D1D4D3B…C08F`, exe `0ACC07DE…EABE`).

Nothing here touched the network, the game folder, `~/.config/hd2arsenal`, the running game or `upstream-bingus/`.
The only reads under `<steam-library>` were the slim data index (`data/bundles*.nxa`) used to confirm that the Laser
Sentry resource exists. Nothing was installed.

## Deliverables

| Path | What |
|---|---|
| `MAP.json` | 23 rows: 19 high, 4 medium, 0 low, 0 unmapped. 16 rows feed a write, all high. All 28 inventory sites are covered. `witness_check_failures` is empty. `writes` lists W1/W2 with the rows they depend on. |
| `build.py` | `python3 -I -B build.py [--tests]`. Copies the upstream source to `work/upstream` (unmodified) and `work/port`, applies the replacements and assembles both with the component's own `scripts/build.py assemble(False)`, as the pack does (BUILD_ASSEMBLED). It then checks, archives, compiles and smoke-runs the result. |
| `out/entry.lua` | The plaintext entry (declaration first line). It differs from upstream on 31 lines, with the same line count; the diff is in `out/entry.diff`. |
| `out/laser_sentry_cooldown.lua.main` | The entry in the type-2 envelope (`<II len, 2>`). |
| `out/9ba626afa44a3aa3.patch_0` | Only resource `mods/cowboybingus/laser_sentry_cooldown`, built with `BingusSharedLoader/scripts/archive.py make_archive` and round-tripped. The shared stub `79e4f54aa542ec98` is not included. Empty `.stream`/`.gpu_resources` companions sit beside it. |
| `out/build-receipt.json`, `out/TESTS.json` | Hashes, every replacement, LuaJIT output, test results. |
| `tools/` | `lib.py`/`align.py`/`show_pair.py` (from hdh-port), `map_globals.py`, `map_fields.py`, `record_fields.py`, `behavior_enum.py`, `request_gate.py`, `find_resource.py`/`slim_extract.py` (read-only data index), `build_map.py` (writes MAP.json and re-asserts every witness), `mock_llm_probe.lua`. |
| `evidence/` | `globals.json`, `field-pairs.json`, `record-fields.json`, `behavior-enum.json`, `request-gate.json`, `resources.json`, `listings/` (aligned old/new listings of the heat update, presentation, ability script, explosion ability, behavior manager update, request applier, set_state, owner check). |
| `live/laser_sentry_cooldown_readonly.lua` | The read-only live probe for checks L0–L6. |

Rebuild: `cd tools && python3 -I -B map_globals.py && python3 -I -B map_fields.py 200 && python3 -I -B record_fields.py && python3 -I -B behavior_enum.py && python3 -I -B request_gate.py && python3 -I -B find_resource.py 56070F36CFFFA8A8 && python3 -I -B build_map.py`, then `cd .. && python3 -I -B build.py --tests`.

## Packaging

- Upstream ships this option as a plaintext entry (BUILD_ASSEMBLED), never as bytecode, so the GC64 VM loads it as it is.
- The unmodified assembly reproduces the lock's `resource_sha256` (`E3CFC11C…FBB74`) and the resource in the shipped v26 option archive byte for byte. `build.py` checks this on every run.
- There is no PORT51/compat51/cffi text; `build.py` refuses any.
- On Linux GC64 LuaJIT the entry compiles (`string.dump` flags 8 = FR2). It stops at the vendored `bingus_memory`'s first `ffi.load` (kernel32 or bcrypt, in `pairs()` order), exactly where the unmodified entry stops (checked).

## What changed (build data only)

| MAP row | Constant | Old | New | Feeds a write |
|---|---|---|---|---|
| `build.pins` | game.dll / exe SHA-256 pins and refusal text (the "Disabled: unsupported game build" gate) | `2E2C…F51E` / `F5FE…5F06`, "needs 25480438" | `6D1D…C08F` / `0ACC…EABE`, "needs 26088801" | gate |
| `build.revision` | log revision | `v1.1.1` | `v1.1.1-26088801` | no |
| `heat.root_rva` | entities object | 0x346BF98 | 0x2CE41B8 | W1 address |
| `heat.table_offset` | heat settings table field | 0xF12CC8 | **0xF14790** | W1 address |
| `heat.slots` | slot count | 58 | **60** | W1 address |
| `heat.records_offset+size` | records offset / size | 928 / 592 | **960** / 592 | W1 address |
| `heat.ability_vanilla` | the overheat ability id the record must hold | 2866 | **2884** (medium, fail-closed) | gate |
| `heat.manager_rva` | WeaponHeat manager | 0x3326D48 | 0x2CE1F08 | W2 selection |
| `behavior.manager_rva` | behavior manager | 0x3326740 | 0x2CE18F0 | W2 address |
| `behavior.id` | Laser Sentry behavior id | 308 | **309** | W2 selection |
| `comments` | RVAs in comments | see MAP.json | | no |

Without the slot-count and records-offset changes, the 25480438 lookup would probe the wrong slots and compute record addresses 32 bytes short. Without the behavior id change, the turret watch would refuse every sentry ("unexpected behavior 309").

Unchanged, with witnesses:
- record size 592;
- record fields +0x50/+0x54/+0x5C/+0x60/+0x64/+0x80/+0x8C/+0x90/+0x248;
- resource hash `0x56070F36CFFFA8A8`;
- header magic/version/type;
- WeaponHeat manager +0x14/+0x40/+0x58, 12-byte states with +8 overheated;
- entity record +0/+8/+20;
- behavior manager +0x34/+0x40/+0x48/+0x4C/+0x50/+0x58/+0x60, 504-byte blocks with +0/+8/+12/+16;
- states 6/7/13 and the request sentinel −1.

## The writes and their evidence

### W1: the Laser Sentry heat record, 9 bytes in 2 ranges

- **What it writes:** 5 bytes at record+0x8C (temp_loss_per_second_overheated := the record's own idle rate from +0x80; needs_reload_after_overheat := 0) and 4 bytes at record+0x248 (overheat_ability := 0).
- **How:** the page is checked (committed, private); VirtualProtectEx sets RW for the span, the bytes are written and the protection restored, then the bytes are read back. Restore writes back the vanilla bytes that were read there.
- **Address:**
  - `[game+0x2CE41B8]` is the entities object: 42/42 witnesses agree, 27 of them exact windows.
  - The heat settings lookup (old 0x50DD30 → new 0x516310), reached from the heat getter (old 0x50E1F0 → new 0x5167C0, byte-identical except RIP targets) by its tail jump, reads `[entities+0xF14790]`.
  - A raw scan of every instruction finds exactly 3 sites of +0xF12CC8 (old) and 3 of +0xF14790 (new). They pair 1:1 with identical code.
  - The lookup itself changed: `hash % 60` (reciprocal 0x8888888888888889, `imul 0x3c`), wrap at 0x3B, 0x3C probes, records at `table + 0x3C0 + 0x250*index`. The old build had % 58 and +0x3A0.
  - The getter's override path still uses 0x250-byte records.
- **Semantics:**
  - WeaponHeat update (old 0x762F60 → new 0x76E3F0, 183/183 aligned). Every `[rdi+X]` record operand is identical. The only non-branch operand difference is an engine-interface slot +0x2C8→+0x2D0 in an unrelated effect call.
    - An overheated instance cools by `[+0x8C]*dt` only when `[+0x90]` is 0.
    - It recovers (state+8 := 0) when the temperature is ≤ `[+0x64]` and `[+0x90]` is 0.
  - Presentation (old 0x763780 → new 0x76EC10, 1098/1098 aligned): `mov r14d,[r13+0x248]; test r14d,r14d; je skip`, so 0 plays no ability.
- **One behavioral difference:** while the per-instance input at +0xC is non-zero (the beam powering up or winding down), 26088801 skips cooling, where 25480438 took the overheated-rate branch. With the mod, an overheated sentry therefore does not cool during those ~0.7 s. Upstream's comment (lines 20–21) about extra cooling then no longer holds. The overheated, idle path the mod relies on is unchanged.
- **Gates (fail closed):** header magic/version/type and the size bound, the EXPECTED values, the vanilla cooling bytes and the vanilla ability id must all hold, or the mod refuses before writing.
  - **Ability id 2884 (medium):** the ability script switch grew from 2867 to 2885 cases.
    - In the old build exactly one id, 2866, dispatches to the explosion ability 0x1150660. Its body is identical to new 0xFE3550, and in the new build exactly one id dispatches there: 2884.
    - Whether the 26088801 record really holds 2884 is game data (`generated_entities.dl_bin` is encrypted). With the wrong id the mod logs "already changed by something else" and stops, with no write.

### W2: behavior block +12 (pending state request) := 7, one u32

- **When:** only for a Laser Sentry this machine owns and simulates (entity flags % 4 == 1) whose heat instance overheated and then cleared. The block must read behavior 309, state 6 and request −1.
- **How:** the block page is private RW, so the bytes are written directly and read back.
- **Address:**
  - `[game+0x2CE18F0]` is the behavior manager: 27 witnesses, 26 exact. The one disagreement is masked-only, the template twin at 0x4ADCCA also rejected by hdh-port. The world initializer stores `&world[+0xEED2B8]` there (old +0xEEBA08).
  - Taint field pairs show +0x34/+0x40/+0x48/+0x4C/+0x50/+0x58/+0x60 unchanged.
  - The manager update (old 0x843040 → new 0x84FF40) computes `blocks + 0x1F8*index`.
  - The owner check (0x843930 → 0x850830, 103/103 identical) probes the id map exactly as `map_value` does.
- **Semantics:**
  - Manager update: if `[block+0xC] != -1`, it calls the gate (state at block+8, id at block+0) and then the applier with the request.
  - set_state (old 0x32B6B0 → new 0x3323B0, 422/428 aligned; it differs only in three sound/ability immediates and its jump table) stores the request as the last state (+16), −1 as the request (+12) and the state (+8).
- **Behavior id 308 → 309 (high):** three independent switches agree.
  1. The behavior dispatcher (old 0x472F60, new 0x479CA0, 693 cases each): the only new case whose body and all 13 state handlers match old 308 is 309 (`evidence/behavior-enum.json`). New case 308 is a different behavior.
  2. The request gate (0x4962C0 → 0x49CFC0): old 308 and new 309 both refuse only state 12; their neighbours allow everything.
  3. The request applier (0x48EE50 → 0x495C20): old case 308 and new case 309 both call set_state.
- **States:**
  - In both state tables, 6, 11 and 12 go straight to the dispatcher exit (no update).
  - State 7 has the same power-up handler (`[block+0x1E0]` bit 1 → 8 …).
  - State 1 still calls set_state(7) after 2 s.
- **Not verifiable offline:** that the firing state (13, new handler 0x3310D0) still moves to 6 when the weapon overheats. Page 0x331000 is encrypted in every new capture (`game-26088801*.dll`, `transmog-live-text.bin`, `diverkit-port/game-live-text.bin`). If it moves elsewhere, the mod never writes ("turret in state N"). Live check L5.

No game function is called. Every read and write goes through ReadProcessMemory/WriteProcessMemory, VirtualQuery and VirtualProtectEx on data pages. No code bytes are read, so the PAGE_NOACCESS code-page rule does not arise.

## Medium rows (all fail closed; none is a write address)

| Row | Why medium | Live check |
|---|---|---|
| `heat.header` | 'LDLD' header is built from game data. The type hash bytes and their surroundings are identical in both images; the mod checks them before reading a record. | L1 |
| `heat.expected` | Record values (enabled 1, magazines 0/0, overheat 250, recover 0) are game data; the offsets are high. | L2 |
| `heat.cooling_vanilla` | 400.0f, 1 is game data. | L2 |
| `heat.ability_vanilla` | 2884 is derived from the code; the data is unreadable offline. | L2 |

## Tests (offline)

Results are in `out/TESTS.json`; port and unmodified upstream give the same results.
- **Linux GC64 LuaJIT:** test_cooldown (13 checks), test_hooks, test_turret (8 checks), test_equivalence (3200 frames), and compile_entry on the release and live-test entries all pass on both copies.
- **Wine, Windows LuaJIT, private prefix `work/wine-prefix` (~380 MB, deletable):** test_adapter plain, hostile and sdk pass on both. Its 0-KB heap-peak assertion occasionally reads 0.3 KB under Wine (seen on both copies), so it gets up to 3 attempts, all recorded.
- **Port test inputs** (build data only):
  - `tests/heat_fixture.lua` is re-laid out to the new lookup (`build.py port_fixture`): the same 29 captured slot entries re-inserted into 60 slots, header size +32 and ability 2866→2884. It is synthetic: a layout transform, not a 26088801 capture.
  - `tests/reference/laser_sentry_cooldown.lua` gets the same code constants.
  - The literals that follow (test_hooks MANAGER_RVA, the probing test's slot numbers 10/11/12/57 → 0/1/2/59, ability bytes, refusal text) are updated.
- **Not run:** `tests/game_lua.py`, which needs the game's old `lua51.dll` through Windows ctypes.

## Read-only in-game checks (for you to run)

B = game.dll base. Nothing here writes or calls the game. Run through Link's Link to Memory:

```
eval local p=assert(io.open('Z:<workspace>/native-work/megapack-port/LaserSentryCooldown/live/laser_sentry_cooldown_readonly.lua','rb'));local s=p:read('*a');p:close();local f=assert(loadstring(s,'@lsc_readonly'));setfenv(f,getfenv(1));return f()
```

`tools/mock_llm_probe.lua` runs it offline against mocked memory.

- **L0 (load)**, after installing: `LaserSentryCooldown.log` shows `Laser Sentry Cooldown v1.1.1-26088801 initialized`, then `Laser Sentry heat record changed: …` (or `Waiting for the weapon data.`). There is no `Disabled:` line.
- **L1 (heat table, ship or mission)**: `N = u64 [B+0x2CE41B8]`, `T = u64 [N+0xF14790]`.
  - `u32 [T-24]` = 0x444C444C, `[T-20]` = 1, `[T-16]` = 0x4C981CD9, `[T-12]` = size ≥ 0x4920.
  - The Laser Sentry's slot: the probe starts at slot `0x56070F36CFFFA8A8 % 60 = 0`. The u64 key `0x56070F36CFFFA8A8` is at `T+16*slot`, with the index at +8.
  - `u64 [N+0xF12CC8]` (the old offset) is something else.
- **L2 (record `R = T + 960 + 592*index`)**:
  - `u8 [R+0x50]` = 1, `u32 [R+0x54]` = 0, `[R+0x5C]` = 0, `f32 [R+0x60]` = 250, `[R+0x64]` = 0, `[R+0x80]` = 5 (idle cooling).
  - Vanilla: `f32 [R+0x8C]` = 400, `u8 [R+0x90]` = 1, `u32 [R+0x248]` = **2884** (expected). With the mod active: 5.0 / 0 / 0.
  - The page is PAGE_READONLY (0x2), MEM_COMMIT, MEM_PRIVATE.
  - **If `[R+0x248]` is not 2884 in vanilla, do not install.** The mod would refuse anyway; report the value.
- **L3 (mission, a Laser Sentry deployed)**: `HM = u64 [B+0x2CE1F08]`.
  - `u32 [HM+0x14]` is the instance count (≤ 160).
  - `[HM+0x40]` holds entity record pointers, `[HM+0x58]` the 12-byte states (+4 temperature rising while it fires, +8 overheated).
- **L4**: for the Laser Sentry's instance, the record has u64 resource `0x56070F36CFFFA8A8`, id at +8 and flags at +20 (your own: flags % 4 = 1).
- **L5 (behavior)**: `BM = u64 [B+0x2CE18F0]`. The id map at +0x40 (capacity +0x48 a power of two, empty +0x4C, multiplier +0x50) gives the index, and `[BM+0x58][index]` is the same entity record. The block `[BM+0x60] + 504*index` reads:
  - behavior **309**;
  - state 13 while firing, **6 right after an overheat** (the key check), 7 for a moment after it cools (with the mod), then 2/3;
  - request +12 = 0xFFFFFFFF except for one frame;
  - last state +16.
- **L6**: the block page is PAGE_READWRITE, MEM_COMMIT, MEM_PRIVATE.
- **Behaviour after installing:** let your Laser Sentry overheat. It must not explode. About 50 s later the log shows `Laser Sentry <id> cooled down: its turret powers up again.` and it fires again.

## Installing (not done here)

The installed option archive holds this resource and the shared stub `79e4f54aa542ec98`. Replace only `mods/cowboybingus/laser_sentry_cooldown` (`out/laser_sentry_cooldown.lua.main`) and keep the stub, e.g. with `runtime-modules/original-mods/install_option.py LaserSentryCooldown --port out`, with the game and HD2 Arsenal closed.
