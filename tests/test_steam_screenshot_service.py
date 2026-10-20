"""Real helper refusal/wire contracts, using only this Python process as peer.

Set LLL_TEST_STEAM_SERVICE to the newly built helper directory. No request in
this fixture can authenticate as Helldivers, so it never starts WGC capture.
"""
from pathlib import Path
import ctypes
import os
import secrets
import struct
import subprocess
import tempfile
import time
import unittest

from lupa import lua51

ROOT = Path(__file__).resolve().parents[1]
SERVICE = os.environ.get('LLL_TEST_STEAM_SERVICE')
GAME = Path(r'C:\Program Files (x86)\Steam\steamapps\common\Helldivers 2_steam')


@unittest.skipUnless(os.name == 'nt' and SERVICE,
                     'Requires an explicitly selected Windows screenshot helper build')
class ScreenshotServiceIntegration(unittest.TestCase):
    def test_foreign_peer_refusal_keeps_one_connection_and_filesystem_responsive(self):
        service_root = Path(SERVICE)
        service = service_root / (service_root / 'service.txt').read_text().strip()
        self.assertTrue(service.is_file(), 'Selected helper build is incomplete')
        pipe = 'lll_steam_shot_test_' + secrets.token_hex(12)
        with tempfile.TemporaryDirectory(prefix='lll-shot-wire-') as temporary:
            root = Path(temporary)
            environment = os.environ.copy()
            environment['LOCALAPPDATA'] = temporary
            child = subprocess.Popen([str(service), '--game', str(GAME), '--pipe', pipe],
                                     env=environment, creationflags=subprocess.CREATE_NO_WINDOW)
            transport = None
            try:
                request_pipe = '\\\\.\\pipe\\' + pipe + '_request'
                deadline = time.monotonic() + 8
                while not ctypes.windll.kernel32.WaitNamedPipeW(request_pipe, 100):
                    if child.poll() is not None:
                        self.fail('Helper exited before the own-process connection')
                    if time.monotonic() >= deadline:
                        self.fail('Helper startup exceeded eight seconds')
                    time.sleep(.02)
                lua = lua51.LuaRuntime(encoding=None)
                create = lua.execute((ROOT / 'src/steam/transport.lua').read_bytes())
                transport = create(lua.table_from({b'pipe': pipe.encode()}))
                exchange = transport[b'exchange']
                nonce = 0

                def call(operation, payload=b'', declared=None):
                    nonlocal nonce
                    nonce += 1
                    packet = struct.pack('<III', nonce, operation,
                                         len(payload) if declared is None else declared) + payload
                    reply = exchange(packet)
                    self.assertGreaterEqual(len(reply), 8)
                    self.assertEqual(struct.unpack_from('<I', reply)[0], nonce)
                    return struct.unpack_from('<I', reply, 4)[0], reply

                # The client PID is this Python process, never the game. Boot
                # still verifies the supported stock files for normal FS use.
                boot = exchange(struct.pack('<III', 0, 0, 0))
                self.assertEqual(struct.unpack_from('<III', boot), (0, 0, os.getpid()))
                stream_root = root / 'LLL/Helldivers2/Steam'
                protocol_paths = [stream_root / name for name in ('request.bin', 'response.bin')]
                before = {path: (path.stat().st_mtime_ns, path.read_bytes()) if path.exists() else None
                          for path in protocol_paths}
                sample = root / 'sample-\u03a9.txt'
                sample.write_bytes(b'filesystem remains responsive')
                png = root / 'LLL/Helldivers2/Screenshots/fixture.png'
                well_formed = b'0123456789abcdef0123456789abcdef'
                began = time.monotonic()

                # Malformed packets must fail in memory, without dropping the
                # connection or falling through to legacy request.bin I/O.
                for operation in (13, 14, 15):
                    for payload, declared in ((b'\xff', None), (b'', None),
                                              (b'abc', 2), (b'a\0b', None)):
                        status, reply = call(operation, payload, declared)
                        self.assertEqual((status, len(reply)), (13, 8))

                # A well-formed path cannot authorize capture from this peer.
                # Repeating it must not allocate a job or create its folder.
                for _ in range(3):
                    status, reply = call(13, str(png).encode('utf-8'))
                    self.assertEqual((status, len(reply)), (5, 8))
                    for operation in (14, 15):
                        status, reply = call(operation, well_formed)
                        self.assertEqual((status, len(reply)), (1168, 8))
                        for invalid in (b'bad', b'0' * 31, b'0' * 33, b'A' * 32):
                            status, reply = call(operation, invalid)
                            self.assertEqual((status, len(reply)), (87, 8))
                    # A normal stat between refusals proves the same service
                    # exchange loop remains usable and carries the right data.
                    status, reply = call(2, str(sample).encode('utf-8'))
                    self.assertEqual((status, len(reply)), (0, 28))
                    self.assertEqual(struct.unpack_from('<II', reply, 12),
                                     (0, sample.stat().st_size))
                self.assertLess(time.monotonic() - began, 2,
                                'Refused screenshot requests blocked filesystem exchanges')
                self.assertFalse(png.parent.exists(), 'Foreign peer created capture output state')
                self.assertFalse((stream_root / 'events.bin').exists())
                for path, expected in before.items():
                    actual = (path.stat().st_mtime_ns, path.read_bytes()) if path.exists() else None
                    self.assertEqual(actual, expected, 'Refusals must not write legacy protocol files')
                transport[b'close']()
                transport = None
                child.wait(timeout=5)
                self.assertEqual(child.returncode, 0)
            finally:
                try:
                    if transport is not None:
                        transport[b'close']()
                finally:
                    if child.poll() is None:
                        child.terminate()
                        child.wait(timeout=5)


if __name__ == '__main__':
    unittest.main()
