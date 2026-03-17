---------------------------------------------------------------------------
-- splitwm: A terminal-multiplexer-style layout for AwesomeWM
--
-- Splits are persistent containers arranged in a binary tree.
-- Each split has a tab stack. Windows are pinned to splits.
-- Splits persist even when empty.
---------------------------------------------------------------------------

local awful     = require("awful")
local gears     = require("gears")
local wibox     = require("wibox")
local beautiful = require("beautiful")
local icons     = require("splitwm.icons")
local tree      = require("splitwm.tree")
local colors    = require("splitwm.colors")

local splitwm = {}

-- Color constants read from theme (mandatory — no fallbacks)
local color_bg             -- pure black
local color_fg             -- pure white
local color_fg_disabled    -- dimmed foreground for disabled icons
local color_close          -- close-button hover
local color_icon           -- launcher icon foreground
local color_btn_bg         -- transparent circle button bg
local color_transparent    -- fully transparent
local color_fg_hover       -- hover highlight
local color_fg        -- drag/active highlight

-- Base height of the tab bar.
local TITLEBAR_HEIGHT = 30

-- Button geometry — used to derive split minimum sizes.
local BTN_SIZE     = 26
local BTN_SPACING  = 5
-- Bottom padding applied to round buttons so they sit 2px above center (raise = padding / 2).
local BTN_V_RAISE  = 4
local N_SPLIT_BTNS = 5  -- swap + vsplit + hsplit + close + "+"
local MIN_SPLIT_W  = N_SPLIT_BTNS * BTN_SIZE + (N_SPLIT_BTNS - 1) * BTN_SPACING
local MIN_SPLIT_H  = TITLEBAR_HEIGHT

-- Tab shape geometry. TAB_ALPHA is the slant angle from vertical.
-- The ear arc sweeps from pi/2 down to TAB_ALPHA so its tangent matches the slant,
-- and the top corner arc starts at pi+TAB_ALPHA for the same reason.
-- Corner center: cx = (TAB_CORNER + TAB_EAR)*(1-sin α)/cos α + h*tan α
local TAB_ALPHA  = math.rad(20)
local TAB_EAR    = 11
local TAB_CORNER = 8
local TAB_SA     = math.sin(TAB_ALPHA)
local TAB_CA     = math.cos(TAB_ALPHA)
local TAB_TA     = math.tan(TAB_ALPHA)
local function tab_cx(h) return (TAB_CORNER + TAB_EAR) * (1 - TAB_SA) / TAB_CA + h * TAB_TA end
-- Overlap = 2x slant width for tighter nesting. Using TITLEBAR_HEIGHT as reference.
local TAB_SPACING = -math.floor((tab_cx(TITLEBAR_HEIGHT) - TAB_EAR * TAB_CA) * 2)

-- Shape function exported so rc.lua wibar capsules can match the tab profile.
function splitwm.tab_shape(cr, w, h)
    local cx = tab_cx(h)
    cr:move_to(0, h)
    cr:arc_negative(0,     h - TAB_EAR, TAB_EAR, math.pi / 2,             TAB_ALPHA)
    cr:line_to(cx - TAB_CORNER * TAB_CA, TAB_CORNER * (1 - TAB_SA))
    cr:arc(cx,     TAB_CORNER, TAB_CORNER, math.pi + TAB_ALPHA, 1.5 * math.pi)
    cr:arc(w - cx, TAB_CORNER, TAB_CORNER, 1.5 * math.pi,       2 * math.pi - TAB_ALPHA)
    cr:line_to(w - TAB_EAR * TAB_CA, h - TAB_EAR * (1 - TAB_SA))
    cr:arc_negative(w, h - TAB_EAR, TAB_EAR, math.pi - TAB_ALPHA, math.pi / 2)
    cr:close_path()
end

-- Cairo line cap value for rounded ends (cairo.LineCap.ROUND = 1).
local CAIRO_LINE_CAP_ROUND = 1

-- Initial ratio when splitting a leaf (golden ratio: larger side for the existing content).
local SPLIT_RATIO = 0.618

---------------------------------------------------------------------------
-- App launchers (configurable from rc.lua via splitwm.launchers)
---------------------------------------------------------------------------
splitwm.launchers = {}  -- set from rc.lua before calling setup()

-- Pickup is a tagged union: idle | client{client,client_tag} | split{split_id}
local PICKUP_IDLE = { tag = "idle" }
local function pickup_idle()            return PICKUP_IDLE end
local function pickup_client(c, t)      return { tag = "client", client = c, client_tag = t } end
local function pickup_split(id)         return { tag = "split", split_id = id } end
local pickup = PICKUP_IDLE

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
        fg     = color_icon,
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

local function make_circle_icon_btn(draw_fn, size, callback)
    local w = make_circle_icon_btn_widget(draw_fn, size)
    w:buttons(gears.table.join(awful.button({}, 1, callback)))
    return w
end

local function rounded_top(cr, w, h)
    local r = 4
    cr:new_sub_path()
    cr:arc(r,     r, r, math.pi,       1.5 * math.pi)
    cr:arc(w - r, r, r, 1.5 * math.pi, 2   * math.pi)
    cr:line_to(w, h) cr:line_to(0, h) cr:close_path()
end

local function draw_tab_border(cr, w, h)
    local cx = tab_cx(h)
    cr:move_to(0, h)
    cr:arc_negative(0,     h - TAB_EAR, TAB_EAR, math.pi / 2,             TAB_ALPHA)
    cr:line_to(cx - TAB_CORNER * TAB_CA, TAB_CORNER * (1 - TAB_SA))
    cr:arc(cx,     TAB_CORNER, TAB_CORNER, math.pi + TAB_ALPHA, 1.5 * math.pi)
    cr:arc(w - cx, TAB_CORNER, TAB_CORNER, 1.5 * math.pi,       2 * math.pi - TAB_ALPHA)
    cr:line_to(w - TAB_EAR * TAB_CA, h - TAB_EAR * (1 - TAB_SA))
    cr:arc_negative(w, h - TAB_EAR, TAB_EAR, math.pi - TAB_ALPHA, math.pi / 2)
