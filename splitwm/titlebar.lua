---------------------------------------------------------------------------
-- splitwm.titlebar — tab bar, split controls, color-picker popup, and
-- related UI widgets for the splitwm layout.
--
-- Pickup/drag state lives in core.drag; the per-leaf wibox cache lives in
-- core.tabbar (animation.lua repositions those wiboxes during animations).
-- M.init() must run once from splitwm.setup() after beautiful is loaded.
---------------------------------------------------------------------------

local awful        = require("awful")
local gears        = require("gears")
local wibox        = require("wibox")
local beautiful    = require("beautiful")
local icons        = require("splitwm.icons")
local client_icons = require("splitwm.client_icons")
local tree         = require("splitwm.tree")
local colors       = require("splitwm.colors")
local core         = require("splitwm.core")
local theme        = require("splitwm.theme")
local ops          = require("splitwm.ops")
local anim         = require("splitwm.animation")
local underlay     = require("splitwm.underlay")

local M = {}

local drag = core.drag

---------------------------------------------------------------------------
-- Module-local constants
---------------------------------------------------------------------------

-- Cairo line cap value for rounded ends (cairo.LineCap.ROUND = 1).
local CAIRO_LINE_CAP_ROUND = 1

-- Bottom padding applied to round buttons so they sit 2 px above centre.
local BTN_V_RAISE = 4

-- Tab color picker menu geometry.
local MENU_CIRC_SIZE = 25
local MENU_CIRC_GAP  = 4
local MENU_CIRC_COLS = 3
local MENU_CIRC_ROWS = 3
local MENU_PAD_H     = 8
local MENU_PAD_V     = 8
local MENU_BW        = 2   -- border on left / right / bottom

-- Left/right padding inside each tab widget, symmetric around the icon.
local TAB_PAD_H = 22

-- Top/bottom padding inside each tab's content margin.
-- icon_size is derived as tb_h - 2 * TAB_CONTENT_V_PAD, so keep in sync.
local TAB_CONTENT_V_PAD = 1

-- Gap between the last tab and the "+" new-tab button.
local PLUS_BTN_GAP = 30

-- Gap between the "+" button and the dimmed tabs from other splits.
local REMOTE_TAB_GROUP_GAP = -2

-- Extra spacing added between tabs (on top of the shape overlap).
-- Sized so adjacent tab icons clear each other now that tabs are icon-only.
local TAB_GAP = 6

-- Vertical overlap between stacked icon pills in a horizontally-minimized
-- split (was coupled to TAB_GAP when tabs still had inline close buttons).
local PILL_STACK_GAP = 4

-- Corner radius for the focus-border widget on empty (no-tab) leaves.
-- Distinct from beautiful.splitwm_empty_radius (content background).
local EMPTY_SPLIT_RADIUS = 14

-- Icon size used for app-launcher widgets in empty splits.
local LAUNCHER_ICON_SIZE = 34

-- Minimum vertical movement (px) before a drag-handle drag activates.
local DRAG_THRESHOLD_PX = 4

local TITLEBAR_RESIZE_CURSOR = "sb_v_double_arrow"
local DEFAULT_CURSOR = "left_ptr"

-- Tab shape geometry. TAB_ALPHA is the slant angle from vertical.
local TAB_ALPHA  = math.rad(20)
local TAB_EAR    = 12
local TAB_CORNER = 9
local TAB_SA     = math.sin(TAB_ALPHA)
local TAB_CA     = math.cos(TAB_ALPHA)
local TAB_TA     = math.tan(TAB_ALPHA)
local function tab_cx(h)
    return (TAB_CORNER + TAB_EAR) * (1 - TAB_SA) / TAB_CA + h * TAB_TA
end

-- Overlap = 2x slant width at the actual titlebar height. Set by M.init().
local TAB_SPACING

function M.init()
    TAB_SPACING = -math.floor(
        (tab_cx(math.max(theme.TITLEBAR_HEIGHT, beautiful.splitwm_gap or 0))
            - TAB_EAR * TAB_CA) * 2)
end

-- Width of one tab slot: the tab widget plus the layout spacing to the next
-- tab (exact — widgets sit in a fixed.horizontal with that spacing).
local function tab_step(icon_size)
    return TAB_PAD_H + icon_size + TAB_PAD_H + TAB_SPACING + TAB_GAP
end

local function tab_slot_x(tab_idx, icon_size)
    return (tab_idx - 1) * tab_step(icon_size)
end

local function tab_content_bounds(tab_idx, icon_size)
    local x1 = tab_slot_x(tab_idx, icon_size) + TAB_PAD_H
    return x1, x1 + icon_size
end

local function tab_content_hit(x, tab_idx, icon_size)
    local x1, x2 = tab_content_bounds(tab_idx, icon_size)
    return x >= x1 and x < x2
end

local function tab_index_at(x, n_tabs, icon_size)
    if n_tabs <= 0 then return nil end
    for i = 1, n_tabs do
        if tab_content_hit(x, i, icon_size) then return i end
    end
    return nil
end

M.tab_index_at      = tab_index_at
M.TAB_CONTENT_V_PAD = TAB_CONTENT_V_PAD

---------------------------------------------------------------------------
-- Tab bar cache and color-menu state
---------------------------------------------------------------------------

local click_away = require("splitwm.click_away")

local tab_color_menu_state = { wb = nil, watcher = nil }
local local_tab_click_active = false

-- Per-event dedup flag: set for the duration of the event that closed a
-- menu, so multiple handlers in one event batch don't each re-trigger.
local menu_was_open_this_event = false

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
-- splitwm-table accessors (launchers and menu hooks set by rc.lua/menu.lua)
---------------------------------------------------------------------------

local function api() return core.splitwm or {} end

local function focus_leaf(t, leaf_id)
    local state = core.state(t)
    if core.leaf(state, leaf_id) then state.focused_leaf_id = leaf_id end
end

---------------------------------------------------------------------------
-- Flush caches (called from splitwm.flush_caches)
---------------------------------------------------------------------------

function M.flush_caches()
    for _, sc in pairs(core.tabbar) do
        for _, entry in pairs(sc) do
            for _, obj in ipairs(entry.tooltip_objs) do
                entry.tooltip:remove_from_object(obj)
            end
        end
    end
    -- Clear in-place so existing core.tabbar references stay valid.
    for k in pairs(core.tabbar) do core.tabbar[k] = nil end
end

---------------------------------------------------------------------------
-- Vertical drag helper (pill drag strip in the tab bar)
---------------------------------------------------------------------------

