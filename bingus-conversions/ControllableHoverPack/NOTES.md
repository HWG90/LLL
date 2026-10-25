# Controllable Hover Pack v1.8.1 → Steam build 26088801 (Megapack option, offline port)

**Status: BLOCKED. Do not install yet.** Everything is mapped except one item: the offset of the hover-duration field that the mod writes (component +0x9c). There is no new-build code witness for it, so `build.py` puts the archive in `out/BLOCKED/` and not in `out/`. Live check **L5** settles it (see "Unblocking").

- **Source:** the pinned copy `upstream-bingus/VanillaPlusMegapack/components/ControllableHoverPack`. Both it and `upstream-bingus/ControllableHoverPack` (git tag `v1.8.1`) match every `source_sha256` in the lock.
- **Builds:** old 25480438, new 26088801. The install was re-hashed read-only: game.dll `6D1D4D3B…C08F`, exe `0ACC07DE…EABE`.
- **Nothing touched:** no network, no game folder, no `~/.config/hd2arsenal`, no writes under `<steam-library>`, no upstream checkout, no running game. Nothing was installed.

## Deliverables

| Path | What |
|---|---|
| `MAP.json` | 30 rows, written by `tools/build_map.py`. Counts: 25 high, 5 medium, 0 low or unmapped. 9 rows feed a write. `blocked: ["settings.duration"]`. `witness_check_failures: []`. Every instruction witness is re-disassembled at build time, and the page each one sits on is checked to be decrypted code. |
| `build.py` | `python3 -I -B build.py [--tests]`. Steps are in the docstring. |
| `out/entry.lua` | The port resource body: `-- HD2-Addon: mods/cowboybingus/hover_pack_cancel` followed by the plaintext `hover_source()`, produced by BingusSharedLoader `build_addon.entry_source`. |
| `out/wrapper.lua`, `out/wrapper.diff` | The assembled source, and its diff against the unmodified assembly. 14 lines differ: 13 replacements plus the install line (pins and revision). |
| `out/BLOCKED/9ba626afa44a3aa3.patch_0` (+ empty `.stream` / `.gpu_resources`) | Holds one resource, `f58c6742a5198ab4` (`mods/cowboybingus/hover_pack_cancel`), type `a14e8dfa2cd117e2`, version-2 envelope, 75893 bytes. It does not contain the shared stub. Made with BingusSharedLoader `make_archive` and round-tripped. A `DO-NOT-INSTALL.txt` sits beside it. |
| `out/build-receipt.json`, `out/TESTS.json` | Hashes, edits, reproduction proof, LuaJIT check and test results. |
| `live/hover_pack_cancel_readonly.lua` | Read-only probe for L0–L5, in the LLM eval env. `tools/mock_probe.lua` runs it offline against synthetic memory. |
| `tools/` | Read-only analysis: `lib.py`, `align.py`, `show_pair.py`, `map_globals.py`, `map_fields.py` (from hdh-port), plus `value_map.py`, `avatar_block.py`, `pages.py` (opaque-page classifier), `template.py`, `template_fields.py`, `find_imul.py`, `identical.py`, `listing.py`, `sbs.sh`, `q.py` and `build_map.py`. |
| `evidence/` | `globals.json`, `field-pairs.json`, `old-global-xrefs.json`, `value-map.json`, `avatar-block.json`, `identical-functions.json`, `override-template.json`, plus aligned listings `listing-a63790.txt` (jump-pack routine) and `listing-jm-init-9b7c10.txt` (manager initialiser). |

Rebuild:

```sh
cd tools
python3 -B map_globals.py && python3 -B map_fields.py 150
python3 -B value_map.py 0x1238 0xf80 0xa7aec 0x1b68 0x53d900 0x3a8 0x118 0xf12cb8 0xf22ec8 0xf32f18
python3 -B avatar_block.py && python3 -B avatar_block.py --bits
python3 -B identical.py && python3 -B build_map.py
cd .. && python3 -I -B build.py --tests
```

## Packaging (GC64)

