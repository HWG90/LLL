"""Private-import safety and allocation contracts in the installed Lua runtimes."""
from pathlib import Path
import json
import os
import unittest

from lupa import lua51
try:
    from lupa import luajit21
except ImportError:
    luajit21 = None

ROOT = Path(__file__).resolve().parents[1]
RUNTIMES = [('Lua 5.1', lua51)] + ([('LuaJIT', luajit21)] if luajit21 else [])


class ProjectImportPreflight(unittest.TestCase):
    def setUp(self):
        self.previous = Path.cwd()
        os.chdir(ROOT)

    def tearDown(self):
        os.chdir(self.previous)

    def runtime(self, implementation):
        lua = implementation.LuaRuntime(encoding=None)
        lua.execute(b'''project=dofile('src/project.lua')
          for index=1,50 do
            local name,value=debug.getupvalue(project.snapshot,index)
            if name=='imports' then scanner=value;break end
          end
          assert(type(scanner)=='function')''')
        return lua

    def scan(self, lua, source):
        result = lua.globals()[b'scanner'](source)
        return [result[index] for index in range(1, len(result) + 1)]

    def test_literal_forms_and_private_names(self):
        cases = [
            b"mod.require('src.helper')", b'mod.require("src/helper.lua")',
            b"mod --prefix\r. --[==[ comment ]==] require --name\n('src.helper')",
            br"mod.require('\115rc\046helper')",
            b'mod.require([==[src.helper]==])',
            b"mod.require 'src.helper'", b'mod.require [[src.helper]]',
            b"other.mod.require('src.helper')",  # Retained receiver handling.
        ]
        for label, implementation in RUNTIMES:
            lua = self.runtime(implementation)
            for source in cases:
                with self.subTest(runtime=label, source=source):
                    self.assertEqual(self.scan(lua, source), [b'src/helper.lua'])
            self.assertEqual(self.scan(lua, b"mod.require('ffi');mod.require('ffi')"), [b'ffi.lua'])
            # Keep existing first-literal handling; dynamic expressions remain
            # outside complete static dependency analysis.
            self.assertEqual(self.scan(lua, b"mod.require('src.'..suffix)"), [b'src/.lua'])

    def test_comments_strings_and_nonmatching_identifiers_are_ignored(self):
        source = br'''-- mod.require('comment')
          --[==[ mod.require('long_comment') ]==]
          local a="mod.require('quoted')"
          local b='escaped \' mod.require("quoted2")'
          local c=[=[mod.require('long_string')]=]
          xmod.require('other');mod.requirex('other');mod:require('other')
          return mod.require('src.helper')'''
        for label, implementation in RUNTIMES:
            with self.subTest(runtime=label):
                lua=self.runtime(implementation)
                lua.eval(b'assert(loadstring(...))',source)
                self.assertEqual(self.scan(lua, source), [b'src/helper.lua'])

    def test_long_string_first_newline_and_short_comment_endings(self):
        for label, implementation in RUNTIMES:
            lua = self.runtime(implementation)
            for newline in (b'\r', b'\n', b'\r\n', b'\n\r'):
                with self.subTest(runtime=label, newline=newline):
                    self.assertEqual(lua.eval(b'assert(loadstring(...))()',
                                             b'return [==[' + newline + b'src.helper]==]'), b'src.helper')
                    self.assertEqual(self.scan(lua, b'mod.require [==[' + newline + b'src.helper]==]'),
                                     [b'src/helper.lua'])
                    self.assertEqual(self.scan(lua, b"-- example mod.require('ignored')" + newline
                                               + b"return mod.require('src.helper')"), [b'src/helper.lua'])

    def test_invalid_paths_and_unique_module_budget(self):
        bad = [b'../escape', b'/absolute', b'C:/absolute', b'src//helper', b'a' * 241]
        bad += [br'src\\helper', br'src\000helper', br'src\010helper']
        for label, implementation in RUNTIMES:
            lua = self.runtime(implementation)
            for path in bad:
                with self.subTest(runtime=label, path=path[:40]):
                    with self.assertRaises(Exception):
                        self.scan(lua, b"mod.require('" + path + b"')")
            imports = b';'.join(b"mod.require('src/m%d')" % index for index in range(512))
            self.assertEqual(len(self.scan(lua, imports)), 512)
            with self.assertRaises(Exception):
                self.scan(lua, imports + b";mod.require('src/overflow')")
            self.assertEqual(self.scan(lua, b"mod.require('src/helper');" * 10000), [b'src/helper.lua'])

    def test_public_snapshot_refuses_missing_dependency_before_execution(self):
        for label, implementation in RUNTIMES:
            lua = self.runtime(implementation)
            lua.execute(b'''local function check(entry,helper)
              local files={['mods/main.lua']=entry,['mods/src/helper.lua']=helper or 'return true'}
              local p={native_ffi=false,read=function(path)return files[path]end}
              local spec={entry='main.lua',modules={'src/helper.lua'},defaults='defaults.cfg'}
              local ok,why=pcall(project.snapshot,p,{id='test',dir='mods'},spec)
              assert(not ok and tostring(why):find('undeclared import src/missing.lua',1,true))
              assert(SOURCE_EXECUTED==nil,'Preflight executed a module')
            end
            check("_G.SOURCE_EXECUTED=true;return mod.require('src/missing')")
            check("_G.SOURCE_EXECUTED=true;return mod.require [[src/missing]]")
            check("return mod.require('src/helper')","_G.SOURCE_EXECUTED=true;return mod.require 'src/missing'")
            local p={native_ffi=false,read=function(path)
              if path=='mods/main.lua'then return "local h=mod.require [==[\\r\\nsrc/helper]==];return {value=h.value}" end
              if path=='mods/src/helper.lua'then return 'return {value=7}'end
            end}
            local entry={id='valid',dir='mods'}
            local spec={entry='main.lua',modules={'src/helper.lua'},defaults='defaults.cfg'}
            local snapshot=project.snapshot(p,entry,spec)
            local definition=project.instantiate(p,entry,snapshot,function()end)
            assert(definition.value==7)''')

    def test_legacy_whitespace_escape_preserves_compiler_semantics_without_copying(self):
        # Valid short LuaJIT paths can have arbitrarily long \z whitespace.
        # Lua 5.1 treats \z as a literal z; it must still refuse these long paths.
        source = br"mod.require('\z" + b' ' * (4 * 1024 * 1024) + b"src.helper')"
        for label, implementation in RUNTIMES:
            lua = self.runtime(implementation)
            lua.execute(b'''local compile=loadstring
              loadstring=function(text,...)assert(#text<=1000,'Copied a giant literal');return compile(text,...)end''')
            lua.globals()[b'_source']=source
            ok,path,allocated=lua.execute(b'''collectgarbage('collect')
              local before=collectgarbage('count');collectgarbage('stop')
              local ok,value=pcall(scanner,_source)
              local allocated=collectgarbage('count')-before;collectgarbage('restart')
              return ok,ok and value[1] or tostring(value),allocated''')
            with self.subTest(runtime=label):
                if label=='LuaJIT':
                    self.assertTrue(ok)
                    self.assertEqual(path,b'src/helper.lua')
                else:
                    self.assertFalse(ok)
                self.assertLess(allocated,256)

    def test_legacy_unicode_literal_spelling_retains_short_path(self):
        path=b'src/'+b'a'*120
        literal=''.join('\\u{%06x}' % byte for byte in path).encode()
        for label, implementation in RUNTIMES:
            lua=self.runtime(implementation)
            if label=='LuaJIT':
                self.assertEqual(self.scan(lua,b"mod.require('"+literal+b"')"),[path+b'.lua'])
            else:
                with self.assertRaises(Exception):
                    self.scan(lua,b"mod.require('"+literal+b"')")

    def test_large_portable_sources_do_not_retain_token_arrays(self):
        filler = b'x' * (4 * 1024 * 1024)
        cases = {
            'long literal': b'local text=[==[' + filler + b"]=]; not_closing ]==];mod.require('src/helper')",
            'short literal': b'local text="' + filler + b'";mod.require("src/helper")',
            'long comment': b'--[==[' + filler + b"]==];mod.require('src/helper')",
            'dense code': b'v=0;' * 1000000 + b"mod.require('src/helper')",
            'huge delimiter': b'--[' + b'=' * 65536 + b'[' + filler + b']' + b'=' * 65536
                + b"];mod.require('src/helper')",
        }
        reports = []
        for label, implementation in RUNTIMES:
            lua = self.runtime(implementation)
            # Unrelated literals and plain imports must never invoke a compiler.
            lua.execute(b"loadstring=function()error('Compiled a skipped literal')end")
            for name, source in cases.items():
                with self.subTest(runtime=label, case=name):
                    lua.globals()[b'_source'] = source
                    count, path, elapsed, allocated = lua.execute(b'''collectgarbage('collect')
                      local before=collectgarbage('count');collectgarbage('stop')
                      local started=os.clock();local result=scanner(_source)
                      local elapsed=os.clock()-started;local allocated=collectgarbage('count')-before
                      collectgarbage('restart');return #result,result[1],elapsed,allocated''')
                    self.assertEqual((count, path), (1, b'src/helper.lua'))
                    self.assertLess(allocated, 256)
                    self.assertLess(elapsed, 5.0)
                    reports.append(dict(runtime=label, case=name, bytes=len(source), cpu_seconds=elapsed,
                                        temporary_kb=allocated))
            # A real giant import is refused before any copying/decoding.
            with self.assertRaises(Exception):
                self.scan(lua, b"mod.require('" + filler + b"')")
        print(json.dumps(reports, indent=2))


if __name__ == '__main__':
    unittest.main()
