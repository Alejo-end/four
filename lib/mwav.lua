-- mwav: the wav files lua reads and writes. Lua cannot read an SC or softcut
-- buffer, so every picture and every analysis of audio in this instrument
-- comes from a FILE: a loaded sample, a PSET's saved take, or a dump of the
-- live take (ctx.take_to_wav). This module is that layer:
--   the RIFF walker and the sample decoders (16/24/32-bit PCM, 32-bit float,
--     the extensible header resolved to its real format)
--   the async fill queue that paints 128-bin strips from a file
--   the sample-rate converter (a windowed sinc), so an off-rate file loads in
--     tune
--   onset and transient detection (TIGHTEN, CHOP)
--   the stereo interleave for exports
-- It knows nothing about the screen: mpages owns the strips and hands their
-- bins tables in.

local floor, sin, cos = math.floor, math.sin, math.cos
local abs, min, max = math.abs, math.min, math.max

local clamp
local SERVER_SR

local M = {}

-- like every lib module: bound to the shared ctx (the server rate, clamp)
function M.init(ctx)
  SERVER_SR, clamp = ctx.SERVER_SR, ctx.clamp
end

-- THE FILL QUEUE: an async waveform read. The FAST part (the header, so the
-- caller knows the duration at once) runs in queue_fill; the slow per-bin peak
-- read is deferred to load_tick (BINS_PER_TICK bins a frame on the redraw
-- clock), so a long file draws IN over about a second instead of freezing the
-- screen. ONE queue serves every strip — the take, the tape
-- — so a pset restore can repaint all of them; a new fill for the SAME bins
-- table supersedes the queued one, and fills for different targets coexist.
-- cancel_fill stops only ITS strip's fill (a CLR must stop the very repaint
-- that would redraw what it just erased, and nothing else).
local fills = {}
local BINS_PER_TICK = 10
function M.cancel_fill(bins)
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

