-- mpages: the screen — the wave/twave display models, every page body, the
-- header, the footer, and the redraw composition.
--   header y0..8   the page title (1x), the purity mark, the write/hold flags,
--                  the page dots top-right
--   body   y11..53 one dominant object per page, drawn from real state
--   footer y56..63 four quiet words: K2 K3 | E2 E3. a turning knob brightens
--                  its word and swells its value in a framed 2x box just above
--                  the footer, bottom right, for ~1.2s
-- The strips are painted from files through lib/mwav.lua (lua cannot read an
-- SC or softcut buffer); this module owns the strips, mwav reads the files.

local floor, sin, cos = math.floor, math.sin, math.cos
local abs, sqrt, min, max = math.abs, math.sqrt, math.min, math.max
local log, exp, PI = math.log, math.exp, math.pi

local C     -- shared ctx, bound at init
local W     -- lib/mwav (the file reader), handed in through ctx.wav
local pget, clamp, window_bounds, FPS, PAGES
local ptext, ptext_c, ptext_r, chip, text_w
local amp_in, amp_out

-- waveform display: 128 amplitude bins over the buffer, filled as the write
-- head passes; pre_level decides how much of the old picture survives overdub
-- (four) one strip per track, its own material; `wave` is the focused
-- track's, swapped by M.focus_wave
local waves = {}
for n = 1, 4 do
  waves[n] = {}
  for i = 1, 128 do waves[n][i] = 0 end
end
local wave = waves[1]
local wave_bin = 0

-- same idea for the tape loop: bins indexed by the tape head while recording
-- A loop deck (the tape) keeps a FINER picture than the
-- take: 1024 bins over their 60s, 59ms each. A deck page zooms onto the loop,
-- and a 4s loop was 8 bins of the old 128: it never looked recorded.
local DECK_BINS = 1024
local twave = {}
for i = 1, DECK_BINS do twave[i] = 0 end
local twave_bin = 0

-- paint amplitude into display bins between the last-seen head position and
-- the current one, walking the SHORTER way around the (circular) buffer —
-- so bins skipped between frames at high rates get filled, wrap-around is
-- seamless, and reverse playback paints in the right direction. entering a
-- fresh bin, previous content survives by `pre` (the overdub picture).
-- A JUMP is not a walk: no head travels more than a bin per frame (the
-- fastest, a deck at 4x, moves about 0.6), so a gap of several bins is a
-- loop wrapping round or a pass re-armed somewhere else. Walking it painted
-- the whole loop with one moment's level (every seam of a DUB loop drew a
-- solid block). Only the landing bin is painted.
-- JUMP_BINS is for a strip of 128 bins; a finer strip scales it, so a jump
-- is the same stretch of time on every strip.
local JUMP_BINS = 3
local function paint_bins(bins, last, bin, amp, pre)
  if last == 0 or last == bin then
    bins[bin] = max(bins[bin], amp)
    return bin
  end
  local n = #bins
  local jump = JUMP_BINS * n / 128
  local fwd = (bin - last) % n
  local bwd = (last - bin) % n
  if fwd > jump and bwd > jump then
    bins[bin] = max(bins[bin] * pre, amp)
    return bin
  end
  local step = (fwd <= bwd) and 1 or -1
  local b = last
  repeat
    b = ((b - 1 + step) % n) + 1
    bins[b] = max(bins[b] * pre, amp)
  until b == bin
  return bin
end
local M = {}
M.paint_bins = paint_bins   -- a deck paints its own picture (lib/mdeck.lua)
M.DECK_BINS = DECK_BINS

-- track the buffer's contents as the write head passes over it. STOP holds
-- the record head (an arm under STOP waits for START), so it holds the
-- picture too: painting the live input over a head that writes nothing set
-- wave_any over an empty buffer, and the next PSET save wrote 60s of silence.
function M.update_wave()
  if pget("rec", 0) == 1 and pget("freeze", 0) == 0
      and pget("stop_all", 0) == 0 then
    local bin = floor(clamp(C.rec_phase, 0, 0.999) * 128) + 1
    if C.rec_amp > 0.01 then C.wave_any = true end
    wave_bin = paint_bins(wave, wave_bin, bin, C.rec_amp, pget("pre_level", 0))
  end
end

-- track the tape loop's contents as the head records (input amplitude,
-- since softcut exposes no per-voice output meter); tape_pre sets survival
function M.update_tape_wave()
  if pget("tape_rec", 0) == 1 and pget("tape_freeze", 0) == 0
      and pget("stop_all", 0) == 0 then
    local bin = floor(clamp(C.tape_phase, 0, 0.999) * DECK_BINS) + 1
    -- meter what softcut actually records (C.cut_rec_amp — the ADC tap, the
    -- engine output, or the blend): a WET print otherwise painted nothing
    -- and left twave_any false over audible tape
    local a = C.cut_rec_amp()
    if a > 0.01 then C.twave_any = true end
    twave_bin = paint_bins(twave, twave_bin, bin, a, pget("tape_pre", 0))
  end
end

-- wipe ANY strip, cancelling its own queued repaint
function M.clear_bins(bins)
  W.cancel_fill(bins)
  for i = 1, #bins do bins[i] = 0 end
end

-- wipe the tape picture (the CLR gesture starts the loop over)
function M.clear_twave()
  M.clear_bins(twave)
  twave_bin = 0
  C.twave_any = false
end

-- wipe the engine's picture (the engine `clear` command): the buffer is gone, so the strip
-- must go with it — every page that draws the take goes back to inviting one.
-- the focus moved to track n: its strip becomes the one TAKE draws and the
-- record head paints
function M.focus_wave(n)
  wave = waves[n] or waves[1]
  wave_bin = 0
end
-- track n's strip, for a restore that lands while another track is focused
function M.track_wave(n) return waves[n] end

function M.clear_wave()
  M.clear_bins(wave)  -- stops an in-flight TAKE fill first
  wave_bin = 0
  C.wave_any = false
end

-- the TAKE's preview: clear the strip FIRST, so an unsupported-format /
-- unreadable early return leaves a flat strip instead of the previous take's
-- waveform; a 24-bit drop-in draws + windows correctly via the shared decoder
-- (the bug this once had for everything except 16-bit).
function M.load_wave(path, buf_secs)
  for i = 1, 128 do wave[i] = 0 end
  wave_bin = 0
  local dur = W.queue_fill(path, wave, buf_secs)
  if dur ~= nil then C.wave_any = dur > 0 end
  return dur
end

