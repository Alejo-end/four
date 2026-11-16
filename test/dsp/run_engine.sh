#!/bin/bash
# Compiles lib/Engine_Four.sc on the Mac (with the stand-in CroneStub.sc.txt) and renders its
# SynthDefs offline. Needs SuperCollider.app, and for the analysis a Python
# with numpy, scipy and soundfile.
# usage: test/dsp/run_engine.sh <work folder> <tag>
#   then: python test/dsp/an_engine.py <work folder> <tag>
# The work folder must hold long5k.wav (python test/dsp/mkbuf.py, run inside it).
# For one PASS or FAIL verdict over this render and the review probes:
# test/dsp/check_dsp.sh <work folder>
set -e
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="$(cd "$1" && pwd)"; TAG="${2:-run}"
# The work folder must be outside the repo: it holds a stand-in CroneEngine .sc
# file, and the deploy rsync would copy it to the norns (CLAUDE.md, invariant 1).
case "$WORK/" in "$REPO"/*) echo "refused: the work folder $WORK is inside the repo $REPO" >&2; exit 2;; esac
SCLANG=/Applications/SuperCollider.app/Contents/MacOS/sclang
# The stand-in class lives in the repo as .txt ON PURPOSE: a second CroneEngine
# .sc file under dust/code would hang every script on the norns.
mkdir -p "$WORK/stub" && cp "$REPO/test/dsp/CroneStub.sc.txt" "$WORK/stub/CroneStub.sc"
printf 'includePaths:\n    - %s/stub\n    - %s/lib\nexcludePaths: []\n' "$WORK" "$REPO" > "$WORK/conf.yaml"
rm -f "$WORK/elog.txt"
# under `script`: without a terminal sclang buffers its output and loses it
# FOUR_PLUGIN_DIR (a folder with FourStretch.scx, from ugen/build_mac.sh) turns
# the FourStretch voices on; without it the engine builds its stock voices.
[ -n "$FOUR_PLUGIN_DIR" ] && export FOUR_STRETCH=1
( BENCH_DIR="$WORK" BENCH_TAG="$TAG" script -q "$WORK/elog.txt" "$SCLANG" -l "$WORK/conf.yaml" "$REPO/test/dsp/engine.scd" > /dev/null 2>&1 & )
for i in $(seq 1 90); do sleep 2; grep -q "BENCH_DONE\|ERROR" "$WORK/elog.txt" 2>/dev/null && break; done
# only this run's sclang: its command line names this work folder's conf.yaml
sleep 2; pkill -f "$WORK/conf.yaml" || true
grep -A8 "ERROR" "$WORK/elog.txt" && exit 1
grep "COMMANDS\|BENCH_DONE\|FourStretch\|four: \|FAIL\|not installed\|exception" "$WORK/elog.txt"
