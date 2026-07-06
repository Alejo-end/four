-- mpages: the screen — wave/twave display models, every page body, header,
-- footer, and the redraw composition. (the bitmap mockups are the bible:
-- same font, same geometry.)
--
-- layout: header y0..10  (title 2x pixel font, ALT chip, page dots, status)
--         body   y12..41 (per-page visualization)
--         footer y44..63 (labels row, then the hardware row mirroring the
--                         panel: E2 hexagon . K2 pill . K3 pill . E3 hexagon)
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
  size = "SIZE", spread = "SPRD", density = "DENS", grain_level = "LVL",
  pitch = "PTCH", warp_window = "WIN", warp_rand = "RAND", kb_octave = "OCT",
  tape_rate = "RATE", tape_pre = "OVR", loop_start = "STRT", loop_end = "END",
  cutoff = "CUT", resonance = "RES",
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

-- hexagon dial: dim outline, bright pointer sweeping 135..405 degrees.
-- the outline is a constant ring — its trig lives in a table, not the frame
local HEX_DX, HEX_DY = {}, {}
for i = 0, 6 do
  local a = -math.pi / 2 + i * math.pi / 3
  HEX_DX[i], HEX_DY[i] = math.cos(a), math.sin(a)
end

local function draw_hex_dial(cx, cy, r, val)
  screen.level(4)
  for i = 0, 6 do
    local x, y = cx + HEX_DX[i] * r, cy + HEX_DY[i] * r
    if i == 0 then screen.move(x, y) else screen.line(x, y) end
  end
  screen.stroke()
  if val then
    local a = math.pi * 0.75 + clamp(val, 0, 1) * math.pi * 1.5
    screen.level(15)
    screen.move(cx, cy)
    screen.line(cx + cos(a) * (r - 2), cy + sin(a) * (r - 2))
    screen.stroke()
  end
end

-- key pill, mockup geometry: y=51, h=11, inverted while lit
local function draw_pill(cx, label, on, dim)
  local w = text_w(label, 1) + 7
  local x = floor(cx - w / 2)
  if on then
    screen.level(15)
    screen.rect(x, 51, w, 11)
    screen.fill()
    ptext_c(label, cx, 54, 1, 0)
  else
    screen.level(dim and 1 or 4)
    screen.rect(x + 0.5, 51.5, w, 11)
    screen.stroke()
    ptext_c(label, cx, 54, 1, dim and 2 or 10)
  end
end

-- transient value readout, top-right of the body (mockup "1.25X" spot).
-- pages can park a persistent dim readout there too; the flash wins.
local flash_on = false

local function topright(str, lvl)
  if flash_on then return end
  ptext_r(string.upper(str), 126, 13, 1, lvl or 4)
end

-- footer: labels row at y44, then hexagon . pill . pill . hexagon at the
-- exact mockup positions (dials 20/108, pills 51/81)
local function draw_footer()
  local id2, id3 = C.enc_param(2), C.enc_param(3)
  ptext_c(SHORT[id2] or "--", 20, 44, 1, 4)
  ptext_c("K2", 51, 44, 1, 4)
  ptext_c("K3", 81, 44, 1, 4)
  ptext_c(SHORT[id3] or "--", 108, 44, 1, 4)
  draw_hex_dial(20, 56, 7, param_norm(id2))
  draw_hex_dial(108, 56, 7, param_norm(id3))
  local held = C.held
  for n = 2, 3 do
    local def = C.key_def(n)
    local cx = (n == 2) and 51 or 81
    if def then
      local on = (def.lit ~= nil and pget(def.lit, 0) == 1) or held[n] == true
      draw_pill(cx, def.label, on, false)
    else
      draw_pill(cx, "--", false, true)
    end
  end
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

-- STRETCH lane curve, shared by the mode textures (a closure built inside
-- the frame would be gc churn at 15fps)
local function stretch_wy(x, ph, rate)
  return 30 + sin((x + ph) * 0.35 * rate) * 6
end

