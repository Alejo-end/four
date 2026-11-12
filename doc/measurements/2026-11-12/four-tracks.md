# mangler2: four engine tracks and the sends, measured 2026-11-12

Preset 1 loaded (its take, layers, pads and LFO running). GRAIN at density 80, WARP at 8 overlaps, each extra track on its own quarter of the take. "thread" is the busiest scsynth thread in `top -H` (the budget is about 60%); "jack" is `Crone.server.avgCPU`, the whole JACK cycle. About 10 s per state.

## First build: the three strips always on

```
1 track PLAY, no FX                                  thread  24.2%  jack  27.6  peak  27.8  synths 14  xruns +0
4 tracks GRAIN (density 80), no FX                   thread  42.2%  jack  45.5  peak  46.3  synths 17  xruns +0
4 tracks GRAIN + reverb, shimmer, delay              thread  44.0%  jack  47.7  peak  47.7  synths 18  xruns +0
4 tracks PV + FX                                     thread  33.2%  jack  37.0  peak  37.1  synths 18  xruns +0
4 tracks WARP (8 overlaps) + FX                      thread  35.8%  jack  39.8  peak  40.1  synths 18  xruns +0
GRAIN, WARP, PV, PLAY + FX                           thread  36.0%  jack  39.2  peak  39.5  synths 18  xruns +0
...+ send ring 1>2>3>4>1 at 0.5                      thread  39.5%  jack  42.4  peak  42.5  synths 18  xruns +0
...+ all 12 sends at 0.3                             thread  40.1%  jack  43.3  peak  43.3  synths 18  xruns +0
4 GRAIN + FX + all sends + filters resonant          thread  48.2%  jack  51.8  peak  51.9  synths 18  xruns +0
soak 60 s heaviest state: xruns + 0  jack 56.830986022949 temp temp=52.1'C
rest synths: 18
```

## After: a strip runs only while its track plays or a send feeds it

```
1 track PLAY, others OFF, no FX                      thread  18.8%  jack  21.7  xruns +0
1 track GRAIN, no FX                                 thread  22.9%  jack  26.0  xruns +0
2 tracks GRAIN, no FX                                thread  29.4%  jack  32.8  xruns +0
4 tracks GRAIN, no FX                                thread  42.8%  jack  45.8  xruns +0
4 tracks GRAIN + reverb, shimmer, delay              thread  44.5%  jack  48.1  xruns +0
+ all 12 sends 0.3 + resonant filters                thread  48.2%  jack  51.6  xruns +0
soak 60 s heaviest: xruns + 0  jack 55.208522796631 temp=54.0'C
back to rest: 1 track PLAY                           thread  18.5%  jack  22.0  xruns +0
track 1 PLAY sent into OFF track 3 (filter as an FX) thread  21.7%  jack  24.6  xruns +0
```

Pausing idle strips saved about 6% of the thread at rest. Each GRAIN track adds about 6.5%. The heaviest state (four GRAIN tracks, reverb, shimmer, delay, all twelve sends, resonant filters) ran 48% on the thread with 0 xruns over 60 s, at 54 C. That is under the 60% line with about 12 points to spare: a fifth source (more pad voices, a second shimmer) could cross it.
