from pathlib import Path
import subprocess,sys,concurrent.futures,shutil
import argparse
parser=argparse.ArgumentParser()
parser.add_argument('--platform',choices=['linux','windows'],default='linux')
parser.add_argument('--work-dir',type=Path,required=True,help='Build directory; Windows expects libffi-win/src/libffi.a and generated headers here')
parser.add_argument('--zig',type=Path,help='Zig 0.14.1 executable for Windows cross compilation')
args=parser.parse_args()
root=Path(__file__).resolve().parent
work=args.work_dir.resolve();work.mkdir(parents=True,exist_ok=True)
src=root/'src';tests=root/'tests';up=root/'vendor/cffi-lua';lua=root/'vendor/lua-5.1.4/src'
win=args.platform == 'windows'
platform='windows' if win else 'linux';dest=root/platform;dest.mkdir(exist_ok=True)
zig=args.zig.resolve() if args.zig else None
if win and not zig: raise SystemExit('--zig is required for Windows')
cpp=[str(zig),'c++','-target','x86_64-windows-gnu'] if win else ['g++']
cc=[str(zig),'cc','-target','x86_64-windows-gnu'] if win else ['gcc']
if win and not (work/'libffi-win/src/libffi.a').exists():
    cross=work/'windows-cross.ini'
    cross.write_text("[binaries]\nc = ["+repr(str(zig))+", 'cc', '-target', 'x86_64-windows-gnu']\ncpp = ["+repr(str(zig))+", 'c++', '-target', 'x86_64-windows-gnu']\nar = ["+repr(str(zig))+", 'ar']\nstrip = 'llvm-strip'\n[host_machine]\nsystem = 'windows'\ncpu_family = 'x86_64'\ncpu = 'x86_64'\nendian = 'little'\n[properties]\nneeds_exe_wrapper = true\n")
    subprocess.run([sys.executable,'-m','mesonbuild.mesonmain','setup',str(work/'libffi-win'),str(root/'vendor/libffi'),'--cross-file',str(cross),'-Ddefault_library=static','-Dtests=false','-Dexe_static_tramp=false'],check=True)
    subprocess.run([sys.executable,'-m','mesonbuild.mesonmain','compile','-C',str(work/'libffi-win'),'-j','2'],check=True)
common=['-O2','-fno-rtti','-fno-exceptions','-std=c++14','-DFFI_LITTLE_ENDIAN','-fvisibility=hidden','-I'+str(lua),'-I'+str(src)]
if win:common+=['-I'+str(work/'libffi-win/include'),'-I'+str(root/'vendor/libffi/src/x86')]
else:common+=['-fPIC']
objects=[];jobs=[]
for name in ['util','ffilib','parser','ast','lib','ffi']:
 obj=work/f'bridge-{platform}-{name}.o';objects.append(str(obj))
 jobs.append(cpp+common+['-include',str(src/'remap.hh'),'-c',str(up/f'src/{name}.cc'),'-o',str(obj)])
obj=work/f'bridge-{platform}-entry.o';objects.append(str(obj))
jobs.append(cpp+common+['-c',str(src/'bridge.cc'),'-o',str(obj)])
if win:
 obj=work/'bridge-windows-bootstrap.o';objects.append(str(obj))
 jobs.append(cpp+common+['-c',str(src/'bootstrap_windows.cc'),'-o',str(obj)])
def run(cmd):
 r=subprocess.run(cmd,capture_output=True,text=True)
 if r.returncode:raise RuntimeError(' '.join(cmd)+'\n'+r.stdout+r.stderr)
 return r.stderr
with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
 for result in pool.map(run,jobs):
  if result:print(result[-1500:])
libffi=[str(work/'libffi-win/src/libffi.a'),'-lbcrypt'] if win else ['-lffi','-ldl']
module=dest/('hd2_cffi.dll' if win else 'hd2_cffi.so')
run(cpp+['-shared']+objects+libffi+['-o',str(module)])
print('Built',module)
if win:
    nativeinfo=dest/'hd2_nativeinfo.dll'
    run(cpp+['-shared','-O2','-std=c++14','-fno-exceptions','-fno-rtti',
        '-I'+str(src),'-I'+str(lua),str(src/'nativeinfo.cc'),'-lbcrypt','-o',str(nativeinfo)])
    print('Built',nativeinfo)
# Independent Lua 5.1.4 harness. No game API guesses are used here.
cs=[str(p) for p in lua.glob('*.c') if p.name not in ['lua.c','luac.c','print.c']]
if win:
 lualib=dest/'lua51.dll';implib=work/'lua51.lib'
 run(cc+['-shared','-O2','-DLUA_BUILD_AS_DLL','-I'+str(lua)]+cs+['-Wl,--out-implib,'+str(implib),'-o',str(lualib)])
 link=[str(implib)]
else:
 lualib=dest/'liblua514.so'
 run(cc+['-shared','-fPIC','-O2','-DLUA_USE_LINUX','-I'+str(lua)]+cs+['-ldl','-lm','-Wl,-soname,liblua514.so','-o',str(lualib)])
 link=[str(lualib),'-Wl,-rpath,$ORIGIN','-ldl']
run(cpp+['-O2','-std=c++14','-I'+str(lua),'-I'+str(src),str(tests/'harness.cc')]+link+['-o',str(dest/('harness.exe' if win else 'harness'))])
run(cc+['-shared','-O2']+([] if win else ['-fPIC'])+[str(tests/'testlib.c'),'-o',str(dest/('ffi_test.dll' if win else 'ffi_test.so'))])
shutil.copy2(tests/'smoke.lua',dest/'smoke.lua')
print('Built harness and unsigned test library for',platform)
