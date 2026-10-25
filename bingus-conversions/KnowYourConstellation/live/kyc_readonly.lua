-- Know Your Constellation port, read-only live checks K1-K13 (Steam build 26088801). Reads only, through Link's Link
-- to Memory (read/ptr/get/region; nothing here writes or calls a game function). Every pointer is range-checked before
-- it is followed. Run it three times: on the ship with the war table (Galactic Map) open and a mission highlighted,
-- on the mission briefing (loadout) screen, and once in a mission. See NOTES.md for what each line should show.
local G = assert(game, 'game.dll base')
local function ok(v) return v and v >= 0x10000 and v < 0x800000000000 end
local function P(a) if not ok(a) then return nil end local v = ptr(a) return ok(v) and v or nil end
local function U32(a) local s = ok(a) and read(a, 4) return s and get(s, 0, 'u32') or nil end
local function U16(a) local s = ok(a) and read(a, 2) return s and (s:byte(1) + s:byte(2) * 256) or nil end
local function U8(a) local s = ok(a) and read(a, 1) return s and s:byte() or nil end
local function F32(a) local s = ok(a) and read(a, 4) return s and get(s, 0, 'f32') or nil end
local function H64(a) local s = ok(a) and read(a, 8) if not s then return 'nil' end
  return fmt('%08x%08x', get(s, 4, 'u32'), get(s, 0, 'u32')) end
local function h(v) return v and fmt('0x%X', v) or 'nil' end
local function f(v) return v and fmt('%.3f', v) or 'nil' end
local function pow2(v) if not v or v < 1 then return false end while v > 1 and v % 2 == 0 do v = v / 2 end return v == 1 end
out('KYC_LIVE game.dll base', h(G))
do -- K0: the mod's own status (same Lua state), when visible from here
  local okk, st = pcall(function() return rawget(_G, 'EnemyIntelligence') end)
  if okk and type(st) == 'table' then out('KYC_K0 revision', st.revision, 'status', st.status, 'screen', tostring(st.screen),
      'key', tostring(st.key), 'complete', tostring(st.complete))
  else out('KYC_K0 EnemyIntelligence not visible from this eval (read EnemyIntelligence.log instead)') end
end
-- K1 UI stack (UI + 0x429C: 5 presenter ids, depth at +20); 15 Hologram = war table, 14 Loadout = briefing
local UI = P(G + 0x2E38160)
if UI then
  local depth = U32(UI + 0x429C + 20)
  local top = depth and depth >= 1 and depth <= 5 and U32(UI + 0x429C + 4 * (depth - 1))
  out('KYC_K1 ui', h(UI), 'depth', depth, 'top', top, '(15 on the war table, 14 on the briefing/loadout)')
else out('KYC_K1 ui state null') end
-- K2 board and root: highlighted operation and the mission descriptor
local B, R = P(G + 0x2E38220), P(G + 0x2CE1508)
local C = R and P(R + 0xAE308)
out('KYC_K2 board', h(B), 'root', h(R), 'controller +0xAE308', h(C), '| old +0xAE288 holds', h(R and P(R + 0xAE288)))
if B then
  local sel = U32(B + 1548960)
  local d = B + 0x4168D0
  out('KYC_K2 selected op', h(sel), '(< 110, 0xFFFFFFFF for a joinable hover)', 'descriptor seed', U32(d), 'faction',
      U8(d + 8), '(2..4)', 'difficulty', U8(d + 9), '(1..10)', 'planet hash', h(U32(d + 12)), 'mission type', U16(d + 26),
      '(< 256)')
  if sel and sel < 110 then
    local op = B + 1012352 + 92 * sel
    out('KYC_K2 op record planet', U16(op + 16), 'byte +24', U8(op + 24), 'category', U32(op + 28), '(< 14)', 'active',
        U8(op + 52), '(1)')
  end
  if C then
    local same = true
    for _, i in ipairs({0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 12, 13, 14, 15, 26, 27}) do
      if U8(d + i) ~= U8(C + 8 + i) then same = false end
    end
    out('KYC_K2 controller +8 descriptor matches the selection', tostring(same), '(true once the hovered mission loaded)')
  end
end
-- K3 controller +664 level: explicit tags (count <= 3), stamp table count, selection record
local L = C and P(C + 664)
out('KYC_K3 level +664', h(L), '| old +648 holds', h(C and P(C + 648)))
if L then
  local n = U32(L + 9160276 + 12)
  out('KYC_K3 explicit tag count', n, '(0..3)', 'natives', U32(L + 9160276), U32(L + 9160280), U32(L + 9160284),
      '(<= 32)', 'stamp count +18510124', U32(L + 18510124), 'selection type +9017008+8', h(U32(L + 9017008 + 8)),
      '(0xADC32FAA when a stamp is placed)')
