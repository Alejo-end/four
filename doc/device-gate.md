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
| 1.1 | E1 through all **11** pages | Every page draws; no black screen | A black screen is a Lua error in `redraw` — scroll maiden below `<ok>` for the traceback |
| 1.2 | Page order | TAKE VOICE · TAPE LAYERS · FILTER DELAY REVERB · MIX · PADS MOTION SCENE | — |
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
| 2.1 | **Erosion respects STOP** | VOICE in PLAY, hold K1, E2 = `erode` ~0.5, window short (~0.5s). K1+K2 STOP. Leave 5 min. START. | The take is *unchanged* | The `level` gate in `\mangler_play` — `level` must be reaching the play synth via `playParams` |
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
| 4.15 | `erode` 0, leave running | Take **bit-identical** after minutes | A stray `\mangler_erode` (stage 14) |
| 4.16 | `erode` ~0.3 | Darkens over passes, no runaway | — |
| 4.17 | `erode` at speed 2 and speed −1 | Ages at the **same rate** | The constant-rate head in `\mangler_erode` |
| 4.18 | Raise `regen` while `erode` > 0 | `erode` drops to 0 (and vice versa) | The param-layer interlock |
| 4.19 | VOICE K2 = HEAL (PLAY mode) | Round-trip; **`regen` comes back too** | The HEAL throw snapshots `regen` |

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
| 6.12 | ◇ purity mark | Lights only at full wet on an unmangled take; dark at the 0.5 default, dark while the tape or a layer is audible, dark with pan off center | `purity()` — it is *supposed* to be rare now; tools/test_purity.lua walks every reason offscreen |
| 6.13 | Grid: hold a note pad, toggle note input off, release | **No stuck voice** | The press-only gate |
| 6.14 | Grid: two-finger scene pads | One release doesn't kill the other's audition/peek | Per-pad ownership |
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

No engine change, so the count is still 65.

| # | Check | Do | Pass | Suspect |
|---|---|---|---|---|
| 9.1 | Two decks sound | Record the engine take. Record LAYER 1 against it. | Both play, independently | |
| 9.2 | They drift | LAYER 1 at rate 0.5, LAYER 2 at 1 | They drift and re-sync; no clicks | The rate slew |
| 9.3 | Overdub vs replace | REC with `pre` 1, then with `pre` 0 | 1 stacks, 0 replaces | |
| 9.4 | **Erase is region-scoped** | K1+K3 on LAYERS | **Only** the selected layer is wiped — the tape and the other layer are untouched | `sc.buffer_clear_region`. This is the one collision that makes layers not purely additive |
| 9.5 | STOP reaches them | K1+K2 | All four decks silence; START restores the exact mix | `ctx.layers_relevel` |
| 9.6 | PSET round-trip | Save, reload, load | Both layers' audio returns; an empty layer does not resurrect | |
| 9.7 | Grid workspace | On LAYERS, rows 3-4 | A two-pad span sets THAT deck's loop; row 5 arms, row 6 mutes (x1-2) and snaps (x4-5); the other deck is untouched | |
| 9.8 | **%CPU with everything running** | Four decks plus a granular drone | No xruns | The number that decides whether a third layer is ever worth adding |

## Stage 10 — The spawn/free delay + true STOP + clear (the engine batch after the fold)

Engine changes with NO new command — the count must STILL read **65** (stage 0
already checked it; a different number here means a stray command).

| # | Check | Do | Pass | Suspect |
|---|---|---|---|---|
| 10.1 | The delay still delays | Take playing, raise `delay_mix`, ride `delay_time`/`delay_fb` | Echoes as before, times glide, repeats darken | The `\mangler_delay` split: send/return buses, `updateDelay` |
| 10.2 | **%CPU drops at rest** | `delay_mix` 0, `rev_mix` 0, watch %CPU | Lower than the pre-split build in the same state | The whole point of the split |
| 10.3 | The dub hold survives KILL | INF (DELAY K2), feed it a phrase, then KILL (K3), wait, un-KILL | The spinning loop is still there | The `delay_fb > 0.9` keep-alive in `updateDelay` |
| 10.4 | Mix up from rest is clean | From silence at mix 0, raise `delay_mix` | No click on spawn; echoes build from NOW (the line starts empty — accepted trade) | |
| 10.5 | **STOP truly halts** | Play the take + tape + a layer, K1+K2 | Every on-screen head FREEZES; no click. START: everything resumes from the exact spot, decks still in their drifted relationship | `winRead`'s `(run > 0.001)`; the stop action's transport re-sends |
| 10.6 | STOP pauses an armed take | Arm REC mid-phrase, K1+K2, wait, K1+K2 again | The write head freezes and resumes; the take has no gap of silence printed | The `engine.rec` gate in the stop/rec actions |
| 10.7 | Full tape throw pauses the drone head | MIX K3 (TAPE throw), watch VOICE/TAKE playheads | The engine head freezes while thrown, resumes on release — stated behavior, same law as erosion/regen | If this feels wrong in play, say so: the alternative is a dedicated run flag (a new command) |
| 10.8 | **Clear is silence** | Echoes + a long reverb tail ringing, then K1+K3 hold on TAKE (erase) | The tails CUT with the take; with `regen` up beforehand, nothing re-records into the cleared buffer | The `\clear` flush; `clear_recording`'s regen zero |

