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
beautiful.splitwm_gap        = 24
beautiful.splitwm_focus_bg   = "#000000aa"
beautiful.splitwm_empty_bg   = "#000000aa"
beautiful.splitwm_focus_border = "#7799dd"
beautiful.splitwm_empty_border = "#555555"
beautiful.splitwm_tab_active_bg = "#535d6c"
beautiful.splitwm_tab_active_fg = "#ffffff"
beautiful.splitwm_tab_bg     = "#333333"
beautiful.splitwm_tab_fg     = "#888888"
beautiful.splitwm_handle_hover_bg = "#7799dd22"
beautiful.splitwm_handle_drag_bg  = "#7799dd44"
beautiful.splitwm_launcher_bg       = "#3a3a3a"
beautiful.splitwm_launcher_hover_bg  = "#555555"
beautiful.splitwm_focus_border_width = 2
beautiful.splitwm_font           = "monospace 12"
beautiful.splitwm_btn_font       = "monospace bold 14"
beautiful.titlebar_bg_normal     = "#000000aa"
beautiful.titlebar_bg_focus      = "#000000"

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

    -- Replace the placeholder menu
    app_menu = awful.menu {
        items = menu_items,
        theme = { width = 200, height = 24 },
    }

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
                      "chromium", "google-chrome", "brave-browser", "librewolf"},
        cmd        = browser,
    },
    {
        label      = "F",
        icon       = "/usr/share/icons/Adwaita/scalable/places/folder.svg",
        cmd        = filemanager,
    },
    {
        label      = "M",
        icon_name  = "application-menu",
        icon_names = {"org.xfce.panel.whiskermenu", "app-launcher", "application-menu",
                      "start-here", "start-here-symbolic",
                      "view-app-grid-symbolic", "apps", "system-run"},
        action    = function()
            app_menu:toggle()
        end,
    },
}

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
beautiful.taglist_font   = "monospace bold 12"
beautiful.fg_normal      = "#ffffff"
beautiful.fg_focus       = "#ffffff"
beautiful.taglist_fg_focus    = "#ffffff"
beautiful.taglist_fg_occupied = "#ffffff"
beautiful.taglist_fg_empty    = "#888888"
beautiful.taglist_fg_urgent   = "#ff6666"

awful.screen.connect_for_each_screen(function(s)
    awful.tag({ "1", "2", "3", "4", "5" }, s, splitwm.layout)

    s.mypromptbox = awful.widget.prompt()
    s.mytaglist   = awful.widget.taglist {
        screen  = s,
        filter  = awful.widget.taglist.filter.all,
        buttons = gears.table.join(
            awful.button({}, 1, function(t) t:view_only() end)
        ),
    }

    local myclock = wibox.widget.textclock(" %I:%M %p ")
    myclock.font = "monospace bold 12"

    s.mywibox = awful.wibar {
        position = "top",
        screen   = s,
        height   = 30,
        bg       = "#000000aa",
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
        { description = "view next", group = "tag" })
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
