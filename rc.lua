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
beautiful.splitwm_gap              = 40 -- minimum 32
beautiful.splitwm_focus_border_width = 2
beautiful.splitwm_border_radius    = 2
beautiful.splitwm_empty_radius     = 14
beautiful.splitwm_btn_font         = "monospace bold 14px"
beautiful.splitwm_smush_width_threshold = 1200
beautiful.splitwm_tiny_smush_width_threshold = 600

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
local menu        = require("menu")
local status      = require("status")
local timebar     = require("timebar")
local hunger_mod  = require("hunger")

---------------------------------------------------------------------------
-- Variables
---------------------------------------------------------------------------

local terminal = os.getenv("TERMINAL") or "xterm"
local modkey   = "Mod4"
local _home    = os.getenv("HOME")

local WALLPAPER = {
    dark   = beautiful.splitwm_color_bg,
    bg     = _home .. "/background0.jpg",
    has_bg = gears.filesystem.file_readable(_home .. "/background0.jpg"),
}

-- Browser detection: try common browsers
local browser = os.getenv("BROWSER") or "xdg-open https://"
local filemanager = os.getenv("FILEMANAGER") or "thunar"

local DPI_STEP = 12
local DPI_MIN  = 72
local DPI_MAX  = 240

local function change_dpi(delta)
    local script = string.format([[
use_xfce=0
current=
if command -v xfconf-query >/dev/null 2>&1; then
    use_xfce=1
    current=$(xfconf-query -c xsettings -p /Xft/DPI 2>/dev/null)
    if [ -n "$current" ] && [ "$current" -gt 1000 ] 2>/dev/null; then
        current=$((current / 1024))
    fi
fi
if ! [ "$current" -gt 0 ] 2>/dev/null; then
    current=$(xrdb -query 2>/dev/null | awk '/^Xft\.dpi:/ { print int($2); exit }')
fi
if ! [ "$current" -gt 0 ] 2>/dev/null; then
    current=96
fi

dpi=$((current + (%d)))
if [ "$dpi" -lt %d ]; then dpi=%d; fi
if [ "$dpi" -gt %d ]; then dpi=%d; fi

if [ "$use_xfce" -eq 1 ]; then
    if xfconf-query -c xsettings -p /Xft/DPI >/dev/null 2>&1; then
        xfconf-query -c xsettings -p /Xft/DPI -s "$dpi"
    else
        xfconf-query -c xsettings -p /Xft/DPI -n -t int -s "$dpi"
    fi
    xrdb -query 2>/dev/null | awk '$1 != "Xft.dpi:" { print }' | xrdb -load 2>/dev/null || true
else
    printf 'Xft.dpi: %%s\n' "$dpi" | xrdb -merge
fi

printf '%%s' "$dpi"
]], delta, DPI_MIN, DPI_MIN, DPI_MAX, DPI_MAX)

    awful.spawn.easy_async_with_shell(script, function(stdout)
        local dpi = stdout:match("(%d+)")
        if dpi then
            naughty.notify {
                title = "DPI",
                text  = dpi,
            }
        end
    end)
end

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
        label          = "T",
        icon           = "/home/jodie/.local/share/applications/templates-briefcase.svg",
        cmd            = "thunar /home/jodie/Desktop/allfiles/templates",
    },
    {
        label          = "O",
        icon_names     = {"obsidian", "md.obsidian.Obsidian"},
        cmd            = "obsidian",
        hide_if_class  = {"obsidian", "Obsidian"},
    },
    {
        label          = "AI",
        icon_names     = {"claude-desktop"},
        cmd            = "claude-desktop",
        hide_if_class  = {"claude-desktop", "Claude"},
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

tag.connect_signal("request::default_layouts", function()
    awful.layout.append_default_layouts({
        splitwm.layout,
        awful.layout.suit.floating,  -- fallback
    })
end)

---------------------------------------------------------------------------
-- Wibar
---------------------------------------------------------------------------

-- Font and color overrides (must be before wibar creation)
beautiful.font           = "monospace bold 12px"
beautiful.fg_normal      = "#ffffff"
beautiful.fg_focus       = "#ffffff"

status.setup({
    splitwm     = splitwm,
    hunger_mod  = hunger_mod,
    do_scroll   = function(s, delta_x, instant)
        splitwm.scroll_delta(s, delta_x, instant)
    end,
})

awful.screen.connect_for_each_screen(function(s)
    awful.tag({ "main" }, s, splitwm.layout)
    splitwm.set_wallpaper(s, WALLPAPER)

    timebar.setup(s)
    status.setup_screen(s)
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

    awful.key({ modkey }, "minus", function() change_dpi(-DPI_STEP) end,
        { description = "lower dpi", group = "display" }),

    awful.key({ modkey }, "equal", function() change_dpi(DPI_STEP) end,
        { description = "raise dpi", group = "display" }),

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

    awful.key({ modkey }, "Left", splitwm.focus_prev_split,
        { description = "focus previous split", group = "splitwm" }),

    awful.key({ modkey }, "Right", splitwm.focus_next_split,
        { description = "focus next split", group = "splitwm" }),

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
