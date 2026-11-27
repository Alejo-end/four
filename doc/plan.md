# four: the plan (written 2026-11-12, corrected 2026-11-27)

This plan says what to do next, in order, and why. Read CLAUDE.md first: it has
the hard rules, the deploy ritual and the lessons. The per-change history is in
doc/changelog.md. The plan before this one (mangler's, October 2026) is in git
history. Phase 5 below carries its open engine items.

The user performs with this instrument. Their words: "don't make me think, I
barely know what I'm doing, so it has to be really polished." Every change is
judged by that: can a tired player on a dark stage read it at once?

Since 2026-11-17 a second plan sits beside this one: doc/signature-workflow.md, for one
loop of play (record four parts, bend them, keep the sound, fade back to it). It owns
gate rows 19.12 and 19.27 (its changes C1 and C5), and it uses Phase 2 and Phase 4 below
as its gates. This plan stays the order of work for everything else.

Since 2026-11-21 doc/clock-plan.md holds the user's notes of that day (the clock, the
record head, the input), built as the sixty-seventh to the seventieth change. They were
deployed at `count: 199`, and stage 21 of doc/device-gate.md was measured on
2026-11-24. Rows 21.1, 21.4 and 21.7 still need ears.

Since 2026-11-24 doc/mix-plan.md holds the mix of the tracks (the seventy-third and
seventy-fourth changes, on `main`). Its step 4 is open.

**What comes next (2026-11-27).** This list is written so that you can follow it without
an assistant. Each step says what to do and what to write down. The commands are in "How to
work on this project" at the end of this file.

1. Listen on the norns (about one hour, nothing to build). The norns runs proposal A now,
   at `count: 199`. First set PARAMS > REVERB to OFF: the system reverb adds reverb that four
   does not control. Then walk these rows of doc/device-gate.md, in this order: 22.7 (the
   mix), 21.1, 21.4 and 21.7 (set the tempo to 120 on SCENE with K1+E2 first). Each row says
   what to do and what you must hear. Last, proposal A: a take of bass or kick must keep more
   low end than on `main`. After each row, write one line in that row of doc/device-gate.md,
   for example "heard 2026-12-01: the hits stay on the beat".
2. Decide proposal A. `proposal-a` holds only commits on top of `main`, so a yes is
   `git checkout main && git merge --ff-only proposal-a && git push origin main`. A no is
   `git checkout main`, and then the engine ritual (step 4 of "How to work"), because the
   norns runs proposal A's engine. Never merge or push `proposal-dsp-fixes`: its history
   holds the private set.
3. If row 22.7 says the mix is still hard, step 4 of doc/mix-plan.md is next (the level from
   any page). It needs a mock-up first. If it is easy, the MIDI faders are enough, and the
   step closes.
4. If a show is near, do Phase 1 (the show checks).
5. Hold the session with a first-time player: doc/walkthrough.md has the card, the
   observer's sheet and the listening script. test/device/session.py measures it.
6. The rest of Phase 2, one item at a time. Then Phase 4 from what the sessions found. Then
   Phase 5: on 2026-11-27 items 2, 3, 4 and 6 were still open in the engine. Item 2 is
   built on branch `perf` (2026-11-28): deploy it, measure it, then merge it.
7. Answer the decisions at the end of this file. (Two were answered on 2026-11-27:
   `proposal-a` is on GitHub, and the old agent worktrees are removed.)

What a tool cannot judge, and why the order is so: four has many changes that nobody heard
(the table in CLAUDE.md, column "Heard"). Each new engine change adds to that pile. So build
no new sound until steps 1 and 6 are heard. Screen and control work (Phase 4) is safe at any
time: `lua test/check.lua` and the renders prove it, and a script reload brings it to the
norns.

## Where the project stands

The STATUS block of CLAUDE.md is the one record of the device: what is on it, the
fingerprint (`count: 199`), and what nobody has heard. Read it first. This plan says only
what to do.

- **What four is.** Four tracks, each with its own 60 s of material. Each track has a
  voice (OFF, GRAIN, WARP, PV, PLAY, CLOUD), a window and a filter. It also has COLOR
  (drive, crush), two effect slots and its sends to the delay and the reverb. Tracks can
  send into each other. Four modulators can sit on any track. Twelve pages.
- **Git.** Read `git status` first. On 2026-11-25 `main` was pushed at the seventy-seventh
  change, and `proposal-a` stands on it. The `../mangler2` folder is a git worktree on branch `mangler2`. It is
  fully merged, and `git worktree remove ../mangler2` removes it once the user agrees. The
  local folder is still named `mangler`: the user moves it, with no session open in it.
