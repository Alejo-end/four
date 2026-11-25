-- four: a 4-track sampler
-- record any sound, then
-- loop, stretch and grain
-- it on four tracks.
--
-- START
-- 1 plug a sound into the
--   norns input.
-- 2 press K2 to record.
--   press K2 again. your
--   take loops, clean.
-- 3 turn E1 to walk the
--   pages.
--
-- ON EVERY PAGE
-- E1    change the page
-- E2 E3 the two knobs
-- K2 K3 the two keys
--       (the foot of the
--       screen names them)
-- K1    hold for a second
--       pair of knobs
-- K1+E1 pick track 1 to 4
-- K1+K2 stop or start all
-- K1+K3 tap: all effects
--       off. hold: erase
--       what the page holds
--
-- KEYS
-- tap a key and it stays
-- on. hold it and it is on
-- only while you hold.
--
-- PAGES
-- TAKE   record a sound
--        and set its loop
-- VOICE  how the track
--        plays the sound:
--   PLAY   a clean loop
--   GRAIN  a cloud of
--          small pieces
--   WARP   slow or fast,
--          same pitch
--   PV     freeze, smear
--   CLOUD  texture
-- TRACKS the four tracks:
--        on, level, and
--        sends (hold K1)
-- TAPE   loop the whole
--        output
-- FILTER tone and drive
-- EFFECT two for a track:
--        chorus, flange,
--        wobble, reson,
--        ring, echo
-- DELAY  echo, shared
-- REVERB space, shared
-- MIX    the levels
-- PADS   8 slices to play
-- MOTION record a knob
--        move, set LFOs
-- SCENE  keep a sound,
--        call it back,
--        morph to it
--
-- GOOD TO KNOW
-- each track has its own
-- sound. pick a track with
-- K1+E1, then TAKE records
-- into it.
-- a fresh take plays dry.
-- you add the effects.
-- every knob maps to MIDI
-- in PARAMS.
-- a grid is welcome, and
-- never needed.
--
-- the full guide is in
-- README.md

-- -----------------------------------------------------------------------------
-- this file is the orchestrator: state + params + key/encoder handlers. the
-- rest lives in lib/ modules (script-internal, NOT norns engines): mfont (pixel
-- font), mtape (the softcut tape + the mix law), mdeck (the loop deck law),
-- minput (midi/keyboard notes), mgrid (grid surface), mmotion (the gesture
-- looper), mscenes (scenes, morph, orbit, the way back), mpages (the screen and
-- the wav file reader), mplugin (installs four's own SuperCollider plugin).
-- they share one `ctx` table and params are the single source of truth. the
-- plan: doc/plan.md. the history: doc/changelog.md.

engine.name = "Four"

-- bring-up diagnostics: load milestones in maiden. If "script file executed"
-- appears without "init() called", the engine died in alloc — check the SC tab.
print("four: script file executed")

local mu = require "musicutil"

local min, max = math.min, math.max

-- ============================================================================
-- state (shared with the lib/ modules through ctx)
-- ============================================================================

-- twelve stations, ordered by FAMILY so neighbours belong together:
-- the take (TAKE VOICE TRACKS) · the loop deck (TAPE) · the tone
-- (FILTER EFFECT DELAY REVERB) · the console (MIX) · the performance layer
-- (PADS MOTION SCENE). EROSION and ORBIT are no longer pages: erosion only
-- ever worked in PLAY mode, so its controls live on VOICE's PLAY face (the
-- alt pair, which was a redundant scan/pitch copy there); the orbit drives
-- the scene machinery, and its knobs live in PARAMS (orbit), its RUN switch
-- on the grid/PARAMS/MIDI. SCENE's alt pair picks the crossfader's A end.
-- The params are UNCHANGED (ids are never renamed), only their surfaces
-- moved.
local PAGES = {
  "TAKE", "VOICE", "TRACKS", "TAPE", "FILTER", "EFFECT", "DELAY", "REVERB",
  "MIX", "PADS", "MOTION", "SCENE",
}

local FPS = 15

local tape_arm_phase      -- head position when tape rec opened a pass; nil = none
local tape_arm_was        -- the loop that pass widened, put back if it is declined
local tape_arm_jumped     -- that pass moved the head to the tape's start (it plays forward)
local rec_open = false    -- an engine record pass is open (armed by a real 1)
local rec_wrapped = false -- that pass came round the end of its buffer
local rec_last = 0        -- ...read from the write head's last poll
local polls = {}
local redraw_clock
local beat_clock          -- ctx.on_beat, on every beat of the clock
local prev_midi_add, prev_midi_remove   -- norns' hot-plug callbacks, restored

-- ============================================================================
-- helpers
-- ============================================================================

local function clamp(x, lo, hi)
  if x < lo then return lo elseif x > hi then return hi else return x end
end

local function ptoggle(id)
  params:set(id, params:get(id) == 0 and 1 or 0)
end

local function pget(id, default)
  if params.lookup[id] then return params:get(id) end
  return default
end

-- current window edges (sorted) and span
-- (four) the take window is the FOCUSED track's: its own material and
-- its own window. ctx.focus_take rewrites WIN.
local WIN = { "pos_start", "pos_end" }
local function window_bounds()
  local a = pget(WIN[1], 0)
  local b = pget(WIN[2], 1)
  local lo, hi = min(a, b), max(a, b)
  return lo, hi, max(hi - lo, 0.001)
end

-- zoom-aware fine control: window/loop edge params scale their encoder
-- deltas by the current span, so steps shrink as the region tightens —
-- a wide-open window moves fast, a tight loop nudges by milliseconds.
-- (combined with the 0.002 quantum on these specs: ~10ms at the finest.)
-- every value other than "win" is the param-id prefix of a loop pair.
local FINE_IDS = { pos_start = "win", pos_end = "win",
                   loop_start = "loop", loop_end = "loop",
                   t2_pos_start = "t2_pos", t2_pos_end = "t2_pos",
                   t3_pos_start = "t3_pos", t3_pos_end = "t3_pos",
                   t4_pos_start = "t4_pos", t4_pos_end = "t4_pos" }

-- interpolate between two values of one param in its controlspec's WARPED
-- space (unmap, lerp, map): linear in the space the encoder moves in, so an
-- exponential param (cutoff, pitch) sweeps evenly. Returns the value and the
-- normalized position. The scene morph and the motion depth both blend
-- through here.
local function warped_lerp(cs, a, b, t)
  local na = clamp(cs:unmap(a), 0, 1)
  local tn = na + (clamp(cs:unmap(b), 0, 1) - na) * t
  return cs:map(tn), tn
end

local function fine_delta(id, d)
  local kind = FINE_IDS[id]
  if not kind then return d end
  local span
  if kind == "win" then
    local _, _, s = window_bounds()
    span = s
  else
    span = math.abs(pget(kind .. "_end", 1) - pget(kind .. "_start", 0))
  end
  return d * clamp(math.max(span, 0.001) * 4, 0.08, 1)
end

-- ============================================================================
-- ctx: the one table the lib/ modules see
-- ============================================================================
-- helpers and stable table refs are bound by each module at init; the
-- mutable scalars below are written here (polls, handlers, the clock) and
-- read by the modules each call.

local ctx = {
  -- wiring
  pget = pget, ptoggle = ptoggle, clamp = clamp,
  window_bounds = window_bounds, warped_lerp = warped_lerp,
  PAGES = PAGES, FPS = FPS,
  -- ui state
  page = 1,
  alt = false,               -- K1 held
  last_input = 0,            -- frame of the last key/encoder touch (idle dim)
  idle_dim = false,
  held = {},                 -- held[n] = true while key n is down (page-independent)
  frame = 0,                 -- redraw frame counter (drives the REC blink)
  flash_id = nil,            -- the param whose footer word swells (turning)
  flash_until = 0,
  -- engine/system signals
  play_phase = 0,            -- engine poll: normalized playhead in the buffer
  play_phase2 = 0,           -- the same for tracks 2 to 4 (four)
  play_phases = { 0, 0, 0, 0 },
  rec_phase = 0,             -- engine poll: normalized write-head position
  rec_arm_phase = 0,         -- write-head position when rec was armed
  rec_reset_at = nil,        -- the frame a new take put the write head at 0 (see head_poll)
  rec_poll_time = nil,       -- when the write head's last poll came (util.time)
  rec_amp = 0,               -- engine poll: amplitude of what's being written
  rec_waiting = false,       -- armed to start on sound, none heard yet (TAKE: WAIT)
  amp_in = { 0, 0 },         -- system polls: live input amplitude L/R
  amp_out = { 0, 0 },        -- system polls: output amplitude L/R
  cpu_high = false,          -- the load is near the limit: the header says CPU
  tape_phase = 0,            -- softcut phase event: tape head, normalized
  tape_heard = nil,          -- an open tape pass: has it heard a sound yet (nil: no pass)
  tape_quiet = 0,            -- frames of silence at the tape's source while it records
  tape_msg = nil,            -- what the last tape pass did, for TAPE to say
  -- display-model flags (mpages paints them)
  wave_any = false,          -- false until something audible lands in the buffer
  twave_any = false,
  -- normalized 0..1 high-water mark of buffer content worth saving (from frame
  -- 0): the take end at rec-stop, a loaded sample's length, or 1 when regen has
  -- filled the whole buffer. write_take bounds the PSET save to it. 0 = empty.
  take_len = 0,
  -- pad bank: 8 slice pads, per-pad type (0 grain / 1 slice), a screen
  -- cursor for standalone select/audition. shared by the PADS page + the
  -- MIDI/grid note routing (they map an incoming note to a pad index).
  -- SOUND-LOCKS: per-pad voice (0 grain / 1 slice) + pitch (semitones). the
  -- `pad_voice`/`pad_pitch` params are the cursor EDITOR (Elektron data-knob
  -- style — they read/write the pad under pad_cursor); these arrays hold the 8
  -- locks and ride the PSET (ctx.padlock_pset_*). note_on reads them per pad.
  pad_type = {},             -- per-pad voice (0 grain / 1 slice); every read is `or 0`
  pad_pitch = {},            -- per-pad pitch (semitones); every read is `or 0`
  pad_sync = false,          -- guard: syncing the editor params FROM the arrays
  pad_cursor = 0,
  pad_n = 8,
  pad_held = {},             -- voice id -> pad index while sounding
  pad_order = {},            -- the same ids in press order, for the steal below
}

local Mfont = include "lib/mfont"
local Mtape = include "lib/mtape"
local Mdeck = include "lib/mdeck"
local Minput = include "lib/minput"
local Mgrid = include "lib/mgrid"
local Mmotion = include "lib/mmotion"
local Mseq = include "lib/mseq"
local Mlfo = include "lib/mlfo"
local Mout = include "lib/mout"
local Mosc = include "lib/mosc"
local Mscenes = include "lib/mscenes"
local Mwav = include "lib/mwav"
local Mpages = include "lib/mpages"
local Mplugin = include "lib/mplugin"
local Msample = include "lib/msample"

ctx.font = Mfont
ctx.wav = Mwav          -- the wav file layer; mpages paints strips through it
ctx.grid = Mgrid
ctx.motion = Mmotion
ctx.seq = Mseq
ctx.lfo = Mlfo
ctx.osc = Mosc
-- the tape display model lives in mpages; mtape clears it when a pset restores
-- an empty tape, so it needs a way to reach it
ctx.clear_twave = Mpages.clear_twave
-- ...and repaints it from the PSET wav on restore
ctx.repaint_twave = Mpages.repaint_twave
ctx.clear_bins = Mpages.clear_bins     -- a deck erase stops its own repaint
ctx.wav_info = Mwav.wav_info

-- any hand on the instrument counts as presence for the idle dim: keys and
-- encoders here, the grid and MIDI in their own modules
function ctx.touch_input() ctx.last_input = ctx.frame end

-- THE TIMEBASE. These two numbers place everything in the instrument: every
-- window edge, pad slice, waveform bin and PSET bound is a fraction of them.
-- Both are set by the ENGINE (lib/Engine_Four.sc allocates
-- `s.sampleRate * bufSecs`, and norns runs its server at 48k) and lua cannot
-- read either off the server — so they are mirrored ONCE here and shared
-- through ctx. They used to be bare literals in several modules plus the .sc:
-- miss one when the buffer length changes and PSET saves silently truncate the
-- take, or every waveform, window bracket and pad slice draws against the
-- wrong clock with no error anywhere.
ctx.BUF_SECS = 60        -- must match `bufSecs` in lib/Engine_Four.sc
-- How many bytes per sample `write_take` puts on disk. MUST match the format
-- in that command (`int24`, so 3). The export works out how big the file
-- should be from this and waits for it to get there, so a number that is too
-- small calls the file finished while a third of it is still being written.
ctx.TAKE_BYTES = 3       -- must match write_take's format in Engine_Four.sc
ctx.SERVER_SR = 48000    -- norns' scsynth sample rate
local BUF_SECS, SERVER_SR = ctx.BUF_SECS, ctx.SERVER_SR
Mwav.init(ctx)

-- THE tempo read. Guarded (the offscreen sim has no clock) and defaulted once,
-- so every caller agrees about what "the tempo" is.
function ctx.tempo()
  if clock and clock.get_tempo then
    local ok, t = pcall(clock.get_tempo)
    if ok and t and t > 0 then return t end
  end
  return 120
end

-- THE CLOCK'S BEATS (the sixty-ninth change): the norns clock, and in the
-- offscreen norns (no clock) a count from the frames at the tempo.
function ctx.beats()
  if clock and clock.get_beats then
    local ok, b = pcall(clock.get_beats)
    if ok and type(b) == "number" then return b end
  end
  return (ctx.frame or 0) / FPS * ctx.tempo() / 60
end

-- A TAKE ON THE CLOCK: how many beats its line is (0 = FREE), and its word
local REC_SYNC_BEATS, REC_SYNC_WORD = { 0, 1, 4 }, { "", "BEAT", "BAR" }
function ctx.rec_sync_beats()
  return REC_SYNC_BEATS[math.floor(pget("rec_sync", 1) + 0.5)] or 0
end
function ctx.rec_sync_word()
  return REC_SYNC_WORD[math.floor(pget("rec_sync", 1) + 0.5)] or ""
end
-- An arm or a stop the instrument makes itself (a clear, UNDO, a change of
-- track, a full ONE-SHOT track): at once, never on the clock
function ctx.rec_set(v)
  ctx.rec_force = true
  params:set("rec", v)
  ctx.rec_force = false
end

-- the EFFECTIVE softcut record source: the cut_source knob. The SRC flag and
-- the meters read THIS, never the raw param, so one place decides it.
function ctx.eff_cut_source()
  return pget("cut_source", 1)
end

-- ONE writer for the softcut input sends, so the routing can never disagree
-- with the flags.
function ctx.update_cut_source()
  Mtape.set_source(ctx.eff_cut_source())
end

-- what the softcut decks RECORD right now, for the meters: the ADC tap, the
-- engine output (WET), or the blend. the law of the tape picture (mpages).
function ctx.cut_rec_amp()
  local cs = ctx.eff_cut_source()
  return max(ctx.amp_in[1], ctx.amp_in[2]) * (1 - cs)
    + max(ctx.amp_out[1], ctx.amp_out[2]) * cs
end

Mtape.init(ctx, Mdeck)   -- the tape borrows the deck mechanics (see mtape)
-- THE deck gain law (eng, tape, master) lives in mtape; the MIX page draws
-- the same numbers update_mix sends, so it reads them from here
ctx.mix_gains = Mtape.gains
ctx.TAPE_LEN = Mtape.TAPE_LEN         -- the tape's own length (not BUF_SECS)
ctx.tape_deck = Mtape.deck            -- read only: the page asks where its material is
ctx.paint_bins = Mpages.paint_bins    -- a deck paints its own picture
ctx.set_pair = Mdeck.set_pair         -- THE way to move a start/end pair
Mdeck.init(ctx)
-- a compound encoder target ("@...") resolves to a REAL param id: the one the
-- footer should print and the dial should point at. Pair-movers report their
-- anchor, the low edge. ONE resolver, because the encoder, the footer value and
-- the footer dial each need the same answer and two of them used to not have it
-- (a compound target read "--" and drew no pointer).
function ctx.enc_target(id)
  if id == "@win_move" then return WIN[1] end
  if id == "@mo_sel" then
    return pget("mod_focus", 1) > 1.5 and "mod_focus" or "motion_lane"
  end
  if id == "@route_amt" then return ctx.route_cur().id end
  if id == "@route_to" then return "route_sel" end
  if id == "@trk_level" then return ctx.LEVEL_ID[ctx.tsel()] end
  if id == "@rec_src" then return "rec_source" end
  if id == "@tempo" then return "clock_tempo" end
  return id
end

-- THE CLOCK IN WORDS (the seventieth change): "120 BPM" on the norns's own
-- clock, "120 MIDI" (LINK, CROW) when another one leads it. Built again only
-- when the tempo or the source changes: the redraw allocates nothing.
local CLOCK_WORD = { internal = "BPM", midi = "MIDI", link = "LINK", crow = "CROW" }
local clock_cache = { t = -1, src = nil, word = "" }
function ctx.clock_source()
  if not params.lookup["clock_source"] then return "internal" end
  return string.lower(params:string("clock_source") or "internal")
end
function ctx.clock_word()
  local t, src = math.floor(ctx.tempo() + 0.5), ctx.clock_source()
  if t ~= clock_cache.t or src ~= clock_cache.src then
    clock_cache.t, clock_cache.src = t, src
    clock_cache.word = t .. " " .. (CLOCK_WORD[src] or string.upper(src))
  end
  return clock_cache.word
end

-- where a loop deck's MATERIAL is (Mdeck.extent), for the scene clamp. The
-- one key is "tape". nil = no material, which leaves a stored loop exactly as
-- it was.
function ctx.material(key)
  if key == "tape" then
    if not ctx.twave_any then return nil end
    return Mdeck.extent(Mtape.deck)
  end
end

-- ---------------------------------------------------------------------------
-- the musical ratios a loop length snaps to
-- ---------------------------------------------------------------------------
-- A hand-played length is never exactly the length you meant. Two loops that
-- are an exact double, half or three-to-two of each other stay together
-- indefinitely. The motion looper rounds a first pass onto the clock with
-- these (ctx.clock_length).
local SNAP_RATIOS = {
  { 1 / 8, "1/8" }, { 1 / 6, "1/6" }, { 1 / 4, "1/4" }, { 1 / 3, "1/3" },
  { 1 / 2, "1/2" }, { 2 / 3, "2/3" }, { 3 / 4, "3/4" }, { 1, "1" },
  { 4 / 3, "4/3" }, { 3 / 2, "3/2" }, { 2, "2" }, { 3, "3" },
  { 4, "4" }, { 6, "6" }, { 8, "8" },
}
-- how close a hand-played length has to be for the automatic snap to take it.
-- 6% is the slop of someone trying to land on the beat; anything further out
-- is a length you chose, and it is left exactly as you played it.
local SNAP_TOL = math.log(1.06)

-- the musical ratio of `ref` nearest to `cur`, compared in LOG space so 1/2
-- and 2 are equally near, the way an ear hears them (a linear nearest would
-- pull everything toward the top). returns the ratio, its label, the error.
local function nearest_ratio(cur, ref)
  local best, label, err = 1, "1", math.huge
  for _, r in ipairs(SNAP_RATIOS) do
    local e = math.abs(math.log(cur / (ref * r[1])))
    if e < err then err, best, label = e, r[1], r[2] end
  end
  return best, label, err
end

-- a gesture loop's length on the clock: the nearest musical length to a bar
-- when what was played is already within the snap tolerance, else nil (a
-- length you clearly chose stays exactly as played). the motion looper asks
-- this when a first pass closes.
function ctx.clock_length(secs)
  local bar = 240 / ctx.tempo()
  local best, _, err = nearest_ratio(secs, bar)
  if err > SNAP_TOL then return nil end
  return bar * best
end

-- TAKE says what K3's SNAP and UNDO just did, on its top row, and prints the
-- full story to the log
local function take_say(msg, detail)
  ctx.take_msg, ctx.take_msg_at = msg, ctx.frame or 0
  print("four: " .. (detail or msg))
end
ctx.take_say = take_say

Minput.init(ctx)
Mgrid.init(ctx)
Mmotion.init(ctx)
Mseq.init(ctx)
Mlfo.init(ctx)
Mout.init(ctx)
Msample.init(ctx)
Mosc.init(ctx)
Mscenes.init(ctx)   -- sets ctx.scene (the module; its bank is ctx.scene.slots)
Mpages.init(ctx)

-- ============================================================================
-- keys: the punch law
-- ============================================================================
-- ONE physical rule for every key:
--   press = engage NOW · release within TAP_FRAMES = it latches ·
--   held past TAP_FRAMES = it was a punch, release disengages ·
--   already latched = any press turns it off.
-- defs come in two shapes:
--   { label, act }                 -- tap-cycle: fires on PRESS, no punch
--   { label, pon, poff, lit }      -- punchable; lit() feeds the footer
--   (gate = true                   -- always momentary, e.g. the PADS pad)
-- K1+K2 = STOP and K1+K3 = DRY (tap) / ERASE (1s arc) are GLOBAL — no page
-- claims them, so the rescue reflexes are unconditional muscle memory.

local TAP_FRAMES = 5     -- <=4 frames (~300ms at 15fps) reads as a tap
local ERASE_FRAMES = 15  -- K1+K3 held ~1s (the drawn arc) erases material

-- per-key press bookkeeping for the punch law: the def is resolved at the
-- PRESS and the release routes back to it, so an alt released mid-hold can
-- never hand the release to the wrong action (the grid learned this the hard way)
local key_state = { [2] = {}, [3] = {} }

-- punchable binary param: the common case
local function pk(label, id)
  return {
    label = label,
    lit = function() return pget(id, 0) > 0 end,
    pon = function() params:set(id, 1) end,
    poff = function() params:set(id, 0) end,
  }
end

-- throw: engage() applies a gesture and returns {id=prior} to restore on
-- disengage. hold = ride it and come back, tap = latch, tap again = back.
local throw_mem = {}

-- a throw's snapshot is only good until something ELSE moves the instrument.
-- A scene recall, a morph, a chaos throw or DRY installs values wholesale;
-- un-latching afterwards would write a snapshot taken BEFORE all that straight
-- over the top of it — silently undoing the recall. Drop the snapshots
-- instead. The pill goes dark, which is the honest signal: there is no longer
-- a "back" to come back to.
function ctx.throws_forget()
  for k in pairs(throw_mem) do throw_mem[k] = nil end
end

local function throw_restore(label)
  local mem = throw_mem[label]
  if not mem then return end
  throw_mem[label] = nil
  for id, v in pairs(mem) do params:set(id, v) end
end

-- a throw: `ids` are the params it owns, `apply` sets the new values, and the
-- snapshot to restore on release is built FROM ids — so what gets put back can
-- never drift from what gets set. Hold = ride it and come back, tap = latch,
-- tap again = back.
--
-- Engaging first un-latches any OTHER throw holding one of the same params,
-- restoring it. Two throws over one param used to STACK: the second cached
-- what the first had already displaced, so releasing them out of order left
-- the param at a value nobody chose under a lit pill. MIX's ENG/TAPE carried a
-- hand-written pair for exactly this and EROSION's HEAL/SCAR did not; keying
-- the conflict on the PARAMS makes it automatic for every throw, present and
-- future.
-- `key` (optional) names the snapshot when two throws share a word (OPEN on
-- either track); it defaults to the label.
local function throw(label, ids, apply, key)
  key = key or label
  return {
    label = label,
    lit = function() return throw_mem[key] ~= nil end,
    pon = function()
      for other, mem in pairs(throw_mem) do
        if other == "DRY" and key ~= "DRY" then
          -- DRY holds the whole wet path: another throw takes only its own
          -- ids out of DRY's memory (they are its now), and the rest of DRY
          -- stays as it is, and comes back on DRY's second tap
          for k = 1, #ids do mem[ids[k]] = nil end
        elseif other ~= key then
          for k = 1, #ids do
            if mem[ids[k]] ~= nil then throw_restore(other); break end
          end
        end
      end
      local mem = {}
      for k = 1, #ids do mem[ids[k]] = params:get(ids[k]) end
      throw_mem[key] = mem
      apply()
    end,
    poff = function() throw_restore(key) end,
  }
end

-- pulse a momentary param (the footswitch-shaped SCENE binaries: their
-- actions fire on the rising edge, so 1-then-0 is one clean press)
local function pulse(id)
  params:set(id, 1)
  params:set(id, 0)
end
-- the grid drives the same momentary params (read lazily at press time, so
-- defining it after the ctx wiring above is safe)
ctx.pulse = pulse

-- "open" cutoff for the current filter type — the ONE definition of what an
-- open filter means, shared by FILTER's OPEN throw and ctx.fx_dry
local function filter_open_cutoff(ft)
  return ft == 2 and 20 or (ft == 3 and 1000 or 20000)
end

-- TAKE K3: window full <-> back where you had it (a round trip, so a
-- fat-fingered snap is always recoverable)
local snap_mem

-- the window bounds SNAP remembers are only meaningful for the material they
-- were taken from. New audio in the buffer makes them a pointer into something
-- that no longer exists — a SNAP after CLR used to restore the erased take's
-- bounds — so whoever replaces the buffer forgets them.
function ctx.snap_forget() snap_mem = nil end

