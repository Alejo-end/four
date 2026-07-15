-- mscenes: scenes, scene morphing, and the safe-state snapshot (S19) — the
-- "remember this / go back to that" layer.
--
-- three features, one data model:
--   SCENES   8 slots, each a flat map { param_id = value } captured from the
--            live params. recall writes them back through params:set, so the
--            engine, the tape and the display all follow for free — a scene
--            is not a second source of truth, it's a photograph of the one
--            that exists.
--   MORPH    a continuous A -> B sweep over the subset of those params that
--            can be interpolated. one knob (scene_morph_amt) moves the whole
--            instrument along a line between two remembered sounds.
--   SAFE     one "last known good" snapshot + an instant restore. capture it
--            before you do something reckless (see the chaos throw below);
--            restore drops you straight back on your feet.
--
-- NOTHING here stores audio. scenes are control state only: a recall does not
-- bring back the take you have since overdubbed (that's what PSETs + the tape
-- wav are for, see mtape). that's also what makes it cheap — 8 slots is ~350
-- numbers, and a recall is ~60 params:set calls.
--
-- WHAT IS AND ISN'T IN A SCENE — the lists are right below and they are
-- deliberate. in: everything that shapes the sound of the take (window,
-- grain/clouds, stretch, tape loop, filter, delay, reverb, shimmer, voices,
-- the sequencer's pattern generator). out: the hardware/config layer (midi
-- channel, keys, root note), the SYSTEM levels (in/out/monitor/hp), the
-- capture transports (rec, tape_rec), the master STOP, and the motion/seq
-- transports. a scene changes how it sounds, never how it's plumbed or
-- whether it's running.
--
-- THE MORPH IS FRAME-COALESCED. scene_morph_amt's action only marks the sweep
-- dirty; M.tick() applies it at most once per redraw frame (the existing 15fps
-- clock — no new process, same modulation grid the gesture looper runs on).
-- a fast CC sweep would otherwise fire ~40 params x 128 CC steps at the engine
-- in a second; this caps it at 15 passes/s, and the per-param deadband below
-- drops the ones that aren't actually moving.

local floor, abs = math.floor, math.abs

local C            -- shared ctx, bound at init
local pget, clamp

local NUM_SLOTS = 8

-- ===========================================================================
-- the curated param lists
-- ===========================================================================
-- SCENE_RECALL_IDS is built from three ORDERED blocks, and recall/restore
-- walk it in order, so a scene lands in the order the engine wants it:
--
--   1 TIMBRE  the continuous voice: source blend, window, grain/clouds,
--             stretch shape, tape loop, voices, sequencer pattern
--   2 SPACE   the wet path: filter, drive, delay, reverb, shimmer
--   3 SWITCH  the discrete mode/type switches — LAST, on purpose: `mode`
--             respawns the SC voice, so switching it after everything else
--             means the new voice is BORN with the scene's params instead of
--             being born wrong and then jumped to them.
--
-- add a new mangle param to the right block and it joins scenes, morphs and
-- the safe snapshot at once (MOTION_IDS in mmotion is the same idea for the
-- gesture looper — the two lists are siblings, kept separate on purpose).

local TIMBRE_IDS = {
  -- source blend. NOT out_level: a scene must never rewrite your stage
  -- volume. (the safe snapshot does take it — see SAFE_EXTRA_IDS.)
  "mix", "sc_level", "cut_level",
  -- playback path + the two output->buffer writers. resample only bites on
  -- the next armed take; regen is the one member that quietly rewrites the
  -- buffer, which is exactly why a scene should be able to pull it back to 0.
  "dry_wet", "resample", "regen",
  -- window / scan
  "pos_start", "pos_end", "scan", "pos_jitter",
  -- grain + clouds (the granular character)
  "size", "density", "pitch", "spread", "pan", "grain_level",
  "grain_jitter", "grain_pitch_spread",
  "clouds_pos", "clouds_tex", "clouds_fb", "clouds_lofi",
  -- stretch shape (mode itself is a SWITCH, below)
  "warp_window", "warp_overlaps", "warp_rand",
  -- tape deck (loop bounds ride along, so a scene = a loop region too)
  "tape_rate", "loop_start", "loop_end", "tape_pre", "tape_fade",
  -- polyphonic pad voices
  "voices", "voice_atk", "voice_rel",
  -- the sequencer's PATTERN (not its transport): euclid regenerates on set,
  -- so a scene restores the generated rhythm. hand-drawn grid edits live in
  -- mseq.pattern, which is not a param — they don't survive a recall.
  "seq_euclid", "seq_len", "seq_slice",
}

