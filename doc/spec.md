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

## 10. Page → control map (NU redesign — 9 stations)

The redesign merged the old 14 pages into 9 stations and replaced per-page alt
keys with a **global alt layer** — the same three chords on every page:

- **K1+E1** — scene morph toward the selected slot, from anywhere.
- **K1+K2** — STOP (`stop_all`).
- **K1+K3** — DRY (`ctx.fx_dry`) on a tap; hold to the ~1s arc (`ERASE_FRAMES`
  = 15) to ERASE the current page's material (the frames between the tap and the
  arc are an abort zone). Per-page erase targets are the last column.

| page   | E2 / E2-alt                    | E3 / E3-alt                 | K2                                   | K3                                   | K1+K3 erases          |
|--------|--------------------------------|-----------------------------|--------------------------------------|--------------------------------------|-----------------------|
| TAKE   | `pos_start` / `@win_move`      | `pos_end` / `pos_jitter`    | REC (`rec`, punch)                   | SNAP (window→take)                   | take (`clear_rec`)    |
| VOICE  | `scan`\* / `scan`              | `pitch`\* / `pitch`         | FRZ (`pv_freeze`, punch)             | MODE (cycle PLAY→GRAIN→WARP→PV)      | —                     |
| TAPE   | `tape_rate` / `tape_pre`       | `loop_end` / `@loop_move`   | REC (`tape_rec`, punch)              | REV (`tape_reverse`, punch)          | tape loop + reset     |
| FILTER | `cutoff` / `drive`             | `resonance` / `dry_wet`     | OPEN (throw)                         | TYPE (cycle LP/HP/BP)                | —                     |
| SPACE  | `delay_mix` / `delay_time`     | `rev_mix` / `rev_decay`     | INF (throw: `delay_fb`=0.95)         | BLOOM (throw: shimmer surge)         | —                     |
| MIX    | `mix` / `input_level`          | `out_level` / `monitor_level` | ENG (throw: `mix`=0)               | TAPE (throw: `mix`=1)                | —                     |
| PADS   | `seq_slice` / `seq_len`        | `seq_euclid` / `seq_div`    | PAD (gate: audition slice)           | RUN (`seq_play`, punch)              | pattern (`Mseq.clear`)|
| MOTION | `motion_lane` / —              | `motion_depth` / —          | REC (`motion_rec`, punch)            | PLAY (`motion_play`, punch)          | selected lane         |
| SCENE  | `scene_slot` / `scene_recall_mode` | `scene_morph_amt` / —   | RCL (punch: hold=PEEK, tap=COMMIT; ◄=safe restore) | CAP (`scene_capture`; ◄=mark safe) | slot (`scene_clear`)  |

\* VOICE E2/E3 are **mode-contextual** (`VOICE_FACE`): GRAIN → `size`/`density`,
WARP → `warp_window`/`warp_rand`, OFF/PV/PLAY → `scan`/`pitch`; the alt layer is
always `scan`/`pitch`.

(Encoders/keys all go through `params:*`; the table mirrors `ENC_MAP`,
`VOICE_FACE` and `KEYS` in `mangler.lua`. `@win_move`/`@loop_move` are compound
targets — `move_pair` slides a lo/hi pair together, width-preserved. **The punch
law** governs K2/K3: press engages now, release within `TAP_FRAMES` (5, ~300 ms)
latches, held longer is a punch whose release disengages, and pressing a latched
key turns it off; `pk(...)` wraps a binary param, **throws** (OPEN/INF/BLOOM/ENG/
TAPE) store the prior values and restore them when un-latched, and the PADS
**PAD** gate always closes its audition voice on release (a latched voice would
just be the drone). The selectors `seq_slice`/`motion_lane`/`scene_slot` are real
params — MIDI-mappable — and `seq_slice`'s action mirrors `ctx.pad_cursor` (one
selection, until the NU-3 slice merge). Destructive erases stay off the tap
layer: they need the held K1+K3 arc.)

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
while sounding, bright cursor), a plain-words routing header (PLAY>PADS / PLAY>DRONE — renamed from NOTES> in the S24 redesign), a
used/cap voice count, and the EMPTY invitation. New key: **K1+K3 ROUTE** toggles pad_input on
the page. Per-pad position + the optional guarded DFM1 filter were deferred (JPverb/MiClouds
were the named asks; keep the untested surface minimal).

**S12 gate:** Lua-only — reload the script (no RESTART, count still 55). The PADS page reads
as 8 slices of your take; K1+K3 flips PLAY>PADS/DRONE; with it on, MIDI/grid notes trigger
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

**Capture by POLLING (not by wrapping calls).** Every frame while armed, `tick()` reads the
current value of each `MOTION_IDS` param and, if it changed since last frame, appends
`{offset, value}` to `lane[id]` (offset = `ctx.frame − rec_start` on the first pass, else the
playhead). This catches **every** driver — encoder (`params:delta`), key throw, MIDI CC, typing
keyboard — because it only ever *reads* values; it never depends on how they changed. `snapshot()`
on arm baselines `last_val` so only moves made *after* arming record. Only ids in `MOTION_IDS` are
watched — the performance / mangle params (the page `ENC_MAP` + `KEYS` targets: `mix`, `cutoff`,
`resonance`, `drive`, `delay_*`, `rev_*`, `shimmer*`, `size`, `density`, `spread`, `clouds_*`,
`scan`, `pitch`, `pos_*`, `warp_*`, `mode`, `freeze`, `pv_freeze`…). **Excluded:** system levels
(`input/output/monitor_level`, `headphone_gain`), `keys_*`, PSET, and the transports `stop_all` /
`rec` / `tape_rec` (a loop must never re-arm recording or fight STOP).

> **WHY POLLING (the S16 bug, fixed).** The first cut *wrapped* `params.set` / `params.delta`. That
> looked right and passed the offscreen sim — but the sim only ever drove `params:set`, while on the
> real norns an **encoder** turn goes through `params:delta` → the individual param's delta, which
> never re-enters the wrapped paramset `set`, so **nothing recorded on device**. Polling reads the
> resolved value each frame and is immune to all of it (no wrap, no `cleanup` restore).

**No runaway.** When playback fires `params:set(id, v)` for an owned lane it writes `v` straight
into `last_val[id]`, so the next poll sees no change and doesn't re-capture the loop's own output —
only genuinely-live moves enter a lane. Gate check: record a sweep, loop it 10×, lane event count
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

### S17 — self-resampling / regen (engine + Lua, fingerprint 58 → 59, UNTESTED)

The self-resampling half of the innovation brainstorm: the sampler **eats itself**. `resample`
already blends the post-FX output into the record buffer — but **only during an armed `rec`
pass** (`recL = in·(1−resample) + sig·resample`, written when `recRun = rec·(1−freeze)`). S17
adds **`regen`**: a continuous feedback that runs the record head on its own, crossfading the
processed output back into the buffer so the granular/FX engine slowly **re-mangles its own
sound** — Basinski-style generative decay. (Distinct from the tape deck's overdub, which loops
the *input*, and from `resample`, which needs a manual write.)

**Engine (`\mangler_io`), one new arg `regen` (0..1, default 0):**
```
regenRun = (regen > 0) * (1 - rec) * (1 - freeze);   // continuous, unless manually recording/frozen
runW     = recRun.max(regenRun);
srcL     = (recL * (1 - regenRun)) + (LeakDC.ar(sig[0]) * regenRun);   // regen source = the OUTPUT
srcR     = (recR * (1 - regenRun)) + (LeakDC.ar(sig[1]) * regenRun);
recLvl   = (rec_level * (1 - regenRun)) + (regen       * regenRun);
preLvl   = (pre_level * (1 - regenRun)) + ((1 - regen) * regenRun);
RecordBuf.ar(srcL, buf_l, 0, recLvl, preLvl, runW, 1);   // (recL/recR still feed the rec_amp poll)
RecordBuf.ar(srcR, buf_r, 0, recLvl, preLvl, runW, 1);
```

**Why it's safe (the three guards):**
- **Bounded — can't run away.** The regen write is a **convex crossfade**: `preLvl + recLvl = 1`,
  both in [0,1]. Each pass a buffer sample becomes `(1−regen)·old + regen·output`; since `old`
  and `output` are both ≤1 (output is capped by the master `Limiter(0.92)`), the result stays
  ≤1. No geometric growth. `LeakDC` on the regen source stops DC building over passes.
- **True no-op at `regen=0`.** `regenRun=0` ⇒ `runW=recRun`, `srcL=recL` (the `×0` term is
  exactly 0), `recLvl=rec_level`, `preLvl=pre_level` — the `RecordBuf` call is **bit-identical**
  to today's. Manual recording is also unaffected whenever `regen>0` (the `(1−rec)` factor zeroes
  `regenRun` during a real take; `freeze` halts regen too, so freeze still locks the buffer).
- **Can't brick loading.** All core UGens (`RecordBuf`/`LeakDC`), no plugin deps.

`\regen` joins `ioKeys` (auto-registered) → **fingerprint 58 → 59**.

**Lua:** `regen` in `grp_rec` (6 → 7); **REC page** E3/E3-alt become `resample`/`regen` (the two
"output → buffer" controls, thematically paired) — `dry_wet` leaves REC (still on FILTER+K1).
A **REGN badge** lights on REC while regen>0 (beside RSMP), SHORT `REGN`.

