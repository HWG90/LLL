-- Consistent Vaulting port, read-only live checks L0-L10 (build 26088801). Reads only, through Link's Link to Memory
-- (read/ptr/get/hashmap/region; nothing here writes or calls a game function). Every pointer is range-checked before
-- it is followed. Run it in a mission with your Helldiver standing still, then again while you hold the climb/vault
-- input facing a waist-high obstacle (L6 needs a query batch: controller phase 2 or 3). See NOTES.md for what each
-- line should show. The old build's offsets are printed beside the new ones where they differ ("| old ... reads").
local G = assert(game, 'game.dll base')
local X = assert(exe, 'helldivers2.exe base')
local function ok(v) return v and v >= 0x10000 and v < 0x800000000000 end
local function P(a) if not ok(a) then return nil end local v = ptr(a) return ok(v) and v or nil end
local function U32(a) local s = ok(a) and read(a, 4) return s and get(s, 0, 'u32') or nil end
local function U16(a) local s = ok(a) and read(a, 2) return s and (s:byte(1) + 256 * s:byte(2)) or nil end
local function U8(a) local s = ok(a) and read(a, 1) return s and s:byte() or nil end
local function F32(a) local s = ok(a) and read(a, 4) return s and get(s, 0, 'f32') or nil end
local function U64(a) local s = ok(a) and read(a, 8) if not s then return nil end return get(s, 0, 'u32'), get(s, 4, 'u32') end
local function H64(lo, hi) return lo and fmt('0x%08X%08X', hi, lo) or 'nil' end
local function h(v) return v and fmt('0x%X', v) or 'nil' end
local function f(v) return v and fmt('%.4f', v) or 'nil' end
local function hex(a, n) local s = ok(a) and read(a, n) if not s then return 'unreadable' end
  return (s:gsub('.', function(c) return fmt('%02x', c:byte()) end)) end
local function dist(p, base) return p and (p - base) or nil end
local AV_LO, AV_HI = 0x294DFA97, 0x4D1C334D
local STRIDE, OLD_STRIDE = 0x1240, 0x1238
out('CV_LIVE game.dll', h(G), 'exe', h(X))
do -- L0 the mod's own state table (same Lua state), when visible
  local okk, st = pcall(function() return rawget(_G, 'ConsistentVaulting') end)
  if okk and type(st) == 'table' then
    out('CV_L0 revision', st.revision, 'status', st.status, 'active', tostring(st.active), 'polls', st.polls,
        'observed_queries', st.observed_queries, 'retry_calls', st.retry_calls, 'native_starts', st.native_starts,
        'slope_status', st.slope_status, 'candidate_reason', st.candidate_reason)
  else out('CV_L0 ConsistentVaulting state table not visible (read ConsistentVaulting.log with CowboyBingusDiagnostics=true)') end
end
-- L1 mission gate, camera, world
local MODE = P(G + 0x2CE1850)
out('CV_L1 mode record', h(MODE), '+8', U32(MODE and MODE + 8), '+0x40', U32(MODE and MODE + 0x40),
    '(mission: +8 non-zero and +0x40 in 1..7)')
local CAM = P(G + 0x2E287D0)
local cx, cy, cz = F32(CAM and CAM + 0x1C), F32(CAM and CAM + 0x20), F32(CAM and CAM + 0x24)
out('CV_L1 camera', h(CAM), 'forward +0x1c', f(cx), f(cy), f(cz), 'length',
    cx and f(math.sqrt(cx * cx + cy * cy + cz * cz)) or 'nil', '(unit vector; turns with the view)')
out('CV_L1 physics world', h(P(G + 0x2E271F8)), '(non-null in a mission)')
-- L2 player manager
local PM = P(G + 0x2CE1618)
local ref
if PM then
  local rec = P(PM + 0xE8)
  ref = U32(PM + 0x3A8)
  out('CV_L2 players', h(PM), 'counts +0x84', U32(PM + 0x84), U32(PM + 0x88), 'local record +0xe8', h(rec),
      'owned bit +0x14', rec and (U32(rec + 0x14) or 0) % 2, 'unit ref +0x3a8', ref, '(0x7fff = none)')
