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

local splitwm = {}

-- Base height of the tab bar.
local TITLEBAR_HEIGHT = 33

---------------------------------------------------------------------------
-- App launchers (configurable from rc.lua via splitwm.launchers)
---------------------------------------------------------------------------
splitwm.launchers = {}  -- set from rc.lua before calling setup()

local picked_up_client = nil

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

local function make_circle_icon_btn_widget(draw_fn, size)
    local icon = wibox.widget.base.make_widget()
    function icon:draw(_, cr, w, h)
        cr:set_source_rgba(1, 1, 1, 0.85)
        cr:set_line_width(2)
        cr:set_line_cap(1) -- ROUND
        draw_fn(cr, w, h)
    end
    function icon:fit(_, w, h) return w, h end
    return wibox.widget {
        icon,
        bg                 = beautiful.splitwm_inactive_bg or "#00000080",
        shape              = gears.shape.circle,
        shape_border_width = 2,
        shape_border_color = beautiful.splitwm_widget_border or "#ffffff30",
        forced_width       = size,
        forced_height      = size,
        widget             = wibox.container.background,
    }
end

local function make_circle_btn(label, size, callback)
    local w = make_circle_btn_widget(label, size)
    w:connect_signal("mouse::enter", function() w.bg = "#00000080" end)
    w:connect_signal("mouse::leave", function() w.bg = beautiful.splitwm_inactive_bg or "#00000080" end)
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

local function icon_plus(cr, w, h)
    local cx, cy, s = w/2, h/2, 4
    cr:move_to(cx-s, cy); cr:line_to(cx+s, cy); cr:stroke()
    cr:move_to(cx, cy-s); cr:line_to(cx, cy+s); cr:stroke()
end

local function icon_vsplit(cr, w, h)
    local cx, cy, bw, bh, br = w/2, h/2, 10, 8, 1
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

local function icon_hsplit(cr, w, h)
    local cx, cy, bw, bh, br = w/2, h/2, 10, 8, 1
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

local function icon_close(cr, w, h)
    local cx, cy, s = w/2, h/2, 4
    cr:move_to(cx-s, cy-s); cr:line_to(cx+s, cy+s); cr:stroke()
    cr:move_to(cx+s, cy-s); cr:line_to(cx-s, cy+s); cr:stroke()
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
-- Split node data model
---------------------------------------------------------------------------

local next_id = 1
local function gen_id()
    local id = next_id
    next_id = next_id + 1
    return id
end

local function make_leaf()
    return {
        type = "leaf",
        id   = gen_id(),
        tabs = {},
        active_tab = 0,
    }
end

local function make_branch(direction, ratio, child_a, child_b)
    return {
        type      = "branch",
        direction = direction,
        ratio     = ratio or 0.5,
        children  = { child_a, child_b },
    }
end

---------------------------------------------------------------------------
-- Tree traversal helpers
---------------------------------------------------------------------------

local function collect_leaves(node, out)
    out = out or {}
    if node.type == "leaf" then
        table.insert(out, node)
    else
        collect_leaves(node.children[1], out)
        collect_leaves(node.children[2], out)
    end
    return out
end

local function find_leaf_for_client(node, c)
    if node.type == "leaf" then
        for _, tab_c in ipairs(node.tabs) do
            if tab_c == c then return node end
        end
        return nil
    else
        return find_leaf_for_client(node.children[1], c)
            or find_leaf_for_client(node.children[2], c)
    end
end

local function find_leaf_by_id(node, id)
    if node.type == "leaf" then
        return node.id == id and node or nil
    else
        return find_leaf_by_id(node.children[1], id)
            or find_leaf_by_id(node.children[2], id)
    end
end

local function find_parent(root, target)
    if root.type == "leaf" then return nil, nil end
    for i, child in ipairs(root.children) do
        if child == target then return root, i end
        local p, idx = find_parent(child, target)
        if p then return p, idx end
    end
    return nil, nil
end

local function find_focused_leaf(root, focused_client)
    if focused_client then
        local leaf = find_leaf_for_client(root, focused_client)
        if leaf then return leaf end
    end
    local leaves = collect_leaves(root)
    return leaves[1]
end

---------------------------------------------------------------------------
-- Geometry computation
---------------------------------------------------------------------------

