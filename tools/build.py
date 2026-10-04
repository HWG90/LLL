"""Runtime assembly and game-build identifiers."""

import argparse, hashlib, json, struct, zipfile
from pathlib import Path
from archive import hash_name, write, read

ROOT = Path(__file__).resolve().parents[1]
STOCK_SHA = "05bbf52978028758b39f5b91a30a695d20069ceabd774d88755f0582a296bec9"
GAME = {
    "bin/helldivers2.exe": "f5fee03dcfdb2e553a4752c283590950ac13316b376d8196aa556ff0400d5f06",
    "data/game/game.dll": "2e2c3b7c2500646dadd5f2b4c6e0504dbb7e7896139f64cddc0d1813c718f51e",
}
CALLBACK = "core/wwise/lua/wwise_flow_callbacks"


def sha(data):
    return hashlib.sha256(data).hexdigest()


def source(stock, platform_source=None, native_bytes=None, native_name=None):
    # UI closures must capture this local before their definitions are compiled.
    code = [
        "local LLL_NATIVE",
        "local LLL_METADATA=(function()\n"
        + (ROOT / "src/metadata.lua").read_text(encoding="utf-8")
        + "\nend)()",
    ]
    for variable, file in [
        ("LLL_CONFIG", "config"),
        ("LLL_CLEANUP_QUEUE", "cleanup_queue"),
        ("LLL_MANAGER", "manager"),
        ("LLL_LEGACY", "legacy"),
        ("LLL_DISCOVER", "discovery"),
        ("LLL_LIVE", "live"),
        ("LLL_STATUS", "status"),
        ("LLL_PROVENANCE", "provenance"),
        ("LLL_CONTROLS", "controls"),
        ("LLL_UI_CORE", "ui/core"),
        ("LLL_UI_MENU", "ui/menu"),
        ("LLL_UI_VIEW", "ui/view"),
        ("LLL_UI_CAPTURE", "ui/capture"),
        ("LLL_UI", "ui"),
        ("LLL_PLATFORM", "platform"),
    ]:
        text = (
            platform_source
            if file == "platform" and platform_source is not None
            else (ROOT / "src" / f"{file}.lua").read_text(encoding="utf-8")
        )
        code.append("local " + variable + "=(function()\n" + text + "\nend)()")
    native_name = (
        native_name or (ROOT / "native/library.txt").read_text(encoding="utf-8").strip()
    )
    native_bytes = (
        native_bytes
        if native_bytes is not None
        else (ROOT / "native" / native_name).read_bytes()
    )
    native_literal = '"' + "".join("\\%03d" % b for b in native_bytes) + '"'
    code.append(
        "LLL_NATIVE={name=" + json.dumps(native_name) + ",bytes=" + native_literal + "}"
    )
    code.append((ROOT / "src/start.lua").read_text(encoding="utf-8"))
    literal = '"' + "".join("\\%03d" % b for b in stock[8:]) + '"'
    # Function argument expansion preserves stock nil holes and trailing nils.
    return (
        "local function start()\n" + "\n".join(code) + "\nend\n"
        'local function finish(...) local ok,why=pcall(start);if not ok then print("[LiveLuaLoader] "..tostring(why)) end;return ... end\n'
        "return finish(assert(loadstring(" + literal + ',"@stock_wwise"))(...))\n'
    ).encode()
