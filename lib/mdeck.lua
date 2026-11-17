-- mdeck: a loop deck on a softcut voice pair.
--
-- One of these is a track: its own slice of the softcut buffer, its own loop
-- points, rate, direction and overdub. Several run at once for almost nothing,
-- because softcut is a separate audio core.
--
-- The instrument builds none with M.new today: the two layer decks (lay1,
-- lay2) are gone, the four engine tracks replaced them. The tape is the one
-- deck, and test/test_deck.lua builds its own to drive the law.
--
-- What a deck CANNOT do is granulate, warp or spectrally stretch. That is the
-- engine's buffer and the engine's voice. A deck is a loop.
--
-- The tape (lib/mtape.lua) borrows these mechanics through a keymapped
-- descriptor: rate, rec gating, loop bounds, the seam, clear and jump are
-- this module's. Its level law, pset files, phase events and its own
-- loop-pedal law stay in mtape and four.lua (see the note there).

local sc = require "softcut"

local C, pget, clamp

local M = {}

-- every deck built, in creation order, so the shared plumbing (the phase
-- dispatcher, the master level, cleanup) can walk them
M.decks = {}

-- ---------------------------------------------------------------------------
-- construction
-- ---------------------------------------------------------------------------
-- `o` = { id, name, va, vb, from, len, bins }
--   id       param prefix, e.g. "dk1" -> dk1_rec, dk1_level, ...
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
    wave = {},          -- the picture, painted as the head passes (o.bins bins)
    wave_bin = 0,
    gen = 0,            -- bumped by anything that replaces the material, so a
                        -- load that lands late can tell
    -- mat_lo / mat_hi: the stretch of the region that holds material (0..1),
    -- nil when there is none. Kept by track_extent, read through M.extent.
  }
  for i = 1, (o.bins or 128) do d.wave[i] = 0 end
  M.decks[#M.decks + 1] = d
  return d
end

-- a param id for this deck: p(d, "rec") -> "dk1_rec". A deck may carry a
-- `keymap` overriding the scheme — the TAPE deck's ids predate the prefix
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
  -- PURPOSE: this module stays drivable standalone (test/test_deck.lua stubs
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
-- pre 0 = REPLACE. A deck defaults to overdub
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
  -- softcut's REC FLAG STAYS ON. A voice moves its write index only while the
  -- flag is on, so a head that played with it off writes at its last set
  -- position, not where it reads: the first pass on a fresh deck landed outside
  -- its own loop and the deck played silence. Heard on the device, 2026-11-06.
  -- These two levels are the gate: rec 0 and pre 1 write nothing, bit for bit.
  local rec = on and 1 or 0
  local pre = on and get(d, "pre", d.pre_default or 1) or 1
  -- A punch ramps over 5ms, so it does not print a step into the audio. The ramp
  -- never lands exactly, and an idle deck must not drift, so the next phase
  -- event (settle_rec) turns it off and lands the levels.
  local ramp = d.rec_on ~= nil and d.rec_on ~= on
  d.rec_on = on
  d.rec_lv, d.pre_lv = rec, pre
  d.rec_settling = ramp
  both(d, function(v)
    sc.recpre_slew_time(v, ramp and 0.005 or 0)
    sc.rec(v, 1)
    sc.rec_level(v, rec)
    sc.pre_level(v, pre)
  end)
end

function M.settle_rec(d)
  if not d.rec_settling then return end
  d.rec_settling = false
  both(d, function(v)
    sc.recpre_slew_time(v, 0)
    sc.rec_level(v, d.rec_lv)
    sc.pre_level(v, d.pre_lv)
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

-- drop both heads at a normalized position inside this deck's region.
-- softcut reports the head every 25 ms, and a report from the place the head
-- left can still be on its way: M.trust drops those.
function M.jump(d, ph)
  ph = clamp(ph, 0, 1)
  local at = d.from + ph * d.len
  both(d, function(v) sc.position(v, at) end)
  d.jump_at, d.jump_left = ph, 3
end

-- Is this report of the head (`ph`, 0..1 in the region) to be believed? `was`
-- is the place the last believed one gave. After a jump, up to three reports
-- that are not near the place the head went to are dropped: without this a
-- pass that closed 30 ms after it opened took the old place as its end. A
-- believed report that lies far before the last one is a head that came
-- round the region's end (d.wrapped). A pass reads that when it closes: its
-- loop cannot cross the end.
function M.trust(d, ph, was)
  if (d.jump_left or 0) > 0 then
    if math.abs(ph - d.jump_at) > 0.02 then
      d.jump_left = d.jump_left - 1
      return false
    end
    d.jump_left = 0
  end
  if ph < was - 0.5 then d.wrapped = true end
  return true
end

-- does this deck play forward? A stopped deck does not.
function M.forward(d)
  return get(d, "rate", 1) * (get(d, "reverse", 0) == 1 and -1 or 1) > 0
end

-- how long this deck's loop actually is, in seconds. One law for every
-- reader, so they cannot disagree.
function M.loop_secs(d)
  local a = clamp(get(d, "start", 0), 0, 1)
  local b = clamp(get(d, "end", 1), 0, 1)
  return math.max(math.abs(b - a) * d.len, 0.1)
end

function M.update_all(d)
  M.update_rate(d)
  M.update_rec(d)
  M.update_loop(d)      -- (sends the seam too: update_loop ends in update_fade)
  M.update_level(d)
  M.update_width(d)
end

-- ---------------------------------------------------------------------------
-- the loop-pedal law
-- ---------------------------------------------------------------------------
-- A deck with NO material takes its loop length from the pass you record:
-- arming opens the loop to the whole region so nothing you play is cut off,
-- and marks where the head is. Disarming closes the loop around exactly what
-- you played and drops the head back at its start, so it plays back tight
-- immediately. Without this a fresh deck loops the WHOLE 60-second region,
-- which is a deck, not a looper.
--
-- A deck that ALREADY holds audio keeps its loop and overdubs into it. That
-- is the entire difference between defining a loop and adding to one, and it
-- is why a deck defaults to overdub while the tape defaults to replace.
--
-- How accurately it can catch the moment you pressed the key is limited by
-- how often softcut reports the playhead position, which is every 25 ms. That
-- is close, but never exact.
-- THE way to move a start/end pair (a loop, the take window). Each edge is a
-- separate write, so in between the new start sits against the OLD end; if
-- that crosses the pair, every reader sorts it into a region that is neither
-- the old one nor the new one, and the deck's 100ms floor can jump the head.
-- So the WIDENING edge goes first: moving left, the start; moving right, the
-- end. With an ordered pair the halfway state is then always ordered, and on a
-- slide right it still contains the old region, so the head is not stranded
-- outside the loop. The take window, the grid spans, the encoder slides and
-- motion replay all write through here.
function M.set_pair(sid, eid, lo, hi)
  if lo < pget(sid, 0) then
    params:set(sid, lo); params:set(eid, hi)
  else
    params:set(eid, hi); params:set(sid, lo)
  end
end

local function set_bounds(d, lo, hi) M.set_pair(p(d, "start"), p(d, "end"), lo, hi) end
M.set_loop = set_bounds

function M.arm_loop(d)
  d.arm_phase, d.arm_was = nil, nil
  d.gen = d.gen + 1                   -- a live pass outranks a load in flight
  if d.any then return end            -- overdub into the established loop
  -- Remember the loop we are about to widen. If the recording turns out to be
  -- too short to be a loop, close_loop puts this back. Widening is only
  -- preparation, and preparation that comes to nothing must not cost the
  -- player the loop they had set. Tapping REC by mistake takes a single
  -- frame, and without this it left the deck looping the whole 60 seconds.
  d.arm_was = { clamp(get(d, "start", 0), 0, 1), clamp(get(d, "end", 1), 0, 1) }
  set_bounds(d, 0, 1)
  -- A NEW LOOP STARTS AT THE START OF THE REGION (the forty-eighth change).
  -- The head runs on while nothing records, so a pass began anywhere in the
  -- region, and one that crossed its end could not become a loop: the whole
  -- region stayed open, and the pass came back once a minute. A deck that
  -- plays backward keeps the old law: its pass starts where the head is.
  -- The tape's own copy of this law is in four.lua (tape_rec).
  d.arm_jumped = M.forward(d)
  if d.arm_jumped then
    M.jump(d, 0)
    d.phase = 0
  end
  d.wrapped = false
  d.arm_phase = d.phase
end

-- forget the mark without closing anything: the erase disarms on its way to
-- wiping the deck, and closing a loop around material about to be destroyed
-- is noise. The loop stays as the arm left it, because the erase resets it.
function M.abort_loop(d) d.arm_phase, d.arm_was, d.arm_jumped = nil, nil, nil end

function M.close_loop(d)
  local a, was, jumped = d.arm_phase, d.arm_was, d.arm_jumped
  d.arm_phase, d.arm_was, d.arm_jumped = nil, nil, nil
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
  -- A forward pass that came round the region's end is longer than the
  -- region. It filled it: the loop is the whole region, as the arm left it.
  if jumped and d.wrapped then return end
  -- The head ran off the end and round to the start, or barely moved at all.
  -- A loop cannot span that join, so there is nothing to close here. Put back
  -- the loop we widened, rather than leave the deck on the full 60 seconds,
  -- which is the once-a-minute playback this whole law exists to prevent.
  if (hi - lo) < (0.1 / d.len) then
    if was then
      set_bounds(d, was[1], was[2])
      -- the arm moved the head to the region's start: put it back on the loop
      if jumped then M.jump(d, was[1]) end
    end
    return
  end
  set_bounds(d, lo, hi)
  M.jump(d, clamp(get(d, "start", 0), 0, 1))
end

-- wipe THIS deck only. sc.buffer_clear() would take the whole buffer with it —
-- the tape and every other deck included — which is the one collision that
-- makes adding decks not purely additive.
function M.clear(d)
  d.gen = d.gen + 1
  sc.buffer_clear_region(d.from, d.len)
  -- through mpages when it is there, so a repaint still queued for this strip
  -- (a PSET restore fills strips one after another) is cancelled with it and
  -- cannot draw the old waveform over the silence
  if C.clear_bins then C.clear_bins(d.wave)
  else for i = 1, #d.wave do d.wave[i] = 0 end end
  d.wave_bin = 0
  d.any = false
  d.mat_lo, d.mat_hi = nil, nil
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
-- where the material is
-- ---------------------------------------------------------------------------
-- The stretch of the region a deck has written, 0..1. A scene recall clamps a
-- stored loop to it, so a scene captured before the deck was recorded cannot
-- reopen the loop over 60 seconds of nothing (mscenes' clamp_stored). Grown
-- from the softcut phase events while the deck records; a load or a PSET
-- restore sets it, a clear forgets it. The tape keeps one too (lib/mtape.lua).
function M.track_extent(d, ph)
  if d.mat_hi then
    if ph < d.mat_lo then d.mat_lo = ph end
    if ph > d.mat_hi then d.mat_hi = ph end
  else
    d.mat_lo, d.mat_hi = ph, ph
  end
end

-- the extent as the clamp should use it, or nil when nothing is known. Widened
-- by 50ms each side: the phase events that grow it come every 25ms, so the
-- last one before a pass ends can be that far behind the head.
function M.extent(d)
  if not (d.mat_lo and d.mat_hi) then return nil end
  local pad = 0.05 / d.len
  return clamp(d.mat_lo - pad, 0, 1), clamp(d.mat_hi + pad, 0, 1)
end

-- how much of the region a PSET save writes: up to the end of the material
-- (plus the 50ms the extent can lag), or the whole region when the extent is
-- not known. A 2s loop no longer saves 60 seconds of mostly silence, and a
-- smaller file is less exposed to a save-then-quit cutting the write short.
function M.save_secs(d)
  if not d.mat_hi then return d.len end
  return math.min(d.len, d.mat_hi * d.len + 0.05)
end

-- after a PSET wav is read back into the region: the material is what the
-- file held, from the region's start (the save began there)
function M.restored_extent(d, path)
  local dur
  if C.wav_info then dur = select(2, C.wav_info(path)) end
  d.mat_lo, d.mat_hi = 0, dur and clamp(dur / d.len, 0, 1) or 1
end

-- ---------------------------------------------------------------------------
-- the phase poll
-- ---------------------------------------------------------------------------
-- mtape owns the single sc.event_phase handler and handles the tape's voice
-- itself. A deck built with M.new needs its events handed to this. Position
-- drives the page; while recording
-- it also paints the picture, because softcut exposes no per-voice output
-- meter — the amplitude has to come from what is being fed in.
function M.on_phase(voice, pos)
  for i = 1, #M.decks do
    local d = M.decks[i]
    if d.va == voice then
      local ph = clamp((pos - d.from) / d.len, 0, 1)
      if not M.trust(d, ph, d.phase) then return end   -- a report from before a jump
      d.phase = ph
      M.settle_rec(d)
      if get(d, "rec", 0) == 1 then
        M.track_extent(d, d.phase)
        local a = C.cut_rec_amp()   -- what softcut records: the shared law
        if a > 0.01 then d.any = true end
        d.wave_bin = C.paint_bins(d.wave, d.wave_bin,
          math.floor(d.phase * (#d.wave - 0.001)) + 1, a, get(d, "pre", 1))
      end
      return
    end
  end
end

-- ---------------------------------------------------------------------------
-- lifecycle
-- ---------------------------------------------------------------------------

function M.init(ctx)
  C = ctx
  pget, clamp = ctx.pget, ctx.clamp
end

return M
