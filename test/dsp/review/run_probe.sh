#!/bin/bash
# like test/dsp/run_engine.sh, for the review probes of doc/measurements/2026-11-15
# usage: test/dsp/review/run_probe.sh <work folder> <tag> <probe.scd>
set -e
REPO="$(cd "$(dirname "$0")/../../.." && pwd)"
WORK="$(cd "$1" && pwd)"; TAG="$2"; PROBE="$3"
# The work folder must be outside the repo: it holds a stand-in CroneEngine .sc
# file, and the deploy rsync would copy it to the norns (CLAUDE.md, invariant 1).
case "$WORK/" in "$REPO"/*) echo "refused: the work folder $WORK is inside the repo $REPO" >&2; exit 2;; esac
SCLANG=/Applications/SuperCollider.app/Contents/MacOS/sclang
mkdir -p "$WORK/stub" && cp "$REPO/test/dsp/CroneStub.sc.txt" "$WORK/stub/CroneStub.sc"
printf 'includePaths:\n    - %s/stub\n    - %s/lib\nexcludePaths: []\n' "$WORK" "$REPO" > "$WORK/conf.yaml"
rm -f "$WORK/plog_$TAG.txt"
[ -n "$FOUR_PLUGIN_DIR" ] && export FOUR_STRETCH=1
( BENCH_DIR="$WORK" BENCH_TAG="$TAG" script -q "$WORK/plog_$TAG.txt" "$SCLANG" -l "$WORK/conf.yaml" "$PROBE" > /dev/null 2>&1 & )
for i in $(seq 1 150); do sleep 2; grep -q "PROBE_DONE\|ERROR" "$WORK/plog_$TAG.txt" 2>/dev/null && break; done
# only this run's sclang: its command line names this work folder's conf.yaml
sleep 2; pkill -f "$WORK/conf.yaml" || true
grep -A8 "ERROR" "$WORK/plog_$TAG.txt" && exit 1
grep "COMMANDS\|PROBE_DONE\|FourStretch\|done \|FAIL\|not installed\|exception" "$WORK/plog_$TAG.txt"
