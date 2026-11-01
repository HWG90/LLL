"""Chef Shared Loader and Boot Mod Loader compatibility contracts, in stock Lua 5.1 and LuaJIT.

Builds real patch archives with tools/archive.py (a Chef addon whose name has a '-', a
boot-style script, an Arsenal options file, requirements, a Bingus-style mod), writes the
hashes the archive scan needs, then runs tests/compat_contracts.lua under each VM found.
"""
from pathlib import Path
import shutil
import struct
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
from archive import hash_name, write

TMP = ROOT / "tests/tmp/compat"


def resource(name, source, envelope=2):
    return {hash_name(name): struct.pack("<II", len(source), envelope) + source}


def main():
    if TMP.exists():
        shutil.rmtree(TMP)
    (TMP / "data").mkdir(parents=True)
    (TMP / "settings").mkdir()
    (TMP / "lll").mkdir()
    names = {}
    patch0 = {}
    patch0.update(resource("mods/test/needs-lib", b"""-- HD2-Addon: mods/test/needs-lib
-- HD2-Requires: chef-shared-loader >= 1.0.0
-- HD2-Requires: mods/test/lib
local chef = ...
local lib = chef.require('mods/test/lib', '1.1')
helper_global = 'private'
return { update = function(dt) chef.save('ticks', (chef.load('ticks', 0)) + 1) end, shutdown = function() chef.save('stopped', true) end, lib = lib }
"""))
    patch0.update(resource("mods/test/lib", b"""-- HD2-Addon: mods/test/lib
local chef = ...
return { version = '1.2.0', value = chef.options.size or 'none' }
"""))
    patch0.update(resource("mods/test/bingus", b"""-- HD2-Addon: mods/test/bingus
return true
"""))
    (TMP / "data/9ba626afa44a3aa3.patch_0").write_bytes(write(patch0))
    patch1 = {}
    patch1.update(resource("mods/test/boot", b"""-- HD2-Boot: mods/test/boot
calls = 0
function init() calls = calls + 1; chef.share('test.boot.init', true) end
function update(dt) calls = calls + 1 end
function shutdown() chef.share('test.boot.shutdown', calls) end
"""))
    patch1.update(resource("mods/test/lib/options/large", b"""-- HD2-Options: mods/test/lib
return { size = 'large', nested = { a = 1 } }
"""))
    patch1.update(resource("mods/test/missing", b"""-- HD2-Addon: mods/test/missing
-- HD2-Requires: mods/test/nowhere >= 2
return true
"""))
    patch1.update(resource("mods/test/too-new", b"""-- HD2-Addon: mods/test/too-new
-- HD2-Requires: chef-shared-loader >= 9.0.0
local chef = ...
return true
"""))
    (TMP / "data/9ba626afa44a3aa3.patch_1").write_bytes(write(patch1))
    for name in ["mods/test/needs-lib", "mods/test/lib", "mods/test/bingus", "mods/test/boot", "mods/test/lib/options/large",
                 "mods/test/missing", "mods/test/too-new"]:
        names[name] = "%016x" % hash_name(name)
    fixture = "return {root=%r,hashes={%s}}\n" % (
        TMP.as_posix(), ",".join("[%r]=%r" % (k, v) for k, v in names.items()))
    (TMP / "fixture.lua").write_text(fixture.replace("'", '"'))
    ran = []
    for vm in ("lua5.1", "luajit"):
        exe = shutil.which(vm)
        if not exe:
            continue
        for path in (TMP / "settings").iterdir():
            path.unlink()
        for path in (TMP / "lll").iterdir():
            path.unlink()
        for contracts in ("tests/compat_contracts.lua", "tests/compat_manager_contracts.lua"):
            result = subprocess.run([exe, contracts], cwd=ROOT, capture_output=True, text=True)
            sys.stdout.write(result.stdout)
            if result.returncode != 0:
                sys.stderr.write(result.stderr)
                raise SystemExit(vm + " failed: " + contracts)
        ran.append(vm)
    if not ran:
        raise SystemExit("No Lua 5.1 or LuaJIT interpreter found")
    print("PASS compatibility contracts on " + ", ".join(ran))


if __name__ == "__main__":
    main()
