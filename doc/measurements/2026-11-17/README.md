# 2026-11-17: an effect's type change (the forty-second change) and the CPU budget

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

## The CPU budget, part by part (the forty-third change, C5 of the plan)

`python3 test/device/measure.py budget`, on the engine of the fortieth change, before
the forty-second went on. All four tracks hold a take. Each state settles for 3 s and is
then read in four windows of 5 s. "Thread" is the busiest scsynth thread in `top -H`,
the number with the limit of about 60%. "Poll" is the norns poll `cpu_avg`. It is
`Crone.server.avgCPU`, the load of the whole JACK cycle: the two read the same number to
the last digit.

| State | Thread, mean | Largest window | Poll | Added |
|---|---|---|---|---|
| All four tracks OFF | 3.2% | 3.4% | 10.5% | |
| Four PLAY | 10.9% | 11.0% | 16.2% | |
| Four PV at pitch 2, nothing else | 35.4% | 35.5% | 41.8% | |
| The dense voices, nothing else: PV at 1.96 and 2.5, GRAIN at density 200 with sizes 0.29 and 0.5 s | 42.0% | 42.2% | 48.3% | |
| + the reverb (mix 0.5, every send 0.5) | 48.0% | 48.2% | 54.5% | 6.0 |
| + shimmer 0.5 | 48.2% | 48.4% | 54.7% | 0.2 |
| + the delay (mix 0.5, every send 0.5) | 50.9% | 51.0% | 57.5% | 2.7 |
| + drive 0.5 on every track | 53.4% | 53.5% | 60.0% | 2.5 |
| + FLANGE in every first slot | 58.2% | 58.4% | 64.7% | 4.8 |
| + ECHO in every second slot: row 19.27's dense set | 62.4% | 62.4% | 68.8% | 4.2 |
| Four PV at pitch 2 with all of it: row 19.27's other set | 55.9% | 56.1% | 63.0% | |

No state had an xrun. The norns was at 52 C and not throttled.

- Nothing grew between 2026-11-13 and 2026-11-16. The 57.3% of 2026-11-13 was the four
  dense voices inside preset 1, read once over 6 s (2026-11-13/lanes.md). The 64.1% of
  2026-11-16 is row 19.27's set: the same voices with the reverb, shimmer, the delay,
  drive on every track and both effect slots on every track. The voices alone take 42.0%.
- What row 19.27 adds to the voices costs 20.4 points: the reverb 6.0, the delay 2.7,
  drive 2.5 (0.6 a track), four FLANGE 4.8 (1.2 each), four ECHO 4.2 (1.1 each) and
  shimmer 0.2.
- Row 19.27 reads the largest of 11 windows. It came out 1.6 to 2.1 points above the
  means of this table: 64.0% and 56.2% on this engine, the same hour.
- The poll reads 5.3 to 7.3 points above the thread at every load. A header word that
  reads the poll can take the thread's limit plus 6.
- The forty-second change costs at most half a point on row 19.27's sets (56.6% and
  64.5% against 56.2% and 64.0%), which is inside the spread from run to run.

Open: the supported set for the README. It is the user's choice (question 8 of the plan).

## The delay and the reverb leave (the forty-fourth change, C3 of the plan)

Until this change the engine freed the delay or the reverb in the same moment that its
mix reached 0. io plays a return at its mix through a 30 ms lag, so the tail was cut
at its full level. Now the engine frees the synth 0.1 s later, when the return is
100 dB down, and only if the mix did not move again.

Offline (`test/dsp/review/probe6.scd`, `_leave.wav`): io plays a 1 s burst of the tone
into the reverb and into the delay. Under the tail, 0.5 s after the burst, the mix goes
to 0. The table is the Mac's. The norns's scsynth gives the same within 1%.

