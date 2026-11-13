-- render_pages.lua — offscreen renderer for mangler's norns screen.
-- Stubs the norns Lua environment, loads the REAL four.lua, drives a
-- believable performance scenario (a take, a tape loop, live FX), then
-- exports every UI page as a PGM framebuffer (0..15 levels -> 0..255).
--
-- usage: lua render_pages.lua <four.lua path> <outdir> <prefix> [variant]
--   variant "empty": empty-buffer states (TAKE + VOICE with nothing recorded)
--   variant "grain": VOICE in GRAIN mode across its param extremes (size/
--                    density/spread/jitter/pan edges, mode OFF)
--   variant "filter": FILTER page across its types and resonance extremes

local MANGLER = arg[1] or "four.lua"
local OUTDIR = arg[2] or "."
local PREFIX = arg[3] or "shot"
local VARIANT = arg[4]
local EMPTY = VARIANT == "empty"
local GRAINX = VARIANT == "grain"
local FILTX = VARIANT == "filter"
local TRACK2 = VARIANT == "track2"   -- four: VOICE 2 and FILTER 2


-- the offscreen norns lives in env.lua so more than one harness can use it.
-- SCENARIO stays OUR local and env reads it through the getter — see the note
-- at the top of env.lua for why that is not ceremony.
local SCENARIO
local REPO_DIR = (arg[0]:match("(.*)/test/uisim/") or ".")
local env = dofile(REPO_DIR .. "/test/uisim/env.lua")
local _h = env.install{ dir = OUTDIR, scenario = function() return SCENARIO end }
local export, run_ticks = _h.export, _h.run_ticks
local push = _h.push

-- ============================================================================
-- load the real script + drive the scenario
-- ============================================================================

