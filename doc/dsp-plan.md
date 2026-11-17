# DSP plan: the voices and the effects, done by the math

> **Status, 2026-11-15.** Much of this plan is built. These parts are in the
> engine: the frame-count head (sixth change), the depth in cents, the RESON gain
> law and the FourStretch UGens. These parts are not built: the correlated loop
> seam, the formant hold and GRAIN through the sinc read. The oversampled drive,
> the RING lowpass, the delay's time options and SHIFT are not built either. The
> sentence "Nothing here is built" below is from 2026-11-13. The text below the
> line is the plan as written. The last section, **The acceptance checklist**, is
> current: each target, its test and the last measured value.
>
> **2026-11-17.** The forty-fifth change moved the amount laws of the effects: CHORUS
> runs from 8 to 50 cents, and WOBBLE's wow reaches 100 cents and its flutter 30. The
> figures for CHORUS and WOBBLE below are the plan's. doc/changelog.md has the laws.

Written 2026-11-13 from a read of `lib/Engine_Four.sc`. Nothing here is built.
This version replaces the first draft of the same day. The first draft chose
what was easy with stock UGens. This one starts from what is correct, and
then says what it costs.

## What "perfect" means here

No stretch or effect is perfect in general. Each one can meet exact
properties, and each property has a number that a test can measure.

| Property | Meaning | Target |
|---|---|---|
| Identity | At neutral settings the output is the input | Null residual below -90 dB |
| Level | Loudness does not change with a setting that is not a level | Within 0.5 dB |
| Clean band | Resampling and nonlinear stages add no aliasing | Images below -70 dB |
| Continuity | No parameter move makes a step in the signal or its slope | No click above the noise floor |
| Tuning | A resonator sounds the note that the screen shows | Within 2 cents |
| Coherence | A stretched sine stays one sine | Sidebands below -50 dB |

## Measured on the Mac, 2026-11-13

SuperCollider 3.14.1 is now on the Mac (`brew install --cask supercollider`).
The files in `test/dsp/` render copies of the engine's graphs offline and
measure them. Set `BENCH_DIR` to a work folder, run `mkbuf.py`, then
`sclang bench.scd`, then `an.py`. These are copies of the graphs, not the
engine file, and only stock UGens ran.

| Claim | Result | Verdict |
|---|---|---|
| PLAY returns the exact recorded sample | A 5 kHz tone 8 s into the buffer reads with noise at -40 dB. At 54 s it is -25 dB. | False. This is new, and it is the worst defect found. |
| Reading above pitch 1 folds the top back | A 15 kHz tone at pitch 2 comes out at 18 kHz at full level | True |
| Pitch at or below 1 does not alias | A 10 kHz tone at half speed has an image at 19 kHz, 30 dB below it | False. I was wrong. |
| Cubic images sit near -40 dB | -30 dB for a 10 kHz tone | Worse than I said |
| The chorus reaches 4 semitones | -4.6 to +3.6 semitones at the top of both knobs, 37 cents at the defaults | True |
| PV changes pitch with scan | A 1 kHz tone at scan 0.5 comes out at 500 Hz | True |
| Two `Warp1` smear the stereo image | Correlation 0.03 with `warp_rand` at 0.2. With it at 0 the two are equal. | True only with `warp_rand` up |
| `Warp1` does not return the input at speed 1 | A sine comes out 2.6 dB up, and noise does not null | True |
| A stretched tone flutters | At half speed the level of a sine moves by 6.6 dB | True |
| The grain level law | Measured +12.04 and +4.77 dB against predicted +12.04 and +4.77 dB | True, with one correction below |
| RESON needs a tuning repair | C2, C4 and C6 are within 0.02 cents | False. The tuning is right today. |
| The drive stage aliases | A loud 5 kHz tone at full drive has aliases at -15 dB. A 1.3 kHz tone has them at -45 dB. | True for bright, loud sound |
| The antialiased `tanh` repairs it | It lowers the aliases by 5 to 12 dB | True, but the gain is modest |

