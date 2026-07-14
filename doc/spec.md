# mangler — design spec (living document)

The durable contract for **mangler**. This is the source of truth for the signal flow, the
staged build order, every stage's parameters / SynthDef arguments / engine commands, the
page→control map, and the on-device acceptance test that gates each stage. Update it as the
design firms up on hardware.

See `CLAUDE.md` for the hard invariants and the current stage marker.

---

## 1. Overview

A stereo sample-mangling instrument for external line-level gear, norns shield XL on Pi 4,
3 keys + 3 encoders, every parameter MIDI-mappable. Records live input, then mangles it via
a playback window, granular synthesis, time-stretch (several modes), tape-style varispeed,
a filter, and an FX section (delay + reverb).

## 2. Signal flow

**Load-bearing fact:** softcut and a SuperCollider engine use **separate buffer systems and
cannot share a buffer**. The stereo ADC is therefore tapped twice in parallel, and the two
playback worlds are blended at the norns main mix.

```
                         ADC (stereo line-in)
                                 │
              ┌──────────────────┴───────────────────┐
              ▼                                       ▼
   Engine_Mangler (scsynth)                    softcut (firmware core)
   RecordBuf → ~60s stereo SC ring buf         voices 1(L)+2(R) → buf 1 & 2
        playback WINDOW [pos_start..pos_end]        WINDOW [loop_start..loop_end]
        mode select on ONE voice:                   varispeed / reverse / loop
          GRAIN  GrainBuf cloud         [S1]         freeze / stutter        [S3 TAPE]
          WARP   Warp1 stretch          [S2]         post-filter (sc native)
          PV     phase-vocoder          [S2]
        → FILTER  LP / HP / BP          [S4]
        → DELAY   time + fb + mix       [S4]
        → REVERB  size + mix (FreeVerb) [S4]
              │                                       │
              └───────────── blended at norns main mix ─────────────┐
                                                                     ▼
                                                              DAC → gear / monitors
```

**Performance budget (Pi 4):** scsynth = one core, xruns past ~60%. softcut runs on a
separate, near-free core — give it everything it can do (record/loop/varispeed/reverse/
filter). scsynth does only what softcut cannot. GRAIN/WARP/PV are a **mode switch** on one
SC voice; their costs never stack. In-engine **FreeVerb** reverb (cheap) so it can carry its
own dry/wet; fall back to built-in `audio.rev_param` only if CPU runs tight. Estimated
all-active worst case ≈ 35–45% of one core.

## 3. Control surface (3 keys + 3 encoders)

- **E1** — page select.
- **E2 / E3** — the active page's two parameters. **Hold K1** to address the alt parameter
  on each encoder.
- **K1** — alt / shift (held).
- **K2 / K3** — the active page's two actions (toggle or momentary).

All actions and encoders drive **params** (`params:set/delta`), never raw locals, so MIDI
(via PMAP) and the hardware stay in lockstep. Momentary holds write the global `held[n]` and
dispatch a page-independent `gesture_release(n)` when `z == 0`.

Pages, cycled by E1:

```
MIX · REC · WINDOW · GRAIN · STRETCH · TAPE · FILTER · DELAY · REVERB
```

## 4. Parameters & MIDI (architectural rule)

Every controllable value is a real norns param. norns auto-exposes
`add_control / add_taper / add_number / add_option / add_binary` to MIDI-learn (PARAMS menu →
long-press → assign CC), saved per-script in `data/mangler/mangler.pmap`.
`add_separator / add_group / add_trigger / add_text` are **not** mappable — so:

- continuous values → `add_control` / `add_taper`
- mode selects → `add_option`
- toggles (freeze, reverse, rec-arm) → `add_binary` (key-toggleable **and** MIDI-mappable)

**Reserved ids:** norns system params share the script paramset. Never reuse their ids —
on collision the system refuses the add ("refusing to clobber"), silently leaving the
script param missing (and desyncing any `add_group` count). Verified reserved on hardware:
`output_level, input_level, monitor_level, engine_level, softcut_level, tape_level,
monitor_mode, headphone_gain, reverb, rev_*, compressor, comp_*, cut_input_*, clock_*,
link_*`. This is why the softcut path's level is `cut_level`, not `tape_level`.

Params are grouped (`add_group`) per section so the PARAMS menu mirrors the pages.

---

## 5. Stage 0 — loadable skeleton  *(shipped; engine is at S5–S9, see §9b + §11)*

**Goal:** the script loads with no LOADING hang and passes audio, proving the one-engine rule
and the control shell, before any DSP exists.

### `lib/Engine_Mangler.sc`
- `Engine_Mangler : CroneEngine` with `*new { |context, doneCallback| ^super.new(...) }`.
- `alloc`: build a trivial **stereo pass-through** SynthDef
  `\mangler_io` = `[In.ar(in1,1), In.ar(in2,1)]` → soft level → `Out.ar(out, sig)`; `.add`;
  `context.server.sync`; start it in `context.xg` with
  `in1/in2 = context.in_b[0].index / in_b[1].index` (in_b is an ARRAY of two mono
  busses) and `out = context.out_b.index` (one stereo bus).
- one no-op command (`addCommand("noop", "f", { })`) to prove the command channel.
- `free { synth.free }`.

### `mangler.lua`
- `engine.name = 'Mangler'`; `local sc = require 'softcut'` (unused at S0, reserved for S3).
- `PAGES = {"MIX","REC","WINDOW","GRAIN","STRETCH","TAPE","FILTER","DELAY","REVERB"}`,
  `page = 1`, `alt = false`, `held = {}`.
