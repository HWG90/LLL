-- Laser Sentry Cooldown port, read-only live checks L1-L6 (build 26088801). Reads only, through Link's Link to Memory
-- (read/ptr/get/region; nothing here writes or calls a game function). Every pointer is range-checked before it is
-- followed. Run it once on the ship (L1, L2) and in a mission with your own A/LAS-98 Laser Sentry deployed: once
-- while it fires, once right after it overheats, and again ~50 s later. See NOTES.md for the expected values.
local G = assert(game, 'game.dll base')
local function ok(v) return v and v >= 0x10000 and v < 0x800000000000 end
local function P(a) if not ok(a) then return nil end local v = ptr(a) return ok(v) and v or nil end
local function U32(a) local s = ok(a) and read(a, 4) return s and get(s, 0, 'u32') or nil end
local function U8(a) local s = ok(a) and read(a, 1) return s and s:byte() or nil end
local function F32(a) local s = ok(a) and read(a, 4) return s and get(s, 0, 'f32') or nil end
local function U64(a) local s = ok(a) and read(a, 8) if not s then return nil end return get(s, 0, 'u32'), get(s, 4, 'u32') end
local function h(v) return v and fmt('0x%X', v) or 'nil' end
local function f(v) return v and fmt('%.3f', v) or 'nil' end
local function pow2(v) if not v or v < 1 then return false end while v > 1 and v % 2 == 0 do v = v / 2 end return v == 1 end
local RES_LO, RES_HI = 0xCFFFA8A8, 0x56070F36 -- laser_cannon_turret
local SLOTS, RECORDS, RECORD = 60, 960, 592
out('LSC_LIVE game.dll base', h(G))
do -- L0: the mod's own install flag (same Lua state), when visible from here
  local okk, v = pcall(function() return rawget(_G, 'LaserSentryCooldownInstalled') end)
  out('LSC_L0 installed flag', okk and tostring(v) or 'not visible (read LaserSentryCooldown.log)')
end
-- L1 heat table: [[game+0x2CE41B8]+0xF14790], header 24 bytes before, 60 slots, records at +960
local N = P(G + 0x2CE41B8)
local T = N and P(N + 0xF14790)
local olo, ohi = U64(N and N + 0xF12CC8)
out('LSC_L1 entities', h(N), 'heat table +0xF14790', h(T), '| old +0xF12CC8 holds', olo and fmt('0x%08X%08X', ohi, olo) or 'nil')
local REC
if T then
  out('LSC_L1 header magic', h(U32(T - 24)), '(0x444C444C)', 'version', U32(T - 20), '(1)', 'type', h(U32(T - 16)),
      '(0x4C981CD9)', 'size', h(U32(T - 12)), '(>= 0x3C0 + 0x250*n; 0x4920 or more expected)')
  local hi = U32(T - 12)
  local slot = ((RES_HI % SLOTS) * (4294967296 % SLOTS) + RES_LO % SLOTS) % SLOTS
  local used = 0
  for s = 0, SLOTS - 1 do local lo = U32(T + 16 * s) if lo and lo ~= 0 then used = used + 1 end end
  local index
  for _ = 1, SLOTS do
    local lo, hh = U32(T + 16 * slot), U32(T + 16 * slot + 4)
    if lo == RES_LO and hh == RES_HI then index = U32(T + 16 * slot + 8) break end
    if lo == 0 and hh == 0 then break end
    slot = (slot + 1) % SLOTS
  end
  out('LSC_L1 slots used', used, 'laser sentry slot', slot, 'index', index,
      'records in size', hi and math.floor((hi - RECORDS) / RECORD))
  if index then REC = T + RECORDS + RECORD * index end
  -- the same lookup with the OLD layout (58 slots, +928) must NOT find a sane record
  local s58 = ((RES_HI % 58) * (4294967296 % 58) + RES_LO % 58) % 58
  out('LSC_L1 old-layout probe slot', s58, 'holds', h(U32(T + 16 * s58)), '(the 58-slot layout is gone: usually not 0xCFFFA8A8)')
