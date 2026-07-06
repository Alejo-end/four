-- render_pages.lua — offscreen renderer for mangler's norns screen.
-- Stubs the norns Lua environment, loads the REAL mangler.lua, drives a
-- believable performance scenario (a take, a tape loop, live FX), then
-- exports every UI page as a PGM framebuffer (0..15 levels -> 0..255).
--
-- usage: lua render_pages.lua <mangler.lua path> <outdir> <prefix> [variant]
--   variant "empty": empty-buffer states (REC + GRAIN)
--   variant "grain": GRAIN page across its param extremes (size/density/
--                    spread/jitter/pan edges, mode OFF)
--   variant "filter": FILTER page across its types and resonance extremes

local MANGLER = arg[1] or "mangler.lua"
local OUTDIR = arg[2] or "."
local PREFIX = arg[3] or "shot"
local VARIANT = arg[4]
local EMPTY = VARIANT == "empty"
local GRAINX = VARIANT == "grain"
local FILTX = VARIANT == "filter"

-- ============================================================================
-- screen: 128x64, 16 levels, cairo-ish path model (overwrite paints)
-- ============================================================================

local W, H = 128, 64
local buf = {}
for y = 1, H do
  buf[y] = {}
  for x = 1, W do buf[y][x] = 0 end
end

local cur_level = 15
local cx, cy = 0, 0
local path

local function reset_path() path = { rects = {}, lines = {}, circles = {} } end
reset_path()

local function px(x, y, l)
  x, y = math.floor(x), math.floor(y)
  if x >= 0 and x < W and y >= 0 and y < H then buf[y + 1][x + 1] = l end
end

local function draw_seg(x0, y0, x1, y1, l)
  x0, y0 = math.floor(x0), math.floor(y0)
  x1, y1 = math.floor(x1), math.floor(y1)
  local dx, dy = math.abs(x1 - x0), -math.abs(y1 - y0)
  local sx = x0 < x1 and 1 or -1
  local sy = y0 < y1 and 1 or -1
  local err = dx + dy
  while true do
    px(x0, y0, l)
    if x0 == x1 and y0 == y1 then break end
    local e2 = 2 * err
    if e2 >= dy then err = err + dy x0 = x0 + sx end
    if e2 <= dx then err = err + dx y0 = y0 + sy end
  end
end

screen = {}
function screen.clear()
  for y = 1, H do for x = 1, W do buf[y][x] = 0 end end
  reset_path()
