-- Armory Preview Cache port, read-only live checks A0-A16 (build 26088801). Reads only, through Link's Link to Memory
-- (read/ptr/get/region/out/fmt; nothing here writes or calls a game function). Every pointer is range-checked before
-- it is followed. Run it (1) on the ship outside menus, (2) in the Armory with the grid shown and thumbnails done,
-- (3) in the Armory weapon pre-select (customize a weapon), (4) on the mission briefing loadout screen and (5) on the
-- briefing equipment picker. See NOTES.md for what each line should show.
local G, E = assert(game, 'game.dll base'), assert(exe, 'exe base')
local function ok(v) return v and v >= 0x10000 and v < 0x800000000000 end
local function P(a) if not ok(a) then return nil end local v = ptr(a) return ok(v) and v or nil end
local function U32(a) local s = ok(a) and read(a, 4) return s and get(s, 0, 'u32') or nil end
local function U8(a) local s = ok(a) and read(a, 1) return s and s:byte() or nil end
local function F32(a) local s = ok(a) and read(a, 4) return s and get(s, 0, 'f32') or nil end
local function U64(a) local s = ok(a) and read(a, 8) if not s then return nil end return get(s, 0, 'u32'), get(s, 4, 'u32') end
local function H64(lo, hi) return lo and fmt('%08x%08x', hi, lo) or 'nil' end
local function h(v) return v and fmt('0x%X', v) or 'nil' end
local function hex(s) return s and (s:gsub('.', function(c) return fmt('%02x', c:byte()) end)) or 'unreadable' end
out('APC_LIVE game.dll base', h(G), 'exe', h(E))
do -- A0 the mod's status table (same Lua state), when visible from here
  local okk, st = pcall(function() return rawget(_G, 'ArmoryPreviewCache') end)
  if okk and type(st) == 'table' then
    out('APC_A0 revision', st.revision, 'status', st.status, 'last_top', st.last_top, 'last_items', st.last_items,
        'last_error', st.last_error, 'disabled_reason', st.disabled_reason)
  else out('APC_A0 status table not visible from this eval (read ArmoryPreviewCache.log instead)') end