- `init()`:
  - `init_params()` — `add_separator("mangler")`, an `io`/MIX `add_group`, and the global MIX
    params as **real params** (see below). Later stages add their own groups.
  - a redraw clock (~30 fps) and `cleanup` that cancels it.
- `enc(n,d)`: `n==1` pages; `n==2/3` `params:delta` the page's (alt-aware) param — at S0 only
  MIX is wired, other pages are inert placeholders.
- `key(n,z)`: `n==1` sets `alt`; otherwise `held[n] = (z==1)`; on `z==0` call
  `gesture_release(n)` (page-independent, no-op at S0).
- `redraw()`: top strip = page tabs + page name; body = the two encoder labels/values for the
  current page; clearly marks unwired pages as `--`.

### S0 params (real, MIDI-mappable from day one)
| id           | type         | range / opts            | page |
|--------------|--------------|-------------------------|------|
| `mix`        | control      | 0..1 (grain/stretch ↔ tape) | MIX |
| `out_level`  | control      | 0..1.5                  | MIX  |
| `sc_level`   | control      | 0..1 (SC voice level)   | MIX  |
| `cut_level`  | control      | 0..1 (softcut level)    | MIX  |

### S0 gate (on-device)
`luac5.3 -p mangler.lua` passes → deploy → `;restart` → loads to MIX page, **no LOADING
hang**, no SC errors in maiden, E1 changes the page, keys register on screen.

---

## 6. Stage 1 — RECORD + GRANULAR + WINDOW  *(deepest; next)*

Live capture into an SC ring buffer + a GrainBuf cloud reading a windowed slice. Grounded in
the GrainBuf/Glut granular pattern and the live-capture (RecordBuf) pattern.

### Engine
- Allocate a **~60 s stereo** buffer (or two mono buffers). `RecordBuf.ar(in, buf, …,
  run, loop:1)` continuously captures ADC; `pre_level` sets feedback/overdub vs. wipe.
- `freeze` → stop `RecordBuf` (`run = 0`) so the buffer holds while the cloud keeps reading.
- `GrainBuf.ar(2, trig, dur=size, buf, rate=pitch, pos, interp:2, pan, env)` where `trig =
  Impulse.kr(density)`, `pos` swept between `pos_start`/`pos_end` (+ `pos_jitter` + `scan`).
- `play_phase` poll (normalized read position) for the UI.

### Commands / params
| id          | type    | range / opts          | note |
|-------------|---------|-----------------------|------|
| `rec`       | binary  | 0/1                   | arm capture |
| `rec_level` | control | 0..1                  | input → buffer |
| `pre_level` | control | 0..1                  | overdub/feedback |
| `freeze`    | binary  | 0/1                   | hold buffer |
| `pos_start` | control | 0..1                  | window start |
| `pos_end`   | control | 0..1                  | window stop |
| `scan`      | control | -1..1                 | window drift rate |
| `size`      | control | 0.01..0.5 s           | grain duration |
| `density`   | control | 1..200 Hz             | grains/sec |
| `pos_jitter`| control | 0..1                  | position spread |
| `pitch`     | control | 0.25..4 (or ±24 st)   | grain rate |
| `spread`    | control | 0..1                  | stereo spread |
| `pan`       | control | -1..1                 | center pan |
| `grain_level`| control| 0..1                  | cloud out |
| `dry_wet`   | control | 0..1                  | input ↔ cloud |
| `envscale`  | control | 0.1..4                | grain env time |

### Pages wired: REC, WINDOW, GRAIN
### S1 gate
Arm rec, feed a loop in → hear a granular cloud from the windowed slice. `size`/`density`/
`pos_start`/`pos_end` audibly change it. `freeze` holds the buffer while live input keeps
moving. No xruns.

---

## 7. Stage 2 — TIME-STRETCH MODES

`mode = OFF | GRAIN | WARP | PV` selects the playback algorithm on the **same**
buffer/window. The engine is split: a persistent io synth (input, record head with
resample feedback, dry/wet, output) + one playback synth spawned/freed per mode —
only the active algorithm costs CPU, and OFF frees the SC voice entirely (the
"engine on/off" control; the S3 softcut tape path is independent and parallel).
`scan` doubles as the stretch rate: it is the window pointer speed in every mode,
and pitch stays independent in GRAIN/WARP.

- **GRAIN** — the S1 cloud.
- **WARP** — `Warp1.ar(2, buf, pointer, freqScale, windowSize, env, overlaps, windowRandRatio,
  interp)`. `pointer` is a 0..1 phasor over the window; its **rate of change = playback
  speed** (time-stretch), and `freqScale = pitch` is **independent**. `stretch_rate = 0`
  freezes on a slice.
- **PV** — `FFT → PV_* → IFFT` phase-vocoder; `PV_MagFreeze` for spectral freeze.

### Params (add to GRAIN's set)
| id             | type    | range / opts            |
|----------------|---------|-------------------------|
| `mode`         | option  | GRAIN / WARP / PV       |
| `stretch_rate` | control | -2..2 (pointer speed)   |
| `warp_window`  | control | 0.05..0.5 s             |
| `warp_overlaps`| number  | 1..8                    |
| `warp_rand`    | control | 0..1                    |
| `pv_freeze`    | binary  | 0/1                     |

