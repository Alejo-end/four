# Record four parts, bend them while they play, keep the sound, and fade back to it

> Status: a plan, written 2026-11-17 and checked against the code the same day. The
> STATUS block of CLAUDE.md and doc/changelog.md (from the forty-second change on) say
> which of its changes are built. doc/plan.md stays the order of work for everything else.
> It uses doc/idea-relay.md (Relay) in an adapted form, in Phase D. File references: E is
> lib/Engine_Four.sc, F is four.lua. The line numbers are those of commit 3565d9f (the
> fortieth change). Later changes move them.

## 1. The workflow

The player records four live parts, one per track. While they loop, the player bends them:
a voice, a filter, an effect, a send. The player keeps the sound they found in one press.
Then they fade away from it and back to it, many times, and nothing they made is lost on
the way. Three keys and three encoders, no grid.

The reason for this plan: the loop must feel easy and safe on stage. Every part of it
exists today. This plan does not add a page. It removes the places where the loop
clicks, forgets the player's work, or hides the next move.

Two anchors make the loop teachable. E1 stops at both ends (F:3311), and the two ends are
the two ends of the workflow: spin E1 left for TAKE, spin it right for SCENE.

## 2. The walk on today's code

A fresh script, no preset, a source on the input. Tracks 2 to 4 start OFF, every send
starts at 0, and the delay and reverb WET start at 0. "Moves" counts key presses and
encoder gestures.

| Step | Page | Moves | What the screen shows | Where it goes wrong |
|---|---|---|---|---|
| 1. Part 1 | TAKE | K2, play, K2 (2) | `EMPTY - K2 REC`, then REC, TRACK 1, the input bar, the seconds. Cell 1 blinks. On stop the strip loops in PLAY | A first press held past 0.33 s is a punch: the pass stops at the release (F:438, 3439). The loop length is free (`win_beats` FREE, F:2572) |
| 2. Parts 2 to 4 | TAKE | K1+E1, release K1, K2, play, K2 (5 each, 15) | The page pops `2 TAKE`. TAKE 2 is empty. REC turns the OFF track to PLAY (F:2455) | All tracks share one write head. After about 60 s of takes in all, a take crosses the end and loops the whole 60 s, silence included (F:2486). K2 pressed before K1 is up is STOP (F:950) |
| 3. A voice | VOICE | E1, K3 per mode (2 to 5) | The voice's own picture. The footer names the face knobs | Each K3 tap swaps the voice synth, and WARP and PV open a hole. CLOUD is four taps from PLAY, through WARP and PV. A K3 press between 0.33 s and 1 s does nothing |
| 4. A filter | FILTER | E1 x3, E2, E3 (3) | The response curve | Clean: TYPE is a 20 ms crossfade (row 19.8) |
| 5. An effect | EFFECT | E1, K2, K3, E2 (4) | The effect's picture | Four of six TYPE steps broke the sound on the device (row 19.12, read on both channels). The second slot's type is in PARAMS only |
| 6. A send | TRACKS, DELAY | E1 x3, hold K1, E2 x3, E3, then E1 x4, E2 (about 6 gestures, two pages) | TRACKS with K1 shows the send grid | With WET at 0 the send is silent, and no page says so. `NO SEND - TRACKS K1` covers only the other case, WET up and no send (mpages.lua:1646, 1653) |
| 7. Keep the sound | SCENE | spin E1 right, K3 (2) | `SLOT 1 EMPTY - K3 CAP`, then `SAVED 1` | Clean. The scene is control state for all four tracks, never audio (mscenes.lua:19) |
| 8. Bend further | any | as in 3 to 6 | | |
| 9. Fade to it and back | SCENE | spin E1 right, hold K1, turn E3 (2) | The rail `A LIVE ----o---- 1 B`. FADE shows in the footer only while K1 is held | Section 3, items 1, 3, 4, 7 and 8 |
| 10. Land it | SCENE | K2 (1) | At the end of the rail, `K2 TO LAND THE REST` | The player still holds K1 from the fade, so K2 is STOP (mpages.lua:2276, F:950). Landing swaps the voices whose mode differs |

The first pass through steps 1 to 10 costs about 45 moves on seven pages, with six
moves for step 8. Most of the moves are in steps 2 and 6, and both are fine once
learned. The losses are not in the move count. They are in section 3.

