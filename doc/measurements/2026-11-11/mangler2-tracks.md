# mangler2: two engine tracks, measured 2026-11-11

The take was empty. GRAIN at density 80, WARP at 8 overlaps. "thread" is the busiest scsynth thread in `top -H` (the budget is about 60%); "jack avg" is `Crone.server.avgCPU`, the whole JACK cycle. About 10 s per state.

```
t1 PLAY, t2 OFF                            thread   6.5%  jack avg  18.6  peak  18.9  synths 11  xruns +0
t1 GRAIN, t2 OFF                           thread  10.5%  jack avg  18.7  peak  18.8  synths 11  xruns +0
t1 GRAIN, t2 GRAIN                         thread  15.0%  jack avg  18.9  peak  18.9  synths 12  xruns +0
t1 GRAIN, t2 WARP (8 overlaps)             thread  12.7%  jack avg  18.7  peak  18.7  synths 12  xruns +0
t1 GRAIN, t2 PV                            thread  12.2%  jack avg  19.3  peak  19.4  synths 12  xruns +0
t1 GRAIN, t2 PLAY                          thread  11.2%  jack avg  18.7  peak  18.9  synths 12  xruns +0
t1 PV, t2 PV                               thread   9.2%  jack avg  19.4  peak  19.9  synths 12  xruns +0
t1 WARP, t2 WARP (8 overlaps)              thread  10.8%  jack avg  19.1  peak  19.4  synths 12  xruns +0
t1 GRAIN, t2 GRAIN, reverb+shimmer+delay   thread  30.0%  jack avg  33.3  peak  33.4  synths 14  xruns +0
t2 filter HP, resonance 0.8                thread  30.2%  jack avg  33.7  peak  34.1  synths 14  xruns +0
after cycling t2 modes, synths: 14
```