local function run_v_drag(s, get_b, on_start, on_stop)
    -- Capture start position before the delayed_call so it reflects the press.
    local start_y = mouse.coords().y
    local moved   = false
    -- Delay the grab until the current event batch is fully processed.
    gears.timer.delayed_call(function()
        if not mouse.coords().buttons[1] then return end
        if on_start then on_start() end
        mousegrabber.run(function(m)
            if not m.buttons[1] then
                if moved then awful.layout.arrange(s) end
                if on_stop then on_stop() end
                return false
            end
            if not moved and math.abs(m.y - start_y) < DRAG_THRESHOLD_PX then
                return true
            end
            moved = true
            local b = get_b()
            if not b then if on_stop then on_stop() end; return false end
            -- Resize the two neighbors of this gap; combined height constant.
            local igap = b.parent_gap or 0
            local rs = 0
            for _, r in ipairs(b.branch.ratios) do rs = rs + r end
            if rs <= 0 then rs = 1 end
            local abs_top   = b.branch.ratios[b.top_idx]     / rs * b.usable
            local abs_bot   = b.branch.ratios[b.top_idx + 1] / rs * b.usable
            local combined  = abs_top + abs_bot
            local min_h     = math.min(theme.MIN_SPLIT_H, combined / 2)
            local new_top   = math.max(min_h, math.min(combined - min_h,
                m.y - b.top_y - math.floor(igap / 2)))
            b.branch.ratios[b.top_idx]     = new_top / b.usable * rs
            b.branch.ratios[b.top_idx + 1] = (combined - new_top) / b.usable * rs
            awful.layout.arrange(s)
            return true
        end, "sb_v_double_arrow")
    end)
end

---------------------------------------------------------------------------
-- Widget helpers
---------------------------------------------------------------------------

local function make_launcher_widget(entry, size, callback)
    local inner
    if entry.icon then
        inner = wibox.widget {
            image         = entry.icon,
            forced_width  = size,
            forced_height = size,
            resize        = true,
            widget        = wibox.widget.imagebox,
        }
    else
        inner = wibox.widget {
            {
                text   = entry.label or "?",
                align  = "center",
                font   = "monospace bold " .. math.floor(size * 0.55) .. "px",
                widget = wibox.widget.textbox,
            },
            bg            = theme.color_btn_bg,
            shape         = gears.shape.circle,
            forced_width  = size,
            forced_height = size,
            widget        = wibox.container.background,
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
            left = 2, right = 2, top = 0, bottom = 0,
            widget = wibox.container.margin,
        },
        bg     = theme.color_transparent,
        fg     = theme.color_fg,
        widget = wibox.container.background,
    }
    w:connect_signal("mouse::enter", function() w.bg = theme.color_fg_hover end)
    w:connect_signal("mouse::leave", function() w.bg = theme.color_transparent end)
    w:buttons(gears.table.join(awful.button({}, 1, callback)))
    return w
end

local function make_circle_icon_btn_widget(draw_fn, size)
    local icon = wibox.widget.base.make_widget()
    function icon:draw(_, cr, w, h)
        local col = self._disabled and theme.color_fg_disabled
            or (self._dark and theme.color_bg or theme.color_fg)
        cr:set_source(gears.color(col))
        cr:set_line_width(2)
        cr:set_line_cap(CAIRO_LINE_CAP_ROUND)
        draw_fn(cr, w, h)
    end
    function icon:fit(_, w, h) return w, h end
    local w = wibox.widget {
        icon,
        bg            = theme.color_btn_bg,
        shape         = gears.shape.circle,
        forced_width  = size,
        forced_height = size,
        widget        = wibox.container.background,
    }
    w._icon = icon
    return w
end

---------------------------------------------------------------------------
-- Tab color picker popup menu
---------------------------------------------------------------------------

-- Border drawn on left/right/bottom only — the top edge meets the tab bar.
-- Shared by the color picker and the hover close popup.
local function make_side_border_widget()
    local w = wibox.widget.base.make_widget()
    function w:draw(_, cr, ww, hh)
        if not self._bpat then return end
        cr:set_source(self._bpat)
        cr:set_line_width(MENU_BW)
        local o = MENU_BW / 2
        cr:move_to(o, 0) cr:line_to(o, hh) cr:stroke()
        cr:move_to(ww - o, 0) cr:line_to(ww - o, hh) cr:stroke()
        cr:move_to(0, hh - o) cr:line_to(ww, hh - o) cr:stroke()
    end
    function w:fit(_, ww, hh) return ww, hh end
    return w
end

local function hide_tab_color_menu()
    local ms = tab_color_menu_state
    if not (ms.wb and ms.wb.visible) then return false end
    ms.wb.visible = false
    if ms.watcher then ms.watcher.stop() end
    return true
end

