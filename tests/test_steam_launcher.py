"""Hidden/event-driven startup with a GUI fixture and the actual external service.

Nothing is installed, no game process is opened, and all filesystem roots are
temporary. Fixture cases exercise startup failures and reuse; the actual service
case verifies Lua 5.1 auto launch, boot acknowledgement, filesystem IO and exit.
"""
from pathlib import Path
import base64
import ctypes
import hashlib
import json
import os
import secrets
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tools'))
import steam_launcher

FIXTURE = r'''
#define UNICODE
#define _UNICODE
#include <windows.h>
#include <shellapi.h>
#include <stdio.h>
#include <wchar.h>
int WINAPI wWinMain(HINSTANCE instance, HINSTANCE previous, PWSTR command, int show) {
    int count;
    LPWSTR *args=CommandLineToArgvW(GetCommandLineW(),&count);
    wchar_t path[32768],name[256];
    HANDLE ready,stop;
    FILE *file=NULL;
    (void)instance;(void)previous;(void)command;(void)show;
    if (!args || count!=5 || wcscmp(args[1],L"--game") || wcscmp(args[3],L"--pipe")) return 2;
    swprintf_s(path,32768,L"%s\\started.txt",args[2]);
    if (_wfopen_s(&file,path,L"ab")) return 3;
    fprintf(file,"%lu\n",GetCurrentProcessId());fclose(file);
    swprintf_s(name,256,L"Local\\LLL_Steam_Test_Stop_%s",args[4]);
    stop=CreateEventW(NULL,TRUE,FALSE,name);if (!stop) return 4;
    swprintf_s(name,256,L"Local\\LLL_Steam_Ready_%s",args[4]);
    ready=CreateEventW(NULL,TRUE,FALSE,name);if (!ready) return 5;
    if (wcsstr(args[2],L"exit_early")) return 6;
    Sleep(150);
    if (!wcsstr(args[2],L"no_signal")) SetEvent(ready);
    WaitForSingleObject(stop,20000);
    CloseHandle(ready);CloseHandle(stop);LocalFree(args);return 0;
}
'''


