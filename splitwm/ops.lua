---------------------------------------------------------------------------
-- splitwm.ops — every mutation of the split tree and its tab stacks:
-- pinning clients, moving/swapping tabs, splitting, closing, resizing,
-- inserting columns, and pickup/drop handling.
---------------------------------------------------------------------------

local awful  = require("awful")
local gears  = require("gears")
local tree   = require("splitwm.tree")
local core   = require("splitwm.core")
local theme  = require("splitwm.theme")
local colors = require("splitwm.colors")
local focus  = require("splitwm.focus")
local smush  = require("splitwm.smush")
local anim   = require("splitwm.animation")
local scroll = require("splitwm.scroll")

local ops = {}

local function maybe_arrange(t, c, opts)
    if opts and opts.arrange == false then return end
    local s = (opts and opts.screen) or (t and t.screen) or (c and c.screen)
    if s then awful.layout.arrange(s) end
end

local function maybe_focus(c, leaf_id, opts)
    if opts and opts.focus == false then return end
    focus.after_arrange(c, leaf_id)
end

---------------------------------------------------------------------------
-- Pending "next client goes here" requests (splitwm.spawn / expect_next_client)
---------------------------------------------------------------------------

-- Single slot: the most recent request wins, and expires after its timeout.
local pending_request = nil

function ops.expect_next_client(opts)
    opts = opts or {}
    local s = core.screen_of(opts.screen or awful.screen.focused())
    local t = opts.tag or (s and s.selected_tag)
    if not t then return nil end

    local state = core.state(t)
    local leaf = (opts.leaf_id and core.leaf(state, opts.leaf_id))
        or core.focused_leaf(state)
        or tree.collect_leaves(state.root)[1]
    if not leaf then return nil end

    state.focused_leaf_id = leaf.id
    pending_request = {
        tag      = t,
        leaf_id  = leaf.id,
        append   = opts.append == true,
        deadline = os.time() + (opts.timeout or 4),
    }
    return pending_request
end

local function take_request(t)
    local request = pending_request
    if not request or request.tag ~= t or os.time() > request.deadline then
        return nil, nil
    end
    pending_request = nil
    local state = core.tag_state[t]
    local leaf = state and core.leaf(state, request.leaf_id)
    if leaf then return request, leaf end
    return nil, nil
end

---------------------------------------------------------------------------
-- Pinning clients to leaves
---------------------------------------------------------------------------

function ops.pin_client(t, c)
    local state = core.state(t)
    local request, leaf = take_request(t)
    leaf = leaf or core.focused_leaf(state) or tree.collect_leaves(state.root)[1]
    if core.tab_index(leaf, c) then return end
    local pos = (request and request.append)
        and #leaf.tabs + 1
        or leaf.active_tab + 1
    table.insert(leaf.tabs, pos, c)
    leaf.active_tab = pos
end

