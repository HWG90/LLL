# Shallow Water Diving (Megapack option, data-v3.10.1) → Steam build 26088801 (offline port)

Source: `upstream-bingus/VanillaPlusMegapack/components/ShallowWaterDiving`, the pinned copy. It is identical to
`upstream-bingus/ShallowWaterDiving` at git tag `v3.10.1` (HEAD 31c3d4e). Both match every `source_sha256` in
`components.lock.json`.

Builds: old 25480438, new 26088801 (game.dll `6D1D4D3B…C08F`, exe `0ACC07DE…EABE`, re-hashed read-only from the install).

Nothing here touched:
- the network;
- the game folder;
- `~/.config/hd2arsenal`;
- anything under `<steam-library>` (the two binaries were only hashed);
- `upstream-bingus/`;
- the running game.

Nothing was installed.

## Deliverables

| Path | What |
|---|---|
| `MAP.json` | 40 rows, one per build-specific constant or group: 33 high, 7 medium, 0 low, 0 unmapped. 20 rows feed a write. Each row has file, line, old, new, method, witnesses, confidence, `feeds_write`, `role` and a live check. `instruction_witnesses` holds 42 old/new instruction pairs, which `tools/build_map.py` re-disassembles from both images on every run. `witness_check_failures` is empty. |
| `build.py` | `python3 -I -B build.py [--tests]`. Steps 1–8 are in its docstring. |
| `out/entry.lua` | sha256 `8cf52557…ff18`. The option's resource body: `-- HD2-Addon: mods/cowboybingus/shallow_water_dive` followed by the plaintext wrapper that `build_module()` assembles. |
| `out/9ba626afa44a3aa3.patch_0` | sha256 `40671e00…9e03`. Holds only `mods/cowboybingus/shallow_water_dive` (`5895ed9013effd40`, 109305 bytes, type-2 envelope). Built with `BingusSharedLoader/scripts/archive.py make_archive` and round-tripped. Empty `.stream`/`.gpu_resources` sit beside it. The shared stub `vanilla_plus_megapack` is not included. |
| `out/wrapper.diff` | Port wrapper vs the unmodified wrapper: 21 replaced lines plus the `install_loader` line (revision `data-v3.10.1-26088801` and pins). |
| `out/build-receipt.json`, `out/TESTS.json` | Hashes, edits, reproduction proof, LuaJIT check output and test results. |
| `tools/` | Read-only analysis. `lib.py`/`align.py`/`show_pair.py`/`field_scan.py`/`imm_scan.py` come from hdh-port. Also `map_globals.py`, `map_fields.py`, `stride_fields.py`, `flag_setters.py`, `flag_qwords.py`, `map_rdata.py`, `build_map.py`, and `mock_llm_probe.lua` (an offline mock run of the probe). |
| `evidence/` | `globals.json`, `field-pairs.json`, `stride-*.json`, `flag-setters.json`, `flag-qwords.json`, `rdata.json`, plus aligned listings `pair_*.txt`. The listings cover the stance-offset writer, the Drownable settings getter, the Drownable lookup, the flag update, the record commit and the bit-9 change. |
| `live/shallow_water_dive_readonly.lua` | Read-only probe for checks L0–L9 below. |

Rebuild:

```
cd tools && python3 -I -B map_globals.py && python3 -I -B map_fields.py 150 \
  && for a in "0x3326a80 0x1c" "0x3326558 0x2c" "0x3326598 0x38"; do python3 -I -B stride_fields.py $a; done \
  && python3 -I -B flag_setters.py && python3 -I -B flag_qwords.py && python3 -I -B map_rdata.py && python3 -I -B build_map.py
cd .. && python3 -I -B build.py --tests
```

## Packaging (GC64)

- The pack compiles this option with `luajit -bsdW`, which produces FR1 bytecode the GC64 VM cannot load.
- It then wraps the bytecode as `-- HD2-Addon: …` + `loadstring("<bytecode>")(...)`.
- The port runs the component's own `scripts/module.py build_module()` unchanged, in the same order and with the same locales and install call. The one compile subprocess is captured instead of run.
- The resource is the shared loader's own `entry_source(module, wrapper)`: the declaration line, then the plaintext wrapper, in the same `<II len, 2>` envelope.
- No PORT51/compat51/cffi. The build refuses those words and the pack's forbidden native-modification APIs.

