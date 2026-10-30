# Sentry Aim Retention (Megapack data-v8.6) → Steam build 26088801 (offline port)

Source: `upstream-bingus/SentryAimRetention` (git `v1.1.1` 8f76f63, clean). All 30 files the Megapack lock pins for
`data-v8.6` match it byte for byte, so it is the pinned component (`components/SentryAimRetention` is identical).
Old build 25480438, new build 26088801 (game.dll `6D1D4D3B…C08F`, helldivers2.exe `0ACC07DE…EABE`). Nothing here
touched the network, the game folder, `~/.config/hd2arsenal`, `<steam-library>` (not even read), the upstream checkouts or
the running game. Nothing was installed.

**2026-10-29: setter emulation (beyond build data).** The game never runs its two turret speed setters in play, so their
code pages stay unreadable and the mod's byte check of them could never pass: the port as first built would have
raised at the first own sentry and been stopped by the loader's guard. The port now does the setters' work itself and
waits instead of raising while a native's code cannot be read yet (section "Setter emulation" below, `out/logic.diff`).
Status: built and tested offline; not installed; live acceptance (L11, then holds in play) pending.

## Deliverables

| Path | What |
|---|---|
| `MAP.json` | 50 rows (46 high, 4 medium, 0 low/unmapped; 35 feed a write or a write decision), incl. the four `emulation.*` rows. Every witness re-checked by `tools/build_map.py`; `witness_check_failures` is empty. `inventory_sites` maps all 50 inventory lines to rows. |
| `build.py` | `python3 -I -B build.py [--tests]`. Copies upstream `src/ scripts/ tests/` to `work/upstream` and `work/port`, applies 40 exact replacements (build data only; assembled once alone as `work/port-data` for the line-for-line check), then the 6 `LOGIC_PATCHES` (setter emulation, wait-for-readable binding; the port wrapper must equal the build-data wrapper with exactly these applied), assembles with upstream `scripts/module.py build_module()`, archives, compiles, smoke-runs. |
| `out/sentry_aim_retention.lua` (= `out/5b268e629ad0619d.lua`) | sha256 `a2572037…0712`. `-- HD2-Addon: mods/cowboybingus/sentry_aim_retention` + the plaintext wrapper `build_module()` assembles. |
| `out/9ba626afa44a3aa3.patch_0` | sha256 `3964e8ec…c102`, `make_archive` from BingusSharedLoader, round-tripped. One resource only: `5b268e629ad0619d` (type `a14e8dfa2cd117e2`, version-2 envelope, 119566 bytes). No shared Megapack stub. Empty `.stream` / `.gpu_resources` beside it. |
| `out/wrapper.diff` | Port wrapper vs the unmodified upstream assembly. The build-data part alone is 40 changed lines (39 replacements + the `install_loader` line). |
| `out/logic.diff` | Port wrapper vs the build-data-only wrapper: exactly the 6 `LOGIC_PATCHES`. |
| `out/build-receipt.json`, `out/TESTS.json` | Hashes, every replacement, reproduction proof, LuaJIT check, test results. |
| `live/sentry_aim_retention_readonly.lua` | Read-only live probe (L0–L11 below). `tools/mock_llm_probe.lua` runs it against mocked memory. |
| `tools/` | `lib.py`/`align.py`/`show_pair.py`/`imm_scan.py`/… (from hdh-port), `map_globals.py`, `map_fields.py`, `fcmp.py`/`save_fcmp.py` (whole-function old/new comparisons), `record_fields.py`, `strides.py`, `horizontal.py`, `behavior_enum.py` (copied from the Laser Sentry Cooldown port), `behavior_ids.py`, `behavior_runs.py`, `behavior_layout.py`, `setter_emulation.py` (setter emulation evidence), `build_map.py`. |
| `evidence/` | `globals.json`, `old-global-xrefs.json`, `field-pairs.json`, `functions.json`, `record-fields-*.txt`, `strides-*.txt`, `horizontal-setter.txt`, `setter-emulation.txt`, `live-game-26088801-page-105D000.bin` (page 0x105d000 read live in a mission, 2026-10-29), `listings/`. |

