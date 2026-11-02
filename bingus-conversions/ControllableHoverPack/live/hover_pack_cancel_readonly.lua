-- Controllable Hover Pack port, read-only live checks L0-L5 (build 26088801). Reads only (read/ptr/get/region; no
-- write, no game function call). Every pointer is range-checked before it is followed; map probes are bounded.
-- Run it (a) on the ship, (b) in a mission wearing the LIFT-860 Hover Pack while standing, (c) while hovering with
-- the jump key held, and (d) once more after the hover runs out (falling/landing). See NOTES.md for what each line
-- should show; L5 decides whether the blocked duration write (+0x9c) can be accepted.
local G = assert(game, 'game.dll base')
local function ok(v) return v and v >= 0x10000 and v < 0x800000000000 end
local function P(a) if not ok(a) then return nil end local v = ptr(a) return ok(v) and v or nil end
local function U32(a) local s = ok(a) and read(a, 4) return s and get(s, 0, 'u32') or nil end
local function U8(a) local s = ok(a) and read(a, 1) return s and s:byte() or nil end
local function F32(a) local s = ok(a) and read(a, 4) return s and get(s, 0, 'f32') or nil end
local function U64(a) local s = ok(a) and read(a, 8) if not s then return nil end return get(s, 0, 'u32'), get(s, 4, 'u32') end
local function H64(lo, hi) return lo and fmt('0x%08X%08X', hi, lo) or 'nil' end
local function h(v) return v and fmt('0x%X', v) or 'nil' end
local function f(v) return v and fmt('%.4f', v) or 'nil' end
local function pow2(v) if not v or v < 1 then return false end while v > 1 and v % 2 == 0 do v = v / 2 end return v == 1 end
-- (a*b) mod 2^32 exactly in doubles
local function mul32(a, b) local hi, lo = math.floor(a / 65536), a % 65536 return (hi * b % 65536 * 65536 + lo * b) % 4294967296 end
-- open-addressed map {data u64, capacity u32, empty u32, multiplier u32} as the mod probes it; index or nil, and why
local function lookup(header, key, limit)
  local data, cap, empty, mult = P(header), U32(header + 8), U32(header + 12), U32(header + 16)
  if not data or not cap or cap == 0 or cap > limit or not pow2(cap) then return nil, 'bad map ' .. tostring(cap) end
  local product = mul32(key, mult)
  for probe = 0, math.min(cap, 64) - 1 do
    local row = data + 8 * ((product + probe) % cap)
    local k = U32(row)
    if k == key then local i = U32(row + 4) if i ~= 0xFFFFFFFF then return i end return nil, 'removed' end
    if k == empty then return nil, 'absent' end
  end
  return nil, 'not found in 64 probes'
end
local AVATAR_LO, AVATAR_HI = 0x294DFA97, 0x4D1C334D
local HOVER_LO, HOVER_HI = 0x1CDB66CF, 0x5EC80F4F
out('CHP_LIVE game.dll base', h(G), 'exe', h(exe))
do -- L0: the mod's own status table, when visible from this eval
  local okk, st = pcall(function() return rawget(_G, 'HoverPackCancel') end)
  if okk and type(st) == 'table' then out('CHP_L0 revision', st.revision, 'status', st.status, 'snapshot', st.snapshot_status,
      'cancellations', st.cancellations, 'restorations', st.restorations)
  else out('CHP_L0 mod status table not visible from this eval (read ControllableHoverPack.log instead)') end
end
-- L1: mission state, local player, avatar
local MODE, PM, ENT = P(G + 0x2CE1850), P(G + 0x2CE1618), P(G + 0x2CE41B8)
local AM, EQ, JM, ATT = P(G + 0x2CE1EE0), P(G + 0x2CE18E8), P(G + 0x2CE1D78), P(G + 0x2CE1F88)
out('CHP_L1 globals mode', h(MODE), 'players', h(PM), 'entities', h(ENT), 'avatars', h(AM), 'equipment', h(EQ),
    'jump packs', h(JM), 'attachments', h(ATT))
