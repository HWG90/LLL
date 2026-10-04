-- Capture lifetime is owned by the menu; all cursor state is restored on exit.
local M = {}
function M.new(native, window, log)
    local self = { active = false }
    local snapshot
    function self.release()
        native.mcm_release()
        if snapshot then
            pcall(window.set_mouse_focus, snapshot.focus)
            pcall(window.set_show_cursor, snapshot.cursor)
            pcall(window.set_clip_cursor, snapshot.clip)
            snapshot = nil
        end
        self.active = false
    end
    function self.sync(visible, focused, hwnd)
        if not visible or not focused then
            if self.active or snapshot then
                self.release()
            end
            return true
        end
        if not self.active then
            for _, name in ipairs({
                "mouse_focus",
                "show_cursor",
                "clip_cursor",
                "set_mouse_focus",
                "set_show_cursor",
                "set_clip_cursor",
            }) do
                if type(window[name]) ~= "function" then
                    return false, "Missing cursor API: " .. name
                end
            end
            snapshot = {
                focus = window.mouse_focus(),
                cursor = window.show_cursor(),
                clip = window.clip_cursor(),
            }
            local ok, err = pcall(function()
                assert(native.mcm_install(hwnd) ~= 0, "Native window capture unavailable")
                assert(native.mcm_capture(1) ~= 0, "Cannot acquire input capture")
                window.set_mouse_focus(false)
                window.set_show_cursor(true)
                window.set_clip_cursor(true)
            end)
            if not ok then
                self.release()
                return false, tostring(err)
            end
            self.active = true
            log("Menu input capture acquired")
        else
            -- The game may reset cursor flags during its own UI update.
            window.set_mouse_focus(false)
            window.set_show_cursor(true)
            window.set_clip_cursor(true)
            if native.mcm_captured() == 0 then
                self.release()
                return false, "Input capture lost"
            end
        end
        return true
    end
    return self
end
return M
