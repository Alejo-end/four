-- mgrid: the optional 8x8 grid surface — monome grid, or launchpad-style
-- controllers via midigrid.
--
-- native monome grids just work; with the midigrid library installed
-- (~/dust/code/midigrid) a launchpad-family or APC mini controller stands
-- in — but only when no real grid is attached (a monome on grid vport 1
-- wins). every pad drives params, the same single source of truth as keys,
-- encoders, and MIDI CCs.
--
--   row 1  engine: [rec] [freeze]  ·  [OFF][GRAIN][WARP][PV]  [pv frz]
--   row 2  tape:   [rec] [freeze] [reverse, hold]  ·  ·  ·  [DRY] [STOP all]
--   row 3  window slices: a pad = that eighth; hold one + press another
--          = the span between them; the write head glows while recording
--   row 4  tape loop slices: same gesture, driving loop start/end
--   rows 5-8  two piano octaves, black row above its white row (same
--          shape as the typing keyboard; upper pair is +1 octave).
--          black-row gap pads: row 7 ends = octave -/+, row 5 ends =
--          pitch reset / pitch quantize

local floor, min, max, log = math.floor, math.min, math.max, math.log

local M = { gg = nil, have_midigrid = false }

local grid_mod = grid
do
  local gname = (grid.vports and grid.vports[1] and grid.vports[1].name)
    or "none"
  if gname == "none" and util.file_exists(_path.code .. "midigrid") then
    -- pcall: a broken midigrid install must not take mangler down with it
    local ok, mg = pcall(include, "midigrid/lib/midigrid")
    if ok and mg then
      grid_mod = mg
      M.have_midigrid = true
      print("mangler: midigrid loaded — midi grid controllers welcome")
    else
      print("mangler: midigrid present but failed to load: " .. tostring(mg))
    end
  end
end

local gg  -- connected grid; no device attached until one is

local C     -- shared ctx, bound at init
local pget, ptoggle, clamp, window_bounds, FPS

-- semitone offsets per column, root-relative (nil = no black key there)
local GRID_WHITE = { 0, 2, 4, 5, 7, 9, 11, 12 }
local GRID_BLACK = { nil, 1, 3, nil, 6, 8, 10, nil }

-- note-pad row pairs { black row, white row, octave offset }: static, so
-- the per-frame grid refresh builds no tables
local GRID_NOTE_ROWS = { { 5, 6, 1 }, { 7, 8, 0 } }

-- window/loop slice pads: track what's held per row so a second press
-- while the first is down stretches the region between them
local slice_held = { win = {}, loop = {} }
local SLICE_IDS = {
  win = { "pos_start", "pos_end" },
  loop = { "loop_start", "loop_end" },
}

