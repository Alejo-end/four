#!/bin/bash
# Builds FourStretch.scx for the Mac bench. usage: ugen/build_mac.sh <out folder>
# SC_HEADERS is a SuperCollider source tree (its include/ folder is all we need).
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
SC_HEADERS="${SC_HEADERS:-$HOME/Documents/RNBO/rnbo.example.supercollider/third-party/supercollider}"
OUT="${1:-.}"; mkdir -p "$OUT"
clang++ -std=c++17 -O2 -fPIC -shared -undefined dynamic_lookup \
    -I"$SC_HEADERS/include/plugin_interface" -I"$SC_HEADERS/include/common" -I"$SC_HEADERS/include/server" \
    -o "$OUT/FourStretch.scx" "$HERE/FourStretch.cpp"
echo "built $OUT/FourStretch.scx"
