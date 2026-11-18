# 2026-11-18: each part starts at the start of its own buffer (the forty-ninth change)

C4 of doc/signature-workflow.md. Offline on the Mac first (scsynth 3.14.1), then with
the norns's own scsynth (3.13.0-dev), then on the norns.

## The fault

io's write head is one for the four tracks. It stopped where a pass ended, and the next
pass went on from there, on any track. A part could start anywhere in its 60 s, and a
part that crossed the end became a 60 s loop with silence in it.

## The probe

`test/dsp/review/probe8.scd` drives `\four_io` as the engine does. One io on a buffer
pair of 4 s, a sine at its input, four passes:

| Pass | Time | The sine | What it is |
|---|---|---|---|
| 1 | 0.5 to 1.5 s | 220 Hz | the first pass |
| 2 | 2.0 to 2.5 s | 331 Hz | a new take: `rec_pass` steps in the bundle of the rec |
| 3 | 3.0 to 3.3 s | 442 Hz | rec alone, as a START after a STOP |
| 4 | 3.6 to 3.8 s | 550 Hz | a new take: `rec_pass` steps one block before the rec |

`an_probe8.py` reads the head's polled phase and the buffer played back.

| | Before | After |
|---|---|---|
| The head 5 ms after pass 2 starts | at 1.013 s | at 0.004 s |
| The head 5 ms after pass 3 starts | at 1.522 s | at 0.513 s: it goes on |
| The head 5 ms after pass 4 starts | at 1.830 s | at 0.002 s |
| The head jumps back | never | at 2.0 s and at 3.6 s |
| 0.03 to 0.18 s of the buffer | 220 Hz | 550 Hz, pass 4 |
| 0.25 to 0.48 s | 220 Hz | 331 Hz, the rest of pass 2 |
| 0.55 to 0.78 s | 220 Hz | 442 Hz, pass 3 |
| 0.86 to 0.99 s | 220 Hz | 220 Hz, the rest of pass 1 |
| 1.10 to 2.20 s | 442 Hz at -15.9 dB | empty |
| UGens of `four_io` | 106 | 107 |

The norns's own scsynth renders the after column to the last digit
(`test/device/norns_nrt.sh`). The head does not jump at the synth's start on either.

## On the norns: row 19.32

`count: 198`, and `engine.commands.rec_track.fmt` reads `ii`. A part of 20 s on each
track in turn, a tone at the input. "Before" is the engine of the forty-fifth change
with the script of the forty-eighth, the same hour. The head stood at 16.5 s when the
row began.

| Row 19.32 | Before | After |
|---|---|---|
| Part 1, window | 16.54 to 36.50 s | 0 to 20.03 s |
| Part 2, window | 36.57 to 56.55 s | 0 to 20.03 s |
| Part 3, window | 0 to 60 s: it crossed the end | 0 to 20.03 s |
| Part 4, window | 16.66 to 36.67 s | 0 to 20.04 s |
| `take_len`, the four parts | 36.5, 56.6, 60 and 36.7 s | 20.03 s each |
| Each part alone in PLAY | -18.8 dB | -18.8 dB |
| Ten passes of exactly 2 s: the window against 2 s | 36 to 49 ms short | from 2 ms short to 1 ms long |
| A pass with a STOP of 1 s in it | one take, 56.80 to 58.87 s | one take, 0 to 2.09 s |
| A pass that moves from track 1 to track 2 | track 1: 0 to 60 s. Track 2: 0.35 to 1.88 s | 0 to 1.53 s on each |