Rebuild: `cd tools && python3 -I -B map_globals.py && python3 -I -B map_fields.py 150 && python3 -I -B save_fcmp.py && python3 -I -B record_fields.py 0x1f8 > ../evidence/record-fields-behavior-504.txt && python3 -I -B record_fields.py 0xd0 > ../evidence/record-fields-runtime-208.txt && python3 -I -B horizontal.py > ../evidence/horizontal-setter.txt && python3 -I -B setter_emulation.py > ../evidence/setter-emulation.txt && python3 -I -B build_map.py`, then `cd .. && python3 -I -B build.py --tests`.

## Packaging (GC64)

- The Megapack ships this MODULES option as `-- HD2-Addon: …\nreturn assert(loadstring("<non-GC64 bytecode>", "@…"))(...)`,
  which the GC64 VM cannot load. The port ships the same declaration followed by the plaintext wrapper
  `build_module()` assembles, in the same type-2 envelope. No PORT51/compat51, no `require('cffi')` (build refuses them).
- **Reproduction, byte for byte**: the unmodified assembly compiled with the workspace's non-GC64 LuaJIT 2.1
  (`runtime-modules/vm-poc/work/runtime/linux/LuaJIT/src/luajit`, `-bsdW`) gives resource sha256
  `C66E3164…2483` = the lock's `resource_sha256`; the Megapack `discoverable_resource()` of it equals the shipped v26
  option's archive resource and its loose `5b268e629ad0619d.lua`. `build.py` asserts all three every run.
- GC64 check (`runtime-modules/build/linux/LuaJIT`, `string.dump` flags 8): `loadstring` compiles the resource; run with
  a stub loader it reaches its first Windows call (`ffi.load('kernel32')`), which fails inside its own `pcall` and
  becomes the status, revision `data-v8.6-26088801`.
- The gate the installed copy stops at ("unsupported game build", `sentry_aim_retention:2434`) is
  `verify_build` with the exe/game.dll SHA-256 pins in `scripts/archive.py`: replaced by the 26088801 hashes.

## Every changed value

| MAP row | Constant | Old | New |
|---|---|---|---|
| archive.EXE_SHA / GAME_DLL_SHA | build pins | F5FEE03D… / 2E2C3B7C… | 0ACC07DE… / 6D1D4D3B… |
| native.retention | flag setter + 24-byte signature | 0x6bf390 | **0x6c9a50** |
| native.vertical | vertical speed setter + signature | 0x11cb930 | **0x105cf00** |
| emulation.* (beyond build data) | invalid id / replication routine / field hashes | 0x3483c20 / 0xfd97e0 / same | **0x2e3f0d0 / 0xe69780 (221-byte signature) / same**; the two setters above are no longer called |
| native.horizontal | horizontal speed setter + signature | 0x11cba20 (24 bytes) | **0x105cff0 (whole predicted 232-byte body)** — medium, runtime-gated |
| native.fire_mode | fire mode setter + signature | 0x755f90 | **0x761700** (signature bytes unchanged) |
| engine.pose_getter | exe world_pose getter signature | 0x1fd220 | **0x1f30c0** |
| engine.world_id | exe world id + signature | 0x79f860 | **0x826d10** |
| engine.raycast | exe raycast + signature | 0x7f4590 | **0x87bc70** |
| game.targeting / behavior / turret | managers | 0x3326d30 / 0x3326740 / 0x3326d70 | 0x2ce1ef0 / 0x2ce18f0 / 0x2ce1f30 |
| game.target_faction | 0x3326cb8 | | 0x2ce1e78 |
| game.clock | 0x3326348 | | 0x2ce14f8 |
| game.weapon / trigger | 0x3326ce0 / 0x3326660 | | 0x2ce1ea0 / 0x2ce1810 |
| game.mode | 0x33266a0 | | 0x2ce1850 |
| data.behavior_ids | behavior ids Gatling / MG / Laser / Rocket / Flame / Mortar / EMS | 213 / 312 / 308 / 611 / 207 / 319 / 323 | **214 / 313 / 309 / 611 / 208 / 320 / 324** |
| game.scheduler / physics_world | 0x347d7e0 / 0x346bfa0 | | 0x2e38988 / 0x2e271f8 |
| exe.actor_pools / world_slots / filter_properties / units | 0x2369b00 / 0x27ba8a8 / 0x27c5e48 / 0x1a100f0 | | 0x2411200 / 0x2861d88 / 0x286d338 / 0x1ab76f8 |

