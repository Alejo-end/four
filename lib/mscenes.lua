-- mscenes: scenes, scene morphing, and the safe-state snapshot — the
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
-- grain/clouds, stretch, tape loop, filter, delay, reverb, shimmer, voices).
-- out: the hardware/config layer (midi channel, keys, root note), the SYSTEM
-- levels (in/out/monitor/hp), the capture transports (rec, tape_rec), the
-- master STOP, the motion transport, and the UI selectors (slice cursor).
-- a scene changes how it sounds, never how it's plumbed or whether it's
-- running.
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
--             stretch shape, tape loop, voices
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
  -- playback path + the output->buffer writers. resample only bites on
  -- the next armed take; regen and erode quietly rewrite the buffer, which
  -- is exactly why a scene should be able to pull them back to 0. wear is
  -- just a tone control and morphs freely. (orbit_* stays OUT of every
  -- list: it is a transport, like motion_*.)
  "dry_wet", "resample", "regen", "erode", "wear",
  -- window / scan
  "pos_start", "pos_end", "scan", "pos_jitter",
  -- grain + clouds (the granular character)
  "size", "density", "pitch", "spread", "pan", "grain_level",
  "grain_jitter", "grain_pitch_spread",
  "clouds_pos", "clouds_tex", "clouds_fb", "clouds_lofi",
  -- stretch shape (mode itself is a SWITCH, below)
  "warp_window", "warp_overlaps", "warp_rand",
  -- tape deck (loop bounds ride along, so a scene = a loop region too).
  -- cut_source is the record-SOURCE blend (dry..wet print) — continuous and
  -- slew-safe, so it morphs; it selects what WOULD be written, never writes.
  "tape_rate", "loop_start", "loop_end", "tape_pre", "tape_fade", "cut_source",
  -- polyphonic pad voices
  "voices", "voice_atk", "voice_rel", "pad_level",
  -- the layer decks: their loops, speeds and levels are performance state and
  -- belong in a scene. rec/play are TRANSPORTS and stay out, exactly like
  -- tape_rec — a scene changes how it sounds, never whether it is running.
  -- layer_sel stays out too: it is a UI cursor, like scene_slot.
  "lay1_level", "lay1_rate", "lay1_start", "lay1_end", "lay1_pre",
  "lay2_level", "lay2_rate", "lay2_start", "lay2_end", "lay2_pre",
  -- NB: seq_slice (the PADS edit cursor) is deliberately NOT captured — it's a
  -- UI selector like scene_slot / motion_lane, not sound; a scene shouldn't
  -- move your cursor, and a morph must never lerp it across slices.
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
  "filt_type", "clouds_mode", "grain_shape",
  "delay_sync",   -- a scene remembers whether the delay follows the clock
  "freeze", "pv_freeze", "tape_freeze", "pad_input",
  "tape_reverse",   -- tape direction is a LATCHING state under the punch law
  "lay1_reverse", "lay2_reverse",   -- ...and so is each layer's
  "mode",   -- last of the last: this one respawns the voice
}

-- `tape_reverse` IS captured/recalled. The punch law makes TAPE K3 a LATCHING
-- toggle (a tap holds tape_reverse=1 until tapped again), so it is a real state —
-- and the direction lives ONLY here: Mtape.update_tape_rate does
-- `tape_rate * (tape_reverse==1 and -1 or 1)` with tape_rate kept positive, so a
-- backwards scene is NOT stored in tape_rate. It is in MORPH_EXCLUDE, though: a
-- morph must not flip the tape mid-sweep (a hard event, like a freeze).

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
  pad_input = true, resample = true, regen = true, erode = true,
  voices = true,
  -- mode respawns the SC voice: crossing 0.5 mid-sweep is a click + a voice
  -- born with half-morphed params, not a texture. tape_reverse flips playback
  -- direction: also a hard event, not something to cross gradually. recall
  -- carries both; a morph leaves them (sweep to 1, then K2 RCL to land).
  mode = true, tape_reverse = true,
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
  chaos_live = false, -- a chaos throw is currently held
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

