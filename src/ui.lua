-- Independent manager frontend with optional MCM integration.
return function(loader, platform, controls, report)
    local self = {}
    local menu, view, capture, input
    local initialize
    local api = LLL_UI_CORE.new(nil, function(msg)
        report("LLL UI", msg)
    end)
    controls.bind(api, "authors")
    self.api = api
    api.author_navigation = true
    api.loader_summary = controls.summary
    function self.open()
        if not menu and initialize then
            local ok, why = pcall(initialize)
            if not ok then
                self.close()
                self.unavailable = tostring(why)
                return false, self.unavailable
            end
        end
        if not menu then
            return false, self.unavailable or "Native manager unavailable"
        end
        local mcm = rawget(_G, "DBFMCM")
        if mcm and type(mcm.close) == "function" then
            mcm.close()
        end
        self.open_pending = true
        menu.visible = true
        return true
    end
    function self.close()
        self.open_pending = false
        if menu then
            menu.visible = false
        end
        if capture then
            capture.release()
        end
        if view then
            view.release()
        end
    end
    loader.open_manager = function()
        local ok, why = self.open()
        assert(ok, why)
    end
    local sr = rawget(_G, "stingray")
    if not sr or not sr.Window or not platform.settings then
        self.unavailable = "Native GUI unavailable"
        return self
    end
    local ffi = require("ffi")
    local bit = require("bit")
    pcall(
        ffi.cdef,
        [[
 typedef struct {long x;long y;} LLL_UI_POINT;
 short lll_ui_key(int) __asm__("GetAsyncKeyState");
 void *lll_ui_foreground(void) __asm__("GetForegroundWindow");
 int lll_ui_cursor(LLL_UI_POINT *) __asm__("GetCursorPos");
 int lll_ui_client(void *,LLL_UI_POINT *) __asm__("ScreenToClient");
 unsigned long lll_ui_window_process(void *,unsigned long *) __asm__("GetWindowThreadProcessId");
 unsigned long lll_ui_process(void) __asm__("GetCurrentProcessId");
 int lll_ui_rect(void *,long *) __asm__("GetClientRect");
 int mcm_install(void *);int mcm_capture(int);int mcm_captured(void);void mcm_release(void);int mcm_wheel(void);
 ]]
    )
    local user = ffi.load("user32")
    local hotkey_held = false
    local owner_kernel = ffi.load("kernel32")
    local owner_pid = owner_kernel.lll_ui_process()
    local owner_check = ffi.new("unsigned long[1]")
    function self.tick()
        local down = bit.band(tonumber(user.lll_ui_key(120)), 0x8000) ~= 0
        if down and not hotkey_held then
            local window = user.lll_ui_foreground()
            if window ~= nil then
                user.lll_ui_window_process(window, owner_check)
            end
            if window ~= nil and owner_check[0] == owner_pid then
                local ok, why = self.open()
                if not ok then
                    report("LLL UI", why)
                end
            end
        end
        hotkey_held = down
    end
    initialize = function()
        local helper = platform.settings .. "/" .. LLL_NATIVE.name
        if platform.read(helper) ~= LLL_NATIVE.bytes then
            assert(
                platform.write(helper, LLL_NATIVE.bytes),
                "Cannot extract manager capture helper"
            )
        end
        assert(platform.read(helper) == LLL_NATIVE.bytes, "Capture helper verification failed")
        local native = ffi.load(helper)
        local kernel = ffi.load("kernel32")
        local pid = kernel.lll_ui_process()
        local point = ffi.new("LLL_UI_POINT[1]")
        local rect = ffi.new("long[4]")
        local foreground_pid = ffi.new("unsigned long[1]")
        local foreground
        capture = LLL_UI_CAPTURE.new(native, sr.Window, function(msg)
            report("LLL UI", msg)
        end)
        view = LLL_UI_VIEW.new(sr)
        menu = LLL_UI_MENU.new(api, view.measure)
        self.menu = menu
        input = {}
        local suppress_toggle = bit.band(tonumber(user.lll_ui_key(120)), 0x8000) ~= 0
        function input.down(code)
            if code == 120 then
                return false
            end -- physical F9 is translated to the menu toggle
            if code == 121 then
                if suppress_toggle then
                    if bit.band(tonumber(user.lll_ui_key(120)), 0x8000) == 0 then
                        suppress_toggle = false
                    end
                    return false
                end
                code = 120
            end
            return foreground and bit.band(tonumber(user.lll_ui_key(code)), 0x8000) ~= 0 or false
        end
        function input.mouse()
            if
                not foreground
                or user.lll_ui_cursor(point) == 0
                or user.lll_ui_client(foreground, point) == 0
                or user.lll_ui_rect(foreground, rect) == 0
            then
                return
            end
            local w, h = sr.Gui.resolution()
            local cw, ch = tonumber(rect[2]), tonumber(rect[3])
            if cw <= 0 or ch <= 0 then
                return
            end
            return tonumber(point[0].x) * w / cw, h - tonumber(point[0].y) * h / ch
        end
        function input.wheel()
            return tonumber(native.mcm_wheel())
        end
        function self.tick(dt)
            local ok, why = pcall(function()
                foreground = user.lll_ui_foreground()
                if foreground ~= nil then
                    user.lll_ui_window_process(foreground, foreground_pid)
                    if foreground_pid[0] ~= pid then
                        foreground = nil
                    end
                end
                if self.open_pending then
                    if not foreground then
                        self.open_pending = false
                        menu.visible = false
                    else
                        local held = false
                        for _, code in ipairs({ 1, 2, 4, 5, 6 }) do
                            if bit.band(tonumber(user.lll_ui_key(code)), 0x8000) ~= 0 then
                                held = true
                                break
                            end
                        end
                        menu.visible = not held
                        if not held then
                            self.open_pending = false
                        end
                    end
                end
                local was = menu.visible
                menu.tick(input)
                if menu.visible and not was then
                    local mcm = rawget(_G, "DBFMCM")
                    if mcm and mcm.close then
                        mcm.close()
                    end
                end
                local mcm = rawget(_G, "DBFMCM")
                if mcm and mcm.is_open and mcm.is_open() then
                    menu.visible = false
                end
                if not foreground then
                    menu.visible = false
                end
                local acquired, reason = capture.sync(menu.visible, foreground ~= nil, foreground)
                if not acquired then
                    menu.visible = false
                    report("LLL UI", reason)
                end
                menu.advance(dt)
                local w, h = sr.Gui.resolution()
                view.draw(menu.compose(w, h))
            end)
            if not ok then
                self.close()
                menu.recover()
                report("LLL UI", tostring(why))
            end
        end
        report("LLL UI", "Independent manager initialized on demand")
    end
    report("LLL UI", "F9 ready; manager initializes on first open")
    return self
end
