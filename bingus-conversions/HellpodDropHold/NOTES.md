# Hellpod Drop Hold v1.2.1 → Steam build 26088801 (offline port)

Source: `upstream-bingus/HellpodDropHold` (git `v1.2.1`, clean). Old build 25480438, new build 26088801
(game.dll `6D1D4D3B…C08F`, helldivers2.exe `0ACC07DE…EABE`, both re-hashed read-only from the install).
Nothing here touched the network, the game folder, `~/.config/hd2arsenal`, anything under `<steam-library>`
(read only), the upstream checkouts, or the running game. Nothing was installed.

## 2026-10-29: the "unexpected pod type hash" was other pods (no re-map needed)

The 2026-10-25 mission probe (`live/hdh_readonly.live.log`) listed 5 landed, owned pods, all with type hash
`0x73F8498BFFDCF415`, and was read as "live pods carry a type hash the mod does not expect". Statically:
- `0x73F8498BFFDCF415` occurs once in each game.dll (old 0x79EC8B, new 0x7AA4FB), as the fallback of a seeded random
  pick (PCG constants 0x5851F42D4C957F2D / 0x14057B7EF767814F beside it, a weighted sum over a 0x58-stride table) in
  a function unrelated to the avatar spawn. It is an existing pod type in both builds, not a renamed player pod.
- The player-pod hashes the mod expects keep their only sites in the avatar-spawn code: new 0xAA3AA9 (`movabs rdi,
  0xE58163E71928D3E2`) and 0xAA3BF5 (`0xEF9EB729A9D6D849`) in 0xAA27D0, and 0xAA49C2 compares a record's `[rec]`
  with `0xE58163E7…` exactly as the mod does (old 0xA8804B / 0xA88190 / 0xA88F64).
- The same probe found both expected hashes in the settings table with the expected records (L7: variant 2,
  400/500/100/1.0; variant 1, 350/350/100/1.0).
So the probe ran while no player pod existed (sentries were out: those were stratagem pods). The map stands and the
port goes in as built (it fails closed on any unrecognized pod; the installed copy failed to load on `PORT51`).
Behaviour check still due: a slow mission load or a join, where the log should show `holding initial spawn pod …`
then `released pod …`.

## Deliverables

| Path | What |
|---|---|
| `MAP.json` | 33 rows, one per build-specific constant or constant group (file, line, old, new, method, re-disassembled witnesses, conflicts, confidence, `feeds_write`, `role`, live check). `witness_check_failures` is empty. |
| `build_hdh_port.py` | `python3 -I -B build_hdh_port.py [--tests]`. Copies upstream `src/`, `scripts/` and `tests/` to `work/port` (and unchanged to `work/upstream`), applies the edits, builds with the upstream `scripts/module.py` `build_module()`, and writes `out/`. |
| `out/entry.lua` | sha256 `816c392d06ac7696d6d130bb2747e851a02c28b4da114c68dd78864d78a77097`. Byte-identical to the upstream entry and to the shipped Megapack v26 entry (`d2aba22187eadcbb`). |
| `out/impl.lua` | sha256 `55fc604a366231d4b1b048d91073c6da0dc399877766ba8fc1ca2c2603e2d095`. Plaintext implementation: the exact wrapper `build_module()` assembles, with the edits. |
| `out/9ba626afa44a3aa3.patch_0` | sha256 `14ae839dbfc65e3abca678eab94449a396a77b4bfd427ea14b61579bacee83c9`, built with `BingusSharedLoader/scripts/archive.py make_archive` and round-tripped. It holds `mods/cowboybingus/hellpod_drop_hold` (`d2aba22187eadcbb`, 194 bytes) and `mods/cowboybingus/hellpod_drop_hold_impl` (`31d6851d9f197100`, 70244 bytes), both type `a14e8dfa2cd117e2` with the version-2 envelope. Empty `.stream`/`.gpu_resources` companions sit beside it. |
| `out/impl.diff` | Port implementation vs the unmodified upstream assembly: 8 lines. |
| `out/build-receipt.json`, `out/TESTS.json` | Input/output hashes, every edit, the LuaJIT check output, and the test results. |
| `tools/` | Read-only analysis: `lib.py`/`align.py` (from myc-port), `map_globals.py`, `map_fields.py`, `state_enum.py`, `name_tables.py`, `show_pair.py` (aligned old/new listing), `build_map.py` (writes MAP.json and re-asserts every witness), `mock_llm_probe.lua` (offline mock run of the live probe). |
| `evidence/` | `globals.json`, `field-pairs.json`, `state-enum.json`, `name-tables.json`, `old-global-xrefs.json`, plus `listings/` (aligned listings of the hellpod update, pod init, avatar spawn, state setter, synchronized-tasks-done and presenter push). |
| `live/hdh_readonly.lua` | Read-only live probe for checks L0–L8 below. |

