# Stratagem Hero Expanded v1.0: Megapack option port to Steam build 26088801

## Source and recipe
- Source: `upstream-bingus/StratagemHeroExpanded`, tag v1.0 (commit 381f9a1). Every file pinned in
  `VanillaPlusMegapack/components.lock.json` matches it, and `build.py` re-checks them on each copy.
- Recipe: BUILD_ASSEMBLED, entry 'direct'. The pack ships the plaintext declaration-bearing entry from
  `scripts/build.py assemble()` in the type-2 envelope. It is already plaintext, so there is nothing to un-bytecode.
- Reproduction: the unmodified assembly equals the lock's resource_sha256 (4F330415…). It is also byte for byte
  resource a55a78cfbcae38c7 of the shipped v26 option archive.
- Output: `out/9ba626afa44a3aa3.patch_0` holds only `mods/cowboybingus/stratagem_hero_expanded` (a55a78cfbcae38c7).
  There is no megapack stub. Empty `.stream` and `.gpu_resources` files sit beside it.
- Compile check: the entry compiles with `loadstring` in the workspace GC64 LuaJIT (FR2 flag set). The port's own
  `Mod.tables().vanilla` equals the new game.dll image at 0x24B5CC0 and 0x24B5F70. The pool is 108 in 8 groups and
  the probe is 127.
- Linux smoke run: the entry stops inside the runtime's own load of bcrypt before installing, and hooks nothing.
  Under Wine `test_entry.lua` shows the normal refusal path.

## Map (MAP.json): 14 rows, all high confidence, 0 witness failures
`tools/build_map.py` re-decodes every witness on each run.

| Value | Old | New | Witness |
|---|---|---|---|
| EXE / GAME SHA-256 pins | F5FE… / 2E2C… | 0ACC… / 6D1D… | the installed files, read only |
| `tiers_rva` (written) | 0x263CCC0 | 0x24B5CC0 | the picker's `lea` (0x598389 → 0x5A0F49). The picker (0x598370 → 0x5A0F30) is instruction-identical, 88 instructions. The 612 old tier bytes occur once in the new image, at 0x24B5CC0 in .data. |
| `groups_rva` (written) | 0x263CF70 | 0x24B5F70 | the picker's `lea` (0x59841B → 0x5A0FDB). The old 640 bytes, with stratagem numbers migrated by name, occur once at 0x24B5F70. The gap between the tables is still 0x2B0 = 612 + 76. |
| table layout 9/68/8 and 10/64/16 | same | same | identical picker: `imul 0x44`, 8 entries, `shl 6`, 16 slots |
| `VANILLA_TIERS` | same | same | the bytes are identical in both images (banners, group indices and weights; no stratagem numbers) |
| `VANILLA_GROUPS` | old numbers | migrated | upstream lists encode to the old image's bytes; the migrated lists encode to the new image's bytes |
| `GROUPS` (108, written) | old numbers | migrated | see "Pool" below |
| `settings_rva` | 0x37CB600 | 0x31870E0 | 4 paired instructions: the builder `lea`, the unload `lea`, the arcade input check (0x598074 → 0x5A0C34, then `[+0x48]` and `[+0x40]`) and the round widget (0x5979C7 → 0x5A0587). The read-only capture agrees, and so does the Bounce sibling's 126/126 vote. |
| `TYPES` | 150 | 154 | the game clears TYPES×8 bytes of the table: `mov r8d,0x4b0` → `0x4d0` in the builder (0x11F20FE → 0x108391E) and unload (0x11F22B1 → 0x1083AD1). The enum has 150 → 154 names. |
| `PROBE` | 124 | 127 | enum name ReinforcementBeacon; the capture holds kind 127's own StratagemInfo |
| StratagemInfo fields 0xC0/+0/+0x40/+0x48/+0xB8, MAX 10/4 | same | same | the arcade input check reads `[+0x48]` and `[+0x40]` in both builds. Nine paired sites read `[+0xB8]` right after a table load. 153 captured records and 77 old-build records agree. |
| comment: picker and round logic | 0x598370, 0x5970D0 | 0x5A0F30, 0x59FC90 | the identical picker; the round logic calls it twice (0x5A0230, 0x5A0291) |
| build text | 25480438 | 26088801 | text only (comments, header, refusal messages) |

**Enum migration.** The StratagemType name registration is decoded in both images (old fn around 0x1568962, new
around 0x1408CDA): 150 → 154 names. It is identical to `native-work/stratagem-enum-migration.json`, which also had
77 independent descriptor-id matches.

**Pool** (`evidence/pool.json`). All 108 migrated numbers are unique. Each one has, in the read-only settings capture:
- its own StratagemInfo (type == number);
- 1..9 code arrows;
- a HUD type of 4 or less;
- the same class (+0x188) that the upstream test fixture gives the old number.

So every group still holds exactly one family, or the shared pair. The port's numbers are identical to those in the
installed PORT51 copy, which logged "applied (108 stratagems in 8 groups; pages 0x08, 0x08), at load." and "At
shutdown: the arcade still draws from the expanded pool."

**Stratagems added in 26088801** (reported only; no feature added, the pool stays the upstream 108):
- 28 SniperRifleDuo: class 20, support weapon, category 2
- 50 EagleFlyBy: class 7, Eagle, category 0
- 66 LaserRifleIon: class 14, support weapon, category 2
- 145 OrbitalConfetti: class 2, orbital, category 0

