-- Stable Lua-table settings encoding. Existing single-line tables remain readable.
local function serialize(value)
    local active = {}
    local function encode(item, depth)
        assert(depth < 16, "Settings nesting too deep")
        local kind = type(item)
        if kind == "string" then
            return string.format("%q", item)
        end
        if kind == "number" then
            assert(item == item and math.abs(item) < math.huge, "Non-finite settings number")
            return string.format("%.17g", item)
        end
        if kind == "boolean" then
            return item and "true" or "false"
        end
        assert(kind == "table", "Unsupported settings value")
        assert(not active[item], "Cyclic settings table")
        active[item] = true
        local keys = {}
        for key in pairs(item) do
            assert(type(key) == "string" or type(key) == "number", "Unsupported settings key")
            keys[#keys + 1] = key
        end
        table.sort(keys, function(a, b)
            if type(a) ~= type(b) then
                return type(a) == "number"
            end
            return a < b
        end)
        local lines = {}
        for _, key in ipairs(keys) do
            lines[#lines + 1] = string.rep("    ", depth + 1)
                .. "["
                .. encode(key, depth + 1)
                .. "] = "
                .. encode(item[key], depth + 1)
                .. ","
        end
        active[item] = nil
        if #lines == 0 then
            return "{}"
        end
        return "{\n" .. table.concat(lines, "\n") .. "\n" .. string.rep("    ", depth) .. "}"
    end
    return encode(value, 0)
end
return { serialize = serialize }