## Stage 11: the snap and quality batch

Engine changes with NO new command, so the count must STILL read **65**. The
layer work is Lua only.

| # | Check | Do | Pass | Suspect |
|---|---|---|---|---|
| 11.1 | **A fresh layer loops what you played** | Empty LAYER 1. K2 (REC), play four bars, K2 again | It loops those four bars, NOT the whole 60 second region | `Mdeck.arm_loop` / `close_loop`; the head must land back at the loop start |
| 11.2 | A layer with audio overdubs | K2 again on the same deck, play over it | The loop length does not change; the new pass stacks | The `d.any` test in `arm_loop` |
| 11.3 | The automatic snap is quiet when it should be | Play a length nowhere near the take's | The loop stays exactly what you played, no message | The 6% tolerance |
| 11.4 | ...and lands when it should | Play roughly the take's length, or half it | The loop rounds onto it and the page says `L1 4.31>4.00S 1/2 x TAKE` | `ctx.layer_quantize` |
| 11.5 | **Two decks stay locked** | Snap LAYER 2 against LAYER 1, leave them running five minutes | They are still in phase | If they walk, the snapped lengths were not an exact ratio |
| 11.6 | Forced SNAP | MIDI-map `lay1_snap` to a footswitch, or grid row 6 x4/x5 | Stomping it snaps the selected deck; the page names the ratio and the reference | |
| 11.6b | SNAP refuses out loud | Park a loop hard against the region end (loop start to max), then SNAP | It says `NO ROOM TO SNAP` rather than silently doing nothing or inventing a 100ms loop | `ctx.layer_snap`'s room check |
| 11.7 | The seam is audible | `lay1_fade` to 0.001 vs 0.2 on a drum loop | Short is a hard downbeat, long is a blend | `sc.fade_time` |
| 11.8 | Width | `lay2_width` to 0 | The deck collapses to the centre; LAYER 1 stays wide | `sc.pan` |
| 11.9 | **A 24-bit take round-trips** | Record, PSET save, CLR, PSET load | The take returns; `take-N_L.wav` is 24 bit and roughly 1.5x the old size | `write_take`'s `int24` |
| 11.10 | Export is 24-bit and browsable | `export_take` | One stereo 24-bit wav in the audio dir; it reloads through LOAD SAMPLE | `interleave_wav` follows the header now |
| 11.11 | **A 96k or 88.2k sample imports clean** | Load one through LOAD SAMPLE | In tune, and no whistling or gritty top end | The windowed sinc's stopband. Cubic folded everything above 24 kHz into the audible band |
| 11.12 | Import is not slower than patience | Load a long off-rate file, and separately a 96k one | The screen stays live throughout. Budget, measured on a dev Mac for 10s of stereo: 44.1k 0.68s (1.9x the old cubic), 88.2k 1.17s (2.3x), 96k 1.25s (2.5x), 192k 2.34s (3.2x). **A Pi will take tens of seconds for a minute of audio, and longer coming down than up** | If that is too slow, `SINC_TAPS` is the knob. The kernel widens as 1/cutoff, so DOWNsampling costs the most, which is the case 11.11 is about. Mac numbers only; the Pi is NOT measured |
| 11.13 | The resample blend is clean | `resample` at 0.5, record, play the take back | No hollow phasey colour on the blend | The pre-limiter tap. This is the comb the notes parked for a device measurement |
| 11.14 | Delay and shimmer saturate warmer | INF the delay and slam it; shimmer up with a hot source | It thickens rather than fraying | `tanh` replaced `softclip` in both recirculating loops. If a hold now decays where it used to sustain, that is the earlier knee, so say so |

