#!/bin/sh
# Start the four visuals: the bridge, and the browser full screen on this
# display. Double click this file in Finder, or run it in a terminal.
#   KIOSK=0 sh visuals/start.command    starts the bridge only
#   LAN=1 sh visuals/start.command      also lets other computers on this network open the page
# Stop with visuals/stop.command.
cd "$(dirname "$0")/.." || exit 1
LOG=/tmp/four-bridge.log
PORT=8080
# the first Chromium browser found: Brave, Chrome, Chromium or Edge
BROWSER=""
for b in "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser" \
         "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
         "/Applications/Chromium.app/Contents/MacOS/Chromium" \
         "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge"; do
  [ -x "$b" ] && BROWSER="$b" && break
done

command -v node >/dev/null 2>&1 || { echo "node is not installed (https://nodejs.org)"; exit 1; }

# keep the computer awake while this runs
if [ -z "$MANGLER_AWAKE" ]; then
  MANGLER_AWAKE=1 caffeinate -dimsu -w $$ >/dev/null 2>&1 &
fi

# the bridge, restarted by a loop if it ever stops
if ! lsof -nP -iTCP:$PORT -sTCP:LISTEN >/dev/null 2>&1; then
  ( while true; do MANGLER_LAN="${LAN:-0}" node visuals/bridge.js >>"$LOG" 2>&1; sleep 1; done ) >/dev/null 2>&1 &
  echo $! > /tmp/four-bridge.pid
fi
for i in 1 2 3 4 5 6 7 8 9 10; do
  curl -s -o /dev/null "http://127.0.0.1:$PORT/" && break
  sleep 1
done
curl -s -o /dev/null "http://127.0.0.1:$PORT/" || { echo "the bridge did not start, see $LOG"; exit 1; }
echo "bridge running on port $PORT (log: $LOG)"

# what the page will hear: the computer's default audio input
echo "default audio input:"
system_profiler SPAudioDataType 2>/dev/null | awk '/^        [^ ].*:$/ {n=$0} /Default Input Device: Yes/ {print "  " n}'
echo "it must be the return from the norns (System Settings > Sound > Input)."

[ "$KIOSK" = "0" ] && exit 0
[ -n "$BROWSER" ] || { echo "no Chromium browser found: open http://127.0.0.1:$PORT in Brave or Chrome by hand"; exit 1; }
echo "browser: $BROWSER"

# A new profile every time: the browser restores the tabs of its last session,
# and each start would add one more page, every one of them drawing.
pkill -f "user-data-dir=$HOME/.four-visuals" 2>/dev/null
sleep 1
rm -rf "$HOME/.four-visuals"
# A private profile, so the flags apply even when the browser is already open:
#   autoplay with sound, and the audio input granted without a question.
exec "$BROWSER" --user-data-dir="$HOME/.four-visuals" --no-first-run --no-default-browser-check \
  --autoplay-policy=no-user-gesture-required --use-fake-ui-for-media-stream \
  --disable-session-crashed-bubble --hide-crash-restore-bubble \
  --kiosk "http://127.0.0.1:$PORT/"
