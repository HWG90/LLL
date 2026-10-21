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

Captured startup code also checks the optional callback at offset 0x8 before
calling it with the engine API getter in the first argument register. This
matches the pinned `PluginApi.loaded(GetApiFunction)` contract. A successfully
accepted plugin could therefore receive the getter through the normal callback;
no address needs to be hard-coded. Actual acceptance and the returned service
interfaces still require separate verification.

The general path copies a bounded UTF-8 path, converts it to UTF-16 and invokes
a module-load operation. No rejection of absolute paths or alternate DLL naming
rule was established. Captured directory construction uses `plugins`, with a
separate path containing `engine` and `win64`; missing helper bodies prevent
treating that as proof of another installation location.

## What remains missing

An offline review of the current stock bootstrap archive
`9ba626afa44a3aa3` parsed all six Lua resources without executing them. Their
constant tables and global references cover startup callbacks, animation helpers
and Wwise audio/editor helpers; none supplies a gameplay input gate. This covers
that bootstrap archive only, not every archive or native interface in the game.

A subsequent metadata census examined all 3,522 base archive names in the
current DSAA index. It validated 3,427 archive type tables; a focused header
check confirmed that the remaining 95 archives declare zero types and zero
resources. Five archives declare 11 Lua entries, comprising nine unique resource
envelopes. This scope excludes patches, dynamically supplied code and native
interfaces.

The five Lua entries outside the bootstrap archive were structurally decoded
without executing them. Two exactly duplicate known animation helpers; the other
three implement editor-test/assertion UI, vector-field editing and reflection
probe editing. Their constants and global/instruction references did not supply
a stock Escape/menu input-context handler or an acquire/release contract. The
editor-test UI reads Keyboard/Mouse and uses the existing cursor/focus APIs; it
does not establish a gameplay keyboard gate.

The census requested 22.2 MB of compressed-file reads and decoded 41.1 MB of
blocks in 3.97 seconds. Selected Lua payloads totaled 20,058 bytes; their inspection
and the focused empty-header check each completed in under 0.32 seconds.
These are offline diagnostic costs, not LLL callback or gameplay frame timings.

The retained Lua API inventories also expose no verified player input service.
Generic script dispatch, Flow events and component setters do exist, but no
current gameplay instance, event/property contract or restoration behavior
connects them to keyboard suppression. They are not candidates for guessed live
calls. Additional game-specific interface evidence is required for this route.

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

## Additional supported startup route

