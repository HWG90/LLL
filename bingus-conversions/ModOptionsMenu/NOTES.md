# Mod Options Menu v1.2.1 — port to game build 26088801

Static, offline port. Nothing was installed, nothing in the game folder, `~/.config/hd2arsenal`, the game library
or `upstream-bingus/` was written, and the running game was not touched. The only inputs are the captured
images in `native-work/evidence/` (old `game-pre1020.dll` = build 25480438, its `.text` matches MOM's 25 prologue
signatures and its three data tables; new `game-26088801.dll`, `.text` equal to the disk file whose SHA-256 is
`6D1D4D3B…1C08F`), MOM's upstream sources and earlier port mappings.

## Files

| File | What |
| --- | --- |
| `MAP.json` | 185 rows, one per build-specific constant MOM's `src/` relies on (file, line, old, new, method, witnesses, conflicts, confidence, evidence; functions also carry old/new prologue bytes and a whole-body comparison; rows needing a source edit carry the exact `replace`). |
| `build_mom_port.py` | Copies upstream `src/*.lua` + `locales/*.lua` to `work/`, applies `MAP.json`'s edits (and two comment-only build-number edits), assembles the entry with upstream `scripts/entry.py` + BSL `build_addon.entry_source`, packs it with BSL `archive.make_archive`, checks `loadstring` in the Linux LuaJIT build. Refuses unmapped rows, edits that do not match exactly once on the recorded line, and any entry change that is not one of the edits; refuses `PORT51`/`compat51`. |
| `out/entry.lua` | The plaintext entry (139758 bytes, SHA-256 `E815ECAC…2C9C73`). |
| `out/9ba626afa44a3aa3.patch_0` | Archive, resource `mods/cowboybingus/mod_options_menu` (hash `fd50351f21814b0e`, type 2 envelope), SHA-256 `FC37E287…83362E`. The empty `.stream`/`.gpu_resources` companions the upstream package ships are beside it. |
| `out/BUILD-RECEIPT.json` | Hashes, the 38 edits, the LuaJIT result. |
| `run_upstream_tests.py`, `out/TESTS.json` | Upstream tests on the port and on an unmodified upstream copy. |
| `analyze_mom_map.py`, `tools/` | Regenerates `MAP.json` (`python3 -I analyze_mom_map.py`, ~2 min); `tools/cluster_sweep.py` writes `out/cluster-sweep.json`. |

Rebuild: `python3 -I analyze_mom_map.py && python3 -I build_mom_port.py && python3 -I run_upstream_tests.py`.

## What changed in the source (build data only)

* `native.lua`: the two SHA-256 pins; `TAB_LABELS_RVA 0x33114d0 → 0x2cc9f30`; `CATEGORY_TABLE_RVA 0x32ec990 →
  0x2ca50b0`; `INERT_DESCRIPTOR_RVA 0x32ecc60 → 0x2ca5320`; all 25 native RVAs (table below). No prologue
  signature changed: every new function starts with exactly the bytes MOM checks.
* `view.lua`: `MENU_SYSTEM_PTR_RVA 0x2e38170`, `UI_STATE_PTR_RVA 0x2e38160`, `INPUT_OWNER_PTR_RVA 0x2e38250`.
* `bingus_text.lua` (`M.GAME`, the game's Text Language): `settings 0x2ce1508`, `index 705628 + 212` (the
  settings object grew by 0x80 before that block; the language field inside the block is still +212),
  `table 0x3180DE0`, `count 15` unchanged. Its comment above still cites the 25480438 addresses.
* Comments only: "Steam build 25480438" → 26088801 in the headers of `native.lua` and `mod_options_menu.lua`.
* Every struct offset, enum, layout constant, label id and descriptor field is unchanged (rows in `MAP.json`).
* `src/api.lua` keeps its local DBF save change (the working-tree file is copied; `api.lua.before-dbf-save` is not).

