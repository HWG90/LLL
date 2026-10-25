"""Compose LLL's LuaJIT build for the LuaJIT VM boot runtime (Steam build 26088801).

After the boot handoff the game's Lua VM is LuaJIT, so LLL runs its own LuaJIT platform
(src/platform.lua: files, folders and module reads through ffi/kernel32) instead of the
Steam Lua 5.1 build's external helper, pipes and cffi module. Assembled like build.py's
LuaJIT build with the Steam release's stock startup and wrapper:
  - every module in MODULES, LuaJIT variants (platform, ui, ui/capture, ui/font);
  - ui/font with build 26088801's HUD font layout (the values steam/font.lua uses);
  - the 26088801 exe/game.dll pair; the build has no lua51.dll, so native JIT access stays off;
  - LLL's manager capture helper (native/library.txt names it; pass its DLL);
  - the stock startup script read from the installed game and checked by fingerprint.
The output is the LLL source the runtime's handoff embeds. Builds nothing else.

usage: build_luajit_live.py --game "<Helldivers 2 folder>" --capture-helper mcm_input_<hash>.dll --output <file.lua>
"""
from pathlib import Path
import argparse, hashlib, json, struct

from archive import LUA_TYPE
from build import MODULES
from build_steam_probe import ENTRY, GAME, STOCK_STARTUP_SHA256, digest
from build_steam_release import PROTECTED, literal
from lua51_chunk import convert
from steam_resources import SteamResources

ROOT = Path(__file__).resolve().parents[1]
CAPTURE = (ROOT / 'native/library.txt').read_text(encoding='utf-8').strip()
# Old build -> 26088801: PE timestamp, image size, checksum; font, atlas, material owner.
FONT = {'0x6AB3B43F': '0x6AD7C05D', '0x4744000': '0x3382000', '0xECDA6F': '0x2ED14F0',
        '0x3772268': '0x312D998', '0x3772EE8': '0x312E618', '0x37C5478': '0x3180C08'}


def stock_startup(game):
    for path, expected in GAME.items():
        if digest((game / path).read_bytes()) != expected:
            raise ValueError('Unsupported installed game: ' + path)
    files = SteamResources(game / 'data')
    matches = [row for row in files.resources('9ba626afa44a3aa3') if row[0] == ENTRY]
    if len(matches) != 1 or matches[0][1] != LUA_TYPE:
        raise ValueError('Expected stock startup entry unavailable')
    stock = files.read('9ba626afa44a3aa3', matches[0][2], matches[0][3])
    if struct.unpack_from('<II', stock) != (len(stock) - 8, 1) or digest(stock) != STOCK_STARTUP_SHA256:
        raise ValueError('Unsupported stock startup fingerprint')
    convert(stock[8:], 4)  # Validate the entire stock chunk before wrapping.
    return stock


def source(stock, capture):
    def read(name):
        return (ROOT / 'src' / (name + '.lua')).read_text(encoding='utf-8')
    code = ['local LLL_TRUST=(function()\n' + read('trusted') + '\nend)().capture(_G)',
            'local ' + ','.join(PROTECTED) + '=' + ','.join('LLL_TRUST.' + name for name in PROTECTED),
            'local LLL_NATIVE',
            'local LLL_METADATA=(function()\n' + read('metadata') + '\nend)()']
    for variable, name in MODULES:
        body = read(name)
        if name == 'ui/font':
            for old, new in FONT.items():
                if body.count(old) != 1:
                    raise ValueError('HUD font layout changed: ' + old)
                body = body.replace(old, new)
        if name == 'platform':
            code.append('local LLL_BUILDS={{exe_sha256=%s,game_sha256=%s}};local LLL_LUA_SHA=%s' % (
                json.dumps(GAME['bin/helldivers2.exe'].upper()), json.dumps(GAME['data/game/game.dll'].upper()),
                json.dumps('none: LuaJIT is the boot runtime')))
        code.append('local ' + variable + '=(function()\n' + body + '\nend)()')
    code.append('LLL_NATIVE={name=' + json.dumps(CAPTURE) + ',bytes=' + literal(capture) + '}')
    code.append(read('start'))
    # The Steam release's wrapper: a failed initializer keeps every stock return and reports to disk.
    return ('local function start()\n' + '\n'.join(code) + '\nend\n'
            'local function finish(...) local ok,why=pcall(start);if not ok then '
            'local message="[LiveLuaLoader Steam] "..tostring(why);print(message);'
            'local f=io.open((os.getenv("LOCALAPPDATA") or "").."/LLL/Helldivers2/Logs/SteamStartupError.log","wb");'
            'if f then f:write(message);f:close() end end;return ... end\n'
            'return finish(assert(loadstring(' + literal(stock[8:]) + ',"@stock_steam_boot"))(...))\n').encode()


def main():
    parser = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    parser.add_argument('--game', type=Path, required=True)
    parser.add_argument('--capture-helper', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    capture = args.capture_helper.read_bytes()
    if args.capture_helper.name != CAPTURE or CAPTURE != 'mcm_input_' + digest(capture)[:12] + '.dll':
        raise ValueError('Capture helper must be native/library.txt\'s content-addressed DLL')
    body = source(stock_startup(args.game.resolve()), capture)
    args.output.write_bytes(body)
    print(json.dumps({'output': str(args.output), 'sha256': hashlib.sha256(body).hexdigest(), 'bytes': len(body)}, indent=1))


if __name__ == '__main__':
    main()
