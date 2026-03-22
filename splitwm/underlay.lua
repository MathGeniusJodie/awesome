---------------------------------------------------------------------------
-- splitwm.underlay — Underlay wibox, wallpaper, and drag handles
--
-- Owns the per-screen "desktop"-type wibox that hosts:
--   • wallpaper rendering
--   • leaf chrome layer (painted by titlebar.lua via make_wb_proxy)
--   • resize drag handle layer
--
-- Call M.setup(deps) once from splitwm.setup() before use.
---------------------------------------------------------------------------

local awful     = require("awful")
local gears     = require("gears")
local wibox     = require("wibox")
local beautiful = require("beautiful")
local tree      = require("splitwm.tree")

local M = {}

-- Injected by M.setup()
local BTN_SIZE, MIN_SPLIT_W, MIN_SPLIT_H
local color_bg, color_fg, color_transparent, color_handle

function M.setup(deps)
    BTN_SIZE          = deps.BTN_SIZE
    MIN_SPLIT_W       = deps.MIN_SPLIT_W
    MIN_SPLIT_H       = deps.MIN_SPLIT_H
    color_bg          = deps.color_bg
    color_fg          = deps.color_fg
    color_transparent = deps.color_transparent
    color_handle      = deps.color_handle
end

---------------------------------------------------------------------------
-- Per-screen underlay wibox: wallpaper + chrome + handles in one surface,
-- stacked below all windows and panels (type = "desktop").
---------------------------------------------------------------------------

local underlay_cache = {}

local function make_wallpaper_widget()
    local w = wibox.widget.base.make_widget()
    w._surface = nil
    w._sw, w._sh = 0, 0
    function w:draw(_, cr, width, height)
        if not self._surface then return end
        local scale = math.max(width / self._sw, height / self._sh)
        cr:save()
        cr:translate((width - self._sw * scale) / 2, (height - self._sh * scale) / 2)
        cr:scale(scale, scale)
        cr:set_source_surface(self._surface, 0, 0)
        cr:paint()
        cr:restore()
    end
    function w:fit(_, w, h) return w, h end
    return w
end

function M.get_or_create_underlay(s)
    if underlay_cache[s] then return underlay_cache[s] end
    local wallpaper_w  = make_wallpaper_widget()
    local chrome_layer = wibox.layout.manual()
    local handle_layer = wibox.layout.manual()
    local wb = wibox {
        screen  = s,
        x       = s.geometry.x,
        y       = s.geometry.y,
        width   = s.geometry.width,
        height  = s.geometry.height,
        bg      = color_bg,
        visible = true,
        type    = "desktop",
    }
    wb:setup { wallpaper_w, chrome_layer, handle_layer, layout = wibox.layout.stack }
    local entry = { wb = wb, chrome_layer = chrome_layer, handle_layer = handle_layer, wallpaper_w = wallpaper_w }
    underlay_cache[s] = entry
    return entry
end

-- Creates a wibox-compatible proxy widget placed in a wibox.layout.manual layer.
function M.make_wb_proxy(layer, s)
    local container = wibox.container.background()
    local px, py, rw, rh = 0, 0, 0, 0
    local pt = { x = px, y = py }
    container.point         = function() return pt end
    container.forced_width  = 0
    container.forced_height = 0
    layer:add(container)

    local proxy = {
        setup          = function(_, tree)    container.widget = wibox.widget(tree) end,
        buttons        = function(_, b)       container:buttons(b)                  end,
        connect_signal = function(_, sig, fn) container:connect_signal(sig, fn)     end,
    }
    setmetatable(proxy, {
        __index = function(_, k)
            if     k == "x"       then return px + s.geometry.x
            elseif k == "y"       then return py + s.geometry.y
            elseif k == "width"   then return rw
            elseif k == "height"  then return rh
            elseif k == "visible" then return container.visible
            else                       return container[k] end
        end,
        __newindex = function(_, k, v)
            if k == "x" then
                local new = v - s.geometry.x
                if new == px then return end
                px = new; pt.x = new
                container:emit_signal("widget::layout_changed")
            elseif k == "y" then
                local new = v - s.geometry.y
                if new == py then return end
                py = new; pt.y = new
                container:emit_signal("widget::layout_changed")
            elseif k == "width" then
                if v == rw then return end
                rw = v
                container.forced_width = container.visible and v or 0
                container:emit_signal("widget::layout_changed")
            elseif k == "height" then
                if v == rh then return end
                rh = v
                container.forced_height = container.visible and v or 0
                container:emit_signal("widget::layout_changed")
            elseif k == "visible" then
                if v == container.visible then return end
                container.visible       = v
                container.forced_width  = v and rw or 0
                container.forced_height = v and rh or 0
                container:emit_signal("widget::layout_changed")
            else
                container[k] = v
            end
        end,
    })
    return proxy
