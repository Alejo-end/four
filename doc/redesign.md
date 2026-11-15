# MANGLER — UI/UX Redesign Specification

> **Historical, and a design reference.** This is mangler's screen redesign of July
> 2026 (NU-1 to NU-4). Its page lists and key maps are old. The pad sequencer came back
> on PADS (the 85th and 98th changes). The LAYERS page came and went (four, thirteenth
> change). four added TRACKS and EFFECT, and has twelve pages.
> README.md's Pages table and doc/controls.md are the current control map. The code
> still cites two of its sections as the reason for a design: §4 (the purity mark) and
> §6 (one dominant object for each page).

**Status:** IMPLEMENTED through NU-4 (2026-07-16, stages in Appendix C) —
renders verified in test/uisim, dist byte-checked; the on-device gate is
still pending (grid code and key-feel are untestable in the sim). Written
2026-07-15, pre-release (no installed base — no compatibility constraints).

> **Superseded in part by S23** (doc/spec.md, 2026-07-17 play-test fixes): the
> nine-station SPACE page was split back into separate **DELAY** and **REVERB**
> pages, and the **sequencer was removed** — PADS is a
> pure 8-slice play/sound-lock surface. The `seq_slice` id is KEPT as the slice
> selector (ids are never renamed), so the "merge into one `slice` param" note
> below is behavioral only. Later changes folded EROSION into VOICE and ORBIT
> into SCENE. (The note at the top of this page says what changed after that.)
**North star:** "make it feel like the S-4" — sleek, immediate, confident,
fluid, unified, restrained — while staying strictly norns-native
(128x64 OLED · 3 keys · 3 encoders · optional grid · no color).
**Engine impact:** none. Fingerprint stays 61. All Lua/UI. One declared
param-layer change: `pad_cursor` + `seq_slice` merge into one `slice`
param (Lua-only). Some params are demoted from encoders to PARAMS-only;
no ids are renamed.

