# mangler

A monome **norns** live stereo sample-mangling instrument for external line-level gear
(synth, drum machine, anything line-level). Performance-first: record, window, granulate,
time-stretch, tape-loop, filter, delay, reverb — played from **3 keys + 3 encoders**, with
**every parameter MIDI-mappable**. Built for **shield XL on Raspberry Pi 4**.

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

> **Status:** Stage 4 (filter + delay + reverb), on-device gate pending. Stages 1–3
> (record/granular/window, stretch modes, tape looper) have passed on hardware. See
> `CLAUDE.md` for the build order and `SPEC/spec.md` for the full design.

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
| **E1**  | select page |
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
mangler.lua            Lua control layer (engine.name = 'Mangler')
lib/Engine_Mangler.sc  the one and only SuperCollider engine file
```
