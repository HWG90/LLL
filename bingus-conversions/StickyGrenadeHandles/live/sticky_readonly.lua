-- Sticky Grenade Handles port, read-only live checks S0-S7 (build 26088801). Reads only, through Link's Link to
-- Memory (game, exe, read, ptr, get, region, out, fmt; nothing here writes or calls a game function). Every pointer
-- is range-checked before it is followed. Run it at the main menu or on the ship (after the splash screen, once the
-- entity settings are loaded), with or without the mod. See NOTES.md for what each line should show.
local G = assert(game, 'game.dll base')
local X = assert(exe, 'helldivers2.exe base')
local function ok(v) return v and v >= 0x10000 and v < 0x800000000000 end
local function P(a) if not ok(a) then return nil end local v = ptr(a) return ok(v) and v or nil end
local function U32(a) local s = ok(a) and read(a, 4) return s and get(s, 0, 'u32') or nil end
local function U8(a) local s = ok(a) and read(a, 1) return s and s:byte() or nil end
local function h(v) if v == nil then return 'nil' end if type(v) ~= 'number' or v < 0 or v >= 2^53 then return tostring(v) end return fmt('0x%X', v) end
local function cstr(a, n) local s = ok(a) and read(a, n) if not s then return nil end return (s:match('^[^%z]*')) end
out('SGH_LIVE game.dll', h(G), 'exe', h(X))
do -- S0: the mod's own status table (same Lua state), when visible from here
  local okk, st = pcall(function() return rawget(_G, 'StickyGrenadeHandles') end)
  if okk and type(st) == 'table' then out('SGH_S0 version', st.version, 'status', st.status, 'applied', tostring(st.applied),
      'tag', h(st.tag), 'index', st.index)
  else out('SGH_S0 status table not visible from this eval (read StickyGrenadeHandles.log)') end
end
-- S1 entity settings root and the ThrowableComponentData table (getter 0x515370 reads [root+0xF14758])
local ROOT = P(G + 0x2CE41B8)
local T = ROOT and P(ROOT + 0xF14758)
out('SGH_S1 root', h(ROOT), 'throwable table +0xF14758', h(T), '| old field +0xF12C90 holds', h(ROOT and P(ROOT + 0xF12C90)),
    '| next table +0xF14760', h(ROOT and P(ROOT + 0xF14760)))
-- S2 the LDLD header 24 bytes before the table: the mod checks +0 and +4 only and reads the size at +12
if T then
  local s = read(T - 24, 24)
  local hex = {}
  for i = 1, #s do hex[i] = fmt('%02x', s:byte(i)) end
  out('SGH_S2 header', table.concat(hex), 'magic', h(get(s, 0, 'u32')), '(want 0x444C444C)', 'version', get(s, 4, 'u32'),
      '(want 1)', 'type', h(get(s, 8, 'u32')), 'size', get(s, 12, 'u32'), '(>= 1472 + n*360)',
      '+16..+23 (not checked by the mod, may vary)', hex[17] .. hex[18] .. hex[19] .. hex[20] .. hex[21] .. hex[22] .. hex[23] .. hex[24])
end
-- S3 both grenades: slot (hash lo/hi, index at +8), record = T + 1472 + index*360, sticky u8 +0x54, material +0x164
local GRENADES = {{'G-123 Thermite', 0x5747C799, 0xC5C05FCB}, {'sticky stun grenade', 0xF596BC0B, 0x3FA94F58}}
if T then
  local slots = read(T, 92 * 16)
  local size = U32(T - 24 + 12)
  for _, g in ipairs(GRENADES) do
    local found
    for slot = 0, 91 do
      if get(slots, slot * 16, 'u32') == g[2] and get(slots, slot * 16 + 4, 'u32') == g[3] then found = slot break end
    end
    if found then
      local index = get(slots, found * 16 + 8, 'u32')
      local start = 1472 + index * 360
      local rec = T + start
      out('SGH_S3', g[1], 'slot', found, 'index', index, 'in bounds', tostring(size and start + 360 <= size or false),
          'sticky +0x54', U8(rec + 0x54), '(want 1)', 'material +0x164', h(U32(rec + 0x164)), '(want 0xC4692706)')
    else out('SGH_S3', g[1], 'NOT FOUND in 92 slots') end
  end
end
-- S4 material library: [exe+0x286D1D8] -> object, vtable == exe+0x1521A98, RTTI name via vtable[-1]
local L = P(X + 0x286D1D8)
local VT = L and P(L)
out('SGH_S4 library', h(L), 'vtable', h(VT), 'rva', h(VT and VT - X), '(want 0x1521A98)', '| old slot exe+0x27C5CF0 holds',
    h(P(X + 0x27C5CF0)))
if VT then
  local col = P(VT - 8)
  local td_rva = col and U32(col + 12)
  out('SGH_S4 RTTI COL', h(col), 'signature', U32(col and col + 0), 'type', cstr(td_rva and X + td_rva + 16, 40),
      '(want .?AVhknpMaterialLibrary@@)')
end
-- S5 entries: hkArray at +0x48 (data), +0x50 size, +0x54 capacity|flags; 80-byte hknpMaterial, name +0, userData +0x48
local E, N = L and P(L + 0x48), L and U32(L + 0x50)
out('SGH_S5 entries', h(E), 'count', N, 'capacity', L and (U32(L + 0x54) or 0) % 0x40000000, '(0 < count <= 1024)')
if E and N and N > 0 and N <= 1024 then
  for i = 0, N - 1 do
    local e = E + i * 80
    local tag = U32(e + 0x48)
    if tag == 0x9A056E1C or tag == 0xC4692706 then
      local np = P(e)
      local name = np and cstr(np - np % 2, 32)
      out('SGH_S5 material', i, 'tag', h(tag), 'name', name, 'tag address', h(e + 0x48),
          (name == 'sticky_grenade_handle') and ((tag == 0xC4692706) and 'HANDLE: applied' or 'HANDLE: vanilla') or '')
    end
  end
end
-- S6 the write target page (only when the handle was found above): want PAGE_READWRITE 0x4, MEM_COMMIT, MEM_PRIVATE
local okk, st = pcall(function() return rawget(_G, 'StickyGrenadeHandles') end)
local target = okk and type(st) == 'table' and st.tag
if not target and E and N then
  for i = 0, math.min(N, 1024) - 1 do
    local np = P(E + i * 80)
    if np and cstr(np - np % 2, 32) == 'sticky_grenade_handle' then target = E + i * 80 + 0x48 break end
  end
end
if target then
  local rg = region(target)
  out('SGH_S6 target', h(target), 'value', h(U32(target)), rg and fmt('protect 0x%X state 0x%X type 0x%X',
      rg.protection or -1, rg.state or -1, rg.type or -1) or 'region nil')
else out('SGH_S6 no handle material located') end
-- S7 code page residency of the getter the RVA came from (informational; never called)
local rg = region(G + 0x515370)
out('SGH_S7 getter page', rg and fmt('protect 0x%X state 0x%X', rg.protection or -1, rg.state or -1) or 'region nil')
