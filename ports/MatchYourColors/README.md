# Match Your Colors 1.5 — Steam build 26088801 (LuaJIT)

CowboyBingus's Match Your Colors (Zero-Clause BSD, see `LICENSE`) with only its build data
remapped for Steam build 26088801. Upstream v1.5 assembles byte for byte into the shipped
resource, so this is that code with build data changed. It needs the LuaJIT VM (see
`docs/LUAJIT-LIVE.md`).

## Changes (`port.diff`, against upstream v1.5 `0341f6d`)

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

## Verified

- Static: every constant with code witnesses in the new binaries; the upstream tests pass on the
  current game data as on unmodified upstream.
- In game, read-only before install: engine API tables and functions, player, customization (with
  the old offsets as a negative control), kit pieces at 112 bytes, entities, avatars, lobby and the
  weapon catalogue all match.
- In game, installed (2026-10-24, Proton): "initialized", 81 materials recolored with a paint
  scheme chosen in Mod Options Menu, weapons recolored (29 materials).

## Files

`entry.lua` is the built resource `mods/cowboybingus/match_your_colors` (the release zip carries it
as an archive). `NOTES.md` holds the mapping notes and the read-only live checks.
