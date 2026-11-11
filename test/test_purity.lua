-- test_purity.lua — the ◇ mark, end to end.
--
-- ◇ says "you hear the recording, verbatim". It has lied twice: it lit at the
-- dry_wet default (half live input), and it lit while a layer deck audibly
-- played over the take. Both times the mark's checks simply did not know
-- about one of the audio paths. This harness renders the REAL header and
-- walks every reason the mark can go dark: start pure (the diamond is
-- drawn), then flip each audible source, each hold, and each buffer writer
-- in turn, asserting the diamond dies and that reverting brings it back.
-- A new audio source that purity() does not know about belongs in MOVES here
-- the day it is born — the classification checks in test_control force the
-- decision for params; this is the same forcing for the mark.
--
--   lua test/test_purity.lua        # from the repo root

local T = dofile("test/harness.lua")
local ok, near = T.ok, T.near

local SCENARIO
local env = dofile("test/uisim/env.lua")
local _h = env.install{ dir = "/tmp", scenario = function() return SCENARIO end }
include = function(p) return dofile(p .. ".lua") end
math.randomseed(1)
dofile("mangler2.lua")
init()
params:add_control("input_level", "in", controlspec.new(0, 1, "lin", 0, 0.8, ""))
params:add_control("monitor_level", "mon", controlspec.new(0, 1, "lin", 0, 0.4, ""))

-- ---- material: a take, tape audio, and layer-1 audio ----------------------
-- the mark must be provably dark for tape and layer PLAYBACK, which needs all
-- three to actually hold something first.
SCENARIO = function(t)
  if t == 2 then params:set("rec", 1); params:set("tape_rec", 1) end
  if t == 25 then
    params:set("rec", 0); params:set("tape_rec", 0)
    params:set("lay1_rec", 1)
  end
  if t == 45 then params:set("lay1_rec", 0) end
  _h.push("rec_phase", 0.02 + t * 0.004)
  _h.push("rec_amp", 0.5)
  _h.push("amp_in_l", 0.4); _h.push("amp_in_r", 0.4)
  _h.push("amp_out_l", 0.3); _h.push("amp_out_r", 0.3)
  _h.push("play_phase", 0.05)
  _h.phase(1, (t % 50))          -- the tape head walks its buffer
  _h.phase(3, 120 + (t % 50))    -- layer 1's head walks its region
end
_h.run_ticks(50)
SCENARIO = nil

-- ---- the pure state -------------------------------------------------------
local PURE = {
  mode = 5, pitch = 1, scan = 1, pan = 0, dry_wet = 1,
  filt_type = 1, cutoff = 20000, resonance = 0,
  drive = 0, delay_mix = 0, rev_mix = 0, shimmer = 0, clouds_fb = 0,
  resample = 0, regen = 0, erode = 0, freeze = 0, pv_freeze = 0,
  mix = 0,           -- the tape holds audio: thrown fully away in the base
  lay1_play = 0,     -- layer 1 holds audio: muted in the base
  stop_all = 0,
  t2_mode = 1,       -- track 2 OFF (mangler2)
  step_run = 0,      -- the pad sequencer
  lfo1_depth = 0,    -- a modulator aimed at wear (below), at rest
}
-- wear alone does not touch the mark, so only the modulator's depth can
local function ctx_lfo_targets()
  for i = 1, 255 do
    local n, v = debug.getupvalue(key, i)
    if n == nil then break end
    if n == "ctx" then return v.lfo.TARGETS end
  end
end
for k, t in ipairs(ctx_lfo_targets()) do
  if t == "wear" then params:set("lfo1_target", k + 1) end
end
for id, v in pairs(PURE) do params:set(id, v) end

-- ---- render + detect ------------------------------------------------------
-- the diamond's exact shape: 8 lit outline pixels around a fully dark
-- interior. specific enough that no glyph or header flag can fake it.
local LIT = { {2,0},{1,1},{3,1},{0,2},{4,2},{1,3},{3,3},{2,4} }
local DARK = { {2,1},{1,2},{2,2},{3,2},{2,3} }

