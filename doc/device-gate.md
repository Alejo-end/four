# Device gate — one walkthrough

The last hardware-confirmed state was **2026-07-16 at `count: 63`**. Everything
from the 48th change onward is unverified: about fifteen logged batches,
several of them engine, and the fingerprint has moved to **65**.

This folds those scattered per-change gates into one ordered pass. The order is
deliberate — **the checks that would invalidate everything else come first**, and
checks that share a setup are grouped so you are not re-recording a take five
times.

Each check says what PASS looks like and, when it fails, **which change to
suspect**. That pointer is the part worth having: with a month of batched work,
"something sounds wrong" is not a useful bug report.

**Work top to bottom. If a stage fails, stop there** — later stages assume the
earlier ones held, and a false failure downstream will cost you an hour.

---

## Stage 0 — Deploy · FAIL-STOP

```sh
rsync -av --delete --exclude='.git' ./ <norns>:~/dust/code/mangler/
```

Then on the norns: **SYSTEM > RESTART**. Not a script reload — sclang only
recompiles the class library at startup, so a reload runs the *old* engine
against the new Lua, which is the most confusing possible state.

| # | Check | Pass |
|---|---|---|
| 0.1 | Only one `Engine_Mangler.sc` on the device | `find ~/dust/code -name 'Engine_Mangler.sc'` returns exactly one path |
| 0.2 | Script loads | No hang on LOADING |
| 0.3 | **Command count** | maiden shows `Engine.register_commands; count: 65` |

**0.3 is the whole stage.** If it says 63, the old engine is still live and every
sound check below is meaningless — restart again. If it says anything else,
something changed that shouldn't have; do not continue.

If it hangs on LOADING with a clean matron log, **look at maiden's SC tab** — SC
errors land there, not in matron. A duplicate engine class is the classic cause.

---

## Stage 1 — Does it live at all?

| # | Check | Pass | Suspect on failure |
|---|---|---|---|
| 1.1 | E1 through all **13** pages (12 on `main`) | Every page draws; no black screen | A black screen is a Lua error in `redraw` — scroll maiden below `<ok>` for the traceback |
| 1.2 | Page order | TAKE VOICE TAPE · FILTER DELAY REVERB · MIX · PADS MOTION SCENE · ORBIT EROSION · LAYERS | — |
| 1.3 | SC tab clean | No errors after load | The guarded plugins (JPverb, MiClouds, DFM1) fall back silently; a *posted* error means a wrong arg order |
| 1.4 | Input reaches the meter | TAKE's IN meter moves with your source | Levels / `monitor_level`, not the engine |

---

## Stage 2 — The three that destroy audio · HIGHEST STAKES

These are new, unheard, and each one silently loses a recording. Do them before
anything that costs you a good take.

**Setup:** record a phrase you can recognise (TAKE, K2, play ~10s, K2). The
window snaps to it and it loops back dry.

| # | Check | Do | Pass | Suspect |
|---|---|---|---|---|
| 2.1 | **Erosion respects STOP** | EROSION, `erode` ~0.5, window short (~0.5s). K1+K2 STOP. Leave 5 min. START. | The take is *unchanged* | The `level` gate in `\mangler_play` — `level` must be reaching the play synth via `playParams` |
| 2.2 | **Punch-in doesn't truncate the save** | Narrow the window to ~2s. Punch a ~200ms overdub (K2, tap, K2). PSET SAVE. Reload script, PSET LOAD. | The **whole** take is back, not 2s of it | `take_len` must be grow-only on the rec-off edge |
| 2.3 | **PRINT aborts on STOP** | `print_len` 8s, fire PRINT (PARAMS), hit K1+K2 STOP after ~3s | Maiden says "PRINT aborted by STOP"; **the take is untouched**; no part-silent wav left behind | The abort watch inside `record_pass` |

If 2.1 fails, **turn `erode` to 0 and leave it there** for the rest of this pass —
it will keep eating takes while you work.

---

## Stage 3 — The safety reflexes

The keys you reach for without thinking. They have to be right before you trust
the instrument with a take you care about.

| # | Check | Pass | Suspect |
|---|---|---|---|
| 3.1 | K1+K2 STOP / START, any page | Silence; title chip inverts; START returns the *exact* mix | `Mtape.update_mix` |
| 3.2 | K1+K3 tapped = DRY | Delay/reverb/shimmer/drive/clouds-fb to zero, filter opens | `ctx.fx_dry` |
| 3.3 | K1+K3 **held** ~1s = ERASE | The arc draws, then that page's material is wiped at the threshold | `tick_keys` |
| 3.4 | Release K1 mid-arc = **abort** | Nothing erased, **and no DRY fires either** | The `k13_fired` flag |
| 3.5 | Release in frames 5–14 | Nothing happens — the abort zone | — |
| 3.6 | TAKE erase then PSET SAVE | Saving an empty take **deletes** the old take file; loading does not resurrect it | `take_pset_write` |