This supersedes the earlier compatibility-constrained redesign pass (that
pass's changelog is summarized in §1).

---

## 1. What changed from the compatibility-constrained pass, and why

Every "keep for churn/muscle-memory" constraint is gone. What each one was
hiding:

| Previous decision | Was kept because | New verdict |
|---|---|---|
| 14 pages, 5 families | "minimize churn" | **9 pages, 4 groups.** LEVEL, WINDOW, GRAIN, DELAY, SEQ die as pages (merged, not lost). |
| GRAIN/REVERB banking (K2=BANK) | "zero churn on the tweakiest pages" | **Banking deleted entirely.** Four curated macros per page; everything deeper lives in a beautifully organized PARAMS menu (norns' native deep-edit, one K1 tap away). |
| DELAY bouncing-ball body | user-picked | **Cut.** It was picked in a world where DELAY was its own page. DELAY+REVERB merge into SPACE, whose unified echo-and-tail scape is a strictly better picture. |
| REVERB decay-tail body | user-picked | **Survives on merit** — its impulse-response form wins the merged SPACE page's visual language. |
| WINDOW loupe (two panels) | user-picked | **Replaced.** Two stacked panels = two competing objects. The merged TAKE page has one strip that *is* the take, with bracket editing and zoom-scaled deltas doing the loupe's job. |
| MIX real-gain lanes | truth pass (S21) | **Survives on merit**, restyled into a full console (IN → decks → VU). Truth is not a compatibility feature. |
| S19c one-selector scene model | just shipped | **Survives on merit** — genuinely the best morph model for two encoders — and gains hold-to-peek and an undo slot. |
| Mode-aware GRAIN bodies | just shipped | **Survive as VOICE's textures.** The idea (the picture is the mode) was already S-4-grade. |
| `say()` text chips | trust fix (36th change) | **Cut from screen.** Every action now has a drawn consequence in the object itself (flash, fill, shake, dot). Words were a patch on pictures that didn't answer; the pictures now answer. Maiden prints stay. |
| K2-acts / K3-chooses / K3-long-destroys table | grammar-by-convention | **Replaced by one physical law: tap = latch, hold = punch.** One rule the hands learn once, instead of a role table the head memorizes. |
| Tape reels | charm | **Cut.** Replaced by the loop BELT (user-picked over ring and strip candidates, feedback round 1) — a literal tape loop that shows direction, speed, and material with zero decoration. |
| Per-page DRY ticks | identity reinforcement | **Replaced by one global purity mark** (§4). Say "this is your recording, verbatim" once, perfectly, everywhere. |

---

## 2. Strategy and instrument identity

Mangler is **one take, sculpted live**. Everything on screen serves three
questions: *what material do I have, what is it becoming, and how do I get
back.*

The S-4 feeling, translated to norns:

- **The structure is the signal path.** Pages aren't a menu; they're stations
  along the sound: TAKE → VOICE → TAPE → FILTER → SPACE → MIX, then the
  control plane: PADS → MOTION → SCENE. The page-dot row literally reads as
  the signal map.
- **Macros, not parameter coverage.** Each page exposes exactly four encoder
  targets (face pair + shift pair) and two gestures. Nothing else is on
  screen. Depth exists — in the PARAMS menu, organized to mirror the pages —
  behind norns' own deliberate gesture.
- **Gestures over toggles.** One law makes every action both a punch and a
  switch (§3). Throws, recalls, records, reverses — all playable as momentary
  stabs or deliberate latches, with the same fingers.
- **Trust is drawn, not written.** State changes flash their object. Refusals
  shake. Purity is a mark. Undo is a slot you can see.

---

## 3. Global interaction language

### The Punch Law (the core of the redesign)

Every key action on the instrument — screen keys and grid pads alike — obeys
one rule:

> **Press = engage now. Release within 300 ms = it latches. Hold past 300 ms
> = it's a punch — release disengages.**
> If it's already latched, any press turns it off.

One law covers: record (tap = arm a take · hold = punch a stab into the
buffer), tape overdub (hold = classic punch-in), reverse (hold =
flip-while-held · tap = latch backwards), freeze (hold = spectral stutter ·
tap = hold it), filter OPEN (hold = sweep gesture that returns to your carved
tone · tap = park it open), delay INF (hold = dub grab · tap = pin it),
shimmer BLOOM, seq RUN (hold = run-while-held stutter), motion REC (hold =
punch-in automation), STOP (hold = mute stab · tap = kill), and scene RECALL
(hold = *borrow the scene, release comes home* · tap = commit). The momentary
version of everything is inherently safe — your finger is the state.

### Controls

| Control | Meaning |
|---|---|
| **E1** | Page — 9 stations, clamped. Hard left = TAKE (the material), hard right = SCENE (the states). |
| **E2** | The page's **material** dimension (what/where): window start, size, rate, cutoff, echo, slice, lane, slot. |
| **E3** | The page's **character** dimension (how much): window end, density, loop, resonance, verb, hits, depth, **morph**. |
| **K1 tap** | norns menu → PARAMS = the deep-edit layer (native, deliberate, one tap away). |
| **K1 hold** | SHIFT: E2/E3 become the alt macro pair; K2/K3 become the global pair. Footer swaps whole, with a one-frame invert. |
| **K2** | The page's **primary gesture** (punch law). |
| **K3** | The page's **secondary gesture or selector** (punch law; pure selectors are tap-cycles). |
| **K1+K2** | **STOP** — global, all 9 pages, no exceptions. Tap = kill (latched, levels slew out, exact mix restores on restart). Hold = mute stab. |
| **K1+K3** | **DRY / ERASE** — global, all 9 pages. Tap = DRY (zero echo/verb/shimmer/drive/clouds-fb, open the filter). Hold to a 1 s arc = **erase the page's material** (take, tape loop, selected lane, pattern, selected slot). Release between 300 ms and the arc = nothing (deliberate abort zone). |
| **K1+E1** | **MORPH, from anywhere** — the everything-knob. Sweeps toward the selected scene without leaving your page. Sweeping back to zero lands you exactly home. |

There are **zero page-specific claims** on the global pairs. The alt layer is
identical on all nine pages. This is what "unified" means: page N+1's keys
are already in your hands.

**Selection exception (declared):** on PADS, MOTION, SCENE, E2 is a selector
(slice / lane / slot). Signaled the same way everywhere: a bracket cursor
moves inside the dominant object and the footer's E2 word is the selection
(`SLICE·3`, `LANE·CUT`, `SLOT·5`).

---

## 4. Visual state language

Brightness ladder: 0 bg · 1–2 ghost/disabled · 3–4 dormant (present, silent)
· 6–8 chrome · 10–12 active · 15 sounding/cursor.

**The purity mark `◇`.** One glyph beside the title, on every page, computed
live: it shows **only when the output is the take, verbatim** — mode PLAY,
pitch and speed at 1, filter open, drive/echo/verb/shimmer/feedback at zero,
no resample/regen. Any mangling extinguishes it. This is "clean until you add
mangling" said once, absolutely, globally — it replaces every per-page DRY
tick, and tapping DRY (K1+K3) visibly re-lights it. It is the product
identity in four pixels.

| State | Treatment |
|---|---|
| latched | stays inverted/filled after release — *if it's lit and your finger is off, it's latched* |
| punched (held) | inverted only while held |
| sounding | brightness rides audibility (house rule, kept) |
| selected | 1-px bracket corners, brightness 15 |
| writing | fast blink (2 frames on/off) — the only fast blink on the instrument |
| pending/queued | slow blink + emptying wedge |
| armed | slow blink |
| danger | hatched fill; reachable only through the erase arc |
| empty | dotted outline + the one invitation voice: `EMPTY — K2 REC` |
| refusal | **the shake**: a no-op action (recall an empty slot, audition an empty take) shakes its object 2 px for 3 frames. The instrument never silently ignores you — and never needs a sentence to say no. |
| you-are-here | a small `●` inside a scene slot whose contents match the live sound — a recall that would change nothing is visible *before* you press |
| STOP | the title chip inverts, page body collapses to brightness-3 skeletons while controls stay bright in place (settings held, sound choked) |

Motion means time: heads sweep, orbits spin (backwards when reversed), wedges
empty. Nothing animates decoratively. Fast blink is reserved for writing,
forever.

**Measurement rails (feedback round 1):** pages whose dominant object lives
on an axis carry dim dotted reference rails at level 2 so position is
*readable*, not just relative — FILTER: verticals at 100 Hz / 1 kHz / 10 kHz
(labeled, level 3) plus the 0 dB line; SPACE: verticals at 1 s / 2 s;
MOTION: loop-quarter rails; TAPE: quarter-position ticks on the belt. Rails
never exceed level 2–3 and hide behind filled content — scaffolding, not
competition.

---

## 5. Structure: 9 stations on one path

```
 SOURCE            COLOR        OUT     PLAY
 TAKE VOICE TAPE · FILTER SPACE · MIX · PADS MOTION SCENE
 [●    ○     ○ ]  [ ○     ○   ] [ ○ ]  [ ○    ○     ○  ]
```

| # | Page | Absorbs | One-line job |
|---|---|---|---|
| 1 | **TAKE** | REC + WINDOW | record the material and frame what plays |
| 2 | **VOICE** | STRETCH + GRAIN | how the take plays: PLAY · GRAIN · WARP · PV |
| 3 | **TAPE** | TAPE | the parallel loop deck |
| 4 | **FILTER** | FILTER | tone |
| 5 | **SPACE** | DELAY + REVERB | the time-smear: echoes and tail |
| 6 | **MIX** | MIX + LEVEL | the console: in → decks → out |
| 7 | **PADS** | PADS + SEQ | the take chopped, played and sequenced |
| 8 | **MOTION** | MOTION | the gesture loop |
| 9 | **SCENE** | SCENE | states, morph, and the way back |

Boot lands on TAKE, showing `EMPTY — K2 REC`: the invitation is the front
door. The dot row is grouped 3·2·1·3 and reads as the signal path — a new
user learns the architecture from the header. (A fully different navigation
model — a chain view that zooms into stations — was considered; it reduces to
pages-with-a-path-shaped-header, so the mechanics stay and the framing is
adopted.)

Why not fewer? FILTER+SPACE would stack two dominant objects; MOTION+SCENE
are different mental models (loop vs. bank); TAPE is a genuinely separate
machine. Nine is the floor without lying.

---

## 6. Detailed redesign per page

Template: every page = one dominant object + header (title · ◇ · flags ·
path dots) + footer (four quiet words at brightness 6: `K2 K3 | E2 E3`; a
turned encoder's word swells to word+value for 1.2 s; engaged keys invert;
numbers appear only on demand).

---

### 1 · TAKE — the material

**Purpose:** record a take and frame what plays. **Mindset:** counting a
phrase in, then leaning in to trim. **One glance:** is it writing, how long,
where the window sits. **Perform/edit:** both — recording is performance,
framing is editing, one object serves each. Screen-primary.

```
TAKE ◇ R        ●●● ·· · ···
▂▅███▇▅▂▁ ▶ ─ ─ ─ ─ ─ ─
  [◀█████████▶]     3.8s
▁▁▂▃▅▆▇▇▆▅▃▂▁  IN ▐▌▌╣
REC  SNAP     ST·      EN·
```

- **Dominant object:** the take strip — the recorded material bright,
  unwritten space dotted, write head sweeping with afterglow while armed,
  window brackets inside it. A hairline underline shows take-within-60s-
  buffer. Window regions outside the take hatch (you're looping silence, and
  it says so).
- **While armed:** strip frame blinks fast, elapsed seconds in the large
  font, and a compact input meter with the **record-ready bracket** (peak
  inside −12…−3 dB = the whole gain manual, no words). On commit, the window
  snaps to the take and the snapped region flashes once — the "what just
  happened" answer.
- **E2/E3:** window start / end, deltas scaled by window length (automatic
  fine control). **K1+E2:** move both edges. **K1+E3:** jitter.
- **K2 = REC:** tap = arm/commit a take · hold = punch a stab of input
  straight into the buffer. **K3 = SNAP:** tap-cycles window → take → full.
- **Erase (K1+K3 arc):** the take. Truly destructive — the arc and hatch are
  the guard; control-state undo does not apply to audio, and the spec says so
  here.
- Loading a file lives in PARAMS (a file dialog is a menu; pretending
  otherwise is false sleekness). Empty state adds one dim line:
  `OR PARAMS > LOAD`.
- Regen/resample (deep, PARAMS): when either is nonzero the strip gains a
  hatched overlay — the buffer is being re-touched by output — and ◇ goes
  out.

---

### 2 · VOICE — how the take plays

**Purpose:** choose and sculpt the playback engine. **Mindset:** committing
to a sound identity, ears first. **One glance:** which mode, what texture
it's making, frozen or free.

```
VOICE          ●●● ·· · ···
 PLAY GRAIN WARP PV
      ▔▔▔▔▔
  · ∴·˙·∴ ˙ ·∴· ˙· ∴ ·
FRZ  MODE     SIZE·  DENS·
```

- **Dominant object:** the mode's own texture, drawn from the playing window
  — solid unbroken wave (PLAY), the grain cloud (GRAIN), overlapped windows
  (WARP), spectral columns (PV). The picture *is* the mode; the mode rail
  above it is the label, active word underlined/inverted. When the drone is
  silent the texture lies flat and dim.
- **Mode-contextual macros (the S-4 move):** the face pair is *what shapes
  this mode most* — PLAY: speed · pitch; GRAIN: size · density; WARP: window
  · rand; PV: speed · pitch. **K1+E2/E3 = speed · pitch always** (the
  universal pair, identical in every mode). Footer words re-label live; the
  swap is the point, not a trap — the encoders always control what you're
  hearing.
- **K2 = FRZ** (punch law: hold = spectral/cloud stutter, tap = hold it —
  latched inverted, `FZ` flag). **K3 = MODE**, tap-cycles
  **PLAY→GRAIN→WARP→PV** — OFF is removed from the cycle (a silence pothole
  mid-set; stopping is STOP's job; OFF survives as a param). The newly active
  mode word flashes 3 frames: confirmation without a dialog.
- Reverse is not a key here: **speed goes through zero** — turning E2 (or
  shift-E2 in grain mode) past 0 plays backwards, and the texture visibly
  reverses.
- Deep grain params (spread, texture, position, feedback, lofi, jitter,
  pitch-spread, shape) → PARAMS. Feedback note: clouds-fb is in DRY's kill
  list, so the washiest deep param always has a panic exit on the keys.

---

### 3 · TAPE — the second deck

**Purpose:** a parallel looper with its own speed and direction.
**Mindset:** dub hands. **One glance:** is it looping, which direction, how
fast, is it being written.

```
TAPE   T          ●●● ·· · ···
    ·    ·    ·          3.2S
  ╭▂▅▃▂▅█▐▌▂▅▃▂▅▃╮
  │     X1.0      │
  ╰───────<───────╯
REC  REV      RATE·  LOOP·
```

- **Dominant object: the BELT** — a literal tape loop (user-picked over the
  ring and strip candidates, feedback round 1). The waveform rides the top
  run of a closed stadium shape; the return run underneath carries a small
  circulation arrow (flips when reversed); the head is a bright tick with a
  comet trail on the top run; rate sits INSIDE the loop; quarter-position
  ticks above the material. Punch-overdub = the freshly written stretch
  glowing behind the head while K2 is held. Reverse is *visible motion*, not
  a label. The reels are gone — the belt says more with less, and it is
  instantly distinct from TAKE's strip (strip = buffer, belt = loop).
- **E2 = rate** (through zero = backwards; the head and arrow flip) ·
  **E3 = loop length**. **K1+E2 = pre-level** (overdub decay) ·
  **K1+E3 = loop position**.
- **K2 = REC:** tap = arm/stop the take-into-loop · **hold = punch-in
  overdub** — the classic looper gesture, finally physical. **K3 = REV:**
  hold = flip-while-held, tap = latch backwards.
- Tape freeze is demoted to PARAMS + grid state row (declared cut: with rec
  off the loop already holds; a fourth surface action isn't worth a key).
- **Erase arc:** the loop. MIX shows this deck honestly (real material × real
  gain), so a forgotten loop can never ambush you — the S21 lesson, kept
  structural.

---

### 4 · FILTER — tone

**Purpose:** cutoff, resonance, drive, type. **One glance:** the curve is the
state; flat = neutral.

- **Dominant object:** the real magnitude curve (survives on merit — it was
  always the best answer): log-f axis with dotted measurement rails at
  100 Hz / 1 kHz / 10 kHz (labeled dim) plus the 0 dB line, filled passband
  (which hides the rails it covers), bright node at cutoff. Drive thickens
  the line and adds grit dots — saturation as texture, not a number. Flat
  curve + zero drive = unfilled + the page contributes its bit to ◇.
- **E2 cutoff · E3 resonance · K1+E2 drive · K1+E3 dry/wet.**
- **K2 = OPEN** (punch law: hold = open-while-held — a filter sweep that
  returns to your carved tone by itself; tap = park it open). **K3 = TYPE**,
  tap-cycle LP→HP→BP; the curve morphs shape instantly, which is the
  confirmation.
- Nothing else. This page was already restrained; now its throw is playable.

---

### 5 · SPACE — the time-smear

**Purpose:** echoes and tail as one picture. **Mindset:** placing the sound
in a room, or grabbing a dub throw. **One glance:** how far the sound smears
in time, and whether it will stop when you do.

```
SPACE           ●●● ·· · ···
█ ▆   ▅    ▃     ▂  ˙ ˙ · ˙
█▂▁▂▁▄▂▁▁▂▃▂▁▁▁▂▂▁▁▁▁▁▁▁▁▁
0s      1s        2s     →
INF  BLOOM     ECHO·  VERB·
```

- **Dominant object: the impulse scape.** One picture, x = time: the onset
  spike, discrete echo taps at the delay interval decaying by feedback, the
  reverb tail as a filled slope beneath them, shimmer as motes climbing off
  the tail. Delay and reverb were always one perceptual thing — *when the
  sound comes back* — and merging the pages lets one object say it. At echo
  = verb = 0 the scape is dormant flat and ◇ can shine. Dotted time rails at
  1 s and 2 s make tap spacing and tail length measurable. When decay and mix
  mean "this will not stop soon," the tail runs off the right edge into a
  hatched margin: readable danger, no words. (Name decided in feedback round
  1: SPACE stays — AIR/ROOM/ECHO considered and declined.)
- **E2 = ECHO** (delay mix) · **E3 = VERB** (reverb mix) — the two
  performance amounts, side by side. **K1+E2 = TIME** · **K1+E3 = DECAY**.
- **K2 = INF:** hold = pin the delay loop while held, release lets go — dub
  grabs as a physical gesture; tap = latch it (repeats stop decaying: the
  picture is the warning). **K3 = BLOOM:** shimmer punch/latch, motes surge
  while engaged.
- Everything else — damp, size, early, mod pair, EQ trio, cuts, shimmer
  pitch/tone, fb fine — lives in PARAMS, in a group ordered exactly like this
  page. The banked editor is gone; nothing on this screen is a list.

---

### 6 · MIX — the console

**Purpose:** in → decks → out, and the visible home of STOP. **One glance:**
what the audience hears, from which deck, how hot.

```
MIX ◇           ●●● ·· ● ···
IN▐▌  ENG ▂▅▇▅▂▅▇▅▂   ┌─┐
      ────────●─────  │▌│
      TAPE ▁▂▁▁▂▁▁▂▁  └─┘
ENG  TAPE      MIX·   OUT·
```

- **Dominant object:** the console — input meter on the left, the two deck
  lanes (real material × real gain, tape head shown whenever the deck holds
  audio), crossfader tick between them, master VU with peak-hold on the
  right. The whole signal path on one screen; this is the page you park on.
- **E2 = crossfade · E3 = master out. K1+E2 = input level · K1+E3 =
  monitor.** Deck trims, headphone gain → PARAMS. The LEVEL page is gone; its
  record-ready bracket moved to TAKE (where recording happens), its meters
  live here.
- **K2 = ENG · K3 = TAPE:** crossfade throws under the punch law — hold =
  duck to that deck while held (a crossfade stab), tap = latch it there, tap
  again = back.
- **STOP state:** title inverts, lanes collapse to skeletons as levels slew,
  fader/VU frames stay bright in place — settings held, sound choked. Steady,
  never blinking: stop is latched, not pending.

---

### 7 · PADS — the take, chopped and sequenced

**Purpose:** play 8 slices and give them a rhythm. **Mindset:** fingers on
pads, riding density. **One glance:** which slice is targeted, what rhythm is
firing it, is the clock running.

```
PADS            ●●● ·· · ●··
▂▅█▃▂▅▃▁▂▅█▃▂▅▃▂
│1│2│▓3│4│5│6│7│8│   ←slices
●·●·●··●·●·●··●·  ▶   ←steps
PAD  RUN      SLICE·3 HITS·
```

- **Dominant object:** the take with its 8 slices, and the 16-step row
  beneath — cause above, rhythm below. When a step fires, the target slice
  cell pulses: the causality is drawn. Playhead inverts the running step.
  Empty pattern invites: `TURN E3 — OR TAP GRID`.
- **The unification:** slice selection is ONE cursor — E2 selects the slice
  that K2 auditions *and* the sequencer retriggers. Browsing slices mid-run
  retargets the sequence live: selection becomes a performance move, not an
  edit state. (Param note, declared: `pad_cursor` and `seq_slice` merge into
  one `slice` param — Lua-only.)
- **E2 = SLICE · E3 = HITS** (the Euclidean density — turning it *is*
  sequencing). **K1+E2 = LEN · K1+E3 = DIV.**
- **K2 = PAD:** hold = gate the selected slice, tap = fire it one-shot — a
  pad under the punch law. **K3 = RUN:** tap = run/stop (steady inverted + a
  `▸` header flag from any page), hold = run-while-held — a sequencer stutter
  gesture.
- Pad type (grain/slice), voice count, atk/rel, note routing → PARAMS + grid
  state row. Routing (`PLAY>PADS`) shows as the page's one context word when
  engaged.
- **Erase arc:** the pattern. Grid: steps on workspace rows 3–4 (tap toggles
  — hand-drawn patterns over the Euclid generator), slice row on 5, mirroring
  this screen exactly.

---

### 8 · MOTION — the gesture loop

**Purpose:** record knob motion, loop it, ride its depth. **Mindset:** looper
brain. **One glance:** armed / playing, the loop, which lanes exist, what's
being replaced.

```
MOTION  M       ●●● ·· · ·●·
[▶━━━━━●━━━━━━━━━━] 4.2s
CUT  ··•···○···•·
MIX  ▒▒•··•···•··   ←rewriting
REC  PLAY     LANE·CUT DPT·
```

- **Dominant object:** the lane stack (feedback round 1 rework). Lanes are
  **dynamic** — one appears per param actually recorded, from ANY page (a
  SPEED lane from VOICE, a CUTOFF lane from FILTER, an ECHO lane from SPACE
  can coexist). Each lane is an **automation curve**, not event dots —
  recorded knob motion read like a DAW lane — drawn at its *depth-scaled*
  values: you see the loop you hear. Lane names are the owning page's own
  footer words, full length, never 3-letter codes. ONE playhead crosses
  every lane, with a bright dot where it meets each curve — the value
  sounding right now. Dim quarter rails mark the loop; `LOOP n.nS` parks
  top-right. While armed the frame blinks fast; a lane being punch-replaced
  this pass fills with hatch — overdub-vs-replace is visible, not
  remembered.
- **E2 = LANE** (selector; list starts at ALL) · **E3 = DEPTH**.
- **K2 = REC:** tap = arm an overdub pass · **hold = punch-in automation** —
  capture only while your finger is down, the single most S-4 gesture in the
  instrument. **K3 = PLAY:** tap = run/stop · hold = apply-while-held (a
  modulation stab).
- **Erase arc:** the selected lane — and because the lane list starts at
  **ALL**, "erase everything" is just select-ALL + the same gesture. One
  eraser, no second vocabulary.
- When a scene recall re-baselines lanes mid-play, the timeline frame flashes
  once: the ground moved, acknowledged.

---

### 9 · SCENE — states and the way back

**Purpose:** capture, recall, morph, and always have a way home.
**Mindset:** under pressure; zero thought allowed. **One glance:** which
slots exist, where you are, where you're aimed, how far you've traveled.

```
SCENE           ●●● ·· · ··●
◄ [1][2][·][4̲●][·][6][·][·]
LIVE ●━━━━━━━○────────── 4
RCL  CAP      SLOT·4  MRF·
```

- **Dominant object:** the slot row + the morph rail. Slot states: filled =
  captured · dotted = empty · bracket = selected · `●` inside =
  **you-are-here** (this slot matches the live sound — a recall that would
  change nothing is visible *before* you press; the old "RECALL — SAME" text
  chip is obsolete) · slow blink + emptying wedge = queued. The rail:
  `LIVE ●——○—— n`, dotted trail at the origin, hollow far end when a landed
  morph still skips the held/routing params (morph ≠ recall, drawn).
- **The model (kept on merit):** E2 selects the slot; K3 captures into it; K2
  recalls it; E3 morphs toward it from wherever you are; sweeping home to 0
  lands exactly where you started. And now **K1+E1 does the same morph from
  any page** — scenes pervade the instrument.
- **K2 = RCL under the punch law — the killer app:** **hold = peek** (a fast
  ~250 ms morph into the scene; release sweeps you home) · tap = commit.
  Auditioning a scene before committing makes recall *fluid* instead of a
  leap of faith. Every commit auto-captures the pre-state into the **◄ slot**
  — a ninth cell at the row's left edge that always holds "where you just
  were."
- **Undo is not a feature; it's a slot.** Select ◄, tap K2. No dedicated key,
  no SAFE vocabulary, nothing to remember to arm. Chaos (grid/MIDI momentary
  only — never a screen key) restores through the same slot on release.
- **K3 = CAP** (tap; the slot cell fills and flashes — the confirmation is
  the object). **Erase arc:** the selected slot. Recall an empty slot: the
  cell **shakes** — refused, explained, wordless. Quantized recall stays as a
  param (NOW/BEAT/BAR); when set, commits queue with the wedge.
- **Grid:** row 1 = slots from any page (tap = recall, hold = peek — same
  law); SCENE workspace adds an aim row and the morph bar; chaos sits in the
  far corner of the state row, maximally far from everything precious.

---

## 7. Cross-page consistency rules

- **Header, identical everywhere:** `TITLE ◇ flags ····path dots`. Flags:
  writes blink fast (`R` take, `T` tape, `M` motion), runs steady (`▸` seq,
  `↻` motion-play), freeze steady (`FZ`). STOP inverts the title chip. The ◇
  purity mark is global truth, not a page feature.
- **Footer, identical everywhere:** four quiet words — `K2 K3 | E2 E3` —
  brightness 6 at rest. Engaged keys invert (latched stays, punched reverts).
  A turned encoder swells to word+value for 1.2 s. **Numbers exist only while
  you're asking.** Shift swaps the whole footer with a one-frame invert.
- **One dominant object per page**, drawn from real state, brightness riding
  audibility. If a thing isn't sounding, its picture lies flat and dim; if a
  deck holds audio, its material is visible whether or not you remember it.
- **The punch law is universal** — screen keys and grid pads. The grid's
  press-surface release routing (a release always returns to the surface that
  took the press) is a load-bearing invariant.
- **One eraser** (K1+K3 arc), one panic (K1+K2), one invitation voice, one
  refusal (the shake), one queue treatment (slow blink + wedge), one writing
  treatment (fast blink + growing bright region in the page's own material).
- **Grid spine:** row 1 = scenes, row 2 = state strip (stop · dry · take-rec
  · tape-rec · freeze · reverse · run · chaos), rows 7–8 = piano — immovable
  on every page. Rows 3–6 = workspace, reshaped only for spatial data (steps,
  slices, aim, morph). The immovable spine is the anti-confusion mechanism.
- **PARAMS is the deep layer, and it's designed:** groups named and ordered
  exactly as the nine pages, face macros first in each group, deep params
  after. Depth is one deliberate K1 tap away, never on the performance
  surface.

---

## 8. What got cut entirely — and why cutting made it better

- **Five pages** (LEVEL, WINDOW, GRAIN, DELAY, SEQ as standalone). Every
  merge removed a duplicate of an object that already existed elsewhere (the
  take strip ×2, the mode texture ×2, the time-smear ×2, the slice row ×2).
  Fewer pages isn't the win; *fewer copies of the same idea* is.
- **The banking system** (REVERB_BANKS, GRAIN_BANKS, BANK keys, `BK n`
  chips). Banks were a hidden mode wearing a chip. Macros + PARAMS gives the
  same depth with zero on-screen state to track.
- **`say()` screen chips.** Replaced by drawn consequences (fill/flash), the
  refusal shake, and the you-are-here dot. Words were compensating for
  pictures that didn't answer.
- **Per-page DRY ticks** → the global ◇. The identity claim got stronger by
  being said once.
- **Tape reels, resting footer numbers, unity-reset keys, SHMR/OCT±/ROUTE/
  UNDO/SAFE/CLR key claims, mode OFF in the cycle, tape freeze on the
  surface, quantized-recall keys, the STP blink.** Each was information or
  convenience; none survived the "does it serve a two-second read while
  performing" test. What survived of their *functions* moved to the punch
  law, PARAMS, or the grid.
- **The dedicated UNDO/SAFE mechanism** → the ◄ slot. A safety system became
  one more thing the existing slot row already knows how to draw.

## 9. What got added — and why it earns its complexity

- **The punch law.** One timing rule (300 ms) buys: punch-in recording and
  overdub, filter sweeps that return by themselves, dub grabs, sequencer
  stutters, automation punch-in, scene peeking, and a mute stab — a whole
  gestural vocabulary for zero new controls. The single highest-leverage
  addition.
- **Scene peek + the ◄ slot + K1+E1 global morph.** Recall becomes fluid
  (audition before commit), undo becomes spatial (a slot you see), and
  morphing becomes pervasive (available mid-gesture on any page). Together
  they make risk cheap — the precondition for actually performing with the
  thing.
- **The ◇ purity mark.** One glyph, computed from ~10 param comparisons per
  frame, carrying the entire product identity.
- **The refusal shake + you-are-here dot.** Trust rendered at 2 px, replacing
  a text system.
- **The loop belt and the impulse scape.** Two new dominant objects; each
  replaces two competing readouts with one picture that answers
  direction/speed and echo/tail at a glance.
- **Mode-contextual VOICE macros.** The one place encoders re-map by state —
  accepted because the mapping follows *what is audible*, which is the most
  honest contract an encoder can have.

## 10. The 5 biggest structural decisions

1. **Nine stations on one signal path** — the page list *is* the
   architecture, taught by the header, bootable into the invitation.
2. **The punch law** — tap = latch, hold = punch, everywhere, including the
   grid and STOP itself.
3. **Macros + PARAMS-as-deep-layer** — four encoder targets per page, banking
   abolished, depth behind norns' own deliberate gesture.
4. **Safety as material, not mechanism** — the ◄ slot, auto-captured on every
   commit; peek-before-commit; one eraser gesture with an abort zone; chaos
   exiled to the grid corner.
5. **One truth system** — ◇ for purity, brightness for audibility, blink
   strictly for writing/pending, the shake for refusal: four channels, never
   mixed.

## 11. The 5 pages that changed most from the previous (compat-era) spec

1. **SPACE** — didn't exist; DELAY and REVERB died to make it, taking the
   bouncing ball with them.
2. **VOICE** — STRETCH+GRAIN merged, banking removed, mode-contextual macros,
   OFF removed from the cycle, reverse moved into the speed encoder.
3. **PADS** — absorbed SEQ, unified the slice cursor with the sequence
   target, gained gate/trig pads and run-stutter under the punch law.
4. **SCENE** — UNDO/SAFE keys and text chips replaced by peek, the ◄ slot,
   the you-are-here dot, and the shake.
5. **TAKE** — REC+WINDOW merged into one strip; the loupe's two panels and
   the reel-counter face are both gone.

## 12. The 3 things most tempting to keep out of habit — changed anyway

1. **The bouncing-ball DELAY body** — explicitly user-kept, and charming. But
   it only made sense while DELAY was a page; defending it meant defending
   the page split, which was the actual mistake.
2. **The banking system** — it worked, it shipped, and the alt-paired banks
   were clever. Cleverness was the tell: it was a workaround for exposing too
   much on the performance surface.
3. **MIX as page 1** — the "hard-left = home" reflex. Pre-release, the
   stronger idea wins: the take is the home of a take-centric instrument, and
   MIX belongs where the signal ends.

## 13. Why this feels like an S-4-caliber instrument

The same three moves the S-4 makes are structural here, in norns' own idiom.
**The architecture is navigable, not menu-shaped:** nine stations along a
drawn signal path, each with one object that shows the sound rather than
describing it — a strip, a texture, a ring, a curve, a scape, a console,
slices, a loop, slots. **The surface is macro-deep:** four curated targets
and two gestures per page, with all remaining depth one deliberate, native
gesture away — so no screen ever looks like a parameter list, and no page
asks a question it can't answer (the ◇ is lit or it isn't; the slot has the
dot or it doesn't; the ring spins the way the tape plays). And **performance
is gestural end to end:** the punch law turns record, reverse, freeze, open,
grab, bloom, run, and recall into the same physical vocabulary — stab it or
set it — with peek, the ◄ slot, and the global morph knob making risk
something you *play with* rather than recover from. Two seconds on any page
tells a stranger what's happening; two minutes on one page teaches the other
eight.

---

## Appendix A — target key/encoder map (quick reference)

| Page | E2 | E3 | K1+E2 | K1+E3 | K2 | K3 |
|---|---|---|---|---|---|---|
| TAKE | win start | win end | move window | jitter | REC | SNAP (take/full) |
| VOICE | mode macro A | mode macro B | speed | pitch | FRZ | MODE |
| TAPE | rate (±) | loop len | pre | loop pos | REC/ovr | REV |
| FILTER | cutoff | res | drive | dry/wet | OPEN | TYPE |
| SPACE | echo | verb | time | decay | INF | BLOOM |
| MIX | crossfade | out | in | monitor | ENG | TAPE |
| PADS | slice | hits | len | div | PAD | RUN |
| MOTION | lane (ALL…) | depth | — | — | REC | PLAY |
| SCENE | slot | morph | — | — | RCL | CAP |

Global on every page: K1 tap = PARAMS (deep) · K1 hold = shift · K1+K2 =
STOP · K1+K3 tap = DRY, hold-arc = ERASE page material · K1+E1 = morph toward
selected scene. All keys and grid pads obey the punch law (tap = latch, hold
= punch).

## Appendix B — decision log

**2026-07-15 · feedback round 1** (renders reviewed in the shot gallery):

- **TAPE = the belt**, picked over the ring ("kinda weird") and the strip.
- **Page name stays SPACE** — AIR / ROOM / ECHO considered and declined.
- **Measurement rails added** (FILTER freq rails + labels, SPACE time rails,
  MOTION loop quarters, TAPE quarter ticks) — restoring the old design's
  "grit you can measure by."
- **MOTION reworked:** lanes are dynamic (one per recorded param, from any
  page), drawn as automation curves with full footer-word names, one
  playhead crossing all lanes with live-value dots.
- **Approved as rendered:** TAKE, VOICE ("nice"), FILTER, PADS+SEQ merge
  ("surprisingly good"), SCENE.
- **GO:** begin modifying the mangler script to this spec (stages below).

## Appendix C — implementation stages (NU = new UI)

Each stage gates on `luac5.3 -p` + the render suite + dist rebuild before
the next begins (device gate at NU-4). No engine changes; fingerprint stays
61 throughout.

- **NU-1 · spine + chrome + punch law.** mangler.lua: PAGES → the nine
  stations; ENC_MAP/KEYS per Appendix A; the punch-law key engine
  (frame-counted on the 15 fps clock: press engages, release < 5 frames
  latches, ≥ 5 punches out; already-on → press disengages; K1+K3 tap = DRY,
  held 15 frames with a drawn arc = ERASE of the page's material; K1+K2 =
  STOP both ways); K1+E1 = morph-toward-selected-scene. mpages: the new
  header (title · ◇ · flags R/T/M/▸/FZ · dots 3-2-1-3) and footer (four
  quiet words, latched inversion, 1.2 s swell values, shift swap, hold-arc).
  Bodies may temporarily reuse old draws under the new chrome. Render suite
  re-pointed at the nine page names (goto_page is already name-based).
- **NU-2 · bodies.** Port the nine dominant objects from
  test/uisim/proto_redesign.lua, bound to real state: take strip (+ ready
  bracket, hatch on regen/resample), mode textures, the belt, curve + rails,
  scape + rails, console, slices + steps, motion curves (dynamic lanes),
  slots + rail.
- **NU-3 · behavior.** `pad_cursor`+`seq_slice` → one `slice` param; scene
  peek (K2 hold via the morph engine), the ◄ auto-slot on every commit,
  chaos exiled to grid/MIDI; motion dynamic-lane data model; params
  regrouped to mirror the nine pages (deep params PARAMS-only, groups
  ordered like the page ring); the ◇ purity computation.
- **NU-4 · grid spine** (rows 1–2 scenes + state, 3–6 page workspace, 7–8
  piano; punch law on pads; press-surface release routing kept) + polish
  (refusal shake, queue wedge, header flag blinking) + README + doc/ui
  gallery regen + the on-device gate.

## Appendix D — implementation mechanics (reference)

- Lua-only; fingerprint stays 61. The punch law is a small state machine in
  `key()`/grid handlers (press timestamp on the 15fps clock; 300 ms ≈ 5
  frames; erase arc 1 s ≈ 15 frames, drawn from the clock).
- Scene peek and K1+E1 global morph drive the EXISTING mscenes morph engine
  (`scene_morph_amt`); peek ramps it over ~4 frames and back.
- ◇ purity = ~10 param comparisons per frame in the header draw; no
  allocation.
- The ◄ slot = one more entry in `Mscenes.slots` written by every commit
  recall / chaos release (reuses `M.safe` machinery).
- `pad_cursor` + `seq_slice` → one `slice` param (the only param-layer
  change). PARAMS groups reorganized to mirror the nine pages.
- The render suite is name-based (goto_page/pfx) — page merges are a rename
  pass there, then full gallery + dist rebuild per the standing workflow.
- Grid: punch law + press-surface release routing (existing invariant);
  spine rows 1–2/7–8 constant, workspace rows 3–6 page-aware.
