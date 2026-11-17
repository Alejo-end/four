# Device gate: one walkthrough

**Where it stands (2026-11-15).** The gate has not passed since **2026-07-16 at
`count: 63`**, under mangler. On 2026-11-06 `test/device/gate.py` ran it at `count: 66`
with no ears, which is not a pass (doc/measurements/2026-11-06/README.md). It has not run
on four. The STATUS block of CLAUDE.md says what is on the device now.

This gate was written for mangler, the one-track instrument. For four:

- Stage 0 expects `count: 198` and `Engine_Four.sc`, and stage 1 the twelve pages.
- The layer decks are gone (four, thirteenth change). Their rows say REMOVED and keep
  their numbers, so the other rows keep theirs: stage 9, 11.1 to 11.8, 12.3, 12.12, 13.5,
  15.7, 15.11 and 18.1. `test/device/gate.py` runs none of them and does not report
  them (four, twenty-fourth change).
- Every send to the delay and the reverb starts at 0 (four, nineteenth change). For a
  delay or reverb row, first open track 1's sends: TRACKS, hold K1, D and R.
- Stages 1 to 18 test track 1. Stage 19 is four's own work: tracks 2 to 4, the lanes
  and the effect slots, the FourStretch voices, the sends, the room, the bucket brigade
  and the CPU budget. The earlier device measurements are in doc/measurements/2026-11-12/
  and 2026-11-13/, and the list to listen to is in doc/plan.md, Phase 2.

This folds those scattered per-change gates into one ordered pass. The order is
deliberate — **the checks that would invalidate everything else come first**, and
checks that share a setup are grouped so you are not re-recording a take five
times.

Each check says what PASS looks like and, when it fails, **which change to
suspect**. That pointer is the part worth having: with a month of batched work,
"something sounds wrong" is not a useful bug report.

`test/device/gate.py` runs what a computer can judge, on a connected device. The
results from 2026-11-06 are in doc/measurements/2026-11-06/README.md. Those marked
`measured` or `you` still need a person.

**Work top to bottom. If a stage fails, stop there** — later stages assume the
earlier ones held, and a false failure downstream will cost you an hour.

---

## Stage 0 — Deploy · FAIL-STOP

```sh
rsync -av --delete --exclude='.git' --exclude='.claude' ./ <norns>:~/dust/code/four/
```

Then on the norns: **SYSTEM > RESTART**. Not a script reload — sclang only
recompiles the class library at startup, so a reload runs the *old* engine
against the new Lua, which is the most confusing possible state.

| # | Check | Pass |
|---|---|---|
| 0.1 | Only one `Engine_Four.sc` on the device | `find ~/dust/code -name 'Engine_Four.sc'` returns exactly one path |
| 0.2 | Script loads | No hang on LOADING |
| 0.3 | **Command count** | maiden shows `Engine.register_commands; count: 198` |

**0.3 is the whole stage.** A lower count means that the old engine is still live, and
every sound check below is then meaningless: restart again. Any other count means that
something changed by mistake. Do not continue.

If it hangs on LOADING with a clean matron log, **look at maiden's SC tab** — SC
errors land there, not in matron. A duplicate engine class is the classic cause.

---

## Stage 1 — Does it live at all?

| # | Check | Pass | Suspect on failure |
|---|---|---|---|
| 1.1 | E1 through all **12** pages | Every page draws. No black screen | A black screen is a Lua error in `redraw`. Scroll maiden below `<ok>` for the traceback |
| 1.2 | Page order | TAKE VOICE TRACKS · TAPE · FILTER EFFECT DELAY REVERB · MIX · PADS MOTION SCENE | |
| 1.3 | SC tab clean | No errors after load. With the plugin, the log says `four: FourStretch on` and `four: CLOUD is FourCloud` | The guarded plugins (FourStretch with FourCloud, JPverb, MiClouds, DFM1) fall back without a word. A *posted* error means a wrong argument order |
| 1.4 | Input reaches the meter | TAKE's IN meter moves with your source | Levels / `monitor_level`, not the engine |

---

## Stage 2 — The three that destroy audio · HIGHEST STAKES

These are new, unheard, and each one silently loses a recording. Do them before
anything that costs you a good take.

**Setup:** record a phrase you can recognise (TAKE, K2, play ~10s, K2). The
window snaps to it and it loops back dry.

