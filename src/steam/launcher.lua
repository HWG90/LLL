-- Quote the one-shot native launcher for io.popen; no PowerShell required.
return function(name,pipe)
    assert(type(name)=='string' and name:match('^lll_steam_launcher_[0-9a-f]+%.exe$') and #name==39,'Invalid launcher name')
    assert(type(pipe)=='string' and #pipe>=16 and #pipe<=96 and pipe:match('^[a-z0-9_]+$'),'Invalid launcher pipe')
    local home=assert(os.getenv('LOCALAPPDATA'),'LOCALAPPDATA unavailable')
    assert(not home:find('[%%!"\r\n]') and not home:find('%z'),'Unsupported launcher path')
    return '"'..home..'/LLL/Helldivers2/Service/'..name..'" --pipe '..pipe
end
