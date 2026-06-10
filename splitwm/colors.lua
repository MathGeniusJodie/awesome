local colors = {}

local COLORS = {
    { name = "pink",    light = "#eda2b9", dark = "#9e5a70" },
    { name = "orange",  light = "#efa78e", dark = "#9f5e47" },
    { name = "gold",    light = "#dbb575", dark = "#8e6b2b" },
    { name = "green",   light = "#b3c480", dark = "#6b7a38" },
    { name = "emerald", light = "#85cea7", dark = "#39825f" },
    { name = "cyan",    light = "#6ccdd3", dark = "#078287" },
    { name = "blue",    light = "#83c3f1", dark = "#3879a2" },
    { name = "violet",  light = "#afb5f6", dark = "#676ba7" },
    { name = "purple",  light = "#d6a8e0", dark = "#8a6093" },
}

---------------------------------------------------------------------------
-- Color-space utilities
---------------------------------------------------------------------------

local function vec3(x, y, z)
    return { x, y, z }
end

local function cbrt(v)
    return v < 0 and -((-v) ^ (1 / 3)) or v ^ (1 / 3)
end

local function clamp01(v)
    return math.max(0, math.min(1, v))
end

local function srgb_to_linear_channel(v)
    return v <= 0.04045 and v / 12.92
        or ((v + 0.055) / 1.055) ^ 2.4
end

local function linear_to_srgb_channel(v)
    return v <= 0.0031308 and v * 12.92
        or 1.055 * (v ^ (1 / 2.4)) - 0.055
end

function colors.srgb_to_linear_srgb(c)
    return vec3(
        srgb_to_linear_channel(c[1]),
        srgb_to_linear_channel(c[2]),
        srgb_to_linear_channel(c[3])
    )
end

function colors.linear_srgb_to_srgb(c)
    return vec3(
        linear_to_srgb_channel(c[1]),
        linear_to_srgb_channel(c[2]),
        linear_to_srgb_channel(c[3])
    )
end

function colors.linear_srgb_to_oklab(c)
    local r, g, b = cbrt(c[1]), cbrt(c[2]), cbrt(c[3])
    return vec3(
        0.254564575 * r + 0.651941557 * g + 0.093493860 * b,
        0.340534798 * r - 0.465335923 * g + 0.124801124 * b,
        0.105142214 * r + 0.318906366 * g - 0.424048543 * b
    )
end

function colors.oklab_to_linear_srgb(c)
    local l, a, b = c[1], c[2], c[3]
    local r = l + 1.944265062 * a + 0.792693030 * b
    local g = l - 0.747676717 * a + 0.000431480481 * b
    local bl = l - 0.0802137488 * a - 2.161349025 * b
    return vec3(r * r * r, g * g * g, bl * bl * bl)
end

function colors.srgb_to_oklab(c)
    return colors.linear_srgb_to_oklab(colors.srgb_to_linear_srgb(c))
end

function colors.oklab_to_srgb(c)
    return colors.linear_srgb_to_srgb(colors.oklab_to_linear_srgb(c))
end

function colors.hex_to_srgb(hex)
    local r, g, b = (hex or ""):match("^#?(%x%x)(%x%x)(%x%x)")
    if not r then return nil end
    return vec3(tonumber(r, 16) / 255, tonumber(g, 16) / 255, tonumber(b, 16) / 255)
end

function colors.srgb_to_hex(c)
    local r = math.floor(clamp01(c[1]) * 255 + 0.5)
    local g = math.floor(clamp01(c[2]) * 255 + 0.5)
    local b = math.floor(clamp01(c[3]) * 255 + 0.5)
    return string.format("#%02x%02x%02x", r, g, b)
end

function colors.hex_to_oklab(hex)
    local srgb = colors.hex_to_srgb(hex)
    return srgb and colors.srgb_to_oklab(srgb) or nil
end

function colors.oklab_to_hex(c)
    return colors.srgb_to_hex(colors.oklab_to_srgb(c))
end

local function load_icon_surface(icon, size)
    local ok_client_icons, client_icons = pcall(require, "splitwm.client_icons")
    return ok_client_icons and client_icons.icon_surface(icon, size) or nil
end

local function surface_size(surface)
    local ok_width, width = pcall(function()
        return surface:get_width()
    end)
    local ok_height, height = pcall(function()
        return surface:get_height()
    end)

    if not ok_width or not ok_height or not width or not height then
        return nil, nil
    end

    return width, height
