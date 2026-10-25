# Better Stratagem Bounce — Vanilla Plus Megapack option, port to Steam build 26088801

Source: `upstream-bingus/BetterStratagemBounce` at git tag v15.4.1 (lock revision `archive-v15.4.1`). Every file in
the lock's `source_sha256` matches it; the pack's pinned copy is identical. Port revision `archive-v15.4.1-26088801`.
Plain LuaJIT (real `ffi`/`bit`), no PORT51/compat51/cffi.

## Status
- Built and checked offline. **Not yet run in game.**
- MAP.json: 14 rows, all high confidence, 0 witness-check failures; 11 changed (10 values + 1 layout edit), 3 unchanged-but-witnessed.
- One edit is not a pure value change. It is flagged in MAP.json `non_data_edits`, row `patch.header_tail`; see below.

## What the mod does at startup (and why the installed copy logs a failure)
`src/archive_loader.lua` installs an `update` hook when the resource loads. On the **first** `update()` it does the following, once only:
1. creates the Windows adapter;
2. checks the SHA-256 of helldivers2.exe and game.dll against the pins;
3. calls `patch.apply` once, which reads the whole settings buffer and the StratagemInfo table, validates the full layout, clears bit 0x02 in the owned records, and verifies the buffer.

There is no retry. The result goes to `_G.BetterStratagemBounce.status`, to the console, and to `BetterStratagemBounce.log` (through `CowboyBingusModLoader.open_log`). The hook then unhooks itself if it is still the outermost one.

The installed copy is `~/.config/hd2arsenal/mods/Better-Stratagem-Bounce-CFFI-26088801`, built by `port-tools/build_bounce_archive.py`. Instead of upstream's header test it compares all 24 bytes of every group header with one capture (`CURRENT_HEADERS`). In the 2026-10-24 23:31 session it logged `better_stratagem_bounce:913: Unexpected settings header` and wrote nothing. That is a failed first-frame apply: the session's header bytes differed from the capture. Upstream's own clause (`u32 +16 == 1 and u32 +20 == 0`) would refuse too, because groups 10 and 11 hold `01 d2 62 6e 4c 5b 02 3a` and `01 5d 00 00 00 00 00 00` there.

## The non-data edit: header bytes +16..+23 are no longer checked (row `patch.header_tail`)
- **Code:** the game's own parser for this buffer is the same instruction for instruction in both builds: old table builder 0x11F2080 with fragment 0x11F2127; new 0x10838A0 with fragment 0x1083947. It reads only four header fields:
  - +0 `'LDLD'`
  - +4 version 1
  - +8 type hash, looked up in the resource type table
  - +0xC size

  It then passes +0x18 to the payload fix-up (0xAAEDD0 / 0xACABC0). It never reads +0x10..+0x17.
- **Data:** the read-only capture of this build has non-zero bytes there in groups 10 and 11. In the other ten groups, and in all twelve, the low byte at +16 is 0x01.
- **Log:** the installed exact-bytes check failed in a later session, so these bytes are not stable across sessions. Live check B3 confirms this directly.
- **Edit:** the assert keeps magic, version 1 and type 0x30EB6399. The `+16 == 1 and +20 == 0` clause is removed and a comment takes its line, so the line count is unchanged. Every other check stays:
  - group count, every group size, walk end == data_size;
  - each record's kind, uniqueness, and table-pointer identity;
  - record total, owned total;
  - pre-write snapshot recheck and full-buffer post-write verification.
- **Offline proof (out/build-receipt.json `capture_replay`):**
  - With every value replaced but upstream's clause kept, the planner refuses the capture with `Unexpected settings header`.
  - The port planner applies 105 bit clears and nothing else, and restore returns the exact capture.
  - With arbitrary bytes at +16..+23 in all 12 groups it still plans the same 105.
  - A foreign table identity is refused with nothing written.

## Value changes (all high; full witnesses in MAP.json)
| row | old | new | key evidence |
|---|---|---|---|
| archive.EXE_SHA / GAME_DLL_SHA | 25480438 pins | `0ACC07DE…` / `6D1D4D3B…` | SHA-256 of installed files |
| patch.buffer_rva | 0x348E8F8 | 0x2E4A228 | 8 paired RIP witnesses (builder 0x11F20E7→0x1083907, unload, 4 reload functions), live read |
| patch.table_rva | 0x37CB600 | 0x31870E0 | 4 paired witnesses incl. `[base+rax*8+table]` → `test [rax+0x170],2`; window vote 126/126 |
| patch.table_bytes | 150*8 | 154*8 | the game's own memset of the table: imm 0x4B0→0x4D0 (builder 0x11F20FE→0x108391E, unload 0x11F22B1→0x1083AD1) |
| patch.data_size | 80280 | 82384 | capture walk ends exactly at the end (12 groups) |
| patch.groups | 11 | 12 | u32 at buffer+0 |
| patch.records | 149 | 153 | capture walk |
| patch.owned_records | 103 | 105 | 103 + kinds 28 and 66 (new in this build) |
| patch.vanilla_flags | 149 entries | 153 entries | captured +0x170 flags. All 149 old kinds, migrated by `stratagem-enum-migration.json`, carry exactly their old flag, so the capture is vanilla. New kinds 28/50/66/145 have 2/0/2/0 |

Unchanged, witnessed:
- `record_size` 400: `imul rdx,rax,0x190`, with kind at record+0 → `table[kind]`.
- Group layout: count at +0, groups from +4, root at +24, items at `[root]`, count at `[root+8]`.
- `flag_offset` 0x170 / bit 0x02: table-indexed `test byte [reg+0x170],2` at old 0x6A4025 / 0x6A1426, new 0x6AE255 / 0x6AB646.

