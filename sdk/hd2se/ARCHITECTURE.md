# HD2SE architecture and implementation boundary

HD2SE is an experimental script extender foundation for Helldivers 2. Its purpose is to turn verified engine facilities into stable, discoverable Lua APIs that mod authors can combine without each mod rediscovering native layouts, inventing its own lifecycle, or retaining stale engine objects.

The first engine target is **entities and worlds**: enumerate a real current world,
identify real entities, and reject references after their lifetime ends. The Lua
adapter now has recorded live enumeration and owned object-lifetime evidence.
Game-scene transition evidence remains a separate gate. Public mutation follows
verified mapping; the native ABI draft still supplies no native DLL host.

## Starting point and ownership

Helldivers 2 already supplies a LuaJIT VM and Stingray Lua APIs. The maintained LLL source executes inside that existing VM, imports `ffi` and `bit`, and uses Lua 5.1 interfaces such as `loadstring` and `setfenv`. An extender should add services to that scripting system while preserving the game's startup/update contract. A second VM would introduce a separate state and synchronization problem without automatically gaining any more engine authority.

LLL already supplies startup ordering, modular Lua projects, isolated module caches, preflight before reload, diagnostics, typed console commands, and cleanup ownership. Its native helper serves manager input capture. These are useful host facilities, but they do not constitute a general engine binding bridge. The current loader pins a particular game build; a supported extender must maintain an explicit compatibility catalog rather than assume every update preserves layouts.

HD2SE consists of five layers:

| Layer | Responsibility | Availability in this foundation |
| --- | --- | --- |
| Lua kernel | Versioned services, capability queries, lifetime ownership and dispatch contracts | See the accompanying kernel source and README for implemented behavior |
| Bootstrap adapters | Connect startup, frame pumping and shutdown to a chosen loader | Opt-in LLL folder addon; existing loader runtime remains unchanged |
| Engine adapters | Map a supported game's real scripting/native operations into kernel services | Stingray Lua bridge with exact-build profile and recorded live lifetime tests |
| Native host | Load/query plugins, marshal callbacks onto the Lua thread and enforce lifetime contracts | ABI design only; unimplemented |
| Mod SDK | Lua API reference, examples, manifests and native interface declarations | Experimental, with explicit availability per interface |

Keep the kernel independent of a particular loader. An LLL adapter can use its direct lifecycle and `after_startup`; a BSL adapter can use BSL's supported authoring/update integration. Both adapters must supply the same pump and shutdown ownership contract. They are alternatives for hosting the foundation, not simultaneous providers of the same instance. Loader adapters must not copy another loader's implementation or assume its private closures are stable API.

