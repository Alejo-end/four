#!/bin/sh
# Check the whole chain and say what is wrong. Run it after start.command.
ok()  { printf "  ok    %s\n" "$1"; }
bad() { printf "  FAIL  %s\n" "$1"; }
PORT=8080
echo "computer"
curl -s -o /dev/null "http://127.0.0.1:$PORT/" && ok "bridge answers on port $PORT" || bad "bridge is not running (run start.command)"
LINE=$(tail -1 /tmp/four-bridge.log 2>/dev/null)
echo "  last bridge line: $LINE"
RATE=$(echo "$LINE" | sed -n 's/^osc :[0-9]* \([0-9]*\) msg\/s.*/\1/p')
PAGES=$(echo "$LINE" | sed -n 's/.*ws :[0-9]* \([0-9]*\) page.*/\1/p')
[ "${RATE:-0}" -gt 20 ] && ok "the norns is sending ($RATE msg/s)" || bad "no OSC from the norns (is osc out on? is the host this computer?)"
[ "${PAGES:-0}" -ge 1 ] && ok "a visuals page is connected" || bad "no visuals page open"
STATUS=$(curl -s -m 3 "http://127.0.0.1:$PORT/status")
echo "  page report: $STATUS"
echo "$STATUS" | grep -q '"playing":true' && ok "the news picture is playing" || bad "the news picture is not playing"
echo "$STATUS" | grep -q '"muted":false' && ok "the news is unmuted" || bad "the news is muted (click the page once)"
echo "norns"
ping -c1 -t2 norns.local >/dev/null 2>&1 && ok "norns.local answers" || bad "norns.local does not answer (same Wi-Fi?)"
HOST=$(scutil --get LocalHostName 2>/dev/null)
echo "  this computer is $HOST.local ; on the norns, osc host should be that name or $(ipconfig getifaddr en0 2>/dev/null)"
echo "audio"
system_profiler SPAudioDataType 2>/dev/null | awk '/^        [^ ].*:$/ {n=$0} /Default Input Device: Yes/ {print "  default input:" n} /Default Output Device: Yes/ {print "  default output:" n}'
echo "news"
curl -s -m 6 -o /dev/null -w "  DW stream: HTTP %{http_code}\n" "https://dwamdstream102.akamaized.net/hls/live/2015525/dwstream102/index.m3u8"
curl -s -m 6 -o /dev/null -w "  France 24 stream: HTTP %{http_code}\n" "https://live.france24.com/hls/live/2037218/F24_EN_HI_HLS/master_500.m3u8"
