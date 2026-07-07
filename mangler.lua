-- mangler
-- live stereo sample-mangling instrument for external gear
-- (synth, drum machine, anything line-level)
--
-- 3 keys + 3 encoders. every parameter is MIDI-mappable (PARAMS menu).
--
-- E1 : page select (hold K1: jump page family)
-- E2 : primary param   (hold K1 -> alt param)
-- E3 : secondary param (hold K1 -> alt param)
-- K1 : alt / shift modifier (hold)
-- K2 : primary action
-- K3 : secondary action
--
-- STAGE 4 — record + granular + window + time-stretch modes + softcut TAPE
-- + filter/delay/reverb. See doc/spec.md.
--
-- MIDI notes play the sample chromatically: note-ons retune `pitch`
-- relative to the root note (PARAMS > keys). a USB typing keyboard works
-- too: ableton-style musical typing (A-row = white keys, W-row = black,
-- Z/X = octave down/up). see lib/minput.lua.
--
-- a grid is optional, never required: a monome grid — or a launchpad-style
-- MIDI grid controller via the midigrid library — adds note pads, window/
-- loop slice pads, and transport toggles. see lib/mgrid.lua.
--
-- this file is the orchestrator: state + params + key/encoder handlers.
-- everything else lives in lib/ modules (script-internal, not norns
-- engines): mfont (pixel font), mparticles (grain cloud), mtape (softcut),
-- minput (midi/keyboard notes), mgrid (grid surface), mpages (the screen).
-- they share one `ctx` table — params stay the single source of truth.

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
  "FILTER", "DELAY", "REVERB",
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
}

local Mfont = include "lib/mfont"
local Mparticles = include "lib/mparticles"
local Mtape = include "lib/mtape"
local Minput = include "lib/minput"
local Mgrid = include "lib/mgrid"
local Mpages = include "lib/mpages"

ctx.font = Mfont
ctx.particles = Mparticles
ctx.grid = Mgrid

Mparticles.init(ctx)
Mtape.init(ctx)
Minput.init(ctx)
Mgrid.init(ctx)
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
    -- octave throws on the playable pitch (alt: up); K3 re-centers
    k2 = { label = "OCT-",
      act = function()
        params:set("pitch", math.max(params:get("pitch") * 0.5, 0.25))
      end },
    k2_alt = { label = "OCT+",
      act = function()
        params:set("pitch", math.min(params:get("pitch") * 2, 4))
      end },
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
    k2 = { label = "WASH",
      act = function() params:set("rev_mix", 1) end },
    k3 = { label = "KILL",
      act = function() params:set("rev_mix", 0) end },
  },
}

-- the key def addressed by key n on the current page, alt-aware; alt falls
-- back to the un-alt def so a page needn't define both layers
local function key_def(n)
  local defs = KEYS[PAGES[ctx.page]]
  if not defs then return nil end
  if n == 2 then
    if ctx.alt then return defs.k2_alt or defs.k2 end
    return defs.k2
  end
  if ctx.alt then return defs.k3_alt or defs.k3 end
  return defs.k3
end

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
  -- FILTER/REVERB gain an ALT layer (K1): the wet-path controls the filter
  -- itself can't expose (RLPF/RHPF/BPF are freq+rq only)
  FILTER  = { "cutoff", "dry_wet", "resonance", "grain_level" },
  DELAY   = { "delay_mix", "delay_time", "delay_fb", "drive" },
  REVERB  = { "rev_size", "delay_mix", "rev_mix", "dry_wet" },
}

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

  params:add_group("grp_rec", "rec", 6)
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
  Minput.cleanup()
  Mgrid.cleanup()
  Mtape.cleanup()
end

-- K1+E1 leaps between the page families the header dots draw:
-- source (MIX·LEVEL·REC) · shape (WINDOW·GRAIN·STRETCH) · TAPE · fx
local PAGE_GROUPS = { 1, 4, 7, 8 }

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
    end
  end
  redraw()
end

function redraw()
  Mpages.redraw()
end
