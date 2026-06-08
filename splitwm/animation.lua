---------------------------------------------------------------------------
-- Split/close/minimize/scroll animations for splitwm.
-- Initialized via M.init(deps) from splitwm.setup().
---------------------------------------------------------------------------

local gears     = require("gears")
local beautiful = require("beautiful")
local tree      = require("splitwm.tree")

local M = {}

M.split_anim_pending    = {}
M.close_anim_pending    = {}
M.minimize_anim_pending = {}
M.split_anim_active     = {}

local _get_active_state
local _effective_tb_h
local _client_geo
local _tb
local _geo_cache
local _update_ui
local _on_split_anim_done
local _on_close_anim_done

function M.init(deps)
    _get_active_state = deps.get_active_state
    _effective_tb_h   = deps.effective_tb_h
    _client_geo       = deps.client_geo
    _tb               = deps.tb
    _geo_cache        = deps.geo_cache
    _update_ui        = deps.update_ui
    _on_split_anim_done = deps.on_split_anim_done
    _on_close_anim_done = deps.on_close_anim_done
end

function M.is_active(s) return M.split_anim_active[s] end

---------------------------------------------------------------------------

local SPLIT_ANIM_FPS      = 60
local SPLIT_ANIM_DURATION = 0.28

local function ease_out_back(t)
    local c = 1.1
    t = t - 1
    return t * t * ((c + 1) * t + c) + 1
end

local function apply_leaf_geo(s, leaf_id, geo)
    local _, state = _get_active_state(s)
    if not state then return end
    local gap      = beautiful.splitwm_gap
    local bw       = beautiful.splitwm_focus_border_width
    local tb_h     = _effective_tb_h(gap)
    local scroll_x = state.scroll_x or 0
    local tc       = _tb.cache[s] and _tb.cache[s][leaf_id]
    if tc then
        tc.wb.x      = geo.x - scroll_x
        tc.wb.y      = geo.y - gap
        tc.wb.width  = math.max(1, geo.width)
        tc.wb.height = math.max(1, geo.height + gap)
    end
    local leaf = tree.find_leaf_by_id(state.root, leaf_id)
    if leaf then
        local c = leaf.tabs[leaf.active_tab]
        if c and c.valid and not c.fullscreen then
            c:geometry(_client_geo(geo, bw, gap, tb_h, scroll_x))
        end
    end
end

local function cancel_split_anim(s)
    local a = M.split_anim_active[s]
    if not a then return end
    if a.min_leaf then a.min_leaf.min_anim = nil end
    a.timer:stop()
    M.split_anim_active[s] = nil
end

local function lerp_geo(g0, g1, p)
    return {
        x      = math.floor(g0.x      + (g1.x      - g0.x)      * p),
        y      = math.floor(g0.y      + (g1.y      - g0.y)      * p),
        width  = math.floor(g0.width  + (g1.width  - g0.width)  * p),
        height = math.floor(g0.height + (g1.height - g0.height) * p),
    }
end

-- Runs a fixed-duration ease-out-back animation. on_frame(p) is called each
-- frame with eased progress in [0,1]. min_leaf.min_anim is cleared on completion.
-- Caller must call cancel_split_anim(s) before this if needed.
local function run_anim(s, on_frame, min_leaf, on_done)
    local frames = math.max(1, math.floor(SPLIT_ANIM_DURATION * SPLIT_ANIM_FPS))
    local frame  = 0
    local tim
    tim = gears.timer {
        timeout   = 1 / SPLIT_ANIM_FPS,
        autostart = true,
        call_now  = false,
        callback  = function()
            frame = frame + 1
            on_frame(ease_out_back(math.min(frame / frames, 1.0)))
            if frame >= frames then
                tim:stop()
                M.split_anim_active[s] = nil
                if min_leaf then
                    min_leaf.min_anim = nil
                    for _, c in ipairs(min_leaf.tabs) do c.hidden = true end
                end
                _update_ui(s)
                if on_done then on_done() end
            end
        end,
    }
    M.split_anim_active[s] = { timer = tim, min_leaf = min_leaf }
end

function M.start_split_anim(s, t, old_geo, a_id, b_id, dir)
    cancel_split_anim(s)
    local cached = _geo_cache[t]
    if not cached then return end
    local geo_a = cached.geos[a_id]
    local geo_b = cached.geos[b_id]
    if not geo_a or not geo_b then return end

    local start_a = old_geo
    local start_b
    if dir == tree.DIR_H then
        if geo_b.x < geo_a.x then
            start_b = { x = geo_b.x,               y = geo_b.y, width = 1, height = geo_b.height }
        else
            start_b = { x = geo_b.x + geo_b.width,  y = geo_b.y, width = 1, height = geo_b.height }
        end
    else
        if geo_b.y < geo_a.y then
            start_b = { x = geo_b.x, y = geo_b.y,                width = geo_b.width, height = 1 }
        else
            start_b = { x = geo_b.x, y = geo_b.y + geo_b.height, width = geo_b.width, height = 1 }
        end
    end

    apply_leaf_geo(s, a_id, start_a)
    apply_leaf_geo(s, b_id, start_b)

    run_anim(s, function(p)
        apply_leaf_geo(s, a_id, lerp_geo(start_a, geo_a, p))
        apply_leaf_geo(s, b_id, lerp_geo(start_b, geo_b, p))
    end, nil, function()
        if _on_split_anim_done then _on_split_anim_done(s, a_id, b_id) end
    end)
end

function M.start_close_anim(s, t, old_geos, leaf_ids)
    cancel_split_anim(s)
    local cached = _geo_cache[t]
    if not cached then return end
    local end_geos = {}
    for _, id in ipairs(leaf_ids) do
        local g = cached.geos[id]
        if not g then return end
        end_geos[id] = g
    end
    for _, id in ipairs(leaf_ids) do
        if old_geos[id] then apply_leaf_geo(s, id, old_geos[id]) end
    end
    run_anim(s, function(p)
        for _, id in ipairs(leaf_ids) do
            if old_geos[id] and end_geos[id] then
                apply_leaf_geo(s, id, lerp_geo(old_geos[id], end_geos[id], p))
            end
        end
    end, nil, function()
        if _on_close_anim_done then _on_close_anim_done(s, leaf_ids) end
    end)
end

function M.start_minimize_anim(s, t, old_geos, leaf_ids, min_leaf)
    cancel_split_anim(s)
    local cached = _geo_cache[t]
    if not cached then
        if min_leaf then min_leaf.min_anim = nil end
        return
    end
    local end_geos = {}
    for _, id in ipairs(leaf_ids) do
        local g = cached.geos[id]
        if not g then
            if min_leaf then min_leaf.min_anim = nil end
            return
        end
        end_geos[id] = g
    end
    for _, id in ipairs(leaf_ids) do
        if old_geos[id] then apply_leaf_geo(s, id, old_geos[id]) end
    end
    run_anim(s, function(p)
        for _, id in ipairs(leaf_ids) do
            if old_geos[id] and end_geos[id] then
                apply_leaf_geo(s, id, lerp_geo(old_geos[id], end_geos[id], p))
            end
        end
    end, min_leaf)
end

return M
