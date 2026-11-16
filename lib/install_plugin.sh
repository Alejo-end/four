#!/bin/sh
# install_plugin.sh: puts the FourStretch plugin that four ships into the user
# Extensions folder of SuperCollider, when it is missing or out of date.
#
# One rule, two callers. The engine class (Engine_Four.installPlug) runs it
# while sclang starts, before sclang boots the server, so the RESTART that
# follows `;install` brings the plugin in with no second restart.
# lib/mplugin.lua runs it again when four loads, as a fallback.
#
#   sh lib/install_plugin.sh HOME SCRIPT_DIR ARCH [SCSYNTH ...]
#
# ARCH is what `uname -m` prints. Empty, the script asks uname itself, and then
# works on Linux only, so the Mac bench never writes an Extensions folder.
# Each SCSYNTH is a path to try: the first one that is an ELF binary decides
# the class (32 or 64 bit) and machine that the plugin must have.
#
# It prints one word: installed, current, none (nothing shipped for this
# machine), foreign (the shipped binary does not suit scsynth), failed or
# unknown. It writes the .so alone, never a class file (a second copy of a
# class hangs every norns script), and nothing outside Extensions/FourStretch.

[ $# -ge 3 ] || { echo unknown; exit 0; }
home=$1
dir=$2
arch=$3
shift 3
if [ -z "$arch" ]; then
  [ "$(uname -s)" = Linux ] || { echo unknown; exit 0; }
  arch=$(uname -m)
fi
[ -n "$home" ] && [ -n "$dir" ] || { echo unknown; exit 0; }
case $arch in
  '' | *[!A-Za-z0-9_]*) echo unknown; exit 0 ;;
esac

src="${dir%/}/ignore/plugins/$arch/FourStretch.so"
[ -f "$src" ] || { echo none; exit 0; }

# the ELF class and machine of a file, as "class/machine"; empty when it is
# not an ELF binary
elfid() {
  [ -f "$1" ] || return 0
  [ "$(od -An -tx1 -N4 "$1" 2>/dev/null | tr -d ' \n')" = 7f454c46 ] || return 0
  printf '%s/%s' "$(od -An -tx1 -j4 -N1 "$1" | tr -d ' \n')" \
    "$(od -An -tx1 -j18 -N2 "$1" | tr -d ' \n')"
}
# A 64-bit kernel under the 32-bit norns system says aarch64 to uname and
# still needs a 32-bit binary: scsynth decides, not the folder name.
for s in "$@"; do
  want=$(elfid "$s")
  if [ -n "$want" ]; then
    [ "$(elfid "$src")" = "$want" ] || { echo foreign; exit 0; }
    break
  fi
done

ext="$home/.local/share/SuperCollider/Extensions/FourStretch"
dst="$ext/FourStretch.so"
# installed already: keep it unless the shipped one is newer and differs
# (an older shipped one never replaces a binary built by hand)
if [ -f "$dst" ] && { [ ! "$src" -nt "$dst" ] || cmp -s "$src" "$dst"; }; then
  echo current
  exit 0
fi
# beside it first, then renamed over it: a running scsynth has the old file
# mapped, and writing into that file in place could crash it. scsynth loads
# only files that end in .so, so the .tmp is never loaded.
tmp="$dst.tmp"
if mkdir -p "$ext" && cp "$src" "$tmp" && mv -f "$tmp" "$dst"; then
  echo installed
else
  rm -f "$tmp"
  echo failed
fi
