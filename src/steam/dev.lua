-- Temporary review-candidate relay. Directory notifications, two checks/second,
-- 30-minute limit; close() releases its watch and leaves no frame callback.
return function(platform)
    local self={active=true}
    local folder=platform.local_app_data .. '/LLL/Helldivers2/Steam/Commands'
    local output=platform.local_app_data .. '/LLL/Helldivers2/Logs/SteamDevResult.log'
    assert(platform.mkdir(folder),'Cannot create review command directory')
    local started,last=platform.now(),nil
    function self.close()
        if not self.active then return true end
        assert(platform.unwatch(folder),'Cannot release review command watcher')
        self.active=false
        if _G.NOVA_LLL_STEAM_DEV==self then _G.NOVA_LLL_STEAM_DEV=nil end
        platform.maintenance=nil
        return true
    end
    local function execute(text)
        local fn,why=loadstring(text,'@LLL-Steam-review-command')
        local ok,a,b,c=false,why,nil,nil
        if fn then ok,a,b,c=pcall(fn) end
        local result=(ok and 'OK' or 'ERROR')..'\n'..tostring(a)..'\n'..tostring(b)..'\n'..tostring(c)..'\n'
        assert(platform.write(output,result),'Cannot save review command result')
    end
    function self.poll()
        if not self.active then return end
        if platform.now()-started>1800 then return self.close() end
        if not platform.changed(folder) then return end
        local text=platform.read(folder..'/run.lua',1048576)
        if text and text~=last then last=text;execute(text) end
    end
    -- Initial watch acquisition precedes external commands, so a write cannot be
    -- lost between loading the candidate and its first maintenance tick.
    platform.changed(folder)
    _G.NOVA_LLL_STEAM_DEV=self
    return self
end