Everything else (all struct offsets, strides, hashes, enum values, filter constants) is unchanged, with witnesses (MAP rows `layout.*`, `engine.raycast_filter`).

## Static verification

**Globals** (`tools/map_globals.py`, up to 64 RIP-relative sites per global, migrated by unique instruction windows):
targeting 53 exact votes, behavior 26, turret 27, faction 52, clock 25, weapon 34, trigger 48, mode 46, scheduler 3 (of
5 sites; initializer identical), physics world 45; exe pools 9/9, world slots 6/6, filter properties 60, units 42,
raycast world table 51, world-id table 17. Disagreements: one masked-window twin each for behavior and turret (rejected;
every exact window agrees). 0x2861d88 = raycast world table 0x2861d50 + 0x38, the same +0x38 field as old.

**Called natives** (all five called functions compared instruction by instruction over their whole bodies,
`evidence/listings/fcmp-*.txt`):

| Native | Old → new | Evidence |
|---|---|---|
| retention flag setter `(nil,id,2,on)` | game 0x6bf390 → 0x6c9a50 | 0 differing instructions; ORs/ANDs bit into `[[tm+0x180]+24*i+0x10]` |
| vertical speed `(entity,float)` | game 0x11cb930 → 0x105cf00 | 0 differing; stores `[[rm+0x58]+16*i+0xc]` |
| horizontal speed `(entity,float)` | game 0x11cba20 → 0x105cff0 | **page 0x105d000 encrypted in every capture**; see below |
| fire mode `(manager,id,mode)` | game 0x755f90 → 0x761700 | 4 differing (script-API vtable offsets in a nested event call); mode store `[[wm+0x60]+12*i]` identical |
| world id `(world)` | exe 0x79f860 → 0x826d10 | 0 differing |
| raycast (11 args) | exe 0x7f4590 → 0x87bc70 | 0 differing over 0xad1 bytes (23 calls); same world table / filter globals |
| world_pose getter (checked only) | exe 0x1fd220 → 0x1f30c0 | 0 differing; unique pattern; same engine-API table slot initializer |

The mod reads every signature with `memory.read` (ReadProcessMemory) once per session before binding and never calls a
native whose bytes did not match, so a non-resident (still encrypted, PAGE_NOACCESS) page makes it wait (since the
setter emulation; before: refuse), never crash.

**Horizontal setter (high since 2026-10-29; no longer called, see "Setter emulation").** In build 25480438 the horizontal setter is the vertical one 0xF0 later,
byte-identical except: RIP/call displacements −0xF0 (same targets), the stored field +0xC→+0x8 (2 bytes) and the
network hash 0x9D5D6CC7→0xCC0B45E5 (`tools/horizontal.py` asserts this on the old image). The new vertical setter is
instruction-identical to the old one, so the same transformation predicts the new horizontal body at 0x105cf00+0xF0.
Only 16 bytes of it are readable offline (they match); the rest of its page is still encrypted in
`evidence/game-26088801.dll` and in both live text dumps. The port therefore replaces this setter's 24-byte signature
with the **whole 232-byte predicted body**: the mod calls it only if all 232 bytes in the running game equal the
prediction, which proves address and semantics at that moment. If the page is not yet decrypted when the first own
sentry is seen, `bind_natives` raises "Unsupported native sentry setter"; the loader's guard then counts errors and
stops the mod after 8 in a burst — a clean refusal, but it would disable the option for that session (L2/L9 show this).
That is what the live checks then showed would happen every session (next section), so the port no longer calls
this setter. **Live 2026-10-29** (mission): page 0x105d000 became readable and was dumped
(`evidence/live-game-26088801-page-105D000.bin`, sha256 `adaee096…e479`); the disk's 16 bytes at 0x105cff0 plus that
page are the predicted 232-byte body byte for byte (store +8, hash 0xCC0B45E5, manager 0x2CE1F30, call 0xE69780).
Page 0x105c000 (the vertical setter, and this setter's first 16 bytes) was still unreadable at the same time.

## Setter emulation (beyond build data; build.py `LOGIC_PATCHES`, `out/logic.diff`)

**Why.** In both builds the direct setters' only callers are a family of turret event handlers (old 0x10cfdb0… five
482-byte siblings + 0x10d1b40: event 0 zeroes both speeds, event 300 restores them from constants; in 26088801 one
sibling is visible at 0xf60eaf, the others sit on encrypted pages). Normal sentry play never raises those events: on
2026-10-25 with a Laser, a Flamethrower and a Gatling sentry firing, both setter pages were unreadable (L2/L9), and on
2026-10-29 page 0x105c000 still was. Build 26088801 maps such pages only once the game runs code on them, so the
vertical signature check, and the horizontal full-body check, could not pass in a session where no sentry raised
those events: `bind_natives` raised "Unsupported native sentry setter" at the first own sentry, and the loader's guard
would stop the mod after 8 errors. Calling a function whose page cannot be read is never done (it cannot be checked).

