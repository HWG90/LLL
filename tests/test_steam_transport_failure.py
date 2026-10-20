"""Lua 5.1 dead-helper containment; fake streams only, no native/game calls."""
from pathlib import Path
import struct
import sys
import unittest

from lupa import lua51

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tools'))
from build_steam_release import source
from lua51_chunk import convert

STREAMS = b'''
counts={open=0,write=0,flush=0,read=0,write_close=0,read_close=0}
local original_io=io
function integer(n)return string.char(n%256,math.floor(n/256)%256,math.floor(n/65536)%256,math.floor(n/16777216)%256)end
packet=integer(7)..integer(2)..integer(1)..'x'
function replies(...)
 chunks={...}
end
function healthy_reply()replies(integer(8),integer(7)..integer(0))end
local writing={setvbuf=function()return true end}
function writing:write(header,body)
 counts.write=counts.write+1
 assert(header==integer(#body))
 if stream_failure=='write'then return nil,'Invalid argument'end
 if stream_failure=='write_throw'then error('broken writer')end
 return self
end
function writing:flush()
 counts.flush=counts.flush+1
 if stream_failure=='flush'then return nil,'broken flush'end
 return true
end
function writing:close()
 counts.write_close=counts.write_close+1
 if close_failure then error('broken close')end
 return true
end
local reading={setvbuf=function()return true end}
function reading:read(count)
 counts.read=counts.read+1
 if stream_failure=='read'then return nil end
 return table.remove(chunks,1)
end
function reading:close()counts.read_close=counts.read_close+1;return true end
io={open=function(_,mode)
 counts.open=counts.open+1
 return mode=='wb'and writing or reading
end}
factory=assert(loadstring(...))()
wire=factory({pipe='fixture_pipe'})
io=original_io
healthy_reply()
function assert_latched()
 assert(type(wire.failure())=='string'and counts.write_close==1 and counts.read_close==1)
 local w,f,r,o=counts.write,counts.flush,counts.read,counts.open
 for i=1,10 do assert(not pcall(wire.exchange,packet))end
 wire.close();wire.close()
 assert(counts.write==w and counts.flush==f and counts.read==r and counts.open==o,
  'Closed transport performed pipe I/O or attempted reconnect')
 assert(counts.write_close==1 and counts.read_close==1,'Stream cleanup was repeated')
end
'''


