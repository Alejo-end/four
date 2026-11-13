# four: the plan (written 2026-11-12, for the next session)

This plan says what to do next, in order, and why. Read CLAUDE.md first: it has
the hard rules, the deploy ritual and the lessons. The per-change history is in
doc/changelog.md. The plan before this one (mangler's, October 2026) is in git
history. Phase 5 below carries its open engine items.

The user performs with this instrument. Their words: "don't make me think, I
barely know what I'm doing, so it has to be really polished." Every change is
judged by that: can a tired player on a dark stage read it at once?

## Where the project stands

- **Name.** mangler2 replaced the one-track mangler and is now called **four**:
  `four.lua`, `Engine_Four` in `lib/Engine_Four.sc`, `engine.name = 'Four'`,
  SynthDefs `\four_*`. The old mangler is the git tag `mangler-1`. The OSC
  addresses are `/four/...` and the log lines start with `four:` (2026-11-13).
- **Fingerprint.** After a RESTART, maiden must read `count: 198`.
- **What four is.** Four tracks, each with its own 60 s of material. Each track
  has a voice (OFF, GRAIN, WARP, PV, PLAY, CLOUD), a window, a filter, COLOR
  (drive, crush) and SPACE (its delay and reverb sends). Tracks can send into
  each other. There are four modulators, and each one sits on a track. GRAIN is
  a granulator that reads the take. CLOUD is MiClouds.
- **On the device (norns shield, Pi 4, `norns.local`, user `we`).**
  - `dust/code/four` and `dust/data/four` are installed.
  - `dust/code/mangler` and `dust/code/mangler2` are deleted.
  - `dust/data/mangler` and `dust/data/mangler2` stay as backups.
  - The last code synced to the device is the screen change below. The script
    was not reloaded, because the user was playing it.
- **Measured on 2026-11-12.**
  - The worst case with four GRAIN tracks takes 45% of the scsynth thread.
  - A 30 minute soak ran at about 40% at 58 to 60 °C, with no throttling
    (`vcgencmd get_throttled` = `0x0`).
  - There were 0 xruns while playing. A preset loaded by hand gave a burst of
    3 to 7 xruns (doc/measurements/2026-11-12/).
- **Nobody listened yet** to the four-track work: per-track COLOR, SPACE and
  modulators, the new GRAIN, CLOUD, or the pad scatter.

### Git state (read `git status` first)

- **Branch `main`.** It is the four version, pushed on 2026-11-13.
- **Uncommitted, from this session: the screen change** ("four, second change"
  in doc/changelog.md):
  - The header track cells.
  - REC TRACK n on TAKE.
  - Steady writer letters.
  - Page dots on a 3 px pitch.
  - `test/device/soak.py`.
  - This plan.
- **Uncommitted, from another session: the visuals doodles.**
  - `visuals/hydra.js` and `visuals/README.md`.
  - A changelog entry titled "Hundred-and-fourteenth change". That number is
    already used, so it needs a new one.
  - When the user says so, commit these (see Phase 1, item 5).
- **The `../mangler2` folder.** It is a git worktree on branch `mangler2`. It is
  fully merged and can be removed with `git worktree remove ../mangler2` once
  the user agrees.
- **GitHub.** The repo is `Alejo-end/four` since 2026-11-13. The local folder is
  still named `mangler`: the user moves it, with no session open in it.

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
5. **Commit.** When the user says so, commit the doodle changes, the visuals
   README and their changelog entry. Renumber the entry first.
6. **The pre-show test.** When the cable is sorted, make sure that:
   - `node visuals/test_bridge.js` passes.
   - `lua test/check.lua` with `LUA53` set passes.
   - The norns answers on `norns.local`.
   - Maiden reads `count: 198`.
   - The system output level is not at -inf. On 2026-11-12 it read -inf, so
     crone's outputs were silent.

## Phase 2: the listening session (the gate for everything after it)

No test can judge sound. Before more engine work, sit with the user and walk this
list on the device. For each item, write down what they heard in
doc/device-gate.md, and fix or revert it.

1. GRAIN at grain jitter 0 (a steady stream) and at 1 (random). Then CLOUD on
   the same take. Is GRAIN nicer than the old Clouds-only voice?
2. GRAIN with spread 0 (the take's stereo) and 1 (wide). Then spray 0.5. Then
   FRZ held.
3. Per-track drive and crush (FILTER, K1 held). Is the crush range musical, or
   is it lo-fi too early?
4. The SPACE sends on the TRACKS grid (K1 held, columns D and R). Turn one
   track's reverb send down while the others keep theirs.
5. A modulator on track 3's cutoff. Is the small wave on TRACKS clear enough?
6. The header track cells and REC TRACK n on TAKE. Ask: "Can you tell what is
   recording, and what plays?" This is the user's own question.
7. A held GRAIN pad. Does it still buzz?
8. The effect slot (four, third change): CHORUS, FLANGE, WOBBLE, RESON and RING
   on one track, on the EFFECT page. Is each one worth keeping? Is the picture
   of each one clear? RESON's level was raised (four, fifth change): is it even
   with the others now, at every note?
9. The presets. They are tuned on CLOUD and have never been heard. Fix the table
   in test/make_set.lua after the listen, then rebuild.

To deploy the rebuilt presets, run `test/deploy_set.sh` (it writes to
`data/four`). It deletes the takes saved in slots 1 to 12, so ask the user
first.

## Phase 3: no glitch when a preset loads

- **Measured.** Loading preset 6 by hand gave 3 xruns at once, and 7 on a second
  load. That preset loads the same 50 s file five times: the take, tracks 2 to 4,
  and both layer decks.
- **Also seen.** crone printed "error seeking to frame 2400256; aborting read".
  softcut tries to read past the end of a 50 s file.
- **Goal.** Loading a preset during a show makes no audible glitch.

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
3. **Fewer pages.** There are thirteen: the user agreed to an EFFECT page
   after FILTER on 2026-11-12. The user asked for fewer pages and one
   focus before. Candidates are to fold TAPE and LAYERS into one deck page, and
   PADS and MOTION into one. Plan this with the user before you build it.
4. **A MIDI controller map.** The user asked if a controller can help the
   granular sound. Ask which controller they own (the question is unanswered).
   Then give each track a column of knobs (level, filter, send, grain size)
   through a shipped `data/four.pmap.example`.
5. **Keep every screen rule in CLAUDE.md:** brightness means audibility, one
   blink, the footer's four words, and no allocation per frame.

Prove each screen change with the uisim renders (`test/uisim/render_pages.lua`,
the variants `base` and `track2`) and test_screen. Look at the PNGs. A
redraw error on the device is a silent black screen.

## Phase 5: engine items left from mangler's plan

Before you build each item, make sure that it is still open: read the engine.
One at a time, each with a RESTART and a listen.

1. **Per-track reverb.** One reverb per track costs too much CPU on one scsynth
   core. SPACE is a send into the shared reverb for that reason. Revisit it only
   with a measurement.
2. **Shimmer costs CPU at zero.** Move the shimmer loop into its own spawn/free
   synth, like the reverb.
3. **The open filter is not a bypass.** At LP, 20 kHz and no resonance, the take
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
4. Deploy the rebuilt presets with `deploy_set.sh`? It deletes the takes in
   slots 1 to 12 of `data/four`.
5. Delete `CLAUDE_PLAN.md` (the original S0 plan) and `data/layers/` (old
   preset copies)?
6. Which MIDI controller do they own?

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
   4. Load the script, and make sure that maiden reads `count: 198`.
5. Capture audio from `SuperCollider:out_1/2` with `n.record(..., ports=...)`.
   crone's outputs follow the system output level.
6. Add an entry to doc/changelog.md for every change, as "four, Nth change".
   Keep the STATUS block in CLAUDE.md current.
7. When the user asks, commit. If you are on `main`, branch first. End the
   commit message with the session line the harness gives you.
