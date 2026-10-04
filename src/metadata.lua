-- Bounded data-only JSON; manifests are never executed as Lua.
local M = {}
function M.decode(text)
    assert(type(text) == "string" and #text <= 65536, "Manifest too large")
    local at = 1
    local parse
    local function space()
        local _, last = text:find("^%s*", at)
        at = (last or at - 1) + 1
    end
    local function string_value()
        assert(text:sub(at, at) == '"')
        at = at + 1
        local out = {}
        while at <= #text do
            local ch = text:sub(at, at)
            at = at + 1
            if ch == '"' then
                return table.concat(out)
            end
            if ch == "\\" then
                ch = text:sub(at, at)
                at = at + 1
                local escape = {
                    ['"'] = '"',
                    ["\\"] = "\\",
                    ["/"] = "/",
                    b = "\b",
                    f = "\f",
                    n = "\n",
                    r = "\r",
                    t = "\t",
                }
                if ch == "u" then
                    local hex = text:sub(at, at + 3)
                    assert(hex:match("^%x%x%x%x$"), "Invalid unicode escape")
                    at = at + 4
                    local n = tonumber(hex, 16)
                    assert(n < 0xd800 or n > 0xdfff, "Unsupported surrogate escape")
                    if n < 128 then
                        ch = string.char(n)
                    elseif n < 2048 then
                        ch = string.char(192 + math.floor(n / 64), 128 + n % 64)
                    else
                        ch = string.char(
                            224 + math.floor(n / 4096),
                            128 + math.floor(n / 64) % 64,
                            128 + n % 64
                        )
                    end
                else
                    ch = assert(escape[ch], "Invalid JSON escape")
                end
            else
                assert(ch:byte() >= 32, "Control in JSON string")
            end
            out[#out + 1] = ch
        end
        error("Unterminated JSON string")
    end
    function parse(depth)
        assert(depth < 12, "Manifest nesting too deep")
        space()
        local ch = text:sub(at, at)
        if ch == '"' then
            return string_value()
        end
        if ch == "{" or ch == "[" then
            local object = ch == "{"
            local closing = object and "}" or "]"
            at = at + 1
            space()
            local value = {}
            if text:sub(at, at) == closing then
                at = at + 1
                return value
            end
            while true do
                local key
                if object then
                    space()
                    key = string_value()
                    space()
                    assert(text:sub(at, at) == ":")
                    at = at + 1
                end
                local item = parse(depth + 1)
                if object then
                    value[key] = item
                else
                    value[#value + 1] = item
                end
                space()
                ch = text:sub(at, at)
                at = at + 1
                if ch == closing then
                    return value
                end
                assert(ch == ",", "Invalid JSON separator")
            end
        end
        for token, value in pairs({ ["true"] = true, ["false"] = false, ["null"] = M }) do
            if text:sub(at, at + #token - 1) == token then
                at = at + #token
                return value
            end
        end
        local token = text:match("^%-?%d+%.?%d*[eE]?[%+%-]?%d*", at)
        assert(token and tonumber(token), "Invalid JSON value")
        at = at + #token
        return tonumber(token)
    end
    local value = parse(0)
    space()
    assert(at > #text, "Trailing JSON data")
    return value
end
local function label(value)
    if type(value) == "table" then
        value = value.name or value.Name
    end
    return type(value) == "string"
            and #value > 0
            and #value <= 512
            and not value:find("[%c]")
            and value
        or nil
end
function M.fields(value)
    if type(value) ~= "table" then
        return {}
    end
    return { author = label(value.author or value.Author), name = label(value.name or value.Name) }
end
function M.read(platform, dir)
    for _, file in ipairs({ "manifest.json", "mod.json", "metadata.json" }) do
        local text = platform.read(dir .. "/" .. file, 65536)
        if text then
            local ok, value = pcall(M.decode, text)
            if ok then
                local fields = M.fields(value)
                fields.path = dir .. "/" .. file
                return fields
            end
        end
    end
    return {}
end
return M
