# four

A live stereo sampler for [norns](https://monome.org/norns/) with four tracks. Each track
records or loads its own material and has its own voice, filter, colour and effect sends;
tracks can feed each other. It was called mangler. Record anything line level,
loop it back exactly as recorded, then process it: time stretch, granular, tape varispeed,
filter, delay, reverb, playable slices, a gesture looper, scene morphing, and controlled
decay. Three keys and three encoders run everything. A grid is optional. Every parameter is
MIDI mappable.

Built and tested on a norns shield XL with a Raspberry Pi 4. Older hardware is untested.

![Signal flow](doc/signal-flow.svg)

Status: in active development, built in stages that are each verified on hardware.
[CLAUDE.md](CLAUDE.md) holds the build log, [doc/spec.md](doc/spec.md) the engine spec,
[doc/engine-map.md](doc/engine-map.md) explains every engine decision in plain words.
Rendered screens for every page are in `doc/ui/`.

## Requirements

A norns on current software. Optional: a MIDI controller, a USB typing keyboard, and a grid
(monome, Launchpad Mini MK3 driven natively in color, or other Launchpad and APC models
through [midigrid](https://github.com/jaggednz/midigrid)). JPverb (sc3-plugins) and MiClouds
(mi-UGens) are used automatically when installed and are never required.

## Install

```sh
rsync -av --delete --exclude='.git' ./ we@norns.local:~/dust/code/four/
```

Then SYSTEM > RESTART on the norns and pick four in SELECT. Two rules:

1. `--delete` matters. A stale second copy of `Engine_Four.sc` anywhere under
   `dust/code` hangs every norns script on LOADING.
2. Any change to the engine file needs SYSTEM > RESTART. Lua changes only need a script
   reload. After a restart the maiden log prints the engine command count. It must read
   `count: 185`; any other number means an old engine is still running.

## First session

1. Plug in your gear. On TAKE press K2, play a phrase, press K2 again. The window snaps to
   what you played and loops it back dry. The small diamond next to the title means you are
   hearing the recording exactly.
2. Turn E2 and E3 to move the window edges. On VOICE, K3 cycles PLAY, GRAIN, WARP, PV. The
   screen texture shows the active mode.
3. FILTER, DELAY and REVERB all start at zero. Dial them in. Reverb adds tail without ever
   lowering the recording itself.
4. On PADS, E2 selects one of eight slices and K2 plays it. Each slice can have its own
   voice type and pitch. Plug in a MIDI or typing keyboard and tap K3 to play slices
   polyphonically.
5. On SCENE, K3 captures the whole current sound into a slot. Change everything, then turn
   E3 to morph from where you are toward the stored scene. Back to zero returns you exactly
   home. K2 recalls. Holding K2 borrows the scene and releasing comes back.
6. Two reflexes work on every page. K1 plus K2 stops and restarts all sound. K1 plus K3
   makes playback dry instantly, and holding it about a second erases the current page's
   material.

## Controls

Every key follows one rule: press engages immediately, a quick release latches it, a longer
hold acts while held and releases when you do, and pressing a latched key turns it off.

| Control | Action |
|---|---|
| E1 | Select page. The destination's name pops up big while you scroll. |
| E2, E3 | The page's two knobs. Hold K1 for the second pair. Values show while turning. |
| K1 | Shift, hold |
| K2, K3 | The page's two actions, named in the footer |
| K1 + K2 | Stop and start everything, from any page. Every head freezes and resumes in place. |
| K1 + K3 | Tap: dry playback. Hold about a second: erase this page's material. |
| K1 + E1 | Morph toward the selected scene, from any page |

The full map of every page's knobs and keys, generated from the code, is in
[doc/controls.md](doc/controls.md).

## Pages

The stations sit in families: the take (TAKE, VOICE), the loop decks (TAPE, LAYERS), the
tone (FILTER, EFFECT, DELAY, REVERB), the console (MIX), and the performance layer (PADS, MOTION,
SCENE). Erosion lives on VOICE (it only works in PLAY mode) and the orbit lives on SCENE.

| Page | What it does | Keys |
|---|---|---|
| TAKE | Record and frame the material | K2 record, K3 tap snap window, hold undo |
| VOICE | How the take plays: PLAY, GRAIN, WARP, PV. In GRAIN the picture is the grain cloud, left channel at the top. In PLAY the alt knobs erode the take. | K2 freeze (heal in PLAY), K3 mode |
| TAPE | A second loop deck with its own speed and direction | K2 record, K3 reverse |
| LAYERS | Two more loop decks, for building a piece in parts | K2 record, K3 mute |
| FILTER | Diode ladder filter plus drive | K2 open, K3 type |
| EFFECT | One effect for the focused track: chorus, flange, wobble, reson or ring. E2 is the amount, E3 the rate. | K2 on and off, K3 next effect |
| DELAY | Feedback echoes, optionally clocked | K2 infinite hold, K3 kill |
| REVERB | Tail and shimmer, added on top of the dry sound | K2 wash, K3 shimmer bloom |
| MIX | Input, both decks, output | K2 engine throw, K3 tape throw |
| PADS | The take chopped into eight playable slices | K2 play slice, K3 route notes |
| MOTION | Record and replay knob movements, and the two modulators | K2 record, K3 play |
| SCENE | Capture, recall and morph whole sounds. The alt knobs run the orbit. | K2 recall or peek, K3 capture |

The header shows what runs, from any page. A blinking R, T, M or L means the take, the
tape, the motion looper or a layer deck is recording. FZ and TF are the freezes, RP a held
beat repeat, SQ the pad sequencer and LF a modulator. When many are lit, a flag shrinks to
its letter or to a short bar, but it never disappears.

Notes on the less obvious ones.

LAYERS gives you two independent loop decks beside the tape, so you can keep playing while
you record the next part. **They work like a loop pedal**: press K2 on an empty deck, play
a phrase, press it again, and the loop is exactly that phrase, playing from its start.
Press K2 again and you are overdubbing into it. The length is set by the first pass and
nothing after that moves it. **Arming a layer records the processed engine output by
default**: resampling the mangled sound into a loop is just K2, and both deck pages say
SRC WET while it happens. Turn `layers record the mix` off in PARAMS and the decks follow
the tape's source switch instead (dry input, or the processed output, on TAPE). A wav can
also be loaded straight into a deck: PARAMS > layers > load file, with the loop snapping to
the file. What a deck cannot do is granulate or stretch: that is the engine's take, and
only the take gets it. MUTE silences a deck without stopping its head, so two decks never
lose their drift against each other. For a full-mix bounce that becomes the new take, use
print (below).

Hand-played loops are never quite the length you meant, and two decks at 3.97 and 4.02
seconds walk apart inside a minute. **SNAP puts a loop's length on a musical grid**: a
half, a double, a three-to-two of whatever else is playing. The other deck if it holds
audio, otherwise the take's window, otherwise a bar of the clock. It only moves the loop
end, so it is undoable by hand. When you close a recording that already landed within a few
percent of a ratio, it rounds on its own and says so; anything further out is a length you
chose and is left exactly as played. To force it, map `L1 snap loop` to a footswitch or use
the grid (LAYERS row 6, pads 4 and 5). Watch the name: TAKE's K3 is also SNAP, and it does
the other thing, fitting the window to where the sound is. Each deck also has its own loop
**seam** (a hard edit for a drum loop, a long blend for a pad) and **width**, so two decks
on related material do not have to be the same wall of stereo.

The orbit lives on SCENE: it picks a stored scene, morphs partway toward it, parks there,
then picks another, never fully arriving, so it keeps finding sounds between the ones you
saved. Hold K1 on SCENE for its two knobs (drift time and reach); start and stop it with
the `orbit run` parameter (MIDI-map a footswitch) or the grid's scene row, and an ORBIT
chip blinks on the page while it wanders. CAP during a wander bottles the in-between sound
into the first empty slot. Move the morph yourself (K1+E1, a MIDI fader, a peek) and the
orbit stands still; two seconds after you let go it carries on from where you left it.

The `recall quantize` parameter decides when a recall lands: NOW, on the next BEAT or BAR,
or GLIDE, where the morph sweeps to the scene over `glide beats` and then the scene lands,
a crossfade instead of a jump. Turning the morph or the selector mid-glide stops it where
it stands.

A MOTION loop's first pass, played within a few percent of a musical length of the clock,
loops exactly on that length (the same rule as the layers' SNAP), so it stays in time with
the clock, the synced delay and the decks.

Erosion lives on VOICE and works in PLAY mode, the one mode the engine erodes in. With
erode up (hold K1 for erode and wear), every pass of the loop rewrites the window slightly
darker and quieter, the GEN counter counts the passes, and K2 becomes HEAL: hold it to
park the decay and let go to resume, or tap to latch it stopped. Recording is never
affected.

SCENE slot zero, drawn as a left arrow, is the way back: every recall and chaos throw parks
the previous sound there automatically. Select it and tap K2 to undo. The `next scene`
parameter steps through filled slots and can be mapped to a footswitch, as can `chaos throw`.
A recalled scene never opens the playback window past the recorded material: a scene
captured with the window wide, recalled over a short take, lands on the take instead of
sixty seconds of mostly silence. The `capture scope` parameter switches CAP to FX-only
scenes: a slot that stores just filter, drive, delay, reverb and shimmer, and lands or
morphs over whatever material is playing.

## Recording

Turn on PARAMS > take - record > start on sound, and an armed take starts where the sound
does. K2 arms as usual and TAKE shows WAIT until what is being recorded crosses the sound
threshold. The take then starts there, with a short pre-roll that keeps the attack. The
recording itself runs from the arm, so nothing is lost while the level is read. A pass with
no sound over the threshold keeps the whole pass, and an overdub never waits. While it is
on, TAKE shows ON SND top right, so you know before you arm.

PARAMS > take - window > win length locks the window's length to the clock: one beat to
eight bars at the current tempo. The window's start carries the length with it, so moving
the start slides the whole window, a record pass comes out that long, and a tempo change
re-times it. Moving the end yourself (E3, SNAP, a scene, the morph) is left as you put it
until the next of those. TAKE shows the length top right.

Hold K3 on TAKE for about a second (the arc, as for the eraser) to go back to the take before
the last finished change: a record pass, a load, a print, a PSET, regen or erosion going
quiet, or a clear. Hold it again to come forward. A tap is still SNAP, and TAKE says on its
top row what either one did. A "<" at the top left means there is a take to go back to.
PARAMS > take - record > undo take does the same from a footswitch. The window comes back with it. Each finished change writes the take
to the card once, at most two takes' worth; turn `keep an undo` off to save the card.

## Notes and pads

A MIDI keyboard or a USB typing keyboard (letters as keys, Z and X for octave) retunes the
sample chromatically. With pad routing on they play the eight slices polyphonically instead.
Settings live in PARAMS under keys. The space bar stops and starts everything.

The pad sequencer (PARAMS > pads - sequencer) plays the pads on the clock, so their own
voices and pitches become a progression. By default it steps through four pads a bar each,
legato: a slow drone sequence. `steps that play` spreads that many hits evenly over
`steps`, `pad order` walks the pads up, down, back and forth or at random, `step chance`
skips hits, and `step gate` shortens each hit. PADS draws the pattern under the pads, dim
while it is stopped and bright with the current step while it runs. Map `sequencer run` to
a footswitch to start and stop it. On the grid's PADS rows, row 6 pad 3 runs it and pads 5
and 6 take a hit away or add one.

## Modulators

PARAMS > modulators holds two LFOs. Each one moves the sound of one engine knob: pick its
target, a shape (sine, triangle, square, ramp, random, or ENV, the input's envelope), a
period (free in Hz, or one beat to eight bars on the clock) and a depth. The modulator never
moves the knob itself, only what the engine hears, so the knob stays where you, a scene or a
motion lane put it, and the sound swings around it. Scenes, UNDO, the motion loop and a PSET
all store the knob, never the wave. Two modulators on one knob add up. A negative depth
inverts the wave, so ENV with a negative depth ducks the sound while the gear plays. The
pages draw the knob, not the swing; the header shows LF while a modulator runs and SQ while
the sequencer does.

The two modulators also live on MOTION, as two rows under the lanes. Turn E2 past the last
lane to select one: its row draws its wave and what it moves ("1>CUT"), E3 sets its depth,
K1+E2 its period and K1+E3 its target. Holding K1+K3 on a modulator row lets it go. The
shape and the free rate stay in PARAMS.

PARAMS > beat repeat is a stutter on the clock. Hold `beat repeat` (map it to a pad or a
footswitch) and on the next division the engine captures that much of what you hear and
loops it until you let go. `repeat length` sets the division, a half note to a 32nd, and
turning it while you hold re-captures a shorter slice: a roll. STOP releases it. The header
shows RP and the division while it holds (RP8 for an eighth). On the grid, row 6 of the main
workspace holds a repeat at a half note to a 32nd (pads 1 to 5): slide a finger across them
for a roll. Resampling and PRINT record the sound without the stutter.

PARAMS > modulation out sends one of those movements to other gear: the scene morph (so
the orbit and a GLIDE move your synth too), the input envelope, or an LFO's wave, which
runs even when it moves no knob. It goes out as a MIDI CC on the port, channel and number
you pick, and to crow output 1 as 0 to 5 volts when a crow is connected.

## Samples

Load: PARAMS > take > load sample reads WAV in 8, 16, 24 or 32 bit, integer or float. The
window snaps to the file. A file at any sample rate loads in tune: off-rate files are resampled on the way in
through a windowed-sinc kernel. That matters most coming DOWN from 88.2k or 96k: there,
everything above the server's own limit has to be removed before resampling or it folds
back into the audible band as tones that were never in the file. PARAMS > layers > load
file does the same into a layer deck.

Export: PARAMS > take > export take writes the current take to `dust/audio` as a stereo
24-bit WAV. The take rides PSET save and load at the same depth.

Print: PARAMS > take > print mix records the master output, everything you hear from both
decks and all effects, then loads that recording back as the take. Length zero means one
window length. The bounce also stays on disk, so material is never lost. Map it to a
footswitch and resampling becomes one stomp.

## Saving

PARAMS > PSET saves everything: parameters, the MIDI map, the take audio, the tape and
layer audio, the scene bank, the motion loop and the per slice settings. Loading restores
the whole session, sound included, and the motion loop comes back playing if it was.
The decks save only as far as they hold material, so a short loop makes a small file.

## Grid

Optional. Rows one and two are always scenes and transport, rows seven and eight are always
a piano octave, and the middle rows follow the current page: window and loop spans, slice
pads, or the morph bar. On a Launchpad Mini MK3 pads are colored by meaning: red records,
green plays, white is the cursor, purple is destructive. Its left and right arrows step the
page, up and down step the scene slot, and it can be plugged in after the script has
loaded. In pad mode the piano rows light the keys whose pad is sounding. Details in
`lib/mgrid.lua`.

## Troubleshooting

1. Every script hangs on LOADING: almost always a duplicate engine class under `dust/code`.
   Redeploy with `rsync --delete`. Errors appear in maiden's SC tab, not matron.
2. Engine edits do nothing: you skipped SYSTEM > RESTART, or the printed command count is
   not `count: 66`.
3. Dry playback has reverb on it: check the system reverb under PARAMS, a raised reverb or
   delay mix, or clouds feedback. K1 plus K3 zeros all of them.
4. Reverb knobs beyond decay, damp and mix do nothing: JPverb is not installed and the
   FreeVerb fallback only honors those three.
5. A mystery loop that is not the take: the tape deck. The MIX page shows which deck is
   audible. Clear the tape on TAPE with the erase gesture.
6. Faint on headphones but fine on the line out: raise headphone gain under PARAMS > LEVELS.
7. Frozen or black screen after loading: a Lua error inside redraw. Scroll maiden below the
   ok line for the traceback. Once running, a Lua error inside one frame no longer freezes
   anything: maiden prints `frame error` and the instrument carries on.

## Architecture

One SuperCollider engine (`lib/Engine_Mangler.sc`, exactly one copy on the device) does
recording, playback voices and effects. softcut runs the tape deck on its own core. The Lua
side is `four.lua` plus modules in `lib/` sharing one context table, with the params
system as the single source of truth for every value. `dist/mangler_single.lua` is a
generated single file build; edit the modules, not that file. `test/uisim/` renders every
page offscreen for testing without hardware.
