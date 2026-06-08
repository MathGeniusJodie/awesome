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
local tree      = require("splitwm.tree")
local colors    = require("splitwm.colors")
local tb        = require("splitwm.titlebar")
local underlay  = require("splitwm.underlay")
local anim      = require("splitwm.animation")

local splitwm = {}

-- Color constants read from theme (mandatory — no fallbacks)
local color_bg             -- pure black
local color_fg             -- pure white
local color_fg_disabled    -- dimmed foreground for disabled icons
local color_btn_bg         -- transparent circle button bg
local color_transparent    -- fully transparent
local color_fg_hover       -- hover highlight for launcher widgets
local color_handle         -- drag handle pill color
local color_close          -- close-button hover foreground

-- Base height of the tab bar.
local TITLEBAR_HEIGHT = 34

-- Button geometry — used to derive split minimum sizes.
local BTN_SIZE     = 26
local BTN_SPACING  = 5
local N_SPLIT_BTNS = 5  -- minimize + swap + split (auto) + close + "+"
local MIN_SPLIT_W  = N_SPLIT_BTNS * BTN_SIZE + (N_SPLIT_BTNS - 1) * BTN_SPACING
local MIN_SPLIT_H  = TITLEBAR_HEIGHT

-- Initial ratio when splitting a leaf (golden ratio: larger side for existing content).
local SPLIT_RATIO = 0.618

-- Ratio delta applied per grow/shrink keypress.
local RESIZE_STEP = 0.05

-- Send Ctrl+0 plus one or two Ctrl+- presses to active clients in narrow splits.
local DEFAULT_SMUSH_WIDTH_THRESHOLD = 900
local DEFAULT_TINY_SMUSH_WIDTH_THRESHOLD = 650
local smush_helper = gears.filesystem.get_configuration_dir() .. "splitwm/smushkeys"
local smush_state = setmetatable({}, { __mode = "k" })
local smush_queue = {}
local smush_queue_running = false
local smush_restore_client = nil
local smush_restore_leaf_id = nil
local smush_focus_client = nil

local function smush_command(mode)
    if mode == "reset" then
        return { smush_helper, "reset" }
    elseif mode == "tiny" then
        return { smush_helper, "tiny" }
    end
    return smush_helper
end

local process_smush_queue

local function restore_focus_after_smush()
    local restore = smush_restore_client
    local restore_leaf_id = smush_restore_leaf_id
    smush_restore_client = nil
    smush_restore_leaf_id = nil
    smush_focus_client = nil
    smush_queue_running = false
    if not (restore and restore.valid) then return end
    if splitwm.focus_client_after_arrange then
        splitwm.focus_client_after_arrange(restore, restore_leaf_id)
    else
        client.focus = restore
        restore:raise()
    end
end

process_smush_queue = function()
    local item = table.remove(smush_queue, 1)
    if not item then
        restore_focus_after_smush()
        return
    end

    local c = item.client
    if not (c and c.valid) then
        gears.timer.delayed_call(process_smush_queue)
        return
    end

    smush_focus_client = c
    client.focus = c
    c:raise()
    gears.timer.start_new(0.035, function()
        local function next_item()
            gears.timer.start_new(0.02, function()
                process_smush_queue()
                return false
            end)
        end
        if c.valid then
            local pid = awful.spawn.easy_async(smush_command(item.mode), function() next_item() end)
            if not pid then next_item() end
        else
            next_item()
        end
        return false
    end)
end

local function send_smush_shortcuts(c, mode, restore_client, restore_leaf_id)
    if not c or not c.valid or not gears.filesystem.file_executable(smush_helper) then return end
    if restore_client and restore_client.valid then
        smush_restore_client = restore_client
        smush_restore_leaf_id = restore_leaf_id
    end
    table.insert(smush_queue, { client = c, mode = mode })
    if not smush_queue_running then
        smush_queue_running = true
        gears.timer.delayed_call(process_smush_queue)
    end
end

-- Effective titlebar height: grows to match gap so the bar never disappears into it.
local function effective_tb_h(gap) return math.max(TITLEBAR_HEIGHT, gap) end

-- Geometry of the client area inside a leaf, accounting for border, titlebar, and scroll.
-- geo is the raw leaf rectangle from compute_tree (canvas coords); scroll_x shifts x left.
local function client_geo(geo, bw, gap, tb_h, scroll_x)
    return {
        x      = geo.x + bw - (scroll_x or 0),
        y      = geo.y - gap + tb_h,
        width  = math.max(1, geo.width  - bw * 2),
        height = math.max(1, geo.height + gap - bw - tb_h),
    }
end

---------------------------------------------------------------------------
-- App launchers (configurable from rc.lua via splitwm.launchers)
---------------------------------------------------------------------------
splitwm.launchers = {}  -- set from rc.lua before calling setup()

-- Tab shape exported so rc.lua wibar capsules can match the tab profile.
splitwm.tab_shape = tb.tab_shape

-- Shared pickup / pending-drag state (owned by titlebar module).
local drag          = tb.drag
local pickup_idle   = tb.pickup_idle
local pickup_client = tb.pickup_client
local pickup_split  = tb.pickup_split

local drag_hover_timer = nil  -- polling timer for switching tabs when dragging over the tab bar
local focus_guard      = nil  -- transient guard for explicit focus requests
local focus_request_seq = 0

function splitwm.guard_focus(c, timeout, leaf_id)
    if not c or not c.valid then return end
    local guard = { client = c, leaf_id = leaf_id }
    focus_guard = guard
    gears.timer.start_new(timeout or 0.35, function()
        if focus_guard == guard then focus_guard = nil end
        return false
    end)
end

local function force_focus_now(c, leaf_id)
    if not c or not c.valid then return end
    splitwm.guard_focus(c, nil, leaf_id)
    if smush_queue_running then
        smush_restore_client = c
        smush_restore_leaf_id = leaf_id
        return
    end
    client.focus = c
    c:raise()
end

function splitwm.focus_client_after_arrange(c, leaf_id)
    if not c or not c.valid then return end
    focus_request_seq = focus_request_seq + 1
    local seq = focus_request_seq
    splitwm.guard_focus(c, nil, leaf_id)
    gears.timer.delayed_call(function()
        if seq ~= focus_request_seq then return end
        force_focus_now(c, leaf_id)
        gears.timer.start_new(0.05, function()
            if seq == focus_request_seq and c.valid and client.focus ~= c then
                force_focus_now(c, leaf_id)
            end
            return false
        end)
        gears.timer.start_new(0.16, function()
            if seq == focus_request_seq and c.valid and client.focus ~= c then
                force_focus_now(c, leaf_id)
            end
            return false
        end)
    end)
end

---------------------------------------------------------------------------
-- Per-tag state
---------------------------------------------------------------------------

local tag_state = setmetatable({}, { __mode = "k" })

local geo_cache          = setmetatable({}, { __mode = "k" })  -- [tag] = { geos={}, bounds={} }
local client_actual_geo  = {}   -- [client] = actual geometry after size-hint snapping
local client_last_target = {}   -- [client] = last geometry we requested in arrange()
local scroll_anim_active = {}   -- [screen] = {timer}
local last_focused_leaf  = {}   -- [screen] = leaf_id; used to detect focus changes in update_ui