local function slice_key(kind, x, z)
  local h = slice_held[kind]
  if z == 1 then
    local anchor = h[1] or x   -- first held pad anchors the span
    h[#h + 1] = x
    local lo, hi = min(anchor, x), max(anchor, x)
    params:set(SLICE_IDS[kind][1], (lo - 1) / 8)
    params:set(SLICE_IDS[kind][2], hi / 8)
  else
    for i = #h, 1, -1 do
      if h[i] == x then table.remove(h, i) end
    end
  end
end

local function grid_note_key(x, y, z)
  if pget("keys_enable", 1) == 0 then return end
  local st
  if y == 6 or y == 8 then
    st = GRID_WHITE[x]
  else
    st = GRID_BLACK[x]
    if not st then
      -- the black rows' gap pads carry the utility functions (press only)
      if z == 1 then
        if y == 7 and (x == 1 or x == 8) then
          params:delta("kb_octave", x == 8 and 1 or -1)
          C.flash_id, C.flash_until = "kb_octave", C.frame + FPS
        elseif y == 5 and x == 1 then
          params:set("pitch", 1.0)
          C.flash_id, C.flash_until = "pitch", C.frame + FPS
        elseif y == 5 and x == 8 then
          ptoggle("pitch_quant")
        end
      end
      return
    end
  end
  if st == nil then return end
  -- a note pad: route to the drone `pitch` or a polyphonic voice, per
  -- pad_input. both edges, so a voice releases on lift. id 2000+ keeps grid
  -- voice ids distinct from MIDI (1000+) and the screen bank (0..8). pad_idx
  -- is the full semitone offset (st + octave), so pad selection tracks the
  -- played note like MIDI (minput passes the absolute note number).
  local oct = pget("kb_octave", 0) + (y <= 6 and 1 or 0)
  C.route_note(2000 + (y * 8 + x), 2 ^ ((st + 12 * oct) / 12), st + 12 * oct, z)
  if z == 1 then C.flash_id, C.flash_until = "pitch", C.frame + FPS end
end

-- SEQ page (S18): the grid becomes the step sequencer while the SEQ screen
-- page is active (page-aware, like snu) — otherwise it's the normal mangler
-- surface. rows 1-2 are the 16 steps (tap to toggle), row 7 picks the slice,
-- row 8 is transport (play / clear).
local function is_seq_page()
  return C.PAGES[C.page] == "SEQ"
end

-- a pad on rows 1-2 -> a step index 1..16 (row 1 = steps 1-8, row 2 = 9-16)
local function seq_step_at(x, y)
  if y == 1 then return x
  elseif y == 2 then return x + 8 end
  return nil
end

local function seq_grid_key(x, y, z)
  if z ~= 1 then return end
  local step = seq_step_at(x, y)
  if step then
    C.seq.toggle_step(step)                       -- tap a step: toggle it
  elseif y == 7 and x >= 1 and x <= 8 then
    params:set("seq_slice", x - 1)                -- row 7: pick the slice
  elseif y == 8 then
    if x == 1 then ptoggle("seq_play")            -- transport: play / stop
    elseif x == 8 then C.seq.clear() end          -- clear the pattern
  end
end

local function seq_redraw()
  local sq = C.seq
  local len = pget("seq_len", 16)
  local pos = sq.pos
  local playing = pget("seq_play", 0) == 1
  -- rows 1-2: the 16 steps. playhead brightest, active mid, rest dim, steps
  -- beyond the length dark.
  for i = 1, 16 do
    local x = ((i - 1) % 8) + 1
    local y = i <= 8 and 1 or 2
    local lvl
    if i > len then lvl = 0
    elseif playing and i == pos then lvl = 15
    elseif sq.pattern[i] then lvl = 8
    else lvl = 2 end
    gg:led(x, y, lvl)
  end
  -- row 7: slice select (current lit)
  local slice = pget("seq_slice", 0)
  for x = 1, 8 do gg:led(x, 7, (x - 1) == slice and 15 or 3) end
  -- row 8: transport — play/stop (left, lit while running), clear (right)
  gg:led(1, 8, playing and 15 or 4)
  gg:led(8, 8, 4)
end

-- SCENE page (S19): like SEQ, the grid follows the screen — while the SCENE
-- page is up the whole surface becomes the scene bank.
--
--   row 1  the 8 slots: tap = recall (quantized per scene_recall_mode).
--          hold CAP and tap = capture into it; hold CLR and tap = clear it
--   row 3  morph endpoint A        row 4  morph endpoint B
--   row 6  morph amount, 8 steps (tap one — the sweep in reach of a finger)
--   row 8  [CAP] [CLR] · [CHAOS, hold] · · [SAFE] [UNDO]
--
-- every pad drives a param, so it does exactly what the screen keys do.
local function is_scene_page()
  return C.PAGES[C.page] == "SCENE"
end

local scene_mod = { cap = false, clr = false }

local function scene_grid_key(x, y, z)
  -- row 8 first: these are the momentary/modifier pads, they need BOTH edges
  if y == 8 then
    if x == 1 then scene_mod.cap = (z == 1)
    elseif x == 2 then scene_mod.clr = (z == 1)
    elseif x == 4 then params:set("chaos_throw", z)          -- hold for mayhem
    elseif x == 7 then params:set("scene_safe_capture", z)
    elseif x == 8 then params:set("scene_safe_restore", z) end
    return
  end
  if z ~= 1 then return end
  if y == 1 then
    params:set("scene_slot", x)                              -- screen follows
    if scene_mod.cap then C.scene_capture(x)
    elseif scene_mod.clr then C.scene_clear(x)
    else C.scene_recall(x) end
  elseif y == 3 then params:set("scene_morph_a", x)
  elseif y == 4 then params:set("scene_morph_b", x)
  elseif y == 6 then params:set("scene_morph_amt", (x - 1) / 7) end
end

local function scene_redraw()
  local sc = C.scene
  local sel = floor(pget("scene_slot", 1) + 0.5)
  local a = floor(pget("scene_morph_a", 1) + 0.5)
  local b = floor(pget("scene_morph_b", 2) + 0.5)
  -- row 1: the bank. queued recall blinks, selected is bright, occupied mid,
  -- empty barely there — the same brightness-is-truth rule as the screen.
  for x = 1, 8 do
    local filled = sc.slots[x] ~= nil
    local lvl
    if sc.pending == x then lvl = (C.frame % FPS) < (FPS / 2) and 15 or 4
    elseif x == sel then lvl = filled and 12 or 3
    elseif filled then lvl = 6
    else lvl = 1 end
    gg:led(x, 1, lvl)
  end
  -- rows 3/4: the morph endpoints (lit = chosen, dim = a slot with something
  -- in it to choose)
  for x = 1, 8 do
    local filled = sc.slots[x] ~= nil
    gg:led(x, 3, x == a and 15 or (filled and 4 or 1))
    gg:led(x, 4, x == b and 15 or (filled and 4 or 1))
  end
  -- row 6: the morph amount as a bar with a bright head
  local head = floor(pget("scene_morph_amt", 0) * 7 + 0.5) + 1
  for x = 1, 8 do
    gg:led(x, 6, x == head and 15 or (x < head and 5 or 1))
  end
  -- row 8: modifiers (lit while held), chaos (lit while thrown), the pair of
  -- safety pads (dark until there's a safe state to go back to)
  gg:led(1, 8, scene_mod.cap and 15 or 4)
  gg:led(2, 8, scene_mod.clr and 15 or 4)
  gg:led(4, 8, pget("chaos_throw", 0) == 1 and 15 or 4)
  gg:led(7, 8, sc.safe and 6 or 2)
  gg:led(8, 8, sc.safe and 6 or 1)
end

-- which layout the grid is showing right now (the surface follows the screen
-- page, like snu)
local function surface()
  if is_seq_page() then return "seq" end
  if is_scene_page() then return "scene" end
  return "main"
end

-- a pad's RELEASE belongs to the surface that took its PRESS.
-- the grid is page-aware, so without this, changing page mid-hold hands the
-- release to a layout that doesn't know the pad — and whatever it was holding
-- LATCHES: a tape stuck in reverse (hold (3,2), turn E1 to SEQ, let go), a
-- note that never lifts, a chaos throw with no way back. the press decides who
-- gets both edges. (this predates the SCENE page — it arrived with the SEQ
-- surface in S18 and was live on tape_reverse.)
local key_surface = {}

local function grid_key(x, y, z)
  if x > 8 or y > 8 then return end  -- wider/taller grids: top-left 8x8
  local k = y * 8 + x
  local s
  if z == 1 then
    s = surface()
    key_surface[k] = s
  else
    s = key_surface[k] or surface()
    key_surface[k] = nil
  end
  if s == "seq" then return seq_grid_key(x, y, z) end
  if s == "scene" then return scene_grid_key(x, y, z) end
  if y == 1 then
    if z ~= 1 then return end
    if x == 1 then ptoggle("rec")
    elseif x == 2 then ptoggle("freeze")
    elseif x >= 3 and x <= 7 then params:set("mode", x - 2)  -- OFF/GRAIN/WARP/PV/PLAY
    elseif x == 8 then ptoggle("pv_freeze") end
  elseif y == 2 then
    if x == 3 then
      params:set("tape_reverse", z)  -- momentary, like K1+K2 on TAPE
    elseif z == 1 then
      if x == 1 then ptoggle("tape_rec")
      elseif x == 2 then ptoggle("tape_freeze")
      elseif x == 7 then C.fx_dry()                -- DRY throw (mangler.lua)
      elseif x == 8 then ptoggle("stop_all") end   -- master STOP, right edge
    end
  elseif y == 3 or y == 4 then
    slice_key(y == 3 and "win" or "loop", x, z)
  else
    grid_note_key(x, y, z)
  end
end

function M.init(ctx)
  C = ctx
  pget, ptoggle, clamp, window_bounds =
    ctx.pget, ctx.ptoggle, ctx.clamp, ctx.window_bounds
  FPS = ctx.FPS
end

function M.redraw()
  if not (gg and gg.device) then return end
  gg:all(0)

  -- SEQ / SCENE pages take over the whole grid (page-aware, like snu)
  if is_seq_page() then seq_redraw() gg:refresh() return end
  if is_scene_page() then scene_redraw() gg:refresh() return end
  -- (no need to clear the SCENE modifiers here: key_surface routes their
  -- release back to scene_grid_key even if the page has moved on)

  -- row 1: engine transport + mode radio
  gg:led(1, 1, pget("rec", 0) == 1 and 15 or 2)
  gg:led(2, 1, pget("freeze", 0) == 1 and 15 or 2)
  local mode = pget("mode", 2)
  for x = 3, 7 do gg:led(x, 1, (x - 2) == mode and 15 or 3) end
  gg:led(8, 1, pget("pv_freeze", 0) == 1 and 15 or 2)

  -- row 2: tape transport + the master STOP on the right edge (blinks
  -- while stopped, same urgency as the header's STP flag)
  gg:led(1, 2, pget("tape_rec", 0) == 1 and 15 or 2)
  gg:led(2, 2, pget("tape_freeze", 0) == 1 and 15 or 2)
  gg:led(3, 2, pget("tape_reverse", 0) == 1 and 15 or 2)
  gg:led(7, 2, 3)  -- DRY: a plain action pad, no state to claim
  gg:led(8, 2, pget("stop_all", 0) == 1
    and ((C.frame % FPS) < (FPS / 2) and 15 or 8) or 2)

  -- rows 3/4: slices lit across the active region, head pad brightest
  local wlo, whi = window_bounds()
  local la, lb = pget("loop_start", 0), pget("loop_end", 1)
  local llo, lhi = min(la, lb), max(la, lb)
  for x = 1, 8 do
    local a, b = (x - 1) / 8, x / 8
    gg:led(x, 3, (a < whi and b > wlo) and 6 or 1)
    gg:led(x, 4, (a < lhi and b > llo) and 6 or 1)
  end
  -- engine write head glows on the window row while capturing — you see
  -- where the take is landing without looking at the screen (playhead is
  -- drawn after, so it wins a shared pad)
  if pget("rec", 0) == 1 and pget("freeze", 0) == 0 then
    gg:led(floor(clamp(C.rec_phase, 0, 0.999) * 8) + 1, 3, 11)
  end
  gg:led(floor(clamp(C.play_phase, 0, 0.999) * 8) + 1, 3, 15)
  gg:led(floor(clamp(C.tape_phase, 0, 0.999) * 8) + 1, 4, 15)

  -- rows 5-8: note pads. current pitch lights its pad; the whole block
  -- dims when note input is off so it's visible why pads are dead
  local en = pget("keys_enable", 1) == 1
  local oct = pget("kb_octave", 0)
  local st_cur = util.round(12 * log(pget("pitch", 1), 2))
  for _, rows in ipairs(GRID_NOTE_ROWS) do
    local by, wy, o = rows[1], rows[2], oct + rows[3]
    for x = 1, 8 do
      local w = GRID_WHITE[x] + 12 * o
      gg:led(x, wy, not en and 1 or w == st_cur and 15
        or (x == 1 or x == 8) and 6 or 4)
      if GRID_BLACK[x] then
        local b = GRID_BLACK[x] + 12 * o
        gg:led(x, by, not en and 1 or b == st_cur and 15 or 2)
      end
    end
  end
  gg:led(1, 7, en and 3 or 1)  -- octave -
  gg:led(8, 7, en and 3 or 1)  -- octave +
  gg:led(1, 5, en and 3 or 1)  -- pitch reset
  gg:led(8, 5, (en and pget("pitch_quant", 0) == 1) and 15 or (en and 3 or 1))

  gg:refresh()
end

function M.connect()
  gg = grid_mod.connect()
  M.gg = gg
  if gg then gg.key = grid_key end
end

function M.cleanup()
  if gg then
    gg.key = nil
    if gg.device then
      gg:all(0)
      gg:refresh()
    end
  end
end

return M