**What the port does instead** (`windows_api.lua` `set_speed`, used by `native.horizontal` / `native.vertical`): the
setters' own work, step for step (`evidence/setter-emulation.txt`): the entity id at +8, nothing for the invalid id
(u32 at game+0x2E3F0D0, live 0); the turret registry [game+0x2CE1F30]'s id map (+0x28 slots of {u32 key, u32 index},
+0x30 capacity, +0x34 empty key, +0x38 multiplier; start (id×mul) & (cap−1), linear probe; live: 512 / 0 / 2); index
−1 or absent = nothing; nothing unless the registry's entity (+0x40 pointers) has +0x14 bit 0 (owned by this machine);
the speed into control record +0x58 + 16·index (+8 horizontal, +0xC vertical) through `api.write` (VirtualQuery:
committed private read-write, then WriteProcessMemory) and read back; only then the routine the setters end with,
game+0xE69780(entity +0x10 network id, field hash, field address), hash 0xCC0B45E5 horizontal / 0x9D5D6CC7 vertical.
Stricter than the setters: the probe is bounded at 128 (as the mod's own map lookup), the index must be below the
registry count (+0x14), the capacity a power of two ≤ 8192, and the registry's entity must be the entity the row
located (`Component identity mismatch` otherwise).

**Evidence** (MAP rows `emulation.replicate`, `emulation.sentinel`, `emulation.registry`, `emulation.hashes`, all
high; `tools/setter_emulation.py` asserts every item on the images):
- the direct vertical setter 0x105cf00 (plaintext page), the direct horizontal one (live page), and the readable
  handle-taking twins of both (new 0x4d5870 / 0x4d5960, old 0x4cea40 / 0x4ceb30): each loads the invalid id (new
  0x2E3F0D0, old 0x3483C20) and the turret manager (new 0x2CE1F30, old 0x3326D70), walks the map as above, tests
  +0x14 bit 0, stores at +0xC / +8 with hash 0x9D5D6CC7 / 0xCC0B45E5 and calls the replication routine with +0x10;
- the replicated-field registration (old 0x6e06f0 / new 0x6eb097) lists 0x9611C029, 0xCC0B45E5, 0x9D5D6CC7 in that
  order in both builds;
- the replication routine: old 0xfd97e0 / new 0xe69780, 58 = 58 instructions identical apart from displacements, 221
  bytes through its ret, no base relocation inside (so live bytes = image bytes), 1183 call sites (old 1272). Live
  2026-10-29: readable in a mission and its 221 bytes equal the image. The mod checks all 221 bytes with
  ReadProcessMemory in `bind_natives` (it replaced the two setter rows of `signatures`) and calls it only after that.

**Waiting instead of raising.** `bind_natives` returns nil while any native's code cannot be read (a read that
fails); bytes that read differently still raise. `M.apply` then returns `waiting_for_natives` (no hold, fire pause or
search request: the sentries keep the game's own behavior) and checks again after 1 s. Once bound, the natives stay
bound for the session, as upstream.

**Not changed:** every other native (retention flag, fire mode, pose, world id, raycast), every snapshot read, every
decision, every other write. The direct setters are not called at all (the build refuses a source that still casts
or lists them).

**Layouts** (taint-paired field displacements over 630 aligned functions that load the globals; record-field pairs in
every function indexing by the stride):
- targeting +0x134/+0x140/+0x144 header, map +0x150..+0x160, entities +0x168, runtime +0x178 (stride 0xd0: imul pairs
  44/44), network +0x180 — all unchanged;
- runtime +8 raw / +0x14 computed aim: the targeting update (old 0x6bbdc0 → new 0x6c6480, 2999/2999 aligned, ratio
  1.000) reads and writes `[r14+r13+8]`, `[+0x10]`, `[+0x14]`, `[+0x1c]` identically;
- behavior +0x20 header, map +0x40, entities +0x58, records +0x60 stride 504 (50 new strides all 504; 44 aligned
  functions, every tracked record access pairs with the same displacement); behavior id initialised at record +0 from
  the settings lookup (0x842200 → 0x84f100, identical); deadline +0x98 compared with `[[clock]+0x18]` and set to
  now+random by the native target-search nodes (0x3b6cc0 → 0x3bd9b6 and five siblings);
- turret +8 header, map +0x28, entities +0x40, control +0x58 stride 16 (+8/+0xc);
- weapon map +0x30, entities +0x48, records +0x58 stride 0x3f0 (+0x78, +0xd8, +0xdc), mode +0x60 stride 12;
- trigger map +0x28, bytes +0x58; faction map +0x12050, slots +0x12068 (+8 id, +0xc unit); clock `[root]+0x18`;
  entity +8 id, +0x14 flags; mode record +8 / +0x40; scheduler (24 jobs × 12 bytes at +0x40008; initializer identical);
- exe: actor resolver (0x7951b0 → 0x81c4e0) and body-index lookup (0x7995f0 → 0x8209b0) identical (pool header
  +0x1c/+0x24/+0x28/+0x34, record +0x14), body accessor `and 0xffffff; *160; add [world+0x18]` identical, filter names
  `[props+0x100]`, count `+0xf8`, `body+0x6c & 0x7f` (exact window), unit table +0x88/+0x98/+0xa0 and 22/8-bit handle
  split identical, scene-graph count at object+0x70 read by an identical unit-API helper.

## Every memory write and its evidence

| # | Write | How | Evidence | Confidence |
|---|---|---|---|---|
| W1 | retention bit (network record +16, bit 1), set and cleared | native 0x6c9a50 | whole body identical (stride 24, +0x10, authority test, sync hash) | high |
| W2 | turret horizontal speed (control +8) → 0 and back | WriteProcessMemory (private RW checked, read back), then replication call game+0xE69780(net id, 0xCC0B45E5, field) | the setter's own work (setter emulation): direct horizontal body (live page) + readable twin 0x4d5960; replication routine 221 bytes checked before binding | high |
| W3 | turret vertical speed (control +0xC) → 0 and back | WriteProcessMemory (private RW checked, read back), then replication call game+0xE69780(net id, 0x9D5D6CC7, field) | direct vertical body 0x105cf00 + twin 0x4d5870; same routine | high |
| W4 | raw aim (runtime record +8, 12 bytes) | WriteProcessMemory, private RW checked | stride 0xd0 ×44; targeting update identical at +8/+0x10 | high |
| W5 | computed aim (runtime record +20, 12 bytes) | WriteProcessMemory | targeting update identical at +0x14/+0x1c (movsd/mov) | high |
| W6 | weapon fire mode → 0 and back | native 0x761700 | whole body identical except an unrelated nested vtable call | high |
| W7 | selection deadline (behavior record +152, u64) | WriteProcessMemory | six native nodes use +0x98 as the clock deadline, unchanged; stride 504 and record fields unchanged | high |

Each write is still guarded by the mod's own checks (entity identity guards, authority byte, VirtualQuery private RW,
read-back verification, journaled restore). Decision inputs that are not write addresses but steer W2–W7, all fail
closed: `data.profiles` (entity type hashes: an unknown type is simply not a sentry), `data.source_flags` (bit 5:
other values only stop holds/requests from triggering), `engine.destructible_filter` and `layout.actor_body` (body +144/+148 have no
code witness; a moved field makes the filter unknown, so a fence counts as terrain and fire pauses more — never a wrong
write). These four are the other medium rows.

