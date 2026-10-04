"""Compile LuaJIT bytecode in an isolated process."""

import ctypes, hashlib, json, struct, sys, zipfile
from pathlib import Path
from archive import read, write, hash_name

ROOT = Path(__file__).resolve().parents[1]
DLL = Path(r"C:\Program Files (x86)\Steam\steamapps\common\Helldivers 2\bin\lua51.dll")


def compile_chunk(source):
    d = ctypes.CDLL(str(DLL))
    d.luaL_newstate.restype = ctypes.c_void_p
    s = d.luaL_newstate()
    d.luaL_openlibs.argtypes = [ctypes.c_void_p]
    d.luaL_openlibs(s)
    d.luaL_loadbuffer.argtypes = [
        ctypes.c_void_p,
        ctypes.c_char_p,
        ctypes.c_size_t,
        ctypes.c_char_p,
    ]
    d.lua_setfield.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_char_p]
    d.lua_pcall.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_int, ctypes.c_int]
    d.lua_tolstring.argtypes = [
        ctypes.c_void_p,
        ctypes.c_int,
        ctypes.POINTER(ctypes.c_size_t),
    ]
    d.lua_tolstring.restype = ctypes.c_void_p
    d.lua_close.argtypes = [ctypes.c_void_p]

    def check(status):
        if status:
            n = ctypes.c_size_t()
            v = d.lua_tolstring(s, -1, ctypes.byref(n))
            raise RuntimeError(ctypes.string_at(v, n.value).decode(errors="replace"))

    try:
        check(d.luaL_loadbuffer(s, source, len(source), b"@lll"))
        d.lua_setfield(s, -10002, b"loader_chunk")
        code = b"return string.dump(loader_chunk,true)"
        check(d.luaL_loadbuffer(s, code, len(code), b"@dump"))
        check(d.lua_pcall(s, 0, 1, 0))
        n = ctypes.c_size_t()
        v = d.lua_tolstring(s, -1, ctypes.byref(n))
        return ctypes.string_at(v, n.value)
    finally:
        d.lua_close(s)