| The largest step when the mix reaches 0 | Before | After |
|---|---|---|
| The reverb, with the plugin (the room), tail at -38.0 dB | 0.0204, 1 click | 0.0000, 0 clicks |
| The reverb, without it (FreeVerb on the Mac), tail at -60.5 dB | 0.0005 | 0.0000 |
| The delay, with the plugin (the bucket brigade), tail at -26.9 dB | 0.0794, 2 clicks | 0.0004, 0 clicks |
| The delay, without it, tail at -21.7 dB | 0.1149, 2 clicks | 0.0003, 0 clicks |

On the norns, the new row 19.30, on both channels. Track 2 plays the tone into the
effect and stops, and the mix goes to 0 under the tail. Then DRY (K1+K3) while the track
plays into both. "Before" is the forty-second change, the same hour.

| Row 19.30 | Before | After, two runs |
|---|---|---|
| The reverb, tail at -41 dB: largest step | 0.0046 | 0.0002 and 0.0002 |
| The delay, tail at -26 dB: largest step | 0.0181, a break | 0.0007 and 0.0007 |
| DRY while the tone plays (the tone alone has about 0.0006) | 0.0795, a break | 0.0008 and 0.0012 |
| The synth is gone half a second later | yes | yes |
| A reverb mix that comes back after 40 ms keeps its synth | no | yes |

`count: 198`. The rows around it pass on this engine: 10.1 to 10.4 (the delay's node is
gone at a mix of 0, and INF with KILL keeps its loop), 19.21 and 19.28 (the sends), 19.7,
19.12 and 19.29. The 141 xruns the JACK log counted in this hour all fall in the second
of a service restart. Nobody has listened to these recordings yet.

## The effects at each amount (the forty-fifth change)

The user tested the forty-fourth change and found the effects "a bit too bland". The
first step was a number for it. `test/dsp/review/probe7.scd` plays one phrase through
each type at five amounts, at rate 0.5. The phrase is a chord of four saws under a slow
swell, a kick and a tick, the same on both sides. `an_probe7.py` reads each lane against
the phrase alone, from 1 s to 9 s:

- "Level" is the lane's RMS over the phrase's.
- "Moved" is the mean distance in dB between the two spectra, over every 43 ms frame and
  every band that sounds in either. A gain of 3 dB and nothing else reads 3. The lane is
  first moved back by the delay its type has at amount 0 (WOBBLE 12 ms, FLANGE 1.4 ms),
  so a late copy alone reads 0.

A slot starts at amount 0.5. With the plugin, on the Mac. The norns's own scsynth
renders the same numbers within 0.06 dB (`test/device/norns_nrt.sh`). WOBBLE's wow is
partly random, and it is the only type that differs.

| Moved, dB | 0.25 before | after | 0.5 before | after | 0.75 before | after | 1 before | after |
|---|---|---|---|---|---|---|---|---|
| CHORUS | 1.2 | 2.6 | 2.3 | 3.4 | 3.2 | 4.0 | 3.9 | 4.4 |
| FLANGE | 1.4 | 2.5 | 2.5 | 3.2 | 3.3 | 3.9 | 4.4 | 4.9 |
| WOBBLE | 1.8 | 3.1 | 3.1 | 4.5 | 4.0 | 5.4 | 4.6 | 5.4 |
| RESON | 3.1 | 3.2 | 6.4 | 4.7 | 9.3 | 7.8 | 8.5 | 8.4 |
| RING | 3.0 | 3.4 | 5.3 | 5.2 | 6.7 | 6.4 | 7.3 | 7.3 |
| ECHO | 1.6 | 3.0 | 3.0 | 4.1 | 4.3 | 4.9 | 5.5 | 5.5 |

