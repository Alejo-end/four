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

-- a param id for this deck: p(d, "rec") -> "lay1_rec"
local function p(d, k) return d.id .. "_" .. k end
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
function M.update_level(d)
  local out = pget("out_level", 1) * (1 - pget("stop_all", 0))
  local lv = get(d, "level", 0.8) * out * (get(d, "play", 1) == 1 and 1 or 0)
  both(d, function(v) sc.level(v, lv) end)
end

function M.update_rate(d)
  local r = get(d, "rate", 1) * (get(d, "reverse", 0) == 1 and -1 or 1)
  both(d, function(v) sc.rate(v, r) end)
end

-- rec gates capture; `pre` is what survives a pass. pre 1 = OVERDUB (stack),
-- pre 0 = REPLACE. Layers default to overdub because stacking is their job.
function M.update_rec(d)
  local on = get(d, "rec", 0) == 1
  both(d, function(v)
    sc.rec_level(v, on and 1 or 0)
    sc.pre_level(v, get(d, "pre", 1))
    sc.rec(v, on and 1 or 0)
  end)
end

-- loop bounds, in seconds, inside this deck's own region
function M.update_loop(d)
  local a = d.from + clamp(get(d, "start", 0), 0, 1) * d.len
  local b = d.from + clamp(get(d, "end", 1), 0, 1) * d.len
  local lo, hi = math.min(a, b), math.max(a, b)
  if hi - lo < 0.1 then hi = lo + 0.1 end     -- softcut's own minimum
  both(d, function(v)
    sc.loop_start(v, lo)
    sc.loop_end(v, hi)
  end)
end

function M.update_all(d)
  M.update_rate(d)
  M.update_rec(d)
  M.update_loop(d)
  M.update_level(d)
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

function M.start(d)
  sc.enable(d.va, 1); sc.enable(d.vb, 1)
  -- voice -> buffer channel, and the stereo split
  sc.buffer(d.va, 1); sc.buffer(d.vb, 2)
  sc.pan(d.va, -1);   sc.pan(d.vb, 1)
  both(d, function(v)
    sc.play(v, 1)
    sc.loop(v, 1)
    sc.position(v, d.from)
    sc.fade_time(v, 0.02)
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
        local cs = pget("cut_source", 0)
        local a = math.max(C.amp_in[1], C.amp_in[2]) * (1 - cs)
          + math.max(C.amp_out[1], C.amp_out[2]) * cs
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
    local path = path_for(d, number)
    if util.file_exists(path) then
      sc.buffer_read_stereo(path, 0, d.from, d.len)
      d.any = true
    else
      M.clear(d)
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
