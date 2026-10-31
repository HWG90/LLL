# HD2 Transmog Foundation 0.2.4 → Steam build 26251122 (LuaJIT)

Build 26251122: exe stamp `0x6ae0964a`, game.dll stamp `0x6ae0e5ff`. The sources here are the installed package's,
byte for byte (`receipt.json`: Addon `66798102…`, ArmoryInterface `2d4c785c…`). The diffs are against the 0.2.4 release
(Addon `3e54bb6f…`, ArmoryInterface `1a5ce3eb…`).

There is no build gate. `M.build` in the three symbol tables, and the stat witness's `build`, only label the port.
GameContract proves each symbol on its own:

- code by its whole witness at a fixed RVA;
- a derived global (`from`) by reading its instruction in the running game;
- a plain global only by lying inside the module's data ("assumed").

The Adapter finds its 26 patterns (CompatSpec for the UI, CatalogCompat for the catalogue) by mask.

## Carried from the 26088801 port (2026-10-25 and r2, 2026-10-29)

- **Cold code pages.** The game keeps Armory code unreadable until it first runs it, and a read that touches such a
  page fails as a whole. The original took that as "not found / gone", or raised.
  - GameContract has a `cold` state: the capability is `unknown`, "not loaded yet", rechecked at most once a second.
  - The Adapter and NativeGrid scans zero-fill unreadable pages. A pattern that was cold is woken by comparing its
    whole hex, masked bytes included, at `wake_rva`.
  - ArmoryExtras and the stat resolver retry instead of switching off.
- **Armors newer than the reference data** are listed by the game with no catalogue identity. NativeGridPresentation
  replays them untouched and never uses them as donors (`tests/presentation_unknown.lua`).
- **No saved variants.** `refresh_looks` never created `looks`, and the previews part stopped. That bug is in the
  original.
- **Mapped executable code.** The decrypted exe code is `MEM_MAPPED`, with its allocation base at the exe. GameProcess
  accepts mapped executable pages owned by the exe or game.dll, and nothing else (`tests/process_mapped.lua`).
- **Mission-in-progress join (r2).** A join puts the player in the host's hellpod. The ship Armory never opens, so
  the grid's `selection`, `commit_source` and thumbnail code stays cold.
  - An optional part on cold code is left out and named in `cold_parts`; the grid is ready with the rest.
  - Progression comes from the catalogue's `progression` global when the selection proof is cold.
  - NativeGridRenewal scans a grid with cold parts again once per picker opening, at most 3 times per screen.
  - The startup and respawn restores wait while the armor setter (`deployment_apply`) is cold.

## Build data (2026-10-29, `MAP.json`: 104 rows, 0 problems)

- **exe:** the code moved; the data globals did not.
  - create `0x2edd20→0x2edca0`, allocate `0x602180→0x602110`, release `0x602240→0x6021d0`.
  - render world submit `0x2e7880→0x2e7800`, update `0x2e77c0→0x2e7740`; world flush `0x304730→0x3046a0`.
  - render target create `0x2ea5a0→0x2ea520`, binding `0x3da160→0x3da0a0`, entry `0x3da5b0→0x3da4f0`.
  - camera frustum `0x402a40→0x402980`; its `+0x96` stores `0x402c2f→0x402b6f`.
  - Each body is masked-identical through its `ret`/`jmp`. The engine API root and both allocator vtables hold the new
    addresses.
- **game.dll:** all 89 RVAs are unchanged, but `.rdata` moved `+0x20` (one target `+0x10`). Every differing
  instruction is a RIP operand whose target holds the same bytes.
  - Re-derived witnesses: `compare_pair`, `model_widget_update`, `package_acquire`, `package_release` and the stat
    witness.
  - Re-derived Adapter hexes: manager, font, atlas, material, loadout_view_setter, loadout_view_stratagems,
    equipment_button_size, gear_catalog_categories and extra_localized_text. With their old hexes the UI adapter
    waited for ever, because a cold pattern wakes only on its whole hex.
- **Live 2026-10-29:** 26 of 26 witnesses matched.

