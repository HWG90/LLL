do -- LuaJIT runtime handoff, Arsenal drop-in. LLL's original boot follows this block unchanged.
 if rawget(_G,'jit')==nil then
  -- The runtime travels in this boot patch. It is written once beside the game's
  -- archives (the game runs from its root folder), checked byte for byte, then loaded.
  local runtime='data/@RUNTIME_NAME@'
  local ok,handed,why=pcall(function()
   local bytes=@RUNTIME_BYTES@
   local f=io.open(runtime,'rb')
   local same=f and f:read('*a')==bytes
   if f then f:close() end
   if not same then
    local w=assert(io.open(runtime..'.tmp','wb'))
    w:write(bytes);w:close()
    os.remove(runtime)
    assert(os.rename(runtime..'.tmp',runtime))
    local r=assert(io.open(runtime,'rb'))
    same=r:read('*a')==bytes;r:close()
    assert(same,'runtime write verification failed')
   end
   local open,err=package.loadlib(runtime,'luaopen_hd2_luajit_boot')
   if not open then return false,'package.loadlib refused '..runtime..': '..tostring(err) end
   return open()
  end)
  local outcome=ok and handed==true and 'LuaJIT boot taken ('..runtime..')'
   or 'boot handoff not taken, LLL runs in PUC: '..tostring(ok and why or handed)
  local report=io.open((os.getenv('LOCALAPPDATA') or '.')..'/HD2-LuaJIT-boot-result.txt','wb')
  if report then report:write(os.date('%Y-%m-%d %H:%M:%S ')..outcome..'\n');report:close() end
  if ok and handed==true then return end
  print('[LuaJIT runtime] '..outcome)
 end
end
