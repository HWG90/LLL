-- Sound Systems Rebalanced port, read-only live checks S0-S6 (build 26088801). Reads only, through Link's Link to
-- Memory (read/ptr/get/module/out/fmt; nothing here writes, calls a game or Wwise function, or calls set_state).
-- Every pointer is range-checked before it is followed. Run it once on the ship, once on a mission loading screen
-- and once in a mission. See NOTES.md for what each line should show.
local G = assert(game, 'game.dll base')
local function ok(v) return v and v >= 0x10000 and v < 0x800000000000 end
local function P(a) if not ok(a) then return nil end local v = ptr(a) return ok(v) and v or nil end
local function U32(a) local s = ok(a) and read(a, 4) return s and get(s, 0, 'u32') or nil end
local function h(v) return v and fmt('0x%X', v) or 'nil' end
local function hex(s) return s and (s:gsub('.', function(c) return fmt('%02x', c:byte()) end)) or 'unreadable' end
out('SSR_LIVE game.dll base', h(G), 'exe', h(exe))
do -- S0: the mod's own status table (same Lua state), when visible from here
  local okk, st = pcall(function() return rawget(_G, 'SoundSystemsRebalanced') end)
  if okk and type(st) == 'table' then out('SSR_S0 status', st.status, 'missions', st.missions, 'version', st.version)
  else out('SSR_S0 status table not visible from this eval (read SoundSystemsRebalanced.log instead)') end
end
-- S1: game state, [game.dll + 0x2CE1508] + 0xAC29C (u32; 3 ship, 6 preparing a mission, 4 mission)
local GS = P(G + 0x2CE1508)
out('SSR_S1 game object', h(GS), 'state +0xAC29C', U32(GS and GS + 0xAC29C), '(3 ship, 6 loading a mission, 4 mission)',
    '| old +0xAC21C reads', U32(GS and GS + 0xAC21C))
-- S2: the old pointer slot, for contrast (expected: not the game object)
out('SSR_S2 old slot game.dll+0x3326340 holds', h(P(G + 0x3326340)), '(expect not equal to S1 game object)')
-- S3: the engine binding the mod needs, in this Lua state (LuaJIT after the boot handoff)
do
  local st = rawget(_G, 'stingray')
  local n, names = 0, {}
  if type(st) == 'table' then
    for k, v in pairs(st) do
      n = n + 1
      local s = tostring(k):lower()
      if s:find('wwise') or s:find('audio') or s:find('sound') or s:find('music') then names[#names + 1] = tostring(k) end
    end
  end
  table.sort(names)
  local w = type(st) == 'table' and rawget(st, 'Wwise')
  out('SSR_S3 stingray', type(st), 'keys', n, '(PUC capture of build 26088801 had 117 C-function namespaces)',
      'audio-like keys', #names > 0 and table.concat(names, ',') or 'none')
  out('SSR_S3 stingray.Wwise', type(w), 'set_state', type(w) == 'table' and type(rawget(w, 'set_state')) or 'n/a',
      '| global Wwise', type(rawget(_G, 'Wwise')), 'global WwiseWorld', type(rawget(_G, 'WwiseWorld')),
      '(expect nil / n/a / nil / nil)')
end
-- S4: is the Lua API still in the Wwise plugin at all? The in-memory .rdata (decrypted once loaded) is searched for
-- the stock registration strings. Found -> the plugin still carries a Lua API (then compare with the PUC state);
-- absent -> the plugin no longer has it, so neither the engine nor the boot handoff can expose stingray.Wwise.
local okm, base, size = pcall(module, 'wwise_pluginw64_release.dll')
if okm and ok(base) then
  out('SSR_S4 wwise plugin base', h(base), 'size', h(size))
  local rdata = read(base + 0x43E000, 0x128000) -- .rdata RVA 0x43E000, virtual size 0x128000 (on-disk PE header)
  if rdata then
    local function count(s) local c, at = 0, 1 while true do local i = rdata:find('\0' .. s .. '\0', at, true) if not i then return c end c, at = c + 1, i + 1 end end
    out('SSR_S4 plugin .rdata strings: Wwise', count('Wwise'), 'set_state', count('set_state'), 'trigger_event',
        count('trigger_event'), 'set_switch', count('set_switch'), 'WwiseWorld', count('WwiseWorld'),
        '(build 25480438 plugin: 1 1 1 1 1; expect 0 0 0 0 1 if the Lua API was removed)')
  else out('SSR_S4 plugin .rdata unreadable') end
  -- S5: the port's native path, read-only (nothing is called): the export resolved from the plugin's in-memory export
  -- table, its page region, and its first 31 bytes against Mod.WWISE.prologue (the port calls only on a match).
  local function U16(a) local s = read(a, 2) return s and get(s, 0, 'u16') or nil end
  local function U32b(a) local s = read(a, 4) return s and get(s, 0, 'u32') or nil end
  local want = '?SetState@SoundEngine@AK@@YA?AW4AKRESULT@@PEBD0@Z'
  local found
  local pe = U32b(base + 0x3C)
  local dir = pe and U32b(base + pe + 24 + 112)
  if dir and dir > 0 then
    local n, functions, names, ordinals = U32b(base + dir + 24), U32b(base + dir + 28), U32b(base + dir + 32), U32b(base + dir + 36)
    for i = 0, (n or 0) - 1 do
      local np = U32b(base + names + 4 * i)
      local s = np and read(base + np, #want + 1)
      if s == want .. '\0' then found = U32b(base + functions + 4 * U16(base + ordinals + 2 * i)) break end
    end
    out('SSR_S5 export table', h(dir), 'names', n, 'SetState(const char*, const char*) RVA', h(found), '(expect 0xDA120)')
  else out('SSR_S5 export directory unreadable') end
  local rg = region(base + 0xDA120)
  out('SSR_S5 export page region', rg and fmt('protect 0x%X state 0x%X type 0x%X', rg.protection or -1, rg.state or -1,
      rg.type or -1) or 'nil', '(expect protect 0x20 PAGE_EXECUTE_READ, state 0x1000, type 0x1000000 MEM_IMAGE; '
      .. 'protect 0x1 PAGE_NOACCESS means the page is not decrypted yet: the port then refuses and logs)')
  local PROLOGUE = '\064\083\069\051\201\076\139\218\072\139\217\072\133\201\117\005\069\139\209\235\074'
      .. '\068\015\182\001\065\186\197\157\028\129'
  local live = read(base + 0xDA120, 31)
  out('SSR_S5 SetState +0xDA120 bytes', hex(live), 'match', tostring(live == PROLOGUE),
      '(match=true: the port will call it; false: it refuses; report these bytes)')
  out('SSR_S5 SetState(AkStateGroupID, AkStateID) +0xDA030', hex(read(base + 0xDA030, 24)))
else
  out('SSR_S4 module() unavailable or plugin not found:', tostring(base))
end
-- S6: the second archive (patched music_init). Its loaded copy is not located by this probe (the resource manager's
-- bank table is not mapped); check the deployed file offline against build-receipt.json second_archive (bytes 520,8xx,
-- sha256), and listen in game:
out('SSR_S6 listen: (a) join a mission in progress, or deploy from the hangar: music at the war-table level (not 6 dB',
    'louder than a war-table launch); (b) a mission on a swamp, desert, deciduous, coniferous, oasis or hive/rift world:',
    'start-intensity and drop music play instead of silence; (c) the log shows one line per mission start and no',
    '"Wwise state not set" line')
return true
