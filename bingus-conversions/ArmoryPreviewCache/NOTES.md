# Armory Preview Cache v23.1 — port to Steam build 26088801 (plain LuaJIT)

Static, offline port of the Vanilla Plus Megapack option `ArmoryPreviewCache` (module
`mods/cowboybingus/armory_preview_cache`, resource hash `88db289011074931`). Nothing was installed; the game folder,
`~/.config/hd2arsenal`, `<steam-library>` and `upstream-bingus/` were not written and the running game was not touched.
Inputs: the captured images in `native-work/evidence/` (old `game-pre1020.dll` = 25480438, new `game-26088801.dll`
+ `.pdata`, `exe-26088801.bin`), the old exe capture `r6_reload_exe_20261017.bin`, the pinned source.

## Source

`upstream-bingus/VanillaPlusMegapack/components/ArmoryPreviewCache` (every file in `components.lock.json`
`source_sha256` checked). `upstream-bingus/ArmoryPreviewCache` is checked out at tag `v23.1` (`ae7e2d9`) and its
`src/`, `tests/`, `scripts/module.py` are byte-identical, so either is the locked revision; the build copies the
pinned component. `src/pixel_*.lua` are not part of the shipped wrapper (`scripts/module.py`) and are not mapped.

## Files

| File | What |
| --- | --- |
| `MAP.json` | 189 rows, one per build-specific site (file, line, old, new, category, cited facts, witness count, confidence, `feeds_write`, exact `replace`), and the 77 facts with their witnesses (old code site -> new code site and value, aligned function pairs, data reads). 182 high, 7 medium, 0 low, 0 unmapped. 125 rows change the source, 64 confirm an unchanged value. |
| `analyze.py` | Regenerates `MAP.json` (`python3 -I analyze.py`, ~5 min; reuses `mom-port/tools` and `myc-port/tools/lib.py`). |
| `build.py` | Copies the pinned source to `work/port` and `work/upstream`, applies `MAP.json` (each edit on its recorded line, exactly once) and the 4 code edits below, assembles with the component's own `scripts/module.py wrapper()` exactly as the pack's WRAPPERS path, reproduces the shipped resource from the unmodified copy, writes `out/`, compiles and smoke-runs. `--tests` runs the upstream tests. |
| `out/wrapper.lua` | The plaintext port wrapper (168084 bytes, SHA-256 `FA60ACF7…F04482`). `out/wrapper.diff` is its whole diff against the upstream wrapper. |
| `out/option_entry.lua` | The option resource body: the pack's `discoverable_resource()` shape (`-- HD2-Addon: mods/cowboybingus/armory_preview_cache`, then `return assert(loadstring("<\ddd payload>", "@…"))(...)`) with the plaintext wrapper as payload instead of non-GC64 bytecode. |
| `out/9ba626afa44a3aa3.patch_0` | Archive with ONLY resource `88db289011074931` (type-2 envelope `struct.pack('<II', len, 2) + body`, SHA-256 of the archive `6C84B3D7…45013E`), made with `BingusSharedLoader/scripts/archive.py make_archive` and round-tripped; empty `.stream`/`.gpu_resources` beside it. |
| `out/build-receipt.json`, `out/TESTS.json` | Hashes, every edit, reproduction result, LuaJIT/Wine smoke output; test results. |
| `tools/port_tests.py` | Maps the upstream test inputs (scripts, captured UI replays, frozen v23 reference adapters) to the new layout. |
| `live/armory_preview_cache_readonly.lua` | Read-only live probe (A0–A16). |

Rebuild: `python3 -I analyze.py && python3 -I -B build.py --tests`.

## Reproduction

The unmodified wrapper (25480438 pins) compiled with a private non-GC64 LuaJIT (`work/luajit-fr1`, the vendored
LuaJIT with `-DLUAJIT_DISABLE_GC64`, never shipped) gives the lock's `resource_sha256` `46F5227D…3176FB` byte for
byte, and `discoverable_resource()` of that bytecode is byte for byte resource `88db289011074931` in the shipped
v26 option archive. The GC64 game VM cannot load that bytecode, so the port ships the plaintext wrapper in the same
shape. The installed copy's `Unsupported game build` is install.lua's SHA gate (`build.memory.verify_build`); the
port passes the 26088801 pins (`6D1D4D3B…1C08F` / `0ACC07DE…74EABE`) together with the mapped data.

## What changed (build data)

