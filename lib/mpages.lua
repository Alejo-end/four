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
local log = math.log

local C     -- shared ctx, bound at init
local pget, clamp, window_bounds, FPS, PAGES
local ptext, ptext_c, ptext_r, chip, text_w
local particles_draw
local GRAIN_CY, GRAIN_CH
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
    local a = max(amp_in[1], amp_in[2])
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

-- wipe the engine's picture (S21 `clear`): the buffer is gone, so the strip
-- must go with it — every page that draws the take goes back to inviting one.
function M.clear_wave()
  for i = 1, 128 do wave[i] = 0 end
  wave_bin = 0
  C.wave_any = false
end

-- paint the wave display straight out of a FILE (S21 `read_file`).
-- lua cannot read the engine's SC buffer, so a loaded sample would otherwise be
-- INVISIBLE on every page that draws the take — REC/WINDOW/PADS would sit there
-- saying "EMPTY - K2 REC" over audio you can hear. so we read the file's peaks
-- ourselves.
-- seek-and-peak: 128 bins, a small window sampled at each (~128KB touched, not
-- the whole 11MB), so a load never stalls the script.
-- 16-bit PCM wav only (what norns records and what dust ships). anything else
-- returns nil and the caller leaves the display alone rather than draw a lie.
-- returns: the seconds the sample occupies IN THE BUFFER, or nil.
function M.load_wave(path, buf_secs)
  local f = io.open(path, "rb")
  if not f then return nil end
  local hdr = f:read(12)
  if not hdr or #hdr < 12 or hdr:sub(1, 4) ~= "RIFF" or hdr:sub(9, 12) ~= "WAVE" then
    f:close()
    return nil
  end
  local ch, bits, dpos, dlen = 1, 16, nil, 0
  while true do
    local c = f:read(8)
    if not c or #c < 8 then break end
    local id = c:sub(1, 4)
    local sz = string.unpack("<I4", c, 5)
    if id == "fmt " then
      local fmt = f:read(sz)
      if not fmt or #fmt < 16 then break end
      ch = string.unpack("<I2", fmt, 3)
      bits = string.unpack("<I2", fmt, 15)
    elseif id == "data" then
      dpos, dlen = f:seek(), sz
      break
    else
      f:seek("cur", sz + (sz % 2))   -- riff chunks are word-aligned
    end
  end
  if not dpos or bits ~= 16 or ch < 1 then
    f:close()
    return nil
  end
  local fbytes = ch * 2
  local frames = floor(dlen / fbytes)
  -- the engine reads WITHOUT sample-rate conversion into a 60s buffer at the
  -- server's 48k, so what decides the picture is how many FRAMES the file
  -- occupies — not its own duration at its own rate.
  local SR = 48000
  local span = clamp(frames / (SR * buf_secs), 0, 1)
  local nb = max(1, floor(span * 128 + 0.5))
  for i = 1, 128 do wave[i] = 0 end
  -- peak across the WHOLE of each bin, striding so the work stays bounded
  -- whatever the file length. sampling a few small windows per bin instead
  -- looks fine on continuous material and loses TRANSIENTS entirely — a 40ms
  -- drum hit vanished from the picture, which is the exact wrong failure for a
  -- sampler. ~200k unpacks total (tens of ms even on a pi4), and a stride of
  -- N still lands many hits inside any transient worth drawing.
  local stride = max(1, floor(frames * ch / 200000))
  local step = stride * 2                    -- bytes; even, so shorts stay aligned
  for i = 1, nb do
    local b0 = floor((i - 1) / nb * frames)
    local n = floor(i / nb * frames) - b0
    local peak = 0
    if n > 0 then
      f:seek("set", dpos + b0 * fbytes)
      local chunk = f:read(n * fbytes)
      if chunk then
        for p = 1, #chunk - 1, step do
          local v = string.unpack("<i2", chunk, p)
          if v < 0 then v = -v end
          if v > peak then peak = v end
        end
      end
    end
    wave[i] = peak / 32768
  end
  f:close()
  wave_bin = 0
  C.wave_any = span > 0
  return frames / SR
end

-- deterministic dither, same trick as the mockups
local function hash(x, y, sd)
  local f = sin(x * 12.9898 + y * 78.233 + sd * 37.719) * 43758.5453
  return f - floor(f)
end

