-- mmotion: the gesture looper — a fourth driver for the params.
--
-- keys/encoders/MIDI are three drivers of the single source of truth (the
-- params). this module adds a fourth that RECORDS the param stream and
-- REPLAYS it: a modulation loop pedal for a 3-knob instrument. each param you
-- move becomes its own automation lane, overdubbed independently. no engine
-- change — it just re-issues params:set, so the fingerprint is untouched and
-- it can never brick loading.
--
-- data model: one loop, per-param lanes.
--   loop_len   loop length in FRAMES (the 15fps redraw grid is the timeline;
--              no new clock). 0 until the first take sets it (free length).
--   lanes[id]  { f={}, v={}, n, cur, last_fire } — flat, pre-grown arrays of
--              {frame-offset, value} events over [0, loop_len). sparse: only
--              params you actually moved exist, so they layer independently.
--   punch-in replace: the first time a param moves in a record pass its lane
--   is cleared, then events append — re-recording a param overwrites ONLY
--   that lane.
--
-- CAPTURE by POLLING (not by intercepting calls). every frame while armed,
-- tick() reads the current value of each recordable param and, if it changed
-- since last frame, appends an event. this catches EVERY driver — encoder
-- (params:delta), key throw, MIDI CC, typing keyboard — because it only reads
-- values; it never depends on HOW they changed. (an earlier version wrapped
-- params.set/params.delta, but that missed the encoder delta path on the real
-- norns paramset — nothing recorded. polling is robust to all of it.)
--
-- no runaway: when playback fires params:set for an owned lane it immediately
-- writes that value into last_val, so the next poll doesn't see the playback
-- change as a live move — only genuinely-live moves enter a lane.

local min, floor = math.min, math.floor

local C            -- shared ctx, bound at init
local pget, clamp, FPS
local MAX_LEN      -- cap the loop at 60s so a forgotten arm can't run away
local MIN_LEN      -- floor on a SETTABLE loop (0.5s) so a tiny motion_len can't
                   -- collapse the loop to a single frame

-- the params whose motion is recordable — the performance / mangle knobs and
-- toggles, in a stable order (first-touch lane order follows it). NOT here:
-- system levels, keys_* config, pad_input, the transports (rec/tape_rec/
-- stop_all), and motion_* itself. add new mangle params here to automate them.
local MOTION_IDS = {
  "mix",
  "pos_start", "pos_end", "scan", "pos_jitter",
  "size", "density", "pitch", "spread", "pan", "grain_level",
  "grain_jitter", "grain_pitch_spread",
  "clouds_pos", "clouds_tex", "clouds_fb", "clouds_lofi", "clouds_mode",
  "mode", "warp_window", "warp_rand", "pv_freeze", "freeze",
  "tape_rate", "loop_start", "loop_end", "tape_pre", "tape_freeze",
  "tape_reverse",
  "cutoff", "resonance", "drive", "filt_type", "dry_wet",
  "erode", "wear",
  "delay_time", "delay_fb", "delay_mix", "delay_sync",
  "rev_decay", "rev_damp", "rev_size", "rev_early", "rev_moddepth",
  "rev_modfreq", "rev_low", "rev_mid", "rev_high", "rev_lowcut",
  "rev_highcut", "rev_mix", "shimmer", "shimmer_pitch", "shimmer_tone",
  "voice_atk", "voice_rel", "pad_level",
  "cut_source",
  -- the scene morph knob. recording THIS records a whole-instrument
  -- sweep in ONE lane — mscenes re-derives every param from it on replay
  -- (and tells us it did, via M.account, so the sweep never punches forty
  -- lanes of its own). appended, so existing lane order is unchanged.
  "scene_morph_amt",
}

local M = {
  loop_len = 0,     -- frames; 0 = empty (no take yet). the PLAYBACK length —
                    -- motion_len may retime it away from the recorded length.
  rec_len = 0,      -- the natural recorded length = the EVENT timebase. events
                    -- are stored against this; playback reads them through a
                    -- rec_len/loop_len ratio, so retiming is lossless.
  playhead = 0,     -- current loop frame while playing (0 .. loop_len)
  lane_ids = {},    -- ordered active param ids (first-touch order)
  lanes = {},       -- lanes[id] = { f, v, n, cur, last_fire }
}

-- purely-internal state (not read by the page)
local rec_start_frame = 0       -- ctx.frame when the first pass armed
local touched_this_pass = {}    -- ids already punched-in this pass
local last_val = {}             -- last accounted value per param (for the poll)