-- THE MORPH'S OTHER END: the sound you were making when you started sweeping.
-- taken on the rising edge out of 0 and dropped when you come home to 0 (or
-- when something else moves the instrument — see invalidate).
--
-- "from HERE to that slot" needs no A/B selector: recall A (K2) then sweep
-- toward B still does the old A->B, and it makes ONE stored scene immediately
-- useful — with a single capture you can mangle the sound and slide back.
local morph_from = nil

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
  -- (a recall, a restore, a throw) just moved it off the line. drop the "from"
  -- with it — we are somewhere new, so the next sweep starts from HERE.
  M.engaged = false
  morph_from = nil
  -- the key throws (OPEN / WASH / INF / HEAL / ...) each cache the values they
  -- displaced, to put back on un-latch. Whatever just moved the instrument
  -- moved those params too, so those caches are now stale: un-latching would
  -- write pre-recall values over the recall. Same reasoning as last_sent above.
  if C and C.throws_forget then C.throws_forget() end
end

-- ===========================================================================
-- feedback — every action says what it did, on screen AND in maiden
-- ===========================================================================
-- a scene action is far too easy to miss. capture moves ONE 13px box; recall
-- of the slot you just captured re-applies the sound you are ALREADY making,
-- so it is inaudible by definition; recall of an empty slot did nothing at all
-- and said nothing about it. that combination reads exactly like "the keys do
-- nothing, there's no sound" — which is what it was reported as, on a page
-- whose code was firing correctly the whole time. a performance page that
-- can't prove it worked is broken, whatever the code does.
--
-- so: one call, two audiences. `msg` is a chip on the page for ~1s; the detail
-- goes to maiden, where you can read the whole story after the fact (the
-- codebase already leans on bring-up prints for exactly this reason).
-- the "- SAME" variants are the important ones: they mean the action landed
-- and NOTHING moved, which is precisely why you can't hear anything.

local function say(msg, detail, slot)
  M.msg, M.msg_at, M.msg_slot = msg, C.frame, slot
  print("mangler: " .. (detail or msg))
end

local function say_recall(slot, n, moved)
  if moved == 0 then
    say("RECALL " .. slot .. " - SAME",
      "scene " .. slot .. " recalled — " .. n .. " params set, NONE moved: the"
      .. " instrument already sounds like this scene, which is why nothing"
      .. " changed. capture a DIFFERENT sound to another slot to hear a recall.",
      slot)
  else
    say("RECALL " .. slot,
      "scene " .. slot .. " recalled — " .. moved .. " of " .. n
      .. " params moved", slot)
  end
end

local function snapshot_ids(ids)
  local t, n = {}, 0
  for i = 1, #ids do
    local id = ids[i]
    if params.lookup[id] then
      t[id] = params:get(id)
      n = n + 1
    end
  end
  return t, n
end

-- region edges: two params that only mean something as a PAIR. setting them
-- one at a time means the consumer reads ONE new edge against ONE old one for
-- an instant — softcut can render up to a block of a region that is neither
-- the old nor the new one (and update_tape_loop's `hi-lo < 0.1` floor turns a
-- crossed pair into a 100ms loop, which jumps the head audibly). so: move the
-- edge that widens the region FIRST, and every intermediate contains a real
-- region instead of a bogus one. `start` key -> `end` key.
local EDGE_PAIRS = { pos_start = "pos_end", loop_start = "loop_end",
                     lay1_start = "lay1_end", lay2_start = "lay2_end" }

-- set one param and report whether the value actually MOVED. the count of
-- moved params is what tells a performer why a recall was silent: 0 moved
-- means the scene and the live sound are already the same.
local function set_moved(id, v)
  local before = params:get(id)
  pset(id, v)
  return params:get(id) ~= before and 1 or 0
end