class SteamTransportFailure(unittest.TestCase):
    def runtime(self):
        lua = lua51.LuaRuntime(encoding=None)
        lua.execute(STREAMS, (ROOT / 'src/steam/transport.lua').read_bytes())
        return lua

    def test_local_request_errors_preserve_healthy_connection(self):
        lua = self.runtime()
        lua.execute(b'''for _,value in ipairs({false,42,{},'',string.rep('x',11),
            integer(1)..integer(2)..integer(100)..'x',integer(0)..integer(2)..integer(1)..'x',
            integer(1)..integer(0)..integer(0)})do
          assert(not pcall(wire.exchange,value))
          assert(counts.write==0 and counts.read==0 and counts.write_close==0 and counts.read_close==0)
          assert(wire.failure()==nil,'Local request validation destroyed a good transport')
        end
        assert(not pcall(wire.exchange,nil))
        assert(wire.exchange(packet)==integer(7)..integer(0))
        assert(counts.open==2 and counts.write==1 and counts.flush==1 and counts.read==2)
        assert(wire.failure()==nil);wire.close();assert_latched()''')

    def test_write_flush_and_read_failures_close_both_streams_once(self):
        for failure in ('write', 'write_throw', 'flush', 'read'):
            with self.subTest(failure=failure):
                lua = self.runtime()
                lua.globals()[b'stream_failure'] = failure.encode()
                lua.execute(b'''close_failure=true
                  local notifications=0
                  wire.on_failure(function(reason)
                    notifications=notifications+1
                    assert(counts.write_close==1 and counts.read_close==1 and reason==wire.failure())
                    error('Failure listener errors must not replace the original pipe error')
                  end)
                  local ok,why=pcall(wire.exchange,packet)
                  assert(not ok and tostring(why):find('Filesystem service unavailable:',1,true))
                  assert_latched();assert(notifications==1)''')

    def test_invalid_framing_truncation_and_nonce_latch_without_retry(self):
        cases = (
            b"replies('x')",
            b'replies(integer(7))',
            b'replies(integer(67108865))',
            b"replies(integer(8),'short')",
            b'replies(integer(8),integer(8)..integer(0))',
        )
        for case in cases:
            with self.subTest(case=case):
                lua = self.runtime()
                lua.execute(case + b';assert(not pcall(wire.exchange,packet));assert_latched()')

    def loader_runtime(self, capture_pending=True):
        lua = self.runtime()
        lua.execute(b'''clock=0;failed=false;scans=0;module_ticks=0;disabled=0;ui_ticks=0;ui_closes=0
          input_frames=0;input_closes=0;input_owned=true;shot_statuses=0;shot_cancels=0
          old_shutdowns=0;notices={};print=function(text)notices[#notices+1]=text end
          stingray={Application={can_get=function()return false end},Window={}}
          smoke_source='return {live_lua_api=1,on_update=function()module_ticks=module_ticks+1 end,on_disable=function()disabled=disabled+1;return true end}'
          function pending_reply()
            return {id=string.rep('a',32),output_path=shot_path,state='pending',error=0,width=0,height=0,elapsed_ms=0}
          end''')
        platform = '''return {data="data",live="live",settings="settings",loader_config="config",
          revision="Steam-fixture",runtime="Lua 5.1",native_ffi=false,
          now=function()return clock end,hash=function()return "unused"end,
          guard=function()return {supported=true,jit_supported=false}end,
          open_log=function()end,write=function()return true end,
          files=function(path)if path=="live"then return {"smoke.lua"}end;return {}end,
          read=function(path)if path=="live/smoke.lua"then return smoke_source end end,
          changed=function()scans=scans+1;if failed then wire.exchange(packet)end;return false end,
          transport_failure=wire.failure,on_transport_failure=wire.on_failure,
          close_watches=function()wire.exchange(packet)end,
          pointer_snapshot=function()error('Input fixture must not sample a pointer')end,
          screenshot_directory="C:/Local/LLL/Helldivers2/Screenshots",screenshot_session="failure_fixture",
          screenshot_request=function(path)shot_path=path;return pending_reply()end,
          screenshot_status=function()shot_statuses=shot_statuses+1;wire.exchange(packet);return pending_reply()end,
          screenshot_cancel=function()shot_cancels=shot_cancels+1;wire.exchange(packet);return pending_reply()end}'''
        stock = b'''update=function(...)return ... end;prior_update=update
          shutdown=function(...)old_shutdowns=old_shutdowns+1;return ... end;return "stock",nil'''
        assembled = source(struct.pack('<II', len(stock), 1) + stock, 'failure_fixture', platform)
        # Inject only the GUI boundary. The real compiled startup/manager,
        # screenshot facade, and failing transport execute unchanged.
        ui = b'local LLL_UI=(function()\n' + (ROOT / 'src/steam/ui.lua').read_text(encoding='utf-8').encode() + b'\nend)()'
        fixture = b'''local LLL_UI=function(loader)
          local ui={tick=function()ui_ticks=ui_ticks+1 end,close=function()ui_closes=ui_closes+1;return true end}
          loader.close_manager=ui.close;return ui
        end'''
        self.assertEqual(assembled.count(ui), 1)
        assembled = assembled.replace(ui, fixture, 1)
        input_service = (b'local LLL_STEAM_INPUT_SERVICE=(function()\n'
                         + (ROOT / 'src/steam/input_service.lua').read_text(encoding='utf-8').encode()
                         + b'\nend)()')
        input_fixture = b'''local LLL_STEAM_INPUT_SERVICE={new=function()
          return {},{begin_frame=function()input_frames=input_frames+1 end,
            close=function()input_closes=input_closes+1;return false,'Owned reader retirement unconfirmed'end}
        end}'''
        self.assertEqual(assembled.count(input_service), 1)
        assembled = assembled.replace(input_service, input_fixture, 1)
        compiled = lua.eval(b'string.dump(assert(loadstring(...)))', assembled)
        chunk = convert(convert(compiled, 4), 8)
        self.assertEqual(lua.eval(b'assert(loadstring(...))()', chunk), (b'stock', None))
        lua.execute(b'''assert(LiveLuaLoader.modules['live/smoke']=='loaded')
          capture=assert(LiveLuaLoader.capture_service)''')
        if capture_pending:
            lua.execute(b'''job=assert(capture.new_job_token());output_token='owned-png'
              assert(capture.request({job_token=job,output_token=output_token,
                output_path=capture.output_directory..'/War Journalist-failure.png'}).state=='pending')''')
        lua.execute(b"hooked_update=update;failed=true;stream_failure='write'")
        return lua

    def test_dead_helper_stops_maintenance_once_but_keeps_loaded_frames_and_cleanup(self):
        lua = self.loader_runtime()
        self.assertEqual(lua.eval(b'(function()clock=.6;return update(.1,nil,9,nil)end)()'),
                         (.1, None, 9, None))
        lua.execute(b'''local checked=scans
          for i=1,40 do clock=clock+.1;update(.1)end
          assert(scans==checked and module_ticks==41 and ui_ticks==1 and ui_closes==1,
            'Dead helper stopped loaded callbacks or retried maintenance/frontend work')
          assert(input_frames==1 and input_closes==1 and input_owned and shot_cancels==1 and shot_statuses==0,
            'Dead helper retried global input/capture cleanup or cleared its ownership')
          assert(counts.write==1 and counts.write_close==1 and counts.read_close==1)
          local reports=0
          for _,text in ipairs(notices)do if text:find('LLL helper:',1,true)then reports=reports+1 end end
          assert(reports==1,'Dead helper failure was reported repeatedly')
          assert(LiveLuaLoader.close_manager()and ui_closes==2)
          local ok,first,middle,last=shutdown('end',nil,9,nil)
          assert(ok=='end'and first==nil and middle==9 and last==nil and old_shutdowns==1)
          assert(disabled==1 and ui_closes==2,'Shutdown skipped loaded module/UI cleanup')
          local reply=capture.status(job,output_token)
          assert(reply.state=='pending'and reply.uncertain,
            'Helper loss falsely acknowledged screenshot worker retirement')
          assert(not LiveLuaLoader.detach()and not LiveLuaLoader.detach()and update==hooked_update)
          local cancellations,queries=shot_cancels,shot_statuses
          for i=1,20 do clock=clock+.1;update(.1)end
          assert(input_closes==1 and input_frames==1 and shot_cancels==cancellations and shot_statuses==queries,
            'Pending detach automatically retried cleanup against a dead helper')
          assert(counts.write==1 and counts.write_close==1 and counts.read_close==1)
          reports=0
          for _,text in ipairs(notices)do if text:find('LLL helper:',1,true)then reports=reports+1 end end
          assert(reports==1)''')

    def test_shutdown_forwards_original_results_when_close_watches_is_first_failure(self):
        lua = self.loader_runtime(capture_pending=False)
        self.assertEqual(lua.eval(b'shutdown("end",nil,42,nil)'), (b'end', None, 42, None))
        lua.execute(b'''assert(old_shutdowns==1 and disabled==1 and ui_closes==2)
          assert(counts.write==1 and counts.write_close==1 and counts.read_close==1)
          assert(not capture.new_job_token(),'Shutdown reopened capture admission')''')


if __name__ == '__main__':
    unittest.main()
