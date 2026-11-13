# four: the plan for SPACE, the effects and the screen

Status: the second draft, 2026-11-13. A second agent reviewed the first draft
and found errors. Section 11 lists them, and the sections above it are
corrected. Nothing here is built.
Each claim below is a target that a test must confirm. A claim with no test is
an opinion.

## 1. What the user asked for

- Effects of real quality, each with its own character. No cheap copy.
- A delay in the manner of a bucket brigade device (BBD).
- A reverb that is a room: you make the box large or small.
- Math that is correct, and a test for each part.
- A screen as sober and clear as good Nordic product design.
- A second agent that reads these ideas before work starts.

## 2. Rules for every part

1. Write the continuous or ideal model first, as equations.
2. Derive the discrete form. State each approximation and its error.
3. Give each part a number to reach (section 9).
4. Put the algorithm in `ugen/four_core.h` with no SuperCollider in it.
5. Prove it in `ugen/test_core.cpp`, on the Mac and on the norns.
6. Measure the cost on the norns before the engine uses it.
7. Only then a person listens.

The budget is 60% of the audio thread. Section 2b holds the first
measurement: what the present delay and reverb cost alone.

## 2b. Measured first (step 1 of the order, done 2026-11-13)

The scsynth audio thread on the norns, track 1 in PLAY:

| State | Thread |
|---|---|
| A fresh script, no reverb, no delay | 4.2% |
| The delay on | +0.6% |
| The reverb on (JPverb) | +13.5% |
| The shimmer on top of the reverb | +0.2% |

The reverb is the heaviest thing in the engine by far. It costs more than six
tracks. The "17% at rest" of every measurement of this week was 4% of engine
and 13% of reverb: preset 1 points a modulator at the reverb mix, so the engine
value never reaches 0 and the reverb synth never stops.

Two results for this plan:

- A reverb of our own at 3% gives back 10 points of the budget. That is the
  largest gain left in the engine.
- A modulator on the reverb mix keeps the reverb alive at a mix of 0. With
  sends, the reverb runs while any send or its return is above 0, and that
  rule must count what the modulators add.

## 3. The signal path of SPACE

Each track t has two sends, taken after its level. Both start at 0.

```
d_in  = sum_t  s_d[t] * x_t  +  s_rd * R_out     (reverb into delay, default 0)
r_in  = sum_t  s_r[t] * x_t  +  s_dr * D_out     (delay into reverb, default 0)
out   = sum_t  x_t  +  g_d * D_out  +  g_r * R_out
```

Only one of the two cross sends (s_rd, s_dr) is open at a time: together they
close a loop through a reverb with no bound on its gain.

The dry sum never ducks. The present delay is a crossfade that lowers the dry
signal, and that law goes away. Make sure that a send of 0 leaves the track bit
for bit equal to the track with no SPACE at all.

## 4. The delay: a bucket brigade

### 4.1 The analog device

A BBD is a chain of N capacitors. A two-phase clock of frequency f_c moves each
charge one stage for each half period. The delay is

```
T = N / (2 f_c)
```

N is fixed by the chip (4096 for the MN3005). The TIME knob moves the clock, so
a change of time is a change of pitch, as on tape. That glide is the device, and
the model keeps it.

A BBD is a sampler at f_c with no quantizer. It needs a low-pass before it
(anti-alias) and one after it (reconstruction). Its output is a staircase, which
adds the droop `sinc(f / f_c)`. A long delay means a slow clock, a low Nyquist
frequency and a dark sound. That darkness is not a tone control. It is the
sampling theorem.

A compander surrounds the chip to hide its noise. The compressor before it
halves the dynamic range in dB, and the expander after it doubles it again.

### 4.2 The model

The model follows Holters and Parker (DAFx 2018). The host runs at f_s = 48 kHz
and the clock ticks at times that do not sit on host samples.

- Input filter. Write H_in(s) as a sum of first-order parts `r_m / (s - p_m)`.
  Each part holds one state. At a tick that falls a time d after the last host
  sample, the state advances by `exp(p_m d)`. This is exact for an input that is
  constant between host samples. The value read at the tick goes into the chain.
