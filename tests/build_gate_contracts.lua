local gate=dofile('src/build_gate.lua')
local exe,game,lua=string.rep('A',64),string.rep('B',64),string.rep('C',64)
local values={exe=exe,['game.dll']=game,['lua51.dll']=lua}
local reads=0
local memory={new=function()return {
    module=function(name)return name or 'exe' end,
    module_hash=function(name)reads=reads+1;local v=values[name];if v=='error' then error('read failed') end;return v end}
end}
local builds={{exe_sha256=exe,game_sha256=game}}
local good=gate.check({},memory,builds,lua)
assert(good.supported and good.jit_supported and reads==3)
values.exe=string.rep('D',64);reads=0
local bad=gate.check({},memory,builds,lua)
assert(not bad.supported and not bad.jit_supported and reads==2 and bad.reason=='unsupported game build')
values.exe='error';reads=0
bad=gate.check({},memory,builds,lua)
assert(not bad.supported and bad.exe_sha256=='unavailable' and bad.game_sha256==game and reads==2)
values.exe=exe;values['lua51.dll']='error'
bad=gate.check({},memory,builds,lua)
assert(bad.supported and not bad.jit_supported)
assert(not gate.check({}, {new=function()error('ffi missing')end}, builds,lua).supported)
assert(not gate.check({},memory,{},lua).supported)
values.exe='malformed';assert(not gate.check({},memory,builds,lua).supported)

-- Real Windows SHA256 and cross-copy cache reuse, inside this isolated LuaJIT process.
local runtime=dofile('src/vendor/bsl_bingus_runtime.lua')
local original_shared=BingusRuntime;BingusRuntime=nil
local factory=dofile('src/vendor/bsl_bingus_memory.lua')
local api=factory.new(runtime)
local t=os.clock();local h=api.module_hash(assert(api.module()));local cold=os.clock()-t
assert(#h==64 and BingusRuntime.hash_reads==1)
local second=dofile('src/vendor/bsl_bingus_memory.lua').new(dofile('src/vendor/bsl_bingus_runtime.lua'))
t=os.clock();assert(second.module_hash(assert(second.module()))==h);local warm=os.clock()-t
assert(BingusRuntime.hash_reads==1,'Second copy must reuse the session hash without reading the file')
BingusRuntime=original_shared

-- Manager entry points must refuse before preflight/eviction/settings/callback effects.
local old_loader,old_compat=LiveLuaLoader,CowboyBingusModLoader
LiveLuaLoader=nil;CowboyBingusModLoader=nil
local side_effects=0
local function forbidden()side_effects=side_effects+1;error('gate bypass')end
local m=dofile('src/manager.lua')({build={supported=false},build_allowed=function()return false end,
    report=function()end,require=forbidden,preflight=forbidden,evict=forbidden,save_enabled=forbidden,
    available=forbidden,can_retry=forbidden},{'archive'})
assert(m.modules.archive=='build refused' and m.capabilities.build_gate)
for _,name in ipairs({'retry','reload','add','set_enabled','after_startup'})do assert(m[name](forbidden)==false)end
m.build.supported=true
assert(not m.retry('archive') and side_effects==0,'Public report changes cannot change the private gate decision')

-- Whole compiled bootstrap: stock result preserved and no optional service initialized.
LiveLuaLoader=nil;CowboyBingusModLoader=nil
local before_update=update
local function pack(...)return {n=select('#',...),...}end
local result=pack(dofile('tests/tmp/refused-bootstrap.lua'))
assert(result.n==4 and result[1]=='stock' and result[2]==nil and result[3]==42 and result[4]==nil and refused_stock==1)
assert(LiveLuaLoader.build.supported==false and LiveLuaLoader.capabilities.build_gate)
assert(not LiveLuaLoader.retry('anything') and not LiveLuaLoader.after_startup(forbidden))
assert(update==before_update and side_effects==0)
LiveLuaLoader=old_loader;CowboyBingusModLoader=old_compat
print(string.format('PASS SHA256 gate mismatch/read failure/unknown JIT, refused startup and all load paths; real shared hash reads=1; cold %.3f ms, cached %.3f ms (isolated process)',cold*1000,warm*1000))