end

local function render_icon_to_argb32_data(icon, max_size)
    local source = load_icon_surface(icon, max_size)
    if not source then
        return nil, nil, nil, nil
    end

    local source_width, source_height = surface_size(source)
    if not source_width or source_width <= 0 or source_height <= 0 then
        return nil, nil, nil, nil
    end

    local ok_lgi, lgi = pcall(require, "lgi")
    if not ok_lgi then
        return nil, nil, nil, nil
    end

    local ok_bytes, bytes = pcall(require, "bytes")
    if not ok_bytes then
        return nil, nil, nil, nil
    end

    local cairo = lgi.cairo
    local scale = 1
    if max_size and max_size > 0 then
        scale = math.min(1, max_size / math.max(source_width, source_height))
    end

    local width = math.max(1, math.floor(source_width * scale + 0.5))
    local height = math.max(1, math.floor(source_height * scale + 0.5))
    local ok_stride, stride = pcall(cairo.Format.stride_for_width, cairo.Format.ARGB32, width)
    stride = ok_stride and stride and stride > 0 and stride or width * 4
    stride = math.floor(stride + 0.5)

    local data = bytes.new(stride * height)
    local surface = cairo.ImageSurface.create_for_data(data, cairo.Format.ARGB32, width, height, stride)
    local cr = cairo.Context(surface)

    cr:scale(width / source_width, height / source_height)
    local ok_source = pcall(function()
        cr:set_source_surface(source, 0, 0)
    end)
    if not ok_source then
        return nil, nil, nil, nil, nil
    end
    cr:paint()
    surface:flush()

    return data, stride, width, height, surface
end

function colors.average_icon_color(icon, opts)
    opts = opts or {}

    local data, stride, width, height = render_icon_to_argb32_data(icon, opts.max_size or 64)
    if not data then
        return nil
    end

    local alpha_threshold = opts.alpha_threshold or 0
    local sum_r, sum_g, sum_b, sum_weight = 0, 0, 0, 0

    -- Cairo ARGB32 is native endian; on Linux/x86 pixels are stored B, G, R, A.
    for y = 0, height - 1 do
        local row = y * stride
        for x = 0, width - 1 do
            local offset = row + x * 4
            local b = data[offset + 1] / 255
            local g = data[offset + 2] / 255
            local r = data[offset + 3] / 255
            local a = data[offset + 4] / 255

            if a > alpha_threshold then
                local inv_alpha = 1 / a
                local srgb_r = clamp01(r * inv_alpha)
                local srgb_g = clamp01(g * inv_alpha)
                local srgb_b = clamp01(b * inv_alpha)

                sum_r = sum_r + srgb_to_linear_channel(srgb_r) * a
                sum_g = sum_g + srgb_to_linear_channel(srgb_g) * a
                sum_b = sum_b + srgb_to_linear_channel(srgb_b) * a
                sum_weight = sum_weight + a
            end
        end
    end

    if sum_weight <= 0 then
        return nil
    end

    local linear_srgb = vec3(sum_r / sum_weight, sum_g / sum_weight, sum_b / sum_weight)
    local srgb = colors.linear_srgb_to_srgb(linear_srgb)

    return {
        linear_srgb = linear_srgb,
        srgb = srgb,
        hex = colors.srgb_to_hex(srgb),
        alpha = sum_weight / (width * height),
        width = width,
        height = height,
    }
end

colors.average_app_icon_color = colors.average_icon_color

local TAU = math.pi * 2
local HUE_SLOT_DEGREES = 40
local ICON_HUE_CHROMA_THRESHOLD = 0.015
local color_templates

local function atan2(y, x)
    return math.atan2 and math.atan2(y, x) or math.atan(y, x)
end

local function oklab_chroma(c)
    return math.sqrt(c[2] * c[2] + c[3] * c[3])
end

local function oklab_hue(c)
    local chroma = oklab_chroma(c)
    if chroma < ICON_HUE_CHROMA_THRESHOLD then return nil end
    local hue = atan2(c[3], c[2])
    return hue < 0 and hue + TAU or hue
end

local function rotate_hue(hue, radians)
    return (hue + radians) % TAU
end

local function hue_distance(a, b)
    local d = math.abs(a - b) % TAU
    return math.min(d, TAU - d)
end

local function oklab_with_hue(template, hue)
    local chroma = oklab_chroma(template)
    return vec3(
        template[1],
        math.cos(hue) * chroma,
        math.sin(hue) * chroma
    )