## 3. The friction, ranked

Ranked by how much it breaks the flow: a break in the sound or lost work first, then a
wrong reading, then a slow move.

1. **An effect TYPE change breaks the sound, and a fade causes it.** Each delay slot is
   born with an empty line under a playing input (E:1173-1176). The break lands one line
   length after the tap. The 19.12 recording shows it
   (four-device-recordings/2026-11-16/19.12_type_steps.wav, outside the repo). A fade
   flips every option at its midpoint (mscenes.lua:746): eight effect slots, four filter
   types, the clouds modes. DRY turns all eight slots OFF at once (F:2317).
2. **The fourth part loops a minute of silence.** One write head serves all four tracks.
   It runs only while rec or regen runs and has no reset (E:1444, 1472). A pass starts
   where the last one stopped (F:2460). Four parts of 15 s fill the buffer, and the take
   that crosses its end gets the whole 60 s as its window (F:2486).
3. **Coming home undoes the player's own moves.** The fade snapshots the live sound when
   it leaves 0 and forces it back at 0 (mscenes.lua:888, 896, 929). For a param that
   differs between the two ends, nothing tells it that a hand moved the param in between.
   A cutoff turned on FILTER while the fade was up goes back to the origin. The rec stop
   sets a new take's window (F:2479). The way home puts the old window back, and the new
   take plays the wrong region or silence. A param that both ends agree on already stays
   with the hand (mscenes.lua:797).
4. **The fade's chord sits on three destructive gestures.** On SCENE the fade is K1+E3.
   With K1 held, a K3 tap is DRY (F:937, 2309). DRY turns every effect off and frees the
   delay and reverb at once, a click under a tail (E:370, 391). It has no way back but a
   scene. It opens track 1's filter and leaves tracks 2 to 4 shut (F:2326). K3 held for a
   second clears slot B (F:931). A clear drops the fade's origin (mscenes.lua:721, 367),
   and the sound stays between the two ends with no way home. K2 is STOP, and the land
   cue asks for K2 while K1 is still down.
5. **A voice change opens a hole.** The old drone gets a 20 ms release and the new one is
   spawned in a separate message (E:345-356 for track 1, E:320-336 for tracks 2 to 4,
   E:676). Offline, the change into WARP dips
   28.6 dB for 149 ms, into PV 27.8 dB for 34 ms (doc/measurements/2026-11-15/README.md).
   CLOUD starts with empty buffers and is not measured. The new head restarts at the
   window start (E:655), so the loop loses its place.
6. **The CPU budget is already over.** Row 19.27's dense set took 64.1% of the scsynth
   thread against 60%, and its four PV at pitch 2 took 56.6%. Both sets carry eight
   effect slots, drive, both sends, the delay, the reverb and shimmer, and the row reads
   the worst 5 s of a minute. Four CLOUD in SPECTRAL take 38.7% of the JACK cycle, with
   three takes empty. A recall that changes four modes runs eight drones for 20 ms. ECHO
   allocates 512 KB in the audio thread (ugen/FourStretch.cpp:147-155). No screen says
   the load is high.
7. **The fade moves in steps.** It writes at 15 fps, and the engine's lags of 20 to 50 ms
   are shorter than the 67 ms frame. The staircase probe found the value still 61 to 74%
   of the time (doc/dsp-plan.md:402). CLOUD's density gain (14 dB), the clouds knobs,
   shimmer, rev_decay and rev_damp have no lag at all (E:1015, 1020, 1586, 1604). Clouds
   outputs zeros at a mode change, and the fade flips `clouds_mode` at the midpoint
   (ugen/vendor/eurorack/clouds/dsp/granular_processor.cc:186-192).
8. **A voice change does not fade.** Modes are out of the fade by design
   (mscenes.lua:193). A GRAIN sound kept in a scene and faded to from PLAY arrives as
   PLAY. The rail says `K2 TO LAND THE REST` only at the very end (mpages.lua:2275).
   For the whole fade the player hears another sound and does not know why.
9. **A send into a silent effect says nothing where it is opened.** See step 6.
10. **Per-track gaps in the take and the scene.** `win length` moves track 1's window
    only, and the rec stop calls it for any track (F:2204, 2505). A recalled scene clamps
    track 1's window against the FOCUSED track's take length, and tracks 2 to 4 not at
    all (mscenes.lua:467, 476). The loop end comes from a 15 Hz poll and lands up to
    67 ms early (F:3208, 2479). K1+E1 during a pass switches the write buffer with no
    ramp (E:1733, F:1813).
