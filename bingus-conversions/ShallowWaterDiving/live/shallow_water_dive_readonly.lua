-- Shallow Water Diving port, read-only live checks L1-L9 (build 26088801). Reads only (read/ptr/get/region; nothing
-- here writes or calls a game function). Every pointer is range-checked before it is followed; map lookups are done
-- here with bounded reads, exactly as the mod does. Run it (a) on the ship, (b) in a mission standing on dry ground,
-- (c) crouched / prone, (d) standing in shallow water, (e) right after starting a dive (hold the probe on a key or
-- run it a few times while diving). See NOTES.md for what each line should show.
local G = assert(game, 'game.dll base')
local function ok(v) return v and v >= 0x10000 and v < 0x800000000000 end
local function P(a) if not ok(a) then return nil end local v = ptr(a) return ok(v) and v or nil end
local function U32(a) local s = ok(a) and read(a, 4) return s and get(s, 0, 'u32') or nil end
local function U8(a) local s = ok(a) and read(a, 1) return s and s:byte() or nil end
local function F32(a) local s = ok(a) and read(a, 4) return s and get(s, 0, 'f32') or nil end
local function h(v) return v and fmt('0x%X', v) or 'nil' end
local function f(v) return v and fmt('%.4f', v) or 'nil' end
local function band(a, b) local r, bit = 0, 1 while a > 0 and b > 0 do if a % 2 == 1 and b % 2 == 1 then r = r + bit end a, b, bit = math.floor(a / 2), math.floor(b / 2), bit * 2 end return r end
-- low 32 bits of key * mult, exact in doubles (16-bit halves)
local function mul32(k, m) local kl, kh, ml, mh = k % 65536, math.floor(k / 65536), m % 65536, math.floor(m / 65536) return (kl * ml + ((kh * ml + kl * mh) % 65536) * 65536) % 4294967296 end
-- the game's open-addressed map: header {u64 rows, u32 capacity, u32 empty, u32 mult}; rows {u32 key, u32 index}
local function lookup(header, key, limit)
  local rows, cap, empty, mult = P(header), U32(header + 8), U32(header + 12), U32(header + 16)
  if not rows or not cap or cap == 0 or cap > limit then return nil, 'map ' .. h(header) .. ' cap ' .. tostring(cap) end
  local base = mul32(key, mult)
  for probe = 0, math.min(cap, 128) - 1 do
    local row = rows + 8 * ((base + probe) % cap)
    local k = U32(row)
    if k == key then return U32(row + 4) end
    if k == nil or k == empty then return nil, 'absent' end
  end
  return nil, 'not found in 128 probes'
end
local function rec24(a) local t = {} for i = 0, 5 do t[i] = U32(a + 4 * i) end return t end
local function same(a, b) for i = 0, 5 do if a[i] == nil or a[i] ~= b[i] then return false end end return true end
out('SWD_LIVE game.dll base', h(G), 'exe', h(exe))
do -- L0: the mod's own status table (same Lua state), when visible from here
  local okk, st = pcall(function() return rawget(_G, 'ShallowWaterDive') end)
  if okk and type(st) == 'table' then
    out('SWD_L0 revision', st.revision, 'status', st.status, 'active', tostring(st.active), 'observed', st.observed,
        'protected', st.protected, 'restored', st.restored, 'depth_option', tostring(st.depth_option))
  else out('SWD_L0 mod status table not visible from this eval (read ShallowWaterDiving.log instead)') end
end
-- L1 mission object
local MODE = P(G + 0x2CE1850)
out('SWD_L1 mission object', h(MODE), '+8', h(U32(MODE and MODE + 8)), '+0x40', U32(MODE and MODE + 0x40),
    '(mod waits unless +8 ~= 0 and +0x40 in 1..7; expect waiting on the ship, 1..7 in a mission)')
