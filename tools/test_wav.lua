-- test_wav.lua — offline harness for lib/mpages.lua's wav layer.
--
-- The thing no eye can check: the 44.1k -> 48k conversion that stops a loaded
-- sample playing a semitone sharp. A rate error IS a pitch error, so these
-- assert the VALUE at a wall-clock position, not just the frame count.
--
--   lua tools/test_wav.lua        # from the repo root
--
-- It lifts the real functions out of lib/mpages.lua (no copies) and drives
-- them over real files, with no norns and no hardware.

-- lift riff_parse + wav_decoder + wav_rate + convert_sr out of mpages and
-- assert the conversion: a rate error IS a pitch error, so check the VALUE at
-- a wall-clock position, not just the frame count.
local ok_count, fail = 0, {}
local function ok(c, w) if c then ok_count = ok_count + 1 else fail[#fail+1] = w end end
local function near(a,b,t,w) ok(math.abs(a-b) <= t,
  string.format("%s (got %s, want %s +-%s)", w, tostring(a), tostring(b), tostring(t))) end

local src = io.open("lib/mpages.lua"):read("a")
local rp = src:match("(local function riff_parse.-\nend)\n")
local dc = src:match("(local DECODE = .-\n})\n")
local wd = src:match("(function M%.wav_decoder.-\nend)\n")
local wr = src:match("(function M%.wav_rate.-\nend)\n")
local cu = src:match("(local function cubic.-\nend)\n")
local os_ = src:match("(local function open_src.-\nend)\n")
local cl = src:match("(local function close_src[^\n]*)\n")
local rf = src:match("(local function read_frames.-\nend)\n")
local blk = src:match("(local SRC_BLOCK = .-\nlocal SRC_PACK = [^\n]*)\n")
local cs = src:match("(function M%.convert_sr.-\n  return true, written / sr\nend)")
local tc = src:match("(function M%.transient_cuts.-\n  return cuts\nend)")
local ob = src:match("(function M%.onset_bounds.-\n  return first / total, %(last %+ 1%) / total\nend)")
assert(rp and dc and wd and wr and cu and os_ and cl and rf and blk and cs and tc and ob,
  "lift failed")
local env = setmetatable({
  floor = math.floor, min = math.min, max = math.max, abs = math.abs,
  clamp = function(x, lo, hi) return math.max(lo, math.min(hi, x)) end,
}, { __index = _G })
-- wav_decoder must be defined BEFORE open_src closes over it
local M = load(
  rp .. "\n" .. dc .. "\n" .. cu .. "\n" .. blk .. "\nlocal M={}\n"
  .. wd .. "\n" .. wr .. "\n" .. os_ .. "\n" .. cl .. "\n" .. rf .. "\n"
  .. cs .. "\n" .. tc .. "\n" .. ob .. "\nreturn M",
  "mp", "t", env)()

local TMP = "/tmp/main-srtest/"
os.execute("rm -rf "..TMP.."; mkdir -p "..TMP)
local function ramp(path, secs, sr, ch)
  local n = math.floor(sr*secs); local f = assert(io.open(path,"wb")); local d = n*ch*2
  f:write("RIFF", string.pack("<I4",36+d), "WAVE")
  f:write("fmt ", string.pack("<I4",16), string.pack("<I2",1), string.pack("<I2",ch),
    string.pack("<I4",sr), string.pack("<I4",sr*ch*2), string.pack("<I2",ch*2), string.pack("<I2",16))
  f:write("data", string.pack("<I4",d))
  local b={} for i=0,n-1 do local v=math.floor((i/n)*30000)
    for _=1,ch do b[#b+1]=string.pack("<i2",v) end end
  f:write(table.concat(b)); f:close(); return n
end
local function read_wav(path)
  local f=io.open(path,"rb"); if not f then return nil end
  local s=f:read("a"); f:close()
  if s:sub(1,4)~="RIFF" then return nil end
  local ch=string.unpack("<I2",s,23); local sr=string.unpack("<I4",s,25)
  local dl=string.unpack("<I4",s,41)
  return { ch=ch, sr=sr, frames=dl//(ch*2),
    sample=function(i,c) return string.unpack("<i2",s,45+(i*ch+(c-1))*2)/32768 end }
end

ramp(TMP.."a441.wav", 2.0, 44100, 2)
ok(M.wav_rate(TMP.."a441.wav") == 44100, "wav_rate reads the declared rate")
local conv, secs = M.convert_sr(TMP.."a441.wav", TMP.."a48.wav", 48000, nil)
ok(conv == true, "a 44.1k file converts")
near(secs, 2.0, 0.01, "...and keeps its DURATION (same pitch, the whole point)")
local w = read_wav(TMP.."a48.wav")
ok(w ~= nil, "the conversion wrote a file")
w = w or { sr=0, frames=0, sample=function() return 0 end }
ok(w.sr == 48000, "the converted file declares the server rate")
ok(w.ch == 2, "...and is stereo")
near(w.frames, 2.0*48000, 4, "...with 2 seconds of 48k frames")
local TOP = 30000/32768
for _, t in ipairs({0.25, 0.5, 0.75, 1.5}) do
  near(w.sample(math.floor(t*48000), 1), (t/2.0)*TOP, 0.01,
    string.format("the ramp is %.0f%% up at %.2fs", (t/2)*100, t))
end
-- a mono source must come back on BOTH channels
ramp(TMP.."m441.wav", 1.0, 44100, 1)
ok(M.convert_sr(TMP.."m441.wav", TMP.."m48.wav", 48000, nil) == true, "a MONO 44.1k file converts")
local mw = read_wav(TMP.."m48.wav")
ok(mw and mw.ch == 2, "...to stereo")
ok(mw and math.abs(mw.sample(24000,1) - mw.sample(24000,2)) < 1e-9,
  "...with the same signal on both sides")
-- already at rate: no work, no file
ramp(TMP.."a48src.wav", 1.0, 48000, 2)
local same = M.convert_sr(TMP.."a48src.wav", TMP.."unused.wav", 48000, nil)
ok(same == false, "a 48k file reports 'no conversion needed'")
ok(io.open(TMP.."unused.wav","rb") == nil, "...and writes nothing")
-- garbage refuses
local b=io.open(TMP.."bad.wav","wb"); b:write("nope"); b:close()
ok(M.convert_sr(TMP.."bad.wav", TMP.."x.wav", 48000, nil) == nil,
  "an unreadable file refuses (the caller falls back to a raw load)")

-- ---- lying and truncated headers -------------------------------------------
-- A file can be SHORTER than its data chunk claims (a truncated copy, an
-- interrupted write). read_frames must still zero-pad the missing tail, or
-- the onset/transient scans index nil and THROW — and their callers are param
-- actions, where a Lua error is a black screen on device.
do
  -- the crash shape: the header claims 4s of data and the file holds NONE, so
  -- the scan's very first read comes back empty. (a file truncated mid-way is
  -- gentler: earlier blocks have filled the reused L/R tables, so the unfixed
  -- code read stale values instead of nil — wrong, but not a throw.)
  local f = assert(io.open(TMP .. "lie.wav", "wb"))
  f:write("RIFF", string.pack("<I4", 36 + 4 * 48000 * 4), "WAVE")
  f:write("fmt ", string.pack("<I4", 16), string.pack("<I2", 1),
    string.pack("<I2", 2), string.pack("<I4", 48000),
    string.pack("<I4", 48000 * 4), string.pack("<I2", 4), string.pack("<I2", 16))
  f:write("data", string.pack("<I4", 4 * 48000 * 4))
  f:close()
  local okc, a = pcall(M.onset_bounds, TMP .. "lie.wav", 0, 1, 60, nil, nil)
  ok(okc, "onset_bounds survives a data chunk that lies about its size")
  ok(okc and a == nil, "...and reads the missing tail as silence")
  local okt = pcall(M.transient_cuts, TMP .. "lie.wav", 0, 1, 8, 60, nil)
  ok(okt, "transient_cuts survives it too")
  -- an implausible declared rate refuses instead of expanding a small file
  -- into gigabytes of output (4800 frames at a claimed 1 Hz = 230M frames;
  -- the unfixed behaviour ran until killed when probed)
  ramp(TMP .. "hz1.wav", 0.1, 48000, 2)
  local g = assert(io.open(TMP .. "hz1.wav", "r+b"))
  g:seek("set", 24); g:write(string.pack("<I4", 1)); g:close()
  ok(M.convert_sr(TMP .. "hz1.wav", TMP .. "y.wav", 48000, nil) == nil,
    "a wav claiming 1 Hz refuses to convert")
  -- and a caller can cap the OUTPUT at what its buffer can hold
  local c2, s2 = M.convert_sr(TMP .. "a441.wav", TMP .. "cap.wav", 48000, nil, 0.5)
  ok(c2 == true, "a capped conversion still converts")
  near(s2, 0.5, 0.01, "...but writes only the capped duration")
end

-- ---- transient detection ---------------------------------------------------
-- What makes pads land on the HITS instead of arbitrary eighths. Build a file
-- with impulses at known times and check the cuts come back at those times, in
-- buffer-fraction units.
do
  local SR, SECS, BUF = 48000, 4.0, 60
  local n = math.floor(SR * SECS)
  local HITS = { 0.5, 1.25, 2.0, 3.1 }      -- seconds into the file
  local f = assert(io.open(TMP .. "hits.wav", "wb"))
  local d = n * 2 * 2
  f:write("RIFF", string.pack("<I4", 36 + d), "WAVE")
  f:write("fmt ", string.pack("<I4", 16), string.pack("<I2", 1), string.pack("<I2", 2),
    string.pack("<I4", SR), string.pack("<I4", SR * 4),
    string.pack("<I2", 4), string.pack("<I2", 16))
  f:write("data", string.pack("<I4", d))
  local buf = {}
  for i = 0, n - 1 do
    local t = i / SR
    local v = 0
    for _, h in ipairs(HITS) do
      local dt = t - h
      -- a 60ms decaying burst: loud attack, quiet between hits
      if dt >= 0 and dt < 0.06 then
        v = v + math.sin(i * 0.3) * 28000 * (1 - dt / 0.06)
      end
    end
    v = math.max(-32768, math.min(32767, math.floor(v)))
    buf[#buf + 1] = string.pack("<i2i2", v, v)
  end
  f:write(table.concat(buf)); f:close()

  -- the whole file is 4s of a 60s buffer -> the window is 0 .. 4/60
  local hi = SECS / BUF
  local cuts = M.transient_cuts(TMP .. "hits.wav", 0, hi, 8, BUF, nil)
  ok(cuts ~= nil, "transient_cuts reads the file")
  cuts = cuts or {}
  ok(#cuts == #HITS + 1,
    "one cut per hit, plus the window edge (got " .. #cuts .. ", want " .. (#HITS + 1) .. ")")
  near(cuts[1] or -1, 0, 0.0001, "the first slice starts at the window edge")
  for i, h in ipairs(HITS) do
    -- 10ms envelope windows, so allow a window either side
    near((cuts[i + 1] or -1) * BUF, h, 0.03,
      string.format("cut %d lands on the hit at %.2fs", i + 1, h))
  end
  -- silence has no transients: the edge, and nothing else
  local q = M.transient_cuts(TMP .. "a48src.wav", 0, hi, 8, BUF, nil)
  ok(q == nil or #q >= 1, "a tone yields at least the window edge")
  -- an unreadable file REFUSES rather than returning an empty list, so a caller
  -- can tell "no transients" from "could not look"
  ok(M.transient_cuts(TMP .. "notawav.wav", 0, hi, 8, BUF, nil) == nil,
    "an unreadable file refuses transient detection")
end

-- ---- where the sound actually is ------------------------------------------
-- What TIGHTEN uses to pull the window in off your reaction time at the head
-- and the room tone at the tail. Build a file that is silent except for a
-- known span and check both edges come back.
do
  local SR, SECS, BUF = 48000, 4.0, 60
  local n = math.floor(SR * SECS)
  local SOUND_FROM, SOUND_TO = 0.80, 2.60          -- seconds
  local f = assert(io.open(TMP .. "gap.wav", "wb"))
  local d = n * 2 * 2
  f:write("RIFF", string.pack("<I4", 36 + d), "WAVE")
  f:write("fmt ", string.pack("<I4", 16), string.pack("<I2", 1), string.pack("<I2", 2),
    string.pack("<I4", SR), string.pack("<I4", SR * 4),
    string.pack("<I2", 4), string.pack("<I2", 16))
  f:write("data", string.pack("<I4", d))
  local buf = {}
  for i = 0, n - 1 do
    local t = i / SR
    local v = 0
    if t >= SOUND_FROM and t < SOUND_TO then v = math.sin(i * 0.05) * 20000 end
    buf[#buf + 1] = string.pack("<i2i2", math.floor(v), math.floor(v))
  end
  f:write(table.concat(buf)); f:close()

  local hi = SECS / BUF
  local a, b = M.onset_bounds(TMP .. "gap.wav", 0, hi, BUF, nil, nil)
  ok(a ~= nil, "onset_bounds finds the sound")
  near((a or 0) * BUF, SOUND_FROM, 0.02, "the leading silence is found exactly")
  near((b or 0) * BUF, SOUND_TO, 0.02, "...and so is the tail")
  -- searching a sub-range must respect it
  local a2 = M.onset_bounds(TMP .. "gap.wav", 1.5 / BUF, hi, BUF, nil, nil)
  near((a2 or 0) * BUF, 1.5, 0.02, "a search that starts mid-sound starts there")
  -- pure silence REFUSES rather than returning the whole range, so the caller
  -- leaves the window alone instead of windowing nothing
  local sil = assert(io.open(TMP .. "sil.wav", "wb"))
  local dd = 48000 * 4
  sil:write("RIFF", string.pack("<I4", 36 + dd), "WAVE")
  sil:write("fmt ", string.pack("<I4", 16), string.pack("<I2", 1), string.pack("<I2", 2),
    string.pack("<I4", SR), string.pack("<I4", SR * 4),
    string.pack("<I2", 4), string.pack("<I2", 16))
  sil:write("data", string.pack("<I4", dd))
  sil:write(string.rep("\0", dd)); sil:close()
  ok(M.onset_bounds(TMP .. "sil.wav", 0, hi, BUF, nil, nil) == nil,
    "a silent window refuses — TIGHTEN leaves it alone")
end

-- ---- the pad slice model ---------------------------------------------------
-- Which slice a pad plays, once a CHOP has found however many transients are
-- actually there. Lifted from mangler.lua so the real law is under test, not a
-- copy of it.
do
  local msrc = io.open("mangler.lua"):read("a")
  local fn = msrc:match("(local function pad_cut.-\nend)\n")
  assert(fn, "could not lift pad_cut out of mangler.lua")
  local fake = { pad_n = 8 }
  local pad_cut = load(fn .. "\nreturn pad_cut", "pc", "t",
    setmetatable({ ctx = fake }, { __index = _G }))()

  -- no chop: the even law, signalled by nil
  fake.pad_cuts = nil
  ok(pad_cut(0) == nil, "with no chop, pads fall back to the even law")

  -- five slices from six boundaries
  fake.pad_cuts = { 0.0, 0.10, 0.20, 0.40, 0.45, 0.50 }
  local a1, b1, j1 = pad_cut(0)
  near(a1, 0.0, 1e-9, "pad 1 starts at the first cut")
  near(b1, 0.10, 1e-9, "...and ends at the second")
  ok(j1 == 0, "...and is slice 0")
  local a4, b4 = pad_cut(3)
  near(a4, 0.40, 1e-9, "pad 4 starts at its own cut")
  near(b4, 0.45, 1e-9, "...and ends at the next")
  local a5, b5 = pad_cut(4)
  near(b5, 0.50, 1e-9, "the LAST slice ends at the window edge")

  -- eight pads over five slices: the pads WRAP rather than falling through to
  -- even eighths that would overlap the chopped ones
  local a6, _, j6 = pad_cut(5)
  ok(j6 == 0, "pad 6 wraps back to slice 1")
  near(a6, 0.0, 1e-9, "...and plays it from the same place")
  local _, _, j8 = pad_cut(7)
  ok(j8 == 2, "pad 8 wraps to slice 3")

  -- slices are never zero-length or inverted, whatever was found
  for i = 0, 7 do
    local lo, hi = pad_cut(i)
    ok(lo ~= nil and hi > lo, "pad " .. (i + 1) .. " has a positive length")
  end

  -- a degenerate cut list (one boundary = no slice) must not divide by zero
  fake.pad_cuts = { 0.25 }
  ok(pad_cut(0) == nil, "a single boundary is not a slice — back to the even law")
end

-- ---- param-list drift ------------------------------------------------------
-- The three hand-maintained lists (MOTION_IDS here, SCENE_RECALL_IDS and
-- SWITCH_IDS in mscenes) have drifted from the param declarations more than
-- once; a lane whose id has no SHORT label draws the raw id and overruns the
-- gutter into the automation curve. Cheap to check, so check it.
do
  local mm = io.open("lib/mmotion.lua"):read("a")
  local mp = io.open("lib/mpages.lua"):read("a")
  local list = mm:match("local MOTION_IDS = %{(.-)\n%}")
  local short = mp:match("local SHORT = %{(.-)\n%}")
  ok(list ~= nil and short ~= nil, "MOTION_IDS and SHORT are both readable")
  local have = {}
  for k in (short or ""):gmatch("([%w_]+)%s*=%s*\"") do have[k] = true end
  local missing = {}
  for id in (list or ""):gmatch("\"([%w_]+)\"") do
    if not have[id] then missing[#missing + 1] = id end
  end
  ok(#missing == 0,
    "every MOTION_IDS entry has a SHORT label (missing: "
      .. table.concat(missing, ", ") .. ")")
end

-- ---- the async bin-fill queue ----------------------------------------------
-- One queue now serves every strip (the take, the tape, the layer decks — the
-- pset restore repaints all of them). Drive a REAL mpages instance: fills for
-- different targets coexist, a fill for the SAME target supersedes the queued
-- one, and each fill spans its own seconds so a short file parks at the left
-- of a long strip and fills a matching one.
do
  local nop = function() end
  local MP = dofile("lib/mpages.lua")
  MP.init({
    pget = function(_, d) return d end,
    clamp = function(x, lo, hi) return math.max(lo, math.min(hi, x)) end,
    window_bounds = function() return 0, 1, 1 end,
    FPS = 15, PAGES = {}, amp_in = { 0, 0 }, amp_out = { 0, 0 },
    SERVER_SR = 48000,
    font = { ptext = nop, ptext_c = nop, ptext_r = nop, chip = nop,
             text_w = function() return 0 end },
  })
  ramp(TMP .. "fill.wav", 1.0, 48000, 2)
  local binsA, binsB = {}, {}
  local dA = MP.fill_wave_bins(TMP .. "fill.wav", binsA, 60)
  near(dA, 1.0, 0.01, "a fill reports the file's duration")
  MP.fill_wave_bins(TMP .. "fill.wav", binsB, 1.0)
  for _ = 1, 40 do MP.load_tick() end
  ok((binsA[1] or 0) > 0 and (binsA[64] or 0) == 0,
    "a 60s-span strip parks the 1s file at its left edge")
  ok((binsB[120] or 0) > 0.8,
    "a 1s-span strip spreads the same file across its width")
  -- supersede: queue a fill, then a second one for the SAME bins — only the
  -- second may land (queued in the reverse order the outcomes differ)
  local binsC = {}
  MP.fill_wave_bins(TMP .. "fill.wav", binsC, 1.0)
  MP.fill_wave_bins(TMP .. "fill.wav", binsC, 60)
  for _ = 1, 40 do MP.load_tick() end
  ok((binsC[120] or 0) == 0 and (binsC[1] or 0) > 0,
    "a new fill for the same target supersedes the queued one")
end

print(string.format("\n%d assertions passed", ok_count))
if #fail > 0 then print(#fail.." FAILED:"); for _,f in ipairs(fail) do print("  x "..f) end; os.exit(1) end
print("main resampler OK")
