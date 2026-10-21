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
function mcm_provider(opened)
    mcm_open=opened==true
    mcm_status={owner=nil,active=false,pending_restore=false}
    mcm_status_error=false
    local provider={shared_input_service=public,
        is_open=function()return mcm_open end,
        input_status=function()if mcm_status_error then error('MCM status unavailable')end;return mcm_status end}
    DBFMCM=provider
    return provider
end
'''

KEYBOARD_FIXTURE = b'''
counts.prepare=0;counts.keyboard_acquire=0;counts.keyboard_snapshot=0;counts.keyboard_release=0
local owned;local serial=0
keyboard_release_ok=true;keyboard_acquire_error=false
keyboard_value={valid=true,x=10,y=20,width=1920,height=1080,buttons=1,wheel=120,dx=7,dy=-4,
    keyboard_active=true,keyboard_state=2,keyboard_generation=11,
    keyboard_keys=string.rep('K',32),keyboard_mask=string.rep('M',32)}
platform.keyboard_scope='fixture registered keys'
platform.keyboard_capture_mask=keyboard_value.keyboard_mask
platform.keyboard_prepare=function()
    counts.prepare=counts.prepare+1;assert(not owned,'Private handle forgotten or another owner admitted')
    serial=serial+1;owned={serial=serial};return owned
end
platform.keyboard_acquire=function(handle)
    assert(handle==owned);counts.keyboard_acquire=counts.keyboard_acquire+1
    if keyboard_acquire_error then error('Acquisition acknowledgement lost after native acceptance')end
    return true
end
platform.keyboard_snapshot=function(handle,mode)
    assert(handle==owned and (mode=='menu'or mode=='camera'))
    keyboard_last_handle,keyboard_last_mode=handle,mode
    counts.keyboard_snapshot=counts.keyboard_snapshot+1;return keyboard_value
end
platform.keyboard_release=function(handle)
    assert(handle==owned);counts.keyboard_release=counts.keyboard_release+1
    if not keyboard_release_ok then return false,'Unregister acknowledgement unavailable'end
    owned=nil;return true
