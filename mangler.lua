-- mangler — a live stereo sampler + mangler for norns
-- =====================================================
--
-- record external gear (synth, drum machine, anything line-level), then play
-- it back and mangle it. a fresh take loops back DRY — exactly what you
-- recorded. you ADD effects on top; they are never forced on.
--
--   IN -> REC -> [ DRONE  +  PADS ] -> FILTER -> DELAY -> REVERB -> OUT
--                  clean loop /        (filter open, drive/delay/reverb
--                  granular /           all start at zero — dial them in)
--                  stretch / spectral
--
-- the drone defaults to CLEAN PLAY — a straight loop of your take, exactly as
-- recorded. GRAIN / WARP / PV are mangling modes you switch on from VOICE.
--
-- PLAY IT (the redesign, doc/redesign.md)
--   TAKE    K2, play a phrase, K2 — the window snaps to your take and loops
--           it, dry. the ◇ by the title = "you hear the recording, verbatim"
--   VOICE   K3 cycles PLAY (clean) · GRAIN · WARP · PV; the texture IS the mode
--   DELAY   echoes: time · feedback (few → many → near-infinite) · mix
--   REVERB  the tail: decay · size · damp · mix — starts silent
--   PADS    the take chopped into 8 playable slices, each sound-locked
--   SCENE   capture whole sounds; HOLD K2 to peek, tap to keep; ◄ = way back
--
-- THE PUNCH LAW (every key, every page):
--   press = engage NOW · release quickly = it latches · held = a punch,
--   release disengages · already latched = any press turns it off.
--
-- CONTROLS   (3 keys + 3 encoders; every param is MIDI-mappable via PARAMS)
--   E1     select page (eleven stations, by family: TAKE VOICE · TAPE LAYERS
--          · FILTER DELAY REVERB · MIX · PADS MOTION SCENE; the page name
--          pops big while you scroll)
--   E2/E3  the page's two shaping knobs (hold K1: the alt pair). values show
--          only while turning; selector pages (SLICE/LANE/SLOT) read at rest
--   K1     shift (hold). the footer swaps whole while it's down
--   K2/K3  the page's two gestures, named in the footer, punch law above
--   K1+K2  STOP / START — GLOBAL, every page, no exceptions. tap = choke
--          (title inverts), tap again = the exact mix back, hold = mute stab
--          (also SPACE on a typing keyboard · grid row 2 · MIDI `stop all`)
--   K1+K3  DRY (tap): playback path thrown clean — delay/reverb/shimmer/
--          drive/clouds-fb zero, filter open. HELD ~1s = the ERASER: an arc
--          fills, and at the ring the page's material is wiped (take / tape
--          loop / lane / slot). GLOBAL, every page.
--   K1+E1  the MORPH, from anywhere: sweep toward the selected scene; back
--          to zero lands exactly home
--
-- SCENE   8 slots + the ◄ cell. K3 captures, K2 recalls (HOLD = peek: borrow
--   the scene, release comes home; tap = commit), E3 morphs from LIVE toward
--   the selected slot. every commit parks the previous sound in ◄
--   automatically — select ◄ and tap K2 to undo. `chaos throw` (PARAMS/grid):
--   hold for bounded mayhem, release to land back on ◄.
--
-- NOTES   a MIDI keyboard (or USB typing keyboard, ableton-style: A-row =
--   white keys, W-row = black, Z/X = octave) retunes the sample chromatically;
--   with pad input on they trigger the PADS slices instead. PARAMS > keys.
--
-- GRID (optional, never required)   a monome grid — or a launchpad-style
--   controller via the midigrid library — adds transport toggles, window/loop
--   slice pads, and two piano octaves. see lib/mgrid.lua.
--
-- BEST SOUND (optional, auto-detected)   JPverb (sc3-plugins) reverb + MiClouds
--   (mi-UGens) granular are used when installed, else stock FreeVerb / GrainBuf.
--   guarded at build time — a missing plugin can never hang loading.
--
-- -----------------------------------------------------------------------------
-- this file is the orchestrator: state + params + key/encoder handlers. the
-- rest lives in lib/ modules (script-internal, NOT norns engines): mfont (pixel
-- font), mtape (softcut tape), minput (midi/keyboard
-- notes), mgrid (grid surface), mpages (the screen). they share one `ctx` table
-- and params are the single source of truth. full design: doc/spec.md.

engine.name = "Mangler"

-- bring-up diagnostics: load milestones in maiden. If "script file executed"
-- appears without "init() called", the engine died in alloc — check the SC tab.
print("mangler: script file executed")

local mu = require "musicutil"

local min, max = math.min, math.max

-- ============================================================================
-- state (shared with the lib/ modules through ctx)
-- ============================================================================

-- eleven stations, ordered by FAMILY so neighbours belong together:
-- the take (TAKE VOICE) · the loop decks (TAPE LAYERS) · the tone
-- (FILTER DELAY REVERB) · the console (MIX) · the performance layer
-- (PADS MOTION SCENE). EROSION and ORBIT are no longer pages: erosion only
-- ever worked in PLAY mode, so its controls live on VOICE's PLAY face (the
-- alt pair, which was a redundant scan/pitch copy there); the orbit drives
-- the scene machinery, so its knobs live on SCENE's alt pair and its RUN
-- switch on the grid/PARAMS/MIDI. The params are UNCHANGED (ids are never
-- renamed), only their surfaces moved.
local PAGES = {
  "TAKE", "VOICE", "TAPE", "LAYERS", "FILTER", "DELAY", "REVERB",
  "MIX", "PADS", "MOTION", "SCENE",
}

local FPS = 15

local tape_arm_phase      -- head position when tape rec opened a pass; nil = none
local polls = {}
local redraw_clock

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
local function window_bounds()
  local a = pget("pos_start", 0)
  local b = pget("pos_end", 1)
  local lo, hi = min(a, b), max(a, b)
  return lo, hi, max(hi - lo, 0.001)
end

-- zoom-aware fine control: window/loop/layer edge params scale their encoder
-- deltas by the current span, so steps shrink as the region tightens —
-- a wide-open window moves fast, a tight loop nudges by milliseconds.
-- (combined with the 0.002 quantum on these specs: ~10ms at the finest.)
-- every value other than "win" is the param-id prefix of a loop pair.
local FINE_IDS = { pos_start = "win", pos_end = "win",
                   loop_start = "loop", loop_end = "loop",
                   lay1_start = "lay1", lay1_end = "lay1",
                   lay2_start = "lay2", lay2_end = "lay2" }

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
  window_bounds = window_bounds,
  PAGES = PAGES, FPS = FPS,
  -- ui state
  page = 1,
  alt = false,               -- K1 held
  last_input = 0,            -- frame of the last key/encoder touch (idle dim)
  idle_dim = false,
  held = {},                 -- held[n] = true while key n is down (page-independent)
  frame = 0,                 -- redraw frame counter (drives the REC blink)
  flash_id = nil,            -- transient top-right value readout
  flash_until = 0,
  -- engine/system signals
  play_phase = 0,            -- engine poll: normalized playhead in the buffer
  rec_phase = 0,             -- engine poll: normalized write-head position
  rec_arm_phase = 0,         -- write-head position when rec was armed
  rec_amp = 0,               -- engine poll: amplitude of what's being written
  amp_in = { 0, 0 },         -- system polls: live input amplitude L/R
  amp_out = { 0, 0 },        -- system polls: output amplitude L/R
  tape_phase = 0,            -- softcut phase event: tape head, normalized
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
local Mscenes = include "lib/mscenes"
local Mpages = include "lib/mpages"

ctx.font = Mfont
ctx.grid = Mgrid
ctx.motion = Mmotion
-- the tape display model lives in mpages; mtape clears it when a pset restores
-- an empty tape, so it needs a way to reach it
ctx.clear_twave = Mpages.clear_twave
-- ...and repaints it from the PSET wav on restore (plus the layer decks'
-- strips, which own their bins and hand them in)
ctx.repaint_twave = Mpages.repaint_twave
ctx.wave_from_file = Mpages.fill_wave_bins
ctx.wav_info = Mpages.wav_info

-- THE TIMEBASE. These two numbers place everything in the instrument: every
-- window edge, pad slice, waveform bin and PSET bound is a fraction of them.
-- Both are set by the ENGINE (lib/Engine_Mangler.sc allocates
-- `s.sampleRate * bufSecs`, and norns runs its server at 48k) and lua cannot
-- read either off the server — so they are mirrored ONCE here and shared
-- through ctx. They used to be bare literals in several modules plus the .sc:
-- miss one when the buffer length changes and PSET saves silently truncate the
-- take, or every waveform, window bracket and pad slice draws against the
-- wrong clock with no error anywhere.
ctx.BUF_SECS = 60        -- must match `bufSecs` in lib/Engine_Mangler.sc
-- How many bytes per sample `write_take` puts on disk. MUST match the format
-- in that command (`int24`, so 3). The export works out how big the file
-- should be from this and waits for it to get there, so a number that is too
-- small calls the file finished while a third of it is still being written.
ctx.TAKE_BYTES = 3       -- must match write_take's format in Engine_Mangler.sc
ctx.SERVER_SR = 48000    -- norns' scsynth sample rate
local BUF_SECS, SERVER_SR = ctx.BUF_SECS, ctx.SERVER_SR

-- THE tempo read. Guarded (the offscreen sim has no clock) and defaulted once,
-- so every caller agrees about what "the tempo" is.
function ctx.tempo()
  if clock and clock.get_tempo then
    local ok, t = pcall(clock.get_tempo)
    if ok and t and t > 0 then return t end
  end
  return 120
end

-- the EFFECTIVE softcut record source. cut_source is the knob; the layer
-- BOUNCE overrides it: while `layer_wet` is on and any layer is armed, the
-- decks record the processed engine output (WET), so "resample into a layer"
-- is just arming one — no trip to the TAPE page first. the send is global,
-- so the tape records the same thing while a bounce runs; both pages' SRC
-- flags read THIS, never the raw knob, so the override is never hidden.
function ctx.eff_cut_source()
  if pget("layer_wet", 1) == 1 then
    for _, d in ipairs(ctx.layers or {}) do
      if pget(d.id .. "_rec", 0) == 1 then return 1 end
    end
  end
  return pget("cut_source", 0)
end

-- ONE writer for the softcut input sends: everything that can change the
-- effective source (the knob, a layer arming/disarming, the layer_wet toggle)
-- funnels through here, so the routing can never disagree with the flags.
function ctx.update_cut_source()
  Mtape.set_source(ctx.eff_cut_source())
end

-- what the softcut decks RECORD right now, for the meters: the ADC tap, the
-- engine output (WET), or the blend. one law for the tape picture (mpages)
-- and the layer decks' pictures (mdeck).
function ctx.cut_rec_amp()
  local cs = ctx.eff_cut_source()
  return max(ctx.amp_in[1], ctx.amp_in[2]) * (1 - cs)
    + max(ctx.amp_out[1], ctx.amp_out[2]) * cs
end

