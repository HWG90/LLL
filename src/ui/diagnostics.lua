-- Shared read-only diagnostics. No native APIs, command execution or input capture.
local M={}
local levels={debug=true,info=true,warn=true,error=true}
local function bounded(value,limit)
    local text=tostring(value or ''):gsub('%z',''):gsub('[\1-\8\11\12\14-\31]',' ')
    if #text>limit then
        while limit>0 and text:byte(limit+1)>=128 and text:byte(limit+1)<=191 do limit=limit-1 end
        text=text:sub(1,limit)..' [truncated]'
    end
    return text
end
function M.new(options)
    options=options or {}
    local capacity=math.max(16,math.min(512,options.capacity or 256))
    local ring,first,count,sequence={},1,0,0
    local owners={};local clock=options.clock or function()return os.time(),os.date('%H:%M:%S')end
    local api={api=1,revision=0,capacity=capacity,count=0,locations={},window={visible=false,width=740,height=320,scroll=0,dock='free'}}
    function api.emit(event)
        assert(type(event)=='table','Diagnostics event required')
        local source=bounded(event.source or 'Unknown',96)
        local severity=levels[event.severity] and event.severity or 'info'
        local message=bounded(event.message,1024);local details=bounded(event.details,1536)
        local path=bounded(event.log_path or api.locations[source],512)
        local timestamp,time=clock()
        local last=count>0 and ring[(first+count-2)%capacity+1]
        if last and last.source==source and last.severity==severity and last.message==message and last.details==details and last.log_path==path then
            last.repeats=last.repeats+1;last.timestamp=timestamp;last.time=time
        else
            sequence=sequence+1
            local index=(first+count-1)%capacity+1
            if count==capacity then index=first;first=first%capacity+1 else count=count+1 end
            ring[index]={seq=sequence,timestamp=timestamp,time=time,source=source,severity=severity,message=message,details=details,log_path=path,repeats=1}
        end
        api.count=count;api.revision=api.revision+1
        return sequence
    end
    function api.record(source,message,severity,details,path)
        if not severity then
            local lower=tostring(message):lower()
            severity=(lower:find('failed',1,true) or lower:find('error',1,true) or lower:find('refused',1,true)) and 'error'
                or (lower:find('pending',1,true) or lower:find('warning',1,true)) and 'warn'
                or tostring(message):match('^MCM TEXT') and 'debug' or 'info'
        end
        return api.emit({source=source,severity=severity,message=message,details=details,log_path=path})
    end
    function api.read()
        local result={}
        for i=1,count do local item=ring[(first+i-2)%capacity+1];local copy={};for k,v in pairs(item)do copy[k]=v end;result[i]=copy end
        return result
    end
    function api.attach(source,path)
        source=bounded(source,96);local token={};owners[token]=source
        if path and path~='' then api.locations[source]=bounded(path,512)end
        return token
    end
    function api.detach(token)
        if not owners[token]then return false,'Unknown diagnostics owner'end
        owners[token]=nil
        if not next(owners)then api.window.visible=false;api.window.drag=nil;api.window.resize=nil;api.active_surface=nil end
        return true
    end
    return api
end
function M.shared()
    local key='dbf.diagnostics.v1';local value=rawget(_G,'DBFDiagnostics') or package.loaded[key]
    if value then assert(value.api==1 and type(value.emit)=='function' and type(value.attach)=='function','Incompatible diagnostics provider')
    else value=M.new()end
    package.loaded[key]=value;rawset(_G,'DBFDiagnostics',value)
    return value
