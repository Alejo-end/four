-- mpages: the screen — wave/twave display models, every page body, header,
-- footer, and the redraw composition. (the bitmap mockups are the bible:
-- same font, same geometry.)
--
-- layout: header y0..10  (title 2x pixel font, ALT chip, page dots, status)
--         body   y12..41 (per-page visualization)
--         footer y44..63 (labels row, then the hardware row mirroring the
--                         panel: E2 dial . K2 pill . K3 pill . E3 dial)
-- values are not parked in the footer: turning an encoder flashes the value
-- top-right for a second (like the mockup readouts), then it gets out of
-- the way.

local floor, sin, cos = math.floor, math.sin, math.cos
local abs, sqrt, min, max = math.abs, math.sqrt, math.min, math.max
local log, exp = math.log, math.exp

local C     -- shared ctx, bound at init
local pget, clamp, window_bounds, FPS, PAGES
local ptext, ptext_c, ptext_r, chip, text_w
local amp_in, amp_out

-- waveform display: 128 amplitude bins over the buffer, filled as the write
-- head passes; pre_level decides how much of the old picture survives overdub
local wave = {}
for i = 1, 128 do wave[i] = 0 end
local wave_bin = 0

-- same idea for the tape loop: bins indexed by the tape head while recording
local twave = {}
for i = 1, 128 do twave[i] = 0 end
local twave_bin = 0

-- paint amplitude into display bins between the last-seen head position and
-- the current one, walking the SHORTER way around the (circular) buffer —
-- so bins skipped between frames at high rates get filled, wrap-around is
-- seamless, and reverse playback paints in the right direction. entering a
-- fresh bin, previous content survives by `pre` (the overdub picture).
local function paint_bins(bins, last, bin, amp, pre)
  if last == 0 or last == bin then
    bins[bin] = max(bins[bin], amp)
    return bin
  end
  local fwd = (bin - last) % 128
  local bwd = (last - bin) % 128
  local step = (fwd <= bwd) and 1 or -1
  local b = last
  repeat
    b = ((b - 1 + step) % 128) + 1
    bins[b] = max(bins[b] * pre, amp)
  until b == bin
  return bin
end
local M = {}
M.paint_bins = paint_bins   -- the layer decks paint their own pictures

-- track the buffer's contents as the write head passes over it
function M.update_wave()
  if pget("rec", 0) == 1 and pget("freeze", 0) == 0 then
    local bin = floor(clamp(C.rec_phase, 0, 0.999) * 128) + 1
    if C.rec_amp > 0.01 then C.wave_any = true end
    wave_bin = paint_bins(wave, wave_bin, bin, C.rec_amp, pget("pre_level", 0))
  end
end

-- track the tape loop's contents as the head records (input amplitude,
-- since softcut exposes no per-voice output meter); tape_pre sets survival
function M.update_tape_wave()
  if pget("tape_rec", 0) == 1 and pget("tape_freeze", 0) == 0 then
    local bin = floor(clamp(C.tape_phase, 0, 0.999) * 128) + 1
    -- meter what softcut actually records (C.cut_rec_amp — the ADC tap, the
    -- engine output, or the blend): a WET print otherwise painted nothing
    -- and left twave_any false over audible tape
    local a = C.cut_rec_amp()
    if a > 0.01 then C.twave_any = true end
    twave_bin = paint_bins(twave, twave_bin, bin, a, pget("tape_pre", 0))
  end
end

-- wipe the tape picture (the CLR gesture starts the loop over)
-- the async fill queue lives up here so the clear functions can cancel their
-- own strip's fill (a CLR must stop the very repaint that would redraw what
-- it just erased — and ONLY that one, not another strip's fill in flight)
local fills = {}
local BINS_PER_TICK = 10
local function cancel_fill(bins)
  for i = #fills, 1, -1 do
    if fills[i].bins == bins then
      pcall(function() fills[i].f:close() end)
      table.remove(fills, i)
    end
  end
end
local function cancel_all_fills()
  for i = #fills, 1, -1 do
    pcall(function() fills[i].f:close() end)
    fills[i] = nil
  end
end

function M.clear_twave()
  cancel_fill(twave)
  for i = 1, 128 do twave[i] = 0 end
  twave_bin = 0
  C.twave_any = false
end

-- wipe the engine's picture (the engine `clear` command): the buffer is gone, so the strip
-- must go with it — every page that draws the take goes back to inviting one.
function M.clear_wave()
  cancel_fill(wave)   -- stop an in-flight TAKE fill first
  for i = 1, 128 do wave[i] = 0 end
  wave_bin = 0
  C.wave_any = false
end

-- paint the wave display straight out of a FILE (the engine `read_file`).
-- lua cannot read the engine's SC buffer, so a loaded sample would otherwise be
-- INVISIBLE on every page that draws the take — REC/WINDOW/PADS would sit there
-- saying "EMPTY - K2 REC" over audio you can hear. so we read the file's peaks
-- ourselves.
-- seek-and-peak: 128 bins, a small window sampled at each (~128KB touched, not
-- the whole 11MB), so a load never stalls the script.
-- 16-bit PCM wav only (what norns records and what dust ships). anything else
-- returns nil and the caller leaves the display alone rather than draw a lie.
-- returns: the seconds the sample occupies IN THE BUFFER, or nil.
-- async waveform read: the FAST part (header → dur, window, wave_any) runs now
-- and RETURNS immediately; the slow per-bin peak read is deferred to load_tick
-- (BINS_PER_TICK bins/frame on the redraw clock) so a long take/sample load
-- draws IN over ~1s instead of freezing the screen. ONE queue serves every
-- strip — the take, the tape, the layer decks — so a pset restore can repaint
-- all of them; a new fill for the SAME bins table supersedes the queued one,
-- and fills for different targets coexist. File handles live on the queue
-- entries until each fill finishes (the queue itself is declared above the
-- clear functions, which cancel per-strip).

-- walk a RIFF/WAVE file to its fmt + data chunks, leaving f positioned at the
-- data. returns afmt, ch, bits, sr, dpos, dlen — or nil if not RIFF/WAVE. shared
-- by load_wave (the preview) and open_pcm16_mono (the Phase B export).
local function riff_parse(f)
  local hdr = f:read(12)
  if not hdr or #hdr < 12 or hdr:sub(1, 4) ~= "RIFF" or hdr:sub(9, 12) ~= "WAVE" then
    return nil
  end
  local afmt, ch, bits, sr, dpos, dlen = 1, 1, 16, 48000, nil, 0
  while true do
    local c = f:read(8)
    if not c or #c < 8 then break end
    local id, sz = c:sub(1, 4), string.unpack("<I4", c, 5)
    if id == "fmt " then
      local fmt = f:read(sz)
      if not fmt or #fmt < 16 then break end
      afmt = string.unpack("<I2", fmt, 1)     -- 1 = PCM int, 3 = IEEE float
      ch = string.unpack("<I2", fmt, 3)
      sr = string.unpack("<I4", fmt, 5)
      bits = string.unpack("<I2", fmt, 15)
    elseif id == "data" then
      dpos, dlen = f:seek(), sz
      break
    else
      f:seek("cur", sz + (sz % 2))            -- riff chunks are word-aligned
    end
  end
  return afmt, ch, bits, sr, dpos, dlen
end

-- one SIGNED sample decoder per (format, bit depth). 16/24/32-bit PCM and
-- 32-bit float are what norns itself can produce — the engine's take dump, the
-- system tape's print, and whatever a performer drops in — so this covers all
-- of it. ONE table: the waveform preview and the sample-rate converter below
-- read the same files, and a second copy would mean a format could draw
-- correctly and convert to noise, or the reverse.
local DECODE = {
  [1] = {
    [16] = function(s, p) return string.unpack("<i2", s, p) / 32768 end,
    [24] = function(s, p) return string.unpack("<i3", s, p) / 8388608 end,
    [32] = function(s, p) return string.unpack("<i4", s, p) / 2147483648 end,
  },
  [3] = {
    [32] = function(s, p) return string.unpack("<f", s, p) end,
  },
}

-- WAVE_FORMAT_EXTENSIBLE is PCM of the stated depth (the common 24-bit case;
-- the rare float-extensible falls through to "unsupported", which callers read
-- as "no preview" / "refuse to convert" rather than drawing or writing a lie).
function M.wav_decoder(afmt, bits)
  if afmt == 0xFFFE then afmt = 1 end
  return DECODE[afmt] and DECODE[afmt][bits]
end

-- open `path` and queue an async fill of `bins`: 128 peak bins spanning
-- `secs` seconds, so a file shorter than the span occupies only its share of
-- the strip (the engine clamps its reads the same way — a longer file only
-- occupies `secs` of the buffer, and drawing more would misalign every
-- playhead and slice). supersedes any queued fill of the SAME bins table.
-- returns the seconds the file occupies, or nil for a format the shared
-- decoders cannot read (the caller leaves the strip alone rather than lie).
local function queue_fill(path, bins, secs)
  cancel_fill(bins)
  local f = io.open(path, "rb")
  if not f then return nil end
  local afmt, ch, bits, _, dpos, dlen = riff_parse(f)
  if not afmt then f:close(); return nil end
  local readpeak = M.wav_decoder(afmt, bits)
  if not dpos or ch < 1 or not readpeak then
    f:close()
    return nil
  end
  local bps = bits // 8
  local fbytes = ch * bps
  local SR = C.SERVER_SR
  local frames = min(floor(dlen / fbytes), floor(SR * secs))
  local span = clamp(frames / (SR * secs), 0, 1)
  local nb = max(1, floor(span * 128 + 0.5))
  -- hand the slow per-bin peak read to load_tick (below). stride the UNPACKS
  -- (not the disk read) so a transient is never skipped — a 40ms drum hit
  -- vanished when this sampled a few windows per bin instead.
  local stride = max(1, floor(frames * ch / 200000))
  if nb >= 1 and frames > 0 then
    fills[#fills + 1] = { f = f, dpos = dpos, fbytes = fbytes, frames = frames,
      nb = nb, bps = bps, step = stride * bps, readpeak = readpeak, i = 0,
      bins = bins }
  else
    f:close()
  end
  return frames / SR
end

-- the TAKE's preview: clear the strip FIRST, so an unsupported-format /
-- unreadable early return leaves a flat strip instead of the previous take's
-- waveform; a 24-bit drop-in draws + windows correctly via the shared decoder
-- (the bug this once had for everything except 16-bit).
function M.load_wave(path, buf_secs)
  for i = 1, 128 do wave[i] = 0 end
  wave_bin = 0
  local dur = queue_fill(path, wave, buf_secs)
  if dur ~= nil then C.wave_any = dur > 0 end
  return dur
end

-- fill an ARBITRARY 128-bin strip from a wav — the layer decks own their bins
-- and hand them here when a pset restores their audio (lua cannot read the
-- softcut buffer, but the wav it was restored FROM is right there; without
-- this a restored loop played audibly under a blank picture).
function M.fill_wave_bins(path, bins, secs)
  for i = 1, 128 do bins[i] = 0 end
  return queue_fill(path, bins, secs)
end

-- the tape strip's version of the same (mpages owns twave)
function M.repaint_twave(path, secs)
  twave_bin = 0
  return M.fill_wave_bins(path, twave, secs)
end

-- fill up to BINS_PER_TICK bins of the queue's HEAD per call (driven by the
-- redraw clock), then close its file and move on. bounded work per frame →
-- the reads never block the UI; each strip draws IN over ~nb/10 frames.
function M.load_tick()
  local p = fills[1]
  if not p then return end
  local bins = p.bins
  local last = min(p.i + BINS_PER_TICK, p.nb)
  for i = p.i + 1, last do
    local b0 = floor((i - 1) / p.nb * p.frames)
    local n = floor(i / p.nb * p.frames) - b0
    local peak = 0
    if n > 0 then
      p.f:seek("set", p.dpos + b0 * p.fbytes)
      local chunk = p.f:read(n * p.fbytes)
      if chunk then
        for pp = 1, #chunk - (p.bps - 1), p.step do
          -- magnitude: the decoder is signed, the strip wants height
          local v = p.readpeak(chunk, pp)
          if v < 0 then v = -v end
          if v > peak then peak = v end
        end
      end
    end
    bins[i] = peak > 1 and 1 or peak
  end
  p.i = last
  if p.i >= p.nb then p.f:close(); table.remove(fills, 1) end
end

-- cancel EVERY in-flight fill (script cleanup)
function M.cancel_load() cancel_all_fills() end

