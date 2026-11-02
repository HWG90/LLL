# Know Your Constellation v4.1.1 → Steam build 26088801 (offline port)

Source: `upstream-bingus/KnowYourConstellation`, git tag v4.1.1; all 53 `source_sha256` entries of
`components.lock.json` match (the pinned copy under `VanillaPlusMegapack/components/` is identical).
Old build 25480438, new build 26088801 (game.dll `6D1D4D3B…C08F`, exe `0ACC07DE…EABE`).
Nothing here touched the network, the game folder, `~/.config/hd2arsenal`, `<steam-library>`, `upstream-bingus/` or the
running game. Module `mods/cowboybingus/enemy_intelligence`, pack recipe WRAPPERS.

## Deliverables

| Path | What |
|---|---|
| `MAP.json` | 55 rows (49 high, 5 medium, 1 low, 0 unmapped), every one `feeds_write: false`, each with its witnesses and the exact edit |
| `build.py` | `python3 -I -B build.py [--tests]`: copy, remap, regenerate the roster table, assemble, reproduce, archive, compile, test |
| `out/9ba626afa44a3aa3.patch_0` | sha256 `3bc184b6…e6`; ONE resource, `mods/cowboybingus/enemy_intelligence` (key `1d106bd89d3a79ac`); plus empty `.stream`/`.gpu_resources` |
| `out/mod.lua.main` | the resource: `struct.pack('<II', len, 2)` + plaintext wrapper, sha256 `164e2474…101e` |
| `out/enemy_intelligence.lua` | the plaintext wrapper (GC64-loadable), sha256 `772a0c77…b70a` |
| `out/build-receipt.json` | hashes, every edit with its line, the reproduction result, the roster report, test results |
| `live/kyc_readonly.lua` | read-only probe K0–K13 (LLM eval env) |
| `tools/` | `map_globals.py`, `scan_values.py`, `table_witness.py`, `natives.py`, `site.py`, `pairsite.py`, `path_fields.py`, `root_fields.py`, `range_scan.py`, `faction_tables.py`, `gen_roster.py`, `build_map.py`, `port_tests.py`, `probe_offline.lua` (+ `lib.py`/`align.py`/`palign.py` copied from myc-port) |
| `evidence/` | `globals.json`, `scans.json`, `table-witnesses.json`, `natives.json`, `old-global-xrefs.json`, `roster_v411.json`, `roster_data_26088801.lua`, `roster-report.json` |

## Reproduction of the shipped option

