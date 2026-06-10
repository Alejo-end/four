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

> **Status:** Stage 0 — a loadable skeleton (no-op engine + control shell). The DSP is being
> brought up one stage at a time on hardware. See `CLAUDE.md` for the build order and
> `SPEC/spec.md` for the full design.

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

Pages cycle with E1: `MIX · REC · WINDOW · GRAIN · STRETCH · TAPE · FILTER · DELAY · REVERB`.
A page reference per stage is in `SPEC/spec.md`. (Stage 0 wires the MIX/global params; later
stages wire their pages.)

### MIDI

Every continuous and toggle parameter is MIDI-mappable: in the norns PARAMS menu, long-press
a parameter and assign a CC. Mappings are saved per-script to `data/mangler/mangler.pmap` and
reloaded automatically.

## Performance model (Pi 4)

scsynth runs on a single core; xruns appear past roughly 60% load. mangler keeps **softcut**
(a separate, near-free audio core) doing all it can — record, loop, varispeed, reverse,
filter — and puts in scsynth only what softcut cannot: granular, time-stretch, and the custom
filter/delay/reverb. The three SC playback algorithms (granular / Warp1 / phase-vocoder) are a
**mode switch** on one voice, so their cost is never paid simultaneously. Estimated all-active
worst case ≈ 35–45% of one core.

## Testing checklist

Each stage has an on-device acceptance test in `SPEC/spec.md`. The Stage-0 gate:

1. `luac5.3 -p mangler.lua` passes locally.
2. Deploy, `;restart`. The script loads to its home page with **no LOADING hang** and **no SC
   errors** in maiden.
3. E1 changes the page indicator; keys register on screen.

Passing Stage 0 unlocks Stage 1.

## Layout

```
CLAUDE.md              agent manual: invariants, build order, current stage
README.md              this file
SPEC/spec.md           durable design contract (full per-stage detail)
mangler.lua            Lua control layer (engine.name = 'Mangler')
lib/Engine_Mangler.sc  the one and only SuperCollider engine file
```
