# The engine, mapped — every decision and why

A mind map of `lib/Engine_Mangler.sc` in plain words. Each branch is a decision
that survived contact with the hardware; where there's a trade, it's stated,
not hidden. If you change the engine, this file tells you what you're about to
fight.

```
                                ┌─ TOPOLOGY: who runs, when
                                ├─ SAFETY: why it can't brick
        ONE ENGINE ─────────────┼─ RECORDING: what gets written
        (everything audible     ├─ PLAYBACK: the five voices
         except the tape deck)  ├─ THE CHAIN: filter → delay → reverb
                                └─ CONTROL: how knobs reach DSP
```

## TOPOLOGY — who runs, when

**One persistent `io` synth** owns input, the record head, the filter, the
delay, and the output. It never dies, because everything flows through it and
respawning it would click.

**Exactly one drone voice at a time** (OFF / GRAIN / WARP / PV / PLAY, swapped
by `setMode`). The Pi 4 gives scsynth one core; running two stretch algorithms
at once buys nothing and costs xruns. Switching modes frees one synth and
spawns another — that's also why `mode` is always the *last* thing a scene
recall sets: the new voice is born with the scene's params instead of jumping
to them.

**Polyphonic pad voices add onto the same bus** (`play_bus`) the drone uses,
so every note passes through the same filter/delay/reverb — one chain, no
special cases. The allocator release-steals the oldest voice past the cap, and
keeps stealing until it's *under* the cap, because the cap is a live knob.

**The reverb is a separate synth that exists only while you can hear it.**
JPverb plus the shimmer pitch-shifter are the most expensive things in the
file, and most of the time the mix knob is at zero. `io` sends into it and
reads the tail back through `InFeedback` (one block late — the price of a
backward edge between nodes). The trade, accepted with eyes open: automating
the mix *through* zero frees the synth and cuts the tail dead. At zero it was
inaudible anyway.

## SAFETY — why it can't brick

**Exactly one `Engine_Mangler` class on the device, ever.** A duplicate hangs
every norns script on "LOADING" — not just this one. Deploys use
`rsync --delete` for exactly this reason.

**Every plugin UGen is guarded twice.** JPverb, MiClouds, and DFM1 are looked
up by name (`.asClass`) so the file compiles without them, and their graphs
are wrapped in `try` so a mismatch degrades to the stock fallback (FreeVerb,
GrainBuf, RLPF/RHPF/BPF) instead of failing alloc. A missing plugin costs you
lushness, never the instrument.

**The command count is the deploy truth.** 63 commands, counted statically.
After every restart, the load log either says 63 or you are running an old
engine and nothing you test means anything. Arity changes (extra args) are
deliberately preferred over new commands so the fingerprint stays put.

**Grain envelope buffers fill before `s.sync`**, so the first grain that ever
fires already has its window. Learned the hard way; don't move it.

## RECORDING — what gets written

**The take is the raw ADC, tapped before the whole chain.** At the default
settings, what you record is what came out of your gear — no filter, no
reverb, nothing baked in. Effects are playback clothing, removable. The one
exception is deliberate: `resample` blends the master output into the record
blend, and that *is* bake-the-mangle-in, by request. Its blend coefficient is
lagged because a step there is printed into the take forever, not heard once.

**`LeakDC` on the way in, a transparent limiter (0.99) after.** DC from a
line input would eat headroom silently; a hot take would hard-clip into the
buffer. Neither is allowed to reach the material.

**Punch-ins fade over ~10 ms** (lagged write levels) while the head itself
stays sample-exact — softcut's manners, applied to the engine deck.

**`regen` is the self-eating tape.** The record head runs continuously and
crossfades the *output* back over the buffer — a slow Basinski decay. It's a
convex crossfade (coefficients always sum to 1) behind a limiter, so it can
drift forever but never run away. It pauses when the deck is choked, because
a muted minute of regen used to mean crossfading silence over your take. And
the polled head position advances with the same signal the record head uses,
so the next take's window can't snap to a stale position.

**The take rides the PSET** as an L/R wav pair (two mono buffers, because
scsynth has no cheap interleave), written only as far as the take actually
reaches — never the whole 60-second buffer of silence.

## PLAYBACK — the five voices

**One window law for all five voices.** `winRead` computes where the read
head is — window edges sorted, lagged ~20 ms (they're performance encoders;
unsmoothed moves clicked), traversal speed from `scan`. It exists once
because five hand-copies of it had already drifted once.

