-- Holster Your Shield port, read-only live checks L0-L6 (build 26088801). Reads only, through Link's Link to Memory
-- (read/ptr/get/region/out/fmt; nothing here writes or calls a game function). Every pointer is range-checked before
-- it is followed, every map probe is bounded. Run it in a mission (or on the ship) three times, wearing the SH-20
-- Ballistic Shield or SH-51 Directional Shield backpack: (a) pistol/one-handed weapon in hand, shield in the left hand;
-- (b) a two-handed primary in hand (shield on the back); (c) while holding the Backpack Function key. NOTES.md lists
-- what each line should show.
local G = assert(game, 'game.dll base')
local HIGH = 4294967296
local function ok(v) return v and v >= 0x10000 and v < 0x800000000000 end
local function P(a) if not ok(a) then return nil end local v = ptr(a) return ok(v) and v or nil end
local function U32(a) local s = ok(a) and read(a, 4) return s and get(s, 0, 'u32') or nil end
local function U8(a) local s = ok(a) and read(a, 1) return s and s:byte() or nil end
local function F32(a) local s = ok(a) and read(a, 4) return s and get(s, 0, 'f32') or nil end
local function h(v) return v and fmt('0x%X', v) or 'nil' end
local function f(v) return v and fmt('%.4f', v) or 'nil' end
local function hex16(a) local s = ok(a) and read(a, 16) if not s then return nil end
  local t = {} for i = 1, #s do t[i] = fmt('%02x', s:byte(i)) end return table.concat(t) end
local function mul32(a, b) local hi, lo = math.floor(a / 65536), a % 65536 return (hi * b % 65536 * 65536 + lo * b) % HIGH end
-- the game's open-addressed map: header {u64 data, u32 capacity, u32 empty, u32 multiplier}; at most 64 probes
local function lookup(header, key, limit)
  local data, cap, empty, mult = P(header), U32(header and header + 8), U32(header and header + 12), U32(header and header + 16)
  if not data or not cap or cap == 0 or cap > limit or not key then return nil, 'bad header' end
  local product = mul32(key, mult)
  for probe = 0, math.min(cap, 64) - 1 do
    local slot = data + 8 * ((product + probe) % cap)
    local k, v = U32(slot), U32(slot + 4)
    if k == nil then return nil, 'unreadable' end
    if k == key then return v ~= 0xFFFFFFFF and v or nil, 'empty value' end
    if k == empty then return nil, 'absent' end
  end
  return nil, 'not found in 64 probes'
end
local PROLOGUES = {set_item = {0x9BD850, '48895c241848894c2408555657415441'},
                   set_mode = {0x9BE500, '48895c24204489442418555657415441'},
                   send_held = {0xC008B0, '48895c241044894c2420574883ec6048'}}
out('HYS_LIVE game.dll base', h(G), 'exe', h(exe))
do -- L0: the mod's install flag (same Lua state), when visible from here
  local okk, flag = pcall(function() return rawget(_G, 'HolsterYourShieldInstalled') end)
  out('HYS_L0 HolsterYourShieldInstalled', okk and tostring(flag) or 'not visible from this eval',
      '(true after "Holster Your Shield v1.0-26088801 initialized" in HolsterYourShield.log)')
end
-- L1 globals and the none ids
local PM, ENT, AM, INV, EQC = P(G + 0x2CE1618), P(G + 0x2CE41B8), P(G + 0x2CE1EE0), P(G + 0x2CE18E8), P(G + 0x2CE1F88)
out('HYS_L1 players', h(PM), 'entities', h(ENT), 'avatars', h(AM), 'inventory', h(INV), 'equipment copies', h(EQC))
out('HYS_L1 none_item [game+0x2E3F0FC]', U32(G + 0x2E3F0FC), 'none_slot [game+0x2E3F10C]', U32(G + 0x2E3F10C),
    '(expect 0 and 0)')
-- L2 the local avatar: player manager -> network id -> entities network map -> 24-byte entity record
local net, record, entity
if PM and ENT then
  local total, here = U32(PM + 0x84), U32(PM + 0x88)
  net = U32(PM + 0x3A8)
  local player = P(PM + 0xE8)
  out('HYS_L2 players total/here', total, here, '(1..4)', 'avatar network id +0x3A8', net, '(0x7FFF = none)',
      'local record +0xE8', h(player), 'owned bit [+0x14]&1', player and (U32(player + 0x14) or 0) % 2)
  local index, why = lookup(ENT + 0xF24990, net ~= 0x7FFF and net or nil, 1048576)
  if index and index < 262144 then
    record = ENT + 0xF349E0 + 24 * index
    local lo, hi = U32(record), U32(record + 4)
    entity = U32(record + 8)
    out('HYS_L2 network map +0xF24990 index', index, 'record', h(record), 'hash', lo and fmt('0x%08X%08X', hi, lo),
        '(expect 0x4D1C334D294DFA97)', 'entity id +8', entity, 'flags +20 bit0', (U32(record + 20) or 0) % 2, '(expect 1)')
    local again = lookup(ENT + 0xF1C978, entity, 1048576)
    out('HYS_L2 entity-id map +0xF1C978 gives index', again, (again == index) and 'ok (same record)' or 'MISMATCH')
  else out('HYS_L2 network-id lookup failed:', why) end
