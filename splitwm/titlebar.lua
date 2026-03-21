---------------------------------------------------------------------------
-- splitwm.titlebar — Tab bar, split controls, color-picker popup, and
-- related UI widgets for the splitwm layout.
--
-- Shared pickup/drag state lives here (M.drag) so init.lua can reference
-- it by table without needing cross-module setter callbacks.
--
-- Dependencies are injected once via M.setup(deps) from splitwm.setup().
---------------------------------------------------------------------------

local awful     = require("awful")
local gears     = require("gears")
local wibox     = require("wibox")
local beautiful = require("beautiful")
local icons     = require("splitwm.icons")
local tree      = require("splitwm.tree")
local colors    = require("splitwm.colors")

---------------------------------------------------------------------------
-- Shared pickup / pending-drag state
-- init.lua binds `local drag = tb.drag` to get a shared reference.
---------------------------------------------------------------------------

local PICKUP_IDLE = { tag = "idle" }
local drag = { pickup = PICKUP_IDLE, pending = nil }

local function pickup_idle()            return PICKUP_IDLE end
local function pickup_client(c, t)      return { tag = "client", client = c, client_tag = t } end
local function pickup_split(id)         return { tag = "split",  split_id = id } end

---------------------------------------------------------------------------
-- Injected dependencies — populated by M.setup()
---------------------------------------------------------------------------

local _geo_cache, _client_actual_geo, _split_anim_active
local _try_drop_picked_up, _handle_split_pickup
local _make_split_action_callbacks
local _get_or_create_underlay, _make_wb_proxy
local _splitwm
local _TITLEBAR_HEIGHT, _BTN_SIZE, _BTN_SPACING, _MIN_SPLIT_W, _MIN_SPLIT_H
local color_bg, color_fg, color_fg_disabled, color_close
local color_btn_bg, color_transparent, color_fg_hover, color_handle

---------------------------------------------------------------------------
-- Module-local constants
---------------------------------------------------------------------------

-- Cairo line cap value for rounded ends (cairo.LineCap.ROUND = 1).
local CAIRO_LINE_CAP_ROUND = 1

-- Bottom padding applied to round buttons so they sit 2 px above centre.
local BTN_V_RAISE = 4

-- Number of split-control buttons (swap, split, close).  Used to compute the
-- right-margin reserve in the above-layer tab row so tabs don't overlap controls.
local NUM_CTRL_BTNS = 3

-- Tab color picker menu geometry.
local MENU_CIRC_SIZE = 18
local MENU_CIRC_GAP  = 4
local MENU_PAD_H     = 8
local MENU_PAD_V     = 6
local MENU_BW        = 2   -- border on left / right / bottom

-- Left/right padding inside each tab widget (drives close-button x-offset).
local TAB_PAD_H = 21

-- Tab shape geometry.  TAB_ALPHA is the slant angle from vertical.
local TAB_ALPHA  = math.rad(20)
local TAB_EAR    = 11
local TAB_CORNER = 8
local TAB_SA     = math.sin(TAB_ALPHA)
local TAB_CA     = math.cos(TAB_ALPHA)
local TAB_TA     = math.tan(TAB_ALPHA)
local function tab_cx(h) return (TAB_CORNER + TAB_EAR) * (1 - TAB_SA) / TAB_CA + h * TAB_TA end
-- Overlap = 2x slant width at the actual titlebar height.  Set in M.setup().
local TAB_SPACING

-- Width of one tab slot including its negative overlap with the next tab.
-- _BTN_SIZE is injected by setup(), so this must be called after setup().
local function tab_step(icon_size)
    return TAB_PAD_H + icon_size + 2 + _BTN_SIZE + TAB_PAD_H + TAB_SPACING
end

---------------------------------------------------------------------------
-- Titlebar cache and color-menu state
---------------------------------------------------------------------------

local titlebar_cache = {}
local tab_color_menu_state = { wb = nil, poll = nil, poll_ready = false }

---------------------------------------------------------------------------
-- Module table
---------------------------------------------------------------------------

local M = {}

M.drag          = drag
M.cache         = titlebar_cache
M.pickup_idle   = pickup_idle
M.pickup_client = pickup_client
M.pickup_split  = pickup_split

---------------------------------------------------------------------------
-- Tab shape — exported so rc.lua wibar capsules can match the tab profile
---------------------------------------------------------------------------

local function tab_path(cr, w, h)
    local cx = tab_cx(h)
    cr:move_to(0, h)
    cr:arc_negative(0,     h - TAB_EAR, TAB_EAR, math.pi / 2,             TAB_ALPHA)
    cr:line_to(cx - TAB_CORNER * TAB_CA, TAB_CORNER * (1 - TAB_SA))
    cr:arc(cx,     TAB_CORNER, TAB_CORNER, math.pi + TAB_ALPHA, 1.5 * math.pi)
    cr:arc(w - cx, TAB_CORNER, TAB_CORNER, 1.5 * math.pi,       2 * math.pi - TAB_ALPHA)
    cr:line_to(w - TAB_EAR * TAB_CA, h - TAB_EAR * (1 - TAB_SA))
    cr:arc_negative(w, h - TAB_EAR, TAB_EAR, math.pi - TAB_ALPHA, math.pi / 2)
end

function M.tab_shape(cr, w, h)
    tab_path(cr, w, h)
    cr:close_path()
end

---------------------------------------------------------------------------
-- Setup
---------------------------------------------------------------------------