local SPACE_IDS = {
  "cutoff", "resonance", "drive",
  "delay_time", "delay_fb", "delay_mix",
  "rev_decay", "rev_damp", "rev_size", "rev_early", "rev_moddepth",
  "rev_modfreq", "rev_low", "rev_mid", "rev_high", "rev_lowcut",
  "rev_highcut", "rev_mix",
  "shimmer", "shimmer_pitch", "shimmer_tone",
}

local SWITCH_IDS = {
  "filt_type", "clouds_mode", "grain_shape", "seq_div",
  "freeze", "pv_freeze", "tape_freeze", "pad_input",
  "mode",   -- last of the last: this one respawns the voice
}

-- NOT here on purpose: `tape_reverse`. it's a MOMENTARY param — the TAPE key
-- and the grid pad hold it and hand the release to held_gesture, so its
-- resting value is 0 and a captured 1 is a transient, not a state. recalling
-- that 1 would latch the tape backwards with nothing left to release it.
-- nothing is lost: `tape_rate` is bipolar (-2..2) and IS in the list, so "this
-- scene plays backwards" stores as a negative rate.

local function append(dst, src)
  for i = 1, #src do dst[#dst + 1] = src[i] end
end

local SCENE_RECALL_IDS = {}
append(SCENE_RECALL_IDS, TIMBRE_IDS)
append(SCENE_RECALL_IDS, SPACE_IDS)
append(SCENE_RECALL_IDS, SWITCH_IDS)

-- MORPH-SAFE = recall MINUS these. the rule, in one line: a morph never
-- flips a hold, never re-routes your notes, never writes the buffer, and
-- never changes the voice structure.
--   freeze / pv_freeze / tape_freeze  holds. crossing 0.5 mid-sweep is a
--     hard event, not a texture — recall the scene if you want the hold.
--   pad_input  note ROUTING. flipping it mid-sweep re-points the keyboard
--     and releases sounding pad voices.
--   resample / regen  the buffer writers. a sweep must stay undo-able, and
--     audio already committed to the buffer is not.
--   voices  the poly CAP. lerping it crosses integers, and every crossing
--     re-caps the engine's allocator — which steals (cuts) held pad notes
--     mid-sweep. structure, not texture: a recall sets it, a morph doesn't.
-- consequence, worth knowing: morph at amt=1 is NOT the same as recall(B) —
-- it moves the morph-safe subset only. sweep to 1, then K2 RCL to land the
-- rest. (the SCENE page says so: see M.unlanded + the "RCL B TO LAND" cue.)
local MORPH_EXCLUDE = {
  freeze = true, pv_freeze = true, tape_freeze = true,
  pad_input = true, resample = true, regen = true, voices = true,
}

