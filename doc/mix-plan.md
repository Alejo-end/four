# four: the next steps, and the mix of the tracks (plan of 2026-11-24)

STATE: steps 1 to 3 are built (the seventy-third and seventy-fourth changes). Step 4 is
open. Stage 22 of doc/device-gate.md is the test. It answers item 36 of doc/ux-feedback.md: "sounds great
just a bit hard to mix the different tracks". doc/plan.md stays the order of work for
everything else.

## The order

1. The user plays the branch `loop-seam` (the seventy-second change): WARP and PV round
   the loop, and a preset change over a busy set. On a yes, merge and push.
2. The mix, below. The user answers the question first.
3. The session with a first-time player (doc/walkthrough.md), with the new mix.
4. Proposal A, below.

## The mix: what is hard today

- A level is on TRACKS only, one at a time: E2 picks the track, E3 turns it. From VOICE or
  FILTER it takes a walk to TRACKS and back.
- TRACKS draws where a level knob stands and not how loud the track is. A quiet take at
  1.0 and a loud one at 1.0 look the same. Only the input and the whole output have a
  meter (MIX).
- The knob is linear from 0 to 1.5. Half of its travel is the top 6 dB, and the quiet
  end is coarse.
- There is no mute and no solo. K2 on TRACKS turns the voice OFF. ON makes a new voice
  that starts at the window's start, so a loop loses its place.
- In PARAMS track 1's level is named `grain level`, and the others `t2 level` and so on.
- MIX holds the engine against the tape, and no track. The name promises more.
- Eight MIDI faders can be the mixer (the sixtieth change). Nobody tried it on hardware.

## The question for the user

Which is it, most of all?
- A: "I cannot see or hear which track is too loud."   Steps 1 and 2.
- B: "I cannot get at the level fast enough."          Step 4.
- C: "I cannot hear one track alone, or drop one out." Step 3.

## The steps (one change each, the cheapest first)

1. LEVELS THAT READ RIGHT (Lua). E3 on TRACKS moves the level in steps of 0.5 dB, with
   0 at the bottom (finer below -30 dB is not needed). The readout is in dB. The bar is in
   dB too, with 0 dB marked. The param keeps its id and its range, so presets, scenes and
   MIDI maps hold. `grain level` is shown as `t1 level` (the name, never the id).
2. A METER FOR EACH TRACK (engine, RESTART, Lua). One amplitude for each track after its
   lane, read from `outBuses`, as four polls (the count stays 199). The level bar on
   TRACKS fills with the sound and the knob is a tick on it. Cost: one Amplitude UGen pair
   for each track that plays, in the lane. Measure it with the dense set (row 19.27).
   Brightness keeps its law: a track that is silent lies flat.
3. MUTE AND SOLO (Lua). On TRACKS, K2 is MUTE: a fade of 20 ms on the level that the engine
   gets (level times mute), and the head runs on. K2 held is SOLO while it is held. OFF stays on K3
   MODE. Four new params `mute_1` to `mute_4` (binary, so a MIDI key reaches them), out of
   scenes and motion, like STOP. A PSET stores them: a load must say so in the header cell,
   dim for a muted track. `lfo`, `motion` and a scene still move the level under a mute.
   Every reader of "does this track sound" (`track_sounds`, the header cells, `purity()`)
   must know the mute.
4. THE LEVEL FROM ANY PAGE (Lua, only on answer B). K1+E1 picks the track today. K1 held
   and E1 at its track draws a pop: the four level bars. Open: which encoder turns the
   level in it. E2 and E3 under K1 are taken on most pages, so this one needs a mock-up
   first. The other way to B costs nothing: the MIDI faders.

Not planned: an automatic balance (one key that matches the four loudnesses). It changes
the sound under the player's hands. It comes up again after the meters.

After each step: the uisim renders, `lua test/check.lua`, the manual and doc/controls.md.
Tests to add: the dB steps reach 0 and 1.5 and come back, a mute keeps the head and the
level param, a solo releases on the key's up wherever the page went (`key_state`), and a
scene recall leaves the mutes.

## Proposal A (branch `proposal-dsp-fixes`)

- Take its two commits (7578dda and 0ceeabb) as patches. NEVER merge the branch: its
  history is the old one, which left the public repository.
- Its engine part is three things: the record and the regen DC blockers go from 38 Hz to
  3.8 Hz (they took 2.8 dB at 40 Hz from each take), a DC blocker before the reverb, and a
  message when the plugin has no real-time memory. The sends keep 38 Hz.
- It no longer applies cleanly to lib/Engine_Four.sc (a 3-way check conflicts). Write the
  same lines by hand, on a branch, with the DSP check.
- It touches FourStretch.cpp: a new plugin build on the norns.
- Measure as doc/plan.md says: below 20 Hz on the send ring, regen at 0.8 for 2 minutes
  under a low resonant low-pass, the reverb's cost. Then by ear: more low end on each take.