## Behavior ids (re-checked after the Laser Sentry Cooldown port found 308 -> 309)

Build 26088801 inserted behaviors: the behavior update dispatcher (old 0x472f60, table 0x4795c4 / new 0x479ca0, table
0x4802c4, 693 cases, case = id − 1) keeps every behavior but shifts most ids. Three independent witnesses:
1. **Case shapes** (`tools/behavior_enum.py`, the LSC tool): 207→208 and 308→309 unique; Gatling and MG share one shape
   that exists exactly twice in each build (old 213/312, new 214/313); all unique anchors from id 135 to 457 shift +1,
   588–693 shift 0.
2. **Code layout** (`tools/behavior_layout.py`, `evidence/behavior-layout.json`): each case's and state handler's direct
   call must land on the old callee plus the local code shift measured from uniquely migrated neighbours. Exactly one
   candidate passes per id: 213→214 (12/12 calls; twin 313 fails), 312→313 (12/12; twin 214 fails), 308→309 (13/13),
   319→320, 323→324, 611→611 (the one behavior-specific callee each, at the exact local shift; the alternative fails);
   207→208 (all 10 callees move by one uniform +0x6bd0, unique shape match).
3. **State switches** (`evidence/behavior-states.json`): the case switches on the node at the behavior record
   (`mov rdx,[rcx+8]; mov eax,[rdx]; dec eax; cmp eax,0xb`); 213→214, 312→313, 207→208 keep 12 states and 308→309 13,
   handlers identical in shape and order, state 12 handler identical, so **node 12 (firing) is unchanged**.

