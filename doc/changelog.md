# mangler change log

The per-change history of mangler, moved out of CLAUDE.md so that file stays a
manual. Oldest first. Each entry records what changed, why, how it was
verified, and what the device gate has to check. The current status and the
rules distilled from all of this live in CLAUDE.md.

## The status marker as it stood before the split (history; CLAUDE.md holds the live one)

**base is DEVICE-CONFIRMED at `count: 63` (2026-07-16: S21 + S22 Phase A engine + the NU-1..4 nine-station redesign + the 45th/46th/47th changes).** A LARGE UNTESTED BATCH now sits on top (**48th change**), still count 63, PENDING the next rsync + SYSTEM > RESTART + gate: the parked follow-ups now BUILT (per-pad **sound-locks** `pad_voice`/`pad_pitch`/`pad_level`/`seq_level`, async `load_wave`, S22 **Phase B** browsable stereo export, progressive FX mix curves, record-safety Limiter, per-note `amp`); a **Pi-4 perf pass** (allocation-free draw closures + reverb/shimmer moved into a **spawn/free `\mangler_reverb` synth** freed at rev_mix=0, InFeedback send/return); a **DFM1 diode-ladder filter** (guarded → stock biquad; the 3× always-on RLPF/RHPF/BPF is now ONE DFM1, BP = HPF of a resonant LP peak); the **pristine reverts** (cubic interp / tanh drive / transparent record Limiter / stereo shimmer all KEPT); an engine+Lua **comment cleanup**; and a **code-review fix batch**. ENGINE changed → confirm `count: 63` after RESTART (no new command). Grid code is sim-stubbed → any grid change is device-only. ON TOP OF THAT sits the **49th change (S23 Batch A, LUA-ONLY)** — play-test fixes from a voice memo: SPACE split into DELAY+REVERB (9→**10 pages**), delay-feedback range curve, tape record-source (dry/processed), motion loop-length, the blinking-window kill + read/write-head distinction, and the **sequencer REMOVED** (lib/mseq.lua deleted; `seq_slice` id KEPT as the PADS slice selector). No fingerprint change (still 63). **Batch B (true STOP + erase reliability) is ENGINE work, DEFERRED to a device session.** When you next deploy: the 48th batch still needs its RESTART; the 49th just needs a reload. ON TOP: the **50th change** (workflow-review batch — 11 Lua fixes + 8 small engine fixes, NO new command, count STILL 63, committed 0b4f045) the **51st change** (texture pass, ENGINE-only, count STILL 63), the **52nd change** (codebase cleanup — dead mparticles module REMOVED (7 libs now), dead scene state/bindings, list-drift fix, engine winRead consolidation), and the **53rd–58th changes** (footer pocket · send-style reverb · DFM1 headroom · quality-recheck batch incl. the 12x-too-weak grain_pitch_spread fix · PRINT + delay_sync + scene_next · doc staleness sweep + **doc/engine-map.md**, the plain-words map of every engine decision) ALL ride the same deploy: ONE rsync + RESTART covers every pending engine change, the reload covers the Lua. The **59th change** (ORBIT page, Lua + EROSION page, ENGINE +2 commands) moves the expected count to **65**. Everything through the **77th change** (the layers' loop-pedal law + SNAP, the 24-bit sample path, the windowed-sinc resampler, and three no-new-command engine edits) rides that SAME pending RESTART.

Bigger arc in flight (approved plan `~/.claude/plans/bright-shimmying-pearl.md`): grow into
a **maximally-capable sampler** — full-API **JPverb** (S10) + **MiClouds** granular (S11),
every UGen attribute wrapped as a real param (no hardcoding), reworked FX/GRAIN/PADS pages,
all **fully guarded** (`.asClass` build-time detect → stock fallback, can't brick). Land it
in **on-device-gated stages** (S9 done here; S10 → S11 → S12 each after its gate). Never write
the next stage before the current one's count + ear-check pass on the device.

S1 PASSED, S2 PASSED (stretch modes), S3 PASSED with UX iterations (tape looper:
one-button take workflow, K1+K3 clear). S4 adds the FX chain to the io synth's wet
path: LP/HP/BP filter, feedback delay (soft-clipped loop), FreeVerb — each FX with
its own dry/wet. Bring-up diagnostics (milestone prints, missing-poll warnings)
stay in — they cost nothing and have saved the day repeatedly.

Lua-only addition (untested on device): chromatic note input — MIDI note-ons set
`pitch` = 2^((note−root)/12), and a USB typing keyboard plays ableton-style
musical typing (A-row/W-row, Z/X octave) via `keyboard.code`. PARAMS > keys group
(enable / channel / root / octave / pitch quantize). No engine change,
fingerprint count unaffected.

Second Lua-only addition (untested on device): an optional **grid layer** — native
monome grid, or launchpad-family / APC mini via the **midigrid** library
(`include "midigrid/lib/midigrid"`, guarded by `util.file_exists` + `pcall`,
used only when no real grid holds grid vport 1). 8×8 layout: engine + tape
transport/mode toggles (rows 1–2), window and tape-loop slice pads with a
two-pad span gesture (rows 3–4), two piano octaves plus octave/reset/quantize
gap pads (rows 5–8). Every pad drives params. The grid controller's MIDI device
is filtered out of chromatic note input (`is_grid_vport`, see the dual-dispatch
gotcha below). Grid LEDs refresh on the existing 15fps clock, also while the
menu is open. No engine change, fingerprint count unaffected. On-device check:
pads toggle/light correctly, slice spans work, note pads retune, and a pad
press must NOT jump `pitch` to 0.25/4 (that means the note-input filter failed).

Third Lua-only addition (verified in tools/uisim renders, untested on device):
a screen polish pass — grouped page dots, alt-aware LEVEL faders (MON/HP),
FILTER/GRAIN top-right readouts, "EMPTY - K2 REC" on REC, the audibility rule
(see Workflow), and per-mode STRETCH textures. All draw-code only.

Fourth Lua-only change (verified pixel-identical in tools/uisim, untested on
device): mangler.lua is split into script-internal modules — lib/mfont,
lib/mparticles, lib/mtape, lib/minput, lib/mgrid, lib/mpages — loaded with
`include("lib/<name>")` and sharing one `ctx` table built in mangler.lua;
params stay the single source of truth. These are plain Lua modules, NOT
engines (the one-engine-file invariant is untouched), and at lib/ depth they
don't appear in norns SELECT. The seeded render suite matches the pre-split
output byte-for-byte and the bench shows no cost (0.076 ms/tick, ~0 garbage).

Fifth Lua-only change (renders verified, untested on device): performance +
depth pass. The UI hot path is now allocation-free (byte-table font
rendering, a pooled 32-slot particle system, static layout tables — ~0 KB
garbage/tick, ~19% faster, proven pixel-identical at the time). The GRAIN
cloud became a stereo-field plot (y = per-grain pan mirroring the engine's
clip law, dot size = grain size, saturation = density). Navigation: K1+E1
jumps between the dot families. Truth additions: grid row 3 glows the engine
write head while recording, REC parks OVR% top-right when overdubbing,
warp_rand shakes the WARP ghost (still at 0). README carries a rendered page
gallery (doc/ui/, regenerate from tools/uisim after any screen change).

Sixth Lua-only change (renders verified, untested on device): UX polish from
first play-testing (feedback log: doc/ux-feedback.md). Every top-right
readout knocks out its own pocket and the encoder flash draws in a framed
black box (legible over any page); page dots sit on one straight pixel row
(current page = wider dash, same row); footer hexagons became circular
dials; FILTER draws the engine's real RLPF/RHPF/BPF magnitude (log-f axis,
100/1k/10k + 0dB rails, filled passband, bright node dot at the cutoff);
WINDOW parks slice length in seconds and scatters jitter ghosts around the
playhead; REC badges RSMP when resample>0 and counts the take in seconds
(ctx.rec_arm_phase); MIX parks the E/T balance; LEVEL hints signal flow.
Every page now gives K2/K3 a job — MIX ENG/TAPE throws, LEVEL IN=0/OUT=0
unity resets, WINDOW FLIP (negate scan), GRAIN OCT−/OCT+ (alt), FILTER
OPEN, DELAY INF, REVERB WASH/KILL — all in the KEYS table, spec §10 updated.
The render suite seeds math.random (deterministic, diffable) and grew a
WINDOW_FLASH shot; dist rebuild byte-verified. Performance walkthroughs:
doc/workflow-standalone.md (keys+encoders only) and doc/workflow-grid.md.

Seventh Lua-only change (renders verified, untested on device): REVERB page
depth, loop 2 of the UX feedback (doc/ux-feedback.md §11–12). REVERB gains
a listener ring, a third ray (rays lengthen with size), and hash-dither air
whose density rides the mix; dormant at mix 0. A DELAY echo-tap-plot rework
was tried and **reverted on user request** — the bouncing-ball delay page
is the keeper (see ux-feedback §11; don't re-attempt unasked). The suite
grew DELAY_INF / DELAY_DRY / REVERB_DRY truth shots; dist re-verified
byte-identical (22 shots). NOTE: the empty-state render invocation is
`render_pages.lua mangler.lua <dir> base empty` — "empty" is the 4th arg;
passing it 3rd just renders the base scenario under an "empty_" prefix.

Eighth Lua-only change (renders verified, untested on device): MIX page
truth pass (doc/ux-feedback.md §14). The engine↔tape crossfade is a
plateau law (mtape.update_mix: `min(1, 2(1−mix))` per side, both decks at
unity around center); the page now scales lane energy by each deck's REAL
gain instead of the raw fader, draws the law itself between the lanes
(handle rides it), stills a fully-thrown-away lane flat-dim, and adds a
slim master VU (amp_out, sqrt law like LEVEL/REC) on the right edge with
a peak-hold tick (~1s decay, bright at clip — mix_peak module state).
Suite grew a MIX_TAPE full-throw shot; dist byte-identical (23 shots).
(The lanes+curve drawing was later replaced by TOWERS — see the tenth
change; the truth rules and the VU survive there.)

Ninth Lua-only change (renders verified, untested on device): REVERB page
redesigned as CATHEDRAL (doc/ux-feedback.md §13) — user-picked from 16
rendered candidates across two gallery rounds. Cross-section vault (one
bright rib + two dotted echo ribs, unit half-arch precomputed at load: no
per-frame trig) grows with size; starry air (hash dither, 3Hz twinkle,
inside-ellipse test) thickens with mix; two ray pulses arc source →
listener on parabolic paths; RT badge top-left (0.4+size*2.6 s — an
estimate, FreeVerb size→RT is not calibrated); dormant at mix 0. Suite
gained REVERB_WASH; dist byte-identical (24 shots).

Tenth Lua-only change (superseded by the eleventh): MIX page as TOWERS
(doc/ux-feedback.md §15). Replaced by VU PAIR below; the towers' master-VU
peak-hold state (mix_peak) was removed with it.

Eleventh Lua-only change (renders verified, untested on device): three
user-picked page redesigns from candidate galleries (doc/ux-feedback.md
§16). MIX → VU PAIR (a needle VU per deck, ENG/TAPE, crossfader between;
each needle rests at the deck's real gain and lifts with output, a
silenced deck's needle falls; dial geometry precomputed in VU_SC/VU_TK,
two cos/sin per frame). REC → REEL COUNTER (tape-deck face: REC lamp,
seconds counter, stereo input meter, 60s reel-usage bar, write head
sweeping while armed; suite gained a REC_REC shot). WINDOW → LOUPE
(waveform-editor overview+detail: buffer boxed up top, slice zoomed
full-width below, jitter fuzzes the detail playhead). LEVEL left as-is
per request. Dist byte-identical (25 shots). PORT GOTCHA: the VU-pair
`on` test must be `(d==1) and eng_on or (d==2 and tape_g>0)` — the
unguarded `d==1 and eng_on or (tape_g>0)` lights the engine needle
whenever tape plays (and/or precedence).

Twelfth Lua-only change (renders verified, untested on device): the
**"Toy" UI** — a whole-instrument screen redesign the user prototyped and
approved in an HTML recreation, chosen over keeping the piecemeal picks
(doc/ux-feedback.md §17). It supersedes the eighth–eleventh page bodies.
- CHROME (all pages): small 1x title top-left that never disappears; the
  status flags (REC/FZ/TR/TFZ) moved BESIDE the title as a blinking 3x3 dot
  + text (single glyphs R/F/T/Z if they'd cross x76); uniform page dots
  (first x=81, pitch 5, current = rounded 4x4). The **top-right readout
  pocket is gone** — E2/E3 values live in the footer row (fmt_value: cutoff
  kHz, pitch ST, rates x, times ms/s, 0..1 as %, else params:string; labels
  drop when the four strings would cross ~85px). Footer knobs are r8
  double-rings that flip to a FILLED disc (pointer knocked out) while their
  param is turning — the flash window is now ~1.2s (mangler.lua enc()).
- ALT MAP: FILTER+K1 → dry_wet / grain_level (D/W, GRN); REVERB+K1 →
  delay_mix / dry_wet (MIX, D/W) — filled into ENC_MAP alt slots (RLPF/RHPF/
  BPF expose only freq+rq, so the wet-path controls live here).
- BODIES reverted/rebuilt to the Toy spec: MIX = two lanes (ENG scatter +
  TAPE mirrored synthetic preview, TAPE_PREVIEW static buffer); LEVEL =
  two stereo meter bars (L/R segments, peak-hold pip decay 0.0045/frame,
  clip lamp >0.93, gain tab); GRAIN = pooled stereo grain field (GR_MAX 110,
  spawn p=0.06+densityN*0.62, life 12+sizeN*26, len 1+sizeN*9, pitch tilts
  vertical drift); TAPE = fixed reels (hub + 3 spokes r2.5→6.5, guides
  y16/y32); REVERB = top-down room + bouncing rays + a periodic source
  ping (period 56f); FILTER = response curve + shimmering spectrum ticks
  (reseeded every 4f); REC = strip + cloud + 14px write-head afterglow;
  WINDOW = strip + jitter ghosts; DELAY/STRETCH unchanged but de-topright.
  Removed the VU/ARCH precompute + DOT_X + topright/flash-pocket.
- Allocation-free hot path preserved (LEVEL uses static LVL_TICKS + the
  preallocated grain pool; no per-frame table literals in draw_body).
- SIM FIX: tools/uisim `screen.fill()` now fills circle paths too (norns
  fills a circle; the pixel sim previously dropped it, so filled knobs
  rendered blank). Suite gained FILTER_ALT / REVERB_ALT / GRAIN_PITCH shots;
  dist byte-identical (42 shots across base/empty/filter/grain).

Thirteenth change — **ENGINE CHANGE (S5 gain pass), deploy ritual required,
completely untested (no SC compiler here)**: first-play feedback was "audio
changes too subtle, volume too faint" (doc/ux-feedback.md §18, spec §9b).
In Engine_Mangler.sc: grain overlap compensation (boost-only ≤2× below
overlap 1); new `drive` command — post-filter tanh with pre.sqrt makeup
(ioKeys + io arg, fingerprint 30 → **31**); delay/reverb mixes linear →
equal-power (linear cut the direct path −6dB at center); reverb return ×2,
damp 0.5 → 0.35; resonance rq = 1−res·0.92 floor 0.05 (was 0.85/0.1).
Lua: `drive` param in grp_filter (count 3 → 4), DELAY E3-alt = drive
(SHORT "DRV"), FILTER-curve constants mirrored in lib/mpages.lua. The Lua
side no-ops against an old engine (`if engine[id]` guard), but the page
curve then overstates resonance until the new .sc is live — deploy both
together. Same pass, a TONE half (no new commands, fingerprint still 31):
GrainBuf/Warp1 interp 2 → 4 (cubic); delay feedback LPF'd at 3.5k (repeats
darken); master Limiter(0.98) before RecordBuf/out. ALL core SC — no plugin
deps, cannot brick loading. Gate criteria in spec §9b. The bigger
"better sounding" swings (DFM1/MoogFF filter, MiClouds granular) need
sc3-plugins / mi-UGens confirmed-installed first (a missing UGen hangs every
script on LOADING) — parked as spec §11 options, a user decision.

Fourteenth change — **ENGINE (S6 reverb), same untested batch as S5,
fingerprint still 31**: user picked "reverb → JPverb" from the §11 menu.
FreeVerb → **JPverb** (sc3-plugins) for a lush hall/plate. THE SAFETY
PATTERN (reusable for any plugin UGen): detect at SynthDef-BUILD time with
`"JPverb".asSymbol.asClass` — the `.if` runs in sclang when the def is
`.add`ed, so only ONE branch's UGens compile into the graph; a missing
plugin picks the FreeVerb fallback instead of failing to compile (which
hangs every script on LOADING). `jpClass.ar(wet.sum*0.5, t60, damp, size)`
uses positional args (keyword args don't survive perform-dispatch on a
var-held Class). rev_size → t60 (0.4..6.4s); JPverb damp/size/mod fixed for
now (exposing them as params is the follow-up once confirmed live). No new
command, so the fingerprint stays 31. UNTESTED — if JPverb IS installed and
the arg order is wrong it errors in the SC tab; if it's absent you get
FreeVerb (louder, from S5).

Fifteenth change — **ENGINE (S7 granular character), user-supplied .sc
confirmed + wired, fingerprint 31 → 34, UNTESTED**: the user rebuilt
`SynthDef(\mangler_grain)` (+ two envelope buffers filled BEFORE s.sync in
alloc, + their frees). Reviewed against intent — matches, all stock UGens
(Dust/TRand/Select/Env), no plugin deps. Impulse.kr → **Dust.kr** (both
channels: kills the periodic buzz + decorrelates L/R). THREE new commands
in playParams (grain_jitter, grain_pitch_spread, grain_shape) → count
31→34. NB the Dust swap means defaults are NOT byte-identical to S6 (that's
change #1, intended); the "identical to before" regression guard is about
the three NEW params being true no-ops at 0 (durL=size, pchL=pitch,
envSel=-1=built-in Hann). WARP/PV only got the new args in their lists so
setMode's uniform pass doesn't warn. DO NOT move the pre-sync buffer fill.
Lua wiring: grp_grain 6→9 (grain_jitter/grain_pitch_spread add_eng_control,
grain_shape add_option HANN/WELCH/PERC with `-1` in set_action like `mode`);
grain_shape cycles on GRAIN **K1+K3** (k3_alt "SHP", the free key slot);
the two continuous params are PARAMS-only (like `pan`) + VISUALISED on the
grain field (GJIT = per-grain tick-length variance, DTUN = per-grain
vertical fan via a new gr_dj pool array) — both guarded `> 0 and … or 0` so
at default they make NO extra math.random call and the seeded GRAIN renders
stay position-identical. Shape reads top-left. Suite gained GRAIN_CHAR;
dist byte-identical (44 shots). I CANNOT run the device — command count 34
is a STATIC trace (ioKeys 17 ∪ playParams 18, −2 shared, + mode); the user
must restart and confirm.

Sixteenth change — **ENGINE + LUA (S8 polyphonic voices), user-supplied
.sc applied + a NEW Lua layer built, fingerprint 34 → 40, UNTESTED (no SC
compiler, no device here)**. Engine (source of truth, reviewed correct):
two voice defs (mangler_voice_grain / mangler_voice_slice), an allocator
(noteOn/noteOff/noteOneShot, oldest-steal at `voices` cap), voices spawn
into playGroup + Out.ar-add onto play_bus (mix with drone, through io FX).
+6 commands (note_on/note_off/note_one_shot/voices/voice_atk/voice_rel) →
count 40 (STATIC trace: 33 union + 7 explicit). io/drone defs untouched.
LUA (built here): **PADS page = page 11** (PAGES/ENC_MAP/KEYS all extended;
header dot pitch now fits >10 pages via `min(5, floor(45/(#PAGES-1)))`).
grp_voice params: `pad_input` (binary, default 0), `voices` (add_number
1..16), `voice_atk`/`voice_rel` (add_eng_control). 8-slice pad bank in
`ctx` (pad_type[0..7], pad_cursor, pad_held id→padidx). Dispatch in
mangler.lua: `ctx.route_note(id,pitch,pad_idx,z)` sends notes to the mono
drone `pitch` (default) OR polyphonic voices (`pad_input`=1); minput +
mgrid.grid_note_key both refactored to call it on BOTH edges (were
press-only) — DEFAULT-OFF so drone behavior is byte-preserved. Stable ids:
screen 0..8 (audition=8), MIDI 1000+note, grid 2000+(y*8+x). GOTCHA:
momentary K1+K2 audition (id 8) is closed in `key()` on any K2 release,
NOT via a def.release callback (release is alt-sensitive and would strand
the voice). `pad_input`→0 and cleanup both call `ctx.pads_all_off()`. PADS
body: 4×2 cells (GRN/SLC per pad, lit when a voice sounds, cursor border),
PAD/DRN routing + used/cap readout. Suite gained PADS + PADS_LIVE; dist
byte-identical (46 shots). RESERVED-ID watch: `voices`/`voice_*`/`pad_input`
aren't in the known system-param list, but confirm no "refusing to clobber"
on device. note_one_shot is available but unused (pad model is held).

Seventeenth change — **S9 headroom + HOME page (engine gain constants +
Lua/doc, fingerprint STAYS 40)**: first of the staged sampler rework. Engine:
per-voice amp 0.5→0.3 (voiceParams) + master Limiter 0.98→0.92 — fixes the
S8 chord-clipping (poly voices summing slammed the limiter into pumping); no
new command, so **still 40** (a restart is still required — gain lives in the
.sc). Lua: a **HOME page** added as **page 1** (seen on load) — signal-flow
chain IN→REC→SRC→FX→OUT (HOME_FLOW/HOME_BX statics), live output meter, cheat-
sheet; ENC_MAP.HOME = master out/in/dry_wet/mix, KEYS.HOME = PANIC
(pads_all_off) / PADS (toggle pad_input). PAGES now 12; PAGE_GROUPS
{1,2,5,8,9,12}; header dot pitch already adapts. GOTCHA handled: adding HOME
shifted every page index, so **the render suite is now name-based** — a
`goto_page(name)` + `pfx(name,suffix)` (index from PAGE_IDX) replaced all the
hardcoded `enc(1,N)` + `_NN_` offsets (robust to future page changes). README
rewritten toward a sampler manual (HOME hero + quickstart + guarded-plugin
note); gallery regenerated (16 pngs, shifted indices). dist byte-identical
(47 shots).

Eighteenth change — **S10 full-API JPverb (engine + Lua, fingerprint 40 →
50)**: the reverb block now wraps JPverb's ENTIRE attribute set as args (no
hardcoding) — +10 ioKeys commands (rev_decay/damp/early/moddepth/modfreq/
low/mid/high/lowcut/highcut). Still guarded (.asClass → FreeVerb fallback
whose roomsize = rev_decay.linlin, damp = rev_damp). `rev_size` REPURPOSED
from 0..1 to JPverb's 0.5..5 size — the REVERB page viz now reads
`param_norm("rev_size")`, keep that in mind. grp_reverb 2 → 12 params. UI:
REVERB is now a **banked editor** — E2/E3 edit one REVERB_BANKS pair; K2
"BANK" calls `ctx.rev_next_bank()` which rewrites `ENC_MAP.REVERB[1]/[3]` in
place (so the footer/enc resolver need no change); a "BK n" chip shows the
bank. SCOPE GOTCHA: the bank cycler lives in `ctx.rev_next_bank` (defined
after ENC_MAP/REVERB_BANKS) because KEYS is declared BEFORE them — a closure
in KEYS can't upvalue a later `local`. Suite: REVERB_ALT shot → REVERB_BANK.
dist byte-identical (47 shots).

Nineteenth change — **S11 MiClouds granular drone (engine + Lua, fingerprint
50 → 55)**: GRAIN mode now runs a **MiClouds** (mi-UGens Clouds port) granular
voice when the plugin is installed, else the S7 GrainBuf drone. GUARDED TWO
WAYS so it can NEVER brick LOADING: (1) the class is resolved via
`"MiClouds".asSymbol.asClass` (no literal reference — the .sc compiles without
mi-UGens), (2) the whole `\mangler_clouds` def is wrapped in `try {} {|e|
hasClouds=false …}` so a wrong graph/arg set degrades to GrainBuf instead of
failing alloc. Architecture: a BufRd scrubs the recorded window (the same
scan/pos Phasor the GrainBuf drone uses) → feeds Clouds; `pv_freeze` doubles
as the clouds freeze. `cc.ar` uses POSITIONAL args (keyword args don't survive
perform on a var-held class) — order: in, pit, pos, size, dens, tex, drywet,
in_gain, spread, rvb, fb, freeze, mode, lofi; our size/density/pitch remap to
Clouds' 0..1 / semitone ranges. +5 playParams commands (clouds_pos/tex/fb/mode/
lofi, auto-wired by the addCommand union loop; setMode re-applies them). NOTE:
the MiClouds arg order/semantics are my best-knowledge and UNVERIFIED — the
device gate must confirm (the guard means a wrong-but-present arg posts in the
SC tab / falls back, rather than bricking). UI: GRAIN became a **banked editor**
(GRAIN_BANKS, `ctx.grain_next_bank`, same in-place ENC_MAP rewrite as REVERB) —
E2/E3 page size/density · spread/tex · pos/fb · level/lofi; K2 BANK, K3 MODE
(cycles the 4 Clouds modes), octave throws moved to the key-alt layer;
grain_shape (SHP) retired to PARAMS. dist byte-identical (48 shots).

Twentieth change — **S12 PADS slice-sampler rework (Lua-only, fingerprint
STAYS 55)**: the PADS page read as abstract 4×2 cells ("not sure what it is").
Redrawn as **the recording chopped into 8 slices** — the buffer waveform under
8 slice boxes (GRN/SLC per pad, lit while sounding, bright cursor border), a
plain-words routing header (**NOTES>PADS** lit / **NOTES>DRONE** dim) and a
used/cap voice count, with the "EMPTY - K2 REC" invitation when there's no
take. So a "pad" is self-evidently an eighth of what you recorded, played
polyphonically over the drone. New key: PADS **K1+K3 = ROUTE** toggles
pad_input right on the page (was HOME-only). Keys otherwise unchanged (K2 SEL
cursor, K1+K2 PLAY audition, K3 TYPE grain/slice); encoders VOX/ATK/REL. Pads
still slice the whole buffer at i/8 (per-pad position + the optional guarded
DFM1 filter were deferred — JPverb/MiClouds were the named asks). dist
byte-identical (48 shots).

Twenty-first change — **HOME page REMOVED + README quick-guide + S13
dry-by-default drive (fingerprint STAYS 55)**: user feedback — the in-script
HOME page was a misread (they wanted the *README* to be the front-page guide,
not a norns-screen page eating a slot), and a fresh recording should sound
like the **exact dry sample**, FX added on top. (a) HOME page fully reverted:
PAGES back to 11 (MIX first again), PAGE_GROUPS {1,4,7,8}, ENC_MAP/KEYS/mpages
HOME removed, render suite PAGES + doc/ui/home.png gone (the name-based
`goto_page`/`pfx` render harness from the Seventeenth change STAYS — it's what
made adding+removing HOME a clean index shift). (b) README rewritten as a
fast, skimmable quick-guide ("play it in 60 seconds", dry-by-default called
out, tightened reference). (c) Engine S13: `drive` is now
`XFade2.ar(clean, tanh(driven), drive*2-1)` so **drive=0 is a TRUE bypass**
(was an always-on tanh that soft-clipped a fresh recording) — no new command,
still 55. Confirmed dry defaults: delay_mix=0, rev_mix=0 (delay+reverb OFF by
default — a fresh take plays clean). dist byte-identical (47 shots).

Twenty-second change — **S14 clean PLAY drone (default) + alt-paired banks
(engine + Lua, fingerprint STAYS 55)**: user wanted a fresh take to loop back
as the EXACT recorded sample (not granulated), and the banked editors to use
the alt layer so there are fewer banks. (a) Engine: new `\mangler_play` def —
a straight BufRd loop of the window (scan = speed, pitch = varispeed resample),
all core UGens (can't brick). setMode gets an `i==4` case; **mode option is
now {OFF,GRAIN,WARP,PV,PLAY}, default PLAY** (appended, so 1..4 keep meaning —
no renumber). No new command → still 55. STRETCH MODE key cycles `%5`; grid
mode radio widened to x=3..7; STRETCH page draws PLAY as a solid unbroken wave;
render suite STRETCH loop + MIX_OFF restore updated to mode 5. (b) REVERB_BANKS
6→**3** and GRAIN_BANKS 4→**2**: each bank entry is now `{E2,E3,E2alt,E3alt}`
(4 params) and the cyclers rewrite all four ENC_MAP slots, so K1 (alt) reaches
the second pair within a bank. Seeds + `ctx.*_next_bank` updated. dist
byte-identical (48 shots). NB the reverb "no audible difference" report is
almost certainly JPverb-absent → FreeVerb fallback (only decay/damp/mix respond,
the other 9 params are no-ops) — a plugin-install issue, not a bug.

Twenty-third change — **GRAIN page = mode-aware drawing (Lua-only, fingerprint
STAYS 55)**: the GRAIN visualization now branches on `clouds_mode` (K3) so the
chosen option BECOMES the picture — GRANULAR = the discrete grain cloud (kept
byte-identical, still the only path that spawns from the seeded pool), STRETCH
= overlapping elongated fade-ended windows (density=layers, size=length,
tex=core fill, pos=center, lofi=dash), LOOP = a loop bar with boundary caps +
a read head + echo ghosts (fb=ghost count & `fb^i` persistence, pos=position),
SPECTRAL = vertical FFT columns around a centroid (pos=centroid, size=width,
tex=roughness, lofi=quantize). The 3 non-granular modes are FULLY PROCEDURAL
(frame + the existing `hash()` helper — no math.random, no per-frame tables/
closures), so GRANULAR's RNG stream and its seeded render stay byte-identical.
Silence (drone OFF / empty buffer) collapses every mode to a flat dim
centerline. Suite gained GRAIN_CL_GRANULAR/STRETCH/LOOP/SPECTRAL shots (52
total). dist byte-identical. (Done via the grain-page-designer subagent.)

Twenty-fourth change — **REVERB + PADS page redesigns (Lua-only, fingerprint
STAYS 55)**: user feedback — the REVERB top-down "room box" didn't read, and
PADS still wasn't landing. (a) REVERB is now a **decay tail / impulse
response**: a bright onset spike at t=0, then reflections decaying left→right,
under a dim envelope-curve guide + a decay-end tick. tail length = rev_decay
(t60), rev_damp = decay exponent (steeper), rev_size = reflection spacing, mix
= density/height; dormant flat at mix 0. All procedural (hash+frame), no room/
rays/ping. (b) PADS split into **the recording on top** (thin wave + 8 slice
dividers + playhead) and **8 pad BUTTONS below, aligned under their slices**
(so pad n = slice n is visible), each GRN/SLC, lit while sounding, cursor
bordered; header now "PLAY>PADS" / "PLAY>DRONE". dist byte-identical (52
shots). Both were reruns of prior designs the user rejected (top-down room,
8-boxes-on-the-wave) — don't restore those unasked.

Twenty-fifth change — **S15 shimmer reverb (engine + Lua + UI, fingerprint
55 → 58) — landed earlier but never logged here; full detail in spec §S15**:
pitch-shifted reverb feedback (PitchShift(+shimmer_pitch) → HPF120 →
LPF(shimmer_tone) back into the verb, scaled by `shimmer`), +3 commands
(shimmer/shimmer_pitch/shimmer_tone). The delay + shimmer feedback loops
MERGE into one LocalIn.ar(4) (SC allows one LocalIn/LocalOut per SynthDef).
Lua: grp_reverb 12→15, a 4th REVERB bank SHIMMER, SHMR bloom key (K1+K3),
upward motes on the decay tail. Suite: REVERB_SHIMMER (53 shots). Gate:
count **58**. DEVICE NOTE (2026-07-11): mi-UGens are now properly installed
— the user's `dust/code/mi-UGens` clone had duplicated the classes paracosms
already keeps in `~/.local/share/SuperCollider/Extensions/supercollider-
plugins/`, hanging EVERY script (DUPLICATE ENGINES); deleting the clone fixed
it. NEVER install .sc class files under dust/code outside an `ignore/`
folder. Also: stock norns ships sc3-plugins, so JPverb is likely PRESENT —
recheck the old "reverb sounds the same" report before blaming the fallback.

Twenty-sixth change — **master STOP/START (Lua-only, fingerprint STAYS 58)**:
user asked for a start/stop key. New `stop_all` binary param (grp_mix 4→5,
MIDI-mappable — map a pedal): STOP chokes BOTH decks inside Mtape.update_mix
(the one place engine.level + the softcut voice levels are computed; levels
slew, so stop/start are click-free) and releases the pad voices
(pads_all_off); everything else keeps running silently — mode, tape head,
loops — so START restores the exact mix instantly. Surfaces: **MIX K1+K2**
(STOP pill, lit while stopped — from anywhere: hold K1, E1 hard left, tap
K2), **SPACE** on the typing keyboard (handled BEFORE the keys_enable gate —
it's transport, not note input — but AFTER the menu gate so typing spaces
into a PSET name can't stop sound), **grid (8,2)** (blinks while stopped),
and a blinking **STP header flag** on every page (STATUS_STR/ABBR grew to
5 bits / 32 combos). Suite: MIX_STOP + MIX_STOP_ALT (55 shots), all prior
shots byte-identical; dist rebuilt + byte-verified. Untested on device
(Lua-only: save + reload).

Twenty-seventh change — **dry-guarantee engine review + DRY throw + global
alt STOP/DRY (Lua-only, fingerprint STAYS 58)**: user reported "reverb mixed
into the dry recording". ENGINE REVIEW VERDICT (read, not run): the record
path CANNOT capture FX — \mangler_io records `in*(1-resample) +
sig*resample`, so at resample=0 the take is the raw ADC tapped before the
whole chain; every wet mix is a true zero at 0 (equal-power .sqrt laws,
shimmer output-gated, drive an XFade2 bypass); the MiClouds positional args
were VERIFIED against v7b1's MiClouds.sc (in, pit, pos, size, dens, tex,
drywet, in_gain, spread, rvb, fb, freeze, mode, lofi) — rvb (Clouds'
internal reverb) is hard 0. Reverb heard on "dry" playback is therefore:
(a) rev_mix/delay_mix left up in the session (JPverb going live makes old
barely-audible values lush, decay to 30s), (b) **clouds_fb** (GRAIN bank 2
E3 — washes like a reverb, the REVERB page can't kill it), (c) the norns
SYSTEM aux reverb (PARAMS > REVERB — init() now prints a maiden NOTE when
it's on), or (d) recording with resample>0 (bakes FX into the take, by
design). Fixes: **ctx.fx_dry()** zeroes delay_mix/rev_mix/shimmer/drive/
clouds_fb + throws the filter open (FILTER OPEN law), on **K1+K3** + grid
(7,2); and after "start/stop not working" feedback the alt transport pair
went GLOBAL — key_def's alt fallback is now ALT_STOP/ALT_DRY (was
fall-back-to-unalt), so **K1+K2 = STOP / K1+K3 = DRY on every page whose
alt slot is unclaimed** (all but GRAIN/TAPE/PADS for K2; plus REVERB for
K3) — hold K1 anywhere and the pills show which pair you have. Suite:
LEVEL_ALT/FILTER_ALT/DELAY_ALT intentionally re-rendered (STOP/DRY pills),
MIX_STOP + MIX_STOP_ALT added (55 shots); dist rebuilt + byte-verified.
REMEMBER: none of this exists on the device until the repo is rsync'd and
the script reloaded.

Twenty-eighth change — **S16 gesture looper / motion recording (Lua-only,
fingerprint STAYS 58, renders verified, untested on device)**: the "fourth
driver" from the innovation brainstorm — records the param stream and replays
it, a modulation loop pedal for a 3-knob box (full design: doc/spec.md §S16).
NEW module **lib/mmotion.lua** (7th lib; amalgamate assert 6→7). It wraps
`params.set`/`params.delta` (restored in cleanup) so every key/encoder/MIDI/
typing move flows through `on_change`; captures only `MOTION_IDS` (the
performance/mangle params — NOT levels/keys/transport/motion_*). Data model:
ONE loop, per-param **lanes** (`lanes[id]={f,v,n,cur,last_fire}` flat arrays,
`loop_len` in FRAMES on the 15fps grid — no new clock), **punch-in replace**
(first touch of a param in a pass clears its lane). A **`replaying` guard**
around the playback fires stops the loop re-recording itself (no runaway).
`Mmotion.tick()` runs in the redraw clock: advances the playhead, fires each
lane's events at `f==playhead`, wraps, auto-disarms an overdub after one full
loop. `motion_depth` (E3) scales continuous lanes toward their baseline (living
loops); discrete params pass through. Transports are **binary params**
(`motion_rec`/`motion_play`, MIDI-mappable → footswitch overdubs); `motion_lane`
(E2) browses lanes. Lua wiring: **MOTION = page 12** (PAGES/PAGE_GROUPS
{1,4,7,8,**12**}/ENC_MAP/KEYS), grp_motion (4 params), `ctx.motion`,
`Mmotion.tick()` in the clock, `Mmotion.cleanup()` restores the wrapped methods.
KEYS.MOTION claims its alt slots (K2 REC / K3 PLAY / **K1+K2 CLR-L** /
**K1+K3 CLR**) so global STOP/DRY aren't on MOTION (like GRAIN/TAPE/PADS). UI:
body_MOTION = loop timeline + sweeping playhead + one lane-row per param (name +
events plotted low..high, selected/just-fired brighten); empty-state invitation;
FULLY PROCEDURAL (no math.random → other pages' seeded renders stay byte-
identical). Adding page 12 legitimately adds a 12th header dot to EVERY page, so
the whole doc/ui gallery was regenerated (+ motion.png). Suite: MOTION_EMPTY/
_REC/_PLAY + base_12_MOTION; dist rebuilt + byte-verified (source==dist across
all 172 shots ×4 variants). DEVICE GATE (doc/spec.md §S16): save + reload, count
still 58; K2 arms, sweep a knob, K2 stops → it loops hands-free; overdub a 2nd
param; re-record replaces one lane; CLR-L/CLR; footswitch maps motion_rec; **check
MIDI-mapped CC moves get captured** (pmap CC should route through paramset:set —
if a firmware path bypasses it, notify from the add_eng_control action closures);
no runaway (loop 10×, lane count constant); watch xruns/GC.

Twenty-ninth change — **S17 self-resampling / regen (ENGINE + Lua, fingerprint
58 → 59, UNTESTED — no sclang here, gate pending)**: the self-resampling half of
the innovation brainstorm — the sampler eats itself. `resample` already blends
the post-FX output into the record buffer but ONLY during an armed `rec` pass;
S17 adds **`regen`** (new ioKeys command → **59**): the io record head runs
CONTINUOUSLY when manual `rec` is off + not frozen, crossfading the processed
OUTPUT back into the buffer so the granular/FX engine slowly re-mangles its own
sound (Basinski decay). THE SAFETY (three guards, full detail doc/spec.md §S17):
(1) BOUNDED — a convex crossfade `preLvl+recLvl=1` (both ≤1) + output
Limiter(0.92) + `LeakDC` on the feedback source → the buffer can't run away;
(2) BIT-IDENTICAL at regen=0 — `regenRun = (regen>0)*(1-rec)*(1-freeze)`; at 0 →
`runW==recRun`, `src==recL/R`, levels unchanged → the exact old RecordBuf (the
`×0` term is exactly 0); (3) can't brick — all core UGens (RecordBuf/LeakDC), no
plugin deps. manual `rec` (the `(1-rec)` factor) and `freeze` both suspend regen.
Lua: `regen` in grp_rec (6→7); **REC page** E3/E3-alt are now `resample`/`regen`
(the two "output→buffer" controls; `dry_wet` left REC — still on FILTER+K1); a
**REGN badge** lights beside RSMP while regen>0 (SHORT `REGN`). Suite: REC_REGEN
shot, rec.png regenerated (footer now RSMP not D/W); dist rebuilt + byte-verified
(source==dist, 176 shots ×4 variants). KNOWN LIMITS (device follow-ups, don't
pre-build): the record head traverses the whole 60s buffer so the take is
re-touched ~once/minute (slow ambient decay by design; a window-synced BufWr
variant is faster); `wave[]` only repaints on `rec` so the morphing buffer isn't
drawn (badge signals it's live); a Lua-only alt route is `audio.level_eng_cut`
(tape loops the output). DEPLOY: this is an ENGINE change — **RESTART + confirm
count 59**, then run the §S17 gate (regen=0 identical; regen up on a take → it
evolves without runaway even at 1; rec/freeze suspend it).

Thirtieth change — **S16 capture bugfix: wrap → polling (Lua-only, fingerprint
STAYS 58/59)**: DEVICE REPORT — "motion doesn't work, it doesn't play the
recording." Root cause: the S16 gesture looper CAPTURED by wrapping
`params.set`/`params.delta`. That passed the offscreen sim (which only drives
`params:set`), but on the real norns an **encoder** turn goes through
`params:delta` → the individual param's `delta`, which never re-enters the
wrapped paramset `set` — so a knob gesture recorded NOTHING (no lanes → PLAY
never armed → silence). FIX: `lib/mmotion.lua` now captures by **POLLING** —
each frame while armed, `tick()` reads every `MOTION_IDS` param and appends an
event when its value changed vs `last_val` (baselined by `snapshot()` on arm).
Robust to ALL drivers (encoder/key/MIDI/typing) because it only reads resolved
values. No wrap, no `cleanup` restore, no `replaying` flag; runaway is prevented
by writing the fired value into `last_val` right after playback sets it (so the
poll skips the loop's own output). Data model / page / transport unchanged.
Renders still show the CUT/MIX lanes + sweeping playhead; dist rebuilt +
byte-verified (source==dist). LESSON for the render sim: its `params:set` stub
does NOT model that `paramset:delta` bypasses `paramset:set` on hardware — a
capture mechanism that intercepts calls can pass the sim yet miss the encoder
path on device. Save + reload (Lua-only).

Thirty-first change — **S18 step sequencer / SEQ page (Lua-only, fingerprint
STAYS 58/59, renders verified, untested on device)**: the "sequencer pillar"
toward a workstation (the Torso S-4 comparison) — a clock-synced **Euclidean**
step sequencer. NEW module **lib/mseq.lua** (8th lib; amalgamate assert 7→8),
built after the user shared their `snu` sequencer and asked to fold it in as a
page + add a Euclidean option. v1 SCOPE (deliberately small — untested surface):
ONE track, up to 16 steps, an on/off `pattern[]` from a Euclidean fill
(`seq_euclid` hits over `seq_len`, Bresenham `acc+=k; if acc>=n then acc-=n,hit`).
Each active step fires `engine.note_one_shot((seq_slice+0.5)/pad_n, 1.0,
pad_type[seq_slice])` — a fire-and-forget slice one-shot over the drone. NO engine
change (drives the existing S8 note_one_shot) → fingerprint untouched, can't
brick. CLOCK: ONE `clock.sync` coroutine, `M.start` on seq_play=1, always
`clock.cancel` on stop + in `cleanup` (the clock.lua resume-race gotcha);
`seq_div` = 1/2·1/4·1/8 beats (8th/16th/32nd); `M.pos` advances on the musical
clock, redraw only reads it. Params (grp_seq, 5, Lua-only): seq_play (binary,
MIDI-map a footswitch), seq_div (option), seq_euclid (0-16, action regens live —
turning E2 IS the generator), seq_len (1-16, regens), seq_slice (0-7). **SEQ =
page 13** (PAGES/PAGE_GROUPS{…,13}/ENC_MAP/KEYS): E2 hits · E2alt clock_tempo
(system param, referenced) · E3 len · E3alt div; K2 PLAY, K3 SLICE (cycle),
alts stay global STOP/DRY. body_SEQ = two rows of 8 cells (active filled, rests
outlined, playhead inverts), hits/len top-right, slice+run-state top-left, empty
invites "EUCLID: TURN E2 FOR HITS"; fully procedural (no math.random). Adding a
13th page dropped header-dot pitch 4→3, so the WHOLE doc/ui gallery was
regenerated (+ seq.png). SIM NOTE: the render leaves seq_play=0 so the offscreen
clock isn't engaged (the sim's clock.run reassigns the redraw coroutine) — the
page still shows the generated pattern. Suite: SEQ_EUCLID + base_13_SEQ; dist
rebuilt + byte-verified (source==dist, 8 modules inlined). FOLLOW-UPS (staged,
don't pre-build): per-step pitch (scale) + per-step slice, grid step-editing,
multiple tracks + CC/param-lock lanes, patterns + chaining, more generation
(probability/ratchets/rotation). Gate: doc/spec.md §S18. Save + reload (Lua-only).

Thirty-second change — **S18 bugfix: sequencer was silent (note_one_shot →
note_on, Lua-only)**: DEVICE REPORT — "the sequencer doesn't work, it plays
nothing." Root cause: S18 fired `engine.note_one_shot`, which the S8 log itself
flags "available but unused" — the one-shot voice path was NEVER tested, and its
gate (`Trig.kr(Impulse.kr(0), sustain)`) produced no sound on device. Secondary:
it triggered WHOLE-buffer slices `(slice+0.5)/8`, silent for a short take (the
pads' known whole-buffer-slice limitation). FIX (lib/mseq.lua, no engine change):
fire a **MONO voice via the TESTED `note_on`/`note_off`** path (what PADS use) at
a **window-relative** position `pos = lo + (seq_slice+0.5)/pad_n · span` (via
`ctx.window_bounds`), so it always lands on the recorded take. note_off releases
the previous voice before note_on (no leak — the engine's noteOn doesn't self-
steal a reused id); rests release; `M.stop` + cleanup release the last voice.
Voice id 2500 (clear of screen 0-8 / MIDI 1000+ / grid 2000+). SEQ page/params/
clock unchanged; renders byte-identical, dist rebuilt + verified. LESSON: don't
build on an engine command that's never been ear-confirmed — note_one_shot
looked right but was dead. DIAGNOSTIC recorded in §S18 (playhead moving ⇒ clock
OK ⇒ audio-path bug; not moving ⇒ clock). Save + reload (Lua-only).

Thirty-third change — **S18 grid support: page-aware SEQ view (Lua-only)**:
DEVICE FEEDBACK — "no mini grid support, I can't see the sequence on the grid
like snu." Made mangler's grid **page-aware** (it was a fixed page-independent
surface): `is_seq_page()` in lib/mgrid.lua → while the SEQ screen page is
active the grid becomes the sequencer, otherwise it's the normal mangler
layout (like snu, whose grid follows the page). Layout: rows 1-2 = the 16
steps (tap toggles via new `Mseq.toggle_step`; playhead brightest, active mid,
rest dim, beyond-length dark), row 7 = slice select, row 8 = play/clear
(`Mseq.clear`). Euclid is the GENERATOR, grid taps edit steps on top; with
seq_euclid=0 you can hand-draw a pattern (body_SEQ now counts ACTIVE steps, not
just hits, so a grid-built pattern shows; empty invite → "TURN E2 - OR TAP
GRID"). Works with midigrid launchpads (the user's "mini grid") the same as the
rest of mangler's grid. NO engine change; renders byte-identical (grid is
stubbed in the uisim, so the grid code is UNTESTED here — device gate). dist
rebuilt + verified. Save + reload (Lua-only). AUDIO CLARITY (the other half of
the report — "don't know what it does to the audio"): v1 retriggers ONE slice
(seq_slice) of the take as a MONO note in the Euclidean rhythm, OVER the drone —
so to hear it distinctly, drop the drone (STRETCH mode OFF / mix) or shorten
voice_rel (PADS E3); per-step pitch/slice (melodic sequencing) is the follow-up.

Thirty-fourth change — **S19 scenes + scene morphing + safe snapshot (Lua-only,
fingerprint STAYS 58/59, renders verified, 177-assertion functional harness
passing, untested on device)**: the "remember this / go back to that" layer, in
NEW module **lib/mscenes.lua** (9th lib; amalgamate assert 8→9). Full design +
gate: doc/spec.md §S19. Data model: `M.slots[1..8]` = flat `{id=value}` maps
captured from the live params (+ `M.safe`, one more). NO audio — control state
only, so 8 slots ≈ 350 numbers. `ctx.scene` = the module, `ctx.scenes` = the
slots table (mutated in place, NEVER reassigned — the ref would go stale);
`ctx.scene_capture/_recall/_clear/_morph` + `ctx.safe_snapshot_capture/_restore`
sit beside `fx_dry`. THREE CURATED LISTS (the design; heavily commented in the
module): SCENE_RECALL_IDS = three ORDERED blocks TIMBRE→SPACE→SWITCH, walked in
order so **`mode` lands LAST** (it respawns the SC voice — switching it last
means the voice is born with the scene's params, not jumped to them); out =
config/keys, SYSTEM levels, `out_level`, `rec`/`tape_rec`, `stop_all`,
motion/seq transports. SCENE_MORPH_IDS = recall MINUS 7, DERIVED at load (a
filter, not a second literal — can't drift): a morph **never flips a hold
(freeze/pv_freeze/tape_freeze), never re-routes notes (pad_input/tape_reverse),
never writes the buffer (resample/regen)** — so morph(1) ≠ recall(B) BY DESIGN.
SAFE_SNAPSHOT_IDS = recall + `out_level`. **NEVER put a scene_* param in any
list** — `scene_morph_amt`'s action re-fires the morph and would fight the
restore. MORPH: interpolates in the controlspec's OWN warped space (unmap→lerp→
map), so cutoff 200→20000 at 0.5 = 2000 (geometric mean), not 10100 — a raw lerp
sounds wrong on every exp param (`opts.linear` forces raw); numbers lerp+round,
options/binaries flip at ≥0.5; the normalized target doubles as the "already
sent" key so a param identical in A and B NEVER fires; ends force-assert.
**Changing A/B never writes** — only the amt knob does (else touching B at amt=0
jumps the instrument to A). CPU: `scene_morph_amt`'s action only marks dirty;
`Mscenes.tick()` in the EXISTING 15fps clock (right after `Mmotion.tick()` — no
new process) applies ≤1 sweep/frame, capping what a fast CC would otherwise
fire (~40 params × 128 steps) at the engine. MOTION SEAM (one function, no
entanglement): every mscenes write goes through a local `pset()` → `params:set`
+ new `Mmotion.account(id)` (re-baselines from the RESOLVED value), because
mmotion captures by POLLING — without it a recall/sweep looks like forty hands
on forty knobs and punches a lane each. `scene_morph_amt` IS in MOTION_IDS
(appended), so recording a sweep = ONE lane that re-derives the other forty.
SAFE/CHAOS: safe_restore also cancels a queued recall (it would undo the rescue
a beat later); `chaos_throw` is a MOMENTARY param (footswitch/grid) — press =
bounded random throw of 14 params in NORMALIZED space (scan thrown to one SIDE,
never the standstill at norm 0.5), release = safe_restore, auto-marks a safe
state if none, and the release is guarded by `chaos_live` so a stray 0
(params:bang, a pset read) can't restore out of nowhere. math.random lives ONLY
here (never in draw) → seeded renders untouched. PARAMS (grp_scene, **11**): 3
selectors + `scene_morph_amt` + `scene_recall_mode` (NOW/BEAT/BAR — non-NOW
queues ONE clock.sync coroutine, always cancelled on replace/restore/cleanup)
+ **six MOMENTARY binaries** (capture/recall/clear/safe_capture/safe_restore/
chaos_throw). Momentary NOT add_trigger: **triggers can't be MIDI-learned** (the
point is a footswitch) and every action fires on the PRESS edge (v==1) only.
UI: **SCENE = page 14**; E2 slot · **E3 = the morph** · K1+E2/K1+E3 = A/B; K2
RCL, K3 CAP, and the page claims BOTH alt slots for the SAFETY pair (K1+K2 UNDO
/ K1+K3 SAFE) instead of global STOP/DRY — that's the page's job. Keys drive the
momentary params + `held_gesture` (the TAPE REV pattern), so key == footswitch.
Grid is page-aware like SEQ (`is_scene_page()`): row 1 slots (CAP/CLR modifiers
on row 8), rows 3/4 = A/B, row 6 = an 8-step morph bar, row 8 = CAP·CLR·CHAOS·
SAFE·UNDO. PSET hooks are SHARED not replaced (mtape audio + mscenes state via
tab.save → `scenes-<n>.lua`); a pset with no scene file leaves the bank alone
(mtape's precedent). SIM FIX: the uisim's controlspec stub had `unmap` but no
`map` — added (norns has both; the morph needs the round trip). VERIFIED: a
throwaway harness loaded the REAL script under the sim's stubs (sliced from
render_pages.lua) and asserted 177 properties — all pass, incl. the BEAT/BAR
clock path driven by hand. Adding page 14 adds ONE header dot to every page:
re-render proved all 62 prior shots differ at EXACTLY (y4-5, x122-123) and
nowhere else (the wider diffs on `extra` shots are pure animation phase — the
walk is 25 ticks longer). Gallery regenerated (+scene.png, 19); suite 67 shots ×
4 variants; dist rebuilt + byte-verified (source==dist, 9 modules). Save + reload.

S19 REVIEW PASS (same change, pre-gate — 6 refinements, harness now **212**
assertions, 68 shots, dist re-verified; every new regression test was checked to
FAIL when its fix is reverted). Two were real bugs:
(1) **A PSET LOAD silently re-derived the morph over the values it had just
restored** (proven by probe: load → cutoff 5000 → one frame later → 5270).
`params:read()` re-sets `scene_morph_amt` → `touch()` → dirty, and `action_read`
runs AFTER the values, so the next tick morphed on top of the pset — discarding
anything hand-tweaked after the last morph move. INVISIBLE without drift, which
is why it would have shipped. FIX: `dirty = false` FIRST in `M.pset_read` (before
the file-exists early return). The pset is authoritative; the morph re-engages on
the next knob move.
(2) **The page-aware grid loses release edges — PRE-EXISTING since S18, live on
`tape_reverse`.** `grid_key` dispatched on the CURRENT page, so changing page
mid-hold handed the release to a layout that ignores it and LATCHED the param:
hold grid (3,2) → E1 to SEQ → let go → **the tape plays backwards forever**; a
held note pad → SEQ/SCENE → **stuck voice**; and S19 would have added a latched
CHAOS with no way back. FIX (generic, fixes all three): `key_surface[k]` records
the surface on the PRESS edge and routes the release back to it — a pad's release
belongs to the surface that took its press. Made the SCENE-modifier page-change
hack dead code (removed).
The other four: `tape_reverse` OUT of every list (momentary — its resting value is
0, so a captured 1 is a transient that recall would latch; `tape_rate` is bipolar,
so "backwards" stores as a negative rate — nothing lost); `voices` INTO
MORPH_EXCLUDE (lerping the poly cap crosses integers and each crossing re-caps the
allocator → STEALS held pad notes mid-sweep; structure, not texture); `EDGE_PAIRS`
in `apply()` — `pos_start`/`pos_end` + `loop_start`/`loop_end` now move the
WIDENING edge FIRST so softcut can never render a region that is neither the old
nor the new one (the `hi-lo<0.1` floor would turn a crossed pair into a 100ms loop
→ head jump); and the **"RCL B TO LAND"** cue (`M.engaged` + `M.unlanded(slot)` +
`MORPH_SKIPPED_IDS`) so `morph(1) ≠ recall(B)` is visible, in the STATUS row —
NOT beside the bar, where the amt=1 handle (x110) would collide with it.
DELIBERATELY NOT CHANGED (predictability over cleverness): the morph stays
fixed-rate 15fps (adaptive would make the feel vary with load; and the engine has
no Lag on these args, so a sweep zippers exactly as much as a hand on E2 does —
if that ever becomes the complaint, `Lag.kr` engine-side is the real lever), and
UNDO still does NOT stop the modulators (a running MOTION lane keeps driving its
param straight after a restore — documented in the §S19 gate, not "fixed" by
silently stopping someone's loop).

Thirty-fifth change — **S20 pad slices follow the take (Lua-only, fingerprint
STAYS 58/59, renders verified, untested on device)**: asked "what is PADS doing
anymore?" — answer: playing SILENCE, mostly. Full detail + gate: doc/spec.md §S20.
THE BUG: `pad_pos(i)` was `(i+0.5)/8` = an eighth of the **60s BUFFER**, but the
normal workflow (REC K2, phrase, K2) snaps the window to the take, so a 4s phrase
is ~7% of the buffer → the 8 pads fired at 3.75s/11.25s/…/56.25s → **pad 1 caught
the take's last 6%, pads 2-8 played silence**. S18 hit EXACTLY this on device and
fixed it **only inside mseq** ("the pads' known whole-buffer-slice limitation" —
the log named the bug and left it), so post-S18 the sequencer played your take
while the pads, same slice number, played empty buffer: TWO meanings of "slice n".
FIX: ONE law in `ctx.pad_pos(i)` = `lo + (i+0.5)/pad_n * span` over the window;
the PADS audition, route_note/pad_trigger AND mseq.fire() all resolve through it,
so pad 3 == seq slice 3 **by construction** (mseq's local copy deleted — the
divergence can't return). A full-buffer window reduces to the old even-eighths
split, so nothing is lost. PAGE: body_PADS drew the whole buffer with 8 even
dividers — honest about the old pads, but it made S12's "a pad is an eighth of
what you recorded" a LIE and drew a short take as an 8px blip with 7 dividers over
silence. The strip is now **the window zoomed to full width** (wave[] is binned
over the buffer → index it through the window), playhead in window space, drawn
only while inside the take. CONSEQUENCE: slices are now RELATIVE to the window —
re-record, nudge WINDOW, or recall a scene (pos_start/pos_end are in
SCENE_RECALL_IDS) and every pad moves with the take. Intended; per-pad absolute
positions stay deferred (S12). NB the zoom is bounded by the display model (a 4s
take = ~8 of the 128 wave bins → blocky, same as the WINDOW loupe). VERIFIED: the
harness (220 assertions) drives the REAL key path (PADS K2 x3 → cursor 3, K1+K2 →
audition) and the REAL Mseq.step(), capturing what each asks the ENGINE for —
pad fires inside the take at its eighth's centre; pad 3 and seq slice 3 fire the
IDENTICAL position + type; slices track a moving window; a full-buffer window
reproduces the classic split. Reverting pad_pos fails 3 of them (pad 3 → 0.4375 =
26s, take ends 4s). Renders: exactly base_11_PADS + _LIVE changed (all 8 pads now
sit on material); pads.png regenerated; dist rebuilt + byte-verified (68 shots).
LESSON: when a device bugfix names a limitation in ANOTHER module ("the pads'
known whole-buffer-slice limitation"), that's not a note — it's an unfixed bug
with a witness.

Thirty-sixth change — **S19 fix: the SCENE page could not prove it worked
(Lua-only, fingerprint STAYS 58/59)**: DEVICE REPORT — "SCENE page is completely
broken, keys do nothing, no sound". **The keys were firing the whole time.**
Checked against the REAL norns source (`lua/core/params/binary.lua`, fetched):
`Binary:set` equality-guards (`if self.value ~= v`), but every SCENE key hands
its release to `held_gesture`, which returns the param to 0 — so each press is a
fresh 0→1 edge and `bang()` runs. The bug was that the page said NOTHING: capture
moved ONE 13px box (I set `captured_at` and never drew it); recall of the slot you
just captured re-applies the sound you are ALREADY making, so it is **inaudible by
definition**; recall of an EMPTY slot was a silent no-op. That combination is
indistinguishable from dead keys. **A performance page that can't prove it worked
is broken, whatever the code does** — the report was right and the diagnosis
("works, user error") would have been wrong.
FIX, one mechanism for two audiences: `say(msg, detail, slot)` in mscenes sets a
~1.2s on-screen chip AND prints the full story to maiden (the codebase already
leans on bring-up prints; now you can always tell whether a key fired by looking).
Every action reports: SAVED n / RECALL n / **RECALL n - SAME** / SLOT n EMPTY /
QUEUED n / CLEARED n / SAFE MARKED / NO SAFE STATE / UNDO / **UNDO - SAME** /
CHAOS. The **`- SAME` variants are the whole point**: `apply()` now returns
(set, MOVED) by comparing each param before/after (`set_moved`), so the page can
say the recall LANDED and nothing moved — which is exactly why no sound changed.
The touched slot flashes with the message (`msg_slot`), so the news has a place as
well as words. The message line outranks the morph cue (a fresh action is the more
urgent news). Empty-bank invitation now TEACHES the workflow instead of stalling
at one scene: 0 filled → "EMPTY - K3 CAP"; **1 filled → "CHANGE SOUND - CAP SLOT
n"** (names the next EMPTY slot — one scene can't prove itself, you need a second
sound to come back from, and this is the step everybody stalls on); 2+ but no
endpoints → "MORPH: K1+E2 = A - K1+E3 = B" (says HOW, not just "pick"). SCREEN
GOTCHA hit here: the first cut of the hint was 136px on a 128px screen and clipped
at BOTH ends — **measure with `text_w` before adding words; 124px is the centered
limit** (`lua -e` + dofile lib/mfont.lua measures it in seconds). Suite: +SCENE_ONE
(the teaching state), +SCENE_SAVED (the chip + flashed slot), +SCENE_SAME (the
recall that explains silence) = 71 shots; only SCENE shots moved (the added
run_ticks shift their message/blink phase); scene.png unchanged; dist rebuilt +
byte-verified; harness still 220. Save + reload.

Thirty-seventh change — **S21: delete a take + load a sample, and MIX stops
lying (ENGINE + Lua, fingerprint 59 → 61, UNTESTED — no sclang here)**: DEVICE
REPORT — "sometimes some different tempo version of the sample sounds then cut,
I think is the tape" + "there is no real way to delete a recording or use some
other sample source". Both real; full detail doc/spec.md §S21.
(a) **THE MYSTERY SOUND WAS THE TAPE, AND MIX WAS HIDING IT.** init_tape sets
`sc.play(v,1)` + `sc.loop(v,1)` ONCE and never clears them, so the softcut deck
is ALWAYS looping — and at the default `mix` 0.5 the plateau law puts it at FULL
level. Anything that ever landed in that buffer (grid (1,2) is `tape_rec`, easy
to hit while exploring; a PSET load also restores tape-N.wav) loops the take back
once every 60s and then falls silent for the rest of the loop = "sometimes ...
sounds then cut". It records the RAW INPUT on its own 60s cycle, not aligned to
the drone's tight window — and at any tape_rate ≠ 1 it is literally a different
tempo. **The MIX page could not show them this**: the TAPE lane drew a STATIC
SYNTHETIC waveform (`TAPE_PREVIEW`, "so the lane always reads as material")
whose height rode the FADER — it claimed the tape had audio whether it did or
not, and ignored stop_all entirely. That breaks this file's own headline rule
(brightness encodes audibility) on the one page whose job is telling you which
deck you hear; the 8th change's MIX truth pass had it right and the Toy redesign
(12th) replaced it with decoration. FIX: both lanes now scale by their deck's
REAL gain (the same law Mtape.update_mix sends: trim x plateau x master x STOP),
the TAPE lane draws the REAL `twave`, and the tape HEAD is drawn whenever the
deck holds audio — bright when audible, dim when thrown away, so a deck you
forgot you armed can never hide again. TAPE_PREVIEW deleted (if a lane can't
tell the truth it shouldn't draw).
(b) **ENGINE +2 commands → 61**: `clear` ("" format — verified against norns
engine.lua: `#fmt`=0 means a genuine no-arg command) zeroes bufL/bufR; `read_file`
("s") loads any wav/aiff. BOTH act on the SAME bufL/bufR the synths already hold
— `Buffer:zero` and the INSTANCE `Buffer:readChannel` (verified in SC's
Buffer.sc: reads into an EXISTING buffer, does not allocate) — so no bufnum ever
changes, nothing respawns, nothing desyncs. Mono files feed both sides from ch 0
via `(nch-1).min(1)`. All core SC, no plugin deps, cannot brick. CAVEAT:
/b_readChannel does NOT sample-rate convert and norns runs at 48k, so a 44.1k
file plays ~9% fast (a varispeed, not a bug).
(c) **Lua**: `ctx.clear_recording` (REC **K1+K3 = CLR**, mirroring TAPE's CLR —
REC gives up the global DRY for it, like TAPE does) + `ctx.load_sample`
(`params:add_file` → norns fileselect; the path rides the PSET so a session
reloads its sample). grp_rec 7 → 9. A loaded sample lands in the SAME buffer a
take does — there is no "loaded sample" mode, window/drone/pads/seq just work on
it — and the window SNAPS to the file's length.
(d) **THE WAVEFORM PROBLEM**: lua cannot read an SC buffer, so a loaded sample
would be INVISIBLE — REC/WINDOW/PADS sitting on "EMPTY - K2 REC" over audible
audio. `Mpages.load_wave(path, secs)` reads the peaks out of the FILE itself: a
RIFF chunk walk (handles LIST/metadata chunks before `data`), 16-bit PCM only
(else nil → the caller leaves the display alone rather than draw a lie), 128 bins
peaked with a STRIDE so the work is bounded whatever the length. TESTED here with
generated wavs: 4s stereo / 2s mono / a LIST-chunk file / a missing file / an
11MB 60s file — exact amplitudes (0.90, 0.50), correct bin counts, zeros past the
sample, 17-30ms scans. **A first cut sampled 8x64 frames per bin and lost a 40ms
drum hit ENTIRELY** — sparse sampling looks fine on continuous material and eats
transients, the exact wrong failure for a sampler; striding the whole bin catches
it (bin 6 = 0.92) and is FASTER on big files.
Renders: only the 5 MIX shots moved (mix.png regenerated); 71 shots; harness 220;
dist byte-verified. **DEPLOY: this is an ENGINE change — rsync, SYSTEM > RESTART,
confirm `count: 61`**, then run the §S21 gate.

Thirty-eighth change — **S19c scenes: one selector, not three (Lua-only,
fingerprint STAYS 61)**: "the scenes are hard to use" — the THIRD report. Twice I
answered it as feedback (§S19b); the third time it was the MODEL. Full detail
doc/spec.md §S19c. THE DIAGNOSIS: capturing a scene ALREADY names the slots you
care about, and the morph made you say it twice more — as `morph A`/`morph B`, on
the ALT LAYER where they're invisible until you hold K1. Six steps before you
heard anything, two hidden, and a bank that did NOTHING until two slots were
filled. THE FIX IS A DELETION: `scene_slot` is the ONE selector with three jobs —
K2 recalls it, K3 captures into it, **E3 morphs TOWARD it from wherever you are**.
The near end (`morph_from`) is snapshotted implicitly on the rising edge out of 0;
sweeping home to 0 lands EXACTLY where you started and drops it, as does
`invalidate` (any recall/capture/restore/throw), so the next sweep departs from
wherever you are by then. scene_morph_a/b DELETED (grp_scene 11 → 9); the freed
alt encoder took `scene_recall_mode` (PARAMS-only before). WHAT IT BUYS: still
does the old A→B (recall A, sweep toward B — FEWER steps), plus the thing the old
model couldn't — **ONE captured scene is immediately musical** (capture, mangle,
slide back, stop anywhere between), which is why the "CAP A 2ND SLOT" teaching
hint is gone: the situation it taught around no longer exists. THE TRADE (stated,
not hidden): the morph is now RELATIVE, so a motion-recorded sweep replays from
wherever the instrument IS at replay time, not from a fixed A. Inherent to "from
here", musically reasonable (a sweep is a move, not a coordinate), and the price
of deleting two selectors. UI: the bar reads `LIVE ——●—— n`; at amt=1 an unlanded
scene says `K2 TO LAND THE REST`. GRID: row 1 taps RECALL (the scene-launcher
gesture), so row 1 CAN'T double as the morph target — you'd already be there and
the sweep would have nowhere to go — hence **row 3 = AIM** (point without
jumping) and row 5 = the 8-step morph bar. Harness 229 (new: aiming doesn't jump ·
amt 1 lands · amt 0 returns home exactly · warped midpoint measured from the live
sound · re-aiming mid-sweep re-targets · ONE scene is musical · the endpoint
params are provably gone). Only SCENE renders moved; scene.png + README manual
entry regenerated; dist byte-verified. Save + reload (Lua-only — but the S21
engine still needs its RESTART for count 61).

Thirty-ninth change — **NU-1: the redesign lands its spine (Lua-only,
fingerprint STAYS 61, renders verified, untested on device)**: first stage of
**doc/redesign.md** (the S-4-inspired redesign; decisions locked with the user
across the proto shot-gallery rounds — belt tape, SPACE name kept, measurement
rails, dynamic motion lanes). PAGES 14 → **9 stations** (TAKE VOICE TAPE
FILTER SPACE MIX PADS MOTION SCENE; merged REC+WINDOW→TAKE, STRETCH+GRAIN→
VOICE, DELAY+REVERB→SPACE, MIX+LEVEL→MIX, PADS+SEQ→PADS). **THE PUNCH LAW**
replaces the act-only KEYS table: press = engage NOW, release <5 frames =
latch, ≥5 = punch (release disengages), press-when-latched = off. Defs:
`{label,act}` tap-cycles (fire on press) or `{label,pon,poff,lit}` punchables
— pk() wraps binary params, throw() wraps store/restore gestures (OPEN / INF
/ BLOOM / ENG / TAPE all round-trip: tap latches, tap again restores the
prior values). **K1+K2 = STOP and K1+K3 = DRY(tap) / ERASE(hold) are GLOBAL,
zero page claims**; the erase fires AT the 15-frame arc threshold from the
redraw clock (tick_keys), release in frames 5–14 = the abort zone; per-page
`erase` entries wipe that page's material (take / tape loop / pattern / lane
/ slot). key_state[] resolves the def at PRESS and routes the release back to
it — the S19 grid lesson applied to the keys. **Banking DELETED**
(REVERB_BANKS/GRAIN_BANKS/cyclers gone; macros + PARAMS menu is the deep
layer). ENC_MAP = 4 macros/page, with "@win_move"/"@loop_move" compound
targets (move_pair: width-preserving, fine_delta-scaled). **VOICE face
encoders are mode-contextual** (VOICE_FACE: GRAIN→size/density,
WARP→win/rand, else speed/pitch; alt = speed/pitch always). **K1+E1 = scene
morph from anywhere** (the family jump retired). held_gesture/gesture_release
retired (SCENE keys pulse their momentary params). CHROME (mpages): header =
title (chip inverts on STOP) + **◇ purity mark** (purity() — lit only when
output==take verbatim; conservative, never lies pure) + write flags R/T/M
(the ONLY fast blink) + ▸ seq-run + FZ/TF + **path dots grouped 3·2·1·3**;
footer = four quiet words `K2 K3 | E2· E3·` — latched = inverted chip, values
only while turning (1.2s swell) EXCEPT selectors (seq_slice/motion_lane/
scene_slot read at rest), shift bar while K1 held, DRY→ERASE word + arc.
seq_slice's action mirrors ctx.pad_cursor (ONE selection, until the NU-3
`slice` merge). Old bodies draw temporarily under the new chrome (TAKE→
body_REC, VOICE→body_STRETCH, SPACE→body_REVERB; LEVEL/WINDOW/GRAIN/DELAY/
SEQ bodies orphaned until NU-2 harvests them). Suite re-pointed at the nine
names (+TAKE_PURE, TAKE_ERASE_ARC, FILTER_OPEN/_SHIFT shots; 58 shots × 4
variants); dist rebuilt + byte-verified. GOTCHA: mgrid's is_seq_page()
matches "SEQ", which no longer exists — the grid's sequencer view is dormant
until NU-4 re-homes it (all other grid behavior untouched). Lua-only: save +
reload. (The S21 engine RESTART + count-61 device gate is still pending,
unchanged by this.)

Fortieth change — **NU-2: the nine dominant objects (Lua-only, fingerprint
STAYS 61, renders verified, untested on device)**: every page body replaced
with its doc/redesign.md §6 object, bound to REAL state; mpages shrank 1640 →
~1440 lines (draw_strip, the reels, the bouncing ball, the GR_* grain pool,
LEVEL faders and all five orphaned bodies deleted). **TAKE** = the material
strip (bright in-window / dim out / dotted unwritten; write head + hot
afterglow + armed frame blink + BIG elapsed seconds + IN meter with the
−12..−3dB ready bracket while rec; window brackets with feet; danger hatch
over the material while the K1+K3 erase arc runs; RSMP/REGN chips). **VOICE**
= mode rail (active word inverted, OFF dims all) over the S2 textures
(unbroken wave / grains / warp ghost / spectral columns) + window bar +
playhead. **TAPE** = the BELT: real twave riding the top run indexed through
the LOOP, turnaround arcs, circulation arrow (flips with direction), comet
trail + head (position within loop from tape_phase), punch-in glow behind
the head while tape_rec, rate INSIDE the loop, loop seconds top-right.
**FILTER** = the real biquad curve kept, + labeled 100/1K/10K dotted rails,
0dB dots, drive grit flecking the curve. **SPACE** = the impulse scape:
onset spike, echo taps at delay_time spacing decaying by fb (height rides
delay_mix), the reverb tail as a filled slope (tau from rev_decay t60 /6.9,
49px/s), 1S/2S time rails + labels, hatched wash margin when the tail
reaches the edge, shimmer motes; dormant baseline + stub when both mixes ~0.
**MIX** = the console: IN meter + peak pip → ENG lane (real wave × the real
gain law) + playhead → crossfade rail/tick (tick stays put in STOP) → TAPE
lane (real twave × real gain) + always-running head → OUT VU + pip.
**PADS** = cause above rhythm below: the window-zoomed take + 8 dividers +
playhead, 8 numbered slice cells (cursor bracket / sounding fill / seq-fire
pulse), the 16-step euclid row (playhead inverts, beyond-len dark) —
SLICE·n reads at rest. **MOTION** = dynamic lanes as STEP CURVES (hold value
between events), full footer-word names, quarter rails, ONE playhead
crossing every lane with a live-value dot per lane, armed frame blink +
grow-right write head. **SCENE** = the ◄ safe cell (filled when a safe state
exists, dotted when not) + 8 slots (dotted empties, pending blink, msg
flash, cursor brackets) + the morph rail (origin dot, traveled segment,
handle; LIVE/target brightness by side) — say() chips + K2-TO-LAND cue kept.
SCENARIO fix in the suite: the TAKE_REC 1-frame re-arm snaps the window to
its blip (the rec-stop law) — the choreography now restores the take window
after, so downstream shots don't show a sliver. GOTCHA hit: mpages had no
`exp` local (body_SPACE) — add math locals when porting. 58 shots × 4
variants; dist rebuilt + byte-verified. Save + reload.

Forty-first change — **NU-3: behavior (Lua-only, fingerprint STAYS 61,
renders verified, untested on device)**: the redesign's trust mechanics.
**PEEK**: SCENE K2 under the punch law — press starts a ~3-frame ramp of
`scene_morph_amt` toward 1 (driven through the PARAM from tick_keys, so the
morph engine, motion capture and MIDI all stay true), release-as-punch ramps
it home (landing exactly, S19c), release-as-tap = COMMIT (pulse scene_recall,
then amt→0 which is a no-op because recall invalidated morph_from — verified
against mscenes' rising-edge law). The key engine grew an optional `def.tap`
hook (tap-release runs it INSTEAD of latching; also fires when pon declined
to engage — how RCL on an empty slot still reports EMPTY). **THE ◄ CELL =
slot 0**: scene_slot is now 0..8; mscenes branches on `is_back` BEFORE
slot_idx clamps (capture→safe_capture · recall→safe_restore · clear→forget ·
morph→refused) — so grid/MIDI recall of ◄ works through the same params.
**AUTO-SAFE**: every commit recall (immediate AND the queued fire) and every
chaos press parks the pre-state in ◄ via the new quiet `M.auto_safe()` — an
undo that never needs arming; manual SAFE (capture into ◄) still exists.
fmt_value: scene_slot 0 reads `<` (footer `SLOT·<`); body_SCENE brackets the
◄ cell and swaps the rail for "K2 = THE WAY BACK" when it's selected.
**SLICE**: single-source confirmed — ctx.pad_cursor's only writer is the
seq_slice action (param id deliberately KEPT as `seq_slice`: ids are never
renamed, the merge is behavioral). **PARAMS menu mirrors the stations**:
group labels renamed (take - record/window · voice - grain/clouds/stretch ·
space - delay/reverb · pads - voices/sequencer; mix/tape/filter/keys/motion/
scenes as-is) — ids untouched, PSETs/PMAPs unaffected. Suite: +SCENE_BACK +
SCENE_PEEK (60 shots × 4 variants); dist byte-verified. GOTCHA for later:
mscenes' old say() texts referenced K1+K2 UNDO / K1+K3 SAFE — the two safety
strings were reworded to the ◄ vocabulary; if any other user-facing string
still names the OLD key map, fix it on sight. Save + reload.

Forty-second change — **NU-4: the grid spine + polish + docs (Lua-only,
fingerprint STAYS 61, renders + dist verified; GRID CODE IS UNTESTED — the
sim stubs the grid, so NU-4's device gate is the real test)**: lib/mgrid.lua
rewritten to the spine (doc/redesign.md §7): **rows 1-2 and 7-8 never change
meaning** — row 1 = the SCENE BANK from any page (tap = recall · **hold =
PEEK**, the same punch law as the key, via per-slot press frames +
ctx.peek_on/peek_back; CAP/CLR modifiers still capture/clear), row 2 = the
STATE STRIP (rec · tape rec · tape rev(hold) · pv frz · tape frz · seq run ·
DRY · STOP — writes blink fast like the header flags, STOP steady), rows 7-8
= ONE piano octave (was two; octave −/+ at the row-7 corners; ids 2000+
unchanged). **Rows 3-6 = the workspace**, following the page: main = window
span (row 3, with rec-head glow) + tape-loop span (row 4) + mode radio x1-5
/ pitch-reset x7 / pitch-quant x8 (row 5); PADS = 16 steps (3-4) + slice
select (5) + run/clear (6); SCENE = AIM (3) + morph bar (5) + CAP·CLR·
CHAOS(hold)·◄ (6). key_surface press-routing kept for the workspace rows
(rows 1-2/7-8 are page-independent, so they don't need it). POLISH:
body_SCENE gained the **refusal shake** (an EMPTY-slot action shakes its
cell ±1px for 4 frames — the no-op that explains itself) and the **queued
wedge** (an emptying pie beside the slot row counting to the sync point,
driven by clock.get_beats guarded with pcall — absent in the sim, so renders
stay deterministic). DOCS: README rewritten to the nine-station instrument
(punch law, ◇, ◄, the spine; gallery images renamed take/voice-*/tape/
filter/space/mix/pads/motion/scene + state shots, doc/ui regenerated at 4x);
mangler.lua's header comment updated to the new grammar; doc/redesign.md
status flipped to IMPLEMENTED-pending-device-gate. 60 shots × 4 variants;
dist rebuilt + byte-verified. DEVICE GATE (the one thing left, needs
hardware): rsync, SYSTEM > RESTART (the S21 engine is STILL ungated —
confirm `count: 61`), then walk all nine pages · tap-vs-hold feel at the
5-frame threshold · K1+K3 DRY tap / erase arc + abort zone · SCENE peek,
commit, ◄ undo, chaos release · MOTION capture from real encoders · the
whole grid spine, especially scene-row peek and held-pad page-changes ·
◇ lights on a fresh take and dies on the first mangle.

Forty-third change — **typing keyboard drives PADS (Lua-only, fingerprint
STAYS 61, renders byte-identical, untested on device)**: the USB typing
keyboard was the ONE note driver still wired only to the mono drone — MIDI
(minput) and grid (mgrid.grid_note_key) both route through `ctx.route_note`
on BOTH edges into the polyphonic voices when `pad_input=1`, but the keyboard
did a bare `params:set("pitch", …)` on key-down only. Now it routes through
`route_note` like the other two: A-row/W-row notes play pad `(semi mod 8)` as
held polyphonic voices in pad mode, or retune the drone otherwise (byte-
preserved — route_note's drone branch ignores the release). Voice ids **3000+
st** keep it clear of MIDI (1000+), grid (2000+), seq (2500), screen bank
(0..8). TWO TRAPS, both guarded + mutation-tested (each fix proven to FAIL a
regression when reverted):
(1) **THE OCTAVE TRAP** — the id MUST key on the physical KEY code
(`3000 + st`, octave-independent), NOT the sounding semitone. A prior sketch
used `3000 + semi`; then holding a key, tapping X (octave up) mid-hold, and
releasing computes a DIFFERENT id at release → note_off misses → the voice
sounds forever. This is exactly why the grid keys its voice on the pad
coordinate, not the note (S8/S19 lesson). `kb_held[code]=st` records the
semitone AT PRESS so the release fires the same id.
(2) **THE STRAND TRAP** — the old handler gated everything behind
`norns.menu.status()` + `keys_enable`; harmless when it only set `pitch`, but
once it opens voices, opening the norns menu (or keys_enable going off)
mid-hold would SWALLOW the release → stuck voice. Releases are now honored
UNCONDITIONALLY, and ONLY for keys we actually opened (the `kb_held` guard —
a release can't fire for a note that never started). SPACE (stop_all) and Z/X
(octave) stay strictly key-down. No `pitch` footer-flash in pad mode (`pitch`
doesn't move there — the lit pad cell is the feedback; drone mode still
flashes). `M.cleanup` clears `kb_held` (the voices themselves are released by
the existing `ctx.pads_all_off()` in script `cleanup()` and the `pad_input`→0
action — this table is display/id bookkeeping only). INHERITED, stated not
hidden: 18 keys wrap onto 8 pads (`mod 8`), same as MIDI/grid; per-key
absolute pad mapping is not a goal. VERIFIED: a 23-assertion harness drives
the REAL lib/minput.lua against a faithful slice of the pad path
(route_note/pad_trigger) and asserts what reaches the ENGINE — polyphony,
autorepeat-not-retriggering, both traps, drone path unchanged; and two
mutants (`3000+semi`; release re-gated behind the menu) each fail exactly
their 2 guard assertions. All 44 base render shots byte-identical to HEAD
(input-only, no draw code); dist rebuilt + byte-verified (source==dist, 9
modules). DEVICE GATE: plug a USB keyboard, `pad_input=1`, confirm keys play
polyphonic slices + release cleanly, and specifically hold a key → tap X →
release → NO stuck voice. Save + reload (Lua-only — the S21 engine RESTART
for count 61 is still separately pending).

Forty-fourth change — **S22 Phase A: the LIVE take rides the PSET (ENGINE +2 →
fingerprint 61 → 63, Lua PSET wiring, UNTESTED on device — no sclang here)**:
answered *"is there a way to save/load the live take?"* — before this, a PSET
restored everything EXCEPT the engine's record buffer (`bufL`/`bufR`, what REC
captures), so a recorded phrase died on reload; only the tape deck's audio, the
scenes, the params, and a loaded sample's PATH survived. Full design +
staging: doc/spec.md §S22 (Phase B = a browsable stereo export, still PLANNED).
ENGINE, **+2 commands** — the direct inverse of S21's `read_file`/`clear`:
`write_take` ("s", a path STEM) → `bufL.write(stem++"_L.wav","wav","int16")` +
`bufR.write(…_R.wav…)`; `read_take` ("s", same stem) → `readChannel` each mono
file back into the SAME `bufL`/`bufR` (existing-buffer read, no bufnum change,
nothing respawns). `Buffer:write` is an async `/b_write` (a direct buffer dump,
NOT realtime playback), bounded, all core UGens — cannot brick. **16-bit PCM wav
specifically** so `Mpages.load_wave` can repaint the restored take. WHY A PAIR,
not one stereo file: `bufL`/`bufR` are two MONO buffers and scsynth has no cheap
non-realtime interleave — so the snapshot sidesteps it entirely (that's Phase
B's problem, kept decoupled so the simple half ships alone). LUA: three helpers
beside the S21 `clear_recording`/`load_sample` (`ctx.take_pset_write/read/
delete`), folded into the SHARED `action_write/read/delete` hook alongside
mtape + mscenes (never replaced). **Write is GATED on `ctx.wave_any`** (the
existing has-a-take signal that also draws "EMPTY - K2 REC") so an empty pset
never leaves a multi-MB silence file and a fresh pset never resurrects one;
**read is gated on `file_exists(stem_L)`** (a pre-S22 pset → leave the buffer
alone, like mtape with no wav) and repaints via `Mpages.load_wave` — WITHOUT
snapping the window (params:read already restored the saved pos_start/pos_end;
this is a session snapshot, not a fresh file like load_sample). Both guard
`if engine.write_take`/`read_take` → clean no-op against an old engine. VERIFIED:
a 12-assertion harness drives the REAL `params.action_*` closures under the sim
stubs with a real generated 16-bit wav (wave_any set through the REAL
load_sample path) — asserts the write-gate (empty→nothing, take→write_take with
the right stem), old-engine no-op, the CLR round-trip, read-absent leaves the
buffer alone, read-present fires read_take + repaint, delete removes BOTH halves.
Two mutants (drop the wave_any gate; delete only `_L`) each fail exactly their
guard assertions. Renders byte-identical to HEAD (no params/draw touched); dist
rebuilt + byte-verified (source==dist). **DEPLOY: ENGINE change — rsync, SYSTEM >
RESTART, confirm `count: 63`** (this SUBSUMES the pending S21 restart — 63 covers
S21's 61 too). §S22 Phase A gate: record a take → PSET SAVE → CLR (buffer empty,
page says EMPTY) → PSET LOAD → the take is back, audible, drawn; confirm
`take-N_L/_R.wav` exist non-truncated (async `/b_write` — a save-then-quit is the
risk); an empty take writes NO file; a pre-S22 pset doesn't resurrect a buffer.

Forty-fifth change — **UI refinements from play-testing (Lua-only, DEVICE-
CONFIRMED running 2026-07-16; committed as d87738a)**: six fixes on the NU
redesign, all lib/mpages.lua + lib/mgrid.lua. (a) **TAPE reels restored** — the
NU-2 "belt" (a moving line + return run) reverted to the physical **spinning
reels** from 94db129 (two reels, hub + 3 spokes, `reel_angle` accumulator driven
by `tape_rate × tape_reverse` — reverse spins backward, stopped stands still),
keeping the loop track + head + loop-seconds. (b) **Selected PADS slice cell →
square**: the cursor cell was the same 12×10 rectangle as the rest (just
brighter); now a 14×14 square standing 1px proud on every side. (c) **Uniform
page dots restored** — NU-1's grouped 3·2·1·3 dots reverted to the pre-redesign
uniform ones (first x=81, pitch `min(5, floor(45/(#PAGES-1)))`, current page a
rounded 4×4 block with corners punched to 0). (d) **Full-word footer labels** — a
new `FULL` table; the footer shows the WHOLE word at rest (START/END/CUTOFF/
REVERB/MONITOR…) and drops to the SHORT abbreviation + value only while
`is_turning`; a `keys_right` collision guard falls back to SHORT if a full word
would cross the key words. (e) **MOTION scroll** — VIS 3→4 with a scroll window
following `motion_lane` + a right-edge scrollbar, so all recorded lanes are
reachable (was a dead "+N" hint). (f) **Grid sequencer brightness** — SEQ step
levels pushed apart (rest 3, on 9, playhead 15) at values unique on the grid.
Only pads.png changed in the gallery; dist byte-verified.

Forty-sixth change — **Launchpad Mini MK3 native colour driver + semantic colour
language (Lua-only, lib/mgrid.lua + lib/minput.lua, DEVICE-CONFIRMED running;
driver committed 6ec63f1, colour language in the working tree)**: midigrid
emulates a MONOCHROME grid (brightness → one hue), so a launchpad showed every
state as shades of yellow. This drives a **Mini MK3 DIRECTLY in Programmer mode
with real RGB**, bypassing midigrid, while pad presses still flow through
`grid_key`. Architecture: a `gg`-shaped shim (led/all/refresh/key) so ALL
existing grid draw code works unchanged; **device-level** MIDI binding
(`midi.devices[id].event`, like midigrid — separate from minput's vport-level, so
`is_grid_vport` (extended to `have_launchpad`) filters pad-notes out of chromatic
input); detection prefers the MIDI/surface port over DAW; **RGB LED SysEx**
(`F0 00 20 29 02 0D 03` + `03 note R G B`, verified against Novation's
Programmer's Reference); enters Programmer mode on connect, returns to Live on
cleanup; every device call `pcall`-guarded → falls back to midigrid/native, can't
brick. **Colour language** (chosen with the user): `gg:led(x,y,z,hue)` takes an
optional semantic hue name — red=recording (**STOP pulses red**), green=playing,
blue=available/empty, white=playhead/selection, yellow=mode/queued, orange=slice,
cyan=frozen, purple=destructive(clear/chaos)/reverse, teal=active region;
brightness scales the hue (so blinks/pulses read) and the monome/midigrid path
ignores the 4th arg. Verified with a 27-assertion offscreen harness (detection,
Programmer mode, note↔xy orientation, RGB framing, brightness scaling, the real
draw code on all 3 workspaces, input parse, Live restore). LP facts: note =
10·row+col (bottom-left 11, top-right 88); two USB ports — use the **MIDI/2nd**,
not DAW. Tunable palette: `LP_HUE` in lib/mgrid.lua. GOTCHA: the sim stubs the
grid, so ALL grid code (this driver, the colour language, and the review batch's
grid fixes) is device-only — the offscreen harness is the only pre-device check.

Forty-seventh change — **xhigh code-review batch: 14 Lua fixes + #14 ENGINE
bounded write_take (DEVICE-CONFIRMED running 2026-07-16)**: a workflow-backed
review (Torso-S4 · Elektron audio-engineer lens) surfaced 15 verified defects;
all addressed. **Destructive safety** (the cardinal rule): (#1) releasing K1
ABORTS a pending K1+K3 erase — can't misfire after an abort or retarget another
station (you can't navigate while K1 is held; K1+E1 is the morph); (#2) scene
CAP/CLR modifiers clear on page-change AND only fire on the SCENE page — no silent
bank-tap overwrites; (#3) an empty-buffer PSET save DELETES the stale take-N pair
so a cleared session can't resurrect old audio. **Regressions:** (#4) the slice
voice is back as a real MIDI-mappable **`pad_voice`** option (GRAIN/SLICE) feeding
every `note_on` — the NU redesign deleted the only writer of the per-pad type
table, so `mangler_voice_slice` was unreachable and every slice played granular;
surfaced on PADS grid row 6 + screen header + PARAMS (grp_voice 4→5); (#5)
`load_wave` now parses **16/24/32-bit int + 32-bit float** WAV (+ extensible-as-
int), so a 24-bit drop-in draws + windows correctly, and `load_sample` sets
`wave_any` unconditionally so audible audio never shows EMPTY. **Scene/morph
fidelity:** (#6) `mode` out of the morph set (no voice-respawn click mid-sweep);
(#7) `M.safe` cleared on pset load (no cross-session ◄ bleed); (#9) a queued
BEAT/BAR recall cancelled BEFORE the pset early-return; (#10) `tape_reverse` back
in scenes (recall-only, morph-excluded) — the punch law LATCHES it now, so the old
"stored as a negative rate" comment was wrong (direction lives only in
`tape_reverse`); (#11) per-pad grid scene-peek ownership (a two-finger peek can't
recall the wrong slot). **Control surface:** (#8) `enc_param` explicit alt no-op —
`alt and m[2] or m[1]` fell through to the base param when the alt slot was nil
(MOTION/SCENE), so K1+E2/E3 could wipe the wrong MOTION lane; (#12) MIX ENG/TAPE
are MUTUALLY-EXCLUSIVE throws of `mix` (engaging one restores + un-latches the
other first, so the crossfader restores true center and both pills can't light).
**Robustness:** (#13) `load_wave` clamps to the 60s buffer (>60s no longer drawn
stretched); (#15) the whole-file read is bounded by that clamp (async load is the
noted follow-up, not degrading transients). **#14 — ENGINE bounded write_take:**
was dumping the full 60s buffer (~11.5MB) on every save; now writes only the take.
`write_take` format `"s"`→`"si"` (numFrames arg; `n≤0` = full — an **ARITY change,
NOT a new command, so fingerprint STAYS 63**). Lua tracks `ctx.take_len` (0..1
high-water mark: rec-stop window end / loaded length / forced 1 when `regen` fills
the buffer / 0 on clear) and passes `ceil(take_len·bufFrames)+50ms` margin —
**never bounds below the current take** (fails safe toward extra silence, never
audio loss). Verified: S22 harness now 16 (incl. a 0.2s take saving 12000 frames
not 2.88M + the empty-delete), LP 27, a new wave-format harness 11; dist byte-
verified. **DEPLOY: the write_take change is ENGINE — rides SYSTEM > RESTART,
count STILL 63** (arity, not a new command). Everything else Lua-only. #14 device-
check: short take → small wav pair; CLR+save → deleted; `regen` up → full write.

Forty-eighth change — **BATCH: Pi-4 perf + DFM1 filter + parked follow-ups +
code-review fixes (ENGINE + Lua, fingerprint STAYS 63, UNTESTED — no sclang/device
here, pending the next gate)**. A large multi-part session; every part guarded, all
count-63.
PARKED FOLLOW-UPS now BUILT (were listed parked in the 47th marker):
* **Per-pad sound-locks** — `pad_voice` (GRAIN/SLICE) + `pad_pitch` (semitones) per
  slice, real MIDI-mappable params, PSET-persisted (`padlock-N.lua`); `pad_level`/
  `seq_level` set note amplitude. This makes `mangler_voice_slice` reachable again —
  the NU redesign had orphaned the per-pad type table, so every slice played grain.
  Surfaced on PADS grid row 6 + header + PARAMS (grp_voice grew).
* **Async `load_wave`** (#15) — the per-bin peak read is deferred to
  `Mpages.load_tick` (BINS_PER_TICK/frame on the redraw clock); load_wave returns dur
  immediately so the window snaps at once and the waveform draws IN over ~0.9s (no
  load hitch). GOTCHA fixed in review: it clears `wave[]` FIRST so an unsupported-
  format early return leaves a flat strip, not the previous take's waveform.
* **S22 Phase B** — `ctx.export_take` dumps the take via `write_take` to a temp L/R
  pair, waits in a clock coroutine for the async `/b_write`, then `Mpages.
  interleave_wav` zips them into one browsable stereo wav in the audio dir (Lua-only,
  no engine interleave). Review-hardened: waits for the files to REACH their expected
  size (not just plateau), the interleave YIELDS between chunks (no UI freeze), and
  backpatches the header on a short read.
* **Progressive FX curves** — delay_mix/rev_mix pass `v*v` (`square`) so the engine's
  equal-power `.sqrt` law nets a LINEAR knob (3% is subtle, not a cliff).
* **Record-safety Limiter** (0.99, 0.002) on the io record path (transparent < 0.99,
  stops a hot take hard-clipping) + per-note `amp` on note_on/note_one_shot (ARITY
  change, count unmoved).
PI-4 PERF PASS (realtime-optimizer analysis, biggest always-on load was the io synth):
* **#8** — hoisted the last per-frame draw closures (`wflag`, `flabel_r`'s labfor/
  total) to module scope; the redraw path now allocates ZERO closures/frame. Byte-
  identical renders.
* **#1** — reverb+shimmer moved OUT of the always-on io synth into a spawn/free
  `\mangler_reverb` synth (`updateReverb`, spawned only while rev_mix > 0, freed at 0)
  so JPverb+PitchShift stop costing CPU in the default state. io SENDS the post-delay
  wet via `Out.ar(rev_send)` and READS the tail via **`InFeedback.ar(rev_ret, 2)`** —
  a backward edge across the node boundary, so plain `In.ar` would read 0. NOT a
  feedback loop (rv is mixed into io OUTPUT, never back into the send); at rev_mix=0
  the return reads 0 → bit-identical to the old rev_mix=0 path. The delay's LocalIn
  un-merges S15's shared `LocalIn.ar(4)` back to `LocalIn.ar(2)` (shimmer's loop now
  lives in the reverb synth). `revParams` route like `playParams`; (ioKeys ∪ revParams)
  = the old ioKeys → count unchanged. ACCEPTED TRADE: freeing at rev_mix=0 discards the
  JPverb tail, so automating rev_mix THROUGH 0 hard-cuts it (inaudible at 0 anyway;
  keeping it alive would undo the CPU win).
DFM1 DIODE-LADDER FILTER (the "better-sounding sc lib" for the filter):
* The 3× always-on RLPF+RHPF+BPF (6 filter instances, one mixed) → ONE guarded
  **DFM1** (sc3-plugins): `type = (filt_type>0.5)*(filt_type<1.5)` → LP for LP+BP
  modes, HP for HP. **BP** = `HPF(resonant DFM1 low-pass, cutoff*0.5)` — DFM1 has no
  bandpass mode, so a resonant LP peak high-passed below the peak = a band with diode
  character (the `0.5` band-width is the device tunable). GUARDED (`.asClass` + `try`)
  → stock RLPF/RHPF/BPF fallback if DFM1 absent/mismatched, never bricks. `res` clip
  **0.9** (below DFM1's self-oscillation onset; raise toward 0.95 to let it self-osc).
  A short-lived SVF-vs-DFM1 runtime toggle (`filt_model`) was built then removed once
  DFM1 was chosen (count went 63→64→63). FILTER page curve redrawn to approximate the
  DFM1 build (BP = resonant LP peak high-passed below cutoff/2), not the old biquad.
PRISTINE (user chose max fidelity): the perf pass's cheaper-but-lossy swaps were
REVERTED — cubic interp (4), tanh drive, transparent record Limiter, STEREO shimmer
all KEPT. Only #1 (transparent) + #8 (screen-only) + DFM1 stayed. #1's reclaimed CPU
is what funds the pristine choices without xruns.
COMMENT CLEANUP: engine header 87→17 lines (kept the one-engine-file rule, the in_b
array gotcha, SC-tab/RESTART); PERF labels + verbose blocks condensed; the Lua files
trimmed of historical stage-tags — every device-lesson note kept, proven byte-
identical renders.
CODE-REVIEW FIX BATCH (xhigh workflow; stopped mid-run but all 21 findings verdicted
from the journal): fixed — DFM1 res floor (0.9); K1+K3 erase-abort no longer leaks a
DRY throw (releasing K1 marks `k13_fired` so the held K3's release can't fire
`fx_dry`); FILTER page BP curve; export robustness (above); load_wave strip clear;
grid seq brightness back to 15/9/3 (monochrome readability, hues intact on the LP);
dead `rev_bank`/`grain_bank` removed. ACCEPTED (not bugs): the reverb through-0 hard-
cut (above); `seq_div` PARAMS-only (all PADS encoder slots claimed). REFUTED (designs
held): InFeedback "NaN forever" (reads stale ≤1 block then zeros), record-limiter
"comb smear" (constant offset), rev_mix "square²" (nets linear).
VERIFIED here: luac clean, engine paren-balanced, renders byte-identical to HEAD,
source==dist, harnesses pass (s22 16, export 12, wave-fmt 11, padlock, LP 27).
DEPLOY: ENGINE change (DFM1 filter, reverb spawn/free, res clip, record Limiter, note
amp) → rsync, SYSTEM > RESTART, **confirm count STILL 63** (no new command). Then gate:
DFM1 LP/HP/BP character; reverb %CPU drops at rev_mix=0; DFM1 res at max is resonant
but stable; no LOADING hang / SC-tab error.

Forty-ninth change — **S23 Batch A: play-test fixes (Lua-only, fingerprint STAYS 63,
renders verified, untested on device)** — from a transcribed voice memo (doc/ux-feedback.md
§19–30; full staging doc/spec.md §S23). User directive: **NO new features** ("make this
thing we have good, it's hard enough") — every item is a fix/rework/removal. Three forks were
resolved WITH the user: remove the sequencer · STOP truly halts (Batch B, engine) · motion
loop-length now. Save + reload (NO restart — the 48th batch's engine RESTART for count 63 is
still separately pending).
* **A1 — SPACE split → DELAY + REVERB.** PAGES 9→**10** (re-spaces every page's header dots,
  so the whole gallery + suite regenerate). body_SPACE split into body_DELAY (echo taps) +
  body_REVERB (tail); shared spc_frame/spc_onset helpers. grp labels de-"space -".
* **A2 — delay feedback range.** `delay_fb` 0..0.95-linear → a 0..1 knob curved through
  `fb_curve(v)=0.98·v^0.6` (shared via ctx.delay_fb_curve so the page taps stay honest): a
  smooth few→many(10+)→near-infinite sweep, no top-end cliff. INF throw sets the knob to 1.
* **A3 — deeper DELAY/REVERB.** The split doubled each effect's encoder complement (DELAY =
  mix/time/fb, REVERB = mix/size/decay/damp — fb/size/damp NEWLY on-encoder; the other 11
  JPverb params stay in PARAMS + WASH/BLOOM). Made rev_size/rev_damp READ on the page (the
  reflection dots space by size, darken by damp). No new params — the user's own "separate
  pages = more keys" resolution.
* **A4 — tape captures FX output.** `cut_source` (grp_tape 8→9, 0=DRY..1=WET, TAPE K1+E3
  replacing @loop_move). `Mtape.set_source` drives level_adc_cut(1-v)+level_eng_cut(v) (they
  SUM at softcut in) so the tape prints dry input / processed output / a blend — the §25
  resample stage. init_tape reads the param (was hardcoded adc1/eng0); cleanup zeroes eng_cut
  (no leak). No runaway (engine reads only the ADC bus). "SRC WET" body flag = never a hidden
  mode. Routing-math harness (DRY/WET/blend/cleanup) + TAPE_WET shot.
* **A5 — motion loop length.** `motion_len` (grp_motion 4→5, seconds, 0=AUTO, MOTION K1+E2).
  Splits timing into rec_len (natural = event timebase) + loop_len (playback length); playback
  reads events through `src_of(ph)=ph·rec_len/loop_len` — IDENTITY when not retimed (AUTO is
  bit-for-bit pre-A5, MOTION renders byte-identical). >0 retimes SPEED losslessly; overdub +
  the page step-curve also key off rec_len. Floored 0.5s; pre-set honored at finalize.
  17-assertion harness (AUTO round-trip lossless, retime up/down, floor).
* **A7 — killed the blinking TAKE window** (§29): removed the armed full-width blink box; the
  sweeping write head + big seconds + IN meter + header R still say REC.
* **A8 — read vs write head** (§30): the READ head is now drawn LAST (never hidden) and a
  distinct SHAPE — dashed column + caret ▽ above the strip — vs the WRITE head's solid line +
  comet-tail. Distinguishable even when they cross.
* **A6 — sequencer REMOVED** (§28). Deleted lib/mseq.lua (amalgamate 9→8); dropped seq_play/
  seq_div/seq_euclid/seq_len/seq_level (grp_seq gone) + all wiring (include/ctx.seq/init/
  cleanup/body step-row/header ▸/grid step rows). KEPT the slice selector: **`seq_slice` id
  UNCHANGED** (ids are never renamed — PMAP/PSET survive; display name→"slice", moved into
  grp_voice 7→8; still the sole writer of ctx.pad_cursor). PADS is now a pure slice surface:
  ENC_MAP = seq_slice/pad_voice/pad_pitch/voice_rel (freed slots → per-slice sound-lock
  encoders); K3 RUN→ROUTE (pad_input); no page erase (K1+K3 stays global DRY). Grid PADS:
  row 3 = 8 slice play-pads (finger-drum, ids 2600+), row 5 select, row 6 voice/route;
  state-strip x6 seq-run→pad_input. mscenes: 3 seq params dropped; seq_slice EXCLUDED from
  scenes (a UI cursor, like scene_slot/motion_lane).
* **docs:** whole doc/ui gallery regenerated at 4x (delay/reverb replace space*; take/pads/
  every-page dots); README → ten stations, DELAY+REVERB, PADS play-surface, de-sequenced;
  redesign.md flagged "superseded in part by S23".
VERIFIED: luac clean, source==dist (47 shots), A5 + A4 harnesses pass, SCENE capture/recall/
morph still exercised byte-clean, no mseq refs remain. **BATCH B (deferred, engine-gated):**
B1 true STOP (gate the play-voice + tape transport + record head, intended arity-only → still
63), B2 erase reliability + clear kills FX tails/regen. Needs a device session: rsync, SYSTEM
> RESTART, confirm count 63, then walk the §S23 gate.

Fiftieth change — **review batch: 11 Lua + 8 engine fixes (fingerprint STAYS 63,
renders byte-identical, dist verified; engine half UNTESTED — rides the pending
RESTART gate)**: a workflow-backed line-by-line review (4 of 9 finders completed
before an early stop; findings judged + verified by hand against every core file).
LUA (save + reload): MIDI note-OFFS now bypass the keys_enable/channel gates
(presses still gated) — toggling note input or channel mid-hold stranded a pad
voice, the same trap the 43rd change fixed for typing keys; **SLICE pads fire from
the slice START** (the attack — centre-anchor skipped the transient; GRAIN keeps
the centre; `pad_pos(i, at_start)`); mscenes morph — a sweep re-aimed at ◄/an
empty slot can now come HOME (restores last_sent ids from morph_from; it was
stranded), **the OT no-stomp rule** (a param IDENTICAL in A and B is never fired,
even at the forced ends — a hand riding it stays live; displaced ids still land
exactly), pset_read invalidates even on the no-scene-file early return; SCENE K2
tap-commit under BEAT/BAR no longer zeroes the amt while the recall is only
QUEUED (screen + grid — it bounced scene→LIVE→scene), peek punch-release only
ramps home if the peek actually engaged; tape pset_write gates on twave_any +
deletes stale (mirrors the take), cleanup restores level_adc_cut(1); take
pset_read requires BOTH _L and _R (async /b_write can orphan one); tape meter
blends amp_in/amp_out by cut_source (a WET print painted nothing). ENGINE (all
core-UGen, no arity/command change): regen gated on `level > 0.001` (STOP with
regen>0 crossfaded SILENCE over the take); rec_phase Phasor driven by runW (regen
walked the real head while the poll stayed parked → stale window snaps);
voice-steal is a `while` (lowering `voices` below the held count never re-capped);
voiceArgs passes `\pan`; \mangler_pv BufRd interp 2→4; JPverb gets the STEREO
send (`revIn * 0.5`, was mono .sum); drive XFade2→**LinXFade2** (equal-power
summed correlated arms to a +3dB mid-knob hump; ends still exact bypass);
\mangler_play gets a ~5ms **loop-seam edge fade** (the default mode clicked every
pass — takes never end on a zero crossing). DOCUMENTED, NOT BUILT (candidates for
a device session, from the review): resample-blend comb (limiter lookahead delay
vs undelayed dry — needs on-device delay measurement), grain overlap comp
attenuation above unity (loudness rebalance — ear call), 44.1k SRC on read_file
(temp-buffer varispeed copy), write_take int16→int24 (touches the whole export
chain), one-gesture FULL-mix resample via the system TAPE, OT-style partial-scene
capture (capture only SPACE_IDS → an FX-only scene — the data model already
supports it), tape-wav repaint after pset restore (twave stays blank over audible
audio), PV's dead `pitch` face knob. README: added "First session, five minutes"
+ a Troubleshooting section. Gate: reload + RESTART, count 63, then ear-check the
8 engine fixes (seam fade, drive law, stereo verb, PV interp, regen pause under
STOP, voice re-cap, voice pan, regen-head window snap).

Fifty-first change — **texture pass (ENGINE-only, fingerprint STAYS 63, all core
UGens, UNTESTED — rides the same pending RESTART)**: the safe subset of the
"sound even better" list. (a) **grain equal-loudness** — overlap comp clip
`(0.25, 1)` → `(0.25, 16)`: above unity overlap it now ATTENUATES (to −12dB)
instead of riding the master limiter into pumping; the ≤2× low-overlap boost (S5)
is unchanged. NB this retunes dense-cloud loudness — ear-check on the gate. (b)
**lagged performance controls** — `pos_start`/`pos_end` (as lo/hi) + `scan` get
`Lag.kr(…, 0.02)` in ALL FIVE play defs (grain/warp/pv/play/clouds): window-edge
rides no longer click the read head. (c) **sample-accurate grains** — Dust.kr →
**Dust.ar** and EVERY per-grain TRand.kr → **TRand.ar** in \mangler_grain and
\mangler_voice_grain (kr quantized onsets to the control block; and a kr TRand
would MISS ar impulses — the two must move together, never swap one without the
other). (d) **punch-in declick** — `recLvl`/`preLvl` wrapped in Lag.kr(0.01):
arming fades in, mid-take level moves stop printing steps; run stays binary so
punch position is sample-exact (punch-OUT still just pauses the head). (e)
**LeakDC on the take's dry arm** (`recL/recR` input side) — DC from a line input
no longer prints into the buffer. NO Lua touched → renders trivially identical;
paren-balanced; TRand.kr/Dust.kr count now 0. STILL DEFERRED (device/measurement):
44.1k SRC, resample-comb DelayN, int24 takes, dual-head seam crossfade,
window-synced regen, full-mix resample, partial scenes. Gate: RESTART, count 63,
then ear the density sweep (equal-loudness), a TAKE E2 ride mid-play (no clicks),
a dense cloud A/B for smoothness, and a rec punch-in on hot material.

Fifty-second change — **codebase cleanup pass (4-agent /simplify sweep; Lua +
ENGINE source-refactor, fingerprint STAYS 63, ALL 61 renders byte-identical,
dist verified — 7 modules now)**: quality only, no behavior change.
* **lib/mparticles.lua DELETED** — the particle system was fully dead (M.draw
  bound but never called since the NU-2 rewrite) yet `Mparticles.update()`
  still burned ~9 param reads + a 32-slot scan EVERY frame. Include/init/tick
  call/bindings removed; amalgamate assert 8→7. Render-proven inert (0 shots
  changed — the sim never drove it either).
* **mscenes dead state removed** — morph_at/safe_at/restored_at/captured_at
  (write-only since the 36th change's say() superseded them) + the 4 unused
  ctx bindings (scene_recall/scene_morph/safe_snapshot_*); ctx keeps only
  scene_capture/scene_clear (the grid's CAP/CLR).
* **LIST DRIFT FIXED** — `cut_source` (S23) and `pad_level` (48th) had missed
  BOTH curated lists: now in SCENE_RECALL_IDS (TIMBRE, morph-safe) and
  MOTION_IDS (appended). The three-hand-lists-over-one-registry pattern
  remains the structural risk (a tagged param registry is the deeper fix —
  deferred).
* **Reuse**: `filter_open_cutoff(ft)` shared by FILTER OPEN + fx_dry (the
  comment claimed parity, now the code enforces it); `ctx.pulse` exported and
  used by mgrid's 3 hand-rolled momentary pairs; mtape got the `path_for`
  helper its three pset siblings already had; dead SHORT/FULL/fmt_value
  entries (clock_tempo/output_level/headphone_gain, SEQ leftovers) removed.
* **ENGINE `winRead`** — the five play defs' identical 7-line window preamble
  (which had already drifted once: play's pitch term) is now ONE build-time
  function `winRead.(pos_start, pos_end, scan, buf, phase_out, pitchMul)`
  emitting the same UGens inline; graphs unchanged, `#winPos, phase, span =`
  destructure per def. SOURCE refactor only — but it IS engine text: rides
  the pending RESTART, confirm count 63 + all modes still play.
* SKIPPED (noted, deliberate): delay→spawn/free synth like the reverb (real
  CPU win, needs a device session); purity()/FILT_Y per-frame micro-costs
  (within the measured 0.076ms budget); footer tostring churn (Lua 5.3
  interns short strings); LP refresh header table (device-only code, micro);
  FILTER-curve Lua/SC duplication (cross-language, needs codegen); pset
  choreography + press-token unification (working, recently hardened);
  param_norm/value_norm + draw-law/VU/dotted-box helper merges in mpages
  (cosmetic maintenance, cut for another pass); `note_one_shot` is dead but
  removing it moves the fingerprint — leave until a deliberate engine gate.

Fifty-third change — **footer pocket while turning (Lua-only, lib/mpages.lua,
renders byte-identical — no suite shot captures mid-swell)**: user report — a
long value swelling in the footer (e.g. a kHz cutoff) collided with the key
words. `flabel_r`'s full-word→SHORT fallback only guarded the AT-REST case;
with a value up there was NO collision guard. Fix: while a param is TURNING,
its label+value knock out a black pocket (x−3..rx+2, rows 56–63) BEFORE
drawing — anything underneath (key words, chips) vanishes for the ~1.2s swell
and returns after (the old top-right readout's pocket rule, applied to the
footer). Selector values at rest (SLICE·n etc.) are unchanged — they were
laid out to fit and must not permanently hide the key words. Save + reload.

Fifty-fourth change — **reverb mix is now SEND-style (ENGINE one-liner,
fingerprint STAYS 63, UNTESTED — rides the next RESTART; user-decided)**:
device report "with reverb I can't listen to the sound recorded" — the old
equal-power crossfade traded the direct sound away as mix rose (gone entirely
at knob max, by design). Now `wet = wet + (rvRet * rev_mix.sqrt)` — the
recorded sound stays at FULL level across the whole knob, rev_mix only adds
tail (linear in the knob thanks to the Lua square map). TRADE (stated): no
100%-wet wash on this knob any more — that's rev_decay/WASH or choking the
source. delay_mix deliberately KEPT as a crossfade (a dub delay throw wants
the direct to duck). The reverb spawn/free gate (rev_mix>0) is unchanged.
SAME SESSION, device diagnosis notes: "very faint on headphones, fine on the
mixer" = the SYSTEM headphone gain (PARAMS > LEVELS), not the engine — the
DFM1-attenuation theory is likely RETRACTED; engine-side noise still being
localized (ladder: STOP kills it? → path vs monitor/HP-amp; only while the
take plays? → noise printed at record time + the wet path's fixed 1.5x
makeup; swells with reverb/shimmer? → FreeVerb x2 fallback / shimmer loop /
DFM1 res near the 0.9 clip).

Fifty-fifth change — **DFM1 headroom (ENGINE one-liner, fingerprint STAYS 63,
UNTESTED — rides the next RESTART)**: device report "why is the sound so
noisy?" — leading theory: the wet path's fixed 1.5x makeup (S5) used to feed
LINEAR biquads; since the 48th batch it drives the NONLINEAR DFM1 diode
ladder at ~1.35 full scale = constant saturation grit, new to the player's
ears with this deploy. Fix: DFM1 inputgain 1 → **0.5 with a x2 post-makeup**
(same loudness, clean until `drive` asks; the 0.5/2 pair is the device
tunable). CONFIRM on device with the 10-second test: grain_level down →
noise cleans = confirmed. Other open noise candidates from the same session:
REGN badge lit (regen re-recording mush), noise PRINTED into the take
(record 2s of silence and play it — hissy = input-chain gain staging, then
boosted by the same 1.5x), FreeVerb x2 fallback with rev_mix up, DFM1 res
near the 0.9 clip. Headphone faintness resolved as SYSTEM headphone gain.

Fifty-sixth change — **audio-quality recheck: 2-agent audit of the CURRENT
engine (ENGINE-only, fingerprint STAYS 63 — re-verified programmatically —
UNTESTED, rides the next RESTART)**. Adversarial verifier: ALL TEN stacked
50th/51st/54th/55th items SAFE — JPverb's array-in confirmed against the real
sc3-plugins source (*ar unpacks [L,R] into ONE true-stereo JPverbRaw, no MCE
double-instantiation), DFM1 arg order confirmed against TJUGens source,
LinXFade2 confirmed core, winRead/destructure legal, regen=0 bit-identical,
while-steal safe. ONE WATCH ITEM for the gate: ar-rate Dust/TRand costs real
CPU across drone + up to 8 poly voices — watch %CPU/xruns with a held PADS
chord in GRAIN mode. APPLIED from the quality lens (docs-verified):
* **grain_pitch_spread was 12x too weak SINCE S7** — `(x/12).midiratio`
  double-divides (midiratio IS 2^(st/12)); a 12 st spread delivered ~1 st.
  `/12` removed in \mangler_grain + \mangler_voice_grain. The knob finally
  does what it says — expect it to feel MUCH stronger.
* **five zipper lags**: resonance (.05 — the likeliest pop source: stepped CC
  on a near-self-osc filter; arg-reassign so the fallback rq law shares it),
  drive/dry_wet/delay_mix/rev_mix (.03 — equal-power .sqrt laws step audibly);
  **resample .02** (a step in that blend PRINTS into the take permanently).
* **wet makeup 1.5 → 2.sqrt** — the exact inverse of Balance2's −3dB centre:
  PLAY/pan-0/no-FX now lands at EXACT unity vs the raw take (was +0.5dB into
  the limiter — the S14 "exact recorded sample" claim, now numerically true).
* **shimmer PitchShift pitchDispersion 0 → 0.02** (SC docs: uniform grain
  placement combs at a fixed ratio — softens the robotic octave-up edge).
RULED OUT by real-source verification (do not re-attempt): PlayBuf is cubic
(no BufRd swap needed in voice_slice); \mangler_pv's FFT 2048/sine/hop-0.5 is
the documented-correct PV config; Warp1 and the 2048-sample grain envelopes
are fine as-is. Footnote (accepted): recLvl/preLvl lag independently, so
their sum wobbles bounded for ~10ms across a rec/regen transition.

Fifty-seventh change — **PRINT + tempo-synced delay + next-scene (Lua-only,
fingerprint STAYS 63, renders byte-identical, dist verified; save + reload)**:
the three user-picked workflow features, no engine change.
* **PRINT** (`print_take` momentary + `print_len` 0=AUTO(window)..16s, grp_rec
  10→12): `ctx.print_take` records the MASTER out via the system TAPE
  (audio.tape_record_open/start/stop) for the length, then `ctx.load_sample`s
  the bounce back AS the take (window snap + progressive waveform; the
  32-bit-float/24-bit load_wave support from the 47th change is what makes the
  system-tape wav drawable). Bounces accumulate as mangler-print-NNN.wav in
  dust/audio — the buffer is replaced but material is never lost. cleanup
  cancels a mid-flight print + pcall-stops the tape. GATE: confirm the system
  tape wav format loads+draws; confirm no conflict if the user's own TAPE
  record is running (no query API — documented, not guarded).
* **delay_sync** (grp_delay 3→4, DELAY K1+E3 — the empty alt slot): FREE or
  1/16..1/2 (+dotted); `sync_delay_time` computes delay_time from
  clock.get_tempo (guarded for the sim), called each redraw frame but WRITES
  only when tempo/division changed; times past the 1s delay line clamp; the
  engine's 0.2s lag glides tempo changes. Added to SWITCH_IDS + MOTION_IDS
  (the list-drift lesson applied at birth). SHORT/FULL "SYNC".
* **scene_next** (grp_scene 9→10, momentary — footswitch): Mscenes.next()
  advances the ONE selector to the next FILLED slot (cycling, skips empties,
  says NO SCENES when bank empty) and recalls through the normal path
  (BEAT/BAR quantize + auto-safe apply). print_take/print_len/scene_next
  correctly OUT of the curated lists (transports/config).
GATE (device): print a 2-bar mix and hear it come back as the take; delay
locks to tempo and glides on tempo change; a footswitch stomps through
filled scenes in order.

Fifty-ninth change — **ORBIT + EROSION pages (PAGES 10 → 12; ORBIT Lua-only,
EROSION is ENGINE: +2 commands erode/wear, fingerprint 63 → **65**, UNTESTED)**.
* **ORBIT** (page 11): the instrument wanders the scene bank by itself — one
  partial morph leg at a time (pick a filled slot ≠ current, ramp
  scene_morph_amt to orbit_reach over orbit_rate seconds, PARK by
  invalidate+silent amt reset so the next leg departs from the in-between,
  repeat). Lives in mscenes (orbit_tick at the top of M.tick); drives the
  REAL scene_slot/scene_morph_amt params through pset() so the SCENE page
  shows it, motion doesn't record it, and CAP bottles any moment. One filled
  slot = asymptotic drift toward it; zero = idle. K2 RUN (punch law: hold =
  temporary wander), K3 CAP. grp_orbit 3 params (orbit_on/rate/reach),
  excluded from scene/motion lists (a transport). math.random only in the
  tick, never in draw.
* **EROSION** (page 12): window-synced decay in PLAY mode. Engine: in
  \mangler_play only, a NON-interpolating BufRd fetches the exact sample at
  the head and BufWr writes back `raw*(1-eff) + LPF(raw,wearF)*0.996*eff` —
  each loop pass ages the take (darker by `wear` 9k→1.2k linexp, 0.996
  amplitude/pass). eff = erode*(1-rec)*(1-freeze) lag 0.05: at erode 0 the
  EXACT read sample is written back (bit-identical content — the non-interp
  read is what makes that true; an interpolated read would smear even at
  zero). erode/wear in ALL FIVE def arg lists (uniform-args convention;
  only play uses them) + playParams → auto-union → count 65. Lua: grp_erode
  (add_eng_control ×2); K2 HEAL / K3 SCAR (throws to 0/1, round-trip);
  GEN counter = play_phase wrap count while eroding (Mpages.erosion_tick on
  the redraw clock, reset by clear); erode+wear in SCENE TIMBRE list with
  erode MORPH-EXCLUDED (a buffer writer, like regen).
* Suite: render_pages PAGES list now MIRRORS the script's (a prepend
  mis-navigated every shot — the suite indexes drive goto_page; comment
  added); ORBIT/EROSION shot at 11/12; 63 shots total, eyeballed both.
* GATE: RESTART, confirm **count: 65** (NOT 63 any more), then: erode=0
  overnight leaves a take bit-identical; erode~0.3 audibly darkens over
  passes without runaway; HEAL freezes the age; rec suspends erosion;
  ORBIT wanders audibly between 2+ scenes and CAP catches an in-between.

Sixtieth change — **erosion hardened to product grade (ENGINE + Lua,
fingerprint STAYS 65, UNTESTED)**: (a) **regen/erode INTERLOCK** — the two
free-running write heads can no longer coexist: each param's action zeroes
the other on its own rising edge (no recursion — interlocks act only on
v>0). The "don't run both" gate note is obsolete; the conflict is now
impossible at the param layer, so every driver (keys, MIDI, scenes, chaos)
inherits it. Scene recall order (regen before erode in TIMBRE) makes a
both-hot legacy capture resolve deterministically to erode. (b) **erosion
runs on its OWN constant-rate head** (`eroPhase` Phasor, one pass per
window length; `eroPos = winPos - phase*span + eroPhase*span` derives lo
at audio rate): aging is uniform and predictable, independent of playback
speed AND direction, no skipped samples at rates >1, no wear-character
shift with varispeed — the two documented quirks are deleted, not
documented. (c) GEN counter is now TIME-based (span*60 s per generation,
matching the head exactly), paused under the same conditions the engine
pauses (rec/freeze/not-PLAY). Gate additions: erode at speed 2 and speed
−1 ages at the same rate; raising regen drops erode to 0 and vice versa.

Sixty-first change — **two code-review fix batches (ENGINE + Lua, fingerprint STAYS
65, all 47 renders byte-identical, UNTESTED on device — rides the SAME pending
RESTART as the 59th/60th)**. Two workflow-backed reviews: one over branch `foundry`
whose shared-core findings apply here, and one over this branch, which found 38 more.
Every fix below is applied; the ones with a named test are mutation-proven.
FROM THE FOUNDRY REVIEW (the shared core — the forge-only findings do not apply here):
* **The erosion head ignored STOP.** `eff` was gated on rec+freeze but not level, so a
  stopped instrument with `erode` up kept aging the take (~600 generations in five
  minutes at a 0.5s window, no undo). The regen head two lines below had carried
  `(level > 0.001)` for exactly this reason; erosion, added later as the SECOND
  free-running writer on the same buffer, never picked it up. `level` is now a key in
  BOTH `ioKeys` and `playParams` — the fan-out `rec`/`freeze` already use — so one
  command reaches both synths and the count is unmoved. LESSON: a guard added to one
  of two siblings makes the other a bug with a witness.
* **Motion overdub wiped the lane it was extending.** Playback stored the value it
  ASKED for; `params:set` on a Control stores `map(unmap(v))`, which differs in the
  last bit for a large share of values on an exp spec. The poll then read the loop's
  own output as a live hand and punch-in-replaced. It now reads the value BACK, the
  way `mscenes.account` already did.
* `throw_mem` invalidated by scene recall/morph/chaos/DRY; `regen` in the HEAL/SCAR
  snapshots (raising `erode` zeroes it through the interlock); the tap fallback no
  longer fires after a press that CANCELLED a latched def; `dry_wet`/`erode`/`wear`
  into MOTION_IDS; `sample_file` cleared on CLR; `erosion_reset` on all three
  buffer-replacing paths; one `ctx.next_free` replacing two scanners that silently
  overwrote the oldest recording at 999; one `ctx.tempo`; `ctx.BUF_SECS`/`SERVER_SR`
  replacing bare `60`/`48000` across the modules and the engine (`var bufSecs`).
* **44.1k samples were playing a semitone sharp.** scsynth's buffer read does no SRC.
  `Mpages.convert_sr` (cubic, yields, beside the RIFF walker and the shared decoder it
  uses) converts to the server rate before the engine reads it; falls back to a raw
  load and SAYS so if it cannot decode. No new SC command.
  DECIDED (user, 2026-08-11): the two resamplers stay SEPARATE. `foundry` converts
  through `Mchain.render_wav` (which also does segments, fades, normalize and the grid
  stride for chain export); `main` has the plain whole-file `Mpages.convert_sr`. They
  share the RIFF walker and the sample decoder already, so what is actually duplicated
  is the 4-line cubic kernel. Do NOT collapse them unasked. The one place this bites is
  a future merge: `ctx.load_sample` calls a different function on each branch, so that
  hunk will conflict and someone has to choose which entry point main keeps.
FROM THIS BRANCH'S REVIEW — three that destroy audio:
* **PRINT was not aborted by STOP.** Refusing to START while stopped was only half the
  guard: a STOP mid-bounce silences the master, and the rest of the pass recorded
  digital silence which was then loaded AS the take. The pass now watches for STOP,
  removes the part-silent file, and leaves the take alone.
* **`take_len` shrank on a short punch-in.** It is documented as a HIGH-WATER mark, but
  the rec-off edge overwrote it with the current `pos_end` — so a 200ms overdub over a
  narrowed window set the PSET write bound to a few seconds and the save silently
  truncated a 30s take. A rec pass overwrites only the region it recorded, so the mark
  is now GROW-ONLY; fresh material still resets it.
* **SLICE pads had no end.** `\mangler_voice_slice`'s PlayBuf got a start and no length,
  so a pad played its slice and then everything after it, while the PADS page drew
  eight bounded cells. `note_len` (an ARITY change on note_on/note_one_shot — NOT a new
  command, count stays 65) carries the slice length; a ~3ms fade closes the boundary.
STRANDED STATE AND SIBLING GAPS (the pattern that produced most of both reviews):
* the GRID gated note RELEASES on `keys_enable`, stranding a voice forever — the exact
  trap already fixed for MIDI and the typing keyboard. Presses only, now.
* **the throw engine now owns its params.** `throw(label, ids, apply)` builds the
  restore snapshot FROM `ids` (so what is put back cannot drift from what is set) and
  un-latches any other throw holding one of the same params first. MIX's ENG/TAPE had a
  hand-written pair for this and EROSION's HEAL/SCAR did not; keying the conflict on
  the PARAM makes it automatic. The MIX special case is deleted.
* Lua mirrors the engine's voice STEAL (`pad_order`), so the PADS page stops drawing
  voices that already stopped; the morph honours EDGE_PAIRS like `apply()` does (it
  meets the crossed-pair hazard 15x a second, far more often than a recall);
  `move_pair` writes the widening edge first; motion capture disarms instead of
  stacking every event at a frozen playhead; `src_of` maps the LAST playback frame onto
  the LAST event frame, so a retimed loop stops dropping the tail of every gesture;
  an empty tape in a pset now CLEARS the softcut buffer (it resurrected from the live
  buffer instead of the file); export refuses a second run rather than cancelling into
  a truncated wav, and clears stale temps first.
* **◇ was lying.** `purity()` never tested `dry_wet`, so the "you hear the recording,
  verbatim" mark lit at the 0.5 default (half live input) and even at 0, where the take
  is inaudible; `erode` was missing from the writers test too. It is the conservative
  mark, so it now requires full wet. Expect it to light far less often — that is the
  point.
* `\mangler_voice_grain` gained the drone's equal-loudness overlap compensation (a held
  chord with density up had nothing holding it back); BLOOM surges instead of reading a
  `ctx.shimmer_mem` nothing ever wrote (it REDUCED shimmer above 0.6); SNAP does
  something on a fresh load instead of nothing silently, and its memory is dropped when
  the material it points at is destroyed; dead `@loop_move` removed (`loop_start` is
  reachable by PARAMS/MIDI/grid, just not an encoder — an honest limit beats dead code
  claiming a feature); `pad_level` got its missing SHORT label; orbit uses `ctx.FPS`;
  the padlock pset write is pcall-guarded like its siblings; the header's control map
  says twelve stations again.
TOOLING: **norns is Lua 5.3 and a dev box may have a newer `luac`** (5.5 here) which
ACCEPTS syntax 5.3 rejects — a clean local parse is necessary, not sufficient. Every
file was scanned for 5.4+-only constructs (none), the stale `luac5.3` invocations were
fixed, and the hazard is written into the Workflow section. The render harness now READS
`PAGES` out of the script instead of mirroring it by hand (a drifted copy would render
the wrong page while the byte-diff kept passing), and its `params:delta` moves in the
controlspec's WARPED space like the real one — a cutoff detent at 200 Hz was moving
200 Hz offscreen and 14 Hz in the hand. The dead 876-line `proto_redesign.lua` is gone,
and the Launchpad refresh no longer allocates a table and a closure every frame.
TESTS: NEW `tools/test_wav.lua` (19 assertions) — main had no harness at all. It lifts
the real functions out of mpages rather than copying them, and asserts the 44.1k→48k
conversion by VALUE at a wall-clock position, because a rate error is a pitch error.
Mutation-proven: disabling the conversion fails 8 assertions. It also asserts every
MOTION_IDS entry has a SHORT label — the hand-maintained-list drift, made checkable.
VERIFIED: `luac -p` clean, engine paren-balanced, **command count still 65**, all 47
renders byte-identical, source == dist. DEPLOY: the engine changed (erosion level gate,
`level` in playParams, `note_len`, voice overlap comp, `bufSecs`) → rsync, SYSTEM >
RESTART, **confirm `count: 65`**, then: STOP with erode up leaves the take intact
overnight · a 44.1k sample loads in tune · a SLICE pad plays ONLY its slice · overdub a
second MOTION lane and the first survives · STOP during a PRINT leaves the take alone ·
a short punch-in then PSET save/load keeps the whole take.

Sixty-second change — **two pieces brought over from `foundry` to make the INSTRUMENT
better (Lua-only, fingerprint STAYS 65, all 47 renders byte-identical, UNTESTED on
device)**. The branches now have distinct jobs: `main` is the instrument, `foundry` is
the Octatrack utility. These are the parts of foundry that are not Octatrack plumbing.
* **`ctx.record_pass` — a port, not a feature.** `print_take` was a bespoke
  reimplementation of the same machinery (open the system tape, count frames, stop,
  flush, hand back), and it had grown its own STOP-abort by hand. The shared version
  replaces it: `record_pass(path, secs, on_tick, done)` + `record_stop` /
  `record_limit` / `record_cancel`. The `on_tick` hook is what it buys — a param
  automated ACROSS the pass — so `ctx.print_take(sweep)` can now print a MOVE rather
  than a moment (a scene morph, an erosion decay) with no chain involved. `cleanup`
  goes through `record_cancel` instead of poking a clock it half-owned.
* **`ctx.take_to_wav` split out of `export_take`**, so the dump-the-take-to-a-file path
  has ONE implementation. Lua cannot read an SC buffer, so that file IS the API — the
  export and the chopper are both built on it.
* **CHOP: the pads land on the material's own attacks.** `pad_pos` was
  `lo + (i+0.5)/8 * span` — eight EVEN eighths regardless of what you recorded, so a
  drum loop chopped arbitrarily. `Mpages.transient_cuts` (a 10ms energy envelope,
  strided so it is affordable on a Pi) finds the onsets in the dumped take and
  `ctx.pad_cuts` stores them as absolute buffer fractions. NO engine change was needed:
  the slice-end fix in the previous change already threads a per-note position AND
  length, so variable-length slices were already supported.
  - the pads WRAP onto however many slices were found (five slices -> pads 6-8 replay
    1-3), the same "more keys than pads" idiom the MIDI and grid note paths use. Falling
    back to even eighths for the remainder would have overlapped the chopped ones.
  - chopped boundaries point at PARTICULAR audio, so anything that replaces the buffer
    drops them (`ctx.pads_uncut` from clear / load / print / take-pset-read) — the same
    rule the window's SNAP memory follows. They ride the padlock PSET beside the other
    per-pad state, and `padlock_pset_read` runs after `take_pset_read`, so the cuts come
    back with the audio they were cut from.
  - `pad_chop` and `pad_even` are MOMENTARY params (grp_voice 8 -> 10) rather than keys:
    both PADS key slots are claimed, and momentary means MIDI-learnable — the point is a
    footswitch. PARAMS-only is the honest limit, like `seq_div`.
  - the PADS page draws the REAL boundaries once a chop exists (even dividers otherwise)
    and labels each cell with the SLICE it plays, not the pad number, so the wrap is
    self-evident. The teaching hint row becomes "CHOP - n SLICES ON THE HITS" while a
    chop is in force — measured at 117px worst case, under the 124px centered limit;
    drawing both overran the line, which is why the hint yields.
* mpages now has ONE file reader (`open_src`/`read_frames`/`close_src`) that both the
  resampler and the transient detector use, instead of the resampler carrying its own.
* TESTS: `tools/test_wav.lua` 19 -> **47 assertions**. Transient detection is asserted
  against a generated file with impulses at KNOWN times (all four found, within a 10ms
  envelope window either side); the slice model is LIFTED out of mangler.lua (not
  copied) and asserted for boundaries, the wrap, positive lengths on all eight pads, and
  a degenerate one-entry cut list.
* GALLERY: regenerated at 4x, byte-identical — no page's drawing changed, because the
  chop only alters what is drawn when a chop EXISTS and the suite's walk has none.
  There is deliberately NO `pads-chop.png`: the suite cannot reach `ctx.pad_cuts` (a
  local in mangler.lua) and a test-only backdoor in production code is not worth one
  image. That state was verified by a one-off patched render and by the model tests.
* DEFERRED, in this order and for this reason: normalize/trim the take (`peak_of` /
  `trim_tail`) and window-snap-to-first-onset (`first_onset`) both operate on the
  dumped take file, which the chopper now stands up — doing them after it means reusing
  that path instead of building it twice. Nothing depends on them.
* NOT brought over, and should not be: `lib/mot.lua` (pure .ot bytes), the 64-cell rack,
  export/import, the 44.1k target, and the autosampler — its output is a rack of cells,
  and the instrument has nowhere to put those.

Sixty-third change — **TIGHTEN + the consolidated device gate (Lua-only, fingerprint
STAYS 65, all 47 renders byte-identical)**.
* **`ctx.take_tighten`** (the safe half of the deferred pair): pressing REC and then
  playing leaves your reaction time at the head of every take, and letting go late
  leaves room tone at the tail — the rec-stop window snaps to where the record HEADS
  were, which is not where the sound is. `Mpages.onset_bounds` finds the first and last
  positions above a floor in the dumped take and the window pulls in onto them, with
  5ms of room either side so a soft attack is never clipped. NON-DESTRUCTIVE by design:
  it only moves pos_start/pos_end, so it is undoable by hand and TAKE K3 SNAP still
  remembers where you were. Silence REFUSES rather than windowing nothing. Momentary
  param in grp_rec (12 -> 13) so a footswitch reaches it.
  The NORMALIZE half stays deferred on purpose: it would rewrite the buffer, making a
  fourth writer alongside rec/regen/erode — and those three needed an interlock and a
  level gate to stop fighting each other, neither of which has been heard on hardware.
  Adding a writer before validating the existing ones is the pattern that produced the
  erosion bug in the first place.
* **`doc/device-gate.md`** — the fifteen pending per-change gates, folded into ONE
  ordered pass. Ordered so the checks that would invalidate everything else come first
  (count 65 is fail-stop; the three audio-destroying fixes come before anything that
  costs you a good take), grouped so a setup is not repeated, and every row names the
  change to SUSPECT when it fails. With a month of batched work "something sounds
  wrong" is not a useful report, and that column is the difference.
* VERIFIED: group counts re-checked against the params that follow each add_group (the
  desync gotcha); test_wav.lua 47 -> **52 assertions** (onset bounds asserted against a
  file that is silent except for a known span, both edges, a sub-range search, and the
  silence refusal).

Sixty-fourth change — **S25 LAYERS: multitrack on the core that has room for it
(Lua-only, ENGINE UNTOUCHED, fingerprint STAYS 65, branch `layers`)**. Full design +
gate: doc/layers.md. Two more independent loop decks on softcut, beside the tape.
* **The shape, and why.** Not more scsynth drones — that was a deliberate CPU decision
  (one core on a Pi 4) and four granular voices would break it. softcut is a separate
  core and near-free, which is this project's own stated rationale for what goes where.
  So: ONE deep track (the engine take: granular, warp, spectral, window, pads, erosion)
  plus THREE shallow ones (tape + 2 layers: loop, varispeed, reverse, overdub). Stated
  plainly in the doc: a softcut deck CANNOT be granulated. It is a loop, not a mangle
  target.
* **NEW `lib/mdeck.lua`** (8th lib; amalgamate assert 7 -> 8) — a deck is a voice pair,
  a buffer region and a param prefix. Instantiated twice: `lay1` (voices 3/4, 120-180s)
  and `lay2` (voices 5/6, 180-240s). The gap at 60-120 is deliberate: `foundry`
  auditions chain cells at 70s, so picking around it means the branches merge without a
  silent buffer collision.
* **The tape deck is NOT refactored onto mdeck, on purpose.** It is the same shape and
  the honest move is one abstraction used three times — but it is one of the few paths
  confirmed on hardware, and nothing since 2026-07-16 has been. Rewriting a proven path
  before the gate is the wrong order. The duplication is real, named, and gated on the
  device pass rather than hidden.
* **THREE collisions**, which is what made this not purely additive:
  (1) `sc.buffer_clear()` takes the WHOLE buffer — a TAPE erase would have silently
  wiped both layers. Every clear is now region-scoped. (2) There is ONE
  `sc.event_phase` handler; mtape owned it and filtered on `v == 1`, and now forwards
  anything else to `ctx.deck_phase` so each deck drives its own playhead and paints its
  own picture. (3) The record SOURCE is global to softcut's two input channels, not
  per-voice, so `cut_source` stays ONE shared control — all decks record the same thing.
  Documented so nobody later expects per-deck dry/wet.
* **`pre` defaults to 1 (OVERDUB)**, unlike the tape's 0 (REPLACE): these are LAYERS,
  stacking is the job, and it is the loop-pedal gesture people already have. The page
  names the mode (DUB / REP) so it is never hidden, and K1+K3 erases one to start over.
* **LAYERS = page 13.** Two strips: the deck's real material, the loop bracket over it,
  the head, a level bar. Selected bright / other dim, and a deck that is stopped or
  turned down dims further — the audibility rule, so you can always see which of them
  you are hearing. E2 selects, E3 its level; K1+E2 rate, K1+E3 moves the loop (the
  existing `move_pair`, which already writes the widening edge first). K2 REC under the
  punch law, K3 PLAY, K1+K3 erases THIS deck only.
* Layer params join the curated lists (levels/rates/loops/overdub in TIMBRE, reverse in
  SWITCH, transports OUT like `tape_rec`, `layer_sel` out as a UI cursor), the loop
  edges join `EDGE_PAIRS`, and every id got a SHORT label — the drift check in
  test_wav.lua enforces that last one.
* VERIFIED: **all 47 prior shots differ in the header dot row and NOWHERE else** —
  proven by re-rendering `main` with a 25-tick pad standing in for the 13th page's walk,
  which collapses every wider diff (they were pure animation phase). NEW
  `tools/test_deck.lua`, **35 assertions**, driving the real module against a softcut
  stub that records what it was told: region isolation, loop bounds as fractions of the
  REGION, crossed and zero-length bounds, per-voice phase routing, the master/STOP fold,
  and per-deck pset files. Mutation-proven: making `clear` whole-buffer fails 4
  assertions. source == dist across 48 shots.

S25 REVIEW PASS (same change, pre-gate — four fixes, none of which the render
suite would have caught, because three of them are only visible while an encoder is
TURNING or a master is moving):
(1) **The layer encoders read `--` and drew no dial.** `fmt_value` mapped `@win_move`
to an anchor param by hand and knew nothing about the new compound targets, and
`param_norm` (the footer dial) had no idea about ANY of them. Fixed by making ONE
resolver, `ctx.enc_target`, that enc(), the footer value and the footer dial all ask —
they each needed the same answer and two of them didn't have it. GOTCHA inside the
fix: `enc()` must keep `id` as the COMPOUND target, not the resolved one, because the
footer matches its flash against the slot's id — reassigning it silently stopped the
value swelling at all. `@win_move` works for exactly this reason.
(2) **The master output didn't master the layers.** `out_level`'s action was
`Mtape.update_mix`, which touches the engine and the tape only. STOP had been wired to
the decks; the master had not.
(3) `body_LAYERS` indexed `decks[1]`/`decks[2]` directly — a latent crash if the deck
list is ever shortened. It loops now.
(4) **`play` is MUTE, and now says so.** It silences by LEVEL rather than stopping the
head — deliberately, because two decks at different rates only hold their drifting
relationship while both heads keep moving; stopping one would snap it back to its loop
start and lose the phase. The strip said "STOP", which is the one thing it does not do.
The key is labelled MUTE and lit means muted.
Suite gained LAYERS_TURN (the footer mid-swell — the shot that proves fix 1); 50 shots,
source == dist.

Sixty-fifth change — **tools/test_control.lua: the control surface, offscreen (tooling
only, no script change)**. The S25 review found four defects and noted that THREE of
them could not have been caught by the render suite, because it proves the instrument
DRAWS correctly and never turns an encoder or presses a key. That is a gap in the
tooling, not just in that change, so it is now closed.
* **123 assertions**, driving the REAL script through `enc()`, `key()` and `params`
  with a no-op screen. Five things it asserts: every ENC_MAP target is a real param or
  a compound one that `ctx.enc_target` resolves AND `SHORT` names (the "reads --"
  bug); every page's E2 and E3 move something, tried in BOTH directions because a knob
  already at its maximum is not a broken target; `out_level` reaches all six softcut
  voices (the master-doesn't-master bug); STOP silences every deck and START brings
  them back; and every page survives its own keys.
* MUTATION-PROVEN against the actual defects: removing the layers from `out_level`
  fails 3 assertions, deleting one line of `ctx.enc_target` fails 2, and dropping the
  `st.unlatched` guard fails 1.
* **That last one is asserted at the SOURCE level, deliberately.** The guard protects
  defs that have both `lit` and `tap`, and on this branch neither reachable def
  qualifies — SCENE's RCL only lights BETWEEN press and release, PADS' pad is a gate.
  The only def that can hit it is CHAIN's PRINT, which lives on `foundry`. Rather than
  fake a runtime test, the harness asserts the guard exists where it lives, so it
  outlives the branch that needed it. Worth knowing: that guard is currently
  unexercised at runtime on main/layers.
* **The shared-stub extraction: CAUSE FOUND, and it now works.** (This paragraph
  replaces the "backed out, unexplained" note that stood here first.) Pulling
  render_pages.lua's offscreen norns into `tools/uisim/env.lua` changed 31 of 50 shots.
  The reason: the per-frame hook was a file-level **`local SCENARIO`** declared INSIDE
  the stub block, which the caller assigned to directly. Moving that code into a module
  made it a local of `install()`, so the caller's `SCENARIO = function(t) ... end`
  created a **global that nothing ever read** — the scenario silently never ran, every
  poll (amp_in, rec_amp, play_phase, the softcut phase) froze at its initial value, and
  the shots that depend on animated data changed while SCENE/MOTION/ORBIT did not.
  No error anywhere. A nil-global TRAP missed it because nothing READ an undefined
  global; the caller WROTE one.
  Found by bisection: wrapping the stub in a function changed nothing (0/50), moving it
  to a separate file changed everything — which pointed straight at a name that stopped
  being shared. THE GENERAL LESSON, worth more than the fix: **moving code into a module
  silently converts an assignment to a former upvalue into an assignment to a global**,
  and Lua does not warn. Any `local` in extracted code that the CALLER writes to is this
  bug waiting to happen.
  The scenario now arrives as a getter (`opts.scenario`) so the caller's own local stays
  the single source of truth. Renders byte-identical across all four variants;
  test_control.lua now shares that one environment instead of stubbing a second norns
  (355 -> 250 lines).
* (superseded) The original note read: Pulling render_pages.lua's
  offscreen norns into a `tools/uisim/env.lua` that both harnesses could use is the
  obvious way to avoid two fake nornses. It changed 31 of 50 rendered shots. The
  extracted code was verified byte-identical to the original, no global was lost (a
  nil-global trap found nothing), and the random state at script load matched exactly —
  and I could not account for the difference. Shipping tooling whose behaviour I cannot
  explain is worse than a second stub, so it was reverted and the renderer is untouched.
  The control harness stubs the screen as no-ops instead: it never draws, so it does
  not want the pixel model, which is the only subtle part of the renderer's environment.
  **If anyone picks this up again: the difference is real, deterministic and
  reproducible — it is worth understanding before trusting the render suite's
  byte-identity as strongly as this project does.**

Sixty-sixth change — **the grid is testable now, and LAYERS has a grid workspace**.
* **THE GRID WAS NEVER ACTUALLY DEVICE-ONLY.** Every grid change in this project has
  shipped unverified on the strength of "the sim stubs the grid". It stubbed
  `grid.connect()` to return a FRESH table each call, so the `gg.key` handler the
  script attached was thrown away. Returning ONE object and exposing it (and giving
  `gg.device` a value, which is what mgrid's redraw guard tests) makes the real key
  handler drivable and every `gg:led` call observable. Three lines. The LED stubs also
  had to be METHODS — `gg:led(...)` through a plain function silently shifts every
  argument by one, which is the same class of mistake as the SCENARIO one above.
* **LAYERS grid workspace** (rows 3-6, page-aware like PADS and SCENE): a row per deck
  — row 3 is deck 1, row 4 is deck 2, rather than a shared selector, because on a grid
  you want to reach the other deck without changing the screen. Each row is the same
  two-pad span gesture the window and tape loop use; row 5 arms, row 6 mutes. Recording
  blinks (the write-flag convention), a muted deck's row dims.
* test_control 123 -> **136 assertions**, now covering the grid: the spine reaches the
  same params from the LAYERS page, a span sets the RIGHT deck's loop and leaves the
  other alone, the transports toggle, the same pad means something else on PADS, and
  the workspace actually lights both deck rows. MUTATION-PROVEN: making both rows
  address deck 1 fails 3, dropping the workspace dispatch fails 5.
* Renders byte-identical across all four variants; source == dist.

Sixty-seventh change — **the sample library, five demo presets, and a dead MIDI
mapping (NO script change at all — `presets/` is new data, fingerprint STAYS 65,
device-applied 2026-08-11)**. Nothing here touches mangler.lua, lib/, or the .sc.
* **THE LIBRARY WAS PLAYING A SEMITONE SHARP AND NOBODY SAW IT.** 4724 wavs (the
  Octatrack MKII factory set — Elektron · Loopmasters · Origin Sound · Sample Magic ·
  Samples From Mars) were 44.1k/24-bit, and **scsynth's buffer read does no SRC**, so
  every one of them played ~8.8% fast and sharp on a 48k norns; a 120 BPM loop read as
  130.6. Converted to 48k/16-bit on the Mac (ffmpeg swresample — no soxr in that build)
  and pushed to `dust/audio/` as five top-level folders. VERIFY A RATE CONVERSION BY
  DURATION, not by the header: a botched one that only relabels comes out 8.8% short,
  and loops landing on exact bar lengths (1.92s @125, 4.0s @120) is the signal it
  worked. Side effect worth knowing: `ctx.load_sample` now takes its fast path, because
  `convert_sr` no-ops when the rates already agree — the 61st change's resampler is
  dead code for this library.
* Two Mac-sourced-library traps, both live here: **AppleDouble `._*.wav`** doubled the
  apparent file count (5116 of them; Finder-over-SMB filters them, `rsync` does not),
  and these are REAPER renders carrying a **`bext` chunk before `fmt `** — any header
  parser assuming `fmt ` at offset 12 reads 0 Hz. `Mpages.load_wave` walks chunks
  properly and is fine; the naive audit script I wrote was not, which is how it
  surfaced.
* **PRESETS ARE GENERATED AGAINST THE DEPLOYED PARAMSET, NEVER THE REPO.** The device
  was running a build without `grp_layers`/`layer_sel`; authoring from the working tree
  would have written ids the device does not have. The method is reusable and cheap:
  take the first ~343 lines of `tools/uisim/render_pages.lua` (the stub env, up to
  `dofile(MANGLER)` + `init()`), point it at the DEPLOYED single-file build, and
  enumerate `params.list` — you get every id, type, default and range exactly as the
  device builds them.
* **SIMULATE THE LOAD, not just the write.** A pset load fires every param's ACTION,
  and an action that throws there is a black screen, not an error (the redraw gotcha
  above). Replaying norns' own reader loop over each generated file — match
  `"id": value`, tonumber, set, then call `params.action_read` — proved 108/108 apply,
  no unknown ids, nothing thrown. Three values every preset must set deliberately:
  **`dry_wet` = 1** (the engine is `dry*(1-dw).sqrt + wet*dw.sqrt`, so the 0.5 default
  is half LIVE INPUT — a sample-only preset at 0.5 is quiet for no reason), `mix` = 0
  (no tape audio ships), and **every momentary param pinned to 0** — a `1` on
  `print_take` or `chaos_throw` fires its action the instant the preset opens.
* Scene sidecars were written with norns' OWN `tab.save` (fetched off the device) so
  the reference-linking format cannot drift; `tab.load` on the device confirmed all
  five parse. Slot 1 of each bank is the preset as it loaded, so RCL 1 is a way home.
  Partial slots are fine and intended — `apply()` skips ids a slot does not carry.
* **A REMOVED PARAM LEAVES A DEAD MIDI MAPPING, SILENTLY.** `mangler.pmap` still mapped
  CC 100 to `seq_play`, deleted with the sequencer in the 49th change; norns drops an
  unknown id on read, so the pedal simply did nothing and said nothing. Repointed to
  `stop_all`. RULE: when a param is deleted, grep `presets/` and the pmap for its id —
  psets and pmaps name params by id and neither validates.
* STATED, NOT HIDDEN: **the presets have never been heard.** Values are validated and
  in range, sample paths confirmed present, actions proven not to throw — the balances
  are reasoned, not eared.
* DEVICE STATE at the time: sclang restarted 04:45 with the current .sc (30s after the
  file changed), so all the batched engine work IS live — but the last script loaded
  was `buoys`, so **`count: 65` is still unconfirmed and `doc/device-gate.md` is still
  unrun**. Loading preset 1 is a reasonable first step into that gate: if ◇ lights on
  a clean loop, a good part of the signal path has proved itself.

Sixty-seventh change — **the grid's device lessons, and the Launchpad driver, under
test at last (tooling only)**.
* **test_control 136 -> 143**: every grid fix CLAUDE.md records as a device lesson now
  has a test, and all of them HOLD. A release belongs to the surface that took the
  press (hold a pad, change page, release — this is what latched `tape_reverse` forever
  and stranded held note voices); note-offs are not gated on `keys_enable`; two fingers
  on the scene bank; the spine reaches the same param from every page; grid STOP
  silences the layer decks. MUTATION-PROVEN on the one that matters most: routing a
  release by the CURRENT page instead of the press's surface leaves a stale span anchor,
  and the test reads 0.125 where 0.5 was expected — exactly the documented symptom.
* **NEW tools/test_launchpad.lua, 41 assertions.** The Mini MK3 driver is
  device-confirmed but its harness was throwaway. The parts asserted are the ones that
  fail SILENTLY: pad geometry (Programmer mode numbers from the BOTTOM row while the
  grid's y=1 is the TOP — get it backwards and the surface is flipped with no error),
  the full round trip, the semantic palette and its 7-bit ceiling, a monotone brightness
  ramp, the SysEx header checked against Novation's documented frame, and the port
  choice.
* **TWO OF MY OWN TESTS WERE WRONG BEFORE THE CODE WAS**, which is worth recording:
  `LP_HUE` is the RGB table and the NAMES live in `LP_HUE_ID`; and a DAW-only port is
  correctly REFUSED (it lights but never reports a press, so falling back to midigrid
  gives a working grid rather than one that looks alive and does nothing).
* And the DAW-exclusion test only bit once the device names were REAL: tidy names like
  "LPMiniMK3 DAW In" do not exercise it, but a true ALSA name carries a `28:0` suffix
  whose digits match the same "second interface?" heuristic the port choice uses. A test
  written with clean fixtures passed against a mutant that a real device would have
  caught.
* 271 assertions across four harnesses; renders byte-identical; source == dist.

Sixty-eighth change: **design-review fix batch (Lua + tooling, ENGINE UNTOUCHED,
fingerprint STAYS 65; renders: only the 3 LAYERS shots moved, by design)**. A
full-codebase review; every finding verified before fixing, the two sharpest
mutation-proven.
* **◇ was lying again, this time about the layers.** purity() never looked at
  the layer decks, so the mark stayed lit while a deck audibly played over the
  take (proven offscreen: the header was pixel-identical with a playing layer,
  and drive killed exactly the 8 diamond pixels). It now goes dark when any
  deck holds material, is playing, and has level up. Same class as the 61st
  change's dry_wet fix; every NEW audio source must join the mark's checks.
* **The 100ms loop floor could cross a region boundary.** mdeck floored
  `hi = lo + 0.1` PAST the region end, so a loop parked at the far right of
  lay1 would read and record the first 100ms of lay2's material. Clamped
  inside the region by moving the start back; mtape got the same clamp (its
  overflow landed in the 60-120s gap reserved for foundry's cells).
  test_deck 35 -> 37, mutation-proven.
* **take_pset_read now forgets the SNAP memory**, like the other two buffer
  replacers (its own stated rule: whoever replaces the buffer forgets the
  remembered bounds; this was the one path that did not).
* **The layer loops joined the conventions their siblings had**: FINE_IDS
  span scaling covers @lay_move (test_control 143 -> 145, mutation-proven),
  lay rates joined RATE_IDS, layer_sel joined SELECTOR_IDS (the selector
  reads at rest like SLICE/LANE/SLOT; the only render diff, layers.png
  regenerated). TAPE's erase now disarms tape_rec first, like the LAYERS
  erase. The morph's stranded-restore path honours EDGE_PAIRS (widening
  edge first), the rule apply() and the sweep already followed.
* **Dead code removed**: BAND_T/B, the @loop_move SHORT/FULL labels,
  ctx.deck, the unread ctx.pad_cut/pad_pos/pad_len bindings, ctx.pad_count,
  ctx.pass_progress (write-only), SHORT.kb_octave plus the kb_octave flash
  writes no surface ever displayed, mtape's redundant twave_any clear,
  mgrid's unreachable st==nil guard. KEPT deliberately: ctx.record_stop and
  ctx.record_limit (unused on this branch, foundry merge parity) and
  note_one_shot (removing it moves the fingerprint).
* **One law instead of mirrors**: Mtape.gains() is THE deck gain law
  (update_mix sends it, body_MIX draws it); ctx.cut_rec_amp() is the one
  record-meter blend (mpages + mdeck); param_norm resolves and calls
  value_norm. Stale text fixed: mangler.lua's two station counts (now
  thirteen), test_control's header (it DOES share tools/uisim/env.lua).
VERIFIED: luac clean, 275 assertions across the four harnesses, 47 of 50
base shots byte-identical (the 3 LAYERS diffs are the selector-at-rest
footer), source == dist (66 shots total across the 4 variants). Lua-only:
save + reload. The engine RESTART + count-65 device gate is unchanged and
pending.

Sixty-ninth change: **the registry check + the ◇ harness (tooling + list
exports, NO behavior change, fingerprint STAYS 65, all renders byte-identical,
334 assertions total)**. The 52nd change named the structural risk ("three
hand-lists over one registry") and deferred the fix; this retires the defect
class without moving the lists.
* **Membership is now TOTAL.** mscenes gained `SCENE_EXCLUDE` and mmotion
  `MOTION_EXCLUDE`: explicit, reasoned lists of what each machine deliberately
  leaves out (exported beside the includes; EDGE_PAIRS and CHAOS exported
  too). test_control's new section 9 walks the REAL paramset and asserts every
  param is in the list or its exclude, never neither and never both, and that
  no entry names a deleted param. A NEW param now FAILS the harness until
  someone decides — the exact failure mode of the 64th change (LAYERS missed
  purity, FINE_IDS, RATE_IDS and SELECTOR_IDS in one change) can no longer
  ship silently. Mechanical siblings enforced the same way: every
  `*_start`/`*_end` pair must be in EDGE_PAIRS and FINE_IDS; every
  x-unit rate param in RATE_IDS (pitch excepted, its own formatter); every
  ENC_MAP + VOICE_FACE target has a SHORT footer word.
* **Section 10: the shipped presets/pmaps are validated** against the live
  paramset — a pset or pmap line naming a deleted param is silently dropped
  by norns (the dead seq_play CC 100 pedal), so now it fails offscreen.
* **NEW tools/test_purity.lua (41 assertions): the ◇ mark, end to end.** It
  has lied twice (dry_wet default; the layer decks). The harness records
  material into the take, the tape AND a layer, renders the REAL header, then
  flips all 20 reasons the mark must die — every audible source, every hold,
  every buffer writer — asserting the diamond (detected by its exact
  8-lit/5-dark pixel shape) dies and revives each time. Mutation-proven:
  re-introducing either historical lie fails exactly its assertion.
* Seven mutation checks on the classification (a removed exclude, a removed
  FINE entry, a removed RATE entry, a removed SHORT entry, a stale exclude,
  a dead CHAOS target, a corrupted preset id) each fail exactly their
  assertion.
VERIFIED: luac clean, 334 assertions across FIVE harnesses (163/37/52/41/41),
renders byte-identical, source == dist. Save + reload only if deploying; the
engine RESTART + count-65 device gate is unchanged and still pending — it is
the one remaining item no harness can substitute for.

Seventieth change: **deeper review — ◇ misses pan, the engine contract check,
the erase arc under test, doc staleness (Lua + tooling + docs, fingerprint
STAYS 65, all 66 render shots byte-identical, 344 assertions)**.
* **◇ missed `pan`, the third source-shaped miss.** The PLAY voice runs
  Balance2 on `pan`; it is MIDI-mappable and rides scenes, so a recalled
  scene with pan hard left kept the mark lit over an output that is plainly
  not the recording. purity() now tests it; test_purity gained the move
  (41 -> 43) and reverting the check fails exactly its assertion.
* **The engine command CONTRACT is now checkable offscreen** (test_control
  section 11): every add_eng_* id and every `engine.X` call is guarded with
  `if engine[id]`, so a typo'd id was a knob that silently did nothing,
  forever, on the device only. The harness parses the .sc's command union
  (ioKeys + playParams + revParams + explicit addCommands) and diffs the Lua
  side against it. Clean today; a typo'd `rev_locut` mutation fails SIX
  assertions (the classification net catches it too — defense in depth).
* **The K1+K3 erase arc finally has a test** (section 6b): the one
  destructive key path fired from the redraw clock had zero offscreen
  coverage. It now asserts the landing (TAPE erase disarms tape_rec first,
  opens the loop), that no DRY leaks on either release, and the abort zone.
  Writing it caught an interference worth knowing: section 6's key mash
  latches ORBIT (by design) and it captures scenes, so the wander was
  morphing the loop edges under the assertions — background movers must be
  silenced in tests that read params over ticks.
* **The sim's Control:set now range-clamps** like the real one (env.lua):
  an out-of-range params:set was stored verbatim offscreen and refused on
  device, a fidelity gap a harness could hide behind. All 66 render shots
  proven byte-identical after the change.
* **Doc staleness fixed**: engine-map.md's erosion paragraph now describes
  the constant-rate own head and the STOP/level gate (60th/61st changes) and
  the slice voice's note_len bound (61st); device-gate row 6.12's purity
  criterion now includes the tape/layer/pan conditions; stage 9's rows
  renumbered in order. Checked clean: both workflow docs already carry
  HISTORICAL banners, README's page table needs no count.
VERIFIED: luac clean, 344 assertions (171/37/52/41/43), all 66 shots
byte-identical across the 4 variants and source == dist. The device gate
remains the one open item.

Seventy-first change: **robustness pass — malformed audio files (Lua +
tests + docs, fingerprint STAYS 65, renders byte-identical, 350 assertions)**.
A fuzz probe fed ten malformed WAVs to every parser entry point and found two
real defects; both fixed at the boundary, both regression-tested.
* **A data chunk that lies about its size crashed the instrument.** A file
  whose header claims more audio than the file holds (a truncated copy, an
  interrupted download, write_take cut off mid-save) made `read_frames`
  return without honouring its own zero-pad contract; `onset_bounds` and
  `transient_cuts` then indexed nil and THREW — inside the TIGHTEN and CHOP
  param actions, where a Lua error is a black screen mid-set. read_frames now
  zero-fills whatever a short read leaves uncovered. Mutation-proven (3
  assertions), but only after sharpening the test file: a PARTLY truncated
  file passed the unfixed code by reading STALE values from the reused L/R
  tables — the crash needs the very first read to come back empty. That
  subtlety is written into the test.
* **A corrupt rate header was a disk bomb.** `convert_sr` sized its output
  from `frames / (in_sr/sr)`: a wav claiming 1 Hz would expand 4800 frames
  into 230M output frames (~921 MB, minutes of work). The unfixed behaviour
  ran until killed when probed. Two fences now: convert_sr REFUSES an
  implausible declared rate (outside 4 kHz..384 kHz) at its own boundary —
  an opt-in cap is protection a future caller forgets — and it takes an
  optional `max_secs` output cap, which `load_sample` passes as BUF_SECS + 1:
  converting past what the buffer can hold was pure waste even for honest
  files (a 30-minute DJ mix used to convert in full for 60 seconds kept).
* All ten fuzz shapes (empty, non-RIFF, header-only, truncated fmt, zero
  channels, zero bits, zero/1 Hz rates, a 4 GB chunk-size claim, a lying data
  chunk) now degrade to nil returns, never a throw.
* **Measured today, offscreen (Mac, sim, draw+grid stubbed to no-ops):** the
  allocation-free hot path HOLDS at all 13 pages under a loaded state —
  0.000–0.003 KB garbage/tick (worst PADS), 61–160 µs/tick. The 5th change's
  claim, re-verified at 2.6x the page count.
* **doc/layers.md now records the merge's real conflict**: the regions merge
  cleanly but `foundry`'s audition claims softcut voices 3/4 — layer 1's here,
  with all six voices taken — so the audition must borrow a pair on merge.
  The buffer planning never solved that half, and the doc now says so.
VERIFIED: luac clean, 350 assertions (171/37/58/41/43), renders byte-identical,
source == dist. The device gate remains the one open item.

Seventy-second change: **the pset restore repaints every strip + the delay
line reaches 2s (Lua + ONE engine constant, NO new command, fingerprint STAYS
65, all 66 render shots byte-identical, 365 assertions)**.
* **A restored loop no longer plays under a blank picture.** Lua cannot read
  the softcut buffer, but the wav a pset restore reads FROM is right there —
  the tape and both layer decks now hand it to a repaint. mpages' async fill
  became ONE queue serving every strip (the take, the tape, the deck bins):
  fills for different targets coexist, a fill for the same bins table
  supersedes its queued one, and each clear cancels only its OWN strip's fill
  (a CLR must stop the very repaint that would redraw what it erased, and
  nothing else). load_wave keeps its exact take semantics on top of the
  shared queue_fill. Wiring mutation-proven in test_deck for BOTH decks —
  mtape's restore is asserted there too, so the sibling this module has
  deliberately not absorbed cannot drift.
* **DelayC 1s -> 2s** (the one ceiling worth raising): a half-note sync now
  fits down to 60 BPM instead of silently clamping below 120. The spec, the
  sync clamp and the footer format follow the line; ~0.75 MB of server
  memory; an ARG CONSTANT, not a new command — count STAYS 65, and the
  change rides the SAME pending RESTART as everything since the 48th batch.
  Gate addition: sync 1/2 at 60 BPM and hear a true 2s repeat.
VERIFIED: luac clean, engine parens balanced, 365 assertions
(173/46/62/41/43), all four mutations fail exactly their assertions
(each deck's missing repaint, the sync clamp left at 1s, the supersede
removed), renders byte-identical across the 4 variants, source == dist.

Seventy-third change: **the design-review batch from the play-test voice memo
(Lua + presets + tooling, ENGINE UNTOUCHED, fingerprint STAYS 65, branch
`layers`)**. The report was "running scenes resets the take window and it takes
a long time to hear the buffer again", plus asks for easier resampling, layer
loading, deeper presets, dead-code cleanup. Everything below is Lua or data:
save + reload. The engine RESTART for count 65 is unchanged and still pending.
* **THE WINDOW RESET, root-caused and fixed at BOTH ends.** pos_start/pos_end
  ride scenes by design, so any scene captured while the window was the full
  60s buffer reopened ~56s of silence over a short take on recall. Worse, the
  SHIPPED presets baked it in twice: every pset carried pos_start 0 / pos_end 1
  AFTER the sample_file line, so the menu load (params:read fires actions in
  FILE order, no bang after; verified against norns source) snapped the window
  to the sample and then overwrote the snap back to the full buffer, and every
  scene sidecar's slot 1 did the same on RCL 1. Fix one, the runtime clamp:
  mscenes' clamp_stored() caps a STORED window edge (recall, safe restore,
  morph target) at C.take_len, the content high-water mark. Beyond it is
  silence by definition, so the clamp can only remove silence. Live values and
  the morph's exact-home restore stay verbatim (morph_from bypasses it), and
  the clamp stands down with no material or full material. Fix two, the data:
  every shipped pset and scene slot dropped the window pair entirely (the
  sample snap is now the only writer), and section 10 of the control harness
  FAILS if the pair ever returns. Both mutation-proven; the pset fix proven by
  replaying norns' reader loop (pos_end stays 0.0333, was 1.0).
* **Presets canonicalized and deepened.** presets/mangler-0N.pset now carries
  the FULL current paramset (the old set stopped at 108 ids, so the set the
  normal `mangler` deploy can actually load never staged the layer decks), a
  sixth preset (LAYERS BED) joins it, and slot 1 of every scene bank is a FULL
  capture over SCENE_RECALL_IDS (78 ids) instead of a 15-id partial, so RCL 1
  is a real way home. The layN_file params are pinned to the audio dir (empty)
  in every pset. Scene sidecars regenerated in the exact tab.save reference
  format (verified against norns tabutil). The harness now also validates the
  scene SIDECAR ids (they were never checked; apply() drops unknown ids
  silently).
* **Layers load files now.** lay1_file/lay2_file (params:add_file, grp_layers
  17 to 19) drive ctx.layer_load: off-rate files go through convert_sr first
  (per-deck temp so it cannot race the take's), Mdeck.load_file clears the
  region, reads stereo in one call or a MONO file into both sides, snaps the
  loop to the file length (Mpages.wav_info, the new header-only channel and
  duration probe) and repaints the strip. Mdeck.pset_read's no-wav branch now
  reloads a named file instead of clearing (the file action may not re-fire
  when the value is unchanged); an EMPTY file param still clears, the tape
  rule. The LAYERS erase forgets the file param like clear_recording forgets
  sample_file. Classified in SCENE_EXCLUDE and MOTION_EXCLUDE.
* **Stations reordered by FAMILY + the page-name pop.** PAGES is now TAKE
  VOICE EROSION · TAPE LAYERS · FILTER DELAY REVERB · MIX · PADS MOTION SCENE
  ORBIT (the last three used to sit appended at the tail in build order,
  history not a map). All dispatch is name-based so nothing else moved. E1
  arms ctx.page_flash (~0.7s) and mpages draws the destination's name BIG and
  centered in the footer-swell framed-box idiom; the render suite's goto_page
  runs the pop out so shots depict the settled page. LAYERS also grew the
  "SRC WET" flag (cut_source is ONE global softcut send, so the tape's source
  knob governs what the layers record; that must not be a hidden mode).
* **Grid fixes from review, both mutation-proven paths.** draw_layers_ws used
  a CONTAINMENT LED law while draw_main_ws uses OVERLAP, so a layer loop
  narrower than one eighth was entirely dark on its own row (@lay_move and
  MIDI park loops at arbitrary fractions; grid-set spans land on eighths,
  which is why it never showed). Now one law. And slice_key wrote start-then-
  end unconditionally, violating the widening-edge-first rule every other
  edge writer follows; a span right of the old one crossed the pair for one
  write and the 100ms floor turns a crossed pair into a head jump.
* **Dead code out** (all call-site-verified by the review agents, harness
  green): mmotion's clear_all export (0 callers since the NU redesign) and
  the write-only last_fire field; mpages' 8 stale SHORT keys, 18 stale FULL
  keys and 7 fmt_value arms stranded by the NU-1 banking deletion (none
  reachable: SHORT's live key set is ENC_MAP + VOICE_FACE + MOTION_IDS); the
  vacuous nb >= 1; erosion_tick/body_EROSION re-deriving the window law by
  hand (now window_bounds, the bound upvalue); layer_strip reaching text_w
  through C.font.
* TESTS: control 173 to 184 (section 12, the window clamp, driven through a
  real simulated take; the sidecar and no-window-pair checks; the narrow-loop
  LED), deck 46 to 55 (load_file stereo/mono/region, the pset file fallback).
  Mutations: neutering clamp_stored fails exactly its 2 assertions; the old
  containment LED law fails exactly its 1.
* VERIFIED: luac clean, 385 assertions across the five harnesses
  (184/55/62/41/43), all 66 shots source == dist across the 4 variants
  (base/empty/grain/filter), gallery regenerated (18 pngs, new page indices),
  the page pop and the SRC flag eyeballed via probe renders. READMEs updated
  (family table, resample workflow, layer loading, the stale "44.1k plays
  sharp" line, presets story). DEFERRED as user decisions, not built: page
  MERGES (fewer stations), E1 wrap-around, a one-key layer BOUNCE gesture,
  auto-WET while a layer records.

Seventy-fourth change: **eleven stations, the layer bounce, FX scenes, and the
tape on the deck mechanics (Lua + tooling, ENGINE UNTOUCHED, fingerprint STAYS
65, branch `layers`)**. The "do all these improvements" batch; everything
offline-provable was built, and the two engine wishes (spawn/free delay, true
STOP) stay parked — more untested SC on the ungated pile breaks invariant 3.
Save + reload; the RESTART for count 65 is unchanged and still pending.
* **PAGES 13 to 11 — two pages became surfaces on the pages they always
  belonged to, losing NO reach.** EROSION only ever worked in PLAY mode (the
  engine erodes in \mangler_play alone; its page said so in words). Its
  controls are now VOICE's PLAY-mode alt pair — which was a REDUNDANT copy of
  scan/pitch there, since the PLAY face already is scan/pitch — and VOICE K2
  is mode-contextual: HEAL (the erode+regen throw) in PLAY, FRZ elsewhere
  (pv_freeze is inert in PLAY). GRAIN/WARP/PV keep alt scan/pitch, so pitch
  stays encoder-reachable under every face. SCAR retired to the erode knob.
  The GEN counter, pass-progress line and fuzz now draw INSIDE the PLAY
  texture (two-pass fill so every pixel gets its own level; the erosion state
  moved ABOVE body_VOICE — a later local would silently read as a global, the
  65th change's lesson). ORBIT's knobs are SCENE's alt pair (drift + reach);
  scene_recall_mode moved to PARAMS-only (set-and-forget config lost its
  encoder to a performance knob, its readout stays on the page); orbit RUN =
  the param (footswitch), a new grid pad on the scene workspace row 6 x6, and
  a blinking ORBIT chip on the page; CAP during a wander already redirected
  to the first empty slot, so no key was needed. All page dispatch was
  name-based, so nothing else moved. Body-section header numbers renumbered.
* **The layer BOUNCE — resampling is one key.** New `layer_wet` toggle
  (default ON, grp_layers 19 to 20): while ON, arming ANY layer throws the
  softcut record source WET (the processed engine output) and disarming
  restores the knob. ONE writer (`ctx.update_cut_source`) resolves the
  effective source from `ctx.eff_cut_source()`; the cut_source action, the
  layN_rec actions (source settles BEFORE the head opens on arm; head closes
  before restore on disarm) and layer_wet all funnel through it. The TAPE and
  LAYERS "SRC WET" flags and the record-meter law (`cut_rec_amp`) all read
  the EFFECTIVE source, so the override is never hidden — including that the
  tape records wet too while a bounce runs (one global send, stated). OFF =
  the decks follow cut_source exactly as before.
* **FX-only scenes (Octatrack-style).** `scene_scope` option ALL/FX
  (grp_scene 10 to 11): CAP with FX stores only SPACE_IDS (filter, drive,
  delay, reverb, shimmer), so a slot becomes an effects preset that recalls
  and morphs OVER whatever material is playing. apply() always skipped
  missing ids, so partial slots were legal — this makes them a gesture. say()
  reports "SAVED n FX". Both new params classified (SCENE_EXCLUDE +
  MOTION_EXCLUDE).
* **The tape now runs on the DECK MECHANICS — proven, not hoped.** mdeck's
  p() honors a per-deck `keymap` (the tape's ids predate the layN_ scheme and
  ids are never renamed), update_rec grew the freeze hold (inert for decks
  without a freeze key) and a `pre_default` (tape 0 = REPLACE; `0 or 1` is 0,
  Lua truthiness). mtape's update_tape_rate/rec/loop and clear_buffer are now
  one-line delegations through a TAPE descriptor that is deliberately NOT
  registered in Mdeck.decks — its level law (the MIX crossfade), pset files,
  phase events and lifecycle stay mtape's own, and mtape receives the module
  via `Mtape.init(ctx, Mdeck)` because norns `include` has NO cache and a
  second instance would split the deck walks. EQUIVALENCE PROOF: the softcut
  call stream over a 146-line state matrix (4 rates x 2 directions, rec x
  freeze x pre, six loop shapes incl. crossed/degenerate/far-right, clear)
  captured before and after the fold, byte-diffed EMPTY. What remains
  deliberately un-folded: level/pset/phase/display — gated on the device
  pass, as the 64th change ruled.
* TESTS: control 185 to 192 (section 13 — the merges: alt reach in both
  modes, the contextual K2 punch, GRAIN keeps pitch, the grid orbit pad;
  section 14 — the bounce observed at the audio sends incl. the layer_wet=OFF
  opt-out, and FX scope proven behaviorally: recall restores the filter and
  does NOT touch scan). deck 55 to 66 (the tape's delegated mechanics:
  REPLACE default, freeze hold, the floor inside 0-60s, crossed sort,
  region-scoped clear). 404 assertions total (192/66/62/41/43).
* VERIFIED: luac clean, all five harnesses, 66 shots source == dist across
  the 4 variants, suite gained VOICE_ERODE + SCENE_ORBIT (rendered LAST in
  the scenario — the orbit rewrites params, nothing may render after it),
  gallery regenerated for 11 pages (erosion.png/orbit.png replaced by
  voice-erode.png/scene-orbit.png), both new surfaces eyeballed. README:
  11-station table, the bounce as the default resample story, orbit/erosion
  notes rewritten as surfaces, capture scope documented.

Seventy-fifth change: **the parked ENGINE work — spawn/free delay + S23 Batch B
true STOP + clear-is-silence (ENGINE + Lua, fingerprint STAYS 65 — verified by
parser: (ioKeys 15 U playParams 26 U revParams 14 U delayParams 3) = 54, + 11
explicit = 65; parens/braces/brackets balance 0 — UNTESTED, no sclang here,
rides the SAME pending RESTART; gate = doc/device-gate.md stage 10, added)**.
User-directed ("do the engine work"); written with the same static discipline
as the 48th-63rd engine batches.
* **The delay is now a spawn/free synth** (`\mangler_delay`, `updateDelay`),
  the split the 52nd change priced and parked. Mirrors the reverb exactly:
  io sends the post-drive wet on dlySendBus, reads the echo back via
  InFeedback on dlyRetBus (one block late; the REGENERATION loop lives inside
  the delay synth, so repeat spacing stays exact), and keeps the equal-power
  crossfade + lag in its own graph (the dub duck is the point; the reverb
  stays a send). io lost its LocalIn/LocalOut and DelayC entirely. delayParams
  = {delay_time, delay_fb, delay_mix} route like revParams; delay_mix stays in
  ioKeys TOO (the crossfade) and the union is unchanged → count 65. THE GATE
  IS NOT PLAIN mix>0: the synth also stays alive while `delay_fb > 0.9`
  (curved; ~0.87 on the knob) so the dub gesture — INF, then KILL, then
  un-KILL — gets its spinning loop back instead of losing it to the free. In
  the DEFAULT state (mix 0, fb ~0.48) the synth is gone: the CPU the delay
  cost at rest is reclaimed, same as the reverb split. `\mangler_delay`
  accepts an unused delay_mix arg so the generic per-key .set never names an
  unknown control. ACCEPTED TRADES, stated: raising mix from rest starts an
  EMPTY line (echoes of what plays from then on, not before); automating fb
  high->low at mix 0 frees the line mid-hold.
* **S23 B1, true STOP.** The engine half is ONE multiply in winRead: the read
  head's Phasor increment gains `(run > 0.001)` where run = the deck `level`
  (all five defs pass it — level was already fanned to playParams by the 61st
  change for the erosion/regen heads; this extends the SAME "silent deck =
  stopped deck" law to the READ head). Under STOP the drone head freezes and
  the play_phase poll stops sweeping; START resumes from the exact spot.
  STATED CONFLATION, same as the write heads: a MIX thrown fully to tape also
  lands level at exact 0, so a fully-thrown-away deck pauses rather than
  spinning unheard (gate row 10.7 asks for an ear verdict; the alternative is
  a new command). The Lua half: the stop_all action now re-sends the tape and
  layer rate/rec laws, which fold `(1 - stop_all)` in Mdeck.update_rate/
  update_rec (shared with the tape through the 74th change's fold — ONE edit
  covered all three decks); every head glides to 0 on the existing slew and
  they stop AS ONE, so the decks' relative drift survives a stop/start (MUTE
  alone still keeps heads moving). The engine record head pauses too:
  `engine.rec` is gated on stop in BOTH the rec action and the stop action
  (param stays armed; arming while stopped waits for START; the window
  bookkeeping still runs against the frozen head, so the arm position is
  exactly where START resumes).
* **S23 B2, clear is silence.** The engine `\clear` now frees + respawns both
  FX synths — their internal state IS the delay line and the reverb/shimmer
  recirculation, so the restart is the flush and nothing rings on with the
  erased material. `ctx.clear_recording` zeroes `regen` first (it would
  re-record the output — monitor + tails — straight into the freshly erased
  buffer). And a truth fix the STOP work exposed: `erosion_tick`'s GEN
  counter now pauses when the deck is silenced (`(C.mix_gains()) > 0.001`) —
  the engine's write head has gated on level since the 61st change, but the
  Lua counter kept counting through a STOP.
* TESTS: control 192 → 204 (section 15: STOP halts all six softcut voices,
  pauses the armed engine head, an arm-during-stop waits, START restores
  tape + layer rates and the head; the section-11 contract parser gained
  delayParams so delay_time/delay_fb still resolve as real commands). deck
  66 → 72 (the stop gate on a layer and, through the delegation, the tape).
  422 assertions total (204/72/62/41/43).
* VERIFIED: luac clean, .sc delimiters balanced, count 65 by parse, all five
  harnesses green, all 66 shots byte-identical to the pre-engine-work run AND
  source == dist across the 4 variants. engine-map.md rewritten for the delay
  split + the stopped-head law; spec §S23 Batch B marked BUILT (count note
  63 → 65); device-gate.md gained stage 10 (delay character, %CPU at rest,
  the dub hold, true STOP incl. the 10.7 ear verdict, clear kills tails).
  DEPLOY: ENGINE change — rsync, SYSTEM > RESTART, confirm `count: 65`, then
  stage 10 rides the same walkthrough as everything since the 48th batch.

Seventy-sixth change: **four performance psets (7-10) + the loop-restore fix
they exposed (Lua one-liner + preset DATA, ENGINE UNTOUCHED, fingerprint STAYS
65)**. Asked for "a pset that uses the two layers to the max" plus "3 psets
that ezbot would add" — the live dub-techno / resample-looping workflow.
* **THE FIX FIRST — designing the preset exposed it.** Mdeck.load_file always
  re-snapped the loop to the file, and the PSET restore path calls it — so a
  pset (or the performer's own saved session) with a CUSTOM layer loop lost it
  to a full-file re-snap on every load. load_file gained `keep_loop`;
  pset_read passes true (params:read already restored the authoritative loop
  points), the interactive path still snaps. test_deck 72 to 74, asserted on
  the reload path.
* **Preset 7 LAYER DRIFT** — the layers-to-the-max one, possible only since
  layN_file rides the pset: the 115 drums as the take, the music box loaded
  INTO L1, the 128 drone into L2 at 0.9x, three loop lengths drifting;
  scenes: layers alone (sc_level 0) · half drift · the box chopped to a
  ~1.2s stab. **8 DUB THROW**: the delay as the instrument (dotted-eighth at
  the material's 128, fb 0.55, dark DFM1 at 5.5k), empty decks staged as the
  looper bed for the wet bounce; scene 2 IS the throw (fb 0.85, mix 0.5,
  cutoff 2.5k) — recall it and morph home. **9 RESAMPLE RIG**: GRAIN mangle
  on the 97 break, print_len ~2 bars, decks waiting; scene 3 recalls CLEAN
  PLAY (mode is SWITCH, lands last) so the loop is mangle → arm a layer →
  clean → play over the bounce. **10 SLOW ORBIT**: the Am atmos at scan 0.5,
  erode 0.12, its own copy an octave lower in L2 (same file, rate 0.5 — the
  other atmos is Bbm and would clash), shimmer + 12s tail, orbit staged at
  rate 22 / reach 0.35 with mood poles in slots 2-4 (tap RUN to wander).
* GENERATION RULES, all enforced by the generator (scratchpad gen_presets):
  values driven through the LIVE paramset and read back (spec-valid by
  construction); momentaries asserted 0; mix pinned 0, dry_wet 1; NO window
  pair; loaded decks' loop pairs OMITTED (the snap owns them; the keep_loop
  fix is what lets a user's own saved loops survive instead); slot 1 = a full
  74-id capture DROPPING the window AND layer-loop pairs (a stored 0/1 would
  re-open a loop onto the silent rest of a region — the window trap's
  sibling); sample paths ONLY from the six device-proven library files, never
  guessed. Presets 1-6 regenerated too: they gained the layer_wet and
  scene_scope lines born after their last generation, and their slot 1s
  dropped the layer-loop pairs (78 to 74 ids).
* VERIFIED: preset 7 replayed through norns' reader loop end to end with a
  local wav standing in for the three library files — 123 lines apply, no
  action throws, the take window AND both layer loops end snapped (the
  pset_read reload keeps them). Harness section 10 now loops presets 1-10 in
  both sets (24 files incl. pmaps and 20 sidecars, ids + no-window-pair).
  424 assertions (204/74/62/41/43), renders byte-identical, source == dist.
  STATED: like every shipped preset, these have never been heard — balances
  are reasoned (tempo-matched delay times, the plateau law, the bounce
  default), not eared. Lua half: save + reload; the engine RESTART for count
  65 (75th change) is unchanged and still pending.

Seventy-seventh change: **the layers become a looper, and the sample path stops
throwing bits away (Lua + three ENGINE edits, fingerprint STAYS 65 by parse, 3 of
the 66 prior render shots changed on purpose, 473 assertions)**. Asked for "a snap
function for the layers" and "higher quality sound"; the engine was reported
running well but `count: 65` is still unconfirmed, so the .sc edits are small,
targeted and add no command.
* **A FRESH LAYER RECORDED INTO A 60-SECOND LOOP.** `lay*_start`/`end` default
  to 0/1, so the first thing you played on a layer came back once a minute. The
  tape has had the loop-pedal law since S3 (arm opens the loop, disarm snaps it
  around the pass and jumps the head to its start) and the layers, added later
  in the same shape, never picked it up. `Mdeck.arm_loop`/`close_loop` land it,
  gated on `d.any` so a deck that already holds audio overdubs into the loop it
  has instead. That distinction IS the looper: the first pass defines the length,
  every pass after it stacks. The erase calls `abort_loop` first so wiping a deck
  cannot snap a loop around material it is about to destroy.
* **SNAP puts the length on a grid.** A hand-played loop is never the length you
  meant, and two decks at 3.97s and 4.02s walk apart inside a minute. The
  reference is the OTHER deck if it holds audio, else the take's window, else a
  bar of the clock; the ratio is chosen in LOG space (a linear nearest pulls
  everything upward); only the loop END moves, so it stays undoable by hand like
  TIGHTEN. Closing a record pass offers the loop to the same code with a **6%
  tolerance**, so a near miss rounds hands-free and a length you clearly chose is
  left exactly as played. `lay*_snap` are MOMENTARY params (footswitch, grid row
  6 pads 4/5, PARAMS) because both LAYERS key slots are taken and **K1+K2/K1+K3
  are global with zero page claims** (NU-1's law) - the `pad_chop` precedent.
* The page prints the selected deck's **loop length in seconds** beside its rate,
  and a snap says what it did over that row for ~1.2s. Needed because a snap that
  finds the loop already on the grid moves NOTHING on screen, which is the 36th
  change's lesson exactly. Chip measured at 111px worst case against the 124px
  limit (`L2 00.00>00.00S 2/3 x TAKE`, brute-forced over every ratio label,
  reference and two-digit second); the pocket takes the WHOLE row (a pocket cut only behind the words left
  the seconds and the rate peeking out either side, which read as garbage). NB
  `ptext`'s y is the TOP row, not a baseline: the 1x font occupies y..y+4, so a
  pocket for text at y=12 is rows 11..17.
* **`lay*_fade`** (the loop seam, was hardcoded 20ms) and **`lay*_width`** (0
  collapses a deck to the centre) are now per-deck controls, moved out of
  `M.start` into `update_all`. grp_layers 20 -> 26.
* **THE SAMPLE PATH WAS 16-BIT END TO END, and one link actually lost data**:
  `convert_sr` wrote 16-bit, so an off-rate 24-bit sample was truncated before it
  ever reached the buffer. Now `convert_sr` writes 24, `write_take` is `int24`
  (the buffer is 32-bit float; every pset round trip re-quantised the take), and
  `interleave_wav` reads the depth from the header and splices whatever it finds
  instead of demanding 16. An on-rate file was always fine (readChannel takes any
  depth) - this is specifically the import/persist/export chain.
* **The resampler is a windowed sinc, not Catmull-Rom cubic.** Cubic has no
  stopband, so a 96k or 88.2k file folded everything above 24 kHz straight into
  the audible band. 16 taps at unity cutoff (widening as 1/cutoff when
  downsampling), 512 phases, Blackman, each phase normalised to unity DC gain (an
  unnormalised kernel gains differently per phase, which is a whine at the phase
  rate, not a rounding error). Asserted by VALUE: a 30 kHz tone at 96k converts
  down to rms 0.0052; real cubic on the same file leaves it at 0.4834. MEASURED
  attenuation across the band, as the level an alias returns at: 26k -13 dB,
  30k -40 dB, 36k -75 dB, 40k -85 dB, against cubic's -0.2 dB everywhere. So the
  deep stopband starts around 1.5x the cutoff and the transition above it is
  wide; what leaks lands at 22 kHz and up. Cost MEASURED per SOURCE RATE, because
  the kernel widens as 1/cutoff and so DOWNsampling is the expensive direction:
  10s of stereo on a dev Mac is 44.1k 0.68s (1.9x cubic), 88.2k 1.17s (2.3x),
  96k 1.25s (2.5x), 192k 2.34s (3.2x). A Pi will take tens of seconds for a long
  file, and longer coming down than going up. Imports already yield, and the device library is
  pre-converted, so this is the off-rate path only.
* **ENGINE, three edits, no new command:** (a) the record and regen arms now tap
  the mix **before the master Limiter**. A limiter that looks ahead delays its
  output by the lookahead, so blending it with the undelayed input at any middle
  `resample` summed a signal with a 10ms copy of itself and printed that comb
  into the take permanently. This is the "resample-blend comb" the 50th change
  parked as needing an on-device delay measurement: the delay is the Limiter's
  own constant, so there was nothing to measure. The record-safety Limiter at
  0.99 still bounds the buffer, so regen stays as convex as it was. (b) + (c)
  `softclip` -> `tanh` in the delay feedback and the shimmer loop: softclip has a
  derivative kink at its knee and a loop applies it every pass, so breakup builds
  up harsh. Stated trade: tanh leans in earlier, so a slammed repeat warms rather
  than fraying, and a hold may sit lower than it used to.
* **NOT done, and why:** anti-aliasing the `drive` stage. It needs oversampling,
  which stock SC cannot do inside a graph, and the band-split alternative
  (saturate below a crossover, pass the top clean) sums an LR4 allpass against
  the clean arm in the middle of the drive knob - a near-total cancellation at
  the crossover. Making the clean arm allpassed too fixes the comb but ends the
  bit-true bypass at drive 0 and runs four filters always. Not worth it for a
  knob that defaults to 0.
* TESTS: control 204 -> 220, deck 74 -> 93, wav 62 -> 76 (473 total). Nine
  mutations, each failing exactly its assertions: the kernel cutoff pinned to 1;
  `arm_loop` without the `d.any` test; `close_loop` without the head jump; the
  take outranking the other deck as reference; the ratio compared in linear
  space; the automatic pass without its tolerance; SNAP moving the start instead
  of the end; a degenerate deck offered as a reference; a fabricated loop
  instead of a refusal. The decline case needed an EMPTY deck twice, so the
  harness drives the real K1+K3 erase between them.

DESIGN-REVIEW PASS on the same change (five fixes, two of them real defects,
both PROVEN reachable by probe before being fixed and mutation-proven after):
* **SNAP was a silent no-op when the other deck's loop was collapsed.**
  `loop_secs` floors at softcut's 100ms, so a deck with its edges together
  returned exactly 0.1 and satisfied the `ref <= 0.1` guard, which returned
  without moving anything and without printing. The 36th change's whole lesson.
  Fixed at the SOURCE, not the symptom: `snap_reference` now skips a degenerate
  deck, so the invalid reference is never offered rather than coped with.
* **SNAP fabricated a result and named a grid it was not on.** With the loop
  parked at the region end, the halve-until-it-fits loop plus a `max(len, 0.1)`
  floor produced a 100ms loop, and the message reported `already 1/8 x BAR
  (0.100s)` when 1/8 x BAR is 0.25s. It now REFUSES out loud (`NO ROOM TO
  SNAP`, with the maiden line naming the room left and what to do), and every
  other report reads the landed length back out of the params rather than
  reporting what it asked for.
* **"snap" meant two things one screen apart.** This codebase has used it for
  "fit the bounds to the material" for fifteen occurrences (`snap_window`,
  `snap_mem`, "loop snapped"), so the loop-pedal trio was the one to move:
  `arm_snap`/`close_snap`/`abort_snap` -> `arm_loop`/`close_loop`/`abort_loop`.
  Pure rename, docs repointed. That fixed the CODE collision only; the
  user-facing one is still live and is now stated rather than hidden (see the
  second review pass).
* **The message mechanism was a second implementation of mscenes' `say`.**
  Different state shape (deadline vs timestamp), different liveness expression,
  different picture. The state shape and liveness now MATCH mscenes so a shared
  `ctx.say` is a mechanical extraction later; the PICTURE stays separate on
  purpose, with the reason written where the next reviewer will ask (`chip()` is
  right for "SAVED 2" and a 111px glare for a sentence). The extraction itself
  is recorded, not applied: it touches mscenes and body_SCENE, outside this
  feature.
* `snap_reference` and `layer_say` were on `ctx` with one caller each, defined
  in the same file twenty lines away. Now file-locals; `layer_snap` and
  `layer_quantize` stay on ctx because mdeck and the param actions reach them.
* Three claims I wrote were untrue and are corrected against measurements
  (above): the "-74 dB stopband, under the 24-bit floor" comment (-74 dB is
  nowhere near a -144 dB floor, and 16 taps only reach it at 1.5x the cutoff),
  the gate's "a minute of audio takes a few seconds", and a test comment citing
  a cubic number that had never been run with cubic. `doc/layers.md` still
  called LAYERS "page 13"; it is page 4 since the family regrouping.
* NOT fixed, recorded as decisions: `lay*_width` has no on-screen tell (a
  collapsed deck looks identical to a wide one) - `pan` has the same gap, so
  this matches the sibling rather than breaking the audibility rule; and
  mpages.lua holds the drawing AND the whole wav layer, a real "and" in one
  file, but moving it costs a new module plus the harness lift machinery that
  three tools point at.
* RENDERS: the SNAP block adds 22 ticks to the scenario, which shifts every
  downstream shot's animation phase. Padding HEAD's scenario with the same 22
  ticks collapses all of it: exactly the **3 LAYERS shots** differ (the loop-
  seconds readout replacing the decorative deck count) plus the new LAYERS_SNAP.
  67 shots, source == dist, layers.png regenerated.
* STYLE: the global no-dash rule was applied to every line this change adds,
  including the code comments. The surrounding files are full of em dashes from
  earlier sessions; new text does not add more.
* DEPLOY: **ENGINE change - rsync, SYSTEM > RESTART, confirm `count: 65`**, then
  `doc/device-gate.md` **stage 11** (added) rides the same walkthrough as
  everything since the 48th batch.

SECOND DESIGN-REVIEW PASS on the same change (no behaviour changed; three
measured claims were wrong and are corrected against re-runs, two duplicates
retired, one duplicate named instead of retired).
* **The tape's loop-pedal law is a SECOND implementation and is now named as
  one.** mdeck grew `arm_loop`/`close_loop` for the layers; the tape has run
  the same law inline in the `tape_rec` action since S3, on a deck that already
  delegates rate, rec, loop, clear and jump to that module. They have already
  drifted: the tape gates on `tape_pre == 0` where mdeck gates on `d.any`, its
  minimum pass is 0.005 normalized (300ms of 60s) where mdeck's is 100ms, and
  it has no quantize hook. NOT folded, on the 74th change's own rule: this is
  one of the few paths confirmed on hardware, folding it also means making
  `TAPE.phase` live (a display stub today), and rewriting a proven path before
  the device gate is the wrong order. The reason and the three differences are
  written in lib/mtape.lua beside the delegation list, and mangler.lua's copy
  points back at it. Change one, change both.
* **The import budget quoted the path this change is NOT for.** "1.9x cubic"
  is 44.1k -> 48k, where the kernel is 16 taps at unity cutoff. `half` widens
  as 1/cutoff, so DOWNsampling costs more, and downsampling is the entire
  reason the sinc replaced the cubic. Re-measured (10s stereo, dev Mac): 44.1k
  1.91x / 0.68s, 88.2k 2.28x / 1.17s, 96k 2.49x / 1.25s, 192k 3.19x / 2.34s.
  Gate row 11.12 and the mpages comment now carry the table, and 11.12 asks for
  a 96k file specifically, because 11.11 already does.
* **Two more numbers re-run rather than trusted.** The chip is 111px worst
  case, not 105 (`L2 00.00>00.00S 2/3 x TAKE`, brute-forced over every ratio
  label, reference and two-digit second; still inside the 124px limit, so
  nothing clipped). And the headline said "all 66 prior render shots
  byte-identical" while this entry's own review-pass bullet said 3 differ: the
  bullet was right, 3 changed on purpose.
* **`doc/engine-map.md` still described the softclip this change removed** from
  the delay feedback loop, two paragraphs from the lines this change edited.
  It is the plain-words map of every engine decision, so it has to follow the
  engine. (`doc/spec.md` names softclip twice more, at S15's gate criterion and
  in the S23 planning text; both are per-stage HISTORY superseded by
  doc/device-gate.md, so they are left as the record of what was decided then.)
* **SNAP names two gestures and both are user-facing.** The first review pass
  renamed the internals and recorded that "the user-facing SNAP key is the
  quantize". That is backwards: TAKE K3's on-screen word is SNAP and it is
  `snap_window`, fit the window to the material; the loop quantize has no key
  at all, by design. The code collision is gone and the product one is not, so
  README and doc/layers.md now say so where each gesture is introduced. A
  rename of the new one is a product call, not a review fix.
* **`body_LAYERS` hand-rolled `ptext_c`** four lines below its own call to it,
  and dropped the helper's `+ 0.5` rounding on the way. One line now.
* **Two dead `SHORT` keys**, `lay1_fade`/`lay2_fade`. SHORT is read only for
  the current page's encoder ids and MOTION lane names; these are neither, and
  their three siblings on the same MOTION_EXCLUDE line (`tape_fade`,
  `warp_overlaps`, `grain_shape`) carry no SHORT entry either. The 73rd change
  deleted 8 stale SHORT keys for exactly this; two grew back in one change.
* `layer_snap`'s `if ref <= 0.1 or cur <= 0 then return end` was unreachable
  once the first review pass moved the check into `snap_reference` (which now
  skips a degenerate deck), and it was a SILENT return, the one shape that
  bullet had just eliminated. Deleted; `snap_reference`'s header carries the
  guarantee instead. `d.arm_phase` is now named in `M.new`'s shape comment (a
  `= nil` field would create no key). A draft comment left standing above its
  own rewrite in test_control.lua is gone.
* NOT changed, deliberately: `layer_snap` and `close_loop` both jump the head
  after a quantized close. It reads as redundant but neither is: SNAP fired
  from a footswitch must move the head itself, and `close_loop` must move it
  when the tolerance DECLINES the quantize and `layer_snap` returns early.
* VERIFIED after the pass: 473 assertions across the five harnesses, `luac -p`
  clean on every file, engine delimiters balanced, **command count still 65 by
  parse**, 67 shots source == dist across the 4 variants, dist a faithful
  `amalgamate.lua` rebuild, gallery current.

WORKFLOW CODE REVIEW on the same change (22 agents, 24 verified findings, 14
distinct). Eight defects fixed, all eight mutation-proven, all eight invisible
to the harnesses as they stood. The cluster is the new loop-pedal law meeting
states no forward-pass test reaches.
* **THE EXPORT GUARD WAS STILL SIZED FOR THE OLD 16-BIT TAKE.** `write_take`
  moved to `int24` in this change; `ctx.take_to_wav` kept computing
  `exp = take_frames() * 2 + 44` and waiting for both temp files to REACH that
  size. The guard therefore passed at ~two thirds of the file, and its own
  comment says why it exists ("a slow SD card could stall mid-write and read as
  stable at a partial size, which would hand back a truncated take"): the
  change defeated the exact protection it was written for. Export, CHOP and
  TIGHTEN all share that path, so all three could act on a part-written take,
  and the `cap` backstop was a third too short as well. The width is now
  **`ctx.TAKE_BYTES`**, named beside `ctx.BUF_SECS`, the .sc says to change
  them together, and test_control section 18 parses the format out of the .sc
  and asserts the two agree. LESSON: a format change is a change to everyone
  who computes a SIZE from it, not only to the readers.
* **`arm_loop` destroyed a loop it could not put back.** It opens an empty
  deck's loop to the whole region, and `close_loop` declined a short pass by
  returning, leaving the deck on 60 seconds. A mis-tapped REC is a few frames
  under the punch law, so a hand-set loop on an empty deck was one fumble from
  gone. The arm now remembers the loop it opens and the decline restores it.
* **The law only ever understood a FORWARD pass.** `lay*_reverse` is reachable
  from PARAMS, MIDI and a scene recall (it is in the SWITCH list), and a
  reversed deck records DOWNWARDS: `b - a` is negative, so a reverse pass was
  declined and left on the region, and a reverse pass that WRAPPED produced a
  tidy-looking span the deck had never recorded. `close_loop` now reads the
  deck's own direction and orders the pass by it.
* **A PSET saved with a deck armed opened a phantom pass.** `lay*_rec` rides
  the pset like everything else and `params:read` fires it before it reaches
  the loop points, so `arm_loop` ran on a deck that still read as empty and
  left a mark over the session's own restored loop; the next disarm re-cut it.
  `Mdeck.pset_read` (which runs in `action_read`, after every value is in)
  now drops any open pass.
* **SNAP anchored on the raw `start` param.** Every other consumer of the pair
  sorts it, so a CROSSED loop (reachable by MIDI, PARAMS or a scene) was
  RELOCATED to a different span of the region while the message said it had
  not moved. It takes the low edge now.
* **SNAP re-cued the head even when it moved nothing**, which restarts the
  phrase mid-performance under a message saying nothing changed, and throws
  away the phase alignment two decks only hold while both heads keep running.
  The jump is now on the branch that moved something. Pinned in BOTH
  directions, because "never jump" passes a one-sided test.
* **A deck mid-record was offered to SNAP as a reference.** `arm_loop` holds an
  open deck's loop at the full region and `any` goes true on the first sound,
  so arming both layers and disarming one quantized it to an eighth of a
  region boundary, hands-free. Skipped by the open pass now.
* **The loop pair could be written crossed.** `Mdeck.set_loop` picks whichever
  order keeps the intermediate state ordered (with both pairs ordered there is
  always one), and `arm_loop`, `close_loop` and SNAP all go through it. The
  100ms floor in `update_loop` turns a crossed pair into a head jump.
* **The seam could be longer than the loop.** `lay*_fade` reaches 0.5s, the
  loop floor is 0.1s, and it is in the scene TIMBRE list, so a recall could
  park a voice permanently inside its own crossfade: silent, while the page
  drew it bright. `update_fade` caps at a quarter of the loop, and
  `update_loop` re-caps because the loop moved.
* **The tanh swap costs the INF hold more than the comment claimed.** softclip
  is EXACTLY unity below 0.5; tanh is not. Measured: at a repeat level of 0.5
  the loop gain at `delay_fb` 0.98 goes from -0.18 dB per pass to -0.86 dB, so
  a hold that used to sit still falls about 10 dB over a dozen repeats (quiet
  repeats are unaffected, unity to within 0.03 dB at 0.1). NOT reverted: the
  user asked for this and gate row 11.14 already asks the device to judge it.
  The engine comment now carries the numbers and names the line to put back.
* **The TAPE's copy of the law shrank its loop on every overdub** (user call:
  fixed rather than deferred). Its ARM branch always knew overdub must not
  re-open the loop; its DISARM branch snapped regardless, so each stacked pass
  re-cut the loop to whatever slice elapsed and a pass that wrapped blew it out
  to the whole 60s tape, with the stacked audio still in the buffer. Proven by
  reverting: `[0.10, 0.30]` becomes `[0.15, 0.22]` on the first overdub, then
  `[0, 1]`. Pre-existing, NOT introduced here. `tape_arm_phase` is now nil
  unless the arm actually opened a pass, and the disarm branches are guarded on
  it, which is the same line `Mdeck.arm_loop` draws with `d.any`. The tape also
  writes its edges through the shared `D.set_loop` now. STILL divergent, and
  the mtape note says so: the tape's minimum pass is 0.005 of the tape where
  mdeck uses 100ms of the region, mdeck reads the deck's DIRECTION and the tape
  does not, and only mdeck offers the closed loop to the quantizer.
* COMMENT PASS afterwards, on request: every comment this change adds was
  rewritten in plain words. Out went the house shorthand a newcomer cannot
  decode ("the punch law", "a crossed pair", "convex", "degenerate", "the alt
  pair is global", a device-gate row number) and the DSP vocabulary the
  resampler leaned on ("stopband", "images", "unity DC gain", "aliasing"),
  each replaced by what actually happens: a tap lasts a few frames, the start
  ends up past the end, the two record levels add up to one, a tone comes back
  mirrored into the audible range. Substance kept, including every measured
  number. Comments only, so nothing was re-verified beyond the parse, the
  harnesses and the renders.
* VERIFIED after the pass: **510 assertions** (241/109/76/41/43), `luac -p`
  clean, delimiters balanced, **count still 65 by parse**, all 67 shots
  byte-identical to before the fixes AND source == dist, gallery current. Every
  fix above is mutation-proven, including the tape one against a faithful
  reconstruction of the pre-fix action rather than a hand-broken line.

Seventy-eighth change: **the full review (Lua + tooling + docs, ENGINE UNTOUCHED,
fingerprint STAYS 65, 571 assertions, one render shot moved on purpose)**. A
five-agent, line-by-line review of the whole codebase found 76 issues; every
one was checked against the code before anything changed. Every Lua bug is
fixed and mutation-proven (25 mutants, each fails its own assertion), and so
are most cleanup findings; three cleanups stay open in doc/plan.md Phase 4. The engine findings are written up in doc/plan.md for the
device session, not applied: invariant 3.
* **A background conversion could eat a live take.** `load_sample` and
  `layer_load` started an async sample-rate conversion that landed on the
  buffer whenever it finished: over a phrase recorded meanwhile, a CLR, a
  PSET restore, or a newer load. Both now go through ONE `load_at_rate`
  helper with a generation counter (`take_gen` for the take, `d.gen` per
  deck); a conversion that finishes after its target moved is dropped and
  says so. The busy path also loaded the file twice; it loads once now.
* **The first take of every session counted as 60 seconds.** `params:bang()`
  fires the rec action with 0, and the rec-stop bookkeeping raised
  `take_len` to the whole buffer before anything was recorded, which turned
  off the scene window clamp, TAKE SNAP and the bounded PSET write. The
  bookkeeping now runs only for a pass that was really opened (`rec_open`).
* **Sibling gaps closed**: LAYERS K2/K3 resolve their deck at the press
  (`LAYER_KEYS`), so turning E2 mid-punch no longer strands a recording; the
  tape forgets an open pass on PSET load and gives back the loop a declined
  pass widened (both already true of the layers); `tape_fade` goes through
  the capped deck seam; the TAKE erase disarms REC first like TAPE and
  LAYERS; the pad steal mirror re-queues a re-struck note as the engine does.
* **Scenes**: ONE `land()` for every landing (a queued recall, ◄, chaos
  release and footswitch recalls all zero the morph amount and end a chaos
  hold); CAP and CLR reset only the morph, so a latched throw survives a
  capture; a re-aimed sweep brings displaced params home; the SCENE erase and
  the RCL tap act on the slot under the finger, and an unaddressed clear
  refuses while the orbit runs; an idle orbit no longer pins the morph knob;
  stored LAYER and TAPE loops clamp to the deck's material extent when they
  are more than twice it; ◄ edge cases in `next()` and `unlanded()`. The
  morph no longer allocates per call (0.506 KB/tick to 0.102 with the orbit
  running; the rest is the per-leg snapshot).
* **Motion**: replay writes region pairs through the shared pair writer (a
  slide right crossed the pair every pass); depth blends in warped space;
  clearing the last lane empties all its timing; the lane selector reaches
  every lane.
* **The screen tells the truth under STOP**: the painters stop with the
  heads, so an arm under STOP no longer marks an empty buffer as a take; the
  TAPE reels and the VOICE texture still; the grid's playheads dim when their
  deck is not audible. `paint_bins` paints only the landing bin on a jump
  (a loop wrap painted the whole loop). The grid, MIDI CCs and SPACE count as
  presence for the idle dim.
* **The wav layer**: an extensible header now resolves to its real format (a
  float render from ffmpeg decoded as int32 noise); the preview stride is odd
  over stereo (a right-only file drew empty); `convert_sr` yields every block;
  CHOP decodes only the frames it reads; the export interleaves as integers.
* **Organization**: the wav layer moved out of mpages into **lib/mwav.lua**
  (9 modules; amalgamate asserts 9); `Mdeck.set_pair` is THE start/end
  writer (move_pair, the grid spans, the loop law and motion replay);
  `buffer_replaced()` is the one "new material" rule; `scan_take()` serves
  TIGHTEN and CHOP; `add_momentary`, `add_eng_option`, `unit`, `fine_unit`
  collapse the param boilerplate (the built paramset is proven identical by
  dump); the PSET hooks walk one `PSET_PARTS` list with each part pcalled;
  `wave_lane`, `vu`, `framed2x`, `src_flag`, `dotted_box`, `cell_brackets`
  replace copied draw code (the ◄ cell bracket had drifted onto its own edge;
  that is the one render that moved). Removed: `param_norm`, `M.wav_rate`,
  20 FULL labels identical to SHORT, `Mdeck.cleanup` (norns resets softcut
  after cleanup), `Mmotion.cleanup`, the morph/recall `opts`, three ctx
  aliases, unread exports.
* **Tooling**: `tools/harness.lua` holds ok/near/report/pages for all five
  harnesses; test_wav loads the real modules instead of regex-lifting them;
  env.lua records `add_group` so test_control checks every group count;
  test_control also asserts the command count is 65, `bufSecs` matches
  `BUF_SECS`, every shipped preset value is in range with momentaries at 0,
  and dist is a fresh build. The grid note-off test asserts the voice closes.
* **Docs**: this file split from CLAUDE.md; the device gate fixed for eleven
  pages with a stage 12 for this batch; stale counts and page lists fixed in
  README, engine-map, layers, redesign and spec; doc/plan.md is the plan.
* VERIFIED: `luac -p` clean (5.5 locally; no 5.4-only syntax added), 571
  assertions (296/109/82/41/43), all 67 shots byte-identical to before except
  base_11_SCENE_BACK (the bracket, 10 pixels), source == dist. Lua-only:
  save and reload. The engine RESTART for count 65 is unchanged and pending.

DESIGN-REVIEW PASS on the same change (no behaviour changed except one timing
fix; 573 assertions).
* **The material extent was computed in two places.** `ctx.material` read
  only deck fields, and the TAPE's extent was tracked in mpages' tape painter
  from the 15 fps redraw clock. The 50ms pad covered the decks' 25ms phase
  events but not the tape's up-to-92ms staleness (computed from the two update
  rates, not measured), so a recall could trim the end of tape material. Now
  `Mdeck.track_extent` and `Mdeck.extent` serve both, and the tape grows its
  extent from its own phase events in mtape (`Mtape.deck` exposes the
  descriptor for reads). A tape test joins section 20.
* **One definition each** for things written twice: `ctx.warped_lerp` (the
  morph and the motion depth both interpolate in warped space; they had
  already drifted on clamping), `mscenes.PARTNER` (motion replay rebuilt the
  same both-way pair map), `ctx.deck_p` in the ten places mpages and
  `eff_cut_source` still built deck ids by hand, `T.goto_page` and
  `T.write_wav` in tools/harness.lua (three page helpers and nine hand-written
  wav headers removed).
* `mwav.init(ctx)` like every sibling module (it had its own signature and a
  second `clamp`); `buffer_cleared()` instead of a boolean flag; renames
  `pad_order_remove`, `slot_brackets`; a dead `C.set_pair` guard removed; the
  typing keyboard's octave keys count as presence; CLAUDE.md invariant 4 now
  describes `key_state` instead of the retired `held[]` gestures.
* The overclaim corrected: the plan and this entry said every Lua and tooling
  finding was fixed. Three cleanups are open (mscenes' own pair loops, the
  VOICE encoder table, the seam re-send).
* VERIFIED: luac clean, 573 assertions (298/109/82/41/43), all renders
  byte-identical to the previous pass, source == dist.


Seventy-ninth change: **the additions after the review (Lua + tooling + docs,
ENGINE UNTOUCHED, fingerprint STAYS 65, on branch `full-review`)**. The Lua
items from the plan's Phase 5, each with a test.
* **Live safety**: the per-frame jobs run under `pcall` (an error is printed
  at most every 5 seconds and the frames go on); while `delay_sync` is on the
  clock owns `delay_time` (any other write is put back next frame, with a
  0.5% tolerance for MIDI clock jitter); background jobs QUEUE instead of
  refusing, so a PSET with an off-rate take and an off-rate layer converts
  both.
* **Scenes and motion**: GLIDE is a fourth `scene_recall_mode` (the morph
  sweeps to the scene over `scene_glide` beats, then the scene lands; a hand
  on the morph or the selector stops it); a running orbit stands still while
  anything else moves the morph and resumes two seconds later; the motion
  loop saves beside the PSET (motion-N.lua) and comes back playing, while a
  saved arm does not start a recording; a first motion pass within 6% of a
  musical length loops on it (`ctx.clock_length`, sharing `nearest_ratio`
  with the layers' SNAP).
* **Material**: deck and tape PSET saves stop at the end of their material
  (`Mdeck.save_secs`) and a restore clears the region before reading;
  stopping regen or erosion dumps the take and repaints its strip, dropped if
  the take changed meanwhile; 8-bit WAV decodes, and a frame wider than its
  stated depth reads the container.
* **Grid**: in pad mode the piano lights the keys whose pad sounds; a Mini MK3
  plugged in after load takes over (`midi.add`/`midi.remove`, restored in
  cleanup), its arrows step the page (`ctx.step_page`, shared with E1) and
  the scene slot, and unplugging brings the fallback grid back.
* **Tooling**: a per-page screen-call budget (2500 a frame under a loaded
  state; MOTION draws about 2100 at the lane cap); `tools/controls.lua`
  generates doc/controls.md from the script's own tables and test_control
  fails on a stale one; `tools/check.lua` runs every offline check with one
  verdict, on Lua 5.3 when `LUA53` points at one. Built lua-5.3.6 from
  lua.org: the code parses and all five harnesses pass on 5.3. Renders match
  across 5.3 and 5.5 except SCENE_ORBIT, because `math.random` differs.
* RENDERS: only base_10_MOTION_PLAY changed (its 1.40s pass now loops at
  1.33s, two thirds of a bar at 120). Device rows: doc/device-gate.md stage 13.
* VERIFIED: 611 assertions (330/112/85/41/43), every new behaviour
  mutation-checked, `tools/check.lua` green on Lua 5.3.


Eightieth change: **erosion in its own synth (ENGINE, no new command,
fingerprint STAYS 65, on branch `full-review`)**. Built ahead of the device
gate because the user asked for it. It is the only engine change since the
review.
* **Engine**: the erosion head left `\mangler_play` for a new
  `\mangler_erode` synth. `updateErode` spawns it while `erode` is above 0 in
  PLAY mode and releases it otherwise. The erode command and every `setMode`
  call it. At rest nothing writes the take. Before, the PLAY voice wrote every
  sample back onto itself even at `erode` 0.
* The write fades in and out over 50 ms through an `asr` gate that frees the
  synth. The head holds its place while rec, freeze or a silenced deck pause
  it, so every part of the window ages at the same rate. Before, it kept
  moving and skipped what passed under it.
* `eroKeys` routes seven playParams to the live synth. `winBounds` (the
  window's sorted, smoothed edges) is shared by `winRead` and the new synth,
  so the window law still exists once. The drone defs keep their unused
  `erode` and `wear` args, so the command set and the count do not move.
* **Lua**: the VOICE pass counter starts a new pass when erosion engages,
  because the respawned head starts at the start of the window.
* **Tests**: test_control section 23. Only `\mangler_erode` holds a `BufWr`.
  `setMode` and the erode command call `updateErode`. The head is released,
  not cut. The pass counter advances, holds under freeze, and restarts on a
  new engagement. Three mutations (the old engine, no `updateErode` call in
  `setMode`, no pass restart) each make it fail.
* **SC syntax**: there is no compiler here. The new file passed a bracket
  count and was parsed with the tree-sitter SuperCollider grammar against the
  old file. Every new line the grammar rejects uses a construct it also
  rejects in the old, device-proven file (`and:`, `#a, b =`, indexing). A
  broken copy was caught: the parse found a missing semicolon and the bracket
  count found an unclosed bracket.
* RENDERS: all 67 byte-identical. Device rows: doc/device-gate.md stage 14.
  Rows 4.15 and 4.17 now point at the new synth.
* VERIFIED: 619 assertions (338/112/85/41/43), `tools/check.lua` green on
  Lua 5.3.


Eighty-first change: **the fixes from the code review of `full-review` (Lua +
tooling, ENGINE UNTOUCHED, fingerprint STAYS 65, on branch `full-review`)**. A
multi-agent review of the branch against `main` confirmed ten bugs. Each fix
has a test that failed before it.
* **The take dump**: `take_to_wav` holds its guard until `done` returns, under
  `pcall`. TIGHTEN, CHOP and REPAINT share one temp file, and a dump started
  during a scan truncated the file under it. CHOP then cut from silence,
  and its `os.remove` deleted the other job's output.
* **The strip repaint**: polled each frame (`tick_take_strip`) instead of run
  from the knobs. It waits for a second of quiet. It follows erosion only in
  PLAY, the only mode where the head runs, so a switch out of PLAY also
  counts as a stop. The repaint is a background dump. A performer's CHOP,
  TIGHTEN or EXPORT that arrives during it waits in one slot. Before, it was
  refused. A repaint that falls due during a performer's dump waits for that
  dump. Before, every HEAL tap dumped up to 17 MB and refused CHOP, TIGHTEN
  and EXPORT for seconds.
* **Conversions**: a queued conversion whose target moved on stops before it
  starts, and a running one stops at the next block. If its yield returns
  false, `Mwav.convert_sr` cancels and removes the part-written file.
* **Decks**: a PSET that reloads a deck's file through `layer_load` clears the
  deck first. The deck no longer plays the previous session's audio while the
  file converts, and an arm in that window opens a fresh loop.
* **Grid**: norns calls `midi.remove` before it deletes the device (read in
  the norns source), so the hot-plug search skips the removed device
  (`lp_find_device(gone)`). Every connect sets `have_midigrid` from
  `M.midigrid_loaded`, so a Mini MK3 that leaves gives midigrid back its note
  filter.
* **Scenes**: at its start, a GLIDE recall ends a held chaos throw, as every
  other landing does. Under GLIDE the RCL and scene-pad peek ramp waits until
  the press is a hold, so a tap glides instead of jumping. The orbit counts a
  held peek and its sweep home as a hand on the morph. It no longer drops the
  origin that the peek returns to.
* **Tooling**: `tools/check.lua` builds the single file to a temp file and
  compares it with dist. It used to rebuild dist in place, so a stale dist
  always passed.
* RENDERS: all 67 byte-identical. Device rows: doc/device-gate.md stage 15.
* VERIFIED: 652 assertions (365/116/87/41/43). Fourteen mutations, each
  removing one part of a fix, each fail a test. `tools/check.lua` green on
  Lua 5.3.

Eighty-second change: **the fixes from the second code review of `full-review`
(Lua + tooling, ENGINE UNTOUCHED, fingerprint STAYS 65, on branch
`full-review`)**. A second multi-agent review found two bugs and eight
cleanups. Nine are done. Each behaviour fix has a test that failed before it.
* **Grid**: on a Launchpad unplug, the connect now waits for the next grid
  frame (`Mgrid.reconnect_due`). norns deletes the device only after
  `midi.remove` returns, and midigrid's own search found the leaving
  Launchpad and bound to it. The leaving Launchpad is dropped at once, so
  nothing draws to it meanwhile. `have_midigrid` is gone: the note filter
  reads `midigrid_loaded`, which said the same thing.
* **The strip repaint**: the `regen` and `erode` actions mark the strip as
  written (`strip_wrote`). A burst that started and ended between two frames
  (a CC flick, a motion lane) wrote the buffer, but the frame poll never saw
  it. `Mpages.eroding()` is now the one rule for "the erosion head runs".
* **Scenes**: the peek ramp waits out the tap window in every recall mode,
  not only under GLIDE. A BEAT or BAR tap raised the morph before the recall
  was due. `Mscenes.recall_glides` is gone.
* **Decks**: `ctx.layer_load` clears the deck when a conversion starts, so a
  file picked by hand behaves like a PSET restore. The clear in
  `Mdeck.pset_read` moved there.
* **Tooling**: `tools/check.lua` no longer rebuilds and compares dist a second
  time. test_control does it, and now runs the generators on its own
  interpreter (`arg[-1]`), so under LUA53 they run on 5.3 too. `T.pulse` and
  `T.finish` replace three copies each in test_control. The PEEK render holds
  K2 for 8 frames, because the ramp now starts after the tap window.
* **Not done**: a CHOP or TIGHTEN queued behind the strip repaint still dumps
  the take again. Reusing the repaint's dump needs a sign that the buffer did
  not change in between, and an overdub does not bump `take_gen`.
* RENDERS: identical except SCENE_PEEK (now a full peek) and two frame-timed
  shots that follow it (VOICE_ERODE, SCENE_ORBIT). Device rows:
  doc/device-gate.md stage 15, rows 15.9 to 15.11.
* VERIFIED: 657 assertions (372/114/87/41/43). Each behaviour fix was
  removed once, and its test failed. `tools/check.lua` green on Lua 5.3.6
  and on 5.5.

Eighty-third change: **start on sound (Lua + tooling, ENGINE UNTOUCHED,
fingerprint STAYS 65, on branch `full-review`)**. The first of the additions.
* **What it does**: with `rec_wait` on, an armed take starts where the sound
  first crosses `rec_thresh`. The head records from the arm, as always, and
  `tick_rec_wait` moves the arm phase to the crossing less a two-frame
  pre-roll. Starting the head at the crossing would cut the attack, because
  the level arrives once a frame.
* **The level** is the engine's `rec_amp`, what is being written, so a
  resample counts too. A STOP holds the wait. A pass with no sound keeps the
  whole pass. A wait that wrapped the buffer starts at the sound.
* **The screen**: TAKE shows WAIT in place of the elapsed seconds.
* **Classified**: both params in `SCENE_EXCLUDE` and `MOTION_EXCLUDE`. The
  record group is 15.
* RENDERS: identical, plus TAKE_WAIT (68 shots). Device rows: stage 16.
* VERIFIED: 669 assertions (384/114/87/41/43). `tools/check.lua` green on
  Lua 5.3.6.

Eighty-fourth change: **start on sound, the review fixes (Lua + tooling,
ENGINE UNTOUCHED, fingerprint STAYS 65)**. A reviewer agent read the 83rd.
* **The pre-roll** is now taken from the head on the last quiet frame, less
  one frame, so a late frame widens it. The fixed two frames could cut a soft
  attack.
* **A hit stopped a moment after the crossing** set no window, so the loop
  stayed on the previous take over the silence this pass wrote. A take that
  started on sound now gets at least the 0.3 s floor.
* **An overdub never waits**: `rec_amp` does not hear the old material that
  `pre_level` keeps, and trimming it out of the loop was wrong.
* **`rec_wait` is read every frame**, not latched at the arm.
* **The rec stop's window writes go through `Mdeck.set_pair`.** A take laid
  past the old window's end crossed the pair for a moment. This bug is older
  than start on sound.

Eighty-fifth change: **the pad sequencer (Lua + tooling, ENGINE UNTOUCHED,
fingerprint STAYS 65)**. New module lib/mseq.lua (amalgamate 9 to 10).
* **Why a sequencer again**: the 49th change removed a percussive one. The
  feedback then was "not a percussive idea but a way to sequence the
  different kinds of pad sounds / drones" (doc/ux-feedback.md §28). This one
  starts there: by default four pads a bar each, legato.
* **The pattern is generated**: `step_fill` hits spread evenly over
  `step_len` (a euclidean rhythm), and `step_order` picks the pad per hit
  (UP, DOWN, BOUNCE, RANDOM). `step_chance` and `step_gate` shape it. Every
  knob rebuilds the pattern in its action. No grid is needed.
* **One voice id (3000)**, released at every step boundary before anything
  else, so nothing can strand a voice. The step is read off the clock's beat
  count. One clock coroutine, cancelled on stop and in cleanup.
* **PADS** draws the steps under the pads while it runs.
* **Purity**: a held pad voice and a running sequencer now kill the ◇ mark.
  Pad voices never did, which is older than the sequencer.
* **Classified**: all seven params in `SCENE_EXCLUDE` and `MOTION_EXCLUDE`,
  as the orbit's are.
* RENDERS: identical, plus PADS_SEQ (69 shots). Device rows 16.3 to 16.6.
* VERIFIED: 697 assertions (408/114/87/41/47). Each fix and guard of the
  84th was removed once, and its test failed. `tools/check.lua` green on Lua
  5.3.6.

Eighty-sixth change: **the modulators (Lua + tooling, ENGINE UNTOUCHED,
fingerprint STAYS 65)**. New module lib/mlfo.lua (amalgamate 10 to 11).
* **Two LFOs**, each on one knob from an append-only target list (the
  option stores an index). Shapes SINE, TRI, SQUARE, RAMP, RANDOM and ENV
  (the input envelope, fast up and slower down). The period is FREE in Hz or
  locked to the clock's beat count. Depth is -1..1, in the knob's unmapped
  space, so ENV with a negative depth ducks.
* **The base is polled**, like the motion looper: a value that is not the
  one the modulator last wrote is a new base. A hand, MIDI, a scene, the
  morph and a motion lane all move the centre. Each write is accounted to
  the looper in the same frame, so no lane records a modulator.
* **A PSET save** stores the base: norns fires `action_write` after the file
  is written, so `Mlfo.pset_patch` rewrites the modulated lines. Cleanup puts
  every knob back.
* **Not targets**: the window and loop pairs (they go through set_pair), the
  buffer writers, the holds and `delay_time` (the clock owns it when synced).
* **Purity**: an active modulator kills the ◇ mark. **Header**: steady SQ
  (the sequencer) and LF (a modulator) flags, drawn only where they fit
  before the page dots.
* RENDERS: identical except PADS_SEQ, which now shows SQ. Device rows 16.7
  to 16.9.
* VERIFIED: 719 assertions (428/114/87/41/49), with the 87th. `tools/check.lua`
  green on Lua 5.3.6.

Eighty-seventh change: **the pad sequencer, the review fixes (Lua + tooling,
ENGINE UNTOUCHED, fingerprint STAYS 65)**. A reviewer agent read the 85th.
* **The voice id** was 3000, which is the typing keyboard's A. A held A had
  its note cut at every step, and its release cut the sequencer's. It is now
  4000, clear of every range.
* **A gate close to legato** slept past the next boundary, and that step was
  lost. A gated hit now releases at least 30 ms before the boundary.
* **A new step length** waited for the old division's sync (up to two bars)
  and could fire once off the grid. The clock restarts on the change, and a
  beat off the grid is not a step.
* **The idle dim**: `pad_trigger` takes an `auto` flag, so the sequencer no
  longer counts as a hand.
* **Left as it is**: under an external clock that stops, a legato hit holds
  until the clock moves (said in lib/mseq.lua).

Eighty-eighth change: **the window on the clock (Lua + tooling, ENGINE
UNTOUCHED, fingerprint STAYS 65)**.
* **`win_beats`** (FREE, 1 BEAT to 8 BAR) sets the window's end to the start
  plus that many beats at the current tempo. `sync_window_len` runs each
  frame beside `sync_delay_time` and follows the same law: the clock owns
  the end, it writes only when the end is off by more than 0.5% of the
  length, and each write is accounted to the motion looper. The write goes
  through `Mdeck.set_pair`.
* **Classified**: a scene remembers it (`SWITCH_IDS`, beside `delay_sync`);
  a motion loop does not replay it.
* **TAKE** shows the locked length top right.
* RENDERS: identical, plus TAKE_LOCK (70 shots). Device rows 16.10, 16.11.
* VERIFIED: 727 assertions (436/114/87/41/49). `tools/check.lua` green on
  Lua 5.3.6.

Eighty-ninth change: **the modulators, rebuilt after review (Lua + tooling,
ENGINE UNTOUCHED, fingerprint STAYS 65)**. A reviewer agent read the 86th
and reproduced five faults, all from one design choice: the modulator wrote
its target param and tracked a "base" by polling. An encoder nudge moved the
centre by the whole swing. A hand on a modulated knob could not be recorded.
Two modulators on one knob ran away. Every snapshot (scenes, the safe
snapshot and UNDO, the throws) stored where the wave happened to be. A
reverb or delay mix swung through 0 respawned its synth every cycle.
* **A modulator now never writes a param.** It sends the engine the knob's
  value plus the swing, through the param's own send map (`ctx.eng_map`,
  filled by `add_eng_control`). The knob stays the single source of truth,
  so everything that reads or stores it sees the knob.
* **Targets** are engine controls only (pitch, tape rate, the mix and the
  deck levels are not). Two modulators on one knob add their swings. Delay
  and reverb mix are held at 0.001 while modulated.
* `pset_patch` is gone: a PSET stores the knob anyway.
* **The sequencer's off-grid guard** is a quarter of a step, not a hundredth:
  a coroutine woken late (matron busy, MIDI clock) still plays its step.

Ninetieth change: **the window on the clock, the review fixes (Lua + tooling,
ENGINE UNTOUCHED, fingerprint STAYS 65)**. A reviewer agent read the 88th
and reproduced three faults: TAKE SNAP could not go back, a morph or GLIDE
on the end fought the lock every frame (the read head wobbled at 7 Hz), and
the morph flipped `win_beats` at its midpoint.
* **The lock no longer owns the end.** It puts the end at start + length
  when it is set, when a record pass stops, on a tempo move past 0.5%, and
  when the start moves while the end does not. A write that moves the end
  (SNAP, TIGHTEN, a scene, the morph, E3, any pair write) is left as it is.
* **A start that jumps past the end** takes the end with it in its own
  action, so the engine never reads a crossed pair.
* `win_beats` joins `MORPH_EXCLUDE`.

Ninety-first change: **the take undo (Lua + tooling, ENGINE UNTOUCHED,
fingerprint STAYS 65)**.
* **One step back and forward.** After every finished change (a record pass
  stops, a load or print lands, a PSET restores the take, regen or erosion
  goes quiet, a clear) the take is dumped as the `undo-cur` L/R pair through
  the engine's own `write_take`, and the pair before becomes `undo-prev`.
  `take_undo` loads `undo-prev` with `read_take` and swaps the two, so a
  second UNDO is a redo. The window and the take length come back with it.
  A clear is a state (`empty`), so UNDO after a clear brings the take back.
* **Before it loads**, UNDO stops rec, regen and erosion, as a clear does.
  The pairs from the last session are removed at init. `undo_keep` off
  writes nothing.
* **Classified**: both params in `SCENE_EXCLUDE` and `MOTION_EXCLUDE`. The
  record group is 17.
* RENDERS: all 70 identical to the 88th. Device rows 16.7, 16.9, 16.12 to
  16.14 (16.7 and 16.9 rewritten for the rebuilt modulators).
* VERIFIED: 753 assertions (462/114/87/41/49). The window fixes and the
  morph exclusion were each removed once, and their tests failed.
  `tools/check.lua` green on Lua 5.3.6.

Ninety-second change: **the modulation out (Lua + tooling, ENGINE UNTOUCHED,
fingerprint STAYS 65)**. New module lib/mout.lua (amalgamate 11 to 12).
* **One source out**: the scene morph, the input envelope, or LFO 1 or 2
  (their waves now run whether or not they move a knob, as `mods[i].out`).
  It goes out as a MIDI CC (`out_midi` port, `out_ch`, `out_cc`) only when
  the 7-bit value changes, and to crow output 1 as 0..5 V when `out_crow` is
  on and a crow is connected.
* It writes nothing in the instrument. It runs after the morph and the
  LFOs in the frame. An LFO draws a RANDOM level only for a RANDOM wave, so the always
  running waves do not move the orbit's own random sequence.
* **Classified**: all five params in `SCENE_EXCLUDE` and `MOTION_EXCLUDE`.
* RENDERS: identical (70 shots). Device rows 16.15, 16.16.
* VERIFIED: 759 assertions (468/114/87/41/49). `tools/check.lua` green on
  Lua 5.3.6.

Ninety-third change: **the review fixes for the undo, the modulators and
the modulation out (Lua + tooling, ENGINE UNTOUCHED, fingerprint STAYS 65)**.
Two reviewer agents read the 91st and 92nd.
* **The undo renamed files the engine had not opened yet.** `write_take` is
  async, and the Lua renames ran first, so two marks in one turn (a clear
  while armed, UNDO during a pass, a PSET load while armed) left one state's
  audio under another state's window. The dumps now go into three fixed
  slots, never renamed: a new one takes the slot no kept state uses, and the
  engine's command order puts every read after its write. The test models
  the queued write; the old design fails it.
* **UNDO during regen or erosion** went two changes back. It now marks the
  take as they left it first, so it goes back one, and a redo returns it.
  It zeroes `erode` only when erosion is writing (PLAY).
* **UNDO to empty** forgets `sample_file`, as a clear does. **`undo_keep`
  off** forgets the kept states, so UNDO never offers a take older than the
  last one.
* **A modulated knob moved by a hand, a scene or a motion lane** sent its
  plain value between the modulator's frames: a spike, and a zipper on every
  move. Each engine control's action now adds the current swing
  (`Mlfo.swung`).
* **The delay's feedback hold** (the engine keeps the delay alive at mix 0
  while the curved feedback is above 0.9) is kept on the knob's side of the
  line, so a swing never drops a held loop.
* **The modulation out** resends a still value on a new port, CC number,
  channel or device, and when crow comes back or is switched on. Nothing is
  sent to a port with no device. The default CC is 20, not the mod wheel. A
  switch to RANDOM draws its level at once.
* RENDERS: all 70 identical. Device row 16.17.
* VERIFIED: 770 assertions (479/114/87/41/49). `tools/check.lua` green on
  Lua 5.3.6.

Ninety-fourth change: **the beat repeat (ENGINE + Lua + tooling, fingerprint
MOVES 65 -> 66, on branch `full-review`)**. Built by request ahead of the
device session, as the 80th was. Stage 17 of doc/device-gate.md must pass
before more engine work lands.
* **The engine**: a new spawn/release synth, `\mangler_repeat`, and one new
  command, `beat_repeat` (the slice length in seconds, 0 releases). Not
  `repeat`: that is a Lua keyword, and `engine.repeat` would not parse.
  Placed after io, it reads the finished output off the engine's out bus and
  replaces it. On spawn it passes the output through while `RecordBuf`
  captures `len` seconds, then `BufRd` loops the slice. The first pass sends
  the live signal itself, so it does not depend on the server's order of the
  write and the read. A 3 ms fade sits at every loop point; `gate` fades in
  over 5 ms and out over 10 ms, then frees the synth. Two 2 s stereo capture
  buffers are allocated once and used in turn: a re-capture fades the old
  synth into the new one, which is placed before it.
* **`\clear`** releases a held repeat. `free` frees the synth and buffers.
* **Lua**: `beat_repeat` (a momentary binary, so a footswitch holds it) and
  `repeat_div` (1/2 to 1/32 of a note). A press waits for the next division
  of the clock (`clock.sync`); a new division while it holds re-captures at
  once (a roll). A STOP releases it and a press under STOP does nothing.
  The slice is capped at the engine's 2 s. Purity: a held repeat kills the
  mark. Header: a steady RP.
* **Accepted trade**: it sits after the record tap, so resample, regen and
  PRINT never record a repeat.
* **Checked without hardware**: the new code adds no parse error under the
  tree-sitter SuperCollider grammar (29 problem nodes, the same 29 the old,
  device-proven file has, at the same constructs). Brackets balance. The
  `Select.ar` over two stereo arrays is the idiom the DFM1 band pass already
  uses on the device.
* **Classified**: both params in `SCENE_EXCLUDE` and `MOTION_EXCLUDE`. The
  test's command count is 66.
* RENDERS: all 70 identical. Device rows: stage 17.
* VERIFIED: 780 assertions (487/114/87/41/51). `tools/check.lua` green on
  Lua 5.3.6. The SuperCollider is unverified until stage 17.

Ninety-fifth change: **the beat repeat, the review fixes (ENGINE + Lua,
fingerprint STAYS 66)**. A reviewer agent read the 94th against SC 3.11/3.12
semantics: nothing in alloc can throw, the argument orders, the Select
expansion, the fade's division and the node order (the fading synth reads the
new one's output, a true crossfade) all hold. It found:
* **The capture stopped up to a block short** of the loop: a kr `Sweep` reads
  a block ahead, so the last frames of the slice held an older capture and
  ticked inside every fade. The capture now runs two blocks past the slice.
* **A fast spin of the division** re-used a capture buffer a fading synth
  still read. Three buffers now (2.3 MB), used in turn.
* **A PSET saved while the repeat was held** loaded it held, with no release
  to come. `action_read` lets it go.
* **RP and the ◇ mark** read the held key, not the engine. They now read
  `ctx.repeat_live()`: the mark dies only while a slice loops, and RP is dim
  while a press waits for its beat. A clear releases the Lua side too.
* **A press let go before its beat cancelled the waiting clock**, which is
  the norns clock race in CLAUDE.md and crossed often. Each press takes a
  generation instead, and a wait that wakes stale does nothing; only cleanup
  cancels. Two presses before one beat repeat once.
* Left as designed: a re-strike captures at once, off the grid (a roll), and
  every capture starts late by the matron-to-scsynth latency.
* Still 29 problem nodes under the tree-sitter grammar, the old file's 29.
* RENDERS: all 70 identical.
* VERIFIED: 785 assertions (491/114/87/41/52). `tools/check.lua` green on
  Lua 5.3.6.

Ninety-sixth change: **the screen fixes, UI-a in doc/tracks-plan.md (Lua
only, the count stays 66)**. The screen audit found two bugs that I checked
in the renders, two tight footers, and header flags that could drop off.
* **The GRAIN picture ignored the grain knobs.** It drew every third column
  of the wave as dots, so the ten grain shots differed only in the play
  head. VOICE in GRAIN now draws the cloud (`grain_cloud`): DENSITY sets how
  many grains (3 to 40), SIZE their length and life, grain jitter how much
  the lengths differ. The cloud sits on the play head, and position jitter
  widens it over the window. The y axis is the stereo field, left at the
  top: pan moves the cloud and spread scatters it. The randoms come from
  `hash` on the frame, never `math.random`.
* **The erase arc sat on the E2 word** ("MOVE" on TAKE): the footer
  reserved the key words' width but not the ring's. While the arc draws, the
  encoder words now clear it, and E2 drops to its short word (MOV).
* **The header could drop a lit flag.** RP, SQ and LF were drawn only where
  they fit, so a long title with R, T and FZ lit hid RP. The flags are now
  one list in priority order: the writers R T M and a new **L** (a layer
  deck recording, which no page but LAYERS showed), the holds FZ TF RP, the
  machines SQ LF. A flag that does not fit whole shrinks to its blinking
  letter (a writer) or a short bar, with room kept for the flags after it.
* **Two tight footers.** DELAY and REVERB name their mix **WET** (ux-feedback
  #24 asked what "echo 100%" meant), which also opens REVERB's 4 px gap. The
  VOICE rail spacing went from 10 to 8 px, so the PV chip no longer touches
  HELD. HELD is dim in PLAY and WARP, where a PV freeze is not heard, and
  bright in PV and GRAIN (Clouds takes `pv_freeze` as its freeze). The PLAY
  and WARP textures keep moving under a PV freeze they cannot hear.
* **A sixth harness**, `tools/test_screen.lua`, reads the offscreen pixels
  (`env.pixel`): every lit flag draws and ends before the page dots, the E2
  word starts right of the arc, and the cloud follows each knob. Each check
  failed against a mutation that undid its fix. `tools/check.lua` runs it.
* RENDERS: 26 shots changed, all on VOICE, DELAY, REVERB, the arc and
  LAYERS_LIVE (its L flag). One new shot, LAYERS_FLAGS: the header with every
  flag lit. The other 44 are identical. Device rows: stage 18.
* VERIFIED: 828 assertions (491/114/87/41/52/43). `tools/check.lua` green on
  Lua 5.3.6.

Ninety-seventh change: **the screen's consistency, the first part of UI-b in
doc/tracks-plan.md (Lua only, the count stays 66)**.
* **One blink.** The header's write flags are now the only thing that
  blinks (ux-feedback #29). TAPE's REC chip, the LAYERS write dot, MOTION's
  REC chip and armed frame, SCENE's ORBIT chip and a queued scene slot, and
  TAKE's WAIT are steady. The grid's layer REC pads blink on the state
  strip's phase.
* **Readable text.** Text that carries information has a floor of level 5:
  PADS' PLAY>DRONE and voice count, SCENE's recall mode, TAPE's seconds,
  MOTION's LOOP, the CHOP note, the second line of an invitation. An empty
  page's invitation is level 10 on every page, as TAKE's was, and VOICE with
  no take now says EMPTY - REC ON TAKE.
* **The page dots in families** (ux-feedback #9): 3 px apart inside a
  family and 5 px between the take, the decks, the tone, the console and the
  performance pages. The row is 2 px narrower than before.
* `test_screen` gains two sections: each page chip draws the same on every
  phase of the old blinks while the header still blinks, and a family gap is
  wider than a gap inside a family. Both failed against a mutation.
* RENDERS: all 71 changed (the dots are in every header). Device rows
  18.7 to 18.9.
* VERIFIED: `tools/check.lua` green on Lua 5.3.6.

Ninety-eighth change: **the sequencer has a home on PADS (Lua only)**.
* **The step row is always there.** It replaced a hint ("E2 SLICE - E3
  PITCH") that only repeated the footer. Stopped, the pattern waits dim, so
  you see it before you start it; running, it is bright with the current
  step lit. A CHOP note moves to the line below it.
* **The grid's PADS row 6** runs the sequencer (pad 3, green while it runs)
  and takes a hit away or adds one (pads 5 and 6).
* RENDERS: the three PADS shots changed. Device row 18.10.
* VERIFIED: `tools/check.lua` green on Lua 5.3.6.

Ninety-ninth change: **UNDO and start on sound have a home on TAKE (Lua
only)**.
* **K3 is two gestures.** A tap is SNAP, as before, but it now fires on the
  release, so a hold never snaps first. A hold to the arc (the eraser's
  second, without K1) is UNDO, and it lands AT the arc. Released between the
  tap and the arc, nothing happens; leaving the page with E1 mid-hold aborts
  it. A def with a `hold` and a `tap` is a new key shape in `key()`, and
  `tick_keys` fires it. The footer draws the same arc and word ("UNDO") for
  it as for the eraser, with the same room. `key_state` moved above
  `tick_keys`, which now reads it.
* **TAKE says what K3 did** on its top row for a moment (`take_say`, the
  LAYERS rule): SNAP whole buffer, on the take, back, already whole; UNDO
  the take before, empty again, nothing to go back to, nothing kept.
* **TAKE's top row** shows "<" while an UNDO is kept (`ctx.undo_ready`),
  and ON SND beside the clock lock while a record would wait for sound.
* **The START and END swell reads seconds** of the buffer, not a percentage.
* RENDERS: TAKE_LOCK shows ON SND; two new shots, TAKE_UNDO_ARC and
  TAKE_SNAP_SAID. Device rows 18.11 to 18.13.
* VERIFIED: `tools/check.lua` green on Lua 5.3.6.

Hundredth change: **the beat repeat on the grid, and its division in the
header (Lua only)**.
* **The main workspace's row 6** was dark. Pads 1 to 5 now hold a repeat at
  a half note to a 32nd. A second pad while one is held changes the
  division (a re-capture, so sliding a finger across them rolls), letting
  it go returns to the pad still held, and the last pad up ends the repeat.
  A repeat a footswitch holds is not the grid's to end: a pad then only
  rolls the division. The held division lights cyan.
* **RP names its division** (RP2 to RP32), with the header's shrink rule.
* RENDERS: none changed. Device row 18.14.
* VERIFIED: `tools/check.lua` green on Lua 5.3.6.

Hundred-and-first change: **MOTION hosts the modulators (Lua only)**.
* **Two rows under the lanes.** Each draws two cycles of its wave, as tall as
  its depth (inverted for a negative depth), with a dot where it is now; ENV
  draws the input's envelope as a bar. The name column says which one and
  what it moves ("1>CUT", "2 OFF"), and a modulator that also goes out to
  other gear says so on the right (>CC, >CV, >OUT). With no lanes the rows
  sit under the invitation. The rails, the playhead and the armed frame span
  the lanes only. `Mlfo.wave` is exported for the drawing.
* **One walk.** E2 is a compound target, `@mo_sel`: no lane, the lanes,
  then LFO 1 and LFO 2. A new param, `mod_focus` (LANES, LFO 1, LFO 2),
  holds which rows the encoders address, so MIDI and a PSET reach it too
  (classified as excluded from scenes and motion; the motion group is 6).
  With a modulator selected, E3 is its depth, K1+E2 its period and K1+E3
  its target (`MOTION_LFO`); the footer reads LANE·LFO1, a signed depth
  and the target's short word. K1+K3 held on a modulator row lets it go
  (target OFF, depth 0) and clears no lane.
* `doc/controls.md` lists MOTION per focus.
* RENDERS: the MOTION shots changed (the two rows); one new shot,
  MOTION_LFO. Device rows 18.15 and 18.16.
* VERIFIED: `tools/check.lua` green on Lua 5.3.6.

Hundred-and-second change: **the screen work's review fixes (Lua only)**. A
reviewer agent read the 96th to the 101st changes and reproduced each of
these in the sim. Each fix has a test that failed against a mutation.
* **An aborted UNDO hold drew a full arc.** Hold TAKE K3, turn E1 away and
  back, keep holding: the footer showed the arc and UNDO, though nothing
  fired. An abort is now recorded (`st.aborted`), and `ctx.hold_frame`
  returns nothing for it.
* **K1 during the hold** changed the arc's word to HOLD (a fresh lookup
  read the DRY def), and UNDO still fired under it. `ctx.hold_frame` now
  returns the press-time def for the word, and a K1 press aborts the hold:
  K1+K3 is the eraser's gesture.
* **Before this range: a global `floor`** in the step gate's PARAMS text
  threw below 100%. It is `math.floor`.
* **A grid unplugged with a repeat pad down** left the repeat looping and
  the pad held forever. `Mgrid.repeat_drop` (run when the Launchpad leaves)
  forgets the held pads and ends a repeat the grid started.
* VERIFIED: 534 + 60 assertions in test_control and test_screen;
  `tools/check.lua` green on Lua 5.3.6. RENDERS: unchanged.

Hundred-and-third change: **the screenshots in doc/ui (docs only)**. The 18
gallery images were made before the screen work and showed the old GRAIN
dots, header and page dots. Each is regenerated from its render
(`render_pages.lua`, then `pgm2png.py` at 4x), matched to the shot it was
made from. Three new ones show the new screens: `motion-lfo.png` (the
modulators on MOTION), `pads-seq.png` (the sequencer running) and
`take-undo.png` (K3 held toward UNDO).

Hundred-and-fourth change: **the device session, measured (tools and docs
only)**. `tools/device/` now drives a connected norns: the REPLs, keys, JACK
capture, a test signal, and audio measurements. The walkthrough ran on 2026-11-06
at `count: 66`, and doc/measurements/2026-11-06/ holds the results. doc/norns-platform.md
explains the platform and the costs. doc/tracks-plan.md no longer says that the
decks cannot reach the engine, because `jack_connect` can patch them in.

A correction: a first test reported that two servers carried 125% with no xruns.
That result was false. Under JACK, a server's `avgCPU` is `jack_cpu_load`, the load
of the whole cycle, so the second server never received its load. The new trial
reads each thread with `top -H`, and it does not show a dependable gain.

The code does not change. The session found these bugs and did not fix them: the
GRAIN density dead zone (4.10), the first pass on an empty layer (11.1), the click
when E2 moves the window (4.14), and CHOP stopping after eight hits (5.4).

Hundred-and-fifth change: **the page dots on one straight line (Lua only)**.
The user reported that the dots were not aligned. Three things moved them: every
dot after the current page moved 2 px to the right, the current page was a
taller block, and the family gaps made the spacing uneven. Each page now has a
fixed slot on rows 4 and 5 at a 4 px pitch. The current page is a brighter, wider
bar on the same rows. The family gaps are gone, so check 18.9 changes with them.
tools/test_screen.lua now fails if a dot moves, leaves the row, or spaces
unevenly on any page. The images in doc/ui still show the old dots.

Hundred-and-sixth change: **the bugs that the device session found (ENGINE and
Lua, no new command, the count stays 66)**. Each was reproduced on the device and
then retested there.

- **The first pass on an empty layer played silence.** Softcut moves a voice's write
  index only while its rec flag is on. A head that played with the flag off wrote at
  its last set position, so the pass landed outside its own loop. A punch in the
  middle of a loop landed in the wrong place for the same reason. `Mdeck.update_rec`
  now leaves the flag on, and rec 0 with pre 1 is the gate.
- **An idle deck must not drift.** With the flag on, softcut's rec and pre ramp never
  lands exactly: 30 s changed samples by up to 23 steps of 24 bits. A punch now ramps
  over 5 ms, so that it prints no step (this was the break at each seam), and the
  next phase event ends the ramp in `Mdeck.settle_rec`. A deck's region is then
  identical, sample for sample, after minutes at rest.
- **GRAIN's density crossed the dead zone of Clouds.** Density 13 to 16 was silent and
  the default was about 20 dB down. It now stays on Clouds' random side, with a lift
  at the sparse end. The spread across 1 to 200 went from 79 dB to about 4 dB.
- **GRAIN's pitch spread did nothing with Clouds.** A noise on Clouds' pitch input now
  gives a spread per grain.
- **E2 clicked.** The window edges moved at control rate, one step per block. They now
  move at audio rate through `Lag2` over 80 ms, so the window answers a little later.
- **CHOP stopped after eight hits.** It now takes its slices evenly across the take.
- **The erase left an echo.** `\clear` spawned the effects before the buffer's zero
  landed, so they took in the last of the take. It now waits with `s.sync`.

Hundred-and-seventh change: **the album set, twelve new presets (presets and
tools only, the engine and the script do not change)**. The ten shipped presets are
replaced by a set for one album. `tools/make_set.lua` builds them as a
chain (each preset is the one before it plus a short list of changes) and checks every value
against the real paramset. `tools/set_audio.py` cuts the loops and `tools/deploy_set.sh` puts
the set on a norns. The audio is not in the repo.

- Nothing is chopped out of the middle of a song. A source holds 60 s, so a long stretch is cut
  into consecutive parts of at most 60 s, kept whole and in order. Presets 1 to 10 are one half of
  one song each, in album order: part 1 in the take, parts 2 and 3 in the layer decks, quiet. The
  scene build brings the next part forward (a 2-part half at slot 4, a 3-part half at slots 3 and
  5), at normal speed and forward, so the half plays through.
- Presets 11 and 12 (ALBUM 1, ALBUM 2) walk songs 1 to 3 and songs 4 and 5: each source holds one
  unbroken 60 s stretch, the stretch that follows is in the next source, and the tape stretch is
  read from `tape-11.wav` and `tape-12.wav` beside the pset. A scene is a set of the four level
  knobs (`sc_level`, `cut_level`, `lay1_level`, `lay2_level`), so a glide is a plain fade and no
  window moves. `mix` stays at 0.5. For a manual crossfader, map `scene_morph_amt`.
- Every scene names the same params, so it sounds the same whatever came before it, and the bank
  builds in small steps (the orbit is off). Slot 8 is the next preset's sound.
- The scene and pad files must be in norns' own table format (`tab.save`). A plain nested
  `return {...}` makes `tab.load` return nil and the bank empty. The generator writes the right
  format and tools/test_set.lua loads files with a copy of `tab.load`.
- A preset sets `clock_tempo` (60). tools/test_control.lua allows that one system id.
- `tools/test_set.lua` is a new harness: it loads every pset like norns, recalls all slots and
  checks the files, the bridges, the steps between scenes, the part walk and the album levels.
- MEASURED on the device (2026-11-10, `count: 66`): every preset loads, scenes load (8 of 8), the
  tape wavs load for 11 and 12, the album levels land. No clipping. scsynth 17 to 26% of a core
  (the budget is about 60%), 57 to 60 C, never throttled, 0 to 2 xruns per preset. Glide runs on
  11 and 12 recorded from JACK: no clicks found, 0 xruns. On 11 the level stayed within 5 dB; on 12
  it dipped 10 dB once, while deck 1 (the start of song 5, a quiet intro) faded in.
- NOT heard by a person. Balances are measured, not judged by ear.

Hundred-and-eighth change: **songs kept whole (presets and tools only)**. The user found the
album presets chopped into too many small pieces. The 12 s medley (preset 11) and the 20 to 30 s
take/tape crossfader (preset 12) were replaced. Presets 1 to 10 now play each half in whole,
consecutive parts and bring the next part forward in the scene build, and presets 11 and 12 walk
the album in unbroken 60 s stretches with one level knob per source. See the 107th change for the
design and the measurements. A source holds 60 s and a preset holds 240 s, so the whole album
(about 980 s) is covered by presets 1 to 10, and 11 and 12 are walks through it.

Hundred-and-ninth change: **the visuals link (Lua only, the count stays 66)**. New
`lib/mosc.lua` sends the instrument's state as OSC to a computer: one message per field,
`/mangler/<key>`, only on a change, with a full resend on a new address and every two seconds.
Param fields go out 0..1 through their own controlspec. Three new params (`osc_on`, `osc_host`,
`osc_port`, group `grp_osc`) are in both exclude lists. It runs at the frame rate of 15 Hz, not
the 10 to 60 Hz first planned, because the frame clock is the only clock and the browser
smooths between messages. New folder `visuals/`: `bridge.js` (UDP OSC in, WebSocket on
127.0.0.1 out, no packages), `hydra.js` (three looks chosen by the page), `index.html` (the bridge serves it with hydra.js
at http://127.0.0.1:8080, so Chrome asks no local network permission), `fields.json` (the
field list, checked against `lib/mosc.lua` by test_control), `test_bridge.js` (a fake norns and
a fake page, 10 checks) and a README with the audio routing. `tools/uisim/env.lua` gained an
`osc` recorder and `params:add_text`; `tools/amalgamate.lua` now expects 13 modules.
The looks sit on slow voronoi blobs (their black is see-through), and the page plays a live news video (DW, HLS through hls.js) as worn tape (low resolution, faded warm colour, wobble, scanlines, grain, smear) under them. `?video=<url>` picks another stream, `?video=none` turns it off. A click on the page unmutes it. index.html asks Hydra for 6 outputs. Tested in Chrome with a fake norns: the link connects, the three looks draw and switch with the
page. That test found that `solid(1,1,1,a)` adds white, so the looks use `solid(x,x,x,1)`, and
that hydra.ojack.xyz waits on a Chrome permission to reach ws://127.0.0.1. Unverified: the
audio input.

Hundred-and-tenth change: **a look per scene (Lua, the presets and the visuals; the count stays 66)**.
The bars were one look of seven. New param `vis_look` (AUTO, BARS, FILTER, SHAPES, RINGS, MOSAIC,
TUNNEL, WAVES) sits in `SWITCH_IDS` and `MORPH_EXCLUDE` of lib/mscenes.lua (a scene or preset
brings its own look, a morph never changes it) and in the motion exclude list. It goes out as
the field `look`. `visuals/hydra.js` was rebuilt around a table of looks and two buffers, so a
change of look is a dissolve. `tools/make_set.lua` gives each scene slot a look
(`VIS_BY_SCENE`), so all twelve scene files changed by one line per slot. Checked on the device:
a recall of scene 3 of preset 11 landed look 7. Open question: after hand-setting `vis_look` while scenes were recalling, three slots of the loaded bank held other looks than the file (slots 2 to 4); a clean reload and recall gave the file values, and I could not repeat it.


Hundred-and-eleventh change: **concert ready, the plug and play pass (Lua, visuals, tools; the count stays 66)**.
`lib/mosc.lua`: the connection params (`osc_on`, `osc_host`, `osc_port`) are remembered in
`dust/data/mangler/osc.cfg`, written on a change and read at load, kept out of every pset (the
generator skips them, the `params.read` wrapper stops a pset from writing the file, and
`action_read` puts the file's values back). `osc_host` takes a name: it is resolved with
`getent` once a minute and the number is sent to, because `osc.send` looks a name up on every
message. Two new fields: `beat` (the clock's beat phase) and `tempo`. Ninth look FACETS (a low-poly
shard version of the news). `visuals/`: `index.html` plays DW with a France 24 fallback, a
watchdog for a frozen picture, hls.js error recovery, and a screen wake lock. `hydra.js` has a VHS
layer (colour slip, a rolling tracking band, vignette, beat pulse) and a canvas on-screen display
(PLAY, counter, date, source, look, scene, REC, link status). `start.command` (bridge restart
loop, `caffeinate`, Chrome kiosk with autoplay and the audio input granted), `stop.command`,
`doctor.command`. Fixed while testing: a Hydra chain changes when it is added to, so a reused
chain made the shader grow without end; `news` clashed with the page's own constant.
Looks reworked after a look at each: FILTER is a scanning beam at the playhead (a feedback that adds too much reaches white, so the add is 0.09 against a decay of 0.88), WAVES are thin rippling lines. Page reports (`/status`, `doctor.command`) carry one entry per page.
`start.command` now starts the browser with a new profile each time: the browser restored the tabs of the last session, so after four starts four pages were drawing at once.
The display shows FF or REW on a scene change, the page name on a page change, PAUSE with a shake on a freeze, and the mode; a page that grows past 700 MB reloads itself after an hour.
Cold start tested twice on the device: after `sudo reboot` with the clean-shutdown flag false (a pulled plug) the norns shows NO SCRIPT and sends nothing (norns does not auto-load after an unclean shutdown); with the flag true (a normal SLEEP) it loaded mangler, read `osc.cfg` and the bridge saw OSC again within about 90 seconds, with no setting touched.
Mistake: a test wrote `params:write(12)` on the device and replaced the files of preset 12
(pset, scenes, padlock, tape, take, decks). They were restored from the repo and from the audio
folder (tape-12.wav from set_alb2_tape.wav, no take or deck files, as the deploy script does).
Use a slot above 12 for a test write.

Hundred-and-twelfth change: **the grid drives the visuals, and the strip colours (Lua only,
the count stays 66)**. Main workspace, row 6: x6 and x7 step the visuals look back and forward
(wrapping, violet, brighter further down the list), x8 is a held FLASH. FLASH is the new
momentary param `vis_flash` (scene and motion excluded, not in a pset), sent as OSC field
`flash`; `hydra.js` keeps its scene flash alive while it is held. Row 2 colours: rec red is
softer and leans rose ({118,28,30}), and the two freeze pads are a new hue ICE ({52,92,127}, a
periwinkle blue) instead of cyan, so they read apart from rec and from the slate blue of
"available". Tests: 4 assertions in section 30a.

Hundred-and-thirteenth change: **MIDI to the picture, and a LAN mode (Lua and visuals, the
count stays 66)**. `lib/minput.lua` hands every MIDI message of every port to `Mosc.midi_in`,
which sends notes, changed CCs, program changes and start/stop at once as `/mangler/ev/<name>`
with integer arguments (at most 24 per frame; the clock is never sent). New param `vis_midi`
(on by default; scene, motion and pset excluded; group count 6). The bridge forwards an event as
`{ev, a}` without keeping it as state. `hydra.js` has a doodle layer (shapes that draw
themselves, words that type themselves: PTN A01, TRK 3 C4, CC74 20, PLAY, STOP, from an idea
the user pasted) over the looks and under the display; a few ambient ones appear when nothing
plays. `MANGLER_LAN=1` (`LAN=1 sh visuals/start.command`) opens the bridge to the local network;
the page now connects to the host that served it and asks no microphone over the network. Tests: 8 assertions
in section 30b, one in `test_bridge.js`. Not tried with an Octatrack.

Hundred-and-fourteenth change: **the sound review's clicks and timing (ENGINE and Lua, the
count stays 66, needs a RESTART)**. A review asked how to make mangler sound better; ten
findings were confirmed, and this fixes all ten. Engine: a mode change RELEASES the drone
(10ms in, 20ms out, `gate` and `handover` args, no new command) instead of freeing it. The
record write has two 10ms linear gates (`recG`, `regG`), and the head runs until they are
down, so punch-in, punch-out and a regen start fade instead of printing a step into the take.
PV and the Clouds source get PLAY's seam fade (`seam`). The drone head stops on the same 50ms
lag as io's level, so STOP fades instead of thumping. A filter type change is a 20ms crossfade: LP
and HP each have a DFM1, always running (one more DFM1 of CPU; the device sits near 30%). `grain_level`, the drone `pan` and PLAY's `pitch` are lagged.
The delay line is one control block short, so every echo lands on time (it drifted 1.33ms a
repeat). The master limiter's lookahead is 3ms, not 10ms, so the output is 6ms late, not
20ms. Lua: `Mdeck.pset_read` snaps a deck's loop when the pset stores no loop points (the
album set), so reloading the same file no longer keeps the player's last slice.
Tests: 2 assertions in test_deck. All checks pass on Lua 5.3. On the device 2026-11-11 it
compiles at `count: 66`, every def builds, modes cycle with no leftover synths, and CPU sits
near 19%. Nobody has listened: each fix still needs an ear.

mangler2, first change: **a second engine track (ENGINE and Lua, the count is 92, a new
script)**. mangler2 is mangler forked into its own script (`mangler2.lua`, class
`Engine_Mangler2`, SynthDefs `\mangler2_*`) so the S-4 tracks idea can be tested beside
mangler without touching it. Engine: a second drone slot (`setMode2`, the same release law)
on the same take, writing its own bus; a strip synth (`\mangler2_strip`) gives it io's
filter (two DFM1s, the 20ms type crossfade) and a level; io adds it after its own filter, so
drive, delay and reverb are shared. Track 2 shares level, rec and freeze with the take, so
STOP halts it too, and it has no erosion head. Commands: `t2_` plus 21 drone args, the
strip's four and `t2_mode`: 26 new, count 92. Lua: the "track 2" group of 26 params
(PARAMS and MIDI only, no page yet), classified like track 1 in scenes, morph and motion,
with SHORT words, the fine step, RATE_IDS and purity. Default OFF, so it costs nothing
until switched on. Tests: the count and the id checks know track 2; one purity row.

mangler2, second change: **fewer scripts in SELECT (folders only, no code change)**. norns lists every
`.lua` under dust/code except in folders named lib, data, crow, test or docs. `tools/` is
now `test/` and `presets/` is now `data/`, so the harnesses, the uisim and the scene and pad
files no longer show as scripts. Every path in the scripts, tests and docs moved with them;
the change log and the 2026-11-06 measurements keep their old paths as history. The
rebuilt presets are byte-identical. All checks pass on Lua 5.3.

mangler2, third change: **the track switch (Lua, and one engine poll; the count stays 92,
needs a RESTART)**. VOICE and FILTER address one engine track at a time. K3 held to the arc
on either page flips the track (the tap keeps MODE and TYPE, as TAKE's K3 keeps SNAP under
UNDO); `track_sel` is the param, a UI cursor kept out of scenes and motion. On track 2 the
title reads VOICE 2 or FILTER 2, every knob and key reaches the `t2_` twin (`ctx.tid`), and
the page draws track 2's mode, texture, window and head (new poll `play_phase2`). Track 2 has
no erosion, so VOICE in PLAY keeps scan and pitch on K1 and FRZ on K2; drive and dry/wet are
shared. OPEN on track 2 is its own throw (`throw` takes a snapshot key). A header flag T2
lights while track 2 sounds. The footer words and values of a `t2_` id read as track 1's.
Tests: 26 assertions in test_control's last section, the T2 flag in test_screen, and a
`track2` render variant in the check (81 shots).

mangler2, fourth change: **the TRACK 2 page, and track 2 in the visuals (Lua and visuals;
the count stays 92)**. A new page after VOICE, TRACK2 (title "TRACK 2"): track 2's mode rail,
the take with track 1's window dim and its head dashed, track 2's window bright with brackets
and a solid head, and a level bar marked at unity. E2/E3 move track 2's window (the fine step),
K1+E2/E3 its level and pitch, K2 is ON (a tap latches, a hold plays while held, and on brings
back the last mode, PLAY the first time), K3 cycles its mode. OFF, STOP or level 0 lay it flat
and dim. The VOICE rail is now one helper (`mode_rail`). The short header bars are 3px (was
4): the twelfth page dot and the T2 flag left the worst case 2px short of the dots. The test
page list and the renderer now read a page name with a digit (they silently dropped TRACK2,
which shifted every later page's index). mosc sends track 2's state (`t2_on`, `t2_mode`,
`t2_level`, `t2_play`, its window, size, density, pitch, cutoff); the visuals draw it as a cold
blue column over the look (o7), name it in the display, and pick BARS for the page in AUTO.
Visuals also fixed for mangler: a page opened over the network halted at once (Hydra makes no
`a` without audio), and such a page now reacts to the sound the listening page relays through
the bridge. Tests: 13 assertions for the page, two renders in the track2 variant (84 shots).

mangler2, fifth change: **four tracks and the routing (ENGINE and Lua, the count is 156,
needs a RESTART)**. The engine's track 2 became tracks 2 to 4 (`extra`, one Event each: drone,
strip, buses; `setModeN`), with commands `t<n>_*` (26 a track). ROUTING, from the S-4's sends:
`send_<from>_<to>` feeds one track's filtered output into another track's filter (12 sends);
each track writes its post-filter output to its own bus, a send arrives a block late through
InFeedback and a LeakDC'd tanh, so a ring can feed back but not run away. A strip runs only
while its track plays or a send feeds it (`updateStrip`, the pause 100ms late so a release is
heard). Lua: `track_sel` is 1 to 4 (K3 held on VOICE/FILTER steps 1>2>3>4>1); the TRACK2 page is
TRACK (tracks 2 to 4, K3 held steps 2>3>4); a new ROUTE page draws the sends as a 4x4 grid (rows
FROM, columns TO, cells filled by level, the cursor framed, row labels bright while the track
sounds): E2 walks the cells (`route_sel`), E3 sets the send (`@route_amt`), K2 PATCH toggles it
(off, or back to its level, half the first time), K3 jumps a row and held clears every send.
Groups: "tracks" (2), "track 2/3/4" (26 each), "routing" (12). Classification, SHORT words,
RATE_IDS, FINE_IDS, EDGE_PAIRS and purity cover tracks 3, 4 and the sends; the header flag
reads T2 to T234. Fixed: `enc_param` had turned an empty K1 slot (MOTION, SCENE) into the base
param (`alt and m[2] or m[1]`), the trap its comment warns about. The writer pips in the header
are 1px gap now (thirteen page dots). On the device: count 156, every def builds; four GRAIN
tracks with FX, all sends and resonant filters at 48% of the thread, 0 xruns over 60 s
(doc/measurements/2026-11-12/four-tracks.md). Nobody has listened.

mangler2, sixth change: **one focus and the TRACKS hub (Lua only, the count stays 156)**. The
user found four tracks hard to reach with three knobs: only TRACK reached tracks 2 to 4, and
routing was a page of its own. Now `track_sel` is THE focus and TAKE, VOICE and FILTER all
follow it (titles TAKE 2, VOICE 2 ...; `TRACK_PAGES` gained TAKE). TAKE on track n edits its
window (E2/E3, K1+E2 slides it, K1+E3 its jitter), draws the other tracks' windows as dim marks
along the top and their heads as ticks, and SNAP puts the track's window on track 1's and back.
TRACK and ROUTE became one page, TRACKS: the four tracks as rows (mode, window with head,
level); E2 the focus, E3 its level (track 1's is grain_level), K2 ON, K3 MODE; with K1 held,
the send grid, and K1+E2/E3 pick and set the focused track's sends (`@route_to`, `@route_amt`;
the cursor stays in the focus's row). 12 pages. A track turned on with its window still at
the default (the whole 60s buffer) starts on track 1's window: on the device track 2 played
the empty buffer past a 32s take for half of every loop. The test page walks now put the focus back on
track 1, since TRACKS's E2 moves it.

mangler2, seventh change: **own material per track, the S-4 way (ENGINE and Lua, the count
is 158, needs a RESTART)**. Each track records and plays its own 60s: the engine has four
buffer pairs (`bufLs`, `bufRs`; bufL/bufR are track 1's), each extra track's drone reads its
own, and two commands point the rest: `rec_track` (the pair io records, regens and prints
into) and `buf_track` (the pair clear, read_file, write_take, read_take and the pad voices
use). Lua: `track_sel` is the FOCUS, and `ctx.focus_take` keeps each track's take state
(TAKES: wave_any, take_len, undo, SNAP memory), swaps the focused one in, rewrites the window
ids (`WIN`, so window_bounds and every take gesture are the focused track's), swaps the
waveform strip (`Mpages.focus_wave`) and moves the engine. A pass recording when the focus
moves ends on the old track and opens on the new one. Recording into an OFF track switches it
to PLAY. REC END (`rec_end`, take - record): LOOP records over the start as before; ONE-SHOT
ends a full 60s take and records on into the next track (on track 4 it stops). PSETs save and
restore every track's take: track 1 as `take-NN` (mangler's name, so a mangler pset still
loads), tracks 2 to 4 as `take2-NN` ..., undo as `undo2-` ... NAVIGATION: K1+E1 picks the
track from any page (the scene morph stays on SCENE's E3); the track pages (TAKE, VOICE,
FILTER, TRACKS) carry an inverted badge with the track number before the device name, and the
page pop reads "2 VOICE". TRACKS shows EMPTY for a track with no material.

mangler2, eighth change: **the presets carry four tracks (Lua and presets; the count stays
158)**. Each track 2 to 4 gets a `t<n>_file` param (its own material from a file, scene and
motion excluded; group counts 27): `ctx.track_load` loads the focused track exactly as the
take, and another track into its own buffer through buf_track, with its own strip, take state
and a window snapped to the file. `test/make_set.lua` now gives every preset four tracks of
material: track 2 deck 1's part, track 3 deck 2's, track 4 the take again (1 to 10) or the
tape's stretch (11, 12). They load OFF, so each preset sounds as it did; TRACKS (K2) brings one
in as an engine track. The tracks' windows stay out of the pset: the file snaps them.

mangler2, ninth change: **COLOR, SPACE and modulators per track, the rest of the S-4 chain
(ENGINE and Lua, the count is 173, needs a RESTART)**. COLOR: every track has its own drive
and a new crush (sample rate down 32 times and 16 to 4 bits at the top, a true bypass at 0).
Track 1's are io's `drive` and `crush`; tracks 2 to 4 get `t<n>_drive` and `t<n>_crush` in
their strips. The drive used to sit after the join and colour all four tracks; it now colours
track 1 only, so `test/make_set.lua` copies a preset's or scene's drive to every track
(test_set counts that copy as one move). SPACE: each track's own send into the shared delay
and reverb (`fx_dly`, `fx_rev`, `t<n>_fx_dly`, `t<n>_fx_rev`), 1 by default, which is the
sound from before. They sit at the end of each row of the TRACKS routing grid (columns D and
R), so K1+E2 walks a track's three sends and then its two FX sends. The FILTER page's K1
layer is now the focused track's drive and crush (the curve draws as stairs while crushed);
dry/wet moved to MIX K1+E3, where the norns monitor level was (it stays in the system LEVELS
menu). DRY clears every track's drive and crush. MODULATORS: four instead of two, each with a
track (`lfo<n>_track`). A target names track 1's knob and moves track n's own on track n; a
knob all tracks share (delay, reverb, dry/wet) stays shared; a knob the track lacks (wear)
moves nothing. Picking a target on MOTION puts the modulator on the focused track. MOTION
shows four modulator rows ("3>T3 CUT"), TRACKS draws a small wave on a modulated track, and
the targets list gained crush, the two FX sends and the level (append only). Engine: 3 new
io commands and 4 more strip keys per track (66 + 3 + 3 x 30 + 12 + 2 = 173). On the device
2026-11-12: compiles, `count: 173`. The worst case takes 45% of the scsynth thread with 0
xruns over 60 s: four GRAIN tracks, all coloured, FX and four modulators
(doc/measurements/2026-11-12/color-space-mods.md). Nobody has listened yet.

mangler2, tenth change: **GRAIN is a granulator that reads the take; Clouds moves to CLOUD
(ENGINE and Lua, the count stays 173, needs a RESTART)**. On a norns with mi-UGens, GRAIN
was MiClouds on the playing window. Its grains came from about the last second of playback,
so the window, spray and position knobs barely shaped it. Now:
- GRAIN (`\mangler2_grain`) grains the track's window directly, with one stream of stereo
  grain pairs. Each trigger starts a left and a right grain at the same time, place, length
  and pitch, so the take keeps its stereo image.
- `spread` 0 is the image as recorded, and 1 throws each pair to one random place.
- `pos_jitter` (SPRAY) scatters the grains over the window. Every grain is also scattered
  by a quarter of its length, so grains no longer comb into a buzz.
- A grain is centred on its place and stays inside the window, so it never reads the
  empty buffer past the take.
- `grain_jitter` now sets the timing too. At 0 the grains form a regular stream that keeps
  a steady level. At 1 the timing is Poisson, the old law: on the device 18% of the default
  cloud fell below -50 dB between clumps.
- The loudness law follows the overlap up to 64. The cloud is trimmed 2 dB, so the default
  is 0.8 dB under PLAY with the limiter idle.
- `pv_freeze` holds the head while the grains go on: FRZ and HELD now work in GRAIN.

CLOUD is the sixth mode option (append-only, engine mode 5): MiClouds as before, trimmed by
6 dB, because it measured 6 dB above PLAY. It falls back to the granulator without
mi-UGens. The K3 cycle is PLAY > GRAIN > WARP > PV > CLOUD > PLAY, and grid row 5 x6 is
CLOUD. VOICE in GRAIN: E2/E3 size and density, K1+E2/E3 SPRAY and the pitch spread. CLOUD
keeps scan and pitch on K1. The mode rail fits five words, and OFF/HELD moved under it. In
GRAIN the cloud draws its pairs (half left, half right, 1 - SPREAD from the middle).

Pad voices: the same stereo pairs and timing law. Each grain starts up to half a grain
after the pad's point, inside the slice, so a held pad no longer buzzes on one sample. The
presets' GRAIN scenes are now CLOUD, so the set keeps the voice it was tuned on. On the
device: doc/measurements/2026-11-12/grain.md. Nobody has listened yet. A script loaded
between `compile done` and the `engines:` line hung on the engine (CLAUDE.md).

---

## Build order (procedural, each ends in an on-device gate)

Full per-stage design — param lists, SynthDef args, command tables, acceptance tests — lives
in `doc/spec.md`. Summary:

- **S0** loadable skeleton (this ship): no-op pass-through engine + Lua router/params shell.
- **S1** RECORD + GRANULAR + WINDOW — `RecordBuf` live capture, `GrainBuf` cloud, slice window.
- **S2** TIME-STRETCH MODES — `mode = GRAIN | WARP | PV` on one voice (Warp1 + phase vocoder).
- **S3** TAPE — softcut parallel path (loop window, varispeed/reverse, stutter, freeze).
- **S4** FILTER + FX — LP/HP/BP filter, delay (time/fb/mix), reverb (FreeVerb, size/mix).

Rationale: softcut (separate audio core, near-free) does everything it can; scsynth does
only what softcut cannot (granular, time-stretch, custom filter/delay/reverb). GRAIN/WARP/PV
are a **mode switch** on a single SC voice, never run together (Pi4 = one scsynth core,
xruns past ~60%).

Hundred-and-fourteenth change: **the doodles come only from played events, and six richer
shapes (visuals only)**. The ambient words and drawings that appeared when nothing played
(they showed the Octatrack's screen words, CROSSFADER among them) are gone: with no MIDI event
nothing is drawn. A note draws one of six shapes by track and pitch (rings with tick marks, a
low-poly shard with spokes and corner dots, a spiral, a burst, a lattice, a scribble), each track in its
own warm tape colour. A CC types its word at most four times a second; the display line shows
every value. The Octatrack link was seen working by the user (CC 39, 40 and 41 appeared); the
CC 70 to 97 mapping and the toggle buttons are still not confirmed.

four, first change: **mangler2 becomes the instrument, named four (names only, the count
stays 173, needs a RESTART)**. The one-track mangler retires; it stays in git as the tag
`mangler-1`. main's 115th and 116th changes (the folder rename and the visuals over the
network) were already here as mangler2's second and fourth, so the merge kept this tree.
The new names: script `four.lua`, class `Engine_Four` in `lib/Engine_Four.sc`,
`engine.name = 'Four'`, SynthDefs `\four_*`, `dist/four_single.lua`, and the presets
`data/four-NN.pset` with `four.pmap.example`. On the norns it lives in `dust/code/four` and
`dust/data/four`; the data folder starts as a copy of `dust/data/mangler2`, with
`mangler2-NN.pset` renamed `four-NN.pset` and `mangler2.pmap` renamed `four.pmap`. The PARAMS
separator and exported takes say `four`. The OSC addresses stay `/mangler/...` (the visuals
read them), and the log lines still start with `mangler:`.

four, second change: **you can see what is recorded and what plays (Lua only, the count
stays 173)**. Play-tested as "hard to understand: what is being recorded, and what is T234".
The header now starts with the four TRACKS, one cell each, on every page:
- A white box is the track the page edits (TAKE, VOICE, FILTER, TRACKS).
- On a shared page (DELAY, REVERB ...) the focus is only underlined, because those pages
  edit no track.
- A bright number sounds and a dim one is silent.
- The track being recorded blinks as a box.

The cells replace the inverted badge, the T2 / T23 / T234 flag and the R flag. TAKE says
what it records in words: REC TRACK 2, and with REC END on ONE-SHOT, THEN 3 (THEN STOP on
track 4). TAKE no longer draws the other tracks' windows and heads: each track has its own
take, so those marks were on other material and read as part of this one. A writer flag
keeps its letter and blinks only its dot, so it never vanishes for half the blink. The page
dots moved to a 3px pitch, with the current page the one bright dot, to make room for the
cells.

four, third change: **one effect slot for each track (engine and params, the count is now
185, needs a RESTART)**. Asked for as "some effects extra more than delay and reverb", for
each track. Every track has one slot after its drive and crush:
- `effect` picks OFF, CHORUS, FLANGE, WOBBLE, RESON or RING. OFF is a true bypass.
- `effect_amt` is the depth, the feedback, the ring time or the mix, as the type needs.
- `effect_rate` is the speed, the note (C2 to C6) or the frequency.

Tracks 2 to 4 have the same three with the `t<n>_` prefix. One slot and two knobs keep the
controls small: four separate effects on each track would be about forty params. In the
engine it is one build-time function (`fxSlot`), used by io and by the strip. CHORUS, FLANGE
and WOBBLE share one comb pair. The count: 3 more for track 1 and 3 for each of tracks 2 to
4, so 173 becomes 185. DRY sets every slot to OFF, the purity mark goes dark for an effect
on track 1, scenes and motion lanes hold all three, and a modulator can move the amount and
the rate. There is NO page yet: the slot is in PARAMS (filter, and track n) and can be
MIDI-mapped. On the device: `count: 185`, no SC errors, each type changes the output, and
four GRAIN tracks take 42.7% of the scsynth thread with the slots off and 43.3% with them
on (doc/measurements/2026-11-12/effect-slot.md). RESON reads about 8 dB quieter than the
others. A preset saved before this change does not reset the effect. Nobody has listened yet.

four, fourth change: **the EFFECT page (Lua only, the count stays 185)**. The effect slot
gets its own page, after FILTER, so there are thirteen pages. It edits the focused track,
like TAKE, VOICE and FILTER.
- E2 is AMOUNT and E3 is RATE. K1 held has no knob there.
- K3 is TYPE: a tap steps CHORUS, FLANGE, WOBBLE, RESON, RING and round again. It skips
  OFF. Held, it steps the focus to the next track.
- K2 is ON, under the punch law: a tap latches, a hold sounds the effect only while held.
  Off remembers the type. The first on is CHORUS.
- While E3 turns, RATE reads in the unit of the effect: a speed in Hz for CHORUS and
  FLANGE, a note (C#4) for RESON, a frequency for RING. The font has a `#` now.
- The body draws one trace the way the effect moves the sound: copies that drift
  (CHORUS), a train of close echoes (FLANGE), a wave whose time bends (WOBBLE), a
  string that rings (RESON), a wave cut into beats (RING). OFF is a dim word and a flat
  dim line. The effect of a silent track is drawn dim.

The header had no room for a thirteenth dot in its worst case (every flag lit on a six
letter title): the dot row moved 1px towards the edge and the flags start 1px closer to
the title. The visuals show the FILTER look on EFFECT. Tests: the keys, the knobs and DRY
in test_control, the three brightness cases in test_screen, nine new shots in the render
suite. On the device (a script reload, no restart): `count: 185`, thirteen pages, K3 walks the five
effects, K2 switches off and back to the last one, E3 moves the rate, the screenshot matches
the render, no Lua errors, CPU unchanged at 27.5%. Nobody has listened yet.

four, fifth change: **RESON is as loud as the other effects (engine, the count stays 185,
needs a RESTART)**. RESON's peak was about 8 dB under the others on the device. Its gain
law was the exact one for noise (the square root of 1 minus the feedback squared), and
music has less energy at the comb's pitch than noise has. The power is now 0.25. On the
device after a restart: `count: 185`, no SC errors, and RESON sits within about 4 dB of
the dry signal at three amounts and three notes
(doc/measurements/2026-11-12/effect-slot.md). Nobody has listened yet.

four, sixth change: **an exact read head, and effect depth as pitch (engine, the count
stays 185, needs a RESTART)**. SuperCollider is on the Mac now, and test/dsp/ compiles the
real engine there (with a stand-in for CroneEngine) and renders its SynthDefs offline.
The first run found two defects, and both are repaired.
- The read head of PLAY, PV and CLOUD was one float from 0 to 1 across the 60 s buffer.
  A float has 24 bits and the buffer has 2.88 million frames, so the head landed up to a
  quarter frame off on every sample. A 5 kHz tone 54 s into the buffer read with noise at
  -38 dB at pitch 1 and -25 dB a semitone up. The head now counts in frames, in two parts
  (whole frames and the place between two frames), and `exactRd` does the cubic from four
  plain reads. At pitch 1 the output is the buffer, bit for bit (-154 dB), anywhere in the
  buffer, forward and reverse, and after a window move and a scan change. Away from pitch
  1 the noise is -49 dB anywhere, which is the limit of the cubic curve itself.
- CHORUS and WOBBLE set their depth in time, so the pitch bend grew with the rate: CHORUS
  reached -456 to +361 cents at the top of both knobs, and WOBBLE 140. The depth is now
  set in cents: CHORUS 5 to 30, WOBBLE's wow up to 50 and its flutter 15. Measured after:
  CHORUS 27 cents at the top, 18 at the defaults; WOBBLE 50.
Two repairs from doc/dsp-plan.md were dropped after the math: the antialiased drive (it
costs 3 dB at 12 kHz for 5 to 12 dB less aliasing) and the lowpass before RING (it only
acts above 20 kHz). NOT on the device yet: the cost of `exactRd` (eight plain reads for
each track in place of two cubic reads) is not measured, and nobody has listened.

four, seventh change: **FourStretch, our own UGens for PV, WARP and PLAY (engine and a
new C++ plugin, the count stays 185, needs a RESTART and a build on the norns)**. Stock
UGens cannot stretch correctly, and the bench proved it: the old PV changed pitch with
scan and ignored its pitch knob, and `Warp1` did not return its input at speed 1.
- `ugen/four_core.h` holds the algorithms in plain C++, and `ugen/test_core.cpp` proves
  them with no SuperCollider (41 checks). `ugen/FourStretch.cpp` wraps them as three
  UGens, and `lib/FourStretch.sc` is their one class file.
- PV is a phase vocoder with locked phases. It reads two frames one hop apart at the
  head, so the head can crawl, stand still or run backward. Left and right share one
  rotation, so the stereo image holds. A rise in level resets the phases, so an attack
  stays the take's own. FRZ now holds the head, as in GRAIN, and pitch is its own knob.
- WARP is WSOLA. A grain starts where it continues the last one, or at the best match
  near the head. Its level now equals PLAY's (the stock voice was 3.4 dB louder).
- PLAY reads through a windowed sinc. Pitched reads went from -49 dB to -70 dB of
  noise, and nothing folds above pitch 1.
- Both stretches run at pitch 1 and one resampler makes the pitch. A first version
  resampled every frame and took 9.5% of a Mac core at pitch 2; this one takes 1.5%
  (with a real-input transform, which gives the same spectrum for half the work).
- Every position and count is 64 bits. The norns is a 32-bit system, and a `long`
  there wraps after a few hours of samples.
- The engine looks for the binary in the Extensions folder. Absent, it builds the stock
  voices and says so in the log.
Measured on the Mac through the real engine (test/dsp): at speed 1 PV and WARP read a
5 kHz tone 54 s in with -109 dB off the tone; at speed 0.5 the tone stays at 5 kHz with no
level swing (the stock WARP swung 2 dB, the stock PV dropped to 2.5 kHz); pitch 2 at
speed 0.5 lands on 10 kHz. NOT on the norns: the plugin is not built there, its CPU on a
Pi is unknown, and nobody has listened.

four, eighth change: **FourStretch on the norns: the build, FFTW, and the measured cost
(plugin only, the count stays 185)**. The sixth and seventh changes went onto the device.
- The engine alone (no binary): `count: 185`, the log says `FourStretch absent`, and four
  PLAY tracks through `exactRd` take 41.8% of the thread.
- The proof (`ugen/test_core.cpp`) passes on the norns, and the plugin loads there.
- The first build was too heavy: four PV tracks took 58.7% at pitch 1 and 85% at pitch 2.
  A timing of each part on the norns found three causes, and two are repaired.
  - Our own transform took 70 us for a frame. `-DFOUR_FFTW` now takes the transforms from
    FFTW (21 us). The plan mode is `FFTW_ESTIMATE`, so every start gives the same output.
    The spectrum is the same to the rounding of a float: the proof passes with it.
  - The resampler kept its place as one `double` and converted it to 64 bits for each
    sample, which is a library call on a 32-bit system. It now keeps whole samples and a
    fraction apart. The output is bit for bit the same.
  - NOT repaired: the 32 kernel weights of a pitched read take 2.1% of a core for each
    track. They come from two table reads for each tap.
- With FFTW: four PV tracks take 53.4% at pitch 1 and 72.3% at pitch 2 (3 xruns). Four
  WARP tracks take 45.8% and 60.0%. Four PLAY tracks take 41.5% and, at pitch 1.5, 50.5%.
- `-O3` and `-ffast-math` made the code slower on the Pi. The build keeps `-O2`.
The record: doc/measurements/2026-11-13/fourstretch.md. Nobody has listened yet.

four, ninth change: **less CPU with the same sound: an exact kernel, buffer reads with no
division, and our own tanh (engine and plugin, the count stays 185, needs a RESTART)**.
The user's set ran at 67 to 69% on the screen, which is over the budget.
- The kernel of every pitched read is now computed, not read from two tables. The sinc
  comes from one sine and one cosine for each sample, so it is exact to a float. The
  window comes from a table of 257 rows, read between two rows. The four taps nearest
  the read place get their own division. NEON does the rest four taps at a time. The
  resampler at pitch 2 fell from 3.2% of a core to 1.0%, and a pitched PLAY read went
  from -72 dB of noise to under -96 dB.
- `Buf::at` took a 64-bit division for every sample it read, which is a library call on
  the norns. The usual case now needs none. WARP's search for a grain start fell from
  500 us to under 200 us, and one WARP track from 1.6% to 1.0%.
- PV finds the rise in level with NEON, four bins at a time.
- `tanh` from the C library costs 0.4% of the thread for each channel, and the engine
  has 28 channels of it (drive, the send input, RESON, the delay loop, the shimmer).
  `FourTanh` is the same curve to 2e-7 (-136 dB against the value) for a tenth of the
  cost. The engine uses it when the plugin is there, and `.tanh` when it is not.
- A first NEON kernel with a Newton division for each tap was no faster than the tables.
  The division-free table for the far taps is what gave the gain.
On the device: `count: 185`, no xruns. Four PLAY tracks fell from 41.5% to 36.0%, four
WARP at pitch 2 from 60.0% to 47.1%, four PV at pitch 1 from 53.4% to 48.6%. Four PV at
pitch 2 take 64.1%, still over the budget. The proof has 44 checks now.

four, tenth change: **a track leaves its filter at the level of its take (engine only, the
count stays 185, needs a RESTART)**. The user heard mud with four tracks. One track
measured flat to 19 kHz, so no filter dulls it. But one PLAY track left the engine 7 dB
louder than its take, and with three or four tracks the master limiter held the peaks
down all the time (crest factor 7 dB, against 11.6 for one track).
- The cause: DFM1 at input gain 0.5 already passes a tone 1.0 dB louder, and the engine
  doubled its output as "makeup". `dfmTrim` (0.891) replaces the x2 in both filters.
- Now the engine output equals its input for one PLAY track (-24.7 dBFS both), and four
  tracks of preset 1 peak at -2.7 dBFS with a crest factor of 12.1 dB.
- EVERYTHING is 7 dB quieter at the output. The balance between tracks and presets is
  the same. Drive, RESON, the sends and the delay loop see 7 dB less, so their `tanh`
  bites later on the knob. Regen and resample now write the take back at its own level.
The record: doc/measurements/2026-11-13/mud.md. Nobody has listened to this change yet.

four, eleventh change: **the tape and the layers show what is on them (Lua only)**. The
user never saw a deck's wave fill up and could not tell if a recording was there.
- The cause: a deck strip drew all 60 s of the deck, and the picture had 128 bins. A 4 s
  loop was a sliver 8 pixels wide. The TAPE page drew no wave at all, only a rail.
- A deck strip now shows the loop: the loop's two ends are the strip's two ends. While
  a first pass is open, it shows the pass, 8 s at least, so the pass fills the strip
  from the left. A rail under the strip shows where that stretch sits in the 60 s.
- The decks keep 1024 bins (59 ms each). `paint_bins`, `clear_bins`, `fill_wave_bins`,
  `wave_lane` and the wav fill read the size from the strip. The take keeps 128.
- TAPE draws the wave and the head under the reels. A loop that plays unheard says
  `SILENT / SEE MIX`: the MIX crossfade is where its sound went.
- LAYERS and the tape lane of MIX use the same view.
On the device with a drum loop: a 4.6 s tape loop and a 3.5 s layer fill their strips
and each hit shows. No test of the new view exists yet in test_screen.

four, twelfth change: **lanes: a track runs only what is heard, and it has a second
effect slot (engine and Lua, the count goes from 185 to 197, needs a RESTART)**.
- Each track's path from its voice to the mix is a LANE: a group of small synths. The
  in synth, one filter family (LO for LP and BP, HI for HP), the colour synth while
  drive or crush is above 0, one effect synth for each slot that is on, and for tracks
  2 to 4 the out synth. `\four_strip` is gone, and io reads track 1's lane from a bus.
  Before, every track ran both filter ladders, the crusher and all five effects.
- A change of filter family and a change of effect are crossfades between two synths,
  released and started in one bundle (20 ms and 50 ms, as before).
- The second slot: `effect2`, `effect2_amt`, `effect2_rate` for each track, after the
  first in series. They are in the scenes, the motion lanes (appended at the end) and
  the modulator targets. On EFFECT, K1+E2 and K1+E3 turn its knobs, and its name shows
  top right. Its TYPE has no key yet: it is in PARAMS.
- A cloud holds 32 grain pairs at most (`maxGrains`), and the level law stops there
  too. The user's set reached 100% with two dense GRAIN tracks and two pitched PV
  tracks. That set now takes 59.8% with no xruns.
- An argument named `s_bus` beside `p_bus` broke the def's event function (both read
  as `bus`). They are `sbus` and `pbus`.
On the device: `count: 197`, four PLAY tracks 25.2% of the thread (36.0% before), four
PV at pitch 2 53.0% (64.1%). doc/measurements/2026-11-13/lanes.md. Nobody has listened.
