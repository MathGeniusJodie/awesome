---------------------------------------------------------------------------
-- transitions.lua — animated tag switching with screenshot cache
--
-- Usage:
--   local transitions = require("transitions")
--   transitions.setup({ workspaces = WORKSPACES })
--   transitions.switch(s, new_tag)
---------------------------------------------------------------------------

local gears = require("gears")
local wibox = require("wibox")
local awful = require("awful")

local M = {}

local WORKSPACES  = nil
local cache       = {}     -- [tag] = file path string
local active      = {}     -- [screen] = { timer, overlays }

local DURATION_S  = 1.1
local FPS         = 60
local SETTLE_S    = 0.7    -- seconds after arriving before we screenshot

local function ease_out(t)
    return 1 - (1 - t) * (1 - t)
end

local function cancel_active(s)
    local a = active[s]
    if not a then return end
    if a.timer then a.timer:stop() end
    for _, ov in ipairs(a.overlays) do
        ov.visible = false
    end
    active[s] = nil
end

local function make_overlay(s, x, img_src, bg_color)
    local ov = wibox {
        screen  = s,
        x       = x,
        y       = s.geometry.y,
        width   = s.geometry.width,
        height  = s.geometry.height,
        bg      = bg_color or "#111111",
        ontop   = true,
        visible = true,
        type    = "notification",
    }
    if img_src then
        local surf = gears.surface.load_uncached(img_src)
        if surf then
            ov:setup { wibox.widget.imagebox(surf, true), layout = wibox.layout.fixed.vertical }
        end
    end
    return ov
end

-- Animate old_overlay out and new_overlay in, both driven by one timer.
-- dx: how far (and which direction) each overlay moves.
--   old starts at sg.x,      ends at sg.x + dx   (slides off-screen)
--   new starts at sg.x - dx, ends at sg.x         (slides on-screen, then hides)
local function animate(s, old_overlay, new_overlay, dx)
    cancel_active(s)
    local frames    = math.max(1, math.floor(DURATION_S * FPS))
    local frame     = 0
    local sg        = s.geometry
    local old_start = sg.x
    local new_start = sg.x - dx
    local tim
    tim = gears.timer {
        timeout   = 1 / FPS,
        autostart = true,
        call_now  = false,
        callback  = function()
            frame = frame + 1
            local p = ease_out(frame / frames)
            old_overlay.x = math.floor(old_start + dx * p)
            new_overlay.x = math.floor(new_start + dx * p)
            if frame >= frames then
                tim:stop()
                old_overlay.visible = false
                new_overlay.visible = false
                active[s] = nil
            end
        end,
    }
    active[s] = { timer = tim, overlays = { old_overlay, new_overlay } }
end

local function schedule_capture(s, tag)
    gears.timer.start_new(SETTLE_S, function()
        local g    = s.geometry
        local path = string.format("/tmp/awesome_ws_%d_%d.png", s.index, tag.index)
        awful.spawn.easy_async(
            string.format("maim -g %dx%d+%d+%d -- %s", g.width, g.height, g.x, g.y, path),
            function(_, _, _, code)
                if code == 0 then cache[tag] = path end
            end
        )
        return false
    end)
end

local function tag_overlay_args(tag)
    local ws    = tag and WORKSPACES and WORKSPACES[tag.index]
    local src   = (tag and cache[tag]) or (ws and ws.has_bg and ws.bg)
    local color = (ws and ws.dark) or "#111111"
    return src, color
end

function M.switch(s, new_tag)
    local old_tag = s.selected_tag
    if old_tag == new_tag then return end

    local old_idx = old_tag and old_tag.index or new_tag.index
    local new_idx = new_tag.index
    -- Negative dx = both slide left (going to higher tag), positive = right
    local dx = (new_idx > old_idx) and -s.geometry.width or s.geometry.width

    local old_src, old_color = tag_overlay_args(old_tag)
    local new_src, new_color = tag_overlay_args(new_tag)

    -- Old overlay covers current state at screen position
    local old_overlay = make_overlay(s, s.geometry.x, old_src, old_color)
    -- New overlay starts off-screen on the incoming side
    local new_overlay = make_overlay(s, s.geometry.x - dx, new_src, new_color)

    -- Switch tag underneath both overlays
    new_tag:view_only()

    -- Capture new tag after settling, for future transitions
    schedule_capture(s, new_tag)

    -- Slide old out, new in
    animate(s, old_overlay, new_overlay, dx)
end

function M.switch_prev(s)
    s = s or awful.screen.focused()
    local tags = s.tags
    local cur  = s.selected_tag
    if not cur then return end
    local idx  = cur.index
    M.switch(s, tags[idx > 1 and idx - 1 or #tags])
end

function M.switch_next(s)
    s = s or awful.screen.focused()
    local tags = s.tags
    local cur  = s.selected_tag
    if not cur then return end
    local idx  = cur.index
    M.switch(s, tags[idx < #tags and idx + 1 or 1])
end

function M.setup(config)
    WORKSPACES = config.workspaces
end

return M
