# Arc Thrower Revamped v1.7.1 → Steam build 26088801 (offline port)

Source: `upstream-bingus/VanillaPlusMegapack/components/ArcThrowerRevamped`, the pinned Megapack copy. Every file
matches the lock's `source_sha256`, and `src/`, `tests/` and `scripts/entry.py` are identical to
`upstream-bingus/ArcThrowerRevamped` at git tag `v1.7.1` (clean). Lock revision `v1.7.1`, module
`mods/cowboybingus/arc_thrower_auto`, resource `eafc48b0c362fb8a`.

Old build 25480438, new build 26088801 (game.dll `6D1D4D3B…C08F`, exe `0ACC07DE…EABE`, both re-hashed read-only).
Nothing here touched the network, the game folder, `~/.config/hd2arsenal`, `<steam-library>` (read only), the upstream
checkouts, or the running game. Nothing was installed.

## Deliverables

| Path | What |
|---|---|
| `MAP.json` | 29 rows: every build-specific site in `megapack-native-inventory.json` plus every struct field the code reads or writes (file, line, old, new, method, re-disassembled witnesses, rejected witnesses, confidence, `feeds_write`, `role`, live check). It also lists the two writes. `witness_check_failures` is empty. |
| `build.py` | `python3 -I -B build.py [--tests]`. Copies the pinned source to `work/upstream` (unmodified) and `work/port`, applies the map, assembles exactly as the pack does, archives, and compiles/runs the entry in GC64 LuaJIT. |
| `out/arc_thrower_auto.lua` | The port entry (plaintext, with the `-- HD2-Addon: mods/cowboybingus/arc_thrower_auto` declaration). sha256 `787c207e1d3ea946aa2792e6e7b09923e696b0a5d57bcd86cf73777a12e53a14`. |
| `out/9ba626afa44a3aa3.patch_0` (+ empty `.stream` / `.gpu_resources`) | sha256 `e0bd0901…1a3f`. Holds **only** `mods/cowboybingus/arc_thrower_auto` (`eafc48b0c362fb8a`, type `a14e8dfa2cd117e2`, `<II len,2>` envelope). It does not include the shared stub `79e4f54aa542ec98`. Built with `BingusSharedLoader/scripts/archive.py make_archive` and round-tripped. |
| `out/arc_thrower_auto.lua.main` | The resource payload (envelope + entry). |
| `out/entry.diff` | Port entry vs the unmodified assembly (23 lines: 16 data/text lines and 7 code-patch lines). |
| `out/build-receipt.json`, `out/TESTS.json` | Hashes, every edit, the LuaJIT check output, and the test results. |
| `tools/` | Read-only analysis: `lib.py`/`align.py`/`palign.py`/`show_pair.py`/`ctx.py`/`field_scan.py`/`imm_scan.py` (from hdh-port), `rawdis.py`, `map_globals.py`, `map_fields.py`, `q.py`, and `build_map.py`, which writes MAP.json and re-asserts every witness. `mock_llm_probe.lua` runs the live probe against mocked memory offline. |
| `evidence/` | `globals.json`, `old-global-xrefs.json`, `field-pairs.json`, plus aligned listings of the charge update (`listing-charge-update-73c8f0.txt`), the trigger update (`listing-trigger-update-7406a0.txt`) and the fire-mode setter (`listing-fire-mode-setter-755f90.txt`). |
| `live/arc_thrower_auto_readonly.lua` | Read-only live probe for checks L1–L8. |

Rebuild: `cd tools && python3 -I -B map_globals.py && python3 -I -B map_fields.py 150 && python3 -I -B build_map.py`,
then `cd .. && python3 -I -B build.py --tests`. `work/wine-prefix` (~380 MB) is a private Wine prefix used only by the tests.

## Packaging (GC64)