out('CHP_L1 mission active +8', U32(MODE and MODE + 8), 'type +0x40', U32(MODE and MODE + 0x40), '(ship: 0; mission: nonzero and 1..7)')
local unit = U32(PM and PM + 0x3A8)
local player = P(PM and PM + 0xE8)
out('CHP_L1 players +0x84', U32(PM and PM + 0x84), '+0x88', U32(PM and PM + 0x88), 'local unit +0x3a8', unit,
    '(0x7FFF none)', 'local player owned (+0x14 bit0)', player and (U8(player + 0x14) or 0) % 2)
local avatar, ai, entity
if ENT and unit and unit ~= 0x7FFF then
  local ei, why = lookup(ENT + 0xF24990, unit, 1048576)
  if ei then
    avatar = ENT + 0xF349E0 + 24 * ei
    local lo, hi = U64(avatar)
    entity = U32(avatar + 8)
    out('CHP_L1 avatar record index', ei, 'hash', H64(lo, hi), (lo == AVATAR_LO and hi == AVATAR_HI) and 'avatar_helldiver OK' or 'MISMATCH',
        'entity', entity, 'owned', (U8(avatar + 20) or 0) % 2)
  else out('CHP_L1 unit not in entities +0xF24990 map:', why) end
end
if AM and entity then
  local idx, why = lookup(AM + 0xF8, entity, 64)
  local count = U32(AM + 0x6C)
  local slot = idx and P(AM + 0x110 + 8 * idx)
  out('CHP_L1 avatar manager index', idx or why, 'count +0x6c', count, 'slot +0x110 points at the avatar record',
      tostring(slot ~= nil and slot == avatar or (slot and U32(slot + 8) == entity) or false))
  ai = idx
end
if AM and ai then
  local block = AM + 0x53D900 + ai * 0x1240 + 0xF88
  out('CHP_L1 movement flags (new base +0x53d900+i*0x1240+0xf88): +8', h(U32(block + 8)), '+12', h(U32(block + 12)),
      '| bit31(+8)', math.floor((U32(block + 8) or 0) / 2^31) % 2, '+12 bits 2/4/5', math.floor((U32(block + 12) or 0) / 4) % 2,
      math.floor((U32(block + 12) or 0) / 16) % 2, math.floor((U32(block + 12) or 0) / 32) % 2,
      '(airborne hover: +12 bit2 = 1, bits 4/5 = 0, +8 bit31 = 0)')
  out('CHP_L1 old-stride reading for comparison (0x1238/0xf80): +8', h(U32(AM + 0x53D900 + ai * 0x1238 + 0xF80 + 8)))
  local held = F32(AM + 0x150 + ai * 0xA7AEC + 0x1B68 + 15 * 32 + 8)
  out('CHP_L1 jump input slot 15 held time', f(held), '(0 released; grows while the jump key is held)')
end
-- L3: backpack, jump-pack registry, attachment
local pack, ji, packrec
if EQ and entity then
  local qi, why = lookup(EQ + 40, entity, 8192)
  if qi then
    local ids, rows = P(EQ + 64), P(EQ + 80)
    pack = rows and U32(rows + qi * 48 + 12)
    out('CHP_L3 equipment row', qi, 'identity pointer -> avatar record', tostring(ids and P(ids + 8 * qi) == avatar),
        'backpack id (+12)', pack)
  else out('CHP_L3 no equipment row:', why) end
