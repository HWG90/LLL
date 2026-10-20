"""Lua 5.1 broker ownership, capture restoration and idle input contracts."""
from pathlib import Path
import unittest

from lupa import lua51

ROOT = Path(__file__).resolve().parents[1]


FIXTURE = b'''
state={focused=true,focus=true,cursor=false,clip=false,sets=0,fail_restore=false}
window={
    has_focus=function()return state.focused end,
    mouse_focus=function()return state.focus end,
    show_cursor=function()return state.cursor end,
    clip_cursor=function()return state.clip end,
    set_mouse_focus=function(value)
        state.sets=state.sets+1
        if state.fail_restore and value==true then return false end
        state.focus=value;return true
    end,
    set_show_cursor=function(value)state.sets=state.sets+1;state.cursor=value;return true end,
    set_clip_cursor=function(value)state.sets=state.sets+1;state.clip=value;return true end,
}
counts={pointer=0,camera=0,release=0}
pointer={valid=true,x=123,y=234,width=1920,height=1080,buttons=3,wheel=120}
camera={valid=true,x=500,y=400,width=1920,height=1080,buttons=2,wheel=-120,dx=12,dy=-5}
release_ok=true
platform={
    pointer_snapshot=function()counts.pointer=counts.pointer+1;return pointer end,
    camera_snapshot=function()counts.camera=counts.camera+1;return camera end,
    release_pointer=function()counts.release=counts.release+1;return release_ok end,
}
busy=false
DBFMCM=nil
'''