11. **The fade hides.** At rest the footer reads `A LIVE` and `B 1`. The fade is on the
    K1 layer (F:1005). It moves 1% per detent (F:3038). A full fade can need several
    turns: count them on the device.
12. **Timing traps on the keys.** The punch law on REC, the dead zone between a tap and a
    hold on K3, and K1 shared by the track pick, the fade, STOP and DRY. Each is right on
    its own. Together they are where a first-time player loses a take or the sound.

What is already clean: REC's punch-in and punch-out (10 ms ramps, E:1442-1471). The loop
seam (a 5 ms fade, E:678-680). The filter type, and drive and crush crossing 0
(E:236-274). `delay_time` (a 0.2 s glide) and STOP (a 50 ms fade, E:1415). Drive and
crush crossing 0, `delay_time` and STOP have no device measurement yet.

## 4. The changes

The smallest set. Each change says what the player gets, what it costs, what it must not
break and how to prove it. No param id changes. A new param is classified
(`SCENE_RECALL_IDS` or `SCENE_EXCLUDE`, `MOTION_IDS` or `MOTION_EXCLUDE`), and
test_control enforces it. No change below adds an engine command except C13, route (a).

### A. Stability (engine first, one change per RESTART)

Invariant 3 of CLAUDE.md holds: each engine change goes to the device and passes its row
before the next one is written. Each one runs `test/dsp/check_dsp.sh` first.

**C1. The effect slot changes with no break.**
- Player: TYPE, ON, DRY and a fade across the midpoint change an effect with no gap.
- Cost: one line at E:1175. The slot reads its input through a 10 ms fade-in
  (`sig * EnvGen.ar(Env([0, 1], [0.01]))`), so a new line fills from silence. The same
  at the shared delay's input (E:1521), where gate row 10.4 found the same break. No
  new synth, no new command. The dry dips under 0.5 dB for 10 ms.
- Must not break: "only what is heard exists" (rows 19.7, 19.10). OFF stays a bypass.
- Proof: a check_dsp probe steps TYPE over a tone on both channels and fails on a step.
  It cannot fail on a gap (section 8, question 10). gate.py learns to score both
  channels: at the fortieth change it read the left only (test/device/gate.py:2688) and
  missed RESON's breaks. Then rows 19.12 and 19.29 on the device.

**C2. A voice change keeps its sound and its place.**
- Player: K3 MODE and a landed scene change the voice with no hole, and the loop goes on
  from where it was.
- Cost: engine. Send the release and the spawn as one bundle, in `setMode` (E:345-356)
  and in `setModeN` for tracks 2 to 4 (E:320-336). Hold the old
  drone until the new one sounds: about 150 ms into WARP, 40 ms into PV, and CLOUD after
  a measurement. Start the new head at the old head's phase, read from the phase bus the
  polls already use (E:655). CPU: two drones for up to 150 ms. In Lua, a recall that
  changes several modes steps them one frame apart, so eight drones never run together.
- Must not break: OFF still frees the voice. `mode` stays last in `SWITCH_IDS`, so a new
  voice is born with the scene's params (mscenes.lua:56).
- Proof: the offline probe of doc/measurements/2026-11-15/ shows no dip deeper than
  6 dB. On the device, row 19.5 and a new row: PLAY to each mode and back over a tone.

**C3. The delay and reverb leave without a click.**
- Player: DRY, a scene or a fade that takes WET to 0 makes no click under a tail.
- Cost: engine. About 0.1 s after the mix reaches 0, look again. Still 0: free the
  synth, as `laneColour` does after 0.3 s (E:264-274). The CPU win stays.
- Must not break: the deliberate decision that a mix of 0 frees the synth and cuts its
  tail. It still does, 0.1 s later.
- Proof: a check_dsp probe takes `rev_mix` to 0 under a tail. On the device: DRY under a
  ringing tail, recorded.

**C4. Each part starts at the start of its own buffer.**
- Player: four parts of any length up to 60 s each. None of them loops a minute of
  silence.