- The chain. A ring of N/2 values, written and read once for each tick. No
  interpolation happens here, so the chain adds no error of its own.
- Output filter. The chain's output is a step at each tick. Each first-order
  part of H_out answers a step in closed form, `(exp(p_m d) - 1) / p_m`. The
  host sample is exact too.
- Both filters are third-order low-passes. Their corner follows the clock:
  `f_3dB = min(0.35 f_c, 14 kHz)`.

### 4.3 What the sampling does, as a number

A tone at f_0 comes out with images at every `k f_c +- f_0`. The first one,
at f_c - f_0, has this level against the tone:

```
A_image / A_tone = [f_0 / (f_c - f_0)] * |H_out(f_c - f_0)| / |H_out(f_0)|
```

The first factor is the ratio of the two sinc values of the hold. The review
measured it on a simulated chain: -25.66 dB by this form and by the render, at
a clock of 31.7 kHz and a tone of 9 kHz. The first draft's form was 2.3 dB off.

The model has a second kind of aliasing that a real BBD does not have. The
host's samples are a staircase at 48 kHz, and the output filter is read at 48
kHz. Both fold at fast clocks: the review found a component at -39 dB with a
clock of 31.7 kHz. Section 4.7 holds the answer.

The delay of the whole device is not `N / (2 f_c)` alone. The two filters add
1.82 clock periods at low frequency and the hold adds 0.5. SYNC subtracts that.

### 4.4 The compander, the noise and the clip

Let avg(.) be a rectifier with one time constant tau (10 ms in the NE570).

```
compressor (feedback):  y = x / avg(|y|)        a 2:1 law in dB
expander  (forward):    z = w * avg(|w|)        a 1:2 law in dB
```

The review proved that this pair alone does nothing: with a clean path between
them, the output equals the input at all times (the difference was 7e-15). The
"breathing" of a real delay is what sits BETWEEN the two halves. So the model
has three more parts, or it has no compander at all:

- the chain's noise, added after the compressor (the expander then pushes it
  down in the quiet parts, and it rises behind each note)
- a soft clip at the chain's input (the rails that catch an attack)
- the filters' loss, which the expander doubles in dB

The compressor's equation is implicit, and it has an exact form for a one-pole
average with coefficient k:

```
c = (1 - k) * a[n-1]
a[n] = (c + sqrt(c^2 + 4 k |x[n]|)) / 2
y[n] = x[n] / max(a[n], floor)
```

The floor is required. Without it silence gives 0/0, and the NaN stays in the
loop for good. The floor also sets the largest gain.

### 4.5 The loop

```
x_loop = in + fb * tanh(HP_30Hz(D_out))
```

If `|fb * H(f)| < 1` at every frequency, the loop is stable. H includes both
filters, so the bound holds for fb up to 1 once the filters are in. The test
runs fb = 0.98 for 60 s and reads a level that falls.

### 4.6 Controls

- TIME: the clock. 20 ms to 1.2 s with N = 8192.
- FEEDBACK.
- TONE: the filter corner, as a share of the clock.
- A slow clock LFO, for chorus.
- SYNC: sets T from the tempo.

 The same core with N = 512 is a true BBD chorus, and with
N = 1024 a per-track ECHO.

### 4.7 Two models, by the clock

- Clock under 24 kHz: the tick model of 4.2. It is the right one there, and its
  law for a moving clock is the device's own.
- Clock above 24 kHz: the sampling is out of hearing (an image at -98 dB), and
  the tick model costs the most there. Use a line whose write place advances by
  `f_c / f_s` for each sample, with the same two filters at the host rate. The
  delay is still the sum of the clock over N/2 ticks, so the glide is the same.
- N is a choice of "chip", as on real units: 512, 1024, 4096, 8192. A short
  time takes a short chain, so the clock stays in the range where it sounds.

The darkness is a product choice and the user must hear it: the corner is
4.8 kHz at 300 ms, 2.9 kHz at 500 ms and 1.2 kHz at 1.2 s with N = 8192.

## 5. The reverb: a room

