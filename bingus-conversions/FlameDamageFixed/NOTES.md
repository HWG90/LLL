# Flame Damage Fixed v1.2 → Steam build 26088801 (Vanilla Plus Megapack option `FlameDamageFixed`, offline port)

Source: `upstream-bingus/FlameDamageFixed` (git `v1.2`, clean). Every file hash equals `components.lock.json`
`source_sha256` (the pinned copy in `VanillaPlusMegapack/components/FlameDamageFixed` is identical). Old build 25480438
(EXE 1.8.46015.0), new build 26088801 (EXE 1.8.46659.0; game.dll `6D1D4D3B…C08F`, helldivers2.exe `0ACC07DE…EABE`,
re-hashed read-only from the install).

Nothing here used the network, touched the game folder (read-only reads of `bin/helldivers2.exe`, `data/game/game.dll`
and the `data/bundles*.nxa` archives only), `~/.config/hd2arsenal`, `upstream-bingus/`, or the running game. Nothing was
installed.

## Deliverables

| Path | What |
|---|---|
| `MAP.json` | 31 rows covering all 44 inventory sites (`inventory_sites`, none uncovered): file, line, old, new, method, re-checked witnesses, confidence, `feeds_write`, role, live check. `witness_check_failures` is empty. |
| `build.py` | `python3 -I -B build.py [--tests]`. Copies upstream `src/ scripts/ tests/` to `work/upstream` and `work/port`, applies the edits, assembles exactly as the pack does, archives, and runs the LuaJIT checks. |
| `out/entry.lua` | sha256 `643572d5…2ada20`, the plaintext entry. |
| `out/flame_damage_fixed.lua.main` | sha256 `d685633a…4f1436`, 88320 bytes. The same entry in the type-2 envelope. |
| `out/9ba626afa44a3aa3.patch_0` | sha256 `c8828f51…bc08d6`. Built with `BingusSharedLoader/scripts/archive.py make_archive` and round-tripped. It holds only `mods/cowboybingus/flame_damage_fixed` (`af1003f292e2726b`), not the shared stub. Empty `.stream`/`.gpu_resources` companions sit beside it. |
| `out/entry.diff` | Port vs the unmodified assembly: 10 lines. |
| `out/build-receipt.json`, `out/TESTS.json` | Input/output hashes, every edit, the LuaJIT output, and the test results. |
| `tools/` | Read-only analysis: `lib.py`, `align.py` (from hdh-port), `map_globals.py`, `map_fields.py`, `seed_fields.py`, `func_pairs.py`, `pairctx.py`, `root_new.py`, `slim_extract.py`, `witness.py`, `build_map.py` (writes MAP.json and re-asserts every witness), `mock_llm_probe.lua`. |
| `evidence/` | `globals.json`, `field-pairs.json`, `root-fields.json`, `seed-exe-230888.json`, `physics-functions.txt`, aligned listings, and `data/` (the two flame effects extracted read-only from the install, plus `found.json`). |
| `live/flame_damage_fixed_readonly.lua` | Read-only live probe for checks F0–F8. |

Rebuild:

```
cd tools && python3 -I -B map_globals.py && python3 -I -B map_fields.py \
  && python3 -I -B seed_fields.py --exe 0x230888 && python3 -I -B root_new.py \
  && python3 -I -B slim_extract.py a8193123526fad64 e3d15622a42863c4 a4f17daba8ecd8e5 \
  && python3 -I -B build_map.py
cd .. && python3 -I -B build.py --tests
```

## Packaging

