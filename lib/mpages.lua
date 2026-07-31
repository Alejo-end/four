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

local BAND_T, BAND_B = 15, 40  -- visualization band (strip pages)

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
    -- meter what softcut actually records: the ADC tap, the engine output
    -- (cut_source WET), or the blend — a WET print otherwise painted nothing
    -- and left twave_any false over audible tape
    local cs = pget("cut_source", 0)
    local a = max(amp_in[1], amp_in[2]) * (1 - cs)
      + max(amp_out[1], amp_out[2]) * cs
    if a > 0.01 then C.twave_any = true end
    twave_bin = paint_bins(twave, twave_bin, bin, a, pget("tape_pre", 0))
  end
end

-- wipe the tape picture (the CLR gesture starts the loop over)
function M.clear_twave()
  for i = 1, 128 do twave[i] = 0 end
  twave_bin = 0
  C.twave_any = false
end

-- wipe the engine's picture (the engine `clear` command): the buffer is gone, so the strip
-- must go with it — every page that draws the take goes back to inviting one.
function M.clear_wave()
  if M.cancel_load then M.cancel_load() end  -- stop an in-flight fill first
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
-- draws IN over ~1s instead of freezing the screen. A new load supersedes the
-- previous fill; the file handle lives on load_pending until the fill finishes.
local load_pending = nil
local BINS_PER_TICK = 10
local function cancel_load()
  if load_pending then pcall(function() load_pending.f:close() end); load_pending = nil end
end

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

function M.load_wave(path, buf_secs)
  cancel_load()
  -- clear the strip FIRST, so an unsupported-format / unreadable early return
  -- leaves a flat strip instead of the previous take's waveform.
  for i = 1, 128 do wave[i] = 0 end
  wave_bin = 0
  local f = io.open(path, "rb")
  if not f then return nil end
  local afmt, ch, bits, _, dpos, dlen = riff_parse(f)
  if not afmt then f:close(); return nil end
  -- WAVE_FORMAT_EXTENSIBLE → treat as PCM int of the stated depth (the common
  -- 24-bit case; the rare float-extensible falls through to "no preview").
  if afmt == 0xFFFE then afmt = 1 end
  -- one sample → a normalized 0..1 magnitude, per format. 16/24/32-bit PCM and
  -- 32-bit float are what the engine's SoundFile loads, so a 24-bit drop-in now
  -- draws + windows correctly instead of "loads audibly but shows EMPTY" (a
  -- bug this once had for everything but 16-bit).
  local readpeak
  if afmt == 1 and bits == 16 then
    readpeak = function(s, p) local v = string.unpack("<i2", s, p); return (v < 0 and -v or v) / 32768 end
  elseif afmt == 1 and bits == 24 then
    readpeak = function(s, p) local v = string.unpack("<i3", s, p); return (v < 0 and -v or v) / 8388608 end
  elseif afmt == 1 and bits == 32 then
    readpeak = function(s, p) local v = string.unpack("<i4", s, p); return (v < 0 and -v or v) / 2147483648 end
  elseif afmt == 3 and bits == 32 then
    readpeak = function(s, p) local v = string.unpack("<f", s, p); return v < 0 and -v or v end
  end
  if not dpos or ch < 1 or not readpeak then
    f:close()
    return nil
  end
  local bps = bits // 8
  local fbytes = ch * bps
  -- the engine reads WITHOUT sample-rate conversion into a `buf_secs` buffer at
  -- the server's 48k and CLAMPS to it (readChannel numFrames), so the picture
  -- must clamp too — a file longer than the buffer only occupies buf_secs of it;
  -- drawing all of it would stretch the wave and misalign every playhead/slice.
  local SR = 48000
  local frames = min(floor(dlen / fbytes), floor(SR * buf_secs))
  local span = clamp(frames / (SR * buf_secs), 0, 1)
  local nb = max(1, floor(span * 128 + 0.5))
  C.wave_any = span > 0
  -- hand the slow per-bin peak read to load_tick (below). stride the UNPACKS
  -- (not the disk read) so a transient is never skipped — a 40ms drum hit
  -- vanished when this sampled a few windows per bin instead.
  local stride = max(1, floor(frames * ch / 200000))
  if nb >= 1 and frames > 0 then
    load_pending = { f = f, dpos = dpos, fbytes = fbytes, frames = frames,
      nb = nb, bps = bps, step = stride * bps, readpeak = readpeak, i = 0 }
  else
    f:close()
  end
  return frames / SR
