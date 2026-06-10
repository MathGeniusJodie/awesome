---------------------------------------------------------------------------
-- splitwm.scroll — horizontal scrolling of the (possibly oversized) canvas.
---------------------------------------------------------------------------

local awful = require("awful")
local gears = require("gears")
local core  = require("splitwm.core")
local theme = require("splitwm.theme")

local scroll = {}

local ANIM_FPS      = 60
local ANIM_DURATION = 0.05  -- seconds

local active = {}  -- [screen] = { timer }

local function start_anim(s, tag)
    local a = active[s]
    if a then a.timer:stop(); active[s] = nil end
    local state    = core.state(tag)
    local start_x  = state.scroll_x or 0
    local target_x = state.scroll_target or 0
    if start_x == target_x then return end
    local frames = math.max(1, math.floor(ANIM_DURATION * ANIM_FPS))
    local frame  = 0
    local tim
    tim = gears.timer {
        timeout   = 1 / ANIM_FPS,
        autostart = true,
        call_now  = false,
        callback  = function()
            frame = frame + 1
            local p = math.min(frame / frames, 1.0)
            p = 1 - (1 - p) * (1 - p)  -- ease out quad
            state.scroll_x = math.floor(start_x + (target_x - start_x) * p)
            if frame >= frames then
                state.scroll_x = target_x
                tim:stop()
                active[s] = nil
            end
            awful.layout.arrange(s)
        end,
    }
    active[s] = { timer = tim }
end

-- instant skips the easing animation: trackpad event streams arrive densely
-- enough that applying each small step directly reads as smooth scrolling.
function scroll.scroll_to(s, tag, target_x, instant)
    local state    = core.state(tag)
    local wa       = s.workarea
    local canvas_w = state.canvas_w or wa.width
    local max_s    = math.max(0, canvas_w - wa.width)
    state.scroll_target = math.max(0, math.min(max_s, target_x))
    if instant then
        local a = active[s]
        if a then a.timer:stop(); active[s] = nil end
        state.scroll_x = state.scroll_target
        awful.layout.arrange(s)
        return
    end
    start_anim(s, tag)
end

function scroll.scroll_delta(s, delta_x, instant)
    local t = s and s.selected_tag
    if not t then return end
    local state = core.state(t)
    -- Accumulate from the target, not the current position, so rapid events
    -- don't lose distance to an in-flight animation.
    scroll.scroll_to(s, t, (state.scroll_target or state.scroll_x or 0) + delta_x,
        instant)
end

-- Scroll so the focused split sits inside the viewport (with one gap margin).
function scroll.ensure_in_view(s, tag)
    local state = core.tag_state[tag]
    if not state then return end
    local wa     = s.workarea
    local cached = core.geo[tag]
    if not cached then return end
    local geo = cached.geos[state.focused_leaf_id]
    if not geo then return end
    local sx     = state.scroll_x or 0
    local gap    = theme.gap()
    local target = sx
    if geo.x - sx < wa.x + gap then
        target = geo.x - wa.x - gap
    elseif geo.x + geo.width - sx > wa.x + wa.width - gap then
        target = geo.x + geo.width - wa.x - wa.width + gap
    end
    if target ~= sx then scroll.scroll_to(s, tag, target) end
end

return scroll
