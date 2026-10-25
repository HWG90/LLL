# Sound Systems Rebalanced v1.0: port to Steam build 26088801 (Vanilla Plus Megapack option)

Source: `upstream-bingus/SoundSystemsRebalanced` (git tag v1.0). Every file pinned in
`VanillaPlusMegapack/components.lock.json` matches it byte for byte. The pack builds this option as BUILD_ASSEMBLED
with entry 'direct': the option resource is `struct.pack('<II', len, 2)` followed by the plaintext entry from the
component's `scripts/build.py assemble()`. There is no bytecode, so the option keeps that envelope as it is.

## Summary

- **Build data.** Remapped: the pins and the game state at `[game.dll+0x2CE1508]+0xAC29C`. Updated: the five
  input-bank pins of the music patch.
- **One non-data edit (user-approved follow-up).** The engine no longer has `stingray.Wwise.set_state`. The port
  falls back to the already-loaded Wwise plugin's exported `AK::SoundEngine::SetState(const char*, const char*)`.
  - Before every call it checks the export's RVA and its first 31 bytes, read through ReadProcessMemory.
  - Any failed check means no call and one log line.
- **Second archive rebuilt.** The music bank archive `9ba626afa44a3aa3.patch_1` is rebuilt from the current banks
  and shipped.
- **Still live-only.** The prologue match (S5) and the in-game listening checks (S6).

## Deliverables

- `MAP.json`: 17 rows, 16 high and 1 medium (`native.prologue`, explained below). `witness_check_failures` is empty.
  `non_data_edits` lists the one code change. `tools/build_map.py` regenerates the map and re-checks every witness.
- `build.py` (`--tests` adds the Wine runs):
  - copies the source to `work/`;
  - applies REPLACEMENTS (pins, layout, comments), the five `biome_patch.VANILLA` pins, and CODE_PATCHES (the
    native fallback);
  - assembles with the copy's own `assemble()`. That also enforces upstream's forbidden names, `LoadLibrary` among
    them, and they still pass;
  - checks that the port entry equals the upstream entry with exactly the 11 listed edits, each applied once;
  - runs the port test;
  - builds the music archive with the port copy's `biome_patch.build()`, re-extracting the banks through
    `tools/collect_evidence.py` when they are missing;
  - writes everything below plus `out/build-receipt.json`.
- `out/`:
  - `entry.lua` and `mod.lua.main`.
  - `9ba626afa44a3aa3.patch_0`: only `mods/cowboybingus/sound_systems_rebalanced`.
  - `9ba626afa44a3aa3.patch_1`: one `content/audio/music_init` wwise_bank resource. Archive SHA-256 `CEE79564…`
    (520,848 bytes); resource 520,654 bytes, SHA-256 `ACD2EE37…`.
  - Both archives come with empty `.stream` and `.gpu_resources` files, the pack's MUSIC_ARCHIVE shape.
  - `entry.diff`, `build-receipt.json` and `TESTS.json`.
