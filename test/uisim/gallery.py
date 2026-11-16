#!/usr/bin/env python3
"""Rebuild doc/ui/ from the offscreen renders. Stdlib only.

usage: python3 test/uisim/gallery.py [lua]

Run it from the repository root. `lua` is the interpreter that renders, and
the default is the LUA53 variable or `lua`. Render with one interpreter every
time: math.random differs between Lua 5.3 and 5.5, so the orbit's shot does too.

The script renders the base, empty and track2 variants to a temporary folder.
It writes each shot of SHOTS to doc/ui/ at 4x, and doc/ui/four.png, one picture
of the twelve pages. It removes every other png in doc/ui/.
"""
import os, pathlib, subprocess, sys, tempfile

HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parent.parent
sys.path.insert(0, str(HERE))
from pgm2png import read_pgm, write_png

SCALE = 4

# doc/ui name -> render shot
SHOTS = {
    "splash": "base_00_SPLASH_14",
    "take": "base_01_TAKE",
    "take-empty": "empty_01_TAKE_EMPTY",
    "take-rec": "base_01_TAKE_REC",
    "take-wait": "base_01_TAKE_WAIT",
    "take-undo": "base_01_TAKE_UNDO_ARC",
    "take-erase": "base_01_TAKE_ERASE_ARC",
    "voice-play": "base_02_VOICE",
    "voice-erode": "base_02_VOICE_ERODE",
    "voice-grain": "base_02_VOICE_GRAIN",
    "voice-warp": "base_02_VOICE_WARP",
    "voice-pv": "base_02_VOICE_PV",
    "tracks": "t2_03_TRACKS",
    "tracks-sends": "t2_03_TRACKS_SENDS",
    "tape": "base_04_TAPE",
    "filter": "base_05_FILTER",
    "filter-hp": "t2_05_FILTER_T2_HP",
    "filter-crush": "t2_05_FILTER_T2_CRUSH",
    "effect-chorus": "base_06_EFFECT_CHORUS",
    "effect-flange": "base_06_EFFECT_FLANGE",
    "effect-wobble": "base_06_EFFECT_WOBBLE",
    "effect-reson": "base_06_EFFECT_NOTE",
    "effect-ring": "base_06_EFFECT_RING",
    "delay": "base_07_DELAY",
    "delay-inf": "base_07_DELAY_INF",
    "reverb": "base_08_REVERB",
    "reverb-shimmer": "base_08_REVERB_SHIMMER",
    "mix": "base_09_MIX",
    "mix-stop": "base_09_MIX_STOP",
    "pads": "base_10_PADS",
    "pads-seq": "base_10_PADS_SEQ",
    "motion": "base_11_MOTION_PLAY",
    "motion-rec": "base_11_MOTION_REC",
    "motion-lfo": "base_11_MOTION_LFO",
    "scene": "base_12_SCENE_MORPH",
    "scene-ab": "base_12_SCENE_AB",
    "scene-peek": "base_12_SCENE_PEEK",
    "scene-orbit": "base_12_SCENE_ORBIT",
}

# doc/ui/four.png: the twelve pages in page order, four in a row
OVERVIEW = [
    "take", "voice-grain", "tracks", "tape",
    "filter", "effect-chorus", "delay", "reverb-shimmer",
    "mix", "pads-seq", "motion-lfo", "scene",
]
COLS, GAP, GAP_LEVEL = 4, 2, 5      # the gap is in screen pixels, before the scale


def render(lua, out):
    for prefix, variant in (("base", None), ("empty", "empty"), ("t2", "track2")):
        cmd = [lua, "test/uisim/render_pages.lua", "four.lua", str(out), prefix]
        if variant:
            cmd.append(variant)
        # track 1 sends to the delay and the reverb, or both pages say NO SEND
        subprocess.run(cmd, cwd=ROOT, check=True, stdout=subprocess.DEVNULL,
                       env=dict(os.environ, FOUR_SENDS="1"))


def scaled(w, h, vals):
    rows = []
    for y in range(h):
        row = []
        for v in vals[y * w:(y + 1) * w]:
            row.extend([v] * SCALE)
        rows.extend([row] * SCALE)
    return rows


def main():
    lua = sys.argv[1] if len(sys.argv) > 1 else os.environ.get("LUA53", "lua")
    ui = ROOT / "doc" / "ui"
    with tempfile.TemporaryDirectory() as tmp:
        tmp = pathlib.Path(tmp)
        render(lua, tmp)
        shots = {name: read_pgm(tmp / (shot + ".pgm")) for name, shot in SHOTS.items()}

    for old in ui.glob("*.png"):
        old.unlink()
    for name, (w, h, vals) in shots.items():
        write_png(ui / (name + ".png"), w * SCALE, h * SCALE, scaled(w, h, vals))

    w, h, _ = shots[OVERVIEW[0]]
    n_rows = (len(OVERVIEW) + COLS - 1) // COLS
    sw, sh = COLS * w + (COLS + 1) * GAP, n_rows * h + (n_rows + 1) * GAP
    sheet = [GAP_LEVEL * 17] * (sw * sh)
    for i, name in enumerate(OVERVIEW):
        x0 = GAP + (i % COLS) * (w + GAP)
        y0 = GAP + (i // COLS) * (h + GAP)
        vals = shots[name][2]
        for y in range(h):
            at = (y0 + y) * sw + x0
            sheet[at:at + w] = vals[y * w:(y + 1) * w]
    write_png(ui / "four.png", sw * SCALE, sh * SCALE, scaled(sw, sh, sheet))
    print("doc/ui: %d pictures and four.png" % len(shots))


if __name__ == "__main__":
    main()
