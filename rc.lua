---------------------------------------------------------------------------
-- rc.lua for splitwm — testing config for Xephyr
--
-- Launch with:
--   Xephyr :1 -ac -screen 1280x800 &
--   DISPLAY=:1 awesome -c ~/.config/awesome/rc.lua
--
-- Or if you put this project elsewhere:
--   DISPLAY=:1 awesome -c /path/to/this/rc.lua
---------------------------------------------------------------------------

pcall(require, "luarocks.loader")

local gears     = require("gears")
local awful     = require("awful")
require("awful.autofocus")
local wibox     = require("wibox")
local beautiful = require("beautiful")
local naughty   = require("naughty")
local hotkeys_popup = require("awful.hotkeys_popup")
require("awful.hotkeys_popup.keys")

---------------------------------------------------------------------------
-- Error handling (stock)
---------------------------------------------------------------------------

if awesome.startup_errors then
    naughty.notify {
        preset = naughty.config.presets.critical,
        title  = "Startup errors",
        text   = awesome.startup_errors,
    }
end

do
    local in_error = false
    awesome.connect_signal("debug::error", function(err)
        if in_error then return end
        in_error = true
        naughty.notify {
            preset = naughty.config.presets.critical,
            title  = "Runtime error",
            text   = tostring(err),
        }
        in_error = false
    end)
end

---------------------------------------------------------------------------
-- Theme
---------------------------------------------------------------------------

beautiful.init(gears.filesystem.get_themes_dir() .. "default/theme.lua")

-- Splitwm theme overrides
-- NOTE: useless_gap is 0 because splitwm handles gaps internally.
-- The actual gap size is splitwm_gap.
beautiful.useless_gap        = 0
beautiful.border_width       = 0
beautiful.titlebar_bg_normal = "#00000000"

-- Splitwm colors
beautiful.splitwm_color_bg       = "#000000ff"
beautiful.splitwm_color_fg       = "#ffffffff"
beautiful.splitwm_accent         = "#ff6666ff"
beautiful.splitwm_btn_bg         = "#00000080"  -- transparent circle button bg
beautiful.splitwm_transparent    = "#00000000"  -- fully transparent
beautiful.splitwm_fg_disabled    = "#ffffff55"
beautiful.splitwm_handle_color   = "#ffffff55"  -- drag handle pill (vertical handles + titlebar pill)

-- Splitwm layout
beautiful.splitwm_gap              = 48
beautiful.splitwm_focus_border_width = 2
beautiful.splitwm_border_radius    = 2
beautiful.splitwm_empty_radius     = 14
beautiful.splitwm_btn_font         = "monospace bold 14px"

---------------------------------------------------------------------------
-- Load splitwm
---------------------------------------------------------------------------

-- Add the directory containing this rc.lua to the Lua path
-- so that `require("splitwm")` finds our module
local config_dir = gears.filesystem.get_configuration_dir()
package.path = config_dir .. "?.lua;"
            .. config_dir .. "?/init.lua;"
            .. package.path

local splitwm     = require("splitwm")
local swcolors    = require("splitwm.colors")
local menu        = require("menu")
local status      = require("status")
local timebar     = require("timebar")
local transitions = require("transitions")
local hunger_mod  = require("hunger")

-- Workspace colors: COLORS indices 0,2,4,6,8 (1-based: 1,3,5,7,9) = pink,gold,emerald,blue,purple
-- bg existence is checked once at startup to avoid repeated stat() on every switch
local _home = os.getenv("HOME")
local WORKSPACES = {}
for i, ci in ipairs({1, 3, 5, 7, 9}) do
    local c = swcolors.COLORS[ci]
    WORKSPACES[i] = {
        light  = c.light,
        dark   = c.dark,
        bg     = _home .. "/background" .. (ci - 1) .. ".jpg",
        has_bg = false,
    }
end
for _, ws in ipairs(WORKSPACES) do
    ws.has_bg = gears.filesystem.file_readable(ws.bg)
end

---------------------------------------------------------------------------
-- Variables
---------------------------------------------------------------------------

local terminal = os.getenv("TERMINAL") or "xterm"
local modkey   = "Mod4"

-- Browser detection: try common browsers
local browser = os.getenv("BROWSER") or "xdg-open https://"
local filemanager = os.getenv("FILEMANAGER") or "thunar"