**Known limits (device follow-ups, don't pre-build):** the record head traverses the **whole
60s buffer**, so the window (the take) is re-touched about **once per minute** — a slow, ambient
decay by design; a **window-synced/faster** variant (BufWr at the playhead) is a follow-up. The
`wave[]` display only repaints on `rec`, so the morphing buffer isn't drawn (the badge signals
it's live). A complementary **Lua-only** self-resampling exists too — route engine output into
softcut (`audio.level_eng_cut`) so the **tape** loops the processed output — parked as an option.

**S17 gate (RESTART — `regen` is in the `.sc`; count 59):**
1. Loads clean, `count: 59`, no SC-tab errors.
2. `regen=0`: everything sounds and records exactly as before (bit-identical guard).
3. Record a short take, set mode PLAY/GRAIN, raise `regen` (~0.3–0.6): over ~a minute the loop
   visibly/audibly evolves — the sound feeds on itself, thickening then decaying — and the REGN
   badge is lit. **No runaway / no clipping blowup** even at `regen=1` (the crossfade + limiter
   hold it).
4. Arming manual `rec` while `regen>0` records the input normally (regen pauses); `freeze` halts
   the evolution and locks the current buffer.
5. Watch xrun headroom with GRAIN + tape + a full reverb also running (RecordBuf feedback is
   cheap, but confirm).

### S18 — step sequencer / SEQ page (Lua-only, fingerprint STAYS 58/59)

The **sequencer pillar** — the thing that separates a live mangler from a workstation (the Torso
S-4 comparison). A clock-synced **Euclidean** step sequencer that triggers mangler's existing
slice voices, so it needs **no engine change** (drives `engine.note_one_shot`, fingerprint
untouched, can't brick). This is **v1** of a staged build — deliberately scoped small so the
untested surface stays minimal.

**Module `lib/mseq.lua`** (8th lib; amalgamate assert 7→8). One track, up to **16 steps**, an
on/off `pattern[]` generated by a **Euclidean fill** — `seq_euclid` hits distributed as evenly as
possible over `seq_len` steps (Bresenham/Bjorklund: `acc += k; if acc>=n then acc-=n, hit`). Each
active step retriggers a **MONO voice via `note_on`/`note_off`** (the TESTED path the PADS use —
NOT the untested `note_one_shot`, which is the bug that made the first cut silent) at a position
**inside the current window** — `ctx.pad_pos(slice)`, shared with the pads since S20 (it was
computed locally here while the pads still sliced the whole buffer) — so it always lands on
recorded audio, not a silent stretch of the 60s buffer. Rests release; `M.stop` releases the last
voice. Voice id `2500` (namespaced clear of screen/MIDI/grid ids).

**Clock hygiene (the norns clock-race gotcha).** ONE `clock.sync` coroutine, started on
`seq_play=1` (`M.start`) and **always cancelled** on stop (`M.stop`) and in `cleanup`. `seq_div`
picks the beat fraction (`1/2·1/4·1/8` beats = 8th·16th·32nd). The playhead `M.pos` advances on
the musical clock; the 15fps redraw only READS it (discrete step motion, correct for a sequencer).

**Params (`grp_seq`, 5, all Lua-only → no engine command):** `seq_play` (binary — MIDI-map to a
footswitch), `seq_div` (option), `seq_euclid` (0–16, its action `regen`s the pattern live so
turning E2 *is* the generator), `seq_len` (1–16, also regens), `seq_slice` (0–7).

**SEQ = page 13** (PAGES / PAGE_GROUPS {…,13} / ENC_MAP / KEYS). E2 = `seq_euclid` hits · E2-alt =
`clock_tempo` (a system param, referenced) · E3 = `seq_len` · E3-alt = `seq_div`. K2 = PLAY
(`seq_play`), K3 = SLICE (cycle `seq_slice`); alt slots stay the global STOP/DRY. `body_SEQ` draws
the pattern as two rows of 8 cells (active filled, rests outlined, playhead cell inverts while
running), hits/len parked top-right, slice + run-state top-left; empty (0 hits) invites
"EUCLID: TURN E2 FOR HITS". Fully procedural (no `math.random`), so other pages' seeded renders
stay byte-identical. Adding a 13th page drops the header-dot pitch 4→3, so the whole `doc/ui`
gallery was regenerated (+ `seq.png`). Suite: `SEQ_EUCLID` + `base_13_SEQ`; dist rebuilt +
byte-verified (source==dist).

**Grid (page-aware, like snu).** While the SEQ screen page is active, the grid becomes the
sequencer (`is_seq_page()` in mgrid; otherwise the normal mangler surface): **rows 1-2** are the
16 steps (playhead brightest, active mid, rest dim, beyond-length dark) — **tap a step to
toggle** it (`M.toggle_step`, manual editing on top of the Euclidean fill); **row 7** picks the
slice; **row 8** is transport (play/stop left, clear right). Euclid is the generator, grid taps
edit individual steps; `seq_euclid=0` + grid taps = a purely hand-drawn pattern (the screen's
empty invite reads "TURN E2 — OR TAP GRID", and `body_SEQ` now counts active steps so a
grid-built pattern shows). Grid logic is untested here (the uisim has no grid device).

**Follow-ups (staged, don't pre-build):** per-step **pitch** (a scale, like snu) and per-step
**slice**; **multiple tracks** + CC/param-lock lanes; **patterns + chaining**; more generation
(probability, ratchets, rotation). v1 is the seed.

**S18 gate (Lua-only — save + reload, no RESTART, count still 58/59):**
1. Loads clean; SEQ is page 13; no clock errors in matron.
2. Record a take, chop it on PADS (or just leave slice 0). On SEQ, turn **E2** to ~5 hits — the
   pattern fills evenly; **K2** runs it → you hear the slice retrigger in a Euclidean rhythm on
   the beat, over the drone. The playhead cell steps across in time.
3. **K3** cycles which slice fires; **E3** changes length (pattern regenerates); **K1+E3** changes
   the division (8th/16th/32nd) and the tempo follows `clock_tempo` (**K1+E2**).
4. `seq_play=0` stops it cleanly; reload/`cleanup` cancels the clock (no `clock.lua` resume race).
5. MIDI-map `seq_play` to a footswitch. It's a MONO voice (one at a time), so no pile-up;
   `voice_rel` (PADS E3) sets the tail — shorten it for tighter, more percussive steps.

**S18 device note (first cut was silent):** the initial version fired `engine.note_one_shot`,
which the S8 log marks "available but unused" — untested, and it produced no sound on device
(the `Impulse.kr(0)`→`Trig` one-shot gate never opened). Fixed to `note_on`/`note_off` (the PADS'
tested path) at a window-relative position. DIAGNOSTIC if still silent: does the playhead cell
move across the SEQ page while playing? Moving = the clock runs, so it's the audio path; not
moving = the clock (check `clock_tempo` / that a take exists / voices audible on PADS).

### S19 — scenes / scene morphing / safe snapshot (Lua-only, fingerprint STAYS 58/59)

The **"remember this / go back to that"** layer. Three features on one data model, in
**`lib/mscenes.lua`** (9th lib; amalgamate assert 8→9). No engine change — it re-issues
`params:set`, so the fingerprint is untouched and it can't brick loading.

**Data model.** `M.slots[1..8]` = a flat `{ param_id = value }` map captured from the live
params (nil = empty); `M.safe` = one more of the same shape. **Nothing here stores audio** —
scenes are control state only (a recall does not bring back a take you have since overdubbed;
that's PSETs + the tape wav, see mtape). That's what makes it cheap: 8 slots ≈ 350 numbers, a
recall ≈ 60 `params:set` calls. `ctx.scene` = the module (like `ctx.motion`/`ctx.seq`);
`ctx.scenes` = the slots table itself, **mutated in place, never reassigned**, so the ref can't
go stale. The named helpers hang off ctx beside `fx_dry`/`pads_all_off`: `ctx.scene_capture`,
`ctx.scene_recall`, `ctx.scene_clear`, `ctx.scene_morph`, `ctx.safe_snapshot_capture`,
`ctx.safe_snapshot_restore`.

**The three curated lists** (in mscenes, heavily commented — this is the design):
- **`SCENE_RECALL_IDS`** — built from three ORDERED blocks, and recall/restore walk it in
  order: **TIMBRE** (source blend, window, grain/clouds, stretch shape, tape loop, voices, seq
  pattern) → **SPACE** (filter/drive/delay/reverb/shimmer) → **SWITCH** (the discrete
  mode/type switches, **`mode` last of all**: it respawns the SC voice, so switching it last
  means the new voice is BORN with the scene's params instead of jumping to them).
  **Out:** hardware/config (`midi_channel`, `keys_enable`, `kb_octave`, `root_note`,
  `pitch_quant`), the SYSTEM levels (`input_level`/`output_level`/`monitor_level`/
  `headphone_gain`), `out_level` (a scene must never rewrite your stage volume), the capture
  transports (`rec`, `tape_rec`), `stop_all`, and the motion/seq transports. A scene changes
  how it sounds, never how it's plumbed or whether it's running.
- **`SCENE_MORPH_IDS`** — recall MINUS 7, derived at load (a filter, not a second literal
  list — it can't drift; `MORPH_SKIPPED_IDS` is the complementary half, built in the same loop
  and used by the page's cue). The rule in one line: **a morph never flips a hold, never
  re-routes your notes, never writes the buffer, and never changes the voice structure** →
  out: `freeze`, `pv_freeze`, `tape_freeze` (holds; crossing 0.5 is a hard event, not a
  texture), `pad_input` (note routing), `resample`, `regen` (buffer writers — a sweep must stay
  undo-able, and committed audio is not), `voices` (the poly CAP — lerping it crosses integers
  and every crossing re-caps the engine allocator, which STEALS held pad notes mid-sweep).
  **Consequence:** morph at amt=1 ≠ recall(B) — it moves the morph-safe subset only. Sweep to 1,
  then K2 RCL to land the rest; `M.unlanded(slot)` reports exactly that, and the page cues it.
- **`tape_reverse` is in NO list** — it's MOMENTARY (the TAPE key + grid pad hold it and hand
  the release to `held_gesture`), so its resting value is 0 and a captured 1 is a transient.
  Recalling that 1 would latch the tape backwards with nothing left to release it. Nothing is
  lost: `tape_rate` is bipolar and IS recalled, so "backwards" stores as a negative rate.
- **`SAFE_SNAPSHOT_IDS`** — recall + `out_level` (if a throw moved your level, the rescue
  brings it back). Still refuses the system levels/transports/`stop_all`: a restore must never
  unmute you, re-arm a recording, or undo a STOP you're leaning on.
- **NEVER in any list: the `scene_*` params themselves.** `scene_morph_amt`'s action re-fires
  the morph, so a snapshot restoring it would instantly overwrite what it just restored.

**Morph.** `M.morph(a, b, amt, opts)`. Continuous params interpolate in the **controlspec's own
(warped) space** — `unmap` → lerp → `map` — because `cutoff` 20→20000 is exponential and a raw
lerp would sit at "nearly open" for the whole second half; warped-space is linear in the space
the encoder moves in, which is the one that sounds even (0.5 of 200→20000 = 2000, the geometric
mean, verified). `opts.linear` forces a raw lerp. Numbers (`voices`, `warp_overlaps`) lerp and
round to integers; options/binaries can't be half-switched, so they **flip at amt ≥ 0.5**.
Params missing from either scene are skipped. **Deadband:** the normalized target doubles as the
"already sent" key, so a param identical in A and B never fires at all, and a moving one re-sends
only past `MORPH_EPS` (1/400 of range). The **ends force-assert** so amt=0/1 land exactly on the
stored values. `M.invalidate()` clears that memory whenever something else moves the instrument
(capture/recall/restore/endpoint change), so the next amt move re-asserts from wherever we are.
**Changing A/B never writes params** — only the amt knob does; otherwise touching the B selector
at amt=0 would jump the whole instrument to A.

**Frame coalescing (the CPU rule).** `scene_morph_amt`'s action only marks dirty; `M.tick()`
(in the EXISTING 15fps redraw clock, right after `Mmotion.tick()` — no new process) applies at
most one sweep per frame. Uncoalesced, a fast CC sweep would fire ~40 params × 128 CC steps at
the engine in a second; this caps it at 15 passes/s (and the deadband drops the rest). 15fps is
the same modulation grid the gesture looper already runs on.

**Motion integration (one seam, no entanglement).** Every mscenes write goes through one local
`pset(id, v)` → `params:set` + `C.motion.account(id)` (new in mmotion: re-baseline that id from
its RESOLVED value). mmotion captures by POLLING for changes, so without this a scene jump or a
morph sweep would look like forty hands on forty knobs and punch a lane for each. Instead:
`scene_morph_amt` is in `MOTION_IDS` (appended — lane order unchanged), so recording a morph
sweep records **ONE lane** and replay re-derives the other forty. Verified both ways.

**Safe / chaos.** `M.safe_capture()` / `M.safe_restore()` (restore also cancels a queued recall —
it would undo the rescue a beat later). Control state only: it does not touch the buffer, the tape
audio, or held voices (K1+K2 STOP remains the mute). **`chaos_throw`** is a MOMENTARY param
(footswitch/grid pad): press = a bounded random throw of 14 mangle params in NORMALIZED space
(so it lands wild but never silent; `scan` is thrown to one SIDE, never the standstill at norm
0.5), release = `safe_restore`. It auto-marks a safe state if you never did, so the release always
has somewhere to land. The release is guarded by `chaos_live`, so a stray 0 (`params:bang` at
init, a pset read) can never restore out of nowhere. `math.random` lives here and nowhere near the
draw path — the seeded render suite never calls it, so every page's RNG stream is untouched.

**Quantized recall.** `scene_recall_mode` = NOW / BEAT / BAR. Non-NOW queues ONE `clock.sync`
coroutine (`M.pending` = the slot, blinking on screen + grid); a new recall replaces it
(last press wins), and it is **always cancelled** on replace / `safe_restore` / `cleanup` —
the norns clock-race gotcha.

**Params (`grp_scene`, 11, all Lua-only).** `scene_slot`, `scene_morph_a`, `scene_morph_b` (the
A/B actions only `invalidate`), `scene_morph_amt` (control — THE performance knob: MIDI-map a
fader/pedal), `scene_recall_mode` (option), then six **momentary binaries** — `scene_capture`,
`scene_recall`, `scene_clear`, `scene_safe_capture`, `scene_safe_restore`, `chaos_throw`.
Momentary, not `add_trigger`, for two reasons: **triggers can't be MIDI-learned** (the whole
point is a capture/recall/undo/chaos footswitch), and every action fires on the **press edge
(v==1) only**, so a stray 0 from `params:bang()` or a pset read does nothing.

**SCENE = page 14** (PAGES / PAGE_GROUPS {…,14} / ENC_MAP / KEYS). E2 = `scene_slot`, **E3 =
`scene_morph_amt`** (the sweep on the main layer), K1+E2/K1+E3 = the A/B endpoints. K2 RCL,
K3 CAP; the page claims BOTH alt slots for the **safety pair** — K1+K2 **UNDO**
(`scene_safe_restore`), K1+K3 **SAFE** (`scene_safe_capture`) — so on this one page the alt keys
are the ways back instead of the global STOP/DRY (that's the page's whole job). Every key drives
its momentary param and hands the release to `held_gesture` (the TAPE REV pattern), so a
MIDI-mapped footswitch and the key are literally the same action. `body_SCENE`: the safety net
top-left (SAFE chip flashes on mark/restore, else "NO SAFE"), the recall mode dim top-right,
8 slot cells y21..31 (occupied fills, selected wears a bright border, a queued recall blinks,
endpoint ticks under A/B), then the morph bar (A? left, B? right, handle at the amount, dim at
either end — the audibility rule for a gesture); empty bank invites "EMPTY - K3 CAP", one
endpoint missing reads "MORPH: PICK A+B". Fully procedural (no `math.random`).

**The "RCL B TO LAND" cue** makes `morph(1) ≠ recall(B)` visible instead of mysterious: when a
sweep has ARRIVED at an end (amt ≤ 0.001 / ≥ 0.999) **and** the morph is what's driving
(`M.engaged`, set by `morph()`, cleared by `invalidate()` — so a knob parked at 0 from boot claims
nothing) **and** `M.unlanded(end_slot)` (that scene holds a MORPH_SKIPPED value different from
live), the status row says which key finishes the job. It sits centre-row, NOT beside the bar:
at amt=1 the handle is pinned at x110 and would collide with a right-aligned label.

**Grid (page-aware, like SEQ).** While the SCENE page is up: **row 1** = the 8 slots (tap =
recall, quantize-aware; hold **CAP** and tap = capture; hold **CLR** and tap = clear), **row 3**
= morph A, **row 4** = morph B, **row 6** = an 8-step morph amount bar (tap it — the sweep in
reach of a finger), **row 8** = `[CAP][CLR] · [CHAOS, hold] · · [SAFE][UNDO]`. Every pad drives
a param. Untested here (the uisim has no grid device).

**A pad's RELEASE belongs to the surface that took its PRESS (`key_surface` in mgrid).** The grid
dispatches on the CURRENT page, so changing page mid-hold handed the release to a layout that
ignores it and **LATCHED** whatever was held. This **predates S19** — it arrived with the SEQ
surface in S18 and was live on `tape_reverse`: hold grid (3,2), turn E1 to SEQ, let go → the tape
plays backwards forever (also: a note pad held while leaving to SEQ never lifts → a stuck voice).
S19 would have added two more (a latched CHAOS with no way back is the nasty one — "hold chaos
and look at another page" is a gesture performers will try). `grid_key` now records the surface
on the press edge and routes the release back to it. Generic, covers all three, and makes the
SCENE modifiers self-clearing (no page-change hack needed).

**Persistence.** The bank + safe snapshot ride along with the PSET: `tab.save`/`tab.load` of
`{v=1, slots, safe}` → `norns.state.data .. "scenes-<n>.lua"`, wrapped in `pcall`. The
`action_write`/`action_read`/`action_delete` hooks are **SHARED, not replaced** — each module
does its half (mtape the audio, mscenes the state). A pset with no scene file **leaves the bank
alone** (mtape's precedent for a missing wav).

**A pset LOAD must not re-derive the morph (found by review, proven by probe).** `params:read()`
restores `scene_morph_amt`, which fires `touch()` → `dirty`; `action_read` runs *after* the
values, so the next tick would morph on top of everything the pset just restored — silently
discarding any param hand-tweaked after the last morph move (invisible when there's no drift,
which is why it would ship). `M.pset_read` therefore clears `dirty` FIRST (before the
file-exists early return). The pset is authoritative; the morph re-engages on the next knob move.

**Region edges move outward-first.** `EDGE_PAIRS` (`pos_start`→`pos_end`, `loop_start`→`loop_end`)
are params that only mean something as a pair: set one at a time, the consumer reads one new edge
against one old one for an instant, and softcut can render up to a block of a region that is
neither the old nor the new one (`update_tape_loop`'s `hi-lo < 0.1` floor turns a crossed pair
into a 100ms loop → an audible head jump). `apply()` sets the edge that WIDENS the region first,
so every intermediate contains a real region.

**Verification done here (no device):** a functional harness drove the REAL script under the
render sim's stubs — **212 assertions**, all passing: list curation + exclusions (by id, not by
magic number); capture/recall round trip; morph endpoints exact; warped-space midpoints
(geometric mean); discrete policy at 0.5; excluded params untouched by a morph but restored by a
recall; deadband (identical params never re-fire, moving ones ≤1/frame) + endpoint snap; safe
capture/restore incl. `out_level`, `stop_all` untouched; chaos throw/release, no regen/levels/rec,
scan never parked, stray-edge safety, auto-safe-capture; motion (a recall punches NO lanes; a
morph records exactly ONE); pset round trip + missing-file + delete + **the load-clobber
regression**; **edge-pair ordering** (asserted on the actual `params:set` order, both
directions); **the unlanded/engaged cue**; NOW immediate; BEAT/BAR queue → fires on the beat,
replace-cancels, UNDO-cancels, cleanup-cancels. **Each new regression test was verified to FAIL
when its fix is reverted** — a guard that can't fail is decoration. Renders: SCENE +
SCENE_BANK/_MORPH/_SAFE/_ALT/_UNLANDED (68 shots × 4 variants), dist rebuilt + byte-verified
(source==dist, 9 modules). Adding the 14th page adds one header dot to every page: proven by
re-render that all 62 pre-existing shots differ at EXACTLY pixels (y4-5, x122-123) and nowhere
else. Gallery regenerated (+ scene.png).

**S19 gate (Lua-only — save + reload, no RESTART, count still 58/59):**
1. Loads clean; SCENE is page 14; no errors in matron; `grp_scene` shows **11** params under
   PARAMS > scenes (a miscounted group would corrupt the paramset — check the neighbours).
2. Dial a sound. On SCENE: **K3** CAP → slot 1 fills. Change the sound, **E2** to slot 2, K3.
   **E2** back to 1, **K2** RCL → the first sound returns (mode/filter/FX all follow).
3. **Morph:** K1+E2 = A=1, K1+E3 = B=2, then sweep **E3**. The instrument walks between the two
   sounds; the handle rides the bar. Check an exp param (cutoff) sweeps EVENLY, not all at once
   near the top. Check `mode` flips exactly halfway. Check a freeze set in B does NOT come on
   during the sweep (it's morph-excluded), that the page then reads **"RCL B TO LAND"**, and
   that K2 lands it.
4. **Safety:** K1+K3 SAFE (chip lights) → wreck everything → K1+K2 UNDO → back, instantly, no
   glitch. MIDI-map `restore safe state` to a footswitch and confirm it does the same.
5. **Chaos:** MIDI-map `chaos throw` to a pad/footswitch (or grid (4,8) on the SCENE page).
   HOLD → bounded mayhem; RELEASE → back on the safe state. It must never touch your level,
   arm rec, or move regen.
6. **Quantize:** `recall quantize` = BEAT. K2 RCL → the slot blinks, then lands on the next
   beat (with the clock running). A second press replaces the queue; UNDO kills it.
7. **Motion:** arm MOTION (K2), sweep the morph knob, stop → check ONE lane appears (`MRPH`),
   not forty, and that replaying it moves the whole instrument. Then recall a scene while
   armed → it must punch NO lanes.
8. **Grid** (if attached): on SCENE, row 1 recalls, CAP(1,8)+row 1 captures, rows 3/4 pick A/B,
   row 6 sweeps, row 8 has CHAOS/SAFE/UNDO. Leaving the page restores the normal grid surface.
9. **The latch tests (the `key_surface` fix — highest-probability real failure, and the harness
   cannot see any of it):** hold grid (3,2) tape-reverse → E1 to SEQ → release → the tape must
   NOT stay backwards. Hold SCENE (4,8) chaos → E1 to another page → release → chaos must let go.
   Hold a note pad → E1 to SEQ/SCENE → release → the voice must lift.
10. PSET SAVE, change scenes, PSET LOAD → the bank comes back (`data/mangler/scenes-<n>.lua`).
    Then the **clobber** case: morph to ~0.5, hand-tweak cutoff, SAVE, move on, LOAD → cutoff
    must stay where the pset put it (it must not jump a frame later).
11. **The tape-loop seam:** with the tape playing, recall a scene whose loop is somewhere else
    entirely. Listen for a click/stutter (the outward-first edge ordering should keep every
    intermediate a real region).
12. Watch xruns/GC over a few minutes of sweeping: the morph is capped at 15 passes/s.
13. **Known and accepted, verify it reads as intended:** UNDO takes the knobs back but does NOT
    stop the things moving them — a running MOTION lane or the SEQ keeps driving its params
    straight after a restore. If the runaway IS a motion loop, stop MOTION first.

### S20 — pad slices follow the take (Lua-only, fingerprint STAYS 58/59)

**"What is PADS doing anymore?"** — playing silence, mostly. This is the other half of a repair
that only ever landed on one side.

**The bug.** `pad_pos(i)` was `(i + 0.5) / 8` — an eighth of the **60-second buffer**. But the
normal workflow (`REC` K2, play a phrase, K2) makes the `rec` action snap the window to the take,
so a 4-second phrase is ~7% of the buffer. The eight pads fired at 3.75s, 11.25s, 18.75s …
56.25s: **pad 1 caught the last 6% of the take and pads 2–8 played silence.** `mseq` hit exactly
this on device in S18 ("silent for a short take (the pads' known whole-buffer-slice limitation)")
and fixed it **locally**, so post-S18 the sequencer played your take while the pads — same slice
number — played the empty buffer. Two meanings of "slice n" in one instrument.

**The fix.** ONE law, in `ctx.pad_pos(i)` (mangler.lua): `lo + (i + 0.5)/pad_n · span` over the
current window. The PADS audition, the MIDI/grid note routing (`route_note` → `pad_trigger`) and
`mseq.fire()` all resolve through it, so pad 3 and seq slice 3 are the same audio **by
construction** — the divergence can't come back. `mseq`'s local copy of the window math is gone.
A full-buffer window (`pos_start`=0, `pos_end`=1) reduces to the old even-eighths split, so
nothing is lost.

**The page.** `body_PADS` drew `wave[]` across the full width with 8 evenly-spaced dividers —
honest about what the pads did (whole-buffer eighths), but it meant S12's claim that "a pad is
self-evidently an eighth of what you recorded" was false, and on a short take the strip was an
8px blip at the far left with seven dividers over silence. The strip is now **the window, zoomed
to full width** (wave[] is binned over the whole buffer, so it's indexed through the window), so
the picture and the pads finally agree: pad n = the n-th eighth of what you see. The playhead is
drawn in window space and only while it's inside the take. NB the zoom is limited by the display
model — a 4s take covers ~8 of the 128 wave bins, so a short take draws blocky (same property as
the WINDOW page's loupe).

**Consequence worth knowing:** slices are now *relative to the current window*. Re-record, or
nudge WINDOW's edges (or recall a scene that moves them — `pos_start`/`pos_end` are in
`SCENE_RECALL_IDS`), and every pad moves with the take. That's the intent; per-pad absolute
positions were deferred in S12 and still are.

**Verified here:** the harness grew an end-to-end slice section (220 assertions total) that drives
the REAL key path (PADS K2 ×3 → cursor 3, K1+K2 → audition) and the REAL sequencer step, capturing
what each asks the engine for: a pad fires inside the take, at the centre of its eighth; pad 3 and
seq slice 3 fire the identical position and type; slices track the window when it moves; a
full-buffer window reproduces the classic split. **Reverting `pad_pos` to the old law fails 3 of
them** (pad 3 lands at 0.4375 = 26s, take ends at 0.0667 = 4s). Renders: exactly `base_11_PADS`
and `base_11_PADS_LIVE` changed (the strip now fills with the take, all 8 pads on material);
`pads.png` regenerated; dist rebuilt + byte-verified (source==dist, 68 shots).

**S20 gate (Lua-only — save + reload, count still 58/59):**
1. Record a SHORT phrase (2–5s). On PADS the strip should now fill with your take, dividers
   spread across it, all 8 pads over material.
2. K1+K3 → `PLAY>PADS`. Play 8 MIDI notes (or grid note pads): **every pad should sound**, each
   a different eighth of the phrase. This is the actual regression — before, only the first pad
   made a noise and only barely.
3. K1+K2 auditions the cursor pad; K2 steps the cursor; K3 flips GRN/SLC.
4. On SEQ, set `seq_slice` to the same index as a pad and run it: the sequencer and the pad must
   play the SAME audio.
5. Nudge WINDOW's edges, or re-record: the pads follow the new take.

### S19b — the SCENE page must prove it worked (Lua-only, fingerprint STAYS 58/59)

**Device report: "SCENE page is completely broken, keys do nothing, no sound." The keys were
firing the whole time.** Verified against the real norns source (`lua/core/params/binary.lua`):
`Binary:set` equality-guards (`if self.value ~= v`), but every SCENE key hands its release to
`held_gesture`, which returns the param to 0 — so each press is a fresh 0→1 edge and `bang()`
runs. What was actually broken was the page's silence:

- **capture** moved ONE 13px box (the code even set `captured_at` and never drew it),
- **recall of the slot you just captured** re-applies the sound you are already making — it is
  **inaudible by definition**,
- **recall of an empty slot** was a silent no-op that said nothing about being empty.

That is indistinguishable from dead keys. **A performance page that cannot prove it worked is
broken, whatever the code does.** The lesson is not "the user misread it" — it is that
correctness in the harness proves nothing about legibility on the device.

**The fix — one call, two audiences.** `say(msg, detail, slot)` sets a ~1.2s chip on the page AND
prints the full story to maiden. Every action reports itself: `SAVED n` · `RECALL n` ·
**`RECALL n - SAME`** · `SLOT n EMPTY` · `QUEUED n` · `CLEARED n` · `SAFE MARKED` ·
`NO SAFE STATE` · `UNDO` · **`UNDO - SAME`** · `CHAOS`. The touched slot flashes with the message
(`msg_slot`) so the news has a PLACE as well as words, and the message line outranks the morph
cue (a fresh action is the more urgent news).

**`apply()` now returns (set, moved)** — `set_moved()` compares each param before/after — so the
page can say a recall LANDED and nothing moved. That is the single most useful sentence on the
page: it converts "no sound, it's broken" into "of course: you're already there".

**The invitation teaches the workflow** instead of stalling at one scene: 0 filled →
`EMPTY - K3 CAP`; **1 filled → `CHANGE SOUND - CAP SLOT n`** (names the next EMPTY slot — one
scene cannot prove itself, you need a second sound to come back from, and this is the step
everybody stalls on); 2+ filled but no endpoints → `MORPH: K1+E2 = A - K1+E3 = B` (says HOW).

**Screen gotcha (hit here).** The first cut of the hint was **136px on a 128px screen** and
clipped at both ends. Measure before adding words — 124px is the centered limit:
`lua -e 'screen=setmetatable({},{__index=function() return function() end end}); local F=dofile("lib/mfont.lua"); print(F.text_w("YOUR STRING",1))'`

**Suite:** +`SCENE_ONE` (teaching state), +`SCENE_SAVED` (chip + flashed slot), +`SCENE_SAME`
(the recall that explains silence) → 71 shots. Only SCENE shots moved (added `run_ticks` shift
their message/blink phase); `scene.png` unchanged; dist byte-verified; harness still 220.

**Gate:** on the SCENE page, K3 → `SAVED n` chip + that slot flashes + maiden prints the param
count. K2 on the same slot → `RECALL n - SAME` (proof it fired, and why it's silent). K2 on an
empty slot → `SLOT n EMPTY`. With one scene stored the page reads `CHANGE SOUND - CAP SLOT n`;
follow it, then K2 between the two slots — that jump is the feature, and it should be obvious.

### S21 — delete a take, load a sample, and MIX stops lying (ENGINE + Lua, 59 → 61)

Device report: *"sometimes some different tempo version of the sample sounds then cut — I think
it's the tape"* and *"there is no real way to delete a recording or use some other sample
source"*. Both real. The second pair is what stops this being a sampler; the first was hiding in
plain sight because the page that should have shown it was drawing a decoration.

**The mystery sound was the tape — and MIX was hiding it.** `init_tape` sets `sc.play(v,1)` +
`sc.loop(v,1)` ONCE and never clears them, so the softcut deck is **always looping**, and at the
default `mix` of 0.5 the plateau law (`min(1, 2*mix)`) puts it at **full level**. Anything that
ever landed in that buffer — grid **(1,2)** is `tape_rec` and is easy to hit while exploring; a
PSET load restores `tape-N.wav` — loops the take back **once every 60 seconds** and then falls
silent for the rest of the loop. It records the RAW INPUT on its own 60s cycle, unaligned to the
drone's tight window, and at any `tape_rate` ≠ 1 it is literally a different tempo. Diagnosis in
one press: **MIX → K2** (throw to ENG). If it stops, it's the tape; **TAPE → K1+K3** wipes it.

**Why they couldn't see it.** The MIX TAPE lane drew a **static synthetic waveform**
(`TAPE_PREVIEW` — *"so the lane always reads as material"*) whose height rode the **fader**. It
claimed the tape had audio whether it did or not, and ignored `stop_all` completely. That breaks
the house audibility rule — *if a thing isn't sounding, its picture lies flat and dim* — on the
one page whose entire job is telling you which deck you are hearing. The 8th change's MIX truth
pass had this right; the Toy redesign (12th) replaced it with decoration and nobody noticed for
25 changes. **Both lanes now scale by their deck's REAL gain** (the same law `Mtape.update_mix`
sends to the engine and softcut: trim × plateau × master × STOP), the TAPE lane draws the real
`twave`, and the tape **head** is drawn whenever the deck holds audio — bright when audible, dim
when thrown away — so a deck you forgot you armed can never hide again. `TAPE_PREVIEW` is
deleted: if a lane can't tell the truth, it shouldn't draw.

**Engine, +2 commands → fingerprint 61.**
- `clear` (format `""` — a genuine no-arg command; verified against norns `engine.lua`, where
  `#fmt == 0` builds a zero-arg function) → `bufL.zero; bufR.zero`.
- `read_file` (format `"s"`) → `SoundFile.openRead` for the channel count, then the **instance**
  `Buffer:readChannel` (verified in SC's `Buffer.sc`: reads into an EXISTING buffer, does not
  allocate). Mono files feed both sides from channel 0 via `(nch-1).min(1)`.
- Both act on the **same `bufL`/`bufR` the synths already hold**, so no bufnum ever changes,
  nothing respawns, nothing desyncs. All core SC, no plugin deps — cannot brick loading.
- **CAVEAT:** `/b_readChannel` does NOT sample-rate convert and norns runs the server at 48k, so
  a 44.1k file plays ~9% fast. That's a varispeed, not a bug — the Lua side measures the frames
  it actually occupies and snaps the window to them.

**Lua.** `ctx.clear_recording` on **REC K1+K3 = CLR** (mirrors TAPE's CLR — the two decks now
clear the same way; REC gives up the global DRY for it, exactly as TAPE does) plus a momentary
`clear_rec` param so a footswitch can wipe between takes. `ctx.load_sample` via
`params:add_file` (norns fileselect; the path rides the PSET, so a saved session reloads its
sample). `grp_rec` 7 → 9. A loaded sample lands in the **same buffer a take does** — there is no
"loaded sample" mode; window, drone, pads and sequencer just work on it — and the window snaps
to the file's length.

**The waveform problem.** Lua cannot read an SC buffer, so a loaded sample would be **invisible**:
REC/WINDOW/PADS would sit on "EMPTY - K2 REC" over audio you can hear. `Mpages.load_wave(path,
secs)` reads the peaks out of the FILE: a RIFF chunk walk (handles LIST/metadata chunks before
`data`), **16-bit PCM only** (anything else returns nil and the caller leaves the display alone
rather than draw a lie), 128 bins peaked with a **stride** so the work is bounded whatever the
length. Verified here against generated wavs — 4s stereo, 2s mono, a LIST-chunk file, a missing
file, and an 11MB 60s file: exact amplitudes (0.90, 0.50), correct bin counts, zeros past the
sample, 17–30ms scans (the 11MB file is FASTER than the 4s one — the stride bounds it).
**A first cut sampled 8×64 frames per bin and lost a 40ms drum hit entirely** — sparse sampling
looks fine on continuous material and eats transients, which is the exact wrong failure for a
sampler. Don't reintroduce it.

**S21 gate (ENGINE — rsync, SYSTEM > RESTART, confirm `count: 61` in maiden):**
1. Loads clean, count **61**. `grp_rec` shows **9** params (a miscount corrupts the paramset).
2. **The mystery:** with the tape empty, MIX's TAPE lane must lie FLAT (it used to draw a fake
   waveform always). Arm `tape_rec` briefly → the lane fills with the real picture and the head
   runs on it. K1+K2 STOP → BOTH lanes go flat, head dim. That's the audibility rule.
3. **Delete:** record a take, then REC **K1+K3** → the strip empties, the page says
   `EMPTY - K2 REC`, and playback goes silent. Confirm maiden prints `engine buffer cleared`.
4. **Load:** PARAMS > rec > `load sample` → pick any wav in `dust/audio`. It plays, the window
   snaps to its length, and REC/WINDOW/PADS draw its real waveform. A 44.1k file will run ~9%
   fast — expected.
5. The loaded sample must slice on PADS and fire from SEQ exactly like a recorded take.
6. PSET save/load round-trips the sample path.

### S19c — scenes: one selector, not three (Lua-only, fingerprint STAYS 61)

**"The scenes are hard to use" — said three times.** Twice I answered it as a feedback problem
(§S19b). The third time it was the model. This is the fix, and it is a deletion.

**What was wrong.** Capturing a scene ALREADY tells the instrument which slots you care about.
The morph then made you say it twice more — as `morph A` and `morph B`, on the **alt layer**,
where they are invisible until you hold K1. Six steps before you heard anything, two of them
hidden, and a bank that couldn't do a thing until you'd filled TWO slots.

**The model now: from HERE to the slot you're pointed at.** `scene_slot` is the ONE selector and
it has three jobs — K2 recalls it, K3 captures into it, E3 morphs toward it. The morph's near end
is captured implicitly (`morph_from`) on the rising edge out of 0, so it is always "the sound I
was making". Sweep back to 0 and you land exactly where you started; `morph_from` is dropped
there (and by `invalidate`, i.e. any recall/capture/restore/throw), so the next sweep departs
from wherever you are by then. `scene_morph_a`/`scene_morph_b` are **deleted**; `grp_scene` 11 → 9;
the freed alt encoder took `scene_recall_mode`, which was PARAMS-only before.

**What this buys.** It can still do the old A→B (recall A, then sweep toward B — fewer steps than
before), and it adds the thing the old model could not: **ONE captured scene is immediately
musical.** Capture a sound, mangle it however you like, then slide E3 back toward it and stop
anywhere in between. The "you need a second slot before anything happens" teaching hint is gone
because the situation it taught around is gone.

**The trade, stated plainly.** The morph is now RELATIVE, so a sweep recorded by the gesture
looper replays from wherever the instrument is at replay time rather than from a fixed A. That is
inherent to "from here", it is musically reasonable (the sweep is a move, not a coordinate), and
it is the price of deleting two selectors. Noted so nobody rediscovers it as a bug.

**UI.** The bar reads `LIVE ——●—— n`, the aimed slot wears the cursor, and at amt=1 an unlanded
scene says `K2 TO LAND THE REST` (see §S19b). **Grid:** row 1 taps still RECALL (a scene
launcher's natural gesture), so row 3 is **AIM** — point the morph at a slot without jumping to
it; row 1 can't double as the target because you'd already be there and the sweep would have
nowhere to go. Row 5 is the 8-step morph bar.

**Verified:** 229 assertions. New properties — aiming does NOT jump; amt 1 lands on the slot;
amt 0 returns home EXACTLY; the warped midpoint is measured from the live sound; re-aiming
mid-sweep re-targets from the same near end; **one scene + a sweep is musical**; the endpoint
selectors are gone (`params.lookup` asserts their absence). Renders: only SCENE frames moved;
scene.png regenerated; dist byte-verified.

**Gate:** capture ONE scene. Mangle the sound. Sweep E3 → it slides back toward the scene, and
stops anywhere between. Sweep to 0 → exactly the mangled sound again. E2 to another slot mid-sweep
→ it re-aims. Nothing needs the alt layer to work.

---

### S22 — persist the live take (session snapshot + export) — Phase A BUILT (ENGINE, gate pending), Phase B PLANNED

Request: *"is there a way to [save/load] for the live take?"* Today a PSET restores everything
**except** the live take — the engine's `bufL`/`bufR` (what REC captures from the input) is never
written to disk, so a recorded phrase is gone on reload. What survives is the tape deck's audio
(`tape-N.wav`), the scene bank, all params, and any **loaded** sample's path. The tape deck is a
zero-code workaround (arm it while you play — it persists), but it records the RAW input on the
tape's own 60s timeline, not the engine's windowed take. This stage makes the take itself
persist, in two independent phases so the simple half ships and gates on its own.

**SEQUENCING (why "build after the S21 gate").** S21 already took the engine to fingerprint 61
but that count is **still ungated on device**. Phase A adds engine commands, so the number the
S21 gate looks for would change under it. Do it in order: **confirm `count: 61` for S21 first**,
THEN land Phase A → **63**, so each engine change is confirmed against a legible number. The whole
feature is opt-in on top of a device gate that is itself still pending — do not build ahead of it.

#### Phase A — session snapshot (ENGINE +2 → fingerprint 61 → 63, then Lua) — BUILT, device gate pending

> **Status (2026-07-16):** implemented and verified in the offscreen harness (12 assertions
> driving the REAL `params.action_write/read/delete` → `ctx.take_pset_*` closures under the sim
> stubs; the wave_any write-gate and the `_L`/`_R` delete contract each proven to FAIL when
> reverted). Renders byte-identical to HEAD, dist rebuilt + byte-verified. **UNTESTED on device**
> (no sclang here). The gate below is what's left.

The take auto-rides the PSET as a private **L/R pair** beside the pset file, exactly like
`mtape` does for the tape wav and `mscenes` for the scene bank. `bufL`/`bufR` are two **mono**
60s buffers (`Engine_Mangler.sc:184`), and scsynth has no cheap non-realtime way to interleave
two mono buffers into one stereo file — so the snapshot stays two mono files and sidesteps the
interleave entirely. That is Phase B's problem, not Phase A's; keeping them decoupled means the
snapshot never waits on the hard part.

**Engine, +2 commands (the direct inverse of S21's `read_file`/`clear`):**
- `write_take` (format `"s"`, a path **stem**) → `bufL.write(stem ++ "_L.wav", "wav", "int16")`
  and `bufR.write(stem ++ "_R.wav", ...)`. `Buffer:write` issues an async `/b_write` — a direct
  buffer dump, NOT realtime playback — bounded by the buffer size, core UGen-free, no plugin
  deps: cannot brick. **Write 16-bit PCM wav specifically** so `Mpages.load_wave` (the S21
  RIFF/16-bit-PCM peak reader) can repaint the restored take from the L file.
- `read_take` (format `"s"`, the same stem) → the S21-proven idiom, per side:
  `bufL.readChannel(stem ++ "_L.wav", 0, frames, 0, false, [0])` and the same for R. Reads into
  the EXISTING buffers (verified in `Buffer.sc`), so no bufnum changes, nothing respawns.
- Both act on the **same `bufL`/`bufR` the synths already hold** — same guarantee as S21.

**Lua / PSET wiring (fold into the shared hook — do NOT replace it).** `params.action_write/
read/delete` in `mangler.lua:1061` already call `Mtape` + `Mscenes`; add the take half beside
them (a few functions near `ctx.clear_recording`/`ctx.load_sample`, or a tiny `mtake` lib if it
grows):
- **write:** only when there is content — gate on the existing **`ctx.wave_any`** (the same
  has-a-take signal that draws `EMPTY - K2 REC`), so an empty pset never carries a ~5.5 MB
  silence file. `if engine.write_take then engine.write_take(norns.state.data .. "take-" ..
  number) end` (the `if engine.*` guard no-ops against an old engine, like S21).
- **read:** `if util.file_exists(stem .. "_L.wav")` → `engine.read_take(stem)`, set
  `ctx.wave_any = true`, and `Mpages.load_wave(stem .. "_L.wav", 60)` to repaint — otherwise the
  restored take is INVISIBLE (the exact "audio you can hear over EMPTY - K2 REC" bug S21 fixed
  for loaded samples). No take file (a pre-S22 pset) → leave the buffer alone, like `mtape`
  leaves the tape alone when there's no wav.
- **delete:** `os.remove` both `_L`/`_R` files.

**Phase A gate (ENGINE — rsync, SYSTEM > RESTART, confirm `count: 63`; S21's 61 first if not yet
done):** record a take → PSET SAVE n → `clear_recording` (REC K1+K3) so the buffer is empty and
the page says `EMPTY - K2 REC` → PSET LOAD n → the take is back, audible, and the REC/WINDOW/PADS
strips draw its real waveform. Confirm `take-n_L.wav`/`_R.wav` exist and are non-truncated (the
`/b_write` is async — a save immediately followed by quit is the risk to check). A pset with no
take saved must NOT resurrect a stale buffer or draw silence as material. An empty take must NOT
write a file. Round-trips alongside tape audio + scenes without fighting them.

#### Phase B — browsable stereo export (a real single file) — DEFERRED until the count-63 gate

> **Decision (2026-07-16):** hold Phase B until the device confirms `count: 63` (S21 + S22A both
> gated). It would be a THIRD untested engine change stacked on two unproven ones, against the
> one-gate-at-a-time rule — and Phase A already gives full session save/load in the meantime.
> **Chosen source: the DRY take (B-eng below)**, not the post-FX softcut bounce — export means
> "the sample I recorded," and B-soft's routing side-effects (eng→cut, the tape catching it)
> aren't worth it. Build B-eng on the proven engine once the gate passes.

Phase A's pair is a private session snapshot, not a file you can browse or reuse. Export writes a
**named stereo `.wav` into `dust/audio`** so it reloads through the existing `sample_file` /
`read_file` path with ZERO new load code. The only hard part is producing an interleaved stereo
file; two mechanisms, chosen (and gated) when this phase is actually built:

- **B-eng (recommended — the true DRY take).** Engine-side, +1 command (`export_stereo "s"` →
  fingerprint 63 → 64). Either (a) a short bounce synth `BufRd.ar([bufL, bufR]) →
  RecordBuf.ar(stereoBuf)` run for the buffer length then `stereoBuf.write(path, "wav", "int16")`
  (realtime — takes the take's length), or (b) `getToFloatArray` both buffers, interleave in
  sclang, `SoundFile.writeData` (non-realtime, ~5.7M floats over OSC — measure on the Pi4 first).
  Prefer (b) if the pull is fast enough, else (a).
- **B-soft (easy, but DIFFERENT audio).** Lua-only: raise `audio.level_eng_cut` (mtape holds it
  at **0** on purpose — `mtape.lua:82`), record the engine OUTPUT into a softcut buffer for the
  window length, `sc.buffer_write_stereo`. Captures what you HEAR (post-FX, not the dry buffer),
  runs realtime, and collides with mtape's routing (the tape would also catch it) and with live
  playback. Only pick this if "bounce the processed sound" is the actual want.

**Convergence (optional, later).** Once B-eng proves a safe stereo write, Phase A's snapshot
COULD migrate from the L/R pair to a single `take-n.wav` loadable by `read_file`, unifying the
two paths — but that inverts the staging (snapshot would then depend on the hard part), so it is
a cleanup to consider only after both phases are gated, never a reason to delay Phase A.

**Phase B gate:** export a take → a real stereo wav appears in `dust/audio`, plays in any editor,
and reloads via PARAMS > load sample identical to the original (B-eng: dry; B-soft: post-FX, as
chosen). No xruns during the bounce; live audio recovers cleanly afterward.

---

### S23 — post-redesign play-test fixes (Lua-heavy; ONE engine gate for true STOP)

Driver: **doc/ux-feedback.md §19–30** (2026-07-17 voice memo, transcribed). The user's
directive is explicit — **NO new features**: "make this thing we have good, it's hard enough."
Everything here is a fix, a rework, or a removal. Three forks were resolved WITH the user:
**remove the sequencer**, **STOP truly halts (not mute)**, **motion loop-length now, multiple
loops deferred**.

**Fingerprint.** Batch A is Lua-only (STAYS **63**, save + reload). Batch B adds a play-voice
transport gate for true STOP — intended arity-only, so **confirm `count` STAYS 63** after
RESTART; if it needs a `\addCommand` it becomes 64, so reuse an existing arg/command instead.

**Page-count note.** Splitting SPACE takes `PAGES` 9 → **10**, which re-spaces the header path
dots on EVERY page (`mpages.lua:1628-1646`, pitch = `min(5, floor(45/(#PAGES-1)))`). So the
whole `doc/ui` gallery + render suite regenerate; all non-SPACE shots differ only by that dot
shift (the S19-style "one dot moves everywhere" diff). Removing the sequencer does NOT change
the page count — SEQ was already merged into PADS in the NU redesign.

**Progress (in-session build):** A1 ✅ split · A2 ✅ delay range · A3 ✅ deeper reverb ·
A5 ✅ motion length · A7 ✅ blink · A8 ✅ heads · A4 ✅ tape source · A6 ✅ remove seq ·
docs ✅. **BATCH A COMPLETE** (Lua-only, no restart — save + reload). Batch B — B1 true
STOP, B2 erase — is ENGINE-gated, deferred to a device session (needs RESTART + count 63).

- docs: full doc/ui gallery regenerated at 4x (every page's header dots went 9→10 on the
  SPACE split; space.png/space-wash.png retired → delay.png/reverb.png added; take/pads
  reflect the head + slice reworks). README rewritten to ten stations: DELAY + REVERB
  sections replace SPACE, PADS is a play/sound-lock surface (no sequencer), TAKE notes the
  two head shapes, TAPE the source control, MOTION the loop length; features list, page
  table, status flags, grid spine, engine spec + architecture all de-sequenced. mangler.lua
  header + mgrid/mscenes/minput comments de-sequenced. doc/redesign.md flagged
  "superseded in part by S23". dist rebuilt + byte-verified (source==dist, 47 shots).

- A6: sequencer REMOVED. Deleted lib/mseq.lua (amalgamate 9→8); dropped
  seq_play/seq_div/seq_euclid/seq_len/seq_level (grp_seq deleted) + all wiring
  (include/ctx.seq/init/cleanup/body step-row/header triangle/grid step rows).
  KEPT the slice selector: `seq_slice` id UNCHANGED (CLAUDE.md invariant — ids
  are never renamed, so PMAP/PSET survive; only display name → "slice" and it
  moved into grp_voice 7→8). Its action is still the sole writer of
  ctx.pad_cursor. PADS reworked into a pure slice surface: ENC_MAP.PADS =
  seq_slice/pad_voice/pad_pitch/voice_rel (the freed slots became the per-slice
  sound-lock encoders); K3 RUN→ROUTE (pad_input); no page erase (PADS has no
  own material → K1+K3 stays global DRY). Grid PADS workspace: row 3 = 8 slice
  play pads (finger-drum, ids 2600+), row 5 = slice select, row 6 = voice/route;
  state-strip x6 seq-run→pad_input. mscenes: seq_euclid/seq_len/seq_div dropped;
  seq_slice EXCLUDED (a UI cursor, like scene_slot/motion_lane — a scene/morph
  must not move it). Verified: source==dist (47 shots, EUCLID gone), PADS renders
  clean, SCENE capture/recall/morph still exercised byte-clean.

- A4: `cut_source` param (grp_tape 8→9, 0=DRY..1=WET, default DRY) on TAPE K1+E3
  (replacing @loop_move — loop positioning stays on grid + loop_end + PARAMS).
  `Mtape.set_source(v)` drives `level_adc_cut(1-v)` + `level_eng_cut(v)`; the two
  sends SUM at the softcut input, so the tape prints dry input, processed engine
  output, or a blend — the resample/print stage of §25. init_tape reads the
  param (was hardcoded adc1/eng0); cleanup zeroes eng_cut so a WET route can't
  leak to the next script. No runaway (engine reads only the ADC bus). A "SRC
  WET" body flag shows the non-default state so it's never hidden. Verified: DRY
  default byte-identical (TAPE + MIX_TAPE shots), routing-math harness (DRY/WET/
  blend/cleanup), +TAPE_WET truth shot; source==dist (48 shots).

- A7: removed the armed-frame full-width blinking box on TAKE (was the only
  fast blink in the body). REC is still unmistakable — sweeping write head, big
  elapsed seconds, IN meter, blinking header R (kept). §29 satisfied.
- A8: the READ (playback) head is now drawn LAST (never hidden behind the solid
  WRITE head) and is a distinct SHAPE — a dashed column + a caret ▽ above the
  strip — vs the write head's solid line + comet-tail afterglow. Distinguishable
  even when they cross. §30 satisfied. Only TAKE shots changed; source==dist.

- A5: `motion_len` param (grp_motion 4→5, seconds, 0=AUTO) on the free MOTION
  K1+E2 alt slot. Splits motion timing into two timebases: `rec_len` (the
  natural recorded length = the event timebase, events stored against it) and
  `loop_len` (the playback length motion_len sets). Playback reads events through
  `src_of(ph)` = `ph·rec_len/loop_len` — IDENTITY when not retimed, so AUTO is
  bit-for-bit the pre-A5 behavior (MOTION renders byte-identical to HEAD). >0
  retimes playback SPEED losslessly (events untouched); overdub captures at
  src_of too so new events share the timebase; the page plots the step-curve
  against `rec_len` (aligned with the playhead when retimed). Floored at 0.5s.
  Pre-set before recording → honored at finalize. Verified: 47 shots source==
  dist, MOTION 4 shots byte-identical to pre-A5, 17-assertion functional harness
  (AUTO round-trip lossless, retime up/down, floor, pre-set-at-finalize).

- A3: the SPACE split (A1) doubled each effect's encoder complement — DELAY owns
  mix/time/fb, REVERB owns mix/size/decay/damp (feedback, size, damp are NEWLY
  on-encoder; the other 11 JPverb params stay in PARAMS + the WASH/BLOOM throws,
  per the user's own "separate pages = more keys" resolution). No new params.
  Made the newly-exposed rev_size/rev_damp READ on the page: the reverb-tail
  reflection dots now space by rev_size and dim toward the tail-end by rev_damp
  (body_REVERB, mpages.lua). Stale "edited in banks" comment on grp_reverb fixed
  (banking was deleted in NU-1). Renders verified, source==dist (47 shots).

#### Batch A — Lua-only (no restart)

**A1. Split SPACE → DELAY + REVERB (§21, §24).** Register two pages where SPACE sat:
`PAGES` (`mangler.lua:86-89`), `KEYS` (split `KEYS.SPACE` `:331-342` — keep the `INF` delay-pin
throw on DELAY, the `BLOOM` shimmer throw on REVERB), `ENC_MAP` (`:433-443`), `BODY` dispatch
(`mpages.lua:1536-1540`). Split `body_SPACE` (`mpages.lua:943-1025`) at its two already-guarded
blocks: the echo-taps block (`:1011-1024`) → `body_DELAY`, the tail + shimmer-motes block
(`:966-1006`) → `body_REVERB`; duplicate the shared baseline/rails/onset (`:948-964, :1007-1010`)
into each. The engine command surface is id-based/page-agnostic — NO `.sc` change. The param
groups already exist and are already named `"space - delay"` (`grp_delay` `mangler.lua:1078`) and
`"space - reverb"` (`grp_reverb` `:1093`) — rename their labels to drop `"space -"`. All SHORT/FULL/
`fmt_value` label entries for delay/reverb ids already exist (`mpages.lua:291-448`) — no label work.

**A2. Fix the delay feedback range (§23).** `delay_fb` is `controlspec.new(0, 0.95, "lin", 0, 0.3)`
(`mangler.lua:1081-1082`) — LINEAR, capped at 0.95, so audible repeat-count (a `ln`-law of feedback)
stays tiny across almost all travel and only explodes in the last few %, then the in-loop `.softclip`
(`Engine_Mangler.sc:466`) sustains → "≈4 quiet repeats, then jumps to infinite." Fix = re-warp the
controlspec (curved/exp, reach ~0.98) so the knob spans "few → many (10+) → near-infinite" smoothly.
Pure Lua controlspec edit; leave the engine softclip alone unless a device ear-check wants a distinct
top-of-range infinite-hold (that half is engine, defer).

**A3. Deeper DELAY / REVERB pages (§22).** DELAY face = `delay_time / delay_fb / delay_mix`
(feedback gets its own encoder now it's not sharing SPACE). REVERB face = 4 of its 15 existing params
(`rev_decay / rev_damp / rev_size / rev_mix`); the other 11 (early/mod/EQ/cuts/shimmer, all already
in `grp_reverb` `mangler.lua:1093-1124`) stay reachable in PARAMS + on the alt encoder layer. No new
params — the depth already exists, it was just hidden behind the merged page.

**A4. Tape captures the FX output (§25).** `mtape.lua:82` holds `audio.level_eng_cut(0)` ON PURPOSE
— raising it feeds the engine's post-FX output (`Out.ar(out_b)`, `Engine_Mangler.sc:505`, after
filter/drive/delay/reverb) into the softcut tape input. This is the codebase's own parked design
(spec.md "B-soft" above; `CLAUDE.md:503-504`). `level_adc_cut` and `level_eng_cut` SUM at the shared
softcut input crossfields, so a dry↔processed mix = driving BOTH (a norns-router property, not a
choice). Add a `tape_source` param (dry↔processed, avoid reserved ids — use the `cut_*`/`sc_*`
convention) with an action that sets both levels; re-assert in `init_tape` and reset on `cleanup`
(`mtape.lua:137-139`) so it doesn't leak to the next script. No feedback runaway — the engine reads
only `context.in_b` (ADC), never softcut. Caveat to note on the page: with `level_eng_cut` up + the
existing `level_cut(1)`, the tape also catches the engine while you monitor live.

**A5. Motion loop-length control (§26).** Length is implicit today — `loop_len` = frames between arm
and stop of the first pass (`mmotion.lua:163-174`), and the "24.4 s" is a read-only `loop_len/FPS`
display (`mpages.lua:1279`). BOTH MOTION alt-encoder slots are genuinely free (`ENC_MAP.MOTION =
{ "motion_lane", nil, "motion_depth", nil }`, `mangler.lua:441`). Add a `motion_len` param on a free
alt slot (K1+E2 or K1+E3), consumed in the finalize branch to clamp/override `elapsed` (and/or to set
a fixed pre-record window that `capture_poll` wraps to). Lua-only, no engine.

**A6. REMOVE the sequencer (§28).** Delete `lib/mseq.lua`. Unwire: `mangler.lua` — include `:198`,
`ctx.seq` `:206`, `Mseq.init` `:213`, `Mseq.cleanup` `:1383`; `KEYS.PADS` `:360-370` (drop `k3`
RUN/`seq_play` + `erase`=`Mseq.clear`, repoint `k2` off `seq_slice`); `ENC_MAP.PADS` `:440` (drop
`seq_len`/`seq_euclid`); `grp_seq` `:1205-1223` (delete `seq_play`/`seq_div`/`seq_euclid`/`seq_len`/
`seq_level`). **CRITICAL — keep a slice selector.** `seq_slice`'s action (`mangler.lua:1216-1219`) is
the ONLY writer of `ctx.pad_cursor` and only caller of `ctx.pad_edit_sync()`; delete it blindly and
the PADS cursor freezes at 0 and the sound-lock editors stop following. Keep that action body under a
renamed `slice` param (E2 on PADS). `lib/mgrid.lua` — drop `seq_play` strip (`:329, :453`), the step
rows in `pads_ws_key` (`:352-362`, keep slice-select y5 + voice y6), the step rows in `draw_pads_ws`
(`:508-534`, keep slice5 + voice6). `lib/mpages.lua` — drop `seq_*` labels (`:315, :351`), the
`body_PADS` step-row block (`:1226-1253`) + `sq`/`seq_play` firing refs (`:1188-1192, :1196`, keep the
slice cells), the header running-triangle (`:1611-1616`); keep `slice` fmt (`:394-396`) + `SELECTOR_IDS`
(`:458`) for the surviving selector. `lib/mscenes.lua` — remove `seq_euclid`/`seq_len`/`seq_slice`
(`:86`) + `seq_div` (`:99`), keep the renamed selector id. `tools/amalgamate.lua:35` assert **9 → 8**.
`tools/uisim/render_pages.lua` — remove the seq sets + `_EUCLID` shot (`:588, :596, :599-600`).
Docs: README / spec / redesign / this file's §28; regenerate `dist/` + `doc/ui/pads.png`. **Must
stay:** all `ctx.pad_*` state + helpers (`pad_pos :534`, `pad_trigger :542`, `route_note :562`,
`pads_all_off :571`, `pad_edit_sync :580`), the `pad_voice`/`pad_pitch` sound-lock editors, the
slice-cell drawing, and grid slice-select + voice.

**A7. Kill the blinking TAKE window (§29).** `mpages.lua:677-683` — the armed-frame full-width box
gated by `(frame % 4) < 2` (the only fast blink in the body). Drop the blink: draw a steady border
or remove the box. One-line change. (The header "R" flag blink `:1607-1608` is separate — leave it.)

**A8. Playback head vs record head on TAKE (§30).** `mpages.lua:669-687` — both are `screen.level(15)`,
the record head is drawn SECOND and 2px taller, so it occludes the playhead wherever `rec_phase ≈
play_phase`. Give the playhead a distinct tone/shape (dimmer, or a caret/dashed line) and draw it
LAST so it isn't buried. Sources are already separate: `C.play_phase` (`mangler.lua:162`) vs
`C.rec_phase` (`:163`).

#### Batch B — engine (ONE restart)

> STATUS: **BUILT** in the 75th change. The fingerprint moved to 65 since this
> section was written — confirm count **65** (not 63), and gate via
> doc/device-gate.md stage 10. The delay also moved into a spawn/free synth in
> the same change, which is what makes the B2 tail flush possible.

**B1. STOP truly halts (§20).** Today `stop_all` (`mangler.lua:848-852`) only zeroes `engine.level`
+ `sc.level` in `Mtape.update_mix` (`mtape.lua:20-30`) — a click-free MUTE; the play voice, the
record head, and the tape transport all keep running (the "24.4s kept advancing" symptom). For a
true stop: on `stop_all==1` also (a) halt the tape transport — `sc.rate(v,0)` / `sc.rec(v,0)` [Lua],
(b) gate the record head — `engine.rec(0)` [Lua], and (c) gate the play/drone voice + freeze
`phaseBus` so the engine actually pauses and the on-screen heads stop sweeping (`play_phase` poll
`Engine_Mangler.sc:680-682`). The drone gate is the engine piece — add a `run` arg to the play/drone
SynthDefs (multiply into output / gate the Phasor) driven from the existing set path, or free/suspend
the play synth. Restore all of it on START (stop_all→0). **Keep the level slew** so it stays
click-free. Intended arity-only → **confirm `count` STAYS 63**; do NOT add a new command (would be 64).

**B2. Erase reliability + clear kills tails/regen (§19).** The wire is CORRECT: K1+K3 hold ≥
`ERASE_FRAMES` (15 ≈ 1 s, `mangler.lua:494-500`) → `page_erase` (`:423-425`) → `KEYS.TAKE.erase`
(`:292`, `pulse("clear_rec")`) → `ctx.clear_recording` (`:596-608`) → `engine.clear` (`Engine_Mangler.sc:617-621`,
`bufL.zero`/`bufR.zero`) + `clear_wave` + `take_len=0` + window reset. The device symptom ("looks
cool, doesn't work") is almost certainly the gesture, NOT the wire: a *tap* of K1+K3 is DRY
(`ALT_DRY`, `mangler.lua:409-410`), you must HOLD ~1 s to erase, and releasing K1 early aborts.
Secondary suspects: FX/delay/reverb tails ringing after the buffer zeroes, and `regen>0` re-seeding
the buffer from live output. Fix: (1) diagnose on device which cause; (2) make erase discoverable/
forgiving (clearer arc feedback, consider a dedicated CLR affordance separate from DRY); (3) have
`clear_recording` also kill FX tails and force `regen`→0 so nothing rings on after a clear; (4)
verify a fresh `rec` pass actually overwrites the buffer ("record over doesn't replace"). Steps
2-4 are Lua-only; batch with B only if a device check shows an engine cause.

#### Verification & gates

- Static: `luac5.3 -p mangler.lua`; engine paren-balance if `.sc` touched.
- Renders: `tools/uisim/render_pages.lua` — expect NEW `DELAY`/`REVERB` shots, changed `MOTION`/
  `TAKE`/`PADS`; every other page differs ONLY by the 9→10 header-dot shift. Regenerate `doc/ui`.
- Build: `tools/amalgamate.lua` (assert 9→8 after A6) → `dist/` byte-verify (source==dist).
- Batch A ships save + reload. **Batch B**: rsync `--delete` → SYSTEM > RESTART → confirm
  `Engine.register_commands; count: 63` (wrong count = a stray new command; fix before gating) →
  run the ear gate: STOP fully halts + START resumes cleanly (no click); erase clears audibly and a
  re-record replaces; delay knob sweeps few→many→infinite; DELAY/REVERB pages read independently.

#### Deferred (stated, not built — do NOT pre-build)

- **Motion multiple loops (§27).** A real state refactor: nest the singleton fields
  (`loop_len`/`playhead`/`lane_ids`/`lanes` + `rec_start_frame`/`touched_this_pass`/`last_val`,
  `mmotion.lua:64-74`) under `loops[k]`, add a `motion_slot` selector, teach `body_MOTION` about
  selected/other loops, and resolve same-param write ownership across simultaneously-playing loops
  (the "one writer per param" invariant, `mmotion.lua:264`). Lua-only, follow-up pass.
- **Sequencer rework** (the drone/pad-sequencing alternative to removal) — not chosen; note kept
  in §28 if it ever returns.
