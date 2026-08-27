-- render_pages.lua — offscreen renderer for mangler's norns screen.
-- Stubs the norns Lua environment, loads the REAL mangler.lua, drives a
-- believable performance scenario (a take, a tape loop, live FX), then
-- exports every UI page as a PGM framebuffer (0..15 levels -> 0..255).
--
-- usage: lua render_pages.lua <mangler.lua path> <outdir> <prefix> [variant]
--   variant "empty": empty-buffer states (REC + GRAIN)
--   variant "grain": GRAIN page across its param extremes (size/density/
--                    spread/jitter/pan edges, mode OFF)
--   variant "filter": FILTER page across its types and resonance extremes

local MANGLER = arg[1] or "mangler.lua"
local OUTDIR = arg[2] or "."
local PREFIX = arg[3] or "shot"
local VARIANT = arg[4]
local EMPTY = VARIANT == "empty"
local GRAINX = VARIANT == "grain"
local FILTX = VARIANT == "filter"


-- the offscreen norns lives in env.lua so more than one harness can use it.
-- SCENARIO stays OUR local and env reads it through the getter — see the note
-- at the top of env.lua for why that is not ceremony.
local SCENARIO
local REPO_DIR = (arg[0]:match("(.*)/tools/uisim/") or ".")
local env = dofile(REPO_DIR .. "/tools/uisim/env.lua")
local _h = env.install{ dir = OUTDIR, scenario = function() return SCENARIO end }
local export, run_ticks = _h.export, _h.run_ticks
local POLL_FNS = _h.poll_fns
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

-- deterministic renders: the particle cloud draws from math.random, and
-- seeding here makes galleries diffable and the dist build byte-checkable
math.randomseed(1)

dofile(MANGLER)
init()

-- system params: owned by norns on device; mangler references, never adds
params:add_control("input_level", "input", controlspec.new(0, 1, "lin", 0, 0.8, ""))
params:add_control("output_level", "output", controlspec.new(0, 1, "lin", 0, 0.7, ""))
params:add_control("monitor_level", "monitor", controlspec.new(0, 1, "lin", 0, 0.45, ""))
params:add_control("headphone_gain", "hp", controlspec.new(0, 1, "lin", 0, 0.6, ""))



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
    -- tape head via the softcut phase event (position in seconds, voice 1)
    if _h.has_phase() then
      local tl, th = params:get("loop_start"), params:get("loop_end")
      if th < tl then tl, th = th, tl end
      local tp = tl + ((t * 0.009) % 1) * (th - tl)
      _h.phase(1, tp * 60)
      -- the layer decks run on their own voices and their own buffer regions,
      -- and each free-runs at its own rate — which is the point of having them.
      -- The real poll reports a position in SECONDS into the whole buffer, so
      -- the stub has to as well, or the deck's phase maths would never be
      -- exercised offscreen.
      for n, dk in ipairs({ { v = 3, from = 120, rate = 0.013 },
                            { v = 5, from = 180, rate = 0.021 } }) do
        local id = "lay" .. n
        local a1, b1 = params:get(id .. "_start"), params:get(id .. "_end")
        if b1 < a1 then a1, b1 = b1, a1 end
        local ph = a1 + ((t * dk.rate) % 1) * (b1 - a1)
        _h.phase(dk.v, dk.from + ph * 60)
      end
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
  for name in block:gmatch('"([A-Z_]+)"') do out[#out + 1] = name end
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
  params:set("rec", 0)
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
  -- LAYERS with material: L1 recording (blinking write flag, DUB), L2 looping
  -- a shorter region at a different rate — the drift that makes two decks worth
  -- having
  goto_page("LAYERS")
  params:set("lay1_rec", 1)
  params:set("lay2_rate", 0.75)
  params:set("lay2_start", 0.15)
  params:set("lay2_end", 0.6)
  run_ticks(120)
  params:set("layer_sel", 2)
  run_ticks(4)
  redraw()
  export(pfx("LAYERS", "_LIVE"))
  -- the footer while a layer encoder is TURNING: it used to read "--" because
  -- the compound target had no anchor param to resolve to
  enc(3, 2)
  run_ticks(2)
  redraw()
  export(pfx("LAYERS", "_TURN"))
  params:set("lay1_rec", 0)
  params:set("layer_sel", 1)
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
  -- punch release sweeps it home again
  params:set("scene_slot", 4)
  run_ticks(2)
  key(2, 1)
  run_ticks(4)
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
end

print("done: " .. _h.ticks() .. " ticks")