class InputService(unittest.TestCase):
    def setUp(self):
        self.lua = lua51.LuaRuntime(encoding=None)
        self.lua.execute(FIXTURE)
        self.lua.globals()[b'Capture'] = self.lua.execute((ROOT/'src/steam/capture.lua').read_bytes())
        self.lua.globals()[b'Broker'] = self.lua.execute((ROOT/'src/steam/input_service.lua').read_bytes())
        self.lua.execute(b'''capture=Capture.new({},window,function()end)
            public,driver=Broker.new(platform,window,capture)
            driver.set_manager_busy(function()return busy end)''')

    def check(self, script):
        self.lua.execute(script.encode())

    def test_capability_and_status_queries_leave_hidden_input_idle(self):
        self.check('''
            assert(public.version==1 or public.api_version==1,'API version missing')
            assert(public.capabilities.menu and public.capabilities.camera and public.capabilities.relative_mouse)
            for i=1,100 do
                driver.begin_frame()
                public.status()
                driver.manager_available()
            end
            assert(counts.pointer==0 and counts.camera==0 and counts.release==0,'Hidden broker touched backend')
            assert(state.sets==0,'Hidden broker changed cursor')
        ''')

    def test_external_tokens_are_exclusive_and_manager_release_is_isolated(self):
        self.check('''
            local first=assert(public.acquire('Example menu','menu'))
            assert(public.owns(first))
            assert(not public.acquire('Another menu','menu'),'Second owner acquired a live lease')
            assert(not public.owns({}),'Forged token owned the lease')
            assert(not public.snapshot({}),'Forged token sampled input')
            assert(not public.release({}),'Forged token released ownership')
            local p,c,r=counts.pointer,counts.camera,counts.release
            driver.manager_release()
            assert(public.owns(first),'Manager release revoked external lease')
            assert(counts.pointer==p and counts.camera==c and counts.release==r,'Manager release touched external backend')
            assert(not driver.manager_available(),'Manager ignored external lease')
            assert(public.release(first))
            assert(not public.owns(first))
            assert(state.focus and not state.cursor and not state.clip,'Release did not restore original cursor')
        ''')

    def test_focus_mcm_manager_and_mode_requirements_refuse_acquisition(self):
        self.check('''
            assert(not public.acquire('', 'menu'),'Empty owner accepted')
            assert(not public.acquire('Example','unsupported'),'Unsupported mode accepted')
            state.focused=false
            assert(not public.acquire('Example','menu'),'Unfocused window acquired input')
            state.focused=true;busy=true
            assert(not public.acquire('Example','menu'),'Manager busy lease conflict accepted')
            busy=false;DBFMCM={is_open=function()return true end}
            assert(not public.acquire('Example','menu'),'MCM conflict accepted')
            DBFMCM={is_open=function()return false end,input_status=function()return {owner='external',active=true}end}
            assert(not public.acquire('Example','menu'),'Closed MCM retained an external cursor owner')
            DBFMCM={is_open=function()return false end,input_status=function()return {pending_restore=true}end}
            assert(not public.acquire('Example','menu'),'MCM pending cursor restoration was ignored')
            DBFMCM={is_open=function()return false end}
            local token=assert(public.acquire('Example','menu'))
            assert(public.release(token))
        ''')

    def test_menu_snapshot_is_reused_and_samples_once_per_frame(self):
        self.check('''
            driver.begin_frame()
            local token=assert(public.acquire('Example','menu'))
            local sample=assert(public.snapshot(token))
            assert(sample.valid and sample.x==123 and sample.y==234 and sample.width==1920 and sample.height==1080)
            assert(sample.buttons==3 and sample.wheel==120)
            local again=assert(public.snapshot(token))
            assert(again==sample,'Broker allocated a new public sample')
            assert(again.wheel==0 and (again.dx or 0)==0 and (again.dy or 0)==0,'Frame deltas delivered twice')
            assert(counts.pointer==1 and counts.camera==0,'More than one backend sample in a frame')
            driver.begin_frame();pointer.x=321;pointer.wheel=-240
            local next_sample=assert(public.snapshot(token))
            assert(next_sample==sample and next_sample.x==321 and next_sample.wheel==-240)
            assert(counts.pointer==2 and counts.camera==0)
            assert(public.release(token))
        ''')

    def test_camera_snapshot_deltas_are_consumed_once_and_use_camera_backend(self):
        self.check('''
            driver.begin_frame()
            local token=assert(public.acquire('Photo Mode','camera'))
            local sample=assert(public.snapshot(token))
            assert(sample.valid and sample.dx==12 and sample.dy==-5 and sample.wheel==-120)
            assert(sample.buttons==2)
            local again=assert(public.snapshot(token))
            assert(again==sample and again.dx==0 and again.dy==0 and again.wheel==0)
            assert(counts.pointer==0 and counts.camera==1)
            driver.begin_frame();camera.dx=-2;camera.dy=4;camera.wheel=0
            local next_sample=assert(public.snapshot(token))
            assert(next_sample==sample and next_sample.dx==-2 and next_sample.dy==4)
            assert(counts.pointer==0 and counts.camera==2)
            assert(public.release(token))
        ''')

    def test_focus_loss_revokes_external_capture(self):
        self.check('''
            local token=assert(public.acquire('Example','menu'))
            assert(public.snapshot(token))
            local p,c=counts.pointer,counts.camera
            state.focused=false;driver.begin_frame()
            assert(not public.owns(token),'Foreground loss retained external ownership')
            assert(not public.snapshot(token),'Revoked owner sampled input')
            assert(counts.pointer==p and counts.camera==c,'Foreground loss sampled hidden input')
            assert(state.focus and not state.cursor and not state.clip,'Foreground loss did not restore cursor')
        ''')

    def test_backend_release_failure_retains_lease_for_explicit_retry(self):
        self.check('''
            local token=assert(public.acquire('Example','menu'))
            assert(public.snapshot(token))
            release_ok=false
            assert(not public.release(token),'Backend release failure was ignored')
            local pending=public.status()
            assert(not public.owns(token),'Inactive pending token still authorized input')
            assert(pending.owner=='Example' and pending.pending_restore and not pending.active,'Failed release discarded pending ownership')
            assert(not public.snapshot(token),'Pending release sampled input')
            assert(not public.acquire('Other','menu'),'Pending release allowed another owner')
            assert(not driver.manager_available(),'Pending release allowed manager')
            release_ok=true
            assert(public.release(token),'Explicit release retry failed')
            assert(not public.owns(token))
            assert(state.focus and not state.cursor and not state.clip)
        ''')

    def test_cursor_restore_failure_retains_lease_for_explicit_retry(self):
        self.check('''
            local token=assert(public.acquire('Example','camera'))
            assert(public.snapshot(token))
            state.fail_restore=true
            assert(not public.release(token),'Cursor restore failure was ignored')
            local pending=public.status()
            assert(not public.owns(token),'Failed restore token still authorized input')
            assert(pending.owner=='Example' and pending.pending_restore and not pending.active,'Failed cursor restore discarded pending ownership')
            state.fail_restore=false
            assert(public.release(token),'Cursor restoration retry failed')
            assert(not public.owns(token))
            assert(state.focus and not state.cursor and not state.clip)
        ''')

    def test_manager_snapshot_is_bounded_and_releases_its_own_reader(self):
        self.check('''
            busy=true
            driver.begin_frame()
            local first=assert(driver.manager_snapshot())
            assert(first.valid and first.wheel==120)
            driver.manager_snapshot()
            assert(counts.pointer==1 and counts.camera==0,'Manager sampled backend more than once per frame')
            driver.begin_frame();pointer.x=321
            local next_sample=assert(driver.manager_snapshot())
            assert(next_sample.x==321 and counts.pointer==2)
            assert(not public.acquire('Example','menu'),'External acquired during manager reader')
            assert(driver.manager_release())
            assert(counts.release==1,'Manager reader was not stopped exactly once')
            assert(driver.manager_release())
            assert(counts.release==1,'Idle manager release touched backend')
        ''')

    def test_camera_capability_gates_mode_and_capabilities_are_read_only(self):
        self.check('''
            local ok=pcall(function()public.capabilities.menu=false end)
            assert(not ok and public.capabilities.menu,'Capabilities could be overwritten')
            platform.camera_snapshot=nil
            public,driver=Broker.new(platform,window,capture)
            assert(public.capabilities.menu and not public.capabilities.camera and not public.capabilities.relative_mouse)
            assert(not public.acquire('Photo Mode','camera'),'Camera mode accepted without backend')
            assert(counts.pointer==0 and counts.camera==0 and counts.release==0)
            local token=assert(public.acquire('Example','menu'))
            assert(public.release(token))
        ''')

    def test_invalid_or_throwing_backend_revokes_once_and_stays_idle(self):
        self.check('''
            local token=assert(public.acquire('Example','menu'))
            pointer.valid=false
            assert(not public.snapshot(token),'Invalid foreground snapshot accepted')
            assert(not public.owns(token) and not public.status().owner)
            assert(counts.pointer==1 and counts.release==1)
            assert(state.focus and not state.cursor and not state.clip)
            local p,r=counts.pointer,counts.release
            for i=1,20 do driver.begin_frame();assert(not public.snapshot(token))end
            assert(counts.pointer==p and counts.release==r,'Revoked owner retried backend')
            platform.pointer_snapshot=function()counts.pointer=counts.pointer+1;error('Disconnected')end
            local next_token=assert(public.acquire('Example','menu'))
            assert(not public.snapshot(next_token),'Throwing backend escaped as success')
            assert(not public.owns(next_token) and not public.status().owner)
            assert(state.focus and not state.cursor and not state.clip)
        ''')

    def test_close_releases_owned_input_and_returns_to_idle(self):
        self.check('''
            local token=assert(public.acquire('Example','menu'))
            assert(public.snapshot(token))
            assert(driver.close())
            assert(not public.owns(token))
            assert(state.focus and not state.cursor and not state.clip)
            local p,c,r=counts.pointer,counts.camera,counts.release
            for i=1,50 do driver.begin_frame();public.status()end
            assert(counts.pointer==p and counts.camera==c and counts.release==r,'Closed broker performed backend work')
        ''')

    def test_activation_failure_exposes_cleanup_token_only_when_restore_fails(self):
        self.check('''
            local activate=capture.activate
            capture.activate=function(token,mode)
                local ok,why=activate(token,mode)
                assert(ok,why)
                return false,'Injected activation rejection after application'
            end
            state.fail_restore=true
            local token,why,cleanup=public.acquire('Example','menu')
            assert(token==nil and type(why)=='string','Failed activation returned usable ownership')
            assert(type(cleanup)=='table','Failed rollback lost its cleanup token')
            local pending=public.status()
            assert(pending.owner=='Example' and pending.pending_restore and not pending.active)
            assert(not public.owns(cleanup) and not public.snapshot(cleanup),'Cleanup token authorized input')
            assert(not public.acquire('Other','menu'),'Failed rollback allowed another owner')
            local sets=state.sets
            for i=1,20 do driver.begin_frame();public.status()end
            assert(state.sets==sets and counts.release==0,'Pending rollback retried without explicit action')
            state.fail_restore=false
            assert(public.release(cleanup),'Explicit cleanup token retry failed')
            assert(not public.status().owner and not capture.status().owner)
            assert(state.focus and not state.cursor and not state.clip)
            local second,second_why,unneeded=public.acquire('Example','menu')
            assert(second==nil and type(second_why)=='string' and unneeded==nil,'Successful rollback exposed a cleanup token')
            assert(not public.status().owner and not capture.status().owner)
            assert(state.focus and not state.cursor and not state.clip)
            assert(counts.pointer==0 and counts.camera==0 and counts.release==0,'Activation failure started input backend')
        ''')


if __name__=='__main__': unittest.main()