## Stage 12: the full-review batch (Lua only)

No engine change. A save and reload is enough on its own, but this rides the
same RESTART as everything above. Each row is a bug that was proven offscreen
and fixed; the device check is that the fix FEELS right.

| # | Check | Do | Pass | Suspect |
|---|---|---|---|---|
| 12.1 | **A late conversion cannot eat a take** | Load a 44.1k sample (it converts in the background), and record a phrase straight away | When the conversion finishes, the maiden log says it was dropped; your phrase is still the take | `take_gen` in `load_at_rate` |
| 12.2 | The first take of a session is the take | Fresh boot, record 4s, SNAP on TAKE | SNAP finds the take; a PSET save writes a small file | The `rec_open` edge in the rec action |
| 12.3 | LAYERS keys stay on their deck | Hold K2 (REC) on L1, turn E2 to L2, let go | L1 stops recording | `LAYER_KEYS` |
| 12.4 | A saved tape loop survives its first disarm | Save a PSET while the tape records; load it; tap TAPE K2 | The loop stays as saved | `tape_arm_phase` reset in `action_read` |
| 12.5 | A mis-tapped tape REC keeps the loop | Set a tight tape loop, tap REC twice quickly | The loop is unchanged | `tape_arm_was` |
| 12.6 | A long tape seam on a short loop | Tape loop 0.3s, `tape_fade` 0.4 | The loop stays audible | `Mtape.set_fade` through `D.update_fade` |
| 12.7 | **STOP stills the pictures** | K1+K2 on TAPE and on VOICE | The reels stop and the VOICE texture lies flat; the grid playheads dim | `body_TAPE`, `body_VOICE`, `draw_main_ws` |
| 12.8 | The grid keeps the screen awake | Play only the grid for 3 minutes | The screen does not dim | `ctx.touch_input` |
| 12.9 | A float WAV from ffmpeg | Load a 32-bit float 96k render | It plays in tune at the right level and draws a real waveform | The extensible SubFormat parse |
| 12.10 | A right-only stereo loop draws | Load a hard-panned stereo loop of about 5s | The strip shows the hits | The odd preview stride |
| 12.11 | Scenes and the orbit | Orbit on; hold K1+K3 on SCENE | The slot you pressed on is cleared, not the one the orbit moved to | `ctx.k13_slot` |
| 12.12 | A recall after a scene captured on an empty layer | Capture, record 4s into L1, recall | L1 loops the 4s, not 60s | `clamp_stored` deck extents |
| 12.13 | MOTION with long lanes | Record 60s of four knobs, stay on MOTION | The screen and the encoders stay responsive | `body_MOTION`'s per-column drawing |
| 12.14 | Import keeps the screen live | Load a 96k file | The screen updates smoothly while it converts | `convert_sr` yields every block |

## Stage 13: the additions (Lua only)

No engine change. Each row is tested offscreen; the device check is how it
feels and that the norns calls behave as the stubs assume.

| # | Check | Do | Pass | Suspect |
|---|---|---|---|---|
| 13.1 | **The motion loop rides the PSET** | Record a gesture, save a PSET, load another, load it back | The loop returns and plays; a saved arm does not start recording | `Mmotion.pset_write` / `pset_read` |
| 13.2 | GLIDE recall | PARAMS > scenes > recall quantize GLIDE, glide beats 4, recall a slot | The sound sweeps over a bar and lands; the ◄ cell holds where it began | `M.glide`, `glide_tick` |
| 13.3 | The orbit yields | Orbit on, then ride K1+E1 | The wander stands still under your hand and resumes two seconds after you let go | `orbit_tick`'s `hand_at` |
| 13.4 | A synced delay stays synced | `delay_sync` 1/4, then recall a scene with a different delay time | The echoes stay on the beat | `sync_delay_time` |
| 13.5 | A short deck saves small | A 4s layer loop, PSET save | `lay1-N.wav` is about 4s, not 60; loading it back plays the loop with nothing after it | `Mdeck.save_secs`, the clear before the read |
| 13.6 | The take strip follows erosion | Erode a take for a minute, then erode to 0 | The TAKE strip redraws darker within a few seconds | `ctx.refresh_take_strip` |
| 13.7 | **Launchpad hot-plug** | Start with no Launchpad, then plug the Mini MK3 in; later unplug it | It lights and plays the moment it is plugged in; unplugged, nothing hangs | `Mgrid.hotplug`, norns' `midi.add` / `midi.remove` |
| 13.8 | Launchpad arrows | Left/right, then up/down | Left/right step the page (the name pops), up/down step the scene slot | The CC numbers 91 to 94 in Programmer mode |
| 13.9 | Grid piano in pad mode | Pad input on, play the grid piano | The keys whose pad sounds light orange | `draw_spine`'s `pad_on` |
| 13.10 | A frame error does not freeze | (only if one happens) | maiden prints `frame error` and the screen keeps moving | The `pcall` around `frame_tick` |

