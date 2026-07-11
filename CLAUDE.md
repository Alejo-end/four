# CLAUDE.md — mangler

Agent manual for working on **mangler**, a norns live stereo sample-mangling instrument.
Read this first. It encodes the hard rules and the staged build order. Keep it current —
when a stage passes its on-device gate, move the **CURRENT STAGE** marker.

---

         ## CURRENT STAGE: **S5–S15 (fingerprint 58) — loads + plays on device (2026-07-11, after the duplicate-mi-UGens fix); count-58 check + S11 MiClouds / S15 shimmer ear gates still to confirm explicitly**

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

**Engine deploy ritual (every time the .sc changes, no exceptions):**
1. replace file → verify on-disk with a REPL fingerprint grep
2. SYSTEM > RESTART (sclang only recompiles at startup — script reload is NOT enough)
3. load script → check `Engine.register_commands; count:` in maiden matches the
   expected fingerprint (S2 = 22, S4 = 30, S5/S6 = 31, S7 = 34, S8/S9 = 40,
   S10 = 50, S11 = 55, S15 = **58**). Wrong count = old engine still live.
Lua-only changes skip all this: save + reload the script.

---

## What mangler is

A performance-first **stereo sample-mangling instrument** for external line-level gear
(synth, drum machine, anything line-level). Built for norns **shield XL on Raspberry Pi 4**,
played with **3 keys + 3 encoders** — everything reachable without a grid; an **optional
grid** (monome, or launchpad-style MIDI grids via midigrid) adds a pad surface. No arc.
It records live stereo input
and mangles it with: multiple **time-stretch** algorithms (pitch-independent), **granular**
clouds, **tape-like** varispeed/looping, a **playback window** (slice start/stop), a
**filter** (LP/HP/BP), and an **FX** section (delay + reverb, each with its own dry/wet).
**Every parameter is MIDI-mappable.**

---

## The four hard invariants

1. **One engine file only.** A second `Engine_Mangler` class anywhere under `~/dust/code/`
   makes *every* norns script hang forever on "LOADING" (SuperCollider refuses to compile a
   duplicate class). Ship exactly one `lib/Engine_Mangler.sc`. Deploy with `rsync --delete`
   so an old copy can never linger on the device.

2. **Name consistency — change these four together, always:**
   | thing            | value                       |
   |------------------|-----------------------------|
   | SC class         | `Engine_Mangler`            |
   | SC file          | `lib/Engine_Mangler.sc`     |
   | Lua engine name  | `engine.name = 'Mangler'`   (norns prepends `Engine_`) |
   | SynthDef names   | namespaced, e.g. `\mangler_*` |

3. **No SuperCollider compiler in this dev environment.** The only static check available is
   `luac5.3 -p mangler.lua` (Lua syntax). SC correctness is **only** verifiable on hardware.
   Therefore every stage is **gated on-device** before the next one is written. Never dump
   untested SC in bulk.

4. **Every controllable value is a real param; params are the single source of truth.**
   Keys, encoders, and MIDI all drive `params:*`. This is also how MIDI works (see below).
   Held gestures are tracked in a global `held[]` table so a release on a different page
   still closes the gesture.

---

## MIDI is native — do not hand-roll it

norns auto-maps **every** parameter added via `params:add_control / add_taper / add_number /
add_option / add_binary` to MIDI-learn from the PARAMS menu, persisting it per-script in a
**PMAP** file (`data/mangler/mangler.pmap`). `add_separator / add_group / add_trigger /
add_text` are **not** mappable.

⇒ The rule that gives "MIDI for every parameter" for free:
- Make every knob a `add_control`/`add_taper`.
- Make every toggle (freeze, reverse, rec-arm) a `add_binary` or `add_option` — never a raw
  Lua boolean — so it is both key-toggleable and MIDI-mappable.
- Keys call `params:set/delta`; encoders call `params:delta`; MIDI maps to the same IDs.
  One source of truth, three drivers.

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

---

## norns Lua API gotchas (learned on hardware)

- **`params:get_name(i)` takes a numeric index ONLY** (`self.params[i]`, no id lookup).
  With a string id it indexes nil and throws. Use `params:lookup_param(id).name`.
  (`params:string / get / set / delta` DO accept string ids.)
- **An error inside `redraw()` shows as a frozen/black screen, not a crash.** The script
  still prints `<ok>`; the display just never reaches `screen.update()`. If the screen is
  stuck on "loading" or goes black, scroll maiden below `<ok>` for the Lua traceback.
- **`params:add_group` id must not collide with any param id.** Use the 3-arg form with a
  distinct id: `params:add_group("grp_mix", "mix", n)`.
