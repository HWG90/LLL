-- Sentry Aim Retention port, read-only live checks L1-L10 (build 26088801). Reads only, through Link's Link to Memory
-- (read/ptr/get/hashmap/region; nothing here writes or calls a game function; code bytes are read with read(), i.e.
-- ReadProcessMemory, which simply fails on a page the game has not decrypted yet). Every pointer is range-checked
-- before it is followed. Run it once on the ship, then in a mission with your own Gatling or Machine Gun sentry
-- deployed (best: once while it shoots, once just after its target died). See NOTES.md for the expected values.
local G, E = assert(game, 'game.dll base'), assert(exe, 'exe base')
local function ok(v) return v and v >= 0x10000 and v < 0x800000000000 end
local function P(a) if not ok(a) then return nil end local v = ptr(a) return ok(v) and v or nil end
local function U32(a) local s = ok(a) and read(a, 4) return s and get(s, 0, 'u32') or nil end
local function U8(a) local s = ok(a) and read(a, 1) return s and s:byte() or nil end
local function F32(a) local s = ok(a) and read(a, 4) return s and get(s, 0, 'f32') or nil end
local function U64(a) local s = ok(a) and read(a, 8) if not s then return nil end return get(s, 0, 'u32'), get(s, 4, 'u32') end
local function H64(lo, hi) return lo and fmt('%08x%08x', hi, lo) or 'nil' end
local function h(v) if v == nil then return 'nil' end if type(v) ~= 'number' or v < 0 or v >= 2^53 then return tostring(v) end return fmt('0x%X', v) end
local function f3(a) local x, y, z = F32(a), F32(a and a + 4), F32(a and a + 8)
  return x and fmt('(%.2f %.2f %.2f)', x, y or 0/0, z or 0/0) or 'nil' end
local BAND = (rawget(_G, 'bit') or require('bit')).band
local function hex(s) return s and (s:gsub('.', function(c) return fmt('%02x', c:byte()) end)) or 'unreadable' end
out('SAR_LIVE game.dll', h(G), 'exe', h(E))
do -- L0 the mod's own state (same Lua state), when visible
  local okk, st = pcall(function() return rawget(_G, 'SentryAimRetention') end)
  if okk and type(st) == 'table' then
    out('SAR_L0 revision', st.revision, 'status', st.status, 'active', tostring(st.active), 'holds', st.holds,
        'fire_pauses', st.fire_pauses, 'reselections', st.reselections)
  else out('SAR_L0 status table not visible from this eval (read SentryAimRetention.log)') end
end
-- L1 globals (new) and what the old offsets hold
local GL = {TM = 0x2CE1EF0, BM = 0x2CE18F0, RM = 0x2CE1F30, FM = 0x2CE1E78, CLK = 0x2CE14F8, WM = 0x2CE1EA0,
            CM = 0x2CE1810, MODE = 0x2CE1850, SCH = 0x2E38988, PW = 0x2E271F8}
local OLD = {TM = 0x3326D30, BM = 0x3326740, RM = 0x3326D70, FM = 0x3326CB8, CLK = 0x3326348, WM = 0x3326CE0,
             CM = 0x3326660, MODE = 0x33266A0, SCH = 0x347D7E0, PW = 0x346BFA0}
local V = {}
for _, k in ipairs({'TM', 'BM', 'RM', 'FM', 'CLK', 'WM', 'CM', 'MODE', 'SCH', 'PW'}) do
  V[k] = P(G + GL[k])
  out('SAR_L1', k, 'game+' .. h(GL[k]), '->', h(V[k]), '| old game+' .. h(OLD[k]), 'holds', h(ptr(G + OLD[k])))