-- L2 local player -> entity record
local PM, ENT = P(G + 0x2CE1618), P(G + 0x2CE41B8)
local id, entity
if PM and ENT then
  local total, here, unit = U32(PM + 0x84), U32(PM + 0x88), U32(PM + 0x3A8)
  local player = P(PM + 0xE8)
  out('SWD_L2 player manager', h(PM), 'counts', total, here, 'player', h(player), 'owned bit', player and band(U8(player + 20) or 0, 1),
      'unit +0x3A8', h(unit), '(0x7FFF = no avatar)')
  if unit and unit ~= 0x7FFF then
    local ei, why = lookup(ENT + 0xF24990, unit, 1048576)
    if ei and ei ~= 0xFFFFFFFF then
      local a = ENT + 0xF349E0 + 24 * ei
      entity = rec24(a)
      id = entity[2]
      out('SWD_L2 entity index', ei, 'record', h(a), 'hash', fmt('0x%08X%08X', entity[1] or 0, entity[0] or 0),
          '(expect 0x4D1C334D294DFA97)', 'id', id, 'owned bit', band(entity[5] or 0, 1))
    else out('SWD_L2 entity lookup failed:', tostring(why)) end
  end
else out('SWD_L2 player manager or entities null', h(PM), h(ENT)) end
-- L3 avatar manager: registry, per-avatar record (stride 0x1240), dive record +0xB84, flags +0xF88
local AM = P(G + 0x2CE1EE0)
if AM and id then
  local count = U32(AM + 0x6C)
  local ai, why = lookup(AM + 0xF8, id, 64)
  out('SWD_L3 avatar manager', h(AM), 'count', count, 'index', tostring(ai), tostring(why or ''))
  if ai and ai ~= 0xFFFFFFFF and count and ai < count then
    local reg = P(AM + 0x110 + 8 * ai)
    out('SWD_L3 registry entry', h(reg), 'same 24 bytes as the entity record', tostring(reg and same(rec24(reg), entity)))
    local c = AM + 0x53D900 + ai * 0x1240
    local q1lo, q1hi = U32(c + 0xF90), U32(c + 0xF94)
    out('SWD_L3 controller', h(c), 'id +0xB84', U32(c + 0xB84), '(expect', id, ')', 'elapsed +0xB8C', f(F32(c + 0xB8C)),
        'landing +0xB90', f(F32(c + 0xB90)))
    out('SWD_L3 flags q0', h(U32(c + 0xF88)), h(U32(c + 0xF8C)), 'q1', h(q1lo), h(q1hi), 'q2', h(U32(c + 0xF98)), h(U32(c + 0xF9C)),
        '| dive', q1hi and band(q1hi, 0x20) ~= 0, 'swim', q1lo and q1lo >= 0x80000000, 'ragdoll', q1hi and band(q1hi, 0x10) ~= 0,
        '(dive true only while diving; swim true only while swimming)')
    out('SWD_L3 old layout for comparison: id at 25480438 stride', U32(AM + 0x53D900 + ai * 0x1238 + 0xB84),
        'q1 at +0xF88', h(U32(c + 0xF88)), h(U32(c + 0xF8C)), '(index 0 cannot tell the strides apart)')
  end
end
-- L4 Drownable manager and the record the mod writes (+8 offset, +16 drown elapsed)
local DM = P(G + 0x2CE1C40)
local water
if DM and id then
  local capacity = U32(DM + 8)
  local di, why = lookup(DM + 0x20, id, 32768)
  out('SWD_L4 Drownable manager', h(DM), 'capacity +8', capacity, 'index', tostring(di), tostring(why or ''))
  if di and di ~= 0xFFFFFFFF and capacity and di < capacity then
    local owners, data, enabled = P(DM + 0x38), P(DM + 0x40), P(DM + 0x48)
    local owner = owners and P(owners + 8 * di)
    out('SWD_L4 owner entry', h(owner), 'same 24 bytes as the entity record', tostring(owner and same(rec24(owner), entity)))
    if data then
      water = data + 28 * di
      out('SWD_L4 record', h(water), 'deep +1', U8(water + 1), 'node +4', U32(water + 4), '(expect 0)', 'offset +8',
          f(F32(water + 8)), 'drown elapsed +16', f(F32(water + 16)), 'remaining +20', f(F32(water + 20)), 'surface +24',
          f(F32(water + 24)), 'enabled', enabled and U8(enabled + 2 * di), enabled and U8(enabled + 2 * di + 1))
      local rg = region(water)
      out('SWD_L4 record region', rg and fmt('protect 0x%X state 0x%X type 0x%X', rg.protection or -1, rg.state or -1,
          rg.type or -1) or 'nil', '(expect protect 0x4, state 0x1000, type 0x20000: what the mod\'s page check requires)')
    end
  end
