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

local T = dofile("tools/harness.lua")
local ok, near = T.ok, T.near

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

-- the script's own state table, read through an upvalue of key() (ctx is a
-- local of mangler.lua): what the params cannot show, the tests read here
local CTX
for i = 1, 255 do
  local n, v = debug.getupvalue(key, i)
  if n == nil then break end
  if n == "ctx" then CTX = v end
end
assert(CTX, "could not reach the script's ctx")

-- 0 · a fresh session holds no take. params:bang() at init fires every
-- action with its default, and the rec action's rec-stop bookkeeping used to
-- run on that 0 and mark the whole 60s buffer as the take before anything was
-- recorded, which disarmed the scene window clamp, TAKE SNAP and the bounded
-- PSET write for the first take of every session.
ok(CTX.take_len == 0, "init leaves take_len at 0 (got " .. tostring(CTX.take_len) .. ")")

-- the params MANGLER owns, captured before the system ones are stubbed in —
-- this is the universe the classification checks (section 9) walk
local MANGLER_IDS = {}
for _, p in ipairs(plist) do MANGLER_IDS[#MANGLER_IDS + 1] = p.id end

-- 0b · every add_group count matches the params that follow it. norns trusts
-- the declared count, and a wrong one (a refused add, a param inserted
-- mid-group) scrambles the PARAMS menu on device and only there.
do
  local G = params.groups
  ok(#G >= 15, "the param groups were recorded (" .. #G .. ")")
  local bad = {}
  for i, g in ipairs(G) do
    local nxt = G[i + 1] and G[i + 1].at or #MANGLER_IDS
    if nxt - g.at ~= g.n then
      bad[#bad + 1] = string.format("%s declares %d, has %d", g.id, g.n, nxt - g.at)
    end
  end
  ok(#bad == 0, "every group count matches its params (" .. table.concat(bad, "; ") .. ")")
end

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
local goto_page = T.goto_page
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
  local names = T.pages()
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
  local names = T.pages()
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
  local names = T.pages()
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
  local names = T.pages()
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
  local names = T.pages()
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

  local page = T.goto_page

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
  local page = T.goto_page

  -- (a) A RELEASE BELONGS TO THE PRESS THAT OPENED IT. Holding a workspace pad
  -- and changing page used to hand the release to a layout that ignored it, so
  -- tape_reverse latched forever and held note pads stranded voices.
  page("TAPE")
  params:set("lay1_start", 0); params:set("lay1_end", 1)
  page("LAYERS")
  g.key(2, 3, 1)                       -- press on the LAYERS workspace
  page("PADS")                         -- ...navigate away while still held
  g.key(2, 3, 0)                       -- ...and release
  page("LAYERS")
  g.key(5, 3, 1); g.key(5, 3, 0)       -- a fresh single-pad span
  near(params:get("lay1_start"), 4 / 8, 1e-6,
    "a span after a cross-page release still anchors on the NEW press")

  -- (b) note-offs are NOT gated on keys_enable: toggling note input mid-hold
  -- must not strand a polyphonic voice
  params:set("pad_input", 1)
  params:set("keys_enable", 1)
  page("TAKE")
  local ons, offs = {}, {}
  engine.note_on = function(id) ons[#ons + 1] = id end
  engine.note_off = function(id) offs[#offs + 1] = id end
  g.key(1, 8, 1)                       -- a piano pad down
  params:set("keys_enable", 0)         -- ...input switched off mid-hold
  g.key(1, 8, 0)                       -- ...and released
  ok(#ons == 1 and #offs == 1 and offs[1] == ons[1],
    "a note pad released after keys_enable went off closes the voice it opened")
  params:set("keys_enable", 1)
  engine.note_on, engine.note_off = nil, nil
  params:set("pad_input", 0)

  -- (c) two fingers on the scene bank: one release must not cancel the other's
  -- peek (row 1 is the bank from any page)
  page("SCENE")
  for s = 1, 2 do                      -- a peek needs a filled slot under it
    params:set("scene_slot", s)
    params:set("scene_capture", 1); params:set("scene_capture", 0)
  end
  params:set("scene_slot", 1)
  g.key(1, 1, 1)                       -- finger A on slot 1
  g.key(2, 1, 1)                       -- finger B on slot 2
  g.key(1, 1, 0)                       -- A lifts
  ok(CTX.peek_on == true, "lifting finger A does not end finger B's peek")
  g.key(2, 1, 0)                       -- B lifts
  ok(CTX.peek_on == false, "...and B's own release does")
  CTX.peek_back = false
  params:set("scene_morph_amt", 0); _h.run_ticks(2)
  for s = 1, 2 do                      -- leave the bank as found
    params:set("scene_slot", s)
    params:set("scene_clear", 1); params:set("scene_clear", 0)
  end

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
  for _, f in ipairs({ "mtape", "mdeck", "mpages", "mwav", "mscenes", "mmotion",
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
  local names = T.pages()
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

-- ============================================================================
-- 16 · SNAP: a layer's loop length lands on a musical grid
-- ============================================================================
-- Two decks at 3.97s and 4.02s walk apart inside a minute; two that are an
-- exact 1x or 2x of each other stay locked forever. What has to hold: the
-- reference is picked in the right order, the ratio is chosen in LOG space
-- (so 1/2 and 2 are equally near), only the loop END moves, and the automatic
-- pass at the end of a record takes a near miss while leaving a length you
-- clearly chose exactly as you played it.
do
  local li
  for i, name in ipairs(T.pages()) do if name == "LAYERS" then li = i end end
  params:set("orbit_on", 0)
  params:set("motion_rec", 0); params:set("motion_play", 0)
  params:set("stop_all", 0)
  params:set("scene_morph_amt", 0); _h.run_ticks(2)
  -- a 6-second take to reference: 0.1 of the 60s buffer
  params:set("pos_start", 0); params:set("pos_end", 0.1)
  params:set("lay2_start", 0); params:set("lay2_end", 1)   -- L2 holds nothing

  -- a loop a little over 3 seconds, against a 6-second take, is a half
  params:set("lay1_start", 0)
  params:set("lay1_end", 3.2 / 60)
  params:set("lay1_snap", 1); params:set("lay1_snap", 0)
  near(params:get("lay1_end") * 60, 3.0, 0.01,
    "SNAP takes a 3.2s loop to half of the 6s take")
  near(params:get("lay1_start"), 0, 1e-9, "...moving only the END, never the start")

  -- and a little over 12 seconds is a double: the nearest ratio in LOG space,
  -- not the nearest absolute length (which would pull everything downward)
  params:set("lay1_end", 12.5 / 60)
  params:set("lay1_snap", 1); params:set("lay1_snap", 0)
  near(params:get("lay1_end") * 60, 12.0, 0.01, "...and a 12.5s loop to double it")

  -- the loop start is honoured: the snapped length runs from wherever the
  -- recording began, not from zero
  params:set("lay1_start", 0.2)
  params:set("lay1_end", 0.2 + 5.7 / 60)
  params:set("lay1_snap", 1); params:set("lay1_snap", 0)
  near((params:get("lay1_end") - params:get("lay1_start")) * 60, 6.0, 0.01,
    "a loop that starts late still snaps its LENGTH")
  near(params:get("lay1_start"), 0.2, 1e-9, "...from where it starts")

  -- a loop parked at the far right cannot GROW past the region, so a ratio
  -- that would round it up halves until it fits, rather than truncating to a
  -- length that is on no grid at all. 5.5s of the 5.7s left rounds to 6s.
  params:set("lay1_start", 0.905)
  params:set("lay1_end", 0.905 + 5.5 / 60)
  params:set("lay1_snap", 1); params:set("lay1_snap", 0)
  ok(params:get("lay1_end") <= 1 + 1e-9, "a snap at the region edge stays inside it")
  near((params:get("lay1_end") - params:get("lay1_start")) * 60, 3.0, 0.02,
    "...by halving to a ratio that fits, not truncating to one on no grid")

  -- the OTHER deck outranks the take once it holds audio. 15.4s reads as 3 x
  -- L2's 5s loop but 3 x the take's 6s would be 18s, so the two answers are
  -- distinguishable and this asserts WHICH reference was used.
  -- arming a layer throws the softcut record source WET (the bounce), so it
  -- is the OUTPUT meter that decides whether the deck heard anything
  _h.push("amp_in_l", 0.5); _h.push("amp_in_r", 0.5)
  _h.push("amp_out_l", 0.5); _h.push("amp_out_r", 0.5); _h.run_ticks(1)
  _h.phase(5, 180)
  params:set("lay2_rec", 1)
  for i = 1, 6 do _h.phase(5, 180 + i); _h.run_ticks(1) end
  params:set("lay2_rec", 0)
  params:set("lay2_start", 0); params:set("lay2_end", 5 / 60)
  params:set("lay1_start", 0); params:set("lay1_end", 15.4 / 60)
  params:set("lay1_snap", 1); params:set("lay1_snap", 0)
  near(params:get("lay1_end") * 60, 15.0, 0.02,
    "the other deck's loop outranks the take as the reference once it has audio")

  -- the AUTOMATIC pass, through the real record gesture on an EMPTY deck.
  -- arming opens the loop, disarming closes it around what was played, and a
  -- near miss rounds onto the grid with no key involved at all.
  _h.phase(3, 120)
  params:set("lay1_rec", 1)
  near(params:get("lay1_end"), 1, 1e-9, "arming an empty layer opens its loop")
  for i = 1, 10 do _h.phase(3, 120 + i * 0.51); _h.run_ticks(1) end   -- ~5.1s
  params:set("lay1_rec", 0)
  near((params:get("lay1_end") - params:get("lay1_start")) * 60, 5.0, 0.02,
    "a 5.1s pass against a 5s reference rounds onto it, hands-free")

  -- ...but a length you clearly CHOSE is left exactly as you played it. 12s
  -- against a 5s reference sits midway between 2x and 3x, nowhere near a
  -- ratio, so the automatic pass declines and the loop stays 12s.
  goto_page(li)
  params:set("layer_sel", 1)
  key(1, 1); key(3, 1); _h.run_ticks(20); key(3, 0); key(1, 0)
  ok(params:get("lay1_end") == 1, "the LAYERS erase empties the deck it is on")
  _h.phase(3, 120)
  params:set("lay1_rec", 1)
  for i = 1, 10 do _h.phase(3, 120 + i * 1.2); _h.run_ticks(1) end    -- 12.0s
  params:set("lay1_rec", 0)
  near((params:get("lay1_end") - params:get("lay1_start")) * 60, 12.0, 0.05,
    "a length that is on no grid is left exactly as played")

  -- and the same length under a FORCED snap does land: it was the tolerance
  -- that declined, not a snap that cannot reach
  params:set("lay1_snap", 1); params:set("lay1_snap", 0)
  near((params:get("lay1_end") - params:get("lay1_start")) * 60, 10.0, 0.05,
    "a FORCED snap lands where the automatic pass declined")

  -- a deck collapsed to a point is not something to measure against. It used
  -- to be offered as a reference anyway, whereupon SNAP refused SILENTLY: a
  -- key that fires, moves nothing and says nothing.
  params:set("lay2_start", 0.5); params:set("lay2_end", 0.5)
  params:set("lay1_start", 0); params:set("lay1_end", 3.2 / 60)
  params:set("lay1_snap", 1); params:set("lay1_snap", 0)
  near(params:get("lay1_end") * 60, 3.0, 0.02,
    "a collapsed deck is skipped as a reference, not answered with silence")

  -- and a loop with no room left refuses OUT LOUD rather than manufacturing a
  -- 100ms loop and labelling it a ratio it is not on
  params:set("lay2_start", 0); params:set("lay2_end", 1)
  params:set("lay1_start", 1); params:set("lay1_end", 1)
  -- the page chip lives on a ctx local, but the SAME text goes to maiden, so
  -- capturing print is a test of what the player is actually told
  local said = {}
  local real_print = print
  print = function(...) said[#said + 1] = table.concat({ ... }, " ") end
  params:set("lay1_snap", 1); params:set("lay1_snap", 0)
  print = real_print
  near(params:get("lay1_end"), 1, 1e-9, "a snap with no room left moves nothing")
  ok(#said > 0 and said[#said]:find("refused") ~= nil,
    "...and says so, instead of reporting a length it did not produce")

  params:set("lay1_rec", 0); params:set("lay2_rec", 0)
  params:set("lay1_start", 0); params:set("lay1_end", 1)
  params:set("lay2_start", 0); params:set("lay2_end", 1)
end

-- ============================================================================
-- 17 - SNAP under the states the loop pair can actually be in
-- ============================================================================
do
  params:set("orbit_on", 0)
  params:set("stop_all", 0)
  params:set("lay1_rec", 0); params:set("lay2_rec", 0)
  params:set("pos_start", 0); params:set("pos_end", 0.1)      -- a 6s take

  -- a CROSSED pair is a legal loop: update_loop sorts it and loop_secs takes
  -- the absolute difference. SNAP anchored on the START param alone, so a
  -- loop already on the grid was RELOCATED to a different span of the region
  -- while the page reported that nothing had moved.
  params:set("lay2_start", 0); params:set("lay2_end", 1)      -- L2's loop: 60s
  params:set("lay1_start", 0.5); params:set("lay1_end", 0.25) -- 15s = 1/4 of it
  params:set("lay1_snap", 1); params:set("lay1_snap", 0)
  local lo = math.min(params:get("lay1_start"), params:get("lay1_end"))
  local hi = math.max(params:get("lay1_start"), params:get("lay1_end"))
  near(lo, 0.25, 1e-9, "SNAP anchors a crossed loop on its LOW edge")
  near(hi, 0.50, 1e-9, "...so a loop already on the grid stays where it was")
  near((hi - lo) * 60, 15.0, 0.02, "...at the length it already had")

  -- a snap that moves nothing must not move the HEAD either: two decks hold
  -- their drift only while both heads keep running, which is the same reason
  -- MUTE silences a deck instead of stopping it.
  params:set("lay2_start", 0); params:set("lay2_end", 6 / 60)   -- reference 6s
  params:set("lay1_start", 0); params:set("lay1_end", 6 / 60)   -- already 1 x L2
  params:set("lay1_snap", 1); params:set("lay1_snap", 0)
  sc_calls = {}
  params:set("lay1_snap", 1); params:set("lay1_snap", 0)
  near((params:get("lay1_end") - params:get("lay1_start")) * 60, 6.0, 0.02,
    "a loop already on the grid stays where it is")
  ok(sc_last("position", 3) == nil,
    "...and a no-op SNAP leaves the head running instead of re-cueing it")
  -- the other half, or "never jump" would pass this too: a snap that DOES
  -- move the loop must re-cue, or the head is left outside its own loop.
  params:set("lay1_end", 7.1 / 60)
  sc_calls = {}
  params:set("lay1_snap", 1); params:set("lay1_snap", 0)
  near((params:get("lay1_end") - params:get("lay1_start")) * 60, 8.0, 0.02,
    "a snap that moves the loop moves it (7.1s -> 4/3 x the 6s reference)")
  ok(sc_last("position", 3) ~= nil, "...and re-cues the head to the new start")

  -- a deck whose own record pass is still OPEN is not a reference: arm_loop
  -- holds its loop at the full region for the length of the pass, and `any`
  -- goes true as soon as it hears anything, so it reads as 60 seconds of
  -- material. The reference NAME is what the assertion reads, because that is
  -- the thing that was wrong: an eighth of a region boundary, called musical.
  -- an EMPTY deck, because that is when arm_loop opens the loop: erase L2
  -- through the real K1+K3 arc, then arm it, which is the two-hand looper
  -- gesture (grid row 5, both decks) this has to survive.
  local li2
  for i, name in ipairs(T.pages()) do if name == "LAYERS" then li2 = i end end
  goto_page(li2)
  params:set("layer_sel", 2)
  key(1, 1); key(3, 1); _h.run_ticks(20); key(3, 0); key(1, 0)
  params:set("layer_sel", 1)
  _h.push("amp_in_l", 0.5); _h.push("amp_in_r", 0.5)
  _h.push("amp_out_l", 0.5); _h.push("amp_out_r", 0.5); _h.run_ticks(1)
  _h.phase(5, 180)
  params:set("lay2_rec", 1)
  for i = 1, 4 do _h.phase(5, 180 + i); _h.run_ticks(1) end    -- L2 mid-pass
  params:set("lay1_start", 0); params:set("lay1_end", 7.6 / 60)
  local said = {}
  local real_print = print
  print = function(...) said[#said + 1] = table.concat({ ... }, " ") end
  params:set("lay1_snap", 1); params:set("lay1_snap", 0)
  print = real_print
  local msg = said[#said] or ""
  ok(msg:find("TAKE") ~= nil and msg:find("L2") == nil,
    "a deck mid-record is skipped, so SNAP falls through to the take")
  params:set("lay2_rec", 0)

  params:set("lay1_start", 0); params:set("lay1_end", 1)
  params:set("lay2_start", 0); params:set("lay2_end", 1)
end

-- ============================================================================
-- 18 - the take's on-disk width is one number, shared with the engine
-- ============================================================================
-- ctx.take_to_wav waits for the async /b_write to REACH the size it computes
-- from ctx.TAKE_BYTES. When write_take moved to int24 and that constant did
-- not, the guard passed at two thirds of the file and the export, the chop
-- and the tighten all read a part-written take. Nothing fails loudly, so the
-- contract is asserted instead.
do
  local sc = io.open("lib/Engine_Mangler.sc"):read("a")
  local fmt = sc:match('bufL%.write%(stem %+%+ "_L%.wav", "wav", "(%w+)"')
  ok(fmt ~= nil, "write_take's sample format is readable from the .sc")
  local bits = fmt and tonumber(fmt:match("(%d+)$"))
  local lua = io.open("mangler.lua"):read("a")
  local declared = tonumber(lua:match("ctx%.TAKE_BYTES = (%d+)"))
  ok(declared ~= nil, "...and mangler.lua declares the matching byte width")
  ok(bits and declared and declared == bits // 8,
    string.format("write_take's %s matches ctx.TAKE_BYTES = %s",
      tostring(fmt), tostring(declared)))
  ok(lua:match("take_frames%(%) %* ctx%.TAKE_BYTES") ~= nil,
    "...and the export's completion guard is sized from that constant")
end

-- ============================================================================
-- 19 - the TAPE's own loop-pedal law, under overdub
-- ============================================================================
-- The tape keeps its own copy of the law (see lib/mtape.lua for why). Its ARM
-- branch has always known that overdub must not re-open the loop, but its
-- DISARM branch snapped regardless: every stacked pass re-cut the loop to
-- whatever slice elapsed, so an 8s loop became 3s, then 1s, converging on the
-- 100ms floor with the stacked audio still sitting in the buffer.
do
  params:set("stop_all", 0)
  params:set("tape_rec", 0)
  params:set("tape_pre", 0)

  -- REPLACE still defines the take: arm opens the loop, disarm closes on it
  params:set("loop_start", 0.2); params:set("loop_end", 0.3)
  _h.phase(1, 0.10 * 60)
  params:set("tape_rec", 1)
  near(params:get("loop_start"), 0, 1e-9, "a REPLACE arm still opens the tape loop")
  near(params:get("loop_end"), 1, 1e-9, "...at both ends")
  _h.phase(1, 0.30 * 60)
  params:set("tape_rec", 0)
  near(params:get("loop_start"), 0.10, 1e-6, "...and the take closes the loop around it")
  near(params:get("loop_end"), 0.30, 1e-6, "...at the head it stopped on")

  -- OVERDUB stacks into the loop it has, and must leave it exactly alone
  params:set("tape_pre", 1)
  _h.phase(1, 0.15 * 60)
  params:set("tape_rec", 1)
  near(params:get("loop_start"), 0.10, 1e-6, "an OVERDUB arm leaves the loop alone")
  near(params:get("loop_end"), 0.30, 1e-6, "...as it always did")
  _h.phase(1, 0.22 * 60)
  params:set("tape_rec", 0)
  near(params:get("loop_start"), 0.10, 1e-6, "...and so does the DISARM")
  near(params:get("loop_end"), 0.30, 1e-6, "...so a stacked pass cannot shrink it")

  -- and the wrap branch cannot blow an overdub loop out to the whole tape
  _h.phase(1, 0.28 * 60)
  params:set("tape_rec", 1)
  _h.phase(1, 0.12 * 60)                    -- wrapped round the loop
  params:set("tape_rec", 0)
  near(params:get("loop_end"), 0.30, 1e-6,
    "a wrapped overdub keeps the loop instead of opening the whole tape")

  params:set("tape_pre", 0)
  params:set("loop_start", 0); params:set("loop_end", 1)
end

-- ============================================================================
-- 20 · the review batch: each defect it fixed, pinned
-- ============================================================================
-- Every one of these passed the harness before it was fixed, because nothing
-- here drove the path. They are written against the failure, not the fix.
do
  local page = T.goto_page
  local function pulse(id) params:set(id, 1); params:set(id, 0) end
  local function fill_slot(s)
    params:set("scene_slot", s); pulse("scene_capture")
  end
  local function clear_bank()
    params:set("orbit_on", 0)
    for s = 1, 8 do params:set("scene_slot", s); pulse("scene_clear") end
  end
  -- silence the background movers (section 6's key mash latches some of them)
  params:set("orbit_on", 0)
  params:set("motion_rec", 0); params:set("motion_play", 0)
  params:set("stop_all", 0)
  params:set("scene_morph_amt", 0); _h.run_ticks(2)
  params:set("scene_recall_mode", 1)
  params:set("scene_scope", 1)
  clear_bank()

  -- (a) LAYERS keys resolve their deck at the PRESS. Hold REC on L1, turn E2
  -- to L2, let go: the release used to go to L2 and leave L1 recording.
  page("LAYERS")
  params:set("layer_sel", 1)
  params:set("lay1_rec", 0); params:set("lay2_rec", 0)
  key(2, 1); _h.run_ticks(8)               -- held past the tap window: a punch
  ok(params:get("lay1_rec") == 1, "holding LAYERS K2 records L1")
  enc(2, 1)                                -- E2 = layer select -> L2
  key(2, 0)
  ok(params:get("lay1_rec") == 0, "a punched L1 REC releases on L1 after E2 moved to L2")
  ok(params:get("lay2_rec") == 0, "...and never arms L2")
  params:set("layer_sel", 1)
  params:set("lay1_play", 1)
  key(3, 1); _h.run_ticks(8)               -- punch MUTE on L1
  enc(2, 1)
  key(3, 0)
  ok(params:get("lay1_play") == 1, "a punched L1 MUTE un-mutes L1 after E2 moved to L2")
  params:set("layer_sel", 1)
  params:set("lay1_start", 0); params:set("lay1_end", 1)

  -- (b) the pad steal mirror follows the engine on a RE-STRUCK note. The
  -- engine re-queues a re-struck id as newest; keeping its old place made the
  -- two steal different voices and stranded the one lua forgot.
  params:set("pad_input", 1)
  params:set("voices", 2)
  local offs = {}
  engine.note_on = function() end
  engine.note_off = function(id) offs[#offs + 1] = id end
  CTX.pad_trigger(901, 0, 1)               -- A
  CTX.pad_trigger(902, 1, 1)               -- B
  CTX.pad_trigger(901, 0, 1)               -- A again: now the newest
  CTX.pad_trigger(903, 2, 1)               -- C: the engine steals the oldest, B
  ok(CTX.pad_held[902] == nil and CTX.pad_held[901] ~= nil and CTX.pad_held[903] ~= nil,
    "a re-struck note is the newest voice, so the steal takes B (as the engine does)")
  offs = {}
  CTX.pad_trigger(901, 0, 0)
  ok(offs[1] == 901, "...and releasing A still sends its note_off")
  CTX.pads_all_off()
  engine.note_on, engine.note_off = nil, nil
  params:set("voices", 8)
  params:set("pad_input", 0)

  -- (c) a PSET saved with the TAPE armed: params:read sets tape_rec before the
  -- loop points, which opened a pass against the OLD session; its disarm then
  -- re-cut the loop the pset had just restored.
  params:set("tape_pre", 0); params:set("tape_rec", 0)
  params:set("loop_start", 0); params:set("loop_end", 1)
  _h.phase(1, 0.5 * 60)
  params:set("tape_rec", 1)                -- the saved arm, read first
  params:set("loop_start", 0.2); params:set("loop_end", 0.3)   -- then the loop
  params.action_read("none", false, 98765) -- the restore hook, after the values
  _h.phase(1, 0.28 * 60)
  params:set("tape_rec", 0)
  near(params:get("loop_start"), 0.2, 1e-9, "a PSET-restored tape loop survives the first disarm")
  near(params:get("loop_end"), 0.3, 1e-9, "...both edges")

  -- (d) a tape pass too short to be a loop gives the loop back (the layers
  -- have done this since the 77th change; the tape left 60 seconds open)
  params:set("loop_start", 0.2); params:set("loop_end", 0.4)
  _h.phase(1, 0.3 * 60)
  params:set("tape_rec", 1)
  near(params:get("loop_end"), 1, 1e-9, "a REPLACE arm opens the tape loop")
  params:set("tape_rec", 0)                -- the head has not moved: a mis-tap
  near(params:get("loop_start"), 0.2, 1e-9, "a declined tape pass gives back the loop it widened")
  near(params:get("loop_end"), 0.4, 1e-9, "...both edges")

  -- (e) the tape seam is capped like the layers': a long fade on a short loop
  params:set("loop_start", 0.1); params:set("loop_end", 0.1 + 0.3 / 60)
  sc_calls = {}
  params:set("tape_fade", 0.4)
  local q = sc_last("fade_time", 1)
  near(q and q[3] or -1, 0.075, 1e-6, "tape_fade is capped at a quarter of a 0.3s loop")
  params:set("tape_fade", 0.05)
  params:set("loop_start", 0); params:set("loop_end", 1)

  -- (f) the TAKE eraser disarms first, like TAPE and LAYERS
  local had_clear = engine.clear
  engine.clear = function() end
  params:set("rec", 1)
  pulse("clear_rec")
  ok(params:get("rec") == 0, "erasing the take while armed disarms REC")
  ok(CTX.take_len == 0 and not CTX.wave_any, "...and leaves an empty take")

  -- (g) arming under STOP paints nothing: the head is held, so a picture of
  -- the input would mark an empty buffer as a take (and save 60s of silence)
  params:set("stop_all", 1)
  params:set("rec", 1)
  for _ = 1, 3 do _h.push("rec_amp", 0.5); _h.run_ticks(1) end
  params:set("rec", 0)
  params:set("stop_all", 0)
  ok(not CTX.wave_any, "a REC armed and released under STOP leaves the buffer EMPTY")
  pulse("clear_rec")

  -- (h) a sample-rate conversion that lands after the take changed is DROPPED.
  -- It takes seconds on a Pi; landing late overwrote a live take recorded in
  -- the meantime. The job runner is captured here so the test decides when
  -- it finishes.
  local real_run, real_exists = clock.run, util.file_exists
  util.file_exists = function(p) local f = io.open(p, "rb"); if f then f:close() end; return f ~= nil end
  local jobs = {}
  clock.run = function(fn) jobs[#jobs + 1] = fn; return {} end
  local function finish(fn)
    local co = coroutine.create(fn)
    repeat
      local okr, err = coroutine.resume(co)
      if not okr then error(err) end
    until coroutine.status(co) == "dead"
  end
  local function wav441(path)               -- 0.1s of stereo at 44.1k
    T.write_wav(path, 44100, 2, 16, 4410, function() return 1000 end)
  end
  local src44 = os.tmpname() .. "-44k.wav"
  wav441(src44)
  local reads = {}
  engine.read_file = function(p) reads[#reads + 1] = p end
  -- positive control first: undisturbed, the conversion lands (the test is
  -- not vacuous)
  CTX.load_sample(src44)
  ok(#jobs == 1 and #reads == 0, "an off-rate sample starts a background conversion")
  finish(table.remove(jobs, 1))
  ok(#reads == 1 and reads[1]:find("srconv", 1, true) ~= nil,
    "...which loads the CONVERTED file when nothing changed meanwhile")
  -- now record a take while it converts
  reads = {}
  CTX.load_sample(src44)
  params:set("rec", 1); params:set("rec", 0)
  finish(table.remove(jobs, 1))
  ok(#reads == 0, "a conversion that finishes after a live take is dropped, not loaded over it")
  -- a second load while one converts WAITS its turn and converts too; the
  -- older conversion, finishing after the newer request, is dropped
  reads = {}
  CTX.load_sample(src44)                   -- job 1 in flight
  local src44b = os.tmpname() .. "-44kb.wav"
  wav441(src44b)
  CTX.load_sample(src44b)                  -- job 2 queued behind it
  ok(#reads == 0, "a second off-rate load queues instead of loading raw")
  finish(table.remove(jobs, 1))            -- job 1 lands late: dropped
  ok(#reads == 0, "...the older conversion does not land on top of it")
  finish(table.remove(jobs, 1))            -- job 2 runs next
  ok(#reads == 1 and reads[1]:find("srconv", 1, true) ~= nil,
    "...and the queued file loads CONVERTED, in tune")
  -- the layer decks share the same guard: erase while converting
  local d1 = CTX.layers[1]
  CTX.layer_load(d1, src44)
  page("LAYERS"); params:set("layer_sel", 1)
  key(1, 1); key(3, 1); _h.run_ticks(20); key(3, 0); key(1, 0)   -- erase L1
  sc_calls = {}
  finish(table.remove(jobs, 1))
  ok(sc_last("buffer_read_stereo") == nil and sc_last("buffer_read_mono") == nil,
    "a layer conversion that finishes after the deck was erased is dropped")
  os.remove(src44); os.remove(src44b)
  engine.read_file = nil
  engine.clear = had_clear
  clock.run, util.file_exists = real_run, real_exists

  -- (i) the SCENE erase clears the slot under the finger when K1+K3 went down,
  -- not the one a running orbit re-aimed to a second later
  for s = 1, 4 do fill_slot(s) end
  page("SCENE")
  params:set("scene_slot", 4)
  key(1, 1); key(3, 1)
  params:set("scene_slot", 2)              -- the orbit re-aims mid-arc
  _h.run_ticks(20)
  key(3, 0); key(1, 0)
  ok(CTX.scene.slots[4] == nil, "the SCENE erase clears the slot it was pressed on")
  ok(CTX.scene.slots[2] ~= nil, "...not the one the selector wandered to")
  -- an unaddressed clear (the footswitch) refuses while the orbit runs
  params:set("orbit_on", 1)
  local sel = math.floor(params:get("scene_slot") + 0.5)
  pulse("scene_clear")
  ok(CTX.scene.slots[sel] ~= nil, "a scene_clear footswitch refuses while the orbit moves the selector")
  params:set("orbit_on", 0)
  params:set("scene_morph_amt", 0); _h.run_ticks(2)
  clear_bank()

  -- (j) re-aiming a sweep at a slot that does not carry a param it displaced
  -- (an FX-only slot) and sweeping home restores it exactly. It used to be
  -- stranded at the half-morphed value forever.
  params:set("size", 0.4); params:set("density", 80)
  fill_slot(3)                             -- ALL: carries size + density
  params:set("scene_scope", 2)
  fill_slot(4)                             -- FX only: no size, no density
  params:set("scene_scope", 1)
  params:set("size", 0.1); params:set("density", 20)
  params:set("scene_slot", 3)
  params:set("scene_morph_amt", 0.5); _h.run_ticks(2)
  ok(math.abs(params:get("size") - 0.1) > 0.01, "the sweep toward slot 3 moved size")
  params:set("scene_slot", 4); _h.run_ticks(2)   -- re-aim mid-sweep
  params:set("scene_morph_amt", 0); _h.run_ticks(2)
  near(params:get("size"), 0.1, 1e-6, "sweeping home after a re-aim restores size exactly")
  near(params:get("density"), 20, 1e-6, "...and density")

  -- (k) every landing zeroes the morph amount, not only the key tap: the ◄
  -- undo and a footswitch recall left it up, and the rail lied
  params:set("scene_slot", 3); pulse("scene_recall")   -- marks ◄ (auto-safe)
  params:set("scene_morph_amt", 0.6); _h.run_ticks(2)
  pulse("scene_safe_restore")
  near(params:get("scene_morph_amt"), 0, 1e-9, "the ◄ undo lands with the morph amount at 0")
  params:set("scene_morph_amt", 0.6); _h.run_ticks(2)
  pulse("scene_recall")
  near(params:get("scene_morph_amt"), 0, 1e-9, "...and so does a recall from the footswitch")
  _h.run_ticks(2)

  -- (l) a capture moves nothing, so it must not forget a latched throw:
  -- latch OPEN, capture the variant, un-latch, and the carved tone comes back
  page("FILTER")
  params:set("filt_type", 1); params:set("cutoff", 1234)
  key(2, 1); key(2, 0)                     -- tap: OPEN latches
  near(params:get("cutoff"), 20000, 1e-6, "OPEN throws the filter open")
  fill_slot(5)
  page("FILTER")
  key(2, 1); key(2, 0)                     -- tap again: back
  near(params:get("cutoff"), 1234, 1e-6, "un-latching OPEN after a capture restores the carved cutoff")

  -- (m) a recall made DURING a held chaos throw ends the hold: the release
  -- used to restore ◄, which the recall had just re-marked with the chaos
  params:set("delay_fb", 0.1); params:set("rev_mix", 0)
  fill_slot(1)
  params:set("chaos_throw", 1)
  params:set("scene_slot", 1); pulse("scene_recall")
  near(params:get("delay_fb"), 0.1, 1e-6, "a recall mid-chaos lands the scene")
  params:set("chaos_throw", 0)
  near(params:get("delay_fb"), 0.1, 1e-6, "...and releasing chaos keeps it, not the madness")
  near(params:get("rev_mix"), 0, 1e-6, "...for every param")

  -- (n) a stored LAYER loop is clamped to the deck's material on recall, the
  -- way the take window is: capture with an empty deck (loop 0..1), record 4s,
  -- recall, and the loop used to reopen over 60 seconds of nothing
  page("LAYERS"); params:set("layer_sel", 1)
  key(1, 1); key(3, 1); _h.run_ticks(20); key(3, 0); key(1, 0)   -- erase L1
  params:set("lay1_start", 0); params:set("lay1_end", 1)
  fill_slot(6)
  _h.push("amp_in_l", 0.5); _h.push("amp_in_r", 0.5)
  _h.push("amp_out_l", 0.5); _h.push("amp_out_r", 0.5)
  _h.phase(3, 120)
  params:set("lay1_rec", 1)
  for i = 1, 16 do _h.phase(3, 120 + i * 0.25) end
  params:set("lay1_rec", 0)
  local closed = params:get("lay1_end")
  ok(closed < 0.2, "the first pass closed the layer loop around 4s (end " .. closed .. ")")
  params:set("scene_slot", 6); pulse("scene_recall")
  ok(params:get("lay1_end") < 0.2,
    "recalling a scene captured on an empty deck keeps the loop on the material (end "
    .. params:get("lay1_end") .. ")")
  params:set("lay1_start", 0); params:set("lay1_end", 1)
  -- the TAPE keeps its extent the same way, from its own phase events
  page("TAPE")
  key(1, 1); key(3, 1); _h.run_ticks(20); key(3, 0); key(1, 0)   -- erase the tape
  params:set("tape_pre", 0)
  params:set("loop_start", 0); params:set("loop_end", 1)
  fill_slot(7)
  _h.phase(1, 6)                           -- 6s into the tape
  params:set("tape_rec", 1)
  for i = 1, 16 do _h.phase(1, 6 + i * 0.25); _h.run_ticks(1) end
  params:set("tape_rec", 0)
  ok(params:get("loop_end") < 0.2, "the tape pass closed its loop (end " .. params:get("loop_end") .. ")")
  params:set("scene_slot", 7); pulse("scene_recall")
  ok(params:get("loop_start") > 0.09 and params:get("loop_end") < 0.18,
    string.format("recalling a scene captured on an empty tape keeps the loop on the material (%.3f..%.3f)",
      params:get("loop_start"), params:get("loop_end")))
  params:set("loop_start", 0); params:set("loop_end", 1)
  _h.push("amp_in_l", 0); _h.push("amp_in_r", 0)
  _h.push("amp_out_l", 0); _h.push("amp_out_r", 0)
  clear_bank()

  -- (o) the orbit with an empty bank leaves the morph knob alone (it parked
  -- every frame, pinning the amount to 0 under the performer's hand)
  params:set("orbit_on", 1)
  params:set("scene_morph_amt", 0.2); _h.run_ticks(3)
  near(params:get("scene_morph_amt"), 0.2, 1e-9, "an idle orbit does not pin the morph knob")
  params:set("orbit_on", 0)
  params:set("scene_morph_amt", 0); _h.run_ticks(2)

  -- (p) ◄ edge cases: scene_next from the back cell starts at slot 1
  for s = 1, 3 do fill_slot(s) end
  params:set("scene_slot", 0)
  pulse("scene_next")
  ok(math.floor(params:get("scene_slot") + 0.5) == 1, "scene_next from ◄ lands on slot 1")
  ok(CTX.scene.unlanded(0) == false, "the ◄ cell is never 'unlanded'")
  clear_bank()

  -- (q) motion: every lane is reachable by the selector
  ok(params:lookup_param("motion_lane").max == #CTX.motion.MOTION_IDS,
    "motion_lane reaches one lane per recordable param")

  -- (r) motion replay writes a region pair WIDENING edge first: a slide
  -- right replayed in lane order crossed the pair for one write every pass
  local mo = CTX.motion
  local crossed = 0
  local real_set = params.set
  params.set = function(self, id, v)
    real_set(self, id, v)
    if (id == "lay1_start" or id == "lay1_end")
        and params:get("lay1_start") > params:get("lay1_end") + 1e-9 then
      crossed = crossed + 1
    end
  end
  params:set("lay1_start", 0.10); params:set("lay1_end", 0.15)
  params:set("motion_rec", 1); _h.run_ticks(2)
  params:set("lay1_end", 0.65); params:set("lay1_start", 0.60)   -- a hand slide right
  _h.run_ticks(3)
  params:set("lay1_start", 0.10); params:set("lay1_end", 0.15)   -- and back left
  _h.run_ticks(3)
  params:set("motion_rec", 0)
  crossed = 0
  _h.run_ticks(40)                         -- several passes of the replay
  params.set = real_set
  ok(crossed == 0, "motion replay never crosses a loop pair (" .. crossed .. " crossed writes)")
  params:set("motion_play", 0)
  while #mo.lane_ids > 0 do mo.clear_lane() end
  -- (s) clearing the last lane drops ALL the loop timing
  ok(mo.loop_len == 0 and mo.rec_len == 0, "clearing the last lane empties the loop's timing")
  params:set("motion_len", 4)
  ok(mo.loop_len == 0, "...so a later motion_len move builds no phantom loop")
  params:set("motion_len", 0)
  params:set("lay1_start", 0); params:set("lay1_end", 1)

  -- (t) motion depth blends in the WARPED space: half depth on an exp
  -- param lands half way up the knob, not most of the way
  params:set("cutoff", 1000)
  params:set("motion_rec", 1); _h.run_ticks(2)
  params:set("cutoff", 300); _h.run_ticks(2)     -- the lane's first value
  params:set("cutoff", 20000); _h.run_ticks(2)
  params:set("motion_rec", 0)
  params:set("motion_depth", 0.5)
  params:set("cutoff", 300)
  local top = 0
  for _ = 1, 12 do _h.run_ticks(1); top = math.max(top, params:get("cutoff")) end
  near(top, math.sqrt(300 * 20000), 150, "half depth on cutoff peaks at the knob's half way")
  params:set("motion_play", 0); params:set("motion_depth", 1)
  while #mo.lane_ids > 0 do mo.clear_lane() end
  params:set("cutoff", 20000)

  -- (u) the grid: presence, the pad-mode pitch swell, the audibility rule
  local g = _h.grid
  page("TAKE")
  CTX.last_input = -1
  g.key(7, 5, 1); g.key(7, 5, 0)           -- a workspace pad
  ok(CTX.last_input == CTX.frame, "a grid press counts as presence for the idle dim")
  params:set("pad_input", 1)
  engine.note_on, engine.note_off = function() end, function() end
  CTX.flash_id = nil
  g.key(1, 8, 1); g.key(1, 8, 0)
  ok(CTX.flash_id ~= "pitch", "a grid note in pad mode does not swell an unchanged pitch")
  engine.note_on, engine.note_off = nil, nil
  params:set("pad_input", 0)
  params:set("stop_all", 1)
  g.leds = {}
  _h.run_ticks(2)
  local bright = false
  for _, l in ipairs(g.leds) do
    if l.y == 4 and l.hue == "white" and (l.z or 0) >= 15 then bright = true end
  end
  ok(not bright, "under STOP the grid's tape playhead is not drawn as playing")
  params:set("stop_all", 0)
end


-- ============================================================================
-- 21 · contracts every change used to re-check by hand
-- ============================================================================
do
  -- (a) the deploy FINGERPRINT: the command count maiden prints after a
  -- RESTART. Section 11 checks every Lua id lands on a command; this checks
  -- the total, so a stray new command fails here instead of on the device.
  local sc = io.open("lib/Engine_Mangler.sc"):read("a")
  local cmds, n = {}, 0
  local function add(id) if not cmds[id] then cmds[id] = true; n = n + 1 end end
  for id in (sc:match("ioKeys = %[(.-)%]") or ""):gmatch("\\([%w_]+)") do add(id) end
  for _, dict in ipairs({ "playParams", "revParams", "delayParams" }) do
    for id in (sc:match(dict .. " = Dictionary%[(.-)%]") or "")
        :gmatch("\\([%w_]+)%s*%->") do add(id) end
  end
  for id in sc:gmatch("addCommand%(\\([%w_]+)") do add(id) end
  ok(n == 65, "the engine command count is 65, the expected fingerprint (got " .. n .. ")")

  -- (b) the buffer length lives in two languages; positions drift with no
  -- error anywhere if only one side changes
  local secs = tonumber(sc:match("var bufSecs = (%d+)"))
  ok(secs ~= nil and secs == CTX.BUF_SECS,
    "the engine's bufSecs matches ctx.BUF_SECS (" .. tostring(secs) .. ")")

  -- (c) the shipped presets hold VALID values, and every momentary is 0: a
  -- pset line fires its action on load, so a 1 on print_take or chaos_throw
  -- goes off the moment the preset opens
  local bad = {}
  for _, dir in ipairs({ "presets/", "presets/layers/" }) do
    for k = 1, 10 do
      local path = string.format("%s%s-%02d.pset", dir,
        dir == "presets/" and "mangler" or "layers", k)
      local f = io.open(path)
      if f then
        for line in f:lines() do
          local id, raw = line:match('^"([%w_]+)"%s*:%s*(.-)%s*$')
          local p = id and lookup[id] and params:lookup_param(id)
          local v = raw and tonumber(raw)
          if p and v then
            local cs = p.controlspec
            local okv = true
            if cs then okv = v >= cs.minval - 1e-9 and v <= cs.maxval + 1e-9
            elseif p.count then okv = v >= 1 and v <= p.count
            elseif p.min then okv = v >= p.min and v <= p.max
            elseif p.behavior then okv = v == 0 or v == 1 end
            if p.behavior == "momentary" and v ~= 0 then okv = false end
            if not okv then bad[#bad + 1] = path:match("[^/]+$") .. ":" .. id .. "=" .. raw end
          end
        end
        f:close()
      end
    end
  end
  ok(#bad == 0, "every shipped preset value is in range, momentaries at 0 ("
    .. table.concat(bad, ",") .. ")")

  -- (d) dist/mangler_single.lua is GENERATED; a stale one ships old code
  local tmp = os.tmpname()
  local okb = os.execute("lua tools/amalgamate.lua mangler.lua " .. tmp .. " >/dev/null")
  local built = io.open(tmp) and io.open(tmp):read("a")
  local shipped = io.open("dist/mangler_single.lua") and io.open("dist/mangler_single.lua"):read("a")
  os.remove(tmp)
  ok(okb and built and built == shipped,
    "dist/mangler_single.lua is a fresh build (run: lua tools/amalgamate.lua)")

  -- (e) doc/controls.md is GENERATED from the script's own tables too
  local ctmp = os.tmpname()
  local okc = os.execute("lua tools/controls.lua " .. ctmp .. " >/dev/null")
  local cmap = io.open(ctmp) and io.open(ctmp):read("a")
  local cdoc = io.open("doc/controls.md") and io.open("doc/controls.md"):read("a")
  os.remove(ctmp)
  ok(okc and cmap and cmap == cdoc,
    "doc/controls.md matches the code (run: lua tools/controls.lua)")
end


-- ============================================================================
-- 22 · the additions after the review
-- ============================================================================
do
  local function pulse(id) params:set(id, 1); params:set(id, 0) end
  params:set("orbit_on", 0)
  params:set("motion_rec", 0); params:set("motion_play", 0)
  params:set("stop_all", 0)
  params:set("scene_morph_amt", 0); _h.run_ticks(2)
  params:set("scene_recall_mode", 1)

  -- (a) a Lua error inside one frame does not end the frame loop
  local real_tick = CTX.motion.tick
  CTX.motion.tick = function() error("boom") end
  local real_print = print
  local said = 0
  print = function(...) said = said + 1 end
  local f0 = CTX.frame
  _h.run_ticks(3)
  print = real_print
  CTX.motion.tick = real_tick
  ok(CTX.frame == f0 + 3, "frames keep running after a frame error")
  ok(said == 1, "...and the error is reported once, not every frame (" .. said .. ")")

  -- (b) while synced, the clock owns the delay time
  clock.get_tempo = function() return 120 end
  params:set("delay_sync", 5)               -- 1/4 at 120 = 0.5s
  near(params:get("delay_time"), 0.5, 1e-6, "a synced delay lands on the beat")
  params:set("delay_time", 0.3)             -- a hand, a scene, a lane
  _h.run_ticks(1)
  near(params:get("delay_time"), 0.5, 1e-6, "...and an outside write is put back on the grid")
  params:set("delay_sync", 1)               -- FREE: the knob is the knob
  params:set("delay_time", 0.3)
  _h.run_ticks(1)
  near(params:get("delay_time"), 0.3, 1e-6, "a FREE delay keeps the time it was given")
  clock.get_tempo = nil

  -- (c) the motion loop rides the PSET
  local mo = CTX.motion
  local real_exists = util.file_exists
  util.file_exists = function(p) local f = io.open(p, "rb"); if f then f:close() end; return f ~= nil end
  params:set("cutoff", 1000)
  params:set("motion_rec", 1); _h.run_ticks(2)
  params:set("cutoff", 400); _h.run_ticks(3)
  params:set("cutoff", 6000); _h.run_ticks(3)
  params:set("motion_rec", 0)
  local lanes, len = #mo.lane_ids, mo.loop_len
  ok(lanes == 1 and len > 0 and params:get("motion_play") == 1, "a gesture loop is recorded and playing")
  params.action_write("x", "x", 98767)
  while #mo.lane_ids > 0 do mo.clear_lane() end
  params:set("motion_play", 1)              -- what params:read restores
  params:set("motion_rec", 1)               -- ...including a saved arm
  params.action_read("x", false, 98767)
  ok(#mo.lane_ids == lanes and mo.loop_len == len, "a PSET load brings the gesture loop back")
  ok(params:get("motion_play") == 1 and params:get("motion_rec") == 0,
    "...playing, and a saved arm does not start a recording over it")
  while #mo.lane_ids > 0 do mo.clear_lane() end
  params.action_write("x", "x", 98767)      -- an empty loop deletes the file
  ok(not util.file_exists(CTX and (norns.state.data .. "motion-98767.lua")),
    "saving with no loop leaves no motion file")
  params.action_delete("x", "x", 98767)
  util.file_exists = real_exists
  params:set("motion_play", 0)
  params:set("cutoff", 20000)

  -- (d) the orbit yields to a hand on the morph, then resumes
  local function fill(slot, cut)
    params:set("cutoff", cut); params:set("scene_slot", slot); pulse("scene_capture")
  end
  fill(1, 500); fill(2, 15000)
  params:set("cutoff", 2000)
  params:set("orbit_rate", 2); params:set("orbit_on", 1)
  _h.run_ticks(5)
  params:set("scene_morph_amt", 0.33)       -- a hand (K1+E1, a MIDI fader)
  _h.run_ticks(10)
  near(params:get("scene_morph_amt"), 0.33, 1e-9, "a running orbit leaves a hand-set morph alone")
  _h.run_ticks(40)                          -- two seconds of quiet, then more
  ok(math.abs(params:get("scene_morph_amt") - 0.33) > 1e-6, "...and resumes once the hand has left")
  params:set("orbit_on", 0)
  params:set("scene_morph_amt", 0); _h.run_ticks(2)

  -- (e) GLIDE: the morph sweeps there over the glide beats, then it lands
  clock.get_tempo = function() return 120 end
  params:set("scene_recall_mode", 4)        -- GLIDE
  params:set("scene_glide", 2)              -- 1 second at 120 = 15 frames
  params:set("cutoff", 2000)
  params:set("scene_slot", 2); pulse("scene_recall")
  _h.run_ticks(7)
  local mid = params:get("cutoff")
  ok(mid > 2000 and mid < 15000, "half way through a glide the sound is between (" .. mid .. ")")
  ok(params:get("scene_morph_amt") > 0.3, "...because the morph is sweeping")
  _h.run_ticks(12)
  near(params:get("cutoff"), 15000, 1e-6, "the glide LANDS the scene")
  near(params:get("scene_morph_amt"), 0, 1e-9, "...with the morph back at 0")
  ok(CTX.scene.safe ~= nil and math.abs(CTX.scene.safe.cutoff - 2000) < 1e-6,
    "...and the way back holds where the glide began")
  -- a hand on the morph stops a glide where it stands
  params:set("cutoff", 2000)
  params:set("scene_slot", 1); pulse("scene_recall")
  _h.run_ticks(4)
  params:set("scene_morph_amt", 0.2); _h.run_ticks(20)
  ok(CTX.scene.glide == nil and math.abs(params:get("cutoff") - 500) > 1,
    "a hand on the morph stops a glide before it lands")
  params:set("scene_recall_mode", 1)
  params:set("scene_morph_amt", 0); _h.run_ticks(2)
  clock.get_tempo = nil
  for s = 1, 2 do params:set("scene_slot", s); pulse("scene_clear") end
  params:set("cutoff", 20000)

  -- (f) a first motion pass played close to a musical length lands on it
  clock.get_tempo = function() return 120 end   -- a bar = 2s = 30 frames
  local function take(frames)
    params:set("motion_len", 0)
    params:set("motion_rec", 1)
    params:set("cutoff", 900); _h.run_ticks(frames - 1)
    params:set("cutoff", 3000); _h.run_ticks(1)
    params:set("motion_rec", 0)
    local got = { rec = mo.rec_len, loop = mo.loop_len }
    params:set("motion_play", 0)
    while #mo.lane_ids > 0 do mo.clear_lane() end
    return got
  end
  local near_bar = take(28)                 -- 29 frames: 3% short of a bar
  ok(near_bar.rec == 29 and near_bar.loop == 30,
    "a pass 3% short of a bar loops on the bar (" .. near_bar.rec .. " -> " .. near_bar.loop .. ")")
  local chosen = take(25)                   -- 26 frames: between 3/4 and 1 bar
  ok(chosen.loop == chosen.rec, "a length clearly between musical lengths stays as played")
  clock.get_tempo = nil
  params:set("cutoff", 20000)

  -- (g) when erosion (or regen) stops, the take's strip is repainted from a
  -- dump of the buffer, unless the take changed while the dump ran. It waits
  -- for a second of quiet, only follows a head that really wrote, and a
  -- performer's dump that arrives during it waits instead of being refused.
  do
    local real_run = clock.run
    local jobs = {}
    clock.run = function(fn) jobs[#jobs + 1] = fn; return {} end
    local function finish(fn)
      if not fn then return end     -- no dump started: the assertion says so
      local co = coroutine.create(fn)
      repeat
        local okr, err = coroutine.resume(co)
        if not okr then error(err) end
      until coroutine.status(co) == "dead"
    end
    local filled = {}
    local real_qf = CTX.wav.queue_fill
    CTX.wav.queue_fill = function(path, bins, secs)
      filled[#filled + 1] = path
      return real_qf(path, bins, secs)
    end
    local writes = 0
    engine.write_take = function(stem, frames)
      writes = writes + 1
      for _, side in ipairs({ "_L", "_R" }) do
        T.write_wav(stem .. side .. ".wav", 48000, 1, 24, frames, function() return 4000000 end)
      end
    end
    local Q = CTX.FPS                           -- a second of frames
    local function erode_stop(m)
      params:set("erode", 0.3); _h.run_ticks(1); params:set("erode", 0)
      _h.run_ticks(m or Q + 1)
    end
    params:set("mode", 5)                       -- PLAY: the erosion head runs
    CTX.wave_any, CTX.take_len = true, 0.002
    erode_stop(Q - 1)
    ok(#jobs == 0, "stopping erosion does not dump at once")
    _h.run_ticks(2)
    ok(#jobs == 1, "...but after a second of quiet")
    finish(table.remove(jobs, 1))
    ok(#filled == 1 and filled[1]:find("mscan-tmp", 1, true) ~= nil,
      "...and the strip repaints from it")
    -- a HEAL tap: erosion back on inside the second
    erode_stop(5)
    params:set("erode", 0.3); _h.run_ticks(Q + 1)
    ok(#jobs == 0, "a HEAL tap (erosion back within a second) dumps nothing")
    -- the mode stops the head as surely as the knob does
    params:set("mode", 2); _h.run_ticks(Q + 1)
    ok(#jobs == 1, "leaving PLAY with erode up repaints the strip too")
    finish(table.remove(jobs, 1))
    params:set("erode", 0)
    erode_stop()
    ok(#jobs == 0, "erode moved outside PLAY (no head ran) dumps nothing")
    params:set("regen", 0.3); CTX.take_len = 0.002
    _h.run_ticks(1); params:set("regen", 0); _h.run_ticks(Q + 1)
    ok(#jobs == 1, "regen writes in every mode, and its stop repaints")
    finish(table.remove(jobs, 1))
    params:set("mode", 5)
    -- a CHOP pressed while the repaint dumps waits for it, then runs
    erode_stop()
    writes = 0
    pulse("pad_chop")
    ok(#jobs == 1 and writes == 0, "a CHOP during the repaint does not start on top of it")
    finish(table.remove(jobs, 1))
    ok(#jobs == 1 and writes == 1, "...it waits, and runs once the repaint is done")
    finish(table.remove(jobs, 1))
    -- the guard holds until the scan is done: a dump asked for while a scan
    -- still reads the shared temp file (a second CHOP, an EXPORT) is refused
    local out1, out2 = os.tmpname(), os.tmpname()
    local refused
    CTX.take_to_wav(out1, function()
      CTX.take_to_wav(out2, function(ok2) refused = ok2 == false end)
    end)
    finish(table.remove(jobs, 1))
    ok(refused == true and #jobs == 0, "a dump asked for during a scan is refused")
    os.remove(out1); os.remove(out2)
    -- ...and a repaint that falls due while a performer's dump runs waits
    -- for it, rather than being refused and lost
    pulse("pad_chop")
    erode_stop(Q + 5)
    ok(#jobs == 1, "a repaint due during a CHOP does not start on top of it")
    finish(table.remove(jobs, 1))
    _h.run_ticks(1)
    ok(#jobs == 1, "...and starts once the CHOP is done")
    finish(table.remove(jobs, 1))
    filled = {}
    erode_stop()
    params:set("rec", 1); params:set("rec", 0)   -- a new pass while it dumps
    finish(table.remove(jobs, 1))
    ok(#filled == 0, "a dump that finishes after the take changed paints nothing")
    CTX.wav.queue_fill = real_qf
    engine.write_take = nil
    clock.run = real_run
    local had_clear = engine.clear
    engine.clear = function() end
    pulse("clear_rec")
    engine.clear = had_clear
  end

  -- (h) in pad mode the grid piano lights the keys whose pad is sounding
  do
    local g = _h.grid
    T.goto_page("TAKE")
    params:set("pad_input", 1)
    engine.note_on, engine.note_off = function() end, function() end
    g.key(3, 8, 1)                          -- E: semitone 4, pad 4
    g.leds = {}
    _h.run_ticks(1)
    local lit = {}
    for _, l in ipairs(g.leds) do
      if l.y == 8 and (l.z or 0) >= 15 and l.hue == "orange" then lit[l.x] = true end
    end
    ok(lit[3] and lit[8], "a sounding pad lights every piano key that plays it (E and high C)")
    g.key(3, 8, 0)
    engine.note_on, engine.note_off = nil, nil
    params:set("pad_input", 0)
  end

  -- (j) a screen-call BUDGET per page, under a loaded state: every strip
  -- holding audio and four MOTION lanes at their 900-event cap. Nothing used
  -- to measure draw calls, which is how MOTION reached 7844 a frame unnoticed.
  do
    local BUDGET = 2500
    local count = 0
    local wrapped = {}
    for k, f in pairs(screen) do
      if type(f) == "function" then
        wrapped[k] = f
        screen[k] = function(...) count = count + 1; return f(...) end
      end
    end
    local was_wave, was_twave = CTX.wave_any, CTX.twave_any
    CTX.wave_any, CTX.twave_any = true, true
    local mo = CTX.motion
    for _, id in ipairs({ "cutoff", "delay_mix", "scan", "rev_mix" }) do
      local L = { f = {}, v = {}, n = 900, cur = 1 }
      local cs = params:lookup_param(id).controlspec
      for e = 1, 900 do L.f[e] = e - 1; L.v[e] = cs:map(0.5 + 0.45 * math.sin(e * 0.2)) end
      mo.lanes[id] = L; mo.lane_ids[#mo.lane_ids + 1] = id
    end
    mo.loop_len, mo.rec_len = 900, 900
    local over = {}
    for i, name in ipairs(T.pages()) do
      T.goto_page(i)
      CTX.page_flash = nil
      count = 0
      redraw()
      if count > BUDGET then over[#over + 1] = name .. "=" .. count end
    end
    ok(#over == 0, "every page draws within " .. BUDGET .. " screen calls a frame ("
      .. table.concat(over, ", ") .. ")")
    for k, f in pairs(wrapped) do screen[k] = f end
    while #mo.lane_ids > 0 do mo.clear_lane() end
    CTX.wave_any, CTX.twave_any = was_wave, was_twave
  end

  -- (i) a Mini MK3 plugged in after load takes over; its arrows step the page
  -- and the scene slot; unplugged, the fallback grid comes back. (the last
  -- test here: it swaps the grid the earlier sections drive)
  do
    local real_devices, real_to_msg = midi.devices, midi.to_msg
    local sent = {}
    local lp = { name = "Launchpad Mini MK3 LPMiniMK3 MIDI Out" }
    function lp:send(m) sent[#sent + 1] = m end
    midi.devices = { [1] = lp }
    midi.to_msg = function(d) return d end
    CTX.grid.midigrid_loaded, CTX.grid.have_midigrid = true, true  -- as on a device with midigrid
    midi.add(lp)
    ok(CTX.grid.have_launchpad and CTX.grid.gg ~= _h.grid,
      "a Mini MK3 plugged in after load takes over the grid")
    ok(CTX.grid.have_midigrid == false, "...and midigrid is no longer the grid")
    ok(sent[1] and sent[1][7] == 0x0E and sent[1][8] == 0x01,
      "...and is put in Programmer mode first")
    T.goto_page("TAKE")
    local p0 = CTX.page
    lp.event({ type = "cc", cc = 94, val = 127 })
    ok(CTX.page == p0 + 1, "the right arrow steps to the next page")
    lp.event({ type = "cc", cc = 93, val = 127 })
    ok(CTX.page == p0, "...and the left arrow back")
    params:set("scene_slot", 3)
    lp.event({ type = "cc", cc = 91, val = 127 })
    lp.event({ type = "cc", cc = 91, val = 0 })   -- a release does nothing
    ok(math.floor(params:get("scene_slot") + 0.5) == 4, "the up arrow steps the scene slot")
    -- norns calls midi.remove while the device is STILL in midi.devices, and
    -- only deletes it afterwards
    midi.remove(lp)
    midi.devices = {}
    ok(not CTX.grid.have_launchpad and CTX.grid.gg == _h.grid,
      "unplugged, the fallback grid comes back")
    ok(CTX.grid.have_midigrid == true,
      "...and midigrid is the grid again, so its pads stay out of the notes")
    CTX.grid.midigrid_loaded, CTX.grid.have_midigrid = false, false
    midi.devices, midi.to_msg = real_devices, real_to_msg
    params:set("scene_slot", 1)
  end
end

-- ============================================================================
-- 23 · erosion runs in its own synth
-- ============================================================================
-- The erosion head used to live inside the PLAY drone, so the drone wrote the
-- take back onto itself on every sample even at erode 0. It is now its own
-- spawn/free synth. The engine cannot run here, so (a) pins the shape in the
-- source; (b) pins the Lua pass counter to the new head, which starts at the
-- window's start each time erosion engages.
do
  local sc = io.open("lib/Engine_Mangler.sc"):read("a")
  local writers, defs = {}, 0
  for name, body in sc:gmatch("SynthDef%(\\mangler_([%w_]+),(.-)}%)%.add;") do
    defs = defs + 1
    if body:find("BufWr", 1, true) then writers[#writers + 1] = name end
  end
  ok(defs >= 10, "the engine's SynthDefs parse out of the .sc (" .. defs .. ")")
  ok(#writers == 1 and writers[1] == "erode",
    "only the erosion synth writes the take with BufWr (" .. table.concat(writers, ",") .. ")")
  local set_mode = sc:match("setMode { arg i;(.-)\n    }")
  ok(set_mode and set_mode:find("this.updateErode", 1, true),
    "a mode switch re-checks the erosion head")
  ok(sc:find("(name == \\erode).if({ this.updateErode })", 1, true),
    "...and so does the erode command")
  ok(sc:find("eroSynth.set(\\gate, 0)", 1, true),
    "the head is released (a fade), not cut")

  -- (b) the pass counter
  local Mp
  for i = 1, 255 do
    local n, v = debug.getupvalue(redraw, i)
    if n == nil then break end
    if n == "Mpages" then Mp = v end
  end
  local function acc()
    for i = 1, 255 do
      local n, v = debug.getupvalue(Mp.erosion_tick, i)
      if n == nil then break end
      if n == "eros_acc" then return v end
    end
  end
  -- an audible engine deck: earlier sections leave the levels anywhere
  params:set("stop_all", 0); params:set("rec", 0); params:set("freeze", 0)
  params:set("regen", 0)
  params:set("mix", 0.5); params:set("out_level", 1); params:set("sc_level", 1)
  params:set("mode", 5)
  Mp.erosion_reset()
  params:set("erode", 0.5)
  _h.run_ticks(6)
  local a1 = acc()
  ok(a1 > 0, "eroding in PLAY advances the pass")
  params:set("freeze", 1); _h.run_ticks(4)
  near(acc(), a1, 1e-12, "...holds while the head is paused")
  params:set("freeze", 0)
  params:set("erode", 0); _h.run_ticks(1)
  params:set("erode", 0.5); _h.run_ticks(1)
  ok(acc() < a1, "...and a new engagement starts a new pass, as the respawned head does")
  params:set("erode", 0)
  Mp.erosion_reset()
end

-- ============================================================================
-- 24 · the code review of full-review
-- ============================================================================
-- The scene and conversion defects the review found. Each assertion failed
-- before its fix.
do
  local page = T.goto_page
  local function pulse(id) params:set(id, 1); params:set(id, 0) end
  local function fill(slot, cut, fb)
    params:set("cutoff", cut); params:set("delay_fb", fb)
    params:set("scene_slot", slot); pulse("scene_capture")
  end
  local function clear_bank()
    for s = 1, 8 do params:set("scene_slot", s); pulse("scene_clear") end
  end
  params:set("orbit_on", 0)
  params:set("motion_rec", 0); params:set("motion_play", 0)
  params:set("stop_all", 0)
  params:set("scene_scope", 1)
  -- a second of frames also lets the strip repaint section 23 left due run
  -- (no write_take here, so it ends at once)
  params:set("scene_morph_amt", 0); _h.run_ticks(CTX.FPS + 2)
  clear_bank()
  clock.get_tempo = function() return 120 end
  params:set("scene_recall_mode", 4)          -- GLIDE
  params:set("scene_glide", 4)                -- 2 seconds at 120 = 30 frames

  -- (a) a GLIDE tapped on K2 crossfades. The peek ramp used to run during
  -- the tap and the glide then started from wherever it had got to.
  fill(1, 500, 0.1); fill(2, 15000, 0.2)
  page("SCENE")
  params:set("scene_slot", 2); params:set("cutoff", 2000)
  key(2, 1); _h.run_ticks(3); key(2, 0)
  _h.run_ticks(1)
  local amt = params:get("scene_morph_amt")
  ok(CTX.scene.glide ~= nil and amt < 0.2,
    "a GLIDE tapped on K2 starts from where the sound stood (" .. amt .. ")")
  _h.run_ticks(35)
  near(params:get("cutoff"), 15000, 1e-6, "...and lands the scene")
  -- the same from a grid scene pad
  local g = _h.grid
  g.key(1, 1, 1); _h.run_ticks(2); g.key(1, 1, 0)
  _h.run_ticks(1)
  amt = params:get("scene_morph_amt")
  ok(CTX.scene.glide ~= nil and amt < 0.2,
    "a GLIDE tapped on a grid scene pad starts from where the sound stood (" .. amt .. ")")
  _h.run_ticks(35)
  near(params:get("cutoff"), 500, 1e-6, "...and lands the scene")
  -- a hold is still a peek, once it is a hold
  params:set("scene_slot", 2)
  key(2, 1); _h.run_ticks(8)
  ok(params:get("scene_morph_amt") > 0.5, "under GLIDE a held K2 still peeks")
  key(2, 0); _h.run_ticks(5)
  near(params:get("cutoff"), 500, 1e-6, "...and its release sweeps home")

  -- (b) a GLIDE made while a chaos throw is held ends the throw, as every
  -- other landing does. Releasing the footswitch mid-glide used to cancel
  -- the glide and land the chaos state, which the glide had just put in ◄.
  params:set("delay_fb", 0.1)
  params:set("chaos_throw", 1)
  params:set("scene_slot", 2); pulse("scene_recall")
  _h.run_ticks(5)
  params:set("chaos_throw", 0)
  ok(CTX.scene.glide ~= nil, "releasing a chaos throw mid-glide leaves the glide running")
  _h.run_ticks(30)
  near(params:get("delay_fb"), 0.2, 1e-6, "...and the glide lands the scene, not the chaos")
  near(params:get("cutoff"), 15000, 1e-6, "...all of it")
  params:set("scene_recall_mode", 1)

  -- (c) the orbit counts a held RCL peek as a hand on the morph. A peek parks
  -- the amount at 1, and after two still seconds the orbit used to park too,
  -- dropping the origin the peek's release sweeps home to.
  clear_bank()
  fill(2, 15000, 0.2)                         -- one slot: the orbit aims at it
  params:set("cutoff", 500)
  params:set("orbit_rate", 60); params:set("orbit_on", 1)
  _h.run_ticks(1)
  key(2, 1); _h.run_ticks(45); key(2, 0)      -- a three second peek
  _h.run_ticks(8)
  local cut = params:get("cutoff")
  ok(cut < 1000, "a long RCL peek under the orbit still returns home (" .. cut .. ")")
  params:set("orbit_on", 0)
  params:set("scene_morph_amt", 0); _h.run_ticks(2)
  clear_bank()
  clock.get_tempo = nil
  params:set("cutoff", 20000); params:set("delay_fb", 0.1)

  -- (d) a conversion whose target moved on stops. The queue used to run it to
  -- the end (tens of seconds for a long file on a Pi) before the newer
  -- request behind it could start.
  local real_run, real_exists = clock.run, util.file_exists
  util.file_exists = function(p) local f = io.open(p, "rb"); if f then f:close() end; return f ~= nil end
  local jobs = {}
  clock.run = function(fn) jobs[#jobs + 1] = fn; return {} end
  local function resumes(co)                  -- run a job to its end; how many steps
    local n = 0
    repeat
      local okr, err = coroutine.resume(co)
      if not okr then error(err) end
      n = n + 1
    until coroutine.status(co) == "dead"
    return n
  end
  local src = os.tmpname() .. "-44k.wav"      -- 1s at 44.1k: a dozen blocks
  T.write_wav(src, 44100, 2, 16, 44100, function() return 1000 end)
  local reads = {}
  engine.read_file = function(p) reads[#reads + 1] = p end
  CTX.load_sample(src)
  local full = resumes(coroutine.create(table.remove(jobs, 1)))
  ok(full > 5 and #reads == 1, "an undisturbed conversion runs (" .. full .. " steps) and lands")
  reads = {}
  CTX.load_sample(src)                        -- A converts
  CTX.load_sample(src)                        -- B queues behind it: A is doomed
  local a = resumes(coroutine.create(table.remove(jobs, 1)))
  ok(a == 1 and #reads == 0, "a doomed conversion stops before it converts (" .. a .. " steps)")
  ok(#jobs == 1, "...and the request behind it starts at once")
  resumes(coroutine.create(table.remove(jobs, 1)))
  ok(#reads == 1, "...and lands")
  reads = {}
  CTX.load_sample(src)
  local co = coroutine.create(table.remove(jobs, 1))
  coroutine.resume(co); coroutine.resume(co)  -- two blocks in
  params:set("rec", 1); params:set("rec", 0)  -- a live pass outranks it
  local rest = resumes(co)
  ok(rest == 1 and #reads == 0,
    "a conversion overtaken mid-way stops at the next block (" .. rest .. " steps)")
  os.remove(src)
  engine.read_file = nil
  clock.run, util.file_exists = real_run, real_exists
end

T.report("control harness OK")