-- apply a stored table, walking `ids` IN ORDER (timbre -> space -> switches;
-- see the list comment). params missing from the table are skipped, so a
-- scene captured by an older version still recalls what it does know.
-- returns: how many params were set, how many of them actually changed.
local function apply(tbl, ids)
  if not tbl then return 0, 0 end
  local n, moved = 0, 0
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
        if v < params:get(id) then
          moved = moved + set_moved(id, v) + set_moved(partner, pv)
        else
          moved = moved + set_moved(partner, pv) + set_moved(id, v)
        end
        done = done or {}
        done[partner] = true
        n = n + 2
      else
        moved = moved + set_moved(id, v)
        n = n + 1
      end
    end
  end
  M.invalidate()
  return n, moved
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
-- slot 0 is the ◄ cell — the way back. capturing into it marks the
-- safe state, recalling it restores, clearing it forgets. the bank proper
-- stays 1..8; every ◄ caller branches here BEFORE slot_idx clamps.
local function is_back(slot)
  return floor((slot or pget("scene_slot", 1)) + 0.5) < 1
end

function M.capture(slot)
  if is_back(slot) then return M.safe_capture() end
  -- while the orbit runs it keeps re-aiming the selector, so a no-slot
  -- capture (SCENE K3, the scene_capture param) would land in whatever
  -- slot the wander just targeted and overwrite a scene it navigates by.
  -- redirect to the first empty slot; an EXPLICIT slot stays explicit.
  if slot == nil and M.orbit_running then return M.capture_free() end
  slot = slot_idx(slot)
  local t, n = snapshot_ids(SCENE_RECALL_IDS)
  M.slots[slot] = t
  M.invalidate()   -- an endpoint's contents may have just changed under us
  say("SAVED " .. slot,
    "scene " .. slot .. " captured — " .. n .. " params (the whole mangle:"
    .. " window, grain, stretch, tape loop, filter, FX, voices)", slot)
  return true
end

-- recall a slot. opts.immediate = true forces NOW even when the page is set
-- to quantize; otherwise scene_recall_mode decides (NOW / next BEAT / next
-- BAR). a queued recall replaces any other queued recall — last press wins.
function M.recall(slot, opts)
  if is_back(slot) then return M.safe_restore() end
  slot = slot_idx(slot)
  local scene = M.slots[slot]
  if not scene then
    -- an empty slot used to be a silent no-op, which reads as a dead key
    say("SLOT " .. slot .. " EMPTY",
      "scene " .. slot .. " is empty — nothing to recall. K3 (CAP) stores the"
      .. " current sound into it first.", slot)
    return false
  end
  opts = opts or {}
  local mode = floor(pget("scene_recall_mode", 1) + 0.5)
  local beats = QUANT_BEATS[mode] or 0
  cancel_pending()
  if beats > 0 and not opts.immediate then
    M.pending = slot
    say("QUEUED " .. slot,
      "scene " .. slot .. " queued — lands on the next "
      .. (beats > 1 and "bar" or "beat"), slot)
    -- ONE coroutine, always cancelled on replace / restore / cleanup (the
    -- norns clock-race gotcha: a timer resuming a dead thread wedges clock)
    pending_clock = clock.run(function()
      clock.sync(beats)
      pending_clock, M.pending = nil, nil
      M.auto_safe()   -- ◄ = where you just were, even for a queued landing
      say_recall(slot, apply(M.slots[slot], SCENE_RECALL_IDS))
    end)
    return true
  end
  -- every commit auto-captures the pre-state into the ◄ cell — an
  -- undo that never needed arming. (quiet: the recall is the news here.)
  M.auto_safe()
  say_recall(slot, apply(scene, SCENE_RECALL_IDS))
  return true
end

-- advance to the NEXT FILLED slot (cycling, skipping empties) and recall it —
-- the stomp-through-a-set gesture (scene_next, MIDI-map a footswitch). moves
-- the ONE selector so the page/grid/morph all follow, then recalls through
-- the normal path (BEAT/BAR quantize and auto-safe both apply).
function M.next()
  local start = slot_idx()
  for i = 1, NUM_SLOTS do
    local s = ((start - 1 + i) % NUM_SLOTS) + 1
    if M.slots[s] then
      params:set("scene_slot", s)
      return M.recall(s)
    end
  end
  say("NO SCENES", "no filled slots to advance to — CAP stores one first")
  return false
end