## The 12 armors missing from the reference data (2026-10-30)

Twelve kits of the game's armor catalogue were outside `CatalogData`: 11 `unknown_reference`, plus `3412f5e4`, whose
header changed. They were listed as cards with no identity, which the input guard accepted but never acted on, so they
could not be selected or equipped.

- The catalogue writes a kit it cannot match into `catalog-observed.txt` as `record` lines: the raw record, body
  records, piece rows, and any passive the reference lacks.
- Those records became `CatalogData` entries in the generator's own form. The 11 kits were added, `3412f5e4` was
  replaced, and passive 42 was added (three body armors use it). Its variant id is the md5 of the catalogue's passive
  fingerprint, because the original generator's recipe is not in the bundle.
- New piece rows can use a 16-byte extension: a pointer that changes every launch, plus a count. The reference keeps
  it with the pointer zeroed. At read time, a row whose other bytes all match is taken as read, pointer included, so
  nothing ever writes a zero pointer.
- `CatalogData` is one line of about 1.2 MB, so the Addon diff carries it whole, old and new.
- **Live 2026-10-30 02:28:** 422 of 422 kits matched (`native_catalog_verified`). The worn `a2441063` was focused,
  cards were drawn, and input was handled.

## Starting without the mission loadout screen (2026-10-30)

On this build, the mission loadout screen's code stays cold until that screen first opens, and 14 of the Adapter's
witnesses lie in it. Transmog therefore waited for a loadout screen on every launch.

- **Loadout witnesses.** Those 14 are optional. A required `armory_registration` proves the UI manager's registry
  from code the game runs at startup. The Equipment readings still need every loadout witness: until they can be
  read, the adapter watches their `wake_rva`, then rescans from pristine state, and the Armory grid is made again from
  the new resolution.
- **The catalogue's player global.** CatalogCompat's `gear_payload` is optional. `extra_booster_host` is now
  required, as it already is in CompatSpec: it is ship code that loads the `players` global within seconds of launch.
  While it was optional, the catalogue resolved before that code ran, and `players` stayed nil for the whole launch:
  no local-player read, base stats, local restream or remote observer.
- **Grid renewal.** NativeGridRenewal now ends a screen's renewals only when a re-check found nothing new while its
  picker stayed open. A one-second Armory visit had left `preview_notify` cold for the launch, so variant previews
  failed with `armory:4053 native stat/perk widget proof unavailable`.
- **Live 2026-10-30 21:58,** with no loadout visit:
  - both adapters resolved, and the catalogue found `extra_booster_host` 8 s after launch: READY, then CATALOG READY;
  - the first Armory opening renewed the grid to complete (`preview_notify` proven), and the local player was read;
  - variant previews completed (`a2441063` too);
  - two equips ended `native_armor_and_passive_cache_verified`.

## Offline tests

Run them in stock LuaJIT 2.1. The image paths are captures of this build, not included: `game.dll` (sha256
`57baccc0…56c8`) and the executable's decrypted code (`6e2751f8…a92c`).

```
luajit tests/cold_pages.lua d42a76efa2beb2e3.lua 29541cbc088af816.lua <game.dll image> - <exe image>
luajit tests/presentation_unknown.lua d42a76efa2beb2e3.lua 29541cbc088af816.lua
luajit tests/process_mapped.lua d42a76efa2beb2e3.lua
```

- `cold_pages`: 150 checks. It makes chosen pages unreadable the way the game does and runs the port's own
  GameContract, Adapter and NativeGrid over them.
- `presentation_unknown`: 11 checks.
- `process_mapped`: 9 checks.

Each prints one JSON line.

`live/transmog_witness_pages_readonly.lua` reports, for each of the 26 Adapter witnesses, whether its page can be read
yet (`R`) or is still cold (`C`). It reads only.

## Not checked on this build

- A fresh launch straight into a mission-in-progress join: variants in the pod, Apply, and the worn variant restored.
  It was accepted on 26088801 r2 (a read-only watch of a join at slot 2 showed 114 → 117 list items, with variants).