local function show_tab_color_menu(tc, s, tab_x, bar_bottom, bg_color, border_color, tab_w)
    local ms        = tab_color_menu_state
    local content_w = MENU_CIRC_COLS * MENU_CIRC_SIZE + (MENU_CIRC_COLS - 1) * MENU_CIRC_GAP
    local menu_w    = tab_w or (MENU_BW * 2 + MENU_PAD_H * 2 + content_w)
    local menu_h    = MENU_PAD_V * 2 + MENU_CIRC_ROWS * MENU_CIRC_SIZE
        + (MENU_CIRC_ROWS - 1) * MENU_CIRC_GAP + MENU_BW

    if not ms.wb then
        ms.wb = wibox { ontop = true, visible = false, border_width = 0 }
    end
    local wb = ms.wb
    wb.width  = menu_w
    wb.height = menu_h
    wb.bg     = bg_color

    -- Circle widgets are created once and reused; selection + handlers are
    -- refreshed each time the menu opens.
    local current = colors.get_client_color(tc)
    if not ms.circs then
        ms.circs = {}
        for i, col in ipairs(colors.COLORS) do
            local circ = wibox.widget {
                bg                 = col.light,
                shape              = gears.shape.circle,
                shape_border_color = theme.color_transparent,
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
        circ.shape_border_color = (current and current.name == col.name)
            and theme.color_fg or theme.color_transparent
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
        ms.border_w = make_side_border_widget()
    end
    ms.border_w._bpat = gears.color(border_color)
    ms.border_w:emit_signal("widget::redraw_needed")

    -- Grid layout and wb:setup are only rebuilt when menu width changes.
    if ms.last_menu_w ~= menu_w then
        ms.last_menu_w = menu_w
        local grid = { spacing = MENU_CIRC_GAP, layout = wibox.layout.fixed.vertical }
        for row = 0, MENU_CIRC_ROWS - 1 do
            local row_spec = {
                spacing = MENU_CIRC_GAP,
                layout = wibox.layout.fixed.horizontal,
            }
            for col = 1, MENU_CIRC_COLS do
                local idx = row * MENU_CIRC_COLS + col
                if ms.circs[idx] then table.insert(row_spec, ms.circs[idx]) end
            end
            table.insert(grid, wibox.widget(row_spec))
        end
        wb:setup {
            ms.border_w,
            {
                {
                    grid,
                    halign = "center", valign = "center",
                    widget = wibox.container.place,
                },
                left   = MENU_BW,
                right  = MENU_BW,
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

    if not ms.watcher then
        ms.watcher = click_away.new {
            visible = function() return ms.wb and ms.wb.visible end,
            inside  = function(m)
                local g = ms.wb:geometry()
                return m.x >= g.x and m.x < g.x + g.width
                    and m.y >= g.y and m.y < g.y + g.height
            end,
            dismiss = hide_tab_color_menu,
        }
    end
    ms.watcher.arm()
end

-- Closes the menu if open and returns true; returns false if already closed.
-- Deduplicates within a single event: multiple handlers firing for the same
-- click all check this, but only the first actually closes.
local function mark_menu_closed()
    menu_was_open_this_event = true
    gears.timer.delayed_call(function() menu_was_open_this_event = false end)
end

local function event_close_menu_if_open()
    local sw = api()
    if sw.menu_just_toggled and sw.menu_just_toggled() then return false end
    if menu_was_open_this_event then return true end
    if hide_tab_color_menu() then
        mark_menu_closed(); return true
    end
    if sw.on_menu_close and sw.on_menu_close() then
        mark_menu_closed(); return true
    end
    return false
end

---------------------------------------------------------------------------
-- Hover close popup — ✕ shown under the active tab, styled like the
-- color picker (client-colored bg, side/bottom border).
---------------------------------------------------------------------------

local close_popup = { wb = nil, client = nil, tab_rect = nil }

local function hide_close_popup()
    close_popup.client   = nil
    close_popup.tab_rect = nil
    if close_popup.wb then close_popup.wb.visible = false end
end

local function point_in(r, mx, my)
    return r and mx >= r.x and mx < r.x + r.width
        and my >= r.y and my < r.y + r.height
end

-- Hide once the cursor has left both the source tab and the popup. Checked
-- by position, not by enter/leave events: the tooltip appearing under the
-- cursor fires spurious leave events that would flicker the popup.
local function schedule_hide_close_popup()
    gears.timer.start_new(0.15, function()
        local cp = close_popup
        if not (cp.wb and cp.wb.visible) then return false end
        local m = mouse.coords()
        if point_in(cp.wb:geometry(), m.x, m.y) or point_in(cp.tab_rect, m.x, m.y) then
            schedule_hide_close_popup()
        else
            hide_close_popup()
        end
        return false
    end)
end

local function show_close_popup(tc, x, y, w, bg_color, border_color, tab_rect)
    local cp = close_popup
    if not cp.wb then
        cp.wb = wibox { ontop = true, visible = false, border_width = 0 }
        cp.border_w = make_side_border_widget()
        cp.label = wibox.widget {
            text   = "✕",
            align  = "center",
            valign = "center",
            font   = beautiful.splitwm_tab_btn_font or "monospace bold 24px",
            widget = wibox.widget.textbox,
        }
        cp.wb:setup {
            cp.border_w,
            {
                cp.label,
                -- Extra bottom inset: the box has a border below but not
                -- above, so plain centering reads visually low.
                left = MENU_BW, right = MENU_BW, bottom = MENU_BW + 4,
                widget = wibox.container.margin,
            },
            layout = wibox.layout.stack,
        }
        cp.wb:connect_signal("mouse::enter", function()
            cp.wb.cursor = "hand2"
        end)
        cp.wb:buttons(gears.table.join(awful.button({}, 1, function()
            local c = cp.client
            hide_close_popup()
            if c and c.valid then c:kill() end
        end)))
    end
    cp.client   = tc
    cp.tab_rect = tab_rect
    cp.border_w._bpat = gears.color(border_color)
    cp.border_w:emit_signal("widget::redraw_needed")
    cp.wb.bg = bg_color
    cp.wb.fg = theme.color_fg
    cp.wb.width   = w
    cp.wb.height  = theme.BTN_SIZE + MENU_BW
    cp.wb.x       = x
    cp.wb.y       = y
    cp.wb.visible = true
    schedule_hide_close_popup()
end

---------------------------------------------------------------------------
-- Tab bar helper functions
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
    local cache = core.tabbar[s]
    local entry = cache[leaf.id]
    if entry then return entry end
    entry = {
        wb = underlay.make_wb_proxy(underlay.get_or_create(s).chrome_layer, s),
        tooltip = awful.tooltip {
            text = "", delay_show = 0.3, font = "monospace bold 12px",
            bg = theme.color_bg, fg = theme.color_fg, border_width = 0,
        },
        tooltip_objs = {},
        tb_h         = nil,
    }
    cache[leaf.id] = entry
    return entry
end

-- Fingerprint check to prevent unneeded heavy redraws.
-- Tab names are excluded: tooltip text is set dynamically on mouse::enter.
local function append_tab_fingerprint(parts, tc, include_pickup)
    parts[#parts + 1] = tostring(tc.window)
    parts[#parts + 1] = tc.class or ""
    parts[#parts + 1] = tc.instance or ""
    if include_pickup and drag.pickup.tag == "client" and drag.pickup.client == tc then
        parts[#parts + 1] = "P"
    end
    local col = colors.get_client_color(tc)
    if col then parts[#parts + 1] = col.name end
end

local function tb_compute_all_tabs_fingerprint(leaves)
    local parts = {}
    for _, leaf in ipairs(leaves) do
        parts[#parts + 1] = tostring(leaf.id)
        for _, tc in ipairs(leaf.tabs) do
            append_tab_fingerprint(parts, tc, false)
        end
    end
    return table.concat(parts, "\0")
end

local function tb_compute_fingerprint(leaf, state, geo, all_tabs_fp)
    local parts = {
        leaf.active_tab,
        state.focused_leaf_id == leaf.id and 1 or 0,
        geo and geo.v_bound_above and "b" or "",
        leaf.minimized and "m" or "",
        leaf.min_anim and "a" or "",
        (drag.pickup.tag == "split" and drag.pickup.split_id == leaf.id) and "S" or "",
        geo and geo.width or 0,
        geo and geo.height or 0,
        all_tabs_fp,
    }
    for _, tc in ipairs(leaf.tabs) do append_tab_fingerprint(parts, tc, true) end
    return table.concat(parts, "\0")
end

local function tb_make_btn(widget_bc, draw_fn, size, callback)
    local w = make_circle_icon_btn_widget(draw_fn, size)
    w.shape_border_color = widget_bc
    if callback then
        w:buttons(gears.table.join(awful.button({}, 1, callback)))
    end
    w:connect_signal("mouse::enter", function()
        if not w._disabled then w.bg = theme.color_bg end
    end)
    w:connect_signal("mouse::leave", function()
        if not w._disabled then w.bg = theme.color_btn_bg end
    end)
    return w
end

-- tab_state: "active" | "inactive" | "picked"
local function get_tab_state(tab_idx, leaf, tc)
    if drag.pickup.tag == "client" and drag.pickup.client == tc then
        return "picked"
    elseif tab_idx == leaf.active_tab then
        return "active"
    end
    return "inactive"
end

local function make_tab_icon(tc, icon_size)
    return client_icons.client_icon_widget(tc, icon_size,
        colors.hue_rotated_icon_surface(tc, icon_size))
end

---------------------------------------------------------------------------
-- Shared tab visual
---------------------------------------------------------------------------

-- Builds the tab visual used by both local and remote tabs: shaped
-- background, app icon, close-button slot, and tooltip wiring.
-- tab_state: "active" | "inactive" | "picked" | "remote".
local function build_tab_visual(tc, entry, ctx, tab_state)
    local client_color = colors.get_client_color(tc)
    local tab_bg = tab_state == "picked" and theme.color_fg
        or (client_color and client_color.dark)
        or (tab_state == "active" and theme.color_bg)
        or theme.color_btn_bg
    local tab_bg_pat    = gears.color(tab_bg)
    local widget_bc_pat = gears.color(ctx.widget_bc)
    local outlined = tab_state == "active" or tab_state == "picked"

    local tab_draw = wibox.widget.base.make_widget()
    function tab_draw:draw(_, cr, w2, h2)
        local h = h2 - 1  -- 1px room at top so the border stroke isn't clipped
        cr:translate(0, 1)
        if ctx.simple_tabs and tab_state ~= "remote" then
            local r = math.floor(h / 4)
            local sw = w2 - 2 * (TAB_EAR + 4)
            cr:translate(TAB_EAR + 4, 0)
            gears.shape.rounded_rect(cr, sw, h, r)
            cr:set_source(tab_bg_pat)
            cr:fill()
            if outlined then
                gears.shape.rounded_rect(cr, sw, h, r)
                cr:set_source(tab_state == "picked"
                    and gears.color(theme.color_fg) or widget_bc_pat)
                cr:set_line_width(2)
                cr:stroke()
            end
        else
            tab_path(cr, w2, h)
            cr:close_path()
            cr:set_source(tab_bg_pat)
            cr:fill()
            if outlined then
                tab_path(cr, w2, h)
                cr:set_source(tab_state == "picked"
                    and gears.color(theme.color_fg) or widget_bc_pat)
                cr:set_line_width(2)
                cr:stroke()
            end
        end
    end
    function tab_draw:fit(_, _, _) return 0, 0 end

    local icon_widget = wibox.widget {
        make_tab_icon(tc, ctx.icon_size),
        halign = "center",
        valign = "center",
        widget = wibox.container.place,
    }

    local tab_widget = wibox.widget {
        tab_draw,
        {
            icon_widget,
            left = TAB_PAD_H, right = TAB_PAD_H,
            top = TAB_CONTENT_V_PAD, bottom = TAB_CONTENT_V_PAD,
            widget = wibox.container.margin,
        },
        layout = wibox.layout.stack,
    }

    tab_widget:connect_signal("mouse::enter", function()
        entry.tooltip.text = (tc.valid and tc.name) or "?"
    end)
    entry.tooltip:add_to_object(tab_widget)
    table.insert(entry.tooltip_objs, tab_widget)
    return tab_widget
end

local function tb_build_remote_tab_widget(tc, entry, ctx, on_click)
    local tab_widget = build_tab_visual(tc, entry, ctx, "remote")
    if on_click then
        tab_widget:buttons(gears.table.join(awful.button({}, 1, on_click)))
    end
    return tab_widget
end

---------------------------------------------------------------------------
-- Build the widget for a single tab
---------------------------------------------------------------------------

local function tb_build_tab_widget(leaf, tc, tab_idx, entry, ctx)
    local tab_state = get_tab_state(tab_idx, leaf, tc)
    local gap       = theme.gap()

    local function in_tab_content(mx, my, g)
        local sx = ctx.state.scroll_x or 0
        return tab_content_hit(mx - (g.x - sx), tab_idx, ctx.icon_size)
            and my >= g.y - gap
            and my < g.y - gap + ctx.tb_h
    end

    -- Activate focus on tc (no-op if client is no longer valid).
    local function focus_tc()
        if not tc.valid then return end
        ops.activate_client_in_leaf(ctx.t, leaf.id, tc, { screen = ctx.s })
    end

    -- Button released with this tab picked up: drop, kill, or reorder.
    -- Dropping a tab onto its own slot is a self-swap, which focuses it —
    -- so a plain click is just the degenerate case of a drag.
    local function settle(m)
        local mx, my = m.x, m.y
        local sx     = ctx.state.scroll_x or 0
        local cached = core.geo[ctx.t]
        if cached then
            for _, drop_leaf in ipairs(tree.collect_leaves(ctx.state.root)) do
                local lid = drop_leaf.id
                local g = cached.geos[lid]
                local gx = g and g.x - sx
                if g and mx >= gx and mx < gx + g.width
                        and my >= g.y - gap and my < g.y + g.height then
                    if lid ~= leaf.id then
                        ops.try_drop_picked_up(ctx.t, lid)
                        awful.layout.arrange(ctx.s)
                    elseif my < g.y then
                        -- Same leaf, in tab bar: reorder tabs by drop position.
                        local target = tab_index_at(mx - gx, #leaf.tabs, ctx.icon_size)
                        if not target then
                            core.drop_pickup()
                            awful.layout.arrange(ctx.s)
                            return false
                        end
                        core.drop_pickup()
                        if not ops.swap_client_to_tab_index(ctx.t, leaf.id, tc,
                                target, { screen = ctx.s }) then
                            awful.layout.arrange(ctx.s)
                            focus_tc()
                        end
                    else
                        -- Same leaf, client area: a drop here is a no-op move.
                        core.drop_pickup()
                        awful.layout.arrange(ctx.s)
                        focus_tc()
                    end
                    return false
                end
            end
        end
        -- Released in a gap (between splits or at edges): new split there.
        if cached then
            local leaves = tree.collect_leaves(ctx.state.root)
            local best_lid, direction, new_first =
                tree.find_gap_drop_target(leaves, cached.geos, sx, mx, my, gap)
            if best_lid and ops.drop_into_new_split(ctx.t, best_lid, direction, new_first) then
                awful.layout.arrange(ctx.s)
            end
        end
        return false
    end

    -- Mousegrabber callback while this tab is held. The picked visual is
    -- only painted once the cursor leaves the tab, so plain clicks don't
    -- flash the drag style.
    local shown_picked = false
    local function drag_release_fn(m)
        if m.buttons[1] then
            if not shown_picked then
                local g = core.geo[ctx.t] and core.geo[ctx.t].geos[leaf.id]
                if g and not in_tab_content(m.x, m.y, g) then
                    shown_picked = true
                    awful.layout.arrange(ctx.s)
                end
            end
            return true
        end
        if drag.pickup.tag == "client" and not drag.pickup.client.valid then
            core.drop_pickup(); awful.layout.arrange(ctx.s); return false
        end
        if drag.pickup.tag == "client" then return settle(m) end
        return false
    end

    -- Begin a tab drag: pick up immediately, grab after the event batch.
    local function start_tab_drag()
        hide_close_popup()
        drag.pickup  = core.pickup_client(tc)
        shown_picked = false
        gears.timer.delayed_call(function()
            if drag.pickup.tag ~= "client" or drag.pickup.client ~= tc then return end
            if not mouse.coords().buttons[1] then
                -- Released within the same event batch: settle as a click.
                settle(mouse.coords())
                return
            end
            if mousegrabber.isrunning() then return end
            mousegrabber.run(drag_release_fn, "fleur")
        end)
    end

    local tab_widget = build_tab_visual(tc, entry, ctx, tab_state)

    -- The ✕ lives in a hover popup under the active tab (no inline button).
    tab_widget:connect_signal("mouse::enter", function()
        if tab_state ~= "active" or drag.pickup.tag ~= "idle" then return end
        if close_popup.client == tc and close_popup.wb and close_popup.wb.visible then
            return
        end
        local g = core.geo[ctx.t] and core.geo[ctx.t].geos[leaf.id]
        if not g or leaf.minimized then return end
        -- Full tab width, not just the icon.
        local tab_w = ctx.icon_size + 2 * TAB_PAD_H
        local x = g.x - (ctx.state.scroll_x or 0) + tab_slot_x(tab_idx, ctx.icon_size)
        local bar_top = g.y - gap
        local cc = colors.get_client_color(tc)
        show_close_popup(tc, x, bar_top + ctx.tb_h, tab_w,
            cc and cc.dark or theme.color_bg,
            cc and cc.light or theme.color_fg,
            { x = x, y = bar_top, width = tab_w, height = ctx.tb_h })
    end)

    tab_widget:buttons(gears.table.join(
        awful.button({}, 1, function()
            local mc = mouse.coords()
            local g = core.geo[ctx.t] and core.geo[ctx.t].geos[leaf.id]
            if not (g and in_tab_content(mc.x, mc.y, g)) then return end
            local_tab_click_active = true
            gears.timer.delayed_call(function() local_tab_click_active = false end)
            if drag.pickup.tag == "split" and drag.pickup.split_id ~= leaf.id then
                ops.handle_split_pickup(ctx.state, leaf.id, ctx.s); return
            end
            if drag.pickup.tag == "client" and drag.pickup.client.valid
                    and drag.pickup.client ~= tc then
                ops.try_drop_picked_up(ctx.t, leaf.id)
                awful.layout.arrange(ctx.s)
                return
            end
            start_tab_drag()
        end),
        awful.button({}, 3, function()
            if not tc.valid then return end
            local mc = mouse.coords()
            local g = core.geo[ctx.t] and core.geo[ctx.t].geos[leaf.id]
            if not (g and in_tab_content(mc.x, mc.y, g)) then return end
            local_tab_click_active = true
            gears.timer.delayed_call(function() local_tab_click_active = false end)
            local sw = api()
            if sw.on_menu_close then sw.on_menu_close() end
            hide_close_popup()
            if tab_color_menu_state.wb and tab_color_menu_state.wb.visible then
                hide_tab_color_menu(); return
            end
            local tab_x = g.x - (ctx.state.scroll_x or 0)
                + select(1, tab_content_bounds(tab_idx, ctx.icon_size))
            local bar_bottom = g.y - gap + ctx.tb_h
            local cc = colors.get_client_color(tc)
            show_tab_color_menu(tc, ctx.s, tab_x, bar_bottom,
                cc and cc.dark or theme.color_bg,
                cc and cc.light or theme.color_fg)
        end)
    ))

    return tab_widget
end

---------------------------------------------------------------------------
-- Build the right-side split control buttons (minimize, swap, split, close)
---------------------------------------------------------------------------

local function tb_build_split_controls(leaf, entry, ctx)
    local gap = theme.gap()
    local geo = ctx.geo
    local parent = tree.find_parent(ctx.state.root, leaf)
    local can_vsplit = geo and geo.width  >= 2 * theme.MIN_SPLIT_W + gap
    local can_hsplit = geo and geo.height >= 2 * theme.MIN_SPLIT_H + gap

    local function make_btn(draw_fn, callback, disabled)
        return tb_make_btn(ctx.widget_bc, draw_fn, theme.BTN_SIZE,
            not disabled and callback)
    end

    local cb    = ops.split_action_callbacks(ctx.state, leaf.id, ctx.t, ctx.s)
    local wider = geo and geo.width >= geo.height
    local auto_icon   = wider and icons.vsplit or icons.hsplit
    local auto_cb     = wider and (can_vsplit and cb.vsplit or nil)
                              or (can_hsplit and cb.hsplit or nil)
    local auto_cb_opp = wider and (can_hsplit and cb.hsplit or nil)
                              or (can_vsplit and cb.vsplit or nil)
    local can_split = wider and can_vsplit or can_hsplit
    local split_btn = make_btn(auto_icon, auto_cb, not can_split)
    if auto_cb_opp then
        split_btn:buttons(gears.table.join(
            split_btn:buttons(),
            awful.button({}, 3, auto_cb_opp)
        ))
    end
    local close_split_btn = make_btn(icons.close, cb.close, not parent)

    if not can_split then set_btn_disabled(split_btn, entry.wb) end
    if parent then
        on_hover_fg(close_split_btn, theme.color_close, theme.color_fg)
    else
        set_btn_disabled(close_split_btn, entry.wb)
    end

    -- Minimize / expand button (disabled when leaf has no parent).
    local parent_dir = parent and parent.direction
    local min_icon
    if leaf.minimized then
        min_icon = (parent_dir == tree.DIR_V) and icons.expand_v or icons.expand_h
    else
        min_icon = (parent_dir == tree.DIR_V) and icons.minimize_v or icons.minimize_h
    end
    local minimize_btn = make_btn(min_icon, parent and cb.minimize_toggle or nil, not parent)
    if not parent then set_btn_disabled(minimize_btn, entry.wb) end

    local is_split_picked = drag.pickup.tag == "split" and drag.pickup.split_id == leaf.id
    local swap_btn = make_circle_icon_btn_widget(icons.swap, theme.BTN_SIZE)
    swap_btn.shape_border_color = ctx.widget_bc
    if is_split_picked then swap_btn.bg = theme.color_fg; swap_btn._icon._dark = true end
    entry.swap_btn        = swap_btn
    entry.swap_btn_picked = is_split_picked
    swap_btn:connect_signal("mouse::enter", function()
        if not entry.swap_btn_picked then swap_btn.bg = theme.color_bg end
    end)
    swap_btn:connect_signal("mouse::leave", function()
        swap_btn.bg = entry.swap_btn_picked and theme.color_fg or theme.color_btn_bg
        if swap_btn._icon then
            swap_btn._icon._dark = entry.swap_btn_picked
            swap_btn._icon:emit_signal("widget::redraw_needed")
        end
    end)
    swap_btn:buttons(gears.table.join(awful.button({}, 1, function()
        if drag.pickup.tag == "split" and drag.pickup.split_id ~= leaf.id then
            ops.handle_split_pickup(ctx.state, leaf.id, ctx.s); return
        elseif drag.pickup.tag ~= "idle" then
            -- Picked-up own split or a client: cancel the pickup.
            core.drop_pickup()
        else
            drag.pickup = core.pickup_split(leaf.id)
            focus_leaf(ctx.t, leaf.id)
        end
        awful.layout.arrange(ctx.s)
    end)))

    return {
        minimize = minimize_btn,
        split    = split_btn,
        close    = close_split_btn,
        swap     = swap_btn,
    }
end

---------------------------------------------------------------------------
-- Focus border drawn around the client area
---------------------------------------------------------------------------

local function tb_build_border_widget(border_color, tb_h, bw, radius)
    local w = wibox.widget.base.make_widget()
    w._bc   = border_color
    w._tb_h = tb_h
    w._bw   = bw
    function w:draw(_, cr, width, height)
        if not self._bc then return end
        cr:set_source(gears.color(self._bc))
        cr:set_line_width(self._bw)
        local half = self._bw / 2
        local x    = half
        local y    = self._tb_h - half
        local wd   = width - self._bw
        local h    = height - self._tb_h
        local r    = radius or beautiful.splitwm_border_radius
        cr:new_sub_path()
        cr:arc(x + wd - r, y + r,     r, -math.pi / 2, 0)
        cr:arc(x + wd - r, y + h - r, r, 0,            math.pi / 2)
        cr:arc(x + r,      y + h - r, r, math.pi / 2,  math.pi)
        cr:arc(x + r,      y + r,     r, math.pi,      3 * math.pi / 2)
        cr:close_path()
        cr:stroke()
    end
    function w:fit(_, wd, h) return wd, h end
    return w
end

---------------------------------------------------------------------------
-- Split tab widgets into two layers
---------------------------------------------------------------------------

-- The active tab and widgets after index n_tabs (i.e. the "+" button) float
-- above the border widget; inactive tabs stay behind it. Spacers preserve
-- layout width in each layer.
--
-- Spacers are pooled on `entry` so make_widget() is only called when the tab
-- count grows beyond its previous maximum, not on every fingerprint change.
local function tb_split_tab_layers(tab_widgets, active_tab, n_tabs, entry)
    if not entry._spacers then entry._spacers = {} end
    local pool = entry._spacers
    while #pool < #tab_widgets do
        local sp = wibox.widget.base.make_widget()
        function sp:fit(wctx, w, h) return self._ref:fit(wctx, w, h) end
        function sp:draw() end
        pool[#pool + 1] = sp
    end
    local behind, above = {}, {}
    for i, tw in ipairs(tab_widgets) do
        local sp = pool[i]
        sp._ref = tw
        if i == active_tab or i > n_tabs then
            table.insert(behind, sp)
            table.insert(above, tw)
        else
            table.insert(behind, tw)
            table.insert(above, sp)
        end
    end
    return behind, above
end

---------------------------------------------------------------------------
-- Assemble bar layer
---------------------------------------------------------------------------

local function tb_build_bar_layer(behind, controls, drag_pill, ctx)
    local tab_spacing = #behind > 1 and (TAB_SPACING + TAB_GAP) or 0
    local tabs = {
        spacing = tab_spacing,
        layout = wibox.layout.fixed.horizontal,
        table.unpack(behind),
    }
    local ctrl_cover = {
        {
            {
                {
                    controls.minimize, controls.swap, controls.split, controls.close,
                    spacing = theme.BTN_SPACING,
                    layout = wibox.layout.fixed.horizontal,
                },
                widget = wibox.container.margin,
            },
            bg = ctx.bar_bg, widget = wibox.container.background,
        },
        bottom = BTN_V_RAISE, widget = wibox.container.margin,
    }
    local bar_content
    if drag_pill then
        bar_content = {
            tabs, drag_pill, ctrl_cover,
            layout = wibox.layout.align.horizontal,
        }
    else
        bar_content = {
            tabs,
            { ctrl_cover, halign = "right", widget = wibox.container.place },
            layout = wibox.layout.stack,
        }
    end
    return {
        {
            { bar_content, top = ctx.top_pad, widget = wibox.container.margin },
            bg = ctx.bar_bg, forced_height = ctx.tb_bar_h,
            widget = wibox.container.background,
        },
        layout = wibox.layout.fixed.vertical,
    }
end

---------------------------------------------------------------------------
-- Assemble the three-layer wibox layout for a leaf's tab bar
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
                        {
                            spacing = TAB_SPACING + TAB_GAP,
                            layout = wibox.layout.fixed.horizontal,
                            table.unpack(above),
                        },
                        right = theme.MIN_SPLIT_W, widget = wibox.container.margin,
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
-- Assemble the wibox for an empty leaf (launcher grid)
---------------------------------------------------------------------------

local function tb_assemble_empty_leaf(entry, bar_widgets, controls, border_draw, middle_drag, launcher_ws, ctx)
    local row1, row2 = {}, {}
    local mid = math.ceil(#launcher_ws / 2)
    for i, w in ipairs(launcher_ws) do
        if i <= mid then table.insert(row1, w) else table.insert(row2, w) end
    end
    local icon_grid
    if #row2 > 0 then
        icon_grid = {
            {
                spacing = theme.BTN_SPACING,
                layout = wibox.layout.fixed.horizontal,
                table.unpack(row1),
            },
            {
                spacing = theme.BTN_SPACING,
                layout = wibox.layout.fixed.horizontal,
                table.unpack(row2),
            },
            spacing = theme.BTN_SPACING, layout = wibox.layout.fixed.vertical,
        }
    else
        icon_grid = {
            spacing = theme.BTN_SPACING,
            layout = wibox.layout.fixed.horizontal,
            table.unpack(launcher_ws),
        }
    end
    local corner_r = beautiful.splitwm_empty_radius
    local bw       = theme.focus_border_width()
    entry.wb:setup {
        -- Layer 1: content background
        {
            { forced_height = ctx.tb_bar_h, widget = wibox.container.background },
            {
                {
                    {
                        {
                            icon_grid,
                            halign = "center", valign = "center",
                            widget = wibox.container.place,
                        },
                        widget = wibox.container.background,
                    },
                    bg    = theme.color_btn_bg,
                    shape = function(cr, w, h)
                        gears.shape.rounded_rect(cr, w, h, corner_r)
                    end,
                    widget = wibox.container.background,
                },
                left = bw, right = bw, bottom = bw, widget = wibox.container.margin,
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
-- Main tab bar update
---------------------------------------------------------------------------

local function update_leaf(s, t, state, geos, leaves, leaf, all_tabs_fp)
    local geo = geos[leaf.id]
    if not geo then return end

    local gap  = theme.gap()
    local tb_h = theme.tb_h(gap)
    local bw   = theme.focus_border_width()

    local entry = tb_get_or_create_entry(s, leaf)
    entry.tb_h  = tb_h
    local wb    = entry.wb
    local scroll_x = state.scroll_x or 0
    local wa = s.workarea
    local vis_x = geo.x - scroll_x
    local off_screen = vis_x + geo.width <= wa.x or vis_x >= wa.x + wa.width
    wb.visible = not off_screen
    if not off_screen and not anim.is_active(s) then
        wb.x      = vis_x
        wb.y      = geo.y - gap
        wb.width  = geo.width
        wb.height = geo.height + gap
    end

    local fp = tb_compute_fingerprint(leaf, state, geo, all_tabs_fp)
    if entry.fp == fp then return end
    entry.fp = fp

    local is_focused    = state.focused_leaf_id == leaf.id
    local active_client = leaf.tabs[leaf.active_tab]
    local active_picked = drag.pickup.tag == "client"
        and drag.pickup.client == active_client
    local active_color = active_client and colors.get_client_color(active_client)
    local focus_color  = active_picked and theme.color_fg
        or (active_color and active_color.light)
        or theme.color_fg
    local par_for_min = tree.find_parent(state.root, leaf)
    local par_dir_min = par_for_min and par_for_min.direction
    local ctx = {
        s            = s,
        t            = t,
        state        = state,
        geo          = geo,
        widget_bc    = is_focused and focus_color or theme.color_transparent,
        bar_bg       = theme.color_transparent,
        top_pad      = math.max(gap, theme.TITLEBAR_HEIGHT) - theme.TITLEBAR_HEIGHT,
        tb_h         = tb_h,
        tb_bar_h     = tb_h,
        icon_size    = tb_h - 2 * TAB_CONTENT_V_PAD,
        simple_tabs  = leaf.minimized and not leaf.min_anim
            and par_dir_min ~= tree.DIR_H,
    }

    -- Detach tooltip from previous tab widgets before rebuilding.
    entry.tooltip:hide()
    for _, obj in ipairs(entry.tooltip_objs) do
        entry.tooltip:remove_from_object(obj)
    end
    entry.tooltip_objs = {}

    -- Build per-tab widgets.
    local tab_widgets = {}
    for i, tc in ipairs(leaf.tabs) do
        table.insert(tab_widgets, tb_build_tab_widget(leaf, tc, i, entry, ctx))
    end

    -- "+" and remote tabs live after local tabs; tb_split_tab_layers keeps
    -- them in the floating layer.
    table.insert(tab_widgets, wibox.widget {
        tb_make_btn(ctx.widget_bc, icons.plus, theme.BTN_SIZE, function()
            pcall(function() mousegrabber.stop() end)
            focus_leaf(ctx.t, leaf.id)
            local sw = api()
            if sw.on_menu_request then sw.on_menu_request() end
        end),
        left = #leaf.tabs > 0 and PLUS_BTN_GAP or 0,
        bottom = BTN_V_RAISE,
        widget = wibox.container.margin,
    })

    local remote_widgets = {}
    local pending_remote_click = nil
    local function queue_remote_click(remote_idx, remote_client)
        if local_tab_click_active then return end
        if not remote_client.valid then return end
        if pending_remote_click then
            if remote_idx > pending_remote_click.idx then
                pending_remote_click.idx = remote_idx
                pending_remote_click.client = remote_client
            end
            return
        end
        pending_remote_click = { idx = remote_idx, client = remote_client }
        gears.timer.delayed_call(function()
            local item = pending_remote_click
            pending_remote_click = nil
            if not (item and item.client and item.client.valid) then return end
            ops.move_client_to_leaf_id(ctx.t, leaf.id, item.client, { screen = ctx.s })
        end)
    end

    for _, other_leaf in ipairs(leaves) do
        if other_leaf.id ~= leaf.id then
            for _, tc in ipairs(other_leaf.tabs) do
                local remote_client = tc
                local remote_idx = #remote_widgets + 1
                remote_widgets[remote_idx] =
                    tb_build_remote_tab_widget(remote_client, entry, ctx, function()
                        queue_remote_click(remote_idx, remote_client)
                    end)
            end
        end
    end
    if #remote_widgets > 0 then
        local top_spacing = TAB_SPACING + TAB_GAP
        local remote_left = REMOTE_TAB_GROUP_GAP + math.max(0, -(TAB_SPACING + TAB_GAP))
        local remote_row = wibox.widget {
            spacing = top_spacing,
            layout  = wibox.layout.fixed.horizontal,
            table.unpack(remote_widgets),
        }
        remote_row.opacity = 0.5
        remote_row:connect_signal("mouse::enter", function() remote_row.opacity = 1.0 end)
        remote_row:connect_signal("mouse::leave", function() remote_row.opacity = 0.5 end)
        table.insert(tab_widgets, wibox.widget {
            remote_row,
            left = remote_left,
            widget = wibox.container.margin,
        })
    end

    local controls = tb_build_split_controls(leaf, entry, ctx)

    local border_draw = #leaf.tabs == 0
        and tb_build_border_widget(is_focused and theme.color_fg or nil,
            tb_h, bw, EMPTY_SPLIT_RADIUS)
        or tb_build_border_widget(is_focused and focus_color or nil,
            tb_h, bw, nil)

    local drag_pill
    if geo.v_bound_above then
        local v_bound_above = geo.v_bound_above
        local pill_bg = wibox.widget {
            bg     = entry.pill_dragging and theme.color_fg or theme.color_transparent,
            shape  = function(cr, w, h)
                gears.shape.rounded_rect(cr, w, h, math.floor(h / 2))
            end,
            widget = wibox.container.background,
        }
        entry.pill_bg = pill_bg
        drag_pill = wibox.widget {
            {
                pill_bg,
                bottom = BTN_V_RAISE, left = 4, right = 4,
                widget = wibox.container.margin,
            },
            bg     = theme.color_transparent,
            cursor = TITLEBAR_RESIZE_CURSOR,
            widget = wibox.container.background,
        }
        drag_pill:connect_signal("mouse::enter", function()
            entry.wb.cursor = TITLEBAR_RESIZE_CURSOR
            if not entry.pill_dragging then entry.pill_bg.bg = theme.color_handle end
        end)
        drag_pill:connect_signal("mouse::leave", function()
            entry.wb.cursor = DEFAULT_CURSOR
            if not entry.pill_dragging then entry.pill_bg.bg = theme.color_transparent end
        end)
        drag_pill:buttons(gears.table.join(awful.button({}, 1, function()
            if event_close_menu_if_open() then return end
            run_v_drag(s, function() return v_bound_above end,
                function()
                    entry.pill_dragging = true
                    entry.pill_bg.bg = theme.color_fg
                    entry.wb.cursor = TITLEBAR_RESIZE_CURSOR
                end,
                function()
                    entry.pill_dragging = false
                    entry.pill_bg.bg = theme.color_transparent
                    entry.wb.cursor = DEFAULT_CURSOR
                end)
        end)))
    end

    local function set_leaf_wb_buttons()
        entry.wb:buttons(gears.table.join(awful.button({}, 1, function()
            if drag.pickup.tag == "split" then
                ops.handle_split_pickup(ctx.state, leaf.id, ctx.s); return
            end
            if drag.pickup.tag == "client" then
                ops.try_drop_picked_up(ctx.t, leaf.id)
                awful.layout.arrange(ctx.s)
                return
            end
            if event_close_menu_if_open() then return end
            focus_leaf(ctx.t, leaf.id)
            awful.layout.arrange(ctx.s)
        end)))
    end

    if leaf.minimized and par_dir_min == tree.DIR_H and not leaf.min_anim then
        -- Horizontal squeeze: vertical pill of tab icons.
        local function build_h_min_tab_icon(tc, i)
            local icon_sz = ctx.icon_size - 2
            local tstate = get_tab_state(i, leaf, tc)
            local client_color = colors.get_client_color(tc)
            local tab_bg = (client_color and client_color.dark)
                or (tstate == "active" and theme.color_bg)
                or theme.color_btn_bg
            local pill_sz = icon_sz + 2
            local r       = math.floor(pill_sz / 2)
            return wibox.widget {
                {
                    make_tab_icon(tc, icon_sz),
                    halign = "center", valign = "center",
                    widget = wibox.container.place,
                },
                bg            = tab_bg,
                shape         = function(cr, w, h)
                    gears.shape.rounded_rect(cr, w, h, r)
                end,
                forced_width  = pill_sz,
                forced_height = pill_sz,
                widget        = wibox.container.background,
            }
        end

        local pill_contents = {}
        for i, tc in ipairs(leaf.tabs) do
            pill_contents[#pill_contents + 1] = build_h_min_tab_icon(tc, i)
        end

        local vstack = {
            spacing = PILL_STACK_GAP,
            layout = wibox.layout.fixed.vertical,
            table.unpack(pill_contents),
        }
        entry.wb:setup {
            {
                {
                    {
                        controls.minimize,
                        halign = "center", valign = "center",
                        widget = wibox.container.place,
                    },
                    top = ctx.top_pad, widget = wibox.container.margin,
                },
                bg            = ctx.bar_bg,
                forced_height = ctx.tb_h,
                widget        = wibox.container.background,
            },
            {
                {
                    {
                        {
                            vstack,
                            halign = "center", valign = "top",
                            widget = wibox.container.place,
                        },
                        left = 4, right = 4, top = 4, bottom = 4,
                        widget = wibox.container.margin,
                    },
                    bg     = theme.color_btn_bg,
                    shape  = function(cr, w, h)
                        gears.shape.rounded_rect(cr, w, h, math.min(w, h) / 2)
                    end,
                    widget = wibox.container.background,
                },
                left = 4, right = 4, top = 4, bottom = 4,
                widget = wibox.container.margin,
            },
            layout = wibox.layout.align.vertical,
        }
        set_leaf_wb_buttons()
    elseif leaf.minimized and not leaf.min_anim then
        -- Vertical squeeze: only the tab bar, no border or content overlay.
        entry.wb:setup(tb_build_bar_layer(tab_widgets, controls, drag_pill, ctx))
        set_leaf_wb_buttons()
    elseif #leaf.tabs == 0 then
        local running_classes = {}
        for _, c in ipairs(client.get()) do
            if c.class then running_classes[c.class:lower()] = true end
        end
        local function launcher_hidden(e)
            for _, cls in ipairs(e.hide_if_class or {}) do
                if running_classes[cls:lower()] then return true end
            end
            return false
        end
        local launcher_ws = {}
        for _, e in ipairs(api().launchers or {}) do
            if not launcher_hidden(e) then
                launcher_ws[#launcher_ws + 1] = make_launcher_widget(e,
                    LAUNCHER_ICON_SIZE, function()
                        if e.action then
                            ops.expect_next_client({ tag = ctx.t, leaf_id = leaf.id })
                            e.action()
                        elseif e.cmd then
                            ops.expect_next_client({ tag = ctx.t, leaf_id = leaf.id })
                            awful.spawn(e.cmd)
                        end
                    end)
            end
        end
        tb_assemble_empty_leaf(entry, tab_widgets, controls, border_draw,
            drag_pill, launcher_ws, ctx)
        set_leaf_wb_buttons()
    else
        entry.wb:buttons(gears.table.join())
        local behind, above = tb_split_tab_layers(tab_widgets, leaf.active_tab,
            #leaf.tabs, entry)
        tb_assemble_wibox(entry, behind, above, controls, border_draw, drag_pill, ctx)
    end
end

function M.update(s, t, state, geos, leaves)
    if not core.tabbar[s] then core.tabbar[s] = {} end

    if close_popup.client and not close_popup.client.valid then
        hide_close_popup()
    end

    local all_tabs_fp = tb_compute_all_tabs_fingerprint(leaves)
    local alive = {}
    for _, leaf in ipairs(leaves) do
        alive[leaf.id] = true
        update_leaf(s, t, state, geos, leaves, leaf, all_tabs_fp)
    end

    -- Hide and clean up entries for dead leaves.
    local dead = {}
    for leaf_id in pairs(core.tabbar[s]) do
        if not alive[leaf_id] then dead[#dead + 1] = leaf_id end
    end
    for _, leaf_id in ipairs(dead) do
        core.tabbar[s][leaf_id].wb.visible = false
        core.tabbar[s][leaf_id] = nil
    end
end

return M