### Page wired: STRETCH
### S2 gate
WARP: half-speed playback with **no pitch change**; `stretch_rate=0` freezes a slice. PV:
spectral freeze holds. CPU stable at `warp_overlaps ≤ 8`.

---

## 8. Stage 3 — TAPE (softcut, parallel path)

softcut voices **1(L)+2(R)** → buffers **1 & 2**, fed from a **parallel ADC tap**
(`level_input_cut`). softcut does the tape work near-free on its own core.

- Window = `loop_start`/`loop_end` (the playback-window slice for the tape path).
- `rate` varispeed; negative = reverse. `rec_level`/`pre_level` for capture/overdub; `freeze`
  = `rec_level 0`. Stutter = shrink the loop to a division and snap to start (restore on
  release). Post-filter via `post_filter_*`.
- A `tape_set(fn)` helper applies identical settings to both voices.

### Params
| id            | type    | range / opts        |
|---------------|---------|---------------------|
| `tape_rec`    | binary  | 0/1                 |
| `tape_rate`   | control | -2..2               |
| `tape_reverse`| binary  | 0/1                 |
| `loop_start`  | control | 0..1 (× buf len)    |
| `loop_end`    | control | 0..1                |
| `tape_pre`    | control | 0..1 (feedback)     |
| `tape_freeze` | binary  | 0/1                 |
| `tape_fade`   | control | 0.001..0.5 s        |

### Page wired: TAPE  (+ blend lives on MIX/home via `mix`)
### S3 gate
Clean loop, no seam click. `tape_rate` 0.5 and negative both work. `tape_freeze` holds the
tape while the SC cloud keeps running.

---

## 9. Stage 4 — FILTER + FX

In-engine, after the SC playback voice, before the SC output to the mix.

- **FILTER** — `type = LP | HP | BP` (SVF or RLPF/RHPF/BPF), `cutoff` (20..20k, exp),
  `resonance` (0..1).
- **DELAY** — `DelayC`/`CombC` with feedback; `delay_time` (0..1 s), `delay_fb` (0..0.99),
  `delay_mix` (0..1 dry/wet). Soft-clip the feedback path.
- **REVERB** — `FreeVerb` (or JPverb if CPU allows); `rev_size` (0..1), `rev_mix` (0..1
  dry/wet). **Per-FX dry/wet** as specified.

### Params
| id          | type    | range / opts        |
|-------------|---------|---------------------|
| `filt_type` | option  | LP / HP / BP        |
| `cutoff`    | control | 20..20000 Hz (exp)  |
| `resonance` | control | 0..1                |
| `delay_time`| control | 0..1 s              |
| `delay_fb`  | control | 0..0.99             |
| `delay_mix` | control | 0..1                |
| `rev_size`  | control | 0..1                |
| `rev_mix`   | control | 0..1                |

### Pages wired: FILTER, DELAY, REVERB
### S4 gate
Filter colors the cloud/stretch across LP/HP/BP. Delay feedback builds without clipping.
Reverb tail audible. All under CPU budget with a stretch mode active + tape running.

---

## 9b. Stage 5 — GAIN PASS (engine, gate pending)

First-play feedback: the wet path was too faint and the FX too subtle. Fixes, all in
`Engine_Mangler.sc` (fingerprint 30 → **31**):

- **Grain overlap compensation** — sparse clouds (density×size < 1) boosted up to 2×,
  dense clouds untouched.
- **`drive`** (new command + param, 0..1) — post-filter tanh saturation with makeup:
  louder *and* dirtier as it rises; doubles as the wet-path safety stage. Lives on
  DELAY's E3-alt slot (hold K1) and in PARAMS > filter.
- **Equal-power FX mixes** — delay and reverb crossfades were linear (cut the direct
  path −6 dB at center while barely adding effect).
- **Reverb return +6 dB** makeup, damp 0.5 → 0.35 (brighter tail).
- **Resonance widened** — rq = 1 − res·0.92, floor 0.05 (was 0.85/0.1); the Lua FILTER
  curve mirrors the same constants.

Tone (same pass, no new commands): GrainBuf/Warp1 interpolation 2 → **4 (cubic)** for
cleaner pitched playback; delay feedback **low-passed at 3.5 kHz** so repeats darken
(dub/tape feel, no high-frequency fizz buildup); a master **Limiter** (0.98, 10 ms
lookahead) before RecordBuf/out so the boosts + drive can run hot without clipping and
resample can't run away. All still core SC.

### S5 gate
Grain cloud at size 30ms/density 8 clearly audible against the dry synth. DRIVE at 50%
unmistakably saturates. Delay mix 30% reads as a real echo (repeats audibly darkening),
reverb mix 30% as a real room, with no level drop when engaging either. Resonance at max
self-emphasizes near oscillation. Master stays clean and loud with everything pushed —
no clipping, no xruns with a stretch mode + tape + all FX engaged.

---

## 10. Page → control map (target, filled in per stage)

