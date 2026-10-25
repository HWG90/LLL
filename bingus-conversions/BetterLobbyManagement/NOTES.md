# Better Lobby Management v1.2.1 → Steam build 26088801 (plain LuaJIT, offline port)

Source: `upstream-bingus/BetterLobbyManagement`, tag v1.2.1, clean. All 41 locked source hashes in
`components.lock.json` match, and the pinned copy in `VanillaPlusMegapack/components/` is identical.
Old build 25480438 → new build 26088801 (game.dll `6D1D4D3B…C08F`, exe `0ACC07DE…EABE`).

Nothing here touched the network, the game folder, `~/.config/hd2arsenal`, `<steam-library>`, `upstream-bingus/` or the
running game. Other live captures of the same build in `<research>` and
`<archive-drive>/Research` were read as files only.

## Deliverables

| Path | What |
|---|---|
| `MAP.json` | 127 rows: one per build-specific constant or constant group, every code signature and native entry, and the two pins. Each row has old/new, method, witnesses, confidence, `feeds_write` and `live_check`. |
| `build.py` | `python3 -I -B build.py [--tests]`. Copies upstream to `work/upstream` and `work/port`, applies MAP.json, the code-page patch and the comment edits, assembles both with the upstream `scripts/entry.py`, archives, compiles and smoke-runs, and writes `out/`. |
| `out/entry.lua` | The plaintext entry: sha256 `AFCA923E…F7A4`, 238,726 bytes. |
| `out/mod.lua.main` | The resource: `<II len,2>` envelope + entry, sha256 `8E612665…82F4`. |
| `out/9ba626afa44a3aa3.patch_0` | sha256 `E2DD69D9…3B01`. Holds only `mods/cowboybingus/better_lobby_management` (key from `resource_hash`). Comes with empty `.stream` and `.gpu_resources` files. |
| `out/build-receipt.json` | Hashes, every edit, the LuaJIT output and the test results. |
| `live/blm_readonly.lua` | L0–L10, read-only. Generated from MAP.json by `tools/make_probes.py`. |
| `live/blm_page_dump.lua` | L11, read-only. Dumps the code that no capture has decrypted, and reports page protections. |
| `tools/` | The analysis and checks (see "Tools" below). |
| `evidence/` | `old-sigs.jsonl`, `sig-map.json`, `resolved.json`, `exe-slots.json`, `globals.json`, `field-pairs.json`, `native-bodies.json`, `old-global-xrefs.json` |

**How the megapack builds this option.** BetterLobbyManagement is ASSEMBLED, not compiled. The pack ships
`entry_text(root, '1.2.1')` in the `<II len,2>` envelope. `build.py` checks two things:

- The unmodified assembly reproduces the locked resource `BD9B0260…0A571` byte for byte.
- It also equals the resource inside the shipped v26 option archive.

The port uses the same recipe, so it is GC64-loadable as is. There is no PORT51/compat51 adapter and no cffi. The
upstream FORBIDDEN rule still holds, since `entry_text` enforces it. In runtime-modules' LuaJIT 2.1 (GC64),
`loadstring` compiles the entry. The smoke run then reaches the Windows step: `ffi.load('kernel32')` fails inside the
addon's own pcall, so the status is `unsupported: …`.

## What changed

### Build data (MAP.json rows with `replace` or a regenerated signature)

**game.dll globals.** Each was found by sampled RIP-relative windows (`tools/map_globals.py`). All witnesses agree; 0
disagree.

| Constant | Old | New | Witnesses |
|---|---|---|---|
| CONTEXT | 0x347cef0 | 0x2e38228 | 24 |
| GAME_STATE | 0x3326340 | 0x2ce1508 | 4 |
| ROSTER | 0x347ced8 | 0x2e38210 | 29 |
| ENGINE_API | 0x3326308 | 0x2ce14c8 | 33 |
| MATCHMAKING (G and S) | 0x347ce80 | 0x2e381b8 | 34 |
| MENU_SYSTEM | 0x347ce38 | 0x2e38170 | 7 |
| PRESENTERS | 0x347ce28 | 0x2e38160 | 17 |
| SOS | 0x3326bf0 | 0x2ce1db0 | 8 |
| PLAYERS | 0x347ce50 | 0x2e38188 | 6 |
| STRATAGEMS | 0x37cb600 | 0x31870e0 | 30, plus the live settings capture of that exact table |
| online CONFIG | 0x347cee0 | 0x2e38218 | 31 |
| override CONFIG | 0x347cdf8 | 0x2e38128 | 32 |
| continent ids (.rdata) | 0x21d45b0 | 0x205d3f0 | the 28 bytes occur once |
| bingus_text `M.GAME` | — | — | the values the MYC port verified |