The capture also contains the exact `--plugin-dir` option at executable RVA
0x1702c10. Autodesk's [command-line reference](https://help.autodesk.com/cloudhelp/ENU/Stingray-Help/stingray_help/reference/engine_command_line.html)
and [SDK loading guide](https://help.autodesk.com/cloudhelp/ENU/Stingray-SDK-Help/sdk_help/extend_engine.html)
document this as an additional directory checked for plugin DLLs at startup.
This gives a concrete normal startup test without changing the shipped
`support_plugin_reload` setting. A retained option string alone does not prove
that this game fork accepts or processes it.

The private candidate uses the unchanged reviewed name-only DLL in an isolated
directory and a one-shot observer. It checks whether the exact directory argument
reached the game and whether the expected plugin name is listed, without dumping
other command-line arguments. A guarded one-launch Steam invocation leaves
persistent launch settings unchanged. The previous diagnostic copy must be
removed before this test to avoid duplicate loads. The candidate does not query
native engine APIs or alter input.

The one-launch test reached a fresh game process. The first observer was rejected
before activation because it omitted the host's required cleanup callback. A
stateless cleanup callback was added, checked against the actual host assertion,
and hot-reloaded in the same process. The corrected observation confirmed valid
arguments containing the exact `--plugin-dir` directory and a valid plugin list,
with the expected name still absent. This proves argument forwarding; it does
not establish parser behavior, startup discovery or plugin acceptance. The Lua
observer and diagnostic native DLLs were subsequently hash-checked, archived
and removed. The option was not saved to Steam settings. A subsequent normal
launch was verified with the production startup patch, helper and user settings
unchanged, and neither diagnostic project present in its fresh loader log.

A bounded check of Windows Code Integrity and relevant Application events for
this launch found no matching loader rejection. The diagnostic DLL depends only
on `KERNEL32.dll`, providing no evidence of a missing external CRT dependency.
Neither negative check identifies the failing stage.

## Native logging diagnostic failure

A separate one-shot Lua diagnostic called the documented zero-argument
[`Application.restart_file_log()`](https://help.autodesk.com/cloudhelp/ENU/Stingray-Help/lua_ref/ns_stingray_Application.html)
to reopen the existing configured log destination. It changed no settings,
loaded no plugin and installed no input callback. The game closed by itself
while that diagnostic was loading, before its result file was written.

The resulting minidump records exception `0xc0000005` at executable RVA
`0x667e33`: a read from address `0x100` with a null base register. This establishes
a native null dereference; timing alone does not identify the full call chain.
The logging diagnostic was removed and the API will not be used again on this
build. Its dump remains private. No native loader error was recovered through
this test, and it provides no evidence of keyboard suppression.

The dump's 165-entry module list contains the stock engine plugins and game
DLL, with no diagnostic LLL native DLL present at the time of the crash. This
does not establish whether an earlier load was attempted or why it failed.

## Attempt to obtain a fuller capture

A separate read-only image reader passed eight own-process fixtures, including
identity mismatch rejection, unreadable-page accounting and bounded partial-read
handling. It was then launched through normal Windows UAC elevation. The reader
opened the current game with a requested `PROCESS_QUERY_INFORMATION |
PROCESS_VM_READ` mask and verified its creation time, executable path and file
fingerprint. `K32EnumProcessModulesEx` then failed with Windows error 5
(access denied), before any image code was read. The same enumeration binding
succeeded in an own-process control. The reader exited and the game remained
running. No fuller capture was obtained through this attempt, and no debug
privilege, protection or target-memory changes were made.

## Lua native-module route

The [community boot investigation and corrections](https://github.com/CowboyBingus/BingusSharedLoader/issues/13)
also report disk Lua loading, resource-before-file priority, and inherited search
paths. Their corrected existence check is `can_get(type, name)`; one argument
reportedly crashes. LLL already uses two arguments and controlled project paths.
These reports do not establish native-module acceptance.

The current VM exposes the standard Lua 5.1
[`package.loadlib`](https://www.lua.org/manual/5.1/manual.html#pdf-package.loadlib)
function. A guarded one-shot query used an independently verified nonexistent
absolute DLL filename. It returned nil, a normal missing-module error and the
`open` stage, establishing that this is not the disabled dynamic-loader stub.
No DLL or returned function was executed by the query. Its temporary project was
hash-checked and removed, with user settings and the startup patch unchanged.

A subsequent elevated, hash-guarded live test attempted to load a small Lua C
module through that same normal route. Its entry point ignores the Lua state,
returns no Lua values, and dispatches a single background image-reading job.
The production artifact passed an own-process Lua 5.1 refusal test and 21 native
fixtures before deployment. A separate verifier passed nine synthetic tests.

The game returned `system error 577` at `package.loadlib`, before the returned
function could be invoked. Windows defines this as
[`ERROR_INVALID_IMAGE_HASH`](https://learn.microsoft.com/en-us/windows/win32/debug/system-error-codes--500-999-),
an image-signature verification failure. The available evidence does not identify
the component enforcing that rejection. No capture job was created. The temporary
Lua project was hash-checked and removed, settings and startup patch hashes stayed
unchanged, and the same game process remained running. Elevation therefore did
not establish native-module acceptance or recover an input API.

## Windows dump API result

A separate elevated helper then made one ordinary
[`MiniDumpWriteDump`](https://learn.microsoft.com/en-us/windows/win32/api/minidumpapiset/nf-minidumpapiset-minidumpwritedump)
call using the verified System32 DbgHelp library. It requested loaded code/data
sections and diagnostic metadata rather than a full heap dump. A control against
an owned Python child produced a valid 15 MB dump with 15 modules and 189 bounded
memory ranges. Size-cap and deadline controls were checked before game use.

Against the verified current game process, the API returned HRESULT `0x80070005`
(access denied) in approximately 40 ms, before any dump writes. The output was
zero bytes and provides no code coverage. The elevated caller had
`SeDebugPrivilege` disabled and did not change privileges, access policy or game
code. The helper exited and the same game process remained running.

A read-only query of `ProcessSignaturePolicy` on that same process succeeded
with raw flags zero: Microsoft-only, Store-only and mitigation-opt-in signing
restrictions were all unset. Those particular flags therefore do not explain the
earlier 577 result; its enforcing component is still unknown. No fuller capture
was obtained through these elevated attempts.

Further bridge work requires evidence for the actual Lua-to-native load route
or a successfully accepted plugin and compatible engine API. Native input or
player writes have not been added. Any eventual input gate must still be tested
for native action isolation, UI input, ownership, close/blur restoration,
lifecycle transitions and deployed callback cost.
