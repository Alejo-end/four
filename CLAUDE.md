# CLAUDE.md — four

Agent manual for **four** (it was mangler, then mangler2), a norns live stereo
sample-mangling instrument with four engine tracks. Read this first: the status, the
hard rules, and the lessons the project paid for. The per-change history is in
**doc/changelog.md** (oldest first; the newest entry is at the end). Keep the status
block current, and add a change-log entry for every change.

---

## STATUS (2026-11-15)

This block is the one record of the device, the fingerprint and what nobody has heard.
doc/plan.md and the README point here. Keep it current. When you change it, date it.

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
- Each track has a voice (OFF GRAIN WARP PV PLAY CLOUD), a window, a filter, COLOR
  (drive, crush), two EFFECT slots in series and its sends to the delay and the reverb.
  The effect types are OFF CHORUS FLANGE WOBBLE RESON RING ECHO, each with an amount and
  a rate. The second slot's type has no key yet: it is in PARAMS.
- GRAIN is a granulator that reads the take: stereo grain pairs, spray, and timing from
  regular to Poisson. A cloud holds 48 pairs with the plugin and 32 without. CLOUD is
  MiClouds.
- Four modulators, each on any track.
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
- The tape is the one softcut deck, on the deck law in lib/mdeck.lua. The layer decks
  are gone. `MOTION_IDS` keeps their fourteen ids in place as tombstones
  (`MOTION_TOMBSTONES`). `data/layers/` and doc/layers.md stay, labelled as old.

**FourStretch, our own plugin.** `ugen/` holds our UGens (FourPV, FourWarp, FourRead,
FourGrain, FourDelay, FourRoom, FourBBD, FourTanh) and their proof `ugen/test_core.cpp`,
in plain C++. `lib/FourStretch.sc` is their ONLY class file: the binary goes alone into
`~/.local/share/SuperCollider/Extensions/FourStretch/`, never with a second class file.
Build it on the norns with `-DFOUR_FFTW` (ugen/README.md). Install the binary BEFORE an
engine that names a new UGen. With the binary the log says `four: FourStretch on`. Without
it the engine builds the stock voices and effects.

**SuperCollider on the Mac (2026-11-13).** 3.14.1, without sc3-plugins or mi-UGens, so
DFM1, JPverb and MiClouds take their fallbacks there. `test/dsp/run_engine.sh` compiles the
real engine with a stand-in for CroneEngine, prints the command count and renders the
SynthDefs offline. `an_engine.py` measures them. `test/dsp/check_dsp.sh` runs the whole
offline DSP check with one verdict (see the workflow). Invariant 3 below is out of date for
stock UGens. The DSP plan and its measurements: doc/dsp-plan.md.

**On the device.** A norns shield on a Pi 4: `norns.local`, user `we`.
- It runs the code of the sixteenth change at `count: 197`, with the plugin of that day.
  The seventeenth to the nineteenth, the twenty-second, the twenty-third and the
  twenty-seventh changes are NOT on it.
- `dust/code/mangler` and `dust/code/mangler2` are deleted. `dust/data/mangler` and
  `dust/data/mangler2` stay as backups.
- `dust/data/four` holds older presets. The set rebuilt in `data/` (the thirteenth and
  nineteenth changes) is not there: `test/deploy_set.sh` overwrites slots 1 to 12, and
  the user has not said yes. A test that writes a PSET on the device uses slot 90.

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
| 17th: THE BUCKET BRIGADE | NO | no |
| 18th: REVERB's four squares (Lua) | NO | no |
| 19th: the sends, `count: 198` | NO | no |
| 20th: the README and its pictures | documents only | |
| 21st: the documents agree with the code | documents only | |
| 22nd: the first grain, the erosion head, a lighter FourBBD (engine and plugin) | NO | no |
| 23rd: the screen review (Lua) | NO | |
| 24th: gate.py follows four (test tools) | not run there yet | |
| 25th: stage 19 of the gate (documents, test tools) | not run there yet | |
| 26th: the offline DSP check (Mac only) | not for the device | |
| 27th: the frame clock, the LFO rate cap (Lua), the staircase probe | NO | |
| 28th: the pre-merge review's fixes (test tools, documents) | not run there yet | |

The thirteenth change's entry says that nothing ran on the device. The fifteenth
change's opening, in the same `four.lua`, drew there, so its Lua is on the device. Nobody
walked the twelve pages there yet.

Measured on the device (doc/measurements/2026-11-12/ and 2026-11-13/). The scsynth thread
xruns past about 60%.
- Four PLAY tracks take 25.2% (twelfth change). With preset 1's reverb and delay on:
  four PLAY 17.2%, four PV 28.6%, four GRAIN 19.1% (sixteenth change). Four PV at pitch
  2 take 53.0%. The user's heaviest set takes 57.3%, with no xruns.
- A soak of 30 minutes (2026-11-12) ran near 40% at 58 to 60 °C, with no throttling. A
  preset loaded by hand gave 3 to 7 xruns (doc/plan.md, Phase 3).

**What is pending on the device** (doc/plan.md, Phase 0):
1. Build the plugin with `FourBBD` (its core changed again in the twenty-second change),
   and install it BEFORE the engine.