end
-- K4 briefing descriptor list: UI event manager +26424 count, rows +26432 {owner, kind 237}; owner +1072 descriptor
local M = P(G + 0x2CE2040)
if M then
  local n = U32(M + 26424)
  out('KYC_K4 manager', h(M), 'briefing list count +26424', n, '| old +26184 reads', U32(M + 26184))
  for i = 0, math.min(n or 0, 8) - 1 do
    local row = M + 26432 + 16 * i
    local owner, kind = P(row), U32(row + 8)
    out('KYC_K4 row', i, 'kind', kind, '(237 = the briefing owner)', 'owner', h(owner),
        kind == 237 and owner and fmt('descriptor +1072: faction %s difficulty %s mission %s', tostring(U8(owner + 1072 + 8)),
        tostring(U8(owner + 1072 + 9)), tostring(U16(owner + 1072 + 26))) or '')
  end
end
-- K5 campaign gate flags (all 0 in normal play)
local S = P(G + 0x2E38228)
out('KYC_K5 session', h(S), 'flag +92142', U8(S and S + 92142), 'root +4333', U8(R and R + 4333), 'root +4345',
    U8(R and R + 4345), '(0 0 0 normally) | old +92134/+4205/+4217 read', U8(S and S + 92134), U8(R and R + 4205),
    U8(R and R + 4217))
-- K6 joinable hover inputs
local S2 = P(G + 0x2CE1C68)
local MM = P(G + 0x2E381B8)
out('KYC_K6 session2', h(S2), 'fallback +5630328 id', h(U32(S2 and S2 + 5630328)), 'group +8', h(U32(S2 and S2 + 5630336)),
    '| matchmaking', h(MM), 'counts', U32(MM and MM + 1253440), U32(MM and MM + 1409448), U32(MM and MM + 1487456),
    '(<= 100, 100, 50)')
if B then
  out('KYC_K6 board joinable count +2053224', U32(B + 2053224), '(<= 440)', 'flag +2064401', U8(B + 2064401),
      'preview planet +1548956', h(U32(B + 1548956)), 'preview slot +4286668', U32(B + 4286668))
end
-- K7 campaign data (data = board + 1053752), definitions, categories, war effects
if B then
  local data = B + 1053752
  local planets, cur = U32(B + 1197132), U32(data + 495200)
  out('KYC_K7 planets', planets, '(<= 512)', 'current planet', cur, '(= board +1548952:', U32(B + 1548952), ')')
  if cur and planets and cur < planets then
    out('KYC_K7 static hash +24', h(U32(data + 280 * cur + 24)), 'dynamic faction +36', U32(data + 304 * cur + 286752 + 36),
        'region +64', U32(data + 304 * cur + 286752 + 64), 'planet mods count +128', U32(data + 304 * cur + 286952 + 128),
        '(<= 32)', 'events', U32(data + 490072), '(<= 8)', 'env', U32(data + 494868), '(<= 4)', 'ops', U32(data + 155672),
        '(<= 512)')
  end
end
local DEFS = P(G + 0x2E380D0)
out('KYC_K7 definitions', h(DEFS), 'count +53248', U32(DEFS and DEFS + 53248), '(<= 1024)', 'row0 id/category/kind',
    U32(DEFS), U32(DEFS and DEFS + 4), U32(DEFS and DEFS + 24))
