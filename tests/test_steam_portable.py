"""Portable data contracts against independent LuaJIT-bit and struct oracles."""
from pathlib import Path
import random
import struct
import unittest

from lupa import lua51, luajit21

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'sdk/portable/lll_portable.lua'


class PortableData(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.lua = lua51.LuaRuntime(encoding=None)
        cls.jit = luajit21.LuaRuntime(encoding=None)
        cls.api = cls.lua.execute(SOURCE.read_bytes())
        cls.bits = cls.api[b'bit']
        cls.bytes = cls.api[b'bytes']
        cls.oracle = cls.jit.eval(b"require('bit')")
        cls.protected = cls.lua.eval(b'function(fn,...)return pcall(fn,...)end')

    def refused(self, fn, *args):
        result = self.protected(fn, *args)
        self.assertIsInstance(result, tuple)
        self.assertIs(result[0], False)

    def test_binary_and_unary_bits_match_luajit_for_boundaries_and_seeded_words(self):
        rng = random.Random(0x4C4C4C)
        words = [-2147483648, -2147483647, -1, 0, 1, 0x7FFFFFFF, 0x80000000, 0xFFFFFFFF]
        cases = [(a, b) for a in words for b in words]
        cases += [(rng.randint(-2147483648, 4294967295), rng.randint(-2147483648, 4294967295))
                  for _ in range(256)]
        for name in (b'band', b'bor', b'bxor'):
            for a, b in cases:
                self.assertEqual(self.bits[name](a, b), self.oracle[name](a, b), (name, a, b))
                self.assertEqual(self.bits[name](a, b, 0x89ABCDEF), self.oracle[name](a, b, 0x89ABCDEF))
            for value in words:
                self.assertEqual(self.bits[name](value), self.oracle[name](value))
        for name in (b'tobit', b'bnot', b'bswap'):
            for value, _ in cases:
                self.assertEqual(self.bits[name](value), self.oracle[name](value), (name, value))

    def test_shifts_rotations_and_hex_match_luajit_without_wide_intermediate_rounding(self):
        rng = random.Random(0xB17)
        words = [-2147483648, -1, 0, 1, 0x12345678, 0x80000001, 0xFFFFFFFF]
        words += [rng.randint(-2147483648, 4294967295) for _ in range(96)]
        counts = [-2147483648, -33, -32, -31, -1, 0, 1, 7, 8, 16, 24, 31, 32, 33, 63, 64, 4294967295]
        for name in (b'lshift', b'rshift', b'arshift', b'rol', b'ror'):
            for value in words:
                for count in counts:
                    self.assertEqual(self.bits[name](value, count), self.oracle[name](value, count),
                                     (name, value, count))
        for value in words:
            self.assertEqual(self.bits[b'tohex'](value), self.oracle[b'tohex'](value))
            for digits in (-8, -4, -1, 0, 1, 4, 8):
                self.assertEqual(self.bits[b'tohex'](value, digits), self.oracle[b'tohex'](value, digits))

    def test_integer_codecs_match_struct_and_read_offsets_preserve_surrounding_bytes(self):
        rng = random.Random(0xC0DEC)
        for kind, fmt, minimum, maximum in (
            ('u16', 'H', 0, 65535), ('i16', 'h', -32768, 32767),
            ('u32', 'I', 0, 4294967295), ('i32', 'i', -2147483648, 2147483647),
        ):
            values = [minimum, maximum, 0, 1] + [rng.randint(minimum, maximum) for _ in range(128)]
            width = struct.calcsize(fmt)
            for order, prefix in ((b'le', '<'), (b'be', '>')):
                for value in values:
                    expected = struct.pack(prefix + fmt, value)
                    self.assertEqual(self.bytes[('write_' + kind).encode()](value, order), expected)
                    self.assertEqual(self.bytes[('read_' + kind).encode()](b'!' + expected + b'?', 2, order),
                                     (value, width + 2))
                    if order == b'le':
                        self.assertEqual(self.bytes[('write_' + kind).encode()](value), expected)
                        self.assertEqual(self.bytes[('read_' + kind).encode()](expected), (value, width + 1))
        self.assertEqual(self.bytes[b'write_u32'](0x89ABCDEF), b'\xef\xcd\xab\x89')
        self.assertEqual(self.bytes[b'read_i32'](b'\x00\x00\x00\x80'), (-2147483648, 5))

    def test_u64_parts_match_exact_python_values_above_lua_number_precision(self):
        rng = random.Random(0x64B17)
        values = [0, 0xFFFFFFFF, 0x100000000, (1 << 53) + 1, 1 << 63, (1 << 64) - 1]
        values += [rng.getrandbits(64) for _ in range(128)]
        for value in values:
            low, high = value & 0xFFFFFFFF, value >> 32
            for order, prefix in ((b'le', '<'), (b'be', '>')):
                encoded = struct.pack(prefix + 'Q', value)
                self.assertEqual(self.bytes[b'write_u64'](low, high, order), encoded)
                self.assertEqual(self.bytes[b'read_u64'](b'!' + encoded, 2, order), (low, high, 10))
        self.assertEqual(self.bytes[b'write_u64'](0x89ABCDEF, 0x01234567),
                         b'\xef\xcd\xab\x89\x67\x45\x23\x01')

    def test_malformed_words_ranges_offsets_and_orders_are_rejected(self):
        malformed = [None, True, b'1', {}, -2147483649, 4294967296, 1.5,
                     float('nan'), float('inf'), -float('inf')]
        for name in (b'tobit', b'band', b'bor', b'bxor', b'bnot', b'bswap', b'tohex'):
            for value in malformed:
                self.refused(self.bits[name], value)
        for name in (b'band', b'bor', b'bxor'):
            self.refused(self.bits[name])
            self.refused(self.bits[name], 0, None)
        for name in (b'lshift', b'rshift', b'arshift', b'rol', b'ror'):
            for value in malformed:
                self.refused(self.bits[name], value, 1)
                self.refused(self.bits[name], 1, value)
        for digits in (-9, 9, 1.5, True, b'8'):
            self.refused(self.bits[b'tohex'], 0, digits)
        for kind, width, minimum, maximum in (
            ('u16', 2, 0, 65535), ('i16', 2, -32768, 32767),
            ('u32', 4, 0, 4294967295), ('i32', 4, -2147483648, 2147483647),
        ):
            read, write = self.bytes[('read_' + kind).encode()], self.bytes[('write_' + kind).encode()]
            for value in (minimum - 1, maximum + 1, 0.5, None, True, b'1'):
                self.refused(write, value)
            for offset in (0, -1, 1.5, 2, float('nan'), float('inf'), b'1'):
                self.refused(read, b'\0' * width, offset)
            self.refused(read, b'\0' * (width - 1))
            self.refused(read, None)
            self.refused(read, b'\0' * width, 1, b'native')
            self.refused(write, 0, b'native')
        for value in (-1, 4294967296, 1.5, None, True):
            self.refused(self.bytes[b'write_u64'], value, 0)
            self.refused(self.bytes[b'write_u64'], 0, value)
        self.refused(self.bytes[b'read_u64'], b'\0' * 7)
        self.refused(self.bytes[b'read_u64'], b'\0' * 8, 2)
        self.refused(self.bytes[b'write_u64'], 0, 0, b'native')

    def test_module_needs_only_pure_lua_primitives_and_installs_no_global_aliases(self):
        self.lua.execute(b'''local before_bit,before_ffi,loaded_bit,loaded_ffi=bit,ffi,package.loaded.bit,package.loaded.ffi
          local env={math=math,string=string,type=type,assert=assert,select=select,setmetatable=setmetatable,error=error}
          setmetatable(env,{__index=function(_,key)error('Unexpected external dependency: '..key)end,
            __newindex=function(_,key)error('Global write: '..key)end})
          local chunk=assert(loadstring(...));setfenv(chunk,env)
          local data=chunk()
          assert(data.version==1 and data.capabilities.bit32 and data.capabilities.integer_codecs and data.capabilities.u64_parts)
          assert(data.capabilities.ffi==false and data.capabilities.native_memory==false
            and data.capabilities.native_calls==false and data.capabilities.float32==false and data.capabilities.mutable_buffers==false)
          assert(not pcall(function()data.capabilities.ffi=true end))
          assert(data.bit.bxor(-1,0)==-1 and data.bytes.read_u32(data.bytes.write_u32(4294967295))==4294967295)
          assert(bit==before_bit and ffi==before_ffi and package.loaded.bit==loaded_bit and package.loaded.ffi==loaded_ffi)
          ''', SOURCE.read_bytes())


if __name__ == '__main__':
    unittest.main()
