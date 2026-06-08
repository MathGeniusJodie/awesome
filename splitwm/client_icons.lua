local menubar_utils = require("menubar.utils")

local M = {}

local class_icon_cache = {}

local ICON_SIZES = { "256x256", "scalable", "128x128", "96x96", "64x64", "48x48", "32x32" }
local ICON_EXTS  = { "png", "svg", "xpm" }

function M.find_icon_file(icon_name)
    if not icon_name or icon_name == "" then return nil end
    if icon_name:sub(1, 1) == "/" then
        local f = io.open(icon_name, "r"); if f then f:close(); return icon_name end
    end
    local home = os.getenv("HOME")
    local bases = {}
    if home then bases[#bases+1] = home .. "/.local/share/icons/hicolor" end
    for _, b in ipairs({ "/usr/local/share/icons/hicolor", "/usr/share/icons/hicolor" }) do
        bases[#bases+1] = b
    end
    for _, base in ipairs(bases) do
        for _, size in ipairs(ICON_SIZES) do
            for _, ext in ipairs(ICON_EXTS) do
                local p = base .. "/" .. size .. "/apps/" .. icon_name .. "." .. ext
                local fh = io.open(p, "r"); if fh then fh:close(); return p end
            end
        end
    end
    for _, ext in ipairs(ICON_EXTS) do
        local p = "/usr/share/pixmaps/" .. icon_name .. "." .. ext
        local fh = io.open(p, "r"); if fh then fh:close(); return p end
    end
    return nil
end

local function class_icon_key(c)
    return (c.class or "") .. "\0" .. (c.instance or "")
end

local function resolve_class_icon(c)
    local candidates = {
        c.instance, c.class,
        c.instance and c.instance:lower(), c.class and c.class:lower(),
    }
    for _, name in ipairs(candidates) do
        if name then
            local path = menubar_utils.lookup_icon(name)
            if path and path ~= false then return path end
        end
    end
end

function M.prepare_client_icon(c)
    local key = class_icon_key(c)
    if class_icon_cache[key] == nil then
        class_icon_cache[key] = resolve_class_icon(c) or false
    end
    return class_icon_cache[key] or nil
end

function M.lookup_class_icon(c)
    return class_icon_cache[class_icon_key(c)] or nil
end

return M
