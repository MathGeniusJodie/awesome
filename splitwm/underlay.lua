---------------------------------------------------------------------------
-- splitwm.underlay — per-screen underlay wibox, wallpaper, and drag handles.
--
-- The underlay is a "desktop"-type wibox below all windows hosting:
--   • wallpaper rendering
--   • leaf chrome layer (painted by titlebar.lua via make_wb_proxy)
--   • resize drag handles and gap/edge "+" insert buttons
---------------------------------------------------------------------------

local awful  = require("awful")
local gears  = require("gears")
local wibox  = require("wibox")
local tree   = require("splitwm.tree")
local core   = require("splitwm.core")
local theme  = require("splitwm.theme")
local ops    = require("splitwm.ops")
local scroll = require("splitwm.scroll")
local smush  = require("splitwm.smush")

local underlay = {}

local underlay_cache = {}

local function scroll_buttons(s)
    -- Horizontal scroll: trackpad (buttons 6/7) streams small instant steps
    -- for smooth scrolling; Shift+wheel (4/5) gets big animated clicks.
    local function by(delta, instant)
        return function() scroll.scroll_delta(s, delta, instant) end
    end
    return gears.table.join(
        awful.button({}, 6, by(-theme.SCROLL_STEP_SMOOTH, true)),
        awful.button({}, 7, by(theme.SCROLL_STEP_SMOOTH, true)),
        awful.button({ "Shift" }, 4, by(-theme.SCROLL_STEP)),
        awful.button({ "Shift" }, 5, by(theme.SCROLL_STEP))
    )
end

local function make_wallpaper_widget()
    local w = wibox.widget.base.make_widget()
    w._surface = nil
    w._sw, w._sh = 0, 0
    -- Pre-scaled cache: rescaling the source image on every damaged repaint
    -- dominated scroll/animation frame cost (25fps -> 60fps benchmarked).
    -- The cache is an opaque screen-sized surface; drawing it is a blit.
    local cache, cache_w, cache_h, cache_src
    function w:draw(_, cr, width, height)
        if not self._surface then return end
        if cache_src ~= self._surface or cache_w ~= width or cache_h ~= height then
            local cairo = require("lgi").cairo
            cache = cairo.ImageSurface.create(cairo.Format.RGB24, width, height)
            local cc = cairo.Context(cache)
            local scale = math.max(width / self._sw, height / self._sh)
            cc:translate((width - self._sw * scale) / 2,
                (height - self._sh * scale) / 2)
            cc:scale(scale, scale)
            cc:set_source_surface(self._surface, 0, 0)
            cc:paint()
            cache_w, cache_h, cache_src = width, height, self._surface
        end
        cr:set_source_surface(cache, 0, 0)
        cr:paint()
    end
    function w:fit(_, width, height) return width, height end
    return w
end

function underlay.get_or_create(s)
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
        bg      = theme.color_bg,
        visible = true,
        type    = "desktop",
    }
    wb:setup { wallpaper_w, chrome_layer, handle_layer, layout = wibox.layout.stack }
    wb:buttons(scroll_buttons(s))

    local entry = {
        wb           = wb,
        chrome_layer = chrome_layer,
        handle_layer = handle_layer,
        wallpaper_w  = wallpaper_w,
    }
    underlay_cache[s] = entry
    return entry
end