- **What the pack did:** `compile_resource(hover_source())` ran `luajit -bsdW`, producing non-GC64 FR1 bytecode. `discoverable_resource()` then wrapped it as `loadstring("\027LJ…")`. The GC64 game VM cannot load that.
- **What the port ships:** the plaintext `hover_source()` as a discoverable entry, via the loader's own `entry_source` (declaration line + source).
- **Reproduction check:** `build.py` runs the unmodified copy through the pack's real `compile_resource()`, using the vendored non-GC64 LuaJIT 2.1 ROLLING (`runtime-modules/vm-poc/work/runtime/linux/LuaJIT/src/luajit`).
  - It reproduces the lock `resource_sha256` (`3EA55710…`).
  - `discoverable_resource()` of it equals the shipped v26 option resource byte for byte (sha256 `109e90bf…f797`).
- **What the edits are:** only constants, the archive pins, and the revision label `v1.8.1-26088801`. There is no PORT51/compat51 text and no `require('cffi')`; the build refuses either.
- **GC64 check (`string.dump` flags 8):** `loadstring` compiles the entry. A smoke run with a loader stub reaches the Windows adapter. On Linux that fails inside the mod's own pcall and becomes its status; nothing installs.

## What changed

| MAP row | Site | Old | New |
|---|---|---|---|
| archive.EXE_SHA / GAME_DLL_SHA | pack `scripts/archive.py` → `install{…}` | `F5FEE03D…` / `2E2C3B7C…` | `0ACC07DE…` / `6D1D4D3B…` |
| hover.mission_rva | hover_data 102 | 0x33266a0 | 0x2ce1850 |
| hover.player_manager_rva | hover_data 111 | 0x3326468 | 0x2ce1618 |
| hover.entities_rva | hover_data 123, settings 57 | 0x346bf98 | 0x2ce41b8 |
| hover.entity_map | hover_data 124 | +0xf22ec8 | +0xf24990 |
| hover.entity_records | hover_data 127 | +0xf32f18 | +0xf349e0 |
| hover.avatar_manager_rva | hover_data 136 | 0x3326d20 | 0x2ce1ee0 |
| hover.equipment_rva | hover_data 149 | 0x3326738 | 0x2ce18e8 |
| hover.jump_pack_rva | hover_data 164, settings 18 | 0x3326bb8 | 0x2ce1d78 |
| hover.attachment_rva | hover_data 183 | 0x3326dc0 | 0x2ce1f88 |
| **hover.movement_flags** | hover_data 195 | am+0x53d900+ai\***0x1238**+**0xf80** | am+0x53d900+ai\***0x1240**+**0xf88** |
| settings.resource_table | settings 58 | owner+0xf12cb8 | owner+0xf14780 |

The avatar movement block grew by 8 bytes, and the flags qword moved with it. A uniform shift would have been wrong here: 0x53d900 itself is unchanged.

## Evidence (summary; MAP.json has the full witnesses)

### Globals

All seven globals were mapped from up to 64 migrated reference windows each, with exact windows first:
- mode: 51/0
- players: 47/0
- entities: 42/0
- avatars: 47/0
- equipment: 47/0
- jump packs: 17/2
- attachments: 45/2

The dissenting jump-pack votes are explained:
- One is a neighbouring store in the global initialiser.
- One is a template duplicate: old 0x9b8780 and 0x545ae0 are the same code, and the new build has one copy.

The jump-pack manager is also pinned by its construction site. It sits at allocation offset 0xeb63f8 (old) / 0xeb7ca8 (new), and the next object starts at +0xa8 in both builds.

### Fields

These are paired over 570 aligned functions:
- mission +8 / +0x40
- player +0x84 / +0x88 / +0xe8 / +0x3a8
- player record +0x14 bit 0
- avatar manager +0xf8 / +0x6c / +0x110
- equipment +40 / +64 / +80
- jump pack +12 / +16 / +20 / +32 / +56 / +80
- attachment +32 / +64

The 1..7 mission gate (`dec eax; cmp eax, 6`) is byte-identical at new 0x386e3b.

Strides were confirmed in identical-body functions:
- equipment and attachment rows are 48 bytes (new 0x78018b, 0x88d038)
- jump-pack state is 5 bytes (new 0xb6f1b8)

The backpack at row +12 is semantically witnessed in decrypted new 0xa7f170. It reads row +0xc and calls the jump-pack component getter 0x515e10.

