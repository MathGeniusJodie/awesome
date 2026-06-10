---------------------------------------------------------------------------
-- splitwm.focus — focus helpers.
--
-- Explicit focus requests are applied after the current event batch so they
-- land after the arrange that triggered them.
---------------------------------------------------------------------------

local gears = require("gears")
local core  = require("splitwm.core")

local focus = {}

function focus.force_now(c)
    if not c or not c.valid then return end
    client.focus = c
    c:raise()
end

-- Focus a client after the next arrange settles.
function focus.after_arrange(c, leaf_id)
    if not c or not c.valid then return end
    gears.timer.delayed_call(function()
        focus.force_now(c, leaf_id)
    end)
end

-- Focus the active tab of a leaf after arrange.
function focus.leaf_after_arrange(state, leaf_id)
    local leaf = core.leaf(state, leaf_id)
    local c = leaf and leaf.tabs[leaf.active_tab]
    if c and c.valid then focus.after_arrange(c, leaf_id) end
end

return focus
