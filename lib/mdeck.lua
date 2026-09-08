-- mdeck: a loop deck on a softcut voice pair.
--
-- One of these is a track: its own slice of the softcut buffer, its own loop
-- points, rate, direction and overdub. Several run at once for almost nothing,
-- because softcut is a separate audio core — which is exactly why the layers
-- live here and not as more scsynth drones (one drone at a time was a CPU
-- decision, not an oversight).
--
-- What a deck CANNOT do is granulate, warp or spectrally stretch. That is the
-- engine's buffer and the engine's voice. A deck is a loop.
--
-- lib/mtape.lua is the same shape and predates this. It is deliberately NOT
-- rewritten on top of this module yet: it is one of the few paths confirmed on
-- hardware, and nothing since 2026-07-16 has been. Folding it in is a named
-- follow-up, gated on the device pass. See doc/layers.md.

local sc = require "softcut"

local C, pget, clamp

local M = {}

-- every deck built, in creation order, so the shared plumbing (the phase
-- dispatcher, the master level, cleanup) can walk them
M.decks = {}

-- ---------------------------------------------------------------------------
-- construction
-- ---------------------------------------------------------------------------
-- `o` = { id, name, va, vb, from, len }
--   id       param prefix, e.g. "lay1" -> lay1_rec, lay1_level, ...
--   va, vb   the softcut voice pair (lower = left, upper = right)
--   from     where this deck's region starts, in seconds into the buffer
--   len      how long the region is, in seconds
-- One more field exists only while a recording is in progress: `arm_phase`,
-- where the playhead was when recording started. Its absence is what means
-- "nothing is being recorded", which is what close_loop checks, so it is
-- deliberately not set up here.
function M.new(o)
  local d = {
    id = o.id, name = o.name,
    va = o.va, vb = o.vb,
    from = o.from, len = o.len,
    phase = 0,          -- 0..1 within the region, from the softcut poll
    any = false,        -- has audio been recorded into it?
    wave = {},          -- 128-bin picture, painted as the head passes
    wave_bin = 0,
  }
  for i = 1, 128 do d.wave[i] = 0 end
  M.decks[#M.decks + 1] = d
  return d
end

-- a param id for this deck: p(d, "rec") -> "lay1_rec". A deck may carry a
-- `keymap` overriding the scheme — the TAPE deck's ids predate the layN_
-- naming (loop_start, tape_pre, ...) and ids are never renamed, so the map
-- is how it borrows these mechanics without touching its params.
local function p(d, k)
  local km = d.keymap
  return (km and km[k]) or (d.id .. "_" .. k)
end
M.p = p

local function get(d, k, dflt) return pget(p(d, k), dflt) end

-- both voices, same setting (the deck is stereo: lower = L, upper = R)
local function both(d, fn) fn(d.va); fn(d.vb) end

-- ---------------------------------------------------------------------------
-- the softcut side
-- ---------------------------------------------------------------------------

-- LEVEL folds in the master and the global STOP, exactly like the engine and
-- tape decks do — one key silences everything that makes sound, with no
-- exceptions and no deck that forgot.
--
-- `play` silences the deck by LEVEL rather than stopping its head, and that is
-- the point: two decks at different rates are only in a drifting relationship
-- while both heads keep moving. Stopping one and restarting it would snap it
-- back to its loop start and lose the phase against the other. The page says
-- MUTE, not STOP, because that is what it does.
function M.update_level(d)
  -- the master fold is computed here rather than read from C.mix_gains ON
  -- PURPOSE: this module stays drivable standalone (tools/test_deck.lua stubs
  -- a bare ctx), and the two-factor fold is the whole overlap
  local out = pget("out_level", 1) * (1 - pget("stop_all", 0))
  local lv = get(d, "level", 0.8) * out * (get(d, "play", 1) == 1 and 1 or 0)
  both(d, function(v) sc.level(v, lv) end)
end

function M.update_rate(d)
  -- the global STOP halts the head, not just the level (true stop: START
  -- resumes from the exact spot). every deck stops AS ONE, so their relative
  -- drift survives; MUTE (play = 0) alone keeps the head moving, unchanged.
  local r = get(d, "rate", 1) * (get(d, "reverse", 0) == 1 and -1 or 1)
    * (1 - pget("stop_all", 0))
  both(d, function(v) sc.rate(v, r) end)
end

-- rec gates capture; `pre` is what survives a pass. pre 1 = OVERDUB (stack),
-- pre 0 = REPLACE. Layers default to overdub because stacking is their job
-- (a deck may set `pre_default` — the tape's is 0, REPLACE). A deck with a
-- `freeze` key (the tape) holds instead: capture stops and the loop
-- regenerates at full pre; decks without one read the default 0 and the
-- branch is inert.
function M.update_rec(d)
  local frozen = get(d, "freeze", 0) == 1
  -- STOP gates capture too (the head is frozen anyway; an armed deck resumes
  -- recording on START, like the engine's record head)
  local on = get(d, "rec", 0) == 1 and not frozen
    and pget("stop_all", 0) == 0
  both(d, function(v)
    sc.rec_level(v, on and 1 or 0)
    sc.pre_level(v, frozen and 1 or get(d, "pre", d.pre_default or 1))
    sc.rec(v, on and 1 or 0)
  end)
end

-- loop bounds, in seconds, inside this deck's own region
function M.update_loop(d)
  local a = d.from + clamp(get(d, "start", 0), 0, 1) * d.len
  local b = d.from + clamp(get(d, "end", 1), 0, 1) * d.len
  local lo, hi = math.min(a, b), math.max(a, b)
  -- softcut's 0.1s minimum, held INSIDE the region: floored past the end, a
  -- loop parked at the far right would read (and record) the first 100ms of
  -- the NEXT deck's region
  if hi - lo < 0.1 then
    hi = math.min(lo + 0.1, d.from + d.len)
    lo = hi - 0.1
  end
  both(d, function(v)
    sc.loop_start(v, lo)
    sc.loop_end(v, hi)
  end)
  M.update_fade(d)      -- the seam is capped against the loop; the loop moved
end

-- The JOIN, where the loop ends and starts again. Softcut fades between the
-- two over this long. Short is a clean cut and a hard downbeat, which is what
-- a drum loop wants. Long is a blend that hides the join landing in the
-- middle of a held note, which is what a pad wants. One fixed value cannot
-- suit both, and this is the number that decides whether a loop sounds tight
-- or smeared.
function M.update_fade(d)
  -- ...but never longer than the loop can absorb. The knob goes to half a
  -- second and a loop can be as short as a tenth of one, so a scene recall
  -- can leave the fade longer than the loop it has to cross. The deck then
  -- spends all its time fading and goes quiet, while the page still draws it
  -- bright. A quarter of the loop is as long as it can usefully get.
  local f = math.min(get(d, "fade", 0.02), M.loop_secs(d) * 0.25)
  both(d, function(v) sc.fade_time(v, f) end)
end

-- stereo WIDTH. 1 is the deck's own hard L/R, 0 collapses it to the centre.
-- Two decks stacked on related material, both full-width, are a wall; pulling
-- one of them in is what leaves room to hear the other around it.
function M.update_width(d)
  local w = clamp(get(d, "width", 1), 0, 1)
  sc.pan(d.va, -w)
  sc.pan(d.vb, w)
end

-- drop both heads at a normalized position inside this deck's region
function M.jump(d, ph)
  local at = d.from + clamp(ph, 0, 1) * d.len
  both(d, function(v) sc.position(v, at) end)
end

-- how long this deck's loop actually is, in seconds. The number SNAP works
-- on and the page prints. One law, so they cannot disagree.
function M.loop_secs(d)
  local a = clamp(get(d, "start", 0), 0, 1)
  local b = clamp(get(d, "end", 1), 0, 1)
  return math.max(math.abs(b - a) * d.len, 0.1)
end

function M.update_all(d)
  M.update_rate(d)
  M.update_rec(d)
  M.update_loop(d)
  M.update_level(d)
  M.update_fade(d)
  M.update_width(d)
end

-- ---------------------------------------------------------------------------
-- the loop-pedal law
-- ---------------------------------------------------------------------------
-- A deck with NO material takes its loop length from the pass you record:
-- arming opens the loop to the whole region so nothing you play is cut off,
-- and marks where the head is. Disarming closes the loop around exactly what
-- you played and drops the head back at its start, so it plays back tight
-- immediately. Without this a fresh layer loops the WHOLE 60-second region,
-- which is a deck, not a looper.
--
-- A deck that ALREADY holds audio keeps its loop and overdubs into it. That
-- is the entire difference between defining a loop and adding to one, and it
-- is why the layers default to overdub while the tape defaults to replace.
--
-- How accurately it can catch the moment you pressed the key is limited by
-- how often softcut reports the playhead position, which is every 25 ms. That
-- is close, but never exact, and it is why SNAP exists on top of this:
-- rounding the length to match something else is what puts a hand-played
-- loop properly in time.
-- Move both loop edges. The order matters: each one is a separate write, so
-- in between there is a moment where the new start sits against the OLD end.
-- If that leaves the start past the end, update_loop reads it as a loop of
-- nothing, floors it to 100ms, and the playhead jumps. So move whichever edge
-- keeps start before end at the halfway point. One of the two always does.
local function set_bounds(d, lo, hi)
  if lo <= clamp(get(d, "end", 1), 0, 1) then
    params:set(p(d, "start"), lo); params:set(p(d, "end"), hi)
  else
    params:set(p(d, "end"), hi); params:set(p(d, "start"), lo)
  end
end
M.set_loop = set_bounds

function M.arm_loop(d)
  d.arm_phase, d.arm_was = nil, nil
  if d.any then return end            -- overdub into the established loop
  -- Remember the loop we are about to widen. If the recording turns out to be
  -- too short to be a loop, close_loop puts this back. Widening is only
  -- preparation, and preparation that comes to nothing must not cost the
  -- player the loop they had set. Tapping REC by mistake takes a single
  -- frame, and without this it left the deck looping the whole 60 seconds.
  d.arm_was = { clamp(get(d, "start", 0), 0, 1), clamp(get(d, "end", 1), 0, 1) }
  set_bounds(d, 0, 1)
  d.arm_phase = d.phase
end

-- forget the mark without closing anything: the erase disarms on its way to
-- wiping the deck, and closing a loop around material about to be destroyed
-- is noise. The loop stays as the arm left it, because the erase resets it.
function M.abort_loop(d) d.arm_phase, d.arm_was = nil, nil end

function M.close_loop(d)
  local a, was = d.arm_phase, d.arm_was
  d.arm_phase, d.arm_was = nil, nil
  if not a then return end
  local b = d.phase
  -- Which way the head was moving decides which end of the recording is the
  -- loop START. Playing backwards, the head counts DOWN, so the recording
  -- runs from where it stopped to where it started. Assuming it always counts
  -- up left a reversed deck with either no loop at all, or a loop around the
  -- one stretch it had just skipped over.
  local back = get(d, "rate", 1) * (get(d, "reverse", 0) == 1 and -1 or 1) < 0
  local lo, hi = a, b
  if back then lo, hi = b, a end
  -- The head ran off the end and round to the start, or barely moved at all.
  -- A loop cannot span that join, so there is nothing to close here. Put back
  -- the loop we widened, rather than leave the deck on the full 60 seconds,
  -- which is the once-a-minute playback this whole law exists to prevent.
  if (hi - lo) < (0.1 / d.len) then
    if was then set_bounds(d, was[1], was[2]) end
    return
  end
  set_bounds(d, lo, hi)
  -- and then let the instrument round the LENGTH onto the grid, if what you
  -- played was already close to one. Which grid is a musical question (the
  -- other deck, the take's window, the clock), so it is not this module's to
  -- answer; the loop-pedal law lives here and the reference lives in ctx.
  if C.layer_quantize then C.layer_quantize(d) end
  M.jump(d, clamp(get(d, "start", 0), 0, 1))
end

-- wipe THIS deck only. sc.buffer_clear() would take the whole buffer with it —
-- the tape and the other layers included — which is the one collision that
-- makes adding decks not purely additive.
function M.clear(d)
  sc.buffer_clear_region(d.from, d.len)
  for i = 1, 128 do d.wave[i] = 0 end
  d.wave_bin = 0
  d.any = false
end

-- read a wav into this deck's region (the `layN_file` params land here, via
-- ctx.layer_load, which resamples off-rate files first: softcut's buffer read
-- does no sample-rate conversion either). Stereo lands L/R on the deck's
-- voice pair; a MONO file feeds both sides. The loop opens to the file's
-- length so it plays at once; unknown length (unreadable header) = the whole
-- region. A load IS material: `any` goes true and the strip repaints.
-- `keep_loop`: the PSET restore passes true — params:read has just restored
-- the session's own loop points, and the interactive snap below would stomp
-- them back to the full file on every load. A hand-picked load keeps snapping.
function M.load_file(d, path, shown, keep_loop)
  local ch, dur
  if C.wav_info then ch, dur = C.wav_info(path) end
  sc.buffer_clear_region(d.from, d.len)
  if ch == 1 then
    sc.buffer_read_mono(path, 0, d.from, d.len, 1, 1)
    sc.buffer_read_mono(path, 0, d.from, d.len, 1, 2)
  else
    sc.buffer_read_stereo(path, 0, d.from, d.len)
  end
  d.any = true
  d.wave_bin = 0
  if C.wave_from_file then C.wave_from_file(path, d.wave, d.len) end
  if not keep_loop then
    local frac = dur and clamp(math.min(dur, d.len) / d.len, 0.01, 1) or 1
    params:set(p(d, "start"), 0)
    params:set(p(d, "end"), frac)
  end
  print(string.format("mangler: %s -> %s%s", shown or path, d.name,
    (dur and not keep_loop)
      and string.format(" (%.1fs, loop snapped)", math.min(dur, d.len)) or ""))
end

function M.start(d)
  sc.enable(d.va, 1); sc.enable(d.vb, 1)
  -- voice -> buffer channel, and the stereo split
  sc.buffer(d.va, 1); sc.buffer(d.vb, 2)
  both(d, function(v)
    sc.play(v, 1)
    sc.loop(v, 1)
    sc.position(v, d.from)
    sc.level_slew_time(v, 0.05)
    sc.rate_slew_time(v, 0.05)
    -- softcut's filter sections default in a way that can mute a voice; force
    -- them open, the same as init_tape does
    sc.pre_filter_dry(v, 1.0)
    sc.pre_filter_lp(v, 0.0)
    sc.post_filter_dry(v, 1.0)
    sc.post_filter_lp(v, 0.0)
  end)
  -- each voice takes one input channel: lower = L, upper = R
  for ch = 1, 2 do
    sc.level_input_cut(ch, d.va, ch == 1 and 1.0 or 0.0)
    sc.level_input_cut(ch, d.vb, ch == 2 and 1.0 or 0.0)
  end
  sc.buffer_clear_region(d.from, d.len)
  M.update_all(d)
  -- the playhead poll drives this deck's needle and its waveform painting
  sc.phase_quant(d.va, 0.025)
end

-- ---------------------------------------------------------------------------
-- the phase poll
-- ---------------------------------------------------------------------------
-- mtape owns the single sc.event_phase handler and forwards anything that is
-- not the tape's own voice to here. Position drives the page; while recording
-- it also paints the picture, because softcut exposes no per-voice output
-- meter — the amplitude has to come from what is being fed in.
function M.on_phase(voice, pos)
  for i = 1, #M.decks do
    local d = M.decks[i]
    if d.va == voice then
      d.phase = clamp((pos - d.from) / d.len, 0, 1)
      if get(d, "rec", 0) == 1 then
        local a = C.cut_rec_amp()   -- what softcut records: the shared law
        if a > 0.01 then d.any = true end
        d.wave_bin = C.paint_bins(d.wave, d.wave_bin,
          math.floor(d.phase * 127.999) + 1, a, get(d, "pre", 1))
      end
      return
    end
  end
end

-- ---------------------------------------------------------------------------
-- the deck audio rides the PSET
-- ---------------------------------------------------------------------------
-- Same rule as the take and the tape: an untouched deck must not dump silence
-- on every save, and a CLEARED one must not resurrect on load — so an empty
-- save DELETES the stale wav, and a load with no wav clears the region rather
-- than leaving whatever happens to be in the live buffer.
local function path_for(d, number)
  return norns.state.data .. d.id .. "-" .. number .. ".wav"
end

function M.pset_write(number)
  for i = 1, #M.decks do
    local d = M.decks[i]
    if d.any then
      sc.buffer_write_stereo(path_for(d, number), d.from, d.len)
    else
      os.remove(path_for(d, number))
    end
  end
end

function M.pset_read(number)
  for i = 1, #M.decks do
    local d = M.decks[i]
    -- Save a preset with a deck armed and it stores rec = 1. Loading it sets
    -- the params one at a time in file order, and rec comes before the loop
    -- points, so arm_loop ran on a deck that still looked empty and left a
    -- recording "open" that never happened. The next time the player stopped
    -- recording, that ghost was used to re-cut the loop the preset had just
    -- restored. This runs after every value is in, so it is the place to
    -- forget it. The deck stays armed; only the ghost goes.
    M.abort_loop(d)
    local path = path_for(d, number)
    if util.file_exists(path) then
      sc.buffer_read_stereo(path, 0, d.from, d.len)
      d.any = true
      -- repaint this deck's strip from its wav (same reason as the tape:
      -- the softcut buffer is unreadable from lua, the file is right there)
      d.wave_bin = 0
      if C.wave_from_file then C.wave_from_file(path, d.wave, d.len) end
    else
      -- no deck wav, but the pset names a loaded FILE: put the file back
      -- rather than clearing. The file param's action may not have re-fired
      -- during params:read if its value did not change across the load. A
      -- pset whose file param is empty still clears, same rule as the tape.
      local fp = pget(p(d, "file"), "")
      if fp ~= "" and fp ~= "-" and (not _path or fp ~= _path.audio)
          and util.file_exists(fp) then
        -- keep_loop: the pset's loop points are already restored and are
        -- authoritative — reloading the audio must not re-snap them
        M.load_file(d, fp, nil, true)
      else
        M.clear(d)
      end
    end
  end
end

function M.pset_delete(number)
  for i = 1, #M.decks do os.remove(path_for(M.decks[i], number)) end
end

-- ---------------------------------------------------------------------------
-- lifecycle
-- ---------------------------------------------------------------------------

function M.init(ctx)
  C = ctx
  pget, clamp = ctx.pget, ctx.clamp
end

-- silence every deck. Called from cleanup so a reload does not leave voices
-- playing into the next script.
function M.cleanup()
  for i = 1, #M.decks do
    local d = M.decks[i]
    both(d, function(v)
      pcall(function()
        sc.rec(v, 0)
        sc.play(v, 0)
        sc.level(v, 0)
        sc.enable(v, 0)
      end)
    end)
  end
end

return M
