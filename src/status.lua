-- Original read-only status page using MCM's public registration API.
return function(loader,discovery,report)
 local owner,handle,last
 local function display(value) return tostring(value or ''):gsub('[%c]',' '):sub(1,500) end
 local function controls()
  local loaded,failed,skipped,disabled=0,0,0,0;local rows={}
  for _,name in ipairs(loader.order) do
   local state=loader.modules[name] or 'unknown'
   if state=='loaded' then loaded=loaded+1 elseif state=='disabled' then disabled=disabled+1 elseif state=='not installed' then skipped=skipped+1 else failed=failed+1 end
   rows[#rows+1]={type='text',label=display(name),description=display(state..(loader.records[name] and '; managed live lifecycle' or '; restart required for reload'))}
   rows[#rows+1]={type='text',label=display('  '..state)}
  end
  local summary={{type='section',label='LIVE LUA LOADER R16'},
   {type='text',label='Loaded: '..loaded..'   Failed / pending: '..failed..'   Disabled: '..disabled..'   Not installed: '..skipped},
   {type='text',label='Discovered archive addons: '..discovery.count},
   {type='text',label='Source limit: 16 MB; live scans every 0.5 seconds'},
   {type='text',label='Loaded means initialization returned successfully.',description='This does not prove gameplay behavior or rendering.'},
   {type='text',label=display(discovery.diagnostics)},
   {type='text',label='Startup validation: experimental private candidate'}}
  return summary,rows
 end
 local function refresh()
  local api=rawget(_G,'DBFMCM');if not api or type(api.register)~='function' then return end
  if api~=owner then if handle then pcall(handle.unregister) end;owner=api;handle=nil;last=nil end
  local summary,rows=controls();local signature=''
  for _,list in ipairs({summary,rows}) do for _,row in ipairs(list) do signature=signature..row.label..(row.description or '') end end
  if signature==last and handle then return end
  if not handle then
   handle=api.register({id='live_lua_loader',name='Live Lua Loader - Diagnostics',description='R16: loader status and addon discovery diagnostics.',pages={
    {id='overview',name='Overview',controls=summary},
    {id='mods',name='Mod status',controls=rows}}})
   report('LLL status','MCM status page registered')
  else
   local mod=api.mods and api.mods.live_lua_loader
   if not mod then handle=nil;last=nil;return end
   mod.pages[1].controls=summary;mod.pages[2].controls=rows;api.revision=api.revision+1
  end
  last=signature
 end
 return {refresh=refresh,close=function()if handle then pcall(handle.unregister);handle=nil end end}
end
