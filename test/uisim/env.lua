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
  -- norns's own parse of raw bytes: the body of Midi.to_msg, copied unchanged
  -- from monome/norns lua/core/midi.lua (commit 227aa04, 2026-10-04, GPL v3),
  -- so a harness can feed a handler what a port delivers. Like the real one it
  -- THROWS on a message cut short (a nil byte in a comparison). The one line
  -- added: a harness that hands over a message it built itself (a table with a
  -- type) gets it back.
  function midi.to_msg(data)
    if type(data) == "table" and data.type then return data end
    local msg = {}
    -- note on
    if data[1] & 0xf0 == 0x90 then
      msg = {
        note = data[2],
        vel = data[3],
        ch = data[1] - 0x90 + 1
      }
      if data[3] > 0 then
        msg.type = "note_on"
      elseif data[3] == 0 then -- if velocity is zero then send note off
        msg.type = "note_off"
      end
    -- note off
    elseif data[1] & 0xf0 == 0x80 then
      msg = {
        type = "note_off",
        note = data[2],
        vel = data[3],
        ch = data[1] - 0x80 + 1
      }
    -- cc
    elseif data[1] & 0xf0 == 0xb0 then
      msg = {
        type = "cc",
        cc = data[2],
        val = data[3],
        ch = data[1] - 0xb0 + 1
      }
    -- pitchbend
    elseif data[1] & 0xf0 == 0xe0 then
      msg = {
        type = "pitchbend",
        val = data[2] + (data[3] << 7),
        ch = data[1] - 0xe0 + 1
      }
    -- key pressure
    elseif data[1] & 0xf0 == 0xa0 then
      msg = {
        type = "key_pressure",
        note = data[2],
        val = data[3],
        ch = data[1] - 0xa0 + 1
      }
    -- channel pressure
    elseif data[1] & 0xf0 == 0xd0 then
      msg = {
        type = "channel_pressure",
        val = data[2],
        ch = data[1] - 0xd0 + 1
      }
    -- program change
    elseif data[1] & 0xf0 == 0xc0 then
      msg = {
        type = "program_change",
        val = data[2],
        ch = data[1] - 0xc0 + 1
      }
    -- start
    elseif data[1] == 0xfa then
      msg.type = "start"
    -- stop
    elseif data[1] == 0xfc then
       msg.type = "stop"
    -- continue
    elseif data[1] == 0xfb then
      msg.type = "continue"
    -- clock
    elseif data[1] == 0xf8 then
      msg.type = "clock"
    -- song position pointer
    elseif data[1] == 0xf2 then
      msg = {
          type = "song_position",
          lsb = data[2],
          msb = data[3]
      }
    -- song select
    elseif data[1] == 0xf3 then
      msg = {
          type = "song_select",
          val = data[2]
      }
    -- active sensing (should probably ignore)
    elseif data[1] == 0xfe then
        -- do nothing
    -- system exclusive
    elseif data[1] == 0xf0 then
      msg = {
        type = "sysex",
        raw = data,
      }
    -- everything else
    else
      msg = {
        type = "other",
        raw = data,
      }
    end
    return msg
  end

  -- norns's road for a message that a device sent (_norns.midi.event in the
  -- same file): the device's handler, then its vport's. The menu's CC map,
  -- which the real one feeds last, is not modelled.
  _norns = rawget(_G, "_norns") or {}
  _norns.midi = _norns.midi or {}
  _norns.midi.event = function(id, data)
    local d = midi.devices[id]
    if d == nil then error("no entry for midi " .. id) end
    if d.event ~= nil then d.event(data) end
    if d.port and midi.vports[d.port].event then midi.vports[d.port].event(data) end
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
      local function hands(x, y, z)
        local c = EXQ.cell_at(x, y)
        local on = EXQ.listed and EXQ.device.event and EXQ.mode() == "pads"
        if on and EXQ.pad_of[c] then
          EXQ.by_pad = EXQ.by_pad + 1
          return EXQ.pad(EXQ.pad_of[c], z == 1)
        elseif on and EXQ.btn_of[c] then
          EXQ.by_pad = EXQ.by_pad + 1
          return EXQ.btn(EXQ.btn_of[c], z == 1)
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
--   X.pad(X.pad_at(2, 1), true) -- a pad, by the grid cell it carries
--   X.press(X.proto.redo)    -- a button, down and up
--   X.turn(2, -1)            -- encoder 2, one tick back
--   X.push(4)                -- an encoder's push, down and up
--   X.raw({ 0xF0, ... })     -- anything else, as bytes
--   X.led(0)                 -- r, g, b of the last frame that wrote that LED
--   X.mode()                 -- "pads", "keys", "off", or nil before any setup
--   X.unplug()               -- norns's order: midi.remove, then unlisted
-- NOT ONE NUMBER of the protocol or of the layout is written here. They are
-- the driver's (M.EX in lib/mgrid.lua), read from the module itself, so the
-- stand-in cannot drift from the driver. The specification's numbers are
-- pinned in one place, test/test_exquis.lua, which fails when the driver's
-- table leaves them.
local HERE = debug.getinfo(1, "S").source:match("^@(.*)test/uisim/env%.lua$") or ""
local PROTO
local function proto()
  if not PROTO then
    -- the module asks norns three things as it loads (is a grid there, is
    -- midigrid installed). Here it is told no, in a world of its own, so
    -- reading its table touches nothing of the harness's.
    local world = setmetatable({
      grid = { vports = {} },
      util = { file_exists = function() return false end },
      _path = { code = "" },
    }, { __index = _G })
    PROTO = assert(assert(loadfile(HERE .. "lib/mgrid.lua", "t", world))().EX,
      "lib/mgrid.lua hands out no EX table")
  end
  return PROTO
