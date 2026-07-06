# mangler

A monome **norns** live stereo sample-mangling instrument for external line-level gear
(synth, drum machine, anything line-level). Performance-first: record, window, granulate,
time-stretch, tape-loop, filter, delay, reverb — played from **3 keys + 3 encoders**, with
**every parameter MIDI-mappable**. An optional **grid** (monome, or a launchpad-style MIDI
grid via midigrid) adds a pad surface. Built for **shield XL on Raspberry Pi 4**.

## What it does

- **Record** live stereo input into the engine.
- **Playback window** — select a slice of the recording with a start and stop.
- **Granular** clouds from the windowed slice.
- **Time-stretch** in several modes, independent of pitch.
- **Tape-like** playback — varispeed, reverse, looping, freeze (via softcut).
- **Filter** — low-pass / high-pass / band-pass.
- **FX** — delay (time + feedback) and reverb, each with its own dry/wet.
- **MIDI** — map any parameter to a CC from the PARAMS menu (saved per-script as a PMAP).
- **Chromatic note input** — play the sample from a MIDI keyboard (or a USB typing
  keyboard), retuning pitch in semitones without changing speed.
- **Grid (optional)** — a monome grid, or a launchpad-style MIDI grid via the midigrid
  library: note pads, window/loop slice pads, and transport toggles.

> **Status:** Stage 4 (filter + delay + reverb), on-device gate pending. Stages 1–3
> (record/granular/window, stretch modes, tape looper) have passed on hardware. See
> `CLAUDE.md` for the build order and `SPEC/spec.md` for the full design.

## Screens

Every frame below is real output — the actual script run through the offscreen renderer
(`SPEC/uisim/`) with a scripted take, tape loop, and live FX.

![WINDOW page: a recorded take, slice handles, scan readout](doc/ui/window.png)

| | |
|---|---|
| ![MIX page](doc/ui/mix.png)<br>**MIX** — engine ↔ tape crossfade; a silent engine lane lies flat | ![LEVEL page](doc/ui/level.png)<br>**LEVEL** — IN/OUT faders with live VU (hold K1: MON/HP) |
| ![REC page](doc/ui/rec.png)<br>**REC** — capture into the loop; empty buffer says `EMPTY - K2 REC` | ![GRAIN page](doc/ui/grain.png)<br>**GRAIN** — the cloud is a stereo-field plot: height = spread, dot size = grain size, x = read position |
| ![TAPE page](doc/ui/tape.png)<br>**TAPE** — reels spin at the real rate; loop + head below | ![FILTER page](doc/ui/filter.png)<br>**FILTER** — response curve, cutoff parked top-right |
| ![DELAY page](doc/ui/delay.png)<br>**DELAY** — one bounce per repeat; feedback shrinks the arcs | ![REVERB page](doc/ui/reverb.png)<br>**REVERB** — the room grows with size, rays are reflections |

**STRETCH** draws the active algorithm's own texture — grains, an overlapped warp window,
spectral columns — and lies flat when the voice is off:

| | |
|---|---|
| ![STRETCH in GRAIN mode](doc/ui/stretch-grain.png)<br>**GRAIN** — the wave sampled as grains | ![STRETCH in WARP mode](doc/ui/stretch-warp.png)<br>**WARP** — a ghost window overlaps (warp rand shakes it) |
| ![STRETCH in PV mode](doc/ui/stretch-pv.png)<br>**PV** — spectral columns; frozen, they stand still | ![STRETCH off](doc/ui/stretch-off.png)<br>**OFF** — voice freed, nothing moves |

## Install

The git repo *is* the script. Copy it into the norns scripts folder:

```sh
rsync -av --delete --exclude='.git' ./ <norns>:~/dust/code/mangler/
```

Then on the norns, `;restart` (or SELECT > mangler). `--delete` is important: it removes any
stale copy of the engine from the device, which would otherwise hang every script on
"LOADING".

## Controls (3 keys + 3 encoders)

| control | function |
|---------|----------|
| **E1**  | select page (**hold K1**: jump page family — source · shape · tape · fx) |
| **E2 / E3** | the page's two parameters (**hold K1** for the alt parameter on each) |
| **K1** (hold) | alt / shift modifier |
| **K2 / K3** | the page's two actions (toggle or momentary) |

