# The DSP review (2026-11-15)

Offline, on the Mac. Nothing ran on the norns. Every render is the real
`lib/Engine_Four.sc`, built twice: with no plugins (the stock voices) and with the
FourStretch plugin built for the Mac. sc3-plugins and mi-UGens are not on the Mac,
so DFM1, JPverb and MiClouds take their fallbacks in every render. The DFM1 figures
below come from its source (sc3-plugins, `source/TJUGens/Dfm1.cpp`), read and
worked by hand. Nobody rendered DFM1. The norns has sc3-plugins, so the device
plays the DFM1 path.

## Method

- `test/dsp/review/run_probe.sh <work> <tag> <probe.scd>` compiles the engine with
  the stand-in CroneEngine and renders a score of the engine's own SynthDefs
  (`probe1.scd` to `probe5.scd`). `an_probe1.py`, `an_probe2.py` and `an_probe4.py`
  measure the renders. Set `FOUR_PLUGIN_DIR` for the plugin build.
- The work folder needs `test/dsp/mkbuf.py` and `test/dsp/review/mkbuf_review.py`,
  run inside it. Python needs numpy, scipy and soundfile, for example
  `uv run --with numpy --with scipy --with soundfile python`.
- `test/dsp/check_dsp.sh <work>` runs probes 1 to 4, engine.scd and
  `core_probe2.cpp`, and checks the fixes and the checklist of doc/dsp-plan.md with
  one PASS or FAIL verdict. Set `FOUR_PLUGIN_DIR` for the plugin build too. Both
  builds take about 30 s. probe4's job r renders the drive row (5 kHz, full drive).
- `core_probe.cpp`, `core_probe2.cpp` and `bbd_time.cpp` measure
  `ugen/four_core.h` directly (`clang++ -O2 -std=c++17 -I<repo>/ugen`).
- Mac to Pi: `ugen/bench_core.cpp` gives the room 0.23% of a Mac core, and the
  norns measured 4.2%. PV is 0.61% against 2.1%, WARP 0.15% against 1.0%. So a Mac
  figure is 3 to 18 times smaller than the Pi's. Every Pi cost below is an estimate
  from that range.

## Fixed in the twenty-second change

| What | Before | After |
|---|---|---|
| A GRAIN pad at density 20: its first sound after the press | 51 ms | 1.2 ms |
| A GRAIN pad at density 4 | 251 ms | 1.0 ms |
| GRAIN after a mode change, density 20: below -60 dBFS | from 20 to 52 ms | never |
| Erosion of a 5 kHz take, erode 1 for 12 s: noise under the tone, window at 3, 18, 30, 54 s | -141, -141, -18, -22 dB | -141 dB at all four |
| FourBBD, Mac, ns a sample, clock 192 kHz (43 ms), 82 kHz (0.1 s), 27 kHz (0.3 s) | 78.5, 41.3, 22.4 | 43.9, 35.8, 23.8 |
| The engine's delay synth, old against new plugin, a click and a tone at four times | | identical, bit for bit |

The first grain: `CoinGate` takes its input's first value as the trigger it last
saw, so it never passed `Impulse`'s first impulse. The erosion head counted a float
from 0 to 1: past the middle of the buffer it landed up to 0.17 frame off and read
and wrote some frames twice. The BBD computed three transcendental functions for
every tick. Every tick but the first in a sample has the same length.

## The filter

The open filter, 20 kHz and resonance 0, runs a filter synth on every track. It is
not a bypass on either path.

| Path | 1 kHz | 5 kHz | 10 kHz | 16 kHz | 19 kHz |
|---|---|---|---|---|---|
| Stock (RLPF), rendered | -0.3 dB | -4.5 dB | -10.1 dB | -16.9 dB | -21.4 dB |
| Stock at 19 kHz (the purity mark's limit) | -0.2 dB | -3.5 dB | -8.6 dB | -15.2 dB | -19.7 dB |
| Candidate: `BLowPass` (RBJ), rq 1.414, rendered | 0.0 dB | 0.0 dB | 0.0 dB | -0.2 dB | -1.4 dB |

DFM1, from its source: the input reaches the ladder at 0.5 x 1.579 = 0.789. The
ladder clips it at 1 and shapes it by z - z^3/3. It leaves at x 1.425. The
small-signal gain is +1.02 dB (the device measured +1.0, which the trim of 0.891
removes).

| Input | Gain | Third harmonic |
|---|---|---|
| -12 dBFS | -0.07 dB | -49.6 dB |
| -6 dBFS | -0.33 dB | -37.3 dB |
| 0 dBFS | -1.45 dB | -24.2 dB |
| +2 dBFS | -2.44 dB | -19.2 dB, and the hard clip starts |

Slopes and resonance. DFM1's HP is one pole (6 dB an octave, its own source says
so). The stock RHPF is 12 dB an octave. Stock peaks, rendered:

| Cutoff | Resonance 0 | 0.5 | 0.9 |
|---|---|---|---|
| 1 kHz | +1.2 dB at 705 Hz | +5.7 dB at 924 Hz | +15.3 dB at 993 Hz |
| 5 kHz | | +5.0 dB at 4578 Hz | +14.7 dB at 4960 Hz |
| 10 kHz | | +3.0 dB at 8761 Hz | +12.7 dB at 9898 Hz |

DFM1 maps resonance 1 to self-oscillation, and the engine clips it at 0.9. Above
7.9 kHz (0.164 of the sample rate) DFM1 cannot sustain its resonance, by its source.
So one knob value gives a different Q and peak on the two paths.

The glide. `cutoff.lag(0.05)` lags the value in Hz. From 20 kHz down to 200 Hz,
half the octaves pass in 17 ms. From 200 Hz up to 20 kHz, half pass in 0.7 ms.

## Modulation

The modulators send a value 15 times a second (`FPS` in four.lua). The engine lags
are 20 to 50 ms, measured to -60 dB. With a 50 ms lag each step is 90% done after
16 ms, and the value stands still for half of each 67 ms frame. With 20 ms it
stands still for 80%. During each step it moves 8 times (50 ms) to 18 times (20 ms)
as fast as the mean. A slow sweep is a staircase at 15 Hz.

## Stereo, headroom and the record path

| Measure | Result |
|---|---|
| Master limiter, a loud burst on L only over a centred tone | the tone drops 3.85 dB on L, R does not move |
| The take, the same burst (record limiter, 0.99) | an image shift of 2.78 dB, printed |
| LeakDC on the take's dry arm (coefficient 0.995) | -2.80 dB at 40 Hz, -0.57 dB at 100 Hz, -0.13 dB at 200 Hz |
| The record limiter on a 1 ms transient at 1.8 over a tone at 0.3 | the transient is held to 0.99, the tone around it ducks by up to 3 dB for about 4 ms |
| The take's delay against the input | 3.9 ms (the record limiter's lookahead, twice) |

At line level the record limiter acts only within 0.09 dB of digital full scale on
the dry arm. It acts often in resample and regen, where the output before the master
limiter goes above 1.

Gains a track can add, measured with amount 1:

| Stage | Gain |
|---|---|
| Drive 1, a -12 dBFS tone | +4.3 dB, third harmonic -16.7 dB |
| RESON on an in-tune tone | +14.8 dB RMS, peak at 1.0 (the tanh), third harmonic -9.8 dB |
| RESON on noise | +3.2 dB |
| FLANGE (FourDelay) | +12.6 dB at 12 Hz, the comb's tooth at DC |
| FLANGE (stock comb) | +14.0 dB at 12 Hz |
| ECHO | +2.8 dB RMS |

## Colour

| Input | Drive | Level against the input | H3 | H5 |
|---|---|---|---|---|
| -12 dBFS | 0.25 | +0.9 dB | -40.3 dB | -69.2 dB |
| -12 dBFS | 0.5 | +2.4 dB | -27.7 dB | -49.3 dB |
| -12 dBFS | 1 | +4.3 dB | -16.7 dB | -31.0 dB |
| -6 dBFS | 0.25 | +0.4 dB | -31.6 dB | -50.0 dB |
| -6 dBFS | 1 | -0.3 dB | -11.8 dB | -20.1 dB |

Drive aliasing, the energy that is not an odd harmonic, below 16 kHz, full drive:

| Tone | Base rate | x2 | x4 |
|---|---|---|---|
| 5 kHz at -6 dBFS | -27.3 dB | -65.0 dB | -104.8 dB |
| 9 kHz at -6 dBFS | -20.7 dB | -34.7 dB | -79.9 dB |
| 9 kHz at -12 dBFS | -31.0 dB | -58.7 dB | -153.2 dB |

Crush 1 (4 bits, 1.5 kHz hold): DC -0.0002 at -6 dBFS (-74 dBFS), level -1.3 dB at
-12 dBFS. Its "second harmonic" at -6 dB is the hold's image at 1.5 kHz + 0.5 kHz.

