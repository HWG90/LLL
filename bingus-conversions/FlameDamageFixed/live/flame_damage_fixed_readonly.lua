-- Flame Damage Fixed port (build 26088801): read-only live checks F0-F8 through Link's Link to Memory
-- (eval env: game, exe, read, ptr, get, region, out, fmt). Nothing here writes or calls a game function: the port's
-- own lookups run against an api whose write guards always refuse (writable_* -> false, write_* -> false and
-- counted), exactly like upstream tests/live_check.lua. See NOTES.md for what each line should show.
-- Best run: once on the ship, once in a mission with a Lumberer (or your own Flame Sentry) in view, and once
-- right after one fired.
local G, X = assert(game, 'game.dll base'), assert(exe, 'exe base')
local SRC = FDF_PORT_SRC or 'Z:<workspace>/native-work/megapack-port/FlameDamageFixed/work/port/src/flame_damage_fixed.lua'
local function ok(v) return type(v) == 'number' and v >= 0x10000 and v < 0x800000000000 end
local function R(a, n) if not ok(a) then return nil end local good, s = pcall(read, a, n) return good and s or nil end
local function U32(a) local s = R(a, 4) return s and get(s, 0, 'u32') or nil end
local function P(a) local s = R(a, 8) if not s then return nil end local v = get(s, 0, 'u32') + get(s, 4, 'u32') * 4294967296 return ok(v) and v or nil end
local function h(v) return v and fmt('0x%X', v) or 'nil' end
local function H64(a) local s = R(a, 8) return s and fmt('0x%08X%08X', get(s, 4, 'u32'), get(s, 0, 'u32')) or 'nil' end
local function reg(a) if not ok(a) then return 'nil' end local good, r = pcall(region, a)
  if not good or type(r) ~= 'table' then return 'region?' end
  return fmt('protect 0x%X state 0x%X type 0x%X', r.protection or -1, r.state or -1, r.type or -1) end

-- The port's module (the same file the build assembles), loaded in test mode: it returns Fix and installs nothing.
local Fix
do
  local f = io.open(SRC, 'rb')
  if not f then out('FDF_F0 port source not found (run build.py first):', SRC) return 'no source' end
  local src = f:read('*a'); f:close()
  -- its own _G, so a running copy of the mod (FlameDamageFixedInstalled in the real _G) does not stop it loading
  local env = setmetatable({FLAME_DAMAGE_FIXED_TEST = true}, {__index = _G})
  env._G = env
  local chunk = assert(loadstring(src, '@flame_damage_fixed_port'))
  setfenv(chunk, env)
  Fix = chunk()