-- ===========================================================================
-- lane bookkeeping
-- ===========================================================================

local function reset_cursors()
  local ids = M.lane_ids
  for i = 1, #ids do M.lanes[ids[i]].cur = 1 end
end

-- clear every lane (structures only — param VALUES are left untouched)
local function wipe()
  local ids = M.lane_ids
  for i = #ids, 1, -1 do
    M.lanes[ids[i]] = nil
    ids[i] = nil
  end
  M.loop_len = 0
  M.rec_len = 0
  M.playhead = 0
end

-- motion_len (seconds) -> a settable playback length in frames, or nil for
-- AUTO (0 = use the natural recorded length). clamped to [0.5s, 60s].
local function len_frames(secs)
  if not secs or secs <= 0 then return nil end
  return clamp(floor(secs * FPS + 0.5), MIN_LEN, MAX_LEN)
end

-- map a playback frame (loop_len timebase) to the event timebase (rec_len).
-- IDENTITY when the loop isn't retimed, so default playback is bit-for-bit
-- the pre-A5 behavior (loop_len == rec_len -> src == playhead, integer).
local function src_of(ph)
  if M.loop_len == M.rec_len then return ph end
  return floor(ph * M.rec_len / M.loop_len)
end

-- baseline: remember every recordable param's current value, so the poll only
-- records CHANGES made after this point (called on arm).
local function snapshot()
  for i = 1, #MOTION_IDS do
    local id = MOTION_IDS[i]
    if params.lookup[id] then last_val[id] = params:get(id) end
  end
end

-- ===========================================================================
-- capture — poll live param moves and append events at `offset`
-- ===========================================================================