local function compute_tree_inner(node, x, y, w, h, gap, geos, bounds, v_bound_above)
    if node.type == "leaf" then
        if geos then geos[node.id] = { x = x, y = y, width = w, height = h } end
        if bounds ~= nil then node.v_bound_above = v_bound_above end
        return
    end
    local dir, ratio, inner = node.direction, node.ratio, gap
    if dir == "h" then
        local usable = w - inner
        local w1 = math.floor(usable * ratio)
        if bounds then
            table.insert(bounds, { branch = node, dir = "h", pos = x + w1 + math.floor(inner / 2),
                start = y, span = h, parent_x = x, parent_w = w, parent_gap = inner })
        end
        compute_tree_inner(node.children[1], x,          y, w1,        h, gap, geos, bounds, v_bound_above)
        compute_tree_inner(node.children[2], x+w1+inner, y, usable-w1, h, gap, geos, bounds, v_bound_above)
    else
        local usable = h - inner
        local h1 = math.floor(usable * ratio)
        local bnd
        if bounds then
            bnd = { branch = node, dir = "v", pos = y + h1 + math.floor(inner / 2),
                start = x, span = w, parent_y = y, parent_h = h, parent_gap = inner }
            table.insert(bounds, bnd)
        end
        compute_tree_inner(node.children[1], x, y,          w, h1,        gap, geos, bounds, v_bound_above)
        compute_tree_inner(node.children[2], x, y+h1+inner, w, usable-h1, gap, geos, bounds, bnd)
    end
end

local function compute_tree(node, x, y, w, h, gap, geos, bounds)
    compute_tree_inner(node, x+gap, y+gap, w-2*gap, h-2*gap, gap, geos, bounds, nil)
end

local function compute_geometries(node, x, y, w, h, gap)
    local geos = {}; compute_tree(node, x, y, w, h, gap, geos, nil); return geos
end

---------------------------------------------------------------------------
-- Per-tag state
---------------------------------------------------------------------------

local tag_state = setmetatable({}, { __mode = "k" })

local function get_state(t)
    if not tag_state[t] then
        local root = make_leaf()
        tag_state[t] = { root = root, focused_leaf_id = root.id }
    end
    return tag_state[t]
end

---------------------------------------------------------------------------
-- Client management
---------------------------------------------------------------------------

local function pin_client(t, c)
    local state = get_state(t)
    local leaf = find_leaf_by_id(state.root, state.focused_leaf_id)
    if not leaf then leaf = collect_leaves(state.root)[1] end
    for _, tc in ipairs(leaf.tabs) do if tc == c then return end end
    table.insert(leaf.tabs, c)
    leaf.active_tab = #leaf.tabs
end

local function unpin_client(root, c)
    local leaf = find_leaf_for_client(root, c)
    if not leaf then return end
    for i, tc in ipairs(leaf.tabs) do
        if tc == c then
            table.remove(leaf.tabs, i)
            if leaf.active_tab > #leaf.tabs then leaf.active_tab = math.max(1, #leaf.tabs) end
            if #leaf.tabs == 0 then leaf.active_tab = 0 end
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

local function try_drop_picked_up(t, leaf_id)
    if not picked_up_client then return false end
    if not picked_up_client.client.valid then picked_up_client = nil; return false end
    local state = get_state(t)
    local target = find_leaf_by_id(state.root, leaf_id)
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

    if src_tag and src_tag ~= t and src_tag.screen then awful.layout.arrange(src_tag.screen) end
    return true
end

---------------------------------------------------------------------------
-- Split operations
---------------------------------------------------------------------------

local function split_leaf(t, direction)
    local state = get_state(t)
    local leaf = find_leaf_by_id(state.root, state.focused_leaf_id)
    if not leaf then return false end

    local child_a = make_leaf()
    child_a.tabs = leaf.tabs
    child_a.active_tab = leaf.active_tab
    local child_b = make_leaf()

    leaf.type = "branch"
    leaf.direction = direction
    leaf.ratio = 0.5
    leaf.children = { child_a, child_b }
    leaf.tabs = nil
    leaf.active_tab = nil
    state.focused_leaf_id = child_a.id
end

