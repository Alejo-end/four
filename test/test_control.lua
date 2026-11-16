-- test_control.lua — the CONTROL SURFACE, offscreen.
--
-- The render suite proves the instrument DRAWS correctly. It never turns an
-- encoder or presses a key, which is why a whole class of bug walks past it:
-- an encoder target that resolves to nothing, a master level that reaches three
-- decks out of four, a key that re-arms the thing it was meant to cancel.
--
-- So this drives the REAL script through enc() and key() and asserts what
-- reaches the params. It runs on the SAME offscreen norns as the render suite
-- (test/uisim/env.lua), so the two can never disagree about what norns does;
-- the screen is real and simply never read here, because drawing is the
-- render suite's job.
--
--   lua test/test_control.lua        # from the repo root

local T = dofile("test/harness.lua")
local ok, near = T.ok, T.near

-- ---- the offscreen norns, shared with the render suite --------------------
local env = dofile("test/uisim/env.lua")
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
dofile("four.lua")
init()

-- the script's own state table, read through an upvalue of key() (ctx is a
-- local of four.lua): what the params cannot show, the tests read here
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
-- has a name). A target that knows only the first is invisible until you turn
-- that knob on the device.
do
  local src = io.open("four.lua"):read("a")
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
      -- (four) TRACKS's E2 moves the focus, which every later page
      -- follows: put it back on track 1, where the rest of the file expects it
      params:set("track_sel", 1)
    end
  end
end

-- ============================================================================
-- 2b · the zoom-aware fine step covers the pair move too
-- ============================================================================
-- the window and the tape loop tighten their encoder steps as the region
-- narrows; the window move goes through move_pair, which once skipped the
-- scaling, so a tight region nudged at full coarseness.
do
  goto_page("TAKE")
  params:set("pos_start", 0); params:set("pos_end", 0.5)
  key(1, 1)                                  -- hold K1: E2 is the window move
  enc(2, 1)
  local wide = params:get("pos_start")
  CTX.set_pair("pos_start", "pos_end", 0.2, 0.21)
  enc(2, 1)
  local tight = params:get("pos_start") - 0.2
  key(1, 0)
  ok(tight > 0, "a tight window still moves")
  ok(tight < wide * 0.5,
    "...but by a FINER step than a wide one (span-scaled)")
  CTX.set_pair("pos_start", "pos_end", 0, 1)
end

-- ============================================================================
-- 3 · the master reaches everything that makes sound
-- ============================================================================
-- One master, every deck, no exceptions.
do
  sc_calls = {}
  params:set("out_level", 0.25)
  local lv = {}
  for v = 1, 2 do
    local c = sc_last("level", v)
    lv[v] = c and c[3] or nil
  end
  ok(lv[1] ~= nil and lv[2] ~= nil, "the master reaches the tape voices")
  for v = 1, 2 do
    if lv[v] then
      ok(lv[v] < 0.8, "tape voice " .. v .. " is scaled by the master (" .. lv[v] .. ")")
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
  for v = 1, 2 do
    local c = sc_last("level", v)
    ok(c ~= nil, "STOP reaches softcut voice " .. v)
    if c then near(c[3], 0, 1e-6, "STOP silences softcut voice " .. v) end
  end
  params:set("stop_all", 0)
  sc_calls = {}
  params:set("out_level", 0.9)   -- a REAL change, so the action definitely fires
  local back = sc_last("level", 1)
  ok(back and back[3] > 0, "START brings the tape back")
end