- Cost: engine and Lua. A rising edge of rec with overdub at 0 resets the write head to
  0 (RecordBuf's trigger and the Phasor's reset, E:1444, 1472). Lua then takes 0 as the
  arm phase and ignores the first stale poll (F:2460). An overdub keeps today's law. The
  loop end adds the time since the last poll, so it no longer lands up to 67 ms early.
  A focus change during a pass re-arms on the next frame, after the 10 ms ramp.
- Must not break: start on sound (test_control section 25), ONE-SHOT handing a full
  track to the next (F:1869), the take UNDO (section 29), and the PSET bound `take_len`.
- Proof: test_control records four parts of 20 s in the simulator: every window starts
  at 0. On the device: row 19.4, and the same four parts.

**C5. The loop stays inside the CPU budget, and says so.**
- Player: the supported set never xruns. Near the limit, the header shows `CPU`.
- Cost: a measurement first, done on 2026-11-17 (doc/measurements/2026-11-17/). Nothing
  grew. The 57.3% of 2026-11-13 was the four dense voices inside preset 1, read once
  over 6 s. The 64.1% of 2026-11-16 is row 19.27's set: the same voices with eight effect
  slots, drive, both sends, the delay, the reverb and shimmer, and the worst 5 s of a
  minute. The four voices alone take 42.0%. Then write the supported set in the README.
  An example: four tracks, at most two of them PV or CLOUD, both sends, delay and reverb.
  The header word reads a norns CPU poll. That poll is the whole JACK cycle, not the
  scsynth thread (CLAUDE.md, the lessons). Measured: it reads 5 to 7 points above the
  thread at every load.
- Must not break: one blink only (the flag is steady). The redraw allocates nothing.
- Proof: row 19.27 passes with the supported set. A uisim render with a high stub value.

**C6. The fade moves without steps.**
- Player: a slow fade of a filter or a level sounds like a turn of the knob.
- Cost: engine, no new command. plan.md Phase 0 already names the successor of proposal
  B: a glide that follows the frame clock. Apply it to the controls a fade moves, and lag
  the ones with none (CLOUD's density gain, the clouds knobs, shimmer, rev_decay,
  rev_damp).
- Must not break: a hand on a knob still answers at once. The fade still runs at 15 fps.
- Proof: the staircase probe (the 27th change) reads the value still under 20% of the
  time. Item 2 of the listening script.

### B. Safety (Lua, proven in the simulator first)

**C7. A hand keeps what it moves during a fade.**
- Player: a knob turned while the fade is up stays where the hand put it, through the
  way home. A new take's window stays on the new take.
- Cost: lib/mscenes.lua. The fade keeps the value it last wrote for each id. Each pass
  compares it with the param. A param that differs left the fade: the fade skips it
  until it comes home. This is the project's rule, capture by polling and never by
  wrapping `set` (CLAUDE.md). It also covers the rec stop, a motion lane and MIDI.
- Must not break: home is exact for every id the hand did not touch (the 38th change's
  tests). `morph(1)` is still not `recall(B)`. A pass allocates nothing.
- Proof: test_control. Fade to 0.5, turn `t2_cutoff`, fade to 0: `t2_cutoff` keeps the
  hand's value and every other id is back on the origin. Record on track 2 during a fade
  and fade home: the window is the new take's. The scene must hold another `t2_cutoff`
  and another window than the origin, or both pass before the fix (mscenes.lua:797).
  Revert the fix and see both fail.

**C8. An option crosses the midpoint once.**
- Player: a fade rocked around the middle does not switch an effect or a filter type on
  and off.
- Cost: a band in `morph_value` (mscenes.lua:746). Switch to B above 0.55, back to A
  below 0.45. `clouds_mode` joins `MORPH_EXCLUDE`, because Clouds goes silent at a mode
  change. If C1 fails on the device, the effect types join it too, and K2 lands them.
- Must not break: the ends land exactly on A and B.
- Proof: test_control steps the fade 0.49, 0.51, 0.49, 0.51 and counts one switch.

**C9. The fade's chord stops destroying.**
- Player: a slip of K3 or K2 while K1 holds the fade costs nothing that cannot come back.
- Cost: three small parts.
  1. `M.clear` refuses a slot that an engaged fade departed from or aims at, and says
     `FADE ON 4: HOME FIRST` (93 px).
  2. DRY becomes a throw like OPEN and WASH (F:491): a second K1+K3 tap brings back what
     DRY moved. DRY also opens the filters of tracks 2 to 4 (F:2326).
  3. While K1 is held, the land cue reads `LET GO OF K1 THEN K2` (89 px, no comma: the
     font has none).
