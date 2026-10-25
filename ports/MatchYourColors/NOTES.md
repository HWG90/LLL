# Match Your Colors v1.5 → Steam build 26088801 (offline port)

Source: `upstream-bingus/MatchYourColors` (v1.5, clean). Old build 25480438, new build 26088801
(game.dll `6D1D4D3B…C08F`, helldivers2.exe `0ACC07DE…EABE`, both re-hashed from the install).
Nothing here touched the network, the game folder, `~/.config/hd2arsenal`, the game library (read only), the
upstream checkouts, or the running game.

## Deliverables

| Path | What |
|---|---|
| `MAP.json` | 158 rows, one per build-specific constant or constant group, with the re-checked evidence and confidence, plus `code_addresses` |
| `build_myc_port.py` | `python3 -I -B build_myc_port.py [--tests]`: copies `src/` and `locales/` to `work/`, applies the changes, runs the upstream `assemble(False)`, then writes `out/entry.lua` and `out/9ba626afa44a3aa3.patch_0` (plus empty `.stream`/`.gpu_resources`) and `out/build-receipt.json` |
| `out/entry.lua` | sha256 `a77a9b125c9df9e3403357006e4360cfa4d814795fcc3d1f145dc5f027d171c7` |
| `out/9ba626afa44a3aa3.patch_0` | sha256 `283cb4954249d1cba434f9b0ff25a14a002283c11bee932ad7fb435ce898ed5d`, made by `make_archive`; one resource `mods/cowboybingus/match_your_colors` (key `7e3a7752c14b6c38`, type `a14e8dfa2cd117e2`) |
| `tools/` | The read-only analysis: `map_globals.py`, `map_fields.py`, `map_exe.py`, `field_scan.py`, `palign.py`/`ctx.py`/`fdiff*.py` (alignment views), `build_map.py` (writes MAP.json), `check_data.lua`, `check_patches.lua`, `check_engine_lazy.lua`, `posix_files.lua` (Linux test shim), `port_tests.py` |
| `evidence/` | `globals.json`, `field-pairs.json`, `exe.json`, `scans.json`, `old-global-xrefs.json` |

The build checks three things. First, the upstream `assemble(False)` still reproduces `709d05e3…`. Second, the port
entry is exactly the shipped entry with the listed changes applied. Third, there is no PORT51/compat51 text, the
upstream forbidden-name rule holds, every module and the entry compile in LuaJIT (`loadstring`), and
`check_engine_lazy.lua` passes.

## What changed (everything else is byte-identical to v1.5)

**29 data replacements** (`REPLACEMENTS` in the build script; the comments in `src/` still describe build 25480438):

- **Pins**:
  - `Addon.GAME_SHA256` and `Addon.EXE_SHA256`.
  - The disable message's build number.
  - The generated header line.
- **game.dll globals**:

  | Global | Old | New |
  |---|---|---|
  | script API | 0x3326308 | 0x2CE14C8 |
  | players | 0x3326468 | 0x2CE1618 |
  | customization / kit catalogue | 0x33264F8 | 0x2CE16A8 |
  | entities | 0x346BF98 | 0x2CE41B8 |
  | avatars | 0x3326D20 | 0x2CE1EE0 |
  | previews | 0x346D580 | 0x2E287E0 |
  | inventory | 0x3326738 | 0x2CE18E8 |
  | weapon customization | 0x3326A38 | 0x2CE1BF8 |
  | UiPreviewSystem | 0x347CE60 | 0x2E38190 |
  | network context | 0x347CEF0 | 0x2E38228 |
  | bingus_text settings | 0x3326340 | 0x2CE1508 |
  | language table | 0x37C5650 | 0x3180DE0 |
- **exe**:
  - get_engine_api: 0xa4e50 → 0xa6f70.
  - The 14 `Engine.FUNCTIONS` RVAs moved. Their table slots and the ScriptApi offsets (24/232/40) are unchanged, and so are the API ids (26 buffers, 5 resources).
- **Struct offsets that moved**:
  - Customization manager: map 2352→2360, applied 2412→2420, desired 2684→2692. Every field from +0x8E0 on moved +8.
  - Entities: unit map 0xF22EC8→0xF24990, id map 0xF1AEB0→0xF1C978, records 0xF32F18→0xF349E0, weapon catalogue 0xF12558→0xF14008 (not a uniform shift), component types 0xF12CF0→0xF147B8, deltas 0xF12E98→0xF14960.
  - Avatar records: 5532272→5532336.
  - Engine lobby in the network context: 0x1D470→0x1D478.
