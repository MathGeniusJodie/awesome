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

-- Base height of the tab bar.
local TITLEBAR_HEIGHT = 33

-- Cairo line cap value for rounded ends (cairo.LineCap.ROUND = 1).
local CAIRO_LINE_CAP_ROUND = 1

-- Initial ratio when splitting a leaf (golden ratio: larger side for the existing content).
local SPLIT_RATIO = 0.618

---------------------------------------------------------------------------
-- App launchers (configurable from rc.lua via splitwm.launchers)
---------------------------------------------------------------------------
splitwm.launchers = {}  -- set from rc.lua before calling setup()

local picked_up_client = nil
local picked_up_split  = nil

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
            font   = "monospace bold " .. math.floor(size * 0.7),
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
        bg     = "#00000000",
        fg     = "#cccccc",
        widget = wibox.container.background,
    }
    w:connect_signal("mouse::enter", function() w.bg = "#ffffff15" end)
    w:connect_signal("mouse::leave", function() w.bg = "#00000000" end)
    w:buttons(gears.table.join(awful.button({}, 1, callback)))
    return w
end

local function make_circle_btn_widget(label, size)
    return wibox.widget {
        {
            {
                markup = '<span font_family="Sans">' .. label .. '</span>',
                align  = "center",
                valign = "center",
                font   = beautiful.splitwm_btn_font or "monospace bold 14",
                widget = wibox.widget.textbox,
            },
            halign = "center",
            valign = "center",
            widget = wibox.container.place,
        },
        bg           = beautiful.splitwm_inactive_bg or "#00000080",
        fg           = "#ffffff",
        shape        = gears.shape.circle,
        shape_border_width  = 2,
        shape_border_color  = beautiful.splitwm_widget_border or "#ffffff30",
        forced_width  = size,
        forced_height = size,
        widget       = wibox.container.background,
    }
end

local function make_circle_btn(label, size, callback)
    local w = make_circle_btn_widget(label, size)
    w:buttons(gears.table.join(awful.button({}, 1, callback)))
    return w
end

local function make_circle_icon_btn_widget(draw_fn, size)
    local icon = wibox.widget.base.make_widget()
    function icon:draw(_, cr, w, h)
        cr:set_source_rgba(1, 1, 1, 0.85)
        cr:set_line_width(2)
        cr:set_line_cap(CAIRO_LINE_CAP_ROUND)
        draw_fn(cr, w, h)
    end
    function icon:fit(_, w, h) return w, h end
    return wibox.widget {
        icon,
        bg                 = beautiful.splitwm_inactive_bg or "#00000080",
        shape              = gears.shape.circle,
        forced_width       = size,
        forced_height      = size,
        widget             = wibox.container.background,
    }
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
    local r   = 6
    local pad = 1
    cr:move_to(pad, h)
    cr:line_to(pad, r + pad)
    cr:arc(r + pad,     r + pad, r, math.pi,       1.5 * math.pi)
    cr:arc(w - r - pad, r + pad, r, 1.5 * math.pi, 2   * math.pi)
    cr:line_to(w - pad, h)
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

