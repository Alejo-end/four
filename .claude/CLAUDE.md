# CLAUDE.md — four

Agent manual for **four** (it was mangler, then mangler2), a norns live stereo
sample-mangling instrument with four engine tracks. Read this first: the status, the
hard rules, and the lessons the project paid for. The per-change history is in
**doc/changelog.md** (oldest first; the newest entry is at the end). Keep the status
block current, and add a change-log entry for every change.

---

## STATUS (2026-11-20)

This block is the one record of the device, the fingerprint and what nobody has heard.
doc/plan.md points here. Keep it current. When you change it, date it.

**Names.** Script `four.lua`, class `Engine_Four` in `lib/Engine_Four.sc`,
`engine.name = 'Four'`, SynthDefs `\four_*`. The code goes to `~/dust/code/four/` and
the data lives in `~/dust/data/four/` (`four-NN.pset`, `four.pmap`). The OSC addresses
are `/four/...` (lib/mosc.lua and visuals/bridge.js must agree), and the log lines start
with `four:`. The one-track mangler is retired as the git tag `mangler-1`. The GitHub
repository is `Alejo-end/four` since 2026-11-13, and the old address redirects.

**The fingerprint.** After a RESTART, maiden must read **`count: 198`**. That is
mangler's 66 and nine for track 1: crush, the two FX sends, and six effect commands for
the two slots. Then `dly_rev`, 36 for each of tracks 2 to 4, 12 sends, `rec_track` and
`buf_track`.
Older text in this repository says 63, 65, 66, 173, 185 or 197: each was true in its day.

**The instrument.**
- Four tracks, each with its own material (four 60 s buffers). K1+E1 picks the track.
  A new take starts at the start of its track's buffer (the forty-ninth change), so four
  parts of up to 60 s each fit. An overdub goes on from where the write head is.
- Each track has a voice (OFF GRAIN WARP PV PLAY CLOUD), a window, a filter, COLOR
  (drive, crush), two EFFECT slots in series and its sends to the delay and the reverb.
  The effect types are OFF CHORUS FLANGE WOBBLE RESON RING ECHO, each with an amount and
  a rate. The second slot's type has no key yet: it is in PARAMS. The amount knob rises
  fast at first (its square root, the forty-fifth change), and no type is quieter than
  the dry sound.
- GRAIN is a granulator that reads the take: stereo grain pairs, spray, and timing from
  regular to Poisson. A cloud holds 48 pairs with the plugin and 32 without. CLOUD is
  Mutable Instruments Clouds: `FourCloud` from our plugin, else an installed MiClouds,
  else the GRAIN granulator. The log says which (`four: CLOUD is FourCloud`).
- Four modulators, each on any track.
- AUTOSAMPLE (lib/msample.lua, PARAMS > take - autosample): every note of a range
  goes out of a MIDI port, comes back on the line input into one take, and is cut on
  its attack. A MIDI keyboard then plays the take as a multisample (`ctx.pad_notes`).
- Twelve pages: TAKE VOICE TRACKS TAPE FILTER EFFECT DELAY REVERB MIX PADS MOTION SCENE.
  TRACKS is the hub: E2 picks the focused track, which TAKE, VOICE, FILTER and EFFECT
  then edit. K1 held on TRACKS shows the sends.
- Each track's path is a lane of small synths (`buildLane`, `laneSet` in the engine).
  Only what is heard exists: one filter family, the colour while drive or crush is up,
  one synth for each effect slot that is on.
- SPACE is two sends. Each track's `fx_dly` and `fx_rev` start at 0. The returns are
  added to the dry sum, which never ducks. `dly_rev` sends the echoes into the reverb.
  When the effect is up and nothing feeds it, DELAY and REVERB say `NO SEND - TRACKS K1`.
  The presets in `data/` say `fx_dly = 1` and so on for the tracks that sent before.
- A track leaves its filter at the level of its take (`dfmTrim`). The output is 7 dB
  quieter than before the tenth change, so drive and RESON bite later on the knob.
