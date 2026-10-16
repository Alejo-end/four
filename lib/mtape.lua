-- mtape: every softcut touch — the TAPE path's plumbing, the eng<>tape mix,
-- and the tape audio halves of PSET save/load/delete.

local sc = require "softcut"  -- the TAPE path: parallel ADC tap, own CPU core

local TAPE_LEN = 60  -- seconds of softcut buffer used by the tape loop

local C     -- shared ctx, bound at init
local pget
local D     -- the deck module (lib/mdeck), handed in at init — `include` has
            -- no module cache, so including it here would build a SECOND
            -- instance with its own deck list and the phase/pset walks would
            -- split across the two

-- the tape as a DECK DESCRIPTOR: the shape mdeck builds, but NOT registered
-- in Mdeck.decks — its level law (the MIX crossfade in gains()), its pset
-- files, its phase events and its lifecycle stay this module's own. What it
-- borrows is the deck MECHANICS: rate and direction, rec/pre/freeze gating,
-- the loop bounds with the 100ms floor held inside the region, and the
-- region-scoped clear. Those laws existed twice, verbatim, and had already
-- drifted once before the layers review caught it; now they exist once.
local TAPE = {
  id = "tape", name = "TAPE", va = 1, vb = 2, from = 0, len = TAPE_LEN,
  pre_default = 0,   -- classic tape: REPLACE unless tape_pre is raised
  keymap = { rec = "tape_rec", rate = "tape_rate", reverse = "tape_reverse",
             pre = "tape_pre", freeze = "tape_freeze", fade = "tape_fade",
             start = "loop_start", ["end"] = "loop_end" },
  -- display fields, unused here (the tape picture lives in mpages as twave)
  wave = {}, wave_bin = 0, any = false, phase = 0, gen = 0,
}

-- the descriptor is exported for the parts of the deck law that READ a deck
-- (its material extent); everything that writes goes through the functions
-- below
local M = { TAPE_LEN = TAPE_LEN, deck = TAPE }

function M.init(ctx, deckmod)
  C = ctx
  pget = ctx.pget
  D = deckmod
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

-- the deck mechanics, delegated (see the TAPE descriptor above). When they
-- were folded in, the softcut command stream over a state matrix (rates,
-- reverse, rec x freeze x pre, five loop shapes, clear) was captured before
-- and after and byte-diffed empty. The seam has gone through the same law
-- since: one fade writer, capped at a quarter of the loop.
--
-- What is NOT shared, and why. Volume, preset files, playhead position and
-- drawing stay here, because they really are the tape's own.
--
-- The loop-pedal behaviour is a different matter. mdeck has a version of it
-- (arm_loop / close_loop) and the tape has its own, written out by hand in
-- the tape_rec action in mangler.lua. That IS a duplicate, left in place on
-- purpose: the tape is one of the few parts of this instrument confirmed
-- working on real hardware, and merging it would also mean keeping
-- TAPE.phase up to date, which nothing does today. It waits for the same
-- device session as the rest of the merge.
--
-- The two now agree that stopping a recording may only re-cut the loop if
-- starting it opened one, that a pass too short to be a loop gives back the
-- loop it widened, that a PSET load forgets an open pass, and both move their
-- edges through D.set_loop. Three things still differ:
--   * the shortest recording the tape accepts is measured against the whole
--     tape; mdeck measures 100ms against the deck's own region
--   * mdeck checks which way the playhead was moving, so a deck playing
--     backwards closes its loop correctly. The tape does not.
--   * only mdeck offers the finished loop to SNAP.
-- If you change one of them, change both.
function M.update_tape_rate() D.update_rate(TAPE) end
function M.update_tape_rec() D.update_rec(TAPE) end
function M.update_tape_loop() D.update_loop(TAPE) end
-- Move both loop edges, in whichever order avoids leaving the start past the
-- end in between. See D.set_loop: getting it backwards makes the playhead jump.
function M.set_loop(lo, hi) D.set_loop(TAPE, lo, hi) end

-- Put both playheads at a position given as 0 to 1 across the tape. Stopping
-- a recording uses this to drop the head at the start of what was just
-- played, so it loops back straight away. Shared with the layer decks: two
-- copies of "put the head here" is how the loop maths drifted apart before.
function M.jump_to(pos) D.jump(TAPE, pos) end

-- the seam, through the deck law: capped at a quarter of the loop, so a long
-- fade on a short loop cannot leave the tape spending all its time fading
-- (a raw write here bypassed the cap the loop updates apply)
function M.set_fade() D.update_fade(TAPE) end

-- REGION-scoped, not the whole buffer. sc.buffer_clear() takes every voice's
-- audio with it, so once the layer decks share this buffer a TAPE erase would
-- silently wipe them too. (Mdeck.clear also resets the descriptor's unused
-- display fields — harmless; the tape picture is mpages' twave.)
function M.clear_buffer()
  D.clear(TAPE)
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
  M.update_tape_loop()     -- also sends the (capped) seam
  M.update_mix()
  -- tape head position events drive the TAPE page needle AND the loop
  -- snap points — 25ms quant keeps snapped loops tight (0.1 was audible)
  sc.phase_quant(1, 0.025)
  -- ONE softcut phase handler exists, and it lives here. Anything that is not
  -- the tape's own voice is forwarded, so the layer decks can drive their own
  -- playheads and waveforms off the same poll.
  sc.event_phase(function(v, pos)
    if v == 1 then
      C.tape_phase = pos / TAPE_LEN
      -- the written stretch, from the same 25ms events the layers use
      if pget("tape_rec", 0) == 1 and pget("tape_freeze", 0) == 0 then
        D.track_extent(TAPE, C.tape_phase)
      end
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
    sc.buffer_write_stereo(path_for(number), 0, D.save_secs(TAPE))
  else
    M.pset_delete(number)
  end
end

function M.pset_read(number)
  local path = path_for(number)
  if util.file_exists(path) then
    sc.buffer_clear_region(0, TAPE_LEN)   -- the save may hold only the start
    sc.buffer_read_stereo(path, 0, 0, TAPE_LEN)
    C.twave_any = true
    D.restored_extent(TAPE, path)
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
