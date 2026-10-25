# GalacticMenuHotkey (Ship Station Hotkeys v1.9.1) — port to game build 26088801

Static, offline port as plain LuaJIT (the option's own upstream code, real `ffi`/`bit`/`jit`; no PORT51/compat51,
no `cffi`). Nothing was installed; the game folder, `~/.config/hd2arsenal`, `<steam-library>` (one log read) and
`upstream-bingus/` were only read; the running game was not touched.

## Source

`upstream-bingus/ShipStationHotkeys` at tag `v1.9.1` (HEAD `b041826`, clean). Every file in the lock's
`source_sha256` matches it byte for byte, and the pinned copy `VanillaPlusMegapack/components/GalacticMenuHotkey`
matches too (identical `src/`, same assembled entry). The standalone checkout was used (MAP.json `source`).
The pack ships this option `direct` / ASSEMBLED: `scripts/entry.py` makes one plaintext entry and that entry is
the resource (no bytecode), so the port is the same assembly of the edited sources.

The installed v26 copy logs "Super Destroyer detected." then "ShipStationHotkeys stopped: unsupported game build":
the galaxy-table world detection already works on 26088801; the stop is the SHA-256 build gate.

## Files

| File | What |
| --- | --- |
| `MAP.json` | 64 rows (58 high, 6 medium, 0 unmapped), each with file/line, old/new, method, re-checked witnesses (201 code/RIP/data witnesses, all pass), `feeds_write`, `feeds_call`, and the exact `replace` edits (29). |
| `make_map.py` | Regenerates MAP.json and re-verifies every witness against the two images (`python3 -I make_map.py`). |
| `build.py` | Copies upstream `src/ locales/ scripts/` to `work/`, applies MAP.json's edits + one comment edit + the code-page edit, assembles with upstream `scripts/entry.py`, packs `out/9ba626afa44a3aa3.patch_0` with only `mods/cowboybingus/galactic_menu_hotkey` (hash `9ee275c2bd559175`), checks loadstring in the Linux LuaJIT (GC64), writes `out/build-receipt.json`. |
| `out/entry.lua`, `out/mod.lua.main` | Entry (111935 bytes, SHA-256 `4FFF29B3…72DA6B`) and resource (`<II len,2>` + entry, `C1170744…09FB28`). |
| `out/9ba626afa44a3aa3.patch_0` (+ empty `.stream`, `.gpu_resources`) | Archive SHA-256 `05E35276…80074B`. |
| `run_upstream_tests.py`, `out/TESTS.json` | Upstream suites on the port and on unmodified upstream. |
| `live/galactic_menu_hotkey_readonly.lua` | Read-only probe for the game's memory tool (G0–G10 below). |
| `tools/` | Probes used to find the pairs (field scans, function sweeps, disp scans). |

Rebuild: `python3 -I make_map.py && python3 -I build.py && python3 -I run_upstream_tests.py`.

**Reproduction:** the unmodified assembly gives payload `8FA1F904…EA65A2` = the lock's `resource_sha256` = the
resource inside the shipped v26 option archive (checked by build.py, which refuses otherwise).

## What changed (build data only, plus the code-page rule)

| Value | 25480438 | 26088801 | Evidence |
| --- | --- | --- | --- |
| GAME / EXE SHA-256 | `2E2C3B7C…` / `F5FEE03D…` | `6D1D4D3B…` / `0ACC07DE…` | capture manifest / brief |
| ENTER_PRESENTER_RVA | 0x14c0350 | 0x135b4f0 | unique 20-byte entry window, same shape/strings/name table (see below) |
| START_ARCADE_RVA | 0x997800 | 0x9a9450 | entry window + bindiff; 366/366 instructions aligned |
| INSTANT_SEAT_RVA | 0x639830 | 0x642f30 | entry window + bindiff; 198/198 aligned; loads seater global |
| OPEN_BRIEFING_RVA | 0x661cf0 | 0x66b5d0 | identical body; loads UI state and deployment system |
| UI state / menu system / input owner | 0x347ce28 / 0x347ce38 / 0x347cf18 | 0x2e38160 / 0x2e38170 / 0x2e38250 | live-verified (brief) + RIP windows |
| mission record ptr | 0x33266a0 | 0x2ce1850 | RIP windows; MBM port map |
| arcade component / registry | 0x3326700 / 0x3326e68 | 0x2ce18b0 / 0x2ce2040 | RIP windows; registry fill function |
| player manager / entities / script API | 0x3326468 / 0x346bf98 / 0x3326308 | 0x2ce1618 / 0x2ce41b8 / 0x2ce14c8 | live-verified (brief) |
| deployment system / Hellpod manager / seater | 0x33265f0 / 0x3326428 / 0x3326d78 | 0x2ce17a0 / 0x2ce15d8 / 0x2ce1f38 | RIP windows; loaded by the briefing / instant-seat entries themselves |
| entity id map / records | +0xf22ec8 / +0xf32f18 | +0xf24990 / +0xf349e0 | brief (live) + mapped code (+0x1ac8) |
| registry list count / rows | +19512 / +19520 | +19704 / +19712 | registry fill registers type 67 into this list (`[rcx+0x4cf8]`, rows `(n+0x4d0)*16`) |
| loadout intro timer / phase | +2570632 / +2570636 | +2570696 / +2570700 | intro phase setter/step aligned; screen object 0x2739d0 -> 0x273a10 |
| instant-seat placement slots | [406]/[407]/[408], 409 u32 | [408]/[409]/[410], 411 u32 | instant seat entry reads placement +0x658.. -> +0x660.. |
| bingus_text M.GAME | 0x3326340, 705500+212, 0x37C5650 | 0x2ce1508, 705628+212, 0x3180DE0 | MOM MAP.json (same file, same SHA) |

