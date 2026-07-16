-- mtape: every softcut touch — the TAPE path's plumbing, the eng<>tape mix,
-- and the tape audio halves of PSET save/load/delete.

local sc = require "softcut"  -- the TAPE path: parallel ADC tap, own CPU core

local TAPE_LEN = 60  -- seconds of softcut buffer used by the tape loop

local C     -- shared ctx, bound at init
local pget

local M = { TAPE_LEN = TAPE_LEN }

function M.init(ctx)
  C = ctx
  pget = ctx.pget
end

-- MIX page: `mix` crossfades SC engine <-> tape, out_level masters
-- both, each side keeps its own trim. center keeps both at full trim.
function M.update_mix()
  local mixv = pget("mix", 0.5)
  -- stop_all (the master STOP) chokes both decks right here; levels slew,
  -- so stop/start are click-free and START restores the exact mix
  local out = pget("out_level", 1) * (1 - pget("stop_all", 0))
  local sc_l = pget("sc_level", 1) * math.min(1, 2 * (1 - mixv)) * out
  local tp_l = pget("cut_level", 1) * math.min(1, 2 * mixv) * out
  if engine.level then engine.level(sc_l) end
  sc.level(1, tp_l)
  sc.level(2, tp_l)
end

-- apply identical settings to both tape voices (1 = L, 2 = R)
local function tape_set(fn)
  fn(1)
  fn(2)
end

function M.update_tape_rate()
  local r = pget("tape_rate", 1) * (pget("tape_reverse", 0) == 1 and -1 or 1)
  tape_set(function(v) sc.rate(v, r) end)
end

-- rec/freeze/pre interact: freeze stops capture and holds the loop at full
-- regeneration; otherwise rec gates capture and tape_pre sets the overdub
function M.update_tape_rec()
  local frozen = pget("tape_freeze", 0) == 1
  local rec_on = pget("tape_rec", 0) == 1 and not frozen
  tape_set(function(v)
    sc.rec_level(v, rec_on and 1 or 0)
    sc.pre_level(v, frozen and 1 or pget("tape_pre", 0))
    sc.rec(v, rec_on and 1 or 0)
  end)
end

function M.update_tape_loop()
  local a = pget("loop_start", 0) * TAPE_LEN
  local b = pget("loop_end", 1) * TAPE_LEN
  local lo, hi = math.min(a, b), math.max(a, b)
  if hi - lo < 0.1 then hi = lo + 0.1 end
  tape_set(function(v)
    sc.loop_start(v, lo)
    sc.loop_end(v, hi)
  end)
end

-- jump both heads to a normalized tape position (loop-snap lands the head
-- at the take's start so it plays back tight immediately)
function M.jump_to(pos)
  tape_set(function(v) sc.position(v, pos * TAPE_LEN) end)
end

function M.set_fade(v)
  tape_set(function(vc) sc.fade_time(vc, v) end)
end

function M.clear_buffer()
  sc.buffer_clear()
end

function M.init_tape()
  audio.level_adc_cut(1)   -- parallel ADC tap into softcut
  audio.level_eng_cut(0)   -- engine does NOT feed softcut (resample is SC-side)
  audio.level_cut(1)       -- softcut master out: persists across scripts, force up
  sc.buffer_clear()
  for v = 1, 2 do
    sc.enable(v, 1)
    sc.buffer(v, v)
    sc.pan(v, v == 1 and -1 or 1)
    sc.play(v, 1)
    sc.loop(v, 1)
    sc.position(v, 0)
    sc.fade_time(v, pget("tape_fade", 0.05))
    sc.level_slew_time(v, 0.05)
    sc.rate_slew_time(v, 0.05)
    -- force the filter sections fully open: their defaults can mute the voice
    sc.pre_filter_dry(v, 1.0)
    sc.pre_filter_lp(v, 0.0)
    sc.post_filter_dry(v, 1.0)
    sc.post_filter_lp(v, 0.0)
    for ch = 1, 2 do
      sc.level_input_cut(ch, v, (ch == v) and 1.0 or 0.0)
    end
  end
  M.update_tape_rate()
  M.update_tape_rec()
  M.update_tape_loop()
  M.update_mix()
  -- tape head position events drive the TAPE page needle AND the loop
  -- snap points — 25ms quant keeps snapped loops tight (0.1 was audible)
  sc.phase_quant(1, 0.025)
  sc.event_phase(function(v, pos)
    if v == 1 then C.tape_phase = pos / TAPE_LEN end
  end)
  sc.poll_start_phase()
end

-- PSETs persist the tape audio too: SAVE writes the softcut buffers
-- (L=buf1, R=buf2, matching init_tape's routing) next to the pset; LOAD
-- reads them back, DELETE cleans up.
function M.pset_write(number)
  sc.buffer_write_stereo(norns.state.data .. "tape-" .. number .. ".wav",
    0, TAPE_LEN)
end

function M.pset_read(number)
  local path = norns.state.data .. "tape-" .. number .. ".wav"
  if util.file_exists(path) then
    sc.buffer_read_stereo(path, 0, 0, TAPE_LEN)
    C.twave_any = true
  end
end

function M.pset_delete(number)
  os.remove(norns.state.data .. "tape-" .. number .. ".wav")
end

function M.cleanup()
  sc.poll_stop_phase()
end

return M
