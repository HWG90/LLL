"""Execute the distributed installer against owned temporary game/package roots."""
from pathlib import Path
import base64
import ctypes
import hashlib
import json
import os
import subprocess
import sys
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[1]
SHA=lambda value:hashlib.sha256(value).hexdigest()
PATCH='9ba626afa44a3aa3.patch_0'
sys.path.insert(0,str(ROOT/'tools'))
from archive import write as write_archive


class Installer(unittest.TestCase):
    def setUp(self):
        self.temporary=tempfile.TemporaryDirectory(prefix="lll installer Dave's ")
        self.addCleanup(self.temporary.cleanup)
        self.root=Path(self.temporary.name)
        self.game=self.root/"game spaces and apostrophe's \u0394\u8230"
        self.package=self.root/'package';self.home=self.root/'local'
        self.base=self.home/'LLL/Helldivers2'
        for path in (self.game/'bin',self.game/'data/game',self.package/'data',self.package/'service',self.base/'Settings',self.base/'Mods'):
            path.mkdir(parents=True)
        (self.game/'bin/helldivers2.exe').write_bytes(b'owned fake game exe')
        (self.game/'data/game/game.dll').write_bytes(b'owned fake game dll')
        self.config=b'return {manager_ui={menu_toggle_key=45}}\r\n'
        (self.base/'LLL.cfg').write_bytes(self.config)
        (self.base/'Settings/keep.cfg').write_bytes(b'keep settings')
        (self.base/'Mods/keep.lua').write_bytes(b'keep mod')
        (self.package/'Install.ps1').write_bytes((ROOT/'tools/install_steam_preview.ps1').read_bytes())
        self.env=os.environ.copy();self.env['LOCALAPPDATA']=str(self.home)
        self.make_package()

    def make_package(self,version=1,known=()):
        helper=b'owned fake helper';name='lll_steam_service_'+SHA(helper)[:16]+'.exe'
        payloads={'data/'+PATCH:b'owned LLL fixture '+str(version).encode(),
                  'data/'+PATCH+'.stream':b'','data/'+PATCH+'.gpu_resources':b'',
                  'service/'+name:helper}
        for path,value in payloads.items():(self.package/path).write_bytes(value)
        self.manifest={'format':'LLL-Steam-portable-v1','release':'preview.'+str(version),
          'game':{path:SHA((self.game/path).read_bytes())for path in ('bin/helldivers2.exe','data/game/game.dll')},
          'service':name,'known_lll_patch_sha256':list(known),
          'payloads':{path:SHA(value)for path,value in payloads.items()}}
        (self.package/'package.json').write_text(json.dumps(self.manifest))
        return payloads

    def run_installer(self,receipt=None,running=False,helper=False):
        # Override process enumeration inside this child only: the real game and
        # its installation are never consulted or targeted by these fixtures.
        quote=lambda value:"'"+str(value).replace("'","''")+"'"
        script="function global:Get-Process { [CmdletBinding()]param([string[]]$Name) "
        if running:script+="if ($Name -contains 'helldivers2') {return [pscustomobject]@{Name='helldivers2';Id=1}}; "
        if helper:script+="if ($Name -contains 'lll_steam_service_*') {return [pscustomobject]@{Name='lll_steam_service_1111111111111111';Id=2}}; "
        script+='return'
        script+=' }; & '+quote(self.package/'Install.ps1')
        script+=(' -Rollback '+quote(receipt))if receipt else(' -GamePath '+quote(self.game))
        return subprocess.run(['powershell.exe','-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass',
          '-EncodedCommand',base64.b64encode(script.encode('utf-16-le')).decode()],
          env=self.env,capture_output=True,text=True,timeout=20,creationflags=subprocess.CREATE_NO_WINDOW)

    def receipts(self):return sorted((self.base/'Backups').glob('*/receipt.json'))

    def assert_saved(self):
        self.assertEqual((self.base/'LLL.cfg').read_bytes(),self.config)
        self.assertEqual((self.base/'Settings/keep.cfg').read_bytes(),b'keep settings')
        self.assertEqual((self.base/'Mods/keep.lua').read_bytes(),b'keep mod')

    def test_clean_install_binding_hash_receipt_and_exact_removal(self):
        self.assertFalse((self.base/'Logs').exists())
        result=self.run_installer();self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        self.assertTrue((self.base/'Logs').is_dir(),'First-launch failures need a log directory')
        (self.base/'Logs/keep.log').write_bytes(b'existing diagnostic')
        self.assertEqual((self.game/'data'/PATCH).read_bytes(),(self.package/'data'/PATCH).read_bytes())
        self.assertEqual((self.base/'Service/game-root.txt').read_bytes(),(str(self.game)+'\n').encode())
        receipt=self.receipts()[0];value=json.loads(receipt.read_text(encoding='utf-8-sig'))
        self.assertEqual(value['state'],'installed bytes verified; saved settings preserved')
        self.assertEqual(len(value['files']),6)
        for row in value['files']:
            path=(self.game/'data'if row['group']=='data'else self.base/'Service')/row['name']
            self.assertEqual(SHA(path.read_bytes()),row['after'])
        self.assert_saved()
        again=self.run_installer();self.assertEqual(again.returncode,0,again.stdout+again.stderr)
        self.assertEqual(len(self.receipts()),1,'Identical reinstall created work')
        restored=self.run_installer(receipt);self.assertEqual(restored.returncode,0,restored.stdout+restored.stderr)
        self.assertFalse((self.game/'data'/PATCH).exists())
        self.assertFalse((self.base/'Service/game-root.txt').exists());self.assert_saved()
        self.assertEqual((self.base/'Logs/keep.log').read_bytes(),b'existing diagnostic')

    def test_owned_update_and_reverse_rollback_preserve_previous_payload(self):
        first=self.make_package(1)
        result=self.run_installer();self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        receipt1=self.receipts()[0]
        second=self.make_package(2)
        result=self.run_installer();self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        receipt2=next(path for path in self.receipts()if path!=receipt1)
        self.assertEqual((self.game/'data'/PATCH).read_bytes(),second['data/'+PATCH])
        result=self.run_installer(receipt2);self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        self.assertEqual((self.game/'data'/PATCH).read_bytes(),first['data/'+PATCH])
        result=self.run_installer(receipt1);self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        self.assertFalse((self.game/'data'/PATCH).exists());self.assert_saved()

    def test_known_lll_migration_restores_original_triplet(self):
        previous=b'previous reviewed LLL startup'
        (self.game/'data'/PATCH).write_bytes(previous)
        for suffix in ('.stream','.gpu_resources'):(self.game/'data'/(PATCH+suffix)).write_bytes(b'')
        self.make_package(known=(SHA(previous),))
        result=self.run_installer();self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        result=self.run_installer(self.receipts()[0]);self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        self.assertEqual((self.game/'data'/PATCH).read_bytes(),previous)
        self.assertTrue((self.game/'data'/(PATCH+'.stream')).exists());self.assert_saved()

    def test_unknown_startup_sidecars_corruption_running_game_and_wrong_build_refuse(self):
        cases=('unknown','sidecar','orphan','payload','running','game')
        for case in cases:
            with self.subTest(case=case):
                # Each refusal runs against a newly owned fixture and preserves
                # its startup bytes, rather than relying on the prior case.
                nested=Installer();nested.setUp()
                try:
                    data=nested.game/'data'
                    if case=='unknown':(data/PATCH).write_bytes(b'other startup owner')
                    if case=='sidecar':
                        (data/PATCH).write_bytes((nested.package/'data'/PATCH).read_bytes())
                        (data/(PATCH+'.stream')).write_bytes(b'other sidecar')
                    if case=='orphan':(data/(PATCH+'.stream')).write_bytes(b'')
                    if case=='payload':(nested.package/'data'/PATCH).write_bytes(b'tampered package')
                    if case=='game':(nested.game/'bin/helldivers2.exe').write_bytes(b'wrong build')
                    before={p.name:p.read_bytes()for p in data.glob(PATCH+'*')}
                    result=nested.run_installer(running=case=='running')
                    self.assertNotEqual(result.returncode,0,result.stdout+result.stderr)
                    self.assertEqual(before,{p.name:p.read_bytes()for p in data.glob(PATCH+'*')})
                    self.assertFalse((nested.base/'Service').exists());nested.assert_saved()
                finally:nested.doCleanups()

    def test_rollback_refuses_changed_owned_bytes_before_any_restoration(self):
        result=self.run_installer();self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        path=self.game/'data'/PATCH;path.write_bytes(b'foreign later update')
        before={p.name:p.read_bytes()for p in (self.base/'Service').iterdir()}
        result=self.run_installer(self.receipts()[0]);self.assertNotEqual(result.returncode,0)
        self.assertEqual(path.read_bytes(),b'foreign later update')
        self.assertEqual(before,{p.name:p.read_bytes()for p in (self.base/'Service').iterdir()});self.assert_saved()

    def test_partial_update_failure_rolls_back_already_replaced_startup(self):
        original=self.make_package(1);result=self.run_installer()
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        self.make_package(2)
        kernel=ctypes.WinDLL('kernel32',use_last_error=True)
        kernel.CreateFileW.argtypes=[ctypes.c_wchar_p,ctypes.c_ulong,ctypes.c_ulong,ctypes.c_void_p,ctypes.c_ulong,ctypes.c_ulong,ctypes.c_void_p]
        kernel.CreateFileW.restype=ctypes.c_void_p;kernel.CloseHandle.argtypes=[ctypes.c_void_p]
        # A readable owned fixture file denies replacement. Earlier startup
        # writes must be restored automatically when its marker write fails.
        handle=kernel.CreateFileW(str(self.base/'Service/installed-steam-preview.json'),0x80000000,1,None,3,128,None)
        self.assertNotEqual(handle,ctypes.c_void_p(-1).value)
        try:result=self.run_installer()
        finally:kernel.CloseHandle(handle)
        self.assertNotEqual(result.returncode,0)
        self.assertIn('changes rolled back',result.stderr+result.stdout)
        self.assertEqual((self.game/'data'/PATCH).read_bytes(),original['data/'+PATCH]);self.assert_saved()

    def test_competing_or_unverifiable_boot_slot_refuses_unrelated_slot_is_preserved(self):
        other=self.game/'data/9ba626afa44a3aa3.patch_7'
        for contents in (write_archive({0xf476df93691895fa:b'other boot'}),b'unverifiable archive'):
            with self.subTest(contents=contents[:16]):
                other.write_bytes(contents)
                result=self.run_installer();self.assertNotEqual(result.returncode,0,result.stdout+result.stderr)
                self.assertIn('Cannot install beside startup slot',result.stderr)
                self.assertEqual(other.read_bytes(),contents)
                self.assertFalse((self.game/'data'/PATCH).exists())
                self.assertFalse((self.base/'Service').exists())
        contents=write_archive({0x12345678:b'unrelated resource'});other.write_bytes(contents)
        result=self.run_installer();self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        result=self.run_installer(self.receipts()[0]);self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        self.assertEqual(other.read_bytes(),contents);self.assert_saved()

    def test_waiting_old_helper_refuses_new_pipe_update_without_changes(self):
        first=self.make_package(1);result=self.run_installer()
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        self.make_package(2)
        before={p.name:p.read_bytes()for p in (self.base/'Service').iterdir()}
        result=self.run_installer(helper=True)
        self.assertNotEqual(result.returncode,0);self.assertIn('waiting LLL Steam helper',result.stderr)
        self.assertEqual((self.game/'data'/PATCH).read_bytes(),first['data/'+PATCH])
        self.assertEqual(before,{p.name:p.read_bytes()for p in (self.base/'Service').iterdir()})
        self.assertEqual(len(self.receipts()),1);self.assert_saved()

    def test_exact_owned_removal_remains_available_after_stock_game_update(self):
        result=self.run_installer();self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        (self.game/'bin/helldivers2.exe').write_bytes(b'Steam advanced game')
        (self.game/'data/game/game.dll').write_bytes(b'Steam advanced dll')
        result=self.run_installer(self.receipts()[0]);self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        self.assertFalse((self.game/'data'/PATCH).exists())
        self.assertEqual((self.game/'bin/helldivers2.exe').read_bytes(),b'Steam advanced game')
        self.assertEqual((self.game/'data/game/game.dll').read_bytes(),b'Steam advanced dll');self.assert_saved()

    def test_one_active_game_root_refuses_rebinding_until_original_removed(self):
        result=self.run_installer();self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        receipt=self.receipts()[0];original=self.game
        self.game=self.root/'second supported game'
        for relative in ('bin/helldivers2.exe','data/game/game.dll'):
            target=self.game/relative;target.parent.mkdir(parents=True,exist_ok=True)
            target.write_bytes((original/relative).read_bytes())
        before=(self.base/'Service/game-root.txt').read_bytes()
        result=self.run_installer();self.assertNotEqual(result.returncode,0)
        self.assertIn('another game folder',result.stderr)
        self.assertFalse((self.game/'data'/PATCH).exists())
        self.assertEqual((self.base/'Service/game-root.txt').read_bytes(),before)
        result=self.run_installer(receipt);self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        result=self.run_installer();self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        self.assertEqual((self.base/'Service/game-root.txt').read_bytes(),(str(self.game)+'\n').encode());self.assert_saved()


if __name__=='__main__':unittest.main()