## Writes (the only ones; no code is touched)
1. **`write()` → `api.write_batch`:** one byte per owned record, 105 in all. The byte is at `[game+0x2E4A228] + record + 0x170`. Its new value is the current byte with 0x02 cleared; other bits keep their current values, and an already-clear bit is never written. There is one protection query for the whole 82384-byte buffer, and only committed private read-write memory is accepted. Each record's identity (kind at +0 and `table[kind]` == record) is checked first, as are the snapshot and the buffer pointer. The whole buffer is verified afterwards. Evidence: rows `patch.buffer_rva`, `table_rva`, `data_size`, `record_size`, `group_layout`, `flag_offset`, `vanilla_flags`, `owned_records`.
2. **`patch.restore` and the partial-write recovery inside `patch.apply`:** sets 0x02 again in the bytes this mod cleared, only while still clear and while the record still holds the same kind.

## Live read-only checks (`live/bounce_readonly.lua`)
Run on the ship. If possible, run once before the option applies and once after it reports `navigation_settings_ready: 105 flags`. Run in at least two game sessions. An offline run against the capture printed exactly the "expected" values below.

| line | what it reads | expected |
|---|---|---|
| B0 | `_G.BetterStratagemBounce` | if visible: revision `archive-v15.4.1-26088801`, active true, status `navigation_settings_ready: 105 flags; executable code unchanged` |
| B1 | `[game+0x2E4A228]` | a heap pointer; region protect 0x4, state 0x1000, type 0x20000 |
| B3 | u32 at buffer | 12 |
| B3 | each group | magic/version/type ok = true; sizes 7180, 1160, 5836, 5204, 1092, 19128, 7016, 3808, 19308, 4860, 1080, 6420; records 13, 2, 11, 9, 2, 36, 13, 7, 36, 9, 2, 13 |
| B3 | walk end | 82384, records 153 |
| B3 | header bytes | the 24 bytes of each group, printed every session |
| B2 | `[game+0x31870E0]`, 154 slots | identity 153, outside 0, slot 0 = 0 |
| B4 | owned bit 0x02 | 105 of 105 before apply, 0 of 105 after; other-bit differences 0 |

B3 tests the finding: groups 10 and 11 should show different tail bytes from one session to the next (or at least from the capture), while every other field stays identical. If B3 shows a different size or record count, `data_size` / `groups` changed and the mod will (correctly) refuse.

## Build and tests
- `python3 -I -B build.py [--tests]`; `tools/build_map.py` rebuilds MAP.json.
- **Reproduction:** the unmodified wrapper, compiled with a private non-GC64 build of the vendored LuaJIT (`work/luajit-fr1`, never shipped), gives the lock's resource_sha256 `C0D19AB4…`. Its pack `discoverable_resource()` is byte for byte resource 19170ca4b0725ff0 in the shipped v26 option archive.
- **Shipped resource:** keeps the pack shape: `-- HD2-Addon: mods/cowboybingus/better_stratagem_bounce` followed by `loadstring("<escaped>")`. The payload is the plaintext port wrapper, 171305 bytes in the envelope. `out/9ba626afa44a3aa3.patch_0` holds only this resource.
- **Diff:** the wrapper differs from upstream on 17 lines (`out/wrapper.diff`): the replaced values, the header clause, and the install_loader pins and revision.
- **GC64 check:** compiles with `loadstring` in the GC64 LuaJIT (FR2 flag set). Smoke run: the entry hooks `update`; its first update fails inside its own pcall on this Linux host (no kernel32), with active false and update returns preserved.
- **Upstream tests (Windows LuaJIT under Wine), port and unmodified upstream:**

  | test | port | upstream |
  |---|---|---|
  | `tests/test_archive.lua` | 14 PASS | 14 PASS |
  | `tests/test_windows_interop.lua`, both orders, Hellpod Steering Unlocked src as peer | 15 PASS | 15 PASS |

  - **test_archive shim:** test_archive runs with a hash-cache prelude because Wine's bcrypt page-faults without it, for both copies (the hdh-port finding). The interop test passes without the prelude.
  - **Fixture edits:** the port's run gets this build's data in the test fixture. These are 10 counted edits (`out/TESTS.json` `fixture_value_changes`): group sizes and counts from the capture, 153/105/154*8, and the pinned call counts `pointer = 166, distance = 12` (records + groups + 1, groups).
  - **Intermittent failure:** one earlier upstream run failed once on the JIT trace-abort count ("1 aborted recordings in the loader"). That is a JIT-timing check unrelated to build data; the rerun passed.
- **Not run:** `tests/test_package.py` and `scripts/test_arsenal_archive.cjs` (release zip / Arsenal import).

## Not carried from the installed CFFI package
That package added three things, none of which is carried here:
- `CURRENT_HEADERS`, the exact-bytes header check that now fails;
- `patch.inspect`;
- the PORT51 adapter.

## Files
`MAP.json`, `build.py`, `NOTES.md`, `live/bounce_readonly.lua`, `tools/build_map.py` (plus `lib.py` and `align.py`, copied from the RBF port), `evidence/flag-crosscheck.json`, and `out/`: `9ba626afa44a3aa3.patch_0` with its `.stream` and `.gpu_resources`, `19170ca4b0725ff0.lua.main`, `option_entry.lua`, `wrapper.lua`, `wrapper.diff`, `build-receipt.json`, `TESTS.json`.
