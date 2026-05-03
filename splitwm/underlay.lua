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
local SCROLL_STEP
local _do_scroll, _insert_column_at_gap, _insert_at_right_edge, _insert_at_left_edge
local _get_state, _get_active_state

function M.setup(deps)
    BTN_SIZE          = deps.BTN_SIZE
    MIN_SPLIT_W       = deps.MIN_SPLIT_W
    MIN_SPLIT_H       = deps.MIN_SPLIT_H
    color_bg          = deps.color_bg
    color_fg          = deps.color_fg
    color_transparent = deps.color_transparent
    color_handle      = deps.color_handle
    SCROLL_STEP       = deps.SCROLL_STEP or 60
    _do_scroll             = deps.do_scroll
    _insert_column_at_gap  = deps.insert_column_at_gap
    _insert_at_right_edge  = deps.insert_at_right_edge
    _insert_at_left_edge   = deps.insert_at_left_edge
    _get_state        = deps.get_state
    _get_active_state = deps.get_active_state
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

    -- Horizontal scroll via 2-finger trackpad (buttons 6/7) or Shift+wheel (4/5).
    wb:buttons(gears.table.join(
        awful.button({}, 6,         function() if _do_scroll then _do_scroll(s, -SCROLL_STEP) end end),
        awful.button({}, 7,         function() if _do_scroll then _do_scroll(s,  SCROLL_STEP) end end),
        awful.button({"Shift"}, 4,  function() if _do_scroll then _do_scroll(s, -SCROLL_STEP) end end),
        awful.button({"Shift"}, 5,  function() if _do_scroll then _do_scroll(s,  SCROLL_STEP) end end)
    ))

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
-- Drag handles (3-zone: left-only, symmetric, right-only)
---------------------------------------------------------------------------

-- Total px subtracted from gap to get handle widget width (inset on each side).
local HANDLE_INSET = 4

-- Zone boundaries as fraction of half-gap from center.
-- Middle zone = ±ZONE_FRAC of gap width; outside = left/right asymmetric.
local ZONE_FRAC = 0.25

local drag_handle_pool = {}
local plus_btn_pool    = {}

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
            if ref.b.edge then return end  -- edge handles have no drag resize
            local b, hw = ref.b, ref.handle_w
            -- Determine drag zone from click position relative to gap center.
            local mx0 = mouse.coords().x
            local t, state = _get_active_state(s)
            local scroll_x = (state and state.scroll_x) or 0
            local canvas_mx = mx0 + scroll_x  -- canvas-space x of click
            local zone_half = (b.parent_gap or 0) * ZONE_FRAC
            local zone
            if canvas_mx < b.pos - zone_half then
                zone = "left"
            elseif canvas_mx > b.pos + zone_half then
                zone = "right"
            else
                zone = "middle"
            end

            handle_state = "dragging"
            wb.bg = color_fg
            local wa = s.workarea
            local wb_x_offset = wb.x - mx0  -- offset from mouse to handle left edge at drag start

            -- Capture initial geometry once to avoid delta accumulation across frames.
            local igap_init        = b.parent_gap or 0
            local usable_init      = b.parent_w - igap_init
            local old_left_w_init  = b.branch.abs_left_w or math.floor(usable_init * b.branch.ratio)
            local old_right_w_init = usable_init - old_left_w_init
            local right_start_init = b.parent_x + old_left_w_init + igap_init
            local canvas_w_init    = (state and state.canvas_w) or wa.width
            local scroll_x_init    = scroll_x  -- scroll_x at click time

            mousegrabber.run(function(mouse_m)
                if not mouse_m.buttons[1] then
                    handle_state = "idle"; wb.bg = color_transparent
                    awful.layout.arrange(s)
                    return false
                end
                local t2, st2 = _get_active_state(s)
                if not st2 then return false end
                local sx = st2.scroll_x or 0

                if zone == "middle" then
                    -- Symmetric resize: split point tracks mouse, canvas unchanged.
                    local min_r = MIN_SPLIT_W / usable_init
                    b.branch.ratio = math.max(min_r, math.min(1 - min_r,
                        (mouse_m.x + sx - b.parent_x - math.floor(igap_init / 2)) / usable_init))
                    b.branch.abs_left_w = nil
                elseif zone == "left" then
                    -- Left child grows/shrinks; right child width stays constant; canvas changes.
                    local new_left_w = math.max(MIN_SPLIT_W,
                        mouse_m.x + sx - b.parent_x - math.floor(igap_init / 2))
                    b.branch.abs_left_w = new_left_w
                    b.branch.ratio = usable_init > 0 and (new_left_w / usable_init) or b.branch.ratio
                    st2.canvas_w = canvas_w_init + (new_left_w - old_left_w_init)
                    local max_sl = math.max(0, st2.canvas_w - wa.width)
                    st2.scroll_x      = math.min(st2.scroll_x or 0, max_sl)
                    st2.scroll_target = st2.scroll_x
                else -- zone == "right"
                    -- Right child shrinks when dragging right; left child locked.
                    -- scroll_x adjusts to keep the gap at the mouse position.
                    local delta = mouse_m.x - mx0
                    local new_right_w = math.max(MIN_SPLIT_W, old_right_w_init - delta)
                    b.branch.abs_left_w = old_left_w_init
                    b.branch.ratio = usable_init > 0 and (old_left_w_init / usable_init) or b.branch.ratio
                    st2.canvas_w = canvas_w_init + (new_right_w - old_right_w_init)
                    local max_sr = math.max(0, st2.canvas_w - wa.width)
                    st2.scroll_x      = math.min(scroll_x_init - delta, max_sr)
                    st2.scroll_target = st2.scroll_x
                end
                awful.layout.arrange(s)
                if zone == "right" then
                    -- update_drag_handles may hide or misplace this handle when the gap
                    -- scrolls off-screen, so force position and visibility manually.
                    wb.visible = true
                    wb.x = mouse_m.x + wb_x_offset
                end
                return true
            end, "sb_h_double_arrow")
        end),
        -- Pass scroll events through the handle to the main scroll handler.
        awful.button({}, 6,        function() if _do_scroll then _do_scroll(s, -SCROLL_STEP) end end),
        awful.button({}, 7,        function() if _do_scroll then _do_scroll(s,  SCROLL_STEP) end end),
        awful.button({"Shift"}, 4, function() if _do_scroll then _do_scroll(s, -SCROLL_STEP) end end),
        awful.button({"Shift"}, 5, function() if _do_scroll then _do_scroll(s,  SCROLL_STEP) end end)
    ))
    wb:connect_signal("mouse::enter", function() if handle_state ~= "dragging" then wb.bg = color_handle end end)
    wb:connect_signal("mouse::leave", function() if handle_state ~= "dragging" then wb.bg = color_transparent end end)

    local entry = { wb = wb, ref = ref }
    drag_handle_pool[s][i] = entry
    return entry