### 5.1 The room, as physics

The room is a box with sides Lx, Ly, Lz, volume V and surface S. With the mean
absorption a of its walls and c = 343 m/s:

```
Sabine:            T60 = 0.161 V / (S a)
Eyring (large a):  T60 = 0.161 V / (-S ln(1 - a))
mean free path:    l = 4 V / S
echo density:      dN/dt = 4 pi c^3 t^2 / V     (echoes for each second)
modal density:     dN/df = 4 pi V f^2 / c^3     (modes for each Hz)
```

The user turns SIZE (V, with fixed proportions) and ABSORB (a). The decay time
is then a result, as in a real room, and the screen shows it in seconds. A
DAMP knob raises a with frequency, which is what air and soft walls do.

### 5.2 The late field: a feedback delay network

Eight delay lines of m_i samples feed each other through a matrix A.

```
s_i[n + m_i] = sum_j A_ij * g_j(s_j[n]) + b_i * in[n]
out_L, out_R = two sums of the s_i with orthogonal weights
A = I - (2/8) * ones(8, 8)        (Householder: unitary, 8 adds and 1 multiply)
```

With every g_j = 1, A unitary makes the network lossless: its energy is
constant. The test confirms that to 0.01 dB over 10 s. This is the proof that
the structure adds no decay or growth of its own.

Decay comes only from the g_j. A line of m_i samples loses

```
|g_i(f)| = 10^(-3 m_i / (f_s T60(f)))
```

so every line decays at the same rate in dB for each second, whatever its
length. g_i is a first-order shelf with exactly this gain at 0 Hz and at f_s/2.
A correction filter at the output flattens the level that the shelves tilt.

The delay lengths come from the box, not from a table of primes. A box has eight round trips of interest:

- three axial: `2 Lx`, `2 Ly`, `2 Lz`
- three tangential, for example `2 sqrt(Lx^2 + Ly^2)`
- one oblique
- the mean free path


`m_i = round(f_s * path_i / c)`, then moved to the nearest set with no common
factor.

The first draft took the eight lengths from the box's own round trips. The
review showed that this fails, for three reasons:

- The rule of Schroeder asks for `sum(m_i) / f_s >= 1.36 T60`. Both sides grow
  with the size, so the size cancels. Only the absorption decides: the rule
  holds for a above 0.6, at 1 m and at 20 m alike. A 5 m room with a = 0.1
  misses it by a factor of 6.
- Box paths cluster. With sides 1 : 1.26 : 1.59, one axial path and one
  tangential path are 1.2% apart, and they beat.
- The echo density reaches its normal value after 250 to 365 ms. The box
  itself mixes in 16 to 70 ms.

So the two fields part ways:

- SIZE drives what a box really fixes: the early reflections (5.3), the
  pre-delay and the mean free path, and with it the decay time.
- The late lines are chosen for density, not for the box. About 1 s of total
  delay, spread with no near pairs, and 4 to 6 allpass stages in front.
- Some lines move by several samples, slowly, or the matrix turns slowly. A
  turning orthogonal matrix is lossless by construction.

An honest limit: a network of delays is never the room's modes. A real room of
250 m3 has 78 modes for each Hz at 1 kHz. This network has about 1.

The shelf of each line must lose dB in proportion to its length at EVERY
frequency, not only at the two ends (the form of Jot, or of Schlecht and
Valimaki). With a plain shelf the lines decay at rates up to 45% apart at 2 kHz.