- The pack builds this option as `BUILD_ASSEMBLED`: its own `scripts/build.py assemble()` produces one plaintext entry, which is enveloped as `<II len, 2>`.
- It was never bytecode, so there is no GC64 issue. The port ships the same plaintext entry.
- `build.py` stubs `build_addon` exactly as the pack's `build_entry()` does.
- The unmodified assembly reproduces the pinned resource (`8C168D6A…235B`, the lock's `resource_sha256`) byte for byte.
- It also equals the resource `af1003f292e2726b` inside the shipped v26 option archive byte for byte.
- No PORT51, compat51 or `require('cffi')` text: the code is upstream LuaJIT (real `ffi`, `bit`, `jit`). The declaration stays on line 1.
- LuaJIT 2.1 GC64 (`string.dump` flags 8 = FR2):
  - The entry compiles.
  - Run on Linux with a stand-in loader table, it stops at the vendored `bingus_memory.new()` loading a Windows DLL. That call is outside the mod's pcall, the same as upstream.
  - The unmodified entry stops at the same call, and `build.py` checks this.

## What changed (everything else is byte-identical to v1.2)

| MAP row | Constant | Old | New | Feeds a write |
|---|---|---|---|---|
| `spray.manager_rva` | game.dll SprayWeaponComponent manager | 0x3326BB0 | 0x2CE1D70 | W2/W3 selection |
| `effect.resource_root_rva` | EXE resource root | 0x23621A8 | **0x24099E8** | W1 address |
| `flame.world_ptr` | game.dll world pointer | 0x346BFA0 | 0x2E271F8 | W3 address |
| `flame.particle_manager` | engine world +particle manager | 0x230888 | **0x230768** | W3 address |
| `phys.filter_ptr` / `phys.filter_vtable` | collision filter pointer / hknpGroupCollisionFilter vtable | 0x27C5E40 / 0x148B938 | 0x286D330 / 0x1521958 | gate |
| `phys.worlds` / `phys.world_vtable` | physics world slots (stride 176) / world vtable | 0x27BA890 / 0x14B3148 | 0x2861D70 / 0x1549168 | W2/W3 address |
| `phys.units` | unit registry | 0x1A100F0 | 0x1AB76F8 | W2 selection |
| `phys.groups` | system-group allocator | 0x27C5B88 | 0x286D078 | W2/W3 group choice |
| `build.pins` | game.dll / exe SHA-256 (the "Unsupported game build" gate) | 2E2C3B7C… / F5FEE03D… | 6D1D4D3B… / 0ACC07DE… | gate |

- The refusal message now says "(needs 26088801)".
- `tests/test_fix.lua` places its synthetic memory at the same RVAs, so the same ten values are applied there.
- The comments naming EXE functions (0xCE6030, 0xE66F60) are left unedited. Their new addresses are 0xD3E960 and 0xEBF980.

## Every memory write, with its evidence

The mod writes only through its own adapter: `write_raw` and `write_u32` via WriteProcessMemory. Each write follows a
VirtualQuery check of committed + private + PAGE_READWRITE. It never writes code, image pages or the game's group
allocator. There are three writes. The pause/stop restore uses the W2 and W3 addresses again.

### W1: shared flame effect data (18 words, `Fix.apply_effect`, once per mission load)

- **Address**: `[exe+0x24099E8]` (root) → `+0x3F8` (resource manager) → `+0x2F0/+0x300/+0x304` type chain (0xD0 entries, next +0xC8) → particles entry → `+0x28/+0x3C` name chain (24-byte entries, value +8, next +0x10) → `+0x10` records + 160·value → data pointer (+0), size (+0x18) = 30896.
  - Root: 5/5 window witnesses (3 exact).
  - In the new image every load of the new root that reads +0x3F8 calls the counterparts of the old resource-manager functions (0x5F2160 → 0x6320E0, 0x5F2290 → 0x632210).
  - The engine lookup old 0x5F85A0 aligns 133/133 with new 0x638520 with no field difference. Exact windows cover each step: both `div` bucket reads, `[r11+0x28]`, `[rax+rcx*8+8]`, `[r11+0x10]`, `shl rdx,5`.
- **Value/semantics**: both flame effects were extracted from the installed slim data (`bundles.nxa` DSAR/LZ4, `tools/slim_extract.py`).
  - Their SHA-256 (`1f447c6f…ff7f` shared, `a1cf46aa…409f` Cremator) equal the build-25480438 pins in upstream `scripts/patch_table.py`.
  - The header, the 12 system sizes and all 18 shipped words match.
  - Upstream `tests/test_constants.py` passes on the installed effects. The patch table is therefore exactly as valid as in 25480438.
- **Guards (unchanged)**:
  - Header plus layout plus every patched word must be either its shipped value or its fixed value; otherwise the fix is refused.
  - The whole 30896 bytes must be private RW.
  - Every word is read back after writing.

### W2: weapon hit-box filter info (`Fix.mark`/`Fix.unmark`, u32 at body + 108, group bits 21–31 only)

- **Address**: `[exe+0x2861D70 + 176·w]` (world, vtable 0x1549168) → `+0x38` bodies + 160·index, word 27.
  - Worlds: 22/22 exact windows.
  - Stride `imul 0xB0` and the body accessor old 0x77D7B8.. are exact at new 0x804A58..: `+0x38`, `shl 5`, actor `[+0x90]`, id `[+0x70]`.
  - The bound/live accessor old 0x78CDB1.. is exact: `cmp [world+0x40]`, `test byte [body+0x44],3`.
  - The world constructor and destructor (old 0xD05870 / 0xD06D00) align completely with no field difference.
- **Which bodies**:
  - The weapon's unit family, through the unit registry 0x1AB76F8. It has 44 witnesses and the lookup is exact: `& 0x3FFFFF`, `+0x88`, unit +8 handle.
  - Parent / child / sibling at +0x1D0 / +0x1D8 / +0x1E0. The old `World.link_unit` implementation (0x1AF240) aligns completely; its only other change is the world tail shift.
  - Avatar subtrees are excluded by unit +0x358. The unit constructor (0x438-byte object built by spawn) aligns 708/708 and stores +0x358 identically. The avatar hash occurs in both game.dll images.
  - Body unit word 37 (+0x94) pairs unchanged in the aligned physics functions.
- **Meaning of the bits**: the collision check old 0xCE6030 is byte-identical at new 0xD3E960. That covers the filter info at body+0x6C, the matrix at filter+0x28 + 16·layer, and the same-group subsystem rule.
- **Group choice**: only 2047..2040, and only while the allocator marks the group free.
  - Allocator: 7/7 exact. The init `[a]=0x800` is exact, and so is the free-bit path at +4/+8.
  - No other body may carry the group.
- **Guards (unchanged)**:
  - `check_filter`: filter vtable plus layer 11's row equal to FLAME_ROW. Otherwise the self-hit fix is off.
  - Each body is re-validated per write: id/index, actor, unit, live flags, layer bits.
  - Only bits 21–31 change.
  - Private RW region.

### W3: flame particle-system query filter (`Fix.retarget_instance`, u32 at system + 0x1684: 11 ↔ 11 + g·2^21)

- **Address**: `[game+0x2E271F8]` (world; the world-init store is an exact window, 47 xref witnesses) → `+0x230768` (particle manager). **Changed:**
  - 32 of 32 mapped old sites of +0x230888 agree on +0x230768.
  - The whole world tail moved −0x120: 0x23096C, 0x230AC8, 0x230880 and 0x230890 moved the same way; 0x230588 and 0x230058 did not.
- The flame slot comes from the effect hash at +0x1B8/+0x1C8/+0x1CC.
  - Old 0x17D3C0 is byte-identical at new 0x177460.
  - `value & [+0x228]` indexes the `+0x278` lists of 24-byte {count, records} entries (exact windows).
- The instance is found by id: a 136-byte record with id at +0x10. The engine's own find-by-id loop is exact (old 0x18A0F0 → new 0x184160).
  - The id must equal the spray instance's +0x24. The spray update old 0x67F3D0 aligns 1184/1185 with new 0x689090; its 6 other changed displacements are not manager/entity/instance fields.
- The simulation (record +8) leads to the system list `[sim+0x30]` (80-byte elements, handle +0x34).
  - The check `[sim+0x20]` == effect data (exact windows in old 0x182FFD / 0x1845E2, which align completely).
- Handle: world = bits 30–31, index = bits 0–15. The engine resolver old 0x810460 is byte-identical.
  - From the handle: `[world_slot]` → `+0x498` table (world constructor identical; exact read old 0xE3C50D → new 0xE94F2D) → `+8` array, 16-byte {system, tag +8}. The table helpers old 0xDF7120 / 0xDF7490 are exact.
  - Last step: system `+0x1684`, with 6 of 6 mapped sites unchanged.
- **Not re-disassembled**: the code that indexes the table with a handle (old 0xE26213, 0xDF4206) lies on pages that are encrypted in the new capture (e.g. 0xE4C000–0xE4DFFF, entropy 7.95).
- **Guards (unchanged)**:
  - The mod checks each slot's tag: index and generation.
  - It writes only when the word holds exactly `from` (11, or 11 in its own group).
  - Private RW region.

**Blocked writes: none.** Every address, layout and value that feeds a write has high-confidence witnesses (MAP rows with
`feeds_write: true`; `build.py` refuses otherwise).

## Not verified / medium confidence

| MAP row | Why | Effect if wrong | Live check |
|---|---|---|---|
| `spray.tracked_hashes` (Lumberer arm 0x0736BEE2D6328726, Flame Sentry 0x820CC3BAFE962858) | Entity type hashes live in encrypted game settings, not in code. | The weapon is never tracked, so nothing is written (fail closed). | F2 |
| `phys.flame_row` (layer 11's matrix row) | Runtime data built from settings. | `check_filter` turns the self-hit fix off (fail closed); the effect fix still works. | F4 |

Not verifiable offline:
- Loader availability in the LuaJIT boot. The mod requires `CowboyBingusModLoader` API 1 with a `jit` table.
- Frame timing.
- Whether the build-26088801 Lumberer and Flame Sentry still play this effect.

## Tests (out/TESTS.json)

Port and unmodified upstream give identical results; all pass.

| Test | Runner | Result |
|---|---|---|
| `test_constants.py` | installed 26088801 effects | PASS |
| `test_fix.lua` | Linux GC64 LuaJIT | PASS |
| `test_guard_diff.lua` | Linux GC64 LuaJIT | PASS |
| `compile_entry.lua` | Linux GC64 LuaJIT | PASS |
| `test_fix_adapter.lua` | Windows luajit.exe under Wine (private prefix `work/wine-prefix`, 379 MB, deletable) | PASS |
| `test_ffi_names.lua` sdk / hostile / reverse | Windows luajit.exe under Wine | PASS |

Not run:
- `tests/game_lua.py`: needs the game's old `lua51.dll` through Windows ctypes.
- `tests/live_check.lua`: needs a running game process.

## Read-only in-game checks

`live/flame_damage_fixed_readonly.lua` loads the port's own `work/port/src/flame_damage_fixed.lua` in test mode with its own `_G`. It drives the port's lookups and driver against an api whose write guards always refuse. Run it through Link's Link to Memory:

```
eval local p=assert(io.open('Z:<workspace>/native-work/megapack-port/FlameDamageFixed/live/flame_damage_fixed_readonly.lua','rb'));local s=p:read('*a');p:close();local f=assert(loadstring(s,'@fdf_readonly'));setfenv(f,getfenv(1));return f()
```

Run it on the ship, in a mission with a Lumberer in view, and right after it (or your Flame Sentry) fired. `tools/mock_llm_probe.lua` runs it against mocked memory offline.

- **F0**: the module loads; `PHYS.PARTICLE_MANAGER` = 0x230768.
- **F1** (`[exe+0x24099E8]` → +0x3F8 → +0x2F0 non-null):
  - In a mission where the flame was loaded, `resolve_effect` gives an address whose page is protect 0x4, state 0x1000, type 0x20000.
  - `check_effect` is true with 18 words still shipped. It shows 0 after the installed mod fixed it.
  - The word at +252 reads 0x41700000 (shipped) or 0x40800000 (fixed). The old root `[exe+0x23621A8]` reads something else.
- **F2** (`[game+0x2CE1D70]`):
  - The count at +0x38 is ≤ 128, and the entities and instances pointers are non-null.
  - A Lumberer's arm is listed as LUMBERER ARM, with a non-zero unit handle.
  - The state reads 1 or 2 while it fires, and the burst id at +0x24 changes per burst. This is the TRACKED-hashes check.
- **F3** (`[game+0x2E271F8]` world, `+0x230768` manager):
  - The manager has a vtable, a count > 0 and power-of-two-like buckets. The old +0x230888 holds something else.
  - While a flame is alive the flame slot lists instances: `effect +0x20 == data` true, systems ≈ 12.
  - Each system shows `tag ok` true and filter `0xB` (layer 11). While the installed mod groups it, it shows `0xB + g·0x200000`.
- **F4** (`[exe+0x286D330]`):
  - The vtable equals exe+0x1521958.
  - `check_filter` reports ok. This is the FLAME_ROW check: row 11 words nonzero, bit pattern of layers {0,2,14,17,19,20,22,27,31,39,48,54,55,59,60,63,66,77,83,86,94,100,101}.
- **F5** (`[exe+0x2861D70 + 176·w]`):
  - At least one world in a mission, with vtable ok.
  - Bodies non-null, limit ≤ capacity, page private RW.
  - Live bodies have `id low24 == index` true and layer < 128.
- **F6** (`[exe+0x286D078]`): capacity 2048, summary words ≥ 1, groups 2047…2040 free (none taken by the game).
- **F7** (unit registry `[exe+0x1AB76F8]`, objects at +0x88):
  - With a Lumberer present, the tracked weapon shows a family of 3–16 units (hull, arm, cannon), each with its +0x358 resource hash.
  - A seated helldiver avatar (0x4D1C334D294DFA97) never appears in the family. "Own flame-hittable bodies" is > 0.
  - Log lines like "Self-hit fix disabled …: body memory not writable private data" come from the refused write guard. They are expected here.
- **F8**: writes attempted 0.
- **After installing**: `FlameDamageFixed.log` shows "Flame Damage Fixed v1.2 initialized …", with no "Unsupported game build". The first Lumberer burst of a mission logs "Flame effect fixed (18 words)." and "Self-hit fix active for the Lumberer (n/m own bodies in group 2047)."

## Installing (not done here)

- The shipped option archive holds this option's resource `af1003f292e2726b` and the shared Megapack stub `79e4f54aa542ec98`.
- The port replaces only `af1003f292e2726b` and must keep the stub, as with `runtime-modules/original-mods/install_option.py --port` for MOM/MYC (single main resource).
- Install with the game and HD2 Arsenal closed.
