# UX feedback — 2026-07-06 (voice notes, typed up)

The main points from the walkthrough feedback, kept as the working list for the
UI polish loop. Overall verdict: **keep the design** — these are refinements,
not a redesign. Target: a UX-friendly, state-of-the-art music-technology view,
fully playable standalone (3 keys + 3 encoders); the grid stays optional.

## The points

1. **Encoder value readout needs its own background.** Turning an encoder
   flashes the value top-right, but the text sits naked on top of a busy page
   (waveform, cloud, reels) and is hard to read. Give the readout a knockout
   box — it may block a little of the picture, that's fine — so the value is
   always completely legible.
   → **DONE**: the flash now draws in a black pocket with a dim frame; the
   parked per-page readouts knock out their own pocket too.

2. **FILTER page: curve too sharp / not a real filter.** The 3-segment sketch
   doesn't represent the actual response. Draw a proper curve, make the page
   more worked-out.
   → **DONE**: real 12 dB/oct biquad magnitude response (matches the engine's
   RLPF/RHPF/BPF with rq = 1 − res·0.85), log-frequency axis 20 Hz–20 kHz,
   dim 100 Hz/1 k/10 k gridlines, 0 dB reference line, filled passband, and a
   bright EQ-style node dot riding the curve at the cutoff.

3. **TAPE page: really good, keep as is.** No action.

4. **STRETCH: fine. WINDOW select: improve.**
   → **DONE**: window length parked top-right in real seconds (60 s buffer),
   jitter now visibly scatters the playhead (it blurs the read position —
   that is what the engine does), K3 = FLIP reverses scan direction.

5. **REC page ("direct page"): improve.**
   → **DONE**: `resample` (in↔out) was invisible state that changes what gets
   recorded — it now shows an RSMP chip while engaged. Take length reads in
   seconds while recording.

6. **MIX / LEVEL confusion: "I don't know what the next page does."**
   MIX = the script's engine↔tape balance; LEVEL = the system I/O gain stage.
   → **DONE**: MIX parks its balance (`E70 T30`) top-right; LEVEL gets a
   signal-flow hint (IN ›› OUT) and 0 dB reset keys, so it reads as the
   I/O trim page.

7. **The footer hexagon: unsure about it.** Circle felt hard at this pixel
   size but the TAPE reels prove r≈7 circles render fine.
   → **DONE**: hexagons replaced with circular dials (ring + bright needle),
   same geometry, same positions — the knob metaphor without the ambiguity.

8. **Unused keys: every page should give K2/K3 a job where possible.**
   → **DONE**: MIX `ENG`/`TAPE` crossfade throws · LEVEL `IN=0`/`OUT=0`
   unity resets · WINDOW `RST`+`FLIP` · GRAIN `OCT-`(alt `OCT+`)+`PT=1` ·
   FILTER `TYPE`+`OPEN` · DELAY `INF`+`KILL` · REVERB `WASH`+`KILL`.
   (REC, STRETCH, TAPE already had both keys.)

9. **Page dots: the row reads as a weird, unstraight line.**
   → **DONE**: every dot now sits on one pixel row (y=2); the current page is
   a wider bright bar on the same row instead of a 3×3 block. Family grouping
   (source · shape · tape · fx) is kept.

10. **Workflows: standalone-first.** The instrument must carry a full
    performance alone — plug a synth in, chop something, turn it into a
    soundscape — and the grid is a bonus surface, never a requirement.
    → **DONE**: `doc/workflow-standalone.md` and `doc/workflow-grid.md`,
    linked from the README.

11. **(loop 2) DELAY page echo-tap plot — tried, then REVERTED on request.**
    An impulse+bars plot with a dotted feedback envelope and time/INF badges
    replaced the bouncing ball; the user asked to revert, so the original
    bouncing-ball page (arcs shrink with feedback, ball hops at the real
    repeat cadence, dormant at mix 0) is back and is the keeper. Don't
    re-attempt a bar-plot delay page without being asked.

12. **(loop 2) REVERB page deepened.** The room keeps its walls, gains a
    listener ring opposite the source, a third reflection ray (rays run
    longer in a bigger room), and a diffuse air shimmer (deterministic hash
    dither, twinkling at 3 Hz) whose density rides the mix — the tail as a
    picture. Dormant at mix 0: dim room, still air.

    The render suite grew three FX truth shots: `DELAY_INF`, `DELAY_DRY`,
    `REVERB_DRY` (dormancy + the INF badge are now diffable states).

13. **(user-directed) REVERB page redesigned as CATHEDRAL.** The top-down
    room never read ("I don't understand the reverb page"). Sixteen rendered
    candidates over two gallery rounds later, the user picked the cathedral
    cross-section: a vault (bright outer rib + two echo ribs, unit-arch
    precomputed — no per-frame trig) that grows with size, starry air that
    thickens with mix, two ray pulses arcing source→listener, an RT badge
    (estimated seconds — FreeVerb size→RT is approximate), and full
    dormancy at mix 0. Suite gained a REVERB_WASH shot.

