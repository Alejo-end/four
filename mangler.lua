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
-- STAGE 3 — record + granular + window + time-stretch modes + softcut TAPE.
-- FILTER/DELAY/REVERB are placeholders for stage 4. See SPEC/spec.md.

engine.name = "Mangler"

-- bring-up diagnostics: load milestones in maiden. If "script file executed"
-- appears without "init() called", the engine died in alloc — check the SC tab.
print("mangler: script file executed")

local sc = require "softcut"  -- the TAPE path: parallel ADC tap, own CPU core

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

-- waveform display: 128 amplitude bins over the buffer, filled as the write
-- head passes; pre_level decides how much of the old picture survives overdub
local wave = {}
for i = 1, 128 do wave[i] = 0 end
local wave_bin = 0

-- same idea for the tape loop: bins indexed by the tape head while recording
local twave = {}
for i = 1, 128 do twave[i] = 0 end
local twave_bin = 0
local twave_any = false

-- grain particles (visual only): spawned at the playhead at ~density rate,
-- spread by jitter, lifetime scaled by grain size
local particles = {}
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
  local lo, hi = math.min(a, b), math.max(a, b)
  return lo, hi, math.max(hi - lo, 0.001)
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
  -- tape head position events drive the TAPE page needle
  sc.phase_quant(1, 0.1)
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

-- page key actions (K2/K3 on key-down). all of them drive params, never
-- locals, so MIDI mappings stay in lockstep with the keys.
local KEY_MAP = {
  REC = {
    [2] = function() ptoggle("rec") end,
    [3] = function() ptoggle("freeze") end,
  },
  WINDOW = {
    [2] = function() params:set("pos_start", 0) params:set("pos_end", 1) end,
  },
  GRAIN = {
    [3] = function() params:set("pitch", 1.0) end,
  },
  STRETCH = {
    -- K2 cycles OFF -> GRAIN -> WARP -> PV -> OFF; K3 toggles spectral freeze
    [2] = function() params:set("mode", (params:get("mode") % 4) + 1) end,
    [3] = function() ptoggle("pv_freeze") end,
  },
  TAPE = {
    -- K2: toggle tape record; with K1 (alt) held it's momentary reverse
    [2] = function()
      if alt then
        params:set("tape_reverse", 1)
        held_gesture[2] = "tape_reverse"
      else
        ptoggle("tape_rec")
      end
    end,
    [3] = function()
      if alt then
        -- clear tape: wipe the loop and start over
        sc.buffer_clear()
        for i = 1, 128 do twave[i] = 0 end
        twave_any = false
        params:set("tape_freeze", 0)
        params:set("loop_start", 0)
        params:set("loop_end", 1)
      else
        ptoggle("tape_freeze")
      end
    end,
  },
  FILTER = {
    [2] = function() params:set("filt_type", (params:get("filt_type") % 3) + 1) end,
  },
  DELAY = {
    [3] = function() params:set("delay_fb", 0) end,
  },
}

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
  add_eng_control("pos_start", "win start",
    controlspec.new(0, 1, "lin", 0, 0.0, ""))
  add_eng_control("pos_end", "win end",
    controlspec.new(0, 1, "lin", 0, 1.0, ""))
  add_eng_control("scan", "scan rate",
    controlspec.new(-2, 2, "lin", 0, 1.0, "x"))
  add_eng_control("pos_jitter", "jitter",
    controlspec.new(0, 1, "lin", 0, 0.0, ""))

  params:add_group("grp_grain", "grain", 6)
  add_eng_control("size", "size",
    controlspec.new(0.01, 0.5, "exp", 0, 0.1, "s"))
  add_eng_control("density", "density",
    controlspec.new(1, 200, "exp", 0, 20, "hz"))
  add_eng_control("pitch", "pitch",
    controlspec.new(0.25, 4, "exp", 0, 1.0, "x"))
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
    end
    update_tape_rec()
  end)
  params:add_control("tape_rate", "tape rate",
    controlspec.new(-2, 2, "lin", 0, 1.0, "x"))
  params:set_action("tape_rate", update_tape_rate)
  params:add_binary("tape_reverse", "tape reverse", "momentary", 0)
  params:set_action("tape_reverse", update_tape_rate)
  params:add_control("loop_start", "loop start",
    controlspec.new(0, 1, "lin", 0, 0.0, ""))
  params:set_action("loop_start", update_tape_loop)
  params:add_control("loop_end", "loop end",
    controlspec.new(0, 1, "lin", 0, 1.0, ""))
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

  params:bang()
