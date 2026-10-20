"""Screenshot ownership, bounded active I/O, cancellation, and uncertain replies."""
from pathlib import Path
import unittest
from lupa import lua51

ROOT = Path(__file__).resolve().parents[1]
FIXTURE = b'''
now=0; counts={request=0,status=0,cancel=0}; phase='pending'; backend_error=0
backend_id=string.rep('a',32); fail_request=false;fail_status=false;fail_cancel=false;reject=false
platform={screenshot_directory='C:/Local/LLL/Helldivers2/Screenshots',screenshot_session='test_session',
 now=function()return now end}
function backend_reply()
 return {id=backend_id,state=phase,error=backend_error,width=phase=='succeeded'and 1280 or 0,
  height=phase=='succeeded'and 720 or 0,elapsed_ms=35,output_path=backend_path}
end
platform.screenshot_request=function(path)
 counts.request=counts.request+1;if fail_request then error('pipe closed')end
 if reject then return nil,'Output exists'end
 backend_path=path:gsub('/','\\\\');return backend_reply()
end
platform.screenshot_status=function(id)
 counts.status=counts.status+1;assert(id==string.rep('a',32))
 if fail_status then error('temporary transport failure')end
 return backend_reply()
end
platform.screenshot_cancel=function(id)
 counts.cancel=counts.cancel+1;assert(id==string.rep('a',32))
 if fail_cancel then error('temporary transport failure')end
 return backend_reply()
end
'''


