# Match Your Colors 1.5 — Steam build 26088801 (LuaJIT)

CowboyBingus's Match Your Colors (Zero-Clause BSD, see `LICENSE`) with only its build data
remapped for Steam build 26088801. Upstream v1.5 assembles byte for byte into the shipped
resource, so this is that code with build data changed. It needs the LuaJIT VM (see
`lll-jit-live/docs/LUAJIT-LIVE.md`, github.com/HWG90/LLL branch `LLL_JIT_Live`).

## Changes (`port.diff`, against upstream v1.5 `0341f6d`; build data, the code-page patch and the weapon source lease)

- **Build data.** `MAP.json` lists 158 build-specific constants (141 high, 17 medium confidence,
  none unmapped). All 12 game.dll globals moved. Several layouts changed:
  - kit piece records grew from 96 to 112 bytes;
  - the weapon catalogue grew from 1080 to 1100 buckets, so a fixed 17280-byte buffer is now 17600;
  - weapon component types grew from 382 to 392 buckets with a new base, and the paint component
    type is 274 (was 271);
  - fields inside the entities object were reordered;
  - customization manager fields moved by 8 bytes.
  Script C API slot offsets are unchanged; only the function addresses and `get_engine_api` moved.
- **Code pages.** `Engine.open` reads `get_engine_api`'s prefix through the memory API. If its page
  is not resident yet, the buffers/resources functions are checked and bound right before their
  first call instead of at startup; a prefix that reads but differs still disables the mod.
- **Weapon source lease (2026-10-25).** Goose's suggestion (CowboyBingus/MatchYourColors#2, after
  Epic LUT R6): a reload binds a weapon's paint again, which v1.5 repaired a frame later (one frame
  of the weapon's own colors). The port takes the reset rows of the bound materials out of the
  weapon's private customization copy while the recolor is bound (the game's allocator makes a copy
  where a weapon has none, verified against the type byte for byte), and watches the weapon in
  hand's customization record for the reload's new magazine unit. New `src/weapon_source.lua`;
  `src/loadout.lua` and `src/weapons.lua` edited, the old watch commented out; `src/addon.lua`
  patched. Details, coordinates and the live checks still to run:
  `native-work/myc-port/lease/README.md`.

## Verified

- Static: every constant with code witnesses in the new binaries; the upstream tests pass on the
  current game data as on unmodified upstream.
- In game, read-only before install: engine API tables and functions, player, customization (with
  the old offsets as a negative control), kit pieces at 112 bytes, entities, avatars, lobby and the
  weapon catalogue all match.
- In game, installed (2026-10-24, Proton): "initialized", 81 materials recolored with a paint
  scheme chosen in Mod Options Menu, weapons recolored (29 materials).
- Not in game yet: the weapon source lease build (`entry.lua` sha256 `55b4f78a…5fc5d7a1`, 2026-10-25).
  Offline: 12 lease checks and the upstream tests (with the port's fixture edits) pass.

## Files

`entry.lua` is the built resource `mods/cowboybingus/match_your_colors` (the release zip carries it
as an archive). `NOTES.md` holds the mapping notes and the read-only live checks.