function M.setup(deps)
    _geo_cache               = deps.geo_cache
    _client_actual_geo       = deps.client_actual_geo
    _split_anim_active       = deps.split_anim_active
    _try_drop_picked_up      = deps.try_drop_picked_up
    _handle_split_pickup     = deps.handle_split_pickup
    _make_split_action_callbacks = deps.make_split_action_callbacks
    _get_or_create_underlay  = deps.get_or_create_underlay
    _make_wb_proxy           = deps.make_wb_proxy
    _splitwm                 = deps.splitwm
    _TITLEBAR_HEIGHT         = deps.TITLEBAR_HEIGHT
    TAB_SPACING              = -math.floor((tab_cx(_TITLEBAR_HEIGHT) - TAB_EAR * TAB_CA) * 2)
    M.TAB_SPACING            = TAB_SPACING
    _BTN_SIZE                = deps.BTN_SIZE
    _BTN_SPACING             = deps.BTN_SPACING
    _MIN_SPLIT_W             = deps.MIN_SPLIT_W
    _MIN_SPLIT_H             = deps.MIN_SPLIT_H
    color_bg                 = deps.color_bg
    color_fg                 = deps.color_fg
    color_fg_disabled        = deps.color_fg_disabled
    color_close              = deps.color_close
    color_btn_bg             = deps.color_btn_bg
    color_transparent        = deps.color_transparent
    color_fg_hover           = deps.color_fg_hover
    color_handle             = deps.color_handle
end

---------------------------------------------------------------------------
-- Flush caches (called from splitwm.flush_caches)
---------------------------------------------------------------------------

function M.flush_caches()
    for _, sc in pairs(titlebar_cache) do
        for _, entry in pairs(sc) do
            for _, obj in ipairs(entry.tooltip_objs) do
                entry.tooltip:remove_from_object(obj)
            end
        end
    end
    -- Clear in-place so existing M.cache references stay valid.
    for k in pairs(titlebar_cache) do titlebar_cache[k] = nil end
end

---------------------------------------------------------------------------
-- Drawing helpers
---------------------------------------------------------------------------

local function rounded_top(cr, w, h)
    local r = 4
    cr:new_sub_path()
    cr:arc(r,     r, r, math.pi,       1.5 * math.pi)
    cr:arc(w - r, r, r, 1.5 * math.pi, 2   * math.pi)
    cr:line_to(w, h) cr:line_to(0, h) cr:close_path()
end

local function draw_tab_border(cr, w, h)
    tab_path(cr, w, h)
end

---------------------------------------------------------------------------
-- Vertical drag helper (used by the pill drag strip in the tab bar)
---------------------------------------------------------------------------

local function run_v_drag(s, get_b, on_start, on_stop)
    -- Capture start position before the delayed_call so it reflects the press position.
    local start_y = mouse.coords().y
    local moved   = false
    -- Delay starting the grab until after the current event batch is fully processed.
    gears.timer.delayed_call(function()
        if not mouse.coords().buttons[1] then return end
        if on_start then on_start() end
        mousegrabber.run(function(m)
            if not m.buttons[1] then
                if moved then awful.layout.arrange(s) end
                if on_stop then on_stop() end
                return false
            end
            if not moved and math.abs(m.y - start_y) < 4 then return true end
            moved = true
            local b = get_b()
            if not b then if on_stop then on_stop() end; return false end
            local igap = b.parent_gap or 0
            b.branch.ratio = math.max(0.1, math.min(0.9,
                (m.y - b.parent_y - math.floor(igap / 2)) / (b.parent_h - igap)))
            awful.layout.arrange(s)
            return true
        end, "sb_v_double_arrow")
    end)
end

---------------------------------------------------------------------------
-- Widget helpers
---------------------------------------------------------------------------

local function make_launcher_widget(entry, size, callback)
    local icon_path = entry.icon
    local inner
    if icon_path then
        inner = wibox.widget {
            image          = icon_path,
            forced_width   = size,
            forced_height  = size,
            resize         = true,
            widget         = wibox.widget.imagebox,
        }
    else
        inner = wibox.widget {
            text   = entry.label or "?",
            align  = "center",
            font   = "monospace bold " .. math.floor(size * 0.7) .. "px",
            widget = wibox.widget.textbox,
        }
    end

    local w = wibox.widget {
        {
            {
                inner,
                halign = "center",
                valign = "center",
                widget = wibox.container.place,
            },
            left = 4, right = 4, top = 2, bottom = 2,
            widget = wibox.container.margin,
        },
        bg     = color_transparent,
        fg     = color_fg,
        widget = wibox.container.background,
    }
    w:connect_signal("mouse::enter", function() w.bg = color_fg_hover end)
    w:connect_signal("mouse::leave", function() w.bg = color_transparent end)
    w:buttons(gears.table.join(awful.button({}, 1, callback)))
    return w
end

local function make_circle_icon_btn_widget(draw_fn, size)
    local icon = wibox.widget.base.make_widget()
    function icon:draw(_, cr, w, h)
        local col = self._disabled and color_fg_disabled
                    or (self._dark and color_bg or color_fg)
        cr:set_source(gears.color(col))
        cr:set_line_width(2)
        cr:set_line_cap(CAIRO_LINE_CAP_ROUND)
        draw_fn(cr, w, h)
    end
    function icon:fit(_, w, h) return w, h end
    local w = wibox.widget {
        icon,
        bg                 = color_btn_bg,
        shape              = gears.shape.circle,
        forced_width       = size,
        forced_height      = size,
        widget             = wibox.container.background,
    }
    w._icon = icon
    return w
end

---------------------------------------------------------------------------
-- Tab color picker popup menu
---------------------------------------------------------------------------

local function hide_tab_color_menu()
    local ms = tab_color_menu_state
    if not (ms.wb and ms.wb.visible) then return false end
    ms.wb.visible = false
    if ms.poll and ms.poll.started then ms.poll:stop() end
    return true
end

