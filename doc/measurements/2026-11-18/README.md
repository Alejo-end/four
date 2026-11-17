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
mangler, and passed. It is the next change.

Nobody has listened to this change yet.