-- Clamps leaf.active_tab into [0, #leaf.tabs].
local function clamp_active_tab(leaf)
    leaf.active_tab = math.max(0, math.min(leaf.active_tab, #leaf.tabs))
end

---------------------------------------------------------------------------
-- Client management
---------------------------------------------------------------------------

local function pin_client(t, c)
    local state = get_state(t)
    local leaf = state.leaf_map[state.focused_leaf_id]
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
    clamp_active_tab(leaf_a)
    clamp_active_tab(leaf_b)
end

local function try_drop_picked_up(t, leaf_id)
    if not picked_up_client then return false end
    if not picked_up_client.client.valid then picked_up_client = nil; return false end
    local state = get_state(t)
    local target = state.leaf_map[leaf_id]
    if not target then picked_up_client = nil; return false end

    local c = picked_up_client.client
    local src_tag = picked_up_client.tag

    if src_tag then
        local src_state = tag_state[src_tag]
        if src_state then unpin_client(src_state.root, c) end
    end
    if src_tag ~= t then c:move_to_tag(t) end

    move_client_to_leaf(state.root, c, target)
    state.focused_leaf_id = leaf_id
    picked_up_client = nil
    colors.resolve_color_conflict(target, c)

    if src_tag and src_tag ~= t and src_tag.screen then awful.layout.arrange(src_tag.screen) end
    return true
end

---------------------------------------------------------------------------
-- Split operations
---------------------------------------------------------------------------

local function split_leaf(t, direction)
    local state = get_state(t)
    local leaf = state.leaf_map[state.focused_leaf_id]
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
    if picked_up_split  == leaf_id then picked_up_split  = nil end
    if picked_up_client and picked_up_client.client.valid and tree.find_leaf_for_client(state.root, picked_up_client.client) == leaf then
        picked_up_client = nil
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

local function resize_focused(t, delta)
    local state = get_state(t)
    local leaf = state.leaf_map[state.focused_leaf_id]
    if not leaf then return false end
    local parent, idx = tree.find_parent(state.root, leaf)
    if not parent then return false end
    local new_ratio = parent.ratio
    if idx == 1 then new_ratio = new_ratio + delta else new_ratio = new_ratio - delta end
    parent.ratio = math.max(0.1, math.min(0.9, new_ratio))
    return true
end

---------------------------------------------------------------------------
-- Tab & Focus operations
---------------------------------------------------------------------------

local function cycle_tab(t, offset)
    local state = get_state(t)
    local leaf = state.leaf_map[state.focused_leaf_id]
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
    local src_leaf = state.leaf_map[state.focused_leaf_id]
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
    mousegrabber.run(function(mouse)
        if not mouse.buttons[1] then awful.layout.arrange(s); return false end
        local b = get_b()
        if not b then return false end
        local igap = b.parent_gap or 0
        b.branch.ratio = math.max(0.1, math.min(0.9, (mouse.y - b.parent_y) / (b.parent_h - igap)))
        awful.layout.arrange(s)
        return true
    end, "sb_v_double_arrow")
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
    local gap   = beautiful.splitwm_gap or 16

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
    local bw   = beautiful.splitwm_focus_border_width or 2
    local tb_h = math.max(TITLEBAR_HEIGHT, gap)

    for _, leaf in ipairs(tree.collect_leaves(root)) do
        local new_tabs = {}
        for _, tc in ipairs(leaf.tabs) do
            if tc.valid then table.insert(new_tabs, tc) end
        end
        leaf.tabs = new_tabs
        clamp_active_tab(leaf)

        local geo = geos[leaf.id]
        if geo then
            for i, c in ipairs(leaf.tabs) do
                if i == leaf.active_tab then
                    c.hidden = false
                    c.border_width = 0
                    -- Content precisely sits below the external titlebar Wibox cache
                    c:geometry({
                        x      = geo.x + bw,
                        y      = geo.y - gap + tb_h,
                        width  = math.max(1, geo.width - bw * 2),
                        height = math.max(1, geo.height + gap - bw - tb_h),
                    })
                else
                    c.hidden = true
                end
            end
        end
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

    local ref = { b = nil, handle_w = 1, dragging = false }
    local wb  = wibox { x = 0, y = 0, width = 1, height = 1, bg = "#00000000", visible = false, ontop = true, type = "utility" }

    wb:buttons(gears.table.join(
        awful.button({}, 1, function()
            if not ref.b then return end
            ref.dragging = true
            wb.bg = beautiful.splitwm_handle_drag_bg or "#7799dd44"
            local b, hw = ref.b, ref.handle_w
            mousegrabber.run(function(mouse)
                if not mouse.buttons[1] then
                    ref.dragging = false; wb.bg = "#00000000"; awful.layout.arrange(s); return false
                end
                local igap = b.parent_gap or 0
                if b.dir == "h" then
                    b.branch.ratio = math.max(0.1, math.min(0.9, (mouse.x - b.parent_x) / (b.parent_w - igap)))
                    wb.x = mouse.x - math.floor(hw / 2)
                else
                    b.branch.ratio = math.max(0.1, math.min(0.9, (mouse.y - b.parent_y) / (b.parent_h - igap)))
                    wb.y = mouse.y - math.floor(hw / 2)
                end
                awful.layout.arrange(s)
                return true
            end, b.dir == "h" and "sb_h_double_arrow" or "sb_v_double_arrow")
        end)
    ))
    wb:connect_signal("mouse::enter", function() if not ref.dragging then wb.bg = beautiful.splitwm_handle_hover_bg or "#7799dd22" end end)
    wb:connect_signal("mouse::leave", function() if not ref.dragging then wb.bg = "#00000000" end end)

    local entry = { wb = wb, ref = ref }
    drag_handle_pool[s][i] = entry
    return entry
end

local overlay_cache  = {}
local titlebar_cache = {}

-- Returns (entry, leaf) for a client's titlebar, or (nil, nil) if any step fails.
local function get_titlebar_entry(c)
    if not c.screen then return nil, nil end
    local t = c.first_tag
    if not t then return nil, nil end
    local state = tag_state[t]
    if not state then return nil, nil end
    local leaf = tree.find_leaf_for_client(state.root, c)
    if not leaf then return nil, nil end
    local entry = titlebar_cache[c.screen] and titlebar_cache[c.screen][leaf.id]
    return entry, leaf
end

---------------------------------------------------------------------------
-- Update Overlays (empty split placeholders)
---------------------------------------------------------------------------

local function update_overlays(s, t, state, geos, leaves)
    local focus_bw = beautiful.splitwm_focus_border_width or 2
    local gap      = beautiful.splitwm_gap or 16
    if not overlay_cache[s] then overlay_cache[s] = {} end

    local needed, alive = {}, {}
    for _, leaf in ipairs(leaves) do
        alive[leaf.id] = true
        if #leaf.tabs == 0 then needed[leaf.id] = leaf end
    end

    for leaf_id, wb in pairs(overlay_cache[s]) do
        if not alive[leaf_id] then
            wb.visible = false
            overlay_cache[s][leaf_id] = nil
        elseif not needed[leaf_id] then
            wb.visible = false
        end
    end

    for leaf_id, leaf in pairs(needed) do
        local geo = geos[leaf_id]
        if geo then
            local x = geo.x + focus_bw
            local w = math.max(1, geo.width - 2 * focus_bw)
            local raise = leaf.v_bound_above and gap or 0
            local y = geo.y + focus_bw - raise
            local h = math.max(1, geo.height - 2 * focus_bw + raise)
            local bg = beautiful.splitwm_inactive_bg
            local is_focused = (leaf_id == state.focused_leaf_id)
            local border = is_focused and (beautiful.splitwm_focus_border or "#7799dd") or "#00000066"

            if overlay_cache[s][leaf_id] then
                local wb = overlay_cache[s][leaf_id]
                wb.x = x; wb.y = y; wb.width = w; wb.height = h
                wb._bg_widget.bg = bg
                wb._bg_widget.shape_border_color = border
                wb._v_drag_ref.b = leaf.v_bound_above
                wb._drag_strip.forced_height = raise
                wb._drag_strip.cursor = raise > 0 and "sb_v_double_arrow" or nil
                wb.visible = true
            else
                local vsplit_btn = make_circle_icon_btn(icons.vsplit, 36, function() state.focused_leaf_id = leaf_id; split_leaf(t, "h"); awful.layout.arrange(s) end)
                local hsplit_btn = make_circle_icon_btn(icons.hsplit, 36, function() state.focused_leaf_id = leaf_id; split_leaf(t, "v"); awful.layout.arrange(s) end)
                local close_btn  = make_circle_icon_btn(icons.close,  36, function() close_leaf(t, leaf_id); awful.layout.arrange(s) end)

                local launcher_ws = {}
                for _, entry in ipairs(splitwm.launchers) do
                    table.insert(launcher_ws, make_launcher_widget(entry, 30, function()
                        state.focused_leaf_id = leaf_id
                        if entry.action then entry.action() elseif entry.cmd then awful.spawn(entry.cmd) end
                    end))
                end

                local v_drag_ref = { b = leaf.v_bound_above }
                local drag_strip = wibox.widget { forced_height = raise, cursor = raise > 0 and "sb_v_double_arrow" or nil, widget = wibox.container.background }
                drag_strip:buttons(gears.table.join(
                    awful.button({}, 1, function()
                        if not v_drag_ref.b then return end
                        run_v_drag(s, function() return v_drag_ref.b end)
                    end)
                ))

                local bg_widget = wibox.widget {
                    {
                        {
                            { { spacing = 6, layout = wibox.layout.fixed.horizontal, table.unpack(launcher_ws) }, halign = "center", widget = wibox.container.place },
                            { { vsplit_btn, hsplit_btn, close_btn, spacing = 6, layout = wibox.layout.fixed.horizontal }, halign = "center", widget = wibox.container.place },
                            spacing = 15, layout = wibox.layout.fixed.vertical,
                        },
                        halign = "center", valign = "center", widget = wibox.container.place,
                    },
                    bg = bg, shape = function(cr, bw, bh) gears.shape.rounded_rect(cr, bw, bh, 8) end, shape_border_width = 2, shape_border_color = border, widget = wibox.container.background,
                }
                local wb = wibox {
                    screen = s, x = x, y = y, width = w, height = h, bg = "#00000000", border_width = 0, visible = true, ontop = false, type = "utility",
                    widget = wibox.widget { drag_strip, bg_widget, layout = wibox.layout.align.vertical },
                }
                wb._bg_widget = bg_widget; wb._drag_strip = drag_strip; wb._v_drag_ref = v_drag_ref
                wb:buttons(gears.table.join(awful.button({}, 1, function()
                    if picked_up_split and picked_up_split ~= leaf_id then
                        swap_split_tabs(state, picked_up_split, leaf_id)
                        state.focused_leaf_id = leaf_id
                        picked_up_split = nil
                        awful.layout.arrange(s); return
                    end
                    if picked_up_split == leaf_id then picked_up_split = nil; awful.layout.arrange(s); return end
                    if picked_up_client then try_drop_picked_up(t, leaf_id); awful.layout.arrange(s); return end
                    state.focused_leaf_id = leaf_id; awful.layout.arrange(s)
                end)))
                overlay_cache[s][leaf_id] = wb
            end
        end
    end
end

---------------------------------------------------------------------------
-- Titlebars (Wibox based) — helper functions
---------------------------------------------------------------------------

local function on_hover_fg(w, hover_fg, normal_fg)
    w:connect_signal("mouse::enter", function() w.fg = hover_fg end)
    w:connect_signal("mouse::leave", function() w.fg = normal_fg end)
end

local function tb_get_or_create_entry(s, leaf)
    local cache = titlebar_cache[s]
    local entry = cache[leaf.id]
    if entry then return entry end
    entry = {
        wb                = wibox { screen = s, bg = "#00000000", visible = true, ontop = false, type = "utility" },
        tooltip_pool      = {},
        tooltip_pool_n    = 0,
        titlebar_btn_list = {},
        titlebar_hovered  = false,
    }
    entry.wb:connect_signal("mouse::enter", function()
        entry.titlebar_hovered = true
        for _, btn in ipairs(entry.titlebar_btn_list) do btn.bg = "#000000" end
        if entry.swap_btn and not entry.swap_btn_picked then entry.swap_btn.bg = "#000000" end
    end)
    entry.wb:connect_signal("mouse::leave", function()
        entry.titlebar_hovered = false
        for _, btn in ipairs(entry.titlebar_btn_list) do btn.bg = "#00000099" end
        if entry.swap_btn then
            entry.swap_btn.bg = entry.swap_btn_picked and "#7799dd" or "#00000099"
        end
    end)
    cache[leaf.id] = entry
    return entry
end

-- Fingerprint check to prevent unneeded heavy redraws.
-- Tab names are excluded: name changes are handled by the property::name
-- signal handler which updates tooltips directly without a full rebuild.
local function tb_compute_fingerprint(leaf, state)
    local parts = {
        leaf.active_tab,
        state.focused_leaf_id == leaf.id and 1 or 0,
        tostring(leaf.v_bound_above),
        picked_up_split == leaf.id and "S" or "",
    }
    for _, tc in ipairs(leaf.tabs) do
        parts[#parts+1] = tostring(tc.window)
        if picked_up_client and picked_up_client.client == tc then parts[#parts+1] = "P" end
    end
    return table.concat(parts, "\0")
end

local function tb_make_btn(entry, widget_bc, draw_fn, size, callback)
    local w = make_circle_icon_btn_widget(draw_fn, size)
    w.shape_border_color = widget_bc
    w:buttons(gears.table.join(awful.button({}, 1, callback)))
    table.insert(entry.titlebar_btn_list, w)
    return w
end

-- Build the widget for a single tab (icon, move button, close button, shape, tooltip).
local function tb_build_tab_widget(leaf, tc, tab_idx, entry, ctx)
    local is_active = (tab_idx == leaf.active_tab)
    local is_picked = (picked_up_client and picked_up_client.client == tc)

    local tab_icon = awful.widget.clienticon(tc)
    tab_icon.forced_width  = ctx.icon_size
    tab_icon.forced_height = ctx.icon_size

    local move_btn = wibox.widget {
        {
            { text = is_picked and "▼" or "↗", align = "center", font = ctx.tab_btn_font, widget = wibox.widget.textbox },
            bottom = 2, widget = wibox.container.margin,
        },
        bg           = is_picked and "#7799dd" or "#00000000",
        fg           = is_active and "#ffffff" or "#00000000",
        shape        = function(cr, w, h) gears.shape.rounded_rect(cr, w, h, 4) end,
        forced_width = 26,
        widget       = wibox.container.background,
    }
    if is_active then
        move_btn:connect_signal("mouse::enter", function() if not is_picked then move_btn.bg = "#ffffff22" end end)
        move_btn:connect_signal("mouse::leave", function() if not is_picked then move_btn.bg = "#00000000" end end)
        move_btn:buttons(gears.table.join(awful.button({}, 1, function()
            if picked_up_client and picked_up_client.client == tc then
                picked_up_client = nil
            else
                picked_up_client = { client = tc, tag = ctx.t }
            end
            awful.layout.arrange(ctx.s)
        end)))
    end

    local close_btn = wibox.widget {
        { text = "✕", align = "center", font = ctx.tab_btn_font, widget = wibox.widget.textbox },
        bg           = "#00000000",
        fg           = is_active and "#ffffff" or "#00000000",
        shape        = function(cr, w, h) gears.shape.rounded_rect(cr, w, h, 4) end,
        forced_width = 26,
        widget       = wibox.container.background,
    }
    if is_active then
        on_hover_fg(close_btn, "#ff6666", "#ffffff")
        close_btn:buttons(gears.table.join(awful.button({}, 1, function() tc:kill() end)))
    end

    local client_color = colors.get_client_color(tc)
    local tab_bg
    if    is_picked     then tab_bg = "#445566"
    elseif client_color then tab_bg = client_color.dark
    elseif is_active    then tab_bg = beautiful.splitwm_tab_active_bg or "#535d6c"
    else                     tab_bg = beautiful.splitwm_inactive_bg   or "#00000080"
    end
    local tab_bg_pat   = gears.color(tab_bg)
    local widget_bc_pat = gears.color(ctx.widget_bc)

    local tab_draw = wibox.widget.base.make_widget()
    function tab_draw:draw(_, cr, w2, h2)
        local lw, r, pad = 2, 6, 1
        local half = lw / 2
        local fpad, fr = pad + half, r - half
        cr:move_to(fpad, h2)
        cr:line_to(fpad, fr + fpad)
        cr:arc(fr + fpad,      fr + fpad, fr, math.pi,       1.5 * math.pi)
        cr:arc(w2 - fr - fpad, fr + fpad, fr, 1.5 * math.pi, 2   * math.pi)
        cr:line_to(w2 - fpad, h2)
        cr:close_path()
        cr:set_source(tab_bg_pat)
        cr:fill()
        if is_active then
            draw_tab_border(cr, w2, h2)
            cr:set_source(widget_bc_pat)
            cr:set_line_width(lw)
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
            left = 8, right = 6, top = 3, bottom = 3, widget = wibox.container.margin,
        },
        layout = wibox.layout.stack,
    }

    -- Tooltip: reuse slot from pool to avoid leaking objects
    local name = tc.name or "?"
    local slot = entry.tooltip_pool[tab_idx]
    if not slot then
        slot = { tt = awful.tooltip { text = name, delay_show = 0.3, font = "monospace bold 12", bg = "#000000", fg = "#ffffff", border_width = 0 } }
        entry.tooltip_pool[tab_idx] = slot
        if tab_idx > entry.tooltip_pool_n then entry.tooltip_pool_n = tab_idx end
    else
        slot.tt.text = name
        if slot.prev_obj then slot.tt.visible = false; slot.tt:remove_from_object(slot.prev_obj) end
    end
    slot.tt:add_to_object(tab_widget)
    slot.prev_obj = tab_widget

    tab_widget:buttons(gears.table.join(awful.button({}, 1, function()
        if picked_up_split and picked_up_split ~= leaf.id then
            swap_split_tabs(ctx.state, picked_up_split, leaf.id)
            ctx.state.focused_leaf_id = leaf.id
            picked_up_split = nil
            awful.layout.arrange(ctx.s); return
        end
        if picked_up_client and picked_up_client.client.valid and picked_up_client.client ~= tc then
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
    local function make_btn(draw_fn, callback)
        return tb_make_btn(entry, ctx.widget_bc, draw_fn, 26, callback)
    end

    local vsplit_btn = make_btn(icons.vsplit, function()
        ctx.state.focused_leaf_id = leaf.id; split_leaf(ctx.t, "h"); awful.layout.arrange(ctx.s)
    end)
    local hsplit_btn = make_btn(icons.hsplit, function()
        ctx.state.focused_leaf_id = leaf.id; split_leaf(ctx.t, "v"); awful.layout.arrange(ctx.s)
    end)
    local close_split_btn = make_btn(icons.close, function()
        close_leaf(ctx.t, leaf.id); awful.layout.arrange(ctx.s)
    end)
    on_hover_fg(close_split_btn, "#ff6666", "#ffffff")

    local is_split_picked = (picked_up_split == leaf.id)
    local swap_btn = make_circle_icon_btn_widget(icons.swap, 26)
    swap_btn.shape_border_color = ctx.widget_bc
    if is_split_picked then swap_btn.bg = "#7799dd" end
    entry.swap_btn        = swap_btn
    entry.swap_btn_picked = is_split_picked
    swap_btn:buttons(gears.table.join(awful.button({}, 1, function()
        if picked_up_split == leaf.id then
            picked_up_split = nil
        elseif picked_up_split then
            swap_split_tabs(ctx.state, picked_up_split, leaf.id)
            ctx.state.focused_leaf_id = leaf.id
            picked_up_split = nil
        else
            picked_up_split = leaf.id
            ctx.state.focused_leaf_id = leaf.id
        end
        awful.layout.arrange(ctx.s)
    end)))

    return { vsplit = vsplit_btn, hsplit = hsplit_btn, close = close_split_btn, swap = swap_btn }
end

-- Build the focus border drawn around the client area.
local function tb_build_border_widget(border_color, tb_h, bw)
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
        local r    = beautiful.splitwm_focus_border_radius or 2
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
    for i, tw in ipairs(tab_widgets) do
        local ref = tw
        local sp  = wibox.widget.base.make_widget()
        function sp:fit(wctx, w, h) return ref:fit(wctx, w, h) end
        function sp:draw() end
        if i == active_tab then
            table.insert(behind, sp)
            table.insert(above,  tw)
        else
            table.insert(behind, tw)
            table.insert(above,  sp)
        end
    end
    return behind, above
end

-- Assemble the three-layer wibox layout for a leaf's titlebar.
local function tb_assemble_wibox(entry, behind, above, controls, border_draw, middle_drag, ctx)
    entry.wb:setup {
        -- Layer 1: inactive tabs + split controls (behind border)
        {
            {
                {
                    {
                        { spacing = ctx.BTN_SPACING, layout = wibox.layout.fixed.horizontal, table.unpack(behind) },
                        middle_drag,
                        { controls.swap, controls.vsplit, controls.hsplit, controls.close, spacing = ctx.BTN_SPACING, layout = wibox.layout.fixed.horizontal },
                        layout = wibox.layout.align.horizontal,
                    },
                    top = ctx.top_pad, widget = wibox.container.margin,
                },
                bg = ctx.bar_bg, shape = rounded_top, forced_height = ctx.tb_h, widget = wibox.container.background,
            },
            layout = wibox.layout.fixed.vertical,
        },
        -- Layer 2: focus border
        border_draw,
        -- Layer 3: active tab on top of border
        {
            {
                {
                    {
                        { spacing = ctx.BTN_SPACING, layout = wibox.layout.fixed.horizontal, table.unpack(above) },
                        nil, nil,
                        layout = wibox.layout.align.horizontal,
                    },
                    top = ctx.top_pad, widget = wibox.container.margin,
                },
                forced_height = ctx.tb_h, widget = wibox.container.background,
            },
            layout = wibox.layout.fixed.vertical,
        },
        layout = wibox.layout.stack,
    }
end

---------------------------------------------------------------------------
-- Titlebars (Wibox based)
---------------------------------------------------------------------------

local function update_titlebars(s, t, state, geos, leaves)
    if not titlebar_cache[s] then titlebar_cache[s] = {} end

    local gap  = beautiful.splitwm_gap or 16
    local tb_h = math.max(TITLEBAR_HEIGHT, gap)
    local bw   = beautiful.splitwm_focus_border_width or 2
    local alive = {}

    for _, leaf in ipairs(leaves) do
        alive[leaf.id] = true
        if #leaf.tabs == 0 then goto continue end
        local geo = geos[leaf.id]
        if not geo then goto continue end

        local entry = tb_get_or_create_entry(s, leaf)
        local wb = entry.wb
        wb.x       = geo.x
        wb.y       = geo.y - gap
        wb.width   = geo.width
        wb.height  = geo.height + gap
        wb.visible = true

        local fp = tb_compute_fingerprint(leaf, state)
        if entry.fp == fp then goto continue end
        entry.fp              = fp
        entry.titlebar_btn_list = {}

        local is_focused    = state.focused_leaf_id == leaf.id
        local active_client = leaf.tabs[leaf.active_tab]
        local active_color  = active_client and colors.get_client_color(active_client)
        local focus_color   = active_color and active_color.light or beautiful.splitwm_focus_border or "#7799dd"
        local ctx = {
            s            = s,
            t            = t,
            state        = state,
            widget_bc    = is_focused and focus_color or "#00000000",
            bar_bg       = is_focused and (beautiful.titlebar_bg_focus  or "#000000")
                                      or  (beautiful.titlebar_bg_normal or "#000000aa"),
            top_pad      = math.max(gap, TITLEBAR_HEIGHT) - TITLEBAR_HEIGHT,
            tb_h         = tb_h,
            icon_size    = 20,
            tab_btn_font = "monospace bold 18",
            BTN_SPACING  = 5,
        }

        -- Build per-tab widgets
        local tab_widgets = {}
        for i, tc in ipairs(leaf.tabs) do
            table.insert(tab_widgets, tb_build_tab_widget(leaf, tc, i, entry, ctx))
        end

        -- Release stale tooltip slots beyond current tab count
        for i = #leaf.tabs + 1, entry.tooltip_pool_n do
            local slot = entry.tooltip_pool[i]
            if slot then
                if slot.prev_obj then slot.tt.visible = false; slot.tt:remove_from_object(slot.prev_obj) end
                entry.tooltip_pool[i] = nil
            end
        end
        entry.tooltip_pool_n = #leaf.tabs

        -- "+" menu button lives at the end of the tab row
        table.insert(tab_widgets, tb_make_btn(entry, ctx.widget_bc, icons.plus, 26, function()
            ctx.state.focused_leaf_id = leaf.id
            if splitwm.on_menu_request then splitwm.on_menu_request() end
        end))

        local controls    = tb_build_split_controls(leaf, entry, ctx)
        local border_draw = tb_build_border_widget(is_focused and focus_color or nil, tb_h, bw)

        local middle_drag
        if leaf.v_bound_above then
            middle_drag = wibox.widget { cursor = "sb_v_double_arrow", widget = wibox.container.background }
            middle_drag:buttons(gears.table.join(awful.button({}, 1, function()
                if not leaf.v_bound_above then return end
                run_v_drag(s, function() return leaf.v_bound_above end)
            end)))
        end

        local behind, above = tb_split_tab_layers(tab_widgets, leaf.active_tab)
        tb_assemble_wibox(entry, behind, above, controls, border_draw, middle_drag, ctx)

        ::continue::
    end

    -- Hide and clean up entries for dead or empty leaves
    for leaf_id, entry in pairs(titlebar_cache[s]) do
        local leaf = state.leaf_map[leaf_id]
        if not alive[leaf_id] or (leaf and #leaf.tabs == 0) then
            entry.wb.visible = false
            if not alive[leaf_id] then titlebar_cache[s][leaf_id] = nil end
        end
    end
end


---------------------------------------------------------------------------
-- Update drag handles
---------------------------------------------------------------------------

local function update_drag_handles(s, state, bounds)
    local gap      = beautiful.splitwm_gap or 16
    local handle_w = gap - 4
    local hi       = 0

    -- Only "h" bounds (vertical dividers between left/right panes) need a drag strip wibox.
    -- "v" bounds (horizontal dividers between top/bottom panes) are dragged via the titlebar,
    -- which spans the full width of the pane and sits exactly on the vertical gap.
    for _, b in ipairs(bounds) do
        if b.dir == "h" then
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
            if not ref.dragging then wb.bg = "#00000000" end
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

local function update_ui(s)
    local t, state = get_active_state(s)
    if not t then
        local pool = drag_handle_pool[s]
        if pool then for _, entry in ipairs(pool) do entry.wb.visible = false end end
        if overlay_cache[s]  then for _, wb    in pairs(overlay_cache[s])  do wb.visible = false    end end
        if titlebar_cache[s] then for _, entry in pairs(titlebar_cache[s]) do entry.wb.visible = false end end
        return
    end

    local gap    = beautiful.splitwm_gap or 16
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
    update_overlays(s, t, state, geos, leaves)
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

splitwm.split_horizontal = function() with_tag(function(t) split_leaf(t, "h") end) end
splitwm.split_vertical   = function() with_tag(function(t) split_leaf(t, "v") end) end
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
    if picked_up_client or picked_up_split then
        picked_up_client = nil
        picked_up_split  = nil
        awful.layout.arrange(awful.screen.focused())
    end
end

---------------------------------------------------------------------------
-- Setup & Caches
---------------------------------------------------------------------------

function splitwm.setup()
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
        if picked_up_client and picked_up_client.client == c then picked_up_client = nil end
        for t, state in pairs(tag_state) do unpin_client(state.root, c) end
    end)

    client.connect_signal("focus", function(c)
        local t, state = get_tag_state(c)
        if not state then return end
        local leaf = tree.find_leaf_for_client(state.root, c)
        if leaf and leaf.id ~= state.focused_leaf_id then
            state.focused_leaf_id = leaf.id
            awful.layout.arrange(c.screen)
        end
    end)

    client.connect_signal("button::press", function(c)
        local t, state = get_tag_state(c)
        if not state then return end
        if picked_up_split then
            local target_leaf = tree.find_leaf_for_client(state.root, c)
            if target_leaf and target_leaf.id ~= picked_up_split then
                swap_split_tabs(state, picked_up_split, target_leaf.id)
                state.focused_leaf_id = target_leaf.id
                picked_up_split = nil
                awful.layout.arrange(c.screen); return
            end
        end
        if picked_up_client and picked_up_client.client.valid and picked_up_client.client ~= c then
            local target_leaf = tree.find_leaf_for_client(state.root, c)
            if target_leaf then try_drop_picked_up(t, target_leaf.id); awful.layout.arrange(c.screen); return end
        end
        local leaf = tree.find_leaf_for_client(state.root, c)
        if leaf and leaf.id ~= state.focused_leaf_id then
            state.focused_leaf_id = leaf.id
            awful.layout.arrange(c.screen)
        end
    end)

    client.connect_signal("property::name", function(c)
        -- Update only the affected tooltip in-place; no full widget rebuild needed.
        local entry, leaf = get_titlebar_entry(c)
        if not entry then return end
        for i, tc in ipairs(leaf.tabs) do
            if tc == c then
                local slot = entry.tooltip_pool[i]
                if slot then slot.tt.text = c.name or "?" end
                break
            end
        end
    end)

    tag.connect_signal("property::selected", function(t)
        local s = t.screen
        if type(s) == "number" then s = screen[s] end
        -- Splits are tag-local; cancel any pending swap so the leaf ID
        -- doesn't silently fail to resolve on the newly selected tag.
        picked_up_split = nil
        if s then geo_cache[s] = nil; gears.timer.delayed_call(function() update_ui(s) end) end
    end)
end

function splitwm.flush_caches()
    for _, screen_cache in pairs(overlay_cache) do
        for _, wb in pairs(screen_cache) do wb.visible = false end
    end
    overlay_cache = {}
    for _, screen_cache in pairs(titlebar_cache) do
        for _, entry in pairs(screen_cache) do
            -- Detach tooltips before dropping the entry so their signal
            -- connections don't keep the old tab widgets alive.
            for _, slot in pairs(entry.tooltip_pool) do
                if slot and slot.prev_obj then
                    slot.tt.visible = false
                    slot.tt:remove_from_object(slot.prev_obj)
                end
            end
            entry.wb.visible = false
        end
    end
    titlebar_cache = {}
end

splitwm.get_state = get_state
splitwm.collect_leaves = tree.collect_leaves

return splitwm