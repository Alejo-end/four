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
-- STAGE 2 — record + granular + window + time-stretch modes.
-- TAPE/FILTER/DELAY/REVERB are placeholders for later stages.
-- See SPEC/spec.md.

engine.name = "Mangler"

-- bring-up diagnostics: load milestones in maiden. If "script file executed"
-- appears without "init() called", the engine died in alloc — check the SC tab.
print("mangler: script file executed")

local sc = require "softcut"  -- reserved for STAGE 3 (tape); unused until then

-- ============================================================================
-- state
-- ============================================================================

local PAGES = {
  "MIX", "REC", "WINDOW", "GRAIN", "STRETCH", "TAPE", "FILTER", "DELAY", "REVERB",
}
local page = 1
local alt = false          -- K1 held
local held = {}            -- held[n] = true while key n is down (global, page-independent)

local FPS = 15
local frame = 0            -- redraw frame counter (drives the REC blink)
local play_phase = 0       -- engine poll: normalized playhead in the buffer
local rec_phase = 0        -- engine poll: normalized write-head position
local rec_arm_phase = 0    -- write-head position when rec was armed
local rec_amp = 0          -- engine poll: amplitude of what's being written
local amp_in = { 0, 0 }    -- system polls: live input amplitude L/R
local amp_out = { 0, 0 }   -- system polls: output amplitude L/R
local polls = {}
local redraw_clock

-- waveform display: 128 amplitude bins over the buffer, filled as the write
-- head passes; pre_level decides how much of the old picture survives overdub
local wave = {}
for i = 1, 128 do wave[i] = 0 end
local wave_bin = 0

-- grain particles (visual only): spawned at the playhead at ~density rate,
-- spread by jitter, lifetime scaled by grain size
local particles = {}
local spawn_acc = 0

-- which params each page's encoders address: { e2, e2_alt, e3, e3_alt }.
-- nil entries draw as "--" until the owning stage wires them.
local ENC_MAP = {
  MIX     = { "mix", "out_level", "sc_level", "cut_level" },
  REC     = { "rec_level", "pre_level", "dry_wet", "resample" },
  WINDOW  = { "pos_start", "scan", "pos_end", "pos_jitter" },
  GRAIN   = { "size", "spread", "density", "grain_level" },
  STRETCH = { "scan", "pitch", "warp_window", "warp_rand" },
  TAPE    = { nil, nil, nil, nil },
  FILTER  = { nil, nil, nil, nil },
  DELAY   = { nil, nil, nil, nil },
  REVERB  = { nil, nil, nil, nil },
}

-- per-page key hints + placeholder stage labels
local KEY_HINTS = {
  REC     = "K2 rec / K3 freeze",
  WINDOW  = "K2 reset window",
  GRAIN   = "K3 pitch reset",
  STRETCH = "K2 mode / K3 pv freeze",
}
local COMING = {
  TAPE    = "softcut tape — stage 3",
  FILTER  = "lp/hp/bp filter — stage 4",
  DELAY   = "delay — stage 4",
  REVERB  = "reverb — stage 4",
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
  params:add_control("mix", "sc<>tape mix",
    controlspec.new(0, 1, "lin", 0, 0.5, ""))        -- wired in S3
  params:add_control("out_level", "out level",
    controlspec.new(0, 1.5, "lin", 0, 1.0, ""))       -- wired in S3
  params:add_control("sc_level", "sc level",
    controlspec.new(0, 1, "lin", 0, 1.0, ""))
  params:set_action("sc_level", function(v)
    if engine.level then engine.level(v) end   -- engine command is `level`
  end)
  -- id "tape_level" is RESERVED by the system TAPE deck; "cut_level" avoids it
  params:add_control("cut_level", "tape level",
    controlspec.new(0, 1, "lin", 0, 1.0, ""))         -- wired in S3

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

  params:bang()
end

-- ============================================================================
-- gestures
-- ============================================================================

local function gesture_release(n)
  -- no-op until a momentary gesture (stutter, reverse...) lands in S3.
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
-- layout: header y<=9 (page name, ALT, page dots, REC/FZ status)
--         body  y12..44 (per-page visualization)
--         hints y48 (key actions, dim)
--         params y53..62 (two name/value cells for E2/E3)

local BAND_T, BAND_B = 15, 41  -- visualization band

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
    -- live signal: input pair left, output pair right
    draw_meter(28, amp_in[1], "")
    draw_meter(36, amp_in[2], "in")
    draw_meter(86, amp_out[1], "")
    draw_meter(94, amp_out[2], "out")
    screen.level(3)
    screen.move(64, 30)
    screen.text_center(">")
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
    -- scan direction + speed, right-aligned on the hint row
    local scan = pget("scan", 1)
    screen.level(3)
    screen.move(128, 49)
    screen.text_right((scan < 0 and "<< " or ">> ") .. string.format("%.2fx", scan))
  elseif pname == "GRAIN" then
    draw_strip(false)
    draw_particles()
  elseif pname == "STRETCH" then
    draw_strip(false)
    if pget("mode", 2) == 2 then draw_particles() end
    -- the stretch, unmissable: big speed readout + active algorithm
    local m = params.lookup["mode"] and params:string("mode") or "?"
    screen.level(10)
    screen.move(30, 26)
    screen.text_center(m)
    screen.font_size(16)
    screen.level(15)
    screen.move(88, 31)
    screen.text_center(string.format("%.2fx", pget("scan", 1)))
    screen.font_size(8)
    if pget("pv_freeze", 0) == 1 and pget("mode", 2) == 4 then
      screen.level(15)
      screen.move(30, 35)
      screen.text_center("HELD")
    end
  else
    screen.level(2)
    screen.move(64, 30)
    screen.text_center(COMING[pname] or "")
  end
end

local function enc_cell(x, n)
  local id = enc_param(n)
  screen.move(x, 55)
  -- params.lookup guard: a missing param must never crash redraw — an error
  -- thrown here kills the menu->script screen handoff and wedges the whole UI
  if id and params.lookup[id] then
    screen.level(4)
    screen.text("E" .. n .. " " .. string.sub(params:lookup_param(id).name, 1, 11))
    screen.move(x, 63)
    screen.level(15)
    screen.text(params:string(id))
  else
    screen.level(2)
    screen.text("E" .. n .. " --")
  end
end

function redraw()
  screen.clear()

  -- header: page name, ALT, page dots, rec/freeze status
  screen.level(15)
  screen.move(0, 8)
  screen.text(PAGES[page])
  if alt then
    screen.level(15)
    screen.move(46, 8)
    screen.text("ALT")
  end
  for i = 1, #PAGES do
    screen.level(i == page and 15 or 2)
    screen.rect(62 + (i - 1) * 5, 4, 2, 2)
    screen.fill()
  end
  local status = {}
  if pget("rec", 0) == 1 then status[#status + 1] = "REC" end
  if pget("freeze", 0) == 1 then status[#status + 1] = "FZ" end
  if #status > 0 then
    -- REC blinks at ~1hz so an armed recorder is impossible to miss
    screen.level((frame % FPS) < (FPS / 2) and 15 or 4)
    screen.move(128, 8)
    screen.text_right(table.concat(status, " "))
  end
  screen.level(1)
  screen.move(0, 11)
  screen.line(128, 11)
  screen.stroke()

  draw_body()

  -- key hints
  local hint = KEY_HINTS[PAGES[page]]
  if hint then
    screen.level(2)
    screen.move(0, 49)
    screen.text(hint)
  end

  -- the two encoder cells
  enc_cell(0, 2)
  enc_cell(66, 3)

  screen.update()
end