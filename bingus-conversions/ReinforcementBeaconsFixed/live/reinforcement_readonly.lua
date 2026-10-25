-- Reinforcement Beacons Fixed port, read-only live checks L0-L9 (build 26088801). Reads only, through Link's Link to
-- Memory (game, exe, read, ptr, get, hashmap, region, out, fmt; nothing here writes or calls a game function). Every
-- pointer is range-checked before it is followed. Run it (a) on the ship, (b) in a mission while alive, (c) right
-- after you die with a teammate's (or your own) reinforcement beacon down, while the reinforcement is queued /
-- the pod pending, and (d) solo after a death (automatic reinforcement). NOTES.md says what each line should show.
local G = assert(game, 'game.dll base')
local E = assert(exe, 'helldivers2.exe base')
local function ok(v) return v and v >= 0x10000 and v < 0x800000000000 end
local function P(a) if not ok(a) then return nil end local v = ptr(a) return ok(v) and v or nil end
local function U32(a) local s = ok(a) and read(a, 4) return s and get(s, 0, 'u32') or nil end
local function U8(a) local s = ok(a) and read(a, 1) return s and s:byte() or nil end
local function F32(a) local s = ok(a) and read(a, 4) return s and get(s, 0, 'f32') or nil end
local function V3(a) local x, y, z = F32(a), F32(a and a + 4), F32(a and a + 8)
  return x and fmt('(%.2f, %.2f, %.2f)', x, y, z) or 'nil' end
local function h(v) return v and fmt('0x%X', v) or 'nil' end
local function pow2(v) if not v or v < 1 then return false end while v > 1 and v % 2 == 0 do v = v / 2 end return v == 1 end
local function band(a, m) return a and (a % (m + 1)) end -- a & m for m = 2^k - 1
out('RBF_LIVE game.dll base', h(G), 'exe', h(E))
do -- L0: the mod's own status table, when visible from this eval
  local okk, st = pcall(function() return rawget(_G, 'ReinforcementBeaconFixData') end)
  if okk and type(st) == 'table' then
    out('RBF_L0 revision', st.revision, 'status', st.status, 'active', tostring(st.active), 'corrections', st.corrections)
  else out('RBF_L0 mod status table not visible from this eval (read ReinforcementBeaconsFixed.log instead)') end
end
-- L1 mission mode: [game+0x2CE1850] (old 0x33266A0): +8 count, +0x40 mode (0 ship / 1..7 gameplay)
local MODE = P(G + 0x2CE1850)
out('RBF_L1 mode object', h(MODE), '+8', U32(MODE and MODE + 8), 'mode +0x40', U32(MODE and MODE + 0x40),
    '(ship: +8 == 0 or mode 0; mission: 1..7)')
-- L2 player manager: [game+0x2CE1618] (old 0x3326468)
local PM = P(G + 0x2CE1618)
local unit_ref, local_id
if PM then
  local state = U32(PM + 0x2E0)
  unit_ref = U32(PM + 0x3A8)
  out('RBF_L2 player manager', h(PM), 'count +0x84', U32(PM + 0x84), 'available +0x88', U32(PM + 0x88),
      'spawn state +0x2E0', state, '(0 before first drop, 1 queued, 2 pod pending, 3 alive)', 'use bit +0x3B4',
      U32(PM + 0x3B4), '(< 32)')
  out('RBF_L2 pending spawn +0x10C', V3(PM + 0x10C), 'countdown +0x12C', F32(PM + 0x12C) and fmt('%.2f', F32(PM + 0x12C)),
      '(state 2: countdown 0.1..5.1 s, XY = where the pod lands)', 'unit ref +0x3A8', h(unit_ref), '(0x7FFF: no unit)',
      'WRITE TARGET would be', h(PM + 0x10C), '8 bytes')
  -- L3 local entity record: [pm+0xE8] -> +8 id, +0x14 bit 0 owned here
  local ENT = P(PM + 0xE8)
  local_id = ENT and U32(ENT + 8)
  out('RBF_L3 local entity', h(ENT), 'id +8', local_id, 'flags +0x14', U8(ENT and ENT + 0x14),
      '(bit 0 = 1: owned on this machine)')
else out('RBF_L2 player manager null (ship / loading)') end
-- L4 reinforcement manager [game+0x2CE1B78] (old 0x33269C0) and position manager [game+0x2CE1CE0] (old 0x3326B20)
local RM, POS = P(G + 0x2CE1B78), P(G + 0x2CE1CE0)
if RM then
  local cap, active = U32(RM + 8), U32(RM + 12)
  local ents, used = P(RM + 0x38), P(RM + 0x48)
  out('RBF_L4 reinforcement manager', h(RM), 'capacity +8', cap, 'active +12', active, 'entities +0x38', h(ents),
      'use bits +0x48', h(used), 'sane', tostring(active and cap and active <= 128 and active <= cap or false))
  local pcount = POS and U32(POS + 8)
  local pcap = POS and U32(POS + 0x30)
  out('RBF_L4 position manager', h(POS), 'count +8', pcount, 'lookup table +0x28', h(P(POS and POS + 0x28)),
      'capacity +0x30', pcap, 'pow2', tostring(pow2(pcap)), 'empty +0x34', h(U32(POS and POS + 0x34)),
      'multiplier +0x38', h(U32(POS and POS + 0x38)), 'positions +0x50', h(P(POS and POS + 0x50)))
  for i = 0, math.min(active or 0, 16) - 1 do
    local e = ents and P(ents + 8 * i)
    local id = e and U32(e + 8)
    local index = POS and id and hashmap(POS + 0x28, id)
    local xyz = index and P(POS + 0x50) and V3(P(POS + 0x50) + 12 * index) or 'nil'
    out('RBF_L4 beacon', i, 'entity', h(e), 'id', id, 'owned', U8(e and e + 0x14) and U8(e + 0x14) % 2,
        'use bits', h(used and U32(used + 4 * i)), 'position index', index, 'position', xyz)
  end
