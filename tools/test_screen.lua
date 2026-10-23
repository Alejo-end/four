-- test_screen.lua — the screen's own promises, read off the real pixels.
--
-- The render suite proves every page draws, and a person looks at the shots.
-- Some promises are easy to miss by eye in 70 shots, so this harness reads
-- the screen the script really drew (tools/uisim/env.lua) and asserts them:
--   the header: a lit flag never drops off, however long the title and
--               however many flags are lit (the beat repeat's RP did)
--   the footer: the erase arc clears the encoder words (it sat on "MOVE")
--   VOICE:      the GRAIN cloud follows its knobs (it drew the same dots
--               whatever size, density, spread, pan or jitter said)
--
--   lua tools/test_screen.lua        # from the repo root

local T = dofile("tools/harness.lua")
local ok = T.ok

local SCENARIO
local env = dofile("tools/uisim/env.lua")
local _h = env.install{ dir = "/tmp", scenario = function() return SCENARIO end }
include = function(p) return dofile(p .. ".lua") end
math.randomseed(1)
dofile("mangler.lua")
init()

local CTX, Mp
for i = 1, 255 do
  local n, v = debug.getupvalue(key, i)
  if n == nil then break end
  if n == "ctx" then CTX = v end
end
for i = 1, 255 do
  local n, v = debug.getupvalue(redraw, i)
  if n == nil then break end
  if n == "Mpages" then Mp = v end
end
assert(CTX and Mp, "could not reach the script's ctx and the pages module")

-- ---- material: a take, so the erase arc and the voice have something -----
SCENARIO = function(t)
  if t == 2 then params:set("rec", 1) end
  if t == 25 then params:set("rec", 0) end
  _h.push("rec_phase", 0.02 + t * 0.004)
  _h.push("rec_amp", 0.5)
  _h.push("amp_in_l", 0.4); _h.push("amp_in_r", 0.4)
  _h.push("play_phase", 0.4)
end
_h.run_ticks(40)
SCENARIO = nil
ok(CTX.wave_any, "the scenario recorded a take")

local px = _h.pixel

-- ============================================================================
-- 1 · the header: every lit flag stays on it
-- ============================================================================
do
  -- the sequencer's and the repeat's clocks are not run here: env's
  -- clock.run would replace the frame loop
  local real_run, real_cancel = clock.run, clock.cancel
  clock.run = function() return {} end
  clock.cancel = function() end
  local HF = {}
  for _, f in ipairs(Mp.HFLAGS) do HF[f.ch] = f end
  local npages = #CTX.PAGES
  local dpitch = math.min(5, math.floor(45 / (npages - 1)))
  local dx0 = 126 - ((npages - 1) * dpitch + 4)

  -- a lone writer draws whole
  T.goto_page("TAKE")
  params:set("motion_rec", 1)
  redraw()
  ok(HF.M.x and HF.M.full, "a lone write flag draws whole (dot and letter)")
  params:set("motion_rec", 0)

  -- a layer deck that records lights L
  params:set("lay1_rec", 1)
  redraw()
  ok(HF.L.x ~= nil, "a layer deck recording lights the L flag")
  params:set("lay1_rec", 0)

  -- all of them at once, on the longest title, in the blink's lit phase
  T.goto_page("LAYERS")
  local ON = { "rec", "tape_rec", "motion_rec", "lay1_rec", "freeze",
    "tape_freeze", "beat_repeat", "step_run" }
  for _, id in ipairs(ON) do params:set(id, 1) end
  params:set("lfo1_target", 2); params:set("lfo1_depth", 0.5)
  _h.run_ticks(1)
  while CTX.frame % 4 >= 2 do _h.run_ticks(1) end
  redraw()
  local last, prev = 0, -1
  for _, f in ipairs(Mp.HFLAGS) do
    ok(f.x ~= nil, "the " .. f.ch .. " flag is drawn with every flag lit")
    if f.x then
      ok(f.x > prev, "...in priority order (" .. f.ch .. ")")
      prev = f.x
      local w = f.full and (f.write and f.w + 5 or f.w) or (f.write and f.w or 2)
      last = f.x + w
      local ink = false
      for x = f.x, f.x + 1 do
        for y = 1, 5 do if px(x, y) > 0 then ink = true end end
      end
      ok(ink, "...and something is drawn where it sits (" .. f.ch .. ")")
    end
  end
  ok(last <= dx0 - 2, "the last flag ends before the page dots (" .. last .. " <= " .. (dx0 - 2) .. ")")
  for _, id in ipairs(ON) do params:set(id, 0) end
  params:set("lfo1_depth", 0); params:set("lfo1_target", 1)
  _h.run_ticks(1)
  clock.run, clock.cancel = real_run, real_cancel
end

-- ============================================================================
-- 2 · the footer: the erase arc clears the encoder words
-- ============================================================================
do
  T.goto_page("TAKE")
  key(1, 1); key(3, 1)
  _h.run_ticks(8)                     -- mid-arc, before it lands
  redraw()
  ok(Mp.FOOT.arc ~= nil, "the arc draws while K1+K3 is held on TAKE")
  ok(Mp.FOOT.arc and Mp.FOOT.e2 > Mp.FOOT.arc,
    "the E2 word starts right of the arc (" .. tostring(Mp.FOOT.e2) .. " > "
      .. tostring(Mp.FOOT.arc) .. ")")
  key(3, 0); key(1, 0)                -- released in the abort zone
  _h.run_ticks(1)
  ok(CTX.wave_any, "...and the abort leaves the take")
  redraw()
  ok(Mp.FOOT.arc == nil, "the arc is gone with the keys")
end

-- ============================================================================
-- 3 · VOICE: the GRAIN cloud follows its knobs
-- ============================================================================
-- the cloud's pixels in the body, the play head's column left out (it is the
-- only thing on row 50). Every case is drawn on the SAME frame, so only the
-- knob differs.
local function cloud()
  redraw()
  local n, x0, x1, y0, y1 = 0, 999, -1, 999, -1
  for x = 0, 127 do
    if px(x, 50) == 0 then
      for y = 21, 47 do
        if px(x, y) > 0 then
          n = n + 1
          x0, x1 = math.min(x0, x), math.max(x1, x)
          y0, y1 = math.min(y0, y), math.max(y1, y)
        end
      end
    end
  end
  return n, x1 - x0, y0, y1
end
do
  T.goto_page("VOICE")
  local BASE = { mode = 2, size = 0.1, density = 20, spread = 0.5, pan = 0,
    pos_jitter = 0, grain_jitter = 0, freeze = 0, stop_all = 0, mix = 0.5 }
  local function set(t)
    for id, v in pairs(BASE) do params:set(id, v) end
    for id, v in pairs(t or {}) do params:set(id, v) end
  end
  set()
  _h.run_ticks(30)                    -- the page-name pop has gone
  local n = cloud()
  ok(n > 0, "GRAIN draws a cloud (" .. n .. " px)")

  set({ size = 0.01 }); local small = cloud()
  set({ size = 0.5 }); local big = cloud()
  ok(big > small * 2, "a bigger SIZE draws longer grains (" .. big .. " > 2 x " .. small .. ")")

  set({ density = 1 }); local thin = cloud()
  set({ density = 200 }); local thick = cloud()
  ok(thick > thin * 3, "a higher DENSITY draws more grains (" .. thick .. " > 3 x " .. thin .. ")")

  local _, _, y0, y1 = (function() set({ spread = 0 }); return cloud() end)()
  ok(y0 == y1, "SPREAD 0 puts every grain in the middle of the stereo field (rows "
    .. y0 .. ".." .. y1 .. ")")
  set({ spread = 1 })
  _, _, y0, y1 = cloud()
  ok(y1 - y0 >= 12, "SPREAD 1 scatters them over it (" .. (y1 - y0) .. " rows)")

  set({ spread = 0, pan = -1 })
  local _, _, ly0, ly1 = cloud()
  set({ spread = 0, pan = 1 })
  local _, _, ry0 = cloud()
  ok(ly1 < ry0, "PAN moves the cloud: left above right (" .. ly1 .. " < " .. ry0 .. ")")

  set({ pos_jitter = 0 }); local _, near_w = cloud()
  set({ pos_jitter = 1 }); local _, wide_w = cloud()
  ok(wide_w > near_w * 2, "position JITTER widens the cloud over the window ("
    .. wide_w .. " > 2 x " .. near_w .. ")")

  -- the draw is pure: the same frame and knobs draw the same picture
  set()
  local a = cloud()
  local b = cloud()
  ok(a == b, "the cloud is drawn from the frame, not from math.random")
  set({ mode = 5 })
end

T.report("screen harness OK")
