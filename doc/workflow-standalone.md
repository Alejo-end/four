# Workflow: standalone (3 keys + 3 encoders)

> **HISTORICAL** — this walkthrough predates the nine/ten-station redesign
> (pages like LEVEL and WINDOW no longer exist; TAKE/VOICE/MIX absorbed them).
> The current guide is the README ("First session, five minutes" + per-page
> sections). Kept for the ideas, not the key maps.

mangler is built to carry a full performance with **nothing plugged in but your
instrument**: a synth (or drum machine, or anything line-level) into the norns
inputs, outputs to the mixer. No grid, no MIDI controller, no laptop. This is
the walkthrough for that: **chop something, then grow it into a soundscape.**

The whole surface is three keys and three encoders:

| control | function |
|---------|----------|
| **E1** | page select (**hold K1**: leap between page families — source · shape · tape · fx) |
| **E2 / E3** | the page's two parameters (**hold K1**: the alt parameter of each) |
| **K1** (hold) | alt / shift |
| **K2 / K3** | the page's two actions — the footer pills always say what they do |

The footer always mirrors the hardware: two knobs for E2/E3 with their live
values inline, two pills for K2/K3. Turning an encoder fills its knob solid
and updates the value — there is no separate readout to hunt for. The page's
title (top-left) never disappears, and if the recorder or tape is armed a
blinking dot + flag sits beside it. Page dots run along the top-right, one
per page, the current one a brighter block.

---

## 0 · Gain-stage — LEVEL

Plug the synth into the norns line inputs and play.

- **LEVEL** page: E2 = IN, E3 = OUT. Two stereo meter bars (L over R) show
  what's coming in and going out — a peak-hold pip marks the loudest recent
  level and a clip lamp blinks past the top; set IN so peaks breathe below
  it. The little tab under each bar is the gain you're setting.
- **K2 `IN=0` / K3 `OUT=0`** reset either level to unity (0 dB) when you've
  trimmed yourself into a corner.
- Hold **K1** for the alt layer: E2 = MON (how much dry input you hear
  directly), E3 = HP (headphone gain). Monitor is your "dry synth" level for
  the whole set — many performers keep it up and treat mangler as a send.

## 1 · Chop something — REC

Go to **REC** (page 3).

- The page is the **buffer strip** with the grain cloud drifting over it,
  and the input meter on the right edge.
- Play a phrase and hit **K2 `REC`**. A `REC` flag blinks by the title, the
  write head walks the strip laying material (with a short afterglow trail),
  and the buffer fills in. Hit **K2** again to stop — **the window snaps to
  exactly what you just played**, so playback immediately loops your phrase,
  not a minute of silence.
- **K3 `FRZ`** freezes capture without disarming; E2 = record level,
  **K1**+E2 = overdub (its `OVR%` shows in the footer while it's non-zero —
  old material survives under new by that amount).
