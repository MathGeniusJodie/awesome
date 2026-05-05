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

local function compute_tree_inner(node, x, y, w, h, gap, geos, bounds, v_bound_above, tb_h)
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
        -- Reserve fixed space for minimized leaves; distribute rest by ratio.
        local min_sz     = gap
        local min_total  = 0
        for i = 1, N do
            if node.children[i].kind == "leaf" and node.children[i].minimized then
                min_total = min_total + min_sz
            end
        end
        local usable_normal = math.max(0, usable - min_total)
        local ratio_sum = 0
        for i = 1, N do
            if not (node.children[i].kind == "leaf" and node.children[i].minimized) then
                ratio_sum = ratio_sum + node.ratios[i]
            end
        end
        if ratio_sum <= 0 then ratio_sum = 1 end
        -- Find last non-minimized child (absorbs rounding remainder).
        local last_normal = nil
        for i = 1, N do
            if not (node.children[i].kind == "leaf" and node.children[i].minimized) then
                last_normal = i
            end
        end
        local child_ws = {}
        local normal_allocated = 0
        for i = 1, N do
            if node.children[i].kind == "leaf" and node.children[i].minimized then
                child_ws[i] = min_sz
            elseif i ~= last_normal then
                local cw = math.max(1, math.floor(usable_normal * node.ratios[i] / ratio_sum))
                child_ws[i] = cw
                normal_allocated = normal_allocated + cw
            end
        end
        if last_normal then
            child_ws[last_normal] = math.max(1, usable_normal - normal_allocated)
        end
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
            compute_tree_inner(node.children[i], cx, y, cw, h, gap, geos, bounds, v_bound_above, tb_h)
            cx = cx + cw + inner
        end
    else
        -- DIR_V: minimized child gets a slot just tall enough for the titlebar (no leftover gap).
        local usable = h - inner
        local min_sz  = math.max(0, (tb_h or gap) - inner)
        local c1_min  = node.children[1].kind == "leaf" and node.children[1].minimized
        local c2_min  = node.children[2].kind == "leaf" and node.children[2].minimized
        local h1
        if c1_min and not c2_min then
            h1 = min_sz
        elseif c2_min and not c1_min then
            h1 = math.max(0, usable - min_sz)
        else
            h1 = math.floor(usable * node.ratio)
        end
        h1 = math.max(0, math.min(usable, h1))
        local bnd
        if bounds then
            bnd = { branch = node, dir = tree.DIR_V, pos = y + h1 + math.floor(inner / 2),
                start = x, span = w, parent_y = y, parent_h = h, parent_gap = inner }
            table.insert(bounds, bnd)
        end
        compute_tree_inner(node.children[1], x, y,          w, h1,        gap, geos, bounds, v_bound_above, tb_h)
        compute_tree_inner(node.children[2], x, y+h1+inner, w, usable-h1, gap, geos, bounds, bnd,          tb_h)
    end
end

function tree.compute_tree(node, x, y, w, h, gap, geos, bounds, tb_h)
    compute_tree_inner(node, x+gap, y+gap, w-2*gap, h-2*gap, gap, geos, bounds, nil, tb_h)
end

return tree
