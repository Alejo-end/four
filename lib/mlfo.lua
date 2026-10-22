-- mlfo: two modulators that move any one knob each, a fifth driver of the
-- params beside the keys, the encoders, MIDI and the motion loop.
--
-- A modulator writes its target param every frame, as base + depth x wave,
-- in the param's own 0..1 (unmapped) space so a curve-mapped knob such as
-- cutoff swings evenly. The BASE is where the knob stands without the
-- modulator. Anything else that moves the knob (a hand, MIDI, a scene, the
-- morph, a motion lane) is seen by polling: a value that is not the one this
-- module last wrote is a new base, and the wave rides on top of it. That is
-- the same polling the motion looper uses, for the same reason (an encoder
-- on the device goes through paramset:delta, which no wrapper sees).
--
-- After each write it tells the motion looper the move was not a hand
-- (Mmotion.account), so a gesture loop never records a modulator.
--
-- Shapes: SINE, TRI, SQUARE, RAMP, RANDOM (a new level each cycle), and ENV,
-- the input's envelope: the knob follows how hard the gear plays. Depth is
-- -1..1; negative inverts, so ENV with negative depth ducks. A period other
-- than FREE locks the phase to the clock's beat count, so a modulator stays
-- on the bar through a tempo change.
--
-- The TARGETS list is APPEND-ONLY: the target param stores an index into it,
-- so a PSET or a PMAP names a target by its position here.

local floor, min, max, sin, pi = math.floor, math.min, math.max, math.sin, math.pi
local C, pget, FPS

local TARGETS = {
  "cutoff", "resonance", "drive", "dry_wet",
  "delay_mix", "delay_fb", "rev_mix", "rev_size", "shimmer",
  "scan", "pitch", "size", "density", "spread", "pan", "grain_jitter",
  "pos_jitter", "warp_window", "clouds_pos", "clouds_tex",
  "tape_rate", "mix", "lay1_level", "lay2_level", "pad_level", "wear",
}
local SHAPES = { "SINE", "TRI", "SQUARE", "RAMP", "RANDOM", "ENV" }
local ENV_SHAPE = 6
-- beats per cycle, matching the lfoN_period option names (nil = FREE)
local PERIODS = { false, 1, 2, 4, 8, 16, 32 }
local PERIOD_NAMES = { "FREE", "1 BEAT", "2 BEAT", "1 BAR", "2 BAR", "4 BAR", "8 BAR" }
local N = 2

local M = {
  TARGETS = TARGETS, SHAPES = SHAPES, PERIOD_NAMES = PERIOD_NAMES, N = N,
  env = 0,        -- the input envelope, 0..1, shared by every ENV modulator
  mods = {},      -- mods[i] = { id, base, wrote, phase, cycle, held } (state)
}
for i = 1, N do
  M.mods[i] = { id = nil, base = 0, wrote = nil, phase = 0, cycle = -1, held = 0 }
end

local function pid(i, what) return "lfo" .. i .. "_" .. what end

-- the target param id of modulator i, or nil when it is OFF
local function target_of(i)
  local t = floor(pget(pid(i, "target"), 1) + 0.5)
  return TARGETS[t - 1]
end

-- one value of the wave, -1..1 (ENV is 0..1, handled by the caller)
local function wave(shape, ph, m)
  if shape == 1 then return sin(ph * 2 * pi) end
  if shape == 2 then return ph < 0.5 and (ph * 4 - 1) or (3 - ph * 4) end
  if shape == 3 then return ph < 0.5 and 1 or -1 end
  if shape == 4 then return ph * 2 - 1 end
  return m.held                      -- RANDOM: the level drawn this cycle
end

local function cs_of(id)
  local p = params:lookup_param(id)
  return p and p.controlspec
end

-- put the knob back where it stands without the modulator
local function restore(m)
  if m.id and m.wrote ~= nil then
    local cur = pget(m.id, m.base)
    -- only when the knob still holds the modulator's value: if something
    -- else moved it last, that value stands
    if math.abs(cur - m.wrote) < 1e-9 then
      params:set(m.id, m.base)
      if C.motion and C.motion.account then C.motion.account(m.id) end
    end
  end
  m.id, m.wrote = nil, nil
end

local function beats_now()
  return (clock.get_beats and clock.get_beats()) or 0
end

