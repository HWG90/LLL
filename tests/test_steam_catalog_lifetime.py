"""Actual Lua 5.1 catalog/watch lifetime checks; no game or filesystem writes."""
from pathlib import Path
import os
import unittest

from lupa import lua51

ROOT = Path(__file__).resolve().parents[1]

FIXTURE = br'''
LLL_METADATA=dofile('src/metadata.lua')
local function key(path)return path:gsub('\\','/'):gsub('/+$',''):lower()end
local function count(items)local n=0;for _ in pairs(items)do n=n+1 end;return n end
local function upvalue(fn,wanted)
 for index=1,40 do local name,value=debug.getupvalue(fn,index)
  if name==wanted then return value end
  if not name then break end
 end
 error('Missing production upvalue: '..wanted)
end
function fixture(releasable)
 local f={files={},dirs={mods={}},loose_files={mods={}},events={},watched={},releases={},
  reads=0,stats=0,listings=0,limit=4,release_mode=nil,fail_listing=false}
 local p={live='mods',settings='settings',roots={{kind='lll',path='mods'}},native_ffi=false,
  source_notifications=true}
 function p.files(path)
  f.listings=f.listings+1;assert(not f.fail_listing,'Temporary listing failure')
  if f.listing_status and f.listing_status~=0 then return {},{},{},f.listing_status end
  return f.loose_files[path] or {},{},f.dirs[path] or {},f.listing_status
 end
 function p.directories(path)return f.dirs[path] or {}end
 function p.read(path)f.reads=f.reads+1;return f.files[path]end
 function p.stat(path)f.stats=f.stats+1;return f.files[path]end
 function p.write(path,text)f.files[path]=text;return true end
 function p.mkdir()return true end
 function p.changed(path)
  local normalized=key(path)
  if not f.watched[normalized]then
   assert(count(f.watched)<f.limit,'Watcher capacity exhausted')
   f.watched[normalized]=path;f.events[normalized]=nil;return true
  end
  local changed=f.events[normalized];f.events[normalized]=nil;return changed==true
 end
 if releasable~=false then
  function p.unwatch(path)
   f.releases[#f.releases+1]=path
   if f.release_mode=='throw'then error('Temporary unwatch failure')end
   if f.release_mode=='false'then return false end
   f.watched[key(path)]=nil;return true
  end
 end
 f.platform=p
 f.live=dofile('src/live.lua')(p,function()end)
 function f.signal()for _,root in ipairs(p.roots)do f.events[key(root.path)]=true end end
 local function main(value)
  return 'return {live_lua_api=1,version='..value..
   ',on_enable=function()end,on_update=function()return mod.require("src/helper").value end'..
   ',on_disable=function()_G.catalog_stops=(_G.catalog_stops or 0)+1;return true end}'
 end
 function f.install(root,id,value,entry,retain)
  local dir=root..'/'..id;entry=entry or 'main.lua'
  f.dirs[root]=f.dirs[root] or {};local found=false
  for _,existing in ipairs(f.dirs[root])do found=found or existing==id end
  if not found then f.dirs[root][#f.dirs[root]+1]=id end
  f.files[dir..'/manifest.json']='{"name":"Project '..value..'","lll":{"entry":"'..entry..
   '","modules":["src/helper.lua"],"retain_until_exit":'..tostring(retain==true)..'}}'
  f.files[dir..'/'..entry]=main(value)
  f.files[dir..'/src/helper.lua']='return {value='..value..'}'
  f.files[dir..'/config/defaults.cfg']='{}';f.signal()
 end
 function f.remove(root,id)
  for index=#(f.dirs[root]or{}),1,-1 do
   if f.dirs[root][index]==id then table.remove(f.dirs[root],index)end
  end
  local prefix=root..'/'..id..'/'
  for path in pairs(f.files)do if path:sub(1,#prefix)==prefix then f.files[path]=nil end end
  f.signal()
 end
 function f.loose(root,id,value)
  f.loose_files[root]=f.loose_files[root]or{}
  f.loose_files[root][#f.loose_files[root]+1]=id..'.lua'
  f.files[root..'/'..id..'.lua']=main(value);f.signal()
 end
 function f.cache(name)
  if name=='metadata_cache'then return upvalue(f.live.scan,name)end
  if name=='sources'then return upvalue(f.live.source,name)end
  if name=='fingerprints'or name=='project_watches'then return upvalue(f.live.fingerprint,name)end
  if name=='prepared'then return upvalue(f.live.preflight,name)end
  return upvalue(f.live.load,name)
 end
 f.count=count;return f
end
'''


