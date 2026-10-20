"""Run the HD2SE kernel contracts in an isolated Lua state, without game attachment."""

from __future__ import annotations

import argparse
import ctypes
import hashlib
import os
from pathlib import Path
import sys


ROOT = Path(__file__).resolve().parents[3]
CONTRACTS = tuple(ROOT / "sdk/hd2se/tests" / name for name in ("contracts.lua", "world_contracts.lua", "stingray_bridge_contracts.lua", "validation_contracts.lua"))
KERNEL = ROOT / "sdk/hd2se/src/kernel.lua"
WORLD_PROVIDER = ROOT / "sdk/hd2se/src/world_provider.lua"
DEFAULT_DLL = Path(
    r"C:\Program Files (x86)\Steam\steamapps\common\Helldivers 2\bin\lua51.dll"
)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--lua-dll", type=Path, default=DEFAULT_DLL)
    args = parser.parse_args()
    dll_path = args.lua_dll.resolve()
    for path in (dll_path, KERNEL, WORLD_PROVIDER, *CONTRACTS):
        if not path.is_file():
            parser.error(f"Missing required file: {path}")

    print("Offline only: fresh Python-owned Lua state; no game attachment or deployment.", flush=True)
    print(f"Lua DLL: {dll_path}", flush=True)
    for path in (KERNEL, WORLD_PROVIDER, *CONTRACTS):
        label = path.name
        print(f"{label} SHA-256: {hashlib.sha256(path.read_bytes()).hexdigest()}", flush=True)

    try:
        dll = ctypes.CDLL(str(dll_path))
    except OSError as exc:
        print(f"Cannot load the isolated Lua DLL: {exc}", file=sys.stderr)
        return 2

    dll.luaL_newstate.argtypes = []
    dll.luaL_newstate.restype = ctypes.c_void_p
    dll.luaL_openlibs.argtypes = [ctypes.c_void_p]
    dll.luaL_openlibs.restype = None
    dll.luaL_loadfile.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
    dll.luaL_loadfile.restype = ctypes.c_int
    dll.lua_pcall.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_int, ctypes.c_int]
    dll.lua_pcall.restype = ctypes.c_int
    dll.lua_tolstring.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.POINTER(ctypes.c_size_t)]
    dll.lua_tolstring.restype = ctypes.c_void_p
    dll.lua_close.argtypes = [ctypes.c_void_p]
    dll.lua_close.restype = None

    state = dll.luaL_newstate()
    if not state:
        print("Lua state allocation failed.", file=sys.stderr)
        return 2
    previous_cwd = Path.cwd()
    try:
        os.chdir(ROOT)
        dll.luaL_openlibs(state)
        for contract in CONTRACTS:
            status = dll.luaL_loadfile(state, contract.relative_to(ROOT).as_posix().encode("utf-8"))
            if not status:
                status = dll.lua_pcall(state, 0, 0, 0)
            if status:
                length = ctypes.c_size_t()
                pointer = dll.lua_tolstring(state, -1, ctypes.byref(length))
                message = ctypes.string_at(pointer, length.value).decode("utf-8", errors="replace") if pointer else "non-string Lua error"
                print(message, file=sys.stderr, flush=True)
                return 1
    finally:
        dll.lua_close(state)
        os.chdir(previous_cwd)
    print("PASS isolated kernel, provider and bridge contracts; live game evidence is separate.", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
