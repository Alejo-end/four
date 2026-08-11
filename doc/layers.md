# S25 — LAYERS: multitrack, on the core that has room for it

## The decision

mangler gets **two more independent loop decks**, on softcut, alongside the one
it already has. What it does *not* get is more simultaneous scsynth drones.

That split is not a compromise, it is this project's own stated rationale
(CLAUDE.md): *"softcut (separate audio core, near-free) does everything it can;
scsynth does only what softcut cannot."* One drone at a time was a deliberate
CPU decision — one scsynth core on a Pi 4, xruns past ~60%. Four simultaneous
granular drones would break that; four softcut loops cost almost nothing.

So the shape is **one deep track plus three shallow ones**:

```
  engine take (scsynth)   granular · warp · spectral · window · pads · erosion
  TAPE  deck  (sc 1,2)    loop · varispeed · reverse · overdub   <- already exists
  LAYER 1     (sc 3,4)    "
  LAYER 2     (sc 5,6)    "
```

**What this buys:** you can build a piece instead of playing a moment. Each deck
has its own loop points and rate, so a 4-bar part against a 3-bar part drifts and
re-syncs on its own. You keep playing while you record the next part. And the
granular voice stops being a bottleneck — the clean loop can sound *while* the
engine chews something else.

**What it does not buy, stated plainly:** softcut decks cannot be granulated,
warped or spectrally stretched. They are loops, not mangle targets. Only the
engine take gets the deep treatment.

## Why the tape deck is not refactored (yet)

`lib/mtape.lua` already *is* a deck, and the honest move is one deck abstraction
used three times. It is not done in this stage, on purpose: the tape deck is one
of the few things on this branch that is **known working on hardware**, and
nothing since 2026-07-16 has been device-confirmed. Rewriting a proven path
before the gate is the wrong order.

`lib/mdeck.lua` is therefore written as the generic deck and instantiated for the
two NEW decks only. **Folding the tape deck into it is a named follow-up, gated
on the device pass.** The duplication is real and is stated rather than hidden.

## Softcut layout

| deck | voices | buffer region | notes |
|---|---|---|---|
| TAPE | 1, 2 | 0 – 60 s | unchanged |
| (reserved) | — | 60 – 120 s | the chain forge's audition on `foundry` sits at 70 s |
| LAYER 1 | 3, 4 | 120 – 180 s | |
| LAYER 2 | 5, 6 | 180 – 240 s | |

softcut's buffer is ~349 s × 2 channels, so this fits with room left. The gap at
60–120 is deliberate: `foundry` auditions chain cells there, and picking regions
that avoid it means the branches can merge without a silent buffer collision.

Each deck is **stereo**: the lower voice takes input channel 1 and pans left, the
upper takes channel 2 and pans right — the same pairing `init_tape` uses.

## Three collisions with the existing deck, and their fixes

These are the parts that cannot be added purely additively.

1. **`sc.buffer_clear()` wipes the WHOLE buffer.** `Mtape.clear_buffer` used it,
   so the TAPE erase would silently wipe both layers. It becomes region-scoped
   (`buffer_clear_region(0, TAPE_LEN)`), and each deck clears only its own.

2. **One `sc.event_phase` handler.** mtape owned it and filtered on `v == 1`.
   It now forwards anything else to `ctx.deck_phase`, so each deck can drive its
   own playhead and waveform. One line in mtape.

3. **The record SOURCE is global, not per-voice.** `audio.level_adc_cut` /
   `level_eng_cut` feed softcut's two input channels for every voice at once, so
   all decks record the same thing. `cut_source` stays a single shared control —
   which is fine, because you record one thing at a time. Stated so nobody later
   expects per-deck dry/wet.

## Params

Per deck, prefixed `lay1_` / `lay2_` (ids are never renamed once shipped):

| id | kind | default | why |
|---|---|---|---|
| `rec` | binary | 0 | arm capture |
| `play` | binary | 1 | transport |
| `level` | control 0–1 | 0.8 | |
| `rate` | control 0.25–4 exp | 1 | varispeed |
| `reverse` | binary | 0 | latching, like the tape's |
| `start` / `end` | control 0–1 | 0 / 1 | loop bounds within the deck's region |
| `pre` | control 0–1 | **1** | overdub survival |

Plus one `layer_sel` selector. Seventeen new params (78 → 95).

**`pre` defaults to 1 (OVERDUB), unlike the tape deck's 0 (REPLACE).** These are
*layers* — stacking is the job, and it is the loop-pedal gesture people already
have in their hands. The page names the mode, so it is never hidden, and K1+K3
erases the selected layer when you want to start over.

**Scenes and motion:** `level`, `rate`, `reverse`, `start`, `end`, `pre` are
performance state and join the curated lists (TIMBRE / SWITCH for `reverse`).
`rec` and `play` are transports and stay out, exactly like `tape_rec`.

**PSET:** each deck writes its own region as a wav beside the pset, gated on
"has audio" and deleting a stale file when empty — the rule the take and the tape
already follow, so a cleared layer cannot resurrect.

## The page

**LAYERS, page 13.** Two strips stacked, one per deck: the recorded waveform
across the deck's region, the loop bracket over it, a playhead, a REC lamp and a
level bar. The selected deck is drawn bright, the other dim — the audibility rule
this project holds everywhere.

- **E2** select layer · **E3** its level
- **K1+E2** rate · **K1+E3** move the loop (start and end together, the existing
  `move_pair` compound, which already writes the widening edge first)
- **K2** REC under the punch law — hold to record while held, tap to latch
- **K3** PLAY — transport toggle
- **K1+K3** held = erase the selected layer (its region and its picture)

Thirteen pages drops the header dot pitch from 4 to 3, which the header already
handles (`min(5, floor(45/(#PAGES-1)))`) and has done before.

## What is deliberately NOT in this stage

- **Per-deck record source.** Global, by softcut's own routing. See above.
- **Granulating a layer.** The engine reads its own buffer, not softcut's.
- **Tape-deck refactor into `mdeck`.** Gated on the device pass.
- **Sync / quantized loop lengths.** Each deck free-runs. Clock-locked loop
  capture is a real follow-up, but it is a separate design (what does "one bar"
  mean when the deck is already mid-loop?) and belongs after this is played.

## Gate

Add to `doc/device-gate.md` after the existing stages:

1. Record the engine take. Record LAYER 1 against it. Both sound, independently.
2. LAYER 1 at rate 0.5 and LAYER 2 at 1 — they drift and re-sync; no clicks.
3. REC on LAYER 1 with `pre` 1 stacks; with `pre` 0 replaces.
4. K1+K3 on LAYERS erases **only** the selected layer — the tape and the other
   layer are untouched. *(This is the `buffer_clear` collision. Check it.)*
5. K1+K2 STOP silences all four decks; START restores the exact mix.
6. PSET save/load round-trips both layers' audio.
7. %CPU with all four decks running and a granular drone — the number that
   decides whether a third layer is ever worth adding.
