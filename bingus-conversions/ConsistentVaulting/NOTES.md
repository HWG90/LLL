# Consistent Vaulting data-v8.9.1 (Megapack option) → Steam build 26088801 (offline port)

Source: `upstream-bingus/VanillaPlusMegapack/components/ConsistentVaulting`, the pinned copy the pack builds from.
`upstream-bingus/ConsistentVaulting` at tag `v8.9.1` holds the same bytes. Both match every `source_sha256` of the
lock (revision `data-v8.9.1`).

The port changes build data only. Old build is 25480438. New build is 26088801: game.dll `6D1D4D3B…C08F`,
helldivers2.exe `0ACC07DE…EABE`, both re-hashed read-only from the install.

Nothing here touched:
- the network;
- the game folder (read only);
- `~/.config/hd2arsenal` or anything under `<steam-library>` (read only);
- `upstream-bingus`;
- the running game.

Nothing was installed.

## Deliverables

| Path | What |
|---|---|
| `MAP.json` | 59 rows: 56 high, 3 medium, 0 low, 0 unmapped. Each row has file/line (plus every site), old, new, method, inline re-asserted witnesses, confidence, `feeds_write`, role and its live check. `witness_check_failures` is empty. |
| `build.py` | `python3 -I -B build.py [--tests]` (details below). |
| `out/consistent_vaulting.lua` | The option's entry, plaintext (sha256 `0426f18f…dbb3`). |
| `out/9ba626afa44a3aa3.patch_0` | Holds only `mods/cowboybingus/consistent_vaulting` (`38ec9f6555859108`, type `a14e8dfa2cd117e2`, 153765 bytes, version-2 envelope). Built with `BingusSharedLoader/scripts/archive.py make_archive` and round-tripped. Empty `.stream` and `.gpu_resources` companions sit beside it. The shared stub `vanilla_plus_megapack` is not included. |
| `out/wrapper.diff` | Port wrapper vs the unmodified wrapper: 63 lines. |
| `out/build-receipt.json`, `out/TESTS.json` | Hashes, every edit with its MAP rows, reproduction proof, LuaJIT check, test results. |
| `tools/` | Read-only analysis. `lib.py`/`align.py`/`show_pair.py` come from hdh-port. The rest: `map_globals.py`, `map_fields.py`, `field_map.py`, `range_scan.py`, `func_diffs.py`, `fmatch.py`, `pairdiff.py`, `small_match.py`, and `build_map.py`, which writes MAP.json and re-asserts every witness. |
| `evidence/` | `globals.json`, `old-global-xrefs.json`, `field-pairs.json` (721 function pairs), `avatar-block-scan.jsonl` (every per-avatar block field). |
| `live/consistent_vaulting_readonly.lua` | Read-only live probe for L0–L10 below. |

`build.py [--tests]` does the following:
1. Copies the component plus the pack's `scripts/{build,archive,package}.py` and the lock into `work/upstream` and `work/port`.
2. Applies 63 exact replacements (64 edits) to `work/port`. Each must match its stated count and name its MAP rows.
3. Refuses if a row feeding a write or call is not high, or if any row is low.

Rebuild:

```
cd tools
python3 -I -B map_globals.py
python3 -I -B map_fields.py 120
python3 -I -B range_scan.py game 0x53e100 0x53f400 4 > ../evidence/avatar-block-scan.jsonl
python3 -I -B build_map.py
cd ..
python3 -I -B build.py --tests
```

## Packaging (GC64)

- **What the pack shipped.** The option resource was the discoverable entry `-- HD2-Addon: …` + `return assert(loadstring("<non-GC64 bytecode>"))(...)`. The bytecode is `luajit -bsdW` of the `mod.wrapper.lua` that the component's `scripts/module.py build_module()` assembles. The GC64 VM cannot load that bytecode.
- **Proof of the unmodified assembly.** `build.py` runs the pack's own `build_component()` on the unmodified copy, with the real compile in the vendored non-GC64 LuaJIT 2.1 ROLLING (`runtime-modules/vm-poc/.../luajit`):
  - the payload equals the lock `resource_sha256` `F7086B62…40FF`;
  - `discoverable_resource()` of it equals byte for byte the shipped v26 resource in `Vanilla Plus Megapack - v26/options/ConsistentVaulting/9ba626afa44a3aa3.patch_0`.