-- the two complementary halves of the recall list: what a morph carries, and
-- what it deliberately leaves behind (the latter drives the page's cue).
local SCENE_MORPH_IDS = {}
local MORPH_SKIPPED_IDS = {}
for i = 1, #SCENE_RECALL_IDS do
  local id = SCENE_RECALL_IDS[i]
  if MORPH_EXCLUDE[id] then
    MORPH_SKIPPED_IDS[#MORPH_SKIPPED_IDS + 1] = id
  else
    SCENE_MORPH_IDS[#SCENE_MORPH_IDS + 1] = id
  end
end

-- the safe snapshot is the recall set PLUS the master out: if a throw (or a
-- fat finger) moved your level, the rescue should bring that back too. it
-- still refuses the SYSTEM levels, the transports and stop_all — a restore
-- must never unmute you, re-arm a recording, or undo a STOP you're leaning on.
local SAFE_EXTRA_IDS = { "out_level" }
local SAFE_SNAPSHOT_IDS = {}
append(SAFE_SNAPSHOT_IDS, SAFE_EXTRA_IDS)
append(SAFE_SNAPSHOT_IDS, SCENE_RECALL_IDS)

-- NEVER capture the scene_* params themselves. scene_morph_amt's action
-- re-fires the morph, so a snapshot that restored it would immediately
-- overwrite everything it just restored. (they're also UI selectors — not
-- sound.) this is a note to whoever adds the next param to the lists above.

-- ===========================================================================
-- module state
-- ===========================================================================

local M = {
  slots = {},         -- slots[1..8] = { id = value } (nil = empty). ctx.scenes
  safe = nil,         -- the safe snapshot, same shape
  pending = nil,      -- slot waiting on a quantized recall (nil = none)
  morph_at = 0,       -- last morph amount applied (display)
  chaos_live = false, -- a chaos throw is currently held
  safe_at = -999,     -- frames, for the page's confirmation flashes
  restored_at = -999,
  captured_at = -999,
  NUM_SLOTS = NUM_SLOTS,
  -- exposed for docs/tests/inspection: the three lists, as built above
  SCENE_RECALL_IDS = SCENE_RECALL_IDS,
  SCENE_MORPH_IDS = SCENE_MORPH_IDS,
  SAFE_SNAPSHOT_IDS = SAFE_SNAPSHOT_IDS,
}

local dirty = false      -- a morph is pending for the next tick
local morphing = false   -- re-entry guard (a param action must never recurse)
local last_sent = {}     -- morph: the last value/norm we pushed, per param
local pending_clock      -- the quantized-recall coroutine (nil = none)

local QUANT_BEATS = { 0, 1, 4 }   -- scene_recall_mode: NOW / BEAT / BAR

-- ===========================================================================
-- param plumbing
-- ===========================================================================

local function lookup(id)
  return params.lookup[id] and params:lookup_param(id) or nil
end

local function slot_idx(slot)
  return clamp(floor((slot or pget("scene_slot", 1)) + 0.5), 1, NUM_SLOTS)
end

-- EVERY write in this module goes through here.
-- 1) params stay the single source of truth — we set the same ids the
--    encoders, keys and MIDI CCs set, and their actions do the engine work.
-- 2) the gesture looper is told the value came from US. mmotion captures by
--    polling for changes, so without this a scene jump or a morph sweep would
--    look exactly like forty hands on forty knobs and punch a lane for each.
--    scenes and motion stay orthogonal drivers: motion records the MORPH KNOB
--    (scene_morph_amt is in MOTION_IDS) and replays that — one lane, not forty.
local function pset(id, v)
  params:set(id, v)
  local mo = C.motion
  -- account for the RESOLVED value: a control quantizes what you hand it
  if mo and mo.account then mo.account(id) end
end

-- the morph's "already sent" memory is only valid while nothing else moves
-- the instrument. any capture/recall/restore/endpoint change clears it, so
-- the next amount move re-asserts the whole sweep from wherever we now are.
function M.invalidate()
  for k in pairs(last_sent) do last_sent[k] = nil end
  -- ...and the morph is no longer what's driving the sound: something else
  -- (a recall, a restore, a throw, a new endpoint) just moved it off the line
  M.engaged = false
end

local function snapshot_ids(ids)
  local t = {}
  for i = 1, #ids do
    local id = ids[i]
    if params.lookup[id] then t[id] = params:get(id) end
  end
  return t
end

-- region edges: two params that only mean something as a PAIR. setting them
-- one at a time means the consumer reads ONE new edge against ONE old one for
-- an instant — softcut can render up to a block of a region that is neither
-- the old nor the new one (and update_tape_loop's `hi-lo < 0.1` floor turns a
-- crossed pair into a 100ms loop, which jumps the head audibly). so: move the
-- edge that widens the region FIRST, and every intermediate contains a real
-- region instead of a bogus one. `start` key -> `end` key.
local EDGE_PAIRS = { pos_start = "pos_end", loop_start = "loop_end" }

-- apply a stored table, walking `ids` IN ORDER (timbre -> space -> switches;
-- see the list comment). params missing from the table are skipped, so a
-- scene captured by an older version still recalls what it does know.
local function apply(tbl, ids)
  if not tbl then return 0 end
  local n = 0
  local done                      -- edge partners already set (nil until needed)
  for i = 1, #ids do
    local id = ids[i]
    local v = tbl[id]
    if v ~= nil and params.lookup[id] and not (done and done[id]) then
      local partner = EDGE_PAIRS[id]
      local pv = partner and tbl[partner]
      if pv ~= nil and params.lookup[partner] then
        -- outward edge first: if the new start moves LEFT it's the widening
        -- one, else the new end is
        if v < params:get(id) then pset(id, v) pset(partner, pv)
        else pset(partner, pv) pset(id, v) end
        done = done or {}
        done[partner] = true
        n = n + 2
      else
        pset(id, v)
        n = n + 1
      end
    end
  end
  M.invalidate()
  return n
end

local function cancel_pending()
  if pending_clock then clock.cancel(pending_clock) end
  pending_clock, M.pending = nil, nil
end

-- ===========================================================================
-- scenes — capture / recall / clear
-- ===========================================================================

-- capture the live state of SCENE_RECALL_IDS into a slot (default: the
-- selected one). overwrites without ceremony — like every other throw in this
-- instrument, the key does the thing.
function M.capture(slot)
  slot = slot_idx(slot)
  M.slots[slot] = snapshot_ids(SCENE_RECALL_IDS)
  M.captured_at = C.frame
  M.invalidate()   -- an endpoint's contents may have just changed under us
  return true
end

-- recall a slot. opts.immediate = true forces NOW even when the page is set
-- to quantize; otherwise scene_recall_mode decides (NOW / next BEAT / next
-- BAR). a queued recall replaces any other queued recall — last press wins.
function M.recall(slot, opts)
  slot = slot_idx(slot)
  local scene = M.slots[slot]
  if not scene then return false end
  opts = opts or {}
  local mode = floor(pget("scene_recall_mode", 1) + 0.5)
  local beats = QUANT_BEATS[mode] or 0
  cancel_pending()
  if beats > 0 and not opts.immediate then
    M.pending = slot
    -- ONE coroutine, always cancelled on replace / restore / cleanup (the
    -- norns clock-race gotcha: a timer resuming a dead thread wedges clock)
    pending_clock = clock.run(function()
      clock.sync(beats)
      pending_clock, M.pending = nil, nil
      apply(M.slots[slot], SCENE_RECALL_IDS)
    end)
    return true
  end
  apply(scene, SCENE_RECALL_IDS)
  return true
end

function M.clear(slot)
  slot = slot_idx(slot)
  -- mutate in place: ctx.scenes points AT this table
  M.slots[slot] = nil
  if M.pending == slot then cancel_pending() end
  M.invalidate()
  return true
end

-- ===========================================================================
-- morph — A -> B, one knob
-- ===========================================================================
-- continuous params interpolate in the controlspec's OWN (warped) space:
-- cutoff 20 -> 20000 is exponential, so a raw lerp would sit at "nearly open"
-- for the whole second half of the sweep. unmap -> lerp -> map is linear in
-- the space the encoder moves in, which is the one that sounds even. pass
-- opts.linear for a raw-value lerp instead.
-- numbers (voices, warp_overlaps) lerp and land on integers; options and
-- binaries can't be half-switched, so they flip at the midpoint (amt >= 0.5).

local function morph_value(id, va, vb, amt, linear)
  local p = lookup(id)
  if not p then return nil end
  local cs = p.controlspec
  if cs then
    if linear then
      local v = va + (vb - va) * amt
      v = clamp(v, cs.minval, cs.maxval)
      return v, clamp(cs:unmap(v), 0, 1)
    end
    local na = clamp(cs:unmap(va), 0, 1)
    local nb = clamp(cs:unmap(vb), 0, 1)
    local tn = na + (nb - na) * amt
    -- the normalized target doubles as the deadband key below: if a param is
    -- identical in A and B, tn never moves and it never gets sent at all
    return cs:map(tn), tn
  end
  if p.count then                                  -- option: midpoint switch
    return amt < 0.5 and va or vb
  end
  if p.min and p.max then                          -- number: lerp -> integer
    return clamp(floor(va + (vb - va) * amt + 0.5), p.min, p.max)
  end
  return amt < 0.5 and va or vb                    -- binary / unknown
end

-- normalized deadband: a param must move at least this much (of its full
-- range) before we re-send it. kills duplicate engine commands on a sweep
-- without being coarse enough to see or hear.
local MORPH_EPS = 1 / 400

-- morph the instrument to `amt` (0..1) along slot a -> slot b.
--   opts.force   send every param even if it hasn't moved
--   opts.linear  interpolate raw values instead of controlspec space
-- returns false when either slot is empty (nothing to interpolate between).
function M.morph(a, b, amt, opts)
  if morphing then return false end    -- a param action can never recurse in
  local A, B = M.slots[slot_idx(a)], M.slots[slot_idx(b)]
  if not (A and B) then return false end
  opts = opts or {}
  amt = clamp(amt or 0, 0, 1)
  -- at the ends, land EXACTLY on the stored values (no deadband rounding)
  local force = opts.force or amt <= 0 or amt >= 1
  morphing = true
  local ids = SCENE_MORPH_IDS
  for i = 1, #ids do
    local id = ids[i]
    local va, vb = A[id], B[id]
    -- skip anything either scene doesn't have (older capture, missing param)
    if va ~= nil and vb ~= nil and params.lookup[id] then
      local v, tn = morph_value(id, va, vb, amt, opts.linear)
      if v ~= nil then
        local key = tn or v        -- continuous: compare norms; discrete: values
        local last = last_sent[id]
        local fire = force or last == nil
          or (tn and abs(tn - last) >= MORPH_EPS)
          or (not tn and v ~= last)
        if fire then
          pset(id, v)
          last_sent[id] = key
        end
      end
    end
  end
  morphing = false
  M.morph_at = amt
  M.engaged = true      -- the morph is now what's driving the sound
  return true
end

-- does this slot hold state a MORPH can't carry? (the MORPH_SKIPPED_IDS —
-- holds, routing, buffer writers, the voice cap.) true = the sweep has
-- arrived but those are still sitting where you left them, and only a K2
-- recall lands them. drives the SCENE page's "RCL B TO LAND" cue, which
-- exists so `morph(1) ~= recall(B)` is visible instead of mysterious.
function M.unlanded(slot)
  local scene = M.slots[slot_idx(slot)]
  if not scene then return false end
  for i = 1, #MORPH_SKIPPED_IDS do
    local id = MORPH_SKIPPED_IDS[i]
    local v = scene[id]
    if v ~= nil and params.lookup[id]
        and abs(params:get(id) - v) > 1e-6 then
      return true
    end
  end
  return false
