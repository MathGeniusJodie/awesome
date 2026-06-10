---------------------------------------------------------------------------
-- splitwm.focus — focus engine.
--
-- AwesomeWM focus is asynchronous and other events (map, unmap, smush
-- keystrokes) can steal it, so explicit focus requests are guarded for a
-- short window and re-asserted a couple of times.
---------------------------------------------------------------------------

local gears = require("gears")
local core  = require("splitwm.core")

local focus = {}

-- Active guard: { client, leaf_id } while a recent explicit request should win.
focus.guard = nil

local request_seq = 0

local function set_guard(c, timeout, leaf_id)
    if not c or not c.valid then return end
    local guard = { client = c, leaf_id = leaf_id }
    focus.guard = guard
    gears.timer.start_new(timeout or 0.35, function()
        if focus.guard == guard then focus.guard = nil end
        return false
    end)
end

function focus.force_now(c, leaf_id)
    if not c or not c.valid then return end
    set_guard(c, nil, leaf_id)
    if core.smush.running then
        -- Defer: the smush queue restores focus when it drains.
        core.smush.restore_client  = c
        core.smush.restore_leaf_id = leaf_id
        return
    end
    client.focus = c
    c:raise()
end

-- Focus a client after the next arrange settles, re-asserting shortly after
-- in case a newly mapped window or the WM steals focus back.
function focus.after_arrange(c, leaf_id)
    if not c or not c.valid then return end
    request_seq = request_seq + 1
    local seq = request_seq
    set_guard(c, nil, leaf_id)
    local function reassert()
        if seq == request_seq and c.valid and client.focus ~= c then
            focus.force_now(c, leaf_id)
        end
        return false
    end
    gears.timer.delayed_call(function()
        if seq ~= request_seq then return end
        focus.force_now(c, leaf_id)
        gears.timer.start_new(0.05, reassert)
        gears.timer.start_new(0.16, reassert)
    end)
end

-- Focus the active tab of a leaf after arrange.
function focus.leaf_after_arrange(state, leaf_id)
    local leaf = core.leaf(state, leaf_id)
    local c = leaf and leaf.tabs[leaf.active_tab]
    if c and c.valid then focus.after_arrange(c, leaf_id) end
end

return focus
