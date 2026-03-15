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

-- Lua-side cache to avoid repeated X11 xproperty reads.
-- Weak keys so entries are evicted automatically when clients are GC'd.
local color_cache  = setmetatable({}, { __mode = "k" })
local NO_COLOR     = {}  -- sentinel: client has no color set

function colors.get_client_color(c)
    if not c.valid then return nil end
    local cached = color_cache[c]
    if cached == NO_COLOR then return nil end
    if cached then return cached end
    local name = c:get_xproperty("splitwm_color")
    local result = name and COLORS_BY_NAME[name]
    color_cache[c] = result or NO_COLOR
    return result
end

local function set_client_color(c, name)
    if not c.valid then return end
    c:set_xproperty("splitwm_color", name)
    color_cache[c] = COLORS_BY_NAME[name] or NO_COLOR
end

local function pick_color_for_leaf(leaf, exclude_c)
    local used = {}
    for _, tc in ipairs(leaf.tabs) do
        if tc ~= exclude_c and tc.valid then
            local col = colors.get_client_color(tc)
            if col then used[col.name] = true end
        end
    end
    for _, col in ipairs(COLORS) do
        if not used[col.name] then return col end
    end
    return COLORS[1]
end

local function assign_color(leaf, c)
    set_client_color(c, pick_color_for_leaf(leaf, c).name)
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

return colors