local function show_tab_color_menu(tc, s, tab_x, bar_bottom, bg_color, border_color, tab_w)
    local ms        = tab_color_menu_state
    local COLS      = 3
    local ROWS      = 3
    local content_w = COLS * MENU_CIRC_SIZE + (COLS - 1) * MENU_CIRC_GAP
    local menu_w    = tab_w or (MENU_BW * 2 + MENU_PAD_H * 2 + content_w)
    local pad_h     = math.max(MENU_BW, math.floor((menu_w - MENU_BW * 2 - content_w) / 2))
    local menu_h    = MENU_PAD_V * 2 + ROWS * MENU_CIRC_SIZE + (ROWS - 1) * MENU_CIRC_GAP + MENU_BW

    if not ms.wb then
        ms.wb = wibox { ontop = true, visible = false, border_width = 0 }
    end
    local wb = ms.wb
    wb.width  = menu_w
    wb.height = menu_h
    wb.bg     = bg_color

    -- Circle widgets are created once and reused; update selection + handlers each open.
    local current = colors.get_client_color(tc)
    if not ms.circs then
        ms.circs = {}
        for i, col in ipairs(colors.COLORS) do
            local circ = wibox.widget {
                bg                 = col.light,
                shape              = gears.shape.circle,
                shape_border_color = color_transparent,
                shape_border_width = MENU_BW,
                forced_width       = MENU_CIRC_SIZE,
                forced_height      = MENU_CIRC_SIZE,
                widget             = wibox.container.background,
            }
            circ:connect_signal("mouse::enter", function() wb.cursor = "hand2" end)
            circ:connect_signal("mouse::leave", function() wb.cursor = "left_ptr" end)
            ms.circs[i] = circ
        end
    end
    for i, col in ipairs(colors.COLORS) do
        local circ = ms.circs[i]
        circ.shape_border_color = (current and current.name == col.name) and color_fg or color_transparent
        local col_name = col.name
        circ:buttons(gears.table.join(awful.button({}, 1, function()
            if tc.valid then
                colors.set_client_color(tc, col_name)
                hide_tab_color_menu()
                awful.layout.arrange(s)
            end
        end)))
    end

    -- Border widget created once; source color updated each open.
    if not ms.border_w then
        local bw = wibox.widget.base.make_widget()
        function bw:draw(_, cr, w, h)
            if not self._bpat then return end
            cr:set_source(self._bpat)
            cr:set_line_width(MENU_BW)
            local o = MENU_BW / 2
            cr:move_to(o, 0) cr:line_to(o, h) cr:stroke()
            cr:move_to(w - o, 0) cr:line_to(w - o, h) cr:stroke()
            cr:move_to(0, h - o) cr:line_to(w, h - o) cr:stroke()
        end
        function bw:fit(_, w, h) return w, h end
        ms.border_w = bw
    end
    ms.border_w._bpat = gears.color(border_color)
    ms.border_w:emit_signal("widget::redraw_needed")

    -- Grid layout and wb:setup only rebuilt when menu width changes.
    if ms.last_menu_w ~= menu_w then
        ms.last_menu_w = menu_w
        local grid = { spacing = MENU_CIRC_GAP, layout = wibox.layout.fixed.vertical }
        for row = 0, ROWS - 1 do
            local row_spec = { spacing = MENU_CIRC_GAP, layout = wibox.layout.fixed.horizontal }
            for col = 1, COLS do
                local idx = row * COLS + col
                if ms.circs[idx] then table.insert(row_spec, ms.circs[idx]) end
            end
            table.insert(grid, wibox.widget(row_spec))
        end
        wb:setup {
            ms.border_w,
            {
                grid,
                left   = pad_h,
                right  = pad_h,
                top    = MENU_PAD_V,
                bottom = MENU_PAD_V + MENU_BW,
                widget = wibox.container.margin,
            },
            layout = wibox.layout.stack,
        }
    end

    local sg = s.geometry
    wb.x = math.max(sg.x, math.min(sg.x + sg.width - menu_w, tab_x))
    wb.y = bar_bottom
    wb.visible = true

    ms.poll_ready = false
    if not ms.poll then
        ms.poll = gears.timer {
            timeout   = 0.05,
            autostart = false,
            callback  = function()
                if not (wb and wb.visible) then
                    ms.poll_ready = false; ms.poll:stop(); return
                end
                local m = mouse.coords()
                local pressed = (m.buttons[1] or m.buttons[3]) and true or false
                if not ms.poll_ready then
                    if not pressed then ms.poll_ready = true end
                    return
                end
                if pressed then
                    local g = wb:geometry()
                    if not (m.x >= g.x and m.x < g.x + g.width
                        and m.y >= g.y and m.y < g.y + g.height) then
                        hide_tab_color_menu()
                    end
                end
            end,
        }
    end
    if ms.poll.started then ms.poll:stop() end
    ms.poll:start()
end

-- Closes the menu if open and returns true; returns false if already closed.
-- Deduplicates within a single event: multiple handlers firing for the same
-- click all check this, but only the first actually calls on_menu_close().
local function event_close_menu_if_open()
    if _splitwm._menu_just_toggled then return false end
    if _splitwm._menu_was_open     then return true  end
    if hide_tab_color_menu() then
        _splitwm._menu_was_open = true
        gears.timer.delayed_call(function() _splitwm._menu_was_open = false end)
        return true
    end
    if _splitwm.on_menu_close and _splitwm.on_menu_close() then
        _splitwm._menu_was_open = true
        gears.timer.delayed_call(function() _splitwm._menu_was_open = false end)
        return true
    end
    return false
end

---------------------------------------------------------------------------
-- Titlebar helper functions
---------------------------------------------------------------------------

local function on_hover_fg(w, hover_fg, normal_fg)
    w:connect_signal("mouse::enter", function() w.fg = hover_fg end)
    w:connect_signal("mouse::leave", function() w.fg = normal_fg end)
end

local function set_btn_disabled(w, wb)
    w._disabled = true
    w._icon._disabled = true
    w._icon:emit_signal("widget::redraw_needed")
    w:buttons(gears.table.join())
    if wb then
        w:connect_signal("mouse::enter", function() wb.cursor = "circle" end)
        w:connect_signal("mouse::leave", function() wb.cursor = "left_ptr" end)
    end
end

local function tb_get_or_create_entry(s, leaf)
    local cache = titlebar_cache[s]
    local entry = cache[leaf.id]
    if entry then return entry end
    entry = {
        wb                = _make_wb_proxy(_get_or_create_underlay(s).chrome_layer, s),
        tooltip           = awful.tooltip {
            text = "", delay_show = 0.3, font = "monospace bold 12px",
            bg = color_bg, fg = color_fg, border_width = 0,
        },
        tooltip_objs      = {},
        titlebar_btn_list = {},
        tb_h              = nil,
    }
    cache[leaf.id] = entry
    return entry
end

