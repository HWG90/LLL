-- Exact files independently hashed before activation; loaded image stamps are
-- checked in process. No guessed engine structures or native game addresses.
local M = {
    exe_sha256 = 'f5fee03dcfdb2e553a4752c283590950ac13316b376d8196aa556ff0400d5f06',
    game_sha256 = '2e2c3b7c2500646dadd5f2b4c6e0504dbb7e7896139f64cddc0d1813c718f51e',
    lua_sha256 = '2c8720c9f446c848436ad993b1a88099d76f0b0b09df53689719b797c3039ce7',
    exe_timestamp = 0x6ab382e4, game_timestamp = 0x6ab3b43f,
    max_worlds = 32, max_entities = 32768,
    evidence = 'HD2 Lua binding candidate; see recorded live validation receipt',
}
function M.create(platform)
    return {
        builds = {{exe_sha256 = M.exe_sha256, game_sha256 = M.game_sha256}},
        max_worlds = M.max_worlds, max_entities = M.max_entities, evidence = M.evidence,
        validate = function() return platform.validate() end,
    }
end
return M
