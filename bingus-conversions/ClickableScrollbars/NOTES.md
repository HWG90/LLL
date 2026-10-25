# Clickable Scrollbars v2.15.1 (Megapack option ClickableScrollbars) — port to game build 26088801

Static, offline port, plain LuaJIT (the mod's own `ffi`/`bit`/`jit` code; no PORT51/compat51, no `require('cffi')`).
Nothing was installed; the game folder, `~/.config/hd2arsenal`, `<steam-library>` and `upstream-bingus/` were only
read, and the running game was not touched. Inputs: `native-work/evidence/` images (old `game-pre1020.dll` =
25480438, new `game-26088801.dll` + `.pdata`), the verified Mod Options Menu map (`native-work/mom-port/MAP.json`),
the global candidates and the pinned source.

## Source

`components.lock.json` pins v2.15.1. The pinned component `upstream-bingus/VanillaPlusMegapack/components/
ClickableScrollbars` matches every lock hash; the standalone checkout `upstream-bingus/ClickableScrollbars` (tag
v2.15.1, commit a69bc06) is byte-identical. The port uses the pinned component (`MAP.json` `source_check`).
The pack lists it in `ASSEMBLED` with entry `direct`: the option ships the plaintext entry from the component's
`scripts/entry.py` in the `<II len, 2>` envelope. The unmodified assembly reproduces both the lock's
`resource_sha256` (`C3BFB9CA…27AC`) and the resource inside the shipped v26 option archive.

## Files

| File | What |
| --- | --- |
| `MAP.json` | 87 rows: every build-specific constant (file, line, old, new, method, witnesses, evidence, confidence, feeds_write, the exact `replace` where it changed). |
| `analyze_cs_map.py`, `tools/csenv.py` | Regenerate `MAP.json` (`python3 -I analyze_cs_map.py`, ~2 min; imports `mom-port/tools` read-only). |
| `build.py` | Copies the pinned `src/` to `work/src`, applies the map (line-scoped, each edit must match once on its line), 4 comment edits and 5 code-page edits, assembles with the component's `scripts/entry.py`, refuses leftovers of old values and the loader-only APIs, packs, `loadstring`-checks in the Linux LuaJIT, writes `out/`. |
| `out/entry.lua`, `out/mod.lua.main` | Entry (139653 bytes, SHA-256 `4983DCD1…72B6D8`); resource `6A738660…40F189`. |
| `out/9ba626afa44a3aa3.patch_0` (+ empty `.stream`, `.gpu_resources`) | Only `mods/cowboybingus/clickable_scrollbars` (hash `9a4b654810fa934b`), SHA-256 `8F75342C…B4F5F9`. No shared megapack stub. |
| `out/build-receipt.json` | Hashes, all 34 edits, reproduction check, LuaJIT result. |
| `run_upstream_tests.py`, `out/TESTS.json` | The 13 upstream Lua suites under Wine (Windows LuaJIT, private prefix `work/wine-prefix`) on the port and on unmodified upstream. |
| `live/clickable_scrollbars_readonly.lua` | Read-only probe C1–C9 for the memory tool. |

Rebuild: `python3 -I analyze_cs_map.py && python3 -I build.py && python3 -I run_upstream_tests.py`
(`build.py` clears `out/`, so run the tests after it).

## What changed (build data)

| What | old | new | confidence |
| --- | --- | --- | --- |
| build pins (install.lua) | game `2E2C3B7C…`, exe `F5FEE03D…` | game `6D1D4D3B…1C08F`, exe `0ACC07DE…4EABE` | high |
| gate message | needs Steam build 25480438 | 26088801 | — |
| dispatch table global (locate, native) | `0x3326e68` | `0x2ce2040` | high (24/24 RIP uses) |
| UI state / menu system / input owner | `0x347ce28` / `0x347ce38` / `0x347cf18` | `0x2e38160` / `0x2e38170` / `0x2e38250` | high (24/24 each; live-verified per brief) |
| UI root (logged only) | `0x347cd90` | `0x2e380c8` | high (24/24) |
| GRID_SOLVER | `0x18d2b60` | `0x1753dc0` | high (window, migrate, 6/6 call sites; sig unchanged) |
| SCROLL_SET | `0x1794530` | `0x16157c0` | high (body identical; copy 1 of 2 in both builds; falls into MOM's scroll_reset at +0x40) |
| POSITION_SET | `0x14476a0` | `0x12df3b0` | high (= MOM set_position; identical) |
| ANIMATION_STOP | `0x1439d40` | `0x12d1a50` | high (identical; 12/12 call sites) |
| INPUT_CONSUME | `0x12fde90` | `0x1190e30` | high (identical; 12/12 call sites; = MBM port) |
| prologue signatures | SCROLL_SET, ANIMATION_STOP, INPUT_CONSUME differ only in a RIP displacement / call rel32 | new bytes from the new image | high |
| **controller kinds** (locate.lua 29/30/50/51/64/67/70) | Armory 224, loadout 229 | **226, 231** | high |
| **LOADOUT_GRID_OFFSET** | 864032 (`0xd2f20`) | **864096 (`0xd2f60`)** | high |

The kinds: all nine controller kinds registered in the `+0x166c` registry moved by +2 in the same order
(205,220,224,229,231,233,288,289,290 → 207,222,226,231,233,235,290,291,292). The Armory controller constructor
(old `0x1455c40` → new `0x12ed950`, similarity 0.998) is identical except this kind (`0xe0` → `0xe2`), its third
registry (`0x2df0` → `0x2e48`) and an unrelated +8 member move. With the old kinds the mod would never find the
Armory/loadout owner (no write, just "equipment grid not registered").

The loadout grid: 5 of 5 mapped witnesses moved `0xd2f20` → `0xd2f60` (the loadout controller grew by 0x40 ahead
of its grid; the same code moved `+0x2808/+0x2818` → `+0x2848/+0x2858`). Key witness old `0x8745b0` / new
`0x881a20`: when `[ui + 0x4294] == 14` the game takes `menu[+0xb0] + offset` and calls a grid routine beside
GRID_SOLVER. With the old offset the mod would have written 0x40 bytes before the real grid (its read bounds would
very likely refuse first, but this is exactly the write the map must get right).

Everything else is unchanged and witnessed (MAP.json): dispatch count `+0x166c`, rows `+0x1670` (16 bytes,
controller +0, kind +8); UI stack `+0x429c`/depth `+0x42b0`; screen ids 5 (Armory), 14 (loadout), 1 (escape), 26
(bindings) — no mapped comparison of a UI menu/stack field with an id changed; menu `+0xc8` escape screen, `+0xd0`
bindings screen, screen active byte `+0xc` (the menu system's per-screen input switch, strict window); every GRID
field (offset `0x7fde8`, rows, row_heights, row_items, selected, content, scroll, span, value, first, last, anchor,
items, columns, kind, row_base, row_stride, the animation flag/stop target) with 1–15 strong witnesses each (49
mapped grid functions); grid bar `+0x110` (17), thumb `+0x378` = bar + `0x268`; Career (`0x4dc08`, list `0x9b8` and
its +4/+8/+0x10/+0x20, track, thumb, thumb_height, enabled, padding 4.0); the options list (bar `0x330`, thumb
`0x598`, span `0xae0`, value `0xae8`, content `0x220`, scroll `0x228` = container y); settings list
`0x3fef20` = MOM OPTIONS_CONTENT `0x2def98` + panel `0x11ff88`; ScrollBar internals `+0x268/+0x7b0/+0x7b8` (the four
scrollbar routines are identical); widget fields +12/+16/+84/+100/+140/+148/+156 (the five widget transform
passes that write them are identical); UI_SELECT `0xa00000000` (25 mapped INPUT_CONSUME calls pass it unchanged).

## Code-page rule (code edits)

The mod already reads prologues with ReadProcessMemory, but refused the native route for the whole session when a
routine's page was not readable yet. Now (`memory.lua` `native_api`): readable-and-different still refuses
everything; unreadable signatures are kept in `api.pending_signatures`. `native.lua` `routines_ready` checks the
routines a route needs (grid: stop, scroll, solve; career: position; options/bindings: scroll, position; settings
input: consume) through the reader right before the first call; while one is still unreadable nothing is called
(`apply_native` raises `native routine not resident yet` before any call or write, `consume_select` returns false);
bytes that differ raise `unsupported native scroll routine` (route retired). `install.lua` `write_native` drops only
the gesture (no retirement) on the not-resident reason. With every page readable this reads nothing extra (frame
budget suite unchanged). In the capture all five routines sit on readable pages.

## Writes and calls (all need the whole chain resolved and bounds-checked in the same frame)

1. **Direct store** `f32 [grid + 0x92960]` = value × span (Armory/loadout grid route, `apply_native`), between
   SCROLL_SET and GRID_SOLVER. Evidence: 12 strong in-function witnesses (MAP.json, GRID.scroll) that `+0x92960` is the grid's scroll pixel
   offset (the game itself stores it, e.g. old `0x18d1af9` `movss [rcx+0x92960], xmm3`, and GRID_SOLVER reads it
   first thing); grid = controller + `0x7fde8` (Armory, 4 strong) or + `0xd2f60` (loadout, 5 witnesses, changed);
   controller from the kind-226/231 dispatch row. The old-value restore path (`scroll(bar, model.value)`) is the same.
2. `native_set` (exported, not called by the runtime; tests only): stores `[grid + 0x8c8]` (bar + 0x7b8 value) and
   `[grid + 0x92960]` — same evidence (ScrollBar `+0x7b8` value in the identical scrollbar routines).
3. Game routine calls (they change UI state): ANIMATION_STOP(grid + `0x92900`) when byte `[grid + 0x92902]` ≠ 0
   (4/4 witnesses: the game's own wheel path does the same `cmp byte [rcx+0x92902],0` / `add rcx,0x92900`);
   SCROLL_SET(bar, value) with bar = grid + `0x110` / list + `0x330`; POSITION_SET(widget, x|y) with the Career list
   (panel + `0x9b8`) or the list container (list + `0x220`); GRID_SOLVER(grid); INPUT_CONSUME(input owner,
   `0xa00000000`, -1). Function identity and argument shapes: identical bodies (GRID_SOLVER differs only inside its
   own code: a jump-table base and a `+0x5f0` → `+0x5f8` offset in another object), MOM/MBM agreement.

## Not verified / medium

* **OPTIONS_PAGES[26].list = 338344 (`0x529a8`), medium.** Every old use (bindings screen code, old
  `0x1475440`–`0x1475850`) maps to new `0x130d000`–`0x130dfff`, a page the capture holds encrypted (entropy 7.95
  bits; the game decrypts it on first use), so no direct witness. Unchanged neighbours in readable code: `[screen +
  0x498f8]`, `[screen + 0x52588]`, tab bar `+0x4e0`, the init's `+0x44608/+0x44610`; the list object's own code is
  identical; the Mod Bindings Menu port keeps 338344. The mod drives this list only after its bar reads visible
  (alpha > 0.95) and span/value/scroll pass its bounds. Live check C7 settles it.
* Heap layouts are proven only through the code that uses them; nothing ran in the game.
* The EXE SHA-256 is as given in the brief (game folder not hashed here).
* Old comments that state what was measured on 25480438 (native.lua "Page offsets were measured…", the
  25327279 fixture notes) are left as history.

## Read-only in-game checks (`live/clickable_scrollbars_readonly.lua`, or by hand)

B = game.dll base. Nothing writes.

* **C0** ClickableScrollbars.log after load: no "unsupported game build" (SHA gate passes); the status line shows
  `native …` instead of `unsupported native scroll routine`.
* **C1** (any time) prologues at B+`0x1753dc0`, `0x16157c0`, `0x12df3b0`, `0x12d1a50`, `0x1190e30` = the new
  signatures (24/24/24/24/20 bytes, in MAP.json); "NOT RESIDENT" is allowed before the screen was used.
* **C2** (Armory open) `D = u64 [B+0x2ce2040]`; `u32 [D+0x166c]` in 1..64; the u32 at `D+0x1670+16i+8` lists 226
  (Armory) — and 231 with the loadout picker open; never 224/229.
* **C3** `U = u64 [B+0x2e38160]`; depth `u32 [U+0x42b0]` 1..5; top `u32 [U+0x429c+4(depth-1)]` = 5 in the
  Armory, 14 in the loadout picker, 1 on Options, 26 on key bindings.
* **C4** (Armory, equipment grid) controller `A` from the kind-226 row; `G = A+0x7fde8`: `f32 [G+0x164]` ≈ 1
  (bar alpha), `f32 [G+0x8c0]` > 0 (span), `f32 [G+0x8c8]` in 0..1, `f32 [G+0x92960]` ≈ value × span, `u32
  [G+0xb9b4]` 1..8 columns, `u32 [G+0x92984]` = item count, first/last `[G+0x98040/44]` move when you scroll with
  the wheel. Career tab: panel `A+0x4dc08`, track alpha `f32 [panel+0x2fab8+0x54]` ≈ 1, list height
  `f32 [panel+0x9c8]` > 0. The page holding `G+0x92960` is committed read-write.
* **C5** (loadout picker) controller `L` from the kind-231 row; `G = L+0xd2f60` gives the same plausible shape as C4
  (alpha ≈ 1, value 0..1, scroll ≈ value × span, columns 1..8); `L+0xd2f20` does not.
* **C6** (Options, a settings page that scrolls) `M = u64 [B+0x2e38170]`, `S = u64 [M+0xc8]`, `u8 [S+0xc]` = 1;
  list `S+0x3fef20`: bar alpha `f32 [list+0x384]` ≈ 1, span `f32 [list+0xae0]` > 0, value `[list+0xae8]` 0..1,
  scroll `[list+0x228]` ≈ value × span (sign as the game keeps it).
* **C7** (key bindings page, list scrolled a bit) `S26 = u64 [M+0xd0]`, `u8 [S26+0xc]` = 1; list `S26+0x529a8`:
  same shape as C6. This is the check for the one medium row.
* **C8** `u64 [B+0x2e38250]` non-null in menus.  **C9** `u64 [B+0x2e380c8]` (UI root; only logged).

## Upstream tests

`out/TESTS.json`: the 13 suites the component's build runs, under Wine with the workspace Windows LuaJIT
(`runtime-modules/build/windows/LuaJIT/src/luajit.exe`, a GC64 build), on the port and on unmodified upstream.
Fixture copies of build data were mapped like the source (RVAs, globals, LOADOUT_OFFSET, kinds, the gate message;
the 25327279 capture's dispatch address and Armory kind byte); test_frame_budget's side-by-side reference (the
earlier v2.15.1 release entry) got MAP.json's line edits only, so its equivalence section checks that the port's
code-page edits change no gesture, write or counter when every routine is readable.

* 12 of 13 pass on the port, the same 12 as on unmodified upstream.
* `test_frame_budget.lua` fails on both, at the same assertion (line 535: "grid: a moving held frame allocated
  24.0 B interpreted, budget 16"): the component pins a non-GC64 LuaJIT (`msvcbuild nogc64`) and its per-frame
  allocation budgets assume it; the workspace build is GC64. Environment, not port.
* Diagnostic (not a pass criterion): with those moving-frame budgets x4, `test_frame_budget.lua` passes completely
  on both sides, including the idle/held/release counts, trace aborts and the frame-by-frame equivalence with the
  mapped reference.
