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
-- recorded. GRAIN / WARP / PV are mangling modes you switch on from STRETCH.
--
-- PLAY IT (the redesign, doc/redesign.md)
--   TAKE    K2, play a phrase, K2 — the window snaps to your take and loops
--           it, dry. the ◇ by the title = "you hear the recording, verbatim"
--   VOICE   K3 cycles PLAY (clean) · GRAIN · WARP · PV; the texture IS the mode
--   SPACE   echoes + reverb, one picture; both start at zero
--   PADS    the take chopped into 8 slices + a euclidean step row
--   SCENE   capture whole sounds; HOLD K2 to peek, tap to keep; ◄ = way back
--
-- THE PUNCH LAW (every key, every page):
--   press = engage NOW · release quickly = it latches · held = a punch,
--   release disengages · already latched = any press turns it off.
--
-- CONTROLS   (3 keys + 3 encoders; every param is MIDI-mappable via PARAMS)
--   E1     select page (nine stations: TAKE VOICE TAPE · FILTER SPACE · MIX
--          · PADS MOTION SCENE — the header dots are the signal map)
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
--          loop / pattern / lane / slot). GLOBAL, every page.
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
-- font), mparticles (grain cloud), mtape (softcut tape), minput (midi/keyboard
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

-- NU-1 (doc/redesign.md §5): nine stations on one signal path —
-- TAKE VOICE TAPE | FILTER SPACE | MIX | PADS MOTION SCENE
local PAGES = {
  "TAKE", "VOICE", "TAPE", "FILTER", "SPACE", "MIX",
  "PADS", "MOTION", "SCENE",
}

local FPS = 15

local tape_arm_phase = 0   -- head position when tape rec was armed
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

-- zoom-aware fine control: window/loop edge params scale their encoder
-- deltas by the current span, so steps shrink as the region tightens —
-- a wide-open window moves fast, a tight loop nudges by milliseconds.
-- (combined with the 0.002 quantum on these specs: ~10ms at the finest.)
local FINE_IDS = { pos_start = "win", pos_end = "win",
                   loop_start = "loop", loop_end = "loop" }

local function fine_delta(id, d)
  local kind = FINE_IDS[id]
  if not kind then return d end
  local span
  if kind == "win" then
    local _, _, s = window_bounds()
    span = s
  else
    span = math.abs(pget("loop_end", 1) - pget("loop_start", 0))
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
  -- display-model flags (mpages paints them, mparticles gates on them)
  wave_any = false,          -- false until something audible lands in the buffer
  twave_any = false,
  -- normalized 0..1 high-water mark of buffer content worth saving (from frame
  -- 0): the take end at rec-stop, a loaded sample's length, or 1 when regen has
  -- filled the whole buffer. write_take bounds the PSET save to it. 0 = empty.
  take_len = 0,
  -- S8 pad bank: 8 slice pads, per-pad type (0 grain / 1 slice), a screen
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
  pad_held = {},             -- voice id -> true while sounding (matches note_off)
  rev_bank = 1,              -- S10: which REVERB param pair E2/E3 edit
  grain_bank = 1,            -- S11: which GRAIN param pair E2/E3 edit
  shimmer_mem = 0.6,         -- S15: last shimmer amount, for the SHMR bloom key
}

local Mfont = include "lib/mfont"
local Mparticles = include "lib/mparticles"
local Mtape = include "lib/mtape"
local Minput = include "lib/minput"
local Mgrid = include "lib/mgrid"
local Mmotion = include "lib/mmotion"
local Mseq = include "lib/mseq"
local Mscenes = include "lib/mscenes"
local Mpages = include "lib/mpages"

ctx.font = Mfont
ctx.particles = Mparticles
ctx.grid = Mgrid
ctx.motion = Mmotion
ctx.seq = Mseq

