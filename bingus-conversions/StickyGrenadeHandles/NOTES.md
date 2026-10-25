# Sticky Grenade Handles v1.0.1: port to Steam build 26088801 (plain LuaJIT)

This is the Vanilla Plus Megapack option `mods/cowboybingus/sticky_grenade_handles`. It is built from the upstream
LuaJIT source `upstream-bingus/StickyGrenadeHandles` at tag v1.0.1. Every `components.lock.json` source_sha256
matches that checkout, and it is identical to the pack's pinned copy. Only build data changed: no PORT51/compat51
adapter and no cffi. It uses the real `ffi`/`bit` of the embedded Bingus Shared Runtime.

## Recipe
The pack builds this option as BUILD_ASSEMBLED with entry `direct`. It calls the component's own `scripts/build.py`
`assemble()` and wraps the plaintext declaration-bearing entry in the type-2 envelope. No bytecode is involved, so
the shipped resource is already GC64-loadable.

`build.py` checks that the unmodified assembly reproduces two things byte for byte:
- the lock `resource_sha256` 5423691D…;
- resource `5fcde649e6a27173` in the shipped v26 option archive.

The port archive `out/9ba626afa44a3aa3.patch_0` holds only this resource. The shared megapack stub is not included.

## Map (MAP.json, from `tools/build_map.py`): 18 rows, all high confidence, 0 witness failures
These rows are recomputed from the binaries on every run.

| Row | Old | New | Evidence |
|---|---|---|---|
| EXE / GAME pins | F5FEE03D… / 2E2C3B7C… | 0ACC07DE… / 6D1D4D3B… | SHA-256 of the installed files |
| `settings_rva` (entities) | 0x346BF98 | 0x2CE41B8 | ThrowableComponent getter old 0x50CD90 / new 0x515370: identical 41-instruction function; its rip load targets these; brief live-verified |
| `throwable_table` | 0xF12C90 | 0xF14758 | the same getter's `mov r10,[rax+disp]`; field-f12c90.json; neighbour getter +0xF12C98→+0xF14760 |
| `throwable_slots` / `records` / `size` | 92 / 1472 / 360 | unchanged | getter: `imul 0x5c`, `cmp r9d,0x5c`, `add 0x5c0`, `imul 0x168`, slot `shl 4`, index at slot+8 |
| `STICKY` +0x54 (u8) | | unchanged | 3 of 37 getter callers test `byte [rax+0x54]` right after the call, in both builds |
| `STICKY_MATERIAL` +0x164 | | unchanged | the one caller (old 0x6C7DE0 / new 0x6D2530) that keeps the record in r13 and reads `dword [r13+0x164]` |
| `library_rva` (exe) | 0x27C5CF0 | 0x286D1D8 | 12 old rip references migrated by unmasked instruction windows; all decode to 0x286D1D8 |
| `library_vtable_rva` (exe) | 0x148BA78 | 0x1521A98 | 7 vtable-store windows, all agree; old RTTI decoded as `.?AVhknpMaterialLibrary@@` |
| Material layout (80-byte entry, name +0, tag +0x48; array +0x48/+0x50/+0x54) | | unchanged | exe lookup `lea rcx,[rax+rax*4]; shl rcx,4; add rcx,[rbx+0x48]` at old 0x77FD6B / new 0x80700B |
| LDLD header (24, 'LDLD') | | unchanged | see below |
| Thin hashes, grenade hashes | | unchanged | data identities, found live (below) |
| Comments / message text | 25480438, getter 0x50CD90 | 26088801, 0x515370 | text only |

The contact-poster comment (0x78BFC0) is left as written. It is a comment and nothing uses it.

The new image's RTTI for the vtable can't be checked statically: its .rdata at the COL is not plaintext in the
capture. Live check S4 covers it.

### LDLD header and the Bounce finding
The mod checks only header +0 (`'LDLD'`) and +4 (`== 1`), and reads the size at +12. It never reads +16..+23. Those
are the bytes Better Stratagem Bounce found varying per session in this build (uninitialized padding), so this
check is unaffected.