end

local function get_color_templates()
    if color_templates then return color_templates end

    color_templates = {}
    for _, col in ipairs(COLORS) do
        local light = colors.hex_to_oklab(col.light)
        local dark = colors.hex_to_oklab(col.dark)
        local hue = light and oklab_hue(light)
        if light and dark and hue then
            color_templates[#color_templates + 1] = {
                name = col.name,
                hue = hue,
                light = light,
                dark = dark,
            }
        end
    end

    return color_templates
end

local function template_for_hue(hue)
    local best, best_dist
    for _, template in ipairs(get_color_templates()) do
        local dist = hue_distance(hue, template.hue)
        if not best_dist or dist < best_dist then
            best = template
            best_dist = dist
        end
    end
    return best
end

local function slot_offset_degrees(slot)
    return slot * HUE_SLOT_DEGREES
end

local function average_with_hue(icon)
    local avg = colors.average_icon_color(icon, { max_size = 48 })
    if not avg then return nil, nil end
    return avg, oklab_hue(colors.linear_srgb_to_oklab(avg.linear_srgb))
end

local function client_app_key(c)
    local ok_client_icons, client_icons = pcall(require, "splitwm.client_icons")
    if ok_client_icons then
        local key = client_icons.app_key(c)
        if key then return key end
    end
end