local function close_leaf(t, leaf_id)
    local state = get_state(t)
    local leaf = find_leaf_by_id(state.root, leaf_id)
    if not leaf then return false end
    local leaves = collect_leaves(state.root)
    if #leaves <= 1 then return false end

    local parent, idx = find_parent(state.root, leaf)
    if not parent then return false end

    local sibling_idx = idx == 1 and 2 or 1
    local sibling = parent.children[sibling_idx]

    parent.type = sibling.type
    parent.direction = sibling.direction
    parent.ratio = sibling.ratio
    parent.children = sibling.children
    parent.tabs = sibling.tabs
    parent.active_tab = sibling.active_tab
    parent.id = sibling.id

    local new_leaves = collect_leaves(parent)
    if new_leaves[1] then state.focused_leaf_id = new_leaves[1].id end
end

local function resize_focused(t, delta)
    local state = get_state(t)
    local leaf = find_leaf_by_id(state.root, state.focused_leaf_id)
    if not leaf then return false end
    local parent, idx = find_parent(state.root, leaf)
    if not parent then return false end
    local new_ratio = parent.ratio
    if idx == 1 then new_ratio = new_ratio + delta else new_ratio = new_ratio - delta end
    parent.ratio = math.max(0.1, math.min(0.9, new_ratio))
end

---------------------------------------------------------------------------
-- Tab & Focus operations
---------------------------------------------------------------------------

local function cycle_tab(t, offset)
    local state = get_state(t)
    local leaf = find_leaf_by_id(state.root, state.focused_leaf_id)
    if not leaf or #leaf.tabs == 0 then return false end
    leaf.active_tab = ((leaf.active_tab - 1 + offset) % #leaf.tabs) + 1
end

local function adjacent_leaf(state, leaf_id, dir)
    local leaves = collect_leaves(state.root)
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
    local src_leaf = find_leaf_by_id(state.root, state.focused_leaf_id)
    if not src_leaf or #src_leaf.tabs == 0 then return false end
    local dst_leaf = adjacent_leaf(state, src_leaf.id, dir)
    if not dst_leaf then return false end

    local c = src_leaf.tabs[src_leaf.active_tab]
    table.remove(src_leaf.tabs, src_leaf.active_tab)
    if src_leaf.active_tab > #src_leaf.tabs then src_leaf.active_tab = math.max(0, #src_leaf.tabs) end
    table.insert(dst_leaf.tabs, c)
    dst_leaf.active_tab = #dst_leaf.tabs
end

local function focus_direction(t, dir)
    local state = get_state(t)
    local leaf = adjacent_leaf(state, state.focused_leaf_id, dir)
    if not leaf then return false end
    state.focused_leaf_id = leaf.id
end

---------------------------------------------------------------------------
-- The layout "arrange" function
---------------------------------------------------------------------------

local function arrange(p)
    local tag = p.tag or awful.screen.focused().selected_tag
    if not tag then return end
    local state = get_state(tag)
    local wa    = p.workarea
    local cls   = p.clients
    local gap   = beautiful.splitwm_gap or 16

    local root = state.root
    local pinned = {}
    for _, leaf in ipairs(collect_leaves(root)) do
        for _, tc in ipairs(leaf.tabs) do pinned[tc] = true end
    end
    for _, c in ipairs(cls) do
        if not pinned[c] then pin_client(tag, c) end
    end

    local geos = compute_geometries(root, wa.x, wa.y, wa.width, wa.height, gap)
    local bw   = beautiful.splitwm_focus_border_width or 2
    local tb_h = math.max(TITLEBAR_HEIGHT, gap)

    for _, leaf in ipairs(collect_leaves(root)) do
        local new_tabs = {}
        for _, tc in ipairs(leaf.tabs) do
            if tc.valid then table.insert(new_tabs, tc) end
        end
        leaf.tabs = new_tabs
        if leaf.active_tab > #leaf.tabs then leaf.active_tab = math.max(0, #leaf.tabs) end
        if #leaf.tabs == 0 then leaf.active_tab = 0 end

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

local focus_border_pool = {}
local function get_focus_border(s)
    if focus_border_pool[s] then return focus_border_pool[s] end
    local sides = {}
    for _ = 1, 4 do
        table.insert(sides, wibox {
            screen = s, x = 0, y = 0, width = 1, height = 1,
            bg = beautiful.splitwm_focus_border or "#7799dd", border_width = 0,
            visible = false, ontop = true, type = "utility", input_passthrough = true,
        })
    end
    focus_border_pool[s] = sides
    return sides
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

---------------------------------------------------------------------------
-- Update Overlays (empty split placeholders)
---------------------------------------------------------------------------

local function update_overlays(s, t, state, geos)
    local focus_bw = beautiful.splitwm_focus_border_width or 2
    local gap      = beautiful.splitwm_gap or 16
    if not overlay_cache[s] then overlay_cache[s] = {} end

    local needed, alive = {}, {}
    for _, leaf in ipairs(collect_leaves(state.root)) do
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
            local border = "#00000066"

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
                local vsplit_btn = make_circle_btn("│", 36, function() state.focused_leaf_id = leaf_id; split_leaf(t, "h"); awful.layout.arrange(s) end)
                local hsplit_btn = make_circle_btn("─", 36, function() state.focused_leaf_id = leaf_id; split_leaf(t, "v"); awful.layout.arrange(s) end)
                local close_btn  = make_circle_btn("✕", 36, function() close_leaf(t, leaf_id); awful.layout.arrange(s) end)

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
                        local b = v_drag_ref.b
                        if not b then return end
                        mousegrabber.run(function(mouse)
                            if not mouse.buttons[1] then awful.layout.arrange(s); return false end
                            local igap = b.parent_gap or 0
                            b.branch.ratio = math.max(0.1, math.min(0.9, (mouse.y - b.parent_y) / (b.parent_h - igap)))
                            awful.layout.arrange(s)
                            return true
                        end, "sb_v_double_arrow")
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
                    if picked_up_client then try_drop_picked_up(t, leaf_id); awful.layout.arrange(s); return end
                    state.focused_leaf_id = leaf_id; awful.layout.arrange(s)
                end)))
                overlay_cache[s][leaf_id] = wb
            end
        end
    end