-- Fingerprint check to prevent unneeded heavy redraws.
-- Tab names are excluded: tooltip text is set dynamically on mouse::enter.
local function tb_compute_fingerprint(leaf, state, geo)
    local parts = {
        leaf.active_tab,
        state.focused_leaf_id == leaf.id and 1 or 0,
        tostring(leaf.v_bound_above),
        (drag.pickup.tag == "split" and drag.pickup.split_id == leaf.id) and "S" or "",
        geo and geo.width or 0,
        geo and geo.height or 0,
    }
    for _, tc in ipairs(leaf.tabs) do
        parts[#parts+1] = tostring(tc.window)
        if drag.pickup.tag == "client" and drag.pickup.client == tc then parts[#parts+1] = "P" end
        local col = colors.get_client_color(tc)
        if col then parts[#parts+1] = col.name end
    end
    return table.concat(parts, "\0")
end

local function tb_make_btn(entry, widget_bc, draw_fn, size, callback)
    local w = make_circle_icon_btn_widget(draw_fn, size)
    w.shape_border_color = widget_bc
    if callback then w:buttons(gears.table.join(awful.button({}, 1, callback))) end
    w:connect_signal("mouse::enter", function() if not w._disabled then w.bg = color_bg end end)
    w:connect_signal("mouse::leave", function() if not w._disabled then w.bg = color_btn_bg end end)
    table.insert(entry.titlebar_btn_list, w)
    return w
end

-- tab_state: "active" | "inactive" | "picked"
local function get_tab_state(tab_idx, leaf, tc)
    if drag.pickup.tag == "client" and drag.pickup.client == tc then return "picked"
    elseif tab_idx == leaf.active_tab then return "active"
    else return "inactive"
    end
end

---------------------------------------------------------------------------
-- Build the widget for a single tab
---------------------------------------------------------------------------

local function tb_build_tab_widget(leaf, tc, tab_idx, entry, ctx)
    local tab_state = get_tab_state(tab_idx, leaf, tc)
    local step      = tab_step(ctx.icon_size)
    local gap       = beautiful.splitwm_gap

    -- Returns true if (mx, my) is over the close button of this tab.
    local function in_close_btn(mx, my, g)
        local cx1 = g.x + (tab_idx - 1) * step + TAB_PAD_H + ctx.icon_size + 2
        return tab_state == "active"
           and mx >= cx1 and mx < cx1 + _BTN_SIZE
           and my >= g.y - gap
           and my <  g.y - gap + ctx.tb_h
    end

    local tab_icon
    if tc.icon then
        tab_icon = awful.widget.clienticon(tc)
        tab_icon.forced_width  = ctx.icon_size
        tab_icon.forced_height = ctx.icon_size
    else
        tab_icon = wibox.widget {
            text          = string.sub(tc.class or tc.instance or "?", 1, 2),
            align         = "center",
            valign        = "center",
            forced_width  = ctx.icon_size,
            forced_height = ctx.icon_size,
            widget        = wibox.widget.textbox,
        }
    end

    local move_overlay = wibox.widget {
        { text = "↗", align = "center", font = ctx.tab_btn_font, widget = wibox.widget.textbox },
        bg            = tab_state == "picked" and color_fg or color_transparent,
        fg            = tab_state == "picked" and color_bg or color_transparent,
        forced_width  = ctx.icon_size,
        forced_height = ctx.icon_size,
        widget        = wibox.container.background,
    }
    local icon_move_btn = wibox.widget {
        { tab_icon, halign = "center", valign = "center", widget = wibox.container.place },
        move_overlay, layout = wibox.layout.stack,
    }
    local close_btn = wibox.widget {
        { text = "✕", align = "center", font = ctx.tab_btn_font, widget = wibox.widget.textbox },
        bg           = color_transparent,
        fg           = tab_state == "active" and color_fg or color_transparent,
        shape        = function(cr, w, h) gears.shape.rounded_rect(cr, w, h, 4) end,
        forced_width = _BTN_SIZE,
        widget       = wibox.container.background,
    }

    -- Activate focus on tc (no-op if client is no longer valid).
    local function focus_tc()
        if tc.valid then tc:emit_signal("request::activate", "mouse_click", {raise = true}) end
    end

    -- Phase 1: while button held, promote pending → pickup once cursor leaves the tab bounds.
    local function try_promote_pending(m)
        local g = _geo_cache[ctx.t] and _geo_cache[ctx.t].geos[leaf.id]
        if not g then return end
        local gap = beautiful.splitwm_gap
        local tx  = g.x + (tab_idx - 1) * step
        local ty  = g.y - gap
        if m.x < tx or m.x >= tx + step - TAB_SPACING
        or m.y < ty or m.y >= ty + ctx.tb_h then
            drag.pending = nil
            drag.pickup  = pickup_client(tc, ctx.t)
            awful.layout.arrange(ctx.s)
        end
    end

    -- Phase 2: button released while still pending (quick click — cursor never left the tab).
    local function settle_pending(m)
        drag.pending = nil
        local mx, my = m.x, m.y
        local g = _geo_cache[ctx.t] and _geo_cache[ctx.t].geos[leaf.id]
        if g and in_close_btn(mx, my, g) then tc:kill(); return false end
        leaf.active_tab = tab_idx
        ctx.state.focused_leaf_id = leaf.id
        focus_tc()
        awful.layout.arrange(ctx.s)
        return false
    end

    -- Phase 3: button released with an active pickup — drop, kill, or reorder.
    local function settle_pickup(m)
        local mx, my = m.x, m.y
        local gap    = beautiful.splitwm_gap
        local cached = _geo_cache[ctx.t]
        -- Released over the close button of the originating tab: close the tab.
        local og = cached and cached.geos[leaf.id]
        if og and in_close_btn(mx, my, og) then
            drag.pickup = pickup_idle()
            tc:kill()
            return false
        end
        if cached then
            for lid, _ in pairs(ctx.state.leaf_map) do
                local g = cached.geos[lid]
                if g and mx >= g.x and mx < g.x + g.width
                       and my >= g.y - gap and my < g.y + g.height then
                    if lid ~= leaf.id then
                        _try_drop_picked_up(ctx.t, lid)
                        awful.layout.arrange(ctx.s)
                    elseif my < g.y then
                        -- Same leaf, in tab bar: reorder tabs by drop position.
                        local reorder_step = tab_step(ctx.icon_size)
                        local target = math.max(1, math.min(#leaf.tabs,
                            math.floor((mx - g.x) / reorder_step) + 1))
                        if target ~= tab_idx then
                            leaf.tabs[tab_idx], leaf.tabs[target] =
                                leaf.tabs[target], leaf.tabs[tab_idx]
                        end
                        leaf.active_tab = target
                        ctx.state.focused_leaf_id = leaf.id
                        drag.pickup = pickup_idle()
                        focus_tc()
                        awful.layout.arrange(ctx.s)
                    end
                    return false
                end
            end
        end
        -- Released outside all splits: stay in pickup mode so user can switch tags and drop there.
        return false
    end

    -- Shared mousegrabber callback: dispatches to the appropriate drag phase.
    local function drag_release_fn(m)
        if m.buttons[1] and drag.pending and drag.pending.client == tc then
            try_promote_pending(m); return true
        end
        if m.buttons[1] then return true end
        if drag.pending and drag.pending.client == tc then return settle_pending(m) end
        if drag.pickup.tag == "client" and not drag.pickup.client.valid then
            drag.pickup = pickup_idle(); awful.layout.arrange(ctx.s); return false
        end
        if drag.pickup.tag == "client" then return settle_pickup(m) end
        return false
    end

    -- Begin a tab drag: start the mousegrabber after the current event batch.
    local function start_tab_drag()
        drag.pending = { client = tc, client_tag = ctx.t }
        gears.timer.delayed_call(function()
            if not mouse.coords().buttons[1] then
                if drag.pending and drag.pending.client == tc then drag.pending = nil end
                return
            end
            if mousegrabber.isrunning() then return end
            local has_pending = drag.pending and drag.pending.client == tc
            local has_pickup  = drag.pickup.tag == "client" and drag.pickup.client == tc
            if not has_pending and not has_pickup then return end
            mousegrabber.run(drag_release_fn, "fleur")
        end)
    end

    if tab_state == "active" then
        move_overlay:connect_signal("mouse::enter", function()
            move_overlay.bg = color_fg_hover
            move_overlay.fg = color_fg
        end)
        move_overlay:connect_signal("mouse::leave", function()
            move_overlay.bg = color_transparent
            move_overlay.fg = color_transparent
        end)
    end

    local client_color  = colors.get_client_color(tc)
    local tab_bg = tab_state == "picked" and color_fg
        or (client_color and client_color.dark)
        or (tab_state == "active" and color_bg)
        or color_btn_bg
    local tab_bg_pat    = gears.color(tab_bg)
    local widget_bc_pat = gears.color(ctx.widget_bc)

    local tab_draw = wibox.widget.base.make_widget()
    function tab_draw:draw(_, cr, w2, h2)
        local h = h2 - 1  -- 1px breathing room at top so the border stroke isn't clipped
        cr:translate(0, 1)
        tab_path(cr, w2, h)
        cr:close_path()
        cr:set_source(tab_bg_pat)
        cr:fill()
        if tab_state == "active" or tab_state == "picked" then
            draw_tab_border(cr, w2, h)
            cr:set_source(tab_state == "picked" and gears.color(color_fg) or widget_bc_pat)
            cr:set_line_width(2)
            cr:stroke()
        end
    end
    function tab_draw:fit(_, _, _) return 0, 0 end

    local tab_widget = wibox.widget {
        tab_draw,
        {
            {
                icon_move_btn, close_btn, spacing = 2, layout = wibox.layout.fixed.horizontal,
            },
            left = TAB_PAD_H, right = TAB_PAD_H, top = 1, bottom = 1, widget = wibox.container.margin,
        },
        layout = wibox.layout.stack,
    }

    tab_widget:connect_signal("mouse::enter", function()
        entry.tooltip.text = (tc.valid and tc.name) or "?"
        -- If the mouse button is held and we're not dragging a tab, switch to this tab.
        if mouse.coords().buttons[1]
        and drag.pickup.tag == "idle"
        and drag.pending == nil
        and tab_idx ~= leaf.active_tab
        and tc.valid then
            leaf.active_tab = tab_idx
            ctx.state.focused_leaf_id = leaf.id
            focus_tc()
            awful.layout.arrange(ctx.s)
        end
    end)
    tab_widget:connect_signal("mouse::leave", function()
        if drag.pending and drag.pending.client == tc and mouse.coords().buttons[1] then
            drag.pending = nil
            drag.pickup  = pickup_client(tc, ctx.t)
            awful.layout.arrange(ctx.s)
        end
    end)
    entry.tooltip:add_to_object(tab_widget)
    table.insert(entry.tooltip_objs, tab_widget)

    tab_widget:buttons(gears.table.join(
        awful.button({}, 1, function()
            if drag.pickup.tag == "split" and drag.pickup.split_id ~= leaf.id then
                _handle_split_pickup(ctx.state, leaf.id, ctx.s); return
            end
            if drag.pickup.tag == "client" and drag.pickup.client.valid and drag.pickup.client ~= tc then
                _try_drop_picked_up(ctx.t, leaf.id)
                awful.layout.arrange(ctx.s)
                return
            end
            -- Clicking the picked tab again cancels the drag.
            if tab_state == "picked" and drag.pickup.tag == "client" and drag.pickup.client == tc then
                drag.pickup = pickup_idle()
                awful.layout.arrange(ctx.s)
                return
            end
            start_tab_drag()
        end, function()
            -- Release handler: fires only for quick clicks (before mousegrabber starts).
            local is_pending = drag.pending and drag.pending.client == tc
            if not is_pending and (drag.pickup.tag ~= "client" or drag.pickup.client ~= tc) then return end
            if is_pending then drag.pending = nil end
            local mc = mouse.coords()
            local g  = _geo_cache[ctx.t] and _geo_cache[ctx.t].geos[leaf.id]
            if g and in_close_btn(mc.x, mc.y, g) then
                drag.pickup = pickup_idle()
                tc:kill()
                return
            end
            leaf.active_tab = tab_idx
            ctx.state.focused_leaf_id = leaf.id
            drag.pickup = pickup_idle()
            focus_tc()
            awful.layout.arrange(ctx.s)
        end),
        awful.button({}, 3, function()
            if not tc.valid then return end
            if _splitwm.on_menu_close then _splitwm.on_menu_close() end
            if tab_color_menu_state.wb and tab_color_menu_state.wb.visible then
                hide_tab_color_menu(); return
            end
            local g = _geo_cache[ctx.t] and _geo_cache[ctx.t].geos[leaf.id]
            if not g then return end
            local tab_x      = g.x + (tab_idx - 1) * step
            local bar_bottom = g.y - beautiful.splitwm_gap + ctx.tb_h
            local cc = colors.get_client_color(tc)
            show_tab_color_menu(tc, ctx.s, tab_x, bar_bottom,
                cc and cc.dark or color_bg,
                cc and cc.light or color_fg,
                step - TAB_SPACING)
        end)
    ))

    return tab_widget
end

---------------------------------------------------------------------------
-- Build the right-side split control buttons (swap, split, close)
---------------------------------------------------------------------------

local function tb_build_split_controls(leaf, entry, ctx)
    local gap      = beautiful.splitwm_gap
    local geo      = ctx.geo
    local parent   = tree.find_parent(ctx.state.root, leaf)
    local can_vsplit = geo and geo.width  >= 2 * _MIN_SPLIT_W + gap
    local can_hsplit = geo and geo.height >= 2 * _MIN_SPLIT_H + gap

    local function make_btn(draw_fn, callback, disabled)
        return tb_make_btn(entry, ctx.widget_bc, draw_fn, _BTN_SIZE,
            not disabled and callback)
    end

    local cb     = _make_split_action_callbacks(ctx.state, leaf.id, ctx.t, ctx.s)
    local wider  = geo and geo.width >= geo.height
    local auto_icon    = wider and icons.vsplit or icons.hsplit
    local auto_cb      = wider and (can_vsplit and cb.vsplit or nil)
                                or (can_hsplit and cb.hsplit or nil)
    local auto_cb_opp  = wider and (can_hsplit and cb.hsplit or nil)
                                or (can_vsplit and cb.vsplit or nil)
    local can_split    = wider and can_vsplit or can_hsplit
    local split_btn       = make_btn(auto_icon,  auto_cb,  not can_split)
    if auto_cb_opp then
        split_btn:buttons(gears.table.join(
            split_btn:buttons(),
            awful.button({}, 3, auto_cb_opp)
        ))
    end
    local close_split_btn = make_btn(icons.close, cb.close, not parent)

    if not can_split then set_btn_disabled(split_btn, entry.wb) end
    if parent then on_hover_fg(close_split_btn, color_close, color_fg)
    else           set_btn_disabled(close_split_btn, entry.wb) end

    local is_split_picked = (drag.pickup.tag == "split" and drag.pickup.split_id == leaf.id)
    local swap_btn = make_circle_icon_btn_widget(icons.swap, _BTN_SIZE)
    swap_btn.shape_border_color = ctx.widget_bc
    if is_split_picked then swap_btn.bg = color_fg; swap_btn._icon._dark = true end
    entry.swap_btn        = swap_btn
    entry.swap_btn_picked = is_split_picked
    swap_btn:connect_signal("mouse::enter", function()
        if not entry.swap_btn_picked then swap_btn.bg = color_bg end
    end)
    swap_btn:connect_signal("mouse::leave", function()
        swap_btn.bg = entry.swap_btn_picked and color_fg or color_btn_bg
        if swap_btn._icon then
            swap_btn._icon._dark = entry.swap_btn_picked
            swap_btn._icon:emit_signal("widget::redraw_needed")
        end
    end)
    swap_btn:buttons(gears.table.join(awful.button({}, 1, function()
        if drag.pickup.tag == "split" and drag.pickup.split_id == leaf.id then
            drag.pickup = pickup_idle()
        elseif drag.pickup.tag == "split" then
            _handle_split_pickup(ctx.state, leaf.id, ctx.s); return
        elseif drag.pickup.tag == "client" then
            drag.pickup = pickup_idle()
        else
            drag.pickup = pickup_split(leaf.id)
            ctx.state.focused_leaf_id = leaf.id
        end
        awful.layout.arrange(ctx.s)
    end)))

    return { split = split_btn, close = close_split_btn, swap = swap_btn }
end

---------------------------------------------------------------------------
-- Build the focus border drawn around the client area
---------------------------------------------------------------------------

local function tb_build_border_widget(border_color, tb_h, bw, radius, entry_ref)
    local w   = wibox.widget.base.make_widget()
    w._bc     = border_color
    w._tb_h   = tb_h
    w._bw     = bw
    function w:draw(_, cr, width, height)
        if not self._bc then return end
        cr:set_source(gears.color(self._bc))
        cr:set_line_width(self._bw)
        local half = self._bw / 2
        local x    = half
        local y    = self._tb_h - half
        local cw   = entry_ref and entry_ref.border_client_w
        local ch   = entry_ref and entry_ref.border_client_h
        local wd   = cw and (cw + self._bw) or (width  - self._bw)
        local h    = ch and (ch + self._bw) or (height - self._tb_h)
        local r    = radius or beautiful.splitwm_border_radius
        cr:new_sub_path()
        cr:arc(x + wd - r, y + r,     r, -math.pi / 2, 0)
        cr:arc(x + wd - r, y + h - r, r,  0,           math.pi / 2)
        cr:arc(x + r,      y + h - r, r,  math.pi / 2, math.pi)
        cr:arc(x + r,      y + r,     r,  math.pi,     3 * math.pi / 2)
        cr:close_path()
        cr:stroke()
    end
    function w:fit(_, wd, h) return wd, h end
    return w
end

---------------------------------------------------------------------------
-- Split tab_widgets into two layers
---------------------------------------------------------------------------

-- The active tab and the "+" button float above the border widget;
-- inactive tabs stay behind it.  Spacers preserve layout width in each layer.
local function tb_split_tab_layers(tab_widgets, active_tab)
    local behind, above = {}, {}
    local n = #tab_widgets
    for i, tw in ipairs(tab_widgets) do
        local ref = tw
        local sp  = wibox.widget.base.make_widget()
        function sp:fit(wctx, w, h) return ref:fit(wctx, w, h) end
        function sp:draw() end
        if i == active_tab then
            table.insert(behind, sp)
            table.insert(above,  tw)
        elseif i == n then
            -- "+" button always in above layer
            table.insert(behind, sp)
            table.insert(above,  tw)
        else
            table.insert(behind, tw)
            table.insert(above,  sp)
        end
    end
    return behind, above
end

---------------------------------------------------------------------------
-- Assemble bar layer
---------------------------------------------------------------------------

local function tb_build_bar_layer(behind, controls, drag_pill, ctx)
    local tab_spacing = #behind > 1 and TAB_SPACING or 0
    local tabs        = { spacing = tab_spacing, layout = wibox.layout.fixed.horizontal, table.unpack(behind) }
    local ctrl_cover  = {
        {
            {
                { controls.swap, controls.split, controls.close,
                  spacing = _BTN_SPACING, layout = wibox.layout.fixed.horizontal },
                widget = wibox.container.margin,
            },
            bg = ctx.bar_bg, widget = wibox.container.background,
        },
        bottom = BTN_V_RAISE, widget = wibox.container.margin,
    }
    local bar_content
    if drag_pill then
        bar_content = { tabs, drag_pill, ctrl_cover, layout = wibox.layout.align.horizontal }
    else
        bar_content = { tabs, { ctrl_cover, halign = "right", widget = wibox.container.place },
                        layout = wibox.layout.stack }
    end
    return {
        {
            { bar_content, top = ctx.top_pad, widget = wibox.container.margin },
            bg = ctx.bar_bg, shape = rounded_top, forced_height = ctx.tb_bar_h,
            widget = wibox.container.background,
        },
        layout = wibox.layout.fixed.vertical,
    }
end

---------------------------------------------------------------------------
-- Assemble the three-layer wibox layout for a leaf's titlebar
---------------------------------------------------------------------------

local function tb_assemble_wibox(entry, behind, above, controls, border_draw, middle_drag, ctx)
    entry.wb:setup {
        -- Layer 1: inactive tabs + split controls (behind border)
        tb_build_bar_layer(behind, controls, middle_drag, ctx),
        -- Layer 2: focus border
        border_draw,
        -- Layer 3: active tab on top of border
        {
            {
                {
                    {
                        { spacing = TAB_SPACING, layout = wibox.layout.fixed.horizontal, table.unpack(above) },
                        right = (NUM_CTRL_BTNS + 1) * _BTN_SIZE + NUM_CTRL_BTNS * _BTN_SPACING, widget = wibox.container.margin,
                    },
                    top = ctx.top_pad, widget = wibox.container.margin,
                },
                forced_height = ctx.tb_bar_h, widget = wibox.container.background,
            },
            layout = wibox.layout.fixed.vertical,
        },
        layout = wibox.layout.stack,
    }
end

---------------------------------------------------------------------------
-- Assemble the titlebar wibox for an empty leaf
---------------------------------------------------------------------------

local function tb_assemble_empty_wibox(entry, bar_widgets, controls, border_draw, middle_drag, launcher_ws, ctx)
    local row1, row2 = {}, {}
    local mid = math.ceil(#launcher_ws / 2)
    for i, w in ipairs(launcher_ws) do
        if i <= mid then table.insert(row1, w) else table.insert(row2, w) end
    end
    local icon_grid
    if #row2 > 0 then
        icon_grid = {
            { spacing = _BTN_SPACING, layout = wibox.layout.fixed.horizontal, table.unpack(row1) },
            { spacing = _BTN_SPACING, layout = wibox.layout.fixed.horizontal, table.unpack(row2) },
            spacing = _BTN_SPACING, layout = wibox.layout.fixed.vertical,
        }
    else
        icon_grid = { spacing = _BTN_SPACING, layout = wibox.layout.fixed.horizontal, table.unpack(launcher_ws) }
    end
    local corner_r = beautiful.splitwm_empty_radius
    entry.wb:setup {
        -- Layer 1: content background
        {
            { forced_height = ctx.tb_bar_h, widget = wibox.container.background },
            {
                {
                    { icon_grid, halign = "center", valign = "center", widget = wibox.container.place },
                    widget = wibox.container.background,
                },
                bg    = color_btn_bg,
                shape = function(cr, w, h) gears.shape.rounded_rect(cr, w, h, corner_r) end,
                widget = wibox.container.background,
            },
            layout = wibox.layout.align.vertical,
        },
        -- Layer 2: bar strip with controls
        tb_build_bar_layer(bar_widgets, controls, middle_drag, ctx),
        -- Layer 3: focus border
        border_draw,
        layout = wibox.layout.stack,
    }
end

---------------------------------------------------------------------------
-- Main titlebar update
---------------------------------------------------------------------------

local function update_titlebars(s, t, state, geos, leaves)
    if not titlebar_cache[s] then titlebar_cache[s] = {} end

    local gap  = beautiful.splitwm_gap
    local tb_h = math.max(_TITLEBAR_HEIGHT, gap)
    local bw   = beautiful.splitwm_focus_border_width
    local alive = {}

    local function update_leaf(leaf)
        local geo = geos[leaf.id]
        if not geo then return end

        local entry = tb_get_or_create_entry(s, leaf)
        entry.tb_h  = tb_h
        local wb    = entry.wb
        local border_ref_client = leaf.tabs[leaf.active_tab]
        wb.visible = true
        if not _split_anim_active[s] then
            wb.x      = geo.x
            wb.y      = geo.y - gap
            wb.width  = geo.width
            wb.height = geo.height + gap
        end

        -- Geometry-only fingerprint: border size is only recomputed when geometry
        -- or active client changes, NOT on focus changes from hover.
        local geo_fp_parts = { leaf.active_tab, geo.width, geo.height }
        for _, tc in ipairs(leaf.tabs) do geo_fp_parts[#geo_fp_parts+1] = tostring(tc.window) end
        local geo_fp = table.concat(geo_fp_parts, "\0")
        if entry.geo_fp ~= geo_fp then
            entry.geo_fp = geo_fp
            entry.border_client_w = nil
            entry.border_client_h = nil
            if border_ref_client and border_ref_client.valid and not border_ref_client.fullscreen then
                local ag    = _client_actual_geo[border_ref_client]
                local exp_w = geo.width - bw * 2
                local exp_h = geo.height + gap - bw - tb_h
                if ag and ag.width  < exp_w - 1 then entry.border_client_w = ag.width  end
                if ag and ag.height < exp_h - 1 then entry.border_client_h = ag.height end
            end
        end

        local fp = tb_compute_fingerprint(leaf, state, geo)
        if entry.fp == fp then return end
        entry.fp              = fp
        entry.titlebar_btn_list = {}

        local is_focused    = state.focused_leaf_id == leaf.id
        local active_client = leaf.tabs[leaf.active_tab]
        local active_picked = drag.pickup.tag == "client" and drag.pickup.client == active_client
        local active_color  = active_client and colors.get_client_color(active_client)
        local focus_color   = active_picked and color_fg
            or (active_color and active_color.light)
            or color_fg
        local ctx = {
            s            = s,
            t            = t,
            state        = state,
            geo          = geo,
            widget_bc    = is_focused and focus_color or color_transparent,
            bar_bg       = color_transparent,
            top_pad      = math.max(gap, _TITLEBAR_HEIGHT) - _TITLEBAR_HEIGHT,
            tb_h         = tb_h,
            tb_bar_h     = tb_h,
            icon_size    = tb_h - 4,
            tab_btn_font = "monospace bold 18px",
        }

        -- Detach tooltip from previous tab widgets before rebuilding.
        entry.tooltip:hide()
        for _, obj in ipairs(entry.tooltip_objs) do entry.tooltip:remove_from_object(obj) end
        entry.tooltip_objs = {}

        -- Build per-tab widgets.
        local tab_widgets = {}
        for i, tc in ipairs(leaf.tabs) do
            table.insert(tab_widgets, tb_build_tab_widget(leaf, tc, i, entry, ctx))
        end

        -- "+" button lives at the end; tb_split_tab_layers always puts it in the above layer.
        table.insert(tab_widgets, wibox.widget {
            tb_make_btn(entry, ctx.widget_bc, icons.plus, _BTN_SIZE, function()
                pcall(function() mousegrabber.stop() end)
                ctx.state.focused_leaf_id = leaf.id
                if _splitwm.on_menu_request then _splitwm.on_menu_request() end
            end),
            left = #leaf.tabs > 0 and 24 or 0, bottom = BTN_V_RAISE, widget = wibox.container.margin,
        })

        local controls    = tb_build_split_controls(leaf, entry, ctx)

        local empty_r     = 14
        local border_draw = #leaf.tabs == 0
            and tb_build_border_widget(is_focused and color_fg or nil, tb_h, bw, empty_r)
            or  tb_build_border_widget(is_focused and focus_color or nil, tb_h, bw, nil, entry)

        local drag_pill
        if leaf.v_bound_above then
            local pill_bg = wibox.widget {
                bg     = entry.pill_dragging and color_fg or color_transparent,
                shape  = function(cr, w, h) gears.shape.rounded_rect(cr, w, h, math.floor(h / 2)) end,
                widget = wibox.container.background,
            }
            entry.pill_bg = pill_bg
            drag_pill = wibox.widget {
                { pill_bg, bottom = BTN_V_RAISE, left = 4, right = 4, widget = wibox.container.margin },
                bg     = color_transparent,
                cursor = "sb_v_double_arrow",
                widget = wibox.container.background,
            }
            drag_pill:connect_signal("mouse::enter", function()
                if not entry.pill_dragging then entry.pill_bg.bg = color_handle end
            end)
            drag_pill:connect_signal("mouse::leave", function()
                if not entry.pill_dragging then entry.pill_bg.bg = color_transparent end
            end)
            drag_pill:buttons(gears.table.join(awful.button({}, 1, function()
                if event_close_menu_if_open() then return end
                run_v_drag(s, function() return leaf.v_bound_above end,
                    function() entry.pill_dragging = true;  entry.pill_bg.bg = color_fg end,
                    function() entry.pill_dragging = false; entry.pill_bg.bg = color_transparent end)
            end)))
        end

        if #leaf.tabs == 0 then
            local launcher_ws = {}
            for _, e in ipairs(_splitwm.launchers) do
                launcher_ws[#launcher_ws + 1] = make_launcher_widget(e, 30, function()
                    ctx.state.focused_leaf_id = leaf.id
                    if e.action then e.action() elseif e.cmd then awful.spawn(e.cmd) end
                end)
            end
            tb_assemble_empty_wibox(entry, tab_widgets, controls, border_draw, drag_pill, launcher_ws, ctx)
            entry.wb:buttons(gears.table.join(awful.button({}, 1, function()
                if drag.pickup.tag == "split"  then _handle_split_pickup(ctx.state, leaf.id, ctx.s); return end
                if drag.pickup.tag == "client" then _try_drop_picked_up(ctx.t, leaf.id); awful.layout.arrange(ctx.s); return end
                if event_close_menu_if_open() then return end
                ctx.state.focused_leaf_id = leaf.id; awful.layout.arrange(ctx.s)
            end)))
        else
            entry.wb:buttons(gears.table.join())
            local behind, above = tb_split_tab_layers(tab_widgets, leaf.active_tab)
            tb_assemble_wibox(entry, behind, above, controls, border_draw, drag_pill, ctx)
        end
    end

    for _, leaf in ipairs(leaves) do
        alive[leaf.id] = true
        update_leaf(leaf)
    end

    -- Hide and clean up entries for dead leaves.
    for leaf_id, entry in pairs(titlebar_cache[s]) do
        if alive[leaf_id] then goto continue end
        entry.wb.visible = false
        titlebar_cache[s][leaf_id] = nil
        ::continue::
    end
end

---------------------------------------------------------------------------
-- Public update entry point
---------------------------------------------------------------------------

M.update = update_titlebars

return M