local function snap_window()
  local lo, hi = pget("pos_start", 0), pget("pos_end", 1)
  if hi < lo then lo, hi = hi, lo end
  if hi - lo > 0.98 then
    if snap_mem then
      params:set("pos_start", snap_mem[1])
      params:set("pos_end", snap_mem[2])
      take_say("SNAP - WINDOW BACK")
    else
      -- full window, nothing remembered — the state on every fresh load, where
      -- this key used to do nothing at all and say nothing about it. Snap to
      -- the TAKE instead: the same "window = what you recorded" law the
      -- rec-stop applies, which is the only useful meaning left here.
      local tl = ctx.take_len or 0
      if ctx.wave_any and tl > 0.001 and tl < 0.98 then
        snap_mem = { lo, hi }
        params:set("pos_start", 0)
        params:set("pos_end", tl)
        take_say("SNAP - WINDOW ON THE TAKE")
      else
        take_say("SNAP - ALREADY WHOLE",
          "SNAP — the window is already the whole buffer")
      end
    end
  else
    snap_mem = { lo, hi }
    params:set("pos_start", 0)
    params:set("pos_end", 1)
    take_say("SNAP - WHOLE BUFFER")
  end
end

-- ---- the tracks (four) ------------------------------------------------
-- Four engine tracks and ONE focus. `track_sel` is the focused track, and
-- TAKE, VOICE and FILTER all edit it: their titles read TAKE 2, VOICE 2 ...
-- and the same knobs and keys reach the `t<n>_` params. TRACKS is the hub:
-- the four tracks in a list, E2 picks the focus, and with K1 held the
-- focused track's sends. A HOLD of K3 on VOICE or FILTER also steps the
-- focus 1 > 2 > 3 > 4 > 1 (the tap keeps MODE / TYPE). What only track 1 has
-- (the erosion) is out of reach on the others, and what all share (drive,
-- dry/wet) stays the same param.
local NTRACKS = 4
-- the engine voice of a track. APPEND-ONLY: a PSET stores the index
local MODE_NAMES = { "OFF", "GRAIN", "WARP", "PV", "PLAY", "CLOUD" }
-- the effect slot of a track (fxSlot in the engine). APPEND-ONLY, like the modes
local EFFECT_NAMES = { "OFF", "CHORUS", "FLANGE", "WOBBLE", "RESON", "RING", "ECHO" }
local TRACK_PAGES = { TAKE = true, VOICE = true, FILTER = true, EFFECT = true }
local function tsel() return clamp(math.floor(pget("track_sel", 1) + 0.5), 1, NTRACKS) end
local function track2() return tsel() > 1 end   -- any track but track 1
-- TID[n][id] = "t<n>_<id>", each string built once and cached: the redraw
-- path reads these every frame and must not allocate
local TID = {}
for n = 2, NTRACKS do
  TID[n] = setmetatable({}, { __index = function(t, id)
    local v = "t" .. n .. "_" .. id
    t[id] = v
    return v
  end })
end
-- track n's id for a track 1 id: itself on track 1, or when track n has no
-- such param
local function tid_n(n, id)
  if id and n > 1 then
    local t = TID[n][id]
    if params.lookup[t] then return t end
  end
  return id
end
local function tid(id) return tid_n(tsel(), id) end
ctx.tid, ctx.tid_n, ctx.tsel = tid, tid_n, tsel
-- each track's mode and level (track 1's level is the engine's grain_level)
local MODE_ID, LEVEL_ID = { "mode" }, { "grain_level" }
for n = 2, NTRACKS do
  MODE_ID[n], LEVEL_ID[n] = "t" .. n .. "_mode", "t" .. n .. "_level"
end
ctx.MODE_ID, ctx.LEVEL_ID = MODE_ID, LEVEL_ID
-- MUTE AND SOLO (the seventy-third change, doc/mix-plan.md). The engine gets
-- a track's level times its gain here, 0 or 1 (the level's eng_map, so a
-- modulator's sends go through it too). The param keeps the level, and the
-- head runs on. ctx.solo is the track held alone (TRACKS K2 held), or nil:
-- it is heard muted or not, and no other track is.
ctx.MUTE_ID = { "mute_1", "mute_2", "mute_3", "mute_4" }
function ctx.track_gain(n)
  if ctx.solo then return n == ctx.solo and 1 or 0 end
  return pget(ctx.MUTE_ID[n], 0) == 1 and 0 or 1
end
-- one track's level to the engine again (its gain changed)
function ctx.level_send(n)
  local id = LEVEL_ID[n]
  if not (params.lookup[id] and engine[id]) then return end
  local v = pget(id, 1)
  if ctx.lfo and ctx.lfo.swinging(id) then v = ctx.lfo.swung(id, v) end
  engine[id](v * ctx.track_gain(n))
end
function ctx.set_solo(n)
  ctx.solo = n
  for k = 1, NTRACKS do ctx.level_send(k) end
end
-- THE LEVEL IN dB: E3 on TRACKS goes in steps of 0.5 dB, from silence
-- (below LEVEL_FLOOR) to the top of the param. Its range and its id are the
-- old ones, so a preset, a scene and a MIDI map hold.
ctx.LEVEL_FLOOR, ctx.LEVEL_TOP = -40, 1.5
function ctx.level_db(v)
  return v > 0 and 20 * math.log(v, 10) or -math.huge
end
function ctx.level_step(id, d)
  local k, floor_k = nil, ctx.LEVEL_FLOOR * 2
  local db = ctx.level_db(pget(id, 1))
  k = db < ctx.LEVEL_FLOOR and floor_k - 1 or math.floor(db * 2 + 0.5)
  k = k + d
  if k < floor_k then params:set(id, 0)
  else params:set(id, math.min(ctx.LEVEL_TOP, 10 ^ (k / 40))) end
end
local function flash_page()
  -- the proof it worked: the page name pops, now with its track
  ctx.page_flash = ctx.frame + math.floor(FPS * 0.7)
end
local function switch_track()
  params:set("track_sel", tsel() % NTRACKS + 1)
  flash_page()
  print("four: the focus is track " .. tsel())
end
-- MODE cycles PLAY->GRAIN->WARP->PV->CLOUD->PLAY, skipping OFF (a silence
-- pothole mid-set; stopping is STOP's job — OFF stays reachable in PARAMS).
-- Tracks 2 to 4 start OFF, so their first tap lands on PLAY. The options are
-- append-only (a PSET stores the index): CLOUD is the sixth.
local MODE_NEXT = { 5, 3, 4, 6, 2, 5 }
local function cycle_mode(id)
  local m = math.floor(pget(id, 5) + 0.5)
  params:set(id, MODE_NEXT[m] or 5)
end
local function cycle_type(id) params:set(id, (pget(id, 1) % 3) + 1) end
-- the EFFECT page's keys on track n. K2 is ON under the punch law (a tap
-- latches, a hold sounds the effect only while held), and off remembers the
-- type, so on brings back the effect you had; the first on is CHORUS. K3
-- steps the type and skips OFF (K2 is the off switch); held, it steps the
-- focus like VOICE and FILTER.
local last_effect = {}
local function effect_keys(n)
  local id = n == 1 and "effect" or ("t" .. n .. "_effect")
  last_effect[n] = 2
  return {
    k2 = {
      label = "ON",
      lit = function() return pget(id, 1) ~= 1 end,
      pon = function() params:set(id, last_effect[n]) end,
      poff = function()
        local e = pget(id, 1)
        if e ~= 1 then last_effect[n] = e end
        params:set(id, 1)
      end,
    },
    k3 = { label = "TYPE", tap = function()
        local e = math.floor(pget(id, 1) + 0.5)
        params:set(id, e >= #EFFECT_NAMES and 2 or e + 1)
      end, hold = switch_track, hold_label = "TRK " .. (n % NTRACKS + 1) },
  }
end
-- TAKE's SNAP on tracks 2 to 4: the track's window onto track 1's (the take
-- as you recorded it), and back. Through set_pair, widening edge first.
local snap_n = {}
local function snap_track(n)
  local a, b = tid_n(n, "pos_start"), tid_n(n, "pos_end")
  local lo, hi = pget(a, 0), pget(b, 1)
  if hi < lo then lo, hi = hi, lo end
  local l1, h1 = pget("pos_start", 0), pget("pos_end", 1)
  if h1 < l1 then l1, h1 = h1, l1 end
  if snap_n[n] and math.abs(lo - l1) < 1e-6 and math.abs(hi - h1) < 1e-6 then
    Mdeck.set_pair(a, b, snap_n[n][1], snap_n[n][2])
    snap_n[n] = nil
    take_say("SNAP - WINDOW BACK")
  else
    snap_n[n] = { lo, hi }
    Mdeck.set_pair(a, b, l1, h1)
    take_say("SNAP - ON TRACK 1")
  end
end
-- a track switched on with its window still at the default (the whole
-- 60s buffer) would play the empty buffer past the take for half its loop
-- (seen on the device): it starts on track 1's window instead
local function fit_new_track(n)
  if n < 2 then return end
  local a, b = tid_n(n, "pos_start"), tid_n(n, "pos_end")
  if pget(a, 0) <= 1e-6 and pget(b, 1) >= 1 - 1e-6 then
    local l1, h1 = pget("pos_start", 0), pget("pos_end", 1)
    if h1 < l1 then l1, h1 = h1, l1 end
    if h1 - l1 < 0.999 then Mdeck.set_pair(a, b, l1, h1) end
  end
end
local TAKE_REC = pk("REC", "rec")
local TAKE_UNDO = function() ctx.take_undo() end
-- per track: TAKE, VOICE and FILTER keys on track n, and the TRACKS page's
-- K2 (ON) and K3 (MODE) for the focus. ON: a tap latches, a hold plays the
-- track only while held (the punch law of every key). Off remembers the
-- mode, so on brings back the voice you had; the first on is PLAY.
local T_KEYS, T_ON, T_MODE, T_MUTE, T_SOLO = {}, {}, {}, {}, {}
local last_mode = {}
for n = 1, NTRACKS do
  local mid = MODE_ID[n]
  if n > 1 then
    local pre = "t" .. n .. "_"
    local nxt = "TRK " .. (n % NTRACKS + 1)
    T_KEYS[n] = {
      TAKE = {
        k2 = TAKE_REC,
        k3 = { label = "SNAP", tap = function() snap_track(n) end,
          hold = TAKE_UNDO, hold_label = "UNDO" },
      },
      VOICE = {
        k2 = pk("FRZ", pre .. "pv_freeze"),
        k3 = { label = "MODE", tap = function()
            if pget(mid, 1) == 1 then fit_new_track(n) end
            cycle_mode(mid)
          end, hold = switch_track, hold_label = nxt },
      },
      FILTER = {
        k2 = throw("OPEN", { pre .. "cutoff", pre .. "resonance" }, function()
          params:set(pre .. "cutoff", filter_open_cutoff(pget(pre .. "filt_type", 1)))
          params:set(pre .. "resonance", 0)
        end, "OPEN" .. n),
        k3 = { label = "TYPE", tap = function() cycle_type(pre .. "filt_type") end,
          hold = switch_track, hold_label = nxt },
      },
      EFFECT = effect_keys(n),
    }
  end
  last_mode[n] = 5
  T_ON[n] = {
    label = "ON",
    lit = function() return pget(mid, 1) ~= 1 end,
    pon = function()
      if pget(mid, 1) == 1 then fit_new_track(n) end
      params:set(mid, last_mode[n])
    end,
    poff = function()
      local m = pget(mid, 1)
      if m ~= 1 then last_mode[n] = m end
      params:set(mid, 1)
    end,
  }
  -- MODE's tap cycles the voices and skips OFF; held, it turns the track
  -- OFF (K2 mutes a track that is on: the head runs on, and no CPU is saved)
  T_MODE[n] = { label = "MODE", tap = function()
    if pget(mid, 1) == 1 then fit_new_track(n) end
    cycle_mode(mid)
  end, hold = function() T_ON[n].poff() end, hold_label = "OFF" }
  -- K2 on a track that is on: MUTE on a tap, SOLO while it is held (from the
  -- frame a tap is over). key_def picks this, or T_ON for a track that is off.
  local function solo_on() ctx.set_solo(n) end
  local function solo_off() ctx.set_solo(nil) end
  local function mute() ptoggle(ctx.MUTE_ID[n]) end
  T_MUTE[n] = { label = "MUTE", lit = function() return pget(ctx.MUTE_ID[n], 0) == 1 end,
    tap = mute, hold = solo_on, hold_label = "SOLO", hold_at = TAP_FRAMES, release = solo_off }
  T_SOLO[n] = { label = "SOLO", lit = function() return true end,
    tap = mute, hold = solo_on, hold_label = "SOLO", hold_at = TAP_FRAMES, release = solo_off }
end

