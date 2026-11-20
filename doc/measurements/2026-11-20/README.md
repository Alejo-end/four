# 2026-11-20: the effect glide (the fifty-sixth change) and the supported set

The engine of the fifty-sixth change, `count: 198`, the plugin on (`four: FourStretch on`).
The Lua is the `phase-a` checkout, with the autosampler (the fifty-fifth change). The
norns was at 58 C and not throttled. Results are in gate.jsonl.

| Row | Result |
|---|---|
| 19.11 | Levels against OFF in dB: CHORUS 1.1, FLANGE 1.0, WOBBLE 0.0, RESON -1.2, RING 0.0, ECHO -0.5 (as before) |
| 19.12 | Six TYPE taps over a tone: no break, largest step 0.0013 (the tone alone 0.0006), no hole on either channel |
| 19.29 | A fade from CHORUS to ECHO rocked across the middle: no break, largest step 0.0008, one hole on the right at 2.06 s (CHORUS's comb) |
| 19.27 | The busiest scsynth thread over 60 s, see below |

Row 19.27, the supported set (four PV at pitch 2, FLANGE and ECHO, drive, both sends, the
delay, the reverb and shimmer) and the dense set:

| Engine | Run | Supported set | Dense set |
|---|---|---|---|
| fifty-sixth change | right after the restart and rows 19.11, 19.12, 19.29 | 62.2%, no xrun | 69.1%, 2 xruns |
| fifty-sixth change | the next run | 57.6%, 1 xrun | 65.1%, 2 xruns |
| fifty-third change | after a restart | 56.9%, no xrun | 61.6%, 1 xrun |
| fifty-sixth change | after a restart | 54.8%, no xrun | 62.0%, no xrun |
| fifty-sixth change | the next run | 53.6%, no xrun | 61.8%, no xrun |

The glide costs nothing that this row can see: the two engines read the same within the
run-to-run spread. The spread itself is large (54 to 62% for one set), and the first run
after other rows reads highest. The supported set sits 2 to 6 points under the limit.
