-- mgrid: the optional 8x8 grid surface — monome grid, or launchpad-style
-- controllers via midigrid.
--
-- native monome grids just work; with the midigrid library installed
-- (~/dust/code/midigrid) a launchpad-family or APC mini controller stands
-- in — but only when no real grid is attached (a monome on grid vport 1
-- wins). every pad drives params, the same single source of truth as keys,
-- encoders, and MIDI CCs.
--
-- THE SPINE: rows 1-2 and 7-8 NEVER change
-- meaning; only the workspace rows 3-6 follow the screen page. your hands
-- always know where the scenes, the transport, and the notes are.
--
--   row 1  SCENES, from any page: tap = recall · hold = PEEK (borrow the
--          scene, release comes home — the punch law) · with the SCENE
--          workspace's CAP/CLR modifiers held: capture / clear
--   row 2  STATE STRIP: [rec][tape rec][tape rev, hold][pv frz][tape frz]
--          [notes->pads] · [DRY] [STOP]
--   rows 3-6  the WORKSPACE (follows the page):
--     main   row 3 window slices (span gesture; write head glows while
--            recording) · row 4 tape loop slices (same gesture) · row 5
--            mode radio x1-5 (OFF GRAIN WARP PV PLAY) + pitch reset x7 /
--            pitch quantize x8 · row 6 dark
--     PADS   row 3 the 8 slice pads (finger-drum, held) · row 5 slice select ·
--            row 6 voice type x1 / notes->pads x8
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
  -- monochrome emulation).
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

-- Colour language (two layers, each value 0-127):
--  * LP_HUE — named SEMANTIC colours the draw code asks for BY MEANING via the
--    4th arg of gg:led (red = recording, green = playing, purple = destructive,
--    …). A pad's brightness (0-15) scales the hue's intensity, so a blink or a
--    pulse still reads — and the monome/midigrid path, which ignores the hue
--    arg, still gets sensible brightness. Chosen with the user; tweak freely.
--  * LP_RGB — the fallback for pads drawn with NO hue (spatial things: piano
--    keys, octave pads), coloured by plain brightness.
local LP_HUE = {              -- indexed by LP_HUE_ID
  { 127, 22, 16 },   -- 1  red     recording / write head (STOP pulses it)
  { 28, 120, 42 },   -- 2  green   playing / running / placed step / capture
  { 30, 46, 122 },   -- 3  blue    available / empty / DRY
  { 120, 120, 120 }, -- 4  white   playhead / selection / cursor
  { 122, 104, 26 },  -- 5  yellow  mode selected / queued recall
  { 127, 64, 6 },    -- 6  orange  selected slice
  { 26, 112, 122 },  -- 7  cyan    frozen / held
  { 104, 26, 127 },  -- 8  purple  destructive (clear / chaos) / reverse
  { 26, 100, 104 },  -- 9  teal    active region (window / loop / morph travel)
}
local LP_HUE_ID = {
  red = 1, green = 2, blue = 3, white = 4, yellow = 5,
  orange = 6, cyan = 7, purple = 8, teal = 9,
}
local LP_RGB = {              -- brightness-only fallback (uncoloured pads)
  [0] = { 0, 0, 0 },    [1] = { 7, 7, 13 },    [2] = { 14, 14, 28 },
  [3] = { 20, 20, 44 }, [4] = { 34, 34, 48 },  [5] = { 40, 46, 62 },
  [6] = { 46, 58, 74 }, [7] = { 56, 64, 82 },  [8] = { 66, 74, 92 },
  [9] = { 78, 86, 104 },[10] = { 88, 96, 112 },[11] = { 96, 104, 118 },
  [12] = { 104, 110, 120 }, [13] = { 110, 116, 122 }, [14] = { 116, 118, 124 },
  [15] = { 120, 120, 120 },
}

-- triangle wave 0..1 over `p` frames — for the STOP breathing pulse
local function tri(f, p)
  local ph = (f % p) / p
  return ph < 0.5 and ph * 2 or (2 - ph * 2)