end
local colors={debug={145,156,165},info={224,230,234},warn={244,202,53},error={255,116,116}}
local function wrap(value,width)
    local lines={};local current='';local size=0
    for glyph in tostring(value):gmatch('[%z\1-\127\194-\244][\128-\191]*')do
        if glyph=='\n' then lines[#lines+1]=current;current='';size=0
        else if size>=width then lines[#lines+1]=current;current='';size=0 end;current=current..glyph;size=size+1 end
    end
    if current~=''then lines[#lines+1]=current end
    return lines
end
function M.surface(model)
    assert(model and model.api==1,'Diagnostics provider required')
    local self={};local token={};local hits={};local bounds,parent,screen;local held={};local mouse_held=false
    local cache={};local lines={};local cached_revision=-1;local cached_width=-1;local visible=1
    local state=model.window
    local function inside(x,y,b)return b and x and y and x>=b.x and x<=b.x+b.w and y>=b.y and y<=b.y+b.h end
    local function release_drag()if state.drag and state.drag.owner==token then state.drag=nil end;if state.resize and state.resize.owner==token then state.resize=nil end end
    function self.release()release_drag();if model.active_surface==token then model.active_surface=nil end;hits={};bounds=nil;self.bounds=nil end
    local function scroll(amount,absolute)
        local maximum=math.max(0,#lines-visible)
        state.scroll=math.max(0,math.min(maximum,absolute or (state.scroll+amount)));state.anchor=nil
    end
    function self.filter(input,open)
        if not open then self.release();return input end
        if model.active_surface~=token then
            model.active_surface=token;state.drag=nil;state.resize=nil
            held={};for _,key in ipairs({192,38,40,33,34,36,35})do held[key]=input.down(key)end
            mouse_held=input.down(1)
        else
            local down=input.down(192)
            if down and not held[192]then state.visible=not state.visible;release_drag()end
            held[192]=down
        end
        local x,y;if input.mouse then x,y=input.mouse()end
        local down=input.down(1);local over=state.visible and inside(x,y,bounds)
        if state.visible and over and down and not mouse_held then
            state.focused=true
            for i=#hits,1,-1 do if inside(x,y,hits[i])then hits[i].click(x,y);break end end
        elseif down and not mouse_held then state.focused=false end
        local dragging=state.visible and (state.drag or state.resize)
        if not down then
            if state.drag and state.drag.owner==token and parent and bounds then
                local gap=18*(screen.scale or 1)
                local b=bounds;local side
                if math.abs(b.x+b.w-parent.x)<gap then side='left'
                elseif math.abs(b.x-(parent.x+parent.w))<gap then side='right'
                elseif math.abs(b.y+b.h-parent.y)<gap then side='bottom'end
                if side then self.dock(side)end
            end
            release_drag()
        elseif x and y and screen then
            if state.drag and state.drag.owner==token then
                state.dock='free';state.x=math.max(0,math.min(screen.w-bounds.w,x-state.drag.dx));state.y=math.max(0,math.min(screen.h-bounds.h,y-state.drag.dy))
            elseif state.resize and state.resize.owner==token then
                local r=state.resize;local l,t,b,right=r.left,r.top,r.bottom,r.right;local s=screen.scale
                if r.edge:find('w',1,true)then l=math.max(0,math.min(right-420*s,x))end
                if r.edge:find('e',1,true)then right=math.min(screen.w,math.max(l+420*s,x))end
                if r.edge:find('s',1,true)then b=math.max(0,math.min(t-200*s,y))end
                if r.edge:find('n',1,true)then t=math.min(screen.h,math.max(b+200*s,y))end
                state.x,state.y=l,b;state.width,state.height=(right-l)/s,(t-b)/s;state.dock='free'
            end
        end
        local blocked={[192]=true}
        if state.visible and state.focused then
            local changes={[38]=1,[40]=-1,[33]=visible,[34]=-visible}
            for _,key in ipairs({38,40,33,34,36,35})do
                local pressed=input.down(key);blocked[key]=true
                if pressed and not held[key]then if key==36 then scroll(0,math.max(0,#lines-visible))elseif key==35 then scroll(0,0)else scroll(changes[key])end end
                held[key]=pressed
            end
        else for _,key in ipairs({38,40,33,34,36,35})do held[key]=input.down(key)end end
        if state.visible and over and input.wheel then scroll(input.wheel()/120*3)end
        mouse_held=down
        local result={}
        for k,v in pairs(input)do result[k]=v end
        result.down=function(key)if blocked[key]then return false end;return input.down(key)end
        if over or dragging then result.mouse=function()end;result.wheel=function()return 0 end end
        return result
    end
    function self.dock(side)
        if side=='free'then state.dock='free';return true end
        if not parent or not bounds or not screen then return false,'Parent geometry unavailable'end
        local x,y=parent.x,parent.y
        if side=='left'then x=parent.x-bounds.w
        elseif side=='right'then x=parent.x+parent.w
        elseif side=='bottom'then y=parent.y-bounds.h
        else return false,'Unknown docking side'end
        if x<0 or y<0 or x+bounds.w>screen.w or y+bounds.h>screen.h then return false,'Not enough space beside parent'end
        state.dock=side;state.x,state.y=x,y;return true
    end
    function self.compose(w,h,parent_bounds,open)
        parent=parent_bounds;screen={w=w,h=h,scale=math.min(w/1920,h/1080)}
        if not open or not state.visible then hits={};bounds=nil;return {}end
        local s=screen.scale;local ww=math.max(420,math.min(w/s,state.width));local wh=math.max(200,math.min(h/s,state.height))
        state.width,state.height=ww,wh
        local x=math.max(0,math.min(w-ww*s,state.x or (w-ww*s)/2));local y=math.max(0,math.min(h-wh*s,state.y or 12*s))
        bounds={x=x,y=y,w=ww*s,h=wh*s};self.bounds=bounds
        if state.dock~='free'then local ok=self.dock(state.dock);if ok then x,y=state.x,state.y;bounds.x,bounds.y=x,y else state.dock='free'end end
        state.x,state.y=x,y;visible=math.max(1,math.floor((wh-82)/18));hits={}
        local width=math.max(12,math.floor((ww-30)/(14*.62)))
        if cached_revision~=model.revision or cached_width~=width then
            lines={};local next_cache={}
            for _,event in ipairs(model.read())do
                local signature=event.repeats..'/'..event.time..'/'..width
                local entry=cache[event.seq]
                if not entry or entry.signature~=signature then
                    local value=event.time..' '..event.severity:upper()..' '..event.source..': '..event.message..(event.repeats>1 and (' (x'..event.repeats..')')or '')
                    if event.details~=''then value=value..'\n  '..event.details end
                    if event.log_path~=''then value=value..'\n  Log: '..event.log_path end
                    entry={signature=signature,lines=wrap(value,width)}
                end
                next_cache[event.seq]=entry
                for index,line in ipairs(entry.lines)do lines[#lines+1]={text=line,severity=event.severity,seq=event.seq,line=index}end
            end
            cache=next_cache;cached_revision=model.revision;cached_width=width
            if state.anchor then for index,item in ipairs(lines)do if item.seq==state.anchor.seq and item.line==state.anchor.line then state.scroll=math.max(0,#lines-visible-index+1);break end end end
        end
        state.scroll=math.floor(math.max(0,math.min(math.max(0,#lines-visible),state.scroll)))
        local first_line=math.max(1,#lines-visible-state.scroll+1);local anchor=lines[first_line]
        state.anchor=state.scroll>0 and anchor and {seq=anchor.seq,line=anchor.line}or nil
        local commands={}
        local function rect(rx,ry,rw,rh,color)commands[#commands+1]={type='rect',x=x+rx*s,y=y+ry*s,w=rw*s,h=rh*s,c=color,a=1,popup=true,layer=400,diagnostic_console=true}end
        local function text(rx,ry,value,color,size)commands[#commands+1]={type='text',x=x+rx*s,y=y+ry*s,text=value,size=(size or 14)*s,c=color or colors.info,a=1,popup=true,layer=400,diagnostic_console=true}end
        local function hit(rx,ry,rw,rh,fn)hits[#hits+1]={x=x+rx*s,y=y+ry*s,w=rw*s,h=rh*s,click=fn}end
        rect(0,0,ww,wh,{20,25,30});rect(0,wh-34,ww,34,{43,51,58});text(12,wh-23,'DIAGNOSTICS',{244,202,53},17)
        hit(0,wh-34,ww,34,function(mx,my)state.drag={owner=token,dx=mx-x,dy=my-y}end)
        for index,side in ipairs({'free','left','right','bottom'})do
            local bx=ww-240+(index-1)*50
            text(bx,wh-22,side:upper(),state.dock==side and {115,231,240}or colors.info,12)
            hit(bx-3,wh-30,48,26,function()local ok,why=self.dock(side);self.notice=ok and ''or why end)
        end
        text(ww-27,wh-23,'X',colors.info,17);hit(ww-35,wh-32,30,28,function()state.visible=false;release_drag()end)
        for index=first_line,math.min(#lines,first_line+visible-1)do local item=lines[index];text(12,wh-55-(index-first_line)*18,item.text,colors[item.severity])end
        if #lines==0 then text(12,wh-55,'No diagnostics events recorded yet.',colors.debug)end
        text(12,12,self.notice and self.notice~=''and self.notice or ('` toggles | '..(state.scroll==0 and 'Following latest' or 'History paused')..' | retained '..model.count..'/'..model.capacity),colors.debug,12)
        if #lines>visible then
            local track=wh-78;local thumb=math.max(16,track*visible/#lines);local maximum=#lines-visible
            local offset=track-thumb;rect(ww-10,35,4,track,{61,71,79});rect(ww-12,35+offset*state.scroll/maximum,8,thumb,{115,231,240})
            hit(ww-16,35,16,track,function(_,my)scroll(0,math.floor(math.max(0,math.min(1,(my-y-35*s)/(track*s)))*maximum))end)
        end
        local function resize(edge,rx,ry,rw,rh)
            hit(rx,ry,rw,rh,function()state.drag=nil;state.resize={owner=token,edge=edge,left=x,right=x+ww*s,bottom=y,top=y+wh*s}end)
        end
        resize('w',0,12,5,wh-24);resize('e',ww-5,12,5,wh-24);resize('s',12,0,ww-24,5);resize('n',12,wh-5,ww-24,5)
        for _,corner in ipairs({{'sw',0,0},{'se',ww-12,0},{'nw',0,wh-12},{'ne',ww-12,wh-12}})do resize(corner[1],corner[2],corner[3],12,12);rect(corner[2]+3,corner[3]+3,5,5,{115,231,240})end
        return commands
    end
    return self
end
return M
