-- Clickable Scrollbars port, read-only live checks C0-C9 (build 26088801). Reads only, through Link's Link to
-- Memory (read/ptr/get/region/out/fmt; nothing here writes or calls a game function). Every pointer is range-checked
-- before it is followed. Run it once at the ship (no menu), then with each screen open: Ship Armory (equipment
-- grid, then its Career tab), the mission loadout picker, Options (escape menu, a settings page with a scrollbar),
-- and the key bindings page. See NOTES.md for what each line should show.
local G = assert(game, 'game.dll base')
local function ok(v) return v and v >= 0x10000 and v < 0x800000000000 end
local function P(a) if not ok(a) then return nil end local v = ptr(a) return ok(v) and v or nil end
local function U32(a) local s = ok(a) and read(a, 4) return s and get(s, 0, 'u32') or nil end
local function U8(a) local s = ok(a) and read(a, 1) return s and s:byte() or nil end
local function F32(a) local s = ok(a) and read(a, 4) return s and get(s, 0, 'f32') or nil end
local function h(v) return v and fmt('0x%X', v) or 'nil' end
local function f(v) return v and fmt('%.3f', v) or 'nil' end
local function hex(s) return s and (s:gsub('.', function(c) return fmt('%02x', c:byte()) end)) or 'unreadable' end
out('CS_LIVE game.dll base', h(G), 'exe', h(exe))