| native | old | new | native | old | new |
| --- | --- | --- | --- | --- | --- |
| set_tab_labels | 0x17aac50 | 0x162bee0 | set_slider | 0x17fc2c0 | 0x167d560 |
| select_category | 0x19999c0 | 0x181ac40 | finish_simple | 0x1807060 | 0x1688300 |
| set_content_hidden | 0x19984c0 | 0x1819740 | finish_access | 0x1800fe0 | 0x1682280 |
| row_reset | 0x17ff700 | 0x16809a0 | scroll_thumb | 0x1793f60 | 0x16151f0 |
| row_release | 0x17ff4b0 | 0x1680750 | scroll_extent | 0x1794600 | 0x1615890 |
| row_init | 0x17fe8d0 | 0x167fb70 | set_opacity | 0x1448ad0 | 0x12e07e0 |
| add_child | 0x144c5c0 | 0x12e42d0 | scroll_reset | 0x1794570 | 0x1615800 |
| set_visible | 0x144cfb0 | 0x12e4cc0 | options_visual | 0x1998590 | 0x1819810 |
| set_label | 0x143bf90 | 0x12d3ca0 | measure_text | 0x144e1a0 | 0x12e5eb0 |
| set_string_arg | 0x143c950 | 0x12d4660 | set_position | 0x14476a0 | 0x12df3b0 |
| clear_args | 0x143a0f0 | 0x12d1e00 | set_size | 0x1447160 | 0x12dee70 |
| set_choice | 0x17fe7e0 | 0x167fa80 | hide_description | 0x17fab90 | 0x167be30 |
| play_sound | 0x1327f50 | 0x11bbaf0 | | | |

## Verified statically

* **Functions (25/25 high).** Each new RVA is agreed by at least two independent methods (unique masked byte window
  at the entry, `bindiff.migrate`, targets of the old call sites once mapped, position among byte-identical copies,
  unchanged distance to an independently mapped neighbour, the MBM port for `set_tab_labels`) with no
  disagreement. Then the whole old and new bodies were aligned instruction by instruction: 23 are identical apart
  from relocations (RIP displacements, branch targets, function-relative jump tables), including every read-only
  constant they load. The two that differ differ only inside the game's own code: `options_visual` compares the
  settings block at `[settings + 0xac45c]` (was `0xac3dc`), `play_sound` reads its audio interface at shifted
  offsets; MOM's arguments and the first-argument-unused property are the same. `set_string_arg` (13 copies),
  `set_label` (2) and `finish_simple` (2) exist as identical templated copies, and `set_visible` shares its
  first 48 bytes with another function; the chosen ones are confirmed by call sites, copy order and neighbour distance, and the `finish_simple`
  copies even call the same callees.
* **Globals.** 16 mapped old RIP-relative uses each, all agreeing: menu system `0x2e38170`, UI state `0x2e38160`,
  input owner `0x2e38250` (same as the working Mod Bindings Menu port and `megapack-global-candidates.json`),
  settings object `0x2ce1508`, language table `0x3180de0`.
* **Data tables, read from the new image.** `0x2cc9f30` holds `d876b36e 78934e12 8c02bd80` (the only occurrence;
  the escape menu init still passes it to `set_tab_labels(bar, labels, 3)`). `0x2ca50b0`: the nine category labels
  at +8 of 48-byte records (only occurrence; the settings lookup still addresses its +4 column); record 0
  (GAMEPLAY) now counts 10 settings instead of 11 — MOM reads only the labels. `0x2ca5320`: descriptors 139…145 are
  byte-identical to the old ones; `[0x2ca5320] = 139, +4 = 10, +12 = 0`. The settings lookup (identical code) finds
  category 10's descriptor array at module base + `0x2ca5320`, and with that base every other category's array
  starts with the same setting id as before, so setting ids did not move and 139 is still the inert BINDINGS
  activation type. Language table: 15 record pointers then null, as before.