-- ============================================================================
-- sample-rate conversion
-- ============================================================================
-- scsynth's Buffer:readChannel does NO sample-rate conversion and norns runs
-- its server at 48k, so a 44.1k wav — which is most of dust/audio and nearly
-- everything off a card — lands in the take buffer playing 8.8% fast, a
-- semitone and change sharp, with every pad, slice and window inheriting the
-- error. This converts a file to the server rate first.
--
-- It is deliberately here in lua and not in the engine: no new SC command, no
-- fingerprint change, no restart, and it yields so the screen stays live.
-- Catmull-Rom cubic, the same kernel a good sampler uses for varispeed.
local function cubic(y0, y1, y2, y3, x)
  local a = -0.5 * y0 + 1.5 * y1 - 1.5 * y2 + 0.5 * y3
  local b = y0 - 2.5 * y1 + 2 * y2 - 0.5 * y3
  local c = -0.5 * y0 + 0.5 * y2
  return ((a * x + b) * x + c) * x + y1
end

-- open a file for random-access frame reads. nil for anything we cannot
-- decode, so a caller refuses rather than working on silence.
local function open_src(path)
  local f = io.open(path, "rb")
  if not f then return nil, "cannot open " .. tostring(path) end
  local afmt, ch, bits, sr, dpos, dlen = riff_parse(f)
  local dec = afmt and M.wav_decoder(afmt, bits)
  if not (dec and dpos and ch and ch >= 1 and sr and sr > 0) then
    f:close(); return nil, "unsupported format"
  end
  local bps = bits // 8
  local fbytes = ch * bps
  return { f = f, dpos = dpos, ch = ch, bps = bps, fbytes = fbytes, sr = sr,
           dec = dec, frames = floor(dlen / fbytes), path = path }
end

local function close_src(s) if s and s.f then s.f:close(); s.f = nil end end

-- read n frames from `from` into L/R (1-based), zero-padding outside the file
-- so an interpolator may always ask for a neighbour it cannot have.
local function read_frames(src, from, n, L, R)
  local a, b = max(from, 0), min(from + n, src.frames)
  for i = 1, a - from do L[i], R[i] = 0, 0 end
  for i = max(1, b - from + 1), n do L[i], R[i] = 0, 0 end
  if b <= a then return end
  src.f:seek("set", src.dpos + a * src.fbytes)
  -- a file can be SHORTER than its header claims (a truncated copy, an
  -- interrupted write): a short read must still honour the zero-pad contract
  -- above, or a caller indexes nil exactly where the data chunk lied
  local chunk = src.f:read((b - a) * src.fbytes) or ""
  local dec, ch, bps, fb = src.dec, src.ch, src.bps, src.fbytes
  local o = a - from
  local got = #chunk // fb
  for i = 0, got - 1 do
    local p = i * fb + 1
    local l = dec(chunk, p)
    L[o + i + 1] = l
    R[o + i + 1] = ch > 1 and dec(chunk, p + bps) or l
  end
  for i = o + got + 1, b - from do L[i], R[i] = 0, 0 end
end

local SRC_BLOCK = 4096
local SRC_PACK = "<" .. string.rep("i2", SRC_BLOCK * 2)

