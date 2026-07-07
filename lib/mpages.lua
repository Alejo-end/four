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
  pos_start = "STRT", scan = "SCAN", pos_end = "END", pos_jitter = "JIT",
  size = "SIZE", spread = "SPRD", density = "DENS", grain_level = "GRN",
  pitch = "PTCH", warp_window = "WIN", warp_rand = "RAND", kb_octave = "OCT",
  tape_rate = "RATE", tape_pre = "OVR", loop_start = "STRT", loop_end = "END",
  cutoff = "CUT", resonance = "RES", drive = "DRV",
  delay_mix = "MIX", delay_time = "TIME", delay_fb = "FDBK",
  rev_size = "SIZE", rev_mix = "MIX",
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

-- footer value text for a param: compact, ALL-CAPS abbreviations. a few
-- ids get hand-tuned units (cutoff kHz, pitch semitones, rates x, times);
-- a plain 0..1 linear control reads as a percentage; everything else falls
-- back to the norns string.
local RATE_IDS = { scan = true, tape_rate = true }
local function fmt_value(id)
  if not (id and params.lookup[id]) then return "--" end
  if id == "cutoff" then
    local v = params:get(id)
    return v >= 1000 and string.format("%.1fKHZ", v / 1000)
      or string.format("%dHZ", floor(v + 0.5))
  elseif id == "pitch" then
    local st = floor(12 * log(params:get(id)) / log(2) + 0.5)
    return (st >= 0 and "+" or "") .. st .. "ST"
  elseif RATE_IDS[id] then
    return string.format("%+.2fX", params:get(id))
  elseif id == "delay_time" then
    local v = params:get(id)
    return v >= 0.9995 and "1.0S" or string.format("%dMS", floor(v * 1000 + 0.5))
  elseif id == "size" then
    return string.format("%dMS", floor(params:get(id) * 1000 + 0.5))
  elseif id == "density" then
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

-- MIX TAPE-lane preview: a static synthetic waveform (soft envelope +
-- ~45% hash noise) so the tape lane always reads as material, computed once
local TAPE_PREVIEW = {}
for i = 1, 128 do
  local env = 0.35 + 0.45 * abs(sin(i * 0.13)) + 0.2 * abs(sin(i * 0.41))
  TAPE_PREVIEW[i] = env * (0.55 + 0.45 * hash(i, 7, 3))
end

-- GRAIN stereo-field pool: preallocated flat arrays (no per-frame alloc),
-- spawned/aged in draw_grain_field, capped at GR_MAX
local GR_MAX = 110
local gr_x, gr_y0, gr_age, gr_life, gr_len = {}, {}, {}, {}, {}
local gr_n = 0
local gr_last_frame = -1
for i = 1, GR_MAX do
  gr_x[i], gr_y0[i], gr_age[i], gr_life[i], gr_len[i] = 0, 0, 0, 0, 0
end

-- LEVEL meter statics: one slow-decaying peak per bar (IN, OUT), and the
-- quarter-tick fractions (static so the hot path allocates nothing)
local lvl_peak = { 0, 0 }
local lvl_last_frame = -1
local LVL_TICKS = { 0.25, 0.5, 0.75 }

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

