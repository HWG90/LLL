from pathlib import Path
import json,re,sys,unittest
from lupa import lua51
ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'tools'))
class CffiLoader(unittest.TestCase):
    def setUp(self):
        self.lua=lua51.LuaRuntime(unpack_returned_tuples=True)
        self.lua.globals().source=(ROOT/'src/steam/cffi.lua').read_text()
        self.lua.execute('''local calls=0
          package={loaded={},loadlib=function()calls=calls+1;error('unexpected native load')end}
          factory=assert(loadstring(source))();config={path='C:/test/hd2_cffi.dll'}
          function call_count()return calls end''')
    def test_disabled_does_not_attempt_loading(self):
        self.lua.execute("local s=factory.open();assert(not s.available and s.reason=='not configured' and call_count()==0)")
    def test_loader_and_entry_failures_are_contained(self):
        self.lua.execute('''local s=factory.open(config);assert(not s.available and s.reason:find('unexpected native load'))
          package.loadlib=function()return nil,'signature rejection fixture' end
          s=factory.open(config);assert(not s.available and s.reason=='signature rejection fixture')
          package.loadlib=function()return function()error('fixture entry failure')end end
          s=factory.open(config);assert(not s.available and s.reason:find('fixture entry failure'))
          package.loadlib=function()return function()return nil end end
          s=factory.open(config);assert(not s.available and s.reason:find('validated module'))
          assert(package.loaded.cffi==nil and package.loaded.ffi==nil)''')
    def test_success_registers_cffi_without_claiming_luajit(self):
        self.lua.execute('''local module={};for _,n in ipairs({'cdef','load','typeof','new','cast','tonumber'})do module[n]=function()end end
          package.loadlib=function(path,entry)assert(path==config.path and entry=='luaopen_hd2_cffi');return function()return module end end
          local s=factory.open(config);assert(s.available and s.module_name=='cffi' and not s.legacy_ffi_alias)
          assert(package.loaded.cffi==module and package.loaded.ffi==nil and jit==nil)
          local again=factory.open(config);assert(not again.available and package.loaded.cffi==module)''')
    def test_invalid_paths_and_incomplete_module(self):
        self.lua.execute('''for _,path in ipairs({'',string.rep('a',32761),'a\\0b',12})do
            local s=factory.open({path=path});assert(not s.available and s.reason=='invalid cffi module path')end
          package.loadlib=function()return function()return {cdef=function()end}end end
          local s=factory.open(config);assert(not s.available and s.reason:find('incomplete cffi module') and not package.loaded.cffi)''')
    def test_missing_package_api(self):
        self.lua.execute("package=nil;local s=factory.open(config);assert(not s.available and s.reason=='package.loadlib unavailable')")
    def test_build_profile_and_native_helper_match(self):
        from build_steam_probe import GAME,STOCK_STARTUP_SHA256
        profile=json.loads((ROOT/'steam-build.json').read_text())
        native=(ROOT/'native/steam_files.c').read_text()
        self.assertEqual(profile['build_id'],'26088801')
        self.assertEqual(GAME,profile['game'])
        self.assertEqual(STOCK_STARTUP_SHA256,profile['stock_startup_sha256'])
        for h in GAME.values():self.assertIn('"'+h+'"',native)
if __name__=='__main__':unittest.main()
