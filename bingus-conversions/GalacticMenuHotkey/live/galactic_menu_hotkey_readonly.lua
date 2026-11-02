-- Ship Station Hotkeys (Vanilla Plus Megapack option GalacticMenuHotkey) port, read-only live checks G0-G10
-- (build 26088801). Reads only, through Link's Link to Memory (read/ptr/get/hashmap/region; nothing here writes
-- or calls a game function). Every pointer is range-checked before it is followed. Run it aboard the ship
-- (G0-G9), once with the Hellpod open after picking a mission, once standing at the Stratagem Hero cabinet, and
-- once while the Hellpod briefing (Loadout screen) intro plays. See NOTES.md for what each line should show.
local G = assert(game, 'game.dll base')
local function ok(v) return v and v >= 0x10000 and v < 0x800000000000 end
local function P(a) if not ok(a) then return nil end local v = ptr(a) return ok(v) and v or nil end
local function U32(a) local s = ok(a) and read(a, 4) return s and get(s, 0, 'u32') or nil end
local function U8(a) local s = ok(a) and read(a, 1) return s and s:byte() or nil end
local function F32(a) local s = ok(a) and read(a, 4) return s and get(s, 0, 'f32') or nil end
local function HEX(a, n) local s = ok(a) and read(a, n) if not s then return 'nil' end
  return (s:gsub('.', function(c) return fmt('%02x', c:byte()) end)) end
local function h(v) return v and fmt('0x%X', v) or 'nil' end
local function f(v) return v and fmt('%.3f', v) or 'nil' end
local function reg(a) local r = ok(a) and region(a)
  return r and fmt('protect 0x%X state 0x%X type 0x%X', r.protection or -1, r.state or -1, r.type or -1) or 'nil' end