local function get_state(t)
    if not tag_state[t] then
        local root = tree.make_leaf()
        tag_state[t] = { root = root, focused_leaf_id = root.id,
                         scroll_x = 0, scroll_target = 0, canvas_w = nil }
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
    return tree.find_leaf_by_id(state.root, state.focused_leaf_id)
end

local function get_leaf(state, leaf_id)
    return state and tree.find_leaf_by_id(state.root, leaf_id) or nil
end

-- Returns (leaf, state, tag) for a client, or (nil, nil, nil) if any step fails.
local function get_leaf_from_client(c)
    local t, state = get_tag_state(c)
    if not state then return nil, nil, nil end
    return tree.find_leaf_for_client(state.root, c), state, t
end

local function focus_leaf_after_arrange(state, leaf_id)
    local leaf = get_leaf(state, leaf_id)
    local c = leaf and leaf.tabs[leaf.active_tab]
    if c and c.valid then splitwm.focus_client_after_arrange(c, leaf_id) end
end

local function smush_leaf_if_narrow(t, state, leaf, restore_client, restore_leaf_id)
    if not leaf or leaf.active_tab <= 0 then return end
    local cached = geo_cache[t]
    local geo = cached and cached.geos[leaf.id]
    if not geo then return end

    local c = leaf.tabs[leaf.active_tab]
    if not c or not c.valid or c.hidden or c.minimized or c.fullscreen then return end

    local threshold = beautiful.splitwm_smush_width_threshold or DEFAULT_SMUSH_WIDTH_THRESHOLD
    local tiny_threshold = beautiful.splitwm_tiny_smush_width_threshold
        or DEFAULT_TINY_SMUSH_WIDTH_THRESHOLD
    if geo.width >= threshold then
        if smush_state[c] and smush_state[c].mode ~= "wide" then
            smush_state[c] = { mode = "wide" }
            send_smush_shortcuts(c, "reset", restore_client, restore_leaf_id)
        end
        return
    end

    local mode = geo.width < tiny_threshold and "tiny" or "narrow"
    local bucket = math.floor(geo.width / 25)
    local state_key = tostring(leaf.id) .. ":" .. tostring(bucket)
    if smush_state[c]
            and smush_state[c].mode == mode
            and smush_state[c].key == state_key then return end
    smush_state[c] = { mode = mode, key = state_key }
    send_smush_shortcuts(c, mode, restore_client, restore_leaf_id)
end

local function smush_after_layout(s, leaf_id)
    if type(s) == "number" then s = screen[s] end
    local t = s and s.selected_tag
    if not t then return end
    gears.timer.delayed_call(function()
        local state = tag_state[t]
        if not state then return end
        local focused_leaf = get_focused_leaf(state)
        local restore_client = focused_leaf and focused_leaf.tabs[focused_leaf.active_tab]
        local restore_leaf_id = focused_leaf and focused_leaf.id
        if leaf_id then
            smush_leaf_if_narrow(t, state, get_leaf(state, leaf_id),
                restore_client, restore_leaf_id)
        else
            for _, leaf in ipairs(tree.collect_leaves(state.root)) do
                smush_leaf_if_narrow(t, state, leaf, restore_client, restore_leaf_id)
            end
        end
    end)
end


---------------------------------------------------------------------------
-- Client management
---------------------------------------------------------------------------

local function tab_index_for_client(leaf, c)
    if not leaf or not c then return nil end
    for i, tc in ipairs(leaf.tabs) do
        if tc == c then return i end
    end
    return nil
end

local function clamp_tab_index(idx, n)
    if n <= 0 then return 0 end
    idx = math.floor(tonumber(idx) or 0)
    if idx < 1 then return 1 end
    if idx > n then return n end
    return idx
end

local function arrange_tab_operation(t, c, opts)
    if opts and opts.arrange == false then return end
    local s = (opts and opts.screen) or (t and t.screen) or (c and c.screen)
    if s then awful.layout.arrange(s) end
end

local function focus_tab_operation(c, leaf_id, opts)
    if opts and opts.focus == false then return end
    if splitwm.focus_client_after_arrange then
        splitwm.focus_client_after_arrange(c, leaf_id)
    elseif c and c.valid then
        client.focus = c
        c:raise()
    end
end

local next_client_request = nil

function splitwm.expect_next_client(opts)
    opts = opts or {}
    local s = opts.screen or awful.screen.focused()
    if type(s) == "number" then s = screen[s] end
    local t = opts.tag or (s and s.selected_tag)
    if not t then return nil end

    local state = get_state(t)
    local leaf = opts.leaf_id and get_leaf(state, opts.leaf_id)
        or get_focused_leaf(state)
        or tree.collect_leaves(state.root)[1]
    if not leaf then return nil end

    state.focused_leaf_id = leaf.id
    local request = {
        tag     = t,
        leaf_id = leaf.id,
        append  = opts.append == true,
    }
    next_client_request = request
    gears.timer.start_new(opts.timeout or 4, function()
        if next_client_request == request then next_client_request = nil end
        return false
    end)
    return request
end

function splitwm.spawn(cmd, opts)
    splitwm.expect_next_client(opts)
    return awful.spawn(cmd)
end

local function take_next_client_request(t)
    local request = next_client_request
    if not request or request.tag ~= t then return nil, nil end

    local state = tag_state[t]
    local leaf = state and get_leaf(state, request.leaf_id)
    next_client_request = nil
    if not leaf then return nil, nil end
    return request, leaf
end

local function pin_client(t, c)
    local state = get_state(t)
    local request, leaf = take_next_client_request(t)
    if not leaf then leaf = get_focused_leaf(state) end
    if not leaf then leaf = tree.collect_leaves(state.root)[1] end
    for _, tc in ipairs(leaf.tabs) do if tc == c then return end end
    local insert_pos
    if request and request.append then
        insert_pos = #leaf.tabs + 1
    else
        insert_pos = leaf.active_tab + 1
    end
    table.insert(leaf.tabs, insert_pos, c)
    leaf.active_tab = insert_pos
end

