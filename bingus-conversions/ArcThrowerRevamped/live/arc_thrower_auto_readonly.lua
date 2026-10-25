-- Arc Thrower Revamped port, read-only live checks L1-L8 (build 26088801). Reads only, through Link's Link to Memory
-- (read/ptr/get/region/out/fmt; nothing here writes or calls a game function). Every pointer is range-checked before it
-- is followed and every loop is bounded. Run it on the ship once, then in a mission with the Arc Thrower equipped:
-- once idle, once while holding Fire (charging), ideally once right after a shot. NOTES.md says what each line should show.
local G = assert(game, 'game.dll base')
local function ok(v) return v and v >= 0x10000 and v < 0x800000000000 end
local function P(a) if not ok(a) then return nil end local v = ptr(a) return ok(v) and v or nil end
local function U32(a) local s = ok(a) and read(a, 4) return s and get(s, 0, 'u32') or nil end
local function U8(a) local s = ok(a) and read(a, 1) return s and s:byte() or nil end
local function F32(a) local s = ok(a) and read(a, 4) return s and get(s, 0, 'f32') or nil end
local function U64(a) local s = ok(a) and read(a, 8) if not s then return nil end return get(s, 0, 'u32'), get(s, 4, 'u32') end
local function H64(lo, hi) return lo and fmt('0x%08X%08X', hi, lo) or 'nil' end
local function h(v) return v and fmt('0x%X', v) or 'nil' end
local function f(v) return v and fmt('%.3f', v) or 'nil' end
local function hex(s) return s and (s:gsub('.', function(c) return fmt('%02x', c:byte()) end)) or 'nil' end
local function rg(a)
  local r = ok(a) and region(a)
  return r and fmt('protect 0x%X state 0x%X type 0x%X', r.protection or -1, r.state or -1, r.type or -1) or 'nil'
end
-- The engine hash map the mod probes: header {slots u64, capacity u32, empty u32, multiplier u32}, slots {key, index}.
local function mul32(a, b) local hi, lo = math.floor(a / 65536), a % 65536 return (hi * b % 65536 * 65536 + lo * b) % 4294967296 end
local function lookup(header, key, limit)
  local slots, cap, empty, mult = P(header), U32(header + 8), U32(header + 12), U32(header + 16)
  if not slots or not cap or cap == 0 or cap > limit then return nil, 'bad header cap ' .. tostring(cap) end
  local p = mul32(key, mult)
  for probe = 0, math.min(cap, 64) - 1 do
    local at = slots + 8 * ((p + probe) % cap)
    local k, i = U32(at), U32(at + 4)
    if k == key then return (i ~= 0xFFFFFFFF) and i or nil, 'found' end
    if k == empty then return nil, 'empty' end
  end
  return nil, 'not found'
end
local ARC_LO, ARC_HI = 0x0F7306E6, 0x96DE9CD5        -- Arc Thrower weapon entity type (ARC_RESOURCE)
local AV_LO, AV_HI = 0x294DFA97, 0x4D1C334D          -- avatar_helldiver (AVATAR_TYPE)
local FINGERPRINT = '0fd7d61a96fba229a931ee670e049541'
out('ATR_LIVE game.dll base', h(G))

-- L1 the fire-mode setter signature (the addon reads it with ReadProcessMemory; nil = page not resident yet)
local sig = read(G + 0x761700, 15)
out('ATR_L1 setter +0x761700', hex(sig), sig and ((hex(sig) == '48894c24085355565741574883ec20') and 'MATCH' or 'DIFFERS') or
    'UNREADABLE (no-access page; the port retries every update)', '| region', rg(G + 0x761700))

-- L2 mission record
local MR = P(G + 0x2CE1850)
local mword, mtype = U32(MR and MR + 8), U32(MR and MR + 0x40)
out('ATR_L2 mission record', h(MR), 'word +8', mword, 'type +0x40', mtype, 'mission',
    tostring(mword ~= nil and mword ~= 0 and mtype ~= nil and mtype >= 1 and mtype <= 7), '(ship: false; mission: true, type 1..7)')

