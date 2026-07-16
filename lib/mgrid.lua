-- mgrid: the optional 8x8 grid surface — monome grid, or launchpad-style
-- controllers via midigrid.
--
-- native monome grids just work; with the midigrid library installed
-- (~/dust/code/midigrid) a launchpad-family or APC mini controller stands
-- in — but only when no real grid is attached (a monome on grid vport 1
-- wins). every pad drives params, the same single source of truth as keys,
-- encoders, and MIDI CCs.
--
-- THE SPINE (NU-4, doc/redesign.md §7): rows 1-2 and 7-8 NEVER change
-- meaning; only the workspace rows 3-6 follow the screen page. your hands
-- always know where the scenes, the transport, and the notes are.
--
--   row 1  SCENES, from any page: tap = recall · hold = PEEK (borrow the
--          scene, release comes home — the punch law) · with the SCENE
--          workspace's CAP/CLR modifiers held: capture / clear
--   row 2  STATE STRIP: [rec][tape rec][tape rev, hold][pv frz][tape frz]
--          [seq run] · [DRY] [STOP]
--   rows 3-6  the WORKSPACE (follows the page):
--     main   row 3 window slices (span gesture; write head glows while
--            recording) · row 4 tape loop slices (same gesture) · row 5
--            mode radio x1-5 (OFF GRAIN WARP PV PLAY) + pitch reset x7 /
--            pitch quantize x8 · row 6 dark
--     PADS   rows 3-4 the 16 steps (tap toggles) · row 5 slice select ·
--            row 6 run x1 / clear x8
--     SCENE  row 3 AIM (point the morph without jumping) · row 5 the morph
--            bar · row 6 [CAP mod][CLR mod] · [CHAOS, hold] · · [◄ back]
--   rows 7-8  ONE piano octave (black row above white; same shape as the
--          typing keyboard). row 7 gap pads x1/x8 = octave -/+

local floor, min, max, log = math.floor, math.min, math.max, math.log

local M = { gg = nil, have_midigrid = false, have_launchpad = false }

local grid_mod = grid
local no_monome = false    -- true when no native monome grid holds grid vport 1
do
  local gname = (grid.vports and grid.vports[1] and grid.vports[1].name)
    or "none"
  no_monome = gname == "none"
  -- midigrid is loaded as the FALLBACK backend; a Launchpad Mini MK3 is
  -- preferred over it at connect time (real per-pad colour vs midigrid's
  -- monochrome emulation — see the Launchpad driver below).
  if no_monome and util.file_exists(_path.code .. "midigrid") then
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

-- ============================================================================
-- Launchpad Mini MK3 — native colour driver (optional)
-- ============================================================================
-- midigrid emulates a MONOCHROME grid, so on a launchpad every state shows as
-- one hue at different brightness ("shades of yellow"). This driver talks to a
-- Mini MK3 DIRECTLY in Programmer mode and lights each pad with a real RGB
-- colour, while still feeding pad presses to the same grid_key handler. It
-- takes priority over midigrid when a Mini MK3 is attached; every device call
-- is guarded (pcall) so a missing/renamed/odd device falls back to midigrid/
-- native cleanly — it can't brick. Protocol verified against Novation's
-- "Launchpad Mini MK3 Programmer's Reference" (SysEx, note grid, RGB lighting).

-- SysEx: enter Programmer mode / return to Live (device id 0x0D); RGB LED
-- header (command 0x03) is followed by colourspecs `03 <note> <R> <G> <B>`.
local LP_PROG    = { 0xF0, 0x00, 0x20, 0x29, 0x02, 0x0D, 0x0E, 0x01, 0xF7 }
local LP_LIVE    = { 0xF0, 0x00, 0x20, 0x29, 0x02, 0x0D, 0x0E, 0x00, 0xF7 }
local LP_RGB_HDR = { 0xF0, 0x00, 0x20, 0x29, 0x02, 0x0D, 0x03 }