local function grab()
  redraw()
  local p = print
  print = function() end       -- env's export announces every write; hush it
  _h.export("purity")
  print = p
  local f = assert(io.open("/tmp/purity.pgm"))
  local txt = f:read("a"); f:close()
  txt = txt:gsub("^%s*P2", "")           -- "P2" would parse as the number 2
  local nums = {}
  for n in txt:gmatch("%d+") do nums[#nums + 1] = tonumber(n) end
  local W = nums[1]                      -- then height, max, then the pixels
  local px = {}
  for i = 4, #nums do px[i - 3] = nums[i] end
  return px, W
end

local function lit()
  local px, W = grab()
  for y0 = 0, 5 do
    for x0 = 0, 69 do
      local hit = true
      for _, o in ipairs(LIT) do
        if (px[(y0 + o[2]) * W + x0 + o[1] + 1] or 0) < 200 then
          hit = false; break
        end
      end
      if hit then
        for _, o in ipairs(DARK) do
          if (px[(y0 + o[2]) * W + x0 + o[1] + 1] or 0) ~= 0 then
            hit = false; break
          end
        end
      end
      if hit then return true end
    end
  end
  return false
end

ok(lit(), "the pure state lights the mark")

-- ---- every reason it must go dark -----------------------------------------
-- { what it proves, param, impure value }; the revert value comes from PURE
local MOVES = {
  { "a mangling mode", "mode", 2 },
  { "pitch off unity", "pitch", 1.5 },
  { "scan off unity", "scan", 0.5 },
  { "pan off center", "pan", 0.5 },
  { "drive", "drive", 0.3 },
  { "delay", "delay_mix", 0.3 },
  { "reverb", "rev_mix", 0.3 },
  { "shimmer", "shimmer", 0.3 },
  { "clouds feedback", "clouds_fb", 0.3 },
  { "resample writing the buffer", "resample", 0.3 },
  { "regen writing the buffer", "regen", 0.3 },
  { "erosion writing the buffer", "erode", 0.3 },
  { "track 2 playing (mangler2)", "t2_mode", 5 },
  { "a freeze hold", "freeze", 1 },
  { "a pv freeze hold", "pv_freeze", 1 },
  { "live input mixed in (dry_wet)", "dry_wet", 0.5 },
  { "a closed filter", "cutoff", 5000 },
  { "resonance", "resonance", 0.2 },
  { "an HP filter", "filt_type", 2 },
  { "the tape deck audible", "mix", 0.5 },
  { "layer 1 audible", "lay1_play", 1 },
  { "the master STOP", "stop_all", 1 },
  { "the pad sequencer running", "step_run", 1 },
  { "a modulator moving a knob", "lfo1_depth", 0.5 },
}
-- the sequencer's clock is not run here: env's clock.run would replace the
-- frame loop that lit() renders through
local real_run = clock.run
clock.run = function() return {} end
for _, m in ipairs(MOVES) do
  params:set(m[2], m[3])
  ok(not lit(), m[1] .. " kills the mark")
  params:set(m[2], PURE[m[2]])
  ok(lit(), "...and reverting " .. m[2] .. " restores it")
end
clock.run = real_run

-- a pad voice sounds on top of the take: a held one kills the mark
local ctx
for i = 1, 255 do
  local n, v = debug.getupvalue(key, i)
  if n == nil then break end
  if n == "ctx" then ctx = v end
end
-- a beat repeat LOOPING kills the mark (one held and still waiting for its
-- beat does not: nothing is replayed yet)
local real_run2, real_sync = clock.run, clock.sync
local waiting
clock.run = function(fn) waiting = fn; return {} end
clock.sync = function() end
engine.beat_repeat = function() end
params:set("beat_repeat", 1)
ok(lit(), "a beat repeat waiting for its beat leaves the mark")
waiting()
ok(not lit(), "a looping beat repeat kills the mark")
params:set("beat_repeat", 0)
ok(lit(), "...and letting go restores it")
clock.run, clock.sync, engine.beat_repeat = real_run2, real_sync, nil

ctx.pad_trigger(77, 0, 1)
ok(not lit(), "a held pad voice kills the mark")
ctx.pad_trigger(77, 0, 0)
ok(lit(), "...and its release restores it")

T.report("purity harness OK")
