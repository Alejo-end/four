-- test_control.lua — the CONTROL SURFACE, offscreen.
--
-- The render suite proves the instrument DRAWS correctly. It never turns an
-- encoder or presses a key, which is why a whole class of bug walks past it:
-- an encoder target that resolves to nothing, a master level that reaches three
-- decks out of four, a key that re-arms the thing it was meant to cancel. Three
-- of the four defects found reviewing the layer decks were exactly that shape.
--
-- So this drives the REAL script through enc() and key() and asserts what
-- reaches the params. It runs on the SAME offscreen norns as the render suite
-- (tools/uisim/env.lua), so the two can never disagree about what norns does;
-- the screen is real and simply never read here, because drawing is the
-- render suite's job.
--
--   lua tools/test_control.lua        # from the repo root

local ok_count, fail = 0, {}
local function ok(c, w) if c then ok_count = ok_count + 1 else fail[#fail + 1] = w end end
local function near(a, b, t, w)
  ok(type(a) == "number" and math.abs(a - b) <= t,
    string.format("%s (got %s, want %s +-%s)", w, tostring(a), tostring(b), tostring(t)))
end

-- ---- the offscreen norns, shared with the render suite --------------------
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

-- the params MANGLER owns, captured before the system ones are stubbed in —
-- this is the universe the classification checks (section 9) walk
local MANGLER_IDS = {}
for _, p in ipairs(plist) do MANGLER_IDS[#MANGLER_IDS + 1] = p.id end

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
  -- the VOICE face pairs are encoder targets too (mode-contextual E2/E3)
  local vface = src:match("local VOICE_FACE = %{(.-)\n%}")
  for id in (vface or ""):gmatch('"([%w_]+)"') do plain[id] = true end
  local unnamed = {}
  for id in pairs(plain) do
    ok(lookup[id] ~= nil, "ENC_MAP target " .. id .. " is a real param")
    -- every encoder target needs a footer word (FULL falls back to SHORT,
    -- so SHORT is the one that must exist)
    if not (short or ""):find("%f[%w_]" .. id .. " =") then
      unnamed[#unnamed + 1] = id
    end
  end
  ok(#unnamed == 0, "every encoder target has a SHORT footer word (missing: "
    .. table.concat(unnamed, ",") .. ")")
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
  ok(#names >= 11, "the page list is readable (" .. #names .. " pages)")
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
-- 2b · the zoom-aware fine step covers the layer loops too
-- ============================================================================
-- the window and the tape loop tighten their encoder steps as the region
-- narrows; the layer loop move goes through the same move_pair, and it used
-- to skip the scaling, so a tight layer loop nudged at full coarseness.
do
  local names = {}
  for name in (io.open("mangler.lua"):read("a")):match("local PAGES = %{(.-)%}"):gmatch('"(%u+)"') do
    names[#names + 1] = name
  end
  local li
  for i, n in ipairs(names) do if n == "LAYERS" then li = i end end
  goto_page(li)
  params:set("layer_sel", 1)
  params:set("lay1_start", 0); params:set("lay1_end", 0.5)
  key(1, 1)                                  -- hold K1: E3 is the loop move
  enc(3, 1)
  local wide = params:get("lay1_start")
  params:set("lay1_start", 0.2); params:set("lay1_end", 0.21)
  enc(3, 1)
  local tight = params:get("lay1_start") - 0.2
  key(1, 0)
  ok(tight > 0, "a tight layer loop still moves")
  ok(tight < wide * 0.5,
    "...but by a FINER step than a wide one (span-scaled, like the window)")
  params:set("lay1_start", 0); params:set("lay1_end", 1)
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
-- 6b · the erase arc — the one destructive key path, and it had no test
-- ============================================================================
-- K1+K3 held to the arc wipes a page's material from the redraw clock
-- (tick_keys). Its device history is all edge cases: firing after an abort,
-- retargeting, leaking a DRY on the release. Drive the real clock and assert
-- the landing, the abort zone, and that neither path fires DRY.
do
  local names = {}
  for name in (io.open("mangler.lua"):read("a")):match("local PAGES = %{(.-)%}"):gmatch('"(%u+)"') do
    names[#names + 1] = name
  end
  local ti
  for i, n in ipairs(names) do if n == "TAPE" then ti = i end end
  goto_page(ti)
  -- section 6's key mash latches things by design (ORBIT RUN among them, and
  -- it captured scenes to wander between) — silence the background movers or
  -- the orbit morphs the very loop edges these assertions read
  params:set("orbit_on", 0)
  params:set("motion_rec", 0); params:set("motion_play", 0)
  params:set("scene_morph_amt", 0)
  params:set("tape_rec", 1)
  params:set("loop_start", 0.3); params:set("loop_end", 0.6)
  params:set("rev_mix", 0.4)
  key(1, 1); key(3, 1)
  _h.run_ticks(20)                     -- past ERASE_FRAMES: the arc lands
  ok(params:get("tape_rec") == 0, "the TAPE erase disarms the deck first")
  ok(params:get("loop_start") == 0 and params:get("loop_end") == 1,
    "...and opens the loop")
  key(3, 0); key(1, 0)
  ok(params:get("rev_mix") > 0.3, "the release after an erase does not fire DRY")
  -- the abort zone: releasing K1 before the arc lands wipes nothing
  params:set("tape_rec", 1)
  params:set("loop_start", 0.3)
  key(1, 1); key(3, 1)
  _h.run_ticks(5)                      -- inside the abort zone
  key(1, 0)                            -- K1 release = abort
  _h.run_ticks(20)
  ok(params:get("tape_rec") == 1, "releasing K1 aborts the erase")
  ok(params:get("rev_mix") > 0.3, "...and the abort does not fire DRY")
  key(3, 0)
  ok(params:get("rev_mix") > 0.3, "...nor does the K3 release after it")
  params:set("tape_rec", 0)
  params:set("loop_start", 0); params:set("rev_mix", 0)
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

  -- a loop NARROWER than one eighth must still light the pad it touches.
  -- the containment law this row used to carry left it entirely dark (@lay_move
  -- and MIDI park loops at arbitrary fractions; grid-set spans hid the bug)
  params:set("lay1_play", 1)
  params:set("lay1_start", 0.4); params:set("lay1_end", 0.45)
  g.leds = {}
  _h.run_ticks(2)
  local narrow = 0
  for _, l in ipairs(g.leds) do
    if l.y == 3 and l.x == 4 and (l.z or 0) >= 4 then narrow = narrow + 1 end
  end
  ok(narrow > 0, "a sub-eighth layer loop still lights its pad")
end

-- ============================================================================
-- 8 · the grid traps this project learned the hard way
-- ============================================================================
-- Each of these is a fix CLAUDE.md records as a device lesson, and none had ever
-- been verified offscreen because the grid was thought untestable. A regression
-- in any of them strands a voice or latches a param with no way back.
do
  local g = _h.grid
  local names = {}
  for name in (io.open("mangler.lua"):read("a")):match("local PAGES = %{(.-)%}"):gmatch('"(%u+)"') do
    names[#names + 1] = name
  end
  local function page(n)
    local i; for k, v in ipairs(names) do if v == n then i = k end end
    enc(1, -30); if i and i > 1 then enc(1, i - 1) end
  end

  -- (a) A RELEASE BELONGS TO THE PRESS THAT OPENED IT. Holding a workspace pad
  -- and changing page used to hand the release to a layout that ignored it, so
  -- tape_reverse latched forever and held note pads stranded voices.
  page("TAPE")
  params:set("lay1_start", 0); params:set("lay1_end", 1)
  page("LAYERS")
  g.key(2, 3, 1)                       -- press on the LAYERS workspace
  page("PADS")                         -- ...navigate away while still held
  g.key(2, 3, 0)                       -- ...and release
  local held_ok = true
  page("LAYERS")
  g.key(5, 3, 1); g.key(5, 3, 0)       -- a fresh single-pad span
  near(params:get("lay1_start"), 4 / 8, 1e-6,
    "a span after a cross-page release still anchors on the NEW press")

  -- (b) note-offs are NOT gated on keys_enable: toggling note input mid-hold
  -- must not strand a polyphonic voice
  params:set("pad_input", 1)
  params:set("keys_enable", 1)
  page("TAKE")
  g.key(1, 8, 1)                       -- a piano pad down
  local held_before = 0
  params:set("keys_enable", 0)         -- ...input switched off mid-hold
  g.key(1, 8, 0)                       -- ...and released
  -- the voice must be closed: pressing again and releasing must not accumulate
  params:set("keys_enable", 1)
  g.key(1, 8, 1); g.key(1, 8, 0)
  ok(true, "a note pad released after keys_enable went off does not error")
  params:set("pad_input", 0)

  -- (c) two fingers on the scene bank: one release must not cancel the other's
  -- peek (row 1 is the bank from any page)
  page("SCENE")
  params:set("scene_slot", 1)
  g.key(1, 1, 1)                       -- finger A on slot 1
  g.key(2, 1, 1)                       -- finger B on slot 2
  g.key(1, 1, 0)                       -- A lifts
  local after_a = params:get("scene_slot")
  g.key(2, 1, 0)                       -- B lifts
  ok(type(after_a) == "number", "two fingers on the scene bank do not error")

  -- (d) the spine is page-independent: row 2 reaches the same param everywhere
  local seen = {}
  for _, pg in ipairs({ "TAKE", "VOICE", "MIX", "SCENE", "LAYERS" }) do
    page(pg)
    local before = params:get("tape_rec")
    g.key(2, 2, 1); g.key(2, 2, 0)
    seen[#seen + 1] = (params:get("tape_rec") ~= before)
    g.key(2, 2, 1); g.key(2, 2, 0)     -- put it back
  end
  local all = true
  for _, v in ipairs(seen) do all = all and v end
  ok(all, "row 2 reaches tape_rec from every page (the spine is page-independent)")

  -- (e) STOP on the grid is the same STOP: it must silence the layer decks too
  page("VOICE")
  sc_calls = {}
  g.key(8, 2, 1); g.key(8, 2, 0)
  ok(params:get("stop_all") == 1, "grid (8,2) engages the master STOP")
  local q = sc_last("level", 3)
  if q then near(q[3], 0, 1e-6, "...and it reaches the layer decks") end
  g.key(8, 2, 1); g.key(8, 2, 0)
  ok(params:get("stop_all") == 0, "...and releases it")
end

-- ============================================================================
-- 9 · every param is CLASSIFIED — the registry check
-- ============================================================================
-- The recurring defect in this codebase's history is a NEW param missing one
-- of the hand-maintained lists its siblings joined: the scene lists, the
-- motion list, the edge pairs, the fine step, the rate format — the layers
-- alone missed four of them in one change. The lists stay where they are,
-- with their ordering and their reasons; what is new is that membership is
-- TOTAL. Every param must sit in a list or in that list's explicit exclude,
-- never neither and never both, so the next param FAILS here until someone
-- decides. Stale entries fail too: an exclude naming a deleted param is the
-- same drift that left a pedal mapped to the deleted seq_play, silently.
do
  local Msc = dofile("lib/mscenes.lua")
  local Mmo = dofile("lib/mmotion.lua")
  -- the universe must be the real paramset, or everything below is vacuous
  ok(#MANGLER_IDS > 100, "the param universe is populated (" .. #MANGLER_IDS .. ")")
  local function set_of(list)
    local s = {}
    for _, id in ipairs(list) do s[id] = true end
    return s
  end
  local function check(name, includes, excludes)
    local inc, exc = set_of(includes), set_of(excludes)
    local neither, both, stale = {}, {}, {}
    for _, id in ipairs(MANGLER_IDS) do
      if not inc[id] and not exc[id] then neither[#neither + 1] = id end
      if inc[id] and exc[id] then both[#both + 1] = id end
    end
    for _, id in ipairs(includes) do
      if not lookup[id] then stale[#stale + 1] = id end
    end
    for _, id in ipairs(excludes) do
      if not lookup[id] then stale[#stale + 1] = id end
    end
    ok(#neither == 0, name .. " leaves params UNDECIDED: "
      .. table.concat(neither, ","))
    ok(#both == 0, name .. " lists params on BOTH sides: "
      .. table.concat(both, ","))
    ok(#stale == 0, name .. " names params that no longer exist: "
      .. table.concat(stale, ","))
  end
  check("scenes", Msc.SCENE_RECALL_IDS, Msc.SCENE_EXCLUDE)
  check("motion", Mmo.MOTION_IDS, Mmo.MOTION_EXCLUDE)

  -- every *_start/*_end pair is a REGION: it must move widening-edge-first
  -- in the scenes (EDGE_PAIRS) and take the span-scaled fine step (FINE_IDS)
  local src = io.open("mangler.lua"):read("a")
  local fine = src:match("local FINE_IDS = %{(.-)%}") or ""
  local no_edge, no_fine = {}, {}
  for _, id in ipairs(MANGLER_IDS) do
    local stem = id:match("^([%w_]+)_start$")
    if stem and lookup[stem .. "_end"] then
      if Msc.EDGE_PAIRS[id] ~= stem .. "_end" then no_edge[#no_edge + 1] = id end
      if not fine:find("%f[%w_]" .. id .. " =") then no_fine[#no_fine + 1] = id end
    end
  end
  ok(#no_edge == 0, "every edge pair is in EDGE_PAIRS (missing: "
    .. table.concat(no_edge, ",") .. ")")
  ok(#no_fine == 0, "every edge pair takes the fine step (missing: "
    .. table.concat(no_fine, ",") .. ")")

  -- every rate-shaped param (controlspec units "x") formats as a rate in the
  -- footer; pitch is the one exception, with its own semitone formatter
  local pages_src = io.open("lib/mpages.lua"):read("a")
  local rate = pages_src:match("local RATE_IDS = %{(.-)%}") or ""
  local no_rate = {}
  for _, id in ipairs(MANGLER_IDS) do
    local p = params:lookup_param(id)
    if p.controlspec and p.controlspec.units == "x" and id ~= "pitch"
        and not rate:find("%f[%w_]" .. id .. " =") then
      no_rate[#no_rate + 1] = id
    end
  end
  ok(#no_rate == 0, "every x-rate param is in RATE_IDS (missing: "
    .. table.concat(no_rate, ",") .. ")")

  -- the chaos throw's target list survives param deletions
  local dead_chaos = {}
  for _, c in ipairs(Msc.CHAOS) do
    if not lookup[c[1]] then dead_chaos[#dead_chaos + 1] = c[1] end
  end
  ok(#dead_chaos == 0, "every CHAOS target exists (dead: "
    .. table.concat(dead_chaos, ",") .. ")")
end

-- ============================================================================
-- 10 · the shipped presets and pmap name only params that exist
-- ============================================================================
-- psets and pmaps reference params by id and norns validates neither: a line
-- naming a deleted param is silently dropped on load. That is how a pedal
-- stayed mapped to seq_play, deleted with the sequencer, and did nothing.
do
  local function ids_in(path)
    local f = io.open(path)
    if not f then return nil end
    local out = {}
    for line in f:lines() do
      local id = line:match('^"([%w_]+)"%s*:')
      if id then out[#out + 1] = id end
    end
    f:close()
    return out
  end
  local checked, dead = 0, {}
  local sets = { "presets/mangler.pmap.example",
    "presets/layers/layers.pmap.example" }
  for n = 1, 10 do
    sets[#sets + 1] = string.format("presets/mangler-%02d.pset", n)
    sets[#sets + 1] = string.format("presets/layers/layers-%02d.pset", n)
  end
  for _, path in ipairs(sets) do
    local ids = ids_in(path)
    if ids then
      checked = checked + 1
      for _, id in ipairs(ids) do
        if not lookup[id] then dead[#dead + 1] = path:match("[^/]+$") .. ":" .. id end
      end
    end
  end
  ok(checked >= 21, "the shipped presets are all readable (" .. checked .. ")")
  ok(#dead == 0, "every preset/pmap id exists in the paramset (dead: "
    .. table.concat(dead, ",") .. ")")

  -- the scene SIDECARS name params by id too, and a dead id there is even
  -- quieter: apply() skips unknown ids without a word. Scan every ["id"]= key.
  local sdead, schecked = {}, 0
  for _, dir in ipairs({ "presets/", "presets/layers/" }) do
    for n = 1, 10 do
      local path = string.format("%sscenes-%02d.lua", dir, n)
      local f = io.open(path)
      if f then
        schecked = schecked + 1
        for line in f:lines() do
          local id = line:match('^%s*%["([%w_]+)"%]=')
          if id and id ~= "slots" and id ~= "safe" and id ~= "v"
              and not lookup[id] then
            sdead[#sdead + 1] = path:match("[^/]+$") .. ":" .. id
          end
        end
        f:close()
      end
    end
  end
  ok(schecked >= 20, "the shipped scene sidecars are all readable (" .. schecked .. ")")
  ok(#sdead == 0, "every scene-sidecar id exists in the paramset (dead: "
    .. table.concat(sdead, ",") .. ")")
  -- and none of them may carry the window pair: a stored full-buffer window
  -- recalled over a short sample is the "long silence" trap (the runtime clamp
  -- guards live captures; the SHIPPED banks simply leave the window alone)
  local wnd = {}
  for _, dir in ipairs({ "presets/", "presets/layers/" }) do
    for n = 1, 10 do
      local path = string.format("%sscenes-%02d.lua", dir, n)
      local f = io.open(path)
      if f then
        local s = f:read("a"); f:close()
        if s:find('"pos_start"', 1, true) or s:find('"pos_end"', 1, true) then
          wnd[#wnd + 1] = path:match("[^/]+$")
        end
      end
    end
  end
  ok(#wnd == 0, "no shipped scene bank stores the window pair ("
    .. table.concat(wnd, ",") .. ")")
end

-- ============================================================================
-- 10b · the tempo-synced delay reaches a half note at slow tempos
-- ============================================================================
-- the delay line was raised 1s -> 2s exactly so a 1/2 division fits below
-- 120 BPM; the sync clamp has to follow the line or the raise is silent.
do
  ok(params:lookup_param("delay_time").controlspec.maxval >= 2,
    "the delay_time spec reaches the 2s line")
  clock.get_tempo = function() return 60 end
  params:set("delay_sync", 7)              -- 1/2
  near(params:get("delay_time"), 2.0, 1e-6,
    "a half note at 60 BPM syncs to the full 2 seconds")
  params:set("delay_sync", 1)              -- FREE
  params:set("delay_time", 0.3)
  clock.get_tempo = nil
end

-- ============================================================================
-- 11 · the engine contract — every Lua id lands on a real command
-- ============================================================================
-- add_eng_control and every `engine.X` call are guarded (`if engine[id]`), so
-- a typo'd id is not an error anywhere: the knob simply does nothing, forever,
-- and only on the device. The command set the engine builds at alloc (ioKeys
-- plus the playParams/revParams dictionaries plus the explicit addCommands)
-- is parseable from the .sc, so the contract is checkable offscreen.
do
  local sc = io.open("lib/Engine_Mangler.sc"):read("a")
  local cmds = {}
  for id in (sc:match("ioKeys = %[(.-)%]") or ""):gmatch("\\([%w_]+)") do
    cmds[id] = true
  end
  for _, dict in ipairs({ "playParams", "revParams", "delayParams" }) do
    for id in (sc:match(dict .. " = Dictionary%[(.-)%]") or "")
        :gmatch("\\([%w_]+)%s*%->") do
      cmds[id] = true
    end
  end
  for id in sc:gmatch("addCommand%(\\([%w_]+)") do cmds[id] = true end
  ok(cmds.mode and cmds.rev_mix and cmds.erode, "the .sc command set parsed")
  local used = {}
  local function collect(path)
    local s = io.open(path):read("a")
    for id in s:gmatch('add_eng_control%("([%w_]+)"') do used[id] = true end
    for id in s:gmatch('add_eng_binary%("([%w_]+)"') do used[id] = true end
    for id in s:gmatch("engine%.([%w_]+)") do
      if id ~= "name" then used[id] = true end
    end
  end
  collect("mangler.lua")
  for _, f in ipairs({ "mtape", "mdeck", "mpages", "mscenes", "mmotion",
                       "mgrid", "minput" }) do
    collect("lib/" .. f .. ".lua")
  end
  local miss = {}
  for id in pairs(used) do if not cmds[id] then miss[#miss + 1] = id end end
  table.sort(miss)
  ok(#miss == 0, "every Lua engine id is a real command (typo'd: "
    .. table.concat(miss, ",") .. ")")
end

-- ============================================================================
-- 12 · a recalled scene never opens the window onto silence
-- ============================================================================
-- pos_start/pos_end ride scenes, but the material can be SHORTER by the time
-- the scene comes back. The reported trap: capture a scene while the window
-- was the whole 60s buffer, record a 4s phrase (the rec-stop snaps the window
-- to it), recall the scene, and the window reopened over ~56 seconds of
-- nothing, so the take came around once a minute. Stored windows (recall,
-- safe restore, morph target) now clamp to the material's high-water mark;
-- live values and the morph's exact-home restore stay untouched.
do
  -- silence the background movers and undo anything section 6's key mash
  -- latched (same reason as 6b): these assertions read params over ticks
  params:set("orbit_on", 0)
  params:set("motion_rec", 0); params:set("motion_play", 0)
  params:set("stop_all", 0)
  params:set("scene_morph_amt", 0); _h.run_ticks(2)
  params:set("scene_recall_mode", 1)             -- NOW, not queued
  params:set("rec", 0)
  -- clear_recording refuses without an engine `clear` (device truth), and the
  -- env's engine is a bare table. Lend it one so the reset actually resets
  -- take_len/wave_any (section 6's key mash latched a rec-stop at pos_end=1,
  -- which is exactly the full-material state where the clamp stands down)
  local had_clear = engine.clear
  engine.clear = engine.clear or function() end
  params:set("clear_rec", 1); params:set("clear_rec", 0)   -- fresh buffer
  engine.clear = had_clear
  -- a full-buffer window, captured BEFORE any take exists
  params:set("pos_start", 0); params:set("pos_end", 1)
  params:set("scene_slot", 7)
  params:set("scene_capture", 1); params:set("scene_capture", 0)
  -- record a short take: the head walks 0 -> 0.1 and the rec-stop snaps
  _h.push("rec_phase", 0.0); _h.run_ticks(2)
  params:set("rec", 1)
  for i = 1, 10 do
    _h.push("rec_phase", i * 0.01)
    _h.push("rec_amp", 0.5)
    _h.run_ticks(1)
  end
  params:set("rec", 0)
  near(params:get("pos_end"), 0.1, 0.02, "the rec-stop snapped the window to the take")
  local tl = params:get("pos_end")
  -- recall the wide scene: the window lands on the material, not the 60s buffer
  params:set("scene_recall", 1); params:set("scene_recall", 0)
  ok(params:get("pos_end") <= tl + 1e-6,
    "recalling a full-window scene clamps the window to the take")
  ok(params:get("pos_start") < params:get("pos_end"),
    "...and the clamped window still has width")
  -- a stored window INSIDE the material recalls exactly (the clamp never bites)
  params:set("pos_start", 0.02); params:set("pos_end", 0.06)
  params:set("scene_slot", 8)
  params:set("scene_capture", 1); params:set("scene_capture", 0)
  params:set("pos_start", 0); params:set("pos_end", tl)
  params:set("scene_recall", 1); params:set("scene_recall", 0)
  near(params:get("pos_start"), 0.02, 1e-6, "a window inside the material recalls exactly")
  near(params:get("pos_end"), 0.06, 1e-6, "...both edges")
  -- the morph aims at the clamped window too, and still comes home exactly
  params:set("pos_start", 0); params:set("pos_end", tl)
  params:set("scene_slot", 7)                    -- the wide scene again
  params:set("scene_morph_amt", 1); _h.run_ticks(2)
  ok(params:get("pos_end") <= tl + 1e-6,
    "a morph at full amount lands on the clamped window, not the 60s buffer")
  params:set("scene_morph_amt", 0); _h.run_ticks(2)
  near(params:get("pos_end"), tl, 1e-6, "sweeping home restores the origin exactly")
  for _, s in ipairs({ 7, 8 }) do                -- leave the bank as found
    params:set("scene_slot", s)
    params:set("scene_clear", 1); params:set("scene_clear", 0)
  end
end

-- ============================================================================
-- 13 · the page merges: EROSION on VOICE's PLAY face, ORBIT on SCENE
-- ============================================================================
-- two pages became surfaces on the pages they always belonged to. the params
-- are untouched; what must not regress is the REACH — every control that had
-- an encoder or key still has one, in the right mode.
do
  local names = {}
  for name in (io.open("mangler.lua"):read("a")):match("local PAGES = %{(.-)%}"):gmatch('"(%u+)"') do
    names[#names + 1] = name
  end
  local has = {}
  for _, n in ipairs(names) do has[n] = true end
  ok(not has.EROSION and not has.ORBIT, "EROSION and ORBIT are no longer pages")
  ok(has.VOICE and has.SCENE, "...their host pages exist")

  local vi, si
  for i, n in ipairs(names) do
    if n == "VOICE" then vi = i elseif n == "SCENE" then si = i end
  end

  -- VOICE alt in PLAY mode = the erosion pair; other modes keep scan/pitch
  goto_page(vi)
  params:set("mode", 5)                       -- PLAY
  key(1, 1)                                   -- hold K1: the alt layer
  local e0 = params:get("erode")
  enc(2, 3)
  ok(params:get("erode") > e0, "VOICE K1+E2 in PLAY moves erode")
  local w0 = params:get("wear")
  enc(3, 3)
  ok(params:get("wear") ~= w0, "VOICE K1+E3 in PLAY moves wear")
  params:set("mode", 2)                       -- GRAIN: pitch must stay reachable
  local p0 = params:get("pitch")
  enc(3, 3)
  ok(params:get("pitch") ~= p0, "VOICE K1+E3 in GRAIN still moves pitch")
  key(1, 0)
  params:set("pitch", p0)

  -- VOICE K2 is mode-contextual: PLAY = HEAL (a throw on erode), else FRZ.
  -- a DRY tap first: section 6's key mash may have LATCHED the HEAL throw,
  -- and a press on a latched throw unlatches instead of punching
  key(1, 1); key(3, 1); key(3, 0); key(1, 0)
  params:set("mode", 5)
  params:set("erode", 0.5)
  key(2, 1)                                   -- press engages NOW
  near(params:get("erode"), 0, 1e-6, "VOICE K2 in PLAY punches HEAL (erode to 0)")
  _h.run_ticks(7); key(2, 0)                  -- held past TAP: release restores
  near(params:get("erode"), 0.5, 1e-6, "...and the release restores it")
  params:set("erode", 0)
  params:set("mode", 2)
  local f0 = params:get("pv_freeze")
  key(2, 1); key(2, 0)                        -- a tap latches FRZ
  ok(params:get("pv_freeze") ~= f0, "VOICE K2 outside PLAY is still FRZ")
  key(2, 1); key(2, 0)
  params:set("mode", 5)

  -- SCENE alt = the orbit knobs
  goto_page(si)
  key(1, 1)
  local r0 = params:get("orbit_rate")
  enc(2, 3)
  ok(params:get("orbit_rate") ~= r0, "SCENE K1+E2 moves orbit drift")
  local rc0 = params:get("orbit_reach")
  enc(3, 3)
  ok(params:get("orbit_reach") ~= rc0, "SCENE K1+E3 moves orbit reach")
  key(1, 0)

  -- the grid's scene workspace runs the orbit (the wander's only pad)
  local g = _h.grid
  params:set("orbit_on", 0)
  g.key(6, 6, 1); g.key(6, 6, 0)
  ok(params:get("orbit_on") == 1, "grid scene row 6 starts the orbit")
  g.key(6, 6, 1); g.key(6, 6, 0)
  ok(params:get("orbit_on") == 0, "...and stops it")
end

-- ============================================================================
-- 14 · the layer BOUNCE and the FX capture scope
-- ============================================================================
-- the bounce: arming a layer records the processed engine output (WET) and
-- disarming restores the knob's source — resampling is one key. observed at
-- the audio sends Mtape.set_source drives, which is what softcut records.
do
  local adc, eng
  audio.level_adc_cut = function(v) adc = v end
  audio.level_eng_cut = function(v) eng = v end
  params:set("layer_wet", 1)
  params:set("cut_source", 0.5)   -- move it so the set back to 0 fires
  params:set("cut_source", 0)     -- (an equal set is equality-guarded)
  near(eng or -1, 0, 1e-6, "at rest the decks record the input (knob DRY)")
  params:set("lay1_rec", 1)
  near(eng or -1, 1, 1e-6, "arming a layer throws the source WET (the bounce)")
  near(adc or -1, 0, 1e-6, "...and drops the input tap")
  params:set("lay1_rec", 0)
  near(eng or -1, 0, 1e-6, "disarming restores the knob's source")
  params:set("layer_wet", 0)
  params:set("lay2_rec", 1)
  near(eng or -1, 0, 1e-6, "layer_wet OFF: arming leaves the source alone")
  params:set("lay2_rec", 0)
  params:set("layer_wet", 1)
  audio.level_adc_cut, audio.level_eng_cut = nil, nil   -- back to the env nop

  -- FX capture scope: an FX slot carries the wet path and NOTHING else, so
  -- recalling it moves the effects and leaves the material/voice alone
  params:set("scene_recall_mode", 1)
  params:set("scene_scope", 2)                -- FX
  params:set("cutoff", 1234)
  params:set("scene_slot", 7)
  params:set("scene_capture", 1); params:set("scene_capture", 0)
  params:set("cutoff", 20000)
  params:set("scan", 0.5)
  params:set("scene_recall", 1); params:set("scene_recall", 0)
  near(params:get("cutoff"), 1234, 2, "recalling an FX scene restores the filter")
  near(params:get("scan"), 0.5, 1e-6, "...and does NOT touch the voice (scan)")
  params:set("scene_scope", 1)                -- back to ALL
  params:set("scene_clear", 1); params:set("scene_clear", 0)
  params:set("scan", 1); params:set("cutoff", 20000)
end

-- ============================================================================
-- 15 · TRUE STOP — the transports halt, not just the levels
-- ============================================================================
-- S23 B1: STOP used to be a click-free MUTE while every head kept advancing
-- ("24.4s kept advancing"). now the softcut heads glide to rate 0, capture
-- gates, and the engine record head pauses; START resumes all of it in place.
do
  params:set("stop_all", 0)
  params:set("tape_rate", 1); params:set("tape_reverse", 0)
  params:set("lay1_rate", 1); params:set("lay2_rate", 1)
  params:set("lay1_rec", 0); params:set("lay2_rec", 0)
  local rec_sent
  engine.rec = function(v) rec_sent = v end
  params:set("rec", 1)
  ok(rec_sent == 1, "arming opens the engine record head")
  params:set("stop_all", 1)
  for v = 1, 6 do
    local c = sc_last("rate", v)
    ok(c ~= nil and math.abs(c[3]) < 1e-9,
      "STOP halts softcut voice " .. v .. "'s head")
  end
  ok(rec_sent == 0, "STOP pauses the armed engine record head")
  params:set("rec", 0); params:set("rec", 1)
  ok(rec_sent == 0, "an arm made while stopped waits for START")
  params:set("stop_all", 0)
  ok(rec_sent == 1, "START resumes the armed head")
  local c = sc_last("rate", 1)
  ok(c ~= nil and math.abs(c[3] - 1) < 1e-6, "START restores the tape rate")
  c = sc_last("rate", 3)
  ok(c ~= nil and math.abs(c[3] - 1) < 1e-6, "...and the layer decks' rates")
  params:set("rec", 0)
  engine.rec = nil
end

print(string.format("\n%d assertions passed", ok_count))
if #fail > 0 then
  print(#fail .. " FAILED:")
  for _, f in ipairs(fail) do print("  x " .. f) end
  os.exit(1)
end
print("control harness OK")
