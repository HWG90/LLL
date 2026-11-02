-- Reads only: why Enemy Collision Synchronized lists no unit. For both managers (game.dll .data 0x2CE1AF8 ragdolls,
-- 0x2CE1AD8 corpses; the header fields the mod's manager_header reads), the mod's own listing state
-- (_G.CorpseCollisionRepair.listings: address -> resource key, or false for a resource it has no profile for) and a
-- tally of the 8-byte resource keys at +0 of every entry's header, split into listed and unlisted. An unlisted key
-- that belongs to one of the 21 profiled enemies would mean the header layout or the hashes moved; only unprofiled
-- keys means no profiled enemy was present.
local s = rawget(_G, 'CorpseCollisionRepair')
if type(s) ~= 'table' then return 'no state' end
local parts = {fmt('status=%s flag=%s classified=%s unreadable=%s changes=%s', tostring(s.status),
  tostring(s.mission_flag), tostring(s.listing_classified), tostring(s.listing_unreadable), tostring(s.listing_changes))}
local layouts = {{name = 'ragdoll', slot = 0x2CE1AF8, count = 12, entities = 56, corpse = false},
                 {name = 'corpse', slot = 0x2CE1AD8, count = 24, entities = 64, corpse = true}}
for _, m in ipairs(layouts) do
  local l = type(s.listings) == 'table' and s.listings[m.corpse]
  local known, profiled = 0, 0
  if l then for _, key in pairs(l.known) do known = known + 1; if key then profiled = profiled + 1 end end end
  local manager = ptr(game + m.slot)
  local h = manager and read(manager, 88)
  local count = h and get(h, m.count, 'u32') or 0
  local arr = h and count > 0 and read(get(h, m.entities, 'u64'), math.min(count, 512) * 8)
  local tally, listed, unlisted, unreadable = {}, 0, 0, 0
  for i = 0, (arr and #arr / 8 or 0) - 1 do
    local address = get(arr, i * 8, 'u64')
    local e = read(address, 24)
    if not e then unreadable = unreadable + 1
    else
      local mod_key = l and l.known[address]
      if mod_key then listed = listed + 1 else unlisted = unlisted + 1 end
      local k = (mod_key and 'L:' or 'U:') .. hex(e:sub(1, 8))
      tally[k] = (tally[k] or 0) + 1
    end
  end
  local keys = {}
  for k, n in pairs(tally) do keys[#keys + 1] = {k, n} end
  table.sort(keys, function(a, b) return a[2] > b[2] end)
  local top = {}
  for i = 1, math.min(#keys, 10) do top[#top + 1] = keys[i][1] .. 'x' .. keys[i][2] end
  parts[#parts + 1] = fmt('%s count=%d mod_n=%s mod_known=%d mod_profiled=%d read_listed=%d read_unlisted=%d '
    .. 'unreadable=%d keys=%d [%s]', m.name, count, tostring(l and l.n), known, profiled, listed, unlisted,
    unreadable, #keys, table.concat(top, ' '))
end
return table.concat(parts, ' | ')