| # | Check | Do | Pass | Suspect |
|---|---|---|---|---|
| 2.1 | **Erosion respects STOP** | VOICE in PLAY, hold K1, E2 = `erode` ~0.5, window short (~0.5s). K1+K2 STOP. Leave 5 min. START. | The take is *unchanged* | The `level` gate in `\four_play`: `level` must reach the play synth through `playParams` |
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
| 3.2 | K1+K3 tapped = DRY | Delay/reverb/shimmer/drive/crush/clouds-fb to zero, the effect slot OFF, filter opens | `ctx.fx_dry` |
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
| 4.4 | **Is it noisy?** | Clean until `drive` asks for grit | DFM1's input gain and `dfmTrim`, which replaced the 2× makeup (four, tenth change). If noisy, turn `grain_level` down. If that cleans it up, the cause is confirmed |

### 4b · Reverb (send-style now, spawn/free)

Open track 1's reverb send first: TRACKS, hold K1, R.

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
| 4.15 | `erode` 0, leave running | Take **bit-identical** after minutes | A stray `\four_erode` (stage 14) |
| 4.16 | `erode` ~0.3 | Darkens over passes, no runaway | — |
| 4.17 | `erode` at speed 2 and speed −1 | Ages at the **same rate** | The constant-rate head in `\four_erode` |
| 4.18 | Raise `regen` while `erode` > 0 | `erode` drops to 0 (and vice versa) | The param-layer interlock |
| 4.19 | VOICE K2 = HEAL (PLAY mode) | Round-trip; **`regen` comes back too** | The HEAL throw snapshots `regen` |

---

## Stage 5 — The new instrument features

| # | Check | Do | Pass | Suspect |
|---|---|---|---|---|
| 5.1 | **44.1k loads in tune** | PARAMS > load sample, pick a 44.1k wav | Maiden says "resampling to 48000"; it plays at the **right pitch** | `Mpages.convert_sr` |
| 5.2 | 48k loads untouched | Load a 48k file | No resample message; instant | The rate probe |
| 5.3 | **A SLICE pad plays only its slice** | PADS, set a pad to SLC, hold it | It stops at the slice end, not at the end of the buffer | `note_len` reaching `\four_voice_slice` |
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
| 6.12 | ◇ purity mark | Lights only at full wet on an unmangled take. Dark at the 0.5 default, dark while the tape is audible, dark with pan off center | `purity()`. It is *meant* to be rare now. test/test_purity.lua walks every reason offscreen |
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

## Stage 9: Layers (S25). REMOVED

Checks 9.1 to 9.8 tested the two layer decks. The decks are gone (four, thirteenth
change), so this stage has nothing to check. Its number stays.

## Stage 10 — The spawn/free delay + true STOP + clear (the engine batch after the fold)

Engine changes with NO new command. The count is the one that stage 0 read. Open
track 1's delay send first: TRACKS, hold K1, D.

| # | Check | Do | Pass | Suspect |
|---|---|---|---|---|
| 10.1 | The delay still delays | Take playing, raise `delay_mix`, ride `delay_time`/`delay_fb` | Echoes as before, times glide, repeats darken | The `\four_delay` split: send/return buses, `updateDelay` |
| 10.2 | **%CPU drops at rest** | `delay_mix` 0, `rev_mix` 0, watch %CPU | Lower than the pre-split build in the same state | The whole point of the split |
| 10.3 | The dub hold survives KILL | INF (DELAY K2), feed it a phrase, then KILL (K3), wait, un-KILL | The spinning loop is still there | The `delay_fb > 0.9` keep-alive in `updateDelay` |
| 10.4 | Mix up from rest is clean | From silence at mix 0, raise `delay_mix` | No click on spawn; echoes build from NOW (the line starts empty — accepted trade) | |
| 10.5 | **STOP truly halts** | Play the take and the tape, K1+K2 | Every head on the screen FREEZES, with no click. START: everything resumes from the exact spot, the take and the tape still in their drifted relationship | `winRead`'s `(run > 0.001)`, and the stop action's transport re-sends |
| 10.6 | STOP pauses an armed take | Arm REC mid-phrase, K1+K2, wait, K1+K2 again | The write head freezes and resumes; the take has no gap of silence printed | The `engine.rec` gate in the stop/rec actions |
| 10.7 | Full tape throw pauses the drone head | MIX K3 (TAPE throw), watch VOICE/TAKE playheads | The engine head freezes while thrown, resumes on release — stated behavior, same law as erosion/regen | If this feels wrong in play, say so: the alternative is a dedicated run flag (a new command) |
| 10.8 | **Clear is silence** | Echoes + a long reverb tail ringing, then K1+K3 hold on TAKE (erase) | The tails CUT with the take; with `regen` up beforehand, nothing re-records into the cleared buffer | The `\clear` flush; `clear_recording`'s regen zero |

