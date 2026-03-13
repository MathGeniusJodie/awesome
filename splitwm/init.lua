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

---------------------------------------------------------------------------
-- App launchers (configurable from rc.lua via splitwm.launchers)
---------------------------------------------------------------------------
-- Each entry: { label = "B", icon = "internet-web-browser", cmd = "firefox" }
-- `icon` is an XDG icon name — looked up from the system icon theme.
-- If the icon can't be found, `label` is shown as text instead.

splitwm.launchers = {}  -- set from rc.lua before calling setup()

-- "Pick up" state for moving tabs between splits
-- When set, the next split click will move this client there.
-- Stored as { client = c, tag = src_tag } so the source tag is known at drop time.
local picked_up_client = nil

--- Build a launcher widget (icon if available, text fallback).
--- `size` is the icon/font size to target; `callback` is the click action.
--- entry.icon must already be a resolved path (set by rc.lua after icon theme loads).
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
    w:connect_signal("mouse::enter", function()
        w.bg = "#ffffff15"
    end)
    w:connect_signal("mouse::leave", function()
        w.bg = "#00000000"
    end)
    w:buttons(gears.table.join(
        awful.button({}, 1, callback)
    ))
    return w
end

--- Shared widget skeleton for circular text buttons.
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
        forced_width  = size,
        forced_height = size,
        widget       = wibox.container.background,
    }
end

--- Build a circular text button with hover highlight (for overlays).
local function make_circle_btn(label, size, callback)
    local w = make_circle_btn_widget(label, size)
    w:connect_signal("mouse::enter", function() w.bg = "#00000080" end)
    w:connect_signal("mouse::leave", function() w.bg = beautiful.splitwm_inactive_bg or "#00000080" end)
    w:buttons(gears.table.join(awful.button({}, 1, callback)))
    return w
end

--- Rounded-top rectangle shape (tabs + titlebars).
local function rounded_top(cr, w, h)
    local r = 8
    cr:new_sub_path()
    cr:arc(r,     r, r, math.pi,       1.5 * math.pi)
    cr:arc(w - r, r, r, 1.5 * math.pi, 2   * math.pi)
    cr:line_to(w, h) cr:line_to(0, h) cr:close_path()
end

---------------------------------------------------------------------------
-- Split node data model
---------------------------------------------------------------------------

-- Each node is either a "leaf" (a container with tabs) or a "branch" (a
-- split with two children and a direction).
--
-- Leaf:
--   { type = "leaf", id = <unique>, tabs = {client, ...}, active_tab = 1 }
--
-- Branch:
--   { type = "branch", direction = "h"|"v", ratio = 0.5,
--     children = { node, node } }

local next_id = 1
local function gen_id()
    local id = next_id
    next_id = next_id + 1
    return id
end

--- Create a new empty leaf node
local function make_leaf()
    return {
        type = "leaf",
        id   = gen_id(),
        tabs = {},
        active_tab = 0,  -- 0 means no active tab
    }
end

--- Create a branch from two children
local function make_branch(direction, ratio, child_a, child_b)
    return {
        type      = "branch",
        direction = direction,  -- "h" = side by side, "v" = stacked
        ratio     = ratio or 0.5,
        children  = { child_a, child_b },
    }
end

---------------------------------------------------------------------------
-- Tree traversal helpers
---------------------------------------------------------------------------

--- Collect all leaf nodes in order (left-to-right / top-to-bottom)
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

--- Find the leaf that contains a given client
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

--- Find a leaf by its id
local function find_leaf_by_id(node, id)
    if node.type == "leaf" then
        return node.id == id and node or nil
    else
        return find_leaf_by_id(node.children[1], id)
            or find_leaf_by_id(node.children[2], id)
    end
end

--- Find the parent branch of a given node, plus which child index it is
local function find_parent(root, target)
    if root.type == "leaf" then return nil, nil end
    for i, child in ipairs(root.children) do
        if child == target then
            return root, i
        end
        local p, idx = find_parent(child, target)
        if p then return p, idx end
    end
    return nil, nil
end

--- Find the currently focused leaf (the one whose active tab has focus,
--  or the first leaf if nothing is focused)
local function find_focused_leaf(root, focused_client)
    if focused_client then
        local leaf = find_leaf_for_client(root, focused_client)
        if leaf then return leaf end
    end
    local leaves = collect_leaves(root)
    return leaves[1]
end

---------------------------------------------------------------------------
-- Geometry computation: walk the tree and compute pixel rects
---------------------------------------------------------------------------

--- Inner recursive walk: x/y/w/h are already inset by the root gap.
local function compute_tree_inner(node, x, y, w, h, gap, geos, bounds)
    if node.type == "leaf" then
        if geos then geos[node.id] = { x = x, y = y, width = w, height = h } end
        return
    end
    local dir, ratio, inner = node.direction, node.ratio, gap
    if dir == "h" then
        local usable = w - inner
        local w1 = math.floor(usable * ratio)
        if bounds then
            table.insert(bounds, { branch = node, dir = "h",
                pos = x + w1 + math.floor(inner / 2),
                start = y, span = h, parent_x = x, parent_w = w, parent_gap = inner })
        end
        compute_tree_inner(node.children[1], x,          y, w1,        h, gap, geos, bounds)
        compute_tree_inner(node.children[2], x+w1+inner, y, usable-w1, h, gap, geos, bounds)
    else
        local usable = h - inner
        local h1 = math.floor(usable * ratio)
        if bounds then
            table.insert(bounds, { branch = node, dir = "v",
                pos = y + h1 + math.floor(inner / 2),
                start = x, span = w, parent_y = y, parent_h = h, parent_gap = inner })
        end
        compute_tree_inner(node.children[1], x, y,          w, h1,        gap, geos, bounds)
        compute_tree_inner(node.children[2], x, y+h1+inner, w, usable-h1, gap, geos, bounds)
    end
