# Lanes, the second effect slot and the grain cap (four, twelfth change)

Device: norns shield, Pi 4. 2026-11-13, after a restart. `count: 197`. Preset 1, all
four tracks in the same voice, the scsynth audio thread over 6 s. No row had an xrun
unless it says so.

| Four tracks of | Before (tenth change) | Lanes |
|---|---|---|
| OFF | 20.3% | 17.3% |
| PLAY, pitch 1 | 36.0% | 25.2% |
| PLAY, pitch 1.5 | 41.0% | 29.9% |
| WARP, pitch 1 | 39.4% | 30.3% |
| WARP, pitch 2 | 47.1% | 37.7% |
| PV, pitch 1 | 48.6% | 45.0% |
| PV, pitch 2 | 64.1% | 53.0% |
| PV, pitch 0.5 | 45.8% | 36.3% |
| GRAIN, density 20, size 0.1 s | 39.0% | 29.6% |
| PLAY, two tracks with both slots on | | 29.7% |

The engine had 1393 UGens with four tracks playing. It has 500 now, and 534 with two
effect slots on.

## The dense cloud

The user's set reached 100%: two PV tracks (pitch 1.96 and 2.5) and two GRAIN tracks
with density near 200 and sizes of 0.29 and 0.5 s. One grain pair costs 0.27% of the
thread (measured: 6 pairs +1.1%, 17 pairs +4.1%), and that set asked for about 160.

| State | No cap | Cap 64 | Cap 32 |
|---|---|---|---|
| Four GRAIN tracks, density 200, size 0.5 s | | 90.7%, 268 xruns | 60.6%, 0 xruns |
| Two PV at pitch 2 and 2.5, two such GRAIN | 100% (the user) | | 59.8%, 0 xruns |

## Each part works

Tracks 1 and 3, in PLAY, 3 s captures: every effect type changes the sound in slot 1,
slot 2 adds to it, HP, BP and LP act, drive and crush act, and the synth count goes
from 22 to 24 and back to 22 as slots go on and off.

## The fourteenth change: our own cloud, the new flanger, ECHO

`FourGrain` against two stock `GrainBuf` on the same inputs, rendered offline
(`test/dsp/grain_eq.scd`): the stock grain equals the written law to -139 dB when its
start place is rounded to a float, as `GrainBuf` rounds it. Ours equals the law to
-146 dB with the exact place. The first grain of a synth differs by one sample: the
stock UGen runs one sample at its start and keeps the step.

Cost of a grain pair on the norns: stock 0.27% of the thread, ours 0.17%.

After a restart, `count: 197`, with captures running (a capture adds a few xruns):

| State | Thread |
|---|---|
| Preset 1 as it loads | 18.3% |
| Four GRAIN tracks, density 20, size 0.1 s | 26.1% |
| Four GRAIN tracks, density 200, size 0.5 s (cap 48) | 57.3% |
| Two PV at pitch 2 and 2.5, two such GRAIN | 57.3%, 0 xruns |
| Track 1 PLAY | 17.8% |
| Track 1 PLAY with FLANGE | 18.6% |
| Track 1 PLAY with ECHO | 18.4% |

With a cap of 128 the four dense clouds took 95%, so the cap is 48.
