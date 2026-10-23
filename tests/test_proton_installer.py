from pathlib import Path
import importlib.util,json,tempfile,unittest
from unittest.mock import patch
spec=importlib.util.spec_from_file_location('installer',Path(__file__).resolve().parents[1]/'tools/install_proton_preview.py')
m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
class ProtonInstaller(unittest.TestCase):
 def setUp(self):
  self.tmp=tempfile.TemporaryDirectory();self.addCleanup(self.tmp.cleanup)
  root=Path(self.tmp.name);self.game=root/'game';self.package=root/'package';self.prefix=root/'pfx'
  (self.prefix/'drive_c/users/steamuser').mkdir(parents=True);(self.prefix/'dosdevices').mkdir();(self.prefix/'dosdevices/z:').symlink_to('/')
  self.home=m.local_home(self.prefix);game={}
  for key in ['bin/helldivers2.exe','data/game/game.dll']:
   p=self.game/key;p.parent.mkdir(parents=True,exist_ok=True);p.write_bytes(key.encode());game[key]=m.digest(p)
  helper=b'helper fixture';self.helper='lll_steam_service_'+m.SHA(helper)[:16]+'.exe'
  payload={'data/'+m.PATCH:b'new startup','data/'+m.PATCH+'.stream':b'','data/'+m.PATCH+'.gpu_resources':b'','service/'+self.helper:helper}
  for key,value in payload.items():
   p=self.package/key;p.parent.mkdir(parents=True,exist_ok=True);p.write_bytes(value)
  self.info={'format':'LLL-Steam-portable-v1','release':'test','game':game,'service':self.helper,'payloads':{k:m.SHA(v) for k,v in payload.items()},'known_lll_patch_sha256':[m.SHA(b'old startup')]}
  (self.package/'package.json').write_text(json.dumps(self.info))
  (self.game/'data'/m.PATCH).write_bytes(b'old startup')
 def test_install_idempotence_and_exact_rollback(self):
  with patch.object(m,'assert_closed'):
   result=m.install(self.package,self.game,self.prefix)
   self.assertEqual((self.game/'data'/m.PATCH).read_bytes(),b'new startup')
   self.assertIn('already installed',m.install(self.package,self.game,self.prefix)['state'])
   m.rollback(result['receipt'])
   self.assertEqual((self.game/'data'/m.PATCH).read_bytes(),b'old startup')
   self.assertFalse((self.home/'Service'/self.helper).exists())
 def test_changed_installed_content_refuses_rollback(self):
  with patch.object(m,'assert_closed'):
   result=m.install(self.package,self.game,self.prefix)
   (self.game/'data'/m.PATCH).write_bytes(b'user edit')
   with self.assertRaisesRegex(ValueError,'changed'):m.rollback(result['receipt'])
   self.assertEqual((self.game/'data'/m.PATCH).read_bytes(),b'user edit')
 def test_collision_refuses_before_any_write(self):
  p=self.home/'Service'/self.helper;p.parent.mkdir(parents=True);p.write_bytes(b'wrong helper')
  with self.assertRaisesRegex(ValueError,'content-addressed'):m.validate(self.package,self.game,self.home)
  self.assertEqual((self.game/'data'/m.PATCH).read_bytes(),b'old startup')
 def test_wrong_game_refuses(self):
  (self.game/'bin/helldivers2.exe').write_bytes(b'other build')
  with self.assertRaisesRegex(ValueError,'Unsupported game'):m.validate(self.package,self.game,self.home)
if __name__=='__main__':unittest.main()
