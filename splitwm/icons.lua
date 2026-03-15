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

return icons