end
public,driver=Broker.new(platform,window,capture)
driver.set_manager_busy(function()return busy end)
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

    def keyboard(self):
        self.lua.execute(KEYBOARD_FIXTURE)

    def test_keyboard_opt_in_preserves_legacy_and_same_frame_immutable_key_snapshot(self):
        self.keyboard()
        self.check('''assert(public.version==1 and public.capabilities.keyboard and public.capabilities.keyboard_scope=='fixture registered keys')
            local mask=platform.keyboard_capture_mask
            assert(public.capabilities.keyboard_mask==mask and #mask==32)
            assert(not pcall(function()public.capabilities.keyboard_mask=string.rep('X',32)end))
            platform.keyboard_capture_mask=string.rep('X',32)
            assert(public.capabilities.keyboard_mask==mask,'Capture mask was reread or overwritten')
            local legacy=assert(public.acquire('Legacy','menu'));assert(public.snapshot(legacy))
            assert(counts.prepare==0 and counts.keyboard_acquire==0 and counts.pointer==1)
            assert(public.release(legacy))
            local token=assert(public.acquire('Photo','camera',nil,{keyboard=true}))
            assert(counts.prepare==1 and counts.keyboard_acquire==1 and counts.keyboard_snapshot==0)
            local first=assert(public.snapshot(token));local keys,mask=first.keyboard_keys,first.keyboard_mask
            assert(first.valid and first.keyboard_active and first.keyboard_state==2 and first.dx==7 and first.wheel==120)
            local second=assert(public.snapshot(token))
            assert(second.keyboard_keys==keys and second.keyboard_mask==mask and second.keyboard_generation==11)
            assert(second.dx==0 and second.dy==0 and second.wheel==0 and counts.keyboard_snapshot==1)
            driver.begin_frame();assert(public.snapshot(token));assert(counts.keyboard_snapshot==2 and counts.camera==0)
            assert(public.release(token)and counts.keyboard_release==1)
            local reads,releases=counts.keyboard_snapshot,counts.keyboard_release
            for i=1,80 do driver.begin_frame();public.status();driver.manager_available()end
            assert(counts.keyboard_snapshot==reads and counts.keyboard_release==releases,'Hidden broker used keyboard pipe')
        ''')

    def test_mode_switch_retains_keyboard_authority_and_invalidates_only_the_frame_sample(self):
        self.keyboard()
        self.check('''local reads=0
            for _,name in ipairs({'mouse_focus','show_cursor','clip_cursor'})do
                local read=window[name];window[name]=function()reads=reads+1;return read()end
            end
            local token=assert(public.acquire('Photo','menu',nil,{keyboard=true}))
            local first=assert(public.snapshot(token));local handle,generation=keyboard_last_handle,first.keyboard_generation
            local sets,read_count=state.sets,reads
            assert(public.set_mode(token,'menu')==true and public.snapshot(token)==first)
            assert(reads==read_count and state.sets==sets and counts.keyboard_snapshot==1,
                'Unchanged mode did window or helper work')
            assert(public.set_mode(token,'camera')==true)
            assert(not state.cursor and not state.focus and state.clip and state.sets==sets+1)
            assert(public.status().mode=='camera'and capture.status().mode=='camera'and public.owns(token))
            assert(counts.prepare==1 and counts.keyboard_acquire==1 and counts.keyboard_release==0
                and counts.keyboard_snapshot==1 and counts.release==0,'Mode switch exchanged or replaced the keyboard lease')
            local camera=assert(public.snapshot(token))
            assert(keyboard_last_mode=='camera'and keyboard_last_handle==handle and camera.keyboard_generation==generation
                and counts.keyboard_snapshot==2,'Next combined sample kept the old mode or changed generation')
            assert(public.set_mode(token,'menu')==true and state.cursor and state.sets==sets+2)
            assert(public.snapshot(token)and keyboard_last_mode=='menu'and keyboard_last_handle==handle)
            assert(counts.prepare==1 and counts.keyboard_acquire==1 and counts.keyboard_release==0)
            assert(public.release(token)and counts.keyboard_release==1 and state.focus and not state.cursor and not state.clip)
        ''')

    def test_mode_switch_rejects_foreign_stale_modes_capabilities_and_mcm_camera_without_mutation(self):
        self.check('''local token=assert(public.acquire('Photo','menu'))
            local sets=state.sets
            assert(not public.set_mode({},'camera')and not public.set_mode(nil,'camera'))
            assert(not public.set_mode(token,'unknown')and not public.set_mode(token,nil))
            assert(state.sets==sets and public.owns(token)and counts.release==0 and counts.pointer==0 and counts.camera==0)
            assert(public.set_mode(token,'camera')==true and public.snapshot(token).dx==12)
            assert(public.set_mode(token,'menu')==true and public.snapshot(token).x==123)
            assert(public.release(token))
            local next_token=assert(public.acquire('Successor','menu'));sets=state.sets
            assert(not public.set_mode(token,'camera')and state.sets==sets and public.owns(next_token))
            assert(public.release(next_token))
            platform.camera_snapshot=nil;public,driver=Broker.new(platform,window,capture)
            token=assert(public.acquire('Menu only','menu'));sets=state.sets
            assert(not public.set_mode(token,'camera')and state.sets==sets and public.owns(token))
            assert(public.release(token))
            platform.camera_snapshot=function()return camera end;public,driver=Broker.new(platform,window,capture)
            local provider=mcm_provider(true);local registration=assert(public.register_frontend('mcm',provider))
            token=assert(public.acquire('DBF MCM','menu',registration));sets=state.sets
            assert(not public.set_mode(token,'camera')and public.owns(token)and state.sets==sets)
            assert(public.release(token)and public.unregister_frontend(registration))
        ''')

    def test_foreign_cursor_mode_state_closes_keyboard_first_and_retains_failed_cleanup(self):
        self.keyboard()
        self.check('''local token=assert(public.acquire('Photo','menu',nil,{keyboard=true}))
            assert(public.snapshot(token));state.clip=false
            local sets=state.sets;keyboard_release_ok=false
            assert(not public.set_mode(token,'camera'))
            assert(not public.owns(token)and public.status().pending_restore and capture.status().pending_restore)
            assert(counts.keyboard_release==1 and counts.release==0 and state.sets==sets and state.cursor,
                'Foreign mode state was overwritten or cursor restored before keyboard ACK')
            assert(not public.set_mode(token,'menu')and not public.set_mode({},'camera'))
            for i=1,30 do driver.begin_frame();public.status()end
            assert(counts.keyboard_release==1 and counts.keyboard_snapshot==1 and state.sets==sets)
            keyboard_release_ok=true;assert(public.release(token))
            assert(counts.keyboard_release==2 and counts.release==1 and state.focus and not state.cursor and not state.clip)
        ''')

    def test_partial_mode_write_failure_keeps_original_baseline_for_acknowledged_restore(self):
        self.keyboard()
        self.check('''local token=assert(public.acquire('Photo','camera',nil,{keyboard=true}))
            local setter=window.set_show_cursor
            window.set_show_cursor=function(value)setter(value);return false end
            keyboard_release_ok=false
            assert(not public.set_mode(token,'menu')and state.cursor and public.status().pending_restore)
            assert(capture.owns(token)and capture.status().pending_restore and counts.keyboard_release==1)
            window.set_show_cursor=setter;keyboard_release_ok=true
            assert(public.release(token)and state.focus and not state.cursor and not state.clip,
                'Partial mode change replaced the original restore baseline')
        ''')

    def test_keyboard_acquire_ack_loss_keeps_cleanup_token_and_cursor_until_exact_release(self):
        self.keyboard()
        self.check('''keyboard_acquire_error=true;keyboard_release_ok=false
            local token,why,cleanup=public.acquire('Photo','camera',nil,{keyboard=true})
            assert(not token and type(why)=='string'and type(cleanup)=='table')
            assert(public.status().pending_restore and public.status().keyboard and not public.owns(cleanup))
            assert(not state.focus and not state.cursor and state.clip,'Cursor restored before keyboard retirement acknowledgement')
            local releases,sets=counts.keyboard_release,state.sets
            assert(not public.release({})and not public.snapshot(cleanup))
            assert(driver.manager_release()and not public.acquire('Other','menu'))
            for i=1,30 do driver.begin_frame();public.status()end
            assert(counts.keyboard_release==releases and state.sets==sets,'Pending keyboard cleanup retried while idle')
            keyboard_release_ok=true;assert(public.release(cleanup))
            assert(not public.status().owner and state.focus and not state.cursor and not state.clip)
            local count=counts.keyboard_release;assert(not public.release(cleanup)and counts.keyboard_release==count)
            keyboard_acquire_error=false
            local next_token=assert(public.acquire('Next','menu',nil,{keyboard=true}))
            assert(public.release(next_token))
        ''')

    def test_keyboard_arming_keeps_lease_and_revocation_never_falls_back_to_pointer(self):
        self.keyboard()
        self.check('''local token=assert(public.acquire('Photo','menu',nil,{keyboard=true}))
            keyboard_value.valid=false;keyboard_value.keyboard_state=1;keyboard_value.keyboard_active=false
            local pending=assert(public.snapshot(token))
            assert(not pending.valid and pending.keyboard_state==1 and public.owns(token)and counts.keyboard_release==0)
            assert(public.snapshot(token)and counts.keyboard_snapshot==1)
            driver.begin_frame();keyboard_value.valid=true;keyboard_value.keyboard_state=2;keyboard_value.keyboard_active=true
            assert(public.snapshot(token).keyboard_active and counts.keyboard_snapshot==2)
            driver.begin_frame();keyboard_value.valid=false;keyboard_value.keyboard_state=3;keyboard_value.keyboard_active=false
            keyboard_release_ok=false
            assert(not public.snapshot(token)and not public.owns(token)and public.status().pending_restore)
            assert(counts.pointer==0 and counts.camera==0 and counts.release==0,'Revoked keyboard fell back or released cursor before ACK')
            local reads=counts.keyboard_snapshot
            for i=1,20 do driver.begin_frame();assert(not public.snapshot(token))end
            assert(counts.keyboard_snapshot==reads)
            keyboard_release_ok=true;assert(public.release(token)and counts.release==1)
        ''')

    def test_manager_keyboard_is_private_cached_and_cannot_release_foreign_owner(self):
        self.keyboard()
        self.check('''busy=true;local first=assert(driver.manager_snapshot());assert(first.keyboard_active)
            assert(driver.manager_snapshot()==first and counts.keyboard_snapshot==1 and counts.pointer==0)
            driver.begin_frame();driver.manager_snapshot();assert(counts.keyboard_snapshot==2)
            assert(not public.acquire('Other','menu'))
            assert(driver.manager_release()and counts.keyboard_release==1 and counts.release==1)
            assert(driver.manager_release()and counts.keyboard_release==1)
            busy=false
            local token=assert(public.acquire('Photo','menu',nil,{keyboard=true}))
            local acquire,release=counts.keyboard_acquire,counts.keyboard_release
            assert(not driver.manager_snapshot().valid and driver.manager_release())
            assert(public.owns(token)and counts.keyboard_acquire==acquire and counts.keyboard_release==release)
            assert(public.release(token))
        ''')

    def test_manager_uncertain_prepare_and_blur_cleanup_do_not_retry_while_hidden(self):
        self.keyboard()
        self.check('''busy=true;keyboard_acquire_error=true;keyboard_release_ok=false
            assert(not driver.manager_failure()and capture.sync(true,true))
            assert(not driver.manager_snapshot().valid and not driver.manager_available())
            local failure=driver.manager_failure();assert(type(failure)=='string'and failure:find('acknowledgement lost'))
            assert(not driver.manager_snapshot().valid and counts.prepare==1 and counts.keyboard_acquire==1)
            assert(driver.manager_failure()==failure,'Failed manager read discarded its failure latch')
            assert(not driver.manager_release())
            local count,sets=counts.keyboard_release,state.sets
            local pending=driver.manager_failure();assert(type(pending)=='string'and pending:find('Unregister'))
            assert(capture.status().owner=='lll'and not state.focus and state.cursor and state.clip,
                'Pending keyboard retirement released the cursor owner')
            for i=1,30 do driver.begin_frame();assert(driver.manager_failure()==pending)end
            assert(counts.keyboard_release==count,'Uncertain manager cleanup retried without explicit action')
            assert(state.sets==sets,'Pure manager failure status changed cursor state')
            keyboard_release_ok=true;assert(driver.manager_release())
            assert(not driver.manager_failure()and not capture.status().owner and state.focus and not state.cursor and not state.clip)
            keyboard_acquire_error=false;assert(driver.manager_snapshot().valid)
            state.focused=false;keyboard_release_ok=false;driver.begin_frame()
            assert(counts.keyboard_release==count+2 and counts.release==0)
            local reads,releases=counts.keyboard_snapshot,counts.keyboard_release
            for i=1,30 do driver.begin_frame();assert(not driver.manager_snapshot().valid)end
            assert(counts.keyboard_snapshot==reads and counts.keyboard_release==releases)
            keyboard_release_ok=true;assert(driver.manager_release()and counts.release==1)
            for i=1,30 do driver.begin_frame()end
            assert(counts.keyboard_release==releases+1)
        ''')

    def test_keyboard_options_refuse_unsupported_or_malformed_requests_without_mutation(self):
        self.check('''assert(not public.capabilities.keyboard and public.capabilities.keyboard_mask==nil)
            assert(not public.acquire('Photo','menu',nil,{keyboard=true}))
            assert(not public.acquire('Photo','menu',nil,{keyboard='yes'}))
            assert(not public.acquire('Photo','menu',nil,true))
            assert(state.sets==0 and counts.pointer==0 and counts.release==0)
            local token=assert(public.acquire('Legacy','menu',nil,{keyboard=false}));assert(public.release(token))''')
        self.keyboard()
        self.check('''for _,value in ipairs({false,17,'',string.rep('M',31),string.rep('M',33)})do
                platform.keyboard_capture_mask=value;public,driver=Broker.new(platform,window,capture)
                assert(not public.capabilities.keyboard and public.capabilities.keyboard_mask==nil)
                assert(not public.acquire('Photo','menu',nil,{keyboard=true}))
            end
            platform.keyboard_capture_mask=nil;public,driver=Broker.new(platform,window,capture)
            assert(not public.capabilities.keyboard and public.capabilities.keyboard_mask==nil)
            assert(counts.prepare==0 and counts.keyboard_acquire==0,'Invalid mask advertised native capture')''')

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

    def test_mcm_registration_requires_exact_published_provider_and_is_idle(self):
        self.check('''
            local provider=mcm_provider(false)
            assert(not public.register_frontend('other',provider),'Unknown frontend role registered')
            assert(not public.register_frontend('mcm',{}),'Unpublished provider registered')
            provider.shared_input_service={}
            assert(not public.register_frontend('mcm',provider),'Foreign shared service registered')
            provider.shared_input_service=nil
            setmetatable(provider,{__index={shared_input_service=public}})
            assert(not public.register_frontend('mcm',provider),'Inherited shared-service field registered')
            setmetatable(provider,nil);provider.shared_input_service=public
            local status=provider.input_status;provider.input_status=nil
            assert(not public.register_frontend('mcm',provider),'Provider without status method registered')
            provider.input_status=status
            local opened=provider.is_open;provider.is_open=true
            assert(not public.register_frontend('mcm',provider),'Provider without open method registered')
            provider.is_open=opened
            local registration=assert(public.register_frontend('mcm',provider))
            assert(registration~=provider and registration~=public,'Registration token was not opaque')
            assert(not public.register_frontend('mcm',provider),'Duplicate provider registration succeeded')
            for i=1,100 do driver.begin_frame();public.status();driver.manager_available()end
            assert(counts.pointer==0 and counts.camera==0 and counts.release==0,'Registered closed MCM polled helper')
            assert(state.sets==0,'Registering closed MCM changed cursor flags')
            assert(not public.unregister_frontend({}),'Wrong registration token unregistered frontend')
            assert(public.unregister_frontend(registration))
            assert(not public.unregister_frontend(registration),'Stale registration token remained valid')
        ''')

    def test_mcm_bound_acquire_bypasses_only_its_own_open_provider(self):
        self.check('''
            local provider=mcm_provider(true)
            local registration=assert(public.register_frontend('mcm',provider))
            mcm_status={owner='DBF MCM',active=true,pending_restore=false}
            assert(not public.acquire('DBF MCM','menu'),'Owner name alone bypassed MCM exclusion')
            assert(not public.acquire('Example','menu'),'Plain acquisition ignored open MCM')
            assert(not public.acquire('DBF MCM','menu',{}),'Forged frontend token accepted')
            assert(not public.acquire('Example','menu',registration),'Frontend token authorized foreign owner')
            assert(not public.acquire('DBF MCM','camera',registration),'Frontend token authorized camera mode')
            busy=true
            assert(not public.acquire('DBF MCM','menu',registration),'Frontend bypassed manager busy')
            busy=false;state.focused=false
            assert(not public.acquire('DBF MCM','menu',registration),'Frontend bypassed game foreground')
            state.focused=true
            local token=assert(public.acquire('DBF MCM','menu',registration))
            assert(public.owns(token) and public.status().frontend=='mcm')
            assert(not public.unregister_frontend(registration),'Active bound lease was unregistered')
            local sets=state.sets
            for i=1,20 do driver.begin_frame()end
            assert(public.owns(token) and state.sets==sets,'Active frontend reapplied cursor flags')
            assert(counts.pointer==0 and counts.camera==0 and counts.release==0,'Active frontend polled without snapshots')
            for i=1,10 do
                driver.begin_frame()
                assert(public.snapshot(token));assert(public.snapshot(token))
            end
            assert(counts.pointer==10 and counts.camera==0 and state.sets==sets,'Frontend repeated sampling or cursor writes')
            assert(public.release(token))
            assert(public.status().frontend==nil)
            assert(public.unregister_frontend(registration))
            assert(not public.acquire('DBF MCM','menu',registration),'Unregistered token acquired input')
            assert(state.focus and not state.cursor and not state.clip)
        ''')

    def test_mcm_frontend_refuses_pending_foreign_unknown_or_malformed_status(self):
        self.check('''
            local provider=mcm_provider(true)
            local registration=assert(public.register_frontend('mcm',provider))
            local bad={
                {owner='DBF MCM',active=false,pending_restore=true},
                {owner='Photo Mode',active=false,pending_restore=false},
                {owner='Photo Mode',active=true,pending_restore=false},
                {owner=nil,active=true,pending_restore=false},
                {owner='DBF MCM',active='yes',pending_restore=false},
                {owner='DBF MCM',active=false,pending_restore='no'},
                {},
                false,'status'
            }
            for _,status in ipairs(bad)do
                mcm_status=status
                assert(not public.acquire('DBF MCM','menu',registration),'Malformed or conflicting MCM status bypassed exclusion')
            end
            mcm_status_error=true
            assert(not public.acquire('DBF MCM','menu',registration),'Throwing status bypassed exclusion')
            mcm_status_error=false;mcm_status={owner=nil,active=false,pending_restore=false}
            mcm_open='yes'
            assert(not public.acquire('DBF MCM','menu',registration),'Malformed open status bypassed exclusion')
            assert(counts.pointer==0 and counts.camera==0 and counts.release==0 and state.sets==0,'Rejected frontend touched input')
            mcm_open=true
            local token=assert(public.acquire('DBF MCM','menu',registration))
            assert(public.release(token));assert(public.unregister_frontend(registration))
        ''')

    def test_mcm_frontend_revokes_on_provider_replacement_or_shared_field_loss(self):
        for trigger in ('snapshot', 'begin_frame'):
            for replacement in ('provider', 'shared_field'):
                with self.subTest(trigger=trigger, replacement=replacement):
                    self.setUp()
                    self.check('''
                        local provider=mcm_provider(true)
                        registration=assert(public.register_frontend('mcm',provider))
                        token=assert(public.acquire('DBF MCM','menu',registration))
                        assert(public.snapshot(token))
                        reads=counts.pointer
                    ''')
                    self.check("mcm_provider(true)" if replacement=='provider'
                               else "DBFMCM.shared_input_service=nil")
                    self.check("assert(not public.snapshot(token))" if trigger=='snapshot'
                               else "driver.begin_frame()")
                    self.check('''
                        assert(not public.owns(token) and not public.status().owner,'Stale frontend retained active input')
                        assert(counts.pointer==reads and counts.release==1,'Stale frontend sampled or failed to release reader')
                        assert(state.focus and not state.cursor and not state.clip,'Stale frontend did not restore cursor')
                        assert(not public.acquire('DBF MCM','menu',registration),'Stale frontend registration reacquired input')
                        assert(public.unregister_frontend(registration))
                    ''')

    def test_mcm_replacement_and_unregistration_wait_for_pending_release(self):
        self.check('''
            local old_provider=mcm_provider(true)
            local old_registration=assert(public.register_frontend('mcm',old_provider))
            local token=assert(public.acquire('DBF MCM','menu',old_registration))
            assert(public.snapshot(token))
            local replacement=mcm_provider(true)
            assert(not public.register_frontend('mcm',replacement),'Replacement registered during active bound lease')
            release_ok=false;driver.begin_frame()
            local pending=public.status()
            assert(not pending.active and pending.pending_restore and pending.frontend=='mcm')
            assert(not public.unregister_frontend(old_registration),'Pending bound lease was unregistered')
            assert(not public.register_frontend('mcm',replacement),'Replacement registered before pending release completed')
            assert(not public.unregister_frontend({}),'Wrong token removed pending frontend')
            release_ok=true
            assert(public.release(token),'Pending frontend release retry failed')
            local registration=assert(public.register_frontend('mcm',replacement))
            assert(registration~=old_registration,'Replacement reused stale registration token')
            assert(not public.acquire('DBF MCM','menu',old_registration),'Old registration acquired replacement provider')
            assert(not public.unregister_frontend(old_registration),'Old registration removed replacement provider')
            local replacement_token=assert(public.acquire('DBF MCM','menu',registration))
            assert(public.release(replacement_token))
            assert(public.unregister_frontend(registration))
        ''')


if __name__=='__main__': unittest.main()