- **Sizes that changed with the game data**:
  - Kit piece record: 96→112 bytes. The first 96 bytes are the same; 16 new bytes are zero.
  - Weapon catalogue: 1080→1100 buckets, records at +17280→+17600, index bound 540→550.
  - **`recolor.lua` buffer 17280→17600.** This one is not in the per-file counts. With the old size, `Weapons.package` would write 320 bytes past it.
  - Weapon component types: 382→392 buckets, base 0x17E0→0x1880.
  - Paint customization component type: 271→274.
- **bingus_text `M.GAME`** (vendored): settings index 705500→705628 (+212). MYC never calls `T.observe`, so this is inert but kept consistent.

**1 code patch (not build data)**, added at the coordinator's request after the live finding that some code pages read as
PAGE_NOACCESS until first executed:

- `Engine.open` still reads get_engine_api's 9-byte prefix with `memory.read`, which is ReadProcessMemory and returns nil when the page is unreadable.
  - A readable prefix that differs disables the mod, as before.
  - An **unreadable** prefix no longer disables it. get_engine_api is then neither checked nor called at startup.
- When get_engine_api is deferred, the 6 buffers/resources functions it provides are verified and bound just before their first call: the prefix is read again, `get_engine_api(26/5)` is called, and the table slots are checked.
  - While the prefix stays unreadable, that call raises `get_engine_api unreadable`. Only that action fails; the runtime guard pauses it, and it is retried on the next call.
- The unit/mesh/material tables are pointer-value checks, so they are still checked at startup.
- `tools/check_engine_lazy.lua` simulates every branch (6 checks, PASS).

## Verified statically (MAP.json: 141 high, 17 medium, 0 low, 0 unmapped)

- **Globals.** Every RIP-relative reference sampled from the old game.dll (up to 48 per global) was migrated by a unique, unmasked instruction window. All witnesses agree, with 0 disagreements:

  | Global | Agreeing witnesses |
  |---|---|
  | script API | 33 |
  | players | 31 |
  | customization | 22 |
  | entities | 19 |
  | avatars | 37 |
  | previews | 8 (of 9 sites) |
  | inventory | 37 |
  | weapon customization | 35 |
  | UiPreviewSystem | 29 |
  | network context | 24 |
  | settings | 24 |
  | language table | 19 |

  The live game.dll capture agrees: `[game+0x2CE14C8]` = `0x142870240`, which is the exe's ScriptApi.
- **Struct offsets and strides.** Each has code witnesses in the new game.dll:
  - Functions that load each global were aligned instruction by instruction. Register-derived memory operands were paired (`field-pairs.json`).
  - Large displacements were scanned image-wide (`scans.json`).
  - Specific old/new instruction pairs are re-disassembled by `build_map.py`. Examples:
    - `add r9, 0x60` → `add r9, 0x70` (kit pieces).
    - `imul eax, edx, 0x438` → `0x44c` (catalogue buckets).
    - `cmp [r9+rdx*4], 0x10f` → `0x112` (component type), at 2 sites.
    - `(idx + 0xA2314) * 24` folds to 0xF349E0.
- **Script C API.**
  - Each exe function was mapped by a unique window or by equal masked bytes at the live-captured address (`epic-engine-live.json`; all agree).
  - Each table slot is proven in the new exe by its initializer, `lea rax,[fn]; mov [table+slot],rax`. All 14 slots are unchanged, including `visibility` at 1624.
  - Each table is the one stored into ScriptApi+24/232/40 (unit table returned by 0x1fc7d0).
  - `get_engine_api(26/5)` was walked statically and returns the same tables as the live capture.
- **Exe objects.**
  - Material bindings (+0x18 count, +0x20 array, 16-byte entries, +8 object): the `set_resource` target is identical.
  - RenderBufferApi format tables are equal (0x80820820, 0x10000000+n).
  - `create_buffer` aligned 232/233 instructions, with only table addresses changed.
  - The Lobby API functions (ScriptApi+0xF8 table) read PlayFab lobby +0x10/+0x100/+0x118/+0x120/+0x130 identically.
  - PlayFabMultiplayerWin.dll is byte-identical to the old build's.
- **Game data.** Read-only through the mod's own readers on the current install:
  - `bundles.nxa` DSAR/DSAA index: 9,725 items (was 9,715), 30 bundles.
  - Archive TOCs, texture headers and DDS/DX10 decoding work.
  - Upstream `test_parity.lua` passes on the current data: all 293 v1.5 helmets/armors, 42,660 plans and 118 capes equal the fixtures.
  - All 12 scheme LUTs, all 125 weapon-scheme LUTs and all 161 attachment units are in their listed archives, the same result as on the old install.
  - The 44 installed patch files index with 0 unreadable.