Rebuild: `cd tools && python3 -I -B map_globals.py && python3 -I -B map_fields.py && python3 -I -B state_enum.py && python3 -I -B name_tables.py && python3 -I -B build_map.py`, then `cd .. && python3 -I -B build_hdh_port.py --tests`.

## Packaging (GC64)

- The old build compiled the implementation with `luajit -bsdW`, which produces non-GC64 (FR1) bytecode. The game's VM is now LuaJIT 2.1 GC64 and cannot load it.
- `build_hdh_port.py` therefore runs upstream `build_module()` unchanged, with one exception: that one subprocess call is captured instead of run. The implementation resource is the plaintext `mod.wrapper.lua` that `build_module()` assembled, in the same `lua_resource` envelope.
- The entry is untouched. It still declares `-- HD2-Addon: mods/cowboybingus/hellpod_drop_hold` and does `return require('mods/cowboybingus/hellpod_drop_hold_impl')`, so the loader path is unchanged.
- The installed Megapack copy failed with `hellpod_drop_hold_impl:905: … 'PORT51'` and was plaintext loaded through this same `require`. That confirms the game loads plaintext through this path.
- There is no PORT51/compat51 adapter. The build refuses either word in the entry or the implementation.
- The upstream forbidden-name rule is enforced, since `build_module()` runs it.
- The implementation carries no `HD2-Addon` declaration, so discovery never starts it on its own.
- The only non-data edits:
  - A comment-only edit on the header line `docs/TECHNICAL.md has the evidence…`, which points at MAP.json.
  - The revision string `data-v1.2.1-26088801`, which shows in the log's first line. Upstream's is `data-v1.2.1`.
- The build checks that the unmodified upstream assembly (old pins, revision `data-v1.2.1`) reproduces `runtime-modules/vm-poc/work/legacy/hellpod_31d6851d9f197100.lua` byte for byte. That file is the source of the shipped bytecode.
- Linux LuaJIT 2.1 GC64 check (`string.dump` flags 8 = FR2):
  - `loadstring` compiles both files.
  - The entry, run with the implementation in `package.preload`, executes the whole implementation. The first Windows call (`ffi.load('kernel32')`) then fails inside the mod's own `pcall` and becomes its status, the same as on any unsupported host.

## What changed (everything else is byte-identical to v1.2.1)

| MAP row | Constant | Old | New | Feeds the write |
|---|---|---|---|---|
| `archive.EXE_SHA` | exe SHA-256 pin (`scripts/archive.py`) | `F5FEE03D…5F06` | `0ACC07DE…EABE` | gate |
| `archive.GAME_DLL_SHA` | game.dll SHA-256 pin | `2E2C3B7C…F51E` | `6D1D4D3B…C08F` | gate |
| `hold.game_rva` | game object global | 0x3326340 | 0x2CE1508 | timing |
| `hold.state_offset` | game state field | 0xAC21C | 0xAC29C | timing |
| `hold.ui_state_rva` | UI state global | 0x347CE28 | 0x2E38160 | timing |
| `hold.cutscene_rva` | cutscene manager global | 0x346D530 | **0x2E28780** | timing |
| `hold.session_rva` | session / network context global | 0x347CEF0 | 0x2E38228 | timing |
| `hold.hotjoin_offset` | `is_hotjoining`, `has_hotjoined` (u8, u8) | 92135 (0x167E7) | **92143 (0x167EF)** | timing |
| `hold.manager_rva` | HellpodComponent manager global | 0x3326D58 | **0x2CE1F18** | **address** |
| `hold.settings_rva` | entities object global | 0x346BF98 | 0x2CE41B8 | **value** |
| `hold.settings_table_offset` | HellpodComponent settings table field | 15805152 (0xF12AE0) | **15812008 (0xF145A8)** | **value** |

