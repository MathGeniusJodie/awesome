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
beautiful.splitwm_gap        = 32
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
local filemanager = os.getenv("FILEMANAGER") or "thunar"

---------------------------------------------------------------------------
-- Freedesktop app menu (auto-generated from .desktop files)
---------------------------------------------------------------------------

local menubar_utils = require("menubar.utils")
local menu_gen      = require("menubar.menu_gen")

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
            entry.icon,
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
    local function launcher_icon(cmd)
        for _, l in ipairs(splitwm.launchers) do
            if l.cmd == cmd then return l.icon end
        end
    end
    local quick_items = {
        { "Terminal",     function() awful.spawn(terminal)     end, launcher_icon(terminal)     },
        { "Browser",      function() awful.spawn(browser)      end, launcher_icon(browser)      },
        { "File Manager", function() awful.spawn(filemanager)  end, launcher_icon(filemanager)  },
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

-- Poll: close the menu if the user clicks outside it.
-- `ready` stays false until all buttons are released after opening, so the
-- opening click itself doesn't immediately re-close the menu.
local menu_poll_timer
do
    local ready = false
    menu_poll_timer = gears.timer {
        timeout   = 0.05,
        autostart = false,
        callback  = function()
            if not (app_menu.wibox and app_menu.wibox.visible) then
                ready = false
                menu_poll_timer:stop()
                return
            end

            local m       = mouse.coords()
            local pressed = (m.buttons[1] or m.buttons[3]) and true or false

            -- Wait for all buttons to be released before arming
            if not ready then
                if not pressed then ready = true end
                return
            end

            if pressed then
                local function inside(menu)
                    if not (menu and menu.wibox and menu.wibox.visible) then return false end
                    local g = menu.wibox:geometry()
                    if m.x >= g.x and m.x <= g.x + g.width
                       and m.y >= g.y and m.y <= g.y + g.height then return true end
                    return menu.active_child and inside(menu.active_child) or false
                end
                if not inside(app_menu) then app_menu:hide() end
            end
        end,
    }
end

splitwm.on_menu_request = function()
    app_menu:toggle()
    menu_poll_timer:start()
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
        -- Horizontal orientation: nub on the right, fill left-to-right
        local bw, bh = 17, 11
        local nub_w, nub_h = 2, 5
        local total_w = bw + nub_w
        local bx = math.floor((width - total_w) / 2)
        local by = math.floor((height - bh) / 2)
        local nub_x = bx + bw
        local nub_y = by + math.floor((bh - nub_h) / 2)

        local pct = math.max(0, math.min(100, self.percentage))

        -- Nub (right side)
        cr:set_source_rgba(1, 1, 1, 1)
        cr:rectangle(nub_x, nub_y, nub_w, nub_h)
        cr:fill()

        -- Body outline
        cr:set_source_rgba(1, 1, 1, 1)
        cr:set_line_width(2)
        cr:save()
        cr:translate(bx, by)
        gears.shape.rounded_rect(cr, bw, bh, 1.5)
        cr:restore()
        cr:stroke()

        -- Fill (left to right)
        if pct <= 20 then
            cr:set_source_rgba(1, 0.3, 0.3, 1)
        elseif pct <= 40 then
            cr:set_source_rgba(1, 0.65, 0.15, 1)
        else
            cr:set_source_rgba(1, 1, 1, 1)
        end
        local fill_w = math.max(0, math.floor((bw - 4) * pct / 100))
        if fill_w > 0 then
            cr:rectangle(bx + 2, by + 2, fill_w, bh - 4)
            cr:fill()
        end

        -- Lightning bolt when charging (horizontal zigzag)
        if self.charging then
            cr:set_source_rgba(1, 1, 0, 1)
            cr:set_line_width(1.5)
            local cx = bx + bw / 2
            local cy = by + bh / 2
            cr:move_to(bx + bw - 2, by + 2)
            cr:line_to(cx + 1, cy)
            cr:line_to(cx + 2, cy)
            cr:line_to(bx + 2, by + bh - 2)
            cr:stroke()
        end
    end

    return w
end

local function refresh_battery()
    -- Synchronous io.open is intentional: sysfs files are kernel virtual
    -- files with no disk I/O. Spawning a subprocess would be heavier.
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

    function w:fit(_, _, h)
        return math.ceil(26 * h / 32), h
    end

    function w:draw(_, cr, _, height)
        -- Scale all coordinates proportionally to height (designed for 32px)
        local s  = height / 32.0
        local cy = height / 2
        local sx = 1 * s

        cr:set_source_rgba(1, 1, 1, 1)

        -- Speaker body: box + flared cone (filled polygon)
        cr:move_to(sx,           cy + 4*s)
        cr:line_to(sx,           cy - 4*s)
        cr:line_to(sx + 4*s,     cy - 4*s)
        cr:line_to(sx + 10*s,    cy - 8*s)
        cr:line_to(sx + 10*s,    cy + 8*s)
        cr:line_to(sx + 4*s,     cy + 4*s)
        cr:close_path()
        cr:fill()

        -- Sound waves or mute X, starting just right of the cone tip
        local ax = sx + 10*s
        cr:set_line_width(1.5 * s)

        if self.muted then
            local cx, ms = ax + 7*s, 3.5*s
            cr:set_line_width(2.5 * s)
            cr:set_line_cap(1)  -- ROUND
            cr:move_to(cx - ms, cy - ms) cr:line_to(cx + ms, cy + ms) cr:stroke()
            cr:move_to(cx + ms, cy - ms) cr:line_to(cx - ms, cy + ms) cr:stroke()
        else
            local waves = self.volume > 60 and 3
                       or self.volume > 25 and 2
                       or self.volume >  0 and 1
                       or 0
            for i = 1, waves do
                cr:arc(ax, cy, i * 3.5 * s, -math.pi / 2.8, math.pi / 2.8)
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

    local cw, ch    = 15, 11
    local pin_len   = 3
    local n_pins    = 3

    function w:fit(_, _, h) return cw + pin_len * 2 + 6, h end

    function w:draw(_, cr, width, height)
        local cx = math.floor(width / 2)
        local cy = math.floor(height / 2)
        local bx = cx - math.floor(cw / 2)
        local by = cy - math.floor(ch / 2)

        -- Pins (left and right sides)
        cr:set_source_rgba(1, 1, 1, 1)
        cr:set_line_width(2)
        local pin_spacing = (ch - 2) / (n_pins - 1)
        for i = 1, n_pins do
            local py = by + 1 + (i - 1) * pin_spacing
            cr:move_to(bx,          py) cr:line_to(bx - pin_len,      py) cr:stroke()
            cr:move_to(bx + cw,     py) cr:line_to(bx + cw + pin_len, py) cr:stroke()
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
    -- Synchronous io.open is intentional: /proc/stat and /proc/meminfo are
    -- kernel virtual files with no disk I/O. Spawning subprocesses would be heavier.
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

local bar_margin     = 3
local capsule_height = 24
local wibar_height   = bar_margin * 2 + capsule_height  -- equal top + bottom padding

--- Build a single tag button: circle + dots drawn via Cairo below.
local function make_tag_widget(t)
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

    function dots:draw(_, cr, w, h)
        if self.n == 0 then return end
        local show  = math.min(self.n, 3)
        local r     = 2.5
        local gap   = 3
        local pad   = 2
        local total = show * (r * 2) + (show - 1) * gap
        local cap_w = total + pad * 2
        local cap_x = (w - cap_w) / 2

        -- Capsule background: match button opacity (selected = opaque, else semi-transparent)
        cr:set_source_rgba(0, 0, 0, self.selected and 1 or 0.5)
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

    -- Label
    local label = wibox.widget.textbox(t.name)
    label.align  = "center"
    label.valign = "center"
    label.font   = "monospace bold 12"

    -- 2px right margin shifts place_c's perceived center 1px left, correcting font offset
    local place_c = wibox.container.place()
    place_c.halign = "center"
    place_c.valign = "center"
    place_c:set_widget(wibox.container.margin(label, 0, 2, 0, 0))

    local circle = wibox.container.background()
    circle.forced_width  = capsule_height
    circle.forced_height = capsule_height
    circle.shape         = gears.shape.circle
    circle.bg            = "#00000080"
    circle:set_widget(place_c)

    local function update_circle()
        circle.bg     = t.selected and "#000000" or "#00000080"
        dots.selected = t.selected
        dots:emit_signal("widget::redraw_needed")
    end

    -- Circle pinned to top; dots (self-drawing capsule) pushed to the very bottom
    local tag_layout = wibox.layout.stack()
    tag_layout:add(wibox.container.margin(circle, 0, 0, bar_margin, bar_margin))
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

    s.mypromptbox = awful.widget.prompt()

    -- Build taglist manually so we have direct widget references (no
    -- get_children_by_id indirection that proved unreliable).
    local taglist_layout = wibox.layout.fixed.horizontal()
    taglist_layout.spacing = 4
    for _, t in ipairs(s.tags) do
        taglist_layout:add(make_tag_widget(t))
    end
    s.mytaglist = taglist_layout

    local dow_codes = { "Su", "Mo", "Tu", "We", "Th", "Fr", "Sa" }
    local mon_codes = { "Ja", "Fe", "Mr", "Ap", "My", "Jn", "Jl", "Au", "Se", "Oc", "Nv", "De" }

    local mydate = wibox.widget.textbox()
    mydate.font = "monospace 12"
    local function update_date()
        local t = os.date("*t")
        mydate.text = dow_codes[t.wday] .. " " .. mon_codes[t.month]
                      .. " " .. string.format("%02d", t.day)
                      .. " " .. string.format("%02d", t.year % 100)
    end
    update_date()
    gears.timer { timeout = 60, autostart = true, call_now = false, callback = update_date }

    local myclock = wibox.widget.textclock("%I:%M %p")
    myclock.font = "monospace bold 12"

    local bat_widget = make_battery_widget()
    table.insert(battery_widgets, bat_widget)

    local vol_widget = make_volume_widget()
    table.insert(volume_widgets, vol_widget)

    local chip_widget = make_chip_widget()
    table.insert(chip_widgets, chip_widget)

    -- Capsule helper: wraps widget(s) in a black pill-shaped background
    local function capsule(inner, pad_l, pad_r)
        local bg = wibox.container.background()
        bg.bg    = "#000000"
        bg.shape = function(cr, w, h)
            gears.shape.partially_rounded_rect(cr, w, h, true, true, false, false, capsule_height / 2)
        end
        bg:set_widget(wibox.container.margin(inner, pad_l or 10, pad_r or 10, 0, 0))
        return wibox.container.margin(bg, 0, 0, bar_margin, 0)
    end

    -- Status icons capsule (chip + battery + volume)
    local icons_row = wibox.layout.fixed.horizontal()
    icons_row.spacing = 4
    icons_row:add(chip_widget)
    icons_row:add(bat_widget)
    icons_row:add(wibox.container.margin(vol_widget, 0, 0, 0, 1))
    local status_capsule = capsule(icons_row, 8, 8)

    -- Date / clock capsule
    local dt_row = wibox.layout.fixed.horizontal()
    dt_row.spacing = 8
    dt_row:add(mydate)
    dt_row:add(myclock)
    local dt_capsule = capsule(dt_row, 12, 12)

    local sg = beautiful.splitwm_gap or 16
    s.mywibox = wibox({
        x       = s.geometry.x + sg,
        y       = s.geometry.y + s.geometry.height - wibar_height,
        width   = s.geometry.width - sg * 2,
        height  = wibar_height,
        bg      = "#00000000",
        ontop   = true,
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
            wibox.container.margin(dt_capsule, 0, bar_margin, 0, 0),
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
