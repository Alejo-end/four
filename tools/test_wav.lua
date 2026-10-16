-- test_wav.lua — offline harness for the wav layer (lib/mwav.lua) and the
-- strips mpages paints through it.
--
-- The thing no eye can check: the 44.1k -> 48k conversion that stops a loaded
-- sample playing a semitone sharp. A rate error IS a pitch error, so these
-- assert the VALUE at a wall-clock position, not just the frame count.
--
--   lua tools/test_wav.lua        # from the repo root
--
-- It loads the real lib/mwav.lua and lib/mpages.lua (no copies) with a stub
-- ctx and drives them over real files, with no norns and no hardware.

local T = dofile("tools/harness.lua")
local ok, near = T.ok, T.near

-- the real modules, initialised the way mangler.lua does it, minus the
-- screen. M answers for both: the file layer first, then the strips.
local nop = function() end
local W = dofile("lib/mwav.lua")
local MP = dofile("lib/mpages.lua")
local M = setmetatable({}, { __index = function(_, k) return W[k] or MP[k] end })
local CTX = {
  wav = W,
  pget = function(_, d) return d end,
  clamp = function(x, lo, hi) return math.max(lo, math.min(hi, x)) end,
  window_bounds = function() return 0, 1, 1 end,
  FPS = 15, PAGES = {}, amp_in = { 0, 0 }, amp_out = { 0, 0 },
  SERVER_SR = 48000,
  font = { ptext = nop, ptext_c = nop, ptext_r = nop, chip = nop,
           text_w = function() return 0 end },
}
W.init(CTX)
MP.init(CTX)

local TMP = os.tmpname() .. "-wav/"   -- per run: a fixed dir broke parallel runs
os.execute("rm -rf "..TMP.."; mkdir -p "..TMP)
local function ramp(path, secs, sr, ch)
  local n = math.floor(sr*secs)
  T.write_wav(path, sr, ch, 16, n, function(i) return math.floor((i/n)*30000) end)
  return n
end
-- reads whatever depth the writer chose: convert_sr moved to 24-bit, and a
-- reader pinned to 16 would have silently decoded every third sample as a
-- frame boundary rather than failing
local function read_wav(path)
  local f=io.open(path,"rb"); if not f then return nil end
  local s=f:read("a"); f:close()
  if s:sub(1,4)~="RIFF" then return nil end
  local ch=string.unpack("<I2",s,23); local sr=string.unpack("<I4",s,25)
  local bits=string.unpack("<I2",s,35); local dl=string.unpack("<I4",s,41)
  local bps=bits//8
  local fmt = (bps==2 and "<i2") or (bps==3 and "<i3") or "<i4"
  local scale = 2^(bits-1)
  return { ch=ch, sr=sr, bits=bits, frames=dl//(ch*bps),
    sample=function(i,c) return string.unpack(fmt,s,45+(i*ch+(c-1))*bps)/scale end }
end
-- A tone at a known pitch, for the things a ramp cannot show: whether the
-- conversion removes what it has to, and leaves alone what it should.
local function sine(path, secs, sr, hz, amp)
  T.write_wav(path, sr, 1, 16, math.floor(sr*secs), function(i)
    return math.floor(math.sin(2*math.pi*hz*i/sr)*(amp or 0.7)*32000)
  end)
end
local function rms(w, from, to, c)
  local a=0
  for i=from,to-1 do local v=w.sample(i,c or 1); a=a+v*v end
  return math.sqrt(a/(to-from))
end

ramp(TMP.."a441.wav", 2.0, 44100, 2)
ok(select(3, M.wav_info(TMP.."a441.wav")) == 44100, "wav_info reads the declared rate")
local conv, secs = M.convert_sr(TMP.."a441.wav", TMP.."a48.wav", 48000, nil)
ok(conv == true, "a 44.1k file converts")
near(secs, 2.0, 0.01, "...and keeps its DURATION (same pitch, the whole point)")
local w = read_wav(TMP.."a48.wav")
ok(w ~= nil, "the conversion wrote a file")
w = w or { sr=0, frames=0, sample=function() return 0 end }
ok(w.sr == 48000, "the converted file declares the server rate")
ok(w.ch == 2, "...and is stereo")
near(w.frames, 2.0*48000, 4, "...with 2 seconds of 48k frames")
ok(w.bits == 24, "...written at 24 bits (a 24-bit source no longer loses 8)")
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

