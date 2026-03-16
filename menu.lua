local awful         = require("awful")
local gears         = require("gears")
local menubar_utils = require("menubar.utils")
local menu_gen      = require("menubar.menu_gen")

local menu = {}

function menu.setup(opts)
    local terminal    = opts.terminal
    local browser     = opts.browser
    local filemanager = opts.filemanager
    local splitwm     = opts.splitwm

    local app_menu = awful.menu {
        items = {
            { "Loading apps...", nil },
        },
        theme = { width = 200, height = 24, border_width = 8, bg_normal = "#000000", bg_focus = "#000000", border_color = "#000000" },
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
            if not launcher.icon and launcher.icon_names then
                for _, name in ipairs(launcher.icon_names) do
                    local path = menubar_utils.lookup_icon(name)
                    if path and path ~= false then
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
        local function lookup(names)
            for _, n in ipairs(names) do
                local p = menubar_utils.lookup_icon(n)
                if p and p ~= false then return p end
            end
        end
        local quick_items = {
            { "Terminal",     function() awful.spawn(terminal)    end, launcher_icon(terminal)    },
            { "Browser",      function() awful.spawn(browser)     end, launcher_icon(browser)     },
            { "File Manager", function() awful.spawn(filemanager) end, launcher_icon(filemanager) },
            { "Obsidian",     function() awful.spawn("obsidian")  end, lookup({"obsidian", "md.obsidian.Obsidian"}) },
            { "yt-gtk",       function() awful.spawn("/home/jodie/yt-scrape/target/release/yt-gtk") end, lookup({"video"}) },
            { "Claude",       function() awful.spawn("claude-desktop") end, lookup({"claude-desktop"}) },
            { "─────────────" },
        }
        for i = #quick_items, 1, -1 do
            table.insert(menu_items, 1, quick_items[i])
        end

        -- Replace the placeholder menu
        app_menu = awful.menu {
            items = menu_items,
            theme = { width = 200, height = 24, border_width = 8, menu_bg_normal = "#000000", border_color = "#000000" },
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

    -- Poll: close the menu if the user clicks outside it.
    -- `ready` stays false until all buttons are released after opening, so the
    -- opening click itself doesn't immediately re-close the menu.
    local poll_ready = false
    local menu_poll_timer
    menu_poll_timer = gears.timer {
        timeout   = 0.05,
        autostart = false,
        callback  = function()
            if not (app_menu.wibox and app_menu.wibox.visible) then
                poll_ready = false
                menu_poll_timer:stop()
                return
            end

            local m       = mouse.coords()
            local pressed = (m.buttons[1] or m.buttons[3]) and true or false

            -- Wait for all buttons to be released before arming
            if not poll_ready then
                if not pressed then poll_ready = true end
                return
            end

            if pressed then
                local function inside(m_obj)
                    if not (m_obj and m_obj.wibox and m_obj.wibox.visible) then return false end
                    local g = m_obj.wibox:geometry()
                    if m.x >= g.x and m.x <= g.x + g.width
                       and m.y >= g.y and m.y <= g.y + g.height then return true end
                    return m_obj.active_child and inside(m_obj.active_child) or false
                end
                if not inside(app_menu) then app_menu:hide() end
            end
        end,
    }

    splitwm.on_menu_request = function()
        splitwm._menu_just_toggled = true
        gears.timer.delayed_call(function() splitwm._menu_just_toggled = false end)
        app_menu:toggle()
        poll_ready = false
        if menu_poll_timer.started then menu_poll_timer:stop() end
        menu_poll_timer:start()
    end

    splitwm.on_menu_close = function()
        if app_menu.wibox and app_menu.wibox.visible then
            app_menu:hide()
            pcall(function() mousegrabber.stop() end)
            return true
        end
        return false
    end
end

return menu
