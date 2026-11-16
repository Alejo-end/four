#!/bin/bash
# Builds FourStretch.scx for the Mac bench. usage: ugen/build_mac.sh <out folder>
# SC_HEADERS is a SuperCollider source tree (its include/ folder is all we need).
# vendor/eurorack holds the Clouds code of FourCloud (four_cloud.h). The plugin
# shows the server only its entry points (-fvisibility=hidden), so the Clouds
# code inside it can never bind to the same code in an installed MiClouds.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
SC_HEADERS="${SC_HEADERS:-$HOME/Documents/RNBO/rnbo.example.supercollider/third-party/supercollider}"
OUT="${1:-.}"; mkdir -p "$OUT"
clang++ -std=c++17 -O2 -fPIC -shared -undefined dynamic_lookup -fvisibility=hidden \
    -I"$SC_HEADERS/include/plugin_interface" -I"$SC_HEADERS/include/common" -I"$SC_HEADERS/include/server" \
    -I"$HERE/vendor/eurorack" \
    -o "$OUT/FourStretch.scx" "$HERE/FourStretch.cpp"
echo "built $OUT/FourStretch.scx"