---

## Stage 4 — The sound itself

A month of engine work nobody has heard. Use one take and walk the chain.

### 4a · Filter (DFM1 — never heard on hardware)

| # | Check | Pass | Suspect |
|---|---|---|---|
| 4.1 | Sweep `cutoff` in LP | Diode-ladder character, no zipper noise | The `resonance` lag |
| 4.2 | `resonance` to max | Resonant but **stable** — no runaway | The 0.9 clip below self-oscillation |
| 4.3 | HP and BP modes | BP is a resonant LP peak high-passed below it | The guarded DFM1 build |
| 4.4 | **Is it noisy?** | Clean until `drive` asks for grit | The 0.5 input-gain / 2× makeup pair. If noisy: turn `grain_level` down — if it cleans up, that confirms it |

### 4b · Reverb (send-style now, spawn/free)

| # | Check | Pass | Suspect |
|---|---|---|---|
| 4.5 | Raise `rev_mix` from 0 | **The dry sound stays at full level** — reverb only adds tail | The send-style change (this was the "I can't hear the recording" report) |
| 4.6 | `rev_mix` back to 0 | Tail cuts (accepted trade), CPU drops | The spawn/free gate |
| 4.7 | `shimmer` up | Octave-up shimmer, less robotic than a fixed ratio | `pitchDispersion` |

### 4c · Voice and grain

| # | Check | Pass | Suspect |
|---|---|---|---|
| 4.8 | PLAY mode, listen to a full loop | **No click at the loop seam** | The ~5ms edge fade |
| 4.9 | `drive` at 0 | Exact bypass; mid-knob has no level hump | `LinXFade2` |
| 4.10 | GRAIN, sweep `density` | Loudness stays roughly even; no limiter pumping | The overlap-comp clip `(0.25, 16)` |
| 4.11 | `grain_pitch_spread` up | **Much stronger than before** — it was 12× too weak for a year | The removed `/12` |
| 4.12 | Hold a PADS chord in GRAIN, raise density | Still even — voices don't stack louder | The voice-grain overlap comp (new) |
| 4.13 | PV mode | No linear-interp artefacts | BufRd interp 4 |
| 4.14 | Ride TAKE E2 mid-play | No clicks on window-edge moves | The `pos_start`/`pos_end` lags |

### 4d · Erosion and regen (two buffer writers)

| # | Check | Pass | Suspect |
|---|---|---|---|
| 4.15 | `erode` 0, leave running | Take **bit-identical** after minutes | The non-interpolating read |
| 4.16 | `erode` ~0.3 | Darkens over passes, no runaway | — |
| 4.17 | `erode` at speed 2 and speed −1 | Ages at the **same rate** | The constant-rate `eroPhase` head |
| 4.18 | Raise `regen` while `erode` > 0 | `erode` drops to 0 (and vice versa) | The param-layer interlock |
| 4.19 | EROSION K2 HEAL / K3 SCAR | Round-trip; **`regen` comes back too** | Both snapshot `regen` |

---

## Stage 5 — The new instrument features

| # | Check | Do | Pass | Suspect |
|---|---|---|---|---|
| 5.1 | **44.1k loads in tune** | PARAMS > load sample, pick a 44.1k wav | Maiden says "resampling to 48000"; it plays at the **right pitch** | `Mpages.convert_sr` |
| 5.2 | 48k loads untouched | Load a 48k file | No resample message; instant | The rate probe |
| 5.3 | **A SLICE pad plays only its slice** | PADS, set a pad to SLC, hold it | It stops at the slice end — not the rest of the buffer | `note_len` reaching `\mangler_voice_slice` |
| 5.4 | **CHOP** | Record a drum loop. PARAMS > `chop to transients` | Page says "CHOP - n SLICES ON THE HITS"; dividers are **uneven**; pads land on the hits | `Mpages.transient_cuts` |
| 5.5 | Chop wrap | With fewer than 8 slices | Cells label the slice they play (`1 2 3 4 5 1 2 3`) | `pad_cut`'s modulo |
| 5.6 | Chop is dropped with its audio | CHOP, then CLR or load a sample | Back to even eighths | `ctx.pads_uncut` |
| 5.7 | **TIGHTEN** | Record leaving silence at the front. PARAMS > `tighten window to sound` | Window pulls in onto the sound; maiden reports both durations | `Mpages.onset_bounds` |
| 5.8 | TIGHTEN on silence | Fire it on an empty window | "window is silent, left alone" — window unchanged | The silence refusal |
| 5.9 | PRINT round-trip | PRINT a 2-bar mix | Comes back as the take, drawn and windowed | The system-tape wav must be loadable |

