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

    def start_manager(self, width=1920, height=1080):
        lua = self.lua
        lua.globals()[b'viewport_width'] = width
        lua.globals()[b'viewport_height'] = height
        lua.execute(b'''clock=0;f8=false;focused=true;mouse_focused=true;cursor=false;clipped=false
          draws=0;destroyed=0;next_id=0;key_reads=0;reports={}
          mouse_x=0;mouse_y=0;left_down=0;right_down=0;middle_down=0;wheel_y=0
          pointer_valid=true;pointer_snapshots=0;pointer_releases=0;engine_mouse_reads=0
          client_width=viewport_width/2;client_height=viewport_height/2
          print=function(...)reports[#reports+1]=table.concat({...},' ')end
          stingray={
            Application={can_get=function()return false end,main_world=function()return 1 end,
              worlds=function()return {1}end},
            Keyboard={button_id=function(name)return name=='f8' and 8119 or nil end,
              button=function(id)assert(id==8119);key_reads=key_reads+1;return f8 and 1 or 0 end},
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
            Window={has_focus=function()return focused end,
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
          read=function(path)if path=='live/client.lua'then return fixture_mod_source end end,write=function()return true end,
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

    def test_complete_manager_f8_hold_close_reopen_and_focus_restoration(self):
        self.start_manager()
        lua = self.lua
        lua.execute(b'''update(.01);assert(draws==0 and not LiveLuaLoader.input_status().active)
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
          focused=false;update(.01)
          assert(not LiveLuaLoader.input_status().active and mouse_focused and not cursor and not clipped)
          assert(pointer_releases==2, 'Focus loss did not release the pointer reader once')
          focused=true;f8=false;update(.01)
          assert(not LiveLuaLoader.input_status().active, 'Refocusing reopened the manager')
          f8=true;update(.01);update(.01)
          assert(LiveLuaLoader.input_status().active, 'Manager did not reopen after losing focus')
          shutdown()
          assert(mouse_focused and not cursor and not clipped and pointer_releases==3)
          ''')

    def test_shared_service_published_before_mod_enable_and_isolated_from_manager(self):
        self.lua.execute(b'''fixture_mod_source="return {live_lua_api=1,on_enable=function() assert(LiveLuaLoader.input_service==CowboyBingusModLoader.input_service);assert(LiveLuaLoader.input_service.version==1);service_seen_during_enable=true end,on_disable=function()return true end}"''')
        self.start_manager()
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

    def test_composed_menu_click_drag_wheel_and_reopened_pointer(self):
        # Non-unit scale catches tests that mistakenly feed logical menu coordinates.
        self.start_manager(3840, 2160)
        self.lua.execute(b'''update(.01);f8=true;update(.01);update(.01);f8=false;update(.01)
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
          f8=true;update(.01)
          assert(not LiveLuaLoader.input_status().active and mouse_focused and not cursor and not clipped)
          local hidden_count=pointer_snapshots
          for frame=1,5 do update(.01)end
          assert(pointer_snapshots==hidden_count and pointer_releases==1)
          f8=false;update(.01);f8=true;update(.01);f8=false;update(.01)
          assert(LiveLuaLoader.input_status().active, 'Mouse manager did not reopen')
          wheel_y=1;update(.01);wheel_y=0;update(.01)
          assert(menu.scroll==0, 'Reopened manager did not accept mouse wheel input')
          click_button(2)
          focused=false;update(.01)
          assert(not LiveLuaLoader.input_status().active and mouse_focused and not cursor and not clipped)
          hidden_count=pointer_snapshots
          for frame=1,5 do update(.01)end
          assert(pointer_snapshots==hidden_count and pointer_releases==2)
          focused=true;f8=false;update(.01);f8=true;update(.01);f8=false;update(.01)
          click_button(3)
          shutdown()
          assert(mouse_focused and not cursor and not clipped and pointer_releases==3 and engine_mouse_reads==0)
          ''')


if __name__ == '__main__':
    unittest.main()