[HD2Runtime's event scripting](https://github.com/SkyeShade/HD2Runtime/blob/master/sdk/docs/event-scripting.md) and [mod store](https://github.com/SkyeShade/HD2Runtime/blob/master/sdk/docs/mod-store.md) already describe useful generation-aware handles, events/timers, mod contexts and atomic local storage. An optional adapter can compose those facilities when they are present and verified. HD2Runtime is not a required dependency, and generic spawning must not be advertised merely because another runtime exposes a scripting entrypoint.

## Target platform invariants

These describe the complete platform contract. The current Lua prototype
negotiates exact service majors, uses integer plugin release versions, and
does not implement native thread enforcement, payload byte limits, per-frame
time preemption or immutable event payloads. See the README for present limits;
native interface minor negotiation and stronger host enforcement are future work.

1. **Truthful capabilities.** A declared interface, a registered provider, a compatible build, a successfully initialized session, and observed game behavior are distinct facts. A query must make those differences visible. An unavailable binding fails explicitly; it must not return fabricated entities or silently report success.
2. **Versioned contracts.** Name interfaces and events, negotiate an exact major and a minimum minor, and reject incompatible providers before activation. Append compatible optional fields under a new minor; change semantics or required fields under a new major. The initial SDK is experimental, so draft ABI stability is not promised.
3. **Single owner.** Every callback, registration, timer/task, hook, native allocation, snapshot and resource lease belongs to a mod instance or provider instance. Releasing that owner prevents new work and drains old work. A replacement waits for acknowledgement.
4. **Lua thread affinity.** Lua calls and game-object access execute on the host-owned Lua thread at a validated lifecycle point. Workers submit copied work for later dispatch. They never retain or enter a `lua_State` or dereference engine objects themselves.
5. **Bounded dispatch.** Limit listeners, queue size, payload bytes, task count, snapshot size and per-frame work. Defer tasks emitted during a dispatch to a later pump. Isolate Lua callback errors, report the responsible owner, and define overload behavior. Arbitrary native memory faults are outside Lua error isolation.
6. **No borrowed pointer escape.** Lua objects, event payloads, interface data and native buffers have stated lifetimes. Public engine identities are opaque handles, not addresses. Native plugin code is trusted process code; ownership checks and private Lua caches are not a security sandbox.
7. **Restore before reclaim.** Releasing a binding is separate from reclaiming its backing memory. Retain resources until native/GPU callbacks no longer reference them. If an operation cannot prove safe release, retain it until session end and require restart for replacement.
8. **Shared systems need coordination.** Centralize service/hook composition and detect conflicting owners. Restore a prior function only while the installed wrapper is still owned. Preserve argument/return cardinality, including trailing nils. Avoid multiple independent global update wrappers when a host callback exists.

## Identity, generations and worlds

The native host owns a registry mapping each public handle to a record containing session identity, world identity/generation, object identity/generation, backing provider, and permitted ownership. Handles must not expose raw pointers or be reused within a session. World teardown invalidates its objects before later queued callbacks can access them. Replacing an object at the same address produces a new generation and a new public identity.

The engine adapter must obtain lifetime signals from a verified engine mechanism. A Lua counter that advances when a mod reloads cannot stand in for native object destruction. If reliable destruction signals are unavailable, resolve and validate the object again on every operation, using only proven identity/liveness checks. Validation and native reads must share one verified engine lifetime/synchronization boundary covering the whole operation; an earlier `is_valid` result cannot protect a later dereference against destruction on another engine thread. If that cannot be done safely, return unavailable.

Enumeration produces a bounded immutable snapshot of candidate handles. That snapshot describes membership at an observation point; it does not keep game objects alive. Metadata reads revalidate the current world and object generation immediately before touching the backing object. A caller may enumerate an entity, then receive `stale` when it reads that entity after the world changed. This is expected lifetime behavior.

Snapshot ownership belongs to the requesting mod. Closing a snapshot releases host inventory storage, without destroying game entities. A world transition invalidates active access even if the immutable inventory remains readable for diagnostics. Saved files must store stable data identifiers and schema versions, never session handles or native pointers.

## Entity/world vertical slice

The first useful feature is a read-only inspector backed by real engine data. Its implementation should establish this chain:

1. Resolve the current supported session/world through a verified game Lua API or a validated native binding profile.
2. Enumerate the engine's actual entity inventory at a safe thread/lifecycle point, with bounded cost and a defined complete-or-error result.
3. Convert backing identities to public opaque handles and attach session/world/object generations.
4. Expose copied world/entity metadata and a fresh validity result; make missing worlds, unsupported kinds, stale entities and unsupported builds explicit.
5. Publish world entry/exit and entity lifetime events only after their real sources, ordering and teardown behavior are understood.
6. Exercise repeated inspection, world transitions, destruction/replacement and reload. Verify that no stale access reaches native memory and no duplicate subscriptions survive cleanup.

An initial adapter can use existing engine Lua functions where they are sufficient. Native code is justified when a required facility is unavailable through the game's scripting surface and a verified binding can provide it. Each field needs provenance: which engine function/property supplies it, which builds were verified, when it is valid, and what happens when it is absent.

The draft native interfaces `hd2se.world` and `hd2se.entity` specify this contract. They are not registered by the current runtime. A fake adapter used in contract tests validates SDK behavior; it cannot satisfy the real enumeration milestone.

After read-only enumeration and lifetime validation pass, add one narrow mutation with a meaningful readback and reversal contract. Choose the operation from mapped engine facilities; do not guess at spawning or assume an arbitrary native address represents a callable engine function. Before implementing a mutation, identify local/server authority, argument domains, ownership, failure behavior, cleanup and world-transition behavior. A success boolean alone is insufficient.

## Native plugin host design

[`include/hd2se_plugin.h`](include/hd2se_plugin.h) is a standalone C99/C++ **future ABI contract**. No plugin DLL is currently loaded, and none of the declared exports/interfaces is wired into LLL. Its main rules are:

- Query compatibility before load using immutable host/game identity. Query performs no engine access or persistent registration. Unsupported builds fail before activation.
- Use fixed-width values, caller-owned outputs, struct size/version prefixes, explicit calling conventions, and opaque handles. Do not exchange C++ objects, allocator ownership, exceptions or platform-sized integer types across the ABI.
- Request a named interface with an exact major and minimum minor. Interface tables remain valid through the plugin's completed unload; revoked providers retain host trampolines that fail explicitly.
- Marshal tasks/events/binding installation to the host-owned Lua thread. A borrowed Lua state exists only during the callback and is never retained by plugin workers.
- Install Lua functions through host-owned revocable trampolines. Cached Lua closures must remain safe after revocation. Never leave a closure calling machine code from an unloaded DLL.
- Begin unload once, stop new work, drain queued/active callbacks and release resources, then acknowledge. Polling supports asynchronous completion. Failure keeps the DLL and backing storage retained rather than forcing unload. Failed partial load uses the same cleanup path.

This follows the useful architecture patterns visible in [SKSE's plugin interface](https://github.com/ianpatt/skse64/blob/master/skse64/PluginAPI.h) and [F4SE's plugin interface](https://github.com/ianpatt/f4se/blob/master/f4se/PluginAPI.h): negotiated interfaces, VM binding, deferred tasks, lifecycle messaging and versioned serialization. HD2SE must implement its own game-specific bridge and preserve source/license boundaries. Matching a header pattern does not supply the engine research those projects performed.

## Future domains and persistence

Use the same provider/ownership model for input/UI, camera/rendering, resources/materials, audio, animation, physics, missions, inventory, extensible data and developer tooling. Keep domain schemas separate so an entity API can evolve without breaking an unrelated UI provider. Offer optional interfaces rather than one mandatory giant dependency surface.

Persistence should use stable mod IDs and versioned schemas, atomic local writes, migration and explicit missing-provider handling. Separate transient session state from saved data. A future serialization interface needs defined save/load phases, maximum sizes and resolve/remap behavior; it must not save pointer values or opaque session tokens.

Network authority belongs in every relevant API contract. Local presentation is distinct from host-authoritative simulation and server-owned progression. A client-side extender cannot make an unavailable server operation valid. Do not promise replication, shared world mutation or generic spawning until the actual ownership and replication mechanisms are mapped and tested. Event messages must describe their origin and authority; plugin-emitted events do not become authoritative engine events.

## Build adapters and evidence gates

Keep game-specific bindings in explicit adapter/profile modules. A profile records supported Steam build identity, executable/game/Lua identities, binding provenance, available interfaces and validation status. Unknown builds fail closed for native binding access while pure Lua tooling may remain available. Do not silently substitute an old profile or treat a PE timestamp alone as proof of native ABI equivalence.

Each feature should move through these separately recorded gates:

| Gate | Evidence required | What it establishes |
| --- | --- | --- |
| Source contract | Documented signature, owner, thread, version and failure contract | Intended API behavior |
| Isolated tests | Fake adapter/contracts; real DLL compilation checks where relevant | Kernel/ABI consistency, not live engine behavior |
| Packaged candidate | Standalone payload, source inputs, hashes and dependency inventory | Reviewable artifact identity |
| Installed identity | Destination bytes/hashes and retained rollback receipt | Which bytes were installed |
| Host activation | Loader/provider acknowledgements for the exact session/build | Initialization and negotiated availability |
| Engine proof | Real observed outputs/readbacks/lifetimes for the promised operation | Actual in-game behavior within the tested scope |
| Release readiness | Compatibility record, docs, cleanup/reload evidence and package/public-download verification | A supportable release of the proved scope |

The current opt-in LLL validation addon has been installed for the explicitly
requested live tests. Its recorded proof distinguishes actual enumeration,
owned native Unit destruction/replacement, world retirement and gameplay scene
transitions. Existing loader archives and unrelated mods were not replaced.
Native DLL hosting and publication remain separate deliberate steps.

## Rollout phases and completion criteria

| Phase | Work | Completion criterion |
| --- | --- | --- |
| 0: SDK foundation | Lua kernel, version/capability semantics, ownership, dispatch, docs and ABI draft | Meaningful isolated contracts pass; no engine support implied |
| 1: Bootstrap | One opt-in loader adapter, pump, diagnostics and acknowledged shutdown | Exact session initializes once, pumps once per frame and cleans up without duplicates |
| 2: Read-only world/entities | Real adapter, supported-build profile, inventory snapshots and fresh validity | Real entities are observed; world/destruction transitions reliably reject old handles; bounded frame cost and cleanup verified |
| 3: First mutation | One mapped operation with authority, readback and reversal | Exact desired effect observed, invalid inputs rejected, lifecycle cleanup demonstrated |
| 4: Native host | Query/load/unload, versioned interfaces, revocable Lua bindings and task/event dispatch | A sample plugin safely loads, fails compatibility checks, survives cached-closure revocation and drains before unload |
| 5: Broader mod platform | Additional domain providers, persistence, compatibility catalog and author tooling | A second independent mod combines stable services without private offsets or special-case loader changes |

Continue only when the preceding phase's evidence supports it. A wide list of callable names is useful documentation; rich mods become dependable when those names describe stable ownership, verified engine behavior and recoverable lifecycles.

Relevant loader references: [BSL third-party API reference](https://github.com/CowboyBingus/BingusSharedLoader/blob/main/docs/THIRD_PARTY_REFERENCE.md), [BSL authoring guide](https://github.com/CowboyBingus/BingusSharedLoader/blob/main/docs/AUTHORING.md). Local starting points are LLL's `src/manager.lua`, `src/project.lua`, `src/live.lua`, `src/start.lua`, `docs/MODULAR-PROJECTS.txt` and `docs/R24-API-AND-PARITY.txt`.