### Avatar block

93 avatar-manager functions were aligned:

| Constant | Old → new | Votes |
|---|---|---|
| 0x53d900 | unchanged | 56 |
| stride 0x1238 | 0x1240 | 86 |
| +0xf80 | +0xf88 | 117 |
| +0xf88 | +0xf90 | 115 |
| 0x150 | unchanged | 43 |
| stride 0xa7aec | unchanged | 79 |
| +0x1b68 | unchanged | 17 |

Across those functions, 959 bit-mask and bit-index immediates were compared and 0 changed.

The jump input is the input helper's pair (2,15). The helper is new 0x58e860. All 13 of its table entries return the high word (slot 15), and new 0xa7f170 reads held time at +0x1b70 = +0x1b68+8.

### Resource and component layout

- The resource table moved from 0xf12cb8 to 0xf14780. This is witnessed by the decrypted fallback (new 0x5158f0: 6 entries of 16 bytes, records 0x118 at +0x60) and the modifier stub (new 0x9cb2c0: default record at +0x3a8).
- The 280-byte record size is witnessed by `imul 0x118` in the new getter, initialiser and fallback.
- The avatar hash `0x4d1c334d294dfa97` is a code immediate in both builds.

### Override storage (the write destinations)

The decrypted new manager initialiser (0x9c989b) aligns 364/368 with the old one (0x9b7c10), and every field displacement is equal:
- +4 capacity = 0x20
- `imul 0x118` → +0xa0 records
- +0x60 forward map (cap 0x40, mult 2)
- +0x80 reverse map (cap 0x40, empty -1, mult 2)

The new getter 0x515e10 reads +0x60/+0x68/+0x6c/+0x70/+0xa0.

+0x98 (count) gets its meaning from the old removal 0x9b8930. Its new copy is on an opaque page. The reverse map ends at +0x94, records sit at +0xa0, and the manager is 0xa8 bytes in both builds, so the dword count can only be at +0x98.

### Encrypted pages

The new jump-pack physics and removal code sits on pages 0x9c5000–0x9c8fff and 0x9ca000. These are still encrypted (opaque) in all three captures (`game-26088801.dll`, `-earlier-session`, `-file-mapping`) and in `diverkit-port/game-live-text.bin`. `tools/pages.py` classifies them: about 25% of decodes are impossible instructions, against under 1% on code pages. No witness is taken from an opaque page.

## Memory writes (`settings.lua`; the mod makes no native calls)

These writes happen only on a cancellation (a fresh press of jump during powered hover) and on the restore after it. They first resolve the pack afresh from the registry roots. The adapter checks that every destination is committed, private, read/write data, with a 280-byte limit.

### Creating the per-pack override (only when the pack has none yet)

| Write | Destination | Value | Evidence for this build |
|---|---|---|---|
| W1 | records(+0xa0) + 280·n, 280 bytes | copy of the shared hover record from entities+0xf14780 | +0xa0 and 280: init and getter **high**. Source table: fallback and stub **high** |
| W2 | reverse map (+0x80) slot for n, 8 bytes | {n, pack id} | init 0x9c989b **high** |
| W3 | +0x98, 4 bytes | n+1 | structural + old removal **high** |
| W4 | forward map (+0x60) slot for pack, 8 bytes | {pack id, n} | init and getter **high** |
| (guard) | n < cap (+4) | | init sets +4 = 32 **high** |

### The cancellation itself

| Write | Destination | Value | Evidence for this build |
|---|---|---|---|
| W5 | override record +0x9c (+156), 4 bytes | 1/1024 (later restored to the original) | **MEDIUM: BLOCKED.** No decrypted new code reads +0x9c. The old physics 0x9b4790 compares it with the airborne time. +0x98, +0x99 and the record size are unchanged in decrypted new code. |
| (guard) | record byte +0x99 must be 1 | | offset read in new 0xa7f170. Meaning (timed hover) is old-only: **medium** |

Because W5 is the mod's whole function, the option stays blocked. W1–W4 are only reached on the way to W5.

## Read-only live checks (`live/hover_pack_cancel_readonly.lua`)

Run the probe in four situations:
1. On the ship.
2. In a mission wearing the **LIFT-860 Hover Pack**, standing.
3. While hovering with the jump key held.
4. Right after the hover runs out.