end

---------------------------------------------------------------------------
-- + button for inserting a new column at a horizontal gap
---------------------------------------------------------------------------

local PLUS_BTN_SIZE = 22  -- px square hit area for the + button

local function get_plus_btn(s, i)
    if not plus_btn_pool[s] then plus_btn_pool[s] = {} end
    if plus_btn_pool[s][i] then return plus_btn_pool[s][i] end

    local ref = { b = nil }
    local wb = M.make_wb_proxy(M.get_or_create_underlay(s).handle_layer, s)
    wb.visible = false

    local btn_state = "idle"

    local draw_w = wibox.widget.base.make_widget()
    function draw_w:draw(_, cr, w, h)
        local col = btn_state == "hover" and color_fg or color_handle
        cr:set_source(gears.color(col))
        cr:set_line_width(2)
        local cx, cy = w / 2, h / 2
        local arm = math.floor(math.min(w, h) * 0.3)
        cr:move_to(cx - arm, cy); cr:line_to(cx + arm, cy); cr:stroke()
        cr:move_to(cx, cy - arm); cr:line_to(cx, cy + arm); cr:stroke()
    end
    function draw_w:fit(_, w, h) return w, h end

    wb:setup {
        draw_w,
        bg     = color_transparent,
        shape  = function(cr, w, h) gears.shape.rounded_rect(cr, w, h, math.floor(h / 2)) end,
        widget = wibox.container.background,
    }

    wb:connect_signal("mouse::enter", function()
        btn_state = "hover"; draw_w:emit_signal("widget::redraw_needed")
    end)
    wb:connect_signal("mouse::leave", function()
        btn_state = "idle"; draw_w:emit_signal("widget::redraw_needed")
    end)
    wb:buttons(gears.table.join(
        awful.button({}, 1, function()
            if not ref.b then return end
            if ref.b.insert_fn then
                ref.b.insert_fn()
            elseif _insert_column_at_gap then
                _insert_column_at_gap(s, ref.b)
            end
        end),
        -- Pass scroll events through.
        awful.button({}, 6,        function() if _do_scroll then _do_scroll(s, -SCROLL_STEP) end end),
        awful.button({}, 7,        function() if _do_scroll then _do_scroll(s,  SCROLL_STEP) end end),
        awful.button({"Shift"}, 4, function() if _do_scroll then _do_scroll(s, -SCROLL_STEP) end end),
        awful.button({"Shift"}, 5, function() if _do_scroll then _do_scroll(s,  SCROLL_STEP) end end)
    ))

    local entry = { wb = wb, ref = ref }
    plus_btn_pool[s][i] = entry
    return entry
