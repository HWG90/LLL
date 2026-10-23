"""Build a current-Steam startup probe; does not deploy or launch the game.

Run with Python 3.14 and the lz4 and lupa wheels (lupa.lua51 compiler).
"""
from pathlib import Path
import argparse
import hashlib
import json
import struct

from archive import LUA_TYPE, write
from lua51_chunk import convert
from steam_resources import SteamResources

ROOT = Path(__file__).resolve().parents[1]
PROFILE = json.loads((ROOT / 'steam-build.json').read_text())
GAME = PROFILE['game']
STOCK_STARTUP_SHA256 = PROFILE['stock_startup_sha256']
ENTRY = 0xf476df93691895fa


def digest(data):
    return hashlib.sha256(data).hexdigest()


def build(game, output):
    from lupa import lua51
    game, output = Path(game).resolve(), Path(output).resolve()
    for relative, expected in GAME.items():
        if digest((game / relative).read_bytes()) != expected:
            raise ValueError('Unsupported stock build: ' + relative)
    stock = SteamResources(game / 'data')
    matches = [row for row in stock.resources('9ba626afa44a3aa3') if row[0] == ENTRY]
    if len(matches) != 1 or matches[0][1] != LUA_TYPE:
        raise ValueError('Expected stock Lua entry unavailable')
    _, _, at, length = matches[0]
    original = stock.read('9ba626afa44a3aa3', at, length)
    size, version = struct.unpack_from('<II', original)
    if version != 1 or size != len(original) - 8:
        raise ValueError('Unsupported stock Lua envelope')
    convert(original[8:], 4)  # Fully parse and validate the stock chunk before wrapping.
    body = (ROOT / 'src/steam/probe.lua').read_text(encoding='utf-8')
    path = Path.home() / 'AppData/Local/LLL/Helldivers2/Logs/SteamPortProbe.log'
    literal = '"' + ''.join('\\%03d' % byte for byte in original[8:]) + '"'
    source = ('local function probe()\nlocal LLL_STEAM_PROBE_LOG=' + json.dumps(path.as_posix())
              + '\n' + body + '\nend\nlocal function finish(...)\n'
              + 'local ok,why=pcall(probe);if not ok then print("[LLL Steam probe] "..tostring(why)) end\n'
              + 'return ...\nend\nreturn finish(assert(loadstring(' + literal + ',"@stock_steam_startup"))(...))\n').encode()
    runtime = lua51.LuaRuntime(encoding=None)
    compiled = runtime.eval(b'string.dump(assert(loadstring(...)))', source)
    bytecode = convert(compiled, 4)
    envelope = struct.pack('<II', len(bytecode), 1) + bytecode
    payload = write({ENTRY: envelope})
    output.mkdir(parents=True, exist_ok=True)
    (output / 'probe.lua').write_bytes(source)
    (output / 'stock-startup.lua-resource').write_bytes(original)
    for suffix in ('', '.stream', '.gpu_resources'):
        (output / ('9ba626afa44a3aa3.patch_101' + suffix)).write_bytes(payload if not suffix else b'')
    receipt = {'purpose':'one-shot startup/API probe, not the completed LLL port',
               'game':GAME,'entry':f'{ENTRY:016x}', 'stock_sha256':digest(original),
               'probe_sha256':digest(payload),'stock_unchanged_inside_wrapper':True,
               'bytecode':'Lua 5.1, little endian, int/instruction/size_t 4, number 8',
               'deployed':False,'log':str(path)}
    (output / 'probe.json').write_text(json.dumps(receipt, indent=2))
    return receipt


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--game', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    print(json.dumps(build(args.game, args.output), indent=2))
