# Mods for Chef Shared Loader and Boot Mod Loader

Live Lua Loader runs mods written for the two Lua 5.1 loaders that appeared after the
2026-10-20 update: [Chef Shared Loader](https://github.com/Th3chef/Chef-Shared-Loader)
(1.2.0) and [Boot Mod Loader](https://github.com/pat-pat-patrick/boot-mod-loader)
(0.11.0). Install those mods with your mod manager as usual, next to LLL. Do not also
deploy Chef Shared Loader or Boot Mod Loader themselves: each replaces the game's `boot`,
as LLL does, and only one can run.

The layers are in `src/compat.lua` and `src/compat/`. They are part of every LLL build
(generic, Steam R35 and LuaJIT Live) through `tools/build.py`'s module list.

## Discovery

Archive mods are found as before. The scan now also accepts:

- names with `-` and more than two parts (`mods/<author>/<group>/<name>`), Chef's rules;
- `-- HD2-Boot: mods/<a>/<b>`: a boot-style script (global `init`, `update`, `render`,
  `shutdown`), run in its own environment;
- `-- HD2-Options: mods/<a>/<b>`: an Arsenal option folder's table, merged one level deep
  into that mod's `chef.options`;
- `-- HD2-Lang:`: recorded, not applied (texts stay in English);
- `-- HD2-Requires: <name> [>= version]` lines among the first comment lines. Required mods
  start first. A mod whose requirement is missing, in a circle, or asks for Chef Shared
  Loader newer than 1.2.0 is not started, and the log says why.

An addon is Chef-style when it has `local chef = ...` near the top or requires
`chef-shared-loader` / `chef-loader`. Those and boot scripts are read from their archive and
run by LLL. Every other addon is loaded by the game's `require`, exactly as before.

The archive catalog cache is now `archive_catalog_v4.txt` and carries these fields.

## Boot Mod Loader mods

They are Bingus-style and run as they always did. LLL adds what Boot Mod Loader gives them:

- `CowboyBingusModLoader.on_shutdown(fn)` (or `on_shutdown(id, fn)`): run after the game's
  whole shutdown chain;
- `CowboyBingusModLoader.on_update(id, fn)` (Chef's): once a frame with `dt`; an erroring
  function is dropped and logged;
- `CowboyBingusModLoader.game`: `build_identifier`, `checked`;
- `ModOptionsMenu` (v1.2, version 3) and `ModBindingsMenu` (v2.3, version 4) look-alikes,
  set before mods load unless the real menu mod is installed.

## Options and keys

Rows of the Mod Options/Bindings Menu look-alikes and of `chef.option` / `chef.bind` live in
[HD2 Mod Setting GUI](https://github.com/pat-pat-patrick/hd2-mod-setting-gui) 1.12.0 or newer,
outside the game. LLL writes the same files Boot Mod Loader writes, in
`%APPDATA%\Arrowhead\Helldivers2`, so a player's values carry between the loaders:
`mom_<mod>_options.json` / `_settings.txt` / `.log`, `mbm_<mod>_...` for keys (a "Keys" page
under the mod's title), and `lll_<mod>_...` / `lll_<mod>_keys_...` for Chef mods. Values the
window changes are read once a second and reach `on_change`. A key counts only while the game
window has focus (Boot Mod Loader's chat guard is not reproduced).

## Chef mods: the `chef` helpers

Each Chef mod gets its own `chef` (as `...` for an addon, a global for a boot script),
`api` 3, `loader_version` "1.2.0". It runs in its own copy of the globals (game callbacks
start as empty stubs; `rawget(_G, 'stingray')` works); a returned table's `update`,
`render` and `shutdown` are driven, else a global `update` it set. A Bingus-style mod that
returns hooks and did not hook the game's `update` itself is driven the same way.

Working: `log`, `own_log`, `log_file`, `log_directory`, `previous_directory`, `options`,
`time`, `call`, `call_kind`, `world`, `world_id` (and the `world` event), `key_down`,
`key_pressed`, `key_known`, `mouse_down`, `cursor`, `wheel`, `typed`, `key_label`, `screen`,
`color`, `rect`, `text`, `text_width`, `text_fit`, `text_wrap`, `sprite`, `triangle`,
`circle`, `ring`, `line`, `notify`, `capabilities`, `has`, `after_startup`, `save`, `load`,
`share`, `shared`, `on`, `emit`, `require`, events `startup` and `shutdown`, `title`,
`option`, `get`, `set`, `on_change`, `bind`, `unit_alive`, `unit_position`,
`unit_rotation`, `unit_node`, `spawn`, `despawn` (spawned units are destroyed when the mod
stops), `link`, `unlink`, `lights`, `light`, `after`, `every`, `spread`, `in_session`,
`is_host`, `players`, `peer_id`, `save_table`, `load_table`, `mods`.

Drawing goes through LLL's own view (the HUD font when LLL has it, else the stock debug
font), bottom-left origin; text is drawn in capitals. `chef.TOP` is 1000.

Not available on LLL (they answer nil, false or an empty list; the matching `has` names are
false): `camera`, `world_to_screen`, `in_mission` (always false, so no `mission_start` /
`mission_end` events), `watch`, `mission_kinds`, `unit_kind`, `units_near`, `bitmap`,
`bitmap_uv`, `ui_textures`, `texture_sizes`, `sprite_sheet`, `arc`, `particles`,
`budget`, `setting`, `lang`/`tr` (English), language files, the resource index, dev mode,
trusted mods and the HD2 Lua Runtime look-alike. LLL is not a sandbox: there is no lockdown,
and an engine call that ends the game is not remembered across launches.

## Tests

`python3 tests/test_compat.py` builds real patch archives and runs
`tests/compat_contracts.lua` and `tests/compat_manager_contracts.lua` in stock Lua 5.1 and
LuaJIT (whichever are installed).
