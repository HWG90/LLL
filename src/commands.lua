-- Typed mod-owned console commands. Setters own validation and persistence.
local M={}
local Metadata=LLL_METADATA or dofile('src/metadata.lua')
function M.new()
    local providers={};local self={api=1}
    local function lookup(path)
        local namespace,rest=path:match('^([%w_-]+)%.(.+)$')
        local provider=namespace and providers[namespace]
        if provider and type(provider.owner)=="table" then assert(provider.owner.console_active~=false,"Mod cleanup is in progress")end
        return provider and provider.paths[rest]
    end
    function self.register(namespace,owner,spec)
        assert(type(namespace)=='string' and namespace:match('^[%w_-]+$'),'Console namespace required')
        assert(owner~=nil and type(spec)=='table','Console owner and fields required')
        assert(not providers[namespace],'Console namespace already owned: '..namespace)
        local paths={}
        local function flatten(values,prefix,depth)
            assert(depth<12,'Console schema nesting limit')
            for key,value in pairs(values)do
                assert(type(key)=='string' and key:match('^[%w_-]+$') and type(value)=='table','Invalid console field')
                local path=prefix=='' and key or prefix..'.'..key
                if value.get or value.set or value.call then
                    assert(not value.get or type(value.get)=='function');assert(not value.set or type(value.set)=='function');assert(not value.call or type(value.call)=='function')
                    paths[path]=value
                else flatten(value,path,depth+1)end
            end
        end
        flatten(spec,'',0)
        local token={owner=owner,paths=paths};providers[namespace]=token
        local function release()
            if providers[namespace]==token then providers[namespace]=nil end
            return true
        end
        return release
    end
    function self.list()
        local result={}
        for namespace,provider in pairs(providers)do for path in pairs(provider.paths)do result[#result+1]=namespace..'.'..path end end
        table.sort(result);return result
    end
    function self.suggest(command)
        if type(command)~='string' or #command>1024 then return {} end
        local result={};local leading,body=command:match('^(%s*)(.-)$')
        local verb,prefix=body:match('^(%a+)%s+([%w_%.%-]*)$')
        if verb and verb~='get' and verb~='run' and verb~='help' and verb~='list' then return result end
        local path,value=body:match('^([%w_%.%-]+)%s*=%s*([%a]*)$')
        local function add(text,label)result[#result+1]={text=leading..text,label=label or text}end
        if path then
            local namespace,rest=path:match('^([%w_-]+)%.(.+)$');local provider=providers[namespace]
            local field=provider and provider.paths[rest]
            if field and field.set and field.type=='boolean' and not (type(provider.owner)=='table' and provider.owner.console_active==false) then
                for _,choice in ipairs({'false','true'})do if choice:sub(1,#value)==value then add(path..' = '..choice)end end
            end
            return result
        end
        prefix=prefix or body
        if not prefix:match('^[%w_%.%-]*$') then return result end
        if not verb then for _,word in ipairs({'get ','help','list','run '})do if word:sub(1,#prefix)==prefix then add(word)end end end
        for namespace,provider in pairs(providers)do
            if not (type(provider.owner)=='table' and provider.owner.console_active==false) then
                for name,field in pairs(provider.paths)do
                    local full=namespace..'.'..name
                    if full:sub(1,#prefix)==prefix and (verb~='run' or field.call) and (verb~='get' or field.get) then
                        add((verb and verb..' ' or '')..full)
                    end
                end
            end
        end
        table.sort(result,function(a,b)return a.text<b.text end);return result
    end
    local function parse(value)
        local number=tonumber(value)
        if number then assert(number==number and math.abs(number)<math.huge,'Finite number required');return number end
        if value=='true' then return true elseif value=='false' then return false end
        return Metadata.decode(value)
    end
    function self.execute(command)
        local ok,success,message=pcall(function()
            assert(type(command)=='string' and #command<=1024,'Command exceeds 1024 characters')
            command=command:match('^%s*(.-)%s*$')
            if command=='help' or command=='list' or command:match('^help%s+[%w_%.%-]+$') or command:match('^list%s+[%w_%.%-]+$')then
                local prefix=command:match('^%w+%s+([%w_%.%-]+)$');local selected={}
                for _,path in ipairs(self.list())do if not prefix or path:sub(1,#prefix)==prefix then selected[#selected+1]=path end end
                return true,'Commands:\n'..table.concat(selected,'\n')
            end
            local path,value=command:match('^([%w_%.%-]+)%s*=%s*(.-)%s*$')
            local action=command:match('^run%s+([%w_%.%-]+)$')
            path=path or action or command:match('^get%s+([%w_%.%-]+)$') or command:match('^([%w_%.%-]+)$')
            assert(path,'Use namespace.field = value, get namespace.field, or run namespace.action')
            local field=assert(lookup(path),'Unknown command: '..path)
            if value~=nil then
                assert(field.set,'Read-only field: '..path)
                local typed=parse(value)
                if field.type then assert(type(typed)==field.type,'Expected '..field.type..' for '..path)end
                if type(typed)=='number' then assert(not field.min or typed>=field.min,'Value below minimum');assert(not field.max or typed<=field.max,'Value above maximum')end
                if field.validate then assert(field.validate(typed)~=false,'Value rejected')end
                local accepted,why=field.set(typed)
                if accepted==false then return false,tostring(why or 'Setter refused')end
                local reported=typed;if field.get then reported=field.get()end
                return true,why or (path..' = '..tostring(reported))
            end
            if action or (field.call and not field.get)then
                assert(field.call,'Command is not an action: '..path)
                local accepted,why=field.call();return accepted~=false,tostring(why or (accepted==false and 'Action refused' or 'Completed '..path))
            end
            assert(field.get,'Field is not readable: '..path)
            return true,path..' = '..tostring(field.get())
        end)
        if not ok then return false,tostring(success)end
        return success,message
    end
    return self
end
return M
