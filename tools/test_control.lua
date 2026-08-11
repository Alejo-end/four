-- test_control.lua — the CONTROL SURFACE, offscreen.
--
-- The render suite proves the instrument DRAWS correctly. It never turns an
-- encoder or presses a key, which is why a whole class of bug walks past it:
-- an encoder target that resolves to nothing, a master level that reaches three
-- decks out of four, a key that re-arms the thing it was meant to cancel. Three
-- of the four defects found reviewing the layer decks were exactly that shape.
--
-- So this drives the REAL script through enc() and key() and asserts what
-- reaches the params. It deliberately does NOT stub a screen: drawing is the
-- render suite's job, and a no-op screen keeps this harness small enough to
-- read. The two harnesses share no code because they genuinely need different
-- things — the valuable part of the renderer is its pixel model, which nothing
-- here wants.
--
--   lua tools/test_control.lua        # from the repo root

local ok_count, fail = 0, {}
local function ok(c, w) if c then ok_count = ok_count + 1 else fail[#fail + 1] = w end end
local function near(a, b, t, w)
  ok(type(a) == "number" and math.abs(a - b) <= t,
    string.format("%s (got %s, want %s +-%s)", w, tostring(a), tostring(b), tostring(t)))
end

-- ---- a norns with no screen ------------------------------------------------
local nop = function() end
screen = setmetatable({}, { __index = function() return nop end })
engine = setmetatable({}, { __index = function() return nop end })
audio  = setmetatable({}, { __index = function() return nop end })
keyboard, midi = {}, { vports = {}, devices = {} }
poll = { set = function(name)
  return setmetatable({}, { __index = function() return nop end })
end }
grid = { connect = function() return setmetatable({}, { __index = function() return nop end }) end }
arc = { connect = function() return setmetatable({}, { __index = function() return nop end }) end }
_path = { code = "/nonexistent/", audio = "/nonexistent/audio/" }
util = { round = function(x) return math.floor(x + 0.5) end,
         file_exists = function() return false end, make_dir = nop }
norns = { state = { data = "/tmp/" }, menu = { status = function() return false end } }
tab = { save = nop, load = function() return nil end }

-- softcut: record every call so a level or a loop bound can be asserted
local SC = {}
local sc_calls = {}
package.preload.softcut = function()
  return setmetatable({}, { __index = function(_, k)
    return function(...) sc_calls[#sc_calls + 1] = { k, ... } end
  end })
end
package.preload.musicutil = function()
  return { note_num_to_name = function(n) return "C" .. n end }
end
local function sc_last(name, voice)
  for i = #sc_calls, 1, -1 do
    local c = sc_calls[i]
    if c[1] == name and (voice == nil or c[2] == voice) then return c end
  end
end

-- clock: run coroutines to completion on demand, never in the background
local CLOCK_CO
clock = {
  run = function(f, ...) local co = coroutine.create(f); coroutine.resume(co, ...)
        CLOCK_CO = co; return co end,
  sleep = function() coroutine.yield() end,
  sync = function() coroutine.yield() end,
  cancel = nop, get_tempo = function() return 120 end,
  get_beats = function() return 0 end,
}

-- ---- the real paramset, near enough --------------------------------------
-- controlspec with the warp maths the encoder law depends on
controlspec = {}
local CS = {}
CS.__index = CS
function controlspec.new(minval, maxval, warp, step, default, units)
  return setmetatable({ minval = minval, maxval = maxval, warp = warp,
    step = step, default = default or minval, units = units, quantum = 0.01 }, CS)
end
function CS:unmap(v)
  if self.warp == "exp" then
    return math.log(v / self.minval) / math.log(self.maxval / self.minval)
  end
  return (v - self.minval) / (self.maxval - self.minval)
end
function CS:map(r)
  if self.warp == "exp" then
    return self.minval * (self.maxval / self.minval) ^ r
  end
  return self.minval + r * (self.maxval - self.minval)
end

local plist, lookup = {}, {}
params = { lookup = lookup, count = 0 }
local function padd(p)
  -- the real Param has a :bang() of its own; the script uses it to re-send a
  -- value to the engine without changing it
  function p:bang() if self.action then self.action(self.value) end end
  plist[#plist + 1] = p; lookup[p.id] = p; params.count = #plist
end
function params:add_group(id, name, n) padd({ id = id, name = name, group = true }) end
function params:add_separator() end
function params:add_control(id, name, spec, fmt)
  padd({ id = id, name = name, controlspec = spec, value = spec.default })
end
params.add_taper = params.add_control
function params:add_number(id, name, lo, hi, dflt)
  padd({ id = id, name = name, min = lo, max = hi, value = dflt or lo })
end
function params:add_option(id, name, opts, dflt)
  padd({ id = id, name = name, options = opts, count = #opts, value = dflt or 1 })
end
function params:add_binary(id, name, behavior, dflt)
  padd({ id = id, name = name, binary = true, value = dflt or 0 })
end
function params:add_file(id, name, dflt) padd({ id = id, name = name, value = dflt or "" }) end
function params:add_trigger(id, name) padd({ id = id, name = name, value = 0 }) end
function params:lookup_param(id) return lookup[id] end
function params:get(id) local p = lookup[id]; return p and p.value end
function params:set(id, v, silent)
  local p = lookup[id]; if not p then return end
  if p.controlspec then
    local cs = p.controlspec
    v = math.max(cs.minval, math.min(cs.maxval, v))
    v = cs:map(cs:unmap(v))                 -- the round trip the device does
  elseif p.min then
    v = math.max(p.min, math.min(p.max, math.floor(v + 0.5)))
  elseif p.count then
    v = math.max(1, math.min(p.count, math.floor(v + 0.5)))
  elseif p.binary then
    v = v ~= 0 and 1 or 0
  end
  p.value = v
  if p.action and not silent then p.action(v) end
end
function params:delta(id, d)
  local p = lookup[id]; if not p then return end
  local cs = p.controlspec
  if cs then
    local raw = cs:unmap(p.value) + d * (cs.quantum or 0.01)
    self:set(id, cs:map(math.max(0, math.min(1, raw))))
  else
    self:set(id, (p.value or 0) + d)
  end
end
function params:set_action(id, fn) local p = lookup[id]; if p then p.action = fn end end
function params:string(id) return tostring(params:get(id)) end
function params:bang() for _, p in ipairs(plist) do p:bang() end end
function params:write() end
function params:read() end
function params:add(a) padd(a) end
params.action_write, params.action_read, params.action_delete = nil, nil, nil

-- norns' include(), so lib/*.lua resolve from the repo
include = function(p) return dofile(p .. ".lua") end

-- ---- load the instrument --------------------------------------------------
dofile("mangler.lua")
init()

-- system params mangler references but norns owns
params:add_control("input_level", "in", controlspec.new(0, 1, "lin", 0, 0.8, ""))
params:add_control("monitor_level", "mon", controlspec.new(0, 1, "lin", 0, 0.4, ""))

-- ============================================================================
-- 1 · the encoder CONTRACT, checked against the source
-- ============================================================================
-- A compound target ("@...") is not a param id. Three things have to know about
-- each one or it half-works: the encoder (to move something), ctx.enc_target
-- (so the footer can print a value instead of "--"), and the SHORT table (so it
-- has a name). The layer targets shipped knowing only the first, which is
-- invisible until you turn that knob on the device.
do
  local src = io.open("mangler.lua"):read("a")
  local pages = io.open("lib/mpages.lua"):read("a")
  local encmap = src:match("local ENC_MAP = %{(.-)\n%}")
  ok(encmap ~= nil, "ENC_MAP is readable")
  local resolver = src:match("function ctx%.enc_target.-\nend")
  ok(resolver ~= nil, "ctx.enc_target exists")
  local short = pages:match("local SHORT = %{(.-)\n%}")

  local compound, plain = {}, {}
  for id in (encmap or ""):gmatch('"(@[%w_]+)"') do compound[id] = true end
  for id in (encmap or ""):gmatch('"([%a][%w_]*)"') do plain[id] = true end

  ok(next(compound) ~= nil, "there are compound targets to check")
  for id in pairs(compound) do
    ok((resolver or ""):find(id, 1, true) ~= nil,
      "ctx.enc_target resolves " .. id .. " (else the footer reads --)")
    ok((short or ""):find('["' .. id .. '"]', 1, true) ~= nil
       or (short or ""):find(id, 1, true) ~= nil,
      "SHORT names " .. id)
  end
  for id in pairs(plain) do
    ok(lookup[id] ~= nil, "ENC_MAP target " .. id .. " is a real param")
  end
end

-- ============================================================================
-- 2 · turning an encoder actually moves something
-- ============================================================================
-- goto_page drives E1 the way the render suite does: hard left, then forward.
local function goto_page(n)
  enc(1, -30)
  if n > 1 then enc(1, n - 1) end
end
local function snapshot()
  local t = {}
  for _, p in ipairs(plist) do if not p.group then t[p.id] = p.value end end
  return t
end
local function changed(before)
  local out = {}
  for _, p in ipairs(plist) do
    if not p.group and before[p.id] ~= p.value then out[#out + 1] = p.id end
  end
  return out
end

do
  local names = {}
  for name in (io.open("mangler.lua"):read("a")):match("local PAGES = %{(.-)%}"):gmatch('"(%u+)"') do
    names[#names + 1] = name
  end
  ok(#names >= 12, "the page list is readable (" .. #names .. " pages)")
  for i, name in ipairs(names) do
    goto_page(i)
    for _, e in ipairs({ 2, 3 }) do
      -- try BOTH directions: a knob already sitting at its maximum does not
      -- move when you turn it up, and that is not a broken target
      local before = snapshot()
      enc(e, 3)
      local moved = changed(before)
      if #moved == 0 then
        before = snapshot()
        enc(e, -3)
        moved = changed(before)
      end
      ok(#moved > 0,
        string.format("%s E%d moves a param (moved: %s)", name, e,
          #moved > 0 and table.concat(moved, ",") or "NOTHING"))
    end
  end
end

-- ============================================================================
-- 3 · the master reaches everything that makes sound
-- ============================================================================
-- out_level used to drive the engine and the tape only, leaving the layer decks
-- at full level. One master, every deck, no exceptions.
do
  sc_calls = {}
  params:set("out_level", 0.25)
  local lv = {}
  for v = 1, 6 do
    local c = sc_last("level", v)
    lv[v] = c and c[3] or nil
  end
  ok(lv[1] ~= nil and lv[2] ~= nil, "the master reaches the tape voices")
  ok(lv[3] ~= nil and lv[4] ~= nil, "...and layer 1")
  ok(lv[5] ~= nil and lv[6] ~= nil, "...and layer 2")
  for v = 3, 6 do
    if lv[v] then
      ok(lv[v] < 0.8, "layer voice " .. v .. " is scaled by the master (" .. lv[v] .. ")")
    end
  end
  params:set("out_level", 1)
end

-- ============================================================================
-- 4 · STOP silences everything
-- ============================================================================
do
  sc_calls = {}
  params:set("stop_all", 1)
  for v = 1, 6 do
    local c = sc_last("level", v)
    if c then near(c[3], 0, 1e-6, "STOP silences softcut voice " .. v) end
  end
  params:set("stop_all", 0)
  sc_calls = {}
  params:set("out_level", 1)
  local back = sc_last("level", 3)
  ok(back and back[3] > 0, "START brings the layers back")
end

-- ============================================================================
-- 5 · the punch law
-- ============================================================================
-- Tapping a LIT key must cancel it and NOT re-arm. That inversion shipped once.
do
  local names = {}
  for name in (io.open("mangler.lua"):read("a")):match("local PAGES = %{(.-)%}"):gmatch('"(%u+)"') do
    names[#names + 1] = name
  end
  local layers_idx
  for i, n in ipairs(names) do if n == "LAYERS" then layers_idx = i end end
  if layers_idx then
    goto_page(layers_idx)
    params:set("layer_sel", 1)
    params:set("lay1_rec", 0)
    key(2, 1); key(2, 0)                      -- tap: latches
    ok(params:get("lay1_rec") == 1, "a tap on REC latches it")
    key(2, 1); key(2, 0)                      -- tap again: cancels
    ok(params:get("lay1_rec") == 0, "tapping the lit key cancels it, and does not re-arm")
  else
    ok(false, "LAYERS page not found")
  end

  -- A def with BOTH `lit` and `tap` is the only shape that can hit the
  -- press-while-lit path, where a cancel must NOT then fire the tap. That
  -- inversion shipped once (tapping a lit PRINT stopped the recording and the
  -- release re-armed it). It cannot be reached at runtime on this branch —
  -- SCENE's RCL only lights BETWEEN press and release, and PADS' pad is a gate
  -- — so it is asserted where it lives instead. The guard has to outlive the
  -- branch that needed it.
  local src2 = io.open("mangler.lua"):read("a")
  local keysrc = src2:match("local KEYS = %{.-\n%}")
  local both = 0
  for body in (keysrc or ""):gmatch("%b{}") do
    if body:find("tap =", 1, true) and body:find("lit =", 1, true) then both = both + 1 end
  end
  ok(both > 0, "there are defs with both lit and tap (" .. both .. ")")
  ok(src2:find("elseif def.tap and not st.unlatched", 1, true) ~= nil,
    "the release path guards def.tap with st.unlatched, so cancelling a lit key stays cancelled")
  ok(src2:find("st.unlatched = true", 1, true) ~= nil,
    "...and the press that cancels sets it")
end

-- ============================================================================
-- 6 · every page survives its own keys
-- ============================================================================
-- A key def with a missing half used to be found by pressing it on the device.
do
  local names = {}
  for name in (io.open("mangler.lua"):read("a")):match("local PAGES = %{(.-)%}"):gmatch('"(%u+)"') do
    names[#names + 1] = name
  end
  for i, name in ipairs(names) do
    goto_page(i)
    for _, k in ipairs({ 2, 3 }) do
      local okp, err = pcall(function() key(k, 1); key(k, 0) end)
      ok(okp, name .. " K" .. k .. " press+release does not error"
        .. (okp and "" or (" — " .. tostring(err))))
    end
  end
end

print(string.format("\n%d assertions passed", ok_count))
if #fail > 0 then
  print(#fail .. " FAILED:")
  for _, f in ipairs(fail) do print("  x " .. f) end
  os.exit(1)
end
print("control harness OK")
