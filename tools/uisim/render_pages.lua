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
  -- filled discs (norns fills a circle path; the pixel sim must too)
  for _, c in ipairs(path.circles) do
    local xc, yc, r = c[1], c[2], c[3]
    local ri = math.floor(r + 0.5)
    for yy = -ri, ri do
      for xx = -ri, ri do
        if xx * xx + yy * yy <= r * r then px(xc + xx, yc + yy, cur_level) end
      end
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
_path = { code = "/nonexistent/", audio = "/nonexistent/audio/" }
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
-- SIM FIX (S19): norns controlspecs have map() as well as unmap(); the stub
-- only had one direction. mscenes needs both — it morphs in normalized space
-- (unmap the endpoints, lerp, map back) so an exponential param sweeps evenly.
function CS:map(t)
  t = math.max(0, math.min(1, t))
  if self.warp == "exp" then
    return self.minval * (self.maxval / self.minval) ^ t
  end
  return self.minval + t * (self.maxval - self.minval)
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
-- S21: a file param (norns opens fileselect for it; the path rides the PSET)
function params:add_file(id, name, path)
  padd({ id = id, name = name, value = path or "-" })
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

-- walk pages and shoot each one. navigation is BY NAME (goto_page) and the
-- export filenames derive their NN index from the page's position, so adding
-- or reordering pages never desyncs the shots.
local PAGES = { "TAKE", "VOICE", "TAPE", "FILTER", "DELAY", "REVERB", "MIX",
  "PADS", "MOTION", "SCENE" }
local PAGE_IDX = {}
for i, n in ipairs(PAGES) do PAGE_IDX[n] = i end
local function goto_page(name) enc(1, -20) enc(1, (PAGE_IDX[name] or 1) - 1) end
local function pfx(name, suffix)
  return string.format("%s_%02d_%s%s", PREFIX, PAGE_IDX[name], name, suffix or "")
end

if EMPTY then
  goto_page("TAKE")
  run_ticks(10)
  redraw()
  export(pfx("TAKE", "_EMPTY"))
  goto_page("VOICE")  -- no material — silence lies dim and flat
  run_ticks(10)
  redraw()
  export(pfx("VOICE", "_EMPTY"))
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
  goto_page("VOICE")
  for _, c in ipairs(CASES) do
    for id, v in pairs(BASE) do params:set(id, v) end
    for id, v in pairs(c[2]) do params:set(id, v) end
    run_ticks(60)
    redraw()
    export(pfx("VOICE", "_" .. c[1]))
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
  goto_page("FILTER")
  for _, c in ipairs(CASES) do
    for id, v in pairs(c[2]) do params:set(id, v) end
    run_ticks(5)
    redraw()
    export(pfx("FILTER", "_" .. c[1]))
  end