end

-- fill up to BINS_PER_TICK waveform bins per call (driven by the redraw clock),
-- then close the file. bounded work per frame → the read never blocks the UI;
-- the waveform draws IN over ~ceil(nb/BINS_PER_TICK) frames.
function M.load_tick()
  local p = load_pending
  if not p then return end
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
          local v = p.readpeak(chunk, pp)
          if v > peak then peak = v end
        end
      end
    end
    wave[i] = peak > 1 and 1 or peak
  end
  p.i = last
  if p.i >= p.nb then p.f:close(); load_pending = nil end
end

-- cancel any in-flight fill (cleanup, or a superseding load)
function M.cancel_load() cancel_load() end

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
  ["@win_move"] = "MOV", ["@loop_move"] = "POS",
  scan = "SPEED", pitch = "PITCH",
  size = "SIZE", spread = "SPRD", density = "DENS", grain_level = "GRN",
  grain_jitter = "GJIT", grain_pitch_spread = "DTUN", grain_shape = "SHP",
  clouds_pos = "POS", clouds_tex = "TEX", clouds_fb = "FB", clouds_lofi = "LOFI",
  kb_octave = "OCT",
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
  scene_slot = "SLOT", scene_morph_amt = "MRF", scene_recall_mode = "QNT",
  orbit_rate = "DRFT", orbit_reach = "RCH", erode = "ERO", wear = "WEAR",
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
  ["@win_move"] = "MOVE", ["@loop_move"] = "MOVE",
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
}

-- normalized 0..1 position of a param, for the dial pointer. bipolar
-- controlspecs (scan, tape_rate) land center at zero, which reads correctly.
local function param_norm(id)
  if not (id and params.lookup[id]) then return nil end
  local p = params:lookup_param(id)
  local v = params:get(id)
  if p.controlspec then
    return clamp(p.controlspec:unmap(v), 0, 1)
  elseif p.count then
    return p.count > 1 and (v - 1) / (p.count - 1) or 0
  elseif p.min and p.max and p.max > p.min then
    return (v - p.min) / (p.max - p.min)
  end
  return clamp(v, 0, 1)
end

-- normalized 0..1 of an ARBITRARY value for a param (not the live value) —
-- used to plot the MOTION lanes' recorded events at their captured heights
local function value_norm(id, v)
  local p = params.lookup[id] and params:lookup_param(id)
  if not p then return 0 end
  if p.controlspec then return clamp(p.controlspec:unmap(v), 0, 1)
  elseif p.count then return p.count > 1 and (v - 1) / (p.count - 1) or 0
  elseif p.min and p.max and p.max > p.min then return (v - p.min) / (p.max - p.min) end
  return clamp(v, 0, 1)
end

