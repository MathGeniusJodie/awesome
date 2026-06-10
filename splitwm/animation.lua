---------------------------------------------------------------------------
-- splitwm.animation — split / close / minimize geometry animations.
--
-- Callers queue an animation in one of the *_pending tables and trigger an
-- arrange; update_ui starts the animation once the new geometry is known.
---------------------------------------------------------------------------

local gears = require("gears")
local core  = require("splitwm.core")
local theme = require("splitwm.theme")
local tree  = require("splitwm.tree")
local smush = require("splitwm.smush")

local animation = {}

-- [screen] = pending descriptor, consumed by update_ui.
animation.split_pending  = {}
animation.reflow_pending = {}

-- [screen] = { timer, min_leaf } while an animation runs.
local active = {}

function animation.is_active(s)
    return active[s] ~= nil
end

local FPS      = 60
local DURATION = 0.28

local function ease_out_back(t)
    local c = 1.1
    t = t - 1
    return t * t * ((c + 1) * t + c) + 1
end

local function lerp_geo(g0, g1, p)
    return {
        x      = math.floor(g0.x      + (g1.x      - g0.x)      * p),
        y      = math.floor(g0.y      + (g1.y      - g0.y)      * p),
        width  = math.floor(g0.width  + (g1.width  - g0.width)  * p),
        height = math.floor(g0.height + (g1.height - g0.height) * p),
    }
end

-- Position a leaf's tab bar wibox and active client at an animated geometry.
local function apply_leaf_geo(s, leaf_id, geo)
    local _, state = core.active_state(s)
    if not state then return end
    local gap      = theme.gap()
    local tb_h     = theme.tb_h(gap)
    local scroll_x = state.scroll_x or 0
    local entry    = core.tabbar[s] and core.tabbar[s][leaf_id]
    if entry then
        entry.wb.x      = geo.x - scroll_x
        entry.wb.y      = geo.y - gap
        entry.wb.width  = math.max(1, geo.width)
        entry.wb.height = math.max(1, geo.height + gap)
    end
    local leaf = tree.find_leaf_by_id(state.root, leaf_id)
    if leaf then
        local c = leaf.tabs[leaf.active_tab]
        if c and c.valid and not c.fullscreen then
            c:geometry(theme.client_geo(geo, theme.focus_border_width(),
                gap, tb_h, scroll_x))
        end
    end
end

local function cancel(s)
    local a = active[s]
    if not a then return end
    if a.min_leaf then a.min_leaf.min_anim = nil end
    a.timer:stop()
    active[s] = nil
end

-- Run a fixed-duration ease-out-back animation; on_frame(p) gets eased
-- progress. min_leaf (if any) stays visible until the animation completes.
local function run(s, on_frame, min_leaf, on_done)
    local frames = math.max(1, math.floor(DURATION * FPS))
    local frame  = 0
    local tim
    tim = gears.timer {
        timeout   = 1 / FPS,
        autostart = true,
        call_now  = false,
        callback  = function()
            frame = frame + 1
            on_frame(ease_out_back(math.min(frame / frames, 1.0)))
            if frame >= frames then
                tim:stop()
                active[s] = nil
                if min_leaf then
                    min_leaf.min_anim = nil
                    for _, c in ipairs(min_leaf.tabs) do c.hidden = true end
                end
                if core.update_ui then core.update_ui(s) end
                if on_done then on_done() end
            end
        end,
    }
    active[s] = { timer = tim, min_leaf = min_leaf }
end

-- Animate a fresh split: the existing leaf moves from its old geometry, the
-- new leaf slides in from the splitting edge.
function animation.start_split(s, t, old_geo, a_id, b_id, dir)
    cancel(s)
    local cached = core.geo[t]
    if not cached then return end
    local geo_a = cached.geos[a_id]
    local geo_b = cached.geos[b_id]
    if not geo_a or not geo_b then return end

    local start_b
    if dir == tree.DIR_H then
        local edge_x = geo_b.x < geo_a.x and geo_b.x or geo_b.x + geo_b.width
        start_b = { x = edge_x, y = geo_b.y, width = 1, height = geo_b.height }
    else
        local edge_y = geo_b.y < geo_a.y and geo_b.y or geo_b.y + geo_b.height
        start_b = { x = geo_b.x, y = edge_y, width = geo_b.width, height = 1 }
    end

    apply_leaf_geo(s, a_id, old_geo)
    apply_leaf_geo(s, b_id, start_b)

    run(s, function(p)
        apply_leaf_geo(s, a_id, lerp_geo(old_geo, geo_a, p))
        apply_leaf_geo(s, b_id, lerp_geo(start_b, geo_b, p))
    end, nil, function()
        smush.after_layout(s)
    end)
end

-- Animate existing leaves from old_geos to their current layout geometry.
-- Used after closing a split (surviving leaves expand; smush re-runs after)
-- and after minimize/restore (min_leaf, if any, is the leaf being minimized,
-- kept visible during the animation via its min_anim flag).
function animation.start_reflow(s, t, old_geos, leaf_ids, min_leaf, smush_after)
    cancel(s)
    local function abort()
        if min_leaf then min_leaf.min_anim = nil end
    end
    local cached = core.geo[t]
    if not cached then return abort() end
    local end_geos = {}
    for _, id in ipairs(leaf_ids) do
        local g = cached.geos[id]
        if not g then return abort() end
        end_geos[id] = g
    end
    for _, id in ipairs(leaf_ids) do
        if old_geos[id] then apply_leaf_geo(s, id, old_geos[id]) end
    end
    run(s, function(p)
        for _, id in ipairs(leaf_ids) do
            if old_geos[id] and end_geos[id] then
                apply_leaf_geo(s, id, lerp_geo(old_geos[id], end_geos[id], p))
            end
        end
    end, min_leaf, smush_after and function() smush.after_layout(s) end or nil)
end

return animation
