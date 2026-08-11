# mangler

A live stereo sampler for [norns](https://monome.org/norns/). Record anything line level,
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
rsync -av --delete --exclude='.git' ./ we@norns.local:~/dust/code/mangler/
```

Then SYSTEM > RESTART on the norns and pick mangler in SELECT. Two rules:

1. `--delete` matters. A stale second copy of `Engine_Mangler.sc` anywhere under
   `dust/code` hangs every norns script on LOADING.
2. Any change to the engine file needs SYSTEM > RESTART. Lua changes only need a script
   reload. After a restart the maiden log prints the engine command count; the expected
   number is in CLAUDE.md, and a different number means an old engine is still running.

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
| E1 | Select page |
| E2, E3 | The page's two knobs. Hold K1 for the second pair. Values show while turning. |
| K1 | Shift, hold |
| K2, K3 | The page's two actions, named in the footer |
| K1 + K2 | Stop and start everything, from any page |
| K1 + K3 | Tap: dry playback. Hold about a second: erase this page's material. |
| K1 + E1 | Morph toward the selected scene, from any page |

## Pages

| Page | What it does | Keys |
|---|---|---|
| TAKE | Record and frame the material | K2 record, K3 snap window |
| VOICE | How the take plays: PLAY, GRAIN, WARP, PV | K2 freeze, K3 mode |
| TAPE | A second loop deck with its own speed and direction | K2 record, K3 reverse |
| FILTER | Diode ladder filter plus drive | K2 open, K3 type |
| DELAY | Feedback echoes, optionally clocked | K2 infinite hold, K3 kill |
| REVERB | Tail and shimmer, added on top of the dry sound | K2 wash, K3 shimmer bloom |
| MIX | Input, both decks, output | K2 engine throw, K3 tape throw |
| PADS | The take chopped into eight playable slices | K2 play slice, K3 route notes |
| MOTION | Record and replay knob movements | K2 record, K3 play |
| SCENE | Capture, recall and morph whole sounds | K2 recall or peek, K3 capture |
| ORBIT | The instrument drifts between your scenes by itself | K2 run, K3 capture the moment |
| EROSION | Each loop pass ages the take a little | K2 heal, K3 scar |
| LAYERS | Two more loop decks, for building a piece in parts | K2 record, K3 mute |

Notes on the less obvious ones.

LAYERS gives you two independent loop decks beside the tape, so you can keep playing while
you record the next part. Each has its own loop points and speed, so a four-bar part
against a three-bar part drifts and re-syncs on its own. They record what the tape records
(dry input, or the processed output — one switch, on TAPE). What they cannot do is
granulate or stretch: that is the engine's take, and only the take gets it. MUTE silences
a deck without stopping its head, so two decks never lose their drift against each other.

ORBIT picks a stored scene, morphs partway toward it, parks there, then picks another. It
never fully arrives, so it keeps finding sounds between the ones you saved. K3 captures
whatever it found into the first empty slot. It needs at least one captured scene, and it
owns the morph knob while running.

EROSION works in PLAY mode. With erode up, every pass of the loop rewrites the window
slightly darker and quieter. Wear sets how dark. The GEN counter shows how many passes the
take has aged. Heal stops the decay where it stands. Recording is never affected.

SCENE slot zero, drawn as a left arrow, is the way back: every recall and chaos throw parks
the previous sound there automatically. Select it and tap K2 to undo. The `next scene`
parameter steps through filled slots and can be mapped to a footswitch, as can `chaos throw`.

## Notes and pads

A MIDI keyboard or a USB typing keyboard (letters as keys, Z and X for octave) retunes the
sample chromatically. With pad routing on they play the eight slices polyphonically instead.
Settings live in PARAMS under keys. The space bar stops and starts everything.

## Samples

Load: PARAMS > take > load sample reads WAV in 16, 24 or 32 bit. The window snaps to the
file. A 44.1 kHz file plays about nine percent fast; export at 48 kHz.

Export: PARAMS > take > export take writes the current take to `dust/audio` as a stereo WAV.

Print: PARAMS > take > print mix records the master output, everything you hear from both
decks and all effects, then loads that recording back as the take. Length zero means one
window length. The bounce also stays on disk, so material is never lost. Map it to a
footswitch and resampling becomes one stomp.

## Saving

PARAMS > PSET saves everything: parameters, the MIDI map, the take audio, the tape audio,
the scene bank and the per slice settings. Loading restores the whole session, sound
included.

## Grid

Optional. Rows one and two are always scenes and transport, rows seven and eight are always
a piano octave, and the middle rows follow the current page: window and loop spans, slice
pads, or the morph bar. On a Launchpad Mini MK3 pads are colored by meaning: red records,
green plays, white is the cursor, purple is destructive. Details in `lib/mgrid.lua`.

## Troubleshooting

1. Every script hangs on LOADING: almost always a duplicate engine class under `dust/code`.
   Redeploy with `rsync --delete`. Errors appear in maiden's SC tab, not matron.
2. Engine edits do nothing: you skipped SYSTEM > RESTART, or the printed command count does
   not match the expected one in CLAUDE.md.
3. Dry playback has reverb on it: check the system reverb under PARAMS, a raised reverb or
   delay mix, or clouds feedback. K1 plus K3 zeros all of them.
4. Reverb knobs beyond decay, damp and mix do nothing: JPverb is not installed and the
   FreeVerb fallback only honors those three.
5. A mystery loop that is not the take: the tape deck. The MIX page shows which deck is
   audible. Clear the tape on TAPE with the erase gesture.
6. Faint on headphones but fine on the line out: raise headphone gain under PARAMS > LEVELS.
7. Frozen or black screen after loading: a Lua error inside redraw. Scroll maiden below the
   ok line for the traceback.

## Architecture

One SuperCollider engine (`lib/Engine_Mangler.sc`, exactly one copy on the device) does
recording, playback voices and effects. softcut runs the tape deck on its own core. The Lua
side is `mangler.lua` plus modules in `lib/` sharing one context table, with the params
system as the single source of truth for every value. `dist/mangler_single.lua` is a
generated single file build; edit the modules, not that file. `tools/uisim/` renders every
page offscreen for testing without hardware.