Reproduction:
- With the vendored non-GC64 LuaJIT 2.1 ROLLING, the unmodified copy's `build_component()` gives the lock's resource (`94E5B6DC…6AEA`).
- `discoverable_resource()` of it equals the shipped v26 option's resource `5895ed9013effd40` byte for byte.

GC64 check (`runtime-modules/build/linux/LuaJIT`, `string.dump` flags 8):
- `loadstring` compiles the entry.
- Without the shared loader, the mod reports `Bingus Shared Loader v14 or newer … is required`.
- With a fake API-1 loader, it reaches its Windows adapter and reports the missing bcrypt on Linux. Both happen inside the mod's own pcall, with revision `data-v3.10.1-26088801`.

## What changed

| MAP row | Constant | Old | New | Write? |
|---|---|---|---|---|
| `archive.EXE_SHA` / `GAME_DLL_SHA` | module hash pins (pack `scripts/archive.py`) | `F5FEE03D…` / `2E2C3B7C…` | `0ACC07DE…` / `6D1D4D3B…` | gate |
| `dive.global.mission` | mission object | 0x33266A0 | 0x2CE1850 | gate |
| `dive.global.local_player` | player manager | 0x3326468 | 0x2CE1618 | identity |
| `dive.global.entities` | entities | 0x346BF98 | 0x2CE41B8 | identity |
| `dive.global.avatars` | avatar manager | 0x3326D20 | 0x2CE1EE0 | identity |
| `dive.global.water` | Drownable manager | 0x3326A80 | 0x2CE1C40 | **address** |
| `dive.global.stance` | stance manager | 0x3326598 | 0x2CE1748 | value (restore) |
| `dive.global.movement` | movement manager | 0x3326558 | 0x2CE1708 | gate |
| `dive.entity.network_map` | entities + | 0xF22EC8 | 0xF24990 | identity |
| `dive.entity.records` | entities + | 0xF32F18 | 0xF349E0 | identity |
| `dive.avatar.stride` | per-avatar record stride | 0x1238 | **0x1240** | identity |
| `dive.controller.flags` | flag qwords (record +) / read size | 0xF80 / 0x414 | **0xF88 / 0x41C** | gate |
| `dive.settings.table_offset` | Drownable settings table (entities +) | 0xF12E20 | **0xF148E8** | value (pinned) |
| `dive.rdata.timeout` / `_fallback` / `window` | 2.0 timeout, fallback, message window | 0x23C7110 / 0x23C7100 / 0x23C7080 | 0x2246948 / 0x2246938 / 0x22468B8 | gate / inert / diagnostic |
| `dive.rdata.prone` / `crouch` | 0.9 / 0.4 | 0x23C6CCC / 0x23C69F8 | 0x22464EC / 0x2246210 | gate |
| `bingus_text.GAME` | settings, index, table | 0x3326340, 705500+212, 0x37C5650 | 0x2CE1508, 705628+212, 0x3180DE0 | text only |

Unchanged, with witnesses:
- mission fields +8/+0x40;
- player fields +0x84/+0x88/+0xE8/+0x3A8;
- avatar fields +0x6C/+0xF8/+0x110;
- record base +0x53D900;
- dive record +0xB84 (id), +0xB8C (elapsed), +0xB90 (landing);
- flag bits (qword 1 bits 31 swim, 36 ragdoll, 37 dive);
- Drownable manager +8/+0x20/+0x38/+0x40/+0x48;
- Drownable record stride 28 with +1/+4/+8/+16/+20/+24;
- stance manager +0x18/+0x38, stride 56, stance at +28 (2 prone, 1 crouch);
- movement +0x48A0/+0x48D8, stride 44, +8/+32;
- settings table: 122 × 16-byte slots, 64-byte records at +0x7A0, base at +4;
- avatar resource hash `0x4D1C334D294DFA97`. This is murmur64 of `content/fac_helldivers/cha_avatar/avatar_helldiver`, so it comes from the name, not the build;
- language count 15.

## Evidence for the non-obvious ones

**Per-avatar record (stride, flags).**
- Every aligned `imul …, 0x1238` in avatar-manager code is `0x1240` now: 237 imul and 9 mov.
- In the flag update (old 0x82DC80 / new 0x83AB00, ratio 1.0), `lea rsi,[r13+0x53D900]` is unchanged, and the three flag qwords moved from 0xF80/0xF88/0xF90 to 0xF88/0xF90/0xF98.
- In the record commit function (old 0xA3F220 / new 0xA59950), every field 0xB64..0xF40 is unchanged and +0xF48 and above moved +8. So the 8 inserted bytes sit after +0xF40: the dive record at +0xB84 is untouched and only the flags moved.
- A caller passes `am+0x53D900` (+index·stride) to that commit function (0x68BB72), which ties it to the same record.
- This matches dbf-experiments-port's `actor_layout` (0x1238→0x1240).