end

-- scene_morph_amt's action calls this: mark the sweep dirty and let the next
-- frame do the work (see the coalescing note at the top).
function M.touch()
  dirty = true
end

-- one per redraw frame, from the existing 15fps clock in mangler.lua.
function M.tick()
  if not dirty then return end
  dirty = false
  M.morph(pget("scene_morph_a", 1), pget("scene_morph_b", 2),
    pget("scene_morph_amt", 0))
end

-- ===========================================================================
-- safe snapshot — the undo for live experimentation
-- ===========================================================================

function M.safe_capture()
  M.safe = snapshot_ids(SAFE_SNAPSHOT_IDS)
  M.safe_at = C.frame
  return true
end

-- back to the last known good state, now. control state only: it does not
-- touch the buffer, the tape audio, or held voices — this is an undo for
-- knobs, not a panic mute (K1+K2 STOP is the mute, and it stays yours).
function M.safe_restore()
  if not M.safe then return false end
  cancel_pending()   -- a queued recall must not undo the rescue a beat later
  apply(M.safe, SAFE_SNAPSHOT_IDS)
  M.chaos_live = false
  M.restored_at = C.frame
  return true
end

-- ===========================================================================
-- chaos throw — hold for madness, release for safety
-- ===========================================================================
-- chaos_throw is a MOMENTARY param: press throws, release restores the safe
-- snapshot. map it to a footswitch or hit the grid pad. the throw is bounded
-- per-param in NORMALIZED space, so it lands somewhere wild but never
-- somewhere silent, and (like the morph) it never touches rec/resample/regen
-- or the levels — everything it does is undo-able, which is the whole point.
-- math.random lives here and nowhere near the draw path: the seeded render
-- suite never calls it, so the pages' RNG stream is untouched.

