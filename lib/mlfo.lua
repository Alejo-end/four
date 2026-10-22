-- mlfo: two modulators that each move the SOUND of one knob.
--
-- A modulator never writes its target param. The param stays where the hand,
-- MIDI, a scene, the morph or a motion lane left it: that is the knob, the
-- single source of truth, and everything that reads or stores it (scene
-- capture, the safe snapshot and UNDO, the throws, the motion looper, a PSET
-- save) sees the knob and never the wave. Each frame the modulator sends the
-- ENGINE the knob's value plus depth x wave, in the param's own 0..1
-- (unmapped) space, so a curve-mapped knob such as cutoff swings evenly, and
-- through the same send map the param's action uses (`ctx.eng_map`).
-- An earlier version wrote the param and tracked a "base" by polling. A
-- reviewer found what that costs: an encoder nudge moved the centre by the
-- whole swing, a hand on the knob could not be recorded, two modulators on
-- one knob ran away, and every snapshot stored where the wave happened to be.
--
-- So only ENGINE controls are targets (a plain `engine[id](v)` action). Two
-- modulators on one knob add their swings. A target that the engine frees at
-- 0 (delay and reverb mix) is held just above 0 while modulated, or the FX
-- synth would be freed and spawned again every cycle; at depth 0 the knob's
-- own value goes back to the engine, so a mix at 0 frees it as before.
-- Pages draw the knob, not the swing; the header's LF says a modulator runs.
--
-- Shapes: SINE, TRI, SQUARE, RAMP, RANDOM (a new level each cycle), and ENV,
-- the input's envelope. Depth is -1..1; negative inverts, so ENV with a
-- negative depth ducks. A period other than FREE locks the phase to the
-- clock's beat count, so a modulator stays on the bar through a tempo change.
--
-- The TARGETS list is APPEND-ONLY: the target param stores an index into it,
-- so a PSET or a PMAP names a target by its position here.

local floor, min, max, sin, pi = math.floor, math.min, math.max, math.sin, math.pi
local C, pget, FPS

local TARGETS = {
  "cutoff", "resonance", "drive", "dry_wet",
  "delay_mix", "delay_fb", "rev_mix", "rev_size", "shimmer",
  "scan", "size", "density", "spread", "pan", "grain_jitter",
  "pos_jitter", "warp_window", "clouds_pos", "clouds_tex", "wear",
}
-- kept above 0 while modulated: the engine frees these synths at 0
local FLOOR = { delay_mix = 0.001, rev_mix = 0.001 }
local SHAPES = { "SINE", "TRI", "SQUARE", "RAMP", "RANDOM", "ENV" }
local ENV_SHAPE = 6
-- beats per cycle, matching the lfoN_period option names (false = FREE)
local PERIODS = { false, 1, 2, 4, 8, 16, 32 }
local PERIOD_NAMES = { "FREE", "1 BEAT", "2 BEAT", "1 BAR", "2 BAR", "4 BAR", "8 BAR" }
local N = 2

local M = {
  TARGETS = TARGETS, SHAPES = SHAPES, PERIOD_NAMES = PERIOD_NAMES, N = N,
  env = 0,        -- the input envelope, 0..1, shared by every ENV modulator
  mods = {},      -- mods[i] = { id, phase, cycle, held, out (0..1) }
}
for i = 1, N do
  M.mods[i] = { id = nil, phase = 0, cycle = -1, held = 0, out = 0.5 }
end
local sum = {}    -- this frame's swing per target id (reused, never rebuilt)

-- the param ids, built once (the redraw path asks active() every frame)
local PID = {}
for i = 1, N do
  PID[i] = {}
  for _, w in ipairs({ "target", "shape", "period", "rate", "depth" }) do
    PID[i][w] = "lfo" .. i .. "_" .. w
  end
end

-- the target param id of modulator i, or nil when it is OFF
local function target_of(i)
  return TARGETS[floor(pget(PID[i].target, 1) + 0.5) - 1]
end

local function depth_of(i)
  local d = pget(PID[i].depth, 0)
  return math.abs(d) >= 0.001 and d or 0
end

-- one value of the wave, -1..1 (ENV is 0..1, handled by the caller)
local function wave(shape, ph, m)
  if shape == 1 then return sin(ph * 2 * pi) end
  if shape == 2 then return ph < 0.5 and (ph * 4 - 1) or (3 - ph * 4) end
  if shape == 3 then return ph < 0.5 and 1 or -1 end
  if shape == 4 then return ph * 2 - 1 end
  return m.held                      -- RANDOM: the level drawn this cycle
end