| Level against the phrase, dB | 0.25 before | after | 0.5 before | after | 0.75 before | after | 1 before | after |
|---|---|---|---|---|---|---|---|---|
| CHORUS | -0.3 | +0.4 | -0.3 | +1.0 | +0.1 | +1.1 | +0.6 | +1.3 |
| FLANGE | +0.3 | +2.1 | +1.5 | +3.0 | +3.7 | +3.6 | +7.0 | +3.6 |
| WOBBLE | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 |
| RESON | -2.6 | +0.7 | -3.0 | +3.4 | +1.2 | +5.3 | +6.3 | +6.7 |
| RING | -2.2 | +0.1 | -4.2 | +0.1 | -4.6 | 0.0 | -3.0 | 0.0 |
| ECHO | +0.2 | +1.0 | +1.0 | +2.1 | +2.4 | +3.5 | +5.5 | +5.5 |

- CHORUS and FLANGE moved the phrase least at 0.5. They and ECHO now move it at 0.5
  about as far as the old knob did at 0.75, and WOBBLE as far as the old knob's top.
- RESON and RING were under the phrase at 0.5, by 3.0 and 4.2 dB. Part of what they
  "moved" was that loss. RESON at 0.5 was half of the dry sound and half of the ring. It
  now is the whole dry sound with the ring on it, so it moves the spectrum less and
  drops nothing.
- FLANGE's top was 7 dB over the phrase and is 3.6 dB. On white noise the top was
  +0.3 dB and is -3.1 dB (probe 1).
