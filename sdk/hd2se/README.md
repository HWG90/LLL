# Helldivers 2 Script Extender: HD2SE

Experimental **0.1.1 Lua binding candidate**, October 13, 2026. The name is provisional.
This additive SDK lives in the owning LLL source repository. An opt-in LLL folder
addon now connects its Entity/World service to the real game Lua APIs. The native
DLL host remains a future interface. The kernel can become a standalone project
without depending on LLL.

The objective is a stable mod platform that extends the game's existing Lua
scripting with independently versioned engine services and native plugins.
Mods should express intent through documented APIs, while build adapters own
engine structures, execution context, object lifetimes, and compatibility work.
The first domain is **entities and worlds**.

## Implemented in this candidate

- A pure Lua 5.1/LuaJIT kernel with service major-version negotiation and
  capability discovery; missing capabilities have explicit reasons.
- Manifest/API validation, deterministic dependency ordering, missing-dependency
  and cycle preflight, and rollback of newly loaded plugins on startup failure.
- Mod-owned services, subscriptions, tasks, opaque handles, and cleanup.
- Separate update/render task phases, bounded queues, task budgets, callback
  error isolation, next-pump deferral, and nonreentrant lifecycle operations.
- World epoch invalidation; optional caller ownership and handle kind checking.
- Explicit cleanup acknowledgement and retry. A pending dependent's cleanup
  retains its dependencies; replacement is blocked until release succeeds.
- An Entity/World provider: bounded world/unit enumeration,
  fresh membership and generation checks, owned handles, copied descriptions,
  and rollback of partial handle allocation.
- A real Stingray Lua bridge, exact-build profile, LLL bootstrap, finite native
  lifetime validation and a scene-transition observer.
- Offline contracts, a native C ABI draft, and an implementation roadmap.

The included profile targets the exact executable/game/Lua hashes in
`live/profile.lua`. Real in-game validation has established enumeration, native
Unit destruction, replacement without reviving the old reference, and owned
world retirement. The gameplay scene round-trip is tracked separately in the
live evidence. These are narrow, explicit support claims for the tested build.
Native DLL loading, new native Lua registrations, general hooks, public entity
mutation/spawning, replication and persistent stores remain future work.

## Layout

| File | Purpose |
| --- | --- |
| `src/kernel.lua` | Loader-independent kernel factory |
| `src/world_provider.lua` | First Entity/World service contract and adapter |
| `src/stingray_bridge.lua` | Genuine engine weak references, fresh native inventories and update leases |
| `live/` | Exact-build profile, LLL bootstrap, controlled validation and scene observer |
| `examples/entity_inspector.lua` | Consumer plugin; requires a world provider |
| `include/hd2se_plugin.h` | Experimental, unimplemented native ABI contract |
| `tests/` | Isolated LuaJIT contracts and Python runner |
| `tools/package.py` | Allowlisted source-candidate packaging |
| `tools/build_live.py` | Build a self-contained LLL folder addon; installation is explicit |
| `ARCHITECTURE.md` | Native design, future domains, research and acceptance gates |

## Start a host

```lua
local Kernel = dofile("sdk/hd2se/src/kernel.lua")
local host = Kernel.new()

-- Portable services need no game mapping. Engine services require the exact
-- executable/game DLL hashes plus a trusted binding validator.
assert(host:register_provider({
    name = "example", major = 1, scope = "portable",
    capabilities = { "example.echo" },
    methods = { echo = function(context, value) return value end },
}))

assert(host:load({{
    manifest = { id = "demo", version = 1, api = 1,
        services = { example = 1 }, capabilities = { "example.echo" } },
    start = function(api)
        local example = assert(api.services.get("example", 1))
        assert(example.echo("ready") == "ready")
        api.on_cleanup(function() return true end)
    end,
}}))

-- A future host adapter invokes these from verified engine phases.
host:pump("update")
host:pump("render")
assert(host:shutdown())
```

Host methods use colon syntax; plugin SDK methods and service methods use dot
syntax. Service callbacks receive `(context, ...)`; context contains `plugin`,
`world_epoch` and the current `phase`. Return values preserve nil slots.
Refusals return `nil, reason`; capability queries return `false, reason`.
Callback faults enter a bounded diagnostics ring instead of escaping the kernel.