end

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
    local lvlbuf, huebuf, sent = {}, {}, {}
    function gg:led(x, y, z, color)      -- 4th arg = semantic hue name (optional)
      if x >= 1 and x <= 8 and y >= 1 and y <= 8 then
        local note = lp_note(x, y)
        lvlbuf[note] = max(0, min(15, floor((z or 0) + 0.5)))
        huebuf[note] = color and LP_HUE_ID[color] or 0
      end
    end
    function gg:all(z)
      local lvl = max(0, min(15, floor((z or 0) + 0.5)))
      for yy = 1, 8 do for xx = 1, 8 do
        local note = lp_note(xx, yy); lvlbuf[note] = lvl; huebuf[note] = 0
      end end
    end
    -- the SysEx message buffer, reused every frame. This is the 15fps grid
    -- path, and it allocated a fresh table (and a fresh pcall closure below)
    -- on every refresh — in a codebase that hoisted closures out of the redraw
    -- loop for exactly this reason on the Pi.
    local msg = {}
    local function send_msg() dev:send(msg) end

    function gg:refresh()                -- one SysEx carries every changed pad
      local m = msg
      local n = #LP_RGB_HDR
      for i = 1, n do m[i] = LP_RGB_HDR[i] end
      for i = #m, n + 1, -1 do m[i] = nil end   -- drop last frame's tail
      local changed = false
      for yy = 1, 8 do for xx = 1, 8 do
        local note = lp_note(xx, yy)
        local lvl = lvlbuf[note] or 0
        local hue = huebuf[note] or 0
        local key = lvl + hue * 16       -- a number: no per-frame allocation
        if sent[note] ~= key then
          sent[note] = key
          m[#m + 1] = 0x03               -- colourspec: RGB
          m[#m + 1] = note
          if hue > 0 and lvl > 0 then     -- a semantic colour, scaled by level
            local b = LP_HUE[hue]
            local s = 0.4 + 0.6 * lvl / 15
            m[#m + 1] = floor(b[1] * s); m[#m + 1] = floor(b[2] * s); m[#m + 1] = floor(b[3] * s)
          elseif hue > 0 then             -- hue but level 0 = off
            m[#m + 1] = 0; m[#m + 1] = 0; m[#m + 1] = 0
          else                            -- no hue: plain brightness ramp
            local c = LP_RGB[lvl] or LP_RGB[0]
            m[#m + 1] = c[1]; m[#m + 1] = c[2]; m[#m + 1] = c[3]
          end
          changed = true
        end
      end end
      if not changed then return end
      m[#m + 1] = 0xF7
      pcall(send_msg)
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
local slice_held = { win = {}, loop = {}, lay1 = {}, lay2 = {} }
local SLICE_IDS = {
  win = { "pos_start", "pos_end" },
  loop = { "loop_start", "loop_end" },
  -- the layer decks' loops, driven by the same two-pad span gesture
  lay1 = { "lay1_start", "lay1_end" },
  lay2 = { "lay2_start", "lay2_end" },
}

local function slice_key(kind, x, z)
  local h = slice_held[kind]
  if z == 1 then
    local anchor = h[1] or x   -- first held pad anchors the span
    h[#h + 1] = x
    local lo, hi = min(anchor, x), max(anchor, x)
    local sid, eid = SLICE_IDS[kind][1], SLICE_IDS[kind][2]
    local nlo, nhi = (lo - 1) / 8, hi / 8
    -- widening edge FIRST, the move_pair/EDGE_PAIRS rule. Written start-then-
    -- end unconditionally, a span to the RIGHT of the old one crossed the pair
    -- for one write, and a crossed pair is a region that is neither the old
    -- nor the new one (the tape/layer actions floor it to a 100ms loop).
    if nlo < pget(sid, 0) then
      params:set(sid, nlo)
      params:set(eid, nhi)
    else
      params:set(eid, nhi)
      params:set(sid, nlo)
    end
  else
    for i = #h, 1, -1 do
      if h[i] == x then table.remove(h, i) end
    end
  end
end

-- one piano octave, rows 7 (black) / 8 (white); gap pads = octave -/+
local function grid_note_key(x, y, z)
  -- the gate applies to PRESSES only. A release belongs to the press that
  -- opened it, so keys_enable going off mid-hold must never swallow a note-off
  -- and strand a polyphonic voice sounding forever — the same trap already
  -- guarded for MIDI and for the typing keyboard in lib/minput.lua. A release
  -- for a note we never opened is a no-op inside route_note/pad_trigger.
  if z == 1 and pget("keys_enable", 1) == 0 then return end
  local st
  if y == 8 then
    st = GRID_WHITE[x]
  else
    st = GRID_BLACK[x]
    if not st then
      if z == 1 and (x == 1 or x == 8) then
        params:delta("kb_octave", x == 8 and 1 or -1)
      end
      return
    end
  end
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
local peek_pad = nil      -- which scene pad OWNS the peek (one morph, one owner)

local function scene_row_key(x, z)
  -- CAP/CLR only capture/clear while the SCENE workspace is showing (that's the
  -- only place their modifier pads live); from any other page row 1 is a plain
  -- recall/peek, so a modifier held while navigating away can't overwrite.
  local on_scene = C.PAGES[C.page] == "SCENE"
  if z == 1 then
    params:set("scene_slot", x)              -- the screen follows the finger
    if scene_mod.cap and on_scene then
      C.scene_capture(x)
      srow_frame[x] = nil
    elseif scene_mod.clr and on_scene then
      C.scene_clear(x)
      srow_frame[x] = nil
    elseif C.scenes[x] then
      -- begin the PEEK: the ramp in mangler's tick drives the morph param.
      -- this pad becomes the owner (a later pad press takes over) so releasing
      -- the FIRST of two held pads can't cancel the second's peek.
      C.peek_on, C.peek_back = true, false
      peek_pad = x
      srow_frame[x] = C.frame
    else
      -- empty slot: recall it anyway so the page says SLOT EMPTY
      C.pulse("scene_recall")
      srow_frame[x] = nil
    end
  else
    local f = srow_frame[x]
    srow_frame[x] = nil
    -- only the pad that OWNS the peek ends it; a superseded pad's release is a
    -- no-op (else it recalls whatever slot is now selected, not its own)
    if f and peek_pad == x then
      C.peek_on = false
      peek_pad = nil
      params:set("scene_slot", x)            -- recall THIS pad's slot
      if C.frame - f < (C.TAP_FRAMES or 5) then
        -- a tap: COMMIT the recall; the scene is the new LIVE. leave the amt
        -- alone when the recall only QUEUED (BEAT/BAR) — zeroing it then
        -- force-applies the old A and bounces the sound around the sync point
        C.pulse("scene_recall")
        if not C.scene.pending then params:set("scene_morph_amt", 0) end
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
  elseif x == 6 then ptoggle("pad_input")   -- notes -> pads/drone (was seq run)
  elseif x == 7 then C.fx_dry()
  elseif x == 8 then ptoggle("stop_all") end
end

-- ============================================================================
-- workspaces (rows 3-6)
-- ============================================================================
local function is_pads_page() return C.PAGES[C.page] == "PADS" end
local function is_scene_page() return C.PAGES[C.page] == "SCENE" end
local function is_layers_page() return C.PAGES[C.page] == "LAYERS" end

-- which deck a workspace row addresses: row 3 is layer 1, row 4 is layer 2 —
-- the same order they are drawn in on the screen
local function layer_of(y) return (y == 3) and 1 or 2 end
local function lay(n, k) return "lay" .. n .. "_" .. k end

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
  -- row 3 = the 8 slice pads: finger-drum the chops as HELD voices (press on,
  -- release off — so it needs both edges, unlike the rest of the workspace).
  -- ids 2600+ clear the note (2000+) / MIDI (1000+) / screen (0-8) namespaces.
  if y == 3 then C.pad_trigger(2600 + x, x - 1, z); return end
  if z ~= 1 then return end
  if y == 5 then params:set("seq_slice", x - 1)         -- select a slice to edit
  elseif y == 6 then
    if x == 1 then params:set("pad_voice", pget("pad_voice", 1) == 1 and 2 or 1)
    elseif x == 8 then ptoggle("pad_input") end          -- notes -> pads/drone
  end
end

-- LAYERS: one loop-span row per deck (the same two-pad gesture the window and
-- the tape loop use), then rec and mute per deck. The decks are independent, so
-- each gets its own row rather than sharing a selector — on a grid you want to
-- reach the other deck without changing what the screen is showing.
local function layers_ws_key(x, y, z)
  if y == 3 or y == 4 then
    local n = layer_of(y)
    slice_key("lay" .. n, x, z)
    return
  end
  if z ~= 1 then return end
  if y == 5 then                      -- rec: x1-2 = deck 1/2
    if x <= 2 then ptoggle(lay(x, "rec")) end
  elseif y == 6 then                  -- mute: x1-2 = deck 1/2
    if x <= 2 then ptoggle(lay(x, "play")) end
  end
end

local function scene_ws_key(x, y, z)
  if y == 6 then                             -- modifier / momentary pads
    if x == 1 then scene_mod.cap = (z == 1)
    elseif x == 2 then scene_mod.clr = (z == 1)
    elseif x == 4 then params:set("chaos_throw", z)
    elseif x == 8 and z == 1 then            -- ◄ the way back
      C.pulse("scene_safe_restore")
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
  if is_layers_page() then return "layers" end
  return "main"
end

-- a pad's RELEASE belongs to the surface that took its PRESS.
-- rows 1-2 and 7-8 are page-independent, but the workspace is not — without
-- this, changing page mid-hold hands the release to a layout that doesn't
-- know the pad, and whatever it was holding LATCHES (learned the hard way on device).
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
  if s == "layers" then return layers_ws_key(x, y, z) end
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
-- a state-strip pad (row 2): dim when off, bright + its hue when on
local function strip_led(x, on, hue, onlvl)
  gg:led(x, 2, on and (onlvl or 12) or 2, on and hue or nil)
end

local function draw_spine()
  -- row 1: the scene bank. queued blinks YELLOW, selected WHITE, filled a soft
  -- blue, empty barely there.
  local sc = C.scene
  local sel = floor(pget("scene_slot", 1) + 0.5)
  for x = 1, 8 do
    local filled = sc.slots[x] ~= nil
    if sc.pending == x then
      gg:led(x, 1, (C.frame % FPS) < (FPS / 2) and 15 or 4, "yellow")
    elseif x == sel then
      gg:led(x, 1, filled and 15 or 6, "white")
    elseif filled then
      gg:led(x, 1, 8, "blue")
    else
      gg:led(x, 1, 1)
    end
  end
  -- row 2: the state strip. RED = recording, GREEN = playing, CYAN = frozen,
  -- PURPLE = reverse, BLUE = DRY; STOP PULSES red so it reads apart from a
  -- steady recording-red. writes carry the fast blink (matching the header).
  local wblink = (C.frame % 4) < 2
  strip_led(1, pget("rec", 0) == 1, "red", wblink and 15 or 5)
  strip_led(2, pget("tape_rec", 0) == 1, "red", wblink and 15 or 5)
  strip_led(3, pget("tape_reverse", 0) == 1, "purple")
  strip_led(4, pget("pv_freeze", 0) == 1, "cyan")
  strip_led(5, pget("tape_freeze", 0) == 1, "cyan")
  strip_led(6, pget("pad_input", 0) == 1, "yellow")      -- notes routed to pads
  gg:led(7, 2, 7, "blue")                                -- DRY: an action
  local stopped = pget("stop_all", 0) == 1
  gg:led(8, 2, stopped and (5 + floor(9 * tri(C.frame, 22))) or 2,
    stopped and "red" or nil)                            -- STOP: pulsing red
  -- rows 7-8: one piano octave; current pitch lights WHITE; the block dims
  -- when note input is off so it's visible why pads are dead
  local en = pget("keys_enable", 1) == 1
  local oct = pget("kb_octave", 0)
  local st_cur = util.round(12 * log(pget("pitch", 1), 2))
  for x = 1, 8 do
    local w = GRID_WHITE[x] + 12 * oct
    if not en then gg:led(x, 8, 1)
    elseif w == st_cur then gg:led(x, 8, 15, "white")
    elseif x == 1 or x == 8 then gg:led(x, 8, 6)
    else gg:led(x, 8, 4) end
    if GRID_BLACK[x] then
      local b = GRID_BLACK[x] + 12 * oct
      if not en then gg:led(x, 7, 1)
      elseif b == st_cur then gg:led(x, 7, 15, "white")
      else gg:led(x, 7, 2) end
    end
  end
  gg:led(1, 7, en and 3 or 1)  -- octave -
  gg:led(8, 7, en and 3 or 1)  -- octave +
end

local function draw_main_ws()
  -- rows 3/4: slices lit TEAL across the active window / loop region
  local wlo, whi = window_bounds()
  local la, lb = pget("loop_start", 0), pget("loop_end", 1)
  local llo, lhi = min(la, lb), max(la, lb)
  for x = 1, 8 do
    local a, b = (x - 1) / 8, x / 8
    local inw = a < whi and b > wlo
    local inl = a < lhi and b > llo
    gg:led(x, 3, inw and 10 or 1, inw and "teal" or nil)
    gg:led(x, 4, inl and 10 or 1, inl and "teal" or nil)
  end
  -- the write head glows RED while capturing; playheads are WHITE (drawn after,
  -- so a playhead wins a shared pad)
  if pget("rec", 0) == 1 and pget("freeze", 0) == 0 then
    gg:led(floor(clamp(C.rec_phase, 0, 0.999) * 8) + 1, 3, 15, "red")
  end
  gg:led(floor(clamp(C.play_phase, 0, 0.999) * 8) + 1, 3, 15, "white")
  gg:led(floor(clamp(C.tape_phase, 0, 0.999) * 8) + 1, 4, 15, "white")
  -- row 5: mode radio (selected YELLOW) + pitch utilities
  local mode = pget("mode", 5)
  for x = 1, 5 do gg:led(x, 5, x == mode and 15 or 3, x == mode and "yellow" or nil) end
  local en = pget("keys_enable", 1) == 1
  local quant = en and pget("pitch_quant", 0) == 1
  gg:led(7, 5, en and 3 or 1)
  gg:led(8, 5, quant and 15 or (en and 3 or 1), quant and "yellow" or nil)
end

-- Grid PADS LED map, in the colour language: row 3 = the 8 slice pads (ORANGE,
-- bright while sounding); row 5 = the edit cursor (WHITE selection over dim
-- blue); row 6 = the selected slice's voice type + the note routing. Brightness
-- reads on the monome/midigrid path too (which ignores the hue).
local function draw_pads_ws()
  local held = C.pad_held
  local cur = floor(pget("seq_slice", 0) + 0.5)
  for x = 1, 8 do
    local sounding = held[2600 + x] ~= nil
    gg:led(x, 3, sounding and 15 or 4, sounding and "orange" or "blue")   -- play
    local sel = (x - 1) == cur
    gg:led(x, 5, sel and 15 or 6, sel and "white" or "blue")             -- select
  end
  gg:led(1, 6, 12, pget("pad_voice", 1) == 2 and "orange" or "cyan")     -- voice: SLICE/GRAIN
  gg:led(8, 6, pget("pad_input", 0) == 1 and 15 or 5, "yellow")          -- route
end

-- LAYERS: a span row per deck showing where its loop sits and where its head
-- is, then rec and mute. Recording BLINKS, the way every write flag in this
-- instrument does; a muted deck's row dims, so what you hear is what is lit.
local function draw_layers_ws()
  local decks = C.layers or {}
  for n = 1, math.min(#decks, 2) do
    local d = decks[n]
    local y = n + 2                       -- deck 1 -> row 3, deck 2 -> row 4
    local a = clamp(pget(d.id .. "_start", 0), 0, 1)
    local b = clamp(pget(d.id .. "_end", 1), 0, 1)
    local lo, hi = min(a, b), max(a, b)
    local playing = pget(d.id .. "_play", 1) == 1
    local recing = pget(d.id .. "_rec", 0) == 1
    local head = floor(clamp(d.phase, 0, 0.999) * 8) + 1
    for x = 1, 8 do
      -- the OVERLAP law, same as draw_main_ws's window/loop rows: a pad lights
      -- when the region touches any of its eighth. The old containment test
      -- left a loop narrower than one eighth entirely dark on its own row.
      local inside = (x - 1) / 8 < hi and x / 8 > lo
      local lvl = inside and (playing and 8 or 3) or 1
      if x == head and inside then lvl = 15 end
      gg:led(x, y, lvl, x == head and "white" or (recing and "red" or "teal"))
    end
    -- rec and mute, one column per deck
    gg:led(n, 5, recing and ((C.frame % 8) < 5 and 15 or 4) or 3, "red")
    gg:led(n, 6, playing and 9 or 3, "green")
  end
end

local function draw_scene_ws()
  local sc = C.scene
  local sel = floor(pget("scene_slot", 1) + 0.5)
  -- row 3: where the morph is aimed (selected WHITE, filled soft blue)
  for x = 1, 8 do
    if x == sel then gg:led(x, 3, 15, "white")
    elseif sc.slots[x] then gg:led(x, 3, 8, "blue")
    else gg:led(x, 3, 1) end
  end
  -- row 5: the morph amount as a TEAL bar with a white head (travel = active)
  local head = floor(pget("scene_morph_amt", 0) * 7 + 0.5) + 1
  for x = 1, 8 do
    if x == head then gg:led(x, 5, 15, "white")
    elseif x < head then gg:led(x, 5, 8, "teal")
    else gg:led(x, 5, 1) end
  end
  -- row 6: CAP (green, save), CLR + CHAOS (purple, destructive), ◄ way back
  gg:led(1, 6, scene_mod.cap and 15 or 4, scene_mod.cap and "green" or nil)
  gg:led(2, 6, scene_mod.clr and 15 or 4, scene_mod.clr and "purple" or nil)
  gg:led(4, 6, pget("chaos_throw", 0) == 1 and 15 or 5, "purple")
  gg:led(8, 6, sc.safe and 10 or 2, sc.safe and "white" or nil)
end

function M.redraw()
  if not (gg and gg.device) then return end
  local s = surface()
  -- CAP/CLR are SCENE-workspace modifiers (row 6). If we've navigated off the
  -- SCENE page they must not linger held — otherwise a page-independent
  -- scene-bank (row 1) tap silently captures/clears instead of recalling.
  if s ~= "scene" then scene_mod.cap, scene_mod.clr = false, false end
  gg:all(0)
  draw_spine()
  if s == "pads" then draw_pads_ws()
  elseif s == "layers" then draw_layers_ws()
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
