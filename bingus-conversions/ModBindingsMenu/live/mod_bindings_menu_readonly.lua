-- Mod Bindings Menu v2.3 port, read-only live checks L0-L10 (build 26088801). Reads only, through Link's Link to
-- Memory (read/ptr/get/region; nothing here writes or calls a game function). Every pointer is range-checked before
-- it is followed; code is read through read() (ReadProcessMemory), which simply fails on a page that is not resident.
-- Run it (a) at the title screen / ship, (b) with Options > Controls > the keyboard binding page open on any tab,
-- (c) on the controller binding page, (d) in a mission. See NOTES.md for what each line should show.
local G = assert(game, 'game.dll base')
local function ok(v) return v and v >= 0x10000 and v < 0x800000000000 end
local function P(a) if not ok(a) then return nil end local v = ptr(a) return ok(v) and v or nil end
local function U32(a) local s = ok(a) and read(a, 4) return s and get(s, 0, 'u32') or nil end
local function U8(a) local s = ok(a) and read(a, 1) return s and s:byte() or nil end
local function F32(a) local s = ok(a) and read(a, 4) return s and get(s, 0, 'f32') or nil end
local function HEX(a, n) local s = ok(a) and read(a, n) return s and (s:gsub('.', function(c) return fmt('%02x', c:byte()) end)) or 'unreadable' end
local function h(v) return v and fmt('0x%X', v) or 'nil' end
local function f(v) return v and fmt('%.3f', v) or 'nil' end
out('MBM_LIVE game.dll base', h(G))

