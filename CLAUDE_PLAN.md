# mangler — fresh-start spec, docs & loadable Stage-0 skeleton

> **Historical.** This is the first plan of the project: mangler's Stage 0, from before
> any code. Nothing in it is current. Its folder `SPEC/` never existed (the spec became
> doc/spec.md, also historical). The current state is the STATUS block of CLAUDE.md, and
> the current plan is doc/plan.md. Whether to delete this file is a decision for the user
> (doc/plan.md, "Decisions for the user").

## Context

The repo is being restarted clean for a new norns script, **mangler**: a performance-first
**stereo sample-mangling instrument** for external line-level gear (synth, drum machine),
targeting norns **shield XL on Raspberry Pi 4**, played with **3 keys + 3 encoders only**
(no grid/arc). The working tree currently holds only a stale `README.md` (pointing at
folders that no longer exist) and a `.claude/scheduled_tasks.lock`. This session's
deliverable is the **design + documentation + a loadable Stage-0 skeleton** — *not* the
full DSP. The instrument is then brought up **one stage at a time on hardware**, because
there is no SuperCollider compiler in this dev environment and untested SC must never be
dumped in all at once. No references to any prior script are carried into the new files.

### What mangler is (from the user's dictation)
A stereo engine that **records** live input and plays it back through several manglers:
- **different types of time-stretching** (independent of pitch),
- **granular** clouds,
- **tape-playback-like** varispeed/looping,
- a **playback window** — select a slice of the recorded sample with a **start and stop**,
- a **filter section**: low-pass, high-pass, band-pass,
- an **FX section**: **delay** (time + feedback) and **reverb**, each with its own **dry/wet**,
- **MIDI controller support for every parameter.**

### Key research findings that shape the design
- **MIDI mapping is native, not a feature to build.** Every parameter added through norns'
  `params:add_control / add_taper / add_number / add_option / add_binary` is automatically
  MIDI-learnable from the PARAMS menu and persisted per-script in a **PMAP** file
  (`data/four/mangler.pmap`). `add_separator / add_group / add_trigger / add_text` are
  *not* mappable. ⇒ **Architectural rule: every controllable value is a real param; keys,
  encoders, and MIDI all drive params. Params are the single source of truth.** This gets
  "MIDI for each parameter" essentially for free and keeps key/encoder/MIDI in sync.
  (monome.org/docs/norns/reference/params)
- **Time-stretch "types" map to distinct SC techniques** on the same recorded buffer:
  **Warp1** (granular time-stretch, `freqScale` decouples pitch from the pointer rate) and
  a **phase-vocoder** path (`FFT` → `PV_*` → `IFFT`, with `PV_MagFreeze` for spectral
  freeze). Plus plain **varispeed** (rate-change playback). These are exposed as a **mode
  select** on the SC playback voice, not parallel voices — the Pi4 SC core is a single
  thread and can't afford all at once. (sc-users / sccode Warp1, PV references)
- **softcut handles "tape playback-like" for free.** norns' built-in softcut (separate
  audio core from scsynth) does record / loop / varispeed / reverse / fades / post-filter
  with effectively no scsynth cost. It cannot share a buffer with the SC engine, so the
  ADC is tapped twice in parallel. softcut also provides the **playback-window slice** via
  `loop_start` / `loop_end`. (monome.org/docs/norns/softcut)
- **The canonical granular reference is the GrainBuf/Glut pattern** (mangl/Glut, Haze for
  live capture): `RecordBuf` captures live ADC into an SC ring buffer, `GrainBuf` reads
  grains from it (size, density, position, jitter, pitch, spread, pan, envscale).

## Architecture

**Signal flow** — load-bearing fact: **softcut and a SuperCollider engine use separate
buffer systems and cannot share a buffer**, so the stereo ADC is tapped twice and the two
playback worlds are blended at the norns main mix.

```
                         ADC (stereo line-in)
                                 │
              ┌──────────────────┴───────────────────┐
              ▼                                       ▼
   Engine_Mangler (scsynth)                    softcut (firmware core)
   RecordBuf → ~60s stereo SC ring buf         voices 1(L)+2(R) → buf 1 & 2
        playback WINDOW [start..end]                playback WINDOW [loop_start..loop_end]
        mode select on ONE voice:                   varispeed / reverse / loop
          GRAIN  (GrainBuf cloud)      [S1]          freeze / stutter            [S3 TAPE]
          WARP   (Warp1 stretch)       [S2]          post-filter (sc native)
          PV     (phase-vocoder)       [S2]
        → FILTER  LP/HP/BP             [S4]
        → DELAY   time + fb + dry/wet  [S4]
        → REVERB  size + dry/wet       [S4]
              │                                       │
              └───────────────── blended at norns main mix ──────────────────┐
                                                                              ▼
                                                                       DAC → gear / monitors

  every box's controls are params:add_* ⇒ all MIDI-mappable via PMAP, all key/enc driven
```

