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

-- DIR_H: n-ary branch; ratios = {r, 1-r} initially.
-- DIR_V: binary branch with a single ratio.
function tree.make_branch(direction, ratio, child_a, child_b)
    local r = ratio or 0.5
    if direction == tree.DIR_H then
        return {
            kind      = "branch",
            direction = direction,
            children  = { child_a, child_b },
            ratios    = { r, 1 - r },
        }
    else
        return {
            kind      = "branch",
            direction = direction,
            ratio     = r,
            children  = { child_a, child_b },
        }
    end
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

local function compute_tree_inner(node, x, y, w, h, gap, geos, bounds, v_bound_above)
    if node.kind == "leaf" then
        if geos then geos[node.id] = { x = x, y = y, width = w, height = h } end
        if bounds ~= nil then node.v_bound_above = v_bound_above end
        return
    end
    local dir, inner = node.direction, gap
    if dir == tree.DIR_H then
        -- N-ary: N children, N-1 inner gaps.
        local N      = #node.children
        local usable = math.max(0, w - inner * (N - 1))
        -- Normalize ratios on the fly (they may not sum to exactly 1).
        local ratio_sum = 0
        for _, r in ipairs(node.ratios) do ratio_sum = ratio_sum + r end
        if ratio_sum <= 0 then ratio_sum = 1 end
        -- Compute child widths; last child absorbs rounding remainder.
        local child_ws = {}
        local allocated = 0
        for i = 1, N - 1 do
            local cw = math.max(1, math.floor(usable * node.ratios[i] / ratio_sum))
            child_ws[i] = cw
            allocated   = allocated + cw
        end
        child_ws[N] = math.max(1, usable - allocated)
        -- Emit bounds entries and recurse.
        local cx = x
        for i = 1, N do
            local cw = child_ws[i]
            if bounds and i < N then
                table.insert(bounds, {
                    branch    = node,
                    dir       = tree.DIR_H,
                    left_idx  = i,
                    pos       = cx + cw + math.floor(inner / 2),
                    left_x    = cx,
                    left_w    = cw,
                    right_w   = child_ws[i + 1],
                    usable    = usable,
                    start     = y, span = h,
                    parent_x  = x, parent_w = w, parent_gap = inner,
                })
            end
            compute_tree_inner(node.children[i], cx, y, cw, h, gap, geos, bounds, v_bound_above)
            cx = cx + cw + inner
        end
    else
        -- DIR_V: binary, unchanged.
        local usable = h - inner
        local h1 = math.floor(usable * node.ratio)
        local bnd
        if bounds then
            bnd = { branch = node, dir = tree.DIR_V, pos = y + h1 + math.floor(inner / 2),
                start = x, span = w, parent_y = y, parent_h = h, parent_gap = inner }
            table.insert(bounds, bnd)
        end
        compute_tree_inner(node.children[1], x, y,          w, h1,        gap, geos, bounds, v_bound_above)
        compute_tree_inner(node.children[2], x, y+h1+inner, w, usable-h1, gap, geos, bounds, bnd)
    end
end

function tree.compute_tree(node, x, y, w, h, gap, geos, bounds)
    compute_tree_inner(node, x+gap, y+gap, w-2*gap, h-2*gap, gap, geos, bounds, nil)
end

return tree
