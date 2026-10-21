"""Keyboard op16-18 framing and uncertain ownership, using a fake pipe peer."""
from pathlib import Path
import unittest
from lupa import lua51

ROOT=Path(__file__).resolve().parents[1]
FIXTURE=b'''
function word(n)n=n%4294967296;return string.char(n%256,math.floor(n/256)%256,math.floor(n/65536)%256,math.floor(n/16777216)%256)end
function u32(s,at)local a,b,c,d=s:byte(at,at+3);return a+b*256+c*65536+d*16777216 end
function fields(...)local out={};for i=1,select('#',...)do out[i]=word(select(i,...))end;return table.concat(out)end
function lp(s)return word(#s)..s end
requests={};state=2;generation=71;native_client=nil;keys=string.rep('K',32)
local function responder(op,nonce,extra)
 if fail_header==op then return fields(nonce,87)end
 if op==16 then
  assert(#extra==40 and u32(extra,1)==1)
  native_client=u32(extra,5);native_mask=extra:sub(9)
  if fail_acquire then error('Acquisition acknowledgement lost after native acceptance')end
  return fields(nonce,0,reply_version or 1,reply_client or native_client,generation,state)..(reply_mask or native_mask)
 elseif op==17 then
  assert(#extra==12 and u32(extra,1)==native_client and u32(extra,5)==generation)
  sample_mode=u32(extra,9);assert(sample_mode==0 or sample_mode==1)
  local pointer=state==2 and fields(1,-12,34,1920,1080,3,-120,7,-9)or string.rep(string.char(0),36)
  return fields(nonce,0)..pointer..fields(reply_version or 1,reply_generation or generation,state)..(state==2 and keys or string.rep(string.char(0),32))
 elseif op==18 then
  assert(#extra==8);release_client=u32(extra,1);release_generation=u32(extra,5)
  if fail_release then error('Release acknowledgement lost')end
  return fields(nonce,0,reply_version or 1,reply_client or release_client,
   reply_generation or (native_client==release_client and generation or 0))
 end
 error('Unexpected operation: '..op)
end
LLL_STEAM_SERVICE={pipe='fixture_keyboard'}
LLL_STEAM_BUILDS={exe_sha256='fixture',game_sha256='fixture'}
stingray={Application={process_id=function()return 77 end,time_since_launch=function()return 0 end}}
LLL_STEAM_TRANSPORT=function()
 return {failure=function()end,on_failure=function()end,exchange=function(bytes)
  local nonce,op,length=u32(bytes,1),u32(bytes,5),u32(bytes,9)
  if op==0 then return fields(0,0,77)..lp('fixture.exe')..lp('fixture_root')end
  if op==3 then return fields(nonce,0)end
  local path=bytes:sub(13,12+length);assert(path=='keyboard-v1')
  local extra=bytes:sub(13+length);requests[#requests+1]={op=op,extra=extra}
  return responder(op,nonce,extra)
 end}
end
'''


class KeyboardTransport(unittest.TestCase):
    def setUp(self):
        self.lua=lua51.LuaRuntime(encoding=None)
        self.lua.execute(FIXTURE)
        self.lua.globals()[b'P']=self.lua.execute((ROOT/'src/steam/platform.lua').read_bytes())

    def check(self,text):
        self.lua.execute(text.encode())

    def test_exact_mask_combined_snapshot_and_no_io_prepare_or_stale_handles(self):
        self.check('''assert(#P.keyboard_capture_mask==32 and #requests==0)
          local handle=assert(P.keyboard_prepare());assert(#requests==0)
          assert(not P.keyboard_prepare()and not P.keyboard_acquire({})and #requests==0)
          assert(P.keyboard_acquire(handle)and #requests==1 and requests[1].op==16)
          assert(native_mask==P.keyboard_capture_mask and u32(requests[1].extra,5)==1)
          assert(P.keyboard_acquire(handle)and #requests==1,'Acknowledged acquisition was repeated')
          local sample=assert(P.keyboard_snapshot(handle,'camera'))
          assert(sample.valid and sample.keyboard_active and sample.keyboard_state==2 and sample.keyboard_generation==71)
          assert(sample.x==-12 and sample.y==34 and sample.wheel==-120 and sample.dx==7 and sample.dy==-9 and sample_mode==1)
          assert(sample.keyboard_keys==keys and sample.keyboard_mask==native_mask)
          assert(not P.keyboard_snapshot({},'menu')and not P.keyboard_release({})and #requests==2)
          assert(P.keyboard_release(handle)and release_client==1 and release_generation==71)
          local second=assert(P.keyboard_prepare());assert(P.keyboard_acquire(second)and native_client==2)
          local count=#requests;assert(not P.keyboard_release(handle)and #requests==count)
          assert(P.keyboard_release(second))''')

    def test_lost_acquire_reply_retains_unknown_generation_cleanup_authority(self):
        self.check('''local handle=assert(P.keyboard_prepare());fail_acquire=true
          assert(not P.keyboard_acquire(handle)and not P.keyboard_prepare())
          local count=#requests;assert(not P.keyboard_acquire(handle)and #requests==count,'Uncertain acquire was retried')
          assert(not P.keyboard_snapshot(handle,'menu')and #requests==count)
          fail_acquire=false;fail_release=true
          assert(not P.keyboard_release(handle)and release_client==1 and release_generation==0)
          assert(not P.keyboard_prepare(),'Uncertain release forgot private ownership')
          fail_release=false;assert(P.keyboard_release(handle))
          assert(P.keyboard_prepare())''')

    def test_wrong_release_ack_and_error_header_cannot_clear_a_live_handle(self):
        for change in ('reply_version=2','reply_client=999','reply_generation=999','fail_header=18'):
            with self.subTest(change=change):
                self.setUp();self.check('local h=assert(P.keyboard_prepare());assert(P.keyboard_acquire(h));handle=h;'+change)
                self.check('''assert(not P.keyboard_release(handle)and not P.keyboard_prepare())
                  reply_version=nil;reply_client=nil;reply_generation=nil;fail_header=nil
                  assert(P.keyboard_release(handle)and P.keyboard_prepare())''')

    def test_arming_terminal_and_changed_mask_are_not_silently_active(self):
        self.check('''state=1;local handle=assert(P.keyboard_prepare());assert(P.keyboard_acquire(handle))
          local pending=assert(P.keyboard_snapshot(handle,'menu'))
          assert(not pending.valid and not pending.keyboard_active and pending.keyboard_state==1 and pending.keyboard_keys==string.rep(string.char(0),32))
          state=3;local revoked=assert(P.keyboard_snapshot(handle,'menu'))
          assert(not revoked.valid and not revoked.keyboard_active and revoked.keyboard_state==3)
          local count=#requests;assert(not P.keyboard_snapshot(handle,'menu')and #requests==count)
          assert(P.keyboard_release(handle))
          local next_handle=assert(P.keyboard_prepare());reply_mask=string.rep(string.char(0),32)
          assert(not P.keyboard_acquire(next_handle),'Native mask substitution was accepted')
          assert(not P.keyboard_prepare());reply_mask=nil;assert(P.keyboard_release(next_handle)and release_generation==0)''')

    def test_never_owned_generation_zero_requires_exact_release_ack(self):
        self.check('''local handle=assert(P.keyboard_prepare());fail_header=18
          assert(not P.keyboard_release(handle)and not P.keyboard_prepare())
          fail_header=nil;assert(P.keyboard_release(handle)and release_generation==0)
          local count=#requests;assert(not P.keyboard_release(handle)and #requests==count)''')


if __name__=='__main__':
    unittest.main()
