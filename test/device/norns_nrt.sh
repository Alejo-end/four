#!/bin/bash
# Render offline probe scores with the norns's OWN scsynth (offline, -N), and
# bring the sound files back to this computer.
#
#   export NORNS_CTL=<control socket>      # see norns.py
#   test/device/norns_nrt.sh <folder of a Mac render> <out folder> <tag> <name:channels>...
#   test/device/norns_nrt.sh /work/plugin /work/plugin_norns p6 walk:2 pairs:100 more:4
#   python3 test/dsp/review/an_probe6.py /work/plugin_norns p6
#
# A probe (test/dsp/review/run_probe.sh) leaves <tag>_<name>.osc beside each
# <tag>_<name>.wav: the score, with the SynthDefs in it. The norns renders the
# same score. Use the plugin build's scores only when the norns has the plugin.
#
# Why: the two scsynths differ, and each difference hid or made a fault.
#   - The norns (3.13) holds Line.kr's first step for its whole first block.
#     The Mac (3.14) starts it at 0. A fade-in built on Line.kr passed on the
#     Mac and left a step of 14% on the norns (the forty-second change).
#   - The Mac frees a released synth one control step short of 0. The norns
#     runs the release to its end.
# A score that reads a sound file by its path on this computer cannot run there.
set -e
[ -n "$NORNS_CTL" ] || { echo "set NORNS_CTL to the control socket of an open session" >&2; exit 2; }
[ $# -ge 4 ] || { echo "usage: norns_nrt.sh <render folder> <out folder> <tag> <name:channels>..." >&2; exit 2; }
IN="$(cd "$1" && pwd)"; mkdir -p "$2"; OUT="$(cd "$2" && pwd)"; TAG="$3"; shift 3
HOST="we@${NORNS_HOST:-norns.local}"
# the socket's path can be too long for ssh: go to its folder and name it bare
cd "$(dirname "$NORNS_CTL")"; CTL="$(basename "$NORNS_CTL")"
for pair in "$@"; do
    name="${pair%%:*}"; nch="${pair##*:}"; stem="/tmp/four_nrt_${TAG}_$name"
    ssh -S "$CTL" "$HOST" "cat > $stem.osc && scsynth -N $stem.osc _ $stem.wav 48000 WAV float -o $nch -m 262144 -b 64 2>&1 | grep -i 'error\|exception\|not installed\|fail' | head -5" < "$IN/${TAG}_$name.osc"
    ssh -S "$CTL" "$HOST" "cat $stem.wav; rm -f $stem.wav $stem.osc" > "$OUT/${TAG}_$name.wav"
    echo "$name: $(wc -c < "$OUT/${TAG}_$name.wav") bytes"
done