* **Globals** (12 RIP-relative witnesses each, all agreeing): entities `0x346bf98 -> 0x2ce41b8`, attachment group
  count `0x348da98 -> 0x2e493c8`, group pointers `0x37c5b50 -> 0x31812e0`, UI preview `0x347ce60 -> 0x2e38190`,
  script API `0x3326308 -> 0x2ce14c8`, lease table `0x347ceb0 -> 0x2e381e8`, kit catalogue `0x33264f8 -> 0x2ce16a8`,
  presets `0x347cef8 -> 0x2e38230`, UI state `0x347ce28 -> 0x2e38160`, UI world `0x347cd90 -> 0x2e380c8`, thumbnail
  manager `0x347cd80 -> 0x2e380b0`, UI dispatch `0x3326e68 -> 0x2ce2040`; package map `0x3799810 -> 0x3154f90` (its
  only reader aligns 1:1, all four fields); fallback attachments `0x213f2b8 -> 0x1fc7988` (only use maps there; numbers
  and hashes byte-identical).
* **UI globals block** (image_native reads them as one block from the manager global): 0x138 -> 0x140 bytes, words
  ui 4 -> 6, state 42 -> 44, lease 76 -> 78 (preview stays 56).
* **Natives (game.dll)**: package acquire `0x12fe350 -> 0x11912f0`, release `0x12fe4e0 -> 0x1191480`, set_texture
  `0x14499e0 -> 0x12e16f0`, set_uv `0x143eef0 -> 0x12d6c00`, set_size `0x1447160 -> 0x12dee70`, set_alpha
  `0x1448ad0 -> 0x12e07e0`, material `0x144f800 -> 0x12e7510` — each identical apart from relocations, 12/12 mapped
  callers agree; register_image `0x1392680 -> 0x1229090` aligned 1:1, differing only in the manager fields it uses.
* **Natives (exe, application table = [ScriptApi+16])**: ScriptApi `0x27c8d80 -> 0x2870240` (live capture value),
  create `0x31af50 -> 0x2ea5a0` (slot 368), destroy `0x31b360 -> 0x2ea9b0` (400), register `0x31e030 -> 0x2ed5c0`
  (528), package request `0x320dd0 -> 0x2f0260` (752), release `0x321030 -> 0x2f04c0` (768): the table's 126 slot
  initializers exist in both builds and each APC slot holds the mapped function (bodies equal apart from the engine
  field `0x1480 -> 0x15f8`); texture format size entry `0x1658990 -> 0x16f5510` (value 32).
* **Signatures**: all 16 entries re-taken from the new images at the mapped RVAs, same lengths. Equal to the old bytes
  apart from RIP/branch fields, except: destroy (engine field `0x1480 -> 0x15f8`), register_image (manager field
  `0x2b80 -> 0x2ca0`), register (bytes 24–31 lie past its jmp: padding in 25480438, other code in 26088801).
* **Thumbnail manager**: a per-card occupancy array at +0x2ab0 grew from 15 to 64 bytes per card, so every later
  field moved: type 11052 -> 11344 (still 7), active 11064 -> 11356, phase 11096 -> 11388, layout 11100 -> 11392, atlas
  11112 -> 11400, registry count 11136 -> 11424, registry 11144 -> 11432 (128 slots, as before); read size 12176 ->
  12464; word indices 2763/2766/2774/2775/2778/2784/2786 -> 2836/2839/2847/2848/2850/2856/2858. Cards and items
  (stride 1816 from +16, state +1832, count +1836, items 120 bytes) unchanged. Witnesses: the manager's init (writes
  7 to +0x2c50), tick, (re)creation and registration functions aligned 1:1.
* **Controller kinds**: renumbered by +2 around them: Armory 224 -> 226, briefing 229 -> 231 (same dispatch lists
  registered; the game's own lookups map to the new numbers; the Armory controller's own code says 0xe2). State ids 5
  (Armory) and 14 (briefing) unchanged; dispatch rows (+5740 count, +5744 rows, kind +8) unchanged.
* **Briefing controller**: grew 0x40 before its loadout block: grid 864032 -> 864096, loadout widgets 422768 ->
  422832 (stride 5464 unchanged), records 454728 -> 454792 (medium, see below).
* **Weapon package table** (entities `0xf12558 -> 0xf14008`): 1080 -> 1100 buckets, records +17280 -> +17600,
  540 -> 550 records (the bound is medium). The getter aligns 1:1 with the changed constants; BRIEF/diverkit live
  capture measured 0xf14008, 1100, 17600.
* **Weapon configurations** (entities `0xf12e10 -> 0xf148d8`): 648 -> 658 buckets, configurations +10368 -> +10528,
  324 -> 329 of 46600 bytes (the default configuration sits at 10528 + 329 x 46600 = 0xea1968 in the new getter).
