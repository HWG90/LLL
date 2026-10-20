# LLL Lua 5.1 compatibility inventory

Target: the shipped Windows x64 Steam build 25988413. This is an inventory of
LLL itself, not an acceptance report for third-party/native mods.

The Steam builder reuses 28 of the normal builder's 37 module entries, replaces
three adapters and excludes six native-only modules. An actual `lupa.lua51`
parse of maintained `src/**/*.lua` accepts 48 of 49 files. The excluded
`discovery_hash.lua` uses LuaJIT `ULL` literals. Syntax acceptance alone does not
establish that a module's native API calls are usable.

| Scope | Steam contract |
| --- | --- |
| Shared runtime | Config, cleanup, after-startup, capabilities, manager, commands, project loader, live/catalog watching, discovery, provenance, controls and shared UI logic are reused. |
| Replaced adapters | `platform` -> `steam/platform`; `ui` -> `steam/ui`; `ui/capture` -> `steam/capture`. |
| Steam services | `steam/transport`, `steam/input` and `steam/input_service` use the one authenticated external-helper connection. `trusted.capture(..., {runtime='lua51'})` avoids FFI initialization. |
| Excluded native-only entries | `vendor/bsl_bingus_memory`, `build_gate`, `vendor/bsl_jit_guard`, `jit_churn`, `jit_budget`, `discovery_hash`. |
| Conditional native health | Shared `vendor/bsl_health` parses, but image/crash helpers stay inactive without a native `platform.health` provider. |
| Optional tools | `steam/probe`, `steam/dev` and the separate poll-cache addon are outside the normal Steam assembly. The developer command relay requires its explicit build flag. |

## Local declared-import improvement

`src/project.lua` now streams private `mod.require` discovery rather than keeping
a table per source token. Unrelated strings and comments are skipped without
copying or compiling them; ordinary unescaped import names also avoid a compiler.
The result retains unique module paths, with the existing project limit of 512.
Paths retain their existing 240-byte validation. Actual quoted import arguments
are limited to 960 encoded bytes on Lua 5.1 and 2,400 on LuaJIT (including its
Unicode escape spellings); giant actual arguments fail before copying/compilation. On LuaJIT, long
`\z` whitespace is compacted with bounded storage first, preserving its existing
literal semantics without copying the giant whitespace body.

The scanner accepts Lua call sugar (`mod.require 'src/helper'` and long literals),
handles CR/LF comment endings and drops the first newline in long literals as the
Lua runtime does. Missing literal dependencies in entries or helpers are refused
before execution. Existing qualified-receiver and first-literal expression
handling is retained; aliases and arbitrary dynamic expressions are not fully
established statically. The native `ffi`/`bit`/`jit` guard remains separate.

This improvement is included in the installed review candidate. Tests measure
scanner allocation separately from the unavoidable compilation/storage of full
module source. No idle polling, game input behavior or Photo files are changed.

One isolated Lua 5.1 comparison on the same 400,032-byte generated fixture:

| Scanner | CPU time | Temporary allocation with GC stopped |
| --- | --- | --- |
| Previous token array | 845 ms | 64,449 KB |
| Streaming scanner | 71 ms | 1.38 KB |

Input storage and full-module compilation are excluded. Four-megabyte
literal/comment fixtures use under 2 KB in Lua 5.1; a dense four-megabyte code
fixture uses under 1 KB and approximately 0.64 seconds. These are offline scanner
measurements on the development machine, not deployed frame-time measurements.

## Offline test entrypoints

```powershell
py -3.14 tests/test_project_import_preflight.py
py -3.14 tests/test_steam_native_preflight.py
py -3.14 tests/test_steam_runtime.py
```

The new scanner tests use actual Lua 5.1, plus the existing `lupa.luajit21` fixture
when available. The runtime suite reuses 19 portable contracts and checks the
compiled Steam startup/lifecycle. Existing input, capture, broker, launcher,
archive and real helper transport suites cover their separate contracts.
`tests/run.py` targets the historical installed LuaJIT DLL; it is not the Steam
test runner and is not represented as a fully passing native-game suite.

## Local recovery follow-up

The current local candidate also removes transient request/reply files from
directory enumeration. Listing records use the existing wire format, Unicode
names, attributes and timestamps in a reused memory buffer capped at 64 MiB and
100,000 entries. A failed or partial enumeration reports an error. Incomplete
scans cannot retire project watches or sweep stale discovery entries; missing
directories remain valid empty results. Actual source writes still generate
notifications.

An isolated Windows helper comparison used the previous shared-input helper and
400 requests per helper/fixture, in baseline/candidate/candidate/baseline order:

| Directory fixture | Previous mean | Candidate mean | Candidate P95 |
| --- | --- | --- | --- |
| One file, one directory | 1.980 ms | 0.082 ms | 0.160 ms |
| 96 files, 12 directories | 2.858 ms | 0.894 ms | 1.291 ms |

Payloads matched byte for byte on the unchanged fixtures. These timings cover
explicit listing requests in an isolated service, not game-frame cost.

Completed catalog scans now release watches belonging to retired projects and
prune stale source, fingerprint and metadata caches. Configured roots and
same-directory successors keep their watches. Running instances, retained
instances and frozen preflight snapshots preserve their existing lifecycle.
A failed unwatch remains tracked for a later full scan; it creates no idle retry
loop. A Lua 5.1 stress fixture completed 320 project removals under a two-watch
limit, with no additional reads, stats or listings during unchanged idle scans.

The [input service](STEAM-INPUT-SERVICE.md#mcm-frontend-registration) also adds
explicit MCM frontend registration. This lets MCM use the same service while
truthfully reporting its menu open, retaining token ownership and foreign-owner
exclusion. It does not add gameplay keyboard isolation.

The review candidate was installed on October 20, 2026, with patch/helper hashes
verified and configuration preserved. Fresh startup logs acknowledge LLL and
MCM 0.1.74-lua51.1, and the user reports the MCM menu open. Full transition
acceptance and fresh performance measurements remain pending.

## Remaining limits

* Arbitrary native LuaJIT mods need individual ports; dynamic native imports can
  evade static discovery.
* Shared camera input suppresses mouse look, but gameplay keyboard/action
  isolation is unfinished.
* The helper/runtime are gated to the exact supported game hashes.
* The current candidate ZIP embeds its build machine's resolved game path.
  Deployment tooling updates an existing reviewed patch, not a clean install.
* Runtime performance and full transition acceptance of this scanner follow-up
  need fresh deployed measurements. Offline results do not establish them.