-- walk a RIFF/WAVE file to its fmt + data chunks, leaving f positioned at the
-- data. returns afmt, ch, bits, sr, dpos, dlen — or nil if not RIFF/WAVE.
-- shared by every reader below (the previews, the converter, the scans and
-- open_pcm_mono for the export).
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
      -- WAVE_FORMAT_EXTENSIBLE: the real format is the first two bytes of the
      -- SubFormat GUID (1 PCM, 3 float). ffmpeg and SoX write this header for
      -- anything over 16 bits, so a float render arrives looking like PCM;
      -- decoding its float bits as int32 drew noise and converted to buzz.
      if afmt == 0xFFFE and #fmt >= 26 then
        afmt = string.unpack("<I2", fmt, 25)
      end
      -- a frame wider than the stated depth (24 valid bits stored in 32):
      -- read the CONTAINER, whose top bits hold the sample. blockAlign is the
      -- frame size the file actually uses.
      local ba = string.unpack("<I2", fmt, 13)
      if ch > 0 and ba > ch * (bits // 8) and ba % ch == 0 then
        bits = (ba // ch) * 8
      end
    elseif id == "data" then
      dpos, dlen = f:seek(), sz
      break
    else
      f:seek("cur", sz + (sz % 2))            -- riff chunks are word-aligned
    end
  end
  return afmt, ch, bits, sr, dpos, dlen
end

-- one sample decoder per (format, bit depth), each returning -1..1. 16/24/32-bit
-- PCM and 32-bit float are what norns itself can produce (the engine's take
-- dump, the system tape's print), and 8-bit is what old sample packs carry. ONE table: the waveform preview and the sample-rate converter below
-- read the same files, and a second copy would mean a format could draw
-- correctly and convert to noise, or the reverse.
local DECODE = {
  [1] = {
    -- 8-bit WAV is UNSIGNED, centred on 128 (the lo-fi and vintage packs)
    [8] = function(s, p) return (s:byte(p) - 128) / 128 end,
    [16] = function(s, p) return string.unpack("<i2", s, p) / 32768 end,
    [24] = function(s, p) return string.unpack("<i3", s, p) / 8388608 end,
    [32] = function(s, p) return string.unpack("<i4", s, p) / 2147483648 end,
  },
  [3] = {
    [32] = function(s, p) return string.unpack("<f", s, p) end,
  },
}

-- the decoder for a format/depth, or nil (callers read nil as "no preview" /
-- "refuse to convert" rather than drawing or writing a lie). riff_parse has
-- already resolved an extensible header to its real format.
local function wav_decoder(afmt, bits)
  return DECODE[afmt] and DECODE[afmt][bits]
end

-- open `path` and queue an async fill of `bins`: 128 peak bins spanning
-- `secs` seconds, so a file shorter than the span occupies only its share of
-- the strip (the engine clamps its reads the same way — a longer file only
-- occupies `secs` of the buffer, and drawing more would misalign every
-- playhead and slice). supersedes any queued fill of the SAME bins table.
-- returns the seconds the file occupies, or nil for a format the shared
-- decoders cannot read (the caller leaves the strip alone rather than lie).
function M.queue_fill(path, bins, secs)
  M.cancel_fill(bins)
  local f = io.open(path, "rb")
  if not f then return nil end
  local afmt, ch, bits, _, dpos, dlen = riff_parse(f)
  if not afmt then f:close(); return nil end
  local readpeak = wav_decoder(afmt, bits)
  if not dpos or ch < 1 or not readpeak then
    f:close()
    return nil
  end
  local bps = bits // 8
  local fbytes = ch * bps
  local SR = SERVER_SR
  local frames = min(floor(dlen / fbytes), floor(SR * secs))
  local span = clamp(frames / (SR * secs), 0, 1)
  local nbins = #bins > 0 and #bins or 128      -- an empty strip is a 128-bin one
  local nb = max(1, floor(span * nbins + 0.5))
  -- hand the slow per-bin peak read to load_tick (below). stride the UNPACKS
  -- (not the disk read) so a transient is never skipped — a 40ms drum hit
  -- vanished when this sampled a few windows per bin instead.
  local stride = max(1, floor(frames * ch / 200000))
  -- the stride counts SAMPLES of interleaved audio: an even stride over
  -- stereo lands on the left channel every time, and a right-only hit never
  -- drew. An odd one alternates.
  if ch > 1 and stride % ch == 0 then stride = stride + 1 end
  if frames > 0 then
    fills[#fills + 1] = { f = f, dpos = dpos, fbytes = fbytes, frames = frames,
      nb = nb, bps = bps, step = stride * bps, readpeak = readpeak, i = 0,
      bins = bins, per = BINS_PER_TICK * max(1, nbins // 128) }
  else
    f:close()
  end
  return frames / SR
end

-- fill up to BINS_PER_TICK bins of the queue's HEAD per call (driven by the
-- redraw clock), then close its file and move on. bounded work per frame →
-- the reads never block the UI; each strip draws IN over ~nb/10 frames.
function M.load_tick()
  local p = fills[1]
  if not p then return end
  local bins = p.bins
  -- a finer strip fills more bins a tick, so it draws in over the same time
  local last = min(p.i + p.per, p.nb)
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
-- To change a file's sample rate you have to work out what the signal was
-- doing BETWEEN the samples you have. The shape used to do that is the whole
-- quality question. The simple choice is a cubic curve through four
-- neighbouring samples, which is what a sampler uses for varispeed; it is
-- cheap and it filters nothing.
--
-- Filtering nothing is the problem when converting DOWNWARDS. A 96k file can
-- hold sound up to 48 kHz, and 48k can only hold up to 24 kHz. Anything above
-- that has to be REMOVED first, or it does not disappear: it comes back
-- mirrored into the audible range as a tone that was never in the file. A
-- cubic curve leaves it all there. This shape removes it.
--
-- It is built once per conversion and stored as a table of numbers, so the
-- inner loop is lookups and multiplies rather than trigonometry. Measured at
-- 1.9x the cost of the cubic it replaces (ten seconds of 44.1k stereo: 0.68s
-- against 0.37s on a dev Mac). An import happens once, it already yields to
-- keep the screen alive, and a library converted ahead of time never gets
-- here at all.
local SINC_TAPS = 16          -- samples looked at per output sample; more
                              -- are used when converting downwards
local SINC_PHASES = 512       -- how finely we can land between two samples.
                              -- 1/512 of a sample off is inaudible

-- `cutoff` says how much of the sound has to survive. Converting UP, the
-- source file is the limit and nothing needs removing, so it is 1. Converting
-- DOWN, the new rate is the limit, so it is the ratio between them, and
-- everything above that has to go. Skip this and the mirrored-back tones are
-- the loudest thing in the converted file.
local function build_sinc(cutoff)
  local pi = math.pi
  local half = max(2, floor(SINC_TAPS / 2 / cutoff + 0.5))
  local taps = half * 2
  local k = {}
  for ph = 0, SINC_PHASES - 1 do
    local frac = ph / SINC_PHASES
    local base = ph * taps
    local sum = 0
    for t = 0, taps - 1 do
      local x = (t - half + 1) - frac         -- distance in SOURCE samples
      local a = pi * cutoff * x
      local s = (abs(a) < 1e-9) and cutoff or (cutoff * sin(a) / a)
      -- Taper the ends of the shape smoothly to zero (a Blackman window), or
      -- chopping it off at 16 samples rings.
      -- Measured on a 96k to 48k conversion, as how loud a tone comes back
      -- when it can only get through by being mirrored: 26k -13 dB, 30k
      -- -40 dB, 36k -75 dB, 40k -85 dB. The cubic left all four at -0.2 dB.
      -- So it takes until roughly half again above the limit to get really
      -- quiet, which is what 16 samples buys. What does leak through lands at
      -- 22 kHz and up, where the cubic was dropping the lot into the middle
      -- of the music.
      local u = (x + half) / taps
      s = s * (0.42 - 0.5 * cos(2 * pi * u) + 0.08 * cos(4 * pi * u))
      k[base + t + 1] = s
      sum = sum + s
    end
    -- Make each set of numbers add up to exactly 1. Otherwise each one
    -- amplifies very slightly differently, and since we cycle through them as
    -- we go, that is a volume wobble at the rate we cycle. It is an audible
    -- whine, not a rounding error.
    if sum ~= 0 then
      for t = 1, taps do k[base + t] = k[base + t] / sum end
    end
  end
  return k, half, taps
end

-- open a file for random-access frame reads. nil for anything we cannot
-- decode, so a caller refuses rather than working on silence.
local function open_src(path)
  local f = io.open(path, "rb")
  if not f then return nil, "cannot open " .. tostring(path) end
  local afmt, ch, bits, sr, dpos, dlen = riff_parse(f)
  local dec = afmt and wav_decoder(afmt, bits)
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

-- the converted file is written at 24 BITS. It is the last stop before the
-- engine buffer, and writing 16 threw away the bottom 8 bits of every 24-bit
-- source before it ever got there: a conversion that fixed the pitch and
-- quietly cost the depth.
local SRC_BLOCK = 4096
local SRC_BITS = 24
local SRC_BYTES = SRC_BITS // 8
local SRC_PEAK = 8388607
local SRC_PACK = "<" .. string.rep("i3", SRC_BLOCK * 2)

-- channels, duration and declared rate of a wav, from the header alone. nil
-- for anything that is not a readable RIFF/WAVE: the loaders then load it as
-- it is (no conversion, stereo, the whole region) rather than guessing.
function M.wav_info(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local afmt, ch, bits, sr, _, dlen = riff_parse(f)
  f:close()
  if not afmt or not sr or sr <= 0 or not ch or ch < 1 then return nil end
  local dur = (dlen and dlen > 0 and bits and bits > 0)
    and dlen / (ch * (bits / 8) * sr) or nil
  return ch, dur, sr
end

-- returns true, seconds  — converted and written to out_path
--         false, seconds — already at `sr`, nothing written
--         nil, err       — could not decode (the caller falls back to loading
--                          the file as-is: audible-but-sharp beats silence),
--                          or `yield` returned false ("cancelled")
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
  local obytes = SRC_BYTES * 2                    -- bytes per stereo frame
  of:write("fmt ", string.pack("<I4", 16), string.pack("<I2", 1),
    string.pack("<I2", 2), string.pack("<I4", sr),
    string.pack("<I4", sr * obytes),
    string.pack("<I2", obytes), string.pack("<I2", SRC_BITS))
  of:write("data", string.pack("<I4", 0))

  local ratio = in_sr / sr
  local kern, half, taps = build_sinc(min(1, sr / in_sr))
  local out_n = floor(frames / ratio)
  -- bound the OUTPUT, not just the input: the take buffer only holds max_secs
  -- anyway, and without this a corrupt header declaring a tiny rate expands a
  -- small file into gigabytes (4800 frames at a claimed 1 Hz = 921 MB out) —
  -- while a long DJ mix converts minutes of audio the buffer would discard
  if max_secs then out_n = min(out_n, floor(sr * max_secs)) end
  local L, R = {}, {}
  local out_v = {}
  local written = 0
  while written < out_n do
    local bn = min(SRC_BLOCK, out_n - written)
    local p0 = written * ratio
    local p1 = (written + bn - 1) * ratio
    local lo = floor(p0) - half
    local hi = floor(p1) + half + 1
    read_frames(src, lo, hi - lo + 1, L, R)
    for k = 0, bn - 1 do
      local pos = (written + k) * ratio
      local ip = floor(pos)
      local ph = floor((pos - ip) * SINC_PHASES)
      if ph >= SINC_PHASES then ph = SINC_PHASES - 1 end
      local base = ph * taps
      -- tap t reads source frame ip + t - half + 1; the kernel is even, so
      -- the same coefficient serves both sides of the output position
      local j = ip - lo - half + 2
      local vl, vr = 0, 0
      for t = 0, taps - 1 do
        local c = kern[base + t + 1]
        vl = vl + c * (L[j + t] or 0)
        vr = vr + c * (R[j + t] or 0)
      end
      vl = vl * SRC_PEAK
      if vl > SRC_PEAK then vl = SRC_PEAK elseif vl < -SRC_PEAK then vl = -SRC_PEAK end
      vr = vr * SRC_PEAK
      if vr > SRC_PEAK then vr = SRC_PEAK elseif vr < -SRC_PEAK then vr = -SRC_PEAK end
      out_v[k * 2 + 1] = floor(vl + 0.5)
      out_v[k * 2 + 2] = floor(vr + 0.5)
    end
    local fmt = bn == SRC_BLOCK and SRC_PACK or ("<" .. string.rep("i3", bn * 2))
    of:write(string.pack(fmt, table.unpack(out_v, 1, bn * 2)))
    written = written + bn
    -- every block: with the sinc kernel one block is 16 to 64 taps per output
    -- sample, tens of ms on a Mac and several times that on a Pi, and a yield
    -- (clock.sleep(0)) costs nothing next to it. Every 4 blocks was a cadence
    -- sized for the old 4-tap cubic, and it froze the screen in jerks.
    -- A yield that returns false cancels: the caller no longer wants the
    -- result, so the files close and the part-written output goes.
    if yield and yield() == false then
      close_src(src); of:close(); os.remove(out_path)
      return nil, "cancelled"
    end
  end

  local datalen = written * obytes
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
-- milliseconds wide, i.e. hundreds of frames), so only every 8th frame of a
-- window is decoded at all: decoding them all and then skipping seven of
-- eight spent most of a CHOP on samples the envelope never read.
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
  local env = {}
  local dec, fb, bps, stereo = src.dec, src.fbytes, src.bps, src.ch > 1
  local i, k = from, 0
  while i < to do
    local n = min(win, to - i)
    src.f:seek("set", src.dpos + i * fb)
    local chunk = src.f:read(n * fb) or ""   -- short read = the file lied: zeros
    local got = #chunk // fb
    local e = 0
    for j = 0, got - 1, stride do
      local p = j * fb + 1
      local l = abs(dec(chunk, p))
      local a = l + (stereo and abs(dec(chunk, p + bps)) or l)
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
  local hits = {}
  local last = -99
  for j = 2, k do
    local prev = env[j - 1]
    if env[j] > floorlv and env[j] > prev * 2.2 and (j - last) > 3 then
      last = j
      hits[#hits + 1] = (from + (j - 1) * win) / total
    end
  end
  -- the first slice always starts at the edge. More hits than pads: take them
  -- evenly across the whole take. Stopping at the first few gave the last pad
  -- most of the take (the device: 3.5s of a 6s drum loop).
  local cuts = { from01 }
  local room = maxn - 1
  for c = 1, math.min(#hits, room) do
    local at = #hits <= room and c or floor((c - 1) * #hits / room) + 1
    cuts[#cuts + 1] = hits[at]
  end
  return cuts
end

-- interleave two MONO wavs (the L/R pair write_take dumps) into one stereo
-- wav. A browsable export that reloads via load sample, ZERO new load code.
-- Lua-only (no engine interleave). Returns true on success.
--
-- The samples are spliced as BYTES and the depth is read from the header, so
-- this follows whatever the engine wrote rather than pinning the export to a
-- depth of its own. write_take moved to 24-bit; this needed no other change.
local function open_pcm_mono(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local afmt, ch, bits, sr, dpos, dlen = riff_parse(f)
  if not dpos or afmt ~= 1 or ch ~= 1 or not bits
      or (bits ~= 16 and bits ~= 24 and bits ~= 32) then
    f:close(); return nil
  end
  local bps = bits // 8
  f:seek("set", dpos)
  return f, floor(dlen / bps), sr, bps   -- handle, frames, rate, bytes/sample
end

function M.interleave_wav(pathL, pathR, out, yield)
  local fL, nL, sr, bps = open_pcm_mono(pathL)
  if not fL then return false end
  local fR, nR, _, bpsR = open_pcm_mono(pathR)
  if not fR then fL:close(); return false end
  -- a mismatched pair is not a stereo file: refuse rather than interleave
  -- samples of two different widths into a header that can only claim one
  if bpsR ~= bps then fL:close(); fR:close(); return false end
  local frames = min(nL, nR)
  local of = io.open(out, "wb")
  if not of then fL:close(); fR:close(); return false end
  local fb = bps * 2                              -- bytes per stereo frame
  local datalen = frames * fb
  of:write("RIFF", string.pack("<I4", 36 + datalen), "WAVE")
  of:write("fmt ", string.pack("<I4", 16), string.pack("<I2", 1), string.pack("<I2", 2),
    string.pack("<I4", sr), string.pack("<I4", sr * fb), string.pack("<I2", fb),
    string.pack("<I2", bps * 8))
  of:write("data", string.pack("<I4", datalen))
  local CHUNK = 8192                               -- frames per pass
  -- unpack each mono chunk as integers and pack them back interleaved: two
  -- string.sub calls per frame made millions of short strings for the GC
  local code = "i" .. bps
  local mono_full = "<" .. string.rep(code, CHUNK)
  local st_full = "<" .. string.rep(code, CHUNK * 2)
  local out = {}
  local i, since = 0, 0
  while i < frames do
    local n = min(CHUNK, frames - i)
    local lc, rc = fL:read(n * bps), fR:read(n * bps)
    if not lc or not rc or #lc < n * bps or #rc < n * bps then break end
    local mono = n == CHUNK and mono_full or ("<" .. string.rep(code, n))
    local lv = { string.unpack(mono, lc) }
    local rv = { string.unpack(mono, rc) }
    for k = 1, n do out[2 * k - 1] = lv[k]; out[2 * k] = rv[k] end
    of:write(string.pack(n == CHUNK and st_full or ("<" .. string.rep(code, n * 2)),
      table.unpack(out, 1, n * 2)))
    i = i + n
    since = since + 1
    if yield and since >= 2 then since = 0; yield() end   -- ~16k frames / yield
  end
  -- a short read means the declared header over-states the data; backpatch the
  -- RIFF + data sizes to what we actually wrote so the wav isn't malformed.
  if i < frames then
    local dl = i * fb
    of:seek("set", 4); of:write(string.pack("<I4", 36 + dl))
    of:seek("set", 40); of:write(string.pack("<I4", dl))
  end
  fL:close(); fR:close(); of:close()
  return true
end

return M