class Launcher(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix='lll-launch-test-')
        cls.build = Path(cls.temporary.name)
        source = cls.build / 'fixture.c'; source.write_text(FIXTURE)
        cls.exe = cls.build / 'fixture.exe'
        vc = Path(r'C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat')
        result = subprocess.run(f'call "{vc}" >nul && cl /nologo /O2 /GS /W4 /WX /MT "{source}" '
                                f'/Fo"{cls.build / "fixture.obj"}" /Fe"{cls.exe}" '
                                '/link /SUBSYSTEM:WINDOWS /DYNAMICBASE /NXCOMPAT /HIGHENTROPYVA kernel32.lib shell32.lib',
                                shell=True, cwd=cls.build, capture_output=True, text=True)
        if result.returncode:
            raise RuntimeError(result.stdout + result.stderr)
        cls.sha = hashlib.sha256(cls.exe.read_bytes()).hexdigest()
        cls.service_name = 'lll_steam_service_' + cls.sha[:16] + '.exe'
        cls.kernel = ctypes.WinDLL('kernel32', use_last_error=True)
        cls.kernel.OpenEventW.argtypes = [ctypes.c_ulong,ctypes.c_int,ctypes.c_wchar_p]
        cls.kernel.OpenEventW.restype = ctypes.c_void_p
        cls.kernel.SetEvent.argtypes = [ctypes.c_void_p]
        cls.kernel.CloseHandle.argtypes = [ctypes.c_void_p]

    @classmethod
    def tearDownClass(cls):
        cls.temporary.cleanup()

    def fixture(self, mode='game'):
        temporary = tempfile.TemporaryDirectory(prefix="lll launch Dave's ")
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name)
        home = root / 'LLL/Helldivers2/Service'; home.mkdir(parents=True)
        (home / self.service_name).write_bytes(self.exe.read_bytes())
        game = root / (mode + " spaces and apostrophe's"); game.mkdir()
        pipe = 'lll_steam_test_' + secrets.token_hex(12)
        env = os.environ.copy(); env['LOCALAPPDATA'] = str(root)
        self.addCleanup(self.stop, pipe, game)
        return root, game, pipe, env

    def stop(self, pipe, game):
        handle = self.kernel.OpenEventW(2,False,'Local\\LLL_Steam_Test_Stop_' + pipe)
        if handle:
            self.kernel.SetEvent(handle); self.kernel.CloseHandle(handle)
        started = game / 'started.txt'
        if started.exists():
            # Wait on owned fixture processes, never the game. This ensures its
            # image is closed before TemporaryDirectory removes the EXE.
            self.kernel.OpenProcess.argtypes = [ctypes.c_ulong,ctypes.c_int,ctypes.c_ulong]
            self.kernel.OpenProcess.restype = ctypes.c_void_p
            self.kernel.WaitForSingleObject.argtypes = [ctypes.c_void_p,ctypes.c_ulong]
            for pid in started.read_text().splitlines():
                process = self.kernel.OpenProcess(0x100000,False,int(pid))
                if process:
                    self.kernel.WaitForSingleObject(process,3000);self.kernel.CloseHandle(process)

    def launch(self, game, pipe, env, timeout_ms=8000):
        return subprocess.run(['powershell.exe','-NoLogo','-NoProfile','-NonInteractive','-WindowStyle','Hidden',
                               '-EncodedCommand',steam_launcher.encoded_command(self.service_name,self.sha,str(game),pipe,timeout_ms)],
                              env=env,capture_output=True,text=True,timeout=12,creationflags=subprocess.CREATE_NO_WINDOW)

    def test_encoded_literals_and_validation(self):
        encoded = steam_launcher.encoded_command(self.service_name,self.sha,"C:\\Dave's game\\",'lll_steam_test_01234567')
        self.assertEqual(base64.b64decode(encoded).decode('utf-16-le'),
                         steam_launcher.powershell(self.service_name,self.sha,"C:\\Dave's game\\",'lll_steam_test_01234567'))
        for invalid in ('../other.exe','lll_steam_service_changed.exe'):
            with self.assertRaises(ValueError): steam_launcher.command(invalid,self.sha,'C:\\game','lll_steam_test_01234567')
        with self.assertRaises(ValueError): steam_launcher.command(self.service_name,self.sha,'C:\\game','bad;token')
        with self.assertRaises(ValueError): steam_launcher.command(self.service_name,self.sha,'C:\\game','lll_steam_test_01234567',8001)

    def test_hidden_start_and_existing_ready_reuse(self):
        root,game,pipe,env = self.fixture()
        first = self.launch(game,pipe,env)
        self.assertEqual(first.returncode,0,first.stdout+first.stderr)
        self.assertEqual(first.stdout.strip(),'LLL_READY')
        second = self.launch(game,pipe,env)
        self.assertEqual(second.returncode,0,second.stdout+second.stderr)
        self.assertEqual(second.stdout.strip(),'LLL_READY')
        self.assertEqual(len((game/'started.txt').read_text().splitlines()),1)

    def test_changed_bytes_are_refused_before_launch(self):
        root,game,pipe,env = self.fixture()
        path = root/'LLL/Helldivers2/Service'/self.service_name
        path.write_bytes(path.read_bytes()+b'changed')
        result = self.launch(game,pipe,env)
        self.assertNotEqual(result.returncode,0)
        self.assertIn('service changed',result.stdout)
        self.assertFalse((game/'started.txt').exists())

    def test_early_exit_and_timeout_are_bounded(self):
        for mode,expected in [('exit_early','exited before readiness'),('no_signal','timed out')]:
            with self.subTest(mode=mode):
                root,game,pipe,env = self.fixture(mode)
                started = time.monotonic()
                result = self.launch(game,pipe,env,1200)
                self.assertNotEqual(result.returncode,0,result.stdout+result.stderr)
                self.assertIn(expected,result.stdout)
                self.assertLess(time.monotonic()-started,6)

    def test_lua_popen_close_does_not_wait_for_long_lived_child(self):
        root,game,pipe,env = self.fixture()
        env['LLL_LAUNCH_COMMAND'] = steam_launcher.command(self.service_name,self.sha,str(game),pipe)
        script = '''from lupa import lua51
import os
lua=lua51.LuaRuntime(encoding=None)
lua.globals()[b'command']=os.environ['LLL_LAUNCH_COMMAND'].encode()
lua.execute(b"local p=assert(io.popen(command,'r'));p:close()")
'''
        started = time.monotonic()
        result = subprocess.run([sys.executable,'-c',script],env=env,capture_output=True,text=True,timeout=12,
                                creationflags=subprocess.CREATE_NO_WINDOW)
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        self.assertLess(time.monotonic()-started,6)
        self.assertEqual(len((game/'started.txt').read_text().splitlines()),1)