end
-- L2 the Laser Sentry heat record
if REC then
  out('LSC_L2 record', h(REC), 'enabled +0x50', U8(REC + 0x50), '(1)', 'magazines +0x54', U32(REC + 0x54), '(0)',
      'max +0x5C', U32(REC + 0x5C), '(0)', 'overheat +0x60', f(F32(REC + 0x60)), '(250)', 'recover +0x64',
      f(F32(REC + 0x64)), '(0)')
  out('LSC_L2 heat/s +0x78', f(F32(REC + 0x78)), 'idle cooling +0x80', f(F32(REC + 0x80)), '(5)', 'overheated cooling +0x8C',
      f(F32(REC + 0x8C)), '(vanilla 400, mod = idle rate)', 'needs reload +0x90', U8(REC + 0x90), '(vanilla 1, mod 0)',
      'fire threshold +0x94', f(F32(REC + 0x94)))
  out('LSC_L2 overheat ability +0x248', U32(REC + 0x248), '(vanilla 2884 expected in 26088801; 2866 was 25480438; mod 0)')
  local r = region(REC + 0x8C)
  out('LSC_L2 record page', r and h(r.protection), r and h(r.state), r and h(r.type), '(0x2 readonly, 0x1000, 0x20000 private)')
else out('LSC_L2 no Laser Sentry heat record found (on the ship the weapon data should already exist)') end
-- L3 WeaponHeat manager [game+0x2CE1F08]: +0x14 count, +0x40 entity record pointers, +0x58 12-byte states
local HM = P(G + 0x2CE1F08)
local count = HM and U32(HM + 0x14)
local recs, states = HM and P(HM + 0x40), HM and P(HM + 0x58)
out('LSC_L3 heat manager', h(HM), 'counts +0x14/+0x18/+0x1C', count, U32(HM and HM + 0x18), U32(HM and HM + 0x1C),
    'records +0x40', h(recs), 'states +0x58', h(states))
local BM = P(G + 0x2CE18F0)
local function block_of(id, rec)
  if not BM then return nil, 'no behavior manager' end
  local n, ents, cap, empty, mul = U32(BM + 0x34), P(BM + 0x40), U32(BM + 0x48), U32(BM + 0x4C), U32(BM + 0x50)
  local brecs, blocks = P(BM + 0x58), P(BM + 0x60)
  if not (n and ents and pow2(cap) and brecs and blocks) then return nil, 'unexpected behavior manager' end
  local start = (id % cap) * (mul % cap) % cap
  for k = 0, math.min(cap, 64) - 1 do
    local at = ents + 8 * ((start + k) % cap)
    local key, value = U32(at), U32(at + 4)
    if key == empty then return nil, 'no behavior' end
    if key == id then
      if value >= n then return nil, 'index >= count' end
      if P(brecs + 8 * value) ~= rec then return nil, 'behavior of another entity' end
      return blocks + 504 * value, value
    end
  end
  return nil, 'probe limit'
end
if HM and recs and states and count and count > 0 and count <= 160 then
  for i = 0, count - 1 do
    local rec = P(recs + 8 * i)
    local lo, hi = U64(rec)
    if lo == RES_LO and hi == RES_HI then
      local id, flags = U32(rec + 8), U8(rec + 20)
      -- L4 entity record and L5 behavior block
      local block, why = block_of(id, rec)
      out('LSC_L4 laser sentry heat instance', i, 'record', h(rec), 'id', id, 'flags', flags, '(owned+local: flags%4 == 1)',
          'spare +0', U32(states + 12 * i), 'temperature +4', f(F32(states + 12 * i + 4)), 'overheated +8', U8(states + 12 * i + 8))
      if block then
        out('LSC_L5 behavior block', h(block), 'index', why, 'behavior +0', U32(block), '(309)', 'state +8', U32(block + 8),
            '(13 firing, 6 after overheat, 7 powering up, 2/3 idle/aware)', 'request +12', h(U32(block + 12)),
            '(0xFFFFFFFF none)', 'last +16', U32(block + 16))
        local r = region(block + 12)
        out('LSC_L6 block page', r and h(r.protection), r and h(r.state), r and h(r.type), '(0x4 readwrite, 0x1000, 0x20000)')
      else out('LSC_L5 behavior block not found:', why, '(normal for a sentry another player owns)') end
    end
  end
else out('LSC_L3 no heat instances (ship / menus) or implausible count') end
out('LSC_L5 behavior manager', h(BM), 'count +0x34', U32(BM and BM + 0x34), 'map capacity +0x48', U32(BM and BM + 0x48),
    'pow2', tostring(pow2(U32(BM and BM + 0x48))))
return 'done'
