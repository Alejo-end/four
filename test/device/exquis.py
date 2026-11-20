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
          sent: an encoder that sends one above and one below its middle value
          steps by one tick a detent (EX_ENC_DIV in the driver assumes that).
  sweep   the pad ids. The driver folds the grid onto the pads from their ids:
          0 at the bottom left, row by row, to the last at the top right. The sweep
          lights them in that order. A light that does not run left to right,
          bottom row first, means that the fold is wrong.

No id, channel or count of the Exquis is written in this file: each is asked
of the driver that runs on the norns (Norns.exquis_proto).

The four script must be loaded. Stage 20 of the gate
(`python3 test/device/gate.py 20`) runs the rows a computer can judge.
"""
import os
import sys
import time

sys.path.insert(0, os.path.dirname(__file__))
from norns import CONTROL, MIDI_MAX, NOTE_OFF, NOTE_ON, Norns  # noqa: E402

# MIDI's own, beside those of norns.py
KEY_PRESSURE, CH_PRESSURE, BEND, BEND_MID, SYSEX = 0xA0, 0xD0, 0xE0, 8192, 0xF0
WATCH_S = 30        # how long `watch` listens when no time is given
POLL_S = 0.25       # how often it reads the log
SWEEP_STEP_S = 0.15  # how long each pad of the sweep stays lit

# the words for the driver's controls, by the name the driver gives each id
# (M.EX in lib/mgrid.lua). The ids come from the norns: none is written here.
LABELS = {"rec": "Record", "loop": "Loop", "clips": "Clips", "play": "Play/Stop",
          "down": "Down", "up": "Up", "undo": "Undo", "redo": "Redo"}


def names(p):
    """Control id -> its name, from the driver's table `p`."""
    out = {p[key]: label for key, label in LABELS.items()}
    for i in range(p["encoders"]):
        out[p["enc"] + i] = f"encoder {i + 1}"
        out[p["push"] + i] = f"push {i + 1}"
    return out


def split(msg):
    """A message's kind (its status byte's high half) and its channel."""
    return (msg[0] & 0xF0, (msg[0] & 0x0F) + 1) if msg else (0, 0)


def describe(msg, p):
    """One received message, as words. `msg` is its bytes, `p` the driver's table."""
    if not msg:
        return "empty"
    st, ch = split(msg)
    ours = ch == p["ch"]
    if st in (NOTE_ON, NOTE_OFF) and len(msg) >= 3:
        kind = "pad" if ours else "note"
        return f"{kind} {msg[1]} {'down' if st == NOTE_ON and msg[2] > 0 else 'up'} (ch {ch}, vel {msg[2]})"
    if st == CONTROL and len(msg) >= 3:
        name = names(p).get(msg[1], f"cc {msg[1]}") if ours else f"cc {msg[1]}"
        return f"{name} = {msg[2]} (ch {ch})"
    if st == CH_PRESSURE and len(msg) >= 2:
        return f"pressure {msg[1]} (ch {ch})"
    if st == KEY_PRESSURE and len(msg) >= 3:
        return f"key pressure {msg[2]} on note {msg[1]} (ch {ch})"
    if st == BEND and len(msg) >= 3:
        return f"bend {msg[1] + (msg[2] << 7) - BEND_MID} (ch {ch})"
    if msg[0] == SYSEX:
        return "sysex"
    return "other"


def summary(msgs, p):
    """What a watch saw, by control: the lines to print."""
    pads, ccs, other = set(), {}, 0
    for m in msgs:
        st, ch = split(m)
        if st == NOTE_ON and ch == p["ch"] and len(m) >= 3:
            pads.add(m[1])
        elif st == CONTROL and ch == p["ch"] and len(m) >= 3:
            ccs.setdefault(m[1], []).append(m[2])
        elif st != NOTE_OFF:
            other += 1
    total = p["pads"]
    lines = [f"{len(msgs)} messages. Pads pressed on channel {p['ch']}: {len(pads)} of {total}"
             + (f" (not {', '.join(str(i) for i in range(total) if i not in pads)})" if 0 < len(pads) < total else "")]
    known = names(p)
    for cc in sorted(ccs):
        vals = ccs[cc]
        name = known.get(cc, f"cc {cc} (the driver has no name for it)")
        if p["enc"] <= cc < p["push"]:
            ticks = sorted({v - p["enc_mid"] for v in vals})
            verdict = "one tick a message, as the driver assumes" if set(ticks) <= {-1, 1} else \
                "MORE than one tick in a message: turn one detent and read the value"
            lines.append(f"  {name}: ticks {ticks} over {len(vals)} messages. {verdict}")
        else:
            lines.append(f"  {name}: values {sorted(set(vals))}")
    if other:
        lines.append(f"  {other} messages that are not pads or controls of channel {p['ch']} (in KEYS the pads "
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
    p = n.exquis_proto()
    if n.exquis_ask("tap_on") != "true":
        print("could not listen in")
        return
    print(f"Listening for {seconds:.0f} s. Press, turn, push.")
    msgs = []
    try:
        end = time.time() + seconds
        while time.time() < end:
            time.sleep(POLL_S)
            got = n.exquis_ask("tap_read")
            for row in (r for r in got.split(";") if r.strip()):
                msg = [int(b, 16) for b in row.split()]
                msgs.append(msg)
                print(f"  {row:24} {describe(msg, p)}", flush=True)
    finally:
        n.exquis_ask("tap_off")
    print("\n".join(summary(msgs, p)))


def sweep(n, step=SWEEP_STEP_S):
    if not status(n):
        return
    p = n.exquis_proto()
    was = n.exquis()["mode"]
    n.exquis_surface(True)
    time.sleep(2 * step)                # the driver's own first paint of the pads
    print(f"Pad 0 to pad {p['pads'] - 1}. The light must run left to right, from the bottom row up, "
          f"a long row and a short one in turn.")
    try:
        for pad in range(p["pads"]):
            n.exquis_ask("sweep", f"local ID, LEVEL = {pad}, {MIDI_MAX} ")
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
        watch(n, float(sys.argv[2]) if len(sys.argv) > 2 else WATCH_S)
    else:
        sweep(n)
    return 0


if __name__ == "__main__":
    sys.exit(main())