| page    | E2 / E2-alt              | E3 / E3-alt             | K2 / K2-alt   | K3 / K3-alt   |
|---------|--------------------------|-------------------------|---------------|---------------|
| MIX     | `mix` / `out_level`      | `sc_level` / `cut_level`| ENG throw (`mix`=0) / **STOP** (`stop_all`) | TAPE throw (`mix`=1) / **DRY** (`ctx.fx_dry`) |
| LEVEL   | `input_level` / `monitor_level` | `output_level` / `headphone_gain` | IN=0 dB reset | OUT=0 dB reset |
| REC     | `rec_level` / `pre_level`| `dry_wet` / `resample`  | `rec` toggle  | `freeze` toggle |
| WINDOW  | `pos_start` / `scan`     | `pos_end` / `pos_jitter`| reset window  | FLIP (negate `scan`) |
| GRAIN   | banked (2 banks × 4)     | banked                  | BANK / OCT− (`pitch` ×½) | MODE (Clouds) / OCT+ (`pitch` ×2) |
| STRETCH | `scan` / `pitch`         | `warp_window` / `warp_rand` | cycle `mode` | `pv_freeze` toggle |
| TAPE    | `tape_rate` / `tape_pre` | `loop_start` / `loop_end`| `tape_rec` / REV (mom) | `tape_freeze` / CLR |
| FILTER  | `cutoff` / `dry_wet`     | `resonance` / `grain_level` | cycle `filt_type` | OPEN (neutralize) |
| DELAY   | `delay_mix` / `delay_time`| `delay_fb` / `drive`   | INF (`delay_fb`=0.95) | KILL (`delay_fb`=0) |
| REVERB  | banked (4 banks × 4)     | banked                  | BANK | KILL (`rev_mix`=0) / SHMR (shimmer bloom) |
| PADS    | `voices` / `voice_atk`   | `voice_rel` / —         | SEL (cursor++) / PLAY (audition) | TYPE (grain/slice) / ROUTE (`pad_input`) |
| MOTION  | LANE select / —          | LEN (`motion_len`) / —  | REC (`motion_rec`) / CLR-L | PLAY (`motion_play`) / CLR |

(This table is kept in lockstep with `ENC_MAP` and `KEYS` in `mangler.lua`; encoders/keys
always go through `params:*`. PADS keys are the exception — SEL/PLAY/TYPE drive the pad
cursor/audition/type in `ctx`, not a param, since a pad bank isn't a single value; MOTION's
LANE cursor is likewise a `ctx` selector, and CLR-L/CLR are destructive so they stay off MIDI.)

**Master STOP (`stop_all`, Lua-only).** A binary param that chokes both decks inside
`Mtape.update_mix` — the one place the engine `level` and the softcut voice levels are
computed — and releases the pad voices. Levels slew, so stop/start are click-free, and
everything else (mode, tape head, loops) keeps running silently: START restores the exact
mix. Surfaces: **K1+K2** (the GLOBAL alt-K2 fallback — every page whose alt-K2 is
unclaimed, i.e. all but GRAIN/TAPE/PADS; the STOP pill lights while stopped), **SPACE** on
a USB typing keyboard (transport, so it works even with `keys_enable` off; the menu still
owns typing), **grid pad (8,2)** (blinks while stopped), and MIDI-map it for a stop pedal.
A blinking **STP** flag sits by the title on every page while stopped. Alt slots a page
doesn't claim in `KEYS` carry this global pair (`ALT_STOP`/`ALT_DRY` in `key_def`).