-- ---- the routing (four) -------------------------------------------------
-- The S-4's sends: each track's filtered output can feed any other track's
-- filter, `send_<from>_<to>`, twelve in all. SPACE: each track also has its
-- own send into the shared delay (to = 5, `fx_dly` / `t<n>_fx_dly`) and
-- reverb (to = 6, `fx_rev` / `t<n>_fx_rev`), at 0 by default: a track goes
-- into the delay and the reverb only as far as you send it. ROUTES walks them row by row (row = from,
-- column = to). On TRACKS with K1 held, the grid shows and the encoders
-- reach the FOCUSED track's row: K1+E2 picks where it sends (`route_sel`),
-- K1+E3 how much.
local FX_TO = { [NTRACKS + 1] = "fx_dly", [NTRACKS + 2] = "fx_rev" }
local ROUTES, ROW_FIRST = {}, {}
local ROW_N = NTRACKS + 1   -- cells per row: three tracks and the two FX
for from = 1, NTRACKS do
  ROW_FIRST[from] = #ROUTES + 1
  for to = 1, NTRACKS + 2 do
    if FX_TO[to] then
      local id = from == 1 and FX_TO[to] or ("t" .. from .. "_" .. FX_TO[to])
      ROUTES[#ROUTES + 1] = { from = from, to = to, id = id, fx = true }
    elseif from ~= to then
      ROUTES[#ROUTES + 1] = { from = from, to = to, id = "send_" .. from .. "_" .. to }
    end
  end
end
ctx.ROUTES = ROUTES
-- the cell under the cursor, always in the focused track's row
local function route_idx()
  local k = clamp(math.floor(pget("route_sel", 1) + 0.5), 1, #ROUTES)
  if ROUTES[k].from ~= tsel() then k = ROW_FIRST[tsel()] end
  return k
end
local function route_cur() return ROUTES[route_idx()] end
ctx.route_cur = route_cur
-- K1+E2 on TRACKS: the next or previous destination in the focus's row
local function route_step(d)
  local first = ROW_FIRST[tsel()]
  local k = clamp(route_idx() + (d > 0 and 1 or -1), first, first + ROW_N - 1)
  params:set("route_sel", k)
end

-- page key defs (+ each page's `erase`: what the K1+K3 arc wipes)
local KEYS = {
  TAKE = {
    k2 = TAKE_REC,
    -- tap = SNAP, hold to the arc = UNDO (the eraser's gesture, without K1).
    -- SNAP moved from the press to the release, so a hold never snaps first
    k3 = { label = "SNAP", tap = snap_window,
      hold = TAKE_UNDO, hold_label = "UNDO" },
    erase = function() pulse("clear_rec") end,   -- audio: NOT undoable
  },
  VOICE = {
    k2 = pk("FRZ", "pv_freeze"),
    -- tap = MODE (cycle_mode), hold to the arc = the track switch
    k3 = { label = "MODE", tap = function() cycle_mode("mode") end,
      hold = switch_track, hold_label = "TRK 2" },
  },
  -- (TRACKS's keys follow the focus: key_def picks T_ON / T_MODE; these
  -- are track 1's, the shape doc/controls.md documents)
  TRACKS = { k2 = T_MUTE[1], k3 = T_MODE[1] },
  TAPE = {
    k2 = pk("REC", "tape_rec"),
    k3 = pk("REV", "tape_reverse"),
    erase = function()
      -- disarm first: wiping while armed just
      -- re-records the input into the freshly cleared loop
      params:set("tape_rec", 0)
      Mtape.clear_buffer()
      ctx.clear_twave()
      params:set("tape_freeze", 0)
      params:set("loop_start", 0)
      params:set("loop_end", 1)
    end,
  },
  FILTER = {
    -- OPEN as a throw: hold = a sweep that returns by itself, tap = park
    -- it open, tap again = back to the carved tone
    k2 = throw("OPEN", { "cutoff", "resonance" }, function()
      params:set("cutoff", filter_open_cutoff(pget("filt_type", 1)))
      params:set("resonance", 0)
    end),
    k3 = { label = "TYPE", tap = function() cycle_type("filt_type") end,
      hold = switch_track, hold_label = "TRK 2" },
  },
  EFFECT = effect_keys(1),
  DELAY = {
    -- INF pins the feedback near max (a dub hold); KILL cuts the echo send.
    -- both round-trip: tap latches, tap again restores the prior value.
    k2 = throw("INF", { "delay_fb" }, function()   -- dub grab: pin the loop
      params:set("delay_fb", 1)   -- knob max -> ~0.98 fb, a self-sustaining hold
    end),
    k3 = throw("KILL", { "delay_mix" }, function()  -- cut the echo send
      params:set("delay_mix", 0)
    end),
  },
  REVERB = {
    -- WASH swells the tail to a near-infinite hall; BLOOM surges shimmer.
    k2 = throw("WASH", { "rev_decay" }, function()  -- freeze the space
      params:set("rev_decay", 30)
    end),
    -- BLOOM always INCREASES: it read a `ctx.shimmer_mem` that nothing in the
    -- codebase ever wrote, so it was permanently the 0.6 fallback — and pulling
    -- shimmer DOWN whenever it already sat above that, which is the opposite of
    -- a surge. Double it, floor at 0.6, ceiling at full.
    k3 = throw("BLOOM", { "shimmer" }, function() -- shimmer surge
      local now = pget("shimmer", 0)
      params:set("shimmer", math.min(1, math.max(0.6, now * 2)))
    end),
  },
  MIX = {
    -- ENG and TAPE are two throws of the same `mix`, so engaging one restores
    -- and un-latches the other first — both pills can never light at once and
    -- the crossfader always returns to its true home. That used to be written
    -- out here by hand; the throw engine now does it for any shared param.
    k2 = throw("ENG", { "mix" }, function()   -- crossfade stab to the engine
      params:set("mix", 0)
    end),
    k3 = throw("TAPE", { "mix" }, function()
      params:set("mix", 1)
    end),
  },
  PADS = {
    -- a pad under the punch law: hold = gate the slice, tap = fire it
    -- short. gate: the release ALWAYS closes the voice — a latched voice
    -- is a drone, and the drone already exists.
    k2 = { label = "PAD", gate = true,
      lit = function() return ctx.pad_held[8] ~= nil end,
      pon = function() ctx.pad_trigger(8, pget("seq_slice", 0), 1) end,
      poff = function() ctx.pad_trigger(8, 0, 0) end },
    -- notes -> pads (poly) or the drone. PADS has no material of its own (the
    -- take is TAKE's), so no page erase — K1+K3 stays the global DRY here.
    k3 = pk("ROUTE", "pad_input"),
  },
  MOTION = {
    k2 = pk("REC", "motion_rec"),
    k3 = pk("PLAY", "motion_play"),
    -- the selected row's: a lane is cleared, a modulator let go (OFF, depth 0)
    erase = function()
      local f = math.floor(pget("mod_focus", 1) + 0.5)
      if f > 1 then
        params:set("lfo" .. (f - 1) .. "_depth", 0)
        params:set("lfo" .. (f - 1) .. "_target", 1)
      else
        ctx.motion.clear_lane()
      end
    end,
  },
  SCENE = {
    -- RCL under the punch law — hold = PEEK (borrow the scene via the
    -- morph engine; release sweeps you home), tap = COMMIT. on the ◄ cell
    -- (slot 0) a tap is the way back (safe restore). CAP captures into the
    -- selected slot — into ◄ it marks the way-back state by hand.
    k2 = { label = "RCL", hold_label = "PEEK",   -- (doc/controls.md's word)
      lit = function() return ctx.peek_on == true end,
      pon = function()
        -- the slot is resolved at the PRESS: a running orbit re-aims the
        -- selector every leg, and the tap must recall what was under the
        -- finger, not what the wander picked a moment later
        local sel = math.floor(pget("scene_slot", 1) + 0.5)
        ctx.rcl_slot = sel
        if sel >= 1 and ctx.scene.slots[sel] then
          ctx.peek_on, ctx.peek_back, ctx.peek_at = true, false, ctx.frame
        end
      end,
      tap = function()
        ctx.peek_on = false
        if ctx.rcl_slot then params:set("scene_slot", ctx.rcl_slot) end
        -- the landing zeroes the morph amount itself (mscenes' land), and
        -- only once the scene has actually landed, so a BEAT/BAR queue
        -- does not bounce scene -> LIVE -> scene around the sync point
        pulse("scene_recall")
      end,
      poff = function()   -- punch release: it was borrowed — sweep home
        -- only when the peek actually engaged: pon declines on an empty slot
        -- and on ◄, and ramping "home" then would drag a morph someone parked
        -- (a latched sweep, a MIDI fader) down to zero for nothing
        if ctx.peek_on then
          ctx.peek_on = false
          ctx.peek_back = true
        end
      end },
    k3 = { label = "CAP", act = function() pulse("scene_capture") end },
    -- the slot selected when K1+K3 went DOWN, not when the arc lands a second
    -- later: a running orbit re-aims the selector every leg, and clearing the
    -- slot it wandered to would destroy a scene you did not pick
    erase = function() Mscenes.clear(ctx.k13_slot) end,
  },
}

-- the global alt pair — identical on every page
local ALT_STOP = pk("STOP", "stop_all")
local ALT_DRY = { label = "DRY", dryerase = true }

-- HEAL parks the erosion decay (round-trips like every throw). It snapshots
-- regen as well as erode: raising erode ZEROES regen through the interlock,
-- so a throw that remembered only erode handed back an instrument with the
-- performer's regen setting silently gone. It lives on VOICE's K2 in PLAY
-- mode only — the one mode where erosion runs (FRZ, which it displaces, is
-- inert in PLAY: pv_freeze holds the PV/clouds voices). SCAR, the old
-- throw-to-full, retired to the erode knob itself (VOICE K1+E2 in PLAY).
local VOICE_HEAL = throw("HEAL", { "erode", "regen" }, function()
  params:set("erode", 0)
end)

local function key_def(n)
  if ctx.alt then
    return n == 2 and ALT_STOP or ALT_DRY
  end
  local page = PAGES[ctx.page]
  if TRACK_PAGES[page] and track2() then
    local tk = T_KEYS[tsel()][page]
    return n == 2 and tk.k2 or tk.k3
  end
  if page == "TRACKS" then
    local t = tsel()
    if n == 3 then return T_MODE[t] end
    if ctx.solo == t then return T_SOLO[t] end
    return pget(MODE_ID[t], 1) == 1 and T_ON[t] or T_MUTE[t]
  end
  -- VOICE K2 is mode-contextual, like its encoders: PLAY = HEAL, else FRZ
  if page == "VOICE" and n == 2 and pget("mode", 5) == 5 then
    return VOICE_HEAL
  end
  local defs = KEYS[page]
  if not defs then return nil end
  return n == 2 and defs.k2 or defs.k3
end

-- what the eraser would wipe on the current page (nil = nothing here; the
-- footer only draws the arc when there is something to erase)
local function page_erase()
  local defs = KEYS[PAGES[ctx.page]]
  return defs and defs.erase or nil
end

-- ============================================================================
-- encoders
-- ============================================================================
-- which params each page's encoders address: { e2, e2_alt, e3, e3_alt }.
-- targets starting with "@" are compound gestures resolved in enc().
local ENC_MAP = {
  TAKE   = { "pos_start", "@win_move", "pos_end", "@rec_src" },
  VOICE  = { "scan", "scan", "pitch", "pitch" }, -- face is mode-contextual
  -- four: the TRACKS hub. E2 the focus, E3 its level; K1 held, its
  -- sends: K1+E2 where to, K1+E3 how much
  TRACKS = { "track_sel", "@route_to", "@trk_level", "@route_amt" },
  TAPE   = { "tape_rate", "tape_pre", "loop_end", "cut_source" },
  FILTER = { "cutoff", "drive", "resonance", "crush" },
  -- the focused track's effect slot: its two knobs. K1 held has nothing here
  EFFECT = { "effect_amt", "effect2_amt", "effect_rate", "effect2_rate" },
  DELAY  = { "delay_mix", "delay_time", "delay_fb", "delay_sync" },
  REVERB = { "rev_mix", "rev_size", "rev_decay", "rev_damp" },
  -- (the seventieth change) K1 held is the input's two ways to the output:
  -- the norns MONITOR and four's DRY/WET. The input gain stays in PARAMS
  -- > LEVELS, where norns has it.
  MIX    = { "mix", "monitor_level", "out_level", "dry_wet" },
  PADS   = { "seq_slice", "pad_voice", "pad_pitch", "voice_rel" },
  -- E2 walks the lanes and then the two modulator rows (@mo_sel); with a
  -- modulator row selected the other three are its own (MOTION_LFO below)
  MOTION = { "@mo_sel", "motion_len", "motion_depth", "motion_bars" },
  -- the crossfader: E2 picks A (LIVE or a slot), E3 picks B (the slot K2
  -- recalls and K3 captures into), both with no shift, and K1+E3 fades
  -- between them. K1+E2 is the TEMPO (the seventieth change: the clock's
  -- page, beside the recall quantize). The orbit's drift and reach, and the
  -- recall quantize, are set-and-forget: they live in PARAMS.
  SCENE  = { "scene_slot_a", "@tempo", "scene_slot", "scene_morph_amt" },
}

-- VOICE face pair per engine mode (the S-4 move: the encoders always
-- control what you're hearing). mode options: OFF GRAIN WARP PV PLAY CLOUD.
local VOICE_FACE = {
  { "scan", "pitch" },            -- OFF (the universal pair still)
  { "size", "density" },          -- GRAIN
  { "warp_window", "warp_rand" }, -- WARP
  { "scan", "pitch" },            -- PV
  { "scan", "pitch" },            -- PLAY
  { "size", "density" },          -- CLOUD
}
-- GRAIN's K1 pair: SPRAY (how far grains land from the head) and the pitch
-- spread. scan and pitch stay on K1 in every other mode.
local GRAIN_ALT = { "pos_jitter", "grain_pitch_spread" }

-- MOTION with a modulator row selected (mod_focus 2 to 5): E3 its depth,
-- K1+E2 its period, K1+E3 its target. E2 stays the row selector. Picking a
-- target puts the modulator on the focused track (K1+E1 picks the track).
local MOTION_LFO, LFO_TRACK = {}, {}
for i = 1, Mlfo.N do
  local p = "lfo" .. i .. "_"
  MOTION_LFO[i] = { "@mo_sel", p .. "period", p .. "depth", p .. "target" }
  LFO_TRACK[p .. "target"] = p .. "track"
end

-- the param id addressed by encoder n (2 or 3), page + alt + mode aware
local function enc_param(n)
  local page = PAGES[ctx.page]
  if page == "MOTION" then
    local f = math.floor(pget("mod_focus", 1) + 0.5)
    local m = MOTION_LFO[f - 1]
    if m then
      if n == 2 then return ctx.alt and m[2] or m[1] end
      if n == 3 then return ctx.alt and m[4] or m[3] end
      return nil
    end
  end
  if page == "VOICE" and not ctx.alt then
    local f = VOICE_FACE[clamp(pget(tid("mode"), 5), 1, 6)]
    return tid(n == 2 and f[1] or f[2])
  end
  if page == "VOICE" and ctx.alt and pget(tid("mode"), 5) == 2 then
    return tid(n == 2 and GRAIN_ALT[1] or GRAIN_ALT[2])
  end
  -- VOICE's alt pair is mode-contextual too: in PLAY mode the face already IS
  -- scan/pitch, so the alt copy was redundant there — it now carries the
  -- EROSION controls, which only ever work in PLAY mode (the engine runs its
  -- erosion head in PLAY alone). every other mode keeps alt scan/pitch, so
  -- pitch stays reachable under a GRAIN or WARP face.
  -- (track 2 has no erosion: its alt pair stays scan/pitch, below)
  if page == "VOICE" and ctx.alt and pget("mode", 5) == 5 and not track2() then
    return n == 2 and "erode" or "wear"
  end
  local m = ENC_MAP[page]
  if not m then return nil end
  -- explicit, NOT `alt and m[2] or m[1]`: a nil alt slot (MOTION/SCENE) must be
  -- a genuine no-op, not fall through to the base param and edit it while K1 is
  -- held (which could wipe the wrong MOTION lane and leak a value in the footer)
  local id
  if n == 2 then
    if ctx.alt then id = m[2] else id = m[1] end
  elseif n == 3 then
    if ctx.alt then id = m[4] else id = m[3] end
  end
  if id and TRACK_PAGES[page] then return tid(id) end
  return id
end

-- compound encoder gesture: slide a lo/hi pair together, width preserved,
-- with the same span-scaled fine step the edges get. The two writes go
-- through Mdeck.set_pair, the one widening-edge-first writer.
local function move_pair(lo_id, hi_id, d)
  local lo, hi = pget(lo_id, 0), pget(hi_id, 1)
  if hi < lo then lo, hi = hi, lo end
  local p = params:lookup_param(lo_id)
  local q = (p and p.controlspec and p.controlspec.quantum) or 0.01
  local width = hi - lo
  local nlo = clamp(lo + fine_delta(lo_id, d) * q, 0, 1 - width)
  Mdeck.set_pair(lo_id, hi_id, nlo, nlo + width)
end

-- K1+K3 held to the arc: the erase fires AT the threshold (not on the
-- release), from the redraw clock, so the arc is a promise that lands.
-- the same tick animates the scene PEEK ramp: holding RCL drives the morph
-- amount toward the slot (~4 frames in), releasing sweeps it home — all
-- through the scene_morph_amt param, so motion capture and MIDI stay true.
-- The ramp waits until the press is a hold, in every recall mode: a tap
-- recalls, and a ramp that had already run would move the sound before the
-- recall is due (a BEAT or BAR queue) or turn a GLIDE into a jump.
-- THE NORNS MENU takes a key's release (K1 tapped while K2 is held): a hold
-- that waits is called off, and a SOLO ends, or it would stay with no key.
function ctx.menu_keys()
  if not (norns.menu and norns.menu.status and norns.menu.status()) then return end
  for n = 2, 3 do
    local st = key_state[n]
    if st.def and st.def.hold then
      st.fired, st.aborted, st.def = true, true, nil
      ctx.held[n] = false
    end
  end
  if ctx.solo then ctx.set_solo(nil) end
end
local function tick_keys()
  -- a key held to the arc on a def with a `hold` (TAKE K3 = UNDO) fires AT
  -- the threshold, the same promise the eraser keeps
  for n = 2, 3 do
    local st = key_state[n]
    if st.def and st.def.hold and not st.fired then
      if ctx.page ~= st.page then
        st.fired, st.aborted = true, true   -- E1 left the page mid-hold: abort
      elseif ctx.frame - st.frame >= (st.def.hold_at or ERASE_FRAMES) then
        st.fired = true
        st.def.hold()
      end
    end
  end
  if ctx.k13_frame and not ctx.k13_fired
      and ctx.frame - ctx.k13_frame >= ERASE_FRAMES then
    local e = page_erase()
    if e then e() end
    ctx.k13_fired = true
  end
  if ctx.peek_on then
    if ctx.frame - (ctx.peek_at or 0) >= TAP_FRAMES then
      local a = pget("scene_morph_amt", 0)
      if a < 1 then params:set("scene_morph_amt", clamp(a + 0.34, 0, 1)) end
    end
  elseif ctx.peek_back then
    local a = pget("scene_morph_amt", 0)
    if a > 0 then
      params:set("scene_morph_amt", clamp(a - 0.34, 0, 1))
    else
      ctx.peek_back = false
    end
  end
end

-- the footer draws what the encoders and keys currently address
ctx.enc_param = enc_param
ctx.key_def = key_def
ctx.page_erase = page_erase
ctx.ERASE_FRAMES = ERASE_FRAMES
ctx.TAP_FRAMES = TAP_FRAMES
-- the frame key n's hold began on, while a def with a `hold` is held on the
-- page that took the press (nil otherwise): the footer draws its arc from
-- it, full once the hold has fired, until the key comes up
-- The def comes back too: the arc's word is the press-time def's, never a
-- fresh lookup (K1 down would read the DRY def). An aborted hold draws none.
function ctx.hold_frame(n)
  local st = key_state[n]
  if st and st.def and st.def.hold and not st.aborted and st.page == ctx.page then
    return st.frame, st.def
  end
end

-- ============================================================================
-- polyphonic pad voices
-- ============================================================================
-- a pad's slice point: the centre of the i-th eighth OF THE TAKE — i.e. of
-- the current window, not of the 60s buffer. this is the one definition of
-- "slice i" in the instrument: the PADS audition and the MIDI/grid note pads
-- both resolve through here.
-- it was buffer-relative ((i+0.5)/8) until now, which meant a normal take —
-- record a phrase, the rec action snaps the window to it — left 7 of the 8
-- pads pointing at silence out in the empty buffer; this is that fix, shared.
-- rate stays fixed at 1 (per-pad rate is a later knob). type is per-pad.
-- SLICE voices are a PlayBuf reading FORWARD from the point, so they anchor
-- at the slice's START — the chop's attack (firing from the centre skipped
-- the transient the pad was chopped for). GRAIN clouds spread around the
-- point, so they keep the centre. one law, two anchors.
-- CHOPPED slices, when there are any: ctx.pad_cuts is a sorted list of
-- boundaries in buffer fractions, one more entry than there are slices (the
-- last is where the final slice ends). nil = the even law below.
-- Chopped boundaries are ABSOLUTE positions in the buffer, not window-relative,
-- so whoever replaces the material drops them (ctx.pads_uncut).
-- pad i -> its slice boundaries. A chop finds however many transients are
-- there, which is usually not eight, so the pads WRAP onto what exists — the
-- same "more keys than pads" idiom the MIDI and grid note paths already use.
-- With five slices, pads 6-8 replay slices 1-3 rather than falling back to
-- even eighths that would overlap the chopped ones.
local function pad_cut(i)
  local c = ctx.pad_cuts
  local n = c and (#c - 1) or 0
  if n < 1 then return nil end
  local j = i % n
  return c[j + 1], c[j + 2], j
end

local function pad_pos(i, at_start)
  local a, b = pad_cut(i)
  if a then return at_start and a or (a + (b - a) * 0.5) end
  local lo, _, span = window_bounds()
  return lo + (i + (at_start and 0 or 0.5)) / ctx.pad_n * span
end

-- how LONG a slice is, in the same buffer-fraction units as pad_pos. The
-- engine's slice voice needs this or its PlayBuf runs from the slice start
-- clean through the rest of the 60s buffer — a pad playing its chop and then
-- everything after it, while the PADS page draws eight bounded cells.
local function pad_len(i)
  local a, b = pad_cut(i)
  if a then return b - a end
  local _, _, span = window_bounds()
  return span / ctx.pad_n
end

-- which SLICE a pad plays (0-based). Differs from the pad number once a chop
-- has found fewer than eight, which is why the page labels cells with this.
function ctx.pad_slice_of(i)
  local _, _, j = pad_cut(i)
  return j or i
end

-- back to even slices. Chopped boundaries point at particular audio, so
-- anything that replaces the buffer has to let them go — the same rule the
-- window's SNAP memory follows.
-- An autosample's notes (ctx.pad_notes) belong to its cuts and go with them.
function ctx.pads_uncut() ctx.pad_cuts, ctx.pad_notes = nil, nil end

-- TIGHTEN: pull the window in onto the sound. Pressing REC and then playing
-- leaves your reaction time at the head of the take, and letting go late
-- leaves room tone at the tail — the rec-stop window snaps to where the record
-- HEADS were, which is not where the sound is.
-- NON-DESTRUCTIVE on purpose: this only moves pos_start/pos_end. It never
-- rewrites the buffer, so it is always undoable by moving the edges back (and
-- TAKE K3 SNAP remembers where you were).
-- Lua cannot read the engine buffer, so every analysis of the take works on a
-- dump of it: the empty check, the dump, the failure message and the temp
-- file live here once. `scan(tmp, lo, hi)` runs inside the dump's own
-- coroutine (so it can yield) over the CURRENT window; the temp file is
-- removed after it returns. Every scan shares the one temp file: take_to_wav
-- holds its guard until `scan` returns, so no second dump can overwrite the
-- file under a scan still reading it. `background`: see take_to_wav.
local function scan_take(tag, scan, background)
  if not ctx.wave_any then
    print("four: " .. tag .. " — nothing recorded yet")
    return
  end
  local tmp = norns.state.data .. "mscan-tmp.wav"
  ctx.take_to_wav(tmp, function(ok)
    if not ok then
      print("four: " .. tag .. " — the take dump did not land")
      return
    end
    local lo, hi = window_bounds()
    scan(tmp, lo, hi)
    os.remove(tmp)
  end, background)
end

ctx.scan_take = scan_take   -- the autosampler cuts its notes on their attacks

function ctx.take_tighten()
  scan_take("TIGHTEN", function(tmp, lo, hi)
    local a, b = Mwav.onset_bounds(tmp, lo, hi, BUF_SECS, nil, ctx.task_yield)
    if not a then
      print("four: TIGHTEN — the window is silent, left alone")
      return
    end
    -- a hair of room either side so a soft attack is never clipped off
    local pad = 0.005 / BUF_SECS
    a = clamp(a - pad, lo, hi)
    b = clamp(b + pad, lo, hi)
    if b - a < 0.002 then
      print("four: TIGHTEN — too little sound to window, left alone")
      return
    end
    -- both edges move INWARD (a >= lo, b <= hi), so the pair cannot cross
    Mdeck.set_pair(WIN[1], WIN[2], a, b)
    print(string.format("four: TIGHTEN — window is %.2fs of sound (was %.2fs)",
      (b - a) * BUF_SECS, (hi - lo) * BUF_SECS))
  end)
end

-- CHOP: put the pads on the material's own attacks instead of eight arbitrary
-- eighths. The transients are found in the dumped take (Mwav.transient_cuts).
-- The engine already takes a position AND a length per note, so nothing here
-- needs a new command — the slices just stop being uniform.
function ctx.pad_chop()
  scan_take("CHOP", function(tmp, lo, hi)
    local cuts = Mwav.transient_cuts(tmp, lo, hi, ctx.pad_n, BUF_SECS,
      ctx.task_yield)
    if not cuts or #cuts < 2 then
      ctx.pads_uncut()
      print("four: CHOP found no transients — pads back to even slices")
      return
    end
    cuts[#cuts + 1] = hi            -- the last slice runs to the window end
    ctx.pad_cuts, ctx.pad_notes = cuts, nil
    print(string.format("four: CHOP — %d slices, on the attacks", #cuts - 1))
  end)
end

-- drop a voice id from the pad steal order (it is in there at most once)
local function pad_order_remove(id)
  local o = ctx.pad_order
  for k = 1, #o do
    if o[k] == id then table.remove(o, k); return end
  end
end

-- spawn/release a voice for pad `i` under a stable `id` (so note_off matches
-- the note_on that started it). z=1 press, z=0 release. `auto`: a machine
-- played it (the sequencer), which is not a hand on the instrument. `semis`
-- retunes this one note (a key on an autosample's multisample).
function ctx.pad_trigger(id, i, z, auto, semis)
  -- playing pads counts as presence (idle dim)
  if not auto then ctx.last_input = ctx.frame end
  if z == 1 then
    if ctx.pad_held[id] and engine.note_off then engine.note_off(id) end
    if engine.note_on then
      -- per-pad SOUND-LOCK: this pad's own pitch (semitones -> rate) + voice, at
      -- the pad voice level (chord-safe default that won't slam the limiter)
      -- a slice past the eighth pad (an autosample's multisample) has no
      -- lock of its own: it plays from its start, a SLICE voice
      local pt = ctx.pad_type[i] or (i >= ctx.pad_n and 1 or 0)
      engine.note_on(id, pad_pos(i, pt > 0),
        2 ^ (((ctx.pad_pitch[i] or 0) + (semis or 0)) / 12),
        pt, pget("pad_level", 0.3), pad_len(i))
    end
    -- the engine's noteOff + noteOn above moves a re-struck id to the END of
    -- its steal queue, so this mirror does exactly the same. Keeping the old
    -- position made the two steal DIFFERENT voices, and the one lua forgot
    -- kept sounding with nothing left that could release it.
    pad_order_remove(id)
    ctx.pad_order[#ctx.pad_order + 1] = id
    ctx.pad_held[id] = i    -- store the pad index (0 is truthy) for the display
    -- MIRROR the engine's voice steal. Over the cap it release-steals the
    -- OLDEST voice and tells lua nothing, so the PADS page went on drawing
    -- cells that had already stopped and the used/cap readout over-counted.
    -- Same cap, same order, so the picture matches what is sounding.
    local cap = math.floor(pget("voices", 8) + 0.5)
    while #ctx.pad_order > cap do
      local old = table.remove(ctx.pad_order, 1)
      ctx.pad_held[old] = nil
    end
  elseif ctx.pad_held[id] then
    if engine.note_off then engine.note_off(id) end
    ctx.pad_held[id] = nil
    pad_order_remove(id)
  end
end

-- MIDI/grid note routing: in pad mode a note plays pad (note mod 8) as a
-- polyphonic voice (note_off on release); otherwise it retunes the mono
-- drone `pitch` exactly as before. `pitch` is the chromatic rate the caller
-- already computed for the drone path. `note`, a MIDI note number, comes
-- from a MIDI key: on an autosample's multisample (ctx.pad_notes) it plays
-- the slice of the nearest sampled note, retuned by the difference.
function ctx.route_note(id, pitch, pad_idx, z, note)
  ctx.last_input = ctx.frame   -- MIDI/grid/typing notes count as presence
  if pget("pad_input", 0) == 1 then
    if note and ctx.pad_notes then
      local j, semis = Msample.slice_of(note)
      ctx.pad_trigger(id, j, z, nil, semis)
      return
    end
    ctx.pad_trigger(id, pad_idx % ctx.pad_n, z)
  elseif z == 1 then
    params:set("pitch", pitch)
  end
end

-- release every sounding pad voice (leaving pad mode, cleanup, panic)
function ctx.pads_all_off()
  for id in pairs(ctx.pad_held) do
    if engine.note_off then engine.note_off(id) end
    ctx.pad_held[id] = nil
  end
  for k = #ctx.pad_order, 1, -1 do ctx.pad_order[k] = nil end
end

-- SOUND-LOCK editor sync: point the pad_voice/pad_pitch editor params at the pad
-- now under the cursor (guarded, so their actions don't write the value back).
function ctx.pad_edit_sync()
  local i = ctx.pad_cursor
  ctx.pad_sync = true
  if params.lookup["pad_voice"] then params:set("pad_voice", (ctx.pad_type[i] or 0) + 1) end
  if params.lookup["pad_pitch"] then params:set("pad_pitch", ctx.pad_pitch[i] or 0) end
  ctx.pad_sync = false
end

-- delete the recording, and load a source other than the live input. the
-- engine's 60s buffer is what everything slices (window, drone, pads). (the
-- TAPE deck's own CLR is on the TAPE page — that's the softcut loop, a
-- different deck entirely.)

-- THE TAKE'S GENERATION. Every writer that puts new material in the buffer (a
-- record pass, a clear, a load, a PSET restore) bumps it. A background
-- sample-rate conversion notes it when it starts and drops its result if it
-- moved: a conversion takes seconds on a Pi, and landing late used to
-- overwrite whatever had happened in the meantime, including a live take that
-- existed nowhere else.
local take_gen = 0

-- the strip needs a repaint once regen or erosion stops writing (see
-- tick_take_strip below). Declared here so a replacement can drop it.
local strip_stale, strip_quiet = false, 0
-- the take dump (ctx.take_to_wav, further down), declared here because
-- tick_take_strip waits for it
local export_clock
local export_bg = false   -- the running dump is a background one
local export_next         -- { out, done }: the dump waiting behind it

-- the one rule for "the buffer now holds different material". The erosion
-- age, the remembered SNAP window and the chop all belonged to the old
-- material, and take_len bounds what a PSET save writes: the new material's
-- length (`dur` seconds), or the whole buffer when the length is unknown.
-- Every replacer goes through here, so none can forget a part of it.
local function buffer_replaced(dur)
  take_gen = take_gen + 1
  strip_stale = false   -- the new material's strip is drawn from its own file
  Mpages.erosion_reset()
  ctx.snap_forget()
  ctx.pads_uncut()
  ctx.take_len = dur and clamp(dur / BUF_SECS, 0.002, 1) or 1
end

-- ...and a clear is a replacement by nothing: a later save writes nothing
-- (and deletes the stale pair)
local function buffer_cleared()
  buffer_replaced()
  ctx.take_len = 0
end

-- regen and erosion rewrite the buffer on the engine side, where lua cannot
-- see it, so the take's strip went on showing audio that was no longer there.
-- Once neither has written for a second, the take is dumped and the strip
-- repainted from the dump. Dropped if the take changed meanwhile (a clear, a
-- load, a new pass), so a late repaint can never draw old audio over new
-- material. It runs in the background: a performer's CHOP, TIGHTEN or EXPORT
-- that arrives during it waits for it instead of being refused.
function ctx.refresh_take_strip()
  if not ctx.wave_any then return end
  local g = take_gen
  scan_take("REPAINT", function(tmp)
    if g == take_gen then Mpages.repaint_wave(tmp) end
  end, true)
end

-- START ON SOUND. An arm records at once, as always, and this watches for
-- the first frame where what is written crosses `rec_thresh`. With `rec_wait`
-- on at that moment, the take starts there: from where the head stood on the
-- last QUIET frame, less one more frame. The onset came after that quiet
-- frame, and the extra frame covers rec_phase arriving a frame late. That
-- margin grows with a late frame, where a fixed pre-roll would not.
-- Recording from the arm, not from the crossing, is what keeps the attack.
-- The start only moves forward within the pass. A pass that wrapped past the
-- buffer end before the sound came starts at the buffer's start.
-- An overdub never waits: the old material under the new is the take too.
-- `rec_wait` is read every frame, not latched at the arm, so turning it on or
-- off while WAIT shows takes effect at once.
local REC_PREROLL = 1 / FPS

-- Does this engine put the write head at 0 for a new take? The command
-- `rec_track` took one argument until the forty-ninth change. An arity
-- change does not move the command count, so the count cannot tell an old
-- engine: its format can. (The offscreen norns has no format table.)
local warned_old_head = false
function ctx.head_resets()
  local c = engine.commands and engine.commands.rec_track
  if c and c.fmt ~= "ii" and c.fmt ~= "iii" then
    if not warned_old_head then
      warned_old_head = true
      print("four: the engine is older than the script (rec_track) - SYSTEM > RESTART. "
        .. "Until then a take starts where the write head is.")
    end
    return false
  end
  return true
end
-- RELAY (C13 of doc/signature-workflow.md): does this engine take a source
-- with rec_track? Its third argument came with the fifty-ninth change.
function ctx.relay_ok()
  local c = engine.commands and engine.commands.rec_track
  return not c or c.fmt == "iii"
end
-- the take's source as the engine numbers it: 0 the line input, 1 to 4 a
-- track, 5 the mix (`rec_source` is 1 IN, 2 to 5 T1 to T4, 6 MIX)
local function rec_src()
  return math.floor(pget("rec_source", 1) + 0.5) - 1
end
ctx.rec_src = rec_src
-- point io at track n's buffer pair. `how`: 0 (or false) goes on from the
-- write head, 1 (or true) opens a new take there (the write head goes to the
-- start of the pair), 2 is an ALIGNED overdub (the sixty-seventh change: it
-- starts at the track's read head and loops in its window). The source goes
-- with it.
local function rec_track(n, how)
  if not engine.rec_track then return end
  how = (how == true or how == 1) and 1 or (how == 2 and 2 or 0)
  if ctx.relay_ok() then
    engine.rec_track(n - 1, how, rec_src())
  elseif ctx.head_resets() then
    engine.rec_track(n - 1, math.min(how, 1))
  else
    engine.rec_track(n - 1)
  end
end

-- Can this engine write an aligned overdub? It came with `head_sync`, the
-- one command of the sixty-seventh change: an older engine reads a 2 as a
-- new take. (The offscreen norns has no command table: it can.)
function ctx.can_align()
  local c = engine.commands
  return not c or c.head_sync ~= nil
end
-- Does the next overdub align? (an overdub, ALIGN, and an engine that can)
function ctx.aligns()
  return pget("pre_level", 0) >= 0.001 and pget("rec_align", 2) == 2 and ctx.can_align()
end

-- why a pass from this source cannot record into the focused track, or nil.
-- A track that records itself, and a source that hears the take's track
-- through a send, would feed the pass back into itself. The sends are
-- followed through other tracks too (T2 to T3 to T1). MIX is allowed: like
-- `resample`, it records the destination's own playback with the rest, on
-- purpose.
local SRC_NAMES = { "IN", "T1", "T2", "T3", "T4", "MIX" }
ctx.SRC_NAMES = SRC_NAMES
function ctx.relay_refusal(dest)
  local s = rec_src()
  if s == 0 then return nil end
  if not ctx.relay_ok() then return "SOURCE NEEDS A RESTART" end
  if s == 5 then return nil end
  if s == dest then return "SOURCE IS THIS TRACK" end
  if ctx.track_gain(s) == 0 then return "T" .. s .. " IS MUTED" end
  -- does the destination reach the source through the sends?
  local seen, todo = { [dest] = true }, { dest }
  while #todo > 0 do
    local a = table.remove(todo)
    for b = 1, NTRACKS do
      if not seen[b] and b ~= a and pget("send_" .. a .. "_" .. b, 0) > 0 then
        if b == s then return "T" .. dest .. " FEEDS T" .. s .. " - SEND OFF" end
        seen[b] = true
        todo[#todo + 1] = b
      end
    end
  end
  return nil
end

-- THE WRITE HEAD'S POLL, once a frame. Just after a new take put the head at
-- 0, a poll that left before can still arrive, with the place the head was.
-- The head moves at one second a second, so for three frames a poll that
-- is further than the time since the reset allows is not believed. It also
-- notes a head that came round the end of the buffer (rec_wrapped).
function ctx.head_poll(v)
  local at = ctx.rec_reset_at
  if at then
    local n = ctx.frame - at
    if n > 3 then
      ctx.rec_reset_at = nil
    elseif v > (n + 2) / (FPS * BUF_SECS) then
      return
    end
  end
  -- (an aligned pass loops in its window: its wraps are not the buffer's)
  if rec_open and v < rec_last - 0.5 and not ctx.rec_aligned then rec_wrapped = true end
  rec_last = v
  ctx.rec_phase = v
  ctx.rec_poll_time = util.time and util.time() or nil
end
local rec_heard, rec_quiet = false, 0   -- this pass: sound seen, last quiet head
local rec_moved = false                 -- this pass's start moved to the sound
local function waits()
  -- (a take on the clock starts on its line, not on the sound)
  return pget("rec_wait", 0) == 1 and pget("pre_level", 0) < 0.001
    and not ctx.rec_synced
end
local function tick_rec_wait()
  if pget("rec", 0) ~= 1 or rec_heard then ctx.rec_waiting = false; return end
  ctx.rec_waiting = waits()
  -- a STOP or a freeze writes nothing, so a level then is not the take
  if pget("stop_all", 0) == 1 or pget("freeze", 0) == 1 then return end
  if ctx.rec_amp < pget("rec_thresh", 0.02) then
    rec_quiet = ctx.rec_phase
    return
  end
  rec_heard = true
  if not ctx.rec_waiting then return end
  ctx.rec_waiting = false
  local arm = ctx.rec_arm_phase
  local from = rec_quiet - REC_PREROLL / BUF_SECS
  from = rec_quiet >= arm and max(from, arm) or max(from, 0)
  ctx.rec_arm_phase, rec_moved = from, true
  rec_wrapped = false   -- the take begins here: a wrap before the sound is not its own
  print(string.format("four: sound at %.2fs into the pass, the take starts there",
    ((ctx.rec_phase - arm) % 1) * BUF_SECS))
end

-- POLLED each frame rather than run from the knobs' actions. The mode stops
-- erosion as surely as its knob does, because the erosion head only runs in
-- PLAY. The second of quiet means that a HEAL tap, a scene recall or a motion
-- lane crossing 0 does not dump the whole take (17 MB at full length) each
-- time it happens. The knobs' actions also mark the strip (strip_wrote): a
-- burst that starts and ends between two frames still wrote the buffer.
local function take_writing()
  return pget("regen", 0) > 0 or Mpages.eroding()
end
local function strip_wrote()
  strip_stale, strip_quiet = true, 0
end
local function tick_take_strip()
  if take_writing() then
    strip_wrote()
  elseif strip_stale then
    strip_quiet = strip_quiet + 1
    -- a performer's dump still running would refuse the repaint: wait it out
    if strip_quiet >= FPS and not export_clock then
      strip_stale = false
      ctx.refresh_take_strip()
      ctx.undo_mark()   -- what regen or erosion left is a finished take
    end
  end
end

-- wipe it. the engine zeroes the buffer; we clear the PICTURE with it and open
-- the window back up, so every page goes back to inviting a take instead of
-- drawing one that isn't there.
function ctx.clear_recording()
  if not engine.clear then
    print("four: engine has no `clear` — SYSTEM > RESTART for the new engine")
    return
  end
  -- disarm first, like the TAPE erase: wiping while armed kept
  -- recording into the freshly cleared buffer, and the rec-stop later built a
  -- window whose first seconds were the erased silence
  if pget("rec", 0) == 1 then ctx.rec_set(0) end
  engine.clear()
  -- the engine's \clear released a held repeat with it. Through ctx: the
  -- local is declared further down, and read from here it would be a global
  ctx.repeat_release()
  Mpages.clear_wave()
  buffer_cleared()
  -- a clear must be SILENCE (S23 B2): regen would immediately re-record the
  -- OUTPUT — input monitor, ringing tails — into the freshly erased buffer,
  -- resurrecting what you just wiped. the engine's `clear` flushes the
  -- delay/reverb tails on its side; this stops the write head at the params.
  -- (buffer_cleared above dropped any pending strip repaint, so stopping
  -- regen here does not dump and repaint a buffer that is now empty)
  if pget("regen", 0) > 0 then params:set("regen", 0) end
  -- forget the loaded sample too. The take half already refuses to resurrect
  -- audio you cleared (take_pset_write deletes the pair), but a take that came
  -- from `load sample` lives in this path, and a PSET saved after a CLR would
  -- restore it on load — putting back the very sample you erased. "" is a
  -- no-op through load_sample's own guard.
  if params:get("sample_file") ~= "" then params:set("sample_file", "") end
  Mdeck.set_pair(WIN[1], WIN[2], 0, 1)
  ctx.undo_mark()   -- empty is a state UNDO can go back from
  print("four: recording cleared")
end

-- put a file in the take buffer and make every page agree about it. The
-- display is read from the FILE: lua cannot see the SC buffer (Mpages.load_wave).
local function read_into_buffer(path, shown)
  engine.read_file(path)
  ctx.wave_any = true    -- audio is in the buffer now, drawable or not — never
                         -- lie "EMPTY" over an audible sample, even for formats
                         -- the preview can't draw
  local dur = Mpages.load_wave(path, BUF_SECS)
  buffer_replaced(dur)   -- the loaded length bounds a PSET save
  if dur then
    Mdeck.set_pair(WIN[1], WIN[2], 0, clamp(dur / BUF_SECS, 0.002, 1))
    print(string.format("four: loaded %s (%.1fs) — window snapped to it",
      shown or path, dur))
  else
    -- audible, but no picture for this format (8-bit / aiff): leave the window
    -- for the performer to set rather than draw a lie
    print("four: loaded " .. (shown or path)
      .. " (playing; no waveform preview for this format)")
  end
  ctx.undo_mark()
end

-- LOAD AT THE SERVER RATE. Neither scsynth's nor softcut's buffer read does any
-- sample-rate conversion, so a file at any other rate plays varispeeded: a
-- 44.1k wav is 8.8% fast, over a semitone sharp, and every slice, pad and
-- window inherits the error. An off-rate file is resampled first, in the
-- background with the screen live. If the conversion cannot run or cannot
-- decode the file, it loads as-is: audible-but-sharp beats silence, and the
-- log says which happened.
--   land(file, shown)  puts a file in place (`shown` = the name that was picked)
--   gen()              the target's generation: a conversion that finishes
--                      after it moved is dropped rather than landing on top
local function load_at_rate(path, tmp, cap_secs, what, land, gen)
  if path == nil or path == "" or path == "-" or path == _path.audio then return end
  if not util.file_exists(path) then
    print("four: no such file — " .. tostring(path))
    return
  end
  local okp, _, _, in_sr = pcall(Mwav.wav_info, path)
  if not (okp and in_sr and in_sr ~= SERVER_SR) then
    land(path)                     -- already at rate, or a format we can't probe
    return
  end
  print(string.format("four: %d Hz file — resampling to %d before the %s load"
    .. " (it would play at %.2fx otherwise)", in_sr, SERVER_SR, what,
    SERVER_SR / in_sr))
  local g = gen()
  ctx.run_task(function(yield)
    -- a job whose target moved on (while it waited in the queue, or between
    -- two blocks) stops here: converting tens of seconds of audio that will
    -- be dropped only delays the newer request queued behind it
    if gen() ~= g then return end
    -- capped at what the target can hold: converting past it is pure waste,
    -- and a corrupt rate header must never expand into gigabytes
    local ok, err = Mwav.convert_sr(path, tmp, SERVER_SR, function()
      yield()
      return gen() == g
    end, cap_secs)
    if not ok and gen() == g then error(err or "conversion failed", 0) end
  end, function(ok, err)
    if gen() ~= g then
      print("four: " .. path .. " dropped before it landed: the " .. what
        .. " changed meanwhile, the newer material stays")
      return
    end
    if ok then
      land(tmp, path)
    else
      print("four: resample failed (" .. tostring(err)
        .. ") — loading at the original rate, it will play sharp")
      land(path)
    end
  end)
end

-- load any wav as the sample (PARAMS > rec > load sample). it lands in the SAME
-- buffer a take does, so the window, drone and pads all work on it
-- identically — there is no "loaded sample" mode, it's just the sample. the
-- window snaps to the file's length.
local srconv_path
function ctx.load_sample(path)
  if path and path ~= "" and path ~= "-" and not engine.read_file then
    print("four: engine has no `read_file` — SYSTEM > RESTART for the new engine")
    return
  end
  take_gen = take_gen + 1     -- the newest request wins over one still converting
  srconv_path = srconv_path or (norns.state.data .. "four-srconv.wav")
  load_at_rate(path, srconv_path, BUF_SECS + 1, "take", read_into_buffer,
    function() return take_gen end)
end

-- the live take rides the PSET as a private L/R pair beside the
-- pset file (take-N_L.wav / _R.wav), the same way mtape persists the tape
-- audio and mscenes the scene bank — the shared action_write/read/delete hook
-- calls each. the engine holds the buffer; lua only knows whether it has
-- CONTENT (ctx.wave_any — the has-a-take signal that also draws
-- "EMPTY - K2 REC"), so the write is gated on it: an empty take never leaves a
-- multi-MB silence file behind, and a fresh pset never resurrects one.
-- (four) track 1 keeps mangler's name, so a mangler pset still loads
-- its take; tracks 2 to 4 save as take2-NN, take3-NN, take4-NN
local FOCUS = 1
local function take_stem(number, n)
  n = n or FOCUS
  return norns.state.data .. (n == 1 and "take-" or ("take" .. n .. "-")) .. number
end

-- how many frames of the buffer a write should cover: the take_len high-water
-- mark (from frame 0), +50ms margin so rounding at the take boundary never clips
-- the tail, capped at the 60s buffer; take_len 0 (empty) -> the full buffer.
local function take_frames(len)
  local total = SERVER_SR * BUF_SECS
  local tl = len or ctx.take_len or 1
  return (tl > 0) and math.min(total, math.ceil(tl * total) + 2400) or total
end

-- (four) every track's take: the focused one from ctx, the others from
-- their kept state (TAKES). buf_track points the engine's buffer commands at
-- a track's pair for one write or read, then back at the focus.
local TAKES = {}
for n = 1, 4 do TAKES[n] = { wave_any = false, take_len = 0 } end
local function take_of(n)
  if n == FOCUS then return ctx.wave_any, ctx.take_len end
  return TAKES[n].wave_any, TAKES[n].take_len
end
ctx.take_of = take_of   -- a scene clamps each track's window to its own take
local function buf_track(n) if engine.buf_track then engine.buf_track(n - 1) end end
-- does track n hold material of its own (TRACKS draws EMPTY where not)
function ctx.track_has(n) return (take_of(n)) and true or false end

function ctx.take_pset_write(number)
  if not engine.write_take then return end   -- old engine: no-op (like read_file)
  for n = 1, 4 do
    local any, len = take_of(n)
    if not any then
      -- nothing recorded: DELETE any take saved into this slot before, so a
      -- session the performer cleared and re-saved as empty can't resurrect
      -- the old audio on load (norns overwrite-save never calls action_delete).
      os.remove(take_stem(number, n) .. "_L.wav")
      os.remove(take_stem(number, n) .. "_R.wav")
    else
      -- bound the write to the TAKE, not the full 60s buffer of mostly silence.
      buf_track(n)
      engine.write_take(take_stem(number, n), take_frames(len))
    end
  end
  buf_track(FOCUS)
end

function ctx.take_pset_read(number)
  if not engine.read_take then return end
  for n = 1, 4 do
    local stem = take_stem(number, n)
    -- no take file (a pset from before S22, or one saved with an empty buffer):
    -- leave the buffer alone, exactly like mtape when there's no wav — the
    -- pset's own params (window included) still load. BOTH halves must exist:
    -- /b_write is async, so an interrupted save can leave _L without _R, and
    -- reading that would zero both buffers then restore a left-only take.
    if util.file_exists(stem .. "_L.wav") and util.file_exists(stem .. "_R.wav") then
      buf_track(n)
      engine.read_take(stem)
      if n == FOCUS then
        -- repaint from the file or the restored take is INVISIBLE (audio you
        -- can hear over "EMPTY - K2 REC"). do NOT snap the window — params:read
        -- already restored the saved pos_start/pos_end.
        local dur = Mpages.load_wave(stem .. "_L.wav", BUF_SECS)
        buffer_replaced(dur)  -- padlock_pset_read restores the pset's own cuts next
        ctx.wave_any = true   -- audio is in the buffer whether or not we could draw it
        ctx.undo_mark()
      else
        local dur = Mpages.fill_wave_bins(stem .. "_L.wav", Mpages.track_wave(n), BUF_SECS)
        TAKES[n].wave_any = true
        TAKES[n].take_len = dur and clamp(dur / BUF_SECS, 0.002, 1) or 1
      end
    end
  end
  buf_track(FOCUS)
end

function ctx.take_pset_delete(number)
  for n = 1, 4 do
    local stem = take_stem(number, n)
    os.remove(stem .. "_L.wav")
    os.remove(stem .. "_R.wav")
  end
end

-- ============================================================================
-- the take UNDO
-- ============================================================================
-- One step back, and one forward again. After every change to the take that
-- is FINISHED (a record pass stops, a load or a print lands, a PSET restores
-- it, regen or erosion goes quiet, a clear), the take as it now stands is
-- dumped as an L/R pair, and the state before it is kept as the one to go
-- back to. TAKE UNDO loads that one and swaps the two, so a second UNDO is a
-- redo. The window and the take length come back with it. A clear is a state
-- too (`empty`), so an UNDO after a clear brings the take back.
-- The dump is the engine's own write_take, the PSET's path, into one of THREE
-- slots (`undo-1..3`). A dump is async: the engine opens its file later than
-- this Lua turn, so files are never renamed (a rename ran before the file
-- existed and left a state's audio under another state's window). A new dump
-- goes into the one slot neither kept state uses, and the engine handles its
-- commands in order, so a read of a slot always follows its write.
-- UNDO while something writes first finishes that change: a pass stops (its
-- stop marks a state), regen or erosion stops and the take as they left it
-- is marked. So UNDO always goes back exactly one change.
-- `undo_keep` off writes nothing and forgets the kept states, so UNDO never
-- offers a take older than the last one you made.
local undo_cur, undo_prev     -- { slot, empty, lo, hi, take_len }
local function undo_stem(slot)
  return norns.state.data .. (FOCUS == 1 and "undo-" or ("undo" .. FOCUS .. "-")) .. slot
end
local function free_slot()
  for k = 1, 3 do
    if not ((undo_cur and undo_cur.slot == k) or (undo_prev and undo_prev.slot == k)) then
      return k
    end
  end
end
function ctx.undo_mark()
  if pget("undo_keep", 1) ~= 1 or not engine.write_take then
    undo_cur, undo_prev = nil, nil
    return
  end
  undo_prev = undo_cur
  if not ctx.wave_any then
    undo_cur = { empty = true }
    return
  end
  local k = free_slot()
  local stem = undo_stem(k)
  -- the slot's old pair goes first, so the wait below reads the new files
  os.remove(stem .. "_L.wav"); os.remove(stem .. "_R.wav")
  engine.write_take(stem, take_frames())
  undo_cur = { slot = k, lo = pget(WIN[1], 0), hi = pget(WIN[2], 1),
    take_len = ctx.take_len }
  ctx.undo_pending = { stem = stem, bytes = take_frames() * ctx.TAKE_BYTES + 44,
    from = ctx.frame or 0 }
end

-- IS THE COPY UNDO KEEPS ON THE CARD YET (the sixty-third change)? The
-- engine writes it from the buffer in the background, and a new take starts
-- writing that buffer from 0: a pass armed while the copy was still being
-- written put its own first moments into the copy. A K2 that stops a take
-- and a K2 at once to start the next one did exactly that. The arm now
-- waits until both files reach their size (a few frames for a short take).
-- The offscreen norns writes no files (it has no util.time either): there the
-- copy is always written. A copy that never arrives is given up
-- after five seconds, so a pass can never be blocked for good.
local function fsize(p)
  local f = io.open(p, "rb"); if not f then return nil end
  local n = f:seek("end"); f:close(); return n
end
function ctx.undo_settled()
  local u = ctx.undo_pending
  if not u then return true end
  if not util.time then ctx.undo_pending = nil; return true end
  local l, r = fsize(u.stem .. "_L.wav"), fsize(u.stem .. "_R.wav")
  local full = l and r and l >= u.bytes and r >= u.bytes
  if full or (ctx.frame or 0) - u.from > FPS * 5 then
    if not full then print("four: the UNDO copy did not arrive in 5 s; recording anyway") end
    ctx.undo_pending = nil
    return true
  end
  return false
end
-- a fresh session: an undo pair left on the card by the last one is not
-- this session's take, so it is never offered, and its files go
function ctx.undo_forget()
  undo_cur, undo_prev = nil, nil
  for k = 1, 3 do
    os.remove(undo_stem(k) .. "_L.wav"); os.remove(undo_stem(k) .. "_R.wav")
  end
end
-- is there a state to go back to (TAKE draws its "<" while there is)
function ctx.undo_ready() return undo_prev ~= nil end
function ctx.take_undo()
  if not (undo_prev and engine.read_take) then
    ctx.take_say("UNDO - NOTHING TO GO BACK TO", "UNDO — nothing to go back to")
    return
  end
  -- finish a change still being written, so UNDO goes back exactly one.
  -- A pass's stop marks a state itself; regen and erosion are marked here
  if pget("rec", 0) == 1 then ctx.rec_set(0) end
  local writing = pget("regen", 0) > 0 or Mpages.eroding()
  if pget("regen", 0) > 0 then params:set("regen", 0) end
  if Mpages.eroding() then params:set("erode", 0) end
  if writing then ctx.undo_mark() end
  local back = undo_prev
  if not back then               -- the mark above forgot them (undo_keep off)
    ctx.take_say("UNDO - NOTHING KEPT", "UNDO — keep an undo is off")
    return
  end
  undo_prev, undo_cur = undo_cur, back
  if back.empty then
    engine.clear()
    Mpages.clear_wave()
    buffer_cleared()
    Mdeck.set_pair(WIN[1], WIN[2], 0, 1)
    -- as a clear does: a PSET saved now must not bring the loaded file back
    if params:get("sample_file") ~= "" then params:set("sample_file", "") end
    ctx.take_say("UNDO - EMPTY AGAIN", "UNDO — back to the empty buffer")
    return
  end
  engine.read_take(undo_stem(back.slot))
  local dur = Mpages.load_wave(undo_stem(back.slot) .. "_L.wav", BUF_SECS)
  buffer_replaced(dur)
  ctx.wave_any = true
  ctx.take_len = back.take_len
  Mdeck.set_pair(WIN[1], WIN[2], back.lo, back.hi)
  ctx.take_say("UNDO - THE TAKE BEFORE",
    "UNDO — the take before the last change is back (UNDO again to return)")
end

-- ============================================================================
-- the focus (four): own material per track
-- ============================================================================
-- Each track records and plays its own 60s. The FOCUSED track is the one REC
-- writes, TAKE draws and edits, the pads play, and UNDO, CLEAR, LOAD, PRINT
-- and EXPORT act on. Moving the focus keeps the old track's take state
-- (TAKES), brings back the new one's, and points the engine at its buffer.
-- A pass that is recording when the focus moves ends on the old track and a
-- new one opens on the new track, so a take never spans two tracks.
function ctx.focus_take(n)
  n = clamp(math.floor(n + 0.5), 1, NTRACKS)
  if n == FOCUS then return end
  local recording = pget("rec", 0) == 1
  if recording then ctx.rec_set(0) end
  local t = TAKES[FOCUS]
  t.wave_any, t.take_len = ctx.wave_any, ctx.take_len
  t.undo_cur, t.undo_prev, t.snap_mem = undo_cur, undo_prev, snap_mem
  FOCUS = n
  local u = TAKES[n]
  ctx.wave_any, ctx.take_len = u.wave_any, u.take_len
  undo_cur, undo_prev, snap_mem = u.undo_cur, u.undo_prev, u.snap_mem
  WIN[1], WIN[2] = tid_n(n, "pos_start"), tid_n(n, "pos_end")
  -- the window lock starts from the new track's window, as it is
  if ctx.win_resync then ctx.win_resync() end
  take_gen = take_gen + 1     -- a job for the old track's buffer must not land here
  Mpages.focus_wave(n)
  -- (the rec action below picks the buffer again, and puts the write head
  -- at its start for a new take: a pass that moves to another track goes on
  -- with no gap, and its part there starts at 0)
  rec_track(n, false)
  buf_track(n)
  if recording then ctx.rec_set(1) end
end
function ctx.focus() return FOCUS end

-- LOAD A FILE INTO TRACK n (its `t<n>_file` param, and the presets): the
-- focused track loads exactly as the take does; another track loads into its
-- own buffer through buf_track, draws its own strip, keeps its own take state,
-- and its window snaps to the file. Off-rate files convert first, like the take.
local track_gen = { 0, 0, 0, 0 }
function ctx.track_load(n, path)
  if n == FOCUS then return ctx.load_sample(path) end
  if path and path ~= "" and path ~= "-" and not engine.read_file then
    print("four: engine has no `read_file` — SYSTEM > RESTART for the new engine")
    return
  end
  track_gen[n] = track_gen[n] + 1
  load_at_rate(path, norns.state.data .. "t" .. n .. "-srconv.wav", BUF_SECS + 1,
    "track " .. n,
    function(file, shown)
      if n == FOCUS then read_into_buffer(file, shown); return end
      buf_track(n)
      engine.read_file(file)
      buf_track(FOCUS)
      local dur = Mpages.fill_wave_bins(file, Mpages.track_wave(n), BUF_SECS)
      local t = TAKES[n]
      t.wave_any = true
      t.take_len = dur and clamp(dur / BUF_SECS, 0.002, 1) or 1
      t.undo_cur, t.undo_prev, t.snap_mem = nil, nil, nil
      if dur then
        Mdeck.set_pair(tid_n(n, "pos_start"), tid_n(n, "pos_end"), 0, t.take_len)
      end
      print(string.format("four: %s -> track %d%s", shown or file, n,
        dur and string.format(" (%.1fs)", dur) or ""))
    end,
    function() return track_gen[n] end)
end

-- REC END: what a pass does when it has filled the 60s. LOOP goes on round
-- and records over the start (as mangler always did). ONE-SHOT ends the take
-- there, whole, and recording carries on into the next track, so a long
-- performance lays itself across the four tracks. On track 4 it stops.
local rec_prev_el = 0
local function tick_rec_end()
  -- (an aligned pass loops in its window and never reaches the buffer's end)
  if pget("rec", 0) ~= 1 or pget("rec_end", 1) ~= 2 or not ctx.rec_arm_phase
      or ctx.rec_aligned then
    rec_prev_el = 0
    return
  end
  local el = (ctx.rec_phase - ctx.rec_arm_phase) % 1
  if rec_prev_el > 0.9 and el < 0.1 then
    rec_prev_el = 0
    ctx.rec_set(0)
    Mdeck.set_pair(WIN[1], WIN[2], 0, 1)    -- the whole 60s is the take
    ctx.take_len = 1
    if FOCUS < NTRACKS then
      local from = FOCUS
      params:set("track_sel", FOCUS + 1)
      ctx.rec_set(1)
      -- a refused arm (the next track is the source) keeps its own words
      if pget("rec", 0) == 1 then take_say("TRACK " .. from .. " FULL - REC ON " .. FOCUS) end
    else
      take_say("TRACK 4 FULL - REC STOPPED")
    end
  else
    rec_prev_el = el
  end
end

-- SOUND-LOCKS ride the PSET like the take + scenes: the 8 per-pad voice+pitch
-- locks save as a small lua table beside the pset (params:read only restores the
-- editor params, i.e. the cursor pad — this restores all 8).
local function padlock_path(number)
  return norns.state.data .. "padlock-" .. number .. ".lua"
end

function ctx.padlock_pset_write(number)
  local t = { v = 1, type = {}, pitch = {}, cuts = ctx.pad_cuts, notes = ctx.pad_notes }
  for i = 0, 7 do t.type[i] = ctx.pad_type[i] or 0; t.pitch[i] = ctx.pad_pitch[i] or 0 end
  -- guarded like every other pset writer here: a write failure must PRINT, not
  -- throw out of params.action_write and abort the rest of the save
  local ok, err = pcall(tab.save, t, padlock_path(number))
  if not ok then print("four: pad-lock save failed — " .. tostring(err)) end
end

function ctx.padlock_pset_read(number)
  local path = padlock_path(number)
  if not util.file_exists(path) then return end
  local ok, t = pcall(tab.load, path)
  if not (ok and type(t) == "table" and type(t.type) == "table") then return end
  for i = 0, 7 do
    ctx.pad_type[i] = t.type[i] or 0
    ctx.pad_pitch[i] = (t.pitch and t.pitch[i]) or 0
  end
  -- the chop belongs to the take, and the take rides the pset too — so the
  -- slice boundaries come back with the audio they were cut from. (this runs
  -- AFTER take_pset_read, which drops them along with the old material.)
  ctx.pad_cuts = (type(t.cuts) == "table" and #t.cuts > 1) and t.cuts or nil
  -- an autosample's notes, one for each slice, come back with its cuts
  ctx.pad_notes = (ctx.pad_cuts and type(t.notes) == "table"
    and #t.notes == #ctx.pad_cuts - 1) and t.notes or nil
  ctx.pad_edit_sync()   -- editor params -> the restored cursor pad
end

function ctx.padlock_pset_delete(number)
  os.remove(padlock_path(number))
end

-- hand back to the scheduler for one tick. Every long scan inside a clock
-- coroutine takes this, so the 15fps redraw (and motion, and scenes) keeps
-- running through a multi-second job instead of freezing.
function ctx.task_yield() clock.sleep(0) end

-- run long jobs as coroutines that yield, ONE AT A TIME, in the order they
-- were asked for. A job that arrives while another runs waits its turn: a PSET
-- can restore two off-rate takes back to back, and both
-- have to convert (refusing the second loaded it out of tune). Each body runs
-- under pcall and its `on_done(ok, err)` ALWAYS runs: without that a throw
-- halfway through (a full card, a bad read) kills the coroutine with the
-- caller's state half-set and its file handles still open. A job whose
-- target changed stops itself and is dropped by the caller's generation
-- check (load_at_rate), not here.
local task_clock
local task_queue = {}
local function start_next_task()
  local job = table.remove(task_queue, 1)
  if not job then return end
  task_clock = clock.run(function()
    local ok, err = pcall(job[1], ctx.task_yield)
    task_clock = nil
    if not ok then print("four: background job failed — " .. tostring(err)) end
    if job[2] then job[2](ok, err) end
    start_next_task()
  end)
end

function ctx.run_task(fn, on_done)
  task_queue[#task_queue + 1] = { fn, on_done }
  if task_clock then
    print("four: queued behind the background job already running")
  else
    start_next_task()
  end
end

-- teardown only: no completion runs (cleanup is leaving), queued jobs included
function ctx.cancel_task()
  for k = #task_queue, 1, -1 do task_queue[k] = nil end
  if task_clock then clock.cancel(task_clock); task_clock = nil end
end

local function filesize(p)
  local f = io.open(p, "rb"); if not f then return nil end
  local s = f:seek("end"); f:close(); return s
end
-- the first free `<prefix>-NNN` stem in `dir`, NNN from 001, tested with `ext`.
-- Returns nil when all 999 are taken, and the caller then REFUSES and says so.
-- This was two copies of one loop, each handing back a "-000" name at
-- exhaustion — which quietly overwrote the performer's oldest recording.
function ctx.next_free(dir, prefix, ext)
  for n = 1, 999 do
    local stem = string.format("%s-%03d", prefix, n)
    if not util.file_exists(dir .. stem .. (ext or "")) then return stem end
  end
  return nil
end

local function next_audio_name(prefix)
  local stem = ctx.next_free(_path.audio, prefix, ".wav")
  return stem and (stem .. ".wav")
end

-- A RECORDING PASS: the system TAPE captures the MASTER out — engine + tape
-- deck + FX, everything you hear — into `path` for `secs`, calling `on_tick`
-- once per frame so a caller can automate a param ACROSS the pass. That last
-- part is what makes a pass more than a bounce: sweep the scene morph, or the
-- erosion, and the recording IS the sweep.
-- `done(finished, path)` runs after the writer has flushed; `finished` is false
-- if the pass was aborted.
-- The duration is LIVE: record_stop ends it now, record_limit re-aims the end.
local pass, pass_clock
function ctx.record_pass(path, secs, on_tick, done)
  if pass then print("four: a recording pass is already running"); return false end
  if not (audio.tape_record_open and audio.tape_record_start) then
    print("four: no system tape API — cannot record"); return false
  end
  -- recording a CHOKED output would capture silence, and a caller that then
  -- loads the result would wipe the take with nothing
  if pget("stop_all", 0) == 1 then
    print("four: pass refused — output is stopped (K1+K2 to start)")
    return false
  end
  pass = { n = math.max(1, math.floor(secs * FPS + 0.5)), i = 0 }
  audio.tape_record_open(path)
  audio.tape_record_start()
  pass_clock = clock.run(function()
    local aborted = false
    while pass and pass.i < pass.n do
      if on_tick then on_tick(pass.n > 1 and pass.i / (pass.n - 1) or 1) end
      clock.sleep(1 / FPS)
      pass.i = pass.i + 1
      -- the global STOP is the abort: the one key that always means silence
      -- has to mean "stop making this" too. Refusing to START while stopped is
      -- only half the guard — a STOP pressed mid-pass silences the master, and
      -- the rest of the recording would be digital silence.
      if pget("stop_all", 0) == 1 then aborted = true; break end
    end
    pcall(audio.tape_record_stop)
    clock.sleep(0.35)          -- let the tape writer flush + close the wav
    pass, pass_clock = nil, nil
    if done then done(not aborted, path) end
  end)
  return true
end

function ctx.record_stop()
  if pass then pass.n = pass.i end          -- the loop falls out next check
end

function ctx.record_limit(secs)
  if pass then
    pass.n = math.max(pass.i + 1, math.floor(secs * FPS + 0.5))
  end
end

-- teardown: kill a pass outright without running its `done`. Only cleanup()
-- wants this — everything else should let the pass finish or abort so the
-- caller's completion work still runs.
function ctx.record_cancel()
  if not pass_clock then return end
  clock.cancel(pass_clock)
  pcall(audio.tape_record_stop)
  pass, pass_clock = nil, nil
end

-- PRINT: the one-gesture full-mix resample. One pass of print_len seconds
-- (0 = AUTO, the current window length), and the bounce loads back as THE take
-- (engine.read_file via load_sample: window snaps, waveform draws). The print
-- wav stays in dust/audio, so the material is never lost even though the buffer
-- is replaced; older takes live in their PSETs. mangle -> print -> mangle.
-- `sweep` (optional) is handed straight to the pass as its per-frame hook, so a
-- caller can print a MOVE rather than a moment.
function ctx.print_take(sweep)
  local secs = pget("print_len", 0)
  if secs < 0.05 then
    local _, _, span = window_bounds()
    secs = clamp(span * BUF_SECS, 0.5, BUF_SECS)
  end
  local name = next_audio_name("four-print")
  if not name then
    print("four: 999 prints in dust/audio — clear some out first")
    return
  end
  local ok = ctx.record_pass(_path.audio .. name, secs, sweep,
    function(finished, path)
      if not finished then
        os.remove(path)        -- a part-silent bounce is not worth keeping
        print("four: PRINT aborted by STOP — the take is untouched")
        return
      end
      ctx.load_sample(path)
      print("four: PRINT done — " .. name .. " is the new take")
    end)
  if ok then
    print(string.format("four: PRINT — recording the master mix, %.1fs", secs))
  end
end

-- dump the live take to ONE stereo wav: write_take drops an L/R pair (bufL and
-- bufR are two MONO buffers and scsynth has no cheap non-realtime interleave),
-- we wait out the async /b_write, then zip them. `done(ok, path)` when the file
-- is there. Lua cannot read an SC buffer, so this file IS the API — the export
-- and the pad chopper are both built on it.
-- `background`: nobody waits on this dump (the strip repaint). A performer's
-- dump that arrives while a background one runs waits for it, in one slot.
function ctx.take_to_wav(out, done, background)
  if not engine.write_take then
    print("four: engine has no write_take — SYSTEM > RESTART")
    if done then done(false) end
    return
  end
  if not ctx.wave_any then
    print("four: nothing to render — the buffer is empty")
    if done then done(false) end
    return
  end
  -- REFUSE a second dump rather than cancelling the first. Both callers share
  -- this one clock and one tmp stem; cancelling killed the coroutine
  -- mid-interleave, leaving a TRUNCATED wav that looks finished in the browser,
  -- and the new dump would overwrite the files the cancelled one was reading.
  -- A dump queued behind the background repaint is not refused: it waits.
  if export_clock then
    if export_bg and not background and not export_next then
      export_next = { out, done }
      print("four: take dump queued behind the strip repaint")
      return
    end
    print("four: a take dump is already running")
    if done then done(false) end
    return
  end
  export_bg = background == true
  local tmp = norns.state.data .. "mexport-tmp"
  -- clear any leftover temp pair first: the names are fixed, so a stale half of
  -- an interrupted dump can satisfy the size-stability wait below and get
  -- interleaved into the new file.
  os.remove(tmp .. "_L.wav"); os.remove(tmp .. "_R.wav")
  engine.write_take(tmp, take_frames())   -- async dump to tmp_L.wav / tmp_R.wav
  -- How big each mono file should end up: one sample per frame, plus a 44
  -- byte header. We wait for both to REACH that size and then stop changing.
  -- Waiting for them to merely stop changing is not enough, because a slow SD
  -- card can pause mid-write and look finished at half a file. That is why
  -- the byte width has a name of its own: while it was stuck at 2 and the
  -- engine wrote 3, this check passed at two thirds and exported a cut-off
  -- take. The time limit scales with the take so a long one gets time to
  -- finish. It is only there to stop us waiting forever.
  local exp = take_frames() * ctx.TAKE_BYTES + 44
  local cap = math.max(100, math.ceil(exp / 200000) + 80)
  export_clock = clock.run(function()
    local pL, pR, stable = -1, -1, 0
    for _ = 1, cap do
      clock.sleep(0.05)
      local sL, sR = filesize(tmp .. "_L.wav"), filesize(tmp .. "_R.wav")
      if sL and sR and sL >= exp * 0.98 and sR >= exp * 0.98
        and sL == pL and sR == pR then
        stable = stable + 1; if stable >= 2 then break end
      else stable = 0 end
      pL, pR = sL, sR
    end
    -- yield between chunks so a large interleave doesn't freeze the UI thread
    local ok = Mwav.interleave_wav(tmp .. "_L.wav", tmp .. "_R.wav", out,
      ctx.task_yield)
    os.remove(tmp .. "_L.wav"); os.remove(tmp .. "_R.wav")
    -- the guard holds until `done` returns. A scan reads `out` in there for
    -- seconds, and a second dump started meanwhile would truncate the file
    -- under it. Under pcall, so a throw cannot leave the guard set forever.
    if done then
      local okd, err = pcall(done, ok, out)
      if not okd then print("four: the step after the take dump failed: " .. tostring(err)) end
    end
    export_clock, export_bg = nil, false
    local nxt = export_next
    export_next = nil
    if nxt then ctx.take_to_wav(nxt[1], nxt[2]) end
  end)
end

-- the browsable EXPORT: the same dump, into dust/audio under a name you can
-- find, as one stereo wav that reloads through `load sample`.
function ctx.export_take(name)
  name = name or next_audio_name("four")
  if not name then
    print("four: 999 exports in dust/audio — clear some out first")
    return
  end
  local out = _path.audio .. name
  ctx.take_to_wav(out, function(ok)
    print(ok and ("four: exported " .. out) or "four: export FAILED")
  end)
end

-- the window locked to the clock: with win_beats other than FREE, the
-- window's END is put at the start plus that many beats at the current tempo,
-- so a PLAY loop of the take stays in time with the synced delay, the decks
-- and the sequencer. It is put there when the lock is set, when a record
-- pass stops, when the tempo moves by more than half a percent (so MIDI clock
-- jitter does not write every frame), and when the START moves on its own
-- (so moving the start slides the whole window). A start that jumps past the
-- end moves the end in its own action, so the pair never stands crossed.
-- It does NOT own the end. An earlier version put the end back every frame,
-- like the synced delay's time, and a reviewer found what that broke: TAKE
-- SNAP could no longer go back, and a morph, a GLIDE or a motion lane on the
-- end fought it every frame, wobbling the read head. So a write that moves
-- the END (SNAP, TIGHTEN, a scene, the morph, a hand on E3, any pair write)
-- is left as it is, until the next of those moments.
-- A start too late for the length ends the window at the buffer's end.
local WIN_BEATS = { 0, 1, 2, 4, 8, 16, 32 }
local WIN_BEAT_NAMES = { "FREE", "1 BEAT", "2 BEAT", "1 BAR", "2 BAR", "4 BAR", "8 BAR" }
ctx.WIN_BEAT_NAMES = WIN_BEAT_NAMES
local win_tempo, win_lo, win_hi = 0, -1, -1   -- what the lock last saw
-- a focus change: the lock compares the NEW track's window with itself, so a
-- start that differs from the old track's is not read as a start that moved
function ctx.win_resync() win_lo, win_hi = pget(WIN[1], 0), pget(WIN[2], 1) end
local function win_lock_beats()
  return WIN_BEATS[math.floor(pget("win_beats", 1) + 0.5)] or 0
end
local function apply_window_len()
  local b = win_lock_beats()
  if b <= 0 then return end
  local t = ctx.tempo()
  win_tempo = t
  -- the FOCUSED track's window (C10 of doc/signature-workflow.md): WIN
  -- holds its ids, so the lock follows the focus
  local want = min(1, pget(WIN[1], 0) + b * 60 / t / BUF_SECS)
  if math.abs(pget(WIN[2], 1) - want) >= 1e-9 then
    params:set(WIN[2], want)   -- only the end moves, outward of the start
    if ctx.motion and ctx.motion.account then ctx.motion.account(WIN[2]) end
  end
  win_lo, win_hi = pget(WIN[1], 0), pget(WIN[2], 1)
  ctx.lock_track(FOCUS, b)
end
-- each frame: a tempo move, or the start moved while the end did not
local function sync_window_len()
  local lo, hi = pget(WIN[1], 0), pget(WIN[2], 1)
  if win_lock_beats() > 0 then
    local t = ctx.tempo()
    if math.abs(t - win_tempo) > win_tempo * 0.005
        or (lo ~= win_lo and hi == win_hi) then
      apply_window_len()
      return
    end
  end
  win_lo, win_hi = lo, hi
end

-- LOCKED TRACKS (the sixty-ninth change, doc/clock-plan.md). A track whose
-- window the lock (win_beats) or a take on the clock set to whole beats is
-- locked: ctx.lock[n] holds the beats and the tempo. On a tempo move the
-- window takes its length again at the new tempo, on every locked track (the
-- lock above follows the focused one only). A window whose length something
-- else changed (a hand, a scene, SNAP) is not locked after that. The heads of
-- the locked tracks restart on the clock (ctx.on_beat).
ctx.lock = {}
local function win_of(n)
  local a, b = tid_n(n, "pos_start"), tid_n(n, "pos_end")
  local x, y = pget(a, 0), pget(b, 1)
  return min(x, y), max(x, y), (y >= x) and b or a
end
local function beats_len(beats, t) return beats * 60 / t / BUF_SECS end
function ctx.lock_track(n, beats)
  local lo, hi = win_of(n)
  local t = ctx.tempo()
  if beats >= 1 and math.abs((hi - lo) - beats_len(beats, t)) < 1e-6 then
    ctx.lock[n] = { beats = beats, tempo = t }
  else
    ctx.lock[n] = nil   -- (it did not fit: a start too late for the length)
  end
end
local function sync_locks()
  local t = ctx.tempo()
  for n = 1, NTRACKS do
    local L = ctx.lock[n]
    if L then
      local lo, hi, end_id = win_of(n)
      if math.abs((hi - lo) - beats_len(L.beats, t)) < 1e-6 then
        L.tempo = t
      elseif math.abs((hi - lo) - beats_len(L.beats, L.tempo)) < 1e-6 then
        if math.abs(t - L.tempo) > L.tempo * 0.005 then
          local want = lo + beats_len(L.beats, t)
          if want > 1 then
            ctx.lock[n] = nil
          else
            params:set(end_id, want)
            if ctx.motion and ctx.motion.account then ctx.motion.account(end_id) end
            L.tempo = t
          end
        end
      else
        ctx.lock[n] = nil
      end
    end
  end
end

-- ON EVERY BEAT of the clock (a coroutine in init; the tests call it): a take
-- that waits for its line arms or stops there, and the locked tracks whose
-- length is a whole number of beats into this one start again at their
-- window's start (head_sync, the sixty-seventh change), so they all start
-- together on the bar and a loop that drifted is put back each time round.
function ctx.on_beat(b)
  b = math.floor(b + 0.5)
  local q = ctx.rec_sync_beats()
  if q == 0 or b % q == 0 then
    if ctx.sync_stop then
      ctx.sync_go = true
      params:set("rec", 0)
      ctx.sync_go = false
    end
    if ctx.sync_arm then
      ctx.sync_arm = false
      ctx.sync_go = true
      params:set("rec", 1)
      ctx.sync_go = false
    end
  end
  if pget("loop_sync", 2) ~= 2 or pget("stop_all", 0) == 1 or not engine.head_sync then
    return
  end
  for n = 1, NTRACKS do
    local L = ctx.lock[n]
    if L and pget(tid_n(n, "mode"), n == 1 and 5 or 1) ~= 1 then
      local k = math.floor(L.beats + 0.5)
      if k >= 1 and b % k == 0 then engine.head_sync(n) end
    end
  end
end

-- BEAT REPEAT (the engine's \four_repeat). Held, it waits for the next
-- division of the clock, then the engine captures that much of the output
-- and loops it until you let go: a stutter on the beat. Turning the division
-- while it holds re-captures at once (a roll to a shorter one). A STOP
-- releases it, as it silences everything, and an arm under STOP waits for
-- the next press. The engine places it after the record tap, so resample,
-- regen and PRINT never record it.
-- A press that waits for its beat is never cancelled: a cancel landing as the
-- sync fires is the norns clock race in CLAUDE.md, and a press let go before
-- its beat is common. Each press takes a generation, and a wait that wakes
-- to a newer press, or to the key let go, does nothing. Cleanup cancels.
local REPEAT_BEATS = { 2, 1, 0.5, 0.25, 0.125 }
local REPEAT_NAMES = { "1/2", "1/4", "1/8", "1/16", "1/32" }
local repeat_clock          -- the newest coroutine waiting for the division
local repeat_gen = 0        -- bumped by every press and every release
local repeat_on = false     -- the engine holds a repeat now
local function repeat_beats()
  return REPEAT_BEATS[math.floor(pget("repeat_div", 3) + 0.5)] or 0.5
end
local function repeat_secs()
  return min(2, repeat_beats() * 60 / ctx.tempo())
end
local function repeat_release()
  repeat_gen = repeat_gen + 1
  if repeat_on and engine.beat_repeat then engine.beat_repeat(0) end
  repeat_on = false
end
local function repeat_start()
  if not engine.beat_repeat then
    print("four: engine has no `beat_repeat` — SYSTEM > RESTART for the new engine")
    return
  end
  if pget("stop_all", 0) == 1 then return end
  repeat_gen = repeat_gen + 1
  local g, b = repeat_gen, repeat_beats()
  repeat_clock = clock.run(function()
    clock.sync(b)
    if g ~= repeat_gen or pget("beat_repeat", 0) ~= 1
        or pget("stop_all", 0) == 1 then return end
    engine.beat_repeat(repeat_secs())
    repeat_on = true
  end)
end
ctx.repeat_release = repeat_release
-- the engine is looping a slice now (not just held, waiting for its beat)
function ctx.repeat_live() return repeat_on end

-- tempo-synced delay: when delay_sync is not FREE, delay_time follows the
-- clock at the chosen division. computed here (Lua) so the ENGINE command
-- set is untouched; the engine's 0.2s time-lag turns tempo changes into a
-- tape-style glide, and times beyond the 2s delay line clamp there (2s so
-- a half note fits down to 60 BPM).
-- While synced the clock OWNS the time: anything else that writes it (a hand
-- on the knob, a scene, the morph, a motion lane) is put back on the grid the
-- next frame, so the echoes cannot sit off the beat until the tempo happens
-- to change. The redraw tick calls this each frame and it writes only when
-- the time is off by more than half a percent, so MIDI clock jitter does not
-- write every frame.
local SYNC_BEATS = { 0, 0.25, 0.5, 0.75, 1, 1.5, 2 }  -- FREE 1/16 1/8 1/8. 1/4 1/4. 1/2
local function sync_delay_time(force)
  local s = pget("delay_sync", 1)
  if s <= 1 then return end                          -- FREE
  local t = ctx.tempo()
  if not (t and t > 0) then return end
  local want = clamp(SYNC_BEATS[s] * 60 / t, 0.01, 2)
  if not force and math.abs(pget("delay_time", want) - want) <= want * 0.005 then
    return
  end
  params:set("delay_time", want)
  -- tell the gesture looper this wasn't a hand on the knob (its polling
  -- capture would otherwise punch a delay_time lane on every tempo move)
  if ctx.motion and ctx.motion.account then ctx.motion.account("delay_time") end
end

-- DRY throw (K1+K3 tap on any page, grid (7,2)): playback becomes the un-effected
-- sample — every "on top" color to zero (delay, reverb, shimmer, drive,
-- clouds feedback — the one wash the REVERB page can't kill) and the
-- filter thrown open (type-aware, same law as FILTER's OPEN key). the
-- take itself is always recorded clean; this clears the playback path.
-- DRY IS A THROW (C9 of doc/signature-workflow.md): a second tap brings back
-- what the first one moved, so a slip of K3 under K1 costs nothing. It opens
-- the filter of every track. A recall, a morph or a pset load forgets it, as
-- it forgets every throw (ctx.throws_forget).
local DRY_IDS = { "delay_mix", "rev_mix", "shimmer", "clouds_fb" }
for n = 1, NTRACKS do
  local pre = n == 1 and "" or ("t" .. n .. "_")
  for _, id in ipairs({ "drive", "crush", "effect", "effect2", "cutoff", "resonance" }) do
    DRY_IDS[#DRY_IDS + 1] = pre .. id
  end
end
ctx.DRY_IDS = DRY_IDS
function ctx.dry_lit() return throw_mem.DRY ~= nil end
function ctx.fx_dry()
  if throw_mem.DRY then
    throw_restore("DRY")
    print("four: DRY again: the wet path is back")
    return
  end
  ctx.throws_forget()   -- DRY moves the wet path wholesale: no throw's "back"
                        -- survives it (a latched WASH would restore reverb)
  local mem = {}
  for k = 1, #DRY_IDS do
    local id = DRY_IDS[k]
    if params.lookup[id] then mem[id] = params:get(id) end
  end
  throw_mem.DRY = mem
  params:set("delay_mix", 0)
  params:set("rev_mix", 0)
  params:set("shimmer", 0)
  params:set("clouds_fb", 0)
  for n = 1, NTRACKS do
    local pre = n == 1 and "" or ("t" .. n .. "_")
    params:set(pre .. "drive", 0)
    params:set(pre .. "crush", 0)
    params:set(pre .. "effect", 1)
    params:set(pre .. "effect2", 1)
    params:set(pre .. "cutoff", filter_open_cutoff(params:get(pre .. "filt_type")))
    params:set(pre .. "resonance", 0)
  end
  print("four: DRY: the wet path is off, every filter open. K1+K3 again brings it back")
end

-- ============================================================================
-- params  (single source of truth: keys, encoders, and MIDI all drive these)
-- ============================================================================
-- every param's action sends the engine command of the same id, so the
-- engine command table and these ids must stay in lockstep (see the .sc file).

-- `map` (optional) is a response curve applied to the param value before it
-- reaches the engine — e.g. the FX sends pass `square` so the engine's
-- equal-power .sqrt crossfade reads LINEAR in the knob (0 stays truthy in Lua,
-- so a 0 map result still short-circuits correctly).
-- the send map of each engine control, by id: the modulators (lib/mlfo.lua)
-- send the engine a swung value through the same map the action uses
ctx.eng_map = {}
local function add_eng_control(id, name, spec, map)
  ctx.eng_map[id] = map
  params:add_control(id, name, spec)
  params:set_action(id, function(v)
    -- a modulated knob sends its value WITH the swing, so a hand, a scene or
    -- a motion lane moving it between the modulator's frames never sends the
    -- plain value in between (a spike, and a zipper on every move)
    if Mlfo.swinging(id) then v = Mlfo.swung(id, v) end
    if engine[id] then engine[id](map and map(v) or v) end
  end)
end
local function square(v) return v * v end

-- delay feedback response. the raw knob is 0..1 but
-- audible repeat-count is a ln-law of the loop gain, so a LINEAR knob crams
-- every useful value into the top few percent ("~4 quiet repeats then jumps to
-- infinite"). this concave curve spreads the knob across the musical band —
-- quarter ~3 repeats, half ~6, three-quarter ~14, top a near-infinite hold —
-- and is SHARED with the DELAY page (ctx.delay_fb_curve) so the drawn echo
-- taps decay at the feedback you actually hear, not the raw knob.
local function fb_curve(v) return 0.98 * v ^ 0.6 end
ctx.delay_fb_curve = fb_curve

local function add_eng_binary(id, name)
  params:add_binary(id, name, "toggle", 0)
  params:set_action(id, function(v)
    if engine[id] then engine[id](v) end
  end)
end

-- an option whose engine command wants a 0-based index (norns options count
-- from 1), sent through the same guard as every other engine command
local function add_eng_option(id, name, options, default)
  params:add_option(id, name, options, default)
  params:set_action(id, function(v)
    if engine[id] then engine[id](v - 1) end
  end)
end

-- a MOMENTARY binary that fires `fn` on the press edge only: a stray 0 (from
-- params:bang or a pset read) must never do anything. momentary rather than a
-- trigger because a trigger cannot be MIDI-learned, and the point of most of
-- these is a footswitch.
local function add_momentary(id, name, fn)
  params:add_binary(id, name, "momentary", 0)
  params:set_action(id, function(v) if v == 1 then fn() end end)
end

-- a plain 0..1 knob, the commonest spec in the paramset; fine_unit adds the
-- 0.002 quantum the region edges use (fine_delta then scales it by the span:
-- the default 0.01 is 600ms of a 60s buffer, far too coarse to set a loop)
local function unit(default) return controlspec.new(0, 1, "lin", 0, default, "") end
local function fine_unit(default)
  local spec = unit(default)
  spec.quantum = 0.002
  return spec
end

local function init_params()
  params:add_separator("four")

  -- group ids must differ from every param id, and the declared count MUST
  -- match the adds that follow (a refused/missing add corrupts the paramset)
  params:add_group("grp_mix", "mix", 5)
  params:add_control("mix", "eng <> tape", unit(0.5))
  params:set_action("mix", Mtape.update_mix)
  params:add_control("out_level", "out level",
    controlspec.new(0, 1.5, "lin", 0, 1.0, ""))
  params:set_action("out_level", Mtape.update_mix)
  params:add_control("sc_level", "eng level", unit(1.0))
  params:set_action("sc_level", Mtape.update_mix)
  -- id "tape_level" is RESERVED by the system TAPE deck; "cut_level" avoids it
  params:add_control("cut_level", "tape level", unit(1.0))
  params:set_action("cut_level", Mtape.update_mix)
  -- master transport: STOP chokes every deck at the one place each level is
  -- computed and halts their heads (below), so START restores the exact mix
  -- from the exact spot. held pad voices are released. MIDI-map it for a stop
  -- pedal; SPACE on a typing keyboard and grid (8,2) drive it too.
  params:add_binary("stop_all", "stop all", "toggle", 0)
  params:set_action("stop_all", function(v)
    if v == 1 then ctx.pads_all_off(); repeat_release() end
    Mtape.update_mix()
    -- TRUE STOP (S23 B1): the transports HALT too, not just the levels. every
    -- softcut head glides to rate 0 (the slew keeps it click-free) and START
    -- resumes each exactly where it stood — and because they all stop AS ONE,
    -- the decks' relative drift survives a stop/start. the rate/rec laws fold
    -- (1 - stop_all), so re-sending them applies it in both directions. the
    -- engine drone's head freezes on its own: its level lands at 0 and the
    -- read head runs on (level > 0), same law as the erosion/regen heads.
    Mtape.update_tape_rate()
    Mtape.update_tape_rec()
    -- the engine record head pauses with everything else. the param stays
    -- armed, so START resumes the take mid-punch; the rec action gates its
    -- own sends the same way, so arming DURING a stop also waits for START.
    if engine.rec then engine.rec(v == 1 and 0 or pget("rec", 0)) end
  end)

  params:add_group("grp_rec", "take - record", 21)
  add_eng_binary("rec", "record")
  -- when capture stops, snap the window to the take just recorded so playback
  -- immediately loops what you played — not a 60s window of mostly silence
  params:set_action("rec", function(v)
    -- (a stop that waits for the clock puts the param back: nothing to do)
    if ctx.rec_hold then return end
    if v == 1 then
      -- a source that cannot record into this track refuses the arm
      local why = ctx.relay_refusal(FOCUS)
      if why then
        take_say(why, "REC refused: " .. why)
        params:set("rec", 0)
        return
      end
      -- the take before the pass is what UNDO brings back. A take that a
      -- PSET restored on another track has no mark yet: mark it now
      if undo_cur == nil and ctx.wave_any then ctx.undo_mark() end
      -- ...and the pass waits until that copy is on the card (undo_settled)
      if not ctx.undo_settled() then
        if ctx.arm_waiting then
          -- a second press while it waits: the arm is called off
          ctx.arm_waiting = false
          take_say("REC CALLED OFF", "REC called off while it waited for the UNDO copy")
        else
          ctx.arm_waiting = true
          take_say("REC - KEEPING UNDO", "REC waits for the UNDO copy to be written")
        end
        params:set("rec", 0)
        return
      end
      -- A TAKE ON THE CLOCK (the sixty-ninth change, rec_sync): a new take
      -- waits for the next beat or bar line, and ctx.on_beat arms it there.
      -- A second press while it waits calls it off. An arm the instrument
      -- makes itself (ctx.rec_set) does not wait, nor does an overdub.
      local q = ctx.rec_sync_beats()
      local new_take = pget("pre_level", 0) < 0.001
      if q > 0 and new_take and not ctx.sync_go and not ctx.rec_force then
        local word = ctx.rec_sync_word()
        if ctx.sync_arm then
          ctx.sync_arm = false
          take_say("REC CALLED OFF", "REC called off while it waited for the " .. word)
        else
          ctx.sync_arm = true
          take_say("REC ON " .. word, "REC waits for the next " .. word)
        end
        params:set("rec", 0)
        return
      end
      ctx.sync_arm = false
      ctx.rec_synced = q > 0 and new_take and ctx.sync_go == true
      ctx.rec_sync_q, ctx.rec_arm_beats = q, ctx.beats()
      -- EACH PART STARTS AT THE START OF ITS OWN BUFFER (C4 of
      -- doc/signature-workflow.md, the forty-ninth change). The write head
      -- is one for the four tracks, and it stopped where a pass ended. The
      -- next pass went on from there, on any track: four parts of 20 s did
      -- not fit, and the part that crossed the end became a 60 s loop with
      -- silence in it. A new take (overdub at 0) now tells the engine to put
      -- the head at 0, BEFORE the rec below. An overdub goes on from where
      -- the head is, as before. So does a STOP and START inside a pass: the
      -- stop action sends the engine its rec, and never comes through here.
      local fresh = pget("pre_level", 0) < 0.001 and ctx.head_resets()
      -- AN ALIGNED OVERDUB (the sixty-seventh change, rec_align): it writes
      -- where the track plays, and loops in its window
      local aligned = not fresh and ctx.aligns()
      rec_track(FOCUS, fresh and 1 or (aligned and 2 or 0))
      ctx.rec_aligned, ctx.rec_arm_frame = aligned, ctx.frame
      if fresh then
        ctx.rec_phase, ctx.rec_reset_at = 0, ctx.frame
      end
      -- the head starts to move now, from the place the script holds
      ctx.rec_poll_time = util.time and util.time() or nil
    end
    -- ...and its stop waits for the next line too, so the take is whole
    -- beats or bars. The param goes back to 1 while it waits, so the page
    -- still says REC. A second press stops at once.
    if v == 0 and rec_open and ctx.rec_synced and not ctx.sync_go and not ctx.rec_force then
      if ctx.sync_stop then
        ctx.sync_stop = false
      else
        ctx.sync_stop = true
        local word = ctx.rec_sync_word()
        take_say("STOP ON " .. word, "the take stops at the next " .. word)
        ctx.rec_hold = true
        params:set("rec", 1)
        ctx.rec_hold = false
        return
      end
    end
    if engine.rec then
      -- under a STOP everything is halted, capture included: an arm made
      -- while stopped takes effect on START (the stop action re-sends it).
      -- the window bookkeeping below still runs — the head is frozen, so
      -- the arm position it records is exactly where START will resume.
      engine.rec(pget("stop_all", 0) == 1 and 0 or v)
    end
    if v == 1 then
      -- (four) a track you record into plays: an OFF track goes to PLAY
      if FOCUS > 1 and pget("t" .. FOCUS .. "_mode", 1) == 1 then
        params:set("t" .. FOCUS .. "_mode", 5)
      end
      -- ...and is heard: a take into a muted track came back silent
      if pget(ctx.MUTE_ID[FOCUS], 0) == 1 then params:set(ctx.MUTE_ID[FOCUS], 0) end
      rec_open = true
      rec_wrapped, rec_last = false, ctx.rec_phase
      take_gen = take_gen + 1   -- a live pass outranks a conversion in flight
      ctx.rec_arm_phase = ctx.rec_phase
      -- a fresh pass for start on sound (see tick_rec_wait)
      rec_heard, rec_quiet, rec_moved = false, ctx.rec_phase, false
      ctx.rec_waiting = waits()
      return
    end
    -- the rec-stop bookkeeping runs only for a pass that was really OPENED.
    -- params:bang() at init fires this action with 0, and with pos_end at 1
    -- that set take_len to the whole buffer before anything was recorded, so
    -- the first take of every session saved, chopped and recalled scenes as
    -- if it were 60 seconds long.
    if not rec_open then return end
    rec_open = false
    if ctx.rec_waiting then
      ctx.rec_waiting = false
      print("four: no sound crossed the threshold — the take is the whole pass")
    end
    -- THE END OF THE TAKE IS WHERE THE HEAD IS NOW, not where its last poll
    -- saw it. The poll comes once a frame, so the window ended up to 67 ms
    -- before the stop, and the loop lost that much of what was played. The
    -- head moves at one second a second while it records: add the time since
    -- the poll, one frame at most. A head held by a STOP or a freeze has not
    -- moved since.
    local now = ctx.rec_phase
    if ctx.rec_poll_time and util.time and pget("stop_all", 0) == 0
        and pget("freeze", 0) == 0 then
      now = now + clamp(util.time() - ctx.rec_poll_time, 0, 1 / FPS) / BUF_SECS
      if now >= 1 then now, rec_wrapped = now - 1, true end
    end
    -- the window writes go through set_pair, widening edge first: a take
    -- laid down past the old window's end used to cross the pair for a moment
    local aligned = ctx.rec_aligned
    ctx.rec_aligned = false
    if aligned then
      -- an aligned overdub wrote inside the window it plays: the window
      -- stays as it is (the sixty-seventh change)
    elseif rec_wrapped then
      -- the pass came round the end of the buffer (LOOP: it is longer than
      -- 60 s, or an overdub began near the end). A window cannot cross the
      -- seam, so the take is the whole buffer.
      Mdeck.set_pair(WIN[1], WIN[2], 0, 1)
    elseif rec_moved and now >= ctx.rec_arm_phase then
      -- started on sound: a hit stopped soon after is still a take (at least
      -- the 0.3s floor below), not the previous take's window over silence
      local a = ctx.rec_arm_phase
      Mdeck.set_pair(WIN[1], WIN[2], a, max(now, min(1, a + 0.005)))
    elseif now > ctx.rec_arm_phase + 0.005 then
      Mdeck.set_pair(WIN[1], WIN[2], ctx.rec_arm_phase, now)
    elseif now < ctx.rec_arm_phase - 0.005 then
      -- the write head wrapped past the buffer end mid-take. a wrapped
      -- window (start > end) would be SORTED into the wrong slice by
      -- window_bounds, so fall back to the whole buffer — the take is in
      -- there, just split across the seam. (proper wrap-around windows
      -- need engine support.)
      Mdeck.set_pair(WIN[1], WIN[2], 0, 1)
    end
    rec_moved = false
    -- A TAKE ON THE CLOCK is whole beats or bars from its arm: the window is
    -- put on that length to the sample, and the track is locked to it (it
    -- keeps that length on a tempo move, and its head restarts on the line,
    -- see ctx.on_beat). A pass shorter than one line keeps its own window.
    ctx.sync_stop = false
    if ctx.rec_synced and not aligned then
      local q = ctx.rec_sync_q or 4
      local units = math.floor((ctx.beats() - (ctx.rec_arm_beats or 0)) / q + 0.02)
      local a = ctx.rec_arm_phase or 0
      local want = a + units * q * 60 / ctx.tempo() / BUF_SECS
      if units >= 1 and want <= 1 then
        Mdeck.set_pair(WIN[1], WIN[2], a, want)
        ctx.lock_track(FOCUS, units * q)
      end
    end
    ctx.rec_synced = false
    -- the take bounds what a PSET save writes (the write head runs
    -- 0..pos_end). regen fills the whole buffer, so it forces a full save.
    -- GROW ONLY: this is a high-water mark, and a rec pass overwrites only
    -- the region it recorded — everything else is still in the buffer. A
    -- short punch-in over a narrowed window used to REPLACE the mark with
    -- that narrow pos_end, so the next PSET save wrote a few seconds and the
    -- rest of the take was gone on reload, with no error anywhere. Fresh
    -- material resets the mark on purpose (clear/load/print), never a punch.
    local bound = pget("regen", 0) > 0 and 1 or pget(WIN[2], 1)
    if bound > (ctx.take_len or 0) then ctx.take_len = bound end
    if not aligned then
      apply_window_len()   -- a locked length: the new take is that long
    end
    ctx.undo_mark()
  end)
  -- START ON SOUND: an arm records at once, and the take starts where the
  -- sound first crosses the threshold (see tick_rec_wait). The level is
  -- what is being written (the engine's rec_amp), so a resample counts too.
  -- (four) what a pass does at the end of its track's 60s: LOOP records
  -- over the start, ONE-SHOT ends the take and records on into the next track
  params:add_option("rec_end", "rec end", { "LOOP", "ONE-SHOT" }, 1)
  -- WHERE AN OVERDUB WRITES (the sixty-seventh change). ALIGN: at the place
  -- the track plays, looping in its window, so what you play lands where
  -- you hear it. FREE: on from the write head, where the last pass stopped
  -- (four's law before). A new take starts at the buffer's start either way.
  params:add_option("rec_align", "overdub head", { "FREE", "ALIGN" }, 2)
  -- A NEW TAKE ON THE CLOCK (the sixty-ninth change): FREE starts and stops
  -- at the press. BEAT and BAR wait for the next line, both ways.
  params:add_option("rec_sync", "take on clock", { "FREE", "BEAT", "BAR" }, 1)
  -- RELAY: what a take records from (TAKE K1+E3). A track is that track
  -- after its filter, colour, effects and level, before its sends.
  params:add_option("rec_source", "rec source", SRC_NAMES, 1)
  params:set_action("rec_source", function()
    -- the engine takes the source at the arm: a change during a pass waits
    if pget("rec", 0) == 1 then
      take_say("SOURCE AT THE NEXT TAKE", "the take's source changes at the next arm")
    end
  end)
  params:add_binary("rec_wait", "start on sound", "toggle", 0)
  params:add_control("rec_thresh", "sound threshold",
    controlspec.new(0.002, 0.5, "exp", 0, 0.02, ""),
    function(p) return string.format("%.0f dB", 20 * math.log(p:get(), 10)) end)
  add_eng_control("rec_level", "rec level", unit(1.0))
  add_eng_control("pre_level", "overdub", unit(0.0))
  add_eng_binary("freeze", "freeze")
  add_eng_control("dry_wet", "dry/wet", unit(0.5))
  add_eng_control("resample", "resample (in<>out)", unit(0.0))
  -- self-resampling: continuous feedback of the processed OUTPUT back into
  -- the record buffer (Basinski-style regenerative decay). 0 = off (a fresh
  -- take stays dry). manual rec + freeze suspend it; engine-side it's a bounded
  -- convex crossfade so it can't run away.
  params:add_control("regen", "regen (self-resample)", unit(0.0))
  params:set_action("regen", function(v)
    -- the other half of the erode interlock (see grp_erode below)
    if v > 0 and pget("erode", 0) > 0 then params:set("erode", 0) end
    if engine.regen then engine.regen(v) end
    if v > 0 then strip_wrote() end
    -- regen's record head traverses the WHOLE buffer, so once it runs the take
    -- can be anywhere: force a full-buffer PSET save (sticky until the next
    -- fresh rec / load / clear resets take_len), never truncate its decay tail.
    if v > 0 then ctx.take_len = 1 end
  end)
  -- delete the take (the TAKE page's K1+K3 erase arc) and load one off the
  -- disk. clear is a MOMENTARY binary so a footswitch can wipe between takes;
  -- it fires on the press edge only, so a stray 0 from bang/pset does nothing.
  add_momentary("clear_rec", "clear recording", ctx.clear_recording)
  -- add_file opens norns' fileselect in the menu and the path rides the PSET,
  -- so a saved session reloads its sample
  params:add_file("sample_file", "load sample", _path.audio)
  params:set_action("sample_file", function(f) ctx.load_sample(f) end)
  -- export the take as a browsable stereo wav in dust/audio.
  -- momentary so a footswitch/grid can fire it; press edge only.
  add_momentary("export_take", "export take (wav)", ctx.export_take)
  -- pull the window in onto the sound (see ctx.take_tighten). momentary so a
  -- footswitch reaches it; non-destructive — it only moves the window edges.
  add_momentary("take_tighten", "tighten window to sound", ctx.take_tighten)
  -- UNDO: one step back to the take before the last finished change, and
  -- again to return (see ctx.take_undo). `undo_keep` off saves the card.
  add_momentary("take_undo", "undo take", ctx.take_undo)
  params:add_binary("undo_keep", "keep an undo", "toggle", 1)
  -- PRINT the master mix back into the buffer (see ctx.print_take). momentary
  -- so a footswitch fires the whole bounce; press edge only.
  add_momentary("print_take", "print mix -> take", ctx.print_take)
  params:add_control("print_len", "print length",
    controlspec.new(0, 16, "lin", 0.5, 0, "s"),
    function(p)
      local v = p:get()
      return v < 0.05 and "AUTO (window)" or string.format("%.1f s", v)
    end)

  params:add_group("grp_window", "take - window", 6)
  -- fine_unit: ~10ms nudges on a tight window once fine_delta scales it
  add_eng_control("pos_start", "win start", fine_unit(0.0))
  add_eng_control("pos_end", "win end", fine_unit(1.0))
  -- the window's LENGTH on the clock (see sync_window_len): FREE, or a
  -- length in beats that the start carries with it
  params:add_option("win_beats", "win length", WIN_BEAT_NAMES, 1)
  params:set_action("win_beats", function() apply_window_len() end)
  -- LOOP SYNC (the sixty-ninth change): the head of a track locked to whole
  -- beats starts again at its window's start on the clock (ctx.on_beat)
  params:add_option("loop_sync", "loop sync", { "OFF", "ON" }, 2)
  -- a start that jumps past a locked window's end takes the end with it at
  -- once (see sync_window_len), so the engine never reads a crossed pair
  params:set_action("pos_start", function(v)
    if engine.pos_start then engine.pos_start(v) end
    if WIN[1] == "pos_start" and win_lock_beats() > 0 and v >= pget("pos_end", 1) then
      apply_window_len()
    end
  end)
  add_eng_control("scan", "scan rate",
    controlspec.new(-2, 2, "lin", 0, 1.0, "x"))
  add_eng_control("pos_jitter", "jitter", unit(0.0))

  params:add_group("grp_grain", "voice - grain", 9)
  add_eng_control("size", "size",
    controlspec.new(0.01, 0.5, "exp", 0, 0.1, "s"))
  add_eng_control("density", "density",
    controlspec.new(1, 200, "exp", 0, 20, "hz"))
  -- pitch is playable chromatically: MIDI notes set it (see grp_keys), and
  -- pitch_quant snaps encoder/CC moves to semitones on the way to the engine
  -- (the param keeps the raw value; only the engine command is quantized)
  params:add_control("pitch", "pitch",
    controlspec.new(0.25, 4, "exp", 0, 1.0, "x"),
    function(p)
      local v = p:get()
      if pget("pitch_quant", 0) == 1 then
        return string.format("%+d st", util.round(12 * math.log(v, 2)))
      end
      return string.format("%.2f x", v)
    end)
  params:set_action("pitch", function(v)
    if pget("pitch_quant", 0) == 1 then
      v = 2 ^ (util.round(12 * math.log(v, 2)) / 12)
    end
    if engine.pitch then engine.pitch(v) end
  end)
  add_eng_control("spread", "spread", unit(0.5))
  add_eng_control("pan", "pan",
    controlspec.new(-1, 1, "lin", 0, 0.0, ""))
  -- (track 1's level: the id is mangler's. The map is the mute, see
  -- ctx.track_gain.)
  add_eng_control("grain_level", "t1 level",
    controlspec.new(0, 1.5, "lin", 0, 1.0, ""), function(v) return v * ctx.track_gain(1) end)
  -- granular character: grain jitter (0 = a regular, steady stream of
  -- equal grains; 1 = Poisson timing and lengths that vary), the detune
  -- spread (0 = off), and a 3-way grain-envelope shape. shape is
  -- an option (engine wants 0/1/2, norns options are 1-based, so -1 in the
  -- action — same trick as `mode`).
  add_eng_control("grain_jitter", "grain jitter", unit(0.0))
  add_eng_control("grain_pitch_spread", "pitch spread",
    controlspec.new(0, 12, "lin", 0, 0.0, "st"))
  add_eng_option("grain_shape", "grain shape", { "HANN", "WELCH", "PERC" }, 1)

  -- MiClouds granular controls (CLOUD mode uses the Clouds voice when
  -- mi-UGens are installed; on the GrainBuf fallback these are stored but
  -- ignored — same guarded philosophy as the JPverb-only reverb params). the
  -- shared size/density/spread/pitch already remap to Clouds; these are the
  -- Clouds-specific attributes. PARAMS (and MIDI) only: VOICE's GRAIN face
  -- carries size/density.
  params:add_group("grp_clouds", "voice - clouds", 5)
  add_eng_control("clouds_pos", "grain position", unit(0.5))
  add_eng_control("clouds_tex", "grain texture", unit(0.5))
  add_eng_control("clouds_fb", "grain feedback", unit(0.0))
  add_eng_option("clouds_mode", "clouds mode",
    { "GRANULAR", "STRETCH", "LOOP", "SPECTRAL" }, 1)
  add_eng_control("clouds_lofi", "grain lofi", unit(0.0))

  params:add_group("grp_stretch", "voice - stretch", 5)
  -- mode swaps the playback synth in the engine: only the active algorithm
  -- costs CPU; OFF frees the SC voice entirely
  -- PLAY (clean straight loop = the exact recorded sample) is the
  -- DEFAULT so a fresh take plays back untouched; GRAIN/WARP/PV are switched
  -- on for mangling. appended (not reordered) so 1..4 keep their meaning.
  add_eng_option("mode", "mode", MODE_NAMES, 5)
  add_eng_control("warp_window", "warp window",
    controlspec.new(0.05, 0.5, "exp", 0, 0.25, "s"))
  params:add_number("warp_overlaps", "warp overlaps", 1, 8, 4)
  params:set_action("warp_overlaps", function(v)
    if engine.warp_overlaps then engine.warp_overlaps(v) end
  end)
  add_eng_control("warp_rand", "warp rand", unit(0.0))
  add_eng_binary("pv_freeze", "pv freeze")

  params:add_group("grp_tape", "tape", 9)
  params:add_binary("tape_rec", "tape record", "toggle", 0)
  -- mirror the SC side's workflow: arming with no overdub opens the loop to
  -- the full tape for a fresh take and puts the head at the tape's start;
  -- stopping snaps the loop around the take and jumps the head to its start,
  -- so it plays back tight immediately.
  -- lib/mdeck.lua holds the same law as arm_loop / close_loop.
  -- This is the older, hand-written copy, still here on purpose: lib/mtape.lua
  -- explains why and lists where the two differ. Change one, change both.
  params:set_action("tape_rec", function(v)
    if v == 1 then
      -- Replace means "record a new take", overdub means "add to the one you
      -- already have". Only the first of those is allowed to re-cut the loop
      -- when you stop. Without this mark, stopping an overdub set the loop to
      -- whatever stretch happened to go by, so every layer you stacked made
      -- the loop shorter, down towards a tenth of a second, with all the
      -- audio still sitting in the buffer. Mdeck.arm_loop draws the same line
      -- by asking whether the deck already holds anything.
      tape_arm_phase, tape_arm_was, tape_arm_jumped = nil, nil, nil
      ctx.tape_heard, ctx.tape_quiet, ctx.tape_msg = false, 0, nil
      if pget("tape_pre", 0) == 0 then
        -- remember the loop this pass widens: a pass too short to be a loop
        -- puts it back (Mdeck.arm_loop does the same with arm_was)
        tape_arm_was = { pget("loop_start", 0), pget("loop_end", 1) }
        if (pget("loop_end", 1) - pget("loop_start", 0)) < 0.99 then
          Mtape.set_loop(0, 1)
        end
        -- A NEW TAKE STARTS AT THE START OF THE TAPE (the forty-eighth
        -- change). The head runs on while nothing records, so a pass began
        -- anywhere in the 60 s. One that crossed the tape's end could not
        -- become a loop: the whole tape stayed open, and the take came back
        -- once a minute. A pass of 8 s did that one time in seven (gate row
        -- 19.31 met it on its first run). A tape that plays backward keeps
        -- the old law: its pass starts where the head is.
        tape_arm_jumped = Mtape.forward()
        if tape_arm_jumped then Mtape.jump_to(0) end
        ctx.tape_deck.wrapped = false
        tape_arm_phase = ctx.tape_phase
      end
    elseif not tape_arm_phase then
      -- an overdub, or a pass this action never opened: leave the loop alone
    elseif (tape_arm_jumped and ctx.tape_deck.wrapped)
        or ctx.tape_phase < tape_arm_phase - 0.005 then
      -- the head came round the tape's end: softcut loops can't cross the
      -- seam, so keep the full tape rather than snapping a wrong slice. For
      -- a pass that began at the tape's start this is a pass longer than
      -- the tape, and the page says so.
      Mtape.set_loop(0, 1)
      if tape_arm_jumped then
        ctx.tape_msg, ctx.tape_msg_at = "TAPE FULL - 60 S", ctx.frame or 0
      end
    elseif ctx.tape_phase > tape_arm_phase + 0.005 then
      Mtape.set_loop(tape_arm_phase, ctx.tape_phase)
      Mtape.jump_to(tape_arm_phase)
    elseif tape_arm_was then
      -- too short to be a loop (a mis-tap): give back the loop it widened
      -- instead of leaving the whole 60s tape playing, and put the head
      -- back on it
      Mtape.set_loop(tape_arm_was[1], tape_arm_was[2])
      if tape_arm_jumped then Mtape.jump_to(tape_arm_was[1]) end
    end
    if v == 0 then
      tape_arm_phase, tape_arm_was, tape_arm_jumped = nil, nil, nil
      -- a pass that heard nothing says so: the strip stayed flat, and a
      -- silent source looks like a tape that does not record
      if ctx.tape_heard == false then
        ctx.tape_msg, ctx.tape_msg_at = "NO SOUND RECORDED", ctx.frame or 0
        print("four: the tape pass heard no sound (tape source "
          .. ctx.eff_cut_source() .. ")")
      end
      ctx.tape_heard = nil
    end
    Mtape.update_tape_rec()
  end)
  params:add_control("tape_rate", "tape rate",
    controlspec.new(-2, 2, "lin", 0, 1.0, "x"))
  params:set_action("tape_rate", Mtape.update_tape_rate)
  params:add_binary("tape_reverse", "tape reverse", "momentary", 0)
  params:set_action("tape_reverse", Mtape.update_tape_rate)
  -- same fine quantum + span-scaled deltas as the window edges
  params:add_control("loop_start", "loop start", fine_unit(0.0))
  params:set_action("loop_start", Mtape.update_tape_loop)
  params:add_control("loop_end", "loop end", fine_unit(1.0))
  params:set_action("loop_end", Mtape.update_tape_loop)
  params:add_control("tape_pre", "tape overdub", unit(0.0))
  params:set_action("tape_pre", Mtape.update_tape_rec)
  params:add_binary("tape_freeze", "tape freeze", "toggle", 0)
  params:set_action("tape_freeze", Mtape.update_tape_rec)
  params:add_control("tape_fade", "tape fade",
    controlspec.new(0.001, 0.5, "exp", 0, 0.05, "s"))
  params:set_action("tape_fade", Mtape.set_fade)
  -- tape RECORD SOURCE (K1+E3 on TAPE): 0 = DRY raw input .. 1 = WET, the
  -- engine's output after the effects: the tape as a print / resample stage.
  -- The default is WET since the forty-sixth change (doc/ux-feedback.md, 25).
  -- At DRY a pass recorded the line input alone, so REC over four playing
  -- tracks gave an empty tape, and nothing on the page said why. The engine's
  -- output holds the input too (dry_wet), so a WET pass still hears it.
  params:add_control("cut_source", "tape source", unit(1.0))
  -- through the one source writer
  params:set_action("cut_source", function() ctx.update_cut_source() end)

  params:add_group("grp_filter", "filter", 11)
  add_eng_option("filt_type", "filter type", { "LP", "HP", "BP" }, 1)
  add_eng_control("cutoff", "cutoff",
    controlspec.new(20, 20000, "exp", 0, 20000, "hz"))
  add_eng_control("resonance", "resonance", unit(0.0))
  -- post-filter tanh saturation with makeup: louder AND dirtier up
  add_eng_control("drive", "drive", unit(0.0))
  -- COLOR: sample rate and bit reduction, after the drive (0 = bypass)
  add_eng_control("crush", "crush", unit(0.0))
  -- THE EFFECT: one slot after the COLOR. OFF is a true bypass. The two
  -- knobs mean what the type needs (see fxSlot in the engine): AMOUNT is
  -- depth, feedback, ring time or mix; RATE is speed, note or frequency.
  add_eng_option("effect", "effect", EFFECT_NAMES, 1)
  add_eng_control("effect_amt", "effect amount", unit(0.5))
  add_eng_control("effect_rate", "effect rate", unit(0.5))
  -- THE SECOND SLOT, after the first (the engine's effect2). The same types
  -- and the same two knobs. On the EFFECT page K1+E2 and K1+E3 turn them.
  add_eng_option("effect2", "effect 2", EFFECT_NAMES, 1)
  add_eng_control("effect2_amt", "effect 2 amount", unit(0.5))
  add_eng_control("effect2_rate", "effect 2 rate", unit(0.5))

  -- ---- tracks 2 to 4 (four) -------------------------------------------
  -- more engine drones on the same take: each its own mode, window, pitch,
  -- grain knobs, filter and level. Each id is track 1's with a `t<n>_`
  -- prefix, with the same range, so a knob means the same thing on every
  -- track. OFF by default: a track costs nothing until it is switched on.
  params:add_group("grp_tracks", "tracks", 6)
  -- which track VOICE and FILTER address (K3 held on either page steps it),
  -- and the ROUTE grid's cursor
  params:add_number("track_sel", "track (focus)", 1, NTRACKS, 1)
  params:set_action("track_sel", function(v) ctx.focus_take(v) end)
  params:add_number("route_sel", "route cell", 1, #ROUTES, 1)
  for n = 1, NTRACKS do
    params:add_binary(ctx.MUTE_ID[n], "t" .. n .. " mute", "toggle", 0)
    params:set_action(ctx.MUTE_ID[n], function() ctx.level_send(n) end)
  end
  for n = 2, NTRACKS do
    local pre, lab = "t" .. n .. "_", "t" .. n .. " "
    params:add_group("grp_t" .. n, "track " .. n, 35)
    -- its own material from a file (the take of track n), like `sample_file`
    params:add_file(pre .. "file", lab .. "load file", _path.audio)
    params:set_action(pre .. "file", function(f) ctx.track_load(n, f) end)
    add_eng_option(pre .. "mode", lab .. "mode", MODE_NAMES, 1)
    add_eng_control(pre .. "level", lab .. "level", controlspec.new(0, 1.5, "lin", 0, 1.0, ""),
      function(v) return v * ctx.track_gain(n) end)
    add_eng_control(pre .. "pos_start", lab .. "win start", fine_unit(0.0))
    add_eng_control(pre .. "pos_end", lab .. "win end", fine_unit(1.0))
    -- the lock follows the focus (C10): a start past the focused track's
    -- locked end takes the end with it, as on track 1
    do
      local sid, eid = pre .. "pos_start", pre .. "pos_end"
      params:set_action(sid, function(v)
        local sv = Mlfo.swinging(sid) and Mlfo.swung(sid, v) or v
        if engine[sid] then engine[sid](sv) end
        if WIN[1] == sid and win_lock_beats() > 0 and v >= pget(eid, 1) then
          apply_window_len()
        end
      end)
    end
    add_eng_control(pre .. "scan", lab .. "scan rate", controlspec.new(-2, 2, "lin", 0, 1.0, "x"))
    add_eng_control(pre .. "pitch", lab .. "pitch", controlspec.new(0.25, 4, "exp", 0, 1.0, "x"))
    add_eng_control(pre .. "pan", lab .. "pan", controlspec.new(-1, 1, "lin", 0, 0.0, ""))
    add_eng_control(pre .. "pos_jitter", lab .. "jitter", unit(0.0))
    add_eng_control(pre .. "size", lab .. "size", controlspec.new(0.01, 0.5, "exp", 0, 0.1, "s"))
    add_eng_control(pre .. "density", lab .. "density", controlspec.new(1, 200, "exp", 0, 20, "hz"))
    add_eng_control(pre .. "spread", lab .. "spread", unit(0.5))
    add_eng_control(pre .. "grain_jitter", lab .. "grain jitter", unit(0.0))
    add_eng_control(pre .. "grain_pitch_spread", lab .. "pitch spread",
      controlspec.new(0, 12, "lin", 0, 0.0, "st"))
    add_eng_option(pre .. "grain_shape", lab .. "grain shape", { "HANN", "WELCH", "PERC" }, 1)
    add_eng_control(pre .. "clouds_pos", lab .. "grain position", unit(0.5))
    add_eng_control(pre .. "clouds_tex", lab .. "grain texture", unit(0.5))
    add_eng_control(pre .. "clouds_fb", lab .. "grain feedback", unit(0.0))
    add_eng_option(pre .. "clouds_mode", lab .. "clouds mode",
      { "GRANULAR", "STRETCH", "LOOP", "SPECTRAL" }, 1)
    add_eng_control(pre .. "clouds_lofi", lab .. "grain lofi", unit(0.0))
    add_eng_control(pre .. "warp_window", lab .. "warp window",
      controlspec.new(0.05, 0.5, "exp", 0, 0.25, "s"))
    params:add_number(pre .. "warp_overlaps", lab .. "warp overlaps", 1, 8, 4)
    params:set_action(pre .. "warp_overlaps", function(v)
      local f = engine[pre .. "warp_overlaps"]
      if f then f(v) end
    end)
    add_eng_control(pre .. "warp_rand", lab .. "warp rand", unit(0.0))
    add_eng_binary(pre .. "pv_freeze", lab .. "pv freeze")
    add_eng_option(pre .. "filt_type", lab .. "filter type", { "LP", "HP", "BP" }, 1)
    add_eng_control(pre .. "cutoff", lab .. "cutoff", controlspec.new(20, 20000, "exp", 0, 20000, "hz"))
    add_eng_control(pre .. "resonance", lab .. "resonance", unit(0.0))
    -- COLOR: its own drive and crush (track 1's are `drive` and `crush`)
    add_eng_control(pre .. "drive", lab .. "drive", unit(0.0))
    add_eng_control(pre .. "crush", lab .. "crush", unit(0.0))
    -- its own EFFECT (track 1's are `effect`, `effect_amt`, `effect_rate`)
    add_eng_option(pre .. "effect", lab .. "effect", EFFECT_NAMES, 1)
    add_eng_control(pre .. "effect_amt", lab .. "effect amount", unit(0.5))
    add_eng_control(pre .. "effect_rate", lab .. "effect rate", unit(0.5))
    add_eng_option(pre .. "effect2", lab .. "effect 2", EFFECT_NAMES, 1)
    add_eng_control(pre .. "effect2_amt", lab .. "effect 2 amount", unit(0.5))
    add_eng_control(pre .. "effect2_rate", lab .. "effect 2 rate", unit(0.5))
  end
  -- the sends: one track's filtered output into another track's filter
  -- and each track's SPACE: its send into the delay and the reverb
  params:add_group("grp_routing", "routing", #ROUTES)
  for _, r in ipairs(ROUTES) do
    if r.fx then
      add_eng_control(r.id, "t" .. r.from .. (r.to == NTRACKS + 1 and " > delay" or " > reverb"),
        unit(0.0))
    else
      add_eng_control(r.id, "send " .. r.from .. " > " .. r.to, unit(0.0))
    end
  end

  params:add_group("grp_delay", "delay", 5)
  add_eng_control("delay_time", "delay time",
    controlspec.new(0.01, 2, "exp", 0, 0.3, "s"))
  -- tempo sync (DELAY K1+E3): FREE = the time knob; a division = delay_time
  -- follows the clock (re-asserted on tempo changes from the redraw tick)
  params:add_option("delay_sync", "delay sync",
    { "FREE", "1/16", "1/8", "1/8.", "1/4", "1/4.", "1/2" }, 1)
  params:set_action("delay_sync", function() sync_delay_time(true) end)
  -- 0..1 knob curved to the actual 0..0.98 feedback coefficient (fb_curve):
  -- a smooth "few -> many (10+) -> near-infinite" sweep, not a top-end cliff.
  add_eng_control("delay_fb", "feedback", unit(0.3), fb_curve)
  -- the level of the echoes. The engine adds them to the dry sum at
  -- delay_mix.sqrt (Engine_Four.sc), and the dry never ducks. A raw 3% knob
  -- would already read about 17% ("way too blunt"), so `square` makes the echo
  -- gain LINEAR in the knob. rev_mix works the same way for the tail.
  add_eng_control("delay_mix", "delay mix", unit(0.0), square)
  -- how much of the echoes goes on into the reverb (0: the two are apart)
  add_eng_control("dly_rev", "delay > reverb", unit(0.0))

  -- the reverb params are JPverb's full attribute set. With the plugin the
  -- engine runs FourRoom, which reads only mix, decay, damp and size (size when
  -- the synth starts). The other knobs act on JPverb only, and FreeVerb is the
  -- last fallback (doc/measurements/2026-11-15/README.md, findings m and n).
  -- REVERB face reaches mix/size/decay/damp (E2/E3 + K1 alt);
  -- the other 11 (early/mod/EQ/cuts/shimmer) live in PARAMS + the WASH/BLOOM
  -- throws. shimmer surges on the BLOOM key.
  params:add_group("grp_reverb", "reverb", 15)
  add_eng_control("rev_decay", "reverb decay",
    controlspec.new(0.1, 30, "exp", 0, 2.0, "s"))
  add_eng_control("rev_damp", "reverb damp", unit(0.3))
  add_eng_control("rev_size", "reverb size",
    controlspec.new(0.5, 5, "lin", 0, 1.0, ""))
  add_eng_control("rev_early", "early diffusion", unit(0.7))
  add_eng_control("rev_moddepth", "mod depth", unit(0.1))
  add_eng_control("rev_modfreq", "mod freq",
    controlspec.new(0, 10, "lin", 0, 2.0, "hz"))
  add_eng_control("rev_low", "low decay", unit(1.0))
  add_eng_control("rev_mid", "mid decay", unit(1.0))
  add_eng_control("rev_high", "high decay", unit(1.0))
  add_eng_control("rev_lowcut", "low crossover",
    controlspec.new(20, 2000, "exp", 0, 500, "hz"))
  add_eng_control("rev_highcut", "high crossover",
    controlspec.new(200, 20000, "exp", 0, 2000, "hz"))
  add_eng_control("rev_mix", "reverb mix",
    unit(0.0), square)   -- progressive fade (see delay_mix)
  -- shimmer: pitch-shifted reverb feedback (climbs in octaves into a pad)
  add_eng_control("shimmer", "shimmer", unit(0.0))
  add_eng_control("shimmer_pitch", "shimmer pitch",
    controlspec.new(-12, 24, "lin", 1, 12, "st"))
  add_eng_control("shimmer_tone", "shimmer tone",
    controlspec.new(500, 12000, "exp", 0, 4500, "hz"))

  -- the BEAT REPEAT (see repeat_start): held, a stutter on the clock.
  -- momentary, so a footswitch or a MIDI note holds it
  params:add_group("grp_repeat", "beat repeat", 2)
  params:add_binary("beat_repeat", "beat repeat", "momentary", 0)
  params:set_action("beat_repeat", function(v)
    if v == 1 then repeat_start() else repeat_release() end
  end)
  params:add_option("repeat_div", "repeat length", REPEAT_NAMES, 3)
  params:set_action("repeat_div", function()
    -- a new division while it holds: re-capture now (a roll), or wait on it
    if pget("beat_repeat", 0) ~= 1 then return end
    if repeat_on then engine.beat_repeat(repeat_secs()) else repeat_start() end
  end)

  -- polyphonic voices: the per-note/per-pad layer that coexists with the
  -- drone. `pad_input` reroutes MIDI + grid note-pads to voices instead of
  -- the mono drone pitch (default OFF = existing behavior). voices = poly
  -- cap (oldest-steal in the engine), voice_atk/voice_rel shape each note.
  params:add_group("grp_voice", "pads - voices", 10)
  params:add_binary("pad_input", "pad input", "toggle", 0)
  params:set_action("pad_input", function(v)
    if v == 0 then ctx.pads_all_off() end   -- don't strand voices on switch
  end)
  -- the PADS slice SELECTOR (id kept as `seq_slice` — ids are never renamed, so
  -- PMAP/PSET references survive; the sequencer that shared it is gone). its
  -- action is the ONLY writer of ctx.pad_cursor, so the sound-lock editors
  -- (pad_voice/pad_pitch) follow the selected slice.
  params:add_number("seq_slice", "slice", 0, 7, 0)
  params:set_action("seq_slice", function(v)
    ctx.pad_cursor = v
    ctx.pad_edit_sync()
  end)
  -- SOUND-LOCK EDITORS (Elektron data-knob style): pad_voice + pad_pitch read/
  -- write the pad under pad_cursor, so selecting a pad and turning these edits
  -- THAT pad's lock. GRAIN = granular texture, SLICE = clean chop. MIDI-map them
  -- to edit the current pad live; the 8 locks ride the PSET (padlock_pset_*).
  params:add_option("pad_voice", "pad voice (sel)", { "GRAIN", "SLICE" }, 1)
  params:set_action("pad_voice", function(v)
    if not ctx.pad_sync then ctx.pad_type[ctx.pad_cursor] = v - 1 end
  end)
  params:add_number("pad_pitch", "pad pitch (sel)", -24, 24, 0,
    function(p) local v = p:get(); return (v >= 0 and "+" or "") .. v .. "st" end)
  params:set_action("pad_pitch", function(v)
    if not ctx.pad_sync then ctx.pad_pitch[ctx.pad_cursor] = v end
  end)
  params:add_number("voices", "poly voices", 1, 16, 8)
  params:set_action("voices", function(v)
    if engine.voices then engine.voices(v) end
  end)
  add_eng_control("voice_atk", "voice attack",
    controlspec.new(0.001, 1, "exp", 0, 0.005, "s"))
  add_eng_control("voice_rel", "voice release",
    controlspec.new(0.01, 4, "exp", 0, 0.6, "s"))
  -- pad voice LEVEL (per-note amp): the chord-safe default (0.3, the
  -- level that stops poly stacks slamming the master limiter). read at note-on.
  params:add_control("pad_level", "pad level", unit(0.3))
  -- CHOP the pads onto the take's own attacks. momentary (not a trigger) so it
  -- is MIDI-learnable — the whole point is a footswitch. Firing it with no
  -- transients found, or on a fresh buffer, puts the pads back to even slices.
  add_momentary("pad_chop", "chop to transients", ctx.pad_chop)
  add_momentary("pad_even", "back to even slices", function()
    ctx.pads_uncut()
    print("four: pads back to even slices")
  end)

  -- the pad SEQUENCER (lib/mseq.lua): a generated pattern on the clock that
  -- plays the pads. Every knob rebuilds the pattern in its action, so the
  -- PADS page reads it at rest and no frame computes it.
  params:add_group("grp_steps", "pads - sequencer", 7)
  params:add_binary("step_run", "sequencer run", "toggle", 0)
  params:set_action("step_run", function(v)
    if v == 1 then
      Mseq.start()
      print("four: sequencer running — " .. math.floor(pget("step_fill", 4) + 0.5)
        .. " of " .. math.floor(pget("step_len", 4) + 0.5) .. " steps play the pads")
    else
      Mseq.stop()
    end
  end)
  params:add_option("step_div", "step length",
    { "2 BAR", "1 BAR", "1/2", "1/4", "1/8", "1/16" }, 2)
  params:set_action("step_div", function() Mseq.restart() end)
  params:add_number("step_len", "steps", 1, 16, 4)
  params:set_action("step_len", function() Mseq.rebuild() end)
  params:add_number("step_fill", "steps that play", 0, 16, 4)
  params:set_action("step_fill", function() Mseq.rebuild() end)
  params:add_option("step_order", "pad order", Mseq.ORDERS, 1)
  params:set_action("step_order", function() Mseq.rebuild() end)
  params:add_control("step_chance", "step chance", unit(1.0))
  params:add_control("step_gate", "step gate",
    controlspec.new(0.05, 1, "lin", 0, 1, ""),
    function(p)
      local v = p:get()
      return v >= 0.999 and "LEGATO" or string.format("%d%%", math.floor(v * 100 + 0.5))
    end)

  -- chromatic note input (MIDI notes + typing keyboard): all of it drives
  -- the same `pitch` param as the encoder and any mapped CC, in lockstep
  -- the fader block (lib/minput.lua): eight CCs in a row are the mixer
  params:add_group("grp_faders", "mixer faders", 2)
  params:add_number("fader_ch", "fader channel", 0, 16, 0,
    function(p) local v = p:get(); return v == 0 and "OFF" or tostring(v) end)
  params:add_number("fader_cc", "first fader cc", 0, 120, 0)
  params:set_action("fader_ch", Minput.fader_reset)
  params:set_action("fader_cc", Minput.fader_reset)

  params:add_group("grp_keys", "keys", 5)
  params:add_binary("keys_enable", "note input", "toggle", 1)
  params:add_number("midi_channel", "midi channel", 0, 16, 0,
    function(p)
      local v = p:get()
      return v == 0 and "any" or tostring(v)
    end)
  params:add_number("root_note", "root note", 0, 127, 60,
    function(p) return mu.note_num_to_name(p:get(), true) end)
  -- typing-keyboard octave (Z/X); MIDI keyboards shift octaves themselves
  params:add_number("kb_octave", "keys octave", -3, 3, 0,
    function(p) return string.format("%+d", p:get()) end)
  params:add_binary("pitch_quant", "pitch quantize", "toggle", 0)
  params:set_action("pitch_quant", function()
    -- re-send pitch so the engine snaps (or unsnaps) immediately
    params:lookup_param("pitch"):bang()
  end)

  -- gesture looper: records the param stream (MOTION_IDS) and replays it
  -- (see lib/mmotion). rec/play are binaries so a footswitch can punch overdubs
  -- and start/stop the loop; lane/depth drive the MOTION page. all Lua-only —
  -- no engine command, so the fingerprint is unchanged.
  params:add_group("grp_motion", "motion", 7)
  params:add_binary("motion_rec", "motion record", "toggle", 0)
  params:set_action("motion_rec", function(v) ctx.motion.set_armed(v == 1) end)
  params:add_binary("motion_play", "motion play", "toggle", 0)
  params:set_action("motion_play", function(v) ctx.motion.set_playing(v == 1) end)
  -- one lane per recordable param at most, so the selector reaches them all
  params:add_number("motion_lane", "motion lane", 0, #ctx.motion.MOTION_IDS, 0,
    function(p)
      local ids = ctx.motion.lane_ids
      local n = #ids
      local v = math.min(p:get(), n)
      if n == 0 or v == 0 then return "-" end
      return ids[v]
    end)
  -- which rows MOTION's encoders address: the lanes, or one modulator
  params:add_option("mod_focus", "motion focus", { "LANES", "LFO 1", "LFO 2", "LFO 3", "LFO 4" }, 1)
  params:add_control("motion_depth", "motion depth", unit(1.0))
  -- settable loop length (K1+E2 on MOTION). 0 = AUTO (the recorded length);
  -- >0 retimes the loop's playback SPEED without touching the stored gesture.
  params:add_control("motion_len", "motion length",
    controlspec.new(0, 60, "lin", 0.5, 0, "s"))
  params:set_action("motion_len", function(v) ctx.motion.set_len(v) end)
  -- a first pass on the clock (K1+E3 on MOTION): it closes itself after this
  -- many bars from its first move, and plays. FREE: it closes when you disarm
  params:add_option("motion_bars", "motion pass", ctx.motion.BAR_NAMES, 1)

  -- scenes / morph / safe state (see lib/mscenes). all Lua-only — no
  -- engine command, so the fingerprint is unchanged. the ACTIONS here are
  -- momentary binaries rather than triggers: a trigger can't be MIDI-learned,
  -- and the whole point is a footswitch that captures, recalls, rescues or
  -- throws. every action fires on the press edge (v == 1) only — a stray 0
  -- from params:bang() or a pset read must never do anything.
  params:add_group("grp_scene", "scenes", 13)
  -- ONE selector, three jobs: the slot K2 recalls, K3 captures into, and the
  -- morph aims at (B, the crossfader's right end).
  -- slot 0 is the ◄ cell — the way back (mscenes branches on it)
  params:add_number("scene_slot", "scene slot B", 0, 8, 1)
  params:set_action("scene_slot", function()
    -- re-aim a sweep in progress; at rest, picking a slot must stay silent
    if pget("scene_morph_amt", 0) > 0 then Mscenes.touch() end
  end)
  -- the crossfader's left end (SCENE K1+E2): 0 = LIVE, the sound you have
  -- when the fade leaves 0 (the default, the morph as it always was), or a
  -- stored slot. No action: a fade latches A when it leaves 0 and keeps it
  -- until it comes home, so picking A never moves the sound by itself.
  -- (scene_morph_a/b, deleted in the 38th change, were hidden on the K1
  -- layer; this one is named on the rail and marked on its cell.)
  params:add_number("scene_slot_a", "scene slot A", 0, 8, 0,
    function(p) local v = p:get() return v < 1 and "LIVE" or tostring(v) end)
  -- THE performance knob: fades from A (the sound you have, or slot A)
  -- toward the selected slot B, and back. MIDI-map it to a fader/pedal, or
  -- record it with the gesture looper
  -- (it's in MOTION_IDS — one lane replays the whole sweep). only this writes
  -- params, and only from the next frame's tick (mscenes coalesces so a fast
  -- CC can't flood the engine).
  -- ONE TURN OF E3 IS A WHOLE FADE (C12 of doc/signature-workflow.md). On
  -- the device, with the step of 0.01, one full turn moved the fade by 25%
  -- (the user's count, 2026-11-20), so a step is 0.04. MIDI sets the value
  -- itself and is not stepped.
  do
    local spec = unit(0.0)
    spec.quantum = 0.04
    params:add_control("scene_morph_amt", "morph amount", spec)
  end
  params:set_action("scene_morph_amt", function() Mscenes.touch() end)
  -- when a recall lands: NOW, on the next BEAT or BAR, or GLIDE (the morph
  -- sweeps there over `scene_glide` beats, then the scene lands)
  params:add_option("scene_recall_mode", "recall quantize",
    { "NOW", "BEAT", "BAR", "GLIDE" }, 1)
  params:add_number("scene_glide", "glide beats", 1, 16, 4)
  -- what CAP stores: the whole mangle, or just the wet path (an FX preset
  -- that lands over whatever material is playing — Octatrack-style)
  params:add_option("scene_scope", "capture scope", { "ALL", "FX" }, 1)
  -- actions on the selected slot (also the SCENE page's K2/K3)
  add_momentary("scene_capture", "capture to slot", Mscenes.capture)
  add_momentary("scene_recall", "recall slot", Mscenes.recall)
  -- stomp through a set: advance to the next FILLED slot and recall it
  -- (cycling; honors BEAT/BAR quantize). MIDI-map a footswitch.
  add_momentary("scene_next", "next scene", Mscenes.next)
  add_momentary("scene_clear", "clear slot", Mscenes.clear)
  -- the safety net (the ◄ cell's two actions, for a footswitch): mark a
  -- state, then get back to it. control state only — it never touches the
  -- buffer or the tape audio.
  add_momentary("scene_safe_capture", "mark safe state", Mscenes.safe_capture)
  add_momentary("scene_safe_restore", "restore safe state", Mscenes.safe_restore)
  -- chaos: HOLD it for a bounded random throw, release to land back on the
  -- safe state (it marks one for you if you never did). a footswitch or grid
  -- pad you can lean on — the release is what makes it safe to press.
  params:add_binary("chaos_throw", "chaos throw", "momentary", 0)
  params:set_action("chaos_throw", function(v)
    if v == 1 then Mscenes.chaos() else Mscenes.chaos_release() end
  end)

  -- ORBIT: the instrument wanders between your captured scenes by itself,
  -- one partial morph leg at a time, never fully arriving. all Lua, driven
  -- through the same morph engine and params as a hand on the knob.
  -- (these groups MUST sit after grp_scene's last param, chaos_throw — a
  -- group's declared count claims the params that FOLLOW it, and an insert
  -- mid-group silently corrupts the whole PARAMS menu on device.)
  params:add_group("grp_orbit", "orbit", 3)
  params:add_binary("orbit_on", "orbit run", "toggle", 0)
  params:set_action("orbit_on", function(v) Mscenes.orbit_set(v == 1) end)
  params:add_control("orbit_rate", "orbit drift",
    controlspec.new(2, 60, "lin", 1, 12, "s"))
  params:add_control("orbit_reach", "orbit reach",
    controlspec.new(0.05, 1, "lin", 0, 0.5, ""))

  -- EROSION: window-synced decay in PLAY mode. `erode` is how much of each
  -- loop pass is rewritten aged; `wear` is how dark the aging filter sits.
  params:add_group("grp_erode", "erosion", 2)
  params:add_control("erode", "erode", unit(0.0))
  params:set_action("erode", function(v)
    -- interlock: erode and regen are both free-running write heads on the
    -- same buffer. engaging one disengages the other, so the conflict is
    -- impossible rather than documented. no recursion: each interlock only
    -- acts when its own value is rising.
    if v > 0 and pget("regen", 0) > 0 then params:set("regen", 0) end
    if engine.erode then engine.erode(v) end
    if Mpages.eroding() then strip_wrote() end
  end)
  add_eng_control("wear", "wear", unit(0.5))

  -- the two modulators (lib/mlfo.lua). LAST, so every target already exists
  -- and the target option can carry the targets' own names.
  Mlfo.add_params(function(id, name, n) params:add_group(id, name, n) end)
  Mout.add_params()   -- ...and the modulation out, which reads them
  Msample.add_params()   -- ...and the autosampler (lib/msample.lua)
  Mosc.add_params()   -- ...and the visuals link (OSC), which reads the rest

  -- PSETs persist the audio too: PARAMS > PSET > SAVE/LOAD/DELETE round-trip
  -- the softcut buffers (mtape) AND the granular engine's record
  -- buffer — the live take, as an L/R wav pair beside the pset (ctx.take_pset_*
  -- → engine write_take/read_take). the hooks are SHARED: each module/helper
  -- does its own half (mtape the tape audio, mscenes the scene bank + safe
  -- snapshot as a lua table, the take helpers the engine buffer).
  -- ONE list of the parts, walked by all three hooks, so a new part cannot be
  -- added to two of them. Each part runs under pcall: one that throws (a full
  -- card on the tape wav) must not silently skip the parts after it. ORDER
  -- matters on read: the take restores before the pad locks, which bring
  -- back the chop the take restore drops.
  local PSET_PARTS = {
    { Mtape.pset_write, Mtape.pset_read, Mtape.pset_delete, "tape" },
    { Mscenes.pset_write, Mscenes.pset_read, Mscenes.pset_delete, "scenes" },
    { Mmotion.pset_write, Mmotion.pset_read, Mmotion.pset_delete, "motion" },
    { ctx.take_pset_write, ctx.take_pset_read, ctx.take_pset_delete, "take" },
    { ctx.padlock_pset_write, ctx.padlock_pset_read, ctx.padlock_pset_delete,
      "pad locks" },
  }
  local function each_part(k, number)
    for _, part in ipairs(PSET_PARTS) do
      local ok, err = pcall(part[k], number)
      if not ok then
        print("four: pset " .. part[4] .. " failed — " .. tostring(err))
      end
    end
  end
  params.action_write = function(filename, name, number) each_part(1, number) end
  params.action_read = function(filename, silent, number)
    -- params:read fires tape_rec before the loop points (file order), so a
    -- PSET saved while the tape recorded opened a pass against the OLD
    -- session; its disarm then re-cut the loop just restored.
    tape_arm_phase, tape_arm_was = nil, nil
    -- norns saves a momentary binary like any other, so a PSET saved while
    -- a footswitch held the repeat loads it held, with no release to come
    if pget("beat_repeat", 0) == 1 then params:set("beat_repeat", 0) end
    -- the OSC link is about this room, not a sound: a PSET never changes it
    Mosc.cfg_reload()
    -- a PSET saved before the mutes has no line for them, and norns leaves
    -- what the file does not name: an old preset would load muted
    local fd = type(filename) == "string" and io.open(filename, "r")
    if fd then
      local text = fd:read("a")
      fd:close()
      for n = 1, NTRACKS do
        if not text:find('"' .. ctx.MUTE_ID[n] .. '"', 1, true) then
          params:set(ctx.MUTE_ID[n], 0)
        end
      end
    end
    each_part(2, number)
  end
  params.action_delete = function(filename, name, number) each_part(3, number) end

  params:bang()
end

-- ============================================================================
-- norns callbacks
-- ============================================================================

function init()
  print("four: init() called")
  init_params()
  ctx.undo_forget()   -- an undo pair from the last session is not this one's
  Mtape.init_tape()
  Minput.init_midi()
  Mgrid.connect()
  -- a Launchpad plugged in (or out) after load is picked up: norns calls
  -- these on MIDI hot-plug. the previous callbacks are kept and restored.
  prev_midi_add, prev_midi_remove = midi.add, midi.remove
  midi.add = function(dev)
    if prev_midi_add then prev_midi_add(dev) end
    Mgrid.hotplug()
  end
  midi.remove = function(dev)
    if prev_midi_remove then prev_midi_remove(dev) end
    Mgrid.hotplug(dev)   -- still in midi.devices while this runs
  end
  ctx.splash_from = ctx.frame      -- the opening picture, see Mpages.redraw
  print("four: init() done, params built")

  -- four's own plugin: the binary shipped for this machine goes where
  -- SuperCollider finds it (lib/mplugin.lua), and is heard after a RESTART.
  -- The engine is already built by now, so this load keeps its voices. A
  -- failure here must never stop the instrument.
  local okp, got = pcall(Mplugin.check)
  if not okp then
    print("four: the plugin check failed, four plays on: " .. tostring(got))
  elseif got == "installed" then
    ctx.notice = { "PLUGIN INSTALLED", "SYSTEM > RESTART" }
  end

  -- the norns SYSTEM aux reverb sits after the engine and colors everything;
  -- if another script left it on, "dry" playback isn't — say so at load
  if params.lookup["reverb"]
      and tostring(params:string("reverb")):lower() ~= "off" then
    print("four: NOTE — the SYSTEM reverb is ON; it adds reverb four"
      .. " does not control (turn it off under PARAMS > REVERB)")
  end

  local function watch(name, fn)
    -- poll.set returns nil when the engine doesn't expose the poll (stale
    -- compiled engine after a deploy without restart) — warn, don't crash
    local p = poll.set(name, fn)
    if p == nil then
      print("four: poll '" .. name .. "' missing — old engine? RESTART needed")
      return
    end
    p.time = 1 / FPS
    p:start()
    polls[#polls + 1] = p
  end
  -- the tracks' meters (an engine older than the seventy-fourth change has
  -- none: TRACKS then draws the knob alone, and no line warns)
  ctx.amp_t = { 0, 0, 0, 0 }
  ctx.has_meter = false
  for t = 1, NTRACKS do
    local p = poll.set("amp_t" .. t, function(v) ctx.amp_t[t] = v end)
    if p then
      p.time = 1 / FPS
      p:start()
      polls[#polls + 1] = p
      ctx.has_meter = true
    end
  end
  watch("play_phase", function(v) ctx.play_phase = v end)
  watch("play_phase2", function(v) ctx.play_phase2 = v; ctx.play_phases[2] = v end)
  watch("play_phase3", function(v) ctx.play_phases[3] = v end)
  watch("play_phase4", function(v) ctx.play_phases[4] = v end)
  watch("rec_phase", ctx.head_poll)
  watch("rec_amp", function(v) ctx.rec_amp = v end)
  watch("amp_in_l", function(v) ctx.amp_in[1] = v end)
  watch("amp_in_r", function(v) ctx.amp_in[2] = v end)
  watch("amp_out_l", function(v) ctx.amp_out[1] = v end)
  watch("amp_out_r", function(v) ctx.amp_out[2] = v end)
  -- THE LOAD (C5 of doc/signature-workflow.md). The norns poll cpu_avg is the
  -- load of the whole JACK cycle, in percent. Measured, it reads 5 to 7
  -- points above the scsynth thread, and the thread xruns past about 60%.
  -- So the header says CPU from 62 (the thread near 56), and stops below
  -- 58: two marks, so the word does not flicker at the edge. Twice a
  -- second is enough for a word.
  do
    local p = poll.set("cpu_avg", function(v)
      if v >= 62 then ctx.cpu_high = true elseif v < 58 then ctx.cpu_high = false end
    end)
    if p then
      p.time = 0.5
      p:start()
      polls[#polls + 1] = p
    end
  end

  -- one frame of the instrument
  local function frame_tick()
    ctx.frame = ctx.frame + 1
    ctx.idle_dim = ctx.frame - ctx.last_input > FPS * 120
    sync_delay_time()    -- keep a synced delay on the clock (writes when off)
    sync_window_len()    -- ...and a locked window's length, on a tempo move
    sync_locks()         -- ...and every locked track's (the sixty-ninth change)
    tick_rec_wait()        -- a start-on-sound take begins at the sound
    tick_rec_end()         -- ONE-SHOT: a full track hands on to the next
    -- a REC that waited for the UNDO copy arms once it is written
    if ctx.arm_waiting and ctx.undo_settled() then
      ctx.arm_waiting = false
      if pget("rec", 0) == 0 then params:set("rec", 1) end
    end
    Msample.tick()         -- AUTOSAMPLE: the next note out, or the end of the pass
    Mpages.erosion_tick()  -- count loop passes while the take erodes
    tick_take_strip()      -- repaint the strip once regen and erosion stop
    Mwav.load_tick()   -- fill a loaded/restored waveform a batch/frame
    Mpages.update_wave()
    Mpages.update_tape_wave()
    -- the modulators: they send the engine a swung value and never write a
    -- param, so nothing below (motion, scenes) can see or record them
    Mlfo.tick(max(ctx.amp_in[1], ctx.amp_in[2]))
    Mmotion.tick()   -- advance + replay the gesture loop
    -- apply a pending morph sweep. AFTER motion, which may have just
    -- replayed a recorded scene_morph_amt move for us to act on.
    Mscenes.tick()
    Mout.tick()   -- after the morph and the LFOs moved: send what they are now
    Mosc.tick()   -- the visuals link: the same frame's state, as OSC
    ctx.menu_keys()
    tick_keys()  -- the K1+K3 erase arc fires AT its threshold
    -- never draw over the system menu; the grid stays live inside it
    if norns.menu.status() == false then redraw() end
    Mgrid.redraw()
  end
  -- every per-frame job runs in this ONE coroutine, so an error must not end
  -- it: a dead clock freezes the screen, the morph, motion and the grid
  -- together, and with the frame counter stopped every key press reads as a
  -- tap. The frame is caught, reported (at most every 5 seconds, not 15 times
  -- a second) and the next one runs.
  local last_err_frame = -1e9
  -- A frame is due every 1/FPS of real time. A plain sleep of 1/FPS after
  -- each frame added the frame's own work to the period, so the frames came
  -- at about 14 a second. A frame that runs late moves the deadline to now:
  -- the loop never bursts to catch up. A system clock that jumps (a time sync)
  -- restarts the deadline too, so a jump back can never stall the screen.
  -- ctx.frame_dt is the real time since the last frame, for what must follow
  -- the clock (the FREE modulators). The simulator has no util.time, so there
  -- every frame is 1/FPS.
  local now = util.time
  -- ON EVERY BEAT (the sixty-ninth change). The offscreen norns has no
  -- clock.sync: its tests call ctx.on_beat themselves.
  if clock.sync and clock.get_beats then
    beat_clock = clock.run(function()
      while true do
        clock.sync(1)
        local ok, b = pcall(clock.get_beats)
        if ok and type(b) == "number" then
          local fine, err = pcall(ctx.on_beat, b)
          if not fine then print("four: beat error - " .. tostring(err)) end
        end
      end
    end)
  end
  redraw_clock = clock.run(function()
    local due = now and now() or 0
    local last = due
    while true do
      if now then
        due = due + 1 / FPS
        local t = now()
        local wait = due - t
        if wait < 0 or wait > 2 / FPS then due, wait = t, 0 end
        clock.sleep(wait)
        t = now()
        ctx.frame_dt = max(0, min(t - last, 4 / FPS))
        last = t
      else
        clock.sleep(1 / FPS)
      end
      local ok, err = pcall(frame_tick)
      if not ok and ctx.frame - last_err_frame >= FPS * 5 then
        last_err_frame = ctx.frame
        print("four: frame error, the instrument keeps running — " .. tostring(err))
      end
    end
  end)

  redraw()
  Mgrid.redraw()
end

function cleanup()
  for _, p in ipairs(polls) do p:stop() end
  if redraw_clock then clock.cancel(redraw_clock) end
  if beat_clock then clock.cancel(beat_clock) end
  if export_clock then clock.cancel(export_clock) end  -- stop a pending export
  export_clock, export_next = nil, nil
  ctx.cancel_task()     -- ...and a conversion in flight
  ctx.record_cancel()   -- a recording pass mid-flight: stop the tape with it
  Mwav.cancel_load()  -- close any in-flight waveform read
  Mseq.stop()          -- the sequencer's clock, and its voice
  repeat_release()     -- a held beat repeat...
  if repeat_clock then clock.cancel(repeat_clock) end   -- ...and its clock
  Mlfo.restore_all()   -- every modulated knob's own value back to the engine
  ctx.pads_all_off()   -- release any held pad voices before teardown
  Msample.cleanup()    -- a note an autosample left sounding on the outboard
  Minput.cleanup()
  midi.add, midi.remove = prev_midi_add, prev_midi_remove
  Mgrid.cleanup()
  Mtape.cleanup()      -- (softcut voices are reset by norns after cleanup)
  Mscenes.cleanup()    -- cancel a queued (quantized) scene recall, same reason
end


-- step through the stations (E1, and the Launchpad's arrows). The page name
-- pops big for a moment: the stations scroll past faster than the 1x title
-- reads, and finding the page mid-set should not need squinting (mpages
-- draws the overlay while this is armed).
function ctx.step_page(d)
  ctx.page = clamp(ctx.page + d, 1, #PAGES)
  ctx.page_flash = ctx.frame + math.floor(FPS * 0.7)
end

-- the double tap of K1 (see key below); declared here, where enc reads it
local K1_DOUBLE = math.floor(FPS * 0.4)
local k1_down, k1_used, k1_last_tap = nil, false, nil

function enc(n, d)
  ctx.last_input = ctx.frame
  if ctx.alt then k1_used = true end
  if n == 1 then
    if ctx.alt then
      -- (four) K1+E1 picks the TRACK from any page, the S-4's track
      -- buttons on a knob: the badge in the header and the page name pop
      -- show where you landed. The scene morph lives on SCENE (E3).
      params:delta("track_sel", d)
      ctx.page_flash = ctx.frame + math.floor(FPS * 0.7)
    else
      ctx.step_page(d)
    end
  else
    local id = enc_param(n)
    if id == "@win_move" then
      -- the focused track's window (TAKE follows the focus)
      move_pair(tid("pos_start"), tid("pos_end"), d)
    elseif id == "@route_to" then
      route_step(d)
    elseif id == "@rec_src" and pget("rec", 0) == 1 then
      -- the source of a pass that records cannot change under it
      take_say("SOURCE: STOP REC FIRST", "the take's source changes only between passes")
    elseif id == "@tempo" then
      -- the tempo, when the norns's own clock leads (PARAMS > CLOCK >
      -- source). Another clock sets it: the turn says so and moves nothing.
      local src = ctx.clock_source()
      if src ~= "internal" or not params.lookup["clock_tempo"] then
        ctx.pop_text = "TEMPO: " .. (src == "internal" and "PARAMS"
          or CLOCK_WORD[src] or string.upper(src))
        ctx.pop_until = ctx.frame + math.floor(FPS * 0.9)
      else
        params:delta("clock_tempo", d)
      end
    elseif id == "@rec_src" then
      -- the take's source, one step at a time, past the focused track (a
      -- track never records itself)
      local k = clamp(math.floor(pget("rec_source", 1) + 0.5) + (d > 0 and 1 or -1), 1, #SRC_NAMES)
      if k == FOCUS + 1 then k = k + (d > 0 and 1 or -1) end
      if k >= 1 and k <= #SRC_NAMES then params:set("rec_source", k) end
    -- these address whichever track or send is selected, so they resolve to a
    -- param id at turn time rather than being fixed in ENC_MAP
    elseif id == "@route_amt" or id == "@trk_level" then
      -- delta the REAL param, but keep `id` as the compound target: the footer
      -- matches its flash against the slot's id, and the resolver turns it back
      -- into a value for display. (@win_move works for exactly this reason.)
      local real = ctx.enc_target(id)
      if id == "@trk_level" then ctx.level_step(real, d)
      else params:delta(real, fine_delta(real, d)) end
    elseif id == "@mo_sel" then
      -- one walk over the rows MOTION draws: no lane (0), the lanes, then
      -- the four modulators
      local n = #ctx.motion.lane_ids
      local f = math.floor(pget("mod_focus", 1) + 0.5)
      local cur = f > 1 and n + f - 1
        or clamp(math.floor(pget("motion_lane", 0) + 0.5), 0, n)
      local nxt = clamp(cur + d, 0, n + Mlfo.N)
      if nxt > n then
        params:set("mod_focus", nxt - n + 1)
      else
        params:set("mod_focus", 1)
        params:set("motion_lane", nxt)
      end
    elseif id and params.lookup[id] then
      params:delta(id, fine_delta(id, d))
      -- a modulator's target picked on MOTION: it moves the focused track's
      if LFO_TRACK[id] then params:set(LFO_TRACK[id], tsel()) end
    else
      id = nil
    end
    if id then
      -- mark the param actively-turning: its footer value swells for ~1.2s
      ctx.flash_id, ctx.flash_until = id, ctx.frame + math.floor(FPS * 1.2)
    end
  end
  redraw()
end

-- DOUBLE-TAP K1: motion record on and off from any page (the sixtieth
-- change). A tap is a K1 press and release with no key or encoder under it.
-- K1 alone did nothing before, so the gesture takes nothing from a page.
function ctx.motion_toggle()
  local on = pget("motion_rec", 0) ~= 1
  params:set("motion_rec", on and 1 or 0)
  ctx.pop_text = on and "MOTION REC" or "MOTION OFF"
  ctx.pop_until = ctx.frame + math.floor(FPS * 0.7)
end

function key(n, z)
  ctx.last_input = ctx.frame
  if n ~= 1 and z == 1 and ctx.alt then k1_used = true end
  if n == 1 then
    ctx.alt = (z == 1)
    if z == 1 then
      k1_down, k1_used = ctx.frame, false
    elseif k1_down and not k1_used and ctx.frame - k1_down < TAP_FRAMES then
      -- (not on TRACKS: K1 there shows the sends, and two quick looks
      -- are not a wish to record motion)
      if PAGES[ctx.page] == "TRACKS" then
        k1_last_tap = nil
      elseif k1_last_tap and ctx.frame - k1_last_tap <= K1_DOUBLE then
        k1_last_tap = nil
        ctx.motion_toggle()
      else
        k1_last_tap = ctx.frame
      end
    else
      k1_last_tap = nil
    end
    -- K1 down during a tap-or-hold key (TAKE K3) aborts it: K1+K3 is the
    -- eraser's gesture, and the hold must not land under another word
    if z == 1 then
      for k = 2, 3 do
        local st = key_state[k]
        if st.def and st.def.hold and not st.fired then
          st.fired, st.aborted = true, true
        end
      end
    end
    -- releasing K1 ABORTS a pending K1+K3 erase. the arc is gated on K1, so
    -- letting go reads as "abort" — honour that instead of firing anyway. (you
    -- can't navigate stations while K1 is held — K1+E1 is the morph — so the
    -- erase can also never retarget onto a different station's material.)
    if z == 0 and ctx.k13_frame and not ctx.k13_fired then
      -- mark it RESOLVED (not just clear the arc) so the still-held K3's release
      -- doesn't fall into the dry/erase tap branch and fire DRY after the abort.
      ctx.k13_frame, ctx.k13_fired = nil, true
    end
    redraw()
    return
  end
  local st = key_state[n]
  ctx.held[n] = (z == 1)
  if z == 1 then
    local def = key_def(n)
    st.def, st.frame, st.engaged, st.unlatched = def, ctx.frame, false, false
    st.fired, st.aborted, st.page = false, false, ctx.page
    if def then
      if def.hold then
        -- tap or hold: nothing fires on the press (tick_keys and the release)
      elseif def.dryerase then          -- K1+K3: DRY on tap, ERASE at the arc
        ctx.k13_frame, ctx.k13_fired = ctx.frame, false
        -- what the arc will erase is fixed NOW (SCENE: the slot under the
        -- finger, before a running orbit can re-aim the selector)
        ctx.k13_slot = math.floor(pget("scene_slot", 1) + 0.5)
      elseif def.pon then           -- punchable
        if def.lit and def.lit() then
          def.poff()                -- already latched: press = off
          -- and REMEMBER that this press cancelled. It leaves engaged false,
          -- same as a pon that declined — but the release must not then run
          -- def.tap() and undo the cancel.
          st.unlatched = true
        else
          def.pon()
          st.engaged = true
        end
      elseif def.act then           -- tap-cycle: fires on the press
        def.act()
      end
    end
  else
    local def = st.def
    st.def = nil
    if def then
      if def.hold then
        -- tap = the def's tap; between the tap and the arc = the abort zone
        if not st.fired and ctx.frame - st.frame < TAP_FRAMES then def.tap() end
        -- a hold that lasts as long as the key (SOLO) ends with it
        if st.fired and not st.aborted and def.release then def.release() end
        st.fired = false
      elseif def.dryerase then
        local dt = ctx.frame - (ctx.k13_frame or ctx.frame)
        -- tap = DRY; the frames between tap and arc = the abort zone
        if not ctx.k13_fired and dt < TAP_FRAMES then ctx.fx_dry() end
        ctx.k13_frame, ctx.k13_fired = nil, false
      elseif st.engaged then
        local dt = ctx.frame - st.frame
        if dt < TAP_FRAMES and def.tap then
          def.tap()               -- tap with its own meaning (RCL = commit)
        elseif def.poff and (def.gate or dt >= TAP_FRAMES) then
          def.poff()
        end
        -- else: a tap — it latches, still engaged with the finger off
      elseif def.tap and not st.unlatched
             and ctx.frame - st.frame < TAP_FRAMES then
        def.tap()                 -- tap on a def whose pon declined to engage
      end
    end
    -- belt-and-braces: the PADS audition voice must never strand
    if n == 2 and ctx.pad_held[8] then ctx.pad_trigger(8, 0, 0) end
  end
  redraw()
end

function redraw()
  Mpages.redraw()
end
