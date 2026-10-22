-- mscenes: scenes, scene morphing, and the safe-state snapshot — the
-- "remember this / go back to that" layer.
--
-- three features, one data model:
--   SCENES   8 slots, each a flat map { param_id = value } captured from the
--            live params. recall writes them back through params:set, so the
--            engine, the tape and the display all follow for free — a scene
--            is not a second source of truth, it's a photograph of the one
--            that exists.
--   MORPH    a continuous sweep from the sound you have now toward a stored
--            slot, over the subset of params that can be interpolated. one
--            knob (scene_morph_amt) moves the whole instrument along that line.
--   SAFE     one "last known good" snapshot + an instant restore. capture it
--            before you do something reckless (see the chaos throw below);
--            restore drops you straight back on your feet.
--
-- NOTHING here stores audio. scenes are control state only: a recall does not
-- bring back the take you have since overdubbed (that's what PSETs + the tape
-- wav are for, see mtape). that's also what makes it cheap — 8 slots is ~600
-- numbers, and a recall is ~80 params:set calls.
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

local floor, abs, min, max = math.floor, math.abs, math.min, math.max

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
  "lay1_fade", "lay1_width",
  "lay2_level", "lay2_rate", "lay2_start", "lay2_end", "lay2_pre",
  "lay2_fade", "lay2_width",
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
  "win_beats",    -- ...and whether the window's length does
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
-- rest. (the SCENE page says so: see M.unlanded + the "K2 TO LAND THE REST" cue.)
local MORPH_EXCLUDE = {
  freeze = true, pv_freeze = true, tape_freeze = true,
  pad_input = true, resample = true, regen = true, erode = true,
  voices = true,
  -- mode respawns the SC voice: crossing 0.5 mid-sweep is a click + a voice
  -- born with half-morphed params, not a texture. tape_reverse flips playback
  -- direction: also a hard event, not something to cross gradually. recall
  -- carries both; a morph leaves them (sweep to 1, then K2 RCL to land).
  mode = true, tape_reverse = true,
  -- the window lock switching mid-sweep re-cuts the window in one frame
  win_beats = true,
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

-- WHAT A SCENE DELIBERATELY LEAVES OUT — the other half of the recall list.
-- membership is TOTAL: tools/test_control.lua asserts every param in the
-- paramset is in SCENE_RECALL_IDS or here, never neither and never both, so
-- a NEW param cannot silently miss the decision (the defect that recurred:
-- purity, FINE_IDS, RATE_IDS and these lists each missed a layers param).
-- adding a param now FAILS the harness until it is placed on one side.
local SCENE_EXCLUDE = {
  -- the master + STOP: a scene must never rewrite stage volume or unmute
  -- (out_level is the ONE of these the safe snapshot takes — SAFE_EXTRA_IDS)
  "out_level", "stop_all",
  -- capture transports + write plumbing: a scene changes how it sounds,
  -- never whether or what it is recording
  "rec", "tape_rec", "rec_level", "pre_level", "clear_rec", "sample_file",
  "rec_wait", "rec_thresh",
  "take_undo", "undo_keep",
  "export_take", "take_tighten", "print_take", "print_len",
  "pad_chop", "pad_even",
  "lay1_rec", "lay1_play", "lay2_rec", "lay2_play",
  "lay1_file", "lay2_file", "layer_wet",
  "lay1_snap", "lay2_snap",   -- a gesture, not state: it acts on the loop now
  -- UI cursors + the per-pad lock EDITORS (the locks themselves ride the
  -- padlock pset, not scenes)
  "seq_slice", "layer_sel", "pad_voice", "pad_pitch",
  -- config / keys
  "keys_enable", "midi_channel", "root_note", "kb_octave", "pitch_quant",
  -- the other machines' transports, and scene's own params (NEVER capture
  -- scene_*: scene_morph_amt's action re-fires the morph)
  "motion_rec", "motion_play", "motion_lane", "motion_depth", "motion_len",
  "orbit_on", "orbit_rate", "orbit_reach",
  -- the sequencer is a machine like the orbit: its run, and the pattern it
  -- generates, are left where they are by a scene
  "step_run", "step_div", "step_len", "step_fill", "step_order",
  "step_chance", "step_gate",
  -- the modulators: machines too. A scene moves the knobs they ride on
  "lfo1_target", "lfo1_shape", "lfo1_period", "lfo1_rate", "lfo1_depth",
  "lfo2_target", "lfo2_shape", "lfo2_period", "lfo2_rate", "lfo2_depth",
  "scene_slot", "scene_morph_amt", "scene_recall_mode", "scene_scope",
  "scene_glide",
  "scene_capture",
  "scene_recall", "scene_next", "scene_clear", "scene_safe_capture",
  "scene_safe_restore", "chaos_throw",
}

-- ===========================================================================
-- module state
-- ===========================================================================

local M = {
  slots = {},         -- slots[1..8] = { id = value } (nil = empty)
  safe = nil,         -- the safe snapshot, same shape
  pending = nil,      -- slot waiting on a quantized recall (nil = none)
  chaos_live = false, -- a chaos throw is currently held
  -- exposed for the harness's classification checks
  SCENE_RECALL_IDS = SCENE_RECALL_IDS,
  SCENE_EXCLUDE = SCENE_EXCLUDE,
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
local GLIDE_MODE = 4              -- ...and GLIDE (scene_glide beats, then land)

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
-- the instrument, and its origin only while the sweep is the thing driving
-- the sound. reset_morph drops both, so the next amount move departs from
-- wherever we are by then. A capture or a clear needs only this: it changes
-- what a slot holds, and moves no param.
local function reset_morph()
  for k in pairs(last_sent) do last_sent[k] = nil end
  M.engaged = false
  morph_from = nil
end

-- the INSTRUMENT moved (a recall, a restore, a chaos throw, a pset load):
-- reset the morph, and forget the key throws too. OPEN / WASH / INF / HEAL
-- each cache the values they displaced, to put back on un-latch; whatever
-- just moved the instrument moved those params as well, so un-latching would
-- write pre-recall values over the recall. A capture must NOT do this: it
-- moves nothing, and latch-OPEN, capture, un-latch is how a variant is built.
function M.invalidate()
  reset_morph()
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
M.EDGE_PAIRS = EDGE_PAIRS   -- the harness asserts every _start/_end pair joins

-- A STORED window is clamped to the material before it is applied. Scenes
-- capture pos_start/pos_end verbatim, but the take may be shorter by the time
-- the scene comes back. The classic trap: capture a scene before recording
-- (window = the whole 60s buffer), record a 4s phrase (the rec-stop snaps the
-- window to it), recall the scene, and the window reopens over ~56 seconds of
-- nothing, so what you were listening to comes around once a minute. Beyond
-- C.take_len (the content high-water mark, from frame 0) there is silence BY
-- DEFINITION, so clamping a stored edge into it can only remove silence,
-- never sound. Only STORED values pass through here: a recall, a safe
-- restore, a morph target. Live values stay exact, so the encoder can still
-- open the window wherever it likes, and a sweep coming home restores the
-- origin verbatim (morph_from bypasses this).
--
-- The LOOP DECKS have the same trap: capture a scene while a layer is empty
-- (its loop 0..1), record a 4s pass (the loop closes around it), recall, and
-- the loop reopened over 60 seconds of nothing. A deck's material does not
-- start at 0, so the decks clamp to the EXTENT that was written (C.material:
-- lo, hi in the deck's own 0..1), and only when the stored loop is more than
-- TWICE the material and overlaps it. A loop's LENGTH is musical (SNAP puts
-- it on a grid), so a loop that is merely a little longer than what was
-- played into it is left alone; and a stored loop entirely elsewhere points
-- at something we cannot know about, and stays exactly as stored.
local WINDOW_IDS = { pos_start = true, pos_end = true }
local EXTENT_OF = {
  loop_start = "tape", loop_end = "tape",
  lay1_start = "lay1", lay1_end = "lay1", lay2_start = "lay2", lay2_end = "lay2",
}
-- the same pairs, both ways round (shared with motion replay)
local PARTNER = {}
for a, b in pairs(EDGE_PAIRS) do PARTNER[a], PARTNER[b] = b, a end
M.PARTNER = PARTNER

local function clamp_stored(id, v, tbl)
  if v == nil then return v end
  if WINDOW_IDS[id] then
    local tl = (C and C.wave_any and C.take_len) or 0
    if tl <= 0.002 or tl >= 0.999 then return v end   -- no/full material: exact
    local cap = id == "pos_end" and tl or (tl - 0.002)
    return v < cap and v or cap
  end
  local key = EXTENT_OF[id]
  if not (key and tbl and C and C.material) then return v end
  local mlo, mhi = C.material(key)
  if not mlo then return v end                      -- nothing known: exact
  local is_start = EDGE_PAIRS[id] ~= nil
  local s, e = v, tbl[PARTNER[id]]
  if not is_start then s, e = e, v end
  if s == nil or e == nil or s > e then return v end
  if not (s < mhi and e > mlo) then return v end    -- elsewhere: exact
  if e - s < 2 * (mhi - mlo) then return v end       -- near the material: exact
  local ns, ne = max(s, mlo), min(e, mhi)
  if ne - ns < 0.002 then return v end
  return is_start and ns or ne
end

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
    local v = clamp_stored(id, tbl[id], tbl)
    if v ~= nil and params.lookup[id] and not (done and done[id]) then
      local partner = EDGE_PAIRS[id]
      local pv = partner and clamp_stored(partner, tbl[partner], tbl)
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

-- a recall still on its way (queued for a beat, or gliding) is forgotten by
-- anything that lands something else: another recall, the way back, a load
local function cancel_pending()
  if pending_clock then clock.cancel(pending_clock) end
  pending_clock, M.pending = nil, nil
  M.glide = nil
end

-- A scene LANDED (a recall, the way back): it IS the new LIVE. ONE place does
-- what every landing needs, because each landing path used to remember a
-- different subset of it:
--   the morph amount goes home. apply() has already dropped the sweep's
--     origin, so writing 0 moves nothing; left up, the rail lied and merely
--     selecting another slot at rest jumped the sound toward it.
--   a held chaos throw ENDS. its release restores ◄, and a recall made
--     mid-hold has just re-marked ◄ with the chaos state, so releasing the
--     footswitch would drag you back onto the madness over the scene you chose.
local function land(tbl, ids)
  local n, moved = apply(tbl, ids)
  M.chaos_live = false
  if pget("scene_morph_amt", 0) > 0 then pset("scene_morph_amt", 0) end
  return n, moved
end

-- the orbit's state (declared here: capture reads it)
local orbit = { on = false, live = false, leg_start = 0, leg_len = 1,
                wrote = nil, hand_at = nil }
local capture_free   -- defined below capture, which it calls

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
  if slot == nil and orbit.on then return capture_free() end
  slot = slot_idx(slot)
  -- capture SCOPE (Octatrack-style): ALL = the whole mangle; FX = just the
  -- wet path (SPACE_IDS: filter, drive, delay, reverb, shimmer), so a slot
  -- becomes an effects preset that recalls and morphs OVER whatever material
  -- and voice you have at the time. apply() skips ids a slot does not carry,
  -- so partial slots were always legal; this makes them a supported gesture.
  local fx_only = floor(pget("scene_scope", 1) + 0.5) == 2
  local t, n = snapshot_ids(fx_only and SPACE_IDS or SCENE_RECALL_IDS)
  M.slots[slot] = t
  reset_morph()    -- the target's contents may have just changed under a sweep
  say("SAVED " .. slot .. (fx_only and " FX" or ""),
    "scene " .. slot .. " captured — " .. n .. (fx_only
      and " params (FX only: filter, drive, delay, reverb, shimmer)"
      or " params (the whole mangle: window, grain, stretch, tape loop,"
      .. " filter, FX, voices)"), slot)
  return true
end

-- recall a slot. scene_recall_mode decides when it lands (NOW / next BEAT /
-- next BAR). a queued recall replaces any other queued recall — last press
-- wins.
function M.recall(slot)
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
  local mode = floor(pget("scene_recall_mode", 1) + 0.5)
  local beats = QUANT_BEATS[mode] or 0
  cancel_pending()
  if mode == GLIDE_MODE then
    -- GLIDE: the morph sweeps there over scene_glide beats, then the scene
    -- LANDS (the holds, routing and writers a morph never moves included).
    -- An Octatrack-style crossfade instead of a jump. ◄ marks where it began.
    local b = pget("scene_glide", 4)
    if floor(pget("scene_slot", 1) + 0.5) ~= slot then pset("scene_slot", slot) end
    M.auto_safe()
    -- a held chaos throw ends HERE, as land() ends it for the other modes:
    -- ◄ now holds the chaos state, and the footswitch's release would restore
    -- it over the scene this glide is heading for
    M.chaos_live = false
    M.glide = { slot = slot, from = C.frame, a0 = pget("scene_morph_amt", 0),
      frames = math.max(1, floor(b * 60 / (C.tempo and C.tempo() or 120)
        * (C.FPS or 15) + 0.5)) }
    say("GLIDE " .. slot, "scene " .. slot .. " gliding in over " .. b
      .. " beats, then it lands", slot)
    return true
  end
  if beats > 0 then
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
      say_recall(slot, land(M.slots[slot], SCENE_RECALL_IDS))
    end)
    return true
  end
  -- every commit auto-captures the pre-state into the ◄ cell — an
  -- undo that never needed arming. (quiet: the recall is the news here.)
  M.auto_safe()
  say_recall(slot, land(scene, SCENE_RECALL_IDS))
  return true
end

-- advance to the NEXT FILLED slot (cycling, skipping empties) and recall it —
-- the stomp-through-a-set gesture (scene_next, MIDI-map a footswitch). moves
-- the ONE selector so the page/grid/morph all follow, then recalls through
-- the normal path (BEAT/BAR quantize and auto-safe both apply).
function M.next()
  -- from the ◄ cell the next slot is 1 (slot_idx would clamp ◄ to 1 and
  -- start the search at 2)
  local start = is_back() and 0 or slot_idx()
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
capture_free = function()
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
  -- the orbit re-aims the selector every leg, so a no-slot clear (the
  -- scene_clear footswitch) would erase whatever the wander picked. The key
  -- path passes the slot it pressed on; an unaddressed clear refuses.
  if slot == nil and orbit.on then
    say("ORBIT RUNNING", "the orbit is moving the selector — stop it (orbit run)"
      .. " before clearing a slot from the footswitch")
    return false
  end
  slot = slot_idx(slot)
  local had = M.slots[slot] ~= nil
  M.slots[slot] = nil   -- in place: the grid and the page read this table
  if M.pending == slot or (M.glide and M.glide.slot == slot) then
    cancel_pending()
  end
  reset_morph()
  say(had and ("CLEARED " .. slot) or ("SLOT " .. slot .. " EMPTY"),
    had and ("scene " .. slot .. " cleared") or
    ("scene " .. slot .. " was already empty"), slot)
  return true
end

-- ===========================================================================
-- morph — from where you are toward a slot, one knob
-- ===========================================================================
-- continuous params interpolate in the controlspec's OWN (warped) space
-- (ctx.warped_lerp): cutoff 20 -> 20000 is exponential, so a raw lerp would
-- sit at "nearly open" for the whole second half of the sweep.
-- numbers (voices, warp_overlaps) lerp and land on integers; options and
-- binaries can't be half-switched, so they flip at the midpoint (amt >= 0.5).

local function morph_value(id, va, vb, amt)
  local p = lookup(id)
  if not p then return nil end
  local cs = p.controlspec
  if cs then
    -- the normalized target doubles as the deadband key below: if a param is
    -- identical in A and B, tn never moves and it never gets sent at all
    return C.warped_lerp(cs, va, vb, amt)
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

-- the sweep in progress, read by emit(). Module state rather than a closure
-- per call: the morph runs every frame while a sweep or the orbit moves, and
-- this is the hot path that is meant to allocate nothing.
local sw_amt, sw_force = 0, false
local pair_done = {}       -- edge partners already written this pass (reused)

-- one param's step of the sweep. `vb` arrives already clamped to the
-- material (clamp_stored).
--   va nil              the origin never had it (an older capture): skip.
--   vb nil              the CURRENT aim does not carry it (an FX-only slot,
--                       a partial preset slot). If this sweep already moved it
--                       under an earlier aim, its line now runs from the
--                       origin to itself, so it goes home; otherwise skip.
--   va == vb            the Octatrack rule: a param identical at both ends is
--                       not the morph's to move, so a hand riding it stays
--                       live, even through the forced ends. An id this sweep
--                       already displaced (last_sent) still tracks the line.
local function emit(id, va, vb)
  if va == nil or not params.lookup[id] then return end
  if vb == nil then
    if last_sent[id] == nil then return end
    vb = va
  end
  if va == vb and last_sent[id] == nil then return end
  local v, tn = morph_value(id, va, vb, sw_amt)
  if v == nil then return end
  local key = tn or v          -- continuous: compare norms; discrete: values
  local last = last_sent[id]
  local fire = sw_force or last == nil
    or (tn and abs(tn - last) >= MORPH_EPS)
    or (not tn and v ~= last)
  if fire then
    pset(id, v)
    last_sent[id] = key
  end
end

-- morph `amt` (0..1) of the way from where you were toward `slot`.
--   amt 0   the sound you had when you started sweeping (exactly)
--   amt 1   that slot's stored sound (exactly, for the morph-safe subset)
-- returns false when the slot is empty, or when there's nothing to do (parked
-- at 0 with no sweep in progress — at rest the sound is just the sound).
function M.morph(slot, amt)
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
  if amt <= 0 and not morph_from then return false end
  -- rising edge out of 0: where we are RIGHT NOW is the other end of the sweep
  local A = morph_from or snapshot_ids(SCENE_MORPH_IDS)
  morph_from = A
  -- at the ends, land EXACTLY on the stored values (no deadband rounding)
  sw_amt, sw_force = amt, amt <= 0 or amt >= 1
  morphing = true
  local ids = SCENE_MORPH_IDS
  for k in pairs(pair_done) do pair_done[k] = nil end
  for i = 1, #ids do
    local id = ids[i]
    if not pair_done[id] then
      local partner = EDGE_PAIRS[id]
      local bv = clamp_stored(id, B[id], B)   -- a stored loop aims at material
      if partner and params.lookup[partner]
          and A[id] ~= nil and B[id] ~= nil
          and A[partner] ~= nil and B[partner] ~= nil then
        -- a REGION's two edges move together, and the WIDENING one goes first —
        -- the same rule apply() follows, and for the same reason: written in
        -- list order a sweep can momentarily cross the pair, and a crossed pair
        -- hits the 100ms minimum-length floor, which jumps the softcut head.
        -- The morph runs this 15 times a second, so it meets the hazard far
        -- more often than a recall does.
        local pv = clamp_stored(partner, B[partner], B)
        local nv = morph_value(id, A[id], bv, amt)
        if nv ~= nil and nv < params:get(id) then
          emit(id, A[id], bv); emit(partner, A[partner], pv)
        else
          emit(partner, A[partner], pv); emit(id, A[id], bv)
        end
        pair_done[partner] = true
      else
        emit(id, A[id], bv)
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
-- recall lands them. drives the SCENE page's "K2 TO LAND THE REST" cue, which
-- exists so `morph(1) ~= recall(B)` is visible instead of mysterious. The ◄
-- cell is never "unlanded": K2 there is the way back, not a landing.
function M.unlanded(slot)
  if is_back(slot) then return false end
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

-- (`orbit` itself is declared above capture, which reads it)

-- parking moves no param: it only drops the sweep's origin, so the next leg
-- departs from wherever this one left the sound. It must not forget the key
-- throws (it is not the instrument moving), and it writes the morph amount
-- home silently (with no origin, 0 sends nothing).
local function orbit_park()
  reset_morph()
  pset("scene_morph_amt", 0)
end

local orbit_filled = {}   -- reused: the orbit looks for a target every leg
local function orbit_new_leg()
  local filled, cur = orbit_filled, slot_idx()
  for k = #filled, 1, -1 do filled[k] = nil end
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
  orbit.wrote, orbit.hand_at = nil, nil
  orbit_park()                 -- depart from (or stop on) wherever we stand
  orbit.live = on and orbit_new_leg()
end

-- the orbit YIELDS to anything else that moves the morph amount: a hand on
-- K1+E1 or a MIDI fader, the RCL peek, a glide, a landing. It watches for a
-- value it did not write, stands still while that keeps happening, and two
-- seconds after it stops parks where the other hand left the sound and
-- starts a fresh leg from there.
local ORBIT_YIELD = 2          -- seconds of quiet before the wander resumes

-- `live` = a leg is actually running. With no filled slot to aim at there is
-- no leg: the orbit looks for a target each frame and touches nothing.
local function orbit_tick()
  if not orbit.on then return end
  local amt = pget("scene_morph_amt", 0)
  -- a held RCL peek parks the amount at 1 and stops moving it, but its
  -- release still needs the sweep's origin to go home: until it is home, the
  -- peek is a hand on the morph even while the value stands still
  if (orbit.wrote ~= nil and abs(amt - orbit.wrote) > 1e-9)
      or C.peek_on or C.peek_back then
    orbit.hand_at = C.frame
  end
  orbit.wrote = amt
  if orbit.hand_at then
    if C.frame - orbit.hand_at < ORBIT_YIELD * (C.FPS or 15) then return end
    orbit.hand_at = nil
    orbit_park()
    orbit.wrote = pget("scene_morph_amt", 0)
    orbit.live = false
  end
  local t = (C.frame - orbit.leg_start) / orbit.leg_len
  if t >= 1 or not orbit.live then
    if orbit.live then orbit_park() end
    orbit.live = orbit_new_leg()
    orbit.wrote = pget("scene_morph_amt", 0)
    if not orbit.live then return end
    t = 0
  end
  pset("scene_morph_amt", pget("orbit_reach", 0.5) * t)
  orbit.wrote = pget("scene_morph_amt", 0)
end

-- a GLIDE in progress: ramp the morph from where it stood to 1 over its
-- frames, then land the scene. A hand on the morph or the selector mid-glide
-- wins: the glide stops and the sound stays where the hand put it.
local function glide_tick()
  local g = M.glide
  if not g then return end
  if floor(pget("scene_slot", 1) + 0.5) ~= g.slot
      or (g.wrote ~= nil and abs(pget("scene_morph_amt", 0) - g.wrote) > 1e-9) then
    M.glide = nil
    say("GLIDE STOPPED", "the glide to scene " .. g.slot .. " stopped: the morph"
      .. " or the selected slot was moved by hand", g.slot)
    return
  end
  local t = (C.frame - g.from) / g.frames
  if t >= 1 then
    M.glide = nil
    say_recall(g.slot, land(M.slots[g.slot], SCENE_RECALL_IDS))
    return
  end
  pset("scene_morph_amt", g.a0 + (1 - g.a0) * t)
  g.wrote = pget("scene_morph_amt", 0)
end

-- one per redraw frame, from the existing 15fps clock in mangler.lua.
-- the target is simply the SELECTED slot — the same one K2 recalls and K3
-- captures into. one selector, three jobs.
function M.tick()
  glide_tick()                 -- a glide moves the morph before the orbit looks
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
      "no safe state marked yet — select the ◄ cell and K3 (CAP) marks one;"
      .. " every recall and every chaos throw also marks it for you")
    return false
  end
  cancel_pending()   -- a queued recall must not undo the rescue a beat later
  local n, moved = land(M.safe, SAFE_SNAPSHOT_IDS)
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
M.CHAOS = CHAOS   -- exposed so the harness can flag an entry for a dead param

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
  ctx.scene = M          -- the module, like ctx.motion. its bank is M.slots,
                         -- mutated in place and never reassigned
end

function M.cleanup()
  cancel_pending()
end

return M