class RealServiceStartup(unittest.TestCase):
    def test_actual_service_lua_cold_start_boot_filesystem_and_disconnect(self):
        directory = Path(os.environ.get('LLL_TEST_STEAM_SERVICE',
                         str(ROOT/'dist/reviews/current-steam-recovery/service-autostart')))
        service = directory/(directory/'service.txt').read_text().strip()
        value = service.read_bytes()
        sha = hashlib.sha256(value).hexdigest()
        self.assertEqual(service.name,'lll_steam_service_'+sha[:16]+'.exe')
        game = Path(r'C:\Program Files (x86)\Steam\steamapps\common\Helldivers 2_steam')
        pipe = 'lll_steam_test_'+secrets.token_hex(12)
        with tempfile.TemporaryDirectory(prefix="lll actual Dave's ") as temporary:
            root = Path(temporary)
            installed = root/'LLL/Helldivers2/Service'/service.name
            installed.parent.mkdir(parents=True);installed.write_bytes(value)
            fixture = root/'filesystem sample.txt';fixture.write_text('sample')
            environment = os.environ.copy()
            environment['LOCALAPPDATA'] = temporary
            environment['LLL_LAUNCH_COMMAND'] = steam_launcher.command(service.name,sha,str(game),pipe)
            environment['LLL_PIPE_TOKEN'] = pipe
            environment['LLL_TRANSPORT_SOURCE'] = str(ROOT/'src/steam/transport.lua')
            environment['LLL_SERVICE_EXE'] = str(installed)
            environment['LLL_STAT_FIXTURE'] = str(fixture)
            script = r'''from pathlib import Path
import ctypes,json,os,struct,subprocess
from lupa import lua51
lua=lua51.LuaRuntime(encoding=None)
factory=lua.execute(Path(os.environ['LLL_TRANSPORT_SOURCE']).read_bytes())
config=lua.table_from({b'pipe':os.environ['LLL_PIPE_TOKEN'].encode(),b'launcher':os.environ['LLL_LAUNCH_COMMAND'].encode()})
client=factory(config) # Missing pipes force the real Lua startup path.
handle=None
kernel=ctypes.WinDLL('kernel32',use_last_error=True)
kernel.OpenProcess.argtypes=[ctypes.c_ulong,ctypes.c_int,ctypes.c_ulong]
kernel.OpenProcess.restype=ctypes.c_void_p
kernel.WaitForSingleObject.argtypes=[ctypes.c_void_p,ctypes.c_ulong]
kernel.GetExitCodeProcess.argtypes=[ctypes.c_void_p,ctypes.POINTER(ctypes.c_ulong)]
kernel.CloseHandle.argtypes=[ctypes.c_void_p]
try:
    boot=client.exchange(bytes(12))
    nonce,status,peer=struct.unpack_from('<III',boot)
    assert (nonce,status,peer)==(0,0,os.getpid()),(nonce,status,peer)
    path=os.environ['LLL_STAT_FIXTURE'].encode('utf-8')
    result=client.exchange(struct.pack('<III',1,2,len(path))+path)
    assert struct.unpack_from('<II',result)==(1,0) and len(result)>8,result
    # Locate only the independently launched helper, then verify its exact
    # temporary image path before waiting on it. No game process is opened.
    image=os.environ['LLL_SERVICE_EXE']
    literal=lambda text:"'"+text.replace("'","''")+"'"
    command='$expected='+literal(image)+';foreach($p in [Diagnostics.Process]::GetProcessesByName('+literal(Path(image).stem)+')){try{if($p.MainModule.FileName -eq $expected){[Console]::WriteLine($p.Id)}}finally{$p.Dispose()}}'
    found=subprocess.check_output(['powershell.exe','-NoLogo','-NoProfile','-NonInteractive','-Command',command],text=True,timeout=5,creationflags=subprocess.CREATE_NO_WINDOW)
    identifiers=found.strip().splitlines()
    assert len(identifiers)==1,found
    service_pid=int(identifiers[0])
    handle=kernel.OpenProcess(0x100000|0x1000,False,service_pid)
    assert handle,ctypes.get_last_error()
finally:
    client.close()
if handle:
    try:
        assert kernel.WaitForSingleObject(handle,5000)==0,'Service did not exit on Lua disconnect'
        code=ctypes.c_ulong()
        assert kernel.GetExitCodeProcess(handle,ctypes.byref(code)) and code.value==0,code.value
    finally:
        kernel.CloseHandle(handle)
print(json.dumps({'boot_peer_pid':peer,'lua_host_pid':os.getpid(),'service_pid':service_pid,'disconnect_exit_code':code.value}))
'''
            started = time.monotonic()
            result = subprocess.run([sys.executable,'-c',script],env=environment,
                                    capture_output=True,text=True,timeout=20,
                                    creationflags=subprocess.CREATE_NO_WINDOW)
            self.assertEqual(result.returncode,0,result.stdout+result.stderr)
            self.assertLess(time.monotonic()-started,12)
            evidence = json.loads(result.stdout.strip().splitlines()[-1])
            self.assertEqual(evidence['boot_peer_pid'],evidence['lua_host_pid'])
            self.assertNotEqual(evidence['service_pid'],evidence['lua_host_pid'])
            self.assertEqual(evidence['disconnect_exit_code'],0)


if __name__ == '__main__': unittest.main()