- **The port resource.** The port runs the same unmodified `build_module()` with its one subprocess captured. It ships the plaintext wrapper through the loader's own plaintext-entry rule (`build_addon.entry_source`: declaration line + source) in the same `<II len, 2>` envelope.
  - The wrapper never uses `...`, so dropping the `loadstring(...)(...)` shell changes nothing.
  - The installed PUC copy already proved the loader starts plaintext for this module: its error read `consistent_vaulting:3173`.
- **What else changed.** Besides build data, only:
  - the revision string `data-v8.9.1-26088801`, which appears in the log status line;
  - the two SHA-256 pins in the pack `scripts/archive.py`.
  - The wrapper is otherwise the upstream source: real `ffi`/`bit`/`jit`, with no PORT51/compat51/cffi. The build checks this.
- **LuaJIT 2.1 GC64 check** (`string.dump` flags 8):
  - `loadstring` compiles the entry.
  - Run, it executes the whole wrapper and stops at the loader check, the same as on any host without Bingus Shared Loader: `Bingus Shared Loader loader-v4 or newer / API 1 or newer is required`.

## What changed (MAP.json "changed")

| Rows | Old → new |
|---|---|
| pins | exe `F5FEE03D…5F06` → `0ACC07DE…EABE`; game `2E2C3B7C…F51E` → `6D1D4D3B…C08F` |
| game globals | mode 0x33266A0→**0x2CE1850**; players 0x3326468→0x2CE1618; entities 0x346BF98→0x2CE41B8; avatars 0x3326D20→0x2CE1EE0; movement 0x3326558→**0x2CE1708**; camera 0x346D560→**0x2E287D0**; physics world 0x346BFA0→**0x2E271F8**; native-table owners 0x3326338/0x3326388/0x3326328→**0x2CE1500/0x2CE1548/0x2CE14E8** |
| entities fields | unit map 0xF22EC8→0xF24990; records 0xF32F18→0xF349E0; AvatarComponent table 0xF12BB8→**0xF14680** |
| avatar manager | per-avatar stride **0x1238→0x1240**; flags 0x53E880→**0x53E888**; override map 0x547C70→**0x547CB0**, count 0x547D20→**0x547D60**, records 0x547D24→**0x547D64** |
| query record (128 B) | ignored unit +0x70→**+0x74**; capacity u16 +0x74→**+0x78**; result count u16 +0x76→**+0x7A**; type bytes +0x7A/7B/7C→**+0x7C/7D/7E**. The new build inserts a u32 total at +0x70. In Lua, `record:byte(0x7b..0x7d)` → `(0x7d..0x7f)` and the descriptor `tail[12]` source `copy+112` → `copy+116`. |
| exe data | handle pools 0x27C3298→**0x286A768**; controller vtable 0x16A16D8→**0x17430A0**; native tables 0x27CD910/0x27CDC30/0x27CDB40→0x2874ED0/0x2875170/0x2875080 (medium, see below) |
| exe functions | valid 0x7972F0→0x81E620; flags 0x7993D0→0x820700; motion 0x799540→0x820870; mover 0x7CE220→0x855900; position 0x7CF050→0x856730; dimensions 0x7CFE10→0x8574F0; world id 0x79F860→0x826D10; world slot 0x68 0x77DEC0→0x805160 (only compared); query 0x7F9070→0x880750 |
| game functions | classify 0xA9D560→0xAB9040; drive 0xA9A0C0→0xAB5BA0; detect 0xA9C3E0→0xAB7EC0; approach 0xA9DD90→0xAB9870; override 0x83C420→0x8492A0; basis 0x173F150→0x15B3180; rotation 0x173A750→0x15AE780 |

These are unchanged, each with witnesses:
- mode +8/+0x40;
- player manager +0x84/+0x88/+0xE8/+0x3A8;
- avatar registry +0xF8/+0x6C/+0x110 and scheduler +0x28;
- input base +0x150, stride 0xA7AEC, slots +0x1B68, climb action 14, motion direction +0x150+0xA7AC8;
- controller block 0x53E1B8 (0x2B0 bytes: +4 phase, +8 ids, +0x30 hits ×44, +0x1E8.. geometry, +0x215/+0x216, +0x2AC id);
- direction state 0x53E134 (+8 speed cap, +0x28 id);
- settings record fields +12/+0x98/+0xAC/+0x104/+0x108/+0x10C and size 852;
- movement +0x48A0/+0x48C8 (132)/+0x48D0 (164), mover +76/+88;
- camera +0x1C;
- scheduler: count +0x40000, 8×12-byte jobs, record +0/+8/+0x10/+0x50/+0x5C/+0x68/+0x6C, filter 0x05A5271A, type 2/1/5;
- controller object +80/+96/+100;
- table slots;
- the four checked entry byte strings;
- avatar resource hash 0x4D1C334D294DFA97.

