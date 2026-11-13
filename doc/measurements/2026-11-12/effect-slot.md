# The effect slot (four, third change)

Device: norns shield, Pi 4. 2026-11-12, after a restart of the four services.

- sclang: `compile done`, no errors. maiden: `count: 185`.
- Each type changes the output. Preset 1, track 1 in PLAY, amount 0.7, rate 0.5,
  3 s of `SuperCollider:out_1/2` for each type:

| type | RMS | peak | zero crossings per second | left to right correlation |
|---|---|---|---|---|
| OFF | 0.237 | 0.920 | 612 | +0.994 |
| CHORUS | 0.233 | 0.920 | 598 | +0.677 |
| FLANGE | 0.160 | 0.920 | 993 | +0.599 |
| WOBBLE | 0.364 | 0.920 | 588 | +0.584 |
| RESON | 0.077 | 0.349 | 477 | +0.957 |
| RING | 0.150 | 0.920 | 884 | +0.985 |

  The captures are not at the same place in the loop, so the RMS column moves
  with the material. The peak of RESON is the one clear level difference: it is
  about 8 dB under the others.
- Cost, four tracks in GRAIN (`top -H` over 4 s, and avgCPU / peakCPU):
  - effects OFF: scsynth thread 42.7%, 47.9 / 48.6
  - RESON on all four: 42.8%, 48.0 / 48.7
  - CHORUS on all four: 43.3%, 48.1 / 49.2

  The slot runs all the time in every live track, so OFF costs the same as on.
  Against the 45% of color-space-mods.md the slot adds no cost that the
  measurement can see.
- xruns: 3 in the run. The run loaded preset 1 twice, and a preset load is the
  known source (doc/plan.md, Phase 3).
- A preset saved before this change does not name the effect params. A load of
  it leaves each track's effect where it was.

## RESON after the level fix (four, fifth change)

The gain law's power went from 0.5 to 0.25. After a restart (`count: 185`), preset 1,
track 1 in PLAY, 8 s of `SuperCollider:out_1/2` for each row:

| state | RMS | peak |
|---|---|---|
| OFF | -13.4 dB | -1.4 dB |
| RESON, amount 0.3, rate 0.5 | -14.3 dB | -3.2 dB |
| RESON, amount 0.7, rate 0.5 | -17.6 dB | -5.3 dB |
| RESON, amount 1.0, rate 0.5 | -11.0 dB | -0.7 dB |
| RESON, amount 0.7, rate 0.1 | -12.1 dB | -1.9 dB |
| RESON, amount 0.7, rate 0.9 | -11.7 dB | -2.1 dB |

RESON now sits within about 4 dB of the dry signal. Before the fix, amount 0.7 at rate
0.5 had a peak about 8 dB under it. The level moves with the note, because a comb rings
more when the material holds its pitch.

Nobody has listened yet.
