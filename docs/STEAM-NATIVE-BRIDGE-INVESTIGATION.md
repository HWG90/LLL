# Current Steam native bridge investigation

Status on October 20, 2026: gameplay keyboard suppression and a native player
adapter remain unimplemented. The published Steam preview documents this
limitation. A plugin name, callback table, or API address alone would not prove
suppression or correct restoration.

## Supplied section dump

The user identified `hd2-dump.7z` as coming from the current game build. Its
SHA256 is `a4d1a4bbc6fd4d0a0a785f7f453b121881c2c011052f16671dc51fc045e1ebab`.
It contains eight raw section files, rather than a complete process dump or PE
image. The supplied bytes remain private and are not included in this repository
or a release.

The section sizes match the installed executable with SHA256
`2ce8b3d74c5573088e4211b060ced0963f1fc1e74526e2645399780b8fb13ff7`.
Its entire 71,168-byte on-disk resource section matches the capture. Comparison
of 181,594 relocated pointers gives one consistent captured image base. These
checks support the current executable mapping; the archive does not independently
identify a process or session.

Coverage is incomplete: 4,505 of 5,259 pages in the full text file are entirely
zero, and the supplied unwind section is entirely zero. The separate text-head
file contains a first page missing from the full-text file. Zero-filled regions
are not treated as recovered code, and the two captures are not silently merged.
No live process access or game changes were used for this analysis.

## What the captured loader establishes

Bounded disassembly recovered a generic native plugin-load path. It resolves
`get_plugin_api`, requests IDs 0, 18 and 19, and passes the resulting interfaces
to registration. The observed registration calls the plugin's name function at
offset zero. This agrees with the corresponding parts of the
[pinned Autodesk PluginApi header](https://github.com/AutodeskGames/stingray-plugin-api-samples/blob/e9d937a013e4aa1f25b6f7d9bdee0ca985455cfd/stingray_sdk/engine_plugin_api/plugin_api.h).

Separate checks requiring non-null callbacks at offsets 0x58, 0x68, 0x90 and
0xa0 belong to the specialized `game/game.dll` path. They are not evidence that
the generic plugin loader rejects the name-only diagnostic. Independent review
found no concrete name-only table incompatibility in the captured generic path.
This is partial layout evidence, not complete ABI verification or live acceptance.

The general path copies a bounded UTF-8 path, converts it to UTF-16 and invokes
a module-load operation. No rejection of absolute paths or alternate DLL naming
rule was established. Captured directory construction uses `plugins`, with a
separate path containing `engine` and `win64`; missing helper bodies prevent
treating that as proof of another installation location.

## What remains missing

The engine API getter passed to native plugin callbacks is referenced at
executable RVA 0xa6f70. Its first 2,048 captured bytes are zero. No current
ScriptApi/InputCApi table, callable action gate, or restoration contract was
recovered. The Lua `load_plugin` and `load_relative_plugin` method names are
present, but their binding code was not identified in the captured pages.

The prior one-shot name-only load tests still returned nil, and the startup
observer still reported only the three stock plugin names. This dump does not
identify the failing stage of those live calls or establish an OS signature
rejection. It provides no basis for changing security policy.

The shipped `support_plugin_reload = false` setting is a separate unresolved
lead. Its semantics were not established and it was not changed.
[`Application.settings()`](https://help.autodesk.com/cloudhelp/ENU/Stingray-Help/lua_ref/ns_stingray_Application.html)
returns `script_data`, so an absent key there cannot establish the value of a
top-level engine setting. The corresponding read-only probe stayed offline.

Further bridge work requires evidence for the actual Lua-to-native load route
or a successfully accepted plugin and compatible engine API. Native input or
player writes have not been added. Any eventual input gate must still be tested
for native action isolation, UI input, ownership, close/blur restoration,
lifecycle transitions and deployed callback cost.
