#!/bin/sh
# Stop the visuals: the page, the bridge and its restart loop.
pkill -f "user-data-dir=$HOME/.four-visuals" 2>/dev/null
[ -f /tmp/four-bridge.pid ] && kill "$(cat /tmp/four-bridge.pid)" 2>/dev/null && rm -f /tmp/four-bridge.pid
pkill -f "visuals/bridge.js" 2>/dev/null
echo stopped
