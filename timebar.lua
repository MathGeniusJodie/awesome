-- timebar.lua
-- Time-blindness aid: two bars on the left edge of each screen.
--
-- Bar 1: Day progress dots.
--   • 102 white dots = 102×10-min blocks from 6:30am to 11:30pm.
--   • Dots drain from the top one-by-one every 10 min (remaining time fills from bottom).
--   • Outside those hours: solid red pill bar.
--
-- Bar 2: 10-min block countdown.
--   • Full height at the start of every 10-min block.
--   • Shrinks to zero over those 10 min, then snaps back.

local wibox = require("wibox")
local gears = require("gears")

-- Layout constants — tweak these to reshape both bars at once.
local BAR_WIDTH   = 6   -- px width of each bar (corner radius = BAR_WIDTH / 2)
local BAR_SPACING = 3   -- px gap between the two bars
local BAR_MARGIN  = 3   -- px gap between screen left edge and bar 1

local M = {}

local DAY_START_MIN = 6 * 60 + 30    -- 6:30am  = 390 min since midnight
local DAY_END_MIN   = 23 * 60 + 30   -- 11:30pm = 1410 min since midnight
local TOTAL_BLOCKS  = 102             -- (1410 - 390) / 10

local function get_state()
    local t    = os.date("*t")
    local mins = t.hour * 60 + t.min
    local secs = t.sec

    local in_day = mins >= DAY_START_MIN and mins < DAY_END_MIN

    local remaining
    if not in_day then
        -- Before day: all blocks remain (full bar in red).
        -- After day: no blocks remain (empty bar in red).
        remaining = (mins < DAY_START_MIN) and TOTAL_BLOCKS or 0
    else
        remaining = TOTAL_BLOCKS - math.floor((mins - DAY_START_MIN) / 10)
    end

    -- Fraction through the current 10-min block (0 = just started, 1 = about to end).
    local block_frac = ((mins % 10) * 60 + secs) / 600.0

    return in_day, remaining, block_frac
end

function M.setup(s)
    local sh  = s.geometry.height
    local tau = math.pi * 2

    local canvas = wibox.widget.base.make_widget()

    function canvas:fit(_, w, h)
        return w, h
    end

    function canvas:draw(_, cr, w, h)
        local in_day, remaining, block_frac = get_state()
        local r_full = BAR_WIDTH / 2   -- corner radius when height allows full rounding

        -- ── Bar 1: day progress ────────────────────────────────────────────
        -- 3px margin top and bottom, 1px gaps between pills.
        local usable = h - 6
        if not in_day then
            -- Red pill with same 3px top/bottom margin.
            cr:set_source_rgb(0.9, 0.15, 0.15)
            cr:save()
            cr:translate(0, 3)
            gears.shape.rounded_rect(cr, BAR_WIDTH, usable, r_full)
            cr:fill()
            cr:restore()
        elseif remaining > 0 then
            -- Black pills stacked from the bottom upward, 1px apart.
            cr:set_source_rgb(0, 0, 0)
            local gap    = 1
            local pill_h = (usable - 101 * gap) / 102
            local r      = math.min(r_full, pill_h * 0.5)
            for i = 0, remaining - 1 do
                -- Bottom of pill i is at (h-3), stacking upward.
                local y = (h - 3) - (i + 1) * pill_h - i * gap
                cr:save()
                cr:translate(0, y)
                gears.shape.rounded_rect(cr, BAR_WIDTH, pill_h, r)
                cr:fill()
                cr:restore()
            end
        end

        -- ── Bar 2: 10-min block countdown ──────────────────────────────────
        -- 3px margin top and bottom; drains from top → bottom over 10 min.
        local max_h = h - 6
        local bar_h = max_h * (1.0 - block_frac)
        if bar_h > 0.5 then
            cr:set_source_rgb(1, 1, 1)
            cr:save()
            -- Bottom edge fixed at h-3; top edge rises as block progresses.
            cr:translate(BAR_WIDTH + BAR_SPACING, (h - 3) - bar_h)
            gears.shape.rounded_rect(cr, BAR_WIDTH, bar_h, math.min(r_full, bar_h * 0.5))
            cr:fill()
            cr:restore()
        end
    end

    local timebox = wibox {
        x                = s.geometry.x + BAR_MARGIN,
        y                = s.geometry.y,
        width            = BAR_WIDTH * 2 + BAR_SPACING,
        height           = sh,
        bg               = "#00000000",
        ontop            = false,
        screen           = s,
        visible          = true,
        type             = "dock",
        input_passthrough = true,
    }
    timebox:set_widget(canvas)

    -- Redraw every second for smooth block bar movement.
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