Mparticles.init(ctx)
Mtape.init(ctx)
Minput.init(ctx)
Mgrid.init(ctx)
Mmotion.init(ctx)
Mseq.init(ctx)
-- S19: sets ctx.scene (the module), ctx.scenes (the 8-slot bank) and the
-- ctx.scene_* / ctx.safe_snapshot_* helpers the KEYS table + grid call
Mscenes.init(ctx)
Mpages.init(ctx)

-- ============================================================================
-- keys: the punch law (NU-1, doc/redesign.md §3)
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
local function throw(label, engage)
  return {
    label = label,
    lit = function() return throw_mem[label] ~= nil end,
    pon = function() throw_mem[label] = engage() end,
    poff = function()
      local m = throw_mem[label]
      if m then for id, v in pairs(m) do params:set(id, v) end end
      throw_mem[label] = nil
    end,
  }
end

-- pulse a momentary param (the footswitch-shaped SCENE binaries: their
-- actions fire on the rising edge, so 1-then-0 is one clean press)
local function pulse(id)
  params:set(id, 1)
  params:set(id, 0)
end

-- TAKE K3: window full <-> back where you had it (a round trip, so a
-- fat-fingered snap is always recoverable)
local snap_mem
local function snap_window()
  local lo, hi = pget("pos_start", 0), pget("pos_end", 1)
  if hi < lo then lo, hi = hi, lo end
  if hi - lo > 0.98 then
    if snap_mem then
      params:set("pos_start", snap_mem[1])
      params:set("pos_end", snap_mem[2])
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
      Mtape.clear_buffer()
      Mpages.clear_twave()
      params:set("tape_freeze", 0)
      params:set("loop_start", 0)
      params:set("loop_end", 1)
    end,
  },
  FILTER = {
    -- OPEN as a throw: hold = a sweep that returns by itself, tap = park
    -- it open, tap again = back to the carved tone
    k2 = throw("OPEN", function()
      local mem = { cutoff = pget("cutoff", 20000),
        resonance = pget("resonance", 0) }
      local ft = pget("filt_type", 1)
      params:set("cutoff", ft == 2 and 20 or (ft == 3 and 1000 or 20000))
      params:set("resonance", 0)
      return mem
    end),
    k3 = { label = "TYPE",
      act = function()
        params:set("filt_type", (pget("filt_type", 1) % 3) + 1)
      end },
  },
  SPACE = {
    k2 = throw("INF", function()   -- dub grab: pin the delay loop
      local mem = { delay_fb = pget("delay_fb", 0) }
      params:set("delay_fb", 0.95)
      return mem
    end),
    k3 = throw("BLOOM", function() -- shimmer surge
      local mem = { shimmer = pget("shimmer", 0) }
      params:set("shimmer", ctx.shimmer_mem or 0.6)
      return mem
    end),
  },
  MIX = {
    -- ENG and TAPE are MUTUALLY EXCLUSIVE throws of the same `mix`: engaging one
    -- restores + un-latches the other FIRST, so the value cached is the true home
    -- (not one the sibling already displaced) and both pills can't light at once.
    k2 = throw("ENG", function()   -- crossfade stab to the engine deck
      if throw_mem["TAPE"] then params:set("mix", throw_mem["TAPE"].mix); throw_mem["TAPE"] = nil end
      local mem = { mix = pget("mix", 0.5) }
      params:set("mix", 0)
      return mem
    end),
    k3 = throw("TAPE", function()
      if throw_mem["ENG"] then params:set("mix", throw_mem["ENG"].mix); throw_mem["ENG"] = nil end
      local mem = { mix = pget("mix", 0.5) }
      params:set("mix", 1)
      return mem
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
    k3 = pk("RUN", "seq_play"),
    erase = function() Mseq.clear() end,
  },
  MOTION = {
    k2 = pk("REC", "motion_rec"),
    k3 = pk("PLAY", "motion_play"),
    erase = function() ctx.motion.clear_lane() end,
  },
  SCENE = {
    -- NU-3: RCL under the punch law — hold = PEEK (borrow the scene via the
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
        if sel >= 1 then
          -- the scene landed: it IS the new LIVE, so the rail goes home
          -- without sweeping (recall invalidated the morph's "from")
          params:set("scene_morph_amt", 0)
        end
      end,
      poff = function()   -- punch release: it was borrowed — sweep home
        ctx.peek_on = false
        ctx.peek_back = true
      end },
    k3 = { label = "CAP", act = function() pulse("scene_capture") end },
    erase = function() pulse("scene_clear") end,
  },
}

-- the global alt pair — identical on every page
local ALT_STOP = pk("STOP", "stop_all")
local ALT_DRY = { label = "DRY", dryerase = true }

local function key_def(n)
  if ctx.alt then
    return n == 2 and ALT_STOP or ALT_DRY
  end
  local defs = KEYS[PAGES[ctx.page]]
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
  TAPE   = { "tape_rate", "tape_pre", "loop_end", "@loop_move" },
  FILTER = { "cutoff", "drive", "resonance", "dry_wet" },
  SPACE  = { "delay_mix", "delay_time", "rev_mix", "rev_decay" },
  MIX    = { "mix", "input_level", "out_level", "monitor_level" },
  PADS   = { "seq_slice", "seq_len", "seq_euclid", "pad_pitch" },
  MOTION = { "motion_lane", nil, "motion_depth", nil },
  SCENE  = { "scene_slot", "scene_recall_mode", "scene_morph_amt", nil },
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
-- with the same span-scaled fine step the edges get
local function move_pair(lo_id, hi_id, d)
  local lo, hi = pget(lo_id, 0), pget(hi_id, 1)
  if hi < lo then lo, hi = hi, lo end
  local p = params:lookup_param(lo_id)
  local q = (p and p.controlspec and p.controlspec.quantum) or 0.01
  local nlo = clamp(lo + fine_delta(lo_id, d) * q, 0, 1 - (hi - lo))
  params:set(lo_id, nlo)
  params:set(hi_id, nlo + (hi - lo))
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
-- S8 polyphonic pad voices
-- ============================================================================
-- a pad's slice point: the centre of the i-th eighth OF THE TAKE — i.e. of
-- the current window, not of the 60s buffer. this is the one definition of
-- "slice i" in the instrument: the PADS audition, MIDI/grid note pads, and
-- the sequencer (mseq.fire) all resolve through here, so pad 3 and seq slice
-- 3 are always the same audio.
-- it was buffer-relative ((i+0.5)/8) until now, which meant a normal take —
-- record a phrase, the rec action snaps the window to it — left 7 of the 8
-- pads pointing at silence out in the empty buffer. mseq hit exactly that on
-- device in S18 and worked around it locally; this is that fix, shared.
-- rate stays fixed at 1 (per-pad rate is a later knob). type is per-pad.
local function pad_pos(i)
  local lo, _, span = window_bounds()
  return lo + (i + 0.5) / ctx.pad_n * span
end
ctx.pad_pos = pad_pos

-- spawn/release a voice for pad `i` under a stable `id` (so note_off matches
-- the note_on that started it). z=1 press, z=0 release.
function ctx.pad_trigger(id, i, z)
  if z == 1 then
    if ctx.pad_held[id] and engine.note_off then engine.note_off(id) end
    if engine.note_on then
      -- per-pad SOUND-LOCK: this pad's own pitch (semitones -> rate) + voice, at
      -- the pad voice level (chord-safe default, unlike the loud sequencer)
      engine.note_on(id, pad_pos(i), 2 ^ ((ctx.pad_pitch[i] or 0) / 12),
        ctx.pad_type[i] or 0, pget("pad_level", 0.3))
    end
    ctx.pad_held[id] = i    -- store the pad index (0 is truthy) for the display
  elseif ctx.pad_held[id] then
    if engine.note_off then engine.note_off(id) end
    ctx.pad_held[id] = nil
  end
end

-- MIDI/grid note routing: in pad mode a note plays pad (note mod 8) as a
-- polyphonic voice (note_off on release); otherwise it retunes the mono
-- drone `pitch` exactly as before. `pitch` is the chromatic rate the caller
-- already computed for the drone path.
function ctx.route_note(id, pitch, pad_idx, z)
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

-- S21 — the two things a sampler needs and this didn't have: a way to DELETE
-- the recording, and a source other than the live input.
-- the engine's 60s buffer is the thing everything slices (window, drone, pads,
-- sequencer), and until now the only way to change it was to record over it.
-- (the TAPE deck's own CLR is on the TAPE page — that's the softcut loop, a
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
  Mpages.clear_wave()
  ctx.take_len = 0       -- empty: a subsequent save writes nothing (and deletes)
  params:set("pos_start", 0)
  params:set("pos_end", 1)
  print("mangler: recording cleared")
end

-- load any wav as the sample (PARAMS > rec > load sample). it lands in the SAME
-- buffer a take does, so the window, drone, pads and sequencer all work on it
-- identically — there is no "loaded sample" mode, it's just the sample.
-- the window snaps to the file's length, and the display is read from the FILE
-- (lua can't see the SC buffer — see Mpages.load_wave).
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
  engine.read_file(path)
  ctx.wave_any = true    -- audio is in the buffer now, drawable or not — never
                         -- lie "EMPTY" over an audible sample (the S21 fix, now
                         -- also honoured for formats the preview can't draw)
  local dur = Mpages.load_wave(path, 60)
  -- the loaded length bounds a PSET save; unknown length (no preview) -> full
  ctx.take_len = dur and clamp(dur / 60, 0.002, 1) or 1
  if dur then
    params:set("pos_start", 0)
    params:set("pos_end", clamp(dur / 60, 0.002, 1))
    print(string.format("mangler: loaded %s (%.1fs) — window snapped to it",
      path, dur))
  else
    -- audible, but no picture for this format (8-bit / aiff / float-extensible):
    -- leave the window for the performer to set rather than draw a lie
    print("mangler: loaded " .. path
      .. " (playing; no waveform preview for this format)")
  end
end

-- S22 Phase A: the live take rides the PSET as a private L/R pair beside the
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
  local total = 48000 * 60
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
  -- pset's own params (window included) still load.
  if not util.file_exists(stem .. "_L.wav") then return end
  engine.read_take(stem)
  -- repaint from the file or the restored take is INVISIBLE (the "audio you can
  -- hear over EMPTY - K2 REC" bug S21 fixed for loaded samples). do NOT snap the
  -- window — params:read already restored the saved pos_start/pos_end.
  local dur = Mpages.load_wave(stem .. "_L.wav", 60)
  ctx.wave_any = true   -- audio is in the buffer whether or not we could draw it
  ctx.take_len = dur and clamp(dur / 60, 0.002, 1) or 1  -- bounds a re-save
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
  local t = { v = 1, type = {}, pitch = {} }
  for i = 0, 7 do t.type[i] = ctx.pad_type[i] or 0; t.pitch[i] = ctx.pad_pitch[i] or 0 end
  tab.save(t, padlock_path(number))
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
  ctx.pad_edit_sync()   -- editor params -> the restored cursor pad
end

function ctx.padlock_pset_delete(number)
  os.remove(padlock_path(number))
end

-- S22 Phase B: browsable stereo EXPORT. write_take dumps the DRY take to a temp
-- L/R pair; we wait for the async /b_write to finish (sizes stop growing), then
-- interleave into a named stereo wav in dust/audio that reloads via `load
-- sample` (zero new load code). Lua-only — fingerprint unchanged.
local export_clock
local function filesize(p)
  local f = io.open(p, "rb"); if not f then return nil end
  local s = f:seek("end"); f:close(); return s
end
local function next_export_name()
  for n = 1, 999 do
    local name = "mangler-" .. string.format("%03d", n) .. ".wav"
    if not util.file_exists(_path.audio .. name) then return name end
  end
  return "mangler-000.wav"
end

function ctx.export_take(name)
  if not engine.write_take then
    print("mangler: engine has no write_take — SYSTEM > RESTART"); return
  end
  if not ctx.wave_any then print("mangler: nothing to export"); return end
  name = name or next_export_name()
  local out = _path.audio .. name
  local tmp = norns.state.data .. "mexport-tmp"
  engine.write_take(tmp, take_frames())   -- async dump to tmp_L.wav / tmp_R.wav
  if export_clock then clock.cancel(export_clock) end
  export_clock = clock.run(function()
    local pL, pR, stable = -1, -1, 0
    for _ = 1, 60 do                  -- wait up to ~3s for the async write
      clock.sleep(0.05)
      local sL, sR = filesize(tmp .. "_L.wav"), filesize(tmp .. "_R.wav")
      if sL and sR and sL > 44 and sL == pL and sR == pR then
        stable = stable + 1; if stable >= 2 then break end
      else stable = 0 end
      pL, pR = sL, sR
    end
    local ok = Mpages.interleave_wav(tmp .. "_L.wav", tmp .. "_R.wav", out)
    os.remove(tmp .. "_L.wav"); os.remove(tmp .. "_R.wav")
    print(ok and ("mangler: exported " .. out) or "mangler: export FAILED")
    export_clock = nil
  end)
end

-- DRY throw (MIX K1+K3, grid (7,2)): playback becomes the un-effected
-- sample — every "on top" color to zero (delay, reverb, shimmer, drive,
-- clouds feedback — the one wash the REVERB page can't kill) and the
-- filter thrown open (type-aware, same law as FILTER's OPEN key). the
-- take itself is always recorded clean; this clears the playback path.
function ctx.fx_dry()
  params:set("delay_mix", 0)
  params:set("rev_mix", 0)
  params:set("shimmer", 0)
  params:set("drive", 0)
  params:set("clouds_fb", 0)
  local ft = params:get("filt_type")
  params:set("cutoff", ft == 2 and 20 or (ft == 3 and 1000 or 20000))
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
  params:set_action("out_level", Mtape.update_mix)
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
  end)

  params:add_group("grp_rec", "take - record", 10)
  add_eng_binary("rec", "record")
  -- when capture stops, snap the window to the take just recorded so playback
  -- immediately loops what you played — not a 60s window of mostly silence
  params:set_action("rec", function(v)
    if engine.rec then engine.rec(v) end
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
      -- the take now bounds what a PSET save writes (write head runs 0..pos_end).
      -- regen fills the whole buffer, so it forces a full save.
      ctx.take_len = pget("regen", 0) > 0 and 1 or pget("pos_end", 1)
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
  -- S17 self-resampling: continuous feedback of the processed OUTPUT back into
  -- the record buffer (Basinski-style regenerative decay). 0 = off (a fresh
  -- take stays dry). manual rec + freeze suspend it; engine-side it's a bounded
  -- convex crossfade so it can't run away.
  add_eng_control("regen", "regen (self-resample)",
    controlspec.new(0, 1, "lin", 0, 0.0, ""))
  params:set_action("regen", function(v)
    if engine.regen then engine.regen(v) end
    -- regen's record head traverses the WHOLE buffer, so once it runs the take
    -- can be anywhere: force a full-buffer PSET save (sticky until the next
    -- fresh rec / load / clear resets take_len), never truncate its decay tail.
    if v > 0 then ctx.take_len = 1 end
  end)
  -- S21: delete the take (REC K1+K3, mirroring TAPE's CLR) and load one off the
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
  -- S22 Phase B: export the take as a browsable stereo wav in dust/audio.
  -- momentary so a footswitch/grid can fire it; press edge only.
  params:add_binary("export_take", "export take (wav)", "momentary", 0)
  params:set_action("export_take", function(v)
    if v == 1 then ctx.export_take() end
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
  -- S7 granular character: per-grain size jitter + detune spread (both
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

  -- S11: MiClouds granular controls (GRAIN mode uses the Clouds voice when
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
  -- S14: PLAY (clean straight loop = the exact recorded sample) is the
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

  params:add_group("grp_tape", "tape", 8)
  params:add_binary("tape_rec", "tape record", "toggle", 0)
  -- mirror the SC side's workflow: arming with no overdub opens the loop to
  -- the full tape for a fresh take; stopping snaps the loop around the take
  -- and jumps the head to its start, so it plays back tight immediately
  params:set_action("tape_rec", function(v)
    if v == 1 then
      if pget("tape_pre", 0) == 0
          and (pget("loop_end", 1) - pget("loop_start", 0)) < 0.99 then
        params:set("loop_start", 0)
        params:set("loop_end", 1)
      end
      tape_arm_phase = ctx.tape_phase
    elseif ctx.tape_phase > tape_arm_phase + 0.005 then
      params:set("loop_start", tape_arm_phase)
      params:set("loop_end", ctx.tape_phase)
      Mtape.jump_to(tape_arm_phase)
    elseif ctx.tape_phase < tape_arm_phase - 0.005 then
      -- head wrapped past the tape end mid-take: softcut loops can't cross
      -- the seam, so keep the full tape rather than snapping a wrong slice
      params:set("loop_start", 0)
      params:set("loop_end", 1)
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

  params:add_group("grp_filter", "filter", 4)
  params:add_option("filt_type", "filter type", { "LP", "HP", "BP" }, 1)
  params:set_action("filt_type", function(v)
    if engine.filt_type then engine.filt_type(v - 1) end
  end)
  add_eng_control("cutoff", "cutoff",
    controlspec.new(20, 20000, "exp", 0, 20000, "hz"))
  add_eng_control("resonance", "resonance",
    controlspec.new(0, 1, "lin", 0, 0.0, ""))
  -- post-filter tanh saturation with makeup (S5): louder AND dirtier up
  add_eng_control("drive", "drive",
    controlspec.new(0, 1, "lin", 0, 0.0, ""))

  params:add_group("grp_delay", "space - delay", 3)
  add_eng_control("delay_time", "delay time",
    controlspec.new(0.01, 1, "exp", 0, 0.3, "s"))
  add_eng_control("delay_fb", "feedback",
    controlspec.new(0, 0.95, "lin", 0, 0.3, ""))
  -- FX SEND response curve: the engine crossfades the wet with an equal-power
  -- .sqrt (Engine_Mangler.sc), so a raw 3% knob already reads ~17% wet ("way too
  -- blunt"). `square` makes the effective wet gain LINEAR in the knob — a
  -- progressive fade (dry stays ~full at the bottom, full wet at 1). same reverb.
  add_eng_control("delay_mix", "delay mix",
    controlspec.new(0, 1, "lin", 0, 0.0, ""), square)

  -- S10: the reverb is JPverb's FULL attribute set (guarded → FreeVerb
  -- fallback in the engine). every knob maps to a real JPverb arg — nothing
  -- hardcoded. edited on the REVERB page in banks (K2 pages through them).
  params:add_group("grp_reverb", "space - reverb", 15)
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
  -- S15 shimmer: pitch-shifted reverb feedback (climbs in octaves into a pad)
  add_eng_control("shimmer", "shimmer",
    controlspec.new(0, 1, "lin", 0, 0.0, ""))
  add_eng_control("shimmer_pitch", "shimmer pitch",
    controlspec.new(-12, 24, "lin", 1, 12, "st"))
  add_eng_control("shimmer_tone", "shimmer tone",
    controlspec.new(500, 12000, "exp", 0, 4500, "hz"))

  -- S8 polyphonic voices: the per-note/per-pad layer that coexists with the
  -- drone. `pad_input` reroutes MIDI + grid note-pads to voices instead of
  -- the mono drone pitch (default OFF = existing behavior). voices = poly
  -- cap (oldest-steal in the engine), voice_atk/voice_rel shape each note.
  params:add_group("grp_voice", "pads - voices", 7)
  params:add_binary("pad_input", "pad input", "toggle", 0)
  params:set_action("pad_input", function(v)
    if v == 0 then ctx.pads_all_off() end   -- don't strand voices on switch
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
  -- pad voice LEVEL (per-note amp): the chord-safe default (0.3, the old S9
  -- level that stops poly stacks slamming the master limiter). read at note-on.
  params:add_control("pad_level", "pad level",
    controlspec.new(0, 1, "lin", 0, 0.3, ""))

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

  -- S16 gesture looper: records the param stream (MOTION_IDS) and replays it
  -- (see lib/mmotion). rec/play are binaries so a footswitch can punch overdubs
  -- and start/stop the loop; lane/depth drive the MOTION page. all Lua-only —
  -- no engine command, so the fingerprint is unchanged.
  params:add_group("grp_motion", "motion", 4)
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

  -- S18 step sequencer: a clock-synced Euclidean sequencer that triggers the
  -- PADS slice one-shots (see lib/mseq). all Lua-only (drives engine.note_one_
  -- shot) — no engine command, so the fingerprint is unchanged. seq_play is a
  -- binary (MIDI-map it to a footswitch); seq_euclid/seq_len regen the pattern.
  params:add_group("grp_seq", "pads - sequencer", 6)
  params:add_binary("seq_play", "seq play", "toggle", 0)
  params:set_action("seq_play", function(v) ctx.seq.set_playing(v == 1) end)
  params:add_option("seq_div", "seq division", Mseq.DIV_LABELS, 2)
  params:add_number("seq_euclid", "seq euclid hits", 0, 16, 0)
  params:set_action("seq_euclid", function() ctx.seq.regen() end)
  params:add_number("seq_len", "seq length", 1, 16, 16)
  params:set_action("seq_len", function() ctx.seq.regen() end)
  params:add_number("seq_slice", "seq slice", 0, 7, 0)
  -- NU-1 glue until the NU-3 `slice` merge: the sequencer's target and the
  -- PADS cursor are ONE selection (browsing slices retargets the sequence)
  params:set_action("seq_slice", function(v)
    ctx.pad_cursor = v
    ctx.pad_edit_sync()          -- the sound-lock editors follow the selected pad
  end)
  -- sequencer voice LEVEL (per-note amp): LOUD by default so the rhythm cuts
  -- over the drone (the "makes no sound" report — it's mono, so no chord-clip).
  params:add_control("seq_level", "seq level",
    controlspec.new(0, 1, "lin", 0, 0.85, ""))

  -- S19 scenes / morph / safe state (see lib/mscenes). all Lua-only — no
  -- engine command, so the fingerprint is unchanged. the ACTIONS here are
  -- momentary binaries rather than triggers: a trigger can't be MIDI-learned,
  -- and the whole point is a footswitch that captures, recalls, rescues or
  -- throws. every action fires on the press edge (v == 1) only — a stray 0
  -- from params:bang() or a pset read must never do anything.
  params:add_group("grp_scene", "scenes", 9)
  -- ONE selector, three jobs: the slot K2 recalls, K3 captures into, and the
  -- morph aims at. (there used to be two more — `morph A`/`morph B` — on the
  -- alt layer, where you couldn't see them. see mscenes' morph_from.)
  -- NU-3: slot 0 is the ◄ cell — the way back (mscenes branches on it)
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
  -- actions on the selected slot (also the SCENE page's K2/K3)
  params:add_binary("scene_capture", "capture to slot", "momentary", 0)
  params:set_action("scene_capture", function(v)
    if v == 1 then Mscenes.capture() end
  end)
  params:add_binary("scene_recall", "recall slot", "momentary", 0)
  params:set_action("scene_recall", function(v)
    if v == 1 then Mscenes.recall() end
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

  -- PSETs persist the audio too: PARAMS > PSET > SAVE/LOAD/DELETE round-trip
  -- the softcut buffers (mtape) AND, since S22, the granular engine's record
  -- buffer — the live take, as an L/R wav pair beside the pset (ctx.take_pset_*
  -- → engine write_take/read_take). the hooks are SHARED: each module/helper
  -- does its own half (mtape the tape audio, mscenes the scene bank + safe
  -- snapshot as a lua table, the take helpers the engine buffer).
  params.action_write = function(filename, name, number)
    Mtape.pset_write(number)
    Mscenes.pset_write(number)
    ctx.take_pset_write(number)   -- S22: the engine take, as an L/R pair
    ctx.padlock_pset_write(number)  -- per-pad sound-locks
  end
  params.action_read = function(filename, silent, number)
    Mtape.pset_read(number)
    Mscenes.pset_read(number)
    ctx.take_pset_read(number)
    ctx.padlock_pset_read(number)
  end
  params.action_delete = function(filename, name, number)
    Mtape.pset_delete(number)
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
      Mpages.load_tick()   -- #15: fill a loaded/restored waveform a batch/frame
      Mpages.update_wave()
      Mpages.update_tape_wave()
      Mparticles.update()
      Mmotion.tick()   -- S16: advance + replay the gesture loop
      -- S19: apply a pending morph sweep. AFTER motion, which may have just
      -- replayed a recorded scene_morph_amt move for us to act on.
      Mscenes.tick()
      tick_keys()  -- NU-1: the K1+K3 erase arc fires AT its threshold
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
  if export_clock then clock.cancel(export_clock) end  -- S22B: stop a pending export
  Mpages.cancel_load()  -- #15: close any in-flight waveform read
  ctx.pads_all_off()   -- release any held pad voices before teardown
  Minput.cleanup()
  Mgrid.cleanup()
  Mtape.cleanup()
  Mmotion.cleanup()    -- gesture looper teardown (no-op; polling needs none)
  Mseq.cleanup()       -- cancel the sequencer clock (norns clock hygiene)
  Mscenes.cleanup()    -- cancel a queued (quantized) scene recall, same reason
end

-- per-key press bookkeeping for the punch law: the def is resolved at the
-- PRESS and the release routes back to it, so an alt released mid-hold can
-- never hand the release to the wrong action (the grid learned this in S19)
local key_state = { [2] = {}, [3] = {} }

function enc(n, d)
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
    end
  else
    local id = enc_param(n)
    if id == "@win_move" then
      move_pair("pos_start", "pos_end", d)
    elseif id == "@loop_move" then
      move_pair("loop_start", "loop_end", d)
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
  if n == 1 then
    ctx.alt = (z == 1)
    -- releasing K1 ABORTS a pending K1+K3 erase. the arc is gated on K1, so
    -- letting go reads as "abort" — honour that instead of firing anyway. (you
    -- can't navigate stations while K1 is held — K1+E1 is the morph — so the
    -- erase can also never retarget onto a different station's material.)
    if z == 0 and ctx.k13_frame and not ctx.k13_fired then
      ctx.k13_frame = nil
    end
    redraw()
    return
  end
  local st = key_state[n]
  ctx.held[n] = (z == 1)
  if z == 1 then
    local def = key_def(n)
    st.def, st.frame, st.engaged = def, ctx.frame, false
    if def then
      if def.dryerase then          -- K1+K3: DRY on tap, ERASE at the arc
        ctx.k13_frame, ctx.k13_fired = ctx.frame, false
      elseif def.pon then           -- punchable
        if def.lit and def.lit() then
          def.poff()                -- already latched: press = off
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
      elseif def.tap and ctx.frame - st.frame < TAP_FRAMES then
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
