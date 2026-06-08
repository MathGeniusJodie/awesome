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

local COLORS_BY_NAME = {}
for _, entry in ipairs(COLORS) do COLORS_BY_NAME[entry.name] = entry end

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

-- Preferred color per application class (case-insensitive).
local CLASS_COLORS = {
    ["discord"]              = "violet",
    ["obsidian"]             = "purple",
    ["mpv"]                  = "purple",
    ["claude"]               = "orange",
    ["librewolf"]            = "cyan",
    ["code"]                 = "blue",  -- VSCode
    ["code-oss"]             = "blue",
    ["yt-gtk"]               = "pink",
}

local function get_preferred_color(c)
    if not c.valid or not c.class then return nil end
    local name = CLASS_COLORS[c.class:lower()]
    return name and COLORS_BY_NAME[name]
end

-- Lua-side cache to avoid repeated X11 xproperty reads.
-- Weak keys so entries are evicted automatically when clients are GC'd.
-- Boxes ({value}) distinguish "not cached" (nil) from "cached nil" ({nil}).
local color_cache = setmetatable({}, { __mode = "k" })

function colors.get_client_color(c)
    if not c.valid then return nil end
    local box = color_cache[c]
    if box ~= nil then return box[1] end
    local name = c:get_xproperty("splitwm_color")
    local result = name and COLORS_BY_NAME[name]
    color_cache[c] = { result }
    return result
end

local function set_client_color(c, name)
    if not c.valid then return end
    c:set_xproperty("splitwm_color", name)
    color_cache[c] = { COLORS_BY_NAME[name] }
end

local function pick_color_for_leaf(leaf, exclude_c)
    local used = {}
    for _, tc in ipairs(leaf.tabs) do
        if tc ~= exclude_c and tc.valid then
            local col = colors.get_client_color(tc)
            if col then used[col.name] = true end
        end
    end
    -- Honour the app's preferred color if it isn't already taken.
    local preferred = exclude_c and get_preferred_color(exclude_c)
    if preferred and not used[preferred.name] then return preferred end
    for _, col in ipairs(COLORS) do
        if not used[col.name] then return col end
    end
    return COLORS[1]
end

local function assign_color(leaf, c)
    set_client_color(c, pick_color_for_leaf(leaf, c).name)
end

-- After a tab is removed, let remaining tabs reclaim their preferred color
-- if it's no longer taken by anyone else in the leaf.
function colors.recheck_preferred(leaf, exclude_c)
    for _, tc in ipairs(leaf.tabs) do
        if tc == exclude_c or not tc.valid then goto continue end
        local preferred = get_preferred_color(tc)
        if not preferred then goto continue end
        local conflict = false
        for _, other in ipairs(leaf.tabs) do
            if other ~= tc and other ~= exclude_c and other.valid then
                local col = colors.get_client_color(other)
                if col and col.name == preferred.name then
                    conflict = true; break
                end
            end
        end
        if not conflict then
            set_client_color(tc, preferred.name)
        end
        ::continue::
    end
end

function colors.resolve_color_conflict(leaf, c)
    if not c.valid then return end
    local existing = colors.get_client_color(c)
    if not existing then assign_color(leaf, c); return end
    for _, tc in ipairs(leaf.tabs) do
        if tc ~= c and tc.valid then
            local col = colors.get_client_color(tc)
            if col and col.name == existing.name then
                assign_color(leaf, c)
                return
            end
        end
    end
end

colors.COLORS          = COLORS
colors.set_client_color = set_client_color

return colors