The avatar block scan explains the shifts. Eight bytes were inserted between 0x53E83C and 0x53E848. Every scanned field at or below 0x53E83C kept its offset and every one from 0x53E848 moved +8. That leaves the controller and direction state in place and moves the flags.

## Verified statically (how)

**Globals.** Up to 64 RIP-relative sites per global were migrated by unique windows (`evidence/globals.json`): 42–55 agreeing, 0 disagreeing, except movement with 1 of 47 disagreeing. Of those, 27–53 are exact unmasked windows. Players, entities and avatars match the coordinator's live-verified values.

**Fields.** 721 old functions that load these globals were aligned with their counterparts. Operands derived from the globals were paired, giving `field-pairs.json`. Per-value operand votes come from `field_map.py`, which aligns the function around every old site:

| Change | Agreeing functions |
|---|---|
| stride 0x1238→0x1240 | 25/25 |
| flags 0x53E880→0x53E888 | 24 |
| override map | 5 |
| override count | 4 |
| override records | 6 |
| AvatarComponent table 0xF14680 | 2, incl. the override routine itself |

**Functions.** For each called game function, the old entry and the new entry were checked these ways:
- exact 160-byte start window, or inner windows for the override routine;
- aligned instruction for instruction:

  | Function | Aligned |
  |---|---|
  | drive | 801/801 |
  | detect | 881/881 |
  | classify | 196/197 |
  | approach | 357/358 |
  | override | 161/161 |
  | basis | 172/172 |
  | rotation | 118/118 |

- unwind codes equal, shifted by the new build's entry padding;
- the 16/12 entry bytes the mod checks are equal.

The game's own callers confirm the targets:
- the detector (0xA9C3E0/0xAB7EC0) calls classify, approach, basis and rotation at the new addresses;
- the vault query producer (0xA9BE10/0xAB78F0, aligned 288/288 with no operand change) calls basis, rotation and the scheduler submit at the new addresses.

The only operand differences in the called functions are offsets these rows already map: stride/flags in detect, override map/records and entities fields in the override routine, the game-state field in drive, and an internal world-object field in classify/detect.

New pdata entries begin 1–8 bytes before the real entry because of junk padding. The real entry is the one callers use, for example basis 142 call sites.

**Exe functions.** Each old function matches exactly one new position: masked bytes over its whole length, with every call target mapping to the counterpart of the old callee. The old runtime tables hold exactly the old functions in the slots the mod checks. The game's calls through the three tables use the same slots in both builds. The actor table gained a slot after 0xA8, which the mod does not use.

**Query record.** The new layout is read directly from two routines:
- the scheduler submit routine (0x175BB40/0x15CFCC0), which writes it;
- the worker (0x175B830/0x15CF930), which hands each record to `[world table+0x80]`.

The descriptor the mod builds for the world query keeps its shape: options +8, matrix +0x10, size +0x50, target +0x5C, tail[12] = ignored unit, tail[13] = +0x6C. Only the unit's record offset moved.

**Exe data.**
- Handle pools: 6/6 exact windows. The mover lookup is byte-identical except two displacements.
- Controller vtable: 4/4 exact windows, with slot-by-slot method pairs.
- Controller setup (exact window 0xD699E2/0xDC2312) stores +0x50 up, +0x60 = cos(slope angle) and +0x64 = cos(contact angle).

### Medium (guards only, `feeds_write: false`)

The three native-table RVAs 0x2874ED0 / 0x2875170 / 0x2875080 are runtime `.bss` tables. They are derived from the pointers in the new game capture minus the preferred exe base 0x140000000. That base is not recorded for that session. Supporting evidence: the same three tables sit in the same order at the end of `.data`, and the world→mover gap is 0xF0 in both builds.

They only feed the mod's identity guard `distance(table, exe) == RVA`. A wrong value makes the mod refuse with `Unsupported native table` before any call. Every function it calls is cast from the separately mapped high-confidence RVAs, and each one's table slot is compared first. L10 settles the RVAs.

