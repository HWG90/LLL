"""Run with py -3 -m unittest discover -s tests -p test_build_poll_cache.py."""

import importlib.util
import json
import shutil
import subprocess
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("build_poll_cache", ROOT / "tools/build_poll_cache.py")
builder = importlib.util.module_from_spec(spec)
spec.loader.exec_module(builder)


class PollCachePackageTests(unittest.TestCase):
    def source_copy(self, target):
        for name in (
            "src/poll_cache.lua",
            "examples/poll_cache_fix/main.lua",
            "examples/poll_cache_fix/manifest.json",
            "examples/poll_cache_fix/config/defaults.cfg",
        ):
            path = target / name
            path.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT / name, path)
        return target

    def test_complete_manifest_checksums_and_package(self):
        version, files = builder.runtime_files()
        self.assertEqual(version, "0.1.3")
        self.assertEqual(set(files), {
            "main.lua", "src/poll_cache.lua", "config/defaults.cfg", "manifest.json", "SHA256SUMS.txt"
        })
        manifest = json.loads(files["manifest.json"])
        self.assertTrue(manifest["lll"]["restart_only"])
        self.assertEqual(manifest["lll"]["modules"], ["src/poll_cache.lua"])
        for name, expected in manifest["checksums"].items():
            self.assertEqual(builder.digest(files[name]), expected)
        lines = files["SHA256SUMS.txt"].decode().splitlines()
        self.assertEqual(len(lines), 4)
        for line in lines:
            expected, name = line.split("  ", 1)
            self.assertEqual(builder.digest(files[name]), expected)
        with tempfile.TemporaryDirectory() as folder:
            target = builder.build(Path(folder))
            with zipfile.ZipFile(target) as archive:
                self.assertIsNone(archive.testzip())
                self.assertEqual(set(archive.namelist()), {"README.txt"} | {
                    "lll_poll_cache/" + name for name in files
                })
                for name, body in files.items():
                    self.assertEqual(archive.read("lll_poll_cache/" + name), body)

    def test_build_is_deterministic_and_ignores_unrelated_files(self):
        with tempfile.TemporaryDirectory() as folder:
            folder = Path(folder)
            source = self.source_copy(folder / "source")
            (source / "src/unrelated.lua").write_text("return 'not bundled'")
            (source / "native.dll").write_bytes(b"not bundled")
            first = builder.build(folder / "first", source).read_bytes()
            second = builder.build(folder / "second", source).read_bytes()
            self.assertEqual(first, second)
            # Git autocrlf cannot change this maintenance runtime or its hashes.
            for name in ("src/poll_cache.lua", "examples/poll_cache_fix/main.lua",
                         "examples/poll_cache_fix/config/defaults.cfg"):
                path = source / name
                path.write_bytes(path.read_bytes().replace(b"\r\n", b"\n").replace(b"\n", b"\r\n"))
            self.assertEqual(first, builder.build(folder / "crlf", source).read_bytes())

    def test_source_changes_update_their_manifest_and_package_hashes(self):
        with tempfile.TemporaryDirectory() as folder:
            source = self.source_copy(Path(folder))
            _, before = builder.runtime_files(source)
            path = source / "src/poll_cache.lua"
            path.write_bytes(path.read_bytes() + b"\n-- fixture change\n")
            _, after = builder.runtime_files(source)
            self.assertNotEqual(before["manifest.json"], after["manifest.json"])
            self.assertNotEqual(before["SHA256SUMS.txt"], after["SHA256SUMS.txt"])
            self.assertEqual(before["main.lua"], after["main.lua"])
            self.assertEqual(json.loads(after["manifest.json"])["checksums"]["src/poll_cache.lua"],
                             builder.digest(after["src/poll_cache.lua"]))

    def test_invalid_module_contract_refuses_before_output(self):
        with tempfile.TemporaryDirectory() as folder:
            folder = Path(folder)
            source = self.source_copy(folder / "source")
            path = source / "examples/poll_cache_fix/manifest.json"
            manifest = json.loads(path.read_text())
            manifest["lll"]["modules"].append("src/missing.lua")
            path.write_text(json.dumps(manifest))
            with self.assertRaisesRegex(AssertionError, "module contract"):
                builder.build(folder / "output", source)
            self.assertFalse((folder / "output").exists())

    def test_cli_requires_an_explicit_output(self):
        with tempfile.TemporaryDirectory() as folder:
            result = subprocess.run([sys.executable, str(ROOT / "tools/build_poll_cache.py")],
                                    cwd=folder, capture_output=True, text=True)
            self.assertEqual(result.returncode, 2)
            self.assertIn("--output", result.stderr)
            self.assertEqual(list(Path(folder).iterdir()), [])


if __name__ == "__main__":
    unittest.main()