- **K1**+E3 = `resample`: blends the *output* back into what gets recorded
  (the page badges `RSMP` while it's up). Record the mangled sound itself,
  window it again, and it composts into new material — the fastest route to
  a soundscape that no longer resembles the synth.

## 2 · Shape the slice — WINDOW

Go to **WINDOW** (page 4). It's the **buffer strip** with bright handles
marking your slice — in-window material reads bright, everything outside
dims. The start/end values sit in the footer.

- E2/E3 drag the window start/end (the handles slide, the bright region
  reshapes). The encoder deltas scale with the window
  span — wide open they move fast, on a tight slice they nudge by ~10 ms.
  Everything downstream (grain cloud, stretch) reads only this slice.
- **K2 `RST`** opens the window to the whole buffer; **K3 `FLIP`** reverses
  the scan direction — the classic throw-it-backwards move.
- **K1**+E2 = scan rate (−2×…+2×; the playhead speed through the slice,
  independent of pitch). **K1**+E3 = jitter — watch the ghost dots fuzz the
  playhead in the detail lane; that blur is literally what the engine does
  to the read position. Jitter high + tight window = smeared, unpitched
  texture.

## 3 · Grow the cloud — GRAIN + STRETCH

**GRAIN** (page 5) is the texture kitchen. The cloud is a stereo-field plot:
dot height = pan, dot size = grain size, density = how many.

- E2 = grain size, E3 = density. Small + dense = smooth wash; large + sparse
  = audible echoes of the phrase.
- **K1**+E2 = stereo spread, **K1**+E3 = grain level.
- **K2 `OCT-`** / **K1+K2 `OCT+`** throw the pitch by octaves; **K3 `PT=1`**
  re-centers. Pitch is independent of speed in every mode.

**STRETCH** (page 6) picks the time engine:

- **K2 `MODE`** cycles OFF → GRAIN → WARP → PV. Each draws its own texture,
  and OFF genuinely frees the voice (the lane lies flat — if it doesn't
  move, it isn't sounding).
- E2 = scan (speed through the slice). **Set it near 0.05–0.2× for drones**:
  the phrase becomes terrain the cloud crawls over.
- PV mode + **K3 `PVFZ`** freezes the spectrum solid — infinite sustain of
  one instant. Park it, then play the *filter* instead.

## 4 · Layer it — TAPE + MIX

The tape is a second, parallel instrument (softcut — costs nothing), and it
records **what's at the outputs**, engine sound included.

- **TAPE** (page 7): **K2 `REC`** starts a take onto the tape; stop, and the
  loop snaps around what you played and starts looping it immediately.
- E2 = tape rate (varispeed, −2×…+2×; the reels spin at the real rate),
  **K1+K2 `REV`** holds reverse, E3 / **K1**+E3 slice the loop edges,
  **K1**+E2 = tape overdub for sound-on-sound layering.
- **K3 `FRZ`** freezes the loop; **K1+K3 `CLR`** wipes the tape for a fresh
  start.
- **MIX** (page 1): E2 crossfades engine ↔ tape. The page is **two lanes**
  with the crossfader between — the ENG scatter up top thickens as you fade
  toward the engine (and lies flat when the mode is OFF), the TAPE waveform
  below grows as you fade toward tape. **K2 `ENG` / K3 `TAPE`** throw the
  fade hard to either deck. E3 trims the engine; **K1**+E2 = master out,
  **K1**+E3 = tape trim.

**The soundscape loop:** capture a phrase → granulate it → print the result
to tape → throw MIX to TAPE → the engine is now free to capture and mangle
something new on top. Repeat. With `resample` up, even the engine buffer
composts itself.

## 5 · Space — FILTER, DELAY, REVERB

The FX chain sits on the engine's wet path.

- **FILTER** (page 8): the curve is the engine's actual response (with a
  shimmering spectrum floor under it); the bright node is the cutoff under
  E2, E3 = resonance. **K2 `TYPE`** cycles LP/HP/BP, **K3 `OPEN`**
  neutralizes it. **Hold K1** for the wet-path trims the filter can't
  reach: E2 = dry/wet (`D/W`), E3 = the granular level (`GRN`). Sweeping a
  resonant LP over a PV-frozen spectrum is a whole movement by itself.
- **DELAY** (page 9): E2 = mix, E3 = feedback, **K1**+E2 = time. **K2 `INF`**
  pins the feedback at the soft-clipped edge — the loop holds and saturates,
  dub style — and **K3 `KILL`** drops it to nothing.
- **REVERB** (page 10): E2 = size, E3 = mix — a room seen from above whose
  walls grow with size, rays bouncing to the listener, a ping pulsing out of
  the source. **K2 `WASH`** goes full wet, **K3 `KILL`** dries it up. **Hold
  K1** to reach the delay send: E2 = delay mix (`MIX`), E3 = dry/wet
  (`D/W`). Both FX pages go visually dormant at mix 0 — nothing on screen
  moves that you can't hear.

## 6 · Keep it

**PARAMS > PSET > SAVE** stores every parameter **and the tape audio** — a
saved soundscape comes back loopable after a restart. MIDI-map anything from
the PARAMS menu (long-press a param); mappings persist per-script.

---

### The whole arc, compressed

```
LEVEL   set IN/OUT, monitor the dry synth
REC     K2 — play a phrase — K2       (window snaps to the take)
WINDOW  tighten the slice, FLIP it, add jitter
GRAIN   small grains, high density, wide spread; OCT- for depth
STRETCH scan ~0.1x, or PV + PVFZ to freeze an instant
FILTER  resonant LP, sweep slow
DELAY   INF to hold a bed, KILL to clear
TAPE    K2 — print a pass — K2        (loop snaps, layer with overdub)
MIX     throw to TAPE, free the engine, capture the next phrase
```

A MIDI keyboard (or a USB typing keyboard, Ableton-style) plays the sample
chromatically at any point — see the README's *Playing notes* section. And if
a grid is around, the same instrument grows pads: `doc/workflow-grid.md`.
