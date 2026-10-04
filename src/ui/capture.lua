-- Capture lifetime is owned by the menu; all cursor state is restored on exit.
local M = {}
function M.new(native, window, log)
    local self = { active = false }
    local snapshot
    local external
    local function restore(saved)
        if not saved then
            return true
        end
        local errors = {}
        for _, field in ipairs({
            { "set_mouse_focus", "focus" },
            { "set_show_cursor", "cursor" },
            { "set_clip_cursor", "clip" },
        }) do
            local ok, result = pcall(window[field[1]], saved[field[2]])
            if not ok or result == false then
                errors[#errors + 1] = field[1]
                    .. ": "
                    .. tostring(ok and "restoration refused" or result)
            end
        end
        if #errors > 0 then
            return false, table.concat(errors, "; ")
        end
        return true
    end
    function self.acquire(owner)
        if type(owner) ~= "string" or owner == "" then
            return nil, "Owner name required"
        end
        if self.active or snapshot or external then
            return nil, "Input lease already owned"
        end
        local ok, saved = pcall(function()
            return {
                focus = window.mouse_focus(),
                cursor = window.show_cursor(),
                clip = window.clip_cursor(),
            }
        end)
        if not ok then
            return nil, tostring(saved)
        end
        local token = {}
        external = { owner = owner, token = token, snapshot = saved }
        return token
    end
    function self.owns(token)
        return external ~= nil and external.token == token
    end
    function self.release(token)
        if token ~= nil then
            if not self.owns(token) then
                return false, "Input lease not owned"
            end
            local ok, reason = restore(external.snapshot)
            if not ok then
                return false, reason
            end
            external = nil
            return true
        end
        -- Menu cleanup cannot alter another owner's cursor or native gate.
        if external then
            return false, "Input lease belongs to another owner"
        end
        native.mcm_release()
        self.active = false
        local ok, reason = restore(snapshot)
        if not ok then
            log("Menu cursor restoration pending: " .. tostring(reason))
            return false, reason
        end
        if snapshot then
            log("Menu cursor snapshot restored")
        end
        snapshot = nil
        return true
    end
    function self.status()
        return {
            owner = external and external.owner
                or (self.active and "mcm" or (snapshot and "mcm_restore" or nil)),
            active = self.active,
            pending_restore = snapshot ~= nil and not self.active,
        }
    end
    function self.sync(visible, focused, hwnd)
        if visible and external then
            return false, "Input lease belongs to " .. external.owner
        end
        if not visible or not focused then
            if self.active or snapshot then
                return self.release()
            end
            return true
        end
        if snapshot and not self.active then
            return false, "Previous cursor restoration pending"
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
    function self.shutdown()
        if external then
            local ok, reason = self.release(external.token)
            if not ok then
                return false, reason
            end
        end
        return self.release()
    end
    return self
end
return M