The unmodified assembly (upstream `scripts/module.py wrapper()` with the 25480438 pins) compiled with the workspace
LuaJIT `-bsdW` gives envelope sha256 `505E2E8E…0DC5` = the lock's `resource_sha256`, and the pack's
`discoverable_resource` form of that bytecode equals the shipped v26 option resource (`ED8123AD…89B6`, the v26
folder's `1d106bd89d3a79ac`) byte for byte. `build.py` checks both on every run.

The port ships the plaintext wrapper in the same envelope instead of `-bsdW` bytecode (the game VM is GC64). No
PORT51/compat51 adapter, no `cffi`; the upstream `check_sources` rule (no write/protect/thread/network API in any
`src/*.lua`) passes on the port. `loadstring` compiles it in `runtime-modules/build/linux/LuaJIT/src/luajit` (GC64).

## Writes

None. KYC reads only through `ReadProcessMemory` (`src/read_api.lua`, private `hd2kyc_*` names); it reads no code
bytes at all, so the no-access code page rule needs no patch here. It never queries or changes protection.

## What changed (35 source edits + the regenerated roster table; everything else byte-identical to v4.1.1)

- **game.dll globals** (all by RIP windows, 0 disagreements): UI state 0x347CE28→0x2E38160 (17 witnesses),
  session 0x347CEF0→0x2E38228 (24), root 0x3326340→0x2CE1508 (4, plus brief/MYC), matchmaking 0x347CE80→0x2E381B8 (34),
  UI event manager 0x3326E68→0x2CE2040 (10), board 0x347CEE8→0x2E38220 (33), session2 0x3326AA0→0x2CE1C68 (10),
  definitions 0x347CD98→0x2E380D0 (42), war effects 0x346D518→0x2E38278 (29), override config 0x347CDF8→0x2E38128 (32),
  difficulty table 0x328D2A0→0x2C44280 (7), category table 0x32E98E0→0x2CA1F40 (29), tag table 0x21E1920→0x2069D50 (3),
  mission configs 0x3773420→0x312EB50 (25), font 0x3772268→0x312D998 (5 incl. global-3772268.json), material owner
  0x37C5478→0x3180C08 (24), atlas 0x3772EE8→0x312E618 (1 + same 0xC80 distance to the font; font initializer
  0xF553C0→0xDE52F0 is instruction-identical), bingus_text M.GAME as in the MYC port (705500→705628, 0x37C5650→0x3180DE0).
- **Struct offsets that moved**:
  - Game state root grew +0x80 between +0xB70 (unchanged) and +0x106C: controller +0xAE288→+0xAE308 (17 scan + 52 taint
    witnesses), loaded packet +713400→+713528, gate flags +4205→+4333 and +4217→+4345 (the same gate function aligned).
  - Session gate flag +92134→+92142 (4/4 readers; matches the brief's hotjoin +8).
  - Session2 joinable fallback +5633600→+5630328 (5+24 aligned witnesses, writer and readers).
  - UI event manager registries: two event kinds were inserted below 0xE2, so kinds 226/229/235 → 228/231/237 and the
    registries moved +0xF0: war-table panel +25224→+25464, briefing panel +25272→+25512, briefing-descriptor list
    count/rows +26184/+26192→+26424/+26432 (registration functions with the same list sets, the dispatcher and the
    descriptor consumer aligned; owner +1072 descriptor unchanged).
  - Controller +648 (level pointer) → +664: **medium**, see below.
- **Enemy tag enum (game data compiled into game.dll)**: the native tag table grew 32→33. `BugAcid` was renamed
  `GM_BugAcid` in place (index 2), and `GM_BugDefiler` (0x35E13F9E) was inserted at native 12, so old natives 12..31 are
  13..32 (names recovered from game.dll strings: hash = high 32 bits of MurmurHash64A(name)). Edits: the table read
  (33 entries, buffer 128→132, loop 0..32), `resolve.from_native` (2..11 → n-1, 12 → new authored id 32, 13..32 → n-2,
  1 → 31) and the authored-id bound 31→32. Every authored id 1..31 still names the same tag hash; the difficulty table
  and all 120 mission configs decode to the same authored ids through the new mapping (the one real data change: the
  Terminid base draw no longer offers tag 1, now a subfaction).
- **`src/roster_data.lua` regenerated** (the upstream generator is not public): `tools/gen_roster.py` decodes the native
  faction descriptors (11 {pointer, count} spans each: units 128 B, swaps 48 B, groups 280 B in pools 2/4/5/6/9), with
  the layouts read by the natives KYC mirrors (group builder instruction-identical, tag predicate byte-identical, group
  weight / replacement chain identical except a moved global's fields, clamp identical). From the old capture it
  reproduces upstream's `roster_data.lua` **byte for byte**; hand-curated parts are carried by identity (names by unit
  resource hash, tags by tag hash, `summoned` by family hash, checked). Changes in 26088801:
  - Terminids: 45→47 units, 21→26 swaps, 122→127 groups (5 for GM_BugDefiler, tag 32), two new families; changed
    swap difficulty ranges and two garrison rows.
  - Automatons: counts unchanged, content equal.
  - Illuminate: 44→45 units (new family 0xA3DECC72), 151→156 groups, weight changes (1→0.7/0.8), changed tags.
  - **Two new Terminid unit resources (0x8AB62629DB3D6AC8, 0x662A7907531B45E5, the Defiler groups' units) have no
    Helldivers-wiki name offline**: they get names index 0, the table's existing "not displayed" value, so the forecast
    omits them. Authored tag 32 has no title in `model.lua`, so the headline omits GM_BugDefiler. Adding names/titles
    would be new text, not build data; not done.

## Verified statically

- Every global and moved offset above has agreeing instruction witnesses; `tools/build_map.py` re-disassembles every
  hand-picked old/new pair (0 failures) and recomputes the data comparisons.
- Unchanged and witnessed: UI stack +0x429C (HDH port, live-verified) and screen ids 14 Loadout / 15 Hologram (menu
  presenter name tables 0..29 equal); board offsets (+1548952..+1548964, +1012352 ops 92 B × 110, +1053752 data,
  +1197132, +2044424/+2053224 ≤ 440, +2064401, +4286668, +0x4168D0, +0x1F8908); campaign data offsets and strides
  (280/304/2496/44/24 …); matchmaking layouts, record 1560, +1456, +944; difficulty 816 / +272 / 276/372/468 /
  564/600/636; definitions 52 B, +53248, categories 40/72, kind 13, +24/+28/+36/+44; category table 168 × 14, +9;
  override maps +73848/+49232, 48 B entries; mission config 896, +0x34, +0x360, +0x14; LCG and exclusion-key constants
  (exclusion-key natives instruction-identical).
- Tests (`build.py --tests`): all 16 upstream suites pass on the port and on unmodified upstream (13 in Linux LuaJIT;
  `test_ffi_names` ×3 need kernel32/bcrypt and run in the workspace Windows LuaJIT under Wine with a private prefix).
  The port's tests get the same build-data remap as `src/` (hex globals, moved offsets and kinds, the 33-entry tag
  table, native tag ids written into fixtures, the from_native assertions, the roster check's id bound 31→32 and the
  v4.1 reference copy used by `test_idle`), each listed in `tools/port_tests.py` and the receipt. `test_roster`'s
  wiki cross-checks pass on the regenerated table.

## Not verified (medium/low) — each has a live check

| MAP row | Why | Live |
|---|---|---|
| `mission.level` controller +648 → +664 (medium) | no code reads controller+0x288 (v4.1.1 measured it); the controller object grew (+0x270→+0x280, +0x2A8→+0x2B8, +0x2C8→+0x2D8) and a struct copy that fills +0x288 writes +0x298 in the new build, but that the copy's record is the controller is not proven | K3 |
| `presentation.panel_widgets` 349072/31232/280528/526048 and briefing owner +8 (low, kept) | no instruction carries these displacements; the owners are the subscribers of the moved registries | K10 |
| `presentation.widget_layout` (medium) | UI library functions are instruction-identical, but no field-level witness | K10 |
| `mission.stamp_layout`, `mission.descriptor_layout`, `mission.war_effects_layout` (medium) | strides and most fields witnessed unchanged; some small fields (+40, +208, +84/+92) have none | K3, K2, K7 |

All of these fail safe: KYC reads through ReadProcessMemory, and wrong offsets give "hidden: … unavailable", a
withheld (incomplete) report or no panel, never a write.

## Live checks (read-only; `live/kyc_readonly.lua`, LLM eval env)

Run on the war table with a mission highlighted, on the briefing/loadout screen, and once in a mission.
`G` = game.dll base; `[x]` = u64 at x.

- **K0** `EnemyIntelligence.status` (or `EnemyIntelligence.log`): `ready` then `visible map … composition rules resolved`;
  never `disabled: unsupported game build`.
- **K1** `U=[G+0x2E38160]`, depth `u32[U+0x42B0]` 1..5, top `u32[U+0x429C+4(depth-1)]` = 15 on the war table, 14 on
  the briefing/loadout.
- **K2** `B=[G+0x2E38220]`, `R=[G+0x2CE1508]`, `C=[R+0xAE308]` heap pointer (old `[R+0xAE288]` is not that pointer).
  Highlighted op `u32[B+1548960]` < 110; descriptor `B+0x4168D0`: faction byte +8 ∈ 2..4, difficulty +9 ∈ 1..10,
  mission u16 +26 < 256; once loaded, `C+8` holds the same identity bytes.
- **K3** `L=[C+664]` heap pointer; `u32[L+9160288]` ≤ 3 explicit tags (natives ≤ 32); stamp count `u32[L+18510124]`.
  Negative control: `[C+648]` should not show that shape. If K3 fails and `[C+648]` passes, the row is wrong (fix: 648).
- **K4** `M=[G+0x2CE2040]` (briefing screen): `u32[M+26424]` ≥ 1; a row at `M+26432+16i` with kind 237 whose owner +1072
  descriptor has the selected faction/difficulty/mission type.
- **K5** gate flags `byte[[G+0x2E38228]+92142]`, `byte[R+4333]`, `byte[R+4345]` = 0 in normal play.
- **K6** joinable hover: `[G+0x2CE1C68]+5630328` id/group, `[G+0x2E381B8]` counts at +1253440/+1409448/+1487456
  ≤ 100/100/50; board joinable count +2053224 ≤ 440.
- **K7** campaign: planets `u32[B+1197132]` ≤ 512, current `u32[B+1053752+495200]` = `u32[B+1548952]`; static +24 hash,
  dynamic +36 faction; definitions `u32[[G+0x2E380D0]+53248]` ≤ 1024; war-effect entries counts ≤ 5.
- **K8** difficulty table `G+0x2C44280+816(d-1)`: draws +272 = 1; Terminid candidates natives {3,4,6,8,7} (offline
  dry run against the capture prints exactly this).
- **K9** mission config `G+0x312EB50+896·type`: +0x34, marker `857c2cd17f827849` on Horde types; override maps at
  `[G+0x2E38128]+73848/+49232`: capacity a power of two.
- **K10** registries: `M+25464` = {1, owner, kind 228} on the war table; `M+25512` = {1, owner, 231} on the briefing.
  Widgets: map `owner+349072` (and planet `+280528`, preview `+526048`), briefing `owner+31232`: flags bit 0x10,
  opacity +84 ≈ 1, scale +100 ≈ +140 in 0.3..4, size +36/+40 × scale ≥ 200×40 when the native panel shows; briefing
  owner +8 = 0 on the briefing tab. Font/material/atlas hashes nonzero. Old registries +25224/+25272 must not hold
  kinds 228/231. **If the widgets fail, the panel will not show; report the owner and the probe output.**
- **K11** tag table `G+0x2069D50`: [2] 0x22E4FCAC, [12] 0x35E13F9E, [13] 0x9FD5943A, [32] 0xBA586F51, [33] 0xE09AD33D
  (static; the offline dry run already shows this).
- **K12** forecast content (no probe): on a Terminid Defiler mission the panel lists the usual enemies; the two new
  Defiler units are not listed (no name); on Illuminate missions counts follow the new table.
- **K13** Text Language: index `u32[R+705840]` < 15, record `[G+0x3180DE0+8·idx]` +8 → `us` for English.
