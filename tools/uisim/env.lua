-- env.lua — the offscreen norns, shared by every tool that runs the real script.
--
-- A fake 128x64 screen with norns' paint model, plus stubs for params, util,
-- audio, clock, softcut, midi and the polls. Nothing here knows what it is used
-- FOR: render_pages.lua draws pictures with it; other harnesses drive it.
--
--   local env = dofile("tools/uisim/env.lua")
--   local SCENARIO
--   local h = env.install{ dir = "/tmp/shots", scenario = function() return SCENARIO end }
--   dofile("mangler.lua")
--   SCENARIO = function(tick) ... end     -- runs once per frame
--
-- WHY THE SCENARIO ARRIVES AS A GETTER, which looks like ceremony: it used to be
-- a file-level `local SCENARIO` that the caller assigned directly. Moving this
-- code into a module made that a local of install(), so the caller's assignment
-- created a GLOBAL that nothing read — the per-frame hook silently never ran,
-- every poll froze at its initial value, and 31 of 50 rendered shots changed
-- with no error anywhere. A write to a name is invisible once that name stops
-- being shared, and nothing warns you. The getter keeps the caller's own local
-- as the single source of truth.

local M = {}

local DIR = "."
local SCENARIO_GET = nil

function M.install(opts)
  DIR = (opts and opts.dir) or "."
  SCENARIO_GET = opts and opts.scenario

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
    local f = assert(io.open(DIR .. "/" .. name .. ".pgm", "w"))
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
  local GRID

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
    state = { data = DIR .. "/" },
    menu = { status = function() return false end },
  }
  keyboard = {}

  -- norns' tab.save / tab.load: a table written as a Lua chunk and read back.
  -- (the real one handles shared references too; the pset sidecars here are
  -- plain trees, which this round-trips exactly)
  local function ser(v)
    local t = type(v)
    if t == "number" then return string.format("%.17g", v) end
    if t == "string" then return string.format("%q", v) end
    if t == "boolean" or t == "nil" then return tostring(v) end
    local parts = {}
    for k, x in pairs(v) do
      parts[#parts + 1] = "[" .. ser(k) .. "]=" .. ser(x)
    end
    return "{" .. table.concat(parts, ",") .. "}"
  end
  tab = {
    save = function(t, path)
      local f = assert(io.open(path, "w"))
      f:write("return " .. ser(t))
      f:close()
    end,
    load = function(path) return dofile(path) end,
  }

  midi = { vports = {} }
  for i = 1, 16 do midi.vports[i] = { name = "none", device = nil } end
  function midi.connect(i) return midi.vports[i or 1] end
  function midi.to_msg() return { type = "none" } end

  -- ONE grid object, handed back to every connect() and exposed on the handle.
  -- mgrid sets `gg.key` on whatever connect returns, so holding that table is
  -- what makes the grid drivable offscreen at all — this project has treated
  -- grid code as device-only since the beginning, and it did not have to be.
  -- device is non-nil so mgrid'''s redraw guard (`gg and gg.device`) passes:
  -- offscreen we WANT the LED path exercised, since that is where the page-aware
  -- workspaces decide what to light
  GRID = { device = { name = "offscreen" }, leds = {}, refreshes = 0 }
  -- METHOD syntax: mgrid calls gg:led(...), so these take self. Defining them
  -- as plain functions silently shifts every argument by one.
  function GRID:led(x, y, z, hue)
    self.leds[#self.leds + 1] = { x = x, y = y, z = z, hue = hue }
  end
  function GRID:all(z) self.leds[#self.leds + 1] = { all = z } end
  function GRID:refresh() self.refreshes = self.refreshes + 1 end
  grid = { vports = { { name = "none" } } }
  function grid.connect() return GRID end

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

  -- groups are RECORDED, not drawn: norns trusts each add_group's declared
  -- count for the params that follow it, and a wrong count scrambles the
  -- PARAMS menu on device with no error anywhere. A harness can check them.
  params = { lookup = {}, list = {}, groups = {} }
  local function padd(p)
    setmetatable(p, PARAM_MT)
    params.list[#params.list + 1] = p
    params.lookup[p.id] = #params.list
    return p
  end
  function params:add_separator() end
  function params:add_group(id, name, n)
    if n == nil then n = name end            -- the 2-arg form: (name, n)
    params.groups[#params.groups + 1] = { id = id, n = n, at = #params.list }
  end
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
    -- the real Control:set lands on map(unmap(v)), which clamps to the spec's
    -- range; without this an out-of-range set is stored verbatim here and a
    -- harness can pass on a value the device would refuse
    if p.controlspec then
      v = math.max(p.controlspec.minval, math.min(p.controlspec.maxval, v))
    end
    if p.value ~= v then
      p.value = v
      if p.action then p.action(v) end
    end
  end
  -- norns' Control:delta moves the RAW (unmapped, 0..1 warped) value and maps
  -- back, so on an exponential spec a detent is a constant RATIO, not a constant
  -- amount. Moving linearly in value space here made the harness disagree with
  -- the device for every exp param — an encoder gesture that reads fine offscreen
  -- and behaves differently in the hand. Same law as the real paramset.
  function params:delta(id, d)
    local p = self:lookup_param(id)
    local cs = p.controlspec
    if cs and cs.unmap and cs.map then
      local raw = cs:unmap(p.value) + d * (cs.quantum or 0.01)
      if raw < 0 then raw = 0 elseif raw > 1 then raw = 1 end
      self:set(id, cs:map(raw))
    elseif cs then
      local range = cs.maxval - cs.minval
      self:set(id, p.value + d * (cs.quantum or 0.01) * range)
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
  local CLOCK_CO = nil
  clock = {
    run = function(fn)
      CLOCK_CO = coroutine.create(fn)
      return CLOCK_CO
    end,
    sleep = function()
      TICK = TICK + 1
      local _sc = SCENARIO_GET and SCENARIO_GET()
        if _sc then _sc(TICK) end
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

  return {
    export = export,
    run_ticks = run_ticks,
    ticks = function() return TICK end,
    push = function(name, v) if POLL_FNS[name] then POLL_FNS[name](v) end end,
    phase = function(v, pos) if SC_PHASE_FN then SC_PHASE_FN(v, pos) end end,
    has_phase = function() return SC_PHASE_FN ~= nil end,
    poll_fns = POLL_FNS,
    -- the grid the script connected to. `grid.key(x, y, z)` drives the REAL
    -- handler; `grid.leds` is every led() call since it was last cleared.
    grid = GRID,
  }
end

return M