**Flag bit numbering.**
- `flag_qwords.py` follows each `bts/btr` in the 123 aligned callers of the commit function to the qword it is OR-ed or AND-ed into.
- All 48 distinct qword-1 bits seen keep their number, including 31, 36 and 37.
- The only change is in qword 2 (bit 9 → 10: a state was inserted there). This mod does not read qword 2.

**Drownable write target (+8) and its value.**
- The game itself writes record +8 in the stance-offset function (old 0x834000 / new 0x840E50, 100/100 instructions aligned):
  - it takes `[DM+0x40] + 28·i + 8`, with i from the map at DM+0x20 (capacity +0x28, empty +0x2C, mult +0x30);
  - the value is the Drownable settings base (+4 of the record that getter 0x512F90 / 0x51B580 returns), plus 0.4 when the stance is 1 and 0.9 when it is 2;
  - the constants are at new 0x2246210 / 0x22464EC.
- The getter is byte-identical except its table displacement 0xF12E20 → 0xF148E8. Its loop constants are 0x7A slots, wrap 0x79, `shl 4` slots, index at +8, records at `+0x7A0` and `shl 6`.
- Its neighbour getter's table moved the same way but its slot count changed (0x1C0 → 0x1C4). So 122 was checked here, not assumed.

## Every write (all into the local avatar's Drownable runtime record; no native calls; no code reads)

| # | Where (source) | Address | Value | Evidence |
|---|---|---|---|---|
| W1 | `apply`, dive_data.lua:509 | `[ [game+0x2CE1C40]+0x40 ] + 28·di + 8` | -1.3 (S.base, the standing reference) | Address: `dive.global.water`, `dive.water.manager_fields`, `dive.water.record` (all high). The game's own write of the same field is at new 0x840FA8. Value: `dive.settings.*`; the mod requires u32 `0x4A182741` and float `-1.3` exactly before using it. |
| W2 | `apply`, :526 (once per dive, startup debt) | same record +16 | 0.0 (drown elapsed) | `dive.water.record` (+0x10 read and written as a float; layout identical across 39 aligned Drownable functions) |
| W3 | `restore`, :382 (and the failed-write recovery) | record +8 | base + 0 / 0.4 / 0.9 by the current stance | stance row (high), plus the game's own stance-offset function as above |
| W4 | `restore`, :362 | record +16 | the bytes read before W2 | as W2 |

Gates before every write, all unchanged from upstream:
- The record's owner pointer at `[DM+0x38]+8·di` must hold the same 24 bytes as the local avatar's entity record.
- The avatar registry entry must match.
- Every snapshot read is re-read and compared.
- A VirtualQuery page check requires committed MEM_PRIVATE / PAGE_READWRITE.
- The value read must equal the current prone offset.

Every MAP row on the write path is high. The one medium row the written value depends on (`dive.settings.index_and_tag`: slot index 5, tag `0x4A182741`, base -1.3) is game data, not code. The mod asserts it and refuses before writing on any mismatch. `build.py` only accepts a medium row feeding a write when it is such an asserted row.

Nothing is blocked. No native calls are made. The option reads no game code, so the code-page rule does not apply. Every witness is on code that disassembles and aligns at ratio ≥ 0.94 (the key functions at 1.0), so none is on a packed page.

## Medium rows (why not high)

- `dive.entity.limits`, `dive.water.limits`, `dive.stance.limits`, `dive.movement.limits`: the mod's own plausibility bounds. They only cause waiting or refusal.
- `dive.settings.index_and_tag`: game data, asserted by the mod (see above). Check live with L7.
- `dive.rdata.timeout_fallback`: one migrated reference. The value is not 2.0 in either build, so it never passes the gate (the same as in 25480438).
- `dive.rdata.window`: only used to list nearby 2.0 values in a refusal message.

## Mod Options Menu integration

- The depth slider uses `_G.ModOptionsMenu` with `api == 1`: `register_option(id, {type='slider', …})`, `get`, `on_change`, and `version >= 2` for function texts.
- native-work/mom-port's ported MOM (`out/entry.lua`) exports `{api = 1, version = 3}` with exactly these functions. `register_option` accepts `slider` with min/max/step/default and functions for label/mod/description.
- SWD reads `rawget(menu, 'revision')`, which MOM's API table does not carry (nil). That is the same as upstream and harmless.
- test_loader's MOM scenarios pass on the port.
- Nothing build-specific is involved.

