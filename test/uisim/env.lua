-- env.lua — the offscreen norns, shared by every tool that runs the real script.
--
-- A fake 128x64 screen with norns' paint model, plus stubs for params, util,
-- audio, clock, softcut, midi and the polls. Nothing here knows what it is used
-- FOR: render_pages.lua draws pictures with it; other harnesses drive it.
--
--   local env = dofile("test/uisim/env.lua")
--   local SCENARIO
--   local h = env.install{ dir = "/tmp/shots", scenario = function() return SCENARIO end }
--   dofile("four.lua")
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

  -- osc: sends are recorded for a harness (osc_sent), nothing leaves the process
  osc = { sent = {} }
  function osc.send(to, path, args)
    osc.sent[#osc.sent + 1] = { host = to[1], port = to[2], path = path, v = args[1], a2 = args[2], a3 = args[3] }
  end

  midi = { vports = {}, devices = {} }
  for i = 1, 16 do midi.vports[i] = { name = "none", device = nil } end
  function midi.connect(i) return midi.vports[i or 1] end
  -- norns's own parse of raw bytes (lua/core/midi.lua), so a harness can feed a
  -- handler what a port delivers. A harness that hands over a message it built
  -- itself (a table with a type) gets it back.
  function midi.to_msg(d)
    if type(d) ~= "table" then return { type = "none" } end
    if d.type then return d end
    local st = d[1]
    if type(st) ~= "number" then return { type = "none" } end
    local hi, ch = st & 0xF0, (st & 0x0F) + 1
    if hi == 0x90 then return { type = "note_on", note = d[2], vel = d[3], ch = ch } end
    if hi == 0x80 then return { type = "note_off", note = d[2], vel = d[3], ch = ch } end
    if hi == 0xB0 then return { type = "cc", cc = d[2], val = d[3], ch = ch } end
    if hi == 0xE0 then return { type = "pitchbend", val = d[2] + (d[3] << 7), ch = ch } end
    if hi == 0xA0 then return { type = "key_pressure", note = d[2], val = d[3], ch = ch } end
    if hi == 0xD0 then return { type = "channel_pressure", val = d[2], ch = ch } end
    if hi == 0xC0 then return { type = "program_change", val = d[2], ch = ch } end
    if st == 0xF0 then return { type = "sysex", raw = d } end
    return { type = "other" }
  end

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
  -- `cur` is the frame being painted and `shown` the last one refreshed, each
  -- as cell (y-1)*8+x -> "level/hue". An attached Exquis is held to `shown`.
  local cur, shown, shown_new = {}, {}, false
  local function lvl(z) return math.max(0, math.min(15, math.floor((z or 0) + 0.5))) end
  local EXQ
  function GRID:led(x, y, z, hue)
    self.leds[#self.leds + 1] = { x = x, y = y, z = z, hue = hue }
    if x >= 1 and x <= 8 and y >= 1 and y <= 8 then
      cur[(y - 1) * 8 + x] = lvl(z) .. "/" .. tostring(hue)
    end
  end
  function GRID:all(z)
    -- a new frame begins: the Exquis has had the whole of the last one
    if EXQ and shown_new then shown_new = false; EXQ.mirror(shown) end
    self.leds[#self.leds + 1] = { all = z }
    for c = 1, 64 do cur[c] = lvl(z) .. "/nil" end
  end
  function GRID:refresh()
    self.refreshes = self.refreshes + 1
    for c = 1, 64 do shown[c] = cur[c] end
    -- only a frame the Exquis was there for is one it must show
    shown_new = EXQ ~= nil and EXQ.painted_by ~= nil
    if EXQ then EXQ.grid_frame = self.refreshes end
  end
  grid = { vports = { { name = "none" } } }
  function grid.connect() return GRID end

  -- an Exquis, attached before the script loads (see M.exquis below).
  -- "keys": beside the grid, where the driver starts it in KEYS.
  -- "pads": found before the grid has a device, so the driver starts it in
  -- PADS. The grid's device comes back with the Exquis's first frame, and the
  -- harness goes on with both surfaces.
  local want_ex = opts and opts.exquis
  if want_ex == nil then want_ex = os.getenv("FOUR_EXQUIS") end
  if want_ex == "" or want_ex == "0" then want_ex = false end
  if want_ex then
    assert(want_ex == "keys" or want_ex == "pads",
      "FOUR_EXQUIS (or install's exquis) is keys or pads, not " .. tostring(want_ex))
    EXQ = M.exquis()
    EXQ.want = want_ex
    EXQ.plug(true)
    if want_ex == "pads" then
      local dev = GRID.device
      GRID.device = nil
      EXQ.on_first = function() GRID.device = dev end
      -- THE HANDS ARE ON THE EXQUIS. A harness presses the grid with
      -- `h.grid.key(x, y, z)`. While the Exquis is in PADS, a press of a cell
      -- that it carries goes in as the bytes of its pad (or its button)
      -- instead, through the driver's fold, and comes out at the same handler.
      -- So every grid gesture of every harness is also a test of the fold.
      local real_key
      local id_of = {}
      for id = 0, 60 do if EXQ.cell_of[id] then id_of[EXQ.cell_of[id]] = id end end
      local function hands(x, y, z)
        local c = (y - 1) * 8 + x
        local on = EXQ.listed and EXQ.device.event and EXQ.mode() == "pads"
        if on and id_of[c] then
          EXQ.by_pad = EXQ.by_pad + 1
          return EXQ.pad(id_of[c], z == 1)
        elseif on and (c == 15 or c == 16) then
          EXQ.by_pad = EXQ.by_pad + 1
          return EXQ.cc(c == 15 and 104 or 105, z == 1 and 127 or 0)
        end
        return real_key(x, y, z)
      end
      setmetatable(GRID, {
        __newindex = function(t, k, v)
          if k == "key" then real_key = v else rawset(t, k, v) end
        end,
        __index = function(_, k)
          if k == "key" and real_key then return hands end
        end,
      })
    end
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
  -- a text param (the OSC host); the value is the string
  function params:add_text(id, name, text)
    padd({ id = id, name = name, value = text or "" })
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
    -- the level (0..15) of screen pixel x, y (0-based), as last drawn
    pixel = function(x, y) return buf[y + 1] and buf[y + 1][x + 1] or 0 end,
    poll_fns = POLL_FNS,
    -- the grid the script connected to. `grid.key(x, y, z)` drives the REAL
    -- handler; `grid.leds` is every led() call since it was last cleared.
    grid = GRID,
    -- the Exquis that was attached before the load (FOUR_EXQUIS=keys|pads, or
    -- install's `exquis`), or nil. `new_exquis()` makes one that is not plugged in.
    exquis = EXQ,
    new_exquis = M.exquis,
  }
end

-- ============================================================================
-- an Exquis stand-in
-- ============================================================================
-- What lib/mgrid.lua's driver sees of an Exquis: a MIDI device with a name, a
-- `send` and an `event`. It speaks raw bytes, as a port does, and it checks
-- every frame the driver sends against the maker's Developer Mode
-- specification: the hardware ignores a wrong frame in silence, so the
-- stand-in must not. A fault is kept in `bad`, and harness.lua's report fails
-- on one. It has never been compared with an Exquis.
--
--   local X = h.exquis or h.new_exquis()
--   X.plug()                 -- norns's order: listed, then midi.add
--   X.pad(11, true)          -- pad id 0..60, on channel 16
--   X.cc(117, 127)           -- a button or an encoder (64 +- n is a turn)
--   X.push(4)                -- an encoder's push, down and up
--   X.raw({ 0xF0, ... })     -- anything else, as bytes
--   X.led(0)                 -- r, g, b of the last frame that wrote that LED
--   X.mode()                 -- "pads", "keys", "off", or nil before any setup
--   X.unplug()               -- norns's order: midi.remove, then unlisted
local EX_HEAD = { 0xF0, 0x00, 0x21, 0x7E, 0x7F }
local EX_MASKS = { [0x00] = "off", [0x2A] = "keys", [0x2B] = "pads" }
local EX_VPORT = 3

function M.exquis(name)
  local dev = { name = name or "Exquis MIDI 1" }
  local X = { device = dev, sent = {}, bad = {}, frames = 0, by_pad = 0 }
  local last_mode

  function X.hex(m)
    local t = {}
    for i = 1, #m do t[i] = string.format("%02X", m[i]) end
    return table.concat(t, " ")
  end
  local function fault(why, m)
    X.bad[#X.bad + 1] = why .. (m and (": " .. X.hex(m):sub(1, 60)) or "")
  end

  local keep_leds, forget_leds       -- set below, with the mirror
  function dev:send(m)
    X.frames = X.frames + 1
    if type(m) ~= "table" then return fault("a frame that is not a byte table") end
    local copy = {}
    for i = 1, #m do copy[i] = m[i] end
    X.sent[#X.sent + 1] = copy
    if not X.listed then fault("a frame after the Exquis was unplugged", copy) end
    for i = 1, #copy do
      local b = copy[i]
      if math.type(b) ~= "integer" or b < 0 or b > 255 then
        return fault("byte " .. i .. " is not a byte", {})
      end
      if i > 1 and i < #copy and b > 127 then return fault("data byte " .. i .. " is over 127", copy) end
    end
    for i = 1, #EX_HEAD do
      if copy[i] ~= EX_HEAD[i] then return fault("not a Developer Mode frame", copy) end
    end
    if copy[#copy] ~= 0xF7 then return fault("no F7 at the end", copy) end
    local kind = copy[6]
    if kind == 0x00 then
      if #copy ~= 8 or not EX_MASKS[copy[7]] then return fault("a setup frame the driver has no name for", copy) end
      local first = last_mode == nil
      last_mode = EX_MASKS[copy[7]]
      forget_leds()
      if first then
        X.first = last_mode
        if X.on_first then X.on_first() end
      end
    elseif kind == 0x04 then
      local count = (#copy - 8) / 4
      local lo = copy[7]
      if count < 1 or count ~= math.floor(count) then return fault("an LED frame that is not whole", copy) end
      local hi = lo + count - 1
      if last_mode ~= "pads" and last_mode ~= "keys" then fault("an LED frame outside Developer Mode", copy) end
      if lo <= 60 and last_mode ~= "pads" then fault("a pad LED written while the pads are the Exquis's own", copy) end
      if hi > 113 or (lo <= 60 and hi > 60) or (lo > 60 and lo < 100) then
        fault("an LED frame that leaves the controls (" .. lo .. " to " .. hi .. ")", copy)
      end
      keep_leds(copy)
    else
      fault("a frame of an unknown kind", copy)
    end
  end

  function X.mode() return last_mode end

  -- THE MIRROR. The Exquis is a second target of the grid's own paint, so
  -- after a frame its LEDs show the grid's cells: the pads in PADS, and the
  -- four buttons of the state strip in both modes. `shown` is the grid's
  -- frame as cell -> "level/hue". The palette is the driver's own business, so
  -- this holds only what does not depend on it: a dark cell is a dark LED, a
  -- lit cell is a lit one, and two cells that look the same on the grid look
  -- the same here. Skipped until the Exquis has been painted whole since its
  -- last setup frame.
  local CELL = {}                      -- control id -> grid cell
  for id = 0, 60 do
    local k, rem = id // 11, id % 11
    local row, col = 2 * k, rem
    if rem >= 6 then row, col = 2 * k + 1, rem - 6 end
    if row == 0 then CELL[id] = 8 + col + 1
    else
      local x = 2 * col + (row % 2 == 1 and 2 or 1)
      if x <= 8 then CELL[id] = (({ 6, 5, 4, 3, 1 })[(row + 1) // 2] - 1) * 8 + x end
    end
  end
  local BTN = { [102] = 9, [103] = 10, [104] = 15, [105] = 16 }
  X.cell_of = CELL
  local lit = {}                       -- control id -> r * 65536 + g * 256 + b
  local pads_whole, btns_whole = false, false
  X.mirrors = 0
  function X.mirror(shown)
    if not X.listed or not dev.event then return end
    if last_mode ~= "pads" and last_mode ~= "keys" then return end
    local same = {}
    local function hold(id, c)
      local want, got = shown[c], lit[id]
      if not want or not got then return end
      local dark = want:sub(1, 2) == "0/"
      if dark ~= (got == 0) and #X.bad < 8 then
        fault(string.format("control %d shows %06X where the grid's cell %d,%d is %s",
          id, got, (c - 1) % 8 + 1, (c - 1) // 8 + 1, want))
      end
      if same[want] and same[want] ~= got and #X.bad < 8 then
        fault(string.format("control %d shows %06X, another %06X, for the same grid look %s",
          id, got, same[want], want))
      end
      same[want] = got
    end
    if last_mode == "pads" and pads_whole then
      for id = 0, 60 do if CELL[id] then hold(id, CELL[id]) end end
    end
    if btns_whole then
      for id, c in pairs(BTN) do hold(id, c) end
    end
    X.mirrors = X.mirrors + 1
  end
  function keep_leds(m)
    local lo, count = m[7], (#m - 8) // 4
    for i = 0, count - 1 do
      local o = 8 + i * 4
      lit[lo + i] = m[o] * 65536 + m[o + 1] * 256 + m[o + 2]
    end
    if lo == 0 and count == 61 then pads_whole = true end
    if lo <= 102 and lo + count - 1 >= 105 then btns_whole = true end
    X.painted_by = X.grid_frame or 0
  end
  function forget_leds()
    for id in pairs(lit) do lit[id] = nil end
    pads_whole, btns_whole, X.painted_by = false, false, nil
  end
  -- the last LED frame that reaches `id`: r, g, b
  function X.led(id)
    for i = #X.sent, 1, -1 do
      local m = X.sent[i]
      if m[6] == 0x04 and m[7] <= id and id <= m[7] + (#m - 8) / 4 - 1 then
        local o = 8 + (id - m[7]) * 4
        return m[o], m[o + 1], m[o + 2]
      end
    end
  end

  -- norns hands a device's bytes to its handler; with none set they are dropped
  function X.raw(bytes) if dev.event then dev.event(bytes) end end
  function X.pad(id, down)
    X.raw(down and { 0x9F, id, 127 } or { 0x8F, id, 0 })
  end
  function X.cc(id, val) X.raw({ 0xBF, id, val }) end
  function X.push(n) X.cc(113 + n, 127); X.cc(113 + n, 0) end
  -- a played note or its pressure, as the Exquis's own keyboard sends it
  -- (KEYS): through the vport, where four's note input listens
  function X.play(bytes)
    local vp = midi.vports[EX_VPORT]
    if vp.event then vp.event(bytes) end
  end

  -- `quiet`: listed without the callback, as a device that was there at boot
  function X.plug(quiet)
    X.listed = true
    midi.devices[100] = dev
    midi.vports[EX_VPORT].device, midi.vports[EX_VPORT].name = dev, dev.name
    if not quiet and midi.add then midi.add(dev) end
  end
  -- norns calls midi.remove while the device is still listed
  function X.unplug()
    if midi.remove then midi.remove(dev) end
    X.listed = false
    midi.devices[100] = nil
    midi.vports[EX_VPORT].device, midi.vports[EX_VPORT].name = nil, "none"
  end

  FOUR_TEST_EXQUIS = X       -- harness.lua's report reads its faults
  return X
end

return M
