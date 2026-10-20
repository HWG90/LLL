-- Shared bounded archive catalog; transport supplies optional native hashing.
local default_hash = LLL_DISCOVERY_HASH
if not default_hash and type(jit)=='table' then
    local chunk=assert(loadfile('src/discovery_hash.lua'))
    setfenv(chunk,getfenv(1))
    default_hash=chunk()
end
return function(platform, force)
    local hash = assert(platform.hash or default_hash, 'Archive hash transport unavailable')
    local files = {}
    local winners = {}
    local copies = {}
    local copy_report = {by_name={},notes={}}
    local identities = {}
    local warnings = {}
    local counters = { lua = 0, envelopes = 0, markers = 0, mismatches = 0 }
    local sample
    local listed, stamps = platform.files(platform.data, "9ba626afa44a3aa3.patch_*")
    local diagnostics = "Archive scan: " .. tostring(platform.data) .. "; files=" .. #listed
    for _, name in ipairs(listed) do
        local index = string.match(name, "^9ba626afa44a3aa3%.patch_(%d+)$")
        if index then
            files[#files + 1] = { name = name, index = tonumber(index) }
        end
    end
    table.sort(files, function(a, b)
        if a.index == b.index then
            return a.name < b.name
        end
        return a.index < b.index
    end)
    local signature, cache_path
    if stamps and platform.settings then
        local parts = { "LLL archive cache 3", platform.data }
        for _, file in ipairs(files) do
            parts[#parts + 1] = file.name .. ":" .. assert(stamps[file.name])
        end
        signature = table.concat(parts, "|")
        cache_path = platform.settings .. "/archive_catalog_v3.txt"
        if not force then
            local cache = platform.read(cache_path, 1048576)
            if cache then
                local split = string.find(cache, "\n", 1, true)
                if split and string.sub(cache, 1, split - 1) == signature then
                    local check_end = string.find(cache, "\n", split + 1, true)
                    local body = check_end and string.sub(cache, check_end + 1)
                    local checksum = check_end and string.sub(cache, split + 1, check_end - 1)
                    local names,records = {},{}
                    local valid = body and checksum == hash(body)
                    for line in string.gmatch(body or "", "([^\n]+)\n") do
                        local tag,name,archive,hidden=string.match(line,"^([NH])\t([^\t]+)\t([^\t]+)\t(.*)$")
                        if not tag or not string.match(name,"^mods/[%w_/]+$") or string.find(name,"//",1,true)
                            or string.sub(name,-1)=="/" or name=="mods/codex/loader"
                            or not string.match(archive,"^9ba626afa44a3aa3%.patch_%d+$") then valid=false;break end
                        local duplicates={}
                        for file in string.gmatch(hidden,"[^,]+") do
                            if not string.match(file,"^9ba626afa44a3aa3%.patch_%d+$") then valid=false;break end
                            duplicates[#duplicates+1]=file
                        end
                        local description="Active archive: "..archive.."; hidden copies: "..(#duplicates>0 and table.concat(duplicates,", ") or "none")
                        if tag=="N" then names[#names+1]=name;copy_report.by_name[name]=description
                        else copy_report.notes[#copy_report.notes+1]=name..": declared copy hidden by undeclared/compiled resource in "..archive end
                        records[#records+1]=line
                    end
                    if valid and body==table.concat(records,"\n").."\n" then
                        return names, {}, diagnostics .. "; cached catalog; candidates=" .. #files, copy_report
                    end
                end
            end
        end
    end
    for _, file in ipairs(files) do
        local reader
        local ok, why = pcall(function()
            local path = platform.data .. "/" .. file.name
            reader = platform.archive and platform.archive(path)
            local data = reader and reader.read(0, math.min(104, reader.size))
                or (not platform.archive and platform.read(path))
            assert(data and #data >= 104, "Unreadable archive")
            local size = reader and reader.size or #data
            local function u32(i)
                assert(i >= 0 and i + 4 <= #data, "Truncated archive integer")
                local a,b,c,d = string.byte(data, i + 1, i + 4)
                return a + b * 256 + c * 65536 + d * 16777216
            end
            local function u64(i)
                return string.format("%08x%08x", u32(i + 4), u32(i))
            end
            assert(u32(0) == 0xf0000011, "Unsupported archive")
            local types, count = u32(4), u32(8)
            local table_start = 72 + types * 32
            local table_end = table_start + count * 80
            assert(types > 0 and types <= 100000 and count <= 100000
                and table_end <= size, "Invalid resource table")
            if reader then
                data = assert(reader.read(0, table_end), "Unreadable resource table")
            end
            for i = 0, count - 1 do
                local at = table_start + i * 80
                local key = u64(at)
                local kind = u64(at + 8)
                -- Every winner hides older declarations, including an unmarked override.
                if kind == "a14e8dfa2cd117e2" then
                    counters.lua = counters.lua + 1
                    if winners[key] == nil then
                        identities[#identities + 1] = key
                    end
                    winners[key] = { index = file.index, order = i, archive = file.name }
                    copies[key]=copies[key] or {files={}}
                    local history=copies[key].files
                    if history[#history]~=file.name then history[#history+1]=file.name end
                    local offset = u32(at + 16) + u32(at + 20) * 4294967296
                    local length = u32(at + 56)
                    assert(
                        offset >= table_end and length >= 8 and offset + length <= size,
                        "Invalid resource range"
                    )
                    local prefix = reader
                            and assert(
                                reader.read(offset, math.min(length, 264)),
                                "Unreadable resource prefix"
                            )
                        or string.sub(data, offset + 1, math.min(offset + length, offset + 264))
                    local function prefix_u32(at)
                        local a,b,c,d = string.byte(prefix, at + 1, at + 4)
                        return a + b * 256 + c * 65536 + d * 16777216
                    end
                    if
                        (prefix_u32(4) == 1 or prefix_u32(4) == 2)
                        and prefix_u32(0) == length - 8
                    then
                        counters.envelopes = counters.envelopes + 1
                        local head = string.sub(prefix, 9)
                        local name = string.match(head, "^%-%- HD2%-Addon: ([^\r\n]+)[\r\n]")
                        local computed
                        if name then
                            counters.markers = counters.markers + 1
                            computed = hash(name)
                            if computed ~= key then
                                counters.mismatches = counters.mismatches + 1
                                sample = sample
                                    or (name .. " computed=" .. computed .. " stored=" .. key)
                            end
                        end
                        local valid = name and string.sub(name, 1, 5) == "mods/" and string.sub(name, -1) ~= "/"
                        if valid then
                            local previous
                            for j = 1, #name do
                                local b = string.byte(name, j)
                                if
                                    not (
                                        (b >= 48 and b <= 57)
                                        or (b >= 65 and b <= 90)
                                        or (b >= 97 and b <= 122)
                                        or b == 95
                                        or b == 47
                                    )
                                    or (b == 47 and previous == 47)
                                then
                                    valid = false
                                    break
                                end
                                previous = b
                            end
                        end
                        if valid and name ~= "mods/codex/loader" and computed == key then
                            winners[key].name = name
                            copies[key].name = name
                        end
                    end
                end
            end
        end)
        if reader then
            reader.close()
        end
        if not ok then
            warnings[#warnings + 1] = file.name .. ": " .. tostring(why)
        end
    end
    diagnostics = diagnostics
        .. "; candidates="
        .. #files
        .. "; lua="
        .. counters.lua
        .. "; envelopes="
        .. counters.envelopes
        .. "; markers="
        .. counters.markers
        .. "; hash mismatches="
        .. counters.mismatches
        .. "; sample="
        .. tostring(sample)
    local entries = {}
    for _, key in ipairs(identities) do
        local entry = winners[key]
        if entry.name then
            entries[#entries + 1] = entry
        end
    end
    table.sort(entries, function(a, b)
        if a.index == b.index then
            return a.order < b.order
        end
        return a.index < b.index
    end)
    local records = {}
    for key, history in pairs(copies) do
        if history.name then
            local winner=winners[key];local hidden={}
            for _, file in ipairs(history.files)do if file~=winner.archive then hidden[#hidden+1]=file end end
            local tag=winner.name and "N" or "H"
            records[#records+1]={index=winner.index,order=winner.order,text=tag.."\t"..history.name.."\t"..winner.archive.."\t"..table.concat(hidden,",")}
            if winner.name then copy_report.by_name[history.name]="Active archive: "..winner.archive.."; hidden copies: "..(#hidden>0 and table.concat(hidden,", ") or "none")
            else copy_report.notes[#copy_report.notes+1]=history.name..": declared copy hidden by undeclared/compiled resource in "..winner.archive end
        end
    end
    table.sort(records,function(a,b)return a.index==b.index and a.order<b.order or a.index<b.index end)
    for i,record in ipairs(records)do records[i]=record.text end
    local names = {}
    for _, entry in ipairs(entries) do
        names[#names + 1] = entry.name
    end
    if signature and #warnings == 0 and platform.write then
        local body = table.concat(records, "\n") .. "\n"
        pcall(platform.write, cache_path, signature .. "\n" .. hash(body) .. "\n" .. body)
    end
    return names, warnings, diagnostics, copy_report
end