---------------------------------------------------------------------------
-- App launchers shown in splits (icon with text fallback)
-- icon_name = XDG name, resolved after icon theme loads
---------------------------------------------------------------------------

splitwm.launchers = {
    {
        label      = "$",
        icon_names = {"utilities-terminal", "terminal", "xterm", "org.xfce.terminal"},
        cmd        = terminal,
    },
    {
        label      = "B",
        icon_names = {"internet-web-browser", "web-browser", "firefox", "firefox-esr",
                      "librewolf", "brave-browser", "chromium", "google-chrome"},
        cmd        = browser,
    },
    {
        label      = "F",
        icon       = "/usr/share/icons/Adwaita/scalable/places/folder.svg",
        cmd        = filemanager,
    },
    {
        label      = "O",
        icon_names = {"obsidian", "md.obsidian.Obsidian"},
        cmd        = "obsidian",
    },
    {
        label      = "YT",
        icon_names = {"video"},
        cmd        = "/home/jodie/yt-scrape/target/release/yt-gtk",
    },
    {
        label      = "AI",
        icon_names = {"claude-desktop"},
        cmd        = "claude-desktop",
    },
}

splitwm.setup()
transitions.setup({ workspaces = WORKSPACES })

-- Expose for external callers e.g. awesome-client "tag_next()"
tag_prev = transitions.switch_prev  -- luacheck: ignore
tag_next = transitions.switch_next  -- luacheck: ignore

---------------------------------------------------------------------------
-- Edge workspace switching (Pacman style)
-- Mouse hitting left/right screen edge switches workspaces.
-- A dead zone prevents re-triggering until mouse retreats from the edge.
---------------------------------------------------------------------------

local EDGE_DEAD_ZONE = beautiful.splitwm_gap  -- px from edge; must clear this before re-triggering

local edge_locked = {}  -- [screen] = "left" | "right" | nil

gears.timer {
    timeout   = 0.025,
    autostart = true,
    callback  = function()
        local s = mouse.screen
        if not s then return end

        local pos  = mouse.coords()
        local mx   = pos.x - s.geometry.x
        local sw   = s.geometry.width
        local lock = edge_locked[s]

        if mx <= 0 then
            if lock ~= "left" then
                edge_locked[s] = "left"
                transitions.switch_instant(s, -1)
                mouse.coords({ x = s.geometry.x + sw - 2, y = pos.y })
            end
        elseif mx >= sw - 1 then
            if lock ~= "right" then
                edge_locked[s] = "right"
                transitions.switch_instant(s, 1)
                mouse.coords({ x = s.geometry.x + 1, y = pos.y })
            end
        else
            if lock == "left"  and mx > EDGE_DEAD_ZONE then
                edge_locked[s] = nil
            elseif lock == "right" and mx < sw - 1 - EDGE_DEAD_ZONE then
                edge_locked[s] = nil
            end
        end
    end,
}

menu.setup({
    terminal    = terminal,
    browser     = browser,
    filemanager = filemanager,
    splitwm     = splitwm,
})

---------------------------------------------------------------------------
-- Layouts — splitwm is the default (and only one you need, really)
---------------------------------------------------------------------------

awful.layout.layouts = {
    splitwm.layout,
    awful.layout.suit.floating,  -- fallback
}

---------------------------------------------------------------------------
-- Wibar
---------------------------------------------------------------------------

-- Wibar font and color overrides (must be before wibar creation)
beautiful.font           = "monospace bold 12px"
beautiful.fg_normal      = "#ffffff"
beautiful.fg_focus       = "#ffffff"

local bar_margin     = 3
local capsule_height = 24
local wibar_height   = beautiful.splitwm_gap - beautiful.splitwm_focus_border_width
local icon_bottom_pad = 4  -- gap between icon bottom and capsule bottom edge

local function parse_hex(hex)
    hex = hex:gsub("#", "")
    return tonumber(hex:sub(1,2), 16) / 255,
           tonumber(hex:sub(3,4), 16) / 255,
           tonumber(hex:sub(5,6), 16) / 255
end