-- L0 native code: page state and prologue (expected bytes = MAP.json new_sig). A no-access page (prot 0x1) is
-- normal before the game first runs that code; the port then checks it right before its first call.
local NATIVES = {
  {'build_rows', 0x1693B90, '488bc45341564881ecd8000000'},
  {'set_tab_labels', 0x162BEE0, '488954241053564883ec680f29742430'},
  {'reset_list', 0x1695020, '40534883ec20488bd985d2743083ea01'},
  {'consume', 0x1190E30, '40534883ec204c8bd14c8bca488bcae81cda3fff'},
}
for _, n in ipairs(NATIVES) do
  local r = region(G + n[2])
  local got = HEX(G + n[2], #n[3] / 2)
  out('MBM_L0', n[1], 'rva', h(n[2]), 'page prot', r and h(r.protection) or 'nil', 'state', r and h(r.state or -1) or 'nil',
      'prologue', got == n[3] and 'MATCH' or (got == 'unreadable' and 'not resident' or ('DIFFERS ' .. got)))
end
-- L3 build_rows' last six instructions sit on page 0x1694000, encrypted in the static capture: once the game has
-- built a binding list (open a binding page), these 36 bytes are readable and must equal the expected tail.
do
  local want = '488bcfc787b807000000000000e8ee17f8ffc68389cd240000488b5c24304883c4205fc3'
  local got = HEX(G + 0x1694000, 36)
  out('MBM_L3 build_rows tail @0x1694000', got == want and 'MATCH' or (got == 'unreadable' and 'not resident yet' or 'DIFFERS ' .. got))
end

-- L1 static data
out('MBM_L1 tab labels @0x2CC8BB0', HEX(G + 0x2CC8BB0, 12), '(expect 51f4708d605c5ef1eb7f8400)')
local DORMANT = {{12, 1, 0x62EA38BF}, {12, 0, 0x82FBDCB2}, {10, 1, 0x6218A8BA}, {10, 4, 0xD46660E4}, {9, 11, 0xAE71F7A9}}
for _, d in ipairs(DORMANT) do
  local v = U32(G + 0x24BC8A0 + 4 * (97 * d[1] + d[2]))
  out('MBM_L1 action label', d[1] .. ':' .. d[2], h(v), v == d[3] and 'original' or '(MBM may have borrowed it on a binding page)')
end
out('MBM_L1 MODS title slot @0x2CE3680', HEX(G + 0x2CE3680, 8), '(0 off the binding pages; a pointer to "MODS" on them)')
local t = P(G + 0x2CE3680)
if t then out('MBM_L1 MODS title text', (read(t, 4) or '?')) end
out('MBM_L1 pool slots 0x2CE2738/0x2CE3490', HEX(G + 0x2CE2738, 8), HEX(G + 0x2CE3490, 8), '(0 unless MBM borrowed them)')

-- L2 input owner and binding maps
local I = P(G + 0x2E38250)
out('MBM_L2 input owner', h(I))
if I then
  for _, m in ipairs({{'live', 0xA7AD0}, {'defaults', 0xA7B78}}) do
    local buckets, cap = P(I + m[2]), U32(I + m[2] + 8)
    out('MBM_L2', m[1], 'map', h(buckets), 'capacity', cap, '(expect 256)')
    if buckets and cap == 256 then
      local found = 0
      for i = 0, 255 do
        local rec = buckets + 0x148 * i
        local code = U32(rec)
        if code == 12 * 65536 + 1 or code == 10 * 65536 + 1 then
          found = found + 1
          local n = U32(rec + 4)
          out('MBM_L2', m[1], 'record', i, 'code', h(code), 'count', n, 'first mapping', HEX(rec + 8, 20),
              '(flags low nibble 3 = keyboard; key = 49 + vk)')
        end
      end
      out('MBM_L2', m[1], 'dormant records found', found, '(expect 2)')
    end
  end
  local s = {}
  for _, a in ipairs({1, 2, 5, 6, 10}) do s[#s + 1] = a .. '=' .. tostring(U8(I + 0x328 + 32 * a)) .. '/' .. f(F32(I + 0x328 + 32 * a + 8)) end
  out('MBM_L9 UI action states group 0 (down byte / held s)', table.concat(s, ' '))
end

-- L4 UI stack: top 26 = binding page
local U = P(G + 0x2E38160)
local depth = U and U32(U + 0x42B0)
local top = depth and depth >= 1 and depth <= 5 and U32(U + 0x429C + 4 * (depth - 1))
out('MBM_L4 ui', h(U), 'depth', depth, 'top', top, '(26 with a binding page on top)')

-- L5 binding screen, tab bar, list
local M = P(G + 0x2E38170)
local S = M and P(M + 0xD0)
out('MBM_L5 menu', h(M), 'binding screen [menu+0xD0]', h(S))
if S then
  local bar = S + 0x4E0
  out('MBM_L5 selected tab [S+8]', U32(S + 8), 'bar count', U32(bar + 0xE068), 'current', U32(bar + 0xE06C),
      '(count 3 native, 4 with MODS, 5 with MORE MODS; current == selected)')
  out('MBM_L5 bar labels', HEX(bar + 0xDFE8, 20), '(51f4708d 605c5ef1 eb7f8400, then 4c101e78 with MODS)')
  local cur = U32(bar + 0xE06C)
  if cur and cur < 8 then out('MBM_L5 current button state', U32(bar + 0xD48 * cur + 0x2AFC), 'active', U8(bar + 0xD48 * cur + 0x2B0D), '(3, 1)') end
  local L = S + 0x529A8
  local rows, descs = U32(L + 0x24CD8C), U32(L + 0x24CD98)
  out('MBM_L5 list rows', rows, 'descriptors', descs, 'controller page flag', U32(L + 0x24CD80),
      '(rows > 0 and <= 97; descriptors 49/26/14 on native tabs, MBM\'s layout size on MODS; flag 0 keyboard, 1 controller)')
  if rows and rows > 0 and rows <= 97 then
    for k = 0, math.min(rows, 6) - 1 do
      local R = L + 0x1EB0 + 0x60D0 * k
      out('MBM_L5 row', k, 'type +0x60B0', U32(R + 0x60B0), 'code +0x60B8', h(U32(R + 0x60B8)),
          'header label +0x11B8', h(U32(R + 0x10A8 + 0x110)), '(type 4 = section header with a label; code group<<16|action)')
    end
  end
  for _, w in ipairs({{'viewport L+0x110', L + 0x110}, {'header row L+0x1EB0', L + 0x1EB0}}) do
    local a = w[2]
    out('MBM_L5 widget', w[1], 'flags', h(U32(a)), 'visible bit', U32(a) and (math.floor(U32(a) / 16) % 2) or 'nil',
        'opacity +0x54', f(F32(a + 0x54)), 'x +0x94', f(F32(a + 0x94)), 'y +0x9C', f(F32(a + 0x9C)), 'w,h +0x24', f(F32(a + 0x24)),
        f(F32(a + 0x28)), 'scale +0x64/+0x8C', f(F32(a + 0x64)), f(F32(a + 0x8C)), '(visible 1, opacity ~1, scale 0.3..4 equal)')
  end
end

-- L6 menu cursor: new offsets (menu+0x5F8, roots menu+0x168 / +0x290) against v2.3's (0x5F0 / 0x160 / 0x288)
if M then
  local C = M + 0x5F8
  local parent = P(C + 0x200)
  out('MBM_L6 cursor menu+0x5F8 parent', h(parent), 'is root', tostring(parent == M + 0x168 or parent == M + 0x290),
      'pos', f(F32(C + 0x26C)), f(F32(C + 0x270)), '(root true while the mouse cursor is shown; pos follows the mouse)')
  local old = P(M + 0x5F0 + 0x200)
  out('MBM_L6 v2.3 offsets menu+0x5F0 parent', h(old), 'is old root', tostring(old == M + 0x160 or old == M + 0x288), '(expect false)')
end

-- L7 mission record
local R = P(G + 0x2CE1850)
out('MBM_L7 mission record', h(R), '+8', R and U32(R + 8), 'mode +0x40', R and U32(R + 0x40), '(in a mission: +8 ~= 0 and mode 1..7)')

-- L8 panel font hashes (equal to the old build's) and the material owner
out('MBM_L8 font', HEX(G + 0x312D998, 8), '(f27dd1c5ba2a6db5 or the active language\'s font)', 'atlas', HEX(G + 0x312E618, 8),
    '(4b939fc791b9ebd1 likewise)')
local MO = P(G + 0x3180C08)
out('MBM_L8 material owner', h(MO), 'material hash +0x18', MO and HEX(MO + 0x18, 8) or 'nil')

-- L10 the mod's own state (same Lua state), when visible
do
  local okk, api = pcall(function() return rawget(_G, 'ModBindingsMenu') end)
  if okk and type(api) == 'table' then
    out('MBM_L10 api version', api.version, 'ready', tostring(api.ready and api.ready()), 'revision', api.revision)
  else out('MBM_L10 ModBindingsMenu not visible from this eval (read ModBindingsMenu.log)') end
  local rt = rawget(_G, 'BingusRuntime')
  local st = rt and rt.statuses and rt.statuses.ModBindingsMenu
  if st then out('MBM_L10 guard status', st.state) end
end
return true