- The pack treats this option as ASSEMBLED: `scripts/entry.py entry_text(root)` produces one plaintext entry, and the resource is `struct.pack('<II', len, 2) + entry`. No bytecode is involved, so this option needs no plaintext substitution.
- The unmodified assembly equals the lock `resource_sha256` (`C100E493…6753`) **and** the resource inside the shipped v26 option archive byte for byte. The build checks both every run.
- No PORT51/compat51 adapter, no `cffi`. The code uses `ffi`, `bit` and `jit` as upstream does. The build refuses any of those strings and any remaining old build value.
- Linux LuaJIT 2.1 GC64 (`string.dump` flags 8 = FR2):
  - `loadstring` compiles the entry.
  - Running it reaches the build gate. bingus_memory's first Windows library load fails inside the gate's `pcall`, and the addon logs `Disabled: …; the addon does nothing this session.` and returns, which is what happens on any unsupported host.

## What changed

**Build data** (16 entry lines):

| MAP row | Site (src line) | Old | New | Role |
|---|---|---|---|---|
| `gate.EXE_SHA256`, `gate.GAME_SHA256` | 159, 160 | `F5FEE03D…`, `2E2C3B7C…` | `0ACC07DE…`, `6D1D4D3B…` | gate |
| `atr.CHARGE_MANAGER` | 26 | 0x3326c20 | **0x2ce1de8** | address of the charging-flag write |
| `atr.TRIGGER_MANAGER` | 27 | 0x3326660 | **0x2ce1810** | selects which weapon is armed |
| `atr.FIRE_MODE_SETTER` | 28 | 0x755f90 | **0x761700** | gate (signature read only) |
| `atr.MISSION_RECORD` | 49 | 0x33266a0 | **0x2ce1850** | timing |
| `atr.player_manager` | 352 | 0x3326468 | **0x2ce1618** | identity |
| `atr.entities` | 352 | 0x346bf98 | **0x2ce41b8** | identity |
| `atr.avatar_manager` | 352, 407 | 0x3326d20 | **0x2ce1ee0** | Fire input address |
| `atr.entity_unit_lookup` | 361 | +0xf22ec8 | **+0xf24990** | identity |
| `atr.entity_records` | 363 | +0xf32f18 | **+0xf349e0** | identity |
| `atr.weapon_holder_manager` | 461 | 0x3326dc0 | **0x2ce1f88** | identity |
| `text.revision`, `text.build_number` | 13, 23, 153, 170, 1195 | `v1.7.1`, 25480438 | `v1.7.1-26088801`, 26088801 | log text / comments |

Unchanged, each with witnesses:
- the fire-mode signature (15 bytes);
- the 0x7fff unit sentinel;
- player fields +0x84/+0x88/+0x3a8/+0xe8;
- the avatar layout: map +0xf8, count +0x6c, entities +0x110, slots +0x150 + ai·0xa7aec + 0x1b68 + 32·action, Fire = action (2,9) → slot 9, held time +8;
- weapon holder rows: map +32, rows +64, stride 48, holder +4;
- the trigger table: count +24, entities +64, flags +88;
- the charge table: count +16, entities +56, entries +64, stride 40, +4 charge, +8 shot charge, +12 flag;
- the charge record: 216 bytes, auto-fire +184, floats +0/+24/+48/+72/+76, fingerprint +168;
- the type hashes (ARC_RESOURCE, AVATAR_TYPE);
- the mission record (+8 set, +0x40 in 1..7, 68 bytes);
- the engine hash-map format;
- the plausibility bounds;
- the Windows/IEEE constants.

**One code patch** (not build data; 7 lines, same line count). The brief's code-page rule requires it:
- `supported_build()` reads FIRE_MODE_SIGNATURE with ReadProcessMemory. Upstream cached any mismatch, including an *unreadable* read (nil), as "unsupported game build" for the whole session.
- On 26088801, game.dll code pages can be PAGE_NOACCESS until first executed. The first `ready()` runs on the first update after load, before any weapon code has run, so upstream would very likely disable itself for good.
- Now an unreadable signature decides nothing: there is no cache and no "Unsupported" log, the addon stays idle (no other read or any write), and the next update reads it again.
- A readable signature that differs still disables the addon for the session.
- The function at 0x761700 is **never called**. Only its 15 bytes are compared.

## Writes (all unchanged in semantics; every address/layout witness is high confidence)

