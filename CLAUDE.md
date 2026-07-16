# CLAUDE.md — mangler

Agent manual for working on **mangler**, a norns live stereo sample-mangling instrument.
Read this first. It encodes the hard rules and the staged build order. Keep it current —
when a stage passes its on-device gate, move the **CURRENT STAGE** marker.

---

         ## CURRENT STAGE: **S21 (fingerprint 61) — ENGINE RESTART + count-61 gate STILL PENDING on device · NU-1..NU-4 UI redesign (doc/redesign.md) fully landed in Lua (renders + dist byte-verified 2026-07-16) — its on-device gate is also pending: save+reload, walk the nine pages, punch-law feel, erase arc, scene peek/◄, and the whole grid spine (grid code is sim-stubbed, device-only)**

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

**Engine deploy ritual (every time the .sc changes, no exceptions):**
1. replace file → verify on-disk with a REPL fingerprint grep
2. SYSTEM > RESTART (sclang only recompiles at startup — script reload is NOT enough)
3. load script → check `Engine.register_commands; count:` in maiden matches the
   expected fingerprint (S2 = 22, S4 = 30, S5/S6 = 31, S7 = 34, S8/S9 = 40,
   S10 = 50, S11 = 55, S15 = 58, S17 = 59, S21 = **61**). Wrong count = old engine still live.
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