-- capture into the first EMPTY slot (the orbit's CAP: bottling a found
-- sound must never overwrite a scene the wander is navigating by)
function M.capture_free()
  for s = 1, NUM_SLOTS do
    if not M.slots[s] then return M.capture(s) end
  end
  say("BANK FULL",
    "all 8 slots hold scenes — clear one to keep the orbit's find")
  return false
end

function M.clear(slot)
  if is_back(slot) then
    local had = M.safe ~= nil
    M.safe = nil
    say(had and "CLEARED <" or "< EMPTY",
      had and "the ◄ way-back state was cleared"
      or "the ◄ cell was already empty")
    return true
  end
  slot = slot_idx(slot)
  local had = M.slots[slot] ~= nil
  -- mutate in place: ctx.scenes points AT this table
  M.slots[slot] = nil
  if M.pending == slot then cancel_pending() end
  M.invalidate()
  say(had and ("CLEARED " .. slot) or ("SLOT " .. slot .. " EMPTY"),
    had and ("scene " .. slot .. " cleared") or
    ("scene " .. slot .. " was already empty"), slot)
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

-- morph `amt` (0..1) of the way from where you were toward `slot`.
--   amt 0   the sound you had when you started sweeping (exactly)
--   amt 1   that slot's stored sound (exactly, for the morph-safe subset)
--   opts.force   send every param even if it hasn't moved
--   opts.linear  interpolate raw values instead of controlspec space
-- returns false when the slot is empty, or when there's nothing to do (parked
-- at 0 with no sweep in progress — at rest the sound is just the sound).
function M.morph(slot, amt, opts)
  if morphing then return false end    -- a param action can never recurse in
  amt = clamp(amt or 0, 0, 1)
  local B = (not is_back(slot)) and M.slots[slot_idx(slot)] or nil
  if not B then
    -- ◄ / an empty slot can't be swept TOWARD — but a sweep already engaged
    -- must still come HOME: re-aim the selector at a dead target mid-sweep
    -- and turning the knob to 0 restores the origin of everything this sweep
    -- displaced (exactly the ids in last_sent). without this the sweep was
    -- stranded: neither able to move nor to land home.
    if not (amt <= 0 and morph_from) then return false end
    morphing = true
    -- walk the morph list IN ORDER (like every other writer here), restoring
    -- only the ids this sweep displaced (the last_sent filter). the region
    -- pairs go WIDENING EDGE FIRST — the same rule apply() and the sweep
    -- follow: restored in bare list order a pair can cross for one write,
    -- and a crossed pair hits the 100ms loop floor and jumps the head.
    local function back(k)
      if last_sent[k] ~= nil and morph_from[k] ~= nil
          and params.lookup[k] then
        pset(k, morph_from[k])
      end
    end
    local rdone
    for i = 1, #SCENE_MORPH_IDS do
      local id = SCENE_MORPH_IDS[i]
      if not (rdone and rdone[id]) then
        local partner = EDGE_PAIRS[id]
        if partner and morph_from[id] ~= nil and params.lookup[id]
            and morph_from[partner] ~= nil and params.lookup[partner] then
          if morph_from[id] < params:get(id) then back(id); back(partner)
          else back(partner); back(id) end
          rdone = rdone or {}
          rdone[partner] = true
        else
          back(id)
        end
      end
    end
    morphing = false
    M.invalidate()   -- forget the sweep: we are home
    return true
  end
  opts = opts or {}
  if amt <= 0 and not morph_from then return false end
  -- rising edge out of 0: where we are RIGHT NOW is the other end of the sweep
  local A = morph_from or snapshot_ids(SCENE_MORPH_IDS)
  morph_from = A
  -- at the ends, land EXACTLY on the stored values (no deadband rounding)
  local force = opts.force or amt <= 0 or amt >= 1
  morphing = true
  local ids = SCENE_MORPH_IDS

  -- one param's step of the sweep.
  -- skip anything either side doesn't have (older capture, missing param).
  -- the Octatrack rule: a param IDENTICAL at both ends is not the morph's to move —
  -- a hand riding such a knob mid-sweep stays live even through the forced
  -- ends, instead of being stomped back (a scene only claims what differs).
  -- an id THIS sweep already displaced (last_sent, e.g. before a re-aim)
  -- still lands exactly at both ends.
  local function emit(id, va, vb)
    if va == nil or vb == nil or not params.lookup[id] then return end
    if not (va ~= vb or (force and last_sent[id] ~= nil)) then return end
    local v, tn = morph_value(id, va, vb, amt, opts.linear)
    if v == nil then return end
    local key = tn or v          -- continuous: compare norms; discrete: values
    local last = last_sent[id]
    local fire = force or last == nil
      or (tn and abs(tn - last) >= MORPH_EPS)
      or (not tn and v ~= last)
    if fire then
      pset(id, v)
      last_sent[id] = key
    end
  end

  local done                     -- edge partners already written this pass
  for i = 1, #ids do
    local id = ids[i]
    if not (done and done[id]) then
      local partner = EDGE_PAIRS[id]
      if partner and params.lookup[partner]
          and A[id] ~= nil and B[id] ~= nil
          and A[partner] ~= nil and B[partner] ~= nil then
        -- a REGION's two edges move together, and the WIDENING one goes first —
        -- the same rule apply() follows, and for the same reason: written in
        -- list order a sweep can momentarily cross the pair, and a crossed pair
        -- hits the 100ms minimum-length floor, which jumps the softcut head.
        -- The morph runs this 15 times a second, so it meets the hazard far
        -- more often than a recall does.
        local nv = morph_value(id, A[id], B[id], amt, opts.linear)
        if nv ~= nil and nv < params:get(id) then
          emit(id, A[id], B[id]); emit(partner, A[partner], B[partner])
        else
          emit(partner, A[partner], B[partner]); emit(id, A[id], B[id])
        end
        done = done or {}
        done[partner] = true
      else
        emit(id, A[id], B[id])
      end
    end
  end
  morphing = false
  M.engaged = amt > 0   -- the morph is what's driving the sound... unless home
  if amt <= 0 then
    -- home again, exactly where you started. forget the "from" so the NEXT
    -- sweep departs from wherever you are by then, and forget what we sent so
    -- it re-asserts from scratch.
    morph_from = nil
    for k in pairs(last_sent) do last_sent[k] = nil end
  end
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

