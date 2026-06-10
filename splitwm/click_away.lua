---------------------------------------------------------------------------
-- splitwm.click_away — shared "click outside closes the popup" watcher.
--
-- Polls the mouse while a popup is visible and calls dismiss() when a
-- button press lands outside it. Arming waits for all buttons to be
-- released first, so the click that opened the popup never closes it.
--
-- Usage:
--   local watcher = click_away.new {
--       visible = function() return popup.visible end,
--       inside  = function(m) ... end,  -- m = mouse.coords()
--       dismiss = function() popup.visible = false end,
--   }
--   watcher.arm()   -- when the popup opens
--   watcher.stop()  -- optional; also stops itself once not visible
---------------------------------------------------------------------------

local gears = require("gears")

local click_away = {}

function click_away.new(opts)
    local self = { ready = false }

    self.timer = gears.timer {
        timeout   = 0.05,
        autostart = false,
        callback  = function()
            if not opts.visible() then
                self.stop()
                return
            end
            local m = mouse.coords()
            local pressed = m.buttons[1] or m.buttons[3]
            if not self.ready then
                if not pressed then self.ready = true end
                return
            end
            if pressed and not opts.inside(m) then
                opts.dismiss()
                self.stop()
            end
        end,
    }

    function self.arm()
        self.ready = false
        if self.timer.started then self.timer:stop() end
        self.timer:start()
    end

    function self.stop()
        self.ready = false
        if self.timer.started then self.timer:stop() end
    end

    return self
end

return click_away
