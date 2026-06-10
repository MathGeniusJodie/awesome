---------------------------------------------------------------------------
-- splitwm.smush — automatic font shrinking for narrow splits.
--
-- Sends Ctrl+0 plus one or two Ctrl+- presses (via the splitwm/smushkeys
-- helper binary) to the active client of a split whenever its width crosses
-- the configured thresholds. Requests are serialized through a queue because
-- the helper types into the *focused* window; focus is restored afterwards.
---------------------------------------------------------------------------

local awful  = require("awful")
local gears  = require("gears")
local core   = require("splitwm.core")
local theme  = require("splitwm.theme")
local tree   = require("splitwm.tree")
local focus  = require("splitwm.focus")

local smush = {}

local HELPER = gears.filesystem.get_configuration_dir() .. "splitwm/smushkeys"

-- [client] = { mode = "wide"|"narrow"|"tiny", key = "leafid:bucket" }
local applied = setmetatable({}, { __mode = "k" })

local queue = {}

local function helper_command(mode)
    if mode == "reset" then return { HELPER, "reset" } end
    if mode == "tiny" then return { HELPER, "tiny" } end
    return HELPER
end

local function restore_focus()
    local restore  = core.smush.restore_client
    local leaf_id  = core.smush.restore_leaf_id
    core.smush.restore_client  = nil
    core.smush.restore_leaf_id = nil
    core.smush.focus_client    = nil
    core.smush.running         = false
    if restore and restore.valid then
        focus.after_arrange(restore, leaf_id)
    end
end

local function process_queue()
    local item = table.remove(queue, 1)
    if not item then
        restore_focus()
        return
    end

    local c = item.client
    if not (c and c.valid) then
        gears.timer.delayed_call(process_queue)
        return
    end

    -- The helper synthesizes key events into the focused window, so focus
    -- the target first and give X a moment to deliver the focus change.
    core.smush.focus_client = c
    client.focus = c
    c:raise()
    gears.timer.start_new(0.035, function()
        local function next_item()
            gears.timer.start_new(0.02, function()
                process_queue()
                return false
            end)
        end
        if c.valid then
            local pid = awful.spawn.easy_async(helper_command(item.mode),
                function() next_item() end)
            if not pid then next_item() end
        else
            next_item()
        end
        return false
    end)
end

local function enqueue(c, mode, restore_client, restore_leaf_id)
    if not c or not c.valid or not gears.filesystem.file_executable(HELPER) then
        return
    end
    if restore_client and restore_client.valid then
        core.smush.restore_client  = restore_client
        core.smush.restore_leaf_id = restore_leaf_id
    end
    table.insert(queue, { client = c, mode = mode })
    if not core.smush.running then
        core.smush.running = true
        gears.timer.delayed_call(process_queue)
    end
end

local function smush_leaf(t, leaf, restore_client, restore_leaf_id)
    if not leaf or leaf.active_tab <= 0 then return end
    local cached = core.geo[t]
    local geo = cached and cached.geos[leaf.id]
    if not geo then return end

    local c = leaf.tabs[leaf.active_tab]
    if not c or not c.valid or c.hidden or c.minimized or c.fullscreen then
        return
    end

    if geo.width >= theme.smush_threshold() then
        if applied[c] and applied[c].mode ~= "wide" then
            applied[c] = { mode = "wide" }
            enqueue(c, "reset", restore_client, restore_leaf_id)
        end
        return
    end

    local mode = geo.width < theme.tiny_smush_threshold() and "tiny" or "narrow"
    -- Bucket widths so small resizes within ~25px don't re-trigger.
    local key = ("%d:%d"):format(leaf.id, math.floor(geo.width / 25))
    if applied[c] and applied[c].mode == mode and applied[c].key == key then
        return
    end
    applied[c] = { mode = mode, key = key }
    enqueue(c, mode, restore_client, restore_leaf_id)
end

-- Re-evaluate smushing after a layout change. With leaf_id only that leaf is
-- checked; otherwise every leaf on the screen's selected tag.
function smush.after_layout(s, leaf_id)
    s = core.screen_of(s)
    local t = s and s.selected_tag
    if not t then return end
    gears.timer.delayed_call(function()
        local state = core.tag_state[t]
        if not state then return end
        local fleaf = core.focused_leaf(state)
        local restore_client  = fleaf and fleaf.tabs[fleaf.active_tab]
        local restore_leaf_id = fleaf and fleaf.id
        if leaf_id then
            smush_leaf(t, core.leaf(state, leaf_id),
                restore_client, restore_leaf_id)
        else
            for _, leaf in ipairs(tree.collect_leaves(state.root)) do
                smush_leaf(t, leaf, restore_client, restore_leaf_id)
            end
        end
    end)
end

return smush