end
function screen.update() end
function screen.aa() end
function screen.font_face() end
function screen.font_size() end
function screen.level(l) cur_level = math.floor(l) end
function screen.move(x, y) cx, cy = x, y end
function screen.line(x, y)
  path.lines[#path.lines + 1] = { cx, cy, x, y }
  cx, cy = x, y
end
function screen.rect(x, y, w, h) path.rects[#path.rects + 1] = { x, y, w, h } end
function screen.circle(x, y, r) path.circles[#path.circles + 1] = { x, y, r } end

function screen.fill()
  for _, r in ipairs(path.rects) do
    local x0, y0 = math.floor(r[1]), math.floor(r[2])
    local w = math.max(math.floor(r[3] + 0.5), 1)
    local h = math.max(math.floor(r[4] + 0.5), 1)
    for yy = y0, y0 + h - 1 do
      for xx = x0, x0 + w - 1 do px(xx, yy, cur_level) end
    end
  end
  reset_path()
end

function screen.stroke()
  for _, L in ipairs(path.lines) do
    draw_seg(L[1], L[2], L[3], L[4], cur_level)
  end
  for _, r in ipairs(path.rects) do
    local x0, y0 = math.floor(r[1]), math.floor(r[2])
    local w = math.max(math.floor(r[3] + 0.5), 1)
    local h = math.max(math.floor(r[4] + 0.5), 1)
    draw_seg(x0, y0, x0 + w - 1, y0, cur_level)
    draw_seg(x0, y0 + h - 1, x0 + w - 1, y0 + h - 1, cur_level)
    draw_seg(x0, y0, x0, y0 + h - 1, cur_level)
    draw_seg(x0 + w - 1, y0, x0 + w - 1, y0 + h - 1, cur_level)
  end
  for _, c in ipairs(path.circles) do
    local xc, yc, r = c[1], c[2], c[3]
    local a = 0
    while a < 2 * math.pi do
      px(xc + math.cos(a) * r, yc + math.sin(a) * r, cur_level)
      a = a + 0.03
    end
  end
  reset_path()
end

local function export(name)
  local f = assert(io.open(OUTDIR .. "/" .. name .. ".pgm", "w"))
  f:write("P2\n", W, " ", H, "\n255\n")
  for y = 1, H do
    local row = {}
    for x = 1, W do row[x] = buf[y][x] * 17 end
    f:write(table.concat(row, " "), "\n")
  end
  f:close()
  print("wrote " .. name .. ".pgm")
end

-- ============================================================================
-- norns environment stubs
-- ============================================================================

local nop = function() end

local SC_PHASE_FN = nil
package.preload.softcut = function()
  return setmetatable({
    event_phase = function(fn) SC_PHASE_FN = fn end,
  }, { __index = function() return nop end })
end
package.preload.musicutil = function()
  return {
    note_num_to_name = function(n)
      local names = { "C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B" }
      return names[(n % 12) + 1] .. (math.floor(n / 12) - 1)
    end,
  }
end

engine = {}
audio = setmetatable({}, { __index = function() return nop end })
_path = { code = "/nonexistent/" }
util = {
  round = function(x) return math.floor(x + 0.5) end,
  file_exists = function() return false end,
}
norns = {
  state = { data = OUTDIR .. "/" },
  menu = { status = function() return false end },
}
keyboard = {}

midi = { vports = {} }
for i = 1, 16 do midi.vports[i] = { name = "none", device = nil } end
function midi.connect(i) return midi.vports[i or 1] end
function midi.to_msg() return { type = "none" } end

grid = { vports = { { name = "none" } } }
function grid.connect()
  return { device = nil, led = nop, all = nop, refresh = nop }
end

local POLL_FNS = {}
poll = {
  set = function(name, fn)
    POLL_FNS[name] = fn
    return { start = nop, stop = nop }
  end,
}

-- controlspec
controlspec = {}
local CS = {}
CS.__index = CS
function controlspec.new(minval, maxval, warp, step, default, units)
  return setmetatable({
    minval = minval, maxval = maxval, warp = warp or "lin",
    step = step, default = default or minval, units = units,
    quantum = 0.01,
  }, CS)
end
function CS:unmap(v)
  if self.warp == "exp" then
    return math.log(v / self.minval) / math.log(self.maxval / self.minval)
  end
  return (v - self.minval) / (self.maxval - self.minval)
end

-- params
local PARAM_MT = {
  __index = {
    get = function(self) return self.value end,
    bang = function(self)
      if self.action then self.action(self.value) end
    end,
  },
}

params = { lookup = {}, list = {} }
local function padd(p)
  setmetatable(p, PARAM_MT)
  params.list[#params.list + 1] = p
  params.lookup[p.id] = #params.list
  return p
end
function params:add_separator() end
function params:add_group() end
function params:add_control(id, name, spec, fmt)
  padd({ id = id, name = name, controlspec = spec, value = spec.default, fmt = fmt })
end
function params:add_binary(id, name, behavior, default)
  padd({ id = id, name = name, value = default or 0, behavior = behavior })
end
function params:add_option(id, name, options, default)
  padd({ id = id, name = name, options = options, count = #options, value = default or 1 })
end
function params:add_number(id, name, minv, maxv, default, fmt)
  padd({ id = id, name = name, min = minv, max = maxv, value = default or minv, fmt = fmt })
end
function params:lookup_param(id) return params.list[params.lookup[id]] end
function params:set_action(id, fn) self:lookup_param(id).action = fn end
function params:get(id) return self:lookup_param(id).value end
function params:set(id, v)
  local p = self:lookup_param(id)
  if p.min then v = math.max(p.min, math.min(p.max, v)) end
  if p.count then v = math.max(1, math.min(p.count, math.floor(v + 0.5))) end
  if p.value ~= v then
    p.value = v
    if p.action then p.action(v) end
  end
end
function params:delta(id, d)
  local p = self:lookup_param(id)
  if p.controlspec then
    local range = p.controlspec.maxval - p.controlspec.minval
    self:set(id, p.value + d * (p.controlspec.quantum or 0.01) * range)
  else
    self:set(id, p.value + d)
  end
end
function params:string(id)
  local p = self:lookup_param(id)
  if p.options then return p.options[p.value] end
  if p.fmt then return p.fmt(p) end
  if p.controlspec then
    return string.format("%.2f %s", p.value, p.controlspec.units or "")
  end
  return tostring(p.value)
end
function params:bang()
  for _, p in ipairs(params.list) do p:bang() end
end

-- clock: the redraw loop runs as a coroutine; sleep yields one tick
local TICK = 0
local SCENARIO = nil
local CLOCK_CO = nil
clock = {
  run = function(fn)
    CLOCK_CO = coroutine.create(fn)
    return CLOCK_CO
  end,
  sleep = function()
    TICK = TICK + 1
    if SCENARIO then SCENARIO(TICK) end
    coroutine.yield()
  end,
  cancel = nop,
}

local function run_ticks(n)
  for _ = 1, n do
    local ok, err = coroutine.resume(CLOCK_CO)
    if not ok then
      io.stderr:write("CLOCK ERROR: " .. tostring(err) .. "\n")
      os.exit(1)
    end
  end
end

-- ============================================================================
-- load the real script + drive the scenario
-- ============================================================================

-- mangler is split across lib/*.lua modules pulled in with norns' include();
-- resolve those from the repo the mangler path points into. (the midigrid
-- include stays safely dead here: its util.file_exists guard returns false,
-- and the pcall would swallow the dofile error anyway.)
local REPO = MANGLER:match("^(.*)/") or "."
include = function(p) return dofile(REPO .. "/" .. p .. ".lua") end

-- deterministic renders: the particle cloud draws from math.random, and
-- seeding here makes galleries diffable and the dist build byte-checkable
math.randomseed(1)

dofile(MANGLER)
init()

-- system params: owned by norns on device; mangler references, never adds
params:add_control("input_level", "input", controlspec.new(0, 1, "lin", 0, 0.8, ""))
params:add_control("output_level", "output", controlspec.new(0, 1, "lin", 0, 0.7, ""))
params:add_control("monitor_level", "monitor", controlspec.new(0, 1, "lin", 0, 0.45, ""))
params:add_control("headphone_gain", "hp", controlspec.new(0, 1, "lin", 0, 0.6, ""))

local function push(name, v)
  if POLL_FNS[name] then POLL_FNS[name](v) end
end

if EMPTY then
  SCENARIO = function(t)
    push("play_phase", (t * 0.011) % 1)
    push("rec_phase", 0)
    push("rec_amp", 0)
    push("amp_in_l", 0.02)
    push("amp_in_r", 0.02)
    push("amp_out_l", 0)
    push("amp_out_r", 0)
  end
else
  SCENARIO = function(t)
    -- a take: rec from t=10 to t=150, write head walks 0.05 -> 0.55
    if t == 10 then params:set("rec", 1) end
    if t == 150 then params:set("rec", 0) end
    if t == 20 then params:set("tape_rec", 1) end
    if t == 140 then params:set("tape_rec", 0) end
    if t == 155 then
      params:set("delay_mix", 0.35)
      params:set("delay_fb", 0.45)
      params:set("delay_time", 0.32)
      params:set("rev_mix", 0.28)
      params:set("rev_size", 0.62)
      params:set("cutoff", 1400)
      params:set("resonance", 0.35)
      params:set("pitch", 2 ^ (5 / 12))
      params:set("density", 22)
      params:set("size", 0.12)
    end
    local rp = 0.05 + math.min(t > 10 and (t - 10) or 0, 140) * 0.0036
    push("rec_phase", rp)
    local env = math.abs(math.sin(t * 0.31)) * (0.6 + 0.4 * math.sin(t * 0.077))
    push("rec_amp", 0.05 + 0.5 * math.max(env, 0))
    push("amp_in_l", 0.04 + 0.4 * math.max(env, 0))
    push("amp_in_r", 0.04 + 0.38 * math.max(math.sin(t * 0.29), 0))
    push("amp_out_l", 0.25 + 0.15 * math.sin(t * 0.13))
    push("amp_out_r", 0.25 + 0.15 * math.sin(t * 0.11))
    local lo, hi = params:get("pos_start"), params:get("pos_end")
    if hi < lo then lo, hi = hi, lo end
    push("play_phase", lo + ((t * 0.013) % 1) * (hi - lo))
    -- tape head via the softcut phase event (position in seconds, voice 1)
    if SC_PHASE_FN then
      local tl, th = params:get("loop_start"), params:get("loop_end")
      if th < tl then tl, th = th, tl end
      local tp = tl + ((t * 0.009) % 1) * (th - tl)
      SC_PHASE_FN(1, tp * 60)
    end
  end
end

-- settle: record the take, snap the window, set FX character
run_ticks(EMPTY and 30 or 200)

-- walk pages and shoot each one
local PAGES = { "MIX", "LEVEL", "REC", "WINDOW", "GRAIN", "STRETCH", "TAPE",
  "FILTER", "DELAY", "REVERB" }

enc(1, -20)  -- rewind to page 1
if EMPTY then
  enc(1, 2)  -- REC page
  run_ticks(10)
  redraw()
  export(PREFIX .. "_03_REC_EMPTY")
  enc(1, 2)  -- GRAIN page: no cloud, no needle — silence lies dim and flat
  run_ticks(10)
  redraw()
  export(PREFIX .. "_05_GRAIN_EMPTY")
elseif GRAINX then
  -- GRAIN extremes: pin the cloud's params to one edge per shot, settle to
  -- steady state (longest grain life is ~2s = 30 ticks), then shoot. BASE
  -- restates the defaults so every case is one delta from the same cloud.
  math.randomseed(1)  -- reproducible cloud for diffing
  local BASE = { size = 0.1, density = 20, spread = 0.5, pos_jitter = 0,
    pan = 0, mode = 2 }
  local CASES = {
    { "BASE", {} },
    { "SIZE_MIN", { size = 0.01 } },
    { "SIZE_MAX", { size = 0.5 } },
    { "DENS_MIN", { density = 1 } },
    { "DENS_MAX", { density = 200 } },
    { "SPRD_0", { spread = 0 } },
    { "SPRD_1", { spread = 1 } },
    { "JIT_1", { pos_jitter = 1 } },
    { "PAN_L", { pan = -1 } },
    { "MODE_OFF", { mode = 1 } },
  }
  enc(1, 4)  -- GRAIN page
  for _, c in ipairs(CASES) do
    for id, v in pairs(BASE) do params:set(id, v) end
    for id, v in pairs(c[2]) do params:set(id, v) end
    run_ticks(60)
    redraw()
    export(PREFIX .. "_05_GRAIN_" .. c[1])
  end
elseif FILTX then
  -- FILTER extremes: each type at a musical setting, plus the edges the
  -- curve math must survive (max resonance peak, fully open)
  local CASES = {
    { "LP_RES1", { filt_type = 1, cutoff = 800, resonance = 1 } },
    { "HP", { filt_type = 2, cutoff = 300, resonance = 0.3 } },
    { "BP", { filt_type = 3, cutoff = 1000, resonance = 0.6 } },
    { "LP_OPEN", { filt_type = 1, cutoff = 20000, resonance = 0 } },
  }
  enc(1, 7)  -- FILTER page
  for _, c in ipairs(CASES) do
    for id, v in pairs(c[2]) do params:set(id, v) end
    run_ticks(5)
    redraw()
    export(PREFIX .. "_08_FILTER_" .. c[1])
  end
else
  for i, name in ipairs(PAGES) do
    if i > 1 then enc(1, 1) end
    run_ticks(25)
    redraw()
    export(string.format("%s_%02d_%s", PREFIX, i, name))
  end
  -- extra shots: LEVEL with alt held, STRETCH per mode
  enc(1, -20)
  enc(1, 1)  -- LEVEL
  key(1, 1)
  run_ticks(3)
  redraw()
  export(PREFIX .. "_02_LEVEL_ALT")
  key(1, 0)
  enc(1, 4)  -- STRETCH
  for m, label in ipairs({ "OFF", "GRAIN", "WARP", "PV" }) do
    params:set("mode", m)
    if m == 4 then params:set("pv_freeze", 1) end
    run_ticks(12)
    redraw()
    export(PREFIX .. "_06_STRETCH_" .. label)
  end
  params:set("pv_freeze", 0)
  -- MIX with the engine off: the ENG lane should lie flat
  params:set("mode", 1)
  enc(1, -20)
  run_ticks(8)
  redraw()
  export(PREFIX .. "_01_MIX_OFF")
  params:set("mode", 2)
  -- the adjust flash over a busy page: nudge an encoder on WINDOW and
  -- shoot while the framed readout is up — it must stay fully legible
  enc(1, 3)  -- MIX -> WINDOW
  run_ticks(5)
  enc(2, 2)  -- nudge win start: the flash appears
  run_ticks(2)
  redraw()
  export(PREFIX .. "_04_WINDOW_FLASH")
  -- FX truth shots: INF pins a flat envelope + badge; mix 0 goes dormant
  enc(1, 5)  -- WINDOW -> DELAY
  params:set("delay_fb", 0.95)
  run_ticks(20)  -- let the WINDOW flash expire: these shots want the parked readout
  redraw()
  export(PREFIX .. "_09_DELAY_INF")
  params:set("delay_fb", 0.45)
  params:set("delay_mix", 0)
  run_ticks(5)
  redraw()
  export(PREFIX .. "_09_DELAY_DRY")
  params:set("delay_mix", 0.35)
  enc(1, 1)  -- REVERB
  params:set("rev_mix", 0)
  run_ticks(5)
  redraw()
  export(PREFIX .. "_10_REVERB_DRY")
  params:set("rev_mix", 1)
  run_ticks(6)
  redraw()
  export(PREFIX .. "_10_REVERB_WASH")
  params:set("rev_mix", 0.28)
  -- MIX thrown full tape: the ENG lane must lie flat-dim (inaudible)
  enc(1, -20)
  params:set("mix", 1)
  run_ticks(8)
  redraw()
  export(PREFIX .. "_01_MIX_TAPE")
  params:set("mix", 0.5)
end

print("done: " .. TICK .. " ticks")
