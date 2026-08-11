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

-- ---- the offscreen norns, shared with the render suite --------------------
-- The SAME environment the renderer uses, so the two harnesses can never
-- disagree about what norns does. Its screen is real and simply never read
-- here: this harness asserts on params, not pixels.
local env = dofile("tools/uisim/env.lua")
local _h = env.install{ dir = "/tmp" }

-- the one thing the renderer does not need: a record of softcut calls, so an
-- assertion can ask whether a level or a loop bound reached the right voice.
local sc_calls = {}
do
  local sc = require "softcut"
  setmetatable(sc, { __index = function(_, k)
    return function(...) sc_calls[#sc_calls + 1] = { k, ... } end
  end })
end
local function sc_last(name, voice)
  for i = #sc_calls, 1, -1 do
    local c = sc_calls[i]
    if c[1] == name and (voice == nil or c[2] == voice) then return c end
  end
end
-- norns' include(), so lib/*.lua resolve from the repo
include = function(m) return dofile(m .. ".lua") end

local plist, lookup = params.list, params.lookup

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
  params:set("out_level", 0.9)   -- a REAL change, so the action definitely fires
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



-- ============================================================================
-- 7 · the GRID, which used to be device-only
-- ============================================================================
-- The offscreen grid stub hands back one object and the script attaches its key
-- handler to it, so the real handler is drivable here. That was always true; it
-- simply was not wired up, and every grid change in this project's history
-- shipped unverified because of it.
do
  local g = _h.grid
  ok(type(g.key) == "function", "the script attached its grid handler")

  local names = {}
  for name in (io.open("mangler.lua"):read("a")):match("local PAGES = %{(.-)%}"):gmatch('"(%u+)"') do
    names[#names + 1] = name
  end
  local function page(n)
    local i; for k, v in ipairs(names) do if v == n then i = k end end
    enc(1, -30); if i and i > 1 then enc(1, i - 1) end
    return i
  end

  -- the page-independent spine: row 2 must reach the same params from anywhere
  page("LAYERS")
  local before = params:get("rec")
  g.key(1, 2, 1); g.key(1, 2, 0)
  ok(params:get("rec") ~= before, "the state strip reaches `rec` from the LAYERS page")
  g.key(1, 2, 1); g.key(1, 2, 0)

  -- the LAYERS workspace: a two-pad span sets that deck's loop
  params:set("lay1_start", 0); params:set("lay1_end", 1)
  g.key(3, 3, 1); g.key(6, 3, 1); g.key(3, 3, 0); g.key(6, 3, 0)
  near(params:get("lay1_start"), 2 / 8, 1e-6, "a grid span sets layer 1's loop start")
  near(params:get("lay1_end"), 6 / 8, 1e-6, "...and its end")
  -- and it addresses the RIGHT deck: row 4 is layer 2, and layer 1 must not move
  local l1s, l1e = params:get("lay1_start"), params:get("lay1_end")
  g.key(1, 4, 1); g.key(4, 4, 1); g.key(1, 4, 0); g.key(4, 4, 0)
  near(params:get("lay2_end"), 4 / 8, 1e-6, "row 4 sets layer 2's loop")
  near(params:get("lay1_start"), l1s, 1e-9, "...and layer 1 is untouched")
  near(params:get("lay1_end"), l1e, 1e-9, "...both edges")

  -- transports
  params:set("lay1_rec", 0)
  g.key(1, 5, 1); g.key(1, 5, 0)
  ok(params:get("lay1_rec") == 1, "grid row 5 arms the deck")
  g.key(1, 5, 1); g.key(1, 5, 0)
  ok(params:get("lay1_rec") == 0, "...and disarms it")
  params:set("lay2_play", 1)
  g.key(2, 6, 1); g.key(2, 6, 0)
  ok(params:get("lay2_play") == 0, "grid row 6 mutes the SECOND deck")
  params:set("lay2_play", 1)

  -- the workspace follows the page: the same pad means something else elsewhere
  page("PADS")
  local l1 = params:get("lay1_start")
  g.key(3, 3, 1); g.key(3, 3, 0)
  near(params:get("lay1_start"), l1, 1e-9,
    "on PADS, row 3 is a slice pad — it must NOT move a layer's loop")

  -- and the LEDs actually light on the layers workspace
  page("LAYERS")
  g.leds = {}
  _h.run_ticks(2)
  local lit, rows = 0, {}
  for _, l in ipairs(g.leds) do
    if l.y and (l.z or 0) > 0 then lit = lit + 1; rows[l.y] = true end
  end
  ok(lit > 0, "the layers workspace lights pads (" .. lit .. ")")
  ok(rows[3] and rows[4], "...on both deck rows")
end

print(string.format("\n%d assertions passed", ok_count))
if #fail > 0 then
  print(#fail .. " FAILED:")
  for _, f in ipairs(fail) do print("  x " .. f) end
  os.exit(1)
end
print("control harness OK")