## Stage 11: the snap and quality batch

Engine changes with NO new command, so the count is the one that stage 0 read.

| # | Check | Do | Pass | Suspect |
|---|---|---|---|---|
| 11.1 to 11.8 | REMOVED | The rows tested the layer decks: the loop pedal, SNAP, the seam and the width | | |
| 11.2d | **The tape's first pass loops** | On TAPE, `cut_source` dry and the voice OFF. K2, play a tone for three seconds, K2 again, then stop playing | The tape plays back the pass you played | The tape's loop-pedal law in lib/mtape.lua |
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
| 12.3 | REMOVED | It tested the LAYERS keys | | |
| 12.4 | A saved tape loop survives its first disarm | Save a PSET while the tape records; load it; tap TAPE K2 | The loop stays as saved | `tape_arm_phase` reset in `action_read` |
| 12.5 | A mis-tapped tape REC keeps the loop | Set a tight tape loop, tap REC twice quickly | The loop is unchanged | `tape_arm_was` |
| 12.6 | A long tape seam on a short loop | Tape loop 0.3s, `tape_fade` 0.4 | The loop stays audible | `Mtape.set_fade` through `D.update_fade` |
| 12.7 | **STOP stills the pictures** | K1+K2 on TAPE and on VOICE | The reels stop and the VOICE texture lies flat; the grid playheads dim | `body_TAPE`, `body_VOICE`, `draw_main_ws` |
| 12.8 | The grid keeps the screen awake | Play only the grid for 3 minutes | The screen does not dim | `ctx.touch_input` |
| 12.9 | A float WAV from ffmpeg | Load a 32-bit float 96k render | It plays in tune at the right level and draws a real waveform | The extensible SubFormat parse |
| 12.10 | A right-only stereo loop draws | Load a hard-panned stereo loop of about 5s | The strip shows the hits | The odd preview stride |
| 12.11 | Scenes and the orbit | Orbit on; hold K1+K3 on SCENE | The slot you pressed on is cleared, not the one the orbit moved to | `ctx.k13_slot` |
| 12.12 | REMOVED | It tested a scene recall on a layer deck | | |
| 12.13 | MOTION with long lanes | Record 60s of four knobs, stay on MOTION | The screen and the encoders stay responsive | `body_MOTION`'s per-column drawing |
| 12.14 | Import keeps the screen live | Load a 96k file | The screen updates smoothly while it converts | `convert_sr` yields every block |

## Stage 13: the additions (Lua only)

No engine change. Each row is tested offscreen; the device check is how it
feels and that the norns calls behave as the stubs assume.

| # | Check | Do | Pass | Suspect |
|---|---|---|---|---|
| 13.1 | **The motion loop rides the PSET** | Record a gesture, save a PSET, load another, load it back | The loop returns and plays; a saved arm does not start recording | `Mmotion.pset_write` / `pset_read` |
| 13.2 | GLIDE recall | PARAMS > scenes > recall quantize GLIDE, glide beats 4, recall a slot | The sound sweeps over a bar and lands; the ◄ cell holds where it began | `M.glide`, `glide_tick` |
| 13.3 | The orbit yields | Orbit on (PARAMS > orbit), then turn E3 on SCENE | The wander stands still under your hand and resumes two seconds after you let go | `orbit_tick`'s `hand_at` |
| 13.3b | The A and B crossfader | Capture slots 3 and 4. On SCENE, E2 to A 3, E3 to B 4, then hold K1 and sweep E3 both ways | The rail reads `A 3` and `4 B`, a small A marks cell 3; the fade at 0 sounds like scene 3, at the top like scene 4 (its morph-safe part), and back again with no jump | `M.morph`, `scene_slot_a` (four, thirty-third change) |
| 13.4 | A synced delay stays synced | `delay_sync` 1/4, then recall a scene with a different delay time | The echoes stay on the beat | `sync_delay_time` |
| 13.5 | REMOVED | It tested the saved file of a layer deck | | |
| 13.6 | The take strip follows erosion | Erode a take for a minute, then erode to 0 | The TAKE strip redraws darker within a few seconds | `ctx.refresh_take_strip` |
| 13.7 | **Launchpad hot-plug** | Start with no Launchpad, then plug the Mini MK3 in; later unplug it | It lights and plays the moment it is plugged in; unplugged, nothing hangs | `Mgrid.hotplug`, norns' `midi.add` / `midi.remove` |
| 13.8 | Launchpad arrows | Left/right, then up/down | Left/right step the page (the name pops), up/down step the scene slot | The CC numbers 91 to 94 in Programmer mode |
| 13.9 | Grid piano in pad mode | Pad input on, play the grid piano | The keys whose pad sounds light orange | `draw_spine`'s `pad_on` |
| 13.10 | A frame error does not freeze | (only if one happens) | maiden prints `frame error` and the screen keeps moving | The `pcall` around `frame_tick` |

