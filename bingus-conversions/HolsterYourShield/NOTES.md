# Holster Your Shield v1.0 → Steam build 26088801 (offline port, Megapack option HolsterYourShield)

Source: the pinned pack copy `upstream-bingus/VanillaPlusMegapack/components/HolsterYourShield`. The checkout
`upstream-bingus/HolsterYourShield` (git tag `v1.0`, cadfd8c) is byte-identical; both match every `source_sha256` of the
lock row, and MAP.json records it. Old build 25480438, new build 26088801 (game.dll `6D1D4D3B…C08F`, exe `0ACC07DE…EABE`,
both re-hashed read-only from the install). Nothing here touched the network, the game folder, `~/.config/hd2arsenal`,
anything under `<steam-library>` (read only), the upstream checkouts or the running game. Nothing was installed.

## Deliverables

| Path | What |
|---|---|
| `MAP.json` | 31 rows (30 high, 1 medium, 0 low, 0 unmapped); 28 feed a native call. 125 instruction/byte witnesses are re-disassembled on every `tools/build_map.py` run; `witness_check_failures` is empty. |
| `build.py` | `python3 -I -B build.py [--tests]` (see its docstring). |
| `out/holster_your_shield.lua` | The port entry (plaintext, declaration first), sha256 `82a19ccf…8b79`. |
| `out/9ba626afa44a3aa3.patch_0` | Only `mods/cowboybingus/holster_your_shield` (`2dc2359512462098`, 57 314 bytes, type `a14e8dfa2cd117e2`, envelope `<II len, 2>`), made with BingusSharedLoader `archive.py make_archive` and round-tripped; empty `.stream` / `.gpu_resources` beside it. Not the shared stub. |
| `out/entry.diff` | Port entry vs the unmodified assembly: 19 lines. |
| `out/build-receipt.json`, `out/TESTS.json` | Hashes, every edit, the LuaJIT check and the tests. |
| `live/holster_your_shield_readonly.lua` | Read-only live probe, checks L0–L6 below; `tools/mock_probe.lua` runs it offline (MOCK OK). |
| `tools/` | `lib.py`/`align.py` (from hdh-port), `map_globals.py`, `map_fields.py`, `value_map.py`, `fmap.py` (function windows), `fpair.py`/`listing.py` (aligned pairs), `action_scan.py`, `getter_fields.py`, `pages.py`, `build_map.py`. |
| `evidence/` | `globals.json`, `field-pairs.json`, `value-map.json`, `action-37.json`, `getter-fields.json`, `listings/` (stow, draw, set_item, set_mode, send_held, equipment getter, entity lookup, one-handed query: old and new side by side). |

Rebuild: `cd tools && python3 -I -B map_globals.py && python3 -I -B map_fields.py 150 && python3 -I -B value_map.py 0xa7aec 0x1cb8 0x1b70 0xf22ec8 0xf1aeb0 0xf12bc0 && python3 -I -B action_scan.py 37 && python3 -I -B getter_fields.py && python3 -I -B build_map.py && cd .. && python3 -I -B build.py --tests`.

## Packaging

- This option was never bytecode. The pack builds it as `BUILD_ASSEMBLED` with `'entry': 'direct'`: the component's
  `scripts/build.py assemble()` makes one plaintext entry (re-entry guard, vendored `bingus_runtime.lua` and
  `bingus_memory.lua`, then the mod), and the pack ships those bytes as they are. `build.py` runs that same pack path
  (`build_component` for the unmodified copy, `component_resource` for the edited copy).
- The unmodified copy reproduces the lock `resource_sha256` (`C11AF49F…F66D`) and equals the shipped v26 resource
  `2dc2359512462098` byte for byte (and the shipped `2dc2359512462098.lua` file).
- The port entry is a fixed point of the loader's own `build_addon.entry_source`. No PORT51, compat51 or cffi; the
  upstream forbidden-name rule holds (no WriteProcessMemory, VirtualProtect, VirtualAlloc, FlushInstructionCache,
  CreateRemoteThread, LoadLibrary, `Network.`, `RPC.`).
- The pack's `archive.py` EXE/GAME pins are not used by this option; it carries its own pins in the source.
- GC64 check: `loadstring` compiles the entry (`string.dump` flag 8 = FR2). Run on Linux beside the unmodified entry under
  the same stand-in loader, both stop identically at the vendored `bingus_memory`'s `ffi.load('kernel32')`/`('bcrypt')`
  (no Windows libraries on this host) and leave `update` untouched. Under Wine the entry refuses cleanly
  (`test_entry`: "Disabled: game modules unavailable").

## What changed (everything else is byte-identical to v1.0)