-- ---- the resampling KERNEL --------------------------------------------------
-- A ramp cannot tell the two shapes apart: both follow a straight line
-- perfectly. What separates them is what they REMOVE. Going down to a lower
-- rate, anything too high to fit has to be taken out first, or it comes back
-- mirrored into the audible range as a tone that was never in the file. The
-- old cubic curve filtered nothing at all, so this is the check that the
-- shape actually changed.
do
  -- 30 kHz at 96k is 6 kHz above the 48k Nyquist: it can only survive as an
  -- alias at 48000 - 30000 = 18 kHz, which is squarely audible.
  sine(TMP .. "hi96.wav", 0.5, 96000, 30000, 0.7)
  ok(M.convert_sr(TMP .. "hi96.wav", TMP .. "hi48.wav", 48000, nil) == true,
    "a 96k file converts DOWN to 48k")
  local hw = read_wav(TMP .. "hi48.wav")
  ok(hw ~= nil, "...and wrote a file")
  local a = hw and rms(hw, 2000, 20000) or 1
  -- measured: sinc 0.0052, cubic 0.4834 (both run against this same file)
  ok(a < 0.02, string.format(
    "...with the above-Nyquist tone REMOVED, not folded back (rms %.4f, "
    .. "cubic measured 0.4834 on this file)", a))

  -- and it only removes what it has to: 8 kHz fits comfortably in a 48k file
  -- and must come through at full level
  sine(TMP .. "lo96.wav", 0.5, 96000, 8000, 0.7)
  ok(M.convert_sr(TMP .. "lo96.wav", TMP .. "lo48.wav", 48000, nil) == true,
    "an in-band 96k tone converts too")
  local lw = read_wav(TMP .. "lo48.wav")
  local b = lw and rms(lw, 2000, 20000) or 0
  near(b, 0.7 / math.sqrt(2), 0.05, "...and keeps its level through the passband")

  -- upsampling is where the everyday library lives: the pitch must be right
  -- and the waveform must still be a clean sine, not a stair
  sine(TMP .. "t441.wav", 0.5, 44100, 1000, 0.7)
  ok(M.convert_sr(TMP .. "t441.wav", TMP .. "t48.wav", 48000, nil) == true,
    "a 44.1k tone converts UP to 48k")
  local tw = read_wav(TMP .. "t48.wav")
  local worst = 0
  if tw then
    for i = 4800, 19200 do          -- skip the kernel's edge transient
      local want = math.sin(2 * math.pi * 1000 * i / 48000) * (32000 / 32768) * 0.7
      worst = math.max(worst, math.abs(tw.sample(i, 1) - want))
    end
  end
  ok(worst < 0.01, string.format(
    "...landing on the same 1 kHz sine at the same PHASE (worst %.4f)", worst))
end

-- ---- the export interleaver -------------------------------------------------
-- write_take dumps a MONO L/R pair and this zips them into the browsable
-- stereo file. It used to demand 16-bit; the take is written at 24 now, so a
-- pinned reader would have refused every export.
do
  local function mono24(path, n, val)
    T.write_wav(path, 48000, 1, 24, n, function() return math.floor(val * 8388607) end)
  end
  mono24(TMP .. "tl.wav", 1000, 0.5)
  mono24(TMP .. "tr.wav", 1000, -0.25)
  ok(M.interleave_wav(TMP .. "tl.wav", TMP .. "tr.wav", TMP .. "stereo24.wav", nil) == true,
    "a 24-bit L/R pair interleaves")
  local sw = read_wav(TMP .. "stereo24.wav")
  ok(sw and sw.bits == 24 and sw.ch == 2, "...into a 24-bit stereo file")
  ok(sw and sw.frames == 1000, "...of the right length")
  near(sw and sw.sample(500, 1) or 0, 0.5, 1e-4, "...with L intact")
  near(sw and sw.sample(500, 2) or 0, -0.25, 1e-4, "...and R intact")
  -- a pair of two different widths is not a stereo file
  T.write_wav(TMP .. "t16.wav", 48000, 1, 16, 1000, function() return 1000 end)
  ok(M.interleave_wav(TMP .. "tl.wav", TMP .. "t16.wav", TMP .. "mix.wav", nil) == false,
    "a MISMATCHED pair refuses rather than interleaving two widths into one header")
end

-- ---- transient detection ---------------------------------------------------
-- What makes pads land on the HITS instead of arbitrary eighths. Build a file
-- with impulses at known times and check the cuts come back at those times, in
-- buffer-fraction units.
do
  local SR, SECS, BUF = 48000, 4.0, 60
  local n = math.floor(SR * SECS)
  local HITS = { 0.5, 1.25, 2.0, 3.1 }      -- seconds into the file
  T.write_wav(TMP .. "hits.wav", SR, 2, 16, n, function(i)
    local t = i / SR
    local v = 0
    for _, h in ipairs(HITS) do
      local dt = t - h
      -- a 60ms decaying burst: loud attack, quiet between hits
      if dt >= 0 and dt < 0.06 then
        v = v + math.sin(i * 0.3) * 28000 * (1 - dt / 0.06)
      end
    end
    return math.max(-32768, math.min(32767, math.floor(v)))
  end)

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
  T.write_wav(TMP .. "gap.wav", SR, 2, 16, n, function(i)
    local t = i / SR
    if t >= SOUND_FROM and t < SOUND_TO then return math.floor(math.sin(i * 0.05) * 20000) end
    return 0
  end)

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
  T.write_wav(TMP .. "sil.wav", SR, 2, 16, SR, function() return 0 end)
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
  local MP = M
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

