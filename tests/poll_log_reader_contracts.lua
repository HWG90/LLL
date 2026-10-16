local Cache=dofile('src/poll_cache.lua')
local function fixture(kind)
 local calls={poll=0,discover=0,register=0,diagnostics=0}
 local platform={files=function()return{},{},{}end,stat=function()return'stamp'end,read=function()return'text'end,changed=function()return false end}
 local live={catalog={},entries={},scan=function()assert(platform);return{}end,fingerprint=function()return'source'end,enabled=function()return true end,auto_reload=function()return true end}
 local controls={bindings={},provenance_snapshot=function()return{}end,refresh=function()end}
 local function refresh()assert(live);controls.refresh()end
 local reader={paths={first={path='untouched.log',position=19}},candidates={pending={path='future.log'}},scanned={first='stamp'},count=1,candidate_count=1,verbose=false}
 reader.poll=function(...)calls.poll=calls.poll+1;return'poll',nil,select('#',...),nil end
 reader.discover=function(...)calls.discover=calls.discover+1;return'discover',nil,select('#',...),nil end
 reader.register=function(...)calls.register=calls.register+1;return'register',nil,select('#',...),nil end
 local manager={refresh=function()return refresh()end,frame=function()end,diagnostics={write=function()calls.diagnostics=calls.diagnostics+1 end}}
 manager.register_log=function(...)return reader.register(...)end
 if kind=='unknown'then reader.verbose=nil
 elseif kind=='wrapped'then local old=manager.register_log;manager.register_log=function(...)return old(...)end
 elseif kind=='stripped'then local old=manager.register_log;local copy=assert(loadstring(string.dump(old,true),debug.getinfo(old,"S").source));for i=1,80 do local n,v=debug.getupvalue(old,i);if not n then break end;debug.setupvalue(copy,i,v)end;manager.register_log=copy
 elseif kind=='ambiguous'then
  local other={};for k,v in pairs(reader)do other[k]=v end
  manager.register_log=function(...)assert(other~=reader);return reader.register(...)end
 end
 return manager,reader,calls
end
local function pack(...)return{n=select('#',...),...}end
for _,kind in ipairs({'known','stripped'})do
 local manager,reader,calls=fixture(kind)
 local poll,discover,register,public=reader.poll,reader.discover,reader.register,manager.register_log
 local paths,candidates,scanned=reader.paths,reader.candidates,reader.scanned
 local h=Cache.install(manager);assert(h.legacy_log_reader_suppressed and h.owned())
 reader.poll('a',nil);reader.discover('b',nil);assert(calls.poll==0 and calls.discover==0 and h.log_poll_skips==1 and h.log_discover_skips==1)
 assert(reader.paths==paths and reader.candidates==candidates and reader.scanned==scanned and reader.count==1 and reader.candidate_count==1 and reader.verbose==false and paths.first.position==19)
 manager.diagnostics.write('still direct');assert(calls.diagnostics==1)
 local r=pack(manager.register_log('source',nil));assert(r.n==4 and r[1]=='register'and r[3]==2 and calls.register==1 and reader.register==register and manager.register_log==public)
 assert(h.release()and reader.poll==poll and reader.discover==discover)
 local r=pack(reader.poll(false,nil));assert(r.n==4 and r[1]=='poll'and r[3]==2)
end
for _,kind in ipairs({'unknown','wrapped','ambiguous'})do
 local manager,reader,calls=fixture(kind);local poll,discover=reader.poll,reader.discover
 local h=Cache.install(manager);assert(not h.legacy_log_reader_suppressed and reader.poll==poll and reader.discover==discover);reader.poll();assert(calls.poll==1);h.release()
end
local manager,reader,calls=fixture('known');local h=Cache.install(manager);local prior=reader.poll
local foreign=function(...)return prior(...)end;reader.poll=foreign;assert(not h.owned());h.release();assert(reader.poll==foreign)
local r=pack(reader.poll(false,nil));assert(r.n==4 and r[1]=='poll'and r[3]==2 and calls.poll==1,'Released adapter must pass through retained foreign reader wrappers')
print('PASS known legacy log-reader suppression: public/stripped identity, no reader state/log/diagnostic/registration mutation, unknown/wrapped/ambiguous refusal, exact restore and foreign wrapper passthrough')