end

---------------------------------------------------------------------------
-- Per-tag state
---------------------------------------------------------------------------

local tag_state = setmetatable({}, { __mode = "k" })

local function get_state(t)
    if not tag_state[t] then
        local root = tree.make_leaf()
        tag_state[t] = { root = root, focused_leaf_id = root.id, leaf_map = { [root.id] = root } }
    end
    return tag_state[t]
end

-- Returns (tag, state) for a client, or (nil, nil) if either is missing.
local function get_tag_state(c)
    local t = c.first_tag
    if not t then return nil, nil end
    return t, tag_state[t]
end

local function get_focused_leaf(state)
    return state.leaf_map[state.focused_leaf_id]
end

-- Returns (leaf, state, tag) for a client, or (nil, nil, nil) if any step fails.
local function get_leaf_from_client(c)
    local t, state = get_tag_state(c)
    if not state then return nil, nil, nil end
    return tree.find_leaf_for_client(state.root, c), state, t
end


---------------------------------------------------------------------------
-- Client management
---------------------------------------------------------------------------

local function pin_client(t, c)
    local state = get_state(t)
    local leaf = get_focused_leaf(state)
    if not leaf then leaf = tree.collect_leaves(state.root)[1] end
    for _, tc in ipairs(leaf.tabs) do if tc == c then return end end
    table.insert(leaf.tabs, c)
    leaf.active_tab = #leaf.tabs
end