Pages cycle with E1:
`MIX · LEVEL · REC · WINDOW · GRAIN · STRETCH · TAPE · FILTER · DELAY · REVERB`.
A page reference per stage is in `SPEC/spec.md`.

### MIDI

Every continuous and toggle parameter is MIDI-mappable: in the norns PARAMS menu, long-press
a parameter and assign a CC. Mappings are saved per-script to `data/mangler/mangler.pmap` and
reloaded automatically.

### Playing notes (chromatic pitch)

Plug a **MIDI keyboard** into the norns and play: each note-on retunes the sample's pitch in
semitones, independent of playback speed, in all three stretch modes. MIDI note 60 plays the
sample as recorded (set by the `root note` param), with a ±24 semitone range. Notes retune
the running voice — last-note priority, no envelope — so it plays like tuning a texture, not
a polyphonic sampler.

A **USB typing keyboard** works too, Ableton-style musical typing: the `A` row is the white
keys (`A` = as recorded), the `W` row the black keys, and `Z` / `X` shift the octave.

Settings live in **PARAMS > keys**: note input on/off, MIDI channel (default: any), root
note, typing-keyboard octave, and **pitch quantize** — which also snaps the pitch encoder
and any mapped CC to semitones.

### Grid (optional)

mangler needs no grid — but if one is attached it becomes an 8×8 performance surface.
A **monome grid** just works. A **launchpad-style MIDI grid** (Launchpad family, APC mini)
works through the community [midigrid](https://github.com/miker2049/midigrid) library:
install it on the norns (maiden REPL: `;install https://github.com/miker2049/midigrid`),
plug the controller in, and load mangler — it is adopted automatically whenever no real
monome grid is attached.

```
row 1    ENGINE  [rec] [freeze]  ·  [OFF][GRAIN][WARP][PV]  [pv freeze]
row 2    TAPE    [rec] [freeze] [reverse (hold)]  ·  ·  ·  ·  ·
row 3    WINDOW  8 slice pads — tap = that eighth, hold one + tap = the span
row 4    LOOP    8 slice pads for the tape loop, same gesture
rows 5–8 NOTES   two piano octaves, black row above its white row (same shape
                 as musical typing; upper pair +1 octave). row 7 corners =
                 octave −/+ · row 5 corners = pitch reset / pitch quantize
```

Pads drive the same params as everything else, so grid, keys, encoders, and MIDI CCs stay
in lockstep. The grid controller's own MIDI is excluded from chromatic note input — its
pads are pads, not notes. (The grid layer is new and not yet verified on hardware.)

## Performance model (Pi 4)

scsynth runs on a single core; xruns appear past roughly 60% load. mangler keeps **softcut**
(a separate, near-free audio core) doing all it can — record, loop, varispeed, reverse,
filter — and puts in scsynth only what softcut cannot: granular, time-stretch, and the custom
filter/delay/reverb. The three SC playback algorithms (granular / Warp1 / phase-vocoder) are a
**mode switch** on one voice, so their cost is never paid simultaneously. Estimated all-active
worst case ≈ 35–45% of one core.

## Testing checklist

Each stage has an on-device acceptance test in `SPEC/spec.md`. The gate, every stage:

1. `luac5.3 -p mangler.lua` passes locally.
2. Deploy, `;restart`. The script loads to its home page with **no LOADING hang** and **no SC
   errors** in maiden.
3. Run the current stage's acceptance test from `SPEC/spec.md`.

Passing a stage's gate unlocks the next (current stage: see the top of `CLAUDE.md`).

## Layout

```
CLAUDE.md              agent manual: invariants, build order, current stage
README.md              this file
SPEC/spec.md           durable design contract (full per-stage detail)
SPEC/uisim/            offscreen UI renderer: see every page as a PNG, no hardware
doc/ui/                rendered page gallery used by this README
mangler.lua            orchestrator: state, params, keys/encoders (engine.name = 'Mangler')
lib/mfont.lua          the 4x5 pixel font and type-setting routines
lib/mparticles.lua     pooled grain-cloud particle system
lib/mtape.lua          softcut plumbing: tape path, eng<>tape mix, PSET tape audio
lib/minput.lua         chromatic note input: MIDI notes + USB typing keyboard
lib/mgrid.lua          optional grid surface (monome, or midigrid controllers)
lib/mpages.lua         the screen: wave models, page bodies, header/footer
lib/Engine_Mangler.sc  the one and only SuperCollider engine file
```