1. **Charging flag: byte 1 at `[[game+0x2ce1de8]+0x40] + 40·i + 12`.** This is the weapon's charge entry, found by matching the armed weapon's entity pointer in `[m+0x38][i]` (count `[m+0x10]`).
   - The charge component update (old 0x73c8f0 → new 0x747f20, 908/908 instructions aligned) iterates exactly that table:
     - `cmp [rbx+0x10]` (count), `[rbx+0x38]` (entity pointers), `[rbx+0x40]` (entries), `lea r14,[rcx+rcx*4]` (stride 40);
     - `cmp byte [r15+r14*8+0xc],0` (charging flag), `addss` dt, then `movss [..+4]` (charge).
   - The trigger update (old 0x7406a0 → new 0x74bd1e) writes the same byte from the fire command (`mov byte [rax+rdx*8+0xc],1` at 0x740a88 / 0x74c108).
   - The only operand differences in the 908-instruction update are engine-interface slots (+8) and the game-state field (+0x80) in its effect/event branches. They are listed in MAP.json and never touch the entry, the record or the flag.
   - Guard (upstream): the page must be committed MEM_PRIVATE PAGE_READWRITE (VirtualQueryEx) or the addon stops. WriteProcessMemory checks the byte count.
2. **Auto-fire flag: byte 1 at charge record + 184, put back on pause/stop/shutdown.**
   - The record is the 216-byte Arc Thrower charge settings record in the weapon data library (committed private PAGE_READONLY region ≥ 1 MiB).
   - The scan finds it by ARC_FINGERPRINT at +168 plus the five charge floats.
   - Layout witnesses:
     - The settings getter (old 0x5052c0 → new 0x50d8b0, 54/54 identical) returns a per-entity copy (`[charge manager+0x90] + 0xd8·i`) or the library record. The library lookup (old 0x504d80 → new 0x50d370) uses `[entities+0xf12ad8 → +0xf145a0]`, 20 slots, records at +0x140, 0xd8 each.
     - The charge update reads `cmp byte [r13+0xb8],0` right after the charge reaches full, then fires (`call 0x748ef0`) and zeroes the charge. That is the engine's own automatic shot, which the flag enables.
   - Guard (upstream): VirtualProtectEx sets PAGE_READWRITE for that byte only, then restores and checks. The write is read back, revalidated every poll frame, and never made through an address whose record no longer validates.
   - **The record values are game data** (ARC_FINGERPRINT, the floats 1.0/1.1/1.2/0.7/1.4; MAP `atr.ARC_FINGERPRINT` medium). They cannot be read offline because the weapon data is encrypted on disk.
   - **This fails closed.** If the data changed, the scan finds nothing and nothing is written; the log says `Charge record not ready yet: charge record not found`. L7 checks it live.

**No write is blocked.** Every address and layout that feeds a write is witnessed by re-disassembled, byte-identical engine code in both builds.

**No game function is called.** The only native calls are kernel32 functions: GetModuleHandleA, GetCurrentProcess, ReadProcessMemory, WriteProcessMemory, VirtualQueryEx, VirtualProtectEx, QueryPerformanceCounter/Frequency and GetTickCount64.

## Verified statically (MAP.json: 28 high, 1 medium, 0 low, 0 unmapped; 26 rows feed a write)

- **Globals.** Every RIP-relative reference to each old global was sampled and migrated by unique instruction windows. On top of that, all six component managers are stored by the world initializer (old 0x568230 → new 0x5711cb) **in the same order**, each as `lea rax,[rbx+off]; mov [rip→global],rax`.

  | Global | Old → new | Agreeing / sampled | Exact windows |
  |---|---|---|---|
  | charge manager | 0x3326c20 → 0x2ce1de8 | 18 / 38 (2 rejected twins) | 18 |
  | trigger manager | 0x3326660 → 0x2ce1810 | 51 / 64 | 48 |
  | mission record | 0x33266a0 → 0x2ce1850 | 51 / 64 | 46 |
  | player manager | 0x3326468 → 0x2ce1618 | 47 / 64 | 45 |
  | entities | 0x346bf98 → 0x2ce41b8 | 42 / 64 | 27 |
  | avatar manager | 0x3326d20 → 0x2ce1ee0 | 47 / 64 | 43 |
  | weapon holder manager | 0x3326dc0 → 0x2ce1f88 | 45 / 64 (2 rejected twins) | 45 |

  Rejected twins, all short windows landing far from the paired code:
  - charge: one masked initializer window and one 32-byte window into an unrelated function;
  - holder: two masked windows, one outside any function.
