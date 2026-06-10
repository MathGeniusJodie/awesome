# splitwm from-scratch rewrite — working notes

Branch: refactor/idiomatic-cleanup. Goal: full rewrite, no preserved internal
APIs, ALL features intact. Verify each step: `awesome -k -c rc.lua`,
`~/.cargo/bin/selene .`, `./test.sh` boots clean in Xephyr.

## New architecture (splitwm/)
- `core.lua`   — shared mutable state ONLY (no logic, no requires of other splitwm modules):
  - `core.tag_state` (weak k: tag -> {root, focused_leaf_id, scroll_x, scroll_target, canvas_w})
  - `core.geo` (weak k: tag -> {geos[leaf_id]=rect, bounds={...}})
  - `core.client_actual_geo`, `core.client_last_target` (client -> rect)
  - `core.drag` = { pickup = {tag="idle"|"client",client|"split",split_id}, pending }
  - `core.tabbar` (s -> {[leaf_id]={wb,...}}) owned by titlebar, read by animation
  - `core.smush` = { running=false, restore_client, restore_leaf_id, focus_client }
  - `core.update_ui(s)` slot — assigned by arrange.lua at load
  - helpers: `core.state(t)` (get-or-create), `core.leaf(state,id)`, `core.focused_leaf(state)`,
    `core.active_state(s)` (tag+state iff layout is splitwm), `core.screen_of(x)`
- `theme.lua`  — `theme.init()` reads beautiful once; exposes color_* fields and metrics:
  TITLEBAR_HEIGHT=34, BTN_SIZE=26, BTN_SPACING=5, N_SPLIT_BTNS=5, MIN_SPLIT_W, MIN_SPLIT_H,
  SPLIT_RATIO=0.618, RESIZE_STEP=0.05, SCROLL_STEP=100, `theme.tb_h(gap)=max(34,gap)`,
  `theme.client_geo(geo,bw,gap,tb_h,scroll_x)`
- `tree.lua`   — pure tree (leaf/branch ctors, traversal, compute geometry, gap drop target)
- `focus.lua`  — focus guard, force_focus, focus_after_arrange, focus_leaf_after_arrange
- `smush.lua`  — Ctrl+0/Ctrl+- queue via splitwm/smushkeys helper; after_layout(s, leaf_id?)
- `ops.lua`    — all tree mutations: pin/unpin clients, move/swap tabs, split_leaf,
  close_leaf(+anim), resize, insert_column_at_gap, insert_at_edge, drop_into_new_split,
  handle_split_pickup, try_drop_picked_up, make_split_action_callbacks, pending client requests
- `scroll.lua` — scroll_to/anim, ensure_in_view, scroll_delta
- `arrange.lua`— layout arrange(p) + update_ui(s) + drag-hover tab switching poll
- `animation.lua` — split/close/minimize geometry animations; pendings + is_active(s);
  uses core.tabbar + core.update_ui (no DI)
- `colors.lua` — oklab color science, per-client colors, hue slots, icon hue rotation (ported)
- `icons.lua`  — cairo icon draw fns (ported)
- `client_icons.lua` — launcher/app icon resolution (ported, no DI)
- `titlebar.lua` — tab bar UI, split buttons, color picker; requires core/theme/ops directly
- `underlay.lua` — wallpaper, drag handles, gap "+" buttons; requires core/theme/ops/scroll
- `init.lua`   — thin: theme.init, signal wiring, layout object, public API (same EXTERNAL
  api used by rc.lua/menu/status: setup, layout, launchers, spawn, expect_next_client,
  split_horizontal/vertical, close_split, focus_next/prev_split, next/prev_tab,
  move_tab_next/prev, resize_grow/shrink, scroll_delta, set_wallpaper, tab_shape,
  focus_leaf, activate_client_in_leaf, move_client_to_leaf_id, swap_client_to_tab_index,
  get_state, collect_leaves, flush_caches, insert_column_at_gap)

## Behavioral features that MUST survive (from old code)
- Splits = binary tree; DIR_H branches are N-ary (ratios list), DIR_V binary (single ratio).
- Tabs per leaf; active_tab; minimized leaves (H: gap-width slot; V: titlebar-height slot).
- Golden ratio 0.618 on split; H-split flattens into existing H parent (ratio r -> r*phi, r*(1-phi)).
- close_leaf: tabs merge into first leaf of adjacent sibling; N-ary ratio redistribution;
  binary collapse; focused-leaf preservation; canvas_w clamp; scroll remap for close anim.
- Scrollable canvas: canvas_w > workarea; insert column at gap / at left/right edge
  (root grows canvas; left insert shifts scroll_x); ensure_in_view on focus change.
- Pickup/drag: pickup client (tab) or split (swap); drop on tab bar, on client, into
  gap → new split via tree.find_gap_drop_target; drag-over-tab hover switch poll (0.05s).
- Animations: split (new leaf slides from edge, ease_out_back 0.28s/60fps), close,
  minimize (min_leaf.min_anim flag keeps client visible during anim), scroll (0.05s ease-out-quad).
- Focus engine: guard_focus (0.35s), focus_request_seq, re-assert at +0.05/+0.16s,
  focus signal honors guard, updates active_tab/focused_leaf, ensure_in_view.
- Smush: narrow-split font shrink via smushkeys helper; thresholds from beautiful
  (splitwm_smush_width_threshold 900 / tiny 650); per-client mode+bucket key dedup
  (bucket = floor(width/25), key "leafid:bucket"); queue serialized w/ timers
  0.035/0.02; restore focus after queue.
- expect_next_client/spawn: pending request (tag, leaf_id, append) with 4s timeout;
  pin into requested leaf at active_tab+1 or append.
- Client colors: manual xproperty "splitwm_manual_color" > icon-hue-derived > hash fallback;
  hue slots per app key (40° steps), hue-rotated icon surfaces; resolve_color_conflict on
  pin/move/merge.
- arrange(): pins unknown clients, computes geos+bounds into core.geo, hides off-viewport
  and inactive tabs, skips re-geometry when client undershot due to size hints
  (client_actual_geo/client_last_target check), no geometry during active anim or fullscreen.
- update_ui(): tab bars + drag handles; starts pending anims; ensure_in_view on focus change
  (last_focused_leaf per screen).
- Signals: manage (icon prep, pin, color conflict), unmanage (drag/pickup cleanup, color
  release, unpin everywhere, cache cleanup), property::geometry -> client_actual_geo,
  property::class/instance (refresh identity + release hue slot)/icon (refresh, keep slot),
  focus (guard logic), property::fullscreen -> arrange, button::press (pickup drops /
  focus leaf / start hover poll), tag property::selected (reset pending, stop mousegrabber,
  drop geo cache, update_ui), startup -> arrange all.
- No `goto` in new code (selene parses lua51 grammar).

## Top-level files (also rewrite): rc.lua, menu.lua, status.lua, timebar.lua, hunger.lua
External theme vars (beautiful.splitwm_*) and test.sh keybindings must keep working.

## Progress
- [x] read: rc, tree, init, animation, colors, icons (in context)
- [ ] core.lua, theme.lua, tree.lua, focus.lua, smush.lua
- [ ] colors.lua, icons.lua, animation.lua
- [ ] client_icons.lua (read+rewrite), underlay.lua (read+rewrite), titlebar.lua (read+rewrite)
- [ ] ops.lua, scroll.lua, arrange.lua, init.lua
- [ ] rc.lua, menu.lua, status.lua, timebar.lua, hunger.lua (read+rewrite)
- [ ] verify: awesome -k, selene, test.sh; commit