-- L3 local player -> unit -> entity record -> avatar -> Fire slot
local PM, N, AM = P(G + 0x2CE1618), P(G + 0x2CE41B8), P(G + 0x2CE1EE0)
local avatar_id, fire_slot
if PM and N and AM then
  local players, locals, unit = U32(PM + 0x84), U32(PM + 0x88), U32(PM + 0x3A8)
  local player = P(PM + 0xE8)
  local pflags = U32(player and player + 20)
  out('ATR_L3 players', players, 'local', locals, 'unit +0x3A8', h(unit), 'player rec', h(player), 'owned', pflags and pflags % 2,
      '(1..4, 1..4, unit ~= 0x7FFF in a mission, owned 1)')
  local ei, why = nil, 'no unit'
  if unit and unit ~= 0x7FFF then ei, why = lookup(N + 0xF24990, unit, 1048576) end
  local rec = ei and N + 0xF349E0 + ei * 24
  local lo, hi = U64(rec)
  local id, eflags = U32(rec and rec + 8), U32(rec and rec + 20)
  avatar_id = id
  out('ATR_L3 entity index', ei, why, 'record', h(rec), 'hash', H64(lo, hi), (lo == AV_LO and hi == AV_HI) and 'avatar_helldiver' or 'OTHER',
      'id', id, 'owned', eflags and eflags % 2, '| old +0xF22EC8 map would give', (unit and unit ~= 0x7FFF) and tostring((lookup(N + 0xF22EC8, unit, 1048576))) or '-')
  if id then
    local ai, why2 = lookup(AM + 0xF8, id, 64)
    local count = U32(AM + 0x6C)
    local ent = ai and P(AM + 0x110 + ai * 8)
    local elo, ehi = U64(ent)
    fire_slot = ai and AM + 0x150 + ai * 0xA7AEC + 0x1B68 + 9 * 32
    out('ATR_L3 avatar index', ai, why2, 'count +0x6C', count, 'entity', h(ent), 'hash', H64(elo, ehi), 'id', U32(ent and ent + 8),
        (U32(ent and ent + 8) == id) and 'SAME' or 'MISMATCH', '(index < count <= 8)')
    if fire_slot then
      local aim, fire = F32(fire_slot - 32 + 8), F32(fire_slot + 8)
      out('ATR_L3 Fire slot', h(fire_slot), 'bytes', hex(read(fire_slot, 32)), 'held +8', f(fire), '| Aim slot +8', f(aim),
          '(hold Fire: held > 0 and rising; release: 0; Aim must not move it)')
    end
  end
else out('ATR_L3 managers', h(PM), h(N), h(AM), '(null before a world exists)') end

