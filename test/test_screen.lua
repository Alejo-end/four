-- test_screen.lua — the screen's own promises, read off the real pixels.
--
-- The render suite proves every page draws, and a person looks at the shots.
-- Some promises are easy to miss by eye in 70 shots, so this harness reads
-- the screen the script really drew (test/uisim/env.lua) and asserts them:
--   the header: a lit flag never drops off, however long the title and
--               however many flags are lit (the beat repeat's RP did)
--   the footer: the erase arc clears the encoder words (it sat on "MOVE")
--   VOICE:      the GRAIN cloud follows its knobs (it drew the same dots
--               whatever size, density, spread, pan or jitter said)
--   a held key: the footer keeps the tap's word while a release still taps
--   the cells:  the recording track reads REC in either blink phase
--   the edges:  TAKE's count and MOTION's >OUT stay on the screen
--
--   lua test/test_screen.lua        # from the repo root

local T = dofile("test/harness.lua")
local ok = T.ok

local SCENARIO
local env = dofile("test/uisim/env.lua")
local _h = env.install{ dir = "/tmp", scenario = function() return SCENARIO end }
include = function(p) return dofile(p .. ".lua") end
math.randomseed(1)
dofile("four.lua")
init()

local CTX, Mp
for i = 1, 255 do
  local n, v = debug.getupvalue(key, i)
  if n == nil then break end
  if n == "ctx" then CTX = v end
end
for i = 1, 255 do
  local n, v = debug.getupvalue(redraw, i)
  if n == nil then break end
  if n == "Mpages" then Mp = v end
end
assert(CTX and Mp, "could not reach the script's ctx and the pages module")

-- ---- material: a take, so the erase arc and the voice have something -----
SCENARIO = function(t)
  if t == 2 then params:set("rec", 1) end
  if t == 25 then params:set("rec", 0) end
  _h.push("rec_phase", 0.02 + t * 0.004)
  _h.push("rec_amp", 0.5)
  _h.push("amp_in_l", 0.4); _h.push("amp_in_r", 0.4)
  _h.push("play_phase", 0.4)
end
_h.run_ticks(40)
SCENARIO = nil
ok(CTX.wave_any, "the scenario recorded a take")

local px = _h.pixel

-- ============================================================================
-- 1 · the header: every lit flag stays on it
-- ============================================================================
do
  -- the sequencer's and the repeat's clocks are not run here: env's
  -- clock.run would replace the frame loop
  local real_run, real_cancel = clock.run, clock.cancel
  clock.run = function() return {} end
  clock.cancel = function() end
  local HF = {}
  for _, f in ipairs(Mp.HFLAGS) do HF[f.id] = f end
  local dx0 = Mp.DOT_X0

  -- a lone writer draws whole
  T.goto_page("TAKE")
  params:set("motion_rec", 1)
  redraw()
  ok(HF.M.x and HF.M.full, "a lone write flag draws whole (dot and letter)")
  params:set("motion_rec", 0)

  -- all of them at once, on the longest title, in the blink's lit phase
  local WIDEST, widest_w = nil, -1
  for _, name in ipairs(T.pages()) do
    local w = CTX.font.text_w(name, 1)
    if w > widest_w then WIDEST, widest_w = name, w end
  end
  T.goto_page(WIDEST)
  local ON = { "rec", "tape_rec", "motion_rec", "freeze",
    "tape_freeze", "beat_repeat", "step_run" }
  for _, id in ipairs(ON) do params:set(id, 1) end
  params:set("lfo1_target", 2); params:set("lfo1_depth", 0.5)
  params:set("t2_mode", 5)   -- four: track 2 sounding lights T2
  _h.run_ticks(1)
  while CTX.frame % 4 >= 2 do _h.run_ticks(1) end
  redraw()
  local last, prev = 0, -1
  for _, f in ipairs(Mp.HFLAGS) do
    ok(f.x ~= nil, "the " .. f.ch .. " flag is drawn with every flag lit")
    if f.x then
      ok(f.x > prev, "...in priority order (" .. f.ch .. ")")
      prev = f.x
      local w = f.full and (f.write and f.w + 5 or f.w) or (f.write and f.w or 2)
      last = f.x + w
      local ink = false
      for x = f.x, f.x + 1 do
        for y = 1, 5 do if px(x, y) > 0 then ink = true end end
      end
      ok(ink, "...and something is drawn where it sits (" .. f.ch .. ")")
    end
  end
  ok(last <= dx0 - 2, "the last flag ends before the page dots (" .. last .. " <= " .. (dx0 - 2) .. ")")
  -- RP names its division
  T.goto_page("TAKE")
  for _, id in ipairs(ON) do if id ~= "beat_repeat" then params:set(id, 0) end end
  params:set("lfo1_depth", 0)
  params:set("t2_mode", 1)
  params:set("repeat_div", 4)
  redraw()
  ok(HF.RP.ch == "RP16" and HF.RP.full, "RP names the division it repeats (" .. HF.RP.ch .. ")")
  params:set("repeat_div", 3)
  for _, id in ipairs(ON) do params:set(id, 0) end
  params:set("lfo1_depth", 0); params:set("lfo1_target", 1)
  _h.run_ticks(1)
  clock.run, clock.cancel = real_run, real_cancel
end

-- ============================================================================
-- 2 · the footer: the erase arc clears the encoder words
-- ============================================================================
do
  T.goto_page("TAKE")
  key(1, 1); key(3, 1)
  _h.run_ticks(8)                     -- mid-arc, before it lands
  redraw()
  ok(Mp.FOOT.arc ~= nil, "the arc draws while K1+K3 is held on TAKE")
  ok(Mp.FOOT.arc and Mp.FOOT.e2 > Mp.FOOT.arc,
    "the E2 word starts right of the arc (" .. tostring(Mp.FOOT.e2) .. " > "
      .. tostring(Mp.FOOT.arc) .. ")")
  key(3, 0); key(1, 0)                -- released in the abort zone
  _h.run_ticks(1)
  ok(CTX.wave_any, "...and the abort leaves the take")
  redraw()
  ok(Mp.FOOT.arc == nil, "the arc is gone with the keys")
  -- TAKE's K3 held toward UNDO draws the same arc, with the same room
  local real_undo = CTX.take_undo
  CTX.take_undo = function() end
  key(3, 1)
  _h.run_ticks(8)
  redraw()
  ok(Mp.FOOT.arc ~= nil, "K3 held on TAKE draws the UNDO arc")
  ok(Mp.FOOT.arc and Mp.FOOT.e2 > Mp.FOOT.arc, "...and the E2 word clears it")
  key(3, 0)
  _h.run_ticks(1)
  redraw()
  ok(Mp.FOOT.arc == nil, "...gone with the key")
  -- a hold aborted by leaving the page draws no arc when it comes back
  key(3, 1); _h.run_ticks(3)
  T.goto_page("VOICE"); _h.run_ticks(2)
  T.goto_page("TAKE"); _h.run_ticks(8)
  redraw()
  ok(Mp.FOOT.arc == nil, "an aborted hold draws no arc back on TAKE")
  key(3, 0); _h.run_ticks(1)
  -- K1 pressed mid-hold aborts: no arc under another word
  key(3, 1); _h.run_ticks(4); key(1, 1); _h.run_ticks(4)
  redraw()
  ok(Mp.FOOT.arc == nil, "K1 mid-hold aborts the UNDO arc")
  key(1, 0); key(3, 0); _h.run_ticks(1)
  CTX.take_undo = real_undo
end

-- ============================================================================
-- 3 · VOICE: the GRAIN cloud follows its knobs
-- ============================================================================
-- the cloud's pixels in the body, the play head's column left out (it is the
-- only thing on row 50). Every case is drawn on the SAME frame, so only the
-- knob differs.
local function cloud()
  redraw()
  local n, x0, x1, y0, y1 = 0, 999, -1, 999, -1
  for x = 0, 127 do
    if px(x, 50) == 0 then
      for y = 21, 47 do
        if px(x, y) > 0 then
          n = n + 1
          x0, x1 = math.min(x0, x), math.max(x1, x)
          y0, y1 = math.min(y0, y), math.max(y1, y)
        end
      end
    end
  end
  return n, x1 - x0, y0, y1
end
do
  T.goto_page("VOICE")
  local BASE = { mode = 2, size = 0.1, density = 20, spread = 0.5, pan = 0,
    pos_jitter = 0, grain_jitter = 0, freeze = 0, stop_all = 0, mix = 0.5,
    pos_start = 0, pos_end = 1 }   -- the whole buffer: jitter has room to show
  local function set(t)
    for id, v in pairs(BASE) do params:set(id, v) end
    for id, v in pairs(t or {}) do params:set(id, v) end
  end
  set()
  _h.run_ticks(30)                    -- the page-name pop has gone
  local n = cloud()
  ok(n > 0, "GRAIN draws a cloud (" .. n .. " px)")

  set({ size = 0.01 }); local small = cloud()
  set({ size = 0.5 }); local big = cloud()
  ok(big > small * 2, "a bigger SIZE draws longer grains (" .. big .. " > 2 x " .. small .. ")")

  set({ density = 1 }); local thin = cloud()
  set({ density = 200 }); local thick = cloud()
  ok(thick > thin * 3, "a higher DENSITY draws more grains (" .. thick .. " > 3 x " .. thin .. ")")

  -- GRAIN plays stereo PAIRS: at SPREAD 0 the left grains sit at the left
  -- edge and the right grains at the right edge, the take as recorded
  local _, _, y0, y1 = (function() set({ spread = 0 }); return cloud() end)()
  ok(y1 - y0 >= 20, "GRAIN at SPREAD 0 keeps the take's stereo: grains at both edges (rows "
    .. y0 .. ".." .. y1 .. ")")
  -- CLOUD scatters each grain around the pan: SPREAD 0 is one row
  BASE.mode = 6
  _, _, y0, y1 = (function() set({ spread = 0 }); return cloud() end)()
  ok(y0 == y1, "CLOUD at SPREAD 0 puts every grain in the middle of the stereo field (rows "
    .. y0 .. ".." .. y1 .. ")")
  set({ spread = 1 })
  _, _, y0, y1 = cloud()
  ok(y1 - y0 >= 12, "SPREAD 1 scatters them over it (" .. (y1 - y0) .. " rows)")

  set({ spread = 0, pan = -1 })
  local _, _, ly0, ly1 = cloud()
  set({ spread = 0, pan = 1 })
  local _, _, ry0 = cloud()
  ok(ly1 < ry0, "PAN moves the cloud: left above right (" .. ly1 .. " < " .. ry0 .. ")")
  BASE.mode = 2

  set({ pos_jitter = 0 }); local _, near_w = cloud()
  set({ pos_jitter = 1 }); local _, wide_w = cloud()
  ok(wide_w > near_w * 2, "position JITTER widens the cloud over the window ("
    .. wide_w .. " > 2 x " .. near_w .. ")")

  -- the draw is pure: the same frame and knobs draw the same picture
  set()
  local a = cloud()
  local b = cloud()
  ok(a == b, "the cloud is drawn from the frame, not from math.random")
  set({ mode = 5 })
end

-- ============================================================================
-- 4 · one blink: only the header's write flags blink
-- ============================================================================
-- A page's own chip for a write (TAPE's REC, MOTION's REC and
-- frame, TAKE's WAIT) is steady: drawn the same on every phase of the old
-- blinks (every 4 frames, every 8, every second).
local function region(x0, y0, x1, y1)
  local t = {}
  for y = y0, y1 do for x = x0, x1 do t[#t + 1] = px(x, y) end end
  return table.concat(t, ",")
end
local function steady(name, x0, y0, x1, y1)
  local keep = CTX.frame
  local ref
  local same, lit = true, false
  for _, f in ipairs({ 0, 2, 6, 8, 12 }) do
    CTX.frame = f
    redraw()
    local r = region(x0, y0, x1, y1)
    if r:find("[1-9]") then lit = true end
    if ref and r ~= ref then same = false end
    ref = ref or r
  end
  CTX.frame = keep
  ok(lit, name .. " draws")
  ok(same, name .. " is steady (the header's write flags are the one blink)")
end
do
  T.goto_page("TAPE")
  _h.run_ticks(30)
  params:set("tape_rec", 1)
  steady("TAPE's REC chip", 0, 10, 24, 20)
  params:set("tape_rec", 0)
  T.goto_page("MOTION")
  _h.run_ticks(30)
  params:set("motion_rec", 1)
  steady("MOTION's REC chip", 0, 10, 24, 20)
  params:set("motion_rec", 0)
  -- the header still blinks
  params:set("tape_rec", 1)
  CTX.frame = 0; redraw(); local on = region(30, 0, 80, 7)
  CTX.frame = 2; redraw(); local off = region(30, 0, 80, 7)
  ok(on ~= off, "...and the header's T still blinks")
  params:set("tape_rec", 0)
  _h.run_ticks(1)
end

-- ============================================================================
-- 5 · the page dots stay on one straight, fixed grid
-- ============================================================================
do
  -- where the dots are on one page: the middle of every lit run on row 4
  local function dots()
    local at = {}
    local c = Mp.DOT_X0 - 1
    while c <= 127 do
      if px(c, 4) > 0 then
        local from = c
        while px(c + 1, 4) > 0 do c = c + 1 end
        at[#at + 1] = (from + c) / 2
      end
      c = c + 1
    end
    return at
  end
  local first
  local same, straight, evenly = true, true, true
  for i = 1, #CTX.PAGES do
    T.goto_page(CTX.PAGES[i])
    _h.run_ticks(30)
    redraw()
    local at = dots()
    ok(#at == #CTX.PAGES, CTX.PAGES[i] .. ": one dot per page (" .. #at .. ")")
    first = first or at
    for k = 1, #at do
      if at[k] ~= first[k] then same = false end
      if k > 1 and at[k] - at[k - 1] ~= 3 then evenly = false end
    end
    for c = Mp.DOT_X0 - 1, 127 do
      if px(c, 3) > 0 or px(c, 6) > 0 then straight = false end
      if (px(c, 4) > 0) ~= (px(c, 5) > 0) then straight = false end
    end
  end
  ok(same, "no dot moves when the page changes")
  ok(evenly, "the dots are evenly spaced")
  ok(straight, "every dot sits on rows 4 and 5, the current page too")
end

-- ============================================================================
-- 6 · PADS shows the sequencer's pattern at all times
-- ============================================================================
do
  T.goto_page("PADS")
  _h.run_ticks(30)
  params:set("step_run", 0)
  params:set("step_len", 8); params:set("step_fill", 3)
  redraw()
  local bars, maxl = 0, 0
  for x = 0, 127 do
    if px(x, 44) > 0 then bars = bars + 1; maxl = math.max(maxl, px(x, 44)) end
  end
  ok(bars > 0, "stopped, the step row is drawn (" .. bars .. " px)")
  ok(maxl <= 3, "...dim (level " .. maxl .. ")")
  params:set("step_len", 4); params:set("step_fill", 4)
end

-- ============================================================================
-- 7 · EFFECT: off lies flat and dim, on draws a bright moving trace, and a
--     silent track's effect is dim
-- ============================================================================
do
  local function body()
    local lit, maxl, rows = 0, 0, {}
    for y = 22, 44 do   -- under the type chip, over the footer
      for x = 0, 127 do
        local l = px(x, y)
        if l > 0 then lit = lit + 1; maxl = math.max(maxl, l); rows[y] = true end
      end
    end
    local n = 0
    for _ in pairs(rows) do n = n + 1 end
    return lit, maxl, n
  end
  T.goto_page("EFFECT")
  params:set("track_sel", 1); params:set("mode", 5); params:set("effect", 1)
  _h.run_ticks(30); redraw()
  local lit, maxl, rows = body()
  ok(rows == 1 and maxl <= 3, "EFFECT off: one flat dim line (" .. rows .. " rows, level " .. maxl .. ")")
  for fx = 2, 6 do
    params:set("effect", fx); params:set("effect_amt", 0.7)
    _h.run_ticks(3); redraw()
    lit, maxl, rows = body()
    ok(rows >= 5 and maxl >= 10, params:string("effect") .. " draws a bright trace (" .. rows .. " rows, level " .. maxl .. ")")
  end
  params:set("mode", 1)
  _h.run_ticks(3); redraw()
  lit, maxl, rows = body()
  ok(maxl <= 4 and lit > 0, "a silent track's effect is drawn dim (level " .. maxl .. ")")
  params:set("mode", 5); params:set("effect", 1)
end

-- ============================================================================
-- 8 · a held key's word changes when its release changes meaning
-- ============================================================================
-- Before TAP_FRAMES a release is still the tap (SNAP, DRY), so the footer
-- keeps the tap's word, with no arc and no hatch. The hold's word drew from
-- the second frame, and a release in frames 2 to 4 did what it did not say.
do
  local TAP = CTX.TAP_FRAMES
  T.goto_page("TAKE")
  _h.run_ticks(30)
  local real_undo = CTX.take_undo
  CTX.take_undo = function() end
  params:set("pos_start", 0.1); params:set("pos_end", 0.4)
  key(3, 1); _h.run_ticks(TAP - 1); redraw()
  ok(Mp.FOOT.k3 == "SNAP" and Mp.FOOT.arc == nil,
    "K3 held " .. (TAP - 1) .. " frames on TAKE still reads SNAP, no arc (" .. tostring(Mp.FOOT.k3) .. ")")
  CTX.take_msg = nil
  key(3, 0)
  ok(CTX.take_msg and CTX.take_msg:find("SNAP"), "...and its release snaps, as it said")
  key(3, 1); key(3, 0)                -- the second tap puts the window back
  key(3, 1); _h.run_ticks(TAP); redraw()
  ok(Mp.FOOT.k3 == "UNDO" and Mp.FOOT.arc ~= nil,
    "held " .. TAP .. " frames it reads UNDO with its arc (" .. tostring(Mp.FOOT.k3) .. ")")
  CTX.take_msg = nil
  key(3, 0); _h.run_ticks(1)
  ok(CTX.take_msg == nil, "...and a release there does nothing")
  CTX.take_undo = real_undo
  -- K1+K3: DRY until a release can no longer be a tap, then ERASE and the hatch
  local function hatched()
    for y = 20, 40 do for x = 0, 127 do if px(x, y) == 11 then return true end end end
    return false
  end
  key(1, 1); key(3, 1); _h.run_ticks(TAP - 1); redraw()
  ok(Mp.FOOT.k3 == "DRY" and Mp.FOOT.arc == nil and not hatched(),
    "K1+K3 held " .. (TAP - 1) .. " frames reads DRY: no ERASE, no arc, no hatch ("
      .. tostring(Mp.FOOT.k3) .. ")")
  _h.run_ticks(1); redraw()
  ok(Mp.FOOT.k3 == "ERASE" and Mp.FOOT.arc ~= nil and hatched(),
    "...and at " .. TAP .. " frames ERASE, the arc and the hatch")
  key(3, 0); key(1, 0); _h.run_ticks(1)
  ok(CTX.wave_any, "...released in the abort zone, the take stays")
end

-- ============================================================================
-- 9 · the recording track's cell reads REC in either blink phase
-- ============================================================================
-- The lit phase was the focus's white box, so on a track page half the blink
-- looked like no recording. Each phase must differ from every other drawing
-- of that cell: the box (a page that edits it) and the underline (a shared page).
do
  local function cell(n) return region((n - 1) * 6, 0, n * 6 - 1, 7) end
  local keep = CTX.frame
  local function at(phase) CTX.frame = 400 + phase; redraw() end
  params:set("track_sel", 2)
  T.goto_page("EFFECT"); _h.run_ticks(30)
  at(0); local box = cell(2)
  at(2); ok(cell(2) == box, "the focus box is steady while nothing records")
  T.goto_page("DELAY"); _h.run_ticks(30)
  at(0); local line = cell(2)
  params:set("rec", 1)
  for _, page in ipairs({ "EFFECT", "DELAY" }) do
    T.goto_page(page); _h.run_ticks(30)
    for _, ph in ipairs({ 0, 2 }) do
      at(ph)
      local c = cell(2)
      ok(Mp.CELL[2] == "rec" and c:find("[1-9]") ~= nil and c ~= box and c ~= line,
        page .. ", blink phase " .. ph .. ": the recording cell is neither the box nor the underline")
    end
  end
  params:set("rec", 0)
  CTX.frame = keep
  params:set("track_sel", 1)
  _h.run_ticks(1)
end

-- ============================================================================
-- 10 · numbers and tags stay on the screen
-- ============================================================================
do
  -- TAKE's elapsed seconds at the widest (58.2S): it lost its S's last two
  -- columns from 20 s on
  T.goto_page("TAKE"); _h.run_ticks(30)
  params:set("rec", 1)
  _h.run_ticks(1)
  CTX.rec_waiting = false
  CTX.rec_arm_phase, CTX.rec_phase = 0, 0.97
  redraw()
  local right = -1
  for y = 46, 55 do for x = 70, 127 do if px(x, y) > 0 then right = math.max(right, x) end end end
  ok(right >= 110 and right <= 125, "TAKE's count at 58 s ends inside the screen (x " .. right .. ")")
  params:set("rec", 0)
  _h.run_ticks(1)
  -- MOTION: a modulator that goes out to MIDI and crow says >OUT after its wave
  local function tgt(id)
    for k, t in ipairs(CTX.lfo.TARGETS) do if t == id then return k + 1 end end
  end
  T.goto_page("MOTION"); _h.run_ticks(30)
  params:set("motion_rec", 0)
  params:set("lfo1_target", tgt("cutoff")); params:set("lfo1_depth", 0.6)
  params:set("out_src", 4); params:set("out_midi", 1); params:set("out_crow", 1)
  params:set("mod_focus", 2)
  _h.run_ticks(2); redraw()
  -- the tag is the row's one level-6 ink (a scrollbar on x 127 is 2 or 9)
  local edge, tag = false, false
  for y = 9, 54 do
    if px(126, y) == 6 or px(127, y) == 6 then edge = true end
    for x = 105, 125 do if px(x, y) == 6 then tag = true end end
  end
  ok(tag and not edge, ">OUT draws whole, clear of the screen's last two columns")
  params:set("out_src", 1); params:set("out_midi", 0); params:set("out_crow", 0)
  params:set("lfo1_depth", 0); params:set("lfo1_target", 1); params:set("mod_focus", 1)
  _h.run_ticks(1)
end

-- ============================================================================
-- 11 · FZ: any track's freeze is a hold the header shows
-- ============================================================================
do
  local FZ
  for _, f in ipairs(Mp.HFLAGS) do if f.id == "FZ" then FZ = f end end
  T.goto_page("DELAY"); _h.run_ticks(2)
  params:set("t3_pv_freeze", 1); redraw()
  ok(FZ.on and FZ.x ~= nil, "track 3's freeze lights FZ")
  params:set("t3_pv_freeze", 0); redraw()
  ok(not FZ.on, "...and FZ goes with it")
end

-- ============================================================================
-- 12 · SCENE names both ends of the crossfader
-- ============================================================================
-- The rail reads "A 1 ====*---- 4 B" (A LIVE when A is the live sound), a
-- small A sits under A's cell, and the footer reads B·4, with K1 A·1.
-- reads() compares the lit pixels in a string's box with that string drawn
-- alone in the same font, so a label that is cut, moved or overdrawn fails.
do
  local Mf = CTX.font
  local function mask(x, y, w)
    local t = {}
    for yy = y, y + 4 do
      for xx = x, x + w - 1 do t[#t + 1] = px(xx, yy) > 0 and "1" or "0" end
    end
    return table.concat(t)
  end
  local function reads(str, x, y)
    local w = Mf.text_w(str, 1)
    local drawn = mask(x, y, w)
    screen.clear()
    Mf.ptext(str, x, y, 1, 15)
    local want = mask(x, y, w)
    redraw()
    return drawn == want
  end
  local function lmax(x0, y0, x1, y1)
    local m = 0
    for y = y0, y1 do for x = x0, x1 do m = math.max(m, px(x, y)) end end
    return m
  end
  local function cell_x(i) return 16 + (i - 1) * 14 end
  T.goto_page("SCENE")
  params:set("orbit_on", 0)
  params:set("scene_morph_amt", 0); _h.run_ticks(2)
  params:set("scene_slot", 1); T.pulse("scene_capture")
  params:set("cutoff", 5000)
  params:set("scene_slot", 4); T.pulse("scene_capture")
  params:set("scene_slot", 8); T.pulse("scene_capture")
  params:set("scene_slot", 4)
  params:set("scene_slot_a", 1)
  _h.run_ticks(25)                           -- the SAVED word has gone
  params:set("scene_morph_amt", 0.4); _h.run_ticks(2)
  redraw()
  local bw = Mf.text_w("4 B", 1)
  ok(reads("A 1", 4, 43), "the rail's left end reads A 1")
  ok(reads("4 B", 124 - bw, 43), "...its right end reads 4 B")
  ok(lmax(4, 43, 16, 47) > lmax(124 - bw, 43, 123, 47),
    "...and the nearer end (A, at 0.4) is the brighter")
  ok(reads("A", cell_x(1) + 4, 36), "a small A sits under A's cell")
  ok(lmax(cell_x(1), 36, cell_x(1) + 11, 40) == 12, "...bright: it is the fader's A")
  local others = 0
  for i = 2, 8 do others = math.max(others, lmax(cell_x(i), 36, cell_x(i) + 11, 40)) end
  ok(others == 0, "...and under no other cell")
  ok(reads("A", Mp.FOOT.e2, 58) and reads("1", Mp.FOOT.e2 + 7, 58),
    "the footer names E2 A·1 (" .. tostring(Mp.FOOT.e2) .. ")")
  ok(reads("B", Mp.FOOT.e3, 58) and reads("4", Mp.FOOT.e3 + 7, 58),
    "...and E3 B·4 (" .. tostring(Mp.FOOT.e3) .. ")")
  key(1, 1); redraw()
  ok(reads("FADE", Mp.FOOT.e3, 58), "...and K1 held names E3 FADE")
  key(1, 0); redraw()

  -- A changed mid-fade: the rail keeps the A the fade left from, and the
  -- mark under the new A waits dim
  params:set("scene_slot_a", 8); _h.run_ticks(1); redraw()
  ok(reads("A 1", 4, 43), "A changed mid-fade: the rail still reads A 1")
  ok(reads("A", cell_x(8) + 4, 36) and lmax(cell_x(8), 36, cell_x(8) + 11, 40) == 4,
    "...and the A under cell 8 waits dim")
  params:set("scene_morph_amt", 0); _h.run_ticks(2); redraw()
  ok(reads("A 8", 4, 43) and lmax(cell_x(8), 36, cell_x(8) + 11, 40) == 12,
    "...home at 0, A 8 takes over, on the rail and on its cell")

  -- the widest labels stay on the screen and clear of the rail
  params:set("scene_slot_a", 0); params:set("scene_slot", 8)
  params:set("scene_morph_amt", 0.6); _h.run_ticks(2); redraw()
  local lw, w8 = Mf.text_w("A LIVE", 1), Mf.text_w("8 B", 1)
  ok(reads("A LIVE", 4, 43), "A = LIVE: the left end reads A LIVE")
  ok(reads("8 B", 124 - w8, 43), "...and slot 8 reads 8 B")
  local any = 0
  for i = 1, 8 do any = math.max(any, lmax(cell_x(i), 36, cell_x(i) + 11, 40)) end
  ok(any == 0, "...and with A LIVE no cell carries the A")
  -- the handle parked at either end keeps a gap of dark columns to the label
  params:set("scene_morph_amt", 0); _h.run_ticks(2); redraw()
  ok(reads("A LIVE", 4, 43) and lmax(4 + lw, 43, 4 + lw + 2, 47) == 0,
    "the handle at 0 stays clear of A LIVE (x " .. (4 + lw - 1) .. ")")
  params:set("scene_morph_amt", 1); _h.run_ticks(2); redraw()
  ok(reads("8 B", 124 - w8, 43) and lmax(124 - w8 - 3, 43, 124 - w8 - 1, 47) == 0,
    "the handle at 1 stays clear of 8 B (x " .. (124 - w8) .. ")")
  ok(lmax(124, 36, 127, 47) == 0, "...and nothing reaches the last four columns")

  params:set("scene_morph_amt", 0); _h.run_ticks(2)
  for _, s in ipairs({ 1, 4, 8 }) do params:set("scene_slot", s); T.pulse("scene_clear") end
  params:set("scene_slot", 1); params:set("cutoff", 20000)
  _h.run_ticks(1)
end

T.report("screen harness OK")