## Manifest and plugin SDK

The experimental manifest uses positive integer release versions. `api = 1`
requests kernel API 1. `dependencies = { other_mod = 2 }` requires that plugin's
release version 2 or later; `services = { world = 1 }` requires exact service
major version 1. `capabilities` is a dense array of required capability names.
These are dependency/availability checks, not a security permission system.
The `hd2se` plugin ID and its namespace are reserved for the host.
Loaded plugin IDs cannot overlap by dotted prefix (`a` and `a.child`), so their
service/event namespaces have one owner.

| SDK call | Contract |
| --- | --- |
| `api.capabilities.has(name)` | Check a currently registered capability |
| `api.services.get(name, major)` | Acquire an owner-bound service facade |
| `api.services.publish(name, major, methods)` | Publish a portable service under `api.id .. "."` |
| `api.events.on(topic, callback)` | Subscribe; returns a cancellation function |
| `api.events.emit(topic, payload)` | Queue an event in the plugin's own namespace |
| `api.tasks.defer(phase, callback)` | Queue update/render work; returns cancellation function |
| `api.on_cleanup(callback)` | Add a release callback; only `true` acknowledges release |

No automatic API negotiation downgrade occurs. Plugin code can request alternate
service versions and handle refusal explicitly. This prototype has one provider
per service name; parallel service major versions are future work.

Events are delivered on the update pump; render pumps execute render tasks only.
Callbacks/subscriptions are selected at delivery, so cancellation takes effect
before invocation. Event payloads are shared Lua values: immutable payloads are
a producer contract, not enforced isolation. New events/tasks wait for the next
eligible pump. Defaults bound both queues to 256 entries, tasks to 64 per pump,
subscriptions to 1024, plugins to 128, providers to 256, handles to 4096, cleanup
callbacks to 256 per plugin, nested service calls to 32, and diagnostics to 32 errors. Task count budgets do
not preempt a long-running Lua callback; timing telemetry and overrun policy are
future work.

Public SDK calls become inactive before cleanup. Release callbacks must capture
their private restoration routines at resource acquisition. Cleanup runs LIFO,
stops at the first failed/unacknowledged release, and retries that release on a
later `stop`/`shutdown`. Acknowledged releases are never repeated. Resources are
not declared reclaimed merely because their facade has been revoked.

## Entity/World adapter

`world_provider.create(host, adapter, profile)` returns the `world` service
descriptor for explicit registration. A trusted adapter supplies `worlds`,
`units`, `world_key`, `entity_key`, `describe` and `with_read_guard`. The read guard
must protect validation and access together against native lifetime/inventory
changes; a prior liveness check alone is insufficient. Keys must include reliable
native lifetime/generation identity. A raw address, stringified userdata, or
an `alive` result alone cannot establish that identity. `profile.builds` lists
exact lowercase SHA-256 pairs (`exe_sha256`, `game_sha256`), and
`profile.validate(build)` must verify binding contracts before use. Host build
identity must be computed by the real bootstrap; this kernel does not hash or
authenticate the caller's claims.

The update-phase service offers `world.list(limit)`, `world.units(world_handle,
limit)`, `world.describe(entity_handle)` and `world.release(handle)`. Handles
belong to the requesting plugin. Successful enumeration returns the list plus
`{ total, returned, truncated }` metadata, making partial results explicit.
Enumeration is bounded and descriptions are
copied semantic data. Consumers must release snapshots when finished;
world transitions and plugin teardown also revoke handles. The host must call
`advance_world()` on confirmed lifecycle transitions. That cancels queued work
and invalidates every handle before queuing `hd2se.world_changed`.

The included `stingray_bridge` is the first real adapter. It retains genuine
engine Unit weak references; private serial keys identify those references and
are never reconstructed from addresses, resource names or `Unit.id`. It checks
`Unit.alive`, fresh membership and scene identity before metadata access. Default
metadata contains only `alive` and the copied 16-digit resource hash. Position
reads remain disabled in the live profile.

