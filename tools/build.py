"""Private package builder. No installed files are modified."""
import argparse, hashlib, json, struct, zipfile
from pathlib import Path
from archive import hash_name, write, read
ROOT=Path(__file__).resolve().parents[1]
STOCK_SHA='05bbf52978028758b39f5b91a30a695d20069ceabd774d88755f0582a296bec9'
GAME={'bin/helldivers2.exe':'f5fee03dcfdb2e553a4752c283590950ac13316b376d8196aa556ff0400d5f06',
      'data/game/game.dll':'2e2c3b7c2500646dadd5f2b4c6e0504dbb7e7896139f64cddc0d1813c718f51e'}
CALLBACK='core/wwise/lua/wwise_flow_callbacks'
def sha(data): return hashlib.sha256(data).hexdigest()
def source(stock,platform_source=None,native_bytes=None,native_name=None):
    # UI closures must capture this local before their definitions are compiled.
    code=['local LLL_NATIVE','local LLL_METADATA=(function()\n'+(ROOT/'src/metadata.lua').read_text()+'\nend)()']
    for variable,file in [('LLL_CLEANUP_QUEUE','cleanup_queue'),('LLL_MANAGER','manager'),('LLL_LEGACY','legacy'),('LLL_DISCOVER','discovery'),('LLL_LIVE','live'),('LLL_STATUS','status'),('LLL_CONTROLS','controls'),('LLL_UI_CORE','ui/core'),('LLL_UI_MENU','ui/menu'),('LLL_UI_VIEW','ui/view'),('LLL_UI_CAPTURE','ui/capture'),('LLL_UI','ui'),('LLL_PLATFORM','platform')]:
        text=platform_source if file=='platform' and platform_source is not None else (ROOT/'src'/f'{file}.lua').read_text()
        code.append('local '+variable+'=(function()\n'+text+'\nend)()')
    native_name=native_name or (ROOT/'native/library.txt').read_text().strip()
    native_bytes=native_bytes if native_bytes is not None else (ROOT/'native'/native_name).read_bytes()
    native_literal='"'+''.join('\\%03d'%b for b in native_bytes)+'"'
    code.append('LLL_NATIVE={name='+json.dumps(native_name)+',bytes='+native_literal+'}')
    code.append((ROOT/'src/start.lua').read_text())
    literal='"'+''.join('\\%03d'%b for b in stock[8:])+'"'
    # Function argument expansion preserves stock nil holes and trailing nils.
    return ('local function start()\n'+'\n'.join(code)+'\nend\n'
            'local function finish(...) local ok,why=pcall(start);if not ok then print("[LiveLuaLoader] "..tostring(why)) end;return ... end\n'
            'return finish(assert(loadstring('+literal+',"@stock_wwise"))(...))\n').encode()
def build(stock,game):
    assert sha(stock)==STOCK_SHA,'Unsupported stock callbacks'
    assert struct.unpack('<II',stock[:8])==(len(stock)-8,2)
    for file,digest in GAME.items(): assert sha((game/file).read_bytes())==digest,'Unsupported '+file
    text=source(stock);body=struct.pack('<II',len(text),2)+text
    archive=write({hash_name(CALLBACK):body})
    assert read(archive)[hash_name(CALLBACK)][1]==body
    out=ROOT/'dist';out.mkdir(exist_ok=True)
    manifest={'Version':1,'Guid':'bb921b89-f8d0-4abc-9e93-f426a93fef51','Name':'Live Lua Loader - R16 private candidate',
        'Description':'R16: author entries beneath the single Live Lua Loader root in MCM and the independent manager; persistent loader counts. Shared auto-reload and lifecycle state. Shared F9 manager/MCM state and helper initialization fix. Native window live validation pending.',
        'Options':[{'Name':'Loader','Include':['data']}]}
    files={'manifest.json':(json.dumps(manifest,indent=2)+'\n').encode(),'README.md':(ROOT/'README.md').read_bytes(),
           'data/9ba626afa44a3aa3.patch_0':archive,'data/9ba626afa44a3aa3.patch_0.stream':b'',
           'data/9ba626afa44a3aa3.patch_0.gpu_resources':b''}
    target=out/'LiveLuaLoader-private-candidate.zip'
    with zipfile.ZipFile(target,'w',zipfile.ZIP_DEFLATED) as z:
        for name,data in sorted(files.items()): z.writestr(name,data)
    with zipfile.ZipFile(target) as z: assert z.testzip() is None
    (out/'runtime.lua').write_bytes(text)
    (out/'build-report.json').write_text(json.dumps({'package_sha256':sha(target.read_bytes()),'stock_sha256':sha(stock),
        'game':GAME,'bingus_source_included':False,'live_verified':False},indent=2)+'\n')
    print(target)
if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--callbacks',type=Path);p.add_argument('--game-root',required=True,type=Path);a=p.parse_args()
    stock=a.callbacks.read_bytes() if a.callbacks else read((a.game_root/'data/9ba626afa44a3aa3').read_bytes())[hash_name(CALLBACK)][1]
    build(stock,a.game_root)