**Struct fields** that moved:

- Game state:
  - MODE 0xac21c → 0xac29c
  - PRIVACY 0xac550 → 0xac5d0
- Network context. Everything from the client synchronizer's tail on moved +8:
  - CS_PARTY_JOIN 0x521 → 0x529
  - JOIN 0x171c8 → 0x171d0
  - LOBBY 0x1d470 → 0x1d478 (also live-verified, MYC L12)
  - BROWSER 0x1f028 → 0x1f030
  - Unchanged: LOCAL, HOST, SESSION, HOST_SYNC (+24/+28), CLIENT_SYNC, PEER_COUNT/PEERS, CHAT.
- Online config: scanner RECHARGE 0x3ce4c → 0x3ceac. The whole region around it moved +0x60, including the lobby post
  seconds 0x3ce68 → 0x3cec8, and 0x3cdd0 → 0x3ce30 with 8 witnesses.
- Player records: size 0x1690 → 0x16c0 and count field 0x2d200 → 0x2d800 (still 32 records). The stratagem slot
  layout inside a record is unchanged.

**Game data id.** `B.SOS_STRATAGEM` 0x91 → **0x95**. The stratagem types shifted:

- In the live settings capture (`native-work/evidence/stratagem-settings-26088801.json`), type 0x91 is now ORBITAL
  CONFETTI, with no use limit.
- Type 0x95 is "MISSIONS. SOS Beacon" (`nui_stratagem_sos_beacon_name`), with uses 1 and shared 0. That matches what
  upstream measured live for its 0x91.
- The game's own SOS availability check changed `cmp edi,0x91` → `cmp edi,0x95` (0x66c9e5 → 0x676451).

Unported, the CANCEL SOS use-back would have read Orbital Confetti.

**Code signatures.** All 73 were re-derived (`tools/map_sigs.py`, `tools/resolve_more.py`):

- Each new location comes from one of: a unique masked window, a unique masked match of the signature itself, every
  migrated call site agreeing, or a whole-function alignment.
- The new bytes are the aligned counterparts of the old instructions.
- Every difference is either RIP or branch, or one of the field moves above. Two others are not mod constants:
  - The network context sits at another offset inside its parent: `lea rbx,[r15+0x1c91cd0]` → `+0x1c92220`.
  - The component registry's layout changed at the two SOS re-arm sites: `mov rcx,[rcx]` → `[rcx+0x20a8]`, and the
    registry type 0x85 → 0x87.
- Every called game.dll native was compared over its whole body (`evidence/native-bodies.json`). Ratios are 0.94–1.0.
  The only changed operands are the context fields above and registry offsets.
- The escape-menu (GAME tab) layout is byte-identical apart from RIP and branch operands. So are the PlayFab lobby,
  the lobby wrapper key cache and countdown, the stratagem slots and settings fields, and the override tables.

**exe engine API.** Lobby table `exe+0x28753b0` (ScriptApi+0xF8) and package table `exe+0x2871350` (ScriptApi+0x10)
come from the new ScriptApi initializers. Slots 0x198, 0x348 and 0x350 hold byte-identical functions.

Slot 0x40 (the continent getter) is now `[exe+0x2405ac8]+0xa8 → +0x44`, where it was `[[g]+0x5d0]+0xa0 → +0x44`.
Its shape and slot are the same, so it is **medium**; live check L1 covers it.

**Pins** in `scripts/entry.py` (GAME_DLL_SHA, EXE_SHA). The header and comment lines now say 26088801.

### The code-page patch (not build data)

The brief's lesson applies here: build 26088801 keeps some game.dll and exe code pages no-access until the game first
runs them. Upstream BLM is affected in two ways:

- It reads ~75 code ranges with a direct `ffi.cast` dereference (`api.bytes`). That faults on such a page, at load
  time.
- It binds every native at startup.