end

function M.set_wallpaper(s, ws)
    local u = M.get_or_create_underlay(s)
    u.wb.bg = ws.dark
    if ws.has_bg then
        local surf = gears.surface.load(ws.bg)
        u.wallpaper_w._surface = surf
        u.wallpaper_w._sw      = surf:get_width()
        u.wallpaper_w._sh      = surf:get_height()
        gears.wallpaper.maximized(ws.bg, s, true)
    else
        u.wallpaper_w._surface = nil
        gears.wallpaper.set(ws.dark)
    end
    u.wallpaper_w:emit_signal("widget::redraw_needed")
end

---------------------------------------------------------------------------
-- Drag handles
---------------------------------------------------------------------------

local drag_handle_pool = {}

local function get_drag_handle(s, i)
    if not drag_handle_pool[s] then drag_handle_pool[s] = {} end
    if drag_handle_pool[s][i] then return drag_handle_pool[s][i] end

    local ref = { b = nil, handle_w = 1 }
    local handle_state = "idle"
    local wb = M.make_wb_proxy(M.get_or_create_underlay(s).handle_layer, s)
    wb.visible = false

    wb.bg    = color_transparent
    wb.shape = function(cr, w, h)
        local pw = BTN_SIZE
        cr:save()
        cr:translate(math.floor((w - pw) / 2), 0)
        gears.shape.rounded_rect(cr, pw, h, math.floor(pw / 2))
        cr:restore()
    end

    wb:buttons(gears.table.join(
        awful.button({}, 1, function()
            if not ref.b then return end
            handle_state = "dragging"
            wb.bg = color_fg
            local b, hw = ref.b, ref.handle_w
            mousegrabber.run(function(mouse)
                if not mouse.buttons[1] then
                    handle_state = "idle"; wb.bg = color_transparent; awful.layout.arrange(s); return false
                end
                local igap = b.parent_gap or 0
                if b.dir == tree.DIR_H then
                    local usable = b.parent_w - igap
                    local min_r  = MIN_SPLIT_W / usable
                    b.branch.ratio = math.max(min_r, math.min(1 - min_r, (mouse.x - b.parent_x - math.floor(igap / 2)) / usable))
                    wb.x = mouse.x - math.floor(hw / 2)
                else
                    local usable = b.parent_h - igap
                    local min_r  = MIN_SPLIT_H / usable
                    b.branch.ratio = math.max(min_r, math.min(1 - min_r, (mouse.y - b.parent_y) / usable))
                    wb.y = mouse.y - math.floor(hw / 2)
                end
                awful.layout.arrange(s)
                return true
            end, b.dir == tree.DIR_H and "sb_h_double_arrow" or "sb_v_double_arrow")
        end)
    ))
    wb:connect_signal("mouse::enter", function() if handle_state ~= "dragging" then wb.bg = color_handle end end)
    wb:connect_signal("mouse::leave", function() if handle_state ~= "dragging" then wb.bg = color_transparent end end)

    local entry = { wb = wb, ref = ref }
    drag_handle_pool[s][i] = entry
    return entry
end

function M.update_drag_handles(s, state, bounds)
    for _, c in ipairs(s.clients) do
        if c.fullscreen then
            local pool = drag_handle_pool[s]
            if pool then for _, entry in ipairs(pool) do entry.wb.visible = false end end
            return
        end
    end

    local gap      = beautiful.splitwm_gap
    local handle_w = gap - 4
    local hi       = 0

    for _, b in ipairs(bounds) do
        if b.dir == tree.DIR_H then
            hi = hi + 1
            local entry    = get_drag_handle(s, hi)
            local wb, ref  = entry.wb, entry.ref
            ref.b        = b
            ref.handle_w = handle_w
            wb.x      = b.pos - math.floor(handle_w / 2)
            wb.y      = b.start
            wb.width  = handle_w
            wb.height = math.max(1, b.span)
            wb.cursor = "sb_h_double_arrow"
            wb.visible = true
        end
    end

    local pool = drag_handle_pool[s]
    if pool then
        for i = hi + 1, #pool do pool[i].wb.visible = false end
    end
end

function M.hide_drag_handles(s)
    local pool = drag_handle_pool[s]
    if pool then for _, entry in ipairs(pool) do entry.wb.visible = false end end
end

function M.flush_caches()
    for _, u in pairs(underlay_cache) do
        u.chrome_layer:reset()
    end
end

return M
