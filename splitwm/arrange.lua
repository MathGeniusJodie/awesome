---------------------------------------------------------------------------
-- splitwm.arrange — the layout's arrange function, the unified UI refresh
-- (tab bars, drag handles, pending animations), and the drag-over-tab
-- hover-switch poll.
---------------------------------------------------------------------------

local awful  = require("awful")
local gears  = require("gears")
local tree   = require("splitwm.tree")
local core   = require("splitwm.core")
local theme  = require("splitwm.theme")
local ops    = require("splitwm.ops")
local focus  = require("splitwm.focus")
local anim   = require("splitwm.animation")
local scroll = require("splitwm.scroll")
local tb     = require("splitwm.titlebar")
local underlay = require("splitwm.underlay")

local M = {}

local last_focused_leaf = {}  -- [screen] = leaf_id, to detect focus changes

---------------------------------------------------------------------------
-- arrange
---------------------------------------------------------------------------

local function place_leaf_clients(s, state, leaf, geo, wa, gap, bw, tb_h)
    -- Is the split entirely outside the visible viewport?
    local scroll_x  = state.scroll_x or 0
    local vis_left  = geo.x - scroll_x
    local vis_right = vis_left + geo.width
    local off_screen = vis_right <= wa.x or vis_left >= wa.x + wa.width

    for i, c in ipairs(leaf.tabs) do
        local show = i == leaf.active_tab and leaf.active_tab > 0
            and not off_screen and (not leaf.minimized or leaf.min_anim)
        if show then
            c.hidden = false
            c.border_width = 0
            if not c.fullscreen and not anim.is_active(s) then
                c:geometry(theme.client_geo(geo, bw, gap, tb_h, scroll_x))
            end
        else
            c.hidden = true
        end
    end
end

function M.arrange(p)
    local tag = p.tag
    if not tag then
        local ps = core.screen_of(p.screen)
        tag = ps and ps.selected_tag
    end
    if not tag then return end
    local state = core.state(tag)
    local wa  = p.workarea
    local gap = theme.gap()

    local root     = state.root
    local canvas_w = state.canvas_w or wa.width

    -- Pin any clients the tree doesn't know about yet.
    local pinned = {}
    for _, leaf in ipairs(tree.collect_leaves(root)) do
        for _, tc in ipairs(leaf.tabs) do pinned[tc] = true end
    end
    for _, c in ipairs(p.clients) do
        if not pinned[c] then ops.pin_client(tag, c) end
    end

    local geos, bounds = {}, {}
    local tb_h = theme.tb_h(gap)
    tree.compute_tree(root, wa.x, wa.y, canvas_w, wa.height, gap, geos, bounds, tb_h)
    core.geo[tag] = { geos = geos, bounds = bounds }

    local s  = core.screen_of(p.screen)
    local bw = theme.focus_border_width()
    for _, leaf in ipairs(tree.collect_leaves(root)) do
        local geo = geos[leaf.id]
        if geo then
            place_leaf_clients(s, state, leaf, geo, wa, gap, bw, tb_h)
        end
    end
end

---------------------------------------------------------------------------
-- update_ui
---------------------------------------------------------------------------

function M.update_ui(s)
    local t, state = core.active_state(s)
    if not t then
        underlay.hide_drag_handles(s)
        if core.tabbar[s] then
            for _, entry in pairs(core.tabbar[s]) do
                entry.wb.visible = false
            end
        end
        return
    end

    local gap    = theme.gap()
    local cached = core.geo[t]
    local geos, bounds
    if cached then
        geos, bounds = cached.geos, cached.bounds
    else
        local wa       = s.workarea
        local canvas_w = state.canvas_w or wa.width
        geos, bounds   = {}, {}
        tree.compute_tree(state.root, wa.x, wa.y, canvas_w, wa.height, gap,
            geos, bounds, theme.tb_h(gap))
    end

    local leaves = tree.collect_leaves(state.root)
    tb.update(s, t, state, geos, leaves)
    underlay.update_drag_handles(s, state, bounds, state.scroll_x or 0)

    local pending = anim.split_pending[s]
    if pending then
        anim.split_pending[s] = nil
        anim.start_split(s, t, pending.old_geo, pending.a_id, pending.b_id, pending.dir)
        return
    end
    local rpending = anim.reflow_pending[s]
    if rpending then
        anim.reflow_pending[s] = nil
        anim.start_reflow(s, t, rpending.old_geos, rpending.leaf_ids,
            rpending.min_leaf, rpending.smush)
        return
    end

    -- Scroll the focused split into view whenever focus changes.
    local lid = state.focused_leaf_id
    if last_focused_leaf[s] ~= lid and not anim.is_active(s) then
        last_focused_leaf[s] = lid
        scroll.ensure_in_view(s, t)
    end
end

core.update_ui = M.update_ui

---------------------------------------------------------------------------
-- Drag-over-tab hover switching
---------------------------------------------------------------------------

local hover_timer = nil

function M.stop_drag_hover_poll()
    if hover_timer then
        hover_timer:stop()
        hover_timer = nil
    end
end

-- While button 1 is held with no pickup/pending drag, hovering another tab
-- in any tab bar switches to it.
local function hover_poll_tick()
    local m = mouse.coords()
    if not m.buttons[1] or core.drag.pickup.tag ~= "idle" then
        M.stop_drag_hover_poll()
        return
    end
    local mx, my  = m.x, m.y
    local gap     = theme.gap()
    local tb_h    = theme.tb_h(gap)
    local icon_sz = tb_h - 2 * tb.TAB_CONTENT_V_PAD
    for s in screen do
        local t = s.selected_tag
        local cached = t and core.geo[t]
        local state  = t and core.tag_state[t]
        if cached and state then
            local sx = state.scroll_x or 0
            for _, leaf in ipairs(tree.collect_leaves(state.root)) do
                local g = cached.geos[leaf.id]
                local gx = g and g.x - sx
                if g and mx >= gx and mx < gx + g.width
                        and my >= g.y - gap and my < g.y - gap + tb_h then
                    local tab_idx = tb.tab_index_at(mx - gx, #leaf.tabs, icon_sz)
                    if tab_idx and tab_idx ~= leaf.active_tab and leaf.tabs[tab_idx] then
                        leaf.active_tab = tab_idx
                        state.focused_leaf_id = leaf.id
                        awful.layout.arrange(s)
                        focus.after_arrange(leaf.tabs[tab_idx], leaf.id)
                    end
                    return
                end
            end
        end
    end
end

function M.start_drag_hover_poll()
    if hover_timer then return end
    hover_timer = gears.timer {
        timeout   = 0.05,
        call_now  = false,
        autostart = true,
        callback  = hover_poll_tick,
    }
end

-- Active tabs tint to the live window-top color; refresh slowly so apps
-- changing color while the WM is idle still propagate. The tab fingerprint
-- short-circuits the update when nothing changed.
gears.timer {
    timeout   = 2,
    autostart = true,
    call_now  = false,
    callback  = function()
        for s in screen do
            if core.active_state(s) and not anim.is_active(s) then
                M.update_ui(s)
            end
        end
    end,
}

return M