## Stage 14: erosion in its own synth (engine)

One engine change with no new command, so the count is the one that stage 0 read.
The erosion head moved out of the PLAY voice into `\four_erode`, which runs
only while `erode` is above 0 in PLAY mode. To list the running synths, type
`Server.default.queryAllNodes` in maiden's SC tab.

| # | Check | Do | Pass | Suspect |
|---|---|---|---|---|
| 14.1 | **At rest nothing writes** | PLAY, `erode` 0, list the nodes | No `four_erode` in the list | `updateErode` |
| 14.2 | Erosion still erodes | A take in PLAY, VOICE K1+E2 to about 0.5, listen over a few passes | It darkens pass by pass as before, GEN counts, and the node list shows `four_erode` | `\four_erode`, `winBounds` |
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
| 15.7 | REMOVED | It tested a layer deck's file in a PSET | | |
| 15.8 | Two off-rate loads in a row | Load a long 44.1k sample, then another a few seconds later | The second one loads soon after it is picked. maiden says the first was dropped | `load_at_rate`'s generation check |
| 15.9 | BEAT tap | Recall quantize BEAT, a clock running, tap K2 on a filled slot between two beats | Nothing moves at the tap. The scene lands on the beat | `tick_keys`' tap wait |
| 15.10 | A regen flick | MIDI-map `regen`, flick the CC up and straight back to 0 on a long take | About a second later maiden shows no error and the take strip redraws | `strip_wrote` in the regen action |
| 15.11 | REMOVED | It tested a layer deck's file load | | |

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
| 16.8 | Ducking | LFO 2 target cutoff (or reverb mix), ENV, depth -0.6, play the gear | The level dips while you play and comes back when you stop | The envelope in `Mlfo.tick`, the `amp_in` polls |
| 16.9 | Reverb on an LFO | LFO 2 target reverb mix with the mix at 0, SQUARE, 2 Hz, depth 0.4 | The reverb pulses with no clicks and no CPU climb; depth 0 frees it again (node list) | `FLOOR` in lib/mlfo.lua |
| 16.10 | **A window on the bar** | A take in PLAY, `win length` 1 BAR, the delay synced to 1/4. Move the window start with E2 | The loop is exactly a bar and stays on the echoes. E2 slides it; the end follows. TAKE shows 1 BAR | `sync_window_len` |
| 16.11 | Tempo change | With the window locked, change the clock tempo | The loop re-times to the new bar length without a click storm | The 0.5% write tolerance |
| 16.12 | SNAP under the lock | Locked to 1 BAR, TAKE K3, then K3 again | It opens to the take, then goes back to the bar | `apply_window_len` only on its moments |
| 16.13 | **Take undo** | Record a take, record a second one over it, then PARAMS > undo take, then again | The first take comes back with its window, then the second | `ctx.take_undo`, the `undo-*` pairs |
| 16.14 | Undo a clear | K1+K3 hold on TAKE (erase), then undo take | The take comes back | The `empty` state |
| 16.15 | **CC out** | `out source` MORPH, a synth on MIDI port 1 learning the CC; run the orbit | The synth's knob follows the morph; a still morph sends nothing (a MIDI monitor) | `Mout.tick`, `midi.connect` |
| 16.16 | crow out | A crow on USB, `out to crow 1` on, `out source` LFO 1 | Output 1 swings 0 to 5 V at the LFO's rate | `crow.output[1].volts` |
| 16.17 | A hand on a swung knob | LFO 1 on cutoff, SINE, 1 Hz, depth 0.4; turn cutoff slowly with E2 on FILTER | A smooth sweep under the swing, no zipper or clicks | `Mlfo.swung` in the eng-control action |

