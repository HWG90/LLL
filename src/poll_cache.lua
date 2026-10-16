-- Optional maintenance adapter for older LLL runtimes. No lifecycle is disabled.
local M={version=1}
local function find(fn,predicate)
 local result
 for i=1,80 do local name,value=debug.getupvalue(fn,i);if not name then break end
  if predicate(value)then assert(not result,'Ambiguous loader interface');result=value end
 end
 return result
end
function M.interfaces(manager)
 assert(type(manager)=='table'and type(manager.refresh)=='function'and type(manager.frame)=='function','LLL public lifecycle unavailable')
 local _,refresh=debug.getupvalue(manager.refresh,1)
 assert(type(refresh)=='function'and not debug.getupvalue(manager.refresh,2),'Unsupported LLL refresh closure')
 local live=assert(find(refresh,function(v)return type(v)=='table'and type(rawget(v,'scan'))=='function'and type(rawget(v,'fingerprint'))=='function'and type(rawget(v,'catalog'))=='table'and type(rawget(v,'entries'))=='table'end),'LLL live catalog unavailable')
 local controls=assert(find(refresh,function(v)return type(v)=='table'and type(rawget(v,'refresh'))=='function'and type(rawget(v,'provenance_snapshot'))=='function'and type(rawget(v,'bindings'))=='table'end),'LLL controls unavailable')
 local platform=assert(find(live.scan,function(v)return type(v)=='table'and type(rawget(v,'changed'))=='function'and type(rawget(v,'files'))=='function'and type(rawget(v,'stat'))=='function'and type(rawget(v,'read'))=='function'end),'LLL watcher platform unavailable')
 assert(type(live.enabled)=='function'and type(live.auto_reload)=='function','LLL reload policy unavailable')
 local project=find(live.scan,function(v)return type(v)=='table'and type(rawget(v,'descriptor'))=='function'and type(rawget(v,'fingerprint'))=='function'and type(rawget(v,'snapshot'))=='function'end)
 return live,controls,platform,project
