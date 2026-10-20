"""Build an isolated LLL folder addon; --install activates this owned candidate."""
from __future__ import annotations
import argparse
import ctypes
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import uuid
import zipfile

ROOT = Path(__file__).resolve().parents[3]
SDK = ROOT / "sdk/hd2se"
GAME = Path(r"C:/Program Files (x86)/Steam/steamapps/common/Helldivers 2")
ID = "hd2se_live_validation"
FILES = ("src/kernel.lua", "src/world_provider.lua", "src/stingray_bridge.lua", "live/platform.lua",
         "live/profile.lua", "live/validation.lua", "live/scene_observer.lua")

def sha(data):
    return hashlib.sha256(data).hexdigest()

def syntax(paths):
    dll = ctypes.CDLL(str(GAME / "bin/lua51.dll"))
    dll.luaL_newstate.restype = ctypes.c_void_p
    dll.luaL_loadfile.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
    dll.lua_settop.argtypes = [ctypes.c_void_p, ctypes.c_int]
    dll.lua_close.argtypes = [ctypes.c_void_p]
    state = dll.luaL_newstate()
    if not state:
        raise RuntimeError("Lua state allocation failed")
    try:
        for path in paths:
            status = dll.luaL_loadfile(state, str(path).encode("utf-8"))
            if status:
                raise RuntimeError(f"Lua syntax failed ({status}): {path}")
            dll.lua_settop(state, 0)
    finally:
        dll.lua_close(state)

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--install", action="store_true")
    args = parser.parse_args()
    output = args.output.resolve()
    if not output.is_relative_to((ROOT / "dist/releases").resolve()):
        parser.error("Output must remain inside the owning component's dist/releases")
    paths = {name: SDK / name for name in FILES}
    paths["main.lua"] = SDK / "live/main.lua"
    inputs = {name: path.read_bytes() for name, path in paths.items()}
    profile = inputs["live/profile.lua"].decode("utf-8")
    binaries = {"exe": "bin/helldivers2.exe", "game": "data/game/game.dll", "lua": "bin/lua51.dll"}
    identity = {}
    for key, relative in binaries.items():
        actual = sha((GAME / relative).read_bytes())
        expected = re.search(key + r"_sha256 = '([0-9a-f]{64})'", profile).group(1)
        if actual != expected:
            raise RuntimeError(f"Unsupported installed {key} identity: {actual}")
        identity[key + "_sha256"] = actual
    check = subprocess.run([sys.executable, str(SDK / "tests/run.py")], cwd=ROOT,
                           capture_output=True, text=True)
    if check.returncode:
        sys.stdout.write(check.stdout); sys.stderr.write(check.stderr)
        return check.returncode
    syntax(paths.values())
    if any(path.read_bytes() != inputs[name] for name, path in paths.items()):
        raise RuntimeError("Live inputs changed during validation")
    manifest = {"id": ID, "name": "HD2SE Entity/World live validation", "author": "Goose", "version": "0.1.1-dev",
                "description": "Real Lua binding adapter with owned lifecycle validation and scene observer",
                "lll": {"entry": "main.lua", "defaults": "config/defaults.cfg", "modules": list(FILES)}}
    inputs["manifest.json"] = (json.dumps(manifest, indent=2) + "\n").encode()
    inputs["config/defaults.cfg"] = b'{"validation_candidate":true}\n'
    project = output / ID
    for name, data in inputs.items():
        path = project / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
    receipt = {"id": ID, "built_at": datetime.now(timezone.utc).isoformat(), "game_identity": identity,
               "source_sha256": {name: sha(data) for name, data in sorted(inputs.items())},
               "validation": "isolated contracts and Lua syntax only; live evidence is separate",
               "loader_replaced": False}
    output.mkdir(parents=True, exist_ok=True)
    (output / "offline-validation.txt").write_text(check.stdout + check.stderr, encoding="utf-8")
    archive = output / "HD2SE-0.1.1-LLL-live-validation.zip"
    with zipfile.ZipFile(archive, "w", zipfile.ZIP_DEFLATED) as z:
        for name, data in sorted(inputs.items()):
            z.writestr("Mods/" + ID + "/" + name, data)
    with zipfile.ZipFile(archive) as z:
        assert z.testzip() is None
        for name, data in inputs.items():
            assert z.read("Mods/" + ID + "/" + name) == data
    receipt["zip_sha256"] = sha(archive.read_bytes())
    if args.install:
        mods = (Path(os.environ["LOCALAPPDATA"]) / "LLL/Helldivers2/Mods").resolve()
        target = mods / ID
        staging = mods / (ID + ".staged-" + uuid.uuid4().hex)
        # Both recursive copy/move endpoints are explicitly constrained here.
        if target.resolve().parent != mods or staging.resolve().parent != mods:
            raise RuntimeError("Install endpoint escaped the owned Mods directory")
        if target.exists() or staging.exists():
            raise RuntimeError("Existing deployment refused; use an explicit owned update with backup")
        cfg = mods.parent / "LLL.cfg"
        evidence = output / "evidence"
        evidence.mkdir(exist_ok=True)
        if cfg.is_file():
            backup = evidence / "LLL.cfg.before-hd2se-install"
            if not backup.exists():
                backup.write_bytes(cfg.read_bytes())
        shutil.copytree(project, staging)
        for name, data in inputs.items():
            assert (staging / name).read_bytes() == data
        staging.rename(target)
        for name, data in inputs.items():
            assert (target / name).read_bytes() == data
        receipt["installed_at"] = datetime.now(timezone.utc).isoformat()
        receipt["installed_path"] = str(target)
        receipt["installed_exact_bytes"] = True
        print("Installed new owned LLL project:", target)
    (output / "LIVE-CANDIDATE.json").write_text(json.dumps(receipt, indent=2) + "\n", encoding="utf-8")
    print("PASS exact game file identities, isolated contracts, all project Lua syntax, ZIP bytes and CRC")
    print(archive)
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
