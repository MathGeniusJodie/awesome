local awful     = require("awful")
local gears     = require("gears")
local wibox     = require("wibox")
local beautiful = require("beautiful")
local icons     = require("splitwm.icons")

local status = {}

local _home = os.getenv("HOME")

local battery_widgets = {}
local volume_widgets  = {}
local chip_widgets    = {}

-- Forward declarations so widget factories can trigger an immediate refresh on creation.
local refresh_battery
local refresh_volume_internal
local refresh_chip

---------------------------------------------------------------------------
-- Widget factories
---------------------------------------------------------------------------

function status.new_battery_widget()
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
        local by = height - bh - 1
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

    table.insert(battery_widgets, w)
    gears.timer.delayed_call(function() refresh_battery() end)
    return w
end

function status.new_volume_widget()
    local w = wibox.widget.base.make_widget()
    w.volume = 0
    w.muted  = false

    function w:fit(_, _, h)
        return math.ceil(26 * h / 32), h
    end

    function w:draw(_, cr, width, height)
        local s  = height / 32.0
        local r2 = math.sqrt(2) * s
        local cx = width / 2

        cr:set_source_rgba(1, 1, 1, 1)
        icons.speaker(cr, width, height)

        -- wave/mute origin: rotated position of the speaker cone tip (11s, cy_orig)
        local ax = cx - r2
        local ay = height - 7*r2
        cr:set_line_width(1.5 * s)

        if self.muted then
            cr:set_line_width(2.5 * s)
            cr:set_line_cap(1)  -- ROUND
            -- mute X rotated -45° becomes a horizontal + vertical line pair
            cr:move_to(cx - r2,      height - 21*r2/2) cr:line_to(cx + 6*r2,   height - 21*r2/2) cr:stroke()
            cr:move_to(cx + 5*r2/2,  height - 14*r2)   cr:line_to(cx + 5*r2/2, height - 7*r2)   cr:stroke()
        else
            local waves = self.volume > 60 and 3
                       or self.volume > 25 and 2
                       or self.volume >  0 and 1
                       or 0
            for i = 1, waves do
                -- arc angles rotated -45° from the original rightward fan
                cr:arc(ax, ay, i * 3.5 * s, -math.pi / 2.8 - math.pi / 4, math.pi / 2.8 - math.pi / 4)
                cr:stroke()
            end
        end
    end

    table.insert(volume_widgets, w)
    gears.timer.delayed_call(function() refresh_volume_internal() end)
    return w
end

function status.new_chip_widget()
    local w = wibox.widget.base.make_widget()
    w.cpu  = 0
    w.ram  = 0
    w.swap = 0

    local cw, ch    = 15, 11
    local pin_len   = 3

    function w:fit(_, _, h) return cw + pin_len * 2 + 6, h end

    function w:draw(_, cr, width, height)
        local cx = math.floor(width / 2)
        local by = height - ch
        local bx = cx - math.floor(cw / 2)
        local cy = by + math.floor(ch / 2)

        cr:set_source_rgba(1, 1, 1, 1)
        cr:save()
        icons.chip(cr, width, height)

        -- 3 vertical gauges inside body, 1px gap between them
        -- Inner area matches battery fill inset: 2px from each edge
        local pad = 3
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
        cr:restore()
    end

    table.insert(chip_widgets, w)
    gears.timer.delayed_call(function() refresh_chip() end)
    return w
end

local function make_circle_icon_btn_widget(size, icon_fn, cmd)
    local icon = wibox.widget.base.make_widget()
    icon.forced_width  = math.floor(size * 0.54)
    icon.forced_height = math.floor(size * 0.54)

    function icon:fit(_, w, h) return self.forced_width, self.forced_height end

    function icon:draw(_, cr, w, h)
        cr:set_source(gears.color(beautiful.splitwm_color_fg))
        icon_fn(cr, w, h)
    end

    local bg = wibox.container.background()
    bg.bg           = beautiful.splitwm_btn_bg
    bg.shape        = gears.shape.circle
    bg.forced_width  = size
    bg.forced_height = size
    bg:set_widget(wibox.container.margin(wibox.container.place(icon), 0, 0, 0, 2))

    bg:buttons(gears.table.join(awful.button({}, 1, cmd)))

    return bg