The patch is in `build.py` `CODE_EDITS`/`GAME_HELPERS`; every changed line is listed in the receipt:

- **`api.bytes` uses ReadProcessMemory** (`windows_api.lua`). It returns nil when a page is unreadable and never
  faults; `tools/check_bytes_wine.lua` tests this under Wine on a real PAGE_NOACCESS page.
- **Layout checks:** a readable mismatch disables the feature, exactly as upstream. An unreadable layout check is
  skipped and named in the log (`…; not loaded yet (checked at first use, or skipped): …`). The SHA-256 pins fix those
  bytes, and they were checked offline against decrypted captures.
- **Natives** bind through `G.checked_native`:
  - A readable, matching entry is bound as before.
  - A readable, different entry disables the feature, as before.
  - An unreadable entry, or one with `bytes = nil` (not known for this build), becomes a stub. The stub checks the
    entry right before its first call: at most one read per 30 calls while unreadable. It raises instead of calling
    until the entry reads back equal, so nothing is called unchecked.
- **Actions are gated on their natives, so none fails halfway.**
  - PROMOTE is offered and started only when its 8 natives check out (`L.PROMOTE_NATIVES`, `lobby.promote_ready`).
    Otherwise the menu offers DISBAND alone.
  - The escape-menu buttons appear, and a kick is set up, only when all 13 menu natives check out.
  - CANCEL SOS is offered or run only when SOS off and the key setter check out.
  - A squad message is skipped (as when chat is off) while the chat or RPC send is unreadable.
  - The Lobby Region continent check is skipped while the getter is unreadable.
- `tools/check_lazy.lua` covers every one of these paths against the upstream fakes: 7 checks, all PASS.

User-visible effect: a feature whose game code the game has not run yet in this session waits for it. For example,
PROMOTE appears once the game has run a lobby search (the Galactic Map scanner or quickplay) — only if those pages
really start no-access in game; L11 shows that.

## Blocked: 5 rows (`confidence: unmapped`), shipped as `bytes = nil`

These are code pages encrypted in **every** available capture of 26088801: the base capture, and 7 other live captures
whose 295 decrypted pages were merged in. None of them may be guessed.

| Row | Location (evidence) | Effect in the port until a dump is ingested |
|---|---|---|
| `kick_peer` native | 0xf1d8f0 (its one old call site migrates to a call of it) | none: only the diagnostic kick modes call it; the release build always uses the game's own KICK. It is a stub that refuses |
| `chat message RPC` (C.CODE) | in 0xc09a40 (the rpc_ingame_chat_message sender, one caller); +0x83 is the old offset | squad messages stay off (DISBAND's chat line, PROMOTE's new-leader notice); both actions still run |
| `continent filter`, `continent flag check` (R.CODE), and `R.KEYS` | in the lobby search builder 0x11cfed0 (its first fragment migrates; page 0x11d0000 is encrypted) | Lobby Region stays off (its writes are never made) |

To complete them, run `live/blm_page_dump.lua` after the game has run that code (best: a lobby search, a chat line and
a kick by the host). Then run `python3 -I -B tools/ingest_dump.py <log>`, `tools/build_map.py`, `build.py --tests` and
`tools/make_probes.py`.

`ingest_dump.py` accepts a row only if all of these hold:

- The masked old signature matches exactly once inside the dumped code.
- Its instructions align with the dump.
- For R.KEYS: both key words, the 7 continents and the type-7 compare are present.

A synthetic run of this path, with old bytes standing in, rebuilt to 123 high / 4 medium. The real result needs the
real dump.

## Confidence (MAP.json)

**Totals:** 118 high, 4 medium, 5 unmapped (above). 70 rows feed writes; every one of them is high, except the
unmapped Lobby Region rows, whose writes the port never makes.

**Medium:**

| Row | Why medium | Live check |
|---|---|---|
| G.FILTER_ARGS (key 3, op 2) | The op is witnessed in the game's own search builder. That a host publishes its peer id under key 3 has no static witness; it was verified live on 25480438 | a PROMOTE that finds the successor's lobby |
| M.WIDGET_GEOMETRY (+4/+12) | Only sizes the marquee, with a 388 px fallback | L6 (labels scroll correctly) |
| M.TEXT_TEMPLATE / TEXT_KEY | String data, as in the MOM port. 0xab2a7b35 is still loaded by game code at 11 migrated sites, and the MOM port's MODS label uses the same template (see its NOTES) | L6 |
| sig `engine continent` (exe slot 0x40) | Its object path changed | L1 |

