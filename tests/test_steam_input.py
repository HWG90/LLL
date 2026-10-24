"""Steam controller names and the complete Lua 5.1 manager input transitions."""
from pathlib import Path
import os
import struct
import sys
import unittest

from lupa import lua51

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tools'))
from build_steam_release import source


class SteamInput(unittest.TestCase):
    def setUp(self):
        self.previous = Path.cwd()
        os.chdir(ROOT)
        self.lua = lua51.LuaRuntime(encoding=None)

    def tearDown(self):
        os.chdir(self.previous)

    def test_documented_punctuation_names_and_frame_cache(self):
        lua = self.lua
        lua.execute(b'''local names={'semicolon','equal','comma','minus','period','slash',
            'backtick','open bracket','backslash','close bracket','quote','f8'}
          values,ids,reads={}, {},0
          for index,name in ipairs(names) do ids[name]=index+1000 end
          local sr={Keyboard={button_id=function(name)return ids[name]end,
              button=function(id)reads=reads+1;return values[id] or 0 end},
            Mouse={button_id=function()end,axis_id=function()end}}
          input=assert(loadstring(...))().new(sr)
          local codes={186,187,188,189,190,191,192,219,220,221,222,119}
          for index,code in ipairs(codes) do
            values[ids[names[index]]]=1;input.frame()
            assert(input.down(code), 'Unreachable key: '..names[index])
            local count=reads
            assert(input.down(code) and reads==count, 'Repeated same-frame controller read')
            values[ids[names[index]]]=0;input.frame()
            assert(not input.down(code), 'Released key stayed down')
          end
          values[ids.f8]=true;input.frame();assert(input.down(119))
          values[ids.f8]=false;input.frame();assert(not input.down(119))
          local count=reads
          assert(not input.down(7) and reads==count, 'Unmapped key queried the device')
          ''', (ROOT / 'src/steam/input.lua').read_bytes())

    def test_external_pointer_snapshot_scaling_buttons_wheel_and_release(self):
        self.lua.execute(b'''snapshots=0;releases=0;pointer_valid=true
          local sr={Keyboard={button_id=function()end},
            Mouse={button_id=function()end,axis_id=function()end,
              button=function()error('Frozen engine mouse must not be read')end,
              axis=function()error('Frozen engine mouse must not be read')end},
            Gui={resolution=function()return 3840,2160 end}}
          local platform={pointer_snapshot=function()
            snapshots=snapshots+1
            return {valid=pointer_valid,x=123,y=456,width=1920,height=1080,buttons=31,wheel=-120}
          end,release_pointer=function()releases=releases+1;return true end}
          local input=assert(loadstring(...))().new(sr,platform)
          input.visible(true);input.frame()
          for _,code in ipairs({1,2,4,5,6})do assert(input.down(code), 'External button bit was lost')end
          local x,y=input.mouse()
          assert(x==246 and y==1248, 'Client top-left coordinates were not scaled into bottom-left GUI coordinates')
          assert(input.wheel()==-120 and input.wheel()==0, 'Wheel delta must be consumed once per frame')
          input.mouse();input.down(1)
          assert(snapshots==1, 'Pointer callbacks repeated the same-frame service exchange')
          pointer_valid=false;input.frame()
          for _,code in ipairs({1,2,4,5,6})do assert(not input.down(code), 'Foreign foreground supplied a button')end
          assert(input.mouse()==nil and input.wheel()==0 and snapshots==2)
          input.visible(false);input.release();input.frame()
          assert(input.mouse()==nil and input.wheel()==0 and snapshots==2 and releases==1,
            'Hidden manager retained or repeatedly queried the pointer reader')
          input.visible(true);pointer_valid=true;input.frame()
          assert(input.down(1) and snapshots==3)
          input.release();assert(releases==2, 'Reopened pointer reader was not released')
          ''', (ROOT / 'src/steam/input.lua').read_bytes())

    def test_keyboard_capture_uses_one_private_sample_and_never_engine_fallback(self):
        self.lua.execute(b'''local function bits(codes)
            local bytes={};for i=1,32 do bytes[i]=0 end
            for _,code in ipairs(codes)do local at=math.floor(code/8)+1;bytes[at]=bytes[at]+2^(code%8)end
            local text={};for i=1,32 do text[i]=string.char(bytes[i])end;return table.concat(text)
          end
          local mask=bits({16,45,87,160,161})
          local engine_w,engine_reads,snapshots,releases=0,0,0,0
          local sample={valid=true,x=10,y=20,width=100,height=100,buttons=0,wheel=0,
            keyboard_active=true,keyboard_state=2,keyboard_mask=mask,keyboard_keys=bits({45,87,161})}
          local sr={Keyboard={button_id=function(name)return ({w=87,f12=123})[name]end,
              button=function(id)engine_reads=engine_reads+1;return id==87 and engine_w or id==123 and 1 or 0 end},
            Mouse={button_id=function()end,axis_id=function()end},Gui={resolution=function()return 100,100 end}}
          local platform={keyboard_capture_mask=mask,pointer_snapshot=function()snapshots=snapshots+1;return sample end,
            release_pointer=function()releases=releases+1;return true end}
          local input=assert(loadstring(...))().new(sr,platform)
          input.visible(true);input.frame()
          assert(input.down(87)and input.down(45)and input.down(161)and not input.down(160))
          input.down(87);input.mouse();input.wheel()
          assert(snapshots==1 and engine_reads==0,'Captured keys repeated IPC or read frozen engine state')
          assert(input.down(123)and engine_reads==1,'Uncaptured OS key lost its legacy reader')
          engine_w=1;sample.keyboard_keys=bits({});input.frame()
          assert(not input.down(87)and snapshots==2 and engine_reads==1)
          sample.valid=false;sample.keyboard_state=1;sample.keyboard_active=false;input.frame()
          assert(not input.down(87)and snapshots==3 and engine_reads==1,'ARMING leaked engine input')
          sample.valid=true;sample.keyboard_state=3;sample.keyboard_active=true;sample.keyboard_keys=bits({87});input.frame()
          assert(not input.down(87)and engine_reads==1,'Revoked lease used old keys or engine fallback')
          sample.keyboard_state=2;sample.keyboard_mask=bits({});input.frame()
          assert(not input.down(87)and engine_reads==1,'Foreign mask supplied input')
          input.visible(false);input.frame()
          local before=snapshots
          assert(input.down(87)and engine_reads==2 and snapshots==before and releases==1,
            'Hidden frontend retained native capture or polled helper')
          ''', (ROOT / 'src/steam/input.lua').read_bytes())

    def test_failed_capture_release_stays_idle_until_explicit_cleanup(self):
        self.lua.execute(b'''local reads,releases=0,0
          local sr={Keyboard={button_id=function()end},Mouse={button_id=function()end,axis_id=function()end}}
          local platform={pointer_snapshot=function()reads=reads+1;return {valid=true,buttons=0}end,
            release_pointer=function()releases=releases+1;return releases>1 end}
          local input=assert(loadstring(...))().new(sr,platform)
          input.visible(true);input.frame();assert(not input.down(1)and reads==1)
          assert(not pcall(input.visible,false)and releases==1)
          input.release(false)
          for i=1,30 do input.frame();input.visible(false)end
          assert(releases==1 and reads==1,'Hidden failed capture repeatedly attempted backend cleanup')
          input.release();assert(releases==2)
          input.release();assert(releases==2,'Retired reader repeated explicit cleanup')
          input.visible(true);input.frame();input.down(1)
          input.release(true);input.release()
          assert(releases==2,'Previously acknowledged release repeated backend I/O')
          ''', (ROOT / 'src/steam/input.lua').read_bytes())

    def start_manager(self, width=1920, height=1080, saved_key=None, native_keyboard=False):
        lua = self.lua
        lua.globals()[b'viewport_width'] = width
        lua.globals()[b'viewport_height'] = height
        lua.globals()[b'fixture_loader_config'] = (
            ('return {manager_ui={menu_toggle_key=%d}}' % saved_key).encode()
            if saved_key is not None else (b'return {manager_native_keyboard=true}' if native_keyboard else None))
        lua.execute(b'''clock=0;f8=false;delete_down=false;insert_down=false;focused=true;mouse_focused=true;cursor=false;clipped=false
          draws=0;destroyed=0;next_id=0;key_reads=0;focus_reads=0;reports={}
          mouse_x=0;mouse_y=0;left_down=0;right_down=0;middle_down=0;wheel_y=0
          pointer_valid=true;pointer_snapshots=0;pointer_releases=0;engine_mouse_reads=0
          client_width=viewport_width/2;client_height=viewport_height/2
          print=function(...)reports[#reports+1]=table.concat({...},' ')end
          stingray={
            Application={can_get=function()return false end,main_world=function()return 1 end,
              worlds=function()return {1}end},
            Keyboard={button_id=function(name)return ({f8=8119,delete=8046,insert=8045})[name]end,
              button=function(id)
                assert(id==8119 or id==8046 or id==8045);key_reads=key_reads+1
                return ((id==8119 and f8)or(id==8046 and delete_down)or(id==8045 and insert_down))and 1 or 0
              end},
            Mouse={RAW=7,button_id=function(name)return ({left=0,right=1,middle=2})[name]end,
              button=function(id)
                engine_mouse_reads=engine_mouse_reads+1
                if not mouse_focused then return 0 end
                return ({[0]=left_down,[1]=right_down,[2]=middle_down})[id] or 0
              end,
              axis_id=function(name)return ({cursor=2,wheel=1})[name]end,
              axis=function(id)
                engine_mouse_reads=engine_mouse_reads+1
                -- The Steam session leaves these states frozen after releasing mouse focus.
                if not mouse_focused then return {x=-300,y=-700}end
                if id==2 then return {x=mouse_x,y=mouse_y}end
                return {x=0,y=wheel_y}
              end},
            Window={has_focus=function()focus_reads=focus_reads+1;return focused end,
              mouse_focus=function()return mouse_focused end,show_cursor=function()return cursor end,
              clip_cursor=function()return clipped end,set_mouse_focus=function(v)mouse_focused=v end,
              set_show_cursor=function(v)cursor=v end,set_clip_cursor=function(v)clipped=v end},
            Gui={resolution=function()return viewport_width,viewport_height end,
              rect=function()draws=draws+1;next_id=next_id+1;return next_id end,
              text=function()draws=draws+1;next_id=next_id+1;return next_id end,
              destroy_rect=function()end,destroy_text=function()end},
            World={create_screen_gui=function()return 1 end,destroy_gui=function()destroyed=destroyed+1 end},
            Vector2=function(x,y)return {x=x,y=y}end,Vector3=function(x,y,z)return {x=x,y=y,z=z}end,
            Color=function(...)return {...}end}
          ''')
        platform = '''return {data="data",live="live",settings="settings",loader_config="config",
          revision="Steam-input-fixture",runtime="Lua 5.1",native_ffi=false,
          hash=function()return "unused"end,now=function()return clock end,
          guard=function()return {supported=true,jit_supported=false}end,open_log=function()end,
          files=function()return fixture_mod_source and {'client.lua'} or {}end,
          read=function(path)
            if path=='config'then return fixture_loader_config end
            if path=='live/client.lua'then return fixture_mod_source end
          end,write=function()return true end,
          pointer_snapshot=function()
            pointer_snapshots=pointer_snapshots+1
            return {valid=pointer_valid and focused,x=mouse_x*client_width/viewport_width,
              y=(viewport_height-mouse_y)*client_height/viewport_height,
              width=client_width,height=client_height,
              buttons=left_down+2*right_down+4*middle_down,wheel=wheel_y*120}
          end,
          release_pointer=function()pointer_releases=pointer_releases+1;return true end}'''
        stock = b'update=function()end;shutdown=function()end'
        assembled = source(struct.pack('<II', len(stock), 1) + stock, 'fixture_pipe', platform)
        # Compile the same assembled frontend and startup code as the release builder.
        lua.execute(b'assert(loadstring(...))()', assembled)
        lua.execute(b'''local production_update=update
          update=function(...)
            local before=pointer_snapshots
            local function pack(...)return {n=select('#',...),...}end
            local result=pack(production_update(...))
            assert(pointer_snapshots-before<=1, 'Manager queried the pointer service more than once in one frame')
            return unpack(result,1,result.n)
          end''')

    def publish_mcm(self, global_key=46):
        self.lua.globals()[b'mcm_binding_key'] = global_key
        self.lua.execute(b'''binding_queries=0;mcm_close_calls=0;mcm_open=false;mcm_token=nil
          local service=LiveLuaLoader.input_service
          local provider={shared_input_service=service}
          function provider.is_open()return mcm_open end
          function provider.input_status()
            return {active=mcm_token~=nil and service.owns(mcm_token),pending_restore=false,
              owner=mcm_token and 'DBF MCM' or nil}
          end
          function provider.close()
            mcm_close_calls=mcm_close_calls+1;mcm_open=false
            if mcm_token then assert(service.release(mcm_token));mcm_token=nil end
            return true
          end
          function provider.menu_binding_status()
            binding_queries=binding_queries+1
            if binding_behavior=='throw' then error('Status unavailable')end
            if binding_behavior=='non-table' then return true end
            if binding_behavior=='malformed-key' then return {global_key=tostring(mcm_binding_key)}end
            return {focused=focused,editing=false,global_key=mcm_binding_key}
          end
          DBFMCM=provider
          mcm_registration=assert(service.register_frontend('mcm',provider))
          function select_loader_key(key)
            assert(dofile('src/ui/preferences.lua').set(LiveLuaLoader,'menu_toggle_key',key))
          end''')

    def test_shared_delete_edge_closes_mcm_without_opening_loader_in_same_frame(self):
        self.lua.execute(b'''fixture_mod_source="return {live_lua_api=1,on_update=function()if _G.mcm_frame then mcm_frame()end end,on_disable=function()return true end}"''')
        self.start_manager()
        self.publish_mcm()
        self.lua.execute(b'''select_loader_key(46)
          local service=LiveLuaLoader.input_service;local held=false
          mcm_frame=function()
            if delete_down and not held then
              if mcm_open then assert(DBFMCM.close())
              else
                assert(LiveLuaLoader.close_manager());mcm_open=true
                mcm_token=assert(service.acquire('DBF MCM','menu',mcm_registration))
              end
            end
            held=delete_down
          end
          update(.01)
          local focus_before=focus_reads
          for i=1,40 do update(.01)end
          assert(binding_queries==0 and focus_reads==focus_before,'Hidden idle added binding/focus reads')
          delete_down=true;update(.01)
          assert(mcm_open and service.status().frontend=='mcm' and draws==0 and binding_queries==1)
          for i=1,20 do update(.01)end
          assert(binding_queries==1 and draws==0,'Held MCM shortcut was queried or opened LLL')
          delete_down=false;update(.01);delete_down=true;update(.01)
          assert(not mcm_open and not service.status().owner and draws==0 and binding_queries==2,
            'MCM closed and released, then LLL opened on the same Delete edge')
          for i=1,20 do update(.01)end
          assert(draws==0 and binding_queries==2)
          -- Explicit opening is available even when the shared physical key is held.
          LiveLuaLoader.open_manager();update(.01)
          assert(draws>0 and LiveLuaLoader.input_status().active and binding_queries==2)
          -- Repeat after initialization: the shared menu's internal toggle path must defer too.
          delete_down=false;update(.01);delete_down=true;update(.01)
          assert(mcm_open and service.status().frontend=='mcm' and binding_queries==3)
          local before=draws
          delete_down=false;update(.01);delete_down=true;update(.01)
          assert(not mcm_open and not service.status().owner and draws==before and binding_queries==4,
            'An initialized LLL menu reopened on MCM close')
          for i=1,20 do update(.01)end
          assert(draws==before and binding_queries==4)
        ''')

    def test_engine_keyboard_manager_ignores_unused_native_capture_mask(self):
        original_source = globals()['source']
        def masked_source(stock, pipe, platform, *args, **kwargs):
            platform = 'local P=' + platform.removeprefix('return ') + """
              P.keyboard_capture_mask=string.rep(string.char(255),32)
              P.keyboard_prepare=function()error('Engine manager must not acquire keyboard')end
              P.keyboard_acquire=function()error('Unexpected keyboard acquire')end
              P.keyboard_snapshot=function()error('Unexpected keyboard sample')end
              P.keyboard_release=function()error('Unexpected keyboard release')end
              return P"""
            return original_source(stock,pipe,platform,*args,**kwargs)
        globals()['source']=masked_source
        try:
            self.start_manager()
        finally:
            globals()['source']=original_source
        self.lua.execute(b'''update(.01);insert_down=true;update(.01);update(.01)
          assert(LiveLuaLoader.input_status().active)
          insert_down=false;update(.01);insert_down=true;update(.01)
          assert(not LiveLuaLoader.input_status().active,
            'Pointer-only manager sample masked the engine close key')
          for i=1,10 do update(.01)end
          assert(not LiveLuaLoader.input_status().active,'Held close key reopened manager')
          insert_down=false;update(.01);insert_down=true;update(.01);update(.01)
          assert(LiveLuaLoader.input_status().active,'Manager failed to reopen')
        ''')

    def test_default_insert_loader_binding_is_independent_of_mcm_delete(self):
        self.start_manager()
        self.publish_mcm()
        self.lua.execute(b'''assert(LiveLuaLoader.get_loader_option('manager_ui')==nil,'Fresh startup wrote a shortcut migration')
          assert(dofile('src/ui/preferences.lua').get(LiveLuaLoader).menu_toggle_key==45)
          update(.01)
          for i=1,30 do update(.01)end
          assert(binding_queries==0)
          insert_down=true;update(.01);update(.01)
          assert(LiveLuaLoader.input_status().active and binding_queries==1 and not mcm_open)
          for i=1,20 do update(.01)end
          assert(binding_queries==1,'Held Insert repeatedly queried MCM binding')
          insert_down=false;update(.01);insert_down=true;update(.01)
          assert(not LiveLuaLoader.input_status().active and binding_queries==2)
          for i=1,20 do update(.01)end
          assert(binding_queries==2 and mouse_focused and not cursor and not clipped)
        ''')

    def test_shared_hotkey_deference_lasts_until_release_when_binding_changes(self):
        self.start_manager(saved_key=119)
        self.publish_mcm(119)
        self.lua.execute(b'''update(.01);f8=true;update(.01)
          assert(draws==0 and binding_queries==1)
          mcm_binding_key=46
          for i=1,30 do update(.01)end
          assert(draws==0 and binding_queries==1,'Binding change reinterpreted a held shared key')
          f8=false;update(.01);f8=true;update(.01);update(.01)
          assert(LiveLuaLoader.input_status().active and binding_queries==2)
        ''')

    def test_failing_or_malformed_binding_status_preserves_existing_owner_gates(self):
        for mode in ('throw', 'non-table', 'malformed-key', 'missing', 'foreign-provider'):
            with self.subTest(mode=mode):
                self.lua = lua51.LuaRuntime(encoding=None)
                self.start_manager(saved_key=119)
                self.publish_mcm(119)
                self.lua.globals()[b'binding_behavior'] = mode.encode()
                self.lua.execute(b'''if binding_behavior=='missing'then DBFMCM.menu_binding_status=nil end
                  if binding_behavior=='foreign-provider'then DBFMCM=17 end
                  update(.01);f8=true;update(.01);update(.01)
                  if binding_behavior=='foreign-provider'then
                    assert(draws==0 and not LiveLuaLoader.input_status().active and binding_queries==0,
                      'Malformed provider bypassed the existing input ownership gate')
                  else
                    assert(LiveLuaLoader.input_status().active,'Failed binding query changed existing closed-MCM behavior')
                    assert(binding_queries==(binding_behavior=='missing'and 0 or 1))
                  end
                  local before=binding_queries
                  for i=1,20 do update(.01)end
                  assert(binding_queries==before,'Failed status introduced held-key polling')
                ''')

    def test_binding_query_cannot_claim_for_a_replaced_provider_or_foreign_lease(self):
        self.start_manager(saved_key=119)
        self.publish_mcm(46)
        self.lua.execute(b'''local service=LiveLuaLoader.input_service
          local token=assert(service.acquire('photo','menu'))
          update(.01);f8=true;update(.01);f8=false;update(.01)
          assert(service.owns(token)and draws==0 and pointer_releases==0 and binding_queries==1,
            'Nonmatching MCM binding bypassed a foreign input lease')
          assert(service.release(token))
          local replacement={is_open=function()return false end,
            input_status=function()return {active=false,pending_restore=false}end,
            close=function()return true end}
          DBFMCM.menu_binding_status=function()
            binding_queries=binding_queries+1;DBFMCM=replacement
            return {global_key=119}
          end
          f8=true;update(.01);update(.01)
          assert(LiveLuaLoader.input_status().active and binding_queries==2,
            'An unpublished provider claimed the hotkey after replacing itself')
        ''')

    def test_complete_manager_f8_hold_close_reopen_and_focus_restoration(self):
        self.start_manager(saved_key=119)
        lua = self.lua
        lua.execute(b'''assert(LiveLuaLoader.get_loader_option('manager_ui').menu_toggle_key==119,'Saved F8 binding was migrated')
          update(.01);assert(draws==0 and not LiveLuaLoader.input_status().active)
          local count=key_reads
          for frame=1,20 do update(.01)end
          assert(key_reads-count==20 and draws==0 and pointer_snapshots==0 and pointer_releases==0,
            'Hidden UI performed extra input/render/service work')
          f8=true;update(.01);update(.01)
          assert(draws>0 and LiveLuaLoader.input_status().active and cursor and not mouse_focused)
          for frame=1,4 do update(.01)end
          assert(LiveLuaLoader.input_status().active, 'Held shortcut toggled repeatedly')
          f8=false;update(.01);f8=true;update(.01);update(.01)
          assert(not LiveLuaLoader.input_status().active and mouse_focused and not cursor and not clipped)
          assert(destroyed>0, 'Hidden manager retained its GUI')
          local hidden_count=pointer_snapshots
          for frame=1,5 do update(.01)end
          assert(pointer_snapshots==hidden_count and pointer_releases==1,
            'Hidden frames did not leave the pointer service idle')
          f8=false;update(.01);f8=true;update(.01);update(.01)
          assert(LiveLuaLoader.input_status().active)
          local blur_key_reads=key_reads
          focused=false;update(.01)
          assert(not LiveLuaLoader.input_status().active and mouse_focused and not cursor and not clipped)
          assert(pointer_releases==2, 'Focus loss did not release the pointer reader once')
          for frame=1,10 do update(.01)end
          assert(key_reads==blur_key_reads,'Blurred manager added keyboard polling')
          focused=true;f8=false;update(.01)
          assert(not LiveLuaLoader.input_status().active, 'Refocusing reopened the manager')
          f8=true;update(.01);update(.01)
          assert(LiveLuaLoader.input_status().active, 'Manager did not reopen after losing focus')
          shutdown()
          assert(mouse_focused and not cursor and not clipped and pointer_releases==3)
          ''')

    def test_shared_service_published_before_mod_enable_and_isolated_from_manager(self):
        self.lua.execute(b'''fixture_mod_source="return {live_lua_api=1,on_enable=function() assert(LiveLuaLoader.input_service==CowboyBingusModLoader.input_service);assert(LiveLuaLoader.input_service.version==1);service_seen_during_enable=true end,on_disable=function()return true end}"''')
        self.start_manager(saved_key=119)
        self.lua.execute(b'''assert(service_seen_during_enable and LiveLuaLoader.capabilities.shared_input)
          local s=LiveLuaLoader.input_service
          local token=assert(s.acquire('photo','menu'))
          assert(not mouse_focused and cursor and clipped and s.owns(token))
          assert(LiveLuaLoader.input_status().owner=='photo','Shared owner hidden from MCM before manager initializes')
          for i=1,4 do update(.01)end
          assert(pointer_snapshots==0,'An unused external lease queried the helper')
          assert(LiveLuaLoader.close_manager())
          assert(pointer_releases==0 and s.owns(token),'Hidden manager released another owner')
          assert(s.snapshot(token).valid and pointer_snapshots==1)
          assert(LiveLuaLoader.close_manager())
          assert(pointer_releases==0 and s.owns(token))
          f8=true;update(.01);f8=false;update(.01)
          assert(s.owns(token))
          assert(pointer_releases==0,'F8 stopped the external pointer owner')
          focused=false;update(.01)
          assert(not s.owns(token) and mouse_focused and not cursor and not clipped)
          assert(pointer_releases==1)
          local calls=pointer_snapshots
          assert(s.snapshot(token)==nil and not s.release(token))
          update(.01);assert(pointer_snapshots==calls,'Revoked token queried the helper')''')

    def test_keyboard_failure_closes_composed_ui_and_requires_explicit_acknowledged_recovery(self):
        original_source = globals()['source']

        def keyboard_source(stock, pipe, platform, *args, **kwargs):
            platform = 'local P=' + platform.removeprefix('return ') + '''
              local bytes={};for i=1,32 do bytes[i]=0 end
              bytes[6]=32
              local text={};for i=1,32 do text[i]=string.char(bytes[i])end
              P.keyboard_capture_mask=table.concat(text)
              keyboard_reads=0;keyboard_releases=0;keyboard_acquires=0
              keyboard_fail=false;keyboard_release_ok=true
              local owned
              P.keyboard_prepare=function()assert(not owned);owned={};return owned end
              P.keyboard_acquire=function(handle)
                assert(handle==owned);keyboard_acquires=keyboard_acquires+1;return true
              end
              P.keyboard_snapshot=function(handle,mode)
                assert(handle==owned and mode=='menu');keyboard_reads=keyboard_reads+1
                if keyboard_fail then return nil,'Fixture keyboard connection lost'end
                local value=P.pointer_snapshot()
                local keys={};for i=1,32 do keys[i]=string.char(i==6 and insert_down and 32 or 0)end
                value.keyboard_keys=table.concat(keys);value.keyboard_mask=P.keyboard_capture_mask
                value.keyboard_state=2;value.keyboard_active=true;value.keyboard_generation=keyboard_acquires
                return value
              end
              P.keyboard_release=function(handle)
                assert(handle==owned);keyboard_releases=keyboard_releases+1
                if not keyboard_release_ok then return false,'Fixture unregister acknowledgement lost'end
                owned=nil;return true
              end
              return P'''
            return original_source(stock, pipe, platform, *args, **kwargs)

        globals()['source'] = keyboard_source
        try:
            self.start_manager(native_keyboard=True)
        finally:
            globals()['source'] = original_source
        self.lua.execute(b'''local function upvalue(fn,wanted)
            for index=1,100 do
              local name,value=debug.getupvalue(fn,index)
              if name==wanted then return value end
              if not name then break end
            end
            error('Missing integration observation point: '..wanted)
          end
          update(.01);left_down=1;insert_down=true;update(.01);update(.01)
          for i=1,3 do update(.01)end
          assert(keyboard_acquires==1 and keyboard_releases==0,
            'Pending open repeatedly acquired/released native capture while waiting for a mouse release')
          left_down=0;insert_down=false;update(.01)
          local ui=upvalue(LiveLuaLoader.open_manager,'self')
          local driver=upvalue(ui.close,'input_driver')
          assert(ui.menu.visible and LiveLuaLoader.input_status().active and keyboard_acquires==1)
          insert_down=true;keyboard_fail=true;keyboard_release_ok=false;update(.01)
          assert(not ui.menu.visible and not ui.open_pending and driver.manager_failure(),
            'Keyboard failure left an unresponsive visible manager')
          assert(keyboard_releases==1,'One UI error attempted native keyboard retirement twice')
          assert(LiveLuaLoader.input_status().owner=='lll'and not mouse_focused and cursor and clipped,
            'Unacknowledged native keyboard retirement discarded cursor ownership')
          local reads,releases,draw_count=keyboard_reads,keyboard_releases,draws
          -- The engine can first report zero, then repeat a physically held key
          -- after native unregister. Neither half may automatically reopen.
          insert_down=false;for i=1,10 do update(.01)end
          insert_down=true;for i=1,20 do update(.01)end
          assert(keyboard_reads==reads and keyboard_releases==releases and draws==draw_count,
            'Held shortcut reopened a failed manager or repeated hidden backend/rendering work')
          insert_down=false;update(.01)
          assert(not pcall(LiveLuaLoader.open_manager)and keyboard_releases==releases+1,
            'Explicit reopen did not make exactly one acknowledged-cleanup attempt')
          assert(not ui.menu.visible and driver.manager_failure())
          keyboard_release_ok=true;keyboard_fail=false
          LiveLuaLoader.open_manager();update(.01)
          assert(not driver.manager_failure()and ui.menu.visible and LiveLuaLoader.input_status().active
              and keyboard_acquires==2,'Manager did not recover after explicit retirement acknowledgement')
          assert(LiveLuaLoader.close_manager())
          assert(mouse_focused and not cursor and not clipped and not driver.manager_failure())
          shutdown()
          ''')

    def test_composed_menu_click_drag_wheel_and_reopened_pointer(self):
        # Non-unit scale catches tests that mistakenly feed logical menu coordinates.
        self.start_manager(3840, 2160)
        self.lua.execute(b'''update(.01);insert_down=true;update(.01);update(.01);insert_down=false;update(.01)
          local function upvalue(fn,wanted)
            for index=1,100 do
              local name,value=debug.getupvalue(fn,index)
              if not name then break end
              if name==wanted then return value end
            end
            error('Missing fixture observation point: '..wanted)
          end
          local ui=upvalue(LiveLuaLoader.open_manager,'self')
          local menu=assert(ui.menu)
          local controls={{id='action',type='button',label='Pointer action',button_label='Run pointer action',
            on_activate=function()clicks=clicks+1 end}}
          for index=1,80 do controls[#controls+1]={id='row'..index,type='toggle',label='Scrollable row '..index,default=false}end
          clicks=0
          ui.api.register({id='mouse_contract',name='Mouse contract',pages={{id='main',name='Pointer tests',require_confirmation=false,controls=controls}}})
          for index,entry in ipairs(ui.api.list())do
            if entry.id=='mouse_contract' then menu.selected=index;break end
          end
          menu.page=1;menu.row=1;menu.focus='settings';menu.scroll=0
          local compose=menu.compose
          menu.compose=function(...)last_commands=compose(...);return last_commands end
          update(.01)
          local function point_at_button()
            for _,command in ipairs(last_commands)do
              if command.control_id=='mouse_contract/action' and command.indicator_kind=='button_label' then
                -- Use a point within the label of the actual composed button.
                local scale=menu.parent_geometry.scale
                mouse_x,mouse_y=command.x+20*scale,command.y+6*scale
                return
              end
            end
            error('Pointer action was not rendered')
          end
          local function click_button(expected)
            point_at_button();left_down=0;update(.01)
            assert(menu.pointer_x==mouse_x and menu.pointer_y==mouse_y, 'Cursor did not reach rendered GUI coordinates')
            left_down=1;update(.01)
            assert(clicks==expected, 'Click on the composed button did not invoke its action')
            for frame=1,3 do update(.01)end
            assert(clicks==expected, 'Held mouse button activated repeatedly')
            left_down=0;update(.01)
          end
          click_button(1)
          assert(engine_mouse_reads==0, 'Visible manager read the disabled engine mouse')
          point_at_button();pointer_valid=false;left_down=1;wheel_y=-1
          local before_invalid_scroll=menu.scroll
          for frame=1,3 do update(.01)end
          assert(clicks==1 and menu.scroll==before_invalid_scroll and menu.pointer_x==nil,
            'Invalid or foreign-foreground pointer data activated the manager')
          left_down=0;wheel_y=0;pointer_valid=true;update(.01)
          local before=menu.parent_geometry
          mouse_x,mouse_y=before.x+100*before.scale,before.y+(before.height-30)*before.scale
          update(.01);left_down=1;update(.01)
          mouse_x,mouse_y=mouse_x+70,mouse_y+40;update(.01)
          left_down=0;update(.01)
          assert(menu.window_x==before.x+70 and menu.window_y==before.y+40,
            'Dragging the rendered title bar did not move the manager in physical pixels')
          local moved=menu.parent_geometry
          mouse_x,mouse_y=moved.x+(moved.width-200)*moved.scale,moved.y+300*moved.scale
          wheel_y=-1;update(.01);wheel_y=0;update(.01)
          assert(menu.scroll==3, 'Mouse wheel over the composed settings pane did not scroll')
          insert_down=true;update(.01)
          assert(not LiveLuaLoader.input_status().active and mouse_focused and not cursor and not clipped)
          local hidden_count=pointer_snapshots
          for frame=1,5 do update(.01)end
          assert(pointer_snapshots==hidden_count and pointer_releases==1)
          insert_down=false;update(.01);insert_down=true;update(.01);insert_down=false;update(.01)
          assert(LiveLuaLoader.input_status().active, 'Mouse manager did not reopen')
          wheel_y=1;update(.01);wheel_y=0;update(.01)
          assert(menu.scroll==0, 'Reopened manager did not accept mouse wheel input')
          click_button(2)
          focused=false;update(.01)
          assert(not LiveLuaLoader.input_status().active and mouse_focused and not cursor and not clipped)
          hidden_count=pointer_snapshots
          for frame=1,5 do update(.01)end
          assert(pointer_snapshots==hidden_count and pointer_releases==2)
          focused=true;insert_down=false;update(.01);insert_down=true;update(.01);insert_down=false;update(.01)
          click_button(3)
          shutdown()
          assert(mouse_focused and not cursor and not clipped and pointer_releases==3 and engine_mouse_reads==0)
          ''')


if __name__ == '__main__':
    unittest.main()