else out('RBF_L4 reinforcement manager null') end
-- L5 active stratagem rows [game+0x2CE1860] (old 0x33266B0): +0x34 count, +0x78 rows of 64 bytes, +12 type, +16 XYZ
local SM = P(G + 0x2CE1860)
if SM then
  local n, rows = U32(SM + 0x34), P(SM + 0x78)
  out('RBF_L5 stratagem manager', h(SM), 'rows +0x34', n, '(<= 512)', 'rows +0x78', h(rows))
  local auto = 0
  for i = 0, math.min(n or 0, 64) - 1 do
    local t = U32(rows + 64 * i + 12)
    if t == 0x7F then auto = auto + 1; out('RBF_L5 automatic reinforcement row (type 0x7F)', i, 'xyz', V3(rows + 64 * i + 16)) end
    if t == 0x7C then out('RBF_L5 row', i, 'type 0x7C (old ReinforcementBeacon id; now TurretMachinegunGPMG): must NOT be an anchor') end
  end
  out('RBF_L5 type-0x7F rows', auto, '(solo: one appears after your death, before the pod; 0 otherwise)')
else out('RBF_L5 stratagem manager null') end
-- L6 entities [game+0x2CE41B8]: unit ref -> index map +0xF24990 (old +0xF22EC8), records +0xF349E0 + 24*i (old
-- +0xF32F18); record +8 must be the local entity id from L3, +12 the engine reference used in L7
local EM = P(G + 0x2CE41B8)
local engine_ref
if EM then
  local cap = U32(EM + 0xF24990 + 8)
  out('RBF_L6 entities', h(EM), 'lookup table', h(P(EM + 0xF24990)), 'capacity', cap, 'pow2', tostring(pow2(cap)),
      'empty', h(U32(EM + 0xF24990 + 12)), 'multiplier', h(U32(EM + 0xF24990 + 16)))
  local index = unit_ref and unit_ref ~= 0x7FFF and hashmap(EM + 0xF24990, unit_ref)
  if index then
    local R = EM + 0xF349E0 + 24 * index
    engine_ref = U32(R + 12)
    out('RBF_L6 unit ref', h(unit_ref), 'index', index, 'record id +8', U32(R + 8), 'local id', local_id,
        (U32(R + 8) == local_id) and 'MATCH' or 'mismatch (ok only while the player has no unit)',
        'engine ref +12', h(engine_ref))
  else out('RBF_L6 no unit for the local player (unit ref', h(unit_ref), ')') end
end
-- L7 exe unit registry [exe+0x1AB76F8] (old 0x1A100F0): slot = ref & 0x3FFFFF < +0x98, generation byte [+0xA0][slot]
-- == ref >> 22, object [+0x88][slot]; [object] vtable slot 0xE8 - exe == 0x28D3A0 (old 0x2BD870); position
-- [object+0x88] + 0x30
local REG = P(E + 0x1AB76F8)
out('RBF_L7 registry', h(REG), 'count +0x98', U32(REG and REG + 0x98), 'generations +0xA0', h(P(REG and REG + 0xA0)),
    'objects +0x88', h(P(REG and REG + 0x88)))
if REG and engine_ref then
  local slot, gen = band(engine_ref, 0x3FFFFF), math.floor(engine_ref / 4194304)
  local gens, objs = P(REG + 0xA0), P(REG + 0x88)
  local obj = objs and P(objs + 8 * slot)
  local vt = obj and P(obj)
  local fn = vt and P(vt + 0xE8)
  out('RBF_L7 slot', slot, 'generation', gen, 'registry generation', gens and U8(gens + slot), 'object', h(obj),
      'vtable', h(vt), 'vtable+0xE8 - exe', h(fn and fn - E), (fn and fn - E == 0x28D3A0) and 'OK (0x28D3A0)' or
      'DIFFERENT', 'unit world position', V3(P(obj and obj + 0x88) and P(obj + 0x88) + 0x30))
end
-- L8 fallback position [game+0x2E287D0] (old 0x346D560) + 0x3C
local FB = P(G + 0x2E287D0)
out('RBF_L8 fallback object', h(FB), 'position +0x3C', V3(FB and FB + 0x3C), '(a world position near the camera/player)')
-- L9 page check of the write target: private read-write data (what api.write requires)
if PM then
  local rg = region(PM + 0x10C)
  out('RBF_L9 write target region', rg and fmt('protect 0x%X state 0x%X type 0x%X', rg.protection or -1, rg.state or -1,
      rg.type or -1) or 'nil', '(expect protect 0x4, state 0x1000, type 0x20000)')
end
return true
