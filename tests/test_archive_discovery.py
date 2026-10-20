"""Regression checks for mixed-resource archive discovery, outside the game."""
import ctypes
import os
from pathlib import Path
import struct
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
from archive import LUA_TYPE, hash_name, read, write


class ArchiveDiscovery(unittest.TestCase):
    def test_mixed_resources_and_invalid_tables(self):
        name = "mods/test/mixed"
        body = b"-- HD2-Addon: mods/test/mixed\nreturn true"
        envelope = struct.pack("<II", len(body), 2) + body
        single = write({hash_name(name): envelope})
        # Three type descriptors move the table by 64 bytes, including payload offsets.
        mixed = bytearray(single[:104] + bytes(64) + single[104:])
        struct.pack_into("<I", mixed, 4, 3)
        struct.pack_into("<Q", mixed, 32, len(mixed))
        struct.pack_into("<Q", mixed, 168 + 16, struct.unpack_from("<Q", single, 120)[0] + 64)
        for offset, kind in ((104, 0xCD4238C6A0C69E32), (136, 0x1234)):
            struct.pack_into("<IIQIIII", mixed, offset, 0, 0, kind, 0, 0, 16, 16)
        bad_types = bytearray(mixed)
        struct.pack_into("<I", bad_types, 4, 0xFFFFFFFF)
        bad_range = bytearray(mixed)
        struct.pack_into("<Q", bad_range, 184, 104)
        truncated = mixed[:200]
        for data in (single, mixed):
            self.assertEqual(read(data)[hash_name(name)], (LUA_TYPE, envelope))
        for data in (bad_types, bad_range, truncated):
            with self.assertRaises(ValueError):
                read(data)
        dll = ctypes.CDLL(os.environ.get("LLL_TEST_LUA_DLL", r"C:\Program Files (x86)\Steam\steamapps\common\Helldivers 2\bin\lua51.dll"))
        dll.luaL_newstate.restype = ctypes.c_void_p
        dll.luaL_openlibs.argtypes = [ctypes.c_void_p]
        dll.luaL_loadstring.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
        dll.lua_pcall.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_int, ctypes.c_int]
        dll.lua_tolstring.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_void_p]
        dll.lua_tolstring.restype = ctypes.c_char_p
        dll.lua_close.argtypes = [ctypes.c_void_p]
        script = r'''local discover=dofile("src/discovery.lua")
local function read(path) local f=assert(io.open(path,"rb"));local b=f:read("*a");f:close();return b end
for _,stream in ipairs({false,true}) do
 for i=1,5 do
  local closed=false
  local p={data=".", files=function()return {"9ba626afa44a3aa3.patch_"..i}end,read=read}
  if stream then p.archive=function(path)
   local b=read(path);return {size=#b,read=function(at,n)return b:sub(at+1,at+n)end,close=function()closed=true end}
  end end
  local names,warnings=discover(p)
  if i<=2 then assert(#names==1 and names[1]=="mods/test/mixed" and #warnings==0)
  else assert(#names==0 and #warnings==1) end
  if stream then assert(closed)end
 end
end'''
        script = 'LLL_DISCOVERY_HASH=dofile("' + (ROOT / "src/discovery_hash.lua").as_posix() + '")\n' + script
        old = Path.cwd()
        with tempfile.TemporaryDirectory() as folder:
            folder = Path(folder)
            for i, data in enumerate((single, mixed, bad_types, bad_range, truncated), 1):
                (folder / f"9ba626afa44a3aa3.patch_{i}").write_bytes(data)
            script = script.replace('dofile("src/discovery.lua")', 'dofile("' + (ROOT / "src/discovery.lua").as_posix() + '")')
            os.chdir(folder)
            state = dll.luaL_newstate()
            try:
                dll.luaL_openlibs(state)
                status = dll.luaL_loadstring(state, script.encode()) or dll.lua_pcall(state, 0, 0, 0)
                self.assertEqual(status, 0, dll.lua_tolstring(state, -1, None))
            finally:
                dll.lua_close(state)
                os.chdir(old)


if __name__ == "__main__":
    unittest.main()