-- norns brightness 0-15 -> Launchpad RGB (each 0-127, i.e. hex/2). The grid
-- draw code sends BRIGHTNESS; we colour it here. The sequencer uses a few
-- UNIQUE levels (7, 9, 13 appear nowhere else on the grid — see draw_pads_ws)
-- so its states get their OWN hues: rest=blue, note=green, slice=orange,
-- clear=red, playhead=white; shared levels stay a calm blue/teal/white so the
-- whole surface reads cleanly. Every triple is tweakable live on the device.
local LP_RGB = {
  [0]  = { 0, 0, 0 },       -- off
  [1]  = { 7, 7, 13 },      -- near-black         (empty slot / disabled key)
  [2]  = { 16, 16, 34 },    -- dim blue-grey      (idle strip)
  [3]  = { 26, 26, 100 },   -- BLUE               (seq rest / low states)
  [4]  = { 34, 34, 48 },    -- soft grey-blue     (white key / filled slot)
  [5]  = { 24, 60, 90 },    -- steel blue         (morph filled)
  [6]  = { 30, 96, 110 },   -- teal               (in-region slice / gap pad)
  [7]  = { 110, 22, 22 },   -- RED                (seq clear pad)
  [8]  = { 120, 84, 34 },   -- amber              (safe cell)
  [9]  = { 28, 115, 40 },   -- GREEN              (seq note ON / pressed step)
  [10] = { 40, 110, 120 },  -- cyan               (latched state)
  [11] = { 42, 112, 46 },   -- green              (run / rec write head)
  [12] = { 122, 104, 28 },  -- YELLOW             (mode selected / quantize)
  [13] = { 127, 66, 8 },    -- ORANGE             (seq slice selected)
  [14] = { 90, 90, 110 },   -- (spare)
  [15] = { 120, 120, 120 }, -- WHITE              (playhead / selection / writes)
}

-- programmer-mode pad note <-> (x,y); y=1 is the TOP row, LP row 8 (notes 81-88)
local function lp_note(x, y) return (9 - y) * 10 + x end
local function lp_xy(note)
  local x, row = note % 10, floor(note / 10)
  if x < 1 or x > 8 or row < 1 or row > 8 then return nil end
  return x, 9 - row
end

-- find the Mini MK3's MIDI (surface) port, NOT the DAW port. ALSA names vary,
-- so match "mk3" + a launchpad marker and prefer the MIDI/2nd interface.
local function lp_find_device()
  if type(midi) ~= "table" or type(midi.devices) ~= "table" then return nil end
  local best
  for _, dev in pairs(midi.devices) do
    local n = (type(dev) == "table" and type(dev.name) == "string")
      and dev.name:lower() or ""
    if n:find("mk3", 1, true)
        and (n:find("mini", 1, true) or n:find("lpmini", 1, true)) then
      local is_daw = n:find("daw", 1, true) ~= nil
      if not is_daw and (n:find("midi", 1, true) or n:find("2")) then
        return dev                       -- the surface/MIDI port: take it
      end
      if not is_daw then best = best or dev end
    end
  end
  return best
end

