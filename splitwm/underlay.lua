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
local _on_resize_finished

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
    _on_resize_finished = deps.on_resize_finished
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
            local mx0 = mouse.coords().x
            local _, state = _get_active_state(s)
            if not state then return end

            -- Shared drag scaffolding: calls on_move(mouse_m, st2) each frame,
            -- then arranges and repositions the handle widget.
            local function start_drag(on_move, wb_x_offset_override)
                handle_state = "dragging"
                wb.bg = color_fg
                local wb_x_offset = wb_x_offset_override ~= nil and wb_x_offset_override or (wb.x - mx0)
                mousegrabber.run(function(mouse_m)
                    if not mouse_m.buttons[1] then
                        handle_state = "idle"; wb.bg = color_transparent
                        awful.layout.arrange(s)
                        if _on_resize_finished then _on_resize_finished(s) end
                        return false
                    end
                    local _, st2 = _get_active_state(s)
                    if not st2 then return false end
                    on_move(mouse_m, st2)
                    awful.layout.arrange(s)
                    wb.visible = true
                    wb.x = mouse_m.x + wb_x_offset
                    return true
                end, "sb_h_double_arrow")
            end

            -- ── Edge resize ──────────────────────────────────────────────────
            if ref.b.edge then
                local canvas_w_init = state.canvas_w or s.workarea.width
                local scroll_x_init = state.scroll_x or 0
                local gap_e         = beautiful.splitwm_gap or 24
                local root_e        = state.root
                local is_left       = ref.b.edge == "left"
                -- Pre-compute initial absolute widths for n-ary root.
                local N_e, usable_init_e, init_abs_e
                if root_e and root_e.direction == tree.DIR_H then
                    N_e = #root_e.children
                    usable_init_e = canvas_w_init - (N_e - 1) * gap_e
                    local rs = 0
                    for _, r in ipairs(root_e.ratios) do rs = rs + r end
                    if rs <= 0 then rs = 1 end
                    init_abs_e = {}
                    for j = 1, N_e do init_abs_e[j] = root_e.ratios[j] / rs * usable_init_e end
                end
                start_drag(function(mouse_m, st2)
                    local delta = mouse_m.x - mx0
                    if is_left and init_abs_e and root_e and root_e.direction == tree.DIR_H then
                        -- Left edge: drag left = leftmost child grows.
                        local new_left_w   = math.max(MIN_SPLIT_W, init_abs_e[1] - delta)
                        local canvas_delta = new_left_w - init_abs_e[1]
                        st2.canvas_w       = math.max(MIN_SPLIT_W * N_e, canvas_w_init + canvas_delta)
                        local new_usable   = usable_init_e + canvas_delta
                        local new_abs = {}
                        for j = 1, N_e do new_abs[j] = init_abs_e[j] end
                        new_abs[1] = new_left_w
                        for j = 1, N_e do root_e.ratios[j] = new_abs[j] / new_usable end
                        st2.scroll_x      = scroll_x_init + canvas_delta
                        st2.scroll_target = st2.scroll_x
                    elseif not is_left and init_abs_e and root_e and root_e.direction == tree.DIR_H then
                        -- Right edge: rightmost child grows.
                        local new_cw       = math.max(MIN_SPLIT_W * 2, canvas_w_init + delta)
                        local canvas_delta = new_cw - canvas_w_init
                        st2.canvas_w       = new_cw
                        local new_usable   = usable_init_e + canvas_delta
                        local new_abs = {}
                        for j = 1, N_e do new_abs[j] = init_abs_e[j] end
                        new_abs[N_e] = new_abs[N_e] + canvas_delta
                        for j = 1, N_e do root_e.ratios[j] = new_abs[j] / new_usable end
                    else
                        st2.canvas_w = math.max(MIN_SPLIT_W * 2, canvas_w_init + delta)
                    end
                end)
                return
            end

            -- ── Gap resize (3-zone) ───────────────────────────────────────────
            local b, hw     = ref.b, ref.handle_w
            local wa        = s.workarea
            local scroll_x  = state.scroll_x or 0
            local canvas_mx = mx0 + scroll_x
            local zone_half = (b.parent_gap or 0) * ZONE_FRAC
            local zone = canvas_mx < b.pos - zone_half and "left"
                      or canvas_mx > b.pos + zone_half and "right"
                      or "middle"

            local canvas_w_init = state.canvas_w or wa.width
            local scroll_x_init = scroll_x
            local N = #b.branch.children
            -- Pre-compute initial absolute widths from current ratios.
            local rs = 0
            for _, r in ipairs(b.branch.ratios) do rs = rs + r end
            if rs <= 0 then rs = 1 end
            local init_abs = {}
            for j = 1, N do init_abs[j] = b.branch.ratios[j] / rs * b.usable end
            -- Middle/left: gap center tracks mouse; center pill on cursor.
            -- Right: gap moves by delta; preserve click-relative offset.
            local gap_wb_x_off = zone ~= "right" and -math.floor(hw / 2) or nil

            start_drag(function(mouse_m, st2)
                local sx = st2.scroll_x or 0
                if zone == "middle" then
                    -- Only the two neighbors change; combined width stays the same.
                    local new_left_w  = math.max(MIN_SPLIT_W,
                        mouse_m.x + sx - b.left_x - math.floor(b.parent_gap / 2))
                    local combined    = init_abs[b.left_idx] + init_abs[b.left_idx + 1]
                    local new_right_w = math.max(MIN_SPLIT_W, combined - new_left_w)
                    new_left_w = combined - new_right_w
                    b.branch.ratios[b.left_idx]     = new_left_w / b.usable
                    b.branch.ratios[b.left_idx + 1] = new_right_w / b.usable
                elseif zone == "left" then
                    -- Left neighbor grows; canvas expands; all others keep abs width.
                    local new_left_w = math.max(MIN_SPLIT_W,
                        mouse_m.x + sx - b.left_x - math.floor(b.parent_gap / 2))
                    local delta      = new_left_w - init_abs[b.left_idx]
                    st2.canvas_w     = canvas_w_init + delta
                    local new_usable = b.usable + delta
                    local new_abs    = {}
                    for j = 1, N do new_abs[j] = init_abs[j] end
                    new_abs[b.left_idx] = new_left_w
                    for j = 1, N do b.branch.ratios[j] = new_abs[j] / new_usable end
                    st2.scroll_x      = math.min(st2.scroll_x or 0, math.max(0, st2.canvas_w - wa.width))
                    st2.scroll_target = st2.scroll_x
                else -- right
                    -- Right neighbor grows; canvas expands; all others keep abs width.
                    local delta       = mouse_m.x - mx0
                    local new_right_w = math.max(MIN_SPLIT_W, init_abs[b.left_idx + 1] - delta)
                    local canvas_delta = new_right_w - init_abs[b.left_idx + 1]
                    st2.canvas_w      = canvas_w_init + canvas_delta
                    local new_usable  = b.usable + canvas_delta
                    local new_abs     = {}
                    for j = 1, N do new_abs[j] = init_abs[j] end
                    new_abs[b.left_idx + 1] = new_right_w
                    for j = 1, N do b.branch.ratios[j] = new_abs[j] / new_usable end
                    st2.scroll_x      = math.min(scroll_x_init - delta, math.max(0, st2.canvas_w - wa.width))
                    st2.scroll_target = st2.scroll_x
                end
            end, gap_wb_x_off)
        end),
        -- Pass scroll events through the handle to the main scroll handler.
        awful.button({}, 6,        function() if _do_scroll then _do_scroll(s, -SCROLL_STEP) end end),
        awful.button({}, 7,        function() if _do_scroll then _do_scroll(s,  SCROLL_STEP) end end),
        awful.button({"Shift"}, 4, function() if _do_scroll then _do_scroll(s, -SCROLL_STEP) end end),
        awful.button({"Shift"}, 5, function() if _do_scroll then _do_scroll(s,  SCROLL_STEP) end end)
    ))
    wb:connect_signal("mouse::enter", function()
        if handle_state ~= "dragging" then wb.bg = color_handle end
        if ref.plus_entry then ref.plus_entry.set_handle_hover(true) end
    end)
    wb:connect_signal("mouse::leave", function()
        if handle_state ~= "dragging" then wb.bg = color_transparent end
        if ref.plus_entry then ref.plus_entry.set_handle_hover(false) end
    end)

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

    local btn_state     = "idle"
    local handle_hovered = false

    local draw_w = wibox.widget.base.make_widget()
    function draw_w:draw(_, cr, w, h)
        if not handle_hovered and btn_state ~= "hover" then return end
        cr:set_source(gears.color(color_fg))
        cr:set_line_width(3)
        local cx, cy = w / 2, h / 2
        local arm = math.floor(math.min(w, h) * 0.3)
        cr:move_to(cx - arm, cy); cr:line_to(cx + arm, cy); cr:stroke()
        cr:move_to(cx, cy - arm); cr:line_to(cx, cy + arm); cr:stroke()
    end
    function draw_w:fit(_, w, h) return w, h end

    wb:setup {
        draw_w,
        bg     = color_transparent,
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

    local entry = {
        wb  = wb,
        ref = ref,
        set_handle_hover = function(v)
            handle_hovered = v
            draw_w:emit_signal("widget::redraw_needed")
        end,
    }
    plus_btn_pool[s][i] = entry
    return entry
end

function M.update_drag_handles(s, state, bounds, scroll_x)
    scroll_x = scroll_x or 0

    local t = s.selected_tag
    if t then
        for _, c in ipairs(t:clients()) do
            if c.fullscreen then
                local pool = drag_handle_pool[s]
                if pool then for _, entry in ipairs(pool) do entry.wb.visible = false end end
                local ppool = plus_btn_pool[s]
                if ppool then for _, entry in ipairs(ppool) do entry.wb.visible = false end end
                return
            end
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
                entry.ref.plus_entry = pe
                pwb.x      = vis_pos - math.floor(PLUS_BTN_SIZE / 2)
                pwb.y      = b.start + math.floor((b.span - PLUS_BTN_SIZE) / 2)
                pwb.width  = PLUS_BTN_SIZE
                pwb.height = PLUS_BTN_SIZE
                pwb.visible = true
            end
        end
    end

    -- Edge handles: + buttons at left and right canvas boundaries.
    -- Vertical span = union of all horizontal-gap spans (matches gap handle heights).
    local canvas_w_val = (state and state.canvas_w) or wa.width
    local edge_top, edge_bot = wa.y + wa.height, wa.y
    for _, b in ipairs(bounds) do
        if b.dir == tree.DIR_H then
            edge_top = math.min(edge_top, b.start)
            edge_bot = math.max(edge_bot, b.start + b.span)
        end
    end
    if edge_top >= edge_bot then  -- no horizontal gaps: fall back to inner workarea
        edge_top, edge_bot = wa.y + gap, wa.y + wa.height - gap
    end
    local edge_span = edge_bot - edge_top

    local function add_edge_handle(pos_canvas, edge_side, insert_fn)
        local vis_pos = pos_canvas - scroll_x
        local pill_x  = vis_pos - math.floor(handle_w / 2)
        local btn_x   = vis_pos - math.floor(PLUS_BTN_SIZE / 2)
        if pill_x + handle_w > wa.x and pill_x < wa.x + wa.width then
            hi = hi + 1
            local entry   = get_drag_handle(s, hi)
            local wb_h, ref_h = entry.wb, entry.ref
            ref_h.b = { edge = edge_side, pos = pos_canvas, start = edge_top, span = edge_span }
            ref_h.handle_w = handle_w
            wb_h.x      = pill_x
            wb_h.y      = edge_top
            wb_h.width  = handle_w
            wb_h.height = edge_span
            wb_h.cursor = "left_ptr"
            wb_h.visible = true

            pi = pi + 1
            local pe  = get_plus_btn(s, pi)
            pe.ref.b  = { edge = true, insert_fn = insert_fn }
            pe.wb.x      = btn_x
            pe.wb.y      = edge_top + math.floor((edge_span - PLUS_BTN_SIZE) / 2)
            pe.wb.width  = PLUS_BTN_SIZE
            pe.wb.height = PLUS_BTN_SIZE
            pe.wb.visible = true
            entry.ref.plus_entry = pe
        end
    end
    add_edge_handle(wa.x + math.floor(gap / 2),                  "left",  function() if _insert_at_left_edge  then _insert_at_left_edge(s)  end end)
    add_edge_handle(wa.x + canvas_w_val - math.floor(gap / 2), "right", function() if _insert_at_right_edge then _insert_at_right_edge(s) end end)

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