**PLAY is the default and it is the truth mode**: a plain cubic-interpolated
read of the window. The gain math lands at *exact* unity — the pan law costs
−3 dB at center and the bus makeup is √2, its exact inverse — so "you hear
the recording, verbatim" is arithmetic, not marketing. A ~5 ms fade at the
loop seam kills the click a non-zero-crossing window otherwise emits every
pass; that fade is the entire distance from verbatim.

**GRAIN is Poisson, not periodic.** `Dust` triggers (audio-rate, so onsets
aren't quantized to the control block) decorrelate the two channels and kill
machine-gun buzz. Every per-grain random (position, pan, size, pitch) is
audio-rate too, because a control-rate random sampled against audio-rate
triggers goes stale. Loudness is compensated across the whole density × size
plane — sparse clouds get a boost (≤2×), dense clouds get pulled down instead
of pumping the limiter. When mi-UGens is installed, GRAIN becomes MiClouds
instead — same window scrub feeding a Clouds port, positional args because
keyword args don't survive dispatch on a variable-held class.

**WARP and PV are the stock tools used straight**: Warp1 with cubic
interpolation; a 2048-point FFT with the documented-correct phase-vocoder
window into `PV_MagFreeze`. Both were audited against upstream docs; the
temptation to "improve" them was investigated and declined.

**Pad voices copy the drone's character** — size, density, spread, jitter,
pan — at spawn, so a pad note sounds like a note *of this instrument*, not a
second instrument. The slice voice is a forward PlayBuf (already cubic) from
the slice's *start*, because the transient you chopped for lives there.

## THE CHAIN — filter → delay → reverb

**One DFM1 diode ladder, not three parallel biquads.** LP and HP are its two
native modes; BP is built by high-passing the resonant LP peak — a band with
diode character rather than a clean textbook BP. Resonance is clipped at 0.9,
just under where the model self-oscillates, and lagged, because a stepped CC
on a nearly-singing filter is the loudest pop in the file. The ladder is
*driven at half gain and made up ×2 after*: it's a nonlinear model, and fed
the bus's hot makeup at unity it saturated on every sample — "the engine
sounds noisy". Cleanliness until `drive` asks for dirt.

**Drive is a linear crossfade to a tanh, with true zero at zero.** Linear, not
equal-power, because both arms are the same signal — equal-power summed them
into a +3 dB loudness bump at mid-knob that flattered the knob and lied about
the level. At zero the bypass is bit-true.

**The delay darkens as it regenerates** — a 3.5 kHz low-pass and a softclip
*inside* the feedback loop, so repeats decay like tape, not like a digital
buffer. The feedback knob's curve lives in Lua (`0.98·v^0.6`), spreading
few → many → nearly-forever across the whole travel instead of the last 5%.
Delay time is interpolated and lagged, so time changes (and tempo-sync
follows) glide with a varispeed bend instead of stepping.

**The reverb is a send, not a crossfade.** The direct sound stays at full
level across the whole mix knob; the knob only decides how much tail is added
on top. It used to be an equal-power trade — turning up reverb turned *down*
your recording, which is exactly what a performer reported as "I can't hear
the sound". Full-wet washes moved to where they belong: decay cranked to 30 s
(the WASH key), or choking the source. Shimmer is pitched feedback *around*
the reverb — the tail, shifted (usually an octave up), band-limited, and fed
back into the input so it climbs into a halo; a small pitch dispersion keeps
it from combing robotically.

**A limiter at 0.92 is the last thing before the DAC.** Everything upstream
is gain-staged to rarely touch it; it exists for the day everything sums.

## CONTROL — how knobs reach DSP

**Every audible value is one norns param**, and the engine command has the
same name. Keys, encoders, MIDI, grid, the gesture looper, and scene morphs
are all just different hands on the same params — the engine has exactly one
API and no back doors.

**Response curves live in Lua, physics live in SC.** The engine keeps honest
equal-power laws; Lua squares the mix knobs so they *feel* linear, curves the
delay feedback so it *feels* even, computes tempo-synced delay times from the
clock. The engine never needs to know what a knob feels like.

**Anything a hand rides is lagged** — cutoff, resonance, drive, the mixes,
the window edges, the write levels. The zipper is the enemy; ~20–50 ms is the
cure; nothing musical is lost at that speed.
