# Mod Options Menu 1.2.1 — Steam build 26088801 (LuaJIT)

CowboyBingus's Mod Options Menu (Zero-Clause BSD, see `LICENSE`) with only its build data remapped
for Steam build 26088801. It is the original LuaJIT code: it needs the LuaJIT VM (see
`docs/LUAJIT-LIVE.md`), not a Lua 5.1 compatibility layer.

## Changes (`port.diff`, against upstream v1.2.1 `d07339a`)

- **Build data.** `MAP.json` lists all 185 build-specific constants (183 high, 2 medium confidence,
  none unmapped). Changed: both SHA-256 build pins, 25 game.dll function RVAs, 3 data tables, 3
  global pointers, and the shared `bingus_text` language table. All 25 prologue signatures, every
  struct offset and every label id are unchanged.
- **Code pages.** Build 26088801 keeps some game.dll code pages `PAGE_NOACCESS` until the game first
  runs them; at boot 10 of the 25 functions were on such pages. The prologue check now reads
  through the memory API (ReadProcessMemory). A function whose page is not resident yet is checked
  right before its first call and never called unchecked.
- **DBF saves.** `api.lua` saves `native_stratagem_radial.*` values immediately, for Diver's Best
  Friend's MCM, which confirms through this API while the native view is suspended.

## Verified

- Static: every constant in `MAP.json` with code or data witnesses in the new game.dll.
- In game, read-only before install: tab labels, the nine category labels, the setting descriptor,
  globals, and the Escape menu / OPTIONS layout all match.
- In game, installed (2026-10-24, Proton): "Native options layout verified for current game
  build", the native MODS tab is added, options apply.

## Files

`entry.lua` is the built resource `mods/cowboybingus/mod_options_menu` (the release zip carries it
as an archive). `NOTES.md` holds the mapping notes and the read-only live checks.
