# Octatrack as a controller

One MIDI track on the Octatrack sends the controls. All of them use MIDI channel 16, so they never collide with note tracks. The file `data/octatrack.pmap` holds the same list in the norns mapping format.

## Setup

1. Octatrack MIDI OUT to the shield's TRS MIDI IN. Check Type A or B.
2. Octatrack: pick a MIDI track (for example MIDI track 8), set its channel to 16, and assign the CCs below to its CC knobs (CC pages of the MIDI track).
3. norns: in the four PARAMS menu set `midi channel` to a channel the Octatrack does not use for notes (for example 1), so notes on 16 never play the instrument.
4. Load the mapping: copy `data/octatrack.pmap` to `~/dust/data/four/four.pmap` on the norns, then reload four. Its channel 16 entries use `dev=2`: the Octatrack must be on MIDI port 2 (SYSTEM, DEVICES, MIDI). If it is on another vport, change `dev` in the file, or map by hand in the PARAMS menu with MIDI learn.
5. The old mapping of `rec` on CC 100 (channel 1, port 1) is kept in the file, unchanged.

## Knobs (continuous, 0 to 127)

| CC | parameter | what it does |
|---|---|---|
| 70 | `size` | grain size |
| 71 | `density` | grain density |
| 72 | `spread` | grain spread |
| 73 | `grain_jitter` | grain jitter |
| 74 | `cutoff` | filter cutoff |
| 75 | `resonance` | filter resonance |
| 76 | `drive` | drive |
| 77 | `dry_wet` | dry / wet |
| 78 | `delay_mix` | delay mix |
| 79 | `rev_mix` | reverb mix |
| 80 | `scene_morph_amt` | scene morph |
| 81 | `vis_look` | visuals look (0 AUTO to 127 FACETS) |

## Buttons (send 127 to press, 0 to release)

| CC | parameter | what it does |
|---|---|---|
| 90 | `freeze` | freeze |
| 91 | `pv_freeze` | spectral freeze |
| 92 | `tape_freeze` | tape freeze |
| 93 | `tape_rec` | tape record |
| 94 | `stop_all` | stop all |
| 95 | `beat_repeat` | beat repeat (hold) |
| 96 | `vis_flash` | visuals flash (hold) |
| 97 | `scene_recall` | recall the selected scene |
| 100 | `rec` | record (kept from the old mapping, channel 1) |

Hold-type buttons (beat repeat, flash) are momentary: 127 on, 0 off. On the Octatrack, put the value on a step as a parameter lock for the CC, or turn a knob past the middle. A toggle (freeze, stop all) should change state when the value passes the middle. I have not tried this on hardware, so test each button once before the show.

## Not mapped on purpose

Pitch and the window or loop positions: their ranges are not a simple 0 to 127 line, and a bad sweep is loud. Use the norns encoders or the grid for those.
## Without the Octatrack (fallback)

The mapping is inert when no Octatrack sends channel 16: every parameter still answers to the
encoders, keys, grid and screen as before, and nothing needs switching off. The grid has the
visuals pads (row 6, x6 to x8) for the look and the flash.

To go back to the mapping that was on the norns before (only `rec` on CC 100):

    ssh we@norns.local 'cp ~/dust/data/four/four.pmap.before-octatrack ~/dust/data/four/four.pmap'

then reload four. The Octatrack copy of the file stays in `data/octatrack.pmap`.
