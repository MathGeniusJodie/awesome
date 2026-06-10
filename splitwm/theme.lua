---------------------------------------------------------------------------
-- splitwm.theme — resolved colors and layout metrics.
--
-- theme.init() must be called once from splitwm.setup() after beautiful is
-- initialized; until then the color fields are nil.
---------------------------------------------------------------------------

local beautiful = require("beautiful")

local theme = {}

-- Tab bar base height; grows with the gap (see theme.tb_h).
theme.TITLEBAR_HEIGHT = 34

-- Round button geometry; split minimum sizes derive from the button row
-- (minimize + swap + split + close + "+").
theme.BTN_SIZE     = 26
theme.BTN_SPACING  = 5
theme.N_SPLIT_BTNS = 5
theme.MIN_SPLIT_W  = theme.N_SPLIT_BTNS * theme.BTN_SIZE
    + (theme.N_SPLIT_BTNS - 1) * theme.BTN_SPACING
theme.MIN_SPLIT_H  = theme.TITLEBAR_HEIGHT

-- Initial ratio when splitting (golden ratio: larger side keeps the content).
theme.SPLIT_RATIO = 0.618

-- Ratio delta per grow/shrink keypress.
theme.RESIZE_STEP = 0.05

-- Pixels per discrete horizontal scroll event.
theme.SCROLL_STEP = 100

-- Width thresholds below which clients get font-shrink (smush) shortcuts.
theme.DEFAULT_SMUSH_WIDTH_THRESHOLD      = 900
theme.DEFAULT_TINY_SMUSH_WIDTH_THRESHOLD = 650

function theme.smush_threshold()
    return beautiful.splitwm_smush_width_threshold
        or theme.DEFAULT_SMUSH_WIDTH_THRESHOLD
end

function theme.tiny_smush_threshold()
    return beautiful.splitwm_tiny_smush_width_threshold
        or theme.DEFAULT_TINY_SMUSH_WIDTH_THRESHOLD
end

function theme.gap()
    return beautiful.splitwm_gap
end

function theme.focus_border_width()
    return beautiful.splitwm_focus_border_width
end

-- Effective tab bar height: grows to match the gap so the bar never
-- disappears into it.
function theme.tb_h(gap)
    return math.max(theme.TITLEBAR_HEIGHT, gap)
end

-- Geometry of the client area inside a leaf, accounting for border,
-- tab bar, and horizontal scroll. geo is the raw leaf rect in canvas coords.
function theme.client_geo(geo, bw, gap, tb_h, scroll_x)
    return {
        x      = geo.x + bw - (scroll_x or 0),
        y      = geo.y - gap + tb_h,
        width  = math.max(1, geo.width - bw * 2),
        height = math.max(1, geo.height + gap - bw - tb_h),
    }
end

-- Colors are mandatory theme variables (no fallbacks) except where noted.
function theme.init()
    theme.color_bg          = beautiful.splitwm_color_bg
    theme.color_fg          = beautiful.splitwm_color_fg
    theme.color_fg_disabled = beautiful.splitwm_fg_disabled
    theme.color_btn_bg      = beautiful.splitwm_btn_bg
    theme.color_transparent = beautiful.splitwm_transparent
    theme.color_handle      = beautiful.splitwm_handle_color
    theme.color_fg_hover    = beautiful.splitwm_fg_hover or "#ffffff20"
    theme.color_close       = beautiful.splitwm_close_color
        or beautiful.splitwm_accent or "#ff6666ff"
end

return theme
