local awful  = require("awful")
local gears  = require("gears")
local wibox  = require("wibox")

local status = {}

local battery_widgets = {}
local volume_widgets  = {}
local chip_widgets    = {}

---------------------------------------------------------------------------
-- Widget factories
---------------------------------------------------------------------------

function status.new_battery_widget()
    local w = wibox.widget.base.make_widget()
    w.percentage = 0
    w.charging   = false

    function w:fit(_, _, h) return 24, h end

    function w:draw(_, cr, width, height)
        -- Horizontal orientation: nub on the right, fill left-to-right
        local bw, bh = 17, 11
        local nub_w, nub_h = 2, 5
        local total_w = bw + nub_w
        local bx = math.floor((width - total_w) / 2)
        local by = math.floor((height - bh) / 2)
        local nub_x = bx + bw
        local nub_y = by + math.floor((bh - nub_h) / 2)

        local pct = math.max(0, math.min(100, self.percentage))

        -- Nub (right side)
        cr:set_source_rgba(1, 1, 1, 1)
        cr:rectangle(nub_x, nub_y, nub_w, nub_h)
        cr:fill()

        -- Body outline
        cr:set_source_rgba(1, 1, 1, 1)
        cr:set_line_width(2)
        cr:save()
        cr:translate(bx, by)
        gears.shape.rounded_rect(cr, bw, bh, 1.5)
        cr:restore()
        cr:stroke()

        -- Fill (left to right)
        if pct <= 20 then
            cr:set_source_rgba(1, 0.3, 0.3, 1)
        elseif pct <= 40 then
            cr:set_source_rgba(1, 0.65, 0.15, 1)
        else
            cr:set_source_rgba(1, 1, 1, 1)
        end
        local fill_w = math.max(0, math.floor((bw - 4) * pct / 100))
        if fill_w > 0 then
            cr:rectangle(bx + 2, by + 2, fill_w, bh - 4)
            cr:fill()
        end

        -- Lightning bolt when charging (horizontal zigzag)
        if self.charging then
            cr:set_source_rgba(1, 1, 0, 1)
            cr:set_line_width(1.5)
            local cx = bx + bw / 2
            local cy = by + bh / 2
            cr:move_to(bx + bw - 2, by + 2)
            cr:line_to(cx + 1, cy)
            cr:line_to(cx + 2, cy)
            cr:line_to(bx + 2, by + bh - 2)
            cr:stroke()
        end
    end

    table.insert(battery_widgets, w)
    return w
end

function status.new_volume_widget()
    local w = wibox.widget.base.make_widget()
    w.volume = 0
    w.muted  = false

    function w:fit(_, _, h)
        return math.ceil(26 * h / 32), h
    end

    function w:draw(_, cr, _, height)
        -- Scale all coordinates proportionally to height (designed for 32px)
        local s  = height / 32.0
        local cy = height / 2
        local sx = 1 * s

        cr:set_source_rgba(1, 1, 1, 1)

        -- Speaker body: box + flared cone (filled polygon)
        cr:move_to(sx,           cy + 4*s)
        cr:line_to(sx,           cy - 4*s)
        cr:line_to(sx + 4*s,     cy - 4*s)
        cr:line_to(sx + 10*s,    cy - 8*s)
        cr:line_to(sx + 10*s,    cy + 8*s)
        cr:line_to(sx + 4*s,     cy + 4*s)
        cr:close_path()
        cr:fill()

        -- Sound waves or mute X, starting just right of the cone tip
        local ax = sx + 10*s
        cr:set_line_width(1.5 * s)

        if self.muted then
            local cx, ms = ax + 7*s, 3.5*s
            cr:set_line_width(2.5 * s)
            cr:set_line_cap(1)  -- ROUND
            cr:move_to(cx - ms, cy - ms) cr:line_to(cx + ms, cy + ms) cr:stroke()
            cr:move_to(cx + ms, cy - ms) cr:line_to(cx - ms, cy + ms) cr:stroke()
        else
            local waves = self.volume > 60 and 3
                       or self.volume > 25 and 2
                       or self.volume >  0 and 1
                       or 0
            for i = 1, waves do
                cr:arc(ax, cy, i * 3.5 * s, -math.pi / 2.8, math.pi / 2.8)
                cr:stroke()
            end
        end
    end

    table.insert(volume_widgets, w)
    return w
end