-- L4 charge manager entries of Arc Thrower weapons
local C = P(G + 0x2CE1DE8)
local arc_entities = {}
if C then
  local count, ents, entries = U32(C + 0x10), P(C + 0x38), P(C + 0x40)
  out('ATR_L4 charge manager', h(C), 'count +0x10', count, 'entities +0x38', h(ents), 'entries +0x40', h(entries),
      'entries page', rg(entries), '(count <= 512; page protect 0x4 type 0x20000)')
  if count and ents and entries and count <= 512 then
    for i = 0, count - 1 do
      local e = P(ents + 8 * i)
      local lo, hi = U64(e)
      if lo == ARC_LO and hi == ARC_HI then
        local base = entries + 40 * i
        arc_entities[#arc_entities + 1] = e
        out('ATR_L4 arc entry', i, 'entity', h(e), 'id', U32(e + 8), 'owned', (U32(e + 20) or 0) % 2, 'charge +4', f(F32(base + 4)),
            'shot +8', f(F32(base + 8)), 'flag +12', U8(base + 12), '(idle: charge 0 flag 0; holding: flag 1, charge rises to the full time)')
      end
    end
    if #arc_entities == 0 then out('ATR_L4 no Arc Thrower in the charge table (equip it in a mission)') end
  end
else out('ATR_L4 charge manager null') end

-- L5 trigger manager: fire commands
local T = P(G + 0x2CE1810)
if T then
  local count, ents, flags = U32(T + 0x18), P(T + 0x40), P(T + 0x58)
  local set, arc = 0, 0
  if count and ents and flags and count <= 4096 then
    local fl = read(flags, count)
    for i = 0, (fl and count or 0) - 1 do
      if fl:byte(i + 1) ~= 0 then
        set = set + 1
        local lo, hi = U64(P(ents + 8 * i))
        if lo == ARC_LO and hi == ARC_HI then arc = arc + 1; out('ATR_L5 arc fire command at index', i) end
      end
    end
  end
  out('ATR_L5 trigger manager', h(T), 'count +0x18', count, 'entities +0x40', h(ents), 'flags +0x58', h(flags), 'set', set, 'arc', arc,
      '(count <= 4096; while you press Fire with the Arc Thrower one arc flag is set briefly)')
else out('ATR_L5 trigger manager null') end

-- L6 weapon holder rows
local W = P(G + 0x2CE1F88)
if W then
  for _, e in ipairs(arc_entities) do
    local wid = U32(e + 8)
    local idx, why = lookup(W + 0x20, wid, 8192)
    local rows = P(W + 0x40)
    local holder = idx and rows and U32(rows + idx * 48 + 4)
    out('ATR_L6 arc weapon', wid, 'holder row', idx, why, 'holder +4', holder, 'local avatar id', avatar_id,
        (holder and holder == avatar_id) and 'HELD BY YOU' or 'other/none')
  end
  out('ATR_L6 weapon holder manager', h(W), 'rows +0x40', h(P(W + 0x40)), 'map cap +0x28', U32(W + 0x28))
else out('ATR_L6 weapon holder manager null') end

-- L7 the Arc Thrower charge settings record (the auto-fire write target): library table [entities+0xF145A0]
local function show_record(label, R)
  local fp = read(R + 168, 16)
  out(label, h(R), 'floats +0/+24/+48/+72/+76', f(F32(R)), f(F32(R + 24)), f(F32(R + 48)), f(F32(R + 72)), f(F32(R + 76)),
      '(addon expects 1.0 1.1 1.2 0.7 1.4)', 'fingerprint +168', hex(fp), (hex(fp) == FINGERPRINT) and 'MATCH' or 'DIFFERS',
      'auto-fire +184', U8(R + 184), '(vanilla 0; 1 while the addon runs)', '| page', rg(R),
      '(library: expect protect 0x2 PAGE_READONLY, state 0x1000, type 0x20000 MEM_PRIVATE)')
end
local L = N and P(N + 0xF145A0)
out('ATR_L7 library table +0xF145A0', h(L), '| old +0xF12AD8 holds', H64(U64(N and N + 0xF12AD8)))
if L then
  local slot = ((ARC_HI % 20) * 16 + ARC_LO % 20) % 20   -- (hi*2^32 + lo) mod 20; 2^32 mod 20 = 16
  local index
  for _ = 1, 20 do
    local lo, hi = U64(L + slot * 16)
    if lo == ARC_LO and hi == ARC_HI then index = U32(L + slot * 16 + 8) break end
    if lo == 0 and hi == 0 then break end
    slot = (slot + 1) % 20
  end
  if index then show_record('ATR_L7 library record slot ' .. slot .. ' index ' .. index, L + 0x140 + 0xD8 * index)
  else out('ATR_L7 Arc Thrower hash not in the library table') end
end
if C then -- per-entity copies the getter prefers: charge manager map +0x50 by entity id -> [+0x90] + 0xD8*i
  for _, e in ipairs(arc_entities) do
    local i = lookup(C + 0x50, U32(e + 8) or 0, 1048576)
    local base = P(C + 0x90)
    if i and base then show_record('ATR_L7 per-entity copy ' .. i, base + 0xD8 * i) else out('ATR_L7 no per-entity copy for', h(e)) end
  end
end

-- L8 summary of the two write targets' pages
out('ATR_L8 write pages: charge entries', rg(C and P(C + 0x40)), '| Fire slot (read only)', rg(fire_slot))
return true