Unchanged, with witnesses:
- presenters block +0x4290 (HUD +0, menu +4, popup +8, stack +12..+28, depth +32), stack +0x429C, max depth 5;
- scene +6412 (queued +6416);
- client state +91288;
- manager header (capacity +36, total +44, active +48, id map +64/+72/+76/+80, records +88, locals +104, nets +112);
- entity record (hash +0, id +8, flags +20 bit 0);
- local state stride 160 with t at +32;
- networked state stride 20 (phase +0: 0 falling, 1 braking, 2 landed; z +12);
- settings table (16 × 16-byte slots {u64 hash, u32 index}, records at +256, 104 bytes; variant +0, initial +20, braking height +24, braking velocity +28, time +32);
- game states 4/5/6, menu presenters 2/4, scene ids 1..20;
- pod type hashes `0xE58163E71928D3E2` / `0xEF9EB729A9D6D849`.

## Verified statically (MAP.json: 32 high, 1 medium, 0 low, 0 unmapped; 29 rows feed the write)

**Globals.** Up to 64 old RIP-relative sites per global were migrated by unique instruction windows. Exact windows come first; windows with field displacements masked come second and are recorded as such.

| Global | Old → new | Agreeing witnesses | Exact windows |
|---|---|---|---|
| game object | 0x3326340 → 0x2CE1508 | 34 | 4 |
| UI state | 0x347CE28 → 0x2E38160 | 18 | 16 |
| cutscene manager | 0x346D530 → 0x2E28780 | 40, from 40 distinct functions | 35 |
| session | 0x347CEF0 → 0x2E38228 | 41 | 33 |
| HellpodComponent manager | 0x3326D58 → 0x2CE1F18 | 55 | 54 |
| entities | 0x346BF98 → 0x2CE41B8 | 42 | 27 |

- The cutscene global is not a uniform shift within its family: 0x346D578 → 0x2E287D8 is +0x58 from it, where the old gap was +0x48.
- There is one disagreement. It is masked-only: the old 0x58C29A getter matched a different component's identically shaped getter at new 0x4ADCCA, which reads +0x50/+0x28 instead of +0x68/+0x48. It was rejected as a template twin. Every exact window agrees.

**The write path** (one 4-byte float store of t, plus one store of the saved t at release):

- **Address**:
  - `[game+0x2CE1F18]` is the HellpodComponent manager:
    - The world initializer stores `&world[+0x75ECD0]` there (old: `&world[+0x75F270]` → 0x3326D58).
    - The world update passes that same address to the HellpodComponent update (old 0x92B770 → new 0x93C640, 2463/2770 instructions aligned).
  - In that update, every header field the mod reads is used at the same offset. Examples: `cmp [rcx+0x30]` (active), `[r15+0x58]` (records), `add r12,[r15+0x68]` after `lea r12,[rcx+rcx*4]; shl r12,5` (locals, stride 160), `[r15+0x70]` with `lea r14,[rcx+rcx*4]` and `[rsi+r14*4]` (nets, stride 20).
  - Taint-paired fields across the 51 aligned functions that load the global (37 of them with field pairs) show every header offset unchanged: +0x24 ×3, +0x2C ×14, +0x30 ×9, +0x40 ×28, +0x48 ×34, +0x4C ×24, +0x50 ×27, +0x58 ×10, +0x68 ×8, +0x70 ×8, with no disagreement.
  - The manager's own id lookup (old 0x9304E0 → new 0x941670) is re-disassembled: `[m+0x48]` capacity, `[m+0x50]` multiplier, `imul` with the id, `[m+0x40]` slots, `[m+0x4C]` empty key, `& (capacity-1)`, 8-byte slots. That is the probing `map_index` mirrors.
  - The entity record is unchanged: `mov rcx,[rec]` (type hash, passed to the settings lookup), `[rec+8]` (id), `test byte [rec+0x14],1` (owner) at 2 sites in the update, plus the spawn-side lookup.
  - The pod type hashes are `movabs` immediates in the avatar spawn sequence (old 0xA866F0 → new 0xAA2150, 1850/1861 aligned). These are their only occurrences in either image.