end
if JM then
  out('CHP_L3 jump packs total +12', U32(JM + 12), 'active +16', U32(JM + 16), 'local +20', U32(JM + 20))
  if pack and pack ~= 0 and pack ~= 0xFFFFFFFF then
    local why
    ji, why = lookup(JM + 32, pack, 128)
    if ji then
      local entries, states = P(JM + 56), P(JM + 80)
      packrec = entries and P(entries + 8 * ji)
      local lo, hi = U64(packrec)
      out('CHP_L3 pack registry index', ji, 'record hash', H64(lo, hi), (lo == HOVER_LO and hi == HOVER_HI) and 'HOVER PACK' or 'other pack',
          'id +8', U32(packrec and packrec + 8), '(= backpack id)', 'owned', (U8(packrec and packrec + 20) or 0) % 2)
      if states then
        local b = {}
        for i = 0, 4 do b[#b + 1] = U8(states + 5 * ji + i) end
        out('CHP_L4 state bytes', table.concat(b, ' '), '(standing 0 x x x 0; powered hover 1 0 1 0 1; expired 1 0 1 0 0;',
            'landing assistance 1 1 1 0 x)')
      end
    else out('CHP_L3 backpack is not in the jump-pack registry:', why) end
  end
end
if ATT and pack and ji then
  local bi, why = lookup(ATT + 32, pack, 8192)
  local rows = P(ATT + 64)
  out('CHP_L3 attachment row', bi or why, 'holder (+4) = avatar entity', tostring(bi and rows and U32(rows + bi * 48 + 4) == entity or false))
end
-- L5: override storage and the hover duration (decides the blocked write)
if JM then
  local cap, count, data = U32(JM + 4), U32(JM + 0x98), P(JM + 0xA0)
  out('CHP_L5 overrides capacity +4', cap, '(expect 32)', 'count +0x98', count, '(expect 0..capacity; 0 unless a pack was cancelled)',
      'records +0xa0', h(data))
  for _, m in ipairs({{0x60, 'forward'}, {0x80, 'reverse'}}) do
    out('CHP_L5', m[2], 'map +' .. h(m[1]), 'data', h(P(JM + m[1])), 'capacity', U32(JM + m[1] + 8), 'empty', h(U32(JM + m[1] + 12)),
        'multiplier', U32(JM + m[1] + 16), '(engine init: capacity 64, multiplier 2; reverse empty 0xFFFFFFFF)')
  end
  if data then
    local rg = region(data)
    out('CHP_L5 records region', rg and fmt('protect 0x%X state 0x%X type 0x%X', rg.protection or -1, rg.state or -1, rg.type or -1) or 'nil',
        '(expect protect 0x4 PAGE_READWRITE, state 0x1000, type 0x20000 MEM_PRIVATE)')
  end
  if pack and ji then
    local oi, why = lookup(JM + 0x60, pack, 256)
    if oi and data then
      local r = data + 0x118 * oi
      out('CHP_L5 this pack has an override', oi, '+0x98', U8(r + 0x98), '+0x99', U8(r + 0x99), '+0x9c', f(F32(r + 0x9c)))
    else out('CHP_L5 this pack has no override (', why, ')') end
  end
end
if ENT then
  local T = P(ENT + 0xF14780)
  out('CHP_L5 shared jump-pack resource table entities+0xF14780', h(T))
  if T then
    for i = 0, 5 do
      local lo, hi = U64(T + 16 * i)
      local idx = U32(T + 16 * i + 8)
      local line = {'CHP_L5 resource', i, H64(lo, hi), 'index', idx}
      if lo and (lo ~= 0 or hi ~= 0) and idx and idx < 3 then
        local r = T + 0x60 + 0x118 * idx
        line[#line + 1] = '+0x98 ' .. tostring(U8(r + 0x98)) .. ' +0x99 ' .. tostring(U8(r + 0x99)) .. ' +0x9a ' .. tostring(U8(r + 0x9a)) ..
          ' +0x9c ' .. f(F32(r + 0x9c)) .. ((lo == HOVER_LO and hi == HOVER_HI) and '  <- HOVER: expect +0x99 = 1 and +0x9c = 6.0000 (seconds)' or '')
      end
      out((table.unpack or unpack)(line))
    end
  end
end
return true
