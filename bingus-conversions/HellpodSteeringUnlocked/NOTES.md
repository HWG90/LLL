# Hellpod Steering Unlocked data-v7.5.1 -> Steam build 26088801 (plain LuaJIT)

Source: `upstream-bingus/HellpodSteeringUnlocked` at git tag v7.5.1. Every `components.lock.json` source_sha256 for this
slug matches the checkout and the pack's pinned copy (`VanillaPlusMegapack/components/HellpodSteeringUnlocked`), so the
checkout is used (build.py re-checks the hashes on its unmodified copy). The installed PORT51 copy was used only as a
pointer to already-mapped values; nothing of its code is used.

## What changed (build data only)
| row | old | new | confidence |
|---|---|---|---|
| archive.EXE_SHA | F5FEE03D... | 0ACC07DE... (installed exe, hashed read-only) | high |
| archive.GAME_DLL_SHA | 2E2C3B7C... | 6D1D4D3B... (installed game.dll, hashed read-only) | high |
| patch.manager_rva | 0x346D578 | 0x2E287D8 | high |
| patch.owner_rva | 0x347CF18 | 0x2E38250 | high |
| patch.owner_offset | 0x7C8C90 | 0x7C8810 | high |

Unchanged, re-witnessed: `size` 69688, flag at +0 (game 1 / mod 0), records u32 +0x8004 (<= 1024), links u32 +0x10008
(<= 8192), set +0x10010 {self+0x10028, 1024, count, 3}, dims +0x11028 {w, w/2, w/64, 1/cell}, the mod's width bounds
64..16384. MAP.json: 12 rows, 12 high, 0 medium/low, 0 unmapped, 0 witness-check failures. The wrapper differs from
upstream on 3 lines only (the two `patch` lines and the `install_loader` pins/revision line; out/wrapper.diff).

## Witnesses (tools/build_map.py recomputes all of them; listings in evidence/witnesses.txt)
- **Static initializer** (old 0x13F2937..0x13F2961, new 0x1289CC7..0x1289CF1, same instruction shape): `mov [owner
  global], rcx` ... `lea rax, [rcx + owner_offset]; mov [manager global], rax`, rcx untouched in between. Old: owner
  0x347CF18, +0x7C8C90, manager 0x346D578. New: owner 0x2E38250, +0x7C8810, manager 0x2E287D8. This one block proves
  all three values and the ownership relation the mod checks (`manager - owner == owner_offset`).
- **Manager global**: all 7 RIP references in the old DLL pair with unique masked windows onto the 7 references of
  0x2E287D8 in the new DLL (6 of them unmasked, 160/128-byte windows).
- **Owner global**: 8 unmasked reference windows (megapack-global-candidates.json, recomputed) + the BRIEF's live
  verification (input owner 0x347CF18 -> 0x2E38250).
- `native-work/field-7c8c90.json` proposed 0x1466D38 for the owner offset from a 32-byte masked window; that lea is a
  different store in the same initializer (not followed by the manager store) and is rejected by the paired block.
