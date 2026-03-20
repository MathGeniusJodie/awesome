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
beautiful.splitwm_fg_disabled    = "#ffffff40"
beautiful.splitwm_close_fg       = "#ff6666ff"
beautiful.splitwm_btn_bg         = "#00000080"  -- transparent circle button bg
beautiful.splitwm_transparent    = "#00000000"  -- fully transparent
beautiful.splitwm_fg_hover       = "#ffffff22"  -- hover highlight

-- Splitwm layout
beautiful.splitwm_gap              = 34
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

local splitwm  = require("splitwm")
local swcolors = require("splitwm.colors")
local menu     = require("menu")
local status   = require("status")
local timebar  = require("timebar")

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
local wibar_height   = bar_margin * 2 + capsule_height  -- equal top + bottom padding
local icon_bottom_pad = 2  -- gap between icon bottom and capsule bottom edge

local function parse_hex(hex)
    hex = hex:gsub("#", "")
    return tonumber(hex:sub(1,2), 16) / 255,
           tonumber(hex:sub(3,4), 16) / 255,
           tonumber(hex:sub(5,6), 16) / 255
end

--- Build a single tag button: colored circle + dots drawn via Cairo below.
local function make_tag_widget(t, color)
    -- Custom dot-indicator widget: draws N white circles via Cairo directly.
    -- This avoids all container/layout sizing issues.
    local dots = wibox.widget.base.make_widget()
    dots.n        = 0
    dots.selected = false
    dots.forced_height = 7

    function dots:fit(_, w, h)
        if self.n == 0 then return 0, 7 end
        local show = math.min(self.n, 3)
        return math.ceil(show * 5 + (show - 1) * 3), 7
    end

    local dr, dg, db = parse_hex(color.dark)  -- pre-computed once, reused in draw

    function dots:draw(_, cr, w, h)
        if self.n == 0 then return end
        local show  = math.min(self.n, 3)
        local r     = 2.5
        local gap   = 3
        local pad   = 2
        local total = show * (r * 2) + (show - 1) * gap
        local cap_w = total + pad * 2
        local cap_x = (w - cap_w) / 2

        -- Capsule background: dark color variant, opaque when selected else semi-transparent
        cr:set_source_rgba(dr, dg, db, self.selected and 1 or 0.5)
        cr:save()
        cr:translate(cap_x, 0)
        gears.shape.rounded_rect(cr, cap_w, h, h / 2)
        cr:restore()
        cr:fill()

        -- Dots centered inside capsule
        local x0 = cap_x + pad + r
        cr:set_source_rgba(1, 1, 1, 1)
        for i = 1, show do
            if i == 3 and self.n > 3 then
                local cx = x0 + (i - 1) * (r * 2 + gap)
                local cy = h / 2
                local arm = r + 0.5
                cr:set_line_width(1.5)
                cr:move_to(cx - arm, cy) cr:line_to(cx + arm, cy) cr:stroke()
                cr:move_to(cx, cy - arm) cr:line_to(cx, cy + arm) cr:stroke()
            else
                cr:arc(x0 + (i - 1) * (r * 2 + gap), h / 2, r, 0, math.pi * 2)
                cr:fill()
            end
        end
    end

    local function update_dots()
        dots.n = #t:clients()
        dots:emit_signal("widget::layout_changed")
        dots:emit_signal("widget::redraw_needed")
    end

    -- Outer ring: white when selected, transparent otherwise
    local ring = wibox.container.background()
    ring.forced_width  = capsule_height
    ring.forced_height = capsule_height
    ring.shape         = gears.shape.circle
    ring.bg            = "#00000000"

    -- Inner colored circle, inset 2px on each side to reveal the ring
    local circle = wibox.container.background()
    circle.forced_width  = capsule_height - 4
    circle.forced_height = capsule_height - 4
    circle.shape         = gears.shape.circle
    circle.bg            = color.dark
    circle:set_widget(wibox.container.place())

    local place_inner = wibox.container.place()
    place_inner:set_widget(circle)
    ring:set_widget(place_inner)

    local function update_circle()
        ring.bg    = t.selected and "#ffffff" or "#00000000"
        circle.bg  = t.selected and color.light or color.dark
        dots.selected = t.selected
        dots:emit_signal("widget::redraw_needed")
    end

    -- Circle pinned to top; dots (self-drawing capsule) pushed to the very bottom
    local tag_layout = wibox.layout.stack()
    tag_layout:add(wibox.container.margin(ring, 0, 0, bar_margin, bar_margin))
    tag_layout:add(wibox.container.margin(dots, 0, 0, wibar_height - bar_margin - dots.forced_height, 0))

    tag_layout:buttons(gears.table.join(
        awful.button({}, 1, function() t:view_only() end)
    ))

    t:connect_signal("property::selected", function() update_circle() end)
    t:connect_signal("tagged",             function() update_circle(); update_dots() end)
    t:connect_signal("untagged",           function() update_circle(); update_dots() end)

    update_circle()
    update_dots()
    return tag_layout