else
  enc(1, -20)  -- ensure we start the walk on page 1
  for i, name in ipairs(PAGES) do
    if i > 1 then enc(1, 1) end
    run_ticks(25)
    redraw()
    export(string.format("%s_%02d_%s", PREFIX, i, name))
  end
  -- VOICE per engine mode (PLAY is the clean-loop default)
  goto_page("VOICE")
  for m, label in ipairs({ "OFF", "GRAIN", "WARP", "PV", "PLAY" }) do
    params:set("mode", m)
    if m == 4 then params:set("pv_freeze", 1) end
    run_ticks(12)
    redraw()
    export(pfx("VOICE", "_" .. label))
  end
  params:set("pv_freeze", 0)
  params:set("mode", 5)
  -- MIX with the engine off: the ENG lane should lie flat
  params:set("mode", 1)
  goto_page("MIX")
  run_ticks(8)
  redraw()
  export(pfx("MIX", "_OFF"))
  params:set("mode", 5)
  -- the value swell over a busy page: nudge the window start on TAKE
  goto_page("TAKE")
  run_ticks(5)
  enc(2, 2)
  run_ticks(2)
  redraw()
  export(pfx("TAKE", "_SWELL"))
  -- the purity mark: everything neutral -> the diamond lights by the title
  params:set("pitch", 1)
  params:set("cutoff", 20000)
  params:set("resonance", 0)
  params:set("delay_mix", 0)
  params:set("rev_mix", 0)
  params:set("mix", 0)          -- tape deck thrown away (it holds audio)
  run_ticks(20)                 -- let the swell expire
  redraw()
  export(pfx("TAKE", "_PURE"))
  params:set("pitch", 2 ^ (5 / 12))
  params:set("cutoff", 1400)
  params:set("resonance", 0.35)
  params:set("delay_mix", 0.35)
  params:set("rev_mix", 0.28)
  params:set("mix", 0.5)
  -- DELAY truth shots: INF pins the loop; the echo at zero goes dormant
  goto_page("DELAY")
  params:set("delay_fb", 0.95)
  run_ticks(20)
  redraw()
  export(pfx("DELAY", "_INF"))
  params:set("delay_fb", 0.45)
  params:set("delay_mix", 0)
  run_ticks(5)
  redraw()
  export(pfx("DELAY", "_DRY"))
  params:set("delay_mix", 0.35)
  -- REVERB truth shots: WASH swells the tail; shimmer motes drift over it
  goto_page("REVERB")
  params:set("rev_mix", 1)
  run_ticks(6)
  redraw()
  export(pfx("REVERB", "_WASH"))
  params:set("rev_mix", 0.4)
  params:set("shimmer", 0.7)
  params:set("shimmer_pitch", 12)
  run_ticks(6)
  redraw()
  export(pfx("REVERB", "_SHIMMER"))
  params:set("shimmer", 0)
  params:set("rev_mix", 0.28)
  -- TAPE record SOURCE thrown WET: the tape prints the processed output
  -- (doc/ux-feedback.md §25) — the "SRC WET" flag must show
  goto_page("TAPE")
  params:set("cut_source", 1)
  run_ticks(4)
  redraw()
  export(pfx("TAPE", "_WET"))
  params:set("cut_source", 0)
  -- MIX thrown full tape: the ENG lane must lie flat-dim (inaudible)
  goto_page("MIX")
  params:set("mix", 1)
  run_ticks(8)
  redraw()
  export(pfx("MIX", "_TAPE"))
  params:set("mix", 0.5)
  -- TAKE armed: write head laying material, hot input, R flag blinking
  goto_page("TAKE")
  params:set("rec", 1)
  push("rec_phase", 0.62)
  push("rec_amp", 0.6)
  push("amp_in_l", 0.7)
  push("amp_in_r", 0.6)
  redraw()
  export(pfx("TAKE", "_REC"))
  params:set("rec", 0)
  -- S17 self-resampling badges
  params:set("resample", 0.4)
  params:set("regen", 0.5)
  run_ticks(4)
  redraw()
  export(pfx("TAKE", "_REGEN"))
  params:set("resample", 0)
  params:set("regen", 0)
  -- the 1-frame re-arm above snapped the window to its blip (the rec-stop
  -- take-snap law); give the real take back for everything downstream
  params:set("pos_start", 0.05)
  params:set("pos_end", 0.554)
  -- the shift layer: K1 held swaps the footer whole (STOP/DRY + alt pair)
  goto_page("FILTER")
  key(1, 1)
  run_ticks(3)
  redraw()
  export(pfx("FILTER", "_SHIFT"))
  key(1, 0)
  -- the punch law on a throw: OPEN latched by a tap (word inverts), a
  -- second tap restores the carved tone
  key(2, 1) key(2, 0)
  run_ticks(2)
  redraw()
  export(pfx("FILTER", "_OPEN"))
  key(2, 1) key(2, 0)
  run_ticks(2)
  -- the erase arc: K1+K3 held on TAKE, shot mid-arc (frame ~8 of 15),
  -- then released in the abort zone — nothing fires, the take survives
  goto_page("TAKE")
  key(1, 1)
  key(3, 1)
  run_ticks(8)
  redraw()
  export(pfx("TAKE", "_ERASE_ARC"))
  key(3, 0)
  key(1, 0)
  -- PADS live: routed, the audition gated on bare K2 (the pad key)
  goto_page("PADS")
  params:set("pad_input", 1)
  params:set("seq_slice", 2)
  key(2, 1)
  run_ticks(3)
  redraw()
  export(pfx("PADS", "_LIVE"))
  key(2, 0)
  params:set("pad_input", 0)
  -- master STOP: the title chip inverts, on every page
  goto_page("MIX")
  params:set("stop_all", 1)
  run_ticks(3)
  redraw()
  export(pfx("MIX", "_STOP"))
  key(1, 1)
  run_ticks(3)
  redraw()
  export(pfx("MIX", "_STOP_SHIFT"))
  key(1, 0)
  params:set("stop_all", 0)
  -- S16 gesture looper: empty, armed (first pass), playing back
  goto_page("MOTION")
  run_ticks(4)
  redraw()
  export(pfx("MOTION", "_EMPTY"))
  params:set("motion_rec", 1)
  for t = 1, 20 do
    params:set("cutoff", 400 + 3000 * (1 + math.sin(t * 0.4)))
    params:set("delay_mix", 0.5 + 0.35 * math.sin(t * 0.25))
    run_ticks(1)
  end
  redraw()
  export(pfx("MOTION", "_REC"))
  params:set("motion_rec", 0)
  run_ticks(10)
  redraw()
  export(pfx("MOTION", "_PLAY"))
  params:set("motion_play", 0)
  -- S19 scenes (param-driven; recall mode stays NOW so no clock.sync)
  goto_page("SCENE")
  params:set("scene_slot", 1)
  params:set("cutoff", 700)
  params:set("delay_mix", 0.1)
  params:set("scene_capture", 1) params:set("scene_capture", 0)
  run_ticks(20)
  redraw()
  export(pfx("SCENE", "_ONE"))
  params:set("scene_slot", 4)
  params:set("cutoff", 9000)
  params:set("delay_mix", 0.7)
  params:set("rev_mix", 0.6)
  params:set("scene_capture", 1) params:set("scene_capture", 0)
  run_ticks(3)
  redraw()
  export(pfx("SCENE", "_SAVED"))
  run_ticks(20)
  redraw()
  export(pfx("SCENE", "_BANK"))
  params:set("scene_recall", 1) params:set("scene_recall", 0)
  run_ticks(3)
  redraw()
  export(pfx("SCENE", "_SAME"))
  run_ticks(20)
  params:set("scene_slot", 4)
  params:set("scene_morph_amt", 0.5)
  run_ticks(3)
  redraw()
  export(pfx("SCENE", "_MORPH"))
  params:set("scene_safe_capture", 1) params:set("scene_safe_capture", 0)
  run_ticks(3)
  redraw()
  export(pfx("SCENE", "_SAFE"))
  run_ticks(20)
  key(1, 1)
  run_ticks(2)
  redraw()
  export(pfx("SCENE", "_SHIFT"))
  key(1, 0)
  -- NU-3: the ◄ cell (slot 0) — filled by the auto-safe of the recall above
  params:set("scene_slot", 0)
  run_ticks(3)
  redraw()
  export(pfx("SCENE", "_BACK"))
  -- NU-3: hold-to-PEEK — RCL held ramps the morph toward the slot; the
  -- punch release sweeps it home again
  params:set("scene_slot", 4)
  run_ticks(2)
  key(2, 1)
  run_ticks(4)
  redraw()
  export(pfx("SCENE", "_PEEK"))
  run_ticks(3)
  key(2, 0)
  run_ticks(8)
  params:set("scene_morph_amt", 0)
  params:set("freeze", 1)
  params:set("scene_slot", 7)
  params:set("scene_capture", 1) params:set("scene_capture", 0)
  params:set("freeze", 0)
  params:set("scene_morph_amt", 1)
  run_ticks(3)
  redraw()
  export(pfx("SCENE", "_UNLANDED"))
  params:set("scene_morph_amt", 0)
  run_ticks(2)
end

print("done: " .. TICK .. " ticks")
