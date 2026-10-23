# mangler: the decks as tracks, and the screen

This plan says how mangler can come closer to a four-track sculpting
sampler such as the Torso S-4, inside what a Pi 4 can do, and how to make
its screen better. It is built on research into the S-4, softcut and the
norns audio routing, and on an audit of every rendered page. Nothing here is
built yet. Phase 0 comes first. The screen bugs (UI-a) can go before the
device session, because they change only the Lua drawing.

## What the S-4 has

Sources: the Sound On Sound review, the OS 2.0 and 2.2 notes, and retailer
listings (links at the end). Some details changed between firmware
versions, so the manual is the authority.

- **Four stereo tracks.** Each one runs a fixed chain of five devices.
  Material is TAPE, POLY, DISC, or BYPASS for the live input. Granular is
  MOSAIC. Filter is RING, a 48-band resonator that morphs between low, band
  and high pass. Color is DEFORM: distortion, compression, crush and noise.
  Space is VAST: delay and reverb.
- **Sends between tracks.** Each track has four send levels into any other
  track, or back into itself. That is how it resamples.
- **Modulators per track:** LFO, random, ADSR and FOLLOW (the amplitude of
  a track or of the input). They can be synced or free.
- **Performance:** macros that move many parameters at once, a Perform page
  of eight knobs and four punch-in effect buttons, and scenes.
- **A master** with a mixer, a DJ-style filter, a compressor, and a record
  of the master mix.

## What mangler has, and what it cannot have

Mangler already has the take with four play modes and three loop decks
(TAPE, L1, L2). One filter, one delay and one reverb serve the take. Around
them sit scenes with a morph and an orbit, a motion looper, pads with a
sequencer, two LFOs, a beat repeat, erosion and regen.

Two limits are fixed by the platform:

- **One SuperCollider voice.** scsynth gets one core on a Pi 4, and the
  project measured audio dropouts past about 60%. Four granular or stretch
  chains side by side are not possible. The take keeps its mode switch.
- **The decks cannot reach the engine's effects.** The norns audio routing
  sends the input, the engine and the tape INTO softcut. softcut's output
  goes only to the output and to the system reverb (`audio.level_cut_rev`,
  one level for all of softcut). No function sends softcut into the engine.
  So the decks cannot use the engine's filter, delay or reverb.

What softcut already offers, and mangler does not use yet:

- **A filter on every voice**, after playback: `softcut.post_filter_fc`,
  `post_filter_rq`, and the mix of `post_filter_lp`, `_hp`, `_bp`, `_br`
  and `_dry`. A second set (`pre_filter_*`) shapes what a voice records.
  Mangler sets both to dry today. The filters run in softcut's own
  process, so using them costs no scsynth CPU.
- **Voice to voice routing**: `softcut.level_cut_cut(src, dst, level)`
  patches one voice's output into another voice's input. That is the S-4's
  track sends.
- **A crossfade on every jump**: `softcut.fade_time`, with
  `softcut.position` for the jump. Fast, faded jumps inside a loop give a
  rough granular texture.
- **`softcut.voice_sync`**, which puts one voice's head at another's.

All six softcut voices are in use: the tape and each layer are a stereo
pair. Every softcut feature below works on those pairs. None needs a new
voice.

## Phase 0: the device session

Do this first, as doc/plan.md says. About thirty changes and the beat repeat
are unheard. Every phase below builds on decks, LFOs and pages that have to
be proven first.

## Phase 1: a filter on each deck

The single largest step toward "tracks". It is Lua only, and the engine count stays 66.

- **Params per deck**: `tape_fc`, `tape_rq`, `tape_ftype`, and `lay1_*`,
  `lay2_*` the same. Not `cut_*`: the system owns `cut_input_*`, and the
  rule in CLAUDE.md is to stay clear of system ids. `ftype` is OFF, LP, HP,
  BP. OFF is the default and is a true bypass (`post_filter_dry` 1), so a
  deck sounds exactly as today until you touch it.
- **One writer**: `Mdeck.update_filter(d)` sets both voices of the pair,
  the same shape as `update_level`. The tape is a deck too (lib/mtape.lua
  delegates to Mdeck), so all three decks share it.
