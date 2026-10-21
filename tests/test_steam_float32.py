"""IEEE binary32 and owned arrays against Python struct and LuaJIT FFI data."""
from pathlib import Path
import math
import random
import struct
import unittest

from lupa import lua51, luajit21

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'sdk/portable/lll_float32.lua'
NAN_BITS = 0x7FC00000


def expected_bits(value):
    if math.isnan(value):
        return NAN_BITS
    try:
        return struct.unpack('<I', struct.pack('<f', value))[0]
    except OverflowError:
        return 0xFF800000 if value < 0 else 0x7F800000


class Float32(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.lua = lua51.LuaRuntime(encoding=None)
        cls.jit = luajit21.LuaRuntime(encoding=None)
        cls.api = cls.lua.execute(SOURCE.read_bytes())
        cls.protected = cls.lua.eval(b'function(fn,...)return pcall(fn,...)end')
        # Lupa can expose integral Lua numbers as Python ints, erasing -0's
        # sign. Observe the reciprocal and perform round trips inside Lua.
        cls.observe = cls.lua.eval(b'''function(fn,...)
          local value,next_at=fn(...)
          return value,value==0 and 1/value or nil,next_at end''')
        cls.roundtrip = cls.lua.eval(b'function(F,bits)return F.to_bits(F.from_bits(bits))end')
        cls.ffi_bits = cls.jit.execute(b'''local ffi=require('ffi')
          local cell=ffi.new('union { float f; uint32_t u; }[1]')
          return function(value)cell[0].f=value;return tonumber(cell[0].u)end''')

    def refused(self, fn, *args):
        result = self.protected(fn, *args)
        self.assertIsInstance(result, tuple)
        self.assertIs(result[0], False)

    def assert_number(self, actual, expected, reciprocal=None):
        if math.isnan(expected):
            self.assertTrue(math.isnan(actual))
        else:
            self.assertEqual(actual, expected)
            if expected == 0:
                self.assertEqual(reciprocal, math.copysign(math.inf, expected))

    def check_write(self, value):
        bits = expected_bits(value)
        self.assertEqual(self.api[b'to_bits'](value), bits, value)
        ffi_bits = self.ffi_bits(value)
        if math.isnan(value):
            self.assertTrue(ffi_bits & 0x7F800000 == 0x7F800000 and ffi_bits & 0x7FFFFF)
        else:
            self.assertEqual(bits, ffi_bits, value)
        for order, prefix in ((b'le', '<'), (b'be', '>')):
            encoded = struct.pack(prefix + 'I', bits)
            self.assertEqual(self.api[b'write'](value, order), encoded)
            actual, reciprocal, next_at = self.observe(self.api[b'read'], b'!' + encoded + b'?', 2, order)
            self.assertEqual(next_at, 6)
            self.assert_number(actual, struct.unpack(prefix + 'f', encoded)[0], reciprocal)
        actual, reciprocal, _ = self.observe(self.api[b'round'], value)
        self.assert_number(actual, struct.unpack('<f', struct.pack('<I', bits))[0], reciprocal)

    def test_special_values_and_seeded_double_inputs_match_independent_oracles(self):
        values = [0.0, -0.0, 1.0, -1.0, 0.1, -0.1, math.inf, -math.inf, math.nan,
                  -math.nan, math.ldexp(1.0, -1074), -math.ldexp(1.0, -1074),
                  math.ldexp(1.0, -149), math.ldexp(1.0, -126), math.ldexp(1.0, 128)]
        rng = random.Random(0xF32)
        values += [struct.unpack('<d', struct.pack('<Q', rng.getrandbits(64)))[0] for _ in range(1024)]
        for value in values:
            self.check_write(value)

    def test_midpoint_rounding_is_ties_to_even_at_subnormal_normal_and_overflow_boundaries(self):
        for lower in (0, 1, 2, 0x007FFFFE, 0x007FFFFF, 0x00800000,
                      0x3EFFFFFF, 0x3F800000, 0x3F800001, 0x4B7FFFFF, 0x7F7FFFFE):
            low, high = [struct.unpack('<f', struct.pack('<I', word))[0] for word in (lower, lower + 1)]
            midpoint = low + (high - low) / 2
            self.assertEqual(self.api[b'to_bits'](midpoint), lower if lower % 2 == 0 else lower + 1)
            for value in (math.nextafter(midpoint, -math.inf), midpoint, math.nextafter(midpoint, math.inf)):
                self.check_write(value)
                self.check_write(-value)
        threshold = math.ldexp(1.0, 128) - math.ldexp(1.0, 103)
        self.assertEqual(self.api[b'to_bits'](threshold), 0x7F800000)
        self.assertEqual(self.api[b'to_bits'](math.nextafter(threshold, 0)), 0x7F7FFFFF)
        for value in (math.nextafter(threshold, 0), threshold, math.nextafter(threshold, math.inf)):
            self.check_write(value)
            self.check_write(-value)

    def test_seeded_binary_words_decode_exactly_and_nan_writes_are_canonical(self):
        words = [0, 0x80000000, 1, 0x80000001, 0x007FFFFF, 0x00800000,
                 0x7F7FFFFF, 0xFF7FFFFF, 0x7F800000, 0xFF800000,
                 0x7F800001, 0xFFC01234, 0x7FFFFFFF, 0xFFFFFFFF]
        rng = random.Random(0xB1A32)
        words += [rng.getrandbits(32) for _ in range(2048)]
        for bits in words:
            expected = struct.unpack('<f', struct.pack('<I', bits))[0]
            actual, reciprocal, _ = self.observe(self.api[b'from_bits'], bits)
            self.assert_number(actual, expected, reciprocal)
            self.assertEqual(self.roundtrip(self.api, bits), NAN_BITS if math.isnan(expected) else bits)
        self.assertEqual(self.api[b'write'](math.nan), b'\0\0\xc0\x7f')

    def test_array_rounding_fill_overlap_copy_views_import_export_and_owner_release(self):
        self.lua.globals()[b'F'] = self.api
        self.lua.execute(b'''local a=F.array(5)
          assert(a:length()==5 and a:alive())
          for index=0,4 do assert(a:set(index,index+1))end
          assert(a:copy(a,0,1,4))
          for index,value in ipairs({1,1,2,3,4})do assert(a:get(index-1)==value)end
          assert(a:copy(a,1,0,4))
          for index,value in ipairs({1,2,3,4,4})do assert(a:get(index-1)==value)end
          local view=a:view(1,3);local nested=view:view(1,1)
          assert(view:length()==3 and view:set(1,0.1)and a:get(2)==F.round(0.1))
          -- Construct the sign from the actual binary32 word; Lua 5.1 source
          -- constant folding need not preserve the spelling -0.0.
          assert(nested:fill(F.from_bits(0x80000000))and 1/a:get(2)==-math.huge)
          assert(not pcall(view.release,view)and a:alive(),'A view released its parent allocation')
          assert(a:release()and a:release()and not a:alive()and not view:alive()and not nested:alive())
          for _,fn in ipairs({function()a:get(0)end,function()view:set(0,1)end,function()nested:export()end,
            function()view:view(0,0)end,function()a:fill(0)end,function()view:import('')end})do assert(not pcall(fn))end
          local empty=F.array(0);assert(empty:export()==''and empty:import('')==1)
          assert(empty:fill(1)and empty:copy(empty)and empty:release())''')
        values = [0.1, -0.0, math.inf, math.nan, -3.5]
        for order, prefix in ((b'le', '<'), (b'be', '>')):
            raw = b''.join(struct.pack(prefix + 'I', expected_bits(value)) for value in values)
            array = self.api[b'array'](len(values) + 2, 7)
            self.assertEqual(array[b'import'](array, b'!' + raw + b'?', 2, 1, len(values), order), 22)
            self.assertEqual(array[b'export'](array, 1, len(values), order), raw)
            self.assertEqual(array[b'get'](array, 0), 7)
            self.assertEqual(array[b'get'](array, 6), 7)
            actual, reciprocal, _ = self.observe(array[b'get'], array, 2)
            self.assert_number(actual, -0.0, reciprocal)
            self.assertTrue(array[b'release'](array))
        array = self.api[b'array'](2)
        self.assertEqual(array[b'import'](array, struct.pack('<II', 0xFF800001, 0x7F800123)), 9)
        self.assertEqual(array[b'export'](array), struct.pack('<II', NAN_BITS, NAN_BITS))
        self.assertTrue(array[b'release'](array))

    def test_scalar_array_updates_do_not_reencode_the_array_and_export_joins_are_bounded(self):
        self.lua.execute(b'''local calls={frexp=0,char=0,concat=0}
          local numeric={};for key,value in pairs(math)do numeric[key]=value end
          numeric.frexp=function(value)calls.frexp=calls.frexp+1;return math.frexp(value)end
          local strings={byte=string.byte,char=function(...)calls.char=calls.char+1;return string.char(...)end}
          local env={math=numeric,string=strings,table={concat=function(...)calls.concat=calls.concat+1;return table.concat(...)end},
            type=type,assert=assert,error=error,setmetatable=setmetatable}
          setmetatable(env,{__index=function(_,key)error('Unexpected dependency: '..key)end,
            __newindex=function(_,key)error('Global write: '..key)end})
          local chunk=assert(loadstring(...));setfenv(chunk,env);local F=chunk()
          local a=F.array(513,1);local before=calls.frexp
          assert(a:set(256,1.1)and calls.frexp==before+1 and calls.char==0)
          before=calls.frexp;assert(a:fill(2.2,0,256)and calls.frexp==before+1 and calls.char==0)
          before=calls.frexp;assert(a:copy(a,0,256,256)and calls.frexp==before and calls.char==0)
          assert(#a:export()==2052 and calls.char==513 and calls.concat==4)
          assert(F.capabilities.float32 and F.capabilities.mutable_arrays and F.capabilities.views)
          assert(F.capabilities.native_memory==false and F.capabilities.native_pointers==false
            and F.capabilities.native_calls==false and F.capabilities.ffi==false)
          assert(not pcall(function()F.capabilities.native_pointers=true end));assert(a:release())''', SOURCE.read_bytes())

    def test_malformed_scalars_bounds_and_array_ranges_refuse_without_partial_mutation(self):
        for value in (None, True, b'1', {}):
            for name in (b'to_bits', b'round', b'write'):
                self.refused(self.api[name], value)
        for value in (-1, 4294967296, 1.5, math.nan, math.inf, None, True, b'1'):
            self.refused(self.api[b'from_bits'], value)
        for offset in (0, -1, 2, 1.5, math.nan, math.inf, b'1'):
            self.refused(self.api[b'read'], b'\0' * 4, offset)
        self.refused(self.api[b'read'], b'\0' * 3)
        self.refused(self.api[b'read'], None)
        self.refused(self.api[b'read'], b'\0' * 4, 1, b'native')
        self.refused(self.api[b'write'], 0, b'native')
        for count in (-1, 1.5, math.nan, math.inf, self.api[b'max_elements'] + 1, True):
            self.refused(self.api[b'array'], count)
        array = self.api[b'array'](3, 1.5)
        before = array[b'export'](array)
        for index in (-1, 3, 0.5, True, math.nan, math.inf):
            self.refused(array[b'get'], array, index)
            self.refused(array[b'set'], array, index, 2)
        self.refused(array[b'fill'], array, 2, 2, 2)
        self.refused(array[b'copy'], array, array, 0, 2, 2)
        self.refused(array[b'copy'], array, {}, 0, 0, 1)
        self.refused(array[b'import'], array, b'\0' * 11)
        self.refused(array[b'import'], array, b'\0' * 12, 1, 2, 2)
        self.refused(array[b'view'], array, 2, 2)
        self.refused(array[b'export'], array, 0, 3, b'native')
        self.assertEqual(array[b'export'](array), before)
        self.assertTrue(array[b'release'](array))


if __name__ == '__main__':
    unittest.main()
