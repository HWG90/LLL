"""Current-Steam reader, bytecode ABI and one-shot startup lifecycle checks."""
from pathlib import Path
import struct
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tools'))
import lz4.block
from lua51_chunk import convert
from steam_resources import DSAR, SteamResources


def dsar(chunks):
    header_end = 32 + len(chunks) * 32
    result = bytearray(header_end)
    raw_at = 0
    for index, (chunk, codec) in enumerate(chunks):
        data = lz4.block.compress(chunk, store_size=False) if codec == 3 else chunk
        struct.pack_into('<QQIIB', result, 32 + index * 32, raw_at, len(result), len(chunk), len(data), codec)
        result.extend(data)
        raw_at += len(chunk)
    struct.pack_into('<4I2Q', result, 0, 0x52415344, 0x10003, len(chunks), header_end, raw_at, 0)
    return result


class StockReaderTests(unittest.TestCase):
    def test_cross_codec_boundaries_and_reject_outside(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'data'
            path.write_bytes(dsar([(b'first-block', 3), (b'raw-second-block', 0)]))
            reader = DSAR(path)
            self.assertEqual(reader.read(8, 10), b'ockraw-sec')
            self.assertEqual(reader.read(reader.size, 0), b'')
            for start, size in [(-1, 1), (0, -1), (reader.size, 1)]:
                with self.assertRaises(ValueError): reader.read(start, size)
            corrupt = dsar([(b'first', 3), (b'second', 0)])
            struct.pack_into('<Q', corrupt, 64, 6)
            path.write_bytes(corrupt)
            with self.assertRaises(ValueError): DSAR(path)

    def test_dsaa_fragmented_file(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            # Logical file abcdef joins two nonadjacent positions in bundle 0.
            name = b'archive\0'
            table_at = 48 + len(name)
            metadata = bytearray(table_at + 32)
            struct.pack_into('<6I', metadata, 0, 0x41415344, 0x10001, len(metadata), 1, 1, 0)
            struct.pack_into('<QIIQ', metadata, 24, 6, 48, 2, table_at)
            metadata[48:table_at] = name
            struct.pack_into('<QQQQ', metadata, table_at, 0, 2, 3, 10)
            (root / 'bundles.nxa').write_bytes(dsar([(bytes(metadata), 3)]))
            (root / 'bundles.00.nxa').write_bytes(dsar([(b'--abc-----def--', 3)]))
            stock = SteamResources(root)
            self.assertEqual(stock.read('archive', 1, 4), b'bcde')
            with self.assertRaises(ValueError): stock.read('archive', 5, 2)


class Lua51Tests(unittest.TestCase):
    def setUp(self):
        from lupa import lua51
        self.lua = lua51.LuaRuntime(encoding=None)

    def test_nested_chunk_roundtrip_and_runtime_results(self):
        original = self.lua.eval(b'string.dump(function(a) local function inner() return a,nil,3,nil end return inner() end)')
        target = convert(original, 4)
        self.assertEqual(target[8], 4)
        restored = convert(target, 8)
        self.assertEqual(original, restored)
        self.assertEqual(self.lua.eval(b'assert(loadstring(...))(7)', restored), (7, None, 3, None))
        for invalid in (target[:-1], target + b'x', b'\x1bLJ' + target[3:]):
            with self.assertRaises(ValueError): convert(invalid, 8)

    def test_probe_returns_detaches_and_preserves_later_owner(self):
        for later_owner in (False, True):
            lua = self.lua
            lua.execute(b'''LLL_STEAM_PROBE_STARTED=nil;messages={};closed=0;calls=0
                io={open=function()return {write=function()end,flush=function()end,close=function()closed=closed+1 end}end}
                print=function(s) messages[#messages+1]=s end
                LLL_STEAM_PROBE_LOG='test'
                original=function(a)calls=calls+1;return a,nil,3,nil end
                update=original''')
            lua.execute((ROOT / 'src/steam/probe.lua').read_bytes())
            self.assertEqual(lua.eval(b'update(9)'), (9, None, 3, None))
            if later_owner:
                lua.execute(b'local owned=update; later=function(...) return owned(...) end; update=later')
            lua.eval(b'update(10)')
            lua.eval(b'update(11)')
            self.assertTrue(lua.eval(b'update == ' + (b'later' if later_owner else b'original')))
            messages = lua.eval(b'#messages')
            lua.eval(b'update(12)')
            self.assertEqual(lua.eval(b'#messages'), messages)
            self.assertEqual(lua.eval(b'closed'), 1)
            self.assertEqual(lua.eval(b'calls'), 4)


if __name__ == '__main__':
    unittest.main()