local function remove_from_leaf(leaf, c)
    local removed = false
    local i = 1
    while i <= #leaf.tabs do
        if leaf.tabs[i] == c then
            table.remove(leaf.tabs, i)
            removed = true
            if i < leaf.active_tab then
                leaf.active_tab = leaf.active_tab - 1
            elseif i == leaf.active_tab then
                leaf.active_tab = core.clamp_tab_index(i - 1, #leaf.tabs)
            end
        else
            i = i + 1
        end
    end
    leaf.active_tab = core.clamp_tab_index(leaf.active_tab, #leaf.tabs)
    return removed
end

function ops.unpin_client(root, c)
    for _, leaf in ipairs(tree.collect_leaves(root)) do
        remove_from_leaf(leaf, c)
    end
end

local function remove_from_other_leaves(state, c, keep_leaf)
    for _, leaf in ipairs(tree.collect_leaves(state.root)) do
        if leaf ~= keep_leaf then remove_from_leaf(leaf, c) end
    end
end

---------------------------------------------------------------------------
-- Tab activation / movement
---------------------------------------------------------------------------

function ops.activate_client_in_leaf(t, leaf_id, c, opts)
    if not (t and c and c.valid) then return false end
    local state = core.state(t)
    local leaf = core.leaf(state, leaf_id)
    if not leaf then return false end

    local idx = core.tab_index(leaf, c)
    if not idx then return false end

    leaf.active_tab = idx
    state.focused_leaf_id = leaf.id
    maybe_arrange(t, c, opts)
    maybe_focus(c, leaf.id, opts)
    return true
end

function ops.move_client_to_leaf_id(t, leaf_id, c, opts)
    if not (t and c and c.valid) then return false end
    local state = core.state(t)
    local target = core.leaf(state, leaf_id)
    if not target then return false end

    if core.tab_index(target, c) then
        remove_from_other_leaves(state, c, target)
        return ops.activate_client_in_leaf(t, target.id, c, opts)
    end

    remove_from_other_leaves(state, c, nil)
    local pos = target.active_tab > 0
        and target.active_tab + 1
        or #target.tabs + 1
    table.insert(target.tabs, pos, c)
    target.active_tab = pos
    state.focused_leaf_id = target.id
    colors.resolve_color_conflict(target, c)
    maybe_arrange(t, c, opts)
    maybe_focus(c, target.id, opts)
    return true
end

function ops.swap_client_to_tab_index(t, leaf_id, c, target_idx, opts)
    if not (t and c and c.valid) then return false end
    target_idx = math.floor(tonumber(target_idx) or 0)

    local state = core.state(t)
    local leaf = core.leaf(state, leaf_id)
    if not leaf or target_idx < 1 or target_idx > #leaf.tabs then return false end

    local cur = core.tab_index(leaf, c)
    if not cur then return false end
    if cur ~= target_idx then
        leaf.tabs[cur], leaf.tabs[target_idx] = leaf.tabs[target_idx], leaf.tabs[cur]
    end
    leaf.active_tab = target_idx
    state.focused_leaf_id = leaf.id
    maybe_arrange(t, c, opts)
    maybe_focus(c, leaf.id, opts)
    return true
end

function ops.cycle_tab(t, offset)
    local state = core.state(t)
    local leaf = core.focused_leaf(state)
    if not leaf or #leaf.tabs == 0 then return false end
    leaf.active_tab = ((leaf.active_tab - 1 + offset) % #leaf.tabs) + 1
    local c = leaf.tabs[leaf.active_tab]
    if c and c.valid then focus.after_arrange(c, leaf.id) end
    return true
end

local function adjacent_leaf(state, leaf_id, dir)
    local leaves = tree.collect_leaves(state.root)
    if #leaves < 2 then return nil end
    local cur
    for i, l in ipairs(leaves) do
        if l.id == leaf_id then cur = i; break end
    end
    if not cur then return nil end
    if dir == "next" then
        return leaves[cur < #leaves and cur + 1 or 1]
    end
    return leaves[cur > 1 and cur - 1 or #leaves]
end

function ops.move_tab_to_direction(t, dir)
    local state = core.state(t)
    local src = core.focused_leaf(state)
    if not src or #src.tabs == 0 then return false end
    local dst = adjacent_leaf(state, src.id, dir)
    if not dst then return false end

    local c = src.tabs[src.active_tab]
    if not c then return false end
    ops.unpin_client(state.root, c)
    table.insert(dst.tabs, c)
    dst.active_tab = #dst.tabs
    colors.resolve_color_conflict(dst, c)
    state.focused_leaf_id = dst.id
    focus.after_arrange(c, dst.id)
    return true
end

function ops.focus_direction(t, dir)
    local state = core.state(t)
    local leaf = adjacent_leaf(state, state.focused_leaf_id, dir)
    if not leaf then return false end
    state.focused_leaf_id = leaf.id
    focus.leaf_after_arrange(state, leaf.id)
    return true
end

---------------------------------------------------------------------------
-- Splitting and closing
---------------------------------------------------------------------------

-- Replace `leaf` in the tree by a branch (or flatten into a same-direction
-- parent branch), keeping its tabs in child_a.
local function split_node(state, leaf, direction, child_a, child_b)
    local parent, idx = tree.find_parent(state.root, leaf)
    if parent and parent.direction == direction then
        -- Flatten: insert into the existing same-direction branch.
        local old_r = parent.ratios[idx]
        parent.ratios[idx] = old_r * theme.SPLIT_RATIO
        table.insert(parent.ratios, idx + 1, old_r * (1 - theme.SPLIT_RATIO))
        parent.children[idx] = child_a
        table.insert(parent.children, idx + 1, child_b)
        return
    end
    local branch = tree.make_branch(direction, theme.SPLIT_RATIO, child_a, child_b)
    if leaf == state.root then
        state.root = branch
    else
        parent.children[idx] = branch
    end
end

function ops.split_leaf(t, direction)
    local state = core.state(t)
    local leaf = core.focused_leaf(state)
    if not leaf then return nil end

    local child_a = tree.make_leaf()
    child_a.tabs       = leaf.tabs
    child_a.active_tab = leaf.active_tab
    local child_b = tree.make_leaf()

    split_node(state, leaf, direction, child_a, child_b)
    state.focused_leaf_id = child_a.id
    return child_a.id, child_b.id
end

function ops.close_leaf(t, leaf_id)
    local state = core.state(t)
    local leaf = core.leaf(state, leaf_id)
    if not leaf then return false end
    local pickup = core.drag.pickup
    if pickup.tag == "split" and pickup.split_id == leaf_id then
        core.drop_pickup()
    end
    if pickup.tag == "client" and pickup.client.valid
            and tree.find_leaf_for_client(state.root, pickup.client) == leaf then
        core.drop_pickup()
    end
    local parent, idx = tree.find_parent(state.root, leaf)
    if not parent then return false end

    -- The closed leaf's tabs merge into the adjacent sibling's first leaf.
    local dest_idx = idx > 1 and (idx - 1) or 2
    local dest = tree.collect_leaves(parent.children[dest_idx])[1]
    for _, tc in ipairs(leaf.tabs) do
        table.insert(dest.tabs, tc)
        colors.resolve_color_conflict(dest, tc)
    end
    if dest.active_tab == 0 and #dest.tabs > 0 then dest.active_tab = 1 end

    local focused_id = state.focused_leaf_id
    if #parent.children > 2 then
        -- N-ary: remove this child and redistribute its ratio share.
        local removed_ratio = parent.ratios[idx]
        table.remove(parent.children, idx)
        table.remove(parent.ratios, idx)
        local remaining = 0
        for _, r in ipairs(parent.ratios) do remaining = remaining + r end
        if remaining > 0 then
            for i = 1, #parent.ratios do
                parent.ratios[i] = parent.ratios[i]
                    + removed_ratio * parent.ratios[i] / remaining
            end
        end
        -- Keep the focused leaf if it survived, else focus the adjacent child.
        local keep
        for _, child in ipairs(parent.children) do
            keep = tree.find_leaf_by_id(child, focused_id)
            if keep then break end
        end
        local fallback_idx = math.min(idx, #parent.children)
        local fallback = tree.collect_leaves(parent.children[fallback_idx])[1]
        state.focused_leaf_id = keep and keep.id or fallback.id
    else
        -- Binary: collapse the parent; the sibling takes its place.
        local sibling = parent.children[idx == 1 and 2 or 1]
        local keep = tree.find_leaf_by_id(sibling, focused_id)
        if parent == state.root then
            state.root = sibling
        else
            local grand, pidx = tree.find_parent(state.root, parent)
            grand.children[pidx] = sibling
        end
        state.focused_leaf_id = keep and keep.id
            or tree.collect_leaves(sibling)[1].id
    end
    return true
end

function ops.close_leaf_with_anim(t, s, state, leaf_id)
    local leaf = core.leaf(state, leaf_id)
    local parent, pidx
    if leaf then parent, pidx = tree.find_parent(state.root, leaf) end
    local old_geos, sibling_ids
    local old_scroll_x = state.scroll_x or 0
    if parent then
        -- Animate ALL remaining children of the parent, not just one subtree.
        local remaining = {}
        for i, child in ipairs(parent.children) do
            if i ~= pidx then
                for _, l in ipairs(tree.collect_leaves(child)) do
                    table.insert(remaining, l)
                end
            end
        end
        local cached = core.geo[t]
        if cached and #remaining > 0 then
            sibling_ids, old_geos = {}, {}
            for _, l in ipairs(remaining) do
                sibling_ids[#sibling_ids + 1] = l.id
                old_geos[l.id] = cached.geos[l.id]
            end
        end
    end
    if ops.close_leaf(t, leaf_id) == false then return end

    -- Clamp canvas_w if the remaining tree has no horizontal splits.
    local wa = s.workarea
    if state.root and state.root.direction ~= tree.DIR_H then
        if (state.canvas_w or wa.width) > wa.width then
            state.canvas_w = wa.width
        end
    end

    awful.layout.arrange(s)
    focus.leaf_after_arrange(state, state.focused_leaf_id)

    -- Clamp scroll to the new canvas and keep the focused split visible.
    -- Done after arrange so the fresh geometry cache is available.
    local final_scroll = old_scroll_x
    local cw    = state.canvas_w or wa.width
    local max_s = math.max(0, cw - wa.width)
    local cached = core.geo[t]
    if cached then
        local fgeo = cached.geos[state.focused_leaf_id]
        if fgeo then
            if fgeo.x - final_scroll < wa.x then
                final_scroll = fgeo.x - wa.x
            elseif fgeo.x + fgeo.width - final_scroll > wa.x + wa.width then
                final_scroll = fgeo.x + fgeo.width - wa.x - wa.width
            end
        end
    end
    final_scroll        = math.max(0, math.min(max_s, final_scroll))
    state.scroll_x      = final_scroll
    state.scroll_target = final_scroll

    if old_geos then
        -- Remap old canvas coords so the animation starts at the correct
        -- screen positions under the new scroll_x.
        for id, geo in pairs(old_geos) do
            old_geos[id] = {
                x      = geo.x - old_scroll_x + final_scroll,
                y      = geo.y,
                width  = geo.width,
                height = geo.height,
            }
        end
        anim.reflow_pending[s] = {
            old_geos = old_geos, leaf_ids = sibling_ids, smush = true,
        }
    end
end

function ops.split_with_anim(t, s, state, leaf_id, dir)
    state.focused_leaf_id = leaf_id
    local old_geo = core.geo[t] and core.geo[t].geos[leaf_id]
    local a_id, b_id = ops.split_leaf(t, dir)
    if not a_id then return end
    awful.layout.arrange(s)
    focus.leaf_after_arrange(state, a_id)
    if old_geo then
        anim.split_pending[s] = {
            old_geo = old_geo, a_id = a_id, b_id = b_id, dir = dir,
        }
    end
end

-- Callbacks for the per-split control buttons in the tab bar.
function ops.split_action_callbacks(state, leaf_id, t, s)
    return {
        vsplit = function() ops.split_with_anim(t, s, state, leaf_id, tree.DIR_H) end,
        hsplit = function() ops.split_with_anim(t, s, state, leaf_id, tree.DIR_V) end,
        close  = function() ops.close_leaf_with_anim(t, s, state, leaf_id) end,
        minimize_toggle = function()
            local leaf = core.leaf(state, leaf_id)
            if not leaf then return end
            local is_minimizing = not leaf.minimized
            local cached = core.geo[t]
            local old_geos, leaf_ids = {}, {}
            if cached then
                for id, g in pairs(cached.geos) do
                    old_geos[id] = g
                    table.insert(leaf_ids, id)
                end
            end
            leaf.minimized = not leaf.minimized
            if #leaf_ids > 0 then
                local min_leaf = is_minimizing and leaf or nil
                if min_leaf then min_leaf.min_anim = true end
                anim.reflow_pending[s] = {
                    old_geos = old_geos, leaf_ids = leaf_ids, min_leaf = min_leaf,
                }
            end
            awful.layout.arrange(s)
        end,
    }
end

---------------------------------------------------------------------------
-- Resizing
---------------------------------------------------------------------------

-- Grow/shrink the focused leaf against its adjacent sibling.
function ops.resize_focused(t, delta)
    local state = core.state(t)
    local leaf = core.focused_leaf(state)
    if not leaf then return false end
    local parent, idx = tree.find_parent(state.root, leaf)
    if not parent then return false end
    local N = #parent.children
    local other = idx < N and idx + 1 or idx - 1
    local min_r = 0.01
    local cur       = parent.ratios[idx]   or (1 / N)
    local cur_other = parent.ratios[other] or (1 / N)
    local new_cur   = math.max(min_r, cur + delta)
    parent.ratios[idx]   = new_cur
    parent.ratios[other] = math.max(min_r, cur_other - (new_cur - cur))
    return true
end

---------------------------------------------------------------------------
-- Inserting columns (gap "+" buttons and edges)
---------------------------------------------------------------------------

-- Insert a new full-height leaf to the right of branch.children[left_idx].
-- For root-level branches, grows canvas_w so the new column gets fresh space.
function ops.insert_column_at_gap(t, s, b)
    local state  = core.state(t)
    local wa     = s.workarea
    local gap    = theme.gap()
    local branch = b.branch
    local N      = #branch.children
    local old_usable = b.usable  -- usable width of this branch from last layout

    -- Normalize existing ratios to current absolute widths.
    local rs = 0
    for _, r in ipairs(branch.ratios) do rs = rs + r end
    if rs <= 0 then rs = 1 end
    local abs_ws = {}
    for j = 1, N do abs_ws[j] = branch.ratios[j] / rs * old_usable end

    local new_leaf = tree.make_leaf()

    local default_w, new_usable
    if branch == state.root then
        -- Root-level: grow the canvas so existing children keep their widths.
        default_w  = math.floor(wa.width / 2)
        state.canvas_w = (state.canvas_w or wa.width) + default_w + gap
        new_usable = old_usable + default_w
    else
        -- Nested: redistribute existing space (no canvas change).
        default_w  = math.floor(old_usable / (N + 1))
        new_usable = old_usable
        for j = 1, N do
            abs_ws[j] = abs_ws[j] * new_usable / (new_usable + default_w)
        end
    end

    table.insert(abs_ws,          b.left_idx + 1, default_w)
    table.insert(branch.children, b.left_idx + 1, new_leaf)
    for j = 1, N + 1 do branch.ratios[j] = abs_ws[j] / new_usable end
    while #branch.ratios > N + 1 do table.remove(branch.ratios) end

    state.focused_leaf_id = new_leaf.id
    awful.layout.arrange(s)
    gears.timer.delayed_call(function() scroll.ensure_in_view(s, t) end)
end

local function insert_at_edge(t, s, left)
    local state  = core.state(t)
    local wa     = s.workarea
    local gap    = theme.gap()
    local new_w  = math.floor(wa.width / 2)
    local old_cw = state.canvas_w or wa.width

    local new_leaf = tree.make_leaf()
    local old_root = state.root

    if old_root.direction == tree.DIR_H then
        local N          = #old_root.children
        local old_usable = old_cw - (N - 1) * gap
        local rs = 0
        for _, r in ipairs(old_root.ratios) do rs = rs + r end
        if rs <= 0 then rs = 1 end
        local abs_ws = {}
        for j = 1, N do abs_ws[j] = old_root.ratios[j] / rs * old_usable end
        if left then
            table.insert(abs_ws, 1, new_w)
            table.insert(old_root.children, 1, new_leaf)
        else
            table.insert(abs_ws, new_w)
            table.insert(old_root.children, new_leaf)
        end
        state.canvas_w = old_cw + new_w + gap
        local new_usable = old_usable + new_w
        for j = 1, N + 1 do old_root.ratios[j] = abs_ws[j] / new_usable end
        while #old_root.ratios > N + 1 do table.remove(old_root.ratios) end
    else
        local r       = left and (new_w / (old_cw + new_w)) or (old_cw / (old_cw + new_w))
        local child_a = left and new_leaf or old_root
        local child_b = left and old_root or new_leaf
        state.root     = tree.make_branch(tree.DIR_H, r, child_a, child_b)
        state.canvas_w = old_cw + new_w + gap
    end

    if left then
        -- Shift scroll so existing content keeps its screen position.
        state.scroll_x      = (state.scroll_x or 0) + new_w + gap
        state.scroll_target = state.scroll_x
    end

    state.focused_leaf_id = new_leaf.id
    awful.layout.arrange(s)
    gears.timer.delayed_call(function() scroll.ensure_in_view(s, t) end)
end

function ops.insert_at_right_edge(t, s) insert_at_edge(t, s, false) end
function ops.insert_at_left_edge(t, s)  insert_at_edge(t, s, true)  end

---------------------------------------------------------------------------
-- Pickup / drop
---------------------------------------------------------------------------

local function swap_split_tabs(state, leaf_a_id, leaf_b_id)
    local a = core.leaf(state, leaf_a_id)
    local b = core.leaf(state, leaf_b_id)
    if not a or not b then return end
    a.tabs, b.tabs = b.tabs, a.tabs
    a.active_tab, b.active_tab = b.active_tab, a.active_tab
    a.active_tab = core.clamp_tab_index(a.active_tab, #a.tabs)
    b.active_tab = core.clamp_tab_index(b.active_tab, #b.tabs)
end

-- A picked-up split was dropped on leaf_id: swap tab stacks, then arrange.
function ops.handle_split_pickup(state, leaf_id, s)
    local pickup = core.drag.pickup
    if pickup.split_id ~= leaf_id and core.leaf(state, pickup.split_id) then
        swap_split_tabs(state, pickup.split_id, leaf_id)
        state.focused_leaf_id = leaf_id
    end
    focus.leaf_after_arrange(state, leaf_id)
    core.drop_pickup()
    awful.layout.arrange(s)
end

-- A picked-up client was dropped on leaf_id.
function ops.try_drop_picked_up(t, leaf_id)
    local pickup = core.drag.pickup
    if pickup.tag ~= "client" then return false end
    if not pickup.client.valid then core.drop_pickup(); return false end

    local c = pickup.client
    if not ops.move_client_to_leaf_id(t, leaf_id, c,
            { arrange = false, focus = false }) then
        core.drop_pickup()
        return false
    end
    core.drop_pickup()
    focus.after_arrange(c, leaf_id)
    smush.after_layout(t.screen, leaf_id)
    return true
end

-- Drop a picked-up tab into a newly created split adjacent to leaf_id.
-- new_leaf_first: true = new leaf becomes the left/top child.
function ops.drop_into_new_split(t, leaf_id, direction, new_leaf_first)
    local pickup = core.drag.pickup
    if pickup.tag ~= "client" then return false end
    if not pickup.client.valid then core.drop_pickup(); return false end
    local state = core.state(t)
    local target = core.leaf(state, leaf_id)
    if not target then core.drop_pickup(); return false end

    -- Capture old geometry before mutation, for the split animation.
    local old_geo = core.geo[t] and core.geo[t].geos[leaf_id]

    local c = pickup.client
    ops.unpin_client(state.root, c)

    local child_existing = tree.make_leaf()
    child_existing.tabs       = target.tabs
    child_existing.active_tab = target.active_tab
    local child_new = tree.make_leaf()
    child_new.tabs       = { c }
    child_new.active_tab = 1

    local child_a = new_leaf_first and child_new or child_existing
    local child_b = new_leaf_first and child_existing or child_new
    split_node(state, target, direction, child_a, child_b)

    colors.resolve_color_conflict(child_new, c)
    state.focused_leaf_id = child_new.id
    core.drop_pickup()
    focus.after_arrange(c, child_new.id)
    smush.after_layout(t.screen, child_new.id)

    if old_geo then
        local s = core.screen_of(t.screen)
        if s then
            anim.split_pending[s] = {
                old_geo = old_geo,
                a_id    = child_existing.id,
                b_id    = child_new.id,
                dir     = direction,
            }
        end
    end
    return true
end

return ops
