# Mod Bindings Menu v2.3 — port to game build 26088801 (plain LuaJIT)

Static, offline port. Nothing was installed; the game folder, `~/.config/hd2arsenal`, `<steam-library>` (one log
read only) and `upstream-bingus/` were not written; the running game was not touched.

## Source

`upstream-bingus/VanillaPlusMegapack/components/ModBindingsMenu` (lock: revision v2.3, resource SHA-256
`B24B2A04…102E5C`). `upstream-bingus/ModBindingsMenu` is at tag `v2.3` (commit `ab48890`) and byte-identical to the
pinned copy for every locked file; the pinned copy is the one built from. The unmodified assembly
(`scripts/entry.py` `entry_text`, envelope `<II len, 2>`, the pack's ASSEMBLED path) reproduces both the locked
resource and the resource inside the shipped v26 option archive byte for byte (`out/build-receipt.json`
`reproduction`). MBM is a plaintext option (no `luajit -bsdW` bytecode), so there is no GC64 bytecode issue.

## Files

| File | What |
| --- | --- |
| `MAP.json` | 143 rows: every build-specific constant MBM's `src/` uses (file, line, old, new, method, witnesses, conflicts, confidence, feeds_write, evidence; `replace` = the exact source edit). `witness_functions` lists the old/new witness functions and whether their bodies are identical. |
| `analyze_mbm_map.py` | Regenerates MAP.json (`python3 -I -B analyze_mbm_map.py`, ~80 s). Uses `native-work/mom-port/tools` (momdiff, witness) read-only and MOM's MAP.json for shared rows. |
| `build.py` | Copies the pinned `src/`, `locales/` (SHA-checked against the lock) to `work/`, applies MAP.json's edits and the code-page edit, assembles with the component's `scripts/entry.py`, writes `out/`. Refuses unmapped or low rows, edits that do not match exactly once (and on the recorded line), unexpected entry changes, `PORT51`/`compat51`/`require('cffi')`. |
| `out/entry.lua` | Plaintext entry, 240050 bytes, SHA-256 `98592434…100D47`. |
| `out/mod_bindings_menu.main` | The resource (`<II len, 2>` + entry), SHA-256 `F7F255B1…D5FBF`. |
| `out/9ba626afa44a3aa3.patch_0` | Archive with ONLY `mods/cowboybingus/mod_bindings_menu` (hash `ace3bd664062daa9`), SHA-256 `FC6ADDED…4B4746`; empty `.stream` / `.gpu_resources` beside it. No shared megapack stub. |
| `out/build-receipt.json` | Hashes, the 87 edits, reproduction check, LuaJIT `loadstring` result (`runtime-modules/build/linux/LuaJIT/src/luajit`: OK). |
| `run_upstream_tests.py`, `out/TESTS.json` | Upstream tests on the port and on an unmodified copy, plus the port test below. |
| `tests/test_port_code_pages.lua` | Port test of the code-page rule with real `PAGE_NOACCESS` pages (Wine). |
| `live/mod_bindings_menu_readonly.lua` | Read-only live probe (L0–L10 below). |

Rebuild: `python3 -I -B analyze_mbm_map.py && python3 -I -B build.py && python3 -I -B run_upstream_tests.py`.

## "Waiting for initialized native binding code: input consume routine changed" — cause and fix

The installed copy (the earlier CFFI port, `port-tools/build_mbm_archive.py`) logged, on 2026-10-24 23:31
(`…/AppData/Local/LLL/Helldivers2/Logs/ModBindingsMenu.log`, read only):

    Waiting for initialized native binding code: input consume routine changed
    Native binding layout verified for current game build.

i.e. the very next probe (one second later) verified the same 20 bytes. The bytes were never wrong: the consume
routine (RVA `0x1190e30`, page `0x1190000`) was not yet resident. HD2 26088801's protection runtime keeps some
game.dll code pages no-access (a view of an encrypted section) until the game first executes them; MBM's build
check runs on its first frame, `read()` (ReadProcessMemory) fails on such a page and returns nil, and v2.3 treats
nil like different bytes. Upstream v2.3 would have stopped for the session on it ("unsupported"); the installed
port papered over it with a 1-second retry of the whole build check, keyed on the message text. Corroboration from
the static capture: two other MBM-relevant pages are still encrypted there (`0x1694000`, the tail of build_rows,
and `0x130d000`, the binding screen's init and tab switch), which is what an undecrypted page looks like.
The 20-byte signature itself also changed, but only in the rel32 of the call at +15 (the callee
`input_group_switch` moved `0x585b80 -> 0x58e860`); the routine is identical instruction for instruction.

Fix in this port (code edit in `src/mod_bindings_menu.lua`, see `build.py` `code_edits`), within the code-page rule:

* `NATIVE_CODE`/`native_ready`: each of the four natives is read through `read()` (ReadProcessMemory). Readable and
  equal: cast and remembered. Readable and different: refusal exactly as v2.3 (at the build check: the same
  pcall path, "unsupported", nothing changed). Unreadable: deferred, noted once ("Native code checked at first use
  (page not resident yet): consume").
* `native(name)`: right before every call of a not-yet-verified native it is read again; a native is never cast or
  called before its bytes matched. Bytes found different at that point refuse the build like the build check
  (`guard.stop`, borrowed slots go back via `shut_down`, `state.base = nil`, bindings inert).
* `consume` and `reset_list` are optional: while not resident the panel's key capture simply does not consume UI
  actions that frame, and the focus reset after filling a tab is skipped (one note each).
* `page_frame` first checks `build_rows` and `set_tab_labels` (`page_code_waiting`); while one is not resident the
  binding page is left exactly as the game drew it (nothing borrowed, nothing written). Gameplay input (`is_down`,
  `poll`, the sweep, the keyboard defaults) never depends on these pages — `state.build_rows` stays the readiness
  flag, as in v2.3.
* No retry timers keyed on error text; the first-frame build check now passes whenever the data checks and every
  resident prologue pass.

`tests/test_port_code_pages.lua` (Wine, real `VirtualProtect(PAGE_NOACCESS)` pages) checks all six cases: consume
not resident at the build check -> passes and defers; not called while unreadable (one note); verified once
readable; different bytes at first use -> refused without calling; page natives not resident -> page untouched;
resident wrong bytes at the build check -> refused as v2.3.

## What changed (build data)

* `mod_bindings_menu.lua`: SHA pins; `INPUT_OWNER 0x2e38250`, `MENU_SYSTEM 0x2e38170`, `UI_STATE 0x2e38160` (16/16
  RIP witnesses each, = MOM); `ACTION_LABELS 0x24bc8a0` (the 13x97 label table is byte-identical); natives
  `BUILD_ROWS 0x1693b90`, `SET_TAB_LABELS 0x162bee0`, `LIST_RESET 0x1695020`, `INPUT_CONSUME 0x1190e30` (+ its
  signature's call displacement); `MISSION_MODE 0x2ce1850`; `TAB_LABELS 0x2cc8bb0`; `MODS_TITLE_PTR 0x2ce3680` and the
  59 `LABEL_POOL` cache slots (each by emulating the game's id->slot dispatch leaf in both images; all 60 agree
  with `native-work/localization-cache-map.json`); header comment build number.
* `panel.lua`: `FONT 0x312d998`, `MATERIAL_PTR 0x3180c08`, `ATLAS 0x312e618` (font and atlas globals hold the same
  resource hashes in both captures). **New finding:** the menu system object grew by 8 bytes between `+0xd0` and
  `+0x160`: `CURSOR 1520 -> 1528` (menu + 0x5f8), `ROOT_A 352 -> 360`, `ROOT_B 648 -> 656` (7, 10 and 11 agreeing
  witnesses: the menu's own init/update code and the row hover test; `menu + 0xd0` and MOM's `+0xc8` unchanged).
  The installed CFFI copy still uses 1520/352/648, so its MORE MODS panel never sees the mouse cursor (keyboard and
  controller still work; reads only, no harm).
* `bingus_text.lua` (identical file to MOM's): `settings 0x2ce1508`, `index 705628 + 212`, `table 0x3180DE0` (MOM rows).
* Everything else is unchanged and witnessed: binding maps (`+0xa7ad0` live, `+0xa7b78` defaults, capacity 256,
  0x148-byte records, mappings at +8, 0x14 each, device nibble), action states (`+0x328`, 32-byte stride, 97 per
  group, f32 value/held at +4/+8), UI stack `0x429c` and binding screen type 26, binding screen at `menu + 0xd0`, tab
  bar at `+0x4e0` and its fields (`0xe068/0xe06c/0x2afc/0x2b0d/0xd48`), list fields (`0x1eb0`, `0x60d0`, `0x24cd8c`,
  `0x24cd98`, `0x24cd80`, viewport `+0x110`), row fields (`0x60b0` type, header type 4, `0x60b8` code, label widget
  `0x10a8` + `0x110`), header descriptor group 13, 12-byte descriptors, widget geometry (`+0x94 +0x9c +0x24 +0x64
  +0x8c +0x54`, visible bit 0x10), cursor widget fields (`+0x200` parent, `+0x26c` position), UI action 10 = select,
  mission record (`+8`, `+0x40`, modes 1-7), material owner `+0x18`, mapping enums (the game's device / input type /
  trigger name parsers align 1:1 with the same strings and numbers: Keyboard 3, Button 4, Press 0,
  RepeatInterval 8) and the six shipped keyboard-default mappings.

## Confidence

143 rows: **141 high, 2 medium, 0 low, 0 unmapped**.

Medium (no readable new code uses them; page `0x130d000` holding the binding screen's init and tab switch is
encrypted in the capture):

* `ROW_LIST_OFFSET 338344 (0x529a8)` — feeds a write. Indirect witnesses: the menu still allocates the binding
  screen with the same size `0x29f780` and constructs it the same way (+0x4e0, +0xe570, +0x44610), the input
  dispatch still reads the same screen fields `0x498f8` and `0x52588` (just below the list) and the tab bar; the
  list object itself is unchanged (its builder, setup, clear and reset are identical). Confirm with L5 before
  relying on the MODS tab.
* `SELECTED_TAB_OFFSET 8` — read only. Screen + 8 is the selected tab in the escape screen too (MOM, unchanged).

Not statically comparable: the last six instructions of `build_rows` (new page `0x1694000`, encrypted in the
capture; old: `[rdi+0x7b8]=0; scroll_reset; [list+0x24cd89]=0; ret`). L3 checks them once the page is resident.

## Memory writes (all of v2.3's, unchanged in kind) and their evidence

| # | Address / value | Evidence |
| --- | --- | --- |
| W1 | `u64 [game.dll+0x2ce3680]` (MODS title cache slot of id `0x781e104c`) := pointer to MBM's "MODS" buffer, only while it reads 0 and a binding page is open; back to 0 after | dispatch-leaf emulation (old leaf -> `0x3328420`, new -> one slot `0x2ce3680`); prior map agrees; MBM checks the page is committed+writable (VirtualQuery) first |
| W2 | `u64` at the 59 `LABEL_POOL` slots (`0x2ce2738`, `0x2ce3490`…`0x2ce36e8`) := text buffer pointers, only while 0; cleared on leaving | same, 59/59 high |
| W3 | `u32 [game.dll+0x24bc8a0 + 4*(97*group+action)]` for registered dormant actions := label id, restored to the original id after | RIP witnesses + build_rows loads the row label from this table (`lea r13, [rip+…]`); table byte-identical; 36/36 original ids read back |
| W4 | `u32 [S+0x4e0+0xd48*cur+0x2afc] := 3`, `u8 [S+0x4e0+0xd48*cur+0x2b0d] := 1` after `set_tab_labels` | tab bar rows (7 witnesses each, = MOM); S = `[menu+0xd0]` (allocation/store and dispatch sites) |
| W5 | `u32 [S+0x529a8+0x24cd98] := #layout`, then `build_rows(S+0x529a8, descriptors)` | descriptor count: 7 witnesses incl. the game's own tab switch doing exactly this; **list offset medium (L5)** |
| W6 | binding records in `[owner+0xa7ad0]` / `[owner+0xa7b78]` maps: count `+4` and mappings `+8..+0x147` (sweep, keyboard defaults) | lookup function identical (0x148 records, +8 mappings, 0x14 stride); parsers identical; live on 26088801 the installed copy wrote 6 records and read slot 1's mapping `43ffd004 7e000000…` |
| N1–N4 | calls: `set_tab_labels(bar, labels, n)`, `build_rows(list, rows)`, `reset_list(list, 3)`, `consume(owner, code, -1)` | each verified (ReadProcessMemory) before its first call; bodies identical to v2.3's (build_rows up to the encrypted tail) |

## Upstream tests (`out/TESTS.json`)

Windows LuaJIT under Wine (private prefix `work/wine-prefix`), `test_bingus_text` also in Linux LuaJIT. Fixtures that
copy build data were mapped like the sources (globals, cache slots, tab labels, SHA pins, menu cursor offsets) and the
v2.3 reference used by `test_idle_gate` got MAP.json's data edits.

* Pass on the port and on unmodified upstream: assignments, bingus_text (both LuaJITs), capture, extended,
  extended_store, idle_gate, keyboard_defaults, mods_tab, panel, poll, sweep.
* `test_idle_gate` needed one test-side adaptation for the port: it recognises "native input activated" by
  `type(state.build_rows) == 'cdata'`; the port's natives are Lua wrappers, so the test is told a function counts
  too (`PORT_TEST_ADAPTATIONS`). With that it passes its 3000-frame equivalence with v2.3.
* `test_api`, `test_ffi_names`, `test_ffi_names_hostile_first`, `test_ffi_names_mbm_first` page-fault in Wine on
  both the port and unmodified upstream (their hostile FFI harness): environment, not the port.
* `test_build.py` not run: it writes a release zip into the source tree.
* Port test `tests/test_port_code_pages.lua`: 6/6 OK.

## Read-only in-game checks (`live/mod_bindings_menu_readonly.lua`)

B = game.dll base. Run (a) at the title screen/ship, (b) with Options > Controls > keyboard bindings open (then
each tab incl. MODS), (c) on the controller page, (d) in a mission.

* **L0** page protection and prologue at `B+0x1693b90` (13 B `488bc45341564881ecd8000000`), `B+0x162bee0` (16 B
  `488954241053564883ec680f29742430`), `B+0x1695020` (16 B `40534883ec20488bd985d2743083ea01`), `B+0x1190e30` (20 B
  `40534883ec204c8bd14c8bca488bcae81cda3fff`): MATCH, or "not resident" (prot 0x1) before the game ran that code —
  at boot expect the consume page to be one of those.
* **L1** `B+0x2cc8bb0` 12 B = `51f4708d605c5ef1eb7f8400`; dormant labels at `B+0x24bc8a0+4*(97g+a)` (12:1 =
  `0x62ea38bf` …) unless borrowed on a binding page; `u64 [B+0x2ce3680]` = 0 off the binding pages, a pointer to
  "MODS" on them; pool slots `B+0x2ce2738`, `B+0x2ce3490` 0 unless borrowed.
* **L2** `I = u64 [B+0x2e38250]`; `[I+0xa7ad8]` = 256 and `[I+0xa7b80]` = 256; records with code `0xc0001` and
  `0xa0001` found in both maps (stride 0x148), count ≤ 16, first mapping's low nibble 3 for keyboard.
* **L3** (after a binding page was opened) 36 B at `B+0x1694000` =
  `488bcfc787b807000000000000e8ee17f8ffc68389cd240000488b5c24304883c4205fc3`.
* **L4** `U = u64 [B+0x2e38160]`; depth `[U+0x42b0]`, top `[U+0x429c+4*(depth-1)]` = 26 with a binding page on top.
* **L5** (binding page open) `S = u64 [[B+0x2e38170]+0xd0]`; `[S+8]` = selected tab = `[S+0x4e0+0xe06c]`; tab count
  `[S+0x4e0+0xe068]` 3 (4/5 with MBM's tabs); labels at `S+0x4e0+0xdfe8`. **List `L = S+0x529a8`**: row count
  `[L+0x24cd8c]` = the rows you see (1..97), descriptors `[L+0x24cd98]` = 49/26/14 on the native tabs (MBM's layout
  size on MODS), controller flag `[L+0x24cd80]` 0 keyboard / 1 controller; rows at `L+0x1eb0+0x60d0*k`: type
  `+0x60b0` (4 = section header), code `+0x60b8` (= group<<16|action), header label `+0x11b8`. Viewport `L+0x110` and
  header row `L+0x1eb0` visible (bit 0x10), opacity ≈ 1, scale 0.3–4 equal in x and y. This is the check that lifts
  ROW_LIST_OFFSET to high; do it before using the MODS tab.
* **L6** cursor `C = menu+0x5f8`: `[C+0x200]` = menu+0x168 or menu+0x290 while the mouse cursor is shown, `f32
  [C+0x26c]`, `[C+0x270]` follow the mouse; v2.3's `menu+0x5f0+0x200` is not a root pointer.
* **L7** `R = u64 [B+0x2ce1850]`: in a mission `[R+8]` ≠ 0 and `[R+0x40]` in 1..7; on the ship otherwise.
* **L8** `u64 [B+0x312d998]` / `[B+0x312e618]` = the body font / atlas hashes (`f27dd1c5ba2a6db5` / `4b939fc791b9ebd1`
  in English); `[[B+0x3180c08]+0x18]` = the font material hash.
* **L9** UI action states `I+0x328+32*a` for a = 1, 2, 5, 6, 10 react to up/down/select in menus.
* **L10** `ModBindingsMenu.ready()` true after the first frames; guard status running.
* The log should say `Native binding layout verified for current game build.` on the first frame (no "Waiting…"),
  possibly followed by `Native code checked at first use (page not resident yet): consume`.

## Not verified

* Anything only live: heap objects (binding screen, list, rows, input owner, records), the MODS/MORE MODS tabs in
  the real game, rendering, saving. The installed copy's live log covers the binding maps and records only.
* The EXE SHA-256 was taken as supplied (the game folder was not hashed).
* `ROW_LIST_OFFSET` and `SELECTED_TAB_OFFSET` (medium) and build_rows' tail until L5/L3 are run.