local function remove_client_from_leaf(leaf, c)
    local removed = false
    local i = 1
    while i <= #leaf.tabs do
        if leaf.tabs[i] == c then
            table.remove(leaf.tabs, i)
            removed = true
            if i < leaf.active_tab then
                leaf.active_tab = leaf.active_tab - 1
            elseif i == leaf.active_tab then
                leaf.active_tab = clamp_tab_index(i - 1, #leaf.tabs)
            end
        else
            i = i + 1
        end
    end
    leaf.active_tab = clamp_tab_index(leaf.active_tab, #leaf.tabs)
    return removed
end

local function unpin_client(root, c)
    for _, leaf in ipairs(tree.collect_leaves(root)) do
        if remove_client_from_leaf(leaf, c) then
            colors.recheck_preferred(leaf, c)
        end
    end
end

local function remove_client_from_other_leaves(state, c, keep_leaf)
    local removed = false
    for _, leaf in ipairs(tree.collect_leaves(state.root)) do
        if leaf ~= keep_leaf and remove_client_from_leaf(leaf, c) then
            removed = true
            colors.recheck_preferred(leaf, c)
        end
    end
    return removed
end

local function move_client_to_leaf(root, c, target_leaf)
    unpin_client(root, c)
    for _, tc in ipairs(target_leaf.tabs) do if tc == c then return end end
    local insert_pos = target_leaf.active_tab + 1
    table.insert(target_leaf.tabs, insert_pos, c)
    target_leaf.active_tab = insert_pos
end

local function activate_client_in_leaf(t, leaf_id, c, opts)
    if not (t and c and c.valid) then return false end
    local state = get_state(t)
    local leaf = get_leaf(state, leaf_id)
    if not leaf then return false end

    local tab_idx = tab_index_for_client(leaf, c)
    if not tab_idx then return false end

    leaf.active_tab = tab_idx
    state.focused_leaf_id = leaf.id
    arrange_tab_operation(t, c, opts)
    focus_tab_operation(c, leaf.id, opts)
    return true
end

local function move_client_to_leaf_id(t, leaf_id, c, opts)
    if not (t and c and c.valid) then return false end
    local state = get_state(t)
    local target_leaf = get_leaf(state, leaf_id)
    if not target_leaf then return false end

    local src_tag = c.first_tag
    if src_tag and src_tag ~= t then
        local src_state = tag_state[src_tag]
        if src_state then unpin_client(src_state.root, c) end
        c:move_to_tag(t)
    end

    if tab_index_for_client(target_leaf, c) then
        remove_client_from_other_leaves(state, c, target_leaf)
        return activate_client_in_leaf(t, target_leaf.id, c, opts)
    end

    remove_client_from_other_leaves(state, c, nil)
    local insert_pos = target_leaf.active_tab > 0
        and target_leaf.active_tab + 1
        or #target_leaf.tabs + 1
    table.insert(target_leaf.tabs, insert_pos, c)
    target_leaf.active_tab = insert_pos
    state.focused_leaf_id = target_leaf.id
    colors.resolve_color_conflict(target_leaf, c)
    arrange_tab_operation(t, c, opts)
    focus_tab_operation(c, target_leaf.id, opts)
    return true
end

local function swap_client_to_tab_index(t, leaf_id, c, target_idx, opts)
    if not (t and c and c.valid) then return false end
    target_idx = math.floor(tonumber(target_idx) or 0)

    local state = get_state(t)
    local leaf = get_leaf(state, leaf_id)
    if not leaf or target_idx < 1 or target_idx > #leaf.tabs then return false end

    local current_idx = tab_index_for_client(leaf, c)
    if not current_idx then return false end
    if current_idx ~= target_idx then
        leaf.tabs[current_idx], leaf.tabs[target_idx] =
            leaf.tabs[target_idx], leaf.tabs[current_idx]
    end
    leaf.active_tab = target_idx
    state.focused_leaf_id = leaf.id
    arrange_tab_operation(t, c, opts)
    focus_tab_operation(c, leaf.id, opts)
    return true
end

local function swap_split_tabs(state, leaf_a_id, leaf_b_id)
    local leaf_a = get_leaf(state, leaf_a_id)
    local leaf_b = get_leaf(state, leaf_b_id)
    if not leaf_a or not leaf_b then return end
    leaf_a.tabs, leaf_b.tabs = leaf_b.tabs, leaf_a.tabs
    leaf_a.active_tab, leaf_b.active_tab = leaf_b.active_tab, leaf_a.active_tab
    leaf_a.active_tab = clamp_tab_index(leaf_a.active_tab, #leaf_a.tabs)
    leaf_b.active_tab = clamp_tab_index(leaf_b.active_tab, #leaf_b.tabs)
end

-- Called when pickup tag=="split" is active: swaps tabs if different leaf, then arranges.
local function handle_split_pickup(state, leaf_id, s)
    if drag.pickup.split_id ~= leaf_id then
        if get_leaf(state, drag.pickup.split_id) then
            -- Same tag: simple in-place swap
            swap_split_tabs(state, drag.pickup.split_id, leaf_id)
            state.focused_leaf_id = leaf_id
        else
            -- Different tag: find source state and swap clients across tags
            local src_state, src_t
            for t, ts in pairs(tag_state) do
                if get_leaf(ts, drag.pickup.split_id) then
                    src_state = ts
                    src_t = t
                    break
                end
            end
            if src_state then
                local src_leaf = get_leaf(src_state, drag.pickup.split_id)
                local dst_leaf = get_leaf(state, leaf_id)
                local dst_t    = s.selected_tag
                if src_leaf and dst_leaf and src_t and dst_t then
                    local src_clients  = src_leaf.tabs
                    local dst_clients  = dst_leaf.tabs
                    local src_active   = src_leaf.active_tab
                    local dst_active   = dst_leaf.active_tab
                    src_leaf.tabs      = dst_clients
                    src_leaf.active_tab = clamp_tab_index(dst_active, #dst_clients)
                    dst_leaf.tabs      = src_clients
                    dst_leaf.active_tab = clamp_tab_index(src_active, #src_clients)
                    for _, c in ipairs(src_leaf.tabs) do if c.valid then c:move_to_tag(src_t) end end
                    for _, c in ipairs(dst_leaf.tabs) do if c.valid then c:move_to_tag(dst_t) end end
                    state.focused_leaf_id = leaf_id
                    if src_t.screen then awful.layout.arrange(src_t.screen) end
                end
            end
        end
    end
    focus_leaf_after_arrange(state, leaf_id)
    drag.pickup = pickup_idle()
    awful.layout.arrange(s)
end

local function try_drop_picked_up(t, leaf_id)
    if drag.pickup.tag ~= "client" then return false end
    if not drag.pickup.client.valid then drag.pickup = pickup_idle(); return false end
    local state = get_state(t)
    local target = get_leaf(state, leaf_id)
    if not target then drag.pickup = pickup_idle(); return false end

    local c       = drag.pickup.client
    local src_tag = drag.pickup.client_tag

    if src_tag then
        local src_state = tag_state[src_tag]
        if src_state then unpin_client(src_state.root, c) end
    end
    if src_tag ~= t then c:move_to_tag(t) end

    move_client_to_leaf(state.root, c, target)
    state.focused_leaf_id = leaf_id
    drag.pickup = pickup_idle()
    colors.resolve_color_conflict(target, c)
    splitwm.focus_client_after_arrange(c, leaf_id)
    smush_after_layout(t.screen, leaf_id)

    if src_tag and src_tag ~= t and src_tag.screen then awful.layout.arrange(src_tag.screen) end
    return true
end

-- Drop a picked-up tab into a newly created split adjacent to target_leaf.
-- direction: tree.DIR_H or tree.DIR_V
-- new_leaf_first: true = new leaf is child_a (left/top), false = child_b (right/bottom)
local function drop_into_new_split(t, leaf_id, direction, new_leaf_first)
    if drag.pickup.tag ~= "client" then return false end
    if not drag.pickup.client.valid then drag.pickup = pickup_idle(); return false end
    local state = get_state(t)
    local target_leaf = get_leaf(state, leaf_id)
    if not target_leaf then drag.pickup = pickup_idle(); return false end

    -- Capture old geometry before tree mutation for animation.
    local old_geo = geo_cache[t] and geo_cache[t].geos[leaf_id]

    local c       = drag.pickup.client
    local src_tag = drag.pickup.client_tag

    if src_tag then
        local src_state = tag_state[src_tag]
        if src_state then unpin_client(src_state.root, c) end
    end
    if src_tag ~= t then c:move_to_tag(t) end

    -- Build the two new children: one keeps the target's tabs, one gets the dragged client.
    local child_existing = tree.make_leaf()
    child_existing.tabs       = target_leaf.tabs
    child_existing.active_tab = target_leaf.active_tab
    local child_new = tree.make_leaf()
    table.insert(child_new.tabs, c)
    child_new.active_tab = 1

    local child_a = new_leaf_first and child_new or child_existing
    local child_b = new_leaf_first and child_existing or child_new

    if direction == tree.DIR_H then
        local parent, idx = tree.find_parent(state.root, target_leaf)
        if parent and parent.direction == tree.DIR_H then
            -- Flatten: insert into existing horizontal branch.
            local old_r = parent.ratios[idx]
            parent.ratios[idx] = old_r * SPLIT_RATIO
            table.insert(parent.ratios, idx + 1, old_r * (1 - SPLIT_RATIO))
            parent.children[idx] = child_a
            table.insert(parent.children, idx + 1, child_b)
        else
            local new_branch = tree.make_branch(direction, SPLIT_RATIO, child_a, child_b)
            if target_leaf == state.root then
                state.root = new_branch
            else
                parent.children[idx] = new_branch
            end
        end
    else
        local new_branch = tree.make_branch(direction, SPLIT_RATIO, child_a, child_b)
        if target_leaf == state.root then
            state.root = new_branch
        else
            local parent, idx = tree.find_parent(state.root, target_leaf)
            parent.children[idx] = new_branch
        end
    end

    colors.resolve_color_conflict(child_new, c)
    state.focused_leaf_id = child_new.id
    drag.pickup = pickup_idle()
    splitwm.focus_client_after_arrange(c, child_new.id)
    smush_after_layout(t.screen, child_new.id)

    -- Queue split animation: existing leaf animates from old_geo, new leaf slides in from edge.
    if old_geo then
        local s = t.screen
        if type(s) == "number" then s = screen[s] end
        if s then
            anim.split_anim_pending[s] = {
                old_geo = old_geo,
                a_id    = child_existing.id,
                b_id    = child_new.id,
                dir     = direction,
            }
        end
    end

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

    if direction == tree.DIR_H then
        local parent, idx = tree.find_parent(state.root, leaf)
        if parent and parent.direction == tree.DIR_H then
            -- Flatten: insert child_b right after child_a in the existing branch
            local old_r = parent.ratios[idx]
            parent.ratios[idx] = old_r * SPLIT_RATIO
            table.insert(parent.ratios, idx + 1, old_r * (1 - SPLIT_RATIO))
            parent.children[idx] = child_a
            table.insert(parent.children, idx + 1, child_b)
            state.focused_leaf_id = child_a.id
            return child_a.id, child_b.id
        end
    end

    -- Create new branch (vertical, or horizontal with no horizontal parent)
    local new_branch = tree.make_branch(direction, SPLIT_RATIO, child_a, child_b)
    if leaf == state.root then
        state.root = new_branch
    else
        local parent, idx = tree.find_parent(state.root, leaf)
        parent.children[idx] = new_branch
    end
    state.focused_leaf_id = child_a.id
    return child_a.id, child_b.id
end

local function close_leaf(t, leaf_id)
    local state = get_state(t)
    local leaf = get_leaf(state, leaf_id)
    if not leaf then return false end
    if drag.pickup.tag == "split" and drag.pickup.split_id == leaf_id then drag.pickup = pickup_idle() end
    if drag.pickup.tag == "client" and drag.pickup.client.valid
            and tree.find_leaf_for_client(state.root, drag.pickup.client) == leaf then
        drag.pickup = pickup_idle()
    end
    local parent, idx = tree.find_parent(state.root, leaf)
    if not parent then return false end

    -- Destination for the closed leaf's tabs: adjacent sibling leaf.
    local dest_idx = idx > 1 and (idx - 1) or 2
    local dest_sibling = parent.children[dest_idx]
    local dest_leaves  = tree.collect_leaves(dest_sibling)
    local dest         = dest_leaves[1]
    for _, tc in ipairs(leaf.tabs) do
        table.insert(dest.tabs, tc)
        colors.resolve_color_conflict(dest, tc)
    end
    if dest.active_tab == 0 and #dest.tabs > 0 then dest.active_tab = 1 end

    if parent.direction == tree.DIR_H and #parent.children > 2 then
        -- N-ary: remove this child and redistribute its ratio share.
        local removed_ratio = parent.ratios[idx]
        table.remove(parent.children, idx)
        table.remove(parent.ratios, idx)
        local remaining_sum = 0
        for _, r in ipairs(parent.ratios) do remaining_sum = remaining_sum + r end
        if remaining_sum > 0 then
            for i = 1, #parent.ratios do
                parent.ratios[i] = parent.ratios[i] + removed_ratio * parent.ratios[i] / remaining_sum
            end
        end
        -- Keep focused leaf if it's still in the tree, else focus adjacent child.
        local focused_id = state.focused_leaf_id
        local keep
        for _, child in ipairs(parent.children) do
            for _, l in ipairs(tree.collect_leaves(child)) do
                if l.id == focused_id then keep = l; break end
            end
            if keep then break end
        end
        local fallback_idx = math.min(idx, #parent.children)
        local fallback = tree.collect_leaves(parent.children[fallback_idx])[1]
        state.focused_leaf_id = keep and keep.id or fallback.id
    else
        -- Binary case (or DIR_V): collapse parent, sibling takes its place.
        local sibling_idx = idx == 1 and 2 or 1
        local sibling = parent.children[sibling_idx]
        local sibling_leaves = tree.collect_leaves(sibling)
        local focused_id = state.focused_leaf_id
        local keep
        for _, l in ipairs(sibling_leaves) do
            if l.id == focused_id then keep = l; break end
        end
        if parent == state.root then
            state.root = sibling
        else
            local grand_parent, parent_idx = tree.find_parent(state.root, parent)
            grand_parent.children[parent_idx] = sibling
        end
        state.focused_leaf_id = keep and keep.id or sibling_leaves[1].id
    end
    return true
end

local function close_leaf_with_anim(t, s, state, leaf_id)
    local leaf = get_leaf(state, leaf_id)
    local parent, pidx
    if leaf then parent, pidx = tree.find_parent(state.root, leaf) end
    local old_geos, sibling_ids
    local old_scroll_x = state.scroll_x or 0
    if parent then
        -- Collect leaves from ALL remaining children (not just one sibling subtree).
        local remaining = {}
        for i, child in ipairs(parent.children) do
            if i ~= pidx then
                for _, l in ipairs(tree.collect_leaves(child)) do
                    table.insert(remaining, l)
                end
            end
        end
        local cached = geo_cache[t]
        if cached and #remaining > 0 then
            sibling_ids = {}; old_geos = {}
            for _, l in ipairs(remaining) do
                sibling_ids[#sibling_ids + 1] = l.id
                old_geos[l.id] = cached.geos[l.id]
            end
        end
    end
    if close_leaf(t, leaf_id) == false then return end

    -- Clamp canvas_w if the remaining tree has no horizontal splits.
    local new_root = state.root
    local wa       = s.workarea
    if new_root and new_root.direction ~= tree.DIR_H then
        if (state.canvas_w or wa.width) > wa.width then
            state.canvas_w = wa.width
        end
    end

    awful.layout.arrange(s)
    focus_leaf_after_arrange(state, state.focused_leaf_id)

    -- Recompute scroll_x: keep current value but clamp to the valid range and
    -- ensure the focused split is within the viewport.  Do this after arrange so
    -- the new geo_cache is available.
    local final_scroll = old_scroll_x
    local cw           = state.canvas_w or wa.width
    local max_s        = math.max(0, cw - wa.width)
    local new_cached   = geo_cache[t]
    if new_cached then
        local fgeo = new_cached.geos[state.focused_leaf_id]
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
        -- Remap old canvas coords so the animation starts from the correct
        -- screen positions given the new scroll_x.
        for id, geo in pairs(old_geos) do
            old_geos[id] = { x      = geo.x - old_scroll_x + final_scroll,
                             y      = geo.y,
                             width  = geo.width,
                             height = geo.height }
        end
        anim.close_anim_pending[s] = { old_geos = old_geos, leaf_ids = sibling_ids }
    end
end

-- Returns callbacks table for the three split control actions (vsplit, hsplit, close).
local function make_split_action_callbacks(state, leaf_id, t, s)
    local function do_split(dir)
        state.focused_leaf_id = leaf_id
        local old_geo = geo_cache[t] and geo_cache[t].geos[leaf_id]
        local a_id, b_id = split_leaf(t, dir)
        awful.layout.arrange(s)
        focus_leaf_after_arrange(state, a_id)
        if old_geo and a_id then
            anim.split_anim_pending[s] = { old_geo = old_geo, a_id = a_id, b_id = b_id, dir = dir }
        end
    end
    return {
        vsplit          = function() do_split(tree.DIR_H) end,
        hsplit          = function() do_split(tree.DIR_V) end,
        close           = function() close_leaf_with_anim(t, s, state, leaf_id) end,
        minimize_toggle = function()
            local leaf = get_leaf(state, leaf_id)
            if not leaf then return end
            local is_minimizing = not leaf.minimized
            local cached = geo_cache[t]
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
                anim.minimize_anim_pending[s] = { old_geos = old_geos, leaf_ids = leaf_ids, min_leaf = min_leaf }
            end
            awful.layout.arrange(s)
        end,
    }
end

local function resize_focused(t, delta)
    local state = get_state(t)
    local leaf = get_focused_leaf(state)
    if not leaf then return false end
    local parent, idx = tree.find_parent(state.root, leaf)
    if not parent then return false end
    if parent.direction == tree.DIR_H then
        -- N-ary: adjust this child and the adjacent one.
        local N = #parent.children
        local other_idx = idx < N and idx + 1 or idx - 1
        local min_r = 0.01
        local cur       = parent.ratios[idx]       or (1 / N)
        local cur_other = parent.ratios[other_idx] or (1 / N)
        local new_cur   = math.max(min_r, cur + delta)
        local actual_d  = new_cur - cur
        parent.ratios[idx]       = new_cur
        parent.ratios[other_idx] = math.max(min_r, cur_other - actual_d)
    else
        -- DIR_V: binary
        local new_ratio = parent.ratio
        if idx == 1 then new_ratio = new_ratio + delta else new_ratio = new_ratio - delta end
        local min_r, max_r = 0.1, 0.9
        local cached = geo_cache[t]
        if cached then
            local l1 = tree.collect_leaves(parent.children[1])[1]
            local l2 = tree.collect_leaves(parent.children[2])[1]
            local g1 = l1 and cached.geos[l1.id]
            local g2 = l2 and cached.geos[l2.id]
            if g1 and g2 then
                min_r = MIN_SPLIT_H / (g1.height + g2.height + beautiful.splitwm_gap)
                max_r = 1 - min_r
            end
        end
        parent.ratio = math.max(min_r, math.min(max_r, new_ratio))
    end
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
    local c = leaf.tabs[leaf.active_tab]
    if c and c.valid then splitwm.focus_client_after_arrange(c, leaf.id) end
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
    if not c then return false end
    unpin_client(state.root, c)
    table.insert(dst_leaf.tabs, c)
    dst_leaf.active_tab = #dst_leaf.tabs
    colors.resolve_color_conflict(dst_leaf, c)
    state.focused_leaf_id = dst_leaf.id
    splitwm.focus_client_after_arrange(c, dst_leaf.id)
    return true
end

local function focus_direction(t, dir)
    local state = get_state(t)
    local leaf = adjacent_leaf(state, state.focused_leaf_id, dir)
    if not leaf then return false end
    state.focused_leaf_id = leaf.id
    focus_leaf_after_arrange(state, leaf.id)
    return true
end

---------------------------------------------------------------------------
-- The layout "arrange" function
---------------------------------------------------------------------------

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

    local root     = state.root
    local scroll_x = state.scroll_x or 0
    local canvas_w = state.canvas_w or wa.width

    local pinned = {}
    for _, leaf in ipairs(tree.collect_leaves(root)) do
        for _, tc in ipairs(leaf.tabs) do pinned[tc] = true end
    end
    for _, c in ipairs(cls) do
        if not pinned[c] then pin_client(tag, c) end
    end

    local geos, bounds = {}, {}
    tree.compute_tree(root, wa.x, wa.y, canvas_w, wa.height, gap, geos, bounds, effective_tb_h(gap))
    local s = p.screen
    if type(s) == "number" then s = screen[s] end
    geo_cache[tag] = { geos = geos, bounds = bounds }
    local bw   = beautiful.splitwm_focus_border_width
    local tb_h = effective_tb_h(gap)

    for _, leaf in ipairs(tree.collect_leaves(root)) do
        local geo = geos[leaf.id]
        if not geo then goto continue end

        -- Check if split is entirely outside the visible viewport.
        local vis_left  = geo.x - scroll_x
        local vis_right = vis_left + geo.width
        local off_screen = vis_right <= wa.x or vis_left >= wa.x + wa.width

        for i, c in ipairs(leaf.tabs) do
            if i == leaf.active_tab and leaf.active_tab > 0 and not off_screen and (not leaf.minimized or leaf.min_anim) then
                c.hidden = false
                c.border_width = 0
                if not c.fullscreen and not anim.is_active(s) then
                    local tgt = client_geo(geo, bw, gap, tb_h, scroll_x)
                    local ag   = client_actual_geo[c]
                    local last = client_last_target[c]
                    local skip = ag and last
                        and (ag.width < tgt.width - 1 and ag.height < tgt.height - 1)
                        and last.x == tgt.x and last.y == tgt.y
                        and last.width == tgt.width and last.height == tgt.height
                    if not skip then
                        c:geometry(tgt)
                        client_last_target[c] = tgt
                    end
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

splitwm.set_wallpaper = underlay.set_wallpaper

---------------------------------------------------------------------------
-- Unified UI update
---------------------------------------------------------------------------

local ensure_in_view    -- forward declaration

local function update_ui(s)
    local t, state = get_active_state(s)
    if not t then
        underlay.hide_drag_handles(s)
        if tb.cache[s] then
            for _, entry in pairs(tb.cache[s]) do
                entry.wb.visible = false
            end
        end
        return
    end

    local gap    = beautiful.splitwm_gap
    local cached = geo_cache[t]
    local geos, bounds
    if cached then
        geos, bounds = cached.geos, cached.bounds
    else
        local wa       = s.workarea
        local canvas_w = state.canvas_w or wa.width
        geos, bounds   = {}, {}
        tree.compute_tree(state.root, wa.x, wa.y, canvas_w, wa.height, gap, geos, bounds, effective_tb_h(gap))
    end

    local leaves = tree.collect_leaves(state.root)
    tb.update(s, t, state, geos, leaves)
    underlay.update_drag_handles(s, state, bounds, state.scroll_x or 0)

    local pending = anim.split_anim_pending[s]
    if pending then
        anim.split_anim_pending[s] = nil
        anim.start_split_anim(s, t, pending.old_geo, pending.a_id, pending.b_id, pending.dir)
        return
    end
    local cpending = anim.close_anim_pending[s]
    if cpending then
        anim.close_anim_pending[s] = nil
        anim.start_close_anim(s, t, cpending.old_geos, cpending.leaf_ids)
        return
    end
    local mpending = anim.minimize_anim_pending[s]
    if mpending then
        anim.minimize_anim_pending[s] = nil
        anim.start_minimize_anim(s, t, mpending.old_geos, mpending.leaf_ids, mpending.min_leaf)
        return
    end

    -- Scroll focused split into view whenever focus changes.
    local lid = state.focused_leaf_id
    if last_focused_leaf[s] ~= lid and not anim.is_active(s) then
        last_focused_leaf[s] = lid
        ensure_in_view(s, t)
    end
end

---------------------------------------------------------------------------
-- Horizontal scroll system
---------------------------------------------------------------------------

local SCROLL_STEP         = 100  -- pixels per discrete scroll event
local SCROLL_ANIM_FPS     = 60
local SCROLL_ANIM_DURATION = 0.05  -- seconds

local function start_scroll_anim(s, tag)
    local a = scroll_anim_active[s]
    if a then a.timer:stop(); scroll_anim_active[s] = nil end
    local state   = get_state(tag)
    local start_x = state.scroll_x or 0
    local target_x = state.scroll_target or 0
    if start_x == target_x then return end
    local frames = math.max(1, math.floor(SCROLL_ANIM_DURATION * SCROLL_ANIM_FPS))
    local frame  = 0
    local tim
    tim = gears.timer {
        timeout   = 1 / SCROLL_ANIM_FPS,
        autostart = true,
        call_now  = false,
        callback  = function()
            frame = frame + 1
            local p = math.min(frame / frames, 1.0)
            -- ease out quad
            p = 1 - (1 - p) * (1 - p)
            state.scroll_x = math.floor(start_x + (target_x - start_x) * p)
            if frame >= frames then
                state.scroll_x = target_x
                tim:stop()
                scroll_anim_active[s] = nil
            end
            awful.layout.arrange(s)
        end,
    }
    scroll_anim_active[s] = { timer = tim }
end

local function scroll_to(s, tag, target_x)
    local state    = get_state(tag)
    local wa       = s.workarea
    local canvas_w = state.canvas_w or wa.width
    local max_s    = math.max(0, canvas_w - wa.width)
    state.scroll_target = math.max(0, math.min(max_s, target_x))
    start_scroll_anim(s, tag)
end

ensure_in_view = function(s, tag)
    local state = tag_state[tag]
    if not state then return end
    local wa      = s.workarea
    local cached  = geo_cache[tag]
    if not cached then return end
    local geo = cached.geos[state.focused_leaf_id]
    if not geo then return end
    local sx     = state.scroll_x or 0
    local gap    = beautiful.splitwm_gap
    local target = sx
    if geo.x - sx < wa.x + gap then
        target = geo.x - wa.x - gap
    elseif geo.x + geo.width - sx > wa.x + wa.width - gap then
        target = geo.x + geo.width - wa.x - wa.width + gap
    end
    if target ~= sx then scroll_to(s, tag, target) end
end

-- Insert a new full-height leaf to the right of branch.children[left_idx].
-- For root-level branches, grows canvas_w to give the new column its own space.
local function insert_column_at_gap(t, s, b)
    local state   = get_state(t)
    local wa      = s.workarea
    local gap     = beautiful.splitwm_gap
    local branch  = b.branch
    local N       = #branch.children
    local old_usable = b.usable  -- usable space of this branch from last layout

    -- Normalize existing ratios to get current absolute widths.
    local rs = 0
    for _, r in ipairs(branch.ratios) do rs = rs + r end
    if rs <= 0 then rs = 1 end
    local abs_ws = {}
    for j = 1, N do abs_ws[j] = branch.ratios[j] / rs * old_usable end

    local new_leaf  = tree.make_leaf()

    local default_w, new_usable
    if branch == state.root then
        -- Root-level: grow canvas so existing children keep their widths.
        default_w  = math.floor(wa.width / 2)
        state.canvas_w = (state.canvas_w or wa.width) + default_w + gap
        new_usable = old_usable + default_w
    else
        -- Nested: redistribute existing space (no canvas change).
        default_w  = math.floor(old_usable / (N + 1))
        new_usable = old_usable
        -- Shrink each existing child proportionally to make room.
        for j = 1, N do abs_ws[j] = abs_ws[j] * new_usable / (new_usable + default_w) end
    end

    table.insert(abs_ws,          b.left_idx + 1, default_w)
    table.insert(branch.children, b.left_idx + 1, new_leaf)
    for j = 1, N + 1 do branch.ratios[j] = abs_ws[j] / new_usable end
    while #branch.ratios > N + 1 do table.remove(branch.ratios) end

    state.focused_leaf_id = new_leaf.id
    awful.layout.arrange(s)
    gears.timer.delayed_call(function() ensure_in_view(s, t) end)
end
splitwm.insert_column_at_gap = insert_column_at_gap

local function insert_at_edge(t, s, left)
    local state   = get_state(t)
    local wa      = s.workarea
    local gap     = beautiful.splitwm_gap
    local new_w   = math.floor(wa.width / 2)
    local old_cw  = state.canvas_w or wa.width

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
        state.root    = tree.make_branch(tree.DIR_H, r, child_a, child_b)
        state.canvas_w = old_cw + new_w + gap
    end

    if left then
        -- Shift scroll so existing content stays at the same screen position.
        state.scroll_x      = (state.scroll_x or 0) + new_w + gap
        state.scroll_target = state.scroll_x
    end

    state.focused_leaf_id = new_leaf.id
    awful.layout.arrange(s)
    gears.timer.delayed_call(function() ensure_in_view(s, t) end)
end

local function insert_at_right_edge(t, s) insert_at_edge(t, s, false) end
local function insert_at_left_edge(t, s)  insert_at_edge(t, s, true)  end

splitwm.activate_client_in_leaf = activate_client_in_leaf
splitwm.move_client_to_leaf_id  = move_client_to_leaf_id
splitwm.swap_client_to_tab_index = swap_client_to_tab_index

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

local function do_split_with_anim(dir)
    local s = awful.screen.focused()
    local t = s and s.selected_tag
    if not t then return end
    local state   = get_state(t)
    local leaf    = get_focused_leaf(state)
    local old_geo = leaf and geo_cache[t] and geo_cache[t].geos[leaf.id]
    local a_id, b_id = split_leaf(t, dir)
    if not a_id then return end
    awful.layout.arrange(s)
    focus_leaf_after_arrange(state, a_id)
    if old_geo then
        anim.split_anim_pending[s] = { old_geo = old_geo, a_id = a_id, b_id = b_id, dir = dir }
    end
end
splitwm.split_horizontal = function() do_split_with_anim(tree.DIR_H) end
splitwm.split_vertical   = function() do_split_with_anim(tree.DIR_V) end
splitwm.focus_next_split = function()
    local s = awful.screen.focused()
    local t = s and s.selected_tag
    if t and focus_direction(t, "next") ~= false then
        awful.layout.arrange(s)
        gears.timer.delayed_call(function() ensure_in_view(s, t) end)
    end
end
splitwm.focus_prev_split = function()
    local s = awful.screen.focused()
    local t = s and s.selected_tag
    if t and focus_direction(t, "prev") ~= false then
        awful.layout.arrange(s)
        gears.timer.delayed_call(function() ensure_in_view(s, t) end)
    end
end
splitwm.next_tab         = function() with_tag(function(t) return cycle_tab(t, 1) end) end
splitwm.prev_tab         = function() with_tag(function(t) return cycle_tab(t, -1) end) end
splitwm.move_tab_next    = function()
    with_tag(function(t)
        local ok = move_tab_to_direction(t, "next")
        if ok ~= false then smush_after_layout(t.screen, get_state(t).focused_leaf_id) end
        return ok
    end)
end
splitwm.move_tab_prev    = function()
    with_tag(function(t)
        local ok = move_tab_to_direction(t, "prev")
        if ok ~= false then smush_after_layout(t.screen, get_state(t).focused_leaf_id) end
        return ok
    end)
end
splitwm.resize_grow      = function()
    with_tag(function(t)
        local ok = resize_focused(t,  RESIZE_STEP)
        if ok ~= false then smush_after_layout(t.screen) end
        return ok
    end)
end
splitwm.resize_shrink    = function()
    with_tag(function(t)
        local ok = resize_focused(t, -RESIZE_STEP)
        if ok ~= false then smush_after_layout(t.screen) end
        return ok
    end)
end
splitwm.close_split = function()
    local s = awful.screen.focused()
    local t = s and s.selected_tag
    if not t then return end
    local state = get_state(t)
    close_leaf_with_anim(t, s, state, state.focused_leaf_id)
end


splitwm.scroll_delta = function(s, delta_x)
    local t = s and s.selected_tag
    if not t then return end
    local state = get_state(t)
    scroll_to(s, t, (state.scroll_x or 0) + delta_x)
end

---------------------------------------------------------------------------
-- Drag-over-tab hover switching
---------------------------------------------------------------------------

local function stop_drag_hover_poll()
    if drag_hover_timer then
        drag_hover_timer:stop()
        drag_hover_timer = nil
    end
end

local function start_drag_hover_poll()
    if drag_hover_timer then return end
    drag_hover_timer = gears.timer {
        timeout   = 0.05,
        call_now  = false,
        autostart = true,
        callback  = function()
            local m = mouse.coords()
            if not m.buttons[1] or drag.pickup.tag ~= "idle" or drag.pending ~= nil then
                stop_drag_hover_poll(); return
            end
            local mx, my   = m.x, m.y
            local gap      = beautiful.splitwm_gap
            local tb_h     = effective_tb_h(gap)
            local icon_sz  = tb_h - 2 * tb.TAB_CONTENT_V_PAD
            for s in screen do
                local t = s.selected_tag
                if not t then goto continue end
                local cached = geo_cache[t]
                local state  = tag_state[t]
                if not cached or not state then goto continue end
                local sx = state.scroll_x or 0
                for _, leaf in ipairs(tree.collect_leaves(state.root)) do
                    local lid = leaf.id
                    local g = cached.geos[lid]
                    local gx = g and g.x - sx
                    if g and mx >= gx and mx < gx + g.width
                           and my >= g.y - gap and my < g.y - gap + tb_h then
                        local tab_idx = tb.tab_index_at(mx - gx, leaf.active_tab, #leaf.tabs, icon_sz)
                        if tab_idx and tab_idx ~= leaf.active_tab and leaf.tabs[tab_idx] then
                            leaf.active_tab = tab_idx
                            state.focused_leaf_id = lid
                            awful.layout.arrange(s)
                            splitwm.focus_client_after_arrange(leaf.tabs[tab_idx], lid)
                        end
                        goto done
                    end
                end
                ::continue::
            end
            ::done::
        end,
    }
end

---------------------------------------------------------------------------
-- Setup & Caches
---------------------------------------------------------------------------

function splitwm.setup()
    color_bg             = beautiful.splitwm_color_bg
    color_fg             = beautiful.splitwm_color_fg
    color_fg_disabled    = beautiful.splitwm_fg_disabled
    color_btn_bg         = beautiful.splitwm_btn_bg
    color_transparent    = beautiful.splitwm_transparent
    color_handle         = beautiful.splitwm_handle_color
    color_fg_hover       = beautiful.splitwm_fg_hover    or "#ffffff20"
    color_close          = beautiful.splitwm_close_color or beautiful.splitwm_accent or "#ff6666ff"

    awesome.register_xproperty("splitwm_color", "string")

    anim.init({
        get_active_state = get_active_state,
        effective_tb_h   = effective_tb_h,
        client_geo       = client_geo,
        tb               = tb,
        geo_cache        = geo_cache,
        update_ui        = update_ui,
        on_split_anim_done = function(s) smush_after_layout(s) end,
        on_close_anim_done = function(s) smush_after_layout(s) end,
    })

    underlay.setup({
        BTN_SIZE          = BTN_SIZE,
        MIN_SPLIT_W       = MIN_SPLIT_W,
        MIN_SPLIT_H       = MIN_SPLIT_H,
        color_bg          = color_bg,
        color_fg          = color_fg,
        color_transparent = color_transparent,
        color_handle      = color_handle,
        SCROLL_STEP       = SCROLL_STEP,
        do_scroll         = function(s, delta_x)
            local t = s.selected_tag
            if not t then return end
            local state = get_state(t)
            scroll_to(s, t, (state.scroll_x or 0) + delta_x)
        end,
        insert_column_at_gap = function(s, b)
            local t = s.selected_tag
            if not t then return end
            insert_column_at_gap(t, s, b)
        end,
        insert_at_right_edge = function(s)
            local t = s.selected_tag
            if not t then return end
            insert_at_right_edge(t, s)
        end,
        insert_at_left_edge = function(s)
            local t = s.selected_tag
            if not t then return end
            insert_at_left_edge(t, s)
        end,
        get_state        = get_state,
        get_active_state = get_active_state,
        on_resize_finished = function(s) smush_after_layout(s) end,
    })

    tb.setup({
        geo_cache               = geo_cache,
        client_actual_geo       = client_actual_geo,
        split_anim_active       = anim.split_anim_active,
        try_drop_picked_up      = try_drop_picked_up,
        handle_split_pickup     = handle_split_pickup,
        drop_into_new_split     = drop_into_new_split,
        make_split_action_callbacks = make_split_action_callbacks,
        splitwm                 = splitwm,
        TITLEBAR_HEIGHT         = TITLEBAR_HEIGHT,
        BTN_SIZE                = BTN_SIZE,
        BTN_SPACING             = BTN_SPACING,
        MIN_SPLIT_W             = MIN_SPLIT_W,
        MIN_SPLIT_H             = MIN_SPLIT_H,
        color_bg                = color_bg,
        color_fg                = color_fg,
        color_fg_disabled       = color_fg_disabled,
        color_btn_bg            = color_btn_bg,
        color_transparent       = color_transparent,
        color_fg_hover          = color_fg_hover,
        color_handle            = color_handle,
        color_close             = color_close,
    })

    client.connect_signal("manage", function(c)
        tb.prepare_client_icon(c)
        local t = c.first_tag
        if not t then return end
        local state = get_state(t)
        local leaf = tree.find_leaf_for_client(state.root, c)
        if not leaf then
            pin_client(t, c); leaf = tree.find_leaf_for_client(state.root, c)
        end
        if leaf then colors.resolve_color_conflict(leaf, c) end
    end)

    client.connect_signal("unmanage", function(c)
        if drag.pickup.tag == "client" and drag.pickup.client == c then drag.pickup = pickup_idle() end
        if drag.pending and drag.pending.client == c then drag.pending = nil end
        for t, state in pairs(tag_state) do unpin_client(state.root, c) end
        client_actual_geo[c]  = nil
        client_last_target[c] = nil
    end)

    client.connect_signal("property::geometry", function(c)
        client_actual_geo[c] = c:geometry()
    end)

    local function refresh_client_icon(c)
        tb.prepare_client_icon(c)
        if c.screen then awful.layout.arrange(c.screen) end
    end
    client.connect_signal("property::class", refresh_client_icon)
    client.connect_signal("property::instance", refresh_client_icon)

    client.connect_signal("focus", function(c)
        if smush_focus_client == c then return end
        if focus_guard and focus_guard.client ~= c then
            local target = focus_guard.client
            local target_leaf_id = focus_guard.leaf_id
            if target and target.valid then
                gears.timer.delayed_call(function()
                    if focus_guard and focus_guard.client == target and target.valid
                            and client.focus ~= target then
                        force_focus_now(target, target_leaf_id)
                    end
                end)
            end
            return
        end
        local leaf, state
        local guarded_focus_leaf = false
        if focus_guard and focus_guard.client == c and focus_guard.leaf_id then
            local _, guarded_state = get_tag_state(c)
            local guarded_leaf = get_leaf(guarded_state, focus_guard.leaf_id)
            if guarded_leaf then
                leaf = guarded_leaf
                state = guarded_state
                guarded_focus_leaf = true
            end
        end
        if not leaf then leaf, state = get_leaf_from_client(c) end
        if not leaf then return end
        local tab_idx
        for i, tc in ipairs(leaf.tabs) do
            if tc == c then tab_idx = i; break end
        end
        if guarded_focus_leaf and not tab_idx then
            leaf, state = get_leaf_from_client(c)
            guarded_focus_leaf = false
            if not leaf then return end
            for i, tc in ipairs(leaf.tabs) do
                if tc == c then tab_idx = i; break end
            end
        end
        local needs_arrange = false
        if guarded_focus_leaf and tab_idx
                and remove_client_from_other_leaves(state, c, leaf) then
            needs_arrange = true
        end
        if tab_idx and leaf.active_tab ~= tab_idx then
            leaf.active_tab = tab_idx
            needs_arrange = true
        end
        if leaf.id ~= state.focused_leaf_id then
            state.focused_leaf_id = leaf.id
            needs_arrange = true
        end
        if smush_queue_running then
            smush_restore_client = c
            smush_restore_leaf_id = leaf.id
        end
        if needs_arrange then awful.layout.arrange(c.screen) end
        local t = c.first_tag
        if t then gears.timer.delayed_call(function() ensure_in_view(c.screen, t) end) end
    end)

    client.connect_signal("property::fullscreen", function(c)
        awful.layout.arrange(c.screen)
    end)

    client.connect_signal("button::press", function(c)
        local leaf, state, t = get_leaf_from_client(c)
        if not state then return end
        if drag.pickup.tag == "split" then
            if leaf and leaf.id ~= drag.pickup.split_id then
                handle_split_pickup(state, leaf.id, c.screen)
            end
        elseif drag.pickup.tag == "client" and drag.pickup.client.valid and drag.pickup.client ~= c then
            if leaf then try_drop_picked_up(t, leaf.id); awful.layout.arrange(c.screen) end
        elseif leaf and leaf.id ~= state.focused_leaf_id then
            state.focused_leaf_id = leaf.id
            awful.layout.arrange(c.screen)
        end
        if drag.pickup.tag == "idle" and drag.pending == nil then
            start_drag_hover_poll()
        end
    end)

    tag.connect_signal("property::selected", function(t)
        local s = t.screen
        if type(s) == "number" then s = screen[s] end
        drag.pending = nil
        if mousegrabber.isrunning() then mousegrabber.stop() end
        geo_cache[t] = nil
        if s then gears.timer.delayed_call(function() update_ui(s) end) end
        if t.selected and drag.pickup.tag == "client" and mouse.coords().buttons[1] then
            mousegrabber.run(function(m)
                if m.buttons[1] then return true end
                if drag.pickup.tag ~= "client" or not drag.pickup.client.valid then
                    drag.pickup = pickup_idle()
                    return false
                end
                local cached = geo_cache[t]
                if cached and s then
                    local gap = beautiful.splitwm_gap
                    local mx, my = m.x, m.y
                    local state = get_state(t)
                    local sx    = state.scroll_x or 0
                    local leaves = tree.collect_leaves(state.root)
                    for _, leaf in ipairs(leaves) do
                        local lid = leaf.id
                        local g = cached.geos[lid]
                        local gx = g and g.x - sx
                        if g and mx >= gx and mx < gx + g.width
                               and my >= g.y - gap and my < g.y + g.height then
                            try_drop_picked_up(t, lid)
                            awful.layout.arrange(s)
                            return false
                        end
                    end
                    -- Dropped in a gap: create a new split at the nearest leaf.
                    local best_lid, direction, new_first =
                        tree.find_gap_drop_target(leaves, cached.geos, sx, mx, my, gap)
                    if best_lid and drop_into_new_split(t, best_lid, direction, new_first) then
                        awful.layout.arrange(s)
                    end
                end
                return false
            end, "fleur")
        end
    end)

    awesome.connect_signal("startup", function()
        for s in screen do awful.layout.arrange(s) end
    end)
end

function splitwm.flush_caches()
    tb.flush_caches()
    underlay.flush_caches()
end

splitwm.get_state      = get_state
splitwm.collect_leaves = tree.collect_leaves

return splitwm
