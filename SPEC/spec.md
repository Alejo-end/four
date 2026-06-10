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

## 5. Stage 0 — loadable skeleton  *(CURRENT)*

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

`mode = GRAIN | WARP | PV` selects the playback algorithm on the **same** voice/buffer/window.

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

## 10. Page → control map (target, filled in per stage)

| page    | E2 / E2-alt              | E3 / E3-alt             | K2            | K3            |
|---------|--------------------------|-------------------------|---------------|---------------|
| MIX     | `mix` / `out_level`      | `sc_level` / `cut_level`| —             | —             |
| REC     | `rec_level` / `pre_level`| `dry_wet` / `envscale`  | `rec` toggle  | `freeze` toggle |
| WINDOW  | `pos_start` / `scan`     | `pos_end` / `pos_jitter`| reset window  | —             |
| GRAIN   | `size` / `spread`        | `density` / `pan`       | —             | `pitch` reset |
| STRETCH | `stretch_rate` / `warp_window` | `warp_overlaps` / `warp_rand` | cycle `mode` | `pv_freeze` toggle |
| TAPE    | `tape_rate` / `tape_pre` | `loop_start` / `loop_end`| `tape_reverse`(mom) | `tape_freeze` toggle |
| FILTER  | `cutoff` / `resonance`   | — / —                   | cycle `filt_type` | —         |
| DELAY   | `delay_time` / `delay_fb`| `delay_mix` / —         | —             | —             |
| REVERB  | `rev_size` / —           | `rev_mix` / —           | —             | —             |

(Action assignments are provisional and refined on hardware; encoders/keys always go through
`params:*`.)

## 11. Roadmap (post-v1)

Scene snapshots; clock-quantized gestures (freeze/stutter/reverse snapped to a division).
MIDI is **core** (PMAP, from S0) — not a roadmap item.
