local gears = require("gears")
local wibox = require("wibox")

local icons = {}

---------------------------------------------------------------------------
-- Split overlay icon drawing functions (cr, w, h)
---------------------------------------------------------------------------

function icons.plus(cr, w, h)
    local cx, cy, s = w/2, h/2, 4
    cr:move_to(cx-s, cy); cr:line_to(cx+s, cy); cr:stroke()
    cr:move_to(cx, cy-s); cr:line_to(cx, cy+s); cr:stroke()
end

function icons.vsplit(cr, w, h)
    local cx, cy, bw, bh, br = w/2, h/2, 10, 10, 1
    local bx, by = cx-bw/2, cy-bh/2
    cr:new_sub_path()
    cr:arc(bx+bw-br, by+br,    br, -math.pi/2, 0)
    cr:arc(bx+bw-br, by+bh-br, br,  0,         math.pi/2)
    cr:arc(bx+br,    by+bh-br, br,  math.pi/2, math.pi)
    cr:arc(bx+br,    by+br,    br,  math.pi,   3*math.pi/2)
    cr:close_path()
    cr:stroke()
    cr:move_to(cx, by+1); cr:line_to(cx, by+bh-1); cr:stroke()
end

function icons.hsplit(cr, w, h)
    local cx, cy, bw, bh, br = w/2, h/2, 10, 10, 1
    local bx, by = cx-bw/2, cy-bh/2
    cr:new_sub_path()
    cr:arc(bx+bw-br, by+br,    br, -math.pi/2, 0)
    cr:arc(bx+bw-br, by+bh-br, br,  0,         math.pi/2)
    cr:arc(bx+br,    by+bh-br, br,  math.pi/2, math.pi)
    cr:arc(bx+br,    by+br,    br,  math.pi,   3*math.pi/2)
    cr:close_path()
    cr:stroke()
    cr:move_to(bx+1, cy); cr:line_to(bx+bw-1, cy); cr:stroke()
end

function icons.close(cr, w, h)
    local cx, cy, s = w/2, h/2, 4
    cr:move_to(cx-s, cy-s); cr:line_to(cx+s, cy+s); cr:stroke()
    cr:move_to(cx+s, cy-s); cr:line_to(cx-s, cy+s); cr:stroke()
end

function icons.swap(cr, w, h)
    local cx, cy, s, ay = w/2, h/2, 4, 3
    cr:move_to(cx - s, cy - ay); cr:line_to(cx + s, cy - ay); cr:stroke()
    cr:move_to(cx + s - 3, cy - ay - 2); cr:line_to(cx + s, cy - ay); cr:line_to(cx + s - 3, cy - ay + 2); cr:stroke()
    cr:move_to(cx + s, cy + ay); cr:line_to(cx - s, cy + ay); cr:stroke()
    cr:move_to(cx - s + 3, cy + ay - 2); cr:line_to(cx - s, cy + ay); cr:line_to(cx - s + 3, cy + ay + 2); cr:stroke()
end

---------------------------------------------------------------------------
-- Status bar widget factories
---------------------------------------------------------------------------

function icons.battery_widget()
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

    return w
end

function icons.volume_widget()
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

    return w
end

function icons.chip_widget()
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

    return w
end

return icons