-- a monome-grid-shaped backend over the Mini MK3: mgrid's draw code calls
-- gg:led/all/refresh with brightness; we buffer, diff, and push RGB SysEx.
local function lp_make_backend(dev)
  return { connect = function()
    if not pcall(function() dev:send(LP_PROG) end) then return nil end
    local gg = { device = dev, rows = 8, cols = 8, key = nil }
    local buf, sent = {}, {}
    function gg:led(x, y, z)
      if x >= 1 and x <= 8 and y >= 1 and y <= 8 then
        buf[lp_note(x, y)] = max(0, min(15, floor((z or 0) + 0.5)))
      end
    end
    function gg:all(z)
      local lvl = max(0, min(15, floor((z or 0) + 0.5)))
      for yy = 1, 8 do for xx = 1, 8 do buf[lp_note(xx, yy)] = lvl end end
    end
    function gg:refresh()                -- one SysEx carries every changed pad
      local m = { table.unpack(LP_RGB_HDR) }
      local changed = false
      for yy = 1, 8 do for xx = 1, 8 do
        local note = lp_note(xx, yy)
        local lvl = buf[note] or 0
        if sent[note] ~= lvl then
          sent[note] = lvl
          local c = LP_RGB[lvl] or LP_RGB[0]
          m[#m + 1] = 0x03               -- colourspec: RGB
          m[#m + 1] = note
          m[#m + 1] = c[1]; m[#m + 1] = c[2]; m[#m + 1] = c[3]
          changed = true
        end
      end end
      if not changed then return end
      m[#m + 1] = 0xF7
      pcall(function() dev:send(m) end)
    end
    function gg:shutdown() pcall(function() dev:send(LP_LIVE) end) end
    dev.event = function(data)           -- pad presses -> the grid_key handler
      local ok, msg = pcall(midi.to_msg, data)
      if not ok or type(msg) ~= "table" then return end
      if msg.type == "note_on" or msg.type == "note_off" then
        local x, y = lp_xy(msg.note or -1)
        if x and gg.key then
          gg.key(x, y, (msg.type == "note_on" and (msg.vel or 0) > 0) and 1 or 0)
        end
      end
    end
    return gg
  end }
end

local gg  -- connected grid; no device attached until one is

local C     -- shared ctx, bound at init
local pget, ptoggle, clamp, window_bounds, FPS

-- semitone offsets per column, root-relative (nil = no black key there)
local GRID_WHITE = { 0, 2, 4, 5, 7, 9, 11, 12 }
local GRID_BLACK = { nil, 1, 3, nil, 6, 8, 10, nil }

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

-- one piano octave, rows 7 (black) / 8 (white); gap pads = octave -/+
local function grid_note_key(x, y, z)
  if pget("keys_enable", 1) == 0 then return end
  local st
  if y == 8 then
    st = GRID_WHITE[x]
  else
    st = GRID_BLACK[x]
    if not st then
      if z == 1 and (x == 1 or x == 8) then
        params:delta("kb_octave", x == 8 and 1 or -1)
        C.flash_id, C.flash_until = "kb_octave", C.frame + FPS
      end
      return
    end
  end
  if st == nil then return end
  -- a note pad: route to the drone `pitch` or a polyphonic voice, per
  -- pad_input. both edges, so a voice releases on lift. id 2000+ keeps grid
  -- voice ids distinct from MIDI (1000+) and the screen bank (0..8).
  local oct = pget("kb_octave", 0)
  C.route_note(2000 + (y * 8 + x), 2 ^ ((st + 12 * oct) / 12), st + 12 * oct, z)
  if z == 1 then C.flash_id, C.flash_until = "pitch", C.frame + FPS end
end

-- ============================================================================
-- row 1 — scenes, under the punch law (tap = recall, hold = peek)
-- ============================================================================
local scene_mod = { cap = false, clr = false }
local srow_frame = {}     -- per-slot press frame, for the tap/punch split

local function scene_row_key(x, z)
  if z == 1 then
    params:set("scene_slot", x)              -- the screen follows the finger
    if scene_mod.cap then
      C.scene_capture(x)
      srow_frame[x] = nil
    elseif scene_mod.clr then
      C.scene_clear(x)
      srow_frame[x] = nil
    elseif C.scenes[x] then
      -- begin the PEEK: the ramp in mangler's tick drives the morph param
      C.peek_on, C.peek_back = true, false
      srow_frame[x] = C.frame
    else
      -- empty slot: recall it anyway so the page says SLOT EMPTY
      params:set("scene_recall", 1)
      params:set("scene_recall", 0)
      srow_frame[x] = nil
    end
  else
    local f = srow_frame[x]
    srow_frame[x] = nil
    if f then
      C.peek_on = false
      if C.frame - f < (C.TAP_FRAMES or 5) then
        -- a tap: COMMIT the recall; the scene is the new LIVE
        params:set("scene_recall", 1)
        params:set("scene_recall", 0)
        params:set("scene_morph_amt", 0)
      else
        C.peek_back = true                   -- borrowed: sweep home
      end
    end
  end
end

-- ============================================================================
-- row 2 — the state strip (identical on every page)
-- ============================================================================
local function state_row_key(x, z)
  if x == 3 then
    params:set("tape_reverse", z)            -- momentary, like TAPE K3 held
    return
  end
  if z ~= 1 then return end
  if x == 1 then ptoggle("rec")
  elseif x == 2 then ptoggle("tape_rec")
  elseif x == 4 then ptoggle("pv_freeze")
  elseif x == 5 then ptoggle("tape_freeze")
  elseif x == 6 then ptoggle("seq_play")
  elseif x == 7 then C.fx_dry()
  elseif x == 8 then ptoggle("stop_all") end
end

-- ============================================================================
-- workspaces (rows 3-6)
-- ============================================================================
local function is_pads_page() return C.PAGES[C.page] == "PADS" end
local function is_scene_page() return C.PAGES[C.page] == "SCENE" end

local function main_ws_key(x, y, z)
  if y == 3 or y == 4 then
    slice_key(y == 3 and "win" or "loop", x, z)
  elseif y == 5 and z == 1 then
    if x <= 5 then params:set("mode", x)     -- OFF GRAIN WARP PV PLAY
    elseif x == 7 then
      params:set("pitch", 1.0)
      C.flash_id, C.flash_until = "pitch", C.frame + FPS
    elseif x == 8 then ptoggle("pitch_quant") end
  end
end

local function pads_ws_key(x, y, z)
  if z ~= 1 then return end
  if y == 3 then C.seq.toggle_step(x)
  elseif y == 4 then C.seq.toggle_step(x + 8)
  elseif y == 5 then params:set("seq_slice", x - 1)
  elseif y == 6 then
    if x == 1 then ptoggle("seq_play")
    elseif x == 8 then C.seq.clear() end
  end
end

local function scene_ws_key(x, y, z)
  if y == 6 then                             -- modifier / momentary pads
    if x == 1 then scene_mod.cap = (z == 1)
    elseif x == 2 then scene_mod.clr = (z == 1)
    elseif x == 4 then params:set("chaos_throw", z)
    elseif x == 8 and z == 1 then            -- ◄ the way back
      params:set("scene_safe_restore", 1)
      params:set("scene_safe_restore", 0)
    end
    return
  end
  if z ~= 1 then return end
  if y == 3 then params:set("scene_slot", x)               -- aim, don't jump
  elseif y == 5 then params:set("scene_morph_amt", (x - 1) / 7) end
end

-- which workspace the grid is showing (the surface follows the screen page)
local function surface()
  if is_pads_page() then return "pads" end
  if is_scene_page() then return "scene" end
  return "main"
end

-- a pad's RELEASE belongs to the surface that took its PRESS.
-- rows 1-2 and 7-8 are page-independent, but the workspace is not — without
-- this, changing page mid-hold hands the release to a layout that doesn't
-- know the pad, and whatever it was holding LATCHES (the S18/S19 lesson).
local key_surface = {}

local function grid_key(x, y, z)
  if x > 8 or y > 8 then return end  -- wider/taller grids: top-left 8x8
  if y == 1 then return scene_row_key(x, z) end
  if y == 2 then return state_row_key(x, z) end
  if y >= 7 then return grid_note_key(x, y, z) end
  local k = y * 8 + x
  local s
  if z == 1 then
    s = surface()
    key_surface[k] = s
  else
    s = key_surface[k] or surface()
    key_surface[k] = nil
  end
  if s == "pads" then return pads_ws_key(x, y, z) end
  if s == "scene" then return scene_ws_key(x, y, z) end
  return main_ws_key(x, y, z)
end

function M.init(ctx)
  C = ctx
  pget, ptoggle, clamp, window_bounds =
    ctx.pget, ctx.ptoggle, ctx.clamp, ctx.window_bounds
  FPS = ctx.FPS
end

-- ============================================================================
-- LEDs
-- ============================================================================
local function draw_spine()
  -- row 1: the scene bank. queued blinks, selected bright, filled mid,
  -- empty barely there — brightness is truth, same as the screen.
  local sc = C.scene
  local sel = floor(pget("scene_slot", 1) + 0.5)
  for x = 1, 8 do
    local filled = sc.slots[x] ~= nil
    local lvl
    if sc.pending == x then lvl = (C.frame % FPS) < (FPS / 2) and 15 or 4
    elseif x == sel then lvl = filled and 12 or 3
    elseif filled then lvl = 6
    else lvl = 1 end
    gg:led(x, 1, lvl)
  end
  -- row 2: the state strip. writes carry the fast blink (matching the
  -- header flags); latched states sit steady; STOP is steady bright.
  local wblink = (C.frame % 4) < 2
  gg:led(1, 2, pget("rec", 0) == 1 and (wblink and 15 or 4) or 2)
  gg:led(2, 2, pget("tape_rec", 0) == 1 and (wblink and 15 or 4) or 2)
  gg:led(3, 2, pget("tape_reverse", 0) == 1 and 12 or 2)
  gg:led(4, 2, pget("pv_freeze", 0) == 1 and 10 or 2)
  gg:led(5, 2, pget("tape_freeze", 0) == 1 and 10 or 2)
  gg:led(6, 2, pget("seq_play", 0) == 1 and 10 or 2)
  gg:led(7, 2, 3)                                        -- DRY: an action
  gg:led(8, 2, pget("stop_all", 0) == 1 and 12 or 2)     -- STOP: latched
  -- rows 7-8: one piano octave; current pitch lights its pad; the block
  -- dims when note input is off so it's visible why pads are dead
  local en = pget("keys_enable", 1) == 1
  local oct = pget("kb_octave", 0)
  local st_cur = util.round(12 * log(pget("pitch", 1), 2))
  for x = 1, 8 do
    local w = GRID_WHITE[x] + 12 * oct
    gg:led(x, 8, not en and 1 or w == st_cur and 15
      or (x == 1 or x == 8) and 6 or 4)
    if GRID_BLACK[x] then
      local b = GRID_BLACK[x] + 12 * oct
      gg:led(x, 7, not en and 1 or b == st_cur and 15 or 2)
    end
  end
  gg:led(1, 7, en and 3 or 1)  -- octave -
  gg:led(8, 7, en and 3 or 1)  -- octave +
end

local function draw_main_ws()
  -- rows 3/4: slices lit across the active region, heads brightest
  local wlo, whi = window_bounds()
  local la, lb = pget("loop_start", 0), pget("loop_end", 1)
  local llo, lhi = min(la, lb), max(la, lb)
  for x = 1, 8 do
    local a, b = (x - 1) / 8, x / 8
    gg:led(x, 3, (a < whi and b > wlo) and 6 or 1)
    gg:led(x, 4, (a < lhi and b > llo) and 6 or 1)
  end
  -- the write head glows on the window row while capturing (playhead is
  -- drawn after, so it wins a shared pad)
  if pget("rec", 0) == 1 and pget("freeze", 0) == 0 then
    gg:led(floor(clamp(C.rec_phase, 0, 0.999) * 8) + 1, 3, 11)
  end
  gg:led(floor(clamp(C.play_phase, 0, 0.999) * 8) + 1, 3, 15)
  gg:led(floor(clamp(C.tape_phase, 0, 0.999) * 8) + 1, 4, 15)
  -- row 5: mode radio + pitch utilities
  local mode = pget("mode", 5)
  for x = 1, 5 do gg:led(x, 5, x == mode and 12 or 3) end
  local en = pget("keys_enable", 1) == 1
  gg:led(7, 5, en and 3 or 1)
  gg:led(8, 5, (en and pget("pitch_quant", 0) == 1) and 12 or (en and 3 or 1))
end

-- Grid sequencer LED map. mangler can only send BRIGHTNESS 0-15 (monome grids
-- are monochrome); on a launchpad, midigrid translates each brightness to a
-- colour via its own palette. The old scheme (rest 2, active 8, playhead 15)
-- put active + playhead both high on that ramp, so on a launchpad they read as
-- two shades of the same yellow — the reported confusion. These values are
-- pushed as far apart as brightness allows AND chosen to land on DISTINCT
-- palette entries on RGB-launchpad midigrid builds, so a pressed step is
-- clearly not an empty one. Intended colour per state (realised by midigrid;
-- confirm on your device — the exact hue is your launchpad's palette, not ours):
--   SEQ_OFF   0   beyond loop length   off / dark
--   SEQ_REST  3   in length, no note   dim  (blue on RGB palettes)
--   SEQ_ON    9   note ON (pressed)    green
--   SEQ_HEAD 15   the playhead step    white / full-bright
-- Row 5 slice-select and row 6 run/clear get their own separated levels too.
local SEQ_OFF, SEQ_REST, SEQ_ON, SEQ_HEAD = 0, 3, 9, 15
local SEQ_SLICE_ON, SEQ_SLICE_OFF = 13, 4   -- selected slice (orange) vs rest
local SEQ_RUN_ON, SEQ_RUN_OFF, SEQ_CLR = 11, 4, 7  -- run(green)/idle · clear(red)

local function draw_pads_ws()
  local sq = C.seq
  local len = pget("seq_len", 16)
  local pos = sq.pos
  local playing = pget("seq_play", 0) == 1
  for i = 1, 16 do
    local x = ((i - 1) % 8) + 1
    local y = i <= 8 and 3 or 4
    local lvl
    if i > len then lvl = SEQ_OFF
    elseif playing and i == pos then lvl = SEQ_HEAD
    elseif sq.pattern[i] then lvl = SEQ_ON
    else lvl = SEQ_REST end
    gg:led(x, y, lvl)
  end
  local slice = pget("seq_slice", 0)
  for x = 1, 8 do gg:led(x, 5, (x - 1) == slice and SEQ_SLICE_ON or SEQ_SLICE_OFF) end
  gg:led(1, 6, playing and SEQ_RUN_ON or SEQ_RUN_OFF)   -- run
  gg:led(8, 6, SEQ_CLR)                                 -- clear
end

local function draw_scene_ws()
  local sc = C.scene
  local sel = floor(pget("scene_slot", 1) + 0.5)
  -- row 3: where the morph is aimed
  for x = 1, 8 do
    gg:led(x, 3, x == sel and 15 or (sc.slots[x] and 4 or 1))
  end
  -- row 5: the morph amount as a bar with a bright head
  local head = floor(pget("scene_morph_amt", 0) * 7 + 0.5) + 1
  for x = 1, 8 do
    gg:led(x, 5, x == head and 15 or (x < head and 5 or 1))
  end
  -- row 6: modifiers, chaos (held), and the ◄ way back
  gg:led(1, 6, scene_mod.cap and 15 or 4)
  gg:led(2, 6, scene_mod.clr and 15 or 4)
  gg:led(4, 6, pget("chaos_throw", 0) == 1 and 15 or 4)
  gg:led(8, 6, sc.safe and 8 or 2)
end

function M.redraw()
  if not (gg and gg.device) then return end
  gg:all(0)
  draw_spine()
  local s = surface()
  if s == "pads" then draw_pads_ws()
  elseif s == "scene" then draw_scene_ws()
  else draw_main_ws() end
  gg:refresh()
end

function M.connect()
  gg = nil
  -- prefer a native Launchpad Mini MK3 colour driver over midigrid/native when
  -- no monome grid is attached; on ANY failure fall back — can't brick.
  if no_monome then
    local lp = lp_find_device()
    if lp then
      local ok, cand = pcall(function() return lp_make_backend(lp).connect() end)
      if ok and cand then
        gg = cand
        M.have_launchpad = true
        M.have_midigrid = false     -- the LP is driving, not midigrid
        print("mangler: Launchpad Mini MK3 colour driver — " .. tostring(lp.name))
      else
        print("mangler: Mini MK3 found but colour driver failed; using fallback")
      end
    end
  end
  if not gg then gg = grid_mod.connect() end   -- midigrid or native grid
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
    if gg.shutdown then gg:shutdown() end        -- LP: return to Live mode
    if M.have_launchpad and gg.device then gg.device.event = nil end
  end
end

return M