-- returns true, seconds  — converted and written to out_path
--         false, seconds — already at `sr`, nothing written
--         nil, err       — could not decode (the caller falls back to loading
--                          the file as-is: audible-but-sharp beats silence)
-- the declared sample rate of a wav, without decoding a byte of it. nil for
-- anything that is not a readable RIFF/WAVE.
function M.wav_rate(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local afmt, _, _, sr = riff_parse(f)
  f:close()
  if not afmt or not sr or sr <= 0 then return nil end
  return sr
end

function M.convert_sr(path, out_path, sr, yield, max_secs)
  local src, err = open_src(path)
  if not src then return nil, err end
  local in_sr, frames = src.sr, src.frames
  if frames < 2 then close_src(src); return nil, "no audio" end
  -- refuse an implausible declared rate HERE, not just via the caller's cap:
  -- a corrupt header claiming 1 Hz turns a 4800-frame file into 230M output
  -- frames, and an opt-in cap is protection a future caller forgets (the
  -- caller falls back to loading the file as-is, which is bounded)
  if in_sr < 4000 or in_sr > 384000 then
    close_src(src); return nil, "implausible sample rate " .. tostring(in_sr)
  end
  if in_sr == sr then close_src(src); return false, frames / sr end

  local of = io.open(out_path, "wb")
  if not of then close_src(src); return nil, "cannot write " .. tostring(out_path) end
  -- header with placeholder sizes, backpatched at the end
  of:write("RIFF", string.pack("<I4", 36), "WAVE")
  of:write("fmt ", string.pack("<I4", 16), string.pack("<I2", 1),
    string.pack("<I2", 2), string.pack("<I4", sr), string.pack("<I4", sr * 4),
    string.pack("<I2", 4), string.pack("<I2", 16))
  of:write("data", string.pack("<I4", 0))

  local ratio = in_sr / sr
  local out_n = floor(frames / ratio)
  -- bound the OUTPUT, not just the input: the take buffer only holds max_secs
  -- anyway, and without this a corrupt header declaring a tiny rate expands a
  -- small file into gigabytes (4800 frames at a claimed 1 Hz = 921 MB out) —
  -- while a long DJ mix converts minutes of audio the buffer would discard
  if max_secs then out_n = min(out_n, floor(sr * max_secs)) end
  local L, R = {}, {}
  local out_v = {}
  local written, since = 0, 0
  while written < out_n do
    local bn = min(SRC_BLOCK, out_n - written)
    local p0 = written * ratio
    local p1 = (written + bn - 1) * ratio
    local lo = floor(p0) - 1
    local hi = floor(p1) + 3
    read_frames(src, lo, hi - lo + 1, L, R)
    for k = 0, bn - 1 do
      local pos = (written + k) * ratio
      local ip = floor(pos)
      local fr = pos - ip
      local j = ip - lo + 1
      local vl = cubic(L[j - 1] or 0, L[j] or 0, L[j + 1] or 0, L[j + 2] or 0, fr)
      local vr = cubic(R[j - 1] or 0, R[j] or 0, R[j + 1] or 0, R[j + 2] or 0, fr)
      vl = vl * 32767
      if vl > 32767 then vl = 32767 elseif vl < -32768 then vl = -32768 end
      vr = vr * 32767
      if vr > 32767 then vr = 32767 elseif vr < -32768 then vr = -32768 end
      out_v[k * 2 + 1] = floor(vl + 0.5)
      out_v[k * 2 + 2] = floor(vr + 0.5)
    end
    local fmt = bn == SRC_BLOCK and SRC_PACK or ("<" .. string.rep("i2", bn * 2))
    of:write(string.pack(fmt, table.unpack(out_v, 1, bn * 2)))
    written = written + bn
    since = since + 1
    if yield and since >= 4 then since = 0; yield() end
  end

  local datalen = written * 4
  of:seek("set", 4);  of:write(string.pack("<I4", 36 + datalen))
  of:seek("set", 40); of:write(string.pack("<I4", datalen))
  close_src(src); of:close()
  return true, written / sr
end

-- WHERE THE SOUND ACTUALLY IS. Returns the first and last positions above a
-- threshold, as fractions of a `buf_secs` buffer — the same units the window
-- uses. nil when the file cannot be read, or when nothing clears the floor
-- (silence), so a caller can tell "nothing there" from "could not look".
--
-- The point: pressing REC and then playing leaves your reaction time at the
-- head of every take, and letting go late leaves room tone at the tail. The
-- rec-stop window snaps to where the HEADS were, not to where the sound is.
function M.onset_bounds(path, from01, to01, buf_secs, thresh, yield)
  local src, err = open_src(path)
  if not src then return nil, err end
  local total = floor(buf_secs * src.sr)
  local from = clamp(floor(from01 * total), 0, src.frames)
  local to = clamp(floor(to01 * total), 0, src.frames)
  if to - from < 64 then close_src(src); return nil, "range is empty" end
  thresh = thresh or 0.004                       -- about -48 dBFS
  local L, R = {}, {}
  local CH = 8192
  local first, last = nil, nil
  local i = from
  while i < to do
    local n = min(CH, to - i)
    read_frames(src, i, n, L, R)
    for k = 1, n do
      local a = abs(L[k]); local b = abs(R[k])
      if a > thresh or b > thresh then
        if not first then first = i + k - 1 end
        last = i + k - 1
      end
    end
    i = i + n
    if yield then yield() end
  end
  close_src(src)
  if not first then return nil, "silence" end
  return first / total, (last + 1) / total
end

-- TRANSIENT DETECTION: where does the material actually start hitting?
-- A 10ms energy envelope; an onset is where energy jumps against its neighbour
-- and clears a floor. Energy tolerates a strided decode (a transient is
-- milliseconds wide, i.e. hundreds of frames), which is what keeps this
-- affordable on a Pi.
--
-- `from01`/`to01` bound the search as fractions of a `buf_secs` buffer, and the
-- cuts come back in the same units — so a caller works in the window's own
-- coordinates and never has to know the file's rate or length.
-- Returns nil (not an empty list) when the file cannot be read, so a caller can
-- tell "no transients here" from "could not look".
function M.transient_cuts(path, from01, to01, maxn, buf_secs, yield)
  local src, err = open_src(path)
  if not src then return nil, err end
  local total = floor(buf_secs * src.sr)
  local from = clamp(floor(from01 * total), 0, src.frames)
  local to = clamp(floor(to01 * total), 0, src.frames)
  if to - from < 64 then close_src(src); return nil, "range is empty" end

  local win = max(64, floor(src.sr * 0.01))
  local stride = 8
  local L, R, env = {}, {}, {}
  local i, k = from, 0
  while i < to do
    local n = min(win, to - i)
    read_frames(src, i, n, L, R)
    local e = 0
    for j = 1, n, stride do
      local a = abs(L[j]) + abs(R[j])
      if a > e then e = a end
    end
    k = k + 1
    env[k] = e * 0.5
    i = i + n
    if yield and (k % 32 == 0) then yield() end
  end
  close_src(src)

  -- floor: a fraction of the loudest window, so quiet material still chops and
  -- room tone does not
  local peak = 0
  for j = 1, k do if env[j] > peak then peak = env[j] end end
  local floorlv = peak * 0.18
  local cuts = { from01 }          -- the first slice always starts at the edge
  local last = -99
  for j = 2, k do
    local prev = env[j - 1]
    if env[j] > floorlv and env[j] > prev * 2.2 and (j - last) > 3 then
      last = j
      local f = from + (j - 1) * win
      cuts[#cuts + 1] = f / total
      if #cuts >= maxn then break end
    end
  end
  return cuts
end

-- interleave two 16-bit MONO wavs (the L/R pair write_take dumps)
-- into one stereo 16-bit wav — a browsable export that reloads via load sample,
-- ZERO new load code. Lua-only (no engine interleave). Returns true on success.
local function open_pcm16_mono(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local _, ch, bits, sr, dpos, dlen = riff_parse(f)
  if not dpos or bits ~= 16 or ch ~= 1 then f:close(); return nil end
  f:seek("set", dpos)
  return f, floor(dlen / 2), sr   -- handle, frames, sample rate
end

function M.interleave_wav(pathL, pathR, out, yield)
  local fL, nL, sr = open_pcm16_mono(pathL)
  if not fL then return false end
  local fR, nR = open_pcm16_mono(pathR)
  if not fR then fL:close(); return false end
  local frames = min(nL, nR)
  local of = io.open(out, "wb")
  if not of then fL:close(); fR:close(); return false end
  local datalen = frames * 4                      -- stereo 16-bit = 4 bytes/frame
  of:write("RIFF", string.pack("<I4", 36 + datalen), "WAVE")
  of:write("fmt ", string.pack("<I4", 16), string.pack("<I2", 1), string.pack("<I2", 2),
    string.pack("<I4", sr), string.pack("<I4", sr * 4), string.pack("<I2", 4), string.pack("<I2", 16))
  of:write("data", string.pack("<I4", datalen))
  local CHUNK = 8192                               -- frames per pass
  local i, since = 0, 0
  while i < frames do
    local n = min(CHUNK, frames - i)
    local lc, rc = fL:read(n * 2), fR:read(n * 2)
    if not lc or not rc or #lc < n * 2 or #rc < n * 2 then break end
    local buf = {}
    for p = 1, n * 2, 2 do
      buf[#buf + 1] = lc:sub(p, p + 1); buf[#buf + 1] = rc:sub(p, p + 1)
    end
    of:write(table.concat(buf))
    i = i + n
    since = since + 1
    if yield and since >= 8 then since = 0; yield() end   -- ~64k frames / yield
  end
  -- a short read means the declared header over-states the data; backpatch the
  -- RIFF + data sizes to what we actually wrote so the wav isn't malformed.
  if i < frames then
    local dl = i * 4
    of:seek("set", 4); of:write(string.pack("<I4", 36 + dl))
    of:seek("set", 40); of:write(string.pack("<I4", dl))
  end
  fL:close(); fR:close(); of:close()
  return true
end

-- deterministic dither, same trick as the mockups
local function hash(x, y, sd)
  local f = sin(x * 12.9898 + y * 78.233 + sd * 37.719) * 43758.5453
  return f - floor(f)
end

-- footer words per param id: the owning page's own vocabulary — these are
-- also the MOTION lane names, so a lane says what its page says
local SHORT = {
  mix = "MIX", out_level = "OUT", sc_level = "ENG", cut_level = "TAPE",
  input_level = "IN", monitor_level = "MON",
  rec_level = "LVL", pre_level = "OVR", dry_wet = "D/W", resample = "RSMP",
  regen = "REGN",
  pos_start = "ST", pos_end = "EN", pos_jitter = "JIT",
  ["@win_move"] = "MOV",
  scan = "SPEED", pitch = "PITCH",
  size = "SIZE", spread = "SPRD", density = "DENS", grain_level = "GRN",
  grain_jitter = "GJIT", grain_pitch_spread = "DTUN", grain_shape = "SHP",
  clouds_pos = "POS", clouds_tex = "TEX", clouds_fb = "FB", clouds_lofi = "LOFI",
  warp_window = "WIN", warp_rand = "RAND",
  tape_rate = "RATE", tape_pre = "PRE", loop_start = "STRT", loop_end = "LOOP",
  cut_source = "SRC",
  cutoff = "CUT", resonance = "RES", drive = "DRV",
  delay_mix = "ECHO", delay_time = "TIME", delay_fb = "FDBK",
  delay_sync = "SYNC",
  rev_size = "SIZE", rev_mix = "VERB",
  rev_decay = "DECAY", rev_damp = "DMP", rev_early = "DIFF",
  rev_moddepth = "MOD", rev_modfreq = "MRAT", rev_low = "LOW",
  rev_mid = "MID", rev_high = "HIGH", rev_lowcut = "LCUT", rev_highcut = "HCUT",
  shimmer = "SHMR", shimmer_pitch = "OCT", shimmer_tone = "AIR",
  voices = "VOX", voice_atk = "ATK", voice_rel = "REL",
  motion_lane = "LANE", motion_depth = "DPT", motion_len = "LEN",
  seq_slice = "SLICE", pad_pitch = "PTCH", pad_voice = "TYPE",
  pad_level = "PLVL",
  scene_slot = "SLOT", scene_morph_amt = "MRF", scene_recall_mode = "QNT",
  orbit_rate = "DRFT", orbit_reach = "RCH", erode = "ERO", wear = "WEAR",
  layer_sel = "LAYER",
  lay1_level = "L1 LV", lay1_rate = "L1 RT", lay1_reverse = "L1 REV",
  lay1_start = "L1 ST", lay1_end = "L1 EN", lay1_pre = "L1 DUB",
  lay2_level = "L2 LV", lay2_rate = "L2 RT", lay2_reverse = "L2 REV",
  lay2_start = "L2 ST", lay2_end = "L2 EN", lay2_pre = "L2 DUB",
  ["@lay_level"] = "LVL", ["@lay_rate"] = "RATE", ["@lay_move"] = "LOOP",
  -- nicer MOTION lane labels for params that aren't footer encoders (safe:
  -- SHORT is only read for the current page's enc ids + MOTION lane names)
  mode = "MODE", filt_type = "FILT", pan = "PAN", freeze = "FRZ",
  pv_freeze = "PVFZ", tape_freeze = "TFRZ", tape_reverse = "TREV",
  clouds_mode = "CMOD",
}

-- the FULL word for a footer encoder label. shown at REST (no assumptions —
-- you read "START", not "ST"); the SHORT form above takes over only while the
-- value is up (turning, or a selector), where the digits need the room. a full
-- word that would collide with the key words falls back to SHORT (flabel_r).
local FULL = {
  mix = "MIX", out_level = "OUT", sc_level = "ENGINE", cut_level = "TAPE",
  input_level = "INPUT", monitor_level = "MONITOR",
  rec_level = "LEVEL", pre_level = "OVER", dry_wet = "DRY/WET", resample = "RESAMPLE",
  regen = "REGEN",
  pos_start = "START", pos_end = "END", pos_jitter = "JITTER",
  ["@win_move"] = "MOVE",
  scan = "SPEED", pitch = "PITCH",
  size = "SIZE", spread = "SPREAD", density = "DENSITY", grain_level = "GRAIN",
  clouds_pos = "POSITION", clouds_tex = "TEXTURE", clouds_fb = "FEEDBACK",
  clouds_lofi = "LOFI",
  warp_window = "WINDOW", warp_rand = "RANDOM",
  tape_rate = "RATE", tape_pre = "PRE", loop_start = "START", loop_end = "LOOP",
  cut_source = "SOURCE",
  cutoff = "CUTOFF", resonance = "RESO", drive = "DRIVE",
  delay_mix = "ECHO", delay_time = "TIME", delay_fb = "FEEDBACK",
  delay_sync = "SYNC",
  rev_size = "SIZE", rev_mix = "REVERB",
  rev_decay = "DECAY", rev_damp = "DAMP",
  shimmer = "SHIMMER", shimmer_pitch = "OCT", shimmer_tone = "AIR",
  voices = "VOICES", voice_atk = "ATTACK", voice_rel = "RELEASE",
  motion_lane = "LANE", motion_depth = "DEPTH", motion_len = "LENGTH",
  seq_slice = "SLICE", pad_pitch = "PITCH", pad_voice = "VOICE",
  scene_slot = "SLOT", scene_morph_amt = "MORPH", scene_recall_mode = "QUANT",
  orbit_rate = "DRIFT", orbit_reach = "REACH", erode = "ERODE", wear = "WEAR",
  layer_sel = "LAYER",
  ["@lay_level"] = "LEVEL", ["@lay_rate"] = "RATE", ["@lay_move"] = "LOOP",
}

-- normalized 0..1 of a value for a param: controlspec unmap, option index,
-- or number range. plots the MOTION lanes' events at their captured heights.
local function value_norm(id, v)
  local p = params.lookup[id] and params:lookup_param(id)
  if not p then return 0 end
  if p.controlspec then return clamp(p.controlspec:unmap(v), 0, 1)
  elseif p.count then return p.count > 1 and (v - 1) / (p.count - 1) or 0
  elseif p.min and p.max and p.max > p.min then return (v - p.min) / (p.max - p.min) end
  return clamp(v, 0, 1)
end

-- the LIVE value's normalized position (compound "@" targets resolve first)
local function param_norm(id)
  if id and C.enc_target then id = C.enc_target(id) end
  if not (id and params.lookup[id]) then return nil end
  return value_norm(id, params:get(id))
end

-- footer value text for a param: compact, ALL-CAPS abbreviations. a few
-- ids get hand-tuned units (cutoff kHz, pitch semitones, rates x, times);
-- a plain 0..1 linear control reads as a percentage; everything else falls
-- back to the norns string.
local RATE_IDS = { scan = true, tape_rate = true,
                   lay1_rate = true, lay2_rate = true }
local function fmt_value(id)
  -- compound encoder targets ("@") read as their anchor param
  if id and C.enc_target then id = C.enc_target(id) end
  if not (id and params.lookup[id]) then return "--" end
  if id == "seq_slice" then
    return tostring(floor(params:get(id) + 0.5) + 1)   -- slices read 1..8
  end
  if id == "scene_slot" then
    local v = floor(params:get(id) + 0.5)
    return v < 1 and "<" or tostring(v)                -- 0 = the ◄ cell
  end
  if id == "motion_lane" then
    -- show the SELECTED lane's param name (or "-" when none picked)
    local ids = C.motion and C.motion.lane_ids
    local n = ids and #ids or 0
    local sel = clamp(floor(params:get(id) + 0.5), 0, n)
    if n == 0 or sel == 0 then return "-" end
    return SHORT[ids[sel]] or string.upper(ids[sel])
  end
  if id == "motion_len" then
    local v = params:get(id)
    return v < 0.05 and "AUTO" or string.format("%.1fS", v)
  end
  if id == "cut_source" then                    -- tape source: DRY .. WET blend
    local v = params:get(id)
    if v < 0.02 then return "DRY" end
    if v > 0.98 then return "WET" end
    return floor(v * 100 + 0.5) .. "%"
  end
  if id == "cutoff" or id == "rev_lowcut" or id == "rev_highcut"
      or id == "shimmer_tone" then
    local v = params:get(id)
    return v >= 1000 and string.format("%.1fKHZ", v / 1000)
      or string.format("%dHZ", floor(v + 0.5))
  elseif id == "shimmer_pitch" then
    local v = floor(params:get(id) + 0.5)
    return (v >= 0 and "+" or "") .. v .. "ST"
  elseif id == "rev_decay" then
    return string.format("%.1fS", params:get(id))
  elseif id == "rev_modfreq" then
    return string.format("%.1fHZ", params:get(id))
  elseif id == "rev_size" then
    return string.format("%.1f", params:get(id))
  elseif id == "pitch" then
    local st = floor(12 * log(params:get(id)) / log(2) + 0.5)
    return (st >= 0 and "+" or "") .. st .. "ST"
  elseif RATE_IDS[id] then
    return string.format("%+.2fX", params:get(id))
  elseif id == "delay_time" then
    local v = params:get(id)
    return v >= 0.9995 and string.format("%.2fS", v)
      or string.format("%dMS", floor(v * 1000 + 0.5))
  elseif id == "size" or id == "voice_atk" then
    local v = params:get(id)
    return v >= 1 and string.format("%.1fS", v)
      or string.format("%dMS", floor(v * 1000 + 0.5))
  elseif id == "density" or id == "voices" then
    return tostring(floor(params:get(id) + 0.5))
  end
  local p = params:lookup_param(id)
  local cs = p.controlspec
  if cs and cs.minval and cs.maxval and cs.minval >= 0 and cs.maxval <= 1 then
    return string.format("%d%%", floor(params:get(id) * 100 + 0.5))
  end
  return string.upper(params:string(id))
end

-- is this param the one currently being turned? (drives the footer knob
-- fill; the window is armed in the encoder handler, ~1.2s)
local function is_turning(id)
  return id ~= nil and C.flash_id == id and C.frame < C.flash_until
end

-- selector pages are the one exception to numbers-only-while-turning:
-- the selection IS the state, so it reads at rest (SLICE·3, LANE·…)
local SELECTOR_IDS = {
  seq_slice = true, motion_lane = true, scene_slot = true, layer_sel = true,
}

local FY = 58  -- the footer text row (four quiet words)

-- one key word: rest = dim text, engaged (latched or held) = inverted chip.
-- def.lit() is the truth; a punched key reads identical while the finger is
-- down and reverts on release — the whole temporary/latched language.
local function fkey_draw(n, x)
  local def = C.key_def(n)
  local lab = def and def.label or "--"
  if def and def.dryerase and C.k13_frame
      and C.frame - C.k13_frame >= 2 and C.page_erase() then
    ptext("ERASE", x, FY, 1, 15)   -- the tap became the eraser
    return text_w("ERASE", 1)
  end
  local on = false
  if def then
    if def.lit and def.lit() then on = true end
    if C.held[n] and not def.dryerase then on = true end
  end
  local w = text_w(lab, 1)
  if on then
    screen.level(15)
    screen.rect(x - 2, 56, w + 5, 8)
    screen.fill()
    ptext(lab, x, FY, 1, 0)
  else
    ptext(lab, x, FY, 1, 6)
  end
  return w
end

-- one encoder word, right-anchored: WORD· — the FULL word at rest (no
-- assumptions), the SHORT form only while the value is up (turning, or a
-- selector). the value itself exists only while you're asking (the 1.2s swell),
-- or always on the selector pages. minx is the key words' right edge: a full
-- word that would cross it drops to the abbreviation so the row never overlaps.
-- hoisted out of flabel_r so the draw path allocates no per-frame closures
local function label_for(id, full)
  if not id then return "--" end
  if full then return FULL[id] or SHORT[id] or string.upper(id) end
  return SHORT[id] or "--"
end
local function label_total(l, val) return text_w(l, 1) + 3 + (val and text_w(val, 1) or 0) end
local function flabel_r(id, rx, minx)
  local turning = is_turning(id)
  -- the footer layout is ALWAYS the at-rest layout: a turning knob only
  -- brightens its word, never widens or moves it, so the neighbor word
  -- stays exactly where it was. the live value shows in the big readout
  -- box instead (draw_footer). selectors keep their small value at rest.
  local val = id and SELECTOR_IDS[id] and fmt_value(id) or nil
  local full = not val
  local lab = label_for(id, full)
  local lvl = turning and 15 or 6
  local x = rx - label_total(lab, val)
  if full and minx and x < minx then
    -- a full word that would cross the key words drops to SHORT
    lab = label_for(id, false)
    x = rx - label_total(lab, val)
  end
  ptext(lab, x, FY, 1, lvl)
  screen.level(lvl)
  screen.rect(x + text_w(lab, 1) + 1, FY + 2, 1, 1)
  screen.fill()
  if val then ptext(val, x + text_w(lab, 1) + 3, FY, 1, lvl) end
  return x
end

-- the big readout: while a knob turns, its value draws at double size in a
-- framed black box just above the footer, right-anchored. the footer never
-- changes shape; this box carries the number and vanishes with the swell.
local function draw_big_value()
  local tid
  local e2, e3 = C.enc_param(2), C.enc_param(3)
  if is_turning(e2) then tid = e2
  elseif is_turning(e3) then tid = e3 end
  if not tid then return end
  local v = fmt_value(tid)
  local w = text_w(v, 2) + 9
  local bx = 126 - w
  screen.level(0)
  screen.rect(bx, 41, w + 2, 15)
  screen.fill()
  screen.level(12)
  screen.rect(bx, 41, w + 2, 15)
  screen.stroke()
  ptext(v, bx + 5, 44, 2, 15)
end

-- footer: K2 K3 | E2· E3· — four quiet words that never lie about the keys
local function draw_footer()
  local x = 2
  if C.alt then                       -- the shift bar: K1 is held
    screen.level(15)
    screen.rect(0, 57, 2, 6)
    screen.fill()
    x = 5
  end
  local w = fkey_draw(2, x)
  x = x + w + 9
  w = fkey_draw(3, x)
  local keys_right = x + w + 4     -- the key words' right edge (labels clear it)
  -- the erase hold-arc beside the K3 word (only where material exists)
  if C.alt and C.k13_frame and C.page_erase() then
    local dt = C.frame - C.k13_frame
    if dt >= 2 then
      local ax, ay = x + w + 8, FY + 2
      local frac = clamp(dt / C.ERASE_FRAMES, 0, 1)
      screen.level(4)
      for a = 0, 2 * math.pi, 0.22 do
        screen.rect(ax + cos(a) * 3.2, ay + sin(a) * 3.2, 1, 1)
      end
      screen.fill()
      screen.level(15)
      local a = -math.pi / 2
      local a1 = -math.pi / 2 + 2 * math.pi * frac
      while a < a1 do
        screen.rect(ax + cos(a) * 3.2, ay + sin(a) * 3.2, 1, 1)
        a = a + 0.1
      end
      screen.fill()
    end
  end
  local e3x = flabel_r(C.enc_param(3), 126, keys_right)
  flabel_r(C.enc_param(2), e3x - 9, keys_right)
  draw_big_value()
end

-- ============================================================================
-- the nine dominant objects (doc/redesign.md §6)
-- ============================================================================
-- one object per page, drawn from REAL state, brightness riding audibility.
-- statics first: everything the 15fps hot path needs preallocated.

-- FILTER: log-frequency axis 20Hz..20kHz over 128 columns, rail columns at
-- 100Hz/1k/10k (labeled), the 0dB row, and a reusable response buffer (the
-- curve is the engine's REAL biquad magnitude — constants mirror the engine, keep in sync
-- with Engine_Mangler.sc)
local FILT_FREQ, FILT_Y = {}, {}
for x = 0, 127 do
  FILT_FREQ[x + 1] = 20 * (1000 ^ (x / 127))
  FILT_Y[x + 1] = 0
end
local FILT_GRID_X, FILT_GRID_LBL = {}, { "100", "1K", "10K" }
for i, f in ipairs({ 100, 1000, 10000 }) do
  FILT_GRID_X[i] = floor(log(f / 20) / log(1000) * 127 + 0.5)
end
local FILT_TOP, FILT_BOT = 14, 46
local FILT_DB_TOP, FILT_DB_RANGE = 18, 48
local FILT_DB0_Y = floor(FILT_TOP
  + FILT_DB_TOP * (FILT_BOT - FILT_TOP) / FILT_DB_RANGE + 0.5)

-- MIX: master/input peak-hold pips (slow decay, static state)
local vu_peak = { 0, 0 }
local vu_last_frame = -1

-- PADS: per-pad "a voice is sounding" flags, refilled each frame
local pad_lit = {}

-- ============================================================================
-- 1 · TAKE — the material (one strip: recorded bright, unwritten dotted,
--     window brackets inside; write head + seconds + ready-bracket while
--     armed; hatched while marked by the erase arc)
-- ============================================================================
local TK_MID, TK_HALF = 30, 11

local function body_TAKE(frame)
  local rec = pget("rec", 0) == 1 and pget("freeze", 0) == 0
  if not C.wave_any and not rec then
    screen.level(3)
    for x = 2, 125, 3 do screen.rect(x, TK_MID, 1, 1) end
    screen.fill()
    ptext_c("EMPTY - K2 REC", 64, 24, 1, 10)
    ptext_c("OR PARAMS > LOAD", 64, 34, 1, 4)
    return
  end
  local lo, hi = window_bounds()
  local wx = clamp(C.rec_phase, 0, 1) * 127
  -- marked for erase: K1+K3 held past the tap window on this page
  local marked = C.k13_frame ~= nil
    and (C.frame - C.k13_frame) >= 2 and not C.k13_fired
  -- the material: bright inside the window, dim outside, hot behind the
  -- write head; the unwritten buffer is a dotted centerline
  local run = 0
  for x = 0, 127 do
    local a = wave[x + 1]
    if a > 0.002 then
      local h = clamp(sqrt(min(a * 2, 1)) * TK_HALF, 1, TK_HALF)
      local nx = x / 127
      local lvl = (nx >= lo and nx <= hi) and 12 or 4
      if rec then
        local d = wx - x
        if d >= 0 and d < 12 then lvl = 15 - floor(d / 3) end
      end
      if marked then lvl = 3 end
      if lvl ~= run then
        if run ~= 0 then screen.stroke() end
        screen.level(lvl)
        run = lvl
      end
      screen.move(x, TK_MID - h)
      screen.line(x, TK_MID + h)
    end
  end
  if run ~= 0 then screen.stroke() end
  screen.level(3)
  for x = 0, 126, 3 do
    if (wave[x + 1] or 0) <= 0.002 then screen.rect(x, TK_MID, 1, 1) end
  end
  screen.fill()
  if marked then                    -- danger hatch: the object, marked
    screen.level(11)
    for y = TK_MID - TK_HALF, TK_MID + TK_HALF do
      for x = 0, 127, 4 do
        local xx = x + (y % 4)
        if (wave[xx + 1] or 0) > 0.002 then screen.rect(xx, y, 1, 1) end
      end
    end
    screen.fill()
  end
  -- window brackets, with feet (the region that plays)
  screen.level(15)
  for k = 1, 2 do
    local e = (k == 1 and lo or hi) * 127
    screen.move(e, TK_MID - TK_HALF - 2)
    screen.line(e, TK_MID + TK_HALF + 2)
  end
  screen.stroke()
  screen.level(15)
  screen.rect(lo * 127 + 1, TK_MID - TK_HALF - 2, 2, 1)
  screen.rect(lo * 127 + 1, TK_MID + TK_HALF + 2, 2, 1)
  screen.rect(hi * 127 - 2, TK_MID - TK_HALF - 2, 2, 1)
  screen.rect(hi * 127 - 2, TK_MID + TK_HALF + 2, 2, 1)
  screen.fill()
  if rec then
    -- no blinking window frame (play-tested as "way too much"): the
    -- sweeping write head, the big elapsed seconds, the IN meter and the header
    -- R flag already say REC. the strip stays calm.
    screen.level(15)                -- the write head
    screen.move(wx, TK_MID - TK_HALF - 2)
    screen.line(wx, TK_MID + TK_HALF + 2)
    screen.stroke()
    -- elapsed seconds: the one number a performer needs
    local el = ((clamp(C.rec_phase, 0, 1) - C.rec_arm_phase) % 1) * C.BUF_SECS
    ptext(string.format("%.1fS", el), 88, 46, 2, 15)
    -- input meter with the record-ready bracket (peak inside = clean take)
    ptext("IN", 2, 47, 1, 5)
    local sig = sqrt(clamp(max(amp_in[1], amp_in[2]), 0, 1))
    screen.level(1)
    screen.rect(12, 48, 55, 5)
    screen.fill()
    screen.level(11)
    screen.rect(12, 48, floor(sig * 55), 5)
    screen.fill()
    screen.level(8)                 -- the -12..-3dB zone, wordless
    screen.rect(40, 46, 18, 1)
    screen.rect(40, 45, 1, 2)
    screen.rect(57, 45, 1, 2)
    screen.fill()
  else
    -- resample/regen: the buffer is being re-touched by output
    local bx = 2
    if pget("resample", 0) > 0 then bx = bx + chip("RSMP", bx, 12) + 2 end
    if pget("regen", 0) > 0 then chip("REGN", bx, 12) end
  end
  -- the READ (playback) head, drawn LAST so it never hides behind the solid
  -- WRITE head. distinct SHAPE, not just tone: a
  -- DASHED column + a caret above the strip vs the write head's solid line +
  -- comet-tail glow — so even when they cross you can tell read from write.
  if C.wave_any and pget("mode", 5) ~= 1 then
    local phx = clamp(C.play_phase, 0, 1) * 127
    screen.level(15)
    for y = TK_MID - TK_HALF, TK_MID + TK_HALF, 2 do screen.rect(phx, y, 1, 1) end
    screen.rect(phx, TK_MID - TK_HALF - 3, 1, 1)          -- caret stem
    screen.rect(phx - 1, TK_MID - TK_HALF - 4, 3, 1)      -- caret ▽ above the strip
    screen.fill()
  end
end

-- ============================================================================
-- 2 · VOICE — how the take plays (mode rail + the mode's own texture)
-- ============================================================================
local VOICE_RAIL = { { "PLAY", 5 }, { "GRAIN", 2 }, { "WARP", 3 }, { "PV", 4 } }

local function voice_wy(x, ph, rate)
  return 33 + sin((x + ph) * 0.35 * rate) * 8
end

local function body_VOICE(frame)
  local mode = pget("mode", 5)
  local held_pv = pget("pv_freeze", 0) == 1
  -- the mode rail: the active word inverted; OFF dims the whole rail
  local x = 4
  for _, m in ipairs(VOICE_RAIL) do
    local w = text_w(m[1], 1)
    if m[2] == mode then
      screen.level(15)
      screen.rect(x - 2, 11, w + 5, 9)
      screen.fill()
      ptext(m[1], x, 13, 1, 0)
    else
      ptext(m[1], x, 13, 1, mode == 1 and 2 or 5)
    end
    x = x + w + 10
  end
  if mode == 1 then ptext_r("OFF", 126, 13, 1, 8)
  elseif held_pv then ptext_r("HELD", 126, 13, 1, 12) end
  -- the texture IS the mode, drawn from the playing motion (drifts with
  -- scan, stands still frozen, lies flat when the voice is freed/silent)
  local scan = pget("scan", 1)
  local rate = max(abs(scan), 0.05)
  local ph = held_pv and 0 or frame * 0.8 * scan
  local silent = not C.wave_any
  if mode == 1 or silent then
    screen.level(1)
    screen.move(0, 33) screen.line(128, 33)
    screen.stroke()
  elseif mode == 2 then        -- GRAIN: the wave sampled as grains
    screen.level(6)
    for gx = 0, 127, 3 do
      screen.rect(gx, voice_wy(gx, ph, rate), 1, 1)
    end
    screen.fill()
  elseif mode == 3 then        -- WARP: an overlapped window ghosts behind
    local off = 9 + sin(frame * 0.9) * 6 * pget("warp_rand", 0)
    screen.level(2)
    for gx = 0, 127 do
      screen.rect(gx, voice_wy(gx + off, ph, rate), 1, 1)
    end
    screen.fill()
    screen.level(8)
    for gx = 0, 127 do
      screen.rect(gx, voice_wy(gx, ph, rate), 1, 1)
    end
    screen.fill()
  elseif mode == 4 then        -- PV: spectral columns under the same curve
    screen.level(6)
    for gx = 0, 127, 4 do
      local h = abs(sin((gx + ph) * 0.35 * rate)) * 14 + 1
      screen.rect(gx, 45 - h, 2, h)
    end
    screen.fill()
  else                         -- PLAY: one unbroken wave — the exact sample
    screen.level(9)
    for gx = 0, 127 do
      screen.rect(gx, voice_wy(gx, ph, rate), 1, 1)
    end
    screen.fill()
  end
  -- window bar + the playhead (nothing moves that can't be heard)
  local lo, hi = window_bounds()
  screen.level(2)
  screen.move(0, 48) screen.line(128, 48)
  screen.stroke()
  screen.level(6)
  screen.move(lo * 127, 48) screen.line(hi * 127, 48)
  screen.stroke()
  if mode ~= 1 and not silent then
    screen.level(15)
    local phx = clamp(C.play_phase, 0, 1) * 127
    screen.move(phx, 24) screen.line(phx, 50)
    screen.stroke()
  end
end

-- ============================================================================
-- 3 · TAPE — the second deck: the REELS (two reels spin at the effective
--     rate — reverse spins backward, stopped stands still — above the loop
--     track + head, with the loop readout on the right)
-- ============================================================================
local REEL_X = { 46, 86 }   -- the two reel centers
local reel_angle = 0        -- persistent spin accumulator, driven by tape rate
local function body_TAPE(frame)
  local a2, b2 = pget("loop_start", 0), pget("loop_end", 1)
  local lo, hi = min(a2, b2), max(a2, b2)
  local lspan = max(hi - lo, 0.001)
  -- the reels spin at the effective rate: reverse -> backward, stopped -> still
  local r = pget("tape_rate", 1) * (pget("tape_reverse", 0) == 1 and -1 or 1)
  reel_angle = reel_angle + r * 0.35
  for _, cx in ipairs(REEL_X) do
    screen.level(4)
    screen.circle(cx, 24, 8)
    screen.stroke()
    screen.level(6)                      -- hub
    screen.rect(cx - 1, 23, 3, 3)
    screen.fill()
    screen.level(10)                     -- three spokes, inner r2.5 -> r6.5
    for k = 0, 2 do
      local a = reel_angle + k * 2.094
      local ca, sa = cos(a), sin(a)
      screen.move(cx + ca * 2.5, 24 + sa * 2.5)
      screen.line(cx + ca * 6.5, 24 + sa * 6.5)
    end
    screen.stroke()
  end
  screen.level(4)                        -- straight tape guides between the reels
  screen.move(46, 16) screen.line(86, 16)
  screen.move(46, 32) screen.line(86, 32)
  screen.stroke()
  -- the loop track below: full-width rail, the loop region, the head
  screen.level(2)
  screen.move(0, 40) screen.line(128, 40)
  screen.stroke()
  screen.level(8)
  screen.move(lo * 127, 40) screen.line(hi * 127, 40)
  screen.stroke()
  screen.level(15)
  local tx = clamp(C.tape_phase, 0, 1) * 127
  screen.move(tx, 37) screen.line(tx, 43)
  screen.stroke()
  ptext_r(string.format("%.1fS", lspan * C.BUF_SECS), 126, 12, 1, 4)
  -- record SOURCE: flag when the tape is printing PROCESSED audio (never a
  -- hidden mode — DRY, the default, draws nothing so classic tape is unchanged)
  local src = pget("cut_source", 0)
  if src > 0.02 then
    ptext(src > 0.98 and "SRC WET" or ("SRC WET " .. floor(src * 100 + 0.5) .. "%"),
      2, 46, 1, 9)
  end
  if pget("tape_rec", 0) == 1 and pget("tape_freeze", 0) == 0 then
    if (frame % FPS) < (FPS / 2) then chip("REC", 2, 12) end
  elseif not C.twave_any then
    ptext_c("EMPTY - K2 REC", 64, 26, 1, 3)
  end
end

-- ============================================================================
-- 4 · FILTER — tone (approx DFM1 response, with labeled measurement rails;
--     drive = grit on the line, not a number)
-- ============================================================================
local function body_FILTER(frame)
  local cut = pget("cutoff", 20000)
  local ft = pget("filt_type", 1)
  local res = pget("resonance", 0)
  local drv = pget("drive", 0)
  screen.level(2)
  for i = 1, 3 do
    for y = FILT_TOP, FILT_BOT, 2 do
      screen.rect(FILT_GRID_X[i], y, 1, 1)
    end
  end
  for x = 0, 127, 4 do screen.rect(x, FILT_DB0_Y, 1, 1) end
  screen.fill()
  for i = 1, 3 do
    ptext(FILT_GRID_LBL[i], FILT_GRID_X[i] - 5, FILT_BOT + 2, 1, 3)
  end
  local rq = max(1 - res * 0.92, 0.05)
  local rq2 = rq * rq
  local px_per_db = (FILT_BOT - FILT_TOP) / FILT_DB_RANGE
  for x = 0, 127 do
    local w = FILT_FREQ[x + 1] / cut
    local w2 = w * w
    local d = 1 - w2
    d = d * d + w2 * rq2
    local h2
    if ft == 1 then h2 = 1 / d
    elseif ft == 2 then h2 = (w2 * w2) / d
    else                              -- BP = resonant LP peak, high-passed below cutoff/2
      local u = w + w                 -- freq / (cutoff*0.5), the engine's HP corner
      local u4 = u * u * u * u
      h2 = (1 / d) * u4 / (1 + u4)
    end
    local y = FILT_TOP + (FILT_DB_TOP - 4.342944819 * log(h2)) * px_per_db
    if y < FILT_TOP then y = FILT_TOP elseif y > FILT_BOT then y = FILT_BOT end
    FILT_Y[x + 1] = y
  end
  -- passband filled dim (hiding the rails it covers), curve bright on top
  screen.level(2)
  for x = 0, 127 do
    local y = FILT_Y[x + 1]
    if y < FILT_BOT then
      screen.move(x, y)
      screen.line(x, FILT_BOT)
    end
  end
  screen.stroke()
  local ssd = floor(frame / 4)
  screen.level(4)
  for x = 0, 127, 5 do
    local under = FILT_BOT - FILT_Y[x + 1]
    if under > 1 then
      local th = hash(x, 3, ssd) * under
      screen.rect(x, FILT_BOT - th, 1, th)
    end
  end
  screen.fill()
  screen.level(10)
  for x = 1, 127 do
    screen.move(x - 1, FILT_Y[x])
    screen.line(x, FILT_Y[x + 1])
  end
  screen.stroke()
  if drv > 0.005 then          -- saturation as texture: grit flecks the curve
    screen.level(7)
    for x = 0, 127, 2 do
      if hash(x, 9, ssd) < drv * 0.35 then
        screen.rect(x, FILT_Y[x + 1] - 2 - hash(x, 11, ssd) * 2, 1, 1)
      end
    end
    screen.fill()
  end
  -- the cutoff as a grabbable node: E2 moves exactly this dot
  local nx = floor(clamp(log(cut / 20) / log(1000), 0, 1) * 127 + 0.5)
  screen.level(15)
  screen.rect(nx - 1, FILT_Y[nx + 1] - 1, 3, 3)
  screen.fill()
  chip(params.lookup["filt_type"] and params:string("filt_type") or "?", 2, 12)
end

-- ============================================================================
-- 5 · DELAY / REVERB — the time-smear, split into two stations. DELAY draws
--     the onset + echo taps decaying by feedback; REVERB draws the tail as a
--     slope + shimmer motes. shared time axis, rails at 1s/2s, dormant flat
--     at mix 0. (was one merged SPACE page, split after play-testing.)
-- ============================================================================
local SPC_BASE, SPC_X0 = 48, 8
local SPC_PPS = 49                    -- pixels per second on the time axis

-- shared chrome: the time baseline, the dormant stub, and the 1s/2s rails.
-- returns true if the page is live (caller draws the effect), false if it
-- already drew the dormant stub and should bail.
local function spc_frame(live)
  screen.level(live and 4 or 2)
  screen.move(4, SPC_BASE) screen.line(124, SPC_BASE)
  screen.stroke()
  if not live then                    -- dormant: a stub of an onset
    screen.level(4)
    screen.rect(SPC_X0, SPC_BASE - 5, 2, 5)
    screen.fill()
    return false
  end
  -- time rails: 1s and 2s, labeled
  screen.level(2)
  for i = 1, 2 do
    local tx = SPC_X0 + i * SPC_PPS
    for y = 14, SPC_BASE - 1, 2 do screen.rect(tx, y, 1, 1) end
  end
  screen.fill()
  ptext("1S", SPC_X0 + SPC_PPS - 3, SPC_BASE + 2, 1, 3)
  ptext("2S", SPC_X0 + 2 * SPC_PPS - 3, SPC_BASE + 2, 1, 3)
  return true
end

local function spc_onset()             -- the shared onset spike
  screen.level(15)
  screen.rect(SPC_X0, SPC_BASE - 34, 2, 34)
  screen.fill()
end

local function body_DELAY(frame)
  local emix = pget("delay_mix", 0)
  if not spc_frame(emix > 0.005) then return end
  spc_onset()
  -- echo taps: spacing = delay_time, height decaying by the ACTUAL feedback
  -- coefficient (the knob is curved through ctx.delay_fb_curve, so the taps
  -- match what you hear — the animation stays honest)
  local sp = max(pget("delay_time", 0.3) * SPC_PPS, 6)
  local fbk = pget("delay_fb", 0.3)
  local fb = max(C.delay_fb_curve and C.delay_fb_curve(fbk) or fbk, 0.05)
  local h = 30 * (0.4 + emix * 0.6)
  local x = SPC_X0 + sp
  while x <= 124 and h >= 1.5 do
    screen.level(max(4, floor(4 + (h / 30) * 10)))
    screen.rect(floor(x), SPC_BASE - h, 2, h)
    screen.fill()
    h = h * fb
    x = x + sp
  end
end

local function body_REVERB(frame)
  local vmix = pget("rev_mix", 0)
  if not spc_frame(vmix > 0.005) then return end
  -- the reverb tail: a filled slope whose reach IS the decay
  local tau = max(pget("rev_decay", 2), 0.1) * SPC_PPS / 6.9
  local A = 4 + vmix * 26
  screen.level(3)
  for x = SPC_X0 + 1, 124 do
    local h = A * exp(-(x - SPC_X0) / tau)
    if h >= 1 then
      screen.move(x, SPC_BASE - h)
      screen.line(x, SPC_BASE - 1)
    end
  end
  screen.stroke()
  -- discrete reflections riding the slope: rev_size spaces them (a bigger
  -- room = sparser, later reflections), rev_damp darkens them toward the
  -- tail-end (high frequencies absorbed) — so both encoders READ on the page.
  local step = 2 + floor(pget("rev_size", 1))          -- 2 (tight) .. 7 (vast)
  local damp = pget("rev_damp", 0.3)
  local span = 124 - SPC_X0
  for x = SPC_X0 + 1, 124, step do
    local h = A * exp(-(x - SPC_X0) / tau)
    if h >= 1 then
      screen.level(max(2, floor(9 - damp * 7 * (x - SPC_X0) / span)))
      screen.rect(x, SPC_BASE - h, 1, 1)
      screen.fill()
    end
  end
  -- "this will not stop soon": the tail runs into the hatched margin
  if A * exp(-(124 - SPC_X0) / tau) >= 1 then
    screen.level(9)
    for y = 14, SPC_BASE do
      local xx = 125 + ((y + 125) % 3)
      if xx <= 127 then screen.rect(xx, y, 1, 1) end
    end
    screen.fill()
  end
  -- shimmer: motes climbing off the tail
  local shim = pget("shimmer", 0)
  if shim > 0.01 then
    local spd = 0.4 + (param_norm("shimmer_pitch") or 0.5) * 1.4
    local n = 3 + floor(shim * 15)
    screen.level(7)
    for i = 1, n do
      local mx = SPC_X0 + 4 + hash(i, 3, 0) * 100
      local ph = (frame * spd + hash(i, 5, 0) * 100) % 28
      screen.rect(mx, SPC_BASE - 4 - ph, 1, 1)
    end
    screen.fill()
  end
  spc_onset()
end

-- ============================================================================
-- 6 · MIX — the console (in meter → the two decks at their REAL gains →
--     master VU). the layer decks live on their own page; this console is
--     the engine <> tape crossfade.
-- ============================================================================
local function body_MIX(frame)
  -- each lane's energy is its deck's REAL gain: the ONE law itself
  -- (C.mix_gains — trim x crossfade plateau x master x STOP), not a mirror
  local mixv = pget("mix", 0.5)
  local eng_g, tape_g = C.mix_gains()
  local eng_on = pget("mode", 5) ~= 1 and eng_g > 0.001 and C.wave_any
  local tape_on = C.twave_any and tape_g > 0.001
  local newframe = C.frame ~= vu_last_frame
  -- input meter, left
  ptext("IN", 3, 12, 1, 5)
  screen.level(1)
  screen.rect(3.5, 18.5, 8, 31)
  screen.stroke()
  local isig = sqrt(clamp(max(amp_in[1], amp_in[2]), 0, 1))
  if isig > 0.01 then
    screen.level(11)
    screen.rect(5, 48 - isig * 28, 5, isig * 28)
    screen.fill()
  end
  if newframe then vu_peak[1] = max(isig, vu_peak[1] - 0.0045) end
  if vu_peak[1] > 0.02 then
    screen.level(15)
    screen.rect(5, 48 - vu_peak[1] * 28 - 1, 5, 1)
    screen.fill()
  end
  -- the engine deck lane (the real take, at the deck's real gain)
  ptext("ENG", 18, 13, 1, 5)
  if not eng_on then
    screen.level(1)
    screen.move(18, 23.5) screen.line(104, 23.5)
    screen.stroke()
  else
    local g = clamp(eng_g, 0, 1)
    screen.level(12)
    for x = 18, 104 do
      local a = wave[floor((x - 18) / 86 * 127) + 1] or 0
      if a > 0.002 then
        local h = clamp(sqrt(min(a * 2, 1)) * g * 5, 0.5, 5)
        screen.move(x, 23.5 - h)
        screen.line(x, 23.5 + h)
      end
    end
    screen.stroke()
    if pget("mode", 5) ~= 1 then
      screen.level(15)
      local phx = 18 + clamp(C.play_phase, 0, 1) * 86
      screen.move(phx, 19) screen.line(phx, 28)
      screen.stroke()
    end
  end
  -- the crossfade rail + tick (the tick stays put in STOP: settings held)
  screen.level(2)
  screen.move(18, 32.5) screen.line(104, 32.5)
  screen.stroke()
  screen.level(15)
  screen.rect(18 + mixv * 84, 30, 3, 6)
  screen.fill()
  -- the tape deck lane (the real loop; the head is ALWAYS running on it)
  if not tape_on then
    screen.level(1)
    screen.move(18, 41.5) screen.line(104, 41.5)
    screen.stroke()
  else
    local g = clamp(tape_g, 0, 1)
    screen.level(10)
    for x = 18, 104 do
      local a = twave[floor((x - 18) / 86 * 127) + 1] or 0
      if a > 0.002 then
        local h = clamp(sqrt(min(a * 2, 1)) * g * 4, 0.5, 4)
        screen.move(x, 41.5 - h)
        screen.line(x, 41.5 + h)
      end
    end
    screen.stroke()
  end
  if C.twave_any then
    screen.level(tape_on and 15 or 4)
    local hx = 18 + clamp(C.tape_phase, 0, 1) * 86
    screen.move(hx, 38) screen.line(hx, 45)
    screen.stroke()
  end
  ptext("TAPE", 18, 47, 1, 5)
  -- master VU, right
  screen.level(1)
  screen.rect(112.5, 18.5, 8, 31)
  screen.stroke()
  local osig = sqrt(clamp(max(amp_out[1], amp_out[2]), 0, 1))
  if osig > 0.01 then
    screen.level(11)
    screen.rect(114, 48 - osig * 28, 5, osig * 28)
    screen.fill()
  end
  if newframe then
    vu_peak[2] = max(osig, vu_peak[2] - 0.0045)
    vu_last_frame = C.frame
  end
  if vu_peak[2] > 0.02 then
    screen.level(15)
    screen.rect(114, 48 - vu_peak[2] * 28 - 1, 5, 1)
    screen.fill()
  end
  ptext("OUT", 112, 12, 1, 5)
end

-- ============================================================================
-- 7 · PADS — the take chopped into 8 playable slices: the window zoomed full
--     width over 8 numbered cells, each with its own voice + pitch sound-lock;
--     lit while sounding, the cursor squared for editing.
-- ============================================================================
local function body_PADS(frame)
  for i = 0, 7 do pad_lit[i] = false end
  local used = 0
  for _, padi in pairs(C.pad_held) do
    pad_lit[padi] = true
    used = used + 1
  end
  local routed = pget("pad_input", 0) == 1
  ptext(routed and "PLAY>PADS" or "PLAY>DRONE", 2, 12, 1, routed and 12 or 3)
  -- the SELECTED pad's sound-lock: voice + pitch (the cursor editor). e.g. SLC+5
  local cvi = clamp(floor(pget("seq_slice", 0) + 0.5), 0, 7)
  local cp = C.pad_pitch and (C.pad_pitch[cvi] or 0) or 0
  local lk = ((C.pad_type and C.pad_type[cvi] or 0) == 1 and "SLC" or "GRN")
    .. (cp ~= 0 and ((cp > 0 and "+" or "") .. cp) or "")
  ptext_c(lk, 72, 12, 1, 6)
  ptext_r(used .. "/" .. floor(pget("voices", 8) + 0.5) .. "V", 126, 12, 1, 4)
  if not C.wave_any and pget("rec", 0) == 0 then
    ptext_c("EMPTY - K2 REC", 64, 28, 1, 6)
    return
  end
  -- THE TAKE: the window zoomed full width, divided into 8 (a pad is
  -- self-evidently an eighth of what you recorded)
  local bx0, bx1, by = 4, 124, 22
  local sw = (bx1 - bx0) / 8
  local wlo, _, wspan = window_bounds()
  screen.level(8)
  for x = bx0, bx1 do
    local a = wave[floor((wlo + (x - bx0) / (bx1 - bx0) * wspan) * 127) + 1] or 0
    if a > 0.002 then
      local h = clamp(sqrt(min(a * 2, 1)) * 4, 1, 4)
      screen.move(x, by - h)
      screen.line(x, by + h)
    end
  end
  screen.stroke()
  -- the slice boundaries, ON the wave. Even eighths when nothing has been
  -- chopped; the REAL cut positions once something has, because the whole
  -- point of a chop is that the slices are not evenly spaced and the picture
  -- has to say so.
  local cuts = C.pad_cuts
  screen.level(4)
  if cuts then
    for i = 1, #cuts do
      local f = (cuts[i] - wlo) / wspan
      if f >= 0 and f <= 1 then
        screen.rect(bx0 + f * (bx1 - bx0), by - 5, 1, 10)
      end
    end
  else
    for i = 0, 8 do screen.rect(bx0 + i * sw, by - 5, 1, 10) end
  end
  screen.fill()
  if pget("mode", 5) ~= 1 then
    local ph = (clamp(C.play_phase, 0, 1) - wlo) / wspan
    if ph >= 0 and ph <= 1 then
      screen.level(13)
      screen.rect(bx0 + ph * (bx1 - bx0), by - 5, 1, 10)
      screen.fill()
    end
  end
  -- the 8 slice cells, aligned under their eighths
  for i = 0, 7 do
    local cx = bx0 + i * sw
    local cur = i == C.pad_cursor
    local lit = pad_lit[i]
    if cur then
      -- the selected cell is a SQUARE that stands 1px proud on every side, so
      -- it reads as picked instead of as one more small rectangle in the row
      screen.level(15)
      screen.rect(cx + sw / 2 - 7, 26.5, 14, 14)
      screen.stroke()
    else
      screen.level(4)
      screen.rect(cx + 1.5, 28.5, sw - 3, 10)
      screen.stroke()
    end
    if lit then
      screen.level(cur and 15 or 9)
      screen.rect(cx + 3, 30, sw - 6, 7)
      screen.fill()
    end
    local sl = (C.pad_slice_of and C.pad_slice_of(i) or i) + 1
    ptext_c(tostring(sl), cx + sw / 2, 31, 1, lit and 0 or (cur and 15 or 6))
    -- SOUND-LOCK markers: a bottom bar = SLICE voice, a top-corner dot = pitched
    if (C.pad_type and C.pad_type[i] or 0) == 1 then
      screen.level(lit and 0 or (cur and 15 or 6))
      screen.rect(cx + sw / 2 - 2, 36, 4, 1)
      screen.fill()
    end
    if C.pad_pitch and (C.pad_pitch[i] or 0) ~= 0 then
      screen.level(cur and 15 or 6)
      screen.rect(cx + sw / 2 + 3, 28, 1, 1)
      screen.fill()
    end
  end
  -- the free row below the slices. Normally a quiet cue for the sound-lock
  -- encoders (82px, well under the 124 limit); once a CHOP is in force that
  -- row says so instead — what the pads now mean outranks a hint you have
  -- already read, and the two together overran the line.
  if C.pad_cuts then
    local n = #C.pad_cuts - 1
    ptext_c(("CHOP - %d SLICES ON THE HITS"):format(n), 64, 46, 1, 4)
  else
    ptext_c("E2 SLICE - E3 PITCH", 64, 46, 1, 3)
  end
end

-- ============================================================================
-- 8 · MOTION — the gesture loop (dynamic lanes: one automation CURVE per
--     recorded param, named with its page's own word; one playhead crosses
--     every lane with a live-value dot)
-- ============================================================================
local function body_MOTION(frame)
  local mo = C.motion
  local ll = mo.loop_len
  local ids = mo.lane_ids
  local nlane = #ids
  local armed = pget("motion_rec", 0) == 1
  local playing = pget("motion_play", 0) == 1
  if nlane == 0 then
    if armed then
      if (frame % 4) < 2 then chip("REC", 2, 12) end
      ptext_c("MOVE A KNOB TO RECORD", 64, 28, 1, 8)
    else
      ptext_c("EMPTY - K2 ARM", 64, 24, 1, 4)
      ptext_c("THEN MOVE A KNOB", 64, 32, 1, 3)
    end
    return
  end
  if ll > 0 then
    ptext_r(string.format("LOOP %.1fS", ll / FPS), 126, 9, 1, 4)
  end
  local sel = clamp(floor(pget("motion_lane", 0) + 0.5), 0, nlane)
  local VIS = 4
  local shown = min(nlane, VIS)
  local top, rh = 15, 10
  local gx0, gx1 = 33, 124
  -- scroll: the VIS-lane window follows the selected lane so every lane is
  -- reachable (a scrollbar on the right edge shows where in the stack you are)
  local off = 0
  if nlane > VIS then
    local focus = sel > 0 and sel or 1
    off = clamp(focus - VIS, 0, nlane - VIS)   -- keep the selected lane visible:
    if focus - 1 < off then off = focus - 1 end --   between the top and bottom row
  end
  -- drawing length: the loop once set, else the furthest event so far
  local dl = ll                          -- playhead / rails denominator (loop_len)
  if dl == 0 then
    for i = 1, nlane do
      local L = mo.lanes[ids[i]]
      if L.n > 0 and L.f[L.n] > dl then dl = L.f[L.n] end
    end
  end
  if dl < 1 then dl = 1 end
  -- events live in the rec_len timebase; plotting them against rec_len keeps
  -- the step-curve aligned with the playhead when motion_len retimes the loop.
  -- IDENTITY when not retimed (rec_len == loop_len == dl) or mid-first-pass.
  local el = mo.rec_len or 0
  if el < 1 then el = dl end
  -- quarter rails through the loop
  screen.level(2)
  for k = 0, 4 do
    local x = gx0 + floor((gx1 - gx0) * k / 4)
    for y = top - 2, top + shown * rh - 2, 2 do screen.rect(x, y, 1, 1) end
  end
  screen.fill()
  local phx = gx0 + (clamp(mo.playhead, 0, dl) / dl) * (gx1 - gx0)
  for row = 1, shown do
    local li = off + row                  -- the lane index this row shows
    local id = ids[li]
    local L = mo.lanes[id]
    local yb = top + (row - 1) * rh + 8   -- the lane's value baseline
    local selected = li == sel
    ptext(SHORT[id] or string.upper(id), 2, yb - 6, 1, selected and 11 or 5)
    if selected then
      screen.level(15)
      screen.move(0, yb - 8) screen.line(0, yb + 2)
      screen.stroke()
      screen.rect(1, yb - 8, 1, 1)
      screen.rect(1, yb + 2, 1, 1)
      screen.fill()
    end
    -- the recorded motion as a STEP CURVE (hold value between events)
    local n = L.n
    if n > 0 then
      screen.level(selected and 11 or 7)
      local py = yb - value_norm(id, L.v[1]) * 8
      screen.move(gx0, py)
      for e = 1, n do
        local ex = gx0 + (L.f[e] / el) * (gx1 - gx0)
        local ey = yb - value_norm(id, L.v[e]) * 8
        screen.line(ex, py)
        screen.line(ex, ey)
        py = ey
      end
      screen.line(gx1, py)
      screen.stroke()
    end
    -- the value sounding right now, where the playhead crosses
    if ll > 0 then
      local vy = yb - (value_norm(id, pget(id, 0)) or 0) * 8
      screen.level(15)
      screen.rect(phx - 1, vy - 1, 3, 3)
      screen.fill()
    end
  end
  -- one playhead crosses every lane
  if ll > 0 then
    screen.level(playing and 10 or 3)
    screen.move(phx, top - 3)
    screen.line(phx, top + shown * rh - 3)
    screen.stroke()
  elseif armed then
    screen.level(15)
    screen.move(gx1, top - 3)
    screen.line(gx1, top + shown * rh - 3)
    screen.stroke()
  end
  if armed and (frame % 4) < 2 then      -- armed frame: the fast blink
    screen.level(15)
    screen.rect(gx0 - 2.5, top - 4.5, gx1 - gx0 + 6, shown * rh + 5)
    screen.stroke()
  end
  -- scrollbar (right edge): the VIS-lane window's place in the whole stack
  if nlane > VIS then
    local sy0, sy1 = top - 2, top + shown * rh - 3
    screen.level(2)
    screen.rect(127, sy0, 1, sy1 - sy0)
    screen.fill()
    local th0 = sy0 + (sy1 - sy0) * (off / nlane)
    local th1 = sy0 + (sy1 - sy0) * ((off + VIS) / nlane)
    screen.level(9)
    screen.rect(127, th0, 1, max(1, th1 - th0))
    screen.fill()
  end
end

-- ============================================================================
-- 9 · SCENE — states and the way back (the slot row + the morph rail; undo
--     is the ◄ cell, a slot you can see)
-- ============================================================================
local function body_SCENE(frame)
  local sc = C.scene
  local sel = clamp(floor(pget("scene_slot", 1) + 0.5), 0, 8)
  local amt = pget("scene_morph_amt", 0)
  -- status row: the message line outranks the morph cue
  local msg_live = sc.msg ~= nil and (frame - sc.msg_at) < FPS * 1.2
  if msg_live then
    chip(sc.msg, 64 - floor((text_w(sc.msg, 1) + 5) / 2), 11)
  elseif amt >= 0.999 and sc.engaged and sc.unlanded(sel) then
    ptext_c("K2 TO LAND THE REST", 64, 13, 1, 5)
  else
    ptext_r(string.upper(params:string("scene_recall_mode")), 126, 13, 1, 4)
  end
  -- the ◄ cell: the way back (the safe state, auto-marked by chaos)
  if sc.safe then
    screen.level(6)
    screen.rect(3, 22, 9, 12)
    screen.fill()
    ptext("<", 6, 25, 1, 0)
  else
    screen.level(2)
    for xx = 3, 11, 2 do
      screen.rect(xx, 22, 1, 1)
      screen.rect(xx, 33, 1, 1)
    end
    for yy = 22, 33, 2 do
      screen.rect(3, yy, 1, 1)
      screen.rect(11, yy, 1, 1)
    end
    screen.fill()
    ptext("<", 6, 25, 1, 3)
  end
  if sel == 0 then                       -- the ◄ cell is selected
    screen.level(15)
    screen.rect(2, 20, 4, 1)
    screen.rect(9, 20, 3, 1)
    screen.rect(2, 35, 4, 1)
    screen.rect(9, 35, 3, 1)
    screen.rect(2, 21, 1, 2)
    screen.rect(11, 21, 1, 2)
    screen.rect(2, 33, 1, 2)
    screen.rect(11, 33, 1, 2)
    screen.fill()
  end
  -- the refusal shake: a no-op action (an empty slot) shakes its cell for a
  -- beat — the instrument never silently ignores you, and needs no words
  local shake = 0
  if msg_live and (frame - sc.msg_at) < 4 and sc.msg
      and sc.msg:find("EMPTY") then
    shake = (frame % 2 == 0) and 1 or -1
  end
  -- the 8 slots
  local nfilled = 0
  for i = 1, 8 do
    local x = 16 + (i - 1) * 14
    if i == sc.msg_slot then x = x + shake end
    local filled = sc.slots[i] ~= nil
    if filled then nfilled = nfilled + 1 end
    local pending = sc.pending == i and (frame % FPS) < (FPS / 2)
    local flash = msg_live and sc.msg_slot == i
    if filled or pending or flash then
      screen.level((pending or flash) and 15 or 7)
      screen.rect(x, 22, 12, 12)
      screen.fill()
    else
      screen.level(2)
      for xx = x, x + 11, 2 do
        screen.rect(xx, 22, 1, 1)
        screen.rect(xx, 33, 1, 1)
      end
      for yy = 22, 33, 2 do
        screen.rect(x, yy, 1, 1)
        screen.rect(x + 11, yy, 1, 1)
      end
      screen.fill()
    end
    ptext_c(tostring(i), x + 6, 25, 1, (filled or pending or flash) and 0 or 4)
    if i == sel then                     -- cursor brackets
      screen.level(15)
      screen.rect(x - 1, 20, 4, 1)
      screen.rect(x + 9, 20, 4, 1)
      screen.rect(x - 1, 35, 4, 1)
      screen.rect(x + 9, 35, 4, 1)
      screen.rect(x - 1, 21, 1, 2)
      screen.rect(x + 12, 21, 1, 2)
      screen.rect(x - 1, 33, 1, 2)
      screen.rect(x + 12, 33, 1, 2)
      screen.fill()
    end
  end
  -- a queued recall: the emptying wedge counts down to the sync point
  -- (clock.get_beats is device-side; the sim has no clock, so no wedge)
  if sc.pending then
    local ok, beats = pcall(clock.get_beats)
    if ok and type(beats) == "number" then
      local mode = floor(pget("scene_recall_mode", 1) + 0.5)
      local span = mode == 3 and 4 or 1
      local frac = 1 - ((beats % span) / span)     -- time remaining
      local wx, wy = 124, 16
      screen.level(12)
      local a = -1.5708
      local a1 = -1.5708 + 6.2832 * clamp(frac, 0, 1)
      while a < a1 do
        screen.rect(wx + cos(a) * 3, wy + sin(a) * 3, 1, 1)
        screen.rect(wx + cos(a) * 2, wy + sin(a) * 2, 1, 1)
        a = a + 0.25
      end
      screen.fill()
    end
  end
  -- ◄ selected: the rail has no target — this cell is a recall, not a morph
  if sel == 0 then
    ptext_c(sc.safe and "K2 = THE WAY BACK" or "< FILLS ON RECALL/CHAOS",
      64, 44, 1, 4)
    return
  end
  -- the morph rail: LIVE toward the selected slot, from wherever you are
  if nfilled == 0 then
    ptext_c("EMPTY - K3 CAP", 64, 44, 1, 4)
    return
  end
  if not sc.slots[sel] then
    ptext_c("SLOT " .. sel .. " EMPTY - K3 CAP", 64, 44, 1, 4)
    return
  end
  local live = amt > 0.001 and amt < 0.999
  ptext("LIVE", 4, 43, 1, amt < 0.5 and 11 or 4)
  ptext_r(tostring(sel), 124, 43, 1, amt >= 0.5 and 11 or 4)
  local x0, x1 = 28, 108
  screen.level(3)
  screen.move(x0, 45.5) screen.line(x1, 45.5)
  screen.stroke()
  screen.level(10)
  local hx = x0 + amt * (x1 - x0)
  if amt > 0.001 then
    screen.move(x0, 45.5) screen.line(hx, 45.5)
    screen.stroke()
  end
  screen.level(12)                       -- the origin: where the sweep left
  screen.rect(x0 - 1, 44, 3, 3)
  screen.fill()
  screen.level(15)                       -- the handle, open
  screen.rect(hx - 2, 43, 5, 5)
  screen.fill()
  screen.level(live and 0 or 2)
  screen.rect(hx, 45, 1, 1)
  screen.fill()
end

-- each page draws its body through this dispatch table, selected by name;
-- built ONCE at load, so the redraw stays allocation-free
-- ORBIT: the eight slots in a row, the wanderer travelling from where it
-- last parked toward the current target. filled slots bright, empties dim,
-- target bracketed. truth rules: the traveller only moves while running.
-- the trail is a preallocated ring of recent positions that fades with
-- age; it freezes when the orbit stops, showing the path it took.
local ORB_TRAIL = 12
local orb_trail = {}
for i = 1, ORB_TRAIL do orb_trail[i] = -1 end
local orb_head = 0
local function body_ORBIT(frame)
  local on = pget("orbit_on", 0) == 1
  local target = clamp(floor(pget("scene_slot", 1) + 0.5), 0, 8)
  local amt = clamp(pget("scene_morph_amt", 0), 0, 1)
  local filled = 0
  for s = 1, 8 do if C.scenes[s] then filled = filled + 1 end end
  if filled == 0 then
    ptext_c("NO SCENES TO ORBIT", 64, 24, 1, 4)
    ptext_c("CAPTURE SOME ON SCENE", 64, 32, 1, 3)
    return
  end
  for s = 1, 8 do
    local x = 6 + (s - 1) * 15
    local has = C.scenes[s] ~= nil
    screen.level(has and (s == target and 12 or 7) or 2)
    screen.rect(x, 22, 11, 11)
    if has then screen.fill() else screen.stroke() end
    if s == target and on then
      screen.level(15)
      screen.rect(x - 1, 20, 13, 1)
      screen.fill()
    end
  end
  -- the traveller: a dot on a rail under the slots, position = morph amount
  -- toward the target slot's x. resting position is the left edge (LIVE).
  local tx = 6 + (target - 1) * 15 + 5
  local px = 6 + (tx - 6) * amt
  screen.level(3)
  screen.rect(6, 42, 116, 1)
  screen.fill()
  if on and (frame % 2) == 0 then
    orb_head = orb_head % ORB_TRAIL + 1
    orb_trail[orb_head] = px
  end
  for i = 1, ORB_TRAIL do
    local t = orb_trail[i]
    if t >= 0 then
      local age = (orb_head - i) % ORB_TRAIL
      screen.level(max(1, 6 - floor(age / 2)))
      screen.rect(clamp(t, 2, 124), 42, 1, 1)
    end
  end
  screen.fill()
  screen.level(on and 15 or 6)
  screen.rect(clamp(px, 2, 124), 40, 3, 5)
  screen.fill()
  if on then
    if (frame % 16) < 10 then chip("RUN", 2, 12) end
  else
    ptext("HELD", 2, 12, 1, 5)
  end
  ptext_r(filled .. " SCENES", 126, 12, 1, 4)
end

-- EROSION: how aged the take is. generation counter counts completed loop
-- passes while eroding; the strip fuzzes and dims with erosion depth.
local eros_gen, eros_acc = 0, 0
function M.erosion_tick()
  -- the erosion head runs at exactly one pass per window length, so a
  -- generation is span times sixty seconds of eroding time. paused under
  -- the same conditions the engine pauses (rec, freeze, not in PLAY).
  if pget("erode", 0) > 0 and pget("mode", 5) == 5
      and pget("rec", 0) == 0 and pget("freeze", 0) == 0 then
    local a, b = pget("pos_start", 0), pget("pos_end", 1)
    local span = max(max(a, b) - min(a, b), 0.001)
    eros_acc = eros_acc + (1 / FPS) / (span * C.BUF_SECS)
    if eros_acc >= 1 then
      eros_gen = eros_gen + 1
      eros_acc = eros_acc - 1
    end
  end
end
function M.erosion_reset() eros_gen, eros_acc = 0, 0 end

local function body_EROSION(frame)
  local e = clamp(pget("erode", 0), 0, 1)
  local w = clamp(pget("wear", 0), 0, 1)
  if pget("mode", 5) ~= 5 then
    ptext_c("EROSION WORKS IN PLAY MODE", 64, 26, 1, 4)
    ptext_c("VOICE K3 TO SWITCH", 64, 34, 1, 3)
    return
  end
  if not C.wave_any then
    ptext_c("EMPTY - K2 REC ON TAKE", 64, 28, 1, 4)
    return
  end
  -- the material line: fuzz density and dimming follow the erosion depth
  local lvl = 10 - floor(e * 6)
  for x = 4, 124 do
    local h = 4 + floor(hash(x, 0, 7) * 8 * (1 - w * 0.5))
    screen.level(hash(x, frame % 8, 3) < e * 0.7 and 2 or lvl)
    screen.rect(x, 31 - floor(h / 2), 1, h)
  end
  screen.fill()
  -- playhead, window relative (play_phase is a buffer position)
  local a, b = pget("pos_start", 0), pget("pos_end", 1)
  local wlo = min(a, b)
  local wspan = max(max(a, b) - wlo, 0.001)
  local hx = 4 + floor(clamp((C.play_phase - wlo) / wspan, 0, 1) * 120)
  screen.level(15)
  screen.rect(hx, 20, 1, 22)
  screen.fill()
  -- progress through the CURRENT generation (the erosion head runs at one
  -- pass per window length; eros_acc tracks it exactly)
  if e > 0 then
    screen.level(5)
    screen.rect(4, 45, floor(clamp(eros_acc, 0, 1) * 120), 1)
    screen.fill()
  end
  ptext_r("GEN " .. eros_gen, 126, 12, 1, e > 0 and 13 or 5)
  if e > 0 and (frame % 8) < 5 then chip("ERODING", 2, 12) end
end

-- ============================================================================
-- 13 - LAYERS - the loop decks beside the tape
-- ============================================================================
-- Two strips, one per deck. Each shows what is actually recorded in it, the
-- loop bracket over that, and the head. The SELECTED deck is bright and the
-- other dim -- the audibility rule everywhere else in this instrument: if a
-- thing is not the one you are working on, it does not compete for your eye.
-- A deck whose level is down, or that is not playing, dims further, so you can
-- always see which of them you are actually hearing.
local function layer_strip(d, y, sel, frame)
  local rec = pget(d.id .. "_rec", 0) == 1
  local playing = pget(d.id .. "_play", 1) == 1
  local lv = pget(d.id .. "_level", 0.8)
  local audible = playing and lv > 0.01 and pget("stop_all", 0) == 0
  local base = sel and (audible and 10 or 6) or (audible and 5 or 3)

  -- name, and the state in words rather than an icon to decode
  ptext(d.name, 3, y - 6, 1, sel and 15 or 6)
  if rec then
    -- the only fast blink in the instrument means WRITING, here as everywhere
    if (frame % 8) < 5 then
      screen.level(15); screen.rect(15, y - 5, 3, 3); screen.fill()
    end
    ptext(pget(d.id .. "_pre", 1) > 0.5 and "DUB" or "REP", 20, y - 6, 1, 12)
  elseif not playing then
    -- MUTE, not STOP: the head keeps rolling. That is deliberate — two decks at
    -- different rates only stay in their drifting relationship if neither one
    -- restarts, so silencing a layer must not move it. The word has to say so.
    ptext("MUTE", 20, y - 6, 1, 5)
  end

  local x0, x1 = 38, 124
  local w = x1 - x0
  -- the material
  screen.level(base)
  for x = x0, x1 do
    local a = d.wave[floor((x - x0) / w * 127) + 1] or 0
    if a > 0.002 then
      local h = clamp(sqrt(min(a * 2, 1)) * 5, 1, 5)
      screen.move(x, y - h)
      screen.line(x, y + h)
    end
  end
  screen.stroke()
  -- the loop bracket: where this deck actually reads from
  local ls = clamp(pget(d.id .. "_start", 0), 0, 1)
  local le = clamp(pget(d.id .. "_end", 1), 0, 1)
  local bx0 = x0 + floor(min(ls, le) * w)
  local bx1 = x0 + floor(max(ls, le) * w)
  screen.level(sel and 12 or 5)
  screen.rect(bx0, y - 6, 1, 13)
  screen.rect(bx1, y - 6, 1, 13)
  screen.rect(bx0, y - 6, bx1 - bx0, 1)
  screen.fill()

  -- the invitation goes over the bracket (which is drawn across the same
  -- space), so it knocks out a pocket first — the rule the footer follows when
  -- a swelling value meets the key words
  if not d.any then
    local msg = sel and "EMPTY - K2 REC" or "EMPTY"
    local tw = C.font.text_w(msg, 1)
    local tx = floor((x0 + x1) / 2 - tw / 2)
    screen.level(0)
    screen.rect(tx - 2, y - 2, tw + 4, 9)
    screen.fill()
    ptext(msg, tx, y + 3, 1, sel and 6 or 3)
  end

  -- the head, drawn last so it is never hidden
  screen.level(audible and 15 or 6)
  screen.rect(x0 + floor(clamp(d.phase, 0, 1) * w), y - 5, 1, 11)
  screen.fill()

  -- level, as a short bar under the name
  screen.level(sel and 8 or 4)
  screen.rect(3, y + 4, floor(clamp(lv, 0, 1) * 30), 1)
  screen.fill()
end

local function body_LAYERS(frame)
  local sel = floor(pget("layer_sel", 1) + 0.5)
  local decks = C.layers or {}
  if #decks == 0 then
    ptext_c("NO LAYER DECKS", 64, 30, 1, 4)
    return
  end
  -- the rate of the selected deck, top right: the number that makes two decks
  -- drift against each other, which is the whole reason for having two
  local d = decks[sel] or decks[1]
  local r = pget(d.id .. "_rate", 1) * (pget(d.id .. "_reverse", 0) == 1 and -1 or 1)
  ptext_r(string.format("%.2fX", r), 126, 12, 1, 5)
  ptext(C.twave_any and "TAPE+2" or "2 DECKS", 2, 12, 1, 4)
  for i = 1, math.min(#decks, 2) do
    layer_strip(decks[i], i == 1 and 27 or 45, sel == i, frame)
  end
end

local BODY = {
  ORBIT = body_ORBIT, EROSION = body_EROSION, LAYERS = body_LAYERS,
  TAKE = body_TAKE, VOICE = body_VOICE, TAPE = body_TAPE,
  FILTER = body_FILTER, DELAY = body_DELAY, REVERB = body_REVERB, MIX = body_MIX,
  PADS = body_PADS, MOTION = body_MOTION, SCENE = body_SCENE,
}

local function draw_body()
  local f = BODY[PAGES[C.page]]
  if f then f(C.frame) end
end

-- the purity mark ◇ (doc/redesign.md §4): lit ONLY when the output
-- is the take, verbatim. conservative — it may stay dark when technically
-- pure, but it never lies pure.
local function purity()
  if not C.wave_any then return false end
  if pget("stop_all", 0) == 1 then return false end
  if pget("mode", 5) ~= 5 then return false end             -- PLAY only
  if abs(pget("pitch", 1) - 1) > 0.001 then return false end
  if abs(pget("scan", 1) - 1) > 0.001 then return false end
  -- pan reaches the PLAY voice's Balance2: off-center output is not the
  -- recording, however clean the rest of the path is
  if abs(pget("pan", 0)) > 0.001 then return false end
  if pget("drive", 0) > 0.001 or pget("delay_mix", 0) > 0.001
      or pget("rev_mix", 0) > 0.001 or pget("shimmer", 0) > 0.001
      or pget("clouds_fb", 0) > 0.001 or pget("resample", 0) > 0.001
      or pget("regen", 0) > 0.001
      -- erode belongs with the other buffer writers: the mark would otherwise
      -- claim "verbatim" at exactly the moment the erosion head is grinding
      -- the take away underneath it
      or pget("erode", 0) > 0.001 then return false end
  if pget("freeze", 0) == 1 or pget("pv_freeze", 0) == 1 then return false end
  -- the take must be ALL of what you hear. dry_wet blends the live INPUT
  -- against the playback path, so anything short of full wet means the monitor
  -- is mixed in on top of the recording — and at 0 the take is not audible at
  -- all. This tested `dw > 0.001` and so lit at the 0.5 default (half and half)
  -- and at 0 (nothing but the input). The mark says "the recording, verbatim";
  -- it has to mean it, and it is supposed to be the conservative one.
  if pget("dry_wet", 0.5) < 0.999 then return false end
  -- ...and the filter must be out of the way
  if pget("filt_type", 1) ~= 1 or pget("cutoff", 20000) < 19000
      or pget("resonance", 0) > 0.02 then return false end
  -- the tape deck must not be adding its own material
  if C.twave_any and pget("mix", 0.5) > 0.02 then return false end
  -- ...and neither may the layer decks: material present and audibly playing
  -- means the output is not just the take (the same rule, per deck)
  local decks = C.layers
  if decks then
    for i = 1, #decks do
      local d = decks[i]
      if d.any and pget(d.id .. "_play", 1) == 1
          and pget(d.id .. "_level", 0.8) > 0.01 then return false end
    end
  end
  return true
end

-- header: TITLE ◇ flags ···· path dots. STOP inverts the title chip;
-- writes (R/T/M) carry the ONLY fast blink; runs are steady.
-- a write flag: dot + letter, blinking. hoisted to module scope (no per-frame
-- closure); returns the advanced x so the caller threads the cursor.
local function wflag(x, blink, ch, adv)
  if blink then
    screen.level(15)
    screen.rect(x, 1, 3, 3)
    screen.fill()
    ptext(ch, x + 5, 1, 1, 15)
  end
  return x + adv
end
local function draw_header()
  local page, frame = C.page, C.frame
  local title = PAGES[page]
  local x
  if pget("stop_all", 0) == 1 then
    screen.level(15)
    screen.rect(0, 0, text_w(title, 1) + 5, 8)
    screen.fill()
    ptext(title, 2, 2, 1, 0)
    x = text_w(title, 1) + 9
  else
    ptext(title, 2, 1, 1, 8)
    x = 2 + text_w(title, 1) + 4
  end
  if purity() then
    screen.level(15)
    screen.rect(x + 2, 0, 1, 1) screen.rect(x + 1, 1, 1, 1)
    screen.rect(x + 3, 1, 1, 1) screen.rect(x, 2, 1, 1)
    screen.rect(x + 4, 2, 1, 1) screen.rect(x + 1, 3, 1, 1)
    screen.rect(x + 3, 3, 1, 1) screen.rect(x + 2, 4, 1, 1)
    screen.fill()
    x = x + 8
  end
  local blink = (frame % 4) < 2
  if pget("rec", 0) == 1 then x = wflag(x, blink, "R", 12) end
  if pget("tape_rec", 0) == 1 then x = wflag(x, blink, "T", 11) end
  if pget("motion_rec", 0) == 1 then x = wflag(x, blink, "M", 13) end
  if pget("pv_freeze", 0) == 1 or pget("freeze", 0) == 1 then
    ptext("FZ", x, 1, 1, 10)
    x = x + 12
  end
  if pget("tape_freeze", 0) == 1 then
    ptext("TF", x, 1, 1, 10)
    x = x + 12
  end
  -- path dots, top-right: uniform spacing, current page a rounded 4x4 block.
  -- the wider current dot nudges every dot after it 2px right so it gets
  -- matching breathing room. the row is RIGHT-ANCHORED to end 2px clear of
  -- the screen edge whatever the page count (a fixed left origin cropped
  -- the last dot once the count reached twelve).
  local dpitch = #PAGES > 1 and min(5, floor(45 / (#PAGES - 1))) or 5
  local dx0 = 126 - ((#PAGES - 1) * dpitch + 4)
  for i = 1, #PAGES do
    local dx = dx0 + (i - 1) * dpitch + (i > page and 2 or 0)
    if i == page then
      screen.level(15)
      screen.rect(dx, 3, 4, 4)
      screen.fill()
      screen.level(0)
      screen.rect(dx, 3, 1, 1)
      screen.rect(dx + 3, 3, 1, 1)
      screen.rect(dx, 6, 1, 1)
      screen.rect(dx + 3, 6, 1, 1)
      screen.fill()
    else
      screen.level(3)
      screen.rect(dx, 4, 2, 2)
      screen.fill()
    end
  end
end

-- idle dim: after two minutes without a key or encoder touch every level is
-- cut to keep the OLED from burning the static chrome in; the first touch
-- restores full brightness. one closure, made once.
local orig_level, dim_level
function M.redraw()
  if orig_level == nil then
    orig_level = screen.level
    dim_level = function(l)
      orig_level(l and l > 0 and max(1, floor(l * 0.4)) or 0)
    end
  end
  screen.level = C.idle_dim and dim_level or orig_level
  screen.clear()
  draw_header()
  draw_body()
  draw_footer()
  screen.update()
  screen.level = orig_level
end

function M.init(ctx)
  C = ctx
  pget, clamp, window_bounds = ctx.pget, ctx.clamp, ctx.window_bounds
  FPS, PAGES = ctx.FPS, ctx.PAGES
  amp_in, amp_out = ctx.amp_in, ctx.amp_out
  local F = ctx.font
  ptext, ptext_c, ptext_r, chip, text_w =
    F.ptext, F.ptext_c, F.ptext_r, F.chip, F.text_w
end

return M