- **Entity registry.** The unit lookup was re-disassembled (old 0xfdba60 → new 0xe6c010):
  - It has the same `cmp edx,0x7fff`, the same probing, and the map header +0x1AC8 (slots 0xf24990, capacity 0xf24998, empty 0xf2499c, multiplier 0xf249a0).
  - Records are `entities + 0xf349e0 + 24·i`. The new code writes this as `(i + 0xa2314)·24`; 0xa2314·24 = 0xf349e0.
  - A second lookup (old 0x13c8540 → new 0x125f53b) uses the same records.
  - The whole-image displacement scan agrees, with no dissent. These match the brief's live-verified values.
- **Avatar Fire input.**
  - The avatar input reader (old 0xa433f0 → new 0xa5dbfe) shows: map +0xf8/+0x100/+0x104/+0x108; entities `[am+0x110+8i]`; `imul r15,rdx,0xa7aec; add r15,r9`; action id → `shl 5`; `[slot·32 + r15 + 0x1cb8]` (0x150 + 0x1b68).
  - The function using the Fire action `movabs rcx,0x900000002` with the same stride is byte-identical (old 0x6c74c0 → new 0x6d1c10).
  - The action→slot mapper's 13-entry jump table returns the action number for every category in both builds, so (2,9) → slot 9.
  - Slot +8 is read as a float at `+0x1b70` in a byte-identical function.
- **Weapon holders, triggers, mission, players.**
  - Re-disassembled readers are byte-identical: holder rows `lea r8,[rdx+rdx*2]; add r8,r8; [rows+r8*8+4]`, with the holder then looked up in the avatar manager; trigger add-entity `inc [rbx+0x18]`, `[rbx+0x40][i]`; trigger update `[rbx+0x58]` byte flags.
  - Taint-paired fields show no disagreement.
  - The game itself tests mission type `dec eax; cmp eax,6` (1..7) at 55 old / 49 new sites.
- **Fire-mode setter.** The 15-byte signature occurs exactly once in each image (0x755f90 → 0x761700). The function aligns 427/427; the only differences are engine-interface slots.
- **Hashes.**
  - AVATAR_TYPE `0x4d1c334d294dfa97` is a movabs/cmp immediate in both images.
  - ARC_RESOURCE `0x96de9cd50f7306e6` occurs 19 times in each game.dll.

## Tests (offline)

- `--tests` runs `check.py`'s full scenario lists (test_bindings ×5, test_work_budget ×6 + recovery 24×2, test_equivalence equivalence + traces). It uses the workspace Windows LuaJIT under Wine with a private prefix.
- **Upstream unmodified:** 61/61 of check.py's scenarios pass. **Port:** 61/61 pass, plus 2/2 of the code-patch check below (63/63).
- The port's copy of `tests/` gets the same address/pin/text remap as the source. The fixtures encode the old build's addresses, so the suites need it to exercise the port. The remap pairs are in `out/build-receipt.json`.
- The equivalence test passes over 12683 updates with 1068 charging-flag write frames and 15 record writes, plus the trace test.
- **Code-patch check** (`test_signature_pending.lua`, derived by build.py from test_work_budget with the signature unreadable for the first 5 reads):
  - The port passes (normal and slow).
  - The unmodified upstream fails as expected: it disables itself on the first unreadable read.
  - See `out/TESTS.json` → `code_patch_check`.