end
-- L2 code signatures (the port's expected bytes); 'unreadable' = page not decrypted yet (the mod then refuses to bind)
local SIG = {
  {'game', 0x6C9A50, '405741574883ec283b1572567702450fb6f94c8b15878461', 'retention flag setter'},
  {'game', 0x105CF00, '4883ec288b41083b05c321de010f84d00000004c8b151650', 'vertical speed setter'},
  {'game', 0x761700, '48894c24085355565741574883ec20', 'fire mode setter'},
  {'exe', 0x1F30C0, '40534883ec204863dae8e2d5eaff488bc84c8b0041ff90e8', 'world_pose getter'},
  {'exe', 0x826D10, '33c04c8d05f7b203020f1f800000000049390cc0740cffc083f80475f3', 'world id'},
  {'exe', 0x87BC70, '488bc4f30f11582089480855535657415441554156415748', 'raycast'},
}
for _, s in ipairs(SIG) do
  local b = read((s[1] == 'game' and G or E) + s[2], #s[3] / 2)
  local got = b and hex(b)
  out('SAR_L2', s[4], s[1] .. '+' .. h(s[2]), got == s[3] and 'MATCH' or (b and ('DIFFERS ' .. got) or 'unreadable'))
end
-- L9 horizontal setter: the whole predicted body (the port's signature for it)
local HB = '4883ec288b41083b05d320de010f84d00000004c8b15264fc80133d24889742438458b4a30458b5a38440fafd8418d71ff4585c90f84a400000048895c2430498b5a2848897c2420418b7a340f1f40008bce468d041a4c23c1428b0cc33bcf741f3bc8741fffc2413bd172e4488b5c2430488b7c2420488b7424384883c428c33bc87550428b44c30483f8ff74464c8d0cc5000000008bd0498b4240498b0c01f6411401742e498b425848c1e204f30f114c0208498b42404d8b42584983c0084c03c2bae5450bcc498b0c018b4910e8bcc6e0ff488b5c2430488b7c2420488b7424384883c428c3'
do
  local b = read(G + 0x105CFF0, #HB / 2)
  local first = read(G + 0x105CFF0, 16)
  out('SAR_L9 horizontal setter game+0x105CFF0', b and (hex(b) == HB and 'MATCHES the predicted 232-byte body' or
      ('DIFFERS: ' .. hex(b))) or 'unreadable (page not decrypted yet; first 16 bytes ' .. hex(first) .. ')')
end
-- L5 mission mode record
do
  local M = V.MODE
  out('SAR_L5 mode record', h(M), 'word +8', U32(M and M + 8), 'word +0x40', U32(M and M + 0x40),
      '(mission: +8 ~= 0 and +0x40 in 1..7)')
end
-- L6 sentries: targeting entries, classified by the mod's profiles (behavior ids of build 26088801: old 213/312/308/
-- 611/207/319/323 -> 214/313/309/611/208/320/324, MAP row data.behavior_ids)
local PROFILES = {['58e31d70']= {'ef85d6cf', 'Gatling', 214}, ['76ba26bb'] = {'37cde438', 'Machine gun', 313},
  ['cfffa8a8'] = {'56070f36', 'Laser cannon', 309}, ['dc86e9c6'] = {'37079568', 'Rocket', 611},
  ['fe962858'] = {'820cc3ba', 'Flamethrower', 208}, ['3bce2d74'] = {'51a0812e', 'Mortar', 320},
  ['38092f8b'] = {'b2053a18', 'EMS mortar', 324}}
local TM, BM, RM, WM, CM, CLK = V.TM, V.BM, V.RM, V.WM, V.CM, V.CLK
local now_lo, now_hi = U64(CLK and CLK + 0x18)
out('SAR_L6 clock [root]+0x18 (us)', now_lo and fmt('%.0f', now_hi * 4294967296 + now_lo) or 'nil')
if TM then
  local cap, total, active = U32(TM + 0x134), U32(TM + 0x140), U32(TM + 0x144)
  local ep, rt, nt = P(TM + 0x168), P(TM + 0x178), P(TM + 0x180)
  out('SAR_L6 targeting cap', cap, 'total', total, 'active', active, 'entities', h(ep), 'runtime', h(rt), 'network', h(nt),
      'sane', tostring(cap and total and active and active <= total and total <= cap and cap <= 8192 or false))
  for i = 0, math.min(active or 0, 512) - 1 do
    local e = P(ep and ep + 8 * i)
    local lo, hi = U64(e)
    local key = lo and fmt('%08x', lo)
    local p = key and PROFILES[key]
    if p and fmt('%08x', hi) ~= p[1] then p = nil end
    if p then
      local id, unit, flags = U32(e + 8), U32(e + 12), U8(e + 20)
      local ti = hashmap(TM + 0x150, id)
      out('SAR_L6 sentry', i, p[2], 'type', H64(lo, hi), 'id', id, 'unit', h(unit), 'flags', flags,
          '(&3==1 own)', 'tm map', ti, ti == i and 'ok' or 'MISMATCH')
      local bi = BM and hashmap(BM + 0x40, id)
      local B = bi and P(BM + 0x60) and P(BM + 0x60) + 504 * bi
      if B then
        local dl_lo, dl_hi = U64(B + 152)
        out('SAR_L6   behavior', bi, 'id +0', U32(B), '(expect ' .. p[3] .. ')', 'node +8', U32(B + 8), 'target +24',
            U32(B + 24), 'point +28', f3(B + 28), 'source +96', U32(B + 96), 'has +120', U8(B + 120),
            'deadline +152', dl_lo and fmt('%.0f', dl_hi * 4294967296 + dl_lo) or 'nil',
            '| bm entity ptr ok', tostring(P(P(BM + 0x58) and P(BM + 0x58) + 8 * bi) == e))
      else out('SAR_L6   behavior map: no entry') end
      local ri = RM and hashmap(RM + 0x28, id)
      local C = ri and P(RM + 0x58) and P(RM + 0x58) + 16 * ri
      if C then out('SAR_L6   turret', ri, 'enabled +0', U8(C), 'horizontal +8', F32(C + 8), 'vertical +12', F32(C + 12),
                    '| rm entity ptr ok', tostring(P(P(RM + 0x40) and P(RM + 0x40) + 8 * ri) == e)) end
      if rt and nt then
        local R, N = rt + 208 * i, nt + 24 * i
        out('SAR_L6   runtime target +0', U32(R), 'raw +8', f3(R + 8), 'computed +20', f3(R + 20), 'net flags +16', U32(N + 16))
      end
      local wi = WM and hashmap(WM + 0x30, id)
      local W = wi and P(WM + 0x58) and P(WM + 0x58) + 1008 * wi
      if W then
        local count, index = U32(W + 216), U32(W + 220)
        out('SAR_L6   weapon', wi, 'fire nodes', count, 'index', index, 'node', index and U32(W + 120 + 4 * index),
            'mode', U32(P(WM + 0x60) and P(WM + 0x60) + 12 * wi), '| wm entity ptr ok',
            tostring(P(P(WM + 0x48) and P(WM + 0x48) + 8 * wi) == e))
        local ci = CM and hashmap(CM + 0x28, id)
        out('SAR_L6   trigger', ci, 'byte', ci and U8(P(CM + 0x58) and P(CM + 0x58) + ci))
      end
      -- L10 the write targets are private read-write data
      for _, t in ipairs({{'runtime raw', rt and rt + 208 * i + 8}, {'behavior deadline', B and B + 152},
                          {'turret control', C}, {'network flags', nt and nt + 24 * i + 16}}) do
        local rg = t[2] and region(t[2])
        out('SAR_L10', t[1], h(t[2]), rg and fmt('protect 0x%X state 0x%X type 0x%X', rg.protection or -1,
            rg.state or -1, rg.type or -1) or 'nil', '(expect 0x4 / 0x1000 / 0x20000)')
      end
      -- L7 pose path (exe units)
      local UT = P(E + 0x1AB76F8)
      if UT and unit then
        local index, gen = unit % 0x400000, math.floor(unit / 0x400000) % 256
        local count, gens, slots = U32(UT + 0x98), P(UT + 0xA0), P(UT + 0x88)
        local obj = slots and index < (count or 0) and P(slots + 8 * index)
        local vt = obj and P(obj)
        local m = vt and P(vt + 0xE8)
        out('SAR_L7   units', h(UT), 'count', count, 'generation', U8(gens and gens + index), '(expect ' .. gen .. ')',
            'object', h(obj), '[+8]', h(U32(obj and obj + 8)), '(expect unit)', 'nodes +0x70', U32(obj and obj + 0x70),
            'vtable+0xE8 code', m and hex(read(m, 5)) or 'nil', '(expect 488d4160c3)', 'matrices +0x88', h(P(obj and obj + 0x88)))
      end
    end
  end
else out('SAR_L6 no targeting registry (no world)') end
-- L8 physics: filter names, worlds, actor pools; one body cross-checked through its actor
do
  local PR = P(E + 0x286D338)
  local count, names = U32(PR and PR + 0xF8), P(PR and PR + 0x100)
  local found = {}
  for k = 0, math.min(count or 0, 128) - 1 do
    local w = names and U32(names + 4 * k)
    if w == 0x04A8FBF9 then found[#found + 1] = 'destructible@' .. k end
    if w == 0x12D0ABF1 then found[#found + 1] = 'flame@' .. k end
    if w == 0x393D9518 then found[#found + 1] = 'query@' .. k end
  end
  out('SAR_L8 filter properties', h(PR), 'count +0xF8', count, 'names +0x100', h(names), 'found', table.concat(found, ' '))
  for w = 0, 3 do
    local world = P(E + 0x2861D88 + 176 * w)
    local bodies = world and P(world + 0x18)
    if bodies then
      local checked = 0
      for b = 0, 1023 do
        local body = bodies + 160 * b
        local actor, owner = U32(body + 144), U32(body + 148)
        if actor and actor ~= 0 and actor ~= 0xFFFFFFFF and owner and owner ~= 0 then
          local wi, k = math.floor(actor / 0x40000000), math.floor(actor / 0x10000000) % 4
          local pool = E + 0x2411200 + 64 * (k + 10 * wi)
          local base, layout, n, mask = P(pool), U32(pool + 28), U32(pool + 36), U32(pool + 40)
          local stride, ident, off = layout and layout % 65536, layout and math.floor(layout / 65536) % 256,
            layout and math.floor(layout / 0x1000000)
          local idx = mask and BAND(actor, mask)
          local entry = base and stride and idx and idx < (n or 0) and base + idx * stride
          local rec = entry and entry + off
          out('SAR_L8 world', w, h(world), 'body', b, 'actor', h(actor), 'unit', h(owner), 'filter idx', U32(body + 108) and
              U32(body + 108) % 128, '| pool', h(pool), 'stride', stride, 'entry key', h(U32(entry and entry + ident)),
              'rec unit', h(U32(rec and rec + 12)), 'rec body', h(U32(rec and rec + 20) and U32(rec + 20) % 0x1000000),
              (U32(entry and entry + ident) == actor and U32(rec and rec + 12) == owner and
               U32(rec and rec + 20) and U32(rec + 20) % 0x1000000 == b) and 'CONSISTENT' or 'inconsistent')
          checked = checked + 1
          if checked >= 3 then break end
        end
      end
    end
  end
end
-- L6b ray job scheduler
do
  local S = V.SCH
  local idle = U32(S)
  local consumed = 0
  for i = 0, 23 do if U32(S and S + 0x40008 + 12 * i + 8) == 1 then consumed = consumed + 1 end end
  out('SAR_L6b scheduler', h(S), 'word +0', idle, 'jobs consumed (word 2 == 1)', consumed .. '/24', 'world', h(V.PW))
end
return true
