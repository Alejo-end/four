# The engine, mapped

Why `lib/Engine_Mangler.sc` is shaped the way it is. Each section is a decision that
survived contact with the hardware. Where there is a trade, it is stated. Change the engine
and this file tells you what you are about to fight.

## What runs

One persistent `io` synth owns input, the record head, the filter and the output.
It never dies because everything flows through it and respawning it would click.

Exactly one drone voice runs at a time (OFF, GRAIN, WARP, PV, PLAY, swapped by `setMode`).
The Pi 4 gives scsynth one core, so two stretch algorithms at once buy nothing and cost
xruns. This is also why a scene recall sets `mode` last: the new voice is born with the
scene's values instead of jumping to them.

Pad voices add onto the same bus the drone uses, so every note passes through the same
filter, delay and reverb. The allocator releases the oldest voice past the cap and keeps
releasing until it is under the cap, because the cap is a live knob.

The reverb is a separate synth that exists only while you can hear it. JPverb plus the
shimmer pitch shifter are the most expensive things in the file, and the mix knob is usually
at zero. The io synth sends into it and reads the tail back one block late, which is the
price of reading a node that runs later in the chain. Accepted trade: automating the mix
through zero frees the synth and cuts the tail, which was inaudible at zero anyway.

The delay is the same shape: its own synth, alive only while the mix is up, with one
exception. A near infinite feedback hold stays alive at mix zero, because the dub gesture
(pin the feedback, kill the mix, bring it back) parks a spinning loop behind a closed door
and expects it back. A low feedback tail dies on its own in a few repeats, so only the hold
is kept. The regeneration loop lives inside the synth, so freeing it is what flushes the
line, and `clear` uses exactly that: erasing the take also restarts both FX synths, so
nothing rings on with the erased material. Accepted trade: at rest the line is empty, so
raising the mix reveals echoes of what plays from then on, not of what played before.

## Why it cannot brick

Exactly one `Engine_Mangler` class may exist on the device. A duplicate hangs every norns
script on LOADING, which is why deploys use `rsync --delete`.

Every plugin UGen (JPverb, MiClouds, DFM1) is looked up by name so the file compiles without
it, and wrapped in `try` so a mismatch degrades to the stock fallback instead of failing to
load. A missing plugin costs lushness, never the instrument.

The command count printed at load is the deploy truth. If it does not match the number in
CLAUDE.md, an old engine is running and nothing you test means anything. New args on
existing commands are preferred over new commands so the count moves rarely.

The grain envelope buffers are filled before the server sync so the first grain that fires
already has its window.

## Recording

The take is the raw input, tapped before the whole chain. What you record is what came out
of your gear. Effects are playback clothing and can be removed. The one exception is
deliberate: `resample` blends the master output into the record path, and its blend
coefficient is smoothed because a step there is printed into the take forever.

DC is filtered on the way in and a transparent limiter at 0.99 stops a hot take from
clipping into the buffer. Punch ins fade over ten milliseconds while the head itself stays
sample exact.

`regen` runs the record head continuously and crossfades the output back over the buffer, a
slow self eating decay. The crossfade coefficients always sum to one and sit behind a
limiter, so it drifts forever but never runs away. It pauses when the output is stopped,
because a muted minute of regen used to overwrite the take with silence. The polled head
position advances with the same signal the record head uses, so the next take's window
cannot snap to a stale position.

`erode` lives in the PLAY voice and runs on its OWN head, one pass per window length
regardless of playback speed or direction: it reads the exact stored sample without
interpolation and writes back a slightly darkened, slightly quieter copy. At zero the exact
sample is written back unchanged, which is only true because the read is not interpolated.
Recording, freeze and a silenced deck (STOP) all suspend it, and the Lua layer interlocks it
against `regen`: two write heads never fight, and a stopped instrument never grinds the
take away with nobody listening.