**Stage-split rationale (Pi4: scsynth = one core, xruns climb past ~60%).** Let softcut do
everything it can (record / loop / varispeed / reverse / filter — near-free on its own
core); put in scsynth only what softcut cannot (granular, time-stretch, custom filter +
delay + reverb). GRAIN / WARP / PV are a **mode switch** on the single SC playback voice,
so their costs are never paid simultaneously. Reverb is **in-engine FreeVerb** (cheap) so
it can carry its own dry/wet to match the user's "dry/wet mixer for each FX" — built-in
`audio.rev_param` is the fallback if CPU runs tight. Estimated all-active worst case
≈ 35–45 % of one core.

**Hard invariants (stated in CLAUDE.md + a checklist):**
1. **One engine file only.** A duplicate `Engine_Mangler` class anywhere under `dust/code/`
   makes *every* norns script hang on "LOADING". Ship a single `.sc`; deploy with
   `rsync --delete`.
2. **Name consistency, changed together:** SC class `Engine_Mangler` · file
   `lib/Engine_Mangler.sc` · Lua `engine.name = 'Mangler'` (norns prepends `Engine_`) ·
   SynthDef names.
3. **No SC compiler in dev.** `luac5.3 -p mangler.lua` is the only static check available;
   **every stage is gated on-device** before the next begins.
4. **Every controllable value is a param** (MIDI rule above); held gestures are tracked in a
   global `held[]` so releasing on a different page still closes the gesture.

## File / directory layout (repo root = the deployable script)

```
<repo root>
├── CLAUDE.md                 # agent manual: invariants, staged plan, current stage
├── README.md                 # human: install, page reference, perf model, test checklist
├── SPEC/spec.md              # durable design contract (full detail; living doc)
├── mangler.lua               # Lua control layer (engine.name='Mangler')
├── lib/Engine_Mangler.sc     # THE ONLY engine file (class Engine_Mangler)
└── .gitignore                # .claude/scheduled_tasks.lock, .DS_Store
```
norns-idiomatic: the git repo *is* the script. Deploy =
`rsync -av --delete --exclude='.git' ./ <norns>:~/dust/code/four/`
(`--delete` guards against an orphaned old engine lingering on the device).

## Control surface (3 keys + 3 encoders)

- **E1** = page select. **E2 / E3** = the page's two params; **K1 held** swaps each to an alt param.
- **K1** = alt/shift (held). **K2 / K3** = the page's two actions (momentary or toggle).
- All of K2/K3 + alt actions call `params:set/delta` (never raw locals) so MIDI and keys
  stay in lockstep. Momentary holds (e.g. stutter, reverse) write `held[n]` and dispatch a
  page-independent `gesture_release` on `z==0`.

Pages (E1 cycles): `MIX · REC · WINDOW · GRAIN · STRETCH · TAPE · FILTER · DELAY · REVERB`.
S0 ships the full page list as the router; each later stage wires its page's params/actions.

## This session's scope (after approval)

1. **Repo reset** — rewrite the stale `README.md`; add `.gitignore`. No nested project dirs.
2. **Docs** — `CLAUDE.md`, `README.md`, `SPEC/spec.md` (content split below).
3. **Stage-0 loadable skeleton:**
   - `lib/Engine_Mangler.sc`: `Engine_Mangler : CroneEngine`; `*new`; `alloc` builds a
     trivial **stereo pass-through** SynthDef (`In.ar(context.in_b.index,2)` →
     `Out.ar(context.out_b.index, …)`), starts it in `context.xg` after
     `context.server.sync`, registers one no-op `addCommand`; clean `free`. Goal: compiles +
     loads + passes audio, proving the one-engine rule.
   - `mangler.lua`: `engine.name='Mangler'`; `init()` builds the **params framework**
     (`add_separator`/`add_group` skeleton + global MIX levels as real params) and the page
     list; page router over `PAGES`; `key(n,z)` writes global `held[n]` and dispatches
     `gesture_release` on release page-independently; `enc`/`redraw` stubs showing current
     page + encoder labels; `cleanup`. Must pass `luac5.3 -p`.
