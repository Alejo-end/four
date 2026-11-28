# 2026-11-28: what is not in use costs nothing (the eighty-first and eighty-second changes)

On the norns, `count: 199`, `four: FourStretch on`, over JACK. "Before" is proposal A (the
seventy-ninth change), "after" is branch `perf` (the eighty-second change), the same hour.
`python3 test/device/measure.py budget`, the busiest scsynth thread in `top -H`, means of
four windows of 5 s. No state had an xrun.

| State | Before | After | Change |
|---|---|---|---|
| All four tracks OFF | 3.7% | 2.2% | -1.5 |
| Four PLAY | 11.3% | 6.0% | -5.3 |
| Four PV at pitch 2, nothing else | 36.1% | 29.4% | -6.7 |
| The dense voices, nothing else | 43.1% | 36.8% | -6.3 |
| + the reverb (mix 0.5, every send 0.5) | 49.5% | 41.6% | -7.9 |
| + shimmer 0.5 | 49.6% | 42.9% | -6.7 |
| + the delay | 52.5% | 45.8% | -6.7 |
| + drive 0.5 on every track | 55.2% | 48.5% | -6.7 |
| + FLANGE in every first slot | 59.9% | 53.6% | -6.3 |
| + ECHO in every second slot: row 19.27's dense set | 64.2% | 57.7% | -6.5 |
| Four PV at pitch 2 with all of it: the supported set | 58.0% | 51.0% | -7.0 |

- The open filters are most of it: every lane sat at LP 20 kHz here, so each one ran a copy in
  place of DFM1. About 1.3 points a lane.
- The reverb now adds 4.8 points (6.4 before), and shimmer 0.5 adds 1.3 (0.1 before): the
  shimmer is paid for only when it is up.
- The dense set is under the limit of about 60% for the first time. The supported set has
  9 points of room.

The lifecycle, read on the engine:
- A cutoff of 1000 Hz swaps to `four_filt_lo` at once. Back at 20 kHz the lane is still LO
  after 0.2 s and OPEN after 0.7 s (the wait is 0.3 s).
- `send_2_1` at 0.5 makes track 1's send synth. At 0 it is still there after 0.3 s and gone
  after 0.9 s.
- The shimmer synth exists while the reverb plays and shimmer is above 0. At shimmer 0 it
  goes between 0.05 and 0.55 s later, and it goes with the reverb.
- The meter is paused on TAKE, runs on TRACKS, and pauses again 2.5 s after TAKE.

Gate rows: 19.7, 19.8 and 19.9 pass, 19.12 has no break. Stage 22: 22.1, 22.2, 22.3, 22.5
and 22.8 pass. 22.4: each meter reads within 0.4 dB of the output's peak. 22.6: on TRACKS the
meters cost 0.27 points. 22.7 needs ears.

Not heard: the open filter without DFM1's faint third harmonic.

## The room a block at a time (the eighty-fourth change)

The same tool later that day, with the plugin built on the norns that morning (`Room::process`).
"Before" is the eighty-second change's "after", above.

| State | Before | After | Change |
|---|---|---|---|
| All four tracks OFF | 2.2% | 2.0% | -0.2 |
| Four PLAY | 6.0% | 6.1% | +0.1 |
| Four PV at pitch 2, nothing else | 29.4% | 30.0% | +0.6 |
| The dense voices, nothing else | 36.8% | 37.4% | +0.6 |
| + the reverb (mix 0.5, every send 0.5) | 41.6% | 40.7% | -0.9 |
| + shimmer 0.5 | 42.9% | 42.0% | -0.9 |
| + the delay | 45.8% | 45.0% | -0.8 |
| + drive 0.5 on every track | 48.5% | 47.5% | -1.0 |
| + FLANGE in every first slot | 53.6% | 52.7% | -0.9 |
| + ECHO in every second slot: row 19.27's dense set | 57.7% | 56.6% | -1.1 |
| Four PV at pitch 2 with all of it: the supported set | 51.0% | 50.0% | -1.0 |

- The reverb's own step is 3.3 points (4.8 before): 1.5 points less. The states without the
  reverb read up to 0.6 points more, which is the spread between two runs, so the saving on a
  set with the reverb is about 1 to 1.5 points.
- The output is the same, sample for sample (ugen/test_core.cpp, on the Mac and on the norns),
  so nothing here needs ears.

## The delay: tried, not kept

THE BUCKET BRIGADE (`BBDDelay`, two FourBBD units in `\four_delay`) costs 2.8 points. Timed on
the norns's CPU, one channel, 20 s of noise, AGE 0.25 as the engine sets it: 0.37 s at a
TIME of 0.1 s, 0.27 s at 0.3 s (the default) and 0.21 s at 1 s. AGE alone is 0.11 s of that.
Three rewrites, none of them kept:

- The gains of the two fixed steps (a whole sample, a whole tick) computed once in
  `setClock`, so a sample with no tick divides nothing. Bit for bit the same, and 5% faster at
  0.3 s (12% at 1 s): about 0.15 points.
- The steps of their own length (the first tick in a sample, the rest after the last) from a
  table and a series in place of exp, sin, cos and four divisions. The same output in every
  test, and no faster at 0.1 s and 0.3 s: on the norns glibc's exp takes 30 ns and sincos
  54 ns, and those calls were not the cost.
- The two channels in one loop: 8 to 12% faster, bit for bit, but it needs a stereo FourBBD
  and an engine change.
- AGE's two envelopes in float: 11% faster, and the output changes by up to -28 dB, so no.

The cost is spread over the chain's double arithmetic. Each gain is small, and none of them is
worth a plugin build and a RESTART alone.
