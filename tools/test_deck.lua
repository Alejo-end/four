-- test_deck.lua — offline harness for lib/mdeck.lua, the loop decks.
--
-- The things no eye can check here are geometric and destructive: a deck must
-- read and write ONLY its own slice of the shared softcut buffer, and an erase
-- must not take the tape or the other layer with it. Those are exactly the
-- failures that are silent until you have lost a loop.
--
--   lua tools/test_deck.lua        # from the repo root

local ok_count, fail = 0, {}
local function ok(c, w) if c then ok_count = ok_count + 1 else fail[#fail + 1] = w end end
local function near(a, b, t, w)
  ok(math.abs(a - b) <= t,
    string.format("%s (got %s, want %s +-%s)", w, tostring(a), tostring(b), tostring(t)))
end

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

-- ---- rec and overdub -----------------------------------------------------
P.lay1_rec = 1; P.lay1_pre = 1
calls = {}; Mdeck.update_rec(d1)
near(last("rec_level", 3)[3], 1, 0.001, "arming opens the record level")
near(last("pre_level", 3)[3], 1, 0.001, "pre 1 = OVERDUB: what is there survives")
P.lay1_pre = 0
calls = {}; Mdeck.update_rec(d1)
near(last("pre_level", 3)[3], 0, 0.001, "pre 0 = REPLACE")
P.lay1_rec = 0
calls = {}; Mdeck.update_rec(d1)
near(last("rec", 3)[3], 0, 0.001, "disarming closes the head")
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
calls = {}
Mdeck.pset_write(7)
local w = last("buffer_write_stereo")
ok(w ~= nil and w[2]:find("lay1-7.wav", 1, true) ~= nil,
  "a deck with audio writes its own file")
near(w[3], 120, 0.001, "...from its own region")
near(w[4], 60, 0.001, "...for its own length")
ok(count("buffer_write_stereo") == 1, "an EMPTY deck writes nothing")

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
  Mdeck.pset_read(9)
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
  Mtape.init(tctx)
  util.file_exists = function(p) return p:find("tape-4", 1, true) ~= nil end
  Mtape.pset_read(4)
  ok(painted ~= nil and painted[1]:find("tape-4.wav", 1, true) ~= nil,
    "the tape restore repaints from its wav")
  near(painted and painted[2] or -1, 60, 0.001, "...over the tape length")
  ok(tctx.twave_any == true, "...and marks the tape as holding audio")
  util.file_exists = function() return false end
end

print(string.format("\n%d assertions passed", ok_count))
if #fail > 0 then
  print(#fail .. " FAILED:")
  for _, f in ipairs(fail) do print("  x " .. f) end
  os.exit(1)
end
print("deck harness OK")