end

function status.new_lock_widget(size)
    return make_circle_icon_btn_widget(size, icons.lock,
        function() awful.spawn(_home .. "/.local/bin/xflock4") end)
end

---------------------------------------------------------------------------
-- Refresh functions
---------------------------------------------------------------------------

-- Cached battery path: found once, reused on every refresh tick.
local _battery_path = nil
local function find_battery_path()
    if _battery_path then return _battery_path end
    local base = "/sys/class/power_supply/"
    -- Fast path: try common names without spawning a subprocess.
    for _, name in ipairs({ "BAT0", "BAT1", "BAT", "BATT" }) do
        local f = io.open(base .. name .. "/capacity", "r")
        if f then f:close(); _battery_path = base .. name; return _battery_path end
    end
    -- Fallback: enumerate the directory (one-time subprocess, result is cached).
    local ls = io.popen("ls /sys/class/power_supply/ 2>/dev/null")
    if ls then
        for name in ls:lines() do
            local f = io.open(base .. name .. "/capacity", "r")
            if f then f:close(); ls:close(); _battery_path = base .. name; return _battery_path end
        end
        ls:close()
    end
    return nil
end

-- Synchronous io.open is intentional: sysfs files are kernel virtual
-- files with no disk I/O. Spawning a subprocess would be heavier.
refresh_battery = function()
    local path = find_battery_path()
    if not path then return end
    local fc = io.open(path .. "/capacity", "r")
    if not fc then _battery_path = nil; return end  -- battery disappeared; reset cache
    local cap = tonumber(fc:read("*l")); fc:close()
    if not cap then return end
    local fs = io.open(path .. "/status", "r")
    local stat = fs and fs:read("*l") or ""
    if fs then fs:close() end
    for _, w in ipairs(battery_widgets) do
        w.percentage = cap
        w.charging   = (stat == "Charging")
        w:emit_signal("widget::redraw_needed")
    end
end

refresh_volume_internal = function()
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

function status.refresh_volume()
    refresh_volume_internal()
end

local _cpu_prev_idle, _cpu_prev_total = 0, 0

refresh_chip = function()
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

---------------------------------------------------------------------------
-- Composite widget factories
---------------------------------------------------------------------------

local CAL_CELL = 24
local CAL_GAP  = 2
local CAL_PAD  = 10