-- fill an ARBITRARY strip from a wav: a track's strip or the tape's, when a
-- pset restores its audio (lua cannot read the
-- softcut buffer, but the wav it was restored FROM is right there; without
-- this a restored loop played audibly under a blank picture).
function M.fill_wave_bins(path, bins, secs)
  -- a strip that is still empty becomes a 128-bin one
  for i = 1, (#bins > 0 and #bins or 128) do bins[i] = 0 end
  return W.queue_fill(path, bins, secs)
end

-- repaint the TAKE's strip from a dump of the buffer, leaving the window and
-- wave_any alone: the material is the same take, changed in place by regen
-- or erosion
function M.repaint_wave(path)
  wave_bin = 0
  return M.fill_wave_bins(path, wave, C.BUF_SECS)
end

-- the tape strip's version of the same (mpages owns twave)
function M.repaint_twave(path, secs)
  twave_bin = 0
  return M.fill_wave_bins(path, twave, secs)
end

-- deterministic dither, same trick as the mockups
local function hash(x, y, sd)
  local f = sin(x * 12.9898 + y * 78.233 + sd * 37.719) * 43758.5453
  return f - floor(f)
end

-- a waveform LANE: the 128 bins of `bins` stretched across columns x0..x1 as
-- vertical strokes around the centre row ym. The height law is the one every
-- strip shares: sqrt so quiet material still reads, times `k`, clamped to
-- [hmin, hmax]. `lo`/`span` (default the whole strip) zoom it onto a part of
-- the bins, which is how PADS draws only the window. The caller sets the level.
local function wave_lane(bins, x0, x1, ym, k, hmin, hmax, lo, span)
  lo, span = lo or 0, span or 1
  local n = #bins
  local w = x1 - x0
  local per = span * (n - 1) / w        -- bins for each column
  for x = x0, x1 do
    local i0 = floor((lo + (x - x0) / w * span) * (n - 1)) + 1
    local a = bins[i0] or 0
    -- a column that covers several bins shows the loudest of them, or a
    -- short hit between two columns would not draw
    if per > 1 then
      for i = i0 + 1, min(n, floor(i0 + per)) do
        local b = bins[i]
        if b > a then a = b end
      end
    end
    if a > 0.002 then
      local h = clamp(sqrt(min(a * 2, 1)) * k, hmin, hmax)
      screen.move(x, ym - h)
      screen.line(x, ym + h)
    end
  end
  screen.stroke()
end

-- WHAT A DECK STRIP SHOWS. A deck is 60s long and a loop is a few seconds of
-- it, so a strip of the whole deck drew a loop as a sliver. The strip shows:
--   the LOOP, when one is set (its two ends are the strip's two ends);
--   else the MATERIAL (a first pass that is still open: from where it began,
--   8s at least, so the pass fills the strip from the left as it records);
--   else the whole deck.
-- Returns lo and span (0..1 of the deck).
local function deck_view(ls, le, mat_lo, mat_hi, len)
  local lo, hi = min(ls, le), max(ls, le)
  if hi - lo < 0.999 then return lo, max(hi - lo, 0.0001) end
  if mat_lo and mat_hi then
    local span = max(mat_hi - mat_lo, 8 / len)
    if mat_lo + span > 1 then span = 1 - mat_lo end
    return mat_lo, max(span, 0.0001)
  end
  return 0, 1
end

-- where the strip sits in the whole deck: a rail one pixel high with the
-- shown stretch lit. Drawn only when the strip is a part of the deck.
local function view_map(x0, x1, y, lo, span, lvl)
  if span > 0.98 then return end
  local w = x1 - x0
  screen.level(1)
  screen.rect(x0, y, w + 1, 1)
  screen.fill()
  screen.level(lvl)
  screen.rect(x0 + floor(lo * w), y, max(2, floor(span * w + 0.5)), 1)
  screen.fill()
end

-- the head on a zoomed strip, or nil when it is outside the strip
local function view_x(ph, x0, x1, lo, span)
  local t = (ph - lo) / span
  if t < 0 or t > 1 then return nil end
  return x0 + floor(t * (x1 - x0))
end

-- the record-SOURCE flag: a deck printing PROCESSED audio is never a hidden
-- mode. DRY (the default) draws nothing. Reads the EFFECTIVE source.
local function src_flag(x, y)
  local src = C.eff_cut_source()
  if src > 0.02 then
    ptext(src > 0.98 and "SRC WET" or ("SRC WET " .. floor(src * 100 + 0.5) .. "%"),
      x, y, 1, 9)
  end
end

-- the framed 2x readout: black pocket, level-12 frame, the text at 2x. The
-- turning knob's value and the page-name pop both use it, so it is legible
-- over any body.
local function framed2x(str, bx, y)
  local w = text_w(str, 2) + 9
  screen.level(0)
  screen.rect(bx, y, w + 2, 15)
  screen.fill()
  screen.level(12)
  screen.rect(bx, y, w + 2, 15)
  screen.stroke()
  ptext(str, bx + 5, y + 3, 2, 15)
end

-- footer words per param id: the owning page's own vocabulary — these are
-- also the MOTION lane names, so a lane says what its page says
local SHORT = {
  mix = "MIX", out_level = "OUT",
  input_level = "IN", monitor_level = "MON",
  dry_wet = "D/W",
  pos_start = "ST", pos_end = "EN", pos_jitter = "JIT",
  ["@win_move"] = "MOV",
  scan = "SPEED", pitch = "PITCH",
  size = "SIZE", spread = "SPRD", density = "DENS", grain_level = "GRN",
  grain_jitter = "GJIT", grain_pitch_spread = "DTUN",
  clouds_pos = "POS", clouds_tex = "TEX", clouds_fb = "FB", clouds_lofi = "LOFI",
  warp_window = "WIN", warp_rand = "RAND",
  tape_rate = "RATE", tape_pre = "PRE", loop_start = "STRT", loop_end = "LOOP",
  cut_source = "SRC",
  cutoff = "CUT", resonance = "RES", drive = "DRV",
  delay_mix = "ECHO", delay_time = "TIME", delay_fb = "FDBK", dly_rev = "D>REV",
  delay_sync = "SYNC",
  rev_size = "SIZE", rev_mix = "VERB",
  rev_decay = "DECAY", rev_damp = "DMP", rev_early = "DIFF",
  rev_moddepth = "MOD", rev_modfreq = "MRAT", rev_low = "LOW",
  rev_mid = "MID", rev_high = "HIGH", rev_lowcut = "LCUT", rev_highcut = "HCUT",
  shimmer = "SHMR", shimmer_pitch = "OCT", shimmer_tone = "AIR",
  voice_atk = "ATK", voice_rel = "REL",
  motion_lane = "LANE", motion_depth = "DPT", motion_len = "LEN",
  ["@mo_sel"] = "LANE", mod_focus = "LANE",
  lfo1_depth = "DPT", lfo1_period = "PER", lfo1_target = "TGT",
  lfo2_depth = "DPT", lfo2_period = "PER", lfo2_target = "TGT",
  lfo3_depth = "DPT", lfo3_period = "PER", lfo3_target = "TGT",
  lfo4_depth = "DPT", lfo4_period = "PER", lfo4_target = "TGT",
  -- COLOR and SPACE (four): the crush, and each track's FX sends
  crush = "CRSH", fx_dly = "1>DLY", fx_rev = "1>REV",
  -- THE EFFECT (four): the slot's type and its two knobs
  effect = "EFFECT", effect_amt = "AMOUNT", effect_rate = "RATE",
  effect2 = "FX 2", effect2_amt = "AMT 2", effect2_rate = "RATE 2",
  seq_slice = "SLICE", pad_pitch = "PTCH", pad_voice = "TYPE",
  pad_level = "PLVL",
  -- the crossfader's two ends (SCENE E2 and K1+E2): they read B·4 and A·3
  scene_slot = "B", scene_slot_a = "A", scene_morph_amt = "MRF",
  orbit_rate = "DRFT", orbit_reach = "RCH", erode = "ERO", wear = "WEAR",
  -- nicer MOTION lane labels for params that aren't footer encoders (safe:
  -- SHORT is only read for the current page's enc ids + MOTION lane names)
  mode = "MODE", filt_type = "FILT", pan = "PAN", freeze = "FRZ",
  pv_freeze = "PVFZ", tape_freeze = "TFRZ", tape_reverse = "TREV",
  clouds_mode = "CMOD",
  -- track 2 (four): the track 1 word after "T2"
  t2_level = "T2 LV", t2_pos_start = "T2 ST", t2_pos_end = "T2 EN",
  t2_scan = "T2 SPD", t2_pitch = "T2 PTCH", t2_pan = "T2 PAN",
  t2_pos_jitter = "T2 JIT", t2_size = "T2 SIZE", t2_density = "T2 DENS",
  t2_spread = "T2 SPRD", t2_grain_jitter = "T2 GJIT",
  t2_grain_pitch_spread = "T2 DTUN", t2_clouds_pos = "T2 POS",
  t2_clouds_tex = "T2 TEX", t2_clouds_fb = "T2 FB", t2_clouds_lofi = "T2 LOFI",
  t2_clouds_mode = "T2 CMOD", t2_mode = "T2 MODE", t2_warp_window = "T2 WIN",
  t2_warp_rand = "T2 RAND", t2_pv_freeze = "T2 PVFZ", t2_cutoff = "T2 CUT",
  t2_resonance = "T2 RES", t2_filt_type = "T2 FILT",
  t2_drive = "T2 DRV", t2_crush = "T2 CRSH",
  t2_fx_dly = "2>DLY", t2_fx_rev = "2>REV",
  t2_effect = "T2 FX", t2_effect_amt = "T2 AMT", t2_effect_rate = "T2 RATE",
  t2_effect2 = "T2 FX2", t2_effect2_amt = "T2 AMT2", t2_effect2_rate = "T2 RT2",
  -- the ROUTE page: its cursor and the selected send's amount
  route_sel = "SEND", ["@route_amt"] = "AMT",
  track_sel = "TRACK", ["@route_to"] = "TO", ["@trk_level"] = "LEVEL",
}
-- tracks 3 and 4 (four): track 2's words with the number changed, and the
-- sends as "2>3" (from track 2 into track 3). Built once, at load.
do
  local add = {}
  for k, v in pairs(SHORT) do
    local rest = k:match("^t2_(.+)$")
    if rest then
      add["t3_" .. rest] = "T3" .. v:sub(3)
      add["t4_" .. rest] = "T4" .. v:sub(3)
    end
  end
  for from = 1, 4 do
    for to = 1, 4 do
      if from ~= to then add["send_" .. from .. "_" .. to] = from .. ">" .. to end
    end
    if from > 1 then
      add["t" .. from .. "_fx_dly"] = from .. ">DLY"
      add["t" .. from .. "_fx_rev"] = from .. ">REV"
    end
  end
  for k, v in pairs(add) do SHORT[k] = v end
end

-- the FULL word for a footer encoder label, shown at REST (you read "START",
-- not "ST"). Only the words that DIFFER from SHORT live here; label_for falls
-- back to SHORT for the rest. A full word that would collide with the key
-- words falls back to SHORT too (flabel_r).
local FULL = {
  input_level = "INPUT", monitor_level = "MONITOR",
  dry_wet = "DRY/WET",
  pos_start = "START", pos_end = "END", pos_jitter = "JITTER",
  ["@win_move"] = "MOVE",
  density = "DENSITY",
  warp_window = "WINDOW", warp_rand = "RANDOM",
  cut_source = "SOURCE",
  cutoff = "CUTOFF", resonance = "RESO", drive = "DRIVE",
  delay_fb = "FEEDBACK",
  delay_mix = "WET", rev_mix = "WET",
  rev_damp = "DAMP",
  voice_rel = "RELEASE",
  motion_depth = "DEPTH", motion_len = "LENGTH",
  lfo1_depth = "DEPTH", lfo1_period = "PERIOD", lfo1_target = "TARGET",
  lfo2_depth = "DEPTH", lfo2_period = "PERIOD", lfo2_target = "TARGET",
  lfo3_depth = "DEPTH", lfo3_period = "PERIOD", lfo3_target = "TARGET",
  lfo4_depth = "DEPTH", lfo4_period = "PERIOD", lfo4_target = "TARGET",
  crush = "CRUSH",
  pad_pitch = "PITCH", pad_voice = "VOICE",
  scene_morph_amt = "FADE",
  orbit_rate = "DRIFT", orbit_reach = "REACH", erode = "ERODE",
}

-- normalized 0..1 of a value for a param: controlspec unmap, option index,
-- or number range. plots the MOTION lanes' events at their captured heights.
-- pnorm takes the param OBJECT, so a caller plotting many values of one
-- param (a MOTION lane) looks it up once, not once per event.
local function pnorm(p, v)
  if not p then return 0 end
  if p.controlspec then return clamp(p.controlspec:unmap(v), 0, 1)
  elseif p.count then return p.count > 1 and (v - 1) / (p.count - 1) or 0
  elseif p.min and p.max and p.max > p.min then return (v - p.min) / (p.max - p.min) end
  return clamp(v, 0, 1)
end
local function lookup_p(id)
  return params.lookup[id] and params:lookup_param(id) or nil
end
local function value_norm(id, v) return pnorm(lookup_p(id), v) end

-- footer value text for a param: compact, ALL-CAPS abbreviations. a few
-- ids get hand-tuned units (cutoff kHz, pitch semitones, rates x, times);
-- a plain 0..1 linear control reads as a percentage; everything else falls
-- back to the norns string.
local RATE_IDS = { scan = true, tape_rate = true,
                   t2_scan = true, t2_pitch = true,
                   t3_scan = true, t3_pitch = true,
                   t4_scan = true, t4_pitch = true }
-- the modulators' params, for their footer values: LFO_OF[id] = { i, word }
local LFO_OF, LFO_NAME = {}, {}
for i = 1, 4 do
  LFO_NAME[i + 1] = "LFO" .. i
  for _, w in ipairs({ "target", "depth" }) do
    LFO_OF["lfo" .. i .. "_" .. w] = { i, w }
  end
end
local T2_KEY = {}
for k in pairs(SHORT) do
  local b = k:match("^t%d_(.+)$")
  if b then T2_KEY[k] = b end
end
-- each track's effect type id, by its rate id (RATE reads in the type's unit)
local FX_TYPE_OF = { effect_rate = "effect", t2_effect_rate = "t2_effect",
  t3_effect_rate = "t3_effect", t4_effect_rate = "t4_effect",
  effect2_rate = "effect2", t2_effect2_rate = "t2_effect2",
  t3_effect2_rate = "t3_effect2", t4_effect2_rate = "t4_effect2" }
local NOTE_NAMES = { "C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B" }
-- the scene slots' words, built once: the footer and the SCENE rail read
-- them every frame (the redraw allocates nothing). [n] the number, a[n] the
-- rail's A label ("A LIVE" at 0), b[n] its B label. One local: the chunk is
-- near Lua's 200 locals.
local SLOT_STR = { a = { [0] = "A LIVE" }, b = {} }
for i = 1, 8 do
  SLOT_STR[i] = tostring(i)
  SLOT_STR.a[i] = "A " .. i
  SLOT_STR.b[i] = i .. " B"
end
local function fmt_value(id)
  -- compound encoder targets ("@") read as their anchor param
  if id and C.enc_target then id = C.enc_target(id) end
  if not (id and params.lookup[id]) then return "--" end
  -- a track 2 id reads in its track 1 format (four)
  local key = T2_KEY[id] or id
  if key == "route_sel" then                    -- the cell: from > to
    local r = C.route_cur and C.route_cur()
    return r and SHORT[r.id] or "-"
  end
  if key == "seq_slice" then
    return tostring(floor(params:get(id) + 0.5) + 1)   -- slices read 1..8
  end
  if key == "scene_slot" then
    local v = floor(params:get(id) + 0.5)
    return v < 1 and "<" or SLOT_STR[v] or "?"         -- 0 = the ◄ cell
  end
  if key == "scene_slot_a" then
    local v = floor(params:get(id) + 0.5)
    return v < 1 and "LIVE" or SLOT_STR[v] or "?"      -- 0 = the live sound
  end
  if key == "motion_lane" then
    -- show the SELECTED lane's param name (or "-" when none picked)
    local ids = C.motion and C.motion.lane_ids
    local n = ids and #ids or 0
    local sel = clamp(floor(params:get(id) + 0.5), 0, n)
    if n == 0 or sel == 0 then return "-" end
    return SHORT[ids[sel]] or string.upper(ids[sel])
  end
  if key == "pos_start" or key == "pos_end" then
    -- the window's edges in seconds of the buffer, not a percentage
    return string.format("%.2fS", params:get(id) * (C.BUF_SECS or 60))
  end
  if key == "mod_focus" then
    return LFO_NAME[floor(params:get(id) + 0.5)] or "LANES"
  end
  if LFO_OF[key] then
    local i, w = LFO_OF[key][1], LFO_OF[key][2]
    if w == "target" then
      -- the knob it moves, on its track: "CUT", "T2 CUT", or "--" when
      -- that track has no such knob
      local L = C.lfo
      if not (L and L.TARGETS[floor(params:get(id) + 0.5) - 1]) then return "OFF" end
      local t = L.target_of(i)
      return t and (SHORT[t] or string.upper(t)) or "--"
    end
    if w == "depth" then
      return string.format("%+d%%", floor(params:get(id) * 100 + 0.5))
    end
  end
  if key == "motion_len" then
    local v = params:get(id)
    return v < 0.05 and "AUTO" or string.format("%.1fS", v)
  end
  if key == "cut_source" then                    -- tape source: DRY .. WET blend
    local v = params:get(id)
    if v < 0.02 then return "DRY" end
    if v > 0.98 then return "WET" end
    return floor(v * 100 + 0.5) .. "%"
  end
  if key == "effect_rate" or key == "effect2_rate" then
    -- RATE reads in the unit its effect gives it: a speed, a note, a frequency
    local fx = floor(params:get(FX_TYPE_OF[id]) + 0.5)
    local v = params:get(id)
    if fx == 2 then return string.format("%.1fHZ", 0.1 * 60 ^ v) end
    if fx == 3 then return string.format("%.2fHZ", 0.05 * 100 ^ v) end
    if fx == 5 then
      local m = floor(36 + v * 48 + 0.5)
      return NOTE_NAMES[m % 12 + 1] .. (floor(m / 12) - 1)
    end
    if fx == 6 then
      local hz = 20 * 200 ^ v
      return hz >= 1000 and string.format("%.1fKHZ", hz / 1000)
        or string.format("%dHZ", floor(hz + 0.5))
    end
    if fx == 7 then                     -- ECHO: its time
      local t = 0.03 * 40 ^ v
      return t >= 1 and string.format("%.2fS", t) or string.format("%dMS", floor(t * 1000 + 0.5))
    end
    return string.format("%d%%", floor(v * 100 + 0.5))
  end
  if key == "cutoff" then
    local v = params:get(id)
    return v >= 1000 and string.format("%.1fKHZ", v / 1000)
      or string.format("%dHZ", floor(v + 0.5))
  elseif key == "rev_decay" then
    return string.format("%.1fS", params:get(id))
  elseif key == "rev_size" then
    return string.format("%.1f", params:get(id))
  elseif key == "pitch" then
    local st = floor(12 * log(params:get(id)) / log(2) + 0.5)
    return (st >= 0 and "+" or "") .. st .. "ST"
  elseif RATE_IDS[id] then
    return string.format("%+.2fX", params:get(id))
  elseif key == "delay_time" then
    local v = params:get(id)
    return v >= 0.9995 and string.format("%.2fS", v)
      or string.format("%dMS", floor(v * 1000 + 0.5))
  elseif key == "size" then
    local v = params:get(id)
    return v >= 1 and string.format("%.1fS", v)
      or string.format("%dMS", floor(v * 1000 + 0.5))
  elseif key == "density" then
    return tostring(floor(params:get(id) + 0.5))
  end
  local p = params:lookup_param(id)
  local cs = p.controlspec
  if cs and cs.minval and cs.maxval and cs.minval >= 0 and cs.maxval <= 1 then
    return string.format("%d%%", floor(params:get(id) * 100 + 0.5))
  end
  return string.upper(params:string(id))
end

-- is this param the one currently being turned? (brightens its footer word and
-- swells the big value box; the window is armed in the encoder handler, ~1.2s)
local function is_turning(id)
  return id ~= nil and C.flash_id == id and C.frame < C.flash_until
end

-- selector pages are the one exception to numbers-only-while-turning:
-- the selection IS the state, so it reads at rest (SLICE·3, LANE·…)
local SELECTOR_IDS = {
  route_sel = true, track_sel = true, ["@route_to"] = true,
  seq_slice = true, motion_lane = true, scene_slot = true, scene_slot_a = true,
  ["@mo_sel"] = true,
}

local FY = 58  -- the footer text row (four quiet words)

-- one key word: rest = dim text, engaged (latched or held) = inverted chip.
-- def.lit() is the truth; a punched key reads identical while the finger is
-- down and reverts on release — the whole temporary/latched language.
-- the frame the arc beside the K3 word started on, or nil: the K1+K3
-- eraser, or a key held on a def with a `hold` (TAKE K3 = UNDO). Its word is
-- the arc's, from the frame the tap window can no longer be a tap.
-- past_tap: a press from frame f0 is no longer a tap. Until then a release
-- still fires the tap (SNAP, MODE, TYPE, DRY), so the screen keeps the tap's
-- word: it showed the hold's word, arc and hatch from the second frame, and
-- a release in frames 2 to 4 then did what the screen did not say.
local function past_tap(f0) return C.frame - f0 >= C.TAP_FRAMES end
local function arc_start()
  if C.alt and C.k13_frame and C.page_erase() then
    return C.k13_frame, "ERASE"
  end
  if not C.hold_frame then return end
  local hf, def = C.hold_frame(3)   -- (an `and` here would keep one value)
  if hf then return hf, def.hold_label or "HOLD" end
end
local function fkey_draw(n, x)
  local def = C.key_def(n)
  local lab = def and def.label or "--"
  if n == 3 then
    local f0, word = arc_start()
    if f0 and past_tap(f0) then
      ptext(word, x, FY, 1, 15)      -- the tap became the hold
      return text_w(word, 1), word
    end
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
  return w, lab
end

-- one encoder word, right-anchored: WORD· — the FULL word, except on the
-- selector pages, where the SHORT word carries the selection beside it
-- (SLICE·3). A turning knob only brightens its word; its value swells in the
-- big box above the footer (draw_big_value). minx is the key words' right
-- edge: a full word that would cross it drops to the abbreviation, so the
-- row never overlaps.
-- hoisted out of flabel_r so the draw path allocates no per-frame closures
local T2_BASE = {}
for k in pairs(SHORT) do
  local b = k:match("^t%d_(.+)$")
  if b and SHORT[b] then T2_BASE[k] = b end
end
local function label_for(id, full)
  if not id then return "--" end
  id = T2_BASE[id] or id
  if full then return FULL[id] or SHORT[id] or string.upper(id) end
  return SHORT[id] or "--"
end
-- the word the footer shows at rest for an encoder target (test/controls.lua
-- writes it into doc/controls.md): a selector's short word, else the full one
function M.footer_word(id)
  return label_for(id, not (id and SELECTOR_IDS[id]))
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
  framed2x(v, 126 - (text_w(v, 2) + 9), 41)
end

-- footer: K2 K3 | E2· E3· — four quiet words that never lie about the keys.
-- M.FOOT keeps the last layout for the tests: `arc` the erase arc's right
-- edge (nil when it is not drawn), `e2` the E2 word's left edge and `k3`
-- the K3 word as drawn.
local FOOT = { arc = nil, e2 = 0, e3 = 0, k3 = nil }
M.FOOT = FOOT
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
  w, FOOT.k3 = fkey_draw(3, x)
  local keys_right = x + w + 4     -- the key words' right edge (labels clear it)
  FOOT.arc = nil
  -- the hold-arc beside the K3 word (the eraser, or TAKE's UNDO). It
  -- belongs to the key words, so the encoder words clear it too: one that
  -- would cross it drops to its short word while the arc draws.
  local f0 = arc_start()
  if f0 then
    local dt = C.frame - f0
    if past_tap(f0) then
      local ax, ay = x + w + 8, FY + 2
      keys_right = ax + 7
      FOOT.arc = ax + 4
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
  FOOT.e3 = e3x
  FOOT.e2 = flabel_r(C.enc_param(2), e3x - 9, keys_right)
  draw_big_value()
end

-- ============================================================================
-- the dominant objects, one per page (doc/redesign.md §6)
-- ============================================================================
-- one object per page, drawn from REAL state, brightness riding audibility.
-- statics first: everything the 15fps hot path needs preallocated.

-- FILTER: log-frequency axis 20Hz..20kHz over 128 columns, rail columns at
-- 100Hz/1k/10k (labeled), the 0dB row, and a reusable response buffer (the
-- curve approximates the engine's DFM1 build, see body_FILTER; the resonance
-- law mirrors Engine_Four.sc, keep them in sync)
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

-- TAKE's top row. Right: the window locked to the clock ("1 BAR"), and
-- "ON SND" while a record would wait for sound, so you know before you arm.
-- Left: "<" while an UNDO is kept, then the chips of a writer that re-touches
-- the buffer (RSMP, REGN). What K3's SNAP or UNDO just did takes the whole row
-- for a moment: the action proves it happened.
local REC_INTO = { "TRACK 1", "TRACK 2", "TRACK 3", "TRACK 4" }
local REC_THEN = { "THEN 2", "THEN 3", "THEN 4" }
local REC_LAST = "THEN STOP"
local function take_top_row(frame, rec)
  if C.take_msg and (frame - (C.take_msg_at or -1e9)) < FPS * 1.2 then
    screen.level(0); screen.rect(0, 11, 128, 7); screen.fill()
    ptext_c(C.take_msg, 64, 12, 1, 12)
    return
  end
  local rx = 126
  local wb = floor(pget("win_beats", 1) + 0.5)
  if wb > 1 then
    local name = C.WIN_BEAT_NAMES[wb]
    ptext_r(name, rx, 12, 1, 6)
    rx = rx - text_w(name, 1) - 5
  end
  if not rec and pget("rec_wait", 0) == 1 and pget("pre_level", 0) < 0.001 then
    ptext_r("ON SND", rx, 12, 1, 5)
  end
  local bx = 2
  -- (four) what is being recorded, in words: REC, the track, and with
  -- REC END on ONE-SHOT the track it goes on to
  if rec then
    local n = C.tsel and C.tsel() or 1
    bx = bx + chip("REC", bx, 12) + 3
    ptext(REC_INTO[n], bx, 12, 1, 15)
    bx = bx + text_w(REC_INTO[n], 1) + 4
    if pget("rec_end", 1) == 2 then
      ptext(n < 4 and REC_THEN[n] or REC_LAST, bx, 12, 1, 6)
    end
    return
  end
  if C.undo_ready and C.undo_ready() then
    ptext("<", bx, 12, 1, 6)
    bx = bx + 7
  end
  if not rec then
    -- resample/regen: the buffer is being re-touched by output
    if pget("resample", 0) > 0 then bx = bx + chip("RSMP", bx, 12) + 2 end
    if pget("regen", 0) > 0 then chip("REGN", bx, 12) end
  end
end

-- four: VOICE and FILTER draw the track they address (C.tid picks the
-- id). tp reads the selected track's value of a track 1 id; the read head
-- and the window follow the track too.
-- each extra track's ids, built once (the redraw path must not allocate)
local TK = {}
for n = 2, 4 do
  local pre = "t" .. n .. "_"
  TK[n] = { mode = pre .. "mode", level = pre .. "level",
    pos_start = pre .. "pos_start", pos_end = pre .. "pos_end",
    pv_freeze = pre .. "pv_freeze" }
end
local function cur_track() return C.tsel and C.tsel() or 1 end
local function on_t2() return cur_track() > 1 end
local function tp(id, d) return pget(C.tid and C.tid(id) or id, d) end
local function track_phase()
  local n = cur_track()
  if n > 1 then return C.play_phases and C.play_phases[n] or 0 end
  return C.play_phase
end
local function track_window_n(n)
  if n < 2 then
    -- track 1's own window (window_bounds is the FOCUSED track's)
    local a, b = pget("pos_start", 0), pget("pos_end", 1)
    local lo, hi = min(a, b), max(a, b)
    return lo, hi, max(hi - lo, 0.001)
  end
  local a, b = pget(TK[n].pos_start, 0), pget(TK[n].pos_end, 1)
  local lo, hi = min(a, b), max(a, b)
  return lo, hi, max(hi - lo, 0.001)
end
local function track_window() return track_window_n(cur_track()) end
-- an extra track is sounding: switched on and its level up
local function track_live(n)
  return pget(TK[n].mode, 1) ~= 1 and pget(TK[n].level, 1) > 0.001
end
M.on_t2 = on_t2

local function body_TAKE(frame)
  local rec = pget("rec", 0) == 1 and pget("freeze", 0) == 0
  if not C.wave_any and not rec then
    screen.level(3)
    for x = 2, 125, 3 do screen.rect(x, TK_MID, 1, 1) end
    screen.fill()
    ptext_c("EMPTY - K2 REC", 64, 24, 1, 10)
    ptext_c("OR PARAMS > LOAD", 64, 34, 1, 5)
    take_top_row(frame, rec)
    return
  end
  -- the window of the FOCUSED track (four): TAKE 2 edits track 2's
  local lo, hi = track_window()
  local wx = clamp(C.rec_phase, 0, 1) * 127
  -- marked for erase: K1+K3 held past the tap window on this page
  local marked = C.k13_frame ~= nil
    and past_tap(C.k13_frame) and not C.k13_fired
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
    -- sweeping write head, the big elapsed seconds, the IN meter, the words
    -- REC TRACK n and the header's blinking track box already say REC.
    screen.level(15)                -- the write head
    screen.move(wx, TK_MID - TK_HALF - 2)
    screen.line(wx, TK_MID + TK_HALF + 2)
    screen.stroke()
    -- elapsed seconds: the one number a performer needs
    -- ...or, armed to start on sound and none yet, WAIT. From x 84 the
    -- widest count (60.0S, 42px at 2x) ends at 125. From 88 every count
    -- from 20 s on lost the last two columns of its S off the screen.
    if C.rec_waiting then
      ptext("WAIT", 84, 46, 2, 12)   -- steady: the header's track box is the blink
    else
      local el = ((clamp(C.rec_phase, 0, 1) - C.rec_arm_phase) % 1) * C.BUF_SECS
      ptext(string.format("%.1fS", el), 84, 46, 2, 15)
    end
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
  end
  -- the READ (playback) head, drawn LAST so it never hides behind the solid
  -- WRITE head. distinct SHAPE, not just tone: a
  -- DASHED column + a caret above the strip vs the write head's solid line +
  -- comet-tail glow — so even when they cross you can tell read from write.
  -- (four) only the focused track: every track has its own take, so the
  -- other tracks' windows and heads are on other material and do not
  -- belong over this wave (drawn here, they read as part of this take)
  local focus = cur_track()
  local fmode = focus == 1 and pget("mode", 5) or pget(TK[focus].mode, 1)
  if C.wave_any and fmode ~= 1 then
    local phx = clamp(track_phase(), 0, 1) * 127
    screen.level(15)
    for y = TK_MID - TK_HALF, TK_MID + TK_HALF, 2 do screen.rect(phx, y, 1, 1) end
    screen.rect(phx, TK_MID - TK_HALF - 3, 1, 1)          -- caret stem
    screen.rect(phx - 1, TK_MID - TK_HALF - 4, 3, 1)      -- caret ▽ above the strip
    screen.fill()
  end
  take_top_row(frame, rec)   -- last: a message's pocket covers the caret
end

-- ============================================================================
-- 2 · VOICE — how the take plays (mode rail + the mode's own texture)
-- ============================================================================
local VOICE_RAIL = { { "PLAY", 5 }, { "GRAIN", 2 }, { "WARP", 3 }, { "PV", 4 }, { "CLOUD", 6 } }

local function voice_wy(x, ph, rate)
  return 33 + sin((x + ph) * 0.35 * rate) * 8
end

-- EROSION state: how aged the take is. The generation counter counts
-- completed loop passes while eroding; drawn inside VOICE's PLAY texture
-- (PLAY is the only mode the engine erodes in). Declared BEFORE body_VOICE:
-- referenced from there, and a later local would silently read as a global.
local eros_gen, eros_acc, eros_live = 0, 0, false
-- the one rule for "the erosion head is engaged": erode up, in PLAY. The
-- strip repaint (four.lua's take_writing) asks the same question.
function M.eroding()
  return pget("erode", 0) > 0 and pget("mode", 5) == 5
end
function M.erosion_tick()
  -- the engine spawns its erosion head at the window's start each time
  -- erosion engages (erode up in PLAY), so an engagement starts a new pass
  local live = M.eroding()
  if live and not eros_live then eros_acc = 0 end
  eros_live = live
  -- the erosion head runs at exactly one pass per window length, so a
  -- generation is span times sixty seconds of eroding time. paused under
  -- the same conditions the engine pauses its head (rec, freeze, and a
  -- SILENCED deck: the engine runs the head on level > 0.001, so the GEN
  -- counter must not keep counting through a STOP or a full mix throw).
  if live and pget("rec", 0) == 0 and pget("freeze", 0) == 0
      and (C.mix_gains()) > 0.001 then
    local _, _, span = track_window_n(1)   -- the erosion is track 1's
    eros_acc = eros_acc + (1 / FPS) / (span * C.BUF_SECS)
    if eros_acc >= 1 then
      eros_gen = eros_gen + 1
      eros_acc = eros_acc - 1
    end
  end
end
function M.erosion_reset() eros_gen, eros_acc = 0, 0 end


-- GRAIN: the cloud the knobs make. Each grain is a short tick: DENSITY sets
-- how many (3 to 40), SIZE how long each one is and how long it lives, and
-- grain JITTER how much the lengths differ. The x axis is the buffer, as the
-- window bar below it says, so the cloud sits on the play head and position
-- JITTER widens it over the window. The y axis is the stereo field, left at
-- the top: PAN moves the cloud and SPREAD scatters it. A grain fades in and
-- out over its life and drifts the way SPEED reads, except while a freeze
-- holds the read point (FREEZE, or the PV freeze that Clouds takes as its
-- own). The randoms come from `hash` on the frame, never from math.random,
-- so the orbit keeps its own sequence and a shot repeats. `pairs` (GRAIN):
-- the grains are stereo pairs, so half sit toward the left and half toward
-- the right, 1 - SPREAD from the middle (the engine's law); CLOUD scatters
-- each grain around the pan.
local GR_MAX, GR_MID, GR_HALF = 40, 34, 11
local function grain_cloud(frame, scan, pairs)
  local sn = value_norm("size", tp("size", 0.1))
  local dn = value_norm("density", tp("density", 20))
  local spread = clamp(tp("spread", 0.5), 0, 1)
  local pan = clamp(tp("pan", 0), -1, 1)
  local pj = clamp(tp("pos_jitter", 0), 0, 1)
  local gj = clamp(tp("grain_jitter", 0), 0, 1)
  local lo, hi = track_window()
  local n = 3 + floor(dn * (GR_MAX - 3) + 0.5)
  local life = 2 + floor(sn * 14 + 0.5)
  local reach = 3 + pj * (hi - lo) * 127
  local cx = clamp(track_phase(), 0, 1) * 127
  local held = pget("freeze", 0) == 1 or tp("pv_freeze", 0) == 1
  local drift = held and 0 or scan * 0.6
  for k = 1, n do
    local t = frame + floor(k * life / n)     -- the births are staggered
    local e = floor(t / life)                 -- this grain's generation
    local age = t - e * life
    local len = max(1, floor((1 + sn * 10) * (1 + gj * (hash(k, e, 3) * 2 - 1)) + 0.5))
    local x = (cx + (hash(k, e, 1) * 2 - 1) * reach + age * drift) % 128
    local side = pairs and (k % 2 == 0 and 1 or -1) * (1 - spread) or 0
    local y = GR_MID + floor(clamp(pan + side + (hash(k, e, 2) * 2 - 1) * spread, -1, 1)
      * GR_HALF + 0.5)
    screen.level(3 + floor(sin(PI * (age + 0.5) / life) * 12 + 0.5))
    screen.rect(floor(x - len / 2), y, len, 1)
    screen.fill()
  end
end

-- the mode rail: the active word inverted; OFF dims the whole rail
local function mode_rail(mode)
  -- five words on 128px: the gap is what the words leave, at most 8
  local tw = 0
  for i = 1, #VOICE_RAIL do tw = tw + text_w(VOICE_RAIL[i][1], 1) end
  local gap = min(8, floor((122 - tw) / (#VOICE_RAIL - 1)))
  local x = 3
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
    x = x + w + gap
  end
end

local function body_VOICE(frame)
  local mode = tp("mode", 5)
  local held_pv = tp("pv_freeze", 0) == 1
  mode_rail(mode)
  -- HELD: the PV freeze is heard in PV, in GRAIN (the head stops, the
  -- grains go on) and in CLOUD (the Clouds freeze). In PLAY and WARP it
  -- waits, dim.
  -- (under the rail's right end: the five words fill its row)
  if mode == 1 then ptext_r("OFF", 126, 22, 1, 8)
  elseif held_pv then
    ptext_r("HELD", 126, 22, 1, (mode == 4 or mode == 2 or mode == 6) and 12 or 4)
  end
  -- the texture IS the mode, drawn from the playing motion (drifts with
  -- scan, stands still frozen, lies flat when the voice is freed/silent)
  local scan = tp("scan", 1)
  local rate = max(abs(scan), 0.05)
  local ph = (held_pv and mode == 4) and 0 or frame * 0.8 * scan
  -- silent = nothing recorded, OR the engine deck is choked (STOP, or MIX
  -- thrown fully to tape): the engine halts the read head then, so the
  -- texture lies flat and the playhead goes, as everywhere else
  local silent = not C.wave_any or (C.mix_gains()) <= 0.001
    or (on_t2() and pget(TK[cur_track()].level, 1) <= 0.001)
  if mode == 1 or silent then
    screen.level(1)
    screen.move(0, 33) screen.line(128, 33)
    screen.stroke()
    -- nothing to play: the invitation, in TAKE's voice (K2 here is a freeze)
    if not C.wave_any then ptext_c("EMPTY - REC ON TAKE", 64, 24, 1, 10) end
  elseif mode == 2 or mode == 6 then   -- GRAIN and CLOUD: the cloud (grain_cloud)
    grain_cloud(frame, scan, mode == 2)
  elseif mode == 3 then        -- WARP: an overlapped window ghosts behind
    local off = 9 + sin(frame * 0.9) * 6 * tp("warp_rand", 0)
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
  else                         -- PLAY: one unbroken wave — the exact sample,
    -- aged by EROSION when it runs (PLAY is the only mode that erodes; the
    -- controls are this page's alt pair). two passes so every pixel fills at
    -- its own level: the base wave dims as erosion deepens, then the fuzz
    -- flecks eat into it. dormant at erode 0 — the wave is untouched.
    local e = on_t2() and 0 or clamp(pget("erode", 0), 0, 1)   -- track 1 only
    screen.level(9 - floor(e * 5))
    for gx = 0, 127 do
      if e <= 0 or hash(gx, frame % 8, 3) >= e * 0.7 then
        screen.rect(gx, voice_wy(gx, ph, rate), 1, 1)
      end
    end
    screen.fill()
    if e > 0 then
      screen.level(2)
      for gx = 0, 127 do
        if hash(gx, frame % 8, 3) < e * 0.7 then
          screen.rect(gx, voice_wy(gx, ph, rate), 1, 1)
        end
      end
      screen.fill()
      -- generation counter + progress through the current pass. the mode
      -- rail runs nearly to the right edge, so the counter sits below it in
      -- its own pocket (the footer's swelling-value rule).
      local gtxt = "GEN " .. eros_gen
      local tw = text_w(gtxt, 1)
      screen.level(0)
      screen.rect(124 - tw, 21, tw + 4, 7)
      screen.fill()
      ptext(gtxt, 126 - tw, 22, 1, 12)
      screen.level(5)
      screen.rect(0, 46, floor(clamp(eros_acc, 0, 1) * 128), 1)
      screen.fill()
    end
  end
  -- window bar + the playhead (nothing moves that can't be heard)
  local lo, hi = track_window()
  screen.level(2)
  screen.move(0, 48) screen.line(128, 48)
  screen.stroke()
  screen.level(6)
  screen.move(lo * 127, 48) screen.line(hi * 127, 48)
  screen.stroke()
  if mode ~= 1 and not silent then
    screen.level(15)
    local phx = clamp(track_phase(), 0, 1) * 127
    screen.move(phx, 24) screen.line(phx, 50)
    screen.stroke()
  end
end

-- ============================================================================
-- TRACKS (four): the hub. At rest, the four tracks in a list: the focus
-- marked, each track's mode, its window on the take with its head, and its
-- level. With K1 held, the sends as a grid, the S-4's routing: a row is
-- where a sound comes FROM, a column where it goes TO; the diagonal is the
-- track itself. A cell fills with its send level, the focused track's row is
-- the one the encoders reach, and the cursor's cell is framed bright. On the
-- right, the cursor's route in words. A label is bright while its track
-- sounds; everything dims while STOP or the MIX throw silences the engine.
-- ============================================================================
-- The last two columns are SPACE: how much of the track goes into the
-- shared delay (D) and reverb (R), full by default.
local RT_X0, RT_Y0, RT_CW, RT_RH = 20, 19, 14, 8
local RT_CELL = 12
local RT_ROW = { "T1", "T2", "T3", "T4" }
local RT_COL = { "1", "2", "3", "4", "D", "R" }
local RT_TO = { "T1", "T2", "T3", "T4", "DLY", "REV" }
-- the send ids and the percent words, built once (no allocation per frame)
local RID, PCT = {}, {}
for r = 1, 4 do
  RID[r] = {}
  for c = 1, 4 do RID[r][c] = "send_" .. r .. "_" .. c end
  RID[r][5] = r == 1 and "fx_dly" or ("t" .. r .. "_fx_dly")
  RID[r][6] = r == 1 and "fx_rev" or ("t" .. r .. "_fx_rev")
end
for v = 0, 100 do PCT[v] = v .. "%" end
local function track_sounds(n)
  if n == 1 then return pget("mode", 5) ~= 1 end
  return track_live(n)
end
local function route_grid(frame)
  local audible = (C.mix_gains()) > 0.001
  local cur = C.route_cur and C.route_cur()
  ptext("TO", 6, 12, 1, 3)       -- columns: where a send goes
  for c = 1, 6 do
    ptext_c(RT_COL[c], RT_X0 + (c - 1) * RT_CW + RT_CELL / 2, 12, 1, c > 4 and 7 or 5)
  end
  -- the line between the tracks and the FX
  screen.level(1)
  screen.rect(RT_X0 + 4 * RT_CW - 2, RT_Y0 - 1, 1, 4 * RT_RH)
  screen.fill()
  for r = 1, 4 do
    local y = RT_Y0 + (r - 1) * RT_RH
    ptext(RT_ROW[r], 6, y, 1, (audible and track_sounds(r)) and 13 or 4)
    if r == cur_track() then ptext(">", 1, y, 1, 15) end
    for c = 1, 6 do
      local x = RT_X0 + (c - 1) * RT_CW
      if r == c then
        screen.level(2)
        screen.rect(x + RT_CELL / 2 - 1, y + 2, 2, 1)
        screen.fill()
      else
        local v = clamp(pget(RID[r][c], 0), 0, 1)
        screen.level(2)
        screen.rect(x, y, RT_CELL, 6)
        screen.stroke()
        if v > 0.001 then
          screen.level(audible and 11 or 4)
          screen.rect(x + 1, y + 1, max(1, floor(v * (RT_CELL - 2) + 0.5)), 4)
          screen.fill()
        end
        if cur and cur.from == r and cur.to == c then
          screen.level(15)
          screen.rect(x - 1, y - 1, RT_CELL + 2, 8)
          screen.stroke()
        end
      end
    end
  end
  -- the cursor's route, in words, on the right
  if cur then
    ptext_c(RT_ROW[cur.from], 116, 19, 1, 12)
    ptext_c(">", 116, 27, 1, 6)
    ptext_c(RT_TO[cur.to], 116, 35, 1, 12)
    local v = clamp(pget(cur.id, 0), 0, 1)
    ptext_c(v > 0.001 and PCT[floor(v * 100 + 0.5)] or "OFF", 116, 45, 1, v > 0.001 and 10 or 4)
  end
end

local TR_MODE = { "OFF", "GRAIN", "WARP", "PV", "PLAY", "CLOUD" }
local TR_EMPTY = "EMPTY"
local TR_Y0, TR_RH = 12, 10
local TR_SX, TR_SW = 46, 49          -- the window strip
local TR_LX, TR_LW = 102, 24         -- the level bar
local function body_TRACKS(frame)
  if C.alt then route_grid(frame); return end
  local audible = (C.mix_gains()) > 0.001
  local focus = cur_track()
  for n = 1, 4 do
    local y = TR_Y0 + (n - 1) * TR_RH
    local mode = clamp(floor(pget(C.MODE_ID[n], 1) + 0.5), 1, 6)
    local sounds = audible and track_sounds(n)
    if n == focus then
      screen.level(2)
      screen.rect(0, y - 2, 128, TR_RH - 1)
      screen.fill()
      ptext(">", 1, y, 1, 15)
    end
    ptext(RT_ROW[n], 7, y, 1, sounds and 15 or 5)
    ptext(TR_MODE[mode], 20, y, 1, mode == 1 and 3 or (sounds and 12 or 6))
    -- a modulator moves one of this track's knobs: a small wave between
    -- the window strip and the level bar
    if C.lfo and C.lfo.moves_track(n) then
      screen.level(sounds and 12 or 4)
      screen.rect(96, y + 2, 1, 1)
      screen.rect(97, y + 1, 1, 1)
      screen.rect(98, y + 2, 1, 1)
      screen.rect(99, y + 3, 1, 1)
      screen.rect(100, y + 2, 1, 1)
      screen.fill()
    end
    -- the window on the take, and the head while it sounds
    local lo, hi = track_window_n(n)
    screen.level(1)
    screen.rect(TR_SX, y + 2, TR_SW, 1)
    screen.fill()
    if not C.track_has(n) then
      ptext(TR_EMPTY, TR_SX + 14, y, 1, 3)   -- no material of its own yet
    else
      screen.level(mode == 1 and 4 or (n == focus and 12 or 8))
      screen.rect(TR_SX + floor(lo * (TR_SW - 1)), y + 1,
        max(1, floor((hi - lo) * (TR_SW - 1) + 0.5)), 3)
      screen.fill()
      if sounds then
        local ph = n == 1 and C.play_phase or (C.play_phases[n] or 0)
        screen.level(15)
        screen.rect(TR_SX + floor(clamp(ph, 0, 1) * (TR_SW - 1)), y - 1, 1, 7)
        screen.fill()
      end
    end
    -- the level (0 to 1.5, unity marked)
    local lv = clamp(pget(C.LEVEL_ID[n], 1) / 1.5, 0, 1)
    screen.level(1)
    screen.rect(TR_LX, y + 1, TR_LW, 3)
    screen.fill()
    screen.level(sounds and 11 or 4)
    screen.rect(TR_LX, y + 1, floor(lv * TR_LW + 0.5), 3)
    screen.fill()
    screen.level(7)
    screen.rect(TR_LX + 16, y, 1, 5)
    screen.fill()
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
  -- the reels spin at the effective rate: reverse -> backward, stopped -> still.
  -- STOP halts the tape head (the rate law folds it), so it halts the reels
  local r = pget("tape_rate", 1) * (pget("tape_reverse", 0) == 1 and -1 or 1)
    * (1 - pget("stop_all", 0))
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
  -- the loop below, as what is ON it: the strip is the loop (or the pass
  -- that is still open), with the head, and under it where that sits in the
  -- 60s of tape
  local _, tape_g = C.mix_gains()
  local heard = tape_g > 0.001
  local td = C.tape_deck
  local vlo, vspan = deck_view(a2, b2, td and td.mat_lo, td and td.mat_hi, C.TAPE_LEN or 60)
  local x0, x1 = 2, 125
  local recording = pget("tape_rec", 0) == 1 and pget("tape_freeze", 0) == 0
  if C.twave_any or recording then
    screen.level(heard and 10 or 5)
    wave_lane(twave, x0, x1, 42, 5, 1, 5, vlo, vspan)
    if lspan < 0.999 then               -- the loop's two ends
      screen.level(6)
      screen.rect(x0 - 1, 36, 1, 13)
      screen.rect(x1 + 1, 36, 1, 13)
      screen.fill()
    end
    local hx = view_x(clamp(C.tape_phase, 0, 1), x0, x1, vlo, vspan)
    if hx then
      screen.level(heard and 15 or 7)
      screen.rect(hx, 36, 1, 13)
      screen.fill()
    end
    view_map(x0, x1, 51, vlo, vspan, heard and 8 or 4)
  else
    screen.level(2)
    screen.rect(x0, 42, x1 - x0 + 1, 1)
    screen.fill()
  end
  ptext_r(string.format("%.1fS", lspan * (C.TAPE_LEN or 60)), 126, 12, 1, 5)
  src_flag(2, 20)
  if recording then
    chip("REC", 2, 12)                -- steady: the header T is the blink
  elseif not C.twave_any then
    ptext_c("EMPTY - K2 REC", 64, 26, 1, 10)
  elseif not heard then
    -- a loop that plays unheard is the tape's commonest puzzle: say where
    -- the sound went
    ptext_r("SILENT", 126, 20, 1, 9)
    ptext_r("SEE MIX", 126, 28, 1, 5)
  end
end

-- ============================================================================
-- 5 · FILTER — tone (approx DFM1 response, with labeled measurement rails;
--     drive = grit on the line, not a number)
-- ============================================================================
local function body_FILTER(frame)
  local cut = tp("cutoff", 20000)
  local ft = tp("filt_type", 1)
  local res = tp("resonance", 0)
  local drv = tp("drive", 0)
  local crush = tp("crush", 0)
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
  if crush > 0.005 then
    -- CRUSH draws the curve as stairs: held in steps as wide as the rate
    -- falls, and in rows as coarse as the bits fall
    local sx = 1 + floor(crush * 7)
    local sy = 1 + floor(crush * 3)
    for x = 0, 127, sx do
      local y = floor(FILT_Y[x + 1] / sy + 0.5) * sy
      screen.rect(x, y, min(sx, 128 - x), 1)
    end
    screen.fill()
  else
    for x = 1, 127 do
      screen.move(x - 1, FILT_Y[x])
      screen.line(x, FILT_Y[x + 1])
    end
    screen.stroke()
  end
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
  chip(params:string(C.tid and C.tid("filt_type") or "filt_type"), 2, 12)
end

-- ============================================================================
-- 5b · EFFECT — the focused track's effect slot. One trace, drawn the way the
--      effect moves the sound, so the type reads without its name:
--        CHORUS  the wave and two copies that drift apart and back
--        FLANGE  the wave and a train of close echoes that sweeps
--        WOBBLE  one wave whose time bends
--        RESON   a string that rings, more waves for a higher note
--        RING    the wave cut into beats
--      OFF, or a silent track, lies flat and dim.
-- ============================================================================
local FX_YM = 31
local FX_Y = {}
for i = 1, 128 do FX_Y[i] = FX_YM end
local function fx_stroke(level)
  screen.level(level)
  for x = 1, 127 do
    screen.move(x - 1, FX_Y[x])
    screen.line(x, FX_Y[x + 1])
  end
  screen.stroke()
end
-- the plain wave, `sh` columns late, at height `h`
local function fx_wave(sh, h)
  for x = 0, 127 do FX_Y[x + 1] = FX_YM + h * sin((x - sh) * 0.16) end
end
local function body_EFFECT(frame)
  local fx = floor(tp("effect", 1) + 0.5)
  -- the second slot, named top right while it is on (K1+E2 and K1+E3 turn
  -- its knobs; its type is in PARAMS for now)
  if floor(tp("effect2", 1) + 0.5) > 1 then
    ptext_r("+ " .. params:string(C.tid and C.tid("effect2") or "effect2"), 126, 12, 1,
      track_sounds(cur_track()) and 10 or 4)
  end
  local a = tp("effect_amt", 0.5)
  local r = tp("effect_rate", 0.5)
  local live = track_sounds(cur_track())
  if fx <= 1 then
    -- OFF: the sound passes untouched. A dim word and one flat dim line
    ptext("OFF", 5, 14, 1, 4)
    screen.level(2)
    screen.rect(4, FX_YM, 120, 1)
    screen.fill()
    return
  end
  chip(params:string(C.tid and C.tid("effect") or "effect"), 2, 12)
  local hi = live and 12 or 4
  local lo = live and 5 or 2
  local t = frame / FPS
  if fx == 2 then
    local d = (2 + a * 7) * sin(t * 6.2832 * 0.1 * 60 ^ r * 0.25)
    fx_wave(0, 9) fx_stroke(lo)
    fx_wave(d, 9) fx_stroke(hi)
    fx_wave(-d, 9) fx_stroke(hi)
  elseif fx == 3 then
    local d = 2.5 + 2 * sin(t * 6.2832 * 0.05 * 100 ^ r * 0.25)
    fx_wave(0, 9) fx_stroke(hi)
    local h = 9
    for k = 1, 1 + floor(a * 3 + 0.5) do
      h = h * (0.45 + a * 0.3)
      fx_wave(d * k, h) fx_stroke(lo)
    end
  elseif fx == 4 then
    local w = t * (1 + r * 4)
    for x = 0, 127 do
      FX_Y[x + 1] = FX_YM + 9 * sin((x + a * 20 * sin(w + x * 0.05)) * 0.16)
    end
    fx_stroke(hi)
  elseif fx == 5 then
    local n = 1 + floor(r * 7 + 0.5)
    local ring = (0.35 + a * 0.65) * (0.6 + 0.4 * cos(t * 9))
    for x = 0, 127 do
      FX_Y[x + 1] = FX_YM + 12 * ring * sin(x * 3.14159 * n / 127)
    end
    fx_stroke(hi)
    screen.level(lo)
    screen.rect(0, FX_YM - 3, 1, 7)
    screen.rect(127, FX_YM - 3, 1, 7)
    screen.fill()
  elseif fx == 7 then
    -- ECHO: one burst and its repeats, as far apart as the time is long and
    -- fading as the feedback says
    local gap = 10 + r * 44
    local g = 1
    for n = 0, 5 do
      local x0 = 6 + floor(n * gap)
      if x0 > 120 or g < 0.06 then break end
      screen.level(n == 0 and hi or max(1, floor(lo + (hi - lo) * g)))
      for x = x0, min(127, x0 + 6) do
        local h = 10 * g * sin((x - x0) * 0.52)
        screen.rect(x, FX_YM - h, 1, max(1, 2 * h))
      end
      screen.fill()
      g = g * (0.15 + a * 0.7)
    end
  else
    local k = 0.25 + r * 1.6
    for x = 0, 127 do
      FX_Y[x + 1] = FX_YM + 11 * sin(x * 0.16) * ((1 - a) + a * sin(x * k + t * 3))
    end
    fx_stroke(hi)
  end
end

-- ============================================================================
-- 6 · DELAY / REVERB — the time-smear, split into two stations. DELAY draws
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

-- SPACE is sends: an effect that is up while no track sends into it makes
-- no sound, and the page must say why
local SPC_DLY = { "fx_dly", "t2_fx_dly", "t3_fx_dly", "t4_fx_dly" }
local SPC_HINT = "NO SEND - TRACKS K1"
local function no_send(ids)
  for n = 1, 4 do if pget(ids[n], 0) > 0.005 then return false end end
  return true
end
local function body_DELAY(frame)
  local emix = pget("delay_mix", 0)
  if not spc_frame(emix > 0.005) then return end
  if no_send(SPC_DLY) then ptext_c(SPC_HINT, 64, 12, 1, 9) end
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

-- REVERB: FOUR SQUARES (doc/space-plan.md, 12.2). The room spreads a sound in
-- four steps, and each step turns every echo into eight. So the page draws
-- four squares around one point, each denser than the one inside it.
--   SIZE   is the size of the squares
--   DECAY  is how long a square glows after the sound reached it
--   DAMP   is the weight of the lines: a dark room draws them double
--   the four tracks stand at the four corners, and a line from a corner to
--   the squares is that track's send, as bright as it is open
-- A pulse leaves the centre only while a track that sends is sounding: the
-- picture moves when sound goes in, and rests when none does.
local RV_GAP = { 4, 3, 2, 1 }                  -- a dot every so many pixels, ring 1 to 4
local RV_CX, RV_CY = 64, 31
local RV_TX = { 5, 119, 5, 119 }               -- the tracks' corners
local RV_TY = { 13, 13, 45, 45 }
local RV_SEND = { "fx_rev", "t2_fx_rev", "t3_fx_rev", "t4_fx_rev" }
local RV_NAME = { "1", "2", "3", "4" }
local RV_PERIOD = 14                           -- frames from one pulse to the next
local function body_REVERB(frame)
  local vmix = pget("rev_mix", 0)
  local live = vmix > 0.005
  local size = clamp((pget("rev_size", 1) - 0.5) / 4.5, 0, 1)
  local r1 = 4 + size                            -- the squares: 4, 8, 12, 16 up to 5, 10, 15, 20
  local damp = pget("rev_damp", 0.3)
  local tau = max(pget("rev_decay", 2), 0.1) * FPS / 6.9     -- frames for one e-fold
  -- who feeds the room
  local feeding = false
  for n = 1, 4 do
    local v = pget(RV_SEND[n], 0)
    local on = live and v > 0.01 and track_sounds(n)
    if on then feeding = true end
    ptext(RV_NAME[n], RV_TX[n], RV_TY[n], 1, on and 12 or 3)
    if live and v > 0.01 then
      local r4 = floor(r1 * 4 + 0.5)
      local sx = RV_TX[n] < 64 and 1 or -1
      local sy = RV_TY[n] < 30 and 1 or -1
      screen.level(on and floor(3 + 9 * clamp(v, 0, 1)) or 2)
      screen.move(RV_TX[n] + (sx > 0 and 6 or -2), RV_TY[n] + (sy > 0 and 6 or -2))
      screen.line(RV_CX - sx * r4, RV_CY - sy * r4)
      screen.stroke()
    end
  end
  -- the four squares
  local p = frame % RV_PERIOD
  for k = 1, 4 do
    local r = floor(r1 * k + 0.5)
    local lv = live and 3 or 1
    if feeding then
      local age = (p - 2 * k) % RV_PERIOD          -- frames since the pulse reached this square
      lv = floor(3 + 12 * (0.25 + 0.75 * vmix) * exp(-age / tau) + 0.5)
    end
    screen.level(clamp(lv, 1, 15))
    local gap = RV_GAP[k]
    for d = -r, r - 1, gap do
      screen.rect(RV_CX + d, RV_CY - r, 1, 1)       -- top, left to right
      screen.rect(RV_CX + r, RV_CY + d, 1, 1)       -- right, down
      screen.rect(RV_CX - d, RV_CY + r, 1, 1)       -- bottom, right to left
      screen.rect(RV_CX - r, RV_CY - d, 1, 1)       -- left, up
    end
    if damp > 0.5 and r > 2 then                    -- a dark room: the lines are double
      for d = -r + 1, r - 2, gap do
        screen.rect(RV_CX + d, RV_CY - r + 1, 1, 1)
        screen.rect(RV_CX + r - 1, RV_CY + d, 1, 1)
        screen.rect(RV_CX - d, RV_CY + r - 1, 1, 1)
        screen.rect(RV_CX - r + 1, RV_CY - d, 1, 1)
      end
    end
    screen.fill()
  end
  if live and no_send(RV_SEND) then
    screen.level(0)
    screen.rect(24, 11, 80, 7)
    screen.fill()
    ptext_c(SPC_HINT, 64, 12, 1, 9)
  end
  -- the point the sound enters at
  screen.level(feeding and 15 or (live and 5 or 2))
  screen.rect(RV_CX - 1, RV_CY - 1, 2, 2)
  screen.fill()
  -- shimmer: motes that climb off the outer square
  local shim = pget("shimmer", 0)
  if live and shim > 0.01 then
    local r4 = floor(r1 * 4 + 0.5)
    local spd = 0.4 + value_norm("shimmer_pitch", pget("shimmer_pitch", 12)) * 1.4
    screen.level(7)
    for i = 1, 3 + floor(shim * 9) do
      local mx = RV_CX - r4 + hash(i, 3, 0) * 2 * r4
      local ph = (frame * spd + hash(i, 5, 0) * 100) % 8
      screen.rect(mx, RV_CY - r4 - 2 - ph, 1, 1)
    end
    screen.fill()
  end
end

-- ============================================================================
-- 8 · MIX — the console (in meter → the two decks at their REAL gains →
--     master VU). this console is the engine <> tape crossfade.
-- ============================================================================
-- one console meter: frame, the signal bar (sqrt law), and a peak pip that
-- decays slowly. `k` picks its peak slot; the pip decays once per frame.
local function vu(x, sig, k, newframe)
  screen.level(1)
  screen.rect(x - 1.5, 18.5, 8, 31)
  screen.stroke()
  if sig > 0.01 then
    screen.level(11)
    screen.rect(x, 48 - sig * 28, 5, sig * 28)
    screen.fill()
  end
  if newframe then vu_peak[k] = max(sig, vu_peak[k] - 0.0045) end
  if vu_peak[k] > 0.02 then
    screen.level(15)
    screen.rect(x, 48 - vu_peak[k] * 28 - 1, 5, 1)
    screen.fill()
  end
end

local function body_MIX(frame)
  -- each lane's energy is its deck's REAL gain: the ONE law itself
  -- (C.mix_gains — trim x crossfade plateau x master x STOP), not a mirror
  local mixv = pget("mix", 0.5)
  local eng_g, tape_g = C.mix_gains()
  local eng_on = pget("mode", 5) ~= 1 and eng_g > 0.001 and C.wave_any
  local tape_on = C.twave_any and tape_g > 0.001
  -- the tape lane shows what the TAPE page shows: the loop, not the 60s
  local ttd = C.tape_deck
  local tvlo, tvspan = deck_view(pget("loop_start", 0), pget("loop_end", 1),
    ttd and ttd.mat_lo, ttd and ttd.mat_hi, C.TAPE_LEN or 60)
  local newframe = C.frame ~= vu_last_frame
  -- input meter, left
  ptext("IN", 3, 12, 1, 5)
  vu(5, sqrt(clamp(max(amp_in[1], amp_in[2]), 0, 1)), 1, newframe)
  -- the engine deck lane (the real take, at the deck's real gain)
  ptext("ENG", 18, 13, 1, 5)
  if not eng_on then
    screen.level(1)
    screen.move(18, 23.5) screen.line(104, 23.5)
    screen.stroke()
  else
    screen.level(12)
    wave_lane(wave, 18, 104, 23.5, clamp(eng_g, 0, 1) * 5, 0.5, 5)
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
    screen.level(10)
    wave_lane(twave, 18, 104, 41.5, clamp(tape_g, 0, 1) * 4, 0.5, 4, tvlo, tvspan)
  end
  if C.twave_any then
    local hx = view_x(clamp(C.tape_phase, 0, 1), 18, 104, tvlo, tvspan)
    if hx then
      screen.level(tape_on and 15 or 4)
      screen.move(hx + 0.5, 38) screen.line(hx + 0.5, 45)
      screen.stroke()
    end
  end
  ptext("TAPE", 18, 47, 1, 5)
  -- master VU, right
  vu(114, sqrt(clamp(max(amp_out[1], amp_out[2]), 0, 1)), 2, newframe)
  if newframe then vu_last_frame = C.frame end
  ptext("OUT", 112, 12, 1, 5)
end

-- ============================================================================
-- 9 · PADS — the take chopped into 8 playable slices: the window zoomed full
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
  ptext(routed and "PLAY>PADS" or "PLAY>DRONE", 2, 12, 1, routed and 12 or 5)
  -- the SELECTED pad's sound-lock: voice + pitch (the cursor editor). e.g. SLC+5
  local cvi = clamp(floor(pget("seq_slice", 0) + 0.5), 0, 7)
  local cp = C.pad_pitch and (C.pad_pitch[cvi] or 0) or 0
  local lk = ((C.pad_type and C.pad_type[cvi] or 0) == 1 and "SLC" or "GRN")
    .. (cp ~= 0 and ((cp > 0 and "+" or "") .. cp) or "")
  ptext_c(lk, 72, 12, 1, 6)
  ptext_r(used .. "/" .. floor(pget("voices", 8) + 0.5) .. "V", 126, 12, 1, 5)
  if not C.wave_any and pget("rec", 0) == 0 then
    ptext_c("EMPTY - K2 REC", 64, 28, 1, 10)
    return
  end
  -- THE TAKE: the window zoomed full width, divided into 8 (a pad is
  -- self-evidently an eighth of what you recorded)
  local bx0, bx1, by = 4, 124, 22
  local sw = (bx1 - bx0) / 8
  local wlo, _, wspan = window_bounds()
  screen.level(8)
  wave_lane(wave, bx0, bx1, by, 4, 1, 4, wlo, wspan)
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
  -- the row below the slices is the sequencer's, at all times: its steps
  -- under the pads, the hits as bars, the rests as dots. Running, it is
  -- bright and the step the clock is on lights (a tall bar while its pad
  -- sounds, a bright dot on a rest); stopped, the pattern waits dim. A CHOP
  -- in force says so on the line below it: what the pads now mean.
  local seq = C.seq
  if seq then
    local run = pget("step_run", 0) == 1
    local n = floor(pget("step_len", 4) + 0.5)
    local sw2 = floor(112 / n)
    local x0 = 64 - floor(sw2 * n / 2)
    for s = 0, n - 1 do
      local x = x0 + s * sw2
      local now = run and s == seq.step
      if seq.hits[s + 1] then
        screen.level(now and 15 or (run and 6 or 3))
        if now then screen.rect(x + 1, 42, sw2 - 2, 5)
        else screen.rect(x + 1, 43, sw2 - 2, 3) end
      else
        screen.level(now and 15 or (run and 3 or 2))
        screen.rect(x + floor(sw2 / 2), 44, 1, 1)
      end
      screen.fill()
    end
  end
  if C.pad_cuts then
    local n = #C.pad_cuts - 1
    ptext_c(("CHOP - %d SLICES ON THE HITS"):format(n), 64, 49, 1, 5)
  end
end

-- ============================================================================
-- 10 · MOTION — the gesture loop (dynamic lanes: one automation CURVE per
--     recorded param, named with its page's own word; one playhead crosses
--     every lane with a live-value dot)
-- ============================================================================
-- MOTION's modulator rows (MOTION hosts the two LFOs): below the lanes, one
-- row each, selected by the same E2 walk. The name column says which one
-- and what it moves ("1>CUT", "2 OFF"); the row draws two cycles of its
-- wave, as tall as its depth (upside down for a negative depth), with a dot
-- where the wave is now. ENV draws the input's envelope as a bar. A
-- modulator that also goes out to other gear says where on the right (>CC
-- the MIDI CC, >CV crow, >OUT both). Dim and flat while it moves nothing.
local LFO_N = 4
local LFO_PID = {}
for k = 1, LFO_N do
  LFO_PID[k] = { target = "lfo" .. k .. "_target", depth = "lfo" .. k .. "_depth",
    shape = "lfo" .. k .. "_shape" }
end
local LFO_TAG = { "1>", "2>", "3>", "4>" }
local LFO_OFF = { "1 OFF", "2 OFF", "3 OFF", "4 OFF" }
local LFO_NONE = "--"   -- a target its track does not have
local LFO_GX1 = 110
local function lfo_row(k, yb, selected, gx0)
  local L = C.lfo
  if not L then return end
  local P = LFO_PID[k]
  local picked = L.TARGETS[floor(pget(P.target, 1) + 0.5) - 1]
  -- the knob it moves on its own track ("T2 CUT"): nil when that track has
  -- no such knob
  local tid = picked and L.target_of(k)
  local depth = pget(P.depth, 0)
  local live = tid ~= nil and abs(depth) >= 0.001
  local lvl = selected and 11 or (live and 7 or 4)
  if picked then
    local word = tid and (SHORT[tid] or "?") or LFO_NONE
    local x = 2 + text_w(LFO_TAG[k], 1) + 1
    ptext(LFO_TAG[k], 2, yb - 6, 1, lvl)
    ptext(word, x, yb - 6, 1, lvl)
    -- a long name ("T2 DENS") pushes the wave to the right of it
    gx0 = max(gx0, x + text_w(word, 1) + 3)
  else
    ptext(LFO_OFF[k], 2, yb - 6, 1, lvl)
  end
  -- does it also go out? The tag sits after the wave, and a wide one (>OUT)
  -- ends at 125 and pulls the wave's end back: from LFO_GX1 + 3 it ran two
  -- columns off the screen.
  local tag
  if floor(pget("out_src", 1) + 0.5) == k + 3 then
    local cc = pget("out_midi", 0) > 0
    local cv = pget("out_crow", 0) == 1
    if cc or cv then tag = cc and cv and ">OUT" or (cc and ">CC" or ">CV") end
  end
  local tx = tag and min(LFO_GX1 + 3, 126 - text_w(tag, 1)) or nil
  local w = (tx and min(LFO_GX1, tx - 3) or LFO_GX1) - gx0
  local mid = yb - 4
  local shape = floor(pget(P.shape, 1) + 0.5)
  local m = L.mods[k]
  if not live then
    screen.level(2)
    screen.rect(gx0, mid, w, 1)
    screen.fill()
  else
    local a = max(1, abs(depth) * 4)
    local sg = depth < 0 and -1 or 1
    screen.level(selected and 11 or 6)
    if shape == 6 then                        -- ENV: the envelope, as a bar
      screen.rect(gx0, mid, max(1, floor(L.env * w)), 1)
    else
      for x = 0, w do
        local ph = (x / w * 2) % 1
        local v = shape == 5 and (hash(floor(x / w * 6), k, 7) * 2 - 1)
          or L.wave(shape, ph)
        screen.rect(gx0 + x, floor(mid - v * a * sg + 0.5), 1, 1)
      end
    end
    screen.fill()
    -- where it is now
    local v = shape == 6 and (L.env * 2 - 1) or (m.out * 2 - 1)
    local dx = shape == 6 and gx0 + L.env * w or gx0 + m.phase * w / 2
    screen.level(15)
    screen.rect(floor(dx) - 1, floor(mid - v * a * sg + 0.5) - 1, 3, 3)
    screen.fill()
  end
  if tag then ptext(tag, tx, yb - 6, 1, 6) end
  if selected then
    screen.level(15)
    screen.move(0, yb - 8) screen.line(0, yb + 2)
    screen.stroke()
    screen.rect(1, yb - 8, 1, 1)
    screen.rect(1, yb + 2, 1, 1)
    screen.fill()
  end
end

local function body_MOTION(frame)
  local mo = C.motion
  local ll = mo.loop_len
  local ids = mo.lane_ids
  local nlane = #ids
  local armed = pget("motion_rec", 0) == 1
  local playing = pget("motion_play", 0) == 1
  local top, rh = 15, 10
  local gx0, gx1 = 33, 124
  -- the selection over every row: 0 none, 1..nlane the lanes, then the
  -- four modulators
  local focus = floor(pget("mod_focus", 1) + 0.5)
  local sel = focus > 1 and nlane + focus - 1
    or clamp(floor(pget("motion_lane", 0) + 0.5), 0, nlane)
  if nlane == 0 then
    -- no lanes: the invitation in one line, the four modulator rows below
    if armed then
      chip("REC", 2, 12)              -- steady: the header M is the blink
      ptext_c("MOVE A KNOB", 64, 12, 1, 8)
    else
      ptext_c("EMPTY - K2 ARM", 64, 12, 1, 10)
    end
    for k = 1, LFO_N do lfo_row(k, 26 + (k - 1) * 8, sel == k, gx0) end
    return
  end
  if ll > 0 then
    ptext_r(string.format("LOOP %.1fS", ll / FPS), 126, 9, 1, 5)
  end
  local nrow = nlane + LFO_N
  local VIS = 4
  local shown = min(nrow, VIS)
  -- scroll: the VIS-row window follows the selection so every row is
  -- reachable (a scrollbar on the right edge shows where in the stack you are)
  local off = 0
  if nrow > VIS then
    local fsel = sel > 0 and sel or 1
    off = clamp(fsel - VIS, 0, nrow - VIS)     -- keep the selected row visible:
    if fsel - 1 < off then off = fsel - 1 end  --   between the top and bottom row
  end
  -- the lane rows in the window (the rails, the playhead and the armed frame
  -- span these, not the modulators)
  local lshown = clamp(nlane - off, 0, shown)
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
  if lshown > 0 then
    screen.level(2)
    for k = 0, 4 do
      local x = gx0 + floor((gx1 - gx0) * k / 4)
      for y = top - 2, top + lshown * rh - 2, 2 do screen.rect(x, y, 1, 1) end
    end
    screen.fill()
  end
  local phx = gx0 + (clamp(mo.playhead, 0, dl) / dl) * (gx1 - gx0)
  for row = 1, shown do
    local li = off + row                  -- the row index this row shows
    if li > nlane then
      lfo_row(li - nlane, top + (row - 1) * rh + 8, li == sel, gx0)
      goto continue
    end
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
    local lp = lookup_p(id)               -- once per lane, not once per event
    if n > 0 then
      screen.level(selected and 11 or 7)
      local py = yb - pnorm(lp, L.v[1]) * 8
      screen.move(gx0, py)
      if n <= gx1 - gx0 then
        for e = 1, n do
          local ex = gx0 + (L.f[e] / el) * (gx1 - gx0)
          local ey = yb - pnorm(lp, L.v[e]) * 8
          screen.line(ex, py)
          screen.line(ex, ey)
          py = ey
        end
      else
        -- more events than pixel columns (a long continuous gesture: up to
        -- 900 a lane). Drawing each one sent thousands of segments a frame
        -- through the screen for the same pixels, so collapse each COLUMN to
        -- one vertical over the values the curve visits there.
        local col, ylo, yhi
        for e = 1, n do
          local c = floor(gx0 + (L.f[e] / el) * (gx1 - gx0))
          local ey = yb - pnorm(lp, L.v[e]) * 8
          if c ~= col then
            if col then
              screen.line(col, ylo); screen.line(col, yhi); screen.line(col, py)
            end
            screen.line(c, py)            -- the hold, up to this column
            col, ylo, yhi = c, min(py, ey), max(py, ey)
          else
            if ey < ylo then ylo = ey end
            if ey > yhi then yhi = ey end
          end
          py = ey
        end
        screen.line(col, ylo); screen.line(col, yhi); screen.line(col, py)
      end
      screen.line(gx1, py)
      screen.stroke()
    end
    -- the value sounding right now, where the playhead crosses
    if ll > 0 then
      local vy = yb - pnorm(lp, pget(id, 0)) * 8
      screen.level(15)
      screen.rect(phx - 1, vy - 1, 3, 3)
      screen.fill()
    end
    ::continue::
  end
  -- one playhead crosses every lane
  if lshown > 0 and ll > 0 then
    screen.level(playing and 10 or 3)
    screen.move(phx, top - 3)
    screen.line(phx, top + lshown * rh - 3)
    screen.stroke()
  elseif lshown > 0 and armed then
    screen.level(15)
    screen.move(gx1, top - 3)
    screen.line(gx1, top + lshown * rh - 3)
    screen.stroke()
  end
  if armed and lshown > 0 then           -- armed frame, steady (header M blinks)
    screen.level(15)
    screen.rect(gx0 - 2.5, top - 4.5, gx1 - gx0 + 6, lshown * rh + 5)
    screen.stroke()
  end
  -- scrollbar (right edge): the VIS-row window's place in the whole stack
  if nrow > VIS then
    local sy0, sy1 = top - 2, top + shown * rh - 3
    screen.level(2)
    screen.rect(127, sy0, 1, sy1 - sy0)
    screen.fill()
    local th0 = sy0 + (sy1 - sy0) * (off / nrow)
    local th1 = sy0 + (sy1 - sy0) * ((off + VIS) / nrow)
    screen.level(9)
    screen.rect(127, th0, 1, max(1, th1 - th0))
    screen.fill()
  end
end

-- ============================================================================
-- 11 · SCENE — states and the way back (the slot row + the morph rail; undo
--     is the ◄ cell, a slot you can see)
-- ============================================================================
-- SCENE slot cells: an empty cell is a dotted box; the selected cell is
-- bracketed one pixel OUTSIDE its edge on both sides, on the slot row (y 20
-- and 35)
local function dotted_box(x0, x1, y0, y1)
  for xx = x0, x1, 2 do
    screen.rect(xx, y0, 1, 1)
    screen.rect(xx, y1, 1, 1)
  end
  for yy = y0, y1, 2 do
    screen.rect(x0, yy, 1, 1)
    screen.rect(x1, yy, 1, 1)
  end
  screen.fill()
end
local function slot_brackets(x0, x1)
  screen.level(15)
  screen.rect(x0, 20, 4, 1)
  screen.rect(x1 - 3, 20, 4, 1)
  screen.rect(x0, 35, 4, 1)
  screen.rect(x1 - 3, 35, 4, 1)
  screen.rect(x0, 21, 1, 2)
  screen.rect(x1, 21, 1, 2)
  screen.rect(x0, 33, 1, 2)
  screen.rect(x1, 33, 1, 2)
  screen.fill()
end

local function body_SCENE(frame)
  local sc = C.scene
  local sel = clamp(floor(pget("scene_slot", 1) + 0.5), 0, 8)
  local sel_a = clamp(floor(pget("scene_slot_a", 0) + 0.5), 0, 8)
  local a_end = sc.a_end()             -- the A the fader starts from (0 = LIVE)
  local amt = pget("scene_morph_amt", 0)
  -- status row: the message line outranks the morph cue
  local msg_live = sc.msg ~= nil and (frame - sc.msg_at) < FPS * 1.2
  if msg_live then
    chip(sc.msg, 64 - floor((text_w(sc.msg, 1) + 5) / 2), 11)
  elseif amt >= 0.999 and sc.engaged and sc.unlanded(sel) then
    ptext_c("K2 TO LAND THE REST", 64, 13, 1, 5)
  else
    ptext_r(params:string("scene_recall_mode"), 126, 13, 1, 5)
  end
  -- the orbit lives here now (its knobs are this page's alt pair): a steady
  -- chip while the wander runs — the moving selector and rail are its motion
  if pget("orbit_on", 0) == 1 then
    chip("ORBIT", 2, 11)
  end
  -- the ◄ cell: the way back (the safe state, auto-marked by chaos)
  if sc.safe then
    screen.level(6)
    screen.rect(3, 22, 9, 12)
    screen.fill()
    ptext("<", 6, 25, 1, 0)
  else
    screen.level(2)
    dotted_box(3, 11, 22, 33)
    ptext("<", 6, 25, 1, 3)
  end
  if sel == 0 then slot_brackets(2, 12) end   -- the ◄ cell (x 3..11) is selected
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
    local pending = sc.pending == i
    local flash = msg_live and sc.msg_slot == i
    if filled or pending or flash then
      -- a queued recall is steady and between the two (one blink: the header)
      screen.level(flash and 15 or (pending and 11 or 7))
      screen.rect(x, 22, 12, 12)
      screen.fill()
    else
      screen.level(2)
      dotted_box(x, x + 11, 22, 33)
    end
    ptext_c(tostring(i), x + 6, 25, 1, (filled or pending or flash) and 0 or 4)
    if i == sel then slot_brackets(x - 1, x + 12) end   -- cursor brackets
    -- the A end, under its cell: bright while it is the fader's A, dim while
    -- it waits (an empty slot, the orbit or a K2 peek departs from LIVE, a
    -- fade still on the A it left from)
    if i == sel_a then ptext("A", x + 4, 36, 1, a_end == i and 12 or 4) end
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
      64, 44, 1, 5)
    return
  end
  -- the morph rail: from A (LIVE or a slot) toward B, the selected slot
  if nfilled == 0 then
    ptext_c("EMPTY - K3 CAP", 64, 44, 1, 10)
    return
  end
  if not sc.slots[sel] then
    ptext_c("SLOT " .. sel .. " EMPTY - K3 CAP", 64, 44, 1, 10)
    return
  end
  local live = amt > 0.001 and amt < 0.999
  -- both ends named, the nearer one the brighter (labels from SLOT_STR):
  -- "A LIVE ====*---- 4 B". The handle at either end keeps 3 px from the
  -- widest labels, A LIVE (x 4..28) and n B (x 112..123)
  ptext(SLOT_STR.a[a_end] or SLOT_STR.a[0], 4, 43, 1, amt < 0.5 and 11 or 4)
  ptext_r(SLOT_STR.b[sel], 124, 43, 1, amt >= 0.5 and 11 or 4)
  local x0, x1 = 34, 106
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
local BODY = {
  TAKE = body_TAKE, VOICE = body_VOICE, TAPE = body_TAPE,
  FILTER = body_FILTER, EFFECT = body_EFFECT, DELAY = body_DELAY, REVERB = body_REVERB, MIX = body_MIX,
  PADS = body_PADS, MOTION = body_MOTION, SCENE = body_SCENE,
  TRACKS = body_TRACKS,
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
  -- track 2 is a second engine source: switched on and audible, the output
  -- is not the take alone
  -- (and tracks 3 and 4; and a send moves sound between tracks even when
  -- the receiving track's own voice is off)
  for n = 2, 4 do
    if track_live(n) then return false end
  end
  if C.ROUTES then
    for _, r in ipairs(C.ROUTES) do
      -- a send between tracks moves sound; the FX sends only scale what
      -- the delay and reverb mixes (checked below) let through
      if not r.fx and pget(r.id, 0) > 0.001 then return false end
    end
  end
  if abs(pget("pitch", 1) - 1) > 0.001 then return false end
  if abs(pget("scan", 1) - 1) > 0.001 then return false end
  -- pan reaches the PLAY voice's Balance2: off-center output is not the
  -- recording, however clean the rest of the path is
  if abs(pget("pan", 0)) > 0.001 then return false end
  -- an effect in track 1's slot (the other tracks' are covered by track_live)
  if pget("effect", 1) ~= 1 then return false end
  if pget("drive", 0) > 0.001 or pget("crush", 0) > 0.001 or pget("delay_mix", 0) > 0.001
      or pget("rev_mix", 0) > 0.001 or pget("shimmer", 0) > 0.001
      or pget("clouds_fb", 0) > 0.001 or pget("resample", 0) > 0.001
      or pget("regen", 0) > 0.001
      -- erode belongs with the other buffer writers: the mark would otherwise
      -- claim "verbatim" at exactly the moment the erosion head is grinding
      -- the take away underneath it
      or pget("erode", 0) > 0.001 then return false end
  if pget("freeze", 0) == 1 or pget("pv_freeze", 0) == 1 then return false end
  -- a pad voice sounds on top of the take, and so does the sequencer that
  -- plays them (between its hits too: the voices release with a tail)
  if next(C.pad_held) ~= nil or pget("step_run", 0) == 1 then return false end
  -- a held beat repeat plays a captured slice, not the take
  if C.repeat_live and C.repeat_live() then return false end
  -- a modulator moving a knob: even at a zero crossing it is not the take
  if C.lfo and C.lfo.active() then return false end
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
  return true
end

-- header: [1][2][3][4] TITLE ◇ flags ···· path dots. The four cells on
-- the left are the TRACKS (see draw_tracks); STOP inverts the title chip.
-- A writer's dot carries the ONLY fast blink (its letter stays, so a flag
-- never vanishes); holds and runs are steady. The flags, in priority order:
-- the writers (T the tape, M the motion looper; the take's
-- REC is the blinking track cell), the holds (FZ, TF, RP a beat repeat),
-- then the machines that play on their own (SQ the pad sequencer, LF a
-- modulator). A flag that does not fit whole shrinks: a writer to its
-- blinking letter without the dot, the others to a 2px bar. Room is kept for
-- the short forms of the lit flags after it, so a lit state never drops off
-- the header. Built once: draw_header refreshes `on` (and RP's `lvl`), and
-- leaves `x` and `full` for the tests.
local HFLAGS = {
  { ch = "T", write = true },
  { ch = "M", write = true },
  { ch = "FZ", lvl = 10 }, { ch = "TF", lvl = 10 }, { ch = "RP", lvl = 12 },
  { ch = "SQ", lvl = 7 }, { ch = "LF", lvl = 7 },
}
M.HFLAGS = HFLAGS
local HF = {}
for _, f in ipairs(HFLAGS) do
  f.id = f.ch                                      -- ch can change (RP8)
  HF[f.id] = f
  f.w, f.on, f.x, f.full = 0, false, nil, false   -- w: set in init
end
-- RP carries the division it repeats: RP2 for a half note .. RP32. Built
-- once, indexed like the repeat_div option, widths measured in init.
local RP_CH = { "RP2", "RP4", "RP8", "RP16", "RP32" }
local RP_W = {}
-- the width of a flag whole, and short (a writer's letter, or a bar)
local function hflag_w(f) return f.write and f.w + 8 or f.w + 3 end
-- (a bar's pip is 3: the 2px bar and a 1px gap, and a writer's letter keeps
-- a 1px gap too. They were 4 and 2, but four's thirteen page dots and its
-- track flag left the worst case short of the dots.)
local function hflag_pip(f) return f.write and f.w + 1 or 3 end
-- draw the lit flags from x, keeping clear of `lim` (the page dots)
local function draw_hflags(x, lim, blink)
  local n = #HFLAGS
  for i = 1, n do
    local f = HFLAGS[i]
    f.x, f.full = nil, false
    if f.on then
      local rest = 0
      for j = i + 1, n do
        if HFLAGS[j].on then rest = rest + hflag_pip(HFLAGS[j]) end
      end
      f.x = x
      f.full = x + hflag_w(f) - 3 + rest <= lim
      if f.write then
        -- the letter stays; the dot before it is the blink
        if f.full then
          if blink then
            screen.level(15)
            screen.rect(x, 1, 3, 3)
            screen.fill()
          end
          ptext(f.ch, x + 5, 1, 1, 15)
        else
          ptext(f.ch, x, 1, 1, blink and 15 or 6)
        end
      elseif f.full then
        ptext(f.ch, x, 1, 1, f.lvl)
      else
        screen.level(f.lvl)
        screen.rect(x, 1, 2, 5)      -- a bar at cap height, not a page dot
        screen.fill()
      end
      x = x + (f.full and hflag_w(f) or hflag_pip(f))
    end
  end
end
-- path dots, top-right. Every page has a fixed slot on one straight row: all
-- dots share rows y=4..5 and a 3px pitch, and no dot ever moves when the page
-- changes. The current page is the one BRIGHT dot (four: the track cells took
-- the room the 4px pitch and the wider bar had). The row is RIGHT-ANCHORED
-- whatever the page count (a fixed left origin cropped the last dot once the
-- count reached twelve). Laid out once, in init.
local DOT_PITCH = 3
local DOT_OFF = {}
local function layout_dots()
  for i = 1, #PAGES do DOT_OFF[i] = (i - 1) * DOT_PITCH end
  -- the last dot ends 1px clear of the edge (it was 2px until the EFFECT
  -- page made thirteen dots: the worst case of flags then met the row)
  M.DOT_X0 = 127 - ((DOT_OFF[#PAGES] or 0) + 2)
end
-- the page's name, with its track on VOICE and FILTER while track 2 is
-- selected (four). Fixed strings: the redraw path allocates nothing.
-- (four) THE TRACKS, always on the left of the header: four cells, 1 to 4,
-- one rule each, so nothing needs a legend:
--   a WHITE BOX is the track this page edits (TAKE, VOICE, FILTER and
--     TRACKS belong to the focused track; on the shared pages, DELAY,
--     REVERB ..., the focus is only underlined: those pages edit no track)
--   a BRIGHT number sounds, a DIM one is silent (OFF, level 0, or STOP)
--   a BLINKING box is the track being RECORDED: a solid block, then a frame
--     with its number. Neither phase looks like any other cell.
-- It replaces the badge and the old T2 / T23 / T234 flag.
local TRACK_PAGE = { TAKE = true, VOICE = true, FILTER = true, EFFECT = true, TRACKS = true }
local BADGE = { "1", "2", "3", "4" }
local CELL_W = 6
M.TRACKS_W = 4 * CELL_W   -- the strip's width; the title starts after it
local function page_title()
  return PAGES[C.page]
end
-- a cell's outline (four 1px fills: a stroke's corners land half a pixel off)
local function cell_frame(x)
  screen.rect(x, 0, CELL_W, 1)
  screen.rect(x, 7, CELL_W, 1)
  screen.rect(x, 0, 1, 8)
  screen.rect(x + CELL_W - 1, 0, 1, 8)
end
-- M.CELL[n] = how cell n was drawn last ("box", "rec", "line", "lit",
-- "dim"), for the tests
M.CELL = {}
local function draw_tracks(blink, own)
  local focus = cur_track()
  local audible = (C.mix_gains()) > 0.001 and pget("stop_all", 0) ~= 1
  local recording = pget("rec", 0) == 1 and pget("freeze", 0) == 0
  for n = 1, 4 do
    local x = (n - 1) * CELL_W
    local sounds = audible and track_sounds(n)
    if recording and n == focus then
      -- REC: the box blinks, and between blinks its frame stays. The lit phase
      -- is a solid block with no number: with the number it was the white
      -- box of the focus, so on TAKE, VOICE, FILTER, EFFECT and TRACKS half
      -- the blink looked like no recording at all. Each phase now reads REC
      -- in a still frame, and the number shows in the other one.
      screen.level(15)
      if blink then
        screen.rect(x, 0, CELL_W, 8)
        screen.fill()
      else
        cell_frame(x)
        screen.fill()
        ptext(BADGE[n], x + 1, 1, 1, 15)
      end
      M.CELL[n] = "rec"
    elseif n == focus and own then
      screen.level(15)
      screen.rect(x, 0, CELL_W, 8)
      screen.fill()
      ptext(BADGE[n], x + 1, 1, 1, 0)
      M.CELL[n] = "box"
    elseif n == focus then
      ptext(BADGE[n], x + 1, 1, 1, sounds and 15 or 5)
      screen.level(15)
      screen.rect(x + 1, 7, CELL_W - 2, 1)
      screen.fill()
      M.CELL[n] = "line"
    else
      ptext(BADGE[n], x + 1, 1, 1, sounds and 13 or 3)
      M.CELL[n] = sounds and "lit" or "dim"
    end
  end
end
M.page_title = page_title

local function draw_header()
  local page, frame = C.page, C.frame
  local title = page_title()
  local x
  local blink = (frame % 4) < 2
  draw_tracks(blink, TRACK_PAGE[PAGES[page]])
  local x0 = M.TRACKS_W + 3
  if pget("stop_all", 0) == 1 then
    screen.level(15)
    screen.rect(x0 - 2, 0, text_w(title, 1) + 5, 8)
    screen.fill()
    ptext(title, x0, 2, 1, 0)
    x = x0 - 2 + text_w(title, 1) + 9
  else
    ptext(title, x0, 1, 1, 8)
    x = x0 + text_w(title, 1) + 3
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
  local dx0 = M.DOT_X0
  HF.T.on = pget("tape_rec", 0) == 1
  HF.M.on = pget("motion_rec", 0) == 1
  -- FZ: the take's freeze, or ANY track's voice freeze. It read track 1's
  -- alone, so a frozen track 3 held its sound with no flag on any page.
  HF.FZ.on = pget("pv_freeze", 0) == 1 or pget("freeze", 0) == 1
    or pget(TK[2].pv_freeze, 0) == 1 or pget(TK[3].pv_freeze, 0) == 1
    or pget(TK[4].pv_freeze, 0) == 1
  HF.TF.on = pget("tape_freeze", 0) == 1
  -- RP bright while the engine loops, dim while a press waits for its beat
  HF.RP.on = pget("beat_repeat", 0) == 1
  HF.RP.lvl = (C.repeat_live and C.repeat_live()) and 12 or 4
  local rd = clamp(floor(pget("repeat_div", 3) + 0.5), 1, #RP_CH)
  HF.RP.ch, HF.RP.w = RP_CH[rd], RP_W[rd]
  HF.SQ.on = pget("step_run", 0) == 1
  HF.LF.on = C.lfo and C.lfo.active() or false
  draw_hflags(x, dx0 - 2, blink)
  for i = 1, #PAGES do
    local dx = dx0 + DOT_OFF[i]
    screen.level(i == page and 15 or 2)
    screen.rect(dx, 4, 2, 2)
    screen.fill()
  end
end

-- idle dim: after two minutes without a key or encoder touch every level is
-- cut to keep the OLED from burning the static chrome in; the first touch
-- restores full brightness. one closure, made once.
local orig_level, dim_level
-- the page-name pop: E1 arms C.page_flash while stations scroll past, and the
-- destination's name reads BIG and centered for a beat. Eleven pages go by
-- faster than the 1x title reads, and finding the page mid-set should not
-- need squinting. Same framed-box idiom as the footer value swell, so it is
-- legible over any body; transient chrome, gone by itself.
-- the pop on a track page names the track first: "2 VOICE" (not on TRACKS,
-- where "2 TRACKS" read as a count)
local FLASH_N = {}
for _, p in ipairs({ "TAKE", "VOICE", "FILTER", "EFFECT" }) do
  FLASH_N[p] = {}
  for n = 1, 4 do FLASH_N[p][n] = n .. " " .. p end
end
local function draw_page_flash()
  if not (C.page_flash and C.frame < C.page_flash) then return end
  local name = page_title()
  if FLASH_N[name] then name = FLASH_N[name][cur_track()] end
  framed2x(name, floor(64 - (text_w(name, 2) + 9) / 2 + 0.5), 23)
end

-- THE OPENING: a second and a half, once, when the script starts. Four bars
-- rise one after the other (the four tracks) and the name lands on them. Any
-- key or knob ends it at once.
local SPLASH_FRAMES = 24
local function draw_splash(t)
  local fade = t > 18 and (SPLASH_FRAMES - t) / 6 or 1      -- out over the last frames
  local function lv(l) return max(1, floor(l * fade + 0.5)) end
  -- the four bars, each rising for five frames, two frames apart
  for k = 0, 3 do
    local g = clamp((t - k * 2) / 5, 0, 1)
    if g > 0 then
      local h = floor(22 * g * (2 - g) + 0.5)                -- ease out
      screen.level(lv(t < 12 and 12 or 3))
      screen.rect(37 + k * 14, 36 - h, 10, h)
      screen.fill()
    end
  end
  if t >= 11 then
    -- the name, cut out of the bars' place and brightening
    local b = clamp((t - 11) / 4, 0, 1)
    local w = text_w("FOUR", 3)
    screen.level(0)
    screen.rect(64 - w / 2 - 2, 17, w + 4, 19)
    screen.fill()
    ptext_c("FOUR", 64, 19, 3, lv(4 + floor(11 * b)))
  end
end

function M.redraw()
  if C.splash_from then
    local t = C.frame - C.splash_from
    if t >= SPLASH_FRAMES or t < 0 or C.last_input > C.splash_from then
      C.splash_from = nil
    else
      screen.clear()
      draw_splash(t)
      screen.update()
      return
    end
  end
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
  draw_page_flash()
  screen.update()
  screen.level = orig_level
end

function M.init(ctx)
  C = ctx
  W = ctx.wav
  pget, clamp, window_bounds = ctx.pget, ctx.clamp, ctx.window_bounds
  FPS, PAGES = ctx.FPS, ctx.PAGES
  amp_in, amp_out = ctx.amp_in, ctx.amp_out
  local F = ctx.font
  ptext, ptext_c, ptext_r, chip, text_w =
    F.ptext, F.ptext_c, F.ptext_r, F.chip, F.text_w
  for _, f in ipairs(HFLAGS) do f.w = text_w(f.ch, 1) end
  for i, ch in ipairs(RP_CH) do RP_W[i] = text_w(ch, 1) end
  layout_dots()
end

return M
