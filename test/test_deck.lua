-- test_deck.lua — offline harness for lib/mdeck.lua, the loop decks.
--
-- The things no eye can check here are geometric and destructive: a deck must
-- read and write ONLY its own slice of the shared softcut buffer, and an erase
-- must not take the tape or the other layer with it. Those are exactly the
-- failures that are silent until you have lost a loop.
--
--   lua test/test_deck.lua        # from the repo root

local T = dofile("test/harness.lua")
local ok, near = T.ok, T.near

-- ---- a softcut that RECORDS what it was told, instead of making sound -------
local calls = {}
local function log(name)
  return function(...) calls[#calls + 1] = { name, ... } end
end
local scstub = setmetatable({}, { __index = function(_, k) return log(k) end })
package.preload.softcut = function() return scstub end

local function last(name, voice)
  for i = #calls, 1, -1 do
    local c = calls[i]
    if c[1] == name and (voice == nil or c[2] == voice) then return c end
  end
end
local function count(name)
  local n = 0
  for _, c in ipairs(calls) do if c[1] == name then n = n + 1 end end
  return n
end

norns = { state = { data = "/tmp/" } }
util = { file_exists = function() return false end }

local P = {}
params = {
  lookup = P,
  get = function(_, id) return P[id] end,
  set = function(_, id, v) P[id] = v end,
}

local Mdeck = dofile("lib/mdeck.lua")
local ctx = {
  pget = function(id, d) if P[id] ~= nil then return P[id] end return d end,
  clamp = function(x, lo, hi) return math.max(lo, math.min(hi, x)) end,
  amp_in = { 0.5, 0.5 }, amp_out = { 0.2, 0.2 },
  -- the shared record-meter law from mangler.lua, over the amps above
  cut_rec_amp = function()
    local cs = P.cut_source or 0
    return 0.5 * (1 - cs) + 0.2 * cs
  end,
  paint_bins = function(bins, lastb, bin, amp) bins[bin] = amp; return bin end,
}
Mdeck.init(ctx)

-- the same layout mangler.lua builds: two decks after the tape's 0-60s
local d1 = Mdeck.new({ id = "lay1", name = "L1", va = 3, vb = 4, from = 120, len = 60 })
local d2 = Mdeck.new({ id = "lay2", name = "L2", va = 5, vb = 6, from = 180, len = 60 })

local function defaults()
  P.out_level = 1; P.stop_all = 0; P.cut_source = 0
  for _, id in ipairs({ "lay1", "lay2" }) do
    P[id .. "_rec"] = 0;   P[id .. "_play"] = 1
    P[id .. "_level"] = 0.8; P[id .. "_rate"] = 1
    P[id .. "_reverse"] = 0; P[id .. "_start"] = 0
    P[id .. "_end"] = 1;     P[id .. "_pre"] = 1
  end
end
defaults()

-- ---- regions -------------------------------------------------------------
-- a deck must live entirely inside its own slice, or it eats a neighbour
ok(d1.from + d1.len <= d2.from, "the decks' regions do not overlap")
ok(d1.from >= 60, "and neither starts inside the tape's 0-60s")
ok(d1.from >= 120, "...or inside 60-120, left clear for the chain audition")

calls = {}
Mdeck.update_loop(d1)
local ls, le = last("loop_start", 3), last("loop_end", 3)
near(ls[3], 120, 0.001, "a full loop starts at the deck's own region start")
near(le[3], 180, 0.001, "...and ends at its end")

P.lay1_start = 0.25; P.lay1_end = 0.5
calls = {}
Mdeck.update_loop(d1)
near(last("loop_start", 3)[3], 135, 0.001, "loop start is a fraction of the REGION")
near(last("loop_end", 3)[3], 150, 0.001, "...and so is the end")
near(last("loop_start", 4)[3], 135, 0.001, "both voices of the pair agree")

-- crossed bounds sort, and never collapse below softcut's own minimum
P.lay1_start = 0.8; P.lay1_end = 0.2
calls = {}
Mdeck.update_loop(d1)
ok(last("loop_end", 3)[3] > last("loop_start", 3)[3], "crossed bounds sort")
P.lay1_start = 0.5; P.lay1_end = 0.5
calls = {}
Mdeck.update_loop(d1)
-- (compared with a tolerance: 150.1 - 150.0 is 0.0999... in binary floating
-- point, which is an artifact of the subtraction, not of what was sent)
near(last("loop_end", 3)[3] - last("loop_start", 3)[3], 0.1, 1e-6,
  "a zero-length loop is floored, not sent to softcut as zero")

-- ...and the floor never pushes past the region's end: at the far right it
-- would otherwise loop (and record) the first 100ms of the NEXT deck's region
P.lay1_start = 1; P.lay1_end = 1
calls = {}
Mdeck.update_loop(d1)
near(last("loop_end", 3)[3], 180, 1e-6,
  "a loop floored at the far right stays inside the region")
near(last("loop_start", 3)[3], 179.9, 1e-6,
  "...by moving the START back instead")
defaults()

-- ---- ERASE is the collision that matters ---------------------------------
-- sc.buffer_clear() would take the tape and the other layer with it
calls = {}
Mdeck.clear(d1)
ok(count("buffer_clear") == 0, "clear NEVER calls the whole-buffer clear")
local cr = last("buffer_clear_region")
ok(cr ~= nil, "clear scopes itself to a region")
cr = cr or { nil, -1, -1 }        -- keep going so a regression REPORTS
near(cr[2], 120, 0.001, "it clears from this deck's region start")
near(cr[3], 60, 0.001, "...for exactly its own length")
ok(d1.any == false, "and the deck reports itself empty afterwards")

-- ---- level folds the master and the global STOP --------------------------
defaults()
calls = {}
Mdeck.update_level(d1)
near(last("level", 3)[3], 0.8, 0.001, "level is the deck's own when nothing else applies")
P.out_level = 0.5
calls = {}; Mdeck.update_level(d1)
near(last("level", 3)[3], 0.4, 0.001, "the master scales it")
P.out_level = 1; P.stop_all = 1
calls = {}; Mdeck.update_level(d1)
near(last("level", 3)[3], 0, 0.001, "STOP silences it — one key, no deck that forgot")
P.stop_all = 0; P.lay1_play = 0
calls = {}; Mdeck.update_level(d1)
near(last("level", 3)[3], 0, 0.001, "and a stopped transport is silent too")
defaults()

-- ---- rate and direction --------------------------------------------------
P.lay1_rate = 0.5
calls = {}; Mdeck.update_rate(d1)
near(last("rate", 3)[3], 0.5, 0.001, "rate reaches the voice")
P.lay1_reverse = 1
calls = {}; Mdeck.update_rate(d1)
near(last("rate", 3)[3], -0.5, 0.001, "reverse negates it, keeping the rate positive")
defaults()

-- ---- the global STOP halts the head, not just the level -------------------
P.stop_all = 1
calls = {}; Mdeck.update_rate(d1)
near(last("rate", 3)[3], 0, 1e-9, "STOP halts a layer head")
P.lay1_rec = 1
calls = {}; Mdeck.update_rec(d1)
near(last("rec_level", 3)[3], 0, 1e-6, "...and gates layer capture while armed")
P.stop_all = 0
calls = {}; Mdeck.update_rate(d1); Mdeck.update_rec(d1)
near(last("rate", 3)[3], 1, 1e-6, "START restores the layer rate")
near(last("rec_level", 3)[3], 1, 1e-6, "...and the armed capture resumes")
defaults()

-- ---- rec and overdub -----------------------------------------------------
P.lay1_rec = 1; P.lay1_pre = 1
calls = {}; Mdeck.update_rec(d1)
near(last("rec", 3)[3], 1, 1e-6, "softcut's rec flag is on, so the write head follows the read head")
near(last("rec_level", 3)[3], 1, 0.001, "arming opens the record level")
near(last("pre_level", 3)[3], 1, 0.001, "pre 1 = OVERDUB: what is there survives")
P.lay1_pre = 0
calls = {}; Mdeck.update_rec(d1)
near(last("pre_level", 3)[3], 0, 0.001, "pre 0 = REPLACE")
P.lay1_rec = 0
calls = {}; Mdeck.update_rec(d1)
near(last("rec_level", 3)[3], 0, 0.001, "disarming closes the head")
near(last("pre_level", 3)[3], 1, 0.001, "...and pre 1 leaves the buffer untouched while the flag stays on")
near(last("rec", 3)[3], 1, 0.001, "the flag stays on, so the write head keeps following")
near(last("recpre_slew_time", 3)[3], 0.005, 1e-6, "a punch ramps, so it prints no step")
calls = {}; Mdeck.settle_rec(d1)
near(last("recpre_slew_time", 3)[3], 0, 1e-6, "the next phase event ends the ramp")
near(last("pre_level", 3)[3], 1, 1e-6, "...and lands pre exactly, so an idle deck cannot drift")
near(last("rec_level", 3)[3], 0, 1e-6, "...and rec exactly")
calls = {}; Mdeck.settle_rec(d1)
ok(last("pre_level", 3) == nil, "a settled deck sends nothing more")
defaults()

-- ---- the phase poll routes by VOICE --------------------------------------
-- one softcut handler serves every deck; a deck must only answer for its own
Mdeck.on_phase(3, 120 + 30)          -- halfway through deck 1's region
near(d1.phase, 0.5, 0.001, "a deck's phase is a fraction of its OWN region")
near(d2.phase, 0, 0.001, "...and the other deck is untouched by it")
Mdeck.on_phase(5, 180 + 15)
near(d2.phase, 0.25, 0.001, "the second deck answers on its own voice")
Mdeck.on_phase(1, 30)                -- the tape's voice: not ours
near(d1.phase, 0.5, 0.001, "the tape's voice moves no layer")

-- recording paints the picture; idle does not
d1.any = false
P.lay1_rec = 0
Mdeck.on_phase(3, 120 + 6)
ok(d1.any == false, "a deck that is not recording paints nothing")
P.lay1_rec = 1
Mdeck.on_phase(3, 120 + 6)
ok(d1.any == true, "a recording deck marks itself as holding audio")
defaults()

-- ---- the pset writes per-deck files ---------------------------------------
d1.any = true; d2.any = false
d1.mat_lo, d1.mat_hi = nil, nil   -- extent unknown: the whole region
calls = {}
Mdeck.pset_write(7)
local w = last("buffer_write_stereo")
ok(w ~= nil and w[2]:find("lay1-7.wav", 1, true) ~= nil,
  "a deck with audio writes its own file")
near(w[3], 120, 0.001, "...from its own region")
near(w[4], 60, 0.001, "...for its own length")
ok(count("buffer_write_stereo") == 1, "an EMPTY deck writes nothing")
-- with its material known, a deck saves only up to the end of it
d1.mat_lo, d1.mat_hi = 0.02, 0.1
calls = {}
Mdeck.pset_write(7)
near(last("buffer_write_stereo")[4], 6.05, 1e-9,
  "a deck holding 6s of material saves 6s (plus the extent's 50ms), not 60")
d1.mat_lo, d1.mat_hi = nil, nil

-- ---- the pset restore repaints the picture --------------------------------
-- lua cannot read the softcut buffer, so a restored loop used to play under a
-- blank strip; a deck now hands the wav it restored FROM to the painter.
do
  local painted = {}
  ctx.wave_from_file = function(path, bins, secs)
    painted[#painted + 1] = { path = path, bins = bins, secs = secs }
  end
  d1.any = false; d2.any = true
  util.file_exists = function(p) return p:find("lay1-9", 1, true) ~= nil end
  ctx.wav_info = function() return 2, 6 end       -- a bounded save: 6 seconds
  calls = {}
  Mdeck.pset_read(9)
  ctx.wav_info = nil
  local cleared, read_at
  for i, c in ipairs(calls) do
    if c[1] == "buffer_clear_region" and c[2] == 120 then cleared = cleared or i end
    if c[1] == "buffer_read_stereo" and c[4] == 120 then read_at = read_at or i end
  end
  ok(cleared and read_at and cleared < read_at,
    "a restore clears the region before reading a save that may be shorter")
  near(d1.mat_hi or -1, 0.1, 1e-9, "...and the material is what the file held")
  ok(#painted == 1, "a deck with a wav asks for exactly ONE repaint")
  local cp = painted[1] or {}
  ok(cp.path ~= nil and cp.path:find("lay1-9.wav", 1, true) ~= nil,
    "...from its own file")
  ok(cp.bins == d1.wave, "...into its own bins")
  near(cp.secs or -1, 60, 0.001, "...spanning its region length")
  ok(d1.any == true, "the restored deck holds audio")
  ok(d2.any == false, "the deck with NO wav is cleared, not repainted")
  util.file_exists = function() return false end
  ctx.wave_from_file = nil
  d1.any = false
  defaults()
end

-- ---- loading a FILE into a deck -------------------------------------------
-- layN_file lands here via ctx.layer_load; the deck must read into ITS region,
-- snap the loop to the file, and feed a mono file to both sides of the pair
do
  ctx.wav_info = function() return 2, 15 end       -- stereo, 15s
  ctx.wave_from_file = function() end
  calls = {}
  Mdeck.load_file(d1, "/tmp/loop.wav")
  local r = last("buffer_read_stereo")
  ok(r ~= nil and r[2] == "/tmp/loop.wav", "a stereo file reads in one stereo read")
  near(r and r[4] or -1, 120, 0.001, "...into this deck's own region")
  near(P.lay1_end or -1, 0.25, 0.001, "the loop snaps to the file's length (15s/60s)")
  ok(d1.any == true, "a load IS material")
  calls = {}
  ctx.wav_info = function() return 1, 60 end       -- mono, full region
  Mdeck.load_file(d2, "/tmp/mono.wav")
  ok(count("buffer_read_mono") == 2, "a mono file is read into BOTH sides of the pair")
  ok(count("buffer_read_stereo") == 0, "...never as a stereo read")
  ctx.wav_info = nil
  ctx.wave_from_file = nil
  d1.any = false; d2.any = false
  defaults()
end

-- ---- the pset restore honours a loaded file --------------------------------
-- no deck wav in the pset, but the file param names one: reload the file
-- rather than clearing (the file action may not have re-fired during
-- params:read if its value did not change across the load). An EMPTY file
-- param still clears: the tape rule, unchanged.
do
  P.lay1_file = "/tmp/bed.wav"
  util.file_exists = function(p) return p == "/tmp/bed.wav" end
  -- the pset restored a CUSTOM loop; the reload must not re-snap it
  P.lay1_start = 0.1; P.lay1_end = 0.3
  ctx.wav_info = function() return 2, 15 end
  calls = {}
  Mdeck.pset_read(3)
  local r = last("buffer_read_stereo")
  ok(r ~= nil and r[2] == "/tmp/bed.wav",
    "a missing deck wav with a named file reloads the file")
  ok(d1.any == true, "...and the deck holds audio")
  near(P.lay1_start, 0.1, 1e-9, "the pset's loop start survives the reload")
  near(P.lay1_end, 0.3, 1e-9, "...and its end (no re-snap over restored params)")
  ctx.wav_info = nil
  P.lay1_file = ""
  calls = {}
  Mdeck.pset_read(3)
  ok(count("buffer_read_stereo") == 0 and last("buffer_clear_region") ~= nil,
    "an empty file param clears the deck as before")
  -- an off-rate file converts in the background through ctx.layer_load, which
  -- clears the deck while it converts (test_control drives that part)
  P.lay1_file = "/tmp/bed.wav"
  P.lay1_start = 0.1; P.lay1_end = 0.3
  local asked
  ctx.layer_load = function(d, path, keep) asked = { d, path, keep } end
  Mdeck.pset_read(3)
  ok(asked and asked[1] == d1 and asked[2] == "/tmp/bed.wav" and asked[3] == true,
    "a named file reloads through layer_load, keeping the loop")
  near(P.lay1_start, 0.1, 1e-9, "...with the pset's loop untouched")
  -- a pset that leaves the loop out (the album set) snaps it: the
  -- same file reloaded must not keep the slice the player left the deck on
  norns.state.shortname = "mangler_test"
  local f = assert(io.open("/tmp/mangler_test-03.pset", "w"))
  f:write('"lay1_file": /tmp/bed.wav\n"lay1_level": 0.8\n')
  f:close()
  asked = nil
  Mdeck.pset_read(3)
  ok(asked and asked[3] == false, "a pset without loop points snaps the loop on reload")
  f = assert(io.open("/tmp/mangler_test-03.pset", "w"))
  f:write('"lay1_file": /tmp/bed.wav\n"lay1_start": 0.1\n"lay1_end": 0.3\n')
  f:close()
  asked = nil
  Mdeck.pset_read(3)
  ok(asked and asked[3] == true, "...and one that stores them keeps them")
  os.remove("/tmp/mangler_test-03.pset")
  norns.state.shortname = nil
  ctx.layer_load = nil
  util.file_exists = function() return false end
  P.lay1_file = nil
  d1.any = false; d2.any = false
  defaults()
end

-- the TAPE deck's restore takes the same path (mtape is the sibling this
-- module deliberately has not absorbed yet — its wiring is asserted here so
-- the two cannot drift apart)
do
  local Mtape = dofile("lib/mtape.lua")
  local painted
  local tctx = {
    pget = ctx.pget,
    repaint_twave = function(path, secs) painted = { path, secs } end,
    clear_twave = function() end,
  }
  Mtape.init(tctx, Mdeck)
  util.file_exists = function(p) return p:find("tape-4", 1, true) ~= nil end
  Mtape.pset_read(4)
  ok(painted ~= nil and painted[1]:find("tape-4.wav", 1, true) ~= nil,
    "the tape restore repaints from its wav")
  near(painted and painted[2] or -1, 60, 0.001, "...over the tape length")
  ok(tctx.twave_any == true, "...and marks the tape as holding audio")
  util.file_exists = function() return false end
end

-- ---- the tape runs on the SAME deck mechanics ------------------------------
-- mtape delegates rate/rec/loop/clear to mdeck through a keymapped descriptor
-- (proven call-for-call identical to the hand-written originals at fold time).
-- what must not regress: the tape's own semantics riding through the shared
-- code — REPLACE by default, freeze holds, the floor stays inside 0-60s.
do
  local Mtape = dofile("lib/mtape.lua")
  Mtape.init({ pget = ctx.pget, clamp = ctx.clamp }, Mdeck)
  P.tape_rate = 0.75; P.tape_reverse = 1
  calls = {}
  Mtape.update_tape_rate()
  near(last("rate", 1)[3], -0.75, 1e-6, "tape reverse negates the rate")
  near(last("rate", 2)[3], -0.75, 1e-6, "...on both voices")
  P.tape_rec = 1; P.tape_freeze = 0; P.tape_pre = 0
  calls = {}
  Mtape.update_tape_rec()
  near(last("rec_level", 1)[3], 1, 1e-6, "arming opens the tape record level")
  near(last("pre_level", 1)[3], 0, 1e-6, "tape default is REPLACE (pre 0), not the layers' overdub")
  P.tape_freeze = 1
  calls = {}
  Mtape.update_tape_rec()
  near(last("rec_level", 1)[3], 0, 1e-6, "freeze stops capture even while armed")
  near(last("pre_level", 1)[3], 1, 1e-6, "...and holds the loop at full regeneration")
  P.tape_freeze = 0; P.tape_rec = 0
  P.loop_start = 1; P.loop_end = 1
  calls = {}
  Mtape.update_tape_loop()
  near(last("loop_end", 1)[3], 60, 1e-6, "the tape's floored loop stays inside 0-60s")
  near(last("loop_start", 1)[3], 59.9, 1e-6, "...by moving the start back")
  P.loop_start = 0.8; P.loop_end = 0.2
  calls = {}
  Mtape.update_tape_loop()
  ok(last("loop_end", 1)[3] > last("loop_start", 1)[3], "crossed tape bounds sort")
  calls = {}
  Mtape.clear_buffer()
  local tc = last("buffer_clear_region")
  near(tc and tc[2] or -1, 0, 1e-6, "tape clear starts at 0")
  near(tc and tc[3] or -1, 60, 1e-6, "...and takes exactly the tape's 60s")
  -- the true STOP reaches the tape through the same delegated law
  P.tape_rate = 1; P.tape_reverse = 0; P.stop_all = 1
  calls = {}
  Mtape.update_tape_rate()
  near(last("rate", 1)[3], 0, 1e-9, "STOP halts the tape head too")
  P.stop_all = 0
  calls = {}
  Mtape.update_tape_rate()
  near(last("rate", 1)[3], 1, 1e-6, "...and START restores its rate")
  P.loop_start = 0; P.loop_end = 1
end

-- ---------------------------------------------------------------------------
-- the LOOP-PEDAL law
-- ---------------------------------------------------------------------------
-- Without this a fresh layer records into the whole 60-second region, so the
-- first thing you play comes back once a minute. That is a deck, not a looper,
-- and it is the gap the snap work closes.
do
  defaults()
  d1.any = false
  P.lay1_start, P.lay1_end = 0.4, 0.55       -- some leftover loop
  d1.phase = 0.10
  Mdeck.arm_loop(d1)
  near(P.lay1_start, 0, 1e-9, "arming an EMPTY deck opens the loop to the region")
  near(P.lay1_end, 1, 1e-9, "...at both ends, so nothing played is cut off")
  d1.phase = 0.30                            -- 12 seconds later, at rate 1
  Mdeck.close_loop(d1)
  near(P.lay1_start, 0.10, 1e-9, "disarming closes the loop where recording began")
  near(P.lay1_end, 0.30, 1e-9, "...and ends it where recording stopped")
  local j = last("position", 3)
  near(j and j[3] or -1, 120 + 0.10 * 60, 1e-6,
    "...and drops the head at the loop start, inside the deck's own region")

  -- a deck that ALREADY holds audio overdubs into the loop it has. That is the
  -- whole difference between defining a loop and adding to one.
  d1.any = true
  P.lay1_start, P.lay1_end = 0.10, 0.30
  d1.phase = 0.15
  Mdeck.arm_loop(d1)
  near(P.lay1_start, 0.10, 1e-9, "arming a deck WITH material leaves its loop alone")
  near(P.lay1_end, 0.30, 1e-9, "...both edges")
  d1.phase = 0.22
  Mdeck.close_loop(d1)
  near(P.lay1_end, 0.30, 1e-9, "...and disarming does not re-cut it")

  -- too short, or the head wrapped past the region end: softcut loops cannot
  -- cross the seam, so keep the whole region rather than snap a wrong slice
  d1.any = false
  P.lay1_start, P.lay1_end = 0, 1
  d1.phase = 0.9
  Mdeck.arm_loop(d1)
  d1.phase = 0.05                            -- wrapped
  Mdeck.close_loop(d1)
  near(P.lay1_start, 0, 1e-9, "a pass that wrapped the region keeps the full loop")
  near(P.lay1_end, 1, 1e-9, "...rather than snapping to a slice that is not it")

  -- the erase disarms on its way past, and must not snap around material it
  -- is about to destroy
  d1.any = false
  d1.phase = 0.2
  Mdeck.arm_loop(d1)
  Mdeck.abort_loop(d1)
  d1.phase = 0.6
  Mdeck.close_loop(d1)
  near(P.lay1_end, 1, 1e-9, "an aborted pass closes nothing")

  -- the quantize hook: mdeck owns the loop-pedal, ctx owns which grid
  local seen
  ctx.layer_quantize = function(d) seen = d end
  d1.any = false; d1.phase = 0.1
  Mdeck.arm_loop(d1); d1.phase = 0.4; Mdeck.close_loop(d1)
  ok(seen == d1, "closing a pass offers it to the instrument's quantizer")
  ctx.layer_quantize = nil
end

-- ---------------------------------------------------------------------------
-- the two settings that used to be hardcoded
-- ---------------------------------------------------------------------------
do
  defaults()
  calls = {}
  P.lay1_fade = 0.004
  Mdeck.update_fade(d1)
  near(last("fade_time", 3)[3], 0.004, 1e-9, "the loop seam is a per-deck control")
  near(last("fade_time", 4)[3], 0.004, 1e-9, "...on both of the deck's voices")
  calls = {}
  P.lay2_width = 0.25
  Mdeck.update_width(d2)
  near(last("pan", 5)[3], -0.25, 1e-9, "width pulls the left voice in")
  near(last("pan", 6)[3], 0.25, 1e-9, "...and the right one, symmetrically")
  calls = {}
  Mdeck.update_width(d1)                     -- unset: full width
  near(last("pan", 3)[3], -1, 1e-9, "an unset width is the deck's own hard L/R")

  -- loop_secs is what SNAP measures and what the page prints: one law
  P.lay1_start, P.lay1_end = 0.25, 0.5
  near(Mdeck.loop_secs(d1), 15, 1e-9, "loop_secs reads the loop in seconds")
  P.lay1_start, P.lay1_end = 0.5, 0.25       -- crossed
  near(Mdeck.loop_secs(d1), 15, 1e-9, "...whichever way round the edges are")
  P.lay1_start, P.lay1_end = 0, 1
end

-- ---------------------------------------------------------------------------
-- the loop-pedal law under the passes that are NOT a loop
-- ---------------------------------------------------------------------------
-- Every one of these leaves the deck looping the whole 60-second region if it
-- goes wrong, which is the exact "a deck, not a looper" failure the law exists
-- to remove. None of them is a forward pass, which is all the law used to see.
do
  defaults()

  -- Tapping REC by mistake. A tap lasts a few frames, and starting a
  -- recording has already widened the loop by then. What the player set has
  -- to come back, not the whole 60 seconds.
  d1.any = false
  P.lay1_start, P.lay1_end = 0.100, 0.170       -- a hand-set 4.2s loop
  d1.phase = 0.100
  Mdeck.arm_loop(d1)
  near(P.lay1_end, 1, 1e-9, "arming still opens an empty deck's loop")
  d1.phase = 0.1005                             -- ~30ms later: not a pass
  Mdeck.close_loop(d1)
  near(P.lay1_start, 0.100, 1e-9, "a pass too short to be a loop gives the old one back")
  near(P.lay1_end, 0.170, 1e-9, "...both edges, not the whole region")

  -- a REVERSE deck records downwards, so its pass runs b..a. Read forwards it
  -- looked like a negative span and was declined, leaving the region.
  d1.any = false
  P.lay1_start, P.lay1_end = 0, 1
  P.lay1_reverse = 1
  d1.phase = 0.50
  Mdeck.arm_loop(d1)
  d1.phase = 0.42                               -- 4.8s of material, downwards
  Mdeck.close_loop(d1)
  near(P.lay1_start, 0.42, 1e-9, "a reverse pass closes at the LOW end it reached")
  near(P.lay1_end, 0.50, 1e-9, "...and ends where it was armed")
  near(Mdeck.loop_secs(d1), 4.8, 1e-6, "...so the loop is what was played")

  -- and a reverse pass that WRAPPED the region end is not a loop either: read
  -- forwards it gave a tidy-looking span the deck had never recorded.
  d1.any = false
  P.lay1_start, P.lay1_end = 0.30, 0.40
  d1.phase = 0.50
  Mdeck.arm_loop(d1)
  d1.phase = 0.80                               -- wrapped past 0 and round
  Mdeck.close_loop(d1)
  near(P.lay1_start, 0.30, 1e-9, "a wrapped reverse pass restores the old loop")
  near(P.lay1_end, 0.40, 1e-9, "...instead of a span it never recorded")
  P.lay1_reverse = 0

  -- A preset saved while a deck was recording restores rec = 1, and loading
  -- sets that before it gets to the loop points. The recording it appears to
  -- start never happened, and stopping it re-cut the loop the preset had just
  -- put back.
  d1.any = false
  P.lay1_start, P.lay1_end = 0, 1
  d1.phase = 0.10
  Mdeck.arm_loop(d1)                            -- what params:read does
  P.lay1_start, P.lay1_end = 0.25, 0.35         -- ...then the file's own values
  Mdeck.pset_read(1)                            -- action_read, after the values
  P.lay1_start, P.lay1_end = 0.25, 0.35         -- (pset_read cleared the region)
  d1.phase = 0.60
  Mdeck.close_loop(d1)
  near(P.lay1_start, 0.25, 1e-9, "a pset load's phantom pass cannot re-cut the loop")
  near(P.lay1_end, 0.35, 1e-9, "...at either edge")
end

-- ---------------------------------------------------------------------------
-- the loop start must never end up past the loop end
-- ---------------------------------------------------------------------------
-- Each edge is a separate write, so in between there is a moment holding one
-- new value and one old one. If that moment has the start past the end,
-- update_loop reads it as a loop of nothing, forces it to 100ms, and the
-- playhead jumps. Whichever edge keeps them in order has to move first.
do
  defaults()
  P.lay1_start, P.lay1_end = 0.10, 0.20
  local seen = {}
  local realset = params.set
  params.set = function(self, id, v)
    realset(self, id, v)
    if id == "lay1_start" or id == "lay1_end" then
      seen[#seen + 1] = P.lay1_end - P.lay1_start
    end
  end
  Mdeck.set_loop(d1, 0.60, 0.70)                -- entirely to the RIGHT
  params.set = realset
  local crossed = false
  for _, w in ipairs(seen) do if w < 0 then crossed = true end end
  ok(not crossed, "moving a loop rightwards never crosses the pair mid-write")
  near(P.lay1_start, 0.60, 1e-9, "...and lands on the new low edge")
  near(P.lay1_end, 0.70, 1e-9, "...and the new high edge")
end

-- ---------------------------------------------------------------------------
-- the seam cannot be longer than the loop it has to cross
-- ---------------------------------------------------------------------------
-- The knob reaches 0.5s and the loop floor is 0.1s, so a scene recall can put
-- a deck permanently inside its own crossfade: silent, while the page draws
-- it bright.
do
  defaults()
  calls = {}
  P.lay1_start, P.lay1_end = 0, 1               -- 60s loop
  P.lay1_fade = 0.35
  Mdeck.update_fade(d1)
  near(last("fade_time", 3)[3], 0.35, 1e-9, "a long seam on a long loop is left alone")
  P.lay1_start, P.lay1_end = 0, 0.4 / 60        -- a 0.4s loop
  calls = {}
  Mdeck.update_fade(d1)
  near(last("fade_time", 3)[3], 0.1, 1e-9, "...but is capped to a quarter of a short one")
  calls = {}
  Mdeck.update_loop(d1)
  ok(last("fade_time", 3) ~= nil, "and moving the loop re-caps the seam against it")
end

T.report("deck harness OK")
