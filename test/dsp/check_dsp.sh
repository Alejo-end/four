#!/bin/bash
# The offline DSP regression check: one verdict, PASS or FAIL. It compiles the
# real lib/Engine_Four.sc on the Mac with the stand-in CroneEngine, renders the
# review probes (test/dsp/review) and engine.scd, and checks the fixes of the
# twenty-second change and the rows of the acceptance checklist in
# doc/dsp-plan.md. The rules and margins are in check_dsp.py.
# usage: test/dsp/check_dsp.sh <work folder>
#   FOUR_PLUGIN_DIR=<folder with FourStretch.scx> test/dsp/check_dsp.sh <work folder>
# Needs SuperCollider.app, clang++, and numpy, scipy and soundfile (through uv
# when the system Python lacks them). Exits non-zero on any FAIL.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$1"
if python3 -c "import numpy, scipy, soundfile" 2>/dev/null; then
    exec python3 "$HERE/check_dsp.py" "$1"
fi
exec uv run -q --with numpy --with scipy --with soundfile python "$HERE/check_dsp.py" "$1"
