# 2026-11-17: an effect's type change (the forty-second change)

Offline on the Mac first, then on the norns. The Mac runs scsynth 3.14.1 and the norns
3.13.0-dev. They differ, and the last two sections say how.

## What the device recording of 2026-11-16 shows

`19.12_type_steps.wav` (outside the repo, in `four-device-recordings/2026-11-16`), read
on both channels. The track played a tone of 220, 331 and 442 Hz. K3 stepped the type
six times.

| Time | The tap | What the samples show |
|---|---|---|
| 1.114 s left, 1.115 s right | FLANGE to WOBBLE | a step of 0.036, 12 ms after the tap. WOBBLE's line is 12 ms long |
| 1.81 to 2.0 s, right louder | WOBBLE to RESON | steps each 3.8 ms that fade over 200 ms. RESON's comb is 3.8 ms long |
| 3.401 s, both | RING to ECHO, 190 ms before | a step where the first echo starts. ECHO's line is 190 ms long |
| 3.933 s left, 3.935 s right | ECHO to CHORUS | a step of 0.012, 15 and 17 ms after the tap. CHORUS's lines are 15 and 17 ms long |

Each break is the head of a delay line that was born empty under the tone. gate.py read
the left channel only and missed RESON's ring. With both channels it finds breaks at
1.114, 1.821, 1.844, 1.867, 1.89, 3.401 and 3.933 s.

## The probe

`test/dsp/review/probe6.scd` renders the engine's own effect SynthDefs offline, and
`an_probe6.py` scores both channels. `test/dsp/check_dsp.sh` runs both.

- The six taps of row 19.12.
- Every change from one type to another, 42 of them. The change lands when the tone is
  near its peak, so a line that catches it mid-wave shows.
- The same two synths side by side, built from three renders: (a to OFF) + (OFF to b) -
  the tone. The engine's two synths are in series on the lane's bus.
- The shared delay, born under the tone. A filter family swap at 400 Hz.

A click is `audio.clicks`: one second difference above 0.006 and above 12 times the mean
of the 10 ms before it. A step is the largest second difference in the 600 ms after a
change. The tone alone has 0.0004.

## Before and after

"Before" is the engine of the fortieth change. WOBBLE's wow is random, so the counts of
the six taps move from run to run.

| | Plugin, before | after | No plugin, before | after |
|---|---|---|---|---|
| The six taps, clicks on both channels | 5 to 11 | 0 | 2 to 8 | 0 |
| The 42 changes, clicks on both channels | 54 | 0 | 70 to 73 | 0 |
| Largest step after a change | 0.098 | 0.0005 | 0.098 | 0.0009 |
| The shared delay born under the tone, largest step | 0.0011 | 0.0008 | 0.239 | 0.0004 |
| Filter, LP to HP at 400 Hz, largest step | 0.013 | 0.013 | 0.013 | 0.013 |

With the plugin the shared delay is the bucket brigade. Its filters round the edge, so
the second difference was small before the change too. The edge itself was there.

## The two suspects

1. The empty line. Before the change, every step sits one line length after the change:
   4.5 ms into FLANGE, 11.8 ms into WOBBLE, 16.7 ms into CHORUS, 49 ms into RESON (its
   ring, at the top of the fade), 189.3 ms into ECHO.
2. The series crossover. Side by side, the steps sit at the same places and are the same
   size or larger: OFF to ECHO 0.098 both ways, CHORUS to ECHO 0.054 in series and 0.098
   side by side. The series path makes no step of its own. It changes which value the
   new line catches, and it moves the level of the crossover: the deepest 5 ms lay up to
   8 dB lower in series for one pair (ECHO to WOBBLE) and up to 10 dB higher for another
   (FLANGE to WOBBLE).

So the fix is the line, not the order of the synths.

## What stays after the change

- A change into WOBBLE, CHORUS or FLANGE crossfades the tone with a copy of itself that
  is 1 to 17 ms late. For 10 to 20 ms the two comb. The deepest 5 ms window lay 11 to
  17 dB under the quieter of the levels before and after, over six runs. The same dip is
  there side by side. No crossfade law avoids it: two copies in opposite phase cancel at
  the middle of any fade.
