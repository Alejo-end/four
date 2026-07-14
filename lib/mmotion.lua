-- mmotion: the gesture looper (S16) — a fourth driver for the params.
--
-- keys/encoders/MIDI are three drivers of the single source of truth (the
-- params). this module adds a fourth that RECORDS the param stream and
-- REPLAYS it: a modulation loop pedal for a 3-knob instrument. record a
-- filter sweep and it loops hands-free while you granulate on top; overdub a
-- delay-mix swell onto a second lane; each param you touch becomes its own
-- automation lane. no engine change — it re-issues the same params:set calls,
-- so the fingerprint is untouched and it can never brick loading.
--
-- data model: one loop, per-param lanes.
--   loop_len   loop length in FRAMES (the 15fps redraw grid is the timeline;
--              no new clock). 0 until the first take sets it (free length).
--   lanes[id]  { f={}, v={}, n, cur, last_fire } — flat, pre-grown arrays of
--              {frame-offset, value} events over [0, loop_len). sparse: only
--              params you actually touched exist, so they layer independently.
--   punch-in replace: the first time a param is touched in a record pass its
--   lane is cleared, then events append — re-recording a param overwrites
--   ONLY that lane.
--
-- capture: wrap params.set/params.delta (restored in cleanup) — reading
-- params:get AFTER the call captures the absolute value whether the driver
-- was a set or an encoder delta, and catches keys + MIDI + the typing
-- keyboard for free. only MOTION_IDS (the performance/mangle params) are
-- captured; levels, transport and config are excluded.
--
-- the replay guard: playback fires params:set for owned lanes every frame —
-- those must NOT be re-captured or the loop grows without bound. `replaying`
-- is raised around the fire calls and the capture hook ignores changes while
-- it is set, so only genuinely-live moves enter a lane.

local min, max, floor = math.min, math.max, math.floor

local C            -- shared ctx, bound at init
local pget, clamp, FPS
local MAX_LEN      -- cap the loop at 60s so a forgotten arm can't run away

-- the params whose motion is recordable — the performance / mangle knobs and
-- toggles. NOT here: system levels (input/output/monitor/headphone/out/sc/cut/
-- rec), the keys_* config, pad_input, the transports (rec/tape_rec/stop_all),
-- and motion_* itself. add new mangle params to this list to make them
-- automatable.
local MOTION_IDS = {}
for _, id in ipairs({
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
}) do MOTION_IDS[id] = true end

local M = {
  loop_len = 0,     -- frames; 0 = empty (no take yet)
  playhead = 0,     -- current loop frame while playing
  lane_ids = {},    -- ordered active param ids (first-touch order)
  lanes = {},       -- lanes[id] = { f, v, n, cur, last_fire }
}

-- purely-internal state (not read by the page)
local replaying = false        -- true while WE are firing params (no capture)
local rec_start_frame = 0       -- ctx.frame when the first pass armed
local touched_this_pass = {}    -- ids already punched-in this pass
local orig_set, orig_delta      -- saved paramset methods (restored in cleanup)

-- ============================================================================
-- lane bookkeeping
-- ============================================================================

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

-- ============================================================================
-- capture — the wrapped params.set/delta land here after the original runs
-- ============================================================================

function M.on_change(id)
  if replaying then return end
  if pget("motion_rec", 0) ~= 1 then return end
  if not MOTION_IDS[id] then return end
  if not params.lookup[id] then return end
  local offset
  if M.loop_len == 0 then
    offset = C.frame - rec_start_frame          -- first pass: elapsed frames
    if offset < 0 or offset > MAX_LEN then return end
  else
    offset = M.playhead                          -- overdub: the loop position
  end
  local L = M.lanes[id]
  if not touched_this_pass[id] then
    -- punch-in replace: first touch this pass clears the lane (or creates it)
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
  L.v[L.n] = params:get(id)
end

-- ============================================================================
-- transport — driven by the motion_rec / motion_play param actions
-- ============================================================================

function M.set_armed(on)
  if on then
    touched_this_pass = {}
    if M.loop_len == 0 then
      rec_start_frame = C.frame                  -- first pass: start the clock
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
        M.loop_len = min(elapsed, MAX_LEN) + 1   -- +1 so the last frame plays
        M.playhead = 0
        reset_cursors()
        if pget("motion_play", 0) ~= 1 then params:set("motion_play", 1) end
      else
        -- nothing captured (or too short): stay empty
        wipe()
        if pget("motion_play", 0) == 1 then params:set("motion_play", 0) end
      end
    else
      touched_this_pass = {}                      -- overdub done
    end
  end
end

function M.set_playing(on)
  if on and M.loop_len > 0 then
    M.playhead = 0
    reset_cursors()
  end
end

-- ============================================================================
-- clear (CLR-L / CLR on the MOTION page)
-- ============================================================================

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

-- ============================================================================
-- playback — one tick per redraw frame (called from mangler's 15fps clock)
-- ============================================================================

function M.tick()
  if pget("motion_play", 0) ~= 1 or M.loop_len == 0 then return end
  M.playhead = M.playhead + 1
  if M.playhead >= M.loop_len then
    M.playhead = 0
    reset_cursors()
    -- an overdub that ran a full loop auto-disarms (keeps the lane's events
    -- sorted and bounds the pass to one loop)
    if pget("motion_rec", 0) == 1 then params:set("motion_rec", 0) end
  end
  local ph = M.playhead
  -- motion_depth (0..1) scales continuous lanes toward their first value —
  -- a global "amount" fader for the whole modulation loop (living loops).
  -- discrete params (options/binaries/numbers, no controlspec) pass through.
  local depth = pget("motion_depth", 1)
  local blend = depth < 0.999
  local ids = M.lane_ids
  replaying = true
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
      L.last_fire = ph
      cur = cur + 1
    end
    L.cur = cur
  end
  replaying = false
end

-- ============================================================================
-- lifecycle
-- ============================================================================

function M.init(ctx)
  C = ctx
  pget, clamp, FPS = ctx.pget, ctx.clamp, ctx.FPS
  MAX_LEN = 60 * FPS
  -- wrap the paramset entry points so every value change (key/encoder/MIDI/
  -- typing) flows through on_change. call the original first, then capture.
  if not orig_set then
    orig_set = params.set
    params.set = function(self, id, ...)
      orig_set(self, id, ...)
      M.on_change(id)
    end
    orig_delta = params.delta
    params.delta = function(self, id, ...)
      orig_delta(self, id, ...)
      M.on_change(id)
    end
  end
end

function M.cleanup()
  if orig_set then params.set = orig_set end
  if orig_delta then params.delta = orig_delta end
  orig_set, orig_delta = nil, nil
end

return M