-- Returns widget, cal_w, cal_h so the caller can size the wibox precisely.
local function build_calendar_widget(year, month, today_day, on_prev, on_next)
    local month_names = {
        "January","February","March","April","May","June",
        "July","August","September","October","November","December"
    }
    local cell = CAL_CELL
    local gap  = CAL_GAP
    local pad  = CAL_PAD

    local first_wday    = os.date("*t", os.time({year=year, month=month, day=1})).wday - 1
    local days_in_month = os.date("*t", os.time({year=year, month=month+1, day=0})).day

    -- Always 6 week rows so the popup height never jumps between months.
    local MAX_WEEKS = 6

    -- Exact pixel height:
    -- rows: margin(hdr)+gap + dow_row + (1+MAX_WEEKS)*gap + MAX_WEEKS*cell
    -- margin(hdr) height = 4 + cell + 4 = cell+8
    local rows_h = (cell + 8) + cell + MAX_WEEKS * cell + (1 + MAX_WEEKS) * gap
    local cal_w  = 7 * cell + 6 * gap + 2 * pad
    local cal_h  = pad + rows_h + pad

    -- Last day of previous month (for overflow cells)
    local prev_y, prev_m = year, month - 1
    if prev_m < 1 then prev_m = 12; prev_y = prev_y - 1 end
    local prev_days = os.date("*t", os.time({year=prev_y, month=prev_m+1, day=0})).day

    -- Blend a color with alpha (#rrggbbaa) onto a background (#rrggbb[aa])
    -- so the result is safe to use in Pango markup (which needs plain #rrggbb).
    local function blend(fg_c, bg_c)
        local r, g, b, a = (fg_c or ""):match("^#(%x%x)(%x%x)(%x%x)(%x%x)$")
        if not r then
            r, g, b = (fg_c or ""):match("^#(%x%x)(%x%x)(%x%x)$")
            return r and ("#" .. r .. g .. b) or "#ffffff"
        end
        local alpha = tonumber(a, 16) / 255
        if alpha >= 1.0 then return "#" .. r .. g .. b end
        local br, bg2, bb = (bg_c or "#000000"):match("^#(%x%x)(%x%x)(%x%x)")
        br, bg2, bb = tonumber(br, 16) or 0, tonumber(bg2, 16) or 0, tonumber(bb, 16) or 0
        local ri = math.floor(br + (tonumber(r, 16) - br) * alpha + 0.5)
        local gi = math.floor(bg2 + (tonumber(g, 16) - bg2) * alpha + 0.5)
        local bi = math.floor(bb + (tonumber(b, 16) - bb) * alpha + 0.5)
        return string.format("#%02x%02x%02x", ri, gi, bi)
    end

    local raw_bg       = beautiful.splitwm_color_bg
    local color_bg     = blend(raw_bg,                            "#000000")
    local color_fg     = blend(beautiful.splitwm_color_fg,        raw_bg)
    local color_muted  = blend(beautiful.splitwm_fg_disabled,     raw_bg)
    local color_dow    = blend(beautiful.splitwm_handle_color,    raw_bg)
    local color_today  = blend(beautiful.splitwm_accent,          raw_bg)

    local rows = wibox.layout.fixed.vertical()
    rows.spacing = gap

    -- Nav header: ‹  Month Year  ›
    local function nav_btn(sym, cb)
        local btn = wibox.widget {
            markup        = string.format('<span color="%s">%s</span>', color_dow, sym),
            align         = "center",
            font          = "monospace bold 14px",
            forced_width  = cell,
            forced_height = cell,
            widget        = wibox.widget.textbox,
        }
        btn:buttons(gears.table.join(awful.button({}, 1, cb)))
        return btn
    end

    local hdr_row = wibox.widget {
        nav_btn("‹", on_prev),
        wibox.widget {
            markup        = string.format('<span color="%s"><b>%s %d</b></span>', color_fg, month_names[month], year),
            align         = "center",
            font          = "monospace bold 13px",
            forced_height = cell,
            widget        = wibox.widget.textbox,
        },
        nav_btn("›", on_next),
        layout = wibox.layout.align.horizontal,
    }
    rows:add(wibox.container.margin(hdr_row, 0, 0, 4, 4))

    -- Day-of-week labels
    local dow_row = wibox.layout.fixed.horizontal()
    dow_row.spacing = gap
    for _, d in ipairs({"Su","Mo","Tu","We","Th","Fr","Sa"}) do
        dow_row:add(wibox.widget {
            markup        = string.format('<span color="%s"><b>%s</b></span>', color_fg, d),
            align         = "center",
            font          = "monospace 12px",
            forced_width  = cell,
            forced_height = cell,
            widget        = wibox.widget.textbox,
        })
    end
    rows:add(dow_row)

    -- Helper: a muted overflow cell
    local function overflow_cell(day_num)
        return wibox.widget {
            wibox.container.place(wibox.widget {
                markup = string.format('<span color="%s">%d</span>', color_muted, day_num),
                align  = "center",
                font   = "monospace 13px",
                widget = wibox.widget.textbox,
            }),
            forced_width  = cell,
            forced_height = cell,
            widget        = wibox.container.background,
        }
    end

    -- Collect week rows into a table so we can prepend a top-overflow row.
    local week_row_widgets = {}
    local col     = first_wday
    local cur_row = wibox.layout.fixed.horizontal()
    cur_row.spacing = gap

    -- Leading overflow days from previous month
    for i = first_wday - 1, 0, -1 do
        cur_row:add(overflow_cell(prev_days - i))
    end

    -- Current month days
    for day = 1, days_in_month do
        local is_today = (day == today_day)
        local label = wibox.widget {
            markup = is_today
                and string.format('<span color="%s"><b>%d</b></span>', color_bg, day)
                or  string.format('<span color="%s">%d</span>', color_fg, day),
            align  = "center",
            font   = "monospace 11px",
            widget = wibox.widget.textbox,
        }
        local cell_w = wibox.widget {
            wibox.container.place(label),
            bg            = is_today and color_today or nil,
            shape         = is_today and gears.shape.circle or nil,
            forced_width  = cell,
            forced_height = cell,
            widget        = wibox.container.background,
        }
        cur_row:add(cell_w)
        col = col + 1
        if col >= 7 then
            table.insert(week_row_widgets, cur_row)
            cur_row         = wibox.layout.fixed.horizontal()
            cur_row.spacing = gap
            col = 0
        end
    end

    -- Complete the last partial row with next-month overflow
    local next_day = 1
    if col > 0 then
        while col < 7 do
            cur_row:add(overflow_cell(next_day))
            next_day = next_day + 1
            col      = col + 1
        end
        table.insert(week_row_widgets, cur_row)
    end

    local week_rows = #week_row_widgets  -- 4, 5, or 6

    -- Extra overflow rows at the bottom.
    -- For 4-week months we only add one here (the other goes at the top below).
    local bottom_target = (week_rows == 4) and (MAX_WEEKS - 1) or MAX_WEEKS
    for _ = week_rows + 1, bottom_target do
        local extra = wibox.layout.fixed.horizontal()
        extra.spacing = gap
        for _ = 1, 7 do
            extra:add(overflow_cell(next_day))
            next_day = next_day + 1
        end
        table.insert(week_row_widgets, extra)
    end

    -- For 4-week months: prepend one extra overflow row at the top.
    -- It shows the 7 prev-month days immediately before the leading overflow cells.
    if week_rows == 4 then
        local top_row = wibox.layout.fixed.horizontal()
        top_row.spacing = gap
        for i = 6, 0, -1 do
            top_row:add(overflow_cell(prev_days - first_wday - i))
        end
        table.insert(week_row_widgets, 1, top_row)
    end

    for _, row in ipairs(week_row_widgets) do
        rows:add(row)
    end

    return wibox.container.margin(rows, pad, pad, pad, pad), cal_w, cal_h
end

function status.new_datetime_widget()
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

    local dt_row = wibox.layout.fixed.horizontal()
    dt_row.spacing = 8
    dt_row:add(mydate)
    dt_row:add(myclock)

    -- Calendar popup state
    local cal_popup   = nil
    local cal_visible = false

    -- Poll timer: closes calendar when a click lands outside it.
    -- poll_ready stays false until all buttons are released after opening,
    -- so the opening click itself doesn't immediately re-close it.
    local poll_ready = false
    local cal_poll_timer = gears.timer {
        timeout   = 0.05,
        autostart = false,
        callback  = function()
            if not (cal_popup and cal_popup.visible) then
                poll_ready = false
                return
            end
            local m       = mouse.coords()
            local pressed = (m.buttons[1] or m.buttons[3]) and true or false
            if not poll_ready then
                if not pressed then poll_ready = true end
                return
            end
            if pressed then
                local g = cal_popup:geometry()
                if m.x < g.x or m.x > g.x + g.width
                or m.y < g.y or m.y > g.y + g.height then
                    cal_popup.visible = false
                    cal_visible       = false
                    poll_ready        = false
                    cal_poll_timer:stop()
                end
            end
        end,
    }

    local function hide_calendar()
        if cal_popup then cal_popup.visible = false end
        cal_visible = false
        poll_ready  = false
        cal_poll_timer:stop()
    end

    local function show_calendar()
        local t           = os.date("*t")
        local scr         = awful.screen.focused()
        local today_year  = t.year
        local today_month = t.month
        local today_day   = t.day

        if cal_popup then cal_popup.visible = false end

        local disp_year  = today_year
        local disp_month = today_month

        local do_refresh  -- forward declaration

        local function on_prev()
            disp_month = disp_month - 1
            if disp_month < 1 then disp_month = 12; disp_year = disp_year - 1 end
            do_refresh()
        end
        local function on_next()
            disp_month = disp_month + 1
            if disp_month > 12 then disp_month = 1; disp_year = disp_year + 1 end
            do_refresh()
        end
        local function cur_today()
            return (disp_year == today_year and disp_month == today_month) and today_day or nil
        end

        local widget, cal_w, cal_h = build_calendar_widget(
            disp_year, disp_month, cur_today(), on_prev, on_next)
        local sg      = scr.geometry
        local wibar_h = 30

        local cal_x = sg.x + sg.width - beautiful.splitwm_gap - 16 - cal_w
        cal_popup = wibox({
            x            = cal_x,
            y            = sg.y + sg.height - wibar_h - cal_h,
            width        = cal_w,
            height       = cal_h,
            bg           = beautiful.splitwm_color_bg or "#000000",
            border_width = 0,
            ontop        = true,
            visible      = true,
            type         = "popup_menu",
        })
        cal_popup.shape  = function(cr, w, h) gears.shape.rounded_rect(cr, w, h, 6) end
        cal_popup.widget = widget
        cal_visible      = true

        poll_ready = false
        if cal_poll_timer.started then cal_poll_timer:stop() end
        cal_poll_timer:start()

        do_refresh = function()
            local w, cw, ch = build_calendar_widget(
                disp_year, disp_month, cur_today(), on_prev, on_next)
            local s = scr.geometry
            cal_popup.x      = s.x + s.width - beautiful.splitwm_gap - 16 - cw
            cal_popup.y      = s.y + s.height - wibar_h - ch
            cal_popup.width  = cw
            cal_popup.height = ch
            cal_popup.widget = w
        end
    end

    -- Wrap dt_row to make it clickable
    local clickable = wibox.widget {
        dt_row,
        widget = wibox.container.background,
    }
    clickable:buttons(gears.table.join(
        awful.button({}, 1, function()
            if cal_visible then
                hide_calendar()
            else
                show_calendar()
            end
        end)
    ))

    return clickable
end

-- Builds the combined status+clock capsule (chip | battery | volume | date | clock).
-- bar_margin and capsule_height control the outer margin/shape; icon_bottom_pad shifts
-- icons up to align with the clock baseline; tab_shape is the pill shape function.
function status.new_status_clock_capsule(bar_margin, capsule_height, icon_bottom_pad, tab_shape)
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

    local chip_widget = status.new_chip_widget()
    local bat_widget  = status.new_battery_widget()
    local vol_widget  = status.new_volume_widget()

    local icons_row = wibox.layout.fixed.horizontal()
    icons_row.spacing = 4
    icons_row:add(wibox.container.margin(chip_widget, 0, 0, 0, icon_bottom_pad))
    icons_row:add(wibox.container.margin(bat_widget,  0, 0, 0, icon_bottom_pad))
    icons_row:add(wibox.container.margin(vol_widget,  0, 0, 0, icon_bottom_pad))

    local combined_row = wibox.layout.fixed.horizontal()
    combined_row.spacing = 16
    combined_row:add(icons_row)
    combined_row:add(status.new_datetime_widget())

    return capsule(combined_row, 24, 26, tab_shape, "#000000ff")
end

---------------------------------------------------------------------------
-- Timers (start immediately on require)
---------------------------------------------------------------------------

local _timers = {
    gears.timer { timeout = 30, autostart = true, call_now = true, callback = refresh_battery },
    gears.timer { timeout = 2,  autostart = true, call_now = true, callback = refresh_volume_internal },
    gears.timer { timeout = 2,  autostart = true, call_now = true, callback = refresh_chip },
}

return status
