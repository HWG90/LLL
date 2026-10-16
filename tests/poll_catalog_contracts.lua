local Cache=dofile('src/poll_cache.lua')
local Project=dofile('src/project.lua')
local function normalize(s)return s:gsub('\\','/'):gsub('/+$',''):lower()end
local broad='X:/CowboyBingus/Helldivers2/'
local base=normalize(broad)
local function fixture(separate,present)
 local fs={[base]={files={'loose.lua','loose.json','session.log'},stamps={['loose.lua']='a',['loose.json']='b',['session.log']='c'},dirs=present and{'Mods','Logs','Demo'}or{'Logs','Demo'}},
 [base..'/logs']={files={'activity.log'},stamps={['activity.log']='1'},dirs={}},
 [base..'/demo']={files={'Manifest.json'},stamps={['Manifest.json']='manifest1'},dirs={'src'}}}
 local data={[base..'/demo/manifest.json']='{"lll":{"entry":"src/start.lua"}}'}
 local events={};local force_calls=0
 local platform={roots={{path=broad}},files=function(path)local v=fs[normalize(path)];if not v then return{}end;return v.files,v.stamps,v.dirs end,
 changed=function(path)local key=normalize(path);local v=events[key];events[key]=false;return v==true end,
 stat=function(path)
  local dir,file=normalize(path):match('^(.*)/([^/]+)$');local row=fs[dir]
  if row then for key,value in pairs(row.stamps)do if key:lower()==file then return value end end end
  return data[normalize(path)]
 end,read=function(path)return data[normalize(path)]end}
 if separate then platform.roots[2]={path='x:\\cowboybingus\\helldivers2\\Mods'}end
 local live={catalog={},entries={},auto_reload=function()return true end,enabled=function()return true end,fingerprint=function()return'x'end}
 function live.scan(force)assert(platform and Project);local changed=platform.changed(broad);if force or changed then force_calls=force_calls+1 end;return changed end
 local controls={bindings={},provenance_snapshot=function()return{}end,refresh=function()end}
 local function refresh_catalog()live.scan();controls.refresh()end
 local manager={frame=function()end,refresh=function()return refresh_catalog()end}
 local handle=Cache.install(manager)
 local function signal(path)events[normalize(path or broad)]=true end
 return handle,platform,live,fs,data,signal,function()return force_calls end
end
local h,p,l,fs,data,signal,count=fixture(true,true)
assert(h.catalog_filtered)
-- Log contents, log creation, screenshots and settings never change discovery markers.
fs[base..'/logs'].stamps['activity.log']='2';signal();assert(not l.scan()and h.catalog_ignored==1)
fs[base..'/logs'].files[#fs[base..'/logs'].files+1]='output.png';fs[base..'/logs'].stamps['output.png']='3';signal();assert(not l.scan())
-- Creating the declared custom entry in an already existing project is discovery.
data[base..'/demo/src/start.lua']='return true';signal();assert(l.scan())
data[base..'/demo/src/start.lua']=nil;signal();assert(l.scan(),'Deleted custom entry must not be hidden')
-- Existing metadata, root loose source/JSON and new candidate folders remain visible.
fs[base..'/demo'].stamps['Manifest.json']='manifest2';data[base..'/demo/manifest.json']='{"name":"Renamed","lll":{"entry":"src/start.lua"}}';signal();assert(l.scan())
fs[base].stamps['loose.lua']='a2';signal();assert(l.scan());fs[base].stamps['loose.json']='b2';signal();assert(l.scan())
fs[base].dirs[#fs[base].dirs+1]='NewMod';fs[base..'/newmod']={files={'mod.lua'},stamps={['mod.lua']='1'},dirs={}};signal();assert(l.scan())
-- Mods is independently watched and passed through without this root filter.
signal(base..'/Mods');assert(p.changed(base..'/Mods'))
-- Explicit force still refreshes despite an output-only notification.
local prior=count();signal();l.scan(true);assert(count()==prior+1)
-- Unknown listings, missing separate roots, and missing Mods directory fail open.
fs[base]=nil;signal();assert(l.scan()and h.catalog_fallbacks>0);h.release()
local h,p,l,fs,data,signal=fixture(false,true);assert(not h.catalog_filtered);signal();assert(l.scan());h.release()
local h,p,l,fs,data,signal=fixture(true,false);assert(h.catalog_filtered);signal();assert(not l.scan(),'A complete listing proves absent configured Mods without masking creation')
fs[base].dirs[#fs[base].dirs+1]='Mods';signal();assert(l.scan(),'Creating configured Mods root must force discovery');table.remove(fs[base].dirs);signal();assert(l.scan(),'Deleting configured Mods root must force discovery');h.release()
local h,p,l,fs,data,signal=fixture(true,true);local prior=p.changed;local foreign=function(...)return prior(...)end;p.changed=foreign;h.release();signal();assert(p.changed==foreign and p.changed(broad),'Released adapter must pass through a foreign wrapper chain')
print('PASS broad-root catalog filter: output suppression, custom entry creation/deletion, casefold paths/manifests, root sources/metadata/new folders, separate Mods, force refresh and unknown-listing/CAS fail-open')
