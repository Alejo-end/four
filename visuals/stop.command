#!/bin/sh
# Stop the visuals: the page, the bridge and its restart loop.
pkill -f "user-data-dir=$HOME/.mangler-visuals" 2>/dev/null
[ -f /tmp/mangler-bridge.pid ] && kill "$(cat /tmp/mangler-bridge.pid)" 2>/dev/null && rm -f /tmp/mangler-bridge.pid
pkill -f "visuals/bridge.js" 2>/dev/null
echo stopped