- Must not break: K1+K2 stays STOP and K1+K3 stays DRY on every page. The erase arc keeps
  its timing. A recall or a scene load still forgets the throws (`M.invalidate`).
- Proof: test_control. A clear during a fade is refused, and the fade still comes home.
  DRY twice restores every id it moved. DRY opens all four filters. test_screen reads the
  new cue.

**C10. Each track keeps its own window.**
- Player: a recalled scene never opens track 2, 3 or 4 onto silence. `win length` locks
  the focused track, not only track 1.
- Cost: `clamp_stored` (mscenes.lua:476) clamps each track's window against that track's
  own take length, through a `ctx` reader over `TAKES` (F:1639). `apply_window_len`
  (F:2204) uses the focused track's ids through `tid`.
- Must not break: test_control sections 12 (a recalled scene never opens the window onto
  silence) and 28 (the window locked to the clock).
- Proof: extend both sections to track 3, with the focus on track 2.

### C. Clarity (words and the screen)

**C11. TRACKS names a send into a silent effect.**
- Player: on TRACKS with K1, the D or R cell draws hollow while its WET is 0. Opening it
  says `DELAY WET IS 0` (61 px) for a second.
- Cost: `route_grid` in lib/mpages.lua, the sibling of `SPC_HINT` (mpages.lua:1646). The
  defaults stay: WET at 0 keeps the delay and reverb synths free, and that CPU counts in
  C5.
- Must not break: the grid's other cells, and the hint on DELAY and REVERB.
- Proof: uisim renders of `track2_03_TRACKS_SENDS` with WET at 0 and at 0.5. test_screen
  reads the hollow cell.

**C12. The fade shows itself.**
- Player: at rest, with B filled, the status row of SCENE reads `K1+E3 FADES` (50 px).
  Some of B can be out of the fade's reach: a voice mode or a hold. Then the B end of the
  rail reads a dim `+K2` for the whole fade. A full fade takes about one turn of E3.
- Cost: `body_SCENE` (mpages.lua:2265). The turn: a larger step for `scene_morph_amt` in
  `enc`, after a device count of detents per fade.
- Must not break: the 34th change's keys (E2 is A, E3 is B, K1+E3 fades). The message
  line still outranks the cue.
- Proof: uisim renders of SCENE at rest, mid-fade and at the end, with equal and with
  different modes. test_screen reads each cue.

### D. Relay, adapted: the take's record source

doc/idea-relay.md proposes a pass from one track's processed sound into another track's
take. Its trust contract is right. Its gesture can be smaller. four already records into
the focused track, with REC, UNDO, start on sound and the window snap. Relay then is one
new choice: WHERE the take records from.

**C13. TAKE records from IN, from a track, or from the mix.**
- Player: focus track 2. On TAKE, K1+E3 picks SOURCE: IN, T1, T3, T4 or MIX. K2, K2.
  Track 1 plays on, and track 2 now holds track 1's sound. UNDO brings back track 2's old
  take. A pass can also commit a heavy voice: copy a CLOUD track into PLAY on another
  track, then turn the CLOUD track OFF and win back its CPU.
- The tap: each track's bus after its filter, colour, effects and level, before its sends
  (`outBuses`, E:515, 1337-1338, 1378). The copy does not hold the shared delay and
  reverb.
- Cost: route (b) first. `rec_track` takes the source bus as a second argument. An arity
  change keeps `count: 198`, the ritual still applies, and REC and a relay pass cannot
  run together. Route (a), a relay synth after io, moves the count to 199 and costs under
  0.5% (an estimate). The destination is protected by the take UNDO, which holds the
  take before the pass (F:1738). C13 must mark the destination's take first: a take that
  a PSET restored on an unfocused track has no mark (F:1688-1692, 1854), and UNDO then
  has nothing to go back to. A scratch buffer pair (about 23 MB) with a swap waits:
  the engine assumes its buffer numbers never change (E:1804-1805).
- UI: SOURCE takes TAKE's K1+E3, now JITTER (`pos_jitter`), which VOICE's GRAIN face also
  reaches on K1+E2. The user decides (section 8).