### Blocked

None.

## Every memory write (unchanged behaviour; addresses now from the new map)

All writes go through Bingus Shared Runtime `write`/`write_batch` (`bingus_write.lua`). That code checks MEM_COMMIT, PAGE_READWRITE and MEM_PRIVATE right before writing and reads each value back. Writes are restored on release, error, pause, stop and shutdown.

| # | Target (new build) | Bytes | When | Evidence |
|---|---|---|---|---|
| W1 | `avatars + 0x53E1B8 + ai*0x1240 + 0x30 + 44*slot + 28`: unit/actor pair of other query hits | 8 each, ≤9 | stage 2 plan (held), stage 3 retry | avatars global, stride, block layout, controller layout (driver/detector identical), hit layout (exe query byte-identical) |
| W2 | same controller, the selected 44-byte hit | 44 | stage 3 retry, restored after the driver call | as W1 |
| W3 | controller +4 phase 3→2 | 4 | stage 3 retry, restored | as W1; phase values come from the identical driver |
| W4 | `avatars + 0x547D64 + oi*852 + 152/172` (slide entry 65°, exit 60°) and `+260` (ground climb height 2.5, ledge mode) | 4 each | steep/ledge assist lease | override map/count/records (5/4/6 functions), settings fields read by the identical detector/driver, record size 852 |
| W5 | character controller object +96 (slope cosine → cos 65°) | 4 | steep assist lease | handle pools, pool decode, vtable guard 0x17430A0, setup code +0x60 = cos(slope); runtime guards: up = (0,0,1), +100 = cos 70°, +96 = cos 50° before arming |
| W6 | `avatars + 0x53E134 + ai*0x1240 + 8` speed cap → walking speed | 4 | after native climbing starts (steep lease) | block layout; the game's own cap setter (0x11A3B90 → 0x1034330) stores `[ai*0x1240 + 0x53E13C]` |

The engine also allocates its own state when the AvatarComponent modifier routine (override, below) creates the avatar's local settings override. The mod writes nothing for this.

## Every native call

| Call | New address | Arguments | Witnesses |
|---|---|---|---|
| actor valid / flags / motion | exe 0x81E620 / 0x820700 / 0x820870 | actor id; private float outputs | small_match + table slot compared first |
| mover / position / dimensions | exe 0x855900 / 0x856730 / 0x8574F0 | unit, mover name; private outputs | same |
| world id / shape query | exe 0x826D10 / 0x880750 | world pointer (game 0x2E271F8); private descriptor and 48-byte output | same; worker passes the same arguments |
| basis / rotation | game 0x15B3180 / 0x15AE780 | private aligned buffers | function pair + detector/producer call sites |
| classify (exit) | game 0xAB9040 | nil, avatar entity, private point/quaternion | function pair, entry bytes checked at bind |
| detect | game 0xAB7EC0 | private 0x2B0 controller copy, 0 | function pair (881/881) |
| approach (five-slice) | game 0xAB9870 | nil, private 52-byte args, private outputs | function pair, entry bytes checked at bind |
| override | game 0x8492A0 | avatar manager, entity record, empty modifier | function pair (161/161), entry bytes checked right before each call |
| drive | game 0xAB5BA0 | the live local controller, dt 0 | function pair (801/801), entry bytes checked at bind |

The entry-byte checks read code through `api.read`, which is ReadProcessMemory. They never use a direct ffi deref.

A game.dll page the game has not executed yet can be unreadable. In that case the bind check fails as "Native … changed", nothing is called, and the snapshot reports `waiting_for_game_data` and retries later. Detect, basis, rotation and the exe natives are called without a byte check, as upstream does; L9 shows their bytes live.

## Offline tests (`out/TESTS.json`)

The upstream suite ran on the unmodified copy and on the port. The port's test fixtures had the same map applied, test-only: 34 + 43 replacements in `test_vault.lua`/`test_slope.lua`. The port and upstream give identical results in every environment:

| Environment | Result (same for upstream and port) |
|---|---|
| Linux, vendored non-GC64 LuaJIT | `test_geometry`, `test_raised_approach`, `test_slope` (4 PASS) and `test_loader` pass. `test_vault` passes its fixture part, then cannot load `kernel32` for its real-memory budget part. |
| Linux, GC64 LuaJIT | Same, except `test_slope` segfaults (its fixtures use raw low addresses). |
| Wine, Windows LuaJIT, private prefix `work/wine-prefix` | `test_vault` passes fully (2 PASS); `test_geometry`, `test_raised_approach` and `test_loader` pass; `test_slope` passes its first part and then page-faults on a fixture write. |

