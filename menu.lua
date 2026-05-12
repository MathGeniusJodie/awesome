local awful         = require("awful")
local gears         = require("gears")
local menubar_utils = require("menubar.utils")
local menu_gen      = require("menubar.menu_gen")
local titlebar      = require("splitwm.titlebar")

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

    -- Stored after menu_gen resolves icons; used to rebuild menu on each open
    local category_items = nil
    local bottom_items   = nil
    local launcher_icon_fn  = nil
    local lookup_fn         = nil

    local function is_running(classes)
        for _, c in ipairs(client.get()) do
            if c.class then
                for _, cls in ipairs(classes) do
                    if c.class:lower() == cls:lower() then return true end
                end
            end
        end
        return false
    end

    local function build_menu()
        if not category_items then return end
        local quick_items = {
            { "Terminal",     function() splitwm._append_next_client = true; awful.spawn(terminal)    end, launcher_icon_fn(terminal)    },
            { "Browser",      function() splitwm._append_next_client = true; awful.spawn(browser)     end, launcher_icon_fn(browser)     },
            { "File Manager", function() splitwm._append_next_client = true; awful.spawn(filemanager) end, launcher_icon_fn(filemanager) },
            { "Templates",    function() splitwm._append_next_client = true; awful.spawn("thunar /home/jodie/Desktop/allfiles/templates") end, "/home/jodie/.local/share/applications/templates-briefcase.svg" },
        }
        if not is_running({"obsidian", "Obsidian"}) then
            table.insert(quick_items, { "Obsidian", function() splitwm._append_next_client = true; awful.spawn("obsidian") end, lookup_fn({"obsidian", "md.obsidian.Obsidian"}) })
        end
        if not is_running({"claude-desktop", "Claude"}) then
            table.insert(quick_items, { "Claude", function() splitwm._append_next_client = true; awful.spawn("claude-desktop") end, lookup_fn({"claude-desktop"}) })
        end
        table.insert(quick_items, { "─────────────" })

        local items = {}
        for _, qi in ipairs(quick_items)   do table.insert(items, qi) end
        for _, ci in ipairs(category_items) do table.insert(items, ci) end
        for _, bi in ipairs(bottom_items)   do table.insert(items, bi) end

        app_menu = awful.menu {
            items = items,
            theme = { width = 200, height = 24, border_width = 8, menu_bg_normal = "#000000", border_color = "#000000" },
        }
    end

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
            local cmdline = entry.cmdline
            table.insert(categories[cat], {
                entry.name,
                function() splitwm._append_next_client = true; awful.spawn(cmdline) end,
                entry.icon,
            })
        end
        table.sort(cat_names)

        -- Build category submenus
        category_items = {}
        for _, cat in ipairs(cat_names) do
            table.sort(categories[cat], function(a, b)
                return (a[1] or "") < (b[1] or "")
            end)
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
            table.insert(category_items, { cat, categories[cat], cat_icon })
        end

        bottom_items = {
            { "─────────────" },
            { "Run...", function() awful.screen.focused().mypromptbox:run() end },
        }

        -- Resolve launcher icons now that the icon theme is ready
        for _, launcher in ipairs(splitwm.launchers) do
            if not launcher.icon and launcher.icon_names then
                for _, name in ipairs(launcher.icon_names) do
                    local path = menubar_utils.lookup_icon(name)
                    if path and path ~= false then launcher.icon = path; break end
                end
                if not launcher.icon then
                    for _, name in ipairs(launcher.icon_names) do
                        local path = titlebar.find_icon_file(name)
                        if path then launcher.icon = path; break end
                    end
                end
            end
        end

        launcher_icon_fn = function(cmd)
            for _, l in ipairs(splitwm.launchers) do
                if l.cmd == cmd then return l.icon end
            end
        end
        lookup_fn = function(names)
            for _, n in ipairs(names) do
                local p = menubar_utils.lookup_icon(n)
                if p and p ~= false then return p end
            end
            for _, n in ipairs(names) do
                local p = titlebar.find_icon_file(n)
                if p then return p end
            end
        end

        build_menu()

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
        build_menu()
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
