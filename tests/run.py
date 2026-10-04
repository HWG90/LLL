"""Isolated LuaJIT checks using the installed DLL in this Python process only."""

import ctypes, os, struct, sys, zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
from archive import hash_name, write, read
from build import source

os.chdir(ROOT)
tmp = ROOT / "tests/tmp"
tmp.mkdir(exist_ok=True)


def resource(name, source):
    return {hash_name(name): struct.pack("<II", len(source), 2) + source}


old = resource("mods/test/shadow", b"-- HD2-Addon: mods/test/shadow\nreturn true")
old.update(
    resource("mods/test/accepted", b"-- HD2-Addon: mods/test/accepted\r\nreturn true")
)
(tmp / "9ba626afa44a3aa3.patch_2").write_bytes(write(old))
(tmp / "9ba626afa44a3aa3.patch_10").write_bytes(
    write(resource("mods/test/shadow", b"return true"))
)
(tmp / "9ba626afa44a3aa3.patch_11").write_bytes(
    write(resource("mods/test/wrong", b"-- HD2-Addon: mods/test/imposter\nreturn true"))
)
(tmp / "9ba626afa44a3aa3.patch_12").write_bytes(b"bad")
stock = b'assert(select("#",...)==3);local a,b,c=...;assert(a==17 and b==nil and c==29);_G.stock_calls=(_G.stock_calls or 0)+1;return "stock",nil,42,nil'
platform = 'return {data="tests/tmp",loader_config="mockconfig",write=function(path,value) _G.mock_config=value;return true end,live="mock_live",files=function(dir) if dir=="mock_live" then if _G.new_live_source then return {"demo.lua","new.lua"} end;return {"demo.lua"} end;return {} end,read=function(path) if path=="mockconfig" then return _G.mock_config elseif path=="mock_live/demo.lua" then return _G.live_source elseif path=="mock_live/new.lua" then return _G.new_live_source end end,guard=function() end,open_log=function() end}'
(tmp / "bootstrap.lua").write_bytes(
    source(struct.pack("<II", len(stock), 2) + stock, platform)
)
generated = (tmp / "bootstrap.lua").read_bytes()
assert (
    generated.index(b"local LLL_NATIVE\n")
    < generated.index(b"local LLL_UI=")
    < generated.index(b"LLL_NATIVE={name=")
)
from build_lean import compile_chunk

# Exercise the same bytecode execution path used by the distributable.
(tmp / "bootstrap.lua").write_bytes(compile_chunk(generated))

native = (
    (ROOT / "src/platform.lua")
    .read_text(encoding="utf-8")
    .replace("P.exe = ffi.string(path, n)", "P.exe=[[C:/test/bin/helldivers2.exe]]")
    .replace('P.data = P.root .. "/data"', 'P.data="tests/tmp"')
)
conflict = "require('ffi').cdef[[typedef struct {char bytes[320];} OTHER_MOD_FIND_DATA;void *FindFirstFileA(const char *,OTHER_MOD_FIND_DATA *);int FindNextFileA(void *,OTHER_MOD_FIND_DATA *);]]\n"
native_test = (
    conflict
    + "local P=(function()\n"
    + native
    + '\nend)();local discover=dofile("src/discovery.lua");local names,warnings=discover(P);assert(#names==1 and names[1]=="mods/test/accepted");assert(#warnings==1);print("PASS real Windows discovery with another mod FFI declarations")'
)
(tmp / "native-platform.lua").write_text(native_test, encoding="utf-8")
(tmp / "speed-native.lua").write_text(native, encoding="utf-8")
(tmp / "watch-fixture").mkdir(exist_ok=True)
os.environ["LOCALAPPDATA"] = str(tmp)
dll = ctypes.CDLL(
    r"C:\Program Files (x86)\Steam\steamapps\common\Helldivers 2\bin\lua51.dll"
)
dll.luaL_newstate.restype = ctypes.c_void_p
s = dll.luaL_newstate()
dll.luaL_openlibs.argtypes = [ctypes.c_void_p]
dll.luaL_openlibs(s)
dll.luaL_loadfile.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
dll.lua_pcall.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_int, ctypes.c_int]
dll.lua_tolstring.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_void_p]
dll.lua_tolstring.restype = ctypes.c_char_p
status = dll.luaL_loadfile(s, b"tests/contracts.lua") or dll.lua_pcall(s, 0, 0, 0)
if not status:
    status = dll.luaL_loadfile(s, b"tests/tmp/native-platform.lua") or dll.lua_pcall(
        s, 0, 0, 0
    )
if not status:
    status = dll.luaL_loadfile(s, b"tests/config_contracts.lua") or dll.lua_pcall(
        s, 0, 0, 0
    )
if not status:
    status = dll.luaL_loadfile(s, b"tests/live_contracts.lua") or dll.lua_pcall(
        s, 0, 0, 0
    )
if not status:
    status = dll.luaL_loadfile(s, b"tests/management_contracts.lua") or dll.lua_pcall(
        s, 0, 0, 0
    )
for contract in (b"tests/speed_contracts.lua", b"tests/deferred_cleanup_contracts.lua"):
    if not status:
        status = dll.luaL_loadfile(s, contract) or dll.lua_pcall(s, 0, 0, 0)
if status:
    print(dll.lua_tolstring(s, -1, None).decode(errors="replace"))
dll.lua_close.argtypes = [ctypes.c_void_p]
dll.lua_close(s)
if status:
    raise SystemExit(status)
with zipfile.ZipFile(ROOT / "dist/LiveLuaLoader-private-candidate.zip") as z:
    assert z.testzip() is None
    for sidecar in (".stream", ".gpu_resources"):
        assert z.read("data/9ba626afa44a3aa3.patch_0" + sidecar) == b""
    contents = read(z.read("data/9ba626afa44a3aa3.patch_0"))
    assert len(contents) == 1
    body = contents[hash_name("core/wwise/lua/wwise_flow_callbacks")][1]
    assert body[8:] == (ROOT / "dist/runtime.luac").read_bytes()
print(
    "PASS package CRC, exact runtime payload, archive roundtrip, empty sidecars; no game attachment or live proof"
)