-- A wibox-compatible proxy widget living in a wibox.layout.manual layer.
-- Lets titlebar.lua treat a widget inside the underlay like a real wibox
-- (x/y/width/height/visible in screen coordinates).
function underlay.make_wb_proxy(layer, s)
    local container = wibox.container.background()
    local px, py, rw, rh = 0, 0, 0, 0
    local pt = { x = px, y = py }
    container.point         = function() return pt end
    container.forced_width  = 0
    container.forced_height = 0
    layer:add(container)

    local proxy = {
        setup          = function(_, decl)    container.widget = wibox.widget(decl) end,
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

function underlay.set_wallpaper(s, ws)
    local u = underlay.get_or_create(s)
    u.wb.bg = ws.dark or theme.color_bg
    if ws.has_bg then
        local surf = gears.surface.load(ws.bg)
        u.wallpaper_w._surface = surf
        u.wallpaper_w._sw      = surf:get_width()
        u.wallpaper_w._sh      = surf:get_height()
        gears.wallpaper.maximized(ws.bg, s, true)
    else
        u.wallpaper_w._surface = nil
        gears.wallpaper.set(ws.dark or theme.color_bg)
    end
    u.wallpaper_w:emit_signal("widget::redraw_needed")
end

---------------------------------------------------------------------------
-- Drag handles (3-zone: left-only, symmetric, right-only) and "+" buttons
---------------------------------------------------------------------------

-- Total px subtracted from gap to get handle widget width.
local HANDLE_INSET = 4
local GAP_RESIZE_CURSOR = "sb_h_double_arrow"
local GAP_LEFT_CURSOR   = "left_side"
local GAP_RIGHT_CURSOR  = "right_side"
local DEFAULT_CURSOR    = "left_ptr"

-- Middle zone = ±ZONE_FRAC of gap width from center; outside = asymmetric.
local ZONE_FRAC = 0.25

local PLUS_BTN_SIZE = 22  -- px square hit area for the "+" button

local drag_handle_pool = {}
local plus_btn_pool    = {}

local function get_drag_handle(s, i)
    drag_handle_pool[s] = drag_handle_pool[s] or {}
    if drag_handle_pool[s][i] then return drag_handle_pool[s][i] end

    local u   = underlay.get_or_create(s)
    local ref = { b = nil, handle_w = 1 }
    local handle_state = "idle"
    local wb = underlay.make_wb_proxy(u.handle_layer, s)
    wb.visible = false

    local function handle_cursor()
        local b = ref.b
        if not b or b.edge then return DEFAULT_CURSOR end

        local mx = mouse.coords().x
        local center = wb.x + math.floor(wb.width / 2)
        local zone_half = (b.parent_gap or wb.width or 0) * ZONE_FRAC
        if mx < center - zone_half then return GAP_LEFT_CURSOR end
        if mx > center + zone_half then return GAP_RIGHT_CURSOR end
        return GAP_RESIZE_CURSOR
    end

    local entry = { wb = wb, ref = ref }
    function entry.update_cursor()
        if handle_state ~= "dragging" then u.wb.cursor = handle_cursor() end
    end

    if not u.drag_handle_cursor_motion_connected then
        u.drag_handle_cursor_motion_connected = true
        u.wb:connect_signal("mouse::move", function()
            local hovered = u.hovered_drag_handle
            if hovered and hovered.update_cursor then hovered.update_cursor() end
        end)
    end

    wb.bg    = theme.color_transparent
    wb.shape = function(cr, w, h)
        local pw = theme.BTN_SIZE
        cr:save()
        cr:translate(math.floor((w - pw) / 2), 0)
        gears.shape.rounded_rect(cr, pw, h, math.floor(pw / 2))
        cr:restore()
    end

    wb:buttons(gears.table.join(
        awful.button({}, 1, function()
            if not ref.b then return end
            local mx0 = mouse.coords().x
            local _, state = core.active_state(s)
            if not state then return end

            -- Shared drag scaffolding: calls on_move(mouse_m, st2) each frame,
            -- then arranges and repositions the handle widget.
            local function start_drag(on_move, wb_x_offset_override, cursor)
                handle_state = "dragging"
                wb.bg = theme.color_fg
                local wb_x_offset = wb_x_offset_override ~= nil
                    and wb_x_offset_override or (wb.x - mx0)
                mousegrabber.run(function(mouse_m)
                    if not mouse_m.buttons[1] then
                        handle_state = "idle"; wb.bg = theme.color_transparent
                        if u.hovered_drag_handle == entry then entry.update_cursor()
                        else u.wb.cursor = DEFAULT_CURSOR end
                        awful.layout.arrange(s)
                        smush.after_layout(s)
                        return false
                    end
                    local _, st2 = core.active_state(s)
                    if not st2 then return false end
                    on_move(mouse_m, st2)
                    awful.layout.arrange(s)
                    wb.visible = true
                    wb.x = mouse_m.x + wb_x_offset
                    return true
                end, cursor or GAP_RESIZE_CURSOR)
            end

            -- ── Edge resize ──────────────────────────────────────────────
            if ref.b.edge then
                local canvas_w_init = state.canvas_w or s.workarea.width
                local scroll_x_init = state.scroll_x or 0
                local gap_e         = theme.gap() or 24
                local root_e        = state.root
                local is_left       = ref.b.edge == "left"
                -- Pre-compute initial absolute widths for an n-ary root.
                local N_e, usable_init_e, init_abs_e
                if root_e and root_e.direction == tree.DIR_H then
                    N_e = #root_e.children
                    usable_init_e = canvas_w_init - (N_e - 1) * gap_e
                    local rs = 0
                    for _, r in ipairs(root_e.ratios) do rs = rs + r end
                    if rs <= 0 then rs = 1 end
                    init_abs_e = {}
                    for j = 1, N_e do
                        init_abs_e[j] = root_e.ratios[j] / rs * usable_init_e
                    end
                end
                start_drag(function(mouse_m, st2)
                    local delta = mouse_m.x - mx0
                    if is_left and init_abs_e then
                        -- Left edge: drag left = leftmost child grows.
                        local new_left_w   = math.max(theme.MIN_SPLIT_W, init_abs_e[1] - delta)
                        local canvas_delta = new_left_w - init_abs_e[1]
                        st2.canvas_w       = math.max(theme.MIN_SPLIT_W * N_e,
                            canvas_w_init + canvas_delta)
                        local new_usable   = usable_init_e + canvas_delta
                        local new_abs = {}
                        for j = 1, N_e do new_abs[j] = init_abs_e[j] end
                        new_abs[1] = new_left_w
                        for j = 1, N_e do root_e.ratios[j] = new_abs[j] / new_usable end
                        st2.scroll_x      = scroll_x_init + canvas_delta
                        st2.scroll_target = st2.scroll_x
                    elseif not is_left and init_abs_e then
                        -- Right edge: rightmost child grows.
                        local new_cw       = math.max(theme.MIN_SPLIT_W * 2,
                            canvas_w_init + delta)
                        local canvas_delta = new_cw - canvas_w_init
                        st2.canvas_w       = new_cw
                        local new_usable   = usable_init_e + canvas_delta
                        local new_abs = {}
                        for j = 1, N_e do new_abs[j] = init_abs_e[j] end
                        new_abs[N_e] = new_abs[N_e] + canvas_delta
                        for j = 1, N_e do root_e.ratios[j] = new_abs[j] / new_usable end
                    else
                        st2.canvas_w = math.max(theme.MIN_SPLIT_W * 2,
                            canvas_w_init + delta)
                    end
                end)
                return
            end

            -- ── Gap resize (3-zone) ──────────────────────────────────────
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

            local zone_cursor = zone == "left" and GAP_LEFT_CURSOR
                or zone == "right" and GAP_RIGHT_CURSOR
                or GAP_RESIZE_CURSOR

            start_drag(function(mouse_m, st2)
                local sx = st2.scroll_x or 0
                if zone == "middle" then
                    -- Only the two neighbors change; combined width constant.
                    local new_left_w  = math.max(theme.MIN_SPLIT_W,
                        mouse_m.x + sx - b.left_x - math.floor(b.parent_gap / 2))
                    local combined    = init_abs[b.left_idx] + init_abs[b.left_idx + 1]
                    local new_right_w = math.max(theme.MIN_SPLIT_W, combined - new_left_w)
                    new_left_w = combined - new_right_w
                    b.branch.ratios[b.left_idx]     = new_left_w / b.usable
                    b.branch.ratios[b.left_idx + 1] = new_right_w / b.usable
                elseif zone == "left" then
                    -- Left neighbor grows; canvas expands; others keep abs width.
                    local new_left_w = math.max(theme.MIN_SPLIT_W,
                        mouse_m.x + sx - b.left_x - math.floor(b.parent_gap / 2))
                    local delta      = new_left_w - init_abs[b.left_idx]
                    st2.canvas_w     = canvas_w_init + delta
                    local new_usable = b.usable + delta
                    local new_abs    = {}
                    for j = 1, N do new_abs[j] = init_abs[j] end
                    new_abs[b.left_idx] = new_left_w
                    for j = 1, N do b.branch.ratios[j] = new_abs[j] / new_usable end
                    st2.scroll_x      = math.min(st2.scroll_x or 0,
                        math.max(0, st2.canvas_w - wa.width))
                    st2.scroll_target = st2.scroll_x
                else -- right
                    -- Right neighbor grows; canvas expands; others keep abs width.
                    local delta        = mouse_m.x - mx0
                    local new_right_w  = math.max(theme.MIN_SPLIT_W,
                        init_abs[b.left_idx + 1] - delta)
                    local canvas_delta = new_right_w - init_abs[b.left_idx + 1]
                    st2.canvas_w       = canvas_w_init + canvas_delta
                    local new_usable   = b.usable + canvas_delta
                    local new_abs      = {}
                    for j = 1, N do new_abs[j] = init_abs[j] end
                    new_abs[b.left_idx + 1] = new_right_w
                    for j = 1, N do b.branch.ratios[j] = new_abs[j] / new_usable end
                    st2.scroll_x      = math.min(scroll_x_init - delta,
                        math.max(0, st2.canvas_w - wa.width))
                    st2.scroll_target = st2.scroll_x
                end
            end, gap_wb_x_off, zone_cursor)
        end),
        scroll_buttons(s)
    ))
    wb:connect_signal("mouse::enter", function()
        u.hovered_drag_handle = entry
        entry.update_cursor()
        if handle_state ~= "dragging" then wb.bg = theme.color_handle end
        if ref.plus_entry then ref.plus_entry.set_handle_hover(true) end
    end)
    wb:connect_signal("mouse::leave", function()
        if u.hovered_drag_handle == entry then u.hovered_drag_handle = nil end
        u.wb.cursor = DEFAULT_CURSOR
        if handle_state ~= "dragging" then wb.bg = theme.color_transparent end
        if ref.plus_entry then ref.plus_entry.set_handle_hover(false) end
    end)
    drag_handle_pool[s][i] = entry
    return entry
end

local function get_plus_btn(s, i)
    plus_btn_pool[s] = plus_btn_pool[s] or {}
    if plus_btn_pool[s][i] then return plus_btn_pool[s][i] end

    local ref = { b = nil }
    local wb = underlay.make_wb_proxy(underlay.get_or_create(s).handle_layer, s)
    wb.visible = false

    local btn_state      = "idle"
    local handle_hovered = false

    local draw_w = wibox.widget.base.make_widget()
    function draw_w:draw(_, cr, w, h)
        if not handle_hovered and btn_state ~= "hover" then return end
        cr:set_source(gears.color(theme.color_fg))
        cr:set_line_width(3)
        local cx, cy = w / 2, h / 2
        local arm = math.floor(math.min(w, h) * 0.3)
        cr:move_to(cx - arm, cy); cr:line_to(cx + arm, cy); cr:stroke()
        cr:move_to(cx, cy - arm); cr:line_to(cx, cy + arm); cr:stroke()
    end
    function draw_w:fit(_, w, h) return w, h end

    wb:setup {
        draw_w,
        bg     = theme.color_transparent,
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
            local t = s.selected_tag
            if ref.b.insert_fn then
                ref.b.insert_fn()
            elseif t then
                ops.insert_column_at_gap(t, s, ref.b)
            end
        end),
        scroll_buttons(s)
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

function underlay.update_drag_handles(s, state, bounds, scroll_x)
    scroll_x = scroll_x or 0

    local t = s.selected_tag
    if t then
        for _, c in ipairs(t:clients()) do
            if c.fullscreen then
                underlay.hide_drag_handles(s)
                return
            end
        end
    end

    local gap      = theme.gap()
    local handle_w = gap - HANDLE_INSET
    local hi, pi   = 0, 0
    local wa       = s.workarea

    for _, b in ipairs(bounds) do
        if b.dir == tree.DIR_H then
            local vis_pos = b.pos - scroll_x  -- screen-space x of gap center

            -- Only show if the gap is at least partially on screen.
            if vis_pos + handle_w / 2 > wa.x
                    and vis_pos - handle_w / 2 < wa.x + wa.width then
                hi = hi + 1
                local entry   = get_drag_handle(s, hi)
                local wb, ref = entry.wb, entry.ref
                ref.b        = b
                ref.handle_w = handle_w
                wb.x      = vis_pos - math.floor(handle_w / 2)
                wb.y      = b.start
                wb.width  = handle_w
                wb.height = math.max(1, b.span)
                wb.cursor = GAP_RESIZE_CURSOR
                wb.visible = true

                -- "+" button: centered vertically in the gap span.
                pi = pi + 1
                local pe  = get_plus_btn(s, pi)
                pe.ref.b  = b
                entry.ref.plus_entry = pe
                pe.wb.x      = vis_pos - math.floor(PLUS_BTN_SIZE / 2)
                pe.wb.y      = b.start + math.floor((b.span - PLUS_BTN_SIZE) / 2)
                pe.wb.width  = PLUS_BTN_SIZE
                pe.wb.height = PLUS_BTN_SIZE
                pe.wb.visible = true
            end
        end
    end

    -- Edge handles: "+" buttons at the left and right canvas boundaries.
    -- Vertical span = union of all horizontal-gap spans.
    local canvas_w_val = (state and state.canvas_w) or wa.width
    local edge_top, edge_bot = wa.y + wa.height, wa.y
    for _, b in ipairs(bounds) do
        if b.dir == tree.DIR_H then
            edge_top = math.min(edge_top, b.start)
            edge_bot = math.max(edge_bot, b.start + b.span)
        end
    end
    if edge_top >= edge_bot then  -- no horizontal gaps: inner workarea
        edge_top, edge_bot = wa.y + gap, wa.y + wa.height - gap
    end
    local edge_span = edge_bot - edge_top

    local function add_edge_handle(pos_canvas, edge_side, insert_fn)
        local vis_pos = pos_canvas - scroll_x
        local pill_x  = vis_pos - math.floor(handle_w / 2)
        if pill_x + handle_w > wa.x and pill_x < wa.x + wa.width then
            hi = hi + 1
            local entry = get_drag_handle(s, hi)
            entry.ref.b = {
                edge = edge_side, pos = pos_canvas,
                start = edge_top, span = edge_span,
            }
            entry.ref.handle_w = handle_w
            entry.wb.x      = pill_x
            entry.wb.y      = edge_top
            entry.wb.width  = handle_w
            entry.wb.height = edge_span
            entry.wb.cursor = DEFAULT_CURSOR
            entry.wb.visible = true

            pi = pi + 1
            local pe  = get_plus_btn(s, pi)
            pe.ref.b  = { edge = true, insert_fn = insert_fn }
            pe.wb.x      = vis_pos - math.floor(PLUS_BTN_SIZE / 2)
            pe.wb.y      = edge_top + math.floor((edge_span - PLUS_BTN_SIZE) / 2)
            pe.wb.width  = PLUS_BTN_SIZE
            pe.wb.height = PLUS_BTN_SIZE
            pe.wb.visible = true
            entry.ref.plus_entry = pe
        end
    end
    add_edge_handle(wa.x + math.floor(gap / 2), "left", function()
        local tag = s.selected_tag
        if tag then ops.insert_at_left_edge(tag, s) end
    end)
    add_edge_handle(wa.x + canvas_w_val - math.floor(gap / 2), "right", function()
        local tag = s.selected_tag
        if tag then ops.insert_at_right_edge(tag, s) end
    end)

    local pool = drag_handle_pool[s]
    if pool then
        for i = hi + 1, #pool do pool[i].wb.visible = false end
    end
    local ppool = plus_btn_pool[s]
    if ppool then
        for i = pi + 1, #ppool do ppool[i].wb.visible = false end
    end
end

function underlay.hide_drag_handles(s)
    local pool = drag_handle_pool[s]
    if pool then for _, entry in ipairs(pool) do entry.wb.visible = false end end
    local ppool = plus_btn_pool[s]
    if ppool then for _, entry in ipairs(ppool) do entry.wb.visible = false end end
end

function underlay.flush_caches()
    for _, u in pairs(underlay_cache) do
        u.chrome_layer:reset()
    end
end

return underlay