### The long buffer defect

The read position is one 32-bit float, from 0 to 1, across a 60 s buffer.
A float has 24 bits, and the buffer has 2.88 million frames. Late in the
buffer the position lands up to a quarter frame off, on every sample, even
at pitch 1. The error rises with the position and with the frequency.

Two stock repairs ran in the bench:

- A `Phasor` that counts in frames, with whole numbers for its start and
  end. At pitch 1 the output is then the buffer, bit for bit (-155 dB).
  Away from pitch 1 it does not help.
- `PlayBuf`, which keeps its position in 64 bits. At plus 1 semitone and
  54 s it reads at -49 dB against -26 dB. What remains is the cubic image.

So PLAY, PV and CLOUD move to a frame count first. That is the cheapest and
largest gain in this plan. The pitched case needs `PlayBuf` or the custom
UGen. GRAIN and WARP are not affected, because a grain keeps its own
position in 64 bits after it starts.

### Repaired and tested again, 2026-11-13

`test/dsp/run_engine.sh` now compiles the real `lib/Engine_Four.sc` on the Mac
and renders its SynthDefs. The numbers below come from the real engine, before
and after the sixth change.

| Measure | Before | After |
|---|---|---|
| PLAY, 5 kHz tone 8 s in, pitch 1 | noise -40 dB | -154 dB (bit exact) |
| PLAY, 54 s in, pitch 1 | -38 dB | -154 dB |
| PLAY, 54 s in, reverse | -35 dB | -154 dB |
| PLAY, 54 s in, plus 1 semitone | -25 dB | -49 dB (the cubic limit) |
| PLAY, 54 s in, half speed | -23 dB | -54 dB |
| PV, 54 s in | -38 dB | -94 dB |
| PLAY after a window move and a scan change | -22 dB | -154 dB |
| CHORUS, top of both knobs | -456 to +361 cents | 27 cents |
| CHORUS, defaults | 38 cents | 18 cents |
| WOBBLE, top of both knobs | 140 cents | 50 cents |

Two repairs were dropped after the math:

- The antialiased drive averages two samples. That costs 3 dB at 12 kHz and
  12 dB at 20 kHz, for 5 to 12 dB less aliasing. The drive would sound dull.
  The honest repair is oversampling, which belongs in a custom UGen.
- The lowpass before RING only acts on input above 20 kHz. Music has almost
  nothing there, so the repair changes nothing that anyone can hear.

Still open: the cost of the new read on the Pi, and a listen.

### The custom UGen, built and proven on the Mac, 2026-11-13

The decision below was taken: our own UGen, not Rubber Band. `ugen/` holds
it. The core is plain C++ and `ugen/test_core.cpp` proves it. The table is
from the real engine, rendered with and without the plugin.

| Measure (5 kHz tone, 54 s in) | Stock voice | FourStretch |
|---|---|---|
| PV, speed 0.5: where the tone lands | 2500 Hz | 5000 Hz |
| PV, speed 0.5, pitch 2 | 2500 Hz | 10000 Hz |
| PV, frozen: energy off the tone | -29 dB | -109 dB |
| WARP, speed 1: energy off the tone | -77 dB | -109 dB |
| WARP, speed 0.5: level swing | 2.0 dB | 0.0 dB |
| WARP, speed 0.5, pitch 2: level swing | 8.0 dB | 0.0 dB |
| PLAY, plus 1 semitone: noise | -49 dB | -70 dB |

The core proof also shows, on noise and not on a tone: PV and WARP return the
take at speed 1 with a residual of -140 dB, the stereo phase holds at every
speed, a 15 kHz tone at pitch 2 does not fold (-71 dB), and an attack at a
quarter speed has no energy before it.

