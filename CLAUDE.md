# CLAUDE.md — mangler

Agent manual for working on **mangler**, a norns live stereo sample-mangling instrument.
Read this first. It encodes the hard rules and the staged build order. Keep it current —
when a stage passes its on-device gate, move the **CURRENT STAGE** marker.

---

## CURRENT STAGE: **S4 — filter + delay + reverb, on-device gate pending**

S1 PASSED, S2 PASSED (stretch modes), S3 PASSED with UX iterations (tape looper:
one-button take workflow, K1+K3 clear). S4 adds the FX chain to the io synth's wet
path: LP/HP/BP filter, feedback delay (soft-clipped loop), FreeVerb — each FX with
its own dry/wet. Bring-up diagnostics (milestone prints, missing-poll warnings)
stay in — they cost nothing and have saved the day repeatedly.

Lua-only addition (untested on device): chromatic note input — MIDI note-ons set
`pitch` = 2^((note−root)/12), and a USB typing keyboard plays ableton-style
musical typing (A-row/W-row, Z/X octave) via `keyboard.code`. PARAMS > keys group
(enable / channel / root / octave / pitch quantize). No engine change,
fingerprint count unaffected.

Second Lua-only addition (untested on device): an optional **grid layer** — native
monome grid, or launchpad-family / APC mini via the **midigrid** library
(`include "midigrid/lib/midigrid"`, guarded by `util.file_exists` + `pcall`,
used only when no real grid holds grid vport 1). 8×8 layout: engine + tape
transport/mode toggles (rows 1–2), window and tape-loop slice pads with a
two-pad span gesture (rows 3–4), two piano octaves plus octave/reset/quantize
gap pads (rows 5–8). Every pad drives params. The grid controller's MIDI device
is filtered out of chromatic note input (`is_grid_vport`, see the dual-dispatch
gotcha below). Grid LEDs refresh on the existing 15fps clock, also while the
menu is open. No engine change, fingerprint count unaffected. On-device check:
pads toggle/light correctly, slice spans work, note pads retune, and a pad
press must NOT jump `pitch` to 0.25/4 (that means the note-input filter failed).

Third Lua-only addition (verified in tools/uisim renders, untested on device):
a screen polish pass — grouped page dots, alt-aware LEVEL faders (MON/HP),
FILTER/GRAIN top-right readouts, "EMPTY - K2 REC" on REC, the audibility rule
(see Workflow), and per-mode STRETCH textures. All draw-code only.

Fourth Lua-only change (verified pixel-identical in tools/uisim, untested on
device): mangler.lua is split into script-internal modules — lib/mfont,
lib/mparticles, lib/mtape, lib/minput, lib/mgrid, lib/mpages — loaded with
`include("lib/<name>")` and sharing one `ctx` table built in mangler.lua;
params stay the single source of truth. These are plain Lua modules, NOT
engines (the one-engine-file invariant is untouched), and at lib/ depth they
don't appear in norns SELECT. The seeded render suite matches the pre-split
output byte-for-byte and the bench shows no cost (0.076 ms/tick, ~0 garbage).

Fifth Lua-only change (renders verified, untested on device): performance +
depth pass. The UI hot path is now allocation-free (byte-table font
rendering, a pooled 32-slot particle system, static layout tables — ~0 KB
garbage/tick, ~19% faster, proven pixel-identical at the time). The GRAIN
cloud became a stereo-field plot (y = per-grain pan mirroring the engine's
clip law, dot size = grain size, saturation = density). Navigation: K1+E1
jumps between the dot families. Truth additions: grid row 3 glows the engine
write head while recording, REC parks OVR% top-right when overdubbing,
warp_rand shakes the WARP ghost (still at 0). README carries a rendered page
gallery (doc/ui/, regenerate from tools/uisim after any screen change).

