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
local menubar   = require("menubar")
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
beautiful.splitwm_gap        = 28
beautiful.splitwm_inactive_bg  = "#00000080"
beautiful.splitwm_empty_bg   = "#00000080"
beautiful.splitwm_focus_border = "#7799dd"
beautiful.splitwm_empty_border = "#555555"
beautiful.splitwm_tab_active_bg = "#000000"
beautiful.splitwm_tab_active_fg = "#ffffff"
beautiful.splitwm_tab_fg     = "#888888"
beautiful.splitwm_handle_hover_bg = "#7799dd22"
beautiful.splitwm_handle_drag_bg  = "#7799dd44"
beautiful.splitwm_launcher_bg       = "#3a3a3a"
beautiful.splitwm_launcher_hover_bg  = "#555555"
beautiful.splitwm_focus_border_width = 2
beautiful.splitwm_font           = "monospace 12"
beautiful.splitwm_btn_font       = "monospace bold 14"
beautiful.titlebar_bg_normal     = "#00000000"
beautiful.titlebar_bg_focus      = "#00000000"

-- Wallpaper
local wallpaper_path = os.getenv("HOME") .. "/background.jpg"
awful.screen.connect_for_each_screen(function(s)
    gears.wallpaper.maximized(wallpaper_path, s, true)
end)

---------------------------------------------------------------------------
-- Load splitwm
---------------------------------------------------------------------------

-- Add the directory containing this rc.lua to the Lua path
-- so that `require("splitwm")` finds our module
local config_dir = gears.filesystem.get_configuration_dir()
package.path = config_dir .. "?.lua;"
            .. config_dir .. "?/init.lua;"
            .. package.path

local splitwm = require("splitwm")

---------------------------------------------------------------------------
-- Variables
---------------------------------------------------------------------------

local terminal = os.getenv("TERMINAL") or "xterm"
local editor   = os.getenv("EDITOR") or "vim"
local modkey   = "Mod4"

-- Browser detection: try common browsers
local browser = os.getenv("BROWSER") or "xdg-open http://"
-- File manager detection
local filemanager = "thunar"  -- XFCE default; change to your preference

---------------------------------------------------------------------------
-- Freedesktop app menu (auto-generated from .desktop files)
---------------------------------------------------------------------------

local menubar_utils = require("menubar.utils")
local menu_gen      = require("menubar.menu_gen")

-- Build the app menu asynchronously from .desktop files
-- We start with a placeholder and replace it once generation completes.
local app_menu = awful.menu {
    items = {
        { "Loading apps...", nil },
    },
    theme = { width = 200, height = 24 },
}

menu_gen.generate(function(entries)
    -- Group entries by category
    local categories = {}
    local cat_names  = {}
    for _, entry in ipairs(entries) do
        local cat = entry.category or "Other"
        if not categories[cat] then
            categories[cat] = {}
            table.insert(cat_names, cat)
        end
        table.insert(categories[cat], {
            entry.name,
            entry.cmdline,
            entry.icon or nil,
        })
    end
    table.sort(cat_names)

    -- Build menu items with category submenus
    local menu_items = {}
    for _, cat in ipairs(cat_names) do
        -- Sort apps within each category
        table.sort(categories[cat], function(a, b)
            return (a[1] or "") < (b[1] or "")
        end)
        -- Look up category icon
        local cat_icon_names = {
            Utility     = "applications-utilities",
            Development = "applications-development",
            Education   = "applications-science",
            Game        = "applications-games",
            Graphics    = "applications-graphics",
            Network     = "applications-internet",
            AudioVideo  = "applications-multimedia",
            Office      = "applications-office",
            Settings    = "preferences-desktop",
            System      = "applications-system",
        }
        local cat_icon = menubar_utils.lookup_icon(cat_icon_names[cat] or "applications-other")
        if cat_icon == false then cat_icon = nil end
        table.insert(menu_items, { cat, categories[cat], cat_icon })
    end

    -- Add extras at the bottom
    table.insert(menu_items, { "─────────────" })
    table.insert(menu_items, { "Run...", function()
        awful.screen.focused().mypromptbox:run()
    end })

    -- NOW the icon theme is ready — resolve launcher icons
    for _, launcher in ipairs(splitwm.launchers) do
        if not launcher.icon then
            -- Try primary icon_name, then fallbacks
            local names = launcher.icon_names or {}
            if launcher.icon_name then
                table.insert(names, 1, launcher.icon_name)
            end
            for _, name in ipairs(names) do
                local path = menubar_utils.lookup_icon(name)
                if path and path ~= false and type(path) == "string" then
                    launcher.icon = path
                    break
                end
            end
        end
    end

    -- Prepend quick-launch items at the top (icons now resolved above)
    local quick_items = {
        { "Terminal",     function() awful.spawn(terminal)     end, splitwm.launchers[1].icon },
        { "Browser",      function() awful.spawn(browser)      end, splitwm.launchers[2].icon },
        { "File Manager", function() awful.spawn(filemanager)  end, splitwm.launchers[3].icon },
        { "─────────────" },
    }
    for i = #quick_items, 1, -1 do
        table.insert(menu_items, 1, quick_items[i])
    end

    -- Replace the placeholder menu
    app_menu = awful.menu {
        items = menu_items,
        theme = { width = 200, height = 24 },
    }

    -- Flush render caches so overlays and titlebars rebuild with the new icons
    splitwm.flush_caches()
    local s = awful.screen.focused()
    if s then awful.layout.arrange(s) end
end)