class ScreenshotAPI(unittest.TestCase):
    def setUp(self):
        self.lua=lua51.LuaRuntime(encoding=None)
        self.lua.execute(FIXTURE)
        self.lua.globals()[b'Factory']=self.lua.execute((ROOT/'src/steam/screenshot_service.lua').read_bytes())
        self.lua.execute(b'''service,driver=Factory.new(platform)
            function intent(name)
             return {job_token=assert(service.new_job_token()),output_token='output-'..(name or 'one'),
              output_path=service.output_directory..'/'..(name or 'one')..'.png'}
            end''')

    def check(self,text):self.lua.execute(text.encode())

    def test_idle_and_token_generation_never_call_backend(self):
        self.check('''
         assert(service.version==1 and service.capabilities.async and service.capabilities.game_window)
         assert(not pcall(function()service.capabilities.format='jpeg'end))
         local seen={}
         for i=1,2048 do
          local id=assert(service.new_job_token());assert(not seen[id]);seen[id]=true
          assert(not service.status('unknown','unknown'))
         end
         assert(driver.close())
         assert(counts.request==0 and counts.status==0 and counts.cancel==0)
        ''')

    def test_output_validation_and_latest_unused_token(self):
        self.check('''
         local old=intent();local new=intent()
         assert(not service.request(old))
         for _,name in ipairs({'../bad.png','folder/bad.png','x..png','COM0.png','CON.png','NUL .png','lpt1.png','x.png:stream','x.jpg','x%y.png'})do
          new.output_path=service.output_directory..'/'..name;assert(not service.request(new))
         end
         new.output_path='C:/Other/x.png';assert(not service.request(new))
         assert(counts.request==0)
         new.output_path=service.output_directory..'/War Journalist-2026-10-20.png'
         local r=assert(service.request(new));assert(r.state=='pending')
         assert(not service.request(new));assert(counts.request==1)
        ''')

    def test_status_throttle_and_cached_terminal(self):
        self.check('''
         local j=intent();assert(service.request(j).output_path==j.output_path)
         for i=1,100 do assert(service.status(j.job_token,j.output_token).state=='pending')end
         assert(counts.status==0)
         now=.11;assert(service.status(j.job_token,j.output_token).state=='pending');assert(counts.status==1)
         phase='succeeded';now=.22
         local r=assert(service.status(j.job_token,j.output_token));assert(r.state=='succeeded'and r.width==1280)
         for i=1,100 do
          local copy=service.status(j.job_token,j.output_token);copy.state='tampered'
          assert(service.cancel(j.job_token,j.output_token))
         end
         assert(service.status(j.job_token,j.output_token).state=='succeeded')
         assert(counts.status==2 and counts.cancel==0)
         assert(not service.request(j),'Consumed token reused')
         local next=intent('next');assert(service.request(next))
         assert(not service.status(j.job_token,j.output_token),'Old tuple reached new job')
        ''')

    def test_cancel_is_pending_until_retired_terminal(self):
        self.check('''
         local j=intent();assert(service.request(j))
         assert(not service.cancel('other',j.output_token));assert(counts.cancel==0)
         local done,r=service.cancel(j.job_token,j.output_token)
         assert(not done and r.state=='pending'and r.cancel_requested)
         assert(not driver.close());assert(counts.cancel==1 and counts.status==0)
         phase='cancelled';backend_error=1223;now=.11
         done,r=service.cancel(j.job_token,j.output_token)
         assert(done and r.state=='cancelled'and driver.close())
         assert(counts.cancel==1 and counts.status==1)
        ''')

    def test_publication_winner_may_succeed_after_cancel(self):
        self.check('''
         local j=intent();assert(service.request(j));assert(not service.cancel(j.job_token,j.output_token))
         phase='succeeded';now=.11
         local done,r=service.cancel(j.job_token,j.output_token)
         assert(done and r.state=='succeeded'and r.output_path==j.output_path)
        ''')

    def test_known_id_transport_failure_can_recover_explicitly(self):
        self.check('''
         local j=intent();assert(service.request(j));fail_status=true;now=.11
         assert(service.status(j.job_token,j.output_token).uncertain)
         fail_status=false;phase='succeeded';now=.22
         local r=assert(service.status(j.job_token,j.output_token));assert(r.state=='succeeded'and not r.uncertain)
        ''')

    def test_cancel_failure_retries_only_at_active_bound(self):
        self.check('''
         local j=intent();assert(service.request(j));fail_cancel=true
         local done,r=service.cancel(j.job_token,j.output_token);assert(not done and r.uncertain)
         for i=1,100 do assert(not service.cancel(j.job_token,j.output_token))end
         assert(counts.cancel==1)
         fail_cancel=false;phase='cancelled';now=.11
         assert(service.cancel(j.job_token,j.output_token));assert(counts.cancel==2)
        ''')

    def test_lost_request_ack_is_not_reported_as_rejection(self):
        self.check('''
         local j=intent();fail_request=true
         local r=assert(service.request(j));assert(r.state=='pending'and r.uncertain)
         assert(not service.new_job_token());assert(not service.request(j));assert(not driver.close())
         for i=1,100 do now=now+1;assert(service.status(j.job_token,j.output_token).uncertain)end
         assert(counts.request==1 and counts.status==0 and counts.cancel==0)
        ''')

    def test_explicit_rejection_leaves_no_pending_ownership(self):
        self.check('''
         reject=true;local j=intent();local r,why=service.request(j)
         assert(r==nil and why=='Output exists')
         reject=false;assert(service.request(intent('other')))
        ''')

    def test_close_permanently_refuses_new_admission(self):
        self.check('''
         local unused=intent();assert(driver.close())
         assert(not service.new_job_token());assert(not service.request(unused))
         assert(driver.close());assert(counts.request==0 and counts.status==0 and counts.cancel==0)
        ''')

    def test_close_preserves_pending_cleanup_without_reopening(self):
        self.check('''
         local j=intent();assert(service.request(j));assert(not driver.close())
         assert(not service.new_job_token());assert(not service.request(j));assert(not driver.close())
         assert(counts.cancel==1 and counts.status==0)
         phase='cancelled';backend_error=1223;now=.11
         assert(driver.close());assert(service.status(j.job_token,j.output_token).state=='cancelled')
         assert(not service.new_job_token());assert(not service.request(j));assert(driver.close())
         assert(counts.cancel==1 and counts.status==1)
        ''')

    def test_stale_native_identity_never_finishes_or_changes_id(self):
        self.check('''
         local j=intent();assert(service.request(j));backend_id=string.rep('b',32);now=.11
         local r=service.status(j.job_token,j.output_token);assert(r.state=='pending'and r.uncertain)
         backend_id=string.rep('a',32);phase='cancelled';now=.22
         assert(service.cancel(j.job_token,j.output_token))
        ''')


if __name__=='__main__':unittest.main()
