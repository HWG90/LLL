local serializer = dofile("src/config.lua").serialize
local original = {
    enabled = true,
    disabled = false,
    ratio = 1 / 3,
    array = { 7, "eight", false },
    nested = { empty = {}, text = 'quotes " slash \\ newline\nUnicode: café' },
    [3] = "numeric",
}
local encoded = serializer(original)
assert(encoded:find("\n    [", 1, true))
assert(encoded == serializer(original))
local chunk = assert(loadstring("return " .. encoded))
setfenv(chunk, {})
local restored = chunk()
local function same(a, b)
    assert(type(a) == type(b))
    if type(a) ~= "table" then
        assert(a == b)
        return
    end
    for key, value in pairs(a) do
        same(value, b[key])
    end
    for key in pairs(b) do
        assert(a[key] ~= nil)
    end
end
same(original, restored)
assert(encoded:find("[3]", 1, true) < encoded:find('["array"]', 1, true))
same(
    { enabled = true, nested = { value = 2 } },
    assert(loadstring("return {enabled=true,nested={value=2}}"))()
)
local cycle = {}
cycle.self = cycle
assert(not pcall(serializer, cycle))
assert(not pcall(serializer, { value = 0 / 0 }))
assert(not pcall(serializer, { value = math.huge }))
assert(not pcall(serializer, { value = function() end }))
print(
    "PASS readable config roundtrip, stable mixed keys, escaping, legacy tables and invalid values"
)