function status.new_chip_widget()
    local w = wibox.widget.base.make_widget()
    w.cpu  = 0
    w.ram  = 0
    w.swap = 0

    local cw, ch    = 15, 11
    local pin_len   = 3
    local n_pins    = 3

    function w:fit(_, _, h) return cw + pin_len * 2 + 6, h end

    function w:draw(_, cr, width, height)
        local cx = math.floor(width / 2)
        local cy = math.floor(height / 2)
        local bx = cx - math.floor(cw / 2)
        local by = cy - math.floor(ch / 2)

        -- Pins (left and right sides)
        cr:set_source_rgba(1, 1, 1, 1)
        cr:set_line_width(2)
        local pin_spacing = (ch - 2) / (n_pins - 1)
        for i = 1, n_pins do
            local py = by + 1 + (i - 1) * pin_spacing
            cr:move_to(bx,          py) cr:line_to(bx - pin_len,      py) cr:stroke()
            cr:move_to(bx + cw,     py) cr:line_to(bx + cw + pin_len, py) cr:stroke()
        end

        -- Body outline: identical to battery (line_width 2, radius 1.5)
        cr:set_source_rgba(1, 1, 1, 1)
        cr:set_line_width(2)
        cr:save()
        cr:translate(bx, by)
        gears.shape.rounded_rect(cr, cw, ch, 1.5)
        cr:restore()
        cr:stroke()

        -- 3 vertical gauges inside body, 1px gap between them
        -- Inner area matches battery fill inset: 2px from each edge
        local pad = 2
        local gap = 1
        local n   = 3
        local gh  = ch - pad * 2
        local gw  = math.floor((cw - pad * 2 - gap * (n - 1)) / n)
        local gy  = by + pad

        local gauges = {
            { pct = self.cpu,  r = 1,   g = 1,   b = 1   },
            { pct = self.ram,  r = 1,   g = 1,   b = 1   },
            { pct = self.swap, r = 1,   g = 0.3, b = 0.3 },
        }

        for i, gauge in ipairs(gauges) do
            local gx = bx + pad + (i - 1) * (gw + gap)

            cr:set_source_rgba(1, 1, 1, 0.2)
            cr:rectangle(gx, gy, gw, gh)
            cr:fill()

            local fill_h = math.floor(gh * math.max(0, math.min(1, gauge.pct)))
            if fill_h > 0 then
                cr:set_source_rgba(gauge.r, gauge.g, gauge.b, 0.9)
                cr:rectangle(gx, gy + gh - fill_h, gw, fill_h)
                cr:fill()
            end
        end
    end

    table.insert(chip_widgets, w)
    return w
end

---------------------------------------------------------------------------
-- Refresh functions
---------------------------------------------------------------------------

local function refresh_battery()
    -- Synchronous io.open is intentional: sysfs files are kernel virtual
    -- files with no disk I/O. Spawning a subprocess would be heavier.
    for _, name in ipairs({ "BAT0", "BAT1", "BAT" }) do
        local fc = io.open("/sys/class/power_supply/" .. name .. "/capacity", "r")
        if fc then
            local cap = tonumber(fc:read("*l")); fc:close()
            -- Skip phantom batteries that exist in sysfs but report no capacity
            if not cap then goto continue end
            local fs = io.open("/sys/class/power_supply/" .. name .. "/status", "r")
            local stat = fs and fs:read("*l") or ""
            if fs then fs:close() end
            for _, w in ipairs(battery_widgets) do
                w.percentage = cap
                w.charging   = (stat == "Charging")
                w:emit_signal("widget::redraw_needed")
            end
            return
        end
        ::continue::
    end
end

local function refresh_volume_internal()
    awful.spawn.easy_async_with_shell(
        "pactl get-sink-mute @DEFAULT_SINK@ 2>/dev/null; pactl get-sink-volume @DEFAULT_SINK@ 2>/dev/null",
        function(out)
            local muted = out:match("Mute: yes") ~= nil
            local vol   = tonumber(out:match("(%d+)%%")) or 0
            for _, w in ipairs(volume_widgets) do
                w.volume = vol
                w.muted  = muted
                w:emit_signal("widget::redraw_needed")
            end
        end
    )
end

function status.refresh_volume()
    refresh_volume_internal()
end

local _cpu_prev_idle, _cpu_prev_total = 0, 0

local function refresh_chip()
    -- Synchronous io.open is intentional: /proc/stat and /proc/meminfo are
    -- kernel virtual files with no disk I/O. Spawning subprocesses would be heavier.
    -- CPU: read /proc/stat
    local f = io.open("/proc/stat", "r")
    local cpu_pct = 0
    if f then
        local line = f:read("*l"); f:close()
        local vals = {}
        for v in line:gmatch("%d+") do vals[#vals+1] = tonumber(v) end
        local idle  = (vals[4] or 0) + (vals[5] or 0)
        local total = 0
        for _, v in ipairs(vals) do total = total + v end
        local d_idle  = idle  - _cpu_prev_idle
        local d_total = total - _cpu_prev_total
        if d_total > 0 then
            cpu_pct = 1 - d_idle / d_total
        end
        _cpu_prev_idle, _cpu_prev_total = idle, total
    end

    -- RAM + swap: read /proc/meminfo
    local ram_pct, swap_pct = 0, 0
    local mf = io.open("/proc/meminfo", "r")
    if mf then
        local mem = {}
        for line in mf:lines() do
            local k, v = line:match("^(%w+):%s+(%d+)")
            if k then mem[k] = tonumber(v) end
        end
        mf:close()
        local total_mem = mem["MemTotal"] or 1
        local avail_mem = mem["MemAvailable"] or total_mem
        ram_pct = 1 - avail_mem / total_mem

        local swap_total = mem["SwapTotal"] or 0
        local swap_free  = mem["SwapFree"]  or swap_total
        if swap_total > 0 then
            swap_pct = 1 - swap_free / swap_total
        end
    end

    for _, w in ipairs(chip_widgets) do
        w.cpu  = cpu_pct
        w.ram  = ram_pct
        w.swap = swap_pct
        w:emit_signal("widget::redraw_needed")
    end
end

---------------------------------------------------------------------------
-- Timers (start immediately on require)
---------------------------------------------------------------------------

status._timers = {
    gears.timer { timeout = 30, autostart = true, call_now = true, callback = refresh_battery },
    gears.timer { timeout = 2,  autostart = true, call_now = true, callback = refresh_volume_internal },
    gears.timer { timeout = 2,  autostart = true, call_now = true, callback = refresh_chip },
}

return status
