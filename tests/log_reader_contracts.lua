local Reader=dofile('src/log_reader.lua')
local logs={['logs/Demo.log']='old ERROR from prior session\n'}
local stamps={['logs/Demo.log']=1}
local sources={['mods/demo/main.lua']='local name="Demo.log"; local other="Late.log"'}
local reads=0
local platform={log_directory='logs',
    read=function(path)return sources[path]end,
    files=function()return {},{},{}end,
    stat=function(path)return logs[path] and tostring(stamps[path] or 1)end,
    read_log=function(path,position,limit,changed)
        local content=logs[path];if not content then return nil end
        reads=reads+1
        local total=#content;local reset=false;local skipped=false
        if position==nil then position=total
        elseif position<0 then position=math.max(0,total+position);skipped=position>0
        elseif position>total or (changed and position==total)then position=0;reset=true end
        local next=math.min(total,position+limit)
        return content:sub(position+1,next),next,reset,skipped,total
    end}
local events={}
local diagnostic={locations={},emit=function(event)events[#events+1]=event end}
local reader=Reader.new(platform,diagnostic,{own_log='logs/LiveLuaLoader.log'})
reader.discover('live/demo',{path='mods/demo/main.lua',dir='mods/demo'})
reader.poll();assert(#events==0,'normal startup must not replay historical errors')
local old_reads=reads;reader.poll();assert(reads==old_reads,'unchanged logs must not read content')
logs['logs/Demo.log']=logs['logs/Demo.log']..'INFO normal\nERROR split';stamps['logs/Demo.log']=2
reader.poll();assert(#events==0,'partial errors wait for complete lines')
logs['logs/Demo.log']=logs['logs/Demo.log']..' line\n';stamps['logs/Demo.log']=3
reader.poll();assert(#events==1 and events[1].source=='live/demo' and events[1].message=='ERROR split line')
reader.poll();assert(#events==1,'errors must not duplicate on unchanged polls')
logs['logs/Demo.log']='ERROR rotated\n';stamps['logs/Demo.log']=4
reader.poll();assert(events[2].message=='ERROR rotated','truncated/replaced logs reset the tail')
reader.verbose=true
logs['logs/Demo.log']=logs['logs/Demo.log']..'startup detail\n';stamps['logs/Demo.log']=5
reader.poll();assert(events[3].severity=='debug','runtime verbose switch includes informational detail')
logs['logs/Late.log']='ERROR created during launch\n';stamps['logs/Late.log']=1
reader.poll();assert(events[4] and events[4].source=='live/demo','late-created source log must be discovered')
local count=#events
diagnostic.locations.Other='logs/Other.log';logs['logs/Other.log']='';stamps['logs/Other.log']=1
reader.poll()
logs['logs/Other.log']='exception owned by Other\n';stamps['logs/Other.log']=2
reader.poll();assert(#events==count+1 and events[#events].source=='Other')
local history=Reader.new(platform,diagnostic,{verbose=true})
assert(history.register('live/demo','logs/Demo.log'));history.poll()
local found=false;for _,event in ipairs(events)do if event.message=='startup detail' and event.source=='live/demo' then found=true end end
assert(found,'verbose launch can include bounded existing tails')
print('PASS source log ownership, bounded tails, append/partial lines, rotation, late files, idle zero reads and runtime verbosity')