-- one frame. `amp`: the input level now (max of the two ADC polls).
function M.tick(amp)
  -- the envelope: fast up, slower down, on a square-root scale so a quiet
  -- source still moves the knob
  local a = math.sqrt(min(max(amp or 0, 0), 1))
  M.env = M.env + (a - M.env) * (a > M.env and 0.6 or 0.15)
  for i = 1, N do
    local m = M.mods[i]
    local id = target_of(i)
    local depth = pget(pid(i, "depth"), 0)
    if id ~= m.id or math.abs(depth) < 0.001 then
      restore(m)
      if id and math.abs(depth) >= 0.001 then
        m.id, m.base, m.wrote = id, pget(id, 0), nil
        print("mangler: LFO " .. i .. " moves " .. params:lookup_param(id).name)
      end
    end
    local cs = m.id and cs_of(m.id)
    if cs then
      local cur = pget(m.id, m.base)
      if m.wrote == nil or math.abs(cur - m.wrote) > 1e-9 then
        m.base = cur                 -- something else moved the knob
      end
      local shape = floor(pget(pid(i, "shape"), 1) + 0.5)
      local per = PERIODS[floor(pget(pid(i, "period"), 1) + 0.5)]
      if per then
        local b = beats_now() / per
        m.phase = b - floor(b)
        local cyc = floor(b)
        if cyc ~= m.cycle then m.cycle = cyc; m.held = math.random() * 2 - 1 end
      else
        local ph = m.phase + pget(pid(i, "rate"), 0.5) / FPS
        if ph >= 1 then m.held = math.random() * 2 - 1 end
        m.phase = ph - floor(ph)
      end
      local off
      if shape == ENV_SHAPE then off = depth * M.env
      else off = depth * 0.5 * wave(shape, m.phase, m) end
      local raw = min(max(cs:unmap(m.base) + off, 0), 1)
      local v = cs:map(raw)
      params:set(m.id, v)
      m.wrote = pget(m.id, v)        -- as stored (a quantum may round it)
      if C.motion and C.motion.account then C.motion.account(m.id) end
    end
  end
end

-- any modulator set to move a knob (the purity mark asks). Read from the
-- params, not from the tick's state, so it is true from the moment it is set.
function M.active()
  for i = 1, N do
    if target_of(i) and math.abs(pget(pid(i, "depth"), 0)) >= 0.001 then return true end
  end
  return false
end

-- every knob back to its base (cleanup)
function M.restore_all()
  for i = 1, N do restore(M.mods[i]) end
end

-- a PSET save has just written the file (norns fires action_write AFTER it),
-- so a modulated knob went in where the wave had it. Put its BASE in the
-- file instead: a session saved mid-sweep must come back where the knob
-- stands, not half a swing off. norns writes one `"id": value` line per param.
function M.pset_patch(filename)
  local fix = {}
  for i = 1, N do
    local m = M.mods[i]
    if m.id and m.wrote ~= nil then fix[m.id] = m.base end
  end
  if next(fix) == nil then return end
  local f = io.open(filename, "r")
  if not f then return end
  local lines = {}
  for line in f:lines() do
    local id = line:match('^"([^"]+)": ')
    lines[#lines + 1] = (id and fix[id] ~= nil)
      and ('"' .. id .. '": ' .. tostring(fix[id])) or line
  end
  f:close()
  f = io.open(filename, "w")
  if not f then return end
  f:write(table.concat(lines, "\n"), "\n")
  f:close()
end

function M.init(ctx)
  C = ctx
  pget, FPS = ctx.pget, ctx.FPS
end

-- the params, added by mangler.lua's init_params after every target exists
-- (an option's names are the targets' own names)
function M.add_params(add_group)
  local names = { "OFF" }
  for k = 1, #TARGETS do
    local p = params:lookup_param(TARGETS[k])
    names[k + 1] = p and p.name or TARGETS[k]
  end
  add_group("grp_lfo", "modulators", 5 * N)
  for i = 1, N do
    params:add_option(pid(i, "target"), "LFO " .. i .. " target", names, 1)
    params:add_option(pid(i, "shape"), "LFO " .. i .. " shape", SHAPES, 1)
    params:add_option(pid(i, "period"), "LFO " .. i .. " period", PERIOD_NAMES, 1)
    params:add_control(pid(i, "rate"), "LFO " .. i .. " rate",
      controlspec.new(0.01, 10, "exp", 0, 0.5, "Hz"))
    params:add_control(pid(i, "depth"), "LFO " .. i .. " depth",
      controlspec.new(-1, 1, "lin", 0, 0, ""))
  end
end

return M