Cost on the Mac: PV 0.6% of a core at pitch 1 and 1.5% at pitch 2, WARP 0.15%
and 0.55%. The Pi is not measured. The transform is a real-input one already
(the same spectrum as the full one, for half the work). Every position is 64
bits, because the norns is a 32-bit system.

Not done from this plan: the correlated loop seam for PLAY, the formant hold,
GRAIN through the sinc read, and every feature in the last step of the order.

## Two things the plan needs first

### A test bench on the Mac

SuperCollider is on the Mac since 2026-11-13. sc3-plugins and mi-UGens are
not, so DFM1, JPverb and MiClouds cannot render there yet. CLOUD renders there through
FourCloud, the same code in four's own plugin, since the thirty-third change.
`scsynth -N` then renders any SynthDef offline from a score, with no audio
hardware.

A new test suite, `test/dsp/`, renders each def with test signals and asserts
the targets above:

- a null test (output minus input) for identity
- a logarithmic sine sweep for aliasing (energy off the expected line)
- an impulse for decay time and tuning
- pink noise for level
- a steady sine and a click train for stretch quality

The norns stays the last gate, because its CPU is the real limit. The bench
removes the reason for "never write SC in bulk", which was that nothing
on the Mac was able to test it.

### One custom UGen for the stretch

Stock UGens cannot do a correct stretch. `Warp1` and `GrainBuf` place grains
blind. The `PV_` UGens give no control of phase from frame to frame. A read
from a buffer has cubic interpolation at best.

The plan is one small C++ UGen, `FourStretch`, with a portable core. The core
is plain C++ with no SuperCollider in it, so a test program on the Mac can
prove it against the targets. A thin wrapper makes it a UGen. It builds on
the norns for the Pi and deploys as one `.so` plus one class file in the
SuperCollider extensions folder, outside `dust/code`. The engine guards it
like MiClouds and falls back to the current voice.

The alternative is the Rubber Band library inside a wrapper. It sounds
excellent, but its licence is GPL or a paid one, and its best engine is heavy
for four tracks on a Pi 4. The own core is the recommendation.

## The voices

### PLAY: exact resampling and an exact loop

Resampling by a ratio `r` is a convolution with a sinc. For `r > 1` the sinc
cutoff must fall to `fs / (2 r)`, or the top of the spectrum folds back.
Cubic interpolation does neither job well: its images sit near -40 dB and it
has no cutoff. `FourStretch` reads with a windowed sinc (16 taps, Kaiser
window, a table of 512 phases), and it scales the cutoff by `1 / r` above
pitch 1. Images then stay below -70 dB.

The loop seam is a crossfade of two segments. The gains must hold
`g1² + g2² + 2 ρ g1 g2 = 1`, where `ρ` is the correlation of the two
segments. Two cases are exact: a linear fade for `ρ = 1`, and a sine and
cosine fade for `ρ = 0`. So the plan makes `ρ` close to 1. At record stop,
Lua searches the last 10 ms of the window for the lag with the highest
cross-correlation against the start. The seam goes there, and the fade is
linear. The loop then has no dip, no bump and no click.

### WARP: a time-domain stretch that returns the input at speed 1

Plain overlap-add at a stretch other than 1 adds grains whose waves do not
line up. They cancel in part, which gives the flutter at the grain rate.
The correct method is WSOLA:

1. Grain `n` is due at read position `p_n = p_(n-1) + H / α`, with output
   hop `H` and stretch `α`.
2. The natural continuation of grain `n-1` is the audio at `p_(n-1) + H`.
3. Search `p_n ± Δ` (Δ about 10 ms) for the offset with the highest
   cross-correlation against that continuation, and read the grain there.
4. Window with Hann at hop `L / 2` or `L / 4`. Hann windows at those hops
   sum to a constant, so no level law is needed.

At `α = 1` the best offset is 0, each grain continues the last one, and the
output is the input, sample for sample. That is the identity target, and
neither `Warp1` nor the first draft's grain pair can meet it.

