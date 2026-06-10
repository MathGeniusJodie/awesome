---------------------------------------------------------------------------
-- splitwm: a terminal-multiplexer-style layout for AwesomeWM.
--
-- Splits are persistent containers arranged in a binary tree (horizontal
-- branches are n-ary). Each split has a tab stack; windows are pinned to
-- splits and persist even when a split is empty.
--
-- Module map:
--   core      shared state            theme     resolved colors/metrics
--   tree      pure tree math          ops       all tree/tab mutations
--   arrange   layout fn + UI refresh  scroll    canvas scrolling
--   focus     focus engine            smush     narrow-split font shrink
--   animation geometry animations     titlebar  tab bar UI
--   underlay  wallpaper/drag handles  colors    per-client colors
---------------------------------------------------------------------------

local awful  = require("awful")
local gears  = require("gears")
local tree   = require("splitwm.tree")
local core   = require("splitwm.core")
local theme  = require("splitwm.theme")
local colors = require("splitwm.colors")
local client_icons = require("splitwm.client_icons")
local focus  = require("splitwm.focus")
local smush  = require("splitwm.smush")
local ops    = require("splitwm.ops")
local scroll = require("splitwm.scroll")
local arrange = require("splitwm.arrange")
local tb     = require("splitwm.titlebar")
local underlay = require("splitwm.underlay")

local splitwm = {}

-- Make the public table reachable from UI modules without require cycles
-- (rc.lua sets splitwm.launchers; menu.lua sets the on_menu_* hooks).
core.splitwm = splitwm

splitwm.launchers = {}  -- set from rc.lua before calling setup()

-- Tab shape exported so rc.lua wibar capsules can match the tab profile.
splitwm.tab_shape = tb.tab_shape

splitwm.set_wallpaper = underlay.set_wallpaper

---------------------------------------------------------------------------
-- Public split/tab API (used by rc.lua keybindings and menu.lua)
---------------------------------------------------------------------------

splitwm.expect_next_client = ops.expect_next_client

function splitwm.spawn(cmd, opts)
    ops.expect_next_client(opts)
    return awful.spawn(cmd)
end

function splitwm.focus_leaf(t, leaf_id)
    local state = t and core.state(t)
    local leaf = core.leaf(state, leaf_id)
    if not leaf then return false end
    state.focused_leaf_id = leaf.id
    return true
end

splitwm.activate_client_in_leaf  = ops.activate_client_in_leaf
splitwm.move_client_to_leaf_id   = ops.move_client_to_leaf_id
splitwm.swap_client_to_tab_index = ops.swap_client_to_tab_index
splitwm.insert_column_at_gap     = ops.insert_column_at_gap
splitwm.get_state      = core.state
splitwm.collect_leaves = tree.collect_leaves
splitwm.scroll_delta   = scroll.scroll_delta

-- Run fn(t) on the focused screen's tag and re-arrange unless it failed.
local function with_tag(fn)
    local s = awful.screen.focused()
    local t = s.selected_tag
    if t and fn(t, s) ~= false then awful.layout.arrange(s) end
end

local function split_focused(dir)
    local s = awful.screen.focused()
    local t = s and s.selected_tag
    if not t then return end
    local state = core.state(t)
    ops.split_with_anim(t, s, state, state.focused_leaf_id, dir)
end

local function focus_split(dir)
    local s = awful.screen.focused()
    local t = s and s.selected_tag
    if t and ops.focus_direction(t, dir) ~= false then
        awful.layout.arrange(s)
        gears.timer.delayed_call(function() scroll.ensure_in_view(s, t) end)
    end
end

splitwm.split_horizontal = function() split_focused(tree.DIR_H) end
splitwm.split_vertical   = function() split_focused(tree.DIR_V) end
splitwm.focus_next_split = function() focus_split("next") end
splitwm.focus_prev_split = function() focus_split("prev") end
splitwm.next_tab = function() with_tag(function(t) return ops.cycle_tab(t, 1) end) end
splitwm.prev_tab = function() with_tag(function(t) return ops.cycle_tab(t, -1) end) end

local function move_tab(dir)
    with_tag(function(t)
        local ok = ops.move_tab_to_direction(t, dir)
        if ok ~= false then
            smush.after_layout(t.screen, core.state(t).focused_leaf_id)
        end
        return ok
    end)
end
splitwm.move_tab_next = function() move_tab("next") end
splitwm.move_tab_prev = function() move_tab("prev") end

local function resize(delta)
    with_tag(function(t)
        local ok = ops.resize_focused(t, delta)
        if ok ~= false then smush.after_layout(t.screen) end
        return ok
    end)
end
splitwm.resize_grow   = function() resize(theme.RESIZE_STEP) end
splitwm.resize_shrink = function() resize(-theme.RESIZE_STEP) end

splitwm.close_split = function()
    local s = awful.screen.focused()
    local t = s and s.selected_tag
    if not t then return end
    local state = core.state(t)
    ops.close_leaf_with_anim(t, s, state, state.focused_leaf_id)
end

function splitwm.flush_caches()
    tb.flush_caches()
    underlay.flush_caches()
end