-- footer value text for a param: compact, ALL-CAPS abbreviations. a few
-- ids get hand-tuned units (cutoff kHz, pitch semitones, rates x, times);
-- a plain 0..1 linear control reads as a percentage; everything else falls
-- back to the norns string.
local RATE_IDS = { scan = true, tape_rate = true }
local function fmt_value(id)
  -- compound encoder targets ("@") read as their anchor param
  if id == "@win_move" then id = "pos_start" end
  if id == "@loop_move" then id = "loop_start" end
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
    return v >= 0.9995 and "1.0S" or string.format("%dMS", floor(v * 1000 + 0.5))
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
  seq_slice = true, motion_lane = true, scene_slot = true,
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
  local val
  if id and (turning or SELECTOR_IDS[id]) then val = fmt_value(id) end
  -- the knob being ADJUSTED keeps its FULL word next to the value; the
  -- pocket below hides whatever that overlaps, and everything returns when
  -- the swell ends. selectors reading at rest keep the SHORT form because
  -- they sit beside the key words permanently, with no pocket.
  local full = turning or not val
  local lab = label_for(id, full)
  local lvl = turning and 15 or 6
  local x = rx - label_total(lab, val)
  if full and not turning and minx and x < minx then
    -- at rest a full word that would cross the key words drops to SHORT
    lab = label_for(id, false)
    x = rx - label_total(lab, val)
  elseif turning and x < 2 then
    -- while turning the pocket handles overlap; abbreviate only if the
    -- full word plus value would run off the screen itself
    lab = label_for(id, false)
    x = rx - label_total(lab, val)
  end
  if turning and val then
    -- the setting being adjusted owns its ground: knock out a pocket first,
    -- so a long value never collides with the key words (or anything else)
    -- underneath — they vanish for the swell and come back after. (the old
    -- top-right readout's pocket rule, applied to the footer row.)
    screen.level(0)
    screen.rect(x - 3, 56, rx - x + 5, 8)
    screen.fill()
  end
  ptext(lab, x, FY, 1, lvl)
  screen.level(lvl)
  screen.rect(x + text_w(lab, 1) + 1, FY + 2, 1, 1)
  screen.fill()
  if val then ptext(val, x + text_w(lab, 1) + 3, FY, 1, lvl) end
  return x
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
    local el = ((clamp(C.rec_phase, 0, 1) - C.rec_arm_phase) % 1) * 60
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
  ptext_r(string.format("%.1fS", lspan * 60), 126, 12, 1, 4)
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
--     master VU; the whole signal path on one screen)
-- ============================================================================
local function body_MIX(frame)
  -- each lane's energy is its deck's REAL gain — the same law
  -- Mtape.update_mix sends (trim x crossfade plateau x master x STOP)
  local mixv = pget("mix", 0.5)
  local out = pget("out_level", 1) * (1 - pget("stop_all", 0))
  local eng_g = pget("sc_level", 1) * min(1, 2 * (1 - mixv)) * out
  local tape_g = pget("cut_level", 1) * min(1, 2 * mixv) * out
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
  screen.level(4)
  for i = 0, 8 do screen.rect(bx0 + i * sw, by - 5, 1, 10) end
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
    ptext_c(tostring(i + 1), cx + sw / 2, 31, 1, lit and 0 or (cur and 15 or 6))
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
  -- a quiet cue for the sound-lock surface (the two face encoders), so the
  -- freed row below the slices isn't blank (82px, well under the 124 limit)
  ptext_c("E2 SLICE - E3 PITCH", 64, 46, 1, 3)
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
    eros_acc = eros_acc + (1 / FPS) / (span * 60)
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
  ptext_r("GEN " .. eros_gen, 126, 12, 1, e > 0 and 13 or 5)
  if e > 0 and (frame % 8) < 5 then chip("ERODING", 2, 12) end
end

local BODY = {
  ORBIT = body_ORBIT, EROSION = body_EROSION,
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
  if pget("drive", 0) > 0.001 or pget("delay_mix", 0) > 0.001
      or pget("rev_mix", 0) > 0.001 or pget("shimmer", 0) > 0.001
      or pget("clouds_fb", 0) > 0.001 or pget("resample", 0) > 0.001
      or pget("regen", 0) > 0.001 then return false end
  if pget("freeze", 0) == 1 or pget("pv_freeze", 0) == 1 then return false end
  local dw = pget("dry_wet", 0)
  if dw > 0.001 then                    -- the filter must be out of the way
    if pget("filt_type", 1) ~= 1 or pget("cutoff", 20000) < 19000
        or pget("resonance", 0) > 0.02 then return false end
  end
  -- the tape deck must not be adding its own material
  if C.twave_any and pget("mix", 0.5) > 0.02 then return false end
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

function M.redraw()
  screen.clear()
  draw_header()
  draw_body()
  draw_footer()
  screen.update()
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