local function fallback_color_for_client(c)
    local key = client_app_key(c) or "client"
    local hash = 0
    for i = 1, #key do
        hash = (hash * 33 + key:byte(i)) % 2147483647
    end
    return COLORS[(hash % #COLORS) + 1]
end

local app_hue_slots = {}
local client_hue_slots = setmetatable({}, { __mode = "k" })

local function release_hue_slot(c)
    local existing = client_hue_slots[c]
    if not existing then return end

    local group = app_hue_slots[existing.key]
    if group and group.used[existing.slot] == c then
        group.used[existing.slot] = nil
        if not next(group.used) then
            app_hue_slots[existing.key] = nil
        end
    end

    client_hue_slots[c] = nil
end

local function hue_slot_for_client(c)
    local existing = client_hue_slots[c]
    if existing then return existing end

    local key = client_app_key(c)
    if not key then return nil end

    local group = app_hue_slots[key]
    if not group then
        group = { used = {} }
        app_hue_slots[key] = group
    end

    local slot = 0
    while group.used[slot] do
        slot = slot + 1
    end

    local degrees = slot_offset_degrees(slot)
    local allocation = {
        key = key,
        slot = slot,
        degrees = degrees,
        radians = math.rad(degrees),
    }
    group.used[slot] = c
    client_hue_slots[c] = allocation
    return allocation
end

local function hue_for_template_name(name)
    for _, tpl in ipairs(get_color_templates()) do
        if tpl.name == name then return tpl.hue end
    end
end

-- Build a full tab color (light/dark pair) for an effective hue by rotating
-- the nearest palette template in oklab space. Single source of truth for
-- icon-derived, slot-offset, fallback, and manual colors alike.
local function color_from_hue(hue)
    local template = template_for_hue(hue)
    if not template then return nil end
    local light = colors.oklab_to_hex(oklab_with_hue(template.light, hue))
    local dark  = colors.oklab_to_hex(oklab_with_hue(template.dark, hue))
    return {
        name  = "hue:" .. light .. ":" .. dark,
        light = light,
        dark  = dark,
        base  = template.name,
        hue   = hue,
    }
end

-- Manually chosen colors are stored as a hue OFFSET (degrees) from the
-- client's base hue, so the tab color and the icon rotate together.
local function manual_hue_offset(c)
    return tonumber(c:get_xproperty("splitwm_manual_hue_offset"))
end

-- Lua-side cache to avoid repeated X11 xproperty reads and icon averaging.
-- Weak keys so entries are evicted automatically when clients are GC'd.
-- Boxes ({value}) distinguish "not cached" (nil) from "cached nil" ({nil}).
local color_cache = setmetatable({}, { __mode = "k" })
local icon_surface_cache = setmetatable({}, { __mode = "k" })

function colors.clear_client_color_cache(c, opts)
    color_cache[c] = nil
    icon_surface_cache[c] = nil
    if opts and opts.release_hue_slot then
        release_hue_slot(c)
    end
end

function colors.release_client(c)
    color_cache[c] = nil
    icon_surface_cache[c] = nil
    release_hue_slot(c)
end

local function byte(v)
    return math.floor(clamp01(v) * 255 + 0.5)
end

local function hue_rotate_argb32_data(data, stride, width, height, radians)
    if not radians or math.abs(radians) < 0.000001 then return end

    for y = 0, height - 1 do
        local row = y * stride
        for x = 0, width - 1 do
            local offset = row + x * 4
            local b = data[offset + 1] / 255
            local g = data[offset + 2] / 255
            local r = data[offset + 3] / 255
            local a = data[offset + 4] / 255

            if a > 0 then
                local inv_alpha = 1 / a
                local srgb = vec3(
                    clamp01(r * inv_alpha),
                    clamp01(g * inv_alpha),
                    clamp01(b * inv_alpha)
                )
                local lab = colors.srgb_to_oklab(srgb)
                local chroma = oklab_chroma(lab)

                if chroma >= ICON_HUE_CHROMA_THRESHOLD then
                    local hue = rotate_hue(atan2(lab[3], lab[2]), radians)
                    srgb = colors.oklab_to_srgb(vec3(
                        lab[1],
                        math.cos(hue) * chroma,
                        math.sin(hue) * chroma
                    ))

                    data[offset + 1] = byte(srgb[3] * a)
                    data[offset + 2] = byte(srgb[2] * a)
                    data[offset + 3] = byte(srgb[1] * a)
                    data[offset + 4] = byte(a)
                end
            end
        end
    end
end

-- Icon surface rotated by the client's color rotation, so the icon always
-- lands on the tab's effective hue. nil when no rotation applies.
function colors.hue_rotated_icon_surface(c, size)
    local col = colors.get_client_color(c)
    local rot = col and col.icon_rotation or 0
    if math.abs(rot) < 0.001 then return nil end

    local cache = icon_surface_cache[c]
    if cache and cache.size == size and cache.rot == rot then
        return cache.surface
    end

    local data, stride, width, height, surface = render_icon_to_argb32_data(c, size)
    if not surface then return nil end

    hue_rotate_argb32_data(data, stride, width, height, rot)
    surface:mark_dirty()

    icon_surface_cache[c] = {
        size = size,
        rot = rot,
        surface = surface,
        data = data,
    }
    return surface
end

-- Effective hue = base hue + offset:
--   base hue   — the icon's average hue, else the hash-fallback palette hue
--   offset     — the manual offset if set, else the per-app dedup slot
-- The icon is rotated by the same offset so it matches the tab color.
function colors.get_client_color(c)
    if not c.valid then return nil end
    local box = color_cache[c]
    if box ~= nil then return box[1] end

    local result
    local avg, icon_hue = average_with_hue(c)
    local manual_deg = manual_hue_offset(c)

    local base_hue = icon_hue
    if not base_hue then
        base_hue = hue_for_template_name(fallback_color_for_client(c).name)
    end

    if base_hue then
        local offset = 0
        if manual_deg then
            offset = math.rad(manual_deg)
        elseif avg then
            local slot = hue_slot_for_client(c)
            offset = slot and slot.radians or 0
        end
        result = color_from_hue(rotate_hue(base_hue, offset))
        if result then
            result.base_hue      = base_hue
            result.offset        = offset
            result.manual        = manual_deg ~= nil
            result.from_icon     = manual_deg == nil and avg ~= nil
            result.icon_rotation = avg and offset or 0
            if avg then result.icon_hex = avg.hex end
        end
    end
    result = result or fallback_color_for_client(c)
    color_cache[c] = { result }
    return result
end

-- Apply a manual hue offset (degrees) from the client's base hue.
function colors.set_client_hue_offset(c, degrees)
    if not c.valid then return end
    c:set_xproperty("splitwm_manual_hue_offset",
        string.format("%.2f", degrees % 360))
    colors.clear_client_color_cache(c)
end

-- Preview color this client would get at a given offset (picker swatches).
function colors.client_color_for_offset(c, degrees)
    local cur = colors.get_client_color(c)
    if not cur or not cur.base_hue then return cur end
    return color_from_hue(rotate_hue(cur.base_hue, math.rad(degrees)))
end

local function pick_color_for_leaf(leaf, exclude_c)
    local used = {}
    for _, tc in ipairs(leaf.tabs) do
        if tc ~= exclude_c and tc.valid then
            local col = colors.get_client_color(tc)
            if col then used[col.base or col.name] = true end
        end
    end
    for _, col in ipairs(COLORS) do
        if not used[col.name] then return col end
    end
    return COLORS[1]
end

local function assign_color(leaf, c)
    local picked = pick_color_for_leaf(leaf, c)
    local hue = hue_for_template_name(picked.name)
    local result = hue and color_from_hue(hue) or picked
    if result ~= picked then result.base_hue = hue end
    color_cache[c] = { result }
end

function colors.resolve_color_conflict(leaf, c)
    if not c.valid then return end
    local existing = colors.get_client_color(c)
    if not existing then assign_color(leaf, c); return end
    if existing.from_icon or existing.manual then return end
    for _, tc in ipairs(leaf.tabs) do
        if tc ~= c and tc.valid then
            local col = colors.get_client_color(tc)
            if col and (col.base or col.name) == (existing.base or existing.name) then
                assign_color(leaf, c)
                return
            end
        end
    end
end

---------------------------------------------------------------------------
-- Window-content sampling: average color of the top strip of a client's
-- rendered window, so the active tab can blend into the app.
---------------------------------------------------------------------------

local window_top_cache = setmetatable({}, { __mode = "k" })

local WINDOW_TOP_TTL_US      = 1000000  -- resample at most once per second
local WINDOW_TOP_FAST_TTL_US = 150000   -- retry fast until a color is known
local WINDOW_TOP_SAMPLE_Y    = 0        -- the very top row of the window

-- Without a compositor, X stores no content for obscured windows: sampling
-- a covered or freshly-unhidden window reads black garbage. Only the
-- focused (raised) client is sampled, and only once it has had time to
-- repaint after gaining focus.
local FOCUS_SETTLE_US = 300000

local focus_since = setmetatable({}, { __mode = "k" })
local ok_glib, GLib = pcall(function() return require("lgi").GLib end)
if ok_glib then
    client.connect_signal("focus", function(c)
        focus_since[c] = GLib.get_monotonic_time()
    end)
end

-- Color (hex) of one pixel at the top-center of c's rendered content, or
-- nil if the content is unavailable (hidden/unmapped clients have none).
function colors.window_top_color(c)
    if not c.valid or c.hidden then return nil end
    local cache = window_top_cache[c]
    local now = ok_glib and GLib.get_monotonic_time() or os.time() * 1e6
    local ttl = (cache and cache.hex) and WINDOW_TOP_TTL_US
        or WINDOW_TOP_FAST_TTL_US
    if cache and now - cache.t <= ttl then return cache.hex end

    -- Sample only the settled, focused client (see FOCUS_SETTLE_US).
    local fs = focus_since[c]
    if not ok_glib or client.focus ~= c or not fs
            or GLib.get_monotonic_time() - fs < FOCUS_SETTLE_US then
        return cache and cache.hex or nil
    end

    local hex
    local ok_lgi, lgi = pcall(require, "lgi")
    local ok_bytes, bytes = pcall(require, "bytes")
    local ok_gsurf, gsurface = pcall(require, "gears.surface")
    local ok_content, content = pcall(function() return gsurface(c.content) end)
    if ok_lgi and ok_bytes and ok_gsurf and ok_content and content then
        local cairo = lgi.cairo
        local sx = math.floor(c:geometry().width / 2)
        local data = bytes.new(4)
        local buf = cairo.ImageSurface.create_for_data(data,
            cairo.Format.ARGB32, 1, 1, 4)
        local cr = cairo.Context(buf)
        if pcall(function()
            cr:set_source_surface(content, -sx, -WINDOW_TOP_SAMPLE_Y)
            cr:paint()
        end) then
            buf:flush()
            -- Pixels are B, G, R, A on little-endian.
            hex = string.format("#%02x%02x%02x", data[3], data[2], data[1])
        end
    end
    -- Sampling fails transiently around visibility changes (the window may
    -- not be rendered yet right after a tab switch). Never let a failed
    -- sample clobber the last good color — return it and retry next call.
    if not hex and cache then return cache.hex end
    window_top_cache[c] = { hex = hex, t = now }
    return hex
end

-- Last sampled top color without refreshing. Unfocused tabs use this so
-- they keep the color their window had when it was last visible.
function colors.window_top_color_cached(c)
    local cache = window_top_cache[c]
    return cache and cache.hex or nil
end

colors.COLORS = COLORS

-- Degrees per picker swatch / per-app dedup slot.
colors.HUE_STEP_DEGREES = HUE_SLOT_DEGREES

return colors
