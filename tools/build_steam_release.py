"""Build the current Steam Lua 5.1 LLL candidate without deploying or launching.

External service must first pass tools/build_steam_service.py's standalone tests.
"""
from pathlib import Path
import argparse
import hashlib
import json
import struct
import secrets
import zipfile
import re

from archive import LUA_TYPE, write
from build import MODULES
from build_steam_probe import ENTRY, GAME, STOCK_STARTUP_SHA256, digest
from lua51_chunk import convert
from steam_resources import SteamResources
from steam_launcher import command as launcher_command

ROOT = Path(__file__).resolve().parents[1]
EXCLUDE = {'LLL_MEMORY','LLL_BUILD_GATE','LLL_JIT_GUARD','LLL_JIT_CHURN','LLL_JIT_BUDGET','LLL_DISCOVERY_HASH'}
OVERRIDES = {'ui':'steam/ui','ui/capture':'steam/capture','platform':'steam/platform','ui/font':'steam/font'}
PROTECTED = ['assert','error','pcall','xpcall','type','tostring','tonumber','rawget','rawset','rawequal','pairs','ipairs','next',
             'select','unpack','loadstring','loadfile','dofile','setfenv','getfenv','setmetatable','getmetatable',
             'collectgarbage','print','string','table','math','io','os','debug','coroutine','package','require']


def literal(data):
    return '"' + ''.join('\\%03d' % value for value in data) + '"'


def source(stock, pipe, platform_source=None, developer=False, launcher=None, release_label=None, cffi_name=None, launcher_name=None, nativeinfo_name=None):
    launcher_code=('nil' if launcher is None else literal(launcher.encode()))
    if launcher_name is not None:
        launcher_code='(function()\n'+(ROOT/'src/steam/launcher.lua').read_text()+'\nend)()('+json.dumps(launcher_name)+','+json.dumps(pipe)+')'
    code = [
        'local LLL_TRUST=(function()\n' + (ROOT / 'src/trusted.lua').read_text() + '\nend)().capture(_G,{runtime="lua51"})',
        'local ' + ','.join(PROTECTED) + '=' + ','.join('LLL_TRUST.' + name for name in PROTECTED),
        'local LLL_METADATA=(function()\n' + (ROOT / 'src/metadata.lua').read_text() + '\nend)()',
        'local LLL_STEAM_SERVICE={pipe='+json.dumps(pipe)+',launcher='+launcher_code
        +('' if release_label is None else ',release='+json.dumps(release_label))+'}',
        'local LLL_STEAM_TRANSPORT=(function()\n'+(ROOT/'src/steam/transport.lua').read_text()+'\nend)()',
        'local LLL_STEAM_BUILDS=' + '{exe_sha256=' + json.dumps(GAME['bin/helldivers2.exe'])
        + ',game_sha256=' + json.dumps(GAME['data/game/game.dll']) + '}',
        'local LLL_STEAM_INPUT=(function()\n' + (ROOT / 'src/steam/input.lua').read_text() + '\nend)()',
        'local LLL_STEAM_INPUT_SERVICE=(function()\n' + (ROOT / 'src/steam/input_service.lua').read_text() + '\nend)()',
        'local LLL_STEAM_SCREENSHOT_SERVICE=(function()\n' + (ROOT / 'src/steam/screenshot_service.lua').read_text() + '\nend)()',
    ]
    cffi_config='nil' if cffi_name is None else '{path=(os.getenv("LOCALAPPDATA") or "").."/LLL/Helldivers2/Native/"..'+json.dumps(cffi_name)+'}'
    code.append('local LLL_CFFI=(function()\n'+(ROOT/'src/steam/cffi.lua').read_text()+'\nend)().open('+cffi_config+')')
    for variable, name in MODULES:
        if variable in EXCLUDE:
            continue
        body = platform_source if name == 'platform' and platform_source is not None else (ROOT / 'src' / (OVERRIDES.get(name, name) + '.lua')).read_text(encoding='utf-8')
        if name == 'ui/font' and nativeinfo_name:
            body = body.replace('hd2_nativeinfo_f6d3465944c1aea1.dll', nativeinfo_name)
        code.append('local ' + variable + '=(function()\n' + body + '\nend)()')
    code.append('LLL_PLATFORM.cffi_status=LLL_CFFI;LLL_PLATFORM.native_cffi=LLL_CFFI.available')
    if developer:
        code.append('local steam_dev=(function()\n'+(ROOT/'src/steam/dev.lua').read_text()+'\nend)()(LLL_PLATFORM);LLL_PLATFORM.maintenance=steam_dev.poll')
    code.append((ROOT / 'src/start.lua').read_text(encoding='utf-8'))
    # A failed port initializer must preserve every stock return and report to disk.
    return ('local function start()\n' + '\n'.join(code) + '\nend\n'
            'local function finish(...) local ok,why=pcall(start);if not ok then '
            'local message="[LiveLuaLoader Steam] "..tostring(why);print(message);'
            'local f=io.open((os.getenv("LOCALAPPDATA") or "").."/LLL/Helldivers2/Logs/SteamStartupError.log","wb");'
            'if f then f:write(message);f:close() end end;return ... end\n'
            'return finish(assert(loadstring(' + literal(stock[8:]) + ',"@stock_steam_boot"))(...))\n').encode()


