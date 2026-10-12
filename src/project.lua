-- LLL-native folder projects. Per-instance scope/cache; no package.path mutation.
local M={}
local Metadata=LLL_METADATA or dofile('src/metadata.lua')
local Serialize=LLL_CONFIG or dofile('src/config.lua')
local function relative(path)
    assert(type(path)=='string' and #path>0 and #path<=240 and not path:find('[\\:%c]') and path:sub(1,1)~='/', 'Use a mod-relative path')
    for part in path:gmatch('[^/]+')do assert(part~='.' and part~='..','Path escapes the mod folder')end
    assert(not path:find('//',1,true),'Empty path segment')
    return path
end
local function module_path(name)
    assert(type(name)=='string','Module name required')
    if not name:find('/',1,true) and not name:match('%.lua$') then name=name:gsub('%.','/') end
    if not name:match('%.lua$') then name=name..'.lua' end
    return relative(name)
end
local function imports(text)
    -- Tokenize literals/comments so documentation examples cannot become imports.
    local tokens,at={},1
    while at<=#text do
        local c=text:sub(at,at)
        local comment=text:sub(at,at+1)=='--'
        local start=comment and at+2 or at
        local equals=text:match('^%[(=*)%[',start)
        if equals then
            local closing=']'..equals..']'
            local finish=text:find(closing,start+#equals+2,true)
            assert(finish,'Unterminated long literal')
            if not comment then tokens[#tokens+1]={kind='string',value=text:sub(start+#equals+2,finish-1)}end
            at=finish+#closing
        elseif comment then at=(text:find('\n',at,true) or #text)+1
        elseif c=='"' or c=="'" then
            local finish=at+1
            while finish<=#text do
                if text:sub(finish,finish)=='\\'then finish=finish+2
                elseif text:sub(finish,finish)==c then break else finish=finish+1 end
            end
            local literal=text:sub(at,finish);local chunk=assert(loadstring('return '..literal));setfenv(chunk,{})
            tokens[#tokens+1]={kind='string',value=chunk()};at=finish+1
        elseif c:match('[%a_]') then
            local name=text:match('^[%w_]+',at);tokens[#tokens+1]={kind='name',value=name};at=at+#name
        elseif c:match('%s')then at=at+1
        else tokens[#tokens+1]={kind='symbol',value=c};at=at+1 end
    end
    local result={}
    for index=1,#tokens-4 do
        if tokens[index].value=='mod' and tokens[index+1].value=='.' and tokens[index+2].value=='require' and tokens[index+3].value=='(' and tokens[index+4].kind=='string' then result[#result+1]=module_path(tokens[index+4].value)end
    end
    return result
end
local function copy(value)
    if type(value)~='table' then return value end
    local result={};for key,item in pairs(value)do result[key]=copy(item)end;return result
end
local function merge(base,overlay)
    local result=copy(base)
    for key,value in pairs(overlay)do
        if type(value)=="table" and type(result[key])=="table" then result[key]=merge(result[key],value)
        else result[key]=copy(value)end
    end
    return result
end
local function json(value)
    Serialize.serialize(value)
    local function quote(text)
        return '"'..text:gsub('[%z\1-\31\\"]',function(c)
            local escapes={['"']='\\"',["\\"]='\\\\',["\n"]='\\n',["\r"]='\\r',["\t"]='\\t'}
            return escapes[c] or string.format('\\u%04x',string.byte(c))
        end)..'"'
    end
    local function encode(item)
        if type(item)=="string" then return quote(item)end
        if type(item)=="number" or type(item)=="boolean" then return tostring(item)end
        local rows,keys={},{};local array=true;local count=0
        for key in pairs(item)do count=count+1;if type(key)~="number" or key%1~=0 or key<1 then array=false end;keys[#keys+1]=key end
        if array and count>0 and #item==count then
            for index=1,count do rows[#rows+1]=encode(item[index])end
            return '['..table.concat(rows,',')..']'
        end
        table.sort(keys)
        for _,key in ipairs(keys)do assert(type(key)=="string","Config objects require string keys");rows[#rows+1]=quote(key)..':'..encode(item[key])end
        return '{'..table.concat(rows,',')..'}'
    end
    return encode(value)
end
local function data(text,path)
    if not text then return {} end
    local result=Metadata.decode(text)
    assert(type(result)=="table" and result~=Metadata,"Config must contain a JSON object")
    json(result);return result
end
function M.descriptor(platform,dir)
    local text=platform.read(dir..'/manifest.json',1048576)
    if not text then return end
    local ok,value=pcall(Metadata.decode,text)
    if not ok or type(value)~='table' or value.lll==nil then return end
    assert(type(value.lll)=='table' and value.lll~=Metadata,'Invalid LLL manifest descriptor')
    local spec=copy(value.lll)
    spec.entry=relative(spec.entry or 'main.lua')
    spec.defaults=relative(spec.defaults or 'config/defaults.cfg')
    assert(spec.entry:match('%.lua$'),'LLL entry must be Lua')
    if spec.modules then
        assert(type(spec.modules)=='table','modules must be a list')
        for _,path in ipairs(spec.modules)do assert(relative(path):match('%.lua$'),'Declared module must be Lua')end
    end
    assert(spec.restart_only==nil or type(spec.restart_only)=='boolean','restart_only must be boolean')
    assert(spec.retain_until_exit==nil or type(spec.retain_until_exit)=='boolean','retain_until_exit must be boolean')
    return spec
end
function M.snapshot(platform,entry,spec)
    local paths,seen={},{}
    local function add(path)
        path=relative(path);if not seen[path]then seen[path]=true;paths[#paths+1]=path end
    end
    add(spec.entry)
    if spec.modules then for _,path in ipairs(spec.modules)do add(path)end
    else
        local function walk(dir,depth)
            assert(depth<=12,'Module directory nesting limit')
            local files,_,dirs=platform.files(entry.dir..'/'..dir)
            for _,file in ipairs(files or {})do if file:match('%.lua$')then add(dir..'/'..file)end end
            for _,child in ipairs(dirs or {})do walk(dir..'/'..relative(child),depth+1)end
        end
        walk('src',1);walk('vendor',1)
    end
    assert(#paths<=512,'Module count limit')
    table.sort(paths)
    local result={spec=spec,code={},chunks={},paths=paths,config_path=platform.settings and platform.settings..'/'..entry.id..'/config.cfg'}
    for _,path in ipairs(paths)do
        local text=assert(platform.read(entry.dir..'/'..path,16777216),'Module unreadable: '..path)
        result.code[path]=text;result.chunks[path]=assert(loadstring(text,'@'..entry.dir..'/'..path))
    end
    for path,text in pairs(result.code)do
        for _,dependency in ipairs(imports(text))do assert(result.code[dependency],path..': undeclared import '..dependency)end
    end
    result.defaults=data(platform.read(entry.dir..'/'..spec.defaults,1048576),entry.dir..'/'..spec.defaults)
    result.user=data(result.config_path and platform.read(result.config_path,1048576),result.config_path or 'config')
    return result
end
function M.fingerprint(platform,entry,spec)
    local paths={spec.entry,spec.defaults,'manifest.json'}
    if spec.modules then for _,path in ipairs(spec.modules)do paths[#paths+1]=path end
    else
        local function walk(dir,depth)
            assert(depth<=12,'Module nesting limit')
            local files,_,dirs=platform.files(entry.dir..'/'..dir)
            for _,file in ipairs(files or {})do if file:match('%.lua$')then paths[#paths+1]=dir..'/'..file end end
            for _,child in ipairs(dirs or {})do walk(dir..'/'..relative(child),depth+1)end
        end
        walk('src',1);walk('vendor',1)
    end
    assert(#paths<=515,'Module count limit');table.sort(paths)
    local parts={}
    for _,path in ipairs(paths)do
        local full=entry.dir..'/'..relative(path)
        local value=platform.stat and platform.stat(full) or platform.read(full,16777216) or '-'
        parts[#parts+1]=#path..':'..path..':'..#value..':'..value
    end
    return table.concat(parts,'|')
end
function M.instantiate(platform,entry,snapshot,report)
    local cache,loading={},{}
    local console_releases={}
    local settings=merge(snapshot.defaults,snapshot.user)
    local scope={};setmetatable(scope,{__index=_G})
    local api={console_active=true,retain_until_exit=snapshot.spec.retain_until_exit==true,id=entry.id,name=entry.metadata and entry.metadata.name or entry.id,dir=entry.dir,scope=scope,config=settings,config_path=snapshot.config_path,config_dir=platform.settings and platform.settings.."/"..entry.id,restart_only=snapshot.spec.restart_only==true}
    scope.mod=api
    if api.config_dir and platform.mkdir then assert(platform.mkdir(api.config_dir),"Cannot create mod config folder")end
    function api.expose(namespace,fields)
        if not platform.command_bus then return false,"Console unavailable" end
        local release=platform.command_bus.register(namespace,api,fields)
        console_releases[#console_releases+1]=release;return release
    end
    function api.release_console()
        for index=#console_releases,1,-1 do console_releases[index]();console_releases[index]=nil end
    end
    function api.require(name,...)
        local path=module_path(name)
        if cache[path]~=nil then return cache[path]end
        assert(not loading[path],'Circular module import: '..path)
        local chunk=assert(snapshot.chunks[path],'Module not declared in this project: '..path);setfenv(chunk,scope)
        loading[path]=true;local called,value=pcall(chunk,...);loading[path]=nil
        if not called then error(value,2)end
        if value==nil then value=true end;cache[path]=value;return value
    end
    function api.read(path)
        return platform.read(entry.dir..'/'..relative(path),16777216)
    end
    function api.set(key,value)
        local valid,problem=pcall(Serialize.serialize,{current=settings,next=value})
        if not valid then return false,tostring(problem)end
        assert(type(key)=='string' and not key:find('[%c]'),'Printable config key required')
        local next_values=copy(settings);next_values[key]=copy(value)
        local called,text=pcall(json,next_values)
        if not called then return false,tostring(text)end
        if not snapshot.config_path then return false,'Settings storage unavailable' end
        if platform.mkdir and not platform.mkdir(platform.settings..'/'..entry.id) then return false,'Cannot create mod settings folder' end
        if not platform.write(snapshot.config_path,text..'\n') then return false,'Cannot save mod config' end
        for field in pairs(settings)do settings[field]=nil end
        for field,item in pairs(next_values)do settings[field]=item end
        return true
    end
    function api.log(message)report('live/'..entry.id,tostring(message))end
    return api.require(snapshot.spec.entry),api
end
return M