- **The change log.** The visuals doodles' entry carried the number 114 of the sound
  fixes. Since 2026-11-27 it is the hundred-and-fifteenth change.

## Phase 0: bring the device up to the code

The STATUS block of CLAUDE.md says which changes the device lacks. To bring it to
`count: 199`, in this order:

1. DONE 2026-11-16: the plugin built on the norns (`ugen/build_norns.sh`, the proof
   printed `all passed`), shipped in `ignore/plugins/`, installed by four itself.
2. DONE 2026-11-16: deployed and restarted, `count: 198` (the count of that day).
3. DONE 2026-11-16: the delay adds 1.4%, and in silence it costs less than with sound
   (doc/measurements/2026-11-16/). A silent CLOUD track costs more than a sounding one:
   3.9% against 2.5%.
4. Look at REVERB's four squares and at `NO SEND - TRACKS K1` on the OLED. The screens
   are captured (doc/measurements/2026-11-16/screens/19.22_REVERB_*_settled.png): the
   user still has to look. The text covers the top edge of the outer square.
5. (The album presets left the repo in the thirty-eighth change.)
6. DONE 2026-11-16: stage 19 ran on four for the first time (doc/measurements/2026-11-16/).
   It found that tracks 2 to 4 never reached the delay or the reverb, and the fortieth
   change fixed that. Row 19.12 (breaks when TYPE steps over a tone) has no break since
   the forty-second change. Open: 19.27, the dense set at 64.3% of the scsynth thread
   (doc/signature-workflow.md, C5). To run it again:
   `python3 test/device/gate.py 19`.
7. DONE 2026-11-16: the frame period, logged for 60 s while four played. 901 frames in
   60.00 s, p95 67.6 ms, none late, redraw p95 11.5 ms, and the sum of `frame_dt` is
   60.07 s, so a FREE modulator keeps its rate.
8. DONE 2026-11-24 (the seventy-second change). Found 2026-11-18 with row 19.33: WARP and PV dip at their own loop seam. Over a
   1 kHz take of 4 s the level fell by about 27 dB, for 82 ms in WARP and 26 ms in PV
   (doc/measurements/2026-11-18/). PLAY has its seam fade. doc/dsp-plan.md names the
   seam as not built. Row 19.33 now reads its levels away from the seam.

Proposal A is written again on `proposal-a` (never merge `proposal-dsp-fixes`: its history
is the private one). It was measured on the norns on 2026-11-25 (that branch's
doc/measurements/2026-11-25/README.md). Open there: the user's ears. The three
messages of a real-time memory failure print on the Mac (the seventy-ninth change).

Proposal B is dropped and kept on `proposal-b-ramp`. Its successor is built: the
fifty-third change, a glide whose time follows the pace of the writes (row 19.34 on
the device). Still to do there: capture the latency of OPEN, KILL and DRY, listen to an
LFO on the cutoff with resonance 0.7, and try a morph and a preset load.

## Phase 1: the show checks (needs the user at the hardware)

This list comes from the visuals session. Do 3 and 2 first, because they decide
whether the show works.

1. **News sound into the norns.** The norns input read silence. Make sure that
   the cable runs from the laptop headphone or line output into the shield
   input, and that the laptop output is set to it. The laptop showed only its
   built-in speakers. Without this, the news voices cannot reach the norns.
2. **Octatrack mapping.** The user saw CC 39 to CC 41 arrive, which proves the
   link. The channel 16 map (CC 70 to CC 97) with the Octatrack on MIDI port 2
   is not confirmed. Ask the user to turn a few knobs and press the buttons, and
   to say which ones move the norns. doc/octatrack-midi.md has the map. Its
   paths now read `dust/data/four/four.pmap`.
3. **The picture on a woken screen.** The kiosk page was restarted with the
   event-only doodles, but the display was asleep. Ask the user to wake it and
   make sure that the six shapes look right. If they still feel plain, ask which
   part.
4. **Launchpad colours.** Nobody has seen them on real pads yet.
5. **Commit.** Done: the doodle changes are committed, as the hundred-and-fifteenth change.
6. **The pre-show test.** When the cable is sorted, make sure that:
   - `node visuals/test_bridge.js` passes.
   - `lua test/check.lua` with `LUA53` set passes.
   - The norns answers on `norns.local`.
   - Maiden reads `count: 199`.
   - The system output level is not at -inf. On 2026-11-12 it read -inf, so
     crone's outputs were silent.