## Writes (the only one)
The mod makes one 4-byte store per session: `le32(0xC4692706)` (the "throwable" tag) into the userData of the
`sticky_grenade_handle` hknpMaterial. The address is `[exe+0x286D1D8]+0x48 → entries`, plus `handle*80 + 0x48`. It
uses `api.write` from bingus_write.lua, which writes only committed private read-write memory after one protection
query, then reads back.

Preconditions that must all hold first:
- the library vtable equals exe+0x1521A98;
- 0 < count ≤ 1024;
- exactly one material named `sticky_grenade_handle` (tag 0x9A056E1C) and one named `throwable` (tag 0xC4692706);
- both grenades are found in the ThrowableComponent table, with sticky = 1 and material = 0xC4692706.

Evidence:
- The address math is the exe's own lookup (above).
- The tag field and value were verified live: batch113 read-only, then batch273 production `attempt()` apply,
  verify and restore of the complete 80-byte entry (`megapack-validation-state.json`).
- No code memory is written.

## Current status line in the game log
"Waiting for the game: the throwable settings are not loaded yet." followed by "applied (material 66 tagged
throwable …), after 2.1 s." is the designed path, not a failure. At load the entity settings are not there yet, so
the self-removing update hook retries each frame. About 2 s later, at the splash screen, it applies once and removes
itself. Material index 66 is this session's handle material.

That log came from the installed PORT51 copy carrying the same values, so the values are already proven in game.
What remains unverified is gameplay: a thrown Thermite or stun grenade sticking when its handle hits first.

## Not verified / limits
- Gameplay throw acceptance is pending.
- The new-image RTTI is live-only (S4).
- This port itself, the plain-LuaJIT entry, has not been loaded in the game. Its logic is byte-identical to upstream
  apart from the 11 listed lines (see `out/entry.diff`).

## Read-only in-game checks (`live/sticky_readonly.lua`)
Run at the main menu or on the ship, after the splash screen:
- **S1:** `[game+0x2CE41B8]` is non-null, and `+0xF14758` is the table pointer (non-null). The old field +0xF12C90
  should hold something else.
- **S2:** the 24 bytes at table−24: +0 = 0x444C444C, +4 = 1, size at +12 ≥ 1472 + n·360. Bytes +16..+23 are shown
  but are not checked.
- **S3:** both grenades are found within 92 slots, with the record in bounds, sticky +0x54 = 1 and material
  +0x164 = 0xC4692706.
- **S4:** `[exe+0x286D1D8]` is non-null, and its vtable − exe = 0x1521A98. vtable[−1] → COL: the signature should be
  1 and the type name `.?AVhknpMaterialLibrary@@`.
- **S5:** the entry count is between 1 and 1024. Two materials print:
  - `throwable` with tag 0xC4692706;
  - `sticky_grenade_handle` with tag 0x9A056E1C (vanilla), or 0xC4692706 once the mod has applied. The index
    should match the log (66 last session).
- **S6:** the write target page should show protect 0x4 (PAGE_READWRITE), state 0x1000 (MEM_COMMIT), type
  0x20000 (MEM_PRIVATE).
- **S7:** getter page residency, informational only; the probe never calls anything.

## Tests (`python3 -I -B build.py --tests`; Windows LuaJIT under Wine, same bcrypt shim as hdh-port, both copies alike)
| Test | Port | Unmodified upstream |
|---|---|---|
| `tests/test_mod.lua` (14 tests) | PASS | PASS |
| `tests/compile_entry.lua` | PASS | PASS |
| `tests/test_entry.lua` | PASS | PASS |

One port test fixture line quotes the refusal message, whose build number changed. It gets the same text change
(`test_fixture_replacements` in the receipt). `tests/game_lua.py` was not run: it is Windows-only and uses the old
lua51.dll.

The Linux GC64 LuaJIT `loadstring` compile passes (FR2 flag set). The Linux smoke run stops at the runtime's kernel32
load before installing anything, and hooks nothing.

## Files
- `MAP.json`
- `tools/build_map.py`
- `evidence/throwable-getter.json`
- `build.py`
- `out/` (entry.lua, mod.lua.main, 9ba626afa44a3aa3.patch_0 and companions, entry.diff, build-receipt.json,
  TESTS.json)
- `live/sticky_readonly.lua`
