"""Run the maintained portable contracts in Lua 5.1, plus the Steam assembly."""
from pathlib import Path
import os
import struct
import sys
import unittest

from lupa import lua51

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tools'))
from build_steam_release import source
from lua51_chunk import convert
from archive import hash_name, write


class SteamRuntime(unittest.TestCase):
    def setUp(self):
        self.previous = Path.cwd()
        os.chdir(ROOT)
        self.lua = lua51.LuaRuntime(encoding=None)

    def tearDown(self):
        os.chdir(self.previous)

    def test_portable_contracts_in_actual_lua51(self):
        contracts = ['after_startup','config','desktop_layout','diagnostics','health','input_restore',
                     'interaction','layout_layer','live','main_font','management','metadata_sidecar',
                     'poll_cache','poll_catalog','poll_log_reader','project','provenance','resize','ui_refresh']
        for name in contracts:
            with self.subTest(contract=name):
                runtime=lua51.LuaRuntime(encoding=None)
                runtime.execute((ROOT / ('tests/' + name + '_contracts.lua')).read_bytes())

    def test_complete_compiled_steam_startup_and_lifecycle(self):
        lua = self.lua
        lua.execute(b'''clock=0;stock_calls=0;stock_updates=0;stock_shutdown=0;enabled=0;disabled=0;ticks=0
            print=function()end
            stingray={Application={can_get=function()return false end},Window={has_focus=function()return true end},
              Keyboard={button_id=function()return nil end},Mouse={button_id=function()return nil end,axis_id=function()return nil end}}
            smoke_source="return {live_lua_api=1,on_enable=function()enabled=enabled+1 end,on_update=function()ticks=ticks+1 end,on_disable=function()disabled=disabled+1;return true end}"''')
        platform = '''return {data="data",live="live",settings="settings",loader_config="config",revision="Steam-fixture",runtime="Lua 5.1",native_ffi=false,
          hash=function()return "unused" end,now=function()return clock end,
          guard=function()return {supported=true,jit_supported=false}end,
          open_log=function()end,files=function(path)if path=="live" then return {"smoke.lua"}end;return {}end,
          read=function(path)if path=="live/smoke.lua"then return smoke_source end end,
          write=function()return true end}'''
        stock = b'''stock_calls=stock_calls+1
          update=function(...)stock_updates=stock_updates+1;return ... end
          shutdown=function(...)stock_shutdown=stock_shutdown+1;return ... end
          return "stock",nil,42,nil'''
        assembled = source(struct.pack('<II',len(stock),1)+stock,'fixture_pipe',platform)
        compiled = lua.eval(b'string.dump(assert(loadstring(...)))',assembled)
        final = convert(convert(compiled,4),8)
        self.assertEqual(lua.eval(b'assert(loadstring(...))()',final),(b'stock',None,42,None))
        self.assertEqual(lua.eval(b'stock_calls'),1)
        self.assertEqual(lua.eval(b'LiveLuaLoader.modules["live/smoke"]'),b'loaded')
        self.assertFalse(lua.eval(b'LiveLuaLoader.capabilities.native_ffi'))
        self.assertEqual(lua.eval(b'LiveLuaLoader.capabilities.runtime'),b'Lua 5.1')
        self.assertEqual(lua.eval(b'update(0.01,nil,9,nil)'),(0.01,None,9,None))
        self.assertEqual(lua.eval(b'ticks'),1)
        self.assertTrue(lua.eval(b'LiveLuaLoader.reload("live/smoke")')[0])
        self.assertEqual(lua.eval(b'enabled'),2)
        self.assertEqual(lua.eval(b'disabled'),1)
        result=lua.eval(b'LiveLuaLoader.set_enabled("live/smoke",false)')
        self.assertTrue(result[0] if isinstance(result,tuple) else result)
        self.assertEqual(lua.eval(b'disabled'),2)
        self.assertEqual(lua.eval(b'shutdown("end",nil)'),(b'end',None))
        self.assertEqual(lua.eval(b'stock_shutdown'),1)

    def test_archive_catalog_under_lua51(self):
        name=b'mods/test/steam'
        body=b'-- HD2-Addon: '+name+b'\nreturn true'
        packed=write({hash_name(name.decode()):struct.pack('<II',len(body),1)+body})
        lua=self.lua
        lua.globals()[b'_archive']=packed
        lua.globals()[b'_hash']=lambda value:('%016x' % hash_name(value.decode())).encode()
        lua.execute(b'''local discover=assert(loadstring(...))()
          local names,warnings=discover({data='data',hash=function(value)return _hash(value)end,
             files=function()return {'9ba626afa44a3aa3.patch_0'}end,read=function()return _archive end})
          assert(#warnings==0 and #names==1 and names[1]=='mods/test/steam')''',(ROOT/'src/discovery.lua').read_bytes())

    def test_source_notifications_skip_idle_stats_and_preserve_discovery(self):
        self.lua.execute(b'''local files={['mods/one.lua']='return 1'}
          local changed,reads,stats,listings=false,0,0,0
          local p={live='mods',source_notifications=true,
            changed=function()local result=changed;changed=false;return result end,
            files=function()listings=listings+1;local names={};for name in pairs(files)do names[#names+1]=name:sub(6)end;return names end,
            read=function(path)reads=reads+1;return files[path]end,
            stat=function(path)stats=stats+1;return files[path]end}
          local live=dofile('src/live.lua')(p,function()end);live.scan()
          assert(live.fingerprint('live/one')=='return 1')
          local r,s,l=reads,stats,listings
          for i=1,100 do live.scan();assert(live.fingerprint('live/one')=='return 1')end
          assert(reads==r and stats==s and listings==l,'Idle loose scripts performed filesystem work')
          files['mods/one.lua']='return 2';files['mods/two.lua']='return 3';changed=true
          assert(live.fingerprint('live/one')=='return 2','Direct fingerprint missed notification')
          live.scan();assert(live.catalog['live/two'],'Fingerprint consumed catalog notification')
          assert(live.fingerprint('live/one')=='return 2')
          r,s=reads,stats
          assert(live.fingerprint('live/one',true)=='return 2' and reads>r and stats>s,'Forced confirmation skipped reads')
          files['mods/one.lua']='return 4';changed=true;live.scan()
          assert(live.fingerprint('live/one')=='return 4','Catalog scan missed source invalidation')
          files['mods/one.lua']=nil;changed=true;live.scan();assert(not live.catalog['live/one'])''')

    def test_native_dependencies_refused_before_any_execution(self):
        self.lua.execute(b'''local project=dofile('src/project.lua')
          local steam={native_ffi=false}
          for _,text in ipairs({"side_effect();local f=require('ffi')", "return require 'bit'", "require([[jit]])", "_G.require('ffi')"})do
            local ok,why=pcall(project.check_runtime,steam,text,'test.lua')
            assert(not ok and why:find('Unsupported runtime',1,true))
          end
          project.check_runtime(steam,"-- require('ffi')\\nlocal example=\\\"require('bit')\\\"",'documentation.lua')
          project.check_runtime(steam,"return mod.require('ffi')",'private-module.lua')
          project.check_runtime({native_ffi=true},"require('ffi')",'legacy.lua')
          local file="_G.executed=true;_G.require('ffi');return {}"
          local live=dofile('src/live.lua')({native_ffi=false,live='mods',
            files=function()return {'native.lua'}end,read=function(path)if path=='mods/native.lua'then return file end end},function()end)
          live.scan()
          local ok,why=pcall(live.load,'live/native')
          assert(not ok and why:find('Unsupported runtime',1,true) and not executed)''')

    def test_engine_cursor_ownership_and_retry(self):
        self.lua.execute(b'''focus=true;cursor=false;clip=false;refuse=false
          window={mouse_focus=function()return focus end,show_cursor=function()return cursor end,clip_cursor=function()return clip end,
          set_mouse_focus=function(v)if refuse then return false end;focus=v end,
          set_show_cursor=function(v)cursor=v end,set_clip_cursor=function(v)clip=v end}
          capture=assert(loadstring(...))().new(nil,window,function()end)''',(ROOT/'src/steam/capture.lua').read_bytes())
        lua=self.lua
        self.assertTrue(lua.eval(b'capture.sync(true,true)'))
        self.assertFalse(lua.eval(b'focus'))
        lua.execute(b'refuse=true')
        self.assertFalse(lua.eval(b'capture.release()')[0])
        self.assertTrue(lua.eval(b'capture.status().pending_restore'))
        self.assertFalse(lua.eval(b'capture.sync(true,true)')[0])
        lua.execute(b'refuse=false')
        self.assertTrue(lua.eval(b'capture.release()'))
        self.assertTrue(lua.eval(b'focus and not cursor and not clip'))
        lua.execute(b'token=capture.acquire("other")')
        self.assertFalse(lua.eval(b'capture.release()')[0])
        self.assertFalse(lua.eval(b'capture.sync(true,true)')[0])
        self.assertTrue(lua.eval(b'capture.release(token)'))


if __name__ == '__main__':
    unittest.main()
