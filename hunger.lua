local awful     = require("awful")
local gears     = require("gears")
local wibox     = require("wibox")
local beautiful = require("beautiful")

local hunger = {}

local config_dir = gears.filesystem.get_configuration_dir()
local STATE_FILE = config_dir .. "hunger_state"
local NUM_APPLES = 10
local ICON_SIZE  = 18

---------------------------------------------------------------------------
-- Tweakable meal schedule
---------------------------------------------------------------------------

local FEED_WINDOW_START = 7   -- hour of first meal (wake time)
local FEED_WINDOW_END   = 21  -- hour of last meal  (9 pm)
local NUM_MEALS         = 5

-- Apple images: 0=full, 1=slightly eaten, 2=more eaten, 3=core
local APPLE_IMGS = {}
for i = 0, 3 do
    APPLE_IMGS[i] = config_dir .. "applew" .. i .. "-fs8.png"
end
local HUNGER_BTN_ICON = config_dir .. "hunger-fs8.png"

---------------------------------------------------------------------------
-- Meal time helpers (all times are seconds since midnight)
---------------------------------------------------------------------------

local MEAL_TIMES = (function()
    local t     = {}
    local start = FEED_WINDOW_START * 3600
    local stop  = FEED_WINDOW_END   * 3600
    for i = 1, NUM_MEALS do
        t[i] = start + (i - 1) * (stop - start) / (NUM_MEALS - 1)
    end
    return t
end)()

local DAY_END_S = 24 * 3600  -- midnight caps the last slot

local function now_s()
    local t = os.date("*t")
    return t.hour * 3600 + t.min * 60 + t.sec
end

-- Returns slot_start, slot_end (seconds from midnight) for the current time,
-- or nil if we are before the first meal of the day.
local function current_slot()
    local n = now_s()
    if n < MEAL_TIMES[1] then return nil end
    for i = 1, NUM_MEALS do
        local s = MEAL_TIMES[i]
        local e = (i < NUM_MEALS) and MEAL_TIMES[i + 1] or DAY_END_S
        if n >= s and n < e then return s, e end
    end
    return nil
end

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
    return 0  -- epoch → treated as "never fed today"
end

local function save_last_feed(ts)
    local f = io.open(STATE_FILE, "w")
    if f then f:write(tostring(ts)); f:close() end
end

hunger._last_feed = load_last_feed()

---------------------------------------------------------------------------
-- Level calculation
---------------------------------------------------------------------------

local function get_level()
    local slot_start, slot_end = current_slot()
    if not slot_start then return 0 end  -- before first meal

    -- Was the button pressed during the current slot today?
    local feed_today = os.date("%Y%j", hunger._last_feed)
    local today      = os.date("%Y%j")
    local lt         = os.date("*t", hunger._last_feed)
    local feed_s     = lt.hour * 3600 + lt.min * 60 + lt.sec

    if feed_today ~= today or feed_s < slot_start or feed_s >= slot_end then
        return 0  -- haven't eaten in this slot
    end

    -- Deplete linearly from full → 0 as we approach the next meal time
    local frac = math.max(0, (slot_end - now_s()) / (slot_end - slot_start))
    return frac * NUM_APPLES
end

---------------------------------------------------------------------------
-- Widget instances (all screens share one feed time, update together)
---------------------------------------------------------------------------

local _update_fns = {}

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
    btn_height = (btn_height or 24) + 6

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
        btn_bg.bg = (get_level() <= 0) and beautiful.splitwm_accent or beautiful.splitwm_btn_bg
        btn_bg:emit_signal("widget::redraw_needed")
    end

    local function update_all()
        update_apples()
        update_btn()
    end

    local function on_feed()
        hunger._last_feed = os.time()
        save_last_feed(hunger._last_feed)
        for _, fn in ipairs(_update_fns) do fn() end
    end

    btn_bg:buttons(gears.table.join(awful.button({}, 1, on_feed)))

    table.insert(_update_fns, update_all)
    update_all()

    return {
        button = (function()
            local p = wibox.container.place(btn_bg)
            p.valign = "bottom"
            return p
        end)(),
        apples = (function()
            local p = wibox.container.place(apple_row)
            p.valign = "bottom"
            return p
        end)(),
    }
end

return hunger