- `port/native_set_state.lua`: the inserted block. `port/test_native_set_state.lua`: its offline test.
- `live/sound_readonly.lua`: the read-only probe (S0–S6).
- `tools/` and `evidence/`: bank extraction (Match Your Colors' unchanged upstream `slim.lua`), id counts, the dry
  run, and the map builder.

## The non-data edit

Three edits to `src/sound_systems_rebalanced.lua`, also listed in `CODE_PATCHES` in `build.py`:

1. `port/native_set_state.lua` is inserted before `log_writer`. It defines `Mod.WWISE` and `Mod.native_set_state(api, note)`.
   - **When it applies:** only if `api.module('wwise_pluginw64_release.dll')` (GetModuleHandleA) finds the plugin
     already loaded. No DLL is ever loaded.
   - **Lookup:** the export is resolved with kernel32 `GetProcAddress`, declared under a private FFI name. kernel32 is
     reached with `ffi.load('kernel32')`, the same way the vendored bingus_memory does; it is already loaded.
   - **Checks before every call:**
     - the export resolves;
     - export minus module base equals `0xDA120`;
     - `api.read` (ReadProcessMemory, never a direct dereference) returns 31 bytes equal to `Mod.WWISE.prologue`.
   - **Then:** it calls `int32 (*)(const char*, const char*)` and treats `AK_Success` (1) as success. Any failed
     check, an unreadable page, or a non-1 result logs `Wwise state not set: …; nothing was called.` (or the
     result) and returns false.
2. In `Mod.install`, the line becomes `options.set_state or Mod.engine_set_state(env) or Mod.native_set_state(api, note)`.
   The refusal text, when no plugin is loaded, is now "…set_state is unavailable and the Wwise plugin is not loaded".
   That still contains upstream's tested phrase.
3. In `enter_mission`, `if set_state(...) == false then return end`. A refused or failed state change does not count
   a mission or log "music held". The engine binding returns nil, so its behaviour is unchanged.

### Evidence for each value (MAP rows `native.*`, `engine.Wwise.set_state`)

- **Why SetState(const char*, const char*):** in build 25480438 the plugin registered `Wwise.set_state` →
  RVA 0xBDD0. That function reads arguments 1 and 2 as strings and calls this export (0xDD690), as disassembled
  from the plain old plugin.
- **Why the binding is gone:**
  - A live enumeration of every `stingray.*` C function in the PUC engine state on this build (2026-10-22, before
    the LuaJIT handoff) found 1874 functions in 117 namespaces. None is Wwise, and no function is owned by a plugin.
  - The boot bridge mirrors the whole `stingray` table, so the absence is the engine's.
- **`rva = 0xDA120`:** from the current file's export table; the headers and export directory are plain on disk.
  The ID overload is at 0xDA030 and is not used.
- **`prologue` (medium confidence):** the first 31 bytes of the export in the build-25480438 plugin:
  `40534533c94c8bda488bd94885c97505458bd1eb4a440fb60141bac59d1c81`.
  - They are whole instructions, with no RIP-relative operand and no call: an inline FNV-1 start
    (`mov r10d, 0x811C9DC5`).
  - Both plugins link the same Wwise SDK library build, `wwise-2024.1.9.8920-v1`.
  - The current plugin is encrypted on disk: all 1085 `.text` pages are high-entropy. So **no offline witness of
    the current bytes exists**.
  - The bytes are therefore a strict gate, not a guess. If the live bytes differ, the mod never calls. S5 prints the
    live bytes and `match`. If they differ, replace the prologue with the live capture, but only after reviewing
    that capture.
- **`AK_Success = 1`:** from the Wwise SDK AKRESULT enum.
- **Thread safety:** SoundEngine::SetState is documented as thread-safe; it is queued to the audio thread.

### Writes

None to game memory. Per mission start there is one checked call of the plugin export. The 31-byte read and the
u32 state read use ReadProcessMemory.

## Second archive: music_init biome fallback, rebuilt

- **Inputs:** the five current banks (main parts) from the slim data. The extractor is validated: on the installed
  build-25480438 copy it reproduces all five old pins exactly. The current banks each grew by 418 bytes; their
  hashes are the MAP `biome_patch.VANILLA.*` rows, the only edits to `scripts/biome_patch.py`.
- **Build:** the port copy's `biome_patch.build()`. Every structure check passes, with the same counts as on
  25480438: 24 tracks edited, 24 added, 1 switch edited, 3 added, 2303 objects, bnk 487,182 → 520,638 bytes.
  `tests/test_biome_patch.py` passes on the current banks (14 tests, OK).
- **build.py also checks:** the archive is one `content/audio/music_init` wwise_bank resource, and the resource
  header is BKHD with the new size.
- **Witness of the pipeline:** the same code with the old pins rebuilds the shipped v26 `patch_1` (`F16873AE…`)
  byte for byte from the old banks (`--tests`).

## Tests

- `build.py`, every run: `port/test_native_set_state.lua` in the Linux LuaJIT, 9 PASS.
  - Covered: match → exactly one call through a real function pointer; prologue mismatch, unreadable page, wrong
    RVA and unresolved export → no call and one log line; AKRESULT ≠ 1 is reported; no plugin → no path.
  - `Mod.new` counts a mission only when the state was set.
- `build.py --tests` (Windows LuaJIT under Wine), all PASS:
  - `tests/test_mod.lua` (11), `compile_entry.lua` and `test_entry.lua`, on the port and on unmodified upstream;
  - the port test under Windows LuaJIT;
  - `test_biome_patch.py` on the old banks;
  - the shipped v26 `patch_1` reproduction.
- Not run: `tests/game_lua.py` (Windows ctypes against `lua51.dll`).
- Compile: `loadstring` in the GC64 Linux LuaJIT passes; FR2 is set. The Linux smoke run stops at the Windows-only
  `ffi.load`, as unmodified upstream does.

## Read-only in-game checks (`live/sound_readonly.lua`)

Run on the ship, on a mission loading screen and in a mission. Nothing is called and nothing is written.

| Check | What it reads | Expect |
| --- | --- | --- |
| S0 | Mod status | `watching for mission starts`; after a mission start, `held mission music … 1 time(s)` |
| S1 | `[game+0x2CE1508]+0xAC29C` | 3 on the ship, 6 while loading, 4 in a mission |
| S2 | Old slot `game+0x3326340` | Not the S1 object |
| S3 | `stingray.Wwise`, `Wwise`, `WwiseWorld` | All nil (confirms the fallback is needed) |
| S4 | The plugin's in-memory `.rdata` (decrypted) | Counts of `Wwise`, `set_state`, `trigger_event`, `set_switch`, `WwiseWorld` are `0 0 0 0 1` (old build: `1 1 1 1 1`) |
| S5 | Export table walk, export page region, 31 bytes at +0xDA120 | Export RVA 0xDA120; region protect 0x20 (execute-read), state 0x1000, type 0x1000000 (image); `match=true` |
| S6 | Listening checklist | See below |

- **S4 caveat:** a 0 over an all-high-entropy region is inconclusive.
- **S5 decides whether the mod will call.** Protect 0x1 (no access) or `match=false` means it will refuse; report
  the printed bytes.
- **S6, the second archive:**
  - Its loaded copy is not located; the resource manager's bank table is not mapped. Compare the deployed `patch_1`
    with `build-receipt.json` → `second_archive`.
  - Listen: joining a mission in progress, or deploying from the hangar, should play music at the war-table level.
  - On a swamp, desert, deciduous, coniferous, oasis, hive or rift world, start-intensity and drop music should play
    instead of silence.
  - The log should show one line per mission start and no `Wwise state not set` line.

## Remaining live-only items

1. The live SetState prologue must equal the expected bytes (S5). Until it does, the mod refuses safely.
2. The export page is readable and image-backed at mission start (S5 region).
3. Audible confirmation of the war-table level after a join in progress, and of biome music on the seven
   previously silent biomes (S6).
4. The rebuilt `music_init` loads (music plays at all; the old build once went silent from a malformed bank).
