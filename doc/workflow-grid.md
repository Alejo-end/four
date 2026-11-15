# Workflow: with a grid (optional 8×8 surface)

> **HISTORICAL.** This page is older than the grid spine redesign (NU-4) and the S23
> PADS layout. The current grid reference is the README's Grid section and the comments
> in `lib/mgrid.lua`. Kept for the ideas, not the pad maps.

A grid is **never required** — everything below has a keys+encoders route
(see `doc/workflow-standalone.md`). But if one is attached, mangler grows a
pad surface for the parts of the instrument that want *instant* hands:
transport, slicing, and notes. The screen and encoders stay the deep-edit
layer; the grid is the play layer.

Works with a **monome grid** out of the box, or a **launchpad-family / APC
mini** controller through the community
[midigrid](https://github.com/miker2049/midigrid) library (install it on the
norns, plug in, load mangler — it's adopted automatically when no real monome
grid is present). Every pad drives the same params as the keys, encoders, and
MIDI maps — nothing on the grid is a second truth.

## The layout

```
row 1   ENGINE   [rec] [freeze]  ·  [OFF][GRAIN][WARP][PV]  [pv freeze]
row 2   TAPE     [rec] [freeze] [reverse — hold]  ·  ·  ·  ·  ·
row 3   WINDOW   8 slice pads over the buffer (write head glows while recording)
row 4   LOOP     8 slice pads over the tape loop
rows 5–8 NOTES   two piano octaves — black row above its white row;
                 upper pair is +1 octave. gap pads:
                 row 7 corners = octave − / +  ·  row 5 corners = pitch reset / quantize
```

Lit = engaged. The mode pads (row 1) are a radio group; the current pitch
lights its note pad; the play head / tape head / write head glow on the slice
rows. LEDs stay live even while the norns menu is open.

## 1 · Capture without looking

Row 1 pad 1 arms the **engine recorder**, row 2 pad 1 the **tape** — the same
one-button take workflow as K2: arm, play, tap again, and the window/loop
snaps around what you played. While recording, the **write head glows across
row 3**, so you can watch the take land without touching the screen.

Freeze pads (row 1/2, pad 2) hold either buffer; row 2 pad 3 is **hold-to-
reverse** for the tape — tap-hold it in rhythm for stutter-reverse figures.

## 2 · Slice with two fingers

Rows 3 and 4 are the buffer and the tape loop cut into eighths:

- **Tap a pad** → the window (or loop) becomes that eighth.
- **Hold one pad, tap another** → the region spans between them.
- Tap-and-release gestures land on the same `pos_start/pos_end` /
  `loop_start/loop_end` params the encoders edit, so you can rough-cut on
  the grid and fine-nudge (~10 ms) with E2/E3 on WINDOW or TAPE after.

This is the fastest way to play the *chop*: hold a bass eighth, stab
different second pads, and the window jumps like a beat repeater.

## 3 · Play the sample as an instrument

Rows 5–8 are two piano octaves in the same shape as musical typing (black
keys above white). Pads set `pitch` chromatically relative to the root note
(PARAMS > keys), independent of playback speed, in every stretch mode:

- bottom pair (rows 7/8) = base octave, top pair (rows 5/6) = +1 octave
- row 7 corner pads = octave − / +
- row 5 corner pads = pitch reset (1.0×) / **pitch quantize** toggle —
  quantize also snaps the GRAIN encoder and any mapped CC to semitones

Last-note priority, no envelope: it plays like re-tuning a running texture,
which over a granular cloud *is* melody.

## 4 · A grid set, end to end

```
row 2 rec ── play a phrase into the tape ── row 2 rec   (loop snaps)
row 4     ── hold+tap: half-bar loop, let it roll
row 1 rec ── capture a second phrase into the engine ── row 1 rec
row 3     ── two-finger a tight slice of it
rows 5–8  ── play the slice chromatically over the tape bed
row 1     ── PV mode, pv-freeze pad: hold a chord of one instant
encoders  ── FILTER sweep / DELAY INF / MIX throws (screen side)
row 2 pad 3 ─ rhythmic reverse stabs on the tape as it all decays
```

## Housekeeping

- **Pads and note input don't fight:** the grid controller's own MIDI device
  is filtered out of chromatic note input, so a launchpad's pads are pads —
  never wild note-ons. (If a pad press ever slams the pitch readout to
  0.25×/4×, that filter broke; see CLAUDE.md.)
- The grid never blocks the standalone flow: unplug it mid-set and every
  gesture still exists on keys + encoders.
- On-device checklist for this layer lives in CLAUDE.md (grid section).