-- short footer labels per param id (4-5 chars, mockup style)
local SHORT = {
  mix = "MIX", out_level = "OUT", sc_level = "ENG", cut_level = "TAPE",
  input_level = "IN", monitor_level = "MON",
  output_level = "OUT", headphone_gain = "HP",
  rec_level = "LVL", pre_level = "OVR", dry_wet = "D/W", resample = "RSMP",
  regen = "REGN",
  pos_start = "STRT", scan = "SCAN", pos_end = "END", pos_jitter = "JIT",
  size = "SIZE", spread = "SPRD", density = "DENS", grain_level = "GRN",
  grain_jitter = "GJIT", grain_pitch_spread = "DTUN", grain_shape = "SHP",
  clouds_pos = "POS", clouds_tex = "TEX", clouds_fb = "FB", clouds_lofi = "LOFI",
  clouds_mode = "MODE",
  pitch = "PTCH", warp_window = "WIN", warp_rand = "RAND", kb_octave = "OCT",
  tape_rate = "RATE", tape_pre = "OVR", loop_start = "STRT", loop_end = "END",
  cutoff = "CUT", resonance = "RES", drive = "DRV",
  delay_mix = "MIX", delay_time = "TIME", delay_fb = "FDBK",
  rev_size = "SIZE", rev_mix = "MIX",
  rev_decay = "DEC", rev_damp = "DMP", rev_early = "DIFF",
  rev_moddepth = "MOD", rev_modfreq = "MRAT", rev_low = "LOW",
  rev_mid = "MID", rev_high = "HIGH", rev_lowcut = "LCUT", rev_highcut = "HCUT",
  shimmer = "SHMR", shimmer_pitch = "OCT", shimmer_tone = "AIR",
  voices = "VOX", voice_atk = "ATK", voice_rel = "REL",
  motion_lane = "LANE", motion_depth = "AMT",
  seq_euclid = "EUC", seq_len = "LEN", seq_div = "DIV", seq_slice = "SLC",
  clock_tempo = "BPM",
  scene_slot = "SLOT", scene_morph_a = "A", scene_morph_b = "B",
  scene_morph_amt = "MRPH",
  -- nicer MOTION lane labels for params that aren't footer encoders (safe:
  -- SHORT is only read for the current page's enc ids + MOTION lane names)
  mode = "MODE", filt_type = "FILT", pan = "PAN", freeze = "FRZ",
  pv_freeze = "PVFZ", tape_freeze = "TFRZ", tape_reverse = "TREV",
  clouds_mode = "CMOD",
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
  if not (id and params.lookup[id]) then return "--" end
  if id == "motion_lane" then
    -- show the SELECTED lane's param name (or "-" when none picked)
    local ids = C.motion and C.motion.lane_ids
    local n = ids and #ids or 0
    local sel = clamp(floor(params:get(id) + 0.5), 0, n)
    if n == 0 or sel == 0 then return "-" end
    return SHORT[ids[sel]] or string.upper(ids[sel])
  end
  if id == "clock_tempo" then
    return tostring(floor(params:get(id) + 0.5))
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

-- footer knob (toy): a double-ring outline with a pointer at
-- pi*0.75 + val*pi*1.5; while its param is being turned it flips to a
-- FILLED disc with the pointer knocked out — the "you're touching this" cue
local function draw_knob(cx, cy, val, turning)
  local r = 8
  local a = math.pi * 0.75 + clamp(val or 0, 0, 1) * math.pi * 1.5
  local ix, iy = cx + cos(a) * r * 0.25, cy + sin(a) * r * 0.25
  local ox, oy = cx + cos(a) * (r - 3), cy + sin(a) * (r - 3)
  if turning then
    screen.level(15)
    screen.circle(cx, cy, r)
    screen.fill()
    screen.level(0)
    screen.move(ix, iy) screen.line(ox, oy)
    screen.stroke()
    screen.rect(ox - 1, oy - 1, 2, 2)
    screen.fill()
  else
    screen.level(15)
    screen.circle(cx, cy, r)
    screen.stroke()
    screen.circle(cx, cy, r - 2)
    screen.stroke()
    screen.move(ix, iy) screen.line(ox, oy)
    screen.stroke()
    screen.rect(ox - 1, oy - 1, 2, 2)
    screen.fill()
  end
end

-- key pill (toy): capsule at y52 h10, filled+inverted while active/held,
-- 1px outline otherwise. caller supplies x and the shared width.
local function draw_pill(x, w, label, on)
  if on then
    screen.level(15)
    screen.rect(x, 52, w, 10)
    screen.fill()
    ptext_c(label, x + w / 2, 54, 1, 0)
  else
    screen.level(4)
    screen.rect(x + 0.5, 52.5, w, 10)
    screen.stroke()
    ptext_c(label, x + w / 2, 54, 1, 9)
  end
end

-- footer (toy): two knobs at the edges, the E2/E3 label+value inline
-- between them (row 1), and the K2/K3 pills (row 2). no top-right pocket —
-- the encoder value lives here and its knob fills while turning.
local function draw_footer()
  local id2, id3 = C.enc_param(2), C.enc_param(3)
  draw_knob(10, 53, param_norm(id2), is_turning(id2))
  draw_knob(117, 53, param_norm(id3), is_turning(id3))
  -- row 1 values (drop labels when the four strings would crowd)
  local l2, v2 = SHORT[id2] or "--", fmt_value(id2)
  local l3, v3 = SHORT[id3] or "--", fmt_value(id3)
  if text_w(l2, 1) + text_w(v2, 1) + text_w(l3, 1) + text_w(v3, 1) + 14 > 85 then
    ptext(v2, 21, 44, 1, 15)
    ptext(v3, 106 - text_w(v3, 1), 44, 1, 15)
  else
    ptext(l2, 21, 44, 1, 4)
    ptext(v2, 21 + text_w(l2, 1) + 3, 44, 1, 15)
    local v3x = 106 - text_w(v3, 1)
    ptext(l3, v3x - 3 - text_w(l3, 1), 44, 1, 4)
    ptext(v3, v3x, 44, 1, 15)
  end
  -- row 2 pills: shared width, same order as the hardware keys
  local k2, k3 = C.key_def(2), C.key_def(3)
  local lab2 = k2 and k2.label or "--"
  local lab3 = k3 and k3.label or "--"
  local pw = clamp(max(text_w(lab2, 1), text_w(lab3, 1)) + 8, 18, 42)
  local held = C.held
  local on2 = k2 ~= nil and ((k2.lit ~= nil and pget(k2.lit, 0) == 1) or held[2] == true)
  local on3 = k3 ~= nil and ((k3.lit ~= nil and pget(k3.lit, 0) == 1) or held[3] == true)
  draw_pill(64 - pw - 2, pw, lab2, on2)
  draw_pill(66, pw, lab3, on3)
end

-- buffer strip: waveform of recorded material (bright inside the window),
-- window underline, playhead needle, write-head ticks
local function draw_strip(handles)
  local lo, hi, _ = window_bounds()
  local mid = (BAND_T + BAND_B) / 2
  local half = (BAND_B - BAND_T) / 2

  -- baseline: an empty buffer reads as a thin line, not a grey block
  screen.level(1)
  screen.move(0, mid)
  screen.line(128, mid)
  screen.stroke()

  -- waveform columns (sqrt + 2x gain for visual headroom on quiet material).
  -- disjoint verticals raster the same under one stroke per brightness run,
  -- so up to 128 stroke calls collapse into at most three
  local run = 0
  for x = 0, 127 do
    local a = wave[x + 1]
    if a > 0.002 then
      local h = clamp(sqrt(min(a * 2, 1)) * half, 1, half)
      local nx = x / 127
      local lvl = (nx >= lo and nx <= hi) and 12 or 2
      if lvl ~= run then
        if run ~= 0 then screen.stroke() end
        screen.level(lvl)
        run = lvl
      end
      screen.move(x, mid - h)
      screen.line(x, mid + h)
    end
  end
  if run ~= 0 then screen.stroke() end

  -- window underline + optional edge handles
  screen.level(4)
  screen.move(lo * 127, BAND_B + 2)
  screen.line(hi * 127, BAND_B + 2)
  screen.stroke()
  if handles then
    screen.level(15)
    for k = 1, 2 do
      local e = k == 1 and lo or hi
      screen.move(e * 127, BAND_T - 2)
      screen.line(e * 127, BAND_B + 2)
    end
    screen.stroke()
  end

  -- playhead needle — only once there's material to play; an empty buffer
  -- keeps the strip quiet so the EMPTY invitation stands alone
  if C.wave_any then
    screen.level(15)
    local px = clamp(C.play_phase, 0, 1) * 127
    screen.move(px, BAND_T - 2)
    screen.line(px, BAND_B + 2)
    screen.stroke()
  end

  -- write head: dim ticks top+bottom while recording, so capture is visible
  if pget("rec", 0) == 1 and pget("freeze", 0) == 0 then
    local wx = clamp(C.rec_phase, 0, 1) * 127
    screen.level(6)
    screen.move(wx, BAND_T - 2)
    screen.line(wx, BAND_T + 4)
    screen.move(wx, BAND_B - 4)
    screen.line(wx, BAND_B + 2)
    screen.stroke()
  end
end

-- LEVEL fader layout per alt layer: { x, label, param id }. the left
-- fader's vu meters the input, the right one the output, in either layer
local LEVEL_DEFS = {
  { 40, "IN", "input_level" },
  { 88, "OUT", "output_level" },
}
local LEVEL_DEFS_ALT = {
  { 40, "MON", "monitor_level" },
  { 88, "HP", "headphone_gain" },
}

local REEL_X = { 46, 86 }   -- TAPE page reel centers
local reel_angle = 0        -- TAPE page reel rotation, driven by tape rate

local delay_heights = {}    -- DELAY bounce peaks, slots reused every frame
local delay_hop = 0         -- DELAY page ball position, in hops (1 hop = 1 repeat)

-- (the MIX page's synthetic TAPE_PREVIEW waveform lived here. it drew a fake
-- picture "so the lane always reads as material" — i.e. it claimed the tape
-- had audio whether it did or not. deleted: MIX draws the real `twave` now.
-- if a lane can't tell the truth, it shouldn't draw.)

-- GRAIN stereo-field pool: preallocated flat arrays (no per-frame alloc),
-- spawned/aged in draw_grain_field, capped at GR_MAX
local GR_MAX = 110
-- gr_dj = per-grain drift jitter (grain_pitch_spread, S7): grains scatter
-- apart vertically instead of drifting as one
local gr_x, gr_y0, gr_age, gr_life, gr_len, gr_dj = {}, {}, {}, {}, {}, {}
local gr_n = 0
local gr_last_frame = -1
for i = 1, GR_MAX do
  gr_x[i], gr_y0[i], gr_age[i], gr_life[i], gr_len[i], gr_dj[i] = 0, 0, 0, 0, 0, 0
end

-- LEVEL meter statics: one slow-decaying peak per bar (IN, OUT), and the
-- quarter-tick fractions (static so the hot path allocates nothing)
local lvl_peak = { 0, 0 }
local lvl_last_frame = -1
local LVL_TICKS = { 0.25, 0.5, 0.75 }

-- PADS page: per-pad "a voice is sounding" flags, refilled each frame from
-- ctx.pad_held (static so the hot path allocates nothing)
local pad_lit = {}

-- FILTER page statics: log-frequency axis 20Hz..20kHz over 128 columns,
-- gridline columns at 100Hz/1k/10k, the 0dB reference row, and a reusable
-- per-column response buffer (the curve is recomputed each frame from the
-- real biquad magnitude — a few muls and one log per column, FILTER only)
local FILT_FREQ, FILT_Y = {}, {}
for x = 0, 127 do
  FILT_FREQ[x + 1] = 20 * (1000 ^ (x / 127))
  FILT_Y[x + 1] = 0
end
local FILT_GRID_X = {}
for i, f in ipairs({ 100, 1000, 10000 }) do
  FILT_GRID_X[i] = floor(log(f / 20) / log(1000) * 127 + 0.5)
end
local FILT_DB_TOP, FILT_DB_RANGE = 18, 48  -- +18dB at BAND_T .. -30dB at BAND_B
local FILT_DB0_Y = floor(BAND_T
  + FILT_DB_TOP * (BAND_B - BAND_T) / FILT_DB_RANGE + 0.5)

-- STRETCH lane curve, shared by the mode textures (a closure built inside
-- the frame would be gc churn at 15fps)
local function stretch_wy(x, ph, rate)
  return 30 + sin((x + ph) * 0.35 * rate) * 6
end

-- each page draws its body through this dispatch table (the idiomatic
-- Lua "switch"): one body_<PAGE> function per page, selected by name. the
-- BODY table is built ONCE at load, so the redraw stays allocation-free.
local function body_MIX(frame)
  -- mix page: the two decks, drawn by what they are ACTUALLY doing. each lane's
  -- energy is its deck's REAL gain — the same law Mtape.update_mix sends to the
  -- engine and softcut (trim x the crossfade plateau x master x STOP) — so a
  -- deck you cannot hear lies flat and dim. that is the house audibility rule,
  -- and this is the page whose entire job is telling you which deck you hear.
  --
  -- the TAPE lane used to draw a STATIC SYNTHETIC waveform, "so the lane always
  -- reads as material". it showed a picture whether the tape held audio or not
  -- — which is exactly how a tape deck you didn't mean to arm hides from you
  -- while it loops your take back once a minute. it now draws the REAL recorded
  -- picture, with the head that is always running on it.
  local mixv = pget("mix", 0.5)
  local out = pget("out_level", 1) * (1 - pget("stop_all", 0))
  local eng_g = pget("sc_level", 1) * min(1, 2 * (1 - mixv)) * out
  local tape_g = pget("cut_level", 1) * min(1, 2 * mixv) * out
  local eng_on = pget("mode", 2) ~= 1 and eng_g > 0.001
  local sd = floor(frame / 2)
  ptext("ENG", 2, 13, 1, 4)
  if not eng_on then
    screen.level(1)
    screen.move(26, 18.5) screen.line(122, 18.5)
    screen.stroke()
  else
    screen.level(12)
    local g = clamp(eng_g, 0, 1)
    local dens = 0.1 + g * 0.4
    local spread = 1 + g * 5
    for x = 26, 122 do
      if hash(x, 1, sd) < dens then
        screen.rect(x, 18 + (hash(x, 7, sd) - 0.5) * 2 * spread, 1, 1)
      end
    end
    screen.fill()
  end
  -- crossfader between the lanes
  screen.level(2)
  screen.move(26, 24.5) screen.line(122, 24.5)
  screen.stroke()
  screen.level(15)
  screen.rect(26 + mixv * 94, 21, 3, 7)
  screen.fill()
  -- TAPE lane: the real recorded picture, scaled by the deck's real gain
  ptext("TAPE", 2, 30, 1, 4)
  screen.level(1)
  screen.move(26, 33) screen.line(122, 33)
  screen.stroke()
  local tape_on = C.twave_any and tape_g > 0.001
  if tape_on then
    local g = clamp(tape_g, 0, 1)
    screen.level(10)
    for x = 26, 122 do
      local a = twave[floor((x - 26) / 96 * 127) + 1] or 0
      if a > 0.002 then
        local h = clamp(sqrt(min(a * 2, 1)) * g * 4, 0.5, 4)
        screen.move(x, 33 - h) screen.line(x, 33 + h)
      end
    end
    screen.stroke()
  end
  -- the tape head. softcut is ALWAYS looping — play/loop are set once at init
  -- and never cleared — so this is the cue that says "this deck is live" even
  -- when you thought it wasn't. bright when audible, dim when thrown away.
  if C.twave_any then
    screen.level(tape_on and 15 or 4)
    local hx = 26 + clamp(C.tape_phase, 0, 1) * 96
    screen.move(hx, 29.5) screen.line(hx, 36.5)
    screen.stroke()
  end
end

local function body_LEVEL(frame)
  -- level page (toy): two stereo meter bars — IN (top), OUT (bottom).
  -- each frames L (upper lane) and R (lower lane) as lit segments; a
  -- peak-hold pip holds the loudest recent level, a clip lamp blinks
  -- past 0.93, and a tab under the bar marks the gain setting.
  local bx0, bw = 24, 97
  local newframe = C.frame ~= lvl_last_frame
  for b = 1, 2 do
    local by = b == 1 and 16 or 29
    local aL = b == 1 and amp_in[1] or amp_out[1]
    local aR = b == 1 and amp_in[2] or amp_out[2]
    local gid = C.enc_param(b == 1 and 2 or 3)
    ptext(b == 1 and "IN" or "OUT", 2, by + 2, 1, 4)
    -- frame + quarter ticks
    screen.level(1)
    screen.rect(bx0, by, bw, 9)
    for t = 1, #LVL_TICKS do
      local tx = bx0 + floor(LVL_TICKS[t] * bw)
      screen.move(tx, by) screen.line(tx, by + 9)
    end
    screen.stroke()
    -- stereo lanes: L at y+2, R at y+6, segmented, tip bright when hot
    local peak = 0
    for lane = 0, 1 do
      local sig = sqrt(clamp(lane == 0 and aL or aR, 0, 1))
      if sig > peak then peak = sig end
      local ly = by + 2 + lane * 4
      local top = floor(sig * bw)
      screen.level(10)
      for sx = 0, top, 3 do screen.rect(bx0 + sx, ly, 2, 2) end
      screen.fill()
      if sig > 0.75 and top >= 3 then
        screen.level(15)
        screen.rect(bx0 + floor(top / 3) * 3, ly, 2, 2)
        screen.fill()
      end
    end
    -- peak-hold pip, slow decay
    if newframe then lvl_peak[b] = max(peak, lvl_peak[b] - 0.0045) end
    if lvl_peak[b] > 0.02 then
      screen.level(15)
      screen.rect(bx0 + floor(lvl_peak[b] * bw), by, 1, 9)
      screen.fill()
    end
    -- clip lamp, blinking, past 0.93
    if lvl_peak[b] > 0.93 and (frame % FPS) < (FPS / 2) then
      screen.level(15)
      screen.rect(123, by + 2, 3, 6)
      screen.fill()
    end
    -- gain-setting tab under the bar
    screen.level(8)
    screen.rect(bx0 + floor((param_norm(gid) or 0) * bw) - 1, by + 9, 3, 2)
    screen.fill()
  end
  if newframe then lvl_last_frame = C.frame end
end

local function body_REC(frame)
  -- rec page (toy): the buffer strip with the grain cloud over it; the
  -- write head lays material, trailing a short afterglow on the band
  -- edges. input meter rides the right edge; empty buffer invites a take.
  draw_strip(false)
  particles_draw()
  if not C.wave_any and pget("rec", 0) == 0 then
    ptext_c("EMPTY - K2 REC", 64, 26, 1, 3)
  end
  local h = floor(clamp(sqrt(max(amp_in[1], amp_in[2])) * (BAND_B - BAND_T), 0, BAND_B - BAND_T))
  if h > 0 then screen.level(15) screen.rect(125, BAND_B - h, 3, h) screen.fill() end
  -- afterglow trail behind the write head (band edges, fading 9->1)
  if pget("rec", 0) == 1 and pget("freeze", 0) == 0 then
    local wx = clamp(C.rec_phase, 0, 1) * 127
    for d = 1, 14 do
      local x = wx - d
      local lv = floor(9 - (d - 1) / 13 * 8 + 0.5)
      if x >= 0 and lv > 0 then
        screen.level(lv)
        screen.rect(x, BAND_T - 1, 1, 1)
        screen.rect(x, BAND_B, 1, 1)
        screen.fill()
      end
    end
  end
  -- resample bakes the OUTPUT into an armed take; regen (S17) feeds it back
  -- continuously (self-resampling). badge whichever is engaged, side by side.
  local bx = 2
  if pget("resample", 0) > 0 then bx = bx + chip("RSMP", bx, 13) + 2 end
  if pget("regen", 0) > 0 then chip("REGN", bx, 13) end
end

local function body_WINDOW(frame)
  -- window page (toy): the buffer strip with the slice handles; jitter
  -- (alt) scatters ghost dots around the playhead — the read-position
  -- blur the engine's TRand makes audible.
  draw_strip(true)
  local _, _, span = window_bounds()
  local jit = pget("pos_jitter", 0)
  if jit > 0 and C.wave_any then
    local phx = clamp(C.play_phase, 0, 1) * 127
    local reach = jit * span * 127
    local sd = floor(frame / 2)
    screen.level(3)
    for k = 1, 12 do
      local gx = phx + (hash(k, 3, sd) - 0.5) * 2 * reach
      if gx >= 0 and gx <= 127 then
        screen.rect(gx, BAND_T + 2 + hash(k, 9, sd) * (BAND_B - BAND_T - 4), 1, 1)
      end
    end
    screen.fill()
  end
end

local function body_GRAIN(frame)
  -- grain page (toy): a thin source ruler up top, then the granular cloud
  -- drawn AS THE CHOSEN CLOUDS MODE — the K3 option becomes the picture.
  -- GRANULAR = a field of discrete grains (density=count, size=tick len,
  -- spread=scatter, pitch=drift, jitter=x-scatter). STRETCH = overlapping
  -- elongated windows (size=length, density=layers, tex=smoothness). LOOP =
  -- a loop bar with echo ghosts (fb=ghosts, pos=position). SPECTRAL =
  -- vertical frequency columns (size/tex shape the profile). shared: pos
  -- shifts center, lofi coarsens, and a silent voice lies flat + dim.
  local lo, hi = window_bounds()
  local playing = C.wave_any and pget("mode", 2) ~= 1
  local cm = pget("clouds_mode", 1)
  -- source ruler at y12: window span, handles, playhead
  screen.level(6)
  screen.move(lo * 127, 12) screen.line(hi * 127, 12)
  screen.stroke()
  screen.level(10)
  screen.rect(lo * 127, 10, 1, 5)
  screen.rect(hi * 127, 10, 1, 5)
  screen.fill()
  if playing then
    screen.level(15)
    screen.rect(clamp(C.play_phase, 0, 1) * 127, 10, 1, 5)
    screen.fill()
  end
  -- age the grain pool every frame (particles always decay out); spawn
  -- only in GRANULAR while playing — the other modes draw procedurally, so
  -- mode 1's seeded RNG stream (and its render) stays byte-identical
  if C.frame ~= gr_last_frame then
    gr_last_frame = C.frame
    local w = 0
    for i = 1, gr_n do
      gr_age[i] = gr_age[i] + 1
      if gr_age[i] < gr_life[i] then
        w = w + 1
        if w ~= i then
          gr_x[w], gr_y0[w], gr_age[w], gr_life[w], gr_len[w], gr_dj[w] =
            gr_x[i], gr_y0[i], gr_age[i], gr_life[i], gr_len[i], gr_dj[i]
        end
      end
    end
    gr_n = w
    if playing and cm == 1 then
      local dN = param_norm("density") or 0
      local sN = param_norm("size") or 0
      local jit = pget("pos_jitter", 0)
      local _, _, span = window_bounds()
      local spr = pget("spread", 0.5)
      local gj = pget("grain_jitter", 0)
      local gps = pget("grain_pitch_spread", 0)
      local px = clamp(C.play_phase, 0, 1)
      local p = 0.06 + dN * 0.62
      for _ = 1, (dN > 0.7 and 2 or 1) do
        if math.random() < p and gr_n < GR_MAX then
          gr_n = gr_n + 1
          gr_x[gr_n] = clamp(px + (math.random() * 2 - 1) * jit * span, 0, 1) * 127
          gr_y0[gr_n] = 30 + (math.random() * 2 - 1) * spr * 10
          gr_age[gr_n] = 0
          gr_life[gr_n] = 12 + sN * 26
          -- per-grain size jitter (guarded so default 0 keeps the RNG
          -- stream — and the renders — identical)
          gr_len[gr_n] = (1 + sN * 9) *
            (1 + (gj > 0 and (math.random() * 2 - 1) * gj or 0))
          -- per-grain detune -> its own drift rate (semitones -> the same
          -- log2 mapping the base drift uses: st/12 * 0.35 * 0.5)
          gr_dj[gr_n] = gps > 0
            and (math.random() * 2 - 1) * gps / 12 * 0.35 * 0.5 or 0
        end
      end
    end
  end
  if cm == 1 then
    -- GRANULAR: discrete grains over the centerline. pitch tilts the drift;
    -- each grain's own detune (gr_dj) adds so a spread cloud fans apart.
    screen.level(1)
    screen.move(0, 30) screen.line(128, 30)
    screen.stroke()
    local drift = log(pget("pitch", 1)) / log(2) * 0.35 * 0.5
    for i = 1, gr_n do
      local lv = floor(12 - gr_age[i] / gr_life[i] * 11 + 0.5)
      if lv >= 1 then
        local y = gr_y0[i] + (drift + gr_dj[i]) * gr_age[i]
        if y < 20 then y = 20 elseif y > 40 then y = 40 end
        screen.level(lv)
        screen.rect(gr_x[i] - gr_len[i] / 2, y, gr_len[i], 1)
        screen.fill()
      end
    end
  elseif not playing then
    -- silence: mode OFF or an empty buffer — the cloud lies flat and dim
    -- (the mode name still says which algorithm is armed)
    screen.level(1)
    screen.move(0, 30) screen.line(128, 30)
    screen.stroke()
  elseif cm == 2 then
    -- STRETCH: grains stretched into sustained, OVERLAPPING windows. each
    -- layer is a three-step brightness envelope (dim full tail -> mid ->
    -- bright dashed core) so it reads as a fade-ended window, not a bare
    -- line. density = layer count, size = length, clouds_tex = core
    -- density (smoothness), clouds_pos = center, clouds_lofi = dash chunk.
    local dN = param_norm("density") or 0
    local sN = param_norm("size") or 0
    local tex = pget("clouds_tex", 0.5)
    local pos = pget("clouds_pos", 0.5)
    local lofi = pget("clouds_lofi", 0)
    local layers = 2 + floor(dN * 5)
    local len = 24 + sN * 96
    local cx = pos * 127
    local sd = floor(frame / 3)
    local dy = 16 / max(layers - 1, 1)
    -- tails (level 3, full length) then mid (level 7, 65%): two batched
    -- fills, brightening toward each layer's center for the window shape
    for pass = 1, 2 do
      local frac = pass == 1 and len or len * 0.65
      screen.level(pass == 1 and 3 or 7)
      for l = 1, layers do
        local ly = 22 + (l - 1) * dy
        local dr = sin(frame * 0.06 + l * 1.3) * 5
        local x0 = clamp(cx - frac / 2 + dr, 0, 127)
        local x1 = clamp(cx + frac / 2 + dr, 0, 127)
        if x1 > x0 then screen.rect(x0, ly, x1 - x0, 1) end
      end
      screen.fill()
    end
    -- cores: bright dashed centers (tex = fill density, lofi = chunk size)
    local dash = 2 + floor(lofi * 6)
    screen.level(12)
    for l = 1, layers do
      local ly = 22 + (l - 1) * dy
      local core = len * 0.38
      local x0 = cx - core / 2 + sin(frame * 0.06 + l * 1.3) * 5
      for u = 0, core, dash do
        if tex > 0.97 or hash(floor(u), l, sd) < 0.2 + tex * 0.8 then
          local x = x0 + u
          if x >= 0 and x <= 127 then screen.rect(x, ly, max(dash - 1, 1), 1) end
        end
      end
    end
    screen.fill()
  elseif cm == 3 then
    -- LOOP: a bright loop segment with echo GHOSTS trailing behind it.
    -- clouds_fb = ghost count + persistence, clouds_pos = loop position,
    -- size = loop length. a read head sweeps the live loop.
    local sN = param_norm("size") or 0
    local pos = pget("clouds_pos", 0.5)
    local fb = pget("clouds_fb", 0)
    local w = 20 + sN * 60
    local cx = pos * 127
    local ngh = floor(fb * 6 + 0.5)
    -- echoes: trailing left + down, fb^i persistence (dim, drawn behind)
    for i = ngh, 1, -1 do
      local lv = floor(3 + fb ^ i * 9 + 0.5)
      if lv >= 1 then
        screen.level(lv)
        screen.rect(cx - i * 11 - w / 2, 30 + i * 1.5, w, 2)
        screen.fill()
      end
    end
    -- the live loop bar
    screen.level(13)
    screen.rect(cx - w / 2, 28, w, 3)
    screen.fill()
    -- boundary caps + a read head sweeping the loop
    screen.level(15)
    screen.rect(cx - w / 2, 25, 1, 9)
    screen.rect(cx + w / 2, 25, 1, 9)
    screen.rect(cx - w / 2 + (frame * 2) % max(w, 1), 24, 1, 11)
    screen.fill()
  else
    -- SPECTRAL: an FFT view — vertical FREQUENCY columns across x. clouds_pos
    -- = spectral centroid, size = width, clouds_tex = roughness, clouds_lofi
    -- = chunkier bins. the columns shimmer (animated); tall/central = bright.
    local sN = param_norm("size") or 0
    local pos = pget("clouds_pos", 0.5)
    local tex = pget("clouds_tex", 0.5)
    local lofi = pget("clouds_lofi", 0)
    local cx = pos * 127
    local width = 12 + sN * 46
    local step = 3 + floor(lofi * 5)
    local bw = max(step - 1, 1)
    local q = 1 + floor(lofi * 4)
    local sd = floor(frame / 2)
    for x = 0, 127, step do
      local d = (x - cx) / width
      local bell = 1 / (1 + d * d)
      local jag = 0.55 + 0.45 * hash(x, 1, 0)
      local shim = 0.6 + 0.4 * sin(frame * 0.3 + x * 0.35)
      local rough = tex > 0 and (1 + (hash(x, 7, sd) * 2 - 1) * tex * 0.6) or 1
      local h = floor(bell * jag * shim * rough * 20 / q) * q
      if h > 20 then h = 20 end
      if h >= 1 then
        screen.level(floor(2 + bell * 10))
        screen.rect(x, 41 - h, bw, h)
        screen.fill()
      end
    end
  end
  -- the Clouds mode top-left (dim; K3 cycles it) and a bank chip top-right
  -- for which granular pair E2/E3 are editing (K2 pages banks)
  if params.lookup["clouds_mode"] then
    ptext(params:string("clouds_mode"), 2, 15, 1, 5)
  end
  chip("BK" .. (C.grain_bank or 1), 108, 13)
end

local function body_STRETCH(frame)
  -- mockup stretch page: inverted mode badge, speed readout, real
  -- playhead, window bar — and the wave drawn in the active algorithm's
  -- own texture: GRAIN samples it as grains, WARP lays a second window
  -- over it, PV rebuilds it as spectral columns. wavelength follows the
  -- rate; the texture drifts with scan (still at 0) and freezes with
  -- pv_freeze. mode OFF frees the voice, so the lane lies flat.
  local m = params.lookup["mode"] and params:string("mode") or "?"
  chip(m, 2, 13)
  local scan = pget("scan", 1)
  local mode = pget("mode", 2)
  local held_pv = pget("pv_freeze", 0) == 1
  if held_pv and mode == 4 then
    ptext_c("HELD", 64, 14, 1, 15)
  end
  local rate = max(abs(scan), 0.05)
  local ph = (mode == 4 and held_pv) and 0 or frame * 0.8 * scan
  if mode == 1 then          -- OFF: dormant lane
    screen.level(1)
    screen.move(0, 30)
    screen.line(128, 30)
    screen.stroke()
  elseif mode == 2 then      -- GRAIN: the wave sampled as grains
    screen.level(6)
    for x = 0, 127, 3 do
      screen.rect(x, stretch_wy(x, ph, rate), 1, 1)
    end
    screen.fill()
  elseif mode == 3 then      -- WARP: an overlapped window ghosts behind
    -- warp_rand shakes the ghost: the engine's window-position jitter is
    -- audible shimmer, so its picture may move (and stands still at 0)
    local off = 9 + sin(frame * 0.9) * 6 * pget("warp_rand", 0)
    screen.level(2)
    for x = 0, 127 do
      screen.rect(x, stretch_wy(x + off, ph, rate), 1, 1)
    end
    screen.fill()
    screen.level(8)
    for x = 0, 127 do
      screen.rect(x, stretch_wy(x, ph, rate), 1, 1)
    end
    screen.fill()
  elseif mode == 4 then      -- PV: spectral columns under the same curve
    screen.level(6)
    for x = 0, 127, 4 do
      local h = abs(sin((x + ph) * 0.35 * rate)) * 11 + 1
      screen.rect(x, 38 - h, 2, h)
    end
    screen.fill()
  else                       -- PLAY: the exact sample, drawn as a solid
    screen.level(9)          -- unbroken wave (no grains/columns = untouched)
    for x = 0, 127 do
      screen.rect(x, stretch_wy(x, ph, rate), 1, 1)
    end
    screen.fill()
  end
  local lo, hi = window_bounds()
  screen.level(2)
  screen.move(0, 39)
  screen.line(128, 39)
  screen.stroke()
  screen.level(6)
  screen.move(lo * 127, 39)
  screen.line(hi * 127, 39)
  screen.stroke()
  -- no playhead while the voice is freed: nothing is playing
  if mode ~= 1 then
    screen.level(15)
    local px = clamp(C.play_phase, 0, 1) * 127
    screen.move(px, 22)
    screen.line(px, 42)
    screen.stroke()
  end
end

local function body_TAPE(frame)
  -- mockup tape page: two reels spinning at the effective rate (reverse
  -- spins backward, stopped stands still), loop track + head below
  local r = pget("tape_rate", 1) * (pget("tape_reverse", 0) == 1 and -1 or 1)
  reel_angle = reel_angle + r * 0.35
  for _, cx in ipairs(REEL_X) do
    screen.level(4)
    screen.circle(cx, 24, 8)
    screen.stroke()
    screen.level(6)          -- hub
    screen.rect(cx - 1, 23, 3, 3)
    screen.fill()
    screen.level(10)         -- three spokes, inner r2.5 -> r6.5
    for k = 0, 2 do
      local a = reel_angle + k * 2.094
      local ca, sa = cos(a), sin(a)
      screen.move(cx + ca * 2.5, 24 + sa * 2.5)
      screen.line(cx + ca * 6.5, 24 + sa * 6.5)
    end
    screen.stroke()
  end
  screen.level(4)           -- straight tape guides between the reels
  screen.move(46, 16)
  screen.line(86, 16)
  screen.move(46, 32)
  screen.line(86, 32)
  screen.stroke()
  local a2, b2 = pget("loop_start", 0), pget("loop_end", 1)
  local lo, hi = min(a2, b2), max(a2, b2)
  screen.level(2)
  screen.move(0, 40)
  screen.line(128, 40)
  screen.stroke()
  screen.level(8)
  screen.move(lo * 127, 40)
  screen.line(hi * 127, 40)
  screen.stroke()
  screen.level(15)
  local tx = clamp(C.tape_phase, 0, 1) * 127
  screen.move(tx, 37)
  screen.line(tx, 43)
  screen.stroke()
  if pget("tape_rec", 0) == 1 and pget("tape_freeze", 0) == 0 then
    if (frame % FPS) < (FPS / 2) then chip("REC", 2, 13) end
  elseif not C.twave_any then
    ptext_c("EMPTY - K2 REC", 64, 26, 1, 3)
  end
end

local function body_FILTER(frame)
  -- the engine's REAL response, not a sketch: RLPF/RHPF/BPF magnitude at
  -- rq = 1 - res*0.92 (floor 0.05 — S5 constants, keep in sync with
  -- Engine_Mangler.sc), on the log-f axis, passband filled, an EQ-node
  -- dot riding the curve at the cutoff. dim rails: 100Hz/1k/10k and 0dB.
  local cut = pget("cutoff", 20000)
  local ft = pget("filt_type", 1)
  local res = pget("resonance", 0)
  screen.level(1)
  for i = 1, 3 do
    screen.move(FILT_GRID_X[i], BAND_T)
    screen.line(FILT_GRID_X[i], BAND_B)
  end
  screen.move(0, FILT_DB0_Y)
  screen.line(128, FILT_DB0_Y)
  screen.stroke()
  local rq = max(1 - res * 0.92, 0.05)
  local rq2 = rq * rq
  local bpg = (1 + res) * (1 + res)
  local px_per_db = (BAND_B - BAND_T) / FILT_DB_RANGE
  for x = 0, 127 do
    local w = FILT_FREQ[x + 1] / cut
    local w2 = w * w
    local d = 1 - w2
    d = d * d + w2 * rq2
    local h2
    if ft == 1 then h2 = 1 / d
    elseif ft == 2 then h2 = (w2 * w2) / d
    else h2 = (w2 * rq2) / d * bpg end
    -- 4.3429*ln = 10*log10: h2 is the squared magnitude
    local y = BAND_T + (FILT_DB_TOP - 4.342944819 * log(h2)) * px_per_db
    if y < BAND_T then y = BAND_T elseif y > BAND_B then y = BAND_B end
    FILT_Y[x + 1] = y
  end
  -- passband filled dim, then the curve bright on top
  screen.level(2)
  for x = 0, 127 do
    local y = FILT_Y[x + 1]
    if y < BAND_B then
      screen.move(x, y)
      screen.line(x, BAND_B)
    end
  end
  screen.stroke()
  -- spectrum ticks under the curve: every 5th column a shimmering bar no
  -- taller than the curve there, reseeded every 4 frames (a lively floor)
  local ssd = floor(frame / 4)
  screen.level(4)
  for x = 0, 127, 5 do
    local under = BAND_B - FILT_Y[x + 1]
    if under > 1 then
      local th = hash(x, 3, ssd) * under
      screen.rect(x, BAND_B - th, 1, th)
    end
  end
  screen.fill()
  -- the response curve bright on top
  screen.level(10)
  for x = 1, 127 do
    screen.move(x - 1, FILT_Y[x])
    screen.line(x, FILT_Y[x + 1])
  end
  screen.stroke()
  -- the cutoff as a grabbable EQ node: E2 moves exactly this dot
  local nx = floor(clamp(log(cut / 20) / log(1000), 0, 1) * 127 + 0.5)
  screen.level(15)
  screen.rect(nx - 1, FILT_Y[nx + 1] - 1, 3, 3)
  screen.fill()
  chip(params.lookup["filt_type"] and params:string("filt_type") or "?", 2, 13)
end

local function body_DELAY(frame)
  -- mockup delay page: the echo as a bouncing ball — impact spacing =
  -- time, shrinking bounces = feedback. the ball is literal: it crosses
  -- one arc per repeat, i.e. delay_time seconds per hop (clamped so the
  -- shortest times still read at 15fps). at mix 0 the page goes dormant:
  -- dim train, no ball — nothing moves that can't be heard.
  local dtime = pget("delay_time", 0.3)
  local tnorm = param_norm("delay_time") or 0.3
  local fb = pget("delay_fb", 0.3)
  local mixv = pget("delay_mix", 0)
  local base = 39
  screen.level(1)
  screen.move(0, base + 1.5)
  screen.line(128, base + 1.5)
  screen.stroke()
  local sp = 12 + tnorm * 24
  local nh = 0
  local h = 20
  while 8 + nh * sp <= 116 and h >= 1.5 do
    nh = nh + 1
    delay_heights[nh] = h
    h = h * max(fb, 0.05)
  end
  screen.level(mixv > 0 and 6 or 2)
  for i = 1, nh do
    local hh = delay_heights[i]
    local xa = 8 + (i - 1) * sp
    local k = 0
    for u = 0, 1, 0.05 do
      if k % 2 == 0 then
        screen.rect(xa + u * sp, base - 4 * hh * u * (1 - u), 1, 1)
      end
      k = k + 1
    end
    screen.rect(xa, base - 2, 1, 2)
  end
  screen.fill()
  if nh > 0 and mixv > 0 then
    delay_hop = (delay_hop + (1 / FPS) / max(dtime, 0.12)) % nh
    local seg = floor(delay_hop) + 1
    local u = delay_hop % 1
    local bx = 8 + (seg - 1) * sp + u * sp
    local by = base - 4 * delay_heights[seg] * u * (1 - u)
    screen.level(15)
    screen.rect(bx - 1, by - 2, 2, 2)
    screen.fill()
  end
end

local function body_REVERB(frame)
  -- reverb page: the DECAY TAIL (impulse response) — the reverb's real
  -- shape. a bright onset spike at t=0 (left), then reflections decaying
  -- over time to the right. the tail LENGTH is the decay (rev_decay/t60);
  -- rev_damp steepens the fade (energy dies faster); rev_size spaces the
  -- reflections; mix sets their density/height. a dim envelope guide traces
  -- the decay curve, and a tick marks where the tail ends. dormant (flat,
  -- dim baseline) at mix 0. K2 pages the JPverb param banks (BK chip).
  local mixv = pget("rev_mix", 0)
  local decN = param_norm("rev_decay") or 0.3
  local damp = pget("rev_damp", 0.3)
  local sizeN = param_norm("rev_size") or 0.3
  local shim = pget("shimmer", 0)
  local live = mixv > 0.01
  local base, maxh, x0 = 38, 21, 8
  local tail = 26 + decN * 92
  local x1 = min(x0 + tail, 125)
  -- time-axis baseline
  screen.level(live and 3 or 1)
  screen.move(2, base) screen.line(126, base) screen.stroke()
  if live then
    -- the onset: a bright full-height spike at t=0
    screen.level(15)
    screen.rect(x0, base - maxh, 1, maxh) screen.fill()
    -- reflections: vertical bars decaying across the tail. damp sets the
    -- decay exponent, size the spacing, mix the height/density.
    local sd = floor(frame / 3)
    local step = 2 + floor(sizeN * 3)
    local expo = 1 + damp * 4
    for x = x0 + step, x1, step do
      local t = (x - x0) / tail
      local env = (1 - t) ^ expo
      local h = env * (0.35 + 0.65 * hash(x, 1, sd)) * maxh * (0.4 + mixv * 0.6)
      if h >= 1 then
        screen.level(floor(2 + env * 11))
        screen.rect(x, base - h, 1, h) screen.fill()
      end
    end
    -- envelope guide: the decay curve the reflections sit under
    screen.level(4)
    for x = x0, x1, 2 do
      screen.rect(x, base - (1 - (x - x0) / tail) ^ expo * maxh, 1, 1)
    end
    screen.fill()
    -- decay-end tick: how long the tail runs
    screen.level(7)
    screen.rect(x1, base - 4, 1, 4) screen.fill()
    -- S15 shimmer: upward-drifting motes over the tail — the octave halo
    -- climbing. density rides shimmer, rise speed rides shimmer_pitch. gated
    -- so a dry-shimmer reverb (shimmer 0) looks exactly as before.
    if shim > 0.01 then
      local spd = 0.4 + (param_norm("shimmer_pitch") or 0.5) * 1.4
      local n = 3 + floor(shim * 15)
      screen.level(7)
      for i = 1, n do
        local mx = x0 + hash(i, 3, 0) * (x1 - x0)
        local ph = (frame * spd + hash(i, 5, 0) * 100) % 22
        screen.rect(mx, base - 2 - ph, 1, 1)
      end
      screen.fill()
    end
  end
  chip("BK" .. (C.rev_bank or 1), 2, 13)
  -- shimmer pitch cue, top-right, whenever shimmer is dialed up
  if shim > 0.01 then ptext_r(fmt_value("shimmer_pitch"), 126, 13, 1, 6) end
end

local function body_PADS(frame)
  -- PADS page: your recording, chopped into 8 playable slices. each pad
  -- plays from its slice of the buffer as a grain cloud (GRN) or a clean
  -- slice (SLC), POLYPHONICALLY and OVER the drone. play them from MIDI
  -- notes / grid pads when "PLAY>PADS" is lit (K1+K3 toggles it here),
  -- or audition the cursor pad with K1+K2. K2 moves the cursor, K3 flips
  -- the cursor pad's type. drawn as the buffer sliced into 8 so it's
  -- obvious what a "pad" is: an eighth of what you recorded.
  for i = 0, 7 do pad_lit[i] = false end
  local used = 0
  for _, padi in pairs(C.pad_held) do pad_lit[padi] = true; used = used + 1 end
  local routed = pget("pad_input", 0) == 1
  -- header: does a note/grid press PLAY a pad, or retune the DRONE? + count
  ptext(routed and "PLAY>PADS" or "PLAY>DRONE", 2, 13, 1, routed and 12 or 3)
  ptext_r(used .. "/" .. floor(pget("voices", 8) + 0.5) .. "V", 126, 13, 1, 4)
  if not C.wave_any and pget("rec", 0) == 0 then
    ptext_c("EMPTY - K2 REC", 64, 28, 1, 6)
  else
    -- TOP: THE TAKE — the window, zoomed to full width and divided into 8.
    -- the pads slice the window (ctx.pad_pos), so the strip has to BE the
    -- window: drawing the whole 60s buffer here would put every divider out
    -- in the silence and shrink a normal take to a few pixels. wave[] is
    -- binned over the whole buffer, so index it through the window.
    local bx0, bx1, by = 4, 124, 23
    local sw = (bx1 - bx0) / 8
    local wlo, _, wspan = window_bounds()
    screen.level(2)
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
    -- the drone's playhead, in window space — it only shows while it's inside
    -- the take (scan/jitter can walk it out; OFF stills it entirely)
    if pget("mode", 5) ~= 1 then
      local ph = (clamp(C.play_phase, 0, 1) - wlo) / wspan
      if ph >= 0 and ph <= 1 then
        screen.level(13)
        screen.rect(bx0 + ph * (bx1 - bx0), by - 5, 1, 10)
        screen.fill()
      end
    end
    -- BOTTOM: 8 pad BUTTONS, one under each slice — pad n plays slice n.
    -- each shows its type (GRN/SLC); lit while its voice sounds; the cursor
    -- (K2) has a bright border and is the pad K1+K2 auditions / K3 retypes.
    for i = 0, 7 do
      local px = bx0 + i * sw
      local cur = i == C.pad_cursor
      local lit = pad_lit[i]
      screen.level(cur and 15 or 4)
      screen.rect(px + 1.5, 30.5, sw - 3, 9)
      screen.stroke()
      if lit then
        screen.level(cur and 15 or 9)
        screen.rect(px + 3, 32, sw - 6, 6)
        screen.fill()
      end
      ptext_c(C.pad_type[i] == 0 and "GRN" or "SLC", px + sw / 2, 33, 1,
        lit and 0 or (cur and 15 or 6))
    end
  end
end

local function body_MOTION(frame)
  -- gesture looper (S16): the recorded param stream drawn as lanes on a loop
  -- timeline. a ruler + sweeping playhead up top, then one row per automated
  -- param (its SHORT name + its events plotted low..high across the loop).
  -- the selected lane (E2) and any lane firing this frame brighten; an idle
  -- loop lies dim, an empty one invites a take. loop length parks top-right
  -- (this page's defining number). fully procedural — no math.random, so the
  -- seeded renders of the other pages stay byte-identical.
  local mo = C.motion
  local ll = mo.loop_len
  local ids = mo.lane_ids
  local nlane = #ids
  local armed = pget("motion_rec", 0) == 1
  local playing = pget("motion_play", 0) == 1

  if ll > 0 then
    ptext_r(string.format("%.1fS", ll / FPS), 126, 13, 1, 4)
  end

  if nlane == 0 then
    -- empty: the house-voice invitation (armed = the first pass is live)
    if armed then
      if (frame % FPS) < (FPS / 2) then chip("REC", 2, 13) end
      ptext_c("MOVE A KNOB TO RECORD", 64, 24, 1, 8)
    else
      ptext_c("EMPTY - K2 ARM", 64, 22, 1, 4)
      ptext_c("THEN MOVE A KNOB", 64, 30, 1, 3)
    end
    return
  end

  -- header: REC pulse while armed, else a LOOP tag
  if armed and (frame % FPS) < (FPS / 2) then chip("REC", 2, 13)
  else ptext("LOOP", 2, 13, 1, 4) end

  -- lane block geometry
  local sel = clamp(floor(pget("motion_lane", 0) + 0.5), 0, nlane)
  local VIS = 4
  local shown = min(nlane, VIS)
  local top, rh = 20, 5
  local tx0, tx1 = 30, 124
  -- drawing length: the loop length once set, else (first pass) the furthest
  -- event captured so far, so a recording-in-progress fills left -> right
  local dl = ll
  if dl == 0 then
    for i = 1, nlane do
      local L = mo.lanes[ids[i]]
      if L.n > 0 and L.f[L.n] > dl then dl = L.f[L.n] end
    end
  end
  if dl < 1 then dl = 1 end

  -- timeline ruler above the lanes
  screen.level(2)
  screen.move(tx0, 16) screen.line(tx1, 16) screen.stroke()

  for row = 1, shown do
    local id = ids[row]
    local L = mo.lanes[id]
    local y = top + (row - 1) * rh
    local selected = row == sel
    local justfired = playing and L.last_fire == mo.playhead
    ptext(SHORT[id] or string.upper(id), 2, y, 1,
      justfired and 15 or (selected and 12 or 5))
    screen.level(1)
    screen.move(tx0, y + 3) screen.line(tx1, y + 3) screen.stroke()
    screen.level(selected and 13 or 7)
    local n = L.n
    for e = 1, n do
      local ex = tx0 + (L.f[e] / dl) * (tx1 - tx0)
      local vn = value_norm(id, L.v[e])
      screen.rect(ex, y + 3 - vn * 3, 1, 1)
    end
    screen.fill()
  end

  local ylo, yhi = top - 1, top + shown * rh - 1
  if ll > 0 then
    -- playback playhead: a line down the lanes + a knob on the ruler
    local phx = tx0 + (mo.playhead / dl) * (tx1 - tx0)
    screen.level(playing and 9 or 3)
    screen.move(phx, ylo) screen.line(phx, yhi) screen.stroke()
    screen.level(playing and 15 or 6)
    screen.rect(phx, 14, 1, 5) screen.fill()
  elseif armed then
    -- first pass: a bright write head at the growing right edge
    screen.level(15)
    screen.move(tx1, ylo) screen.line(tx1, yhi) screen.stroke()
  end
  if nlane > VIS then
    ptext_r("+" .. (nlane - VIS), 126, top + VIS * rh - 4, 1, 4)
  end
end

local function body_SEQ(frame)
  -- step sequencer (S18): a Euclidean on/off pattern that triggers a slice
  -- one-shot per active step. up to 16 steps in two rows of 8; active steps
  -- fill, rests outline, the playhead cell inverts while running. E2 sets the
  -- hit count (regenerates the pattern), K3 picks the slice, K2 runs it.
  -- fully procedural — no math.random, so other pages' seeded renders hold.
  local sq = C.seq
  local len = pget("seq_len", 16)
  local hits = pget("seq_euclid", 0)
  local slice = pget("seq_slice", 0)
  local playing = pget("seq_play", 0) == 1
  local pos = sq.pos
  -- defining number top-right: hits / length. slice + run-state top-left.
  ptext_r(hits .. "/" .. len, 126, 13, 1, 4)
  ptext("SLICE " .. slice, 2, 13, 1, playing and 12 or 5)

  -- active steps: from the Euclidean fill OR manual grid taps
  local active = 0
  for i = 1, len do if sq.pattern[i] then active = active + 1 end end
  if active == 0 then
    ptext_c("TURN E2 - OR TAP GRID", 64, 28, 1, 5)
    return
  end

  -- steps: up to 16 in two rows of 8 (15px pitch, 13x9 cells)
  for i = 1, sq.NUM_STEPS do
    if i <= len then
      local col = (i - 1) % 8
      local row = i <= 8 and 0 or 1
      local x = 4 + col * 15
      local y = 19 + row * 12
      local on = sq.pattern[i]
      if playing and i == pos then
        screen.level(15)                     -- playhead: bright cell
        screen.rect(x, y, 13, 9)
        screen.fill()
        if on then                           -- with an active-step notch
          screen.level(0)
          screen.rect(x + 4, y + 2, 5, 5)
          screen.fill()
        end
      elseif on then
        screen.level(8)                      -- active step: filled
        screen.rect(x, y, 13, 9)
        screen.fill()
      else
        screen.level(3)                      -- rest: outline
        screen.rect(x + 0.5, y + 0.5, 12, 8)
        screen.stroke()
      end
    end
  end
end

local function body_SCENE(frame)
  -- scenes (S19): the 8-slot bank on top, the A->B morph underneath, and the
  -- safety net top-left. an occupied slot fills, the selected one wears a
  -- bright border, a slot queued for a quantized recall blinks until the
  -- clock lands it. the morph bar lies dim when either endpoint is empty —
  -- the audibility rule: nothing to move between, so the picture says so.
  -- fully procedural (no math.random), so the seeded renders of every other
  -- page stay byte-identical.
  local sc = C.scene
  local sel = clamp(floor(pget("scene_slot", 1) + 0.5), 1, 8)
  local a = clamp(floor(pget("scene_morph_a", 1) + 0.5), 1, 8)
  local b = clamp(floor(pget("scene_morph_b", 2) + 0.5), 1, 8)
  local amt = pget("scene_morph_amt", 0)

  -- status row y12..20 (the chip is 9 tall, so it starts at 12 and the plain
  -- text sits at 14 to share its baseline — the row must clear the cells).
  -- top-left: the safety net, armed or not. a fresh mark / a restore flashes
  -- the chip for a beat, so the throw confirms itself.
  if sc.safe then
    local hot = (frame - max(sc.safe_at, sc.restored_at)) < FPS
    if hot then chip("SAFE", 2, 12) else ptext("SAFE", 2, 14, 1, 8) end
  else
    ptext("NO SAFE", 2, 14, 1, 3)
  end
  -- top-right, dim: this page's defining number — WHEN a recall lands
  ptext_r(string.upper(params:string("scene_recall_mode")), 126, 14, 1, 4)

  -- THE MESSAGE LINE. every scene action says what it did here for ~1s, and
  -- it outranks the morph cue below — a fresh action is the more urgent news.
  -- without this the page was a feedback desert: capture moved one 13px box,
  -- recall of the sound you're already making is inaudible by design, and an
  -- empty slot said nothing at all. see mscenes' `say`.
  local msg_live = sc.msg ~= nil and (frame - sc.msg_at) < FPS * 1.2
  if msg_live then
    chip(sc.msg, 64 - floor((text_w(sc.msg, 1) + 5) / 2), 12)
  else
    -- a morph moves the morph-safe subset only: holds, note routing, the buffer
    -- writers and the voice cap stay put (see mscenes MORPH_EXCLUDE). so when a
    -- sweep has ARRIVED at an end and that scene still holds some of those, say
    -- which key finishes the job — otherwise "I swept all the way to B and it
    -- doesn't sound like B" is a mystery instead of a fact. only while the morph
    -- is what's driving (parked at 0 from boot claims nothing).
    local sc_end = amt >= 0.999 and b or (amt <= 0.001 and a or nil)
    if sc_end and sc.engaged and sc.unlanded(sc_end) then
      ptext_c("RCL " .. (amt >= 0.999 and "B" or "A") .. " TO LAND", 64, 14, 1, 5)
    end
  end

  -- the 8 slots, y21..31 (same cell geometry as the SEQ steps). the slot an
  -- action just touched flashes with the message, so the news has a PLACE as
  -- well as words — you see WHICH slot you just saved or recalled.
  local nfilled = 0
  for i = 1, 8 do
    local x = 4 + (i - 1) * 15
    local filled = sc.slots[i] ~= nil
    if filled then nfilled = nfilled + 1 end
    local pending = sc.pending == i and (frame % FPS) < (FPS / 2)
    local flash = msg_live and sc.msg_slot == i
    if filled or pending or flash then
      screen.level((pending or flash) and 15 or 7)
      screen.rect(x, 21, 13, 10)
      screen.fill()
    else
      screen.level(2)
      screen.rect(x + 0.5, 21.5, 12, 9)
      screen.stroke()
    end
    ptext_c(tostring(i), x + 7, 23, 1, (filled or pending or flash) and 0 or 5)
    -- the morph endpoints get a tick, tying them to the A?/B? labels below
    if i == a or i == b then
      screen.level(9)
      screen.rect(x + 5, 32, 3, 1)
      screen.fill()
    end
    if i == sel then
      screen.level(15)
      screen.rect(x - 0.5, 20.5, 14, 11)
      screen.stroke()
    end
  end

  -- the morph: A on the left, B on the right, the handle at the amount
  -- the bottom row teaches the workflow, because a scene bank can't prove
  -- itself in one press: you have to store a sound, make a DIFFERENT one, and
  -- come back. one slot filled is the step everybody stalls on — recalling it
  -- re-applies what you're already playing and nothing happens, which reads as
  -- broken. so say the next move instead of showing a morph bar that can't run.
  local A, B = sc.slots[a], sc.slots[b]
  if nfilled == 0 then
    ptext_c("EMPTY - K3 CAP", 64, 35, 1, 4)
    return
  end
  if nfilled == 1 then
    -- name the next EMPTY slot: "capture a second one" is the move, and being
    -- concrete about where beats being vague. one line — two would crowd the
    -- footer, and 124px is the centered limit (measure with text_w before
    -- adding words; it is easy to sail past it and clip both ends).
    local nxt = 1
    for i = 1, 8 do
      if not sc.slots[i] then nxt = i break end
    end
    ptext_c("CHANGE SOUND - CAP SLOT " .. nxt, 64, 35, 1, 6)
    return
  end
  if not (A and B) then
    ptext_c("MORPH: K1+E2 = A - K1+E3 = B", 64, 35, 1, 3)
    return
  end
  -- the end you're standing on reads bright; parked at either end the handle
  -- dims (nothing is being morphed — the audibility rule, for a gesture)
  local live = amt > 0.001 and amt < 0.999
  ptext("A" .. a, 2, 35, 1, amt < 0.5 and 12 or 5)
  ptext_r("B" .. b, 126, 35, 1, amt >= 0.5 and 12 or 5)
  local x0, x1 = 18, 110
  screen.level(3)
  screen.move(x0, 38)
  screen.line(x1, 38)
  screen.stroke()
  screen.level(live and 15 or 8)
  local hx = x0 + amt * (x1 - x0)
  screen.rect(hx - 1, 35, 3, 7)
  screen.fill()
end

local BODY = {
  MIX = body_MIX, LEVEL = body_LEVEL, REC = body_REC,
  WINDOW = body_WINDOW, GRAIN = body_GRAIN, STRETCH = body_STRETCH,
  TAPE = body_TAPE, FILTER = body_FILTER, DELAY = body_DELAY,
  REVERB = body_REVERB, PADS = body_PADS, MOTION = body_MOTION,
  SEQ = body_SEQ, SCENE = body_SCENE,
}

local function draw_body()
  local f = BODY[PAGES[C.page]]
  if f then f(C.frame) end
end

-- status flag text + single-glyph fallback for each of the 32 combos,
-- built once: the header redraws every frame, only the combo index changes
local STATUS_STR, STATUS_ABBR = {}, {}
do
  local flags = { "REC", "FZ", "TR", "TFZ", "STP" }
  local abbr = { "R", "F", "T", "Z", "S" }
  for m = 0, 31 do
    local t, a = {}, {}
    for b = 1, 5 do
      if m & (1 << (b - 1)) ~= 0 then
        t[#t + 1] = flags[b]
        a[#a + 1] = abbr[b]
      end
    end
    STATUS_STR[m] = table.concat(t, " ")
    STATUS_ABBR[m] = table.concat(a, "")
  end
end

-- header (toy): a small title that never disappears, a blinking status dot
-- + flags beside it (single glyphs if they'd crowd), and one page dot per
-- page top-right (the current page a rounded 4x4 block).
local function draw_header()
  local page = C.page
  local frame = C.frame
  ptext(PAGES[page], 2, 2, 1, 15)
  if C.alt then
    chip("ALT", 2 + text_w(PAGES[page], 1) + 4, 1)
  end
  -- status flags beside the title (only when something is armed/frozen)
  local m = (pget("rec", 0) == 1 and 1 or 0)
    + (pget("freeze", 0) == 1 and 2 or 0)
    + (pget("tape_rec", 0) == 1 and 4 or 0)
    + (pget("tape_freeze", 0) == 1 and 8 or 0)
    + (pget("stop_all", 0) == 1 and 16 or 0)
  if m > 0 and not C.alt then
    local dotx = 2 + text_w(PAGES[page], 1) + 4
    screen.level((frame % FPS) < (FPS / 2) and 12 or 2)
    screen.rect(dotx, 3, 3, 3)
    screen.fill()
    local fx = dotx + 6
    local str = STATUS_STR[m]
    if fx + text_w(str, 1) > 76 then str = STATUS_ABBR[m] end
    ptext(str, fx, 2, 1, 8)
  end
  -- page dots, top-right: pitch fits all pages under x~125 (5px normally,
  -- tightens to 4 once PADS makes it 11); current = rounded 4x4
  local dpitch = #PAGES > 1 and min(5, floor(45 / (#PAGES - 1))) or 5
  for i = 1, #PAGES do
    -- the current dot is a 4px block (others are 2px), so it would sit flush
    -- against its RIGHT neighbour while gapped on its left — nudge every dot
    -- after it right by 2px so the selected one gets matching breathing room
    local dx = 81 + (i - 1) * dpitch + (i > page and 2 or 0)
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
  particles_draw = ctx.particles.draw
  GRAIN_CY, GRAIN_CH = ctx.particles.CY, ctx.particles.CH
end

return M