---------------------------------------------------------------------------
-- App launchers shown in splits (icon with text fallback)
-- icon_name = XDG name, resolved after icon theme loads
---------------------------------------------------------------------------

splitwm.launchers = {
    {
        label      = "$",
        icon_name  = "utilities-terminal",
        icon_names = {"utilities-terminal", "terminal", "xterm", "org.xfce.terminal"},
        cmd        = terminal,
    },
    {
        label      = "B",
        icon_name  = "internet-web-browser",
        icon_names = {"internet-web-browser", "web-browser", "firefox", "firefox-esr",
                      "librewolf", "brave-browser", "chromium", "google-chrome"},
        cmd        = browser,
    },
    {
        label      = "F",
        icon       = "/usr/share/icons/Adwaita/scalable/places/folder.svg",
        cmd        = filemanager,
    },
}

splitwm.on_menu_request = function()
    app_menu:toggle()
end

-- Close menu on any client focus change
client.connect_signal("focus", function()
    app_menu:hide()
end)

-- Close menu when clicking anywhere on root window
root.buttons(gears.table.join(
    awful.button({}, 1, function() app_menu:hide() end),
    awful.button({}, 3, function() app_menu:hide() end)
))

-- Close menu when clicking empty split overlays
splitwm.on_background_click = function()
    app_menu:hide()
end

-- Poll: if menu is visible and a mouse button is pressed outside it, close
do
    local was_visible = false
    local was_pressed = false
    local skip_count = 0
    gears.timer {
        timeout   = 0.05,
        autostart = true,
        callback  = function()
            local visible = app_menu.wibox and app_menu.wibox.visible
            if not visible then
                was_visible = false
                was_pressed = false
                skip_count = 0
                return
            end

            local m = mouse.coords()
            local pressed = (m.buttons[1] or m.buttons[3]) and true or false

            -- Menu just became visible: set was_pressed to current state
            -- and skip a few ticks to let the opening click fully release
            if not was_visible then
                was_visible = true
                was_pressed = pressed
                skip_count = 5  -- skip 5 ticks (250ms at 50ms interval)
                return
            end

            if skip_count > 0 then
                skip_count = skip_count - 1
                was_pressed = pressed
                return
            end

            -- Detect fresh press (was not pressed, now is)
            if pressed and not was_pressed then
                local dominated = false
                local function check(menu)
                    if menu and menu.wibox and menu.wibox.visible then
                        local g = menu.wibox:geometry()
                        if m.x >= g.x and m.x <= g.x + g.width
                           and m.y >= g.y and m.y <= g.y + g.height then
                            dominated = true
                        end
                        if menu.active_child then check(menu.active_child) end
                    end
                end
                check(app_menu)
                if not dominated then
                    app_menu:hide()
                end
            end
            was_pressed = pressed
        end,
    }
end

splitwm.setup()

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
beautiful.font           = "monospace bold 12"
beautiful.fg_normal      = "#ffffff"
beautiful.fg_focus       = "#ffffff"

---------------------------------------------------------------------------
-- Status widgets: battery + volume + chip (cpu/ram/swap)
---------------------------------------------------------------------------

local battery_widgets = {}
local volume_widgets  = {}
local chip_widgets    = {}

