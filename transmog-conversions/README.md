# Transmog conversions — Steam build 26251122 (LuaJIT)

[HD2 Transmog Foundation](https://github.com/tyrypyrking/HD2-Transmog) 0.2.4 (Experimental) by tyrypyrking
([Nexus Mods 16633](https://www.nexusmods.com/helldivers2/mods/16633)), converted for the LuaJIT VM
(`docs/LUAJIT-LIVE.md`). The upstream repository has no licence file: the original code is its author's.

The port is plain LuaJIT, with real `ffi`/`bit`, no Lua 5.1 compatibility layer and no `cffi`. It needs the LLL
LuaJIT boot and the Vanilla Plus Megapack's LuaJIT Bingus Shared Loader v18 (the upstream release asks for v15+ / API 1).
Of the release's 11 option resources only two change. The other nine and the Options tree are the originals.

| Option folder | Resource | Name |
|---|---|---|
| `Addon` | `d42a76efa2beb2e3` | `mods/hd2transmog/foundation` |
| `ArmoryInterface` | `29541cbc088af816` | `mods/hd2transmog/armory` |

Each build folder has:

- `<resource>.lua`: the installed source as plain Lua.
- `<resource>.diff`: against the 0.2.4 release's resource (`original_source_sha256` in the receipt).
- `receipt.json`: the builder's validation receipt (every option resource's hashes, the archives, the offline test
  results, the port map's hash). Its `pending` list predates the live checks in `NOTES.md`.
- `MAP.json`: every build-specific row from the previous build, old and new, with its evidence.
- `NOTES.md`: what changed and why, and what was checked in game.
- `tests/`: the offline tests, in stock LuaJIT over captured images of the build (not included).
- `live/`: read-only probes, run through Link's Link to Memory.

Each option archive (`9ba626afa44a3aa3.patch_0`) holds one resource in the version-2 envelope
(`<u32 length><u32 2>` then the source), built with Bingus Shared Loader's `scripts/archive.py make_archive`, with
empty `.stream` and `.gpu_resources` companions. The builder, the registration tool and the evidence stay in the porting
workspace.

Status on Proton, 2026-10-31:

| Build | Status |
|---|---|
| 26251122 | Installed through Arsenal (GUID `cc08f326-3b32-5471-b930-ecd8e1a72ce6`, replacing the 26088801 port's `f450aeee…`). **Accepted in game on 2026-10-30 at 21:58**: started on the ship with no visit to the mission loadout screen, both adapters and the catalogue ready, variant previews drawn and two equips verified, armor and passive. Every armor of the game's catalogue is in the reference data (422 of 422 matched live). A launch straight into a mission-in-progress join has not been run on this build yet |