else out('CV_L2 player manager null') end
-- L3 local avatar entity
local OWN = P(G + 0x2CE41B8)
local entity, id, unit
if OWN and ref and ref ~= 0x7FFF then
  local ei = hashmap(OWN + 0xF24990, ref)
  entity = ei and OWN + 0xF349E0 + 24 * ei
  local lo, hi = U64(entity)
  id, unit = U32(entity and entity + 8), U32(entity and entity + 12)
  out('CV_L3 entity index', ei, 'record', h(entity), 'hash', H64(lo, hi), (lo == AV_LO and hi == AV_HI) and 'avatar_helldiver'
      or 'NOT THE AVATAR', 'id', id, 'unit', unit, 'flags bit0', entity and (U32(entity + 20) or 0) % 2)
else out('CV_L3 no local unit reference') end
-- L4 avatar manager, controller, direction state, flags, input
local AM = P(G + 0x2CE1EE0)
local ai, ctl
if AM and id then
  ai = hashmap(AM + 0xF8, id)
  local n = U32(AM + 0x6C)
  out('CV_L4 avatar manager', h(AM), 'index', ai, 'count +0x6c', n, 'registry +0x110[ai] == entity',
      tostring(ai and P(AM + 0x110 + 8 * ai) == entity))
end
if AM and ai then
  ctl = AM + 0x53E1B8 + ai * STRIDE
  out('CV_L4 controller', h(ctl), 'id +0x2ac', U32(ctl + 0x2AC), '(== id ' .. tostring(id) .. ')', 'phase +4', U32(ctl + 4),
      '(0/1 idle, 2 batch issued, 3 consumed)', '| old stride reads id', U32(AM + 0x53E1B8 + ai * OLD_STRIDE + 0x2AC))
  local dir = AM + 0x53E134 + ai * STRIDE
  out('CV_L4 direction state', h(dir), 'id +0x28', U32(dir + 0x28), 'speed cap +8', f(F32(dir + 8)),
      '(cap: negative/large = none; walking speed while a steep assist climbs)')
  local fl = AM + 0x53E888 + ai * STRIDE
  local w = {}
  for i = 0, 5 do w[#w + 1] = h(U32(fl + 4 * i)) end
  out('CV_L4 flags +0x53e888', table.concat(w, ' '), '(word0 bit 0x2 set when able to move; word3 bit 0x200 while '
      .. 'climbing)', '| old +0x53e880 (old stride) reads', h(U32(AM + 0x53E880 + ai * OLD_STRIDE)))
  local input = AM + 0x150 + ai * 0xA7AEC + 0x1B68 + 14 * 32
  out('CV_L4 climb input byte', h(input), U8(input), '(0 released; non-zero while the climb/vault key is held)',
      'held time float +8', f(F32(input + 8)))
  out('CV_L4 motion direction +0xa7c18', f(F32(AM + 0x150 + ai * 0xA7AEC + 171698 * 4)),
      f(F32(AM + 0x150 + ai * 0xA7AEC + 171698 * 4 + 4)), f(F32(AM + 0x150 + ai * 0xA7AEC + 171698 * 4 + 8)))
end
-- L5 effective settings (override record or shared component record)
if AM and id and OWN then
  local oi = hashmap(AM + 0x547CB0, id)
  local count = U32(AM + 0x547D60)
  local rec
  if oi and oi ~= 0xFFFFFFFF then rec = AM + 0x547D64 + oi * 852
  else
    local comp = P(OWN + 0xF14680)
    local lo, hi = U64(comp)
    out('CV_L5 component', h(comp), 'slot0 hash', H64(lo, hi), 'index', U32(comp and comp + 8), '(avatar hash, index 0)')
    rec = comp and comp + 32
  end
  out('CV_L5 settings', oi and oi ~= 0xFFFFFFFF and ('override ' .. oi) or 'shared', 'override count', count, '(<= 8)',
      'walk +12', f(F32(rec and rec + 12)), 'enter +0x98', f(F32(rec and rec + 0x98)), '(45)', 'exit +0xac',
      f(F32(rec and rec + 0xAC)), '(40)', 'ground height +0x104', f(F32(rec and rec + 0x104)), '(1.95)',
      'air height +0x108', f(F32(rec and rec + 0x108)), 'reach +0x10c', f(F32(rec and rec + 0x10C)))
end
-- L6 query scheduler and this controller's ten query records (new layout: unit +0x74, capacity +0x78, count +0x7a,
-- type +0x7c..0x7e)
if AM and ctl then
  local S = P(AM + 0x28)
  if S then
    local total = U32(S + 0x40000)
    local st = {}
    for j = 0, 7 do st[#st + 1] = (U32(S + 0x40004 + 12 * j) or '?') .. '-' .. (U32(S + 0x40008 + 12 * j) or '?') .. ':'
      .. (U32(S + 0x4000C + 12 * j) or '?') end
    out('CV_L6 scheduler', h(S), 'queries +0x40000', total, 'jobs start-finish:state', table.concat(st, ' '))
    for slot = 0, 9 do
      local q = U32(ctl + 8 + 4 * slot)
      if q and q > 0 and q <= 2048 then
        local r = S + (q - 1) * 128
        local outp = P(r)
        out('CV_L6 slot', slot, 'query', q, 'output == hit', tostring(outp == ctl + 0x30 + 44 * slot), 'filter +0x68',
            h(U32(r + 0x68)), '(0x5A5271A)', 'options +0x6c', U32(r + 0x6C), 'total +0x70', U32(r + 0x70),
            'unit +0x74', U32(r + 0x74), '(== ' .. tostring(unit) .. ')', 'capacity +0x78', U16(r + 0x78), '(1)',
            'count +0x7a', U16(r + 0x7A), '(0/1)', 'type', U8(r + 0x7C), U8(r + 0x7D), U8(r + 0x7E), '(2 1 5)',
            '| old +0x70 unit reads', U32(r + 0x70))
      end
    end
  else out('CV_L6 scheduler pointer null') end
end
-- L7 movement and mover records
local MM = P(G + 0x2CE1708)
local mover_name, handle
if MM and id then
  local mi = hashmap(MM + 0x48A0, id)
  local move, mover = mi and P(MM + 0x48C8), mi and P(MM + 0x48D0)
  move, mover = move and move + mi * 132, mover and mover + mi * 164
  mover_name, handle = U32(mover and mover + 76), U32(mover and mover + 88)
  out('CV_L7 movement', h(MM), 'index', mi, 'move', h(move), 'ground bytes +13/+16', U8(move and move + 13),
      U8(move and move + 16), 'normal +20', f(F32(move and move + 20)), f(F32(move and move + 24)), f(F32(move and move + 28)),
      'mover', h(mover), 'name +76', h(mover_name), 'handle +88', h(handle))
end
-- L8 exe handle pool -> character controller (the slope-cosine write target)
if handle then
  local pool = P(X + 0x286A768 + math.floor(handle / 2 ^ 30) * 0x810)
  local rows, layout, count, mask = P(pool), U32(pool and pool + 0x1C), U32(pool and pool + 0x24), U32(pool and pool + 0x28)
  local B = rawget(_G, 'bit')  -- the mod's own decode: band(handle, mask); without bit, the power-of-two form
  local index = mask and (B and tonumber(B.band(handle, mask)) % 2 ^ 32 or (handle % 2 ^ 30) % (mask + 1))
  local start = rows and layout and index and rows + index * (layout % 65536)
  local check = start and U32(start + math.floor(layout / 65536) % 256)
  local rec = start and start + math.floor(layout / 2 ^ 24)
  local def, obj = P(rec and rec + 16), P(rec and rec + 24)
  out('CV_L8 pool', h(pool), 'count', count, 'mask', h(mask), 'index', index, 'handle check', tostring(check == handle),
      'record unit', U32(rec and rec + 8), '(== ' .. tostring(unit) .. ')', 'def name', h(U32(def)), '(== mover name)')
  out('CV_L8 controller object', h(obj), 'vtable - exe', h(dist(P(obj), X)), '(0x17430A0)', 'up +80', f(F32(obj and obj + 80)),
      f(F32(obj and obj + 84)), f(F32(obj and obj + 88)), '(0 0 1)', 'slope cos +96', f(F32(obj and obj + 96)),
      '(0.6428 = cos 50; 0.4226 while a steep assist holds)', 'contact cos +100', f(F32(obj and obj + 100)), '(0.3420)',
      'def angles +20/+24', f(F32(def and def + 20)), f(F32(def and def + 24)), '(0.8727 1.2217 rad)')
  local rg = obj and region(obj)
  out('CV_L8 controller region', rg and fmt('protect 0x%X state 0x%X type 0x%X', rg.protection or -1, rg.state or -1,
      rg.type or -1) or 'nil', '(PAGE_READWRITE 0x4, MEM_COMMIT 0x1000, MEM_PRIVATE 0x20000)')
end
-- L9 game functions the mod binds: entry bytes (read only; a page the game has not run yet may be unreadable)
for _, fn in ipairs({{'classify', 0xAB9040, 12, '488bc4488958084889682056'},
                     {'drive', 0xAB5BA0, 16, '4055535657415441564157488d6c24d0'},
                     {'approach', 0xAB9870, 16, '488bc448895808555657415441554156'},
                     {'override', 0x8492A0, 16, '48895c240848896c2410488974241857'},
                     {'detect', 0xAB7EC0, 8, '488bc44889581048'}, {'basis', 0x15B3180, 8, '488bc44889580848'},
                     {'rotation', 0x15AE780, 8, '48895c2420574883'}}) do
  local got = hex(G + fn[2], fn[3])
  out('CV_L9', fn[1], h(fn[2]), got, got == fn[4] and 'ok' or ('expected ' .. fn[4]))
end
if ctl then
  local rg = region(ctl)
  out('CV_L9 controller region', rg and fmt('protect 0x%X state 0x%X type 0x%X', rg.protection or -1, rg.state or -1,
      rg.type or -1) or 'nil', '(the query writes need PAGE_READWRITE, MEM_COMMIT, MEM_PRIVATE)')
end
-- L10 exe native tables (identity guards) and their slots
for _, t in ipairs({{'actor', 0x2CE1500, 0x2874ED0, {{0x18, 0x81E620}, {0x38, 0x820700}, {0xA8, 0x820870}}},
                    {'mover', 0x2CE1548, 0x2875170, {{0x00, 0x855900}, {0x28, 0x856730}, {0x68, 0x8574F0}}},
                    {'world', 0x2CE14E8, 0x2875080, {{0x00, 0x826D10}, {0x68, 0x805160}, {0x80, 0x880750}}}}) do
  local T = P(G + t[2])
  local slots = {}
  for _, s in ipairs(t[4]) do
    local d = dist(P(T and T + s[1]), X)
    slots[#slots + 1] = fmt('+0x%X %s%s', s[1], h(d), d == s[2] and '' or (' (expected 0x%X)'):format(s[2]))
  end
  out('CV_L10 table', t[1], 'table - exe', h(dist(T, X)), dist(T, X) == t[3] and 'ok' or fmt('(expected 0x%X)', t[3]),
      table.concat(slots, ', '))
end
return true
