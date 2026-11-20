#!/usr/bin/env python3
"""An Exquis on a connected norns: what it is called, what it sends, where its pads are.

    export NORNS_CTL=<control socket>       # see norns.py
    python3 test/device/exquis.py status     # the name, the driver's mode
    python3 test/device/exquis.py watch 30   # 30 s of every message it sends
    python3 test/device/exquis.py sweep      # light pad 0 to pad 60, one by one

four's driver (lib/mgrid.lua) is written from the maker's Developer Mode
specification and was never run on an Exquis. Three things in it are guesses,
and each command here settles one:

  status  the name. The driver takes a MIDI device with "exquis" in its name.
          Without one, this prints every name the norns lists.
  watch   the bytes. Press each pad and button and turn each encoder one
          detent each way. The summary gives, for each control, the values it
          sent: an encoder that sends 65 and 63 steps by one tick a detent
          (EX_ENC_DIV in the driver assumes that).
  sweep   the pad ids. The driver folds the grid onto the pads from their ids:
          0 at the bottom left, row by row, to 60 at the top right. The sweep
          lights them in that order. A light that does not run left to right,
          bottom row first, means that the fold is wrong.

The four script must be loaded. Stage 20 of the gate
(`python3 test/device/gate.py 20`) runs the rows a computer can judge.
"""
import os
import sys
import time

sys.path.insert(0, os.path.dirname(__file__))
from norns import Norns  # noqa: E402

# what the driver expects of each control (lib/mgrid.lua)
NAMES = {102: "Record", 103: "Loop", 104: "Clips", 105: "Play/Stop", 106: "Down", 107: "Up",
         108: "Undo", 109: "Redo", 110: "encoder 1", 111: "encoder 2", 112: "encoder 3",
         113: "encoder 4", 114: "push 1", 115: "push 2", 116: "push 3", 117: "push 4"}


def describe(msg):
    """One received message, as words. `msg` is its bytes."""
    if not msg:
        return "empty"
    st, ch = msg[0] & 0xF0, (msg[0] & 0x0F) + 1
    if st in (0x90, 0x80) and len(msg) >= 3:
        kind = "pad" if ch == 16 else "note"
        return f"{kind} {msg[1]} {'down' if st == 0x90 and msg[2] > 0 else 'up'} (ch {ch}, vel {msg[2]})"
    if st == 0xB0 and len(msg) >= 3:
        name = NAMES.get(msg[1], f"cc {msg[1]}") if ch == 16 else f"cc {msg[1]}"
        return f"{name} = {msg[2]} (ch {ch})"
    if st == 0xD0 and len(msg) >= 2:
        return f"pressure {msg[1]} (ch {ch})"
    if st == 0xA0 and len(msg) >= 3:
        return f"key pressure {msg[2]} on note {msg[1]} (ch {ch})"
    if st == 0xE0 and len(msg) >= 3:
        return f"bend {msg[1] + (msg[2] << 7) - 8192} (ch {ch})"
    if msg[0] == 0xF0:
        return "sysex"
    return "other"


def summary(msgs):
    """What a watch saw, by control: the lines to print."""
    pads, ccs, other = set(), {}, 0
    for m in msgs:
        st, ch = (m[0] & 0xF0, (m[0] & 0x0F) + 1) if m else (0, 0)
        if st == 0x90 and ch == 16 and len(m) >= 3:
            pads.add(m[1])
        elif st == 0xB0 and ch == 16 and len(m) >= 3:
            ccs.setdefault(m[1], []).append(m[2])
        elif st != 0x80:
            other += 1
    lines = [f"{len(msgs)} messages. Pads pressed on channel 16: {len(pads)} of 61"
             + (f" (not {', '.join(str(i) for i in range(61) if i not in pads)})" if 0 < len(pads) < 61 else "")]
    for cc in sorted(ccs):
        vals = ccs[cc]
        name = NAMES.get(cc, f"cc {cc} (the driver has no name for it)")
        if 110 <= cc <= 113:
            ticks = sorted({v - 64 for v in vals})
            verdict = "one tick a message, as the driver assumes" if set(ticks) <= {-1, 1} else \
                "MORE than one tick in a message: turn one detent and read the value"
            lines.append(f"  {name}: ticks {ticks} over {len(vals)} messages. {verdict}")
        else:
            lines.append(f"  {name}: values {sorted(set(vals))}")
    if other:
        lines.append(f"  {other} messages that are not pads or controls of channel 16 (in KEYS the pads "
                     f"play notes on the Exquis's own channels)")
    return lines


def status(n):
    ex = n.exquis()
    if not ex["name"]:
        print("No MIDI device on the norns has 'exquis' in its name. The devices:",
              ", ".join(ex["devices"]) or "none")
        print("If the Exquis is in that list, ex_find_device in lib/mgrid.lua must learn its name.")
        return False
    print(f"The norns calls it {ex['name']!r}.")
    if not ex["mode"]:
        print("four's driver does not hold it. Is the four script loaded? maiden says "
              "`four: Exquis in Developer Mode` when it is taken.")
        return False
    print(f"four holds it in {ex['mode']}. A grid with a device is {'attached' if ex['grid'] else 'not attached'}.")
    return True


def watch(n, seconds):
    if not status(n):
        return
    if n.exquis_ask("tap_on") != "true":
        print("could not listen in")
        return
    print(f"Listening for {seconds:.0f} s. Press, turn, push.")
    msgs = []
    try:
        end = time.time() + seconds
        while time.time() < end:
            time.sleep(0.25)
            got = n.exquis_ask("tap_read")
            for row in (r for r in got.split(";") if r.strip()):
                msg = [int(b, 16) for b in row.split()]
                msgs.append(msg)
                print(f"  {row:24} {describe(msg)}", flush=True)
    finally:
        n.exquis_ask("tap_off")
    print("\n".join(summary(msgs)))


def sweep(n, step=0.15):
    if not status(n):
        return
    was = n.exquis()["mode"]
    n.exquis_surface(True)
    time.sleep(0.3)
    print("Pad 0 to pad 60. The light must run left to right, from the bottom row (6 pads) up: "
          "rows of 6 and 5 in turn.")
    try:
        for pad in range(61):
            n.exquis_ask("sweep", f"local ID = {pad} ")
            time.sleep(step)
    finally:
        n.exquis_surface(was == "PADS")
        n.exquis_ask("repaint")
    print(f"Done. The driver is back in {was} and paints again.")


def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else "status"
    if cmd not in ("status", "watch", "sweep"):
        print(__doc__)
        return 2
    n = Norns()
    if not n.helpers():
        print("the four script is not loaded: no ctx")
        return 1
    if cmd == "status":
        status(n)
    elif cmd == "watch":
        watch(n, float(sys.argv[2]) if len(sys.argv) > 2 else 30)
    else:
        sweep(n)
    return 0


if __name__ == "__main__":
    sys.exit(main())
