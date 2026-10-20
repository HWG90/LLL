"""Validate and package only the experimental HD2SE SDK source candidate."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import zipfile

ROOT = Path(__file__).resolve().parents[3]
SDK = ROOT / "sdk/hd2se"
FILES = (
    "README.md", "ARCHITECTURE.md", "src/kernel.lua", "src/world_provider.lua",
    "include/hd2se_plugin.h", "examples/entity_inspector.lua",
    "tests/contracts.lua", "tests/world_contracts.lua", "tests/run.py",
    "tools/package.py",
    "src/stingray_bridge.lua", "tests/stingray_bridge_contracts.lua",
    "live/main.lua", "live/platform.lua", "live/profile.lua", "live/validation.lua",
    "live/scene_observer.lua", "live/bindings_probe.lua", "tools/build_live.py",
    "examples/lll_entity_consumer.lua",
    "tests/validation_contracts.lua",
    "live/inventory_diagnostic.lua",
)


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--lua-dll", type=Path)
    args = parser.parse_args()
    output = args.output.resolve()
    if not output.is_relative_to((ROOT / "dist/releases").resolve()):
        parser.error("Output must be within the owning component's dist/releases directory.")
    missing = [name for name in FILES if not (SDK / name).is_file()]
    if missing:
        parser.error("Missing SDK inputs: " + ", ".join(missing))
    # Freeze exact input bytes before checking. Reject concurrent source edits
    # rather than packaging bytes different from those the checks exercised.
    inputs = {name: (SDK / name).read_bytes() for name in FILES}
    command = [sys.executable, str(SDK / "tests/run.py")]
    if args.lua_dll:
        command += ["--lua-dll", str(args.lua_dll.resolve())]
    result = subprocess.run(command, cwd=ROOT, capture_output=True, text=True)
    sys.stdout.write(result.stdout)
    sys.stderr.write(result.stderr)
    if result.returncode:
        return result.returncode
    if any((SDK / name).read_bytes() != data for name, data in inputs.items()):
        raise SystemExit("SDK inputs changed during validation; rerun with stable source.")
    metadata = {
        "name": "HD2SE", "version": "0.1.1-dev", "stage": "lua-binding-source-candidate",
        "installable_game_addon": False, "game_profiles": ["live/profile.lua"],
        "validation": "isolated Lua contracts with synthetic adapters",
        "native_abi": "draft only; no native host implementation",
        "source_sha256": {name: digest(data) for name, data in sorted(inputs.items())},
    }
    receipt = (json.dumps(metadata, indent=2, sort_keys=True) + "\n").encode("utf-8")
    output.mkdir(parents=True, exist_ok=True)
    archive = output / "HD2SE-0.1.1-binding-source.zip"
    packed = {"sdk/hd2se/" + name: data for name, data in inputs.items()}
    packed["CANDIDATE.json"] = receipt
    with zipfile.ZipFile(archive, "w", compression=zipfile.ZIP_DEFLATED) as z:
        for name, data in sorted(packed.items()):
            info = zipfile.ZipInfo(name, date_time=(2026, 10, 13, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o644 << 16
            z.writestr(info, data)
    with zipfile.ZipFile(archive) as z:
        assert z.testzip() is None
        assert set(z.namelist()) == set(packed)
        for name, data in packed.items():
            assert z.read(name) == data, name
    # Run the packaged source with its own root. Leave the review extraction in
    # the explicitly named candidate directory; no source fallback or deletion.
    standalone = output / "standalone-check"
    for name, data in packed.items():
        destination = standalone / name
        if not destination.resolve().is_relative_to(standalone.resolve()):
            raise SystemExit("Unsafe source-candidate member path.")
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(data)
    standalone_command = [sys.executable, str(standalone / "sdk/hd2se/tests/run.py")]
    if args.lua_dll:
        standalone_command += ["--lua-dll", str(args.lua_dll.resolve())]
    standalone_result = subprocess.run(standalone_command, cwd=standalone, capture_output=True, text=True)
    if standalone_result.returncode:
        sys.stdout.write(standalone_result.stdout)
        sys.stderr.write(standalone_result.stderr)
        return standalone_result.returncode
    (output / "CANDIDATE.json").write_bytes(receipt)
    (output / "validation.txt").write_text(
        result.stdout + result.stderr + "\nEXTRACTED SOURCE CHECK\n" + standalone_result.stdout + standalone_result.stderr,
        encoding="utf-8",
    )
    (output / "SHA256SUMS.txt").write_text(
        digest(archive.read_bytes()) + "  " + archive.name + "\n", encoding="ascii"
    )
    print(f"PASS extracted contracts using only packaged SDK sources: {standalone}")
    print(f"PASS allowlisted ZIP inputs, exact-byte readback, CRC and SHA-256: {archive}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
