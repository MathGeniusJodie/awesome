-- timebar.lua
-- Time-blindness aid: two bars across the top of each screen.
--
-- Bar 1: Day progress dots.
--   • 102 white dots = 102×10-min blocks from 6:30am to 11:30pm.
--   • Dots drain from the left one-by-one every 10 min (remaining time fills from right).
--   • Outside those hours: solid red pill bar.
--
-- Bar 2: 10-min block countdown.
--   • Full width at the start of every 10-min block.
--   • Shrinks to zero over those 10 min, then snaps back.

local wibox = require("wibox")
local gears = require("gears")

-- Layout constants.
local BAR_HEIGHT  = 8   -- px height of each bar (corner radius = BAR_HEIGHT / 2)
local BAR_SPACING = 3   -- px gap between the two bars
local BAR_MARGIN  = 0   -- px gap between screen top edge and bar 1

local M = {}

local DAY_START_MIN = 6 * 60 + 00    -- 06:00am
local DAY_END_MIN   = 23 * 60 + 30   -- 11:30pm
local TOTAL_BLOCKS  = (DAY_END_MIN - DAY_START_MIN) / 10

local function get_state()
    local t    = os.date("*t")
    local mins = t.hour * 60 + t.min
    local secs = t.sec

    local in_day = mins >= DAY_START_MIN and mins < DAY_END_MIN

    local remaining
    if not in_day then
        remaining = (mins < DAY_START_MIN) and TOTAL_BLOCKS or 0
    else
        remaining = TOTAL_BLOCKS - math.floor((mins - DAY_START_MIN) / 10)
    end

    local block_frac = ((mins % 10) * 60 + secs) / 600.0

    return in_day, remaining, block_frac
end

function M.setup(s)
    local sw  = s.geometry.width
    local tau = math.pi * 2

    local canvas = wibox.widget.base.make_widget()

    function canvas:fit(_, w, h)
        return w, h
    end

    function canvas:draw(_, cr, w, h)
        local in_day, remaining, block_frac = get_state()
        local r_full = BAR_HEIGHT / 2   -- corner radius when width allows full rounding

        -- ── Bar 1: day progress ────────────────────────────────────────────
        -- Pills laid out left-to-right; remaining pills fill from the right.
        local usable = w
        if not in_day then
            cr:set_source_rgb(0.9, 0.15, 0.15)
            gears.shape.rounded_rect(cr, usable, BAR_HEIGHT, r_full)
            cr:fill()
        elseif remaining > 0 then
            cr:set_source_rgb(0, 0, 0)
            local gap    = 2
            local pill_w = (usable - (TOTAL_BLOCKS - 1) * gap) / TOTAL_BLOCKS
            local r      = math.min(r_full, pill_w * 0.5)
            -- Remaining pills aligned to right edge.
            for i = 0, remaining - 1 do
                local x = usable - (i + 1) * pill_w - i * gap
                cr:save()
                cr:translate(x, 0)
                gears.shape.rounded_rect(cr, pill_w, BAR_HEIGHT, r)
                cr:fill()
                cr:restore()
            end
        end

        -- ── Bar 2: 10-min block countdown ──────────────────────────────────
        -- Fills from left, shrinks rightward over 10 min.
        local bar_w = w * (1.0 - block_frac)
        if bar_w > 0.5 then
            cr:set_source_rgb(1, 1, 1)
            cr:save()
            cr:translate(0, BAR_HEIGHT + BAR_SPACING)
            gears.shape.rounded_rect(cr, bar_w, BAR_HEIGHT, math.min(r_full, bar_w * 0.5))
            cr:fill()
            cr:restore()
        end
    end

    local bar_total_h = BAR_HEIGHT * 2 + BAR_SPACING

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