end

--- Walk the tree computing geometry rects (geos) and/or split boundaries (bounds).
--- Applies the outer gap inset before recursing.
local function compute_tree(node, x, y, w, h, gap, geos, bounds)
    compute_tree_inner(node, x+gap, y+gap, w-2*gap, h-2*gap, gap, geos, bounds)
end

local function compute_geometries(node, x, y, w, h, gap)
    local geos = {}; compute_tree(node, x, y, w, h, gap, geos, nil); return geos
end


---------------------------------------------------------------------------
-- Per-tag state
---------------------------------------------------------------------------

-- Keyed by tag object. Each entry holds { root = <tree node>,
--   focused_leaf_id = <id> }
local tag_state = setmetatable({}, { __mode = "k" })

local function get_state(t)
    if not tag_state[t] then
        local root = make_leaf()
        tag_state[t] = {
            root = root,
            focused_leaf_id = root.id,
        }
    end
    return tag_state[t]
end

---------------------------------------------------------------------------
-- Client management
---------------------------------------------------------------------------

--- Pin client to the currently focused leaf
local function pin_client(t, c)
    local state = get_state(t)
    local leaf = find_leaf_by_id(state.root, state.focused_leaf_id)
    if not leaf then
        local leaves = collect_leaves(state.root)
        leaf = leaves[1]
    end
    -- Don't double-add
    for _, tc in ipairs(leaf.tabs) do
        if tc == c then return end
    end
    table.insert(leaf.tabs, c)
    leaf.active_tab = #leaf.tabs
end