end
M.exquis_proto = proto

-- MIDI's own: status bytes, the largest data byte
local NOTE_ON, NOTE_OFF, CC, MIDI_MAX = 0x90, 0x80, 0xB0, 127
local KEY_PRESSURE, CH_PRESSURE = 0xA0, 0xD0
-- the vport the stand-in takes. Not the first free one, as norns would give
-- it: the harnesses play their keyboards on the first ports.
local EX_VPORT = 3
local LED_BYTES = 4                    -- r, g, b, effect
local FAULTS_KEPT = 8                  -- the mirror stops adding after these

function M.exquis(name)
  local P = proto()
  local dev = { name = name or ("E" .. P.name:sub(2) .. " MIDI 1") }
  local X = { device = dev, sent = {}, bad = {}, frames = 0, by_pad = 0, proto = P }
  local last_mode
  -- a frame is the head, a kind, a body and the end; the two kinds the driver sends
  local HEAD, KIND_AT = #P.setup - 1, #P.setup
  local SETUP, LED = P.setup[KIND_AT], P.led[KIND_AT]
  local BODY = KIND_AT + 1               -- a setup's mask, an LED frame's first id
  local MODE = {}
  for mode, mask in pairs(P.zones) do MODE[mask] = mode end
  local LAST_PAD = P.pads - 1
  -- an LED frame's count of LEDs, and where LED number i (from 0) starts in it
  local function led_count(m) return (#m - BODY - 1) / LED_BYTES end
  local function led_at(i) return BODY + 1 + i * LED_BYTES end

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
      if i > 1 and i < #copy and b > MIDI_MAX then
        return fault("data byte " .. i .. " is over " .. MIDI_MAX, copy)
      end
    end
    for i = 1, HEAD do
      if copy[i] ~= P.setup[i] then return fault("not a Developer Mode frame", copy) end
    end
    if copy[#copy] ~= P.eox then return fault("no end of SysEx at the end", copy) end
    local kind = copy[KIND_AT]
    if kind == SETUP then
      if #copy ~= BODY + 1 or not MODE[copy[BODY]] then
        return fault("a setup frame the driver has no name for", copy)
      end
      local first = last_mode == nil
      last_mode = MODE[copy[BODY]]
      forget_leds()
      if first then
        X.first = last_mode
        if X.on_first then X.on_first() end
      end
    elseif kind == LED then
      local count = led_count(copy)
      local lo = copy[BODY]
      if count < 1 or count ~= math.floor(count) then return fault("an LED frame that is not whole", copy) end
      local hi = lo + count - 1
      if last_mode ~= "pads" and last_mode ~= "keys" then fault("an LED frame outside Developer Mode", copy) end
      if lo <= LAST_PAD and last_mode ~= "pads" then
        fault("a pad LED written while the pads are the Exquis's own", copy)
      end
      if hi > P.lit_hi or (lo <= LAST_PAD and hi > LAST_PAD) or (lo > LAST_PAD and lo < P.lit_lo) then
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
  local GRID_W = 8
  local CELL = {}                      -- pad id -> grid cell (y-1)*8+x
  X.pad_of, X.btn_of = {}, {}          -- grid cell -> its pad, or its button
  for id = 0, LAST_PAD do
    local x, y = P.cell(id)
    if x then
      CELL[id] = (y - 1) * GRID_W + x
      X.pad_of[CELL[id]] = id
    end
  end
  function X.cell_at(x, y) return (y - 1) * GRID_W + x end
  -- the pad that carries grid cell x, y (an error when none does)
  function X.pad_at(x, y)
    return assert(X.pad_of[X.cell_at(x, y)], "no pad carries cell " .. x .. "," .. y)
  end
  local BTN = P.btn_cell
  for id, c in pairs(BTN) do
    if not X.pad_of[c] then X.btn_of[c] = id end
  end
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
      if dark ~= (got == 0) and #X.bad < FAULTS_KEPT then
        fault(string.format("control %d shows %06X where the grid's cell %d,%d is %s",
          id, got, (c - 1) % GRID_W + 1, (c - 1) // GRID_W + 1, want))
      end
      if same[want] and same[want] ~= got and #X.bad < FAULTS_KEPT then
        fault(string.format("control %d shows %06X, another %06X, for the same grid look %s",
          id, got, same[want], want))
      end
      same[want] = got
    end
    if last_mode == "pads" and pads_whole then
      for id = 0, LAST_PAD do if CELL[id] then hold(id, CELL[id]) end end
    end
    if btns_whole then
      for id, c in pairs(BTN) do hold(id, c) end
    end
    X.mirrors = X.mirrors + 1
  end
  function keep_leds(m)
    local lo, count = m[BODY], led_count(m) // 1
    local hi = lo + count - 1
    for i = 0, count - 1 do
      local o = led_at(i)
      lit[lo + i] = m[o] * 65536 + m[o + 1] * 256 + m[o + 2]
    end
    if lo == 0 and count == P.pads then pads_whole = true end
    local all = true
    for id in pairs(BTN) do if id < lo or id > hi then all = false end end
    if all then btns_whole = true end
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
      if m[KIND_AT] == LED and m[BODY] <= id and id <= m[BODY] + led_count(m) - 1 then
        local o = led_at(id - m[BODY])
        return m[o], m[o + 1], m[o + 2]
      end
    end
  end
  -- whether frame `m` is an LED frame that paints every pad at once
  function X.paints_all(m)
    return m[KIND_AT] == LED and m[BODY] == 0 and led_count(m) == P.pads
  end
  -- the setup frame for a mode ("pads", "keys", "off"), as the hex of X.hex
  function X.setup_hex(mode)
    local m = {}
    for i = 1, KIND_AT do m[i] = P.setup[i] end
    m[BODY], m[BODY + 1] = P.zones[mode], P.eox
    return X.hex(m)
  end

  -- norns hands a device's bytes to the device's handler AND to its vport's
  -- (_norns.midi.event in lua/core/midi.lua), in that order. So a pad's note
  -- also reaches four's note input, which must know it for a pad.
  function X.raw(bytes)
    if X.listed then _norns.midi.event(dev.id, bytes) end
  end
  local CH = P.ch - 1                  -- the channel, as a status byte's low half
  -- the bytes of a pad's edge and of a control's value, and their sending
  function X.msg_pad(id, down)
    return down and { NOTE_ON + CH, id, MIDI_MAX } or { NOTE_OFF + CH, id, 0 }
  end
  function X.msg_cc(id, val) return { CC + CH, id, val } end
  function X.pad(id, down) X.raw(X.msg_pad(id, down)) end
  function X.cc(id, val) X.raw(X.msg_cc(id, val)) end
  -- the Exquis as its own keyboard (KEYS): a note, a release, pressure on a
  -- channel (MPE) or on a key. `v` is 0 to 1.
  local function data(v) return math.floor(v * MIDI_MAX + 0.5) end
  function X.note(ch, note, v) X.raw({ NOTE_ON + ch - 1, note, data(v) }) end
  function X.note_off(ch, note) X.raw({ NOTE_OFF + ch - 1, note, 0 }) end
  function X.pressure(ch, v) X.raw({ CH_PRESSURE + ch - 1, data(v) }) end
  function X.key_pressure(ch, note, v) X.raw({ KEY_PRESSURE + ch - 1, note, data(v) }) end
  X.MAX = MIDI_MAX
  -- a button, or an encoder's push: one edge, or down and up
  function X.btn(id, down) X.cc(id, down and MIDI_MAX or 0) end
  function X.press(id) X.btn(id, true); X.btn(id, false) end
  function X.push(n) X.press(P.push + n - 1) end
  -- encoder n by `ticks` (one message, as one detent or a fast turn sends)
  function X.turn(n, ticks) X.cc(P.enc + n - 1, P.enc_mid + ticks) end
  -- a played note or its pressure, as the Exquis's own keyboard sends it
  -- (KEYS). The same road as every other message.
  X.play = X.raw

  -- `quiet`: listed without the callback, as a device that was there at boot
  function X.plug(quiet)
    X.listed = true
    if not dev.id then                 -- the first id that no device holds
      dev.id = 1
      while midi.devices[dev.id] do dev.id = dev.id + 1 end
    end
    midi.devices[dev.id] = dev
    dev.port = EX_VPORT
    midi.vports[EX_VPORT].device, midi.vports[EX_VPORT].name = dev, dev.name
    if not quiet and midi.add then midi.add(dev) end
  end
  -- norns calls midi.remove while the device is still listed
  function X.unplug()
    if midi.remove then midi.remove(dev) end
    X.listed = false
    midi.devices[dev.id] = nil
    midi.vports[EX_VPORT].device, midi.vports[EX_VPORT].name = nil, "none"
  end

  FOUR_TEST_EXQUIS = X       -- harness.lua's report reads its faults
  return X
end

return M
