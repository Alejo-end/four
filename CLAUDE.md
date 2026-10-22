# CLAUDE.md — mangler

Agent manual for **mangler**, a norns live stereo sample-mangling instrument. Read this
first: the status, the hard rules, and the lessons the project paid for. The per-change
history is in **doc/changelog.md** (oldest first; the newest entry is at the end). Keep
the status block current, and add a change-log entry for every change.

---

## STATUS

- **Last device-confirmed:** 2026-07-16 at `count: 63` (S21, S22 Phase A, the NU-1..4
  redesign, the 45th to 47th changes).
- **Unverified on hardware:** everything since the 48th change, engine and Lua. The engine
  has changed several times; after a RESTART maiden must read **`count: 65`**.
- **The one walkthrough:** doc/device-gate.md, stages 0 to 16, top to bottom. When it
  passes, update this block with the date and the count.
- **Latest change:** the 91st, the take undo (doc/changelog.md). Lua and
  tooling only. The 80th moved erosion into its own synth (ENGINE, no new command), so the
  count stays 65. Work lives on the `full-review` branch until it is merged.
- **Next work:** doc/plan.md (the engine batch for the device session, then the rest).

**Engine deploy ritual (every time the .sc changes, no exceptions):**
1. replace the file, and check it on disk with a REPL grep
2. SYSTEM > RESTART (sclang only recompiles at startup; a script reload is NOT enough)
3. load the script and check `Engine.register_commands; count: 65` in maiden. A wrong
   count means an old engine is still live. An arity change on an existing command does
   NOT move the count. tools/test_control.lua parses the command set and fails if the
   source no longer adds up to 65.

Lua-only changes skip all this: save and reload the script.

---

## What mangler is

A performance-first **stereo sample-mangling instrument** for external line-level gear
(synth, drum machine, anything line-level). Built for norns **shield XL on Raspberry Pi 4**,
played with **3 keys + 3 encoders** — everything reachable without a grid; an **optional
grid** (monome, a Launchpad Mini MK3 through its own colour driver, or other launchpad-style
MIDI grids via midigrid) adds a pad surface. No arc.
It records live stereo input
and mangles it with: multiple **time-stretch** algorithms (pitch-independent), **granular**
clouds, **tape-like** varispeed/looping, a **playback window** (slice start/stop), a
**filter** (LP/HP/BP), and an **FX** section (delay + reverb, each with its own dry/wet).
**Every parameter is MIDI-mappable.**

Architecture: softcut (a separate audio core, nearly free) does everything it can (the
tape, the layer decks); scsynth does only what softcut cannot (granular, time-stretch,
the filter, delay and reverb). GRAIN/WARP/PV/PLAY are a **mode switch** on a single SC
voice, never run together: a Pi 4 has one scsynth core, and it xruns past about 60%.

---

## The four hard invariants

1. **One engine file only.** A second `Engine_Mangler` class anywhere under `~/dust/code/`
   makes *every* norns script hang forever on "LOADING" (SuperCollider refuses to compile a
   duplicate class). Ship exactly one `lib/Engine_Mangler.sc`. Deploy with `rsync --delete`
   so an old copy can never linger on the device.

2. **Name consistency — change these four together, always:**
   | thing            | value                       |
   |------------------|-----------------------------|
   | SC class         | `Engine_Mangler`            |
   | SC file          | `lib/Engine_Mangler.sc`     |
   | Lua engine name  | `engine.name = 'Mangler'`   (norns prepends `Engine_`) |
   | SynthDef names   | namespaced, e.g. `\mangler_*` |

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
**PMAP** file (`data/mangler/mangler.pmap`). `add_separator / add_group / add_trigger /
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
  ids (`rev_eng_input`, `rev_return_level`, `rev_pre_delay`, ...; mangler's `rev_mix`,
  `rev_decay` and siblings do not collide). mangler uses `cut_level` for the softcut
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
- **Editing a `.sc` file requires SYSTEM > RESTART** (sclang must recompile the class
  library); reloading the script is not enough.
- **midi dispatch is dual-path: norns fires BOTH `midi.devices[id].event` (device
  level) and `midi.vports[port].event` (vport level) for the same message.** midigrid
  binds device-level; mangler's note input binds vport-level on all 16 slots — so a
  grid controller's pad note-ons reach both handlers unless filtered. mangler's
  `is_grid_vport()` skips the vport whose device midigrid claimed (compared by
  identity and by name against `gg.device`). Symptom when this breaks: every pad
  press also slams `pitch` to an extreme (raw launchpad note numbers are far from
  root 60 and clamp to the 0.25–4 spec edges).
- **`clock.lua:62 bad argument #1 to 'resume' (thread expected)`** is a system-level race
  (a clock timer fires for an already-dead coroutine, often on script reload) and wedges
  clock state until restart. It is not specific to one script, but: keep mangler's clock
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
  deleted, grep `presets/` and the pmap for its id; norns drops unknown ids silently.
