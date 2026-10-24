"""Current-build HUD resources and unavailable native-module fallback."""
from pathlib import Path
import struct, unittest
from lupa import lua51
ROOT=Path(__file__).resolve().parents[1]
class SteamFont(unittest.TestCase):
 def test_current_resources_and_build_refusal(self):
  lua=lua51.LuaRuntime(encoding=None,unpack_returned_tuples=True)
  module=lua.execute((ROOT/'src/steam/font.lua').read_bytes())
  base=0x180000000;owner=0x300000000;pe=0x100
  fields={60:pe,pe:0x4550,pe+8:0x6AD7C05D,pe+80:0x3382000,pe+88:0x2ED14F0}
  regions={base+k:struct.pack('<I',v) for k,v in fields.items()}
  regions.update({base+0x312D998:bytes.fromhex('0102030405060708'),base+0x312E618:bytes.fromhex('1122334455667788'),base+0x3180C08:struct.pack('<Q',owner),owner+24:bytes.fromhex('aabbccddeeff1234')})
  lua.globals().reader=lambda a,n:regions.get(int(a),b'')[:int(n)]
  lua.execute(b"memory={address=function(x)return x end,read=function(a,n)return reader(a,n)end};accept=true;sr={IdString64={from_hex=function(x)return x end},Application={can_get=function()return accept end}}")
  resolver=module[b'new'](lua.globals().memory,base,None)
  result=resolver[b'resolve'](lua.globals().sr)
  self.assertEqual((result[b'font'],result[b'atlas'],result[b'material']),(b'0807060504030201',b'8877665544332211',b'3412ffeeddccbbaa'))
  regions[base+pe+8]=struct.pack('<I',0x6AB3B43F)
  self.assertIsNone(resolver[b'resolve'](lua.globals().sr))
  regions[base+pe+8]=struct.pack('<I',0x6AD7C05D);lua.globals().accept=False
  self.assertIsNone(resolver[b'resolve'](lua.globals().sr))
  lua.globals().accept=True;regions[base+0x3180C08]=bytes(8)
  self.assertIsNone(resolver[b'resolve'](lua.globals().sr))
 def test_unavailable_native_module_keeps_fallback(self):
  lua=lua51.LuaRuntime(encoding=None)
  lua.execute(b"package.loadlib=function()return nil,'native loader refused' end;os.getenv=function()return 'C:/fixture' end")
  module=lua.execute((ROOT/'src/steam/font.lua').read_bytes())
  self.assertIsNone(module[b'new']()[b'resolve'](None))
if __name__=='__main__':unittest.main()