- **Layout**: the mission initializer (old 0x13D56C0, new 0x126C830; displacement sets identical) loads the manager
  global, memsets 0x10010 bytes (flag, records, links), memsets 0x1010 at +0x10018, writes width = arg + 100.0 at
  +0x11028, width*0.5, width*0.015625, 1.0/cell at +0x1102C..+0x11034 (constants identical), +0x10010 = self+0x10028,
  +0x10020 = 3, +0x10018 = 0x400, and ends with `mov byte ptr [rbx], 1` (the game's flag value). Last field ends at
  0x11038 = 69688 = `size`. The record/link function (old 0x13D5980, new 0x126CAF0) reads +0x8004 against 0x400 and
  +0x10008 against 0x2000 identically. The avoidance reader (old 0x92A3B5, new 0x93B285, identical window) does
  `cmp byte ptr [manager], 0; je` - the push-away is skipped when the flag is 0, which is the mod's effect.

## Writes (the only ones; no code memory)
1. **Clear**: 1 byte at `[game.dll+0x2E287D8] + 0` from 1 (game value) to 0, via `write_batch(manager, 69688,
   {{0, '\0'}})`, which first requires all 69688 bytes to be committed private read-write data. Only after `stable()`
   re-reads manager and owner pointers, the flag (== 1), the 24-byte set and the 16-byte dims and finds them equal to
   the view that passed `layout_valid` and `manager - owner == 0x7C8810`. Evidence: the game's own mission
   initializer writes 1 to exactly this byte; the reader treats 0 as "no avoidance".
2. **Restore** (`patch.restore`, on pause/stop/error below): 1 byte back to 1, only over the mod's own 0 in the same
   manager/owner/set/dims, same checks. Shutdown writes nothing.

## The current log: `waiting_for_mission`
`archive_loader.lua` reports `waiting_for_mission` right after the build gate passes (exe/game.dll SHA-256 matched),
and `steering_patch.lua inspect()` keeps returning it while either global is null or the manager storage is blank
(all fields zero), which is its state aboard the ship. So the installed copy's log means: build gate passed, ship /
menu, nothing written - the expected state outside a mission. The next status only appears when the mission
initializer has run (flag 1, valid layout): `avoidance_settings_ready` (cleared), or a refusal
(`avoidance_owner_mismatch`, `avoidance_layout_mismatch`, `avoidance_is_not_writable_private_data`) which would point at
a wrong value. The log only records status changes, so a session that never entered a mission shows nothing else.

## Build (build.py)
- MODULES option: both copies are assembled by their own `scripts/module.py build_module()`; its `luajit -bsdW` is
  captured, not run. The option resource keeps the pack's `discoverable_resource()` shape (`-- HD2-Addon:` +
  `loadstring("<escaped>", "@mods/cowboybingus/hellpod_steering_unlocked")`) with the plaintext wrapper as payload.
- Reproduction: a private non-GC64 build of the vendored LuaJIT (work/luajit-fr1, never shipped) compiles the
  unmodified wrapper to exactly the lock's resource_sha256 (4F9D6D66...), and its discoverable resource equals
  resource 71dd3b38d256e5bd of the shipped v26 option archive byte for byte.
- out/9ba626afa44a3aa3.patch_0 holds only `mods/cowboybingus/hellpod_steering_unlocked` (no megapack stub).
- GC64 LuaJIT (runtime-modules/build/linux/LuaJIT) compiles entry and wrapper (FR2 set); the smoke run loads the
  payload, which stops inside its pcall on Linux (no kernel32/bcrypt), active=false, update untouched.

## Upstream tests (`build.py --tests`, out/TESTS.json), port vs unmodified upstream
- `test_data.lua` (Windows LuaJIT under Wine, real adapter, Bounce v15.4.1 peer; hdh-port's bcrypt shim): 15/15 PASS
  both. Its last check runs the shipped plaintext payload as `build/mod.ljbc`.
- `test_api_coexistence.lua` hellpod-first / bounce-first: PASS both.
- `test_idle_gate.lua` (Linux GC64 LuaJIT, x20): data checks pass every run in both; the final JIT trace-abort count
  check (control > 0, now == 0) varies run to run in this LuaJIT for the unmodified upstream too (control 0 or 1-2
  aborts) - environmental; no other failure. Port fixtures: the 3 values replaced in tests/reference/steering_patch.lua.
- Not run: `test_package.py` (release zip).

## Live checks (live/steering_readonly.lua, reads only) - run on the ship, then in a mission
- L1: `[game+0x2E287D8] - [game+0x2E38250] == 0x7C8810` (ship and mission; pointers persist across both).
- L2/L3 on the ship: BLANK (flag 0, everything 0). In a mission: VALID - flag 0 (mod cleared it) or 1 (mod not
  running), records <= 1024, links <= 8192, set = manager+0x10028, 1024, count <= 1024, 3, width in 64..16384 with
  half = w/2, cell = w/64, reciprocal = 1/cell.
- L4: manager+0 and manager+69687 pages protect 0x4, MEM_COMMIT 0x1000, MEM_PRIVATE 0x20000.
- L5: sibling globals from the same initializer: [+0x2E38168] - owner = 0x5EB400, [+0x2E381C8] - owner = 0x7D9848.
- Gameplay: in a mission, steer the pod toward a rooftop/rock - it should not be pushed away; the log should read
  `avoidance_settings_ready`.

Not verified: the port has not run in the game. native-work/megapack-steering-evidence.json records the same three
values with `live_accepted: false`; the installed PORT51 copy with these values only ever logged
`waiting_for_mission` (gate passed, no mission seen), so the in-mission layout check and the write are not yet
witnessed live.