-- C1 the five routines the port calls: 24/20 prologue bytes (unreadable = page not resident yet; the port then
-- checks it again right before its first call)
local ROUTINES = {
  {'GRID_SOLVER', 0x1753DC0, '488bc45355565741544155415641574881ecf800000083b9'},
  {'SCROLL_SET', 0x16157C0, '0f57d20f2fd1770cf30f1015c40dc300f30f5dd1f30f1081'},
  {'POSITION_SET', 0x12DF3B0, '48895c241848896c24204889542410565741574883ec20f3'},
  {'ANIMATION_STOP', 0x12D1A50, '40534883ec40488b05b3351e014833c448894424300fb601'},
  {'INPUT_CONSUME', 0x1190E30, '40534883ec204c8bd14c8bca488bcae81cda3fff'},
}
for _, r in ipairs(ROUTINES) do
  local got = hex(read(G + r[2], #r[3] / 2))
  out('CS_C1', r[1], h(r[2]), got == r[3] and 'MATCH' or (got == 'unreadable' and 'NOT RESIDENT' or 'DIFFERS ' .. got))
end

-- C2 dispatch registry: count at +0x166C, 16-byte rows at +0x1670 {controller u64, kind u32}
local D = P(G + 0x2CE2040)
local rows = {}
if D then
  local n = U32(D + 0x166C)
  out('CS_C2 dispatch', h(D), 'count +0x166C', n, '(1..64)')
  if n and n >= 1 and n <= 64 then
    local kinds = {}
    for i = 0, n - 1 do
      local c, k = P(D + 0x1670 + 16 * i), U32(D + 0x1670 + 16 * i + 8)
      rows[#rows + 1] = {c = c, k = k}
      kinds[#kinds + 1] = tostring(k)
    end
    out('CS_C2 kinds', table.concat(kinds, ' '), '(Armory open: 226; loadout picker open: 231; never 224/229)')
  end
else out('CS_C2 dispatch pointer null') end
local function controller(kind) for _, r in ipairs(rows) do if r.k == kind and r.c then return r.c end end end

-- C3 UI menu / stack: current +0x4294, stack +0x429C (5 x u32), depth +0x42B0
local U = P(G + 0x2E38160)
if U then
  local depth, st = U32(U + 0x42B0), {}
  for i = 0, 4 do st[#st + 1] = tostring(U32(U + 0x429C + 4 * i)) end
  out('CS_C3 ui', h(U), 'menu +0x4294', U32(U + 0x4294), 'stack', table.concat(st, ' '), 'depth', depth,
      '(top = stack[depth]: 5 Armory, 14 loadout, 1 escape/Options, 26 key bindings)')
else out('CS_C3 ui state null') end

-- C4 Armory (kind 226): grid = controller + 0x7FDE8, its bar at +0x110, thumb at +0x378; Career panel at +0x4DC08
local function grid_line(tag, g)
  local bar = g + 0x110
  local span, value, scroll = F32(g + 0x8C0), F32(g + 0x8C8), F32(g + 0x92960)
  out(tag, 'grid', h(g), 'bar alpha +0x164', f(F32(g + 0x164)), 'bar h +0x120', f(F32(g + 0x120)),
      'span +0x8C0', f(span), 'value +0x8C8', f(value), 'scroll +0x92960', f(scroll),
      'value*span', (span and value) and f(span * value) or 'nil', 'content +0x92968', f(F32(g + 0x92968)))
  out(tag, 'items +0x92984', U32(g + 0x92984), 'columns +0xB9B4', U32(g + 0xB9B4), 'rows +0x91F0C', U32(g + 0x91F0C),
      'first/last +0x98040', U32(g + 0x98040), U32(g + 0x98044), 'selected +0x928F4', U32(g + 0x928F4),
      'kind +0x92FC4', U32(g + 0x92FC4), 'anim flag +0x92902', U8(g + 0x92902), 'thumb h +0x388', f(F32(g + 0x388)))
  local rg = region(g + 0x92960)
  out(tag, 'scroll field region', rg and fmt('protect 0x%X state 0x%X type 0x%X', rg.protection or -1,
      rg.state or -1, rg.type or -1) or 'nil', '(expect a committed read-write page: protect 0x4)')
end
local A = controller(226)
if A then
  grid_line('CS_C4 armory', A + 0x7FDE8)
  local C = A + 0x4DC08
  out('CS_C4 career', h(C), 'track alpha +0x2FAB8+0x54', f(F32(C + 0x2FAB8 + 0x54)), 'track h', f(F32(C + 0x2FAB8 + 0x10)),
      'thumb h +0x2FCE0+0x10', f(F32(C + 0x2FCE0 + 0x10)), 'list x/y +0x9BC/+0x9C0', f(F32(C + 0x9BC)),
      f(F32(C + 0x9C0)), 'list h +0x9C8', f(F32(C + 0x9C8)), 'scale +0x9D8', f(F32(C + 0x9D8)),
      'enabled +0x2FDF9', U8(C + 0x2FDF9), 'thumb_height +0x2FE34', f(F32(C + 0x2FE34)))
else out('CS_C4 no kind-226 controller registered (open the Ship Armory)') end

-- C5 loadout picker (kind 231): grid at controller + 0xD2F60 (was +0xD2F20); both read for comparison
local L = controller(231)
if L then
  grid_line('CS_C5 loadout', L + 0xD2F60)
  out('CS_C5 old offset +0xD2F20 reads: bar alpha', f(F32(L + 0xD2F20 + 0x164)), 'value', f(F32(L + 0xD2F20 + 0x8C8)),
      'columns', U32(L + 0xD2F20 + 0xB9B4), '(expected implausible)')
else out('CS_C5 no kind-231 controller registered (open the mission loadout picker)') end

-- C6/C7 inline lists: bar +0x330 (alpha +0x54, height +0x10), span +0xAE0, value +0xAE8, scroll +0x228, content +0x220
local function list_line(tag, list)
  local span, value = F32(list + 0xAE0), F32(list + 0xAE8)
  out(tag, 'list', h(list), 'bar alpha', f(F32(list + 0x330 + 0x54)), 'bar h', f(F32(list + 0x330 + 0x10)),
      'span +0xAE0', f(span), 'value +0xAE8', f(value), 'scroll +0x228', f(F32(list + 0x228)),
      'value*span', (span and value) and f(span * value) or 'nil', 'thumb h +0x598+0x10', f(F32(list + 0x598 + 0x10)))
end
local M = P(G + 0x2E38170)
if M then
  local S1, S26 = P(M + 0xC8), P(M + 0xD0)
  out('CS_C6 menu', h(M), 'escape screen +0xC8', h(S1), 'active +0xC', S1 and U8(S1 + 0xC))
  if S1 then list_line('CS_C6 settings', S1 + 0x3FEF20) end
  out('CS_C7 bindings screen +0xD0', h(S26), 'active +0xC', S26 and U8(S26 + 0xC), '+0x498F8', S26 and U32(S26 + 0x498F8),
      '+0x52588', S26 and U32(S26 + 0x52588))
  if S26 then list_line('CS_C7 bindings', S26 + 0x529A8) end
else out('CS_C6 menu system null') end

-- C8 input owner
local I = P(G + 0x2E38250)
out('CS_C8 input owner', h(I), '(non-null in menus)')

-- C9 UI root (logged by the mod only)
out('CS_C9 ui root', h(P(G + 0x2E380C8)))
return true