## Phase 2: the listening session (the gate for everything after it)

No test can judge sound. On 2026-11-16 the user listened to four with the plugin and
said "it sounds nice", a general judgement. The list below is still open. Before more
engine work, sit with the user and walk it on the device. For each item, write down what they heard in
doc/device-gate.md, and fix or revert it.

1. GRAIN at grain jitter 0 (a steady stream) and at 1 (random). Then CLOUD on
   the same take. Is GRAIN nicer than the old Clouds-only voice?
2. GRAIN with spread 0 (the take's stereo) and 1 (wide). Then spray 0.5. Then
   FRZ held.
3. Per-track drive and crush (FILTER, K1 held). Is the crush range musical, or
   is it lo-fi too early?
4. The sends (four, nineteenth change). Every send starts at 0. On TRACKS (K1
   held, columns D and R) open one track's sends, then a second track's. When the
   echoes and the tail come up, the dry sound must not duck. Then raise
   `dly_rev`, which sends the echoes into the reverb.
5. A modulator on track 3's cutoff. Is the small wave on TRACKS clear enough?
6. The header track cells and REC TRACK n on TAKE. Ask: "Can you tell what is
   recording, and what plays?" This is the user's own question.
7. A held GRAIN pad. Does it still buzz?
8. The effect slots (four, third change): CHORUS, FLANGE, WOBBLE, RESON, RING
   and ECHO on one track, on the EFFECT page. Is each one worth keeping? Is the
   picture of each one clear? RESON's level was raised (four, fifth change): is
   it even with the others now, at every note? FLANGE is new and ECHO is new
   (four, fourteenth change). Then the second slot (K1+E2 and K1+E3). The user
   found them "a bit too bland" on 2026-11-17, and the forty-fifth change made
   each one stronger at the same knob: is that enough, and is any too much now?
9. (The album presets left the repo. New example presets on free ambient
   samples are to come, and they need a listen too.)
10. The stretch voices of FourStretch: PV, WARP and PLAY at pitch 1 and away
    from it. The user liked them on 2026-11-13, before the ninth change.
11. The level (four, tenth change): everything is 7 dB quieter. Is that right?
    Do drive and RESON still bite?
12. The room (four, sixteenth change) and the bucket brigade (four, seventeenth
    change). Turn DECAY, DAMP and SIZE. Set a long delay time: it must grow dark.


## Phase 3: no glitch when a preset loads (DONE 2026-11-24)

- **Measured (2026-11-12).** Loading preset 6 by hand gave 3 xruns at once, and 7
  on a second load. That preset then loaded the same 50 s file five times: the
  take, tracks 2 to 4, and both layer decks. The decks are gone (four, thirteenth
  change), so measure it again on the rebuilt presets.
- **Also seen.** crone printed "error seeking to frame 2400256; aborting read".
  softcut tries to read past the end of a 50 s file.
- **Goal.** Loading a preset during a show makes no audible glitch.

- **Measured again (2026-11-24, doc/measurements/2026-11-24/).** 48 loads in a row with no
  recording gave no xrun, from memory or from the card, and crone logged no seek error.
  A load over four PV tracks gave 1 or 2 xruns (3 with the recording), each time 0.04
  to 0.06 s after it started, and the files alone gave none. So candidates 1, 2 and 4
  below have no measured case.
- **Found and fixed (2026-11-24, the seventy-second change).** The PV case is softcut's
  region clear of the tape, which a load of a preset with an empty tape runs. The
  candidates below have nothing left to fix.

Candidate fixes, in order of cost:

1. **Do not read a file twice.** If a track's file is the take's file, the
   engine copies the buffer in SuperCollider (`Buffer.copyData`) and does not
   read the disk again. This needs a new engine command, so the count moves: update
   CLAUDE.md, test_control and the ritual.
2. **Stagger the reads.** Space the file loads over a few frames with
   `clock.run`, instead of loading all of them in one frame.
3. **Fade the engine out and back in** around the load (about 50 ms each way),
   so a dropped block falls into silence.
4. **Clip softcut's read** to the file's real length, which ends the seek error.

To measure: `test/device/soak.py` gives the CPU and xrun numbers.
`n.xruns_since(n.now())` around one `params:read(6)` counts the xruns of one
load. Read real slots only. Never write slots 1 to 12. Use slot 90 (see the
memory note and CLAUDE.md).

## Phase 4: "don't make me think" (the screen and the controls)

The user still finds four hard to read. The 2026-11-12 screen change fixed the
two things they named. Next:

1. **Walk every page with the user.** For each page, ask what they think each
   word, number and mark means. Wrong guesses go on a list. doc/ux-feedback.md
   is the place for it.
2. **Fewer words that need a legend.** Some words still need one: GJIT, DTUN,
   SPRD, CRSH, 1>DLY, the route grid's D and R. Prefer full words at rest and
   short ones only while a knob turns. The footer already does this for some
   ids.
3. **Fewer pages.** There are twelve: the user agreed to an EFFECT page after
   FILTER on 2026-11-12, and LAYERS went in the thirteenth change. The user
   asked for fewer pages and one focus before. A candidate is PADS and MOTION as
   one page. doc/space-plan.md proposes one SPACE page for the sends, DELAY and
   REVERB, but in July the user asked for DELAY and REVERB apart
   (doc/ux-feedback.md, point 21). Plan this with the user before you build it.
4. **A MIDI controller map.** The user asked if a controller can help the
   granular sound. Ask which controller they own (the question is unanswered).
   Then give each track a column of knobs (level, filter, send, grain size)
   through a shipped `data/four.pmap.example`.
5. **Keep every screen rule in CLAUDE.md:** brightness means audibility, one
   blink, the footer's four words, and no allocation per frame.

Prove each screen change with the uisim renders (`test/uisim/render_pages.lua`,
the variants `base` and `track2`) and test_screen. Look at the PNGs. A
redraw error on the device is a silent black screen.

### The observed walkthrough (step 1 of this phase)

An outside review of the screen (2026-11-15, four's twenty-third change) asks
for this before any redesign. It tests what a player understands without help.
Do it on the device, with sound, after Phase 0.

**Set up.** A fresh script, no preset loaded, a sound source at the input.
Save only to PSET slot 90. One person observes and writes, and does not
explain anything until a task ends. When the player stops or asks a question,
take a photo of the screen.

**The tasks**, in this order, each one started from TAKE:

1. Record a take of about ten seconds on track 1, then stop.
2. Record a second take on track 2.
3. On track 1, change the voice to GRAIN and make the grains longer.
4. Send track 2 into the reverb, and make the reverb louder.
5. Undo track 2's take.
6. Save the sound into scene 3. Change two knobs. Recall scene 3. Then go
   back to the sound before the recall.
7. Freeze track 1's voice (it is GRAIN now). Start a take on track 2. Go to
   DELAY, and say from the screen what is frozen, what records and what
   plays.

**Ask before you explain.** After each task, point at the screen and ask:

- "What does this word mean?" for each footer word on the page, and for the
  header's cells and letters (T, M, FZ, LF).
- "Which track records now? Which tracks play?"
- "Held here, what does K3 do? What does K1 change here?"
- At one page of each family: "One turn of E1 from here: which page comes next?"

**Write down** for each task: done alone, done with help, or not done. The
time it took. Each wrong press (the key, the page, what the player expected).
Each word the player asked about or guessed wrong, and the guess. Where the
player looked first.

**After it.** Put the results in a new dated section of doc/ux-feedback.md,
the wrong guesses as a list. Then ask the user to decide on the review's
proposals (the twenty-third change's entry names them) with the list in hand.
Build only what the user accepts.

## Phase 5: engine items left from mangler's plan

Before you build each item, make sure that it is still open: read the engine.
One at a time, each with a RESTART and a listen.

1. **Per-track reverb.** One reverb per track costs too much CPU on one scsynth
   core. SPACE is a send into the shared reverb for that reason. Revisit it only
   with a measurement.
2. BUILT 2026-11-28 on branch `perf` (the eighty-first change), not on the norns yet:
   **Shimmer costs CPU at zero.** The shimmer is its own spawn/free synth now.
3. BUILT 2026-11-28 on branch `perf` (the eighty-second change), not on the norns yet:
   **The open filter is not a bypass.** At LP, 20 kHz and no resonance, the take
   still passes through the DFM1 ladder. Crossfade to the dry signal at the end
   stop, and make `purity()` test the same end stop.
4. **Resample and regen print after the fader.** Take `preLim` before the level
   multiply, and keep the `(level > 0.001)` gate.
5. **Duplicated grain code.** The GRAIN drone and the pad voice repeat the
   stereo-pair law. Make a build-time function, like `winRead` and `colour`.
6. **Linked stereo limiting.** Derive one gain from `max(abs(L), abs(R))` and
   apply it to both sides.
7. **Reversed grains.** Add a per-grain direction probability (`grain_rev`), as
   one new command.
8. **The rest of doc/space-plan.md.** Its section 8 is the order of work, and
   its sections 13 to 15 say what is built.

### Performance, ranked (review of 2026-11-28)

The supported set (four PV at pitch 2 with every effect on) reads 53.6% to 62.2% of the
scsynth thread, at the 60% limit. Where the points go (doc/measurements/2026-11-17/): the
four PV voices about 32, the reverb 6.0, the effect slots about 9, the delay 2.7, drive 2.5.

1. The shimmer (above, item 2): built, about 1 point while the reverb plays at shimmer 0.
2. Built (the eighty-second change, branch `perf`): an open filter is a copy, the sends into
   a track run only while one is open, and the meters only while TRACKS shows them. The open
   filter drops DFM1's faint third harmonic, so it needs a listen.
3. A silent CLOUD track costs more than one that sounds (3.9% against 2.5%). A guess to test
   on the norns: denormal numbers in Clouds' feedback paths. Set the flush-to-zero bit in
   FourCloud's calc function and read `measure.py` again.
4. CHORUS, FLANGE and WOBBLE share `\four_fx_mod`: 90 UGens, mostly control rate, about
   0.01 point each a slot. A def for each type would be smaller, but a change between the
   three would crossfade instead of glide for 100 ms. That is the user's call.
5. PV itself: the C++ is near its floor. Each hop is three forward and two inverse FFTW
   transforms of 2048, and the read and the sinc already use NEON. A real saving needs
   a different algorithm (a smaller frame at high pitch), which changes the sound.

## Phase 6: the device (the S-4 alternative)

The goal in memory is a physical instrument in the norns form factor, meant to
beat the S-4. It has a DIY 16x8 grid in `../grid128`, which is not ordered yet.

- **Cooling.** The Pi 4 runs at 58 to 60 °C under the soak, with 20 °C of room
  before it throttles. In a closed case, start with a passive heatsink or a
  thermal pad to a metal case. A fan is a last resort: it is heard in quiet
  passages, and its noise can reach the audio. If a fan is needed, switch it at
  about 70 °C with the `gpio-fan` overlay, on a GPIO pin that the shield does
  not use. Check the pin first.
- **The grid.** Review `../grid128` with the pcb-design-review skill before
  ordering.

## Decisions for the user

Each one needs a yes or a no. Ask the user. Do not decide.

1. (done 2026-11-13: `main` is pushed and the GitHub repo is `four`.)
2. Rename the local folder from mangler to four?
3. Remove the `../mangler2` worktree?
4. (Answered 2026-11-16: the album presets and `data/layers/` left the repo.)
5. (Answered 2026-11-16: `CLAUDE_PLAN.md` is deleted. Git history keeps it.)
6. Which MIDI controller do they own?
7. One SPACE page (doc/space-plan.md, section 7.2), or DELAY and REVERB as two
   pages, as the user asked in July?
8. (Answered 2026-11-27: `proposal-a` is pushed to GitHub. It holds no private history.)
9. (Answered 2026-11-27: the three agent worktrees are removed. Their branches stay local.)

## How to work on this project

The details are in CLAUDE.md. In short:

1. Make the smallest change that can be tested.
2. Add a test for every bug that you fix. Then revert the fix and make sure that
   the test fails.
3. Run `LUA53=<lua 5.3> lua test/check.lua`. Rebuild `dist/four_single.lua`
   with `lua test/amalgamate.lua`. Rebuild `doc/controls.md` with
   `lua test/controls.lua` when knobs or keys change.
4. For an engine change, follow the ritual:
   1. Run `rsync --delete` to `dust/code/four/`.
   2. Run `sudo systemctl restart norns-jack norns-crone norns-sclang
      norns-matron` over one SSH master session that stays open.
   3. Wait for both `compile done` and the `engines: [...]` line in the
      sclang log. A load before the second line hangs.
   4. Load the script, and make sure that maiden reads `count: 199`.
5. Capture audio from `SuperCollider:out_1/2` with `n.record(..., ports=...)`.
   crone's outputs follow the system output level.
6. Add an entry to doc/changelog.md for every change, as "four, Nth change".
   Keep the STATUS block in CLAUDE.md current.
7. When the user asks, commit. If you are on `main`, branch first. End the
   commit message with the session line the harness gives you.