-- ============================================================================
-- 5 · the punch law
-- ============================================================================
-- Tapping a LIT key must cancel it and NOT re-arm. That inversion shipped once.
do
  goto_page("TAPE")
  params:set("tape_rec", 0)
  key(2, 1); key(2, 0)                      -- tap: latches
  ok(params:get("tape_rec") == 1, "a tap on REC latches it")
  key(2, 1); key(2, 0)                      -- tap again: cancels
  ok(params:get("tape_rec") == 0, "tapping the lit key cancels it, and does not re-arm")

  -- A def with BOTH `lit` and `tap` is the only shape that can hit the
  -- press-while-lit path, where a cancel must NOT then fire the tap. That
  -- inversion shipped once (tapping a lit PRINT stopped the recording and the
  -- release re-armed it). It cannot be reached at runtime on this branch —
  -- SCENE's RCL only lights BETWEEN press and release, and PADS' pad is a gate
  -- — so it is asserted where it lives instead. The guard has to outlive the
  -- branch that needed it.
  local src2 = io.open("four.lua"):read("a")
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
  -- (four) TRACKS's K2/K3 switch track 1 on and off and cycle its mode
  params:set("track_sel", 1)
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
  page("TAPE")
  local before = params:get("rec")
  g.key(1, 2, 1); g.key(1, 2, 0)
  ok(params:get("rec") ~= before, "the state strip reaches `rec` from the TAPE page")
  g.key(1, 2, 1); g.key(1, 2, 0)

  -- the main workspace: a two-pad span on row 4 sets the tape loop
  params:set("loop_start", 0); params:set("loop_end", 1)
  g.key(3, 4, 1); g.key(6, 4, 1); g.key(3, 4, 0); g.key(6, 4, 0)
  near(params:get("loop_start"), 2 / 8, 1e-6, "a grid span sets the tape loop start")
  near(params:get("loop_end"), 6 / 8, 1e-6, "...and its end")
  -- and it addresses the RIGHT pair: row 3 is the window, and the loop must not move
  local l1s, l1e = params:get("loop_start"), params:get("loop_end")
  g.key(1, 3, 1); g.key(4, 3, 1); g.key(1, 3, 0); g.key(4, 3, 0)
  near(params:get("pos_end"), 4 / 8, 1e-6, "row 3 sets the window")
  near(params:get("loop_start"), l1s, 1e-9, "...and the tape loop is untouched")
  near(params:get("loop_end"), l1e, 1e-9, "...both edges")
  CTX.set_pair("pos_start", "pos_end", 0, 1)

  -- the workspace follows the page: the same pad means something else elsewhere
  page("PADS")
  local l1 = params:get("loop_start")
  g.key(3, 4, 1); g.key(3, 4, 0)
  near(params:get("loop_start"), l1, 1e-9,
    "on PADS, row 4 is not a loop span: it must NOT move the tape loop")

  -- and the LEDs actually light on the main workspace
  page("TAPE")
  g.leds = {}
  _h.run_ticks(2)
  local lit, rows = 0, {}
  for _, l in ipairs(g.leds) do
    if l.y and (l.z or 0) > 0 then lit = lit + 1; rows[l.y] = true end
  end
  ok(lit > 0, "the main workspace lights pads (" .. lit .. ")")
  ok(rows[3] and rows[4], "...on the window row and the loop row")
  params:set("loop_start", 0); params:set("loop_end", 1)
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
  params:set("loop_start", 0); params:set("loop_end", 1)
  g.key(2, 4, 1)                       -- press on the main workspace
  page("PADS")                         -- ...navigate away while still held
  g.key(2, 4, 0)                       -- ...and release
  page("TAPE")
  g.key(5, 4, 1); g.key(5, 4, 0)       -- a fresh single-pad span
  near(params:get("loop_start"), 4 / 8, 1e-6,
    "a span after a cross-page release still anchors on the NEW press")
  params:set("loop_start", 0); params:set("loop_end", 1)

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
  for _, pg in ipairs({ "TAKE", "VOICE", "MIX", "SCENE", "TAPE" }) do
    page(pg)
    local before = params:get("tape_rec")
    g.key(2, 2, 1); g.key(2, 2, 0)
    seen[#seen + 1] = (params:get("tape_rec") ~= before)
    g.key(2, 2, 1); g.key(2, 2, 0)     -- put it back
  end
  local all = true
  for _, v in ipairs(seen) do all = all and v end
  ok(all, "row 2 reaches tape_rec from every page (the spine is page-independent)")

  -- (e) STOP on the grid is the same STOP: it must silence the tape too
  page("VOICE")
  sc_calls = {}
  g.key(8, 2, 1); g.key(8, 2, 0)
  ok(params:get("stop_all") == 1, "grid (8,2) engages the master STOP")
  local q = sc_last("level", 1)
  ok(q ~= nil, "...and it reaches softcut")
  if q then near(q[3], 0, 1e-6, "...and it silences the tape") end
  g.key(8, 2, 1); g.key(8, 2, 0)
  ok(params:get("stop_all") == 0, "...and releases it")
end

-- ============================================================================
-- 9 · every param is CLASSIFIED — the registry check
-- ============================================================================
-- The recurring defect in this codebase's history is a NEW param missing one
-- of the hand-maintained lists its siblings joined: the scene lists, the
-- motion list, the edge pairs, the fine step, the rate format. The lists
-- stay where they are,
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
  -- `tombs`: ids of deleted params that an APPEND-ONLY list keeps in place,
  -- so that no later entry moves. Only those may name a missing param.
  local function check(name, includes, excludes, tombs)
    local inc, exc = set_of(includes), set_of(excludes)
    local tomb = set_of(tombs or {})
    local neither, both, stale = {}, {}, {}
    for _, id in ipairs(MANGLER_IDS) do
      if not inc[id] and not exc[id] then neither[#neither + 1] = id end
      if inc[id] and exc[id] then both[#both + 1] = id end
    end
    for _, id in ipairs(includes) do
      if not lookup[id] and not tomb[id] then stale[#stale + 1] = id end
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
  check("motion", Mmo.MOTION_IDS, Mmo.MOTION_EXCLUDE, Mmo.MOTION_TOMBSTONES)
  -- a tombstone is honest only while it names nothing and still holds its
  -- place: one that became a param again, or that left the list, is a bug
  do
    local at = {}
    for i, id in ipairs(Mmo.MOTION_IDS) do at[id] = i end
    local alive, lost = {}, {}
    for _, id in ipairs(Mmo.MOTION_TOMBSTONES) do
      if lookup[id] then alive[#alive + 1] = id end
      if not at[id] then lost[#lost + 1] = id end
    end
    ok(#alive == 0, "no motion tombstone names a live param (" .. table.concat(alive, ",") .. ")")
    ok(#lost == 0, "every motion tombstone still holds its place (" .. table.concat(lost, ",") .. ")")
    -- the places themselves: the first entry after the tombstones stays where
    -- every preset made before the removal expects it
    ok(at.lay1_level == 60 and at.scene_morph_amt == 74,
      "the lanes after the tombstones did not move (lay1_level "
        .. tostring(at.lay1_level) .. ", scene_morph_amt " .. tostring(at.scene_morph_amt) .. ")")
  end

  -- every *_start/*_end pair is a REGION: it must move widening-edge-first
  -- in the scenes (EDGE_PAIRS) and take the span-scaled fine step (FINE_IDS)
  local src = io.open("four.lua"):read("a")
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
-- SuperCollider reads a rate from an argument's name: t_ makes a trigger
-- control, which falls to 0 after one block, a_ an audio-rate control and i_
-- a fixed one. io's bus arguments were called t_dly and t_rev, so io read bus
-- 0 after the first block and tracks 2 to 4 never reached the delay or the
-- reverb (found on the device on 2026-11-16). No argument may carry a prefix.
-- ============================================================================
do
  local sc = io.open("lib/Engine_Four.sc"):read("a"):gsub("/%*.-%*/", ""):gsub("//[^\n]*", "")
  local bad, seen = {}, 0
  local function names(list)
    for item in list:gmatch("[^,]+") do
      local name = item:match("^%s*([%a_][%w_]*)")
      if name then
        seen = seen + 1
        if name:match("^[tai]_") then bad[#bad + 1] = name end
      end
    end
  end
  for list in sc:gmatch("arg%s+([^;]+);") do names(list) end
  for list in sc:gmatch("{%s*|([^|]+)|") do names(list) end
  -- a NamedControl takes its rate from its name too: \t_x.kr
  for name in sc:gmatch("\\([%a_][%w_]*)%.[aikt]r") do
    if name:match("^[tai]_") then bad[#bad + 1] = name end
  end
  ok(seen > 100, "the engine's argument lists are readable (" .. seen .. " names)")
  ok(#bad == 0, "no engine argument is named t_, a_ or i_ (" .. table.concat(bad, ",") .. ")")
end

-- the files that ship directly in a folder (not in its subfolders) whose path
-- matches one of the patterns, sorted. A global: the checks below and section
-- 10b use it.
function SHIPPED(dir, ...)
  local pats, out = { ... }, {}
  local p = io.popen("ls -1 " .. dir .. " 2>/dev/null")
  for name in p:lines() do
    local path = dir .. name
    for _, pat in ipairs(pats) do
      if path:find(pat) then out[#out + 1] = path; break end
    end
  end
  p:close()
  table.sort(out)
  return out
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
  -- the one system param a preset sets on purpose: the clock the sequencer and
  -- the beat-locked modulators run on (the paramset here is mangler's alone)
  local SYSTEM_IDS = { clock_tempo = true }
  -- the params of the two layer decks are gone (four, thirteenth change), and
  -- no shipped file may name them
  local LAYER_IDS = { layer_sel = true, layer_wet = true }
  for n = 1, 2 do
    for _, k in ipairs({ "rec", "play", "level", "rate", "reverse", "start",
        "end", "pre", "file", "fade", "width", "snap" }) do
      LAYER_IDS["lay" .. n .. "_" .. k] = true
    end
  end
  for id in pairs(LAYER_IDS) do
    ok(not lookup[id], "the layer param " .. id .. " is gone from the paramset")
  end
  local function dead_ok(_, id) return SYSTEM_IDS[id] end
  local checked, dead = 0, {}
  -- every preset and MIDI map that ships in data/, whatever their names
  local sets = SHIPPED("data/", "%.pset$", "%.pmap$", "%.pmap%.example$")
  for _, path in ipairs(sets) do
    local ids = ids_in(path)
    if ids then
      checked = checked + 1
      for _, id in ipairs(ids) do
        if not lookup[id] and not dead_ok(path, id) then
          dead[#dead + 1] = path:match("[^/]+$") .. ":" .. id
        end
      end
    end
  end
  ok(checked == #sets and checked >= 1, "the shipped presets and maps are all readable (" .. checked .. ")")
  ok(#dead == 0, "every preset/pmap id exists in the paramset (dead: "
    .. table.concat(dead, ",") .. ")")

  -- the scene SIDECARS name params by id too, and a dead id there is even
  -- quieter: apply() skips unknown ids without a word. Scan every ["id"]= key.
  local sdead, schecked = {}, 0
  local banks = SHIPPED("data/", "^data/scenes%-%d+%.lua$")
  for _, path in ipairs(banks) do
    local f = io.open(path)
    if f then
      schecked = schecked + 1
      for line in f:lines() do
        local id = line:match('^%s*%["([%w_]+)"%]=')
        if id and id ~= "slots" and id ~= "safe" and id ~= "v"
            and not lookup[id] and not dead_ok(path, id) then
          sdead[#sdead + 1] = path:match("[^/]+$") .. ":" .. id
        end
      end
      f:close()
    end
  end
  ok(schecked == #banks, "the shipped scene sidecars are all readable (" .. schecked .. ")")
  ok(#sdead == 0, "every scene-sidecar id exists in the paramset (dead: "
    .. table.concat(sdead, ",") .. ")")
  -- and none of them may carry the window pair: a stored full-buffer window
  -- recalled over a short sample is the "long silence" trap (the runtime clamp
  -- guards live captures; the SHIPPED banks simply leave the window alone)
  local wnd = {}
  for _, path in ipairs(banks) do
    local f = io.open(path)
    if f then
      local s = f:read("a"); f:close()
      if s:find('"pos_start"', 1, true) or s:find('"pos_end"', 1, true) then
        wnd[#wnd + 1] = path:match("[^/]+$")
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
-- four's extra-track and routing commands, built in loops in the .sc
-- (so not literal): per track 2 to 4, a `t<n>_` command per playParam but
-- the five it does not own, one per strip key, and `t<n>_mode`; and the
-- twelve `send_<from>_<to>`
local function four_cmds(sc, add)
  local skip = { level = true, rec = true, freeze = true, erode = true, wear = true }
  local strip = {}
  for id in (sc:match("stripKeys = %[(.-)%]") or ""):gmatch("\\([%w_]+)") do strip[#strip + 1] = id end
  for n = 2, 4 do
    for id in (sc:match("playParams = Dictionary%[(.-)%]") or ""):gmatch("\\([%w_]+)%s*%->") do
      if not skip[id] then add("t" .. n .. "_" .. id) end
    end
    for _, id in ipairs(strip) do add("t" .. n .. "_" .. id) end
    add("t" .. n .. "_mode")
  end
  for from = 1, 4 do
    for to = 1, 4 do
      if from ~= to then add("send_" .. from .. "_" .. to) end
    end
  end
end

do
  local sc = io.open("lib/Engine_Four.sc"):read("a")
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
  four_cmds(sc, function(id) cmds[id] = true end)
  ok(cmds.mode and cmds.rev_mix and cmds.erode, "the .sc command set parsed")
  ok(cmds.t2_mode and cmds.t3_size and cmds.t4_cutoff and cmds.send_3_1,
    "...with the other tracks' and the routing commands")
  local used = {}
  local function collect(path)
    local s = io.open(path):read("a")
    for id in s:gmatch('add_eng_control%("([%w_]+)"') do used[id] = true end
    for id in s:gmatch('add_eng_binary%("([%w_]+)"') do used[id] = true end
    for id in s:gmatch("engine%.([%w_]+)") do
      if id ~= "name" then used[id] = true end
    end
  end
  collect("four.lua")
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
  params:set("mode", 6)                       -- CLOUD: pitch must stay reachable
  local p0 = params:get("pitch")
  enc(3, 3)
  ok(params:get("pitch") ~= p0, "VOICE K1+E3 in CLOUD still moves pitch")
  -- GRAIN (the granulator): K1 is SPRAY and the pitch spread
  params:set("mode", 2)
  local j0, s0 = params:get("pos_jitter"), params:get("grain_pitch_spread")
  enc(2, 3); enc(3, 3)
  ok(params:get("pos_jitter") > j0 and params:get("grain_pitch_spread") > s0,
    "VOICE K1+E2/E3 in GRAIN move SPRAY and the pitch spread")
  params:set("pos_jitter", j0); params:set("grain_pitch_spread", s0)
  key(1, 0)
  -- the K3 cycle: PLAY > GRAIN > WARP > PV > CLOUD > PLAY, OFF skipped
  params:set("mode", 5)
  local seen = {}
  for _ = 1, 5 do
    key(3, 1); key(3, 0)
    seen[#seen + 1] = params:string("mode")
  end
  ok(table.concat(seen, " ") == "GRAIN WARP PV CLOUD PLAY",
    "VOICE K3 cycles GRAIN WARP PV CLOUD and back to PLAY (" .. table.concat(seen, " ") .. ")")
  local sent_mode
  local real_mode = engine.mode
  engine.mode = function(v) sent_mode = v end
  params:set("mode", 6)
  ok(sent_mode == 5, "CLOUD is engine mode 5 (the Clouds voice)")
  engine.mode = real_mode
  params:set("mode", 5)
  key(1, 1)
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

  -- SCENE: E2 picks A and E3 picks B with no shift, K1+E3 fades, and K1+E2
  -- is nothing. The orbit's drift and reach live in PARAMS.
  goto_page(si)
  params:set("scene_slot_a", 0)
  params:set("scene_slot", 4)
  params:set("scene_morph_amt", 0)
  local r0, rc0 = params:get("orbit_rate"), params:get("orbit_reach")
  local b0, m0 = params:get("scene_slot"), params:get("scene_morph_amt")
  enc(2, 3)
  ok(params:get("scene_slot_a") == 3, "SCENE E2 picks A (LIVE + 3 = slot 3)")
  ok(params:get("scene_slot") == b0, "...and leaves B where it was")
  ok(params:get("orbit_rate") == r0, "...and moves no orbit drift")
  enc(2, -20)
  ok(params:get("scene_slot_a") == 0, "...and E2 turned down comes back to LIVE")
  enc(3, 2)
  ok(params:get("scene_slot") == b0 + 2, "SCENE E3 picks B")
  ok(params:get("scene_morph_amt") == m0, "...and does not fade")
  enc(3, -2)
  key(1, 1)
  local a1 = params:get("scene_slot_a")
  enc(2, 3)
  ok(params:get("scene_slot_a") == a1 and params:get("scene_slot") == b0,
    "SCENE K1+E2 moves nothing")
  enc(3, 4)
  ok(params:get("scene_morph_amt") > m0 and params:get("orbit_reach") == rc0,
    "SCENE K1+E3 fades (not orbit reach)")
  enc(3, -40)
  key(1, 0)
  params:set("scene_morph_amt", 0)
  ok(params:lookup_param("orbit_rate").name == "orbit drift"
      and params:lookup_param("orbit_reach").name == "orbit reach",
    "the orbit's drift and reach are still params (PARAMS, MIDI, presets)")

  -- the grid's scene workspace runs the orbit (the wander's only pad)
  local g = _h.grid
  params:set("orbit_on", 0)
  g.key(6, 6, 1); g.key(6, 6, 0)
  ok(params:get("orbit_on") == 1, "grid scene row 6 starts the orbit")
  g.key(6, 6, 1); g.key(6, 6, 0)
  ok(params:get("orbit_on") == 0, "...and stops it")
end

-- ============================================================================
-- 14 · the tape's record source and the FX capture scope
-- ============================================================================
-- cut_source is the one thing that decides what softcut records. observed at
-- the audio sends Mtape.set_source drives.
do
  local adc, eng
  audio.level_adc_cut = function(v) adc = v end
  audio.level_eng_cut = function(v) eng = v end
  params:set("cut_source", 0.5)   -- move it so the set back to 0 fires
  near(eng or -1, 0.5, 1e-6, "cut_source at half sends half of the engine output")
  near(adc or -1, 0.5, 1e-6, "...and half of the input tap")
  params:set("cut_source", 0)     -- (an equal set is equality-guarded)
  near(eng or -1, 0, 1e-6, "at rest the tape records the input (knob DRY)")
  near(adc or -1, 1, 1e-6, "...through the full input tap")
  params:set("tape_rec", 1)
  near(eng or -1, 0, 1e-6, "arming the tape leaves the source alone")
  params:set("tape_rec", 0)
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
  local rec_sent
  engine.rec = function(v) rec_sent = v end
  params:set("rec", 1)
  ok(rec_sent == 1, "arming opens the engine record head")
  params:set("stop_all", 1)
  for v = 1, 2 do
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
  params:set("rec", 0)
  engine.rec = nil
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
  local sc = io.open("lib/Engine_Four.sc"):read("a")
  local fmt = sc:match('bufLs%[opIdx%]%.write%(stem %+%+ "_L%.wav", "wav", "(%w+)"')
  ok(fmt ~= nil, "write_take's sample format is readable from the .sc")
  local bits = fmt and tonumber(fmt:match("(%d+)$"))
  local lua = io.open("four.lua"):read("a")
  local declared = tonumber(lua:match("ctx%.TAKE_BYTES = (%d+)"))
  ok(declared ~= nil, "...and four.lua declares the matching byte width")
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
  local pulse = T.pulse
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

  -- (a) was the LAYERS keys, which resolved their deck at the press. It went
  -- with the layer decks (four, thirteenth change).

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

  -- (d) a tape pass too short to be a loop gives the loop back (the tape
  -- once left 60 seconds open)
  params:set("loop_start", 0.2); params:set("loop_end", 0.4)
  _h.phase(1, 0.3 * 60)
  params:set("tape_rec", 1)
  near(params:get("loop_end"), 1, 1e-9, "a REPLACE arm opens the tape loop")
  params:set("tape_rec", 0)                -- the head has not moved: a mis-tap
  near(params:get("loop_start"), 0.2, 1e-9, "a declined tape pass gives back the loop it widened")
  near(params:get("loop_end"), 0.4, 1e-9, "...both edges")

  -- (e) the tape seam is capped by the deck law: a long fade on a short loop
  params:set("loop_start", 0.1); params:set("loop_end", 0.1 + 0.3 / 60)
  sc_calls = {}
  params:set("tape_fade", 0.4)
  local q = sc_last("fade_time", 1)
  near(q and q[3] or -1, 0.075, 1e-6, "tape_fade is capped at a quarter of a 0.3s loop")
  params:set("tape_fade", 0.05)
  params:set("loop_start", 0); params:set("loop_end", 1)

  -- (f) the TAKE eraser disarms first, like TAPE
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
  local finish = T.finish
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

  -- (n) a stored TAPE loop is clamped to the deck's material on recall, the
  -- way the take window is: capture with an empty tape (loop 0..1), record 4s,
  -- recall, and the loop used to reopen over 60 seconds of nothing. The tape
  -- keeps its extent from its own phase events
  _h.push("amp_in_l", 0.5); _h.push("amp_in_r", 0.5)
  _h.push("amp_out_l", 0.5); _h.push("amp_out_r", 0.5)
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
    if (id == "loop_start" or id == "loop_end")
        and params:get("loop_start") > params:get("loop_end") + 1e-9 then
      crossed = crossed + 1
    end
  end
  params:set("loop_start", 0.10); params:set("loop_end", 0.15)
  params:set("motion_rec", 1); _h.run_ticks(2)
  params:set("loop_end", 0.65); params:set("loop_start", 0.60)   -- a hand slide right
  _h.run_ticks(3)
  params:set("loop_start", 0.10); params:set("loop_end", 0.15)   -- and back left
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
  params:set("loop_start", 0); params:set("loop_end", 1)

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
  local sc = io.open("lib/Engine_Four.sc"):read("a")
  local cmds, n = {}, 0
  local function add(id) if not cmds[id] then cmds[id] = true; n = n + 1 end end
  for id in (sc:match("ioKeys = %[(.-)%]") or ""):gmatch("\\([%w_]+)") do add(id) end
  for _, dict in ipairs({ "playParams", "revParams", "delayParams" }) do
    for id in (sc:match(dict .. " = Dictionary%[(.-)%]") or "")
        :gmatch("\\([%w_]+)%s*%->") do add(id) end
  end
  for id in sc:gmatch("addCommand%(\\([%w_]+)") do add(id) end
  four_cmds(sc, add)
  ok(n == 198, "the engine command count is 198, the expected fingerprint (got " .. n .. ")")

  -- (b) the buffer length lives in two languages; positions drift with no
  -- error anywhere if only one side changes
  local secs = tonumber(sc:match("var bufSecs = (%d+)"))
  ok(secs ~= nil and secs == CTX.BUF_SECS,
    "the engine's bufSecs matches ctx.BUF_SECS (" .. tostring(secs) .. ")")

  -- (c) the shipped presets hold VALID values, and every momentary is 0: a
  -- pset line fires its action on load, so a 1 on print_take or chaos_throw
  -- goes off the moment the preset opens
  local bad = {}
  for _, path in ipairs(SHIPPED("data/", "%.pset$")) do
    do
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

  -- (d) dist/four_single.lua is GENERATED; a stale one ships old code.
  -- The generators run on the interpreter running this harness (LUA53 under
  -- test/check.lua), not on whatever `lua` is on PATH.
  local LUA = (arg and arg[-1]) or "lua"
  local tmp = os.tmpname()
  local okb = os.execute(LUA .. " test/amalgamate.lua four.lua " .. tmp .. " >/dev/null")
  local built = io.open(tmp) and io.open(tmp):read("a")
  local shipped = io.open("dist/four_single.lua") and io.open("dist/four_single.lua"):read("a")
  os.remove(tmp)
  ok(okb and built and built == shipped,
    "dist/four_single.lua is a fresh build (run: lua test/amalgamate.lua)")

  -- (e) doc/controls.md is GENERATED from the script's own tables too
  local ctmp = os.tmpname()
  local okc = os.execute(LUA .. " test/controls.lua " .. ctmp .. " >/dev/null")
  local cmap = io.open(ctmp) and io.open(ctmp):read("a")
  local cdoc = io.open("doc/controls.md") and io.open("doc/controls.md"):read("a")
  os.remove(ctmp)
  ok(okc and cmap and cmap == cdoc,
    "doc/controls.md matches the code (run: lua test/controls.lua)")
end


-- ============================================================================
-- 22 · the additions after the review
-- ============================================================================
do
  local pulse = T.pulse
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
    local finish = T.finish   -- nil (no dump started) runs nothing
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
    -- a burst that starts and ends between two frames (a CC, a motion lane)
    -- still wrote the buffer, and the frame poll alone never sees it
    params:set("regen", 0.3); params:set("regen", 0); _h.run_ticks(Q + 1)
    ok(#jobs == 1, "a regen burst shorter than a frame still repaints")
    finish(table.remove(jobs, 1))
    params:set("mode", 5)
    params:set("erode", 0.3); params:set("erode", 0); _h.run_ticks(Q + 1)
    ok(#jobs == 1, "...and so does an erosion burst in PLAY")
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
    CTX.grid.midigrid_loaded = true           -- as on a device with midigrid
    -- the fallback's connect records what it could see: midigrid scans
    -- midi.devices itself, and cannot be told to skip a leaving device
    local real_connect, seen_lp = grid.connect, nil
    grid.connect = function()
      seen_lp = false
      for _, dv in pairs(midi.devices) do if dv == lp then seen_lp = true end end
      return real_connect()
    end
    midi.add(lp)
    ok(not CTX.grid.have_launchpad, "a plugged-in Mini MK3 connects on the next grid frame")
    CTX.grid.redraw()
    ok(CTX.grid.have_launchpad and CTX.grid.gg ~= _h.grid,
      "a Mini MK3 plugged in after load takes over the grid")
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
    local n_sent = #sent
    midi.remove(lp)
    ok(not CTX.grid.have_launchpad and CTX.grid.gg == nil,
      "unplugged, the Launchpad is dropped at once")
    midi.devices = {}
    CTX.grid.redraw()
    ok(#sent == n_sent, "...nothing is drawn to it after it left")
    ok(seen_lp == false, "...and the fallback connects only once norns has deleted it")
    ok(not CTX.grid.have_launchpad and CTX.grid.gg == _h.grid,
      "unplugged, the fallback grid comes back")
    grid.connect = real_connect
    CTX.grid.midigrid_loaded = false
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
  local sc = io.open("lib/Engine_Four.sc"):read("a")
  local writers, defs = {}, 0
  for name, body in sc:gmatch("SynthDef%(\\four_([%w_]+),(.-)}%)%.add;") do
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
  local pulse = T.pulse
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
  -- a BEAT recall tapped on K2 waits for the beat: the peek ramp used to run
  -- during the tap and leave the morph raised until the landing
  params:set("scene_recall_mode", 2)          -- BEAT
  local real_run, queued = clock.run, {}
  clock.run = function(fn) queued[#queued + 1] = fn; return {} end
  params:set("scene_slot", 2)
  key(2, 1); _h.run_ticks(3); key(2, 0)
  _h.run_ticks(1)
  clock.run = real_run
  amt = params:get("scene_morph_amt")
  ok(#queued == 1 and amt < 0.2,
    "a BEAT recall tapped on K2 does not move the sound before the beat (" .. amt .. ")")
  params:set("scene_recall_mode", 4)
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
  local finish = T.finish                     -- returns how many steps
  local src = os.tmpname() .. "-44k.wav"      -- 1s at 44.1k: a dozen blocks
  T.write_wav(src, 44100, 2, 16, 44100, function() return 1000 end)
  local reads = {}
  engine.read_file = function(p) reads[#reads + 1] = p end
  CTX.load_sample(src)
  local full = finish(table.remove(jobs, 1))
  ok(full > 5 and #reads == 1, "an undisturbed conversion runs (" .. full .. " steps) and lands")
  reads = {}
  CTX.load_sample(src)                        -- A converts
  CTX.load_sample(src)                        -- B queues behind it: A is doomed
  local a = finish(table.remove(jobs, 1))
  ok(a == 1 and #reads == 0, "a doomed conversion stops before it converts (" .. a .. " steps)")
  ok(#jobs == 1, "...and the request behind it starts at once")
  finish(table.remove(jobs, 1))
  ok(#reads == 1, "...and lands")
  reads = {}
  CTX.load_sample(src)
  local co = coroutine.create(table.remove(jobs, 1))
  coroutine.resume(co); coroutine.resume(co)  -- two blocks in
  params:set("rec", 1); params:set("rec", 0)  -- a live pass outranks it
  local rest = finish(co)
  ok(rest == 1 and #reads == 0,
    "a conversion overtaken mid-way stops at the next block (" .. rest .. " steps)")
  os.remove(src)
  engine.read_file = nil
  clock.run, util.file_exists = real_run, real_exists
end

-- ============================================================================
-- 25 · start on sound
-- ============================================================================
-- An arm with rec_wait on records at once, and the take starts where the
-- head stood on the last quiet frame before the sound, less one frame.
do
  local PRE = (1 / CTX.FPS) / CTX.BUF_SECS
  local function pass(arm, quiet_to, sound_at, stop_at)
    _h.push("rec_amp", 0); _h.push("rec_phase", arm); _h.run_ticks(1)
    params:set("rec", 1)
    local waited = CTX.rec_waiting
    local ph = arm
    while ph < quiet_to - 1e-9 do
      ph = ph + 0.002
      _h.push("rec_phase", ph % 1); _h.push("rec_amp", 0.01); _h.run_ticks(1)
    end
    local still = CTX.rec_waiting
    if sound_at then
      _h.push("rec_phase", sound_at); _h.push("rec_amp", 0.3); _h.run_ticks(1)
    end
    _h.push("rec_phase", stop_at); _h.run_ticks(1)
    params:set("rec", 0)
    return waited, still
  end
  params:set("stop_all", 0); params:set("freeze", 0)
  params:set("rec_wait", 1); params:set("rec_thresh", 0.05)
  local waited, still = pass(0.10, 0.12, 0.13, 0.20)
  ok(waited and still, "an arm with start-on-sound waits, through input under the threshold")
  ok(not CTX.rec_waiting, "...and a sound over it ends the wait")
  near(params:get("pos_start"), 0.12 - PRE, 1e-4,
    "...the take starts at the last quiet frame, less one more")
  near(params:get("pos_end"), 0.20, 1e-4, "...and ends where the pass stopped")
  pass(0.50, 0.50, 0.501, 0.55)
  near(params:get("pos_start"), 0.50, 1e-4, "the pre-roll never reaches back before the arm")
  pass(0.30, 0.35, nil, 0.36)
  near(params:get("pos_start"), 0.30, 1e-4, "a pass with no sound is the whole pass")
  ok(not CTX.rec_waiting, "...and ends its wait")
  pass(0.95, 1.03, 0.04, 0.07)                -- the head wrapped while it waited
  near(params:get("pos_start"), 0.03 - PRE, 1e-4,
    "a wait that wrapped the buffer starts the take at the sound")
  near(params:get("pos_end"), 0.07, 1e-4, "...a window, not the whole buffer")
  -- a hit stopped a moment later is still a take (the 0.3s floor), not the
  -- previous take's window left over the silence this pass wrote
  pass(0.20, 0.30, 0.302, 0.303)
  near(params:get("pos_start"), 0.30 - PRE, 1e-4, "a short hit after a long wait is the take")
  near(params:get("pos_end"), 0.30 - PRE + 0.005, 1e-4, "...at least the 0.3s floor long")
  -- an overdub keeps the old material under the new, so it never waits
  params:set("pre_level", 0.7)
  pass(0.60, 0.65, 0.66, 0.70)
  near(params:get("pos_start"), 0.60, 1e-4, "an overdub does not wait: the take starts at the arm")
  params:set("pre_level", 0)
  -- read live: turned off while WAIT shows, the start stays at the arm
  _h.push("rec_amp", 0); _h.push("rec_phase", 0.40); _h.run_ticks(1)
  params:set("rec", 1)
  _h.push("rec_phase", 0.42); _h.run_ticks(1)
  ok(CTX.rec_waiting, "armed to start on sound, WAIT shows")
  params:set("rec_wait", 0); _h.run_ticks(1)
  ok(not CTX.rec_waiting, "...turned off, it stops waiting at once")
  _h.push("rec_phase", 0.43); _h.push("rec_amp", 0.3); _h.run_ticks(1)
  _h.push("rec_phase", 0.48); _h.run_ticks(1)
  params:set("rec", 0)
  near(params:get("pos_start"), 0.40, 1e-4, "...and the take starts at the arm")
  params:set("rec_wait", 1)
  -- a take laid past the old window's end: the pair never crosses on the way
  params:set("rec_wait", 0)
  local crossed = false
  local real_set = params.set
  params.set = function(self, id, v, ...)
    real_set(self, id, v, ...)
    if params:get("pos_start") > params:get("pos_end") then crossed = true end
  end
  pass(0.10, 0.10, nil, 0.20)                 -- window 0.10..0.20
  pass(0.70, 0.70, nil, 0.80)                 -- the next take, past its end
  params.set = real_set
  ok(not crossed and math.abs(params:get("pos_start") - 0.70) < 1e-4,
    "a new take past the old window's end moves the window without crossing it")
  params:set("rec_wait", 1)
  -- a STOP holds the wait: the head writes nothing, so a level then is not sound
  _h.push("rec_amp", 0); _h.push("rec_phase", 0.6); _h.run_ticks(1)
  params:set("rec", 1)
  params:set("stop_all", 1)
  _h.push("rec_amp", 0.3); _h.run_ticks(2)
  ok(CTX.rec_waiting, "under a STOP a sound does not end the wait")
  params:set("stop_all", 0); _h.push("rec_phase", 0.62); _h.run_ticks(1)
  ok(not CTX.rec_waiting, "...and on START it does")
  params:set("rec", 0)
  params:set("rec_wait", 0)
  pass(0.40, 0.42, 0.43, 0.48)
  near(params:get("pos_start"), 0.40, 1e-4, "with start-on-sound off, the take starts at the arm")
  _h.push("rec_amp", 0)
end

-- ============================================================================
-- 26 · the pad sequencer
-- ============================================================================
-- A generated pattern on the clock plays the pads through pad_trigger, one
-- voice id, released at every step boundary. The clock is driven by hand
-- here: fire(beats) is one boundary.
do
  local seq = CTX.seq
  local real_run, real_on, real_off = clock.run, engine.note_on, engine.note_off
  local ons, offs = {}, 0
  engine.note_on = function(id, pos, rate, typ, amp, len) ons[#ons + 1] = { id = id, pos = pos } end
  engine.note_off = function() offs = offs + 1 end
  clock.run = function() return {} end
  local cancelled = 0
  local real_cancel = clock.cancel
  clock.cancel = function() cancelled = cancelled + 1 end
  CTX.wave_any = true
  params:set("stop_all", 0)
  local function hits()
    local t = {}
    for i = 1, math.floor(params:get("step_len") + 0.5) do t[i] = seq.hits[i] and "x" or "." end
    return table.concat(t)
  end
  params:set("step_len", 8); params:set("step_fill", 3)
  ok(hits() == "x..x..x.", "3 of 8 steps spread evenly (" .. hits() .. ")")
  params:set("step_fill", 0)
  ok(hits() == "........", "no steps that play is silence")
  params:set("step_fill", 12)
  ok(hits() == "xxxxxxxx", "more hits than steps fills them all")
  params:set("step_len", 4); params:set("step_fill", 4); params:set("step_order", 1)
  ok(seq.slices[1] == 0 and seq.slices[4] == 3, "UP plays the pads in turn")
  params:set("step_order", 2)
  ok(seq.slices[1] == 7 and seq.slices[4] == 4, "DOWN plays them from the top")
  params:set("step_len", 16); params:set("step_fill", 16); params:set("step_order", 3)
  ok(seq.slices[8] == 7 and seq.slices[9] == 6 and seq.slices[15] == 0,
    "BOUNCE turns at the ends")
  params:set("step_len", 4); params:set("step_fill", 4); params:set("step_order", 1)
  params:set("step_div", 2); params:set("step_gate", 1); params:set("step_chance", 1)
  params:set("step_run", 1)
  ok(seq.running(), "sequencer run starts its clock")
  ok(seq.fire(0) == nil and #ons == 1 and ons[1].id == seq.VOICE_ID,
    "a hit plays a pad voice, held to the next step when legato")
  ok(CTX.pad_held[seq.VOICE_ID] == 0, "...the first step's pad")
  seq.fire(4)                                 -- one bar later: step 2
  ok(offs == 1 and #ons == 2 and CTX.pad_held[seq.VOICE_ID] == 1,
    "the next step releases the voice and plays the next pad")
  ok(seq.step == 1, "...and the page reads which step fired")
  seq.fire(16)                                -- four bars: round to step 1
  ok(seq.step == 0 and CTX.pad_held[seq.VOICE_ID] == 0, "the step is read off the beat count")
  params:set("step_gate", 0.5)
  local hold = seq.fire(4)
  near(hold, 4 * 0.5 * 60 / CTX.tempo(), 1e-9, "a gate under a step holds that part of it")
  params:set("step_gate", 0.998)
  local step_s = 4 * 60 / CTX.tempo()
  near(seq.fire(4), step_s - 0.03, 1e-9,
    "a gate close to legato still releases before the next boundary")
  params:set("step_gate", 1)
  local fired = seq.step
  ok(seq.fire(6) == nil and seq.step == fired,
    "a beat off the step grid (a sync left from another step length) is not a step")
  local last = CTX.last_input
  CTX.frame = CTX.frame + 100
  seq.fire(8)
  ok(CTX.last_input == last, "the sequencer is not a hand: the idle dim still comes")
  ok(seq.VOICE_ID < 1000 and seq.VOICE_ID > 8 or seq.VOICE_ID >= 3200,
    "its voice id is clear of the typing keyboard's 3000+ and every other range")
  seq.fire(4.2)
  ok(seq.step == 1, "...but a boundary woken a little late still plays")
  local c0 = cancelled
  params:set("step_div", 6)
  ok(cancelled == c0 + 1 and seq.running(),
    "a new step length restarts the clock on it at once")
  params:set("step_div", 2)
  params:set("step_chance", 0)
  local n = #ons
  seq.fire(8)
  ok(#ons == n and CTX.pad_held[seq.VOICE_ID] == nil, "chance 0 plays nothing, and releases")
  params:set("step_chance", 1)
  params:set("stop_all", 1)
  seq.fire(12)
  ok(#ons == n and CTX.pad_held[seq.VOICE_ID] == nil, "under a STOP it plays nothing")
  params:set("stop_all", 0)
  CTX.wave_any = false
  seq.fire(12)
  ok(#ons == n, "an empty take plays nothing")
  CTX.wave_any = true
  seq.fire(0)
  params:set("step_run", 0)
  ok(not seq.running() and cancelled >= 1 and CTX.pad_held[seq.VOICE_ID] == nil,
    "stopped, the clock is cancelled and the voice released")
  -- the grid's PADS workspace runs it: x3 run, x5/x6 fewer and more hits
  local g = _h.grid
  T.goto_page("PADS")
  params:set("step_fill", 4)
  g.key(3, 6, 1); g.key(3, 6, 0)
  ok(params:get("step_run") == 1 and seq.running(), "grid PADS row 6 x3 runs the sequencer")
  g.key(6, 6, 1); g.key(6, 6, 0)
  ok(params:get("step_fill") == 5, "...x6 adds a hit")
  g.key(5, 6, 1); g.key(5, 6, 0); g.key(5, 6, 1); g.key(5, 6, 0)
  ok(params:get("step_fill") == 3, "...x5 takes one away")
  g.key(3, 6, 1); g.key(3, 6, 0)
  ok(params:get("step_run") == 0 and not seq.running(), "...and x3 again stops it")
  params:set("step_fill", 4)
  -- the step gate's PARAMS text (a global `floor` threw below 100%)
  params:set("step_gate", 0.5)
  local okfmt, txt = pcall(function() return params:string("step_gate") end)
  ok(okfmt and txt == "50%", "step gate reads 50% in PARAMS (" .. tostring(txt) .. ")")
  params:set("step_gate", 1)
  clock.run, clock.cancel = real_run, real_cancel
  engine.note_on, engine.note_off = real_on, real_off
end

-- ============================================================================
-- 27 · the modulators
-- ============================================================================
-- An LFO sends the ENGINE the knob's value plus depth x wave, in the param's
-- unmapped space, and never writes the param: the knob stays the knob.
do
  local lfo = CTX.lfo
  local function tindex(id)
    for k, t in ipairs(lfo.TARGETS) do if t == id then return k + 1 end end
  end
  local cs = params:lookup_param("cutoff").controlspec
  local sent = {}
  local real = { cutoff = engine.cutoff, rev_mix = engine.rev_mix, delay_mix = engine.delay_mix }
  engine.cutoff = function(v) sent.cutoff = v end
  engine.rev_mix = function(v) sent.rev_mix = v end
  engine.delay_mix = function(v) sent.delay_mix = v end
  params:set("motion_rec", 0); params:set("motion_play", 0)
  params:set("orbit_on", 0); params:set("scene_morph_amt", 0)
  params:set("cutoff", 2000)
  params:set("lfo1_target", tindex("cutoff"))
  params:set("lfo1_shape", 1); params:set("lfo1_period", 1)
  params:set("lfo1_rate", 1); params:set("lfo1_depth", 0.4)
  local function swing(frames, id)
    local lo, hi = 1e9, -1e9
    for _ = 1, frames do
      _h.run_ticks(1)
      local v = sent[id or "cutoff"]
      lo, hi = math.min(lo, v), math.max(hi, v)
    end
    return lo, hi
  end
  local lo, hi = swing(CTX.FPS)
  local base_raw = cs:unmap(2000)
  near(cs:unmap(hi), base_raw + 0.2, 0.02, "a sine at depth 0.4 swings the sound 0.2 up...")
  near(cs:unmap(lo), base_raw - 0.2, 0.02, "...and 0.2 down, in the knob's own space")
  near(params:get("cutoff"), 2000, 1e-9, "...and the knob itself stays where it was set")
  ok(lfo.active(), "...and says it is moving a knob")
  -- a nudge moves the centre by the nudge, not by the swing
  params:delta("cutoff", 1)
  local nudged = params:get("cutoff")
  ok(math.abs(cs:unmap(nudged) - base_raw) < 0.02,
    "an encoder nudge on a modulated knob moves it one step")
  lo, hi = swing(CTX.FPS)
  near((cs:unmap(lo) + cs:unmap(hi)) / 2, cs:unmap(nudged), 0.03,
    "...and the wave swings around the knob")
  -- a hand between the modulator's frames sends with the swing on it, so
  -- the engine never gets the plain knob value as a spike
  params:set("cutoff", 2500)
  local cs2 = params:lookup_param("cutoff").controlspec
  ok(lfo.swinging("cutoff") and math.abs(sent.cutoff - lfo.swung("cutoff", 2500)) < 1e-9,
    "a hand on a modulated knob sends its value with the swing on it")
  -- the motion looper records the hand, never the modulator
  params:set("motion_rec", 1)
  _h.run_ticks(10)
  ok(CTX.motion.lanes["cutoff"] == nil, "a gesture loop does not record the modulator")
  params:set("cutoff", 3000); _h.run_ticks(2)
  params:set("motion_rec", 0)
  ok(CTX.motion.lanes["cutoff"] ~= nil, "...but it does record a hand on the modulated knob")
  while #CTX.motion.lane_ids > 0 do CTX.motion.clear_lane() end
  -- a scene captures the knob, not the wave
  params:set("cutoff", 4000)
  params:set("scene_slot", 5); T.pulse("scene_capture")
  _h.run_ticks(3)
  near(CTX.scene.slots[5].cutoff, 4000, 1e-9, "a scene captures the knob, not where the wave was")
  params:set("scene_slot", 5); T.pulse("scene_clear")
  -- depth 0 gives the engine the knob's own value back
  params:set("lfo1_depth", 0); _h.run_ticks(1)
  near(sent.cutoff, 4000, 1e-6, "depth 0 gives the engine the knob's own value back")
  ok(not lfo.active(), "...and nothing is modulated")
  -- two modulators on one knob add their swings, and never run away
  params:set("lfo1_depth", 0.2); params:set("lfo1_shape", 3)   -- SQUARE
  params:set("lfo2_target", tindex("cutoff"))
  params:set("lfo2_shape", 3); params:set("lfo2_depth", 0.2); params:set("lfo2_rate", 1)
  lo, hi = swing(3 * CTX.FPS)
  ok(cs:unmap(hi) <= cs:unmap(4000) + 0.2 + 1e-6 and cs:unmap(lo) >= cs:unmap(4000) - 0.2 - 1e-6,
    "two modulators on one knob add up and stay bounded")
  near(params:get("cutoff"), 4000, 1e-9, "...and the knob never moves")
  params:set("lfo2_depth", 0); params:set("lfo2_target", 1)
  -- a FREE wave follows real time: a late frame moves its phase by the time
  -- the frame took (four.lua's frame clock sets ctx.frame_dt), not by 1/FPS
  params:set("lfo1_rate", 1)
  local m1 = lfo.mods[1]
  _h.run_ticks(1)
  local p0 = m1.phase
  CTX.frame_dt = 2 / CTX.FPS
  _h.run_ticks(1)
  CTX.frame_dt = nil
  near((m1.phase - p0) % 1, 2 / CTX.FPS, 1e-9,
    "a FREE modulator steps by the real time since the last frame")
  p0 = m1.phase
  _h.run_ticks(1)
  near((m1.phase - p0) % 1, 1 / CTX.FPS, 1e-9, "...and by 1/FPS where no clock measures it")
  ok(params:lookup_param("lfo1_rate").controlspec.maxval <= CTX.FPS * 0.4 + 1e-9,
    "the LFO rate stops below half the frame rate, so a wave never aliases")
  -- on the clock: the phase is the beat count
  local real_beats = clock.get_beats
  local beats = 0
  clock.get_beats = function() return beats end
  params:set("lfo1_period", 4)                -- 1 BAR
  params:set("lfo1_shape", 4)                 -- RAMP
  params:set("lfo1_depth", 1)
  beats = 0; _h.run_ticks(1)
  near(cs:unmap(sent.cutoff), cs:unmap(4000) - 0.5, 0.01, "a ramp on the bar starts low on the one")
  beats = 2; _h.run_ticks(1)
  near(cs:unmap(sent.cutoff), cs:unmap(4000), 0.01, "...and is at the centre half a bar later")
  clock.get_beats = real_beats
  -- the input envelope: up with the input, and a negative depth ducks
  params:set("lfo1_shape", 6); params:set("lfo1_period", 1)
  params:set("lfo1_depth", 0.5)
  _h.push("amp_in_l", 0); _h.push("amp_in_r", 0); _h.run_ticks(20)
  local quiet = sent.cutoff
  _h.push("amp_in_l", 0.5); _h.push("amp_in_r", 0.5); _h.run_ticks(6)
  ok(sent.cutoff > quiet * 1.5, "ENV opens the sound as the input plays")
  params:set("lfo1_depth", -0.5); _h.run_ticks(2)
  ok(sent.cutoff < 4000, "...and a negative depth ducks it")
  _h.push("amp_in_l", 0); _h.push("amp_in_r", 0)
  -- a mix the engine frees at 0 is held above it while modulated
  params:set("lfo2_target", tindex("rev_mix")); params:set("rev_mix", 0)
  params:set("lfo2_shape", 3); params:set("lfo2_depth", 0.3)
  local zero = false
  for _ = 1, 2 * CTX.FPS do
    _h.run_ticks(1)
    if sent.rev_mix <= 0 then zero = true end
  end
  ok(not zero, "a modulated reverb mix never sends 0, so the reverb is not respawned each cycle")
  -- the delay's feedback hold is not swung across its line with the mix at 0
  local fbsent = {}
  local real_fb = engine.delay_fb
  engine.delay_fb = function(v) fbsent[#fbsent + 1] = v end
  params:set("delay_mix", 0); params:set("delay_fb", 0.95)
  params:set("lfo1_target", tindex("delay_fb")); params:set("lfo1_shape", 3)
  params:set("lfo1_period", 1); params:set("lfo1_rate", 2); params:set("lfo1_depth", 0.8)
  fbsent = {}
  _h.run_ticks(2 * CTX.FPS)
  local below = false
  for _, v in ipairs(fbsent) do if v <= 0.9 then below = true end end
  ok(#fbsent > 0 and not below, "a swung feedback hold stays a hold while the delay mix is 0")
  params:set("lfo1_depth", 0); _h.run_ticks(1)
  engine.delay_fb = real_fb
  params:set("delay_fb", 0.3); params:set("lfo1_target", tindex("cutoff"))
  -- cleanup gives every knob's own value back
  lfo.restore_all()
  near(sent.rev_mix, 0, 1e-9, "restoring gives the engine every knob's own value")
  near(sent.cutoff, 4000, 1e-6, "...both of them")
  params:set("lfo1_depth", 0); params:set("lfo2_depth", 0)
  params:set("lfo1_target", 1); params:set("lfo2_target", 1)
  _h.run_ticks(1)
  engine.cutoff, engine.rev_mix, engine.delay_mix = real.cutoff, real.rev_mix, real.delay_mix
  params:set("cutoff", 20000); params:set("rev_mix", 0)
end

-- ============================================================================
-- 27b · four: modulators per track, COLOR and SPACE per track
-- ============================================================================
-- A modulator on track n moves t<n>_<target>; a knob the tracks share stays
-- the shared knob; a knob track n lacks moves nothing. Every track has its
-- own drive and crush, and its own send into the delay and the reverb.
do
  local lfo = CTX.lfo
  local function tindex(id)
    for k, t in ipairs(lfo.TARGETS) do if t == id then return k + 1 end end
  end
  ok(lfo.N == 4, "there are four modulators")
  local sent = {}
  local names = { "cutoff", "t3_cutoff", "t2_level", "delay_mix" }
  local real = {}
  for _, id in ipairs(names) do
    real[id] = engine[id]
    engine[id] = function(v) sent[id] = v end
  end
  params:set("motion_rec", 0); params:set("motion_play", 0)
  params:set("orbit_on", 0)
  params:set("cutoff", 2000); params:set("t3_cutoff", 2000)
  params:set("lfo3_target", tindex("cutoff")); params:set("lfo3_track", 3)
  params:set("lfo3_shape", 3); params:set("lfo3_period", 1)
  params:set("lfo3_rate", 1); params:set("lfo3_depth", 0.5)
  sent.cutoff = nil
  _h.run_ticks(CTX.FPS)
  ok(sent.t3_cutoff ~= nil and math.abs(sent.t3_cutoff - 2000) > 100,
    "a modulator on track 3 swings track 3's cutoff")
  ok(sent.cutoff == nil, "...and leaves track 1's alone")
  near(params:get("t3_cutoff"), 2000, 1e-9, "...and the knob itself stays put")
  ok(lfo.moves_track(3) and not lfo.moves_track(1), "...and the TRACKS hub can say track 3 moves")
  -- track 1's level is track n's `level`
  params:set("lfo3_target", tindex("grain_level")); params:set("lfo3_track", 2)
  _h.run_ticks(CTX.FPS)
  ok(lfo.target_of(3) == "t2_level" and sent.t2_level ~= nil,
    "the level target on track 2 moves t2_level")
  -- a shared knob is the shared knob on any track
  params:set("lfo3_target", tindex("delay_mix")); params:set("lfo3_track", 4)
  ok(lfo.target_of(3) == "delay_mix", "the delay mix is the same knob on track 4")
  ok(not lfo.moves_track(4), "...and is not one of track 4's own knobs")
  -- a knob the track does not have moves nothing
  params:set("lfo3_target", tindex("wear")); params:set("lfo3_track", 2)
  ok(lfo.target_of(3) == nil, "track 2 has no erosion, so its wear moves nothing")
  params:set("lfo3_depth", 0); params:set("lfo3_target", 1); params:set("lfo3_track", 1)
  _h.run_ticks(1)
  for _, id in ipairs(names) do engine[id] = real[id] end
  params:set("cutoff", 20000); params:set("t3_cutoff", 20000)

  -- MOTION: picking a target puts the modulator on the focused track
  T.goto_page("MOTION")
  params:set("track_sel", 2)
  params:set("mod_focus", 4)                 -- LFO 3
  key(1, 1); enc(3, 3); key(1, 0)
  ok(params:get("lfo3_track") == 2, "a target picked on MOTION lands on the focused track")
  params:set("lfo3_target", 1); params:set("mod_focus", 1)
  params:set("track_sel", 1)

  -- COLOR: the FILTER page's K1 layer is the focused track's drive and crush
  T.goto_page("FILTER")
  CTX.alt = true
  ok(CTX.enc_param(2) == "drive" and CTX.enc_param(3) == "crush",
    "FILTER K1+E2/E3 are track 1's drive and crush")
  params:set("track_sel", 4)
  ok(CTX.enc_param(2) == "t4_drive" and CTX.enc_param(3) == "t4_crush",
    "...and track 4's on track 4")
  CTX.alt = false
  params:set("track_sel", 1)
  -- dry/wet moved to MIX's K1+E3
  T.goto_page("MIX")
  CTX.alt = true
  ok(CTX.enc_param(3) == "dry_wet", "dry/wet is on MIX K1+E3")
  CTX.alt = false
  -- DRY clears every track's colour
  params:set("crush", 0.5); params:set("t3_drive", 0.4); params:set("t2_crush", 0.3)
  CTX.fx_dry()
  ok(params:get("crush") == 0 and params:get("t3_drive") == 0 and params:get("t2_crush") == 0,
    "DRY clears every track's drive and crush")
  CTX.throws_forget()

  -- THE EFFECT: its own page for the focused track. E2 and E3 are the two
  -- knobs, K1 held turns the second slot's; K3 steps the type and skips OFF; K2 is ON
  -- under the punch law and remembers the type; DRY switches every slot off.
  T.goto_page("EFFECT")
  ok(CTX.enc_param(2) == "effect_amt" and CTX.enc_param(3) == "effect_rate",
    "EFFECT E2/E3 are track 1's effect amount and rate")
  CTX.alt = true
  ok(CTX.enc_param(2) == "effect2_amt" and CTX.enc_param(3) == "effect2_rate",
    "...and K1 held turns the SECOND slot's amount and rate")
  CTX.alt = false
  params:set("effect2", 4); params:set("t3_effect2", 5)
  ok(params:get("effect") == 1, "the effect starts OFF")
  key(3, 1); key(3, 0)
  ok(params:get("effect") == 2, "EFFECT K3 steps OFF to CHORUS")
  for _ = 1, 4 do key(3, 1); key(3, 0) end
  ok(params:get("effect") == 6, "...and on to RING")
  key(3, 1); key(3, 0)
  ok(params:get("effect") == 7, "...and to ECHO, the last type")
  key(3, 1); key(3, 0)
  ok(params:get("effect") == 2, "...and wraps to CHORUS, not through OFF")
  params:set("effect", 4)
  key(2, 1); key(2, 0)
  ok(params:get("effect") == 1, "EFFECT K2 switches the effect off")
  key(2, 1); key(2, 0)
  ok(params:get("effect") == 4, "...and on again brings back the effect it had")
  params:set("track_sel", 3)
  ok(CTX.enc_param(2) == "t3_effect_amt" and CTX.enc_param(3) == "t3_effect_rate",
    "on track 3 the knobs are track 3's")
  key(3, 1); key(3, 0)
  ok(params:get("t3_effect") == 2 and params:get("effect") == 4,
    "...and K3 steps track 3's effect, not track 1's")
  CTX.fx_dry()
  ok(params:get("effect") == 1 and params:get("t3_effect") == 1, "DRY switches every effect off")
  ok(params:get("effect2") == 1 and params:get("t3_effect2") == 1,
    "...and the second slot of every track")
  CTX.throws_forget()
  params:set("track_sel", 1)

  -- SPACE: the FX sends are on the routing grid, closed by default
  for n = 1, 4 do
    local d = n == 1 and "fx_dly" or ("t" .. n .. "_fx_dly")
    local r = n == 1 and "fx_rev" or ("t" .. n .. "_fx_rev")
    ok(params:get(d) == 0 and params:get(r) == 0,
      "track " .. n .. " sends nothing to the delay and reverb by default")
  end
  T.goto_page("TRACKS")
  params:set("track_sel", 2)
  CTX.alt = true
  local seen = {}
  for _ = 1, 8 do enc(2, 1); seen[CTX.route_cur().id] = true end
  ok(seen.t2_fx_dly and seen.t2_fx_rev and seen.send_2_4,
    "K1+E2 on TRACKS walks track 2's sends and its two FX sends")
  ok(CTX.route_cur().id == "t2_fx_rev", "...and stops at the reverb, the row's end")
  ok(CTX.enc_target("@route_amt") == "t2_fx_rev", "...and K1+E3 sets that send")
  enc(3, -5)
  ok(params:get("t2_fx_rev") < 1, "...which turns track 2's reverb send down")
  params:set("t2_fx_rev", 1)
  CTX.alt = false
  params:set("track_sel", 1); params:set("route_sel", 1)
end

-- ============================================================================
-- 28 · the window locked to the clock
-- ============================================================================
-- With win_beats other than FREE the window's end is put at the start plus
-- that many beats: when it is set, when the start moves on its own, when a
-- pass stops and when the tempo moves. A write that moves the end is left.
do
  local real_tempo = clock.get_tempo
  local tempo = 120
  clock.get_tempo = function() return tempo end
  params:set("motion_rec", 0); params:set("motion_play", 0)
  params:set("orbit_on", 0); params:set("scene_morph_amt", 0)
  local B = CTX.BUF_SECS
  params:set("pos_start", 0.2); params:set("pos_end", 0.6)
  params:set("win_beats", 4)                  -- 1 BAR
  near(params:get("pos_end"), 0.2 + 2 / B, 1e-6, "a bar at 120 is a two-second window")
  params:set("pos_start", 0.21); _h.run_ticks(1)
  near(params:get("pos_end"), 0.21 + 2 / B, 1e-6, "moving the start slides the whole window")
  -- a start that jumps past the end never leaves the pair crossed
  local crossed = false
  local real_set = params.set
  params.set = function(self, id, v, ...)
    real_set(self, id, v, ...)
    if id == "pos_start" and params:get("pos_start") > params:get("pos_end") then crossed = true end
  end
  params:set("pos_start", 0.5)
  params.set = real_set
  ok(not crossed or params:get("pos_end") > params:get("pos_start"),
    "a start that jumps past the end takes the end with it at once")
  near(params:get("pos_end"), 0.5 + 2 / B, 1e-6, "...a bar from the new start")
  _h.run_ticks(1)
  -- a write that moves the end is left
  params:set("pos_end", 0.9); _h.run_ticks(3)
  near(params:get("pos_end"), 0.9, 1e-9, "a hand on the end is left where it put it")
  -- TAKE SNAP opens the window and a second SNAP goes back
  params:set("pos_end", 0.5 + 2 / B); _h.run_ticks(1)
  T.goto_page("TAKE")
  key(3, 1); key(3, 0); _h.run_ticks(3)
  near(params:get("pos_end") - params:get("pos_start"), 1, 1e-6, "SNAP opens the locked window")
  key(3, 1); key(3, 0); _h.run_ticks(3)
  near(params:get("pos_start"), 0.5, 1e-6, "...and a second SNAP goes back to it")
  near(params:get("pos_end"), 0.5 + 2 / B, 1e-6, "...the whole of it")
  -- a tempo move re-times it, clock jitter does not
  tempo = 60; _h.run_ticks(1)
  near(params:get("pos_end"), 0.5 + 4 / B, 1e-6, "a tempo change re-times it")
  params:set("pos_end", 0.7); _h.run_ticks(1)
  tempo = 60.1; _h.run_ticks(1)
  near(params:get("pos_end"), 0.7, 1e-9, "...but clock jitter does not write")
  -- the morph never fights it: a sweep toward a scene with another end
  params:set("pos_end", 0.5 + 4 / B); _h.run_ticks(1)
  params:set("win_beats", 1)
  params:set("pos_end", 0.8); params:set("scene_slot", 6); T.pulse("scene_capture")
  params:set("pos_end", 0.5 + 4 / B)
  params:set("win_beats", 4)
  -- every write of the end is logged: the old lock pulled it back between
  -- the morph's writes, every frame
  local flips, last = 0, nil
  local real_set2 = params.set
  params.set = function(self, id, v, ...)
    real_set2(self, id, v, ...)
    if id == "pos_end" then
      local e = params:get("pos_end")
      if last and e < last - 1e-9 then flips = flips + 1 end
      last = e
    end
  end
  for k = 1, 14 do
    params:set("scene_morph_amt", k / 20); _h.run_ticks(1)
  end
  params.set = real_set2
  ok(flips == 0, "a morph on the end moves it one way, without the lock pulling it back")
  ok(math.floor(params:get("win_beats") + 0.5) == 4, "...and the morph does not flip the lock itself")
  params:set("scene_morph_amt", 0); _h.run_ticks(2)
  params:set("scene_slot", 6); T.pulse("scene_clear")
  params:set("motion_rec", 1)
  tempo = 90; _h.run_ticks(2)
  params:set("motion_rec", 0)
  ok(CTX.motion.lanes["pos_end"] == nil, "a gesture loop does not record the clock's writes")
  params:set("pos_start", 0.99); _h.run_ticks(1)
  near(params:get("pos_end"), 1, 1e-9, "a start too late ends the window at the buffer's end")
  params:set("win_beats", 1)
  params:set("pos_start", 0.1); params:set("pos_end", 0.7); _h.run_ticks(1)
  near(params:get("pos_end"), 0.7, 1e-9, "FREE leaves the window alone")
  params:set("pos_start", 0); params:set("pos_end", 1)
  clock.get_tempo = real_tempo
end

-- ============================================================================
-- 29 · the take undo
-- ============================================================================
-- After every finished change the take is dumped as undo-cur and the one
-- before becomes undo-prev. UNDO loads undo-prev and swaps the two.
do
  local label = "?"
  local writes, reads, clears = 0, {}, 0
  local real_w, real_r, real_c = engine.write_take, engine.read_take, engine.clear
  -- the engine as it is: a write is QUEUED (the file appears later than the
  -- Lua turn that asked for it), and the server runs its commands in order,
  -- so a read runs after every write queued before it
  local queue = {}
  local function flush()
    for _, w in ipairs(queue) do
      for _, side in ipairs({ "_L", "_R" }) do
        local f = io.open(w[1] .. side .. ".wav", "w"); f:write(w[2]); f:close()
      end
    end
    queue = {}
  end
  engine.write_take = function(stem)
    writes = writes + 1
    queue[#queue + 1] = { stem, label }
  end
  engine.read_take = function(stem)
    flush()
    local f = io.open(stem .. "_L.wav"); reads[#reads + 1] = f and f:read("a"); if f then f:close() end
  end
  engine.clear = function() clears = clears + 1 end
  params:set("rec", 0); params:set("regen", 0); params:set("erode", 0)
  params:set("win_beats", 1)
  CTX.undo_forget()
  CTX.wave_any = true
  local function state(name, lo, hi)
    label = name
    params:set("pos_start", lo); params:set("pos_end", hi)
    CTX.take_len = 0.002
    CTX.undo_mark()
  end
  CTX.take_undo()
  ok(#reads == 0, "with no change behind it, UNDO does nothing")
  state("A", 0.1, 0.2)
  ok(writes == 1, "a finished take is dumped for the undo")
  state("B", 0.3, 0.4)
  CTX.take_undo()
  ok(reads[#reads] == "A", "UNDO loads the take before the last change")
  near(params:get("pos_start"), 0.1, 1e-9, "...with its window")
  near(params:get("pos_end"), 0.2, 1e-9, "...the whole of it")
  CTX.take_undo()
  ok(reads[#reads] == "B", "a second UNDO goes forward again")
  near(params:get("pos_start"), 0.3, 1e-9, "...window and all")
  -- a clear is a state too
  T.pulse("clear_rec")
  ok(not CTX.wave_any, "a clear empties the take")
  CTX.take_undo()
  ok(reads[#reads] == "B" and CTX.wave_any, "UNDO after a clear brings the take back")
  local c0 = clears
  CTX.take_undo()
  ok(clears == c0 + 1 and not CTX.wave_any, "...and a second UNDO clears it again")
  CTX.wave_any = true
  -- an UNDO during regen undoes the regen: one change back, not two
  state("C", 0.5, 0.6)
  state("D", 0.6, 0.7)
  label = "D+regen"
  params:set("regen", 0.4)
  CTX.take_undo()
  ok(params:get("regen") == 0 and reads[#reads] == "D", "UNDO during regen stops it and undoes it")
  CTX.take_undo()
  ok(reads[#reads] == "D+regen", "...and a second UNDO brings the regen back")
  -- two marks in one turn keep each state's audio with its own window: a
  -- clear while armed marks the pass, then the clear
  state("F", 0.2, 0.3)
  _h.push("rec_phase", 0.4); _h.run_ticks(1)
  label = "G"
  params:set("rec", 1); _h.push("rec_phase", 0.5); _h.run_ticks(1)
  T.pulse("clear_rec")
  CTX.take_undo()
  ok(reads[#reads] == "G", "UNDO after a clear made while armed brings back the pass")
  near(params:get("pos_start"), 0.4, 1e-6, "...with that pass's own window")
  -- back to an empty buffer forgets the loaded file, as a clear does
  CTX.take_undo()
  ok(not CTX.wave_any and params:get("sample_file") == "", "UNDO to empty forgets the loaded file too")
  CTX.wave_any = true
  -- a record pass marks a state
  local w0 = writes
  _h.push("rec_phase", 0.1); _h.run_ticks(1)
  params:set("rec", 1); _h.push("rec_phase", 0.2); _h.run_ticks(1); params:set("rec", 0)
  ok(writes == w0 + 1, "a record pass that stops is a finished take")
  -- off, it writes nothing, and never offers a take older than the last
  params:set("undo_keep", 0)
  w0 = writes
  state("E", 0.1, 0.2)
  ok(writes == w0, "with keep an undo off, nothing is dumped")
  local r0 = #reads
  CTX.take_undo()
  ok(#reads == r0, "...and UNDO offers nothing older")
  params:set("undo_keep", 1)
  -- TAKE K3: a tap is SNAP (on the release), a hold to the arc is UNDO
  CTX.undo_forget()
  state("H", 0.1, 0.2)
  state("I", 0.3, 0.4)
  T.goto_page("TAKE")
  _h.run_ticks(1)
  local r1 = #reads
  key(3, 1)
  near(params:get("pos_end") - params:get("pos_start"), 0.1, 1e-9, "a K3 press alone does nothing yet")
  key(3, 0)
  near(params:get("pos_end") - params:get("pos_start"), 1, 1e-9, "a K3 tap is SNAP, on the release")
  ok(CTX.take_msg and CTX.take_msg:find("SNAP"), "...and TAKE says so (" .. tostring(CTX.take_msg) .. ")")
  key(3, 1); key(3, 0)                             -- SNAP back
  near(params:get("pos_start"), 0.3, 1e-9, "...a second tap puts the window back")
  key(3, 1); _h.run_ticks(8); key(3, 0)
  ok(#reads == r1 and math.abs(params:get("pos_start") - 0.3) < 1e-9,
    "released between the tap and the arc: neither SNAP nor UNDO")
  ok(CTX.undo_ready(), "TAKE knows an UNDO is kept")
  key(3, 1); _h.run_ticks(14)
  ok(#reads == r1, "held, UNDO waits for the arc")
  _h.run_ticks(2)
  ok(#reads == r1 + 1 and reads[#reads] == "H", "...and lands AT the arc, held")
  _h.run_ticks(20)
  ok(#reads == r1 + 1, "...once")
  key(3, 0)
  near(params:get("pos_start"), 0.1, 1e-9, "...and the release after it is not a SNAP")
  ok(CTX.take_msg and CTX.take_msg:find("UNDO"), "TAKE says the UNDO happened")
  -- E1 off the page mid-hold aborts it
  key(3, 1); _h.run_ticks(3)
  T.goto_page("VOICE")
  _h.run_ticks(20)
  key(3, 0)
  ok(#reads == r1 + 1, "leaving TAKE mid-hold aborts the UNDO")
  T.goto_page("TAKE")
  -- K1 down mid-hold aborts it too (K1+K3 is the eraser's gesture)
  key(3, 1); _h.run_ticks(3)
  key(1, 1); _h.run_ticks(20); key(1, 0)
  key(3, 0)
  ok(#reads == r1 + 1, "K1 pressed mid-hold aborts the UNDO")
  ok(CTX.hold_frame(3) == nil, "...and no arc is left to draw")
  CTX.undo_forget()
  engine.write_take, engine.read_take, engine.clear = real_w, real_r, real_c
  params:set("pos_start", 0); params:set("pos_end", 1)
end

-- ============================================================================
-- 30 · the modulation out
-- ============================================================================
-- One source (the morph, the envelope, an LFO's wave) out as a MIDI CC, and
-- to crow output 1 as 0..5 V. A CC goes out only when its value changes.
do
  local ccs = {}
  local fake = { device = {}, cc = function(self, n, v, ch) ccs[#ccs + 1] = { n, v, ch } end }
  local real_connect = midi.connect
  midi.connect = function() return fake end
  params:set("orbit_on", 0); params:set("motion_play", 0)
  params:set("out_midi", 1); params:set("out_cc", 74); params:set("out_ch", 2)
  params:set("lfo1_shape", 1)
  params:set("out_src", 2)                    -- MORPH
  params:set("scene_morph_amt", 0.5); _h.run_ticks(1)
  local c = ccs[#ccs]
  ok(c and c[1] == 74 and c[2] == 64 and c[3] == 2, "the morph goes out as a CC on its number and channel")
  local n = #ccs
  _h.run_ticks(3)
  ok(#ccs == n, "...and a still source sends nothing more")
  params:set("scene_morph_amt", 0); _h.run_ticks(1)
  ok(ccs[#ccs][2] == 0, "...and follows the morph home")
  -- a new number resends a still value; a port with no device sends nothing,
  -- and the value goes out once the device is plugged in
  params:set("out_cc", 75); _h.run_ticks(1)
  ok(ccs[#ccs][1] == 75 and ccs[#ccs][2] == 0, "a new CC number gets the still value at once")
  local dev = fake.device
  fake.device = nil
  params:set("scene_morph_amt", 0.25); _h.run_ticks(1)
  n = #ccs
  ok(ccs[#ccs][2] ~= 32, "a port with nothing plugged in sends nothing")
  fake.device = dev; _h.run_ticks(1)
  ok(#ccs == n + 1 and ccs[#ccs][2] == 32, "...and the device plugged in later gets the value")
  params:set("scene_morph_amt", 0); _h.run_ticks(1)
  -- an LFO's wave goes out even when it moves no knob
  params:set("lfo1_target", 1); params:set("lfo1_depth", 0)
  params:set("lfo1_shape", 3); params:set("lfo1_period", 1); params:set("lfo1_rate", 2)
  params:set("out_src", 4)                    -- LFO 1
  local seen = {}
  for _ = 1, CTX.FPS do _h.run_ticks(1); seen[ccs[#ccs][2]] = true end
  ok(seen[0] and seen[127], "an LFO with no knob still drives the CC out, low and high")
  -- crow output 1, 0..5 V, when connected
  local real_crow = crow
  crow = { connected = function() return true end, output = { {} } }
  params:set("out_crow", 1)
  params:set("out_src", 2); params:set("scene_morph_amt", 0.4); _h.run_ticks(1)
  near(crow.output[1].volts, 2, 1e-9, "the source goes to crow output 1 as 0 to 5 volts")
  local up = true
  crow.connected = function() return up end
  up = false; _h.run_ticks(1)
  crow.output[1].volts = 0                    -- a crow that rebooted
  up = true; _h.run_ticks(1)
  near(crow.output[1].volts, 2, 1e-9, "...and a crow that comes back gets the still value again")
  params:set("scene_morph_amt", 0); _h.run_ticks(1)
  crow = real_crow
  params:set("out_crow", 0)
  params:set("out_src", 1)
  n = #ccs
  params:set("scene_morph_amt", 0.7); _h.run_ticks(1)
  ok(#ccs == n, "OFF sends nothing")
  params:set("scene_morph_amt", 0); _h.run_ticks(2)
  params:set("out_midi", 0)
  midi.connect = real_connect
end

-- 30a · the grid's visuals pads (main workspace, row 6: x6 back, x7 next, x8 flash)
do
  local g = _h.grid
  T.goto_page("TAKE")
  params:set("vis_look", 1)
  g.key(7, 6, 1); g.key(7, 6, 0)
  ok(params:get("vis_look") == 2, "grid x7 on row 6 steps the visuals look forward")
  g.key(6, 6, 1); g.key(6, 6, 0); g.key(6, 6, 1); g.key(6, 6, 0)
  ok(params:get("vis_look") == #CTX.osc.LOOKS, "grid x6 steps back and wraps to the last look")
  g.key(8, 6, 1)
  ok(params:get("vis_flash") == 1, "grid x8 on row 6 holds the visuals flash")
  g.key(8, 6, 0)
  ok(params:get("vis_flash") == 0, "releasing x8 ends the flash")
  params:set("vis_look", 1)
end

-- ============================================================================
-- 30b · the visuals link (OSC)
-- ============================================================================
-- The state goes out as one message per field, only on a change, and all of it
-- again on a new address, a switch-on and every two seconds. Nothing is
-- written to the instrument, and every field it names must still exist.
do
  local Mosc = CTX.osc
  params:set("orbit_on", 0); params:set("motion_play", 0)
  local sent = osc.sent
  local function drain() for i = #sent, 1, -1 do sent[i] = nil end end
  local function find(path)
    for i = #sent, 1, -1 do if sent[i].path == path then return sent[i] end end
  end
  drain()
  params:set("osc_on", 0); _h.run_ticks(3)
  ok(#sent == 0, "OSC off sends nothing")
  params:set("osc_host", "10.0.0.7"); params:set("osc_port", 9001)
  params:set("osc_on", 1); _h.run_ticks(1)
  ok(#sent >= #Mosc.FIELDS, "switching on sends every field once")
  ok(sent[1] and sent[1].host == "10.0.0.7" and sent[1].port == 9001,
    "...to the host and port in the params")
  drain(); _h.run_ticks(2)
  -- MIDI for the picture: a note, a CC (not repeated), a program change, the transport
  drain()
  Mosc.midi_in({ type = "note_on", ch = 3, note = 60, vel = 100 }, 1)
  local n = find("/four/ev/note")
  ok(n and n.v == 3 and n.a2 == 60 and n.a3 == 100, "a MIDI note goes out as /four/ev/note ch note vel")
  Mosc.midi_in({ type = "cc", ch = 1, cc = 74, val = 20 }, 1)
  ok(find("/four/ev/cc") ~= nil, "a CC goes out as /four/ev/cc")
  drain()
  Mosc.midi_in({ type = "cc", ch = 1, cc = 74, val = 20 }, 1)
  ok(find("/four/ev/cc") == nil, "...and the same CC value is not sent again")
  Mosc.midi_in({ type = "program_change", ch = 1, val = 17 }, 1)
  ok(find("/four/ev/pc") and find("/four/ev/pc").a2 == 17, "a program change goes out as /four/ev/pc")
  Mosc.midi_in({ type = "stop" }, 1)
  ok(find("/four/ev/run") and find("/four/ev/run").v == 0, "STOP goes out as /four/ev/run 0")
  Mosc.midi_in({ type = "clock" }, 1)
  ok(find("/four/ev/clock") == nil, "the MIDI clock is never forwarded")
  _h.run_ticks(1); drain()
  for i = 1, 60 do Mosc.midi_in({ type = "note_on", ch = 1, note = i, vel = 90 }, 1) end
  ok(#sent <= 24, "no more than 24 events leave in one frame")
  params:set("vis_midi", 0); _h.run_ticks(1); drain()
  Mosc.midi_in({ type = "note_on", ch = 1, note = 61, vel = 90 }, 1)
  ok(#sent == 0, "midi to visuals off sends no event")
  params:set("vis_midi", 1)
  drain(); _h.run_ticks(2)
  local param_msgs = 0
  for _, m in ipairs(sent) do
    local live = m.path:find("/in_") or m.path:find("/out_") or m.path:find("/env")
      or m.path:find("/lfo") or m.path:find("/play") or m.path:find("/rec_phase")
      or m.path:find("/beat")
    if not live then param_msgs = param_msgs + 1 end
  end
  ok(param_msgs == 0, "a still instrument sends no param field again (got " .. param_msgs .. ")")
  params:set("cutoff", 20000); _h.run_ticks(1); drain()
  params:set("cutoff", 200); _h.run_ticks(1)
  local m = find("/four/cutoff")
  ok(m and m.v > 0 and m.v < 1, "a moved knob sends its field, normalised 0..1 (got " .. tostring(m and m.v) .. ")")
  params:set("cutoff", 20000); _h.run_ticks(1)
  m = find("/four/cutoff")
  near(m and m.v or -1, 1, 1e-6, "...and the top of the knob is 1")
  drain()
  params:set("mode", params:get("mode") == 2 and 3 or 2); _h.run_ticks(1)
  m = find("/four/mode")
  ok(m and m.v == params:get("mode"), "an option goes out as its number")
  drain()
  params:set("osc_port", 9002); _h.run_ticks(1)
  ok(#sent >= #Mosc.FIELDS and sent[1].port == 9002, "a new port resends every field to it")
  drain()
  _h.run_ticks(CTX.FPS * 2)
  ok(find("/four/size") ~= nil, "every two seconds the whole state goes out again")
  -- a send that fails is counted, never raised
  local real_send = osc.send
  osc.send = function() error("no route") end
  params:set("size", 0.2); params:set("size", 0.7)
  local okr = pcall(_h.run_ticks, 2)
  ok(okr and Mosc.errors > 0, "a failing send is counted and the frame goes on")
  osc.send = real_send
  -- every field names a real param
  for _, f in ipairs(Mosc.FIELDS) do
    ok(f.read or params.lookup[f.id], "OSC field " .. f.key .. " names a real param (" .. tostring(f.id) .. ")")
  end
  -- the bridge's own list of fields is the same list
  local fh = io.open("visuals/fields.json")
  if fh then
    local txt = fh:read("a"); fh:close()
    for _, f in ipairs(Mosc.FIELDS) do
      ok(txt:find('"' .. f.key .. '"', 1, true), "visuals/fields.json lists " .. f.key)
    end
  else
    ok(false, "visuals/fields.json is missing")
  end
  params:set("osc_on", 0)
  drain()
end

-- ============================================================================
-- 31 · the beat repeat
-- ============================================================================
-- Held, it waits for the next division of the clock, then the engine loops
-- that much of the output. The engine cannot run here; this pins what Lua
-- sends it and when.
do
  local sent = {}
  local real_br, real_run, real_cancel = engine.beat_repeat, clock.run, clock.cancel
  local real_sync, real_tempo = clock.sync, clock.get_tempo
  engine.beat_repeat = function(len) sent[#sent + 1] = len end
  local jobs, cancelled = {}, 0
  clock.run = function(fn) jobs[#jobs + 1] = fn; return fn end
  clock.cancel = function(co)
    cancelled = cancelled + 1
    for k = #jobs, 1, -1 do if jobs[k] == co then table.remove(jobs, k) end end
  end
  clock.sync = function() end
  clock.get_tempo = function() return 120 end
  params:set("stop_all", 0)
  params:set("repeat_div", 3)                 -- 1/8
  params:set("beat_repeat", 1)
  ok(#sent == 0 and #jobs == 1, "a press waits for the next division before it repeats")
  T.finish(table.remove(jobs, 1))
  near(sent[#sent], 0.25, 1e-9, "...then loops an eighth: a quarter second at 120")
  params:set("repeat_div", 4)
  near(sent[#sent], 0.125, 1e-9, "a shorter division while it holds re-captures at once (a roll)")
  params:set("beat_repeat", 0)
  ok(sent[#sent] == 0, "letting go releases it")
  -- let go before the division comes: nothing ever repeats, and the wait is
  -- not cancelled under the sync (the norns clock race)
  local n = #sent
  local c0 = cancelled
  params:set("beat_repeat", 1)
  params:set("beat_repeat", 0)
  ok(cancelled == c0, "a press let go before its beat does not cancel the waiting clock")
  T.finish(table.remove(jobs, 1))
  ok(#sent == n, "...and repeats nothing when the beat comes")
  -- two presses before one beat: one repeat, not two
  params:set("beat_repeat", 1); params:set("beat_repeat", 0); params:set("beat_repeat", 1)
  T.finish(table.remove(jobs, 1)); T.finish(table.remove(jobs, 1))
  ok(#sent == n + 1, "two presses before one beat repeat once")
  params:set("beat_repeat", 0)
  n = #sent
  -- a STOP releases it, and a press under STOP does nothing
  params:set("beat_repeat", 1); T.finish(table.remove(jobs, 1))
  params:set("stop_all", 1)
  ok(sent[#sent] == 0, "a STOP releases a held repeat")
  params:set("beat_repeat", 0)
  n = #sent
  params:set("beat_repeat", 1)
  ok(#jobs == 0 and #sent == n, "...and a press under STOP does nothing")
  ok(not CTX.repeat_live(), "...and the instrument knows nothing loops")
  params:set("beat_repeat", 0)
  params:set("stop_all", 0)
  -- the division is capped at the engine's 2 second buffer
  clock.get_tempo = function() return 40 end
  params:set("repeat_div", 1)                 -- 1/2 at 40 BPM: 3 seconds
  params:set("beat_repeat", 1); T.finish(table.remove(jobs, 1))
  near(sent[#sent], 2, 1e-9, "a slice longer than the engine's buffer is capped at 2 seconds")
  params:set("beat_repeat", 0)
  -- a PSET saved while it was held loads it let go
  params:set("beat_repeat", 1); T.finish(table.remove(jobs, 1))
  params.action_read("none", false, 98764)
  ok(params:get("beat_repeat") == 0 and sent[#sent] == 0, "a PSET saved while it held loads it let go")
  params:set("repeat_div", 3)
  -- the grid's main row 6: hold a pad to repeat at its division, slide to
  -- another for a roll, and the last pad up ends it
  local g = _h.grid
  T.goto_page("TAKE")
  g.key(3, 6, 1)
  ok(params:get("beat_repeat") == 1 and params:get("repeat_div") == 3,
    "grid row 6 x3 holds a repeat at 1/8")
  T.finish(table.remove(jobs, 1))
  g.key(4, 6, 1)
  ok(params:get("repeat_div") == 4, "...a second pad while held rolls to 1/16")
  g.key(4, 6, 0)
  ok(params:get("beat_repeat") == 1 and params:get("repeat_div") == 3,
    "...letting it go returns to the pad still held")
  g.key(3, 6, 0)
  ok(params:get("beat_repeat") == 0, "...and the last pad up ends it")
  -- a footswitch hold is not the grid's to end
  params:set("beat_repeat", 1)
  T.finish(table.remove(jobs, 1))
  g.key(5, 6, 1); g.key(5, 6, 0)
  ok(params:get("beat_repeat") == 1 and params:get("repeat_div") == 5,
    "a pad under a footswitch hold rolls the division and leaves the hold")
  params:set("beat_repeat", 0)
  -- the release belongs to the surface that took the press
  g.key(2, 6, 1)
  T.goto_page("PADS")
  g.key(2, 6, 0)
  ok(params:get("beat_repeat") == 0, "a pad let go on another page still ends its repeat")
  -- the grid unplugged mid-hold: its release never comes, so the repeat
  -- it started ends and the held pad is forgotten
  local Mg
  for i = 1, 255 do
    local nm, v = debug.getupvalue(cleanup, i)
    if nm == nil then break end
    if nm == "Mgrid" then Mg = v end
  end
  T.goto_page("TAKE")
  g.key(2, 6, 1)
  Mg.repeat_drop()
  ok(params:get("beat_repeat") == 0, "a grid that leaves mid-hold ends the repeat it started")
  g.key(4, 6, 1); g.key(4, 6, 0)
  ok(params:get("beat_repeat") == 0, "...and a later pad is not held up by the lost one")
  while #jobs > 0 do T.finish(table.remove(jobs, 1)) end
  params:set("repeat_div", 3)
  engine.beat_repeat, clock.run, clock.cancel = real_br, real_run, real_cancel
  clock.sync, clock.get_tempo = real_sync, real_tempo
end

-- ============================================================================
-- 32 · MOTION hosts the modulators
-- ============================================================================
-- E2 walks the lanes and then the four modulator rows; a modulator row takes
-- E3 (depth), K1+E2 (period) and K1+E3 (target). The eraser lets the
-- selected modulator go and leaves the lanes.
do
  T.goto_page("MOTION")
  params:set("mod_focus", 1); params:set("motion_lane", 0)
  local n = #CTX.motion.lane_ids
  for _ = 1, n do enc(2, 1) end
  ok(params:get("mod_focus") == 1 and params:get("motion_lane") == n,
    "E2 walks the lanes first (" .. n .. " of them)")
  enc(2, 1)
  ok(params:get("mod_focus") == 2, "...then LFO 1")
  enc(2, 1)
  ok(params:get("mod_focus") == 3, "...then LFO 2")
  enc(2, 1); enc(2, 1)
  ok(params:get("mod_focus") == 5, "...then LFO 3 and LFO 4")
  enc(2, 5)
  ok(params:get("mod_focus") == 5, "...and stops there")
  for _ = 1, 3 do enc(2, -1) end
  ok(params:get("mod_focus") == 2, "back down to LFO 1")
  enc(2, -1)
  ok(params:get("mod_focus") == 1 and params:get("motion_lane") == n,
    "...and back onto the last lane")
  enc(2, 1)                                   -- LFO 1
  ok(CTX.enc_param(2) == "@mo_sel" and CTX.enc_param(3) == "lfo1_depth",
    "with LFO 1 selected, E3 is its depth")
  local d0, md0, ml0 = params:get("lfo1_depth"), params:get("motion_depth"), params:get("motion_len")
  enc(3, 5)
  ok(params:get("lfo1_depth") > d0 and params:get("motion_depth") == md0,
    "...E3 moves the LFO's depth, not the lanes'")
  key(1, 1)
  local p0, t0 = params:get("lfo1_period"), params:get("lfo1_target")
  enc(2, 1)
  ok(params:get("lfo1_period") == p0 + 1 and params:get("motion_len") == ml0,
    "...K1+E2 its period, not the loop length")
  enc(3, 2)
  ok(params:get("lfo1_target") == t0 + 2, "...K1+E3 its target")
  key(1, 0)
  ok(params:get("mod_focus") == 2, "K1 held, E2 did not move the selection")
  -- the eraser lets it go and leaves the lanes alone
  local lanes = #CTX.motion.lane_ids
  key(1, 1); key(3, 1); _h.run_ticks(20); key(3, 0); key(1, 0)
  ok(params:get("lfo1_depth") == 0 and params:get("lfo1_target") == 1,
    "K1+K3 held on a modulator row lets it go (OFF, depth 0)")
  ok(#CTX.motion.lane_ids == lanes, "...and clears no lane")
  -- the footer reads the selection at rest
  CTX.alt = false
  ok(CTX.enc_target("@mo_sel") == "mod_focus", "the footer reads the selection as the focus")
  params:set("mod_focus", 1); params:set("lfo1_period", 1)
  ok(CTX.enc_param(3) == "motion_depth", "with the lanes selected, E3 is the lanes' depth again")
end

-- ============================================================================
-- four · the track switch: K3 held on VOICE or FILTER flips the track
-- ============================================================================
do
  local Mp
  for i = 1, 255 do
    local n, v = debug.getupvalue(redraw, i)
    if n == nil then break end
    if n == "Mpages" then Mp = v end
  end
  CTX.alt = false
  params:set("track_sel", 1)
  params:set("mode", 2)                      -- track 1 GRAIN
  params:set("t2_mode", 1)
  T.goto_page("VOICE")
  -- a tap is still MODE, on track 1
  key(3, 1); _h.run_ticks(1); key(3, 0)
  ok(params:get("mode") == 3 and params:get("t2_mode") == 1,
    "VOICE K3 tapped cycles track 1's mode, not track 2's")
  -- a hold to the arc switches the track and keeps the mode
  key(3, 1); _h.run_ticks(20); key(3, 0)
  ok(params:get("track_sel") == 2 and params:get("mode") == 3,
    "VOICE K3 held to the arc switches to track 2 and changes no mode")
  ok(Mp and Mp.page_title() == "VOICE" and CTX.tsel() == 2, "...and the title reads VOICE 2")
  -- on track 2 the tap cycles track 2's mode: OFF lands on PLAY
  key(3, 1); _h.run_ticks(1); key(3, 0)
  ok(params:get("t2_mode") == 5 and params:get("mode") == 3,
    "on track 2 the tap cycles track 2's mode (OFF to PLAY)")
  -- PLAY face: E2/E3 are track 2's scan and pitch, and K1 keeps them (no erosion)
  ok(CTX.enc_param(2) == "t2_scan" and CTX.enc_param(3) == "t2_pitch",
    "track 2's PLAY face is its own scan and pitch")
  CTX.alt = true
  ok(CTX.enc_param(2) == "t2_scan" and CTX.enc_param(3) == "t2_pitch",
    "...and K1 keeps them: track 2 has no erosion")
  CTX.alt = false
  params:set("t2_mode", 2)                   -- GRAIN
  local s0, ts0 = params:get("size"), params:get("t2_size")
  enc(2, 5)
  ok(params:get("t2_size") > ts0 and params:get("size") == s0,
    "track 2's GRAIN face moves t2_size, not track 1's size")
  ok(CTX.key_def(2).label == "FRZ", "K2 on track 2 is its FRZ")
  key(2, 1); key(2, 0)
  ok(params:get("t2_pv_freeze") == 1 and params:get("pv_freeze") == 0,
    "...and it holds track 2's freeze only")
  key(2, 1); key(2, 0)
  -- FILTER follows the same track
  T.goto_page("FILTER")
  ok(Mp.page_title() == "FILTER" and CTX.tsel() == 2, "FILTER on track 2 reads FILTER 2")
  ok(CTX.enc_param(2) == "t2_cutoff" and CTX.enc_param(3) == "t2_resonance",
    "FILTER's E2/E3 are track 2's cutoff and resonance")
  CTX.alt = true
  ok(CTX.enc_param(2) == "t2_drive" and CTX.enc_param(3) == "t2_crush",
    "...and K1 reaches track 2's own COLOR: its drive and crush")
  CTX.alt = false
  local ft0 = params:get("filt_type")
  key(3, 1); _h.run_ticks(1); key(3, 0)
  ok(params:get("t2_filt_type") == 2 and params:get("filt_type") == ft0,
    "FILTER K3 tapped on track 2 cycles track 2's type")
  params:set("t2_filt_type", 1)              -- LP: open means 20 kHz
  params:set("cutoff", 2000); params:set("t2_cutoff", 500)
  key(2, 1); key(2, 0)                       -- OPEN latched on track 2
  ok(params:get("t2_cutoff") == 20000 and params:get("cutoff") == 2000,
    "OPEN on track 2 opens track 2's filter only")
  key(2, 1); key(2, 0)
  ok(params:get("t2_cutoff") == 500, "...and a second tap puts it back")
  -- hold again: on to track 3, then 4, then round to track 1
  key(3, 1); _h.run_ticks(20); key(3, 0)
  ok(params:get("track_sel") == 3 and Mp.page_title() == "FILTER" and CTX.tsel() == 3,
    "FILTER K3 held again steps on to track 3")
  ok(CTX.enc_param(2) == "t3_cutoff", "...and the knobs are track 3's")
  key(3, 1); _h.run_ticks(20); key(3, 0)
  ok(params:get("track_sel") == 4 and CTX.enc_param(3) == "t4_resonance",
    "...then track 4")
  key(3, 1); _h.run_ticks(20); key(3, 0)
  ok(params:get("track_sel") == 1 and Mp.page_title() == "FILTER" and CTX.tsel() == 1,
    "...and round to track 1")
  ok(CTX.enc_param(2) == "cutoff", "...with track 1's knobs again")
  -- the track cells in the header: bright while a track sounds, dim when
  -- OFF, a box on the track the page edits, an underline on shared pages
  T.goto_page("TAKE")
  redraw()
  ok(Mp.CELL[2] == "lit", "track 2 playing lights its number in the header")
  ok(Mp.CELL[1] == "box", "TAKE boxes the track it edits")
  params:set("t2_mode", 1)
  redraw()
  ok(Mp.CELL[2] == "dim", "...and OFF dims it")
  T.goto_page("DELAY")
  redraw()
  ok(Mp.CELL[1] == "line", "a shared page (DELAY) only underlines the focus: it edits no track")
  T.goto_page("TAKE")
  -- recording: the focused cell blinks, and TAKE says what it records
  params:set("rec", 1)
  local seen = {}
  for _ = 1, 4 do _h.run_ticks(1); redraw(); seen[Mp.CELL[1]] = true end
  ok(seen.rec, "recording turns the focused track's cell into the REC box")
  params:set("rec", 0)
  _h.run_ticks(1)
  params:set("t2_filt_type", 1); params:set("t2_cutoff", 20000)
  params:set("mode", 5)
end

-- ============================================================================
-- four · the TRACKS hub and the focus
-- ============================================================================
do
  local Mp
  for i = 1, 255 do
    local n, v = debug.getupvalue(redraw, i)
    if n == nil then break end
    if n == "Mpages" then Mp = v end
  end
  CTX.alt = false
  params:set("track_sel", 1)
  params:set("t2_mode", 1); params:set("t3_mode", 1); params:set("t4_mode", 1)
  T.goto_page("TRACKS")
  ok(Mp.page_title() == "TRACKS", "the hub reads TRACKS")
  ok(CTX.enc_param(2) == "track_sel" and CTX.enc_param(3) == "@trk_level",
    "E2 picks the focus, E3 its level")
  ok(CTX.enc_target("@trk_level") == "grain_level", "track 1's level is the engine's grain level")
  enc(2, 1)
  ok(params:get("track_sel") == 2, "E2 moves the focus to track 2")
  ok(CTX.enc_target("@trk_level") == "t2_level", "...and E3 is now track 2's level")
  local l0, g0 = params:get("t2_level"), params:get("grain_level")
  enc(3, -5)
  ok(params:get("t2_level") < l0 and params:get("grain_level") == g0, "E3 turns track 2's level only")
  -- K2 ON and K3 MODE follow the focus
  params:set("pos_start", 0.2); params:set("pos_end", 0.5)
  params:set("t2_pos_start", 0); params:set("t2_pos_end", 1)
  key(2, 1); key(2, 0)
  ok(params:get("t2_mode") == 5 and params:get("mode") ~= 1, "K2 turns the focused track on (PLAY the first time)")
  ok(math.abs(params:get("t2_pos_start") - 0.2) < 1e-9 and math.abs(params:get("t2_pos_end") - 0.5) < 1e-9,
    "...on track 1's window, not the whole empty buffer")
  params:set("pos_start", 0); params:set("pos_end", 1)
  key(3, 1); key(3, 0)
  ok(params:get("t2_mode") == 2, "K3 cycles its mode (PLAY to GRAIN)")
  key(2, 1); key(2, 0)
  ok(params:get("t2_mode") == 1, "K2 again turns it off")
  key(2, 1); key(2, 0)
  ok(params:get("t2_mode") == 2, "...and on brings back GRAIN")
  key(2, 1); _h.run_ticks(10); key(2, 0)
  ok(params:get("t2_mode") == 1, "K2 held plays it only while held")
  redraw()
  -- K1 held: the sends of the focused track
  CTX.alt = true
  ok(CTX.enc_param(2) == "@route_to" and CTX.enc_param(3) == "@route_amt",
    "K1 held, E2 picks where the focus sends, E3 how much")
  ok(CTX.route_cur().from == 2, "the cursor sits in the focused track's row")
  enc(2, 1)
  ok(CTX.route_cur().id == "send_2_3", "K1+E2 steps to track 2 into track 3")
  for _ = 1, 6 do enc(2, 1) end
  ok(CTX.route_cur().id == "t2_fx_rev", "...and stops at the row's end, the reverb send")
  enc(2, -1); enc(2, -1)
  ok(CTX.route_cur().id == "send_2_4", "...two back is track 2 into track 4")
  enc(3, 10)
  ok(params:get("send_2_4") > 0 and params:get("send_2_3") == 0, "K1+E3 sets that send only")
  redraw()
  CTX.alt = false
  params:set("send_2_4", 0)
  -- the focus carries to TAKE, VOICE and FILTER
  T.goto_page("TAKE")
  ok(Mp.page_title() == "TAKE" and CTX.tsel() == 2, "TAKE follows the focus: TAKE 2")
  ok(CTX.enc_param(2) == "t2_pos_start" and CTX.enc_param(3) == "t2_pos_end",
    "...its E2/E3 are track 2's window")
  params:set("t2_pos_start", 0.5); params:set("t2_pos_end", 0.6)
  local a0 = params:get("t2_pos_start")
  enc(2, -1)
  ok(params:get("t2_pos_start") < a0 and a0 - params:get("t2_pos_start") < 0.01,
    "a tight track 2 window moves by a fine step")
  CTX.alt = true
  local p0, q0 = params:get("t2_pos_start"), params:get("t2_pos_end")
  enc(2, 1)
  ok(params:get("t2_pos_start") > p0 and params:get("t2_pos_end") > q0,
    "K1+E2 slides track 2's window, both edges")
  CTX.alt = false
  -- SNAP on track 2: onto track 1's window, and back
  params:set("pos_start", 0.1); params:set("pos_end", 0.4)
  local s0, e0 = params:get("t2_pos_start"), params:get("t2_pos_end")
  key(3, 1); _h.run_ticks(1); key(3, 0)
  ok(math.abs(params:get("t2_pos_start") - 0.1) < 1e-9 and math.abs(params:get("t2_pos_end") - 0.4) < 1e-9,
    "SNAP on TAKE 2 puts track 2's window on track 1's")
  key(3, 1); _h.run_ticks(1); key(3, 0)
  ok(math.abs(params:get("t2_pos_start") - s0) < 1e-9 and math.abs(params:get("t2_pos_end") - e0) < 1e-9,
    "...and a second SNAP puts it back")
  ok(params:get("pos_start") == 0.1, "...track 1's window is untouched")
  redraw()
  T.goto_page("VOICE")
  ok(Mp.page_title() == "VOICE" and CTX.tsel() == 2, "VOICE follows the focus")
  -- back to track 1
  params:set("track_sel", 1)
  params:set("pos_start", 0); params:set("pos_end", 1)
  params:set("t2_pos_start", 0); params:set("t2_pos_end", 1); params:set("t2_level", 1)
  T.goto_page("TAKE")
  ok(Mp.page_title() == "TAKE" and CTX.tsel() == 1 and CTX.enc_param(2) == "pos_start",
    "on track 1 TAKE edits track 1 again")
end

-- ============================================================================
-- four · own material per track: the focus, the saves, ONE-SHOT
-- ============================================================================
do
  local calls, writes = {}, {}
  local saved = { engine.rec_track, engine.buf_track, engine.write_take }
  engine.rec_track = function(i) calls[#calls + 1] = "rec" .. i end
  engine.buf_track = function(i) calls[#calls + 1] = "buf" .. i end
  engine.write_take = function(stem) writes[#writes + 1] = stem end
  params:set("rec", 0)
  params:set("track_sel", 1)
  CTX.wave_any, CTX.take_len = true, 0.5
  params:set("track_sel", 2)
  ok(CTX.focus() == 2, "the focus follows track_sel")
  ok(CTX.wave_any == false and CTX.take_len == 0, "track 2 starts with no material of its own")
  local joined = table.concat(calls, ",")
  ok(joined:find("rec1", 1, true) and joined:find("buf1", 1, true),
    "the engine records into and works on track 2's buffer")
  CTX.wave_any, CTX.take_len = true, 0.25
  params:set("track_sel", 1)
  ok(CTX.wave_any == true and CTX.take_len == 0.5, "back on track 1, its take is still there")
  params:set("track_sel", 2)
  ok(CTX.take_len == 0.25, "...and track 2's is kept too")
  -- a save writes every track that has material, each under its own name
  CTX.take_pset_write(97)
  local all = table.concat(writes, " ")
  ok(all:find("take-97", 1, true) and all:find("take2-97", 1, true)
    and not all:find("take3-97", 1, true),
    "a PSET save writes track 1 and track 2's takes, not the empty ones (" .. all .. ")")
  -- ONE-SHOT: a pass that fills the 60s ends whole and records on into the next track
  params:set("rec_end", 2)
  params:set("t3_mode", 1)
  CTX.rec_phase = 0.3
  params:set("rec", 1)
  ok(params:get("t2_mode") ~= 1, "recording into an OFF track switches it on (PLAY)")
  CTX.rec_phase = 0.25; _h.run_ticks(1)     -- 0.95 of the way round
  CTX.rec_phase = 0.31; _h.run_ticks(1)     -- ...and past the start: full
  ok(CTX.focus() == 3 and params:get("rec") == 1, "ONE-SHOT: the full track hands on to track 3, still recording")
  ok(params:get("t2_pos_start") == 0 and params:get("t2_pos_end") == 1, "...and track 2's take is the whole 60s")
  ok(params:get("t3_mode") == 5, "...and track 3 plays what it records")
  params:set("rec", 0)
  params:set("rec_end", 1)
  params:set("track_sel", 1)
  params:set("t2_mode", 1); params:set("t3_mode", 1)
  params:set("t3_pos_start", 0); params:set("t3_pos_end", 1)
  engine.rec_track, engine.buf_track, engine.write_take = saved[1], saved[2], saved[3]
end

do
  local Mp
  for i = 1, 255 do
    local n, v = debug.getupvalue(redraw, i)
    if n == nil then break end
    if n == "Mpages" then Mp = v end
  end
  params:set("track_sel", 1)
  T.goto_page("FILTER")
  local m0 = params:get("scene_morph_amt")
  key(1, 1); enc(1, 2); key(1, 0)
  ok(params:get("track_sel") == 3 and params:get("scene_morph_amt") == m0,
    "K1+E1 picks the track from any page (and no longer morphs)")
  ok(Mp.page_title() == "FILTER" and CTX.enc_param(2) == "t3_cutoff",
    "...the page stays, now on track 3's filter")
  redraw()
  params:set("track_sel", 1)
end

-- ============================================================================
-- 33 · the crossfader's two ends: A (LIVE or a slot) and B
-- ============================================================================
-- E2 picks B (scene_slot), K1+E2 picks A (scene_slot_a: 0 = LIVE), E3 fades.
-- A = LIVE is the morph as it always was (the sections above). A = a slot
-- fades between two stored sounds, both ways: 0 is A, 1 is B, for the
-- morph-safe params. A is latched when the fade leaves 0 and kept until it
-- comes home; the orbit, a K2 peek and a GLIDE leave 0 from LIVE.
do
  local pulse, sc = T.pulse, CTX.scene
  local function amt(a) params:set("scene_morph_amt", a); _h.run_ticks(1) end
  local function sound(cut, fb, rev)
    params:set("cutoff", cut); params:set("delay_fb", fb); params:set("rev_mix", rev)
  end
  local function fill(slot, cut, fb, rev)
    sound(cut, fb, rev)
    params:set("scene_slot", slot); pulse("scene_capture")
  end
  local function clear_bank()
    for s = 1, 8 do params:set("scene_slot", s); pulse("scene_clear") end
  end
  params:set("orbit_on", 0)
  params:set("motion_rec", 0); params:set("motion_play", 0)
  params:set("stop_all", 0)
  params:set("scene_morph_amt", 0); _h.run_ticks(2)
  params:set("scene_recall_mode", 1)
  params:set("scene_scope", 1)
  params:set("scene_slot_a", 0)
  clear_bank()
  fill(1, 500, 0.2, 0.1)                     -- A
  fill(2, 8000, 0.8, 0.7)                    -- B
  sound(2000, 0.5, 0.4)                      -- the live sound, neither

  -- (a) the param, its classification and its reach
  local pa = params:lookup_param("scene_slot_a")
  ok(pa and pa.min == 0 and pa.max == 8 and params:get("scene_slot_a") == 0,
    "scene_slot_a is a number 0..8, LIVE (0) by default, so MIDI can map it")
  ok(params:string("scene_slot_a") == "LIVE", "...and PARAMS reads 0 as LIVE")
  local excl = {}
  for _, id in ipairs(sc.SCENE_EXCLUDE) do excl[id] = true end
  ok(excl.scene_slot_a, "...and no scene captures it (a selector, like scene_slot)")
  local mo = {}
  for _, id in ipairs(CTX.motion.MOTION_IDS) do mo[id] = true end
  ok(not mo.scene_slot_a and mo.scene_morph_amt,
    "...and motion records the fader, not the selector")

  -- (b) picking A at rest moves nothing; the first move of E3 brings A in
  params:set("scene_slot", 2)
  params:set("scene_slot_a", 1); _h.run_ticks(2)
  near(params:get("cutoff"), 2000, 1e-6, "picking A while E3 is at 0 leaves the sound alone")
  ok(sc.a_end() == 1, "...and the rail names A 1 as the fader's start")
  amt(0.01)
  ok(params:get("cutoff") < 600 and math.abs(params:get("delay_fb") - 0.206) < 0.01,
    "E3 off 0 with A = slot 1: the sound is A at once (cutoff " .. params:get("cutoff") .. ")")
  amt(0.5)
  near(params:get("cutoff"), 2000, 20, "halfway the cutoff is the geometric mean of A and B")
  near(params:get("delay_fb"), 0.5, 0.01, "...and the feedback the plain mean")
  amt(1)
  near(params:get("cutoff"), 8000, 1e-6, "at 1 the fade is exactly B")
  near(params:get("delay_fb"), 0.8, 1e-9, "...every morph-safe param (feedback)")
  near(params:get("rev_mix"), 0.7, 1e-9, "...(reverb)")
  amt(0.5)
  near(params:get("cutoff"), 2000, 20, "turning back, the fade runs the same line")
  amt(0)
  near(params:get("cutoff"), 500, 1e-6, "back at 0 the fade is exactly A, not the live sound")
  near(params:get("delay_fb"), 0.2, 1e-9, "...(feedback)")
  near(params:get("rev_mix"), 0.1, 1e-9, "...(reverb)")
  _h.run_ticks(3)
  near(params:get("cutoff"), 500, 1e-6, "...and the sound stays on A at rest")
  amt(1); amt(0)
  near(params:get("cutoff"), 500, 1e-6, "a second pass, both ways, lands A again")

  -- (c) A changed mid-fade: no jump, the fade keeps the A it left from until
  -- it comes home, and the next departure takes the new A
  fill(3, 100, 0.05, 0)
  params:set("scene_slot", 2)
  sound(2000, 0.5, 0.4)
  amt(0.5)
  local mid = params:get("cutoff")
  params:set("scene_slot_a", 3); _h.run_ticks(2)
  near(params:get("cutoff"), mid, 1e-6, "changing A mid-fade does not move the sound")
  ok(sc.a_end() == 1, "...the rail keeps the A the fade left from")
  amt(0)
  near(params:get("cutoff"), 500, 1e-6, "...and 0 still lands that A (slot 1)")
  ok(sc.a_end() == 3, "...after which the new A is the fader's start")
  amt(0.01)
  ok(params:get("cutoff") < 110, "...and the next fade leaves from it (cutoff " .. params:get("cutoff") .. ")")
  amt(0)

  -- (d) an empty A is LIVE: the fade leaves from the sound you have
  params:set("scene_slot_a", 5)
  ok(sc.a_end() == 0, "A on an empty slot: the rail says LIVE")
  sound(1000, 0.5, 0.4)
  amt(1)
  near(params:get("cutoff"), 8000, 1e-6, "...the fade still reaches B")
  amt(0)
  near(params:get("cutoff"), 1000, 1e-6, "...and comes home to the live sound")

  -- (e) an empty B: nothing to fade toward; a fade aimed at it mid-way still
  -- comes home, to A
  params:set("scene_slot_a", 1)
  params:set("scene_slot", 6)
  sound(1000, 0.5, 0.4)
  amt(0.5)
  near(params:get("cutoff"), 1000, 1e-6, "B empty: the fader moves nothing")
  amt(0)
  params:set("scene_slot", 2)
  amt(0.5)
  params:set("scene_slot", 6); _h.run_ticks(1)  -- re-aimed at an empty B mid-fade
  amt(0)
  near(params:get("cutoff"), 500, 1e-6, "a fade re-aimed at an empty B still comes home to A")

  -- (f) A == B: the fader holds that scene across its whole travel
  params:set("scene_slot_a", 2); params:set("scene_slot", 2)
  sound(1000, 0.5, 0.4)
  amt(0.3)
  near(params:get("cutoff"), 8000, 1e-6, "A == B: off 0 the sound is that scene")
  amt(0.8)
  near(params:get("cutoff"), 8000, 1e-6, "...wherever the fader is")
  amt(0)
  near(params:get("cutoff"), 8000, 1e-6, "...and at 0 too")

  -- (g) an FX-only A carries only the effects: what it does not hold fades
  -- from the live sound
  params:set("scene_scope", 2)
  sound(300, 0.1, 0); params:set("size", 0.4)
  params:set("scene_slot", 4); pulse("scene_capture")
  params:set("scene_scope", 1)
  sound(8000, 0.8, 0.7); params:set("size", 0.2)
  params:set("scene_slot", 2); pulse("scene_capture")   -- B again, with size 0.2
  sound(2000, 0.5, 0.4); params:set("size", 0.1)
  params:set("scene_slot_a", 4)
  amt(1)
  near(params:get("size"), 0.2, 1e-6, "FX-only A: B's size at 1")
  amt(0)
  near(params:get("cutoff"), 300, 1e-6, "...A's cutoff at 0")
  near(params:get("size"), 0.1, 1e-6, "...and the live size, which A does not carry")

  -- (h) a recall lands B and zeroes the fader; the next move brings A in
  params:set("scene_slot_a", 1); params:set("scene_slot", 2)
  amt(0.5)
  pulse("scene_recall")
  near(params:get("cutoff"), 8000, 1e-6, "a recall mid-fade lands B (K2 RCL, as before)")
  near(params:get("scene_morph_amt"), 0, 1e-9, "...with the fader at 0")
  amt(0.01)
  ok(params:get("cutoff") < 600, "...and the next move leaves from A again")
  amt(0)

  -- (i) a capture mid-fade forgets the sweep; the next move departs from
  -- the same A on the same line, so the sound does not jump
  amt(0.5)
  local before = params:get("cutoff")
  sc.capture(7)                              -- an explicit slot: B stays 2
  amt(0.52)
  local after = params:get("cutoff")
  ok(after > before and after < before * 1.15,
    "a capture mid-fade: the next move continues the line (" .. before .. " -> " .. after .. ")")
  amt(0)
  near(params:get("cutoff"), 500, 1e-6, "...and home is still A")

  -- (j) a chaos throw mid-fade, released: the way back lands with the fader
  -- at 0, and the next move departs from A
  amt(0.5)
  params:set("chaos_throw", 1); params:set("chaos_throw", 0)
  near(params:get("scene_morph_amt"), 0, 1e-9, "chaos released mid-fade: the fader is home")
  amt(0.01)
  ok(params:get("cutoff") < 600, "...and the next move leaves from A")
  amt(0)

  -- (k) the orbit departs from LIVE whatever A says: its legs park and
  -- leave again, and an A slot would pull the sound back at every leg
  sound(3000, 0.5, 0.4)
  params:set("scene_slot", 2)                -- the orbit aims at the others
  params:set("orbit_rate", 60); params:set("orbit_reach", 0.5)
  params:set("orbit_on", 1)
  ok(sc.a_end() == 0, "the orbit runs: the rail says A LIVE")
  _h.run_ticks(30)
  local c = params:get("cutoff")
  ok(c > 600 and c < 3000, "...and its leg leaves from the live sound, not A (" .. c .. ")")
  params:set("orbit_on", 0)
  params:set("orbit_rate", 12)
  params:set("scene_morph_amt", 0); _h.run_ticks(2)
  ok(sc.a_end() == 1, "orbit stopped: A 1 is the fader's start again")

  -- (l) K2 works as it did: a peek from rest borrows B from the live sound
  -- and gives it back; a GLIDE recall crossfades from the live sound
  T.goto_page("SCENE")
  sound(3000, 0.5, 0.4)
  params:set("scene_slot", 2)
  key(2, 1); _h.run_ticks(10)
  near(params:get("cutoff"), 8000, 1e-6, "a held RCL peeks B")
  key(2, 0); _h.run_ticks(8)
  near(params:get("cutoff"), 3000, 1e-6, "...and its release gives back the live sound, not A")
  clock.get_tempo = function() return 120 end
  params:set("scene_recall_mode", 4)         -- GLIDE
  params:set("scene_glide", 2)               -- 1 second at 120 = 15 frames
  pulse("scene_recall")
  _h.run_ticks(7)
  local g = params:get("cutoff")
  ok(g > 3000 and g < 8000, "a GLIDE from rest crossfades from the live sound, not A (" .. g .. ")")
  _h.run_ticks(12)
  near(params:get("cutoff"), 8000, 1e-6, "...and lands B")
  params:set("scene_recall_mode", 1)
  clock.get_tempo = nil

  -- (m) a pset load forgets the fade, like every other landing
  amt(0.5)
  params.action_read("none", false, 98766)
  ok(not sc.engaged and sc.a_end() == 1, "a pset load drops the fade; A stays selected")

  params:set("scene_morph_amt", 0); _h.run_ticks(2)
  params:set("scene_slot_a", 0)
  clear_bank()
  params:set("scene_slot", 1)
  params:set("size", 0.1)
  sound(20000, 0.3, 0)
end

T.report("control harness OK")
