local gears = require("gears")
local icons = {}

---------------------------------------------------------------------------
-- Icon drawing functions (cr, w, h)
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

function icons.chip(cr, w, h)
    local cw, ch  = 15, 11
    local pin_len = 3
    local n_pins  = 3
    local bx = math.floor(w / 2) - math.floor(cw / 2)
    local by = math.floor(h / 2) - math.floor(ch / 2)

    cr:set_line_width(2)
    local pin_spacing = (ch - 2) / (n_pins - 1)
    for i = 1, n_pins do
        local py = by + 1 + (i - 1) * pin_spacing
        cr:move_to(bx,      py) cr:line_to(bx - pin_len,      py) cr:stroke()
        cr:move_to(bx + cw, py) cr:line_to(bx + cw + pin_len, py) cr:stroke()
    end

    cr:save()
    cr:translate(bx, by)
    gears.shape.rounded_rect(cr, cw, ch, 1.5)
    cr:restore()
    cr:stroke()
end

function icons.lock(cr, w, h)
    local cx = w / 2
    -- Shackle: arc on top
    cr:set_line_width(w * 0.165)
    local sy = h * 0.465
    local sr = w * 0.275
    cr:arc(cx, sy, sr, math.pi, 0)
    cr:stroke()
    -- Body: rounded rect, lower portion
    local bx, by = w * 0.09, h * 0.41
    local bw, bh = w * 0.82, h * 0.56
    cr:save()
    cr:translate(bx, by)
    gears.shape.rounded_rect(cr, bw, bh, bw * 0.18)
    cr:restore()
    cr:fill()
end

function icons.speaker(cr, _, h)
    local s  = h / 32.0
    local cy = h / 2
    local sx = 1 * s

    cr:move_to(sx,           cy + 4*s)
    cr:line_to(sx,           cy - 4*s)
    cr:line_to(sx + 4*s,     cy - 4*s)
    cr:line_to(sx + 10*s,    cy - 8*s)
    cr:line_to(sx + 10*s,    cy + 8*s)
    cr:line_to(sx + 4*s,     cy + 4*s)
    cr:close_path()
    cr:fill()
end

return icons
