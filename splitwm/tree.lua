local tree = {}

tree.DIR_H = "horizontal"
tree.DIR_V = "vertical"

---------------------------------------------------------------------------
-- ID generator
---------------------------------------------------------------------------

local next_id = 1
local function gen_id()
    local id = next_id
    next_id = next_id + 1
    return id
end

---------------------------------------------------------------------------
-- Node constructors
---------------------------------------------------------------------------

function tree.make_leaf()
    return { kind = "leaf", id = gen_id(), tabs = {}, active_tab = 0 }
end

-- All branches are n-ary with a ratios list; ratio is the share of the
-- first child ({r, 1-r} initially).
function tree.make_branch(direction, ratio, child_a, child_b)
    local r = ratio or 0.5
    return {
        kind      = "branch",
        direction = direction,
        children  = { child_a, child_b },
        ratios    = { r, 1 - r },
    }
end

---------------------------------------------------------------------------
-- Tree traversal helpers
---------------------------------------------------------------------------

local function traverse(node, fn)
    if node.kind == "leaf" then
        fn(node)
    else
        for _, child in ipairs(node.children) do
            traverse(child, fn)
        end
    end
end

function tree.collect_leaves(node)
    local out = {}
    traverse(node, function(leaf) table.insert(out, leaf) end)
    return out
end

function tree.find_leaf_for_client(node, c)
    if node.kind == "leaf" then
        for _, tc in ipairs(node.tabs) do
            if tc == c then return node end
        end
    else
        for _, child in ipairs(node.children) do
            local found = tree.find_leaf_for_client(child, c)
            if found then return found end
        end
    end
end

function tree.find_leaf_by_id(node, id)
    if not node then return nil end
    if node.kind == "leaf" then
        return node.id == id and node or nil
    end
    for _, child in ipairs(node.children) do
        local found = tree.find_leaf_by_id(child, id)
        if found then return found end
    end
    return nil
end

function tree.find_parent(root, target)
    if root.kind == "leaf" then return nil, nil end
    for i, child in ipairs(root.children) do
        if child == target then return root, i end
        local p, idx = tree.find_parent(child, target)
        if p then return p, idx end
    end
    return nil, nil
end

---------------------------------------------------------------------------
-- Geometry computation
---------------------------------------------------------------------------

-- Split `usable` px between N children along one axis: minimized leaves get
-- min_sz each, the rest is shared by ratio, the last normal child absorbs
-- rounding. Returns the array of child sizes.
local function child_sizes(node, usable, min_sz)
    local N = #node.children
    local function is_min(i)
        return node.children[i].kind == "leaf" and node.children[i].minimized
    end

    local min_total, ratio_sum, last_normal = 0, 0, nil
    for i = 1, N do
        if is_min(i) then
            min_total = min_total + min_sz
        else
            ratio_sum = ratio_sum + node.ratios[i]
            last_normal = i
        end
    end
    if ratio_sum <= 0 then ratio_sum = 1 end
    local usable_normal = math.max(0, usable - min_total)

    local sizes, allocated = {}, 0
    for i = 1, N do
        if is_min(i) then
            sizes[i] = min_sz
        elseif i ~= last_normal then
            local sz = math.max(1, math.floor(usable_normal * node.ratios[i] / ratio_sum))
            sizes[i] = sz
            allocated = allocated + sz
        end
    end
    if last_normal then
        sizes[last_normal] = math.max(1, usable_normal - allocated)
    end
    return sizes
end

local function compute_tree_inner(node, x, y, w, h, gap, geos, bounds, v_bound_above, tb_h)
    if node.kind == "leaf" then
        if geos then
            geos[node.id] = {
                x = x, y = y, width = w, height = h,
                v_bound_above = v_bound_above,
            }
        end
        return
    end

    local inner = gap
    local N     = #node.children

    if node.direction == tree.DIR_H then
        local usable = math.max(0, w - inner * (N - 1))
        -- Minimized leaves collapse to one gap width.
        local sizes = child_sizes(node, usable, gap)
        local cx = x
        for i = 1, N do
            local cw = sizes[i]
            if bounds and i < N then
                table.insert(bounds, {
                    branch    = node,
                    dir       = tree.DIR_H,
                    left_idx  = i,
                    pos       = cx + cw + math.floor(inner / 2),
                    left_x    = cx,
                    left_w    = cw,
                    right_w   = sizes[i + 1],
                    usable    = usable,
                    start     = y, span = h,
                    parent_x  = x, parent_w = w, parent_gap = inner,
                })
            end
            compute_tree_inner(node.children[i], cx, y, cw, h, gap,
                geos, bounds, v_bound_above, tb_h)
            cx = cx + cw + inner
        end
    else
        local usable = math.max(0, h - inner * (N - 1))
        -- Minimized leaves get a slot just tall enough for the tab bar.
        local min_sz = math.max(0, (tb_h or gap) - inner)
        local sizes = child_sizes(node, usable, min_sz)
        local cy = y
        for i = 1, N do
            local ch = sizes[i]
            -- The bound above child i (nil for the first child, which
            -- inherits whatever bound is above this branch).
            local bnd = v_bound_above
            if bounds and i > 1 then
                bnd = {
                    branch     = node,
                    dir        = tree.DIR_V,
                    top_idx    = i - 1,
                    pos        = cy - math.ceil(inner / 2),
                    top_y      = cy - inner - sizes[i - 1],
                    top_h      = sizes[i - 1],
                    bottom_h   = ch,
                    usable     = usable,
                    start      = x, span = w,
                    parent_gap = inner,
                }
                table.insert(bounds, bnd)
            end
            compute_tree_inner(node.children[i], x, cy, w, ch, gap,
                geos, bounds, bnd, tb_h)
            cy = cy + ch + inner
        end
    end
end

function tree.compute_tree(node, x, y, w, h, gap, geos, bounds, tb_h)
    compute_tree_inner(node, x + gap, y + gap, w - 2 * gap, h - 2 * gap,
        gap, geos, bounds, nil, tb_h)
end

-- Given leaves and canvas geos, find the nearest leaf to screen point (mx, my)
-- (scroll_x converts canvas x to screen x; gap is the titlebar region above geo.y).
-- Returns leaf_id, direction (DIR_H or DIR_V), new_leaf_first (bool), or nil if empty.
function tree.find_gap_drop_target(leaves, geos, scroll_x, mx, my, gap)
    local best_lid, best_dist = nil, math.huge
    for _, leaf in ipairs(leaves) do
        local lid = leaf.id
        local g = geos[lid]
        if g then
            local gx = g.x - scroll_x
            local dx = mx < gx and (gx - mx)
                or (mx >= gx + g.width and (mx - gx - g.width) or 0)
            local dy = my < g.y - gap and (g.y - gap - my)
                or (my >= g.y + g.height and (my - g.y - g.height) or 0)
            local dist = dx + dy
            if dist < best_dist then best_dist = dist; best_lid = lid end
        end
    end
    if not best_lid then return nil end
    local g    = geos[best_lid]
    local gx   = g.x - scroll_x
    local dx_l = math.max(0, gx - mx)
    local dx_r = math.max(0, mx - (gx + g.width))
    local dy_t = math.max(0, (g.y - gap) - my)
    local dy_b = math.max(0, my - (g.y + g.height))
    local direction, new_first
    if math.max(dx_l, dx_r) >= math.max(dy_t, dy_b) then
        direction = tree.DIR_H; new_first = dx_l > dx_r
    else
        direction = tree.DIR_V; new_first = dy_t > dy_b
    end
    return best_lid, direction, new_first
end

return tree