local function draw_body()
  local pname = PAGES[C.page]
  local frame = C.frame

  if pname == "MIX" then
    -- two lanes like the mockup: engine as grains, tape as its real
    -- waveform, crossfader between them. lane energy follows the mix.
    -- mode OFF silences the engine, so its lane lies flat — nothing
    -- moves that can't be heard.
    local mixv = pget("mix", 0.5)
    local sd = floor(frame / 2)
    ptext("ENG", 2, 13, 1, 4)
    if pget("mode", 2) == 1 then
      screen.level(1)
      screen.move(26, 17)
      screen.line(122, 17)
      screen.stroke()
    else
      screen.level(12)
      for x = 26, 122 do
        if hash(x, 1, sd) < 0.1 + (1 - mixv) * 0.4 then
          local dy = (hash(x, 7, sd) - 0.5) * 2 * (1 + (1 - mixv) * 5)
          screen.rect(x, 16 + dy, 1, 1)
        end
      end
      screen.fill()
    end
    screen.level(2)
    screen.move(26, 24)
    screen.line(122, 24)
    screen.stroke()
    screen.level(15)
    screen.rect(25 + mixv * 96, 21, 3, 7)
    screen.fill()
    ptext("TAPE", 2, 30, 1, 4)
    screen.level(1)
    screen.move(26, 33)
    screen.line(122, 33)
    screen.stroke()
    -- lane columns share one brightness: a single stroke rasters the same
    local g = 0.3 + 0.7 * mixv
    screen.level(12)
    for x = 26, 122 do
      local a = twave[floor((x - 26) / 96 * 127) + 1]
      if a > 0.002 then
        local h = clamp(sqrt(min(a * 2, 1)) * 5 * g, 1, 5)
        screen.move(x, 33 - h)
        screen.line(x, 33 + h)
      end
    end
    screen.stroke()
  elseif pname == "LEVEL" then
    -- mockup levels page: faders with live VU columns beside them. the
    -- faders track the alt layer, so they always show what E2/E3 grab:
    -- IN/OUT normally, MON/HP while K1 is held
    local defs = C.alt and LEVEL_DEFS_ALT or LEVEL_DEFS
    for i = 1, 2 do
      local d = defs[i]
      local fx, label, pos = d[1], d[2], param_norm(d[3]) or 0
      local amp = i == 1 and max(amp_in[1], amp_in[2])
        or max(amp_out[1], amp_out[2])
      ptext_c(label, fx + 4, 12, 1, 4)
      screen.level(4)
      screen.move(fx, 19)
      screen.line(fx, 40)
      screen.move(fx - 2, 19)
      screen.line(fx + 2, 19)
      screen.move(fx - 2, 40)
      screen.line(fx + 2, 40)
      screen.stroke()
      local hy = 40 - floor(pos * 21)
      screen.level(15)
      screen.rect(fx - 4, hy - 1, 9, 3)
      screen.fill()
      local vu = floor(clamp(sqrt(amp), 0, 1) * 21)
      if vu > 0 then
        screen.level(12)
        screen.rect(fx + 9, 40 - vu, 3, vu)
        screen.fill()
      end
    end
  elseif pname == "REC" then
    draw_strip(false)
    particles_draw()
    -- an empty buffer is an invitation, in the same voice as the TAPE page
    if not C.wave_any and pget("rec", 0) == 0 then
      ptext_c("EMPTY - K2 REC", 64, 26, 1, 3)
    end
    -- input meter rides the right edge so you can see what's being captured
    local h = floor(clamp(sqrt(max(amp_in[1], amp_in[2])) * (BAND_B - BAND_T), 0, BAND_B - BAND_T))
    screen.level(15)
    if h > 0 then
      screen.rect(125, BAND_B - h, 3, h)
      screen.fill()
    end
    -- overdub level parks top-right while it shapes the take (knockout
    -- pocket over the strip, same treatment as GRAIN's pitch readout)
    local ovr = pget("pre_level", 0)
    if ovr > 0 then
      screen.level(0)
      screen.rect(84, 11, 44, 9)
      screen.fill()
      topright(string.format("OVR %d%%", floor(ovr * 100 + 0.5)))
    end
  elseif pname == "WINDOW" then
    draw_strip(true)
    local scan = pget("scan", 1)
    topright((scan < 0 and "<< " or ">> ") .. string.format("%.2fX", abs(scan)))
  elseif pname == "GRAIN" then
    -- mockup grain page: thin sample strip up top with window brackets,
    -- grain cloud (the real particles) below, playhead tick between.
    -- the cloud is a stereo-field plot: y is per-grain pan (L up, R down),
    -- so height IS spread, off-rail drift IS pan, dot size IS grain size
    screen.level(1)
    screen.move(0, 16)
    screen.line(128, 16)
    screen.stroke()
    -- strip columns and both window brackets each share one brightness:
    -- batched strokes raster identically
    screen.level(6)
    for x = 0, 127 do
      local a = wave[x + 1]
      if a > 0.002 then
        local h = clamp(sqrt(min(a * 2, 1)) * 4, 1, 4)
        screen.move(x, 16 - h)
        screen.line(x, 16 + h)
      end
    end
    screen.stroke()
    local lo, hi = window_bounds()
    screen.level(15)
    for k = 1, 2 do
      local ex = (k == 1 and lo or hi) * 127
      screen.move(ex, 11)
      screen.line(ex, 21)
      screen.move(ex - 2, 11)
      screen.line(ex + 2, 11)
      screen.move(ex - 2, 21)
      screen.line(ex + 2, 21)
    end
    screen.stroke()
    -- stereo axis under the cloud: dim mono rail + L/R poles. spread 0
    -- lays every grain on the rail; silence leaves only the flat line
    screen.level(1)
    screen.move(0, GRAIN_CY)
    screen.line(128, GRAIN_CY)
    screen.stroke()
    ptext("L", 1, GRAIN_CY - GRAIN_CH - 1, 1, 1)
    ptext("R", 1, GRAIN_CY + GRAIN_CH - 4, 1, 1)
    -- playhead: bright tick under the strip, dim needle through the cloud
    -- (the scatter's center once jitter detaches grains from it). no
    -- needle while the voice is freed or the buffer is empty: nothing
    -- is playing (matches the STRETCH page rule)
    if C.wave_any and pget("mode", 2) ~= 1 then
      local px = clamp(C.play_phase, 0, 1) * 127
      screen.level(15)
      screen.move(px, 22)
      screen.line(px, 25)
      screen.stroke()
      screen.level(2)
      screen.move(px, 26)
      screen.line(px, GRAIN_CY + GRAIN_CH)
      screen.stroke()
    end
    particles_draw()
    -- pitch parks top-right, in a quiet corner knocked out of the strip:
    -- it's the one grain value you play from anywhere (MIDI, typing
    -- keyboard, grid) without seeing this page
    local pv = pget("pitch", 1)
    screen.level(0)
    screen.rect(84, 11, 44, 9)
    screen.fill()
    if pget("pitch_quant", 0) == 1 then
      topright(string.format("PT %+d ST", util.round(12 * log(pv, 2))))
    else
      topright(string.format("PT %.2fX", pv))
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
    topright(string.format("%+.2fX", scan))
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
      screen.level(10)
      for k = 0, 2 do
        local a = reel_angle + k * 2.094
        screen.move(cx, 24)
        screen.line(cx + cos(a) * 6, 24 + sin(a) * 6)
      end
      screen.stroke()
    end
    screen.level(4)
    screen.move(46, 15)
    screen.line(86, 15)
    screen.move(46, 33)
    screen.line(86, 33)
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
    topright(string.format("%+.2fX", r))
    if pget("tape_rec", 0) == 1 and pget("tape_freeze", 0) == 0 then
      if (frame % FPS) < (FPS / 2) then chip("REC", 2, 13) end
    elseif not C.twave_any then
      ptext_c("EMPTY - K2 REC", 64, 26, 1, 3)
    end
  elseif pname == "FILTER" then
    -- stylized response curve: cutoff on a log axis, resonance bump.
    -- the cutoff parks top-right — every page keeps its one number there
    local cut = pget("cutoff", 20000)
    topright(cut >= 1000 and string.format("%.1fKHZ", cut / 1000)
      or string.format("%dHZ", floor(cut + 0.5)))
    local ft = pget("filt_type", 1)
    local res = pget("resonance", 0)
    local cx = clamp((log(cut / 20) / log(1000)) * 127, 0, 127)
    local mid = 26
    screen.level(8)
    if ft == 1 then       -- LP
      screen.move(0, mid)
      screen.line(max(cx - 10, 0), mid)
      screen.line(cx, mid - res * 10)
      screen.line(min(cx + 14, 127), BAND_B)
    elseif ft == 2 then   -- HP
      screen.move(127, mid)
      screen.line(min(cx + 10, 127), mid)
      screen.line(cx, mid - res * 10)
      screen.line(max(cx - 14, 0), BAND_B)
    else                  -- BP
      screen.move(max(cx - 26, 0), BAND_B)
      screen.line(cx, mid - 6 - res * 6)
      screen.line(min(cx + 26, 127), BAND_B)
    end
    screen.stroke()
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
    topright(string.format("MIX %d%%", floor(mixv * 100 + 0.5)),
      mixv > 0 and 10 or 3)
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
    -- mockup reverb page: a room seen from above — size grows the walls,
    -- rays are the reflections bouncing off them. at mix 0 the page goes
    -- dormant: dim room, still air — nothing moves that can't be heard.
    local size = pget("rev_size", 0.5)
    local mixv = pget("rev_mix", 0)
    topright(string.format("MIX %d%%", floor(mixv * 100 + 0.5)),
      mixv > 0 and 10 or 3)
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
    if mixv > 0 then
      screen.level(6)
      for k = 0, 1 do
        local a = k * 2.4 + frame * 0.03
        local px2, py = sx, sy
        local dx, dy = cos(a), sin(a)
        for i = 0, 70 do
          px2 = px2 + dx
          py = py + dy
          if px2 <= x0 + 1 or px2 >= x1 - 1 then dx = -dx end
          if py <= y0 + 1 or py >= y1 - 1 then dy = -dy end
          if i % 3 == 0 then screen.rect(px2, py, 1, 1) end
        end
      end
      screen.fill()
    end
  end
end

-- page-dot x positions, top-right, computed once (in init, from the page
-- list): dots cluster by signal family — source (MIX LEVEL REC) · shape
-- (WINDOW GRAIN STRETCH) · TAPE · fx (FILTER DELAY REVERB) — so position
-- in the row tells you which part of the instrument you're in.
local DOT_X = {}

-- the status line for each of the 16 flag combos, built once: the header
-- redraws every frame, and only the combo index changes
local STATUS_STR = {}
do
  local flags = { "REC", "FZ", "TR", "TFZ" }
  for m = 0, 15 do
    local t = {}
    for b = 1, 4 do
      if m & (1 << (b - 1)) ~= 0 then t[#t + 1] = flags[b] end
    end
    STATUS_STR[m] = table.concat(t, " ")
  end
end

local function draw_header()
  local page = C.page
  local frame = C.frame

  -- title in the 2x pixel font, ALT chip beside it
  local w = ptext(PAGES[page], 2, 1, 2, 15)
  if C.alt then chip("ALT", 2 + w + 5, 1) end

  -- page dots, top-right: current page is a 3x3 block, the rest are 1px
  for i = 1, #PAGES do
    if i == page then
      screen.level(15)
      screen.rect(DOT_X[i] - 1, 1, 3, 3)
    else
      screen.level(2)
      screen.rect(DOT_X[i], 2, 1, 1)
    end
    screen.fill()
  end

  -- status flags blink under the dots: an armed recorder is impossible
  -- to miss from any page
  local m = (pget("rec", 0) == 1 and 1 or 0)
    + (pget("freeze", 0) == 1 and 2 or 0)
    + (pget("tape_rec", 0) == 1 and 4 or 0)
    + (pget("tape_freeze", 0) == 1 and 8 or 0)
  if m > 0 then
    ptext_r(STATUS_STR[m], 126, 6, 1,
      (frame % FPS) < (FPS / 2) and 15 or 4)
  end
end

function M.redraw()
  screen.clear()

  -- the transient value readout claims the top-right corner while active;
  -- page readouts (topright) yield to it
  local flash_id = C.flash_id
  flash_on = flash_id ~= nil and C.frame < C.flash_until
    and params.lookup[flash_id] ~= nil

  draw_header()
  draw_body()
  draw_footer()

  if flash_on then
    ptext_r((SHORT[flash_id] or "") .. " " ..
      string.upper(params:string(flash_id)), 126, 13, 1, 15)
  end

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
  local GAP_AFTER = { [3] = true, [6] = true, [7] = true }
  local x = 126
  for i = #PAGES, 1, -1 do
    DOT_X[i] = x
    x = x - 4
    if i > 1 and GAP_AFTER[i - 1] then x = x - 2 end
  end
end

return M