- **Classified**: the three controls join `SCENE_RECALL_IDS` (a scene keeps
  a deck's tone) and `MOTION_IDS`. `ftype` joins `MORPH_EXCLUDE`, like the
  engine's `filt_type`.
- **Purity**: a deck filter does not touch the take, but a deck that plays
  audibly already kills the mark, so nothing changes there.
- **Screen**: see the screen section. The filter needs a home on TAPE and
  LAYERS.
- **To check on the device**: the range and law of `post_filter_fc` and
  `rq` (the docs give no range), and whether a cutoff change zippers at
  encoder speed. `rate_slew_time` has no filter twin. If it zippers, the
  Lua side steps the cutoff over a few frames.

## Phase 2: the modulators reach the decks

The LFOs move only engine controls today, and never the knob itself. Phase
2 adds deck targets without breaking that rule.

- **A second kind of target**: a deck control. The LFO computes the swung
  value as now, and sends it with the deck's own writer instead of
  `engine[id]`. The writers (`update_level`, `update_rate`, the new
  `update_filter`) take an optional swing, so the knob still stays where
  the hand left it.
- **Targets**: each deck's level, pan or width, rate, and filter cutoff.
  The TARGETS list is append-only, so they go at its end.
- **A second follower**: FOLLOW on the S-4 can follow a track's output.
  Add the engine output level (`amp_out`, already polled) as a source
  beside the input. It gives "duck the decks when the take is loud".
- **Rate is a special case**: a swung rate changes the deck's pitch and its
  position in time. Allow it, but with a small depth range, and say so.

## Phase 3: sends between decks

The S-4 resamples by sending one track into another. softcut can do the
same with `level_cut_cut`.

- **Params**: three sends per deck, into each of the other two decks
  (`tape_to_l1`, ...), 0 to 1, default 0. A deck into itself is left out:
  the overdub (`pre`) already is its feedback, and a self-send on top of it
  runs away.
- **Safety**: a ring (tape into L1 into L2 into tape) is a feedback loop
  with no limiter in softcut. When a ring is open, cap the product of its
  sends below 1 and say so on screen.
- **What it gives**: record L1 from the tape's mangled loop while you play,
  without the engine. With the deck filters, a filtered copy of a loop.
- **Classified**: the sends are routing, so they join `SCENE_EXCLUDE` and
  `MOTION_EXCLUDE`, like `cut_source`.

## Phase 4: a texture mode for each deck

Not a real granular engine, but a cheap way to give a deck its own texture
without the one scsynth core.

- **How**: a Lua clock per deck, while its texture is on. On each tick it
  jumps both voices to a random point in the loop (`softcut.position`), with
  `fade_time` as the crossfade. It has three knobs. Density is the jumps per
  second, up to about 30. Size is the fade, which is the grain length.
  Spread is the farthest a jump can land from the head.
- **The seam knob**: `fade_time` is also each deck's loop seam. While the
  texture runs, it owns `fade_time`. When it stops, the seam comes back.
- **Costs**: a clock coroutine per deck (CLAUDE.md asks for few clocks, and
  one cancel per clock in cleanup). Keep one shared clock for all three
  decks.
- **Risk**: how softcut sounds at 20 to 30 jumps a second is unknown. Build
  it as one deck first and listen, then decide.

## Phase 5: macros and a perform layer

The scene morph is already one knob over the whole sound. The S-4's macros
and Perform page are smaller and freer: a knob moves the few things you
chose, by the ranges you chose.

- **Macros**: four, each with up to four targets and a range per target.
  A macro is a param (`macro1` .. `macro4`), so MIDI maps it like any knob.
  Writing the targets goes through the same rule as the morph: it writes
  params, and the motion looper and scenes see the macro, not its targets.
- **Punch-ins**: mangler's throws (DRY, OPEN, INF, WASH, the beat repeat,
  chaos) are its punch-in effects. Gather them on one grid row, and give
  the beat repeat a key home (see the screen section).
- **Assigning**: the hardest part on three keys. A "learn" gesture (hold a
  macro, turn a knob, its range is the travel) avoids a menu of targets.

## Phase 6: the engine items still waiting

One at a time, after Phase 0, each with its own RESTART: reversed grains,
linked stereo limiting, the plugin test (doc/plan.md, Phase 5). A deck
DEFORM (distortion per deck) is not possible: softcut has no saturation, and
the decks cannot reach the engine.

## The screen

An agent rendered all 70 shots in the four variants and looked at each one.
I checked the two bugs below against the renders myself. The rest is its
recommendation, ordered by value. None of it reverts the decisions that
CLAUDE.md protects (the DELAY bars, the REVERB room, the MIX meters, the
TAPE reels stay as they are).

### Bugs to fix first (small)

- **The GRAIN texture ignores the grain knobs.** VOICE in GRAIN draws
  every third column of the wave as dots, whatever `size`, `density`,
  `spread`, `grain_jitter` or `pan` say. The ten grain shots differ only in
  the play head. The screen rule says VOICE draws the active mode's own
  texture, so this page lies. Size can set the tick length, density the
  count, spread the vertical scatter, jitter the drift and pan the bias.
  The grain-page-designer agent is made for this. (medium)
- **The erase arc overlaps the E2 word.** On TAKE the arc is drawn at
  `x + w + 8` with radius 3, but `keys_right` reserves only `x + w + 4`,
  so the ring sits on "MOVE" (base_01_TAKE_ERASE_ARC). Reserve its width.