## Tests (`out/TESTS.json`)

- Run with the workspace's Windows LuaJIT under Wine, because test_dive and test_idle_equivalence copy memory with kernel32 `RtlMoveMemory`.
- Unmodified upstream: test_bingus_text 15 PASS, test_dive 13, test_loader 8, test_idle_equivalence 2. All exit 0.
- Port, with the test fixtures and `tests/reference/dive_data.lua` remapped by the same table (`TEST_MAP`, 123 token edits, tests only): the same 15/13/8/2 PASS, all exit 0. This includes:
  - the located timeout-failure message at the new address (0x22468D8);
  - controllers at stride 0x1240 with flags at +0xF94.
- Not run: tests/test_package.py, which checks a standalone release zip that is not built here.

## Live checks (read-only; `live/shallow_water_dive_readonly.lua` in the LLM eval env)

Run these on the ship, then in a mission:
1. standing on dry ground;
2. crouched;
3. prone;
4. standing in ankle-deep water;
5. two or three times while diving.

| Check | Read | Expected |
|---|---|---|
| L0 | `ShallowWaterDive` table | Revision `data-v3.10.1-26088801`. Status `waiting_for_mission` on the ship and `dive_ended` in a mission once the port is installed. Never `Unsupported game module`. |
| L1 | `[game+0x2CE1850]` +8 (u32), +0x40 (u32) | In a mission: +8 ≠ 0 and +0x40 in 1..7. On the ship, the mod waits. |
| L2 | `[game+0x2CE1618]` +0x84/+0x88 counts (1..4), +0xE8 player (byte +20 bit 0 = 1), +0x3A8 unit (≠ 0x7FFF). Map at entities+0xF24990, record at entities+0xF349E0+24·i | Hash `0x4D1C334D294DFA97`, owned bit 1, id = a small entity id |
| L3 | `[game+0x2CE1EE0]` count +0x6C, map +0xF8 → ai; registry +0x110+8·ai; controller = AM+0x53D900+ai·0x1240 | Registry equals the entity record. u32 at controller+0xB84 = id. Flags at +0xF88..+0xF9F: `dive` (q1 high bit 0x20) false at rest and true while diving; `swim` true only while swimming. The diving case is the one that proves the bit and stride; with ai = 0 the stride cannot be told apart, so a check in a squad slot ≥ 1 or 2 is also worth one run. |
| L4 | `[game+0x2CE1C40]` +8 capacity, map +0x20 → di; owners +0x38 → entry equals the entity record; record = `[DM+0x40]+28·di` | Node +4 = 0. Offset +8 per L5. Remaining +20 > 0. Region protect 0x4, state 0x1000, type 0x20000. |
| L5 | `[game+0x2CE1748]` map +0x18 → si, `[SM+0x38]+56·si+28` stance | Stance 0/1/2 when standing, crouched or prone. Water offset +8 = −1.3 / −0.9 / −0.4 respectively (outside a mod-held dive). This ties stance, the stance constants and the written field together. |
| L6 | `[game+0x2CE1708]` map +0x48A0 → mi, `[MM+0x48D8]+44·mi` | Root z +8 equals the avatar's height. Valid byte +32 = 1. In shallow water, surface − root z is small and positive. |
| L7 | `[entities+0xF148E8]` | Pointer non-null. The avatar hash is found among 122 slots with index **5**; record +0 = `0x4A182741`, +4 = −1.3. Old +0xF12E20 is some other table. If the index is not 5, the mod refuses ("Unsupported Drownable resource") and the asserted values must be re-mapped. |
| L8 | game+0x2246948 / 0x2246938 / 0x22464EC / 0x2246210 | 2.0 / not 2.0 / 0.9 / 0.4 |
| L9 | `[game+0x2CE1508]`+705840 → index < 15; `[game+0x3180DE0+8·i]`→+8 → code | `us` for English (the same check as myc-port) |

A gameplay acceptance check, with the mod installed, `CowboyBingusDiagnostics = true` and a dive in ankle-deep water:
- ShallowWaterDiving.log counts `protected` and `restored` up by one each;
- the avatar keeps the dive instead of swimming;
- after landing, L5's offset is back to the stance default.