## Stage 14: erosion in its own synth (engine)

One engine change with no new command, so maiden must still read `count: 65`.
The erosion head moved out of the PLAY voice into `\mangler_erode`, which runs
only while `erode` is above 0 in PLAY mode. To list the running synths, type
`Server.default.queryAllNodes` in maiden's SC tab.

| # | Check | Do | Pass | Suspect |
|---|---|---|---|---|
| 14.1 | **At rest nothing writes** | PLAY, `erode` 0, list the nodes | No `mangler_erode` in the list | `updateErode` |
| 14.2 | Erosion still erodes | A take in PLAY, VOICE K1+E2 to about 0.5, listen over a few passes | It darkens pass by pass as before, GEN counts, and the node list shows `mangler_erode` | `\mangler_erode`, `winBounds` |
| 14.3 | **No click in or out** | A loud sustained take, `erode` 1, then VOICE K2 (HEAL) and release, a few times | No click is printed into the take: the next passes play smoothly where the switches happened | The 50ms `gate` fade |
| 14.4 | Mode switch | `erode` up, VOICE K3 once (GRAIN), then three more times (WARP, PV, PLAY) | The node is gone in GRAIN, WARP and PV and back in PLAY. The other modes do not darken the take | `setMode`'s `updateErode` |
| 14.5 | STOP holds the head | `erode` up, K1+K2, wait ten seconds, K1+K2 again | GEN and the pass bar hold during the STOP. Later passes age evenly, with no lighter stretch | The head's `run` gate |
| 14.6 | %CPU at rest | PLAY, `erode` 0, watch %CPU | Equal to or lower than the previous build in the same state | The point of the split |

## Stage 15: the review fixes (Lua only)

No engine change. Each row is tested offscreen. The device check is that the
norns calls behave as the stubs assume, and how it feels.

| # | Check | Do | Pass | Suspect |
|---|---|---|---|---|
| 15.1 | **CHOP right after erosion** | Erode a take in PLAY, set `erode` to 0, and fire CHOP about two seconds later | maiden prints `take dump queued behind the strip repaint`, then the CHOP result. The pads land on the attacks | `take_to_wav`'s `export_next` |
| 15.2 | A short HEAL dumps nothing | Erode in PLAY, hold VOICE K2 (HEAL) for half a second and release, then fire CHOP at once | maiden prints the CHOP result with no `queued` line | `tick_take_strip`'s second of quiet |
| 15.3 | **Launchpad unplug** | With the Mini MK3 driving, unplug it. With midigrid and a second controller, try it with that controller attached too | maiden shows no error. The second controller takes over, and its pads do not move `pitch` | `Mgrid.hotplug(gone)`, `reconnect_due`, `midigrid_loaded` |
| 15.4 | GLIDE tap | Recall quantize GLIDE, glide beats 4, tap K2 on a filled slot | The sound crossfades over a bar. Nothing jumps at the tap | `tick_keys`' tap wait |
| 15.5 | GLIDE through chaos | Hold the chaos throw, recall a slot under GLIDE, release the throw mid-glide | The glide goes on and lands the scene | The GLIDE branch of `M.recall` |
| 15.6 | A long peek under the orbit | Orbit on, hold K2 on a filled slot for three seconds, release | The sound sweeps back to where it was before the peek | `orbit_tick` |
| 15.7 | An off-rate deck file in a PSET | Delete `lay1-N.wav` beside a PSET whose L1 came from a 44.1k file, then load the PSET | L1 is silent for a moment, then plays the file in tune | `ctx.layer_load`'s clear |
| 15.8 | Two off-rate loads in a row | Load a long 44.1k sample, then another a few seconds later | The second one loads soon after it is picked. maiden says the first was dropped | `load_at_rate`'s generation check |
| 15.9 | BEAT tap | Recall quantize BEAT, a clock running, tap K2 on a filled slot between two beats | Nothing moves at the tap. The scene lands on the beat | `tick_keys`' tap wait |
| 15.10 | A regen flick | MIDI-map `regen`, flick the CC up and straight back to 0 on a long take | About a second later maiden shows no error and the take strip redraws | `strip_wrote` in the regen action |
| 15.11 | An off-rate layer file by hand | L1 playing, then PARAMS > layers > L1 load file, a 44.1k wav | L1 goes silent at once, then plays the new file in tune | `ctx.layer_load`'s clear |