## Every write the port makes, with its evidence

Every write goes through `api.writable_data` (one VirtualQuery: committed private RW), exactly as upstream.

1. **Escape-menu button count and type bytes:** `C+1789912` and `+1789913+i`, with `C = [[game+0x2E38170]+200]+281480`.
   One `write_words`.
   - Evidence: the signatures GAME tab select / select types / dialog result / attach / buttons are byte-identical
     apart from RIP and branch.
   - The game's select handler and its dialog result still act on types 0–4 only, so mod types 5–7 still land in the
     shared confirm dialog.
2. **KICK hold timer:** `card+85520` = 100.0f, with `card = C+1371024+85552·i`.
   - The KICK function aligns 0.979: `addss xmm0,[rsi+0x14e10]` (0x18f78b9 → 0x17789c9), with the 3.0 s threshold
     from .rdata in both builds.
   - The player menu run is gated by `cmp qword [rcx+0x1be8],0` (0x18f7110 → 0x1778220).
   - The peer is at +0x14e00 in both.
3. **Escape-menu pending close:** byte `[[game+0x2E38160]+0x4388]+16` = 1. Evidence: signature
   `mov rax,[rbx+0x4388]; …; mov byte [rax+0x10],1` (0x18fa53f → 0x177b705) is identical. The presenter global has 17
   witnesses and is live-verified by the HDH and MOM ports.
4. **Lobby post countdown:** float `[game+0x2E38228] + 0x1D478 + 0x1B80` = 0. Evidence:
   - G.LOBBY moved at 0x1d470 → 0x1d478 in the network update, SOS on/off, start_join and the host sync update
     (MYC L12 is live).
   - The countdown signature (`movss xmm0,[rdi+0x1b80]` …) is unchanged.
   - 8 lobby-code sites at +0x1b80 are unchanged.
5. **SOS Beacon use given back:** u32 `[game+0x2E38188] + 0x16C0·r + 0x1C0 + 48·i + 4` += 1. It is made only when slot
   type = 0x95, uses < settings `[0x31870E0+8·0x95]+0x50` (1), and shared (+0x94) = 0.
   - Player records: count 0x2d800 and stride 0x16c0 (signature + 79 field pairs).
   - Slots: +0x788/+0x188/+0x18c and the 16-slot bound are identical.
   - Type 0x95: code and live settings capture.
6. **Scanner recharge seconds:** int32 `[game+0x2E38218]+0x3CEAC`.
   - The reader signature now reads +0x3ceac (0x1337fa8 → 0x11cd238), into the countdown at `MM+0x10bd74`.
   - The neighbouring config fields moved +0x60 too.
   - The read-back/stop logic is upstream's.
7. **Scanner countdown shortened:** float `[game+0x2E381B8]+0x10BD74`. 6 of 6 sites are unchanged, including the
   per-frame update signature.
8. **Lobby Region table writes:** OnlineOverrideData `[game+0x2E38128]+0xC050`. **Not made in this port**:
   `region.verify` refuses on the unknown signatures.

## Every native the port calls

Every native's entry is checked through ReadProcessMemory before its first call.

**game.dll:**

| Native | RVA | What it does |
|---|---|---|
| add_child | 0x12e42d0 | attach the button |
| set_enabled | 0x12e85f0 | enable the button |
| set_label | 0x12d3ca0 | `#COUNT` label |
| set_label_wrapped | 0x12d9430 | `#COUNT` label, wrapped text |
| set_string_arg | 0x12d4660 | the text |
| set_marquee | 0x12d4110 | scrolling long labels |
| measure_text | 0x12e5eb0 | measure the dialog texts |
| dialog_setup | 0x1621080 | the game's confirm dialog |
| clear_args | 0x12d1e00 | take the mod's text off the dialog |
| rebuild | 0x177d140 | the game's own button rebuild |
| focus | 0x177c420 | focus a card or button |
| card_state | 0x1778f10 | open a player menu, for the game's KICK |
| SOS off | 0x684660 | lobby key 8 = 0, privacy setter, `S+0` = 0, `S+8` = 0 |
| lobby key setter | 0xf22d80 | key 19 in the cache, plus the key's bits |
| chat send | 0xf27db0 | rpc_ingame_chat_message to the squad, and the host's own chat |
| RPC send | 0xbfcbd0 | rpc_from_host_notify_new_host |
| filter_string | 0xf25640 | lobby search filter (PROMOTE) |
| browser_start | 0xf24f60 | lobby search (PROMOTE) |
| browser_busy | 0xf24fd0 | lobby search (PROMOTE) |
| browser_count | 0xf25070 | lobby search (PROMOTE) |
| browser_result | 0xf250e0 | lobby search (PROMOTE); fills the mod's 256-byte buffer, body identical |
| start_join | 0xf206f0 | the squad-quickplay party join |
| is_friend | 0x12874b0 | friend check |