The bridge borrows access only inside the actual LLL update callback, on its
recorded OS thread, in a synchronous coroutine lease. It uses public engine Lua
bindings and their native weak-reference contract; this is not a mutex for raw
native pointers. Failed/incomplete scans preserve the last committed registry
and refuse consumers. World catalog changes and `World.levels` membership changes
advance the global inventory epoch before dispatch, including when the engine
reuses the same World between scenes. Adding an unrelated preview world can
therefore invalidate retained handles; callers reacquire them after the event.

All callbacks now prohibit yielding. Suspension restores kernel dispatch state,
revokes the borrowed lease, and reports an error. Shared-VM code can retain its
own coroutine, but it cannot regain a revoked SDK owner or native read lease.

## Real-game LLL integration

```powershell
py -3 sdk/hd2se/tools/build_live.py --output dist/releases/hd2se-live-20261013
```

The resulting ZIP contains `Mods/hd2se_live_validation`, with all required Lua
modules. Its deliberate validation mode creates an empty private world and two
camera-only units, verifies their destruction/replacement/retirement, then
observes real scene changes. It never selects borrowed units/worlds for mutation.
It runs native work at 0.5-second intervals and exposes `HD2SE` after activation.
This is a development validation addon, not a general gameplay mutation API.

`--install` activates a new owned folder only after exact game-file hashes,
isolated contracts, complete Lua syntax and ZIP identity checks pass. It refuses
existing deployment replacement. The running LLL can discover it without a
loader replacement or game restart. JSON-lines evidence is written through LLL's
log API as `HD2SE_LiveValidation.log`.

A cooperating mod waits for `HD2SE.ready`, calls `HD2SE.load({definition})`, and
uses the SDK passed to its `start`. `HD2SE.stop(id)` performs owned teardown;
`HD2SE.status()` returns copied provider/bridge/validation diagnostics. World
reads execute through `api.tasks.defer("update", callback)`. Retained handles
are intentionally session-local; subscribe to `hd2se.world_changed` and
reacquire them after transitions. The public facade exposes no native references.

## Validation and packaging

From the LLL root (or extracted source-candidate root):

```powershell
py -3 sdk/hd2se/tests/run.py
py -3 sdk/hd2se/tools/package.py --output dist/releases/hd2se-foundation-20261013
```

The test runner loads the existing game `lua51.dll` into a fresh Python-owned
state. It does not attach to the game process, invoke real engine functions,
change game files, or deploy anything. `--lua-dll` selects another compatible
Lua 5.1/LuaJIT DLL. The native ABI draft requires separate C/C++ syntax checks;
no native host implementation is implied by a successful header compile.

The packager verifies ZIP bytes/CRC and reruns the contracts from an extracted
copy using only packaged SDK sources. It retains hashes and validation output
beside the ZIP.

The source ZIP contains only this SDK's allowlisted files. It is a development
candidate, not an installable game addon. See `ARCHITECTURE.md` for bootstrap,
native bridge, entity integration, compatibility and live acceptance milestones.

## Extensibility principles

Build on the game's existing LuaJIT VM and cooperate with existing loaders;
avoid replacing their startup resources or callback chains without a defined
integration contract. Adapt useful public APIs from HD2Runtime and other
providers instead of duplicating their catalogs. Keep gameplay, camera,
rendering, input, audio, assets, local state and tooling independently versioned.

This direction follows the versioned interfaces, VM registrations, tasks and
messaging seen in [SKSE](https://github.com/ianpatt/skse64/blob/master/skse64/PluginAPI.h)
and [F4SE](https://github.com/ianpatt/f4se/blob/master/f4se/PluginAPI.h), with
HD2-specific ownership and lifecycle contracts. Existing integration references:
[BSL authoring](https://github.com/CowboyBingus/BingusSharedLoader/blob/main/docs/AUTHORING.md),
[HD2Runtime scripting](https://github.com/SkyeShade/HD2Runtime/blob/master/sdk/docs/event-scripting.md).

All Lua mods share the host VM; namespaces, caches and cleanup are not a sandbox.
Native access violations cannot be caught by Lua `pcall`. Provider availability
and evidence strings are host declarations; live support requires actual game
validation for the exact build and operation. No guarantee of arbitrary engine
features or server-authoritative changes follows from the SDK architecture.