class SteamCatalogLifetime(unittest.TestCase):
    def setUp(self):
        self.previous = Path.cwd()
        os.chdir(ROOT)
        self.lua = lua51.LuaRuntime(encoding=None)
        self.lua.execute(FIXTURE)

    def tearDown(self):
        os.chdir(self.previous)

    def test_removed_projects_release_capacity_and_prune_discovery_caches(self):
        self.lua.execute(br'''
          local f=fixture();f.limit=2
          for index=1,320 do
           local id='project'..index;local name='live/'..id
           f.install('mods',id,index);f.live.scan();f.live.fingerprint(name);f.live.source(name)
           assert(f.count(f.watched)==2)
           f.remove('mods',id);f.live.scan();f.live.forget_removed(name)
           assert(f.count(f.watched)==1 and f.watched.mods,'Root watch was released')
           assert(f.count(f.cache('project_watches'))==0)
           assert(f.count(f.cache('fingerprints'))==0 and f.count(f.cache('sources'))==0)
           assert(f.count(f.cache('metadata_cache'))==0)
          end
          assert(#f.releases==320)
          local reads,stats,listings=f.reads,f.stats,f.listings
          for index=1,100 do f.live.scan()end
          assert(f.reads==reads and f.stats==stats and f.listings==listings and #f.releases==320,
           'Unchanged idle scans performed cleanup or filesystem work')
        ''')

    def test_reinstallation_and_priority_replacement_get_fresh_fingerprints(self):
        self.lua.execute(br'''
          local f=fixture();local p=f.platform
          p.roots[2]={kind='lll',path='secondary'};f.dirs.secondary={}
          f.install('mods','demo',1);f.install('secondary','demo',2)
          f.live.scan();local first=f.live.fingerprint('live/demo')
          f.remove('mods','demo');f.live.scan()
          assert(f.live.catalog['live/demo'].dir=='secondary/demo')
          assert(not f.watched['mods/demo'] and f.watched.mods and f.watched.secondary)
          assert(f.count(f.cache('fingerprints'))==0)
          local second=f.live.fingerprint('live/demo');assert(second~=first)
          assert(f.count(f.cache('metadata_cache'))==1)
          f.loose('mods','demo',3);f.live.scan()
          assert(not f.live.catalog['live/demo'].project and not f.watched['secondary/demo'])
          assert(f.count(f.cache('fingerprints'))==0)
          f.install('mods','demo',4);f.live.scan()
          assert(f.live.catalog['live/demo'].project and f.live.fingerprint('live/demo')~=first)
          assert(f.watched['mods/demo'] and #f.releases==2)
        ''')

    def test_same_directory_successor_and_configured_root_keep_shared_watch(self):
        self.lua.execute(br'''
          local f=fixture();f.install('mods','demo',1);f.live.scan()
          local first=f.live.fingerprint('live/demo')
          f.install('mods','demo',2,'new.lua');f.live.scan()
          assert(#f.releases==0 and f.watched['mods/demo'])
          assert(f.count(f.cache('fingerprints'))==0 and f.live.fingerprint('live/demo')~=first)
          f.platform.roots[2]={kind='lll',path=[[MODS\demo\]]}
          f.signal();f.live.scan()
          f.remove('mods','demo');f.live.scan()
          assert(#f.releases==0 and f.watched['mods/demo'],'Configured root alias was unwatched')
        ''')

    def test_backend_without_unwatch_still_prunes_caches_without_tracking_leaks(self):
        self.lua.execute(br'''
          local f=fixture(false);f.install('mods','demo',1);f.live.scan()
          f.live.fingerprint('live/demo');f.live.source('live/demo')
          f.remove('mods','demo');f.live.scan()
          assert(#f.releases==0 and f.count(f.cache('project_watches'))==0)
          assert(f.count(f.cache('fingerprints'))==0 and f.count(f.cache('sources'))==0)
          assert(f.count(f.cache('metadata_cache'))==0)
        ''')

    def test_failed_unwatch_retries_only_on_a_later_full_scan(self):
        self.lua.execute(br'''
          for _,failure in ipairs({'false','throw'})do
           local f=fixture();f.install('mods','demo',1);f.live.scan();f.live.fingerprint('live/demo')
           f.release_mode=failure;f.remove('mods','demo');f.live.scan()
           assert(#f.releases==1 and f.watched['mods/demo'])
           assert(f.count(f.cache('project_watches'))==1 and f.count(f.cache('fingerprints'))==0)
           f.release_mode=nil
           for index=1,100 do f.live.scan()end
           assert(#f.releases==1,'Failed unwatch introduced idle retries')
           f.signal();f.live.scan()
           assert(#f.releases==2 and not f.watched['mods/demo'])
           assert(f.count(f.cache('project_watches'))==0)
          end
        ''')

    def test_active_retained_instances_and_frozen_preflight_survive_scan_cleanup(self):
        self.lua.execute(br'''
          local f=fixture();f.install('mods','demo',1,nil,true);f.live.scan()
          f.live.fingerprint('live/demo');f.live.preflight('live/demo')
          local frozen=f.cache('prepared')['live/demo']
          f.files['mods/demo/src/helper.lua']='return {value=2}'
          f.live.scan(true)
          assert(f.cache('prepared')['live/demo']==frozen,'Scan discarded a frozen preflight')
          local original=f.live.load('live/demo');original.on_enable()
          local instance=f.cache('instances')['live/demo']
          f.remove('mods','demo');f.live.scan()
          assert(not f.watched['mods/demo'] and f.cache('instances')['live/demo']==instance)
          assert(original.on_update()==1 and not catalog_stops,
           'Discovery cleanup changed a running instance or its frozen modules')
          f.install('mods','demo',3);f.live.scan();f.live.preflight('live/demo')
          local replacement=f.live.load('live/demo')
          assert(replacement.on_update()==3 and original.on_update()==1 and not catalog_stops)
          local retained=f.cache('retained_instances')
          assert(#retained==1 and retained[1]==instance,'Retain-until-exit ownership was discarded')
          assert(original.on_disable() and replacement.on_disable() and catalog_stops==2)
        ''')

    def test_failed_scan_cannot_release_watches_from_a_partial_catalog(self):
        self.lua.execute(br'''
          local f=fixture();f.install('mods','demo',1);f.live.scan();f.live.fingerprint('live/demo')
          f.remove('mods','demo');f.fail_listing=true
          assert(not pcall(f.live.scan) and #f.releases==0 and f.watched['mods/demo'])
          f.fail_listing=false;f.signal();f.live.scan()
          assert(#f.releases==1 and not f.watched['mods/demo'])
        ''')

    def test_native_listing_errors_keep_catalog_signatures_metadata_and_watches(self):
        self.lua.execute(br'''
          for _,status in ipairs({5,234})do
           local f=fixture();f.install('mods','demo',1);f.live.scan();f.live.fingerprint('live/demo')
           local entry=f.live.catalog['live/demo'];local metadata=f.cache('metadata_cache')['mods/demo/']
           f.remove('mods','demo');f.listing_status=status
           local ok,why=pcall(f.live.scan)
           assert(not ok and why:find('Catalog listing incomplete',1,true))
           assert(f.live.catalog['live/demo']==entry and #f.releases==0 and f.watched['mods/demo'])
           assert(f.count(f.cache('fingerprints'))==1 and f.cache('metadata_cache')['mods/demo/']==metadata,
            'An incomplete empty listing was mistaken for removal')
           local listings,reads,stats=f.listings,f.reads,f.stats
           for index=1,100 do f.live.scan()end
           assert(f.listings==listings and f.reads==reads and f.stats==stats and #f.releases==0,
            'A listing error introduced idle filesystem retries')
           f.listing_status=0;f.signal();f.live.scan()
           assert(not f.live.catalog['live/demo'] and #f.releases==1 and not f.watched['mods/demo'])
          end
        ''')

    def test_success_and_known_absence_statuses_allow_complete_cleanup(self):
        self.lua.execute(br'''
          for _,status in ipairs({0,2,3})do
           local f=fixture();f.install('mods','demo',1);f.live.scan();f.live.fingerprint('live/demo')
           f.remove('mods','demo');f.listing_status=status;f.live.scan()
           assert(not f.live.catalog['live/demo'] and #f.releases==1 and not f.watched['mods/demo'])
           assert(f.count(f.cache('fingerprints'))==0 and f.count(f.cache('metadata_cache'))==0)
          end
        ''')

    def test_broad_root_filter_passes_incomplete_listings_through(self):
        self.lua.execute(br'''
          local broad='X:/CowboyBingus/Helldivers2'
          for _,status in ipairs({5,234})do
           local listing_status=0;local event=false
           local p={roots={{path=broad},{path=broad..'/Mods'}},stat=function()end,
            files=function()return {},{},{},listing_status end,
            changed=function()local result=event;event=false;return result end}
           local h={active=true,catalog_ignored=0,catalog_passed=0,catalog_fallbacks=0}
           local _,filtered=dofile('src/catalog_watch.lua')(p,{descriptor=function()end},h)
           event=true;assert(not filtered(broad),'Complete unchanged signature should be ignored')
           listing_status=status;event=true
           assert(filtered(broad)==true and h.catalog_fallbacks==1,
            'An incomplete empty broad-root listing suppressed its notification')
          end
          for _,status in ipairs({0,2,3})do
           local event=false
           local p={roots={{path=broad},{path=broad..'/Mods'}},stat=function()end,
            files=function()return {},{},{},status end,
            changed=function()local result=event;event=false;return result end}
           local h={active=true,catalog_ignored=0,catalog_passed=0,catalog_fallbacks=0}
           local _,filtered=dofile('src/catalog_watch.lua')(p,{descriptor=function()end},h)
           event=true;assert(not filtered(broad) and h.catalog_fallbacks==0,
            'Complete success/known-absent listings were treated as incomplete')
          end
        ''')


if __name__ == '__main__':
    unittest.main()