The take rides the PSET as a left and right WAV pair, written only as far as the take
actually reaches.

## Playback

One window law serves all five voices. `winRead` computes where the read head is: edges
sorted, smoothed twenty milliseconds because they are performance encoders, speed from
`scan`. It exists once because five copies had already drifted apart once.

PLAY is the default and reproduces the recording at exactly unity. The pan law costs three
decibels at center and the bus makeup is the square root of two, its exact inverse, so
"you hear the recording" is arithmetic. A five millisecond fade at the loop seam removes the
click a window that does not end on a zero crossing would otherwise make on every pass.

GRAIN triggers grains with `Dust`, random rather than periodic, at audio rate so onsets are
not quantized to the control block. Every per grain random value is audio rate too, because
a control rate random sampled against audio rate triggers goes stale. Loudness is
compensated across the whole density and size plane: sparse clouds get a boost, dense clouds
get pulled down instead of pumping the limiter. With mi-UGens installed GRAIN becomes
MiClouds, fed by the same window scrub, called with positional arguments because keyword
arguments do not survive dispatch on a class held in a variable.

WARP and PV are the stock tools used straight, with cubic interpolation everywhere. Both
were checked against upstream documentation and left alone on purpose.

Pad voices copy the drone's grain character at spawn so a note sounds like this instrument.
The slice voice plays forward from the slice start, because the transient you chopped for
lives there, and it carries the slice LENGTH, closed with a three millisecond fade. Given
only a start it used to play its slice and then everything after it, while the PADS page
drew eight bounded cells.

## The chain

One DFM1 diode ladder replaces three parallel biquads. Low pass and high pass are native,
band pass is the resonant low pass peak high passed below the cutoff. Resonance is clipped
just under self oscillation and smoothed, because a stepped control change on a nearly
singing filter is the loudest pop available. The ladder is driven at half gain with a times
two makeup after: it is a nonlinear model, and fed the hot bus at unity it saturated on
every sample. Clean until `drive` asks for dirt.

Drive is a linear crossfade to a tanh stage with a true bypass at zero. Linear, not equal
power, because both arms are the same signal and the equal power law summed them into a
three decibel loudness bump at mid knob.

The delay darkens as it repeats: a low pass filter and a soft clip sit inside the feedback
loop, so repeats decay like tape. The feedback knob's curve lives in Lua and spreads the
useful range across the whole travel. Delay time is interpolated and smoothed, so time and
tempo changes glide instead of stepping. The mix stays a crossfade (a dub throw wants the
direct to duck), unlike the reverb's send.

A silenced deck is a stopped deck. Every drone def's read head runs on the deck level, the
same law the erosion and regen write heads follow: under a STOP, or with the mix thrown
fully to tape, the head freezes where it stands and resumes from that exact spot. The Lua
side halts the softcut transports and pauses the record head with it, all together, so the
decks keep their relative drift across a stop and start.

The reverb is a send, not a crossfade. The direct sound stays at full level across the whole
knob and the knob only decides how much tail is added. It used to trade the direct sound
away, which players reported as losing the recording. Shimmer is the tail pitch shifted,
band limited and fed back into the reverb input so it climbs into a halo, with a little
pitch dispersion so the shifter does not comb.

A limiter at 0.92 is the last thing before the output. Everything upstream is gain staged to
rarely touch it.

## Knobs and parameters

Every audible value is one norns parameter and the engine command has the same name. Keys,
encoders, MIDI, the grid, the gesture looper, scene morphs and the orbit are different hands
on the same parameters. The engine has one API and no back doors.

Response curves live in Lua, physics live in SuperCollider. The engine keeps honest equal
power laws; Lua shapes the knobs so they feel linear, curves the delay feedback, computes
clocked delay times. The engine never needs to know what a knob feels like.

Anything a hand rides is smoothed, between twenty and fifty milliseconds. Nothing musical is
lost at that speed and the zipper is gone.