end

-- ============================================================================
-- visuals: waveform bins + grain particles
-- ============================================================================

-- track the buffer's contents as the write head passes over it
local function update_wave()
  if pget("rec", 0) == 1 and pget("freeze", 0) == 0 then
    local bin = math.floor(clamp(rec_phase, 0, 0.999) * 128) + 1
    if bin ~= wave_bin then
      -- entering a fresh bin: previous content survives by the overdub amount
      wave[bin] = math.max(wave[bin] * pget("pre_level", 0), rec_amp)
      wave_bin = bin
    else
      wave[bin] = math.max(wave[bin], rec_amp)
    end
  end
end

-- track the tape loop's contents as the head records (input amplitude,
-- since softcut exposes no per-voice output meter); tape_pre sets survival
local function update_tape_wave()
  if pget("tape_rec", 0) == 1 and pget("tape_freeze", 0) == 0 then
    local bin = math.floor(clamp(tape_phase, 0, 0.999) * 128) + 1
    local a = math.max(amp_in[1], amp_in[2])
    if a > 0.01 then twave_any = true end
    if bin ~= twave_bin then
      twave[bin] = math.max(twave[bin] * pget("tape_pre", 0), a)
      twave_bin = bin
    else
      twave[bin] = math.max(twave[bin], a)
    end
  end
end

local function update_particles()
  if not params.lookup["density"] then return end
  local lo, hi, span = window_bounds()
  local jit = pget("pos_jitter", 0)
  spawn_acc = spawn_acc + pget("density", 20) / FPS
  while spawn_acc >= 1 do
    spawn_acc = spawn_acc - 1
    if #particles < 32 then
      local px = clamp(play_phase + (math.random() * 2 - 1) * jit * span, 0, 1)
      particles[#particles + 1] = {
        x = px * 127,
        y = 17 + math.random() * 22,
        lvl = 13,
        decay = 13 / math.max(pget("size", 0.1) * FPS * 4, 2),
      }
    else
      spawn_acc = 0
    end
  end
  for i = #particles, 1, -1 do
    local p = particles[i]
    p.lvl = p.lvl - p.decay
    if p.lvl < 1 then table.remove(particles, i) end
  end
end

-- ============================================================================
-- norns callbacks
-- ============================================================================

function init()
  print("mangler: init() called")
  init_params()
  init_tape()
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
      -- never draw over the system menu
      if norns.menu.status() == false then redraw() end
    end
  end)

  redraw()
end

function cleanup()
  for _, p in ipairs(polls) do p:stop() end
  if redraw_clock then clock.cancel(redraw_clock) end
  sc.poll_stop_phase()
end

