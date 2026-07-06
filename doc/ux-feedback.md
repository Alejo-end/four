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

## Still open / next loop iterations

- On-device verification of everything above (all of it is uisim-verified
  only; renders in `doc/ui/`).
- Consider grid pads for the new key actions (FLIP, INF, WASH…) — parity
  question, low priority.
- Watch whether the LEVEL `IN=0`/`OUT=0` resets feel right on hardware
  (system params are dB tapers there; 0 = unity).
