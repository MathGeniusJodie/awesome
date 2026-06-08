local menubar_utils = require("menubar.utils")

local M = {}

local class_icon_cache = {}
local configured_launchers = {}

local ICON_SIZES = { "256x256", "128x128", "96x96", "64x64", "48x48", "32x32" }
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
    for _, base in ipairs(bases) do
        for _, ext in ipairs(ICON_EXTS) do
            local p = base .. "/scalable/apps/" .. icon_name .. "." .. ext
            local fh = io.open(p, "r"); if fh then fh:close(); return p end
        end
    end
    return nil
end

local function class_icon_key(c)
    return (c.class or "") .. "\0" .. (c.instance or "")
end

local function xdg_application_dirs()
    local dirs = {}
    local home = os.getenv("HOME")
    if home then dirs[#dirs + 1] = home .. "/.local/share/applications" end

    local data_dirs = os.getenv("XDG_DATA_DIRS") or "/usr/local/share:/usr/share"
    for dir in data_dirs:gmatch("[^:]+") do
        dirs[#dirs + 1] = dir .. "/applications"
    end
    return dirs
end

local function shell_quote(s)
    return "'" .. s:gsub("'", "'\\''") .. "'"
end

local function desktop_files()
    local dirs = {}
    for _, dir in ipairs(xdg_application_dirs()) do
        dirs[#dirs + 1] = shell_quote(dir)
    end
    if #dirs == 0 then return {} end

    local pipe = io.popen("find " .. table.concat(dirs, " ")
        .. " -maxdepth 2 -type f -name '*.desktop' 2>/dev/null")
    if not pipe then return {} end

    local files = {}
    for path in pipe:lines() do
        files[#files + 1] = path
    end
    pipe:close()
    return files
end

local function parse_desktop_icon_entry(path)
    local fh = io.open(path, "r")
    if not fh then return nil end

    local in_entry = false
    local entry = { file = path }
    for line in fh:lines() do
        if line == "[Desktop Entry]" then
            in_entry = true
        elseif in_entry and line:match("^%[") then
            break
        elseif in_entry then
            local key, value = line:match("^([%w%-]+)%s*=%s*(.+)$")
            if key == "Icon" or key == "StartupWMClass" or key == "Name" then
                entry[key] = value
            end
        end
    end
    fh:close()

    if not entry.Icon then return nil end
    entry.file_name = path:match("([^/]+)%.desktop$")
    return entry
end

local desktop_icon_cache

local function add_desktop_icon(cache, key, icon)
    if not key or key == "" or not icon or icon == "" then return end
    key = key:lower()
    cache[key] = cache[key] or {}
    cache[key][#cache[key] + 1] = icon

    for token in key:gmatch("[a-z0-9]+") do
        if #token >= 4 and token ~= key then
            cache[token] = cache[token] or {}
            cache[token][#cache[token] + 1] = icon
        end
    end
end

local function desktop_icon_names_by_key()
    if desktop_icon_cache then return desktop_icon_cache end

    desktop_icon_cache = {}
    for _, path in ipairs(desktop_files()) do
        local entry = parse_desktop_icon_entry(path)
        if entry then
            add_desktop_icon(desktop_icon_cache, entry.StartupWMClass, entry.Icon)
            add_desktop_icon(desktop_icon_cache, entry.file_name, entry.Icon)
            add_desktop_icon(desktop_icon_cache, entry.Name, entry.Icon)
        end
    end
    return desktop_icon_cache
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

    local desktop_icons = desktop_icon_names_by_key()
    for _, name in ipairs({ c.instance, c.class, c.instance and c.instance:lower(), c.class and c.class:lower() }) do
        local icons = name and desktop_icons[name:lower()]
        for _, icon in ipairs(icons or {}) do
            add_candidate(candidates, seen, icon)
        end
    end

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
    desktop_icon_cache = nil
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

function M.app_key(c)
    local icon = M.lookup_class_icon(c)
    if icon then return "icon:" .. icon end

    local class = c.class and c.class:lower()
    if class and class ~= "" then return "class:" .. class end

    local instance = c.instance and c.instance:lower()
    if instance and instance ~= "" then return "instance:" .. instance end
end

return M