Sixth Lua-only change (renders verified, untested on device): UX polish from
first play-testing (feedback log: doc/ux-feedback.md). Every top-right
readout knocks out its own pocket and the encoder flash draws in a framed
black box (legible over any page); page dots sit on one straight pixel row
(current page = wider dash, same row); footer hexagons became circular
dials; FILTER draws the engine's real RLPF/RHPF/BPF magnitude (log-f axis,
100/1k/10k + 0dB rails, filled passband, bright node dot at the cutoff);
WINDOW parks slice length in seconds and scatters jitter ghosts around the
playhead; REC badges RSMP when resample>0 and counts the take in seconds
(ctx.rec_arm_phase); MIX parks the E/T balance; LEVEL hints signal flow.
Every page now gives K2/K3 a job — MIX ENG/TAPE throws, LEVEL IN=0/OUT=0
unity resets, WINDOW FLIP (negate scan), GRAIN OCT−/OCT+ (alt), FILTER
OPEN, DELAY INF, REVERB WASH/KILL — all in the KEYS table, spec §10 updated.
The render suite seeds math.random (deterministic, diffable) and grew a
WINDOW_FLASH shot; dist rebuild byte-verified. Performance walkthroughs:
doc/workflow-standalone.md (keys+encoders only) and doc/workflow-grid.md.

