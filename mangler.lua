-- mangler
-- live stereo sample-mangling instrument for external gear
-- (synth, drum machine, anything line-level)
--
-- 3 keys + 3 encoders. every parameter is MIDI-mappable (PARAMS menu).
--
-- E1 : page select
-- E2 : primary param   (hold K1 -> alt param)
-- E3 : secondary param (hold K1 -> alt param)
-- K1 : alt / shift modifier (hold)
-- K2 : primary action
-- K3 : secondary action
--
-- STAGE 4 — record + granular + window + time-stretch modes + softcut TAPE
-- + filter/delay/reverb. See SPEC/spec.md.
--
-- MIDI notes play the sample chromatically: note-ons retune `pitch`
-- relative to the root note (PARAMS > keys). a USB typing keyboard works
-- too: ableton-style musical typing (A-row = white keys, W-row = black,
-- Z/X = octave down/up).
--
-- a grid is optional, never required: a monome grid — or a launchpad-style
-- MIDI grid controller via the midigrid library — adds note pads, window/
-- loop slice pads, and transport toggles (see the grid section below).

engine.name = "Mangler"

-- bring-up diagnostics: load milestones in maiden. If "script file executed"
-- appears without "init() called", the engine died in alloc — check the SC tab.
print("mangler: script file executed")

local sc = require "softcut"  -- the TAPE path: parallel ADC tap, own CPU core
local mu = require "musicutil"

-- the redraw path runs at 15fps on a core shared with the audio engine:
-- hot loops read these as registers instead of two table hops per call
local floor, sin, cos = math.floor, math.sin, math.cos
local abs, sqrt, min, max = math.abs, math.sqrt, math.min, math.max
local random, log = math.random, math.log
local sbyte = string.byte

-- ============================================================================
-- state
-- ============================================================================

local PAGES = {
  "MIX", "LEVEL", "REC", "WINDOW", "GRAIN", "STRETCH", "TAPE",
  "FILTER", "DELAY", "REVERB",
}
local page = 1
local alt = false          -- K1 held
local held = {}            -- held[n] = true while key n is down (global, page-independent)
local held_gesture = {}    -- held_gesture[n] = param id to zero when key n releases

local FPS = 15
local frame = 0            -- redraw frame counter (drives the REC blink)
local play_phase = 0       -- engine poll: normalized playhead in the buffer
local rec_phase = 0        -- engine poll: normalized write-head position
local rec_arm_phase = 0    -- write-head position when rec was armed
local rec_amp = 0          -- engine poll: amplitude of what's being written
local amp_in = { 0, 0 }    -- system polls: live input amplitude L/R
local amp_out = { 0, 0 }   -- system polls: output amplitude L/R
local tape_phase = 0       -- softcut phase event: tape head, normalized
local tape_arm_phase = 0   -- head position when tape rec was armed
local polls = {}
local redraw_clock

local TAPE_LEN = 60        -- seconds of softcut buffer used by the tape loop

local BAND_T, BAND_B = 15, 40  -- visualization band (screen + particle bounds)

local reel_angle = 0           -- TAPE page reel rotation, driven by tape rate
local delay_hop = 0            -- DELAY page ball position, in hops (1 hop = 1 repeat)
local flash_id, flash_until = nil, 0  -- transient top-right value readout

-- grid (optional): native monome or a midi grid controller via midigrid.
-- declared up here so the midi note-input filter can see them — it must
-- ignore the grid controller's own note messages (see the grid section).
local gg                     -- connected grid; no device attached until one is
local have_midigrid = false  -- true when the midigrid library is standing in

-- waveform display: 128 amplitude bins over the buffer, filled as the write
-- head passes; pre_level decides how much of the old picture survives overdub
local wave = {}
for i = 1, 128 do wave[i] = 0 end
local wave_bin = 0
local wave_any = false  -- false until something audible lands in the buffer

-- same idea for the tape loop: bins indexed by the tape head while recording
local twave = {}
for i = 1, 128 do twave[i] = 0 end
local twave_bin = 0
local twave_any = false

-- grain particles (visual only): spawned at the playhead at ~density rate,
-- spread by jitter, lifetime scaled by grain size. slots are pooled and
-- kept in spawn order, so steady-state spawning never allocates
local PARTICLE_MAX = 32
local particles = {}
local particles_n = 0
for i = 1, PARTICLE_MAX do
  particles[i] = { x = 0, y = 0, lvl = 0, decay = 0 }
end
local spawn_acc = 0

-- which params each page's encoders address: { e2, e2_alt, e3, e3_alt }.
-- nil entries draw as "--" until the owning stage wires them.
local ENC_MAP = {
  MIX     = { "mix", "out_level", "sc_level", "cut_level" },
  -- LEVEL drives the SYSTEM params directly (they share the script paramset);
  -- never ADD params with these ids — referencing them is fine
  LEVEL   = { "input_level", "monitor_level", "output_level", "headphone_gain" },
  REC     = { "rec_level", "pre_level", "dry_wet", "resample" },
  WINDOW  = { "pos_start", "scan", "pos_end", "pos_jitter" },
  GRAIN   = { "size", "spread", "density", "grain_level" },
  STRETCH = { "scan", "pitch", "warp_window", "warp_rand" },
  TAPE    = { "tape_rate", "tape_pre", "loop_start", "loop_end" },
  FILTER  = { "cutoff", nil, "resonance", nil },
  DELAY   = { "delay_mix", "delay_time", "delay_fb", nil },
  REVERB  = { "rev_size", nil, "rev_mix", nil },
}

-- ============================================================================
-- helpers
-- ============================================================================

local function clamp(x, lo, hi)
  if x < lo then return lo elseif x > hi then return hi else return x end
end

-- the param id addressed by encoder n (2 or 3) on the current page, alt-aware.
local function enc_param(n)
  local m = ENC_MAP[PAGES[page]]
  if not m then return nil end
  if n == 2 then return alt and m[2] or m[1]
  elseif n == 3 then return alt and m[4] or m[3] end
  return nil
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
-- mix + tape plumbing (defined before params so actions can close over them)
-- ============================================================================

-- MIX page, now real: `mix` crossfades SC engine <-> tape, out_level masters
-- both, each side keeps its own trim. center keeps both at full trim.
local function update_mix()
  local mixv = pget("mix", 0.5)
  local out = pget("out_level", 1)
  local sc_l = pget("sc_level", 1) * math.min(1, 2 * (1 - mixv)) * out
  local tp_l = pget("cut_level", 1) * math.min(1, 2 * mixv) * out
  if engine.level then engine.level(sc_l) end
  sc.level(1, tp_l)
  sc.level(2, tp_l)
end

-- apply identical settings to both tape voices (1 = L, 2 = R)
local function tape_set(fn)
  fn(1)
  fn(2)
end

local function update_tape_rate()
  local r = pget("tape_rate", 1) * (pget("tape_reverse", 0) == 1 and -1 or 1)
  tape_set(function(v) sc.rate(v, r) end)
end

-- rec/freeze/pre interact: freeze stops capture and holds the loop at full
-- regeneration; otherwise rec gates capture and tape_pre sets the overdub
local function update_tape_rec()
  local frozen = pget("tape_freeze", 0) == 1
  local rec_on = pget("tape_rec", 0) == 1 and not frozen
  tape_set(function(v)
    sc.rec_level(v, rec_on and 1 or 0)
    sc.pre_level(v, frozen and 1 or pget("tape_pre", 0))
    sc.rec(v, rec_on and 1 or 0)
  end)
end

local function update_tape_loop()
  local a = pget("loop_start", 0) * TAPE_LEN
  local b = pget("loop_end", 1) * TAPE_LEN
  local lo, hi = math.min(a, b), math.max(a, b)
  if hi - lo < 0.1 then hi = lo + 0.1 end
  tape_set(function(v)
    sc.loop_start(v, lo)
    sc.loop_end(v, hi)
  end)
end