**DRY throw (`ctx.fx_dry`, Lua-only) + the dry guarantee.** The record path CANNOT capture
FX: `\mangler_io` records `in*(1-resample) + sig*resample`, so at `resample`=0 the take is
the raw ADC input, tapped before the whole chain (`resample`>0 bakes the output in — that's
its job). Every playback mix is a true zero at 0 (equal-power `.sqrt` laws, shimmer is
output-gated, drive is an XFade2 bypass), and the MiClouds call passes `rvb`=0 (its internal
reverb) — positional args verified against v7b1's `MiClouds.sc`. So "reverb on a dry take"
is always one of: `rev_mix`/`delay_mix` left up, `clouds_fb` (a reverb-like wash the REVERB
page can't kill), the norns SYSTEM aux reverb (mangler prints a maiden NOTE at load when
it's on), or FX baked in by recording with `resample`>0. **DRY** (MIX K1+K3, grid (7,2))
throws the playback path clean in one gesture: `delay_mix`/`rev_mix`/`shimmer`/`drive`/
`clouds_fb` to 0 and the filter open (FILTER OPEN's type-aware law). It leaves the source
alone (mode/pitch/window), so PLAY mode + DRY = exactly the recorded sample. DRY rides the
global alt-K3 fallback (every page but GRAIN/TAPE/REVERB/PADS).

## 11. Roadmap (post-v1)

Scene snapshots; clock-quantized gestures (freeze/stutter/reverse snapped to a division).
MIDI is **core** (PMAP, from S0) — not a roadmap item.

### "Better sounding" engine options (needs a device audit first)

S5 wrung the loudness/tone out of the **stock/core** UGens. The next tier of sound
quality means swapping UGens for ones in optional plugin packs — which **must be
confirmed installed on the device first** (`Quarks.installed` / just try compiling a
one-liner), because a missing UGen hangs *every* script on LOADING. In rough order of
audible payoff:

1. **Reverb → JPverb or Greyhole** (sc3-plugins). FreeVerb is the cheap-sounding link;
   JPverb (lush plate/hall, `t60`/`damp`/`size`/`earlyDiff`/`modDepth`) or Greyhole
   (diffuse, pitch-shifting, dub-space) is the single biggest upgrade. ~2–3× the CPU of
   FreeVerb — measure headroom with a stretch mode + tape running.
   **→ DONE (S6, chosen): JPverb, guarded by a build-time `.asClass` check** so a
   missing plugin falls back to FreeVerb instead of bricking loading. `rev_size` → t60
   for now; exposing JPverb's damp/size/mod as params is the follow-up once it's
   confirmed live on device (and CPU headroom is measured). If confirmed present, next
   consider the same treatment for the filter (2) and granular (3) below.
2. **Filter → DFM1** (sc3-plugins) or **MoogFF** (core, LP-only). DFM1 folds
   cutoff+resonance+**drive**+self-oscillation into one musical UGen (would absorb the
   S5 `drive` param). MoogFF is core and safe but lowpass-only, so it can't cover the
   HP/BP arithmetic-select — LP path only.
3. **Granular → MiClouds** (mi-UGens, the Mutable Clouds port). Best-in-class granular
   texture/pitch/spectral; would replace the GrainBuf voice and remap size/density/
   texture/pitch/spread/feedback/reverb. Big rewrite + hard dependency; highest ceiling.
   **→ STILL OPEN, user decision.** S7 (below) took the GrainBuf voice a long way with
   stock UGens; MiClouds is only worth the dependency + rewrite if S7 still doesn't get
   there. Deferred until the S7 gate is heard on device.
4. Cheaper, no-dependency polish still on the table: **stereo width** via a small
   inter-channel grain-time offset, a **ping-pong** delay, waveshaper saturation
   (`Shaper` + Cheby table) instead of tanh. (Per-grain **envelope shaping** — item done
   in S7.)

Path forward: audit installed plugins + CPU headroom on the device, then pick a tier.

### S7 — granular character pass (engine, gate pending, fingerprint 31 → 34)

Stock-UGen-only (cannot brick loading). Changes confined to `SynthDef(\mangler_grain)`
plus two envelope buffers in `alloc` (and their frees); WARP/PV get the new args in their
lists only so `setMode`'s uniform pass doesn't warn.

- **Triggers `Impulse.kr` → `Dust.kr`** (both channels) — kills the periodic comb/buzz
  locked to `density` in sparse clouds, and decorrelates L/R (independent Poisson).
- **`grain_jitter`** (0..1) — per-grain size randomisation, latched per onset. 0 = off.
- **`grain_pitch_spread`** (0..12 st) — per-grain detune, latched per onset. 0 = off.
- **`grain_shape`** (option HANN / WELCH / PERC → engine 0/1/2) — grain envelope; 0 uses
  GrainBuf's built-in Hann (`envbufnum -1`, zero cost, identical to S6).

UI (all in `grp_grain` + on the GRAIN page): `grain_jitter` and `grain_pitch_spread` are
params + visualised on the grain field (tick-length variance / vertical fan); `grain_shape`
cycles on **K1+K3** (`SHP` pill) and reads top-left. GRAIN's 4 encoder slots stay as-is
(size/spread/density/grain_level); the two continuous params sit in PARAMS like `pan`
already does. Suite gained a `GRAIN_CHAR` shot.

**S7 gate:** load clean, SC tab error-free, **command count 34** (was 31). With
`grain_shape`=HANN, `grain_jitter`=0, `grain_pitch_spread`=0 the cloud sounds like S6 apart
from the (intended) Dust trigger — the periodic buzz in a sparse cloud (e.g. size 40ms /
density 6) should be gone. Jitter → grains audibly vary in size; pitch spread → shimmer /
chorus; WELCH → smoother pads, PERC → pointillist clicks. No xruns with a stretch mode +
tape + FX.

### S8 — polyphonic voice engine (engine + Lua, gate pending, fingerprint 34 → 40)

Stock/core UGens + the guarded JPverb only. A per-note voice layer that coexists with the
drone: voices spawn into `playGroup` and `Out.ar`-add onto `play_bus`, so they mix with the
drone and pass through the io FX chain. +6 commands (`note_on`, `note_off`, `note_one_shot`,
`voices`, `voice_atk`, `voice_rel`).

- **Two voice defs**, the allocator picks by per-pad type (the switch): `mangler_voice_grain`
  (S7 grain cloud at `note_pos`, tracks the drone's grain params) / `mangler_voice_slice`
  (clean `PlayBuf` from `note_pos`). Env.asr gated, `doneAction:2` frees on release so grain
  gaps can't strand a voice; one-shots self-terminate via an internal `Trig`. Poly cap =
  `voices`; at cap the **oldest** held voice is release-stolen.
- **Lua (this stage): a PADS page** (page 11, additive — drone pages untouched). An 8-slice
  pad bank: pad `i` → `pos = (i+0.5)/8`, rate 1, per-pad `type` (GRN/SLC). Screen: cursor +
  **K1+K2** audition + **K3** type toggle; **E2** `voices`, **K1+E2** `voice_atk`, **E3**
  `voice_rel`. A **`pad input`** toggle (default OFF) reroutes **MIDI notes + grid note-pads**
  to polyphonic voices (`note_on` on press / `note_off` on release, stable ids: screen 0..8,
  MIDI 1000+, grid 2000+) instead of the mono drone `pitch`; OFF = exactly the old behavior.
  `note_one_shot` is wired in the engine and available but unused by the current pad model
  (held note_on/off, which rings out on release via `voice_rel`).

**S8 gate:** load clean, SC tab error-free, **command count 40** (was 34). (a) drone behaves
exactly as before with `pad input` OFF; (b) a pad press (screen K1+K2, or MIDI/grid with
`pad input` ON) sounds instantly and rings out on release; (c) GRN vs SLC pads audibly
differ (cloud vs clean slice); (d) holding more than `voices` pads steals the oldest. No
xruns with the drone + several voices + FX.

**MiClouds granular (§11 item 3) — user chose to go for it (S11).** See the approved plan
`~/.claude/plans/bright-shimmying-pearl.md`: the instrument grows into a maximally-capable
sampler in gated stages — S9 (headroom + HOME, below), S10 (full-API JPverb + REVERB editor),
S11 (MiClouds granular + GRAIN editor), S12 (PADS rework + optional DFM1). All plugin UGens
**fully guarded** (`.asClass` build-time detect → stock fallback), so nothing can brick
loading. **Performance rule: one MiClouds instance (the drone) — never per poly-voice.**

### S9 — headroom + HOME page (engine gain constants + Lua/doc, fingerprint STAYS 40)

First staged step. Fixes the S8 chord-clipping: poly voices summing on `play_bus` slammed
the master limiter into pumping — per-voice amp 0.5→0.3, limiter ceiling 0.98→0.92. No new
command (still 40; still needs a RESTART — gain is in the `.sc`). Lua: the render suite went
**name-based** (`goto_page`/`pfx`) so page adds/reorders can't desync shots. (An in-script
HOME page was added here then **removed** in the S13 pass — the user wanted the README as the
front-page guide, not a norns-screen page; the name-based harness made the revert a clean
index shift.)

**S9 gate:** load clean, **count still 40**; chords no longer clip/pump; drone/pads unchanged.

### S10 — full-API JPverb (engine + Lua, fingerprint 40 → 50)

The reverb block wraps JPverb's entire attribute set as args (no hardcoding): +10 ioKeys
(rev_decay/damp/early/moddepth/modfreq/low/mid/high/lowcut/highcut). Guarded (.asClass →
FreeVerb fallback). `rev_size` repurposed 0..1 → JPverb 0.5..5 (page viz reads param_norm).
REVERB is a **banked editor** — E2/E3 edit one REVERB_BANKS pair, K2 "BANK" pages them
(rewrites ENC_MAP.REVERB in place via `ctx.rev_next_bank`), a "BK n" chip shows the bank.

**S10 gate:** load clean, **count 50**; each reverb knob audibly changes the tail as its
label says (decay length, damping, size, mod chorusing, the low/mid/high band decays, the
crossover cuts); BANK pages through all pairs; KILL dries. If mi-UGens/sc3-plugins JPverb is
absent it's the FreeVerb fallback (decay + damp + mix respond) — still no brick.

### S11 — MiClouds granular drone (engine + Lua, fingerprint 50 → 55)

GRAIN mode runs a **MiClouds** granular voice when mi-UGens is installed, else the S7
GrainBuf drone. **Guarded two ways** (`.asClass` + a `try` around the def) so it can never
brick — a wrong graph falls back to GrainBuf. A BufRd scrubs the window → feeds Clouds;
pv_freeze doubles as clouds freeze. +5 commands (clouds_pos/tex/fb/mode/lofi). GRAIN is a
**banked editor** (size/density · spread/tex · pos/fb · level/lofi; K2 BANK, K3 MODE cycles
the 4 Clouds modes; octaves on the key-alt layer). **The MiClouds arg order/semantics are
UNVERIFIED — confirm on device.**

**S11 gate:** load clean, **count 55**; watch the SC tab — if it posts "MiClouds def failed
— using GrainBuf", the arg set is wrong (still safe, just fell back) — send me the log. With
mi-UGens present: GRAIN mode granulates the window; size/density/spread/tex/pos/fb/lofi and
the 4 modes audibly do their thing; **no xruns** with the clouds drone + JPverb + delay +
tape + a few poly voices. Without mi-UGens: GRAIN is the GrainBuf drone as before.

### S12 — PADS slice-sampler rework (Lua-only, fingerprint STAYS 55)

The PADS page was abstract 4×2 cells that didn't say what a "pad" is. Redrawn as **the
recording chopped into 8 slices** (buffer waveform under 8 slice boxes: GRN/SLC per pad, lit
while sounding, bright cursor), a plain-words routing header (NOTES>PADS / NOTES>DRONE), a
used/cap voice count, and the EMPTY invitation. New key: **K1+K3 ROUTE** toggles pad_input on
the page. Per-pad position + the optional guarded DFM1 filter were deferred (JPverb/MiClouds
were the named asks; keep the untested surface minimal).

**S12 gate:** Lua-only — reload the script (no RESTART, count still 55). The PADS page reads
as 8 slices of your take; K1+K3 flips NOTES>PADS/DRONE; with it on, MIDI/grid notes trigger
slices polyphonically over the drone; K1+K2 auditions the cursor slice; K3 flips GRN/SLC.

### S13 — dry-by-default + README quick-guide + HOME removed (engine + Lua/doc, STAYS 55)

User feedback: a fresh recording should sound like the **exact dry sample**, FX added on top;
and the README (not an in-script page) should be the front-page guide. (a) Engine: `drive`
became `XFade2.ar(clean, tanh-driven, drive*2−1)` so **drive=0 is a true bypass** (was an
always-on tanh soft-clipping fresh takes) — no new command, still 55. delay_mix / rev_mix
already default 0 (delay + reverb OFF by default) — confirmed, no change. (b) The in-script
HOME page (added in S9) was **removed**; PAGES back to 11, MIX first. (c) README rewritten as
a fast quick-guide.

**S13 gate:** RESTART (drive is in the `.sc`), **count still 55**. A fresh recording plays
back clean (no delay/reverb/saturation until you turn them up); turning drive up adds
saturation smoothly from 0; no HOME page — the script opens on MIX as before.

### S14 — clean PLAY drone (default) + alt-paired banks (engine + Lua, STAYS 55)

The drone playback itself should be the exact sample by default. New `\mangler_play` def: a
straight BufRd loop of the window (scan = speed, pitch = varispeed) — all core UGens. The mode
option is now **{OFF, GRAIN, WARP, PV, PLAY}, default PLAY** (appended so 1..4 keep meaning;
setMode gains an `i==4` case). No new command → still 55. Also: the banked editors halve their
banks by using the alt layer — **REVERB 6→3 banks, GRAIN 4→2**, each bank now `{E2, E3, E2alt,
E3alt}`; K2 pages banks, K1 reaches the second pair within a bank.

**S14 gate:** RESTART, **count still 55**. A fresh take loops back as the clean exact sample
(mode reads PLAY); GRAIN/WARP/PV still mangle when selected; STRETCH MODE cycles all five;
REVERB shows 3 banks / GRAIN 2, and holding K1 on those pages reaches the bank's alt pair.

### S15 — shimmer reverb (engine + Lua + UI, fingerprint 55 → 58)

Pitch-shifted reverb feedback: the tail recirculates through `PitchShift(+shimmer_pitch)` →
`HPF120` → `LPF(shimmer_tone)` back into the reverb input, scaled by `shimmer` — so it climbs
in octaves into an ethereal pad. +3 commands (shimmer/shimmer_pitch/shimmer_tone). **The
delay + shimmer feedback loops MERGE into one `LocalIn.ar(4)`** (SC allows one LocalIn/LocalOut
per SynthDef) — delay ch 0-1, shimmer ch 2-3, one deferred `LocalOut(delayFb ++ shimOut)`.
Wraps the guarded JPverb/FreeVerb. Lua: grp_reverb 12→15, a 4th REVERB bank SHIMMER, a SHMR
bloom key (K1+K3). UI: the decay-tail gains upward motes (density=shimmer, speed=pitch, gated
shimmer>0) + a +ST cue.

**S15 gate:** RESTART, **count 58**. (1) `shimmer=0`: reverb sounds + looks exactly as before
(loop muted, no motes). (2) raise shimmer on a sustained sound: the tail climbs octaves and
blooms; at 0.9 it swells but the softclip holds it — no runaway/harsh clip. (3) shimmer_pitch
+12 = octave, -12 = down, +7 = a fifth stack. (4) shimmer_tone down = darker halo, up =
brighter without hiss blowing up. (5) motes drift upward only when shimmer>0, faster at higher
pitch. **Watch xruns** — PitchShift runs even at shimmer=0 (gated output, not gated UGen), a
small always-on cost on top of clouds+JPverb+delay+tape+voices.

**Reverb "no audible difference" (user report):** almost certainly **JPverb (sc3-plugins) not
installed** → the FreeVerb fallback only responds to decay/damp/mix; the other 9 JPverb params
(size, early, mod depth/freq, low/mid/high, low/high cut) are no-ops on it. Verify on device
with `JPverb.class.postln` in the SC tab. Not a bug — the guard doing its job.

### S16 — gesture looper (motion recording) (Lua-only, fingerprint STAYS 58)

**The fourth driver.** Params are the single source of truth with three drivers — keys, encoders,
MIDI (§4). S16 adds a fourth that **records the param stream and replays it**: a modulation loop
pedal for a 3-knob instrument. Record a filter sweep and it loops hands-free while you granulate on
top; overdub a delay-mix swell onto a second lane; each lane automates its own param independently.
No engine change — it re-issues existing `params:set` calls — so **fingerprint STAYS 58, no RESTART,
save + reload**, and zero risk of bricking LOADING (it is all Lua). This is the highest-leverage
Lua-only addition on the table precisely because every controllable value already goes through
`params:set/delta`: the looper is a thin capture/replay around that one chokepoint, needing no new
audio path, no new engine command, and it inherits MIDI-mappability for its own transport.

**Module: `lib/mmotion.lua`** (script-internal, like mtape/minput: `M.init(ctx)` binds `C = ctx`,
returns `M`). Owns the loop state + the capture hook; drawn by mpages, ticked by the redraw clock,
surfaced by keys/grid.

**Data model — one loop, per-param lanes.**
- `loop_len` — length in **frames** (the 15fps `ctx.frame` grid is the timeline; no new clock, per
  the clock-minimalism gotcha). Set by the first from-empty record pass — free length, loop-pedal
  style, no tempo needed.
- `lane[id]` = a flat, pre-sized array of `{f, v}` events for param `id` over `[0, loop_len)`.
  Sparse — only params the performer actually touched become lanes, so independent params are
  independent automation lanes.
- **Punch-in replace, per lane:** the first time a param is touched in a record pass its lane is
  cleared, then events append. Re-recording a param overwrites **only** that lane (predictable
  overdub); touching a new param adds a lane without disturbing the others. One growing loop you
  keep overdubbing into — no track objects, no mute matrix.

**Capture hook.** `mmotion` wraps the paramset methods `params.set` and `params.delta` (restored in
`cleanup`): call the original, then, while armed, log `{ctx.frame − rec_start, id, params:get(id)}`
into `lane[id]` — reading `params:get` *after* the call captures the absolute value whether the
driver was a set or a delta. Only ids in a whitelist `MOTION_IDS` are captured — the performance /
mangle params (the page `ENC_MAP` + `KEYS` targets: `mix`, `cutoff`, `resonance`, `drive`,
`delay_*`, `rev_*`, `shimmer*`, `size`, `density`, `spread`, `clouds_*`, `scan`, `pitch`, `pos_*`,
`warp_*`, `mode`, `freeze`, `pv_freeze`…). **Excluded:** system levels (`input/output/monitor_level`,
`headphone_gain`), `keys_*`, PSET, and the transports `stop_all` / `rec` / `tape_rec` (a loop must
never re-arm recording or fight STOP). *Device-gate check:* confirm MIDI-mapped (CC) moves land in a
lane — norns pmap CC dispatch should route through paramset `set`; if a firmware path bypasses it,
the fallback is to also notify from the `add_eng_control` action closures.

**The replay guard (no runaway).** Playback fires `params:set` for owned lanes every frame; those
must NOT be re-captured or the loop grows unbounded. `mmotion` raises an internal `replaying` flag
around its own fire calls, and the capture hook ignores any change while it is set — so only genuinely
live moves (enc/key/MIDI) enter a lane. Gate check: record a sweep, loop it 10×, lane event count
stays constant.

**Playback.** Inside the existing `redraw_clock` loop in `init()` (add `Mmotion.tick()` next to
`Mparticles.update()`): when playing, advance a playhead `p` over `[0, loop_len)`, fire every lane
event whose frame `== p`, wrap at `loop_len`. A param holds its last fired value until the next event
(exactly as recorded), so continuous sweeps replay stepped-at-15fps — no worse than live encoder
turning, which the engine already receives un-slewed. Playback visibly moves the footer knobs (they
read the param), so a page shows itself being played. *Refinements (later):* optional linear
interpolation between events for zipper-free sweeps; half-speed / reverse motion; clock/Link-quantized
loop length (the §11 "clock-quantized gestures" line).

**Controls — MOTION page (page 12, appended; `PAGE_GROUPS` gains it as its own fx-adjacent family).**
A modulation looper earns a page the way a static HOME dashboard did not: it needs three unambiguous
standalone controls AND a live lane view (the design law — brightness = audibility: an idle loop
draws dim, a playing lane pulses on each event, the armed lane glows). Keys (the page claims its alt
slots like GRAIN/TAPE/PADS, so the global STOP/DRY pair simply isn't on MOTION — documented):
- **K2 = REC** (`motion_rec` toggle, lit while armed) — arm capture; from empty it starts the loop and
  sets `loop_len` on the next stop; while looping it punches in an overdub.
- **K3 = PLAY** (`motion_play` toggle, lit while looping) — start/stop loop playback.
- **K1+K2 = CLR-L** — clear the selected lane. **K1+K3 = CLR** — wipe all lanes to empty. Clearing
  leaves every param at its last value (no jump).
- **E2 = LANE** — select a lane to view / solo / clear (a `ctx` cursor, not a param — like PADS SEL).
  **E3 = LEN** — pre-set loop length in seconds before the first take (reads captured length after).

**Params (`grp_motion`, Lua-only actions → no engine command, count unaffected).** `motion_rec`
(binary) + `motion_play` (binary), both MIDI-mappable, so a **footswitch can punch overdubs and
start/stop the loop** — the killer mapping for a looper. Clear stays key/grid only (destructive — no
stray CC should wipe a take). Optional `motion_depth` (0..1 global amount / dry-blend of the
automation) is a natural add.

**Grid (mgrid, optional, existing pattern).** A small REC / PLAY / CLEAR transport cluster (lit /
blinking to match) plus a per-lane activity readout — but the instrument stays fully playable
standalone (hard invariant), so the gate rides on the keys.

**Interactions.** STOP (`stop_all`) mutes audio while the loop keeps running silently — START returns
to the exact motion state. DRY (`fx_dry`) is a manual rescue that zeroes FX params; a lane that owns
one will fight DRY — expected (CLEAR stops the loop, DRY does not). **Not persisted in v1** —
serializing lanes next to the PSET (alongside the tape wav, via `params.action_write`) is the
follow-up. Synergy note: pairs naturally with the roadmap's self-resampling idea (evolving textures)
and with clock-quantized gestures.

**Allocation.** Playback + draw stay allocation-free (flat event arrays, static layout, no per-frame
tables — the hot-path rule). Recording appends to lane arrays (amortized, user-driven, rare) — the
only allocating path, and it is off the audio/redraw-critical loop.

**Render suite.** Add MOTION shots (empty / armed / playing-with-lanes) to `tools/uisim`; eyeball
before deploy (a redraw error is a silent black screen); rebuild `dist` and byte-verify the untouched
shots.

**S16 gate (Lua-only — save + reload, NO RESTART, count still 58):**
1. Loads clean, `count: 58`, no matron/SC errors; MOTION is page 12.
2. On MOTION, K2 arms REC (lit); go to FILTER, sweep `cutoff`; back to MOTION, K2 to stop → `loop_len`
   set, K3 PLAY loops the sweep hands-free; the FILTER footer knob moves on its own.
3. Overdub: while looping, K2, move a *different* param (`delay_mix`) → both lanes loop independently.
4. Re-record `cutoff` → only its lane is replaced (the delay lane is untouched).
5. CLR-L clears one lane, CLR wipes all; params hold their last value (no jump).
6. MIDI-map `motion_rec` to a footswitch → stomping punches record.
7. No runaway: record a sweep, loop 10×, lane event count constant (replay guard holds).
8. No new xruns / GC hitch from playback (dev check with a stretch mode + tape running).