Unchanged and verified (high): presenter ids 5/6/8/14/15 (PresenterManager name table identical), MenuScreenType
11 Loadout / 24 Hologram (screen name table; 26088801 inserts EosErrorPopup at 27, after them), presenter
manager at UI+0x4288 with current +0xc and depth +0x28, mission record +8/+0x40 and type 1..7, action-state
layout 808/32/97 and the seven (group, action) slots (identical 13x97 label table), the four prologue
signatures (bytes read at the new RVAs; the 13-byte briefing one stops before its RIP displacement), arcade
component map fields, pool stride 0x1470 and +5208, type 67, deployment system +32/+36/+72984, Hellpod manager
arrays and states 2/3/4, seater component layout and record +0, player-manager fields, avatar type hash, intro
phases 1/0 (identical timer table, phase 1 = 2.0 s), the galaxy-table resource id (live log on 26088801).

**ENTER_PRESENTER note.** The presenter subsystem was recompiled (presenter objects' internal fields moved), so no
masked window maps the old function. The new one is the only place the old first 20 bytes occur, at a function
start; it scans the same stack, logs the same "trying to reopen" string through the same name table, closes the
current presenter and tail-calls the open routine like the old one. New in 26088801: if `[manager+0x10] != 0` it
logs "change_menu(%s) ignored: a popup is active" and returns. That is a game-side guard: the mod re-reads the
current presenter after the call and logs it, so a refused open shows as `current=0` in the log.

**Code-page rule.** The mod already reads code through ReadProcessMemory (its own `read`), but upstream stops all
shortcuts when a prologue read fails. Edited so that a prologue whose page is not readable yet is checked right
before that function's first call and never called unchecked: until then its shortcut is skipped and logged
("native instant seat entry not resident yet; shortcut skipped."); a mismatch at that point stops the shortcuts
(as upstream), except the world-position function, which only turns the proximity check off (as upstream). The log
line "Checked at first use (code not resident yet): …" lists any deferred function. Resident functions are checked
and cast exactly as before (the tests' stubs and capture check still apply).

## Memory writes and native calls

* **Write (the only direct one):** `float [loadout + 0x2739c8] = 0` (upstream `ffi.cast('float *', screen +
  INTRO_TIMER_OFFSET)[0] = 0`), only when `[menu system + 0] == 11`, `screen = [menu system + 0xb0]`, the presenter
  manager's current presenter is 14 and `[screen + 0x2739cc] == 1`. Evidence: the factory case for type 11 (`dec
  edx`, jump table entry 10 in both builds) allocates 0x273a10 bytes and stores the screen at `[rsi+0xb0]`; the
  phase setter writes `[rdi+0x2739cc] = phase` and `[rdi+0x2739c8] = table[phase]` (old: 0x27398c/0x273988), and
  the intro step reloads the timer from the same table, which is identical (`-1, 2.0, 0.15, 0.35, 0.5, 1, 0.25,
  0`): phase 1 is the 2.0 s wait, so zeroing the timer while phase = 1 ends the wait, as on 25480438. Both fields
  are inside the object (end 0x273a10). Rows 23, 36, 37, 38 (`feeds_write`).
* **The mod's own buffer passed to the game:** the instant-seat request (80 bytes, `[0]=1`, `+72` -> placement)
  and the placement (`u32[411]`, `[408]` = slot pod). Evidence: the instant entry checks `byte [r8]`, loads
  `[r8+0x48]` and reads the seat collection / entrance hash / entrance index at +0x660/+0x664/+0x668 (old
  +0x658/+0x65c/+0x660) in the aligned body; `set_entering` then stores the collection at seater record +0.
* **Game functions called** (they write game state themselves): presenter open (manager = UI+0x4288, id 15/5/6/8),
  arcade start (registry type-67 system, nil, arcade entity, avatar entity), instant seat (nil, avatar seater
  entity, request), briefing entry (nil, 0). Argument sources are `feeds_call` rows, all high.

## Not verified statically (medium rows)

* `UNIT_POSITION_PREFIX` / table slot +136: the script API's function table is filled at run time; the slot is
  used alike in both builds and the mod checks the prologue at run time (failure only disables the Stratagem
  Hero proximity check). Live check G6.
* Arcade component count +24 == 1 and capacity == 128: no code witness for +24 (the accessors are byte-identical);
  a wrong value only refuses the arcade shortcut. Live check G5.
* Seater record byte +48 (transition): no direct witness; refusal check only. Live check G8.
* Entity index bound 262144: a read guard, not code-derived.
* Labels 0x2716885e (Ship Management) and 0xe89a91ef (Hellpod Deployment): game string data, not in game.dll in
  either build; cosmetic (Mod Bindings Menu row text).
* Behaviour in the real game (the shortcuts, the briefing-intro skip and the Hellpod seat) — nothing was run.

## Upstream tests (out/TESTS.json)

Windows LuaJIT under Wine (private prefix `work/wine-prefix`), the six suites upstream's build runs: test_hotkey,
test_binding_paths, test_bingus_text (also Linux LuaJIT), test_ffi_names sdk-first / mod-first / hostile-first:
all pass on the port and on unmodified upstream. Fixture copies of the build data (globals, RVAs, intro offsets,
placement slots, registry offsets, entity offsets, SHA pins) were mapped like the source, in one pass. Extra:
test_hotkey with `HD2_GAME_CAPTURE` = the captured 26088801 game.dll passes on the port (its own check of the four
prologues at the ported RVAs). The deferred-check path is not exercised by these suites (they stub the natives).
upstream's second pass in the game's lua51.dll was not run (the game runs LuaJIT now).

## Read-only in-game checks (`live/galactic_menu_hotkey_readonly.lua`)

B = game.dll base. Nothing writes. Run aboard the ship unless noted.

* **G0** 16 bytes at B+0x135b4f0 = `48895c24084889742410574883ec208b`, B+0x9a9450 = `488bc448895010488948085355574883`,
  B+0x642f30 = `48895c24204889542410565741544155`, 13 at B+0x66b5d0 = `48894c2408574883ec404c8b0d`. "NOT RESIDENT"
  is allowed (then the log shows "Checked at first use").
* **G1** `U = [B+0x2e38160]`; idle: `u32 [U+0x4294]` (current) = 0, `[U+0x42b0]` (depth) = 0, `[U+0x4298]` (popup)
  = 0; with the galactic map open current = 15; Armory 5; Loadout/briefing 14.
* **G2** `[B+0x2ce1850]` -> `+8`, `+0x40`: aboard not (flag != 0 and type 1..7); in a mission it is.
* **G3** `S = [B+0x2e38170]`: `u32 [S]` = 11 while the Hellpod briefing (Loadout) shows; `L = [S+0xb0]`:
  `u32 [L+0x2739cc]` = 1 during the intro and `f32 [L+0x2739c8]` counts down from 2.0, then phase 0 / timer -1.0.
  The page of `L+0x2739c8` is PAGE_READWRITE, MEM_COMMIT, MEM_PRIVATE. (This is the write target.)
* **G4** `[B+0x2ce1618]`: `+0x84`, `+0x88` in 1..4, `[+0xe8]` byte +20 bit 0 set, `+0x3a8` != 0x7fff;
  `hashmap(N+0xf24990, ref)` gives an index; record `N+0xf349e0+24*i` starts `97fa4d294d331c4d`, id and unit != 0.
* **G5** `[B+0x2ce18b0]`: count +24 = 1, capacity +56 = 128, empty +60 = 0, `[pool+5208]` = 0 when idle (your
  avatar id while you play). `[B+0x2ce2040]`: exactly one row with type 67 in `+19712 + 16*i` for i < `[+19704]`.
* **G6** `[[B+0x2ce14c8]+0x18]+0x88` -> 6 bytes `40534883ec20`.
* **G7** `[B+0x2ce17a0]` +32 = +36 = 1 (solo); +72984 = slot pod id; Hellpod manager `[B+0x2ce15d8]`: count +8 in
  1..4; after picking a mission the pod with id = slot pod shows mode 2, state/target 3/3 when open, 4 occupied.
* **G8** seater `[B+0x2ce1f38]`: `hashmap(SC+32, avatar id)` -> index, entity id = avatar id; record +0 = 0 and
  byte +48 = 0 standing, record +0 = slot pod once seated.
* **G9** `[B+0x2e38250]` state bytes for (12,1) (12,0) (10,1) (10,4) (10,8) (10,14) (10,9): 0; holding Tab sets the
  first on that frame.
* **G10** language code via `[B+0x2ce1508] + 705628 + 212` -> `[B+0x3180de0 + 8n] + 8` -> `us`.

With the port loaded, `GalacticMenuHotkey.log` should show "Super Destroyer detected." then "Native ship menu
presenters ready for current game build." (plus possibly "Checked at first use …").

## Installing (not done)

The archive and its two empty companions replace the option's `9ba626afa44a3aa3.patch_0` content only for this
option's resource; the pack's shared stub (`mods/cowboybingus/vanilla_plus_megapack`) is deliberately not in it.
`work/wine-prefix` (~380 MB) and `work/luajit.exe` exist only for the tests; delete freely.
