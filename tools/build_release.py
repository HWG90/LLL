"""Build the distributable and readable source archive without installing either."""

import argparse
import hashlib
import json
import struct
import zipfile
from pathlib import Path
from archive import hash_name, read, write
from build import source, STOCK_SHA
from build_lean import compile_chunk

ROOT = Path(__file__).resolve().parents[1]


def digest(data):
    return hashlib.sha256(data).hexdigest()


def source_files():
    files = {}
    for directory in ("src", "native", "binary", "docs", "examples"):
        for path in (ROOT / directory).rglob("*"):
            if path.is_file() and "lean-build" not in path.parts:
                files[path.relative_to(ROOT).as_posix()] = path.read_bytes()
    for name in (
        "archive.py",
        "build.py",
        "build_lean.py",
        "build_release.py",
        "build_native_lean.py",
        "create_mod.py",
        "ui_preview.py",
        "verify_modular.py",
    ):
        files["tools/" + name] = (ROOT / "tools" / name).read_bytes()
    for path in (ROOT / "tests").glob("*.lua"):
        files[path.relative_to(ROOT).as_posix()] = path.read_bytes()
    files["tests/run.py"] = (ROOT / "tests/run.py").read_bytes()
    for name in ("ARCHITECTURE.txt", "stylua.toml"):
        files[name] = (ROOT / name).read_bytes()
    files["generated/runtime.lua"] = (ROOT / "dist/runtime.lua").read_bytes()
    return files


def save_zip(path, files):
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as archive:
        for name, data in sorted(files.items()):
            info = zipfile.ZipInfo(name, (2026, 10, 4, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            archive.writestr(info, data)
    with zipfile.ZipFile(path) as archive:
        assert archive.testzip() is None


def build(output, label="release"):
    assert label and all(ch.isalnum() or ch in "-_" for ch in label), "Invalid candidate label"
    suffix = "" if label == "release" else "-" + label
    output.mkdir(parents=True, exist_ok=True)
    stock_bytes = (ROOT / "binary/stock_wwise.luac").read_bytes()
    stock = struct.pack("<II", len(stock_bytes), 2) + stock_bytes
    assert digest(stock) == STOCK_SHA
    runtime = source(stock)
    compiled = compile_chunk(runtime)
    native_name = (ROOT / "native/library.txt").read_text().strip()
    native = (ROOT / "native" / native_name).read_bytes()
    assert native in compiled and stock_bytes in compiled
    resource = struct.pack("<II", len(compiled), 2) + compiled
    payload = write({hash_name("core/wwise/lua/wwise_flow_callbacks"): resource})
    assert (
        read(payload)[hash_name("core/wwise/lua/wwise_flow_callbacks")][1] == resource
    )
    (ROOT / "dist").mkdir(exist_ok=True)
    (ROOT / "dist/runtime.lua").write_bytes(runtime)
    (ROOT / "dist/runtime.luac").write_bytes(compiled)
    manifest = {
        "Version": 1,
        "Guid": "bb921b89-f8d0-4abc-9e93-f426a93fef51",
        "Author": "Goose",
        "Name": "Live Lua Loader 0.1.8 - R31" + suffix,
        "Description": "R31: Helldivers manager UI, lifecycle and watcher improvements; bsl-v20 candidate adds SHA256 build gate, shared hash cache and event-driven JIT churn guard.",
        "Options": [{"Name": "Loader", "Include": ["data"]}],
    }
    files = {
        "manifest.json": (json.dumps(manifest, indent=2) + "\n").encode(),
        "data/9ba626afa44a3aa3.patch_0": payload,
        "data/9ba626afa44a3aa3.patch_0.stream": b"",
        "data/9ba626afa44a3aa3.patch_0.gpu_resources": b"",
    }
    for path in (ROOT / "docs").glob("*.txt"):
        files[path.name] = path.read_bytes()
    files["examples/heartbeat.lua"] = (ROOT / "examples/heartbeat.lua").read_bytes()
    files["examples/heartbeat.json"] = (ROOT / "examples/heartbeat.json").read_bytes()
    for path in (ROOT / "examples/modular_example").rglob("*"):
        if path.is_file():files[path.relative_to(ROOT).as_posix()]=path.read_bytes()
    files.update({"source/" + name: data for name, data in source_files().items()})
    files["FILES-SHA256.txt"] = "".join(
        digest(data) + "  " + name + "\n" for name, data in sorted(files.items())
    ).encode()
    target = output / f"LiveLuaLoader-0.1.8-R31{suffix}.zip"
    save_zip(target, files)
    save_zip(ROOT / "dist/LiveLuaLoader-private-candidate.zip", files)
    save_zip(
        output / f"LiveLuaLoader-0.1.8-R31{suffix}-source.zip", source_files()
    )
    (output / f"LiveLuaLoader-0.1.8-R31{suffix}-SHA256.txt").write_text(
        digest(target.read_bytes()) + "  " + target.name + "\n", encoding="utf-8"
    )
    (output / f"LiveLuaLoader-0.1.8-R31{suffix}-README.txt").write_bytes(
        files["README.txt"]
    )
    print(target)
    print(digest(target.read_bytes()))


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--label", default="release")
    args=parser.parse_args()
    build(args.output,args.label)
