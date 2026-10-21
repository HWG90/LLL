# Replacing FFI-dependent functionality

Target: Steam build 25988413, Lua 5.1. This is a porting map, not a declaration
that old native mods work unchanged. R34's installed runtime stays unchanged.

LuaJIT [FFI](https://luajit.org/ext_ffi_api.html) supplies C types, native symbols,
library loading, pointer casts and callbacks. Replacing the name `ffi` would
not recreate those implementations. A port should request the operation it
needs through a documented provider, or use a portable data library.

| Old dependency | Replacement | Current boundary |
| --- | --- | --- |
| C integer bit fields and byte conversions | `sdk/portable/lll_portable.lua` | Standalone Lua 5.1 source; its README defines supported types and validation. |
| 64-bit IDs stored in C unions | Exact low/high 32-bit words or hexadecimal IDs | Do not convert an arbitrary u64 to one Lua double. Engine IdString64 values still need their native lifetime rules. |
| `GetAsyncKeyState`, cursor reads and mouse capture | `LiveLuaLoader.input_service` | R34 opt-in keyboard and pointer leases; one combined sample per active frame, release on close. Ordinary closed-menu shortcuts can use the exposed engine keyboard API. |
| Game-window PNG capture | `LiveLuaLoader.capture_service` | Asynchronous SDR capture and owned job cleanup already exist; HDR remains unqualified. |
| File enumeration, metadata, watches, directory creation, atomic writes and resource hashes | Existing external filesystem service; scoped project read/config APIs | The helper has real implementations. Its private wire/platform functions are not a public general-purpose FFI namespace. More mod-facing file/export operations need an explicit scoped API. |
| Clipboard, file dialogs, compression and additional codecs | Named external helper jobs | These need specific implementations and batching; exposing a capability flag alone does not provide them. |
| Existing exposed Unit/World/Material operations | Current Stingray Lua bindings | Replace calls individually and verify argument types, lifetime and observed behavior on this build. |
| Engine C function pointers, renderer buffers, private combat initializers and game-memory layouts | An admitted in-process binding with verified current-build functions | Not restored. External helper pointers refer to the helper, not the game's address space. |

## First implementation

The standalone portable library supplies actual data operations without a DLL,
IPC, frame callback, watcher or idle loop. Mods explicitly vendor/import it; it
does not impersonate `ffi`, `bit` or `jit`, and does not relax native-import
checks. Unsupported pointer/function operations remain unavailable.

This recovers a reusable portion of data-processing code. It does not provide
mutable native float arrays, C struct ABI layout, pointer dereferences or engine
renderer calls. Large LUT/image transformations should use bulk operations;
one IPC call per pixel, scalar or draw would be an unsuitable replacement.

The [SDK usage and qualification notes](../sdk/portable/README.md) include six
focused tests, four import-guard checks and 128 golden cases passed in the
running Steam Lua 5.1 VM. Small live compute batches were below clock resolution;
that is not a zero-time result or a performance qualification of a complete mod.

## Native binding admission

The [current investigation](STEAM-NATIVE-BRIDGE-INVESTIGATION.md#lua-native-module-route)
records `package.loadlib` rejecting the tested module with error 577 before its
entry point became callable. The enforcing component remains unidentified.
Neither the existence of `package.loadlib` nor an FFI-shaped Lua table resolves
that admission requirement.

An eventual native provider also needs the correct current-build engine
interfaces, callback execution context and ownership-aware cleanup. The HD2SE
header is a host contract; its declarations are not an implemented native host.

### Optional FFI worker

LuaJIT could also run FFI-dependent data/OS jobs in an external worker. That
would provide real FFI within that worker's own process, with explicit input and
output messages. It would still require changes to the caller and would not
make worker pointers valid in the game. No such general worker is implemented
by this SDK. Prefer bounded bulk jobs over a round trip for every C call.

## Concrete consumer gaps

| Consumer | Portable/service route | Remaining native dependency |
| --- | --- | --- |
| Epic LUT | Input/cursor leases; existing filesystem operations; data conversion. Clipboard, process/file actions and LZNT1/XPRESS codecs need new helper jobs. | `vendor/engine.lua` obtains C API function pointers and creates/updates/destroys renderer buffers. Integer codecs cannot replace that renderer. Its LuaJIT `ULL` literals also require source changes. |
| Height Over Bore | Existing engine Lua operations where available; integer decoding can share the data library. | `src/memory.lua` and the backend use process-memory operations and build-specific layouts. They are not helper-local buffer operations. |
| Photo Mode | Current Steam adapter already uses input/capture services and exposed Unit/Camera/World bindings. | Legacy native profiles, depth-resource/HUD bindings and memory-based AI/hover controls require separately verified providers. Selected-subject references do not establish an authoritative local-player reference. |
| MCM | Current Steam adapter uses the shared input service. Directory creation already has a replacement; fixed URL opening can become a helper job. | Native-entry tab integration and binding-record writes still use game functions or game memory. |

Epic LUT's `binding_provenance.lua` needs SHA-256. The helper's resource-name
hash is a different algorithm and must not substitute for it. A pure Lua
SHA-256 implementation already exists in Bridge Combat's compatibility source;
its licensing, dependency and performance should be checked before reuse.

## Porting order

1. Replace data-only dependencies with the standalone library and compare exact
   results with known binary fixtures and a LuaJIT oracle where applicable.
2. Route input/capture and file operations through existing providers. Cache
   unchanged state; perform work on explicit actions or lifecycle events.
3. Implement missing helper operations as bounded, owned bulk jobs, choosing
   actual mod use cases rather than general arbitrary DLL calls.
4. Keep game-native features unsupported until their binding and behavior have
   been established. Report source tests, installed bytes and live acceptance
   separately.