- The largest peak with the plugin is 0.68, where the phrase peaks at 0.35 (0.98 before,
  FLANGE's top). Without the plugin FLANGE is a bare comb and peaks at 1.19 (1.75).
- CHORUS bends the pitch by 29 cents at amount 0.5 and by 45 at the top of both knobs.
  WOBBLE bends it by 97 to 99 cents at the top, and by 46 to 49 at rate 0, where the
  line's room is the limit (`an_engine.py`).

On the norns, `count: 198`, gate row 19.11: track 2 plays the tone of 220, 331 and
442 Hz, and each type runs at amount 0.5 and rate 0.5. The level against OFF, left
channel:

| Row 19.11 | Before | After |
|---|---|---|
| CHORUS | -1.2 dB | +1.1 dB |
| FLANGE | +0.1 dB | +1.1 dB |
| WOBBLE | 0.0 dB | -0.1 dB |
| RESON | -7.2 dB | -1.2 dB |
| RING | -4.3 dB | -0.1 dB |
| ECHO | -0.2 dB | -0.5 dB |

The tone is off RESON's note (C4 at rate 0.5), so its ring is weak there, and half of
the dry sound was all that came out.

The rows around it, on this engine: 19.12 (six TYPE taps) has no break, and its largest
step is 0.0013. 19.29 (the fade rocked across the middle) has no break, and its largest
step is 0.0012. The tone alone has about 0.0006, and the forty-second change read
0.0008: a stronger effect moves the samples more. Rows 19.1, 19.7, 19.10, 19.13 and
19.30 pass.

Row 19.11's "largest change against OFF" read a band at 884 Hz, where the tone has no
partial. That band's floor moved from -132 dB to -95 dB between two runs, and the row
printed 3 to 60 dB for the same effect. It now reads only the bands that sound in OFF.

### What the stronger effects cost

`measure.py budget` again, three times: the morning's table above (the old laws), a
first version of the new laws, and the final one. The first version held nine more
control-rate operators in FLANGE and four more in ECHO.

| State, thread mean | The old laws, morning | First version | Final |
|---|---|---|---|
| The dense voices, nothing else | 42.0% | 42.2% | 42.7% |
| + the reverb, shimmer, the delay, drive on every track | 53.4% | 53.8% | 54.4% |
| + FLANGE in every first slot | 58.2% | 59.0% | 59.3% |
| + ECHO in every second slot: row 19.27's dense set | 62.4% | 63.5% | 63.3% |
| Four FLANGE add | 4.8 | 5.2 | 4.9 |
| Four ECHO add | 4.2 | 4.5 | 4.0 |
| Four PV at pitch 2 with all of it | 55.9% | 57.2% | 56.8% |

- The eight slots cost 9.0 points with the old laws, 9.7 with the first version and 8.9
  with the final one. One control-rate operator costs about 0.01% of the scsynth thread
  for each synth that holds it.
- The final laws hold the same number of UGens as the old ones: `four_fx_mod` 85,
  `four_fx_flange` 31, `four_fx_reson` 41 and `four_fx_echo` 20. `four_fx_ring` has 21,
  one more, for the sine's level. check_dsp.sh holds the counts.
- The states under the effects read 1.0 point more in the last run than in the morning.
  The norns was at 62 C, not throttled, against 52 C in the morning. Row 19.27 read
  57.8% and 65.7% on the first version (56.6% and 64.5% in the morning). It was not run
  again on the final one.
- No state had an xrun.

Nobody has listened to this change yet.

## The tape (the forty-sixth change)

The user: "I think the tape is not working. I don't know how can I record the tape."
The tape recorded, and its source was the line input alone. A fresh script, on the norns:

| A pass of 3 s on TAPE (K2, wait, K2) | `cut_source` | The tape plays back at |
|---|---|---|
| A tone at the input, no track | 0, DRY (the old default) | -17.1 dB |
| Track 1 plays, the input is silent | 0, DRY | -92.6 dB, and the page said `EMPTY - K2 REC` |
| Track 1 plays, the input is silent | 1, WET | -27.7 dB |

After the change `cut_source` starts at 1. Gate row 19.31, track 2 plays the tone and
the input is silent:

| Row 19.31 | The WET pass (a fresh script) | The DRY pass (K1+E3 down) |
|---|---|---|
| The tape plays back at | -17.2 dB | -92.6 dB |
| Silent frames counted while it recorded | 0 | 47 |
| The page while it recorded | `SRC WET`, REC | `SRC DRY`, REC, `NO SOUND - K1+E3 SOURCE` |
| The page at the stop | the loop | `NO SOUND RECORDED` |

The screens are `screens/19.31_*.png`.

The first run of the row failed, and it showed a second fault. The head runs on over the
60 s of tape while nothing records. That pass began 2 s before the tape's end and crossed
it. The tape's law then keeps the whole 60 s as the loop, so the 3 s of sound play once a
minute. A pass of 8 s crosses the end one time in seven.

### A new take starts at the tape's start (the forty-eighth change)

A REPLACE pass now puts the head at the tape's start before it records. Row 19.31 arms
its WET pass with the head 2 s before the tape's end, on purpose:

| Row 19.31, the WET pass | Before | After |
|---|---|---|
| The head at the arm | 0.974 of the tape | 0.974 |
| The loop when the pass closes | 0 to 1: the whole tape | 0 to 0.062: its first 3.7 s |
| The tape plays back, in the next 2 s | -180 dB: silence | -17.3 dB |

softcut reports its head every 25 ms, and a report from the old place can arrive after
the jump. The script drops up to three such reports. A loop from 30 to 36 s, the head
in it, and a pass that closes soon after it opens. A right result gives the loop back:

| A pass that closes | With the guard | With the guard taken away |
|---|---|---|
| 0 ms after it opens | 12 of 12 right | not run |
| 10 ms | 12 of 12 | 18 of 20: two kept the whole tape |
| 20 ms | not run | 18 of 20: two kept the whole tape |
| 30 ms | 12 of 12 | 20 of 20 |
| 60 ms and 120 ms | 24 of 24 | not run |

The older tape rows pass on this script: 7.1 and 7.2 (the tape in a PSET), 11.2d (the
first pass loops, at -17.2 dB) and 12.6 (a loop of 0.3 s under a seam of 0.4 s).

The norns had booted on a stale clock (09:14), and the time sync moved it to 20:36. sclang
then took 98% of a core and matron 108%, as on 2026-11-06. A restart of the services
cleared it. All of this page's evening numbers are from after that restart.