* **Unchanged and witnessed**: Armory control +280216, grid +523752, pre-select records +37728 / mode +37968 /
  widgets +5256 stride 12304; grid meta +597772, records +602104, kind +602052, owned cards +622592, window +622584,
  rows +2816 stride 44752, columns +44724, widgets +9192 stride 11112; widget record pointer +1984, bound byte +2005,
  element +272, spinner +616, material +328 / name +336, record type +8 (== 3), card +60, slot +64, invalidation +68,
  style +72; UI world +15432, blocked +15892, state stack +0x429c; lease table header/rows/allocator; preview queue
  +50448 / rows +50456 x 200 x 128 (identity +64, count +80, slots +88); kits [0]/[8], row key +0 / id +32; presets
  +7392 / rows +761060 x 24 (+4 key, +8 kit); attachment rows 88 bytes (+8 number, +32 id, +48 kinds, +56 count);
  package map +0/+8/+16/+24; hashes 984135806 (texture slot), 3400165836 (atlas render target),
  0x27ef06435506e446 (thumbnail material).

## Code edits (the BRIEF's code-page rule)

APC already reads every code byte through ReadProcessMemory (`api.read`), never a direct deref. In v23 a failed read
(page not resident yet) asserted and disabled the mod at init. The port keeps every check: a signature whose page
cannot be read yet is recorded, and the first call of any native covered by that signature list
(`native.lua`: acquire/release; `image_native.lua`: create/destroy/register/set_texture/set_uv/set_size/set_alpha/
material/register_image) first re-reads and compares it, raising if still unreadable or different; a native is never
called unchecked. With every page resident nothing changes (no wrapper is installed). Four edits, listed in
`out/build-receipt.json` `code_edits`. No PORT51/compat51/cffi; the code stays APC's own LuaJIT code.

## Memory writes and game calls, with their evidence

1. **Package lease calls** (game acquire/release on the lease table at `[game+0x2e381e8]`): functions identical,
   12/12 callers; table global 12 witnesses; APC re-reads the table before and after each call and asserts the count
   moved by exactly one (unchanged runtime guard).
2. **Atlas swap** `[manager+11400] = fresh` (freeze) and `= t.handle` (restore): the game's own atlas creator does
   `create(w,h,1,0,0xcaaa69cc,1)` through app+0x170, `register(0xcaaa69cc, tex)` through app+0x210 and stores the
   result at `[manager+0x2c88]` in 26088801 (`[+0x2b68]` in 25480438) — the same call sequence and slot APC uses
   (fact `exe.application_slots_used_by_game`, `manager.layout`). APC first checks `[game+0x2e380b0] == manager`,
   `[manager+11400] == the atlas it captured` and the descriptor id.
3. **Render target create/register/destroy** (exe 0x2ea5a0/0x2ed5c0/0x2ea9b0 via the mapped slots; APC asserts each
   slot value at init).
4. **Widget bytes**: `widget+2005 = 1` (bound) and `record+68 = 0/1` (invalidation), with the record pointer read
   from `widget+1984`; set_texture/set_uv/set_size/set_alpha/material/register_image on `widget+272` and alpha on
   `widget+616`. Witness: the game's own thumbnail widget update (0x1943780 -> 0x17c4950) is identical and does the
   same: reads `[widget+0x7c0]`, `[rec+8]==3`, clears `rec+0x44`, clears `widget+0x7d5`, calls
   material(widget+0x110, 0x27ef06435506e446, 1), set_alpha(+0x110 / +0x268), set_uv. register_image writes the
   manager registry (count +11424, array +11432) inside the game function.
5. Which widgets: Armory grid widgets (grid+2816+row*44752+9192+col*11112) and pre-select widgets
   (control+5256+i*12304) — unchanged, high. Briefing loadout widgets (owner+422832+i*5464) — high (uniform +0x40
   shift, array base and stride witnessed); APC binds them only when each widget's record pointer equals
   owner+454792+i*80 and the record and manager item agree (kind, card, slot): a wrong records base can only make it
   fall back to the grid, never write elsewhere.

## Medium rows (7)

* `dependencies.lua:73/78` — configuration pair layout (+0 (kind, number) x 10) and allowed kinds (+80): stride and
  copy unchanged, no aligned reader of these 120 bytes found. Read-only; a wrong layout only changes which packages
  are prewarmed (A12 shows the values).
* `native.lua:144` — weapon record bound 550 (records start at (index + 550) x 32; capacity/2 as before). Read-only;
  a larger index raises inside the snapshot (the step is skipped, no leases change). A11 shows the max index.
