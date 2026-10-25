-- Hellpod Steering Unlocked port, read-only live checks L0-L5 (build 26088801). Reads only, through Link's Link to
-- Memory (game, exe, read, ptr, get, region, out, fmt; nothing here writes or calls a game function). Every pointer is
-- range-checked before it is followed. Run it on the ship, then again in a mission (best: during the drop, before
-- and after the hellpod lands). See NOTES.md for what each line should show.
local G = assert(game, 'game.dll base')
local function ok(v) return v and v >= 0x10000 and v < 0x800000000000 end
local function P(a) if not ok(a) then return nil end local v = ptr(a) return ok(v) and v or nil end
local function U32(a) local s = ok(a) and read(a, 4) return s and get(s, 0, 'u32') or nil end
local function U8(a) local s = ok(a) and read(a, 1) return s and s:byte() or nil end
local function F32(a) local s = ok(a) and read(a, 4) return s and get(s, 0, 'f32') or nil end
local function h(v) return v and fmt('0x%X', v) or 'nil' end
local function f(v) return v and fmt('%.6g', v) or 'nil' end
local function near(a, b) return a and b and a == a and math.abs(a - b) <= math.max(0.00001, math.abs(b) * 0.00001) end
out('HSU_LIVE game.dll base', h(G), 'exe', h(exe))
do -- L0: the mod's own status table (same Lua state), when visible from here
  local okk, st = pcall(function() return rawget(_G, 'HellpodSteeringUnlocked') end)
  if okk and type(st) == 'table' then out('HSU_L0 mod revision', st.revision, 'status', st.status, 'active', tostring(st.active))
  else out('HSU_L0 mod status table not visible from this eval (read HellpodSteeringUnlocked.log instead)') end
end
-- L1 globals and ownership: manager = [game+0x2E287D8], owner = [game+0x2E38250], manager - owner == 0x7C8810
local M, O = P(G + 0x2E287D8), P(G + 0x2E38250)
out('HSU_L1 manager [+0x2E287D8]', h(M), 'owner [+0x2E38250]', h(O), 'manager - owner', h(M and O and M - O),
    (M and O and M - O == 0x7C8810) and 'ok (0x7C8810)' or 'MISMATCH (expect 0x7C8810)')
out('HSU_L1 old slots (should NOT hold this pair): [+0x346D578]', h(P(G + 0x346D578)), '[+0x347CF18]', h(P(G + 0x347CF18)))
if not M then out('HSU_L1 manager pointer null: the mod reports waiting_for_mission'); return true end
-- L2 layout (the mission initializer game.dll 0x126C830 writes exactly these)
local flag, records, links = U8(M), U32(M + 0x8004), U32(M + 0x10008)
local setp, cap, cnt, three = P(M + 0x10010), U32(M + 0x10018), U32(M + 0x1001C), U32(M + 0x10020)
local w, half, cell, recip = F32(M + 0x11028), F32(M + 0x1102C), F32(M + 0x11030), F32(M + 0x11034)
out('HSU_L2 flag +0', flag, '(1 game value in a mission, 0 after the mod cleared it, 0 blank aboard ship)',
    'records +0x8004', records, '(<=1024)', 'links +0x10008', links, '(<=8192)')
out('HSU_L2 set +0x10010', h(setp), (setp and setp - M == 0x10028) and 'self+0x10028 ok' or '(expect manager+0x10028 or 0)',
    'capacity +0x10018', cap, '(1024)', 'count +0x1001C', cnt, '(<=1024)', 'kind +0x10020', three, '(3)')
out('HSU_L2 dims +0x11028 width', f(w), 'half', f(half), near(half, w and w / 2) and 'ok' or '?', 'cell', f(cell),
    near(cell, w and w / 64) and 'ok' or '?', 'reciprocal', f(recip), near(recip, cell and cell ~= 0 and 1 / cell) and 'ok' or '?',
    '(width 64..16384 in a mission; all 0 blank)')
local blank = flag == 0 and records == 0 and links == 0 and not setp and cap == 0 and cnt == 0 and three == 0
    and w == 0 and half == 0 and cell == 0 and recip == 0
local valid = records and links and records <= 1024 and links <= 8192 and setp and setp - M == 0x10028 and cap == 1024
    and cnt and cnt <= 1024 and three == 3 and w and w >= 64 and w <= 16384 and near(half, w / 2) and near(cell, w / 64)
    and near(recip, 1 / cell)
out('HSU_L3 classification', blank and 'BLANK (ship: mod waits)' or (valid and 'VALID (mission: mod may write)' or
    'NEITHER (mod would refuse: avoidance_layout_mismatch)'), 'flag', flag)
-- L4 page check: write_batch requires the whole 69688-byte manager to be committed private read-write data
local rg, rg2 = region(M), region(M + 69688 - 1)
for i, r in ipairs({rg, rg2}) do
  out('HSU_L4 region', i == 1 and 'manager+0' or 'manager+69687', r and fmt('protect 0x%X state 0x%X type 0x%X', r.protection or -1,
      r.state or -1, r.type or -1) or 'nil', '(expect protect 0x4, state 0x1000, type 0x20000)')
end
-- L5 owner context: the owner block is the object the static initializer derives ~40 globals from; a few siblings
-- must be owner + their own offsets (same initializer block, game.dll 0x1289CC7..)
out('HSU_L5 siblings: [+0x2E38168] - owner', h(P(G + 0x2E38168) and O and P(G + 0x2E38168) - O), '(0x5EB400)',
    '[+0x2E381C8] - owner', h(P(G + 0x2E381C8) and O and P(G + 0x2E381C8) - O), '(0x7D9848)')
return true