**exe:**

| Native | RVA | What it does |
|---|---|---|
| clear_filters | 0x94a5c0 | clear the lobby search filters |
| continent | 0x948f50 | read the player's continent |

**Bound but never called in the release build** (only the diagnostic kick modes use them):

| Native | Location |
|---|---|
| kick_peer | 0xf1d8f0, bytes unknown |
| send_kick | 0xc12380 |
| unload_paused | exe 0x2f0bc0 |
| pause_unloads | exe 0x2f0be0 |

## Tests (`build.py --tests`, recorded in `out/build-receipt.json`)

All 17 upstream suite runs ran on three copies:

- **upstream:** unmodified v1.2.1.
- **port:** as shipped.
- **port_filled:** the port with the 5 unknown signatures given their old bytes as stand-ins, so the upstream fakes
  can place them. It is a test fixture only.

Runners: Linux LuaJIT for most suites; the Windows LuaJIT under Wine for windows_api, ffi_names ×3 and entry.

- **upstream and port_filled pass the same 16 of 17 runs:** bingus_text, locales, game, lobby, region, menu, chat,
  scanner, sos, diag, addon, idle_gate, ffi_names sdk / hostile / mod-first, and entry.
- **test_windows_api fails in all three at line 169**, "run inside the game lua51.dll": the Wine runner is a static
  luajit.exe. That is an environment failure.
- **The shipped port fails game, lobby, region, chat, diag, addon and idle_gate.** The cause is the intended
  `bytes = nil`:
  - The fakes cannot place nil code.
  - The test kick mode 'hold' calls kick_peer.
  - Chat and Region are off.

  It passes menu, scanner, sos, bingus_text, locales, ffi_names ×3 and entry.
- **Port-specific:** `tools/check_lazy.lua` 7/7 PASS. `tools/check_bytes_wine.lua` PASS (nil, no fault, on a
  no-access page).
- **Test remap** (`tools/port_tests.py`): test_scanner's two fixture constants, and MAP.json applied to
  `tests/reference/menu.lua` (two globals and the signatures).

## Live checks (read-only; run them through the game's memory tool)

**Run `live/blm_readonly.lua`** (LLM eval env). Run it on the ship while hosting a squad with the escape menu open on
the GAME tab, then again in a mission as host with an SOS Beacon called in. `BetterLobbyManagement.log` also states
what was checked or deferred at startup.

