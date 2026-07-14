-- mangler — a live stereo sampler + mangler for norns
-- =====================================================
--
-- record external gear (synth, drum machine, anything line-level), then play
-- it back and mangle it. a fresh take loops back DRY — exactly what you
-- recorded. you ADD effects on top; they are never forced on.
--
--   IN -> REC -> [ DRONE  +  PADS ] -> FILTER -> DELAY -> REVERB -> OUT
--                  clean loop /        (filter open, drive/delay/reverb
--                  granular /           all start at zero — dial them in)
--                  stretch / spectral
--
-- the drone defaults to CLEAN PLAY — a straight loop of your take, exactly as
-- recorded. GRAIN / WARP / PV are mangling modes you switch on from STRETCH.
--
-- PLAY IT
--   LEVEL   set input so the meters peak just below the top
--   REC     K2, play a phrase, K2 — the window snaps to your take and loops it
--   STRETCH pick the drone engine (PLAY clean · GRAIN · WARP · PV) · GRAIN tunes it
--   DELAY / REVERB   start dry (mix 0); turn E2 up to add them
--   PADS    K1+K3 -> NOTES>PADS: MIDI/grid notes play 8 slices over the drone
--
-- CONTROLS   (3 keys + 3 encoders; every param is MIDI-mappable via PARAMS)
--   E1     select page          (hold K1: jump between page families)
--   E2/E3  the page's two knobs  (hold K1: the alt pair; footer shows values)
--   K1     alt / shift (hold)
--   K2/K3  the page's two actions (on banked pages K2 pages E2/E3 through
--          the parameter pairs — e.g. all of REVERB and GRAIN)
--   K1+K2  STOP / START: mute everything, press again for the exact mix back
--          (also SPACE on a typing keyboard · grid (8,2) · MIDI-map). global,
--          except pages whose alt-K2 has a job (GRAIN, TAPE, PADS)
--   K1+K3  DRY: throw the playback path clean — delay/reverb/shimmer/drive/
--          clouds-fb to zero, filter open. the take is always recorded clean;
--          DRY makes what you HEAR the bare sample (also grid (7,2)). global,
--          except GRAIN / TAPE / REVERB / PADS
--
-- PAGES   MIX  LEVEL  REC  WINDOW  GRAIN  STRETCH  TAPE  FILTER  DELAY  REVERB  PADS
--
-- NOTES   a MIDI keyboard (or USB typing keyboard, ableton-style: A-row =
--   white keys, W-row = black, Z/X = octave) retunes the sample chromatically;
--   with pad input on they trigger the PADS slices instead. PARAMS > keys.
--
-- GRID (optional, never required)   a monome grid — or a launchpad-style
--   controller via the midigrid library — adds transport toggles, window/loop
--   slice pads, and two piano octaves. see lib/mgrid.lua.
--
-- BEST SOUND (optional, auto-detected)   JPverb (sc3-plugins) reverb + MiClouds
--   (mi-UGens) granular are used when installed, else stock FreeVerb / GrainBuf.
--   guarded at build time — a missing plugin can never hang loading.
--
-- -----------------------------------------------------------------------------
-- this file is the orchestrator: state + params + key/encoder handlers. the
-- rest lives in lib/ modules (script-internal, NOT norns engines): mfont (pixel
-- font), mparticles (grain cloud), mtape (softcut tape), minput (midi/keyboard
-- notes), mgrid (grid surface), mpages (the screen). they share one `ctx` table
-- and params are the single source of truth. full design: doc/spec.md.

engine.name = "Mangler"

-- bring-up diagnostics: load milestones in maiden. If "script file executed"
-- appears without "init() called", the engine died in alloc — check the SC tab.
print("mangler: script file executed")

local mu = require "musicutil"

local min, max = math.min, math.max

-- ============================================================================
-- state (shared with the lib/ modules through ctx)
-- ============================================================================

local PAGES = {
  "MIX", "LEVEL", "REC", "WINDOW", "GRAIN", "STRETCH", "TAPE",
  "FILTER", "DELAY", "REVERB", "PADS", "MOTION", "SEQ",
}

local FPS = 15

local held_gesture = {}    -- held_gesture[n] = param id to zero when key n releases
local tape_arm_phase = 0   -- head position when tape rec was armed
local polls = {}
local redraw_clock

-- ============================================================================
-- helpers
-- ============================================================================

local function clamp(x, lo, hi)
  if x < lo then return lo elseif x > hi then return hi else return x end
end

local function ptoggle(id)
  params:set(id, params:get(id) == 0 and 1 or 0)
end

local function pget(id, default)
  if params.lookup[id] then return params:get(id) end
  return default
end

-- current window edges (sorted) and span
local function window_bounds()
  local a = pget("pos_start", 0)
  local b = pget("pos_end", 1)
  local lo, hi = min(a, b), max(a, b)
  return lo, hi, max(hi - lo, 0.001)
end

-- zoom-aware fine control: window/loop edge params scale their encoder
-- deltas by the current span, so steps shrink as the region tightens —
-- a wide-open window moves fast, a tight loop nudges by milliseconds.
-- (combined with the 0.002 quantum on these specs: ~10ms at the finest.)
local FINE_IDS = { pos_start = "win", pos_end = "win",
                   loop_start = "loop", loop_end = "loop" }

local function fine_delta(id, d)
  local kind = FINE_IDS[id]
  if not kind then return d end
  local span
  if kind == "win" then
    local _, _, s = window_bounds()
    span = s
  else
    span = math.abs(pget("loop_end", 1) - pget("loop_start", 0))
  end
  return d * clamp(math.max(span, 0.001) * 4, 0.08, 1)
end

-- ============================================================================
-- ctx: the one table the lib/ modules see
-- ============================================================================
-- helpers and stable table refs are bound by each module at init; the
-- mutable scalars below are written here (polls, handlers, the clock) and
-- read by the modules each call.