local function make_battery_widget()
    local w = wibox.widget.base.make_widget()
    w.percentage = 0
    w.charging   = false

    function w:fit(_, _, h) return 24, h end

    function w:draw(_, cr, width, height)
        local bw, bh = 9, 15
        local nub_w, nub_h = 5, 2
        local bx = math.floor((width - bw) / 2)
        local nub_top = math.floor((height - bh - nub_h) / 2)
        local by = nub_top + nub_h
        local nub_x = bx + math.floor((bw - nub_w) / 2)

        local pct = math.max(0, math.min(100, self.percentage))

        -- Nub
        cr:set_source_rgba(1, 1, 1, 1)
        cr:rectangle(nub_x, nub_top, nub_w, nub_h)
        cr:fill()

        -- Body outline (subtle corner radius)
        cr:set_source_rgba(1, 1, 1, 1)
        cr:set_line_width(2)
        cr:save()
        cr:translate(bx, by)
        gears.shape.rounded_rect(cr, bw, bh, 1.5)
        cr:restore()
        cr:stroke()

        -- Fill (from bottom up)
        if pct <= 20 then
            cr:set_source_rgba(1, 0.3, 0.3, 1)
        elseif pct <= 40 then
            cr:set_source_rgba(1, 0.65, 0.15, 1)
        else
            cr:set_source_rgba(1, 1, 1, 1)
        end
        local fill_h = math.max(0, math.floor((bh - 4) * pct / 100))
        if fill_h > 0 then
            cr:rectangle(bx + 2, by + bh - 2 - fill_h, bw - 4, fill_h)
            cr:fill()
        end

        -- Lightning bolt when charging
        if self.charging then
            cr:set_source_rgba(1, 1, 0, 1)
            cr:set_line_width(1.5)
            local cx = bx + bw / 2
            local t, m, b = by + 3, by + bh / 2, by + bh - 3
            cr:move_to(cx + 3, t)
            cr:line_to(cx - 2, m)
            cr:line_to(cx + 2, m)
            cr:line_to(cx - 3, b)
            cr:stroke()
        end
    end

    return w
end

local function refresh_battery()
    for _, name in ipairs({ "BAT0", "BAT1", "BAT" }) do
        local fc = io.open("/sys/class/power_supply/" .. name .. "/capacity", "r")
        if fc then
            local cap = tonumber(fc:read("*l")); fc:close()
            local fs = io.open("/sys/class/power_supply/" .. name .. "/status", "r")
            local status = fs and fs:read("*l") or ""
            if fs then fs:close() end
            for _, w in ipairs(battery_widgets) do
                w.percentage = cap or 0
                w.charging   = (status == "Charging")
                w:emit_signal("widget::redraw_needed")
            end
            return
        end
    end
end

local function make_volume_widget()
    local w = wibox.widget.base.make_widget()
    w.volume = 0
    w.muted  = false

    function w:fit(_, _, h) return 28, h end

    function w:draw(_, cr, _, height)
        local cy = height / 2
        local sx = 3  -- left edge of speaker body

        cr:set_source_rgba(1, 1, 1, 1)

        -- Speaker body: box + flared cone (filled polygon)
        cr:move_to(sx,      cy + 4)
        cr:line_to(sx,      cy - 4)
        cr:line_to(sx + 4,  cy - 4)
        cr:line_to(sx + 10, cy - 8)
        cr:line_to(sx + 10, cy + 8)
        cr:line_to(sx + 4,  cy + 4)
        cr:close_path()
        cr:fill()

        -- Sound waves or mute X, starting just right of the cone tip
        local ax = sx + 10
        cr:set_line_width(1.5)

        if self.muted then
            local cx, s = ax + 7, 3.5
            cr:set_line_width(2.5)
            cr:set_line_cap(1)  -- ROUND
            cr:move_to(cx - s, cy - s) cr:line_to(cx + s, cy + s) cr:stroke()
            cr:move_to(cx + s, cy - s) cr:line_to(cx - s, cy + s) cr:stroke()
        else
            local waves = self.volume > 60 and 3
                       or self.volume > 25 and 2
                       or self.volume >  0 and 1
                       or 0
            for i = 1, waves do
                cr:arc(ax, cy, i * 3.5, -math.pi / 2.8, math.pi / 2.8)
                cr:stroke()
            end
        end
    end

    return w
end

local function refresh_volume()
    awful.spawn.easy_async_with_shell(
        "pactl get-sink-mute @DEFAULT_SINK@ 2>/dev/null; pactl get-sink-volume @DEFAULT_SINK@ 2>/dev/null",
        function(out)
            local muted = out:match("Mute: yes") ~= nil
            local vol   = tonumber(out:match("(%d+)%%")) or 0
            for _, w in ipairs(volume_widgets) do
                w.volume = vol
                w.muted  = muted
                w:emit_signal("widget::redraw_needed")
            end
        end
    )
end

