# The GRAIN granulator (mangler2, tenth change)

Device: norns shield, Pi 4. 2026-11-12. Count: 173. Every capture is 6 s of
`SuperCollider:out_1/2`, recorded with `jack_rec` before crone. The system
output level was at -inf, so crone's outputs were silent. The take is
a loop of the album set, which is mono in effect: PLAY has an L/R correlation of 1.00.
"quiet" is the share of 10 ms blocks below -50 dBFS. "lim" is the share of
blocks that peak above 0.88: the master limiter sits at 0.92.

| state | level dB | lim | quiet | corr |
|---|---|---|---|---|
| PLAY | -14.1 | 0% | 0% | 1.00 |
| old GRAIN, Poisson (before the change) | -13.9 | n/a | 18% | 0.91 |
| GRAIN default (size 0.1, density 20, jitter 0) | -14.9 | 0% | 0% | 0.90 |
| GRAIN, grain jitter 1 (Poisson, the old timing) | -12.6 | 9% | 8% | 0.93 |
| GRAIN dense (density 150, size 0.2) | -13.4 | 1% | 0% | 0.91 |
| GRAIN sparse (density 3, size 0.05) | -19.4 | 3% | 83% | 0.96 |
| GRAIN, spray 0.5 | -14.3 | 1% | 0% | 0.90 |
| GRAIN, frozen head | -15.5 | 0% | 0% | 0.91 |
| CLOUD (Clouds, after the -6 dB trim) | -13.2 | 0% | 0% | 0.97 |
| CLOUD before the trim | -8.2 | n/a | 0% | 0.99 |

- The old GRAIN row is the first, plain-Dust version of the new def. On this take
  the old two-cloud def was not measured, because Clouds ran instead of it.
- The node tree shows `mangler2_grain` for GRAIN and `mangler2_clouds` for CLOUD.
- A held GRAIN pad (`mangler2_voice_grain`) over PLAY sounds, at -12.2 dB, with
  0% limiter.
- CPU: four GRAIN tracks at density 60 and size 0.2, with the delay and reverb,
  took 44.6% of the scsynth thread, with 0 xruns over 35 s.

Nobody has listened yet. These numbers say the cloud is now continuous and at
PLAY's level, and that it does not drive the limiter. They do not say whether
it sounds good.