local ctx = {
  -- wiring
  pget = pget, ptoggle = ptoggle, clamp = clamp,
  window_bounds = window_bounds,
  PAGES = PAGES, FPS = FPS,
  -- ui state
  page = 1,
  alt = false,               -- K1 held
  held = {},                 -- held[n] = true while key n is down (page-independent)
  frame = 0,                 -- redraw frame counter (drives the REC blink)
  flash_id = nil,            -- transient top-right value readout
  flash_until = 0,
  -- engine/system signals
  play_phase = 0,            -- engine poll: normalized playhead in the buffer
  rec_phase = 0,             -- engine poll: normalized write-head position
  rec_arm_phase = 0,         -- write-head position when rec was armed
  rec_amp = 0,               -- engine poll: amplitude of what's being written
  amp_in = { 0, 0 },         -- system polls: live input amplitude L/R
  amp_out = { 0, 0 },        -- system polls: output amplitude L/R
  tape_phase = 0,            -- softcut phase event: tape head, normalized
  -- display-model flags (mpages paints them, mparticles gates on them)
  wave_any = false,          -- false until something audible lands in the buffer
  twave_any = false,
  -- S8 pad bank: 8 slice pads, per-pad type (0 grain / 1 slice), a screen
  -- cursor for standalone select/audition. shared by the PADS page + the
  -- MIDI/grid note routing (they map an incoming note to a pad index).
  pad_type = { [0] = 0, [1] = 0, [2] = 0, [3] = 0,
    [4] = 0, [5] = 0, [6] = 0, [7] = 0 },
  pad_cursor = 0,
  pad_n = 8,
  pad_held = {},             -- voice id -> true while sounding (matches note_off)
  rev_bank = 1,              -- S10: which REVERB param pair E2/E3 edit
  grain_bank = 1,            -- S11: which GRAIN param pair E2/E3 edit
  shimmer_mem = 0.6,         -- S15: last shimmer amount, for the SHMR bloom key
}

local Mfont = include "lib/mfont"
local Mparticles = include "lib/mparticles"
local Mtape = include "lib/mtape"
local Minput = include "lib/minput"
local Mgrid = include "lib/mgrid"
local Mmotion = include "lib/mmotion"
local Mseq = include "lib/mseq"
local Mpages = include "lib/mpages"

ctx.font = Mfont
ctx.particles = Mparticles
ctx.grid = Mgrid
ctx.motion = Mmotion
ctx.seq = Mseq

Mparticles.init(ctx)
Mtape.init(ctx)
Minput.init(ctx)
Mgrid.init(ctx)
Mmotion.init(ctx)
Mseq.init(ctx)
Mpages.init(ctx)

-- ============================================================================
-- gestures
-- ============================================================================
-- a momentary hold registers held_gesture[n] = param id on press; release
-- zeroes it here, page-independently, so switching pages mid-hold is safe.

local function gesture_release(n)
  local id = held_gesture[n]
  if id then
    params:set(id, 0)
    held_gesture[n] = nil
  end
end