end
-- A1 code: the first 16 bytes of every native the port checks (expected = MAP.json new_sig prefixes). "unreadable"
-- means the page is not resident yet (the port then checks it right before its first call).
local CODE = {
  {'game', 0x11912F0, '4585c00f8475010000415641574883ec', 'package acquire'},
  {'game', 0x1191480, '4585c00f8460010000415641574883ec', 'package release'},
  {'game', 0x12E16F0, '48895c24084889742410574883ec2049', 'set_texture'},
  {'game', 0x12D6C00, '4c8944241848895424104883ec28f30f', 'set_uv'},
  {'game', 0x12DEE70, '48895c241848896c24204889542410565741574883ec20f30f', 'set_size'},
  {'game', 0x12E07E0, '40574883ec20f30f104144488bf90f2e', 'set_alpha'},
  {'game', 0x12E7510, '48895c2408574883ec20410fb6f8488b', 'material'},
  {'game', 0x1229090, '40534883ec204533c9488bda488b15', 'register_image'},
  {'exe', 0x2EA5A0, '48896c2410488974241857415641574883ec40', 'create render target'},
  {'exe', 0x2EA9B0, '48895c2408574883ec20488b1d', 'destroy render target'},
  {'exe', 0x2ED5C0, '4c8bc28bd1488b0d', 'register render target'},
}
for _, c in ipairs(CODE) do
  local base = c[1] == 'game' and G or E
  local got = read(base + c[2], #c[3] / 2)
  out('APC_A1', c[4], c[1] .. '+' .. h(c[2]), got and (hex(got) == c[3] and 'ok' or 'DIFFERS ' .. hex(got)) or 'unreadable (not resident)')
end
-- A2 exe: ScriptApi, application table slots, texture format size
local API = P(G + 0x2CE14C8)
local APP = API and P(API + 16)
out('APC_A2 ScriptApi', h(API), '== exe+0x2870240', tostring(API == E + 0x2870240), 'app', h(APP))
if APP then
  for _, s in ipairs({{368, 0x2EA5A0}, {400, 0x2EA9B0}, {528, 0x2ED5C0}, {752, 0x2F0260}, {768, 0x2F04C0}}) do
    local v = P(APP + s[1])
    out('APC_A2 app+' .. s[1], h(v), 'expect exe+' .. h(s[2]), tostring(v == E + s[2]))
  end
end
out('APC_A2 texture format size [exe+0x16F5510]', U32(E + 0x16F5510), '(expect 32)')
-- A3 the UI globals block (manager, UI, state, preview, lease)
local TM, UI, SM, PV, LT = P(G + 0x2E380B0), P(G + 0x2E380C8), P(G + 0x2E38160), P(G + 0x2E38190), P(G + 0x2E381E8)
out('APC_A3 manager', h(TM), 'ui', h(UI), 'state', h(SM), 'preview', h(PV), 'lease table', h(LT))
-- A4 state stack, UI world, blocked flag
local depth, top
if SM then
  depth = U32(SM + 0x42B0)
  top = depth and depth >= 1 and depth <= 5 and U32(SM + 0x429C + 4 * (depth - 1)) or nil
  out('APC_A4 depth', depth, 'top', top, '(5 Armory, 14 briefing; 0 depth at the title/startup)')
end
if UI then out('APC_A4 world [ui+15432]', h(P(UI + 15432)), 'blocked [ui+15892]', U32(UI + 15892)) end
-- A5 thumbnail manager (26088801 layout)
local ATLAS
if TM then
  out('APC_A5 type [tm+11344]', U32(TM + 11344), '(expect 7) | old offset [tm+11052] reads', U32(TM + 11052))
  local active, phase = U32(TM + 11356), U32(TM + 11388)
  out('APC_A5 active [tm+11356]', active and fmt('0x%X', active), '(0xFFFFFFFF idle or 0..5)', 'phase [tm+11388]', phase,
      'layout [tm+11392]', U32(TM + 11392), U32(TM + 11396), 'tile', fmt('%s x %s', tostring(F32(TM + 24)), tostring(F32(TM + 28))))
  ATLAS = P(TM + 11400)
  local n = U32(TM + 11424)
  out('APC_A5 atlas [tm+11400]', h(ATLAS), 'registry count [tm+11424]', n, '(<= 128)', 'first', h(P(TM + 11432)),
      'byte after the registry [tm+12456]', U8(TM + 12456))
  local cards = {}
  for c = 0, 5 do cards[#cards + 1] = fmt('%d:%s/%s', c, tostring(U32(TM + 1832 + 1816 * c)), tostring(U32(TM + 1836 + 1816 * c))) end
  out('APC_A5 cards state/count', table.concat(cards, ' '), '(state <= 8, count <= 15)')
  for c = 0, 5 do
    local n_ = U32(TM + 1836 + 1816 * c)
    if n_ and n_ > 0 and n_ <= 15 then
      local at = TM + 1816 * c + 32
      local lo, hi = U64(at + 24)
      out('APC_A5 card', c, 'item 0 id', H64(lo, hi), 'kind +100', U32(at + 100), 'status +104', U32(at + 104), '(kind 0..4 equipment)')
      break
    end
  end
end
-- A6 atlas descriptor
if ATLAS then
  local d = read(ATLAS, 104)
  if d then
    out('APC_A6 descriptor +8', get(d, 8, 'u32'), '+12', get(d, 12, 'u32'), 'w +20', get(d, 20, 'u32'), 'h +24', get(d, 24, 'u32'),
        '+28', get(d, 28, 'u32'), '+32', get(d, 32, 'u32'), 'byte +99', d:byte(100), '(expect 0 0 w h 1 1 1; w,h 64..4096/16384)')
  end
end
-- A7 dispatch rows: the controller kinds
local D = P(G + 0x2CE2040)
local ARMORY, BRIEF
if D then
  local n = U32(D + 5740)
  local kinds = {}
  for i = 0, math.min(n or 0, 64) - 1 do
    local k = U32(D + 5744 + 16 * i + 8)
    kinds[#kinds + 1] = tostring(k)
    if k == 226 then ARMORY = P(D + 5744 + 16 * i) end
    if k == 231 then BRIEF = P(D + 5744 + 16 * i) end
  end
  out('APC_A7 dispatch', h(D), 'rows', n, 'kinds', table.concat(kinds, ','), '| Armory 226', h(ARMORY), 'briefing 231', h(BRIEF),
      '(226 present only with the Armory open, 231 with the briefing; 224/229 are other controllers now)')
end
-- A8 Armory controller (owner+280216 control, +523752 grid)
if ARMORY then
  local grid = ARMORY + 523752
  local rows = U32(grid + 597772)
  out('APC_A8 Armory grid rows', rows, '(<= 12)', 'grid kind +602052', U32(grid + 602052))
  if rows and rows > 0 and rows <= 12 then
    local rb = grid + 2816
    local cols = U32(rb + 44724)
    local w = rb + 9192
    local rec = P(w + 1984)
    local off = rec and rec - (grid + 602104)
    out('APC_A8 row 0 columns', cols, '(<= 4)', 'widget 0 record', h(rec), 'record offset', off,
        '(multiple of 80 in 0..20400)', 'record type +8', rec and U32(rec + 8), 'card +60', rec and U32(rec + 60),
        'slot +64', rec and U32(rec + 64), 'element flags', h(U32(w + 272)), 'bound +2005', U8(w + 2005))
  end
  local control = ARMORY + 280216
  out('APC_A8 pre-select mode block +37968', U32(control + 37968), U8(control + 37972), U32(control + 37980),
      '(card <6, closed byte 0 = shown, mode 0 weapon / 1 cosmetic)', 'widget 0 record', h(P(control + 5256 + 1984)),
      '== control+37728', tostring(P(control + 5256 + 1984) == control + 37728))
end
-- A9 briefing controller: the +0x40 shift (records 454792, widgets 422832, grid 864096)
if BRIEF then
  local good, old = 0, 0
  for i = 0, 5 do
    local tail = P(BRIEF + 422832 + i * 5464 + 1984)
    if tail == BRIEF + 454792 + i * 80 then good = good + 1 end
    if P(BRIEF + 422768 + i * 5464 + 1984) == BRIEF + 454728 + i * 80 then old = old + 1 end
  end
  out('APC_A9 briefing loadout widgets pointing at their records (new offsets)', good, '/6', '| old offsets', old,
      '/6 (on the loadout screen expect 6 and 0)')
  for i = 0, 5 do
    local r = BRIEF + 454792 + i * 80
    out('APC_A9 record', i, 'type +8', U32(r + 8), 'card +60', U32(r + 60), 'slot +64', U32(r + 64), 'style +72', U32(r + 72))
  end
  out('APC_A9 briefing grid rows [+864096+597772]', U32(BRIEF + 864096 + 597772), '| old [+864032+597772]',
      U32(BRIEF + 864032 + 597772))
end
-- A10 lease table
if LT then
  local cap, mul = U32(LT + 8), U32(LT + 24)
  local elo, ehi = U64(LT + 16)
  local storage, alloc = P(LT), P(LT + 16416)
  local used = 0
  local rows = read(LT + 32, 16384)
  if rows then for i = 0, 1023 do if get(rows, i * 16, 'u32') ~= 0 or get(rows, i * 16 + 4, 'u32') ~= 0 then used = used + 1 end end end
  out('APC_A10 lease capacity +8', cap, '(1024)', '+24', mul, '(2)', '+16', H64(elo, ehi), '(0)', 'storage == +32',
      tostring(storage == LT + 32), 'allocator +16416', h(alloc), 'rows used', used)
end
-- A11 weapon package table (entities + 0xF14008): 1100 buckets, records at +17600
local N = P(G + 0x2CE41B8)
local WT = N and P(N + 0xF14008)
if WT then
  local b = read(WT, 1100 * 16)
  local ids, maxi = 0, -1
  if b then for i = 0, 1099 do
    if get(b, i * 16, 'u32') ~= 0 or get(b, i * 16 + 4, 'u32') ~= 0 then ids = ids + 1; maxi = math.max(maxi, get(b, i * 16 + 8, 'u32')) end
  end end
  local r = read(WT + 17600, 550 * 32)
  local pk = 0
  if r then for i = 0, 549 do if get(r, i * 32 + 8, 'u32') ~= 0 then pk = pk + 1 end end end
  out('APC_A11 weapon table', h(WT), 'ids', ids, 'max record index', maxi, '(< 550)', 'records with a package', pk)
end
-- A12 weapon configurations (entities + 0xF148D8): 658 buckets, 329 configurations of 46600 bytes from +10528
local DEF = N and P(N + 0xF148D8)
if DEF then
  local b = read(DEF, 658 * 16)
  local ids, maxi, first = 0, -1, nil
  if b then for i = 0, 657 do
    if get(b, i * 16, 'u32') ~= 0 or get(b, i * 16 + 4, 'u32') ~= 0 then
      ids = ids + 1; local x = get(b, i * 16 + 8, 'u32'); maxi = math.max(maxi, x); first = first or x
    end
  end end
  out('APC_A12 configurations', h(DEF), 'ids', ids, 'max index', maxi, '(< 329)')
  if first then
    local c = read(DEF + 10528 + first * 46600, 120)
    if c then
      local pairs_, allowed = {}, {}
      for j = 0, 9 do pairs_[#pairs_ + 1] = get(c, j * 8, 'u32') .. ':' .. get(c, j * 8 + 4, 'u32') end
      for j = 0, 9 do allowed[#allowed + 1] = tostring(get(c, 80 + j * 4, 'u32')) end
      out('APC_A12 configuration', first, 'pairs (kind:number)', table.concat(pairs_, ' '), '| allowed kinds +80',
          table.concat(allowed, ','), '(kinds 1..9 then 0 to end; numbers match attachment rows in A14)')
    end
  end
end
-- A13 kits and presets
local KO, PO = P(G + 0x2CE16A8), P(G + 0x2E38230)
if KO then
  local kc = U32(KO + 8)
  local kp = P(KO)
  local r0 = kp and P(kp)
  local lo, hi = U64(r0 and r0 + 32)
  out('APC_A13 kits', kc, '(1..1024)', 'row 0 key', r0 and U32(r0), 'id +32', H64(lo, hi))
end
if PO then out('APC_A13 presets', U32(PO + 7392), '(1..4096)', 'row 0 key +4', U32(PO + 761060 + 4), 'kit +8', U32(PO + 761060 + 8)) end
-- A14 attachments and the package map
local groups = U32(G + 0x2E493C8)
local gp = P(G + 0x31812E0)
if groups and gp then
  local n = U32(gp + 8)
  local rows = P(gp)
  local lo, hi = U64(rows and rows + 32)
  out('APC_A14 attachment groups', groups, '(1..64)', 'group 0 rows', n, 'row 0 number +8', rows and U32(rows + 8), 'id +32',
      H64(lo, hi), 'kinds +56', rows and U32(rows + 56))
end
local MAPS = G + 0x3154F90
local cnt, mult = U32(MAPS + 8), U32(MAPS + 24)
out('APC_A14 package map count', cnt, '(power of two)', 'multiplier', mult, 'empty key', H64(U64(MAPS + 16)), 'storage', h(P(MAPS)))
out('APC_A14 fallback attachment numbers [game+0x1FC7988 + 32k]', U32(G + 0x1FC7988), U32(G + 0x1FC7988 + 32),
    U32(G + 0x1FC7988 + 64), '(0, 0xACC1561C, 0x7766DA38)')
-- A15 preview queue
if PV then out('APC_A15 preview queue head/tail [+50448]', U32(PV + 50448), U32(PV + 50452), '(< 128)') end
-- A16 page check of the objects the port writes into (manager atlas slot, a widget)
if TM then
  local rg = region(TM + 11400)
  out('APC_A16 manager region', rg and fmt('protect 0x%X state 0x%X type 0x%X', rg.protection or -1, rg.state or -1, rg.type or -1) or 'nil',
      '(expect 0x4 PAGE_READWRITE, 0x1000 MEM_COMMIT, 0x20000 MEM_PRIVATE)')
end
return true
