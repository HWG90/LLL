from pathlib import Path
import subprocess,hashlib
ROOT=Path(__file__).resolve().parents[1];native=ROOT/'native';out=native/'lean-build';out.mkdir(exist_ok=True)
vc=Path(r"C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat")
cmd=f'call "{vc}" >nul && cl /nologo /c /O1 /GS /Zl /W4 /WX "{native / "input_guard.c"}" "{native / "lean_runtime.c"}" && link /nologo /DLL /ENTRY:DllMain /NODEFAULTLIB /OPT:REF /OPT:ICF /DYNAMICBASE /NXCOMPAT /HIGHENTROPYVA /OUT:"{out / "mcm_input_lean_gs.dll"}" input_guard.obj lean_runtime.obj user32.lib kernel32.lib bcrypt.lib libvcruntime.lib libcmt.lib'
subprocess.run(cmd,shell=True,check=True,cwd=out)
cmd=f'call "{vc}" >nul && cl /nologo /O1 /GS /W4 /WX "{native / "test_input_guard.c"}" /Fo"{out / "test.obj"}" /Fe"{out / "test.exe"}" /link user32.lib'
subprocess.run(cmd,shell=True,check=True,cwd=out);subprocess.run([str(out/'test.exe')],check=True)
print(out/'mcm_input_lean_gs.dll');print((out/'mcm_input_lean_gs.dll').stat().st_size)

import shutil
helper=out/'mcm_input_lean_gs.dll'
name='mcm_input_'+hashlib.sha256(helper.read_bytes()).hexdigest()[:12]+'.dll'
shutil.copy2(helper,native/name)
(native/'library.txt').write_text(name)