local function make_chip_widget()
    local w = wibox.widget.base.make_widget()
    w.cpu  = 0
    w.ram  = 0
    w.swap = 0

    local cw, ch    = 15, 15
    local pin_len   = 3
    local n_pins    = 3

    function w:fit(_, _, h) return cw + pin_len * 2 + 6, h end

    function w:draw(_, cr, width, height)
        local cx = math.floor(width / 2)
        local cy = math.floor(height / 2)
        local bx = cx - math.floor(cw / 2)
        local by = cy - math.floor(ch / 2)

        -- Pins (top and bottom), same line_width as battery outline
        cr:set_source_rgba(1, 1, 1, 1)
        cr:set_line_width(2)
        local pin_spacing = cw / (n_pins + 1)
        for i = 1, n_pins do
            local px = bx + i * pin_spacing
            cr:move_to(px, by)
            cr:line_to(px, by - pin_len)
            cr:stroke()
            cr:move_to(px, by + ch)
            cr:line_to(px, by + ch + pin_len)
            cr:stroke()
        end

        -- Body outline: identical to battery (line_width 2, radius 1.5)
        cr:set_source_rgba(1, 1, 1, 1)
        cr:set_line_width(2)
        cr:save()
        cr:translate(bx, by)
        gears.shape.rounded_rect(cr, cw, ch, 1.5)
        cr:restore()
        cr:stroke()

        -- 3 vertical gauges inside body, 1px gap between them
        -- Inner area matches battery fill inset: 2px from each edge
        local pad = 2
        local gap = 1
        local n   = 3
        local gh  = ch - pad * 2
        local gw  = math.floor((cw - pad * 2 - gap * (n - 1)) / n)
        local gy  = by + pad

        local gauges = {
            { pct = self.cpu,  r = 1,   g = 1,   b = 1   },
            { pct = self.ram,  r = 1,   g = 1,   b = 1   },
            { pct = self.swap, r = 1,   g = 0.3, b = 0.3 },
        }

        for i, gauge in ipairs(gauges) do
            local gx = bx + pad + (i - 1) * (gw + gap)

            cr:set_source_rgba(1, 1, 1, 0.2)
            cr:rectangle(gx, gy, gw, gh)
            cr:fill()

            local fill_h = math.floor(gh * math.max(0, math.min(1, gauge.pct)))
            if fill_h > 0 then
                cr:set_source_rgba(gauge.r, gauge.g, gauge.b, 0.9)
                cr:rectangle(gx, gy + gh - fill_h, gw, fill_h)
                cr:fill()
            end
        end
    end

    return w
end

-- prev_cpu_idle/total for delta calculation
local _cpu_prev_idle, _cpu_prev_total = 0, 0