* **Struct offsets (screen, tab bar, OPTIONS content, dialog, description box, panels, rows, selector, widget
  labels, input owner).** Each was traced to old instructions that use it (alone or folded into composite
  displacements such as `screen + 0x2def98 + 0x141e58 = 0x420df0`), mapped to the new build; every witness shows
  the same value. Scans of common values only accept old code inside the options-menu code ranges, so unrelated
  structures with the same numbers (several of which did change, e.g. a `0xf98 → 0xfa8` elsewhere) are excluded.
  Key witness functions are identical in the new build: dialog decision (`0x181e3a0`), set_description
  (`0x181a980`), row-by-setting lookup (`0x181ab10`, every panel offset, row count and the row array), release-all-
  rows (32 rows, `0xee218`), settings lookup, label argument setter, category button visual, OPTIONS input
  (dialog mode 0/1/other handling: mode 2 is still ignored by the game's confirm).
* **Wider sweep** (`out/cluster-sweep.json`): all 932 .pdata functions of the old widget core, tab bar, scroll,
  option rows/panels, OPTIONS content and menu helper ranges: 852 mapped, 750 identical apart from relocations,
  102 differ, 80 not mapped by a unique window. None of the operand changes in the 102 touches an offset MOM uses:
  they are other objects (the settings object +0x80, a style object +8, a few +0x58 shifts), stack frames and two
  callback slots (`[rcx+8]`/`[rcx+0x10]` in callback objects), plus GAMEPLAY's 11 -> 10 settings loop.
* **Layout constants** loaded from read-only data are unchanged: 806 / 64 / -64 / 32 (panel heights and steps),
  14 / 24 / 1 / 450 / 7 / 72 (description layout).
* **Input**: the 13 x 97 action label table (MBM's, now `0x24bc8a0`) is identical, so (group 0, action 12) is
  still Menu.ExtraOption1; the state array is still `owner + 0x328 + 32 * (97 * group + action)`, 13 groups.
* **Label ids**: all 32 `NATIVE_WORDS` ids (incl. OFF/ON) still occur in the new image's descriptor data;
  `TEXT_KEY` is still the key every format-argument call uses.
* **Entry**: compiles with `loadstring` in `runtime-modules/build/linux/LuaJIT/src/luajit` (LuaJIT 2.1).
  The entry differs from the upstream entry only on the edited lines.
* **Upstream tests** (`out/TESTS.json`), run under the workspace Windows LuaJIT in a private Wine prefix
  (`work/wine-prefix`), `test_bingus_text` also in Linux LuaJIT: categories, ffi_names, options_tab, slider_numbers,
  values and bingus_text pass on the port exactly as on unmodified upstream. `test_hostile.lua` page-faults in
  Wine for both (its `H.clash` harness), so it is an environment failure, not a port one. Fixture copies of the
  three global RVAs and the two SHA pins in the tests were mapped like the source.

## Not verified statically

* Anything that only exists at run time: heap objects (escape menu screen, OPTIONS content, rows, dialog, input
  owner, settings object, language records). Their layouts are proven only through the code that uses them.
* `TEXT_TEMPLATE 0xc67c7faf` (medium): the `#COUNT` template's text lives in game string data, not game.dll. Game
  code still compares a label with it at one site in each build.
* `APPLY_SOUND 0x468ca758` (medium): a sound event id that occurs in neither game.dll; cosmetic (the apply click).
* The EXE SHA-256 was taken as supplied (the game folder was not read). game.dll's is from the capture manifest.
* The language code strings in the records (e.g. `us`) are on the heap.
* Behaviour (input, rendering, saving) in the real game; nothing was installed or run there.

## Read-only in-game checks (for you to run with the memory tool)

B = game.dll base. `u32/u64/f32 [x]` = little-endian read at x. Nothing here writes.

**0. MOM's own gate.** With the port loaded, `ModOptionsMenu.log` should say `Native options layout verified
for current game build.` (it checks both SHA pins, all 25 prologues, the tab/category labels and descriptor 139
itself; on failure it names what changed and touches nothing).

**1. Static data (any time):**
* `B+0x2cc9f30`, 12 bytes = `6e b3 76 d8 12 4e 93 78 80 bd 02 8c`.
* `u32 [B+0x2ca50b0 + 48*i + 8]` for i = 0..8 = `396f27d7 196248d0 a522d2d0 15cecac1 9a688238 07e3b100 5db3b764
  a7c345ef 9bb47b92`; `u32 [B+0x2ca50b4]` = 10 (GAMEPLAY count; it was 11).
* `B+0x2ca5320`, 16 bytes = `8b 00 00 00 0a 00 00 00 02 00 00 00 00 00 00 00`.
* `u64 [B+0x1feba70 + 8*10]` = B + 0x2ca5320 (settings lookup → descriptor array of category 10).
* Prologues: 16 bytes at each new RVA in the table above = `new_sig` in `MAP.json` (28 for set_position/set_size).

**2. UI stack and menu system (escape menu open, on top):**
* `U = u64 [B+0x2e38160]` non-null; `u32 [U+0x42b0]` = depth (1..5); `u32 [U+0x429c + 4*(depth-1)]` = 1.
  Close the menu: no entry 1 in `U+0x429c .. +4*depth`.
* `M = u64 [B+0x2e38170]`; `S = u64 [M+0xc8]` non-null, 8-aligned.
* `u32 [S+0xe548]` = 3 before MOM adds MODS (4 after); `u32 [S+0xe54c]` = current tab (0 GAME, 1 SOCIAL,
  2 OPTIONS, 3 MODS); `u32 [S+8]` = the shown content (2 on OPTIONS; MOM also writes 2 on MODS).
* `u32 [S+0xe4c8 .. +12]` = `d876b36e 78934e12 8c02bd80`, then `c67c7faf` once MODS exists.
* Current tab's button state: `u32 [S+0x2fdc + 0xd48*tab]` = 3, active byte `[S+0x2fed + 0xd48*tab]`.
* MODS title widget (after MOM): `u32 [S+0x4e30]` = `c67c7faf`, `u32 [S+0x4e38]` = `ab2a7b35`, `u32 [S+0x4e3c]` =
  1, `u64 [S+0x4e40]` → the text "MODS" (or its translation), `u8 [S+0x4f88]` ≥ 1. The tab shows the text:
  this is the TEXT_TEMPLATE check.

**3. OPTIONS content `C = S + 0x2def98` (on the OPTIONS tab, before opening MODS):**
* `u32 [C+0x141e58]` = selected category 0..8 (follows your clicks); `u32 [C+0x141e5c]` = previous one.
* Category button text labels `u32 [C+0xbc8 + 0x3a48*i]` = the nine category ids above (i = 0..8).
* GAMEPLAY panel: `u64 [C+0x119a80]` = C + 0x23280 (row array), `u32 [C+0x119a90]` = 10, `u32 [C+0x119ab8]` =
  hovered row index. Same shape for the others at panel + 0xb00 (rows) and the family count: DISPLAY
  `C+0x120a88` / `C+0x128170` (19), ACCESSIBILITY `C+0x11b108` / `C+0x11fd58`.
* Row 0 = `R = C+0x23280`, row k at `R + 0x7ae8*k`: `u32 [R+0x7ac4]` = setting id (a GAMEPLAY id, those start at 0),
  `u32 [R+0x10a8]` = its label id, selector rows: `u32 [R+0x718c]` = index, `u32 [R+0x7190]` = choice count,
  `u32 [R+0x7198]` = first choice label; slider rows `f32 [R+0x7ab0]` = value.
* Description: `u32 [C+0x141e64]` = described setting (0x9c = none) and `u32 [C+0x141e4c]` = shown one; title
  label `u32 [C+0x141890]`, body label `u32 [C+0x141b48]`.
* Dialog: change a setting, then switch tab: `u32 [C+0x1413d0]` = 2 while UNAPPLIED CHANGES is open, `u32
  [C+0x1413cc]` = 0 (mode), `u8 [C+0x142219]` = 1 while edits are pending; confirm button flags `u32 [C+0x13d8a8]`
  has bit 0x10, its key `u32 [C+0x13f5d0], [C+0x13f5d4]` = 0, 10 (Menu.Select); cancel `u32 [C+0x13f628]` bit
  0x10, key `[C+0x141350], [C+0x141354]` = 0, 9 (Menu.Back).

**4. Input owner:** `I = u64 [B+0x2e38250]` non-null in menus; the per-action state bytes are at
`I + 0x328 + 32*(97*group + action)`, 0x9da0 bytes in all. Holding Tab on OPTIONS sets `u8 [I+0x4a8]` on the
frame it triggers (sampling may miss it; the dialog keys above are the easier shape check).

**5. Text Language (bingus_text M.GAME):** `G = u64 [B+0x2ce1508]`; `n = u32 [G+0xac530]` in 0..14 and changes
when you change Text Language (apply); `R = u64 [B+0x3180de0 + 8*n]`; `P = u64 [R+8]`; 16 bytes at P = an ASCII
code + NUL (`us` for English). `u64 [B+0x3180de0 + 8*15]` = 0.

**6. Not checkable by reading:** the apply sound (listen for the click on Tab/APPLY in MODS).

## Things worth knowing

* GAMEPLAY lost one native setting in 26088801 (its builder loops 10 times); MOM replaces those rows anyway.
* Installing: the archive and its two empty companions go together as the add-on's `Addon/` content (with the
  manifest of the upstream package or Arsenal's import); MOM needs Bingus Shared Loader v18+. Not installed here.
* The installed v26 copy's "unsupported game build" is the SHA gate in `native.lua`; this port changes the pins
  only together with the mapped data.
* `work/wine-prefix` (~380 MB) and `work/luajit.exe` exist only for the upstream tests; delete them freely
  (`run_upstream_tests.py` recreates them).