| MAP row | Constant | Old | New | Feeds a call |
|---|---|---|---|---|
| `pin.GAME_SHA256` / `pin.EXE_SHA256` | `Holster.GAME_SHA256` / `EXE_SHA256` (verify_build gate) | `2E2C3B7C…F51E` / `F5FEE03D…5F06` | `6D1D4D3B…C08F` / `0ACC07DE…EABE` | gate |
| `layout.players` | player manager | 0x3326468 | 0x2CE1618 | yes |
| `layout.owner` | entities object | 0x346BF98 | 0x2CE41B8 | yes |
| `layout.avatars` | avatar manager | 0x3326D20 | 0x2CE1EE0 | yes |
| `layout.inventory` | inventory (first argument of set_item/set_mode) | 0x3326738 | 0x2CE18E8 | yes |
| `layout.equipment` | EquipmentComponent per-entity copies | 0x3326DC0 | 0x2CE1F88 | yes |
| `layout.none_item` | nothing-held id (item argument of a stow) | 0x3483C4C | 0x2E3F0FC | yes |
| `layout.none_slot` | empty held-carryable id | 0x3483C5C | 0x2E3F10C | yes |
| `layout.set_item` | game function (inventory, entity, item) | 0x9ABC30 | **0x9BD850** | **call** |
| `layout.set_mode` | game function (inventory, entity, mode) | 0x9AC8E0 | **0x9BE500** | **call** |
| `layout.send_held` | rpc_set_held_carryable (peer, entity, item, mode) | 0xBE20B0 | **0xC008B0** | **call** |
| `owner.network_map` | entities: network-id map | 0xF22EC8 | 0xF24990 | yes |
| `owner.entity_map` | entities: entity-id map | 0xF1AEB0 | 0xF1C978 | yes |
| `owner.records` | entities: 24-byte records | 0xF32F18 | 0xF349E0 | yes |
| `owner.settings` | entities: shared EquipmentComponent table | 0xF12BC0 | **0xF14688** | yes |
| `settings.slots` | slots of that table | 688 | **702** | yes |
| `label.version`, `label.build` | `VERSION` `1.0` → `1.0-26088801`; three comments and the refusal message name 26088801 | | | no |

Unchanged, with witnesses: the three prologues (16 bytes each), player manager +0x84/+0x88/+0xE8 (record +0x14 bit 0)/+0x3A8
(0x7FFF none), entity record {hash, id +8, flags +20 bit 0}, avatar hash `0x4D1C334D294DFA97`, avatar manager
+0xF8/+0x6C/+0x110, input slots +0x150+0x1B68 (32 bytes, held time +8), stride 0xA7AEC, Backpack Function = action 37,
inventory map +40 / identities +64 / rows +80 / 48-byte rows (weapons +0/+4/+8 by slot 1..3, backpack +12, held +20, slot
in hand +28, carry mode +32), copies map +80 / records +144 / 232 bytes, settings slot {u64 key, u32 index +8}, 232-byte
records after 16·slots, type +0x80 (25 = shield), one-handed +0xC4, carry modes 2 held / 1 away, peer −2. The only medium
row is `limits` (plausibility bounds 1048576/65536/64/262144/8/4; they can only make the mod wait or refuse).

## Writes and calls

**Memory writes: none.** The mod writes no memory. Its source has no write API (the upstream build forbids the names) and
reads only through ReadProcessMemory into private buffers.

**Native calls: three game functions**, bound once at install after `verify_build` (both new pins) and after the first 16
bytes of each are read **through ReadProcessMemory** and compared. They are called only on a key press or re-stow, after a
full re-resolution from the registry roots, exactly as the game's own stow and draw call them:

| Call | Old → new | Evidence |
|---|---|---|
| `set_item(inventory, entity, item)` | 0x9ABC30 → 0x9BD850 | Unique unmasked 160-byte entry window, 9/9 inner windows agree. Body aligns 818/819 (ratio 0.993); the only changed operands are the game's own avatar-block stride 0x1238→0x1240, field 0x53E9B8→0x53E9C0 and its jump table. Called by the game's stow (new 0xAB1524) and draw (new 0xAB1701). |
| `set_mode(inventory, entity, mode)` | 0x9AC8E0 → 0x9BE500 | Unique 160-byte entry window, 8/8 inner. Aligns 461/461 (same stride/field changes only). Writes carry mode +0x20, and 0 when nothing is held (new 0x9BE5BD), as the mod expects. Called at new 0xAB1534 / 0xAB1711. |
| `send_held(peer, entity, item, mode)` | 0xBE20B0 → 0xC008B0 | Unique 160-byte entry window, 3/3 inner. Aligns 35/35 with no operand change. Called at new 0xAB154F / 0xAB172F with `rcx = -2`. (Its pdata entry starts 3 padding bytes earlier, at 0xC008AD; callers and the mod use 0xC008B0.) |

