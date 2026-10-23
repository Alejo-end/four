# mangler: the plan after the full review

This plan says what to do next, in what order, and why. It comes from a
line-by-line review of the whole codebase (October 2026). The review found 76
issues. Every Lua bug is fixed and tested (the 78th change in
doc/changelog.md), and so are most of the cleanup findings. Three cleanups are
still open and listed in Phase 4. The engine issues are listed in Phase 2,
because engine code cannot be tested in this environment and must go through
the device gate.

## Where the project stands

The last state proven on hardware is from 2026-07-16, at `count: 63`. Since
then about thirty changes landed without a device test, several of them in the
engine. After a RESTART the engine must report `count: 66`.

The offscreen tests are strong. Five test scripts run 770 assertions, the
render suite compares 70 screens pixel by pixel, and the single-file build is
tested for freshness. No test script can judge sound and feel. That is why the
first step is a device session and not more code.

## Phase 1: the device session (do this first)

Nothing else in this plan is safe until this passes.

1. Deploy with `rsync --delete`, then run SYSTEM > RESTART.
2. Make sure that maiden reads `count: 66`. If it does not, stop.
3. Walk doc/device-gate.md from stage 0 to stage 17, top to bottom. If a stage
   fails, stop there and note what you heard.
4. When it passes, update the STATUS block in CLAUDE.md with the date and the
   count.

Stages 12 to 14 are new. They cover the review's fixes, the additions and
the erosion synth, where only hardware can judge. For example, a late sample
conversion must no longer replace a live take.

## Phase 2: the engine batch

Do these one at a time, after Phase 1, each with its own RESTART and listening
test.
None of them adds a command, so the count stays 66. They are ordered by risk to
the sound.

1. **STOP clicks and leaks DC.** The STOP gate in `winRead` freezes the read
   head instantly. PLAY, PV and Clouds then output one held sample: a click on
   stop, and a constant fed into the delay and reverb for the whole stop. Fix:
   lag the gate (`Lag.kr(run > 0.001, 0.05)`), use it in the head increment,
   and multiply each drone's output by it.
2. **Resample and regen print after the fader.** The record path taps the mix
   after the deck `level`, so the master volume and the MIX crossfader decide
   how loud material is printed. With regen up and the master down, the take
   decays 6 dB faster per pass. Fix: take `preLim` before the level multiply.
   Keep the `(level > 0.001)` gate so STOP still pauses regen.
3. **The open filter is never a bypass.** At LP, 20 kHz and no resonance the
   take still runs through the DFM1 diode ladder, so the purity mark (◇) and
   "PLAY plays the exact sample" are not literally true. Fix: crossfade to the
   unfiltered signal at the open end stop, and make `purity()` test the same
   end stop.
4. **Every echo is one block late.** `LocalIn` and `InFeedback` each add one
   control block (1.33 ms), so a tempo-synced hold drifts off the clock (21 ms
   after one bar of sixteenths). Fix: subtract `ControlDur.ir` from the delay
   time.
5. **A reused voice id orphans a synth.** `noteOn` does not release an id that
   is already sounding. The Lua side guards it today. Fix: call
   `this.noteOff(id)` first in `noteOn`.
6. **Shimmer costs CPU at zero.** With the reverb up, two PitchShifts run even
   at `shimmer` 0 (the default). Fix: move the shimmer loop into its own
   spawn/free synth, the same pattern as the reverb and delay.
7. **Duplicated graph code.** The grain cloud is written twice (drone and voice)
   and fixes have had to be ported between the copies twice. Fix: build-time
   functions `grainCloud`, `stereoRead` and `loadPair`, like `winRead`.
8. **Stale engine comments.** Five comments describe older behavior (a 1.5x
   makeup that is now `2.sqrt`, a 44.1k file that "plays 9% fast"). Fix them
   with the next engine change.

## Phase 3: finish the tape fold

After Phase 1 proves the tape on hardware, move the tape's loop-pedal law onto
`Mdeck.arm_loop` and `Mdeck.close_loop`. The review found that the tape's own
copy had missed two fixes the layers already had. Both are fixed now, but three
differences remain (the minimum pass length, reverse direction, and SNAP). One
law removes about 30 lines and the whole class of drift. lib/mtape.lua lists the
differences.

## Phase 4: structure

These change no behavior. Each one is proven the same way as this review:
paramset dump, test scripts, and byte-identical renders.

1. **Extract the take helpers into lib/mtake.lua.** mangler.lua is 2580 lines
   with three jobs: the control surface, the parameter registration, and about
   650 lines of take and file work (load, clear, export, print, chop, tighten,
   the PSET take). The take work already has one rule (`buffer_replaced`) and
   one loader (`load_at_rate`), so it can move as a unit.
2. **One pair loop in mscenes.** `apply`, the morph sweep and the morph's way
   home each write region pairs with their own loop, instead of going through
   `Mdeck.set_pair` like every other writer. mscenes needs its writer to count
   the params that moved, so the shared writer needs a writer argument first.
   This removes about 30 lines.