## Stage 17: the beat repeat (ENGINE, a new command)

The one engine change since stage 14: a new synth, `\four_repeat`, and a
new command, `beat_repeat`. Do stage 0 again first: maiden must read
`count: 198`. MIDI-map `beat repeat` to a pad or a footswitch (it is a hold).

| # | Check | Do | Pass | Suspect |
|---|---|---|---|---|
| 17.1 | **It loads** | RESTART, load the script | `count: 198`, no error in the SC tab | `\four_repeat`, `updateRepeat`, the three `repBufs` |
| 17.2 | **A repeat on the beat** | A take playing, clock at 120, `repeat length` 1/8. Hold `beat repeat` for two bars | It starts on the next eighth and stutters that eighth until you let go, then the live sound returns. The header shows RP | `clock.sync` in `repeat_start`, the `first` pass |
| 17.3 | No clicks | Hold it over a sustained pad, then over drums | The loop points are smooth (the 3 ms fade); entering and leaving does not click | `fade`, the `gate` envelope |
| 17.4 | A roll | While holding, turn `repeat length` from 1/8 to 1/16 to 1/32, then spin it fast | Each step re-captures a shorter slice: a roll, no click or smear between steps | The three capture buffers, `updateRepeat` |
| 17.5 | STOP and clear | Hold a repeat, then K1+K2. Later hold one and erase the take (K1+K3 hold on TAKE) | STOP silences it at once. The erase stops it too | `repeat_release` in `stop_all`, `\clear` |
| 17.6 | Not recorded | Hold a repeat with `resample` up and record a pass, or PRINT | The take records the sound without the stutter | It sits after the record tap |
| 17.7 | %CPU | Watch %CPU with no repeat, then held | No change at rest; a small rise while held | The synth exists only while held |

## Stage 18: the screen fixes (Lua only)

No engine change. `test/test_screen.lua` reads these off the offscreen
pixels. The device check is that the OLED shows the same, and that the
frame rate holds with the GRAIN cloud at its densest.

