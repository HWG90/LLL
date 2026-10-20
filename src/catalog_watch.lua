-- Ignore output-only broad-root notifications while preserving discovery edits.
local function add(parts,key,value)
 value=tostring(value);parts[#parts+1]=key..'='..#value..':'..value
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
  local files,stamps,dirs,status=platform.files(path)
  if status~=nil and status~=0 and status~=2 and status~=3 then return end
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
return catalog_filter