---

## Stage 6 — Control surface

| # | Check | Pass | Suspect |
|---|---|---|---|
| 6.1 | Tap vs hold at the 5-frame line | Tap latches, hold punches | `TAP_FRAMES` |
| 6.2 | **Tap a lit key to cancel it** | It cancels — and does **not** re-arm | `st.unlatched` |
| 6.3 | MIX ENG / TAPE | Mutually exclusive; crossfader returns to true centre | The throw engine's shared-param rule |
| 6.4 | FILTER OPEN, DELAY INF/KILL, REVERB WASH | Each round-trips | — |
| 6.5 | REVERB BLOOM | Shimmer **increases** (never drops) | The surge law |
| 6.6 | Throw, then recall a scene, then un-latch | Un-latch does **not** overwrite the recalled value; the pill goes dark | `ctx.throws_forget` |
| 6.7 | SCENE peek / commit / ◄ / chaos release | As designed | — |
| 6.8 | **Morph a tape loop fast** | No head jump / no 100ms collapse | The morph's `EDGE_PAIRS` order |
| 6.9 | MOTION: record a sweep from a real **encoder** | It captures (polling, not call-interception) | `capture_poll` |
| 6.10 | **MOTION overdub** | Arm again, move a *second* knob — **the first lane survives** | `last_val` readback |
| 6.11 | MOTION with `motion_len` shortened | The **end** of the gesture still plays | `src_of` endpoints |
| 6.12 | ◇ purity mark | Lights only at full wet on an unmangled take; dark at the 0.5 default | `purity()` — it is *supposed* to be rare now |
| 6.13 | Grid: hold a note pad, toggle note input off, release | **No stuck voice** | The press-only gate |
| 6.14 | Grid: two-finger rack/scene pads | One release doesn't kill the other's audition/peek | Per-pad ownership |
| 6.15 | Launchpad colours | Semantic hues, no flicker | The reused SysEx buffer |

---

## Stage 7 — Persistence

| # | Check | Pass |
|---|---|---|
| 7.1 | PSET SAVE/LOAD round-trip | Take, tape, scenes, pad locks, **and the chop** all return |
| 7.2 | Empty tape in a pset | Loading **clears** the tape — no resurrection from the live buffer |
| 7.3 | CLR a loaded sample, save, reload | The sample does **not** come back (`sample_file` cleared) |
| 7.4 | Pre-S22 pset | Loads without resurrecting a buffer |

---

## Stage 8 — Performance

The one measurement that matters on a Pi 4.

| # | Check | Pass | Suspect |
|---|---|---|---|
| 8.1 | %CPU at rest, `rev_mix` 0 | Reverb synth is **not** running | The spawn/free gate |
| 8.2 | Hold an 8-voice PADS chord in GRAIN | No xruns | **The known watch item**: `Dust.ar`/`TRand.ar` cost real CPU across drone + 8 voices. If this fails, that is the first suspect |
| 8.3 | Sweep a scene morph | No xruns; no zipper | The 15fps coalescing |
| 8.4 | Load a 60s 24-bit sample | Waveform draws in progressively; no hitch | Async `load_wave` |

---

## Stage 9 — Layers (S25)

Only on the `layers` branch. No engine change, so the count is still 65.

| # | Check | Do | Pass | Suspect |
|---|---|---|---|---|
| 9.1 | Two decks sound | Record the engine take. Record LAYER 1 against it. | Both play, independently | |
| 9.2 | They drift | LAYER 1 at rate 0.5, LAYER 2 at 1 | They drift and re-sync; no clicks | The rate slew |
| 9.3 | Overdub vs replace | REC with `pre` 1, then with `pre` 0 | 1 stacks, 0 replaces | |
| 9.4 | **Erase is region-scoped** | K1+K3 on LAYERS | **Only** the selected layer is wiped — the tape and the other layer are untouched | `sc.buffer_clear_region`. This is the one collision that makes layers not purely additive |
| 9.5 | STOP reaches them | K1+K2 | All four decks silence; START restores the exact mix | `ctx.layers_relevel` |
| 9.6 | PSET round-trip | Save, reload, load | Both layers' audio returns; an empty layer does not resurrect | |
| 9.7 | **%CPU with everything running** | Four decks plus a granular drone | No xruns | The number that decides whether a third layer is ever worth adding |

## When it passes

Move the **CURRENT STAGE** marker at the top of `CLAUDE.md` to record the new
confirmed state — the date and `count: 65`. That marker is what tells the next
session which changes are trustworthy, and it is the only reason this document
could be written at all.

If something fails, the "suspect" column is a starting point, not a verdict.
Note what you actually heard; a symptom described precisely is worth more than a
guess at the cause.