Seventh Lua-only change (renders verified, untested on device): REVERB page
depth, loop 2 of the UX feedback (doc/ux-feedback.md §11–12). REVERB gains
a listener ring, a third ray (rays lengthen with size), and hash-dither air
whose density rides the mix; dormant at mix 0. A DELAY echo-tap-plot rework
was tried and **reverted on user request** — the bouncing-ball delay page
is the keeper (see ux-feedback §11; don't re-attempt unasked). The suite
grew DELAY_INF / DELAY_DRY / REVERB_DRY truth shots; dist re-verified
byte-identical (22 shots). NOTE: the empty-state render invocation is
`render_pages.lua mangler.lua <dir> base empty` — "empty" is the 4th arg;
passing it 3rd just renders the base scenario under an "empty_" prefix.

Eighth Lua-only change (renders verified, untested on device): MIX page
truth pass (doc/ux-feedback.md §14). The engine↔tape crossfade is a
plateau law (mtape.update_mix: `min(1, 2(1−mix))` per side, both decks at
unity around center); the page now scales lane energy by each deck's REAL
gain instead of the raw fader, draws the law itself between the lanes
(handle rides it), stills a fully-thrown-away lane flat-dim, and adds a
slim master VU (amp_out, sqrt law like LEVEL/REC) on the right edge with
a peak-hold tick (~1s decay, bright at clip — mix_peak module state).
Suite grew a MIX_TAPE full-throw shot; dist byte-identical (23 shots).
The MIX page is considered converged pending on-device feedback.

Ninth Lua-only change (renders verified, untested on device): REVERB page
redesigned as CATHEDRAL (doc/ux-feedback.md §13) — user-picked from 16
rendered candidates across two gallery rounds. Cross-section vault (one
bright rib + two dotted echo ribs, unit half-arch precomputed at load: no
per-frame trig) grows with size; starry air (hash dither, 3Hz twinkle,
inside-ellipse test) thickens with mix; two ray pulses arc source →
listener on parabolic paths; RT badge top-left (0.4+size*2.6 s — an
estimate, FreeVerb size→RT is not calibrated); dormant at mix 0. Suite
gained REVERB_WASH; dist byte-identical (24 shots).

**Engine deploy ritual (every time the .sc changes, no exceptions):**
1. replace file → verify on-disk with a REPL fingerprint grep
2. SYSTEM > RESTART (sclang only recompiles at startup — script reload is NOT enough)
3. load script → check `Engine.register_commands; count:` in maiden matches the
   expected fingerprint (S2 = 22, S4 = **30**). Wrong count = old engine still live.
Lua-only changes skip all this: save + reload the script.

---

## What mangler is

A performance-first **stereo sample-mangling instrument** for external line-level gear
(synth, drum machine, anything line-level). Built for norns **shield XL on Raspberry Pi 4**,
played with **3 keys + 3 encoders** — everything reachable without a grid; an **optional
grid** (monome, or launchpad-style MIDI grids via midigrid) adds a pad surface. No arc.
It records live stereo input
and mangles it with: multiple **time-stretch** algorithms (pitch-independent), **granular**
clouds, **tape-like** varispeed/looping, a **playback window** (slice start/stop), a
**filter** (LP/HP/BP), and an **FX** section (delay + reverb, each with its own dry/wet).
**Every parameter is MIDI-mappable.**

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
   `luac5.3 -p mangler.lua` (Lua syntax). SC correctness is **only** verifiable on hardware.
   Therefore every stage is **gated on-device** before the next one is written. Never dump
   untested SC in bulk.

4. **Every controllable value is a real param; params are the single source of truth.**
   Keys, encoders, and MIDI all drive `params:*`. This is also how MIDI works (see below).
   Held gestures are tracked in a global `held[]` table so a release on a different page
   still closes the gesture.

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

## Build order (procedural, each ends in an on-device gate)

Full per-stage design — param lists, SynthDef args, command tables, acceptance tests — lives
in `doc/spec.md`. Summary:

- **S0** loadable skeleton (this ship): no-op pass-through engine + Lua router/params shell.
- **S1** RECORD + GRANULAR + WINDOW — `RecordBuf` live capture, `GrainBuf` cloud, slice window.
- **S2** TIME-STRETCH MODES — `mode = GRAIN | WARP | PV` on one voice (Warp1 + phase vocoder).
- **S3** TAPE — softcut parallel path (loop window, varispeed/reverse, stutter, freeze).
- **S4** FILTER + FX — LP/HP/BP filter, delay (time/fb/mix), reverb (FreeVerb, size/mix).

Rationale: softcut (separate audio core, near-free) does everything it can; scsynth does
only what softcut cannot (granular, time-stretch, custom filter/delay/reverb). GRAIN/WARP/PV
are a **mode switch** on a single SC voice, never run together (Pi4 = one scsynth core,
xruns past ~60%).

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
  engine_level, softcut_level, tape_level, monitor_mode, headphone_gain, reverb, rev_*,
  compressor, comp_*, cut_input_*, clock_*, link_*`. mangler uses `cut_level` for the
  softcut path's level.
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
  before drawing conclusions about whichever script loaded last. S0 uses no clocks at all.

---

## Workflow

```sh
# static check (only one available locally)
luac5.3 -p mangler.lua

# render every UI page to PNGs with NO hardware: tools/uisim/render_pages.lua
# stubs the norns env (including include(), so the lib/*.lua modules resolve
# from the repo), runs the real mangler.lua redraw code against a fake
# framebuffer, and drives a scripted performance (a take, a tape loop, FX).
# eyeball these before deploying any screen change — a redraw error on
# device is a silent black screen.
lua tools/uisim/render_pages.lua mangler.lua /tmp/shots base        # all pages + variants
lua tools/uisim/render_pages.lua mangler.lua /tmp/shots base empty  # empty-buffer state
python3 tools/uisim/pgm2png.py /tmp/shots/base_01_MIX.pgm mix.png 4 # PGM -> PNG, 4x

# single-file build: inlines lib/*.lua into dist/mangler_single.lua as
# IIFEs (proven byte-identical via the seeded render suite). the dist file
# is GENERATED — never edit it; rebuild after any lua change that ships.
lua tools/amalgamate.lua

# deploy to the norns (the repo IS the script; --delete kills stale engine copies)
rsync -av --delete --exclude='.git' ./ <norns>:~/dust/code/mangler/

# then on the norns: ;restart  (or reload the script), watch maiden for SC errors
```

**Screen design rules (hold these in every page):** brightness encodes
audibility — if a thing isn't sounding, its picture lies flat and dim (mode
OFF stills the ENG lane, the STRETCH texture, the particles, the playhead;
mix-0 FX pages go dormant). Each page parks its one defining number dim in
the top-right corner (yielding to the transient flash). An empty buffer is
an invitation, always in the same voice: "EMPTY - K2 REC". The page dots
cluster by signal family (source · shape · tape · fx). The STRETCH body
draws the active algorithm's own texture: grains / overlapped warp windows /
spectral columns.

**On-device gate per stage:** load the script, confirm no LOADING hang and no SC errors in
maiden, then run that stage's acceptance test in `doc/spec.md`. Only then write the next
stage. Update the **CURRENT STAGE** marker at the top of this file when a gate passes.