local CHAOS = {
  { "pos_jitter", 0.35, 1.00 },
  { "density", 0.55, 1.00 },
  { "size", 0.00, 0.45 },
  { "grain_jitter", 0.30, 1.00 },
  { "grain_pitch_spread", 0.20, 0.90 },
  { "clouds_tex", 0.00, 1.00 },
  { "clouds_fb", 0.20, 0.70 },
  { "resonance", 0.40, 0.95 },
  { "drive", 0.20, 0.80 },
  { "delay_fb", 0.50, 0.95 },
  { "delay_mix", 0.30, 0.90 },
  { "rev_mix", 0.30, 0.90 },
  { "shimmer", 0.20, 0.90 },
  { "warp_rand", 0.30, 1.00 },
}

-- scan is bipolar — normalized 0.5 is STOPPED. throw it to one side or the
-- other so chaos always keeps moving.
local SCAN_FWD = { 0.62, 0.95 }
local SCAN_REV = { 0.05, 0.38 }

local function set_norm(id, n)
  local p = lookup(id)
  if p and p.controlspec then pset(id, p.controlspec:map(clamp(n, 0, 1))) end
end

local function throw(id, lo, hi)
  set_norm(id, lo + math.random() * (hi - lo))
end

function M.chaos()
  -- never strand the performer: if they never marked a safe state, the throw
  -- marks one for them, so the release always has somewhere to land
  if not M.safe then M.safe_capture() end
  for i = 1, #CHAOS do
    local c = CHAOS[i]
    throw(c[1], c[2], c[3])
  end
  local s = math.random() < 0.5 and SCAN_REV or SCAN_FWD
  throw("scan", s[1], s[2])
  M.invalidate()
  M.chaos_live = true
  return true
