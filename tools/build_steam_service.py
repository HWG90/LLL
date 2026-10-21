"""Build the external filesystem service; never loads code into the game."""
from pathlib import Path
import argparse
import hashlib
import subprocess

ROOT=Path(__file__).resolve().parents[1]
def build(output):
    output=Path(output).resolve();output.mkdir(parents=True,exist_ok=True)
    vc=Path(r'C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat')
    worker=(f'call "{vc}" >nul && cl /nologo /std:c++17 /EHsc /permissive- /Zc:__cplusplus '
            f'/O2 /GS /W4 /WX /MT /utf-8 /c "{ROOT / "native/steam_screenshot.cpp"}" '
            f'/Fo"{output / "steam_screenshot.obj"}"')
    subprocess.run(worker,shell=True,check=True,cwd=output)
    command=(f'call "{vc}" >nul && cl /nologo /O2 /GS /W4 /WX /MT /DUNICODE /D_UNICODE '
             f'"{ROOT / "native/steam_service.c"}" /Fo"{output / "steam_service.obj"}" '
             f'/Fe"{output / "steam_service.exe"}" "{output / "steam_screenshot.obj"}" '
             f'/link /SUBSYSTEM:WINDOWS /DYNAMICBASE /NXCOMPAT /HIGHENTROPYVA '
             f'/DELAYLOAD:d3d11.dll /DELAYLOAD:dxgi.dll /DELAYLOAD:dwmapi.dll delayimp.lib '
             f'bcrypt.lib kernel32.lib shell32.lib user32.lib d3d11.lib dxgi.lib dwmapi.lib '
             f'windowscodecs.lib windowsapp.lib runtimeobject.lib ole32.lib uuid.lib')
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
    keyboard_tests=(f'call "{vc}" >nul && cl /nologo /std:c11 /O2 /GS /W4 /WX /MT '
           f'"{ROOT / "native/test_steam_keyboard.c"}" /Fo"{output / "test_steam_keyboard.obj"}" '
           f'/Fe"{output / "test_steam_keyboard.exe"}" /link kernel32.lib user32.lib')
    subprocess.run(keyboard_tests,shell=True,check=True,cwd=output)
    subprocess.run([str(output/'test_steam_keyboard.exe')],check=True,cwd=output,timeout=30)
    screenshot_tests=(f'call "{vc}" >nul && cl /nologo /O2 /GS /W4 /WX /MT '
           f'"{ROOT / "native/test_steam_screenshot_jobs.c"}" /Fo"{output / "test_steam_screenshot_jobs.obj"}" '
           f'/Fe"{output / "test_steam_screenshot_jobs.exe"}" /link bcrypt.lib kernel32.lib shell32.lib user32.lib')
    subprocess.run(screenshot_tests,shell=True,check=True,cwd=output)
    subprocess.run([str(output/'test_steam_screenshot_jobs.exe')],check=True,cwd=output)
    runtime_tests=(f'call "{vc}" >nul && cl /nologo /std:c++17 /EHsc /permissive- /Zc:__cplusplus '
           f'/O2 /GS /W4 /WX /MT /utf-8 "{ROOT / "native/test_steam_screenshot_runtime.cpp"}" '
           f'/Fo"{output / "test_steam_screenshot_runtime.obj"}" /Fe"{output / "test_steam_screenshot_runtime.exe"}" '
           f'/link /DYNAMICBASE /NXCOMPAT /HIGHENTROPYVA '
           f'/DELAYLOAD:d3d11.dll /DELAYLOAD:dxgi.dll /DELAYLOAD:dwmapi.dll delayimp.lib '
           f'kernel32.lib user32.lib d3d11.lib dxgi.lib dwmapi.lib windowscodecs.lib '
           f'windowsapp.lib runtimeobject.lib ole32.lib uuid.lib')
    subprocess.run(runtime_tests,shell=True,check=True,cwd=output)
    subprocess.run([str(output/'test_steam_screenshot_runtime.exe')],check=True,cwd=output,timeout=60)
    value=(output/'steam_service.exe').read_bytes()
    name='lll_steam_service_'+hashlib.sha256(value).hexdigest()[:16]+'.exe'
    (output/name).write_bytes(value);(output/'service.txt').write_text(name+'\n')
    return output/name

if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output',required=True,type=Path)
    args=parser.parse_args();print(build(args.output))