The two category-2 support weapons look loadout-selectable. Upstream's rule ("every stratagem a loadout can hold")
would then add them to groups 4 and 5. Those groups already hold 16 each, the slot limit, so adding them would need a
regrouping. That is a feature decision, not a port, so nothing was added.

## The one non-data edit (MAP.json `non_data_edits`: hero.region_type_mapped), flagged, medium confidence
The edit:
- before: `region.type ~= MEM_IMAGE`
- after: `(region.type ~= MEM_IMAGE and region.type ~= MEM_MAPPED)`, with `MEM_MAPPED = 0x40000` added.

Why it is needed:
- In the running game under Proton, game.dll's own image pages report type 0x40000 (MEM_MAPPED). Evidence is
  `native-work/mom-port/live/mom_page_region.live.log`: 5 regions, rva 0x167F000..0x168C000.
- The unmodified page check would therefore refuse the tables, and the mod could never apply.

Why it is environment-specific, not generic Wine:
- Offline, plain Wine reports MEM_IMAGE for every section of a normally loaded image (`out/TESTS.json`
  `wine_host_region_types`).
- The unmodified upstream "page check" test passes there.
- So this is how game.dll is mapped in this game, not generic Wine behaviour, and the edit adds MEM_MAPPED rather
  than replacing MEM_IMAGE.

Checks that stay unchanged:
- MEM_COMMIT;
- the writable-protection set {0x04, 0x08, 0x40, 0x80};
- allocation base == game.dll base;
- exact vanilla bytes of both tables;
- every pool identity.

MEM_PRIVATE and foreign-module pages are still refused, and the upstream refusal tests still pass on the port.

Medium confidence because MEM_MAPPED has not yet been observed on the tables' own pages; live check H5 settles it.
The installed copy carrying this edit applied there with protect 0x08 and held to shutdown.

## Writes
No code memory is touched.
1. **Tier table.** 612 bytes at game.dll+0x24B5CC0, `tables.expanded.tiers`: the vanilla banners and size-weighted
   entries. Written with WriteProcessMemory (`native.write`), only after all of these:
   - the stratagem settings are loaded (PROBE slot 127 set);
   - the full pool check passes;
   - both tables hold the exact vanilla bytes;
   - `Mod.image_writable` passes over the range.

   It is read back afterwards (`arcade_state == 'expanded'`). Evidence: hero.tiers_rva, table_layout, VANILLA_TIERS,
   region_type_mapped.
2. **Group table.** 640 bytes at game.dll+0x24B5F70, `tables.expanded.groups`: group 0 empty, groups 1-8 the pool,
   group 9 empty. Same guards. Evidence: hero.groups_rva, VANILLA_GROUPS, GROUPS, TYPES, settings_rva, INFO_layout.
3. **The 76 bytes between the tables** are never written.
4. **No restore.** Upstream v1.0 has none, and game.dll .data is fresh each launch. At shutdown the mod only reads
   both tables once and logs whether they still hold the pool. The older roundtrip probe
   (`native-work/megapack_hero_roundtrip.lua`, PORT51 copy) restored all 1252 bytes exactly.

## Startup
- Install checks the loader API 1 and the pins (verify_build), then builds the tables.
- One attempt runs at load. If the settings are not loaded yet (PROBE slot null), a self-removing update hook retries
  once per frame for up to 600 s of game time, then writes once and removes itself.
- A refusal (any byte or identity mismatch) disables the mod without writing.

## Live checks: `live/hero_readonly.lua` (reads only; generated by `tools/make_probe.py`)
Run it on the ship, once with the option off and once with it on. I ran it offline against the image capture, where
H1, H2 (vanilla), H4 and H6 print the expected values.

| Line | Shows | Expected |
|---|---|---|
| H0 | mod status | "applied (108 stratagems in 8 groups; pages …)" |
| H1 | .data from the PE header | rva 0x24B5000, size 0xCDF000, tables inside |
| H2 | the tables' state | `vanilla` without the option, `expanded` with it. Group 1: vanilla 86,139,34,31,122,69; expanded starts 104,123,14,137. Tier 0 banner 0x4762C948. |
| H3 | settings and pool | slot 127 → a StratagemInfo with type 127; slot 153 non-null; pool 108, 0 failing |
| H4 | picker code bytes | as listed in the probe (identical to the image) |
| H5 | regions of both tables (start and end) | state 0x1000, type 0x40000 (or 0x1000000), protect 0x8 before the write (0x8 or 0x4 after), allocation base == game.dll |
| H6 | the old tiers address 0x263CCC0 | does not hold the tables (false) |

## Tests (`build.py --tests`; Windows LuaJIT under Wine with hdh-port's bcrypt hash-cache shim, both copies)
| Test | Port | Unmodified upstream |
|---|---|---|
| `tests/test_mod.lua` | PASS (20 tests) | PASS (20 tests) |
| `tests/compile_entry.lua` | PASS | PASS |
| `tests/test_entry.lua` | PASS | PASS |

The port's test fixtures carry the same build data, all recorded in the receipt:
- every StratagemType number in LOADOUT, MISSION, the CLASS keys, VANILLA_POOL and the refusal cases, migrated by
  name;
- synthetic records for 1..153;
- the vanilla group bytes from the new image;
- the build-number text.

`tests/game_lua.py` was not run: it is Windows-only and uses the game's old lua51.dll.

## Not verified
- The port entry has not been loaded in the game yet. Its values are the ones the installed PORT51 copy applied
  with.
- MEM_MAPPED has not been seen on the tables' own pages (H5).
- No arcade round has been played to see the new stratagems drawn.