local function init_tape()
  audio.level_adc_cut(1)   -- parallel ADC tap into softcut
  audio.level_eng_cut(0)   -- engine does NOT feed softcut (resample is SC-side)
  audio.level_cut(1)       -- softcut master out: persists across scripts, force up
  sc.buffer_clear()
  for v = 1, 2 do
    sc.enable(v, 1)
    sc.buffer(v, v)
    sc.pan(v, v == 1 and -1 or 1)
    sc.play(v, 1)
    sc.loop(v, 1)
    sc.position(v, 0)
    sc.fade_time(v, pget("tape_fade", 0.05))
    sc.level_slew_time(v, 0.05)
    sc.rate_slew_time(v, 0.05)
    -- force the filter sections fully open: their defaults can mute the voice
    sc.pre_filter_dry(v, 1.0)
    sc.pre_filter_lp(v, 0.0)
    sc.post_filter_dry(v, 1.0)
    sc.post_filter_lp(v, 0.0)
    for ch = 1, 2 do
      sc.level_input_cut(ch, v, (ch == v) and 1.0 or 0.0)
    end
  end
  update_tape_rate()
  update_tape_rec()
  update_tape_loop()
  update_mix()
  -- tape head position events drive the TAPE page needle AND the loop
  -- snap points — 25ms quant keeps snapped loops tight (0.1 was audible)
  sc.phase_quant(1, 0.025)
  sc.event_phase(function(v, pos)
    if v == 1 then tape_phase = pos / TAPE_LEN end
  end)
  sc.poll_start_phase()
end

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
  REC = {
    k2 = { label = "REC", lit = "rec",
      act = function() ptoggle("rec") end },
    k3 = { label = "FRZ", lit = "freeze",
      act = function() ptoggle("freeze") end },
  },
  WINDOW = {
    k2 = { label = "RST",
      act = function() params:set("pos_start", 0) params:set("pos_end", 1) end },
  },
  GRAIN = {
    k3 = { label = "PT=1",
      act = function() params:set("pitch", 1.0) end },
  },
  STRETCH = {
    -- K2 cycles OFF -> GRAIN -> WARP -> PV -> OFF; K3 toggles spectral freeze
    k2 = { label = "MODE",
      act = function() params:set("mode", (params:get("mode") % 4) + 1) end },
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
        sc.buffer_clear()
        for i = 1, 128 do twave[i] = 0 end
        twave_bin = 0
        twave_any = false
        params:set("tape_freeze", 0)
        params:set("loop_start", 0)
        params:set("loop_end", 1)
      end },
  },
  FILTER = {
    k2 = { label = "TYPE",
      act = function() params:set("filt_type", (params:get("filt_type") % 3) + 1) end },
  },
  DELAY = {
    k3 = { label = "KILL",
      act = function() params:set("delay_fb", 0) end },
  },
}