end

---------------------------------------------------------------------------
-- Titlebars (Wibox based)
---------------------------------------------------------------------------

local function update_titlebars(s, t, state, geos)
    if not titlebar_cache[s] then titlebar_cache[s] = {} end

    local gap      = beautiful.splitwm_gap or 16
    local tb_h     = math.max(TITLEBAR_HEIGHT, gap)
    local bw       = beautiful.splitwm_focus_border_width or 2
    local alive    = {}
    local BTN_SPACING = 5

    for _, leaf in ipairs(collect_leaves(state.root)) do
        alive[leaf.id] = true
        if #leaf.tabs > 0 then
            local geo = geos[leaf.id]
            if geo then
                local entry = titlebar_cache[s][leaf.id]
                if not entry then
                    entry = {
                        wb = wibox {
                            screen  = s,
                            bg      = "#00000000",
                            visible = true,
                            ontop   = false,
                            type    = "utility",
                        },
                        tooltip_pool      = {},
                        titlebar_btn_list = {},
                        titlebar_hovered  = false,
                    }
                    entry.wb:connect_signal("mouse::enter", function()
                        entry.titlebar_hovered = true
                        for _, btn in ipairs(entry.titlebar_btn_list) do btn.bg = "#000000" end
                    end)
                    entry.wb:connect_signal("mouse::leave", function()
                        entry.titlebar_hovered = false
                        for _, btn in ipairs(entry.titlebar_btn_list) do btn.bg = "#00000099" end
                    end)
                    titlebar_cache[s][leaf.id] = entry
                end

                local wb = entry.wb
                wb.x      = geo.x
                wb.y      = geo.y - gap
                wb.width  = geo.width
                wb.height = geo.height + gap
                wb.bg     = "#00000000"
                wb.visible = true

                -- Fingerprint check to prevent unneeded heavy redraws
                local fp_parts = { leaf.active_tab, state.focused_leaf_id == leaf.id and 1 or 0, tostring(leaf.v_bound_above) }
                for _, tc in ipairs(leaf.tabs) do
                    fp_parts[#fp_parts+1] = tostring(tc.window)
                    fp_parts[#fp_parts+1] = tc.name or "?"
                    if picked_up_client and picked_up_client.client == tc then fp_parts[#fp_parts+1] = "P" end
                end
                local fp = table.concat(fp_parts, "\0")

                if entry.fp ~= fp then
                    entry.fp = fp
                    entry.titlebar_btn_list = {}

                    local is_focused   = state.focused_leaf_id == leaf.id
                    local widget_bc    = is_focused and (beautiful.splitwm_focus_border or "#7799dd") or "#00000000"

                    local function make_tb_btn(draw_fn, size, callback)
                        local w = make_circle_icon_btn_widget(draw_fn, size)
                        w.shape_border_color = widget_bc
                        w:connect_signal("mouse::enter", function() w.bg = "#333333" end)
                        w:connect_signal("mouse::leave", function()
                            w.bg = entry.titlebar_hovered and "#000000" or (beautiful.splitwm_inactive_bg or "#00000080")
                        end)
                        w:buttons(gears.table.join(awful.button({}, 1, callback)))
                        table.insert(entry.titlebar_btn_list, w)
                        return w
                    end

                    local tab_widgets = {}
                    local tab_btn_font = "monospace bold 14"
                    local icon_size = 20

                    for i, tc in ipairs(leaf.tabs) do
                        local name = tc.name or "?"
                        local is_active = (i == leaf.active_tab)
                        local tab_client = tc
                        local tab_idx = i
                        local is_picked = (picked_up_client and picked_up_client.client == tc)

                        local tab_icon = awful.widget.clienticon(tc)
                        tab_icon.forced_width = icon_size
                        tab_icon.forced_height = icon_size
                        tab_icon:buttons(gears.table.join(
                            awful.button({}, 1, function()
                                if picked_up_client and picked_up_client.client ~= tc then
                                    try_drop_picked_up(t, leaf.id)
                                    awful.layout.arrange(s)
                                    return
                                end
                                leaf.active_tab = tab_idx
                                awful.layout.arrange(s)
                            end)
                        ))

                        local move_btn = wibox.widget {
                            {
                                text   = is_picked and "▼" or "↗",
                                align  = "center",
                                font   = tab_btn_font,
                                widget = wibox.widget.textbox,
                            },
                            bg           = is_picked and "#7799dd" or "#00000000",
                            fg           = "#ffffff",
                            shape        = function(cr, bw2, bh) gears.shape.rounded_rect(cr, bw2, bh, 4) end,
                            forced_width = 24,
                            widget = wibox.container.background,
                        }
                        move_btn:connect_signal("mouse::enter", function() if not is_picked then move_btn.bg = "#ffffff22" end end)
                        move_btn:connect_signal("mouse::leave", function() if not is_picked then move_btn.bg = "#00000000" end end)
                        move_btn:buttons(gears.table.join(
                            awful.button({}, 1, function()
                                if picked_up_client and picked_up_client.client == tab_client then
                                    picked_up_client = nil
                                else
                                    picked_up_client = { client = tab_client, tag = t }
                                end
                                awful.layout.arrange(s)
                            end)
                        ))

                        local close_btn = wibox.widget {
                            {
                                text   = "✕",
                                align  = "center",
                                font   = tab_btn_font,
                                widget = wibox.widget.textbox,
                            },
                            bg           = "#00000000",
                            fg           = "#ffffff",
                            shape        = function(cr, bw2, bh) gears.shape.rounded_rect(cr, bw2, bh, 4) end,
                            forced_width = 24,
                            widget = wibox.container.background,
                        }
                        close_btn:connect_signal("mouse::enter", function() close_btn.fg = "#ff6666" end)
                        close_btn:connect_signal("mouse::leave", function() close_btn.fg = "#ffffff" end)
                        close_btn:buttons(gears.table.join(awful.button({}, 1, function() tab_client:kill() end)))

                        local tab_bg = is_picked and "#445566"
                            or (is_active and (beautiful.splitwm_tab_active_bg or "#535d6c")
                                          or  (beautiful.splitwm_inactive_bg or "#00000080"))

                        local tab_draw = wibox.widget.base.make_widget()
                        function tab_draw:draw(_, cr, w2, h2)
                            local lw, r, pad = 2, 6, 1
                            local half = lw / 2
                            local fp, fr = pad + half, r - half
                            cr:move_to(fp, h2)
                            cr:line_to(fp, fr + fp)
                            cr:arc(fr + fp,       fr + fp, fr, math.pi,       1.5 * math.pi)
                            cr:arc(w2 - fr - fp,  fr + fp, fr, 1.5 * math.pi, 2   * math.pi)
                            cr:line_to(w2 - fp, h2)
                            cr:close_path()
                            cr:set_source(gears.color(tab_bg))
                            cr:fill()
                            draw_tab_border(cr, w2, h2)
                            cr:set_source(gears.color(widget_bc))
                            cr:set_line_width(lw)
                            cr:stroke()
                        end
                        function tab_draw:fit(_, _, _) return 0, 0 end
                        local tab_widget = wibox.widget {
                            tab_draw,
                            {
                                {
                                    { tab_icon, halign = "center", valign = "center", widget = wibox.container.place },
                                    move_btn, close_btn, spacing = 2, layout  = wibox.layout.fixed.horizontal,
                                },
                                left = 4, right = 2, top = 3, bottom = 3,
                                widget = wibox.container.margin,
                            },
                            layout = wibox.layout.stack,
                        }

                        local slot = entry.tooltip_pool[i]
                        if not slot then
                            slot = {
                                tt = awful.tooltip { text = name, delay_show = 0.3, font = "monospace bold 12", bg = "#000000", fg = "#ffffff", border_width = 0 },
                            }
                            entry.tooltip_pool[i] = slot
                        else
                            slot.tt.text = name
                            if slot.prev_obj then slot.tt:remove_from_object(slot.prev_obj); slot.tt.visible = false end
                        end
                        slot.tt:add_to_object(tab_widget)
                        slot.prev_obj = tab_widget

                        table.insert(tab_widgets, tab_widget)
                    end

                    for i = #leaf.tabs + 1, #entry.tooltip_pool do
                        local slot = entry.tooltip_pool[i]
                        if slot and slot.prev_obj then
                            slot.tt:remove_from_object(slot.prev_obj); slot.tt.visible = false; slot.prev_obj = nil
                        end
                    end

                    local menu_btn = make_tb_btn(icon_plus, 26, function() state.focused_leaf_id = leaf.id; if splitwm.on_menu_request then splitwm.on_menu_request() end end)
                    table.insert(tab_widgets, menu_btn)

                    local vsplit_btn = make_tb_btn(icon_vsplit, 26, function() state.focused_leaf_id = leaf.id; split_leaf(t, "h"); awful.layout.arrange(s) end)
                    local hsplit_btn = make_tb_btn(icon_hsplit, 26, function() state.focused_leaf_id = leaf.id; split_leaf(t, "v"); awful.layout.arrange(s) end)
                    local close_split_btn = make_tb_btn(icon_close, 26, function() close_leaf(t, leaf.id); awful.layout.arrange(s) end)
                    close_split_btn:connect_signal("mouse::enter", function() close_split_btn.fg = "#ff6666" end)
                    close_split_btn:connect_signal("mouse::leave", function() close_split_btn.fg = "#ffffff" end)

                    local bar_bg = (state.focused_leaf_id == leaf.id)
                        and (beautiful.titlebar_bg_focus  or "#000000")
                        or  (beautiful.titlebar_bg_normal or "#000000aa")

                    local middle_drag
                    if leaf.v_bound_above then
                        middle_drag = wibox.widget { cursor = "sb_v_double_arrow", widget = wibox.container.background }
                        middle_drag:buttons(gears.table.join(
                            awful.button({}, 1, function()
                                local b = leaf.v_bound_above
                                if not b then return end
                                mousegrabber.run(function(mouse)
                                    if not mouse.buttons[1] then awful.layout.arrange(s); return false end
                                    local igap = b.parent_gap or 0
                                    b.branch.ratio = math.max(0.1, math.min(0.9, (mouse.y - b.parent_y) / (b.parent_h - igap)))
                                    awful.layout.arrange(s)
                                    return true
                                end, "sb_v_double_arrow")
                            end)
                        ))
                    end

                    local top_pad = math.max(gap, TITLEBAR_HEIGHT) - TITLEBAR_HEIGHT

                    local border_color = is_focused and (beautiful.splitwm_focus_border or "#7799dd") or nil
                    local border_draw = wibox.widget.base.make_widget()
                    border_draw._bc   = border_color
                    border_draw._tb_h = tb_h
                    border_draw._bw   = bw
                    function border_draw:draw(_, cr, width, height)
                        if not self._bc then return end
                        cr:set_source(gears.color(self._bc))
                        cr:set_line_width(self._bw)
                        local half = self._bw / 2
                        local x    = half
                        local y    = self._tb_h - half
                        local w    = width - self._bw
                        local h    = height - self._tb_h
                        local r    = beautiful.splitwm_focus_border_radius or 2
                        cr:new_sub_path()
                        cr:arc(x + w - r, y + r,     r, -math.pi / 2, 0)
                        cr:arc(x + w - r, y + h - r, r,  0,           math.pi / 2)
                        cr:arc(x + r,     y + h - r, r,  math.pi / 2, math.pi)
                        cr:arc(x + r,     y + r,     r,  math.pi,     3 * math.pi / 2)
                        cr:close_path()
                        cr:stroke()
                    end
                    function border_draw:fit(_, w, h) return w, h end

                    -- Split tab_widgets: active tab goes to top layer, rest to bottom layer
                    local behind_tabs, above_tabs = {}, {}
                    for i, tw in ipairs(tab_widgets) do
                        local ref = tw
                        local sp  = wibox.widget.base.make_widget()
                        function sp:fit(ctx, w, h) return ref:fit(ctx, w, h) end
                        function sp:draw() end
                        if i == leaf.active_tab then
                            table.insert(behind_tabs, sp)
                            table.insert(above_tabs,  tw)
                        else
                            table.insert(behind_tabs, tw)
                            table.insert(above_tabs,  sp)
                        end
                    end

                    entry.wb:setup {
                        -- Layer 1: inactive tabs + split controls (behind border)
                        {
                            {
                                {
                                    {
                                        { spacing = BTN_SPACING, layout  = wibox.layout.fixed.horizontal, table.unpack(behind_tabs) },
                                        middle_drag,
                                        { { vsplit_btn, hsplit_btn, close_split_btn, spacing = BTN_SPACING, layout  = wibox.layout.fixed.horizontal }, right  = 0, widget = wibox.container.margin },
                                        layout = wibox.layout.align.horizontal,
                                    },
                                    top    = top_pad,
                                    widget = wibox.container.margin,
                                },
                                bg     = bar_bg, shape  = rounded_top, forced_height = tb_h, widget = wibox.container.background,
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
                                        { spacing = BTN_SPACING, layout  = wibox.layout.fixed.horizontal, table.unpack(above_tabs) },
                                        nil, nil,
                                        layout = wibox.layout.align.horizontal,
                                    },
                                    top    = top_pad,
                                    widget = wibox.container.margin,
                                },
                                forced_height = tb_h, widget = wibox.container.background,
                            },
                            layout = wibox.layout.fixed.vertical,
                        },
                        layout = wibox.layout.stack,
                    }
                end
            end
        end
    end

    for leaf_id, entry in pairs(titlebar_cache[s]) do
        local leaf = find_leaf_by_id(state.root, leaf_id)
        if not alive[leaf_id] or (leaf and #leaf.tabs == 0) then
            entry.wb.visible = false
            if not alive[leaf_id] then titlebar_cache[s][leaf_id] = nil end
        end
    end
end

---------------------------------------------------------------------------
-- Update focus border
---------------------------------------------------------------------------

local function update_focus_border(s, state, geos, gap)
    local sides = get_focus_border(s)
    local leaf = find_leaf_by_id(state.root, state.focused_leaf_id)
    local geo  = leaf and geos[leaf.id]
    if not geo then
        for _, wb in ipairs(sides) do wb.visible = false end
        return
    end

    local bw      = beautiful.splitwm_focus_border_width or 2
    local bc      = beautiful.splitwm_focus_border       or "#7799dd"
    local has_win = leaf.tabs and #leaf.tabs > 0
    -- Frame wibox handles the border when the split has windows
    if has_win then
        for _, wb in ipairs(sides) do wb.visible = false end
        return
    end
    local gy      = has_win and (geo.y - gap) or geo.y
    local gh      = has_win and (geo.height + gap) or geo.height
    local tb_h    = has_win and math.max(TITLEBAR_HEIGHT, gap) or 0
    local side_y  = gy + tb_h
    local side_h  = gh - tb_h - bw
    local rects = {
        { x = geo.x,              y = gy,           width = geo.width, height = bw },
        { x = geo.x,              y = gy + gh - bw, width = geo.width, height = bw },
        { x = geo.x,              y = side_y,       width = bw,        height = side_h },
        { x = geo.x + geo.width - bw, y = side_y,  width = bw,        height = side_h },
    }
    for i, r in ipairs(rects) do
        local wb = sides[i]
        if i == 1 and has_win then
            wb.visible = false
        else
            wb.bg      = bc
            wb.x       = r.x
            wb.y       = r.y
            wb.width   = math.max(1, r.width)
            wb.height  = math.max(1, r.height)
            wb.visible = true
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
        local sides = focus_border_pool[s]
        if sides then for _, wb in ipairs(sides) do wb.visible = false end end
        local pool = drag_handle_pool[s]
        if pool then for _, entry in ipairs(pool) do entry.wb.visible = false end end
        if overlay_cache[s] then for _, wb in pairs(overlay_cache[s]) do wb.visible = false end end
        if titlebar_cache[s] then for _, entry in pairs(titlebar_cache[s]) do entry.wb.visible = false end end
        return
    end

    local wa     = s.workarea
    local gap    = beautiful.splitwm_gap or 16
    local geos   = {}
    local bounds = {}
    compute_tree(state.root, wa.x, wa.y, wa.width, wa.height, gap, geos, bounds)

    update_overlays(s, t, state, geos)
    update_titlebars(s, t, state, geos)
    update_focus_border(s, state, geos, gap)
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
    if picked_up_client then
        picked_up_client = nil
        awful.layout.arrange(awful.screen.focused())
    end
end

---------------------------------------------------------------------------
-- Setup & Caches
---------------------------------------------------------------------------

function splitwm.setup()
    client.connect_signal("manage", function(c)
        local t = c.first_tag
        if not t then return end
        local state = get_state(t)
        if not find_leaf_for_client(state.root, c) then pin_client(t, c) end
    end)

    client.connect_signal("unmanage", function(c)
        for t, state in pairs(tag_state) do unpin_client(state.root, c) end
    end)

    client.connect_signal("focus", function(c)
        local t = c.first_tag
        if not t then return end
        local state = tag_state[t]
        if not state then return end
        local leaf = find_leaf_for_client(state.root, c)
        if leaf and leaf.id ~= state.focused_leaf_id then
            state.focused_leaf_id = leaf.id
            awful.layout.arrange(c.screen)
        end
    end)

    client.connect_signal("button::press", function(c)
        local t = c.first_tag
        if not t then return end
        local state = tag_state[t]
        if not state then return end
        if picked_up_client and picked_up_client.client.valid and picked_up_client.client ~= c then
            local target_leaf = find_leaf_for_client(state.root, c)
            if target_leaf then try_drop_picked_up(t, target_leaf.id); awful.layout.arrange(c.screen); return end
        end
        local leaf = find_leaf_for_client(state.root, c)
        if leaf and leaf.id ~= state.focused_leaf_id then
            state.focused_leaf_id = leaf.id
            awful.layout.arrange(c.screen)
        end
    end)

    client.connect_signal("property::name", function(c)
        if c.screen then gears.timer.delayed_call(function() update_ui(c.screen) end) end
    end)

    tag.connect_signal("property::selected", function(t)
        local s = t.screen
        if type(s) == "number" then s = screen[s] end
        if s then gears.timer.delayed_call(function() update_ui(s) end) end
    end)
end

function splitwm.flush_caches()
    for _, screen_cache in pairs(overlay_cache) do for _, wb in pairs(screen_cache) do wb.visible = false end end
    overlay_cache = {}
    
    for _, screen_cache in pairs(titlebar_cache) do for _, entry in pairs(screen_cache) do entry.wb.visible = false end end
    titlebar_cache = {}
end

splitwm.get_state = get_state
splitwm.collect_leaves = collect_leaves

return splitwm