2. Deploy, RESTART, and read `count: 198`.
3. Measure the delay's cost. Make sure that silence costs nothing: the denormal repair is
   not confirmed there.

**Not heard.** No listening session for four took place yet. The one judgement on record
is the user's on FourStretch, above. The shipped presets have never been heard. The list
to listen to is doc/plan.md, Phase 2.

**The walkthrough.** doc/device-gate.md, stages 0 to 19, top to bottom. Stage 19 is
four's own work. It has not
passed since 2026-07-16 at `count: 63`, under mangler. On 2026-11-06
`test/device/gate.py` ran it at `count: 66` with no ears, which is NOT a pass
(doc/measurements/2026-11-06/README.md). It has not run on four. When it passes, write
the date and the count here. Costs, budgets and platform traps: doc/norns-platform.md.

**The album set.** `data/` holds twelve presets for one album: ten half-songs
walked in whole parts, and two album walks, ALBUM 1 and 2. `test/make_set.lua` builds
them and is the source of truth, with loops from `test/set_audio.py` and
`test/deploy_set.sh` to install them. Their mangler form was on the device on
2026-11-10 (loads, scenes, levels, CPU and temperature measured). Nobody judged them by
ear yet. After a listen, fix the table in make_set.lua and rebuild.

**The visuals link.** lib/mosc.lua sends the state as OSC to visuals/bridge.js, which
feeds Hydra (visuals/hydra.js). It ran with mangler on the device (the 110th and 111th
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
   source no longer adds up to 198.

Lua-only changes skip all this: save and reload the script.

---

## Documents: current, reference, historical

Current. Keep these true to the code:
- CLAUDE.md (this file) and README.md, the guide for players.
- doc/plan.md: the next work. doc/changelog.md: every change, oldest first.
- doc/device-gate.md: the walkthrough. It was written for mangler, and its top says what
  that means for four.
- doc/controls.md and doc/set-album.md: GENERATED, never edit by hand.
- doc/octatrack-midi.md, data/README.md, ugen/README.md, visuals/README.md.

Design references. Partly built, and each one says what is built:
- doc/space-plan.md (SPACE: the delay, the room, the sends, the screen).
- doc/dsp-plan.md (the voices and the effects, by the math).
- doc/engine-map.md (why the engine is shaped as it is, written for mangler's engine).
- doc/norns-platform.md (what the platform costs, measured with mangler).
- doc/measurements/: dated records from the device.

Historical. Kept for their reasoning, and each one has a note at its top:
- CLAUDE_PLAN.md (the first plan), doc/spec.md (mangler's spec, S0 to S23).
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
(GRAIN, WARP, PV, PLAY, CLOUD): one track never runs two modes at once. A Pi 4 has one
scsynth core, and it xruns past about 60%, so four tracks share that budget.

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

**Deliberate decisions: do not "fix" these unasked**
- The tape keeps its own loop-pedal law; folding it onto `Mdeck.arm_loop`/`close_loop`
  waits for the device gate. The remaining differences are listed in lib/mtape.lua.
- `note_one_shot` stays: removing it moves the command count.
- `ctx.record_stop` / `ctx.record_limit` stay for the `foundry` merge.
- The two resamplers (`main` vs `foundry`) stay separate.
- Freeing the reverb and delay synths at mix 0 cuts their tails: the CPU win is the point.
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
# EVERYTHING below in one command, with one verdict: syntax, the seven harnesses,
# and source == single-file build across all render variants. With LUA53 set to a
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
lua test/test_purity.lua    # the ◇ mark: every source, hold and writer kills it
lua test/test_screen.lua    # the screen's promises, read off the pixels: header
                             # flags, the erase arc's room, the GRAIN cloud
lua test/test_set.lua       # the album presets: every pset and scene loads

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

# on a connected device: run the walkthrough and the measurements (doc/norns-platform.md
# says how, and why one SSH session must stay open)
python3 test/device/gate.py 2 4:4.10,4.14
python3 test/device/measure.py states voices

# deploy (the repo IS the script; --delete kills stale engine copies)
rsync -av --delete --exclude='.git' ./ <norns>:~/dust/code/four/
```

To prove a refactor changes nothing: render all five variants (base, empty, grain,
filter, track2) before and after and byte-compare the PGMs, then render `dist/four_single.lua`
the same way. Compare renders made by the SAME interpreter: `math.random` differs between
Lua 5.3 and 5.5, so the orbit's shot differs across them by design.

**Screen rules (hold these on every page):**
- Brightness encodes audibility: a thing that is not sounding lies flat and dim (mode
  OFF, STOP, a deck thrown away by the MIX crossfade, a dormant FX page at mix 0).
- An empty buffer is an invitation, always in the same voice: "EMPTY - K2 REC".
- The header: the four track cells, the page title, the ◇ purity mark, the write flags
  (T and M), the hold flags, and uniform page dots top-right. The cell of the track that
  records and the dots of T and M are the ONLY fast blink.
- The footer: four quiet words, K2 K3 | E2 E3. A turning knob brightens its word and
  swells its value in a framed 2x box above the footer; selector pages (SLICE, LANE,
  SLOT) read their value at rest. E1 pops the page name big for a moment.
- VOICE draws the active mode's own texture (one unbroken wave, grains, warp windows,
  spectral columns).
- The redraw path allocates nothing per frame.