3. **Cache the MOTION lane geometry.** The page now draws one column at a time
   when a lane is dense. A per-lane cache, rebuilt on each lane change, makes a
   playing loop cost the same as an empty one.
4. **Skip unchanged grid frames.** A native monome gets every LED 15 times a
   second whether or not anything changed. A per-frame signature can skip the
   redraw.
5. **Merge font pixels into runs.** `ptext` issues one rectangle per lit pixel.
   Precomputed runs cut the font's rectangles by about a third, with identical
   pixels.
6. **Two small leftovers from the review.** The VOICE encoder table repeats the
   scan/pitch pair for three modes and carries two slots nothing reads. The
   decks re-send an unchanged seam time on every loop edge write. Remembering
   the last value sent skips it.

## Phase 5: features worth adding

Most of this phase is built (the 79th change in doc/changelog.md). These need
no engine change and are tested offscreen:

- The frame loop survives a Lua error, and reports it every 5 seconds at most.
- The motion loop saves with the PSET and comes back playing.
- The orbit stands still while anything else moves the morph, and resumes two
  seconds later.
- A synced delay stays on the clock, whatever else writes its time.
- 8-bit WAV files decode, and a frame wider than its stated depth reads the
  container.
- Every page stays within 2500 screen calls a frame (a test).
- A first motion pass close to a musical length loops on it.
- In pad mode the grid piano lights the keys whose pad sounds.
- A Mini MK3 plugged in after load takes over, and its arrows step the page
  and the scene slot.
- Background jobs queue instead of refusing.
- GLIDE recall: the morph sweeps to a scene over N beats, then it lands.
- Deck and tape PSET saves stop at the end of their material.
- After regen or erosion stops, the take strip repaints.
- doc/controls.md is generated from the code.
- `tools/check.lua` runs every offline check. With a Lua 5.3 build set up, it
  runs them on the norns version.

Erosion as a spawn/free synth is also built (the 80th change). It went ahead
of the device session by request, so stage 14 of doc/device-gate.md must pass
before more engine work lands. A code review of the branch then found ten
bugs in this work. The 81st change fixes them, and stage 15 of
doc/device-gate.md checks them on the device. The other engine items wait for
Phase 1:

The 83rd to 93rd changes added six Lua features, each reviewed by an agent
and fixed before the next: start on sound, the pad sequencer, two
modulators, the window on the clock, the take undo and the modulation out.
Stage 16 of doc/device-gate.md checks them on the device.

The engine items below wait for Phase 1, one at a time, each with its own
RESTART and listening test. A new command moves the count from 65, so the
command count in CLAUDE.md, tools/test_control.lua and the deploy ritual move
with it.

| Feature | Why | Design | Cost |
|---|---|---|---|
| Server-side plugin test | `.asClass` proves the class, not the plugin binary. A partial install is silent | At alloc, play each plugin UGen into a 1-sample buffer and check a /done reply; fall back as for a missing class | medium |
| Linked stereo limiting | Two independent limiters shift the stereo image while limiting | One gain from `max(abs(L), abs(R))` applied to both sides, in place of the two `Limiter.ar` | medium |
| Beat repeat | BUILT in the 94th change, by request ahead of the device session: `\mangler_repeat` and the `beat_repeat` command (count 66). Stage 17 of doc/device-gate.md | | |
| Reversed grains | GRAIN plays every grain forward | A per-grain rate sign drawn with a probability (`grain_rev`), on both grain copies (Phase 2 item 7 first, so it is written once). One new command, count 66 or 67 | small, after item 7 |

## Phase 6: decisions for you

These are not code questions. Each one needs a yes or no.

1. **Delete `CLAUDE_PLAN.md`?** It is the original S0 plan and nothing
   references it. Keeping it in git history loses nothing.
2. **Delete `presets/layers/`?** It holds ten byte-identical copies of the
   presets for the old `layers` branch build. If no device runs `layers.lua`
   any more, it doubles every preset change.
3. **Rename one of the two SNAPs?** TAKE K3 SNAP fits the window to the take.
   The layer SNAP quantizes a loop length. One word, two gestures.

## How to work on this project

Every change follows the same loop. CLAUDE.md has the details and the rules.

1. Make the change in the smallest step that can be tested.
2. Add a test for any bug you fix. Then revert the fix and make sure that the
   test fails.
3. Render the four variants before and after, and compare the PGM files byte
   for byte. Only the screens you meant to change can differ. Compare renders
   made by the same Lua version.
4. Rebuild the single file with `lua tools/amalgamate.lua`. If a page's knobs
   or keys changed, also rebuild the control map with `lua tools/controls.lua`.
5. Run `lua tools/check.lua` with `LUA53` set to a Lua 5.3 build. It runs the
   syntax check, the five test scripts and the source-against-build renders on
   the version norns runs.
6. Add an entry to doc/changelog.md, and a row to doc/device-gate.md for
   anything only hardware can judge.
7. Engine changes go one at a time and only after the current device gate
   passes. Never send untested SuperCollider in bulk.
