"""Build the external filesystem service; never loads code into the game."""
from pathlib import Path
import argparse
import hashlib
import subprocess

ROOT=Path(__file__).resolve().parents[1]
def build(output):
    output=Path(output).resolve();output.mkdir(parents=True,exist_ok=True)
    vc=Path(r'C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat')
    command=(f'call "{vc}" >nul && cl /nologo /O2 /GS /W4 /WX /MT /DUNICODE /D_UNICODE '
             f'"{ROOT / "native/steam_service.c"}" /Fo"{output / "steam_service.obj"}" '
             f'/Fe"{output / "steam_service.exe"}" /link /SUBSYSTEM:WINDOWS /DYNAMICBASE /NXCOMPAT /HIGHENTROPYVA bcrypt.lib kernel32.lib shell32.lib user32.lib')
    subprocess.run(command,shell=True,check=True,cwd=output)
    tests=(f'call "{vc}" >nul && cl /nologo /O2 /GS /W4 /WX /MT '
           f'"{ROOT / "native/test_steam_files.c"}" /Fo"{output / "test_steam_files.obj"}" '
           f'/Fe"{output / "test_steam_files.exe"}" /link bcrypt.lib kernel32.lib')
    subprocess.run(tests,shell=True,check=True,cwd=output)
    subprocess.run([str(output/'test_steam_files.exe')],check=True,cwd=output)
    pointer_tests=(f'call "{vc}" >nul && cl /nologo /O2 /GS /W4 /WX /MT '
           f'"{ROOT / "native/test_steam_pointer.c"}" /Fo"{output / "test_steam_pointer.obj"}" '
           f'/Fe"{output / "test_steam_pointer.exe"}" /link kernel32.lib user32.lib')
    subprocess.run(pointer_tests,shell=True,check=True,cwd=output)
    subprocess.run([str(output/'test_steam_pointer.exe')],check=True,cwd=output)
    value=(output/'steam_service.exe').read_bytes()
    name='lll_steam_service_'+hashlib.sha256(value).hexdigest()[:16]+'.exe'
    (output/name).write_bytes(value);(output/'service.txt').write_text(name+'\n')
    return output/name

if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output',required=True,type=Path)
    args=parser.parse_args();print(build(args.output))