-- send the engine a value for param `id`, through the param's own send map
local function send(id, v)
  local f = engine[id]
  if not f then return end
  local map = C.eng_map and C.eng_map[id]
  f(map and map(v) or v)
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
  for id in pairs(sum) do sum[id] = nil end
  for i = 1, N do
    local m = M.mods[i]
    local depth = depth_of(i)
    local id = depth ~= 0 and target_of(i) or nil
    if id ~= m.id then
      -- the knob it left gets its own value back (unless the other one
      -- still swings it: that one's send below then wins)
      if m.id then send(m.id, pget(m.id, 0)) end
      if id then print("mangler: LFO " .. i .. " moves " .. params:lookup_param(id).name) end
      m.id = id
    end
    -- the wave runs whether or not it moves a knob: `out` (0..1) is also a
    -- source for the modulation outputs (lib/mout.lua)
    local shape = floor(pget(PID[i].shape, 1) + 0.5)
    local per = PERIODS[floor(pget(PID[i].period, 1) + 0.5)]
    -- a RANDOM level is drawn only for a RANDOM wave, so the other shapes,
    -- which run whether or not they move a knob, leave the orbit's random
    -- sequence alone. Switched to RANDOM, it draws at once, not a cycle late.
    local rnd = shape == 5
    if rnd and m.shape ~= 5 then m.held = math.random() * 2 - 1 end
    m.shape = shape
    if per then
      local b = beats_now() / per
      m.phase = b - floor(b)
      local cyc = floor(b)
      if cyc ~= m.cycle then
        m.cycle = cyc
        if rnd then m.held = math.random() * 2 - 1 end
      end
    else
      local ph = m.phase + pget(PID[i].rate, 0.5) / FPS
      if ph >= 1 and rnd then m.held = math.random() * 2 - 1 end
      m.phase = ph - floor(ph)
    end
    local w = shape == ENV_SHAPE and M.env or wave(shape, m.phase, m)
    m.out = shape == ENV_SHAPE and w or (w + 1) * 0.5
    if id then
      local off = shape == ENV_SHAPE and depth * w or depth * 0.5 * w
      sum[id] = (sum[id] or 0) + off
    end
  end
  for id in pairs(sum) do send(id, M.swung(id, pget(id, 0))) end
end

-- the delay's feedback HOLD: with the delay mix at 0 the engine keeps the
-- delay synth alive only while the (curved) feedback is above 0.9, so a
-- held loop survives a KILL. A swing across that line would free the synth
-- and drop the loop each cycle, so it is kept on the knob's own side of it.
local FB_HOLD = 0.9
local function fb_sent(v)
  local map = C.eng_map and C.eng_map.delay_fb
  return map and map(v) or v
end

-- is param `id` swung this frame (its action asks, before it sends)
function M.swinging(id) return sum[id] ~= nil end

-- knob value `v` of param `id` with this frame's swing on it, as the engine
-- should get it (before the send map)
function M.swung(id, v)
  local off = sum[id]
  if not off then return v end
  local cs = params:lookup_param(id).controlspec
  local w = cs:map(min(max(cs:unmap(v) + off, 0), 1))
  if FLOOR[id] then w = max(w, FLOOR[id]) end
  if id == "delay_fb" and pget("delay_mix", 0) <= 0 then
    local above = fb_sent(v) > FB_HOLD
    -- step back toward the knob until the sent value is on its side
    for _ = 1, 20 do
      if (fb_sent(w) > FB_HOLD) == above then break end
      w = (w + v) / 2
    end
    if (fb_sent(w) > FB_HOLD) ~= above then w = v end
  end
  return w
end


-- any modulator set to move a knob (the purity mark and the header ask). Read
-- from the params, so it is true from the moment it is set.
function M.active()
  for i = 1, N do
    if depth_of(i) ~= 0 and target_of(i) then return true end
  end
  return false
end

-- every modulated knob's own value back to the engine (cleanup)
function M.restore_all()
  for i = 1, N do
    local m = M.mods[i]
    if m.id then send(m.id, pget(m.id, 0)) end
    m.id = nil
  end
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
    params:add_option(PID[i].target, "LFO " .. i .. " target", names, 1)
    params:add_option(PID[i].shape, "LFO " .. i .. " shape", SHAPES, 1)
    params:add_option(PID[i].period, "LFO " .. i .. " period", PERIOD_NAMES, 1)
    params:add_control(PID[i].rate, "LFO " .. i .. " rate",
      controlspec.new(0.01, 10, "exp", 0, 0.5, "Hz"))
    params:add_control(PID[i].depth, "LFO " .. i .. " depth",
      controlspec.new(-1, 1, "lin", 0, 0, ""))
  end
end

return M