end
-- L5 stance: offset +8 should equal base -1.3 plus 0 (standing), 0.4 (crouch) or 0.9 (prone)
local SM = P(G + 0x2CE1748)
if SM and id then
  local si, why = lookup(SM + 0x18, id, 8192)
  local stances = P(SM + 0x38)
  local stance = si and si ~= 0xFFFFFFFF and stances and U32(stances + 56 * si + 28)
  local expect = stance == 0 and -1.3 or stance == 1 and -0.9 or stance == 2 and -0.4 or nil
  out('SWD_L5 stance manager', h(SM), 'index', tostring(si), tostring(why or ''), 'stance +28', tostring(stance),
      '(0 stand, 1 crouch, 2 prone, 3 transition)', '| water offset', f(water and F32(water + 8)), 'expected', f(expect),
      '(outside a mod-held dive)')
end
-- L6 movement: root z
local MM = P(G + 0x2CE1708)
if MM and id then
  local mi, why = lookup(MM + 0x48A0, id, 16384)
  local pos = P(MM + 0x48D8)
  local rec = mi and mi ~= 0xFFFFFFFF and pos and pos + 44 * mi
  out('SWD_L6 movement manager', h(MM), 'index', tostring(mi), tostring(why or ''), 'root z +8', f(rec and F32(rec + 8)),
      'valid +32', rec and U8(rec + 32), '| surface - root z', f(water and rec and (F32(water + 24) or 0) - (F32(rec + 8) or 0)),
      '(positive and small in shallow water)')
end
-- L7 Drownable settings table: entities + 0xF148E8 -> 122 slots {u64 hash, u32 index}, records at +0x7A0, 64 bytes
local T = ENT and P(ENT + 0xF148E8)
out('SWD_L7 settings table', h(T), '| old +0xF12E20 holds', h(ENT and P(ENT + 0xF12E20)))
if T then
  local index, used = nil, 0
  for slot = 0, 121 do
    local lo, hi = U32(T + 16 * slot), U32(T + 16 * slot + 4)
    if lo and hi and (lo ~= 0 or hi ~= 0) then used = used + 1 end
    if lo == 0x294DFA97 and hi == 0x4D1C334D then index = U32(T + 16 * slot + 8) end
  end
  local R = index and T + 0x7A0 + 64 * index
  out('SWD_L7 slots used', used, 'avatar index', tostring(index), '(mod requires 5)', 'record +0', h(R and U32(R)),
      '(mod requires 0x4A182741)', 'base +4', f(R and F32(R + 4)), '(mod requires -1.3)')
end
-- L8 game.dll read-only constants the mod verifies once per session
out('SWD_L8 timeout', f(F32(G + 0x2246948)), '(2.0)', 'fallback', f(F32(G + 0x2246938)), '(not 2.0, inert)',
    'prone', f(F32(G + 0x22464EC)), '(0.9)', 'crouch', f(F32(G + 0x2246210)), '(0.4)')
-- L9 Text Language (bingus_text): settings + 705628 + 212 -> index < 15 -> record table -> code string
local S = P(G + 0x2CE1508)
local li = S and U32(S + 705628 + 212)
local rec = li and li < 15 and P(G + 0x3180DE0 + 8 * li)
local str = rec and P(rec + 8)
local code = str and read(str, 8)
out('SWD_L9 language index', tostring(li), 'code', code and code:match('^(%a[%a%-]*)') or 'nil', '(us for English)')
return true