local function capture_poll(offset)
  for i = 1, #MOTION_IDS do
    local id = MOTION_IDS[i]
    if params.lookup[id] then
      local v = params:get(id)
      local lv = last_val[id]
      if lv ~= nil and v ~= lv then
        local L = M.lanes[id]
        -- punch-in replace: first move this pass clears (or creates) the lane
        if not touched_this_pass[id] then
          if not L then
            L = { f = {}, v = {}, n = 0, cur = 1, last_fire = -1 }
            M.lanes[id] = L
            M.lane_ids[#M.lane_ids + 1] = id
          else
            L.n = 0
          end
          touched_this_pass[id] = true
        end
        L.n = L.n + 1
        L.f[L.n] = offset
        L.v[L.n] = v
      end
      last_val[id] = v
    end
  end
end

-- another driver (a scene recall or a morph sweep) is about to move `id` itself: fold the
-- resulting value into our baseline so the next poll doesn't read it as a
-- live hand on a knob. this is the same trick playback uses on its own
-- writes — a scene recall or a morph sweep is a JUMP, not a gesture, and
-- must never punch itself into a lane. no-op for ids we don't track.
function M.account(id)
  if last_val[id] ~= nil then last_val[id] = params:get(id) end
end

-- ===========================================================================
-- transport — driven by the motion_rec / motion_play param actions
-- ===========================================================================

function M.set_armed(on)
  if on then
    touched_this_pass = {}
    snapshot()                                  -- only moves AFTER arming record
    if M.loop_len == 0 then
      rec_start_frame = C.frame                 -- first pass: start the clock
    else
      -- overdub: replay the existing loop from the top while we punch in
      M.playhead = 0
      reset_cursors()
      if pget("motion_play", 0) ~= 1 then params:set("motion_play", 1) end
    end
  else
    if M.loop_len == 0 then
      -- finalize the first pass: its natural length is the EVENT timebase;
      -- motion_len (>0) sets the PLAYBACK length, 0 = AUTO (= natural).
      local elapsed = C.frame - rec_start_frame
      if #M.lane_ids > 0 and elapsed >= 2 then
        M.rec_len = min(elapsed, MAX_LEN) + 1   -- +1 so the last frame plays
        M.loop_len = len_frames(pget("motion_len", 0)) or M.rec_len
        M.playhead = 0
        reset_cursors()
        if pget("motion_play", 0) ~= 1 then params:set("motion_play", 1) end
      else
        wipe()                                  -- nothing captured: stay empty
        if pget("motion_play", 0) == 1 then params:set("motion_play", 0) end
      end
    else
      touched_this_pass = {}                     -- overdub done
    end
  end
end

function M.set_playing(on)
  if on and M.loop_len > 0 then
    M.playhead = 0
    reset_cursors()
  end
end

-- motion_len (K1+E2 on the MOTION page) retimes the loop's PLAYBACK length in
-- seconds; 0 = AUTO (the natural recorded length). retiming changes the loop's
-- SPEED, not the stored gesture — events live in the rec_len timebase and are
-- read through src_of(), so you can dial the length up and down losslessly.
-- resettles from the top so the new length takes hold cleanly. no-op until a
-- loop exists (before that the finalize branch reads motion_len).
function M.set_len(secs)
  if M.rec_len == 0 then return end
  M.loop_len = len_frames(secs) or M.rec_len
  M.playhead = 0
  reset_cursors()
end

-- ===========================================================================
-- clear (CLR-L / CLR on the MOTION page)
-- ===========================================================================

-- clear the selected lane (E2 picks it; 0 = the newest). params keep their
-- current values — clearing removes the automation, not the sound.
function M.clear_lane()
  local n = #M.lane_ids
  if n == 0 then return end
  local sel = clamp(floor(pget("motion_lane", 0) + 0.5), 0, n)
  if sel == 0 then sel = n end
  local id = M.lane_ids[sel]
  if not id then return end
  M.lanes[id] = nil
  table.remove(M.lane_ids, sel)
  if #M.lane_ids == 0 then
    M.loop_len = 0
    M.playhead = 0
    if pget("motion_play", 0) == 1 then params:set("motion_play", 0) end
  else
    reset_cursors()
  end
end

-- wipe the whole loop back to empty
function M.clear_all()
  if pget("motion_rec", 0) == 1 then params:set("motion_rec", 0) end
  wipe()
  if pget("motion_play", 0) == 1 then params:set("motion_play", 0) end
end

-- ===========================================================================
-- tick — one per redraw frame: capture live moves, then replay the loop
-- ===========================================================================

function M.tick()
  local armed = pget("motion_rec", 0) == 1
  -- 1) capture: poll for live param moves (before playback overwrites them)
  if armed then
    if M.loop_len == 0 then
      local offset = C.frame - rec_start_frame
      if offset >= 0 and offset <= MAX_LEN then capture_poll(offset) end
    else
      -- overdub: punch in at the loop position, mapped to the EVENT timebase so
      -- new events line up with the old ones even when the loop is retimed
      capture_poll(src_of(M.playhead))
    end
  end
  -- 2) playback: advance the playhead and fire each lane's due events
  if pget("motion_play", 0) == 1 and M.loop_len > 0 then
    M.playhead = M.playhead + 1
    if M.playhead >= M.loop_len then
      M.playhead = 0
      reset_cursors()
      -- an overdub that ran a full loop auto-disarms (keeps events sorted)
      if armed then params:set("motion_rec", 0) end
    end
    local src = src_of(M.playhead)       -- read the lanes in their own timebase
    -- motion_depth (0..1) scales continuous lanes toward their first value —
    -- a global "amount" for the whole loop. discrete params pass through.
    local depth = pget("motion_depth", 1)
    local blend = depth < 0.999
    local ids = M.lane_ids
    for i = 1, #ids do
      local id = ids[i]
      local L = M.lanes[id]
      local n = L.n
      local cur = L.cur
      while cur <= n and L.f[cur] <= src do
        local v = L.v[cur]
        if blend then
          local p = params:lookup_param(id)
          if p and p.controlspec then
            local base = L.v[1]
            v = base + depth * (v - base)
          end
        end
        params:set(id, v)
        -- account for our own change so the poll skips it. read the value BACK
        -- rather than storing what we asked for: a Control stores
        -- map(unmap(v)), which differs from v in the last bit for a large share
        -- of values on an exponential spec. storing v left the next poll seeing
        -- a mismatch, reading it as a live hand on the knob, and punch-in
        -- REPLACING the very lane an overdub was meant to extend. M.account
        -- re-reads for the same reason.
        last_val[id] = params:get(id)
        L.last_fire = M.playhead
        cur = cur + 1
      end
      L.cur = cur
    end
  end
end

-- ===========================================================================
-- lifecycle
-- ===========================================================================

function M.init(ctx)
  C = ctx
  pget, clamp, FPS = ctx.pget, ctx.clamp, ctx.FPS
  MAX_LEN = 60 * FPS
  MIN_LEN = math.max(4, floor(FPS * 0.5))     -- a settable loop is >= 0.5s
end

function M.cleanup() end   -- nothing to tear down (no wrapped methods anymore)

return M
