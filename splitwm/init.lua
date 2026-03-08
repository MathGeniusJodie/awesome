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
local naughty   = require("naughty")
local menubar_utils = require("menubar.utils")

local splitwm = {}

---------------------------------------------------------------------------
-- App launchers (configurable from rc.lua via splitwm.launchers)
---------------------------------------------------------------------------
-- Each entry: { label = "B", icon = "internet-web-browser", cmd = "firefox" }
-- `icon` is an XDG icon name — looked up from the system icon theme.
-- If the icon can't be found, `label` is shown as text instead.

splitwm.launchers = {}  -- set from rc.lua before calling setup()

-- "Pick up" state for moving tabs between splits
-- When set, the next split click will move this client there
local picked_up_client = nil

--- Resolve an icon: accepts an XDG name, a file path, or nil.
--- Returns a usable path string or nil.
local function resolve_icon(icon_input)
    if not icon_input then return nil end
    if type(icon_input) ~= "string" then return nil end
    -- If it looks like an absolute path and exists, use it directly
    if icon_input:sub(1, 1) == "/" then
        return icon_input
    end
    -- Otherwise treat as XDG icon name
    local result = menubar_utils.lookup_icon(icon_input)
    if result and result ~= false and type(result) == "string" then
        return result
    end
    return nil
end

--- Build a launcher widget (icon if available, text fallback).
--- `size` is the icon/font size to target; `callback` is the click action.
local function make_launcher_widget(entry, size, callback)
    -- entry.icon = resolved path (set after icon theme loads)
    -- entry.icon_name = XDG name (for deferred resolution)
    local icon_path = resolve_icon(entry.icon) or resolve_icon(entry.icon_name)

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

local function compute_geometries(node, x, y, w, h, gap, out, is_root)
    out = out or {}
    -- On the root call, apply outer margin first
    if is_root == nil then is_root = true end
    if is_root then
        x = x + gap
        y = y + gap
        w = w - 2 * gap
        h = h - 2 * gap
        return compute_geometries(node, x, y, w, h, gap, out, false)
    end

    if node.type == "leaf" then
        out[node.id] = { x = x, y = y, width = w, height = h }
    else
        local dir   = node.direction
        local ratio = node.ratio
        local inner = gap  -- gap between splits matches outer margin
        if dir == "h" then
            local usable = w - inner  -- subtract one inner gap
            local w1 = math.floor(usable * ratio)
            local w2 = usable - w1
            compute_geometries(node.children[1], x,              y, w1, h, gap, out, false)
            compute_geometries(node.children[2], x + w1 + inner, y, w2, h, gap, out, false)
        else -- "v"
            local usable = h - inner
            local h1 = math.floor(usable * ratio)
            local h2 = usable - h1
            compute_geometries(node.children[1], x, y,              w, h1, gap, out, false)
            compute_geometries(node.children[2], x, y + h1 + inner, w, h2, gap, out, false)
        end
    end
    return out
end