The game's stow (old 0xA95910 / new 0xAB13F0) and draw (old 0xA95A90 / new 0xAB1570) align **100/100 and 127/127 with no
operand change**. They read the same inventory map, identity, row, none ids and equipment type, then call these three
functions with the same argument pattern:

- stow: `set_item(inv, e, none_item)`, `set_mode(inv, e, 1)`, `send_held(-2, e, held, 1)`;
- draw: `set_item(inv, e, backpack)`, `set_mode(inv, e, 2)`, `send_held(-2, e, backpack, 2)`, after `getter(backpack)+0x80 == 25`
  and the one-handed query.

The mod's argument values (inventory pointer, entity id, ids from the row, modes) come only from high rows.

**Code pages:** all three functions are on decrypted code pages in the 26088801 capture. At game start, a page that is
still PAGE_NOACCESS makes the prologue read fail. The mod then logs `Disabled: game function unreadable: <name>` and does
nothing, so it never calls unchecked code.

If L6 shows that happening at load, the remedy is a lazy bind like myc-port's: check and bind right before the first call.
That is a code change, not build data, so it is not applied here.

## Offline tests (`out/TESTS.json`)

Upstream suites `test_mod`, `test_hostile`, `compile_entry` and `test_entry` ran on the unmodified copy and on the port.
For the port, the test fixtures were remapped with the same map (test files only). In `fake_game.lua`: 0xF32F18, 0xF22EC8,
0xF1AEB0, 0xF12BC0 and 688 slots. In `test_mod.lua`, the adapter test's 0x240000-byte buffer becomes 0x260000, because the
new send_held RVA lies beyond it.

- **Windows LuaJIT 2.1 GC64 under Wine** (the game VM's kind): upstream and port both pass 20 + 4 + 1 + 1 (all PASS).
- **Linux GC64 LuaJIT:** only `compile_entry` passes, for both. The others need kernel32, which is environmental and
  identical for the unmodified copy.
- **Not run:** `tests/game_lua.py` (the game's own lua51.dll through Windows ctypes).

## Read-only live checks (`live/holster_your_shield_readonly.lua`)

Run it through the game's memory tool (LLM eval env: game, exe, read, ptr, get, region, out, fmt). Wear the SH-20 or
SH-51 shield backpack, and run it three times:

- (a) a pistol or other one-handed weapon in hand, so the shield is in the left hand;
- (b) a two-handed primary in hand, so the shield is on the back;
- (c) while holding the Backpack Function key.

| Check | Reads | Expect |
|---|---|---|
| L0 | `_G.HolsterYourShieldInstalled` | true; the log says `Holster Your Shield v1.0-26088801 initialized` |
| L1 | [game+0x2CE1618/0x2CE41B8/0x2CE1EE0/0x2CE18E8/0x2CE1F88]; u32 [game+0x2E3F0FC], [game+0x2E3F10C] | 5 heap pointers; none ids 0 and 0 |
| L2 | players +0x84/+0x88 (1..4), +0x3A8 network id (not 0x7FFF), [+0xE8]+0x14 bit 0 = 1; entities+0xF24990 map → index i; record entities+0xF349E0+24·i | hash `0x4D1C334D294DFA97`, flags +20 bit 0 = 1; the entity-id map entities+0xF1C978 gives the same i |
| L3 | avatar manager +0x6C count (≤ 8), +0xF8 map → ai, [+0x110+8·ai] | equals the record address from L2 |
| L4 | key am+0x150+0x1B68+0xA7AEC·ai+37·32+8 (f32) | 0 released, > 0 and growing in (c) |
| L4 | inventory+40 map → row index r; [inventory+64][r] = record address; row = [inventory+80]+48·r | (a) held +20 = backpack +12 and mode +32 = 2; (b) held 0, mode 0 or 1; slot +28 is 1, 2 or 3 |
| L5 | the backpack's equipment record (copies map +80/+144·232, else the shared table [entities+0xF14688], 702 slots) | type +0x80 = 25, +0xC4 = 1 |
| L5 | the weapon in hand | +0xC4 = 1 for a pistol, 0 for a two-handed primary |
| L5 | the shared table | used slots ≤ 702 and every index < 702; old +0xF12BC0 holds something else |
| L6 | 16 bytes at game+0x9BD850, 0x9BE500, 0xC008B0, and their page protection | prologues match; protection 0x20 (PAGE_EXECUTE_READ). 0x1 at load = the mod disables itself (see above) |

Then a gameplay check, which is the user's call:

1. With a one-handed weapon and the shield in hand, press Backpack Function. The log should show `Shield to the back: done
   (held 0, mode 0)`.
2. Press it again. The log should show `Shield to the hand: done (held <id>, mode 2)`.
3. A squadmate should see the shield move. This is the RPC.
