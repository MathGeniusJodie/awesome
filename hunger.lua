local awful     = require("awful")
local gears     = require("gears")
local wibox     = require("wibox")
local beautiful = require("beautiful")

local hunger = {}

local config_dir     = gears.filesystem.get_configuration_dir()
local STATE_FILE     = config_dir .. "hunger_state"
local TOTAL_DURATION = 3 * 60 * 60  -- 3 hours in seconds
local NUM_APPLES     = 10
local ICON_SIZE      = 18

-- Apple images: 0=full, 1=slightly eaten, 2=more eaten, 3=core
local APPLE_IMGS = {}
for i = 0, 3 do
    APPLE_IMGS[i] = config_dir .. "appleb" .. i .. "-fs8.png"
end
local HUNGER_BTN_ICON = config_dir .. "hunger-fs8.png"

---------------------------------------------------------------------------
-- State persistence
---------------------------------------------------------------------------

local function load_last_feed()
    local f = io.open(STATE_FILE, "r")
    if f then
        local ts = tonumber(f:read("*l"))
        f:close()
        if ts then return ts end
    end
    return os.time()
end

local function save_last_feed(ts)
    local f = io.open(STATE_FILE, "w")
    if f then f:write(tostring(ts)); f:close() end
end

-- Module-level: loaded once per awesome session, survives awesome.restart
-- because it reads from disk each time awesome starts.
hunger._last_feed = load_last_feed()

local function get_level()
    local elapsed = os.time() - hunger._last_feed
    local frac    = math.max(0, math.min(1, elapsed / TOTAL_DURATION))
    return (1 - frac) * NUM_APPLES  -- 10.0 = full, 0.0 = empty
end

---------------------------------------------------------------------------
-- Widget instances (all screens share one feed time, update together)
---------------------------------------------------------------------------

local _update_fns = {}

-- Single module-level timer drives all instances
gears.timer {
    timeout   = 30,
    autostart = true,
    call_now  = false,
    callback  = function()
        for _, fn in ipairs(_update_fns) do fn() end
    end,
}

---------------------------------------------------------------------------
-- Widget factory
---------------------------------------------------------------------------

-- btn_height should match capsule_height from rc.lua (typically 24)
function hunger.new_widget(btn_height)
    btn_height = (btn_height or 24) + 4

    -- Apple imagebox row (left=fills last, right=fills first)
    local apple_imgs = {}
    local apple_row  = wibox.layout.fixed.horizontal()
    apple_row.spacing = 2

    for i = 1, NUM_APPLES do
        local img = wibox.widget.imagebox()
        img.forced_width  = ICON_SIZE
        img.forced_height = ICON_SIZE
        img.resize = false
        apple_imgs[i] = img
        apple_row:add(img)
    end

    local function update_apples()
        local level = get_level()
        for i = 1, NUM_APPLES do
            -- fill_i: 1.0 when apple i is fully present, 0.0 when gone
            -- rightmost apple (i=10) depletes first, leftmost (i=1) last
            local fill = math.max(0, math.min(1, level - (i - 1)))
            if fill >= 0.75 then
                apple_imgs[i].image = APPLE_IMGS[0]
            elseif fill >= 0.50 then
                apple_imgs[i].image = APPLE_IMGS[1]
            elseif fill >= 0.25 then
                apple_imgs[i].image = APPLE_IMGS[2]
            elseif fill > 0.00 then
                apple_imgs[i].image = APPLE_IMGS[3]
            else
                apple_imgs[i].image = nil
            end
        end
    end

    -- Circle button with hunger icon
    local hunger_icon = wibox.widget.imagebox(HUNGER_BTN_ICON)
    hunger_icon.forced_width  = ICON_SIZE
    hunger_icon.forced_height = ICON_SIZE
    hunger_icon.resize = false

    local btn_bg = wibox.container.background()
    btn_bg.bg           = beautiful.splitwm_btn_bg
    btn_bg.shape        = gears.shape.circle
    btn_bg.forced_width  = btn_height
    btn_bg.forced_height = btn_height
    btn_bg:set_widget(wibox.container.place(hunger_icon))

    local function update_btn()
        btn_bg.bg = (get_level() <= 0) and beautiful.splitwm_close_fg or beautiful.splitwm_btn_bg
        btn_bg:emit_signal("widget::redraw_needed")
    end

    local function update_all()
        update_apples()
        update_btn()
    end

    local function on_feed()
        hunger._last_feed = os.time()
        save_last_feed(hunger._last_feed)
        -- Refresh every instance (all screens)
        for _, fn in ipairs(_update_fns) do fn() end
    end

    btn_bg:buttons(gears.table.join(awful.button({}, 1, on_feed)))

    table.insert(_update_fns, update_all)
    update_all()

    -- Assemble: [button] [apples]
    local row = wibox.layout.fixed.horizontal()
    row.spacing = 6
    row:add(wibox.container.margin(wibox.container.place(btn_bg), 0, 0, 0, 2))
    row:add(wibox.container.margin(wibox.container.place(apple_row), 0, 0, 0, 1))

    return row
end

return hunger