All seven ids are now high (MAP `data.behavior_ids`, `data.firing_node`). Still medium: the entity type hashes
(`data.profiles`) and source-flag bit 5 (`data.source_flags`), both fail closed. The port's test fixtures use the new
Gatling id (synthetic sentries, `tests/reference/aim_data.lua`, and the captured Gatling's behavior word 213→214), recorded in
out/TESTS.json; test results are unchanged.

## Tests (out/TESTS.json; port and unmodified upstream give identical results)

- Linux GC64 LuaJIT: `test_aim` (182-sample replay, 8 holds), `test_firing`, `test_current_game` PASS.
- Windows LuaJIT under Wine (private prefix `work/wine-prefix`, ~380 MB, deletable): `test_loader`, `test_snapshot`,
  `test_idle_gate`, `test_module` PASS.
- `test_windows_api` fails on **both** (environment): Wine's bcrypt faults in BCryptDestroyHash (same as hdh-port); the
  hash-cache prelude cannot satisfy its "hash read once" counter. A derived copy with only those two counter checks
  relaxed PASSES on both (upstream 9 PASS lines: actor filter, pose binding, terrain path, native query arguments;
  the port 10: the same 9 plus the setter emulation test).
- Setter emulation (2026-10-29), port tests only (build.py `TEST_LOGIC_PATCHES`):
  - `test_windows_api` gains a block that runs `set_speed` for real under Wine: the replication routine is a 33-byte
    executable stub that records its arguments, the registry/entity/control records are VirtualAlloc'd memory. Both
    axes write and replicate with the right network id, hash and field address; nothing is written or replicated
    for an entity this machine does not own, the invalid id, an id not in the map, a slot holding index −1, or a
    read-only control record; another entity with the same id is refused. The "binds add no C types" check still
    passes with the new typedef.
  - `test_snapshot` line 85 (upstream: unreadable signatures make apply raise) becomes: unreadable code →
    `waiting_for_natives`, no binding, no read again before 1 s, a read again at 1 s; readable but different code →
    "Unsupported native sentry setter".
  - Results 2026-10-29: port and upstream identical (8 suites + the derived one pass on both; `test_windows_api`
    fails on both for the bcrypt reason above).
- The port's copy of the tests gets the same old→new global map applied to its fixtures (synthetic memory at
  game/exe+RVA, `tests/reference/aim_data.lua`, and the global-slot blocks of the build-25327279 capture), recorded in
  TESTS.json; the capture test then decodes the real captured sentry through the port's code with the new globals.