--- Unpin client from wherever it lives in the tree
local function unpin_client(root, c)
    local leaf = find_leaf_for_client(root, c)
    if not leaf then return end
    for i, tc in ipairs(leaf.tabs) do
        if tc == c then
            table.remove(leaf.tabs, i)
            if leaf.active_tab > #leaf.tabs then
                leaf.active_tab = math.max(1, #leaf.tabs)
            end
            if #leaf.tabs == 0 then
                leaf.active_tab = 0
            end
            return
        end
    end
end

--- Move a client from its current leaf to a target leaf
local function move_client_to_leaf(root, c, target_leaf)
    unpin_client(root, c)
    -- Don't double-add
    for _, tc in ipairs(target_leaf.tabs) do
        if tc == c then return end
    end
    table.insert(target_leaf.tabs, c)
    target_leaf.active_tab = #target_leaf.tabs
end

--- Try to drop the picked-up client into the given leaf.
--- Handles cross-tag moves by re-tagging the client.
--- Returns true if a drop happened.
local function try_drop_picked_up(t, leaf_id)
    if not picked_up_client then return false end
    if not picked_up_client.client.valid then
        picked_up_client = nil
        return false
    end
    local state = get_state(t)
    local target = find_leaf_by_id(state.root, leaf_id)
    if not target then
        picked_up_client = nil
        return false
    end

    local c       = picked_up_client.client
    local src_tag = picked_up_client.tag

    -- Remove from source tag's tree
    if src_tag then
        local src_state = tag_state[src_tag]
        if src_state then
            unpin_client(src_state.root, c)
        end
    end

    -- Move client to destination tag if different
    if src_tag ~= t then
        c:move_to_tag(t)
    end

    move_client_to_leaf(state.root, c, target)

    state.focused_leaf_id = leaf_id
    picked_up_client = nil

    -- Re-arrange source tag's screen if cross-tag
    if src_tag and src_tag ~= t and src_tag.screen then
        awful.layout.arrange(src_tag.screen)
    end

    return true
end

---------------------------------------------------------------------------
-- Split operations
---------------------------------------------------------------------------

--- Split the focused leaf in a given direction
local function split_leaf(t, direction)
    local state = get_state(t)
    local leaf = find_leaf_by_id(state.root, state.focused_leaf_id)
    if not leaf then return false end

    -- Create two new leaves; the old leaf's tabs stay in child_a
    local child_a = make_leaf()
    child_a.tabs       = leaf.tabs
    child_a.active_tab = leaf.active_tab

    local child_b = make_leaf()

    -- Mutate the old leaf into a branch (this preserves parent references)
    leaf.type      = "branch"
    leaf.direction  = direction
    leaf.ratio      = 0.5
    leaf.children   = { child_a, child_b }
    leaf.tabs       = nil
    leaf.active_tab = nil
    -- Keep old id on the branch (harmless); focus moves to child_a
    state.focused_leaf_id = child_a.id
end

--- Close (remove) a leaf, merging its sibling up
local function close_leaf(t, leaf_id)
    local state = get_state(t)
    local leaf = find_leaf_by_id(state.root, leaf_id)
    if not leaf then return false end

    -- Can't close the last leaf
    local leaves = collect_leaves(state.root)
    if #leaves <= 1 then return false end

    local parent, idx = find_parent(state.root, leaf)
    if not parent then return false end

    -- The sibling replaces the parent
    local sibling_idx = idx == 1 and 2 or 1
    local sibling = parent.children[sibling_idx]

    -- Copy sibling's properties into parent (morphing parent into sibling)
    parent.type      = sibling.type
    parent.direction = sibling.direction
    parent.ratio     = sibling.ratio
    parent.children  = sibling.children
    parent.tabs      = sibling.tabs
    parent.active_tab = sibling.active_tab
    parent.id        = sibling.id

    -- Move focus to the sibling (or its first leaf)
    local new_leaves = collect_leaves(parent)
    if new_leaves[1] then
        state.focused_leaf_id = new_leaves[1].id
    end
end

--- Resize: adjust the ratio of the parent branch of the focused leaf
local function resize_focused(t, delta)
    local state = get_state(t)
    local leaf = find_leaf_by_id(state.root, state.focused_leaf_id)
    if not leaf then return false end
    local parent, idx = find_parent(state.root, leaf)
    if not parent then return false end
    local new_ratio = parent.ratio
    if idx == 1 then
        new_ratio = new_ratio + delta
    else
        new_ratio = new_ratio - delta
    end
    parent.ratio = math.max(0.1, math.min(0.9, new_ratio))
end

---------------------------------------------------------------------------
-- Tab operations
---------------------------------------------------------------------------

local function cycle_tab(t, offset)
    local state = get_state(t)
    local leaf = find_leaf_by_id(state.root, state.focused_leaf_id)
    if not leaf or #leaf.tabs == 0 then return false end
    leaf.active_tab = ((leaf.active_tab - 1 + offset) % #leaf.tabs) + 1
end

local function focus_tab_n(t, n)
    local state = get_state(t)
    local leaf = find_leaf_by_id(state.root, state.focused_leaf_id)
    if not leaf or n < 1 or n > #leaf.tabs then return end
    leaf.active_tab = n
end

--- Return the leaf adjacent to leaf_id in direction "next"|"prev", or nil.
local function adjacent_leaf(state, leaf_id, dir)
    local leaves = collect_leaves(state.root)
    if #leaves < 2 then return nil end
    local cur_idx
    for i, l in ipairs(leaves) do
        if l.id == leaf_id then cur_idx = i; break end
    end
    if not cur_idx then return nil end
    local new_idx
    if dir == "next" then
        new_idx = cur_idx < #leaves and cur_idx + 1 or 1
    else
        new_idx = cur_idx > 1 and cur_idx - 1 or #leaves
    end
    return leaves[new_idx]
end

--- Move the currently active tab in the focused leaf to an adjacent leaf
local function move_tab_to_direction(t, dir)
    local state    = get_state(t)
    local src_leaf = find_leaf_by_id(state.root, state.focused_leaf_id)
    if not src_leaf or #src_leaf.tabs == 0 then return false end
    local dst_leaf = adjacent_leaf(state, src_leaf.id, dir)
    if not dst_leaf then return false end

    local c = src_leaf.tabs[src_leaf.active_tab]
    table.remove(src_leaf.tabs, src_leaf.active_tab)
    if src_leaf.active_tab > #src_leaf.tabs then
        src_leaf.active_tab = math.max(0, #src_leaf.tabs)
    end
    table.insert(dst_leaf.tabs, c)
    dst_leaf.active_tab = #dst_leaf.tabs
end

---------------------------------------------------------------------------
-- Focus navigation between splits
---------------------------------------------------------------------------

local function focus_direction(t, dir)
    local state = get_state(t)
    local leaf  = adjacent_leaf(state, state.focused_leaf_id, dir)
    if not leaf then return false end
    state.focused_leaf_id = leaf.id
end

---------------------------------------------------------------------------
-- The layout "arrange" function (this is what awesome calls)
---------------------------------------------------------------------------

local function arrange(p)
    local tag = p.tag or awful.screen.focused().selected_tag
    if not tag then return end
    local state = get_state(tag)
    local wa    = p.workarea
    local cls   = p.clients
    -- Use our own gap variable, NOT useless_gap (awesome auto-applies that)
    local gap   = beautiful.splitwm_gap or 16

    -- Make sure every client in the tag is pinned somewhere.
    -- Build a set of already-pinned clients from the tree in one pass to avoid
    -- an O(n*m) find_leaf_for_client call per client.
    local root = state.root
    local pinned = {}
    for _, leaf in ipairs(collect_leaves(root)) do
        for _, tc in ipairs(leaf.tabs) do pinned[tc] = true end
    end
    for _, c in ipairs(cls) do
        if not pinned[c] then pin_client(tag, c) end
        if not c._splitwm_update_titlebar then setup_tabbar(c) end
    end

    -- Compute geometries for each leaf
    local geos = compute_geometries(root, wa.x, wa.y, wa.width, wa.height, gap)

    -- Clean out dead clients and apply geometries in one pass.
    -- NOTE: we do NOT use p.clients here because awesome filters out
    -- minimized/hidden clients from that list, and we hide inactive tabs.
    -- Windows are shifted up by gap/2 so the tab bar (TITLEBAR_HEIGHT tall)
    -- floats into the gap above, sitting between splits rather than consuming
    -- space inside the split. Height is increased by the same amount to compensate.
    -- focus_bw insets the content so the focus border renders outside it.
    local focus_bw  = beautiful.splitwm_focus_border_width or 2
    local tab_raise = math.floor(gap / 2)

    for _, leaf in ipairs(collect_leaves(root)) do
        -- Clean dead clients
        local new_tabs = {}
        for _, tc in ipairs(leaf.tabs) do
            if tc.valid then table.insert(new_tabs, tc) end
        end
        leaf.tabs = new_tabs
        if leaf.active_tab > #leaf.tabs then
            leaf.active_tab = math.max(0, #leaf.tabs)
        end
        if #leaf.tabs == 0 then leaf.active_tab = 0 end

        -- Apply geometry
        local geo = geos[leaf.id]
        if geo then
            for i, c in ipairs(leaf.tabs) do
                if i == leaf.active_tab then
                    c.hidden = false
                    c.border_width = 0
                    c:geometry({
                        x      = geo.x + focus_bw,
                        y      = geo.y + focus_bw - tab_raise,
                        width  = math.max(1, geo.width  - 2 * focus_bw),
                        height = math.max(1, geo.height - 2 * focus_bw + tab_raise),
                    })
                else
                    c.hidden = true
                end
            end
        end
    end
end

---------------------------------------------------------------------------
-- Shared UI helpers
---------------------------------------------------------------------------

--- Returns (tag, state) if the screen has an active splitwm tag, else (nil, nil).
local function get_active_state(s)
    local t = s.selected_tag
    if not t or not t.layout or t.layout.name ~= "splitwm" then return nil, nil end
    return t, get_state(t)
end

---------------------------------------------------------------------------
-- Persistent wibox pools (avoid X window churn on every arrange)
---------------------------------------------------------------------------

-- Focus border: 4 permanent wiboxes per screen, repositioned each update
local focus_border_pool = {}

local function get_focus_border(s)
    if focus_border_pool[s] then return focus_border_pool[s] end
    local sides = {}
    for _ = 1, 4 do
        table.insert(sides, wibox {
            screen            = s,
            x = 0, y = 0, width = 1, height = 1,
            bg                = beautiful.splitwm_focus_border or "#7799dd",
            border_width      = 0,
            visible           = false,
            ontop             = true,
            type              = "utility",
            input_passthrough = true,
        })
    end
    focus_border_pool[s] = sides
    return sides
end

-- Drag handles: growable pool per screen; buttons/signals wired once at creation
local HANDLE_THICKNESS = 6
-- Height of the tab bar / titlebar drawn at the top of each client.
-- The tab bar floats upward by gap/2, sitting in the gap above the split,
-- so this should be >= gap/2 to ensure it's fully visible.
local TITLEBAR_HEIGHT  = 33

local drag_handle_pool = {}  -- drag_handle_pool[s] = array of { wb, ref }

local function get_drag_handle(s, i)
    if not drag_handle_pool[s] then drag_handle_pool[s] = {} end
    if drag_handle_pool[s][i] then return drag_handle_pool[s][i] end

    -- Mutable ref updated each arrange; the already-wired closures read from here
    local ref = { b = nil, handle_w = 1, dragging = false }
    local wb  = wibox {
        x = 0, y = 0, width = 1, height = 1,
        bg      = "#00000000",
        visible = false,
        ontop   = true,
        type    = "utility",
    }

    wb:buttons(gears.table.join(
        awful.button({}, 1, function()
            if not ref.b then return end
            ref.dragging = true
            wb.bg = beautiful.splitwm_handle_drag_bg or "#7799dd44"
            local b  = ref.b
            local hw = ref.handle_w
            mousegrabber.run(function(mouse)
                if not mouse.buttons[1] then
                    ref.dragging = false
                    wb.bg = "#00000000"
                    awful.layout.arrange(s)
                    return false
                end
                local igap = b.parent_gap or 0
                if b.dir == "h" then
                    b.branch.ratio = math.max(0.1, math.min(0.9,
                        (mouse.x - b.parent_x) / (b.parent_w - igap)))
                    wb.x = mouse.x - math.floor(hw / 2)
                else
                    b.branch.ratio = math.max(0.1, math.min(0.9,
                        (mouse.y - b.parent_y) / (b.parent_h - igap)))
                    wb.y = mouse.y - math.floor(hw / 2)
                end
                awful.layout.arrange(s)
                return true
            end, b.dir == "h" and "sb_h_double_arrow" or "sb_v_double_arrow")
        end)
    ))
    wb:connect_signal("mouse::enter", function()
        if not ref.dragging then
            wb.bg = beautiful.splitwm_handle_hover_bg or "#7799dd22"
        end
    end)
    wb:connect_signal("mouse::leave", function()
        if not ref.dragging then wb.bg = "#00000000" end
    end)

    local entry = { wb = wb, ref = ref }
    drag_handle_pool[s][i] = entry
    return entry
end

-- Overlay wiboxes: cached by screen + leaf_id; recreated only when a new
-- leaf_id is first seen (i.e. on split, not on every focus change)
local overlay_cache = {}  -- overlay_cache[s][leaf_id] = wibox

---------------------------------------------------------------------------
-- Update overlays (empty split placeholders)
---------------------------------------------------------------------------

local function update_overlays(s, t, state, geos)
    local focus_bw = beautiful.splitwm_focus_border_width or 2
    if not overlay_cache[s] then overlay_cache[s] = {} end

    -- Determine which leaf_ids need an overlay this frame, and which exist at all
    local needed  = {}
    local alive   = {}
    for _, leaf in ipairs(collect_leaves(state.root)) do
        alive[leaf.id] = true
        if #leaf.tabs == 0 then needed[leaf.id] = leaf end
    end

    -- Destroy overlays whose leaf no longer exists; hide ones that are now occupied
    for leaf_id, wb in pairs(overlay_cache[s]) do
        if not alive[leaf_id] then
            wb.visible = false
            overlay_cache[s][leaf_id] = nil
        elseif not needed[leaf_id] then
            wb.visible = false
        end
    end

    -- Show or create overlays for empty leaves
    for leaf_id, leaf in pairs(needed) do
        local geo = geos[leaf_id]
        if geo then
            local focused = leaf.id == state.focused_leaf_id
            local x  = geo.x + focus_bw
            local y  = geo.y + focus_bw
            local w  = math.max(1, geo.width  - 2 * focus_bw)
            local h  = math.max(1, geo.height - 2 * focus_bw)
            local bg     = beautiful.splitwm_inactive_bg
            local border = "#00000066"

            if overlay_cache[s][leaf_id] then
                -- Reuse: just update geometry and focus color
                local wb = overlay_cache[s][leaf_id]
                wb.x = x; wb.y = y; wb.width = w; wb.height = h
                wb._bg_widget.bg                 = bg
                wb._bg_widget.shape_border_color = border
                wb.visible = true
            else
                -- First time we've seen this leaf_id: build and cache the overlay
                local vsplit_btn = make_circle_btn("│", 36, function()
                    state.focused_leaf_id = leaf_id
                    split_leaf(t, "h")
                    awful.layout.arrange(s)
                end)
                local hsplit_btn = make_circle_btn("─", 36, function()
                    state.focused_leaf_id = leaf_id
                    split_leaf(t, "v")
                    awful.layout.arrange(s)
                end)
                local close_btn = make_circle_btn("✕", 36, function()
                    close_leaf(t, leaf_id)
                    awful.layout.arrange(s)
                end)

                local launcher_ws = {}
                for _, entry in ipairs(splitwm.launchers) do
                    table.insert(launcher_ws, make_launcher_widget(entry, 30, function()
                        state.focused_leaf_id = leaf_id
                        if entry.action then entry.action()
                        elseif entry.cmd then awful.spawn(entry.cmd)
                        end
                    end))
                end

                local bg_widget = wibox.widget {
                    {
                        {
                            {
                                {
                                    spacing = 6,
                                    layout  = wibox.layout.fixed.horizontal,
                                    table.unpack(launcher_ws),
                                },
                                halign = "center",
                                widget = wibox.container.place,
                            },
                            {
                                {
                                    vsplit_btn, hsplit_btn, close_btn,
                                    spacing = 6,
                                    layout  = wibox.layout.fixed.horizontal,
                                },
                                halign = "center",
                                widget = wibox.container.place,
                            },
                            spacing = 15,
                            layout  = wibox.layout.fixed.vertical,
                        },
                        halign = "center",
                        valign = "center",
                        widget = wibox.container.place,
                    },
                    bg                 = bg,
                    shape              = function(cr, bw, bh) gears.shape.rounded_rect(cr, bw, bh, 8) end,
                    shape_border_width = 2,
                    shape_border_color = border,
                    widget             = wibox.container.background,
                }
                local wb = wibox {
                    screen       = s,
                    x = x, y = y, width = w, height = h,
                    bg           = "#00000000",
                    border_width = 0,
                    visible      = true,
                    ontop        = false,
                    type         = "utility",
                    widget       = bg_widget,
                }
                wb._bg_widget = bg_widget
                wb:buttons(gears.table.join(
                    awful.button({}, 1, function()
                        if picked_up_client then
                            try_drop_picked_up(t, leaf_id)
                            awful.layout.arrange(s)
                            return
                        end
                        state.focused_leaf_id = leaf_id
                        awful.layout.arrange(s)
                    end)
                ))
                overlay_cache[s][leaf_id] = wb
            end
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
    local gy      = has_win and (geo.y - math.floor(gap / 2)) or geo.y
    local gh      = has_win and (geo.height + math.floor(gap / 2)) or geo.height
    local rects = {
        { x = geo.x,                  y = gy,              width = geo.width, height = bw        },
        { x = geo.x,                  y = gy + gh - bw,    width = geo.width, height = bw        },
        { x = geo.x,                  y = gy + bw,         width = bw,        height = gh - 2*bw },
        { x = geo.x + geo.width - bw, y = gy + bw,         width = bw,        height = gh - 2*bw },
    }
    for i, r in ipairs(rects) do
        local wb = sides[i]
        wb.bg      = bc
        wb.x       = r.x
        wb.y       = r.y
        wb.width   = math.max(1, r.width)
        wb.height  = math.max(1, r.height)
        wb.visible = true
    end
end

---------------------------------------------------------------------------
-- Update drag handles
---------------------------------------------------------------------------

local function update_drag_handles(s, state, bounds)
    local gap      = beautiful.splitwm_gap or 16
    local handle_w = math.max(HANDLE_THICKNESS, gap)
    local n        = #bounds

    for i, b in ipairs(bounds) do
        local entry    = get_drag_handle(s, i)
        local wb, ref  = entry.wb, entry.ref
        -- Update the mutable ref so the already-wired closure sees fresh data
        ref.b        = b
        ref.handle_w = handle_w

        if b.dir == "h" then
            wb.x      = b.pos - math.floor(handle_w / 2)
            wb.y      = b.start
            wb.width  = handle_w
            wb.height = math.max(1, b.span)
            wb.cursor = "sb_h_double_arrow"
        else
            wb.x      = b.start
            wb.y      = b.pos - math.floor(handle_w / 2)
            wb.width  = math.max(1, b.span)
            wb.height = handle_w
            wb.cursor = "sb_v_double_arrow"
        end
        if not ref.dragging then wb.bg = "#00000000" end
        wb.visible = true
    end

    -- Hide unused handles beyond current boundary count
    local pool = drag_handle_pool[s]
    if pool then
        for i = n + 1, #pool do pool[i].wb.visible = false end
    end
end

---------------------------------------------------------------------------
-- Unified UI update: single tree traversal feeds all three subsystems
---------------------------------------------------------------------------

local function update_ui(s)
    local t, state = get_active_state(s)
    if not t then
        local sides = focus_border_pool[s]
        if sides then for _, wb in ipairs(sides) do wb.visible = false end end
        local pool = drag_handle_pool[s]
        if pool then for _, entry in ipairs(pool) do entry.wb.visible = false end end
        if overlay_cache[s] then
            for _, wb in pairs(overlay_cache[s]) do wb.visible = false end
        end
        return
    end

    local wa     = s.workarea
    local gap    = beautiful.splitwm_gap or 16
    local geos   = {}
    local bounds = {}
    compute_tree(state.root, wa.x, wa.y, wa.width, wa.height, gap, geos, bounds)

    update_overlays(s, t, state, geos)
    update_focus_border(s, state, geos, gap)
    update_drag_handles(s, state, bounds)

    for _, c in ipairs(s.clients) do
        if c._splitwm_update_titlebar then
            c._splitwm_update_titlebar()
        end
    end
end

---------------------------------------------------------------------------
-- Titlebar with tab indicators
---------------------------------------------------------------------------

local function setup_tabbar(c)
    -- We'll put a small titlebar at the top showing tab position
    -- This gets rebuilt whenever the layout arranges
    local titlebar_hovered = false
    local titlebar_btn_list = {}
    local tb  -- declared here so update_titlebar's closure can reference it
    -- Tooltip pool: reused across rebuilds to avoid leaking X windows.
    -- Each slot: { tt = awful.tooltip, prev_obj = widget_it_is_attached_to }
    local tooltip_pool = {}
    local BTN_SPACING = 5

    -- Button factory for titlebar controls. Defined once per client (not per rebuild).
    -- Buttons are registered in titlebar_btn_list so hover state can be synced.
    local function make_tb_btn(label, size, callback)
        local w = make_circle_btn_widget(label, size)
        w:connect_signal("mouse::enter", function() w.bg = "#333333" end)
        w:connect_signal("mouse::leave", function()
            w.bg = titlebar_hovered and "#000000" or (beautiful.splitwm_inactive_bg or "#00000080")
        end)
        w:buttons(gears.table.join(awful.button({}, 1, callback)))
        table.insert(titlebar_btn_list, w)
        return w
    end

    local function update_titlebar()
        local t = c.first_tag
        if not t then return end
        local state = tag_state[t]
        if not state then return end
        local leaf = find_leaf_for_client(state.root, c)
        if not leaf then return end

        -- Only show titlebar on the active tab
        if leaf.tabs[leaf.active_tab] ~= c then return end

        -- Skip rebuild if nothing visible has changed
        local fp_parts = { leaf.id, leaf.active_tab,
                           state.focused_leaf_id == leaf.id and 1 or 0 }
        for _, tc in ipairs(leaf.tabs) do
            fp_parts[#fp_parts+1] = tostring(tc.window)
            fp_parts[#fp_parts+1] = tc.name or "?"
            if picked_up_client and picked_up_client.client == tc then fp_parts[#fp_parts+1] = "P" end
        end
        local fp = table.concat(fp_parts, "\0")
        if c._splitwm_tb_fp == fp then return end
        c._splitwm_tb_fp = fp

        local leaf_id = leaf.id

        -- Reset titlebar button list for this rebuild
        titlebar_btn_list = {}

        -- Tab indicators with app icon, move and close buttons
        local tab_widgets = {}
        local tab_btn_font = "monospace bold 14"
        local icon_size = 20

        for i, tc in ipairs(leaf.tabs) do
            local name = tc.name or "?"
            local is_active = (i == leaf.active_tab)
            local tab_client = tc
            local tab_idx = i

            -- Is this tab currently picked up?
            local is_picked = (picked_up_client and picked_up_client.client == tc)

            -- App icon for the tab
            local tab_icon = awful.widget.clienticon(tc)
            tab_icon.forced_width = icon_size
            tab_icon.forced_height = icon_size

            -- Click the icon to switch to this tab (or drop a picked-up tab)
            tab_icon:buttons(gears.table.join(
                awful.button({}, 1, function()
                    if picked_up_client and picked_up_client.client ~= tc then
                        try_drop_picked_up(t, leaf_id)
                        awful.layout.arrange(c.screen)
                        return
                    end
                    leaf.active_tab = tab_idx
                    awful.layout.arrange(c.screen)
                end)
            ))

            -- Move button (pick up)
            local move_btn = wibox.widget {
                {
                    text   = is_picked and "▼" or "↗",
                    align  = "center",
                    font   = tab_btn_font,
                    widget = wibox.widget.textbox,
                },
                bg     = is_picked and "#7799dd" or "#00000000",
                fg     = "#ffffff",
                shape  = function(cr, bw, bh) gears.shape.rounded_rect(cr, bw, bh, 2) end,
                forced_width = 24,
                widget = wibox.container.background,
            }
            move_btn:connect_signal("mouse::enter", function()
                if not is_picked then move_btn.bg = "#ffffff22" end
            end)
            move_btn:connect_signal("mouse::leave", function()
                if not is_picked then move_btn.bg = "#00000000" end
            end)
            move_btn:buttons(gears.table.join(
                awful.button({}, 1, function()
                    if picked_up_client and picked_up_client.client == tab_client then
                        picked_up_client = nil
                    else
                        picked_up_client = { client = tab_client, tag = t }
                    end
                    awful.layout.arrange(c.screen)
                end)
            ))

            -- Close button
            local close_btn = wibox.widget {
                {
                    text   = "✕",
                    align  = "center",
                    font   = tab_btn_font,
                    widget = wibox.widget.textbox,
                },
                bg     = "#00000000",
                fg     = "#ffffff",
                shape  = function(cr, bw, bh) gears.shape.rounded_rect(cr, bw, bh, 2) end,
                forced_width = 24,
                widget = wibox.container.background,
            }
            close_btn:connect_signal("mouse::enter", function()
                close_btn.fg = "#ff6666"
            end)
            close_btn:connect_signal("mouse::leave", function()
                close_btn.fg = "#ffffff"
            end)
            close_btn:buttons(gears.table.join(
                awful.button({}, 1, function()
                    tab_client:kill()
                end)
            ))

            -- The tab: [icon] [↗] [✕]
            local tab_bg = is_picked and "#445566"
                or (is_active and (beautiful.splitwm_tab_active_bg or "#535d6c")
                              or  (beautiful.splitwm_inactive_bg or "#00000080"))

            -- Tooltip showing the window title (attached to whole tab)
            -- Created after tab_widget, added below

            local tab_widget = wibox.widget {
                {
                    {
                        {
                            tab_icon,
                            halign = "center",
                            valign = "center",
                            widget = wibox.container.place,
                        },
                        move_btn,
                        close_btn,
                        spacing = 2,
                        layout  = wibox.layout.fixed.horizontal,
                    },
                    left = 4, right = 2, top = 3, bottom = 3,
                    widget = wibox.container.margin,
                },
                bg = tab_bg,
                shape = rounded_top,
                widget = wibox.container.background,
            }
            -- Reuse tooltip from pool to avoid leaking X windows on every rebuild
            local slot = tooltip_pool[i]
            if not slot then
                slot = {
                    tt = awful.tooltip {
                        text         = name,
                        delay_show   = 0.3,
                        font         = "monospace bold 12",
                        bg           = "#000000",
                        fg           = "#ffffff",
                        border_width = 0,
                    },
                }
                tooltip_pool[i] = slot
            else
                slot.tt.text = name
                if slot.prev_obj then
                    slot.tt:remove_from_object(slot.prev_obj)
                    slot.tt.visible = false
                end
            end
            slot.tt:add_to_object(tab_widget)
            slot.prev_obj = tab_widget

            table.insert(tab_widgets, tab_widget)
        end

        -- Detach and dismiss tooltips for slots beyond the current tab count
        for i = #leaf.tabs + 1, #tooltip_pool do
            local slot = tooltip_pool[i]
            if slot and slot.prev_obj then
                slot.tt:remove_from_object(slot.prev_obj)
                slot.tt.visible = false
                slot.prev_obj = nil
            end
        end

        -- Menu button (right after tabs, on the left side)
        local menu_btn = make_tb_btn("+", 26, function()
            state.focused_leaf_id = leaf_id
            if splitwm.on_menu_request then
                splitwm.on_menu_request()
            end
        end)
        table.insert(tab_widgets, menu_btn)

        -- Titlebar split/close buttons
        local vsplit_btn = make_tb_btn("│", 26, function()
            state.focused_leaf_id = leaf_id
            split_leaf(t, "h")
            awful.layout.arrange(c.screen)
        end)

        local hsplit_btn = make_tb_btn("─", 26, function()
            state.focused_leaf_id = leaf_id
            split_leaf(t, "v")
            awful.layout.arrange(c.screen)
        end)

        local close_split_btn = make_tb_btn("✕", 26, function()
            close_leaf(t, leaf_id)
            awful.layout.arrange(c.screen)
        end)
        close_split_btn:connect_signal("mouse::enter", function() close_split_btn.fg = "#ff6666" end)
        close_split_btn:connect_signal("mouse::leave", function() close_split_btn.fg = "#ffffff" end)

        local is_focused_leaf = (state.focused_leaf_id == leaf_id)
        local bar_bg = is_focused_leaf
            and (beautiful.titlebar_bg_focus  or "#000000")
            or  (beautiful.titlebar_bg_normal or "#000000aa")

        tb:setup {
            {
                { -- Left: tab buttons
                    spacing = BTN_SPACING,
                    layout  = wibox.layout.fixed.horizontal,
                    table.unpack(tab_widgets),
                },
                nil, -- Middle: empty
                { -- Right: split controls
                    {
                        vsplit_btn,
                        hsplit_btn,
                        close_split_btn,
                        spacing = BTN_SPACING,
                        layout  = wibox.layout.fixed.horizontal,
                    },
                    right  = 0,
                    widget = wibox.container.margin,
                },
                layout = wibox.layout.align.horizontal,
            },
            bg     = bar_bg,
            shape  = rounded_top,
            widget = wibox.container.background,
        }
    end

    -- Create the titlebar once; hover signals attached here, content rebuilt by update_titlebar
    tb = awful.titlebar(c, { size = TITLEBAR_HEIGHT, position = "top", bg = "#00000000" })
    tb:connect_signal("mouse::enter", function()
        titlebar_hovered = true
        for _, btn in ipairs(titlebar_btn_list) do btn.bg = "#000000" end
    end)
    tb:connect_signal("mouse::leave", function()
        titlebar_hovered = false
        for _, btn in ipairs(titlebar_btn_list) do btn.bg = "#00000099" end
    end)

    c:connect_signal("property::name", update_titlebar)
    -- We call it once on setup; it will also be triggered by arrange
    gears.timer.delayed_call(update_titlebar)

    -- Store the updater so arrange can call it
    c._splitwm_update_titlebar = update_titlebar
end

---------------------------------------------------------------------------
-- Layout object (what you put in awful.layout.layouts)
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

-- Convention: fn(t) should return false (not nil) to indicate "did nothing,
-- skip the arrange call". Any other return value (including nil) triggers arrange.
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
-- Setup function: connect signals for client management
---------------------------------------------------------------------------

function splitwm.setup()
    -- When a new client appears, pin it and set up its titlebar
    client.connect_signal("manage", function(c)
        local t = c.first_tag
        if not t then return end
        -- Use get_state to ensure state is initialized
        local state = get_state(t)
        if not find_leaf_for_client(state.root, c) then
            pin_client(t, c)
        end
        if not c._splitwm_update_titlebar then
            setup_tabbar(c)
        end
    end)

    -- When a client is removed, unpin it
    client.connect_signal("unmanage", function(c)
        for t, state in pairs(tag_state) do
            unpin_client(state.root, c)
        end
    end)

    -- When focus changes, update the focused leaf and re-arrange for borders
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

    -- Also catch clicks on already-focused clients (e.g. clicking back
    -- from an empty split to the window that's still client.focus)
    client.connect_signal("button::press", function(c)
        local t = c.first_tag
        if not t then return end
        local state = tag_state[t]
        if not state then return end
        -- Handle drop of picked-up client
        if picked_up_client and picked_up_client.client.valid and picked_up_client.client ~= c then
            local target_leaf = find_leaf_for_client(state.root, c)
            if target_leaf then
                try_drop_picked_up(t, target_leaf.id)
                awful.layout.arrange(c.screen)
                return
            end
        end
        local leaf = find_leaf_for_client(state.root, c)
        if leaf and leaf.id ~= state.focused_leaf_id then
            state.focused_leaf_id = leaf.id
            awful.layout.arrange(c.screen)
        end
    end)

    -- Update UI when tag selection changes
    tag.connect_signal("property::selected", function(t)
        local s = t.screen
        if type(s) == "number" then s = screen[s] end
        if s then gears.timer.delayed_call(function() update_ui(s) end) end
    end)
end

---------------------------------------------------------------------------
-- Widget exports
---------------------------------------------------------------------------

-- Call this after launcher icons are resolved to force a full UI rebuild.
-- Without it, the icon-less first render is cached and icons never appear.
function splitwm.flush_caches()
    -- Hide orphaned overlay wiboxes before dropping the cache references,
    -- otherwise the old (icon-less) wiboxes stay visible under the new ones.
    for _, screen_cache in pairs(overlay_cache) do
        for _, wb in pairs(screen_cache) do wb.visible = false end
    end
    overlay_cache = {}
    for _, c in ipairs(client.get()) do
        c._splitwm_tb_fp = nil
    end
end

splitwm.get_state = get_state
splitwm.collect_leaves = collect_leaves

return splitwm
