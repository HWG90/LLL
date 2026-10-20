"""End-to-end external service / standard Lua 5.1 pipe integration, outside game."""
from pathlib import Path
import ctypes
import os
import secrets
import struct
import subprocess
import sys
import tempfile
import time
import unittest

from lupa import lua51

ROOT=Path(__file__).resolve().parents[1]
SERVICE=Path(os.environ.get('LLL_TEST_STEAM_SERVICE',str(ROOT/'dist/reviews/current-steam-recovery/service-candidate')))
GAME=Path(r'C:\Program Files (x86)\Steam\steamapps\common\Helldivers 2_steam')


class ServiceIntegration(unittest.TestCase):
    def test_standard_lua_io_and_real_windows_filesystem(self):
        service=SERVICE/(SERVICE/'service.txt').read_text().strip()
        pipe='lll_steam_test_'+secrets.token_hex(12)
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary)
            environment=os.environ.copy();environment['LOCALAPPDATA']=temporary
            child=subprocess.Popen([str(service),'--game',str(GAME),'--pipe',pipe],env=environment,creationflags=subprocess.CREATE_NO_WINDOW)
            try:
                deadline=time.monotonic()+8
                name='\\\\.\\pipe\\'+pipe+'_request'
                while not ctypes.windll.kernel32.WaitNamedPipeW(name,100):
                    if child.poll() is not None: self.fail('Service exited before connection')
                    if time.monotonic()>deadline: self.fail('Service startup timeout')
                    time.sleep(.02)
                lua=lua51.LuaRuntime(encoding=None)
                lua.globals()[b'LLL_STEAM_TRANSPORT']=lua.execute((ROOT/'src/steam/transport.lua').read_bytes())
                lua.execute(b'''local create=LLL_STEAM_TRANSPORT
                  LLL_STEAM_TRANSPORT=function(config)
                    local transport=create(config);_test_exchange=transport.exchange;return transport
                  end''')
                lua.globals()[b'LLL_STEAM_SERVICE']=lua.table_from({b'pipe':pipe.encode()})
                lua.globals()[b'_local']=temporary.encode()
                lua.globals()[b'_pid']=os.getpid()
                lua.execute(b'''local prior=os.getenv
                  os.getenv=function(key)if key=='LOCALAPPDATA'then return _local end;return prior(key)end
                  clock=0;stingray={Application={process_id=function()return _pid end,time_since_launch=function()return clock end}}''')
                lua.globals()[b'LLL_STEAM_BUILDS']=lua.table_from({b'exe_sha256':b'fixture',b'game_sha256':b'fixture'})
                lua.globals()[b'P']=lua.execute((ROOT/'src/steam/platform.lua').read_bytes())
                self.assertTrue(lua.eval(b'P.guard().supported'))
                self.assertEqual(lua.eval(b'P.hash("core/wwise/lua/wwise_flow_callbacks")'),b'7251fdd9bb62480a')
                directory=root/'samples';directory.mkdir()
                path=directory/'normal.lua'
                lua.globals()[b'_path']=str(path).encode();lua.globals()[b'_directory']=str(directory).encode()
                self.assertTrue(lua.eval(b'P.changed(_directory)'))
                self.assertTrue(lua.eval(b'P.write(_path,"return 1")'))
                self.assertEqual(lua.eval(b'P.read(_path)'),b'return 1')
                self.assertIsInstance(lua.eval(b'P.stat(_path)'),bytes)
                lua.execute(b'''local files,stamps,dirs=P.files(_directory,'*.lua')
                    assert(#files==1 and files[1]=='normal.lua' and stamps[files[1]] and #dirs==0)''')
                deadline=time.monotonic()+2
                changed=False
                while time.monotonic()<deadline:
                    lua.execute(b'clock=clock+.5')
                    if lua.eval(b'P.changed(_directory)'): changed=True;break
                    time.sleep(.01)
                self.assertTrue(changed)
                # Windows can deliver the write and rename as separate events.
                # Wait for that known transition to settle before testing idle.
                quiet=time.monotonic();deadline=quiet+2
                while time.monotonic()-quiet<.1 and time.monotonic()<deadline:
                    time.sleep(.01);lua.execute(b'clock=clock+.5')
                    if lua.eval(b'P.changed(_directory)'): quiet=time.monotonic()
                self.assertLess(time.monotonic()-quiet,.5)
                reply_path=root/'LLL/Helldivers2/Steam/response.bin'
                request_path=reply_path.with_name('request.bin')
                # Stat is a frequent metadata check. Both successful and
                # missing Unicode paths must use the in-memory pipe response,
                # leaving the old request/reply transport files untouched.
                unicode_path=root/'metadata-\u03a9-\U0001f680.bin'
                unicode_path.write_bytes(b'Unicode metadata fixture')
                lua.globals()[b'_unicode_path']=str(unicode_path).encode('utf-8')
                lua.globals()[b'_missing_unicode_path']=str(unicode_path.with_name('missing-\u03a9-\U0001f680.bin')).encode('utf-8')
                protocol_before={path:(path.stat().st_mtime_ns,path.read_bytes())
                                 for path in (request_path,reply_path)}
                unicode_stamp=lua.eval(b'P.stat(_unicode_path)')
                self.assertIsInstance(unicode_stamp,bytes)
                self.assertEqual(int(unicode_stamp.split(b':',1)[0],16),unicode_path.stat().st_size)
                self.assertIsNone(lua.eval(b'P.stat(_missing_unicode_path)'))
                # Enumeration uses the same wire records and Lua filtering,
                # including Unicode names, directory flags and identity stamps.
                listing_directory=root/'listing-\u03a9-\U0001f680';listing_directory.mkdir()
                listing_name='file-\u03a9-\U0001f680.lua'
                (listing_directory/listing_name).write_bytes(b'return "Unicode listing"')
                (listing_directory/'note.txt').write_bytes(b'filtered')
                empty_directory=listing_directory/'folder-\u03a9-\U0001f680';empty_directory.mkdir()
                growth_directory=root/'larger-listing';growth_directory.mkdir()
                for index in range(160):
                    (growth_directory/f'entry-{index:03}-\u03a9.lua').write_bytes(b'return 1')
                lua.globals()[b'_listing_directory']=str(listing_directory).encode('utf-8')
                lua.globals()[b'_listing_name']=listing_name.encode('utf-8')
                lua.globals()[b'_listing_file']=str(listing_directory/listing_name).encode('utf-8')
                lua.globals()[b'_listing_folder']=empty_directory.name.encode('utf-8')
                lua.globals()[b'_empty_directory']=str(empty_directory).encode('utf-8')
                lua.globals()[b'_growth_directory']=str(growth_directory).encode('utf-8')
                missing_directory=listing_directory/'missing-\u03a9-\U0001f680'
                lua.globals()[b'_missing_directory']=str(missing_directory).encode('utf-8')
                lua.execute(b'''local files,stamps,dirs=P.files(_listing_directory,'*.lua')
                  assert(#files==1 and files[1]==_listing_name and stamps[_listing_name]==P.stat(_listing_file))
                  assert(#dirs==1 and dirs[1]==_listing_folder)
                  local all=P.files(_listing_directory);assert(#all==2)
                  local files,stamps,dirs,status=P.files(_empty_directory)
                  assert(#files==0 and next(stamps)==nil and #dirs==0 and status==0)
                  local files,stamps,dirs,status=P.files(_missing_directory)
                  assert(#files==0 and next(stamps)==nil and #dirs==0 and status==3)
                  local files,stamps,dirs=P.files(_growth_directory,'*.lua')
                  assert(#files==160 and stamps[files[1]] and #dirs==0)''')
                for nonce,encoded_path,expected_status in (
                    (0x60000001,str(empty_directory).encode('utf-8'),0),
                    (0x60000002,str(missing_directory).encode('utf-8'),3),
                    (0x60000003,b'\xff',13),
                    (0x60000004,b'',13),
                ):
                    lua.globals()[b'_listing_packet']=struct.pack('<III',nonce,1,len(encoded_path))+encoded_path
                    reply=lua.eval(b'_test_exchange(_listing_packet)')
                    self.assertEqual(reply,struct.pack('<II',nonce,expected_status))
                for protocol_path,before in protocol_before.items():
                    self.assertEqual((protocol_path.stat().st_mtime_ns,protocol_path.read_bytes()),before,
                                     'Stat and success/missing/Unicode/empty listing must not rewrite protocol files')
                stamp=reply_path.stat().st_mtime_ns
                for _ in range(100):
                    lua.execute(b'clock=clock+.5')
                    self.assertFalse(lua.eval(b'P.changed(_directory)'))
                self.assertEqual(reply_path.stat().st_mtime_ns,stamp,
                                 'Idle pipe notifications must not rewrite protocol files')
                self.assertFalse((root/'LLL/Helldivers2/Steam/events.bin').exists())
                # Read-only listings stay quiet, but a real external write
                # still invalidates the watched directory and updates listing.
                (directory/'after-listing.lua').write_bytes(b'return 2')
                deadline=time.monotonic()+2;changed=False
                while time.monotonic()<deadline:
                    lua.execute(b'clock=clock+.5')
                    if lua.eval(b'P.changed(_directory)'): changed=True;break
                    time.sleep(.01)
                self.assertTrue(changed,'Real writes must still deliver directory notifications')
                lua.execute(b'''local files,stamps=P.files(_directory,'*.lua')
                  assert(#files==2 and stamps['after-listing.lua'])''')
                foreground_pid=ctypes.c_ulong()
                ctypes.windll.user32.GetForegroundWindow.restype=ctypes.c_void_p
                foreground=ctypes.windll.user32.GetForegroundWindow()
                ctypes.windll.user32.GetWindowThreadProcessId(ctypes.c_void_p(foreground),ctypes.byref(foreground_pid))
                self.assertNotEqual(foreground_pid.value,os.getpid(),
                                    'The noninteractive integration client must not own the foreground')
                for cycle in range(3):
                    # Versioned operation12 adds signed raw dx/dy without
                    # changing operation10's legacy seven-integer payload.
                    for operation,fields in ((10,7),(12,9)):
                        nonce=0x70000000+cycle*100+operation
                        lua.globals()[b'_pointer_packet']=struct.pack('<III',nonce,operation,7)+b'pointer'
                        reply=lua.eval(b'_test_exchange(_pointer_packet)')
                        self.assertEqual(len(reply),8+fields*4)
                        self.assertEqual(struct.unpack_from('<II',reply),(nonce,0))
                        self.assertEqual(struct.unpack_from('<'+'i'*fields,reply,8),(0,)*fields,
                                         'Foreign foreground must suppress all pointer and raw motion data')
                    lua.execute(b'''local p=P.pointer_snapshot()
                      assert(type(p.valid)=='boolean' and type(p.x)=='number' and type(p.buttons)=='number')
                      if not p.valid then assert(p.x==0 and p.y==0 and p.buttons==0 and p.wheel==0)end''')
                    lua.execute(b'''local p=P.camera_snapshot()
                      assert(type(p.valid)=='boolean' and type(p.dx)=='number' and type(p.dy)=='number')
                      if not p.valid then assert(p.x==0 and p.y==0 and p.buttons==0 and p.wheel==0 and p.dx==0 and p.dy==0)end''')
                    self.assertTrue(lua.eval(b'P.release_pointer()'))
                for protocol_path,before in protocol_before.items():
                    self.assertEqual((protocol_path.stat().st_mtime_ns,protocol_path.read_bytes()),before,
                                     'Pointer and relative snapshots must stay in memory')
                self.assertTrue(lua.eval(b'P.unwatch(_directory)'))
                lua.execute(b'P.close_watches();P=nil;_test_exchange=nil;collectgarbage("collect");collectgarbage("collect")')
                del lua
                child.wait(timeout=5)
                self.assertEqual(child.returncode,0)
            finally:
                if child.poll() is None:
                    child.terminate();child.wait(timeout=5)


if __name__=='__main__':unittest.main()
