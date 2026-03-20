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
local lgi   = require("lgi")
local cairo = lgi.cairo

local M = {}

local WORKSPACES = nil
local cache      = {}   -- [tag] = cairo ImageSurface (screenshot from last departure)
local active     = {}   -- [screen] = { timer, overlays }

local DURATION_S = 1.1
local FPS        = 60

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

-- Synchronously capture the current screen content into an ImageSurface.
-- root.content() returns the raw XCB surface; we blit it cropped to this screen.
local function capture_screen(s)
    local g    = s.geometry
    local img  = cairo.ImageSurface(cairo.Format.RGB24, g.width, g.height)
    local cr   = cairo.Context(img)
    cr:set_source_surface(gears.surface(root.content()), -g.x, -g.y)
    cr:paint()
    return img
end

local function make_overlay(s, x, surf, bg_color)
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
    if surf then
        ov:setup { wibox.widget.imagebox(surf, true), layout = wibox.layout.fixed.vertical }
    end
    return ov
end

local function animate(s, old_overlay, new_overlay, dx)
    cancel_active(s)
    local frames    = math.max(1, math.floor(DURATION_S * FPS))
    local frame     = 0
    local old_start = s.geometry.x
    local new_start = s.geometry.x - dx
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

local function tag_color(tag)
    local ws = tag and WORKSPACES and WORKSPACES[tag.index]
    return (ws and ws.dark) or "#111111"
end

-- Returns cached surface for tag, or wallpaper as fallback, or nil.
local function tag_surf(tag)
    if cache[tag] then return cache[tag] end
    local ws = tag and WORKSPACES and WORKSPACES[tag.index]
    if ws and ws.has_bg then
        return gears.surface.load_uncached(ws.bg)
    end
    return nil
end

function M.switch(s, new_tag)
    local old_tag = s.selected_tag
    if old_tag == new_tag then return end

    cancel_active(s)

    local old_idx = old_tag and old_tag.index or new_tag.index
    local new_idx = new_tag.index
    local dx      = (new_idx > old_idx) and -s.geometry.width or s.geometry.width

    -- Capture current screen state synchronously before switching
    local old_surf = capture_screen(s)
    if old_tag then cache[old_tag] = old_surf end

    local old_overlay = make_overlay(s, s.geometry.x,      old_surf,          tag_color(old_tag))
    local new_overlay = make_overlay(s, s.geometry.x - dx, tag_surf(new_tag), tag_color(new_tag))

    new_tag:view_only()
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
