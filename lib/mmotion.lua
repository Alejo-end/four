-- mmotion: the gesture looper (S16) — a fourth driver for the params.
--
-- keys/encoders/MIDI are three drivers of the single source of truth (the
-- params). this module adds a fourth that RECORDS the param stream and
-- REPLAYS it: a modulation loop pedal for a 3-knob instrument. record a
-- filter sweep and it loops hands-free while you granulate on top; overdub a
-- delay-mix swell onto a second lane; each param you move becomes its own
-- automation lane. no engine change — it just re-issues params:set, so the
-- fingerprint is untouched and it can never brick loading.
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
  "cutoff", "resonance", "drive", "filt_type",
  "delay_time", "delay_fb", "delay_mix",
  "rev_decay", "rev_damp", "rev_size", "rev_early", "rev_moddepth",
  "rev_modfreq", "rev_low", "rev_mid", "rev_high", "rev_lowcut",
  "rev_highcut", "rev_mix", "shimmer", "shimmer_pitch", "shimmer_tone",
  "voice_atk", "voice_rel",
}

local M = {
  loop_len = 0,     -- frames; 0 = empty (no take yet)
  playhead = 0,     -- current loop frame while playing
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
  M.playhead = 0
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
      -- finalize the first pass: its length becomes the loop length
      local elapsed = C.frame - rec_start_frame
      if #M.lane_ids > 0 and elapsed >= 2 then
        M.loop_len = min(elapsed, MAX_LEN) + 1  -- +1 so the last frame plays
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
      capture_poll(M.playhead)                  -- overdub: at the loop position
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
    local ph = M.playhead
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
      while cur <= n and L.f[cur] <= ph do
        local v = L.v[cur]
        if blend then
          local p = params:lookup_param(id)
          if p and p.controlspec then
            local base = L.v[1]
            v = base + depth * (v - base)
          end
        end
        params:set(id, v)
        last_val[id] = v      -- account for our own change so the poll skips it
        L.last_fire = ph
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
end

function M.cleanup() end   -- nothing to tear down (no wrapped methods anymore)

return M