- Must not break: REC writes only the focused track (row 19.4). SOURCE skips the focused
  track, so no track records itself. A source that hears the destination through a send
  (`send_<dest>_<src>` above 0) refuses with `T2 FEEDS T1 - SEND OFF` (91 px).
  `resample` and PRINT keep working.
- Proof: test_control (the source list skips the focus, the refusal, UNDO after a relay
  pass). check_dsp relays a filtered tone and compares it with the source's bus. On the
  device: the seven steps at the end of doc/idea-relay.md.

## 5. Phases

Each phase ends at a gate. Do not start the next phase before its gate passes.

| Phase | What | Changes | Gate |
|---|---|---|---|
| A. Click-free and in budget (done 2026-11-20) | Engine and device. The prerequisites | C1, C3, C4, then C2 and C6. C5 measures from the start | Rows 19.12 and 19.27 pass, and the rows A1 to A5 of section 6. The user hears plan.md Phase 2, items 4, 8 and 12 |
| B. Safe (built 2026-11-20, not on the device) | Lua only, a reload on the device | C7, C8, C9, C10 | test_control's new section, `LUA53=... lua test/check.lua`, dist rebuilt. Renders byte-identical except the new cues |
| C. Readable (built 2026-11-20, not walked on the device) | Lua only | C11, C12 | uisim renders looked at, test_screen. Then the observed walkthrough of plan.md Phase 4, with the loop of section 6 added as task 8 |
| D. Relay (built 2026-11-20, `count: 198`, on the device) | Engine and Lua, `count: 198` by route (b) | C13 | Starts after Phase C passes and the user says yes. The deploy ritual, then Relay's seven steps |
| E. The decision | Device, the user, a first-time player | none | Section 6. Then the README's first minutes become this loop, and the example presets show it |

Phase A also settles what plan.md Phase 3 (no glitch at a preset load) means here. The
loop never loads a preset mid-show, so Phase 3 is not its prerequisite. It stays in
plan.md for shows that load presets.

## 6. The device walkthrough and listening script

**Set up.** A fresh script, the supported set of C5, a drum machine and a synth at the
input. Record the output (`SuperCollider:out_1/2`, doc/plan.md "How to work") for the
offline click scan, and read the scsynth thread in `top -H` (CLAUDE.md, the lessons).
Save only to PSET slot 90. One person observes and writes, and explains nothing until a
task ends.

**Phase A's rows.** Each one is recorded on both channels and scanned offline. A gap is a
5 ms stretch more than 10 dB under the 100 ms around it, outside the loop seams. A step
is a click by the law of test/device/audio.py.

- A1. Six TYPE taps over a tone, then a fade rocked across 0.5 between two types: no
  step on either channel (rows 19.12 and 19.29). The gap law cannot score an effect row
  (section 8, question 10).
- A2. Four parts of 20 s: each window starts at 0 of its track, and none loops 60 s.
- A3. PLAY to each voice and back over a tone: no gap, and the loop keeps its place.
- A4. DRY under a ringing reverb tail: no click.
- A5. A fade of the cutoff over 2 s: the staircase probe reads still under 20% of the time.

**The card.** The player gets these six lines and nothing else:

1. E1 all the way left is TAKE. K2 records, K2 stops.
2. Hold K1 and turn E1 for the next track.
3. VOICE, FILTER and EFFECT change the track you are on.
4. E1 all the way right is SCENE. K3 keeps the sound.
5. Hold K1 and turn E3 to fade to the kept sound and back.
6. K1 and K2 together stop everything. Do it again to start.

**Part 1: a first-time player** (has never seen four, can know a norns).

1. Record four parts: drums, a bass line, a chord, a noise.
2. Change one voice, one filter and one effect, on any tracks.
3. Keep the sound.
4. Change two more things.
5. Fade to the kept sound and back, three times.
6. Point at the screen: which track records, which tracks play, where is the fade?

Pass, all of these:
- Tasks 1 to 5 done alone in 12 minutes or less.
- At most two wrong presses that cost sound (a STOP, a DRY, a lost take), and the player
  recovers from each without help.
- At the end all four takes play. No take was lost or replaced by mistake.
- Back at 0, the fade is home: in maiden, every id of the fade equals the origin, except
  the ids the hand moved (C7).
- Task 6 answered right from the screen alone.
- The player keeps playing after the last task without being asked. Write down how long.