- On a steady tone CHORUS and FLANGE make holes of 10 dB in a 5 ms window with no change
  near them (the six taps show one 207 ms after the tap into FLANGE, where its first
  notch reaches 220 Hz). The loop seam of PLAY is such a hole too (10.8 dB by the math).
  So the law "5 ms more than 10 dB under the 100 ms around it" cannot score an effect
  row. gate.py scores steps on both channels and lists the holes with their times.
- The Mac's scsynth frees a released synth one control step short of 0. A 50 ms straight
  fade ends at 1.4%, a 20 ms one at 6.7%, and the 50 ms S curve at 0.05%. The effect
  slot now uses the S curve. The filter keeps its 20 ms straight fade: on the Mac a
  family swap ends on a step of 0.013. The norns's scsynth runs a release to its end
  (the next section), and row 19.8 has no break there on either channel.

## The two scsynths differ

The first version of the fix faded the input with `Line.kr(0, 1, 0.01)`. It passed on
the Mac. On the norns row 19.12 had no break, but the new row 19.29 had one. Row 19.29
keeps a scene with ECHO, plays CHORUS, and rocks the fade between 0.49 and 0.51, so the
type changes at each crossing. Each time ECHO was born, a step came 190 ms later: 0.0052,
0.0083 and 0.0046, at 1.777, 2.580 and 3.446 s. One is over the click law's 0.006.

The same small score, rendered offline by each scsynth (`scsynth -N`): a constant 1
through each fade, started at 0.1003 s.

| The fade | The Mac (3.14.1) | The norns (3.13.0-dev) |
|---|---|---|
| `Line.kr(0, 1, 0.01)` | 0 for one block, then a ramp. Largest jump 0.0022 | 0.1429 for the whole first block: a jump of 0.1429 |
| `Line.ar(0, 1, 0.01)` | a ramp from 0.0021 | the same |
| `EnvGen.ar(Env([0, 1], [0.01], \sin))` | from 0, flat at its start | the same |
| `EnvGen.kr(Env([0, 1], [0.01]))` | a ramp, one block late | a ramp from the first sample |
| A straight release of 20 ms, as the filter's | freed at 0.0677 | runs down to 0.0011 |
| An S curve release of 50 ms, as the slot's | freed at 0.0005 | runs down to 0.00003 |

So on the norns the line still caught 14% of the edge. The fade is now
`EnvGen.ar(Env([0, 1], [0.01], \sin))`, the same on both.

`test/device/norns_nrt.sh` renders the probe's own scores with the norns's scsynth and
brings the files back. The 42 changes of type, the shared delay and the filter swap:

| On the norns's scsynth | `Line.kr`, plugin | no plugin | `EnvGen.ar`, plugin | no plugin |
|---|---|---|---|---|
| The 42 changes, clicks on both channels | 4 | 6 | 0 | 0 |
| Largest step after a change | 0.0139 | 0.0139 | 0.0005 | 0.0009 |
| The shared delay born under the tone, largest step | 0.0008 | 0.0342 | 0.0008 | 0.0004 |
| Filter, LP to HP at 400 Hz, largest step | 0.0005 | 0.0005 | 0.0005 | 0.0005 |

The filter swap has no step on the norns. The 0.013 is the Mac's early free alone.

## On the norns: the rows

The forty-second change deployed, one RESTART, `count: 198`, `four: FourStretch on`.
The norns had booted on a stale clock, so the services were restarted before the first
measurement. Recordings are in `four-device-recordings/2026-11-17`, outside the repo.

| Row | Result |
|---|---|
| 19.7, 19.10: only what is heard exists | pass |
| 19.8: the filter swap, both channels | pass, no break |
| 19.12: six TYPE taps, four runs | no break in any run. Largest step 0.0008, and the tone alone has about 0.0006. On 2026-11-16: seven breaks, largest step 0.0215 |
| 19.29: the fade rocked across the middle, four runs | no break in any run. Largest step 0.0008. The type changed at each crossing |
| 10.4: the delay's mix raised by E2, and jumped from 0 to 0.4 | no break either way |
| 19.27: the busiest scsynth thread | four PV at pitch 2 56.6%, the dense set 64.5%. The engine of the fortieth change, the same hour: 56.2% and 64.0% |

The rows list holes by the 5 ms law and do not score them. Row 19.12 had one in each
run, at the tap into RESON or under RESON. Row 19.29 had one or two in each run, most of
them under CHORUS with no change near. Nobody has listened to these recordings yet.