14. **(loop 3, user-directed) MIX page tells the truth about the crossfade.**
    The engine↔tape fader is a plateau law (`min(1, 2(1−mix))` each side —
    both decks at unity around center, no dip), but the page scaled lane
    energy linearly with the fader, showing half-energy lanes at a
    full-level center. Now: lane energy follows each deck's REAL gain, the
    law itself is drawn between the lanes (unity plateau meeting at center,
    tails at the edges) with the handle riding it, a full throw stills the
    dead lane flat-dim, and a slim master VU (`amp_out`, same sqrt law as
    LEVEL/REC) rides the right edge — this page is where the blend gets
    pushed. Suite grew a `MIX_TAPE` full-throw truth shot. Loop 4 added a
    peak-hold tick on the VU (~1s decay, bright at clip).

15. **(user-directed) MIX page redesigned as TOWERS.** From an 8-candidate
    rendered gallery the user picked "2's towers with 4's master VU": two
    columns whose height IS each deck's real gain under the plateau law
    (both stand full at center), ENG filled with live static, TAPE with
    the loop's actual waveform, knockout name plates at the tower feet,
    crossfader below, and the right-edge master VU with peak-hold kept
    from the truth pass. Lanes + law-curve drawing retired. **(Superseded
    by §16.)**

16. **(user-directed) MIX page changed again to VU PAIR; REC → REEL
    COUNTER; WINDOW → LOUPE; LEVEL kept as-is.** After galleries of 8
    MIX and 6-each LEVEL/REC/WINDOW candidates, the user's picks:
    - **MIX = VU PAIR** — the DJ-mixer archetype: a needle VU per deck
      (ENG/TAPE), crossfader between. Each needle rests at the deck's real
      gain and lifts with the live output; a silenced deck (mode OFF /
      thrown away) drops its needle to rest. Dial geometry precomputed
      (VU_SC/VU_TK) — two cos/sin per frame. The towers' master-VU
      peak-hold (mix_peak) is gone; that state was removed.
      *Gotcha fixed in port:* `d==1 and eng_on or (tape_g>0)` made the
      engine needle "on" whenever tape played — must be
      `(d==1) and eng_on or (d==2 and tape_g>0)`.
    - **REC = REEL COUNTER** — a tape-deck face: REC lamp, big seconds
      counter, stereo input meter, 60s reel-usage bar with the write head
      sweeping while recording. Suite gained a `REC_REC` armed-state shot.
    - **WINDOW = LOUPE** — a waveform-editor overview+detail: full buffer
      boxed up top, the slice zoomed full-width below, playhead tracking
      inside; jitter fuzzes the detail playhead (alt-layer feedback).
    - **LEVEL** — left exactly as shipped (twin faders + VU) per request.
    Dist byte-identical (25 shots).

17. **(user-directed) the "Toy" whole-screen redesign — supersedes §8–16
    bodies.** (Notes above capture earlier iterations; some points marked DONE
    refer to UI elements that were later replaced by this Toy chrome.) The user
    prototyped and approved a full UI direction ("D · Toy") in a separate HTML
    recreation and asked for it verbatim, choosing "Full Toy, revert bodies" when told it conflicted with the recent picks.
    - **New ALT layer** on FILTER (D/W, GRN) and REVERB (MIX, D/W): the
      wet-path controls the filter itself can't expose.
    - **Bodies:** MIX → two lanes; LEVEL → stereo meter bars (peak-hold +
      clip lamp); GRAIN → a pooled stereo grain field (size stretches ticks,
      density fills, pitch tilts the drift); TAPE → fixed reels; REVERB →
      top-down room + rays + a source ping; FILTER → curve + spectrum ticks;
      REC → strip + write-head afterglow; WINDOW → strip + jitter.
    - Found + fixed a **uisim gap**: `screen.fill()` didn't fill circle
      paths, so filled knobs rendered blank in the sim (fine on hardware).
      Suite gained FILTER_ALT / REVERB_ALT / GRAIN_PITCH shots; dist
      byte-identical (42 shots).

18. **(user, first sound-check) "the audio changes are too subtle, the
    volume is too faint — engine improvements to be done."** Diagnosis in
    the engine, not the UI: FX mixes were linear crossfades (engaging
    delay .35 + reverb .28 left 0.47× of the direct wet path while adding
    polite tails), sparse grain clouds sat far below the dry input
    (loudness ∝ density×size), FreeVerb's return is inherently quiet, and
    there was no drive stage to push into. S5 gain pass (spec §9b,
    fingerprint 30 → 31): overlap compensation, equal-power FX mixes,
    reverb return ×2 + brighter damp, wider resonance, and a new `drive`
    param (DELAY page, hold K1, E3) — tanh saturation with makeup.
    **Engine change: needs the on-device deploy ritual; gate pending.**

## Still open / next loop iterations

- On-device verification of everything above (all of it is uisim-verified
  only; renders in `doc/ui/`).
- Consider grid pads for the new key actions (FLIP, INF, WASH…) — parity
  question, low priority.
