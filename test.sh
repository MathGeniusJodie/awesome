#!/bin/bash
# Launch splitwm in Xephyr for testing
# Usage: ./test.sh [display_num]

DISPLAY_NUM="${1:-1}"
SCREEN_SIZE="${2:-1280x800}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=== splitwm test launcher ==="
echo "Display:  :${DISPLAY_NUM}"
echo "Screen:   ${SCREEN_SIZE}"
echo "Config:   ${SCRIPT_DIR}/rc.lua"
echo ""

# Kill any existing Xephyr on this display
pkill -f "Xephyr :${DISPLAY_NUM}" 2>/dev/null
sleep 0.3

# Start Xephyr
Xephyr ":${DISPLAY_NUM}" -ac -screen "${SCREEN_SIZE}" -resizeable &
XEPHYR_PID=$!
sleep 1

if ! kill -0 "$XEPHYR_PID" 2>/dev/null; then
    echo "ERROR: Xephyr failed to start"
    exit 1
fi

echo "Xephyr running (PID ${XEPHYR_PID})"
echo "Starting awesome..."
echo ""

# Point awesome at our config directory
# (so require("splitwm") resolves from our dir)
DISPLAY=":${DISPLAY_NUM}" awesome -c "${SCRIPT_DIR}/rc.lua" \
    --search "${SCRIPT_DIR}" 2>&1 | while read -r line; do
    echo "[awesome] $line"
done &

AWESOME_PID=$!

echo ""
echo "=== Keybindings ==="
echo "  Mod4+Enter      Open terminal"
echo "  Mod4+v           Split horizontal"
echo "  Mod4+h           Split vertical"
echo "  Mod4+q           Close split"
echo "  Mod4+Tab         Focus next split"
echo "  Mod4+Shift+Tab   Focus prev split"
echo "  Mod4+]           Next tab in split"
echo "  Mod4+[           Prev tab in split"
echo "  Mod4+Shift+]     Move tab to next split"
echo "  Mod4+Shift+[     Move tab to prev split"
echo "  Mod4+l           Grow split"
echo "  Mod4+Shift+l     Shrink split"
echo "  Mod4+Ctrl+r      Restart awesome (reload config)"
echo "  Mod4+Shift+q     Quit awesome"
echo ""
echo "Press Ctrl+C to stop everything"

# Wait and cleanup
trap "kill $AWESOME_PID $XEPHYR_PID 2>/dev/null; exit 0" INT TERM
wait $XEPHYR_PID
kill $AWESOME_PID 2>/dev/null
