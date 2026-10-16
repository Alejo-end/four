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
engine. After a RESTART the engine must report `count: 65`.

The offscreen tests are strong. Five test scripts run 571 assertions, the
render suite compares 67 screens pixel by pixel, and the single-file build is
tested for freshness. No test script can judge sound and feel. That is why the
first step is a device session and not more code.

## Phase 1: the device session (do this first)

Nothing else in this plan is safe until this passes.

1. Deploy with `rsync --delete`, then run SYSTEM > RESTART.
2. Make sure that maiden reads `count: 65`. If it does not, stop.
3. Walk doc/device-gate.md from stage 0 to stage 12, top to bottom. If a stage
   fails, stop there and note what you heard.
4. When it passes, update the STATUS block in CLAUDE.md with the date and the
   count.

Stage 12 is new. It covers the fixes in this review that only hardware can
judge. For example, a late sample conversion must no longer replace a live take.

## Phase 2: the engine batch

Do these one at a time, after Phase 1, each with its own RESTART and listening
test.
None of them adds a command, so the count stays 65. They are ordered by risk to
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

Ranked by value for cost. Small means an afternoon with tests.

| Feature | Why | Cost |
|---|---|---|
| Guard the redraw clock with `pcall` | One Lua error today freezes the screen, the morph, motion and the grid, and every key press then reads as a tap | small |
| Persist the motion loop in the PSET | Scenes, the take, the tape and the layers all survive a reload. A recorded gesture does not | small |
| The orbit yields to a hand on the morph knob | The orbit rewrites the morph amount every frame, so a hand or a MIDI fader on it is overridden | small |
| `delay_sync` owns `delay_time` | While synced, a scene, a morph or a lane can move the delay off the grid until the tempo next changes | small |
| Decode 8-bit PCM, honour `blockAlign` | 8-bit files play but get no waveform and no rate conversion | small |
| A screen-call budget per page in the test scripts | Nothing measured draw calls, which is how MOTION reached 7844 calls a frame | small |
| Snap the motion loop length to the clock | The layers snap. Gesture loops still drift against a synced delay | small |
| Light the grid piano by pad in pad mode | In pad mode the grid shows the drone pitch, which pads never change | small |
| Launchpad hot-plug | Unplugging the Mini MK3 leaves a dead grid until a reload | small |
| A job queue instead of refusing a second job | A PSET with an off-rate take and an off-rate layer converts one of them and loads the other sharp | medium |
| GLIDE recall mode | Ramp the morph to the slot over N beats, then land: an Octatrack-style crossfade | medium |
| Bound deck and tape PSET writes | Every save writes 60s per deck even for a 2s loop | medium |
| Refresh the take strip after regen or erosion | The strip shows audio the buffer no longer holds | medium |
| Erosion as a spawn/free synth | The PLAY drone is a buffer writer even at `erode` 0 | medium (engine) |
| Server-side plugin test | `.asClass` proves the class, not the plugin binary. A partial install is silent | medium (engine) |
| Linked stereo limiting | Two independent limiters shift the stereo image while limiting | medium (engine) |
| Generate the control map from the source | The spec's control table went stale through two redesigns | small |
| A one-command test runner and a Lua 5.3 build | Every change repeats the same tests by hand, and the local luac is 5.5 | small |

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
2. Run `luac -p` on every changed file. The local luac is 5.5 and norns runs
   5.3, so do not use 5.4 syntax.
3. Run the five test scripts. Add a test for any bug you fix. Then revert the
   fix and make sure that the test fails.
4. Render the four variants before and after, and compare the PGM files byte
   for byte. Only the screens you meant to change can differ.
5. Rebuild the single file with `lua tools/amalgamate.lua`. The control test
   script fails on a stale build.
6. Add an entry to doc/changelog.md, and a row to doc/device-gate.md for
   anything only hardware can judge.
7. Engine changes go one at a time and only after the current device gate
   passes. Never send untested SuperCollider in bulk.