- **System param ids are reserved — the system shares the script paramset.** Adding a param
  with a system id (e.g. `tape_level`, owned by the TAPE deck) prints "refusing to clobber"
  and the param is silently NOT added — which also desyncs the surrounding `add_group`
  count. Reserved (verified on hardware): `output_level, input_level, monitor_level,
  engine_level, softcut_level, tape_level, monitor_mode, headphone_gain, reverb, rev_*,
  compressor, comp_*, cut_input_*, clock_*, link_*`. mangler uses `cut_level` for the
  softcut path's level.
- **The ~60 system params (LEVELS/REVERB/COMPRESSOR/SOFTCUT/CLOCK) appearing in
  `params.count` is normal** — they are not leftovers from another script.
- **`context.in_b` is an ARRAY of two mono busses** (`in_b[0].index`, `in_b[1].index`);
  `out_b` is one stereo bus. `context.in_b.index` throws doesNotUnderstand inside alloc's
  fork → the doneCallback never fires → matron waits forever → the script's `init()` is
  never called → stuck on "loading" with NO error in the matron tab.
- **SC errors print in maiden's SC tab, not the matron tab.** A script hanging on
  "loading" with a clean matron log means: check the SC tab. The load chain is:
  script file runs → `engine.load(name, Script.init)` → SC alloc → doneCallback →
  `init()` → `norns.init_done` → screen handoff. A silent break before `init()` is
  almost always the engine failing in alloc.
- **Editing a `.sc` file requires SYSTEM > RESTART** (sclang must recompile the class
  library); reloading the script is not enough.
- **midi dispatch is dual-path: norns fires BOTH `midi.devices[id].event` (device
  level) and `midi.vports[port].event` (vport level) for the same message.** midigrid
  binds device-level; mangler's note input binds vport-level on all 16 slots — so a
  grid controller's pad note-ons reach both handlers unless filtered. mangler's
  `is_grid_vport()` skips the vport whose device midigrid claimed (compared by
  identity and by name against `gg.device`). Symptom when this breaks: every pad
  press also slams `pitch` to an extreme (raw launchpad note numbers are far from
  root 60 and clamp to the 0.25–4 spec edges).
- **`clock.lua:62 bad argument #1 to 'resume' (thread expected)`** is a system-level race
  (a clock timer fires for an already-dead coroutine, often on script reload) and wedges
  clock state until restart. It is not specific to one script, but: keep mangler's clock
  usage minimal, always `clock.cancel` in `cleanup`, and when this error appears, restart
  before drawing conclusions about whichever script loaded last. S0 uses no clocks at all.

---

## Workflow

```sh
# static check (only one available locally)
luac5.3 -p mangler.lua

# render every UI page to PNGs with NO hardware: tools/uisim/render_pages.lua
# stubs the norns env (including include(), so the lib/*.lua modules resolve
# from the repo), runs the real mangler.lua redraw code against a fake
# framebuffer, and drives a scripted performance (a take, a tape loop, FX).
# eyeball these before deploying any screen change — a redraw error on
# device is a silent black screen.
lua tools/uisim/render_pages.lua mangler.lua /tmp/shots base        # all pages + variants
lua tools/uisim/render_pages.lua mangler.lua /tmp/shots base empty  # empty-buffer state
python3 tools/uisim/pgm2png.py /tmp/shots/base_01_MIX.pgm mix.png 4 # PGM -> PNG, 4x

# single-file build: inlines lib/*.lua into dist/mangler_single.lua as
# IIFEs (proven byte-identical via the seeded render suite). the dist file
# is GENERATED — never edit it; rebuild after any lua change that ships.
lua tools/amalgamate.lua

# deploy to the norns (the repo IS the script; --delete kills stale engine copies)
rsync -av --delete --exclude='.git' ./ <norns>:~/dust/code/mangler/

# then on the norns: ;restart  (or reload the script), watch maiden for SC errors
```

**Screen design rules (hold these in every page):** brightness encodes
audibility — if a thing isn't sounding, its picture lies flat and dim (mode
OFF stills the ENG lane, the STRETCH texture, the particles, the playhead;
mix-0 FX pages go dormant). Each page parks its one defining number dim in
the top-right corner (yielding to the transient flash). An empty buffer is
an invitation, always in the same voice: "EMPTY - K2 REC". The page dots
cluster by signal family (source · shape · tape · fx). The STRETCH body
draws the active algorithm's own texture: grains / overlapped warp windows /
spectral columns.

**On-device gate per stage:** load the script, confirm no LOADING hang and no SC errors in
maiden, then run that stage's acceptance test in `doc/spec.md`. Only then write the next
stage. Update the **CURRENT STAGE** marker at the top of this file when a gate passes.