Both channels share one offset, found on the sum of left and right, so the
stereo image is exact. A grain that starts on a detected attack is not
searched or cut. It is copied whole, so drums keep their front edge. Pitch is
the sinc resampler from PLAY, applied after the stretch.

### PV: a phase vocoder with locked phases

The frame at analysis hop `Ra` is rebuilt at synthesis hop `Rs`, and the
stretch is `α = Rs / Ra`. For each bin `k` with centre frequency
`ω_k = 2π k / N`:

```
Δφ   = princarg( φa[t] − φa[t−1] − Ra · ω_k )
ω̂   = ω_k + Δφ / Ra                 (the true frequency in the bin)
φs[t] = φs[t−1] + Rs · ω̂
```

This alone keeps each partial continuous in time, but the bins around one
partial drift apart, which is the hollow "phasey" sound. Identity phase
locking (Laroche and Dolson, 1999) repairs it:

1. Find the peaks of the magnitude spectrum.
2. Propagate the phase of each peak bin `p` with the equations above.
3. Give every other bin in the region of that peak the phase
   `φs[k] = φs[p] + φa[k] − φa[p]`.

Two more rules complete it. On a detected attack, set `φs = φa` for the whole
frame, so the attack is not smeared across the frame. With a Hann window for
analysis and for synthesis at hop `N / 4`, the squared windows sum to 1.5, so
the scale is 2/3. At `α = 1` every phase equals its analysis phase, and the
output is the input.

Frame size is 2048 at 75% overlap. Pitch is the stretch by `α` and then the
sinc resampler by `1 / α`. An optional formant hold divides each frame by its
spectral envelope (a smoothed cepstrum) before the shift and multiplies it
back after.

The freeze of the first draft (new random phases on each frame) stays as the
law for scan 0 only. A random phase keeps the power spectrum and nothing
else. That is right for a frozen texture and wrong for a stretch.

Expected cost: about 3% of the thread for each stereo track. Four tracks must
stay below 40%.

### GRAIN: an exact level law

For Hann grains, the window has a mean of 1/2 and a mean square of 3/8. With
an overlap `N = density × size`:

- grains from one place add in amplitude, and the sum is `N / 2`
- grains from random places add in power, and the power is `3 N / 8`

This gain holds the level for any mix of the two:

```
g = 1 / sqrt( 3N/8 + ρ · (N²/4 − 3N/8) )
```

Here `ρ` is 1 only for grains that move at the natural speed with no random
offset. A frozen head gives `ρ = 0`: the bench measured it. The engine adds a
random offset to every grain, so it is always at `ρ = 0`. The current law,
`1 / sqrt(N)`, is then right in shape, and the measured 0.8 trim absorbs the
constant. GRAIN needs no change of law. Below `N = 1` the stream has
gaps, and the gain stays at its `N = 1` value. No boost can fill a gap.

Grains above pitch 1 alias for the same reason as PLAY. The exact repair is
the sinc read, so GRAIN moves into `FourStretch` as a third mode, after WARP
and PV are proven. The reverse chance and the interval spread of the first
draft are features, not corrections. They stay in the plan at the end.

### CLOUD

MiClouds is a closed box. It gets the correlated seam and nothing else.

## The effects

Each of these is exact with stock UGens.

### CHORUS, FLANGE, WOBBLE: depth as pitch, not as time

A delay that moves by `D · sin(2π f t)` shifts the pitch by the ratio
`2π f D` at its peak. Today the depth in time is fixed while the rate rises.
At the top of both knobs the chorus reaches `2π · 6 · 0.007 = 0.26`, which
is about 4 semitones of vibrato. That is a defect in the law.

The correct law fixes the depth in cents: `D = (2^(c/1200) − 1) / (2π f)`.
The amount knob sets `c`, and the rate knob then changes the speed without
changing the detune.

- CHORUS: `c` from 0 to 25 cents. Three taps with LFO phases 120 degrees
  apart. The three pitch offsets sum to zero at every instant
  (`Σ sin(θ + 2πk/3) = 0`), so the vibrato cancels and the width stays.