Rows 19.1 (the count, the plugin) and 19.4 (each track's own take, by its digest) pass.

## The older rows on this engine

Stages 2, 3, 5, 10, 11, 12 and 16 ran on the forty-ninth change, 53 rows that the
script checks. They record takes, undo them, save them and start them on sound. All of
them pass or are measured as before, except one.

Row 10.8 (a clear is silence) fails: after the erase, 320 frames of the buffer are not
zero, 6.7 ms at 11.70 s. That is where regen's write head stood. The fault is older than
this change, and three erases on this engine show its cause:

| The erase | Frames left in the buffer |
|---|---|
| With `regen` at 0.4 | 320 |
| With `regen` set to 0 a moment before | 0 |
| While a take records | 0 |

The script clears the buffer first and stops regen after. Regen's write then fades over
10 ms into the buffer that was just cleared. The row last ran on 2026-11-06, under
mangler, and passed.

## A clear with a write running (the fiftieth change)

The engine's `clear` now zeroes the pair a second time, 60 ms later, unless a file, a
new take or another clear came to that pair since.

Offline, probe8's `_clear.wav`: regen at 0.4 writes into the pair, the pair is zeroed at
1.5 s, and regen goes to 0 3 ms later, as the script does it.

| What stays in the buffer | Before | After |
|---|---|---|
| Offline, on the Mac and with the norns's scsynth | 576 frames, 12 ms, peak 0.07 | 0 frames |
| On the norns, row 10.8 (an erase with regen at 0.4) | 320 frames, 6.7 ms | 0: "buffer all zero" |

On the norns the second zero spares what comes right after a clear:

| In the same moment as the clear | The buffer after |
|---|---|
| A file of 5.2 s is loaded | holds the file from its first frame to its last |
| A new take of 1 s is armed | holds the take from its start, 1.05 s |

`count: 198`. The other rows of stage 10 pass or are measured as before, and rows 19.1
and 19.4 pass.

Nobody has listened to this change yet.

## A voice change (the fifty-first change, C2 of the plan)

K3 MODE, or a scene that lands, puts another drone on the track. The old drone left over
20 ms in the same moment, and the new head started at the window's start.

### What a new drone needs to sound

`test/dsp/review/probe9.scd`, `_rise.wav`: each drone alone, born over a 1 kHz take.

| The drone | First sound, with the plugin | Within 6 dB of its level | Without the plugin |
|---|---|---|---|
| GRAIN | 1.7 ms | 22 ms | 23 ms |
| WARP | 3.1 ms | 91 ms: it rises in a line to 175 ms | 78 ms |
| PV | 12.9 ms | 24 ms | 41 ms: silent for 35 ms |
| CLOUD | 341.2 ms: Clouds' own buffer | 341 ms | the granulator, 25 ms |

And how far a drone's sound lies behind its head, each drone alone against PLAY from the
same start (`_steady.wav`, over the phrase):

| The drone | Behind PLAY, with the plugin | Match | Without the plugin |
|---|---|---|---|
| WARP | 0 frames | 1.000 | 25 frames, match 0.897 |
| PV | 2560 frames, 53.3 ms | 0.992 | 1984 frames, 41.3 ms |
| CLOUD | 16347 frames, 340.6 ms | 0.862 | the granulator: no match |

### The change, offline

Each change is read against the two drones it joins, alone (`an_probe9.py`). At each
moment of the 600 ms after the swap, the lane's level is set against the quieter of the
two (the deepest place) and the louder (the highest). 0 dB is no hole and no bump. With
the plugin, on the Mac:

| The change | Over the tone, before | After | Over the phrase, before | After |
|---|---|---|---|---|
| PLAY to WARP, deepest | -28.6 dB | -0.3 dB | -26.9 dB | -0.1 dB |
| PLAY to PV, deepest | -27.8 dB | -1.5 dB | -7.6 dB | -0.5 dB |
| PLAY to CLOUD, deepest | silence for 341 ms | -1.6 dB | silence for 341 ms | -1.1 dB |
| WARP to PLAY, highest | +1.7 dB | +0.5 dB | 0.0 dB | +0.2 dB |
| PV to PLAY, deepest | -3.5 dB | 0.0 dB | not read: another place | 0.0 dB |
| The highest among PLAY, WARP and PV | +1.7 dB | +0.5 dB | 0.0 dB | +0.4 dB |
| What is heard, from its place | 1000 ms back | 0.0 ms | 1000 ms back | 0.0 ms |
| The new drone against the old one | another place | | another place | 0 frames out of step |

- A change into GRAIN is read at the change alone, and it moves from render to render:
  two streams of grains never match. It read from 0 to -11 dB over ten renders, where
  GRAIN's own stream dips by 5 to 10 dB by itself.
- Without the plugin: among PLAY, WARP and PV the deepest is -3.9 dB over the tone (it
  was -85.6 dB) and -0.4 dB over the phrase (-31.1 dB). The stock WARP plays 17 to 25
  frames behind its head, so it is that far out of step with PLAY.
- The norns's own scsynth (`test/device/norns_nrt.sh`) renders the plugin's rows the
  same: the deepest -1.5 dB and -0.5 dB, 0 frames out of step. One number differs: a
  change into PLAY reads +1.2 dB at its highest, where the Mac reads +0.5 dB.
- Each drone def has five UGens more, at control rate: `four_play` 60, `four_warp` 47,
  `four_pv` 48, `four_grain` 104, `four_clouds` 115.

### Where the place is read

The first build read the old head's place in sclang (`getSynchronous`) and sent it as a
number with the new drone. Offline that is exact. On the device the number is already
old when the server makes the drone. How old was not measured: half a cycle of the
1 kHz tone is 0.5 ms. Two copies of a tone that are out of step cancel while they cross:

| On the device, PLAY to PV and back over the tone | Deepest |
|---|---|
| The old engine | -70.6 dB |
| The first build: the place sent from sclang | -18.5 dB |
| This build: the new drone reads the phase bus in its first block | -0.9 dB |

The new drone is added at the head of the group, so in its first block it reads what
the old drone wrote one block before. It adds one block of travel and the two delays.

### How a head starts at a given frame

`Phasor.ar(0, rate, start, end)` takes its first place from `start` when it is built. Five
ways to give it 700 for that moment only, on both scsynths:

| The way | The Mac, 3.14 | The norns, 3.13 |
|---|---|---|
| A control at 700, set to 0 by a message one block later | starts at 700 | starts at 700 |
| `Trig.kr(control, 0)` | starts at 700 | starts at 700 |
| `Impulse.kr(0) * control` | starts at 700 | starts at 900 |
| A trigger-rate control | starts at 900 | starts at 900 |
| A control set to 0 in the bundle of the spawn | starts at 1 | starts at 1 |

A synth's UGens are built at its first block, after the whole bundle. The engine uses
`Trig.kr`, and rounds the place to a whole frame.

### A stage of an envelope takes a block

The old drone's hold is a stage of its own envelope. At a change into PLAY the hold is
0, and the stage still takes a block (1.3 ms). So the old drone starts to go after the
new one starts to come, and for that time the two add up to more than one sound. The
norns's scsynth reads about twice the Mac's bump. Why was not looked into.

| The cross into PLAY | The Mac, 3.14 | The norns, 3.13 |
|---|---|---|
| 10 ms, fast at first (the start every drone has, and the same curve out) | +1.6 dB | +3.2 dB |
| 20 ms, a straight line in and out | +0.5 dB | +1.2 dB |

The engine uses the straight line: the new PLAY drone takes its time in and its curve
from the swap (`att`, `acrv`).

### On the device (row 19.33)

`count: 198`, the plugin on (`four: FourStretch on`). Track 2 holds a 1 kHz take of
14 s and plays it in PLAY. The row changes it to a mode and back, and records the
engine's output. It waits until the head is between 2% and 15% of the window, so no
loop seam falls into a recording. The level is read in windows of 20 ms (50 ms for
GRAIN and CLOUD) against the median of the recording. The old engine is the fiftieth
change, on the same day, with the same row.

| PLAY to the mode and back | The old engine, deepest | This build, deepest | Highest | The mode alone |
|---|---|---|---|---|
| WARP | -26.4 dB | -0.4 dB | +1.3 dB | -0.3 and +0.5 dB |
| PV | -70.6 dB | -0.9 dB | +1.3 dB | -0.3 and +0.6 dB |
| CLOUD | -71.2 dB | -1.3 dB | +0.9 dB | -1.5 and +1.2 dB |
| GRAIN | -7.5 dB | -7.1 dB | +0.9 dB | -5.8 and +2.2 dB |

| | The old engine | This build |
|---|---|---|
| What is heard after the change, from its place | 1550 to 2067 ms back | +1, -3, -14 and -1 ms |
| Four tracks from PLAY to WARP in one moment | all four within 52 ms | after 53, 193, 374 and 546 ms |
| xruns at those four changes | 0 | 0 |

- The place on the device is read from the script's phase poll, once a frame (67 ms).
  It says that the loop went on. The offline probe reads the place to the frame.
- GRAIN over a steady tone dips by 5.8 dB by itself, so its change reads no deeper than
  its own stream.
- The first build of this change read -18.5 dB at PV (see above).
- A second run, after another restart with the same code: WARP -0.4 dB, PV -0.9 dB,
  CLOUD -1.3 dB, GRAIN -5.8 dB (alone -4.9 dB), the place within 10 ms, and the four
  tracks after 60, 201, 364 and 539 ms.
- The recordings are outside the repo: `../four-device-recordings/2026-11-18/19.33_*.wav`,
  and the old engine's in `before_51/` beside them.
- Not heard by the user.

### WARP and PV at the loop seam (open)

The row's first runs used a take of 4 s, and a seam fell into some recordings. With the
first build of this change, WARP alone read -26.3 dB at the seam, and a recording of PV
with a seam in it read -26.8 dB. The dips were 82 ms wide in WARP and 26 ms in PV. The
old engine was not read at a seam, and nothing in this change touches the loop's wrap,
so the dip is taken to be older. PLAY has a seam fade. doc/dsp-plan.md names the seam as
not built. doc/plan.md, Phase 0, item 8.

### The other rows, with this build

| Row | Result |
|---|---|
| 19.1 | `count: 198`, `four: FourStretch on` |
| 19.4 | each track keeps its own take: the digests hold |
| 19.5 | the four voices in the tree, track 1 alone -64.6 dB at 220 Hz, track 2 alone -17.0 dB |
| 19.7, 19.10 | only what is heard exists: the lanes at rest, CHORUS and RING, both OFF |
| 19.14 | PLAY, WARP and PV read the same bands: the largest difference 0.0 dB |
| 19.16 | CLOUD runs `four_clouds`, -19.1 dB |
| 19.27 | four PV at pitch 2 56.6%, the dense set 64.3% of the scsynth thread, no xrun (56.6% and 64.5% before). Still over 60% |
| 19.32 | four parts of 20 s: every window starts at 0, 20.02 to 20.03 s long |
| 10.8 | a clear with regen running: the buffer reads all zero |

The five UGens that each drone gained cost nothing that the row can read. JACK logged
one xrun in this run, from the softcut client, 40 s after the script load and before
row 19.27. The rows that count xruns counted none.