local function refresh_chip()
    -- CPU: read /proc/stat
    local f = io.open("/proc/stat", "r")
    local cpu_pct = 0
    if f then
        local line = f:read("*l"); f:close()
        local vals = {}
        for v in line:gmatch("%d+") do vals[#vals+1] = tonumber(v) end
        local idle  = (vals[4] or 0) + (vals[5] or 0)
        local total = 0
        for _, v in ipairs(vals) do total = total + v end
        local d_idle  = idle  - _cpu_prev_idle
        local d_total = total - _cpu_prev_total
        if d_total > 0 then
            cpu_pct = 1 - d_idle / d_total
        end
        _cpu_prev_idle, _cpu_prev_total = idle, total
    end

    -- RAM + swap: read /proc/meminfo
    local ram_pct, swap_pct = 0, 0
    local mf = io.open("/proc/meminfo", "r")
    if mf then
        local mem = {}
        for line in mf:lines() do
            local k, v = line:match("^(%w+):%s+(%d+)")
            if k then mem[k] = tonumber(v) end
        end
        mf:close()
        local total_mem = mem["MemTotal"] or 1
        local avail_mem = mem["MemAvailable"] or total_mem
        ram_pct = 1 - avail_mem / total_mem

        local swap_total = mem["SwapTotal"] or 0
        local swap_free  = mem["SwapFree"]  or swap_total
        if swap_total > 0 then
            swap_pct = 1 - swap_free / swap_total
        end
    end

    for _, w in ipairs(chip_widgets) do
        w.cpu  = cpu_pct
        w.ram  = ram_pct
        w.swap = swap_pct
        w:emit_signal("widget::redraw_needed")
    end
end

gears.timer { timeout = 30, autostart = true, call_now = true, callback = refresh_battery }
gears.timer { timeout = 2,  autostart = true, call_now = true, callback = refresh_volume }
gears.timer { timeout = 2,  autostart = true, call_now = true, callback = refresh_chip }

--- Build a single tag button: circle + dots drawn via Cairo below.
local function make_tag_widget(t)
    -- Custom dot-indicator widget: draws N white circles via Cairo directly.
    -- This avoids all container/layout sizing issues.
    local dots = wibox.widget.base.make_widget()
    dots.n = 0
    dots.forced_height = 7

    function dots:fit(_, w, h)
        return 26, h
    end

    function dots:draw(_, cr, w, h)
        if self.n == 0 then return end
        local show  = math.min(self.n, 3)
        local r     = 2.5
        local gap   = 3
        local total = show * (r * 2) + (show - 1) * gap
        local x0    = (w - total) / 2 + r
        cr:set_source_rgba(1, 1, 1, 1)
        for i = 1, show do
            if i == 3 and self.n > 3 then
                -- draw a "+" instead of the third dot
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
        dots:emit_signal("widget::redraw_needed")
    end

    -- Label
    local label = wibox.widget.textbox(t.name)
    label.align  = "center"
    label.valign = "center"
    label.font   = "monospace bold 12"

    -- Circle button
    local place_c = wibox.container.place()
    place_c.halign = "center"
    place_c.valign = "center"
    place_c:set_widget(label)

    local circle = wibox.container.background()
    circle.forced_width  = 26
    circle.forced_height = 26
    circle.shape         = gears.shape.circle
    circle.bg            = "#00000080"
    circle:set_widget(place_c)

    local function update_circle()
        circle.bg = t.selected and "#000000" or "#00000080"
    end

    -- Vertical stack: circle on top, dots below
    local vbox = wibox.layout.fixed.vertical()
    vbox.spacing = 2
    vbox:add(circle)
    vbox:add(dots)

    local margin = wibox.container.margin()
    margin:set_top(3)
    margin:set_bottom(3)
    margin:set_widget(vbox)

    margin:buttons(gears.table.join(
        awful.button({}, 1, function() t:view_only() end)
    ))

    t:connect_signal("property::selected", function() update_circle() end)
    t:connect_signal("tagged",             function() update_circle(); update_dots() end)
    t:connect_signal("untagged",           function() update_circle(); update_dots() end)

    update_circle()
    update_dots()
    return margin
end

awful.screen.connect_for_each_screen(function(s)
    awful.tag({ "1", "2", "3", "4", "5" }, s, splitwm.layout)

    s.mypromptbox = awful.widget.prompt()

    -- Build taglist manually so we have direct widget references (no
    -- get_children_by_id indirection that proved unreliable).
    local taglist_layout = wibox.layout.fixed.horizontal()
    taglist_layout.spacing = 4
    for _, t in ipairs(s.tags) do
        taglist_layout:add(make_tag_widget(t))
    end
    s.mytaglist = taglist_layout

    local mydate = wibox.widget.textclock(" %A, %B %e, %Y ")
    mydate.font = "monospace 12"

    local myclock = wibox.widget.textclock(" %I:%M %p ")
    myclock.font = "monospace bold 12"

    local bat_widget = make_battery_widget()
    table.insert(battery_widgets, bat_widget)

    local vol_widget = make_volume_widget()
    table.insert(volume_widgets, vol_widget)

    local chip_widget = make_chip_widget()
    table.insert(chip_widgets, chip_widget)

    s.mywibox = awful.wibar {
        position = "top",
        screen   = s,
        height   = 42,
        bg       = beautiful.splitwm_inactive_bg,
    }
    s.mywibox:setup {
        layout = wibox.layout.align.horizontal,
        { -- Left
            layout = wibox.layout.fixed.horizontal,
            s.mytaglist,
            s.mypromptbox,
        },
        nil, -- Center: empty
        { -- Right
            layout = wibox.layout.fixed.horizontal,
            wibox.widget.systray(),
            chip_widget,
            bat_widget,
            vol_widget,
            mydate,
            myclock,
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
        awful.spawn.easy_async("pactl set-sink-volume @DEFAULT_SINK@ +5%", refresh_volume)
    end, { description = "raise volume", group = "media" }),

    awful.key({}, "XF86AudioLowerVolume", function()
        awful.spawn.easy_async("pactl set-sink-volume @DEFAULT_SINK@ -5%", refresh_volume)
    end, { description = "lower volume", group = "media" }),

    awful.key({}, "XF86AudioMute", function()
        awful.spawn.easy_async("pactl set-sink-mute @DEFAULT_SINK@ toggle", refresh_volume)
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