- FLANGE: the dry arm is delayed by a fixed 3.5 ms so that the sweep passes
  through zero. With feedback `g` the peak gain is `1 / (1 − g)`, so the wet
  arm is scaled by `(1 − g)`. The peaks then never exceed the dry level.
- WOBBLE: wow from 0 to 50 cents at 0.3 to 2 Hz, flutter from 0 to 15 cents
  at 6 to 12 Hz. These are the figures of a tape machine from good to worn.

### RESON: the right note and a known level

The comb period is `L = fs / f0` samples. Any filter in the loop adds its
own phase delay `τ(f0)`, so the line must be `L − τ(f0)`. The feedback for
a decay time `T60` is `g = 0.001^(L / (fs · T60))`.

No single gain is right for every input. A comb gives noise a power gain of
`1 / (1 − g²)`, and it gives a tone on the resonance an amplitude gain of
`1 / (1 − g)`. The plan uses the tone law, `(1 − g)`, because music in tune
with the resonator is the loud case. The mix knob then adds a makeup of the
measured difference for pink noise.

Three combs (root, fifth, octave) stay from the first draft. The bench
found the tuning of the current comb exact, so the length correction
applies only after a filter joins the loop. High notes ring dull today: at
C6 the 8th partial is 31 dB down, because the cubic read in the loop
removes the top.

### RING and SHIFT: no fold at the top

A product with a sine at `fc` moves every input frequency `f` to `f + fc`
and `f − fc`. Anything with `f + fc` above `fs / 2` folds back as a false
tone. The exact repair is a lowpass on the input at `fs/2 − fc` before the
product. For the top of the knob (4 kHz) that is 20 kHz, so the cost in tone
is small. SHIFT (`FreqShift`) gets the same lowpass for upward shifts.

### DRIVE: saturation with no aliasing

`tanh` makes harmonics without limit, and those above `fs / 2` fold back.
The stock repair is antiderivative antialiasing. With `F(x) = ln cosh x`,
the antiderivative of `tanh`:

```
y[n] = ( F(x[n]) − F(x[n−1]) ) / ( x[n] − x[n−1] )
```

If the two samples are closer than 1e-5, the output is `tanh` of their mean.
This is the exact average of `tanh` over the path between two samples. The
bench measured 5 to 12 dB less aliasing, for a half sample of delay. Stock UGens can build it. The same stage serves the delay loop and
the shimmer loop.

CRUSH aliases on purpose and stays.

### DELAY and REVERB

- The loop is stable for `|g · H(f)| < 1` at every frequency. A 60 Hz
  highpass joins the lowpass in the loop, and the bench confirms the bound.
- A time change has two honest forms. A slewed time is tape (the pitch
  bends). A crossfade between two taps is digital (no bend). Today it is
  tape. The choice is the performer's, so it becomes one option param.
- The shimmer uses the PV shifter of `FourStretch` in place of
  `PitchShift`, which removes its grain.

## Order

1. The test bench on the Mac. The first run is done (see the table above).
   It still needs the plugins and the real engine file.
2. The frame count for PLAY, PV and CLOUD (the long buffer defect).
   Then the exact laws with stock UGens: depth in cents, RESON gain, the
   RING lowpass, the drive stage, the correlated seam.
3. The `FourStretch` core on the Mac: sinc reader, then WSOLA, then the
   phase vocoder. Each one passes its targets before the next starts.
4. The UGen wrapper, the build on the norns, and the CPU measurement.
5. WARP, PV and PLAY move to it, one voice for each restart. GRAIN follows.
6. Features: SHIFT, the ensemble chorus, the tape tone, grain reverse and
   intervals, the delay options.

Each stage on the device ends as before: the count, a capture, the thread
load with four tracks (stop above 55%), a listen, the change-log entry.

## What the math cannot settle