--- Walk the tree and collect split boundaries (the edges between children
--  of branch nodes). Each boundary has a position, extent, direction,
--  and a reference to the branch node so we can adjust its ratio.
local function compute_boundaries(node, x, y, w, h, gap, out, is_root)
    out = out or {}
    if is_root == nil then is_root = true end
    if is_root then
        x = x + gap
        y = y + gap
        w = w - 2 * gap
        h = h - 2 * gap
        return compute_boundaries(node, x, y, w, h, gap, out, false)
    end

    if node.type == "leaf" then return out end

    local dir   = node.direction
    local ratio = node.ratio
    local inner = gap

    if dir == "h" then
        local usable = w - inner
        local w1 = math.floor(usable * ratio)
        local w2 = usable - w1
        -- The divider center sits in the inner gap between children
        local split_x = x + w1 + math.floor(inner / 2)
        table.insert(out, {
            branch = node,
            dir    = "h",
            pos    = split_x,
            start  = y,
            span   = h,
            parent_x = x,
            parent_w = w,
            parent_gap = inner,
        })
        compute_boundaries(node.children[1], x,              y, w1, h, gap, out, false)
        compute_boundaries(node.children[2], x + w1 + inner, y, w2, h, gap, out, false)
    else -- "v"
        local usable = h - inner
        local h1 = math.floor(usable * ratio)
        local h2 = usable - h1
        local split_y = y + h1 + math.floor(inner / 2)
        table.insert(out, {
            branch = node,
            dir    = "v",
            pos    = split_y,
            start  = x,
            span   = w,
            parent_y = y,
            parent_h = h,
            parent_gap = inner,
        })
        compute_boundaries(node.children[1], x, y,              w, h1, gap, out, false)
        compute_boundaries(node.children[2], x, y + h1 + inner, w, h2, gap, out, false)
    end

    return out
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
    if not picked_up_client.valid then
        picked_up_client = nil
        return false
    end
    local state = get_state(t)
    local target = find_leaf_by_id(state.root, leaf_id)
    if not target then
        picked_up_client = nil
        return false
    end

    local c = picked_up_client
    local src_tag = c.first_tag

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

    -- Add to target leaf (avoid double-add)
    local already = false
    for _, tc in ipairs(target.tabs) do
        if tc == c then already = true; break end
    end
    if not already then
        table.insert(target.tabs, c)
    end
    target.active_tab = #target.tabs

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
    if not leaf then return end

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
    if not leaf then return end

    -- Can't close the last leaf
    local leaves = collect_leaves(state.root)
    if #leaves <= 1 then return end

    local parent, idx = find_parent(state.root, leaf)
    if not parent then return end

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
    if not leaf then return end
    local parent, idx = find_parent(state.root, leaf)
    if not parent then return end
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
    if not leaf or #leaf.tabs == 0 then return end
    leaf.active_tab = ((leaf.active_tab - 1 + offset) % #leaf.tabs) + 1
end

local function focus_tab_n(t, n)
    local state = get_state(t)
    local leaf = find_leaf_by_id(state.root, state.focused_leaf_id)
    if not leaf or n < 1 or n > #leaf.tabs then return end
    leaf.active_tab = n
end

--- Move the currently active tab in the focused leaf to an adjacent leaf
local function move_tab_to_direction(t, dir)
    local state = get_state(t)
    local src_leaf = find_leaf_by_id(state.root, state.focused_leaf_id)
    if not src_leaf or #src_leaf.tabs == 0 then return end

    local leaves = collect_leaves(state.root)
    local src_idx
    for i, l in ipairs(leaves) do
        if l.id == src_leaf.id then src_idx = i; break end
    end
    if not src_idx then return end

    -- For now, "next"/"prev" based on tree order
    local dst_idx
    if dir == "next" then
        dst_idx = src_idx < #leaves and src_idx + 1 or 1
    else
        dst_idx = src_idx > 1 and src_idx - 1 or #leaves
    end

    local dst_leaf = leaves[dst_idx]
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
    local leaves = collect_leaves(state.root)
    if #leaves < 2 then return end

    local cur_idx
    for i, l in ipairs(leaves) do
        if l.id == state.focused_leaf_id then cur_idx = i; break end
    end
    if not cur_idx then return end

    local new_idx
    if dir == "next" then
        new_idx = cur_idx < #leaves and cur_idx + 1 or 1
    else
        new_idx = cur_idx > 1 and cur_idx - 1 or #leaves
    end

    state.focused_leaf_id = leaves[new_idx].id
end

---------------------------------------------------------------------------
-- The layout "arrange" function (this is what awesome calls)
---------------------------------------------------------------------------

local function arrange(p)
    local tag   = p.tag or awful.screen.focused().selected_tag
    local state = get_state(tag)
    local wa    = p.workarea
    local cls   = p.clients
    -- Use our own gap variable, NOT useless_gap (awesome auto-applies that)
    local gap   = beautiful.splitwm_gap or 16

    -- Make sure every client in the tag is pinned somewhere
    local root = state.root
    for _, c in ipairs(cls) do
        if not find_leaf_for_client(root, c) then
            pin_client(tag, c)
        end
        -- Ensure titlebar is set up
        if not c._splitwm_update_titlebar then
            setup_tabbar(c)
        end
    end

    -- Clean out clients that are no longer alive
    -- NOTE: we do NOT use p.clients here because awesome filters out
    -- minimized/hidden clients from that list, and we hide inactive tabs.
    for _, leaf in ipairs(collect_leaves(root)) do
        local new_tabs = {}
        for _, tc in ipairs(leaf.tabs) do
            if tc.valid then
                table.insert(new_tabs, tc)
            end
        end
        leaf.tabs = new_tabs
        if leaf.active_tab > #leaf.tabs then
            leaf.active_tab = math.max(0, #leaf.tabs)
        end
        if #leaf.tabs == 0 then leaf.active_tab = 0 end
    end

    -- Compute geometries for each leaf
    local geos = compute_geometries(root, wa.x, wa.y, wa.width, wa.height, gap)

    -- Apply geometries: only the active tab in each leaf is visible
    -- Inset content by focus_bw so the focus border sits outside the content
    local focus_bw = beautiful.splitwm_focus_border_width or 2

    for _, leaf in ipairs(collect_leaves(root)) do
        local geo = geos[leaf.id]
        local is_focused = (leaf.id == state.focused_leaf_id)
        if geo then
            for i, c in ipairs(leaf.tabs) do
                if i == leaf.active_tab then
                    c.hidden = false
                    c.border_width = 0
                    c:geometry({
                        x      = geo.x + focus_bw,
                        y      = geo.y + focus_bw,
                        width  = math.max(1, geo.width - 2 * focus_bw),
                        height = math.max(1, geo.height - 2 * focus_bw),
                    })
                else
                    c.hidden = true
                end
            end
        end
    end
end

---------------------------------------------------------------------------
-- Wibar indicator widget (shows split tree + tabs)
---------------------------------------------------------------------------

local function make_indicator_widget()
    -- Returns a widget that visualizes the current split tree
    local w = wibox.widget.textbox()
    w.font = beautiful.splitwm_font or "monospace 14"

    local function update()
        local s = awful.screen.focused()
        if not s then return end
        local t = s.selected_tag
        if not t then return end
        local state = get_state(t)
        local leaves = collect_leaves(state.root)
        local parts = {}
        for _, leaf in ipairs(leaves) do
            local focused = leaf.id == state.focused_leaf_id
            local prefix = focused and ">" or " "
            local n_tabs = #leaf.tabs
            local active = leaf.active_tab
            local tab_str
            if n_tabs == 0 then
                tab_str = "empty"
            else
                local tab_parts = {}
                for i = 1, n_tabs do
                    local name = leaf.tabs[i].name or "?"
                    -- Truncate
                    if #name > 12 then name = name:sub(1, 11) .. "…" end
                    if i == active then
                        table.insert(tab_parts, "[" .. name .. "]")
                    else
                        table.insert(tab_parts, " " .. name .. " ")
                    end
                end
                tab_str = table.concat(tab_parts, "")
            end
            table.insert(parts, prefix .. tab_str)
        end
        w:set_text(table.concat(parts, " | "))
    end

    -- Update on various signals
    tag.connect_signal("property::selected", update)
    tag.connect_signal("property::layout", update)
    client.connect_signal("manage", update)
    client.connect_signal("unmanage", update)
    client.connect_signal("property::name", update)
    client.connect_signal("focus", update)

    -- Also update on a timer for tab switches etc.
    gears.timer {
        timeout   = 0.5,
        autostart = true,
        callback  = update,
    }

    update()
    return w
end

---------------------------------------------------------------------------
-- Overlay wiboxes for empty splits (so you can see and click them)
---------------------------------------------------------------------------

local overlay_wiboxes = {}

local function update_overlays(s)
    -- Clear old overlays for this screen
    if overlay_wiboxes[s] then
        for _, wb in ipairs(overlay_wiboxes[s]) do
            wb.visible = false
        end
    end
    overlay_wiboxes[s] = {}

    local t = s.selected_tag
    if not t then return end
    local state = get_state(t)
    -- Check if this tag is actually using our layout
    if not t.layout or t.layout.name ~= "splitwm" then return end

    local wa = s.workarea
    local gap = beautiful.splitwm_gap or 16
    local geos = compute_geometries(state.root, wa.x, wa.y,
                                     wa.width, wa.height, gap)

    local focus_bw = beautiful.splitwm_focus_border_width or 2
    local focus_bc = beautiful.splitwm_focus_border or "#7799dd"

    for _, leaf in ipairs(collect_leaves(state.root)) do
        if #leaf.tabs == 0 then
            local geo = geos[leaf.id]
            if geo then
                local focused = leaf.id == state.focused_leaf_id
                local leaf_id = leaf.id

                -- Helper for overlay buttons
                local btn_font = beautiful.splitwm_btn_font or "monospace bold 14"
                local overlay_btn_size = 36
                local function make_overlay_btn(label, bg_color, callback)
                    local w = wibox.widget {
                        {
                            {
                                markup = '<span font_family="Sans">' .. label .. '</span>',
                                align  = "center",
                                valign = "center",
                                font   = btn_font,
                                widget = wibox.widget.textbox,
                            },
                            halign = "center",
                            valign = "center",
                            widget = wibox.container.place,
                        },
                        bg            = "#000000",
                        fg            = "#ffffff",
                        shape         = gears.shape.circle,
                        forced_width  = overlay_btn_size,
                        forced_height = overlay_btn_size,
                        widget        = wibox.container.background,
                    }
                    w:connect_signal("mouse::enter", function()
                        w.bg = "#333333"
                    end)
                    w:connect_signal("mouse::leave", function()
                        w.bg = "#000000"
                    end)
                    w:buttons(gears.table.join(
                        awful.button({}, 1, callback)
                    ))
                    return w
                end

                local vsplit_btn = make_overlay_btn("│", "#444444", function()
                    state.focused_leaf_id = leaf_id
                    split_leaf(t, "h")
                    awful.layout.arrange(s)
                end)

                local hsplit_btn = make_overlay_btn("─", "#444444", function()
                    state.focused_leaf_id = leaf_id
                    split_leaf(t, "v")
                    awful.layout.arrange(s)
                end)

                local close_btn = make_overlay_btn("✕", "#553333", function()
                    close_leaf(t, leaf_id)
                    awful.layout.arrange(s)
                end)

                -- App launcher buttons for empty splits (larger)
                local overlay_launchers = {}
                for _, entry in ipairs(splitwm.launchers) do
                    local lw = make_launcher_widget(entry, 30, function()
                        state.focused_leaf_id = leaf_id
                        if entry.action then
                            entry.action()
                        elseif entry.cmd then
                            awful.spawn(entry.cmd)
                        end
                    end)
                    table.insert(overlay_launchers, lw)
                end

                local wb = wibox {
                    screen  = s,
                    x       = geo.x + focus_bw,
                    y       = geo.y + focus_bw,
                    width   = math.max(1, geo.width - 2 * focus_bw),
                    height  = math.max(1, geo.height - 2 * focus_bw),
                    bg      = focused and (beautiful.splitwm_focus_bg or "#333344cc")
                                       or (beautiful.splitwm_empty_bg or "#222222aa"),
                    border_width = 0,
                    visible = true,
                    ontop   = false,
                    type    = "utility",
                    widget  = wibox.widget {
                        {
                            {
                                -- Top row: app launchers (centered)
                                {
                                    {
                                        spacing = 6,
                                        layout  = wibox.layout.fixed.horizontal,
                                        table.unpack(overlay_launchers),
                                    },
                                    halign = "center",
                                    widget = wibox.container.place,
                                },
                                -- Bottom row: split controls (centered)
                                {
                                    {
                                        vsplit_btn,
                                        hsplit_btn,
                                        close_btn,
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
                        layout = wibox.layout.stack,
                    },
                }
                -- Click background to focus this leaf (or drop a picked-up tab)
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
                table.insert(overlay_wiboxes[s], wb)
            end
        end
    end
end

---------------------------------------------------------------------------
-- Focus border: a wibox drawn around the focused leaf
---------------------------------------------------------------------------

local focus_border_wiboxes = {}  -- keyed by screen

local function update_focus_border(s)
    -- Clear old
    if focus_border_wiboxes[s] then
        for _, wb in ipairs(focus_border_wiboxes[s]) do
            wb.visible = false
        end
    end
    focus_border_wiboxes[s] = {}

    local t = s.selected_tag
    if not t then return end
    local state = get_state(t)
    if not t.layout or t.layout.name ~= "splitwm" then return end

    local wa = s.workarea
    local gap = beautiful.splitwm_gap or 16
    local geos = compute_geometries(state.root, wa.x, wa.y, wa.width, wa.height, gap)

    local leaf = find_leaf_by_id(state.root, state.focused_leaf_id)
    if not leaf then return end
    local geo = geos[leaf.id]
    if not geo then return end

    local bw = beautiful.splitwm_focus_border_width or 2
    local bc = beautiful.splitwm_focus_border or "#7799dd"

    -- Draw 4 thin wiboxes forming a border around the focused leaf
    local sides = {
        { -- top
            x = geo.x, y = geo.y,
            width = geo.width, height = bw,
        },
        { -- bottom
            x = geo.x, y = geo.y + geo.height - bw,
            width = geo.width, height = bw,
        },
        { -- left
            x = geo.x, y = geo.y + bw,
            width = bw, height = geo.height - 2 * bw,
        },
        { -- right
            x = geo.x + geo.width - bw, y = geo.y + bw,
            width = bw, height = geo.height - 2 * bw,
        },
    }

    for _, side in ipairs(sides) do
        local wb = wibox {
            screen  = s,
            x       = side.x,
            y       = side.y,
            width   = math.max(1, side.width),
            height  = math.max(1, side.height),
            bg      = bc,
            border_width = 0,
            visible = true,
            ontop   = true,
            type    = "utility",
            input_passthrough = true,
        }
        table.insert(focus_border_wiboxes[s], wb)
    end
end

local HANDLE_THICKNESS = 6  -- pixels, the clickable/draggable zone

local drag_handles = {}  -- keyed by screen

local function update_drag_handles(s)
    -- Clear old handles
    if drag_handles[s] then
        for _, wb in ipairs(drag_handles[s]) do
            wb.visible = false
        end
    end
    drag_handles[s] = {}

    local t = s.selected_tag
    if not t then return end
    local state = get_state(t)
    if not t.layout or t.layout.name ~= "splitwm" then return end

    local wa = s.workarea
    local gap = beautiful.splitwm_gap or 16
    local boundaries = compute_boundaries(state.root,
        wa.x, wa.y, wa.width, wa.height, gap)

    -- Make handle thickness at least as wide as the gap so the entire
    -- gap zone between splits is draggable
    local handle_w = math.max(HANDLE_THICKNESS, gap)

    for _, b in ipairs(boundaries) do
        local wb
        if b.dir == "h" then
            -- Vertical divider line (horizontal split) → drag left/right
            wb = wibox {
                x       = b.pos - math.floor(handle_w / 2),
                y       = b.start,
                width   = handle_w,
                height  = math.max(1, b.span),
                bg      = "#00000000",  -- transparent
                visible = true,
                ontop   = true,
                type    = "utility",
                cursor  = "sb_h_double_arrow",
            }
        else
            -- Horizontal divider line (vertical split) → drag up/down
            wb = wibox {
                x       = b.start,
                y       = b.pos - math.floor(handle_w / 2),
                width   = math.max(1, b.span),
                height  = handle_w,
                bg      = "#00000000",
                visible = true,
                ontop   = true,
                type    = "utility",
                cursor  = "sb_v_double_arrow",
            }
        end

        -- Drag logic: on press, start tracking mouse; on release, stop.
        local dragging = false
        local branch = b.branch

        wb:buttons(gears.table.join(
            awful.button({}, 1, function()
                dragging = true

                -- Highlight the handle while dragging
                wb.bg = beautiful.splitwm_handle_drag_bg or "#7799dd44"

                mousegrabber.run(function(mouse)
                    if not mouse.buttons[1] then
                        -- Released: stop dragging
                        dragging = false
                        wb.bg = "#00000000"
                        awful.layout.arrange(s)
                        gears.timer.delayed_call(function()
                            update_drag_handles(s)
                        end)
                        return false  -- stop grabbing
                    end

                    -- Compute new ratio from mouse position
                    -- parent_w/parent_h include the inner gap, so we need
                    -- to compute ratio over the usable space
                    local igap = b.parent_gap or 0
                    if b.dir == "h" then
                        local usable = b.parent_w - igap
                        local new_ratio = (mouse.x - b.parent_x) / usable
                        branch.ratio = math.max(0.1, math.min(0.9, new_ratio))
                    else
                        local usable = b.parent_h - igap
                        local new_ratio = (mouse.y - b.parent_y) / usable
                        branch.ratio = math.max(0.1, math.min(0.9, new_ratio))
                    end

                    -- Re-arrange live while dragging
                    awful.layout.arrange(s)

                    -- Update handle position to follow the mouse
                    if b.dir == "h" then
                        wb.x = mouse.x - math.floor(handle_w / 2)
                    else
                        wb.y = mouse.y - math.floor(handle_w / 2)
                    end

                    return true  -- keep grabbing
                end, b.dir == "h" and "sb_h_double_arrow"
                                   or "sb_v_double_arrow")
            end)
        ))

        -- Hover highlight
        wb:connect_signal("mouse::enter", function()
            if not dragging then
                wb.bg = beautiful.splitwm_handle_hover_bg or "#7799dd22"
            end
        end)
        wb:connect_signal("mouse::leave", function()
            if not dragging then
                wb.bg = "#00000000"
            end
        end)

        table.insert(drag_handles[s], wb)
    end
end

---------------------------------------------------------------------------
-- Titlebar with tab indicators
---------------------------------------------------------------------------

local function setup_tabbar(c)
    -- We'll put a small titlebar at the top showing tab position
    -- This gets rebuilt whenever the layout arranges
    local function update_titlebar()
        local t = c.first_tag
        if not t then return end
        local state = tag_state[t]
        if not state then return end
        local leaf = find_leaf_for_client(state.root, c)
        if not leaf then return end

        -- Only show titlebar on the active tab
        if leaf.tabs[leaf.active_tab] ~= c then return end

        local leaf_id = leaf.id
        local btn_font = beautiful.splitwm_btn_font or "monospace bold 14"

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
            local is_picked = (picked_up_client == tc)

            -- App icon for the tab
            local tab_icon = awful.widget.clienticon(tc)
            tab_icon.forced_width = icon_size
            tab_icon.forced_height = icon_size

            -- Click the icon to switch to this tab (or drop a picked-up tab)
            tab_icon:buttons(gears.table.join(
                awful.button({}, 1, function()
                    if picked_up_client and picked_up_client ~= tc then
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
                    if picked_up_client == tab_client then
                        picked_up_client = nil
                    else
                        picked_up_client = tab_client
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
                              or  (beautiful.splitwm_tab_bg or "#333333"))

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
                shape = function(cr, w, h)
                    -- Top-only rounded corners
                    local r = 8
                    cr:new_sub_path()
                    cr:arc(r, r, r, math.pi, 1.5 * math.pi)
                    cr:arc(w - r, r, r, 1.5 * math.pi, 2 * math.pi)
                    cr:line_to(w, h)
                    cr:line_to(0, h)
                    cr:close_path()
                end,
                widget = wibox.container.background,
            }
            awful.tooltip {
                objects        = { tab_widget },
                text           = name,
                delay_show     = 0.3,
                font           = "monospace bold 12",
                bg             = "#000000",
                fg             = "#ffffff",
                border_width   = 0,
            }
            table.insert(tab_widgets, tab_widget)
        end

        -- Helper to make a titlebar button (perfect circle)
        local btn_size = 26
        local function make_btn(label, bg_color, callback)
            local w = wibox.widget {
                {
                    {
                        markup = '<span font_family="Sans">' .. label .. '</span>',
                        align  = "center",
                        valign = "center",
                        font   = btn_font,
                        widget = wibox.widget.textbox,
                    },
                    halign = "center",
                    valign = "center",
                    widget = wibox.container.place,
                },
                bg           = "#000000",
                fg           = "#ffffff",
                shape        = gears.shape.circle,
                forced_width  = btn_size,
                forced_height = btn_size,
                widget       = wibox.container.background,
            }
            w:connect_signal("mouse::enter", function()
                w.bg = "#333333"
            end)
            w:connect_signal("mouse::leave", function()
                w.bg = "#000000"
            end)
            w:buttons(gears.table.join(
                awful.button({}, 1, callback)
            ))
            return w
        end

        -- Vertical split button (split side by side)
        local vsplit_btn = make_btn("│", "#444444", function()
            state.focused_leaf_id = leaf_id
            split_leaf(t, "h")
            awful.layout.arrange(c.screen)
        end)

        -- Horizontal split button (split top/bottom)
        local hsplit_btn = make_btn("─", "#444444", function()
            state.focused_leaf_id = leaf_id
            split_leaf(t, "v")
            awful.layout.arrange(c.screen)
        end)

        -- Close split button
        local close_split_btn = make_btn("✕", "#553333", function()
            close_leaf(t, leaf_id)
            awful.layout.arrange(c.screen)
        end)

        -- App launcher buttons (titlebar size)
        local launcher_widgets = {}
        for _, entry in ipairs(splitwm.launchers) do
            local lw = make_launcher_widget(entry, 21, function()
                -- Focus this split first so the new app lands here
                state.focused_leaf_id = leaf_id
                if entry.action then
                    entry.action()
                elseif entry.cmd then
                    awful.spawn(entry.cmd)
                end
            end)
            table.insert(launcher_widgets, lw)
        end

        local is_focused_leaf = (state.focused_leaf_id == leaf_id)
        local bar_bg = is_focused_leaf
            and (beautiful.titlebar_bg_focus  or "#000000")
            or  (beautiful.titlebar_bg_normal or "#000000aa")

        awful.titlebar(c, { size = 33, position = "top", bg = "#00000000" }):setup {
            {
                { -- Left: tab buttons
                    spacing = 2,
                    layout  = wibox.layout.fixed.horizontal,
                    table.unpack(tab_widgets),
                },
                nil, -- Middle: empty
                { -- Right: launchers + split controls
                    {
                        {
                            spacing = 2,
                            layout  = wibox.layout.fixed.horizontal,
                            table.unpack(launcher_widgets),
                        },
                        {
                            width   = 8,
                            widget  = wibox.container.constraint,
                        },
                        vsplit_btn,
                        hsplit_btn,
                        close_split_btn,
                        spacing = 5,
                        layout  = wibox.layout.fixed.horizontal,
                    },
                    right  = 5,
                    widget = wibox.container.margin,
                },
                layout = wibox.layout.align.horizontal,
            },
            bg     = bar_bg,
            shape  = function(cr, w, h)
                local r = 8
                cr:new_sub_path()
                cr:arc(r, r, r, math.pi, 1.5 * math.pi)
                cr:arc(w - r, r, r, 1.5 * math.pi, 2 * math.pi)
                cr:line_to(w, h)
                cr:line_to(0, h)
                cr:close_path()
            end,
            widget = wibox.container.background,
        }
    end

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
        -- Update overlays, drag handles, and titlebars after arranging
        local s = p.screen
        if type(s) == "number" then s = screen[s] end
        if not s then s = awful.screen.focused() end
        gears.timer.delayed_call(function()
            update_overlays(s)
            update_focus_border(s)
            update_drag_handles(s)
            -- Update all titlebars on this screen
            for _, c in ipairs(s.clients) do
                if c._splitwm_update_titlebar then
                    c._splitwm_update_titlebar()
                end
            end
        end)
    end,
}

---------------------------------------------------------------------------
-- Keybinding helpers
---------------------------------------------------------------------------

function splitwm.split_horizontal()
    local t = awful.screen.focused().selected_tag
    if t then split_leaf(t, "h"); awful.layout.arrange(awful.screen.focused()) end
end

function splitwm.split_vertical()
    local t = awful.screen.focused().selected_tag
    if t then split_leaf(t, "v"); awful.layout.arrange(awful.screen.focused()) end
end

function splitwm.close_split()
    local t = awful.screen.focused().selected_tag
    if not t then return end
    local state = get_state(t)
    close_leaf(t, state.focused_leaf_id)
    awful.layout.arrange(awful.screen.focused())
end

function splitwm.focus_next_split()
    local t = awful.screen.focused().selected_tag
    if t then focus_direction(t, "next"); awful.layout.arrange(awful.screen.focused()) end
end

function splitwm.focus_prev_split()
    local t = awful.screen.focused().selected_tag
    if t then focus_direction(t, "prev"); awful.layout.arrange(awful.screen.focused()) end
end

function splitwm.next_tab()
    local t = awful.screen.focused().selected_tag
    if t then cycle_tab(t, 1); awful.layout.arrange(awful.screen.focused()) end
end

function splitwm.prev_tab()
    local t = awful.screen.focused().selected_tag
    if t then cycle_tab(t, -1); awful.layout.arrange(awful.screen.focused()) end
end

function splitwm.move_tab_next()
    local t = awful.screen.focused().selected_tag
    if t then move_tab_to_direction(t, "next"); awful.layout.arrange(awful.screen.focused()) end
end

function splitwm.move_tab_prev()
    local t = awful.screen.focused().selected_tag
    if t then move_tab_to_direction(t, "prev"); awful.layout.arrange(awful.screen.focused()) end
end

function splitwm.resize_grow()
    local t = awful.screen.focused().selected_tag
    if t then resize_focused(t, 0.05); awful.layout.arrange(awful.screen.focused()) end
end

function splitwm.resize_shrink()
    local t = awful.screen.focused().selected_tag
    if t then resize_focused(t, -0.05); awful.layout.arrange(awful.screen.focused()) end
end

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
        setup_tabbar(c)
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
        if picked_up_client and picked_up_client.valid and picked_up_client ~= c then
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

    -- Update overlays when tag selection changes
    tag.connect_signal("property::selected", function(t)
        local s = t.screen
        if type(s) == "number" then s = screen[s] end
        if s then
            gears.timer.delayed_call(function()
                update_overlays(s)
                update_focus_border(s)
                update_drag_handles(s)
            end)
        end
    end)
end

---------------------------------------------------------------------------
-- Widget exports
---------------------------------------------------------------------------

splitwm.indicator = make_indicator_widget
splitwm.get_state = get_state
splitwm.collect_leaves = collect_leaves

return splitwm