-- ===========================================================================
-- orbit: the instrument wanders the scene bank by itself
-- ===========================================================================
-- one leg at a time: pick a filled slot, ramp the morph partway toward it
-- (orbit_reach) over orbit_drift seconds, park there, pick another. parking
-- means dropping the sweep origin without applying anything, so the next leg
-- departs from the in-between sound the last one found. everything goes
-- through the same scene_slot and scene_morph_amt params a hand would use:
-- the SCENE page shows the wander live, and CAP bottles any moment of it.
-- with one filled slot each leg halves the remaining distance toward it;
-- with none the orbit idles. math.random stays out of the draw path.

local orbit = { on = false, leg_start = 0, leg_len = 1 }

local function orbit_park()
  M.invalidate()
  pset("scene_morph_amt", 0)   -- silent: with no sweep origin this writes nothing
end

local function orbit_new_leg()
  local filled, cur = {}, slot_idx()
  for s = 1, NUM_SLOTS do
    if M.slots[s] and s ~= cur then filled[#filled + 1] = s end
  end
  if #filled == 0 and not M.slots[cur] then return false end
  local target = #filled > 0 and filled[math.random(#filled)] or cur
  pset("scene_slot", target)
  orbit.leg_start = C.frame
  orbit.leg_len = math.max(2, math.floor(pget("orbit_rate", 12) * (C.FPS or 15)))
  return true
end

function M.orbit_set(on)
  orbit.on = on
  M.orbit_running = on   -- read by capture(); declared here, order-safe
  if on then
    orbit_park()               -- depart from wherever we stand right now
    orbit_new_leg()
  else
    orbit_park()               -- stop and keep the sound the orbit found
  end
end

local function orbit_tick()
  if not orbit.on then return end
  local t = (C.frame - orbit.leg_start) / orbit.leg_len
  if t >= 1 then
    orbit_park()
    if not orbit_new_leg() then return end
    t = 0
  end
  pset("scene_morph_amt", pget("orbit_reach", 0.5) * t)
end

-- one per redraw frame, from the existing 15fps clock in mangler.lua.
-- the target is simply the SELECTED slot — the same one K2 recalls and K3
-- captures into. one selector, three jobs.
function M.tick()
  orbit_tick()                 -- may set the morph params, marking dirty
  if not dirty then return end
  dirty = false
  M.morph(pget("scene_slot", 1), pget("scene_morph_amt", 0))
end

-- ===========================================================================
-- safe snapshot — the undo for live experimentation
-- ===========================================================================

function M.safe_capture()
  local t, n = snapshot_ids(SAFE_SNAPSHOT_IDS)
  M.safe = t
  say("MARKED <",
    "way-back state marked — " .. n .. " params. select the ◄ cell and K2"
    .. " brings this exact sound back.")
  return true
end

-- the quiet version: every commit recall / chaos throw parks the pre-state
-- in ◄ without stealing the headline from the action itself
function M.auto_safe()
  M.safe = snapshot_ids(SAFE_SNAPSHOT_IDS)
end

-- back to the last known good state, now. control state only: it does not
-- touch the buffer, the tape audio, or held voices — this is an undo for
-- knobs, not a panic mute (K1+K2 STOP is the mute, and it stays yours).
function M.safe_restore()
  if not M.safe then
    say("NO SAFE STATE",
      "no safe state marked yet — K1+K3 (SAFE) on the SCENE page marks one")
    return false
  end
  cancel_pending()   -- a queued recall must not undo the rescue a beat later
  local n, moved = apply(M.safe, SAFE_SNAPSHOT_IDS)
  M.chaos_live = false
  say(moved == 0 and "UNDO - SAME" or "UNDO",
    "safe state restored — " .. moved .. " of " .. n .. " params moved")
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
  -- never strand the performer: the throw parks where-you-were in ◄, so the
  -- release always has somewhere to land (and ◄ is always the LAST ground)
  M.auto_safe()
  for i = 1, #CHAOS do
    local c = CHAOS[i]
    throw(c[1], c[2], c[3])
  end
  local s = math.random() < 0.5 and SCAN_REV or SCAN_FWD
  throw("scan", s[1], s[2])
  M.invalidate()
  M.chaos_live = true
  say("CHAOS", "chaos thrown — release to land back on the safe state")
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
  -- a LOAD is authoritative: cancel any queued (BEAT/BAR) recall FIRST, before
  -- any early return — otherwise a coroutine armed just before the load survives
  -- and fires an old slot over the freshly loaded session a beat later.
  cancel_pending()
  -- the load is authoritative even when NO scene file follows: a morph_from /
  -- last_sent left engaged would re-derive the morph from the PRE-load sound
  -- on the next knob move. (covers every path below, including the early
  -- returns — nothing after this touches the morph state again.)
  M.invalidate()
  local path = path_for(number)
  -- no scene file (a pset from before scenes existed): leave the bank alone,
  -- exactly like mtape leaves the tape audio alone when there's no wav
  if not util.file_exists(path) then return end
  local ok, t = pcall(tab.load, path)
  if not (ok and type(t) == "table" and type(t.slots) == "table") then
    print("mangler: scene file unreadable — " .. tostring(t))
    return
  end
  for i = 1, NUM_SLOTS do
    M.slots[i] = type(t.slots[i]) == "table" and t.slots[i] or nil
  end
  -- CLEAR safe when the loaded pset has none, like the slots — otherwise the
  -- previous session's ◄/safe-state bleeds into this one and its recall jumps
  -- the instrument to a sound this session never captured.
  M.safe = type(t.safe) == "table" and t.safe or nil
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
  ctx.scene = M          -- the module, like ctx.motion
  ctx.scenes = M.slots   -- the scene table itself (mutated in place, never
                         -- reassigned, so this ref can't go stale)
  -- the named helpers the grid's CAP/CLR modifiers call (everything else
  -- drives the scene_* params directly, so those are the only two exposed)
  ctx.scene_capture = M.capture
  ctx.scene_clear = M.clear
end

function M.cleanup()
  cancel_pending()
end

return M
