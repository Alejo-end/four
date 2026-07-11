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

local function grid_key(x, y, z)
  if x > 8 or y > 8 then return end  -- wider/taller grids: top-left 8x8
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