Mtape.init(ctx, Mdeck)   -- the tape borrows the deck mechanics (see mtape)
-- THE deck gain law (eng, tape, master) lives in mtape; the MIX page draws
-- the same numbers update_mix sends, so it reads them from here
ctx.mix_gains = Mtape.gains
ctx.paint_bins = Mpages.paint_bins    -- decks paint their own pictures
ctx.loop_secs = Mdeck.loop_secs       -- ...and the page prints the same law
Mdeck.init(ctx)
-- TWO more loop decks beside the tape, on softcut voices the script does not
-- otherwise use. Their buffer regions start at 120s, leaving 60-120 clear:
-- the chain forge on `foundry` auditions cells at 70s, and picking around it
-- means the branches can merge without a silent buffer collision.
ctx.layers = {
  Mdeck.new({ id = "lay1", name = "L1", va = 3, vb = 4, from = 120, len = 60 }),
  Mdeck.new({ id = "lay2", name = "L2", va = 5, vb = 6, from = 180, len = 60 }),
}
ctx.deck_phase = function(v, pos) Mdeck.on_phase(v, pos) end
-- which layer the page and its encoders address
function ctx.layer_sel()
  return ctx.layers[math.floor(pget("layer_sel", 1) + 0.5)] or ctx.layers[1]
end
-- re-send every deck's level: the master, the transport and the global STOP
-- all fold into it, so anything that moves one of those has to come through here
-- a compound encoder target ("@...") resolves to a REAL param id: the one the
-- footer should print and the dial should point at. Pair-movers report their
-- anchor, the low edge. ONE resolver, because the encoder, the footer value and
-- the footer dial each need the same answer and two of them used to not have it
-- (the layer targets read "--" and drew no pointer).
function ctx.enc_target(id)
  if id == "@win_move" then return "pos_start" end
  if id == "@lay_move" then return Mdeck.p(ctx.layer_sel(), "start") end
  if id == "@lay_level" then return Mdeck.p(ctx.layer_sel(), "level") end
  if id == "@lay_rate" then return Mdeck.p(ctx.layer_sel(), "rate") end
  return id
end

function ctx.layers_relevel()
  for _, d in ipairs(ctx.layers) do Mdeck.update_level(d) end
end

-- ---------------------------------------------------------------------------
-- SNAP: put a layer's loop LENGTH on the grid
-- ---------------------------------------------------------------------------
-- Recording a layer gives you exactly the length you played, which is never
-- exactly the length you meant. Two loops of 3.97 and 4.02 seconds drift out
-- of time with each other within a minute. Two that are an exact double, half
-- or three-to-two of each other stay together indefinitely. SNAP is what gets
-- you from the first to the second.
--
-- It rounds the length to match whatever you are most likely playing along
-- with, looking in this order: the other deck if it has anything on it, then
-- the take, then a bar at the current tempo. It only ever moves the END of
-- the loop, because where a loop starts was decided by when you hit record
-- and that is not this code's business to second-guess. It also means you can
-- always undo it by hand.
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

-- This always hands back a real length. A deck whose loop has been squashed
-- down to nothing still reads as a tenth of a second, so it is skipped here
-- instead of being passed on for SNAP to reject; the take is checked the same
-- way; and four beats is 0.8 seconds even at the fastest tempo the clock
-- allows. Because of that, layer_snap needs no "there is no reference" case.
-- A key that fires, changes nothing and says nothing is the one thing this
-- page must never do.
local function snap_reference(d)
  for _, o in ipairs(ctx.layers) do
    -- ...and not one that is still being recorded. While a deck records its
    -- first pass its loop is held open at the full 60 seconds, and it counts
    -- as "has audio" the moment it hears anything, so it would offer 60
    -- seconds as the length to match. Record both layers at once and stop one
    -- of them: without this, it snapped to an eighth of 60 seconds, which is
    -- a number off the buffer and nothing to do with the music.
    if o ~= d and o.any and not o.arm_phase and Mdeck.loop_secs(o) > 0.1 then
      return Mdeck.loop_secs(o), o.name
    end
  end
  local _, _, span = window_bounds()
  if ctx.wave_any and span * BUF_SECS > 0.1 then
    return span * BUF_SECS, "TAKE"
  end
  return 240 / ctx.tempo(), "BAR"            -- four beats of the clock
end

