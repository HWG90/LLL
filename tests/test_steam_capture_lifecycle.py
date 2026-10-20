"""Real assembled Lua 5.1 loader detach must await screenshot retirement."""
from pathlib import Path
import struct
import sys
import unittest

from lupa import lua51

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tools'))
from build_steam_release import source
from lua51_chunk import convert


class ScreenshotLoaderLifecycle(unittest.TestCase):
    def setUp(self):
        self.lua = lua51.LuaRuntime(encoding=None)
        self.lua.execute(b'''clock=0;phase='pending';captures=0;statuses=0;cancels=0;stock_updates=0
            notices={};print=function(text)notices[#notices+1]=text end
            stingray={Application={can_get=function()return false end},Window={has_focus=function()return true end},
              Keyboard={button_id=function()return nil end},Mouse={button_id=function()return nil end,axis_id=function()return nil end}}
            function capture_reply()
              return {id=string.rep('a',32),output_path=capture_path,state=phase,error=phase=='cancelled'and 1223 or 0,
                width=phase=='succeeded'and 1280 or 0,height=phase=='succeeded'and 720 or 0,
                elapsed_ms=phase=='pending'and 0 or 75}
            end''')
        platform = '''return {data="data",live="live",settings="settings",loader_config="config",
          revision="Steam-fixture",runtime="Lua 5.1",native_ffi=false,
          hash=function()return "unused" end,now=function()return clock end,
          guard=function()return {supported=true,jit_supported=false}end,
          open_log=function()end,files=function()return {}end,read=function()end,write=function()return true end,
          screenshot_directory="C:/Local/LLL/Helldivers2/Screenshots",screenshot_session="lifecycle_fixture",
          screenshot_request=function(path)captures=captures+1;capture_path=path;return capture_reply()end,
          screenshot_status=function(id)assert(id==string.rep('a',32));statuses=statuses+1;return capture_reply()end,
          screenshot_cancel=function(id)assert(id==string.rep('a',32));cancels=cancels+1;return capture_reply()end}'''
        stock = b'''update=function(dt,...)stock_updates=stock_updates+1;return dt,... end
          prior_update=update;shutdown=function(...)return ... end;return "stock",nil,42,nil'''
        assembled = source(struct.pack('<II', len(stock), 1) + stock, 'lifecycle_fixture', platform)
        compiled = self.lua.eval(b'string.dump(assert(loadstring(...)))', assembled)
        chunk = convert(convert(compiled, 4), 8)
        self.assertEqual(self.lua.eval(b'assert(loadstring(...))()', chunk), (b'stock', None, 42, None))
        self.lua.execute(b'''capture=assert(LiveLuaLoader.capture_service)
          assert(capture==CowboyBingusModLoader.capture_service and LiveLuaLoader.capabilities.game_screenshots)
          job=assert(capture.new_job_token());output_token=job..':png'
          local reply=assert(capture.request({job_token=job,output_token=output_token,
            output_path=capture.output_directory..'/War Journalist-lifecycle.png'}))
          assert(reply.state=='pending'and captures==1)
          hooked_update=update;assert(hooked_update~=prior_update)''')

    def test_repeated_detach_cannot_acknowledge_active_capture_and_pending_log_stays_quiet(self):
        self.lua.execute(b'''assert(not LiveLuaLoader.detach())
          assert(cancels==1 and update==hooked_update and not next(LiveLuaLoader.pending_cleanup))
          for i=1,6 do
            local done,why=LiveLuaLoader.detach()
            assert(done==false and why=='pending'and update==hooked_update,
              'Repeated detach acknowledged an active screenshot worker')
          end
          -- The real update wrapper keeps explicit cleanup alive. Active
          -- native status reads remain bounded by the facade's 100ms gate.
          for i=1,20 do clock=clock+.05;update(.05)end
          assert(update==hooked_update and cancels==1 and statuses>0 and statuses<=10)
          local reports=0
          for _,text in ipairs(notices)do
            if text:find('LLL screenshot cleanup:',1,true)then reports=reports+1 end
          end
          assert(reports==1,'Pending screenshot cleanup rewrote the same report every frame')
          phase='cancelled';clock=clock+.2;update(.2)
          assert(update==prior_update,'Retired capture did not release the owned update wrapper')
          assert(LiveLuaLoader.detach()==true and capture.status(job,output_token).state=='cancelled')
          local count=statuses;clock=clock+1;update(.01)
          assert(statuses==count and LiveLuaLoader.detach()==true,
            'Completed detach resumed helper reads')''')

    def test_publication_winner_retires_without_overwriting_a_new_update_owner(self):
        self.lua.execute(b'''assert(not LiveLuaLoader.detach())
          assert(not LiveLuaLoader.detach()and update==hooked_update)
          -- Publication may win cancellation, but remains pending until the
          -- backend reports worker retirement. Preserve a later hook owner.
          local foreign=function()return 'foreign'end;update=foreign
          phase='succeeded';clock=.2;hooked_update(.2)
          assert(update==foreign and LiveLuaLoader.detach()==true,
            'Capture cleanup overwrote a later update owner')
          local reply=capture.status(job,output_token)
          assert(reply.state=='succeeded'and reply.width==1280 and reply.height==720)
          local reads=statuses;hooked_update(.01)
          assert(statuses==reads and update==foreign)''')


if __name__ == '__main__':
    unittest.main()