end

function M.update_drag_handles(s, state, bounds, scroll_x)
    scroll_x = scroll_x or 0

    for _, c in ipairs(s.clients) do
        if c.fullscreen then
            local pool = drag_handle_pool[s]
            if pool then for _, entry in ipairs(pool) do entry.wb.visible = false end end
            local ppool = plus_btn_pool[s]
            if ppool then for _, entry in ipairs(ppool) do entry.wb.visible = false end end
            return
        end
    end

    local gap      = beautiful.splitwm_gap
    local handle_w = gap - HANDLE_INSET
    local hi       = 0
    local pi       = 0
    local wa       = s.workarea

    for _, b in ipairs(bounds) do
        if b.dir == tree.DIR_H then
            local vis_pos = b.pos - scroll_x  -- screen-space x of gap center

            -- Only show handle and + button if gap is at least partially on screen.
            if vis_pos + handle_w / 2 > wa.x and vis_pos - handle_w / 2 < wa.x + wa.width then
                hi = hi + 1
                local entry    = get_drag_handle(s, hi)
                local wb, ref  = entry.wb, entry.ref
                ref.b        = b
                ref.handle_w = handle_w
                wb.x      = vis_pos - math.floor(handle_w / 2)
                wb.y      = b.start
                wb.width  = handle_w
                wb.height = math.max(1, b.span)
                wb.cursor = "sb_h_double_arrow"
                wb.visible = true

                -- + button: centered vertically in the gap span.
                pi = pi + 1
                local pe   = get_plus_btn(s, pi)
                local pwb  = pe.wb
                pe.ref.b   = b
                pwb.x      = vis_pos - math.floor(PLUS_BTN_SIZE / 2)
                pwb.y      = b.start + math.floor((b.span - PLUS_BTN_SIZE) / 2)
                pwb.width  = PLUS_BTN_SIZE
                pwb.height = PLUS_BTN_SIZE
                pwb.visible = true
            end
        end
    end

    -- Edge handles: + buttons at left and right canvas boundaries.
    local canvas_w_val = (state and state.canvas_w) or wa.width
    local function add_edge_handle(pos_canvas, inward, insert_fn)
        local vis_pos = pos_canvas - scroll_x
        -- inward = 1 means pill extends right (left edge), -1 means extends left (right edge)
        local pill_x = inward == 1 and vis_pos or vis_pos - handle_w
        local btn_x  = inward == 1 and vis_pos or vis_pos - PLUS_BTN_SIZE
        -- Show when any part of the pill is on screen.
        if pill_x + handle_w > wa.x and pill_x < wa.x + wa.width then
            hi = hi + 1
            local entry   = get_drag_handle(s, hi)
            local wb_h, ref_h = entry.wb, entry.ref
            ref_h.b = { edge = true, pos = pos_canvas, start = wa.y, span = wa.height }
            ref_h.handle_w = handle_w
            wb_h.x      = pill_x
            wb_h.y      = wa.y
            wb_h.width  = handle_w
            wb_h.height = wa.height
            wb_h.cursor = "left_ptr"
            wb_h.visible = true

            pi = pi + 1
            local pe  = get_plus_btn(s, pi)
            pe.ref.b  = { edge = true, insert_fn = insert_fn }
            pe.wb.x      = btn_x
            pe.wb.y      = wa.y + math.floor((wa.height - PLUS_BTN_SIZE) / 2)
            pe.wb.width  = PLUS_BTN_SIZE
            pe.wb.height = PLUS_BTN_SIZE
            pe.wb.visible = true
        end
    end
    add_edge_handle(wa.x,                 1,  function() if _insert_at_left_edge  then _insert_at_left_edge(s)  end end)
    add_edge_handle(wa.x + canvas_w_val, -1,  function() if _insert_at_right_edge then _insert_at_right_edge(s) end end)

    local pool = drag_handle_pool[s]
    if pool then
        for i = hi + 1, #pool do pool[i].wb.visible = false end
    end
    local ppool = plus_btn_pool[s]
    if ppool then
        for i = pi + 1, #ppool do ppool[i].wb.visible = false end
    end
end

function M.hide_drag_handles(s)
    local pool = drag_handle_pool[s]
    if pool then for _, entry in ipairs(pool) do entry.wb.visible = false end end
    local ppool = plus_btn_pool[s]
    if ppool then for _, entry in ipairs(ppool) do entry.wb.visible = false end end
end

function M.flush_caches()
    for _, u in pairs(underlay_cache) do
        u.chrome_layer:reset()
    end
end

return M