--- Build a single tag button: wallpaper/screenshot thumbnail in a rounded-rect frame.
-- Empty tags show the wallpaper. Tags with windows show the screenshot from
-- transitions.cache, which is captured synchronously on every tag departure.
local function make_tag_widget(t, ws)
    local CORNER  = 4
    local geo     = t.screen.geometry
    local thumb_h = beautiful.splitwm_gap - 6
    local thumb_w = math.floor(thumb_h * geo.width / geo.height)

    local thumb = wibox.widget.base.make_widget()
    thumb.has_wins = false
    thumb.selected = false
    thumb.forced_width  = thumb_w
    thumb.forced_height = thumb_h

    local wp_surface = ws.has_bg and gears.surface.load(ws.bg) or nil
    local dr, dg, db = parse_hex(ws.dark)

    function thumb:fit(_, w, h) return self.forced_width, h end

    function thumb:draw(_, cr, w, h)
        local surf = (self.has_wins and transitions.cache[t]) or wp_surface
        local pad = 2  -- space reserved outside the thumbnail for the border

        cr:save()
        cr:translate(pad, pad)
        gears.shape.rounded_rect(cr, w - 2*pad, h - 2*pad, CORNER)
        cr:clip()

        if surf then
            local sw = surf:get_width()
            local sh = surf:get_height()
            local cw, ch = w - 2*pad, h - 2*pad
            local scale = math.max(cw / sw, ch / sh)
            cr:save()
            cr:translate((cw - sw * scale) / 2, (ch - sh * scale) / 2)
            cr:scale(scale, scale)
            cr:set_source_surface(surf, 0, 0)
            cr:paint()
            cr:restore()
        else
            cr:set_source_rgb(dr, dg, db)
            cr:paint()
        end

        cr:restore()

        if self.selected then
            cr:set_source_rgba(1, 1, 1, 0.9)
            cr:set_line_width(2)
            cr:translate(pad - 1, pad - 1)
            gears.shape.rounded_rect(cr, w - 2*(pad - 1), h - 2*(pad - 1), CORNER)
            cr:stroke()
        end
    end

    local function update()
        thumb.has_wins = #t:clients() > 0
        thumb.selected = t.selected
        thumb:emit_signal("widget::redraw_needed")
    end

    local layout = wibox.container.margin(thumb, 0, 0, wibar_height - thumb_h - 2, 2)
    layout:buttons(gears.table.join(
        awful.button({}, 1,
            function() transitions.prepare(t.screen, t) end,
            function() transitions.switch(t.screen, t) end)
    ))

    t:connect_signal("property::selected",   function() update() end)
    t:connect_signal("tagged",               function() update() end)
    t:connect_signal("untagged",             function() update() end)
    t:connect_signal("transitions::arrived", function() update() end)

    update()
    return layout
end