end
-- L3 avatar manager slot, and L4 the Backpack Function key
local ai
if AM and entity then
  local count = U32(AM + 0x6C)
  ai = lookup(AM + 0xF8, entity, 64)
  local pointer = ai and P(AM + 0x110 + 8 * ai)
  out('HYS_L3 avatar manager count +0x6C', count, '(<= 8)', 'index', ai, 'entity pointer +0x110', h(pointer),
      'equals record', tostring(pointer == record), '(expect true)')
  if ai then
    local key = AM + 0x150 + 0x1B68 + 0xA7AEC * ai + 37 * 32 + 8
    out('HYS_L4 Backpack Function (action 37) held time at', h(key), f(F32(key)),
        '(0 released; > 0 and growing while the key is held; climb action 14 for comparison:',
        f(F32(AM + 0x150 + 0x1B68 + 0xA7AEC * ai + 14 * 32 + 8)) .. ')')
  end
end
-- L4 inventory row
local row, backpack, held, slot, mode
if INV and entity and record then
  local index = lookup(INV + 40, entity, 65536)
  local identities, rows = P(INV + 64), P(INV + 80)
  if index and identities and rows then
    row = rows + 48 * index
    backpack, held, slot, mode = U32(row + 12), U32(row + 20), U32(row + 28), U32(row + 32)
    out('HYS_L4 inventory index', index, 'identity +64[i]', h(P(identities + 8 * index)), '== record', tostring(
        P(identities + 8 * index) == record), 'row', h(row))
    out('HYS_L4 row weapons +0/+4/+8', U32(row), U32(row + 4), U32(row + 8), 'backpack +12', backpack, 'held +20', held,
        'slot in hand +28', slot, 'carry mode +32', mode,
        '(a: held == backpack, mode 2; b: held 0, mode 0 or 1; slot 1 primary, 2 sidearm, 3 support)')
  else out('HYS_L4 inventory lookup failed', index, h(identities), h(rows)) end
end
-- L5 equipment records: the backpack and the weapon in hand (per-entity copy, else the shared settings table)
local function equipment(id)
  if not id or id == 0 then return nil, 'none' end
  if EQC then
    local i = lookup(EQC + 80, id, 65536)
    local records = i and P(EQC + 144)
    if records then return records + 232 * i, 'per-entity copy ' .. i end
  end
  local r = ENT and lookup(ENT + 0xF1C978, id, 1048576)
  if not r then return nil, 'entity not found' end
  local base = ENT + 0xF349E0 + 24 * r
  local lo, hi = U32(base), U32(base + 4)
  if U32(base + 8) ~= id or not lo then return nil, 'record mismatch' end
  local table_address = P(ENT + 0xF14688)
  if not table_address then return nil, 'no shared table' end
  local s = (hi * (HIGH % 702) + lo) % 702
  for n = 1, 702 do
    local a, b = U32(table_address + 16 * s), U32(table_address + 16 * s + 4)
    if a == lo and b == hi then
      local k = U32(table_address + 16 * s + 8)
      return table_address + 16 * 702 + 232 * k, fmt('shared slot %d (home %d, %d probes) index %d', s,
        (hi * (HIGH % 702) + lo) % 702, n, k)
    end
    if a == 0 and b == 0 then return nil, 'empty slot reached after ' .. n .. ' probes' end
    s = (s + 1) % 702
  end
  return nil, 'not in 702 slots'
end
if row then
  local a, why = equipment(backpack)
  out('HYS_L5 backpack', backpack, why, 'type +0x80', a and U32(a + 0x80), '(25 = shield)', 'one-handed +0xC4',
      a and U8(a + 0xC4))
  local weapon = slot and slot >= 1 and slot <= 3 and U32(row + 4 * (slot - 1)) or nil
  local b, why2 = equipment(weapon)
  out('HYS_L5 weapon in hand', weapon, why2, 'type +0x80', b and U32(b + 0x80), 'one-handed +0xC4', b and U8(b + 0xC4),
      '(1 for a pistol / one-handed weapon, 0 for a two-handed primary)')
  local t = ENT and P(ENT + 0xF14688)
  if t then
    local used, bad = 0, 0
    for s = 0, 701 do
      local lo, hi, k = U32(t + 16 * s), U32(t + 16 * s + 4), U32(t + 16 * s + 8)
      if lo and (lo ~= 0 or hi ~= 0) then used = used + 1 if not k or k >= 702 then bad = bad + 1 end end
    end
    out('HYS_L5 shared table +0xF14688', h(t), 'used slots', used, 'of 702, index out of range', bad, '(expect 0)',
        '| old +0xF12BC0 holds', h(P(ENT + 0xF12BC0)))
  end
end
-- L6 the three game functions the mod calls: first 16 bytes (read only) and their pages
for name, v in pairs(PROLOGUES) do
  local bytes = hex16(G + v[1])
  local rg = region(G + v[1])
  out('HYS_L6', name, h(G + v[1]), bytes == v[2] and 'prologue ok' or ('prologue ' .. tostring(bytes) .. ' expected ' .. v[2]),
      rg and fmt('protect 0x%X state 0x%X type 0x%X', rg.protection or -1, rg.state or -1, rg.type or -1) or 'region nil',
      '(expect protect 0x20 PAGE_EXECUTE_READ; 0x1 PAGE_NOACCESS = not yet decrypted: the port refuses moves until the '
      .. 'game has run it, then checks and binds it)')
end
return true