- Every new param is CLASSIFIED: in `SCENE_RECALL_IDS` or `SCENE_EXCLUDE`, in `MOTION_IDS`
  or `MOTION_EXCLUDE`; a `*_start`/`*_end` pair joins `EDGE_PAIRS` and `FINE_IDS`; an
  x-rate joins `RATE_IDS`; an encoder target gets a `SHORT` word. Every `add_group` count
  must match. test_control enforces all of it.
- Every new audio source must join `purity()` (the ◇ mark has lied three times).
- A guard added to one of two sibling paths makes the other one a bug with a witness.
  When a fix names a limitation in ANOTHER module, that is an unfixed bug, not a note.
- A release belongs to whatever took the press: `key_state` routes a key release to the
  def resolved at the press, the grid routes a workspace release to the surface that
  took it, and a def must not look its target up again at release (`LAYER_KEYS`).
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
- `include` has no module cache: a module that needs another module's state is handed
  the instance through `init` (mtape receives Mdeck), never includes it again.
- Moving code into a module turns an assignment to a former upvalue into a write to a
  global, silently. A local referenced above its declaration also reads as a global.
- A performance page must prove it worked: every action says what it did (`say`,
  `layer_say`), including the "nothing moved" case.
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
- SNAP names two gestures (TAKE K3 fits the window; the layer loop quantize). A rename
  is a product decision.
- NORMALIZE (a fourth buffer writer) waits until rec, regen and erode are heard on
  hardware.
- `morph(1)` is not `recall(B)` by design (holds, routing, writers and the voice cap do
  not morph); the morph runs at a fixed 15 fps; UNDO does not stop modulators.
- The shipped presets have never been heard: their balances are reasoned, not eared.

---

## Workflow

```sh
# EVERYTHING below in one command, with one verdict: syntax, the five harnesses,
# and source == single-file build across all render variants. With LUA53 set to a
# Lua 5.3 `lua` (norns' version: build lua-5.3.6 from lua.org with `make macosx`)
# it runs on 5.3, which is the only check of what the device actually accepts.
LUA53=/path/to/lua-5.3.6/src/lua lua tools/check.lua

# static check alone (local luac is 5.5; norns runs 5.3, so without LUA53 this is
# necessary, not sufficient)
luac -p mangler.lua lib/*.lua

# render every page to PGM with NO hardware (tools/uisim stubs norns and runs the REAL
# redraw code). eyeball these before deploying a screen change: a redraw error on the
# device is a silent black screen
lua tools/uisim/render_pages.lua mangler.lua /tmp/shots base        # all pages + states
lua tools/uisim/render_pages.lua mangler.lua /tmp/shots empty empty # empty-buffer states
python3 tools/uisim/pgm2png.py /tmp/shots/base_01_TAKE.pgm take.png 4

# the harnesses. the render suite proves the instrument DRAWS; these drive it. Each
# prints its assertion count and exits non-zero on any failure.
lua tools/test_control.lua   # encoders, keys, grid, STOP, the erase arc, scenes, motion,
                             # the classification checks, group counts, the engine
                             # command count, preset values, dist freshness
lua tools/test_deck.lua      # the softcut loop decks and the tape's delegated mechanics
lua tools/test_wav.lua       # the wav layer: resampling, headers, transients, onsets
lua tools/test_launchpad.lua # the Mini MK3 driver: geometry, palette, SysEx
lua tools/test_purity.lua    # the ◇ mark: every source, hold and writer kills it

# single-file build: inlines lib/*.lua into dist/mangler_single.lua. GENERATED, never
# edit it; rebuild after any Lua change (test_control fails on a stale one)
lua tools/amalgamate.lua

# the control map: doc/controls.md is GENERATED from ENC_MAP/VOICE_FACE/KEYS; rerun
# after changing a page's knobs or keys (test_control fails on a stale one)
lua tools/controls.lua

# deploy (the repo IS the script; --delete kills stale engine copies)
rsync -av --delete --exclude='.git' ./ <norns>:~/dust/code/mangler/
```

To prove a refactor changes nothing: render all four variants (base, empty, grain,
filter) before and after and byte-compare the PGMs, then render `dist/mangler_single.lua`
the same way. Compare renders made by the SAME interpreter: `math.random` differs between
Lua 5.3 and 5.5, so the orbit's shot differs across them by design.

**Screen rules (hold these on every page):**
- Brightness encodes audibility: a thing that is not sounding lies flat and dim (mode
  OFF, STOP, a deck thrown away by the MIX crossfade, a dormant FX page at mix 0).
- An empty buffer is an invitation, always in the same voice: "EMPTY - K2 REC".
- The header: the page title, the ◇ purity mark, the write flags (R/T/M, the ONLY fast
  blink), the hold flags, and uniform page dots top-right.
- The footer: four quiet words, K2 K3 | E2 E3. A turning knob brightens its word and
  swells its value in a framed 2x box above the footer; selector pages (SLICE, LANE,
  SLOT, LAYER) read their value at rest. E1 pops the page name big for a moment.
- VOICE draws the active mode's own texture (one unbroken wave, grains, warp windows,
  spectral columns).
- The redraw path allocates nothing per frame.