- The tape is the one softcut deck, on the deck law in lib/mdeck.lua. A pass records
  what four plays: `cut_source` starts at 1 (WET, the engine's output), and K1+E3 on
  TAPE turns it to DRY, the line input alone. TAPE names the source and says when a pass
  hears nothing. A new take (a REPLACE pass) starts at the tape's start, and its loop is
  the first seconds of the tape. The layer decks are gone. `MOTION_IDS` keeps their fourteen ids in
  place as tombstones (`MOTION_TOMBSTONES`). `data/layers/` and doc/layers.md stay,
  labelled as old.

**FourStretch, our own plugin.** `ugen/` holds our UGens (FourPV, FourWarp, FourRead,
FourGrain, FourDelay, FourRoom, FourBBD, FourTanh, FourCloud) and their proof
`ugen/test_core.cpp`, in plain C++. `lib/FourStretch.sc` is their ONLY class file: the
binary goes alone into `~/.local/share/SuperCollider/Extensions/FourStretch/`, never with
a second class file. With the binary the log says `four: FourStretch on`. Without it the
engine builds the stock voices and effects.
- `FourCloud` is Clouds, the code of mi-UGens' MiClouds copied unchanged into
  `ugen/vendor/` (commit and licenses in `ugen/vendor/README.md`). Same inputs, same
  samples (rendered offline against a MiClouds of the same commit). Never name it
  `MiClouds`: a second MiClouds class next to an installed mi-UGens hangs every script.
  Every build needs `-Iugen/vendor/eurorack`.
- **four installs its own plugin** (35th and 36th changes). A binary built on a norns
  with `ugen/build_norns.sh` lands in `ignore/plugins/<uname -m>/FourStretch.so` (inert
  on the norns, deployed like the rest; the repo ships one for armv7l, the same file for
  aarch64). `lib/install_plugin.sh` holds the rule: it copies that `.so` alone into
  Extensions when none is there or the shipped one is newer with other bytes. It checks
  the ELF class and machine against scsynth's, writes nothing else, and never touches
  mi-UGens. `Engine_Four.installPlug` runs it from `*initClass`, while sclang starts and
  before it boots the server, so the one RESTART after `;install` brings the plugin in.
  lib/mplugin.lua runs it again at four's load as a fallback, and when that installs it
  says `PLUGIN INSTALLED / SYSTEM > RESTART`. `test/test_plugin.lua` proves the cases.
- The engine uses the plugin only when the binary is the one that was there when
  sclang started (`Engine_Four.bootPlug`). One installed since then waits for the
  RESTART (`four: FourStretch is new since the restart`), so a reload without a RESTART
  plays the stock voices instead of silence. FourCloud needs a binary that holds it
  (`plugHas`): an older binary leaves CLOUD to MiClouds or the granulator.

**SuperCollider on the Mac (2026-11-13).** 3.14.1, without sc3-plugins or mi-UGens, so
DFM1 and JPverb take their fallbacks there, and CLOUD is FourCloud only in the plugin
build. `test/dsp/run_engine.sh` compiles the
real engine with a stand-in for CroneEngine, prints the command count and renders the
SynthDefs offline. `an_engine.py` measures them. `test/dsp/check_dsp.sh` runs the whole
offline DSP check with one verdict (see the workflow). Invariant 3 below is out of date for
stock UGens. The DSP plan and its measurements: doc/dsp-plan.md.

**On the device.** A norns shield on a Pi 4: `norns.local`, user `we`.
- Since 2026-11-18 it runs the fifty-third change at `count: 198`, with the plugin
  built there on 2026-11-16 (`ignore/plugins/armv7l/`), which four's startup install put
  in Extensions. Its scsynth is 3.13.0-dev (the Mac's is 3.14.1). The plugin of 2026-11-13 is kept in
  `~/fourstretch-backup/` on the device. mi-UGens is installed there too
  (`Extensions/supercollider-plugins/`).
- `dust/code/mangler` and `dust/code/mangler2` are deleted. `dust/data/mangler` and
  `dust/data/mangler2` stay as backups.
- `dust/data/four` holds older presets of the user's. A test that writes a PSET on the
  device uses slot 90.

| Change of four | On the device | Heard |
|---|---|---|
| 1st, 2nd: the names, the header's track cells | yes | no |
| 3rd to 5th: the effect slot, the EFFECT page, RESON's level | yes, `count: 185` | no |
| 6th to 9th: the exact read head, FourStretch | yes, `four: FourStretch on` | the user liked it on 2026-11-13, before the ninth |
| 10th: unity gain | yes | no |
| 11th: the deck pages | yes, screenshots | the user has not seen it |
| 12th: lanes, the second slot | yes, `count: 197` | no |
| 13th: the layer decks removed (Lua) | yes, see below | no |
| 14th: FourGrain, the new FLANGE, ECHO | yes | no |
| 15th: the name everywhere, the opening | yes | |
| 16th: THE ROOM | yes | no |
| 17th: THE BUCKET BRIGADE | yes, 2026-11-16 | no |
| 18th: REVERB's four squares (Lua) | yes, 2026-11-16, not looked at | no |
| 19th: the sends, `count: 198` | yes, `count: 198` | no |
| 20th: the README and its pictures | documents only | |
| 21st: the documents agree with the code | documents only | |
| 22nd: the first grain, the erosion head, a lighter FourBBD (engine and plugin) | yes, 2026-11-16 | no |
| 23rd: the screen review (Lua) | yes, 2026-11-16 | |
| 24th: gate.py follows four (test tools) | not run there yet | |
| 25th: stage 19 of the gate (documents, test tools) | not run there yet | |
| 26th: the offline DSP check (Mac only) | not for the device | |
| 27th: the frame clock, the LFO rate cap (Lua), the staircase probe | yes, 2026-11-16, the frame period not logged | |
| 28th: the pre-merge review's fixes (test tools, documents) | not run there yet | |
| 29th: a short README, the guide in doc/manual.md, the GPL v3 license | documents only | |
| 30th: the README picture on the handheld case | documents only | |
| 31st, 32nd: README, safer deploy line, the clip exporter | documents, test tool | |
| 33rd: SCENE A and B crossfader (Lua) | yes, 2026-11-16 | no |
| 34th: SCENE: E2 is A, E3 is B, K1+E3 fades (Lua) | yes, 2026-11-16 | no |
| 35th: FourCloud, four installs its own plugin (engine, plugin, Lua) | yes: installed itself, `four: CLOUD is FourCloud` | the user, 2026-11-16: "it sounds nice" |
| 36th: the plugin installs while the norns starts: one RESTART (engine, Lua) | yes: one RESTART, then `four: FourStretch on` | the user, 2026-11-16: "it sounds nice" |
| 37th: the documents tidied, the known limits, the visuals named four | documents, visuals scripts | |
| 38th: the album preset set leaves the repo | nothing on the device changes | |
| 39th: CLAUDE_PLAN.md deleted, this file moves to .claude/ | documents only | |
| 40th: tracks 2 to 4 reach the delay and the reverb (io's `t_dly` was a trigger control) (engine) | yes, `count: 198`, measured | no |
| 41st: the Relay brief and the plan doc/signature-workflow.md | documents only | |
| 42nd: an effect synth and the shared delay fill their lines from silence (C1 of the plan) (engine, test tools) | yes, 2026-11-17, `count: 198`: rows 19.12, 19.29 and 10.4 with no break. Not pushed | no |
| 43rd: the CPU budget part by part, `measure.py budget` (the first step of C5) (test tool, documents) | measured there, 2026-11-17 | |
| 44th: the delay and the reverb leave 0.1 s after their mix reaches 0 (C3 of the plan) (engine, test tools) | yes, 2026-11-17, `count: 198`: row 19.30 with no break. Not pushed | the user, 2026-11-17, on the build as a whole: "I think it sounds good" |
| 45th: the effects are stronger at the same knob, and none is quieter than the dry sound (engine, test tools) | yes, 2026-11-17, `count: 198`: row 19.11's levels, 19.12 and 19.29 with no break. Not pushed | no. The user asked for it: the effects were "a bit too bland" |
| 46th: the tape records what four plays (`cut_source` starts at WET), and TAPE says when a pass hears nothing (Lua, test tools) | yes, 2026-11-17: row 19.31. Not pushed | no. The user asked: "I don't know how can I record the tape" |
| 47th: an Exquis driver in lib/mgrid.lua, PADS and KEYS (Lua, test tool) | deployed with the rest; never run on an Exquis: no device yet | |
| 48th: a new tape take starts at the tape's start, and softcut's late report of the head is dropped (Lua, test tools) | yes, 2026-11-17: row 19.31 armed 2 s before the tape's end. Not pushed | no |
| 49th: each part starts at the start of its own buffer: a new take puts the write head at 0 (C4 of the plan) (engine, Lua, test tools) | yes, 2026-11-18, `count: 198`: row 19.32, four parts of 20 s. Not pushed | no |
| 50th: a clear zeroes the buffer again 60 ms later, when a write that was running has faded out (engine, test tools) | yes, 2026-11-18, `count: 198`: row 10.8 reads all zero. Not pushed | |
| 51st: a voice change keeps its sound and its place: the old drone holds and fades under the new one, and the new head starts where the old one is (C2 of the plan) (engine, test tools) | yes, 2026-11-18, `count: 198`: row 19.33, WARP -0.4 dB, PV -0.9 dB, CLOUD -1.3 dB (-26.4, -70.6 and -71.2 before). Not pushed | no |
| 53rd: a knob that moves once a frame draws lines: each knob's lag is a glide whose time follows the pace of the writes (C6 of the plan) (engine, test tools) | yes, 2026-11-18, `count: 198`: row 19.34, still 0.8% of the time (45.9% before). Not pushed | no |
| 54th: the header says CPU while the load is near the limit (the rest of C5's screen part) (Lua, test tool) | yes, 2026-11-18: on at 62.9% of the JACK cycle, off at 21.1% | |
| 52nd: PRESS, a seventh modulator shape: keyboard pressure moves a knob (Lua, test tool) | no. Never run with a pressure keyboard | |
| 55th: AUTOSAMPLE: four plays a MIDI note range out, records it into one take, and a keyboard plays it as a multisample (Lua, test tool) | deployed 2026-11-20 and loads; never run with gear. The TRS jack is norns port 3, `virtual` (ttymidi on /dev/ttyAMA0, client `shieldXL`) | no |
| 56th: WOBBLE and plugin FLANGE glide their delay in and out; the supported set (engine, test tools, documents) | yes, 2026-11-20, `count: 198`: row 19.12 no break and no hole, 19.27 passes on the supported set | no |
| 57th: Phase B, the fade is safe: a hand keeps what it moves, an option crosses once, a clear of an end is refused, DRY is a round trip, each track keeps its own window (Lua, test tools). On `main` | deployed 2026-11-20 and loads; not walked | no |
| 58th: Phase C, the screen: a send into a silent effect is hollow, SCENE says K1+E3 FADES and +K2 (Lua, test tools). On `main`. One turn of E3 is a whole fade (step 0.04, from the user's count) | deployed 2026-11-20, loads | no |
| 59th: RELAY, the take's SOURCE: IN, a track or the MIX, on TAKE K1+E3; `rec_track` takes it as a third argument ("iii") (engine, Lua, test tools) | yes, 2026-11-20, `count: 198`: T1, T3 and MIX relayed into another track, IN silent, the refusal | no |
| 60th: motion without visiting MOTION (first move starts a pass, PASS in bars closes it, overdub stays armed, double-tap K1), MIDI faders as the mixer, the control page on the computer (Lua, visuals, test tools) | deployed 2026-11-20, loads; OSC in from the computer moved params. Faders and double tap not tried | no |
| 61st: Phase E's sheets (doc/walkthrough.md) and test/device/session.py; rows 19.12 to 19.34 again on the current build (documents, test tools) | yes: the tool ran, the rows hold | no |
| 62nd: the review's fixes: AUTOSAMPLE records IN, an overdub across the seam, the 60 s cap from the first move, DRY and the other throws, typed OSC values, the lock at a focus change, the bridge's Origin check (Lua, visuals, test tools) | deployed 2026-11-20 | no |
| 63rd: every harness runs with an Exquis: a stand-in in the offscreen norns, three more runs each way in check.lua, stage 20 of the gate, test/device/exquis.py (test tools, documents) | not run there: no Exquis yet | |

The thirteenth change's entry says that nothing ran on the device. The fifteenth
change's opening, in the same `four.lua`, drew there, so its Lua is on the device. Nobody
walked the twelve pages there yet.

Measured on the device (doc/measurements/2026-11-12/ and 2026-11-13/). The scsynth thread
xruns past about 60%.
- Four PLAY tracks take 25.2% (twelfth change). With preset 1's reverb and delay on
  (tracks 2 to 4 did not reach them until the fortieth change; the effects cost the same):
  four PLAY 17.2%, four PV 28.6%, four GRAIN 19.1% (sixteenth change). Four PV at pitch
  2 take 53.0%. The user's heaviest set takes 57.3%, with no xruns.
- A soak of 30 minutes (2026-11-12) ran near 40% at 58 to 60 °C, with no throttling. A
  preset loaded by hand gave 3 to 7 xruns (doc/plan.md, Phase 3).
- With the plugin of 2026-11-16 (doc/measurements/2026-11-16/): all tracks OFF 9.8%.
  One CLOUD track 12.2%, four 29.1%, four in SPECTRAL 38.7%. The delay adds 1.4%, and
  20 s after the sound stops it costs less than with sound. A silent CLOUD track costs
  3.9% against 2.5% for one that sounds: Clouds in silence is not free. No xruns.
- The budget, part by part (2026-11-17, doc/measurements/2026-11-17/): all OFF 3.2% of
  the thread, four PLAY 10.9%, four PV at pitch 2 35.4%, the dense voices 42.0%. The
  reverb adds 6.0 points, the delay 2.7, drive 0.6 a track, FLANGE 1.2 a slot, ECHO 1.1 a
  slot. Row 19.27's sets are dressed with all of that: 62.4% and 55.9% as means, 64.5%
  and 56.6% as the row's largest window. The norns poll `cpu_avg` is
  `Crone.server.avgCPU`, and it reads 5 to 7 points above the thread at every load.
  The same evening, at 62 C against 52 C, every state read 0.5 to 1.0 point more: the
  dense set 63.3%. The forty-fifth change costs nothing: four FLANGE add 4.9 points and
  four ECHO 4.0 (4.8 and 4.2 before).

**Phase A of doc/signature-workflow.md is done (2026-11-20)** and merged into `main`.
C1 to C6 are the forty-second to the fifty-fourth change. On 2026-11-20 the user said they
had heard the forty-fifth to the fifty-fourth change and asked for the merge. They
answered question 8: the supported set is four PV at pitch 2 with every effect on (the
README), and row 19.27 decides on it (53.6% to 62.2% over four runs, one run with one
xrun; the dense set is listed, 61.6% to 69.1%). They answered question 10: fix the dip.
The fifty-sixth change glides WOBBLE's delay and plugin FLANGE's dry side in from 0 and
back out (OFF to WOBBLE -4.4 dB, was -15.8; row 19.12 has no hole). Phase B of the plan
(C7 to C10) is the fifty-seventh change and Phase C (C11, C12) the fifty-eighth, both Lua
only, deployed and loaded on the device but not walked. The user asked to merge them on
2026-11-20, and they are on `main`. Phase D (Relay, C13) is the fifty-ninth change: the user said yes on 2026-11-20, and it is on `main` and on the device, with the sixtieth change (motion from any page, MIDI faders, the control page). Phase E (section 6) is people: its sheets and its tool are ready (doc/walkthrough.md, test/device/session.py), and it waits for a first-time player and the user's set. The
Exquis driver (47th) and PRESS (52nd) are committed and on `main`, never run with their
hardware. The tests are ready for an Exquis (63rd): when one is on the norns, run
`exquis.py status`, `sweep` and `watch`, then stage 20. Another session can share this checkout: stage only your own hunks.

**What is pending on the device** (doc/plan.md, Phase 0): the plugin, the costs, stage
19 and the frame clock are done (doc/measurements/2026-11-16/). Row 19.12 (breaks when
TYPE steps) has no break since the forty-second change. Row 19.27 passes on the supported set
(2026-11-20); the dense set is over the limit by design. WARP and PV dip
by about 27 dB at their own loop seam (doc/plan.md, Phase 0, item 8). Open too: the user's look at REVERB's squares (the
screens are in doc/measurements/2026-11-16/screens/), and why a silent CLOUD track costs
more than one that sounds.

**Heard.** On 2026-11-16 the user listened to four on the device, the thirty-sixth change
with the plugin (FourCloud included), and said "it sounds nice". That is a general
judgement, the first on four as a whole. The item-by-item session of doc/plan.md, Phase 2,
has not taken place, and the shipped presets have never been heard. The earlier judgement
is the user's on FourStretch, above.

**The walkthrough.** doc/device-gate.md, stages 0 to 20, top to bottom. Stage 20 is the
Exquis: it needs one on the norns and has never run. Stage 19 is four's own work. It has not
passed since 2026-07-16 at `count: 63`, under mangler. On 2026-11-06
`test/device/gate.py` ran it at `count: 66` with no ears, which is NOT a pass
(doc/measurements/2026-11-06/README.md). It has not run on four. When it passes, write
the date and the count here. Costs, budgets and platform traps: doc/norns-platform.md.

**No presets ship.** `data/` holds the two MIDI maps only. The user's own preset set for
a live show, its tools and its test are private: they are not in this repo and must never
be pushed (the agent memory says where they are). The user wants example presets built on
freely usable ambient samples instead, and none are chosen yet. A new example set needs a
harness that loads every pset and scene through the offscreen script.

**The visuals link.** lib/mosc.lua sends the state as OSC to visuals/bridge.js, which
feeds Hydra (visuals/hydra.js). The bridge also serves a control page
(`/control`, visuals/control.html) whose moves go back to the norns as `/four/set`,
`/four/norm` and `/four/press` (port 10111). mosc's ALLOW filters `/four/`; the norns's own
`/param/` path stays open to the network, so ALLOW is not a wall. It ran with mangler on the device (the 110th and 111th
changes). No run with the `/four/` addresses is on record.

**Before four.** mangler went to its 114th change at `count: 66`. `full-review` was
merged into `main` on 2026-10-23. mangler2 then forked from mangler and became four.
doc/changelog.md holds that history.

**Next work:** doc/plan.md.

**Engine deploy ritual (every time the .sc changes, no exceptions):**
1. replace the file, and check it on disk with a REPL grep
2. SYSTEM > RESTART (sclang only recompiles at startup; a script reload is NOT enough)
3. load the script and check `Engine.register_commands; count: 198` in maiden. A wrong
   count means an old engine is still live. An arity change on an existing command does
   NOT move the count. test/test_control.lua parses the command set and fails if the
   source no longer adds up to 198. `rec_track` took a second argument in the
   forty-ninth change and a third (the take's source) in the fifty-ninth: the script
   reads `engine.commands.rec_track.fmt` (`iii`) and says so when the engine is older.

Lua-only changes skip all this: save and reload the script.

---

## Documents: current, reference, historical

Current. Keep these true to the code:
- CLAUDE.md (this file). README.md, the short page for players, and doc/manual.md, the
  full guide with every page's pictures.
- doc/plan.md: the next work. doc/changelog.md: every change, oldest first.
- doc/walkthrough.md: Phase E's sheets (the card, the observer's sheet, the listening
  script). test/device/session.py measures the session.
- doc/device-gate.md: the walkthrough. It was written for mangler, and its top says what
  that means for four.
- doc/controls.md: GENERATED, never edit by hand.
- doc/octatrack-midi.md, data/README.md, ugen/README.md, visuals/README.md.

Design references. Partly built, and each one says what is built:
- doc/signature-workflow.md (the loop: record four parts, bend them, keep the sound,
  fade back to it. Changes C1 to C13 in phases A to E) and doc/idea-relay.md (Relay, its
  Phase D).
- doc/space-plan.md (SPACE: the delay, the room, the sends, the screen).
- doc/dsp-plan.md (the voices and the effects, by the math).
- doc/engine-map.md (why the engine is shaped as it is, written for mangler's engine).
- doc/norns-platform.md (what the platform costs, measured with mangler).
- doc/measurements/: dated records from the device.

Historical. Kept for their reasoning, and each one has a note at its top:
- doc/spec.md (mangler's spec, S0 to S23). The first plan, CLAUDE_PLAN.md, was deleted
  in the thirty-ninth change; git history keeps it.
- doc/redesign.md (mangler's screen redesign), doc/tracks-plan.md (decks as tracks).
- doc/layers.md and `data/layers/` (the layer decks, removed).
- doc/workflow-standalone.md, doc/workflow-grid.md (mangler's walkthroughs).
- doc/ux-feedback.md is the user's feedback of July 2026. New feedback goes at its end.

---

## What four is

A performance-first **stereo sample-mangling instrument** for external line-level gear
(synth, drum machine, anything line-level). Built for norns **shield XL on Raspberry Pi 4**,
played with **3 keys + 3 encoders**. Everything is reachable without a grid. An
**optional grid** (monome, a Launchpad Mini MK3 through its own colour driver, or other
launchpad-style MIDI grids via midigrid) adds a pad surface. No arc.
It records live stereo input on four tracks
and mangles it with: multiple **time-stretch** algorithms (pitch-independent), **granular**
clouds, **tape-like** varispeed/looping, a **playback window** (slice start/stop), a
**filter** (LP/HP/BP) and two **effect** slots on each track, and a shared **delay** and
**reverb** that the tracks send into.
**Every parameter is MIDI-mappable.**

Architecture: softcut (a separate audio core, nearly free) does everything it can (the
tape). scsynth does only what softcut cannot (granular, time-stretch,
the filters, the effects, delay and reverb). Each track's voice is a **mode switch**
(GRAIN, WARP, PV, PLAY, CLOUD): one track never runs two modes at once, except while a
voice change crosses over (0.17 s into WARP, 0.36 s into CLOUD, one track at a time). A
Pi 4 has one scsynth core, and it xruns past about 60%, so four tracks share that budget.

---

## The four hard invariants

1. **One engine file only.** A second `Engine_Four` class anywhere under `~/dust/code/`
   makes *every* norns script hang forever on "LOADING" (SuperCollider refuses to compile a
   duplicate class). Ship exactly one `lib/Engine_Four.sc`. Deploy with `rsync --delete`
   so an old copy can never linger on the device.

2. **Name consistency — change these four together, always:**
   | thing            | value                       |
   |------------------|-----------------------------|
   | SC class         | `Engine_Four`               |
   | SC file          | `lib/Engine_Four.sc`        |
   | Lua engine name  | `engine.name = 'Four'`      (norns prepends `Engine_`) |
   | SynthDef names   | namespaced, e.g. `\four_*`    |

3. **No SuperCollider compiler in this dev environment.** The only static check available is
   `luac -p` (Lua syntax). The local luac is 5.5 and norns runs Lua 5.3, so a clean parse
   is necessary, not sufficient: 5.5 accepts syntax 5.3 rejects. SC correctness is **only**
   verifiable on hardware.
   Therefore every stage is **gated on-device** before the next one is written. Never dump
   untested SC in bulk.

4. **Every controllable value is a real param; params are the single source of truth.**
   Keys, encoders, and MIDI all drive `params:*`. This is also how MIDI works (see below).
   A key's release is routed to the def resolved at its press (`key_state`), and a grid
   pad's release to the surface that took its press, so a release always closes the
   gesture it began.

---

## MIDI is native — do not hand-roll it

norns auto-maps **every** parameter added via `params:add_control / add_taper / add_number /
add_option / add_binary` to MIDI-learn from the PARAMS menu, persisting it per-script in a
**PMAP** file (`data/four/four.pmap`). `add_separator / add_group / add_trigger /
add_text` are **not** mappable.

⇒ The rule that gives "MIDI for every parameter" for free:
- Make every knob a `add_control`/`add_taper`.
- Make every toggle (freeze, reverse, rec-arm) a `add_binary` or `add_option` — never a raw
  Lua boolean — so it is both key-toggleable and MIDI-mappable.
- Keys call `params:set/delta`; encoders call `params:delta`; MIDI maps to the same IDs.
  One source of truth, three drivers.

---

## norns Lua API gotchas (learned on hardware)

- **`params:get_name(i)` takes a numeric index ONLY** (`self.params[i]`, no id lookup).
  With a string id it indexes nil and throws. Use `params:lookup_param(id).name`.
  (`params:string / get / set / delta` DO accept string ids.)
- **An error inside `redraw()` shows as a frozen/black screen, not a crash.** The script
  still prints `<ok>`; the display just never reaches `screen.update()`. If the screen is
  stuck on "loading" or goes black, scroll maiden below `<ok>` for the Lua traceback.
- **`params:add_group` id must not collide with any param id.** Use the 3-arg form with a
  distinct id: `params:add_group("grp_mix", "mix", n)`.
- **System param ids are reserved — the system shares the script paramset.** Adding a param
  with a system id (e.g. `tape_level`, owned by the TAPE deck) prints "refusing to clobber"
  and the param is silently NOT added — which also desyncs the surrounding `add_group`
  count. Reserved (verified on hardware): `output_level, input_level, monitor_level,
  engine_level, softcut_level, tape_level, monitor_mode, headphone_gain, reverb,
  compressor, comp_*, cut_input_*, clock_*, link_*`, and the system reverb's own `rev_*`
  ids (`rev_eng_input`, `rev_return_level`, `rev_pre_delay`, ...; four's `rev_mix`,
  `rev_decay` and siblings do not collide). four uses `cut_level` for the softcut
  path's level.
- **The ~60 system params (LEVELS/REVERB/COMPRESSOR/SOFTCUT/CLOCK) appearing in
  `params.count` is normal** — they are not leftovers from another script.
- **`context.in_b` is an ARRAY of two mono busses** (`in_b[0].index`, `in_b[1].index`);
  `out_b` is one stereo bus. `context.in_b.index` throws doesNotUnderstand inside alloc's
  fork → the doneCallback never fires → matron waits forever → the script's `init()` is
  never called → stuck on "loading" with NO error in the matron tab.
- **SC errors print in maiden's SC tab, not the matron tab.** A script hanging on
  "loading" with a clean matron log means: check the SC tab. The load chain is:
  script file runs → `engine.load(name, Script.init)` → SC alloc → doneCallback →
  `init()` → `norns.init_done` → screen handoff. A silent break before `init()` is
  almost always the engine failing in alloc.
- **norns calls `midi.remove(dev)` BEFORE it deletes `dev` from `midi.devices`** (read in
  lua/core/midi.lua). A search of the devices inside that callback still finds the device
  that is leaving, so `Mgrid.hotplug` is handed it and skips it.
- **`sudo systemctl restart norns.target` restarts NOTHING.** The target only
  Requires the services, so they keep running with the old class library. For a
  RESTART over SSH use `sudo systemctl restart norns-jack norns-crone norns-sclang
  norns-matron`, then check that the sclang log shows a fresh `compile done`.
  Load the script only after the log also shows the `engines: [...]` line: a
  load sent between the two hung on the engine for good (2026-11-12), and only
  another restart cleared it.
- **Editing a `.sc` file requires SYSTEM > RESTART** (sclang must recompile the class
  library); reloading the script is not enough.
- **midi dispatch is dual-path: norns fires BOTH `midi.devices[id].event` (device
  level) and `midi.vports[port].event` (vport level) for the same message.** midigrid
  binds device-level; four's note input binds vport-level on all 16 slots — so a
  grid controller's pad note-ons reach both handlers unless filtered. four's
  `is_grid_vport()` skips the vport whose device midigrid claimed (compared by
  identity and by name against `gg.device`). Symptom when this breaks: every pad
  press also slams `pitch` to an extreme (raw launchpad note numbers are far from
  root 60 and clamp to the 0.25–4 spec edges).
- **A large system time jump makes sclang flood matron.** If sclang boots on a stale
  clock and Wi-Fi then corrects the time, its polls try to catch up. On 2026-11-06, a
  70-day jump gave about 24,000 `/poll/value` messages per second instead of 105. sclang
  took about 94% of a core, matron about 90%, and the sclang REPL did not answer. After a
  jump, restart and then measure. A device of our own needs a battery clock or must wait
  for the time sync.
- **The last SSH logout deletes the JACK sockets.** When user `we` logs out, systemd's
  `RemoveIPC` default empties `/dev/shm`. Running audio continues, but `jack_lsp` and
  `jack_connect` then fail with "server is not running". A restart repairs them. For JACK
  work, open one SSH session, restart, and keep that session open to the end of the work.
- **`clock.lua:62 bad argument #1 to 'resume' (thread expected)`** is a system-level race
  (a clock timer fires for an already-dead coroutine, often on script reload) and wedges
  clock state until restart. It is not specific to one script, but: keep four's clock
  usage minimal, always `clock.cancel` in `cleanup`, and when this error appears, restart
  before drawing conclusions about whichever script loaded last.

---

## Lessons and deliberate decisions

Each line was learned the hard way; the change log has the story.

**Rules**
- Never install `.sc` class files under `dust/code` outside an `ignore/` folder. A
  duplicate class (for example a second mi-UGens clone) hangs every script on LOADING.
- Plugin UGens: resolve the class with `"Name".asSymbol.asClass` at SynthDef build time,
  wrap the graph in `try`, and pass POSITIONAL args (keyword args do not survive perform
  on a var-held class). A missing plugin must cost sound, never the instrument.
- Do NOT move the grain envelope buffer fill after `s.sync`.
- Do not build on an engine command that has never been heard on the device
  (`note_one_shot` looked right and was silent).
- Param ids are never renamed: PSETs and PMAPs name params by id. When a param is
  deleted, grep `data/` and the pmap for its id; norns drops unknown ids silently.
- Every new param is CLASSIFIED: in `SCENE_RECALL_IDS` or `SCENE_EXCLUDE`, in `MOTION_IDS`
  or `MOTION_EXCLUDE`; a `*_start`/`*_end` pair joins `EDGE_PAIRS` and `FINE_IDS`; an
  x-rate joins `RATE_IDS`; an encoder target gets a `SHORT` word. Every `add_group` count
  must match. test_control enforces all of it.
- `MOTION_IDS` is append-only: an id whose param is deleted stays in its place and joins
  `MOTION_TOMBSTONES`. test_control lets only a tombstone name a missing param.
- Every new audio source must join `purity()` (the ◇ mark has lied three times).
- A SynthDef argument's name sets its rate: `t_` makes a trigger control that falls to 0
  after one block, `a_` an audio-rate control, `i_` a fixed one. io's bus arguments
  `t_dly` and `t_rev` read bus 0 after the first block, so tracks 2 to 4 never reached
  the delay or the reverb until the fortieth change. test_control rejects the prefixes.
- A delay line born under a playing sound fills from silence: fade its INPUT in (10 ms).
  An empty line catches the sound mid-wave, and the edge comes out one line length later
  as a step (the forty-second change). Score both channels: an effect's sides differ.
- The two scsynths differ: 3.14.1 on the Mac, 3.13.0-dev on the norns. The norns holds
  `Line.kr`'s first step for its whole first block (a fade of 10 ms starts with a jump
  of 14%), and the Mac starts it at 0. Fade with `EnvGen` or `Line.ar`. The Mac frees a
  released synth one control step short of 0 (a straight 20 ms fade ends 6.7% up, a
  50 ms S curve 0.05%), and the norns runs the release to its end.
- The offline check on the Mac is not the device's scsynth. `test/device/norns_nrt.sh`
  renders a probe's scores with the norns's own scsynth, offline, in seconds. Run it
  before the RESTART for any change that the first block of a synth can decide.
- On the norns every UGen counts. A control-rate operator costs about 0.01% of the
  scsynth thread for each synth that holds it: nine more in FLANGE and four in ECHO took
  the dense set from 62.4% to 63.5% (the forty-fifth change, first version). When a law
  changes, count the def's UGens before and after (probe7 prints them, check_dsp.sh
  holds the counts), and write the law so that the count does not grow.
- An effect that is quieter than the dry sound reads as weak. A straight crossfade of a
  sound and its effect is 3 dB down at its middle, and more when the effect is weak on
  that material (RESON was 7 dB under OFF on an off-note tone). Cross at equal power, or
  keep the dry sound whole up to the middle. Measure the level of every effect against
  OFF at the amount it starts with (gate row 19.11, probe7).
- A write that fades out outlives the command that stopped it. io's rec and regen
  gates ramp over 10 ms, so a buffer zeroed while one of them runs is written to after
  the zero. The engine's `clear` zeroes again 60 ms later, behind a counter that a file,
  a new take or another clear steps (`clearWait`, `bufGen`).
- When a command's arity changes, the script reads the command's format
  (`engine.commands.<name>.fmt`) and keeps the old law for an old engine. The count
  cannot tell the two apart, and norns only warns about a wrong number of arguments.
- A trigger in a SynthDef without a `t_` name: step a plain control by 1 and read the
  step with `HPZ1.kr` (io's `rec_pass`). It gives one block above 0, on both scsynths,
  and nothing at the synth's start.
- A synth's UGens are built at its first block, after the whole bundle that made it. A
  control set back in that bundle is never seen. For a value that holds for the first
  block only, use `Trig.kr(value, 0)` (a head's first place in `winRead`).
  `Impulse.kr(0) * value` and a trigger-rate control give a Phasor the wrong place on
  the norns.
- What sclang reads from the server is already old when the server acts on it, by
  another time at each call (not measured). Two sounds that must add up in step are
  placed on the server: the new drone reads the phase bus itself in its first block. A
  score has no travel time, so the offline bench cannot see this fault. Row 19.33 found
  it on the device: PLAY into PV dipped by 18.5 dB over a tone.
- A stage of zero length in an EnvGen still takes a block, so a release behind it
  starts late. A cross into PLAY on the drones' own start curve (fast at first) read
  +1.6 dB on the Mac and +3.2 dB on the norns's scsynth. Cross two sounds that are in
  step on a straight line, where a late block is 7%: +0.5 and +1.2 dB.
- WARP and PV dip at their own loop seam (found with row 19.33 on a take of 4 s). A
  device row that reads a level waits until the head is past the seam (`after_seam`).
- A knob in a SynthDef is `gl.(value, value_t)`, never a bare `.lag`: every write sends
  the glide time with the value (`gset`). A new knob joins `glideKeys` in the engine,
  and its def must not grow (VarLag with warp 1 is one UGen: without the warp it is an
  EnvGen and two more). A lag shorter than a frame makes a modulated knob stand still.
- lib/mpages.lua is at Lua's limit of 200 locals in its main chunk. A new value there
  is a field of `M`, not a local (the error is at load: "too many local variables").
- A level read off a recording has a fine ripple that a render has not. Low-pass it
  (40 Hz in an_fade.py) before a measure that counts stands: row 19.34 read 26% still
  on a knob that was moving, and 0.8% after.
- The engine's write head is polled once a frame. A poll that left before the head was
  reset can arrive after it. The head moves at one second a second, so for three frames
  a poll further than the time since the reset allows is not believed (`ctx.head_poll`).
  And the end of a pass is the last poll plus the time since it: the window was 36 to
  49 ms short of what was played.
- softcut reports a head every 25 ms, and a report from the place the head left can
  arrive after `softcut.position`. On the norns 4 of 40 passes that closed 10 or 20 ms
  after a jump read the old place. After a jump, believe a report only when it is near
  the place the head went to (`Mdeck.jump`, `Mdeck.trust`).
- A loop pedal's pass starts where its loop can live. A softcut loop cannot cross the
  end of its region, and a head that runs on while nothing records is anywhere in it.
  The tape began its pass there, and one pass in seven of 8 s kept the whole 60 s
  (the forty-eighth change).
- A page that records says what a pass will record, and says when a pass hears nothing.
  The tape recorded the line input alone, the knob for its source was under K1+E3, and
  a pass over playing tracks came back empty with `EMPTY - K2 REC` (the forty-sixth
  change). The user read it as "the tape is not working".
- A guard added to one of two sibling paths makes the other one a bug with a witness.
  When a fix names a limitation in ANOTHER module, that is an unfixed bug, not a note.
- A release belongs to whatever took the press: `key_state` routes a key release to the
  def resolved at the press, the grid routes a workspace release to the surface that
  took it, and a def must not look its target up again at release.
- Note RELEASES are never gated (keys_enable, the MIDI channel, the menu): a gated
  release strands a polyphonic voice forever. Key voice ids on the physical key or pad.
- Every write of a start/end pair goes through `Mdeck.set_pair` (the widening edge
  first). A crossed pair is a region that is neither the old one nor the new one, and
  the 100ms loop floor turns it into a jump of the head.
- Anything that replaces the take buffer goes through `buffer_replaced()` (and so bumps
  `take_gen`); a deck replacement bumps `d.gen`. Async work checks the generation before
  it lands.
- Capture by POLLING, not by wrapping calls: on the device an encoder goes through
  `paramset:delta`, which never re-enters a wrapped `set` (the sim does not model this).
- A format change is a change to everyone who computes a SIZE from it (`TAKE_BYTES`).
- A busy guard covers every reader of what it protects. `take_to_wav` holds `export_clock`
  until `done` returns, because the scans read the shared dump after it. A background job
  never refuses a performer's: a dump asked for during the strip repaint waits for it.
- softcut's rec flag stays ON on every deck; rec 0 and pre 1 are the gate. With the flag
  off, the write index does not follow the read head, and a pass lands somewhere else.
  Its rec and pre ramp never lands exactly, so `Mdeck.settle_rec` ends every ramp.
- Under JACK, a server's `avgCPU` is the load of the whole cycle (`jack_cpu_load`), not
  that server's. Read one server's cost from its thread in `top -H`.
- A second scsynth is not a dependable gain: see doc/norns-platform.md before trying again.
- `include` has no module cache: a module that needs another module's state is handed
  the instance through `init` (mtape receives Mdeck), never includes it again.
- Moving code into a module turns an assignment to a former upvalue into a write to a
  global, silently. A local referenced above its declaration also reads as a global.
- A performance page must prove it worked: every action says what it did (`say`,
  `take_say`), including the "nothing moved" case.
- Screen text: measure with `text_w` first; 124px is the centred limit. `ptext`'s y is
  the TOP row of the 1x font (y..y+4).
- Tests that read params over ticks must first silence the background movers (orbit,
  motion, a latched peek).
- The Exquis stand-in and the driver come from one reading of one specification. The
  stand-in proves that the driver is consistent (frames, the mirror of the grid, the
  fold), not that an Exquis agrees. Only stage 20 on the device can say that.
- Lua that a device tool sends to the REPL lives in one table in test/device/norns.py
  (`EXQUIS_LUA`), and test_exquis.lua runs it in the offscreen script. A REPL line is
  one line: no comment in it. The script logs to the same REPL, so a tool's answer is
  printed behind a mark (`@exq `) and read from the marked line only: `num()` takes the
  first number in the text, which can be a log line's.

**Deliberate decisions: do not "fix" these unasked**
- The tape keeps its own loop-pedal law; folding it onto `Mdeck.arm_loop`/`close_loop`
  waits for the device gate. The remaining differences are listed in lib/mtape.lua.
- `note_one_shot` stays: removing it moves the command count.
- `ctx.record_stop` / `ctx.record_limit` stay for the `foundry` merge.
- The two resamplers (`main` vs `foundry`) stay separate.
- Freeing the reverb and delay synths at mix 0 cuts their tails: the CPU win is the point.
  (Since the forty-fourth change the free comes 0.1 s after the mix reaches 0, so it
  cuts nothing that still sounds.)
- The DELAY page's bouncing echoes are the keeper; the top-down REVERB room and the
  8-boxes-on-the-wave PADS were rejected. Do not restore them unasked.
- NORMALIZE (a fourth buffer writer) waits until rec, regen and erode are heard on
  hardware.
- `morph(1)` is not `recall(B)` by design (holds, routing, writers and the voice cap do
  not morph); the morph runs at a fixed 15 fps; UNDO does not stop modulators.
- The shipped presets have never been heard: their balances are reasoned, not eared.

---

## Workflow

```sh
# EVERYTHING below in one command, with one verdict: syntax, the eight harnesses,
# the three that load the script again with an Exquis attached (KEYS, then PADS),
# and source == single-file build across all render variants. About two minutes. With LUA53 set to a
# Lua 5.3 `lua` (norns' version: build lua-5.3.6 from lua.org with `make macosx`)
# it runs on 5.3, which is the only check of what the device actually accepts.
LUA53=/path/to/lua-5.3.6/src/lua lua test/check.lua

# static check alone (local luac is 5.5; norns runs 5.3, so without LUA53 this is
# necessary, not sufficient)
luac -p four.lua lib/*.lua

# render every page to PGM with NO hardware (test/uisim stubs norns and runs the REAL
# redraw code). eyeball these before deploying a screen change: a redraw error on the
# device is a silent black screen
lua test/uisim/render_pages.lua four.lua /tmp/shots base           # all pages + states
lua test/uisim/render_pages.lua four.lua /tmp/shots empty empty # empty-buffer states
python3 test/uisim/pgm2png.py /tmp/shots/base_01_TAKE.pgm take.png 4

# the harnesses. the render suite proves the instrument DRAWS; these drive it. Each
# prints its assertion count and exits non-zero on any failure.
lua test/test_control.lua   # encoders, keys, grid, STOP, the erase arc, scenes, motion,
                             # the classification checks, group counts, the engine
                             # command count, preset values, dist freshness
lua test/test_deck.lua      # the softcut loop decks and the tape's delegated mechanics
lua test/test_wav.lua       # the wav layer: resampling, headers, transients, onsets
lua test/test_launchpad.lua # the Mini MK3 driver: geometry, palette, SysEx
lua test/test_exquis.lua    # the Exquis driver: the fold onto hexagons, SysEx, modes
lua test/test_purity.lua    # the ◇ mark: every source, hold and writer kills it
lua test/test_screen.lua    # the screen's promises, read off the pixels: header
                             # flags, the erase arc's room, the GRAIN cloud
lua test/test_plugin.lua    # the plugin installer (lib/mplugin.lua), over real files

# any harness or render that loads the script, with an Exquis stand-in attached
# (test/uisim/env.lua). keys: beside the grid. pads: every grid press of a cell that
# the Exquis carries is made on its pads. The stand-in checks each frame it is sent
# and holds its LEDs to the grid's; the harness's report fails on a fault.
FOUR_EXQUIS=pads lua test/test_control.lua

# single-file build: inlines lib/*.lua into dist/four_single.lua. GENERATED, never
# edit it; rebuild after any Lua change (test_control fails on a stale one)
lua test/amalgamate.lua

# the control map: doc/controls.md is GENERATED from ENC_MAP/VOICE_FACE/KEYS; rerun
# after changing a page's knobs or keys (test_control fails on a stale one)
lua test/controls.lua

# the DSP, offline on the Mac, after ANY engine or ugen change: compiles the real
# engine (count 198), renders the review probes, one verdict. About 30 s. KNOWN rows
# are open faults that fail only when they get worse. FOUR_PLUGIN_DIR (a folder with
# FourStretch.scx from ugen/build_mac.sh) adds the plugin build.
# The work folder must be OUTSIDE the repo: it holds a stand-in CroneEngine .sc file,
# and the deploy rsync would copy it to the norns (invariant 1). The scripts refuse it.
FOUR_PLUGIN_DIR=<plugin folder> test/dsp/check_dsp.sh <work folder outside the repo>

# the plugin's own proof and its build on the Mac (ugen/README.md; every build of
# ugen/ needs -Iugen/vendor/eurorack). On the norns: ugen/build_norns.sh
clang++ -O2 -std=c++17 -Iugen/vendor/eurorack -o /tmp/test_core ugen/test_core.cpp && /tmp/test_core
ugen/build_mac.sh <plugin folder>

# on a connected device: run the walkthrough and the measurements (doc/norns-platform.md
# says how, and why one SSH session must stay open)
python3 test/device/gate.py 2 4:4.10,4.14
python3 test/device/measure.py states voices

# with an Exquis on the norns: stage 20, and the three things the driver guesses
# (its name, its encoders' step, the order of its pad ids)
python3 test/device/gate.py 20
python3 test/device/exquis.py status
python3 test/device/exquis.py sweep
python3 test/device/exquis.py watch 30

# on a connected device: render an offline probe's scores with the norns's OWN scsynth
# (3.13, where the Mac has 3.14: they differ), then score the files as usual
test/device/norns_nrt.sh <probe folder> <out folder> p6 walk:2 pairs:100 more:4
python3 test/dsp/review/an_probe6.py <out folder> p6

# deploy (the repo IS the script; --delete kills stale engine copies). Keep
# --exclude='.claude': agent worktrees live in .claude/worktrees, each with its own
# lib/Engine_Four.sc, and a second copy on the norns hangs every script (invariant 1).
# ignore/ goes too, on purpose: it carries the shipped plugin binaries, and norns
# compiles nothing under a folder named ignore.
rsync -av --delete --exclude='.git' --exclude='.claude' ./ <norns>:~/dust/code/four/
```

To prove a refactor changes nothing: render all five variants (base, empty, grain,
filter, track2) before and after and byte-compare the PGMs, then render `dist/four_single.lua`
the same way. Compare renders made by the SAME interpreter: `math.random` differs between
Lua 5.3 and 5.5, so the orbit's shot differs across them by design.

**Screen rules (hold these on every page):**
- Brightness encodes audibility: a thing that is not sounding lies flat and dim (mode
  OFF, STOP, a deck thrown away by the MIX crossfade, a dormant FX page at mix 0).
- An empty buffer is an invitation, always in the same voice: "EMPTY - K2 REC".
- The header: the four track cells, the page title, the ◇ purity mark, CPU while the
  load is near the limit (steady), the write flags (T and M), the hold flags, and
  uniform page dots top-right. The cell of the track that
  records and the dots of T and M are the ONLY fast blink.
- The footer: four quiet words, K2 K3 | E2 E3. A turning knob brightens its word and
  swells its value in a framed 2x box above the footer; selector pages (SLICE, LANE,
  SLOT) read their value at rest. E1 pops the page name big for a moment.
- VOICE draws the active mode's own texture (one unbroken wave, grains, warp windows,
  spectral columns).
- The redraw path allocates nothing per frame.