---------------------------------------------------------------------------
-- Layout object
---------------------------------------------------------------------------

splitwm.layout = {
    name    = "splitwm",
    arrange = function(p)
        arrange.arrange(p)
        local s = core.screen_of(p.screen)
        if not s then return end
        gears.timer.delayed_call(function() arrange.update_ui(s) end)
    end,
}

---------------------------------------------------------------------------
-- Signal wiring
---------------------------------------------------------------------------

local function connect_client_signals()
    client.connect_signal("manage", function(c)
        client_icons.prepare_client_icon(c, splitwm.launchers)
        local t = c.first_tag
        if not t then return end
        local state = core.state(t)
        local leaf = tree.find_leaf_for_client(state.root, c)
        if not leaf then
            ops.pin_client(t, c)
            leaf = tree.find_leaf_for_client(state.root, c)
        end
        if leaf then colors.resolve_color_conflict(leaf, c) end
    end)

    client.connect_signal("unmanage", function(c)
        local drag = core.drag
        if drag.pickup.tag == "client" and drag.pickup.client == c then
            core.drop_pickup()
        end
        colors.release_client(c)
        local keep_t, keep_state, keep_leaf
        for t, state in pairs(core.tag_state) do
            local leaf = tree.find_leaf_for_client(state.root, c)
            if leaf and state.focused_leaf_id == leaf.id then
                keep_t, keep_state, keep_leaf = t, state, leaf
            end
            ops.unpin_client(state.root, c)
        end
        if not keep_leaf then return end

        -- Keep focus inside the split the window was closed from: autofocus
        -- picks the next client from global history, which may live in
        -- another split and would drag focus (and the canvas) over there.
        local nxt = keep_leaf.tabs[keep_leaf.active_tab]
        if nxt and nxt.valid then
            focus.force_now(nxt)
            focus.after_arrange(nxt, keep_leaf.id)
        else
            -- The split is now empty; splits persist, so it stays focused.
            gears.timer.delayed_call(function()
                if not core.leaf(keep_state, keep_leaf.id) then return end
                keep_state.focused_leaf_id = keep_leaf.id
                if #keep_leaf.tabs == 0 then client.focus = nil end
                local s = keep_t.screen and core.screen_of(keep_t.screen)
                if s then awful.layout.arrange(s) end
            end)
        end
    end)

    local function refresh_client_icon(c, release_hue_slot)
        client_icons.prepare_client_icon(c, splitwm.launchers)
        colors.clear_client_color_cache(c, { release_hue_slot = release_hue_slot })
        if c.screen then awful.layout.arrange(c.screen) end
    end
    client.connect_signal("property::class", function(c) refresh_client_icon(c, true) end)
    client.connect_signal("property::instance", function(c) refresh_client_icon(c, true) end)
    client.connect_signal("property::icon", function(c) refresh_client_icon(c, false) end)

    client.connect_signal("focus", function(c)
        local leaf, state = core.client_leaf(c)
        if not leaf then return end
        local tab_idx = core.tab_index(leaf, c)
        if not tab_idx then return end
        local needs_arrange = false
        if leaf.active_tab ~= tab_idx then
            leaf.active_tab = tab_idx
            needs_arrange = true
        end
        if leaf.id ~= state.focused_leaf_id then
            state.focused_leaf_id = leaf.id
            needs_arrange = true
        end
        if needs_arrange then awful.layout.arrange(c.screen) end
        local t = c.first_tag
        if t then
            gears.timer.delayed_call(function()
                scroll.ensure_in_view(c.screen, t)
            end)
        end
    end)

    client.connect_signal("property::fullscreen", function(c)
        awful.layout.arrange(c.screen)
    end)

    client.connect_signal("button::press", function(c)
        local leaf, state, t = core.client_leaf(c)
        if not state then return end
        local drag = core.drag
        if drag.pickup.tag == "split" then
            if leaf and leaf.id ~= drag.pickup.split_id then
                ops.handle_split_pickup(state, leaf.id, c.screen)
            end
        elseif drag.pickup.tag == "client" and drag.pickup.client.valid
                and drag.pickup.client ~= c then
            if leaf then
                ops.try_drop_picked_up(t, leaf.id)
                awful.layout.arrange(c.screen)
            end
        elseif leaf and leaf.id ~= state.focused_leaf_id then
            state.focused_leaf_id = leaf.id
            awful.layout.arrange(c.screen)
        end
        if drag.pickup.tag == "idle" then
            arrange.start_drag_hover_poll()
        end
    end)
end

function splitwm.setup()
    theme.init()
    tb.init()
    client_icons.set_launchers(splitwm.launchers)
    awesome.register_xproperty("splitwm_manual_color", "string")

    connect_client_signals()

    tag.connect_signal("property::selected", function(t)
        local s = core.screen_of(t.screen)
        if mousegrabber.isrunning() then mousegrabber.stop() end
        core.geo[t] = nil
        if s then
            gears.timer.delayed_call(function() arrange.update_ui(s) end)
        end
    end)

    awesome.connect_signal("startup", function()
        for s in screen do awful.layout.arrange(s) end
    end)
end

return splitwm