| # | Check | Do | Pass | Suspect |
|---|---|---|---|---|
| 18.1 | REMOVED | It tested the header's L flag of a layer deck | | |
| 18.2 | A full header | Record the take, the tape and a motion lane at once, with FREEZE on, a beat repeat held, the sequencer running and a modulator set. Then go to REVERB, a six letter title | The recording track's cell blinks as a box. T and M blink their dots. The other flags show as letters or short bars, and nothing touches the page dots | `draw_tracks`, `draw_hflags` |
| 18.3 | The erase arc | On TAKE, hold K1+K3 and let go before it lands | The ring sits between ERASE and MOV and touches neither | `FOOT`, `keys_right` |
| 18.4 | The GRAIN cloud | VOICE in GRAIN. Turn SIZE and DENSITY, then spread, pan and jitter in PARAMS | Longer ticks with SIZE, more with DENSITY, wider with jitter; pan moves the cloud up (left) or down (right) and spread scatters it. At density 200 the screen does not stutter | `grain_cloud` |
| 18.5 | WET | Open DELAY and REVERB | The E2 word reads WET on both | `FULL` |
| 18.6 | HELD | PV freeze on, then step VOICE through its modes | HELD is bright in PV and GRAIN, dim in PLAY and WARP, and does not touch the PV chip | `body_VOICE` |
| 18.7 | One blink | Record on TAKE, TAPE and MOTION in turn, and run the orbit on SCENE | Only the header blinks: the recording track's cell and the dots of T and M. TAPE's REC chip, MOTION's REC chip and frame, the ORBIT chip and TAKE's WAIT are steady | the page chips |
| 18.8 | Readable text | Look at PADS (PLAY>DRONE, the voice count), SCENE (NOW), TAPE (the seconds) and MOTION (LOOP) from playing distance | All of it reads; an empty page's invitation is as bright as TAKE's, and VOICE with no take says EMPTY - REC ON TAKE | the level floor of 5 |
| 18.9 | Page dots on one line | Step E1 through all the pages | The dots stay on one straight row at an even spacing. No dot moves. Only the bright bar moves from slot to slot | `layout_dots` |
| 18.10 | The pattern on PADS | Open PADS with the sequencer stopped, then run it from the grid (PADS, row 6 pad 3); add and take hits with pads 6 and 5 | The pattern shows dim while stopped, bright with the moving step while it runs; the hits follow pads 5 and 6 | `body_PADS`, `pads_ws_key` |
| 18.11 | TAKE K3: tap and hold | With a take, tap K3; tap again. Then record a second pass and hold K3 for a second | A tap snaps the window and TAKE's top row says so; a second tap puts it back. Held, the arc fills beside UNDO and the first take comes back AT the arc, with a message; letting go does not snap | `tick_keys`, `ctx.hold_frame` |
| 18.12 | The abort zone | Hold K3 on TAKE for half a second and let go; hold it and turn E1 away and back; hold it and press K1 | Nothing happens any time, and no arc stays drawn | `st.fired`, `st.page` |
| 18.13 | What TAKE shows | Turn on start on sound and lock the window to a bar; turn E2 | "<" top left while an UNDO is kept, ON SND and 1 BAR top right; the START swell reads seconds | `take_top_row`, `fmt_value` |
| 18.14 | The repeat on the grid | A take playing on the clock. On TAKE, hold grid row 6 pad 3, then slide to pad 4 and back, then let go | A 1/8 repeat on the beat, a roll to 1/16 and back, the live sound when the last pad comes up. The header reads RP8, then RP16. The held pad is bright cyan | `repeat_key`, `RP_CH` |
| 18.15 | The modulators on MOTION | On MOTION, turn E2 past the last lane to LFO 1. Turn K1+E3 to CUTOFF, E3 up, K1+E2 to 1 BAR | The row reads 1>CUT and draws its wave with a moving dot; the filter swings on the bar; the footer reads LANE·LFO1, DEPTH, PERIOD, TARGET | `@mo_sel`, `MOTION_LFO`, `lfo_row` |
| 18.16 | Let a modulator go | With LFO 1 selected and moving, hold K1+K3 | The arc lands, the row goes OFF and flat, the swing stops, and no lane is cleared | MOTION's `erase` |

## Stage 19: four's own work (ENGINE and PLUGIN)

Four tracks, the lanes, the effect slots, the FourStretch voices, the sends, the room
and the bucket brigade. Most of it ran on the device without ears, and the bucket
brigade and the sends never ran there. Do stage 0 first: build the plugin on the norns
(ugen/README.md), install the binary alone in
`~/.local/share/SuperCollider/Extensions/FourStretch/` BEFORE the engine, RESTART, and
read `count: 198`. `python3 test/device/gate.py 19` runs it. It records a take on each
track: put a source on the input that you can tell apart.

The CPU figures are the busiest scsynth thread in `top -H`, the way
doc/measurements/2026-11-12/ and 2026-11-13/ read them. `Crone.server.avgCPU` is the load
of the whole JACK cycle, not the engine's. The budget is 60% of that thread.

