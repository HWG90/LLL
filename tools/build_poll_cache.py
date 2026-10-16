"""Build the standalone LLL maintenance addon; never install or attach to a game."""

import argparse
import hashlib
import json
import re
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PROJECT = Path("examples/poll_cache_fix")
README = (
    "Copy lll_poll_cache into %LOCALAPPDATA%/LLL/Helldivers2/Mods. "
    "Existing LLL auto-discovers it and loads it on normal startup. "
    "No game resources, native DLLs, or directory prerequisites. "
    "Loader settings and automatic reload remain unchanged. "
    "Disable this maintenance entry to restore its owned methods.\n"
).encode()


def digest(body):
    return hashlib.sha256(body).hexdigest()


def text_bytes(path, newline=b"\n"):
    # The accepted 0.1.3 package has a CRLF backend and LF entry/defaults.
    # Fix the payload format so clean Git exports and Windows checkouts agree.
    return path.read_bytes().replace(b"\r\n", b"\n").replace(b"\n", newline)


def runtime_files(root=ROOT):
    """The complete, explicit runtime allowlist; no native or game resources."""
    manifest = json.loads((root / PROJECT / "manifest.json").read_text(encoding="utf-8"))
    assert manifest["id"] == "lll_poll_cache", "Unexpected maintenance project"
    assert re.fullmatch(r"\d+\.\d+\.\d+", manifest["version"]), "Invalid addon version"
    assert manifest["lll"] == {
        "entry": "main.lua",
        "defaults": "config/defaults.cfg",
        "modules": ["src/poll_cache.lua"],
        "restart_only": True,
    }, "Unexpected maintenance module contract"
    files = {
        "main.lua": text_bytes(root / PROJECT / "main.lua"),
        "src/poll_cache.lua": text_bytes(root / "src/poll_cache.lua", b"\r\n"),
        "config/defaults.cfg": text_bytes(root / PROJECT / "config/defaults.cfg"),
    }
    assert isinstance(json.loads(files["config/defaults.cfg"]), dict), "Defaults must be a JSON object"
    manifest["checksums"] = {name: digest(body) for name, body in sorted(files.items())}
    files["manifest.json"] = (json.dumps(manifest, indent=2) + "\n").encode()
    files["SHA256SUMS.txt"] = "".join(
        digest(body) + "  " + name + "\n" for name, body in sorted(files.items())
    ).encode()
    return manifest["version"], files


def build(output, root=ROOT):
    version, files = runtime_files(root)
    output = Path(output)
    output.mkdir(parents=True, exist_ok=True)
    target = output / ("LLL-Poll-Cache-" + version + ".zip")
    package = {"lll_poll_cache/" + name: body for name, body in files.items()}
    package["README.txt"] = README
    # Explicit names and fixed metadata make the whole ZIP reproducible.
    with zipfile.ZipFile(target, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        for name, body in sorted(package.items()):
            info = zipfile.ZipInfo(name, (2026, 10, 15, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.create_system = 3
            info.external_attr = 0o100644 << 16
            archive.writestr(info, body, compresslevel=9)
    with zipfile.ZipFile(target) as archive:
        assert archive.testzip() is None, "Package CRC verification failed"
        assert {name: archive.read(name) for name in archive.namelist()} == package
    return target


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path, help="Explicit build output directory")
    args = parser.parse_args()
    print(build(args.output))


if __name__ == "__main__":
    main()