-- the key def addressed by key n on the current page, alt-aware; alt falls
-- back to the un-alt def so a page needn't define both layers
local function key_def(n)
  local defs = KEYS[PAGES[page]]
  if not defs then return nil end
  if n == 2 then
    if alt then return defs.k2_alt or defs.k2 end
    return defs.k2
  end
  if alt then return defs.k3_alt or defs.k3 end
  return defs.k3
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
  params:add_group("grp_mix", "mix", 4)
  params:add_control("mix", "eng <> tape",
    controlspec.new(0, 1, "lin", 0, 0.5, ""))
  params:set_action("mix", update_mix)
  params:add_control("out_level", "out level",
    controlspec.new(0, 1.5, "lin", 0, 1.0, ""))
  params:set_action("out_level", update_mix)
  params:add_control("sc_level", "eng level",
    controlspec.new(0, 1, "lin", 0, 1.0, ""))
  params:set_action("sc_level", update_mix)
  -- id "tape_level" is RESERVED by the system TAPE deck; "cut_level" avoids it
  params:add_control("cut_level", "tape level",
    controlspec.new(0, 1, "lin", 0, 1.0, ""))
  params:set_action("cut_level", update_mix)

  params:add_group("grp_rec", "rec", 6)
  add_eng_binary("rec", "record")
  -- when capture stops, snap the window to the take just recorded so playback
  -- immediately loops what you played — not a 60s window of mostly silence
  params:set_action("rec", function(v)
    if engine.rec then engine.rec(v) end
    if v == 1 then
      rec_arm_phase = rec_phase
    elseif rec_phase > rec_arm_phase + 0.005 then
      params:set("pos_start", rec_arm_phase)
      params:set("pos_end", rec_phase)
    elseif rec_phase < rec_arm_phase - 0.005 then
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

  params:add_group("grp_grain", "grain", 6)
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

  params:add_group("grp_stretch", "stretch", 5)
  -- mode swaps the playback synth in the engine: only the active algorithm
  -- costs CPU; OFF frees the SC voice entirely
  params:add_option("mode", "mode", { "OFF", "GRAIN", "WARP", "PV" }, 2)
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
      tape_arm_phase = tape_phase
    elseif tape_phase > tape_arm_phase + 0.005 then
      params:set("loop_start", tape_arm_phase)
      params:set("loop_end", tape_phase)
      tape_set(function(vc) sc.position(vc, tape_arm_phase * TAPE_LEN) end)
    elseif tape_phase < tape_arm_phase - 0.005 then
      -- head wrapped past the tape end mid-take: softcut loops can't cross
      -- the seam, so keep the full tape rather than snapping a wrong slice
      params:set("loop_start", 0)
      params:set("loop_end", 1)
    end
    update_tape_rec()
  end)
  params:add_control("tape_rate", "tape rate",
    controlspec.new(-2, 2, "lin", 0, 1.0, "x"))
  params:set_action("tape_rate", update_tape_rate)
  params:add_binary("tape_reverse", "tape reverse", "momentary", 0)
  params:set_action("tape_reverse", update_tape_rate)
  -- same fine quantum + span-scaled deltas as the window edges
  local loop_start_spec = controlspec.new(0, 1, "lin", 0, 0.0, "")
  loop_start_spec.quantum = 0.002
  params:add_control("loop_start", "loop start", loop_start_spec)
  params:set_action("loop_start", update_tape_loop)
  local loop_end_spec = controlspec.new(0, 1, "lin", 0, 1.0, "")
  loop_end_spec.quantum = 0.002
  params:add_control("loop_end", "loop end", loop_end_spec)
  params:set_action("loop_end", update_tape_loop)
  params:add_control("tape_pre", "tape overdub",
    controlspec.new(0, 1, "lin", 0, 0.0, ""))
  params:set_action("tape_pre", update_tape_rec)
  params:add_binary("tape_freeze", "tape freeze", "toggle", 0)
  params:set_action("tape_freeze", update_tape_rec)
  params:add_control("tape_fade", "tape fade",
    controlspec.new(0.001, 0.5, "exp", 0, 0.05, "s"))
  params:set_action("tape_fade", function(v)
    tape_set(function(vc) sc.fade_time(vc, v) end)
  end)

  params:add_group("grp_filter", "filter", 3)
  params:add_option("filt_type", "filter type", { "LP", "HP", "BP" }, 1)
  params:set_action("filt_type", function(v)
    if engine.filt_type then engine.filt_type(v - 1) end
  end)
  add_eng_control("cutoff", "cutoff",
    controlspec.new(20, 20000, "exp", 0, 20000, "hz"))
  add_eng_control("resonance", "resonance",
    controlspec.new(0, 1, "lin", 0, 0.0, ""))

  params:add_group("grp_delay", "delay", 3)
  add_eng_control("delay_time", "delay time",
    controlspec.new(0.01, 1, "exp", 0, 0.3, "s"))
  add_eng_control("delay_fb", "feedback",
    controlspec.new(0, 0.95, "lin", 0, 0.3, ""))
  add_eng_control("delay_mix", "delay mix",
    controlspec.new(0, 1, "lin", 0, 0.0, ""))

  params:add_group("grp_reverb", "reverb", 2)
  add_eng_control("rev_size", "reverb size",
    controlspec.new(0, 1, "lin", 0, 0.5, ""))
  add_eng_control("rev_mix", "reverb mix",
    controlspec.new(0, 1, "lin", 0, 0.0, ""))

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

  -- PSETs persist the tape audio too: PARAMS > PSET > SAVE writes the
  -- softcut buffers (L=buf1, R=buf2, matching init_tape's routing) next to
  -- the pset; LOAD reads them back, DELETE cleans up. so "save my current
  -- state and load it again" is one menu action. the granular engine's
  -- record buffer would need a matching save command on the SC side to
  -- round-trip as well — until then, only the tape survives a restart.
  params.action_write = function(filename, name, number)
    sc.buffer_write_stereo(norns.state.data .. "tape-" .. number .. ".wav",
      0, TAPE_LEN)
  end
  params.action_read = function(filename, silent, number)
    local path = norns.state.data .. "tape-" .. number .. ".wav"
    if util.file_exists(path) then
      sc.buffer_read_stereo(path, 0, 0, TAPE_LEN)
      twave_any = true
    end
  end
  params.action_delete = function(filename, name, number)
    os.remove(norns.state.data .. "tape-" .. number .. ".wav")
  end

  params:bang()
end

-- ============================================================================
-- midi note input (chromatic playing)
-- ============================================================================
-- note-ons set `pitch` = 2^(semitones/12) relative to root_note: middle C
-- (with the default root) plays the sample as recorded, and the 0.25–4 spec
-- covers ±24 st (notes beyond that clamp to the edges). last-note priority,
-- no envelope — a note retunes the running voice rather than gating one.
-- CC mappings (PMAP) are handled by the system and unaffected by this.

local midi_devices = {}

-- true when vport i holds the device midigrid adopted as the grid: its
-- note-ons are grid pads, not notes. norns dispatches midi to BOTH the
-- device-level handler (which midigrid uses) and the vport-level handler
-- (which we use), so without this filter every pad press would also yank
-- `pitch` to whatever the pad's raw note number maps to.
local function is_grid_vport(i)
  if not (have_midigrid and gg and gg.device) then return false end
  local vp = midi.vports[i]
  local dev = vp and vp.device
  if not dev then return false end
  return dev == gg.device or dev.name == gg.device.name
end

local function midi_event(data, vport)
  if is_grid_vport(vport) then return end
  local msg = midi.to_msg(data)
  if msg.type ~= "note_on" or (msg.vel or 0) == 0 then return end
  if pget("keys_enable", 1) == 0 then return end
  local ch = pget("midi_channel", 0)
  if ch > 0 and msg.ch ~= ch then return end
  params:set("pitch", 2 ^ ((msg.note - pget("root_note", 60)) / 12))
end

local function init_midi()
  -- connect every vport: any keyboard works, including ones plugged in later
  for i = 1, #midi.vports do
    midi_devices[i] = midi.connect(i)
    midi_devices[i].event = function(data) midi_event(data, i) end
  end
end

-- USB typing keyboard: ableton-style musical typing. the A-row is the white
-- keys, the W-row the black keys — A plays the sample as recorded, and Z/X
-- shift the octave (kb_octave). semitone offsets are root-relative, so the
-- root_note param only concerns MIDI (which sends absolute note numbers).
local KB_NOTES = {
  A = 0, W = 1, S = 2, E = 3, D = 4, F = 5, T = 6, G = 7, Y = 8,
  H = 9, U = 10, J = 11, K = 12, O = 13, L = 14, P = 15,
  SEMICOLON = 16, APOSTROPHE = 17,
}

function keyboard.code(code, value)
  if value ~= 1 then return end           -- key-down only (2 = autorepeat)
  if norns.menu.status() then return end  -- the menu owns typing (PSET names)
  if pget("keys_enable", 1) == 0 then return end
  if code == "Z" or code == "X" then
    params:delta("kb_octave", code == "X" and 1 or -1)
    flash_id, flash_until = "kb_octave", frame + FPS
  else
    local st = KB_NOTES[code]
    if st then
      params:set("pitch", 2 ^ ((st + 12 * pget("kb_octave", 0)) / 12))
      flash_id, flash_until = "pitch", frame + FPS
    end
  end
end

-- ============================================================================
-- grid (optional): monome grid, or launchpad-style controllers via midigrid
-- ============================================================================
-- an 8x8 performance surface. native monome grids just work; with the
-- midigrid library installed (~/dust/code/midigrid) a launchpad-family or
-- APC mini controller stands in — but only when no real grid is attached
-- (a monome on grid vport 1 wins). every pad drives params, the same
-- single source of truth as keys, encoders, and MIDI CCs.
--
--   row 1  engine: [rec] [freeze]  ·  [OFF][GRAIN][WARP][PV]  [pv frz]
--   row 2  tape:   [rec] [freeze] [reverse, hold]  ·  ·  ·  ·  ·
--   row 3  window slices: a pad = that eighth; hold one + press another
--          = the span between them
--   row 4  tape loop slices: same gesture, driving loop start/end
--   rows 5-8  two piano octaves, black row above its white row (same
--          shape as the typing keyboard; upper pair is +1 octave).
--          black-row gap pads: row 7 ends = octave -/+, row 5 ends =
--          pitch reset / pitch quantize

local grid_mod = grid
do
  local gname = (grid.vports and grid.vports[1] and grid.vports[1].name)
    or "none"
  if gname == "none" and util.file_exists(_path.code .. "midigrid") then
    -- pcall: a broken midigrid install must not take mangler down with it
    local ok, mg = pcall(include, "midigrid/lib/midigrid")
    if ok and mg then
      grid_mod = mg
      have_midigrid = true
      print("mangler: midigrid loaded — midi grid controllers welcome")
    else
      print("mangler: midigrid present but failed to load: " .. tostring(mg))
    end
  end
end

-- semitone offsets per column, root-relative (nil = no black key there)
local GRID_WHITE = { 0, 2, 4, 5, 7, 9, 11, 12 }
local GRID_BLACK = { nil, 1, 3, nil, 6, 8, 10, nil }

-- note-pad row pairs { black row, white row, octave offset }: static, so
-- the per-frame grid refresh builds no tables
local GRID_NOTE_ROWS = { { 5, 6, 1 }, { 7, 8, 0 } }

-- window/loop slice pads: track what's held per row so a second press
-- while the first is down stretches the region between them
local slice_held = { win = {}, loop = {} }
local SLICE_IDS = {
  win = { "pos_start", "pos_end" },
  loop = { "loop_start", "loop_end" },
}

local function slice_key(kind, x, z)
  local h = slice_held[kind]
  if z == 1 then
    local anchor = h[1] or x   -- first held pad anchors the span
    h[#h + 1] = x
    local lo, hi = math.min(anchor, x), math.max(anchor, x)
    params:set(SLICE_IDS[kind][1], (lo - 1) / 8)
    params:set(SLICE_IDS[kind][2], hi / 8)
  else
    for i = #h, 1, -1 do
      if h[i] == x then table.remove(h, i) end
    end
  end
end

local function grid_note_key(x, y, z)
  if z ~= 1 then return end
  if pget("keys_enable", 1) == 0 then return end
  local st
  if y == 6 or y == 8 then
    st = GRID_WHITE[x]
  else
    st = GRID_BLACK[x]
    if not st then
      -- the black rows' gap pads carry the utility functions
      if y == 7 and (x == 1 or x == 8) then
        params:delta("kb_octave", x == 8 and 1 or -1)
        flash_id, flash_until = "kb_octave", frame + FPS
      elseif y == 5 and x == 1 then
        params:set("pitch", 1.0)
        flash_id, flash_until = "pitch", frame + FPS
      elseif y == 5 and x == 8 then
        ptoggle("pitch_quant")
      end
      return
    end
  end
  local oct = pget("kb_octave", 0) + (y <= 6 and 1 or 0)
  params:set("pitch", 2 ^ ((st + 12 * oct) / 12))
  flash_id, flash_until = "pitch", frame + FPS
end

local function grid_key(x, y, z)
  if x > 8 or y > 8 then return end  -- wider/taller grids: top-left 8x8
  if y == 1 then
    if z ~= 1 then return end
    if x == 1 then ptoggle("rec")
    elseif x == 2 then ptoggle("freeze")
    elseif x >= 4 and x <= 7 then params:set("mode", x - 3)
    elseif x == 8 then ptoggle("pv_freeze") end
  elseif y == 2 then
    if x == 3 then
      params:set("tape_reverse", z)  -- momentary, like K1+K2 on TAPE
    elseif z == 1 then
      if x == 1 then ptoggle("tape_rec")
      elseif x == 2 then ptoggle("tape_freeze") end
    end
  elseif y == 3 or y == 4 then
    slice_key(y == 3 and "win" or "loop", x, z)
  else
    grid_note_key(x, y, z)
  end
end

local function grid_redraw()
  if not (gg and gg.device) then return end
  gg:all(0)

  -- row 1: engine transport + mode radio
  gg:led(1, 1, pget("rec", 0) == 1 and 15 or 2)
  gg:led(2, 1, pget("freeze", 0) == 1 and 15 or 2)
  local mode = pget("mode", 2)
  for x = 4, 7 do gg:led(x, 1, (x - 3) == mode and 15 or 3) end
  gg:led(8, 1, pget("pv_freeze", 0) == 1 and 15 or 2)

  -- row 2: tape transport
  gg:led(1, 2, pget("tape_rec", 0) == 1 and 15 or 2)
  gg:led(2, 2, pget("tape_freeze", 0) == 1 and 15 or 2)
  gg:led(3, 2, pget("tape_reverse", 0) == 1 and 15 or 2)

  -- rows 3/4: slices lit across the active region, head pad brightest
  local wlo, whi = window_bounds()
  local la, lb = pget("loop_start", 0), pget("loop_end", 1)
  local llo, lhi = min(la, lb), max(la, lb)
  for x = 1, 8 do
    local a, b = (x - 1) / 8, x / 8
    gg:led(x, 3, (a < whi and b > wlo) and 6 or 1)
    gg:led(x, 4, (a < lhi and b > llo) and 6 or 1)
  end
  gg:led(floor(clamp(play_phase, 0, 0.999) * 8) + 1, 3, 15)
  gg:led(floor(clamp(tape_phase, 0, 0.999) * 8) + 1, 4, 15)

  -- rows 5-8: note pads. current pitch lights its pad; the whole block
  -- dims when note input is off so it's visible why pads are dead
  local en = pget("keys_enable", 1) == 1
  local oct = pget("kb_octave", 0)
  local st_cur = util.round(12 * log(pget("pitch", 1), 2))
  for _, rows in ipairs(GRID_NOTE_ROWS) do
    local by, wy, o = rows[1], rows[2], oct + rows[3]
    for x = 1, 8 do
      local w = GRID_WHITE[x] + 12 * o
      gg:led(x, wy, not en and 1 or w == st_cur and 15
        or (x == 1 or x == 8) and 6 or 4)
      if GRID_BLACK[x] then
        local b = GRID_BLACK[x] + 12 * o
        gg:led(x, by, not en and 1 or b == st_cur and 15 or 2)
      end
    end
  end
  gg:led(1, 7, en and 3 or 1)  -- octave -
  gg:led(8, 7, en and 3 or 1)  -- octave +
  gg:led(1, 5, en and 3 or 1)  -- pitch reset
  gg:led(8, 5, (en and pget("pitch_quant", 0) == 1) and 15 or (en and 3 or 1))

  gg:refresh()
end

local function init_grid()
  gg = grid_mod.connect()
  if gg then gg.key = grid_key end
end

-- ============================================================================
-- visuals: waveform bins + grain particles
-- ============================================================================

-- paint amplitude into display bins between the last-seen head position and
-- the current one, walking the SHORTER way around the (circular) buffer —
-- so bins skipped between frames at high rates get filled, wrap-around is
-- seamless, and reverse playback paints in the right direction. entering a
-- fresh bin, previous content survives by `pre` (the overdub picture).
local function paint_bins(bins, last, bin, amp, pre)
  if last == 0 or last == bin then
    bins[bin] = max(bins[bin], amp)
    return bin
  end
  local fwd = (bin - last) % 128
  local bwd = (last - bin) % 128
  local step = (fwd <= bwd) and 1 or -1
  local b = last
  repeat
    b = ((b - 1 + step) % 128) + 1
    bins[b] = max(bins[b] * pre, amp)
  until b == bin
  return bin
end

-- track the buffer's contents as the write head passes over it
local function update_wave()
  if pget("rec", 0) == 1 and pget("freeze", 0) == 0 then
    local bin = floor(clamp(rec_phase, 0, 0.999) * 128) + 1
    if rec_amp > 0.01 then wave_any = true end
    wave_bin = paint_bins(wave, wave_bin, bin, rec_amp, pget("pre_level", 0))
  end
end

-- track the tape loop's contents as the head records (input amplitude,
-- since softcut exposes no per-voice output meter); tape_pre sets survival
local function update_tape_wave()
  if pget("tape_rec", 0) == 1 and pget("tape_freeze", 0) == 0 then
    local bin = floor(clamp(tape_phase, 0, 0.999) * 128) + 1
    local a = max(amp_in[1], amp_in[2])
    if a > 0.01 then twave_any = true end
    twave_bin = paint_bins(twave, twave_bin, bin, a, pget("tape_pre", 0))
  end
end

local function update_particles()
  if not params.lookup["density"] then return end
  -- nothing moves that can't be heard: mode OFF frees the SC voice, and an
  -- empty buffer granulates silence — either way the cloud stops spawning
  -- (live particles still decay out)
  if pget("mode", 2) == 1 or not wave_any then
    spawn_acc = 0
  else
    spawn_acc = spawn_acc + pget("density", 20) / FPS
  end
  local lo, hi, span = window_bounds()
  local jit = pget("pos_jitter", 0)
  local decay = 13 / max(pget("size", 0.1) * FPS * 4, 2)
  while spawn_acc >= 1 do
    spawn_acc = spawn_acc - 1
    if particles_n < PARTICLE_MAX then
      local px = clamp(play_phase + (random() * 2 - 1) * jit * span, 0, 1)
      particles_n = particles_n + 1
      local p = particles[particles_n]
      p.x = px * 127
      -- spawn below the strip zone so GRAIN's top strip stays readable
      p.y = BAND_T + 6 + random() * (BAND_B - BAND_T - 8)
      p.lvl = 13
      p.decay = decay
    else
      spawn_acc = 0
    end
  end
  -- decay + compact in place: live slots keep their order (draw order is
  -- part of the picture), dead slots swap to the tail for reuse
  local w = 0
  for i = 1, particles_n do
    local p = particles[i]
    p.lvl = p.lvl - p.decay
    if p.lvl >= 1 then
      w = w + 1
      if w ~= i then
        particles[w], particles[i] = p, particles[w]
      end
    end
  end
  particles_n = w
end

-- ============================================================================
-- norns callbacks
-- ============================================================================

function init()
  print("mangler: init() called")
  init_params()
  init_tape()
  init_midi()
  init_grid()
  print("mangler: init() done, params built")

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
  watch("play_phase", function(v) play_phase = v end)
  watch("rec_phase", function(v) rec_phase = v end)
  watch("rec_amp", function(v) rec_amp = v end)
  watch("amp_in_l", function(v) amp_in[1] = v end)
  watch("amp_in_r", function(v) amp_in[2] = v end)
  watch("amp_out_l", function(v) amp_out[1] = v end)
  watch("amp_out_r", function(v) amp_out[2] = v end)

  redraw_clock = clock.run(function()
    while true do
      clock.sleep(1 / FPS)
      frame = frame + 1
      update_wave()
      update_tape_wave()
      update_particles()
      -- never draw over the system menu; the grid stays live inside it
      if norns.menu.status() == false then redraw() end
      grid_redraw()
    end
  end)

  redraw()
  grid_redraw()
end

function cleanup()
  for _, p in ipairs(polls) do p:stop() end
  if redraw_clock then clock.cancel(redraw_clock) end
  for _, d in ipairs(midi_devices) do d.event = nil end
  keyboard.code = nil
  if gg then
    gg.key = nil
    if gg.device then
      gg:all(0)
      gg:refresh()
    end
  end
  sc.poll_stop_phase()
end

function enc(n, d)
  if n == 1 then
    page = clamp(page + d, 1, #PAGES)
  else
    local id = enc_param(n)
    -- params.lookup guard: a missing param must not throw
    if id and params.lookup[id] then
      params:delta(id, fine_delta(id, d))
      flash_id, flash_until = id, frame + FPS  -- show the value for ~1s
    end
  end
  redraw()
end

function key(n, z)
  if n == 1 then
    alt = (z == 1)
  else
    held[n] = (z == 1)
    if z == 1 then
      local def = key_def(n)
      if def and def.act then def.act() end
    else
      gesture_release(n)
    end
  end
  redraw()
end

-- ============================================================================
-- screen  (the bitmap mockups are the bible: same font, same geometry)
-- ============================================================================
-- layout: header y0..10  (title 2x pixel font, ALT chip, page dots, status)
--         body   y12..41 (per-page visualization)
--         footer y44..63 (labels row, then the hardware row mirroring the
--                         panel: E2 hexagon . K2 pill . K3 pill . E3 hexagon)
-- values are not parked in the footer: turning an encoder flashes the value
-- top-right for a second (like the mockup readouts), then it gets out of
-- the way.

-- the 4x5 pixel font from the mockups, drawn rect-by-rect so the device
-- renders exactly what the bitmaps promised. rows top->bottom, '1' = lit.
local FONT = {
  A = { "0110", "1001", "1111", "1001", "1001" },
  B = { "1110", "1001", "1110", "1001", "1110" },
  C = { "0111", "1000", "1000", "1000", "0111" },
  D = { "1110", "1001", "1001", "1001", "1110" },
  E = { "1111", "1000", "1110", "1000", "1111" },
  F = { "1111", "1000", "1110", "1000", "1000" },
  G = { "0111", "1000", "1011", "1001", "0111" },
  H = { "1001", "1001", "1111", "1001", "1001" },
  I = { "111", "010", "010", "010", "111" },
  J = { "0011", "0001", "0001", "1001", "0110" },
  K = { "1001", "1010", "1100", "1010", "1001" },
  L = { "1000", "1000", "1000", "1000", "1111" },
  M = { "10001", "11011", "10101", "10001", "10001" },
  N = { "1001", "1101", "1011", "1001", "1001" },
  O = { "0110", "1001", "1001", "1001", "0110" },
  P = { "1110", "1001", "1110", "1000", "1000" },
  Q = { "0110", "1001", "1001", "1010", "0101" },
  R = { "1110", "1001", "1110", "1010", "1001" },
  S = { "0111", "1000", "0110", "0001", "1110" },
  T = { "111", "010", "010", "010", "010" },
  U = { "1001", "1001", "1001", "1001", "0110" },
  V = { "101", "101", "101", "101", "010" },
  W = { "10001", "10001", "10101", "11011", "10001" },
  X = { "101", "101", "010", "101", "101" },
  Y = { "101", "101", "010", "010", "010" },
  Z = { "1111", "0001", "0110", "1000", "1111" },
  ["0"] = { "0110", "1001", "1011", "1101", "0110" },
  ["1"] = { "010", "110", "010", "010", "111" },
  ["2"] = { "1110", "0001", "0110", "1000", "1111" },
  ["3"] = { "1110", "0001", "0110", "0001", "1110" },
  ["4"] = { "1001", "1001", "1111", "0001", "0001" },
  ["5"] = { "1111", "1000", "1110", "0001", "1110" },
  ["6"] = { "0111", "1000", "1110", "1001", "0110" },
  ["7"] = { "1111", "0001", "0010", "0100", "0100" },
  ["8"] = { "0110", "1001", "0110", "1001", "0110" },
  ["9"] = { "0110", "1001", "0111", "0001", "1110" },
  ["."] = { "0", "0", "0", "0", "1" },
  ["-"] = { "000", "000", "111", "000", "000" },
  ["+"] = { "000", "010", "111", "010", "000" },
  ["="] = { "000", "111", "000", "111", "000" },
  [":"] = { "0", "1", "0", "1", "0" },
  ["/"] = { "001", "001", "010", "100", "100" },
  ["%"] = { "11001", "11010", "00100", "01011", "10011" },
  ["<"] = { "001", "010", "100", "010", "001" },
  [">"] = { "100", "010", "001", "010", "100" },
  [" "] = { "00", "00", "00", "00", "00" },
}

-- byte-indexed glyph + advance tables, built once: text draws every frame,
-- and a byte walk allocates nothing (per-char gmatch/sub costs an iterator
-- or a string per call). lua patterns are byte-based, so bytes match them.
local FONT_B, FONT_ADV = {}, {}
for b = 0, 255 do
  local ch = string.char(b)
  local g = FONT[ch] or FONT[ch:upper()] or FONT[" "]
  FONT_B[b] = g
  FONT_ADV[b] = #g[1] + 1
end

local function text_w(str, sc)
  local w = 0
  for i = 1, #str do w = w + FONT_ADV[sbyte(str, i)] * sc end
  return w - sc
end

-- draw a pixel-font string at (x,y) top-left, scale sc, brightness lvl
local function ptext(str, x, y, sc, lvl)
  screen.level(lvl)
  local cx = x
  for i = 1, #str do
    local b = sbyte(str, i)
    local g = FONT_B[b]
    for r = 1, 5 do
      local row = g[r]
      for c = 1, #row do
        if sbyte(row, c) == 49 then  -- 49 = "1"
          screen.rect(cx + (c - 1) * sc, y + (r - 1) * sc, sc, sc)
        end
      end
    end
    cx = cx + FONT_ADV[b] * sc
  end
  screen.fill()
  return cx - x - sc
end

local function ptext_c(str, cx, y, sc, lvl)
  ptext(str, floor(cx - text_w(str, sc) / 2 + 0.5), y, sc, lvl)
end

local function ptext_r(str, rx, y, sc, lvl)
  ptext(str, rx - text_w(str, sc), y, sc, lvl)
end

-- inverted chip (the ALT tag / mode badge from the mockups)
local function chip(str, x, y)
  local w = text_w(str, 1) + 5
  screen.level(15)
  screen.rect(x, y, w, 9)
  screen.fill()
  ptext(str, x + 3, y + 2, 1, 0)
  return w
end

-- deterministic dither, same trick as the mockups
local function hash(x, y, sd)
  local f = sin(x * 12.9898 + y * 78.233 + sd * 37.719) * 43758.5453
  return f - floor(f)
end

-- short footer labels per param id (4-5 chars, mockup style)
local SHORT = {
  mix = "MIX", out_level = "OUT", sc_level = "ENG", cut_level = "TAPE",
  input_level = "IN", monitor_level = "MON",
  output_level = "OUT", headphone_gain = "HP",
  rec_level = "LVL", pre_level = "OVR", dry_wet = "D/W", resample = "RSMP",
  pos_start = "STRT", scan = "SCAN", pos_end = "END", pos_jitter = "JIT",
  size = "SIZE", spread = "SPRD", density = "DENS", grain_level = "LVL",
  pitch = "PTCH", warp_window = "WIN", warp_rand = "RAND", kb_octave = "OCT",
  tape_rate = "RATE", tape_pre = "OVR", loop_start = "STRT", loop_end = "END",
  cutoff = "CUT", resonance = "RES",
  delay_mix = "MIX", delay_time = "TIME", delay_fb = "FDBK",
  rev_size = "SIZE", rev_mix = "MIX",
}

-- normalized 0..1 position of a param, for the dial pointer. bipolar
-- controlspecs (scan, tape_rate) land center at zero, which reads correctly.
local function param_norm(id)
  if not (id and params.lookup[id]) then return nil end
  local p = params:lookup_param(id)
  local v = params:get(id)
  if p.controlspec then
    return clamp(p.controlspec:unmap(v), 0, 1)
  elseif p.count then
    return p.count > 1 and (v - 1) / (p.count - 1) or 0
  elseif p.min and p.max and p.max > p.min then
    return (v - p.min) / (p.max - p.min)
  end
  return clamp(v, 0, 1)
end

-- hexagon dial: dim outline, bright pointer sweeping 135..405 degrees.
-- the outline is a constant ring — its trig lives in a table, not the frame
local HEX_DX, HEX_DY = {}, {}
for i = 0, 6 do
  local a = -math.pi / 2 + i * math.pi / 3
  HEX_DX[i], HEX_DY[i] = math.cos(a), math.sin(a)
end

local function draw_hex_dial(cx, cy, r, val)
  screen.level(4)
  for i = 0, 6 do
    local x, y = cx + HEX_DX[i] * r, cy + HEX_DY[i] * r
    if i == 0 then screen.move(x, y) else screen.line(x, y) end
  end
  screen.stroke()
  if val then
    local a = math.pi * 0.75 + clamp(val, 0, 1) * math.pi * 1.5
    screen.level(15)
    screen.move(cx, cy)
    screen.line(cx + cos(a) * (r - 2), cy + sin(a) * (r - 2))
    screen.stroke()
  end
end

-- key pill, mockup geometry: y=51, h=11, inverted while lit
local function draw_pill(cx, label, on, dim)
  local w = text_w(label, 1) + 7
  local x = floor(cx - w / 2)
  if on then
    screen.level(15)
    screen.rect(x, 51, w, 11)
    screen.fill()
    ptext_c(label, cx, 54, 1, 0)
  else
    screen.level(dim and 1 or 4)
    screen.rect(x + 0.5, 51.5, w, 11)
    screen.stroke()
    ptext_c(label, cx, 54, 1, dim and 2 or 10)
  end
end

-- transient value readout, top-right of the body (mockup "1.25X" spot).
-- pages can park a persistent dim readout there too; the flash wins.
local flash_on = false

local function topright(str, lvl)
  if flash_on then return end
  ptext_r(string.upper(str), 126, 13, 1, lvl or 4)
end

-- footer: labels row at y44, then hexagon . pill . pill . hexagon at the
-- exact mockup positions (dials 20/108, pills 51/81)
local function draw_footer()
  local id2, id3 = enc_param(2), enc_param(3)
  ptext_c(SHORT[id2] or "--", 20, 44, 1, 4)
  ptext_c("K2", 51, 44, 1, 4)
  ptext_c("K3", 81, 44, 1, 4)
  ptext_c(SHORT[id3] or "--", 108, 44, 1, 4)
  draw_hex_dial(20, 56, 7, param_norm(id2))
  draw_hex_dial(108, 56, 7, param_norm(id3))
  for n = 2, 3 do
    local def = key_def(n)
    local cx = (n == 2) and 51 or 81
    if def then
      local on = (def.lit ~= nil and pget(def.lit, 0) == 1) or held[n] == true
      draw_pill(cx, def.label, on, false)
    else
      draw_pill(cx, "--", false, true)
    end
  end
end

-- buffer strip: waveform of recorded material (bright inside the window),
-- window underline, playhead needle, write-head ticks
local function draw_strip(handles)
  local lo, hi, _ = window_bounds()
  local mid = (BAND_T + BAND_B) / 2
  local half = (BAND_B - BAND_T) / 2

  -- baseline: an empty buffer reads as a thin line, not a grey block
  screen.level(1)
  screen.move(0, mid)
  screen.line(128, mid)
  screen.stroke()

  -- waveform columns (sqrt + 2x gain for visual headroom on quiet material).
  -- disjoint verticals raster the same under one stroke per brightness run,
  -- so up to 128 stroke calls collapse into at most three
  local run = 0
  for x = 0, 127 do
    local a = wave[x + 1]
    if a > 0.002 then
      local h = clamp(sqrt(min(a * 2, 1)) * half, 1, half)
      local nx = x / 127
      local lvl = (nx >= lo and nx <= hi) and 12 or 2
      if lvl ~= run then
        if run ~= 0 then screen.stroke() end
        screen.level(lvl)
        run = lvl
      end
      screen.move(x, mid - h)
      screen.line(x, mid + h)
    end
  end
  if run ~= 0 then screen.stroke() end

  -- window underline + optional edge handles
  screen.level(4)
  screen.move(lo * 127, BAND_B + 2)
  screen.line(hi * 127, BAND_B + 2)
  screen.stroke()
  if handles then
    screen.level(15)
    for k = 1, 2 do
      local e = k == 1 and lo or hi
      screen.move(e * 127, BAND_T - 2)
      screen.line(e * 127, BAND_B + 2)
    end
    screen.stroke()
  end

  -- playhead needle — only once there's material to play; an empty buffer
  -- keeps the strip quiet so the EMPTY invitation stands alone
  if wave_any then
    screen.level(15)
    local px = clamp(play_phase, 0, 1) * 127
    screen.move(px, BAND_T - 2)
    screen.line(px, BAND_B + 2)
    screen.stroke()
  end

  -- write head: dim ticks top+bottom while recording, so capture is visible
  if pget("rec", 0) == 1 and pget("freeze", 0) == 0 then
    local wx = clamp(rec_phase, 0, 1) * 127
    screen.level(6)
    screen.move(wx, BAND_T - 2)
    screen.line(wx, BAND_T + 4)
    screen.move(wx, BAND_B - 4)
    screen.line(wx, BAND_B + 2)
    screen.stroke()
  end
end

local function draw_particles()
  -- level varies per particle and overlaps must layer in spawn order, so
  -- the fill stays per-particle (32 max)
  for i = 1, particles_n do
    local p = particles[i]
    screen.level(floor(p.lvl))
    screen.rect(p.x, p.y, 1, 1)
    screen.fill()
  end
end

-- LEVEL fader layout per alt layer: { x, label, param id }. the left
-- fader's vu meters the input, the right one the output, in either layer
local LEVEL_DEFS = {
  { 40, "IN", "input_level" },
  { 88, "OUT", "output_level" },
}
local LEVEL_DEFS_ALT = {
  { 40, "MON", "monitor_level" },
  { 88, "HP", "headphone_gain" },
}

local REEL_X = { 46, 86 }   -- TAPE page reel centers

local delay_heights = {}    -- DELAY bounce peaks, slots reused every frame

-- STRETCH lane curve, shared by the mode textures (a closure built inside
-- the frame would be gc churn at 15fps)
local function stretch_wy(x, ph, rate)
  return 30 + sin((x + ph) * 0.35 * rate) * 6
end

local function draw_body()
  local pname = PAGES[page]

  if pname == "MIX" then
    -- two lanes like the mockup: engine as grains, tape as its real
    -- waveform, crossfader between them. lane energy follows the mix.
    -- mode OFF silences the engine, so its lane lies flat — nothing
    -- moves that can't be heard.
    local mixv = pget("mix", 0.5)
    local sd = floor(frame / 2)
    ptext("ENG", 2, 13, 1, 4)
    if pget("mode", 2) == 1 then
      screen.level(1)
      screen.move(26, 17)
      screen.line(122, 17)
      screen.stroke()
    else
      screen.level(12)
      for x = 26, 122 do
        if hash(x, 1, sd) < 0.1 + (1 - mixv) * 0.4 then
          local dy = (hash(x, 7, sd) - 0.5) * 2 * (1 + (1 - mixv) * 5)
          screen.rect(x, 16 + dy, 1, 1)
        end
      end
      screen.fill()
    end
    screen.level(2)
    screen.move(26, 24)
    screen.line(122, 24)
    screen.stroke()
    screen.level(15)
    screen.rect(25 + mixv * 96, 21, 3, 7)
    screen.fill()
    ptext("TAPE", 2, 30, 1, 4)
    screen.level(1)
    screen.move(26, 33)
    screen.line(122, 33)
    screen.stroke()
    -- lane columns share one brightness: a single stroke rasters the same
    local g = 0.3 + 0.7 * mixv
    screen.level(12)
    for x = 26, 122 do
      local a = twave[floor((x - 26) / 96 * 127) + 1]
      if a > 0.002 then
        local h = clamp(sqrt(min(a * 2, 1)) * 5 * g, 1, 5)
        screen.move(x, 33 - h)
        screen.line(x, 33 + h)
      end
    end
    screen.stroke()
  elseif pname == "LEVEL" then
    -- mockup levels page: faders with live VU columns beside them. the
    -- faders track the alt layer, so they always show what E2/E3 grab:
    -- IN/OUT normally, MON/HP while K1 is held
    local defs = alt and LEVEL_DEFS_ALT or LEVEL_DEFS
    for i = 1, 2 do
      local d = defs[i]
      local fx, label, pos = d[1], d[2], param_norm(d[3]) or 0
      local amp = i == 1 and max(amp_in[1], amp_in[2])
        or max(amp_out[1], amp_out[2])
      ptext_c(label, fx + 4, 12, 1, 4)
      screen.level(4)
      screen.move(fx, 19)
      screen.line(fx, 40)
      screen.move(fx - 2, 19)
      screen.line(fx + 2, 19)
      screen.move(fx - 2, 40)
      screen.line(fx + 2, 40)
      screen.stroke()
      local hy = 40 - floor(pos * 21)
      screen.level(15)
      screen.rect(fx - 4, hy - 1, 9, 3)
      screen.fill()
      local vu = floor(clamp(sqrt(amp), 0, 1) * 21)
      if vu > 0 then
        screen.level(12)
        screen.rect(fx + 9, 40 - vu, 3, vu)
        screen.fill()
      end
    end
  elseif pname == "REC" then
    draw_strip(false)
    draw_particles()
    -- an empty buffer is an invitation, in the same voice as the TAPE page
    if not wave_any and pget("rec", 0) == 0 then
      ptext_c("EMPTY - K2 REC", 64, 26, 1, 3)
    end
    -- input meter rides the right edge so you can see what's being captured
    local h = floor(clamp(sqrt(max(amp_in[1], amp_in[2])) * (BAND_B - BAND_T), 0, BAND_B - BAND_T))
    screen.level(15)
    if h > 0 then
      screen.rect(125, BAND_B - h, 3, h)
      screen.fill()
    end
  elseif pname == "WINDOW" then
    draw_strip(true)
    local scan = pget("scan", 1)
    topright((scan < 0 and "<< " or ">> ") .. string.format("%.2fX", abs(scan)))
  elseif pname == "GRAIN" then
    -- mockup grain page: thin sample strip up top with window brackets,
    -- grain cloud (the real particles) below, playhead tick between
    screen.level(1)
    screen.move(0, 16)
    screen.line(128, 16)
    screen.stroke()
    -- strip columns and both window brackets each share one brightness:
    -- batched strokes raster identically
    screen.level(6)
    for x = 0, 127 do
      local a = wave[x + 1]
      if a > 0.002 then
        local h = clamp(sqrt(min(a * 2, 1)) * 4, 1, 4)
        screen.move(x, 16 - h)
        screen.line(x, 16 + h)
      end
    end
    screen.stroke()
    local lo, hi = window_bounds()
    screen.level(15)
    for k = 1, 2 do
      local ex = (k == 1 and lo or hi) * 127
      screen.move(ex, 11)
      screen.line(ex, 21)
      screen.move(ex - 2, 11)
      screen.line(ex + 2, 11)
      screen.move(ex - 2, 21)
      screen.line(ex + 2, 21)
    end
    screen.stroke()
    screen.level(15)
    local px = clamp(play_phase, 0, 1) * 127
    screen.move(px, 22)
    screen.line(px, 25)
    screen.stroke()
    draw_particles()
    -- pitch parks top-right, in a quiet corner knocked out of the strip:
    -- it's the one grain value you play from anywhere (MIDI, typing
    -- keyboard, grid) without seeing this page
    local pv = pget("pitch", 1)
    screen.level(0)
    screen.rect(84, 11, 44, 9)
    screen.fill()
    if pget("pitch_quant", 0) == 1 then
      topright(string.format("PT %+d ST", util.round(12 * log(pv, 2))))
    else
      topright(string.format("PT %.2fX", pv))
    end
  elseif pname == "STRETCH" then
    -- mockup stretch page: inverted mode badge, speed readout, real
    -- playhead, window bar — and the wave drawn in the active algorithm's
    -- own texture: GRAIN samples it as grains, WARP lays a second window
    -- over it, PV rebuilds it as spectral columns. wavelength follows the
    -- rate; the texture drifts with scan (still at 0) and freezes with
    -- pv_freeze. mode OFF frees the voice, so the lane lies flat.
    local m = params.lookup["mode"] and params:string("mode") or "?"
    chip(m, 2, 13)
    local scan = pget("scan", 1)
    local mode = pget("mode", 2)
    local held_pv = pget("pv_freeze", 0) == 1
    topright(string.format("%+.2fX", scan))
    if held_pv and mode == 4 then
      ptext_c("HELD", 64, 14, 1, 15)
    end
    local rate = max(abs(scan), 0.05)
    local ph = (mode == 4 and held_pv) and 0 or frame * 0.8 * scan
    if mode == 1 then          -- OFF: dormant lane
      screen.level(1)
      screen.move(0, 30)
      screen.line(128, 30)
      screen.stroke()
    elseif mode == 2 then      -- GRAIN: the wave sampled as grains
      screen.level(6)
      for x = 0, 127, 3 do
        screen.rect(x, stretch_wy(x, ph, rate), 1, 1)
      end
      screen.fill()
    elseif mode == 3 then      -- WARP: an overlapped window ghosts behind
      screen.level(2)
      for x = 0, 127 do
        screen.rect(x, stretch_wy(x + 9, ph, rate), 1, 1)
      end
      screen.fill()
      screen.level(8)
      for x = 0, 127 do
        screen.rect(x, stretch_wy(x, ph, rate), 1, 1)
      end
      screen.fill()
    else                       -- PV: spectral columns under the same curve
      screen.level(6)
      for x = 0, 127, 4 do
        local h = abs(sin((x + ph) * 0.35 * rate)) * 11 + 1
        screen.rect(x, 38 - h, 2, h)
      end
      screen.fill()
    end
    local lo, hi = window_bounds()
    screen.level(2)
    screen.move(0, 39)
    screen.line(128, 39)
    screen.stroke()
    screen.level(6)
    screen.move(lo * 127, 39)
    screen.line(hi * 127, 39)
    screen.stroke()
    -- no playhead while the voice is freed: nothing is playing
    if mode ~= 1 then
      screen.level(15)
      local px = clamp(play_phase, 0, 1) * 127
      screen.move(px, 22)
      screen.line(px, 42)
      screen.stroke()
    end
  elseif pname == "TAPE" then
    -- mockup tape page: two reels spinning at the effective rate (reverse
    -- spins backward, stopped stands still), loop track + head below
    local r = pget("tape_rate", 1) * (pget("tape_reverse", 0) == 1 and -1 or 1)
    reel_angle = reel_angle + r * 0.35
    for _, cx in ipairs(REEL_X) do
      screen.level(4)
      screen.circle(cx, 24, 8)
      screen.stroke()
      screen.level(10)
      for k = 0, 2 do
        local a = reel_angle + k * 2.094
        screen.move(cx, 24)
        screen.line(cx + cos(a) * 6, 24 + sin(a) * 6)
      end
      screen.stroke()
    end
    screen.level(4)
    screen.move(46, 15)
    screen.line(86, 15)
    screen.move(46, 33)
    screen.line(86, 33)
    screen.stroke()
    local a2, b2 = pget("loop_start", 0), pget("loop_end", 1)
    local lo, hi = min(a2, b2), max(a2, b2)
    screen.level(2)
    screen.move(0, 40)
    screen.line(128, 40)
    screen.stroke()
    screen.level(8)
    screen.move(lo * 127, 40)
    screen.line(hi * 127, 40)
    screen.stroke()
    screen.level(15)
    local tx = clamp(tape_phase, 0, 1) * 127
    screen.move(tx, 37)
    screen.line(tx, 43)
    screen.stroke()
    topright(string.format("%+.2fX", r))
    if pget("tape_rec", 0) == 1 and pget("tape_freeze", 0) == 0 then
      if (frame % FPS) < (FPS / 2) then chip("REC", 2, 13) end
    elseif not twave_any then
      ptext_c("EMPTY - K2 REC", 64, 26, 1, 3)
    end
  elseif pname == "FILTER" then
    -- stylized response curve: cutoff on a log axis, resonance bump.
    -- the cutoff parks top-right — every page keeps its one number there
    local cut = pget("cutoff", 20000)
    topright(cut >= 1000 and string.format("%.1fKHZ", cut / 1000)
      or string.format("%dHZ", floor(cut + 0.5)))
    local ft = pget("filt_type", 1)
    local res = pget("resonance", 0)
    local cx = clamp((log(cut / 20) / log(1000)) * 127, 0, 127)
    local mid = 26
    screen.level(8)
    if ft == 1 then       -- LP
      screen.move(0, mid)
      screen.line(max(cx - 10, 0), mid)
      screen.line(cx, mid - res * 10)
      screen.line(min(cx + 14, 127), BAND_B)
    elseif ft == 2 then   -- HP
      screen.move(127, mid)
      screen.line(min(cx + 10, 127), mid)
      screen.line(cx, mid - res * 10)
      screen.line(max(cx - 14, 0), BAND_B)
    else                  -- BP
      screen.move(max(cx - 26, 0), BAND_B)
      screen.line(cx, mid - 6 - res * 6)
      screen.line(min(cx + 26, 127), BAND_B)
    end
    screen.stroke()
    chip(params.lookup["filt_type"] and params:string("filt_type") or "?", 2, 13)
  elseif pname == "DELAY" then
    -- mockup delay page: the echo as a bouncing ball — impact spacing =
    -- time, shrinking bounces = feedback. the ball is literal: it crosses
    -- one arc per repeat, i.e. delay_time seconds per hop (clamped so the
    -- shortest times still read at 15fps). at mix 0 the page goes dormant:
    -- dim train, no ball — nothing moves that can't be heard.
    local dtime = pget("delay_time", 0.3)
    local tnorm = param_norm("delay_time") or 0.3
    local fb = pget("delay_fb", 0.3)
    local mixv = pget("delay_mix", 0)
    topright(string.format("MIX %d%%", floor(mixv * 100 + 0.5)),
      mixv > 0 and 10 or 3)
    local base = 39
    screen.level(1)
    screen.move(0, base + 1.5)
    screen.line(128, base + 1.5)
    screen.stroke()
    local sp = 12 + tnorm * 24
    local nh = 0
    local h = 20
    while 8 + nh * sp <= 116 and h >= 1.5 do
      nh = nh + 1
      delay_heights[nh] = h
      h = h * max(fb, 0.05)
    end
    screen.level(mixv > 0 and 6 or 2)
    for i = 1, nh do
      local hh = delay_heights[i]
      local xa = 8 + (i - 1) * sp
      local k = 0
      for u = 0, 1, 0.05 do
        if k % 2 == 0 then
          screen.rect(xa + u * sp, base - 4 * hh * u * (1 - u), 1, 1)
        end
        k = k + 1
      end
      screen.rect(xa, base - 2, 1, 2)
    end
    screen.fill()
    if nh > 0 and mixv > 0 then
      delay_hop = (delay_hop + (1 / FPS) / max(dtime, 0.12)) % nh
      local seg = floor(delay_hop) + 1
      local u = delay_hop % 1
      local bx = 8 + (seg - 1) * sp + u * sp
      local by = base - 4 * delay_heights[seg] * u * (1 - u)
      screen.level(15)
      screen.rect(bx - 1, by - 2, 2, 2)
      screen.fill()
    end
  elseif pname == "REVERB" then
    -- mockup reverb page: a room seen from above — size grows the walls,
    -- rays are the reflections bouncing off them. at mix 0 the page goes
    -- dormant: dim room, still air — nothing moves that can't be heard.
    local size = pget("rev_size", 0.5)
    local mixv = pget("rev_mix", 0)
    topright(string.format("MIX %d%%", floor(mixv * 100 + 0.5)),
      mixv > 0 and 10 or 3)
    local w = 44 + size * 60
    local hh = 14 + size * 12
    local x0, x1 = 64 - w / 2, 64 + w / 2
    local y0, y1 = 26 - hh / 2, 26 + hh / 2
    screen.level(mixv > 0 and 8 or 2)
    screen.rect(x0 + 0.5, y0 + 0.5, w, hh)
    screen.stroke()
    local sx, sy = x0 + 7, 26
    screen.level(mixv > 0 and 15 or 4)
    screen.rect(sx - 1, sy - 1, 2, 2)
    screen.fill()
    if mixv > 0 then
      screen.level(6)
      for k = 0, 1 do
        local a = k * 2.4 + frame * 0.03
        local px2, py = sx, sy
        local dx, dy = cos(a), sin(a)
        for i = 0, 70 do
          px2 = px2 + dx
          py = py + dy
          if px2 <= x0 + 1 or px2 >= x1 - 1 then dx = -dx end
          if py <= y0 + 1 or py >= y1 - 1 then dy = -dy end
          if i % 3 == 0 then screen.rect(px2, py, 1, 1) end
        end
      end
      screen.fill()
    end
  end
end

-- page-dot x positions, top-right, computed once: dots cluster by signal
-- family — source (MIX LEVEL REC) · shape (WINDOW GRAIN STRETCH) · TAPE ·
-- fx (FILTER DELAY REVERB) — so position in the row tells you which part
-- of the instrument you're in.
local DOT_X = {}
do
  local GAP_AFTER = { [3] = true, [6] = true, [7] = true }
  local x = 126
  for i = #PAGES, 1, -1 do
    DOT_X[i] = x
    x = x - 4
    if i > 1 and GAP_AFTER[i - 1] then x = x - 2 end
  end
end

-- the status line for each of the 16 flag combos, built once: the header
-- redraws every frame, and only the combo index changes
local STATUS_STR = {}
do
  local flags = { "REC", "FZ", "TR", "TFZ" }
  for m = 0, 15 do
    local t = {}
    for b = 1, 4 do
      if m & (1 << (b - 1)) ~= 0 then t[#t + 1] = flags[b] end
    end
    STATUS_STR[m] = table.concat(t, " ")
  end
end

local function draw_header()
  -- title in the 2x pixel font, ALT chip beside it
  local w = ptext(PAGES[page], 2, 1, 2, 15)
  if alt then chip("ALT", 2 + w + 5, 1) end

  -- page dots, top-right: current page is a 3x3 block, the rest are 1px
  for i = 1, #PAGES do
    if i == page then
      screen.level(15)
      screen.rect(DOT_X[i] - 1, 1, 3, 3)
    else
      screen.level(2)
      screen.rect(DOT_X[i], 2, 1, 1)
    end
    screen.fill()
  end

  -- status flags blink under the dots: an armed recorder is impossible
  -- to miss from any page
  local m = (pget("rec", 0) == 1 and 1 or 0)
    + (pget("freeze", 0) == 1 and 2 or 0)
    + (pget("tape_rec", 0) == 1 and 4 or 0)
    + (pget("tape_freeze", 0) == 1 and 8 or 0)
  if m > 0 then
    ptext_r(STATUS_STR[m], 126, 6, 1,
      (frame % FPS) < (FPS / 2) and 15 or 4)
  end
end

function redraw()
  screen.clear()

  -- the transient value readout claims the top-right corner while active;
  -- page readouts (topright) yield to it
  flash_on = flash_id ~= nil and frame < flash_until
    and params.lookup[flash_id] ~= nil

  draw_header()
  draw_body()
  draw_footer()

  if flash_on then
    ptext_r((SHORT[flash_id] or "") .. " " ..
      string.upper(params:string(flash_id)), 126, 13, 1, 15)
  end

  screen.update()
end