4. **Fresh memory lessons** (Mangler-scoped, no prior-script references; written after
   approval since memory writes aren't allowed in plan mode):
   - `mangler-one-engine-rule.md` — duplicate `Engine_Mangler` under `dust` ⇒ every script
     stuck on LOADING; deploy one folder with `rsync --delete`.
   - `mangler-staged-bringup.md` — no SC compiler in dev; bring the engine up one stage at a
     time on hardware, gate each before the next.
   - `mangler-midi-via-params.md` — make every control a `params:add_*`; PMAP gives MIDI
     mapping for free; keys/encoders drive the same params.

**Out of scope this session (later sessions, each on-device-gated):** the Stage 1–4 *code*.
Their full design (command tables, SynthDef args, param lists, acceptance tests) is written
**now** into `SPEC/spec.md`; code is added stage by stage after each prior gate passes.

## Staged milestones (recorded in SPEC/spec.md; each ends in an on-device gate)

- **S1 RECORD + GRANULAR + WINDOW (deepest):** `RecordBuf` live capture into a ~60 s stereo
  SC ring buffer; **playback window** `pos_start`/`pos_end` slice; `GrainBuf` cloud reading
  the window. Params: `rec, rec_level, pre_level, freeze, pos_start, pos_end, scan, size,
  density, pos_jitter, pitch, spread, pan, grain_level, dry_wet, envscale`; polls
  `play_phase`. *Gate:* arm rec, hear a granular cloud from the windowed slice; size/density/
  window audibly change it; freeze holds while live input keeps moving; no xruns.
- **S2 TIME-STRETCH MODES:** `mode = GRAIN | WARP | PV` on the same voice/buffer/window.
  WARP = `Warp1.ar(2, buf, pointer, freqScale=pitch, windowSize, env, overlaps, randRatio)`,
  **pointer rate independent of pitch**; PV = `FFT → PV_* → IFFT` with `PV_MagFreeze` freeze.
  Params: `mode, stretch_rate, warp_window, warp_overlaps, warp_rand, pv_freeze`. *Gate:*
  half-speed playback with no pitch change (WARP), spectral freeze (PV), CPU stable at
  overlaps ≤ 8.
- **S3 TAPE (softcut parallel path):** voices 1(L)+2(R) → buffers 1 & 2 from a parallel ADC
  tap; **playback window** = `loop_start`/`loop_end`; varispeed/reverse, stutter, freeze,
  post-filter; a `tape_set()` helper keeps both voices identical. *Gate:* clean loop (no
  seam click), rate 0.5/negative works, freeze holds tape while the SC cloud keeps running.
- **S4 FILTER + FX:** in-engine filter `type = LP | HP | BP` (SVF/RLPF) with `cutoff`,
  `resonance`; **delay** (`DelayC`/`CombC`, `delay_time`, `delay_fb`, `delay_mix`);
  **reverb** (FreeVerb, `rev_size`, `rev_mix`) — **per-FX dry/wet** as the user asked.
  *Gate:* filter colors the cloud/stretch, delay feedback builds without clipping, reverb
  tail audible, all under CPU budget.
- **Roadmap (post-v1):** scene snapshots, clock-quantized gestures. (MIDI is core, via PMAP,
  from S0 onward — not deferred.)

## Documentation content split

- **CLAUDE.md** — the four hard invariants; the staged plan with a **"current stage" marker**
  (S0 at ship); the one-engine + name-consistency + MIDI-via-params rules; the deploy command;
  the static-check + on-device-gate workflow.
- **README.md** — what mangler is; install/deploy; the 9-page control reference; performance
  model; the per-stage on-device test checklist.
- **SPEC/spec.md** — durable contract: full signal flow, every stage's param list + SynthDef
  args + command table + acceptance test, the page→param/action map, the PMAP/MIDI rule.

## Verification

- `luac5.3 -p mangler.lua` passes (only static check available locally).
- `git status` clean of stale tracked files; `.gitignore` covers the lock + OS cruft; the
  rewritten README no longer points at non-existent folders.
- **On-device Stage-0 gate (user runs):** `rsync` the repo to `~/dust/code/four/`,
  `;restart`; script loads to its home page with **no LOADING hang** and no SC errors in
  maiden; E1 changes the page indicator, keys register. Passing this gate unlocks Stage 1.