- **t semantics**: t at local+32 is accessed exactly three times in the update in both builds:
  - Decay read and decay store: `if phase == 1 and t > 0 then t = max(0, t - dt / settings.time)`. Re-disassembled pairs: `cmp ecx,1`, `movss xmm3,[r12+0x20]`, `comiss xmm3,xmm14` (xmm14 = 0), `divss xmm0,[rax+0x20]`, `maxss`, `movss [r12+0x20],xmm2`.
  - Step read: `((1 - t) * [settings+0x1C] + t * [settings+0x14]) * dt`, with xmm12 = 1.0 (0x23C6D70 → 0x2246594, both read back as 1.0).
  - Pod init still writes t = 1 when the braking time is > 0 (`movss [rdi+0x20],xmm0` after `[rbx+0x20]`).
  - The new build's inserted code in the update (an inlined event-queue push, about 180 instructions) never touches the local state.
  - Every manager-loading function has the same number of +0x20 dword stores old vs new.
  - So t_hold = (0.5 − braking)/(initial − braking) < 0 still skips the decay and gives a 0.5 m/s step.
- **Value** (the settings that compute t_hold):
  - The HellpodComponent update and pod init call the settings lookup old 0x505390 → new 0x50D980. It is a leaf function with no pdata, which is why the normal xref scan found only one site.
  - The lookup reads `mov r10,[rax+0xF12AE0]` → `[rax+0xF145A8]` from the entities global, and is otherwise byte-identical: `and r8d,0xF`, `shl rax,4`, 16 probes, `[slot+8]` index, `imul rcx,rax,0x68`, `lea rax,[r10+0x100]`.
  - A raw scan of every instruction (pdata or not) finds exactly 2 sites of 0xF12AE0 in the old image and 2 of 0xF145A8 in the new one. They pair 1:1 with identical code: the lookup, and old 0x870C00 → new 0x87DFB0.
  - The lookup has 24 call sites in both builds, in the same order.
  - The neighbouring table fields 0xF12A28..0xF12C48 all moved +0x1AC8.
  - In the new image, +0xF12AE0 is now written by unrelated code (0x5659BF). Keeping the old value would read a wrong pointer.
  - The update reads exactly the record fields the mod uses: `[rec+0x14]`, `[rec+0x18]`, `[rec+0x1C]`, `[rec+0x20]`, and `cmp [rec],0` (variant).
- **Timing** (when to hold or release):
  - Game state +0xAC29C has 75 taint pairs. 211 of the 329 old sites map to 0xAC29C, and all 170 compared immediates are equal. The state setter (old 0xAB2FA0 → new 0xACECC8) indexes a state-name table (0x2147F30 → 0x1FD0740) whose names 0..6 are identical: None, Splash, TitleScreen, Ship, Mission, PrepareShip, PrepareMission.
  - UI block:
    - +0x4294 ×40, +0x4298 ×29, +0x429C ×38, +0x42B0 ×34, +0x4290 ×1, +0x4288 ×6, all unchanged.
    - The PresenterManager push (old 0x14C0550 → new 0x135B830) still writes `stack[depth]` at manager+0x14 and increments depth at manager+0x28. It still logs through the menu presenter name table, now 0x2065380, whose names 0..25 are identical (2 LoadingMission, 4 LoadingTutorial). The HUD name table (→ 0x2065978) is identical too.
  - Cutscene: +0x190C ×50, +0x1910 ×39. The scene-name switch (0x117E950 → 0x100F400) has 20 identical names.
  - Session:
    - Client state +0x16498 is unchanged (4 taint pairs plus 6 of 8 scan sites).
    - `is_hotjoining`/`has_hotjoined` moved +8. Synchronized-tasks-done (old 0xAD4520 → new 0xAF0640) now does `cmp byte [rax+0x167EF],0` / `mov byte [rax+0x167EF],0` and then reads the scene at `[cut+0x190C]`.
    - The 8-byte insertion lies between +0x166D8 (unchanged) and +0x167E6 (+8). The old 92135 would read the byte before the flag.