def build(game, service, output, developer=False, portable=False,
          release_label='R32-steam-lua51-preview.1', known_lll_patches=(), cffi_module=None, launcher_exe=None, nativeinfo_module=None):
    from lupa import lua51
    game, service, output = Path(game).resolve(), Path(service).resolve(), Path(output).resolve()
    if portable and (developer or not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]{0,95}',release_label)):
        raise ValueError('Portable releases need a valid label and no developer relay')
    if any(not re.fullmatch(r'[0-9a-f]{64}',value) for value in known_lll_patches):
        raise ValueError('Known LLL startup patches need exact SHA256 fingerprints')
    for path, expected in GAME.items():
        if digest((game / path).read_bytes()) != expected:
            raise ValueError('Unsupported installed game: ' + path)
    service_name = (service / 'service.txt').read_text().strip()
    service_bytes = (service / service_name).read_bytes()
    if service_name != 'lll_steam_service_' + digest(service_bytes)[:16] + '.exe':
        raise ValueError('Service content address mismatch')
    launcher_bytes=None if launcher_exe is None else Path(launcher_exe).read_bytes()
    if launcher_bytes is not None and (not portable or len(launcher_bytes)<64 or launcher_bytes[:2]!=b'MZ'):
        raise ValueError('Native launcher requires a portable package and Windows executable')
    launcher_name=None if launcher_bytes is None else 'lll_steam_launcher_'+digest(launcher_bytes)[:16]+'.exe'
    cffi_bytes=None if cffi_module is None else Path(cffi_module).read_bytes()
    if cffi_bytes is not None and (not portable or len(cffi_bytes)<64 or cffi_bytes[:2]!=b'MZ'):
        raise ValueError('cffi requires a portable package and Windows DLL')
    cffi_name=None if cffi_bytes is None else 'hd2_cffi_'+digest(cffi_bytes)[:16]+'.dll'
    nativeinfo_bytes=None if nativeinfo_module is None else Path(nativeinfo_module).read_bytes()
    if nativeinfo_bytes is not None and (not portable or len(nativeinfo_bytes)<64 or nativeinfo_bytes[:2]!=b'MZ'):
        raise ValueError('Native font helper requires a portable package and Windows-format DLL')
    nativeinfo_name=None if nativeinfo_bytes is None else 'hd2_nativeinfo_'+digest(nativeinfo_bytes)[:16]+'.dll'
    pipe = 'lll_steam_' + secrets.token_hex(16)
    files = SteamResources(game / 'data')
    entry = next(row for row in files.resources('9ba626afa44a3aa3') if row[0] == ENTRY)
    stock = files.read('9ba626afa44a3aa3', entry[2], entry[3])
    if entry[1] != LUA_TYPE or struct.unpack_from('<II', stock) != (len(stock)-8,1):
        raise ValueError('Unsupported stock startup script')
    if digest(stock) != STOCK_STARTUP_SHA256:
        raise ValueError('Unsupported stock startup fingerprint')
    convert(stock[8:],4)  # Validate the entire stock chunk before wrapping.
    launcher=launcher_command(service_name,digest(service_bytes),None if portable else str(game),pipe)
    runtime = source(stock, pipe, developer=developer,launcher=launcher,release_label=release_label if portable else None,cffi_name=cffi_name,launcher_name=launcher_name,nativeinfo_name=nativeinfo_name)
    compiler = lua51.LuaRuntime(encoding=None)
    compiled = compiler.eval(b'string.dump(assert(loadstring(...,"@LLL-Steam")))', runtime)
    chunk = convert(compiled, 4)
    payload = write({ENTRY: struct.pack('<II', len(chunk), 1) + chunk})
    output.mkdir(parents=True, exist_ok=True)
    package = {}
    for suffix in ('', '.stream', '.gpu_resources'):
        name = 'data/9ba626afa44a3aa3.patch_0' + suffix
        value = payload if not suffix else b''
        package[name] = value
        path = output / name; path.parent.mkdir(parents=True, exist_ok=True); path.write_bytes(value)
    package['service/' + service_name] = service_bytes
    if cffi_name is not None: package['native/'+cffi_name]=cffi_bytes
    if nativeinfo_name is not None: package['native/'+nativeinfo_name]=nativeinfo_bytes
    if launcher_name is not None: package['service/'+launcher_name]=launcher_bytes
    if portable:
        portable_info={'format':'LLL-Steam-portable-v1','release':release_label,'game':GAME,
                      'service':service_name,'known_lll_patch_sha256':sorted(set(known_lll_patches)),
                      'payloads':{name:digest(value) for name,value in sorted(package.items())}}
        if cffi_name is not None: portable_info['cffi']=cffi_name
        if nativeinfo_name is not None: portable_info['nativeinfo']=nativeinfo_name
        if cffi_name is not None: portable_info['compatibility']={'live_game':'Linux/Proton only','windows':'WILL NOT WORK'}
        if launcher_name is not None: portable_info['launcher']=launcher_name
        package['package.json']=(json.dumps(portable_info,indent=2)+'\n').encode()
        package['install_proton.py']=(ROOT/'tools/install_proton_preview.py').read_bytes()
        if cffi_name is not None:
            package['LINUX-ONLY-WARNING.txt']=(ROOT/'docs/LINUX-ONLY-WARNING.txt').read_bytes()
            for dest,origin in [('cffi-lua.txt','cffi-lua/COPYING.md'),('libffi.txt','libffi/LICENSE'),('lua-5.1.4.txt','lua-5.1.4/COPYRIGHT')]:
                package['LICENSES/'+dest]=(ROOT/'native/cffi/vendor'/origin).read_bytes()
        package['Install.ps1']=(ROOT/'tools/install_steam_preview.ps1').read_bytes()
        package['README.txt']=(ROOT/'docs/STEAM-PREVIEW-INSTALL.txt').read_bytes()
        package['CONTENTS-NOTICES.txt']=(
            'Live Lua Loader current-Steam preview. Original LLL code by Goose; shared runtime helpers '
            'adapted from CowboyBingus under the included 0BSD notices. MCM UI primitives come from this project.\n'
            'The startup patch preserves the supported game startup bytecode in its wrapper; original envelope SHA256: '
            +digest(stock)+'. No game executable, game DLL, font asset, personal setting, log or third-party mod is included. Optional native helper DLLs are built from the included source.\n'
            'The helper is an external Windows-format x64 program used through Proton. Python 3 is required by the Linux installer; no compiler is needed.\n'
            'No repository-wide open-source license has been selected. Source is available at https://github.com/HWG90/LLL.\n').encode()
        for name in ('BSL-V20-LICENSE.txt','BSL-HELPERS-LICENSE.txt','BSL-V20-PROVENANCE.txt'):
            package[name]=(ROOT/'docs'/name).read_bytes()
    (output / service_name).write_bytes(service_bytes)
    (output / 'runtime.lua').write_bytes(runtime)
    (output / 'runtime.luac').write_bytes(chunk)
    package['FILES-SHA256.txt'] = ''.join(digest(value) + '  ' + name + '\n' for name,value in sorted(package.items())).encode()
    package_name='LiveLuaLoader-'+release_label+'.zip' if portable else 'LLL-Steam-Lua51-candidate.zip'
    with zipfile.ZipFile(output / package_name, 'w', zipfile.ZIP_DEFLATED) as archive:
        for name,value in package.items(): archive.writestr(name,value)
    if portable:
        for name,value in package.items():
            path=output/name;path.parent.mkdir(parents=True,exist_ok=True);path.write_bytes(value)
        (output/'SHA256SUMS.txt').write_text(digest((output/package_name).read_bytes())+'  '+package_name+'\n')
    receipt = {'runtime':'Lua 5.1','game':GAME,'stock_sha256':digest(stock),'service':service_name,'pipe':pipe,
               'service_sha256':digest(service_bytes),'patch_sha256':digest(payload),'runtime_sha256':digest(chunk),
               'native_launcher':launcher_name,'cffi_module':cffi_name,'nativeinfo_module':nativeinfo_name,'cffi_live_validation':'pending' if cffi_name else 'not configured','deployment':'not deployed','live_validation':'pending','portable':portable,'package':package_name,
               'release_label':release_label if portable else None,
               'developer_relay':'temporary; closes after 30 minutes or explicit close()' if developer else 'not included',
               'install_note':'External service belongs in LOCALAPPDATA/LLL/Helldivers2/Service; starts automatically on game launch.'}
    (output / 'build.json').write_text(json.dumps(receipt, indent=2))
    return receipt


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--game', required=True, type=Path)
    parser.add_argument('--service', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--developer-relay', action='store_true', help='Include temporary local review commands; excluded from normal builds')
    parser.add_argument('--portable',action='store_true',help='Build the public prebuilt installer using a per-install game-path binding')
    parser.add_argument('--release-label',default='R32-steam-lua51-preview.1')
    parser.add_argument('--known-lll-patch',action='append',default=[],help='Reviewed LLL-owned startup patch SHA256 allowed for migration')
    parser.add_argument('--cffi-module',type=Path,help='Optional build-26088801 cffi bootstrap DLL; portable packages only')
    parser.add_argument('--nativeinfo-module',type=Path,help='Optional matching native HUD font helper DLL')
    parser.add_argument('--launcher-exe',type=Path,help='Optional native launcher for Windows and Proton without PowerShell')
    args = parser.parse_args()
    print(json.dumps(build(args.game,args.service,args.output,args.developer_relay,args.portable,args.release_label,args.known_lll_patch,args.cffi_module,args.launcher_exe,args.nativeinfo_module),indent=2))