local function unpin_client(root, c)
    local leaf = tree.find_leaf_for_client(root, c)
    if not leaf then return end
    for i, tc in ipairs(leaf.tabs) do
        if tc == c then
            table.remove(leaf.tabs, i)
            if i < leaf.active_tab then
                leaf.active_tab = leaf.active_tab - 1
            else
                leaf.active_tab = math.min(leaf.active_tab, #leaf.tabs)
            end
            return
        end
    end
end

local function move_client_to_leaf(root, c, target_leaf)
    unpin_client(root, c)
    for _, tc in ipairs(target_leaf.tabs) do if tc == c then return end end
    table.insert(target_leaf.tabs, c)
    target_leaf.active_tab = #target_leaf.tabs
end

local function swap_split_tabs(state, leaf_a_id, leaf_b_id)
    local leaf_a = state.leaf_map[leaf_a_id]
    local leaf_b = state.leaf_map[leaf_b_id]
    if not leaf_a or not leaf_b then return end
    leaf_a.tabs, leaf_b.tabs = leaf_b.tabs, leaf_a.tabs
    leaf_a.active_tab, leaf_b.active_tab = leaf_b.active_tab, leaf_a.active_tab
    leaf_a.active_tab = math.min(leaf_a.active_tab, #leaf_a.tabs)
    leaf_b.active_tab = math.min(leaf_b.active_tab, #leaf_b.tabs)
end

-- Called when pickup tag=="split" is active: swaps tabs if different leaf, then always resets and arranges.
local function handle_split_pickup(state, leaf_id, s)
    if pickup.split_id ~= leaf_id then
        swap_split_tabs(state, pickup.split_id, leaf_id)
        state.focused_leaf_id = leaf_id
    end
    pickup = pickup_idle()
    awful.layout.arrange(s)
end

local function try_drop_picked_up(t, leaf_id)
    if pickup.tag ~= "client" then return false end
    if not pickup.client.valid then pickup = pickup_idle(); return false end
    local state = get_state(t)
    local target = state.leaf_map[leaf_id]
    if not target then pickup = pickup_idle(); return false end

    local c = pickup.client
    local src_tag = pickup.client_tag

    if src_tag then
        local src_state = tag_state[src_tag]
        if src_state then unpin_client(src_state.root, c) end
    end
    if src_tag ~= t then c:move_to_tag(t) end

    move_client_to_leaf(state.root, c, target)
    state.focused_leaf_id = leaf_id
    pickup = pickup_idle()
    colors.resolve_color_conflict(target, c)

    if src_tag and src_tag ~= t and src_tag.screen then awful.layout.arrange(src_tag.screen) end
    return true
end

---------------------------------------------------------------------------
-- Split operations
---------------------------------------------------------------------------

local function split_leaf(t, direction)
    local state = get_state(t)
    local leaf = get_focused_leaf(state)
    if not leaf then return false end

    local child_a = tree.make_leaf()
    child_a.tabs = leaf.tabs
    child_a.active_tab = leaf.active_tab
    local child_b = tree.make_leaf()

    state.leaf_map[leaf.id]    = nil
    state.leaf_map[child_a.id] = child_a
    state.leaf_map[child_b.id] = child_b

    local new_branch = tree.make_branch(direction, SPLIT_RATIO, child_a, child_b)
    if leaf == state.root then
        state.root = new_branch
    else
        local parent, idx = tree.find_parent(state.root, leaf)
        parent.children[idx] = new_branch
    end
    state.focused_leaf_id = child_a.id
    return true
end

local function close_leaf(t, leaf_id)
    local state = get_state(t)
    local leaf = state.leaf_map[leaf_id]
    if not leaf then return false end
    if pickup.tag == "split" and pickup.split_id == leaf_id then pickup = pickup_idle() end
    if pickup.tag == "client" and pickup.client.valid and tree.find_leaf_for_client(state.root, pickup.client) == leaf then
        pickup = pickup_idle()
    end
    local parent, idx = tree.find_parent(state.root, leaf)
    if not parent then return false end

    local sibling_idx = idx == 1 and 2 or 1
    local sibling = parent.children[sibling_idx]

    -- Move the closed leaf's tabs to the sibling's first leaf so no windows are lost.
    local sibling_leaves = tree.collect_leaves(sibling)
    local dest = sibling_leaves[1]
    for _, tc in ipairs(leaf.tabs) do
        table.insert(dest.tabs, tc)
        colors.resolve_color_conflict(dest, tc)
    end
    if dest.active_tab == 0 and #dest.tabs > 0 then dest.active_tab = 1 end

    -- Keep the currently focused leaf if it lives in the sibling subtree.
    local focused_id = state.focused_leaf_id
    local keep
    for _, l in ipairs(sibling_leaves) do
        if l.id == focused_id then keep = l; break end
    end

    -- Remove the closed leaf from the map; sibling keeps its own identity.
    state.leaf_map[leaf_id] = nil

    -- Splice sibling into the tree in place of parent — no in-place field mutation.
    if parent == state.root then
        state.root = sibling
    else
        local grand_parent, parent_idx = tree.find_parent(state.root, parent)
        grand_parent.children[parent_idx] = sibling
    end

    state.focused_leaf_id = keep and keep.id or sibling_leaves[1].id
    return true
end

-- Returns callbacks table for the three split control actions (vsplit, hsplit, close).
local function make_split_action_callbacks(state, leaf_id, t, s)
    return {
        vsplit = function() state.focused_leaf_id = leaf_id; split_leaf(t, tree.DIR_H); awful.layout.arrange(s) end,
        hsplit = function() state.focused_leaf_id = leaf_id; split_leaf(t, tree.DIR_V); awful.layout.arrange(s) end,
        close  = function() close_leaf(t, leaf_id); awful.layout.arrange(s) end,
    }
end

local function resize_focused(t, delta)
    local state = get_state(t)
    local leaf = get_focused_leaf(state)
    if not leaf then return false end
    local parent, idx = tree.find_parent(state.root, leaf)
    if not parent then return false end
    local new_ratio = parent.ratio
    if idx == 1 then new_ratio = new_ratio + delta else new_ratio = new_ratio - delta end
    local min_r, max_r = 0.1, 0.9
    local cached = t.screen and geo_cache[t.screen]
    if cached then
        local l1 = tree.collect_leaves(parent.children[1])[1]
        local l2 = tree.collect_leaves(parent.children[2])[1]
        local g1 = l1 and cached.geos[l1.id]
        local g2 = l2 and cached.geos[l2.id]
        if g1 and g2 then
            local gap = beautiful.splitwm_gap
            if parent.dir == tree.DIR_H then
                min_r = MIN_SPLIT_W / (g1.width + g2.width + gap)
            else
                min_r = MIN_SPLIT_H / (g1.height + g2.height + gap)
            end
            max_r = 1 - min_r
        end
    end
    parent.ratio = math.max(min_r, math.min(max_r, new_ratio))
    return true
end

---------------------------------------------------------------------------
-- Tab & Focus operations
---------------------------------------------------------------------------

local function cycle_tab(t, offset)
    local state = get_state(t)
    local leaf = get_focused_leaf(state)
    if not leaf or #leaf.tabs == 0 then return false end
    leaf.active_tab = ((leaf.active_tab - 1 + offset) % #leaf.tabs) + 1
    return true
end

local function adjacent_leaf(state, leaf_id, dir)
    local leaves = tree.collect_leaves(state.root)
    if #leaves < 2 then return nil end
    local cur_idx
    for i, l in ipairs(leaves) do if l.id == leaf_id then cur_idx = i; break end end
    if not cur_idx then return nil end
    local new_idx
    if dir == "next" then new_idx = cur_idx < #leaves and cur_idx + 1 or 1
    else new_idx = cur_idx > 1 and cur_idx - 1 or #leaves end
    return leaves[new_idx]
end

local function move_tab_to_direction(t, dir)
    local state = get_state(t)
    local src_leaf = get_focused_leaf(state)
    if not src_leaf or #src_leaf.tabs == 0 then return false end
    local dst_leaf = adjacent_leaf(state, src_leaf.id, dir)
    if not dst_leaf then return false end

    local c = src_leaf.tabs[src_leaf.active_tab]
    table.remove(src_leaf.tabs, src_leaf.active_tab)
    clamp_active_tab(src_leaf)
    table.insert(dst_leaf.tabs, c)
    dst_leaf.active_tab = #dst_leaf.tabs
    colors.resolve_color_conflict(dst_leaf, c)
    return true
end

local function focus_direction(t, dir)
    local state = get_state(t)
    local leaf = adjacent_leaf(state, state.focused_leaf_id, dir)
    if not leaf then return false end
    state.focused_leaf_id = leaf.id
    return true
end

---------------------------------------------------------------------------
-- Drag helpers
---------------------------------------------------------------------------

local function run_v_drag(s, get_b)
    -- Capture start position before the delayed_call so it reflects the press position.
    local start_y = mouse.coords().y
    local moved   = false
    -- Delay starting the grab until after the current event batch is fully processed.
    -- This avoids a race where xcb_grab_pointer is enqueued but the button-release
    -- event has already been read from the X socket, causing the grab to start with
    -- no button held and no future release event to terminate the callback.
    gears.timer.delayed_call(function()
        if not mouse.coords().buttons[1] then return end  -- button already released
        mousegrabber.run(function(m)
            if not m.buttons[1] then
                if moved then awful.layout.arrange(s) end
                return false
            end
            if not moved and math.abs(m.y - start_y) < 4 then return true end
            moved = true
            local b = get_b()
            if not b then return false end
            local igap = b.parent_gap or 0
            b.branch.ratio = math.max(0.1, math.min(0.9, (m.y - b.parent_y) / (b.parent_h - igap)))
            awful.layout.arrange(s)
            return true
        end, "sb_v_double_arrow")
    end)
end

---------------------------------------------------------------------------
-- The layout "arrange" function
---------------------------------------------------------------------------

local geo_cache = {}   -- [screen] = { geos={}, bounds={} }, written by arrange(), read by update_ui()

local function arrange(p)
    local tag = p.tag
    if not tag then
        local s = p.screen
        if type(s) == "number" then s = screen[s] end
        tag = s and s.selected_tag
    end
    if not tag then return end
    local state = get_state(tag)
    local wa    = p.workarea
    local cls   = p.clients
    local gap   = beautiful.splitwm_gap

    local root = state.root
    local pinned = {}
    for _, leaf in ipairs(tree.collect_leaves(root)) do
        for _, tc in ipairs(leaf.tabs) do pinned[tc] = true end
    end
    for _, c in ipairs(cls) do
        if not pinned[c] then pin_client(tag, c) end
    end

    local geos, bounds = {}, {}
    tree.compute_tree(root, wa.x, wa.y, wa.width, wa.height, gap, geos, bounds)
    local s = p.screen
    if type(s) == "number" then s = screen[s] end
    if s then geo_cache[s] = { geos = geos, bounds = bounds } end
    local bw   = beautiful.splitwm_focus_border_width
    local tb_h = math.max(TITLEBAR_HEIGHT, gap)

    for _, leaf in ipairs(tree.collect_leaves(root)) do
        local new_tabs = {}
        for _, tc in ipairs(leaf.tabs) do
            if tc.valid then table.insert(new_tabs, tc) end
        end
        leaf.tabs = new_tabs
        leaf.active_tab = math.min(leaf.active_tab, #leaf.tabs)

        local geo = geos[leaf.id]
        if not geo then goto continue end
        for i, c in ipairs(leaf.tabs) do
            if i == leaf.active_tab then
                c.hidden = false
                c.border_width = 0
                if not c.fullscreen then
                    -- Content precisely sits below the external titlebar Wibox cache
                    c:geometry({
                        x      = geo.x + bw,
                        y      = geo.y - gap + tb_h,
                        width  = math.max(1, geo.width - bw * 2),
                        height = math.max(1, geo.height + gap - bw - tb_h),
                    })
                end
            else
                c.hidden = true
            end
        end
        ::continue::
    end
end

---------------------------------------------------------------------------
-- Persistent wibox pools
---------------------------------------------------------------------------

local function get_active_state(s)
    local t = s.selected_tag
    if not t or not t.layout or t.layout.name ~= "splitwm" then return nil, nil end
    return t, get_state(t)
end


local drag_handle_pool = {}
local function get_drag_handle(s, i)
    if not drag_handle_pool[s] then drag_handle_pool[s] = {} end
    if drag_handle_pool[s][i] then return drag_handle_pool[s][i] end

    local ref = { b = nil, handle_w = 1 }
    local handle_state = "idle"
    local wb  = wibox { x = 0, y = 0, width = 1, height = 1, bg = color_transparent, visible = false, ontop = true, type = "utility" }

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
                    b.branch.ratio = math.max(min_r, math.min(1 - min_r, (mouse.x - b.parent_x) / usable))
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
    wb:connect_signal("mouse::enter", function() if handle_state ~= "dragging" then wb.bg = color_fg_hover end end)
    wb:connect_signal("mouse::leave", function() if handle_state ~= "dragging" then wb.bg = color_transparent end end)

    local entry = { wb = wb, ref = ref }
    drag_handle_pool[s][i] = entry
    return entry
end

local titlebar_cache = {}

-- Closes the menu if open and returns true; returns false if it was already closed.
-- Deduplicates within a single event: multiple handlers firing for the same click
-- all check this, but only the first actually calls on_menu_close().
local function event_close_menu_if_open()
    if splitwm._menu_just_toggled then return false end
    if splitwm._menu_was_open     then return true  end
    if splitwm.on_menu_close and splitwm.on_menu_close() then
        splitwm._menu_was_open = true
        gears.timer.delayed_call(function() splitwm._menu_was_open = false end)
        return true
    end
    return false
end

---------------------------------------------------------------------------
-- Titlebars (Wibox based) — helper functions
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
        wb                = wibox { screen = s, bg = color_transparent, visible = true, ontop = false, type = "utility" },
        tooltip           = awful.tooltip { text = "", delay_show = 0.3, font = "monospace bold 12px", bg = color_bg, fg = color_fg, border_width = 0 },
        tooltip_objs      = {},
        titlebar_btn_list = {},
        titlebar_hovered  = false,
        tb_h              = nil,
    }
    entry.wb:connect_signal("mouse::enter", function()
        entry.titlebar_hovered = true
        for _, btn in ipairs(entry.titlebar_btn_list) do if not btn._disabled then btn.bg = color_bg end end
        if entry.swap_btn and not entry.swap_btn_picked then entry.swap_btn.bg = color_bg end
    end)
    entry.wb:connect_signal("mouse::leave", function()
        entry.titlebar_hovered = false
        for _, btn in ipairs(entry.titlebar_btn_list) do if not btn._disabled then btn.bg = color_btn_bg end end
        if entry.swap_btn then
            entry.swap_btn.bg = entry.swap_btn_picked and color_fg or color_btn_bg
            if entry.swap_btn._icon then
                entry.swap_btn._icon._dark = entry.swap_btn_picked
                entry.swap_btn._icon:emit_signal("widget::redraw_needed")
            end
        end
    end)
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
        (pickup.tag == "split" and pickup.split_id == leaf.id) and "S" or "",
        geo and geo.width or 0,
        geo and geo.height or 0,
    }
    for _, tc in ipairs(leaf.tabs) do
        parts[#parts+1] = tostring(tc.window)
        if pickup.tag == "client" and pickup.client == tc then parts[#parts+1] = "P" end
    end
    return table.concat(parts, "\0")
end

local function tb_make_btn(entry, widget_bc, draw_fn, size, callback)
    local w = make_circle_icon_btn_widget(draw_fn, size)
    w.shape_border_color = widget_bc
    if callback then w:buttons(gears.table.join(awful.button({}, 1, callback))) end
    table.insert(entry.titlebar_btn_list, w)
    return w
end

-- tab_state: "active" | "inactive" | "picked"
local function get_tab_state(tab_idx, leaf, tc)
    if pickup.tag == "client" and pickup.client == tc then return "picked"
    elseif tab_idx == leaf.active_tab then return "active"
    else return "inactive"
    end
end

-- Build the widget for a single tab (icon, move button, close button, shape, tooltip).
local function tb_build_tab_widget(leaf, tc, tab_idx, entry, ctx)
    local tab_state = get_tab_state(tab_idx, leaf, tc)

    local tab_icon = awful.widget.clienticon(tc)
    tab_icon.forced_width  = ctx.icon_size
    tab_icon.forced_height = ctx.icon_size

    local move_btn = wibox.widget {
        {
            { text = tab_state == "picked" and "↗" or "↗", align = "center", font = ctx.tab_btn_font, widget = wibox.widget.textbox },
            bottom = 2, widget = wibox.container.margin,
        },
        bg           = tab_state == "picked" and color_fg or color_transparent,
        fg           = tab_state == "picked" and color_bg or (tab_state == "active" and color_fg or color_transparent),
        shape        = function(cr, w, h) gears.shape.rounded_rect(cr, w, h, 4) end,
        forced_width = BTN_SIZE,
        widget       = wibox.container.background,
    }
    local close_btn = wibox.widget {
        { text = "✕", align = "center", font = ctx.tab_btn_font, widget = wibox.widget.textbox },
        bg           = color_transparent,
        fg           = tab_state == "active" and color_fg or color_transparent,
        shape        = function(cr, w, h) gears.shape.rounded_rect(cr, w, h, 4) end,
        forced_width = BTN_SIZE,
        widget       = wibox.container.background,
    }
    if tab_state == "active" then
        move_btn:connect_signal("mouse::enter", function() move_btn.bg = color_fg_hover end)
        move_btn:connect_signal("mouse::leave", function() move_btn.bg = color_transparent end)
        move_btn:buttons(gears.table.join(awful.button({}, 1, function()
            if pickup.tag == "client" and pickup.client == tc then
                pickup = pickup_idle()
            else
                pickup = pickup_client(tc, ctx.t)
            end
            awful.layout.arrange(ctx.s)
        end)))
        close_btn:buttons(gears.table.join(awful.button({}, 1, function() tc:kill() end)))
    end

    local client_color = colors.get_client_color(tc)
    local tab_bg = tab_state == "picked" and color_fg
        or (client_color and client_color.dark)
        or (tab_state == "active" and color_bg)
        or color_btn_bg
    local tab_bg_pat   = gears.color(tab_bg)
    local widget_bc_pat = gears.color(ctx.widget_bc)

    local tab_draw = wibox.widget.base.make_widget()
    function tab_draw:draw(_, cr, w2, h2)
        local h = h2 - 1  -- 1px breathing room at top so the border stroke isn't clipped
        cr:translate(0, 1)
        local cx = tab_cx(h)
        cr:move_to(0, h)
        cr:arc_negative(0,      h - TAB_EAR, TAB_EAR, math.pi / 2,             TAB_ALPHA)
        cr:line_to(cx - TAB_CORNER * TAB_CA, TAB_CORNER * (1 - TAB_SA))
        cr:arc(cx,      TAB_CORNER, TAB_CORNER, math.pi + TAB_ALPHA, 1.5 * math.pi)
        cr:arc(w2 - cx, TAB_CORNER, TAB_CORNER, 1.5 * math.pi,       2 * math.pi - TAB_ALPHA)
        cr:line_to(w2 - TAB_EAR * TAB_CA, h - TAB_EAR * (1 - TAB_SA))
        cr:arc_negative(w2, h - TAB_EAR, TAB_EAR, math.pi - TAB_ALPHA, math.pi / 2)
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
                { { tab_icon, halign = "center", valign = "center", widget = wibox.container.place }, right = 3, widget = wibox.container.margin },
                move_btn, close_btn, spacing = 2, layout = wibox.layout.fixed.horizontal,
            },
            left = 21, right = 21, top = 1, bottom = 1, widget = wibox.container.margin,
        },
        layout = wibox.layout.stack,
    }

    tab_widget:connect_signal("mouse::enter", function() entry.tooltip.text = (tc.valid and tc.name) or "?" end)
    entry.tooltip:add_to_object(tab_widget)
    table.insert(entry.tooltip_objs, tab_widget)

    tab_widget:buttons(gears.table.join(awful.button({}, 1, function()
        if pickup.tag == "split" and pickup.split_id ~= leaf.id then
            handle_split_pickup(ctx.state, leaf.id, ctx.s); return
        end
        if pickup.tag == "client" and pickup.client.valid and pickup.client ~= tc then
            try_drop_picked_up(ctx.t, leaf.id)
            awful.layout.arrange(ctx.s)
            return
        end
        leaf.active_tab = tab_idx
        awful.layout.arrange(ctx.s)
    end)))

    return tab_widget
end

-- Build the right-side split control buttons (vsplit, hsplit, close, swap).
local function tb_build_split_controls(leaf, entry, ctx)
    local gap    = beautiful.splitwm_gap
    local geo    = ctx.geo
    local parent = tree.find_parent(ctx.state.root, leaf)
    local can_vsplit = geo and geo.width  >= 2 * MIN_SPLIT_W + gap
    local can_hsplit = geo and geo.height >= 2 * MIN_SPLIT_H + gap

    local function make_btn(draw_fn, callback, disabled)
        return tb_make_btn(entry, ctx.widget_bc, draw_fn, BTN_SIZE,
            not disabled and callback)
    end

    local cb = make_split_action_callbacks(ctx.state, leaf.id, ctx.t, ctx.s)
    local vsplit_btn      = make_btn(icons.vsplit, cb.vsplit, not can_vsplit)
    local hsplit_btn      = make_btn(icons.hsplit, cb.hsplit, not can_hsplit)
    local close_split_btn = make_btn(icons.close,  cb.close,  not parent)

    if not can_vsplit then set_btn_disabled(vsplit_btn, entry.wb) end
    if not can_hsplit then set_btn_disabled(hsplit_btn, entry.wb) end
    if parent then on_hover_fg(close_split_btn, color_close, color_fg)
    else           set_btn_disabled(close_split_btn, entry.wb) end


    local is_split_picked = (pickup.tag == "split" and pickup.split_id == leaf.id)
    local swap_btn = make_circle_icon_btn_widget(icons.swap, BTN_SIZE)
    swap_btn.shape_border_color = ctx.widget_bc
    if is_split_picked then swap_btn.bg = color_fg; swap_btn._icon._dark = true end
    entry.swap_btn        = swap_btn
    entry.swap_btn_picked = is_split_picked
    swap_btn:buttons(gears.table.join(awful.button({}, 1, function()
        if pickup.tag == "split" and pickup.split_id == leaf.id then
            pickup = pickup_idle()
        elseif pickup.tag == "split" then
            handle_split_pickup(ctx.state, leaf.id, ctx.s); return
        else
            pickup = pickup_split(leaf.id)
            ctx.state.focused_leaf_id = leaf.id
        end
        awful.layout.arrange(ctx.s)
    end)))

    return { vsplit = vsplit_btn, hsplit = hsplit_btn, close = close_split_btn, swap = swap_btn }
end

-- Build the focus border drawn around the client area.
local function tb_build_border_widget(border_color, tb_h, bw, radius)
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
        local wd   = width - self._bw
        local h    = height - self._tb_h
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

-- Split tab_widgets into two layers: the active tab floats above the border widget,
-- inactive tabs stay behind it.  Spacers preserve layout width in each layer.
local function tb_split_tab_layers(tab_widgets, active_tab)
    local behind, above = {}, {}
    local n = #tab_widgets
    for i, tw in ipairs(tab_widgets) do
        local ref = tw
        local sp  = wibox.widget.base.make_widget()
        function sp:fit(wctx, w, h) return ref:fit(wctx, w, h) end
        function sp:draw() end
        -- The last widget ("+" button) always goes in above so it's drawn on top of
        -- the active tab's negative-spacing overlap in Layer 3.
        if i == active_tab then
            table.insert(behind, sp)
            table.insert(above,  tw)
        elseif i == n then
            table.insert(behind, sp)
            table.insert(above,  tw)
        else
            table.insert(behind, tw)
            table.insert(above,  sp)
        end
    end
    return behind, above
end

local function tb_build_bar_layer(behind, controls, middle_drag, ctx)
    local tabs   = { spacing = ctx.TAB_SPACING, layout = wibox.layout.fixed.horizontal, table.unpack(behind) }
    -- Rendered on top of tabs in the stack so its background paints over any tab overflow.
    local ctrl_cover = {
        {
            {
                {
                    { controls.swap, controls.vsplit, controls.hsplit, controls.close,
                      spacing = ctx.BTN_SPACING, layout = wibox.layout.fixed.horizontal },
                    widget = wibox.container.margin,
                },
                bg = ctx.bar_bg, widget = wibox.container.background,
            },
            bottom = BTN_V_RAISE, widget = wibox.container.margin,
        },
        halign = "right", widget = wibox.container.place,
    }
    local layers = middle_drag
        and { middle_drag, tabs, ctrl_cover, layout = wibox.layout.stack }
        or  { tabs, ctrl_cover, layout = wibox.layout.stack }
    return {
        {
            { layers, top = ctx.top_pad, widget = wibox.container.margin },
            bg = ctx.bar_bg, shape = rounded_top, forced_height = ctx.tb_bar_h, widget = wibox.container.background,
        },
        layout = wibox.layout.fixed.vertical,
    }
end

-- Assemble the three-layer wibox layout for a leaf's titlebar.
local function tb_assemble_wibox(entry, behind, above, controls, border_draw, middle_drag, ctx)
    entry.wb:setup {
        -- Layer 1: inactive tabs + split controls (behind border)
        tb_build_bar_layer(behind, controls, middle_drag, ctx),
        -- Layer 2: focus border
        border_draw,
        -- Layer 3: active tab on top of border (clipped same as Layer 1 so it doesn't overlap controls)
        {
            {
                {
                    {
                        { spacing = ctx.TAB_SPACING, layout = wibox.layout.fixed.horizontal, table.unpack(above) },
                        right = 4 * BTN_SIZE + 3 * ctx.BTN_SPACING, widget = wibox.container.margin,
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

-- Assemble the titlebar wibox for an empty leaf: bar strip + background + launchers.
local function tb_assemble_empty_wibox(entry, bar_widgets, controls, border_draw, middle_drag, launcher_ws, ctx)
    -- Split launchers into two rows
    local row1, row2 = {}, {}
    local mid = math.ceil(#launcher_ws / 2)
    for i, w in ipairs(launcher_ws) do
        if i <= mid then table.insert(row1, w) else table.insert(row2, w) end
    end
    local icon_grid
    if #row2 > 0 then
        icon_grid = {
            { spacing = ctx.BTN_SPACING, layout = wibox.layout.fixed.horizontal, table.unpack(row1) },
            { spacing = ctx.BTN_SPACING, layout = wibox.layout.fixed.horizontal, table.unpack(row2) },
            spacing = ctx.BTN_SPACING, layout = wibox.layout.fixed.vertical,
        }
    else
        icon_grid = { spacing = ctx.BTN_SPACING, layout = wibox.layout.fixed.horizontal, table.unpack(launcher_ws) }
    end
    local corner_r = beautiful.splitwm_empty_radius
    entry.wb:setup {
        -- Layer 1: content background (spacer over bar area, colored content fills the rest)
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
        -- Layer 2: bar strip with controls (+ button left, split controls right)
        tb_build_bar_layer(bar_widgets, controls, middle_drag, ctx),
        -- Layer 3: focus border
        border_draw,
        layout = wibox.layout.stack,
    }
end

---------------------------------------------------------------------------
-- Titlebars (Wibox based)
---------------------------------------------------------------------------

local function update_titlebars(s, t, state, geos, leaves)
    if not titlebar_cache[s] then titlebar_cache[s] = {} end

    local gap  = beautiful.splitwm_gap
    local tb_h = math.max(TITLEBAR_HEIGHT, gap)
    local bw   = beautiful.splitwm_focus_border_width
    local alive = {}

    local function update_leaf(leaf)
        local geo = geos[leaf.id]
        if not geo then return end

        local entry = tb_get_or_create_entry(s, leaf)
        entry.tb_h = tb_h
        local wb = entry.wb
        local active_client = leaf.tabs[leaf.active_tab]
        if active_client and active_client.fullscreen then
            wb.visible = false
            return
        end
        wb.x       = geo.x
        wb.y       = geo.y - gap
        wb.width   = geo.width
        wb.height  = geo.height + gap
        wb.visible = true

        local fp = tb_compute_fingerprint(leaf, state, geo)
        if entry.fp == fp then return end
        entry.fp              = fp
        entry.titlebar_btn_list = {}

        local is_focused    = state.focused_leaf_id == leaf.id
        local active_client = leaf.tabs[leaf.active_tab]
        local active_picked = pickup.tag == "client" and pickup.client == active_client
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
            top_pad      = math.max(gap, TITLEBAR_HEIGHT) - TITLEBAR_HEIGHT,
            tb_h         = tb_h,
            tb_bar_h     = tb_h,
            icon_size    = 20,
            tab_btn_font = "monospace bold 18px",
            BTN_SPACING  = BTN_SPACING,
            TAB_SPACING  = TAB_SPACING,
        }

        -- Detach tooltip from previous tab widgets before rebuilding
        entry.tooltip:hide()
        for _, obj in ipairs(entry.tooltip_objs) do entry.tooltip:remove_from_object(obj) end
        entry.tooltip_objs = {}

        -- Build per-tab widgets
        local tab_widgets = {}
        for i, tc in ipairs(leaf.tabs) do
            table.insert(tab_widgets, tb_build_tab_widget(leaf, tc, i, entry, ctx))
        end

        -- "+" lives at the end of the tab row; tb_split_tab_layers always puts it in
        -- the above layer so it renders on top of the active tab's negative-spacing overlap.
        table.insert(tab_widgets, wibox.widget {
            tb_make_btn(entry, ctx.widget_bc, icons.plus, BTN_SIZE, function()
                pcall(function() mousegrabber.stop() end)
                ctx.state.focused_leaf_id = leaf.id
                if splitwm.on_menu_request then splitwm.on_menu_request() end
            end),
            left = #leaf.tabs > 0 and 24 or 0, bottom = BTN_V_RAISE, widget = wibox.container.margin,
        })

        local controls    = tb_build_split_controls(leaf, entry, ctx)

        local empty_r     = 14
        local empty_focus_color = color_fg
        local border_draw = #leaf.tabs == 0
            and tb_build_border_widget(is_focused and empty_focus_color or nil, tb_h, bw, empty_r)
            or  tb_build_border_widget(is_focused and focus_color or nil, tb_h, bw)

        local middle_drag
        if leaf.v_bound_above then
            middle_drag = wibox.widget { cursor = "sb_v_double_arrow", widget = wibox.container.background }
            middle_drag:buttons(gears.table.join(awful.button({}, 1, function()
                if not leaf.v_bound_above then return end
                if event_close_menu_if_open() then return end
                run_v_drag(s, function() return leaf.v_bound_above end)
            end)))
        end

        if #leaf.tabs == 0 then
            local launcher_ws = {}
            for _, e in ipairs(splitwm.launchers) do
                launcher_ws[#launcher_ws + 1] = make_launcher_widget(e, 30, function()
                    ctx.state.focused_leaf_id = leaf.id
                    if e.action then e.action() elseif e.cmd then awful.spawn(e.cmd) end
                end)
            end
            -- tab_widgets is empty for empty leaves; controls.menu has the "+" button
            tb_assemble_empty_wibox(entry, tab_widgets, controls, border_draw, middle_drag, launcher_ws, ctx)
            -- Clicking the content area completes a swap/drop, just like the old overlay did
            entry.wb:buttons(gears.table.join(awful.button({}, 1, function()
                if pickup.tag == "split"  then handle_split_pickup(ctx.state, leaf.id, ctx.s); return end
                if pickup.tag == "client" then try_drop_picked_up(ctx.t, leaf.id); awful.layout.arrange(ctx.s); return end
                if event_close_menu_if_open() then return end
                ctx.state.focused_leaf_id = leaf.id; awful.layout.arrange(ctx.s)
            end)))
        else
            entry.wb:buttons(gears.table.join())  -- clear handler when split becomes non-empty
            local behind, above = tb_split_tab_layers(tab_widgets, leaf.active_tab)
            tb_assemble_wibox(entry, behind, above, controls, border_draw, middle_drag, ctx)
        end
    end

    for _, leaf in ipairs(leaves) do
        alive[leaf.id] = true
        update_leaf(leaf)
    end

    -- Hide and clean up entries for dead leaves
    for leaf_id, entry in pairs(titlebar_cache[s]) do
        if alive[leaf_id] then goto continue end
        entry.wb.visible = false
        titlebar_cache[s][leaf_id] = nil
        ::continue::
    end
end


---------------------------------------------------------------------------
-- Update drag handles
---------------------------------------------------------------------------

local function update_drag_handles(s, state, bounds)
    local gap      = beautiful.splitwm_gap
    local handle_w = gap - 4
    local hi       = 0

    -- Only "horizontal" bounds (vertical dividers between left/right panes) need a drag strip wibox.
    -- "vertical" bounds (horizontal dividers between top/bottom panes) are dragged via the titlebar,
    -- which spans the full width of the pane and sits exactly on the vertical gap.
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


---------------------------------------------------------------------------
-- Unified UI update
---------------------------------------------------------------------------

local function hide_cache(cache, wb_key)
    if not cache then return end
    for _, v in pairs(cache) do
        local obj = wb_key and v[wb_key] or v
        obj.visible = false
    end
end

local function update_ui(s)
    local t, state = get_active_state(s)
    if not t then
        local pool = drag_handle_pool[s]
        if pool then for _, entry in ipairs(pool) do entry.wb.visible = false end end
        if titlebar_cache[s] then
            for _, entry in pairs(titlebar_cache[s]) do
                entry.wb.visible = false
            end
        end
        return
    end

    local gap    = beautiful.splitwm_gap
    local cached = geo_cache[s]
    local geos, bounds
    if cached then
        geos, bounds = cached.geos, cached.bounds
    else
        local wa = s.workarea
        geos, bounds = {}, {}
        tree.compute_tree(state.root, wa.x, wa.y, wa.width, wa.height, gap, geos, bounds)
    end

    local leaves = tree.collect_leaves(state.root)
    update_titlebars(s, t, state, geos, leaves)
    update_drag_handles(s, state, bounds)
end

---------------------------------------------------------------------------
-- Layout object
---------------------------------------------------------------------------

splitwm.layout = {
    name    = "splitwm",
    arrange = function(p)
        arrange(p)
        local s = p.screen
        if type(s) == "number" then s = screen[s] end
        if not s then return end
        gears.timer.delayed_call(function() update_ui(s) end)
    end,
}

---------------------------------------------------------------------------
-- Keybinding helpers
---------------------------------------------------------------------------

local function with_tag(fn)
    local s = awful.screen.focused()
    local t = s.selected_tag
    if t and fn(t) ~= false then awful.layout.arrange(s) end
end

splitwm.split_horizontal = function() with_tag(function(t) split_leaf(t, tree.DIR_H) end) end
splitwm.split_vertical   = function() with_tag(function(t) split_leaf(t, tree.DIR_V) end) end
splitwm.focus_next_split = function() with_tag(function(t) focus_direction(t, "next") end) end
splitwm.focus_prev_split = function() with_tag(function(t) focus_direction(t, "prev") end) end
splitwm.next_tab         = function() with_tag(function(t) cycle_tab(t, 1) end) end
splitwm.prev_tab         = function() with_tag(function(t) cycle_tab(t, -1) end) end
splitwm.move_tab_next    = function() with_tag(function(t) move_tab_to_direction(t, "next") end) end
splitwm.move_tab_prev    = function() with_tag(function(t) move_tab_to_direction(t, "prev") end) end
splitwm.resize_grow      = function() with_tag(function(t) resize_focused(t, 0.05) end) end
splitwm.resize_shrink    = function() with_tag(function(t) resize_focused(t, -0.05) end) end
splitwm.close_split      = function() with_tag(function(t) close_leaf(t, get_state(t).focused_leaf_id) end) end

function splitwm.cancel_pickup()
    if pickup.tag ~= "idle" then
        pickup = pickup_idle()
        awful.layout.arrange(awful.screen.focused())
    end
end

---------------------------------------------------------------------------
-- Setup & Caches
---------------------------------------------------------------------------

function splitwm.setup()
    color_bg             = beautiful.splitwm_color_bg
    color_fg             = beautiful.splitwm_color_fg
    color_fg_disabled    = beautiful.splitwm_fg_disabled
    color_close          = beautiful.splitwm_close_fg
    color_icon           = beautiful.splitwm_color_fg
    color_btn_bg         = beautiful.splitwm_btn_bg
    color_transparent    = beautiful.splitwm_transparent
    color_fg_hover       = beautiful.splitwm_fg_hover

    awesome.register_xproperty("splitwm_color", "string")

    client.connect_signal("manage", function(c)
        local t = c.first_tag
        if not t then return end
        local state = get_state(t)
        local leaf = tree.find_leaf_for_client(state.root, c)
        if not leaf then pin_client(t, c); leaf = tree.find_leaf_for_client(state.root, c) end
        if leaf then colors.resolve_color_conflict(leaf, c) end
    end)

    client.connect_signal("unmanage", function(c)
        if pickup.tag == "client" and pickup.client == c then pickup = pickup_idle() end
        for t, state in pairs(tag_state) do unpin_client(state.root, c) end
    end)

    client.connect_signal("focus", function(c)
        local leaf, state = get_leaf_from_client(c)
        if not leaf then return end
        if leaf.id ~= state.focused_leaf_id then
            state.focused_leaf_id = leaf.id
            awful.layout.arrange(c.screen)
        end
    end)

    client.connect_signal("property::fullscreen", function(c)
        awful.layout.arrange(c.screen)
    end)

    client.connect_signal("button::press", function(c)
        local leaf, state, t = get_leaf_from_client(c)
        if not state then return end
        if pickup.tag == "split" then
            if leaf and leaf.id ~= pickup.split_id then
                handle_split_pickup(state, leaf.id, c.screen)
            end
        elseif pickup.tag == "client" and pickup.client.valid and pickup.client ~= c then
            if leaf then try_drop_picked_up(t, leaf.id); awful.layout.arrange(c.screen) end
        elseif leaf and leaf.id ~= state.focused_leaf_id then
            state.focused_leaf_id = leaf.id
            awful.layout.arrange(c.screen)
        end
    end)

    tag.connect_signal("property::selected", function(t)
        local s = t.screen
        if type(s) == "number" then s = screen[s] end
        -- Splits are tag-local; cancel any pending swap so the leaf ID
        -- doesn't silently fail to resolve on the newly selected tag.
        if pickup.tag == "split" then pickup = pickup_idle() end
        if s then geo_cache[s] = nil; gears.timer.delayed_call(function() update_ui(s) end) end
    end)
end

function splitwm.flush_caches()
    for _, screen_cache in pairs(titlebar_cache) do
        for _, entry in pairs(screen_cache) do
            for _, obj in ipairs(entry.tooltip_objs) do entry.tooltip:remove_from_object(obj) end
            entry.wb.visible = false
        end
    end
    titlebar_cache = {}
end

splitwm.get_state = get_state
splitwm.collect_leaves = tree.collect_leaves

return splitwm