local tree = {}

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
    return {
        type = "leaf",
        id   = gen_id(),
        tabs = {},
        active_tab = 0,
    }
end

function tree.make_branch(direction, ratio, child_a, child_b)
    return {
        type      = "branch",
        direction = direction,
        ratio     = ratio or 0.5,
        children  = { child_a, child_b },
    }
end

---------------------------------------------------------------------------
-- Tree traversal helpers
---------------------------------------------------------------------------

function tree.collect_leaves(node, out)
    out = out or {}
    if node.type == "leaf" then
        table.insert(out, node)
    else
        tree.collect_leaves(node.children[1], out)
        tree.collect_leaves(node.children[2], out)
    end
    return out
end

function tree.find_leaf_for_client(node, c)
    if node.type == "leaf" then
        for _, tab_c in ipairs(node.tabs) do
            if tab_c == c then return node end
        end
        return nil
    else
        return tree.find_leaf_for_client(node.children[1], c)
            or tree.find_leaf_for_client(node.children[2], c)
    end
end

function tree.find_leaf_by_id(node, id)
    if node.type == "leaf" then
        return node.id == id and node or nil
    else
        return tree.find_leaf_by_id(node.children[1], id)
            or tree.find_leaf_by_id(node.children[2], id)
    end
end

function tree.find_parent(root, target)
    if root.type == "leaf" then return nil, nil end
    for i, child in ipairs(root.children) do
        if child == target then return root, i end
        local p, idx = tree.find_parent(child, target)
        if p then return p, idx end
    end
    return nil, nil
end

function tree.find_focused_leaf(root, focused_client)
    if focused_client then
        local leaf = tree.find_leaf_for_client(root, focused_client)
        if leaf then return leaf end
    end
    local leaves = tree.collect_leaves(root)
    return leaves[1]
end

---------------------------------------------------------------------------
-- Geometry computation
---------------------------------------------------------------------------

local function compute_tree_inner(node, x, y, w, h, gap, geos, bounds, v_bound_above)
    if node.type == "leaf" then
        if geos then geos[node.id] = { x = x, y = y, width = w, height = h } end
        if bounds ~= nil then node.v_bound_above = v_bound_above end
        return
    end
    local dir, ratio, inner = node.direction, node.ratio, gap
    if dir == "h" then
        local usable = w - inner
        local w1 = math.floor(usable * ratio)
        if bounds then
            table.insert(bounds, { branch = node, dir = "h", pos = x + w1 + math.floor(inner / 2),
                start = y, span = h, parent_x = x, parent_w = w, parent_gap = inner })
        end
        compute_tree_inner(node.children[1], x,          y, w1,        h, gap, geos, bounds, v_bound_above)
        compute_tree_inner(node.children[2], x+w1+inner, y, usable-w1, h, gap, geos, bounds, v_bound_above)
    else
        local usable = h - inner
        local h1 = math.floor(usable * ratio)
        local bnd
        if bounds then
            bnd = { branch = node, dir = "v", pos = y + h1 + math.floor(inner / 2),
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

function tree.compute_geometries(node, x, y, w, h, gap)
    local geos = {}
    tree.compute_tree(node, x, y, w, h, gap, geos, nil)
    return geos
end

return tree
