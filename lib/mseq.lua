-- mseq: the pad sequencer. A pattern on the clock plays the pads through the
-- same voice path a hand does (ctx.pad_trigger), so the sound-locks, the
-- voice cap and the PADS picture all apply to it.
--
-- An earlier, percussive step sequencer was removed in the 49th change: the
-- least used part, "not a percussive idea but a way to sequence the different
-- kinds of pad sounds / drones" (doc/ux-feedback.md §28). This one starts
-- from that note. By default it steps through four pads a bar each, legato,
-- so the pads' own voices and pitches become a slow drone progression. The
-- short divisions are there for rhythm when you want it.
--
-- The pattern is GENERATED, not drawn, so the keys, the encoders and MIDI
-- reach all of it through the params (no grid needed): `step_fill` hits
-- spread as evenly as they go over `step_len` steps (a euclidean rhythm), and
-- each hit plays the next slice in `step_order`. `step_chance` skips hits at
-- random, and `step_gate` is how much of a step a hit holds.
--
-- ONE voice id (VOICE_ID). Every step boundary releases it before anything
-- else, so a pattern can never strand a voice, whatever is cancelled when.
-- The step is read off the clock's beat count, so a start, a tempo change or
-- MIDI clock keeps the pattern on the bar. One clock coroutine, cancelled on
-- stop and in cleanup (the norns clock-race gotcha in CLAUDE.md). An external
-- clock that stops stops the steps with it: a legato hit then holds until the
-- clock moves, STOP, or the run is turned off.

local floor = math.floor
local C, pget

-- clear of every other voice id range: the screen bank (0..8), MIDI (1000+),
-- the grid (2000+ notes, 2600+ slices) and the typing keyboard (3000+)
local VOICE_ID = 4000
-- a gated hit releases at least this long before the next boundary, so a
-- late wake from the sleep can never miss that boundary's clock.sync
local GATE_MARGIN = 0.03
-- beats per step, matching the step_div option names
local DIVS = { 8, 4, 2, 1, 0.5, 0.25 }   -- 2 BAR, 1 BAR, 1/2, 1/4, 1/8, 1/16
local ORDERS = { "UP", "DOWN", "BOUNCE", "RANDOM" }
local NSTEP = 16

local M = {
  step = -1,      -- the step that last fired (0-based), -1 = stopped
  hits = {},      -- hits[1..16]: true = a hit (the PADS page draws it)
  slices = {},    -- slices[1..16]: the pad a hit plays (nil on a rest)
  VOICE_ID = VOICE_ID, DIVS = DIVS, ORDERS = ORDERS,
}
local co          -- the running clock coroutine, nil when stopped

-- k hits over n steps, as evenly as they go, the first step always a hit
-- (the Bresenham form of a euclidean rhythm). Writes M.hits in place.
local function build_hits(k, n)
  for i = 1, NSTEP do M.hits[i] = false end
  if k > n then k = n end
  if k <= 0 then return end
  for i = 0, n - 1 do
    M.hits[i + 1] = floor(i * k / n) ~= floor((i - 1) * k / n)
  end
end

-- which pad the h-th hit of a pass plays (h from 0). RANDOM is drawn when
-- the hit fires, not here, so it differs pass to pass.
local function slice_for(h, order)
  if order == 1 then return h % 8 end
  if order == 2 then return 7 - h % 8 end
  if order == 3 then
    local p = h % 14
    return p < 8 and p or 14 - p
  end
  return nil
end

-- rebuild the pattern from the params. Run by their actions, never per frame.
function M.rebuild()
  local n = floor(pget("step_len", 4) + 0.5)
  build_hits(floor(pget("step_fill", 4) + 0.5), n)
  local order = floor(pget("step_order", 1) + 0.5)
  local h = 0
  for i = 1, NSTEP do
    if M.hits[i] and i <= n then
      M.slices[i] = slice_for(h, order)
      h = h + 1
    else
      M.slices[i] = nil
    end
  end
end

local function div_beats()
  return DIVS[floor(pget("step_div", 2) + 0.5)] or 4
end

local function release()
  if C.pad_held[VOICE_ID] then C.pad_trigger(VOICE_ID, 0, 0, true) end
end

-- one step boundary, at clock beat `beats`. Returns the seconds the hit
-- should hold before its release, or nil when the next boundary releases it.
function M.fire(beats)
  release()
  local div = div_beats()
  local n = floor(pget("step_len", 4) + 0.5)
  local q = floor(beats / div + 0.5)
  -- a boundary of a division that is no longer set (a sync that was waiting
  -- when step_div changed) is not a step: the next sync lands on the grid
  if math.abs(beats / div - q) > 0.01 then return nil end
  local step = q % n
  M.step = step
  if not M.hits[step + 1] then return nil end
  -- a STOP silences everything and an empty take has nothing to slice
  if pget("stop_all", 0) == 1 or not C.wave_any then return nil end
  if math.random() >= pget("step_chance", 1) then return nil end
  local pad = M.slices[step + 1] or math.random(0, 7)
  C.pad_trigger(VOICE_ID, pad, 1, true)
  local gate = pget("step_gate", 1)
  if gate >= 0.999 then return nil end
  local tempo = (C.tempo and C.tempo()) or 120
  local step_s = div * 60 / tempo
  return math.max(0, math.min(step_s * gate, step_s - GATE_MARGIN))
end

local function run()
  while true do
    clock.sync(div_beats())
    local hold = M.fire(clock.get_beats())
    if hold then
      clock.sleep(hold)
      release()
    end
  end
end

function M.start()
  if co then return end
  M.rebuild()
  co = clock.run(run)
end

-- a new step length takes effect at once: the running sync waits on the OLD
-- division (up to two bars), so the coroutine is started again on the new one
function M.restart()
  if not co then return end
  M.stop()
  M.start()
end

function M.stop()
  if co then clock.cancel(co) end
  co = nil
  M.step = -1
  release()
end

function M.running() return co ~= nil end

function M.init(ctx)
  C = ctx
  pget = ctx.pget
end

return M