- Not run: `tests/test_package.py` (needs the release zip).

## Read-only in-game checks

Run `live/sentry_aim_retention_readonly.lua` through Link's Link to Memory:

```
eval local p=assert(io.open('Z:<workspace>/native-work/megapack-port/SentryAimRetention/live/sentry_aim_retention_readonly.lua','rb'));local s=p:read('*a');p:close();local f=assert(loadstring(s,'@sar_readonly'));setfenv(f,getfenv(1));return f()
```

Once on the ship, once in a mission with your own Gatling or MG sentry (ideally while it fires, and right after its
target dies). G = game.dll base, E = exe base.

- **L0**: log first line `data-v8.6-26088801`, second `waiting_for_sentries` (not "unsupported game build").
- **L1**: `[G+0x2CE1EF0]`, `[G+0x2CE18F0]`, `[G+0x2CE1F30]`, `[G+0x2CE1EA0]`, `[G+0x2CE1810]`, `[G+0x2CE14F8]`,
  `[G+0x2CE1850]` non-null in a mission (managers); scheduler `[G+0x2E38988]` and world `[G+0x2E271F8]` non-null in a mission.
- **L2**: retention / replication routine (221 bytes) / fire-mode / pose / world-id / raycast signatures print MATCH (or
  `unreadable` before the game ran that code — then the mod waits and checks again every second; it never calls it). The
  vertical setter line is information only (not called; `unreadable` expected).
- **L9** (information; not called): `G+0x105CFF0`, 232 bytes print "MATCHES the predicted 232-byte body" once readable.
- **L11** (setter emulation): invalid id `[G+0x2E3F0D0]` (live 0); turret map cap / empty / mul (live 512 / 0 / 2); per
  own sentry: the setters' map walk finds `index` = the turret row (`ok`), `record` = the entity (`ok`), owned bit 1,
  a network id, and both write targets (+8 / +12, current speeds e.g. 80 / 50) protect 0x4, state 0x1000, type 0x20000.
- **L5**: mode record `+8` ≠ 0 and `+0x40` in 1..7 in a mission; outside, not.
- **L6**: targeting `cap ≤ 8192`, `active ≤ total ≤ cap`; your sentry listed with the right type, `flags & 3 == 1`,
  `tm map … ok`; behavior id **214** (Gatling) / **313** (MG) / 309 / 611 / 208 / 320 / 324 (row data.behavior_ids; the old 213/312 would mean the migration is wrong);
  node 12 while firing; target ≠ 0 and source bit 0 while tracking; deadline within ~1 s of the clock while searching;
  turret enabled 1, speeds e.g. 80/50; runtime raw/computed = a world position near the target; weapon fire nodes 1..24,
  mode ≤ 8; every "entity ptr ok" true.
- **L10**: raw aim, deadline, control and network addresses: protect 0x4, state 0x1000, type 0x20000.
- **L7**: units count > index, generation byte = handle>>22, `[object+8]` = unit, nodes +0x70 small, vtable+0xE8 code
  `488d4160c3`, matrices pointer non-null.
- **L8**: filter property count ≤ 128 with `destructible@k` (0x04a8fbf9) present; three bodies with actor/unit print
  CONSISTENT (pool entry key = actor, record unit = body+148, record body index = body) — this verifies body +144/+148.
- **L6b**: scheduler word +0 is 0 most of the time; jobs consumed 24/24 between physics steps.
- Behaviour after installing: holds/fire pauses in SentryAimRetention.log, no "Unsupported native sentry setter"; with
  diagnostics on, the status reads `waiting_for_natives` only until the natives check out (normally never in a
  mission, since all of them were readable there).

## Installing (not done here)

The installed Megapack option archive holds two resources (`79e4f54aa542ec98` shared stub + `5b268e629ad0619d`). The port
replaces `5b268e629ad0619d` only and must keep the stub (`runtime-modules/original-mods/install_option.py SentryAimRetention
--port out/…`, with the game and HD2 Arsenal closed). Do it once L2 matches (replication routine included) and L11 shows
the expected lookup; L9 no longer gates it.