end
local function add(parts,key,value)
 value=tostring(value);parts[#parts+1]=key..'='..#value..':'..value
end
local function mark(manager,controls)
 local parts={}
 add(parts,'selected',controls.selected);add(parts,'diagnostics',manager.discovery_diagnostics)
 for key,value in pairs(controls.expanded or {})do add(parts,'expanded:'..key,value)end
 for index,row in ipairs(controls.provenance_snapshot()or{})do
  for _,key in ipairs({'name','state','owner','source','author','display_name','description'})do add(parts,index..':'..key,row[key])end
 end
 if manager.get_loader_option then
  for _,key in ipairs({'manager_ui','manager_window','metadata_editing','auto_reload'})do
   local value=manager.get_loader_option(key)
   if type(value)=='table'then for k,v in pairs(value)do add(parts,key..':'..k,v)end else add(parts,key,value)end
  end
 end
 for index,binding in ipairs(controls.bindings)do
  add(parts,index..':api',binding.api);add(parts,index..':handle',binding.handle);add(parts,index..':inside',binding.inside)
  local mod=binding.api and binding.api.mods and binding.api.mods.lll_management
  add(parts,index..':mod',mod)
  for key,value in pairs(mod and mod.values or{})do add(parts,index..':value:'..key,value)end
 end
 table.sort(parts);return table.concat(parts,'|')
end
local function normalized(path)return type(path)=='string'and path:gsub('\\','/'):gsub('/+$',''):lower()or''end
local function catalog_filter(platform,project,handle)
 if not project or type(platform.roots)~='table'then return end
 local broad,separate
 for _,root in ipairs(platform.roots)do
  if normalized(root.path):match('/cowboybingus/helldivers2$')then broad=root.path:gsub('[/\\]+$','')end
 end
 if not broad then return end
 for _,root in ipairs(platform.roots)do if normalized(root.path)==normalized(broad)..'/mods'then separate=true end end
 if not separate then return end
 local descriptors={}
 local function listing(path)
  local files,stamps,dirs=platform.files(path)
  if type(files)~='table'or type(stamps)~='table'then return end
  if type(dirs)~='table'and platform.directories then dirs=platform.directories(path)end
  if type(dirs)~='table'then return end
  local lowered={}
  for key,value in pairs(stamps)do if type(key)=='string'then lowered[key:lower()]=value end end
  for _,file in ipairs(files)do if type(file)~='string'or lowered[file:lower()]==nil then return end end
  return files,lowered,dirs
 end
 local function signature()
  local files,stamps,dirs=listing(broad);if not files then return end
  local mods_present=false
  for _,dir in ipairs(dirs)do if type(dir)=='string'and dir:lower()=='mods'then mods_present=true end end
  local parts={}
  -- A complete parent listing also proves an absent configured Mods root.
  -- Its creation/deletion changes this marker and forces normal discovery.
  add(parts,'separate-mods-present',mods_present)
  for _,file in ipairs(files)do
   if type(file)=='string'and(file:lower():match('%.lua$')or file:lower():match('%.json$'))then add(parts,'root:'..file,stamps[file:lower()]or'-')end
  end
  for _,dir in ipairs(dirs)do
   if type(dir)=='string'and dir:match('^[%w_-]+$')and dir:lower()~='mods'then
    add(parts,'directory',dir)
    local child=broad..'/'..dir
    -- Older transports stat every enumerated file. Inspect only the fixed
    -- discovery markers; logs can contain hundreds of unrelated files.
    local child_stamps={}
    for _,file in ipairs({'manifest.json','mod.json','metadata.json','main.lua','mod.lua'})do
     child_stamps[file]=platform.stat(child..'/'..file)
     add(parts,dir..':'..file,child_stamps[file]or'-')
    end
    local manifest_stamp=child_stamps['manifest.json']
    if manifest_stamp then
     local cached=descriptors[dir]
     if not cached or cached.stamp~=manifest_stamp then
      -- Decode through LLL's existing data-only descriptor; never execute metadata.
      local checked={read=function(path,limit)
       local text=platform.read(path,limit)
       assert(text~=nil,'Manifest temporarily unreadable')
       return text
      end}
      local spec=project.descriptor(checked,child)
      cached={stamp=manifest_stamp,entry=spec and spec.entry};descriptors[dir]=cached
     end
     if cached.entry then
      local stamp=child_stamps[cached.entry:lower()]
      if stamp==nil then stamp=platform.stat(child..'/'..cached.entry)end
      add(parts,dir..':entry:'..cached.entry,stamp or'-')
     end
    else descriptors[dir]=nil end
   end
  end
  table.sort(parts);return table.concat(parts,'|')
 end
 local last
 local ok,value=pcall(signature);if ok then last=value end
 local original=platform.changed
 local wrapper=function(path,...)
  if not handle.active then return original(path,...)end
  local changed=original(path,...)
  if changed~=true or normalized(path)~=normalized(broad)then return changed end
  local ok,current=pcall(signature)
  if not ok or not current then last=nil;handle.catalog_fallbacks=handle.catalog_fallbacks+1;return changed end
  local same=last==current;last=current
  if same then handle.catalog_ignored=handle.catalog_ignored+1;return false end
  handle.catalog_passed=handle.catalog_passed+1;return changed
 end
 return original,wrapper
end
local function legacy_log_reader(manager)
 -- The public registration closure owns this exact legacy reader. Unknown or
 -- wrapped APIs remain untouched rather than searching arbitrary callbacks.
 if type(manager.register_log)~='function'then return end
 local source=debug.getinfo(manager.register_log,'S').source
 local found
 for i=1,80 do local name,value=debug.getupvalue(manager.register_log,i);if not name then break end
  if type(value)=='table'and type(rawget(value,'poll'))=='function'and type(rawget(value,'discover'))=='function'and type(rawget(value,'register'))=='function'
   and type(rawget(value,'paths'))=='table'and type(rawget(value,'candidates'))=='table'and type(rawget(value,'scanned'))=='table'
   and type(rawget(value,'count'))=='number'and type(rawget(value,'candidate_count'))=='number'and type(rawget(value,'verbose'))=='boolean'
   and debug.getinfo(value.poll,'S').source==source and debug.getinfo(value.discover,'S').source==source then
    if found and found~=value then return end
    found=value
  end
 end
 return found
end
function M.install(manager)
 local live,controls,platform,project=M.interfaces(manager)
 local old_fingerprint,old_refresh=live.fingerprint,controls.refresh
 local cache,last_mark={},nil
 local handle={version=1,active=true,manager=manager,live=live,controls=controls,hits=0,misses=0,restart_skips=0,refresh_hits=0,catalog_ignored=0,catalog_passed=0,catalog_fallbacks=0}
 local wrapped_fingerprint,wrapped_refresh
 wrapped_fingerprint=function(name,force)
  if not handle.active then return old_fingerprint(name,force)end
  local entry=live.catalog[name]or live.entries[name]
  if not entry then return old_fingerprint(name,force)end
  if entry.project and entry.project.restart_only==true then handle.restart_skips=handle.restart_skips+1;return nil end
  local prior=cache[name]
  -- Explicit loads need a baseline even when auto-reload is disabled. Retain it
  -- without consuming the watcher until automatic reload is enabled again.
  if not force and not live.auto_reload()and prior and prior.path==entry.path then handle.hits=handle.hits+1;return prior.value end
  if entry.project then
   local changed=platform.changed(entry.dir)
   if not force and not changed and prior and prior.path==entry.path and prior.dir==entry.dir then handle.hits=handle.hits+1;return prior.value end
   handle.misses=handle.misses+1
   cache[name]=nil
   -- Consume the watcher once, then force the underlying cache to recompute.
   local value=old_fingerprint(name,true)
   if value~=nil then cache[name]={path=entry.path,dir=entry.dir,value=value}else cache[name]=nil end
   return value
  end
  local stamp=platform.stat(entry.path)
  if not force and stamp and prior and prior.path==entry.path and prior.stamp==stamp then handle.hits=handle.hits+1;return prior.value end
  handle.misses=handle.misses+1
  cache[name]=nil
  local value=old_fingerprint(name,force)
  local after=platform.stat(entry.path)
  if value~=nil and stamp and stamp==after then cache[name]={path=entry.path,stamp=stamp,value=value}else cache[name]=nil end
  return value
 end
 wrapped_refresh=function(...)
  if not handle.active then return old_refresh(...)end
  local current=mark(manager,controls)
  if last_mark==current then handle.refresh_hits=handle.refresh_hits+1;return end
  local function saved(...)
   last_mark=mark(manager,controls)
   return ...
  end
  return saved(old_refresh(...))
 end
 local old_changed,wrapped_changed=catalog_filter(platform,project,handle)
 local reader=legacy_log_reader(manager)
 local old_poll,old_discover,wrapped_poll,wrapped_discover
 if reader then
  old_poll,old_discover=reader.poll,reader.discover
  wrapped_poll=function(...)if handle.active then handle.log_poll_skips=handle.log_poll_skips+1;return end;return old_poll(...)end
  wrapped_discover=function(...)if handle.active then handle.log_discover_skips=handle.log_discover_skips+1;return end;return old_discover(...)end
 end
 handle.legacy_log_reader_suppressed=reader~=nil
 handle.log_poll_skips,handle.log_discover_skips=0,0
 function handle.release()
  if not handle.active then return true end
  handle.active=false
  if live.fingerprint==wrapped_fingerprint then live.fingerprint=old_fingerprint end
  if controls.refresh==wrapped_refresh then controls.refresh=old_refresh end
  if wrapped_changed and platform.changed==wrapped_changed then platform.changed=old_changed end
  if reader and reader.poll==wrapped_poll then reader.poll=old_poll end
  if reader and reader.discover==wrapped_discover then reader.discover=old_discover end
  return true
 end
 function handle.owned()return handle.active and live.fingerprint==wrapped_fingerprint and controls.refresh==wrapped_refresh and(not wrapped_changed or platform.changed==wrapped_changed)and(not reader or(reader.poll==wrapped_poll and reader.discover==wrapped_discover))end
 live.fingerprint,controls.refresh=wrapped_fingerprint,wrapped_refresh
 if wrapped_changed then platform.changed=wrapped_changed end
 if reader then reader.poll,reader.discover=wrapped_poll,wrapped_discover end
 handle.catalog_filtered=wrapped_changed~=nil
 return handle
end
return M
