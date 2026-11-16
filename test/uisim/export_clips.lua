-- export_clips.lua: animated clips of four's real screen, for a website.
--
-- usage, from the repository root, with Lua 5.3 (norns' version):
--   $HOME/lua53/lua-5.3.6/src/lua test/uisim/export_clips.lua four.lua <outdir> [contact.png]
--
-- It loads the REAL four.lua into the offscreen norns (env.lua), plays a small
-- performance and keeps every frame the script draws. It writes into <outdir>:
--   <id>.png    one sprite sheet per clip: 128 wide, 64 high per frame, the
--               frames stacked top to bottom, 8-bit grey, pixel = level * 17
--               (the encoding of gallery.py's pictures)
--   clips.json  { fps, width, height, clips = [ { id, page, file, frames,
--               loop_start, caption } ] }. A player shows frames 0 to
--               loop_start - 1 once, then loops loop_start to frames - 1.
-- With a third argument it also writes a contact sheet there: the first
-- looping frame of every clip at 4x, four to a row.
--
-- Every page clip starts as the device does when E1 lands on the page: the
-- page name pops big for nine frames. The loop starts after the pop. The
-- polls and the knobs are driven as functions of the place in the loop, so
-- the last frame of a loop runs on into its first.
--
-- PIXEL TRUTH. A frame is the screen after one tick of the script's own
-- frame loop (frame_tick, which ends in redraw), read through env's pixel():
-- the buffer env's export() writes for render_pages. Nothing here draws.
-- The first 200 ticks replay render_pages' recording scenario exactly, so
-- with FOUR_CLIPS_PROOF=<dir> this writes, through env's export(), the
-- frame render_pages shoots first (as clips_base_01_TAKE.pgm, to cmp with
-- base_01_TAKE.pgm made with FOUR_SENDS=1 as gallery.py does) and one frame
-- of the take clip (clips_take_NN.pgm, NN its index in take.png).
--
-- WHY PYTHON WRITES THE PNG: a PNG needs deflate and Lua has no zlib. Each
-- sheet goes out as a P2 PGM, test/uisim/pgm2png.py (stdlib only) turns it
-- into the PNG at scale 1, and the PGM is removed. `python3` must be on PATH.
--
-- The clips use the same interpreter rules as the gallery: math.randomseed(1),
-- so a run repeats exactly on one interpreter (5.3 and 5.5 differ).

local MANGLER = arg[1] or "four.lua"
local OUTDIR = arg[2] or "."
local CONTACT = arg[3]
local PROOF = os.getenv("FOUR_CLIPS_PROOF")

local SCENARIO
local REPO_DIR = (arg[0]:match("(.*)/test/uisim/") or ".")
local env = dofile(REPO_DIR .. "/test/uisim/env.lua")
-- env's folder is where export() writes: only the proof frames go there
local h = env.install{ dir = PROOF or OUTDIR, scenario = function() return SCENARIO end }
local run_ticks, push = h.run_ticks, h.push

-- the script's own lines are counted, not shown; a caught frame error ends
-- the export (the frame loop survives it, so it would not show otherwise)
local real_print = print
local script_lines = 0
print = function(...)
  local parts = {}
  for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end
  local line = table.concat(parts, " ")
  if line:find("frame error", 1, true) then
    io.stderr:write("export_clips: the script reported: " .. line .. "\n")
    os.exit(1)
  end
  script_lines = script_lines + 1
end

local REPO = MANGLER:match("^(.*)/") or "."
include = function(p) return dofile(REPO .. "/" .. p .. ".lua") end
math.randomseed(1)
dofile(MANGLER)
init()

-- system params, as render_pages adds them (norns owns them on the device)
params:add_control("input_level", "input", controlspec.new(0, 1, "lin", 0, 0.8, ""))
params:add_control("output_level", "output", controlspec.new(0, 1, "lin", 0, 0.7, ""))
params:add_control("monitor_level", "monitor", controlspec.new(0, 1, "lin", 0, 0.45, ""))
params:add_control("headphone_gain", "hp", controlspec.new(0, 1, "lin", 0, 0.6, ""))
-- track 1 sends to the delay and the reverb (gallery's FOUR_SENDS)
params:set("fx_dly", 1); params:set("fx_rev", 1)

local function upvalue(fn, name)
  for i = 1, 255 do
    local n, v = debug.getupvalue(fn, i)
    if n == nil then break end
    if n == name then return v end
  end
end
local ctx = assert(upvalue(key, "ctx"), "could not reach the script's ctx")

local PAGES = (function()
  local src = assert(io.open(MANGLER, "r")):read("a")
  local block = assert(src:match("\nlocal PAGES = %{(.-)%}"), "no PAGES in " .. MANGLER)
  local out = {}
  for name in block:gmatch('"([A-Z0-9_]+)"') do out[#out + 1] = name end
  return out
end)()
local PAGE_IDX = {}
for i, n in ipairs(PAGES) do PAGE_IDX[n] = i end

-- E1 to the page, as render_pages does it, without running out the pop
local function land(name)
  enc(1, -20)
  enc(1, assert(PAGE_IDX[name], name) - 1)
end

-- ============================================================================
-- frames and clips
-- ============================================================================

local W, H = 128, 64
local CH = {}
for l = 0, 15 do CH[l] = string.char(l) end
local pixel = h.pixel

-- the screen as it stands: W * H bytes, one level (0 to 15) each
local function grab()
  assert(not ctx.idle_dim, "the screen went idle-dim during a clip")
  local rows = {}
  for y = 0, H - 1 do
    local r = {}
    for x = 0, W - 1 do r[x + 1] = CH[pixel(x, y)] end
    rows[y + 1] = table.concat(r)
  end
  return table.concat(rows)
end

local CLIPS = {}
local function add_clip(id, page, frames, loop_start, caption)
  CLIPS[#CLIPS + 1] = { id = id, page = page, frames = frames,
    loop_start = loop_start, caption = caption }
end

-- one tick of the frame loop, and the frame it drew
local function tick_grab(frames)
  run_ticks(1)
  frames[#frames + 1] = grab()
end

-- ============================================================================
-- the opening and render_pages' recording, tick for tick
-- ============================================================================

-- render_pages' base scenario, verbatim: a take on track 1 from t=10 to 150,
-- a tape pass from 20 to 140, the FX and a +5 pitch at 155
SCENARIO = function(t)
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
  local e = math.abs(math.sin(t * 0.31)) * (0.6 + 0.4 * math.sin(t * 0.077))
  push("rec_amp", 0.05 + 0.5 * math.max(e, 0))
  push("amp_in_l", 0.04 + 0.4 * math.max(e, 0))
  push("amp_in_r", 0.04 + 0.38 * math.max(math.sin(t * 0.29), 0))
  push("amp_out_l", 0.25 + 0.15 * math.sin(t * 0.13))
  push("amp_out_r", 0.25 + 0.15 * math.sin(t * 0.11))
  local lo, hi = params:get("pos_start"), params:get("pos_end")
  if hi < lo then lo, hi = hi, lo end
  push("play_phase", lo + ((t * 0.013) % 1) * (hi - lo))
  local l2, h2 = params:get("t2_pos_start"), params:get("t2_pos_end")
  if h2 < l2 then l2, h2 = h2, l2 end
  push("play_phase2", l2 + ((t * 0.017) % 1) * (h2 - l2))
  for k = 3, 4 do
    local lk, hk = params:get("t" .. k .. "_pos_start"), params:get("t" .. k .. "_pos_end")
    if hk < lk then lk, hk = hk, lk end
    push("play_phase" .. k, lk + ((t * (0.011 + k * 0.003)) % 1) * (hk - lk))
  end
  if h.has_phase() then
    local tl, th = params:get("loop_start"), params:get("loop_end")
    if th < tl then tl, th = th, tl end
    h.phase(1, (tl + ((t * 0.009) % 1) * (th - tl)) * 60)
  end
end

-- the opening: init drew its first frame; the first resume of the frame loop
-- only reaches its first sleep, and every tick after it draws one frame
do
  local frames = { grab() }
  run_ticks(1)
  while ctx.splash_from and ctx.frame - ctx.splash_from < 23 do tick_grab(frames) end
  add_clip("intro", "SPLASH", frames, #frames,
    "The opening: four bars rise, one for each track, and the name lands on them.")
end

-- the rest of render_pages' 200 ticks, then its first shot (TAKE after E1)
run_ticks(200 - h.ticks())
enc(1, -20)
run_ticks(25)
redraw()
if PROOF then h.export("clips_base_01_TAKE") end
SCENARIO = nil

-- ============================================================================
-- the material the pages show, driven per frame from here on
-- ============================================================================

local TWO_PI = 2 * math.pi

-- a hit that falls away fast: 1 on the beat, near 0 just before the next.
-- `u` is seconds or the place in a loop, `n` the beats in one unit, `lag` a
-- shift in beats
local function beat(u, n, lag)
  return math.exp(-((u * n + (lag or 0)) % 1) * 6)
end

-- one track's window from its params, low to high
local function window(n)
  local p = n == 1 and "" or ("t" .. n .. "_")
  local a, b = params:get(p .. "pos_start"), params:get(p .. "pos_end")
  return math.min(a, b), math.max(a, b)
end

-- the heads: each crosses its window a whole number of times per loop, so a
-- loop's last frame runs on into its first
local PASSES = { 1, 2, 3, 1 }
local OFFSET = { 0, 0.3, 0.6, 0.1 }
local PHASE_POLL = { "play_phase", "play_phase2", "play_phase3", "play_phase4" }
local function drive_base(u)
  for n = 1, 4 do
    local lo, hi = window(n)
    push(PHASE_POLL[n], lo + ((u * PASSES[n] + OFFSET[n]) % 1) * (hi - lo))
  end
  local phrase = 0.65 + 0.35 * math.sin(TWO_PI * u)
  local bl, br = beat(u, 8), beat(u, 8, 0.12)
  push("amp_in_l", 0.03 + 0.5 * bl * phrase)
  push("amp_in_r", 0.03 + 0.42 * br * phrase)
  push("amp_out_l", 0.18 + 0.3 * bl * phrase)
  push("amp_out_r", 0.16 + 0.28 * br * phrase)
  push("rec_amp", 0.05 + 0.4 * bl * phrase)
  if h.has_phase() then
    local tl, th = params:get("loop_start"), params:get("loop_end")
    if th < tl then tl, th = th, tl end
    h.phase(1, (tl + u * (th - tl)) * 60)
  end
end

-- a take at the real speed: f counts frames from the arm, and the write head
-- moves 1/60 of the buffer a second, so the seconds TAKE counts are seconds.
-- The input is a beat twice a second under a phrase that rises and falls
local REC_S = 24                     -- the take's length in seconds
local REC_FRAMES = REC_S * 15
local function rec_drive(f)
  local s = f / 15
  local phrase = 0.55 + 0.3 * math.sin(TWO_PI * s / 7.3) + 0.12 * math.sin(TWO_PI * s / 2.3)
  local bl, br = beat(s, 2), beat(s, 2, 0.06)
  push("rec_phase", math.min(f, REC_FRAMES) / (60 * 15))
  push("rec_amp", 0.04 + 0.55 * bl * phrase)
  push("amp_in_l", 0.04 + 0.6 * bl * phrase)
  push("amp_in_r", 0.04 + 0.52 * br * phrase)
  push("amp_out_l", 0.2 + 0.2 * bl * phrase)
  push("amp_out_r", 0.2 + 0.18 * br * phrase)
end

-- ============================================================================
-- TAKE: track 2 records a take in real time
-- ============================================================================
-- Track 1 keeps render_pages' take (the material of every page below). The
-- take clip records track 2 at the real speed of the write head, so its
-- seconds count true; it is also the second take TRACKS shows.
do
  params:set("track_sel", 2)         -- the focus: REC writes track 2's buffer
  push("rec_phase", 0)
  rec_drive(0)
  run_ticks(1)
  params:set("rec", 1)
  local POP_AT = REC_FRAMES - 36 - 9  -- 2.4 s of recording after the pop
  local frames, loop_start = {}, nil
  for f = 0, REC_FRAMES + 14 do
    if f == REC_FRAMES then params:set("rec", 0) end
    if f == POP_AT then land("TAKE") end
    rec_drive(f)
    -- the arm turned track 2's voice on (an OFF track you record into
    -- plays): its PLAY head started at the window's start with the write
    -- head and runs at the same speed; after the close it loops the take
    local lo, hi = window(2)
    push("play_phase2", lo + (f / 900 - lo) % math.max(hi - lo, 0.001))
    if f >= POP_AT then
      tick_grab(frames)
      if not loop_start and not (ctx.page_flash and ctx.frame < ctx.page_flash) then
        loop_start = #frames - 1
      end
      if PROOF and loop_start and #frames - 1 == loop_start + 10 then
        h.export(string.format("clips_take_%02d", #frames - 1))
      end
    else
      run_ticks(1)
    end
  end
  add_clip("take", "TAKE", frames, loop_start,
    "TAKE records track 2 in real time: the write head lays the take down, the "
    .. "seconds count, the IN meter moves. Then the take closes and its window snaps to it.")
end

-- tracks 3 and 4 get short takes too, recorded fast where no clip looks;
-- then each track gets a voice of its own and the focus goes home
do
  local function quick_take(n, frames)
    params:set("track_sel", n)
    push("rec_phase", 0)
    run_ticks(1)
    params:set("rec", 1)
    for f = 0, frames do
      rec_drive(f * 6)
      push("rec_phase", f * 6 / 900)
      run_ticks(1)
    end
    params:set("rec", 0)
    run_ticks(1)
  end
  quick_take(3, 40)                  -- 16 s
  quick_take(4, 50)                  -- 20 s
  -- narrower windows inside each take: the start moves in first, so the
  -- pair never crosses
  params:set("t3_pos_start", 0.05); params:set("t3_pos_end", 0.2)
  params:set("t4_pos_start", 0.08); params:set("t4_pos_end", 0.3)
  params:set("t2_mode", 2); params:set("t3_mode", 4); params:set("t4_mode", 6)
  params:set("track_sel", 1)
  run_ticks(2)
end

-- ============================================================================
-- the page clips
-- ============================================================================
-- c.page, c.id, c.loop (frames), c.caption; c.setup() before E1 lands,
-- c.drive(u, i) before each tick (u is the place in the loop, 0 to 1; i the
-- frame, negative during the pop), c.landed() right after E1 lands,
-- c.done() after the last frame. c.warm frames run on the page before it is
-- landed on again for the clip, for a page that keeps state between frames
local function page_clip(c)
  if c.setup then c.setup() end
  local L = c.loop
  if c.warm then
    land(c.page)
    local pop = ctx.page_flash - ctx.frame - 1
    for i = -pop - c.warm, -pop - 1 do
      drive_base((i % L) / L)
      if c.drive then c.drive((i % L) / L, i) end
      run_ticks(1)
    end
  end
  land(c.page)
  if c.landed then c.landed() end
  local pop = ctx.page_flash - ctx.frame - 1
  local frames = {}
  for i = -pop, L - 1 do
    local u = (i % L) / L
    drive_base(u)
    if c.drive then c.drive(u, i) end
    tick_grab(frames)
  end
  if c.done then c.done() end
  add_clip(c.id, c.page, frames, pop, c.caption)
end

-- VOICE in each mode. The PLAY wave drifts 0.8 px a frame on an 18 px
-- period, so 45 frames are two whole periods
local VOICE_CLIPS = {
  { "voice_play", 5, "VOICE in PLAY with erosion: the wave ages in flecks, GEN counts the "
    .. "passes and the bar under it fills as the erosion head crosses the window.",
    function() params:set("erode", 0.5) end, function() params:set("erode", 0) end },
  { "voice_grain", 2, "VOICE in GRAIN: the cloud of grains sits on the read head, as many "
    .. "and as long as DENSITY and SIZE say, scattered over the stereo field." },
  { "voice_warp", 3, "VOICE in WARP: the time-stretch's overlapped window ghosts behind "
    .. "the wave and wobbles with the warp's randomness.",
    function() params:set("warp_rand", 0.6) end, function() params:set("warp_rand", 0) end },
  { "voice_pv", 4, "VOICE in PV: the phase vocoder, drawn as spectral columns that drift "
    .. "with the scan." },
  { "voice_cloud", 6, "VOICE in CLOUD: the Clouds granulator, each grain scattered "
    .. "around the pan." },
}
for _, v in ipairs(VOICE_CLIPS) do
  page_clip{ id = v[1], page = "VOICE", loop = 45, caption = v[3],
    setup = function()
      params:set("mode", v[2])
      if v[4] then v[4]() end
    end,
    done = function()
      if v[5] then v[5]() end
      params:set("mode", 5)
    end }
end

-- TRACKS: the four rows, each head on its own window; E2 walks the focus
-- 1 2 3 4 3 2 and back, a step every 8 frames
do
  local WALK = { 1, 2, 3, 4, 3, 2 }
  local tsel = function() return math.floor(params:get("track_sel") + 0.5) end
  page_clip{ id = "tracks", page = "TRACKS", loop = 48,
    caption = "TRACKS, the hub: four tracks, each with its own take, voice, window and "
      .. "level. E2 walks the focus that the other pages edit.",
    setup = function() params:set("t2_level", 1.2) end,
    drive = function(u, i)
      local want = WALK[(i % 48) // 8 + 1]
      if want ~= tsel() then enc(2, want - tsel()) end
    end,
    done = function() params:set("track_sel", 1) end }
end

-- TRACKS with K1 held: the sends. K1+E2 walks the cursor along track 1's
-- row and back, a step every 6 frames
do
  local SENDS = { send_1_2 = 0.6, send_1_4 = 0.3, send_2_3 = 0.5, send_3_1 = 0.4,
    t2_fx_dly = 0.8, t3_fx_rev = 0.5, fx_rev = 0.7 }
  local WALK = { 1, 2, 3, 4, 5, 4, 3, 2 }
  local at = 1
  page_clip{ id = "tracks_sends", page = "TRACKS", loop = 48,
    caption = "TRACKS with K1 held: the sends. A row is where a sound comes from, a "
      .. "column where it goes: another track, the delay or the reverb.",
    setup = function()
      for id, v in pairs(SENDS) do params:set(id, v) end
    end,
    landed = function()
      -- K1 goes down after E1 has landed (K1+E1 picks a track), and K1+E2
      -- takes the cursor to the first cell of track 1's row
      key(1, 1)
      for _ = 1, 6 do enc(2, -1) end
      at = 1
    end,
    drive = function(u, i)
      local want = WALK[(i % 48) // 6 + 1]
      while at ~= want do
        local d = want > at and 1 or -1
        enc(2, d)
        at = at + d
      end
    end,
    done = function()
      key(1, 0)
      for id in pairs(SENDS) do params:set(id, 0) end
      params:set("fx_rev", 1)
    end }
end

-- TAPE: the reels turn 0.35 rad a frame and have three spokes, so 48 frames
-- turn them eight thirds and a hair; the head crosses the loop once
page_clip{ id = "tape", page = "TAPE", loop = 48,
  caption = "TAPE, the loop deck: the reels turn at the tape's rate and the head "
    .. "crosses the loop that was recorded on it." }

-- FILTER: the cutoff sweeps down from 12 kHz to 150 Hz and back up, with the
-- resonance up
page_clip{ id = "filter", page = "FILTER", loop = 45,
  caption = "FILTER: the cutoff sweeps down and back up with the resonance high; "
    .. "the curve is the filter's real response.",
  setup = function() params:set("filt_type", 1); params:set("resonance", 0.6) end,
  drive = function(u)
    local k = 0.5 - 0.5 * math.cos(TWO_PI * u)
    params:set("cutoff", 12000 * (150 / 12000) ^ k)
  end,
  done = function() params:set("cutoff", 1400); params:set("resonance", 0.35) end }

-- EFFECT: K3 steps the slot's type, one second each. K3 skips OFF (K2 is the
-- off switch), so after ECHO it comes back to CHORUS, as the loop does
do
  local NAMES = { "CHORUS", "FLANGE", "WOBBLE", "RESON", "RING", "ECHO" }
  page_clip{ id = "effect", page = "EFFECT", loop = 15 * #NAMES,
    caption = "EFFECT: K3 steps the slot through CHORUS, FLANGE, WOBBLE, RESON, RING "
      .. "and ECHO; each draws the way it moves the sound.",
    setup = function() params:set("effect", 2) end,
    drive = function(u, i)
      if i >= 0 and i % 15 == 0 then
        local want = i // 15 + 2
        if math.floor(params:get("effect") + 0.5) ~= want then
          key(3, 1); key(3, 0)
          assert(math.floor(params:get("effect") + 0.5) == want,
            "K3 did not step to " .. NAMES[want - 1])
        end
      end
    end,
    done = function() params:set("effect", 1) end }
end

-- DELAY: the time and the feedback move, so the echoes slide and fade
page_clip{ id = "delay", page = "DELAY", loop = 45,
  caption = "DELAY: the onset and its echoes, as far apart as the time and as many "
    .. "as the feedback lets through.",
  setup = function() params:set("delay_mix", 0.45) end,
  drive = function(u)
    params:set("delay_time", 0.3 + 0.12 * math.sin(TWO_PI * u))
    params:set("delay_fb", 0.55 + 0.25 * math.cos(TWO_PI * u))
  end,
  done = function()
    params:set("delay_mix", 0.35); params:set("delay_time", 0.32); params:set("delay_fb", 0.45)
  end }

-- REVERB with shimmer, tracks 1 to 3 sending: a pulse every 14 frames, so
-- 42 frames are three
page_clip{ id = "reverb", page = "REVERB", loop = 42,
  caption = "REVERB: the tracks that send stand at the corners; each pulse spreads "
    .. "through the room's four squares, and shimmer motes climb off the outer one.",
  setup = function()
    params:set("rev_mix", 0.45); params:set("shimmer", 0.7); params:set("shimmer_pitch", 12)
    params:set("t2_fx_rev", 0.6); params:set("t3_fx_rev", 0.35)
  end,
  done = function()
    params:set("shimmer", 0); params:set("rev_mix", 0.28)
    params:set("t2_fx_rev", 0); params:set("t3_fx_rev", 0)
  end }

-- MIX: the crossfade swings between the decks while the meters move. The
-- meters' peak pips fall slowly, so two loops run first and the pips are on
-- their loop when the clip starts
page_clip{ id = "mix", page = "MIX", loop = 45, warm = 90,
  caption = "MIX, the console: the input meter, the engine deck and the tape deck at "
    .. "their real gains across the crossfade, and the master meter.",
  drive = function(u) params:set("mix", 0.5 + 0.22 * math.sin(TWO_PI * u)) end,
  done = function() params:set("mix", 0.5) end }

-- PADS with the sequencer running. Its clock is not run (env's clock.run
-- would replace the frame loop): a step is fired by hand every 5 frames, an
-- eighth of a bar, eight steps to the loop
do
  local real_run = clock.run
  local SP, NSTEP, DIV = 5, 8, 0.5
  page_clip{ id = "pads", page = "PADS", loop = SP * NSTEP,
    caption = "PADS: the take in eight slices. The sequencer steps through them; the "
      .. "pad it plays lights and its step stands tall.",
    setup = function()
      clock.run = function() return {} end
      params:set("step_div", 5)
      params:set("step_len", NSTEP); params:set("step_fill", 5)
      params:set("step_run", 1)
    end,
    drive = function(u, i)
      local j = i % (SP * NSTEP)
      if j % SP == 0 then ctx.seq.fire(j // SP * DIV) end
    end,
    done = function()
      params:set("step_run", 0)
      params:set("step_len", 4); params:set("step_fill", 4); params:set("step_div", 2)
      clock.run = real_run
    end }
end

-- MOTION: a recorded gesture plays (its loop set to 3 s, the clip's), and
-- two modulators run under it: a sine on the resonance once a loop, and the
-- input's envelope ducking the reverb
do
  local function tgt(id)
    for k, t in ipairs(ctx.lfo.TARGETS) do if t == id then return k + 1 end end
  end
  page_clip{ id = "motion", page = "MOTION", loop = 45,
    caption = "MOTION: a recorded gesture plays back on its lanes, and the modulators "
      .. "below swing their knobs; a dot shows where each one is now.",
    setup = function()
      params:set("motion_len", 3)
      params:set("motion_rec", 1)
      for t = 0, 44 do
        local u = t / 45
        params:set("cutoff", 900 * (8 ^ (0.5 - 0.5 * math.cos(TWO_PI * u))))
        params:set("delay_mix", 0.4 + 0.3 * math.sin(TWO_PI * u * 2))
        run_ticks(1)
      end
      params:set("motion_rec", 0)
      params:set("lfo1_target", tgt("resonance")); params:set("lfo1_depth", 0.7)
      params:set("lfo1_rate", 1 / 3)
      params:set("lfo2_target", tgt("rev_mix")); params:set("lfo2_shape", 6)
      params:set("lfo2_depth", -0.5)
      params:set("mod_focus", 2)
    end,
    done = function()
      params:set("motion_play", 0)
      params:set("mod_focus", 1)
      params:set("lfo1_depth", 0); params:set("lfo1_target", 1); params:set("lfo1_rate", 0.5)
      params:set("lfo2_depth", 0); params:set("lfo2_target", 1); params:set("lfo2_shape", 1)
      params:set("cutoff", 1400); params:set("delay_mix", 0.35)
    end }
end

-- SCENE: two slots stored, the morph sweeps toward slot 4 and back
page_clip{ id = "scene", page = "SCENE", loop = 45,
  caption = "SCENE: eight slots of stored states. E3 morphs the sound from where it "
    .. "is toward the selected slot, and back.",
  setup = function()
    params:set("scene_slot", 1)
    params:set("cutoff", 700); params:set("delay_mix", 0.1)
    params:set("scene_capture", 1); params:set("scene_capture", 0)
    params:set("scene_slot", 4)
    params:set("cutoff", 9000); params:set("delay_mix", 0.7); params:set("rev_mix", 0.6)
    params:set("scene_capture", 1); params:set("scene_capture", 0)
    params:set("cutoff", 1400); params:set("delay_mix", 0.35); params:set("rev_mix", 0.28)
    run_ticks(25)                      -- the SAVED word has gone
  end,
  drive = function(u)
    params:set("scene_morph_amt", 0.48 * (1 - math.cos(TWO_PI * u)))
  end,
  done = function() params:set("scene_morph_amt", 0) end }

-- ============================================================================
-- write the sheets, the list and the contact sheet
-- ============================================================================

local function sh(s) return "'" .. s:gsub("'", "'\\''") .. "'" end
local PGM2PNG = REPO_DIR .. "/test/uisim/pgm2png.py"
local LV = {}
for l = 0, 15 do LV[l] = tostring(l * 17) end

-- a PGM of `rows` (each a string of levels, `w` wide), then the PNG
local function write_png(path, w, rows, scale)
  local pgm = path:gsub("%.png$", "") .. ".pgm"
  local f = assert(io.open(pgm, "w"))
  f:write("P2\n", w, " ", #rows, "\n255\n")
  local vals = {}
  for _, r in ipairs(rows) do
    for x = 1, w do vals[x] = LV[r:byte(x)] end
    f:write(table.concat(vals, " ", 1, w), "\n")
  end
  f:close()
  local ok = os.execute("python3 " .. sh(PGM2PNG) .. " " .. sh(pgm) .. " " .. sh(path)
    .. " " .. scale)
  os.remove(pgm)
  assert(ok, "pgm2png failed for " .. path)
end

local function frame_rows(frame, into)
  for y = 0, H - 1 do into[#into + 1] = frame:sub(y * W + 1, (y + 1) * W) end
end

local function jstr(s)
  return '"' .. s:gsub('[%c"\\]', function(c)
    return c == '"' and '\\"' or (c == "\\" and "\\\\" or string.format("\\u%04x", c:byte()))
  end) .. '"'
end

local entries = {}
for _, c in ipairs(CLIPS) do
  local rows = {}
  for _, fr in ipairs(c.frames) do frame_rows(fr, rows) end
  c.file = c.id .. ".png"
  write_png(OUTDIR .. "/" .. c.file, W, rows, 1)
  local fh = assert(io.open(OUTDIR .. "/" .. c.file, "rb"))
  c.bytes = fh:seek("end")
  fh:close()
  entries[#entries + 1] = string.format(
    '    { "id": %s, "page": %s, "file": %s, "frames": %d, "loop_start": %d, "caption": %s }',
    jstr(c.id), jstr(c.page), jstr(c.file), #c.frames, c.loop_start, jstr(c.caption))
end
do
  local f = assert(io.open(OUTDIR .. "/clips.json", "w"))
  f:write('{\n  "fps": 15,\n  "width": 128,\n  "height": 64,\n  "clips": [\n',
    table.concat(entries, ",\n"), "\n  ]\n}\n")
  f:close()
end

-- the contact sheet: the first looping frame of each clip (the intro, which
-- does not loop, shows its middle), four to a row, 2 px apart at level 5
if CONTACT then
  local COLS, GAP = 4, 2
  local n = #CLIPS
  local nrow = (n + COLS - 1) // COLS
  local sw = COLS * W + (COLS + 1) * GAP
  local sheet = {}
  local gap_row = string.rep(CH[5], sw)
  for _ = 1, nrow * (H + GAP) + GAP do sheet[#sheet + 1] = gap_row end
  for k, c in ipairs(CLIPS) do
    local fi = c.loop_start < #c.frames and c.loop_start + 1 or (#c.frames + 1) // 2
    local fr = c.frames[fi]
    local x0 = GAP + ((k - 1) % COLS) * (W + GAP)
    local y0 = GAP + ((k - 1) // COLS) * (H + GAP)
    for y = 0, H - 1 do
      local r = sheet[y0 + y + 1]
      sheet[y0 + y + 1] = r:sub(1, x0) .. fr:sub(y * W + 1, (y + 1) * W) .. r:sub(x0 + W + 1)
    end
  end
  write_png(CONTACT, sw, sheet, 4)
end

local total = 0
for _, c in ipairs(CLIPS) do
  total = total + c.bytes
  real_print(string.format("%-13s %4d frames  loop from %3d  %7d bytes", c.id, #c.frames,
    c.loop_start, c.bytes))
end
real_print(string.format("%d clips, %d bytes, %d ticks (%d script lines kept quiet)",
  #CLIPS, total, h.ticks(), script_lines))
