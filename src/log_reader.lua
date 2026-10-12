-- Incremental, source-owned log ingestion; never intercept another mod's writer.
local M={}
local function key(path)return path:gsub('\\','/'):lower()end
local function filename(value)
    return type(value)=='string' and value:match('^[%w_. -]+%.log$') and value
end
function M.new(platform,diagnostics,options)
    options=options or {}
    local self={paths={},count=0,scanned={},candidates={},candidate_count=0,verbose=options.verbose==true}
    local roots={platform.log_directory}
    local base=os.getenv('LOCALAPPDATA')
    if base then
        roots[#roots+1]=base..'/CowboyBingus/Helldivers2/Logs'
        roots[#roots+1]=base..'/MDL/Helldivers2/Logs'
    end
    function self.register(source,path,from_start,authoritative)
        if type(path)~='string' or not filename(path:match('[^/\\]+$')) then return false end
        local id=key(path)
        if self.paths[id] then
            if authoritative then self.paths[id].source=source;self.paths[id].authoritative=true end
            return self.paths[id].source==source
        end
        if self.count>=64 then return false end
        local _,position=platform.read_log(path,nil,0)
        if from_start then position=0 end
        self.paths[id]={source=source,path=path,position=position,
            authoritative=authoritative,initial=self.verbose,partial='',stamp=platform.stat and platform.stat(path)}
        self.count=self.count+1
        return true
    end
    function self.discover(source,entry,force)
        if not entry or not entry.path then return end
        local signature=entry.path.."|"..tostring(platform.stat and platform.stat(entry.path))
        if not force and self.scanned[source]==signature then return end
        self.scanned[source]=signature
        local names={};local name_count=0
        local function add_name(name)
            if filename(name) and not names[name] and name_count<16 then names[name]=true;name_count=name_count+1 end
        end
        local explicit=entry.metadata and entry.metadata.log_files
        if type(explicit)=='table' then for _,name in ipairs(explicit)do add_name(name) end end
        local budget,files=2097152,0
        local function inspect(path)
            if files>=96 or budget<=0 then return end
            files=files+1
            local text=platform.read(path,math.min(262144,budget))
            if not text then return end
            budget=budget-#text
            -- Read literal log basenames from source; never evaluate source to discover a path.
            for literal in text:gmatch('["\']([^"\'\r\n]+%.log)["\']') do
                local name=literal:match('[^/\\]+$')
                if name~='LiveLuaLoader.log' then add_name(name) end
            end
        end
        inspect(entry.path)
        local function walk(dir,depth)
            if depth>4 or not platform.files or files>=96 or budget<=0 then return end
            local list,_,dirs=platform.files(dir)
            for _,name in ipairs(list or {})do if name:match('%.lua$')then inspect(dir..'/'..name)end end
            for _,name in ipairs(dirs or {})do
                if name~='dist' and name~='tests' and name~='native' and name~='binary' and name~='vendor' then walk(dir..'/'..name,depth+1)end
            end
        end
        if not entry.metadata_id then walk(entry.dir,0) end
        for name in pairs(names)do
            local candidates={entry.dir..'/'..name,entry.dir..'/Logs/'..name}
            for _,root in ipairs(roots)do if root then candidates[#candidates+1]=root..'/'..name end end
            for _,path in ipairs(candidates)do
                local id=key(path)
                local prior=self.candidates[id]
                if not prior and self.candidate_count<256 then
                    self.candidates[id]={source=source,path=path};self.candidate_count=self.candidate_count+1
                elseif prior and prior.source~=source then prior.ambiguous=true end
                if self.candidates[id] and platform.stat and platform.stat(path) and not self.candidates[id].ambiguous then self.register(source,path) end
            end
        end
    end
    function self.poll()
        -- Paths explicitly advertised by diagnostics are authoritative and can appear late.
        for source,path in pairs(diagnostics.locations or {})do
            if path~=options.own_log then self.register(source,path,nil,true)end
        end
        for id,candidate in pairs(self.candidates)do
            if not candidate.ambiguous and not self.paths[id] and platform.stat and platform.stat(candidate.path) then
                self.register(candidate.source,candidate.path,true)
            end
        end
        for id,item in pairs(self.paths)do
            if self.candidates[id] and self.candidates[id].ambiguous and not item.authoritative then
                self.paths[id]=nil;self.count=self.count-1
            else
            local stamp=platform.stat and platform.stat(item.path)
            if item.initial or item.pending or not platform.stat or stamp~=item.stamp then
                local text,position,reset,skipped,total=platform.read_log(item.path,item.initial and -65536 or item.position,8192,item.stamp and stamp~=item.stamp)
                if text then
                    item.stamp=stamp;item.initial=false;item.position=position;item.pending=total and position<total
                    if reset or skipped then item.partial='' end
                    if skipped then text=text:gsub('^[^\n]*\n','',1)end
                    local combined=item.partial..text
                    local at=1
                    for line,last in combined:gmatch('([^\n]*)\n()')do
                        line=line:gsub('\r$','');at=last
                        local lower=line:lower()
                        local severity=lower:find('error',1,true) or lower:find('exception',1,true)
                            or lower:find('failed',1,true) or lower:find('traceback',1,true)
                        if severity or self.verbose then
                            diagnostics.emit({source=item.source,severity=severity and 'error' or 'debug',
                                message=line,details='Mod log: '..item.path,log_path=item.path})
                        end
                    end
                    item.partial=combined:sub(at):sub(-4096)
                end
            end
            end
        end
    end
    return self
end
return M
