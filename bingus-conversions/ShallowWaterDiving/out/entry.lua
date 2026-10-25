-- HD2-Addon: mods/cowboybingus/shallow_water_dive
local text = (function()
-- Bingus Text v1: translations and UTF-8 text layout for CowboyBingus mods.
--
-- Canonical copy: Translations/bingus_text.lua in the workspace. Every mod
-- that shows text carries a byte-identical src/bingus_text.lua. Copies share
-- translations only through the plain-data table _G.BingusTranslations, never
-- through functions, so mods built with different copies still agree:
--
--   version         1
--   serial          bumped by every change below; mods compare it to notice
--   packs           {language = 'zh-Hans', name = '...', force = false,
--                    mods = {mod_id = {key = text}}}
--   override        language of the last pack registered with force = true
--   game_language   tag of the game's Text Language setting, from game memory
--   game_code       that setting's own code (for example 'us')
--   steam_language  tag of Steam's game language (false when unknown)
--
-- Nothing here runs per frame. A mod resolves its texts when it builds its
-- UI; tr:refresh() costs one global read and two compares when nothing
-- changed. System calls: five memory reads through the mod's own reader
-- when it observes the game's language, and the Steam language query once
-- per session when that fails (both unmeasured in game).
local M = {VERSION = 1}

local byte, char, concat = string.byte, string.char, table.concat

-- The code point at byte i and the byte after it, or nil when the bytes at i
-- are not valid UTF-8 (overlong forms, surrogates and values above U+10FFFF
-- are invalid).
function M.decode(text, i)
    local c = byte(text, i)
    if not c then return nil end
    if c < 0x80 then return c, i + 1 end
    local n, value
    if c >= 0xC2 and c <= 0xDF then n, value = 1, c - 0xC0
    elseif c >= 0xE0 and c <= 0xEF then n, value = 2, c - 0xE0
    elseif c >= 0xF0 and c <= 0xF4 then n, value = 3, c - 0xF0
    else return nil end
    local lo, hi = 0x80, 0xBF
    if c == 0xE0 then lo = 0xA0 elseif c == 0xED then hi = 0x9F
    elseif c == 0xF0 then lo = 0x90 elseif c == 0xF4 then hi = 0x8F end
    for k = 1, n do
        local d = byte(text, i + k)
        if not d or d < lo or d > hi then return nil end
        value = value * 64 + (d - 0x80)
        lo, hi = 0x80, 0xBF
    end
    return value, i + n + 1
end

-- UTF-8 bytes of one code point.
function M.encode(value)
    if value < 0x80 then return char(value) end
    if value < 0x800 then return char(0xC0 + math.floor(value / 64), 0x80 + value % 64) end
    if value < 0x10000 then
        return char(0xE0 + math.floor(value / 4096), 0x80 + math.floor(value / 64) % 64, 0x80 + value % 64)
    end
    return char(0xF0 + math.floor(value / 262144), 0x80 + math.floor(value / 4096) % 64,
        0x80 + math.floor(value / 64) % 64, 0x80 + value % 64)
end

-- Text a mod may show: valid UTF-8 without control characters (a line feed
-- only where `multiline` allows it). Returns the text, or nil and the reason.
function M.check(text, multiline)
    if type(text) ~= 'string' then return nil, 'not a string' end
    local i, n = 1, #text
    while i <= n do
        local value, after = M.decode(text, i)
        if not value then return nil, 'invalid UTF-8 at byte ' .. i end
        if (value < 32 and not (multiline and value == 10)) or value == 127 or (value >= 0x80 and value < 0xA0) then
            return nil, 'control character at byte ' .. i
        end
        i = after
    end
    return text
end

-- check() that raises. Replaces the old plain-ASCII guards.
function M.display(text, multiline)
    local ok, why = M.check(text, multiline)
    if not ok then error('Unsupported display text: ' .. why, 2) end
    return text
end

-- Number of code points.
function M.length(text)
    local count, i, n = 0, 1, #text
    while i <= n do
        local _, after = M.decode(text, i)
        i, count = after or i + 1, count + 1
    end
    return count
end

-- Upper case for the scripts the game's fonts carry: ASCII, Latin-1, Latin
-- Extended-A (Polish, Czech...), Greek and Cyrillic. string.upper changes only
-- a-z, so 'Plongee' with an accent would come out half upper-cased. Other
-- characters (CJK, digits, sharp s) stay as they are.
local function upper_value(v)
    if v < 0x80 then return (v >= 0x61 and v <= 0x7A) and v - 32 or v end
    if v >= 0xE0 and v <= 0xFE and v ~= 0xF7 then return v - 32 end
    if v == 0xFF then return 0x178 end
    if v >= 0x100 and v <= 0x17F then
        if v == 0x131 then return 0x49 end
        if v == 0x17F then return 0x53 end
        if (v >= 0x139 and v <= 0x148) or (v >= 0x179 and v <= 0x17E) then
            return v % 2 == 0 and v - 1 or v
        end
        if v ~= 0x138 and v ~= 0x149 and v ~= 0x130 then return v % 2 == 1 and v - 1 or v end
        return v
    end
    if v >= 0x3B1 and v <= 0x3CB then return v == 0x3C2 and 0x3A3 or v - 32 end
    if v == 0x3AC then return 0x386 end
    if v >= 0x3AD and v <= 0x3AF then return v - 37 end
    if v == 0x3CC then return 0x38C end
    if v == 0x3CD or v == 0x3CE then return v - 63 end
    if v >= 0x430 and v <= 0x44F then return v - 32 end
    if v >= 0x450 and v <= 0x45F then return v - 80 end
    if v == 0x491 then return 0x490 end
    return v
end

function M.upper(text)
    if not text:find('[\97-\122\128-\255]') then return text end
    local parts, i, n = {}, 1, #text
    while i <= n do
        local value, after = M.decode(text, i)
        local changed = value and upper_value(value)
        if not value then after = i + 1 end
        parts[#parts + 1] = changed and changed ~= value and M.encode(changed) or text:sub(i, after - 1)
        i = after
    end
    return concat(parts)
end

-- The longest start of `text` that fits in `bytes` without cutting a
-- character: for the game's fixed-size text buffers.
function M.clip(text, bytes)
    if #text <= bytes then return text end
    local i = bytes + 1
    while i > 1 do
        local b = byte(text, i)
        if b < 0x80 or b >= 0xC0 then break end
        i = i - 1
    end
    return text:sub(1, i - 1)
end

local function set(list)
    local result = {}
    for _, value in ipairs(list) do result[value] = true end
    return result
end

-- Line breaking, a small subset of Unicode UAX #14. Never break before
-- closing punctuation, small kana or the prolonged sound mark, or after
-- opening punctuation and currency signs.
local CLOSE = set({0x21, 0x25, 0x29, 0x2C, 0x2E, 0x3A, 0x3B, 0x3F, 0x5D, 0x7D,
    0x2010, 0x2013, 0x2019, 0x201D, 0x2025, 0x2026, 0x2030, 0x2103,
    0x3001, 0x3002, 0x3005, 0x3009, 0x300B, 0x300D, 0x300F, 0x3011, 0x3015, 0x3017, 0x3019, 0x301B,
    0x301C, 0x301E, 0x301F, 0x303B,
    0x3041, 0x3043, 0x3045, 0x3047, 0x3049, 0x3063, 0x3083, 0x3085, 0x3087, 0x308E, 0x3095, 0x3096,
    0x309B, 0x309C, 0x309D, 0x309E, 0x30A0, 0x30A1, 0x30A3, 0x30A5, 0x30A7, 0x30A9, 0x30C3, 0x30E3,
    0x30E5, 0x30E7, 0x30EE, 0x30F5, 0x30F6, 0x30FB, 0x30FC, 0x30FD, 0x30FE,
    0xFF01, 0xFF05, 0xFF09, 0xFF0C, 0xFF0E, 0xFF1A, 0xFF1B, 0xFF1F, 0xFF3D, 0xFF5D, 0xFF5E, 0xFF60,
    0xFF61, 0xFF63, 0xFF64, 0xFF65})
local OPEN = set({0x24, 0x28, 0x5B, 0x7B, 0xA3, 0xA5, 0x2018, 0x201C, 0x20A9, 0x20AC,
    0x3008, 0x300A, 0x300C, 0x300E, 0x3010, 0x3014, 0x3016, 0x3018, 0x301A, 0x301D,
    0xFF04, 0xFF08, 0xFF3B, 0xFF5B, 0xFF5F, 0xFF62, 0xFFE1, 0xFFE5})
local ZWJ = 0x200D

-- Characters that belong to the one before them: combining marks, joiners,
-- variation selectors, emoji skin tones, Hangul vowel and final jamo.
local function mark(v)
    return (v >= 0x300 and v <= 0x36F) or (v >= 0x483 and v <= 0x489) or v == 0xE31
        or (v >= 0xE34 and v <= 0xE3A) or (v >= 0xE47 and v <= 0xE4E) or (v >= 0x1160 and v <= 0x11FF)
        or (v >= 0x1AB0 and v <= 0x1AFF) or (v >= 0x1DC0 and v <= 0x1DFF) or v == 0x200C or v == ZWJ
        or (v >= 0x20D0 and v <= 0x20FF) or v == 0x3099 or v == 0x309A or (v >= 0xFE00 and v <= 0xFE0F)
        or (v >= 0xFE20 and v <= 0xFE2F) or (v >= 0x1F3FB and v <= 0x1F3FF) or (v >= 0xE0100 and v <= 0xE01EF)
end

-- Scripts written without spaces between words (Chinese, Japanese) and
-- Korean syllables: a line may break before or after any of these.
local function wide(v)
    return (v >= 0x1100 and v <= 0x115F) or (v >= 0x2E80 and v <= 0xA4CF) or (v >= 0xA960 and v <= 0xA97F)
        or (v >= 0xAC00 and v <= 0xD7FF) or (v >= 0xF900 and v <= 0xFAFF) or (v >= 0xFE10 and v <= 0xFE1F)
        or (v >= 0xFE30 and v <= 0xFE4F) or (v >= 0xFF00 and v <= 0xFF60) or (v >= 0xFFE0 and v <= 0xFFE6)
        or (v >= 0x1F300 and v <= 0x1FAFF) or (v >= 0x20000 and v <= 0x3FFFD)
end

local function space(v) return v == 32 or v == 0x3000 end

-- Byte offsets where each user-perceived character starts (a code point plus
-- the marks that follow it), then #text + 1. Scrolling and forced breaks cut
-- only here, so no character is ever split.
function M.boundaries(text)
    local list, i, n, previous = {}, 1, #text, nil
    while i <= n do
        local value, after = M.decode(text, i)
        if not value then value, after = 0xFFFD, i + 1 end
        if not previous or not (mark(value) or previous == ZWJ) then list[#list + 1] = i end
        previous, i = value, after
    end
    list[#list + 1] = n + 1
    return list
end

-- Unbreakable pieces of text: {first byte, last byte, separator before it,
-- line feeds before it}.
local function pieces(text)
    local list, i, n = {}, 1, #text
    local first, last, previous, gap, feeds = nil, nil, nil, '', 0
    local function finish()
        if first then
            list[#list + 1] = {first, last, gap, feeds}
            gap, feeds = '', 0
        end
        first = nil
    end
    while i <= n do
        local value, after = M.decode(text, i)
        if not value then value, after = 0xFFFD, i + 1 end
        if value == 10 then
            finish()
            feeds, gap, previous = feeds + 1, '', nil
        elseif space(value) and not first then
            gap = gap .. text:sub(i, after - 1)
        elseif space(value) then
            finish()
            gap, previous = text:sub(i, after - 1), nil
        else
            local join = first and (mark(value) or previous == ZWJ or CLOSE[value] or OPEN[previous]
                or not (wide(value) or wide(previous)))
            if join then last = after - 1
            else
                if first then finish() end
                first, last = i, after - 1
            end
            previous = value
        end
        i = after
    end
    finish()
    return list
end

-- Splits text into lines no wider than `width`, where measure(s) is the
-- drawn width of s. Lines break at spaces, and between CJK characters except
-- before closing or after opening punctuation. A piece wider than a whole
-- line breaks between characters. Spaces at a break are dropped.
function M.wrap(text, width, measure)
    local lines, line = {}, ''
    for _, piece in ipairs(pieces(text)) do
        local value = text:sub(piece[1], piece[2])
        for _ = 1, piece[4] do
            lines[#lines + 1] = line
            line = ''
        end
        local candidate = line == '' and value or line .. piece[3] .. value
        if measure(candidate) <= width then line = candidate
        else
            if line ~= '' then lines[#lines + 1] = line end
            if measure(value) <= width then line = value
            else
                line = ''
                local edges = M.boundaries(value)
                for k = 1, #edges - 1 do
                    local glyph = value:sub(edges[k], edges[k + 1] - 1)
                    if measure(line .. glyph) <= width then line = line .. glyph
                    else
                        assert(line ~= '', 'Text column too narrow')
                        lines[#lines + 1] = line
                        line = glyph
                    end
                end
            end
        end
    end
    if line ~= '' then lines[#lines + 1] = line end
    return lines
end

-- '{name}' placeholders are replaced by values.name; unknown names stay.
function M.format(text, values)
    return (text:gsub('{([%a_][%w_]*)}', function(name)
        local value = values[name]
        if value ~= nil then return tostring(value) end
    end))
end

-- Sorted placeholder names, to compare a translation with its English text.
function M.placeholders(text)
    local names = {}
    for name in text:gmatch('{([%a_][%w_]*)}') do names[#names + 1] = name end
    table.sort(names)
    return concat(names, ',')
end

-- Pseudo-translation for layout tests: accented letters the game's Latin
-- fonts carry (Latin-1 and Polish), 40% longer and bracketed, so clipped,
-- cut or untranslated text is easy to spot. Placeholders stay intact.
local PSEUDO = {a = 0xE1, c = 0xE7, d = 0xF0, e = 0xE9, i = 0xED, l = 0x142, n = 0xF1, o = 0xF6, s = 0x15B,
    u = 0xFC, y = 0xFD, z = 0x17C, A = 0xC1, C = 0xC7, D = 0xD0, E = 0xC9, I = 0xCD, L = 0x141, N = 0xD1,
    O = 0xD6, S = 0x15A, U = 0xDC, Y = 0xDD, Z = 0x17B}
function M.pseudo(text)
    local parts, i, n = {}, 1, #text
    while i <= n do
        local name = text:match('^{[%a_][%w_]*}', i)
        if name then
            parts[#parts + 1] = name
            i = i + #name
        else
            local c = text:sub(i, i)
            parts[#parts + 1] = PSEUDO[c] and M.encode(PSEUDO[c]) or c
            i = i + 1
        end
    end
    return '[' .. concat(parts) .. ' ' .. string.rep('~', math.max(2, math.ceil(M.length(text) * 0.4))) .. ']'
end

-- The shared table (see the top of this file), created on first use. Another
-- copy, a pack add-on or a stray assignment may have left it incomplete: the
-- fields every reader needs are filled in instead of failing in every mod.
function M.registry()
    local registry = rawget(_G, 'BingusTranslations')
    if type(registry) ~= 'table' then
        registry = {}
        rawset(_G, 'BingusTranslations', registry)
    end
    if type(rawget(registry, 'version')) ~= 'number' then rawset(registry, 'version', 1) end
    if type(rawget(registry, 'serial')) ~= 'number' then rawset(registry, 'serial', 0) end
    if type(rawget(registry, 'packs')) ~= 'table' then rawset(registry, 'packs', {}) end
    return registry
end

-- A language tag a pack may carry: 'de', 'pt-BR', 'zh-Hant', 'es-419', 'pseudo'.
local function valid_tag(tag)
    return type(tag) == 'string' and #tag <= 16 and tag:match('^%a%a%a?%-?[%w%-]*$') ~= nil
end

-- Adds a translation pack. Pack add-ons do the same inline, without this file
-- (translations.py writes that code); keep the two identical. A pack forces its
-- language on every mod only with force = true (any other value does not).
function M.register(pack)
    assert(type(pack) == 'table' and valid_tag(pack.language) and type(pack.mods) == 'table',
        'A translation pack needs a language tag and a mods table')
    local registry = M.registry()
    registry.packs[#registry.packs + 1] = pack
    if pack.force == true then registry.override = pack.language end
    registry.serial = registry.serial + 1
end

-- The game's Text Language (Options menu), which can differ from Steam's.
-- Build 25480438: the settings object [game.dll+0x3326340] + 705500 (what the
-- settings save 0x102f7a0 writes) holds at +212 an index into the table of
-- 15 language records at game.dll+0x37C5650; each record has its code string
-- at +8. Unreadable or implausible values mean "unknown", never a guess.
M.GAME = {settings = 0x2CE1508, index = 705628 + 212, table = 0x3180DE0, count = 15}
-- Record codes to BCP 47 tags. Only 'us' is confirmed (English); the others
-- are the spellings the game's code tables use. An unlisted code is kept
-- as its own tag, so no translation matches it and English shows.
M.GAME_CODES = {us = 'en', en = 'en', ['en-US'] = 'en', uk = 'en-GB', gb = 'en-GB', ['en-GB'] = 'en-GB',
    de = 'de', fr = 'fr', it = 'it', es = 'es', ['es-ES'] = 'es', mx = 'es-419', ['es-MX'] = 'es-419',
    ['es-419'] = 'es-419', pl = 'pl', ru = 'ru', jp = 'ja', ja = 'ja', kr = 'ko', ko = 'ko', br = 'pt-BR',
    ['pt-BR'] = 'pt-BR', pt = 'pt', ['zh-CN'] = 'zh-Hans', cn = 'zh-Hans', zh = 'zh-Hans', zhs = 'zh-Hans',
    ['zh-TW'] = 'zh-Hant', tw = 'zh-Hant', zht = 'zh-Hant', cz = 'cs', cs = 'cs', gr = 'el', el = 'el',
    nl = 'nl', tr = 'tr', ua = 'uk'}

local function number(bytes)
    local value = 0
    for k = #bytes, 1, -1 do value = value * 256 + byte(bytes, k) end
    return value
end

-- The code of the game's Text Language, read through the mod's own
-- read(address, size) (a ReadProcessMemory wrapper: bad addresses fail, never
-- crash), which receives addresses as Lua numbers. `game` is game.dll's base
-- address, a number or a pointer. Five reads.
function M.game_code(read, game)
    if type(game) == 'cdata' then
        local ok, value = pcall(function() return tonumber(require('ffi').cast('uintptr_t', game)) end)
        game = ok and value or nil
    end
    if type(game) ~= 'number' then return nil end
    local function load(address, size)
        local ok, bytes = pcall(read, address, size)
        if ok and type(bytes) == 'string' and #bytes == size then return bytes end
    end
    local function pointer(address)
        local bytes = load(address, 8)
        local value = bytes and number(bytes)
        if value and value >= 65536 and value < 2 ^ 47 then return value end
    end
    local g = M.GAME
    local settings = pointer(game + g.settings)
    local index = settings and load(settings + g.index, 4)
    index = index and number(index)
    if not index or index >= g.count then return nil end
    local record = pointer(game + g.table + 8 * index)
    local text = record and pointer(record + 8)
    local bytes = text and (load(text, 16) or load(text, 8))
    local code = bytes and bytes:match('^(%a[%a%-]*)%z')
    if code and #code <= 12 then return code end
end

-- Records the game's Text Language for every mod. A mod that can read game
-- memory calls this at start, and again when it sees the native font change.
-- Returns the tag and the game's code, or nil when the setting is unreadable.
function M.observe(read, game)
    local code = M.game_code(read, game)
    if not code then return nil end
    local tag = M.GAME_CODES[code] or code
    local registry = M.registry()
    if registry.game_language ~= tag then
        registry.game_language, registry.game_code = tag, code
        registry.serial = registry.serial + 1
    end
    return tag, code
end

-- Steam language names (ISteamApps::GetCurrentGameLanguage), as the game's
-- own Localization module reads them, to BCP 47 tags.
M.STEAM = {english = 'en', schinese = 'zh-Hans', tchinese = 'zh-Hant', koreana = 'ko', japanese = 'ja',
    russian = 'ru', polish = 'pl', french = 'fr', german = 'de', italian = 'it', spanish = 'es',
    latam = 'es-419', brazilian = 'pt-BR', portuguese = 'pt', ukrainian = 'uk', czech = 'cs', dutch = 'nl',
    turkish = 'tr', thai = 'th', vietnamese = 'vi', danish = 'da', finnish = 'fi', norwegian = 'no',
    swedish = 'sv', hungarian = 'hu', romanian = 'ro', bulgarian = 'bg', greek = 'el', arabic = 'ar',
    indonesian = 'id'}

-- Steam's current game language, which the game starts from until the player
-- picks a Text Language. Made once per session and only when the game's own
-- setting is unreadable: two lookups in steam_api64.dll, which the game has
-- already loaded (nothing is loaded), and two calls into it.
function M.steam_language()
    local ok, name = pcall(function()
        local ffi = require('ffi')
        -- Declared once per process, whichever copy of this file comes first,
        -- under this file's own names (asm labels): no mod's declaration of
        -- the same Windows functions can clash with these.
        if not pcall(ffi.typeof, 'bingus_steam_apps_fn') then
            ffi.cdef[[
                typedef void *(*bingus_steam_apps_fn)(void);
                typedef const char *(*bingus_steam_language_fn)(void *apps);
                void *bingus_text_module(const char *name) __asm__("GetModuleHandleA");
                void *bingus_text_export(void *module, const char *name) __asm__("GetProcAddress");
            ]]
        end
        local steam = ffi.C.bingus_text_module('steam_api64.dll')
        if steam == nil then return nil end
        local apps_fn = ffi.C.bingus_text_export(steam, 'SteamAPI_SteamApps_v008')
        local language_fn = ffi.C.bingus_text_export(steam, 'SteamAPI_ISteamApps_GetCurrentGameLanguage')
        if apps_fn == nil or language_fn == nil then return nil end
        local apps = ffi.cast('bingus_steam_apps_fn', apps_fn)()
        if apps == nil then return nil end
        local value = ffi.cast('bingus_steam_language_fn', language_fn)(apps)
        return value ~= nil and ffi.string(value) or nil
    end)
    return ok and name or nil
end

-- The game's language: its Text Language setting when a mod observed it,
-- else Steam's game language.
function M.game_language()
    local registry = M.registry()
    if registry.game_language then return registry.game_language end
    if registry.steam_language == nil then
        local name = M.steam_language()
        registry.steam_language = name and (M.STEAM[name] or name) or false
    end
    return registry.steam_language or nil
end

-- The language mods show: a forced pack's, else the game's, else English.
-- Forcing is global: every mod on Bingus Text shows the forced language.
function M.language()
    local override = M.registry().override
    if valid_tag(override) then return override end
    return M.game_language() or 'en'
end

-- Tags tried for a language, least specific first: 'zh-Hant' tries 'zh',
-- then 'zh-Hant'. Keys missing from both show in English.
local function chain(language)
    local base = language:match('^([^-]+)-')
    return base and {base, language} or {language}
end

local translator = {}
translator.__index = translator
translator.__call = function(self, key, values) return self:text(key, values) end

-- A translator for one mod. `english` is the mod's locales/en.lua table:
-- {mod = 'mod_id', language = 'en', strings = {key = text},
-- limits = {key = characters}, multiline = {key = true}}; `bundled` maps
-- language tags to the other locale files shipped in the mod; log(message)
-- receives rejected entries and one summary line per language.
function M.new(english, bundled, log)
    assert(type(english) == 'table' and type(english.strings) == 'table', 'English texts required')
    local mod = english.mod
    assert(type(mod) == 'string' and mod:match('^[%l%d_]+$'), 'Invalid mod id')
    local limits, multiline = english.limits or {}, english.multiline or {}
    for key, text in pairs(english.strings) do
        assert(type(key) == 'string' and key:match('^[%w_.%-]+$'), 'Invalid text key')
        assert(M.check(text, multiline[key]), 'Invalid English text: ' .. key)
        assert(not limits[key] or M.length(text) <= limits[key], 'English text over its limit: ' .. key)
    end
    return setmetatable({mod = mod, english = english.strings, limits = limits, multiline = multiline,
        bundled = bundled or {}, log = log, logged = {}}, translator)
end

function translator:warn(message)
    if self.log and not self.logged[message] then
        self.logged[message] = true
        self.log(message)
    end
end

-- Copies the valid entries of one source over `texts` and marks them in
-- `translated`. Invalid entries keep the text they would have replaced.
function translator:merge(texts, translated, source, origin)
    if type(source) ~= 'table' then return end
    for key, text in pairs(source) do
        local english = self.english[key]
        local ok, why = english ~= nil, 'unknown key'
        if ok then ok, why = M.check(text, self.multiline[key]) end
        if ok and M.placeholders(text) ~= M.placeholders(english) then ok, why = nil, 'placeholders differ from English' end
        if ok and self.limits[key] and M.length(text) > self.limits[key] then
            ok, why = nil, 'longer than ' .. self.limits[key] .. ' characters'
        end
        if ok then
            texts[key], translated[key] = text, true
        else
            self:warn('translation ' .. origin .. ': ' .. tostring(key) .. ': ' .. why)
        end
    end
end

function translator:resolve(language, registry)
    local texts = {}
    for key, text in pairs(self.english) do texts[key] = text end
    if language == 'pseudo' then
        for key, text in pairs(texts) do texts[key] = M.pseudo(text) end
    elseif language ~= 'en' then
        local translated = {}
        for _, tag in ipairs(chain(language)) do
            local bundled = self.bundled[tag]
            self:merge(texts, translated, bundled and bundled.strings, tag .. ' (bundled)')
            for _, pack in ipairs(registry.packs) do
                -- A malformed entry (another copy's or add-on's) is skipped, never indexed blindly.
                if type(pack) == 'table' and pack.language == tag and type(pack.mods) == 'table' then
                    self:merge(texts, translated, pack.mods[self.mod], tag .. ' (' .. tostring(pack.name) .. ')')
                end
            end
        end
        local count, total = 0, 0
        for key in pairs(self.english) do
            total = total + 1
            if translated[key] then count = count + 1 end
        end
        self:warn('language ' .. language .. ': ' .. count .. ' of ' .. total .. ' texts translated')
    end
    self.texts, self.language, self.serial = texts, language, registry.serial
    self.generation = (self.generation or 0) + 1
end

-- Resolves again when the language or the installed packs changed. Returns
-- true when it did. Every lookup does this too (a menu host may call a mod's
-- text function at any time), so a mod that caches what it drew compares
-- tr.generation, which grows with every resolution, not this return value.
function translator:refresh()
    local registry = M.registry()
    local language = M.language()
    if self.texts and self.serial == registry.serial and self.language == language then return false end
    self:resolve(language, registry)
    return true
end

-- The text for `key` in the current language, placeholders filled from
-- `values`.
function translator:text(key, values)
    self:refresh()
    local text = self.texts[key]
    if text == nil then error('Unknown text key: ' .. tostring(key), 2) end
    return values and M.format(text, values) or text
end

-- Keep this rarely run code interpreted: it must not add traces to the
-- game's shared LuaJIT code cache.
if jit and jit.off then
    for _, fn in ipairs({M.decode, M.encode, M.check, M.display, M.length, upper_value, M.upper, M.clip, mark,
                         wide, space, M.boundaries, pieces, M.wrap, M.format, M.placeholders, M.pseudo,
                         M.registry, valid_tag, M.register, number, M.game_code, M.observe, M.steam_language,
                         M.game_language, M.language, chain, M.new, translator.warn, translator.merge,
                         translator.resolve, translator.refresh, translator.text}) do
        jit.off(fn, true)
    end
end

return M

end)()
local runtime = (function()
-- bingus_runtime.lua, version 1: the core of Bingus Shared Runtime.
-- Canonical copy: github.com/CowboyBingus/BingusSharedRuntime, runtime/bingus_runtime.lua.
--
-- Helldivers 2 runs the game and every Lua mod in one LuaJIT state, with one
-- global update chain. This file gives a mod the update guard every mod used
-- to write by hand, and the session table all runtime copies share. It uses no
-- FFI and no system function.
--
-- Loading: each runtime file is one chunk that returns a table and installs
-- nothing until the mod asks. A mod vendors byte-identical copies of the files
-- it needs and runs each once when it loads:
--   local runtime = <bingus_runtime.lua>              -- this file: shared(), guard()
--   local memory = <bingus_memory.lua>.new(runtime)   -- reads, page checks, module hashes, time()
--   <bingus_write.lua>.extend(memory)                 -- checked writes, added to memory
-- A mod that never touches memory vendors this file alone; one that only reads
-- vendors this file and bingus_memory.lua.
--
-- Copies of different versions can run in the same game. Their session state
-- lives in one global table, BingusRuntime = {hashes, statuses, versions,
-- hash_reads}, which every copy of every version shares.
--
-- runtime.shared([globals]) -> BingusRuntime, created or repaired.
-- runtime.guard(options) -> guard: the update and shutdown wrappers. The
-- previous update runs outside pcall, so its errors reach the game unchanged
-- (P1); the first failure survives shutdown as "stopped after: <reason>" (P2);
-- 8 errors stop the mod, counted per burst so rare transient errors never add
-- up (P3); a mod that can restore its state pauses after an error below it and
-- resumes when the updates below run cleanly again; every argument and return
-- value passes through; a status table per mod lands in BingusRuntime.statuses.
--
-- Per-frame cost of a guard: the mod's step under pcall, a few boolean tests
-- and stores and two integer counters around the previous update; no
-- allocation, closure or system call. Unmeasured in game.
local runtime = {VERSION = 1}

local type, pcall, error, tostring, rawget, rawset, ipairs = type, pcall, error, tostring, rawget, rawset, ipairs

-- Session state shared by every copy of every version ----------------------------

local SHARED = 'BingusRuntime'
local SHARED_TABLES = {'hashes', 'statuses', 'versions'}

-- Another copy, another version or another mod may have left the table
-- incomplete (even `BingusRuntime = {}`): missing or broken fields are filled in,
-- so one stray assignment cannot stop every mod on the runtime.
function runtime.shared(globals)
    globals = globals or _G
    local shared = rawget(globals, SHARED)
    if type(shared) ~= 'table' then
        shared = {}
        rawset(globals, SHARED, shared)
    end
    for _, field in ipairs(SHARED_TABLES) do
        if type(rawget(shared, field)) ~= 'table' then rawset(shared, field, {}) end
    end
    if type(rawget(shared, 'hash_reads')) ~= 'number' then rawset(shared, 'hash_reads', 0) end
    rawset(rawget(shared, 'versions'), runtime.VERSION, true)
    return shared
end

-- Update guard -----------------------------------------------------------------------

-- options:
--   name    key in BingusRuntime.statuses (required, one guard per name)
--   step    function(dt, ...) before the previous update, every frame while running
--   after   function() after the previous update returned, while running
--   stop    function(reason) once, when the guard stops or the game shuts down;
--           its errors are kept in status.stop_error, never raised
--   pause   function(reason), optional: an update below this mod raised; restore
--           the game state and reset the mod to a fresh start. With it the guard
--           pauses (no step, no after) and resumes once the updates below have
--           returned on `resume` frames in a row (default 60). Without it such an
--           error stops the guard. A pause that raises stops the guard.
--   log     function(line) for the guard's few lines (errors, pauses, resumes, stop)
--   errors  errors that stop the guard (default 8), counted separately for the
--           mod's own step and after and for the updates below it. A count starts
--           again after `clean` frames without such an error (default 3600, about a
--           minute at 60 FPS), so rare transient errors never add up to a stop.
--   env     the table holding update and shutdown (default _G)
-- guard.install() wraps env.update and env.shutdown and returns the guard.
-- guard.stop(reason) stops it from the mod (a refusal counts as the first failure).
-- guard.running() is true from install until a stop or shutdown.
-- guard.status: {name, version, state, installed, errors, lower_errors, pauses,
--   first_error, burst_error, first_failure, stop_error}; state is 'new', 'running',
--   'paused: <reason>', 'stopped: <reason>', then at shutdown 'stopped' or
--   'stopped after: <first failure>'.
function runtime.guard(options)
    local name = options.name
    if type(name) ~= 'string' or name == '' then error('guard name required', 0) end
    local shared = runtime.shared(options.env)
    if shared.statuses[name] and shared.statuses[name].installed then error('guard ' .. name .. ' already installed', 0) end
    local status = {name = name, version = runtime.VERSION, state = 'new', installed = false, errors = 0,
        lower_errors = 0, pauses = 0}
    shared.statuses[name] = status
    local step, after_step, stop_work, pause_work, log = options.step, options.after, options.stop, options.pause,
        options.log
    local limit, resume_after, clean_after = options.errors or 8, options.resume or 60, options.clean or 3600
    local previous_update, previous_shutdown
    local in_previous, stopped, paused, failed = false, false, false, false
    local clean_run, lower_run = 0, 0

    local function note(line)
        if log then pcall(log, line) end
    end

    local function halt(reason)
        if stopped then return end
        stopped, paused = true, false
        status.first_failure = status.first_failure or reason
        status.state = 'stopped: ' .. reason
        note(name .. ' stopped: ' .. reason)
        if stop_work then
            local ok, why = pcall(stop_work, reason)
            if not ok then status.stop_error = tostring(why) end
        end
    end

    -- The mod's own step or after raised: one log line per burst of errors.
    local function failed_step(problem)
        failed, clean_run = true, 0
        status.errors = status.errors + 1
        local text = tostring(problem)
        status.first_error = status.first_error or text
        if status.errors == 1 then
            status.burst_error = text
            note(name .. ' error: ' .. text)
        end
        if status.errors >= limit then halt('stopped after ' .. limit .. ' errors: ' .. status.burst_error) end
    end

    -- An update below this mod raised (seen on the next frame).
    local function failed_below()
        lower_run = 0
        status.lower_errors = status.lower_errors + 1
        if not pause_work then return halt('the previous update failed') end
        if status.lower_errors >= limit then
            return halt('stopped after ' .. limit .. ' failed updates below this mod')
        end
        if paused then return end
        paused = true
        status.pauses = status.pauses + 1
        status.state = 'paused: the previous update failed'
        note(name .. ' paused: the previous update failed')
        local ok, why = pcall(pause_work, 'the previous update failed')
        if not ok then halt('pause failed: ' .. tostring(why)) end
    end

    local function resume_when_clean()
        if paused and lower_run >= resume_after then
            paused = false
            status.state = 'running'
            note(name .. ' resumed after ' .. resume_after .. ' clean frames')
        end
    end

    -- Counts a frame without an own error, which also clears an old burst.
    local function count_clean()
        if failed then return end
        clean_run = clean_run + 1
        if clean_run == clean_after then status.errors = 0 end
    end

    local function finish(...)
        in_previous = false
        lower_run = lower_run + 1
        if lower_run == clean_after then status.lower_errors = 0 end
        if not stopped and not paused then
            if after_step then
                local ok, problem = pcall(after_step)
                if not ok then failed_step(problem) end
            end
            count_clean()
        end
        return ...
    end

    -- The previous update runs outside pcall: its errors (value and traceback)
    -- reach the game unchanged. One that raised leaves in_previous set, and the
    -- next frame pauses (or stops) this mod and keeps forwarding.
    local function update(...)
        failed = false
        if in_previous then
            in_previous = false
            if not stopped then failed_below() end
        end
        resume_when_clean()
        if step and not stopped and not paused then
            local ok, problem = pcall(step, ...)
            if not ok then failed_step(problem) end
        end
        in_previous = true
        return finish(previous_update(...))
    end

    local function shutdown(...)
        if in_previous then
            in_previous = false
            status.first_failure = status.first_failure or 'the previous update failed'
        end
        local failure = status.first_failure
        if not stopped then
            stopped = true
            if stop_work then
                local ok, why = pcall(stop_work, 'shutdown')
                if not ok then status.stop_error = tostring(why) end
            end
        end
        status.state = failure and ('stopped after: ' .. failure) or 'stopped'
        if previous_shutdown then return previous_shutdown(...) end
    end

    local guard = {status = status}

    function guard.install()
        local env = options.env or _G
        if status.installed then error('guard ' .. name .. ' already installed', 0) end
        previous_update = rawget(env, 'update')
        if type(previous_update) ~= 'function' then error('game update unavailable', 0) end
        previous_shutdown = rawget(env, 'shutdown')
        rawset(env, 'update', update)
        rawset(env, 'shutdown', shutdown)
        status.installed, status.state = true, 'running'
        return guard
    end

    function guard.stop(reason)
        halt(tostring(reason))
    end

    function guard.running()
        return status.installed and not stopped
    end

    return guard
end

return runtime

end)()
local runtime_memory = (function()
-- bingus_memory.lua, version 1: the read side of Bingus Shared Runtime.
-- Canonical copy: github.com/CowboyBingus/BingusSharedRuntime, runtime/bingus_memory.lua.
--
-- Loading: the chunk returns {VERSION = 1, new = function(runtime)} and
-- installs nothing. A mod vendors a byte-identical copy next to
-- bingus_runtime.lua and runs each file once when it loads:
--   local runtime = <bingus_runtime.lua>
--   local memory = <bingus_memory.lua>.new(runtime)   -- the api below
--   <bingus_write.lua>.extend(memory)                 -- optional: checked writes
-- This file only reads memory, page information and module files; it never
-- changes memory or page protection. A mod whose build refuses sources that can
-- modify memory vendors bingus_runtime.lua and this file only.
--
-- Windows functions are declared under private, versioned FFI names
-- (bingus_memory1_*, each with an __asm__ label naming the real export), at
-- most once per version in the whole game. ffi.cdef keeps the first prototype
-- of a name for the whole game, so a plain name would bind to whatever another
-- mod declared first. Copies of other versions declare their own names.
--
-- memory.new(runtime) -> api. runtime is the table bingus_runtime.lua returns:
-- its shared table keeps module hashes for the session. Each api has its own
-- buffers and counters; every api of one copy shares the bound functions.
--   api.read(address, size)        the bytes as a string, or nil when they cannot
--                                  all be read; allocates only that string
--   api.read_into(address, size, buffer)  into a buffer the caller keeps: true or
--                                  false, no allocation
--   api.pointer(bytes [, offset])  the user-mode pointer stored little-endian at
--                                  bytes[offset+1 .. offset+8], as uint8_t *, or nil
--   api.address(pointer)           a pointer, number or integer cdata as a Lua number
--   api.distance(a, b)             api.address(a) - api.address(b)
--   api.writable_data(address, size)  true when [address, address + size) is
--                                  committed private read-write memory: never code,
--                                  read-only, guard or module image pages
--   api.queries                    page queries made so far (one per memory region)
--   api.time()                     seconds from the performance counter (a Lua number)
--   api.module([name])             a loaded module's base as uint8_t *, or nil;
--                                  no name: the executable
--   api.module_hash(module)        SHA-256 (uppercase hex) of the module's file, read
--                                  once per session for every mod (BingusRuntime.hashes)
--   api.verify_build(build)        build = {exe_sha256, game_sha256}: true, or false and why
--   api.windows                    {ffi, kernel32, bcrypt}: the bound functions under
--                                  their Windows names, for calls the api does not cover
-- Addresses are pointer cdata (read, read_into) or pointers, numbers and integer
-- cdata (address, distance, writable_data).
--
-- Cost per call: read and read_into one ReadProcessMemory (about 1-2 us in game);
-- writable_data one VirtualQuery per memory region in the range (about 0.29 ms
-- each in game), so check only on frames that act; time() one
-- QueryPerformanceCounter (unmeasured in game). read_into, address, distance,
-- writable_data and time allocate nothing, interpreted or compiled.
local memory = {VERSION = 1}

local type, error, pcall, tonumber, ipairs, pairs = type, error, pcall, tonumber, ipairs, pairs
local max, format, concat = math.max, string.format, table.concat

local HIGH = 4294967296
local MEM_COMMIT, MEM_PRIVATE, PAGE_READWRITE = 0x1000, 0x20000, 4

-- Windows functions ----------------------------------------------------------------

-- The region record is MEMORY_BASIC_INFORMATION with each 64-bit field read as
-- two 32-bit halves, and the cell turns a pointer into two halves through one
-- union (one base, so compiled code sees the store): neither allocates when read.
-- The region record is also this file's sentinel: once it exists, every
-- declaration below exists too.
local PREFIX = 'bingus_memory1_'
local SENTINEL = 'bingus_memory1_region'
local DECLARATIONS = [[
    typedef struct bingus_memory1_region {
        uint32_t base_low, base_high, allocation_base_low, allocation_base_high;
        uint32_t allocation_protection; uint16_t partition, reserved;
        uint32_t size_low, size_high, state, protection, type, padding;
    } bingus_memory1_region;
    typedef union bingus_memory1_cell {
        const void *pointer;
        struct { uint32_t low, high; };
    } bingus_memory1_cell;
    void *bingus_memory1_GetModuleHandleA(const char *name) __asm__("GetModuleHandleA");
    uint32_t bingus_memory1_GetModuleFileNameW(void *module, uint16_t *path, uint32_t capacity) __asm__("GetModuleFileNameW");
    void *bingus_memory1_GetCurrentProcess(void) __asm__("GetCurrentProcess");
    int bingus_memory1_ReadProcessMemory(void *process, const void *address, void *buffer, size_t size,
                                         size_t *done) __asm__("ReadProcessMemory");
    uint32_t bingus_memory1_VirtualQuery(uint64_t address, bingus_memory1_region *region, size_t size) __asm__("VirtualQuery");
    int bingus_memory1_QueryPerformanceCounter(uint32_t *count) __asm__("QueryPerformanceCounter");
    int bingus_memory1_QueryPerformanceFrequency(uint32_t *frequency) __asm__("QueryPerformanceFrequency");
    void *bingus_memory1_CreateFileW(const uint16_t *path, uint32_t access, uint32_t share, void *security,
                                     uint32_t disposition, uint32_t flags, void *template_file) __asm__("CreateFileW");
    int bingus_memory1_ReadFile(void *file, void *buffer, uint32_t size, uint32_t *done, void *overlapped) __asm__("ReadFile");
    int bingus_memory1_CloseHandle(void *handle) __asm__("CloseHandle");
    int32_t bingus_memory1_BCryptOpenAlgorithmProvider(void **algorithm, const uint16_t *name, const uint16_t *provider,
                                                       uint32_t flags) __asm__("BCryptOpenAlgorithmProvider");
    int32_t bingus_memory1_BCryptCloseAlgorithmProvider(void *algorithm, uint32_t flags) __asm__("BCryptCloseAlgorithmProvider");
    int32_t bingus_memory1_BCryptCreateHash(void *algorithm, void **hash, void *object, uint32_t object_size,
                                            const void *secret, uint32_t secret_size, uint32_t flags) __asm__("BCryptCreateHash");
    int32_t bingus_memory1_BCryptHashData(void *hash, const void *data, uint32_t size, uint32_t flags) __asm__("BCryptHashData");
    int32_t bingus_memory1_BCryptFinishHash(void *hash, void *digest, uint32_t size, uint32_t flags) __asm__("BCryptFinishHash");
    int32_t bingus_memory1_BCryptDestroyHash(void *hash) __asm__("BCryptDestroyHash");
]]
local FUNCTIONS = {
    kernel32 = {'GetModuleHandleA', 'GetModuleFileNameW', 'GetCurrentProcess', 'ReadProcessMemory', 'VirtualQuery',
                'QueryPerformanceCounter', 'QueryPerformanceFrequency', 'CreateFileW', 'ReadFile', 'CloseHandle'},
    bcrypt = {'BCryptOpenAlgorithmProvider', 'BCryptCloseAlgorithmProvider', 'BCryptCreateHash',
              'BCryptHashData', 'BCryptFinishHash', 'BCryptDestroyHash'},
}

local bound, ticks_per_second
-- {ffi, kernel32, bcrypt}, each library table holding the functions above under
-- their Windows names. Declared at most once per version in the whole game.
local function bind()
    if bound then return bound end
    local ffi = require('ffi')
    if not ffi.abi('64bit') then error('Windows x64 is required', 0) end
    if not pcall(ffi.typeof, SENTINEL) then ffi.cdef(DECLARATIONS) end
    local result = {ffi = ffi}
    for library, names in pairs(FUNCTIONS) do
        local loaded, functions = ffi.load(library), {}
        for _, name in ipairs(names) do functions[name] = loaded[PREFIX .. name] end
        result[library] = functions
    end
    local frequency = ffi.new('uint32_t[2]')
    if result.kernel32.QueryPerformanceFrequency(frequency) == 0 then error('performance counter unavailable', 0) end
    ticks_per_second = frequency[0] + frequency[1] * HIGH
    bound = result
    return bound
end

-- Module files ---------------------------------------------------------------------

-- SHA-256 (uppercase hex) of the file at path (a UTF-16 string buffer).
local function sha256(windows, path)
    local ffi, kernel, bcrypt = windows.ffi, windows.kernel32, windows.bcrypt
    local file = kernel.CreateFileW(path, 0x80000000, 7, nil, 3, 0x08000000, nil)
    if file == ffi.cast('void *', -1) then error('cannot read the module file', 0) end
    local algorithm, hash = ffi.new('void *[1]'), ffi.new('void *[1]')
    local ok, result = pcall(function()
        local id = ffi.new('uint16_t[7]', {83, 72, 65, 50, 53, 54, 0})  -- "SHA256"
        if bcrypt.BCryptOpenAlgorithmProvider(algorithm, id, nil, 0) ~= 0 then error('SHA-256 unavailable', 0) end
        if bcrypt.BCryptCreateHash(algorithm[0], hash, nil, 0, nil, 0, 0) ~= 0 then
            error('SHA-256 unavailable', 0)
        end
        local buffer, count = ffi.new('uint8_t[1048576]'), ffi.new('uint32_t[1]')
        while true do
            if kernel.ReadFile(file, buffer, 1048576, count, nil) == 0 then error('module file read failed', 0) end
            if count[0] == 0 then break end
            if bcrypt.BCryptHashData(hash[0], buffer, count[0], 0) ~= 0 then error('SHA-256 failed', 0) end
        end
        local digest, hex = ffi.new('uint8_t[32]'), {}
        if bcrypt.BCryptFinishHash(hash[0], digest, 32, 0) ~= 0 then error('SHA-256 failed', 0) end
        for i = 0, 31 do hex[i + 1] = format('%02X', digest[i]) end
        return concat(hex)
    end)
    if hash[0] ~= nil then bcrypt.BCryptDestroyHash(hash[0]) end
    if algorithm[0] ~= nil then bcrypt.BCryptCloseAlgorithmProvider(algorithm[0], 0) end
    kernel.CloseHandle(file)
    if not ok then error(result, 0) end
    return result
end

-- The SHA-256 of a loaded module's file, read once per session for every mod:
-- kept in the shared table by file path.
local function module_hash(runtime, windows, module)
    local ffi = windows.ffi
    local path = ffi.new('uint16_t[32768]')
    local length = windows.kernel32.GetModuleFileNameW(module, path, 32768)
    if length == 0 or length >= 32768 then error('module file name unavailable', 0) end
    local shared = runtime.shared()
    local key = 'sha256:' .. ffi.string(path, length * 2)
    local cached = shared.hashes[key]
    if cached then return cached end
    local hex = sha256(windows, path)
    shared.hash_reads = shared.hash_reads + 1
    shared.hashes[key] = hex
    return hex
end

-- The api --------------------------------------------------------------------------

function memory.new(runtime)
    if type(runtime) ~= 'table' or type(runtime.shared) ~= 'function' then
        error('bingus_memory.lua: new(runtime) needs the table bingus_runtime.lua returns', 2)
    end
    runtime.shared()
    local windows = bind()
    local ffi, kernel = windows.ffi, windows.kernel32
    local read_memory, query, query_counter = kernel.ReadProcessMemory, kernel.VirtualQuery,
        kernel.QueryPerformanceCounter
    local process = kernel.GetCurrentProcess()
    -- ReadProcessMemory reports its count as a 64-bit size: it is read back as two
    -- 32-bit words, because reading the 64-bit value boxes a new cdata in
    -- interpreted code. Only the call writes this buffer.
    local done = ffi.new('size_t[1]')
    local done32 = ffi.cast('uint32_t *', done)
    local region, region_size = ffi.new(SENTINEL), ffi.sizeof(SENTINEL)
    local cell, counter = ffi.new('bingus_memory1_cell'), ffi.new('uint32_t[2]')
    local scratch_size = 256
    local scratch = ffi.new('uint8_t[?]', scratch_size)
    local ticks = ticks_per_second
    local api = {queries = 0, windows = windows}

    -- A pointer, number or integer cdata as a number, without allocating: a
    -- pointer passes through the cell. Exact below 2^53 (user-mode addresses
    -- end at 2^47).
    local function address_of(address)
        if type(address) == 'number' then return address end
        if type(address) == 'cdata' then
            local integer = tonumber(address)
            if integer then return integer end
        end
        cell.pointer = address
        return cell.low + cell.high * HIGH
    end

    function api.module(name)
        local handle = kernel.GetModuleHandleA(name)
        if handle == nil then return nil end
        return ffi.cast('uint8_t *', handle)
    end

    -- The bytes at address as a string, or nil when they cannot all be read.
    -- Allocates only the returned string.
    function api.read(address, size)
        if size > scratch_size then
            scratch_size = max(size, scratch_size * 2)
            scratch = ffi.new('uint8_t[?]', scratch_size)
        end
        if read_memory(process, address, scratch, size, done) == 0 or done32[0] ~= size then
            return nil
        end
        return ffi.string(scratch, size)
    end

    -- Into a buffer the caller keeps: no allocation at all.
    function api.read_into(address, size, buffer)
        return read_memory(process, address, buffer, size, done) ~= 0 and done32[0] == size
    end

    -- The user-mode pointer stored little-endian at bytes[offset+1 .. offset+8].
    function api.pointer(bytes, offset)
        offset = offset or 0
        if type(bytes) ~= 'string' or offset < 0 or offset + 8 > #bytes then return nil end
        local b1, b2, b3, b4, b5, b6, b7, b8 = bytes:byte(offset + 1, offset + 8)
        if b7 ~= 0 or b8 ~= 0 then return nil end
        local value = b1 + b2 * 256 + b3 * 65536 + b4 * 16777216 + (b5 + b6 * 256) * HIGH
        if value < 0x10000 or value >= 0x800000000000 then return nil end
        return ffi.cast('uint8_t *', value)
    end

    api.address = address_of

    function api.distance(first, second)
        return address_of(first) - address_of(second)
    end

    -- True when [address, address + size) is committed private read-write memory:
    -- never code, read-only, guard or module image pages. One VirtualQuery per
    -- region, each answered in the region record (no allocation).
    function api.writable_data(address, size)
        if type(size) ~= 'number' or size <= 0 then return false end
        local cursor = address_of(address)
        local finish = cursor + size
        while cursor < finish do
            api.queries = api.queries + 1
            if query(cursor, region, region_size) ~= region_size then return false end
            if region.state ~= MEM_COMMIT or region.type ~= MEM_PRIVATE or region.protection ~= PAGE_READWRITE then
                return false
            end
            local region_end = region.base_low + region.base_high * HIGH + region.size_low + region.size_high * HIGH
            if region_end <= cursor then return false end
            cursor = region_end
        end
        return true
    end

    -- Seconds since an arbitrary start (boot), from the performance counter read
    -- as two 32-bit halves into a reused buffer; the frequency is read once.
    function api.time()
        query_counter(counter)
        return (counter[0] + counter[1] * HIGH) / ticks
    end

    function api.module_hash(module)
        return module_hash(runtime, windows, module)
    end

    -- build: {exe_sha256, game_sha256}. true, or false and why.
    function api.verify_build(build)
        local exe, game = api.module(nil), api.module('game.dll')
        if not exe or not game then return false, 'game modules unavailable' end
        if api.module_hash(exe) ~= build.exe_sha256 or api.module_hash(game) ~= build.game_sha256 then
            return false, 'unsupported game build'
        end
        return true
    end

    return api
end

return memory

end)()
local runtime_write = (function()
-- bingus_write.lua, version 1: the write side of Bingus Shared Runtime.
-- Canonical copy: github.com/CowboyBingus/BingusSharedRuntime, runtime/bingus_write.lua.
--
-- Loading: the chunk returns {VERSION = 1, extend = function(api)} and installs
-- nothing. A mod that writes vendors byte-identical copies of all three files
-- and runs each once when it loads:
--   local runtime = <bingus_runtime.lua>
--   local memory = <bingus_memory.lua>.new(runtime)
--   <bingus_write.lua>.extend(memory)   -- adds write and write_batch; returns memory
--
-- extend(api) takes an api from bingus_memory.lua (version 1) and adds:
--   api.write(address, bytes [, size])   bytes: a string, or a buffer with size.
--                                        true when every byte landed
--   api.write_batch(base, size, changes) several writes inside [base, base + size)
--                                        under one check: changes = {{offset, bytes},
--                                        ...}. true and the count, or false and how
--                                        many writes landed, so the caller can undo them
--   api.windows.kernel32.WriteProcessMemory, bound like the read-side functions
-- write takes a pointer cdata; write_batch a pointer or a number.
--
-- Writes go only into memory that is already committed, private and read-write:
-- never code, read-only, guard or module image pages. Each write checks its whole
-- range with api.writable_data right before writing (one VirtualQuery per memory
-- region, about 0.29 ms each in game; api.queries counts them), so write only on
-- frames that act. Nothing here changes page protection or allocates memory
-- pages. WriteProcessMemory is declared under a private, versioned name
-- (bingus_write1_*, an __asm__ label naming the real export), at most once per
-- version in the whole game; the marker type bingus_write1_declared is this
-- file's sentinel.
local write = {VERSION = 1}

local type, error, pcall = type, error, pcall

local SENTINEL = 'bingus_write1_declared'
local DECLARATIONS = [[
    typedef struct bingus_write1_declared bingus_write1_declared;
    int bingus_write1_WriteProcessMemory(void *process, void *address, const void *buffer, size_t size,
                                         size_t *done) __asm__("WriteProcessMemory");
]]

local bound
-- The bound function, declared at most once per version in the whole game.
local function bind(ffi)
    if bound then return bound end
    if not pcall(ffi.typeof, SENTINEL) then ffi.cdef(DECLARATIONS) end
    bound = ffi.load('kernel32').bingus_write1_WriteProcessMemory
    return bound
end

function write.extend(api)
    if type(api) ~= 'table' or type(api.writable_data) ~= 'function' or type(api.windows) ~= 'table' then
        error('bingus_write.lua: extend(api) needs an api from bingus_memory.lua', 2)
    end
    local windows = api.windows
    local ffi, kernel = windows.ffi, windows.kernel32
    local write_memory = bind(ffi)
    kernel.WriteProcessMemory = write_memory
    local process = kernel.GetCurrentProcess()
    -- The 64-bit count is read back as two 32-bit words: reading the 64-bit value
    -- boxes a new cdata in interpreted code. Only the call writes this buffer.
    local done = ffi.new('size_t[1]')
    local done32 = ffi.cast('uint32_t *', done)

    -- bytes: a string, or a buffer with size. Checked right before the write.
    function api.write(address, bytes, size)
        size = size or #bytes
        if not api.writable_data(address, size) then return false end
        return write_memory(process, address, bytes, size, done) ~= 0 and done32[0] == size
    end

    -- Stops at the first failure and returns false and how many writes landed.
    function api.write_batch(base, size, changes)
        if not api.writable_data(base, size) then return false, 0 end
        local start = ffi.cast('uint8_t *', base)
        for index = 1, #changes do
            local offset, bytes = changes[index][1], changes[index][2]
            if offset < 0 or offset + #bytes > size
                or write_memory(process, start + offset, bytes, #bytes, done) == 0
                or done32[0] ~= #bytes then
                return false, index - 1
            end
        end
        return true, #changes
    end

    return api
end

return write

end)()
local create_api = (function()
-- The memory API the patch and the loader use, on top of Bingus Shared Runtime
-- v1: runtime is the core (src/bingus_runtime.lua) and memory the api of
-- src/bingus_memory.lua extended by src/bingus_write.lua, byte-identical copies
-- that the build embeds and passes in. The runtime declares the Windows
-- functions under private, versioned FFI names and provides the page check,
-- checked writes, module handles and module hashes (computed once per session
-- for every mod). This adapter adds what the patch needs beyond that: reads at
-- plain-number addresses that allocate nothing but a returned string, writes
-- whose page the caller already checked and the span a page check approved.
-- The log throttle's clock is the runtime's: memory.time(), seconds from the
-- performance counter, which allocates nothing.
return function(runtime, memory)
    assert(type(runtime) == 'table' and type(memory) == 'table' and type(memory.write) == 'function',
        'Bingus Shared Runtime v1 memory api with writes is required')
    local native = memory.windows
    local ffi, kernel = native.ffi, native.kernel32
    -- Private names, declared once per process: ffi.cdef keeps the first
    -- declaration of a name for the whole game. The casts below use these named
    -- types: a function pointer written out in a type string adds C types to the
    -- table all mods share on every use.
    if not pcall(ffi.typeof, 'swd_read_memory') then
        ffi.cdef [[
            typedef int (*swd_read_memory)(void *process, uint64_t address, uint64_t buffer, size_t size, uint32_t *read);
            typedef int (*swd_write_memory)(void *process, uint64_t address, const void *buffer, size_t size, uint32_t *written);
        ]]
    end
    -- Memory is addressed by plain numbers: these casts of the runtime's
    -- functions take the address and destination as uint64_t (the same register
    -- as a pointer on x64) and the byte count as two 32-bit words, so a call
    -- creates no pointer or 64-bit cdata. Neither call re-enters Lua before its
    -- count words are read. The runtime's read and read_into take pointers
    -- instead, which number addresses would have to be cast to on every read:
    -- 16 bytes of garbage per address (32 per read_into) wherever the code runs
    -- interpreted, which is always the snapshot and in practice the rarely run
    -- dive start, landing and restore.
    local read_memory = ffi.cast('swd_read_memory', kernel.ReadProcessMemory)
    local write_memory = ffi.cast('swd_write_memory', kernel.WriteProcessMemory)
    local process = kernel.GetCurrentProcess()
    local api = {queries = 0, module = memory.module, module_hash = memory.module_hash, distance = memory.distance,
        time = memory.time}

    local count = ffi.new('uint32_t[2]')
    local function read_to(address, size, destination)
        return read_memory(process, address, destination, size, count) ~= 0 and count[0] == size and count[1] == 0
    end
    -- read(address, size) returns the bytes as a string (one scratch buffer,
    -- grown on demand): a read allocates only the returned string.
    -- read(address, size, into, offset) copies them into a caller buffer
    -- {data, address, size} at offset and returns true: nothing is allocated,
    -- which is what the per-frame snapshot uses.
    local scratch_size, scratch = 4096, ffi.new('uint8_t[4096]')
    local scratch_address = tonumber(ffi.cast('uintptr_t', scratch))
    function api.read(address, size, into, offset)
        if into then
            offset = offset or 0
            if size <= 0 or offset < 0 or offset + size > into.size then return nil end
            return read_to(address, size, into.address + offset) or nil
        end
        if size < 0 or size > scratch_size then
            scratch, scratch_size = ffi.new('uint8_t[?]', size), size
            scratch_address = tonumber(ffi.cast('uintptr_t', scratch))
        end
        if not read_to(address, size, scratch_address) then return nil end
        return ffi.string(scratch, size)
    end

    -- True, and the span [low, high) it approved, when every page of
    -- [address, address + size) is committed private read/write data: the
    -- runtime's check, one VirtualQuery per region (about 0.29 ms each in game;
    -- api.queries counts them). The runtime reports no region bounds, so the
    -- check covers the whole pages around the range and that is the span kept.
    -- Protection is set per page: the pages pass exactly when the range does.
    local PAGE = 4096
    function api.writable_data(address, size)
        if type(size) ~= 'number' or size <= 0 then return false end
        local low = memory.address(address)
        local high = low + size
        low, high = low - low % PAGE, high + (-high) % PAGE
        local ok = memory.writable_data(low, high - low)
        api.queries = memory.queries
        if not ok then return false end
        return true, low, high
    end

    -- checked: the caller verified this range with writable_data and decides
    -- how long that check stays valid, so the write makes no page check.
    -- Otherwise the runtime's write checks the range right before writing.
    local written = ffi.new('uint32_t[2]')
    function api.write(address, bytes, checked)
        if checked then
            return write_memory(process, address, bytes, #bytes, written) ~= 0
                and written[0] == #bytes and written[1] == 0
        end
        local ok = memory.write(ffi.cast('void *', address), bytes)
        api.queries = memory.queries
        return ok
    end
    return api
end

end)()
local patch = (function()
local ffi,bit=require('ffi'),require('bit')
local M={}
-- Deepest water (game units above the native root) where a dive keeps the
-- standing reference. 0.20, tightened after the knee-depth test, is the
-- default and the minimum; Mod Options Menu may raise it up to the standing
-- reference itself (1.30), above which the avatar swims and 'deep_water'
-- applies anyway.
M.MIN_WATER_DEPTH,M.SWIM_DEPTH=0.20,1.30
M.max_water_depth=M.MIN_WATER_DEPTH
function M.set_max_water_depth(depth)
    if type(depth)~='number' or depth~=depth then return false end
    M.max_water_depth=math.max(M.MIN_WATER_DEPTH,math.min(M.SWIM_DEPTH,depth))
    return true
end

-- A check allocates nothing. Every read of a snapshot lands in one reused
-- arena (8-byte aligned), addresses are plain numbers, fields decode in place
-- and pointers decode from two 32-bit halves. Each read, or each record inside
-- a bulk read, is remembered as a guard (address, arena offset, size) for the
-- coherence check before a write.
local ARENA,GUARDS=16384,1024
local arena=ffi.new('uint8_t[?]',ARENA)
local words,floats=ffi.cast('uint32_t *',arena),ffi.cast('float *',arena)
local buffer={data=arena,address=tonumber(ffi.cast('uintptr_t',arena)),size=ARENA}
local recheck=ffi.new('uint8_t[?]',4096)
local recheck_buffer={data=recheck,address=tonumber(ffi.cast('uintptr_t',recheck)),size=4096}
local guard_address,guard_offset=ffi.new('double[?]',GUARDS),ffi.new('int32_t[?]',GUARDS)
local guard_size,guard_identity=ffi.new('int32_t[?]',GUARDS),ffi.new('bool[?]',GUARDS)
-- Float conversions through one union: the JIT treats a store and a load of
-- different types as aliasing only when they share a base, so type punning
-- through two separate pointer views of one cell would read a stale value.
-- The arena is written by ReadProcessMemory calls only, which order its loads.
-- The union is declared once by name: an anonymous one in a type string would
-- add C types to the table all mods share on every load.
if not pcall(ffi.typeof,'SwdFloatBits') then ffi.cdef('typedef union { float f; uint32_t u; } SwdFloatBits;') end
local cell=ffi.new('SwdFloatBits')
local function rounded(n) cell.f=n;return cell.f end
local function float_bits(n) cell.f=n;return cell.u end
-- Four-byte strings, for the write and restore paths only.
local function packed(n) return ffi.string(ffi.new('float[1]',n),4) end
local function bits_packed(b) return ffi.string(ffi.new('uint32_t[1]',b),4) end
local function string_u32(bytes) local w=ffi.new('uint32_t[1]');ffi.copy(w,bytes,4);return w[0] end
local function finite(n) return n==n and math.abs(n)<100000 end
local function partial(before,after,current)
    if not current then return false end
    for cut=0,#after do
        if current==after:sub(1,cut)..before:sub(cut+1) then return true end
    end
    return false
end
local DIVE_TIMEOUT_RVAS={0x2246948,0x2246938}
local RESOURCE='\151\250\077\041\077\051\028\077'
local RESOURCE_LOW,RESOURCE_HIGH
do
    local id=ffi.new('uint8_t[8]');ffi.copy(id,RESOURCE,8)
    local halves=ffi.cast('uint32_t *',id);RESOURCE_LOW,RESOURCE_HIGH=halves[0],halves[1]
end
local TIMEOUT,PRONE,CROUCH,SETTINGS_BASE=float_bits(2),float_bits(0.9),float_bits(0.4),float_bits(-1.3)
local function matches(api,guards)
    for _,g in ipairs(guards) do if api.read(g.address,#g.bytes)~=g.bytes then return false end end
    return true
end
-- Waiting reasons, built once, with the names the earlier error-based waits
-- used: 'waiting_for_<stage>_read', '_pointer' and '_global_<rva>'.
local STAGES={}
for _,name in ipairs({'mission','local_player','local_avatar','water','stance','movement','water_settings'}) do
    STAGES[name]={read='waiting_for_'..name..'_read',pointer='waiting_for_'..name..'_pointer',
        invalid='Invalid '..name..' pointer'}
end
-- Waiting reasons answered before the local avatar's dive controller was
-- reached (no mission, no local player, no local avatar): no dive can start
-- before one exists, so the loader polls these less often. Waits on a dive
-- frame (water, stance, movement, settings) are not in it.
local BEFORE_AVATAR={mission=true,local_player=true,local_avatar=true}
M.NO_AVATAR={}
for name in pairs(BEFORE_AVATAR) do
    M.NO_AVATAR['waiting_for_'..name],M.NO_AVATAR[STAGES[name].read],M.NO_AVATAR[STAGES[name].pointer]=true,true,true
end
local GLOBAL_WAIT={}
for rva,name in pairs({[0x2ce1850]='mission',[0x2ce1618]='local_player',[0x2ce41b8]='local_avatar',
    [0x2ce1ee0]='local_avatar',[0x2ce1c40]='water',[0x2ce1748]='stance',[0x2ce1708]='movement'}) do
    GLOBAL_WAIT[rva]=string.format('waiting_for_%s_global_%x',name,rva)
    if BEFORE_AVATAR[name] then M.NO_AVATAR[GLOBAL_WAIT[rva]]=true end
end

-- The running check: adapter, game.dll base address, stage, the reason the
-- last helper returned nil, and the arena bytes and guards used so far.
local reader,base,stage,wait,used,guards
local game_pointer,game_address
local function u(o) return words[o/4] end
local function f(o) return floats[o/4] end
local function guard(address,o,size,identity)
    assert(guards<GUARDS,'Too many snapshot guards')
    guard_address[guards],guard_offset[guards],guard_size[guards]=address,o,size
    guard_identity[guards]=identity==true
    guards=guards+1
end
-- One read without a guard: the caller guards the records it uses.
local function fetch(address,size)
    local o=used
    assert(o+size<=ARENA,'Snapshot exceeds its buffer')
    if not reader.read(address,size,buffer,o) then wait=stage.read;return nil end
    used=o+size+(-size)%8
    return o
end
local function read(address,size,identity)
    local o=fetch(address,size)
    if o then guard(address,o,size,identity) end
    return o
end
local function pointer(o)
    local low,high=words[o/4],words[o/4+1]
    if low==0 and high==0 then wait=stage.pointer;return nil end
    local p=high*4294967296+low
    assert(p>=0x10000 and p<0x800000000000,stage.invalid)
    return p
end
local function global(rva,identity)
    local o=read(base+rva,8,identity)
    if not o then return nil end
    if words[o/4]==0 and words[o/4+1]==0 then wait=GLOBAL_WAIT[rva];return nil end
    return pointer(o)
end
-- Low 32 bits of key*mult from 16-bit halves: exact in doubles, no 64-bit cdata.
local function hash(key,mult)
    local kl,kh,ml,mh=bit.band(key,0xffff),bit.rshift(key,16),bit.band(mult,0xffff),bit.rshift(mult,16)
    return kl*ml+bit.band(kh*ml+kl*mh,0xffff)*65536
end
-- The index stored for key, nil when absent, false while waiting.
local function lookup(header,key,limit,identity)
    local capacity,empty,mult=u(header+8),u(header+12),u(header+16)
    if capacity==0 then return nil end
    assert(capacity<=limit and bit.band(capacity,capacity-1)==0,'Unsupported map')
    local data=pointer(header)
    if not data then return false end
    local product=hash(key,mult)
    for probe=0,math.min(capacity,128)-1 do
        local row=read(data+bit.band(product+probe,capacity-1)*8,8,identity)
        if not row then return false end
        if u(row)==key then return u(row+4) end
        if u(row)==empty then return nil end
    end
end
local function same_record(a,b)
    for i=0,5 do if words[a/4+i]~=words[b/4+i] then return false end end
    return true
end

-- Dive controller: the dive record (+0xb84) and state flags (+0xf80), one read.
local CONTROLLER,CONTROLLER_SIZE,FLAGS=0xb84,0x41c,0xf88-0xb84
-- Every field a snapshot returns; the one table is reused by every check.
local S={dive=false,swim=false,ragdoll=false,elapsed=0,landing=0,key=0,entity=0,controller=0,id=0,
    manager=0,table=0,water_address=0,enabled=false,water_gate=false,offset=0,offset_bits=0,drown_elapsed=0,remaining=0,
    surface=0,elapsed_bits=0,deep=false,stance_address=0,stance=0,root_z=0,base=0,prone=0}

-- Returns the reused snapshot table, or nil and a waiting reason. The fields
-- stay valid until the next check; S.entity is an arena offset.
function M.snapshot(api,game,state)
    reader,used,guards=api,0,0
    if type(game)=='number' then base=game
    else
        if game~=game_pointer then game_pointer,game_address=game,tonumber(ffi.cast('uintptr_t',game)) end
        base=game_address
    end
    stage=STAGES.mission
    local mode=global(0x2ce1850);if not mode then return nil,wait end
    mode=read(mode,0x44);if not mode then return nil,wait end
    if u(mode+8)==0 or u(mode+0x40)<1 or u(mode+0x40)>7 then return nil,'waiting_for_mission' end
    stage=STAGES.local_player
    local pm=global(0x2ce1618);if not pm then return nil,wait end
    -- Player counts (+0x84), player pointer (+0xe8) and unit (+0x3a8), one read.
    local p=fetch(pm+0x84,0x328);if not p then return nil,wait end
    guard(pm+0x84,p,8)
    assert(u(p)<=4 and u(p+4)<=4,'Unsupported player count')
    if u(p)==0 or u(p+4)==0 then return nil,'waiting_for_local_player' end
    guard(pm+0xe8,p+0x64,8)
    local player=pointer(p+0x64);if not player then return nil,wait end
    player=read(player,24);if not player then return nil,wait end
    if bit.band(arena[player+20],1)==0 then return nil,'waiting_for_local_player' end
    guard(pm+0x3a8,p+0x324,4)
    local unit=u(p+0x324)
    if unit==0x7fff then return nil,'waiting_for_local_avatar' end
    stage=STAGES.local_avatar
    local owner=global(0x2ce41b8,true);if not owner then return nil,wait end
    local header=read(owner+0xf24990,20);if not header then return nil,wait end
    local ei=lookup(header,unit,1048576);if ei==false then return nil,wait end
    if not ei or ei==0xffffffff then return nil,'waiting_for_local_avatar' end
    assert(ei<262144,'Unsupported entity index')
    local entity_address=owner+0xf349e0+ei*24
    local entity=read(entity_address,24,true);if not entity then return nil,wait end
    assert(u(entity)==RESOURCE_LOW and u(entity+4)==RESOURCE_HIGH,'Unsupported avatar resource')
    if bit.band(arena[entity+20],1)==0 then return nil,'waiting_for_local_avatar' end
    local id=u(entity+8)
    local am=global(0x2ce1ee0,true);if not am then return nil,wait end
    -- Avatar count (+0x6c), map header (+0xf8) and registry (+0x110), one read.
    local a=fetch(am+0x6c,0xe4);if not a then return nil,wait end
    guard(am+0xf8,a+0x8c,20)
    local ai=lookup(a+0x8c,id,64);if ai==false then return nil,wait end
    if not ai or ai==0xffffffff then return nil,'waiting_for_local_avatar' end
    guard(am+0x6c,a,4)
    local count=u(a)
    if count==0 then return nil,'waiting_for_local_avatar' end
    assert(count<=8 and ai<count,'Unsupported avatar index')
    guard(am+0x110+ai*8,a+0xa4+ai*8,8,true)
    local registered=pointer(a+0xa4+ai*8);if not registered then return nil,wait end
    registered=read(registered,24,true);if not registered then return nil,wait end
    assert(same_record(registered,entity),'Avatar registry mismatch')
    local controller=am+0x53d900+ai*0x1240
    local c=fetch(controller+CONTROLLER,CONTROLLER_SIZE);if not c then return nil,wait end
    guard(controller+CONTROLLER,c,20);guard(controller+0xf88,c+FLAGS,24)
    assert(u(c)==id,'Dive controller identity mismatch')
    S.dive=bit.band(u(c+FLAGS+12),0x20)~=0
    S.swim=bit.band(u(c+FLAGS+8),0x80000000)~=0
    S.ragdoll=bit.band(u(c+FLAGS+12),0x10)~=0
    S.elapsed,S.landing=f(c+8),f(c+12)
    S.key,S.entity,S.controller,S.id=entity_address,entity,controller,id
    if not S.dive then
        -- Outside a dive, apply() needs only the identity and the dive timer
        -- (it answers 'dive_ended' before reading anything else), so the water,
        -- stance, movement and settings records wait for a dive. They are still
        -- fully read and validated on every dive frame, before any write.
        assert(finite(S.elapsed) and finite(S.landing),'Invalid movement or water value')
        return S
    end
    stage=STAGES.water
    local dm=global(0x2ce1c40,true);if not dm then return nil,wait end
    -- Record capacity (+8), map header (+32) and the owner, data and enabled
    -- pointers (+56, +64, +72), one read.
    local d=fetch(dm+8,72);if not d then return nil,wait end
    guard(dm+32,d+24,20,true)
    local di=lookup(d+24,id,32768,true);if di==false then return nil,wait end
    guard(dm+8,d,4)
    local capacity=u(d)
    if not di or di==0xffffffff or capacity==0 then return nil,'waiting_for_water_record' end
    assert(di<capacity and capacity<=16384,'Drownable record unavailable')
    guard(dm+56,d+48,8,true)
    local owners=pointer(d+48);if not owners then return nil,wait end
    local drownable=read(owners+8*di,8,true);if not drownable then return nil,wait end
    drownable=pointer(drownable);if not drownable then return nil,wait end
    drownable=read(drownable,24,true);if not drownable then return nil,wait end
    assert(same_record(drownable,entity),'Drownable identity mismatch')
    guard(dm+64,d+56,8,true)
    local data=pointer(d+56);if not data then return nil,wait end
    S.manager,S.table,S.water_address=dm,data,data+28*di
    local water=read(S.water_address,28);if not water then return nil,wait end
    guard(dm+72,d+64,8)
    local enabled=pointer(d+64);if not enabled then return nil,wait end
    enabled=read(enabled+2*di,2);if not enabled then return nil,wait end
    S.enabled,S.water_gate=arena[enabled]~=0,arena[enabled+1]~=0
    assert(u(water+4)==0,'Unsupported water reference node')
    S.offset,S.offset_bits=f(water+8),u(water+8)
    S.drown_elapsed,S.remaining,S.surface=f(water+16),f(water+20),f(water+24)
    S.elapsed_bits=u(water+16)
    S.deep=arena[water+1]~=0
    stage=STAGES.stance
    local sm=global(0x2ce1748,true);if not sm then return nil,wait end
    -- Map header (+24) and stance data pointer (+56), one read.
    local st=fetch(sm+24,40);if not st then return nil,wait end
    guard(sm+24,st,20,true)
    local si=lookup(st,id,8192,true);if si==false then return nil,wait end
    if not si or si==0xffffffff then return nil,'waiting_for_stance_record' end
    assert(si<4096,'Unsupported stance index')
    guard(sm+56,st+32,8,true)
    local stances=pointer(st+32);if not stances then return nil,wait end
    S.stance_address=stances+56*si+28
    local stance=read(S.stance_address,4);if not stance then return nil,wait end
    S.stance=u(stance)
    if S.stance==3 then return nil,'waiting_for_stance' end
    assert(S.stance<=2,'Unsupported stance')
    stage=STAGES.movement
    local mm=global(0x2ce1708);if not mm then return nil,wait end
    -- Map header (+0x48a0) and position data pointer (+0x48d8), one read.
    local mv=fetch(mm+0x48a0,64);if not mv then return nil,wait end
    guard(mm+0x48a0,mv,20)
    local mi=lookup(mv,id,16384);if mi==false then return nil,wait end
    if not mi or mi==0xffffffff then return nil,'waiting_for_movement_record' end
    assert(mi<8192,'Unsupported movement index')
    guard(mm+0x48d8,mv+0x38,8)
    local positions=pointer(mv+0x38);if not positions then return nil,wait end
    local pos=read(positions+44*mi,44);if not pos then return nil,wait end
    if arena[pos+32]==0 then return nil,'waiting_for_movement_reference' end
    S.root_z=f(pos+8)
    stage=STAGES.water_settings
    local components=read(owner+0xf148e8,8);if not components then return nil,wait end
    components=pointer(components);if not components then return nil,wait end
    -- The 122-slot resource map and the first six resources, one read.
    local map=fetch(components,122*16+6*64);if not map then return nil,wait end
    guard(components,map,122*16)
    local index
    for slot=0,121 do
        local o=map+slot*16
        if u(o)==RESOURCE_LOW and u(o+4)==RESOURCE_HIGH then index=u(o+8);break end
    end
    if index==nil then return nil,'waiting_for_water_settings' end
    assert(index==5,'Unsupported Drownable resource')
    local resource=map+122*16+64*index
    guard(components+122*16+64*index,resource,64)
    assert(u(resource)==0x4a182741 and u(resource+4)==SETTINGS_BASE,'Drownable settings changed')
    S.base=f(resource+4)
    S.prone=rounded(S.base+rounded(0.9))
    if not (state and state.constants_verified) then
        -- The dive timeout (2.0) and both stance offsets are game.dll read-only
        -- data: verified on the first dive of a session, not on every frame.
        -- Build 25480438 shifted this constant block by 0x10 (both stance
        -- constants below moved); the timeout kept its old address by mistake.
        -- The exact 2.0 value remains the gate; the old address is a fallback.
        local timeout_ok=false
        for i=1,#DIVE_TIMEOUT_RVAS do
            if reader.read(base+DIVE_TIMEOUT_RVAS[i],4,buffer,used) and u(used)==TIMEOUT then timeout_ok=true;break end
        end
        if not timeout_ok then
            -- Evidence for the next migration: every 2.0 near the expected block.
            local window,two=reader.read(base+0x22468b8,0x100) or '',packed(2)
            local found={}
            for o=0,#window-4,4 do if window:sub(o+1,o+4)==two then found[#found+1]=string.format('0x%x',0x22468b8+o) end end
            error(string.format('Native dive timeout changed (2.0 near expected block at: %s)',
                #found>0 and table.concat(found,',') or 'none'),0)
        end
        local prone=read(base+0x22464ec,4);if not prone then return nil,wait end
        assert(u(prone)==PRONE,'Stance offsets changed')
        local crouch=read(base+0x2246210,4);if not crouch then return nil,wait end
        assert(u(crouch)==CROUCH,'Stance offsets changed')
        if state then state.constants_verified=true end
    end
    assert(finite(S.elapsed) and finite(S.landing) and finite(S.offset) and finite(S.drown_elapsed)
        and finite(S.remaining) and finite(S.surface) and finite(S.root_z),'Invalid movement or water value')
    return S
end

-- Returns a reason rather than changing the game. The native landing timer is
-- zero in flight and becomes positive when the native land_dodge path begins.
function M.reason(s)
    if not s.dive then return 'dive_ended' end
    if s.swim or s.ragdoll or s.stance~=2 then return 'other_state' end
    if not s.enabled or s.remaining<=0 then return 'water_disabled_or_drowned' end
    if s.landing~=0 then return 'landing' end
    if s.elapsed<0 or s.elapsed>=2 then return 'native_timeout' end
    -- A disabled secondary gate makes surface_z a reset value, not a plane.
    if s.deep or s.water_gate and s.surface>s.root_z-s.base then return 'deep_water' end
    -- A reset surface value is not evidence of water. Restrict the assistance
    -- to the configured depth (lower shin by default); deeper water keeps the
    -- game's normal dive decision.
    if not s.water_gate then return 'water_surface_unavailable' end
    local depth=s.surface-s.root_z
    if depth<=0 then return 'not_in_shallow_water' end
    if depth>M.max_water_depth+0.00001 then return 'water_too_deep' end
    return nil
end

-- reuse: the caller just saw a normal dive end with a fresh snapshot, so the
-- page check made when this lease began still covers its record once the
-- identity below (the table pointer included) matches. Every other caller
-- (shutdown, stops, waits, failed writes) checks the page again.
function M.restore(api,pending,reuse)
    if not pending then return true,'nothing_to_restore' end
    if not matches(api,pending.identity) then return true,'retired_identity' end
    local checked=reuse and pending.checked
    if pending.elapsed_recovery then
        local e=pending.elapsed_recovery
        local current=api.read(e.address,4)
        if partial(e.before,e.after,current) and current~=e.before then
            api.write(e.address,e.before,checked)
            if api.read(e.address,4)~=e.before then return false,'startup_restore_failed' end
        end
        pending.elapsed_recovery=nil
    end
    local current=api.read(pending.address,4)
    local ours=current==pending.after
        or pending.failed_write and partial(pending.before,pending.after,current)
        or pending.recovery and partial(pending.recovery.before,pending.recovery.after,current)
    if not ours then return true,'offset_changed_by_engine' end
    local stance=api.read(pending.stance_address,4)
    if not stance then return false,'stance_unavailable' end
    local index=string_u32(stance)
    if index>2 then return false,'stance_unavailable' end
    -- A native transition to standing may already have written the same bytes
    -- we used. Restore the CURRENT stance's default, never stale prone bytes.
    local target=packed(rounded(pending.base+(index==2 and rounded(0.9) or index==1 and rounded(0.4) or 0)))
    if current==target then return true,'already_restored' end
    if not matches(api,pending.identity) then return true,'retired_identity' end
    pending.recovery={before=current,after=target}
    if not api.write(pending.address,target,checked) then return false,'offset_not_writable' end
    return api.read(pending.address,4)==target,'restored'
end

-- Re-reads the current snapshot's guards (all, or the identity ones) and
-- compares them byte for byte with what the snapshot saw.
local function guards_match(api,identity_only)
    for i=0,guards-1 do
        if guard_identity[i] or not identity_only then
            local o,size=guard_offset[i],guard_size[i]
            if not api.read(guard_address[i],size,recheck_buffer,0) then return false end
            for j=0,size-1 do if recheck[j]~=arena[o+j] then return false end end
        end
    end
    return true
end
-- The identity guards as strings, kept by a lease for restore().
local function identity_list()
    local list={}
    for i=0,guards-1 do
        if guard_identity[i] then
            list[#list+1]={address=guard_address[i],bytes=ffi.string(arena+guard_offset[i],guard_size[i])}
        end
    end
    return list
end
local function release(api,state,reason,reuse)
    local ok=M.restore(api,state.pending,reuse)
    if ok then state.pending=nil;state.restored=state.restored+1 end
    return ok,ok and reason or 'restore_failed',false
end
local function same_entity(seen,o)
    for i=0,5 do if seen[i]~=words[o/4+i] then return false end end
    return true
end

-- Page check for the two water-record writes. A protection query costs about
-- 0.2-0.3 ms in game, so one runs per record table, not per write: the span
-- it approved is kept while the same Drownable manager, table and avatar are
-- in use (the guards re-read the table pointer and the record's owner right
-- before every write) and is dropped on any wait, avatar change or failed
-- write. A table seen at a new address while one was kept counts as a move.
local function writable(api,state,s)
    local low,high=s.water_address+8,s.water_address+20
    local c=state.write_check
    if c and c.manager==s.manager and c.table==s.table and c.key==state.key and c.low<=low and high<=c.high then
        return true
    end
    if c and (c.manager~=s.manager or c.table~=s.table) then state.table_moves=state.table_moves+1 end
    state.write_check=nil
    local ok,from,to=api.writable_data(low,high-low)
    if not ok then return false end
    state.write_check={manager=s.manager,table=s.table,key=state.key,low=from,high=to}
    return true
end

-- Idle gate, run by the loader between full checks while the last one found
-- the local avatar idle ('dive_ended', no lease or retry): one read of its
-- dive controller. The same avatar id, no dive flag (bit 0x20 of +0xf8c) and
-- finite timers mean 'dive_ended', exactly what the full check answers there;
-- true then. Anything else (a dive, another id, a failed read) is false, and
-- the loader runs the full check at once. The gate reads into the snapshot
-- arena and writes nothing.
local band=bit.band
function M.idle(api,state)
    if not api.read(state.gate_controller+CONTROLLER,CONTROLLER_SIZE,buffer,0) or words[0]~=state.gate_id
        or band(words[(FLAGS+12)/4],0x20)~=0 then return false end
    return finite(floats[2]) and finite(floats[3])
end

-- The full check: every call reads the identity chain (the idle gate above
-- is the loader's).
function M.apply(api,game,exe,state)
    local s,waiting=M.snapshot(api,game,state)
    if not s then
        -- Clear only what is set: storing nil under a missing key still adds
        -- the key, and the resize that can follow allocates on waiting checks.
        if state.gate_controller then state.gate_controller=nil end
        if state.write_check then state.write_check=nil end
        if state.key then state.key=nil end
        state.was_dive=false;state.retry_start=false
        if state.pending then return release(api,state,waiting) end
        return true,waiting,false
    end
    local seen=state.entity_words
    if not seen then seen=ffi.new('uint32_t[6]');state.entity_words=seen end
    if state.key~=s.key or not same_entity(seen,s.entity) then
        if state.pending then
            local ok=M.restore(api,state.pending)
            if not ok then return false,'restore_failed',false end
            state.pending=nil
        end
        state.key=s.key;state.was_dive=false;state.retry_start=false
        if state.write_check then state.write_check=nil end
        for i=0,5 do seen[i]=words[s.entity/4+i] end
    end
    state.gate_controller,state.gate_id=s.controller,s.id
    local new_dive=s.dive and not state.was_dive
    if new_dive then state.observed=state.observed+1 end
    if state.was_dive and not s.dive and s.elapsed<=0.02 then state.short_ends=state.short_ends+1 end
    state.was_dive=s.dive
    local reason=M.reason(s)
    if state.pending then
        if reason then return release(api,state,reason,true) end
        if s.offset_bits~=state.pending.after_bits then return release(api,state,'offset_changed_by_engine') end
        return true,'airborne_reference',true
    end
    if reason then state.retry_start=false;return true,reason,false end
    -- Do not acquire an old dive after module load or rescue an ongoing swim.
    if not (new_dive or state.retry_start) or s.elapsed>0.05 then return true,'waiting_for_dive_start',false end
    state.retry_start=false
    if s.drown_elapsed>0.05 or s.drown_elapsed>0 and not s.water_gate then
        return true,'existing_submersion',false
    end
    if s.offset_bits~=float_bits(s.prone) then return true,'different_reference_owner',false end
    local address=s.water_address+8
    if not guards_match(api,false) then
        -- Retry a coherent snapshot at the other update boundary in this frame.
        state.retry_start=true
        return true,'snapshot_changed',false
    end
    -- Both floats of the record in one page check, kept per table (see
    -- writable). A refused page stops the mod before anything is written.
    if not writable(api,state,s) then return false,'reference_write_failed',false end
    state.pending={address=address,before=bits_packed(s.offset_bits),after=packed(s.base),
        after_bits=float_bits(s.base),identity=identity_list(),stance_address=s.stance_address,base=s.base,
        checked=true}
    local ok=api.write(address,state.pending.after,true)
    if not ok or api.read(address,4)~=state.pending.after then
        -- A partially written float can contain neither complete value. We own
        -- this exact attempted write, and the entity/record must still match.
        -- The kept page check is dropped; the restore checks the page again.
        state.write_check=nil
        state.pending.failed_write=true
        ok=M.restore(api,state.pending)
        if ok then state.pending=nil end
        return false,'reference_write_failed',false
    end
    -- The water update may already have counted the first prone frame. Clear
    -- only that startup debt, once, while the standing reference is above water.
    if s.drown_elapsed>0 and s.drown_elapsed<=0.05 and s.water_gate then
        local elapsed_address,elapsed_bytes,zero=s.water_address+16,bits_packed(s.elapsed_bits),packed(0)
        if not guards_match(api,true) then return release(api,state,'identity_changed') end
        if api.read(elapsed_address,4)~=elapsed_bytes then return release(api,state,'water_changed') end
        local cleared=api.write(elapsed_address,zero,true) and api.read(elapsed_address,4)==zero
        if not cleared then
            state.write_check=nil
            state.pending.elapsed_recovery={address=elapsed_address,before=elapsed_bytes,after=zero}
            release(api,state,'startup_write_failed')
            return false,'startup_write_failed',false
        end
        state.startup_clears=state.startup_clears+1
    elseif s.drown_elapsed>0 then
        return release(api,state,'existing_submersion')
    end
    state.protected=state.protected+1
    return true,'airborne_reference',true
end

-- The full snapshot is long straight-line code that runs every 120th idle
-- frame and on dive frames. Compiled, it took 50-74 KB of the LuaJIT code
-- cache every mod and the game share, to save about 6 us per dive-frame check
-- (measured in the game's lua51.dll); interpreted, the helpers it calls still
-- compile and the mod's machine code stays at 9-13 KB. The idle gate is
-- unaffected. This only marks this one function; it flushes nothing else.
if jit and jit.off then jit.off(M.snapshot) end

return M

end)()
local install_loader = (function()
-- text: src/bingus_text.lua; locales: {en, bundled} (locales/); runtime:
-- src/bingus_runtime.lua, whose guard wraps the game's update and shutdown.
return function(create_api,patch,build,text,locales,runtime)
    if rawget(_G,'ShallowWaterDive') then return end
    local state={revision=build.revision,active=false,observed=0,protected=0,
        restored=0,startup_clears=0,short_ends=0,table_moves=0,menu_attempts=0}
    rawset(_G,'ShallowWaterDive',state)
    local api,game,exe,last_log,guard
    -- The slider's texts, in the game's language when a translation has them;
    -- the translator's notes (language, refused entries) go to the log, as do
    -- the guard's lines (an error burst, a pause, a resume, a stop).
    local text_notes,guard_notes={},{}
    local tr=text.new(locales.en,locales.bundled,function(message)
        if #text_notes<20 then text_notes[#text_notes+1]=message end
    end)
    local function write_log()
        pcall(function()
            local logger=rawget(_G,'CowboyBingusModLoader')
            local file=logger and logger.open_log and logger.open_log('ShallowWaterDiving.log');if not file then return end
            file:write(build.revision..'\n'..state.status..'\n')
            for _,key in ipairs({'observed','protected','restored','startup_clears','short_ends','table_moves'}) do
                file:write(key..'='..state[key]..'\n')
            end
            -- Memory protection queries this session (about 0.2-0.3 ms each in game).
            file:write('protection_queries='..tostring(api and api.queries or 0)..'\n')
            -- The update guard's pauses and its error counts (own, below) in the current burst.
            if guard then
                local g=guard.status
                file:write('pauses='..g.pauses..'\nerrors='..g.errors..'\nerrors_below='..g.lower_errors..'\n')
            end
            if state.depth_option then
                file:write('menu_attempts='..state.menu_attempts..'\ndepth_option='..state.depth_option..'\n')
            end
            -- Present only when the loader's after_startup made the registration.
            if state.menu_registration then file:write('menu_registration='..state.menu_registration..'\n') end
            for _,line in ipairs(text_notes) do file:write('text: '..line..'\n') end
            for _,line in ipairs(guard_notes) do file:write('guard: '..line..'\n') end
            file:close()
        end)
    end
    -- Status and counts are kept in ShallowWaterDive on every check. The log
    -- file is written on startup, after the menu registration, on each guard
    -- line, when the mod pauses or stops and at shutdown; routine updates only
    -- with CowboyBingusDiagnostics = true, at most every 2 s. A check builds no
    -- strings and opens no files.
    local function report(status,active,force)
        state.status=status;state.active=active
        if not force and rawget(_G,'CowboyBingusDiagnostics')~=true then return end
        local now=api and api.time and api.time() or 0
        if not force and last_log and now-last_log<2 then return end
        last_log=now
        if force then print('[ShallowWaterDiving] '..build.revision..': '..status) end
        write_log()
    end
    local function guard_line(line)
        if #guard_notes<20 then guard_notes[#guard_notes+1]=line end
        print('[ShallowWaterDiving] '..build.revision..': '..line)
        write_log()
    end
    -- Optional Mod Options Menu slider for the deepest water a dive may start
    -- in; the applied value reaches the patch through on_change.
    local DEPTH_OPTION='shallow_water_diving.max_water_depth'
    -- Mod Options Menu v1.1 and later (version 2) take texts as functions and
    -- call them whenever the escape menu opens, so they follow the game's
    -- language; v1.0 takes strings with byte limits, where a translation that
    -- does not fit stays English.
    local function option_text(menu,key,bytes)
        if (tonumber(menu.version) or 1)>=2 then return function() return tr(key) end end
        local value=tr(key)
        return #value<=bytes and value or tr.english[key]
    end
    local function register_depth_option()
        local menu=rawget(_G,'ModOptionsMenu')
        if type(menu)~='table' or menu.api~=1 then return 'not installed' end
        local registered,reason=menu.register_option(DEPTH_OPTION,{type='slider',
            label=option_text(menu,'option.depth.label',64),mod=option_text(menu,'option.mod',40),
            min=patch.MIN_WATER_DEPTH,max=patch.SWIM_DEPTH,step=0.05,default=patch.MIN_WATER_DEPTH,
            description=option_text(menu,'option.depth.description',400)})
        if not registered then return 'not registered: '..tostring(reason) end
        patch.set_max_water_depth(menu.get(DEPTH_OPTION))
        menu.on_change(DEPTH_OPTION,function(depth) patch.set_max_water_depth(depth) end)
        return 'registered'
    end
    -- One registration attempt; a failing menu must never reach the game's
    -- update chain.
    local function attempt_registration()
        state.menu_attempts=state.menu_attempts+1
        local called,result=pcall(register_depth_option)
        state.depth_option=called and result or 'failed: '..tostring(result)
    end
    -- Without the loader's after_startup (below), the registration runs on the
    -- first update, then again when the menu's API table or its revision has
    -- changed (a menu that loaded late or was replaced, or one that may now
    -- accept what it refused): looked at every MENU_FRAMES updates, at most
    -- MENU_ATTEMPTS registrations in all. Once registered, or out of attempts,
    -- nothing about the menu runs per frame.
    local MENU_ATTEMPTS,MENU_FRAMES,UNSEEN=8,30,{}
    local menu_watch,menu_wait,menu_seen,menu_revision=true,0,UNSEEN,nil
    local function menu_changed()
        local menu=rawget(_G,'ModOptionsMenu')
        local revision=type(menu)=='table' and rawget(menu,'revision') or nil
        if menu==menu_seen and revision==menu_revision then return false end
        menu_seen,menu_revision=menu,revision
        return true
    end
    local function watch_menu()
        if not menu_changed() then return end
        attempt_registration()
        menu_watch=state.depth_option~='registered' and state.menu_attempts<MENU_ATTEMPTS
        report(state.status,state.active,true)
    end
    -- A loader whose capabilities include after_startup (Bingus Shared Loader
    -- v19) runs this once, after every mod of this startup has started (Mod
    -- Options Menu too, whatever the manager's order) and before the first
    -- update. The slider registers there, once; the menu is not watched on any
    -- frame. Should the loader refuse the callback, or not run it before the
    -- first update, the retry above takes over as with loader v18 (its watch
    -- stays armed until this runs, and the first update always attempts), and
    -- this does nothing once an attempt was made.
    local function register_after_startup()
        if state.menu_attempts>0 then return end
        menu_watch=false
        state.menu_registration='after_startup'
        attempt_registration()
        report(state.status,state.active,true)
    end
    -- Feature test, never a version comparison: true when the loader took the
    -- callback (it may already have run it, when startup had finished).
    local function use_after_startup()
        local loader=rawget(_G,'CowboyBingusModLoader')
        local tested,accepted=pcall(function()
            local capabilities=loader.capabilities
            if type(capabilities)~='table' or not capabilities.after_startup
                or type(loader.after_startup)~='function' then return false end
            return loader.after_startup(register_after_startup)==true
        end)
        return tested and accepted
    end
    local ok,why=pcall(function()
        local loader=rawget(_G,'CowboyBingusModLoader')
        -- Feature tests, never the internal version: API 1 and open_log (v14+).
        assert(type(loader)=='table' and loader.api==1 and type(loader.open_log)=='function',
            'Bingus Shared Loader v14 or newer (API 1 with open_log) is required')
        api=create_api()
        game,exe=api.module('game.dll'),api.module(nil)
        assert(game and exe,'Required modules unavailable')
        assert(api.module_hash(game)==build.game_sha256,'Unsupported game module')
        assert(api.module_hash(exe)==build.exe_sha256,'Unsupported executable')
        assert(type(update)=='function','Game update unavailable')
    end)
    if not ok then report(tostring(why),false,true);return end
    -- Puts back the water record a lease changed (patch.restore checks the
    -- page again) and drops the lease once that worked.
    local function cleanup()
        local called,restored=pcall(patch.restore,api,state.pending)
        if called and restored then state.pending=nil;return true end
        return false
    end
    -- Waiting for a dive. What the last full check found decides the next
    -- checks, which this loader keeps in locals (set by settle):
    -- * the local avatar idle ('dive_ended', no lease or retry): both
    --   boundaries run the patch's idle gate (one read of its dive controller,
    --   no pcall, apply or report; the status stays 'dive_ended'), and the
    --   step boundary runs a full check every GATE_FRAMES-th frame (about 2 s
    --   at 60 FPS) to follow avatar and mission changes. A failed gate runs
    --   the full check at once, which verifies the identity again;
    -- * no mission, local player or local avatar (patch.NO_AVATAR): no dive
    --   can start before one exists, so only every POLL_FRAMES-th step checks
    --   (the ship, loading screens, a dead player);
    -- * anything else (a dive, a lease, a retry, a wait on a dive frame): a
    --   full check at both boundaries, as before.
    -- A patch without idle (the test fakes) is never gated.
    local idle,no_avatar=patch.idle,patch.NO_AVATAR or {}
    local GATE_FRAMES,POLL_FRAMES=120,30
    local gated,gate_left,poll_left,watch_after=false,0,0,false
    local function settle(checked,reason)
        gated=checked and idle~=nil and state.gate_controller~=nil
            and not (state.pending or state.retry_start or state.was_dive)
        gate_left=gated and GATE_FRAMES-1 or 0
        poll_left=checked and not state.pending and no_avatar[reason] and POLL_FRAMES-1 or 0
        watch_after=(state.pending or state.retry_start or state.gate_controller) and true or false
    end
    -- A refusal (false and a reason) stops the mod at once; the guard then
    -- runs stop below, which restores. An error goes on to the guard, which
    -- counts it: 8 in a burst stop the mod the same way, and the next check
    -- is a full one. apply still runs under pcall, as in every release:
    -- called directly, its own entry would compile too (about 1.3 KB more of
    -- the shared code cache, offline in the game's lua51.dll) for no
    -- measurable time.
    local function check()
        local called,accepted,reason,active=pcall(patch.apply,api,game,exe,state)
        if not called then settle(false);error(accepted,0) end
        if not accepted then guard.stop(reason);return end
        settle(true,reason)
        report(reason,active==true)
    end
    -- Before the game's update, every frame while the mod runs.
    local function step()
        if menu_watch then
            menu_wait=menu_wait-1
            if menu_wait<=0 then menu_wait=MENU_FRAMES;watch_menu() end
        end
        if poll_left>0 then poll_left=poll_left-1;return end
        if gate_left>0 then
            gate_left=gate_left-1
            if idle(api,state) then return end
        end
        check()
    end
    -- The after-update boundary is checked while a lease or retry is in
    -- progress or a local avatar exists (then usually the idle gate's one
    -- read). Which boundary first sees a new dive is unknown
    -- (docs/TECHNICAL.md), so both watch whenever a dive can start; without
    -- a local avatar none can start before the next update.
    local function after()
        if not watch_after then return end
        if gated and idle(api,state) then return end
        check()
    end
    -- Once: a refusal, 8 errors in a burst or a failed pause stopped the mod,
    -- or the game shuts down. The shutdown status keeps the first failure,
    -- including an update below that raised just before it.
    local function stop(reason)
        local restored=cleanup()
        if reason~='shutdown' then report(reason..(restored and '' or '; restore_failed'),false,true);return end
        local failure=guard.status.first_failure
        report((restored and 'stopped' or 'restore_failed')..(failure and ' after: '..failure or ''),false,true)
    end
    -- An update below this mod raised (the game's or another mod's): restore
    -- as stop does and start afresh, as when the mod loads; the session counts
    -- and the game.dll constants verified this session stay. The guard skips
    -- this mod until the updates below have returned on 60 frames in a row.
    -- A restore that fails raises, and the guard stops the mod instead.
    local function pause(reason)
        if not cleanup() then error('restore_failed',0) end
        state.retry_start,state.was_dive=false,false
        state.gate_controller,state.key,state.write_check=nil,nil,nil
        settle(false)
        report('paused: '..reason,false,true)
    end
    -- These run every frame (the menu watch every 30th while unregistered)
    -- and stay interpreted, as this loader's did before (its traces aborted
    -- in report): compiled they took 2-4 KB more of the LuaJIT code cache
    -- every mod and the game share, for no measurable time (offline in the
    -- game's lua51.dll). The patch's checks still compile.
    if jit and jit.off then
        for _,fn in ipairs({report,settle,check,step,after,watch_menu,menu_changed}) do jit.off(fn) end
    end
    -- The previous update runs outside pcall, so its errors reach the caller
    -- unchanged (value and traceback); every argument and value passes through.
    ok,why=pcall(function()
        guard=runtime.guard({name='ShallowWaterDiving',step=step,after=after,stop=stop,pause=pause,
            log=guard_line,env=_G}).install()
    end)
    if not ok then report(tostring(why),false,true);return end
    report('waiting_for_mission',false,true)
    -- After the status exists: a loader whose startup has finished runs the
    -- callback at once, and its report needs it.
    use_after_startup()
end

end)()
local locales = {bundled = {}}
locales.en = (function()
-- Shallow Water Diving: English texts, the source of every translation.
-- Translators: see TRANSLATING.md. These show in Mod Options Menu, which
-- upper-cases the mod name.
return {
    mod = 'shallow_water_diving',
    title = 'Shallow Water Diving',
    language = 'en',
    strings = {
        -- The mod's name: its category button in Mod Options Menu.
        ['option.mod'] = 'Shallow Water Diving',
        -- The slider's name.
        ['option.depth.label'] = 'Max Dive Water Depth',
        -- Shown beside the slider. 0.20 and 1.30 are the slider's ends, in the game's units.
        ['option.depth.description'] = 'Deepest water, measured up from your feet, that a dive can start in: from 0.20 (lower shin, the original limit) up to 1.30, where your Helldiver starts swimming. Deeper water always keeps the game\'s normal behavior.',
    },
    -- Mod Options Menu's limits, in characters.
    limits = {['option.mod'] = 40, ['option.depth.label'] = 64, ['option.depth.description'] = 400},
}

end)()
install_loader(function() return create_api(runtime, runtime_write.extend(runtime_memory.new(runtime))) end, patch, {revision = 'data-v3.10.1-26088801', exe_sha256 = '0ACC07DEBE04714AE04281E1A66BD2EB9D3D85232953E32A93C8A3DD0874EABE', game_sha256 = '6D1D4D3BC6FC84801D9F8F1B310E13A603D07409F3D9495D74B42E1D0BB1C08F'}, text, locales, runtime)