Controls. Use Eyring's form everywhere, with air: `T60 = 0.161 V / (-S ln(1 - a)
+ 4 m V)`. The user decides between two readings of the same physics: SIZE and
ABSORB (the decay is the result), or SIZE and DECAY (the absorption is the
result, and the page marks a room that cannot exist). The late level rises by
`10 log10(T60)`, so the return needs a gain law.

### 5.3 The early field

The first reflections of a box are exact: the image source method. The six
first-order images and the first twelve second-order images give 18 taps. Each
has a delay r / c and a gain `(1 - a)^(order / 2) * r_0 / r` (r_0 is the direct
path, so no gain is above 1), for a source and a
listener placed in the box. Two ears, 17 cm apart, give the stereo picture. A
POSITION knob moves the source from near to far.

### 5.4 The rest

- Two allpass stages before the network raise the echo density at the start.
- A change of SIZE crossfades between two sets of delays in 50 ms. A slide of
  the lengths bends the pitch, and a room does not do that.
- Shimmer uses the phase vocoder of `FourStretch` inside the loop.

## 6. The other effects

- CHORUS: the BBD core with N = 512. Two chains for stereo, clocks 90 degrees apart.
- ECHO: the BBD core with N = 1024, one for each track that uses it.
- RESON: a string. A delay loop with a loss filter set from a T60 for each
  frequency (the equation of 5.2) and an allpass for the fraction of a sample,
  so the pitch is right to 1 cent at any note.
- WOBBLE: the tape model. Wow and flutter as measured spectra (0.5 Hz, 6 Hz and
  noise), a head bump at 60 Hz and a loss above 10 kHz.
- CLOUD moves from the voices to the effect slots.
- FLANGE and RING stay as they are.

## 7. The screen

### 7.1 Principles

1. One page says one thing. The picture is the sound's own mechanism.
2. Geometry only: lines, squares, circles. No texture, no decoration.
3. Four levels of grey with fixed meanings: 15 is what you turn, 10 is what
   sounds, 4 is what rests, 1 is the frame.
4. One grid of 4 pixels. Every edge sits on it.
5. Motion means sound. If the sound holds still, the picture holds still.
6. A number appears while you turn its knob, and in its true unit (ms, s, Hz, m).
7. The same place always holds the same kind of thing.

### 7.2 SPACE

- SENDS view: four columns, one for each track. Each holds two bars (to the
  delay, to the reverb). The focused track is at level 15.
- DELAY view: the chain itself. A row of cells, and bright packets that step
  from cell to cell at the clock's speed. A short delay is a fast row. A packet
  that reaches the end comes back in at the start, dimmer by the feedback. The
  packets grow coarser as the clock slows, because the bandwidth falls.
- REVERB view: the box, seen from above. Its side is SIZE. The wall's weight is
  ABSORB (a thin wall reflects, a thick wall absorbs). The first reflections
  are drawn as the image source rays they are, and the field then fills in at
  the rate dN/dt of 5.1. The decay time stands beside it in seconds.

CLAUDE.md records that an earlier top-down room on REVERB was rejected. This
one differs in one way: every line on it is computed from the same box as the
sound. That decision belongs to the user.

### 7.3 Then every other page

The same seven principles, page by page, after SPACE proves them: TAKE, VOICE,
FILTER, EFFECT, MOTION, TRACKS, MIX, PADS, SCENE.

## 8. Order of work

1. Measure the present delay and reverb alone on the norns.
2. The BBD core and its tests. Then ECHO and CHORUS on it.
3. The reverb core and its tests.
4. The engine: sends at 0, the additive law of section 3, the two new UGens.
5. The SPACE page with its three views.
6. MOTION for each track.
7. SOURCE on TAKE, the tape removed, MIX made simple.
8. Takes of 2 minutes.
9. The screen principles on every other page.

Each step ends with the count, a capture, the thread load and a commit.

## 9. The numbers to reach

| Part | Test | Target |
|---|---|---|
| Send at 0 | track against the track with no SPACE | bit exact |
| BBD time | phase slope, against chain + hold + filter delay | within 0.1 clock period |
| BBD response | sweep against `H_in * sinc(f/f_c) * H_out * sinc(f/f_s)` | within 0.2 dB to the corner |
| BBD image | tone against the corrected formula of 4.3 | within 0.5 dB |
| BBD other aliasing | every component not at `k f_c +- f_0` | under -70 dB, at every clock |
| Compander at rest | a 200 Hz tone, its fundamental in against out | within 0.05 dB |
| Silence | 60 s of no input, on the norns | no NaN, no rise in cost |
| Loop | fb 0.98, shortest and longest time, LFO on | the level falls at the predicted dB for each pass |
| Network, lossless | energy of the STATE with g = 1 over 10 s | within 0.01 dB |
| Decay | T60 in octave bands, against the designed curve T60(f) | within 5% |
| Echo density | time to a normal echo density of 0.9 (Abel and Huang) | under 80 ms |
| Stereo | correlation of the late field | under 0.1 |
| Early field | mono sum of left and right | no notch deeper than 6 dB |
| Moving knobs | TIME, SIZE, sends and feedback turned under a tone | no energy outside the tone's band above -60 dB |
| Blocks | the same input in blocks of 1 and of 64 | the same output |
| RESON pitch | every note from C2 to C6 | within 1 cent |
| Cost | delay and reverb together on the norns, no shimmer | under 8% of the thread |
| Cost, each track | CHORUS and ECHO on four tracks | measured before they ship |

## 10. What a reviewer is asked

1. Is each equation right, and does each test prove what it claims?
2. Is the BBD model the right one, or is a simpler exact one at hand?
3. Does the answer to the modal density tension hold?
4. Is 8% of a Pi 4 thread a real figure for both?
5. What is missing?

## 11. The review (2026-11-13) and what it changed

A second agent read the first draft, derived or simulated each equation, and
reported 14 findings. The ones that changed the design:

1. Delay lengths from the box do not work (5.2 is rewritten). The size cancels
   out of Schroeder's rule, the paths cluster, and the density comes late.
2. The BBD scheme is exact only for a staircase input. It folds at fast clocks
   (4.3 and 4.7 are new).
3. Above a clock of 24 kHz the tick model gains nothing and costs the most
   (4.7).
4. The compander alone is an identity. It needs the noise and the clip between
   its halves, an exact form and a floor against NaN (4.4 is rewritten).
5. The image formula was wrong by 2.3 dB at the test point (4.3).
6. The delay law lacked the filters' own delay, 2.3 clock periods (4.3).
7. A plain shelf gives each line its own decay rate between its two ends (5.2).
8. The two cross sends close an unbounded loop (section 3).
9. Five of the fifteen tests failed on a CORRECT build, and four had no
   measurable form. Section 9 is rewritten, with five tests added.
10. RESON, WOBBLE, CHORUS and ECHO have no equations and no tests yet. RESON
    must subtract the loss filter's phase delay, or it is 37 cents flat at C6.
    Each of them gets its own section before any code.

Found correct: the delay law of the chain, the baseband response, the 2:1 law,
the stability of the loop at a fixed clock, Sabine, Eyring, the mean free path,
the echo and modal densities, the Householder matrix and the absorption law.

The review's cost estimate, not measured: the stereo delay 1.5 to 3%, the
reverb with 8 lines 3 to 5%, so 4.5 to 8% for both. The shimmer adds 2 to 5%.
CHORUS on four tracks is 8 to 20% with the tick model, which is why 4.7 exists.

Still open, for the user:

- SIZE with ABSORB, or SIZE with DECAY.
- BBD noise: none, or a little that the user sets.
- The top-down room on the screen. A network of delays fills in more slowly
  than a box, so the picture shows the network's own density or makes no claim.
- The screen rule of four greys needs a ramp for a fading echo. The page
  shows one echo crossing in the time T, not the 4096 real stages.

Missing from this plan, to write before the work starts: a gain structure
(the level into the clip and the returns), the fallback with no plugin, the
change of the command count, and what a saved preset does once the delay's
crossfade law is gone.

## 12. The user's decisions (2026-11-13) and what follows from them

1. The reverb's knobs are SIZE and DECAY. The absorption is the result:
   `a = 1 - exp(-(0.161 V / T60 - 4 m V) / S)`. If that gives a below 0 or above
   1, no such room exists, and the page says so (the decay still plays).
2. The delay has noise. One knob, AGE, sets the chain's noise from none to the
   level of an old unit (about -70 dB before the expander). AGE at 0 also
   removes the compander, because it then has no work.
3. The reverb has a dark side. One knob, COLOR, runs from bright to dark. It
   sets the ratio of the decay at 8 kHz to the decay at 200 Hz, from 1 down to
   0.15, and the corner of that curve. Dark is a room of soft walls: the highs
   die first. It is the curve T60(f) of 5.2, not a filter on the output.
4. The delay's darkness is a target for the modulators. TONE is the corner of
   the two filters as a share of the clock, from 0.2 to 0.45. It stays under
   0.5, where the loop's bound of 4.5 holds.
5. The reverb's picture comes from the number four (12.2).

### 12.1 The diffusion, in four steps

The review asked for more diffusion in front of the late lines. The design
that answers it is the multichannel diffuser that Signalsmith describes
("Let's Write A Reverb", 2021). The input spreads to 8 channels. Each step
delays every channel by its own time, flips the sign of some, and mixes all 8
with a Hadamard matrix (unitary, 24 adds). Each step turns one echo into 8.

```
echoes after k steps = 8^k        four steps: 4096 echoes
step lengths: 1, 2, 4, 8 parts of a base time t_0, which follows SIZE
```

Four steps reach a normal echo density inside `15 t_0`. With t_0 = 5 ms that is
75 ms, which meets the target of section 9. Every step is unitary, so the
lossless proof of 5.2 covers the diffuser too. The cost is 32 short delays and
4 Hadamard mixes for each sample, which the review's method puts near 1.5%.
That figure is a guess until the norns measures it.

### 12.2 The picture: four squares

The page draws four squares, one inside the other, around one point. They are
the four steps of 12.1, so the picture is the mechanism.

- A sound enters at the centre. It lights the inner square, then the next, and
  each square is denser than the one before: 8, 64, 512, 4096.
- SIZE is the size of the squares. A small room packs them tight.
- DECAY is how long the outer square stays lit after the centre is dark.
- COLOR is the weight of the lines. A dark room draws thick, soft squares, and
  a bright one draws thin ones.
- The four tracks sit at the four corners. A track's send is a line from its
  corner to the centre, as bright as the send is open.

The screen rule of four greys gets one exception here: a fading square uses the
levels between, because a decay is a ramp.

### 12.3 Not found

The user named the reverb of "AP Mastering" as one to study. A search found no
description of how it works. The user must name the plugin or the video, and
this plan then takes what it does well.

### 12.4 Before any code

Four sections are still owed: the equations and tests for CHORUS, ECHO, RESON
and WOBBLE, the gain structure, the fallback with no plugin, and the fate of
old presets. Then a second review, of this whole draft.

## 13. Built first: the room's core (2026-11-13)

`Room` in `ugen/four_core.h`: the four diffusion steps of 12.1 and the eight
late lines of 5.2. It is the core only. No UGen, no engine and no page use it
yet, and nobody heard it. The proof is in `ugen/test_core.cpp` and passes on
the Mac and on the norns.

| Claim | Result |
|---|---|
| No loss set: the energy 10 s after a click against 1 s | 0.00 dB |
| That energy is the click's own | 0.00 dB |
| All 8 lines decay at one rate (500 Hz, 2, 4 and 10 kHz) | they differ by under 1% |
| Designed T60 at 0 Hz and at the top (2 s and 1 s asked) | 2.00 s and 1.00 s |
| Late decay against the design, 500 Hz to 10 kHz | 0.98 to 1.02 |
| Echo density 80 ms after a click | full |
| Left against right in the late field | correlation -0.02, level 0.02 dB |
| 60 s of silence after it | finite, under 1e-9 |
| Cost on the norns, plain C++, stereo | 4.2% of a core |

Three things the work found:

- Buffers of a power of two, set one after the other, all want the same places
  in the cache. The first build took 22.8% of a norns core. A gap of a
  different size after each buffer brought it to 4.2%. The sound is the same.
- A one-pole loss filter gave each line its own decay rate, as the review said.
  A first-order shelf whose middle sits at one frequency for every line gives
  one rate to all eight.
- The first 20 dB of the decay fall more slowly at the top than the design.
  The build-up of the four steps has no loss in it. The late slope (-20 to -50
  dB) is what the test reads.

Not done in this core: the early field of 5.3, a change of SIZE while it plays,
the slow movement of the lines, and the gain law for long decays.