Every failure above also fails on the unmodified upstream, so it is environmental. Across environments every test passes on both copies: `test_vault` under Wine, `test_slope` on non-GC64 Linux.

`tests/test_package.py` was not run, since no release zip is built.

## Live checks to run (read-only; `live/consistent_vaulting_readonly.lua`)

Run the probe in a mission with your Helldiver standing still. Then run it again while you hold the climb/vault input facing a waist-high wall.

| Check | Address / size | Expect |
|---|---|---|
| L0 | `ConsistentVaulting` table | revision `data-v8.9.1-26088801`, status e.g. `waiting_for_mission` / `waiting_for_manual_vault` |
| L1 | `[game+0x2CE1850]` +8, +0x40 (u32); `[game+0x2E287D0]` +0x1C (3 f32); `[game+0x2E271F8]` | in a mission +8 ≠ 0 and +0x40 in 1..7; camera forward length 1.0, changes as you turn; world non-null |
| L2 | `[game+0x2CE1618]` +0x84/+0x88, +0xE8 → +0x14 bit 0, +0x3A8 | counts 1..4; owned bit 1; unit ref ≠ 0x7FFF |
| L3 | `[game+0x2CE41B8]`: hashmap +0xF24990 by the unit ref → record +0xF349E0 + 24·i | hash `0x4D1C334D294DFA97`, flags bit 0 = 1 |
| L4 | `[game+0x2CE1EE0]`: hashmap +0xF8 by id → ai; controller `+0x53E1B8+ai*0x1240`; direction `+0x53E134+…`; flags `+0x53E888+…`; input `+0x150+ai*0xA7AEC+0x1B68+14*32` | controller +0x2AC = id (the old-stride read differs once ai > 0); direction +0x28 = id; input byte 0 when released and non-zero while held; phase 2/3 right after a vault attempt; flags word3 bit 0x200 while climbing |
| L5 | override map +0x547CB0 / count +0x547D60 / record +0x547D64; else `[entities+0xF14680]` + 32 | count ≤ 8; fields 45 / 40 / 1.95 (+0x98/+0xAC/+0x104), walk speed > 0 |
| L6 | `[avatars+0x28]` scheduler: +0x40000 count, jobs; records `(q−1)·128` for the controller's ten ids | output == the controller hit slot, filter 0x5A5271A, unit at **+0x74** == the avatar unit, capacity +0x78 = 1, count +0x7A ∈ {0,1}, type +0x7C..+0x7E = 2 1 5 |
| L7 | `[game+0x2CE1708]` hashmap +0x48A0 → move (+0x48C8, 132 B) / mover (+0x48D0, 164 B) | mover name +76 and handle +88 non-zero |
| L8 | `[exe+0x286A768 + (handle>>30)·0x810]` pool → record → definition/object | handle check true, record unit == avatar unit, def name == mover name, vtable − exe = 0x17430A0, up (0,0,1), +96 = 0.6428, +100 = 0.3420, def angles 0.8727/1.2217; object region RW/commit/private |
| L9 | entry bytes at game+0xAB9040 (12), 0xAB5BA0/0xAB9870/0x8492A0 (16), 0xAB7EC0/0x15B3180/0x15AE780 (8) | `ok` on each; an `unreadable` line before you have climbed once is expected and settles the bind-time behaviour above. Controller region RW/commit/private |
| L10 | `[game+0x2CE1500/0x2CE1548/0x2CE14E8]` − exe and their slots | 0x2874ED0 / 0x2875170 / 0x2875080 (the three medium rows); slots 0x81E620/0x820700/0x820870, 0x855900/0x856730/0x8574F0, 0x826D10/0x805160/0x880750 |

After L0–L10 agree, the gameplay check is the original mod's own:
- a manual vault at a slightly-too-high or sloped obstacle starts (log `native_local_vault_started`, `native_starts` > 0);
- a steep-slope or ledge assist arms and releases (`slope_arms`, `slope_climbs`).

To get the log lines, set `CowboyBingusDiagnostics = true` for `ConsistentVaulting.log`.