| # | Check | Do | Pass | Suspect |
|---|---|---|---|---|
| 19.1 | **The plugin is in** | RESTART with the binary installed, load the script | `count: 198`. The SC log says `four: FourStretch on`, and `Crone.engine.hasStretch` is true. The plugin folder holds no `.sc` file | The install order. Without the line, every row below runs the stock voices, JPverb and the stock delay |
| 19.2 | K1+E1 picks the track | On any page, hold K1 and turn E1 right four steps, then left three | The focus goes 2, 3, 4, stays at 4, then 3, 2, 1. The track badge in the header and the page name pop show it | `enc` in four.lua, `track_sel` |
| 19.3 | TRACKS picks the focus | On TRACKS, turn E2 | `track_sel` follows E2 | `ENC_MAP.TRACKS` |
| 19.4 | **Each track has its own take** | Focus track 1 and record drums on TAKE (K2). Focus track 2 and record a tone, then tracks 3 and 4 | Each pass writes only the focused track's buffers. The other tracks' buffers stay the same, bit for bit. The four takes differ. The engine's `recIdx` and `opIdx` follow the focus | `rec_track`, `buf_track`, `ctx.focus_take` |
| 19.5 | Each track plays its own voice | Track 1 PLAY, track 2 GRAIN, track 3 WARP, track 4 PV. Then track 1 alone, and track 2 alone in PLAY | The node tree holds `four_play`, `four_grain`, `four_warp` and `four_pv`. Track 1 alone plays the drums and track 2 alone the tone | `setModeN`, `droneDef` |
| 19.6 | The pages edit the focused track | Focus track 3. On FILTER turn E2, on EFFECT tap K2, on TAKE turn E2 | `t3_cutoff`, `t3_effect` and `t3_pos_start` move. Track 1's `cutoff`, `effect` and `pos_start` do not | `tid`, `TRACK_PAGES` |
| 19.7 | **Only what is heard exists** | Track 2 in PLAY, the others OFF. Drive, crush and both effects at rest | One filter synth for each track (four in all), no `four_colour`, no `four_fx_*` | `buildLane` (twelfth change) |
| 19.8 | A filter family swap | Track 2's tone, cutoff 400. Step its `filter type` LP, HP, BP, LP | HP runs `four_filt_hi` in place of `four_filt_lo`. BP runs `four_filt_lo`. There are still four filter synths. No click at any step: the swap is a 20 ms crossfade | `laneFilter` |
| 19.9 | The colour synth | Track 2's drive up, crush up, drive to 0, crush to 0 | One `four_colour` while drive or crush is up. It goes about 300 ms after both are at 0 | `laneColour` |
| 19.10 | The effect synths | Track 2's `effect` CHORUS, `effect 2` RING, then both OFF | One `four_fx_mod` and one `four_fx_ring`, then no `four_fx_*` | `laneFx` |
| 19.11 | **Each effect type changes the sound** | Track 2's tone. Step `effect` through CHORUS, FLANGE, WOBBLE, RESON, RING and ECHO | Each type sounds different from OFF and from the others. RESON is within about 4 dB of the dry sound. FLANGE is the plugin's flanger (`four_fx_flange`), ECHO repeats the track | `fxSlot`, `four_fx_flange`, `four_fx_echo` (fourteenth change) |
| 19.12 | A type change does not click | On EFFECT, tap K2 ON, then tap K3 TYPE through every type while the tone plays | No click at any step: the change is a 50 ms crossfade | `laneFx`'s bundle |
| 19.13 | The second slot | Set track 2's `effect 2` in PARAMS. On EFFECT, turn K1+E2 and K1+E3 | K1+E2 turns `effect2_amt` and K1+E3 `effect2_rate`, and the first slot's knobs do not move. The second slot's name shows top right. The second slot changes the sound of the first | `ENC_MAP.EFFECT`, `body_EFFECT` |
| 19.14 | **PV, WARP and PLAY at pitch 1** | Track 2's tone at pitch 1, in PLAY, WARP and PV | The three play the same take at the same level, within 1 dB. Listen for warble or a smear | FourPV, FourWarp, FourRead, `exactRd` |
| 19.15 | **GRAIN's first grain** | Density 4. Start track 2's GRAIN and track 3's PLAY together. Then tap a grain pad with track 3's PLAY | The grain sounds with the PLAY, not a quarter of a second after it. Offline the first grain comes 1 to 1.6 ms after the press | `Impulse.ar(0)` in `\four_grain` and `\four_voice_grain` (twenty-second change) |
| 19.16 | CLOUD | Track 2 in CLOUD | It sounds. With the plugin (FourCloud) or mi-UGens the node is `four_clouds`, without either `four_grain` | `droneDef`, FourCloud, MiClouds |
| 19.17 | The voices' cost | Four tracks in PLAY, then WARP, PV and GRAIN, at pitch 1 | Record the thread for each. Compare with doc/measurements/2026-11-13/lanes.md and the sixteenth change | |
| 19.18 | **The sends start at 0** | A fresh script | `fx_dly`, `fx_rev`, every `t<n>_fx_dly` and `t<n>_fx_rev`, and `dly_rev` read 0 | `ROUTES` (nineteenth change) |
| 19.19 | A send at 0 gives no echo | Drums on track 1, `delay_mix` and `rev_mix` up, every send at 0. Stop the voice. Then open track 1's sends (TRACKS, hold K1, D and R) and stop it again | With the sends at 0 nothing rings on. With them open, echoes and a tail ring on | the sends in io and the lanes |
| 19.20 | **The dry never ducks** | Track 2's tone, every send at 0. Raise `delay_mix` and `rev_mix` from 0 to full | The level stays within 0.5 dB | The sum in `\four_io` (nineteenth change) |
| 19.21 | `dly_rev` | Track 2's delay send open, its reverb send at 0, `delay_fb` 0, `rev_decay` 4 s. Stop the voice with `dly_rev` at 0, then at 1 | At 0 the echo ends dry. At 1 the echoes ring on in the reverb | `dly_rev` in `\four_io` |
| 19.22 | NO SEND | `delay_mix` and `rev_mix` up, every send at 0. Open DELAY and REVERB. Then open track 2's delay send | Both pages say `NO SEND - TRACKS K1`. On DELAY the words go once a track sends | `SPC_HINT`, `no_send` in lib/mpages.lua |
| 19.23 | The room and the brigade run | Track 2's sends open, `delay_mix` and `rev_mix` up | `four_reverb` and `four_delay` run, and `hasStretch` is true, so they are FourRoom and FourBBD. The tail decays smoothly. The echoes land on `delay_time` | `\four_reverb`, `\four_delay` (sixteenth and seventeenth changes) |
| 19.24 | **Silence costs nothing** | Track 2's sends open, `delay_mix` and `rev_mix` up, `delay_fb` 0.5. Turn every track OFF. Read the thread 5 s and 60 s later | The thread does not rise while the tails die out. A rise is the denormal fault. Only the offline proof covers its repair (doc/space-plan.md, section 15) | The 1e-15 term in `BBD`, `Room` and `DelayFb` |
| 19.25 | Their cost | Track 2 in PLAY with both sends open. Read the thread with both mixes at 0, the delay alone, the reverb alone, then both | Record the figures. The room took about 5% on 2026-11-13, where JPverb took 13.5%. The brigade has no device figure yet | |
| 19.26 | KNOWN, not new failures | Turn SIZE while the room plays. Set `delay_time` to 0.01 s. Feed the reverb a DC offset | Record what the device does and go on. The offline review found it all (doc/measurements/2026-11-15/README.md): The room reads SIZE at its start only. A later turn of SIZE does nothing. Eight other reverb knobs do nothing to the room. The brigade's least time is 42.8 ms. The room has a DC gain of +16 dB. FLANGE at amount 0 delays the track by 1.40 ms | Not a fault of this build. A device figure that differs from these is new |
| 19.27 | **The CPU budget** | Four PV tracks at pitch 2 for 60 s. Each has FLANGE and ECHO on, drive up and both sends open. `delay_mix`, `rev_mix` and `shimmer` are up. Then the user's dense set: PV at pitch 1.96 and 2.5, GRAIN at density 200 and size 0.29 s and 0.5 s, for 60 s | The scsynth thread stays under 60%, and there is no xrun in either 60 s. On 2026-11-13 four PV at pitch 2 took 53.0% and the dense set 57.3% | The grain cap (48 pairs), the lanes, the room |
| 19.28 | Every track's sends | Each track alone in PLAY on its take. Open only its delay send, stop the track, read 1 s of what rings on. Then only its reverb send | Every tail is well above silence (-92.5 dB). Until the fortieth change tracks 2 to 4 never reached the delay or the reverb, and no check saw it | io's `lanes_dly` and `lanes_rev`, the lanes' `fx_dly` and `fx_rev` |
| 19.29 | A fade rocked across the middle | Track 2 plays the tone with CHORUS. Keep a scene with ECHO in its place, then fade to it and rock the fade between 0.49 and 0.51 | The type changes at each crossing, and no step breaks the sound on either channel. Listen to the recording for the dip | `morph_value` in lib/mscenes.lua, `laneFx`'s bundle |
| 19.30 | The delay and the reverb leave without a click | Track 2 plays the tone into the reverb and stops. Under the tail, set `rev_mix` to 0. The same for the delay. Then K1+K3 (DRY) while the track plays into both | No step on either channel, and each synth is gone a moment later. A mix that comes back within 40 ms keeps its synth and its tail | `updateReverb`, `updateDelay`, `spaceWait` |

## When it passes

Write the date and `count: 198` into the STATUS block of `CLAUDE.md`, as the new
confirmed state. That block tells the next session which changes it can trust.

If something fails, the "suspect" column is a starting point, not a verdict.
Note what you actually heard; a symptom described precisely is worth more than a
guess at the cause.