What each line should show:

- **L0:** `HoverPackCancel` status, if visible. Otherwise read `ControllableHoverPack.log`.
- **L1, mission state:** game.dll+0x2CE1850 → +8 is 0 on the ship and nonzero in a mission; +0x40 is in 1..7.
- **L1, players:** game.dll+0x2CE1618 → +0x84/+0x88 are 1..4; +0x3a8 is the local unit (not 0x7FFF in a mission).
- **L1, avatar record:** its index comes from entities(0x2CE41B8)+0xF24990. The record at +0xF349E0+24·i has hash `0x4D1C334D294DFA97`, owned = 1.
- **L1, avatar manager:** slot +0x110+8·i points at that record.
- **L1, movement flags:** at avatars+0x53D900+i·0x1240+0xF88, during hover expect +12 bit 2 = 1, bits 4/5 = 0, +8 bit 31 = 0. The line also prints the old-stride reading for contrast.
- **L1, jump input:** slot 15 held time is 0 when released and grows while jump is held.
- **L3, equipment:** row identity → avatar record; backpack id at row +12.
- **L3, jump-pack registry:** the pack's entry hash is `0x5EC80F4F1CDB66CF` (this confirms the **medium hover_hash row**), id = backpack id, owned = 1.
- **L3, attachment:** holder = avatar entity.
- **L4, state bytes** (confirms the **medium state_bytes row**):
  - standing: `0 …`
  - powered hover: `1 0 1 0 1`
  - after natural expiry: `1 0 1 0 0`
  - near the ground: `1 1 …`
- **L5, decides the block:**
  - jump packs +4 = 32
  - +0x98 between 0 and 32
  - maps +0x60/+0x80: capacity 64, multiplier 2, reverse empty 0xFFFFFFFF
  - records region `protect 0x4, state 0x1000, type 0x20000`
  - the shared resource table entities+0xF14780 lists the hover hash with index < 3, and its record shows **+0x99 = 1 and +0x9c = 6.0000**: the six-second hover duration the mod's upstream measured. If the pack already has an override, its +0x9c is printed too.

## Unblocking

If L5 shows the hover record with +0x99 = 1 and +0x9c = 6.0 seconds, write `live/accepted.json` with the observed values. Ideally also check the timing: in L4, a natural hover should expire after about 6 s. Use this shape:

```json
{"settings.duration": {"confirmed": true, "new": "+0x9c", "observed": {"+0x9c": 6.0, "+0x99": 1, "table": "entities+0xF14780"}},
 "settings.mode_byte": {"confirmed": true, "observed": {"+0x99": 1}},
 "hover.hover_hash": {"confirmed": true, "observed": "0x5EC80F4F1CDB66CF"},
 "hover.state_bytes": {"confirmed": true, "observed": "1 0 1 0 1 / 1 0 1 0 0"}}
```

Then run `python3 -B tools/build_map.py && python3 -I -B build.py --tests`. Confirmed medium rows become high, with the live reading as their witness. The archive then goes to `out/9ba626afa44a3aa3.patch_0`.

A stronger alternative to the live reading is a read-only dump of game.dll pages 0x9c5000–0x9c8fff after a hover flight, the same way the Quaternion pages were dumped (`runtime-modules/live-load/2026-10-24/*_page_dump.lua`). That would let the new physics routine be aligned with old 0x9b4790.

## Tests (`out/TESTS.json`)

These are the component's eight suites, run the way its own `scripts/build.py` runs them:
- the pure-Lua suites on the GC64 Linux LuaJIT;
- `snapshot`, `windows_api` and `module` on the workspace Windows LuaJIT under Wine, with a private prefix.

`windows_api` also needs the hdh-port environment shim: Wine's bcrypt faults, which also happens with unmodified upstream, so the module-hash cache is seeded.

| Run | Result |
|---|---|
| unmodified copy | all 8 pass |
| port with fixtures remapped by the same map (test text only: old addresses → new) | all 8 pass |
| port with the original fixtures | cancel, loader, replay and module pass. settings, snapshot, windows_api and idle_gate fail because their fake memory sits at the old addresses (expected) |
