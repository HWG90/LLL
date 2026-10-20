"""Bounded-memory native dependency checks in the actual Lua 5.1 runtime."""
from pathlib import Path
import os
import unittest

from lupa import lua51

ROOT = Path(__file__).resolve().parents[1]


class SteamNativePreflight(unittest.TestCase):
    def setUp(self):
        self.previous = Path.cwd()
        os.chdir(ROOT)
        self.lua = lua51.LuaRuntime(encoding=None)
        self.lua.execute(b'project=dofile("src/project.lua")')

    def tearDown(self):
        os.chdir(self.previous)

    def check(self, source):
        # Store input before measuring: only guard-created allocation counts.
        self.lua.globals()[b'_source'] = source
        return self.lua.execute(b'''collectgarbage('collect')
          local before=collectgarbage('count')
          collectgarbage('stop')
          local started=os.clock()
          local ok,why=pcall(project.check_runtime,{native_ffi=false},_source,'fixture.lua')
          local elapsed=os.clock()-started
          local allocated=collectgarbage('count')-before
          collectgarbage('restart')
          return ok,why,elapsed,allocated''')

    def test_literal_calls_and_decoded_short_names(self):
        cases = {
            b"side_effect();local native=require('ffi')": b'ffi',
            b'return require "bit"': b'bit',
            b'return require([[jit]])': b'jit',
            b"return _G.require('ffi')": b'ffi',
            b"_G -- global\r. --[=[note]=] require -- another\n ('jit')": b'jit',
            br"return require('\102\102\105')": b'ffi',
            br"return require('\098\105\116')": b'bit',
            br"return require('\106i\116')": b'jit',
            b'return require [==[\r\nffi]==]': b'ffi',
            b'return require [[\njit]]': b'jit',
            b"return 'prefix'..require('ffi')": b'ffi',
        }
        for source, name in cases.items():
            with self.subTest(source=source):
                ok, why, _, _ = self.check(source)
                self.assertFalse(ok)
                self.assertIn(b'Unsupported runtime: fixture.lua requires LuaJIT ' + name
                              + b'; script was not executed', why)

    def test_comments_strings_private_imports_and_runtime_bypass(self):
        cases = [
            b"-- require('ffi')\nreturn true",
            b"-- require('ffi')\rreturn true",
            b"--[=[_G.require('ffi')]=]\nreturn true",
            b'''local example="require('ffi')";return true''',
            b'''local example='require("bit")';return true''',
            br'''local example="escaped \" require('ffi') \" text";return true''',
            b"local example=[==[require('jit')]==];return mod.require('ffi')",
            b"return private.require('bit'), object:require('jit')",
            br"return require('\ffi')",  # \f is a form-feed, not the letter f.
            br"return require('\\ffi')",
            b"return require('ffii')",
            b"return require('jit.util')",
        ]
        for source in cases:
            with self.subTest(source=source):
                self.assertTrue(self.check(source)[0])
        self.lua.execute(b'''project.check_runtime({native_ffi=true},"unterminated '", 'legacy.lua')
          project.check_runtime({},"require('ffi')", 'legacy-default.lua')
          assert(executed==nil)
          local ok=pcall(project.check_runtime,{native_ffi=false},
            "_G.executed=true;require('ffi')",'no-execution.lua')
          assert(not ok and executed==nil)''')

    def test_four_megabyte_inputs_have_bounded_allocation_and_time(self):
        filler = b'x' * (4 * 1024 * 1024)
        cases = {
            'early dependency': b"require('ffi')\n--[=[" + filler + b']=]',
            'after long comment': b'--[==[' + filler + b"]==]\nrequire('ffi')",
            'after quoted literal': b'local text="' + filler + br'''";require('\102\102\105')''',
            'portable long literal': b'local text=[==[' + filler + b"require('ffi')]==];return true",
            # Distinct identifier strings expose retained-token allocation even
            # with collection stopped; none of this source is executed.
            'after generated code': b''.join(b'v%06d=0\n' % index for index in range(420000))
                + b"require('ffi')",
        }
        for label, source in cases.items():
            with self.subTest(case=label):
                ok, why, elapsed, allocated_kb = self.check(source)
                self.assertEqual(ok, label == 'portable long literal')
                if not ok:
                    self.assertIn(b'requires LuaJIT ffi', why)
                self.assertLess(allocated_kb, 256,
                                f'{label} allocated {allocated_kb:.1f} KB with GC stopped')
                limit = 2.0 if label == 'after generated code' else 1.0
                self.assertLess(elapsed, limit, f'{label} took {elapsed:.3f} seconds')
                print(f'{label}: {len(source)} bytes, {allocated_kb:.2f} KB, {elapsed * 1000:.1f} ms')

    def test_large_literals_are_not_compiled_or_copied_for_decoding(self):
        self.lua.execute(b'''loadstring=function()error('Guard compiled a source literal')end''')
        delimiter = b'=' * 65536
        source = (b'--[' + delimiter + b'[' + b'x' * (4 * 1024 * 1024)
                  + b']' + delimiter + br"] return require('\102\102\105')")
        ok, why, elapsed, allocated_kb = self.check(source)
        self.assertFalse(ok)
        self.assertIn(b'requires LuaJIT ffi', why)
        self.assertLess(allocated_kb, 256)
        self.assertLess(elapsed, 1.0)


if __name__ == '__main__':
    unittest.main()