out('GMH_LIVE game.dll base', h(G), 'exe', h(exe))
-- G0 the four native entries: prologue bytes the mod checks (nil = page not readable yet: checked at first use)
for _, e in ipairs({{'presenter open', 0x135B4F0, '48895c24084889742410574883ec208b'},
                    {'arcade start', 0x9A9450, '488bc448895010488948085355574883'},
                    {'instant seat', 0x642F30, '48895c24204889542410565741544155'},
                    {'briefing entry', 0x66B5D0, '48894c2408574883ec404c8b0d'}}) do
  local got = HEX(G + e[2], #e[3] / 2)
  out('GMH_G0', e[1], h(e[2]), got, got == e[3] and 'MATCH' or (got == 'nil' and 'NOT RESIDENT' or 'DIFFERS'),
      'page', reg(G + e[2]))
end
-- G1 presenter manager = UI state + 0x4288: current +0xC, popup guard +0x10 (new), stack +0x14.., depth +0x28
local UI = P(G + 0x2E38160)
if UI then
  local M = UI + 0x4288
  local st = {}
  for i = 0, 4 do st[#st + 1] = U32(M + 0x14 + 4 * i) end
  out('GMH_G1 ui', h(UI), 'current +0xC', U32(M + 0xC), 'popup +0x10', U32(M + 0x10), 'depth +0x28', U32(M + 0x28),
      'stack', table.concat(st, ' '), '(idle: current 0, depth 0; Hologram 15, Armory 5, Terminal 6, ShipMgmt 8, Loadout 14)')
else out('GMH_G1 ui state null') end
-- G2 mission record: flag +8, type +0x40 (mission = flag ~= 0 and type 1..7)
local MR = P(G + 0x2CE1850)
out('GMH_G2 mission record', h(MR), 'flag +8', U32(MR and MR + 8), 'type +0x40', U32(MR and MR + 0x40),
    '(aboard: flag 0 or type outside 1..7)')
-- G3 menu system: current MenuScreenType [+0] (11 Loadout, 24 Hologram), loadout screen [+0xB0]; intro phase/timer
local S = P(G + 0x2E38170)
local L = S and P(S + 0xB0)
out('GMH_G3 menu system', h(S), 'screen type', U32(S), 'loadout screen +0xB0', h(L))
if L then
  out('GMH_G3 intro phase +0x2739CC', U32(L + 0x2739CC), 'timer +0x2739C8', f(F32(L + 0x2739C8)),
      '(phase 0..7; phase 1 timer counts down from 2.0; phase 0 timer -1.0)',
      '| old offsets +0x27398C', U32(L + 0x27398C), '+0x273988', f(F32(L + 0x273988)),
      '| write page', reg(L + 0x2739C8), '(expect PAGE_READWRITE 0x4, MEM_COMMIT, MEM_PRIVATE)')
end
-- G4 local player and avatar entity
local PM = P(G + 0x2CE1618)
local N = P(G + 0x2CE41B8)
local avatar_id, avatar_unit
if PM and N then
  local ref = U32(PM + 0x3A8)
  local rec = P(PM + 0xE8)
  out('GMH_G4 players', h(PM), 'local count +0x84', U32(PM + 0x84), 'active +0x88', U32(PM + 0x88), 'record +0xE8',
      h(rec), 'flags +20', U8(rec and rec + 20), 'avatar ref +0x3A8', h(ref), '(counts 1..4, flags bit 0 set)')
  local idx = ref and ref ~= 0x7FFF and hashmap(N + 0xF24990, ref)
  out('GMH_G4 entity map +0xF24990 cap', U32(N + 0xF24990 + 8), 'empty', h(U32(N + 0xF24990 + 12)), 'mult',
      h(U32(N + 0xF24990 + 16)), 'index', idx)
  if idx then
    local R = N + 0xF349E0 + 24 * idx
    avatar_id, avatar_unit = U32(R + 8), U32(R + 12)
    out('GMH_G4 avatar record', HEX(R, 8), '(expect 97fa4d294d331c4d)', 'id', h(avatar_id), 'unit', h(avatar_unit),
        'flags', U8(R + 20))
  end
end
-- G5 arcade: component (count 1, capacity 128, empty 0), pool +5208 (0 idle), registry type-67 row
local C = P(G + 0x2CE18B0)
if C then
  local pool = P(C + 88)
  out('GMH_G5 arcade component', h(C), 'count +24', U32(C + 24), 'buckets +48', h(P(C + 48)), 'capacity +56',
      U32(C + 56), 'empty +60', U32(C + 60), 'pool +88', h(pool), 'active player +5208', U32(pool and pool + 5208),
      'last +5212', U32(pool and pool + 5212))
end
local R = P(G + 0x2CE2040)
if R then
  local n = U32(R + 19704)
  local hits = {}
  for i = 0, math.min(n or 0, 256) - 1 do
    if U32(R + 19712 + 16 * i + 8) == 67 then hits[#hits + 1] = h(P(R + 19712 + 16 * i)) end
  end
  out('GMH_G5 registry', h(R), 'list count +19704', n, 'type-67 rows', #hits, table.concat(hits, ' '),
      '(expect exactly 1) | old +19512 count reads', U32(R + 19512))
end
-- G6 world-position function: [script API + 0x18] + 0x88, prologue 40534883ec20
local A = P(G + 0x2CE14C8)
local T = A and P(A + 24)
local F = T and P(T + 136)
out('GMH_G6 script API', h(A), 'table', h(T), 'slot +136', h(F), 'bytes', HEX(F, 6), '(expect 40534883ec20)')
-- G7 Hellpod: deployment system (+32/+36 = 1/1 solo, +72984 slot pod) and manager per-pod arrays
local DS, HM = P(G + 0x2CE17A0), P(G + 0x2CE15D8)
local slot_pod = U32(DS and DS + 72984)
out('GMH_G7 deployment system', h(DS), '+32', U32(DS and DS + 32), '+36', U32(DS and DS + 36), 'slot pod +72984',
    h(slot_pod), '| manager', h(HM), 'count +8', U32(HM and HM + 8))
if HM then
  for i = 0, math.min(U32(HM + 8) or 0, 4) - 1 do
    local e = P(HM + 104 + 8 * i)
    out('GMH_G7 pod', i, 'entity', h(e), 'id', h(U32(e and e + 8)), 'flags', U8(e and e + 20), 'mode', U32(HM + 136 + 12 * i),
        'state', U32(HM + 184 + 20 * i), 'index', U32(HM + 188 + 20 * i), 'target', U32(HM + 264 + 4 * i),
        '(mission picked: mode 2; open 3/3; occupied 4)')
  end
end
-- G8 seater: the avatar's seater record (+0 seat collection 0 while standing, byte +48 transition 0)
local SC = P(G + 0x2CE1F38)
if SC and avatar_id then
  local idx = hashmap(SC + 32, avatar_id)
  local ents, recs = P(SC + 56), P(SC + 72)
  local e = idx and ents and P(ents + 8 * idx)
  out('GMH_G8 seater', h(SC), 'count +12', U32(SC + 12), 'index', idx, 'entity', h(e), 'entity id', h(U32(e and e + 8)),
      '(= avatar id', h(avatar_id) .. ')', 'record +0', U32(idx and recs and recs + 64 * idx),
      'byte +48', U8(idx and recs and recs + 64 * idx + 48), '(standing: 0 / 0; in the pod: +0 = slot pod)')
end
-- G9 input owner and the gate stretch (state bytes of the six shortcut actions)
local I = P(G + 0x2E38250)
if I then
  local s = {}
  for _, a in ipairs({{12, 1}, {12, 0}, {10, 1}, {10, 4}, {10, 8}, {10, 14}, {10, 9}}) do
    s[#s + 1] = U8(I + 808 + 32 * (a[1] * 97 + a[2]))
  end
  out('GMH_G9 input owner', h(I), 'state bytes', table.concat(s, ' '), '(0 while nothing is held; hold Tab: one turns 1)')
end
-- G10 text language (bingus_text M.GAME)
local GS = P(G + 0x2CE1508)
local n = U32(GS and GS + 705628 + 212)
local LR = n and n < 15 and P(G + 0x3180DE0 + 8 * n)
local CP = LR and P(LR + 8)
out('GMH_G10 language index', n, 'code', CP and read(CP, 4) or 'nil', '(us for English)')
return true