- Watch whether the LEVEL `IN=0`/`OUT=0` resets feel right on hardware
  (system params are dB tapers there; 0 = unity).

---

# UX feedback — 2026-07-17 (voice memo → whisper transcript)

Second on-device walkthrough, recorded after the NU nine-station redesign and
the S21/S22 engine changes shipped. Source: a 22-min voice memo transcribed to
`/Users/alejandrodeleon/Downloads/transcript.txt` (line refs below). Points
continue the global numbering.

**Overarching directive:** *no new features* — "no more features now… make this
thing we have good, it's hard enough" (l.122-123). Everything below is a fix, a
rework, or a removal. All PLANNED (nothing implemented yet).

## Bugs — fix first

19. **Delete/erase doesn't actually clear the take.** The CLR / K1+K3 erase
    gesture animates ("looks cool") but the recording isn't wiped, and recording
    over it doesn't replace it either. "The delete looks cool but it doesn't
    fucking work… deleting is still like an issue" (l.92-100). → PLANNED: trace
    the erase path on device (K1+K3 hold → arc threshold → `ctx.clear_recording`
    → engine `clear`); an animation that fires while the buffer stays audible
    means either the arc-threshold action never reaches `engine.clear`, or
    `wave[]`/`take_len` aren't reset so it only *looks* uncleared. Confirm a
    re-record replaces the buffer.

20. **STOP only mutes — it doesn't stop.** `stop_all` chokes the deck levels but
    mode / tape / heads keep running underneath, so it reads as mute, not stop.
    "I wanted to stop it not to mute it" (l.78-81). → PLANNED: decide whether
    STOP should truly halt playback (pause the play voice + tape transport) or
    stay a click-free level-choke; if it stays a choke, make the page honest that
    it's muted, not stopped.

## SPACE page — undo the delay+reverb merge

21. **Split delay and reverb back into two separate pages.** Merging them onto
    one SPACE page was a regression — "just make it a separate thing again, it
    was better before" (l.4-5, 59-60). There are enough pages/keys now.

22. **Deeper control on delay and reverb.** The settings are too simple — "these
    settings are too simple for me… my control is not satisfied" → "deeper
    control for either reverb or both, and separate pages because we have more
    keys" (l.63-64).

23. **Fix the delay feedback range.** At 100% it's only ~4 barely-audible
    repeats, then it jumps straight to infinite with nothing usable between; the
    user wants ~10+ repeats / "tons more repeats" before infinity (l.53-59). The
    animation is *accurate to the sound* — the fault is the feedback param's
    range/curve, not the drawing (l.57-58).

24. **Make the delay/reverb controls legible.** Unclear what "echo 100%" means or
    whether the time knob acts on the delay or the reverb (l.45-52). Splitting the
    pages (21) + clear labels should resolve most of this.

## Tape — a resample stage, not a second recorder

25. **Tape should capture the OUTPUT of the FX chain, not the raw input.** So you
    can "print" the mangled sound onto the tape loop and mangle it further, and
    mix between the dry input and the processed signal — tape as a resample /
    filter stage in the chain (l.67-76). (The io record path already has a
    `resample` in↔out control; this is about routing the softcut/tape capture
    from the post-FX output.)

## Motion page — much more control

26. **Controllable, legible motion loop length.** The "24.4 s" loop time is
    confusing and unsettable — it's the whole recording, and its meaning shifts
    with playback speed (l.82-114). Add a loop-time / window control (the alt
    encoder slot is free — "you can put it on the alt page, there's nothing
    there," l.115).

27. **Multiple motion loops without overwriting.** Recording a second motion
    forces deleting the first; the user wants to keep more than two so they can
    layer without doing everything at once (l.116-119). "We need a lot more
    control on the motion page to make it usable" (l.119).

## Sequencer — rework or remove

28. **The single-line sequencer is the least-used, least-understood part —
    rethink it or cut it.** "Maybe take it out completely… it's the part I use the
    least because I don't know how to use it" (l.29-42). If kept, it should be its
    *own* thing and sequence *pad / drone* sounds rather than percussive hits —
    "not a percussive idea but a way to sequence the different kinds of pad
    sounds / drones" (l.34-37).

## UI polish

29. **Kill the blinking TAKE window** — "the blinking window should be gone… I
    don't like the fucking blinking, it's way too much" (l.97-98).

30. **Clarify playback head vs record head on TAKE.** They overlap and read as
    misleading — "the playback head is behind the recording head which you don't
    see… it's misleading" (l.102-104).

## Praised — do not touch

- Voice **pitch** ("awesome… sounds good", l.65), **recording** ("fine", l.66),
  the **mix page** ("better… okay", l.77), and the **big elapsed-seconds
  numbers** ("cool", l.98-99). The low-fi character is accepted as the norns'
  sound profile (l.1-3). **Scenes** are now understood and liked as manual
  checkpoint / version-control (l.6-26); no change asked. Open to verify, not a
  to-do: granular depth ("I need to test it", l.67).