- **Two tight footers.** REVERB's "BLOOM REVERB·" has a 4 px gap where
  every other page has 9. On VOICE in PV, the inverted PV box touches
  "HELD". The fix for REVERB can be the word "WET·" for both FX mixes,
  which also answers ux-feedback #24 ("what does echo 100% mean").

### The header must show every writer (small to medium)

- **No flag for a layer that records.** The header has R, T and M, but a
  layer deck recording shows nothing on any other page. Add L.
- **The new flags can drop off.** RP, SQ and LF are drawn only where they
  fit. With R, T and FZ lit, a long title pushes RP off on six pages. Draw
  in priority order (write flags, then holds, then machines), and shrink SQ
  and LF to a 2 px pip when space is short, so nothing disappears.

### A home for the features that live only in PARAMS (medium)

- **MOTION hosts the modulators.** It has a free K1+E3 slot and an empty
  lower half. LFO 1 and LFO 2 become rows that `motion_lane` can select,
  drawn as their waves: E3 sets the depth, K1+E2 the period, K1+E3 the
  target. A row that also goes out gets a tag such as "›CC20" or "›CV".
- **PADS shows the sequencer always.** The "E2 SLICE - E3 PITCH" row only
  repeats the footer. Put the step row there at all times, dim when it is
  stopped. On the grid, PADS row 6 has free pads for run and steps.
- **TAKE gets undo and start on sound.** A hold of K3 is UNDO, with the
  same arc as the erase, and a tap stays SNAP. The scene's "◄" glyph shows
  when an undo is kept. With `rec_wait` on, a dim "ON SND" tag sits beside
  the lock's "1 BAR", so you know before you arm that K2 will wait. The
  START and END swell reads seconds, not a percentage.
- **The beat repeat on the grid.** The main workspace's row 6 is dark: x1
  to x5 hold a repeat at 1/2 to 1/32, so a finger sliding across them is a
  roll. No key is free for it, so it stays off the keys. The header shows
  the division ("RP8").

### Consistency (small)

- VOICE with an empty buffer has no "EMPTY - K2 REC" invitation, and the
  MOTION invitation is dimmer than TAKE's.
- "HELD" is bright in PLAY, where a PV freeze cannot be heard. Dim it.
- Text that carries information gets a floor of level 5 (the PADS status
  row, SCENE's "NOW", the TAPE seconds).
- **One blink.** There are three blink phases (the header, the LAYERS dot,
  the MOTION chip). You disliked blinking (ux-feedback #29). Keep the
  header's write flags as the only blink and make the page chips steady.
- **The page dots in families.** A 2 px gap between the families (the take,
  the decks, the FX, MIX, the performance pages) brings back ux-feedback #9
  within the same 45 px.

### The screen for the deck phases

- **No new pages.** Eleven is already a lot for E1.
- **LAYERS becomes a three-row track view**: TAPE, L1 and L2, about 11 px
  a row, the selected row drawn larger. Each row carries small FILT, MOD
  and TEX chips that go dim at zero. `layer_sel` grows to include the
  tape, so one selector focuses any deck. The TAPE page with its reels
  stays.
- **FILTER gets a K1 toggle** between the engine filter and the focused
  deck's filter. That is the home for Phase 1's knobs, and the filter
  picture already exists.
- Every deck param still needs its classification, a SHORT word and the
  group counts, as CLAUDE.md requires.

## Order and cost

| Phase | What | Engine | Cost |
|---|---|---|---|
| 0 | The device session | none | a session |
| UI-a | The screen bugs and the header flags | no | small |
| UI-b | Homes for the PARAMS-only features, consistency | no | medium |
| 1 | A filter on each deck | no | small to medium |
| 2 | Modulators on the decks | no | medium |
| 3 | Sends between decks | no | medium |
| 4 | A texture mode per deck | no | medium, risky |
| 5 | Macros and punch-ins | no | large |
| 6 | Reversed grains, limiter, plugin test | yes, one at a time | small to medium each |

## Sources

- [Sound On Sound review of the S-4](https://www.soundonsound.com/reviews/torso-electronics-s-4)
- [S-4 OS 2.0 notes (Synth Anatomy)](https://synthanatomy.com/2024/05/torso-electronics-s-4-a-modern-tape-machine-with-advanced-sound-sculpting-features.html)
- [S-4 OS 2.2 notes (Synth Anatomy)](https://synthanatomy.com/2026/05/torso-electronics-s-4-a-modern-tape-machine-with-advanced-sound-sculpting-features.html)
- [S-4 listing (Rubadub)](https://rubadub.co.uk/products/torso-electronics-s4-sculpting-sampler-white)
- [softcut reference (monome)](https://monome.org/docs/norns/softcut/)
- [norns audio reference (monome)](https://monome.org/docs/norns/reference/audio)