end

-- the release edge. it only acts when a throw is actually live, so a stray 0
-- (params:bang at init, a pset read) can never restore out of nowhere.
function M.chaos_release()
  if not M.chaos_live then return false end
  M.chaos_live = false
  return M.safe_restore()
end

-- ===========================================================================
-- persistence — rides along with the PSET
-- ===========================================================================
-- the scene bank + the safe snapshot save as a plain lua table next to the
-- pset, in the same data/ folder the tape audio uses. mangler.lua's
-- action_write/read/delete call BOTH modules (mtape does the audio, we do
-- the state) — that hook is shared, never replaced.

local function path_for(number)
  return norns.state.data .. "scenes-" .. number .. ".lua"
end

function M.pset_write(number)
  local ok, err = pcall(tab.save,
    { v = 1, slots = M.slots, safe = M.safe }, path_for(number))
  if not ok then print("mangler: scene save failed — " .. tostring(err)) end
end

function M.pset_read(number)
  -- a pset LOAD is authoritative: params:read() has just restored the VALUES
  -- the sound actually had — and in doing so re-set scene_morph_amt, which
  -- fired touch() and armed a sweep. drop it. re-deriving the morph here would
  -- overwrite any param the performer hand-tweaked AFTER their last morph move
  -- and saved, one frame after the load, silently. the morph re-engages on the
  -- next move of the knob. (this runs from action_read, i.e. after the values.)
  dirty = false
  local path = path_for(number)
  -- no scene file (a pset from before scenes existed): leave the bank alone,
  -- exactly like mtape leaves the tape audio alone when there's no wav
  if not util.file_exists(path) then return end
  local ok, t = pcall(tab.load, path)
  if not (ok and type(t) == "table" and type(t.slots) == "table") then
    print("mangler: scene file unreadable — " .. tostring(t))
    return
  end
  cancel_pending()
  for i = 1, NUM_SLOTS do
    M.slots[i] = type(t.slots[i]) == "table" and t.slots[i] or nil
  end
  if type(t.safe) == "table" then M.safe = t.safe end
  M.invalidate()
end

function M.pset_delete(number)
  os.remove(path_for(number))
end

-- ===========================================================================
-- lifecycle
-- ===========================================================================

function M.init(ctx)
  C = ctx
  pget, clamp = ctx.pget, ctx.clamp
  ctx.scene = M          -- the module, like ctx.motion / ctx.seq
  ctx.scenes = M.slots   -- the scene table itself (mutated in place, never
                         -- reassigned, so this ref can't go stale)
  -- the named helpers, on ctx beside fx_dry / pads_all_off — the KEYS table
  -- and the grid reach them the same way they reach everything else
  ctx.scene_capture = M.capture
  ctx.scene_recall = M.recall
  ctx.scene_clear = M.clear
  ctx.scene_morph = M.morph
  ctx.safe_snapshot_capture = M.safe_capture
  ctx.safe_snapshot_restore = M.safe_restore
end

function M.cleanup()
  cancel_pending()
end

return M
