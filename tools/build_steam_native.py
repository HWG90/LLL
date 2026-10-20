"""Build the hook-free Steam Lua 5.1 filesystem helper into an explicit candidate."""
from pathlib import Path
import argparse
import hashlib
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def build(output):
    output = Path(output).resolve()
    output.mkdir(parents=True, exist_ok=True)
    vc = Path(r'C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat')
    source = ROOT / 'native/steam_files.c'
    command = (f'call "{vc}" >nul && cl /nologo /O2 /GS /W4 /WX /LD /MT '
               f'"{source}" /Fo"{output / "steam_files.obj"}" /Fe"{output / "steam_files.dll"}" '
               '/link /DYNAMICBASE /NXCOMPAT /HIGHENTROPYVA bcrypt.lib kernel32.lib')
    subprocess.run(command, shell=True, check=True, cwd=output)
    tests = (f'call "{vc}" >nul && cl /nologo /O2 /GS /W4 /WX /MT '
             f'"{ROOT / "native/test_steam_files.c"}" /Fo"{output / "test_steam_files.obj"}" '
             f'/Fe"{output / "test_steam_files.exe"}" /link bcrypt.lib kernel32.lib')
    subprocess.run(tests, shell=True, check=True, cwd=output)
    subprocess.run([str(output / 'test_steam_files.exe')], check=True, cwd=output)
    data = (output / 'steam_files.dll').read_bytes()
    name = 'lll_steam_files_' + hashlib.sha256(data).hexdigest()[:16] + '.dll'
    (output / name).write_bytes(data)
    (output / 'library.txt').write_text(name + '\n')
    return output / name


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    print(build(args.output))