| Check | Where to look | Expect |
|---|---|---|
| **L0** | All 73 signatures vs MAP.json | `DIFFERENT 0`. "unreadable" means not run yet; that is fine. "unknown" is the 4 blocked rows. A dry run on the merged static capture gives match 69, DIFFERENT 0, unknown 4 |
| **L1** | `[game+0x2CE14C8]` | = exe+0x2870240 |
| | `[S+0xF8]` / `[S+0x10]` | = exe+0x28753B0 / +0x2871350 |
| | slots 0x40 / 0x198 | → exe+0x948F50 / +0x94A5C0 |
| | slots 0x348 / 0x350 | → exe+0x2F0BC0 / +0x2F0BE0 |
| | continent: `[[exe+0x2405AC8]+0xA8]+0x44` | your two-letter continent, signed in |
| **L2** | `u32 [[game+0x2CE1508]+0xAC29C]` | 3 ship / 4 mission |
| | `NC = [game+0x2E38228]` | local `+0xB398` = host `+0xB3A8` when hosting; peers `+0x16390` 1..4 |
| | host sync `+0x159B0+24` / `+28` | = 1 / 0 |
| | party byte `+0x162C8+0x529` | 0 |
| | join `+0x171D0` | 0 |
| | negative controls | the old offsets show other values |
| **L3** | roster `[game+0x2E38210]` | your peer id with your name at +8 (stride 0xC0) |
| | Text Language | index < 15; record code e.g. `us` |
| **L4** | `[NC+0x1D478]` → `+0x10` PlayfabLobby | state 3, members = squad size |
| | key cache | key 8 `0`/`1` (SOS), key 19 `0..3` (privacy) |
| | `+0x1B80` | 0–30 s |
| | `[NC+0x1F030]` | nonzero after a lobby search |
| **L5** | `[game+0x2E38218]+0x3CEAC` | 20 (server) before the mod writes, then your setting (default 5) |
| | `+0x3CEC8` | 30 |
| | `[game+0x2E381B8]+0x10BD74` | counts down while the scanner says RECHARGING |
| **L6** | screen `[[game+0x2E38170]+0xC8]` | non-null with the menu open |
| | `+8` | 0 on GAME |
| | button count | 2..5 |
| | types | game 0–4, mod 5–7 |
| | button label ids | game ids, or C67C7FAF on the mod's buttons |
| | cards | your squad's peer ids |
| | presenter `[[game+0x2E38160]+0x4388]` | non-null while open; byte +16 = 0 |
| **L7** | `byte [NC+0xC418]` | 1 with text chat on |
| **L8** (mission) | `[game+0x2CE1DB0]` | +8 = 1 while the SOS is on; +24 = beacons |
| | privacy `[GS+0xAC5D0]` | 0..3, your setting |
| **L9** | settings type 0x95 | uses 1, shared 0; type 0x91 gives -1 |
| | your player record (count `+0x2D800`, stride 0x16C0) | a slot with type 0x95 and uses 1, or 0 after the beacon |
| **L10** | OnlineOverrideData at `+0xC050` | capacity 512, multiplier 2, count > 0 |
| | continent ids at game+0x205D3F0 | the 7 ids |

**Then run `live/blm_page_dump.lua` (L11).** Run it after a Galactic Map scan, a chat line and, ideally, a kick by
you as host. It does two things:

- It dumps the three blocked ranges when they are readable (`BLM_DUMP` lines; feed the log to
  `tools/ingest_dump.py`).
- It prints the protection of the 42 game.dll code pages the mod reads or calls. 0x1 means not run yet; those
  natives wait and those checks are skipped.

**Functional checks, in order of risk:**

1. The log line `ready: … not loaded yet …` names what was deferred.
2. Scanner: RECHARGING counts from 5.
3. Escape menu as host with a squad on the ship: DISBAND, and PROMOTE once the game has searched.
4. CANCEL SOS in a mission: the SOS stops and the SOS Beacon is usable again (L9 uses 0 → 1).

## Not verified offline

- The 5 blocked rows above.
- Everything at run time: real LuaJIT in game, `ffi.load('kernel32')`, Bingus Shared Loader v18+, and which code
  pages are resident at boot. The probes and the log tell.
- That a host publishes its peer id under lobby key 3 on this build (G.FILTER_ARGS, medium).
- `src/diag.lua`, the test build's recorder, is not shipped and was left unported: its exe package-queue offsets are
  for 25480438.

## Tools

| Tool | What it does |
|---|---|
| `tools/lib.py` | MYC's helpers, plus `new_game()` with the 295 decrypted pages merged from other live captures and `page_state()` |
| `tools/dump_sigs.lua` | the signature tables, read from the upstream source |
| `tools/map_sigs.py`, `tools/resolve_more.py`, `tools/map_exe_slots.py` | where each signature is in the new build |
| `tools/fcompare.py`, `tools/native_bodies.py`, `tools/fwit.py`, `tools/palign.py` | instruction alignment |
| `tools/map_globals.py`, `tools/map_fields.py`, `tools/field_scan.py`, `tools/q.py` | globals and fields |
| `tools/build_map.py` | writes MAP.json |
| `tools/port_tests.py`, `tools/check_lazy.lua`, `tools/check_bytes_wine.lua` | tests |
| `tools/make_probes.py` | writes the live probes |
| `tools/ingest_dump.py` | takes in the page dump |
