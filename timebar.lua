-- timebar.lua
-- Time-blindness aid: solid bar across the top of each screen.
--
-- Bar: Day progress.
--   • Solid black rectangle, width proportional to remaining time in the day.
--   • Day runs from 6:30am to 11:30pm.
--   • Outside those hours: solid red bar.

local wibox = require("wibox")
local gears = require("gears")

-- Layout constants.
local BAR_HEIGHT  = 7   -- px height of the bar
local BAR_MARGIN  = 0   -- px gap between screen top edge and bar

local M = {}

local DAY_START_MIN = 6 * 60 + 30    -- 06:00am
local DAY_END_MIN   = 23 * 60 + 30   -- 11:30pm
local TOTAL_BLOCKS  = (DAY_END_MIN - DAY_START_MIN) / 10

local function get_state()
    local t    = os.date("*t")
    local mins = t.hour * 60 + t.min

    local in_day = mins >= DAY_START_MIN and mins < DAY_END_MIN

    local remaining
    if not in_day then
        remaining = (mins < DAY_START_MIN) and TOTAL_BLOCKS or 0
    else
        remaining = TOTAL_BLOCKS - math.floor((mins - DAY_START_MIN) / 10)
    end

    return in_day, remaining
end

function M.setup(s)
    local sw  = s.geometry.width

    local canvas = wibox.widget.base.make_widget()

    function canvas:fit(_, w, h)
        return w, h
    end

    function canvas:draw(_, cr, w, h)
        local in_day, remaining = get_state()

        -- ── Day progress: solid rectangle, proportional to remaining time ───
        if not in_day then
            cr:set_source_rgb(0.9, 0.15, 0.15)
            cr:rectangle(0, 0, w, BAR_HEIGHT)
            cr:fill()
        elseif remaining > 0 then
            cr:set_source_rgb(0, 0, 0)
            cr:rectangle(0, 0, w * (remaining / TOTAL_BLOCKS), BAR_HEIGHT)
            cr:fill()
        end
    end

    local bar_total_h = BAR_HEIGHT

    local timebox = wibox {
        x                 = s.geometry.x,
        y                 = s.geometry.y + BAR_MARGIN,
        width             = sw,
        height            = bar_total_h,
        bg                = "#00000000",
        ontop             = false,
        screen            = s,
        visible           = true,
        type              = "dock",
        input_passthrough = true,
    }
    timebox:struts({ top = BAR_MARGIN + bar_total_h })
    timebox:set_widget(canvas)

    gears.timer {
        timeout   = 1,
        autostart = true,
        call_now  = true,
        callback  = function()
            canvas:emit_signal("widget::redraw_needed")
        end,
    }

    return timebox
end

return M