end
local writes = 0
local api = {
  u32 = U32,
  read = function(a, n) return R(a, n) end,
  load = function(a, n)
    local s = R(a, n)
    if not s then -- some hosts cap a single read: fall back to 4 KB pieces
      local parts = {}
      for o = 0, n - 1, 4096 do local piece = R(a + o, math.min(4096, n - o)) if not piece then return nil end parts[#parts + 1] = piece end
      s = table.concat(parts)
    end
    return setmetatable({}, {__index = function(_, k) return get(s, 4 * k, 'u32') end})
  end,
  writable_data = function() return false end, writable_region = function() return nil end,
  write_raw = function() writes = writes + 1 return false end, write_u32 = function() writes = writes + 1 return false end,
}
out('FDF_F0 game.dll', h(G), 'exe', h(X), 'port module loaded; PHYS.PARTICLE_MANAGER', h(Fix.PHYS.PARTICLE_MANAGER))

-- F1 effect: resource root -> manager -> particles type -> shared flame record (old build root reads nothing sane)
local root = P(X + 0x24099E8)
out('FDF_F1 root [exe+0x24099E8]', h(root), 'manager +0x3F8', h(P(root and root + 0x3F8)),
    'types +0x2F0', h(P(root and P(root + 0x3F8) and P(root + 0x3F8) + 0x2F0)), '| old root [exe+0x23621A8]', h(P(X + 0x23621A8)))
local data, why = Fix.resolve_effect(api, X)
out('FDF_F1 resolve_effect', h(data), why or '', '| data page', reg(data))
if data then
  local good, detail = Fix.check_effect(api, data)
  out('FDF_F1 check_effect', tostring(good), good and (detail .. ' of 18 words still at the shipped value (0 = already fixed)') or detail,
      '| first patch word +252', h(U32(data + 252)), '(0x41700000 shipped, 0x40800000 fixed)')
end
-- F2 SprayWeaponComponent manager and its tracked weapons
local M = P(G + 0x2CE1D70)
local count = M and U32(M + 0x38)
out('FDF_F2 spray manager [game+0x2CE1D70]', h(M), 'count +0x38', count, 'entities +0x60', h(P(M and M + 0x60)),
    'instances +0x70', h(P(M and M + 0x70)), '| old global reads', h(P(G + 0x3326BB0)))
if M and count and count <= 128 then
  local entities, instances = P(M + 0x60), P(M + 0x70)
  for i = 0, math.min(count, 24) - 1 do
    local e = entities and P(entities + 8 * i)
    local lo, hi = U32(e), U32(e and e + 4)
    local name = (hi == 0x0736BEE2 and lo == 0xD6328726) and 'LUMBERER ARM' or (hi == 0x820CC3BA and lo == 0xFE962858) and 'FLAME SENTRY' or ''
    out('FDF_F2 spray', i, 'type', H64(e), name, 'unit handle +0xC', h(U32(e and e + 12)),
        'state', U32(instances and instances + 0x218 * i), 'burst id +0x24', h(U32(instances and instances + 0x218 * i + 0x24)))
  end
end
-- F3 particle manager and the flame instances
local W = P(G + 0x2E271F8)
local PM = W and P(W + 0x230768)
out('FDF_F3 world [game+0x2E271F8]', h(W), 'particle manager +0x230768', h(PM), 'vtable', H64(PM),
    '| old +0x230888 holds', h(P(W and W + 0x230888)))
out('FDF_F3 manager +0x1C8 count', U32(PM and PM + 0x1C8), '+0x1CC buckets', U32(PM and PM + 0x1CC), '+0x228 mask', h(U32(PM and PM + 0x228)))
local slot = Fix.flame_slot(api, G)
local n = slot and U32(slot)
out('FDF_F3 flame slot', h(slot), 'instances', n)
if slot and n and n <= 64 then
  local recs = P(slot + 8)
  for i = 0, n - 1 do
    local rec = recs and recs + 136 * i
    local sim = P(rec and rec + 8)
    local systems, list = U32(sim and sim + 40), P(sim and sim + 48)
    out('FDF_F3 instance', i, 'id +0x10', h(U32(rec and rec + 0x10)), 'sim', h(sim), 'effect +0x20 == data',
        tostring(data ~= nil and P(sim and sim + 32) == data), 'systems', systems)
    for s = 0, math.min(systems or 0, 12) - 1 do
      local handle = U32(list + 80 * s + 52)
      local w = handle and math.floor(handle / 1073741824)
      local wrapper = w and P(X + 0x2861D70 + 176 * w)
      local tbl = wrapper and P(wrapper + 0x498)
      local arr = tbl and P(tbl + 8)
      local idx = handle and handle % 65536
      local ps, tag = arr and P(arr + 16 * idx), arr and U32(arr + 16 * idx + 8)
      out('FDF_F3   system', s, 'handle', h(handle), 'world', w, 'table', h(tbl), 'ps', h(ps), 'tag', h(tag),
          'tag ok', tostring(tag ~= nil and tag % 65536 == idx and math.floor(tag / 16777216) == math.floor(handle / 65536) % 256),
          'filter +0x1684', h(U32(ps and ps + 0x1684)), '(0xB = layer 11; 0xB + g*0x200000 while grouped)', reg(ps))
    end
  end
end
-- F4 collision filter: hknpGroupCollisionFilter vtable and layer 11's row
local F = P(X + 0x286D330)
out('FDF_F4 filter [exe+0x286D330]', h(F), 'vtable', H64(F), 'expected', fmt('0x%X', X + 0x1521958))
local filter, reason = Fix.check_filter(api, X)
out('FDF_F4 check_filter', filter and 'ok (flame row as shipped)' or reason,
    '| row 11 words', U32(F and F + 40 + 176), U32(F and F + 44 + 176), U32(F and F + 48 + 176), U32(F and F + 52 + 176))
-- F5 physics worlds and body records
for w = 0, 3 do
  local wd = P(X + 0x2861D70 + 176 * w)
  if wd then
    local bodies, cap, limit = P(wd + 0x38), U32(wd + 0x40), U32(wd + 0x50)
    out('FDF_F5 world', w, h(wd), 'vtable ok', tostring(P(wd) == X + 0x1549168), 'bodies', h(bodies), 'capacity', cap,
        'limit', limit, 'ps table +0x498', h(P(wd + 0x498)), 'bodies page', reg(bodies))
    if bodies and limit and limit > 0 then
      local live = 0
      for i = 0, math.min(limit, 64) - 1 do
        local b = bodies + 160 * i
        local flags, filt, id, unit = U32(b + 0x44), U32(b + 0x6C), U32(b + 0x70), U32(b + 0x94)
        if flags and flags % 4 ~= 0 then
          live = live + 1
          if live <= 6 then out('FDF_F5   body', i, 'flags', h(flags), 'filter', h(filt), 'layer', filt and filt % 128,
            'group', filt and math.floor(filt / 2097152), 'id low24 == index', tostring(id and id % 16777216 == i), 'unit', h(unit)) end
        end
      end
      out('FDF_F5   live bodies among the first 64:', live)
    end
  end
end
-- F6 group allocator: capacity 2048, groups 2040-2047 free
local A = P(X + 0x286D078)
local free = {}
for g = 2047, 2040, -1 do if Fix.group_free(api, X, g) then free[#free + 1] = g end end
out('FDF_F6 allocator [exe+0x286D078]', h(A), 'capacity', U32(A), '(2048) summary words', U32(A and A + 4),
    'bitmap', h(P(A and A + 8)), 'free private groups', #free > 0 and table.concat(free, ' ') or 'none')
-- F7 unit registry and the tracked weapons' families (the driver with every write refused)
local UR = P(X + 0x1AB76F8)
out('FDF_F7 unit registry [exe+0x1AB76F8]', h(UR), 'objects +0x88', h(P(UR and UR + 0x88)), 'count +0x98', U32(UR and UR + 0x98))
local fix = Fix.new(api, G, X, function(line) out('FDF_F7 log', line) end)
fix.scan()
for _ = 1, 400 do fix.step(1 / 60) end
for i, address in ipairs(fix.tracked) do
  local weapon = fix.weapons[address]
  local units = {}
  for k = 1, weapon and #weapon.family or 0 do
    local hnd = weapon.family[k]
    local u = P(P(UR + 0x88) + 8 * (hnd % 4194304))
    units[#units + 1] = fmt('%X:%s', hnd, H64(u and u + 0x358))
  end
  out('FDF_F7 tracked', i, h(address), weapon and weapon.name, 'family', weapon and #weapon.family or 0, table.concat(units, ' '),
      'own flame-hittable bodies', weapon and weapon.job_ok and weapon.job.n or 'not scanned')
end
if #fix.tracked == 0 then out('FDF_F7 tracked: none (no Lumberer or Flame Sentry in the scene)') end
-- F8 nothing was written
out('FDF_F8 writes attempted', writes, '(the driver may try and is refused; the guards never pass here)')
return 'done'