A stretch trades time detail against frequency detail, and no frame size is
right for all material. The targets prove that the engine adds no errors of
its own. Which voice suits which sound is still a matter for ears.

## The acceptance checklist (2026-11-15)

Each row is a target of the table at the top, its test, and the last value. "Mac"
is an offline render of the real engine or a run of the core. Nothing here is from
the norns. The DFM1 rows come from its source, because the Mac has no sc3-plugins.
The method and every number: doc/measurements/2026-11-15/README.md.

| Target | Test | Last value | Verdict |
|---|---|---|---|
| PLAY is the take at pitch 1 | 5 kHz tone 54 s in, an_engine.py | -154 dB | pass |
| PV and WARP are the take at speed 1 | noise, test_core | -140 dB | pass |
| PLAY, PV, WARP fold nothing at pitch 2 | 15 kHz tone, core_probe2 | -70.6 dBFS | pass |
| The same at pitch 3 and 4 | 10 and 7.5 kHz tones | -37.2 and -27.9 dBFS | FAIL: the kernel keeps 32 taps above pitch 2 |
| No image at pitch 0.5 and 0.25 | 10 kHz tone | -106 and -104 dBFS | pass |
| GRAIN is flat at pitch 1 | noise, third-octave bands | -2.4 dB at 19 kHz | FAIL: the cubic read between frames |
| GRAIN folds nothing at pitch 2 | 15 kHz tone | -13.4 dBFS | FAIL |
| The open filter is the identity | null against dry, under -90 dB | stock -10 dB at 10 kHz, DFM1 H3 -37 dB at -6 dBFS | FAIL on both paths |
| LP, BP and HP sound alike on both paths | sweeps at 3 cutoffs and 3 resonances | HP 6 against 12 dB an octave | FAIL |
| No step from a moved knob | probe4 s: a 0.25 Hz sine sent once a frame at random phase (14.9 and 13.8 Hz clocks) into a level and a cutoff, an_stair.py | still 61 to 74% of the time, longest 47 to 60 ms, ripple above 5 Hz -34 to -35 dB | FAIL |
| A mode change has no hole | 1 kHz take, 5 ms RMS | WARP -28.6 dB, PV -27.8 dB | FAIL |
| The same into GRAIN | as above | no hole | pass (twenty-second change) |
| The drive folds nothing in hearing | 5 kHz at -6 dBFS, full drive, below 16 kHz | -27.3 dB | FAIL |
| The take is the input | LeakDC on the record arm | -2.8 dB at 40 Hz | FAIL |
| Limiting keeps the stereo image | one-sided burst | 3.85 dB shift (output), 2.78 dB (take) | FAIL |
| Erosion adds no noise | 5 kHz take, 12 s | -141 dB at every place | pass (twenty-second change) |
| RESON is in tune | C2, C4, C6 | within 0.02 cents | pass |
| The bucket brigade meets its formulas | test_core | within 0.47 dB and 0.1 clock period | pass |
| Every reverb knob acts | null test on a running room | 9 knobs change nothing | FAIL |
| The shimmer loop is bounded | 0.95 at every pitch, 60 s | FourRoom decays, FreeVerb runs away at 0 st | pass with the plugin |
| The reverb passes no DC | DC 0.5 for 10 s, decay 30 | +16 dB of DC out | FAIL |
| Cost on the norns | four tracks, `top -H` | doc/measurements/2026-11-13 | measured before this review |

To check the rows a Mac can render: `test/dsp/check_dsp.sh <work folder>` (add
`FOUR_PLUGIN_DIR` for the FourStretch build, about 30 s). It fails on a missed pass
row, and on a FAIL row that gets worse than the margin it prints.

Three tests for the filter are still to write. The first sweeps each path at
cutoffs of 20 Hz, 1 kHz and 20 kHz with resonance 0, 0.5 and 0.9. The second is
the null against dry at the open setting. The third changes LP to BP to HP under
a tone and finds no click above -60 dB.