function enc(n, d)
  if n == 1 then
    page = clamp(page + d, 1, #PAGES)
  else
    local id = enc_param(n)
    -- params.lookup guard: a missing param must not throw
    if id and params.lookup[id] then params:delta(id, d) end
  end
  redraw()
end

function key(n, z)
  if n == 1 then
    alt = (z == 1)
  else
    held[n] = (z == 1)
    if z == 1 then
      local acts = KEY_MAP[PAGES[page]]
      local fn = acts and acts[n]
      if fn then fn() end
    else
      gesture_release(n)
    end
  end
  redraw()
end

-- ============================================================================
-- screen
-- ============================================================================
-- layout: header y0..11  (title, ALT tag, page dots, status flags)
--         body   y15..40 (per-page visualization, BAND_T..BAND_B)
--         footer y44..63 (name+value readouts, then the hardware row:
--                         E2 hex dial . K2 pill . K3 pill . E3 hex dial —
--                         mirroring the physical panel left to right)

local BAND_T, BAND_B = 15, 40

-- per-page key pills: { k2, k3, k2_alt, k3_alt }. each def is
-- { label, active_fn }; when active_fn returns true the pill draws inverted
-- (filled box, knocked-out text = engaged, like a lit hardware button).
-- alt defs fall back to the un-alt def; nil draws a dim "--" pill so the
-- footer geometry never changes between pages.
local function pon(id)
  return function() return pget(id, 0) == 1 end
end

local KEY_LABELS = {
  REC     = { { "REC", pon("rec") }, { "FRZ", pon("freeze") } },
  WINDOW  = { { "RST" }, nil },
  GRAIN   = { nil, { "PT=1" } },
  STRETCH = { { "MODE" }, { "PVFZ", pon("pv_freeze") } },
  TAPE    = { { "REC", pon("tape_rec") }, { "FRZ", pon("tape_freeze") },
              { "REV", pon("tape_reverse") }, { "CLR" } },
  FILTER  = { { "TYPE" }, nil },
  DELAY   = { nil, { "KILL" } },
}

local function key_def(n)
  local defs = KEY_LABELS[PAGES[page]]
  if not defs then return nil end
  local i = (n == 2) and 1 or 2
  if alt and defs[i + 2] then return defs[i + 2] end
  return defs[i]
end

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
-- a hexagon renders crisp at this size where a circle goes lumpy.
local function draw_hex_dial(cx, cy, r, val)
  screen.level(4)
  for i = 0, 6 do
    local a = -math.pi / 2 + i * math.pi / 3
    local x, y = cx + math.cos(a) * r, cy + math.sin(a) * r
    if i == 0 then screen.move(x, y) else screen.line(x, y) end
  end
  screen.stroke()
  if val then
    local a = math.pi * 0.75 + clamp(val, 0, 1) * math.pi * 1.5
    screen.level(15)
    screen.move(cx, cy)
    screen.line(cx + math.cos(a) * (r - 2), cy + math.sin(a) * (r - 2))
    screen.stroke()
  end
end

-- key pill: outline = idle, inverted = engaged. `dim` for unassigned keys.
local function draw_pill(cx, y, label, on, dim)
  local w = screen.text_extents(label) + 6
  local x = math.floor(cx - w / 2)
  if on then
    screen.level(15)
    screen.rect(x, y, w, 9)
    screen.fill()
    screen.level(0)
    screen.move(cx, y + 7)
    screen.text_center(label)
  else
    screen.level(dim and 1 or 4)
    screen.rect(x + 0.5, y + 0.5, w, 9)
    screen.stroke()
    screen.level(dim and 2 or 10)
    screen.move(cx, y + 7)
    screen.text_center(label)
  end
end

-- name (dim) + value (bright) inline readout for one encoder
local function draw_enc_readout(n, right)
  local id = enc_param(n)
  if not (id and params.lookup[id]) then
    screen.level(2)
    screen.move(right and 128 or 0, 49)
    if right then screen.text_right("E" .. n .. " --")
    else screen.text("E" .. n .. " --") end
    return
  end
  local name = string.upper(string.sub(params:lookup_param(id).name, 1, 7))
  local val = params:string(id)
  if right then
    screen.level(15)
    screen.move(128, 49)
    screen.text_right(val)
    screen.level(4)
    screen.move(128 - screen.text_extents(val) - 3, 49)
    screen.text_right(name)
  else
    screen.level(4)
    screen.move(0, 49)
    screen.text(name)
    screen.level(15)
    screen.move(screen.text_extents(name) + 3, 49)
    screen.text(val)
  end
end

-- the shared footer: readout row, then dial . pill . pill . dial,
-- laid out in the same order as the physical E2 K2 K3 E3
local function draw_footer()
  draw_enc_readout(2, false)
  draw_enc_readout(3, true)
  draw_hex_dial(6, 57, 6, param_norm(enc_param(2)))
  draw_hex_dial(121, 57, 6, param_norm(enc_param(3)))
  for n = 2, 3 do
    local def = key_def(n)
    local cx = (n == 2) and 52 or 76
    if def then
      local on = (def[2] and def[2]()) or held[n] == true
      draw_pill(cx, 52, def[1], on, false)
    else
      draw_pill(cx, 52, "--", false, true)
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

  -- waveform columns (sqrt + 2x gain for visual headroom on quiet material)
  for x = 0, 127 do
    local a = wave[x + 1]
    if a > 0.002 then
      local h = clamp(math.sqrt(math.min(a * 2, 1)) * half, 1, half)
      local nx = x / 127
      screen.level((nx >= lo and nx <= hi) and 12 or 2)
      screen.move(x, mid - h)
      screen.line(x, mid + h)
      screen.stroke()
    end
  end

  -- window underline + optional edge handles
  screen.level(4)
  screen.move(lo * 127, BAND_B + 2)
  screen.line(hi * 127, BAND_B + 2)
  screen.stroke()
  if handles then
    for _, e in ipairs({ lo, hi }) do
      screen.level(15)
      screen.move(e * 127, BAND_T - 2)
      screen.line(e * 127, BAND_B + 2)
      screen.stroke()
    end
  end

  -- playhead needle
  screen.level(15)
  local px = clamp(play_phase, 0, 1) * 127
  screen.move(px, BAND_T - 2)
  screen.line(px, BAND_B + 2)
  screen.stroke()

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
  for _, p in ipairs(particles) do
    screen.level(math.floor(p.lvl))
    screen.rect(p.x, p.y, 1, 1)
    screen.fill()
  end
end

-- vertical meter: x position, normalized amp 0..1
local function draw_meter(x, amp, label)
  local h = math.floor(clamp(math.sqrt(amp) * (BAND_B - BAND_T), 0, BAND_B - BAND_T))
  screen.level(1)
  screen.rect(x, BAND_T, 6, BAND_B - BAND_T)
  screen.fill()
  screen.level(12)
  if h > 0 then
    screen.rect(x, BAND_B - h, 6, h)
    screen.fill()
  end
  screen.level(3)
  screen.move(x + 3, BAND_B + 8)
  screen.text_center(label)
end

local function draw_body()
  local pname = PAGES[page]

  if pname == "MIX" then
    -- one control, drawn big: the engine <> tape fader (E2)
    local mixv = pget("mix", 0.5)
    screen.level(3)
    screen.move(14, 22)
    screen.text("engine")
    screen.move(114, 22)
    screen.text_right("tape")
    screen.level(2)
    screen.rect(14, 30, 100, 2)
    screen.fill()
    screen.level(15)
    screen.rect(12 + mixv * 100, 26, 3, 10)
    screen.fill()
  elseif pname == "LEVEL" then
    -- live meters + the system level params on the encoders
    local rows = {
      { "in",  math.sqrt(math.max(amp_in[1], amp_in[2])) },
      { "out", math.sqrt(math.max(amp_out[1], amp_out[2])) },
    }
    for i, r in ipairs(rows) do
      local y = 11 + i * 10
      screen.level(3)
      screen.move(22, y + 5)
      screen.text_right(r[1])
      screen.level(1)
      screen.rect(26, y, 98, 6)
      screen.fill()
      local w = math.floor(clamp(r[2], 0, 1) * 98)
      if w > 0 then
        screen.level(12)
        screen.rect(26, y, w, 6)
        screen.fill()
      end
    end
    screen.level(3)
    screen.move(0, 41)
    screen.text("monitor " ..
      (params.lookup["monitor_level"] and params:string("monitor_level") or "?"))
    screen.move(128, 41)
    screen.text_right("phones " ..
      (params.lookup["headphone_gain"] and params:string("headphone_gain") or "?"))
  elseif pname == "REC" then
    draw_strip(false)
    draw_particles()
    -- input meter rides the right edge so you can see what's being captured
    local h = math.floor(clamp(math.sqrt(math.max(amp_in[1], amp_in[2])) * (BAND_B - BAND_T), 0, BAND_B - BAND_T))
    screen.level(15)
    if h > 0 then
      screen.rect(125, BAND_B - h, 3, h)
      screen.fill()
    end
  elseif pname == "WINDOW" then
    draw_strip(true)
    -- scan direction + speed, top-right inside the band
    local scan = pget("scan", 1)
    screen.level(3)
    screen.move(126, BAND_T + 6)
    screen.text_right((scan < 0 and "<< " or ">> ") .. string.format("%.2fx", scan))
  elseif pname == "GRAIN" then
    draw_strip(false)
    draw_particles()
  elseif pname == "STRETCH" then
    -- transport layout: big mode + big speed up top, thin window bar below —
    -- nothing overlaps the text
    local m = params.lookup["mode"] and params:string("mode") or "?"
    screen.font_size(16)
    screen.level(12)
    screen.move(2, 28)
    screen.text(m)
    screen.level(15)
    screen.move(126, 28)
    screen.text_right(string.format("%.2fx", pget("scan", 1)))
    screen.font_size(8)
    if pget("pv_freeze", 0) == 1 and pget("mode", 2) == 4 then
      screen.level(15)
      screen.move(64, 24)
      screen.text_center("HELD")
    end
    -- thin transport bar: window segment + playhead
    local lo, hi, _ = window_bounds()
    screen.level(2)
    screen.move(0, 38)
    screen.line(128, 38)
    screen.stroke()
    screen.level(6)
    screen.move(lo * 127, 38)
    screen.line(hi * 127, 38)
    screen.stroke()
    screen.level(15)
    local px = clamp(play_phase, 0, 1) * 127
    screen.move(px, 34)
    screen.line(px, 42)
    screen.stroke()
  elseif pname == "TAPE" then
    -- tape strip: recorded material as waveform (bright inside the loop),
    -- loop handles, head needle (doubles as write head while recording)
    local a = pget("loop_start", 0)
    local b = pget("loop_end", 1)
    local lo, hi = math.min(a, b), math.max(a, b)
    local mid = (BAND_T + BAND_B) / 2
    local half = (BAND_B - BAND_T) / 2
    screen.level(1)
    screen.move(0, mid)
    screen.line(128, mid)
    screen.stroke()
    for x = 0, 127 do
      local amp = twave[x + 1]
      if amp > 0.002 then
        local h = clamp(math.sqrt(math.min(amp * 2, 1)) * half, 1, half)
        local nx = x / 127
        screen.level((nx >= lo and nx <= hi) and 12 or 2)
        screen.move(x, mid - h)
        screen.line(x, mid + h)
        screen.stroke()
      end
    end
    screen.level(4)
    screen.move(lo * 127, BAND_B + 2)
    screen.line(hi * 127, BAND_B + 2)
    screen.stroke()
    for _, e in ipairs({ lo, hi }) do
      screen.level(15)
      screen.move(e * 127, BAND_T - 2)
      screen.line(e * 127, BAND_B + 2)
      screen.stroke()
    end
    screen.level(15)
    local tx = clamp(tape_phase, 0, 1) * 127
    screen.move(tx, BAND_T - 2)
    screen.line(tx, BAND_B + 2)
    screen.stroke()
    if pget("tape_rec", 0) == 1 and pget("tape_freeze", 0) == 0 then
      screen.level((frame % FPS) < (FPS / 2) and 12 or 3)
      screen.move(2, 21)
      screen.text("rec")
    elseif not twave_any then
      screen.level(3)
      screen.move(64, mid - 5)
      screen.text_center("empty loop — K2 to record")
    end
    -- effective rate; reverse flips the sign live
    local r = pget("tape_rate", 1) * (pget("tape_reverse", 0) == 1 and -1 or 1)
    screen.level(10)
    screen.move(127, 21)
    screen.text_right(string.format("%+.2fx", r))
  elseif pname == "FILTER" then
    -- stylized response curve: cutoff on a log axis, resonance bump
    local ft = pget("filt_type", 1)
    local res = pget("resonance", 0)
    local cx = clamp((math.log(pget("cutoff", 20000) / 20) / math.log(1000)) * 127, 0, 127)
    local mid = 26
    screen.level(8)
    if ft == 1 then       -- LP
      screen.move(0, mid)
      screen.line(math.max(cx - 10, 0), mid)
      screen.line(cx, mid - res * 10)
      screen.line(math.min(cx + 14, 127), BAND_B)
    elseif ft == 2 then   -- HP
      screen.move(127, mid)
      screen.line(math.min(cx + 10, 127), mid)
      screen.line(cx, mid - res * 10)
      screen.line(math.max(cx - 14, 0), BAND_B)
    else                  -- BP
      screen.move(math.max(cx - 26, 0), BAND_B)
      screen.line(cx, mid - 6 - res * 6)
      screen.line(math.min(cx + 26, 127), BAND_B)
    end
    screen.stroke()
    screen.level(12)
    screen.move(2, 21)
    screen.text(params.lookup["filt_type"] and params:string("filt_type") or "?")
  elseif pname == "DELAY" then
    -- zones: readout row y<=20, viz band y24..42 — never overlapping
    local t = pget("delay_time", 0.3)
    local fb = pget("delay_fb", 0.3)
    local mixv = pget("delay_mix", 0)
    screen.level(mixv > 0 and 10 or 3)
    screen.move(127, 20)
    screen.text_right(string.format("mix %d%%", math.floor(mixv * 100 + 0.5)))
    if mixv == 0 then
      screen.level(3)
      screen.move(0, 20)
      screen.text("E2 opens the mix")
    end
    -- echo train: source tick + repeats spaced by time, decaying by feedback
    screen.level(1)
    screen.move(0, 42)
    screen.line(128, 42)
    screen.stroke()
    screen.level(12)
    screen.rect(4, 24, 2, 18)
    screen.fill()
    local x = 4
    local lvl = 1.0
    for i = 1, 10 do
      x = x + t * 56
      lvl = lvl * fb
      if x > 125 or lvl < 0.04 then break end
      local hh = math.max(18 * lvl, 1)
      screen.level(math.max(math.floor(12 * lvl), 1))
      screen.rect(x, 42 - hh, 2, hh)
      screen.fill()
    end
  elseif pname == "REVERB" then
    -- zones: readout row y<=20, viz band y24..42 — never overlapping
    local size = pget("rev_size", 0.5)
    local mixv = pget("rev_mix", 0)
    screen.level(mixv > 0 and 10 or 3)
    screen.move(127, 20)
    screen.text_right(string.format("mix %d%%", math.floor(mixv * 100 + 0.5)))
    if mixv == 0 then
      screen.level(3)
      screen.move(0, 20)
      screen.text("E3 opens the mix")
    end
    -- impulse + decaying tail; tail length follows size
    screen.level(1)
    screen.move(0, 42)
    screen.line(128, 42)
    screen.stroke()
    screen.level(12)
    screen.rect(4, 24, 3, 18)
    screen.fill()
    local len = 10 + size * 110
    local x = 10
    while x < 10 + len and x < 126 do
      local frac = (x - 10) / len
      local lvl = math.floor(12 * (1 - frac))
      if lvl < 1 then break end
      local hh = math.max(18 * (1 - frac), 1)
      screen.level(lvl)
      screen.rect(x, 42 - hh, 2, hh)
      screen.fill()
      x = x + 4
    end
  end
end

function redraw()
  screen.clear()
  screen.font_face(1)
  screen.font_size(8)

  -- header: title, ALT tag (inverted), page dots, status flags
  screen.level(15)
  screen.move(0, 8)
  screen.text(PAGES[page])
  if alt then
    local ax = screen.text_extents(PAGES[page]) + 4
    local aw = screen.text_extents("ALT") + 5
    screen.level(15)
    screen.rect(ax, 1, aw, 8)
    screen.fill()
    screen.level(0)
    screen.move(ax + 3, 8)
    screen.text("ALT")
  end

  -- page dots, top-right row: current page is a 3x3 block, others 1px
  for i = 1, #PAGES do
    local x = 128 - (#PAGES - i + 1) * 5 + 1
    if i == page then
      screen.level(15)
      screen.rect(x - 1, 1, 3, 3)
    else
      screen.level(2)
      screen.rect(x, 2, 1, 1)
    end
    screen.fill()
  end

  -- status flags: blink at ~1hz under the dots, so an armed recorder is
  -- impossible to miss from any page
  local status = {}
  if pget("rec", 0) == 1 then status[#status + 1] = "REC" end
  if pget("freeze", 0) == 1 then status[#status + 1] = "FZ" end
  if pget("tape_rec", 0) == 1 then status[#status + 1] = "TR" end
  if pget("tape_freeze", 0) == 1 then status[#status + 1] = "TFZ" end
  if #status > 0 then
    screen.level((frame % FPS) < (FPS / 2) and 15 or 4)
    screen.move(128, 10)
    screen.text_right(table.concat(status, " "))
  end

  screen.level(1)
  screen.move(0, 12)
  screen.line(128, 12)
  screen.stroke()

  draw_body()
  draw_footer()

  screen.update()
end