-- page key actions + footer pill labels, ONE table: k2/k3 (and k2_alt/k3_alt
-- while K1 is held) each carry the pill label, an optional `lit` param id
-- (pill draws inverted while it reads 1), and the action. behavior and UI
-- come from the same definition, so they can never drift apart.
-- all actions drive params, never locals, so MIDI mappings stay in lockstep.
local KEYS = {
  MIX = {
    -- crossfade throws: snap hard to either deck; the encoder recovers
    k2 = { label = "ENG",
      act = function() params:set("mix", 0) end },
    k3 = { label = "TAPE",
      act = function() params:set("mix", 1) end },
    -- (the alt layer here is the global STOP/DRY pair — see key_def)
  },
  LEVEL = {
    -- unity resets: the system level params are dB tapers, 0 = 0 dB
    k2 = { label = "IN=0",
      act = function() params:set("input_level", 0) end },
    k3 = { label = "OUT=0",
      act = function() params:set("output_level", 0) end },
  },
  REC = {
    k2 = { label = "REC", lit = "rec",
      act = function() ptoggle("rec") end },
    k3 = { label = "FRZ", lit = "freeze",
      act = function() ptoggle("freeze") end },
  },
  WINDOW = {
    k2 = { label = "RST",
      act = function() params:set("pos_start", 0) params:set("pos_end", 1) end },
    -- reverse the scan direction — the classic throw-it-backwards move
    k3 = { label = "FLIP",
      act = function() params:set("scan", -params:get("scan")) end },
  },
  GRAIN = {
    -- S11: BANK pages E2/E3 through the granular attributes (like REVERB);
    -- MODE cycles the four Clouds modes. octave throws move to the alt layer.
    k2 = { label = "BANK",
      act = function() ctx.grain_next_bank() end },
    k2_alt = { label = "OCT-",
      act = function()
        params:set("pitch", math.max(params:get("pitch") * 0.5, 0.25))
      end },
    k3 = { label = "MODE",
      act = function()
        params:set("clouds_mode", (params:get("clouds_mode") % 4) + 1)
      end },
    k3_alt = { label = "OCT+",
      act = function()
        params:set("pitch", math.min(params:get("pitch") * 2, 4))
      end },
  },
  STRETCH = {
    -- K2 cycles OFF -> GRAIN -> WARP -> PV -> PLAY -> OFF; K3 spectral freeze
    k2 = { label = "MODE",
      act = function() params:set("mode", (params:get("mode") % 5) + 1) end },
    k3 = { label = "PVFZ", lit = "pv_freeze",
      act = function() ptoggle("pv_freeze") end },
  },
  TAPE = {
    k2 = { label = "REC", lit = "tape_rec",
      act = function() ptoggle("tape_rec") end },
    k3 = { label = "FRZ", lit = "tape_freeze",
      act = function() ptoggle("tape_freeze") end },
    -- alt layer: momentary reverse + clear
    k2_alt = { label = "REV", lit = "tape_reverse",
      act = function()
        params:set("tape_reverse", 1)
        held_gesture[2] = "tape_reverse"
      end },
    k3_alt = { label = "CLR",
      act = function()
        -- clear tape: wipe the loop and start over
        Mtape.clear_buffer()
        Mpages.clear_twave()
        params:set("tape_freeze", 0)
        params:set("loop_start", 0)
        params:set("loop_end", 1)
      end },
  },
  FILTER = {
    k2 = { label = "TYPE",
      act = function() params:set("filt_type", (params:get("filt_type") % 3) + 1) end },
    -- neutralize: open the filter as far as its type allows, kill the res
    k3 = { label = "OPEN",
      act = function()
        local ft = params:get("filt_type")
        params:set("cutoff", ft == 2 and 20 or (ft == 3 and 1000 or 20000))
        params:set("resonance", 0)
      end },
  },
  DELAY = {
    -- dub throws: INF pins the loop at the (soft-clipped) edge, KILL drops it
    k2 = { label = "INF",
      act = function() params:set("delay_fb", 0.95) end },
    k3 = { label = "KILL",
      act = function() params:set("delay_fb", 0) end },
  },
  REVERB = {
    -- BANK pages E2/E3 through the JPverb param pairs; KILL dries it out
    k2 = { label = "BANK",
      act = function() ctx.rev_next_bank() end },
    k3 = { label = "KILL",
      act = function() params:set("rev_mix", 0) end },
    -- S15 alt: SHMR blooms the shimmer on/off, remembering the last amount
    k3_alt = { label = "SHMR",
      act = function()
        if pget("shimmer", 0) > 0.001 then
          ctx.shimmer_mem = pget("shimmer", 0)
          params:set("shimmer", 0)
        else
          params:set("shimmer", ctx.shimmer_mem or 0.6)
        end
      end },
  },
  PADS = {
    -- K2 steps the cursor through the 8 pads; K1+K2 auditions the selected
    -- pad (momentary voice); K3 toggles the selected pad's grain/slice type
    k2 = { label = "SEL",
      act = function() ctx.pad_cursor = (ctx.pad_cursor + 1) % ctx.pad_n end },
    -- audition the cursor pad while held (fixed voice id 8, closed on any
    -- K2 release in the key handler so an alt-release can't strand it)
    k2_alt = { label = "PLAY",
      act = function() ctx.pad_trigger(8, ctx.pad_cursor, 1) end },
    k3 = { label = "TYPE",
      act = function()
        local i = ctx.pad_cursor
        ctx.pad_type[i] = (ctx.pad_type[i] == 0) and 1 or 0
      end },
    -- alt: route MIDI/grid notes to the pads (vs the drone) — the header
    -- flips NOTES>DRONE / NOTES>PADS
    k3_alt = { label = "ROUTE", lit = "pad_input",
      act = function() ptoggle("pad_input") end },
  },
  MOTION = {
    -- the gesture looper (S16). K2 arms recording of the param stream (a
    -- fresh loop from empty, or a punch-in overdub onto the running loop);
    -- K3 starts/stops playback. the page claims its alt slots (like GRAIN/
    -- TAPE/PADS) so K1+K2 = CLR-L (clear the selected lane) and K1+K3 = CLR
    -- (wipe all lanes); clearing leaves every param at its last value.
    k2 = { label = "REC", lit = "motion_rec",
      act = function() ptoggle("motion_rec") end },
    k3 = { label = "PLAY", lit = "motion_play",
      act = function() ptoggle("motion_play") end },
    k2_alt = { label = "CLR-L",
      act = function() ctx.motion.clear_lane() end },
    k3_alt = { label = "CLR",
      act = function() ctx.motion.clear_all() end },
  },
  SEQ = {
    -- the step sequencer (S18). K2 runs/stops the clock; K3 cycles which
    -- slice the active steps trigger. E2 sets the Euclidean hit count (it
    -- regenerates the pattern live). alt slots stay global STOP/DRY.
    k2 = { label = "PLAY", lit = "seq_play",
      act = function() ptoggle("seq_play") end },
    k3 = { label = "SLICE",
      act = function()
        params:set("seq_slice", (params:get("seq_slice") + 1) % ctx.pad_n)
      end },
  },
}

-- the key def addressed by key n on the current page, alt-aware. any alt
-- slot a page doesn't claim carries the GLOBAL transport pair instead:
-- K1+K2 = STOP (master mute) and K1+K3 = DRY (throw playback clean) — the
-- two rescue keys work on every page except where the alt layer already
-- has a job (GRAIN octaves, TAPE rev/clear, PADS play/route, REVERB shmr).
-- hold K1 anywhere: the footer pills SHOW which pair you have.
local ALT_STOP = { label = "STOP", lit = "stop_all",
  act = function() ptoggle("stop_all") end }
local ALT_DRY = { label = "DRY",
  act = function() ctx.fx_dry() end }
local function key_def(n)
  local defs = KEYS[PAGES[ctx.page]]
  if not defs then return nil end
  if n == 2 then
    if ctx.alt then return defs.k2_alt or ALT_STOP end
    return defs.k2
  end
  if ctx.alt then return defs.k3_alt or ALT_DRY end
  return defs.k3
end

-- S10: REVERB has more (JPverb) attributes than 4 encoder slots, so E2/E3
-- edit one PAIR at a time and K2 (BANK) pages through them. the KEYS.REVERB
-- BANK action rewrites ENC_MAP.REVERB[1]/[3] in place, so the footer + encoder
-- resolver keep working unchanged.
-- Banked editors (REVERB, GRAIN): each bank holds FOUR params — E2/E3 plus
-- their alt (hold K1) pair — so K2 pages through half as many banks and the
-- alt layer earns its keep. entry order: { E2, E3, E2_alt, E3_alt }.
local REVERB_BANKS = {
  { "rev_decay", "rev_mix", "rev_damp", "rev_size" },      -- SPACE
  { "rev_low", "rev_mid", "rev_high", "rev_early" },        -- TONE + diffusion
  { "rev_moddepth", "rev_modfreq", "rev_lowcut", "rev_highcut" },  -- MOD + cuts
  { "shimmer", "shimmer_pitch", "shimmer_tone", "rev_mix" },  -- SHIMMER (S15)
}
local GRAIN_BANKS = {
  { "size", "density", "spread", "clouds_tex" },
  { "clouds_pos", "clouds_fb", "grain_level", "clouds_lofi" },
}

-- which params each page's encoders address: { e2, e2_alt, e3, e3_alt }.
-- nil entries draw as "--" until the owning stage wires them.
local ENC_MAP = {
  MIX     = { "mix", "out_level", "sc_level", "cut_level" },
  -- LEVEL drives the SYSTEM params directly (they share the script paramset);
  -- never ADD params with these ids — referencing them is fine
  LEVEL   = { "input_level", "monitor_level", "output_level", "headphone_gain" },
  -- REC E3/E3-alt are the two "output -> buffer" controls: resample (bake the
  -- output into an armed take) and regen (S17 continuous self-resampling).
  -- dry_wet moved off REC (still reachable on FILTER + K1).
  REC     = { "rec_level", "pre_level", "resample", "regen" },
  WINDOW  = { "pos_start", "scan", "pos_end", "pos_jitter" },
  -- GRAIN/REVERB track the current bank; BANK (K2) rewrites all four slots.
  -- seed with bank 1. format {e2, e2_alt, e3, e3_alt}.
  GRAIN   = { "size", "spread", "density", "clouds_tex" },
  STRETCH = { "scan", "pitch", "warp_window", "warp_rand" },
  TAPE    = { "tape_rate", "tape_pre", "loop_start", "loop_end" },
  -- FILTER/REVERB gain an ALT layer (K1): the wet-path controls the filter
  -- itself can't expose (RLPF/RHPF/BPF are freq+rq only)
  FILTER  = { "cutoff", "dry_wet", "resonance", "grain_level" },
  DELAY   = { "delay_mix", "delay_time", "delay_fb", "drive" },
  REVERB  = { "rev_decay", "rev_damp", "rev_mix", "rev_size" },
  PADS    = { "voices", "voice_atk", "voice_rel", nil },
  -- MOTION (S16): E2 browses lanes, E3 is the global automation amount.
  -- no alt pair — the page claims K1 for CLR-L/CLR instead.
  MOTION  = { "motion_lane", nil, "motion_depth", nil },
  -- SEQ (S18): E2 Euclidean hits / tempo (alt), E3 length / division (alt).
  -- clock_tempo is a SYSTEM param (referenced, never added).
  SEQ     = { "seq_euclid", "clock_tempo", "seq_len", "seq_div" },
}

-- S10: page E2/E3 through the REVERB param banks (rewrites ENC_MAP.REVERB in
-- place so the footer/encoder resolver stay unchanged). called by KEYS.REVERB.
-- bank entry {E2,E3,E2alt,E3alt} maps to ENC_MAP {e2, e2_alt, e3, e3_alt}
function ctx.rev_next_bank()
  ctx.rev_bank = (ctx.rev_bank % #REVERB_BANKS) + 1
  local b = REVERB_BANKS[ctx.rev_bank]
  ENC_MAP.REVERB[1], ENC_MAP.REVERB[2], ENC_MAP.REVERB[3], ENC_MAP.REVERB[4] =
    b[1], b[3], b[2], b[4]
end

function ctx.grain_next_bank()
  ctx.grain_bank = (ctx.grain_bank % #GRAIN_BANKS) + 1
  local b = GRAIN_BANKS[ctx.grain_bank]
  ENC_MAP.GRAIN[1], ENC_MAP.GRAIN[2], ENC_MAP.GRAIN[3], ENC_MAP.GRAIN[4] =
    b[1], b[3], b[2], b[4]
end

-- the param id addressed by encoder n (2 or 3) on the current page, alt-aware.
local function enc_param(n)
  local m = ENC_MAP[PAGES[ctx.page]]
  if not m then return nil end
  if n == 2 then return ctx.alt and m[2] or m[1]
  elseif n == 3 then return ctx.alt and m[4] or m[3] end
  return nil
end

-- the footer draws what the encoders and keys currently address
ctx.enc_param = enc_param
ctx.key_def = key_def

-- ============================================================================
-- S8 polyphonic pad voices
-- ============================================================================
-- a pad's slice point + rate. 8 pads spread evenly across the buffer; rate
-- fixed at 1 for now (per-pad rate is a later knob). type is per-pad.
local function pad_pos(i) return (i + 0.5) / ctx.pad_n end

-- spawn/release a voice for pad `i` under a stable `id` (so note_off matches
-- the note_on that started it). z=1 press, z=0 release.
function ctx.pad_trigger(id, i, z)
  if z == 1 then
    if ctx.pad_held[id] and engine.note_off then engine.note_off(id) end
    if engine.note_on then
      engine.note_on(id, pad_pos(i), 1.0, ctx.pad_type[i] or 0)
    end
    ctx.pad_held[id] = i    -- store the pad index (0 is truthy) for the display
  elseif ctx.pad_held[id] then
    if engine.note_off then engine.note_off(id) end
    ctx.pad_held[id] = nil
  end
end

-- MIDI/grid note routing: in pad mode a note plays pad (note mod 8) as a
-- polyphonic voice (note_off on release); otherwise it retunes the mono
-- drone `pitch` exactly as before. `pitch` is the chromatic rate the caller
-- already computed for the drone path.
function ctx.route_note(id, pitch, pad_idx, z)
  if pget("pad_input", 0) == 1 then
    ctx.pad_trigger(id, pad_idx % ctx.pad_n, z)
  elseif z == 1 then
    params:set("pitch", pitch)
  end
end

-- release every sounding pad voice (leaving pad mode, cleanup, panic)
function ctx.pads_all_off()
  for id in pairs(ctx.pad_held) do
    if engine.note_off then engine.note_off(id) end
    ctx.pad_held[id] = nil
  end
end

-- DRY throw (MIX K1+K3, grid (7,2)): playback becomes the un-effected
-- sample — every "on top" color to zero (delay, reverb, shimmer, drive,
-- clouds feedback — the one wash the REVERB page can't kill) and the
-- filter thrown open (type-aware, same law as FILTER's OPEN key). the
-- take itself is always recorded clean; this clears the playback path.
function ctx.fx_dry()
  params:set("delay_mix", 0)
  params:set("rev_mix", 0)
  params:set("shimmer", 0)
  params:set("drive", 0)
  params:set("clouds_fb", 0)
  local ft = params:get("filt_type")
  params:set("cutoff", ft == 2 and 20 or (ft == 3 and 1000 or 20000))
  params:set("resonance", 0)
end

-- ============================================================================
-- params  (single source of truth: keys, encoders, and MIDI all drive these)
-- ============================================================================
-- every param's action sends the engine command of the same id, so the
-- engine command table and these ids must stay in lockstep (see the .sc file).

local function add_eng_control(id, name, spec)
  params:add_control(id, name, spec)
  params:set_action(id, function(v)
    if engine[id] then engine[id](v) end
  end)
end

local function add_eng_binary(id, name)
  params:add_binary(id, name, "toggle", 0)
  params:set_action(id, function(v)
    if engine[id] then engine[id](v) end
  end)
end

local function init_params()
  params:add_separator("mangler")

  -- group ids must differ from every param id, and the declared count MUST
  -- match the adds that follow (a refused/missing add corrupts the paramset)
  params:add_group("grp_mix", "mix", 5)
  params:add_control("mix", "eng <> tape",
    controlspec.new(0, 1, "lin", 0, 0.5, ""))
  params:set_action("mix", Mtape.update_mix)
  params:add_control("out_level", "out level",
    controlspec.new(0, 1.5, "lin", 0, 1.0, ""))
  params:set_action("out_level", Mtape.update_mix)
  params:add_control("sc_level", "eng level",
    controlspec.new(0, 1, "lin", 0, 1.0, ""))
  params:set_action("sc_level", Mtape.update_mix)
  -- id "tape_level" is RESERVED by the system TAPE deck; "cut_level" avoids it
  params:add_control("cut_level", "tape level",
    controlspec.new(0, 1, "lin", 0, 1.0, ""))
  params:set_action("cut_level", Mtape.update_mix)
  -- master transport: STOP chokes both decks at the one place their levels
  -- are computed (update_mix), so START restores the exact mix. everything
  -- keeps running silently — mode, loops, heads — and held pad voices are
  -- released. MIDI-map it for a stop pedal; SPACE on a typing keyboard and
  -- grid (8,2) drive it too.
  params:add_binary("stop_all", "stop all", "toggle", 0)
  params:set_action("stop_all", function(v)
    if v == 1 then ctx.pads_all_off() end
    Mtape.update_mix()
  end)

  params:add_group("grp_rec", "rec", 7)
  add_eng_binary("rec", "record")
  -- when capture stops, snap the window to the take just recorded so playback
  -- immediately loops what you played — not a 60s window of mostly silence
  params:set_action("rec", function(v)
    if engine.rec then engine.rec(v) end
    if v == 1 then
      ctx.rec_arm_phase = ctx.rec_phase
    elseif ctx.rec_phase > ctx.rec_arm_phase + 0.005 then
      params:set("pos_start", ctx.rec_arm_phase)
      params:set("pos_end", ctx.rec_phase)
    elseif ctx.rec_phase < ctx.rec_arm_phase - 0.005 then
      -- the write head wrapped past the buffer end mid-take. a wrapped
      -- window (start > end) would be SORTED into the wrong slice by
      -- window_bounds, so fall back to the whole buffer — the take is in
      -- there, just split across the seam. (proper wrap-around windows
      -- need engine support.)
      params:set("pos_start", 0)
      params:set("pos_end", 1)
    end
  end)
  add_eng_control("rec_level", "rec level",
    controlspec.new(0, 1, "lin", 0, 1.0, ""))
  add_eng_control("pre_level", "overdub",
    controlspec.new(0, 1, "lin", 0, 0.0, ""))
  add_eng_binary("freeze", "freeze")
  add_eng_control("dry_wet", "dry/wet",
    controlspec.new(0, 1, "lin", 0, 0.5, ""))
  add_eng_control("resample", "resample (in<>out)",
    controlspec.new(0, 1, "lin", 0, 0.0, ""))
  -- S17 self-resampling: continuous feedback of the processed OUTPUT back into
  -- the record buffer (Basinski-style regenerative decay). 0 = off (a fresh
  -- take stays dry). manual rec + freeze suspend it; engine-side it's a bounded
  -- convex crossfade so it can't run away.
  add_eng_control("regen", "regen (self-resample)",
    controlspec.new(0, 1, "lin", 0, 0.0, ""))

  params:add_group("grp_window", "window", 4)
  -- default controlspec quantum is 0.01 = 1% per click = 600ms of a 60s
  -- buffer: way too coarse to set a loop. 0.002 base + fine_delta's span
  -- scaling in enc() gets down to ~10ms nudges on a tight window.
  local pos_start_spec = controlspec.new(0, 1, "lin", 0, 0.0, "")
  pos_start_spec.quantum = 0.002
  add_eng_control("pos_start", "win start", pos_start_spec)
  local pos_end_spec = controlspec.new(0, 1, "lin", 0, 1.0, "")
  pos_end_spec.quantum = 0.002
  add_eng_control("pos_end", "win end", pos_end_spec)
  add_eng_control("scan", "scan rate",
    controlspec.new(-2, 2, "lin", 0, 1.0, "x"))
  add_eng_control("pos_jitter", "jitter",
    controlspec.new(0, 1, "lin", 0, 0.0, ""))

  params:add_group("grp_grain", "grain", 9)
  add_eng_control("size", "size",
    controlspec.new(0.01, 0.5, "exp", 0, 0.1, "s"))
  add_eng_control("density", "density",
    controlspec.new(1, 200, "exp", 0, 20, "hz"))
  -- pitch is playable chromatically: MIDI notes set it (see grp_keys), and
  -- pitch_quant snaps encoder/CC moves to semitones on the way to the engine
  -- (the param keeps the raw value; only the engine command is quantized)
  params:add_control("pitch", "pitch",
    controlspec.new(0.25, 4, "exp", 0, 1.0, "x"),
    function(p)
      local v = p:get()
      if pget("pitch_quant", 0) == 1 then
        return string.format("%+d st", util.round(12 * math.log(v, 2)))
      end
      return string.format("%.2f x", v)
    end)
  params:set_action("pitch", function(v)
    if pget("pitch_quant", 0) == 1 then
      v = 2 ^ (util.round(12 * math.log(v, 2)) / 12)
    end
    if engine.pitch then engine.pitch(v) end
  end)
  add_eng_control("spread", "spread",
    controlspec.new(0, 1, "lin", 0, 0.5, ""))
  add_eng_control("pan", "pan",
    controlspec.new(-1, 1, "lin", 0, 0.0, ""))
  add_eng_control("grain_level", "grain level",
    controlspec.new(0, 1.5, "lin", 0, 1.0, ""))
  -- S7 granular character: per-grain size jitter + detune spread (both
  -- continuous from 0 = off), and a 3-way grain-envelope shape. shape is
  -- an option (engine wants 0/1/2, norns options are 1-based, so -1 in the
  -- action — same trick as `mode`).
  add_eng_control("grain_jitter", "grain jitter",
    controlspec.new(0, 1, "lin", 0, 0.0, ""))
  add_eng_control("grain_pitch_spread", "pitch spread",
    controlspec.new(0, 12, "lin", 0, 0.0, "st"))
  params:add_option("grain_shape", "grain shape", { "HANN", "WELCH", "PERC" }, 1)
  params:set_action("grain_shape", function(v)
    if engine.grain_shape then engine.grain_shape(v - 1) end
  end)

  -- S11: MiClouds granular controls (GRAIN mode uses the Clouds voice when
  -- mi-UGens are installed; on the GrainBuf fallback these are stored but
  -- ignored — same guarded philosophy as the JPverb-only reverb params). the
  -- shared size/density/spread/pitch already remap to Clouds; these are the
  -- Clouds-specific attributes. edited on the GRAIN page + PARAMS.
  params:add_group("grp_clouds", "clouds", 5)
  add_eng_control("clouds_pos", "grain position",
    controlspec.new(0, 1, "lin", 0, 0.5, ""))
  add_eng_control("clouds_tex", "grain texture",
    controlspec.new(0, 1, "lin", 0, 0.5, ""))
  add_eng_control("clouds_fb", "grain feedback",
    controlspec.new(0, 1, "lin", 0, 0.0, ""))
  params:add_option("clouds_mode", "clouds mode",
    { "GRANULAR", "STRETCH", "LOOP", "SPECTRAL" }, 1)
  params:set_action("clouds_mode", function(v)
    if engine.clouds_mode then engine.clouds_mode(v - 1) end
  end)
  add_eng_control("clouds_lofi", "grain lofi",
    controlspec.new(0, 1, "lin", 0, 0.0, ""))

  params:add_group("grp_stretch", "stretch", 5)
  -- mode swaps the playback synth in the engine: only the active algorithm
  -- costs CPU; OFF frees the SC voice entirely
  -- S14: PLAY (clean straight loop = the exact recorded sample) is the
  -- DEFAULT so a fresh take plays back untouched; GRAIN/WARP/PV are switched
  -- on for mangling. appended (not reordered) so 1..4 keep their meaning.
  params:add_option("mode", "mode", { "OFF", "GRAIN", "WARP", "PV", "PLAY" }, 5)
  params:set_action("mode", function(v)
    if engine.mode then engine.mode(v - 1) end
  end)
  add_eng_control("warp_window", "warp window",
    controlspec.new(0.05, 0.5, "exp", 0, 0.25, "s"))
  params:add_number("warp_overlaps", "warp overlaps", 1, 8, 4)
  params:set_action("warp_overlaps", function(v)
    if engine.warp_overlaps then engine.warp_overlaps(v) end
  end)
  add_eng_control("warp_rand", "warp rand",
    controlspec.new(0, 1, "lin", 0, 0.0, ""))
  add_eng_binary("pv_freeze", "pv freeze")

  params:add_group("grp_tape", "tape", 8)
  params:add_binary("tape_rec", "tape record", "toggle", 0)
  -- mirror the SC side's workflow: arming with no overdub opens the loop to
  -- the full tape for a fresh take; stopping snaps the loop around the take
  -- and jumps the head to its start, so it plays back tight immediately
  params:set_action("tape_rec", function(v)
    if v == 1 then
      if pget("tape_pre", 0) == 0
          and (pget("loop_end", 1) - pget("loop_start", 0)) < 0.99 then
        params:set("loop_start", 0)
        params:set("loop_end", 1)
      end
      tape_arm_phase = ctx.tape_phase
    elseif ctx.tape_phase > tape_arm_phase + 0.005 then
      params:set("loop_start", tape_arm_phase)
      params:set("loop_end", ctx.tape_phase)
      Mtape.jump_to(tape_arm_phase)
    elseif ctx.tape_phase < tape_arm_phase - 0.005 then
      -- head wrapped past the tape end mid-take: softcut loops can't cross
      -- the seam, so keep the full tape rather than snapping a wrong slice
      params:set("loop_start", 0)
      params:set("loop_end", 1)
    end
    Mtape.update_tape_rec()
  end)
  params:add_control("tape_rate", "tape rate",
    controlspec.new(-2, 2, "lin", 0, 1.0, "x"))
  params:set_action("tape_rate", Mtape.update_tape_rate)
  params:add_binary("tape_reverse", "tape reverse", "momentary", 0)
  params:set_action("tape_reverse", Mtape.update_tape_rate)
  -- same fine quantum + span-scaled deltas as the window edges
  local loop_start_spec = controlspec.new(0, 1, "lin", 0, 0.0, "")
  loop_start_spec.quantum = 0.002
  params:add_control("loop_start", "loop start", loop_start_spec)
  params:set_action("loop_start", Mtape.update_tape_loop)
  local loop_end_spec = controlspec.new(0, 1, "lin", 0, 1.0, "")
  loop_end_spec.quantum = 0.002
  params:add_control("loop_end", "loop end", loop_end_spec)
  params:set_action("loop_end", Mtape.update_tape_loop)
  params:add_control("tape_pre", "tape overdub",
    controlspec.new(0, 1, "lin", 0, 0.0, ""))
  params:set_action("tape_pre", Mtape.update_tape_rec)
  params:add_binary("tape_freeze", "tape freeze", "toggle", 0)
  params:set_action("tape_freeze", Mtape.update_tape_rec)
  params:add_control("tape_fade", "tape fade",
    controlspec.new(0.001, 0.5, "exp", 0, 0.05, "s"))
  params:set_action("tape_fade", Mtape.set_fade)

  params:add_group("grp_filter", "filter", 4)
  params:add_option("filt_type", "filter type", { "LP", "HP", "BP" }, 1)
  params:set_action("filt_type", function(v)
    if engine.filt_type then engine.filt_type(v - 1) end
  end)
  add_eng_control("cutoff", "cutoff",
    controlspec.new(20, 20000, "exp", 0, 20000, "hz"))
  add_eng_control("resonance", "resonance",
    controlspec.new(0, 1, "lin", 0, 0.0, ""))
  -- post-filter tanh saturation with makeup (S5): louder AND dirtier up
  add_eng_control("drive", "drive",
    controlspec.new(0, 1, "lin", 0, 0.0, ""))

  params:add_group("grp_delay", "delay", 3)
  add_eng_control("delay_time", "delay time",
    controlspec.new(0.01, 1, "exp", 0, 0.3, "s"))
  add_eng_control("delay_fb", "feedback",
    controlspec.new(0, 0.95, "lin", 0, 0.3, ""))
  add_eng_control("delay_mix", "delay mix",
    controlspec.new(0, 1, "lin", 0, 0.0, ""))

  -- S10: the reverb is JPverb's FULL attribute set (guarded → FreeVerb
  -- fallback in the engine). every knob maps to a real JPverb arg — nothing
  -- hardcoded. edited on the REVERB page in banks (K2 pages through them).
  params:add_group("grp_reverb", "reverb", 15)
  add_eng_control("rev_decay", "reverb decay",
    controlspec.new(0.1, 30, "exp", 0, 2.0, "s"))
  add_eng_control("rev_damp", "reverb damp",
    controlspec.new(0, 1, "lin", 0, 0.3, ""))
  add_eng_control("rev_size", "reverb size",
    controlspec.new(0.5, 5, "lin", 0, 1.0, ""))
  add_eng_control("rev_early", "early diffusion",
    controlspec.new(0, 1, "lin", 0, 0.7, ""))
  add_eng_control("rev_moddepth", "mod depth",
    controlspec.new(0, 1, "lin", 0, 0.1, ""))
  add_eng_control("rev_modfreq", "mod freq",
    controlspec.new(0, 10, "lin", 0, 2.0, "hz"))
  add_eng_control("rev_low", "low decay",
    controlspec.new(0, 1, "lin", 0, 1.0, ""))
  add_eng_control("rev_mid", "mid decay",
    controlspec.new(0, 1, "lin", 0, 1.0, ""))
  add_eng_control("rev_high", "high decay",
    controlspec.new(0, 1, "lin", 0, 1.0, ""))
  add_eng_control("rev_lowcut", "low crossover",
    controlspec.new(20, 2000, "exp", 0, 500, "hz"))
  add_eng_control("rev_highcut", "high crossover",
    controlspec.new(200, 20000, "exp", 0, 2000, "hz"))
  add_eng_control("rev_mix", "reverb mix",
    controlspec.new(0, 1, "lin", 0, 0.0, ""))
  -- S15 shimmer: pitch-shifted reverb feedback (climbs in octaves into a pad)
  add_eng_control("shimmer", "shimmer",
    controlspec.new(0, 1, "lin", 0, 0.0, ""))
  add_eng_control("shimmer_pitch", "shimmer pitch",
    controlspec.new(-12, 24, "lin", 1, 12, "st"))
  add_eng_control("shimmer_tone", "shimmer tone",
    controlspec.new(500, 12000, "exp", 0, 4500, "hz"))

  -- S8 polyphonic voices: the per-note/per-pad layer that coexists with the
  -- drone. `pad_input` reroutes MIDI + grid note-pads to voices instead of
  -- the mono drone pitch (default OFF = existing behavior). voices = poly
  -- cap (oldest-steal in the engine), voice_atk/voice_rel shape each note.
  params:add_group("grp_voice", "voices", 4)
  params:add_binary("pad_input", "pad input", "toggle", 0)
  params:set_action("pad_input", function(v)
    if v == 0 then ctx.pads_all_off() end   -- don't strand voices on switch
  end)
  params:add_number("voices", "poly voices", 1, 16, 8)
  params:set_action("voices", function(v)
    if engine.voices then engine.voices(v) end
  end)
  add_eng_control("voice_atk", "voice attack",
    controlspec.new(0.001, 1, "exp", 0, 0.005, "s"))
  add_eng_control("voice_rel", "voice release",
    controlspec.new(0.01, 4, "exp", 0, 0.6, "s"))

  -- chromatic note input (MIDI notes + typing keyboard): all of it drives
  -- the same `pitch` param as the encoder and any mapped CC, in lockstep
  params:add_group("grp_keys", "keys", 5)
  params:add_binary("keys_enable", "note input", "toggle", 1)
  params:add_number("midi_channel", "midi channel", 0, 16, 0,
    function(p)
      local v = p:get()
      return v == 0 and "any" or tostring(v)
    end)
  params:add_number("root_note", "root note", 0, 127, 60,
    function(p) return mu.note_num_to_name(p:get(), true) end)
  -- typing-keyboard octave (Z/X); MIDI keyboards shift octaves themselves
  params:add_number("kb_octave", "keys octave", -3, 3, 0,
    function(p) return string.format("%+d", p:get()) end)
  params:add_binary("pitch_quant", "pitch quantize", "toggle", 0)
  params:set_action("pitch_quant", function()
    -- re-send pitch so the engine snaps (or unsnaps) immediately
    params:lookup_param("pitch"):bang()
  end)

  -- S16 gesture looper: records the param stream (MOTION_IDS) and replays it
  -- (see lib/mmotion). rec/play are binaries so a footswitch can punch overdubs
  -- and start/stop the loop; lane/depth drive the MOTION page. all Lua-only —
  -- no engine command, so the fingerprint is unchanged.
  params:add_group("grp_motion", "motion", 4)
  params:add_binary("motion_rec", "motion record", "toggle", 0)
  params:set_action("motion_rec", function(v) ctx.motion.set_armed(v == 1) end)
  params:add_binary("motion_play", "motion play", "toggle", 0)
  params:set_action("motion_play", function(v) ctx.motion.set_playing(v == 1) end)
  params:add_number("motion_lane", "motion lane", 0, 16, 0,
    function(p)
      local ids = ctx.motion.lane_ids
      local n = #ids
      local v = math.min(p:get(), n)
      if n == 0 or v == 0 then return "-" end
      return ids[v]
    end)
  params:add_control("motion_depth", "motion depth",
    controlspec.new(0, 1, "lin", 0, 1.0, ""))

  -- S18 step sequencer: a clock-synced Euclidean sequencer that triggers the
  -- PADS slice one-shots (see lib/mseq). all Lua-only (drives engine.note_one_
  -- shot) — no engine command, so the fingerprint is unchanged. seq_play is a
  -- binary (MIDI-map it to a footswitch); seq_euclid/seq_len regen the pattern.
  params:add_group("grp_seq", "sequencer", 5)
  params:add_binary("seq_play", "seq play", "toggle", 0)
  params:set_action("seq_play", function(v) ctx.seq.set_playing(v == 1) end)
  params:add_option("seq_div", "seq division", Mseq.DIV_LABELS, 2)
  params:add_number("seq_euclid", "seq euclid hits", 0, 16, 0)
  params:set_action("seq_euclid", function() ctx.seq.regen() end)
  params:add_number("seq_len", "seq length", 1, 16, 16)
  params:set_action("seq_len", function() ctx.seq.regen() end)
  params:add_number("seq_slice", "seq slice", 0, 7, 0)

  -- PSETs persist the tape audio too: PARAMS > PSET > SAVE/LOAD/DELETE
  -- round-trip the softcut buffers (see mtape). the granular engine's
  -- record buffer would need a matching save command on the SC side to
  -- round-trip as well — until then, only the tape survives a restart.
  params.action_write = function(filename, name, number)
    Mtape.pset_write(number)
  end
  params.action_read = function(filename, silent, number)
    Mtape.pset_read(number)
  end
  params.action_delete = function(filename, name, number)
    Mtape.pset_delete(number)
  end

  params:bang()
end

-- ============================================================================
-- norns callbacks
-- ============================================================================

function init()
  print("mangler: init() called")
  init_params()
  Mtape.init_tape()
  Minput.init_midi()
  Mgrid.connect()
  print("mangler: init() done, params built")

  -- the norns SYSTEM aux reverb sits after the engine and colors everything;
  -- if another script left it on, "dry" playback isn't — say so at load
  if params.lookup["reverb"]
      and tostring(params:string("reverb")):lower() ~= "off" then
    print("mangler: NOTE — the SYSTEM reverb is ON; it adds reverb mangler"
      .. " does not control (turn it off under PARAMS > REVERB)")
  end

  local function watch(name, fn)
    -- poll.set returns nil when the engine doesn't expose the poll (stale
    -- compiled engine after a deploy without restart) — warn, don't crash
    local p = poll.set(name, fn)
    if p == nil then
      print("mangler: poll '" .. name .. "' missing — old engine? RESTART needed")
      return
    end
    p.time = 1 / FPS
    p:start()
    polls[#polls + 1] = p
  end
  watch("play_phase", function(v) ctx.play_phase = v end)
  watch("rec_phase", function(v) ctx.rec_phase = v end)
  watch("rec_amp", function(v) ctx.rec_amp = v end)
  watch("amp_in_l", function(v) ctx.amp_in[1] = v end)
  watch("amp_in_r", function(v) ctx.amp_in[2] = v end)
  watch("amp_out_l", function(v) ctx.amp_out[1] = v end)
  watch("amp_out_r", function(v) ctx.amp_out[2] = v end)

  redraw_clock = clock.run(function()
    while true do
      clock.sleep(1 / FPS)
      ctx.frame = ctx.frame + 1
      Mpages.update_wave()
      Mpages.update_tape_wave()
      Mparticles.update()
      Mmotion.tick()   -- S16: advance + replay the gesture loop
      -- never draw over the system menu; the grid stays live inside it
      if norns.menu.status() == false then redraw() end
      Mgrid.redraw()
    end
  end)

  redraw()
  Mgrid.redraw()
end

function cleanup()
  for _, p in ipairs(polls) do p:stop() end
  if redraw_clock then clock.cancel(redraw_clock) end
  ctx.pads_all_off()   -- release any held pad voices before teardown
  Minput.cleanup()
  Mgrid.cleanup()
  Mtape.cleanup()
  Mmotion.cleanup()    -- gesture looper teardown (no-op; polling needs none)
  Mseq.cleanup()       -- cancel the sequencer clock (norns clock hygiene)
end

-- K1+E1 leaps between the page families the header dots draw: source
-- (MIX·LEVEL·REC) · shape (WINDOW·GRAIN·STRETCH) · TAPE · fx · motion · seq
local PAGE_GROUPS = { 1, 4, 7, 8, 12, 13 }

function enc(n, d)
  if n == 1 then
    if ctx.alt then
      local gi = 1
      for i = 1, #PAGE_GROUPS do
        if ctx.page >= PAGE_GROUPS[i] then gi = i end
      end
      ctx.page = PAGE_GROUPS[clamp(gi + (d > 0 and 1 or -1), 1, #PAGE_GROUPS)]
    else
      ctx.page = clamp(ctx.page + d, 1, #PAGES)
    end
  else
    local id = enc_param(n)
    -- params.lookup guard: a missing param must not throw
    if id and params.lookup[id] then
      params:delta(id, fine_delta(id, d))
      -- mark the param actively-turning: its footer knob fills for ~1.2s
      ctx.flash_id, ctx.flash_until = id, ctx.frame + math.floor(FPS * 1.2)
    end
  end
  redraw()
end

function key(n, z)
  if n == 1 then
    ctx.alt = (z == 1)
  else
    ctx.held[n] = (z == 1)
    if z == 1 then
      local def = key_def(n)
      if def and def.act then def.act() end
    else
      gesture_release(n)
      -- close the PADS-page audition voice (id 8) on K2 release, whatever
      -- the alt state is now — momentary holds must never strand a voice
      if n == 2 and ctx.pad_held[8] then ctx.pad_trigger(8, 0, 0) end
    end
  end
  redraw()
end

function redraw()
  Mpages.redraw()
end