**Part 2: the user, a five-minute set.** Free play on the same loop. With Phase D built,
Relay too.

Pass, all of these:
- No break and no click heard. The offline scan of the recording finds no gap, as
  Phase A's rows define it.
- The scsynth thread stays under 55% at p95, with no xrun.
- The user rates "easy" and "expressive" at 4 of 5 or more, and names one thing to cut.

**The listening script** (the user, with ears, one item at a time, written down in
doc/device-gate.md):

1. Fade between two scenes whose effect types differ, slowly across the middle, then
   rock it there. A click, a gap, or a clean change?
2. Fade a scene with a filter sweep from 200 Hz to 8 kHz. Do you hear steps?
3. Record a part while the fade is up, then fade home. Does the new take still play?
4. Fade to a scene with another voice, then K2 to land it. A click at the land?
5. K1+K3 (DRY), then K1+K3 again. Is it the same sound as before?
6. A full fade in one turn of E3: too fast, too slow, or right?
7. (Phase D) Relay a filtered track into an empty one. Does the copy sound like what you
   heard? A click where its loop wraps?

**The verdict.** Part 1 and Part 2 pass, and items 1 to 6 of the script are clean. Only
then does four lead with this loop, in the README and in the example presets. If a
first-time player needs help with the fade or loses a take, fix that first. More features
do not come before it.

## 7. What not to build

- No new page, and no page merge for this loop. Fewer pages is plan.md Phase 4, with the
  user.
- No voice mode inside the fade. It stays out by design (mscenes.lua:193) unless the
  user asks (section 8).
- No more work on the orbit. It stays in PARAMS. The loop does not use it.
- No new effect types, voices or modulators until Phase E passes.
- No automatic chains, tempo lengths or crossfades between sources in Relay (the
  proposal's own first version leaves them out too).
- No grid-only gesture. The grid stays a bonus surface.
- No WET above 0 by default. It costs CPU in silence, and C11 names the silence instead.
- Do not touch the deliberate decisions in CLAUDE.md: `morph(1)` is not `recall(B)`, the
  fade runs at 15 fps, the tape keeps its own loop law, and DELAY keeps its bouncing echoes.

## 8. Questions only the user can answer

1. **The hand during a fade (C7).** Keep a knob you turned while the fade was up, or
   always land exactly on the origin at 0?
2. **Four parts in time.** Does a take's length lock to the clock by default (`win
   length` per track, C10), or stay free and drift?
3. **DRY as a round trip (C9).** A second K1+K3 tap brings the sound back. Yes?
4. **Where the fade lives.** You chose E2 for A, E3 for B and K1+E3 for the fade (the
   34th change). In a show, which is more frequent, picking B or fading? If fading, the
   fade can take E3 and B can take K1+E3.
5. **The recall.** K2 lands a scene at once (NOW). Does it glide over two beats by
   default instead (`scene_recall_mode` GLIDE)?
6. **Relay's place (C13).** SOURCE on TAKE's K1+E3 in place of JITTER, or in PARAMS
   first? The user asked for Phase D on 2026-11-20 without choosing: it is on TAKE's
   K1+E3, as the plan proposed, and in PARAMS.
7. **The voice in the fade.** Leave voice modes to K2, or switch them at the midpoint
   once C2 makes a change clean? Each switch runs two drones for up to 150 ms.
8. **The supported set (C5).** Which four voices must play together in a show?
   Answered 2026-11-20: four PV at pitch 2 with every effect on (the README).
9. **The first-time player.** Who plays Part 1 of section 6?
10. **The dip at a type change (row A1).** A change into WOBBLE, CHORUS or FLANGE
    crossfades the sound with a late copy of itself. For 10 to 20 ms the two cancel in
    part, 11 to 17 dB deep in one 5 ms window, and no crossfade avoids that. CHORUS and
    FLANGE make the same holes on a steady tone with no change near them. So the gate
    scores steps and lists the holes (doc/measurements/2026-11-17/). Listen to
    `19.12_type_steps.wav` and `19.29_fade_rock.wav`: is the dip fine as it is?
    Answered 2026-11-20: fix it. The fifty-sixth change glides WOBBLE's delay (and
    plugin FLANGE's dry side) in from 0 and back out: OFF to WOBBLE -4.4 dB, was -15.8.