-- mangler is split across lib/*.lua modules pulled in with norns' include();
-- resolve those from the repo the mangler path points into. (the midigrid
-- include stays safely dead here: its util.file_exists guard returns false,
-- and the pcall would swallow the dofile error anyway.)
local REPO = MANGLER:match("^(.*)/") or "."
include = function(p) return dofile(REPO .. "/" .. p .. ".lua") end

-- deterministic renders: the scenes' chaos and the orbit draw from
-- math.random, and seeding here makes galleries diffable and the dist build
-- byte-checkable
math.randomseed(1)

dofile(MANGLER)
init()

-- system params: owned by norns on device; mangler references, never adds
params:add_control("input_level", "input", controlspec.new(0, 1, "lin", 0, 0.8, ""))
params:add_control("output_level", "output", controlspec.new(0, 1, "lin", 0, 0.7, ""))
params:add_control("monitor_level", "monitor", controlspec.new(0, 1, "lin", 0, 0.45, ""))
params:add_control("headphone_gain", "hp", controlspec.new(0, 1, "lin", 0, 0.6, ""))

-- the gallery (gallery.py) wants DELAY and REVERB with something in them: a fresh
-- script sends nothing, and both pages then say NO SEND
if os.getenv("FOUR_SENDS") then
  params:set("fx_dly", 1); params:set("fx_rev", 1)
end



if EMPTY then
  SCENARIO = function(t)
    push("play_phase", (t * 0.011) % 1)
    push("rec_phase", 0)
    push("rec_amp", 0)
    push("amp_in_l", 0.02)
    push("amp_in_r", 0.02)
    push("amp_out_l", 0)
    push("amp_out_r", 0)
  end
else
  SCENARIO = function(t)
    -- a take: rec from t=10 to t=150, write head walks 0.05 -> 0.55
    if t == 10 then params:set("rec", 1) end
    if t == 150 then params:set("rec", 0) end
    if t == 20 then params:set("tape_rec", 1) end
    if t == 140 then params:set("tape_rec", 0) end
    if t == 155 then
      params:set("delay_mix", 0.35)
      params:set("delay_fb", 0.45)
      params:set("delay_time", 0.32)
      params:set("rev_mix", 0.28)
      params:set("rev_size", 0.62)
      params:set("cutoff", 1400)
      params:set("resonance", 0.35)
      params:set("pitch", 2 ^ (5 / 12))
      params:set("density", 22)
      params:set("size", 0.12)
    end
    local rp = 0.05 + math.min(t > 10 and (t - 10) or 0, 140) * 0.0036
    push("rec_phase", rp)
    local env = math.abs(math.sin(t * 0.31)) * (0.6 + 0.4 * math.sin(t * 0.077))
    push("rec_amp", 0.05 + 0.5 * math.max(env, 0))
    push("amp_in_l", 0.04 + 0.4 * math.max(env, 0))
    push("amp_in_r", 0.04 + 0.38 * math.max(math.sin(t * 0.29), 0))
    push("amp_out_l", 0.25 + 0.15 * math.sin(t * 0.13))
    push("amp_out_r", 0.25 + 0.15 * math.sin(t * 0.11))
    local lo, hi = params:get("pos_start"), params:get("pos_end")
    if hi < lo then lo, hi = hi, lo end
    push("play_phase", lo + ((t * 0.013) % 1) * (hi - lo))
    -- four: track 2's head walks its own window
    local l2, h2 = params:get("t2_pos_start"), params:get("t2_pos_end")
    if h2 < l2 then l2, h2 = h2, l2 end
    push("play_phase2", l2 + ((t * 0.017) % 1) * (h2 - l2))
    for k = 3, 4 do
      local lk, hk = params:get("t" .. k .. "_pos_start"), params:get("t" .. k .. "_pos_end")
      if hk < lk then lk, hk = hk, lk end
      push("play_phase" .. k, lk + ((t * (0.011 + k * 0.003)) % 1) * (hk - lk))
    end
    -- tape head via the softcut phase event (position in seconds, voice 1)
    if _h.has_phase() then
      local tl, th = params:get("loop_start"), params:get("loop_end")
      if th < tl then tl, th = th, tl end
      local tp = tl + ((t * 0.009) % 1) * (th - tl)
      _h.phase(1, tp * 60)
    end
  end
end

-- settle: record the take, snap the window, set FX character
run_ticks(EMPTY and 30 or 200)

-- walk pages and shoot each one. navigation is BY NAME (goto_page) and the
-- export filenames derive their NN index from the page's position, so adding
-- or reordering pages never desyncs the shots.
-- READ from the script rather than mirrored by hand. A hand-copied list that
-- drifts is worse than no list: goto_page navigates by INDEX, so every shot
-- would silently render the wrong page while the byte-diff check kept passing.
local PAGES = (function()
  local src = assert(io.open(MANGLER, "r")):read("a")
  local block = src:match("\nlocal PAGES = %{(.-)%}")
  assert(block, "could not read PAGES out of " .. MANGLER)
  local out = {}
  for name in block:gmatch('"([A-Z0-9_]+)"') do out[#out + 1] = name end
  assert(#out > 0, "PAGES parsed empty")
  return out
end)()
local PAGE_IDX = {}
for i, n in ipairs(PAGES) do PAGE_IDX[n] = i end
local function goto_page(name)
  enc(1, -20)
  enc(1, (PAGE_IDX[name] or 1) - 1)
  -- run out the page-name pop (E1 arms it for ~0.7s): the shots depict the
  -- settled page, not the navigation chrome on top of it
  run_ticks(12)
end
-- the script's own state table (a local of four.lua, reached through an
-- upvalue of key()), for a state the params cannot set
local function script_ctx()
  for i = 1, 255 do
    local n, v = debug.getupvalue(key, i)
    if n == nil then break end
    if n == "ctx" then return v end
  end
end
local function pfx(name, suffix)
  return string.format("%s_%02d_%s%s", PREFIX, PAGE_IDX[name], name, suffix or "")
end

if EMPTY then
  goto_page("TAKE")
  run_ticks(10)
  redraw()
  export(pfx("TAKE", "_EMPTY"))
  goto_page("VOICE")  -- no material — silence lies dim and flat
  run_ticks(10)
  redraw()
  export(pfx("VOICE", "_EMPTY"))
elseif GRAINX then
  -- GRAIN extremes: pin the cloud's params to one edge per shot, settle to
  -- steady state (longest grain life is ~2s = 30 ticks), then shoot. BASE
  -- restates the defaults so every case is one delta from the same cloud.
  math.randomseed(1)  -- reproducible cloud for diffing
  local BASE = { size = 0.1, density = 20, spread = 0.5, pos_jitter = 0,
    pan = 0, mode = 2 }
  local CASES = {
    { "BASE", {} },
    { "SIZE_MIN", { size = 0.01 } },
    { "SIZE_MAX", { size = 0.5 } },
    { "DENS_MIN", { density = 1 } },
    { "DENS_MAX", { density = 200 } },
    { "SPRD_0", { spread = 0 } },
    { "SPRD_1", { spread = 1 } },
    { "JIT_1", { pos_jitter = 1 } },
    { "PAN_L", { pan = -1 } },
    { "MODE_OFF", { mode = 1 } },
  }
  goto_page("VOICE")
  for _, c in ipairs(CASES) do
    for id, v in pairs(BASE) do params:set(id, v) end
    for id, v in pairs(c[2]) do params:set(id, v) end
    run_ticks(60)
    redraw()
    export(pfx("VOICE", "_" .. c[1]))
  end
elseif TRACK2 then
  -- four: the pages on track 2. Track 1 stays in PLAY, so any grain or
  -- spectral texture on VOICE 2 is track 2's own. The head reads play_phase2.
  math.randomseed(1)
  params:set("mode", 5)
  params:set("t2_pos_start", 0.2); params:set("t2_pos_end", 0.5)
  goto_page("VOICE")
  key(3, 1); run_ticks(20); key(3, 0)        -- the hold: onto track 2
  for m, label in ipairs({ "OFF", "GRAIN", "WARP", "PV", "PLAY" }) do
    params:set("t2_mode", m)
    run_ticks(30)
    redraw()
    export(pfx("VOICE", "_T2_" .. label))
  end
  goto_page("FILTER")
  params:set("t2_filt_type", 2); params:set("t2_cutoff", 300); params:set("t2_resonance", 0.6)
  run_ticks(5)
  redraw()
  export(pfx("FILTER", "_T2_HP"))
  -- COLOR: track 2's crush draws the curve as stairs
  params:set("t2_crush", 0.6); params:set("t2_drive", 0.4)
  run_ticks(5)
  redraw()
  export(pfx("FILTER", "_T2_CRUSH"))
  params:set("t2_crush", 0); params:set("t2_drive", 0)
  -- a modulator on track 3's cutoff: the TRACKS hub marks track 3
  local TG = 1
  for i, t in ipairs(script_ctx().lfo.TARGETS) do if t == "cutoff" then TG = i + 1 end end
  params:set("lfo3_target", TG); params:set("lfo3_track", 3); params:set("lfo3_depth", 0.4)
  -- the TRACKS hub: four tracks, track 3 focused, then its sends under K1
  params:set("t2_mode", 2); params:set("t2_level", 1.2)
  params:set("t3_mode", 4); params:set("t3_pos_start", 0.05); params:set("t3_pos_end", 0.2)
  params:set("t4_mode", 1); params:set("t4_pos_start", 0.6); params:set("t4_pos_end", 0.9)
  params:set("track_sel", 3)
  goto_page("TRACKS")
  run_ticks(10)
  redraw()
  export(pfx("TRACKS", ""))
  params:set("send_1_2", 0.8); params:set("send_3_1", 0.4); params:set("send_3_4", 0.25)
  params:set("t3_fx_rev", 0.3); params:set("t2_fx_dly", 0)
  key(1, 1)
  run_ticks(3)
  redraw()
  export(pfx("TRACKS", "_SENDS"))
  key(1, 0)
  -- MOTION with no lanes: the four modulator rows, LFO 3 on track 3
  goto_page("MOTION")
  params:set("mod_focus", 4)
  run_ticks(5)
  redraw()
  export(pfx("MOTION", "_LFO4"))
  params:set("mod_focus", 1); params:set("lfo3_depth", 0); params:set("lfo3_target", 1)
  goto_page("TAKE")                          -- TAKE 3: track 3's window, the others marked
  run_ticks(10)
  redraw()
  export(pfx("TAKE", "_T3"))
  params:set("track_sel", 1)
  goto_page("TAKE")                          -- the track flag in the header
  run_ticks(5)
  redraw()
  export(pfx("TAKE", "_T2_FLAG"))
elseif FILTX then
  -- FILTER extremes: each type at a musical setting, plus the edges the
  -- curve math must survive (max resonance peak, fully open)
  local CASES = {
    { "LP_RES1", { filt_type = 1, cutoff = 800, resonance = 1 } },
    { "HP", { filt_type = 2, cutoff = 300, resonance = 0.3 } },
    { "BP", { filt_type = 3, cutoff = 1000, resonance = 0.6 } },
    { "LP_OPEN", { filt_type = 1, cutoff = 20000, resonance = 0 } },
  }
  goto_page("FILTER")
  for _, c in ipairs(CASES) do
    for id, v in pairs(c[2]) do params:set(id, v) end
    run_ticks(5)
    redraw()
    export(pfx("FILTER", "_" .. c[1]))
  end
else
  enc(1, -20)  -- ensure we start the walk on page 1
  for i, name in ipairs(PAGES) do
    if i > 1 then enc(1, 1) end
    run_ticks(25)
    redraw()
    export(string.format("%s_%02d_%s", PREFIX, i, name))
  end
  -- VOICE per engine mode (PLAY is the clean-loop default)
  goto_page("VOICE")
  for m, label in ipairs({ "OFF", "GRAIN", "WARP", "PV", "PLAY" }) do
    params:set("mode", m)
    if m == 4 then params:set("pv_freeze", 1) end
    run_ticks(12)
    redraw()
    export(pfx("VOICE", "_" .. label))
  end
  params:set("pv_freeze", 0)
  params:set("mode", 5)
  -- MIX with the engine off: the ENG lane should lie flat
  params:set("mode", 1)
  goto_page("MIX")
  run_ticks(8)
  redraw()
  export(pfx("MIX", "_OFF"))
  params:set("mode", 5)
  -- the value swell over a busy page: nudge the window start on TAKE
  goto_page("TAKE")
  run_ticks(5)
  enc(2, 2)
  run_ticks(2)
  redraw()
  export(pfx("TAKE", "_SWELL"))
  -- the purity mark: everything neutral -> the diamond lights by the title
  params:set("pitch", 1)
  params:set("cutoff", 20000)
  params:set("resonance", 0)
  params:set("delay_mix", 0)
  params:set("rev_mix", 0)
  params:set("mix", 0)          -- tape deck thrown away (it holds audio)
  params:set("dry_wet", 1)      -- the take alone: no live input blended in
  run_ticks(20)                 -- let the swell expire
  redraw()
  export(pfx("TAKE", "_PURE"))
  params:set("dry_wet", 0.5)    -- back to the default for the rest of the walk
  params:set("pitch", 2 ^ (5 / 12))
  params:set("cutoff", 1400)
  params:set("resonance", 0.35)
  params:set("delay_mix", 0.35)
  params:set("rev_mix", 0.28)
  params:set("mix", 0.5)
  -- DELAY truth shots: INF pins the loop; the echo at zero goes dormant
  goto_page("DELAY")
  params:set("delay_fb", 0.95)
  run_ticks(20)
  redraw()
  export(pfx("DELAY", "_INF"))
  params:set("delay_fb", 0.45)
  params:set("delay_mix", 0)
  run_ticks(5)
  redraw()
  export(pfx("DELAY", "_DRY"))
  params:set("delay_mix", 0.35)
  -- REVERB truth shots: WASH swells the tail; shimmer motes drift over it
  goto_page("REVERB")
  params:set("rev_mix", 1)
  run_ticks(6)
  redraw()
  export(pfx("REVERB", "_WASH"))
  params:set("rev_mix", 0.4)
  params:set("shimmer", 0.7)
  params:set("shimmer_pitch", 12)
  run_ticks(6)
  redraw()
  export(pfx("REVERB", "_SHIMMER"))
  params:set("shimmer", 0)
  params:set("rev_mix", 0.28)
  -- TAPE record SOURCE thrown WET: the tape prints the processed output
  -- (doc/ux-feedback.md §25) — the "SRC WET" flag must show
  goto_page("TAPE")
  params:set("cut_source", 1)
  run_ticks(4)
  redraw()
  export(pfx("TAPE", "_WET"))
  params:set("cut_source", 0)
  -- MIX thrown full tape: the ENG lane must lie flat-dim (inaudible)
  goto_page("MIX")
  params:set("mix", 1)
  run_ticks(8)
  redraw()
  export(pfx("MIX", "_TAPE"))
  params:set("mix", 0.5)
  -- TAKE armed: write head laying material, hot input, R flag blinking
  goto_page("TAKE")
  params:set("rec", 1)
  push("rec_phase", 0.62)
  push("rec_amp", 0.6)
  push("amp_in_l", 0.7)
  push("amp_in_r", 0.6)
  redraw()
  export(pfx("TAKE", "_REC"))
  -- armed to start on sound and none yet: WAIT where the seconds were. Set on
  -- the script's state directly, so the pass and every later shot are as before
  local ctx = script_ctx()
  ctx.rec_waiting = true
  redraw()
  export(pfx("TAKE", "_WAIT"))
  ctx.rec_waiting = false
  params:set("rec", 0)
  -- the window locked to a bar of the clock: its length says so top right.
  -- The window is put back after, so every later shot is as before
  -- start on sound is on too: "ON SND" beside it, before you arm
  local ws, we = params:get("pos_start"), params:get("pos_end")
  params:set("win_beats", 4)
  params:set("rec_wait", 1)
  redraw()
  export(pfx("TAKE", "_LOCK"))
  params:set("rec_wait", 0)
  params:set("win_beats", 1)
  params:set("pos_start", ws); params:set("pos_end", we)
  -- K3 held toward UNDO: the arc and the word, released before it lands
  key(3, 1)
  run_ticks(8)
  redraw()
  export(pfx("TAKE", "_UNDO_ARC"))
  key(3, 0)
  -- a SNAP tap says what it did on the top row; a second tap puts it back
  key(3, 1); key(3, 0)
  redraw()
  export(pfx("TAKE", "_SNAP_SAID"))
  key(3, 1); key(3, 0)
  run_ticks(20)
  params:set("pos_start", ws); params:set("pos_end", we)
  -- S17 self-resampling badges
  params:set("resample", 0.4)
  params:set("regen", 0.5)
  run_ticks(4)
  redraw()
  export(pfx("TAKE", "_REGEN"))
  params:set("resample", 0)
  params:set("regen", 0)
  -- the 1-frame re-arm above snapped the window to its blip (the rec-stop
  -- take-snap law); give the real take back for everything downstream
  params:set("pos_start", 0.05)
  params:set("pos_end", 0.554)
  -- the shift layer: K1 held swaps the footer whole (STOP/DRY + alt pair)
  goto_page("FILTER")
  key(1, 1)
  run_ticks(3)
  redraw()
  export(pfx("FILTER", "_SHIFT"))
  key(1, 0)
  -- the punch law on a throw: OPEN latched by a tap (word inverts), a
  -- second tap restores the carved tone
  key(2, 1) key(2, 0)
  run_ticks(2)
  redraw()
  export(pfx("FILTER", "_OPEN"))
  key(2, 1) key(2, 0)
  run_ticks(2)
  -- EFFECT: K3 steps through the five effects from OFF; each one draws its
  -- own motion. Then RESON's note read while E3 turns, K2 switching it off
  -- (the word goes dark, the line flat), and the same page on track 2.
  goto_page("EFFECT")
  for _, name in ipairs({ "CHORUS", "FLANGE", "WOBBLE", "RESON", "RING" }) do
    key(3, 1) key(3, 0)
    run_ticks(7)
    redraw()
    export(pfx("EFFECT", "_" .. name))
  end
  params:set("effect", 5)
  enc(3, 2)
  run_ticks(2)
  redraw()
  export(pfx("EFFECT", "_NOTE"))
  key(2, 1) key(2, 0)
  run_ticks(25)
  redraw()
  export(pfx("EFFECT", "_OFF_AGAIN"))
  params:set("track_sel", 2)
  params:set("t2_effect", 3); params:set("t2_effect_amt", 0.9)
  run_ticks(25)
  redraw()
  export(pfx("EFFECT", "_T2_SILENT"))
  params:set("t2_effect", 1); params:set("track_sel", 1)
  -- the erase arc: K1+K3 held on TAKE, shot mid-arc (frame ~8 of 15),
  -- then released in the abort zone — nothing fires, the take survives
  goto_page("TAKE")
  key(1, 1)
  key(3, 1)
  run_ticks(8)
  redraw()
  export(pfx("TAKE", "_ERASE_ARC"))
  key(3, 0)
  key(1, 0)
  -- PADS live: routed, the audition gated on bare K2 (the pad key)
  goto_page("PADS")
  params:set("pad_input", 1)
  params:set("seq_slice", 2)
  key(2, 1)
  run_ticks(3)
  redraw()
  export(pfx("PADS", "_LIVE"))
  key(2, 0)
  params:set("pad_input", 0)
  -- the sequencer running: its steps under the pads, the third one fired.
  -- Its clock is not run (env's clock.run would replace the frame loop), and
  -- the step is fired by hand, then released
  local real_run = clock.run
  clock.run = function() return {} end
  params:set("step_len", 8); params:set("step_fill", 5)
  params:set("step_run", 1)
  local seq = script_ctx().seq
  seq.fire(8)
  redraw()
  export(pfx("PADS", "_SEQ"))
  params:set("step_run", 0)
  params:set("step_len", 4); params:set("step_fill", 4)
  clock.run = real_run
  -- master STOP: the title chip inverts, on every page
  goto_page("MIX")
  params:set("stop_all", 1)
  run_ticks(3)
  redraw()
  export(pfx("MIX", "_STOP"))
  key(1, 1)
  run_ticks(3)
  redraw()
  export(pfx("MIX", "_STOP_SHIFT"))
  key(1, 0)
  params:set("stop_all", 0)
  -- S16 gesture looper: empty, armed (first pass), playing back
  goto_page("MOTION")
  run_ticks(4)
  redraw()
  export(pfx("MOTION", "_EMPTY"))
  params:set("motion_rec", 1)
  for t = 1, 20 do
    params:set("cutoff", 400 + 3000 * (1 + math.sin(t * 0.4)))
    params:set("delay_mix", 0.5 + 0.35 * math.sin(t * 0.25))
    run_ticks(1)
  end
  redraw()
  export(pfx("MOTION", "_REC"))
  params:set("motion_rec", 0)
  run_ticks(10)
  redraw()
  export(pfx("MOTION", "_PLAY"))
  -- the modulators under the lanes: LFO 1 swings the cutoff (selected, its
  -- encoders on the footer), LFO 2 ducks the reverb on the input's envelope
  -- and also goes out as a MIDI CC
  local ctx = script_ctx()
  local function tgt(id)
    for k, t in ipairs(ctx.lfo.TARGETS) do if t == id then return k + 1 end end
  end
  params:set("lfo1_target", tgt("cutoff")); params:set("lfo1_depth", 0.6)
  params:set("lfo2_target", tgt("rev_mix")); params:set("lfo2_shape", 6)
  params:set("lfo2_depth", -0.5)
  params:set("out_src", 5); params:set("out_midi", 1)
  params:set("mod_focus", 2)
  run_ticks(6)
  redraw()
  export(pfx("MOTION", "_LFO"))
  params:set("mod_focus", 1)
  params:set("out_src", 1); params:set("out_midi", 0)
  params:set("lfo1_depth", 0); params:set("lfo1_target", 1)
  params:set("lfo2_depth", 0); params:set("lfo2_target", 1); params:set("lfo2_shape", 1)
  run_ticks(1)
  params:set("motion_play", 0)
  -- S19 scenes (param-driven; recall mode stays NOW so no clock.sync)
  goto_page("SCENE")
  params:set("scene_slot", 1)
  params:set("cutoff", 700)
  params:set("delay_mix", 0.1)
  params:set("scene_capture", 1) params:set("scene_capture", 0)
  run_ticks(20)
  redraw()
  export(pfx("SCENE", "_ONE"))
  params:set("scene_slot", 4)
  params:set("cutoff", 9000)
  params:set("delay_mix", 0.7)
  params:set("rev_mix", 0.6)
  params:set("scene_capture", 1) params:set("scene_capture", 0)
  run_ticks(3)
  redraw()
  export(pfx("SCENE", "_SAVED"))
  run_ticks(20)
  redraw()
  export(pfx("SCENE", "_BANK"))
  params:set("scene_recall", 1) params:set("scene_recall", 0)
  run_ticks(3)
  redraw()
  export(pfx("SCENE", "_SAME"))
  run_ticks(20)
  params:set("scene_slot", 4)
  params:set("scene_morph_amt", 0.5)
  run_ticks(3)
  redraw()
  export(pfx("SCENE", "_MORPH"))
  params:set("scene_safe_capture", 1) params:set("scene_safe_capture", 0)
  run_ticks(3)
  redraw()
  export(pfx("SCENE", "_SAFE"))
  run_ticks(20)
  key(1, 1)
  run_ticks(2)
  redraw()
  export(pfx("SCENE", "_SHIFT"))
  key(1, 0)
  -- NU-3: the ◄ cell (slot 0) — filled by the auto-safe of the recall above
  params:set("scene_slot", 0)
  run_ticks(3)
  redraw()
  export(pfx("SCENE", "_BACK"))
  -- NU-3: hold-to-PEEK — RCL held ramps the morph toward the slot; the
  -- punch release sweeps it home again. The ramp waits out the tap window
  -- (5 frames), then takes 3 to arrive
  params:set("scene_slot", 4)
  run_ticks(2)
  key(2, 1)
  run_ticks(8)
  redraw()
  export(pfx("SCENE", "_PEEK"))
  run_ticks(3)
  key(2, 0)
  run_ticks(8)
  params:set("scene_morph_amt", 0)
  params:set("freeze", 1)
  params:set("scene_slot", 7)
  params:set("scene_capture", 1) params:set("scene_capture", 0)
  params:set("freeze", 0)
  params:set("scene_morph_amt", 1)
  run_ticks(3)
  redraw()
  export(pfx("SCENE", "_UNLANDED"))
  params:set("scene_morph_amt", 0)
  run_ticks(2)

  -- the merged surfaces, LAST so their state cannot leak into other shots:
  -- VOICE in PLAY with the take eroding (the EROSION page lives here now)...
  goto_page("VOICE")
  params:set("mode", 5)
  params:set("erode", 0.5)
  run_ticks(8)
  redraw()
  export(pfx("VOICE", "_ERODE"))
  params:set("erode", 0)
  -- ...and SCENE with the orbit running (the ORBIT page lives here now).
  -- the wander rewrites params, which is why nothing renders after it.
  goto_page("SCENE")
  params:set("orbit_on", 1)
  run_ticks(6)
  redraw()
  export(pfx("SCENE", "_ORBIT"))
  params:set("orbit_on", 0)
  -- the header with every flag lit on a long title: the words that do not
  -- fit shrink to dots and pips, and none of them drops off. Shot in the
  -- blink's lit phase, so the write letters show. The sequencer's and the
  -- repeat's clocks are not run (env's clock.run replaces the frame loop).
  goto_page("REVERB")
  clock.run = function() return {} end
  for _, id in ipairs({ "rec", "tape_rec", "motion_rec", "freeze",
      "tape_freeze", "beat_repeat", "step_run" }) do
    params:set(id, 1)
  end
  params:set("lfo1_target", 2); params:set("lfo1_depth", 0.5)
  run_ticks(1)
  while script_ctx().frame % 4 >= 2 do run_ticks(1) end
  redraw()
  export(pfx("REVERB", "_FLAGS"))
end

print("done: " .. _h.ticks() .. " ticks")

-- the opening picture (Mpages' draw_splash), at four moments
if not VARIANT then
  local c = script_ctx()
  for _, t in ipairs({ 4, 9, 14, 21 }) do
    c.splash_from = c.frame - t
    c.last_input = c.splash_from - 1
    redraw()
    export(string.format("%s_00_SPLASH_%02d", PREFIX, t))
  end
  c.splash_from = nil
end
