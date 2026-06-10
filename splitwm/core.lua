---------------------------------------------------------------------------
-- splitwm.core — shared state for all splitwm modules.
--
-- This module holds data only; it never requires another splitwm module,
-- so anything may depend on it without creating cycles.
---------------------------------------------------------------------------

local tree = require("splitwm.tree")

local core = {}

-- Per-tag layout state: root tree, focused leaf, scroll position, canvas width.
core.tag_state = setmetatable({}, { __mode = "k" })

-- Last computed geometry per tag: { geos = {[leaf_id]=rect}, bounds = {...} }.
core.geo = setmetatable({}, { __mode = "k" })

-- Client geometry bookkeeping for size-hint-aware arranging.
core.client_actual_geo  = {}  -- [client] = geometry after size-hint snapping
core.client_last_target = {}  -- [client] = last geometry requested by arrange

-- Tab pickup / pending-drag state shared between titlebar, underlay and ops.
core.PICKUP_IDLE = { tag = "idle" }
core.drag = { pickup = core.PICKUP_IDLE, pending = nil }

function core.pickup_client(c)  return { tag = "client", client = c } end
function core.pickup_split(id)  return { tag = "split", split_id = id } end

function core.drop_pickup()
    core.drag.pickup = core.PICKUP_IDLE
end

-- Tab bar wibox cache, owned by titlebar but read by animation:
-- core.tabbar[screen][leaf_id] = { wb = wibox, ... }.
core.tabbar = {}

-- Smush (font-shrink) coordination between smush.lua and focus.lua.
core.smush = {
    running         = false,
    restore_client  = nil,
    restore_leaf_id = nil,
    focus_client    = nil,
}

-- Set by arrange.lua at load time; lets animation.lua refresh the UI
-- without a circular require.
core.update_ui = nil

---------------------------------------------------------------------------
-- State accessors
---------------------------------------------------------------------------

function core.screen_of(s)
    if type(s) == "number" then return screen[s] end
    return s
end

-- Get or create the layout state for a tag.
function core.state(t)
    local st = core.tag_state[t]
    if not st then
        local root = tree.make_leaf()
        st = {
            root            = root,
            focused_leaf_id = root.id,
            scroll_x        = 0,
            scroll_target   = 0,
            canvas_w        = nil,
        }
        core.tag_state[t] = st
    end
    return st
end

function core.leaf(state, leaf_id)
    return state and tree.find_leaf_by_id(state.root, leaf_id) or nil
end

function core.focused_leaf(state)
    return tree.find_leaf_by_id(state.root, state.focused_leaf_id)
end

-- (tag, state) for a client's first tag, or nil if untracked.
function core.client_state(c)
    local t = c.first_tag
    if not t then return nil, nil end
    return t, core.tag_state[t]
end

-- (leaf, state, tag) for a client, or nils.
function core.client_leaf(c)
    local t, state = core.client_state(c)
    if not state then return nil, nil, nil end
    return tree.find_leaf_for_client(state.root, c), state, t
end

-- (tag, state) for a screen iff its selected tag runs the splitwm layout.
function core.active_state(s)
    local t = s.selected_tag
    if not t or not t.layout or t.layout.name ~= "splitwm" then return nil, nil end
    return t, core.state(t)
end

function core.tab_index(leaf, c)
    if not leaf or not c then return nil end
    for i, tc in ipairs(leaf.tabs) do
        if tc == c then return i end
    end
    return nil
end

function core.clamp_tab_index(idx, n)
    if n <= 0 then return 0 end
    idx = math.floor(tonumber(idx) or 0)
    return math.max(1, math.min(n, idx))
end

return core