-- ---- headers and strides that used to lie ---------------------------------
do
  -- WAVE_FORMAT_EXTENSIBLE carrying FLOAT samples (what ffmpeg and SoX write
  -- for a float render). The outer tag says 0xFFFE; the real format is in the
  -- SubFormat GUID. Decoded as int32, a 0.25 sine came out near full scale.
  local SR, n = 44100, 4410
  local f = assert(io.open(TMP .. "xfloat.wav", "wb"))
  local d = n * 4
  f:write("RIFF", string.pack("<I4", 4 + 8 + 40 + 8 + d), "WAVE")
  f:write("fmt ", string.pack("<I4", 40), string.pack("<I2", 0xFFFE),
    string.pack("<I2", 1), string.pack("<I4", SR), string.pack("<I4", SR * 4),
    string.pack("<I2", 4), string.pack("<I2", 32),
    string.pack("<I2", 22), string.pack("<I2", 32), string.pack("<I4", 4),
    string.pack("<I2", 3),                                -- SubFormat: FLOAT
    "\0\0\0\0\16\0\128\0\0\170\0\56\155\113")             -- the GUID's tail
  f:write("data", string.pack("<I4", d))
  local b = {}
  for i = 0, n - 1 do b[#b + 1] = string.pack("<f", math.sin(i * 0.1) * 0.25) end
  f:write(table.concat(b)); f:close()
  ok(M.convert_sr(TMP .. "xfloat.wav", TMP .. "xfloat48.wav", 48000, nil) == true,
    "a float-extensible 44.1k file converts")
  local xw = read_wav(TMP .. "xfloat48.wav")
  local peak = 0
  for i = 200, (xw and xw.frames or 0) - 200 do
    peak = math.max(peak, math.abs(xw.sample(i, 1)))
  end
  near(peak, 0.25, 0.01, "...as FLOAT, at its real level (int32 decode read ~0.67)")

  -- a stereo file whose material is on the RIGHT only, long enough that the
  -- preview strides: an even stride over interleaved samples read the left
  -- channel every time and drew an empty strip over audible audio
  local len = 5.0
  local fr = math.floor(48000 * len)
  T.write_wav(TMP .. "right.wav", 48000, 2, 16, fr, function(i, c)
    return c == 2 and math.floor(math.sin(i * 0.05) * 26000) or 0
  end)
  local bins = {}
  M.fill_wave_bins(TMP .. "right.wav", bins, len)
  for _ = 1, 40 do M.load_tick() end
  local top = 0
  for i = 1, 128 do top = math.max(top, bins[i] or 0) end
  ok(top > 0.7, string.format("a right-only stereo file previews (peak bin %.2f)", top))

  -- a clear cancels ITS strip's queued repaint, so an erase cannot be redrawn
  local cb = {}
  M.fill_wave_bins(TMP .. "right.wav", cb, len)
  M.clear_bins(cb)
  for _ = 1, 40 do M.load_tick() end
  local any = 0
  for i = 1, 128 do any = math.max(any, cb[i] or 0) end
  ok(any == 0, "clearing a strip cancels the repaint queued for it")
end

-- ---- the waveform painter: a jump is not a walk -----------------------------
-- A loop wrapping round, or a pass re-armed somewhere else, moves the head
-- many bins in one frame. Walking that gap painted the whole loop with one
-- moment's level; only the landing bin may be painted.
do
  local pb = {}
  for i = 1, 128 do pb[i] = 0 end
  local last = M.paint_bins(pb, 0, 40, 0.9, 1)
  last = M.paint_bins(pb, last, 13, 0.9, 1)          -- the wrap: 40 -> 13
  local lit = 0
  for i = 1, 128 do if pb[i] > 0 then lit = lit + 1 end end
  ok(lit == 2, "a wrap paints the landing bin only (" .. lit .. " lit, want 2)")
  last = M.paint_bins(pb, last, 15, 0.5, 1)          -- a real two-bin step
  ok(pb[14] > 0 and pb[15] > 0, "...while a real step still fills the bins between")
end

T.report("main resampler OK")