- **Tests.** Upstream `tests/` ran offline on Linux LuaJIT for the port (fixture literals remapped the same way; `tests/reference/` too) and for an unmodified upstream copy. The results are identical:
  - addon 57, install 3, idle_alloc 13, locales, cache 14, sync 50, patches 5, weapons 14, idle_equivalence 6, parity 14, bingus_text, and job 53 (on the current game data) all pass.
  - The only failures are kernel32-only checks, which fail the same way upstream: test_units 2 overlapped-read checks and test_job 1 check.

## Not verified / medium confidence (each has a live check below)

| MAP row | Why medium | Live check |
|---|---|---|
| engine.MESH_VISIBILITY 0xDC | 13/13 exe byte operands at +0xDC near +0xD8 moved unchanged, but not tied to the mesh object by dataflow | L13 |
| engine.view_layout, engine.texture_object | consumer code identical; the texture object's 24-bit render handle is a renderer internal (fails safe: "no render handle") | — |
| avatar.player_entity_flags (+20 bit 0) | 1 taint witness | L3 |
| avatar.applied/desired kit order (+0/+4/+8/+12, +4/+12/+8) | record size and readers unchanged, no field-level witness | L4 |
| avatar.V_SLOT_COUNT 5 | one `cmp edi, 5` | L8 |
| sync.JOINED 3 | the exe writes the same state values (0,1,2,3,4,9) to +0x118 | L12 |
| kits +12 name / +32 archive | header read whole; no field witness | L5 |
| weapons catalogue record +8 package | lookup aligned; field not used by game code in a witness | L14 |
| weapons.KINDS, RECORD_UNITS +8/+40/+68 | binder unchanged; +12/+96/+100 witnessed | L16 |
| weapons.PREVIEW_SLOT 3, slot +144/+152 | +128 (6) and +144 (1) witnessed, +152 not | L10 |
| weapon_data.units, appearance_data | build 25480438 measurements; items added by the update are absent (the mod's fallback applies) | — |
| albedo template/slots | only met in mods' materials | — |

Not verifiable offline at all:
- Everything in game: the real LuaJIT runtime, `ffi.C`/`ffi.load('kernel32'/'bcrypt')`, and Bingus Shared Loader v18+ (`CowboyBingusModLoader`).
- That the exe is mapped at the base the capture shows. MYC uses the module base it reads, so this does not matter.

## Data-format risks

- **Formats are unchanged**: DSAR/DSAA slim index, archive TOC (72/32/80, 0xF0000011), texture 0xC0 header + DX10 DDS, the patch-file TOC, and the shared tiler archives.
- **One content change**: cape `4dcec343`'s decal sheet `8d08eb0717651e49` has new bytes. The recolored-sheet checksums of 3 parity plans differ. The sheet still reads and recolors (format OK); only the fixture checksum is stale.
- **New content is unknown offline**: kits and weapons added by the update are not in the v1.5 fixtures. The 10 new archive items are not exercised, and `weapon_data.lua` and `appearance_data.lua` have no rows for them. The mod reads kits from memory at runtime, so they are recolored with the generic fallbacks, as v1.5 treats unlisted items.
- **Weapon catalogue and component tables are sized by the data** (1100 / 392 buckets, component type 274). A future data-only update can change these again without a game.dll change.
- **Analysis cache**: the cache header holds the build hashes, so v1.5 caches are discarded. This is expected.

## Code addresses MYC reads or calls (for your page-protection query)

MYC reads and calls **no game.dll code**. In game.dll it reads only `.data` globals and heap objects, always through `memory.read_into` (ReadProcessMemory). Exe RVAs on build 26088801:

| Use | Name | exe RVA | page(s) |
|---|---|---|---|
| **read** 9 bytes (memory.read) | get_engine_api prefix `48 83 EC 28 83 F9 01 0F 85` | 0xA6F70 | 0xA6000 |
| call (startup if the prefix reads, else on first buffers/resources use) | get_engine_api(26), (5) | 0xA6F70 | 0xA6000 |
| call | Unit.alive | 0x1F4D50 | 0x1F4000 |
| call | Unit.num_meshes / Unit.mesh | 0x1F6B70 / 0x1F6BC0 | 0x1F6000 |
| call (Hide Cape) | set_unit_visibility | 0x1FB520 | 0x1FB000 |
| call | Mesh.num_materials / Mesh.material | 0x313760 / 0x3137B0 | 0x313000 |
| call | Mesh commit (`jmp 0x520140`) | 0x3137C0 | 0x313000, 0x520000 |
| call | Material.set_resource (`jmp 0x503A60`) | 0x2DE990 | 0x2DE000, 0x503000 |
| call | create / update / destroy buffer | 0x1BD850 / 0x1BDC20 / 0x1BDD30 | 0x1BD000 |
| call | lookup_resource | 0x1BE200 | 0x1BE000 |
| call | can_get_by_id / get_by_id | 0xA2E50 / 0xA2F10 | 0xA2000 |

- The 14 table functions are verified only by the pointer values in their exe `.data` tables (data reads). Their code is never read.
- Also called: PlayFabMultiplayerWin.dll `PFLobbyPostUpdate` / `PFLobbyGetMembers` / `PFLobbyGetMemberProperty` (GetProcAddress), and kernel32/bcrypt.

## Live checks (read-only; run them yourself)

Notation:
- `game` = game.dll base, `exe` = helldivers2.exe base (0x140000000 in the 2026-10-22 capture).
- `[x]` = the u64 at x, `u32[x]` = the u32 at x.
- MYC also checks most of this itself. A wrong value disables it with a reason in `MatchYourColors.log` (e.g. `Disabled: engine function changed: alive`), or stops one feature.

- **L1 exe_prefix / code_pages.** Read 9 bytes at `exe+0xA6F70`. Expect `48 83 EC 28 83 F9 01 0F 85`. Query the protection of every page in the table above.
- **L2 script_api.**
  - `[game+0x2CE14C8]` = `exe+0x2870240`.
  - `[exe+0x2870240+0x18]` = `exe+0x28703E0` (unit), `+0xE8` = `exe+0x2872BA0` (mesh), `+0x28` = `exe+0x2870E30` (material).
  - `[exe+0x28703E0+0x720]` = `exe+0x1F4D50`, `+0x1A8` → `0x1F6B70`, `+0x1B8` → `0x1F6BC0`, `+0x658` → `0x1FB520`.
  - `[exe+0x2872BA0+8/+0x18/+0x20]` → `0x313760/0x3137B0/0x3137C0`.
  - `[exe+0x2870E30+0x80]` → `0x2DE990`.
  - buffers table `exe+0x286E4F0`: `+0x60/+0x68/+0x70/+0x78` → `0x1BD850/0x1BDC20/0x1BDD30/0x1BE200`.
  - resources table `exe+0x286E390`: `+0x30/+0x40` → `0xA2E50/0xA2F10`.
- **L3 global_players** (ship or mission). `P=[game+0x2CE1618]` is a heap pointer.
  - `u32[P+0x84]` = local player count, 1 (≤4).
  - `E=[P+0xE8]`: `u32[E+8]` = local player entity id, and `byte[E+0x14] & 1` = 1.
  - Map at `P+0xD0` is `{u64 data, u32 capacity (power of 2), u32 0xFFFFFFFF, u32 multiplier}`. Looking up the entity id gives index i < 8.
  - `u32[P+0x3A8+32i]` = Helldiver unit (nonzero). `u32[P+0x3B4+32i]` = UI slot 0..3. `[P+0x2C8+56i]` = own peer id (= L11's local peer).
- **L4 global_customization.** `C=[game+0x2CE16A8]`.
  - Map header at `C+0x938`, same shape as L3. Look up the player entity id to get r.
  - `u32[C+0x974+68r ..+12]` = body (0/1), helmet, cape, armor kit ids of what you wear. They should equal the kit ids in L5.
  - `u32[C+0xA84+64r+4/+8/+12]` = helmet, cape, armor of your loadout.
  - **Negative control**: the old offsets `C+0x96C` / `C+0xA7C` should *not* line up with your kits.
- **L5 kit_catalogue.** `u32[C+8]` ≈ 422 (count), and `[C+0]` → array of kit pointers K.
  - `u32[K+0]` = kit id. `u32[K+0x28]` ∈ {0,1,2}. `u32[K+0x38]` ≤ 8 bodies at `B=[K+0x30]`.
  - Per body j: pieces `[B+24j+8]`, count `u32[B+24j+0x10]`. Piece n is at `pieces+112n`; its bytes 96..111 are zero, and with a 96 stride piece 1 would not start with a unit name.
  - `[K+0x20]` (16 hex digits) is an item name in `bundles.nxa`.
  - Already partly proven live in `transmog-piece-layout-live.json`.
- **L6 global_entities.** `N=[game+0x2CE41B8]`.
  - Map at `N+0xF24990`: look up your Helldiver unit (L3) to get e.
  - At `N+0xF349E0+24e`: u64 +0 = `0x4D1C334D294DFA97`, u32 +8 = avatar id, `byte +0x14 & 1` = 1.
  - Map at `N+0xF1C978`: the avatar id looks up to the same e.
- **L7 global_avatars.** `A=[game+0x2CE1EE0]`.
  - `u32[A+0x6C]` = avatar count. Map at `A+0xF8`: the avatar id looks up to i < count.
  - 30 u32 at `A+0x546B8C+440i` are unit refs: array 0 slot 0 = helmet unit, slot 1 = cape unit, all nonzero or 0xFFFFFFFF.
  - Negative control: `A+0x546B4C+440i` should not look like that.
- **L8 global_previews.** `V=[game+0x2E287E0]`. 5 slots at `V+0x820+0x888s`: one has `[+0]` = own peer id, and `u32[+0x40]` ≤ 16.
- **L9 global_ups** (Armory open). `U=[game+0x2E38190]`.
  - `u32[U+0xC508]` ≤ 8, and `u32[U+0xC50C]` has the bit of your UI slot.
  - The record at `U+0xC008+160s` holds: `+8` body unit, `+0x88` body type, `+0x8C` armor, `+0x90` helmet, `+0x94` cape kit ids (as shown, hovered included).
- **L10 weapon_preview** (Armory weapon panel, slot 3 = `U+0x13B60`).
  - `u32[+0]` = weapon unit, and `[+128]` = weapon id.
  - `u32[+144]` ≤ 10, followed by that many u64 customization ids at `+152`. Change a paint and the list changes.
- **L11 global_network.** `NC=[game+0x2E38228]`.
  - `[NC+0xB398]` = own peer id. `u32[NC+0x16390]` = session peers 1..4.
  - Entries at `NC+0x16398+32i` hold `{u64 peer, …, u32 +20 UI slot 0..3}`.
- **L12 lobby** (joined lobby; the ship with a squad).
  - `L=[NC+0x1D478]` is a pointer, and `PF=[L+0x10]`.
  - `u32[PF+0x118]` = 3 when joined, and `[PF+0x120]` is a nonzero handle.
  - `[PF+0x130]` → a C string = your peer id in hex without leading zeros.
  - `u32[PF+0x100]` = member count.
  - Negative control: `[NC+0x1D470]` is not that pointer.
- **L13 mesh_visibility** (Hide Cape).
  - Read-only: with Hide Cape on, `MatchYourColors.log` shows `cape hidden` once per cape and does **not** repeat "the game showed … cape again" every 30 frames. A wrong offset would re-hide constantly.
  - With a mesh pointer from any probe: `byte[mesh+0xDC]` = 0xFF shown, 0 hidden.
- **L14 weapon_catalogue.** `T=[N+0xF14008]`.
  - 1100 buckets of 16 bytes `{u64 weapon id, u32 index}`. Every index is < 550, and your primary's id (its entity resource, L6 record +0) is present.
  - The record at `T+17600+32·index` has `[+8]` = a package archive name present in `bundles.nxa`.
  - The default record is at `T+0x8980`.
- **L15 weapon_types.**
  - `W=[N+0xF147B8]` has 392 buckets. Your primary's id, probed from `id % 392`, gives an index, and the component is at `W+0x1880+4872·index`. Its `[+0x78]` is the default optic unit name, or 0 without one.
  - `D=[N+0xF14960]` has `u32[D+8]` buckets, and ops at `[D+0x20]` are 12 bytes each `{u32 type, …}`. Type 274 occurs (paint), and 271 means something else now.
- **L16 weapon_paint / global_weapons** (painted weapon in hand).
  - Inventory `I=[game+0x2CE18E8]`: map at `I+0x28` → row k. `[I+0x50]+48k` holds `+0/+4/+8` weapon entity ids and `+0x1C` the held slot.
  - Weapon customization `WC=[game+0x2CE1BF8]`: map at `WC+0x2B8` → copy k at `[WC+0x2F8]+4872k`. That copy holds:
    - `+0x78/+0x80/+0x90/+0x98/+0xA0/+0xC0` attachment unit names (0 when none).
    - At `+200`: 10 rows of 40 bytes `{u32 material slot, u64 LUT +8}`.
    - At `+600+408e`: `u32 kind` ∈ {0,1,2,4,5}.
  - Map at `WC+0x278` → record j at `[WC+0x2A0]+128j`: u32 `+8/+12/+40/+68/+96` are attachment unit ids (0, 0xFFFFFFFF or live units), and `+100` is the underbarrel entity.

If any check fails, MAP.json names the rows it covers (`live_check`).
