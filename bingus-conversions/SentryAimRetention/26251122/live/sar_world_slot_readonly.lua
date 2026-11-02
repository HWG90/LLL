-- Sentry Aim Retention data-v8.7 guard (2026-10-31), reads only. Checks the new witness at exe+0x87bb80, the world
-- table exe+0x826bc0 searches (exe+0x2862010, from its lea), and each world's physics scene slot that the raycast
-- loads (exe+0x2861d70 + 0xb0*index). The guard skips the raycast when the slot for the game world's index is empty.
local function hx(s) return (s:gsub('..', function(p) return string.char(tonumber(p, 16)) end)) end
local function h(v) return v and string.format('0x%x', v) or 'nil' end
local w = read(exe + 0x87bb80, 65)
out('witness 0x87bb80 ' .. (w == nil and 'unreadable' or w == hx(
  '488d15c961fe014181e40080000033f644896424680fae5c24508b4c24500fbae90f894c24500fae54245083ff04' ..
  '7205448bfeeb0c4869cfb00000004c8b7c1120') and 'same' or 'DIFFERENT'))
local i8 = read(exe + 0x826bc0, 29)
out('witness 0x826bc0 ' .. (i8 == nil and 'unreadable' or
  i8 == hx('33c04c8d0547b403020f1f800000000049390cc0740cffc083f80475f3') and 'same' or 'DIFFERENT'))
local world = ptr(game + 0x2e271f8)
out('game world ' .. h(world))
local index
for i = 0, 3 do
  local listed, scene = ptr(exe + 0x2862010 + 8 * i), ptr(exe + 0x2861d70 + 0xb0 * i)
  if world and listed == world then index = i end
  out(string.format('world %d listed=%s scene=%s%s', i, h(listed), h(scene),
    world and listed == world and ' <- game world' or ''))
end
local scene = index and ptr(exe + 0x2861d70 + 0xb0 * index)
local verdict = not index and 'game world not listed (index 4: cast_terrain asserts as before)'
  or scene and 'slot set: the guard lets the raycast run' or 'slot EMPTY: the guard skips the raycast'
out('SAR-GUARD ' .. verdict)
return verdict