-- One short line on the LAYERS page, and the full story printed to the log.
-- A snap that lands on the length you already had changes nothing you can
-- see, and a page that cannot say so looks exactly like a dead key. The
-- screen gets the short form because a line has to fit in 124 pixels.
--
-- The scene page has its own version of this (mscenes' `say`). Both hold the
-- same two things, the text and the frame it was set on, so merging them into
-- one shared helper later is straightforward. Their LOOK stays separate on
-- purpose: the scene page draws a small inverted box, which suits "SAVED 2"
-- but would be a 111-pixel slab for a sentence like the ones here.
local function layer_say(msg, detail)
  ctx.lay_msg, ctx.lay_msg_at = msg, ctx.frame or 0
  print("mangler: " .. (detail or msg))
end

-- tol = nil forces the snap; tol = a log-ratio only takes it when the length
-- was already that close (the automatic pass at the end of a record).
function ctx.layer_snap(d, tol)
  d = d or ctx.layer_sel()
  local ref, from = snap_reference(d)
  local cur = Mdeck.loop_secs(d)
  local best, label, err = 1, "1", math.huge
  for _, r in ipairs(SNAP_RATIOS) do
    -- compare in LOG space so 1/2 and 2 are equally near, the way an ear
    -- hears them: a linear nearest would pull everything toward the top
    local e = math.abs(math.log(cur / (ref * r[1])))
    if e < err then err, best, label = e, r[1], r[2] end
  end
  if tol and err > tol then return end
  -- Measure from the LOWER of the two edges, not from "start". The loop
  -- points can legally be the other way round, and everything else that reads
  -- them sorts them first. Trusting "start" on a back-to-front loop moved it
  -- to a completely different stretch of the deck, while the message on
  -- screen said nothing had changed.
  local lo = math.min(clamp(pget(Mdeck.p(d, "start"), 0), 0, 1),
    clamp(pget(Mdeck.p(d, "end"), 1), 0, 1))
  local want = ref * best
  local len, room = want, (1 - lo) * d.len
  -- keep it inside the region by halving, because half of a musical length is
  -- still one. If not even that fits, REFUSE: manufacturing a 100ms loop and
  -- labelling it a ratio is worse than saying no, and it puts a grid in the
  -- message that the loop is not on.
  while len > room and len / 2 >= 0.1 do len = len / 2 end
  if len > room then
    layer_say(d.name .. " NO ROOM TO SNAP",
      string.format("%s SNAP refused: %.2fs left in the region, and the nearest"
        .. " %s x %s is %.2fs. Move the loop start back first.",
        d.name, room, label, from, want))
    return
  end
  Mdeck.set_loop(d, lo, clamp(lo + len / d.len, 0, 1))
  -- report what LANDED, not what was asked for. The region clamp and softcut's
  -- own 100ms floor can both move it, and this message is the only proof the
  -- key did anything, so it is the last thing that may guess.
  local got = Mdeck.loop_secs(d)
  local on = math.abs(got - want) < 0.005 and (label .. " x " .. from)
    or ("FIT " .. from)
  if math.abs(got - cur) < 0.005 then
    -- The loop did not move, so the playhead must not either. Sending it back
    -- to the start would restart the phrase mid-performance under a message
    -- saying nothing changed, and two decks only keep their timing against
    -- each other while both heads keep running. It is why MUTE lowers a
    -- deck's volume instead of stopping it.
    layer_say(string.format("%s ON GRID %s", d.name, on),
      string.format("%s SNAP: already %s (%.3fs)", d.name, on, cur))
  else
    Mdeck.jump(d, lo)
    layer_say(string.format("%s %.2f>%.2fS %s", d.name, cur, got, on),
      string.format("%s SNAP: %.3fs -> %.3fs (%s; %s = %.3fs)",
        d.name, cur, got, on, from, ref))
  end
end

-- the automatic pass, called by the loop-pedal close in lib/mdeck.lua
function ctx.layer_quantize(d) ctx.layer_snap(d, SNAP_TOL) end
Minput.init(ctx)
Mgrid.init(ctx)
Mmotion.init(ctx)
-- sets ctx.scene (the module), ctx.scenes (the 8-slot bank) and the
-- ctx.scene_capture/_clear helpers the grid's CAP/CLR modifiers call
Mscenes.init(ctx)
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
local function throw(label, ids, apply)
  return {
    label = label,
    lit = function() return throw_mem[label] ~= nil end,
    pon = function()
      for other, mem in pairs(throw_mem) do
        if other ~= label then
          for k = 1, #ids do
            if mem[ids[k]] ~= nil then throw_restore(other); break end
          end
        end
      end
      local mem = {}
      for k = 1, #ids do mem[ids[k]] = params:get(ids[k]) end
      throw_mem[label] = mem
      apply()
    end,
    poff = function() throw_restore(label) end,
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
      else
        print("mangler: SNAP — the window is already the whole buffer")
      end
    end
  else
    snap_mem = { lo, hi }
    params:set("pos_start", 0)
    params:set("pos_end", 1)
  end
end

-- page key defs (+ each page's `erase`: what the K1+K3 arc wipes)
local KEYS = {
  TAKE = {
    k2 = pk("REC", "rec"),
    k3 = { label = "SNAP", act = snap_window },
    erase = function() pulse("clear_rec") end,   -- audio: NOT undoable
  },
  VOICE = {
    k2 = pk("FRZ", "pv_freeze"),
    -- MODE cycles PLAY->GRAIN->WARP->PV, skipping OFF (a silence pothole
    -- mid-set; stopping is STOP's job — OFF stays reachable in PARAMS)
    k3 = { label = "MODE",
      act = function()
        local m = pget("mode", 5)
        params:set("mode", m >= 5 and 2 or (m < 2 and 5 or m + 1))
      end },
  },
  TAPE = {
    k2 = pk("REC", "tape_rec"),
    k3 = pk("REV", "tape_reverse"),
    erase = function()
      -- disarm first, like the LAYERS erase: wiping while armed just
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
    k3 = { label = "TYPE",
      act = function()
        params:set("filt_type", (pget("filt_type", 1) % 3) + 1)
      end },
  },
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
    erase = function() ctx.motion.clear_lane() end,
  },
  LAYERS = {
    -- REC under the punch law: hold to record while you lean on it, tap to
    -- latch. PLAY is a plain transport toggle. K1+K3 erases THIS layer only —
    -- the tape and the other layer are untouched (mdeck clears by region).
    k2 = { label = "REC",
      lit = function() return pget(Mdeck.p(ctx.layer_sel(), "rec"), 0) == 1 end,
      pon = function() params:set(Mdeck.p(ctx.layer_sel(), "rec"), 1) end,
      poff = function() params:set(Mdeck.p(ctx.layer_sel(), "rec"), 0) end },
    -- MUTE rather than a transport stop: the head keeps rolling so the decks
    -- hold their drift against each other (see lib/mdeck.lua). Lit = audible.
    k3 = { label = "MUTE",
      lit = function() return pget(Mdeck.p(ctx.layer_sel(), "play"), 1) == 0 end,
      pon = function() params:set(Mdeck.p(ctx.layer_sel(), "play"), 0) end,
      poff = function() params:set(Mdeck.p(ctx.layer_sel(), "play"), 1) end },
    erase = function()
      local d = ctx.layer_sel()
      -- Cancel any recording in progress BEFORE stopping it. Otherwise the
      -- deck sets a loop around audio we are one line away from erasing, and
      -- announces it on screen.
      Mdeck.abort_loop(d)
      params:set(Mdeck.p(d, "rec"), 0)
      Mdeck.clear(d)
      params:set(Mdeck.p(d, "start"), 0)
      params:set(Mdeck.p(d, "end"), 1)
      -- forget the loaded file too, like clear_recording forgets sample_file:
      -- a PSET saved after this erase must not resurrect the very file you
      -- wiped ("" is a no-op through layer_load's own guard)
      local fid = Mdeck.p(d, "file")
      if params.lookup[fid] and params:get(fid) ~= "" then
        params:set(fid, "")
      end
    end,
  },
  SCENE = {
    -- RCL under the punch law — hold = PEEK (borrow the scene via the
    -- morph engine; release sweeps you home), tap = COMMIT. on the ◄ cell
    -- (slot 0) a tap is the way back (safe restore). CAP captures into the
    -- selected slot — into ◄ it marks the way-back state by hand.
    k2 = { label = "RCL",
      lit = function() return ctx.peek_on == true end,
      pon = function()
        local sel = math.floor(pget("scene_slot", 1) + 0.5)
        if sel >= 1 and ctx.scenes[sel] then
          ctx.peek_on, ctx.peek_back = true, false
        end
      end,
      tap = function()
        local sel = math.floor(pget("scene_slot", 1) + 0.5)
        ctx.peek_on = false
        pulse("scene_recall")
        -- the scene landed: it IS the new LIVE, so the rail goes home without
        -- sweeping (recall invalidated the morph's "from"). NOT when the
        -- recall only QUEUED (BEAT/BAR): zeroing amt then would force-apply
        -- the old A and audibly bounce scene->LIVE->scene around the sync.
        if sel >= 1 and not ctx.scene.pending then
          params:set("scene_morph_amt", 0)
        end
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
    erase = function() pulse("scene_clear") end,
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
  TAKE   = { "pos_start", "@win_move", "pos_end", "pos_jitter" },
  VOICE  = { "scan", "scan", "pitch", "pitch" }, -- face is mode-contextual
  TAPE   = { "tape_rate", "tape_pre", "loop_end", "cut_source" },
  FILTER = { "cutoff", "drive", "resonance", "dry_wet" },
  DELAY  = { "delay_mix", "delay_time", "delay_fb", "delay_sync" },
  REVERB = { "rev_mix", "rev_size", "rev_decay", "rev_damp" },
  MIX    = { "mix", "input_level", "out_level", "monitor_level" },
  PADS   = { "seq_slice", "pad_voice", "pad_pitch", "voice_rel" },
  MOTION = { "motion_lane", "motion_len", "motion_depth", nil },
  -- the alt pair is the ORBIT: drift time + how far each leg reaches. the
  -- recall quantize (scene_recall_mode) moved to PARAMS — a set-and-forget
  -- config knob lost its encoder to a performance one.
  SCENE  = { "scene_slot", "orbit_rate", "scene_morph_amt", "orbit_reach" },
  LAYERS = { "layer_sel", "@lay_rate", "@lay_level", "@lay_move" },
}

-- VOICE face pair per engine mode (the S-4 move: the encoders always
-- control what you're hearing). mode options: OFF GRAIN WARP PV PLAY.
local VOICE_FACE = {
  { "scan", "pitch" },            -- OFF (the universal pair still)
  { "size", "density" },          -- GRAIN
  { "warp_window", "warp_rand" }, -- WARP
  { "scan", "pitch" },            -- PV
  { "scan", "pitch" },            -- PLAY
}

-- the param id addressed by encoder n (2 or 3), page + alt + mode aware
local function enc_param(n)
  local page = PAGES[ctx.page]
  if page == "VOICE" and not ctx.alt then
    local f = VOICE_FACE[clamp(pget("mode", 5), 1, 5)]
    return n == 2 and f[1] or f[2]
  end
  -- VOICE's alt pair is mode-contextual too: in PLAY mode the face already IS
  -- scan/pitch, so the alt copy was redundant there — it now carries the
  -- EROSION controls, which only ever work in PLAY mode (the engine erodes in
  -- \mangler_play alone). every other mode keeps alt scan/pitch, so pitch
  -- stays reachable under a GRAIN or WARP face.
  if page == "VOICE" and ctx.alt and pget("mode", 5) == 5 then
    return n == 2 and "erode" or "wear"
  end
  local m = ENC_MAP[page]
  if not m then return nil end
  -- explicit, NOT `alt and m[2] or m[1]`: a nil alt slot (MOTION/SCENE) must be
  -- a genuine no-op, not fall through to the base param and edit it while K1 is
  -- held (which could wipe the wrong MOTION lane and leak a value in the footer)
  if n == 2 then
    if ctx.alt then return m[2] end
    return m[1]
  elseif n == 3 then
    if ctx.alt then return m[4] end
    return m[3]
  end
  return nil
end

-- compound encoder gesture: slide a lo/hi pair together, width preserved,
-- with the same span-scaled fine step the edges get.
-- The two writes go in the OUTWARD-EDGE-FIRST order the scenes use for the
-- same pairs: sliding right by more than the current width would otherwise
-- put the low edge past the high one for a single param write, and a crossed
-- pair is a region that is neither the old one nor the new one.
local function move_pair(lo_id, hi_id, d)
  local lo, hi = pget(lo_id, 0), pget(hi_id, 1)
  if hi < lo then lo, hi = hi, lo end
  local p = params:lookup_param(lo_id)
  local q = (p and p.controlspec and p.controlspec.quantum) or 0.01
  local width = hi - lo
  local nlo = clamp(lo + fine_delta(lo_id, d) * q, 0, 1 - width)
  if nlo < lo then                     -- moving LEFT: the low edge widens first
    params:set(lo_id, nlo)
    params:set(hi_id, nlo + width)
  else                                 -- moving RIGHT: the high edge widens
    params:set(hi_id, nlo + width)
    params:set(lo_id, nlo)
  end
end

-- K1+K3 held to the arc: the erase fires AT the threshold (not on the
-- release), from the redraw clock, so the arc is a promise that lands.
-- the same tick animates the scene PEEK ramp: holding RCL drives the morph
-- amount toward the slot (~4 frames in), releasing sweeps it home — all
-- through the scene_morph_amt param, so motion capture and MIDI stay true.
local function tick_keys()
  if ctx.k13_frame and not ctx.k13_fired
      and ctx.frame - ctx.k13_frame >= ERASE_FRAMES then
    local e = page_erase()
    if e then e() end
    ctx.k13_fired = true
  end
  if ctx.peek_on then
    local a = pget("scene_morph_amt", 0)
    if a < 1 then params:set("scene_morph_amt", clamp(a + 0.34, 0, 1)) end
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
function ctx.pads_uncut() ctx.pad_cuts = nil end

-- TIGHTEN: pull the window in onto the sound. Pressing REC and then playing
-- leaves your reaction time at the head of the take, and letting go late
-- leaves room tone at the tail — the rec-stop window snaps to where the record
-- HEADS were, which is not where the sound is.
-- NON-DESTRUCTIVE on purpose: this only moves pos_start/pos_end. It never
-- rewrites the buffer, so it is always undoable by moving the edges back (and
-- TAKE K3 SNAP remembers where you were).
function ctx.take_tighten()
  if not ctx.wave_any then
    print("mangler: TIGHTEN — nothing recorded yet")
    return
  end
  local tmp = norns.state.data .. "mtight-tmp.wav"
  ctx.take_to_wav(tmp, function(ok)
    if not ok then
      print("mangler: TIGHTEN — the take dump did not land")
      return
    end
    local lo, hi = window_bounds()
    local a, b = Mpages.onset_bounds(tmp, lo, hi, BUF_SECS, nil, ctx.task_yield)
    os.remove(tmp)
    if not a then
      print("mangler: TIGHTEN — the window is silent, left alone")
      return
    end
    -- a hair of room either side so a soft attack is never clipped off
    local pad = 0.005 / BUF_SECS
    a = clamp(a - pad, lo, hi)
    b = clamp(b + pad, lo, hi)
    if b - a < 0.002 then
      print("mangler: TIGHTEN — too little sound to window, left alone")
      return
    end
    -- both edges move INWARD, so the pair can never cross; still, set the one
    -- that moves first and re-read, the way every other edge pair here does
    params:set("pos_start", a)
    params:set("pos_end", b)
    print(string.format("mangler: TIGHTEN — window is %.2fs of sound (was %.2fs)",
      (b - a) * BUF_SECS, (hi - lo) * BUF_SECS))
  end)
end

-- CHOP: put the pads on the material's own attacks instead of eight arbitrary
-- eighths. Lua cannot read the engine buffer, so the take is dumped to a file
-- and the transients are found in that (Mpages.transient_cuts). The engine
-- already takes a position AND a length per note, so nothing here needs a new
-- command — the slices just stop being uniform.
function ctx.pad_chop()
  if not ctx.wave_any then
    print("mangler: CHOP — nothing recorded yet")
    return
  end
  local tmp = norns.state.data .. "mchop-tmp.wav"
  ctx.take_to_wav(tmp, function(ok)
    if not ok then
      print("mangler: CHOP — the take dump did not land")
      return
    end
    -- this callback runs inside the dump's own coroutine, so the scan can yield
    local lo, hi = window_bounds()
    local cuts = Mpages.transient_cuts(tmp, lo, hi, ctx.pad_n, BUF_SECS,
      ctx.task_yield)
    os.remove(tmp)
    if not cuts or #cuts < 2 then
      ctx.pads_uncut()
      print("mangler: CHOP found no transients — pads back to even slices")
      return
    end
    cuts[#cuts + 1] = hi            -- the last slice runs to the window end
    ctx.pad_cuts = cuts
    print(string.format("mangler: CHOP — %d slices, on the attacks", #cuts - 1))
  end)
end

-- spawn/release a voice for pad `i` under a stable `id` (so note_off matches
-- the note_on that started it). z=1 press, z=0 release.
function ctx.pad_trigger(id, i, z)
  ctx.last_input = ctx.frame   -- playing pads counts as presence (idle dim)
  if z == 1 then
    if ctx.pad_held[id] and engine.note_off then engine.note_off(id) end
    if engine.note_on then
      -- per-pad SOUND-LOCK: this pad's own pitch (semitones -> rate) + voice, at
      -- the pad voice level (chord-safe default that won't slam the limiter)
      local pt = ctx.pad_type[i] or 0
      engine.note_on(id, pad_pos(i, pt > 0),
        2 ^ ((ctx.pad_pitch[i] or 0) / 12),
        pt, pget("pad_level", 0.3), pad_len(i))
    end
    if ctx.pad_held[id] == nil then
      ctx.pad_order[#ctx.pad_order + 1] = id
    end
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
    for k = 1, #ctx.pad_order do
      if ctx.pad_order[k] == id then table.remove(ctx.pad_order, k); break end
    end
  end
end

-- MIDI/grid note routing: in pad mode a note plays pad (note mod 8) as a
-- polyphonic voice (note_off on release); otherwise it retunes the mono
-- drone `pitch` exactly as before. `pitch` is the chromatic rate the caller
-- already computed for the drone path.
function ctx.route_note(id, pitch, pad_idx, z)
  ctx.last_input = ctx.frame   -- MIDI/grid/typing notes count as presence
  if pget("pad_input", 0) == 1 then
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

-- wipe it. the engine zeroes the buffer; we clear the PICTURE with it and open
-- the window back up, so every page goes back to inviting a take instead of
-- drawing one that isn't there.
function ctx.clear_recording()
  if engine.clear then
    engine.clear()
  else
    print("mangler: engine has no `clear` — SYSTEM > RESTART for the new engine")
    return
  end
  -- a clear must be SILENCE (S23 B2): regen would immediately re-record the
  -- OUTPUT — input monitor, ringing tails — into the freshly erased buffer,
  -- resurrecting what you just wiped. the engine's `clear` flushes the
  -- delay/reverb tails on its side; this stops the write head at the params.
  if pget("regen", 0) > 0 then params:set("regen", 0) end
  Mpages.clear_wave()
  Mpages.erosion_reset()   -- a fresh take starts at generation zero
  ctx.snap_forget()        -- the old window bounds point at audio that is gone
  ctx.pads_uncut()         -- ...and so do the chopped slice boundaries
  ctx.take_len = 0       -- empty: a subsequent save writes nothing (and deletes)
  -- forget the loaded sample too. The take half already refuses to resurrect
  -- audio you cleared (take_pset_write deletes the pair), but a take that came
  -- from `load sample` lives in this path, and a PSET saved after a CLR would
  -- restore it on load — putting back the very sample you erased. "" is a
  -- no-op through load_sample's own guard.
  if params:get("sample_file") ~= "" then params:set("sample_file", "") end
  params:set("pos_start", 0)
  params:set("pos_end", 1)
  print("mangler: recording cleared")
end

-- load any wav as the sample (PARAMS > rec > load sample). it lands in the SAME
-- buffer a take does, so the window, drone and pads all work on it
-- identically — there is no "loaded sample" mode, it's just the sample.
-- the window snaps to the file's length, and the display is read from the FILE
-- (lua can't see the SC buffer — see Mpages.load_wave).
-- scsynth's buffer read does no sample-rate conversion, so a file at any rate
-- other than SERVER_SR plays varispeeded: a 44.1k wav is 8.8% fast, over a
-- semitone sharp. Anything not at rate goes through the resampler first.
local srconv_path

-- put a file in the take buffer and make every page agree about it. The tail
-- half of load_sample, split out so the sample-rate conversion can reach it
-- with a different path than the one the performer picked.
local function read_into_buffer(path, shown, secs)
  engine.read_file(path)
  ctx.wave_any = true    -- audio is in the buffer now, drawable or not — never
                         -- lie "EMPTY" over an audible sample, even for formats
                         -- the preview can't draw
  Mpages.erosion_reset()   -- different audio, generation zero: the age counter
                           -- belongs to the material, not to the session
  ctx.snap_forget()        -- ...and the remembered window belonged to the old
  ctx.pads_uncut()         -- ...as did the chop
  local dur = Mpages.load_wave(path, BUF_SECS) or secs
  -- the loaded length bounds a PSET save; unknown length (no preview) -> full
  ctx.take_len = dur and clamp(dur / BUF_SECS, 0.002, 1) or 1
  if dur then
    params:set("pos_start", 0)
    params:set("pos_end", clamp(dur / BUF_SECS, 0.002, 1))
    print(string.format("mangler: loaded %s (%.1fs) — window snapped to it",
      shown or path, dur))
  else
    -- audible, but no picture for this format (8-bit / aiff / float-extensible):
    -- leave the window for the performer to set rather than draw a lie
    print("mangler: loaded " .. (shown or path)
      .. " (playing; no waveform preview for this format)")
  end
end

-- load any wav as the sample (PARAMS > rec > load sample). A file that is not
-- at the server rate is RESAMPLED first (in the background, screen live) —
-- otherwise it plays sharp and every slice, pad and window inherits the error.
-- If the conversion cannot run or cannot decode the file, we load it straight
-- anyway: audible-but-sharp beats silence, and the log says which happened.
function ctx.load_sample(path)
  if path == nil or path == "" or path == "-" or path == _path.audio then return end
  if not util.file_exists(path) then
    print("mangler: no such file — " .. tostring(path))
    return
  end
  if not engine.read_file then
    print("mangler: engine has no `read_file` — SYSTEM > RESTART for the new engine")
    return
  end
  local okp, in_sr = pcall(Mpages.wav_rate, path)
  if not (okp and in_sr and in_sr ~= SERVER_SR) then
    read_into_buffer(path)         -- already at rate, or a format we can't probe
    return
  end
  srconv_path = srconv_path or (norns.state.data .. "mangler-srconv.wav")
  print(string.format("mangler: %d Hz sample — resampling to %d before load"
    .. " (it would play %+.1f%% otherwise)",
    in_sr, SERVER_SR, (in_sr / SERVER_SR - 1) * 100))
  local started = ctx.run_task(function(yield)
    -- capped at what the buffer can hold: converting past BUF_SECS is pure
    -- waste, and a corrupt rate header must never expand into gigabytes
    local ok, err = Mpages.convert_sr(path, srconv_path, SERVER_SR, yield,
      BUF_SECS + 1)
    if not ok then error(err or "conversion failed", 0) end
  end, function(ok, err)
    if ok then
      read_into_buffer(srconv_path, path)
    else
      print("mangler: resample failed (" .. tostring(err)
        .. ") — loading at the original rate, it will play sharp")
      read_into_buffer(path)
    end
  end)
  if not started then
    print("mangler: busy — loading at the original rate, it will play sharp")
    read_into_buffer(path)
  end
end

-- load a wav into a LAYER deck (PARAMS > layers > L1/L2 load file, the answer
-- to "how do I get material into a layer without playing it in live"). Same
-- rate rule as the take: softcut's buffer read does no sample-rate conversion,
-- so an off-rate file goes through the resampler first; if that cannot run,
-- load as-is and say so (audible-but-sharp beats silence). Each deck gets its
-- own conversion temp so a take load and a layer load can never race over one
-- file the server is still reading.
function ctx.layer_load(d, path)
  if path == nil or path == "" or path == "-" or path == _path.audio then return end
  if not util.file_exists(path) then
    print("mangler: no such file — " .. tostring(path))
    return
  end
  local okp, in_sr = pcall(Mpages.wav_rate, path)
  if not (okp and in_sr and in_sr ~= SERVER_SR) then
    Mdeck.load_file(d, path)
    return
  end
  local conv = norns.state.data .. d.id .. "-srconv.wav"
  print(string.format("mangler: %d Hz sample — resampling to %d before the %s load",
    in_sr, SERVER_SR, d.name))
  local started = ctx.run_task(function(yield)
    local ok, err = Mpages.convert_sr(path, conv, SERVER_SR, yield, d.len + 1)
    if not ok then error(err or "conversion failed", 0) end
  end, function(ok, err)
    if ok then
      Mdeck.load_file(d, conv, path)
    else
      print("mangler: resample failed (" .. tostring(err)
        .. ") — loading at the original rate, it will play sharp")
      Mdeck.load_file(d, path)
    end
  end)
  if not started then
    print("mangler: busy — loading at the original rate, it will play sharp")
    Mdeck.load_file(d, path)
  end
end

-- the live take rides the PSET as a private L/R pair beside the
-- pset file (take-N_L.wav / _R.wav), the same way mtape persists the tape
-- audio and mscenes the scene bank — the shared action_write/read/delete hook
-- calls each. the engine holds the buffer; lua only knows whether it has
-- CONTENT (ctx.wave_any — the has-a-take signal that also draws
-- "EMPTY - K2 REC"), so the write is gated on it: an empty take never leaves a
-- multi-MB silence file behind, and a fresh pset never resurrects one.
local function take_stem(number)
  return norns.state.data .. "take-" .. number
end

-- how many frames of the buffer a write should cover: the take_len high-water
-- mark (from frame 0), +50ms margin so rounding at the take boundary never clips
-- the tail, capped at the 60s buffer; take_len 0 (empty) -> the full buffer.
local function take_frames()
  local total = SERVER_SR * BUF_SECS
  local tl = ctx.take_len or 1
  return (tl > 0) and math.min(total, math.ceil(tl * total) + 2400) or total
end

function ctx.take_pset_write(number)
  if not engine.write_take then return end   -- old engine: no-op (like read_file)
  if not ctx.wave_any then
    -- nothing recorded: DELETE any take saved into this slot before, so a
    -- session the performer cleared and re-saved as empty can't resurrect the
    -- old audio on load (norns overwrite-save never calls action_delete).
    ctx.take_pset_delete(number)
    return
  end
  -- bound the write to the TAKE, not the full 60s buffer of mostly silence.
  engine.write_take(take_stem(number), take_frames())
end

function ctx.take_pset_read(number)
  if not engine.read_take then return end
  local stem = take_stem(number)
  -- no take file (a pset from before S22, or one saved with an empty buffer):
  -- leave the buffer alone, exactly like mtape when there's no wav — the
  -- pset's own params (window included) still load. BOTH halves must exist:
  -- /b_write is async, so an interrupted save can leave _L without _R, and
  -- reading that would zero both buffers then restore a left-only take.
  if not (util.file_exists(stem .. "_L.wav")
      and util.file_exists(stem .. "_R.wav")) then return end
  engine.read_take(stem)
  -- repaint from the file or the restored take is INVISIBLE (audio you can hear
  -- over "EMPTY - K2 REC"). do NOT snap the window — params:read already
  -- restored the saved pos_start/pos_end.
  local dur = Mpages.load_wave(stem .. "_L.wav", BUF_SECS)
  Mpages.erosion_reset()  -- the restored take carries its own age in the audio;
                          -- the counter is per-material, not per-session
  ctx.snap_forget()       -- the buffer was replaced: the remembered window
                          -- pointed at the previous session's material
  ctx.pads_uncut()        -- padlock_pset_read restores the pset's own cuts next
  ctx.wave_any = true   -- audio is in the buffer whether or not we could draw it
  ctx.take_len = dur and clamp(dur / BUF_SECS, 0.002, 1) or 1  -- bounds a re-save
end

function ctx.take_pset_delete(number)
  local stem = take_stem(number)
  os.remove(stem .. "_L.wav")
  os.remove(stem .. "_R.wav")
end

-- SOUND-LOCKS ride the PSET like the take + scenes: the 8 per-pad voice+pitch
-- locks save as a small lua table beside the pset (params:read only restores the
-- editor params, i.e. the cursor pad — this restores all 8).
local function padlock_path(number)
  return norns.state.data .. "padlock-" .. number .. ".lua"
end

function ctx.padlock_pset_write(number)
  local t = { v = 1, type = {}, pitch = {}, cuts = ctx.pad_cuts }
  for i = 0, 7 do t.type[i] = ctx.pad_type[i] or 0; t.pitch[i] = ctx.pad_pitch[i] or 0 end
  -- guarded like every other pset writer here: a write failure must PRINT, not
  -- throw out of params.action_write and abort the rest of the save
  local ok, err = pcall(tab.save, t, padlock_path(number))
  if not ok then print("mangler: pad-lock save failed — " .. tostring(err)) end
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
  ctx.pad_edit_sync()   -- editor params -> the restored cursor pad
end

function ctx.padlock_pset_delete(number)
  os.remove(padlock_path(number))
end

-- browsable stereo EXPORT. write_take dumps the DRY take to a temp
-- L/R pair; we wait for the async /b_write to finish (sizes stop growing), then
-- interleave into a named stereo wav in dust/audio that reloads via `load
-- sample` (zero new load code).
-- hand back to the scheduler for one tick. Every long scan inside a clock
-- coroutine takes this, so the 15fps redraw (and motion, and scenes) keeps
-- running through a multi-second job instead of freezing.
function ctx.task_yield() clock.sleep(0) end

-- run a long job as a coroutine that yields.
-- The body runs under pcall and `on_done(ok, err)` ALWAYS runs: without that a
-- throw halfway through (a full card, a bad read) kills the coroutine with the
-- caller's state half-set and its file handles still open. A second job is
-- REFUSED, not substituted — the job already running owns its cleanup and only
-- it can run it.
local task_clock
function ctx.run_task(fn, on_done)
  if task_clock then
    print("mangler: a background job is already running")
    if on_done then on_done(false, "busy") end
    return false
  end
  task_clock = clock.run(function()
    local ok, err = pcall(fn, ctx.task_yield)
    task_clock = nil
    if not ok then print("mangler: background job failed — " .. tostring(err)) end
    if on_done then on_done(ok, err) end
  end)
  return true
end

local export_clock
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

local function next_export_name()
  local stem = ctx.next_free(_path.audio, "mangler", ".wav")
  return stem and (stem .. ".wav")
end
local function next_print_name()
  local stem = ctx.next_free(_path.audio, "mangler-print", ".wav")
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
  if pass then print("mangler: a recording pass is already running"); return false end
  if not (audio.tape_record_open and audio.tape_record_start) then
    print("mangler: no system tape API — cannot record"); return false
  end
  -- recording a CHOKED output would capture silence, and a caller that then
  -- loads the result would wipe the take with nothing
  if pget("stop_all", 0) == 1 then
    print("mangler: pass refused — output is stopped (K1+K2 to start)")
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
  local name = next_print_name()
  if not name then
    print("mangler: 999 prints in dust/audio — clear some out first")
    return
  end
  local ok = ctx.record_pass(_path.audio .. name, secs, sweep,
    function(finished, path)
      if not finished then
        os.remove(path)        -- a part-silent bounce is not worth keeping
        print("mangler: PRINT aborted by STOP — the take is untouched")
        return
      end
      ctx.load_sample(path)
      print("mangler: PRINT done — " .. name .. " is the new take")
    end)
  if ok then
    print(string.format("mangler: PRINT — recording the master mix, %.1fs", secs))
  end
end

-- dump the live take to ONE stereo wav: write_take drops an L/R pair (bufL and
-- bufR are two MONO buffers and scsynth has no cheap non-realtime interleave),
-- we wait out the async /b_write, then zip them. `done(ok, path)` when the file
-- is there. Lua cannot read an SC buffer, so this file IS the API — the export
-- and the pad chopper are both built on it.
function ctx.take_to_wav(out, done)
  if not engine.write_take then
    print("mangler: engine has no write_take — SYSTEM > RESTART")
    if done then done(false) end
    return
  end
  if not ctx.wave_any then
    print("mangler: nothing to render — the buffer is empty")
    if done then done(false) end
    return
  end
  -- REFUSE a second dump rather than cancelling the first. Both callers share
  -- this one clock and one tmp stem; cancelling killed the coroutine
  -- mid-interleave, leaving a TRUNCATED wav that looks finished in the browser,
  -- and the new dump would overwrite the files the cancelled one was reading.
  if export_clock then
    print("mangler: a take dump is already running")
    if done then done(false) end
    return
  end
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
    local ok = Mpages.interleave_wav(tmp .. "_L.wav", tmp .. "_R.wav", out,
      ctx.task_yield)
    os.remove(tmp .. "_L.wav"); os.remove(tmp .. "_R.wav")
    export_clock = nil
    if done then done(ok, out) end
  end)
end

-- the browsable half: the same dump, into dust/audio under a name you can find.
function ctx.export_take(name)
  name = name or next_export_name()
  if not name then
    print("mangler: 999 exports in dust/audio — clear some out first")
    return
  end
  local out = _path.audio .. name
  ctx.take_to_wav(out, function(ok)
    print(ok and ("mangler: exported " .. out) or "mangler: export FAILED")
  end)
end

-- tempo-synced delay: when delay_sync is not FREE, delay_time follows the
-- clock at the chosen division. computed here (Lua) so the ENGINE command
-- set is untouched; the engine's 0.2s time-lag turns tempo changes into a
-- tape-style glide, and times beyond the 2s delay line clamp there (2s so
-- a half note fits down to 60 BPM). the
-- redraw tick calls this each frame — it only WRITES when the tempo actually
-- changed (or the division did), so idle frames set nothing.
local SYNC_BEATS = { 0, 0.25, 0.5, 0.75, 1, 1.5, 2 }  -- FREE 1/16 1/8 1/8. 1/4 1/4. 1/2
local last_sync_tempo = 0
local function sync_delay_time(force)
  local s = pget("delay_sync", 1)
  if s <= 1 then return end                          -- FREE
  local t = ctx.tempo()
  if not (t and t > 0) then return end
  if not force and t == last_sync_tempo then return end
  last_sync_tempo = t
  params:set("delay_time", clamp(SYNC_BEATS[s] * 60 / t, 0.01, 2))
  -- tell the gesture looper this wasn't a hand on the knob (its polling
  -- capture would otherwise punch a delay_time lane on every tempo move)
  if ctx.motion and ctx.motion.account then ctx.motion.account("delay_time") end
end

-- DRY throw (MIX K1+K3, grid (7,2)): playback becomes the un-effected
-- sample — every "on top" color to zero (delay, reverb, shimmer, drive,
-- clouds feedback — the one wash the REVERB page can't kill) and the
-- filter thrown open (type-aware, same law as FILTER's OPEN key). the
-- take itself is always recorded clean; this clears the playback path.
function ctx.fx_dry()
  ctx.throws_forget()   -- DRY moves the wet path wholesale: no throw's "back"
                        -- survives it (a latched WASH would restore reverb)
  params:set("delay_mix", 0)
  params:set("rev_mix", 0)
  params:set("shimmer", 0)
  params:set("drive", 0)
  params:set("clouds_fb", 0)
  local ft = params:get("filt_type")
  params:set("cutoff", filter_open_cutoff(ft))
  params:set("resonance", 0)
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
local function add_eng_control(id, name, spec, map)
  params:add_control(id, name, spec)
  params:set_action(id, function(v)
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

local function init_params()
  params:add_separator("mangler")

  -- group ids must differ from every param id, and the declared count MUST
  -- match the adds that follow (a refused/missing add corrupts the paramset)
  params:add_group("grp_mix", "mix", 5)
  params:add_control("mix", "eng <> tape",
    controlspec.new(0, 1, "lin", 0, 0.5, ""))
  params:set_action("mix", Mtape.update_mix)
  params:add_control("out_level", "out level",
    controlspec.new(0, 1.5, "lin", 0, 1.0, ""))
  params:set_action("out_level", function()
    Mtape.update_mix()
    ctx.layers_relevel()   -- the master masters the layer decks too
  end)
  params:add_control("sc_level", "eng level",
    controlspec.new(0, 1, "lin", 0, 1.0, ""))
  params:set_action("sc_level", Mtape.update_mix)
  -- id "tape_level" is RESERVED by the system TAPE deck; "cut_level" avoids it
  params:add_control("cut_level", "tape level",
    controlspec.new(0, 1, "lin", 0, 1.0, ""))
  params:set_action("cut_level", Mtape.update_mix)
  -- master transport: STOP chokes both decks at the one place their levels
  -- are computed (update_mix), so START restores the exact mix. everything
  -- keeps running silently — mode, loops, heads — and held pad voices are
  -- released. MIDI-map it for a stop pedal; SPACE on a typing keyboard and
  -- grid (8,2) drive it too.
  params:add_binary("stop_all", "stop all", "toggle", 0)
  params:set_action("stop_all", function(v)
    if v == 1 then ctx.pads_all_off() end
    Mtape.update_mix()
    ctx.layers_relevel()   -- the layer decks choke with everything else
    -- TRUE STOP (S23 B1): the transports HALT too, not just the levels. every
    -- softcut head glides to rate 0 (the slew keeps it click-free) and START
    -- resumes each exactly where it stood — and because they all stop AS ONE,
    -- the decks' relative drift survives a stop/start. the rate/rec laws fold
    -- (1 - stop_all), so re-sending them applies it in both directions. the
    -- engine drone's head freezes on its own: its level lands at 0 and the
    -- read head runs on (level > 0), same law as the erosion/regen heads.
    Mtape.update_tape_rate()
    Mtape.update_tape_rec()
    for _, d in ipairs(ctx.layers) do
      Mdeck.update_rate(d)
      Mdeck.update_rec(d)
    end
    -- the engine record head pauses with everything else. the param stays
    -- armed, so START resumes the take mid-punch; the rec action gates its
    -- own sends the same way, so arming DURING a stop also waits for START.
    if engine.rec then engine.rec(v == 1 and 0 or pget("rec", 0)) end
  end)

  params:add_group("grp_rec", "take - record", 13)
  add_eng_binary("rec", "record")
  -- when capture stops, snap the window to the take just recorded so playback
  -- immediately loops what you played — not a 60s window of mostly silence
  params:set_action("rec", function(v)
    if engine.rec then
      -- under a STOP everything is halted, capture included: an arm made
      -- while stopped takes effect on START (the stop action re-sends it).
      -- the window bookkeeping below still runs — the head is frozen, so
      -- the arm position it records is exactly where START will resume.
      engine.rec(pget("stop_all", 0) == 1 and 0 or v)
    end
    if v == 1 then
      ctx.rec_arm_phase = ctx.rec_phase
    elseif ctx.rec_phase > ctx.rec_arm_phase + 0.005 then
      params:set("pos_start", ctx.rec_arm_phase)
      params:set("pos_end", ctx.rec_phase)
    elseif ctx.rec_phase < ctx.rec_arm_phase - 0.005 then
      -- the write head wrapped past the buffer end mid-take. a wrapped
      -- window (start > end) would be SORTED into the wrong slice by
      -- window_bounds, so fall back to the whole buffer — the take is in
      -- there, just split across the seam. (proper wrap-around windows
      -- need engine support.)
      params:set("pos_start", 0)
      params:set("pos_end", 1)
    end
    if v == 0 then
      -- the take bounds what a PSET save writes (the write head runs
      -- 0..pos_end). regen fills the whole buffer, so it forces a full save.
      -- GROW ONLY: this is a high-water mark, and a rec pass overwrites only
      -- the region it recorded — everything else is still in the buffer. A
      -- short punch-in over a narrowed window used to REPLACE the mark with
      -- that narrow pos_end, so the next PSET save wrote a few seconds and the
      -- rest of the take was gone on reload, with no error anywhere. Fresh
      -- material resets the mark on purpose (clear/load/print), never a punch.
      local bound = pget("regen", 0) > 0 and 1 or pget("pos_end", 1)
      if bound > (ctx.take_len or 0) then ctx.take_len = bound end
    end
  end)
  add_eng_control("rec_level", "rec level",
    controlspec.new(0, 1, "lin", 0, 1.0, ""))
  add_eng_control("pre_level", "overdub",
    controlspec.new(0, 1, "lin", 0, 0.0, ""))
  add_eng_binary("freeze", "freeze")
  add_eng_control("dry_wet", "dry/wet",
    controlspec.new(0, 1, "lin", 0, 0.5, ""))
  add_eng_control("resample", "resample (in<>out)",
    controlspec.new(0, 1, "lin", 0, 0.0, ""))
  -- self-resampling: continuous feedback of the processed OUTPUT back into
  -- the record buffer (Basinski-style regenerative decay). 0 = off (a fresh
  -- take stays dry). manual rec + freeze suspend it; engine-side it's a bounded
  -- convex crossfade so it can't run away.
  add_eng_control("regen", "regen (self-resample)",
    controlspec.new(0, 1, "lin", 0, 0.0, ""))
  params:set_action("regen", function(v)
    -- the other half of the erode interlock (see grp_erode below)
    if v > 0 and pget("erode", 0) > 0 then params:set("erode", 0) end
    if engine.regen then engine.regen(v) end
    -- regen's record head traverses the WHOLE buffer, so once it runs the take
    -- can be anywhere: force a full-buffer PSET save (sticky until the next
    -- fresh rec / load / clear resets take_len), never truncate its decay tail.
    if v > 0 then ctx.take_len = 1 end
  end)
  -- delete the take (REC K1+K3, mirroring TAPE's CLR) and load one off the
  -- disk. clear is a MOMENTARY binary so a footswitch can wipe between takes;
  -- both fire on the press edge only, so a stray 0 from bang/pset does nothing.
  params:add_binary("clear_rec", "clear recording", "momentary", 0)
  params:set_action("clear_rec", function(v)
    if v == 1 then ctx.clear_recording() end
  end)
  -- add_file opens norns' fileselect in the menu and the path rides the PSET,
  -- so a saved session reloads its sample
  params:add_file("sample_file", "load sample", _path.audio)
  params:set_action("sample_file", function(f) ctx.load_sample(f) end)
  -- export the take as a browsable stereo wav in dust/audio.
  -- momentary so a footswitch/grid can fire it; press edge only.
  params:add_binary("export_take", "export take (wav)", "momentary", 0)
  params:set_action("export_take", function(v)
    if v == 1 then ctx.export_take() end
  end)
  -- pull the window in onto the sound (see ctx.take_tighten). momentary so a
  -- footswitch reaches it; non-destructive — it only moves the window edges.
  params:add_binary("take_tighten", "tighten window to sound", "momentary", 0)
  params:set_action("take_tighten", function(v)
    if v == 1 then ctx.take_tighten() end
  end)
  -- PRINT the master mix back into the buffer (see ctx.print_take). momentary
  -- so a footswitch fires the whole bounce; press edge only.
  params:add_binary("print_take", "print mix -> take", "momentary", 0)
  params:set_action("print_take", function(v)
    if v == 1 then ctx.print_take() end
  end)
  params:add_control("print_len", "print length",
    controlspec.new(0, 16, "lin", 0.5, 0, "s"),
    function(p)
      local v = p:get()
      return v < 0.05 and "AUTO (window)" or string.format("%.1f s", v)
    end)

  params:add_group("grp_window", "take - window", 4)
  -- default controlspec quantum is 0.01 = 1% per click = 600ms of a 60s
  -- buffer: way too coarse to set a loop. 0.002 base + fine_delta's span
  -- scaling in enc() gets down to ~10ms nudges on a tight window.
  local pos_start_spec = controlspec.new(0, 1, "lin", 0, 0.0, "")
  pos_start_spec.quantum = 0.002
  add_eng_control("pos_start", "win start", pos_start_spec)
  local pos_end_spec = controlspec.new(0, 1, "lin", 0, 1.0, "")
  pos_end_spec.quantum = 0.002
  add_eng_control("pos_end", "win end", pos_end_spec)
  add_eng_control("scan", "scan rate",
    controlspec.new(-2, 2, "lin", 0, 1.0, "x"))
  add_eng_control("pos_jitter", "jitter",
    controlspec.new(0, 1, "lin", 0, 0.0, ""))

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
  add_eng_control("spread", "spread",
    controlspec.new(0, 1, "lin", 0, 0.5, ""))
  add_eng_control("pan", "pan",
    controlspec.new(-1, 1, "lin", 0, 0.0, ""))
  add_eng_control("grain_level", "grain level",
    controlspec.new(0, 1.5, "lin", 0, 1.0, ""))
  -- granular character: per-grain size jitter + detune spread (both
  -- continuous from 0 = off), and a 3-way grain-envelope shape. shape is
  -- an option (engine wants 0/1/2, norns options are 1-based, so -1 in the
  -- action — same trick as `mode`).
  add_eng_control("grain_jitter", "grain jitter",
    controlspec.new(0, 1, "lin", 0, 0.0, ""))
  add_eng_control("grain_pitch_spread", "pitch spread",
    controlspec.new(0, 12, "lin", 0, 0.0, "st"))
  params:add_option("grain_shape", "grain shape", { "HANN", "WELCH", "PERC" }, 1)
  params:set_action("grain_shape", function(v)
    if engine.grain_shape then engine.grain_shape(v - 1) end
  end)

  -- MiClouds granular controls (GRAIN mode uses the Clouds voice when
  -- mi-UGens are installed; on the GrainBuf fallback these are stored but
  -- ignored — same guarded philosophy as the JPverb-only reverb params). the
  -- shared size/density/spread/pitch already remap to Clouds; these are the
  -- Clouds-specific attributes. edited on the GRAIN page + PARAMS.
  params:add_group("grp_clouds", "voice - clouds", 5)
  add_eng_control("clouds_pos", "grain position",
    controlspec.new(0, 1, "lin", 0, 0.5, ""))
  add_eng_control("clouds_tex", "grain texture",
    controlspec.new(0, 1, "lin", 0, 0.5, ""))
  add_eng_control("clouds_fb", "grain feedback",
    controlspec.new(0, 1, "lin", 0, 0.0, ""))
  params:add_option("clouds_mode", "clouds mode",
    { "GRANULAR", "STRETCH", "LOOP", "SPECTRAL" }, 1)
  params:set_action("clouds_mode", function(v)
    if engine.clouds_mode then engine.clouds_mode(v - 1) end
  end)
  add_eng_control("clouds_lofi", "grain lofi",
    controlspec.new(0, 1, "lin", 0, 0.0, ""))

  params:add_group("grp_stretch", "voice - stretch", 5)
  -- mode swaps the playback synth in the engine: only the active algorithm
  -- costs CPU; OFF frees the SC voice entirely
  -- PLAY (clean straight loop = the exact recorded sample) is the
  -- DEFAULT so a fresh take plays back untouched; GRAIN/WARP/PV are switched
  -- on for mangling. appended (not reordered) so 1..4 keep their meaning.
  params:add_option("mode", "mode", { "OFF", "GRAIN", "WARP", "PV", "PLAY" }, 5)
  params:set_action("mode", function(v)
    if engine.mode then engine.mode(v - 1) end
  end)
  add_eng_control("warp_window", "warp window",
    controlspec.new(0.05, 0.5, "exp", 0, 0.25, "s"))
  params:add_number("warp_overlaps", "warp overlaps", 1, 8, 4)
  params:set_action("warp_overlaps", function(v)
    if engine.warp_overlaps then engine.warp_overlaps(v) end
  end)
  add_eng_control("warp_rand", "warp rand",
    controlspec.new(0, 1, "lin", 0, 0.0, ""))
  add_eng_binary("pv_freeze", "pv freeze")

  -- ---- the layer decks ---------------------------------------------------
  -- Two more loop decks on softcut, beside the tape. Same shape, their own
  -- regions of the buffer. See doc/layers.md; the deck itself is lib/mdeck.lua.
  -- `pre` defaults to 1 (OVERDUB) unlike the tape's 0 (REPLACE): these are
  -- LAYERS, stacking is the job, and it is the loop-pedal gesture people
  -- already have in their hands. K1+K3 on the page erases one to start over.
  params:add_group("grp_layers", "layers", 26)
  params:add_number("layer_sel", "layer", 1, 2, 1)
  -- the BOUNCE: while ON (the default), arming a layer records the processed
  -- engine output instead of the raw input — resampling is just K2 on LAYERS.
  -- OFF = the decks follow cut_source like the tape always has. the SRC flag
  -- on TAPE and LAYERS shows the EFFECTIVE source either way.
  params:add_binary("layer_wet", "layers record the mix", "toggle", 1)
  params:set_action("layer_wet", function() ctx.update_cut_source() end)
  for n = 1, 2 do
    local id = "lay" .. n
    local function q(k) return id .. "_" .. k end
    local function deck() return ctx.layers[n] end
    -- load a wav straight into this deck (norns fileselect; the path rides the
    -- PSET, so a session reloads its layer material even with no deck wav)
    params:add_file(q("file"), "L" .. n .. " load file", _path.audio)
    params:set_action(q("file"), function(f) ctx.layer_load(deck(), f) end)
    params:add_binary(q("rec"), "L" .. n .. " record", "toggle", 0)
    params:set_action(q("rec"), function(v)
      -- arming: settle the record SOURCE before the head opens (the bounce
      -- may throw it WET), and open the loop so nothing you play is cut off;
      -- disarming: close the head, then close the loop around what you played
      if v == 1 then
        ctx.update_cut_source()
        Mdeck.arm_loop(deck())
        Mdeck.update_rec(deck())
      else
        Mdeck.update_rec(deck())
        Mdeck.close_loop(deck())
        ctx.update_cut_source()
      end
    end)
    params:add_binary(q("play"), "L" .. n .. " play", "toggle", 1)
    params:set_action(q("play"), function() Mdeck.update_level(deck()) end)
    params:add_control(q("level"), "L" .. n .. " level",
      controlspec.new(0, 1, "lin", 0, 0.8, ""))
    params:set_action(q("level"), function() Mdeck.update_level(deck()) end)
    params:add_control(q("rate"), "L" .. n .. " rate",
      controlspec.new(0.25, 4, "exp", 0, 1.0, "x"))
    params:set_action(q("rate"), function() Mdeck.update_rate(deck()) end)
    params:add_binary(q("reverse"), "L" .. n .. " reverse", "toggle", 0)
    params:set_action(q("reverse"), function() Mdeck.update_rate(deck()) end)
    local ls = controlspec.new(0, 1, "lin", 0, 0.0, "")
    ls.quantum = 0.002
    params:add_control(q("start"), "L" .. n .. " loop start", ls)
    params:set_action(q("start"), function() Mdeck.update_loop(deck()) end)
    local le = controlspec.new(0, 1, "lin", 0, 1.0, "")
    le.quantum = 0.002
    params:add_control(q("end"), "L" .. n .. " loop end", le)
    params:set_action(q("end"), function() Mdeck.update_loop(deck()) end)
    params:add_control(q("pre"), "L" .. n .. " overdub",
      controlspec.new(0, 1, "lin", 0, 1.0, ""))
    params:set_action(q("pre"), function() Mdeck.update_rec(deck()) end)
    -- The join where the loop starts over. Short is a clean cut and a hard
    -- downbeat; long is a blend that hides the join landing mid-note.
    params:add_control(q("fade"), "L" .. n .. " seam",
      controlspec.new(0.001, 0.5, "exp", 0, 0.02, "s"))
    params:set_action(q("fade"), function() Mdeck.update_fade(deck()) end)
    -- Stereo width: 1 is the deck's own full left and right, 0 folds it to
    -- the middle. Two decks playing related material, both at full width, is
    -- a wall of sound with no room to hear either one.
    params:add_control(q("width"), "L" .. n .. " width",
      controlspec.new(0, 1, "lin", 0, 1.0, ""))
    params:set_action(q("width"), function() Mdeck.update_width(deck()) end)
    -- A momentary switch, so a footswitch can reach it. There is no key left
    -- for this: LAYERS already uses K2 and K3, and holding K1 is reserved for
    -- stop and erase on every page. So it lives in PARAMS, on MIDI and on the
    -- grid, the same as pad_chop. The automatic snap when a recording ends
    -- needs no key at all.
    params:add_binary(q("snap"), "L" .. n .. " snap loop", "momentary", 0)
    params:set_action(q("snap"), function(v)
      if v == 1 then ctx.layer_snap(deck()) end
    end)
  end

  params:add_group("grp_tape", "tape", 9)
  params:add_binary("tape_rec", "tape record", "toggle", 0)
  -- mirror the SC side's workflow: arming with no overdub opens the loop to
  -- the full tape for a fresh take; stopping snaps the loop around the take
  -- and jumps the head to its start, so it plays back tight immediately.
  -- The layer decks do the same thing through Mdeck.arm_loop / close_loop.
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
      tape_arm_phase = nil
      if pget("tape_pre", 0) == 0 then
        if (pget("loop_end", 1) - pget("loop_start", 0)) < 0.99 then
          Mtape.set_loop(0, 1)
        end
        tape_arm_phase = ctx.tape_phase
      end
    elseif not tape_arm_phase then
      -- an overdub, or a pass this action never opened: leave the loop alone
    elseif ctx.tape_phase > tape_arm_phase + 0.005 then
      Mtape.set_loop(tape_arm_phase, ctx.tape_phase)
      Mtape.jump_to(tape_arm_phase)
      tape_arm_phase = nil
    elseif ctx.tape_phase < tape_arm_phase - 0.005 then
      -- head wrapped past the tape end mid-take: softcut loops can't cross
      -- the seam, so keep the full tape rather than snapping a wrong slice
      Mtape.set_loop(0, 1)
      tape_arm_phase = nil
    else
      tape_arm_phase = nil
    end
    Mtape.update_tape_rec()
  end)
  params:add_control("tape_rate", "tape rate",
    controlspec.new(-2, 2, "lin", 0, 1.0, "x"))
  params:set_action("tape_rate", Mtape.update_tape_rate)
  params:add_binary("tape_reverse", "tape reverse", "momentary", 0)
  params:set_action("tape_reverse", Mtape.update_tape_rate)
  -- same fine quantum + span-scaled deltas as the window edges
  local loop_start_spec = controlspec.new(0, 1, "lin", 0, 0.0, "")
  loop_start_spec.quantum = 0.002
  params:add_control("loop_start", "loop start", loop_start_spec)
  params:set_action("loop_start", Mtape.update_tape_loop)
  local loop_end_spec = controlspec.new(0, 1, "lin", 0, 1.0, "")
  loop_end_spec.quantum = 0.002
  params:add_control("loop_end", "loop end", loop_end_spec)
  params:set_action("loop_end", Mtape.update_tape_loop)
  params:add_control("tape_pre", "tape overdub",
    controlspec.new(0, 1, "lin", 0, 0.0, ""))
  params:set_action("tape_pre", Mtape.update_tape_rec)
  params:add_binary("tape_freeze", "tape freeze", "toggle", 0)
  params:set_action("tape_freeze", Mtape.update_tape_rec)
  params:add_control("tape_fade", "tape fade",
    controlspec.new(0.001, 0.5, "exp", 0, 0.05, "s"))
  params:set_action("tape_fade", Mtape.set_fade)
  -- tape RECORD SOURCE (K1+E3 on TAPE): 0 = DRY raw input .. 1 = WET post-FX
  -- engine output — the tape as a print / resample stage. default DRY = the classic parallel-ADC tap, so nothing changes until
  -- you reach for it.
  params:add_control("cut_source", "tape source",
    controlspec.new(0, 1, "lin", 0, 0.0, ""))
  -- through the one source writer: while a layer bounce holds the send WET,
  -- turning the knob re-resolves rather than silently fighting it
  params:set_action("cut_source", function() ctx.update_cut_source() end)

  params:add_group("grp_filter", "filter", 4)
  params:add_option("filt_type", "filter type", { "LP", "HP", "BP" }, 1)
  params:set_action("filt_type", function(v)
    if engine.filt_type then engine.filt_type(v - 1) end
  end)
  add_eng_control("cutoff", "cutoff",
    controlspec.new(20, 20000, "exp", 0, 20000, "hz"))
  add_eng_control("resonance", "resonance",
    controlspec.new(0, 1, "lin", 0, 0.0, ""))
  -- post-filter tanh saturation with makeup: louder AND dirtier up
  add_eng_control("drive", "drive",
    controlspec.new(0, 1, "lin", 0, 0.0, ""))

  params:add_group("grp_delay", "delay", 4)
  add_eng_control("delay_time", "delay time",
    controlspec.new(0.01, 2, "exp", 0, 0.3, "s"))
  -- tempo sync (DELAY K1+E3): FREE = the time knob; a division = delay_time
  -- follows the clock (re-asserted on tempo changes from the redraw tick)
  params:add_option("delay_sync", "delay sync",
    { "FREE", "1/16", "1/8", "1/8.", "1/4", "1/4.", "1/2" }, 1)
  params:set_action("delay_sync", function() sync_delay_time(true) end)
  -- 0..1 knob curved to the actual 0..0.98 feedback coefficient (fb_curve):
  -- a smooth "few -> many (10+) -> near-infinite" sweep, not a top-end cliff.
  add_eng_control("delay_fb", "feedback",
    controlspec.new(0, 1, "lin", 0, 0.3, ""), fb_curve)
  -- FX SEND response curve: the engine crossfades the wet with an equal-power
  -- .sqrt (Engine_Mangler.sc), so a raw 3% knob already reads ~17% wet ("way too
  -- blunt"). `square` makes the effective wet gain LINEAR in the knob — a
  -- progressive fade (dry stays ~full at the bottom, full wet at 1). same reverb.
  add_eng_control("delay_mix", "delay mix",
    controlspec.new(0, 1, "lin", 0, 0.0, ""), square)

  -- the reverb is JPverb's FULL attribute set (guarded → FreeVerb
  -- fallback in the engine). every knob maps to a real JPverb arg — nothing
  -- hardcoded. REVERB face reaches mix/size/decay/damp (E2/E3 + K1 alt);
  -- the other 11 (early/mod/EQ/cuts/shimmer) live in PARAMS + the WASH/BLOOM
  -- throws. shimmer surges on the BLOOM key.
  params:add_group("grp_reverb", "reverb", 15)
  add_eng_control("rev_decay", "reverb decay",
    controlspec.new(0.1, 30, "exp", 0, 2.0, "s"))
  add_eng_control("rev_damp", "reverb damp",
    controlspec.new(0, 1, "lin", 0, 0.3, ""))
  add_eng_control("rev_size", "reverb size",
    controlspec.new(0.5, 5, "lin", 0, 1.0, ""))
  add_eng_control("rev_early", "early diffusion",
    controlspec.new(0, 1, "lin", 0, 0.7, ""))
  add_eng_control("rev_moddepth", "mod depth",
    controlspec.new(0, 1, "lin", 0, 0.1, ""))
  add_eng_control("rev_modfreq", "mod freq",
    controlspec.new(0, 10, "lin", 0, 2.0, "hz"))
  add_eng_control("rev_low", "low decay",
    controlspec.new(0, 1, "lin", 0, 1.0, ""))
  add_eng_control("rev_mid", "mid decay",
    controlspec.new(0, 1, "lin", 0, 1.0, ""))
  add_eng_control("rev_high", "high decay",
    controlspec.new(0, 1, "lin", 0, 1.0, ""))
  add_eng_control("rev_lowcut", "low crossover",
    controlspec.new(20, 2000, "exp", 0, 500, "hz"))
  add_eng_control("rev_highcut", "high crossover",
    controlspec.new(200, 20000, "exp", 0, 2000, "hz"))
  add_eng_control("rev_mix", "reverb mix",
    controlspec.new(0, 1, "lin", 0, 0.0, ""), square)   -- progressive fade (see delay_mix)
  -- shimmer: pitch-shifted reverb feedback (climbs in octaves into a pad)
  add_eng_control("shimmer", "shimmer",
    controlspec.new(0, 1, "lin", 0, 0.0, ""))
  add_eng_control("shimmer_pitch", "shimmer pitch",
    controlspec.new(-12, 24, "lin", 1, 12, "st"))
  add_eng_control("shimmer_tone", "shimmer tone",
    controlspec.new(500, 12000, "exp", 0, 4500, "hz"))

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
  params:add_control("pad_level", "pad level",
    controlspec.new(0, 1, "lin", 0, 0.3, ""))
  -- CHOP the pads onto the take's own attacks. momentary (not a trigger) so it
  -- is MIDI-learnable — the whole point is a footswitch. Firing it with no
  -- transients found, or on a fresh buffer, puts the pads back to even slices.
  params:add_binary("pad_chop", "chop to transients", "momentary", 0)
  params:set_action("pad_chop", function(v) if v == 1 then ctx.pad_chop() end end)
  params:add_binary("pad_even", "back to even slices", "momentary", 0)
  params:set_action("pad_even", function(v)
    if v == 1 then ctx.pads_uncut(); print("mangler: pads back to even slices") end
  end)

  -- chromatic note input (MIDI notes + typing keyboard): all of it drives
  -- the same `pitch` param as the encoder and any mapped CC, in lockstep
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
  params:add_group("grp_motion", "motion", 5)
  params:add_binary("motion_rec", "motion record", "toggle", 0)
  params:set_action("motion_rec", function(v) ctx.motion.set_armed(v == 1) end)
  params:add_binary("motion_play", "motion play", "toggle", 0)
  params:set_action("motion_play", function(v) ctx.motion.set_playing(v == 1) end)
  params:add_number("motion_lane", "motion lane", 0, 16, 0,
    function(p)
      local ids = ctx.motion.lane_ids
      local n = #ids
      local v = math.min(p:get(), n)
      if n == 0 or v == 0 then return "-" end
      return ids[v]
    end)
  params:add_control("motion_depth", "motion depth",
    controlspec.new(0, 1, "lin", 0, 1.0, ""))
  -- settable loop length (K1+E2 on MOTION). 0 = AUTO (the recorded length);
  -- >0 retimes the loop's playback SPEED without touching the stored gesture.
  params:add_control("motion_len", "motion length",
    controlspec.new(0, 60, "lin", 0.5, 0, "s"))
  params:set_action("motion_len", function(v) ctx.motion.set_len(v) end)

  -- scenes / morph / safe state (see lib/mscenes). all Lua-only — no
  -- engine command, so the fingerprint is unchanged. the ACTIONS here are
  -- momentary binaries rather than triggers: a trigger can't be MIDI-learned,
  -- and the whole point is a footswitch that captures, recalls, rescues or
  -- throws. every action fires on the press edge (v == 1) only — a stray 0
  -- from params:bang() or a pset read must never do anything.
  params:add_group("grp_scene", "scenes", 11)
  -- ONE selector, three jobs: the slot K2 recalls, K3 captures into, and the
  -- morph aims at. (there used to be two more — `morph A`/`morph B` — on the
  -- alt layer, where you couldn't see them. see mscenes' morph_from.)
  -- slot 0 is the ◄ cell — the way back (mscenes branches on it)
  params:add_number("scene_slot", "scene slot", 0, 8, 1)
  params:set_action("scene_slot", function()
    -- re-aim a sweep in progress; at rest, picking a slot must stay silent
    if pget("scene_morph_amt", 0) > 0 then Mscenes.touch() end
  end)
  -- THE performance knob: sweeps from the sound you have toward the selected
  -- slot. MIDI-map it to a fader/pedal, or record it with the gesture looper
  -- (it's in MOTION_IDS — one lane replays the whole sweep). only this writes
  -- params, and only from the next frame's tick (mscenes coalesces so a fast
  -- CC can't flood the engine).
  params:add_control("scene_morph_amt", "morph amount",
    controlspec.new(0, 1, "lin", 0, 0.0, ""))
  params:set_action("scene_morph_amt", function() Mscenes.touch() end)
  params:add_option("scene_recall_mode", "recall quantize",
    { "NOW", "BEAT", "BAR" }, 1)
  -- what CAP stores: the whole mangle, or just the wet path (an FX preset
  -- that lands over whatever material is playing — Octatrack-style)
  params:add_option("scene_scope", "capture scope", { "ALL", "FX" }, 1)
  -- actions on the selected slot (also the SCENE page's K2/K3)
  params:add_binary("scene_capture", "capture to slot", "momentary", 0)
  params:set_action("scene_capture", function(v)
    if v == 1 then Mscenes.capture() end
  end)
  params:add_binary("scene_recall", "recall slot", "momentary", 0)
  params:set_action("scene_recall", function(v)
    if v == 1 then Mscenes.recall() end
  end)
  -- stomp through a set: advance to the next FILLED slot and recall it
  -- (cycling; honors BEAT/BAR quantize). MIDI-map a footswitch.
  params:add_binary("scene_next", "next scene", "momentary", 0)
  params:set_action("scene_next", function(v)
    if v == 1 then Mscenes.next() end
  end)
  params:add_binary("scene_clear", "clear slot", "momentary", 0)
  params:set_action("scene_clear", function(v)
    if v == 1 then Mscenes.clear() end
  end)
  -- the safety net (the SCENE page's alt layer): mark a state, then get back
  -- to it. control state only — it never touches the buffer or the tape audio.
  params:add_binary("scene_safe_capture", "mark safe state", "momentary", 0)
  params:set_action("scene_safe_capture", function(v)
    if v == 1 then Mscenes.safe_capture() end
  end)
  params:add_binary("scene_safe_restore", "restore safe state", "momentary", 0)
  params:set_action("scene_safe_restore", function(v)
    if v == 1 then Mscenes.safe_restore() end
  end)
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
  params:add_control("erode", "erode",
    controlspec.new(0, 1, "lin", 0, 0.0, ""))
  params:set_action("erode", function(v)
    -- interlock: erode and regen are both free-running write heads on the
    -- same buffer. engaging one disengages the other, so the conflict is
    -- impossible rather than documented. no recursion: each interlock only
    -- acts when its own value is rising.
    if v > 0 and pget("regen", 0) > 0 then params:set("regen", 0) end
    if engine.erode then engine.erode(v) end
  end)
  add_eng_control("wear", "wear",
    controlspec.new(0, 1, "lin", 0, 0.5, ""))

  -- PSETs persist the audio too: PARAMS > PSET > SAVE/LOAD/DELETE round-trip
  -- the softcut buffers (mtape) AND the granular engine's record
  -- buffer — the live take, as an L/R wav pair beside the pset (ctx.take_pset_*
  -- → engine write_take/read_take). the hooks are SHARED: each module/helper
  -- does its own half (mtape the tape audio, mscenes the scene bank + safe
  -- snapshot as a lua table, the take helpers the engine buffer).
  params.action_write = function(filename, name, number)
    Mtape.pset_write(number)
    Mdeck.pset_write(number)
    Mscenes.pset_write(number)
    ctx.take_pset_write(number)   -- the engine take, as an L/R pair
    ctx.padlock_pset_write(number)  -- per-pad sound-locks
  end
  params.action_read = function(filename, silent, number)
    Mtape.pset_read(number)
    Mdeck.pset_read(number)
    Mscenes.pset_read(number)
    ctx.take_pset_read(number)
    ctx.padlock_pset_read(number)
  end
  params.action_delete = function(filename, name, number)
    Mtape.pset_delete(number)
    Mdeck.pset_delete(number)
    Mscenes.pset_delete(number)
    ctx.take_pset_delete(number)
    ctx.padlock_pset_delete(number)
  end

  params:bang()
end

-- ============================================================================
-- norns callbacks
-- ============================================================================

function init()
  print("mangler: init() called")
  init_params()
  Mtape.init_tape()
  for _, d in ipairs(ctx.layers) do Mdeck.start(d) end
  Minput.init_midi()
  Mgrid.connect()
  print("mangler: init() done, params built")

  -- the norns SYSTEM aux reverb sits after the engine and colors everything;
  -- if another script left it on, "dry" playback isn't — say so at load
  if params.lookup["reverb"]
      and tostring(params:string("reverb")):lower() ~= "off" then
    print("mangler: NOTE — the SYSTEM reverb is ON; it adds reverb mangler"
      .. " does not control (turn it off under PARAMS > REVERB)")
  end

  local function watch(name, fn)
    -- poll.set returns nil when the engine doesn't expose the poll (stale
    -- compiled engine after a deploy without restart) — warn, don't crash
    local p = poll.set(name, fn)
    if p == nil then
      print("mangler: poll '" .. name .. "' missing — old engine? RESTART needed")
      return
    end
    p.time = 1 / FPS
    p:start()
    polls[#polls + 1] = p
  end
  watch("play_phase", function(v) ctx.play_phase = v end)
  watch("rec_phase", function(v) ctx.rec_phase = v end)
  watch("rec_amp", function(v) ctx.rec_amp = v end)
  watch("amp_in_l", function(v) ctx.amp_in[1] = v end)
  watch("amp_in_r", function(v) ctx.amp_in[2] = v end)
  watch("amp_out_l", function(v) ctx.amp_out[1] = v end)
  watch("amp_out_r", function(v) ctx.amp_out[2] = v end)

  redraw_clock = clock.run(function()
    while true do
      clock.sleep(1 / FPS)
      ctx.frame = ctx.frame + 1
      ctx.idle_dim = ctx.frame - ctx.last_input > FPS * 120
      sync_delay_time()    -- tempo-follow the delay (writes only on change)
      Mpages.erosion_tick()  -- count loop passes while the take erodes
      Mpages.load_tick()   -- fill a loaded/restored waveform a batch/frame
      Mpages.update_wave()
      Mpages.update_tape_wave()
      Mmotion.tick()   -- advance + replay the gesture loop
      -- apply a pending morph sweep. AFTER motion, which may have just
      -- replayed a recorded scene_morph_amt move for us to act on.
      Mscenes.tick()
      tick_keys()  -- the K1+K3 erase arc fires AT its threshold
      -- never draw over the system menu; the grid stays live inside it
      if norns.menu.status() == false then redraw() end
      Mgrid.redraw()
    end
  end)

  redraw()
  Mgrid.redraw()
end

function cleanup()
  for _, p in ipairs(polls) do p:stop() end
  if redraw_clock then clock.cancel(redraw_clock) end
  if export_clock then clock.cancel(export_clock) end  -- stop a pending export
  ctx.record_cancel()   -- a recording pass mid-flight: stop the tape with it
  Mpages.cancel_load()  -- close any in-flight waveform read
  ctx.pads_all_off()   -- release any held pad voices before teardown
  Minput.cleanup()
  Mgrid.cleanup()
  Mtape.cleanup()
  Mdeck.cleanup()
  Mmotion.cleanup()    -- gesture looper teardown (no-op; polling needs none)
  Mscenes.cleanup()    -- cancel a queued (quantized) scene recall, same reason
end

-- per-key press bookkeeping for the punch law: the def is resolved at the
-- PRESS and the release routes back to it, so an alt released mid-hold can
-- never hand the release to the wrong action (the grid learned this the hard way)
local key_state = { [2] = {}, [3] = {} }

function enc(n, d)
  ctx.last_input = ctx.frame
  if n == 1 then
    if ctx.alt then
      -- K1+E1 = the everything-knob: morph toward the selected scene from
      -- ANY page (sweeping home to 0 lands exactly where you started)
      if params.lookup["scene_morph_amt"] then
        params:delta("scene_morph_amt", d)
        ctx.flash_id = "scene_morph_amt"
        ctx.flash_until = ctx.frame + math.floor(FPS * 1.2)
      end
    else
      ctx.page = clamp(ctx.page + d, 1, #PAGES)
      -- pop the page name big for a moment: the stations scroll past faster
      -- than the 1x title reads, and finding the page mid-set should not
      -- need squinting (mpages draws the overlay while this is armed)
      ctx.page_flash = ctx.frame + math.floor(FPS * 0.7)
    end
  else
    local id = enc_param(n)
    if id == "@win_move" then
      move_pair("pos_start", "pos_end", d)
    -- the LAYERS encoders address whichever deck is selected, so they resolve
    -- to a param id at turn time rather than being fixed in ENC_MAP
    elseif id == "@lay_level" or id == "@lay_rate" then
      -- delta the REAL param, but keep `id` as the compound target: the footer
      -- matches its flash against the slot's id, and the resolver turns it back
      -- into a value for display. (@win_move works for exactly this reason.)
      local real = ctx.enc_target(id)
      params:delta(real, fine_delta(real, d))
    elseif id == "@lay_move" then
      local dk = ctx.layer_sel()
      move_pair(Mdeck.p(dk, "start"), Mdeck.p(dk, "end"), d)
    elseif id and params.lookup[id] then
      params:delta(id, fine_delta(id, d))
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

function key(n, z)
  ctx.last_input = ctx.frame
  if n == 1 then
    ctx.alt = (z == 1)
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
    if def then
      if def.dryerase then          -- K1+K3: DRY on tap, ERASE at the arc
        ctx.k13_frame, ctx.k13_fired = ctx.frame, false
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
      if def.dryerase then
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
