-- Build 26088801 maps the executable's decrypted code back as views of a
-- section (MEM_MAPPED), so "code inside a module image" must accept mapped
-- executable pages whose allocation is the exe or game.dll, and nothing else.
-- Seen live: the engine's string lookup at exe+0x2f1270 is MEM_MAPPED,
-- PAGE_EXECUTE_READ, allocation base = the exe.
--
-- usage: luajit process_mapped.lua <foundation.lua>
-- Prints one JSON line.
local foundation_path=...
assert(foundation_path,'usage: luajit process_mapped.lua foundation')
local f=assert(io.open(foundation_path,'rb'));local text=f:read('*a');f:close()
local head='local GameProcess = (function()'
local a=assert(text:find(head,1,true));local b=assert(text:find('\nend)()',a,true))
local GameProcess=assert(loadstring('return (function()'..text:sub(a+#head,b+#'\nend)()'-1),'@GameProcess'))()

local EXE,GAME,OTHER=0x140000000,0x6ffff0880000,0x7ff800000000
local regions={}
local function region(at,kind,protect,allocation,state)regions[at]={kind=kind,protect=protect,allocation=allocation,state=state or 0x1000}end
region(0x1402f1270,GameProcess.MAPPED,0x20,EXE)          -- the live case
region(GAME+0x1000,GameProcess.MAPPED,0x20,GAME)
region(EXE+0x1000,GameProcess.IMAGE,0x20,EXE)
region(OTHER+0x1000,GameProcess.MAPPED,0x20,OTHER)        -- another module's mapping
region(0x2000000,0x20000,0x40,0x2000000)                  -- private executable memory
region(EXE+0x2000,GameProcess.MAPPED,0x01,EXE)            -- a cold page: no access
region(EXE+0x3000,GameProcess.MAPPED,0x20,EXE,0x2000)     -- reserved, not committed
local backend={read=function()return nil end,
 module=function(name)if name==nil then return EXE end;if name=='game.dll'then return GAME end end,
 query=function(at)local r=regions[at];if not r then return nil end
  return at-at%4096,4096,r.state,r.protect,r.kind,r.allocation end}
local p=GameProcess.new(backend)
local checks=0
local function check(ok,what)assert(ok,what);checks=checks+1 end
check(p.executable(0x1402f1270,true),'mapped exe code, allocated as the exe, is module code')
check(p.executable(GAME+0x1000,true),'mapped game.dll code is module code')
check(p.executable(EXE+0x1000,true),'image code is module code')
check(not p.executable(OTHER+0x1000,true),'a mapping allocated as anything else is refused')
check(not p.executable(0x2000000,true),'private executable memory is refused')
check(p.executable(0x2000000),'private executable memory is still executable without image_only')
check(not p.executable(EXE+0x2000,true)and not p.executable(EXE+0x2000),'a no-access (cold) page is not executable')
check(not p.executable(EXE+0x3000,true),'reserved memory is refused')
-- A backend without module() keeps the old rule: image pages only.
local plain=GameProcess.new({read=backend.read,query=backend.query})
check(not plain.executable(0x1402f1270,true)and plain.executable(EXE+0x1000,true),'without module() only image pages count')
print(string.format('{"pass":true,"checks":%d}',checks))
