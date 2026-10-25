-- Hellpod Drop Hold port, read-only live checks L1-L8 (build 26088801). Reads only, through Link's Link to Memory
-- (read/ptr/u32/f32/hashmap; nothing here writes or calls a game function). Every pointer is range-checked before
-- it is followed. Run it on the ship, then again in a mission (best: right after your own hellpod launches, and
-- once while a reinforcement pod falls). See NOTES.md for what each line should show.
local G = assert(game, 'game.dll base')
local function ok(v) return v and v >= 0x10000 and v < 0x800000000000 end
local function P(a) if not ok(a) then return nil end local v = ptr(a) return ok(v) and v or nil end
local function U32(a) local s = ok(a) and read(a, 4) return s and get(s, 0, 'u32') or nil end
local function U8(a) local s = ok(a) and read(a, 1) return s and s:byte() or nil end
local function F32(a) local s = ok(a) and read(a, 4) return s and get(s, 0, 'f32') or nil end
-- 64-bit values as two u32 halves (a Lua number cannot hold a 64-bit hash exactly)
local function U64(a) local s = ok(a) and read(a, 8) if not s then return nil end return get(s, 0, 'u32'), get(s, 4, 'u32') end
local function H64(lo, hi) return lo and fmt('0x%08X%08X', hi, lo) or 'nil' end
local function h(v) return v and fmt('0x%X', v) or 'nil' end
local function f(v) return v and fmt('%.3f', v) or 'nil' end
local function pow2(v) if not v or v < 1 then return false end while v > 1 and v % 2 == 0 do v = v / 2 end return v == 1 end
out('HDH_LIVE game.dll base', h(G), 'exe', h(exe))
do -- L0: the mod's own status table (same Lua state), when visible from here
  local okk, st = pcall(function() return rawget(_G, 'HellpodDropHold') end)
  if okk and type(st) == 'table' then out('HDH_L0 mod revision', st.revision, 'status', st.status, 'active', tostring(st.active))
  else out('HDH_L0 mod status table not visible from this eval (read HellpodDropHold.log instead)') end
end
-- L1 game state
local GS = P(G + 0x2CE1508)
out('HDH_L1 game object', h(GS), 'state +0xAC29C', U32(GS and GS + 0xAC29C), '(3 ship, 4 mission, 5/6 preparing)',
    '| old +0xAC21C reads', U32(GS and GS + 0xAC21C))
-- L2 UI presenters (UI + 0x4288 PresenterManager; block at +0x4290)
local UI = P(G + 0x2E38160)
if UI then
  local b = {}
  for i = 0, 8 do b[i] = U32(UI + 0x4290 + 4 * i) end
  out('HDH_L2 ui', h(UI), 'hud', b[0], 'menu', b[1], 'popup', b[2], 'stack', b[3], b[4], b[5], b[6], b[7], 'depth', b[8],
      '(depth 0..5; hud 2 ship / 3 mission; menu 2 = LoadingMission, 4 = LoadingTutorial)')
else out('HDH_L2 ui state null') end
-- L3 cutscene manager
local CUT = P(G + 0x2E28780)
out('HDH_L3 cutscene manager', h(CUT), 'current +0x190C', U32(CUT and CUT + 0x190C), 'queued +0x1910',
    U32(CUT and CUT + 0x1910), '(0..20; 6 ship_hellpod_launch, 15 ship_teleporter_network_join)')
-- L4 session
local S = P(G + 0x2E38228)
out('HDH_L4 session', h(S), 'client state +0x16498', U32(S and S + 0x16498), 'is_hotjoining +0x167EF',
    U8(S and S + 0x167EF), 'has_hotjoined +0x167F0', U8(S and S + 0x167F0),
    '| old +0x167E7/+0x167E8 read', U8(S and S + 0x167E7), U8(S and S + 0x167E8))