* `image_native.lua:162/348/854/862` — briefing records 454792: no code uses the base directly (reached via each
  widget's record pointer); rests on the uniform +0x40 shift of every witnessed field from 0x60000 to 0x80000 and the
  grid. Self-checked as described in write 5. A9 confirms it in one look.

## Verified statically / not verified

Verified: every row above with its witnesses; the port wrapper differs from upstream only on mapped lines, the code
edits and the pin line (`out/wrapper.diff`); `loadstring` in the Linux GC64 LuaJIT (FR2 set); under Wine with the
workspace's Windows GC64 LuaJIT the option entry loads, installs its update hook and stops cleanly on the first update
(no game.dll in that process); the upstream reproduction above.

Not verified: anything only true at run time (heap objects: manager, controllers, widgets, lease table contents,
weapon/configuration tables), the texture descriptor layout (medium fact, only asserted on), rendering and behaviour
in the game. The exe SHA-256 is the BRIEF's value (the game folder was not read).

## Upstream tests (`out/TESTS.json`)

Run on the port (with its test inputs mapped by `tools/port_tests.py`: test-script constants, the captured Armory and
loadout UI replays relocated to the new layout — globals, application table, manager re-laid out, kinds 224/229 ->
226/231, briefing +0x40 and pointers into it, weapon table — and the frozen v23 reference adapters given the same
edits) and on an unmodified upstream copy; Linux GC64 LuaJIT, then the Windows LuaJIT under Wine (private prefix in
`work/wine-prefix`) for those needing kernel32. 17 pass on both, including all eight native-adapter tests on the
captured UI (`test_current_ui`, `test_visible_adapter`, `test_material_synthetic`, `test_gate_equivalence`,
`test_policy_gate`, `test_idle_gate`, `test_lease_table`, `test_frame_budget`). 5 fail on both (environment: Wine's
process memory/time telemetry): `test_install`, `test_platform_reads`, `test_ffi_names` x3.

## Read-only in-game checks

Run `live/armory_preview_cache_readonly.lua` through the memory tool (eval env: game, exe, read, ptr, get, region,
out, fmt) in each situation; B = game.dll base, X = exe base. Nothing writes.

* **Any time** — A1: 16-byte prefixes at the new RVAs read `ok` (or `unreadable` = page not resident yet; that is
  fine). A2: `[B+0x2ce14c8] == X+0x2870240`; app = `[that+16]`; app+368/400/528/752/768 = X+0x2ea5a0/0x2ea9b0/
  0x2ed5c0/0x2f0260/0x2f04c0; `u32 [X+0x16f5510]` = 32. A10: lease `[t+8]`=1024, `[t+24]`=2, `[t+16]`=0, `[t]`=t+32,
  allocator `[t+16416]` non-null. A11: weapon table `[[B+0x2ce41b8]+0xf14008]`: ids > 0, max record index < 550.
  A12: configurations `[…+0xf148d8]`: max index < 329; a configuration's pairs look like `kind 1..9 : number`, then
  0s; allowed kinds 0..9. A13: kits 1..1024, presets 1..4096. A14: groups 1..64, package map count a power of two,
  fallback numbers `0, 0xACC1561C, 0x7766DA38`.
* **Ship, no menu** — A4: depth 0 or the hub state; A5: `u32 [tm+11344]` = 7 (`tm = [B+0x2e380b0]`), active
  0xFFFFFFFF, registry count <= 128, cards' state <= 8 / count <= 15.
* **Armory, grid done** — A4: top 5, world non-null, blocked 0. A5: atlas `[tm+11400]` non-null, card states 8;
  A6: descriptor `0 0 w h 1 1 1`. A7: a dispatch row with kind 226 (Armory controller). A8: grid rows 1..12, row 0
  columns <= 4, widget 0's record offset a multiple of 80 below 20480, record type 3, element flags & 0x3C0000 =
  0xC0000. The mod's log (`ArmoryPreviewCache.log`, diagnostics on) shows `image_status` working and hits on revisits.
* **Armory weapon pre-select** — A8: mode block card < 6, closed byte 0, mode 0 (weapon); widget 0 record ==
  control+37728 `true`.
* **Briefing loadout** — A4: top 14. A7: a row with kind 231. A9: `6 /6` loadout widgets point at their records with
  the new offsets (`0 /6` with the old), records type 3, card < 6, slot < 15.
* **Briefing picker** — A9: grid rows `[owner+864096+597772]` 1..12.
* A16: the manager page is `0x4 / 0x1000 / 0x20000` (private read-write).

## Things worth knowing

* The option archive must go with the pack's shared stub archive/loader as before (BSL v18+); only this option's
  resource is in `out/9ba626afa44a3aa3.patch_0`. Not installed here.
* The learned profile and settings are keyed by the game/exe SHA pair, so a 25480438 profile is ignored (rebuilt).
* `work/` holds the copies, the private non-GC64 LuaJIT, `luajit.exe` and the Wine prefix (~hundreds of MB); delete
  freely, `build.py` recreates them.
