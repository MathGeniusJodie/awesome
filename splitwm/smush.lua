---------------------------------------------------------------------------
-- splitwm.smush — automatic font shrinking for narrow splits.
--
-- Sends Ctrl+0 plus one or two Ctrl+- presses (via the splitwm/smushkeys
-- helper binary) to the focused split's active client when its width
-- crosses the configured thresholds. The helper types into the focused
-- window, so only the focused client is ever adjusted — other splits catch
-- up when they receive focus.
---------------------------------------------------------------------------

local awful = require("awful")
local gears = require("gears")
local core  = require("splitwm.core")
local theme = require("splitwm.theme")

local smush = {}

local HELPER = gears.filesystem.get_configuration_dir() .. "splitwm/smushkeys"

-- [client] = { mode = "wide"|"narrow"|"tiny", key = "leafid:bucket" }
local applied = setmetatable({}, { __mode = "k" })

local function helper_command(mode)
    if mode == "reset" then return { HELPER, "reset" } end
    if mode == "tiny" then return { HELPER, "tiny" } end
    return HELPER
end

local function smush_focused(t)
    local state = core.tag_state[t]
    if not state then return end
    local leaf = core.focused_leaf(state)
    if not leaf or leaf.active_tab <= 0 then return end
    local cached = core.geo[t]
    local geo = cached and cached.geos[leaf.id]
    if not geo then return end

    local c = leaf.tabs[leaf.active_tab]
    if not c or not c.valid or c.hidden or c.minimized or c.fullscreen then
        return
    end
    -- The helper synthesizes keys into the focused window.
    if client.focus ~= c then return end

    local mode, key
    if geo.width >= theme.smush_threshold() then
        if not applied[c] or applied[c].mode == "wide" then return end
        mode, key = "wide", nil
    else
        mode = geo.width < theme.tiny_smush_threshold() and "tiny" or "narrow"
        -- Bucket widths so small resizes within ~25px don't re-trigger.
        key = ("%d:%d"):format(leaf.id, math.floor(geo.width / 25))
        if applied[c] and applied[c].mode == mode and applied[c].key == key then
            return
        end
    end
    applied[c] = { mode = mode, key = key }
    awful.spawn(helper_command(mode == "wide" and "reset" or mode))
end

-- Re-evaluate smushing for the focused split after a layout change.
-- (The leaf_id argument from callers is accepted but unused: only the
-- focused client can be smushed.)
function smush.after_layout(s)
    s = core.screen_of(s)
    local t = s and s.selected_tag
    if not t or not gears.filesystem.file_executable(HELPER) then return end
    -- Small delay so any pending focus change from the same operation lands.
    gears.timer.start_new(0.05, function()
        smush_focused(t)
        return false
    end)
end

return smush
