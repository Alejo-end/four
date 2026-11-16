#!/bin/bash
# Builds FourStretch.so ON THE NORNS and puts it where four ships it:
# ignore/plugins/<what uname -m prints>/FourStretch.so in this repo. norns
# compiles nothing under a folder named ignore. The next load of four installs
# it (lib/mplugin.lua) and asks for SYSTEM > RESTART.
#
# usage, on the norns, in the deployed script:
#   ~/dust/code/four/ugen/build_norns.sh
#
# It runs the proof first (test_core must print `all passed`) and builds in a
# scratch folder, so nothing else lands in dust/code. Then copy the binary
# back into the repo on the Mac and commit it: the next deploy runs
# `rsync --delete`, which removes a binary the Mac does not have (an installed
# copy in Extensions stays). SC_HEADERS is the SuperCollider include folder.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
H="${SC_HEADERS:-/usr/local/include/SuperCollider}"
[ "$(uname -s)" = Linux ] || { echo "build_norns.sh builds on the norns (Linux); on the Mac use ugen/build_mac.sh" >&2; exit 2; }
[ -f "$H/plugin_interface/SC_PlugIn.h" ] || { echo "no SuperCollider headers in $H (set SC_HEADERS)" >&2; exit 2; }
ARCH="$(uname -m)"
# the flags of the norns build (ugen/README.md). -O3 and -ffast-math made the
# code slower on the Pi. The CPU flags fit the 32-bit system of the norns.
case "$(g++ -dumpmachine)" in
    arm*-gnueabihf) CPU="-mcpu=cortex-a72 -mfpu=neon-fp-armv8 -mfloat-abi=hard" ;;
    aarch64*)       CPU="-mcpu=cortex-a72" ;;
    *)              CPU="" ;;
esac
F="-O2 -std=c++17 $CPU -DFOUR_FFTW -I$HERE/vendor/eurorack"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "the proof (test_core)"
g++ $F -o "$WORK/test_core" "$HERE/test_core.cpp" -lfftw3f
"$WORK/test_core" > "$WORK/proof.txt" || { cat "$WORK/proof.txt"; echo "the proof failed, no plugin built" >&2; exit 1; }
tail -n 1 "$WORK/proof.txt"

echo "the plugin"
g++ $F -fPIC -shared -fvisibility=hidden \
    -I"$H/plugin_interface" -I"$H/common" -I"$H/server" \
    -o "$WORK/FourStretch.so" "$HERE/FourStretch.cpp" -lfftw3f

OUT="$REPO/ignore/plugins/$ARCH"
mkdir -p "$OUT"
cp "$WORK/FourStretch.so" "$OUT/FourStretch.so"
echo "built $OUT/FourStretch.so (g++ $(g++ -dumpversion), $(g++ -dumpmachine))"
echo "load four: it installs the binary and asks for SYSTEM > RESTART"