## Stage 16: the additions (Lua only)

No engine change. Each row is tested offscreen. The device check is the feel,
and that the engine polls behave as the stubs assume.

| # | Check | Do | Pass | Suspect |
|---|---|---|---|---|
| 16.1 | **Start on sound** | PARAMS > take - record > start on sound on. K2, wait three seconds in silence, play a hard attack, K2 | TAKE shows WAIT until you play. The loop starts on the attack, with the attack whole, and maiden prints `sound at` | `tick_rec_wait`, `REC_PREROLL` |
| 16.2 | The threshold | Raise `sound threshold` until a quiet note no longer starts the take | The quiet note keeps WAIT; a louder one starts it | `rec_thresh`, the `rec_amp` poll |
| 16.3 | A short hit | Start on sound on, K2, wait, one drum hit, K2 straight after | The loop is the hit, not the previous take | The `rec_moved` branch of the rec stop |
| 16.4 | **Sequencer drone** | Set four pads to different pitches (PADS E3), GRAIN voice, `voice release` about 2s, then `sequencer run` on | A pad a bar, overlapping into a slow progression. PADS shows the steps, the current one bright | `Mseq.fire`, `clock.sync` |
| 16.5 | Sequencer on the clock | Run it with 1/16 steps and 5 of 8, change the tempo, then stop and start it | It stays on the beat through the tempo change, and starts again on the bar | The beat count in `Mseq.fire` |
| 16.6 | Sequencer stop | While it plays, K1+K2 (STOP), then `sequencer run` off | Silence at once, no voice left hanging after the stop or the run off | `release()`, `Mseq.stop` |
| 16.7 | **A modulator** | LFO 1 target cutoff, SINE, 1 BAR, depth 0.4. Turn cutoff by hand while it runs | The filter breathes once a bar, around where your hand leaves it; the knob does not move by itself. The header shows LF | `Mlfo.tick`, `ctx.eng_map` |
| 16.8 | Ducking | LFO 2 target `eng level` (or reverb mix), ENV, depth -0.6, play the gear | The level dips while you play and comes back when you stop | The envelope in `Mlfo.tick`, the `amp_in` polls |
| 16.9 | Reverb on an LFO | LFO 2 target reverb mix with the mix at 0, SQUARE, 2 Hz, depth 0.4 | The reverb pulses with no clicks and no CPU climb; depth 0 frees it again (node list) | `FLOOR` in lib/mlfo.lua |
| 16.10 | **A window on the bar** | A take in PLAY, `win length` 1 BAR, the delay synced to 1/4. Move the window start with E2 | The loop is exactly a bar and stays on the echoes. E2 slides it; the end follows. TAKE shows 1 BAR | `sync_window_len` |
| 16.11 | Tempo change | With the window locked, change the clock tempo | The loop re-times to the new bar length without a click storm | The 0.5% write tolerance |
| 16.12 | SNAP under the lock | Locked to 1 BAR, TAKE K3, then K3 again | It opens to the take, then goes back to the bar | `apply_window_len` only on its moments |
| 16.13 | **Take undo** | Record a take, record a second one over it, then PARAMS > undo take, then again | The first take comes back with its window, then the second | `ctx.take_undo`, the `undo-*` pairs |
| 16.14 | Undo a clear | K1+K3 hold on TAKE (erase), then undo take | The take comes back | The `empty` state |
| 16.15 | **CC out** | `out source` MORPH, a synth on MIDI port 1 learning the CC; run the orbit | The synth's knob follows the morph; a still morph sends nothing (a MIDI monitor) | `Mout.tick`, `midi.connect` |
| 16.16 | crow out | A crow on USB, `out to crow 1` on, `out source` LFO 1 | Output 1 swings 0 to 5 V at the LFO's rate | `crow.output[1].volts` |

## When it passes

Move the **CURRENT STAGE** marker at the top of `CLAUDE.md` to record the new
confirmed state — the date and `count: 65`. That marker is what tells the next
session which changes are trustworthy, and it is the only reason this document
could be written at all.

If something fails, the "suspect" column is a starting point, not a verdict.
Note what you actually heard; a symptom described precisely is worth more than a
guess at the cause.