end

awful.screen.connect_for_each_screen(function(s)
    awful.tag({ "1", "2", "3", "4", "5" }, s, splitwm.layout)

    -- Per-tag wallpaper: rendered in the splitwm underlay wibox (type="desktop").
    local function set_wallpaper(ws)
        splitwm.set_wallpaper(s, ws)
    end
    for i, t in ipairs(s.tags) do
        local ws = WORKSPACES[i]
        t:connect_signal("property::selected", function()
            if t.selected then set_wallpaper(ws) end
        end)
        if t.selected then set_wallpaper(ws) end
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

    local dow_codes = { "Su", "Mo", "Tu", "We", "Th", "Fr", "Sa" }
    local mon_codes = { "Ja", "Fe", "Mr", "Ap", "My", "Jn", "Jl", "Au", "Se", "Oc", "Nv", "De" }

    local mydate = wibox.widget.textbox()
    mydate.font   = "monospace 14px"
    mydate.valign = "bottom"
    local function update_date()
        local t = os.date("*t")
        mydate.text = dow_codes[t.wday] .. " " .. mon_codes[t.month]
                      .. " " .. string.format("%02d", t.day)
                      .. " " .. string.format("%02d", t.year % 100)
    end
    update_date()
    gears.timer { timeout = 60, autostart = true, call_now = false, callback = update_date }

    local myclock = wibox.widget.textbox()
    myclock.font   = "monospace bold 14px"
    myclock.valign = "bottom"
    local function update_clock()
        local t = os.date("%I:%M")
        local ap = os.date("%p"):lower()
        myclock.markup = string.format(
            '%s<span font_variant="small-caps">%s</span>', t, ap)
    end
    update_clock()
    gears.timer { timeout = 60, autostart = true, call_now = false, callback = update_clock }

    local bat_widget  = status.new_battery_widget()
    local vol_widget  = status.new_volume_widget()
    local chip_widget = status.new_chip_widget()

    -- Capsule helper: wraps widget(s) in a black shaped background
    local function capsule(inner, pad_l, pad_r, shape_fn, bgc)
        bgc = bgc or "#00000000"
        local bg = wibox.container.background()
        bg.bg    = bgc
        bg.shape = shape_fn or function(cr, w, h)
            gears.shape.partially_rounded_rect(cr, w, h, true, true, false, false, capsule_height / 2)
        end
        bg:set_widget(wibox.container.margin(inner, pad_l or 10, pad_r or 10, 0, 0))
        return wibox.container.margin(bg, 0, 0, bar_margin + 2, 0)
    end

    -- Status icons capsule (chip + battery + volume) — tab profile on left side
    local icons_row = wibox.layout.fixed.horizontal()
    icons_row.spacing = 4
    icons_row:add(wibox.container.margin(chip_widget, 0, 0, 0, icon_bottom_pad))
    icons_row:add(wibox.container.margin(bat_widget,  0, 0, 0, icon_bottom_pad))
    icons_row:add(wibox.container.margin(vol_widget,  0, 0, 0, icon_bottom_pad))
    local status_capsule = capsule(icons_row, 24, 22, splitwm.tab_shape, "#000000ff")

    -- Date / clock capsule — tab profile on right side
    local dt_row = wibox.layout.fixed.horizontal()
    dt_row.spacing = 8
    dt_row:add(mydate)
    dt_row:add(myclock)
    local dt_capsule = capsule(wibox.container.margin(dt_row, 0, 0, 0, 0), 26, 26, splitwm.tab_shape, "#000000ff")

    local lock_capsule = wibox.container.margin(
        status.new_lock_widget(capsule_height), 0, 0, wibar_height - capsule_height - 2, 0)

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
            wibox.container.margin(s.mytaglist, bar_margin, 0, 0, 0),
            s.mypromptbox,
        },
        nil, -- Center: empty
        { -- Right
            layout = wibox.layout.fixed.horizontal,
            spacing = bar_margin,
            wibox.widget.systray(),
            status_capsule,
            dt_capsule,
            wibox.container.margin(lock_capsule, 0, bar_margin, 0, 0),
        },
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

    awful.key({ modkey }, "Left",  awful.tag.viewprev,
        { description = "view previous", group = "tag" }),
    awful.key({ modkey }, "Right", awful.tag.viewnext,
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
                if t then t:view_only() end
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