- **Code pages**: HDH reads no code bytes and calls no game function. Every read is ReadProcessMemory into its own buffers (`read_to`). The write is `write_batch`: VirtualQuery shows committed private RW, then WriteProcessMemory, then read-back. The PAGE_NOACCESS code-page rule therefore does not apply. `verify_build` hashes the module files on disk.

**Tests.** The upstream `tests/test_hold.lua` ran offline:
- **Port:** 18/18 checks pass in the workspace Windows LuaJIT under Wine (private prefix `work/wine-prefix`, ~380 MB, deletable).
- **Unmodified upstream copy:** the same result, 18/18.
- **Wine shim (test environment only, applied identically to both runs):** Wine's `bcrypt` faults inside `BCryptDestroyHash` (execute access violation). This was reproduced with unmodified upstream code. A `-e` prelude seeds Bingus Shared Runtime's per-session hash cache (`BingusRuntime.hashes`) with luajit.exe's SHA-256, computed by Python, so the test's one `module_hash` call never reaches bcrypt. Consequence: the SHA-256 code itself was not exercised under Wine.
- **Not run:**
  - `tests/game_lua.py`: needs the game's old lua51.dll through Windows ctypes.
  - `tests/test_package.py`: needs the release zip.

## Not verified / medium confidence

| MAP row | Why | Live check |
|---|---|---|
| `drop_hold.TYPES.variant` (2 initial spawn, 1 reinforce) | Game data. `generated_entities.dl_bin` is encrypted, so it cannot be read offline. Code still special-cases variant 2 at the same two sites. **Fails closed:** a different variant, or implausible velocities, stops the mod (`drop_pod_settings_unrecognized`) before any write. | L7 |

Not verifiable offline at all:
- The real load path in the game's GC64 VM: Bingus Shared Loader discovery, then `require` of the plaintext impl.
- Loading-screen timing, and frame order between the Lua update and the world update.
- How far a pod falls before the first held frame.
- Whether the build-26088801 join flow still reaches the same signals in the same order. The offsets are proven, but the flow changes nothing about the safety, since holds are capped at 120 s and released on pause/stop.

## Read-only in-game checks (for you to run)

B = game.dll base. Nothing here writes. Run `live/hdh_readonly.lua` through Link's Link to Memory:

```
eval local p=assert(io.open('Z:<workspace>/native-work/hdh-port/live/hdh_readonly.lua','rb'));local s=p:read('*a');p:close();local f=assert(loadstring(s,'@hdh_readonly'));setfenv(f,getfenv(1));return f()
```

Run it once on the ship and once in a mission, ideally while your own hellpod or a reinforcement pod is falling. `tools/mock_llm_probe.lua` runs it against mocked memory offline.

- **L0 (pins, load):** with the port installed, `HellpodDropHold.log` (`%LOCALAPPDATA%/CowboyBingus/Helldivers2/Logs/` in the Proton prefix) has:
  - first line `data-v1.2.1-26088801`;
  - second line `waiting_for_loading_screen`, not `unsupported game build…`, and no `PORT51` error.
- **L1 (game state):** `G = u64 [B+0x2CE1508]`.
  - `u32 [G+0xAC29C]` = 3 on the ship, 4 in a mission, 5/6 behind a loading screen.
  - `[G+0xAC21C]` (the old offset) does not track these values.
- **L2 (UI):** `U = u64 [B+0x2E38160]`; nine u32 at `U+0x4290`: HUD, menu, popup, stack[5], depth.
  - Depth 0..5. HUD 2 on the ship, 3 in a mission.
  - With the escape menu open: depth ≥ 1, and the top of the stack (`[U+0x429C+4*(depth-1)]`) = 1 (Main).
  - Behind the mission loading screen: menu (`U+0x4294`) = 2, or 2 on the stack.
