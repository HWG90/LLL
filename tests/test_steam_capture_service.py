"""Owner-bound Steam menu/camera cursor activation and explicit restoration."""
from pathlib import Path
import unittest

from lupa import lua51

ROOT = Path(__file__).resolve().parents[1]


class SteamCaptureService(unittest.TestCase):
    def setUp(self):
        self.lua = lua51.LuaRuntime(encoding=None)
        self.lua.execute(b'''state={focus=true,cursor=false,clip=false};writes={};reads=0
          local function read(key)
            reads=reads+1
            if read_error==key then error('read refused: '..key)end
            return state[key]
          end
          local function write(key,value)
            writes[#writes+1]={key=key,value=value}
            if refuse==key then return false end
            if ignore~=key then state[key]=value end
            if trip_read==key then read_error=key end
          end
          window={
            mouse_focus=function()return read('focus')end,
            show_cursor=function()return read('cursor')end,
            clip_cursor=function()return read('clip')end,
            set_mouse_focus=function(v)return write('focus',v)end,
            set_show_cursor=function(v)return write('cursor',v)end,
            set_clip_cursor=function(v)return write('clip',v)end}
          capture=assert(loadstring(...))().new(nil,window,function()end)
          ''', (ROOT / 'src/steam/capture.lua').read_bytes())

    def test_menu_activation_is_once_and_tokens_cannot_change_mode_or_owners(self):
        self.lua.execute(b'''local token=assert(capture.acquire('test menu'))
          assert(reads==3 and #writes==0 and capture.owns(token))
          assert(not capture.status().active and not capture.status().pending_restore)
          assert(capture.activate(token))
          assert(not state.focus and state.cursor and state.clip)
          assert(capture.status().owner=='test menu' and capture.status().active and capture.status().mode=='menu')
          assert(not capture.active, 'External activation must not become the manager lease')
          local count,read_count=#writes,reads
          assert(count==3 and capture.activate(token,'menu'))
          assert(not capture.activate(token,'camera'))
          assert(not capture.activate({},'menu') and not capture.activate(nil))
          assert(not capture.activate(token,'unknown') and not capture.release({}))
          assert(#writes==count and reads==read_count, 'Repeated or invalid activation mutated cursor state')
          assert(not capture.release(), 'Manager cleanup must not release another owner')
          assert(capture.sync(false,false))
          assert(#writes==count and capture.owns(token), 'Hidden manager touched an external owner')
          assert(capture.release(token))
          assert(state.focus and not state.cursor and not state.clip and capture.status().owner==nil)
          count=#writes
          assert(not capture.release(token) and not capture.activate(token))
          assert(#writes==count, 'Stale token mutated cursor state')
          assert(capture.sync(true,true) and capture.active)
          assert(capture.acquire('competing')==nil)
          assert(capture.release() and state.focus and not state.cursor and not state.clip)
          ''')

    def test_camera_mode_starts_hidden_and_clipped_and_restores_only_changed_fields(self):
        self.lua.execute(b'''local token=assert(capture.acquire('test camera'))
          assert(capture.activate(token,'camera'))
          assert(not state.focus and not state.cursor and state.clip)
          assert(#writes==2 and capture.status().mode=='camera' and capture.status().active)
          local count,read_count=#writes,reads
          assert(capture.activate(token,'camera') and #writes==count and reads==read_count)
          assert(not capture.activate(token,'menu') and #writes==count)
          -- Camera did not change cursor visibility and therefore cannot restore it.
          state.cursor=true
          assert(capture.release(token))
          assert(state.focus and state.cursor and not state.clip and #writes==count+2)
          -- A visible baseline is also restored when camera activation changed it.
          token=assert(capture.acquire('visible baseline'))
          assert(capture.activate(token,'camera') and not state.cursor and state.clip)
          assert(capture.release(token) and state.cursor)
          -- Existing clipping does not create a redundant clip write.
          state.cursor=false;state.clip=true
          count=#writes;token=assert(capture.acquire('clipped baseline'))
          assert(capture.activate(token,'camera') and #writes==count+1)
          assert(capture.release(token) and state.clip and #writes==count+2)
          ''')

    def test_failed_restoration_retains_owner_until_explicit_retry(self):
        self.lua.execute(b'''local token=assert(capture.acquire('retry owner'))
          assert(capture.activate(token))
          refuse='focus'
          local ok= capture.release(token)
          assert(not ok and capture.owns(token))
          assert(not capture.status().active and capture.status().pending_restore and capture.status().owner=='retry owner')
          local count=#writes
          assert(not capture.activate(token) and capture.acquire('new owner')==nil)
          for frame=1,20 do capture.sync(false,false);capture.status()end
          assert(#writes==count, 'Restoration retried without an explicit owner action')
          refuse=nil
          assert(capture.release(token) and not capture.owns(token))
          assert(state.focus and not state.cursor and not state.clip)
          ''')

    def test_partial_restoration_and_readback_failure_can_be_retried(self):
        self.lua.execute(b'''local token=assert(capture.acquire('partial owner'))
          assert(capture.activate(token))
          refuse='cursor'
          assert(not capture.release(token) and state.focus and state.cursor and state.clip)
          -- Focus was already restored by this release; a later foreign change
          -- must not be overwritten by retrying the remaining fields.
          state.focus=false;refuse=nil
          assert(capture.release(token) and not state.focus and not state.cursor and not state.clip)
          state.focus=true
          token=assert(capture.acquire('readback owner'))
          assert(capture.activate(token))
          trip_read='focus'
          assert(not capture.release(token) and capture.status().pending_restore)
          assert(state.focus, 'Restoration write did not occur before the simulated readback failure')
          local count=#writes
          trip_read=nil;read_error=nil
          assert(capture.release(token))
          assert(#writes==count+2, 'Retry rewrote an already restored focus flag')
          assert(state.focus and not state.cursor and not state.clip)
          ''')

    def test_foreign_baseline_invalid_state_and_already_restored_flags(self):
        self.lua.execute(b'''local token=assert(capture.acquire('baseline owner'))
          state.cursor=true
          assert(not capture.activate(token) and #writes==0)
          assert(capture.status().pending_restore and not capture.status().active)
          assert(capture.release(token) and state.cursor and #writes==0)
          state.cursor=false
          token=assert(capture.acquire('foreign state owner'))
          assert(capture.activate(token))
          state.clip='foreign'
          local count=#writes
          assert(not capture.release(token) and #writes==count and capture.owns(token),
            'Invalid foreign state was overwritten before all fields were checked')
          state.clip=true
          assert(capture.release(token))
          token=assert(capture.acquire('focus return owner'))
          assert(capture.activate(token))
          state.focus=true;state.cursor=false;state.clip=false
          count=#writes
          assert(capture.release(token) and #writes==count and capture.status().owner==nil,
            'Original flags already restored by focus change remained pending')
          ''')

    def test_activation_failure_keeps_partial_state_for_explicit_cleanup(self):
        self.lua.execute(b'''local token=assert(capture.acquire('partial acquisition'))
          refuse='cursor'
          assert(not capture.activate(token) and not state.focus and not state.cursor and not state.clip)
          assert(capture.status().pending_restore and not capture.status().active and capture.owns(token))
          local count=#writes
          assert(not capture.activate(token) and #writes==count)
          refuse=nil
          assert(capture.release(token) and state.focus and #writes==count+1)
          token=assert(capture.acquire('silent setter'))
          ignore='cursor'
          assert(not capture.activate(token) and capture.status().pending_restore)
          ignore=nil;assert(capture.release(token) and state.focus and not state.cursor and not state.clip)
          state.focus=false
          token=assert(capture.acquire('disabled baseline'))
          count=#writes
          assert(not capture.activate(token) and #writes==count)
          assert(capture.release(token) and not state.focus and #writes==count)
          state.focus=true;read_error='focus'
          assert(capture.acquire('unreadable baseline')==nil)
          assert(capture.status().owner==nil and #writes==count)
          ''')


if __name__ == '__main__':
    unittest.main()