- Not run: `check.py --archive` (needs a release zip from scripts/build.py, which needs BingusSharedLoader's build_addon packaging); the luaparser grammar check (not installed).

## Not verified / medium confidence

| Item | Why | Live check |
|---|---|---|
| `atr.ARC_FINGERPRINT` and the five charge floats | Game data in the encrypted weapon data. If they changed, the scan finds nothing and the addon never writes (fail-closed). | L7 |

Not verifiable offline at all:
- That the weapon data library is still MEM_PRIVATE PAGE_READONLY under Proton (the scan only searches such regions);
- when the fire-mode setter's code page becomes readable;
- loader discovery in the GC64 VM.

## Read-only in-game checks (for you to run)

B = game.dll base. Nothing here writes. Run `live/arc_thrower_auto_readonly.lua` through Link's Link to Memory:

```
eval local p=assert(io.open('Z:<workspace>/native-work/megapack-port/ArcThrowerRevamped/live/arc_thrower_auto_readonly.lua','rb'));local s=p:read('*a');p:close();local f=assert(loadstring(s,'@atr_readonly'));setfenv(f,getfenv(1));return f()
```

Run it once on the ship, then in a mission with the Arc Thrower equipped: once idle and once while holding Fire.

- **L0 (load):** `ArcThrowerAuto.log` should show:
  - `Arc Thrower Revamped v1.7.1-26088801 initialised on game build 26088801`;
  - no `Disabled:` line and no `Unsupported game build`;
  - later `Charge record ready.` (or `Charge record not ready yet: …`, which is L7's case).
- **L1:** `read(B+0x761700, 15)` = `48894c24085355565741574883ec20` (MATCH). `UNREADABLE` means the page is not resident yet; the port waits and retries.
- **L2:** `R = u64 [B+0x2ce1850]`. On the ship, `u32 [R+8]` = 0 or `[R+0x40]` outside 1..7. In a mission, `[R+8]` ≠ 0 and `[R+0x40]` is in 1..7.
- **L3:** the local avatar chain.
  - `PM = [B+0x2ce1618]`: `[PM+0x84]` and `[PM+0x88]` are 1..4, unit `[PM+0x3a8]` ≠ 0x7fff in a mission, and `[[PM+0xe8]+20]` bit 0 is 1.
  - `N = [B+0x2ce41b8]`: the map at `N+0xf24990` gives index i, and the record at `N+0xf349e0+24i` has hash `0x4D1C334D294DFA97`, owned 1.
  - `AM = [B+0x2ce1ee0]`: the map `AM+0xf8` gives the avatar index (< `[AM+0x6c]` ≤ 8), and `[AM+0x110+8·ai]` holds the same id.
  - Fire slot `AM+0x150+ai·0xa7aec+0x1b68+0x120`: f32 at +8 is 0 when idle and rises while Fire is held. The Aim slot does not move it.
- **L4:** `C = [B+0x2ce1de8]`, count `[C+0x10]` ≤ 512. The Arc Thrower entry (entity hash `0x96DE9CD50F7306E6`) shows:
  - idle: charge +4 = 0 and flag +12 = 0;
  - holding Fire: flag 1, with the charge rising to the full time.
  - The entries page is protect 0x4, type 0x20000.
- **L5:** `T = [B+0x2ce1810]`, count `[T+0x18]` ≤ 4096. While you click Fire with the Arc Thrower, one arc flag in `[T+0x58]` is set briefly.
- **L6:** `W = [B+0x2ce1f88]`: the arc weapon's holder row `[W+0x40] + 48·idx + 4` equals your avatar id (`HELD BY YOU`).
- **L7 (the auto-fire write target):** `L = [N+0xf145a0]`; the Arc hash is in one of 20 16-byte slots, and the record is at `L+0x140+0xd8·index`. Expect:
  - floats 1.000 1.100 1.200 0.700 1.400;
  - fingerprint `0fd7d61a96fba229a931ee670e049541` (MATCH);
  - +184 = 0 in vanilla (1 while the addon runs);
  - page protect 0x2, state 0x1000, type 0x20000.
  - Per-entity copies, if any, are at `[C+0x90]+0xd8·i` and should carry the same values.
  - The old `+0xf12ad8` holds something else.
- **L8:** the charge entries page is PAGE_READWRITE / MEM_COMMIT / MEM_PRIVATE.
- **Behaviour** (after installing): hold Fire with the Arc Thrower in a mission; it keeps firing at the vanilla cadence and stops on release. Other weapons are unaffected.

## Installing (not done here)

- The archive holds only the option resource. The installed Megapack option archive also holds the shared stub `79e4f54aa542ec98`, which must be kept.
- Use `runtime-modules/original-mods/install_option.py ArcThrowerRevamped --port out/…` (dry run first), with the game and HD2 Arsenal closed.
