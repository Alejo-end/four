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
--   lanes[id]  { f={}, v={}, n, cur } — flat, pre-grown arrays of
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
  -- TOMBSTONES: the two layer decks are gone (four, thirteenth change) and
  -- these fourteen ids name no param. They keep their places so that nothing
  -- after them moves and motion_lane keeps its range. Every reader of this
  -- list skips an id with no param. MOTION_TOMBSTONES below names them.
  "lay1_level", "lay1_rate", "lay1_reverse", "lay1_start", "lay1_end", "lay1_pre",
  "lay1_width",
  "lay2_level", "lay2_rate", "lay2_reverse", "lay2_start", "lay2_end", "lay2_pre",
  "lay2_width",
  -- the scene morph knob. recording THIS records a whole-instrument
  -- sweep in ONE lane — mscenes re-derives every param from it on replay
  -- (and tells us it did, via M.account, so the sweep never punches forty
  -- lanes of its own). appended, so existing lane order is unchanged.
  "scene_morph_amt",
  -- track 2 (four), appended so the lane order above is unchanged.
  -- The same choices as track 1: grain_shape and warp_overlaps stay out.
  "t2_level", "t2_pos_start", "t2_pos_end", "t2_scan", "t2_pitch", "t2_pan",
  "t2_pos_jitter", "t2_size", "t2_density", "t2_spread", "t2_grain_jitter",
  "t2_grain_pitch_spread", "t2_clouds_pos", "t2_clouds_tex", "t2_clouds_fb",
  "t2_clouds_lofi", "t2_clouds_mode", "t2_mode", "t2_warp_window",
  "t2_warp_rand", "t2_pv_freeze", "t2_cutoff", "t2_resonance", "t2_filt_type",
  -- COLOR and SPACE (four), appended: each track's drive and crush and
  -- its sends into the delay and the reverb
  "crush", "fx_dly", "fx_rev", "t2_drive", "t2_crush", "t2_fx_dly", "t2_fx_rev",
  -- THE EFFECT (four), appended: each track's effect and its two knobs
  "effect", "effect_amt", "effect_rate",
  "t2_effect", "t2_effect_amt", "t2_effect_rate",
}
-- four: tracks 3 and 4 the same as track 2 (appended, lane order kept),
-- then the twelve sends
do
  local t2 = {}
  for i = 1, #MOTION_IDS do
    local rest = MOTION_IDS[i]:match("^t2_(.+)$")
    if rest then t2[#t2 + 1] = rest end
  end
  for _, n in ipairs({ 3, 4 }) do
    for i = 1, #t2 do MOTION_IDS[#MOTION_IDS + 1] = "t" .. n .. "_" .. t2[i] end
  end
  for from = 1, 4 do
    for to = 1, 4 do
      if from ~= to then MOTION_IDS[#MOTION_IDS + 1] = "send_" .. from .. "_" .. to end
    end
  end
  -- the second effect slot, appended AFTER everything above: a lane is
  -- stored by its place in this list, so nothing before it may move
  for n = 1, 4 do
    local pre = n == 1 and "" or ("t" .. n .. "_")
    for _, k in ipairs({ "effect2", "effect2_amt", "effect2_rate" }) do
      MOTION_IDS[#MOTION_IDS + 1] = pre .. k
    end
  end
  -- the echoes into the reverb (appended, as above)
  MOTION_IDS[#MOTION_IDS + 1] = "dly_rev"
end

-- the entries of MOTION_IDS that are tombstones: ids of deleted params, kept
-- in the list so that no later entry moves. test_control lets only these
-- name a missing param, and fails if one of them comes back as a param.
local MOTION_TOMBSTONES = {
  "lay1_level", "lay1_rate", "lay1_reverse", "lay1_start", "lay1_end", "lay1_pre",
  "lay1_width",
  "lay2_level", "lay2_rate", "lay2_reverse", "lay2_start", "lay2_end", "lay2_pre",
  "lay2_width",
}

-- WHAT THE LOOPER DELIBERATELY DOES NOT RECORD — the other half of the list.
-- membership is TOTAL: test/test_control.lua asserts every param sits in
-- MOTION_IDS or here, never neither and never both, so a new param cannot
-- silently miss the decision. each line names its reason once.
local MOTION_EXCLUDE = {
  -- stage-setting levels + STOP (mix, the performance crossfade, IS recorded)
  "sc_level", "cut_level", "out_level", "stop_all",
  -- capture transports + write plumbing: a replayed arm or blend writes the
  -- buffer, which a loop must never do behind your back
  "rec", "tape_rec", "rec_level", "pre_level", "resample", "regen",
  "rec_wait", "rec_thresh", "rec_end",
  "take_undo", "undo_keep",
  "clear_rec", "sample_file", "export_take", "take_tighten", "print_take",
  "t2_file", "t3_file", "t4_file",   -- four: each track's own material
  "print_len", "pad_chop", "pad_even",
  -- PARAMS-only discretes: no performance surface reaches them
  "grain_shape", "warp_overlaps", "tape_fade",
  "t2_grain_shape", "t2_warp_overlaps",
  "t3_grain_shape", "t3_warp_overlaps", "t4_grain_shape", "t4_warp_overlaps",
  -- routing + structure (see the header: pad_input re-points the keyboard,
  -- the voices cap re-caps the allocator)
  "pad_input", "voices",
  -- UI cursors + the per-pad lock editors
  "seq_slice", "pad_voice", "pad_pitch",
  "track_sel",   -- four: which track VOICE and FILTER address
  "route_sel",   -- four: the ROUTE grid's cursor
  -- a clock rule, set and left (a replayed one would jump the window)
  "win_beats",
  -- config / keys
  "keys_enable", "midi_channel", "root_note", "kb_octave", "pitch_quant",
  -- motion itself, and the scene/orbit machinery (scene_morph_amt is the ONE
  -- scene param that IS recorded — the whole-sweep lane above)
  "motion_rec", "motion_play", "motion_lane", "motion_depth", "motion_len",
  "mod_focus",
  "scene_slot", "scene_recall_mode", "scene_scope", "scene_glide", "scene_capture",
  "scene_recall",
  "scene_next", "scene_clear", "scene_safe_capture", "scene_safe_restore",
  "chaos_throw", "orbit_on", "orbit_rate", "orbit_reach",
  -- the sequencer: a second machine on the clock. A loop replaying its knobs
  -- would fight it, so they are left to the hand, like the orbit's
  "step_run", "step_div", "step_len", "step_fill", "step_order",
  "step_chance", "step_gate",
  -- the beat repeat: a hold you play live (a replayed one would stutter on its own)
  "beat_repeat", "repeat_div",
  -- the modulation out: routing to other gear
  "out_src", "out_midi", "out_ch", "out_cc", "out_crow",
  -- the visuals link: routing to a computer, not sound
  "osc_on", "osc_host", "osc_port", "vis_look", "vis_flash", "vis_midi",
  -- the modulators: a loop of their knobs would fight them
  "lfo1_target", "lfo1_shape", "lfo1_period", "lfo1_rate", "lfo1_depth",
  "lfo2_target", "lfo2_shape", "lfo2_period", "lfo2_rate", "lfo2_depth",
  "lfo3_target", "lfo3_shape", "lfo3_period", "lfo3_rate", "lfo3_depth",
  "lfo4_target", "lfo4_shape", "lfo4_period", "lfo4_rate", "lfo4_depth",
  "lfo1_track", "lfo2_track", "lfo3_track", "lfo4_track",
}

local M = {
  loop_len = 0,     -- frames; 0 = empty (no take yet). the PLAYBACK length —
                    -- motion_len may retime it away from the recorded length.
  rec_len = 0,      -- the natural recorded length = the EVENT timebase. events
                    -- are stored against this; playback reads them through a
                    -- rec_len/loop_len ratio, so retiming is lossless.
  playhead = 0,     -- current loop frame while playing (0 .. loop_len)
  lane_ids = {},    -- ordered active param ids (first-touch order)
  lanes = {},       -- lanes[id] = { f, v, n, cur }
  -- exposed for the harness's totality check (see MOTION_EXCLUDE above)
  MOTION_IDS = MOTION_IDS,
  MOTION_TOMBSTONES = MOTION_TOMBSTONES,
  MOTION_EXCLUDE = MOTION_EXCLUDE,
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
-- the pre-retime behaviour (loop_len == rec_len -> src == playhead, integer).
--
-- The ENDPOINTS are what matter when it IS retimed: this maps the last
-- playback frame onto the last event frame, so the tail of every gesture is
-- reached. Scaling by rec_len/loop_len and flooring instead left the final
-- rec_len/loop_len event frames past the end of the sweep — shortening a loop
-- with motion_len silently dropped the end of every recorded gesture.
local function src_of(ph)
  if M.loop_len == M.rec_len then return ph end
  if M.loop_len <= 1 then return M.rec_len - 1 end
  return floor(ph * (M.rec_len - 1) / (M.loop_len - 1) + 0.5)
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
            L = { f = {}, v = {}, n = 0, cur = 1 }
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
        local fixed = len_frames(pget("motion_len", 0))
        -- AUTO: a pass played close to a musical length is put ON it (the
        -- snap ratios), so the loop stays in time with the clock, the
        -- synced delay and the decks. The gesture itself is untouched:
        -- playback reads it through src_of, so this only retimes it.
        if not fixed and C.clock_length then
          local s = C.clock_length(M.rec_len / FPS)
          if s then
            fixed = clamp(floor(s * FPS + 0.5), MIN_LEN, MAX_LEN)
            print(string.format("four: MOTION loop %.2fs -> %.2fs, on the clock",
              M.rec_len / FPS, fixed / FPS))
          end
        end
        M.loop_len = fixed or M.rec_len
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
    -- the loop is empty again: ALL of its timing goes, rec_len included, or
    -- a later motion_len move builds a phantom loop with no lanes and the
    -- next arm becomes a fixed-length overdub instead of a free first pass
    wipe()
    if pget("motion_play", 0) == 1 then params:set("motion_play", 0) end
  else
    reset_cursors()
  end
end

-- ===========================================================================
-- tick — one per redraw frame: capture live moves, then replay the loop
-- ===========================================================================

-- motion_depth scales a continuous lane toward its first value in the
-- controlspec's WARPED space, the same space the scene morph blends in
-- (ctx.warped_lerp), so half depth sits half way up the knob on an
-- exponential param too. discrete params pass through.
local function at_depth(id, L, v, depth)
  local p = params:lookup_param(id)
  local cs = p and p.controlspec
  if not cs then return v end
  return (C.warped_lerp(cs, L.v[1], v, depth))
end

-- this frame's due values, reused (the replay is on the 15fps hot path)
local due_ids, due_val = {}, {}

local function write_back(id, v)
  params:set(id, v)
  -- account for our own change so the poll skips it. read the value BACK
  -- rather than storing what we asked for: a Control stores map(unmap(v)),
  -- which differs from v in the last bit for a large share of values on an
  -- exponential spec. storing v left the next poll seeing a mismatch, reading
  -- it as a live hand on the knob, and punch-in REPLACING the very lane an
  -- overdub was meant to extend. M.account re-reads for the same reason.
  last_val[id] = params:get(id)
end

function M.tick()
  local armed = pget("motion_rec", 0) == 1
  -- 1) capture: poll for live param moves (before playback overwrites them)
  if armed then
    if M.loop_len == 0 then
      local offset = C.frame - rec_start_frame
      if offset >= 0 and offset <= MAX_LEN then capture_poll(offset) end
    elseif pget("motion_play", 0) == 1 then
      -- overdub: punch in at the loop position, mapped to the EVENT timebase so
      -- new events line up with the old ones even when the loop is retimed
      capture_poll(src_of(M.playhead))
    else
      -- armed over an existing loop with the transport STOPPED. The playhead
      -- is frozen, so every move would punch-in-clear the lane and then stack
      -- at one identical offset — an automation curve replaced by a single
      -- step. There is no timebase to record against, so disarm and say so
      -- (arming an overdub starts playback; getting here means it was stopped
      -- afterwards, by hand).
      params:set("motion_rec", 0)
      print("four: MOTION overdub needs the loop running — disarmed")
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
    -- motion_depth (0..1): a global "amount" for the whole loop (at_depth)
    local depth = pget("motion_depth", 1)
    local blend = depth < 0.999
    local ids = M.lane_ids
    -- 1) what each lane says NOW: the last event due by this frame (a
    --    retimed loop can pass several in one frame; only the last one is
    --    the value the param should hold)
    local nd = 0
    for i = 1, #ids do
      local id = ids[i]
      local L = M.lanes[id]
      local n, cur, v = L.n, L.cur, nil
      while cur <= n and L.f[cur] <= src do
        v = L.v[cur]
        cur = cur + 1
      end
      L.cur = cur
      if v ~= nil then
        nd = nd + 1
        due_ids[nd] = id
        due_val[id] = blend and at_depth(id, L, v, depth) or v
      end
    end
    -- 2) write them. A region's two edges due together go through the one
    --    pair writer (widening edge first): replayed in lane order, a slide
    --    right crossed the pair for one write every pass, and the deck's
    --    100ms floor turned that into a jump of the head.
    -- (the pair maps live in mscenes, which initialises after this module,
    -- so they are read here rather than bound at init)
    local sc = C.scene
    local pm = nd > 1 and sc and sc.PARTNER or nil
    for k = 1, nd do
      local id = due_ids[k]
      local v = due_val[id]
      if v ~= nil then
        local partner = pm and pm[id]
        local pv = partner and due_val[partner] or nil
        if pv ~= nil then
          local sid, eid = id, partner
          if not sc.EDGE_PAIRS[id] then sid, eid = partner, id end
          C.set_pair(sid, eid, due_val[sid], due_val[eid])
          last_val[sid], last_val[eid] = params:get(sid), params:get(eid)
          due_val[partner] = nil
        else
          write_back(id, v)
        end
        due_val[id] = nil
      end
      due_ids[k] = nil
    end
  end
end

-- ===========================================================================
-- the loop rides the PSET
-- ===========================================================================
-- Scenes, the take and the tape all come back with a session; the
-- gesture loop does too. The lanes save as a plain table beside the pset
-- (motion-N.lua). A loop with no lanes deletes the file, and a pset with no
-- file loads with no loop: the loop belongs to the session being loaded.

local function path_for(number)
  return norns.state.data .. "motion-" .. number .. ".lua"
end

function M.pset_write(number)
  if #M.lane_ids == 0 then os.remove(path_for(number)); return end
  local t = { v = 1, loop_len = M.loop_len, rec_len = M.rec_len,
              ids = {}, lanes = {} }
  for i, id in ipairs(M.lane_ids) do
    local L = M.lanes[id]
    local f, v = {}, {}
    for e = 1, L.n do f[e], v[e] = L.f[e], L.v[e] end
    t.ids[i], t.lanes[id] = id, { f = f, v = v }
  end
  local ok, err = pcall(tab.save, t, path_for(number))
  if not ok then print("four: motion save failed — " .. tostring(err)) end
end

function M.pset_read(number)
  -- params:read has already restored the transports. A saved ARM must not
  -- start recording over the restored loop, and the play state applies to
  -- the loop loaded here, not to whatever was running before the load.
  local play = pget("motion_play", 0) == 1
  if pget("motion_rec", 0) == 1 then params:set("motion_rec", 0) end
  wipe()
  local path = path_for(number)
  if util.file_exists(path) then
    local ok, t = pcall(tab.load, path)
    if ok and type(t) == "table" and type(t.ids) == "table"
        and type(t.lanes) == "table" then
      for _, id in ipairs(t.ids) do
        local s = t.lanes[id]
        if params.lookup[id] and type(s) == "table" and type(s.f) == "table"
            and type(s.v) == "table" then
          local L = { f = {}, v = {}, n = 0, cur = 1 }
          for e = 1, #s.f do L.f[e], L.v[e], L.n = s.f[e], s.v[e], e end
          M.lanes[id] = L
          M.lane_ids[#M.lane_ids + 1] = id
        end
      end
      if #M.lane_ids > 0 then
        M.rec_len = t.rec_len or 0
        M.loop_len = t.loop_len or M.rec_len
      end
    end
  end
  play = play and M.loop_len > 0
  if (pget("motion_play", 0) == 1) ~= play then
    params:set("motion_play", play and 1 or 0)
  end
  M.playhead = 0
  reset_cursors()
end

function M.pset_delete(number)
  os.remove(path_for(number))
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

return M
