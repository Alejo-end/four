# FourStretch on the norns (four, eighth change)

Device: norns shield, Pi 4, 32-bit. 2026-11-13. Preset 1, all four tracks in the
same voice. Each row is `top -H` over 6 s for the scsynth audio thread, then
avgCPU and peakCPU, then the xruns in that window. The budget is 60% of the thread.

## The build

- The SuperCollider headers are on the norns: `/usr/local/include/SuperCollider`.
- `ugen/test_core.cpp` built on the norns prints `all passed` (41 checks).
- `FourStretch.so` loads. The log says `mangler: FourStretch on`. The count is 185.
- With the binary absent the log says `FourStretch absent` and the count is 185.

## The cost

| Four tracks of | Stock voices | Plugin, first build | Plugin, FFTW build |
|---|---|---|---|
| OFF | 21.6% | 21.6% | 21.4% |
| PLAY, pitch 1 | 41.8% | 41.4% | 41.5% |
| PLAY, pitch 1.5 | 42.7% | 52.4% | 50.5% |
| WARP, pitch 1 | 44.5% | 45.8% | 45.8% |
| WARP, pitch 2 | 44.4% | 60.0% | 60.0% |
| PV, pitch 1 | 47.8% | 58.7% | 53.4% |
| PV, pitch 2 | 48.0% | 85.1%, 295 xruns | 72.3%, 3 xruns |
| PV, pitch 0.5 | 47.6% | 55.8% | 52.5% |
| GRAIN | 43.3% | 43.2% | 43.4% |

All other rows had 0 xruns. The first plugin run also recorded each state with
`jack_rec`, and that recording caused 2 to 10 xruns in a row. The other two runs
did not record.

"Stock voices" is the same engine file with the binary absent. Its PLAY row is the
exact read head of the sixth change: four PLAY tracks cost 41.8%.

## What the numbers say

- The pitch 1 states fit. Four PV tracks cost 5.6 points more than the stock PV.
- A pitched voice costs more because the stretch runs `pitch` samples for each
  sample of output, and the resampler computes 32 weights for each sample.
- Four PV tracks at pitch 2 do not fit. Four WARP tracks at pitch 2 sit on the limit.

## Where the time goes (plain C++ on the norns, one track, script loaded)

| Part | Share of a core |
|---|---|
| PV, one hop of work at pitch 1 | 2.4% |
| of that, the five transforms (FFTW) | 1.1% |
| of that, the phase work | 0.6% |
| Resampler at pitch 1 (pass-through) | 0.13% |
| Resampler at pitch 2 | 3.2% |
| of that, the 32 kernel weights | 2.1% |

Our own transform took 70 us for each frame. FFTW takes 21 us.

## After the ninth change (the same day)

The same measurement, after the exact kernel, the buffer read without a division
and the fast tanh. No row had an xrun.

| Four tracks of | Stock voices | FFTW build | Ninth change |
|---|---|---|---|
| OFF | 21.6% | 21.4% | 20.3% |
| PLAY, pitch 1 | 41.8% | 41.5% | 36.0% |
| PLAY, pitch 1.5 | 42.7% | 50.5% | 41.0% |
| WARP, pitch 1 | 44.5% | 45.8% | 39.4% |
| WARP, pitch 2 | 44.4% | 60.0% | 47.1% |
| PV, pitch 1 | 47.8% | 53.4% | 48.6% |
| PV, pitch 2 | 48.0% | 72.3% | 64.1% |
| PV, pitch 0.5 | 47.6% | 52.5% | 45.8% |
| GRAIN | 43.3% | 43.4% | 39.0% |

One track in plain C++ on the norns (a quiet core): PV 2.1% at pitch 1 and 5.0% at
pitch 2, WARP 1.0% and 2.9%. The resampler at pitch 2 fell from 3.2% to 1.0%.

What each UGen of a track costs, measured with eight copies on the audio thread:

| Eight of | Thread |
|---|---|
| `tanh` (the C library) | 3.4 to 4.0% |
| DFM1 | 3.3% |
| CombC | 1.4% |
| the crusher | 1.4% |
| RLPF | 1.2% |

A track has six `tanh` channels, four DFM1, four CombC and two crushers, and all of
them run whatever the knobs say. Four PV tracks at pitch 2 are still over the budget.