- **L3 (cutscene):** `C = u64 [B+0x2E28780]`.
  - `u32 [C+0x190C]` (current) and `[C+0x1910]` (queued) are 0 when idle.
  - 6 during the ship hellpod launch cinematic.
  - 15 while a network join's teleporter scene plays.
- **L4 (session):** `S = u64 [B+0x2E38228]`.
  - `u8 [S+0x167EF]` (`is_hotjoining`) = 0 normally, 1 only while a join into a mission in progress is finishing.
  - `u8 [S+0x167F0]` (`has_hotjoined`) = 1 after you joined a mission in progress.
  - `u32 [S+0x16498]` is the client state (log only).
  - The old `+0x167E7/+0x167E8` bytes should not behave like these flags.
- **L5 (manager):** `M = u64 [B+0x2CE1F18]`, non-null once a world exists.
  - `u32 [M+0x24]` capacity ≤ 4096, `[M+0x2C]` total ≤ capacity, `[M+0x30]` active ≤ total.
  - `[M+0x48]` is a power of two, `[M+0x4C]` the empty key, `[M+0x50]` the multiplier.
  - Pointers `[M+0x40]`, `[M+0x58]` records, `[M+0x68]` locals, `[M+0x70]` nets are user-mode.
- **L6 (pods, mission):** for each `i < active`, let `rec = u64 [records+8i]`:
  - `u64 [rec]` is the type hash: `0xE58163E71928D3E2` for your first drop or a join, `0xEF9EB729A9D6D849` for a reinforcement. Other hashes are stratagem pods.
  - `u32 [rec+8]` is the entity id, and `[rec+0x14]` bit 0 = 1 for pods your machine owns (your own).
  - `hashmap(M+0x40, id)` = i. The probe prints `ok`.
  - Phase `u32 [nets+20i]`: 0 falling, 1 braking, 2 landed. Height `f32 [nets+20i+12]` decreases.
  - t `f32 [locals+160i+32]`: 1.000 while falling, drops toward 0 within about 1 s of braking, then stays 0. With the mod holding: about −0.332 (initial spawn) or −0.398 (reinforce), with the height sinking 0.5 m/s. These values assume the build-25480438 velocities from TECHNICAL.md; L7 shows the real ones.
- **L7 (settings):** `N = u64 [B+0x2CE41B8]`, `T = u64 [N+0xF145A8]`.
  - Each pod hash sits in one of the 16 slots at `T` (start = low32 & 15) with its record index at slot+8.
  - The record is at `R = T + 0x100 + 0x68*index`:
    - InitialSpawn: `u32 [R]` = **2**, `f32 [R+0x14]` = 400, `[R+0x18]` = 500, `[R+0x1C]` = 100, `[R+0x20]` = 1.0. The probe prints t_hold −0.332.
    - Reinforce: variant **1**, 350 / 350 / 100 / 1.0, t_hold −0.398.
    - `[R+8]` should be the spawn height (1500 / 1000 per TECHNICAL.md); informational only.
  - `u64 [N+0xF12AE0]` (the old offset) holds something else.
  - This is the TYPES.variant check.
- **L8 (write target page):** `region(locals)` should be PAGE_READWRITE (0x4), MEM_COMMIT, MEM_PRIVATE. That is what `write_batch` requires before its one store.
- **Behaviour** (after installing):
  - In a mission join or a slow load, the log shows `holding initial spawn pod <id> at ~1500 m (speed factor 1.000 -> -0.332)`, then `released pod <id> (loading screen gone) after N s`.
  - A reinforcement during normal play is never held, because no loading screen is up.
  - Neither `drop_pod_settings_unrecognized` nor `manager_layout` ever appears.

## Installing (not done here)

- The archive holds two resources, the entry and the implementation. The installed Megapack option's archive holds three: `d2aba22187eadcbb` entry, `31d6851d9f197100` implementation, and the shared Megapack stub `79e4f54aa542ec98`. The port replaces the first two and must keep the stub.
- `runtime-modules/original-mods/install_option.py --port` currently expects a single main resource. It needs a two-resource variant (or an equivalent manual swap) for this option, used with the game and HD2 Arsenal closed.
- A standalone install is the archive plus the two empty companions, behind Bingus Shared Loader.