awful.screen.connect_for_each_screen(function(s)
    awful.tag({ "1", "2", "3", "4", "5" }, s, splitwm.layout)

    -- Per-tag wallpaper: rendered in the splitwm underlay wibox (type="desktop").
    for i, t in ipairs(s.tags) do
        local ws = WORKSPACES[i]
        t:connect_signal("property::selected", function()
            if t.selected then splitwm.set_wallpaper(s, ws) end
        end)
        if t.selected then splitwm.set_wallpaper(s, ws) end
    end

    timebar.setup(s)

    s.mypromptbox = awful.widget.prompt()

    -- Build taglist manually so we have direct widget references (no
    -- get_children_by_id indirection that proved unreliable).
    local taglist_layout = wibox.layout.fixed.horizontal()
    taglist_layout.spacing = 4
    for i, t in ipairs(s.tags) do
        taglist_layout:add(make_tag_widget(t, WORKSPACES[i]))
    end
    s.mytaglist = taglist_layout

    local hunger_parts  = hunger_mod.new_widget(capsule_height)

    -- Capsule helper: wraps widget(s) in a black shaped background
    local function capsule(inner, pad_l, pad_r, shape_fn, bgc)
        bgc = bgc or "#00000000"
        local bg = wibox.container.background()
        bg.bg    = bgc
        bg.shape = shape_fn or function(cr, w, h)
            gears.shape.partially_rounded_rect(cr, w, h, true, true, false, false, capsule_height / 2)
        end
        bg:set_widget(wibox.container.margin(inner, pad_l or 10, pad_r or 10, 0, 0))
        local m = wibox.container.margin(bg, 0, 0, bar_margin + 2, 0)
        return wibox.container.constraint(m, "exact", nil, capsule_height + bar_margin + 2)
    end

    local hunger_inner = wibox.layout.fixed.horizontal()
    hunger_inner.spacing = bar_margin
    hunger_inner:add(wibox.container.margin(hunger_parts.button, 0, 0, 3, -5))
    hunger_inner:add(hunger_parts.apples)
    local hunger_row = capsule(hunger_inner, 16, 20, splitwm.tab_shape, "#000000ff")

    local status_clock_capsule = status.new_status_clock_capsule(
        bar_margin, capsule_height, icon_bottom_pad, splitwm.tab_shape)

    local sg = beautiful.splitwm_gap
    s.mywibox = wibox({
        x       = s.geometry.x + sg,
        y       = s.geometry.y + s.geometry.height - wibar_height,
        width   = s.geometry.width - sg * 2,
        height  = wibar_height,
        bg      = "#00000000",
        ontop   = false,
        screen  = s,
        visible = true,
        type    = "dock",
    })
    s.mywibox:setup {
        layout = wibox.layout.align.horizontal,
        { -- Left
            layout = wibox.layout.fixed.horizontal,
            wibox.container.margin(s.mytaglist, 0, 0, 0, 0),
            s.mypromptbox,
        },
        { widget = wibox.container.place, valign = "bottom", hunger_row }, -- Center
        { -- Right: status capsule flush with the wibar's right (gap) edge
            layout = wibox.layout.fixed.horizontal,
            spacing = bar_margin,
            wibox.widget.systray(),
            { widget = wibox.container.place, valign = "bottom", status_clock_capsule },
        },
    }

    -- Lock button in its own wibox at the actual screen corner
    local lock_w = capsule_height + bar_margin
    s.mylock_wibox = wibox({
        x       = s.geometry.x + s.geometry.width - lock_w,
        y       = s.geometry.y + s.geometry.height - wibar_height,
        width   = lock_w,
        height  = wibar_height,
        bg      = "#00000000",
        ontop   = false,
        screen  = s,
        visible = true,
        type    = "dock",
    })
    s.mylock_wibox:setup {
        wibox.container.margin(
            status.new_lock_widget(capsule_height), 0, bar_margin, wibar_height - capsule_height - 2, 0),
        layout = wibox.layout.fixed.horizontal,
    }
end)

---------------------------------------------------------------------------
-- Key bindings
---------------------------------------------------------------------------

local globalkeys = gears.table.join(

    -- Help
    awful.key({ modkey }, "s", hotkeys_popup.show_help,
        { description = "show help", group = "awesome" }),

    -- Terminal
    awful.key({ modkey }, "Return", function() awful.spawn(terminal) end,
        { description = "open terminal", group = "launcher" }),

    -- Restart / quit awesome
    awful.key({ modkey, "Control" }, "r", awesome.restart,
        { description = "reload awesome", group = "awesome" }),
    awful.key({ modkey, "Shift" }, "q", awesome.quit,
        { description = "quit awesome", group = "awesome" }),

    -- Prompt
    awful.key({ modkey }, "r",
        function() awful.screen.focused().mypromptbox:run() end,
        { description = "run prompt", group = "launcher" }),

    awful.key({ modkey }, "space",
        function() awful.spawn("rofi -show combi") end,
        { description = "rofi combi launcher", group = "launcher" }),

    ---------------------------------------------------------------------------
    -- SPLITWM: Split management
    ---------------------------------------------------------------------------

    awful.key({ modkey }, "v", splitwm.split_horizontal,
        { description = "split horizontally", group = "splitwm" }),

    awful.key({ modkey }, "h", splitwm.split_vertical,
        { description = "split vertically", group = "splitwm" }),

    awful.key({ modkey }, "q", splitwm.close_split,
        { description = "close current split", group = "splitwm" }),

    ---------------------------------------------------------------------------
    -- SPLITWM: Focus between splits
    ---------------------------------------------------------------------------

    awful.key({ modkey }, "Tab", splitwm.focus_next_split,
        { description = "focus next split", group = "splitwm" }),

    awful.key({ modkey, "Shift" }, "Tab", splitwm.focus_prev_split,
        { description = "focus prev split", group = "splitwm" }),

    ---------------------------------------------------------------------------
    -- SPLITWM: Tab management
    ---------------------------------------------------------------------------

    awful.key({ modkey }, "]", splitwm.next_tab,
        { description = "next tab in split", group = "splitwm" }),

    awful.key({ modkey }, "[", splitwm.prev_tab,
        { description = "prev tab in split", group = "splitwm" }),

    awful.key({ modkey, "Shift" }, "]", splitwm.move_tab_next,
        { description = "move tab to next split", group = "splitwm" }),

    awful.key({ modkey, "Shift" }, "[", splitwm.move_tab_prev,
        { description = "move tab to prev split", group = "splitwm" }),

    ---------------------------------------------------------------------------
    -- SPLITWM: Resize
    ---------------------------------------------------------------------------

    awful.key({ modkey }, "l", splitwm.resize_grow,
        { description = "grow split", group = "splitwm" }),

    awful.key({ modkey, "Shift" }, "l", splitwm.resize_shrink,
        { description = "shrink split", group = "splitwm" }),

    awful.key({}, "Escape", splitwm.cancel_pickup,
        { description = "cancel tab move", group = "splitwm" }),

    ---------------------------------------------------------------------------
    -- Tag switching (standard)
    ---------------------------------------------------------------------------

    awful.key({ modkey }, "Left",  function() transitions.switch_prev() end,
        { description = "view previous", group = "tag" }),
    awful.key({ modkey }, "Right", function() transitions.switch_next() end,
        { description = "view next", group = "tag" }),

    ---------------------------------------------------------------------------
    -- Media / volume
    ---------------------------------------------------------------------------

    awful.key({}, "XF86AudioRaiseVolume", function()
        awful.spawn.easy_async("pactl set-sink-volume @DEFAULT_SINK@ +5%", status.refresh_volume)
    end, { description = "raise volume", group = "media" }),

    awful.key({}, "XF86AudioLowerVolume", function()
        awful.spawn.easy_async("pactl set-sink-volume @DEFAULT_SINK@ -5%", status.refresh_volume)
    end, { description = "lower volume", group = "media" }),

    awful.key({}, "XF86AudioMute", function()
        awful.spawn.easy_async("pactl set-sink-mute @DEFAULT_SINK@ toggle", status.refresh_volume)
    end, { description = "toggle mute", group = "media" })
)