FourTanh against `tanh`: test_core checks it to 3e-7. On the Mac that test compares
`std::tanh` with itself, because the NEON branch runs on ARM only. The norns build
of test_core is the real proof.

## Voices: what folds, by pitch

A tone at -6 dBFS. Above pitch 1 the tone is 30 kHz / pitch. Its true place is
then 30 kHz, and what lands on 18 kHz is a fold. Below pitch 1 the tone is 10 kHz,
and the table gives its largest image. dBFS, FourStretch build.

| Voice | x1.5 | x2 | x3 | x4 | x0.5 image | x0.25 image |
|---|---|---|---|---|---|---|
| PLAY, PV, WARP | -97.8 | -70.6 | -37.2 | -27.9 | -106.0 | -104.4 |
| GRAIN | -35.0 | -13.4 | -23.8 | -9.8 | -40.8 | -40.4 |

GRAIN at pitch 1 against the take, white noise: -0.39 dB at 10 kHz, -1.46 dB at
16 kHz, -2.44 dB at 19 kHz (the device measured -1.6 and -2.4). With each grain's
start on a whole frame: within 0.16 dB to 19 kHz.

Mode changes from PLAY, a 1 kHz take (5 ms RMS):

| Into | Plugin: deepest, recovered after | Stock: deepest, recovered after |
|---|---|---|
| WARP | -28.6 dB, 149 ms | -23.3 dB, 208 ms (and +3.5 dB after) |
| PV | -27.8 dB, 34 ms | -85.6 dB, 46 ms |

GRAIN's cap: a cloud holds density x size grain pairs. The plugin's cap is 48 and
the stock one 32. At size 0.5 s the cap holds from density 96 (stock 64). Below a
size of 0.24 s (stock 0.16 s) it never holds. The pad voices have no such cap: their
`GrainBuf` keeps its default of 512 grains each.

A grain longer than its window reads past the window: in a 12 ms window at size
0.5 s the sound from outside came out 8.6 dB louder than the window's own. At size
0.01 s: -153 dB.

PLAY with scan set to 0 in the middle of the window holds a sample: a DC of +0.21 on
the output.

## Reverb, shimmer and delay

| Reverb, a click | Decay 0.8 s | 2 s | 7 s |
|---|---|---|---|
| FourRoom: T60, level of the first 0.5 s | 0.67 s, -8.6 dB | 1.79 s, -8.5 dB | 5.79 s, -7.6 dB |
| FreeVerb (no plugins) | 0.59 s, -5.3 dB | 0.61 s, -5.2 dB | 0.75 s, -4.7 dB |

A null test on a running room: `rev_size`, `rev_early`, `rev_moddepth`,
`rev_modfreq`, `rev_low`, `rev_mid`, `rev_high`, `rev_lowcut` and `rev_highcut`
set at once change nothing, bit for bit. A room started at size 2 differs from one
started at 1 by +3.5 dB. Sizes 2.1 and 4 at the start are identical.

Shimmer 0.95, decay 30, 60 s:

| Input | FourRoom | FreeVerb |
|---|---|---|
| A burst, pitch -12, -7, 0, +7, +12, +24 | decays at every pitch, -129 to -146 dBFS at 59 s | decays, except at 0: a full-scale drone (peak 4.8) |
| 40 Hz at 0 dBFS for 10 s, pitch 0 | decays, -88 dBFS at 59 s | runs away (+4.8 dBFS RMS at 30 s) |
| DC 0.5 for 10 s | peak 3.16 (the room's own DC gain, +16 dB, with shimmer at any pitch) | runs away at pitch 0 |

No denormals: the smallest value in the last second was 1e-12 (FourRoom) and 6e-24
(FreeVerb), both normal floats.

FourBBD: the least time is 42.8 ms. `delay_time` 0.01, 0.02 and 0.043 s all give an
echo at 42.8 ms (the stock delay gives 8.7, 18.7 and 41.7 ms). A turn from 0.3 to
0.1 s under a 1 kHz tone: no sideband above -82 dB (the clock's steps of one block
are not heard at the engine's 0.2 s lag).

FLANGE (FourDelay) at amount 0 delays the track by 1.40 ms (67 samples).

## Not measured

The cost of anything on the Pi. The DFM1, JPverb and MiClouds paths. CLOUD. The
memory a full engine takes from scsynth's real-time pool.
