from pathlib import Path
import sys,zipfile,json,hashlib,ctypes,os
ROOT=Path(__file__).absolute().parents[1];sys.path.insert(0,str(ROOT/'tools'))
from build_lean import compile_chunk
workspace=ROOT.parent
packages=[]
for component in ['DBF-MCM','DBF-HUD','Epic-LUT','DBF']:
    packages.extend((workspace/component/'dist/releases/modular-20261010').glob('*-LLL-Modular.zip'))
assert len(packages)==4
results=[]
for package in packages:
    with zipfile.ZipFile(package) as z:
        assert z.testzip() is None
        paths=z.namelist();prefix=paths[0].split('/')[0]+'/'
        manifest=json.loads(z.read(prefix+'manifest.json'))
        for line in z.read(prefix+'FILES-SHA256.txt').decode().splitlines():
            digest,path=line.split('  ',1);assert hashlib.sha256(z.read(prefix+path)).hexdigest()==digest
        declared=manifest['lll']['modules']
        assert set(path for path in paths if path.endswith('.lua'))=={prefix+path for path in declared}|{prefix+'main.lua'}
        for path in declared+['main.lua']:compile_chunk(z.read(prefix+path))
        assert len(z.read(prefix+'main.lua'))<16000
        results.append({'package':str(package),'modules':len(declared),'entry_bytes':len(z.read(prefix+'main.lua')),'crc':'pass','hashes':'pass','lua_compile':'pass','restart_only':manifest['lll']['restart_only']})
# Execute only module constructors in this separate Python LuaJIT process, never on_enable.
# APIs that touch the game remain inside the original guarded lifecycle callbacks.
os.chdir(ROOT)
d=ctypes.CDLL(r'C:\Program Files (x86)\Steam\steamapps\common\Helldivers 2\bin\lua51.dll')
d.luaL_newstate.restype=ctypes.c_void_p;state=d.luaL_newstate();d.luaL_openlibs.argtypes=[ctypes.c_void_p];d.luaL_openlibs(state)
d.luaL_loadbuffer.argtypes=[ctypes.c_void_p,ctypes.c_char_p,ctypes.c_size_t,ctypes.c_char_p];d.lua_pcall.argtypes=[ctypes.c_void_p,ctypes.c_int,ctypes.c_int,ctypes.c_int];d.lua_tolstring.argtypes=[ctypes.c_void_p,ctypes.c_int,ctypes.c_void_p];d.lua_tolstring.restype=ctypes.c_char_p
for result in results:
    package=Path(result['package']);folder=package.parent/package.name.split('-')[0]
    # Derive id from the manifest, not the version-containing filename.
    with zipfile.ZipFile(package) as z:
        prefix=z.namelist()[0].split('/')[0];manifest=json.loads(z.read(prefix+'/manifest.json'))
    folder=package.parent/manifest['id']
    source='''local P=dofile("src/project.lua")
local platform={settings="tests/tmp/modular-component-settings",mkdir=function()return true end,read=function(path)local f=io.open(path,"rb");if not f then return end;local data=f:read("*a");f:close();return data end}
local entry={id=ID,dir=DIR,metadata={name=NAME}}
local spec=assert(P.descriptor(platform,entry.dir));local snapshot=P.snapshot(platform,entry,spec)
local definition,context=P.instantiate(platform,entry,snapshot,function()end)
assert(type(definition)=="table" and type(definition.on_enable)=="function" and type(definition.on_disable)=="function","Lifecycle exports missing")
'''.replace('id=ID','id='+json.dumps(manifest['id'])).replace('dir=DIR','dir='+json.dumps(folder.as_posix())).replace('name=NAME','name='+json.dumps(manifest['name']))
    body=source.encode();status=d.luaL_loadbuffer(state,body,len(body),b'@component-constructor') or d.lua_pcall(state,0,0,0)
    if status:
        error=d.lua_tolstring(state,-1,None).decode(errors='replace');result['constructor']='failed';result['error']=error
    else:result['constructor']='pass'
d.lua_close.argtypes=[ctypes.c_void_p];d.lua_close(state)
output=ROOT/'dist/releases/modular-20261010/component-validation.json';output.write_text(json.dumps(results,indent=2))
print(json.dumps(results,indent=2))
assert all(result['constructor']=='pass' for result in results)