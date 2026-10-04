local factory = dofile("src/ui/capture.lua")
local state = { focus = true, cursor = false, clip = false }
local fail = false
local captured = 0
local native = {
    mcm_install = function()
        return 1
    end,
    mcm_capture = function(value)
        captured = value
        return 1
    end,
    mcm_captured = function()
        return captured
    end,
    mcm_release = function()
        captured = 0
    end,
}
local window = {
    mouse_focus = function()
        return state.focus
    end,
    show_cursor = function()
        return state.cursor
    end,
    clip_cursor = function()
        return state.clip
    end,
    set_mouse_focus = function(value)
        if fail then
            return false
        end
        state.focus = value
    end,
    set_show_cursor = function(value)
        state.cursor = value
    end,
    set_clip_cursor = function(value)
        state.clip = value
    end,
}
local capture = factory.new(native, window, function() end)
assert(capture.sync(true, true, {}))
assert(not state.focus and state.cursor and state.clip)
fail = true
local done = capture.release()
assert(done == false and capture.status().pending_restore and captured == 0)
assert(not capture.sync(true, true, {}))
assert(capture.acquire("new owner") == nil)
fail = false
assert(capture.sync(false, true, {}))
assert(state.focus and not state.cursor and not state.clip and not capture.status().pending_restore)
assert(capture.sync(true, true, {}))
assert(capture.release())
assert(state.focus and not state.cursor and not state.clip)
local token = assert(capture.acquire("external"))
fail = true
assert(capture.release(token) == false and capture.owns(token))
fail = false
assert(capture.release(token) and not capture.owns(token))
assert(capture.shutdown())
print(
    "PASS merged input repair: snapshot retained on failed restoration, safe retry, baseline acquisition blocked until restore, external ownership retained and repeated close"
)