out('KYC_K7 category table rows 0..13 flag +9:', (function() local t = {} for c = 0, 13 do t[#t + 1] = tostring(U8(G + 0x2CA1F40 + 168 * c + 9)) end return table.concat(t, ' ') end)())
local GW = P(G + 0x2E38278)
if GW then
  local t = {}
  for i = 0, 31 do local n = U32(GW + 356 * i + 80) if n and n > 0 then t[#t + 1] = i .. ':' .. n .. '/scope' .. tostring(U8(GW + 356 * i + 84)) end end
  out('KYC_K7 war effects (entry:count/scope, counts <= 5)', table.concat(t, ' '))
end
-- K8 difficulty settings (10 x 816): draws and the Terminid candidates (native ids <= 32)
for d = 1, 10 do
  local row = G + 0x2C44280 + 816 * (d - 1)
  local c = {}
  for i = 0, 7 do c[#c + 1] = tostring(U32(row + 276 + 12 * i)) .. '@' .. f(F32(row + 280 + 12 * i)) end
  out('KYC_K8 difficulty', d, 'draws', U32(row + 272), 'terminid candidates', table.concat(c, ' '))
end
-- K9 mission config and override maps
if B then
  local mtype = U16(B + 0x4168D0 + 26)
  if mtype and mtype < 256 then
    local cfg = G + 0x312EB50 + 896 * mtype
    out('KYC_K9 mission type', mtype, 'mode +0x34', U8(cfg + 0x34), 'marker', H64(cfg + 0x360), '(857c2cd17f827849 = HordeOnly marker)',
        'exclusions', U32(cfg + 0x14), U32(cfg + 0x18), U32(cfg + 0x1C), U32(cfg + 0x20))
  end
end
local CFG = P(G + 0x2E38128)
for _, off in ipairs({73848, 49232}) do
  local cap = U32(CFG and CFG + off + 8)
  out('KYC_K9 override map +' .. off, 'entries', h(P(CFG and CFG + off)), 'capacity', cap, 'pow2', tostring(cap == 0 or pow2(cap)),
      'empty', h(U32(CFG and CFG + off + 12)), 'multiplier', U32(CFG and CFG + off + 16))
end
-- K10 panel anchor: registries (count 1, owner, kind 228 map / 231 briefing), fonts, widgets
if M then
  for _, r in ipairs({{'map', 25464, 228, 349072}, {'briefing', 25512, 231, 31232}}) do
    local name, off, kind, widget = r[1], r[2], r[3], r[4]
    local count, owner, k = U32(M + off), P(M + off + 8), U32(M + off + 16)
    out('KYC_K10', name, 'registry +' .. off, 'count', count, '(1)', 'owner', h(owner), 'kind', k, '(' .. kind .. ')')
    if owner and count == 1 and k == kind then
      local w = owner + widget
      out('KYC_K10', name, 'widget +' .. widget, 'flags', h(U32(w)), '(bit 0x10 visible)', 'opacity +84', f(F32(w + 84)),
          'scale +100/+140', f(F32(w + 100)), f(F32(w + 140)), 'pos +148/+156', f(F32(w + 148)), f(F32(w + 156)),
          'size +36/+40', f(F32(w + 36)), f(F32(w + 40)), '(panel visible: flags&0x10, opacity ~1, scale 0.3..4, size*scale >= 200x40)')
      if name == 'map' then
        local p = owner + 280528
        out('KYC_K10 map planet widget +280528 flags', h(U32(p)), 'opacity', f(F32(p + 84)), 'size', f(F32(p + 36)), f(F32(p + 40)),
            '| preview +526048 flags', h(U32(owner + 526048)), 'opacity', f(F32(owner + 526048 + 84)))
      else
        out('KYC_K10 briefing owner +8', U32(owner + 8), '(0 on the briefing tab, 1 on loadout)')
      end
    end
  end
  out('KYC_K10 old registries +25224/+25272 kinds', U32(M + 25224 + 16), U32(M + 25272 + 16), '(should not be 228/231)')
end
out('KYC_K10 font', H64(G + 0x312D998), 'material', H64((P(G + 0x3180C08) or 0) + 24), 'atlas', H64(G + 0x312E618),
    '(all nonzero once the war table drew)')
-- K11 enemy tag table: 33 natives, GM_BugDefiler at 12, GM_BugDragon_Traveler at 13, Count at 33
out('KYC_K11 tags [2]', h(U32(G + 0x2069D50 + 8)), '(0x22E4FCAC GM_BugAcid)', '[12]', h(U32(G + 0x2069D50 + 48)),
    '(0x35E13F9E GM_BugDefiler)', '[13]', h(U32(G + 0x2069D50 + 52)), '(0x9FD5943A)', '[32]', h(U32(G + 0x2069D50 + 128)),
    '(0xBA586F51 GM_SEAF)', '[33]', h(U32(G + 0x2069D50 + 132)), '(0xE09AD33D Count)')
-- K13 Text Language (bingus_text): settings +705628 +212 index -> record +8 code
local idx = R and U32(R + 705840)
local rec = idx and idx < 15 and P(G + 0x3180DE0 + 8 * idx)
local code = rec and P(rec + 8)
local s = code and read(code, 8)
out('KYC_K13 language index', idx, '(< 15)', 'code', s and s:match('^(%a[%a%-]*)') or 'nil', '(us for English)')
return true
