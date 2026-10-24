# CFFI for Helldivers 2 Lua 5.1

**NOT FOR THE LIVE GAME UNLESS YOU ARE ON LINUX. IT WILL NOT WORK ON WINDOWS.**

The prebuilt game module targets Steam build 26088801 under Proton. Native Windows
rejects loading with system error 577. `require("cffi")` is not a LuaJIT FFI alias.
The bootstrap uses normal Lua module loading, the existing host Lua state, exact
executable SHA256 and 53 Lua API witnesses. It does not replace the VM.

This source snapshot contains cffi-lua, Lua 5.1.4 and libffi with their original
licenses. The cffi-lua change corrects pointer-minus-integer stride/direction,
signed pointer differences and array subtraction. `tests/smoke.lua` exercises
these cases plus calls, callbacks, arrays and contained parser/load errors.
`src/nativeinfo.cc` supplies bounded native reads for the current stock HUD font.

Build from this directory (Zig 0.14.1, Python 3, Meson and Ninja for cross builds):

```sh
python3 build.py --platform windows --work-dir /tmp/lll-cffi-build --zig /path/to/zig
```

The Windows-format outputs run inside Proton; this build target does not promise
native Windows game compatibility. Linux standalone harness builds use GCC/G++,
system libffi headers/library and `--platform linux`. They are isolated tests,
not game plugins. Do not install the harness's separate Lua library into the game.
Use the release's portable installer for the game DLLs. Source paths/link metadata
can make rebuild hashes differ from the existing tested binaries.
