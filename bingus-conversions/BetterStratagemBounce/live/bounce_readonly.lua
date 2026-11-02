-- Better Stratagem Bounce port (archive-v15.4.1-26088801), read-only live checks B0-B5 (build 26088801). Reads only,
-- through Link's Link to Memory (game, read, ptr, get, region, out, fmt; nothing here writes or calls a game function).
-- Every pointer is range-checked before it is followed. Run it on the ship (the settings load at boot), once BEFORE
-- the option is installed or right after a session where it refused, and again after it reports
-- navigation_settings_ready. Run it in two or more game sessions: B3 prints the 24 header bytes of all 12 groups so
-- the "tail bytes +16..+23 vary between sessions" finding (MAP.json patch.header_tail) is checked directly.
-- See NOTES.md for what each line should show.
local G = assert(game, 'game.dll base')
local BUFFER_RVA, TABLE_RVA, DATA_SIZE, GROUPS, RECORDS, OWNED_RECORDS = 0x2E4A228, 0x31870E0, 82384, 12, 153, 105
local RECORD_SIZE, FLAG_OFFSET, OWNED = 400, 0x170, 2
local VANILLA = {2, 2, 0, 0, 2, 2, 0, 2, 2, 0, 2, 2, 2, 2, 2, 2, 2, 0, 2, 3, 0, 2, 2, 2, 2, 2, 0, 2, 0, 2, 0, 2, 2, 2, 0, 1, 2, 1, 0, 2, 1, 0, 2, 2, 2, 2, 2, 2, 2, 0, 0, 2, 2, 2, 2, 2, 2, 2, 2, 0, 2, 2, 2, 0, 2, 2, 2, 0, 2, 2, 2, 3, 2, 0, 0, 2, 0, 2, 2, 2, 2, 2, 2, 2, 3, 0, 2, 3, 2, 2, 0, 2, 3, 0, 2, 1, 0, 2, 2, 2, 1, 2, 2, 2, 0, 2, 2, 2, 0, 0, 2, 3, 2, 0, 2, 2, 2, 2, 2, 2, 0, 2, 2, 2, 2, 0, 0, 0, 0, 2, 0, 2, 2, 2, 0, 0, 2, 2, 0, 2, 0, 2, 0, 2, 0, 2, 3, 2, 0, 0, 2, 0, 2}
local function ok(v) return v and v >= 0x10000 and v < 0x800000000000 end
local function P(a) if not ok(a) then return nil end local v = ptr(a) return ok(v) and v or nil end
local function U32(s, o) return get(s, o, 'u32') end
local function h(v) return v and fmt('0x%X', v) or 'nil' end
local function hex(s) local t = {} for i = 1, #s do t[i] = fmt('%02x', s:byte(i)) end return table.concat(t) end
out('BSB_LIVE game.dll base', h(G))
do -- B0: the mod's own status table (same Lua state), when visible from here
  local okk, st = pcall(function() return rawget(_G, 'BetterStratagemBounce') end)
  if okk and type(st) == 'table' then out('BSB_B0 revision', st.revision, 'active', tostring(st.active), 'status', st.status)
  else out('BSB_B0 mod status table not visible from this eval (read BetterStratagemBounce.log instead)') end
end
-- B1: settings buffer global
local B = P(G + BUFFER_RVA)
out('BSB_B1 buffer [game+0x2E4A228]', h(B), '(expected a heap address; nil means the settings are not loaded)')
if not B then return end
local src = read(B, DATA_SIZE)
if not src or #src ~= DATA_SIZE then out('BSB_B1 cannot read', DATA_SIZE, 'bytes at the buffer') return end
local rg = region(B)
out('BSB_B1 buffer region', rg and fmt('protect 0x%X state 0x%X type 0x%X', rg.protection or -1, rg.state or -1,
    rg.type or -1) or 'n/a', '(the write needs committed private read-write: protect 0x4, state 0x1000, type 0x20000)')
-- B3: groups, the 24 header bytes of each, and the walk (the game's parser checks only +0 magic, +4 version 1,
-- +8 type hash 0x30EB6399 and +0xC size; +16..+23 are what upstream checked as 1 / 0)
local count = U32(src, 0)
out('BSB_B3 group count', count, '(expected 12)')
local offset, records, tails_upstream_ok = 4, 0, 0
for g = 1, math.min(count or 0, 32) do
  if offset + 40 > DATA_SIZE then out('BSB_B3 group', g, 'out of bounds at', offset) break end
  local head = src:sub(offset + 1, offset + 24)
  local magic, version, kind, size = U32(src, offset), U32(src, offset + 4), U32(src, offset + 8), U32(src, offset + 12)
  local n = U32(src, offset + 32)
  local upstream_ok = U32(src, offset + 16) == 1 and U32(src, offset + 20) == 0
  if upstream_ok then tails_upstream_ok = tails_upstream_ok + 1 end
  out('BSB_B3 group', g, 'at', offset, 'header', hex(head), 'magic/version/type ok',
      tostring(magic == 0x444C444C and version == 1 and kind == 0x30EB6399), 'size', size, 'records', n,
      'tail +16..+23', hex(head:sub(17, 24)), 'upstream tail check', tostring(upstream_ok))
  records = records + (n or 0)
  offset = offset + 24 + (size or 0)
end
out('BSB_B3 walk end', offset, '(expected 82384 = data_size)', 'records', records, '(expected 153)',
    'groups passing the upstream +16/+20 check', tails_upstream_ok, 'of', count)
-- B2 + B4: table identities and the navigation flags byte of every kind
local T = read(G + TABLE_RVA, 154 * 8)
local identity, outside, set_owned, vanilla_owned, other_bits_differ = 0, 0, 0, 0, 0
for kind = 1, RECORDS do
  local p = get(T, kind * 8, 'u32') + get(T, kind * 8 + 4, 'u32') * 4294967296
  local off = p - B
  if off >= 0 and off + RECORD_SIZE <= DATA_SIZE then
    if U32(src, off) == kind then identity = identity + 1 end
    local flags = src:byte(off + FLAG_OFFSET + 1)
    if bit.band(VANILLA[kind], OWNED) ~= 0 then
      vanilla_owned = vanilla_owned + 1
      if bit.band(flags, OWNED) ~= 0 then set_owned = set_owned + 1 end
    end
    if bit.band(flags, 0xFD) ~= bit.band(VANILLA[kind], 0xFD) then other_bits_differ = other_bits_differ + 1 end
  else outside = outside + 1 end
end
local slot0 = get(T, 0, 'u32') + get(T, 4, 'u32') * 4294967296
out('BSB_B2 table [game+0x31870E0] kinds 1..153: identity', identity, '(expected 153)', 'outside buffer', outside,
    '(expected 0)', 'slot 0', h(slot0))
out('BSB_B4 owned bit 0x02 set in', set_owned, 'of', vanilla_owned, 'owned records (105 = vanilla / mod not applied;',
    '0 = applied)', 'records whose other flag bits differ from vanilla', other_bits_differ, '(expected 0)')
for _, kind in ipairs({1, 28, 50, 66, 145, 153}) do
  local p = get(T, kind * 8, 'u32') + get(T, kind * 8 + 4, 'u32') * 4294967296
  local off = p - B
  if off >= 0 and off + RECORD_SIZE <= DATA_SIZE then
    out('BSB_B4 kind', kind, 'record offset', off, 'flags +0x170', src:byte(off + FLAG_OFFSET + 1), 'vanilla', VANILLA[kind],
        'write address would be', h(B + off + FLAG_OFFSET))
  end
end