-- Bind number keys to tags
for i = 1, 5 do
    globalkeys = gears.table.join(globalkeys,
        awful.key({ modkey }, "#" .. i + 9,
            function()
                local s = awful.screen.focused()
                local t = s.tags[i]
                if t then transitions.switch(s, t) end
            end,
            { description = "view tag #" .. i, group = "tag" })
    )
end

root.keys(globalkeys)

---------------------------------------------------------------------------
-- Client keys & buttons
---------------------------------------------------------------------------

local clientkeys = gears.table.join(
    awful.key({ modkey }, "f", function(c)
        c.fullscreen = not c.fullscreen
        c:raise()
    end, { description = "toggle fullscreen", group = "client" }),

    awful.key({ modkey, "Shift" }, "c", function(c) c:kill() end,
        { description = "close", group = "client" }),

    awful.key({ "Mod1" }, "F4", function(c) c:kill() end,
        { description = "close (Alt+F4)", group = "client" }),

    awful.key({ modkey, "Control" }, "space",
        awful.client.floating.toggle,
        { description = "toggle floating", group = "client" })
)

local clientbuttons = gears.table.join(
    awful.button({}, 1, function(c)
        c:emit_signal("request::activate", "mouse_click", { raise = true })
    end),
    awful.button({ modkey }, 1, function(c)
        c:emit_signal("request::activate", "mouse_click", { raise = true })
        awful.mouse.client.move(c)
    end),
    awful.button({ modkey }, 3, function(c)
        c:emit_signal("request::activate", "mouse_click", { raise = true })
        awful.mouse.client.resize(c)
    end)
)

---------------------------------------------------------------------------
-- Rules
---------------------------------------------------------------------------

awful.rules.rules = {
    {
        rule = {},
        properties = {
            border_width = beautiful.border_width,
            border_color = beautiful.border_normal,
            focus     = awful.client.focus.filter,
            raise     = true,
            keys      = clientkeys,
            buttons   = clientbuttons,
            screen    = awful.screen.preferred,
            placement = awful.placement.no_overlap + awful.placement.no_offscreen,
        },
    },
    -- Floating dialogs
    {
        rule_any = { type = { "dialog" } },
        properties = { floating = true },
    },
}

---------------------------------------------------------------------------
-- Signals
---------------------------------------------------------------------------

client.connect_signal("manage", function(c)
    if awesome.startup and not c.size_hints.user_position
       and not c.size_hints.program_position then
        awful.placement.no_offscreen(c)
    end
end)
