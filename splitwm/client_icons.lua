local menubar_utils = require("menubar.utils")

local M = {}

local class_icon_cache = {}
local configured_launchers = {}

local ICON_SIZES = { "256x256", "128x128", "96x96", "64x64", "48x48", "32x32", "scalable" }
local ICON_EXTS  = { "png", "svg", "xpm" }

function M.is_symbolic_icon(path)
    return path and (path:match("/symbolic/") or path:match("%-symbolic%."))
end

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

local function add_candidate(candidates, seen, name)
    if not name or name == "" or seen[name] then return end
    seen[name] = true
    candidates[#candidates + 1] = name
end

local function launcher_matches_client(c, launcher)
    if not launcher.hide_if_class then return false end

    local class = c.class and c.class:lower()
    local instance = c.instance and c.instance:lower()
    for _, name in ipairs(launcher.hide_if_class) do
        local lower = name:lower()
        if lower == class or lower == instance then return true end
    end
    return false
end

local function icon_candidates(c, launchers)
    local candidates, seen = {}, {}

    add_candidate(candidates, seen, c.instance)
    add_candidate(candidates, seen, c.class)
    add_candidate(candidates, seen, c.instance and c.instance:lower())
    add_candidate(candidates, seen, c.class and c.class:lower())

    for _, launcher in ipairs(launchers or {}) do
        if launcher_matches_client(c, launcher) then
            add_candidate(candidates, seen, launcher.icon)
            for _, name in ipairs(launcher.icon_names or {}) do
                add_candidate(candidates, seen, name)
            end
        end
    end

    return candidates
end

local function resolve_class_icon(c, launchers)
    local candidates = icon_candidates(c, launchers)

    local symbolic
    for _, name in ipairs(candidates) do
        if name then
            local path = M.find_icon_file(name)
            if path then
                if not M.is_symbolic_icon(path) then return path end
                symbolic = symbolic or path
            end
        end
    end

    for _, name in ipairs(candidates) do
        if name then
            local path = menubar_utils.lookup_icon(name)
            if path and path ~= false then
                if not M.is_symbolic_icon(path) then return path end
                symbolic = symbolic or path
            end
        end
    end
    return symbolic
end

function M.set_launchers(launchers)
    configured_launchers = launchers or {}
    class_icon_cache = {}
end

function M.prepare_client_icon(c, launchers)
    local key = class_icon_key(c)
    if class_icon_cache[key] == nil then
        class_icon_cache[key] = resolve_class_icon(c, launchers or configured_launchers) or false
    end
    return class_icon_cache[key] or nil
end

function M.lookup_class_icon(c)
    return M.prepare_client_icon(c)
end

return M
