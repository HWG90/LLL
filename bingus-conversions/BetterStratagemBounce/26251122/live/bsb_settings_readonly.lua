-- Reads only: Better Stratagem Bounce's navigation settings buffer on this build, walked the way the mod's
-- prepare() walks it (game+0x2e4a228 -> buffer; groups of LDLD headers; 400-byte records; flags at +0x170).
local function u32(s, o) local a, b, c, d = s:byte(o + 1, o + 4) return a + b * 256 + c * 65536 + d * 16777216 end
local function u64(s, o) return u32(s, o) + u32(s, o + 4) * 4294967296 end
local buffer = ptr(game + 0x2e4a228)
if not buffer then out('BSB no buffer') return 'no buffer' end
local head = read(buffer, 4)
local groups = u32(head, 0)
out(fmt('BSB buffer=%x groups=%d', buffer, groups))
local offset, records, pairs_out, bad = 4, 0, {}, 0
for g = 1, groups do
  local h = read(buffer + offset, 24)
  if not h then out('BSB group', g, 'header unreadable at', offset) bad = bad + 1 break end
  local size = u32(h, 12)
  out(fmt('BSB group %d at %d: magic=%08x one=%d type=%08x size=%d tail=%s', g, offset, u32(h, 0), u32(h, 4),
    u32(h, 8), size, hex(h:sub(17, 24))))
  local root = offset + 24
  local body = read(buffer + root, size)
  if not body then out('BSB group', g, 'body unreadable') bad = bad + 1 break end
  local items, count = u64(body, 0), u32(body, 8)
  local start = items - buffer
  out(fmt('BSB   count=%d start=%d (root+%d) end=%d finish=%d', count, start, start - root, start + count * 400,
    root + size))
  for i = 0, count - 1 do
    local r = read(buffer + start + i * 400, 400)
    if not r then bad = bad + 1 break end
    pairs_out[#pairs_out + 1] = fmt('%d:%d', u32(r, 0), r:byte(0x170 + 1))
    records = records + 1
  end
  offset = root + size
end
out(fmt('BSB total=%d records=%d', offset, records))
out('BSB flags ' .. table.concat(pairs_out, ','))
local tb = read(game + 0x31870e0, 200 * 8)
if tb then
  local used, last = 0, -1
  for k = 0, 199 do if u64(tb, k * 8) ~= 0 then used, last = used + 1, k end end
  out(fmt('BSB table used=%d last=%d', used, last))
end
return offset, records, bad
