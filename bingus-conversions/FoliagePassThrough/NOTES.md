# Foliage Pass-Through v1.0 — port to game build 26088801

Offline, static port. Nothing was installed; the game folder, `~/.config/hd2arsenal`, `<steam-library>` (read only:
the two binaries were hashed) and `upstream-bingus/` were not written; the game process was not touched. Source:
`upstream-bingus/FoliagePassThrough` (tag `v1.0`, every file equals the `components.lock.json` pin; the pack copy
is identical).

Rebuild: `python3 -I tools/static_evidence.py && python3 -I tools/map_targets.py && python3 -I tools/build_map.py
&& python3 -I -B build.py --tests && python3 -I tools/make_probe.py`.

## Files

| File | What |
| --- | --- |
| `MAP.json` | 111 rows: 2 pins, 4 layout, 4 fields, 2 template values, 99 targets (107 high, 3 medium, 1 low). |
| `tools/static_evidence.py` → `tools/static-evidence.json` | loader, ray-step and query-table comparisons (old `game-pre1020.dll` vs new `game-26088801.dll`). |
| `tools/map_targets.py` → `tools/target-map.json` | systematic old→new identity of the 99 target rows (from the read-only live capture `native-work/megapack-projectile-tail-output.txt`). |
| `build.py` | copy, remap, assemble with upstream `scripts/build.py assemble()`, reproduce v26, archive, LuaJIT checks, tests. |
| `out/entry.lua`, `out/944fd9181c9a3fcd.lua.main`, `out/9ba626afa44a3aa3.patch_0` (+ empty `.stream`/`.gpu_resources`) | the option: one plaintext resource `mods/cowboybingus/foliage_pass_through` (the pack's `direct` entry, no bytecode). |
| `out/build-receipt.json`, `out/TESTS.json`, `out/entry.diff` | hashes, edits, reproduction, test results, the full entry diff. |
| `live/foliage_readonly.lua` | read-only probe (L1–L4 below). |

## What the earlier attempt left unresolved, resolved

1. **Template field moved `+0xF4 → +0xF8`.** The projectile ray step's unique instruction pair
   `mov edx,[rcx+0xAC] / jmp / mov edx,[r15+0xF4] / mov edx,[rcx+rdx*4+8]` (old 0x13ABDA5, function 0x13AB156) is
   `mov edx,[rcx+0xB4] / jmp / mov edx,[r15+0xF8] / mov edx,[rcx+rdx*4+8]` in the new build (0x1242BAE, function
   0x1241F5E), and `r15` is loaded from the projectile index in both (`[rcx+rax*8+0x37C7670]` → `+0x3182E70`). The
   live capture agrees: `+0xF8` holds only 0/2/3, `+0xF4` is a new field (61, 125, 181, 188 …), the proximity query
   name hash moved to `+0xFC`.
2. **The no-foliage template value changed `2 → 3`** (the earlier work missed this; keeping 2 would have switched
   the 95 rows to the *back-face* damage query). The query table each mission builds (old 0x175BE60, new 0x15D0002)
   gained a slot at index 1 (`damage_query`, flags 0x80000001); old slots 1..33 equal new slots 2..34 exactly.
   Names by Stingray murmur64 (upper 32 bits): `damage_query` = 0x393D9518 (template 0 in both),
   `damage_no_foliage_query` = 0xEAF0A29F (old template 2, new template 3).
3. **Duplicate-name identities.** Types and explosions are ordered enums: 47 targets have a name hash that is unique
   among the 355 live rows (anchors); their type shift (new−old) is non-decreasing in old type (0, +1, +2 … +5).
   Every other target has exactly one same-name row strictly inside its anchor window; the two `120mm HE Cannon
   Round` rows (old 234, 238) share a window with exactly two candidates and are assigned in order (their
   explosions 63 / 74 are unchanged and match). The resulting old→new explosion map is a function and order
   preserving (+1 after 164 and after 334, one explosion gone between 176 and 187, +2 at the end; a bound
   compare in the ray step went `cmp ecx, 0x1A7` → `0x1A9`, plausibly the explosion count: consistent, not relied on). All resolved rows are on template 0 in the capture.

## Map summary

| Value | Old | New | Confidence / witness |
| --- | --- | --- | --- |
| EXE / game.dll SHA-256 | F5FEE03D… / 2E2C3B7C… | 0ACC07DE… / 6D1D4D3B… | high, hashed from the install |
| `buffer_rva` | 0x348E2F8 | 0x2E49C28 | high, loader store (old 0x11EC607 / new 0x107DE27; loaders 121 = 121 instructions, same shapes) |
| `index_rva` | 0x37C7670 | 0x3182E70 | high, loader `lea r12` + ray-step row load |
| `slots` | 351 | 356 | high, loader memset 0xAF8 → 0xB20 |
| `row_size` | 0x110 | 0x110 | high, loader `imul 0x110` |
| TYPE / NAME / EXPLOSION | 0x00 / 0x08 / 0x90 | same | high, loader index store; capture (355/355 identities, 47 unique-name anchors) |
| TEMPLATE | 0xF4 | **0xF8** | high, ray step (above) |
| VANILLA / NO_FOLIAGE | 0 / 2 | 0 / **3** | high, query table + name hashes |
| targets | 99 | **95 shipped** | 95 high; 3 medium (excluded); 1 removed |

Not shipped (reported as blocked rather than guessed):

* `Orbital_illumination_shot` (old 190 → 194, explosion 390 → 391), `Missile_SAM` (203 → 206, 334),
  `Orbital_Smoke` (247 → 251, 75): their name hash is 0, so only the type window and the explosion (exactly the
  value the neighbouring shift predicts) identify them. Medium; left vanilla. To include them later, a live check
  that these rows are the orbital illumination / SAM / smoke shells (e.g. firing one and watching which row's
  instances spawn) is needed.
* `200kg Bomb` (old 192, name 0x1CB4F094, explosion 182): no live row has its name hash, no row in its type window
  has an impact explosion, and its explosion is the one the explosion map shows removed. The projectile is gone or
  replaced in this build; nothing to target.

## The write (the only one)

`Mod.set_template` writes 4 bytes per row, once per session: `ProjectileInfo + 0xF8 := 3` in the loaded
`generated_projectile_settings` rows (committed private RW memory, one `bingus_write` batch under one page check,
each field read back; landed writes are undone if the batch fails). Before writing, every row must have
`+0x00 == type`, `+0x08 == name hash`, `+0x90 == explosion` and `+0xF8 ∈ {0, 3}`, else nothing is written.
Witnesses: rows `layout.*`, `field.*`, `enum.*` above (all high, code-backed), and 95 high target identities.
Semantics: the ray step casts with `handles[row+0xF8]`, and handle slot 3 is created from `damage_no_foliage_query`.

## Not verified / open

* **New behaviour in this build:** the ray step now also does an extra sweep when the row's float `+0xA4 > 0`,
  using the query in handle slot `0xF0` (filled outside the query-table function; its name is not resolved). If a
  target row has `+0xA4 > 0`, that sweep may still detonate it in leaves. Probe L3 lists such rows.
* The `layer 27 = foliage` difference between the two queries (from the old physics settings) was not re-read:
  game data is now in DirectStorage `DSAR` bundles (compressed), not readable offline here. The query names and
  flags are unchanged, so the same physics properties are referenced.
* In-game effect (shots into canopies), multiplayer, cost: not tested.

## Tests (`out/TESTS.json`)

`tests/test_mod.lua` (10 tests) passes on the port and on unmodified upstream, workspace Windows LuaJIT (GC64) under
Wine, private prefix. The port run maps the test's own build data (template field 0xF8 and value 3, 356 slots, 95
rows and their call budget 192/96/191, the type numbers it names via MAP; every replacement counted in
`fixture_changes`). Under Linux LuaJIT the suite fails identically for port and upstream (it needs kernel32):
environment. `tests/compile_entry.lua` passes in Linux GC64 LuaJIT; `tests/test_entry.lua` passes under Wine (the
entry refuses outside the game and hooks nothing). `tests/game_lua.py` (the game's old lua51.dll) not run.
Reproduction: the unmodified assembly equals the lock's resource SHA-256 and resource `944fd9181c9a3fcd` of the v26
option archive byte for byte.

## Read-only in-game checks (`live/foliage_readonly.lua`)

B = game.dll base. Reads only.

* **L0** `FoliagePassThrough.log`: with the port loaded, `applied: 95 projectile types use the no-foliage query`.
* **L1** (ship or mission) `ptr(B+0x2E49C28)` non-null; for i = 1..355 `ptr(B+0x3182E70+8*i)` is a row with
  `u32(row) == i` (slot 0 empty). Expect 355 rows, 0 mismatches.
* **L2** histogram of `u32(row+0xF8)` over all rows: only values 0..3 (most 0; 3 on plasma/laser rows; the 95
  targets at 3 once the mod ran). `u32(row+0xF4)` should rarely/never be 0..3.
* **L3** each of the 98 identified rows: `+0x00/+0x08/+0x90` equal the MAP `new` values (expect 98/98); template 0
  before the mod, 95 at 3 after (the 3 medium rows stay 0); lists rows with `f32(row+0xA4) > 0`.
* **L4** the mod's status table, if visible from the eval state.
