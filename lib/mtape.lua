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

-- THE gain law: `mix` crossfades SC engine <-> tape (a plateau — center keeps
-- both at full trim), out_level masters both, stop_all chokes both. returns
-- eng_gain, tape_gain, master_out. update_mix sends it and the MIX page draws
-- it, so the picture reads from the one law instead of mirroring it.
function M.gains()
  local mixv = pget("mix", 0.5)
  local out = pget("out_level", 1) * (1 - pget("stop_all", 0))
  return pget("sc_level", 1) * math.min(1, 2 * (1 - mixv)) * out,
    pget("cut_level", 1) * math.min(1, 2 * mixv) * out,
    out
end

-- levels slew, so stop/start are click-free and START restores the exact mix
function M.update_mix()
  local sc_l, tp_l = M.gains()
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
  -- the 100ms floor, held inside the tape's own 0-60s (same rule as the layer
  -- decks): floored past the end it would loop buffer the tape does not own
  if hi - lo < 0.1 then
    hi = math.min(lo + 0.1, TAPE_LEN)
    lo = hi - 0.1
  end
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

-- REGION-scoped, not the whole buffer. sc.buffer_clear() takes every voice's
-- audio with it, so once the layer decks share this buffer a TAPE erase would
-- silently wipe them too.
function M.clear_buffer()
  sc.buffer_clear_region(0, TAPE_LEN)
end

-- the tape's RECORD SOURCE (cut_source): 0 = DRY (the
-- raw ADC tap) .. 1 = WET (the engine's post-FX output — filter/drive/delay/
-- reverb). the two router sends SUM at the shared softcut input, so a blend
-- prints part raw + part processed and the tape becomes a resample / print
-- stage. NO runaway: the engine reads only the ADC bus (context.in_b), never
-- softcut, so eng -> cut is a one-way edge. default 0 = the classic parallel
-- tap, so the tape behaves exactly as before until you reach for this.
function M.set_source(v)
  audio.level_adc_cut(1 - v)   -- dry input tap
  audio.level_eng_cut(v)       -- processed engine output
end

function M.init_tape()
  M.set_source(pget("cut_source", 0))   -- dry/processed record source (was 1/0)
  audio.level_cut(1)       -- softcut master out: persists across scripts, force up
  sc.buffer_clear_region(0, TAPE_LEN)
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
  -- ONE softcut phase handler exists, and it lives here. Anything that is not
  -- the tape's own voice is forwarded, so the layer decks can drive their own
  -- playheads and waveforms off the same poll.
  sc.event_phase(function(v, pos)
    if v == 1 then C.tape_phase = pos / TAPE_LEN
    elseif C.deck_phase then C.deck_phase(v, pos) end
  end)
  sc.poll_start_phase()
end

-- PSETs persist the tape audio too: SAVE writes the softcut buffers
-- (L=buf1, R=buf2, matching init_tape's routing) next to the pset; LOAD
-- reads them back, DELETE cleans up.
local function path_for(number)
  return norns.state.data .. "tape-" .. number .. ".wav"
end

function M.pset_write(number)
  -- like the take (take_pset_write): an untouched tape must not dump 60s of
  -- stereo silence per save, and a cleared one must not resurrect old audio
  -- on load — an empty save deletes the stale wav instead.
  if C.twave_any then
    sc.buffer_write_stereo(path_for(number), 0, TAPE_LEN)
  else
    M.pset_delete(number)
  end
end

function M.pset_read(number)
  local path = path_for(number)
  if util.file_exists(path) then
    sc.buffer_read_stereo(path, 0, 0, TAPE_LEN)
    C.twave_any = true
    -- repaint the strip from the wav we just restored: lua cannot read the
    -- softcut buffer, so without this the loop played under a blank picture
    if C.repaint_twave then C.repaint_twave(path, TAPE_LEN) end
  else
    -- NO wav means the pset was saved with an EMPTY tape (pset_write deletes
    -- the file in that case, precisely so old audio cannot resurrect). Leaving
    -- the softcut buffer alone let it resurrect anyway — from the live buffer
    -- instead of from disk, which is the same failure by another route. An
    -- empty tape in the pset means an empty tape after loading it.
    M.clear_buffer()
    if C.clear_twave then C.clear_twave() end   -- wipes the picture + twave_any
  end
end

function M.pset_delete(number)
  os.remove(path_for(number))
end

function M.cleanup()
  sc.poll_stop_phase()
  audio.level_eng_cut(0)   -- don't leak a processed-source route to the next script
  audio.level_adc_cut(1)   -- ...and give the next script the stock ADC tap back
end

return M