local function draw_body()
  local pname = PAGES[C.page]
  local frame = C.frame

  if pname == "MIX" then
    -- mix page (toy): two lanes with the crossfader between them. the ENG
    -- lane is a scatter that thickens as the fade favors the engine (mode
    -- OFF stills it flat); the TAPE lane is a mirrored waveform from a
    -- synthetic preview buffer, its height riding the fade toward tape.
    local mixv = pget("mix", 0.5)
    local eng_off = pget("mode", 2) == 1
    local sd = floor(frame / 2)
    ptext("ENG", 2, 13, 1, 4)
    if eng_off then
      screen.level(1)
      screen.move(26, 18.5) screen.line(122, 18.5)
      screen.stroke()
    else
      screen.level(12)
      local dens = 0.1 + (1 - mixv) * 0.4
      local spread = 1 + (1 - mixv) * 5
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
    -- TAPE lane: mirrored synthetic waveform, height rides the fade
    ptext("TAPE", 2, 30, 1, 4)
    screen.level(1)
    screen.move(26, 33) screen.line(122, 33)
    screen.stroke()
    local g = 0.3 + 0.7 * mixv
    screen.level(10)
    for x = 26, 122 do
      local a = TAPE_PREVIEW[floor((x - 26) / 96 * 127) + 1]
      local h = clamp(a * g * 4, 0.5, 4)
      screen.move(x, 33 - h) screen.line(x, 33 + h)
    end
    screen.stroke()
  elseif pname == "LEVEL" then
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
  elseif pname == "REC" then
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
    -- resample re-records the OUTPUT: badge it while engaged
    if pget("resample", 0) > 0 then chip("RSMP", 2, 13) end
  elseif pname == "WINDOW" then
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
  elseif pname == "GRAIN" then
    -- grain page (toy): a thin source ruler up top; the hero is a stereo
    -- grain field. grains spawn at the playhead (scattered by jitter),
    -- their ticks STRETCH with size, FILL with density, and DRIFT
    -- vertically with pitch. centerline y30, lanes +/-10.
    local lo, hi = window_bounds()
    local playing = C.wave_any and pget("mode", 2) ~= 1
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
    -- update the grain pool once per frame: age + compact, then spawn
    if C.frame ~= gr_last_frame then
      gr_last_frame = C.frame
      local w = 0
      for i = 1, gr_n do
        gr_age[i] = gr_age[i] + 1
        if gr_age[i] < gr_life[i] then
          w = w + 1
          if w ~= i then
            gr_x[w], gr_y0[w], gr_age[w], gr_life[w], gr_len[w] =
              gr_x[i], gr_y0[i], gr_age[i], gr_life[i], gr_len[i]
          end
        end
      end
      gr_n = w
      if playing then
        local dN = param_norm("density") or 0
        local sN = param_norm("size") or 0
        local jit = pget("pos_jitter", 0)
        local _, _, span = window_bounds()
        local spr = pget("spread", 0.5)
        local px = clamp(C.play_phase, 0, 1)
        local p = 0.06 + dN * 0.62
        for _ = 1, (dN > 0.7 and 2 or 1) do
          if math.random() < p and gr_n < GR_MAX then
            gr_n = gr_n + 1
            gr_x[gr_n] = clamp(px + (math.random() * 2 - 1) * jit * span, 0, 1) * 127
            gr_y0[gr_n] = 30 + (math.random() * 2 - 1) * spr * 10
            gr_age[gr_n] = 0
            gr_life[gr_n] = 12 + sN * 26
            gr_len[gr_n] = 1 + sN * 9
          end
        end
      end
    end
    -- centerline
    screen.level(1)
    screen.move(0, 30) screen.line(128, 30)
    screen.stroke()
    -- draw the grains: pitch tilts the vertical drift over each grain's age
    local drift = log(pget("pitch", 1)) / log(2) * 0.35 * 0.5
    for i = 1, gr_n do
      local lv = floor(12 - gr_age[i] / gr_life[i] * 11 + 0.5)
      if lv >= 1 then
        local y = gr_y0[i] + drift * gr_age[i]
        if y < 20 then y = 20 elseif y > 40 then y = 40 end
        screen.level(lv)
        screen.rect(gr_x[i] - gr_len[i] / 2, y, gr_len[i], 1)
        screen.fill()
      end
    end
  elseif pname == "STRETCH" then
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
    else                       -- PV: spectral columns under the same curve
      screen.level(6)
      for x = 0, 127, 4 do
        local h = abs(sin((x + ph) * 0.35 * rate)) * 11 + 1
        screen.rect(x, 38 - h, 2, h)
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
  elseif pname == "TAPE" then
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
  elseif pname == "FILTER" then
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
  elseif pname == "DELAY" then
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
  elseif pname == "REVERB" then
    -- reverb page (toy): a room seen from above — the walls grow with
    -- size, the source (bright dot, left) sends rays bouncing to a
    -- listener ring (right), and the air fills with diffuse dither as mix
    -- rises. a ping ring pulses out of the source on a slow cycle. at mix
    -- 0 the page goes dormant: dim room, still air, no ping.
    local size = pget("rev_size", 0.5)
    local mixv = pget("rev_mix", 0)
    local w = 44 + size * 60
    local hh = 14 + size * 12
    local x0, x1 = 64 - w / 2, 64 + w / 2
    local y0, y1 = 26 - hh / 2, 26 + hh / 2
    screen.level(mixv > 0 and 8 or 2)
    screen.rect(x0 + 0.5, y0 + 0.5, w, hh)
    screen.stroke()
    local sx, sy = x0 + 7, 26
    screen.level(mixv > 0 and 15 or 4)
    screen.rect(sx - 1, sy - 1, 2, 2)
    screen.fill()
    screen.level(mixv > 0 and 8 or 2)
    screen.circle(x1 - 7, 26, 2)
    screen.stroke()
    if mixv > 0 then
      -- diffuse air, density rides mix
      screen.level(2)
      local sd = floor(frame * 0.2)
      for gx = x0 + 3, x1 - 3, 5 do
        for gy = y0 + 3, y1 - 3, 4 do
          if hash(gx, gy, sd) < mixv * 0.45 then screen.rect(gx, gy, 1, 1) end
        end
      end
      screen.fill()
      -- three rays bouncing off the walls, longer in a bigger room
      screen.level(6)
      local steps = floor(34 + size * 44)
      for k = 0, 2 do
        local a = k * 2.1 + frame * 0.03
        local px2, py = sx, sy
        local dx, dy = cos(a), sin(a)
        for i = 0, steps do
          px2 = px2 + dx
          py = py + dy
          if px2 <= x0 + 1 or px2 >= x1 - 1 then dx = -dx end
          if py <= y0 + 1 or py >= y1 - 1 then dy = -dy end
          if i % 3 == 0 then screen.rect(px2, py, 1, 1) end
        end
      end
      screen.fill()
      -- the ping: an expanding ring from the source, slow cycle
      local pmax = hh / 2 - 3
      if pmax > 2 then
        local pph = (frame % 56) / 56
        local plv = floor(9 - pph * 7 + 0.5)
        if plv >= 2 then
          screen.level(plv)
          screen.circle(sx, sy, 2 + pph * (pmax - 2))
          screen.stroke()
        end
      end
    end
  end
end

-- status flag text + single-glyph fallback for each of the 16 combos,
-- built once: the header redraws every frame, only the combo index changes
local STATUS_STR, STATUS_ABBR = {}, {}
do
  local flags = { "REC", "FZ", "TR", "TFZ" }
  local abbr = { "R", "F", "T", "Z" }
  for m = 0, 15 do
    local t, a = {}, {}
    for b = 1, 4 do
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
  -- page dots, top-right: first x=81, 5px pitch; current = rounded 4x4
  for i = 1, #PAGES do
    local dx = 81 + (i - 1) * 5
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
