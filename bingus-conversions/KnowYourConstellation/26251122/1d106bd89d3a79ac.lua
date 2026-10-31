local text = (function(...)
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
local create_api = (function(...)
return function()
    local ffi = require('ffi')
    assert(ffi.abi('64bit'), 'Windows x64 is required')
    -- Every Windows function has a private name, an __asm__ label naming the
    -- real export. ffi.cdef keeps the first prototype declared for a name in the
    -- whole game and ignores later ones without an error, so a mod that declared
    -- a real name first would decide how this mod calls it, and this mod's
    -- declarations would decide it for every mod loaded later.
    -- Memory is addressed by plain numbers: the memory read takes its address
    -- and destination as uint64_t (the same register as a pointer on x64) and
    -- reports its SIZE_T count as two 32-bit words, so a read creates no
    -- pointer or 64-bit cdata. Module files are hashed by the shared runtime
    -- (bingus_memory.lua), once per session for every mod.
    ffi.cdef [[
        void *hd2kyc_GetModuleHandleA(const char *name) __asm__("GetModuleHandleA");
        void *hd2kyc_GetCurrentProcess(void) __asm__("GetCurrentProcess");
        int hd2kyc_ReadProcessMemory(void *process, uint64_t address, uint64_t buffer, size_t size,
                                     uint32_t *done) __asm__("ReadProcessMemory");
    ]]
    local kernel = ffi.load('kernel32')
    local read_memory = kernel.hd2kyc_ReadProcessMemory
    local process = kernel.hd2kyc_GetCurrentProcess()
    local done = ffi.new('uint32_t[2]')
    local api = {}

    -- The module's base address as a number, or nil.
    function api.module(name)
        local handle = kernel.hd2kyc_GetModuleHandleA(name)
        if handle == nil then return nil end
        return tonumber(ffi.cast('uintptr_t', handle))
    end

    local function copy(address, size, destination)
        return read_memory(process, address, destination, size, done) ~= 0 and done[0] == size and done[1] == 0
    end
    -- Reads size bytes at a number address; nil when they cannot all be read.
    -- read(address, size, into, offset) copies them into a buffer the caller
    -- keeps, into = {data = uint8_t array, address = its address as a number,
    -- size = its length}, at offset and returns true: nothing is allocated.
    -- read(address, size) returns them as a string from one scratch buffer.
    local scratch, scratch_address, scratch_size = nil, nil, 0
    function api.read(address, size, into, offset)
        if into then
            offset = offset or 0
            if size <= 0 or offset < 0 or offset + size > into.size then return nil end
            return copy(address, size, into.address + offset) or nil
        end
        if size > scratch_size then
            scratch_size = math.max(size, 256)
            scratch = ffi.new('uint8_t[?]', scratch_size)
            scratch_address = tonumber(ffi.cast('uintptr_t', scratch))
        end
        if not copy(address, size, scratch_address) then return nil end
        return ffi.string(scratch, size)
    end
    return api
end

end)(text)
local runtime = (function(...)
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

end)(text)
local runtime_memory = (function(...)
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

end)(text)
local resolve = (function(...)
-- The constellation draw and the tag rules, as the game resolves them. Runs on
-- the 0.5 s refresh only, interpreted, and allocates nothing when the caller
-- passes the lists to fill.
local ffi = require('ffi')
local bit = require('bit')
local M = {}
local float = ffi.new('float[1]')
local NONE = {}
local WORD = 4294967296
-- The native draw is a 64-bit linear congruential generator: state = state *
-- multiplier + increment (mod 2^64), and each draw uses the state's high 32
-- bits. The state is kept as its two 32-bit words in plain numbers, every
-- partial product exact in a double, so a draw creates no 64-bit cdata.
local MULTIPLIER_HIGH, MULTIPLIER_LOW = 0x5851F42D, 0x4C957F2D
local INCREMENT_HIGH, INCREMENT_LOW = 0x14057B7E, 0xF767814F

function M.f32(value)
    float[0] = value
    return tonumber(float[0])
end

function M.add(tags, tag)
    if not tag or tag == 0 then return end
    assert(tag >= 1 and tag <= 32, 'Unknown enemy tag')
    for _, value in ipairs(tags) do if value == tag then return end end
    assert(#tags < 16, 'Too many enemy tags')
    tags[#tags + 1] = tag
end

-- (a * b) mod 2^32 for 32-bit a and b, exact in doubles (no 64-bit cdata).
local function mul32(a, b)
    local low = a % 65536
    return (low * b + (a - low) / 65536 * b % 65536 * 65536) % 4294967296
end

-- a * b for 32-bit a and b, as its high and low 32-bit words: 16-bit partial
-- products, each exact in a double.
local function mul64(a, b)
    local a0, b0 = a % 65536, b % 65536
    local a1, b1 = (a - a0) / 65536, (b - b0) / 65536
    local middle = a1 * b0 + a0 * b1
    local low = a0 * b0 + middle % 65536 * 65536
    local carry = low >= WORD and 1 or 0
    return a1 * b1 + (middle - middle % 65536) / 65536 + carry, low - carry * WORD
end

-- The generator's next state from (high, low): its high and low words.
-- Public so the tests can check every state against uint64_t arithmetic.
local function step(high, low)
    local product_high, product_low = mul64(low, MULTIPLIER_LOW)
    local sum_low = product_low + INCREMENT_LOW
    local carry = sum_low >= WORD and 1 or 0
    local sum_high = product_high + mul32(high, MULTIPLIER_LOW) + mul32(low, MULTIPLIER_HIGH) + INCREMENT_HIGH + carry
    return sum_high % WORD, sum_low - carry * WORD
end
M.step = step

-- The list, emptied.
local function emptied(list)
    for i = #list, 1, -1 do list[i] = nil end
    return list
end

-- A candidate row takes part in the draw when it names a tag and, if it is
-- only for missions without tags, no tag came before the draws.
local function drawable(row, empty)
    return row.id ~= 0 and (not row.only_when_empty or empty)
end

-- The drawable rows' count and their float32 weight total. Every row's
-- weight is checked, drawable or not.
local function weights(candidates, empty)
    local count, total = 0, 0
    for _, row in ipairs(candidates) do
        assert(row.weight >= 0 and row.weight < math.huge, 'Invalid constellation weight')
        if drawable(row, empty) then
            count, total = count + 1, M.f32(total + row.weight)
        end
    end
    return count, total
end

-- The tag of the first drawable row whose float32 running weight reaches
-- target, or nil.
local function pick(candidates, empty, target)
    local cumulative = 0
    for _, row in ipairs(candidates) do
        if drawable(row, empty) then
            cumulative = M.f32(cumulative + row.weight)
            if cumulative >= target then return row.id end
        end
    end
    return nil
end

-- Whether one of the blockers before the first 0 is among the tags.
local function blocked(tags, blockers)
    for _, blocker in ipairs(blockers) do
        if blocker == 0 then return false end
        for _, tag in ipairs(tags) do
            if tag == blocker then return true end
        end
    end
    return false
end

-- The tags a mission's 32-bit seed draws: the initial tags, `settings.draws`
-- weighted draws among the candidates, then the fallback unless a blocker is
-- among them. Fills `into` (emptied first; a new table when none is given).
function M.base(seed, settings, initial, into)
    local tags = emptied(into or {})
    for _, tag in ipairs(initial or NONE) do M.add(tags, tag) end
    local candidates, empty = settings.candidates, #tags == 0
    local count, total = weights(candidates, empty)
    assert(settings.draws >= 0 and settings.draws <= 16, 'Invalid draw count')
    assert(seed >= 0 and seed < WORD and seed % 1 == 0, 'Invalid mission seed')
    local high, low = 0, seed
    for _ = 1, settings.draws do
        if count == 0 or total <= 0 then break end
        high, low = step(high, low)
        M.add(tags, pick(candidates, empty, M.f32(M.f32(M.f32(high) * 2^-32) * total)))
    end
    if not blocked(tags, settings.blockers) then M.add(tags, settings.fallback) end
    return tags
end

local function mix(value, word)
    local mixed = mul32(word, 1540483477)
    mixed = mul32(bit.bxor(mixed, bit.rshift(mixed, 24)) % 4294967296, 1540483477)
    return bit.bxor(mixed, mul32(value, 1540483477)) % 4294967296
end

function M.exclusion_key(hash)
    local value = mix(3781555287, 3964548889)
    -- Without a hash only the fixed word is mixed in (as an ipairs over both stopped).
    if hash == nil then return value end
    return mix(value, hash)
end

-- Keep authored catalogue IDs stable after native tag 1 was inserted in build 25480438.
function M.from_native(tag)
    assert(tag >= 0 and tag <= 32, 'Unknown native enemy tag')
    if tag == 1 then return 31 end
    if tag == 12 then return 32 end
    return tag > 12 and tag - 2 or tag > 1 and tag - 1 or 0
end

-- The tags neither excluded (one tag, or a set) nor disabled, in order. Fills
-- `into` (emptied first; a new table when none is given; never `tags`).
function M.filter(tags, excluded, disabled, into)
    assert(into == nil or into ~= tags, 'Filter into its own input')
    local result = emptied(into or {})
    for _, tag in ipairs(tags) do
        if not (type(excluded)=='table' and excluded[tag] or tag==excluded) and not disabled[tag] then M.add(result, tag) end
    end
    return result
end

-- Every function here runs only on the 0.5 s refresh: kept interpreted, they
-- add no traces to the game's shared LuaJIT code cache.
if jit and jit.off then
    for _, fn in ipairs({M.f32, M.add, mul32, mul64, step, emptied, drawable, weights, pick, blocked, M.base, mix,
                         M.exclusion_key, M.from_native, M.filter}) do
        jit.off(fn)
    end
end

return M

end)(text)
local mission = (function(...)
-- Reads the highlighted mission's inputs the way the game resolves them. Every
-- read lands in a buffer this reader keeps and its fields decode in place:
-- addresses are plain numbers, pointers decode from their bytes, and the
-- tables a refresh fills are reused, so neither the per-frame checks nor the
-- 0.5 s refresh allocate.
local ffi = require('ffi')
local bit = require('bit')
local M = {}

-- Expected transient states, while the game builds or switches screens, are
-- raised as constant tables {pending = reason, status = 'hidden: ' .. reason}:
-- a waiting frame builds no string, and the installer hides and retries on the
-- next frame without counting the frame toward stopping the mod (as v4.0 did
-- for every raised frame). Everything else raises a string and counts.
local function pending(reason) return {pending = reason, status = 'hidden: ' .. reason} end
local DATA_UNAVAILABLE = pending('Mission data unavailable')
local POINTER_UNAVAILABLE = pending('Mission pointer unavailable')
local NOT_READY = pending('Mission descriptor not ready')
local NO_MISSION = pending('No highlighted mission')
local NO_BRIEFING = pending('Briefing descriptor unavailable')
local NO_OWNER = pending('Briefing owner unavailable')
M.PENDING = {DATA_UNAVAILABLE, POINTER_UNAVAILABLE, NOT_READY, NO_MISSION, NO_BRIEFING, NO_OWNER}
-- An error's text for the unresolved list.
local function describe(why)
    if type(why) == 'table' and why.pending then return why.pending end
    return tostring(why)
end

local function u16(b, at) return b[at] + b[at + 1] * 256 end
local function u32(b, at) return b[at] + b[at + 1] * 256 + b[at + 2] * 65536 + b[at + 3] * 16777216 end
-- The user-mode pointer stored at b[at] (little-endian), or nil.
local function pointer_at(b, at)
    if b[at + 6] ~= 0 or b[at + 7] ~= 0 then return nil end
    local value = u32(b, at) + (b[at + 4] + b[at + 5] * 256) * 4294967296
    if value < 0x10000 or value >= 0x800000000000 then return nil end
    return value
end
-- (a * b) mod 2^32 for 32-bit a and b, exact in doubles.
local function mul32(a, b)
    local low = a % 65536
    return (low * b + (a - low) / 65536 * b % 65536 * 65536) % 4294967296
end
local function clear(t)
    for key in pairs(t) do t[key] = nil end
end
-- A buffer reads land in: {data = uint8_t array, address = number, size}.
local function buffer(size)
    local data = ffi.new('uint8_t[?]', size)
    return {data = data, address = tonumber(ffi.cast('uintptr_t', data)), size = size}
end

-- Descriptor bytes that make up a mission's identity (seed, secondary seed,
-- faction, difficulty, planet, mission type).
local IDENTITY = {0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 12, 13, 14, 15, 26, 27}
local LAYOUTS = {[1] = {1097440, 1253440, 100}, [2] = {1253448, 1409448, 100}, [3] = {1409456, 1487456, 50}}
local CANDIDATES = {[2] = 276, [3] = 372, [4] = 468}
local FALLBACKS = {[2] = 564, [3] = 600, [4] = 636}
local CONFIG_MAPS = {73848, 49232}
-- The additional HordeOnly tag's marker in a mission record (+0x360).
local HORDE_MARKER = {73, 120, 130, 127, 209, 44, 124, 133}

-- Whether a and b hold the same NUL-terminated text at their start, compared
-- like matching '^([^%z]+)%z' on both: an empty or unterminated text never
-- matches.
local function text_length(b, size)
    for i = 0, size - 1 do
        if b[i] == 0 then return i > 0 and i or nil end
    end
    return nil
end
local function same_text(a, b, size)
    local n = text_length(a, size)
    if not n or text_length(b, size) ~= n then return false end
    for i = 0, n - 1 do
        if a[i] ~= b[i] then return false end
    end
    return true
end
local function same_bytes(a, b, size)
    for i = 0, size - 1 do
        if a[i] ~= b[i] then return false end
    end
    return true
end

-- A float decoder: the bits go in and the float comes out of one union cell.
-- Bytes stored through a second, differently typed view of a cell read back
-- stale in compiled code (LuaJIT's alias analysis treats the views as
-- independent). Declared on first use, under a private name.
local function float_decoder()
    if not pcall(ffi.typeof, 'hd2kyc_float_bits') then
        ffi.cdef('typedef union { uint32_t bits; float value; } hd2kyc_float_bits;')
    end
    local cell = ffi.new('hd2kyc_float_bits')
    return function(b, at)
        cell.bits = u32(b, at)
        return cell.value
    end
end

function M.new(api, game, resolve)
    local self = {api=api, game=game, resolve=resolve}
    local f32 = float_decoder()
    local scratch, bulk = buffer(128), buffer(53248)
    local descriptor_bytes, loaded_bytes, recheck_bytes = buffer(200), buffer(200), buffer(200)
    local advertised_bytes, packet_bytes = buffer(512), buffer(512)
    local settings_bytes, config_bytes, hash_bytes = buffer(816), buffer(896), buffer(132)
    local static_bytes, dynamic_bytes, operation_bytes = buffer(280), buffer(304), buffer(92)
    local header_bytes, mods_bytes, selection_bytes, map_bytes = buffer(24), buffer(1024), buffer(168), buffer(24)
    -- Tables each refresh fills again (never returned).
    local hashes, hash_by_id, initial, drawn, disabled, exclusion = {}, {}, {}, {}, {}, {}
    local by_id, by_hash, weight_family, weight_factor = {}, {}, {}, {}
    local settings_table = {candidates = {}, blockers = {}}
    for i = 1, 8 do settings_table.candidates[i] = {} end

    -- The bytes at address in `into` (default: the scratch buffer, for fields
    -- decoded before the next read). Memory that cannot be read is pending:
    -- the game rebuilds these records while screens change.
    local function read(address, size, into)
        into = into or scratch
        assert(size > 0 and size <= into.size, 'Mission read bound exceeded')
        if not api.read(address, size, into, 0) then error(DATA_UNAVAILABLE) end
        return into.data
    end
    local function ptr(address)
        local address_value = pointer_at(read(address, 8), 0)
        if not address_value then error(POINTER_UNAVAILABLE) end
        return address_value
    end
    local function count(address, maximum)
        local value = u32(read(address, 4), 0)
        assert(value <= maximum, 'Mission array bound exceeded')
        return value
    end

    -- 'map' or 'briefing' when one of them is on top of the UI screen stack.
    -- No UI state yet (while the game starts) is no forecast screen, not an
    -- error: errors now count toward stopping the mod.
    local function top_screen(state)
        local n = u32(state, 20)
        if n < 1 or n > 5 then return nil end
        local top = u32(state, 4 * (n - 1))
        if top == 15 then return 'map' end
        if top == 14 then return 'briefing' end
        return nil
    end
    -- The UI manager the last screen() found: the idle gate reads its stack
    -- alone until the installer's next full check.
    local kept_manager
    function self:screen()
        local manager = pointer_at(read(game + 0x2E38160, 8), 0)
        kept_manager = manager
        if not manager then return nil end
        return top_screen(read(manager + 0x429c, 24))
    end
    -- The idle gate's one read: true when the kept manager's stack shows
    -- neither screen. False (the caller runs the full frame) when no manager
    -- is kept, the read fails or a forecast screen is on top. Never raises.
    function self:quiet()
        if not kept_manager or not api.read(kept_manager + 0x429c, 24, scratch, 0) then return false end
        return top_screen(scratch.data) == nil
    end
    -- Interpreted: the gate that calls quiet is (install.lua), and a side
    -- trace from a screen change would climb into it and abort. The read
    -- itself still compiles.
    if jit and jit.off then
        jit.off(top_screen)
        jit.off(self.quiet)
    end

    -- The key is built again only when the identity changes.
    local key, key1, key2, key3, key4, key5, key6
    local function key_of(seed, secondary, faction, difficulty, planet, mission)
        if key == nil or seed ~= key1 or secondary ~= key2 or faction ~= key3 or difficulty ~= key4
            or planet ~= key5 or mission ~= key6 then
            key1, key2, key3, key4, key5, key6 = seed, secondary, faction, difficulty, planet, mission
            key = seed .. ':' .. secondary .. ':' .. faction .. ':' .. difficulty .. ':' .. planet .. ':' .. mission
        end
        return key
    end
    local function identity(b, result)
        local faction, difficulty = b[8], b[9]
        if faction < 2 or faction > 4 or difficulty < 1 or difficulty > 10 then error(NOT_READY) end
        local mission = u16(b, 26)
        assert(mission < 256, 'Unknown mission type')
        local seed, secondary, planet = u32(b, 0), u32(b, 4), u32(b, 12)
        result.key = key_of(seed, secondary, faction, difficulty, planet, mission)
        result.seed, result.faction, result.difficulty, result.planet, result.mission =
            seed, faction, difficulty, planet, mission
    end
    -- A loaded descriptor matches when its identity bytes equal the selection's.
    local function same_identity(a, b)
        for i = 1, #IDENTITY do
            if a[IDENTITY[i]] ~= b[IDENTITY[i]] then return false end
        end
        return true
    end

    -- Joinable preview: mirror the native map lookup (0x1036670 / 0x1036710).
    -- A missing operation selection alone does not authorize cached preview
    -- data. The second result distinguishes an ended hover from a selected
    -- mission whose advertised packet or preview is still loading.
    local function joinable_selection(board)
        local selection = read(board + 1548964, 8)
        local id, group = u32(selection, 0), u32(selection, 4)
        if id >= 0x80000000 or group == 0 then
            local session = ptr(game + 0x2CE1C68)
            local fallback = read(session + 5630328, 12)
            if id >= 0x80000000 then id = u32(fallback, 0) end
            if group == 0 then group = u32(fallback, 8) end
        end
        return id, group
    end
    local function joinable_row(board, total, id, group)
        local rows = read(board + 2044424, total * 20, bulk)
        local kind, index
        for i = 0, total - 1 do
            local at = i * 20
            if u32(rows, at + 8) == group and u32(rows, at + 12) == id then
                assert(not kind, 'Ambiguous joinable mission')
                kind, index = u32(rows, at), u32(rows, at + 4)
            end
        end
        return kind, index
    end
    local function joinable_preview(board, root)
        local planet = u32(read(board + 1548956, 4), 0)
        if planet >= 0x80000000 or read(board + 2064401, 1)[0] == 0 then return nil, false end
        local id, group = joinable_selection(board)
        if id >= 0x80000000 or group == 0 then return nil, false end
        local total = count(board + 2053224, 440)
        if total == 0 then return nil, true end
        local kind, index = joinable_row(board, total, id, group)
        local layout = LAYOUTS[kind]
        if not layout then return nil, true end
        local manager = ptr(game + 0x2E381B8)
        if index >= count(manager + layout[2], layout[3]) then return nil, true end
        local record = manager + layout[1] + index * 1560
        if read(record + 1456, 1)[0] == 0 then return nil, true end
        local advertised = read(record + 944, 512, advertised_bytes)
        -- The native preview builder decodes this advertisement into the board
        -- descriptor and loads its canonical packet into the single preview slot.
        if u32(read(board + 4286668, 4), 0) ~= 0 then return nil, true end
        local loaded = read(root + 713528, 512, packet_bytes)
        if not same_text(advertised, loaded, 512) then return nil, true end
        return planet, true
    end

    -- Map: the highlighted local operation, or the hovered joinable mission.
    -- Returns preview_planet, hovered, operation_planet, operation_index.
    local function map_selection(board, root)
        local index = u32(read(board + 1548960, 4), 0)
        if index == 0xffffffff then return joinable_preview(board, root) end
        if index >= 110 then error(NO_MISSION) end
        local selected = read(board + 1012352 + index * 92, 92)
        if selected[52] == 0 then error(NO_MISSION) end
        return nil, nil, u16(selected, 16), index
    end
    -- Briefing: the owner record of the loaded mission.
    local function briefing_address()
        local manager = ptr(game + 0x2CE2040)
        local n = count(manager + 26424, 1024)
        if n == 0 then error(NO_BRIEFING) end
        local rows = read(manager + 26432, n * 16, bulk)
        local selected
        for i = 0, n - 1 do
            if u32(rows, 16 * i + 8) == 237 then
                assert(not selected, 'Ambiguous briefing owner')
                selected = pointer_at(rows, 16 * i)
                if not selected then error(NO_OWNER) end
            end
        end
        if not selected then error(NO_OWNER) end
        return selected + 1072
    end

    -- Fills `result` (a new table when none is given) with the selected
    -- mission's identity and the records a sample reads.
    function self:descriptor(screen, result)
        local root = ptr(game + 0x2CE1508)
        local controller = ptr(root + 0xae308)
        local board = ptr(game + 0x2E38220)
        local address = board + 0x4168d0
        local preview_planet, hovered, operation_planet, operation_index
        if screen == 'briefing' then
            address = briefing_address()
        else
            preview_planet, hovered, operation_planet, operation_index = map_selection(board, root)
            if not preview_planet and not operation_index then return nil, hovered end
        end
        result = result or {}
        local bytes = read(address, 200, descriptor_bytes)
        identity(bytes, result)
        -- The native modifier/stamp path consumes the loaded controller.
        -- A stale controller cannot authorize a full composition forecast.
        result.controller_matches = same_identity(bytes, read(controller + 8, 200, loaded_bytes))
        result.address, result.controller, result.board, result.root = address, controller, board, root
        result.preview_planet = preview_planet
        result.operation_planet, result.operation_index = operation_planet, operation_index
        result.screen = screen
        return result, hovered
    end

    local function settings(snapshot)
        local b = read(game + 0x2C44280 + (snapshot.difficulty - 1) * 816, 816, settings_bytes)
        local start, fallback = CANDIDATES[snapshot.faction], FALLBACKS[snapshot.faction]
        local result = settings_table
        result.draws = u32(b, 272)
        result.fallback = resolve.from_native(u32(b, fallback + 32))
        for i = 0, 7 do
            local at, row = start + i * 12, result.candidates[i + 1]
            row.id, row.weight, row.only_when_empty = resolve.from_native(u32(b, at)), f32(b, at + 4), b[at + 8] ~= 0
            result.blockers[i + 1] = resolve.from_native(u32(b, fallback + i * 4))
        end
        return result
    end

    -- Modifier definitions: enemy tags by ID (category 40), spawn-weight
    -- scales by ID (category 72: one enemy family's groups, native group
    -- weight 0x94a0a0) and the first ID of each hash.
    local function definitions(hashes_now)
        clear(by_id) clear(by_hash) clear(weight_family) clear(weight_factor)
        local defs = ptr(game + 0x2E380D0)
        local dn = count(defs + 53248, 1024)
        if dn == 0 then return end
        local rows = read(defs, dn * 52, bulk)
        for i = 0, dn - 1 do
            local at = i * 52
            local id, category, kind = u32(rows, at), u32(rows, at + 4), u32(rows, at + 24)
            if category == 40 and kind == 13 then
                by_id[id] = assert(hashes_now[u32(rows, at + 28)], 'Unknown campaign enemy tag')
            end
            if category == 72 and kind == 13 and u32(rows, at + 36) == 2 then
                weight_family[id], weight_factor[id] = u32(rows, at + 28), f32(rows, at + 44)
            end
            local hash = u32(rows, at + 8)
            if by_hash[hash] == nil then by_hash[hash] = id end
        end
    end

    -- One campaign modifier: its enemy tag, and its spawn weight once per ID.
    -- zone is the sample's weight table, emptied at the start of each
    -- campaign read; applied holds the IDs applied in that read.
    local zone, applied = nil, {}
    local function apply(id)
        if not id then return end
        resolve.add(initial, by_id[id])
        local family = weight_family[id]
        if family and not applied[id] then
            applied[id] = true
            zone[family] = (zone[family] or 1) * weight_factor[id]
        end
    end
    local function add_ids(b, at, length, maximum)
        assert(length <= maximum, 'Too many campaign modifiers')
        for i = 0, length - 1 do apply(u32(b, at + i * 4)) end
    end
    local function event_modifiers(data, planet, index)
        local event = read(data + 470104 + 2496 * index, 2496, bulk)
        local pn = u32(event, 2480)
        assert(pn <= 32, 'Too many event planets')
        local applies = pn == 0
        for j = 0, pn - 1 do
            if u32(event, 2352 + 4 * j) == planet then applies = true end
        end
        if applies then add_ids(event, 2336, u32(event, 2348), 3) end
    end
    local function planet_modifiers(data, planet, static)
        local selected = read(data + 304 * planet + 286952, 132, bulk)
        add_ids(selected, 0, u32(selected, 128), 32)
        add_ids(static, 184, u32(static, 200), 4)
        for i = 0, count(data + 494868, 4) - 1 do
            local env = read(data + 494696 + i * 44, 44)
            if u32(env, 0) == planet then add_ids(env, 4, u32(env, 36), 8) end
        end
        for i = 0, count(data + 490072, 8) - 1 do event_modifiers(data, planet, i) end
    end

    -- Operation templates: the highlighted local operation's modifier hashes.
    local function find_operation(data, planet, id)
        for i = 0, count(data + 155672, 512) - 1 do
            local operation = read(data + 143384 + 24 * i, 24)
            if u32(operation, 0) == planet and u32(operation, 4) == id then return operation end
        end
        return nil
    end
    local function apply_template(slot)
        local template = ptr(slot)
        local total_mods = count(template + 96, 256)
        if total_mods == 0 then return end
        local list = read(ptr(template + 88), total_mods * 4, mods_bytes)
        for j = 0, total_mods - 1 do apply(by_hash[u32(list, 4 * j)]) end
    end
    local function template_modifiers(board, template_id)
        local header = read(board + 0x1f8908, 24, header_bytes)
        local values, total = pointer_at(header, 0), u32(header, 16)
        assert(total <= 4096, 'Too many operation templates')
        if not values or total == 0 then return end
        local keys = read(assert(pointer_at(header, 8)), total * 4, bulk)
        for i = 0, total - 1 do
            if u32(keys, 4 * i) == template_id then return apply_template(values + 8 * i) end
        end
    end
    local function operation_modifiers(board, data, planet, index)
        local selected = read(board + 1012352 + 92 * index, 92, operation_bytes)
        assert(u16(selected, 16) == planet, 'Operation planet does not match this mission')
        local category = u32(selected, 28)
        if selected[52] == 0 or category >= 14 or read(game + 0x2CA1F40 + 168 * category + 9, 1)[0] == 0 then
            return
        end
        local operation = find_operation(data, u16(selected, 16), selected[24])
        local operation_id = operation and u32(operation, 4)
        operation = operation_id and find_operation(data, planet, operation_id)
        if operation then template_modifiers(board, u32(operation, 8)) end
    end
    local function local_operation(snapshot, board, data, planet)
        local selected_index = u32(read(board + 1548960, 4), 0)
        assert(selected_index <= 110 or selected_index == 0xffffffff, 'Invalid operation selection')
        assert(not snapshot.operation_index or selected_index == snapshot.operation_index,
            'Operation changed during read')
        if not snapshot.preview_planet and selected_index < 110 then
            operation_modifiers(board, data, planet, selected_index)
        end
    end

    -- Global modifiers in scope: type 17 adds an enemy tag; type 15 war
    -- effects scale one family's group weights (native 0x12e3c00).
    local function global_entry(war, globals, at)
        local total = u32(globals, at + 80)
        assert(total <= 5, 'Too many global modifier entries')
        for j = 0, total - 1 do
            local kind = globals[at + 16 * j]
            if kind == 17 then resolve.add(initial, resolve.from_native(u32(globals, at + 16 * j + 4))) end
            if kind == 15 then
                local family = u32(globals, at + 16 * j + 4)
                war[family] = (war[family] or 1) * f32(globals, at + 16 * j + 8)
            end
        end
    end
    -- Fills war (emptied first); returns it, or nil when no effect applies.
    local function war_effects(planet, dynamic, war)
        clear(war)
        local faction, region = u32(dynamic, 36), u32(dynamic, 64)
        local globals = read(ptr(game + 0x2E38278), 32 * 356, bulk)
        for i = 0, 31 do
            local at = i * 356
            local scope, value, filter = globals[at + 84], u32(globals, at + 88), u32(globals, at + 92)
            local applies = scope == 3 or scope == 0 and value == planet
                or scope == 1 and value == region or scope == 2 and value == faction
            if applies and (filter == 0 or filter == faction) then global_entry(war, globals, at) end
        end
        return next(war) and war or nil
    end

    -- Map previews can be on a different planet from the active operation.
    -- Use the advertised planet for remote hovers or the highlighted local
    -- operation's planet. Check its hash before applying campaign inputs.
    local function campaign_planet(snapshot, board, data)
        local planet = snapshot.preview_planet or snapshot.operation_planet or count(board + 1548952, 511)
        local n = count(board + 1197132, 512)
        assert(planet < n, 'Planet data changed')
        if not snapshot.preview_planet and not snapshot.operation_planet then
            assert(u32(read(data + 495200, 4), 0) == planet, 'Planet data changed')
        end
        return planet
    end
    -- The sample keeps its two weight tables (zone_weights, war_weights) and
    -- refills them on every read; zone and war name them while not empty.
    local function campaign(snapshot, hashes_now)
        local board, root = snapshot.board, snapshot.root
        local data = board + 1053752
        local planet = campaign_planet(snapshot, board, data)
        local static = read(data + 280 * planet, 280, static_bytes)
        assert(u32(static, 24) == snapshot.planet, 'Selected planet does not match this mission')
        local dynamic = read(data + 304 * planet + 286752, 304, dynamic_bytes)
        local session = ptr(game + 0x2E38228)
        -- session+92134 (0x167e6): the game reads it as a flag in six places on build 25480438. The old
        -- 92102 was an older build's offset; on 25480438 it held unrelated data (0xa4 in play), which gated
        -- every campaign modifier off, so Hive Worlds never listed Hive Lords.
        local gated = read(session + 92142, 1)[0] ~= 0 or read(root + 4333, 1)[0] ~= 0
            or read(root + 4345, 1)[0] ~= 0
        definitions(hashes_now)
        zone = snapshot.zone_weights or {}
        snapshot.zone_weights, snapshot.war_weights = zone, snapshot.war_weights or {}
        clear(zone) clear(applied)
        if not gated then
            planet_modifiers(data, planet, static)
            local_operation(snapshot, board, data, planet)
        end
        local war = war_effects(planet, dynamic, snapshot.war_weights)
        snapshot.zone, snapshot.war = next(zone) and zone or nil, war
        return true
    end

    local function stamp_address(selection)
        local index, variant = selection[162], selection[161]
        if index == 255 then return nil end
        local owner = assert(pointer_at(selection, 0))
        if u32(selection, 8) ~= 2915250090 then return ptr(owner) end
        if variant == 255 then return nil end
        return ptr(ptr(owner + 40) + 24 * variant + 8) + 456 * index
    end
    local function stamp(snapshot)
        local controller = snapshot.controller
        local level = ptr(controller + 664)
        local explicit = read(level + 9160276, 16)
        local n = u32(explicit, 12)
        assert(n <= 3, 'Too many explicit tags')
        for i = 0, n - 1 do resolve.add(initial, resolve.from_native(u32(explicit, 4 * i))) end
        if not pointer_at(read(controller, 8), 0) or count(level + 18510124, 100000) == 0 then return end
        local address = stamp_address(read(level + 9017008, 168, selection_bytes))
        if address then resolve.add(initial, resolve.from_native(u32(read(address + 208, 4), 0))) end
    end

    local function excluded_in(map, key)
        local header = read(map, 24, map_bytes)
        local capacity, empty, multiplier = u32(header, 8), u32(header, 12), u32(header, 16)
        assert(capacity <= 65536 and (capacity == 0 or bit.band(capacity, capacity - 1) == 0),
            'Unexpected configuration map')
        if capacity == 0 then return false end
        local data = assert(pointer_at(header, 0))
        local product = mul32(key, multiplier)
        for probe = 0, math.min(capacity, 128) - 1 do
            local slot = bit.band(product + probe, capacity - 1)
            local found = u32(read(data + 48 * slot, 4), 0)
            if found == key then return true end
            if found == empty then return false end
        end
        assert(capacity <= 128, 'Configuration lookup bound exceeded')
        return false
    end
    local function excluded_by_config(tag_hash)
        local manager = ptr(game + 0x2E38128)
        local key = resolve.exclusion_key(tag_hash)
        for i = 1, #CONFIG_MAPS do
            if excluded_in(manager + CONFIG_MAPS[i], key) then return true end
        end
        return false
    end

    local function tag_hashes()
        local b = read(game + 0x2069D70, 33 * 4, hash_bytes)
        clear(hashes)
        for i = 0, 32 do
            local hash = u32(b, i * 4)
            local tag = resolve.from_native(i)
            hashes[hash], hash_by_id[tag] = tag, hash
        end
    end
    -- Campaign and level tags into `initial`; true when both resolved.
    local function initial_tags(snapshot, unresolved)
        clear(initial)
        local ok, result = pcall(campaign, snapshot, hashes)
        if not ok then
            clear(initial)
            unresolved[#unresolved + 1] = describe(result)
        end
        local complete = ok and result and snapshot.controller_matches
        if snapshot.controller_matches then
            local good, reason = pcall(stamp, snapshot)
            if not good then unresolved[#unresolved + 1] = describe(reason) end
            complete = complete and good
        else
            unresolved[#unresolved + 1] = 'Hovered mission differs from the loaded mission'
        end
        return complete
    end
    -- Tags the backend configuration disables; false when a lookup failed.
    local function disabled_tags(tags, unresolved)
        clear(disabled)
        local complete = true
        for _, tag in ipairs(tags) do
            local ok, value = pcall(excluded_by_config, hash_by_id[tag])
            if ok then disabled[tag] = value else
                complete = false
                unresolved[#unresolved + 1] = describe(value)
            end
        end
        return complete
    end
    -- Native build 25480438 uses 896-byte mission records, a conditional
    -- additional tag, and eight exclusions (formerly one).
    local function horde_mode(config)
        if config[0x34] ~= 2 then return false end
        for i = 1, #HORDE_MARKER do
            if config[0x35f + i] ~= HORDE_MARKER[i] then return false end
        end
        return true
    end
    local function mission_exclusions(config)
        clear(exclusion)
        for i = 0, 7 do
            local native = u32(config, 0x14 + 4 * i)
            if native ~= 0 then exclusion[resolve.from_native(native)] = true end
        end
    end
    -- The selection, screen and highlighted operation are still the ones read.
    local function unchanged(snapshot, screen)
        if not same_bytes(read(snapshot.address, 200, recheck_bytes), descriptor_bytes.data, 200)
            or self:screen() ~= screen then
            return false
        end
        local board = snapshot.board
        if snapshot.preview_planet and u32(read(board + 1548956, 4), 0) ~= snapshot.preview_planet then
            return false
        end
        if snapshot.operation_index and (u32(read(board + 1548960, 4), 0) ~= snapshot.operation_index
            or u16(read(board + 1012352 + 92 * snapshot.operation_index + 16, 2), 0) ~= snapshot.operation_planet)
            then
            return false
        end
        return true
    end

    -- The full forecast inputs, in `result` (a new table when none is given;
    -- a table passed again is refilled, its lists reused).
    function self:sample(screen, result)
        local snapshot = self:descriptor(screen, result)
        if not snapshot then return nil end
        tag_hashes()
        local unresolved = snapshot.unresolved or {}
        clear(unresolved)
        snapshot.unresolved, snapshot.zone, snapshot.war = unresolved, nil, nil
        local complete = initial_tags(snapshot, unresolved)
        local tags = resolve.base(snapshot.seed, settings(snapshot), initial, drawn)
        local config = read(game + 0x312EB50 + 896 * snapshot.mission, 896, config_bytes)
        if horde_mode(config) then resolve.add(tags, 31) end
        complete = disabled_tags(tags, unresolved) and complete
        mission_exclusions(config)
        snapshot.tags = resolve.filter(tags, exclusion, disabled, snapshot.tags)
        snapshot.complete = complete
        if not unchanged(snapshot, screen) then return nil end
        return snapshot
    end
    -- The 0.5 s refresh stays interpreted: compiled, its row loops would add
    -- traces to the game's shared code cache for a path that runs twice a
    -- second. The per-frame checks (screen, descriptor) and the readers and
    -- decoders they share compile.
    if jit and jit.off then
        for _, fn in ipairs({self.sample, tag_hashes, initial_tags, campaign, campaign_planet, definitions, apply,
                             add_ids, event_modifiers, planet_modifiers, find_operation, apply_template,
                             template_modifiers, operation_modifiers, local_operation, global_entry, war_effects,
                             stamp_address, stamp, excluded_in, excluded_by_config, disabled_tags, horde_mode,
                             mission_exclusions, unchanged, settings, clear}) do
            jit.off(fn)
        end
    end
    return self
end

return M

end)(text)
local roster = (function(...)
-- Eligible enemies and spawn-rate levels for one mission, from roster_data.lua.
-- Mirrors native build 25480438: group builder 0x94be10, group weight
-- 0x94a0a0 with the war-effect clamp 0x12e3c00, tag predicate 0x177e3c0 and
-- replacement chain 0x949b80. Runs once per mission key, never per frame.
local M = {}

local PATROL, GARRISON, REINFORCEMENT, TRAVEL, AIR = 2, 4, 5, 6, 9
-- Air support fires every 300-600 s against 65-200 s patrol timers.
local AIR_RATE = 0.25
-- A unit at 16% of all spawns fills the meter; each halving removes 1.5 ticks.
local FULL, STEP, TICKS = 0.16, 1.5, 10
local PLACEHOLDER = 0.1

local function any(tags, list)
    for i = 1, #list do
        if tags[list[i]] then return true end
    end
    return false
end

local function accepts(tags, required, excluded)
    for i = 1, #excluded do
        if tags[excluded[i]] then return false end
    end
    return #required == 0 or any(tags, required)
end

-- Highest-priority matching rule wins; a later step may not lower the priority.
local function replace(faction, resource, tags, difficulty)
    local priority = -1
    for _ = 1, 5 do
        local best
        for _, rule in ipairs(faction.swaps) do
            if rule[2] == resource and tags[rule[1]] and difficulty >= rule[4] and difficulty <= rule[5]
                and (not best or rule[6] > best[6]) then
                best = rule
            end
        end
        if not best or best[6] < priority then break end
        resource, priority = best[3], best[6]
    end
    return resource
end

-- Eligible unit rows of one family with their displayed name and weight share.
local function members_of(context, family)
    local cached = context.families[family]
    if cached then return cached end
    local faction, tags, difficulty = context.faction, context.tags, context.difficulty
    local list, total = {}, 0
    for _, unit in ipairs(faction.units) do
        local weight = unit[1] == family and unit[3][difficulty] or 0
        if weight > 0 and accepts(tags, unit[4], unit[5]) then
            list[#list + 1] = {faction.resources[replace(faction, unit[2], tags, difficulty)], weight}
            total = total + weight
        end
    end
    for _, entry in ipairs(list) do entry[3] = entry[2] / total end
    context.families[family] = list
    return list
end

local function clamp(value)
    if value < 0 then return 0 end
    if value > 10000 then return 10000 end
    return value
end

local function weight_of(context, group)
    local weight = group[4][context.difficulty] or group[3]
    local zone, war, families = context.zone, context.war, context.faction.families
    if zone or war then
        local product = 1
        if zone then
            for _, member in ipairs(group[10]) do product = product * (zone[families[member[1]]] or 1) end
        end
        for _, member in ipairs(group[10]) do
            if war then product = product * (war[families[member[1]]] or 1) end
            product = clamp(product)
        end
        weight = weight * clamp(product)
    end
    if group[1] == 8 and weight < 0.1 then weight = 0.1 end
    return weight
end

-- Groups the native builder keeps for one pool, as {weight, group}.
local function eligible(context, pool, category)
    local result = {}
    for _, group in ipairs(context.faction.groups) do
        local difficulty = context.difficulty
        if group[1] == pool and (not category or group[2] == category)
            and difficulty >= group[5] and difficulty <= group[6] and group[7] <= 4 and group[8] >= 1
            and (#group[9] == 0 or any(context.tags, group[9])) then
            local weight = weight_of(context, group)
            local complete = weight > 0
            for _, member in ipairs(group[10]) do
                if complete and #members_of(context, member[1]) == 0 then complete = false end
            end
            if complete then result[#result + 1] = {weight, group} end
        end
    end
    return result
end

-- Expected units of each name per weighted draw from a list of groups.
local function draws(context, groups, counts, rate)
    local total = 0
    for _, item in ipairs(groups) do total = total + item[1] end
    for _, item in ipairs(groups) do
        for _, member in ipairs(item[2][10]) do
            local count = member[2] >= 999 and 1 or member[2]
            for _, entry in ipairs(members_of(context, member[1])) do
                if entry[1] > 0 then
                    counts[entry[1]] = (counts[entry[1]] or 0) + rate * item[1] / total * count * entry[3]
                end
            end
        end
    end
end

local function shares(counts)
    local total = 0
    for _, value in pairs(counts) do total = total + value end
    if total <= 0 then return nil end
    local result = {}
    for name, value in pairs(counts) do result[name] = value / total end
    return result
end

-- Patrols: one equal-rate stream per patrol category, plus gated border
-- travelers at the same rate and Illuminate air support at a quarter.
local function patrols(context)
    local counts = {}
    for category = 1, 4 do
        local groups = eligible(context, PATROL, category)
        if #groups > 0 then draws(context, groups, counts, 1) end
    end
    if context.travel then
        local groups = eligible(context, TRAVEL)
        if #groups > 0 then draws(context, groups, counts, 1) end
    end
    local air = eligible(context, AIR)
    if #air > 0 then draws(context, air, counts, AIR_RATE) end
    return shares(counts)
end

-- Garrisons pick a member family by its summed unit weight, then a unit by weight.
-- Groups at a placeholder weight (build 25480438 raised two from 0 to 0.01)
-- are treated as disabled: garrison spawn points also filter by unit masks
-- that are not modelled, and the wiki does not report those units there.
local function garrisons(context)
    local counts = {}
    for _, item in ipairs(eligible(context, GARRISON)) do
        for _, member in ipairs(item[1] >= PLACEHOLDER and item[2][10] or {}) do
            for _, entry in ipairs(members_of(context, member[1])) do
                if entry[1] > 0 then counts[entry[1]] = (counts[entry[1]] or 0) + entry[2] end
            end
        end
    end
    return shares(counts)
end

local function reinforcements(context)
    local counts = {}
    local groups = eligible(context, REINFORCEMENT)
    if #groups > 0 then draws(context, groups, counts, 1) end
    return shares(counts)
end

function M.ticks(share)
    if not share or share <= 0 then return 0 end
    local value = math.floor(TICKS + STEP * math.log(share / FULL) / math.log(2) + 0.5)
    if value < 1 then return 1 end
    if value > TICKS then return TICKS end
    return value
end

local function order(data, share)
    return function(a, b)
        local x, y = share[a] or 0, share[b] or 0
        if x ~= y then return x > y end
        return data.names[a][1] < data.names[b][1]
    end
end

-- Returns {large = {{name, ticks}, ...}, small = {name, ...}} using names indexes.
function M.compute(data, snapshot, zone, war)
    local faction = assert(data.factions[snapshot.faction], 'Unknown faction')
    local difficulty = snapshot.difficulty
    assert(difficulty >= 1 and difficulty <= 10, 'Invalid difficulty')
    local tags = {}
    for _, tag in ipairs(snapshot.tags) do tags[tag] = true end
    local context = {faction=faction, tags=tags, difficulty=difficulty, families={},
        zone=zone and next(zone) and zone or nil, war=war and next(war) and war or nil,
        travel=any(tags, faction.travel)}
    local share, sources = {}, 0
    for _, source in pairs({patrols(context), reinforcements(context), garrisons(context)}) do
        -- Empty sources are nil, so pairs rather than ipairs visits every other one.
        sources = sources + 1
        for name, value in pairs(source) do share[name] = (share[name] or 0) + value end
    end
    local listed = {}
    for name, value in pairs(share) do
        share[name] = value / sources
        if not data.hidden[name] then listed[#listed + 1] = name end
    end
    local extra = {}
    if faction.summoned then
        local commanded = false
        for name in pairs(data.commanders) do commanded = commanded or (share[name] or 0) > 0 end
        if commanded then
            for _, entry in ipairs(members_of(context, faction.summoned)) do
                if entry[1] > 0 and not share[entry[1]] then extra[entry[1]] = true end
            end
        end
    end
    local hive = data.hive_lord
    if tags[hive.tag] and difficulty >= hive.difficulty and not share[hive.name] then extra[hive.name] = true end
    for name in pairs(extra) do listed[#listed + 1] = name end
    table.sort(listed, order(data, share))
    local report = {large={}, small={}}
    for _, name in ipairs(listed) do
        if data.names[name][2] >= 3 then
            report.large[#report.large + 1] = {name, math.max(1, M.ticks(share[name]))}
        else
            report.small[#report.small + 1] = name
        end
    end
    return report
end

-- One-entry cache: the forecast only changes when the mission inputs do.
function M.new(data)
    local self = {computed=0}
    function self:report(snapshot, zone, war)
        local parts = {snapshot.faction, snapshot.difficulty}
        local sorted = {}
        for _, tag in ipairs(snapshot.tags) do sorted[#sorted + 1] = tag end
        table.sort(sorted)
        parts[#parts + 1] = table.concat(sorted, ',')
        for _, map in ipairs({zone or {}, war or {}}) do
            local keys = {}
            for family, value in pairs(map) do keys[#keys + 1] = family .. '=' .. value end
            table.sort(keys)
            parts[#parts + 1] = table.concat(keys, ',')
        end
        local key = table.concat(parts, '|')
        if key ~= self.key then
            self.value = M.compute(data, snapshot, zone, war)
            self.key = key
            self.computed = self.computed + 1
        end
        return self.value, self.key
    end
    return self
end

-- Keep this rarely run code interpreted: it must not add traces to the
-- game's shared LuaJIT code cache.
if jit and jit.off then
    for _, fn in ipairs({any, accepts, replace, members_of, clamp, weight_of, eligible, draws, shares,
                         patrols, garrisons, reinforcements, order, M.ticks, M.compute, M.new}) do
        jit.off(fn, true)
    end
end

return M

end)(text)
local roster_data = (function(...)
-- Generated by gen_roster_data.py from Steam build 26088801 (game.dll 6D1D4D3BC6FC84801D9F8F1B310E13A603D07409F3D9495D74B42E1D0BB1C08F).
-- Unit names follow the Helldivers wiki. Do not edit by hand.
return {
build='26251122',
-- names[i] = {plural display name, wiki size class: 1 small, 2 medium, 3 large, 4 massive}
names={{'Scavengers',1},{'Bile Spitters',1},{'Pouncers',1},{'Warriors',2},{'Hive Guards',2},{'Bile Warriors',2},{'Hunters',1},{'Brood Commanders',3},{'Chargers',3},{'Charger Behemoths',3},{'Bile Spewers',2},{'Bile Titans',4},{'Stalkers',3},{'Nursing Spewers',2},{'Shriekers',1},{'Impalers',3},{'Alpha Commanders',3},{'Alpha Warriors',2},{'Spore Chargers',3},{'Predator Stalkers',3},{'Hive Lords',4},{'Dragonroaches',4},{'Rupture Spewers',2},{'Rupture Warriors',2},{'Rupture Chargers',3},{'Spore Burst Bile Titans',4},{'Spore Burst Warriors',2},{'Spore Burst Hunters',1},{'Spore Burst Scavengers',1},{'Predator Hunters',1},{'Troopers',1},{'Marauders',1},{'Brawlers',1},{'Assault Raiders',1},{'MG Raiders',1},{'Rocket Raiders',1},{'Commissars',1},{'Berserkers',2},{'Devastators',2},{'Heavy Devastators',2},{'Rocket Devastators',2},{'Scout Striders',3},{'Hulk Scorchers',3},{'Hulk Bruisers',3},{'Annihilator Tanks',3},{'Shredder Tanks',3},{'Barrager Tanks',3},{'Factory Striders',4},{'Hulk Obliterators',3},{'Gunships',3},{'Reinforced Scout Striders',3},{'Conflagration Devastators',2},{'Pyro Troopers',1},{'Jet Brigade Devastators',2},{'War Striders',3},{'Vox Engines',4},{'Agitators',2},{'Radicals',2},{'Jet Brigade Troopers',1},{'Jet Brigade MG Raiders',1},{'Jet Brigade Commissars',1},{'Incendiary Rocket Raiders',1},{'Hulk Firebombers',3},{'Incendiary MG Devastators',2},{'Jet Brigade Hulk Scorchers',3},{'Jet Brigade Hulk Bruisers',3},{'Elevated Overseers',2},{'Harvesters',3},{'Watchers',2},{'Overseers',2},{'Voteless',1},{'Stingrays',3},{'Fleshmobs',3},{'Leviathans',4},{'Crescent Overseers',2},{'Veracitors',3},{'Gatekeepers',3},{'Obtruders',2},{'Crushers',3},{'Wretches',2}},
commanders={[8]=true,[17]=true},
hidden={[49]=true},
hive_lord={['tag']=23,['difficulty']=7,['name']=21},
factions={
[2]={
families={3478611010,96305411,137310222,2478129961,1453367020,3603869457,3517152816,957043117,2724699650,2255668545,839087686,1571860610,592702357,1610950166,1837263553,2406941944,1289790787,2519355991,1202601230,769209189,2952114795,112786645,889552243,644868927,2631899986,3953553244,3382434603,3597423533,512390556,333947844,1428114468,1765845365,2939701389,618425675,4197606685},
-- resources[i] = names index, 0 when not displayed
resources={1,1,2,3,4,4,5,6,7,7,8,9,10,11,11,12,13,0,0,14,0,15,0,16,0,17,18,19,20,21,22,23,24,25,26,27,28,29,0,0,0,30},
-- units: {family, resource, weights by difficulty, required tags, excluded tags}
units={{1,1,{1,1,1,0,0,0,0,0,0,0},{},{}},{1,2,{0,0,0,1,1,1,1,1,1,1},{},{}},{2,3,{1,1,1,1,1,1,1,1,1,1},{1},{32}},{3,4,{1,1,1,1,1,1,1,1,1,1},{3},{}},{4,5,{1,1,1,0,0,0,0,0,0,0},{},{}},{4,6,{0,0,0,1,1,1,1,1,1,1},{},{}},{4,7,{0,0,0.05,0.1,0.1,0.15,0.2,0.2,0.3,0.3},{},{}},{4,7,{0,0,0.2,0.4,0.5,0.6,0.8,0.9,1,1},{2},{}},{5,8,{1,1,1,1,1,1,1,1,1,1},{1},{}},{6,7,{1,1,1,1,1,1,1,1,1,1},{},{}},{7,9,{0,1,1,0,0,0,0,0,0,0},{},{}},{7,10,{0,0,0,1,1,1,1,1,1,1},{},{}},{8,11,{1,1,1,1,1,1,1,0,0,0},{},{}},{9,12,{1,1,1,1,1,1,0.6,0.4,0.3,0},{},{}},{9,13,{0,0,0,0,0,0,0.4,0.6,0.7,1},{},{}},{10,14,{1,1,1,1,1,0,0,0,0,0},{1},{32}},{10,15,{0,0,0,0,0,1,1,1,1,1},{1},{32}},{11,16,{1,1,1,1,1,1,1,1,1,1},{},{}},{12,17,{0,0,0,1,1,1,1,1,1,1},{},{}},{13,18,{1,1,1,1,1,1,1,1,1,1},{},{}},{14,19,{1,1,1,1,1,1,1,1,1,1},{},{}},{15,20,{1,1,1,1,1,1,1,1,1,1},{},{}},{16,6,{0,0,0,1,1,1,1,0,0,0},{},{}},{16,7,{0,0,0,1,1,1,1,0.4,0.4,0.3},{2},{}},{17,21,{0,0,0,1,1,1,1,1,1,1},{},{}},{18,22,{1,1,1,1,1,1,1,1,1,1},{},{}},{19,23,{1,1,1,1,1,1,1,1,1,1},{},{}},{16,5,{1,1,1,0,0,0,0,0,0,0},{},{}},{20,24,{0,0,0,0,1,0.2,0.2,0.2,0.3,0.3},{},{}},{21,25,{0,0,0,0,1,1,1,1,1,1},{},{}},{8,26,{0,0,0,0,0,0,0,1,1,1},{},{}},{16,27,{0,0,0,0,0,0,0,1,1,1},{},{}},{9,28,{0,0,0,0,0.3,0.3,0.4,0.5,0.5,0.5},{1},{}},{22,29,{0,0,0,1,1,1,1,1,1,1},{8},{}},{23,30,{0,0,0,0,0,0,1,1,1,1},{},{}},{24,31,{1,1,1,1,1,1,1,1,1,1},{11},{}},{25,32,{0,0,0,0,0,1,1,1,1,1},{10},{}},{26,33,{0,0,0,0,0,1,1,1,1,1},{10},{}},{27,34,{0,0,0,0,0,1,1,1,1,1},{10},{}},{28,35,{0,0,0,0,1,1,1,1,1,1},{9},{}},{29,36,{0,1,1,1,1,1,1,1,1,1},{9},{}},{30,37,{0,1,1,1,1,1,1,1,1,1},{9},{}},{31,38,{0,1,1,1,1,1,1,1,1,1},{9},{}},{32,39,{1,1,1,1,1,1,1,1,1,1},{},{}},{33,40,{0.9,1,1,1,1,1,1,1,1,1},{32},{}},{34,41,{0,0,0,0,1,1,1,1,1,1},{32},{}},{35,22,{1,1,1,1,1,1,1,1,1,1},{},{}}},
-- swaps: {tag, source resource, target resource, min difficulty, max difficulty, priority}
swaps={{1,1,3,1,100,0},{1,2,3,1,100,0},{3,1,4,2,100,0},{3,2,4,2,100,0},{1,6,8,1,100,0},{9,5,36,2,100,2},{9,6,36,2,100,2},{9,1,38,2,100,2},{9,2,38,2,100,2},{9,9,37,2,100,1},{9,10,37,2,100,1},{8,9,42,2,100,2},{8,10,42,2,100,2},{10,12,34,6,100,3},{10,13,34,6,100,3},{10,14,32,6,100,3},{10,5,33,6,100,3},{10,6,33,6,100,3},{10,20,32,6,100,3},{11,16,12,2,100,0},{9,16,35,5,100,1},{32,1,40,2,100,1},{32,2,40,2,100,1},{32,14,41,5,100,1},{32,20,41,5,100,1},{32,15,41,5,100,1}},
-- groups: {pool, patrol category, weight, overrides, min difficulty, max difficulty,
--          min players, max players, required tags, members {family, count}}
groups={{2,1,1,{},1,2,1,4,{},{{1,7}}},{2,1,1,{},1,2,1,4,{},{{4,3},{1,3}}},{2,1,1,{},2,5,1,4,{},{{1,10}}},{2,1,1,{},2,3,1,4,{},{{7,3},{1,4}}},{2,1,1,{},3,4,1,4,{},{{1,3},{4,5}}},{2,1,1,{},4,5,1,4,{},{{7,5},{1,5}}},{2,1,0.4,{},4,6,1,4,{},{{9,1},{1,6}}},{2,1,0.5,{},4,6,1,4,{},{{8,1},{4,2},{1,4}}},{2,1,1,{},5,8,1,4,{},{{1,4},{4,7}}},{2,1,0.2,{},6,7,1,4,{},{{11,1}}},{2,1,0.6,{},7,10,1,4,{},{{8,2},{4,4}}},{2,1,0.8,{},7,10,1,4,{},{{9,1},{4,4},{1,2},{7,2}}},{2,1,1,{},6,10,1,4,{},{{1,4},{7,7}}},{2,1,2.5,{},2,4,1,4,{3},{{1,4},{7,4}}},{2,1,2.5,{},5,10,1,4,{3},{{1,4},{7,8}}},{2,1,1.5,{},3,4,1,4,{2},{{4,5},{1,5}}},{2,1,1.5,{},5,8,1,4,{2},{{4,7},{1,4}}},{2,1,1,{},4,7,1,4,{2},{{9,1},{4,2},{1,4}}},{2,1,1.5,{},3,4,1,4,{5},{{1,5},{4,5}}},{2,1,1.5,{},5,8,1,4,{5},{{1,4},{4,7}}},{2,1,0.7,{},4,7,1,4,{5},{{8,1},{4,3},{1,3}}},{2,1,2.5,{},3,4,1,4,{6},{{15,1},{1,5}}},{2,1,2.5,{},5,7,1,4,{6},{{15,2},{1,5}}},{2,1,2.5,{},8,10,1,4,{6},{{15,4},{1,5}}},{2,1,2.5,{},3,4,1,4,{1},{{10,1},{1,5}}},{2,1,2.5,{},5,7,1,4,{1},{{10,2},{1,6}}},{2,1,2.5,{},8,10,1,4,{1},{{10,5},{1,4}}},{2,1,1.2,{},8,10,1,4,{5},{{8,3},{4,3},{1,2}}},{2,1,0.5,{},8,10,1,4,{2},{{9,2},{4,4},{1,2}}},{2,1,0.3,{},8,10,1,4,{},{{11,1}}},{2,1,0.2,{},6,10,1,4,{},{{20,1}}},{2,1,1.5,{},4,6,1,4,{8},{{7,4},{1,1},{22,1}}},{2,1,1.5,{},7,10,1,4,{8},{{7,5},{22,3}}},{2,1,2.5,{},6,10,1,4,{10},{{26,5},{25,2}}},{2,2,1,{},3,5,1,4,{9},{{29,6},{31,7}}},{2,2,1,{},3,5,1,4,{9},{{30,7},{31,6}}},{2,2,1,{},6,10,1,4,{9},{{29,6},{30,6},{31,6}}},{2,2,1,{},6,10,1,4,{9},{{29,8},{30,5}}},{2,2,0.3,{},8,10,1,4,{9},{{28,1},{31,6},{29,3},{30,2}}},{2,1,2.5,{},5,7,1,4,{32},{{34,2},{33,6}}},{2,1,2.5,{},8,10,1,4,{32},{{34,5},{33,4}}},{2,1,2.5,{},8,10,1,4,{32},{{34,3},{33,10}}},{4,0,0.9,{},1,8,1,4,{},{{1,999}}},{4,0,0.7,{},1,8,1,4,{},{{4,999}}},{4,0,2,{},3,10,1,4,{1},{{10,999}}},{4,0,2,{},2,10,1,4,{1},{{5,999}}},{4,0,0.35,{},6,10,1,4,{},{{11,999}}},{4,0,0.8,{},3,10,1,4,{},{{7,999}}},{4,0,0.5,{},2,10,1,4,{},{{6,999}}},{4,0,0.5,{},4,10,1,4,{},{{9,999}}},{4,0,0.5,{},4,7,1,4,{},{{8,999}}},{4,0,0.75,{},3,10,1,4,{},{{4,999}}},{4,0,0.01,{},1,10,1,4,{},{{15,999}}},{4,0,0.01,{},1,10,1,4,{},{{32,999}}},{4,0,0.25,{},3,3,1,4,{},{{8,999}}},{4,0,1,{},1,10,1,4,{},{{14,999}}},{4,0,2,{},3,10,1,4,{3},{{7,999}}},{4,0,1.4,{},2,10,1,4,{2},{{6,999}}},{4,0,2,{},3,10,1,4,{6},{{15,999}}},{4,0,1.7,{},1,8,1,4,{6},{{1,999}}},{4,0,2,{},1,10,1,4,{5},{{4,999}}},{4,0,1,{},8,10,1,4,{},{{8,999}}},{4,0,0.5,{},7,10,1,4,{5},{{8,999}}},{4,0,0.5,{},6,10,1,4,{},{{20,999}}},{4,0,1,{},1,10,1,4,{1},{{2,999}}},{4,0,1,{},8,10,1,4,{6},{{1,999}}},{4,0,2,{},4,10,1,4,{8},{{22,999}}},{4,0,1,{},6,10,1,4,{10},{{25,999}}},{4,0,1,{},6,10,1,4,{10},{{26,999}}},{5,0,0.01,{},1,3,1,4,{},{{1,3}}},{5,0,0.01,{},4,10,1,4,{},{{4,1},{1,2}}},{5,0,0.01,{},7,10,1,4,{},{{4,2},{1,1}}},{5,0,1,{},1,2,1,4,{},{{1,6}}},{5,0,1,{},1,2,1,4,{},{{4,2}}},{5,0,1,{},3,4,1,4,{},{{7,2}}},{5,0,1,{},3,10,1,4,{},{{1,6}}},{5,0,1,{},3,4,1,4,{},{{4,3}}},{5,0,0.2,{},4,4,1,4,{},{{9,1}}},{5,0,1,{},5,10,1,4,{},{{4,4}}},{5,0,1,{},5,10,1,4,{},{{7,4}}},{5,0,0.3,{},3,4,1,4,{},{{8,1}}},{5,0,0.6,{},5,10,1,4,{},{{8,1},{4,2}}},{5,0,0.4,{},5,7,1,4,{},{{9,1}}},{5,0,0.3,{},8,10,1,4,{9},{{28,1},{31,6}}},{5,0,2.5,{},3,5,1,4,{3},{{7,3}}},{5,0,2,{},6,10,1,4,{3},{{7,5}}},{5,0,2,{},3,6,1,4,{6},{{1,8}}},{5,0,2,{},3,10,1,4,{3},{{1,8}}},{5,0,2,{},3,4,1,4,{2},{{4,3}}},{5,0,2,{},5,10,1,4,{2},{{4,5}}},{5,0,0.3,{},4,10,1,4,{2},{{9,1}}},{5,0,2.5,{},3,4,1,4,{6},{{15,1}}},{5,0,2,{},5,10,1,4,{6},{{15,1},{15,1}}},{5,0,1.8,{},3,4,1,4,{1},{{10,1}}},{5,0,1.8,{},5,10,1,4,{1},{{10,1},{10,1}}},{5,0,0.4,{},8,10,1,4,{},{{11,1}}},{5,0,0.7,{},8,10,1,4,{},{{9,1}}},{5,0,1,{},7,10,1,4,{6},{{1,6}}},{5,0,1.5,{},3,4,1,4,{5},{{4,3}}},{5,0,1.5,{},5,10,1,4,{5},{{4,5}}},{5,0,1,{},7,10,1,4,{7},{{4,2},{7,2}}},{5,0,0.5,{},7,10,1,4,{7},{{8,1},{4,2}}},{5,0,0.3,{},6,10,1,4,{},{{20,1}}},{5,0,0.7,{},4,7,1,4,{8},{{22,1}}},{5,0,1,{},8,10,1,4,{8},{{22,2}}},{5,0,0.7,{},4,7,1,4,{8},{{22,1}}},{5,0,1,{},8,10,1,4,{8},{{22,2}}},{5,0,1,{},3,5,1,4,{8},{{7,3}}},{5,0,1.3,{},6,10,1,4,{8},{{7,5}}},{5,0,1,{},6,10,1,4,{10},{{25,2},{26,3}}},{5,0,0.7,{},6,10,1,4,{10},{{26,2},{27,1}}},{5,0,1,{},6,10,1,4,{9},{{29,4},{30,3}}},{5,0,1,{},4,5,1,4,{9},{{29,3},{30,2}}},{5,0,1,{},3,10,1,4,{9},{{31,10}}},{5,0,1,{},7,10,1,4,{9},{{28,1}}},{5,0,2,{},5,10,1,4,{32},{{34,1},{34,1}}},{5,0,1,{},6,10,1,4,{32},{{34,2},{33,5}}},{5,0,0.4,{},8,10,1,4,{31},{{11,1}}},{5,0,0.5,{},7,10,1,4,{31},{{9,1}}},{5,0,0.3,{},6,10,1,4,{31},{{20,1}}},{5,0,0.2,{},5,10,1,4,{31},{{35,6}}},{6,0,1,{},4,6,1,4,{},{{18,3}}},{6,0,1,{},5,9,1,4,{},{{18,6}}},{6,0,1,{},7,10,1,4,{},{{18,12}}},{6,0,2,{},5,6,1,4,{11},{{24,1}}},{6,0,3,{},7,9,1,4,{11},{{24,1}}},{6,0,2.4,{},10,10,1,4,{11},{{24,1}}}},
travel={11,12},
summoned=16,
},
[3]={
families={1678159601,3192111246,1625228342,2521687525,874245638,4141283163,4155034467,1867408488,1264796786,565587391,498789095,2194729737,1708780433,819295132,2976047544,3857136067,1925535306,1054068826,854147169,1816450187,1671042384,2176809320,437176070,4054604406,3744054757,3132503137,3557177074,3213088485,3216070267},
-- resources[i] = names index, 0 when not displayed
resources={31,31,32,33,34,35,36,37,31,38,39,40,41,42,43,44,45,46,47,48,49,0,0,50,51,48,52,53,54,55,56,57,58,57,58,59,60,61,31,32,35,62,37,43,63,39,41,35,36,64,31,65,66},
-- units: {family, resource, weights by difficulty, required tags, excluded tags}
units={{1,1,{1,1,0.4,0,0,0,0,0,0,0},{},{}},{1,2,{0,0,0.6,1,1,0,0,0,0,0},{},{}},{1,3,{0,0,0,0,0.5,1,1,1,1,1},{},{}},{1,4,{0.25,0.25,0.25,0.25,0.25,0.25,0.25,0.25,0.25,0.25},{},{}},{1,4,{0.4,0.5,0.5,0.5,0.5,0.5,0.5,0.5,0.5,0.5},{13},{}},{1,5,{0,0.5,0.8,0.9,1,1,1,1,1,1},{19},{}},{1,6,{0,0.1,0.2,0.25,0.3,0.35,0.5,0.7,1,1},{},{}},{1,6,{0,0.2,0.3,0.4,0.4,0.4,0.5,0.7,1,1},{14},{}},{1,7,{0,0.1,0.2,0.25,0.3,0.35,0.5,0.7,1,1},{},{}},{1,7,{0,0.2,0.3,0.4,0.4,0.4,0.5,0.7,1,1},{15},{}},{2,1,{1,1,0.5,0,0,0,0,0,0,0},{},{}},{2,2,{0,0,0.5,1,1,0,0,0,0,0},{},{}},{2,3,{0,0,0,0,0.5,1,1,1,1,1},{},{}},{3,4,{1,1,1,1,1,1,1,1,1,1},{},{}},{4,8,{1,1,1,1,1,1,1,1,1,1},{},{}},{5,9,{1,1,1,1,1,1,1,1,1,1},{},{}},{6,6,{1,1,1,1,1,1,1,1,1,1},{},{}},{7,5,{1,1,1,1,1,1,1,1,1,1},{13},{}},{8,7,{1,1,1,1,1,1,1,1,1,1},{},{}},{9,10,{1,1,1,1,1,1,1,1,1,1},{},{}},{10,11,{1,1,1,1,1,1,1,1,1,1},{},{}},{11,12,{1,1,1,1,1,1,1,1,1,1},{},{}},{12,13,{1,1,1,1,1,1,1,1,1,1},{},{}},{13,14,{1,1,1,1,1,1,1,0,0,0},{},{}},{14,15,{1,1,1,1,1,1,1,1,1,1},{},{}},{14,16,{1,1,1,1,1,1,1,1,1,1},{},{}},{14,15,{1,1,1,1,1,1,1,1,1,1},{13},{}},{14,16,{1,1,1,1,1,1,1,1,1,1},{14},{}},{15,15,{1,1,1,1,1,1,1,1,1,1},{},{}},{16,16,{1,1,1,1,1,1,1,1,1,1},{},{}},{17,17,{1,1,1,1,1,1,1,1,1,1},{},{}},{17,18,{1,1,1,1,1,1,1,1,1,1},{},{}},{17,19,{0,0,0,0,0,0,0.3,0.5,0.8,0.8},{},{}},{18,20,{1,1,1,1,1,1,1,1,1,1},{},{}},{19,21,{1,1,1,1,1,1,1,1,1,1},{},{}},{20,22,{1,1,1,1,1,1,1,1,1,1},{},{}},{21,23,{1,1,1,1,1,1,1,1,1,1},{},{}},{22,11,{1,1,1,1,1,1,0.6,0.3,0,0},{},{}},{22,12,{0,0,0.1,0.3,0.4,0.5,0.6,0.8,1,1},{},{}},{22,13,{0,0,0.1,0.3,0.4,0.5,0.6,0.8,1,1},{},{}},{22,12,{0,0,0.3,0.5,0.6,0.7,0.8,0.9,1,1},{14},{}},{22,13,{0,0,0.3,0.5,0.6,0.7,0.8,0.9,1,1},{15},{}},{23,24,{0,0,0,0,1,1,1,1,1,1},{},{}},{13,25,{0,0,0,0,0,0,0,1,1,1},{},{}},{24,26,{1,1,1,1,1,1,1,1,1,1},{},{}},{25,17,{0,0,0,0,1,1,1,1,1,1},{},{}},{25,15,{0,0,0,1,1,1,1,1,1,1},{},{}},{25,10,{0,1,1,1,1,1,1,1,1,1},{},{}},{26,27,{1,1,1,1,1,1,1,1,1,1},{22},{}},{27,28,{1,1,1,1,1,1,1,1,1,1},{22},{}},{28,28,{1,1,1,1,1,1,1,1,1,1},{22},{}},{28,28,{1,1,1,1,1,1,1,1,1,1},{22},{}},{22,29,{0,0,0,0.2,0.2,0.3,0.4,0.5,1,1},{19},{}},{22,29,{0,0,0,0.2,0.2,0.3,0.4,0.5,1,1},{19},{}},{29,30,{0,0,0,0,0,1,1,1,1,1},{},{}},{18,31,{0,0,0,0,0,0,1,1,1,1},{20},{}},{13,32,{1,1,1,1,1,1,1,1,1,1},{20},{}},{13,33,{1,1,1,1,1,1,1,1,1,1},{20},{}},{13,34,{1,1,1,1,1,1,1,1,1,1},{20},{}},{13,35,{1,1,1,1,1,1,1,1,1,1},{20},{}}},
-- swaps: {tag, source resource, target resource, min difficulty, max difficulty, priority}
swaps={{19,2,36,1,100,7},{19,3,36,1,100,7},{19,6,37,1,100,7},{19,4,5,1,100,7},{19,8,38,1,100,7},{19,9,36,1,100,7},{22,1,39,1,100,1},{22,2,40,1,100,1},{22,3,40,1,100,1},{22,6,41,1,100,2},{22,7,42,1,100,2},{22,8,43,1,100,1},{22,4,28,1,100,7},{22,15,44,1,100,5},{22,16,45,1,100,7},{22,11,46,1,100,1},{22,13,47,1,100,1},{22,2,40,1,100,1},{22,48,41,1,100,1},{22,49,42,1,100,1},{22,12,50,1,100,6},{22,51,39,1,100,0},{22,10,27,1,100,7},{19,11,29,1,100,1},{19,15,52,1,100,7},{19,16,53,1,100,5},{15,17,30,6,100,0},{15,18,30,6,100,0},{15,19,30,6,100,0},{13,17,30,6,100,0},{13,18,30,6,101,0},{13,19,30,6,100,0},{19,17,30,6,100,4},{19,18,30,6,100,4},{19,19,30,6,100,3},{20,20,31,7,100,9},{20,26,31,7,100,9},{20,14,32,1,100,9},{20,25,33,1,100,9}},
-- groups: {pool, patrol category, weight, overrides, min difficulty, max difficulty,
--          min players, max players, required tags, members {family, count}}
groups={{2,1,1,{},1,2,1,4,{},{{1,4},{4,1}}},{2,1,3,{},6,8,1,4,{15},{{4,1},{22,4},{1,7}}},{2,1,3,{},6,8,1,4,{14},{{4,1},{22,4},{1,7}}},{2,1,1,{},1,2,1,4,{},{{1,8},{4,1}}},{2,1,3,{},3,5,1,4,{15},{{4,1},{1,7},{22,2}}},{2,1,3,{},3,5,1,4,{14},{{4,1},{1,7},{22,2}}},{2,1,1,{},2,2,1,4,{},{{1,3},{22,1},{4,1}}},{2,1,2,{},6,10,1,4,{17},{{4,1},{13,3},{1,6}}},{2,1,0.7,{},2,3,1,4,{},{{4,1},{9,2}}},{2,1,3,{},3,5,1,4,{17},{{4,1},{13,3},{1,3}}},{2,1,1,{},3,4,1,4,{},{{4,1},{1,6}}},{2,1,2,{},5,7,1,4,{13},{{4,1},{9,5},{7,4}}},{2,1,1,{},3,3,1,4,{},{{22,1},{4,1},{1,5}}},{2,1,2,{},2,4,1,4,{13},{{4,1},{9,3},{1,2}}},{2,1,1,{},3,7,1,4,{},{{4,1},{1,12}}},{2,1,1,{},8,10,1,4,{},{{4,1},{22,5},{1,2}}},{2,1,1,{},3,4,1,4,{},{{4,1},{1,4},{13,2}}},{2,1,0.8,{},7,10,1,4,{},{{4,1},{22,4},{14,1}}},{2,1,0.7,{},3,4,1,4,{},{{4,1},{9,3},{3,2}}},{2,1,0.7,{},5,7,1,4,{},{{4,1},{9,3},{3,4},{22,1}}},{2,1,0.5,{},4,6,1,4,{},{{4,1},{14,1},{1,4}}},{2,1,0.6,{},5,7,1,4,{},{{4,1},{1,6},{13,2},{22,1}}},{2,1,0.6,{},5,7,1,4,{},{{4,1},{1,3},{22,2},{13,1}}},{2,1,0.5,{},5,7,1,4,{15},{{4,1},{16,1},{1,4}}},{2,1,0.5,{},5,7,1,4,{14},{{4,1},{16,1},{1,4}}},{2,1,0.5,{},5,7,1,4,{13},{{4,1},{1,4},{15,1}}},{2,1,1,{},5,10,1,4,{17},{{17,1}}},{2,1,0.8,{},7,10,1,4,{13},{{9,4},{15,2},{4,1},{1,3}}},{2,1,0.7,{},8,10,1,4,{15},{{16,2},{22,4},{4,1},{1,2}}},{2,1,0.7,{},8,10,1,4,{14},{{16,1},{22,5},{4,1},{1,2}}},{2,1,0.8,{},8,10,1,4,{},{{4,1},{1,2},{22,4},{13,1}}},{2,1,1,{},1,3,1,4,{22},{{27,4},{4,1}}},{2,1,1,{},4,7,1,4,{22},{{27,4},{4,1},{26,2}}},{2,1,1,{},8,10,1,4,{22},{{27,4},{4,1},{26,3},{14,2}}},{2,1,0.8,{},6,10,1,4,{13},{{29,1},{4,1},{22,1},{1,3},{9,3}}},{2,1,0.7,{},6,10,1,4,{19},{{29,1},{4,1},{22,3},{1,3}}},{2,1,1.3,{},6,10,1,4,{15},{{29,1},{4,1},{22,3},{1,3}}},{2,1,1,{},3,10,1,4,{20},{{1,4},{22,2},{13,1}}},{2,1,1.4,{},6,10,1,4,{20},{{1,6},{22,3},{13,2}}},{2,1,1.6,{},1,10,1,4,{20},{{1,6},{13,1}}},{2,1,1.2,{},6,10,2,4,{20},{{18,1}}},{2,1,1.2,{},1,10,1,4,{20},{{13,1},{13,1},{13,1},{1,5}}},{2,1,1.2,{},1,10,1,4,{20},{{13,1},{13,1},{1,6}}},{2,1,1,{},6,10,1,4,{20},{{18,1}}},{4,0,1.4,{},1,8,1,4,{},{{1,999}}},{4,0,1,{},2,10,1,4,{14},{{6,999}}},{4,0,2,{},2,10,1,4,{13},{{7,999}}},{4,0,1,{},2,10,1,4,{15},{{8,999}}},{4,0,0.7,{},2,10,1,4,{},{{9,999}}},{4,0,0.9,{},2,10,1,4,{},{{22,999}}},{4,0,1.5,{},3,10,1,4,{14},{{11,999}}},{4,0,1.5,{},3,10,1,4,{15},{{12,999}}},{4,0,1,{},3,10,1,4,{},{{13,999}}},{4,0,0.5,{},4,7,1,4,{},{{14,999}}},{4,0,0.5,{},6,10,1,4,{},{{17,999}}},{4,0,0.4,{},7,10,1,4,{},{{18,999}}},{4,0,0.4,{},1,10,1,4,{},{{19,999}}},{4,0,1,{},1,8,1,4,{13},{{3,999}}},{4,0,0.2,{},1,8,1,4,{},{{4,999}}},{4,0,0.1,{},1,10,1,4,{},{{20,999}}},{4,0,0.1,{},1,10,1,4,{},{{21,999}}},{4,0,2.5,{},3,10,1,4,{17},{{13,999}}},{4,0,2.5,{},2,10,1,4,{13},{{9,999}}},{4,0,0.5,{},5,10,1,4,{13},{{15,999}}},{4,0,0.5,{},5,10,1,4,{15},{{16,999}}},{4,0,0.5,{},5,10,1,4,{14},{{16,999}}},{4,0,1,{},8,10,1,4,{},{{14,999}}},{4,0,0.4,{},7,10,1,4,{17},{{18,999}}},{4,0,1.5,{},1,10,1,4,{19},{{1,999}}},{4,0,0.1,{},1,10,1,4,{},{{1,999}}},{4,0,0.5,{},2,10,1,4,{19},{{22,999}}},{4,0,0.3,{},5,10,1,4,{19},{{14,999}}},{4,0,0.5,{},7,10,1,4,{15},{{29,999}}},{4,0,0.5,{},7,10,1,4,{13},{{29,999}}},{4,0,0.5,{},7,10,1,4,{19},{{29,999}}},{4,0,0.8,{},1,10,1,4,{20},{{1,999}}},{5,0,0.01,{},1,4,1,4,{},{{1,3},{4,1}}},{5,0,0.01,{},5,10,1,4,{},{{4,1},{22,2}}},{5,0,1.5,{},1,2,1,4,{},{{4,1},{1,3}}},{5,0,1,{},2,3,1,4,{},{{22,1}}},{5,0,0.6,{},3,4,1,4,{},{{9,2}}},{5,0,1.3,{},3,5,1,4,{},{{4,1},{1,5}}},{5,0,1,{},3,4,1,4,{},{{13,1}}},{5,0,1,{},4,7,1,4,{},{{22,2}}},{5,0,0.7,{},5,10,1,4,{},{{9,3}}},{5,0,0.9,{},5,10,1,4,{},{{13,1}}},{5,0,0.6,{},5,7,1,4,{},{{14,1}}},{5,0,0.6,{},6,10,1,4,{},{{17,1}}},{5,0,1,{},6,10,1,4,{},{{1,6}}},{5,0,1,{},8,10,1,4,{},{{22,3}}},{5,0,2,{},3,5,1,4,{13},{{9,2},{1,2}}},{5,0,2,{},6,10,1,4,{13},{{9,4},{1,2}}},{5,0,3,{},3,5,1,4,{17},{{13,1},{1,2}}},{5,0,2.5,{},6,10,1,4,{17},{{13,1},{1,3}}},{5,0,0.7,{},6,10,1,4,{17},{{17,1}}},{5,0,3,{},2,3,1,4,{15},{{22,1},{1,2}}},{5,0,3,{},2,3,1,4,{14},{{22,1},{1,2}}},{5,0,3,{},4,6,1,4,{15},{{22,2},{1,2}}},{5,0,3,{},4,6,1,4,{14},{{22,2},{1,2}}},{5,0,3,{},7,10,1,4,{15},{{22,3},{1,2}}},{5,0,3,{},7,10,1,4,{14},{{22,3},{1,2}}},{5,0,0.5,{},5,10,1,4,{15},{{16,1}}},{5,0,0.5,{},5,10,1,4,{14},{{16,1}}},{5,0,0.5,{},5,10,1,4,{13},{{15,1}}},{5,0,0.8,{},8,10,1,4,{},{{14,1}}},{5,0,0.2,{},7,7,2,4,{},{{18,1}}},{5,0,0.3,{},8,10,1,4,{},{{18,1}}},{5,0,0.2,{},7,10,2,4,{17},{{18,1}}},{5,0,1.2,{},5,10,1,4,{19},{{1,6}}},{5,0,0.7,{},2,4,1,4,{19},{{1,3}}},{5,0,1,{},1,4,1,4,{22},{{26,1}}},{5,0,1,{},4,6,1,4,{22},{{26,1},{1,2},{22,1}}},{5,0,1,{},7,10,1,4,{22},{{26,2},{22,2}}},{5,0,1,{},1,4,1,4,{22},{{27,2},{1,3}}},{5,0,1,{},5,10,1,4,{22},{{1,4},{27,3}}},{5,0,1,{},4,10,1,4,{19},{{22,3}}},{5,0,0.5,{},5,10,1,4,{19},{{14,1}}},{5,0,0.4,{},6,10,1,4,{15},{{29,1}}},{5,0,0.3,{},6,10,1,4,{13},{{29,1}}},{5,0,0.3,{},6,10,1,4,{19},{{29,1}}},{5,0,1.1,{},3,10,1,4,{20},{{1,5},{13,1},{22,1}}},{5,0,1.1,{},1,10,1,4,{20},{{13,1},{1,4}}},{5,0,1,{},6,10,2,4,{20},{{18,1}}},{5,0,1.1,{},1,10,1,4,{20},{{13,2},{1,3},{22,2}}},{5,0,1.1,{},2,10,1,4,{20},{{1,2},{8,1},{13,1},{13,1}}},{5,0,1.4,{},8,10,1,4,{20},{{1,2},{11,2},{13,2}}},{6,0,1,{},5,6,1,4,{},{{23,1}}},{6,0,1,{},6,7,1,4,{},{{23,2}}},{6,0,1,{},8,9,1,4,{},{{23,3}}},{6,0,1,{},10,10,1,4,{},{{23,4}}}},
travel={11,21},
},
[4]={
families={3547956525,2686922360,921769811,4187027803,1648726799,2873160530,2347777940,1986520905,2941825161,799891980,3539239690,2069117845,2259428716,3791980,2396746338,3140880209,4235305538,2364407238,2595257766,1337482975,2749287538},
-- resources[i] = names index, 0 when not displayed
resources={67,68,69,70,71,71,71,72,73,74,75,76,77,78,79,80},
-- units: {family, resource, weights by difficulty, required tags, excluded tags}
units={{1,1,{0.1,0.1,0.1,0.2,0.3,0.4,0.4,0.5,0.5,0.5},{},{}},{2,2,{0,0,1,1,1,1,1,1,1,1},{},{}},{3,3,{1,1,1,1,1,1,1,1,1,1},{},{}},{4,4,{1,1,1,1,1,1,1,1,1,1},{},{}},{5,5,{1,1,1,1,1,1,1,1,1,1},{},{}},{5,6,{1,1,1,1,1,1,1,1,1,1},{},{}},{5,7,{1,1,1,1,1,1,1,1,1,1},{},{}},{6,8,{1,1,1,1,1,1,1,1,1,1},{},{}},{7,9,{0,0,0.01,0.1,0.5,0.5,0.6,0.6,0.7,0.7},{},{}},{8,10,{1,1,1,1,1,1,1,1,1,1},{},{}},{9,5,{1,1,1,1,1,1,1,1,1,1},{27},{}},{9,6,{1,1,1,1,1,1,1,1,1,1},{27},{}},{9,7,{1,1,1,1,1,1,1,1,1,1},{27},{}},{9,4,{0.4,0.4,0.5,0.5,0.5,0.6,0.6,0.6,0.7,0.7},{27,26},{}},{9,1,{0,0,0.2,0.3,0.3,0.3,0.3,0.3,0.5,0.5},{27,26},{}},{10,11,{0,0,0.1,0.2,0.3,0.4,0.4,0.4,0.4,0.4},{},{}},{9,11,{0,0,0.1,0.1,0.2,0.2,0.2,0.2,0.3,0.3},{27},{}},{11,5,{1,1,1,1,1,1,1,1,1,1},{27},{}},{11,6,{1,1,1,1,1,1,1,1,1,1},{27},{}},{11,7,{1,1,1,1,1,1,1,1,1,1},{27},{}},{11,4,{0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.2,0.2,0.2},{26,27},{}},{11,1,{0,0,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1},{26,27},{}},{11,11,{0,0,0,0.1,0.1,0.1,0.1,0.1,0.1,0.1},{28,27},{}},{12,4,{1,1,1,1,1,1,1,1,1,1},{},{}},{12,11,{0,0,0.1,0.2,0.3,0.4,0.4,0.4,0.4,0.4},{},{}},{12,1,{0,0,0.1,0.2,0.3,0.4,0.4,0.5,0.5,0.5},{},{}},{13,12,{0,0,0,0.1,0.2,0.2,0.3,0.3,0.4,0.4},{26},{}},{13,13,{0,0,0,0,0.1,0.1,0.1,0.2,0.3,0.3},{26},{}},{14,13,{0,0,0,0,0.1,0.1,0.15,0.2,0.3,0.3},{26},{}},{15,12,{0,0,0,0.1,0.2,0.2,0.3,0.3,0.4,0.4},{26},{}},{9,7,{1,1,1,1,1,1,1,1,1,1},{28,29},{}},{9,5,{1,1,1,1,1,1,1,1,1,1},{28,29},{}},{9,6,{1,1,1,1,1,1,1,1,1,1},{28,29},{}},{16,14,{1,1,1,1,1,1,1,1,1,1},{26},{}},{17,9,{0,0,0,0.3,0.5,0.5,0.6,0.8,0.8,1},{28,29},{}},{11,14,{0.3,0.3,0.3,0.4,0.5,0.5,0.3,0.3,0.3,0.3},{26},{}},{18,15,{1,1,1,1,1,1,1,1,1,1},{29},{}},{19,16,{1,1,1,1,1,1,1,1,1,1},{29},{}},{11,16,{1,1,1,1,1,1,1,1,1,1},{29},{}},{11,4,{0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.2,0.2,0.2},{28},{}},{9,4,{0.4,0.4,0.5,0.5,0.5,0.6,0.6,0.6,0.7,0.7},{28},{}},{9,16,{1,1,1,1,1,1,1,1,1,1},{29},{}},{9,15,{0,0,0,0,1,1,1,1,1,1},{29},{}},{20,2,{0,0,1,1,1,1,1,1,1,1},{26,27,28},{}},{21,1,{0.1,0.1,0.1,0.2,0.3,0.4,0.4,0.5,0.5,0.5},{26,27},{}}},
-- swaps: {tag, source resource, target resource, min difficulty, max difficulty, priority}
swaps={{28,1,11,1,100,2},{28,1,9,5,100,1},{26,11,1,1,100,0}},
-- groups: {pool, patrol category, weight, overrides, min difficulty, max difficulty,
--          min players, max players, required tags, members {family, count}}
groups={{2,3,1,{},2,6,1,4,{28},{{4,1},{5,8}}},{2,1,1,{},6,10,1,4,{28},{{2,1},{5,5}}},{2,3,1,{},3,10,1,4,{28},{{4,1},{5,6}}},{2,1,1,{},4,10,1,4,{27},{{12,2},{5,12}}},{2,3,1,{},4,8,1,4,{28},{{2,1},{4,1},{5,7}}},{2,1,1,{},5,10,1,4,{27},{{12,1},{2,1},{5,10}}},{2,3,1,{},5,10,1,4,{28},{{2,1},{12,1},{5,5}}},{2,1,1,{},3,10,1,4,{27},{{12,2},{5,13}}},{2,1,1,{},6,10,1,4,{27},{{2,1},{12,2},{5,12}}},{2,1,1,{},1,3,1,4,{28},{{5,10}}},{2,1,1,{},2,2,1,4,{27},{{12,1},{5,13}}},{2,1,1,{},5,10,1,4,{27},{{12,1},{5,11}}},{2,3,1,{},4,6,1,4,{28},{{2,1},{5,5}}},{2,1,1,{},7,10,1,4,{28},{{2,1},{5,12}}},{2,4,1,{},1,10,1,4,{26},{{3,1}}},{2,4,1,{},1,10,1,4,{27,28},{{3,1}}},{2,1,1,{},1,10,1,4,{27},{{5,12}}},{2,1,1,{},2,3,1,4,{27},{{5,12},{12,1}}},{2,1,1,{},1,6,1,4,{27},{{12,2}}},{2,1,1,{},7,10,1,4,{27},{{12,5}}},{2,1,1,{},7,8,1,4,{26},{{1,2},{4,1}}},{2,1,1,{},1,2,1,4,{26},{{4,2}}},{2,3,1,{},1,10,1,4,{28},{{5,8}}},{2,1,1,{},3,10,1,4,{27},{{12,1},{7,2},{5,10}}},{2,1,1,{},6,10,1,4,{27},{{12,1},{5,9},{7,2}}},{2,1,0.5,{},5,10,1,4,{27},{{12,1},{7,2},{5,8}}},{2,1,0.5,{},6,10,1,4,{26},{{15,1},{1,1},{4,2}}},{2,1,0.5,{},6,10,1,4,{26},{{15,1},{1,1},{4,1}}},{2,1,0.5,{},7,10,1,4,{26},{{15,2},{1,1},{4,2}}},{2,1,0.5,{},5,10,1,4,{26},{{16,2},{15,1},{4,3}}},{2,1,0.5,{},5,10,1,4,{26},{{4,2},{15,1},{16,2}}},{2,1,0.5,{},5,8,1,4,{26},{{15,1}}},{2,1,0.5,{},8,10,1,4,{26},{{4,3},{15,2}}},{2,1,0.5,{},5,10,1,4,{26},{{15,1},{1,1}}},{2,2,1,{},1,10,1,4,{26},{{16,4}}},{2,1,1,{},3,10,1,4,{26},{{16,4}}},{2,2,1,{},5,10,1,4,{26},{{16,6}}},{2,1,1,{},7,10,1,4,{26},{{16,7}}},{2,2,1,{},1,4,1,4,{26},{{16,6}}},{2,1,1,{},1,3,1,4,{26},{{16,5}}},{2,1,1,{},5,10,1,4,{28},{{5,11},{12,1}}},{2,3,1,{},5,10,1,4,{28},{{5,5},{17,1}}},{2,1,1,{},1,10,1,4,{28},{{5,3}}},{2,3,1,{},1,10,1,4,{28},{{5,8}}},{2,2,1,{},1,10,1,4,{28},{{5,12}}},{2,1,1,{},1,10,1,4,{28},{{5,6}}},{2,3,1,{},1,10,1,4,{28},{{5,7}}},{2,2,1,{},1,10,1,4,{28},{{5,13}}},{2,1,1,{},1,10,1,4,{28},{{5,6}}},{2,3,1,{},1,10,1,4,{28},{{5,8}}},{2,2,1,{},1,10,1,4,{28},{{5,12}}},{2,1,1,{},1,10,1,4,{28},{{5,5}}},{2,3,1,{},1,10,1,4,{28},{{5,10}}},{2,2,1,{},1,10,1,4,{28},{{5,14}}},{2,1,1,{},1,10,1,4,{28},{{5,4}}},{2,3,1,{},1,10,1,4,{28},{{5,7}}},{2,2,1,{},1,10,1,4,{28},{{5,12}}},{2,1,1,{},5,10,1,4,{28},{{17,2},{5,4}}},{2,3,1,{},6,10,1,4,{28},{{17,1},{5,5}}},{2,2,1,{},8,10,1,4,{28},{{5,4},{17,3}}},{2,1,1,{},5,10,1,4,{26},{{16,8}}},{2,1,1,{},7,10,1,4,{26},{{16,12}}},{2,3,1,{},1,10,1,4,{29},{{5,6}}},{2,3,1,{},1,10,1,4,{29},{{5,13}}},{2,3,1,{},3,10,1,4,{29},{{5,9},{19,2}}},{2,3,1,{},1,10,1,4,{29},{{5,9},{19,3}}},{2,2,2,{},1,4,1,4,{29},{{19,2}}},{2,2,2,{},5,10,1,4,{29},{{19,4}}},{2,2,2,{},5,10,1,4,{29},{{19,7}}},{2,2,2,{},4,10,1,4,{29},{{18,1}}},{2,2,2,{},5,10,1,4,{29},{{18,2}}},{2,1,2,{},5,10,1,4,{29},{{18,1},{19,4}}},{2,1,2,{},5,10,1,4,{29},{{18,1},{19,6}}},{2,1,2,{},5,10,1,4,{29},{{18,1},{19,9}}},{2,3,1,{},3,10,1,4,{29},{{5,4},{7,1}}},{2,3,1,{},3,10,1,4,{29},{{5,6},{7,2}}},{2,3,2,{},3,10,1,4,{29},{{19,3},{7,1}}},{2,3,2,{},3,10,1,4,{29},{{19,6},{7,2}}},{2,1,2,{},5,10,1,4,{29},{{19,5}}},{2,4,0.01,{},1,10,1,4,{26},{{16,1}}},{2,4,0.01,{},1,10,1,4,{27,28},{{5,1}}},{4,0,0.8,{},2,10,1,4,{26,27},{{4,999}}},{4,0,1.2,{},1,10,1,4,{29},{{5,999}}},{4,0,0.2,{},6,7,1,4,{26,27},{{2,999}}},{4,0,0.5,{},8,10,1,4,{31},{{2,999}}},{4,0,0.5,{},5,10,1,4,{29},{{7,999}}},{4,0,0.2,{},4,6,1,4,{26},{{15,999}}},{4,0,0.7,{},4,10,1,4,{28,29},{{17,999}}},{4,0,0.6,{},3,10,1,4,{27,28},{{10,999}}},{4,0,0.5,{},4,10,1,4,{27,26},{{1,999}}},{4,0,0.4,{},7,10,1,4,{26},{{15,999}}},{4,0,1,{},5,10,1,4,{29},{{18,999}}},{4,0,1,{},3,10,1,4,{29},{{19,999}}},{4,0,0.8,{},2,10,1,4,{28},{{4,999}}},{4,0,1.2,{},1,10,1,4,{27,28},{{5,999}}},{4,0,0.2,{},6,7,1,4,{28},{{2,999}}},{4,0,0.5,{},5,10,1,4,{27,28},{{7,999}}},{4,0,0.05,{},8,10,1,4,{26},{{15,1}}},{4,0,1,{},1,1,1,4,{26},{{16,1}}},{5,0,1,{},3,4,1,4,{27,28},{{4,1},{5,9}}},{5,0,1,{},4,10,1,4,{27,28},{{4,2},{5,10}}},{5,0,1,{},4,10,1,4,{27,28},{{4,2},{5,11}}},{5,0,1,{},5,10,1,4,{27,28},{{4,2},{5,10}}},{5,0,1,{},6,10,1,4,{27,28},{{4,1},{5,10}}},{5,0,0.5,{},4,10,1,4,{28,27},{{2,1}}},{5,0,1,{},3,6,1,4,{28},{{4,1},{5,12}}},{5,0,0.1,{},6,10,1,4,{28},{{4,1},{5,16}}},{5,0,1,{},6,10,1,4,{27,26},{{2,1}}},{5,0,1,{},4,10,1,4,{28},{{4,2},{5,18}}},{5,0,1,{},2,3,1,4,{27,28},{{4,1},{5,11}}},{5,0,0.5,{},8,10,1,4,{26},{{4,2},{15,1},{14,1}}},{5,0,1,{},3,10,1,4,{27},{{7,2},{12,4},{5,13}}},{5,0,1,{},8,10,1,4,{27},{{12,2},{7,3},{5,13}}},{5,0,0.1,{},4,10,1,4,{28},{{5,8},{2,1},{7,4},{4,1}}},{5,0,1,{},4,8,1,4,{27},{{2,1},{1,1}}},{5,0,1,{},5,10,1,4,{27},{{10,1},{4,2}}},{5,0,0.8,{},4,10,1,4,{27},{{1,1},{10,2}}},{5,0,0.8,{},5,10,1,4,{26},{{14,1},{15,1}}},{5,0,0.5,{},4,10,1,4,{26},{{15,2},{4,2}}},{5,0,0.3,{},5,10,1,4,{26},{{14,1},{1,1},{4,1}}},{5,0,1,{},5,10,1,4,{28},{{5,11},{4,1}}},{5,0,1,{},4,10,1,4,{28,29},{{5,8},{17,4}}},{5,0,1,{},1,10,1,4,{28},{{5,4}}},{5,0,1,{},1,10,1,4,{28},{{5,3}}},{5,0,1,{},1,10,1,4,{28},{{5,4}}},{5,0,1,{},1,10,1,4,{28},{{5,5}}},{5,0,1,{},1,10,1,4,{28},{{5,7}}},{5,0,1,{},1,10,1,4,{28},{{5,8}}},{5,0,0.7,{},1,7,1,4,{26},{{1,1},{4,1}}},{5,0,0.5,{},1,4,1,4,{26},{{16,2},{4,1}}},{5,0,0.5,{},4,10,1,4,{26},{{15,1}}},{5,0,0.4,{},4,10,1,4,{26},{{15,1},{16,4}}},{5,0,0.3,{},7,10,1,4,{26},{{13,1},{16,3}}},{5,0,0.7,{},5,10,1,4,{26},{{16,4},{1,1}}},{5,0,0.3,{},1,10,1,4,{26},{{16,1}}},{5,0,1,{},5,10,1,4,{26},{{16,4},{4,2}}},{5,0,2,{},5,10,1,4,{29},{{18,1}}},{5,0,2,{},5,10,1,4,{29},{{19,5}}},{5,0,2,{},5,10,1,4,{29},{{19,4}}},{5,0,2,{},5,10,1,4,{29},{{18,2}}},{5,0,3,{},5,10,1,4,{29},{{19,5},{18,1}}},{5,0,2,{},5,10,1,4,{29},{{19,4}}},{5,0,0.7,{},7,10,1,4,{26},{{14,1}}},{5,0,0.6,{},5,6,1,4,{26},{{14,1}}},{5,0,0.5,{},4,10,1,4,{26},{{2,1}}},{5,0,1,{},6,10,1,4,{28},{{2,1}}},{5,0,1,{},1,4,1,4,{29},{{19,3}}},{5,0,1,{},1,4,1,4,{29},{{19,2},{5,4}}},{5,0,1,{},3,4,1,4,{29},{{7,1},{19,4}}},{5,0,0.8,{},5,10,1,4,{31},{{20,1}}},{5,0,1,{},8,10,1,4,{31},{{14,1},{21,1},{4,1}}},{5,0,1,{},8,10,1,4,{31},{{20,1},{21,1}}},{6,0,1,{},5,10,1,4,{},{{8,1}}},{9,0,1,{},4,7,2,4,{27},{{6,1}}},{9,0,1,{},8,10,1,4,{27},{{6,1}}},{9,0,0.2,{},7,10,2,4,{27},{{6,2}}}},
travel={11,25},
},
},
}

end)(text)
local model = (function(...)
-- Display model for one mission forecast. Every text comes from
-- locales/en.lua or its translation through `t` (a bingus_text translator:
-- t(key, values)); enemy names are keyed by roster_data.lua's English names.
local M = {}

-- Authored tag IDs (resolve.from_native) to their title keys. Subfactions,
-- strains and operation modifiers use their in-game names; base
-- constellations keep the mod's names.
M.TITLES = {
    [1]='title.bile_bugs', [2]='title.armored_bugs', [3]='title.hunter_swarms', [4]='title.flyer_composition',
    [5]='title.light_bugs', [6]='title.bug_nursery', [7]='title.balanced_terminids',
    [8]='title.predator_strain', [9]='title.spore_burst_strain', [10]='title.rupture_strain',
    [11]='title.dragonroach_activity', [12]='title.roving_shriekers',
    [13]='title.assault_forces', [14]='title.phalanx_forces', [15]='title.artillery_forces',
    [16]='title.air_composition', [17]='title.armored_column', [18]='title.balanced_automatons',
    [19]='title.jet_brigade', [20]='title.cyborg_legion', [21]='title.gunship_patrols',
    [22]='title.incineration_corps', [23]='title.hive_world', [24]='title.illuminate_stragglers',
    [25]='title.leviathan_blockade', [26]='title.appropriators', [27]='title.invasion_fleet',
    [28]='title.mindless_masses', [29]='title.vote_snatchers', [30]='title.seaf_support', [31]='title.horde',
}
local BASE = {[1]=true,[2]=true,[3]=true,[4]=true,[5]=true,[6]=true,[7]=true,
    [13]=true,[14]=true,[15]=true,[16]=true,[17]=true,[18]=true,[24]=true}

-- Text key of an English enemy name: 'MG Raiders' -> 'unit.mg_raiders'.
function M.unit_key(name)
    local key = name:lower():gsub('[^%w]+', '_'):gsub('^_+', ''):gsub('_+$', '')
    return 'unit.' .. key
end

function M.headline(tags, t)
    local modifiers, bases = {}, {}
    for _, tag in ipairs(tags) do
        local key = M.TITLES[tag]
        if key then
            local list = BASE[tag] and bases or modifiers
            list[#list + 1] = t(key)
        end
    end
    for _, title in ipairs(bases) do modifiers[#modifiers + 1] = title end
    return #modifiers > 0 and table.concat(modifiers, t('headline.separator')) or t('headline.standard')
end

-- report = roster report {large={{name, ticks}}, small={name}} with names indexes.
function M.make(snapshot, report, data, t)
    local large, small, parts = {}, {}, {}
    for _, entry in ipairs(report.large) do
        local text = t(M.unit_key(data.names[entry[1]][1]))
        large[#large + 1] = {text=text, ticks=entry[2]}
        parts[#parts + 1] = text .. '=' .. entry[2]
    end
    for _, name in ipairs(report.small) do
        small[#small + 1] = t(M.unit_key(data.names[name][1]))
        parts[#parts + 1] = small[#small]
    end
    local result = {key=snapshot.key, screen=snapshot.screen, complete=true, headline=M.headline(snapshot.tags, t),
        large=large, small=small, label=t('panel.label'), footer=t('panel.footer'), more=t('panel.more'),
        separator=t('panel.list_separator'), large_caption=t('panel.large'), rate_caption=t('panel.rate'),
        small_caption=t('panel.small'), order_caption=t('panel.order')}
    -- Every drawn text is in the signature, so a language change redraws.
    result.signature = table.concat({result.headline, result.label, result.footer, result.more, result.separator,
        result.large_caption, result.rate_caption, result.small_caption, result.order_caption,
        table.concat(parts, '\1')}, '\2')
    return result
end

return M

end)(text)
local panel = (function(...)
-- Forecast panel: a gold-framed box hanging below the native planet,
-- operation or briefing panel (sharing its bottom stroke). It may cover the
-- squad list while a mission is highlighted, so it draws on a high layer; it
-- stops above the bottom prompt row. Beside the native panel is the last
-- resort when even that height is too short. GUI objects are retained:
-- nothing is measured or redrawn unless the report, geometry or font changes,
-- except one text update per frame while a long headline scrolls. Text is
-- UTF-8 in any script: it is measured, wrapped and scrolled by character,
-- never by byte (bingus_text.lua).
local text = assert(..., 'bingus_text required')
local M = {}

-- Expected transient states, while the game builds or switches screens, are
-- raised as constant tables {pending = reason, status = 'hidden: ' .. reason}:
-- a waiting frame builds no string, and the installer hides and retries on the
-- next frame without counting the frame toward stopping the mod (as v4.0 did
-- for every raised frame). Everything else raises a string and counts.
local function pending(reason) return {pending = reason, status = 'hidden: ' .. reason} end
M.PENDING = {
    worlds = pending('UI worlds unavailable'),
    gui = pending('Could not create forecast panel'),
    material = pending('Font material unavailable'),
    metrics = pending('Font metrics unavailable'),
    caret = pending('Font caret unavailable'),
    rect = pending('Retained rectangle unavailable'),
    text = pending('Retained text unavailable'),
    native = pending('Native panel unavailable'),
    viewport = pending('Forecast exceeds viewport'),
}
local PENDING = M.PENDING

-- UI units at scale 1; the native frame is 533 wide.
M.BOTTOM = 56             -- keep the Esc / Back prompt row visible
-- Native frame geometry: a 3-unit gold outline, a 4-unit dark gap, then the
-- opaque body 7 units from the outer edge. Text starts 22 units in, in line
-- with the native panel text above.
M.BORDER, M.INSET, M.PAD, M.GAP, M.EDGE = 3, 7, 22, 6, 5
M.SIZES = {18, 16, 14, 12}
M.TITLE, M.CAPTION = 18, 13
-- Line pitch of meter rows and list lines, in text sizes.
M.ROW, M.LINE = 1.4, 1.3
-- Capital height, in text sizes: sets the padding above the label's capitals,
-- which the space below the footer's baseline mirrors.
M.CAP = 0.7
M.TICK, M.TICK_GAP, M.TICKS = 8, 3, 10
-- Body and slate (rules, empty ticks). The war-table UI shows dark colours
-- lighter than their values: the native body, (15, 20, 30), shows as about
-- (32, 37, 49). These show as the mockup's #0F141E and #3B4654.
M.BODY, M.SLATE = {6, 10, 17}, {42, 53, 69}
-- A headline wider than the panel scrolls like native long strings: it holds
-- at the start, scrolls to the end, holds, then resets. Speed in units/s.
M.SCROLL = {hold=2.0, end_hold=1.5, speed=40}
-- Draw layers. GUI layers sort across every GUI in a world and only 0-1023
-- order correctly (1024 and above wrap under the box in game). The squad
-- nameplates draw above 1000 and below 1011 (probed in game), so the box
-- covers them while a mission is highlighted. Masks hide scrolling glyphs in
-- the side padding.
M.LAYER = {shade=1011, body=1012, rule=1013, border=1013, content=1014, mask=1015}

-- Tick and gap widths in whole pixels. Fractional sizes would round to
-- uneven gaps (ticks seen in pairs), so every tick and gap is identical.
function M.tick_pixels(s)
    return math.max(1, math.floor(M.TICK * s + 0.5)), math.max(1, math.floor(M.TICK_GAP * s + 0.5))
end

function M.meter_width(s)
    local tick, gap = M.tick_pixels(s)
    return M.TICKS * tick + (M.TICKS - 1) * gap
end

-- Lines break at spaces and between CJK characters, never inside a character.
M.wrap = text.wrap

-- Scroll distance from the start at `time` seconds into a cycle, for text
-- `travel` units wider than its window, and the cycle length.
function M.scroll_offset(time, travel, s)
    local hold, speed = M.SCROLL.hold, M.SCROLL.speed * s
    local moving = travel / speed
    local period = hold + moving + M.SCROLL.end_hold
    time = time % period
    if time < hold then return 0, period end
    if time < hold + moving then return (time - hold) * speed, period end
    return travel, period
end

-- Characters drawn at scroll `offset`: those wholly inside the window widened
-- by `margin` on each side, where the masks hide them. `edges[k]` is the caret
-- before character k. Continues from (first, last) found at a smaller or equal
-- offset, or from the start without them. Returns the first character and the
-- one after the last.
function M.window(edges, count, offset, width, margin, first, last)
    first, last = first or 1, last or 1
    while first <= count and edges[first] < offset - margin do first = first + 1 end
    if last < first then last = first end
    while last <= count and edges[last + 1] <= offset + width + margin do last = last + 1 end
    return first, last
end

-- Moves scroll state `m` to its current time. Returns the visible text and
-- its x position, or nil when nothing moved since the last call. `m.bounds[k]`
-- is the byte where character k starts (then #text + 1), so a window never
-- cuts a character. Window strings are cached, so later cycles create no
-- strings.
function M.advance(m)
    local offset, period = M.scroll_offset(m.time, m.travel, m.scale)
    if m.time >= period then m.time = m.time - period end
    if offset == m.offset then return nil end
    if not m.offset or offset < m.offset then m.first, m.last = nil, nil end
    m.offset = offset
    m.first, m.last = M.window(m.edges, #m.bounds - 1, offset, m.width, m.margin, m.first, m.last)
    local key = m.first * 1024 + m.last
    local value = m.windows[key]
    if not value then
        value = m.text:sub(m.bounds[m.first], m.bounds[m.last] - 1)
        m.windows[key] = value
    end
    return value, m.x + m.edges[m.first] - offset
end

-- Lays out one report at body size `size`. Offsets are distances below the
-- content top (y grows downward here). Returns nil when it needs more than
-- `limit` height. `shown_large`/`shown_small` limit the listed enemies; the
-- rest are counted in an "and N more" line (model.more, with {count}).
function M.plan(model, measure, width, limit, s, size, shown_large, shown_small)
    local items, d = {}, 0
    local function add(value, text_size, x, role)
        items[#items + 1] = {kind='text', text=value, size=text_size, x=x, d=d + text_size, role=role}
    end
    local title = M.TITLE * s
    add(model.label, title, 0, 'label')
    d = d + title * 1.3
    if model.headline then
        -- One line at the title size; wider headlines scroll.
        add(model.headline, title, 0, 'body')
        local overflow = measure(model.headline, title) - width
        if overflow > 0 then items[#items].kind, items[#items].travel = 'scroll', overflow end
        d = d + title * 1.25
    end
    local row, line = size * M.ROW, size * M.LINE
    local caption = M.CAPTION * s
    local function section(left, right)
        d = d + M.GAP * s
        add(left, caption, 0, 'muted')
        add(right, caption, width - measure(right, caption), 'muted')
        d = d + caption * 1.2
        items[#items + 1] = {kind='rule', d=d, h=math.max(1, s)}
        d = d + 3 * s
    end
    local large, small = model.large or {}, model.small or {}
    shown_large = math.min(shown_large or #large, #large)
    shown_small = math.min(shown_small or #small, #small)
    if shown_large > 0 then
        section(model.large_caption, model.rate_caption)
        for i = 1, shown_large do
            local entry = large[i]
            -- A name that would reach the meter needs a smaller size.
            if measure(entry.text, size) > width - M.meter_width(s) - 2 * M.GAP * s then return nil end
            add(entry.text, size, 0, 'body')
            -- Ticks slightly taller than the capitals beside them, centred on them.
            items[#items + 1] = {kind='meter', ticks=entry.ticks, x=width - M.meter_width(s),
                d=d + size * 1.05, h=size * 0.8}
            d = d + row
        end
    end
    local hidden = (#large - shown_large) + (#small - shown_small)
    if shown_small > 0 or hidden > 0 then
        local names = {}
        for i = 1, shown_small do names[i] = small[i] end
        if shown_small > 0 then section(model.small_caption, model.order_caption) end
        local separator = model.separator or ', '
        local list = table.concat(names, separator)
        if hidden > 0 then
            local more = text.format(model.more or 'and {count} more', {count = hidden})
            list = (list == '' and '' or list .. separator) .. more
        end
        for _, value in ipairs(M.wrap(list, width, function(v) return measure(v, size) end)) do
            add(value, size, 0, 'body')
            d = d + line
        end
    end
    d = d + M.GAP * s
    local footer = M.CAPTION * s
    add(model.footer, footer, 0, 'muted')
    -- End as far below the footer's baseline as the label's capitals start
    -- below the top, so both ends get the same padding.
    d = d + footer + title * (1 - M.CAP)
    if d > limit then return nil end
    return {items=items, size=size, height=d}
end

-- Largest body size that fits. With `cut`, the lists may then be shortened
-- from the end and summarised as "and N more" at the smallest size.
function M.fit(model, measure, width, limit, s, cut)
    for _, size in ipairs(M.SIZES) do
        local plan = M.plan(model, measure, width, limit, s, size * s)
        if plan then return plan end
    end
    if not cut then return nil end
    local size = M.SIZES[#M.SIZES] * s
    local large, small = #(model.large or {}), #(model.small or {})
    for k = small - 1, 0, -1 do
        local plan = M.plan(model, measure, width, limit, s, size, large, k)
        if plan then return plan end
    end
    for k = large - 1, 0, -1 do
        local plan = M.plan(model, measure, width, limit, s, size, k, 0)
        if plan then return plan end
    end
    return nil
end

-- Chrome around the content: border, inset and inner padding on each side.
local function chrome(s) return 2 * (M.BORDER + M.INSET + M.EDGE) * s end

-- Below the native panel when the content fits above the bottom prompt row,
-- otherwise beside it with the full screen height.
function M.place(anchor, width, height, plan_below, plan_side)
    local s = anchor.scale
    if plan_below then
        local h = plan_below.height + chrome(s)
        return {side=false, x=anchor.x, y=anchor.y + M.BORDER * s - h, w=anchor.w, h=h}, plan_below
    end
    local plan = plan_side
    if not plan then error(PENDING.viewport) end
    local h = plan.height + chrome(s)
    local x = anchor.x + anchor.w + 12 * s
    if x + anchor.w > width - 12 * s then x = anchor.x - anchor.w - 12 * s end
    local y = math.min(height - 12 * s, anchor.y + anchor.h) - h
    if x < 0 or y < 0 then error(PENDING.viewport) end
    return {side=true, x=x, y=y, w=anchor.w, h=h}, plan
end

function M.below_limit(anchor)
    local s = anchor.scale
    return anchor.y + M.BORDER * s - M.BOTTOM * s - chrome(s)
end

function M.side_limit(anchor, height)
    local s = anchor.scale
    return math.min(height - 12 * s, anchor.y + anchor.h) - 12 * s - chrome(s)
end

function M.new(engine)
    local self = {cache={}, order={}, rect_ids={}, text_ids={}}
    local App, World, Gui = engine.Application, engine.World, engine.Gui
    local function colour(a, r, g, b) return engine.Color(a, r, g, b) end
    local function vector(x, y, z) return engine.Vector3(x, y, z or 0) end
    local function worlds()
        local list = App.worlds()
        if not list then error(PENDING.worlds) end
        return list
    end
    local function contains(list, value)
        for _, v in ipairs(list) do if v == value then return true end end
        return false
    end
    local function wipe(t)
        for key in pairs(t) do t[key] = nil end
    end
    -- Drops the GUI, destroying it only while its world is still listed
    -- (`list`: this frame's world list, when the caller already has it). The
    -- tables are emptied in place, so the hidden frames, which clear every
    -- frame, allocate nothing.
    local function destroy(list)
        if self.gui and contains(list or worlds(), self.world) then World.destroy_gui(self.world, self.gui) end
        self.gui, self.world, self.font, self.scroll = nil, nil, nil, nil
        wipe(self.rect_ids) wipe(self.text_ids)
        self.signature = nil
    end
    -- True from a clear until the next show, the only path that creates a GUI
    -- or fills these tables: clearing again then changes nothing, so hidden
    -- frames skip it (no pairs loop on the idle path).
    local empty = false
    local function clear(list)
        destroy(list)
        self.model, self.geometry = nil, nil
        wipe(self.cache) wipe(self.order)
        empty = true
    end
    function self:clear()
        if empty then return end
        clear()
    end
    -- Mirror native normal-font setup on one of our GUI materials.
    local function ink(gui, anchor)
        local material = Gui.material(gui, engine.IdString64.from_hex(anchor.material))
        if not material then error(PENDING.material) end
        local function slot(hash) return engine.IdString64.from_hex(hash .. '00000000') end
        for _, hash in ipairs({'8035c266', '5e8455fe', '309e7783', '82b803a8'}) do
            engine.Material.set_scalar(material, slot(hash), 0)
        end
        engine.Material.set_vector2(material, slot('e13777ce'), engine.Vector2(1, -1))
        engine.Material.set_vector4(material, slot('7701209e'), colour(0, 0, 0, 0))
        engine.Material.set_texture(material, slot('88bac99b'), engine.IdString64.from_hex(anchor.atlas))
    end
    -- Every frame the panel is up, the world list is checked again: a world
    -- that was replaced or removed moves or hides the panel on that frame.
    local function prepare(anchor)
        -- The first non-main world is the only UI world drawn on the war table.
        local main, target = App.main_world(), nil
        local list = worlds()
        for _, world in ipairs(list) do
            if world ~= main then target = world break end
        end
        if not target then clear(list) return nil end
        if self.world and self.world ~= target then clear(list) end
        if not self.gui or self.font ~= anchor.font or self.material ~= anchor.material or self.atlas ~= anchor.atlas then
            destroy(list)
            self.gui = World.create_screen_gui(target, 'scale', 1, 1)
            if not self.gui then error(PENDING.gui) end
            self.world = target
            ink(self.gui, anchor)
            self.font, self.material, self.atlas = anchor.font, anchor.material, anchor.atlas
        end
        return target
    end
    local function measurer(font)
        local measured = {}
        return function(value, size)
            local key = size .. '|' .. value
            if not measured[key] then
                local lo, hi, caret = Gui.text_extents(self.gui, value, font, size)
                if not (lo and hi and caret) then error(PENDING.metrics) end
                measured[key] = math.max(engine.Vector2.x(hi), engine.Vector2.x(caret)) - math.min(0, engine.Vector2.x(lo))
            end
            return measured[key]
        end
    end
    -- Carets before each character and after the last, never decreasing:
    -- one measurement per character (a CJK character is 3 bytes, one glyph).
    local function carets(value, bounds, font, size)
        local edges = {0}
        for k = 2, #bounds do
            local _, _, caret = Gui.text_extents(self.gui, value:sub(1, bounds[k] - 1), font, size)
            if not caret then error(PENDING.caret) end
            edges[k] = math.max(edges[k - 1], engine.Vector2.x(caret))
        end
        return edges
    end
    -- Plans are cached per report, width, height limit, scale and mode (8 entries).
    local function planned(model, font, width, limit, s, cut)
        local key = table.concat({model.signature or 'pending', self.font, width, limit, s, tostring(cut)}, '|')
        local plan = self.cache[key]
        if plan == nil then
            plan = M.fit(model, measurer(font), width, limit, s, cut) or false
            self.cache[key] = plan
            self.order[#self.order + 1] = key
            if #self.order > 8 then self.cache[table.remove(self.order, 1)] = nil end
        end
        return plan or nil
    end
    local palette = {
        label=function() return colour(255, 255, 213, 0) end,
        body=function() return colour(255, 240, 243, 245) end,
        muted=function() return colour(255, 179, 198, 205) end,
    }
    -- One frame of a scrolling headline: no GUI call while it holds still.
    -- Engine IDs are temporary, so they are rebuilt from the hex names.
    local function scroll(dt)
        local m = self.scroll
        m.time = m.time + math.max(0, math.min(dt or 0, 0.1))
        local value, x = M.advance(m)
        if not value then return end
        Gui.update_text(self.gui, m.id, value, engine.IdString64.from_hex(self.font), m.size,
            engine.IdString64.from_hex(self.material), vector(x, m.y, M.LAYER.content), palette.body())
    end
    local function draw(plan, place, anchor, font_id, material_id)
        local s, gui, layer = anchor.scale, self.gui, M.LAYER
        local rect_index, text_index = 0, 0
        local function rect(x, y, w, h, z, fill)
            rect_index = rect_index + 1
            local pos, size = vector(x, y, z), engine.Vector2(w, h)
            local id = self.rect_ids[rect_index]
            if id then Gui.update_rect(gui, id, pos, size, fill)
            else
                local created = Gui.rect(gui, pos, size, fill)
                if not created then error(PENDING.rect) end
                self.rect_ids[rect_index] = created
            end
        end
        local function label(value, size, x, y, fill)
            text_index = text_index + 1
            local pos = vector(x, y, layer.content)
            local id = self.text_ids[text_index]
            if id then Gui.update_text(gui, id, text.display(value), font_id, size, material_id, pos, fill)
            else
                id = Gui.text(gui, text.display(value), font_id, size, material_id, pos, fill)
                if not id then error(PENDING.text) end
                self.text_ids[text_index] = id
            end
            return id
        end
        local body = colour(255, M.BODY[1], M.BODY[2], M.BODY[3])
        local gold, slate = colour(255, 255, 185, 0), colour(255, M.SLATE[1], M.SLATE[2], M.SLATE[3])
        local x, y, w, h = place.x, place.y, place.w, place.h
        local b, i = M.BORDER * s, M.INSET * s
        rect(x, y, w, h, layer.shade, colour(204, 0, 0, 0))
        rect(x + i, y + i, w - 2 * i, h - 2 * i, layer.body, body)
        rect(x, y + h - b, w, b, layer.border, gold)
        rect(x, y, w, b, layer.border, gold)
        rect(x, y, b, h, layer.border, gold)
        rect(x + w - b, y, b, h, layer.border, gold)
        local top = y + h - (M.BORDER + M.INSET + M.EDGE) * s
        local cx, cw = x + M.PAD * s, w - 2 * M.PAD * s
        local previous = self.scroll
        self.scroll = nil
        for _, item in ipairs(plan.items) do
            if item.kind == 'text' then
                label(item.text, item.size, cx + item.x, top - item.d, palette[item.role]())
            elseif item.kind == 'scroll' then
                -- Carets are measured once per plan, per character. The same
                -- headline keeps its place in the cycle when the panel moves.
                item.bounds = item.bounds or text.boundaries(item.text)
                assert(#item.bounds <= 1024, 'Headline too long')
                item.edges = item.edges or carets(item.text, item.bounds, font_id, item.size)
                local same = previous and previous.text == item.text and previous.size == item.size
                local m = {text=item.text, bounds=item.bounds, edges=item.edges, size=item.size, x=cx,
                    y=top - item.d, width=cw, margin=(M.PAD - M.INSET) * s, travel=item.travel, scale=s,
                    time=same and previous.time or 0, windows=same and previous.windows or {}}
                local value, at = M.advance(m)
                m.id = label(value, item.size, at, m.y, palette.body())
                -- Panel-coloured masks over the side padding hide glyphs
                -- entering or leaving the text column.
                local line_y, line_h = m.y - item.size * 0.35, item.size * 1.5
                rect(x + i, line_y, cx - (x + i), line_h, layer.mask, body)
                rect(cx + cw, line_y, (x + w - i) - (cx + cw), line_h, layer.mask, body)
                self.scroll = m
            elseif item.kind == 'rule' then
                rect(cx, top - item.d, cw, item.h, layer.rule, slate)
            else
                -- Whole-pixel ticks: every tick and gap renders the same width.
                local tick, gap = M.tick_pixels(s)
                local left, bottom = math.floor(cx + item.x + 0.5), math.floor(top - item.d + 0.5)
                local tall = math.max(1, math.floor(item.h + 0.5))
                for t = 1, M.TICKS do
                    rect(left + (t - 1) * (tick + gap), bottom, tick, tall, layer.content,
                        t <= item.ticks and palette.body() or slate)
                end
            end
        end
        -- Clear primitives a longer report used.
        for index = rect_index + 1, #self.rect_ids do
            Gui.update_rect(gui, self.rect_ids[index], vector(0, 0, 0), engine.Vector2(0, 0), body)
        end
        for index = text_index + 1, #self.text_ids do
            Gui.update_text(gui, self.text_ids[index], '', font_id, M.CAPTION * s, material_id, vector(0, 0, 0), body)
        end
    end
    function self:show(model, dt, anchor)
        empty = false
        if not prepare(anchor) then return false end
        local width, height = Gui.resolution()
        -- Unchanged report, geometry and font: only a long headline moves.
        local g = self.geometry
        if g and model.signature == self.signature and anchor.x == g.ax and anchor.y == g.ay
            and anchor.w == g.aw and anchor.h == g.ah and anchor.scale == g.as and width == g.rw and height == g.rh then
            if self.scroll then scroll(dt) end
            return true
        end
        local s = anchor.scale
        if not (width >= 640 and height >= 480 and s > 0) then error(PENDING.native) end
        local font_id = engine.IdString64.from_hex(anchor.font)
        local material_id = engine.IdString64.from_hex(anchor.material)
        local content_w = anchor.w - 2 * M.PAD * s
        local below = planned(model, font_id, content_w, M.below_limit(anchor), s, false)
        local side = not below and planned(model, font_id, content_w, M.side_limit(anchor, height), s, true)
        local place, plan = M.place(anchor, width, height, below, side)
        draw(plan, place, anchor, font_id, material_id)
        self.model, self.signature = model, model.signature
        self.geometry = {ax=anchor.x, ay=anchor.y, aw=anchor.w, ah=anchor.h, as=anchor.scale,
            rw=width, rh=height, place=place, plan=plan}
        return true
    end
    -- Pending reports keep the panel and captions (in the language they were
    -- drawn in) without any enemy text. The pending model is made once, from
    -- the report drawn before it; while it is drawn, later pending frames
    -- pass it again, so they allocate nothing.
    function self:suspend(anchor)
        local model = self.model
        if not self.gui or not model then return false end
        if model.signature ~= 'pending' then
            model = {key=model.key, screen=model.screen, label=model.label, footer=model.footer, signature='pending'}
        end
        return self:show(model, 0, anchor)
    end
    -- Removing the panel runs only when something was drawn (a screen change,
    -- an unhover), and its pairs loops would abort any trace: interpreted.
    if jit and jit.off then
        for _, fn in ipairs({wipe, destroy, clear}) do jit.off(fn) end
    end
    return self
end

return M

end)(text)
local install = (function(...)
-- modules: the mod's chunks (create_api, mission, resolve, roster, roster_data,
-- model, panel, presentation, text, locales), its build {revision,
-- game_sha256, exe_sha256}, and the vendored Bingus Shared Runtime core
-- (runtime) and read side (runtime_memory).
return function(modules)
    if rawget(_G,'EnemyIntelligence') then return end
    local create_api,mission,resolve,roster = modules.create_api,modules.mission,modules.resolve,modules.roster
    local roster_data,model,panel,build = modules.roster_data,modules.model,modules.panel,modules.build
    local presentation,text,locales = modules.presentation,modules.text,modules.locales
    local runtime,runtime_memory = modules.runtime,modules.runtime_memory
    -- failures: the mod's own frame errors this session; pending: frames that
    -- met an expected transient state (never counted as errors). The update
    -- guard's counters and first failure are in state.guard (its status).
    local state = {revision=build.revision,status='starting',reads=0,frames=0,failures=0,pending=0}
    rawset(_G,'EnemyIntelligence',state)
    local api,source,surface,current,view,game,tr,font,guard
    local forecasts = roster.new(roster_data)
    local started, elapsed = false, 0
    local selected_key,selected_screen,controller_matches
    -- Translation notes (language, refused entries) stay under the status line.
    local notes = {}
    -- The log is written only when the status or the notes change (kept
    -- interpreted, with report and note: see the jit.off list at the end).
    local function write_lines()
        local logger=rawget(_G,'CowboyBingusModLoader')
        local file=logger and logger.open_log and logger.open_log('EnemyIntelligence.log')
        if file then
            file:write(build.revision..'\n'..state.status..'\n')
            for _,line in ipairs(notes) do file:write(line..'\n') end
            file:close()
        end
    end
    local function write_log()
        pcall(write_lines)
    end
    local function report(message)
        if state.status == message then return end
        state.status = message
        print('[EnemyIntelligence] '..message)
        write_log()
    end
    local function note(message)
        if #notes >= 40 then return end
        notes[#notes+1] = message
        write_log()
    end
    -- A refusal to start (unsupported game) stops the guard: it is the
    -- session's first failure, and no frame runs again.
    local function refuse(why)
        guard.stop('disabled: '..tostring(why))
    end
    -- The game's Text Language (5 reads). Read when the panel first appears
    -- and whenever the native font changes, which is what a language change
    -- does; texts follow at the next 0.5 s re-sample. Both take number
    -- addresses; the reads return strings.
    local function read_at(address,size)
        return api.read(address,size)
    end
    local function observe_language(anchor)
        if anchor.font == font then return end
        font = anchor.font
        local tag,code = text.observe(read_at,game)
        note('text language: '..(tag and (tag..' (game setting '..code..')') or (text.language()..' (Steam)')))
    end
    -- Creates the readers and the panel; raises when the game or its build is
    -- not supported. The build check hashes each module file at most once per
    -- session for every mod on the runtime (BingusRuntime.hashes).
    local function start()
        local supported,why = runtime_memory.new(runtime).verify_build({exe_sha256=build.exe_sha256,
            game_sha256=build.game_sha256})
        if not supported then error(why,0) end
        api = create_api()
        game = assert(api.module('game.dll'),'game modules unavailable')
        assert(stingray and stingray.Gui and stingray.World, 'Game GUI unavailable')
        tr = text.new(locales.en,locales.bundled,note)
        source = mission.new(api,game,resolve)
        surface = panel.new(stingray)
        view = presentation.new(api,game)
    end
    local function initialize()
        if started then return source ~= nil end
        started = true
        local ok,why = pcall(start)
        if not ok then
            source = nil
            refuse(why)
            return false
        end
        report('ready')
        return true
    end
    -- Tables the readers fill again every frame: the native panel, the
    -- selection before and after a sample, and the sample itself. Nothing
    -- keeps them past the frame, so frames allocate nothing for them.
    local anchor_box,selection_before,selection_after,sampled = {},{},{},{}
    -- An unchanged refresh reuses the last roster report and model.
    local function same_tags(a,b)
        if #a ~= #b then return false end
        for i = 1,#a do
            if a[i] ~= b[i] then return false end
        end
        return true
    end
    local function copy_tags(into,from)
        local n = #from
        for i = 1,n do into[i] = from[i] end
        for i = #into,n+1,-1 do into[i] = nil end
    end
    -- A weight table equal to the kept copy (present: whether one was kept).
    local function same_weights(kept,present,weights)
        if not weights or not present then return not weights and not present end
        local n = 0
        for family,value in pairs(weights) do
            if kept[family] ~= value then return false end
            n = n+1
        end
        for _ in pairs(kept) do n = n-1 end
        return n == 0
    end
    -- Copies weights into kept (emptied first); true when there were any.
    local function keep_weights(kept,weights)
        for family in pairs(kept) do kept[family] = nil end
        if not weights then return false end
        for family,value in pairs(weights) do kept[family] = value end
        return true
    end
    -- forecasts:report returns its cached report for the same faction,
    -- difficulty, tag set and weight modifiers. The last call's inputs are
    -- kept here (copied), so inputs exactly equal to them get that report
    -- before the roster builds its cache key again.
    local last = {tags={},zone={},war={}}
    local function roster_report(snapshot)
        local zone,war = snapshot.zone,snapshot.war
        if last.report and last.faction == snapshot.faction and last.difficulty == snapshot.difficulty
            and same_tags(last.tags,snapshot.tags) and same_weights(last.zone,last.has_zone,zone)
            and same_weights(last.war,last.has_war,war) then
            return last.report
        end
        local report = forecasts:report(snapshot,zone,war)
        last.report,last.faction,last.difficulty = report,snapshot.faction,snapshot.difficulty
        copy_tags(last.tags,snapshot.tags)
        last.has_zone,last.has_war = keep_weights(last.zone,zone),keep_weights(last.war,war)
        return report
    end
    -- The model depends only on the report, the mission key, screen and tags
    -- and the translator's texts (tr.generation grows when they change).
    local made = {tags={}}
    local function forecast(snapshot)
        tr:refresh()
        local report = roster_report(snapshot)
        if made.model and made.report == report and made.key == snapshot.key and made.screen == snapshot.screen
            and made.generation == tr.generation and same_tags(made.tags,snapshot.tags) then
            return made.model
        end
        made.model = model.make(snapshot,report,roster_data,tr)
        made.report,made.key,made.screen,made.generation = report,snapshot.key,snapshot.screen,tr.generation
        copy_tags(made.tags,snapshot.tags)
        return made.model
    end
    local function reset_selection()
        current,selected_key,selected_screen,controller_matches = nil,nil,nil,nil
        elapsed = 0
        state.key,state.screen,state.complete = nil,nil,false
    end
    local function select(descriptor)
        if not descriptor then
            current,selected_key,controller_matches = nil,nil,false
            state.key,state.complete = nil,false
            elapsed = 0
            return
        end
        local changed = selected_key ~= descriptor.key or selected_screen ~= descriptor.screen
        if changed then
            if selected_screen and selected_screen ~= descriptor.screen then surface:clear() end
            current = nil
        end
        -- Check identity every frame. Resolve immediately when the controller
        -- catches up, then poll unresolved inputs at a bounded 100 ms cadence.
        if changed or descriptor.controller_matches and not controller_matches then elapsed = 0.5 end
        controller_matches = descriptor.controller_matches == true
        if not controller_matches then current = nil end
        selected_key,selected_screen = descriptor.key,descriptor.screen
        state.key,state.screen = selected_key,selected_screen
    end
    local function hide(message)
        reset_selection()
        surface:clear()
        report(message)
    end
    -- Publish a report only from a complete snapshot belonging to the
    -- selection both before and after reads.
    local function publishable(snapshot,descriptor,screen)
        return snapshot and snapshot.complete == true and snapshot.controller_matches == true and controller_matches
            and snapshot.key == descriptor.key and snapshot.key == selected_key
            and snapshot.screen == screen and selected_screen == screen
    end
    -- The re-sample of a selected mission. False when the panel had to hide.
    local function refresh(screen,anchor,descriptor)
        elapsed = 0
        local snapshot = source:sample(screen,sampled)
        state.reads = state.reads+1
        if source:screen() ~= screen then
            hide('hidden')
            return false
        end
        local latest,latest_hovered = source:descriptor(screen,selection_after)
        if anchor.client and latest_hovered==false then
            hide('hidden')
            return false
        end
        select(latest)
        current = nil
        if publishable(snapshot,descriptor,screen) then
            -- The roster is recomputed only when the mission inputs change;
            -- texts only when the language or the installed packs change.
            current = forecast(snapshot)
        end
        return true
    end
    -- The refresh runs twice a second: kept interpreted like the mission
    -- reader's sample, it adds no traces to the game's shared code cache.
    if jit and jit.off then
        for _,fn in ipairs({same_tags,copy_tags,same_weights,keep_weights,roster_report,forecast,publishable,refresh}) do
            jit.off(fn)
        end
    end
    -- The status draw() last reported and its inputs. The text is built again
    -- only when an input changes or another report replaced it, not on every
    -- frame the panel stays up.
    local drawn_status,drawn_phase,drawn_screen,drawn_key
    local function report_draw(phase,screen,key)
        if state.status == drawn_status and phase == drawn_phase and screen == drawn_screen and key == drawn_key then
            return
        end
        drawn_phase,drawn_screen,drawn_key = phase,screen,key
        if phase == 'waiting' then
            drawn_status = 'waiting for mission data '..screen..' '..(key or 'preview loading')
        else
            drawn_status = phase..screen..' '..key..' composition rules resolved'
        end
        report(drawn_status)
    end
    local function draw(screen,anchor,dt)
        state.complete = current ~= nil
        if not current then
            surface:suspend(anchor)
            return report_draw('waiting',screen,selected_key)
        end
        local drawn = surface:show(current,dt,anchor)
        report_draw(drawn and 'visible ' or 'waiting for GUI ',screen,current.key)
    end
    -- Idle gate. After a frame that found neither the war table nor the
    -- briefing and hid everything, the next frames read only the kept UI
    -- manager's screen stack (1 read) and do nothing else while it shows
    -- neither. Every QUIET_CHECK-th frame, a failed read or a forecast screen
    -- runs the full frame again (its 2 reads find the manager anew). A hidden
    -- frame repeated changes nothing but the frame count, which the gate
    -- keeps. Anything that changes the status (a pause, a pending wait, an
    -- error) restores, which ends the quiet state. A replaced UI manager
    -- whose old stack still reads as neither screen is seen at the next
    -- check: up to 0.5 s at 60 FPS, the longest the panel can appear late.
    local QUIET_CHECK = 30
    local quiet, quiet_frames = false, 0
    local function idle()
        if not quiet then return false end
        quiet_frames = quiet_frames+1
        if quiet_frames >= QUIET_CHECK or not source:quiet() then
            quiet = false
            return false
        end
        state.frames = state.frames+1
        return true
    end
    -- Nothing to show. With neither screen on top, the gate takes over.
    local function hidden(screen)
        hide('hidden')
        if not screen then quiet,quiet_frames = true,0 end
    end
    local function frame(dt)
        if not initialize() then return end
        state.frames = state.frames+1
        local screen = source:screen()
        local anchor = screen and view:sample(screen,anchor_box)
        if not anchor then return hidden(screen) end
        if selected_screen and selected_screen~=screen then
            reset_selection()
            surface:clear()
        end
        observe_language(anchor)
        selected_screen,state.screen = screen,screen
        local descriptor,hovered = source:descriptor(screen,selection_before)
        -- Native selection ends before the card's fade. Hide immediately on
        -- unhover, but retain the frame while a hovered mission is loading.
        if anchor.client and (hovered==false or hovered==nil and not anchor.active) then return hide('hidden') end
        select(descriptor)
        elapsed = elapsed + math.max(0,dt or 0)
        -- Re-sample every 0.5 s, or every 0.1 s while the report is pending.
        if controller_matches and elapsed >= (current and 0.5 or 0.1) and not refresh(screen,anchor,descriptor) then
            return
        end
        draw(screen,anchor,dt)
    end

    -- Update chain: the family's runtime guard (bingus_runtime.lua, policy in
    -- its README). The previous update runs outside pcall, so its errors reach
    -- the game unchanged. The mod's own errors count in bursts: 8 in one burst
    -- stop it, and 3600 frames without one end a burst. After an update below
    -- raised, the forecast is removed, the selection starts afresh and the mod
    -- pauses until the updates below have returned on 60 frames in a row; 8 of
    -- those failures in one burst stop it. The first failure survives shutdown.
    -- The forecast's frame runs after the previous update, as before: in the
    -- guard's `after`, with the frame time its `step` keeps.
    -- Expected transient states (the readers and the panel raise constant
    -- {pending = reason} tables: memory being rebuilt, no mission highlighted,
    -- the font not loaded yet, ...) never reach the guard: the frame hides the
    -- forecast, starts the selection afresh, reports the reason and retries on
    -- the next frame, as v4.0 did for every raised frame. Only genuine errors
    -- go on to the guard, after the forecast was removed.
    local function clear_surface()
        if surface then surface:clear() end
    end
    local function restore()
        quiet = false
        reset_selection()
        clear_surface()
    end
    local frame_dt = 0
    local function keep_dt(dt) frame_dt = dt end
    local function waited(why)
        state.pending = state.pending+1
        pcall(restore)
        report(why.status)
    end
    -- A genuine error: the forecast is removed and the error goes on to the
    -- guard, which counts it. The first error of a burst reports its status;
    -- later ones of the burst only update it.
    local function failed(why)
        local message = tostring(why)
        state.failures = state.failures+1
        pcall(restore)
        if guard.status.errors == 0 then report('hidden: '..message) else state.status = 'hidden: '..message end
        error(why,0)
    end
    local function run()
        if idle() then return end
        local ok,why = pcall(frame,frame_dt)
        if ok then return end
        if type(why) == 'table' and why.pending then return waited(why) end
        failed(why)
    end
    -- Interpreted, so they start no trace that keeps aborting (LuaJIT keeps
    -- only 64 such starts for the whole game):
    -- - keep_dt, run and frame: the guard calls keep_dt and run under pcall and
    --   run calls frame under pcall, so a trace started in one of them aborts
    --   when it returns into that pcall ("return to lower frame");
    -- - idle, hidden, hide, reset_selection: a side trace from them would climb
    --   into those; the readers they call (the gate's one read) still compile;
    -- - report, note, write_log, write_lines: they write the log on a status
    --   change, through its loop.
    if jit and jit.off then
        for _,fn in ipairs({keep_dt,run,frame,idle,hidden,hide,reset_selection,report,note,write_log,write_lines}) do
            jit.off(fn)
        end
    end
    -- An update below raised: remove the forecast and start the selection
    -- afresh. A removal that raises stops the mod instead.
    local function pause(reason)
        restore()
        report('paused: '..reason)
    end
    -- The status of a stop names its reason ('stopped after: <reason>') from
    -- then on, so it already shows the first failure that shutdown keeps.
    local function stopped_after(reason)
        return 'stopped after: '..(reason:match('^stopped after (.*)$') or reason)
    end
    -- Once: a refusal, 8 errors in one burst, 8 failed updates below in one
    -- burst or a failed pause stopped the mod, or the game shuts down. The
    -- forecast is removed. At shutdown a session without a failure keeps its
    -- last status.
    local function stop(reason)
        if reason ~= 'shutdown' then
            pcall(restore)
            return report(stopped_after(reason))
        end
        pcall(clear_surface)
        local failure = guard.status.first_failure
        if failure then report(stopped_after(failure)) end
    end
    -- runtime.guard raises only for a second guard of this name, which the
    -- one-copy check above rules out.
    guard = runtime.guard({name='KnowYourConstellation',step=keep_dt,after=run,stop=stop,pause=pause,log=note,env=_G})
    state.guard = guard.status
    local installed,why = pcall(guard.install)
    if not installed then refuse(why) end
end

end)(text)
local presentation = (function(...)
-- Read the native panel's solved screen rectangle and opacity. These fields
-- are build locked by install.lua. This module never changes native widgets.
-- Reads land in buffers this reader keeps and fields decode in place, so a
-- sample allocates nothing when the caller passes the table to fill.
local ffi = require('ffi')
local bit = require('bit')
local M = {}

-- Expected transient states, while the game builds or switches screens, are
-- raised as constant tables {pending = reason, status = 'hidden: ' .. reason}:
-- a waiting frame builds no string, and the installer hides and retries on the
-- next frame without counting the frame toward stopping the mod (as v4.0 did
-- for every raised frame). Everything else raises a string and counts.
local function pending(reason) return {pending = reason, status = 'hidden: ' .. reason} end
local DATA_UNAVAILABLE = pending('Presentation data unavailable')
local OWNER_UNAVAILABLE = pending('Presentation owner unavailable')
local FONT_NOT_READY = pending('Native font is not ready')
M.PENDING = {DATA_UNAVAILABLE, OWNER_UNAVAILABLE, FONT_NOT_READY}

local function uint(b, at) return b[at] + b[at + 1] * 256 + b[at + 2] * 65536 + b[at + 3] * 16777216 end
-- The user-mode pointer stored at b[at] (little-endian), or nil.
local function pointer_at(b, at)
    if b[at + 6] ~= 0 or b[at + 7] ~= 0 then return nil end
    local value = uint(b, at) + (b[at + 4] + b[at + 5] * 256) * 4294967296
    if value < 0x10000 or value >= 0x800000000000 then return nil end
    return value
end
local function buffer(size)
    local data = ffi.new('uint8_t[?]', size)
    return {data = data, address = tonumber(ffi.cast('uintptr_t', data)), size = size}
end
local function out_of_range(v) return v ~= v or v < 0 or v > 32768 end

-- A float decoder: the bits go in and the float comes out of one union cell
-- (as in mission.lua: a second view of the cell would read back stale values
-- in compiled code). Declared on first use, under a private name.
local function float_decoder()
    if not pcall(ffi.typeof, 'hd2kyc_float_bits') then
        ffi.cdef('typedef union { uint32_t bits; float value; } hd2kyc_float_bits;')
    end
    local cell = ffi.new('hd2kyc_float_bits')
    return function(b, at)
        cell.bits = uint(b, at)
        return cell.value
    end
end

function M.new(api,game)
    local scratch, widget_bytes, preview_bytes = buffer(64), buffer(164), buffer(88)
    local real = float_decoder()
    local function read(address,size,into)
        into = into or scratch
        assert(address and size <= 1024 and size <= into.size, 'Invalid presentation read')
        if not api.read(address,size,into,0) then error(DATA_UNAVAILABLE) end
        return into.data
    end
    local function pointer(address)
        local result = pointer_at(read(address,8),0)
        if not result then error(OWNER_UNAVAILABLE) end
        return result
    end
    -- A resource hash read each frame, so an unready font table hides the panel
    -- at once; its hex text is formatted again only when the words change, which
    -- they do only when the game loads another font (a language change).
    local function hash_reader()
        local last_high,last_low,text
        return function(address)
            local bytes = read(address,8)
            local high,low = uint(bytes,4),uint(bytes,0)
            if high == 0 and low == 0 then error(FONT_NOT_READY) end
            if high ~= last_high or low ~= last_low then
                last_high,last_low,text = high,low,string.format('%08x%08x',high,low)
            end
            return text
        end
    end
    local font_hash,material_hash,atlas_hash = hash_reader(),hash_reader(),hash_reader()
    -- The widget's solved rectangle into box, when it is fully visible.
    local function rectangle(owner,offset,box)
        local widget = read(owner+offset,164,widget_bytes)
        -- +84 is inherited opacity, including the pod entry animation. +68
        -- alone is local opacity and can remain one while its parent is hidden.
        local opacity = real(widget,84)
        if bit.band(uint(widget,0),0x10) == 0 or not (opacity>=0.995 and opacity<=1.01) then return false end
        local sx,sy = real(widget,100),real(widget,140)
        local x,y,w,h = real(widget,148),real(widget,156),real(widget,36)*sx,real(widget,40)*sy
        if out_of_range(x) or out_of_range(y) or out_of_range(w) or out_of_range(h) or out_of_range(sx) then
            return false
        end
        if sx < 0.3 or sx > 4 or math.abs(sx-sy)>0.01 or w<200 or h<40 then return false end
        box.x,box.y,box.w,box.h,box.scale = x,y,w,h,sx
        return true
    end
    -- The operation or briefing frame; on the map, else the planet frame of a
    -- remote hover. The planet frame stays fixed while joinable cards move and
    -- fade between hovers. Card activity is a fallback for local previews.
    -- Remote hover activity comes from mission selection.
    local function frame(owner,screen,box)
        box.client,box.active = nil,nil
        if rectangle(owner,screen == 'map' and 349072 or 31232,box) then return true end
        if screen ~= 'map' or not rectangle(owner,280528,box) then return false end
        local preview = read(owner+526048,88,preview_bytes)
        local opacity = real(preview,84)
        box.client = true
        box.active = bit.band(uint(preview,0),0x10)~=0 and opacity>0.001 and opacity<=1.01
        return true
    end
    local self = {}
    -- Fills box (a new table when none is given) or returns nil.
    function self:sample(screen,box)
        if screen ~= 'map' and screen ~= 'briefing' then return nil end
        local manager = pointer(game+0x2CE2040)
        local registry = screen == 'map' and 25464 or 25512
        local kind = screen == 'map' and 228 or 231
        -- These event registries have one inline subscriber. A zero count can
        -- leave a stale pointer behind, so never inspect it without the count.
        local entry = read(manager+registry,24)
        if uint(entry,0) ~= 1 or uint(entry,16) ~= kind then return nil end
        local owner = pointer_at(entry,8)
        if not owner then return nil end
        if screen == 'briefing' and uint(read(owner+8,4),0) ~= 0 then return nil end
        box = box or {}
        if not frame(owner,screen,box) then return nil end
        -- The active locale's body face and its normal material. The native
        -- font initializer at 0xf553c0 populates these same rendering tables.
        box.font = font_hash(game+0x312D998)
        box.material = material_hash(pointer(game+0x3180C08)+24)
        box.atlas = atlas_hash(game+0x312E618)
        box.screen = screen
        -- No guessed coordinates if the native panel is absent or mid-layout.
        return box
    end
    return self
end

return M

end)(text)
local locales = {bundled = {}}
locales.en = (function()
-- Know Your Constellation: English texts, the source of every translation.
-- Translators: see TRANSLATING.md. Keys never change meaning; the comment above an
-- entry says where the text shows. The panel shrinks its text to fit, so there are
-- no length limits, but shorter reads better.
return {
    mod = 'know_your_constellation',
    title = 'Know Your Constellation',
    language = 'en',
    strings = {
        -- Panel title above the forecast, in the game's gold. Upper case in English, like the
        -- game's own panel titles.
        ['panel.label'] = 'FORECAST // INTEL AND RECON',
        -- Last line of the panel.
        ['panel.footer'] = 'Possible encounters. Spawns are not guaranteed.',
        -- Caption above the large enemies, which get a SPAWN RATE meter.
        ['panel.large'] = 'LARGE ENEMIES',
        -- Caption on the right, above the meters.
        ['panel.rate'] = 'SPAWN RATE',
        -- Caption above the list of small and medium enemies.
        ['panel.small'] = 'SMALL AND MEDIUM ENEMIES',
        -- Caption on the right, above that list.
        ['panel.order'] = 'MOST COMMON FIRST',
        -- Ends a list that had to be cut to fit the screen. {count} is the number of
        -- enemies left out (1 or more).
        ['panel.more'] = 'and {count} more',
        -- Between two enemy names in the list. Chinese and Japanese usually use an
        -- ideographic comma without spaces.
        ['panel.list_separator'] = ', ',
        -- Between two constellation names in the headline (one line under the title).
        ['headline.separator'] = ' // ',
        -- Headline when the mission has no special constellation.
        ['headline.standard'] = 'STANDARD FORCES',

        -- Constellation names in the headline, upper case in English. Subfactions, strains
        -- and operation modifiers (JET BRIGADE, PREDATOR STRAIN, INCINERATION CORPS...)
        -- use the game's own names: use the ones your game shows. The others are this
        -- mod's names for the game's base constellations.
        ['title.bile_bugs'] = 'BILE BUGS',
        ['title.armored_bugs'] = 'ARMORED BUGS',
        ['title.hunter_swarms'] = 'HUNTER SWARMS',
        ['title.flyer_composition'] = 'FLYER COMPOSITION',
        ['title.light_bugs'] = 'LIGHT BUGS',
        ['title.bug_nursery'] = 'BUG NURSERY',
        ['title.balanced_terminids'] = 'BALANCED TERMINIDS',
        ['title.predator_strain'] = 'PREDATOR STRAIN',
        ['title.spore_burst_strain'] = 'SPORE BURST STRAIN',
        ['title.rupture_strain'] = 'RUPTURE STRAIN',
        ['title.dragonroach_activity'] = 'DRAGONROACH ACTIVITY',
        ['title.roving_shriekers'] = 'ROVING SHRIEKERS',
        ['title.assault_forces'] = 'ASSAULT FORCES',
        ['title.phalanx_forces'] = 'PHALANX FORCES',
        ['title.artillery_forces'] = 'ARTILLERY FORCES',
        ['title.air_composition'] = 'AIR COMPOSITION',
        ['title.armored_column'] = 'ARMORED COLUMN',
        ['title.balanced_automatons'] = 'BALANCED AUTOMATONS',
        ['title.jet_brigade'] = 'JET BRIGADE',
        ['title.cyborg_legion'] = 'CYBORG LEGION',
        ['title.gunship_patrols'] = 'GUNSHIP PATROLS',
        ['title.incineration_corps'] = 'INCINERATION CORPS',
        ['title.hive_world'] = 'HIVE WORLD',
        ['title.illuminate_stragglers'] = 'ILLUMINATE STRAGGLERS',
        ['title.leviathan_blockade'] = 'LEVIATHAN BLOCKADE',
        ['title.appropriators'] = 'APPROPRIATORS',
        ['title.invasion_fleet'] = 'INVASION FLEET',
        ['title.mindless_masses'] = 'MINDLESS MASSES',
        ['title.vote_snatchers'] = 'VOTE SNATCHERS',
        ['title.seaf_support'] = 'SEAF SUPPORT',
        ['title.horde'] = 'HORDE',

        -- Enemy names, plural, as on the Helldivers wiki. Use the names players of your
        -- language know (the game's own where it shows one).
        ['unit.scavengers'] = 'Scavengers',
        ['unit.bile_spitters'] = 'Bile Spitters',
        ['unit.pouncers'] = 'Pouncers',
        ['unit.warriors'] = 'Warriors',
        ['unit.hive_guards'] = 'Hive Guards',
        ['unit.bile_warriors'] = 'Bile Warriors',
        ['unit.hunters'] = 'Hunters',
        ['unit.brood_commanders'] = 'Brood Commanders',
        ['unit.chargers'] = 'Chargers',
        ['unit.charger_behemoths'] = 'Charger Behemoths',
        ['unit.bile_spewers'] = 'Bile Spewers',
        ['unit.bile_titans'] = 'Bile Titans',
        ['unit.stalkers'] = 'Stalkers',
        ['unit.nursing_spewers'] = 'Nursing Spewers',
        ['unit.shriekers'] = 'Shriekers',
        ['unit.impalers'] = 'Impalers',
        ['unit.alpha_commanders'] = 'Alpha Commanders',
        ['unit.alpha_warriors'] = 'Alpha Warriors',
        ['unit.spore_chargers'] = 'Spore Chargers',
        ['unit.predator_stalkers'] = 'Predator Stalkers',
        ['unit.hive_lords'] = 'Hive Lords',
        ['unit.dragonroaches'] = 'Dragonroaches',
        ['unit.rupture_spewers'] = 'Rupture Spewers',
        ['unit.rupture_warriors'] = 'Rupture Warriors',
        ['unit.rupture_chargers'] = 'Rupture Chargers',
        ['unit.spore_burst_bile_titans'] = 'Spore Burst Bile Titans',
        ['unit.spore_burst_warriors'] = 'Spore Burst Warriors',
        ['unit.spore_burst_hunters'] = 'Spore Burst Hunters',
        ['unit.spore_burst_scavengers'] = 'Spore Burst Scavengers',
        ['unit.predator_hunters'] = 'Predator Hunters',
        ['unit.troopers'] = 'Troopers',
        ['unit.marauders'] = 'Marauders',
        ['unit.brawlers'] = 'Brawlers',
        ['unit.assault_raiders'] = 'Assault Raiders',
        ['unit.mg_raiders'] = 'MG Raiders',
        ['unit.rocket_raiders'] = 'Rocket Raiders',
        ['unit.commissars'] = 'Commissars',
        ['unit.berserkers'] = 'Berserkers',
        ['unit.devastators'] = 'Devastators',
        ['unit.heavy_devastators'] = 'Heavy Devastators',
        ['unit.rocket_devastators'] = 'Rocket Devastators',
        ['unit.scout_striders'] = 'Scout Striders',
        ['unit.hulk_scorchers'] = 'Hulk Scorchers',
        ['unit.hulk_bruisers'] = 'Hulk Bruisers',
        ['unit.annihilator_tanks'] = 'Annihilator Tanks',
        ['unit.shredder_tanks'] = 'Shredder Tanks',
        ['unit.barrager_tanks'] = 'Barrager Tanks',
        ['unit.factory_striders'] = 'Factory Striders',
        ['unit.hulk_obliterators'] = 'Hulk Obliterators',
        ['unit.gunships'] = 'Gunships',
        ['unit.reinforced_scout_striders'] = 'Reinforced Scout Striders',
        ['unit.conflagration_devastators'] = 'Conflagration Devastators',
        ['unit.pyro_troopers'] = 'Pyro Troopers',
        ['unit.jet_brigade_devastators'] = 'Jet Brigade Devastators',
        ['unit.war_striders'] = 'War Striders',
        ['unit.vox_engines'] = 'Vox Engines',
        ['unit.agitators'] = 'Agitators',
        ['unit.radicals'] = 'Radicals',
        ['unit.jet_brigade_troopers'] = 'Jet Brigade Troopers',
        ['unit.jet_brigade_mg_raiders'] = 'Jet Brigade MG Raiders',
        ['unit.jet_brigade_commissars'] = 'Jet Brigade Commissars',
        ['unit.incendiary_rocket_raiders'] = 'Incendiary Rocket Raiders',
        ['unit.hulk_firebombers'] = 'Hulk Firebombers',
        ['unit.incendiary_mg_devastators'] = 'Incendiary MG Devastators',
        ['unit.jet_brigade_hulk_scorchers'] = 'Jet Brigade Hulk Scorchers',
        ['unit.jet_brigade_hulk_bruisers'] = 'Jet Brigade Hulk Bruisers',
        ['unit.elevated_overseers'] = 'Elevated Overseers',
        ['unit.harvesters'] = 'Harvesters',
        ['unit.watchers'] = 'Watchers',
        ['unit.overseers'] = 'Overseers',
        ['unit.voteless'] = 'Voteless',
        ['unit.stingrays'] = 'Stingrays',
        ['unit.fleshmobs'] = 'Fleshmobs',
        ['unit.leviathans'] = 'Leviathans',
        ['unit.crescent_overseers'] = 'Crescent Overseers',
        ['unit.veracitors'] = 'Veracitors',
        ['unit.gatekeepers'] = 'Gatekeepers',
        ['unit.obtruders'] = 'Obtruders',
        ['unit.crushers'] = 'Crushers',
        ['unit.wretches'] = 'Wretches',
    },
}

end)()
locales.bundled['zh-Hans'] = (function()
-- Know Your Constellation: Simplified Chinese (zh-Hans). Made from en.lua by translations.py template.
-- Translate the text on the right of each '='. Keep the keys, {placeholders} and quotes.
-- A line starting with '-- [' is not translated yet: remove the '-- ' and translate it.
-- 'English:' lines are the source text; check reports when it changes.
return {
    mod = 'know_your_constellation',
    language = 'zh-Hans',
    strings = {
        -- Panel title above the forecast, in the game's gold. Upper case in English, like the
        -- game's own panel titles.
        -- English: FORECAST // INTEL AND RECON
        ['panel.label'] = '敌情预测 // 情报与侦察',
        -- Last line of the panel.
        -- English: Possible encounters. Spawns are not guaranteed.
        ['panel.footer'] = '可能遭遇的敌人，不保证实际出现。',
        -- Caption above the large enemies, which get a SPAWN RATE meter.
        -- English: LARGE ENEMIES
        ['panel.large'] = '大型敌人',
        -- Caption on the right, above the meters.
        -- English: SPAWN RATE
        ['panel.rate'] = '生成率',
        -- Caption above the list of small and medium enemies.
        -- English: SMALL AND MEDIUM ENEMIES
        ['panel.small'] = '小型和中型敌人',
        -- Caption on the right, above that list.
        -- English: MOST COMMON FIRST
        ['panel.order'] = '越靠前越常见',
        -- Ends a list that had to be cut to fit the screen. {count} is the number of
        -- enemies left out (1 or more).
        -- English: and {count} more
        ['panel.more'] = '另有 {count} 种',
        -- Between two enemy names in the list. Chinese and Japanese usually use an
        -- ideographic comma without spaces.
        -- English: ,
        ['panel.list_separator'] = '、',
        -- Between two constellation names in the headline (one line under the title).
        -- English:  //
        ['headline.separator'] = ' // ',
        -- Headline when the mission has no special constellation.
        -- English: STANDARD FORCES
        ['headline.standard'] = '常规部队',
        -- Constellation names in the headline, upper case in English. Subfactions, strains
        -- and operation modifiers (JET BRIGADE, PREDATOR STRAIN, INCINERATION CORPS...)
        -- use the game's own names: use the ones your game shows. The others are this
        -- mod's names for the game's base constellations.
        -- English: BILE BUGS
        ['title.bile_bugs'] = '胆液虫群',
        -- English: ARMORED BUGS
        ['title.armored_bugs'] = '重甲虫群',
        -- English: HUNTER SWARMS
        ['title.hunter_swarms'] = '追猎虫群',
        -- English: FLYER COMPOSITION
        ['title.flyer_composition'] = '飞空虫群',
        -- English: LIGHT BUGS
        ['title.light_bugs'] = '轻型虫群',
        -- English: BUG NURSERY
        ['title.bug_nursery'] = '虫族繁育窝',
        -- English: BALANCED TERMINIDS
        ['title.balanced_terminids'] = '均衡虫群',
        -- English: PREDATOR STRAIN
        ['title.predator_strain'] = '掠食变种',
        -- English: SPORE BURST STRAIN
        ['title.spore_burst_strain'] = '孢裂变种',
        -- English: RUPTURE STRAIN
        ['title.rupture_strain'] = '爆裂虫族变种',
        -- English: DRAGONROACH ACTIVITY
        ['title.dragonroach_activity'] = '蟑龙活动',
        -- English: ROVING SHRIEKERS
        ['title.roving_shriekers'] = '漫游尖啸虫',
        -- English: ASSAULT FORCES
        ['title.assault_forces'] = '特攻部队',
        -- English: PHALANX FORCES
        ['title.phalanx_forces'] = '方阵部队',
        -- English: ARTILLERY FORCES
        ['title.artillery_forces'] = '炮兵部队',
        -- English: AIR COMPOSITION
        ['title.air_composition'] = '空中部队',
        -- English: ARMORED COLUMN
        ['title.armored_column'] = '装甲纵队',
        -- English: BALANCED AUTOMATONS
        ['title.balanced_automatons'] = '均衡部队',
        -- English: JET BRIGADE
        ['title.jet_brigade'] = '喷气旅',
        -- English: CYBORG LEGION
        ['title.cyborg_legion'] = '生化人军团',
        -- English: GUNSHIP PATROLS
        ['title.gunship_patrols'] = '炮舰巡逻队',
        -- English: INCINERATION CORPS
        ['title.incineration_corps'] = '炽灼部队',
        -- English: HIVE WORLD
        ['title.hive_world'] = '虫窝世界',
        -- English: ILLUMINATE STRAGGLERS
        ['title.illuminate_stragglers'] = '光能者残部',
        -- English: LEVIATHAN BLOCKADE
        ['title.leviathan_blockade'] = '利维坦封锁屏障',
        -- English: APPROPRIATORS
        ['title.appropriators'] = '占领者',
        -- English: INVASION FLEET
        ['title.invasion_fleet'] = '入侵舰队',
        -- English: MINDLESS MASSES
        ['title.mindless_masses'] = '无脑群氓',
        -- English: VOTE SNATCHERS
        ['title.vote_snatchers'] = '窃票者',
        -- English: SEAF SUPPORT
        ['title.seaf_support'] = '超级地球武装部队支援',
        -- English: HORDE
        ['title.horde'] = '群袭',
        -- Enemy names, plural, as on the Helldivers wiki. Use the names players of your
        -- language know (the game's own where it shows one).
        -- English: Scavengers
        ['unit.scavengers'] = '食腐虫',
        -- English: Bile Spitters
        ['unit.bile_spitters'] = '胆液吐沫虫',
        -- English: Pouncers
        ['unit.pouncers'] = '猛扑虫',
        -- English: Warriors
        ['unit.warriors'] = '武斗虫',
        -- English: Hive Guards
        ['unit.hive_guards'] = '虫窝护卫',
        -- English: Bile Warriors
        ['unit.bile_warriors'] = '吐酸武斗虫',
        -- English: Hunters
        ['unit.hunters'] = '追猎虫',
        -- English: Brood Commanders
        ['unit.brood_commanders'] = '虫族指挥官',
        -- English: Chargers
        ['unit.chargers'] = '强袭虫',
        -- English: Charger Behemoths
        ['unit.charger_behemoths'] = '巨兽级强袭虫',
        -- English: Bile Spewers
        ['unit.bile_spewers'] = '胆液喷涌虫',
        -- English: Bile Titans
        ['unit.bile_titans'] = '吐酸泰坦',
        -- English: Stalkers
        ['unit.stalkers'] = '追踪虫',
        -- English: Nursing Spewers
        ['unit.nursing_spewers'] = '抚育喷涌虫',
        -- English: Shriekers
        ['unit.shriekers'] = '尖啸虫',
        -- English: Impalers
        ['unit.impalers'] = '穿刺虫',
        -- English: Alpha Commanders
        ['unit.alpha_commanders'] = '阿尔法指挥官',
        -- English: Alpha Warriors
        ['unit.alpha_warriors'] = '阿尔法武斗虫',
        -- English: Spore Chargers
        ['unit.spore_chargers'] = '孢子强袭虫',
        -- English: Predator Stalkers
        ['unit.predator_stalkers'] = '掠食追踪虫',
        -- English: Hive Lords
        ['unit.hive_lords'] = '霸王虫',
        -- English: Dragonroaches
        ['unit.dragonroaches'] = '蟑龙',
        -- English: Rupture Spewers
        ['unit.rupture_spewers'] = '爆裂喷涌虫',
        -- English: Rupture Warriors
        ['unit.rupture_warriors'] = '爆裂武斗虫',
        -- English: Rupture Chargers
        ['unit.rupture_chargers'] = '爆裂强袭虫',
        -- English: Spore Burst Bile Titans
        ['unit.spore_burst_bile_titans'] = '孢裂吐酸泰坦',
        -- English: Spore Burst Warriors
        ['unit.spore_burst_warriors'] = '孢裂武斗虫',
        -- English: Spore Burst Hunters
        ['unit.spore_burst_hunters'] = '孢裂追猎虫',
        -- English: Spore Burst Scavengers
        ['unit.spore_burst_scavengers'] = '孢裂食腐虫',
        -- English: Predator Hunters
        ['unit.predator_hunters'] = '掠食追猎虫',
        -- English: Troopers
        ['unit.troopers'] = '装甲兵',
        -- English: Marauders
        ['unit.marauders'] = '劫掠者',
        -- English: Brawlers
        ['unit.brawlers'] = '乱斗者',
        -- English: Assault Raiders
        ['unit.assault_raiders'] = '特攻奇袭者',
        -- English: MG Raiders
        ['unit.mg_raiders'] = '机枪奇袭者',
        -- English: Rocket Raiders
        ['unit.rocket_raiders'] = '火箭奇袭者',
        -- English: Commissars
        ['unit.commissars'] = '机械统帅',
        -- English: Berserkers
        ['unit.berserkers'] = '狂暴者',
        -- English: Devastators
        ['unit.devastators'] = '蹂躏者',
        -- English: Heavy Devastators
        ['unit.heavy_devastators'] = '重型蹂躏者',
        -- English: Rocket Devastators
        ['unit.rocket_devastators'] = '火箭蹂躏者',
        -- English: Scout Striders
        ['unit.scout_striders'] = '侦察纵步者',
        -- English: Hulk Scorchers
        ['unit.hulk_scorchers'] = '巨型炙炎者',
        -- English: Hulk Bruisers
        ['unit.hulk_bruisers'] = '巨型碾压者',
        -- English: Annihilator Tanks
        ['unit.annihilator_tanks'] = '湮灭坦克',
        -- English: Shredder Tanks
        ['unit.shredder_tanks'] = '碎裂坦克',
        -- English: Barrager Tanks
        ['unit.barrager_tanks'] = '铁幕坦克',
        -- English: Factory Striders
        ['unit.factory_striders'] = '移动工厂',
        -- English: Hulk Obliterators
        ['unit.hulk_obliterators'] = '巨型抹煞者',
        -- English: Gunships
        ['unit.gunships'] = '炮舰',
        -- English: Reinforced Scout Striders
        ['unit.reinforced_scout_striders'] = '强化侦察纵步者',
        -- English: Conflagration Devastators
        ['unit.conflagration_devastators'] = '烈火蹂躏者',
        -- English: Pyro Troopers
        ['unit.pyro_troopers'] = '炙焰装甲兵',
        -- English: Jet Brigade Devastators
        ['unit.jet_brigade_devastators'] = '喷气旅蹂躏者',
        -- English: War Striders
        ['unit.war_striders'] = '战争纵步者',
        -- English: Vox Engines
        ['unit.vox_engines'] = '噪轰引擎',
        -- English: Agitators
        ['unit.agitators'] = '惑乱者',
        -- English: Radicals
        ['unit.radicals'] = '激进先锋',
        -- English: Jet Brigade Troopers
        ['unit.jet_brigade_troopers'] = '喷气旅装甲兵',
        -- English: Jet Brigade MG Raiders
        ['unit.jet_brigade_mg_raiders'] = '喷气旅机枪装甲兵',
        -- English: Jet Brigade Commissars
        ['unit.jet_brigade_commissars'] = '喷气旅机械统帅',
        -- English: Incendiary Rocket Raiders
        ['unit.incendiary_rocket_raiders'] = '燃烧火箭奇袭者',
        -- English: Hulk Firebombers
        ['unit.hulk_firebombers'] = '巨型烈焰轰炸者',
        -- English: Incendiary MG Devastators
        ['unit.incendiary_mg_devastators'] = '燃烧机枪蹂躏者',
        -- English: Jet Brigade Hulk Scorchers
        ['unit.jet_brigade_hulk_scorchers'] = '喷气旅巨型炙炎者',
        -- English: Jet Brigade Hulk Bruisers
        ['unit.jet_brigade_hulk_bruisers'] = '喷气旅巨型碾压者',
        -- English: Elevated Overseers
        ['unit.elevated_overseers'] = '崇高监视者',
        -- English: Harvesters
        ['unit.harvesters'] = '猎杀器',
        -- English: Watchers
        ['unit.watchers'] = '守望者',
        -- English: Overseers
        ['unit.overseers'] = '监视者',
        -- English: Voteless
        ['unit.voteless'] = '无票者',
        -- English: Stingrays
        ['unit.stingrays'] = '刺魟',
        -- English: Fleshmobs
        ['unit.fleshmobs'] = '肉瘤体',
        -- English: Leviathans
        ['unit.leviathans'] = '利维坦',
        -- English: Crescent Overseers
        ['unit.crescent_overseers'] = '新月监视者',
        -- English: Veracitors
        ['unit.veracitors'] = '证真者',
        -- English: Gatekeepers
        ['unit.gatekeepers'] = '御门者',
        -- English: Obtruders
        ['unit.obtruders'] = '突入者',
        -- English: Crushers
        ['unit.crushers'] = '粉碎者',
        -- English: Wretches
        ['unit.wretches'] = '悲怜体',
    },
}

end)()
install({create_api=create_api,mission=mission,resolve=resolve,roster=roster,roster_data=roster_data,model=model,panel=panel,presentation=presentation,text=text,locales=locales,runtime=runtime,runtime_memory=runtime_memory,build={revision='v4.1.1',game_sha256='61DCFCD201DACBF3545C97BEB8A5A6186E9850D2670BF60B0E058320B477F6DF',exe_sha256='257FD7DE21A04E8668E02E5C820EDF3435176FBDE3569765255CC52A5EA20F9D'}})