-- L5 HellpodComponent manager
local M = P(G + 0x2CE1F18)
local active, records, locals, nets
if M then
  local cap, total = U32(M + 0x24), U32(M + 0x2C)
  active = U32(M + 0x30)
  local mcap, mempty, mmul = U32(M + 0x48), U32(M + 0x4C), U32(M + 0x50)
  records, locals, nets = P(M + 0x58), P(M + 0x68), P(M + 0x70)
  out('HDH_L5 manager', h(M), 'capacity', cap, 'total', total, 'active', active, 'map', h(P(M + 0x40)), 'map capacity',
      mcap, 'pow2', tostring(pow2(mcap)), 'empty', h(mempty), 'multiplier', h(mmul))
  out('HDH_L5 arrays records', h(records), 'locals', h(locals), 'nets', h(nets),
      'header sane', tostring(cap and total and active and cap <= 4096 and total <= cap and active <= total or false))
else out('HDH_L5 manager pointer null (no world yet)') end
-- L6 pods: record (hash, id, flags), phase, height, t, and the manager's own id map
local TYPES = {{low = 0x1928D3E2, high = 0xE58163E7, name = 'initial spawn'}, {low = 0xA9D6D849, high = 0xEF9EB729, name = 'reinforce'}}
local function kind(lo, hi) for _, t in ipairs(TYPES) do if lo == t.low and hi == t.high then return t.name end end return 'other' end
if M and records and locals and nets and active then
  out('HDH_L6 pods active', active)
  for i = 0, math.min(active, 32) - 1 do
    local r = P(records + 8 * i)
    local lo, hi = U64(r)
    local id, flags = U32(r and r + 8), U32(r and r + 0x14)
    local found = id and hashmap(M + 0x40, id)
    out('HDH_L6 pod', i, 'hash', H64(lo, hi), kind(lo, hi), 'id', id, 'owned', flags and flags % 2,
        'phase', U32(nets + 20 * i), 'z', f(F32(nets + 20 * i + 12)), 't +32', f(F32(locals + 160 * i + 32)),
        'map index', found, (found == i) and 'ok' or 'MISMATCH', 'write address would be', h(locals + 160 * i + 32))
  end
end
-- L7 HellpodComponent settings: entities + 0xF145A8 -> 16 slots {u64 hash, u32 index}, records at +0x100, 0x68 each
local N = P(G + 0x2CE41B8)
local T = N and P(N + 0xF145A8)
out('HDH_L7 entities', h(N), 'settings table +0xF145A8', h(T), '| old +0xF12AE0 holds', H64(U64(N and N + 0xF12AE0)))
if T then
  for _, t in ipairs(TYPES) do
    local name = t.name
    local slot, index = t.low % 16, nil
    for _ = 1, 16 do
      local slo, shi = U64(T + slot * 16)
      if slo == t.low and shi == t.high then index = U32(T + slot * 16 + 8) break end
      if slo == 0 and shi == 0 then break end
      slot = (slot + 1) % 16
    end
    if index then
      local R = T + 0x100 + 0x68 * index
      local initial, braking = F32(R + 0x14), F32(R + 0x1C)
      out('HDH_L7', name, 'slot', slot, 'index', index, 'variant', U32(R), 'spawn height +8', f(F32(R + 8)),
          'initial +0x14', f(initial), 'braking height +0x18', f(F32(R + 0x18)), 'braking velocity +0x1C', f(braking),
          'time +0x20', f(F32(R + 0x20)), 't_hold', (initial and braking and initial > braking) and
          f((0.5 - braking) / (initial - braking)) or 'n/a')
    else out('HDH_L7', name, 'not found in the settings table') end
  end
end
-- L8 page check: the arrays the mod writes into are private read-write data (what write_batch requires)
if locals then
  local rg = region(locals)
  out('HDH_L8 locals region', rg and fmt('protect 0x%X state 0x%X type 0x%X', rg.protection or -1, rg.state or -1,
      rg.type or -1) or 'nil', '(expect protect 0x4 PAGE_READWRITE, state 0x1000 MEM_COMMIT, type 0x20000 MEM_PRIVATE)')
end
return true
