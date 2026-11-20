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
--            mode radio x1-6 (OFF GRAIN WARP PV PLAY CLOUD) + pitch reset x7 /
--            pitch quantize x8 · row 6 the beat repeat, held: x1-5 = 1/2 to
--            1/32 (slide a finger across them for a roll) · x6/x7 visuals look
--            back/next · x8 visuals FLASH, held
--     PADS   row 3 the 8 slice pads (finger-drum, held) · row 5 slice select ·
--            row 6 voice type x1 · sequencer run x3, fewer/more hits x5/x6 ·
--            notes->pads x8
--     SCENE  row 3 AIM (point the morph without jumping) · row 5 the morph
--            bar · row 6 [CAP mod][CLR mod] · [CHAOS, hold] · · [◄ back]
--   rows 7-8  ONE piano octave (black row above white; same shape as the
--          typing keyboard). row 7 gap pads x1/x8 = octave -/+. lit: the
--          drone's pitch, or in pad mode the keys whose pad is sounding
--
-- On a Launchpad Mini MK3 the arrows step the page (left/right, like E1) and
-- the scene selector (up/down), and the pad is picked up on hot-plug.
--
-- An Exquis works beside any of these, or alone: its pads show rows 1 to 6
-- folded onto the hexagons, or play as its own keyboard. See the Exquis
-- section below for the layout.

local floor, min, max, log = math.floor, math.min, math.max, math.log
-- the visuals look names (lib/mosc.lua owns the list; kept in step by test_control)
local Mosc_LOOKS = { "AUTO", "BARS", "FILTER", "SHAPES", "RINGS", "MOSAIC", "TUNNEL", "WAVES", "FACETS" }

local M = { gg = nil, have_launchpad = false, midigrid_loaded = false,
            reconnect_due = false,
            ex = nil, ex_due = false }   -- an Exquis, beside the grid (see below)

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
      M.midigrid_loaded = true
      print("four: midigrid loaded — midi grid controllers welcome")
    else
      print("four: midigrid present but failed to load: " .. tostring(mg))
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
  { 118, 28, 30 },   -- 1  red     recording / write head (STOP pulses it); softer, rose-leaning
  { 28, 120, 42 },   -- 2  green   playing / running / placed step / capture
  { 30, 46, 122 },   -- 3  blue    available / empty / DRY
  { 120, 120, 120 }, -- 4  white   playhead / selection / cursor
  { 122, 104, 26 },  -- 5  yellow  mode selected / queued recall
  { 127, 64, 6 },    -- 6  orange  selected slice
  { 26, 112, 122 },  -- 7  cyan    frozen / held
  { 104, 26, 127 },  -- 8  purple  destructive (clear / chaos) / reverse
  { 26, 100, 104 },  -- 9  teal    active region (window / loop / morph travel)
  { 52, 92, 127 },   -- 10 ice     frozen (a periwinkle blue, apart from the slate "available" blue)
}
local LP_HUE_ID = {
  red = 1, green = 2, blue = 3, white = 4, yellow = 5,
  orange = 6, cyan = 7, purple = 8, teal = 9, ice = 10,
}
local LP_RGB = {              -- brightness-only fallback (uncoloured pads)
  [0] = { 0, 0, 0 },    [1] = { 7, 7, 13 },    [2] = { 14, 14, 28 },
  [3] = { 20, 20, 44 }, [4] = { 34, 34, 48 },  [5] = { 40, 46, 62 },
  [6] = { 46, 58, 74 }, [7] = { 56, 64, 82 },  [8] = { 66, 74, 92 },
  [9] = { 78, 86, 104 },[10] = { 88, 96, 112 },[11] = { 96, 104, 118 },
  [12] = { 104, 110, 120 }, [13] = { 110, 116, 122 }, [14] = { 116, 118, 124 },
  [15] = { 120, 120, 120 },
}

-- the Mini MK3's top-row arrows in Programmer mode (CC numbers)
local LP_UP, LP_DOWN, LP_LEFT, LP_RIGHT = 91, 92, 93, 94

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
-- `gone`: a device being unplugged. norns runs midi.remove BEFORE it deletes
-- the device from midi.devices, so the search has to skip it by hand.
local function lp_find_device(gone)
  if type(midi) ~= "table" or type(midi.devices) ~= "table" then return nil end
  local best
  for _, dev in pairs(midi.devices) do
    local n = (dev ~= gone and type(dev) == "table" and type(dev.name) == "string")
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
      elseif msg.type == "cc" and gg.button then
        -- the top row and the side column arrive as CCs in Programmer mode
        gg.button(msg.cc, msg.val or 0)
      end
    end
    -- light the four arrows once: they are fixed controls (page and slot)
    local m = {}
    for i = 1, #LP_RGB_HDR do m[i] = LP_RGB_HDR[i] end
    local w = LP_HUE[LP_HUE_ID.white]
    for cc = LP_UP, LP_RIGHT do
      m[#m + 1] = 0x03; m[#m + 1] = cc
      m[#m + 1] = floor(w[1] * 0.5); m[#m + 1] = floor(w[2] * 0.5); m[#m + 1] = floor(w[3] * 0.5)
    end
    m[#m + 1] = 0xF7
    pcall(function() dev:send(m) end)
    return gg
  end }
end

local gg  -- connected grid; no device attached until one is

local C     -- shared ctx, bound at init
local pget, ptoggle, clamp, window_bounds, FPS

-- semitone offsets per column, root-relative (nil = no black key there)
local GRID_WHITE = { 0, 2, 4, 5, 7, 9, 11, 12 }
local GRID_BLACK = { nil, 1, 3, nil, 6, 8, 10, nil }

-- region slice pads: track what's held per row so a second press while the
-- first is down stretches the region between them. A row is keyed by its
-- START param id, which also names the pair.
local slice_held = {}

local function slice_key(sid, eid, x, z)
  local h = slice_held[sid]
  if not h then h = {}; slice_held[sid] = h end
  if z == 1 then
    local anchor = h[1] or x   -- first held pad anchors the span
    h[#h + 1] = x
    local lo, hi = min(anchor, x), max(anchor, x)
    -- through the one pair writer (widening edge first: a crossed pair is a
    -- region that is neither the old one nor the new one)
    C.set_pair(sid, eid, (lo - 1) / 8, hi / 8)
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
  -- in pad mode `pitch` does not move, so do not swell a value that is not
  -- changing (the typing keyboard learned the same thing)
  if z == 1 and pget("pad_input", 0) == 0 then
    C.flash_id, C.flash_until = "pitch", C.frame + FPS
  end
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
      C.scene.capture(x)
      srow_frame[x] = nil
    elseif scene_mod.clr and on_scene then
      C.scene.clear(x)
      srow_frame[x] = nil
    elseif C.scene.slots[x] then
      -- begin the PEEK: the ramp in mangler's tick drives the morph param.
      -- this pad becomes the owner (a later pad press takes over) so releasing
      -- the FIRST of two held pads can't cancel the second's peek.
      C.peek_on, C.peek_back, C.peek_at = true, false, C.frame
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
        -- a tap: COMMIT the recall; the scene is the new LIVE (the landing
        -- zeroes the morph amount itself, once the scene has actually landed)
        C.pulse("scene_recall")
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

-- the beat repeat on the main workspace's row 6: hold a pad to repeat at its
-- division (x1 1/2 .. x5 1/32). A second pad while one is held changes the
-- division (a re-capture: a roll), and letting go of it goes back to the one
-- still held. The repeat ends when the last pad comes up, and only if a pad
-- started it: a footswitch holding `beat_repeat` keeps it.
local rep_held = {}         -- x -> the order it was pressed in
local rep_seq, rep_owned = 0, false
local function repeat_key(x, z)
  if z == 1 then
    rep_seq = rep_seq + 1
    rep_held[x] = rep_seq
    params:set("repeat_div", x)
    if pget("beat_repeat", 0) ~= 1 then
      rep_owned = true
      params:set("beat_repeat", 1)
    end
    return
  end
  rep_held[x] = nil
  local last, lx = 0, nil
  for k, n in pairs(rep_held) do
    if n > last then last, lx = n, k end
  end
  if lx then
    params:set("repeat_div", lx)
  elseif rep_owned then
    rep_owned = false
    params:set("beat_repeat", 0)
  end
end
M.repeat_key = repeat_key
-- the grid went away mid-hold: its releases will never come, so forget the
-- held pads and end a repeat the grid started
function M.repeat_drop()
  for k in pairs(rep_held) do rep_held[k] = nil end
  if rep_owned then
    rep_owned = false
    params:set("beat_repeat", 0)
  end
end

local function main_ws_key(x, y, z)
  if y == 6 then
    if x <= 5 then repeat_key(x, z)
    elseif x == 8 then params:set("vis_flash", z)          -- a hit on the visuals, held
    elseif z == 1 then                                       -- x6 / x7: the visuals look, back / next
      local n = #Mosc_LOOKS
      local cur = floor(pget("vis_look", 1) + 0.5)
      params:set("vis_look", (cur - 1 + (x == 7 and 1 or -1)) % n + 1)
    end
    return
  end
  if y == 3 then
    slice_key("pos_start", "pos_end", x, z)
  elseif y == 4 then
    slice_key("loop_start", "loop_end", x, z)
  elseif y == 5 and z == 1 then
    if x <= 6 then params:set("mode", x)     -- OFF GRAIN WARP PV PLAY CLOUD
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
    elseif x == 3 then ptoggle("step_run")               -- the sequencer
    elseif x == 5 then params:delta("step_fill", -1)     -- fewer hits
    elseif x == 6 then params:delta("step_fill", 1)      -- more hits
    elseif x == 8 then ptoggle("pad_input") end          -- notes -> pads/drone
  end
end

local function scene_ws_key(x, y, z)
  if y == 6 then                             -- modifier / momentary pads
    if x == 1 then scene_mod.cap = (z == 1)
    elseif x == 2 then scene_mod.clr = (z == 1)
    elseif x == 4 then params:set("chaos_throw", z)
    elseif x == 6 and z == 1 then            -- ORBIT run/stop (page merge:
      C.ptoggle("orbit_on")                  -- the wander has no key of its own)
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
  return "main"
end

-- a pad's RELEASE belongs to the surface that took its PRESS.
-- rows 1-2 and 7-8 are page-independent, but the workspace is not — without
-- this, changing page mid-hold hands the release to a layout that doesn't
-- know the pad, and whatever it was holding LATCHES (learned the hard way on device).
local key_surface = {}

-- the Mini MK3's arrows (other grids have none): left/right step the page
-- the way E1 does, so the workspace rows follow without reaching for the
-- encoder; up/down step the scene selector. Presses only.
local function lp_button(cc, val)
  if val == 0 then return end
  C.touch_input()
  if cc == LP_LEFT then C.step_page(-1)
  elseif cc == LP_RIGHT then C.step_page(1)
  elseif cc == LP_UP then params:delta("scene_slot", 1)
  elseif cc == LP_DOWN then params:delta("scene_slot", -1) end
end

local function grid_key(x, y, z)
  if x > 8 or y > 8 then return end  -- wider/taller grids: top-left 8x8
  C.touch_input()                    -- the grid counts as presence (idle dim)
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

-- ============================================================================
-- Exquis (Intuitive Instruments): Developer Mode driver (optional)
-- ============================================================================
-- The Exquis has 61 hexagonal pads in 11 rows (6 and 5 pads in turn), four
-- encoders with a push, and ten buttons. In Developer Mode it hands chosen
-- ZONES to the host: a zone taken over sends plain events on MIDI channel 16
-- and shows the colours the host sends. The protocol is from the maker's
-- "Developer Mode MIDI specification" (2025-03-10). NOT YET RUN ON A DEVICE:
-- the ALSA name ("exquis"), the encoder step size and the colours are untested.
--
-- The driver is not a grid backend. It lives beside the grid (M.ex), so a
-- monome grid and an Exquis work together. It has two modes, and the push of
-- encoder 4 changes between them:
--   PADS  the pads are the grid surface, drawn by the same code as the grid.
--         A taken pad sends no velocity, pressure or tilt (the protocol).
--   KEYS  the pads go back to the Exquis: its own layout, velocity and MPE.
--         Its notes reach four as any MIDI keyboard's do (lib/minput.lua).
-- PADS is the start when no grid is attached, KEYS when one is.
--
-- The 8x8 surface on the hexagons: a strip of eight zigzags along two rows,
-- from the left edge (odd cells on the row of 6, even cells on the row of 5
-- below it). The three pads at the right end of each pair stay dark.
--   rows 10+9 (top)  grid row 1, the scenes
--   rows 8+7 .. 2+1  grid rows 3 to 6, the workspace
--   row 0 (bottom)   grid row 2, the state strip, cells 1 to 6
-- The piano rows 7 and 8 are not on the pads: KEYS is the keyboard.
--   Record, Loop     rec, tape rec (strip cells 1, 2)
--   Clips, Play/Stop DRY, STOP (strip cells 7, 8)
--   Undo, Redo       the page, back and next       Down, Up  the scene slot
--   encoders 1 to 3  E1 to E3, their pushes K1 to K3
--   encoder 4        the track (as K1+E1), its push PADS or KEYS
-- Settings, Sound and the slider stay the Exquis's own.

-- Every number of the protocol and of the layout is named here, once, and
-- handed out as M.EX below: the stand-in of test/uisim/env.lua and the device
-- tools (test/device) read them from there and hold none of their own.
local EX_NAME = "exquis"                 -- in the device's name, any case
local EX_CH = 16                         -- the channel of a zone taken over
local EX_PADS = 61                       -- pad ids 0 .. EX_PADS - 1
local EX_EOX = 0xF7
local EX_SETUP = { 0xF0, 0x00, 0x21, 0x7E, 0x7F, 0x00 }   -- then the zone mask
local EX_LED   = { 0xF0, 0x00, 0x21, 0x7E, 0x7F, 0x04 }   -- then start id, (r g b fx)...
-- the Exquis asks for a repaint with this (after its settings menu closes)
local EX_REFRESH = { 0xF0, 0x00, 0x21, 0x7E, 0x7F, 0x03 }
-- zone masks: pads 01, encoders 02, Up/Down 08, the other buttons 20
local EX_ZONES_PADS, EX_ZONES_KEYS, EX_ZONES_OFF = 0x2B, 0x2A, 0x00
local EX_ROW_Y = { 6, 5, 4, 3, 1 }       -- pad row pair, from the bottom -> grid row
-- buttons that are cells of the state strip, as (y-1)*8+x
local EX_REC, EX_LOOP, EX_CLIPS, EX_PLAY = 102, 103, 104, 105
local EX_BTN_CELL = { [EX_REC] = 9, [EX_LOOP] = 10, [EX_CLIPS] = 15, [EX_PLAY] = 16 }
local EX_DOWN, EX_UP, EX_UNDO, EX_REDO = 106, 107, 108, 109
-- encoder ticks for one step. E1 and the track pick step through short lists.
local EX_ENC_DIV = { 3, 1, 1, 3 }
local EX_ENC = 110                       -- the encoders, then their pushes
local EX_PUSH = EX_ENC + #EX_ENC_DIV
local EX_ENC_MID = 64                    -- an encoder sends this plus its ticks
-- the controls with a light that the driver writes: the buttons, the encoders
local EX_LIT_LO, EX_LIT_HI = EX_REC, EX_PUSH - 1
local EX_NAV_KEY, EX_ENC_KEY = 5, 3      -- the fixed controls: a dim plain light

-- pad id (0 = bottom left .. 60 = top right, row by row) -> grid x, y, or nil
local function ex_cell(id)
  if id < 0 or id >= EX_PADS then return nil end
  local k, rem = floor(id / 11), id % 11
  local row, col = 2 * k, rem                      -- a row of 6
  if rem >= 6 then row, col = 2 * k + 1, rem - 6 end   -- a row of 5
  if row == 0 then return col + 1, 2 end
  local x = 2 * col + (row % 2 == 1 and 2 or 1)
  if x > 8 then return nil end
  return x, EX_ROW_Y[floor((row + 1) / 2)]
end

local EX_CELL = {}                        -- pad id -> (y-1)*8+x
for id = 0, EX_PADS - 1 do
  local x, y = ex_cell(id)
  if x then EX_CELL[id] = (y - 1) * 8 + x end
end

-- the driver's numbers, for whatever must agree with them
M.EX = {
  name = EX_NAME, ch = EX_CH, pads = EX_PADS, eox = EX_EOX,
  setup = EX_SETUP, led = EX_LED, refresh = EX_REFRESH,
  zones = { pads = EX_ZONES_PADS, keys = EX_ZONES_KEYS, off = EX_ZONES_OFF },
  cell = ex_cell, btn_cell = EX_BTN_CELL,
  rec = EX_REC, loop = EX_LOOP, clips = EX_CLIPS, play = EX_PLAY,
  down = EX_DOWN, up = EX_UP, undo = EX_UNDO, redo = EX_REDO,
  enc = EX_ENC, push = EX_PUSH, enc_div = EX_ENC_DIV, enc_mid = EX_ENC_MID,
  lit_lo = EX_LIT_LO, lit_hi = EX_LIT_HI,
}

-- `gone`: a device being unplugged, still listed (see lp_find_device)
local function ex_find_device(gone)
  if type(midi) ~= "table" or type(midi.devices) ~= "table" then return nil end
  for _, dev in pairs(midi.devices) do
    if dev ~= gone and type(dev) == "table" and type(dev.name) == "string"
        and dev.name:lower():find(EX_NAME, 1, true) then
      return dev
    end
  end
  return nil
end

-- a led key (level + hue * 16) -> r, g, b in the Launchpad's colour language
local function ex_rgb(key)
  local lvl, hue = key % 16, floor(key / 16)
  if hue > 0 then
    if lvl == 0 then return 0, 0, 0 end
    local b, s = LP_HUE[hue], 0.4 + 0.6 * lvl / 15
    return floor(b[1] * s), floor(b[2] * s), floor(b[3] * s)
  end
  local c = LP_RGB[lvl] or LP_RGB[0]
  return c[1], c[2], c[3]
end

-- the Exquis as a draw target (led, all, refresh, like a grid) and an event
-- source (key, turn, push, nav: set by the caller). nil when it cannot be set up.
local function ex_make(dev, pads)
  local ex = { device = dev, surface = pads and true or false }
  local buf, sent, held = {}, {}, {}
  local msg, acc, rpos = {}, { 0, 0, 0, 0 }, 0
  local function send_msg() dev:send(msg) end
  local function setup(mask)
    return pcall(function()
      dev:send({ EX_SETUP[1], EX_SETUP[2], EX_SETUP[3], EX_SETUP[4], EX_SETUP[5],
                 EX_SETUP[6], mask, EX_EOX })
    end)
  end
  if not setup(ex.surface and EX_ZONES_PADS or EX_ZONES_KEYS) then return nil end

  function ex:led(x, y, z, color)
    if x >= 1 and x <= 8 and y >= 1 and y <= 8 then
      buf[(y - 1) * 8 + x] = max(0, min(15, floor((z or 0) + 0.5)))
        + (color and LP_HUE_ID[color] or 0) * 16
    end
  end
  function ex:all(z)
    local lvl = max(0, min(15, floor((z or 0) + 0.5)))
    for i = 1, 64 do buf[i] = lvl end
  end
  -- what the LED of control `id` shows this frame, as a led key
  local function want(id)
    local c
    if id < EX_PADS then c = EX_CELL[id] else c = EX_BTN_CELL[id] end
    if c then return buf[c] or 0 end
    if id >= EX_DOWN and id <= EX_REDO then return EX_NAV_KEY end
    if id >= EX_ENC and id < EX_PUSH then return EX_ENC_KEY end
    return 0
  end
  -- one SysEx from the first changed LED of lo..hi to the last
  local function push_leds(lo, hi)
    local first, last
    for id = lo, hi do
      if sent[id] ~= want(id) then
        first = first or id
        last = id
      end
    end
    if not first then return end
    local m, n = msg, #EX_LED
    for i = 1, n do m[i] = EX_LED[i] end
    n = n + 1; m[n] = first
    for id = first, last do
      local k = want(id)
      sent[id] = k
      m[n + 1], m[n + 2], m[n + 3] = ex_rgb(k)
      m[n + 4] = 0                         -- no effect
      n = n + 4
    end
    n = n + 1; m[n] = EX_EOX
    for i = #m, n + 1, -1 do m[i] = nil end   -- drop a longer frame's tail
    pcall(send_msg)
  end
  function ex:refresh()
    if self.surface then push_leds(0, EX_PADS - 1) end
    push_leds(EX_LIT_LO, EX_LIT_HI)
  end
  function ex:invalidate()
    for id = 0, EX_LIT_HI do sent[id] = nil end
  end
  -- end every held cell: after a mode change or an unplug its release never comes
  function ex:drop()
    for id, c in pairs(held) do
      held[id] = nil
      if self.key then self.key((c - 1) % 8 + 1, floor((c - 1) / 8) + 1, 0) end
    end
  end
  function ex:set_surface(on)
    on = on and true or false
    if on == self.surface then return end
    self:drop()
    if C.lfo and C.lfo.press_clear then C.lfo.press_clear() end
    self.surface = on
    setup(on and EX_ZONES_PADS or EX_ZONES_KEYS)
    for id = 0, EX_PADS - 1 do sent[id] = nil end
  end
  function ex:shutdown()
    self:drop()
    setup(EX_ZONES_OFF)                    -- leave Developer Mode
  end

  -- a press or a release of a control that is a grid cell. A release goes to
  -- the cell its press took, whatever the mode is by then.
  local function cell_event(id, c, down)
    if down then
      if not c then return end
      held[id] = c
    else
      c = held[id]
      if not c then return end
      held[id] = nil
    end
    if ex.key then ex.key((c - 1) % 8 + 1, floor((c - 1) / 8) + 1, down and 1 or 0) end
  end

  dev.event = function(data)
    -- the Refresh request, whole or in pieces
    if type(data) == "table" then
      for i = 1, #data do
        local b = data[i]
        if b == EX_REFRESH[rpos + 1] then
          rpos = rpos + 1
          if rpos == #EX_REFRESH then rpos = 0; ex:invalidate() end
        else
          rpos = (b == 0xF0) and 1 or 0
        end
      end
    end
    local ok, m = pcall(midi.to_msg, data)
    if not ok or type(m) ~= "table" or m.ch ~= EX_CH then return end
    if m.type == "note_on" or m.type == "note_off" then
      local down = m.type == "note_on" and (m.vel or 0) > 0
      local id = m.note or -1
      -- in KEYS a note on channel 16 is a played note, not a pad
      cell_event(id, ex.surface and EX_CELL[id] or nil, down)
    elseif m.type == "cc" then
      local id, v = m.cc or -1, m.val or 0
      if id >= EX_ENC and id < EX_PUSH then
        local n = id - EX_ENC + 1
        local a, div = acc[n] + (v - EX_ENC_MID), EX_ENC_DIV[n]
        local steps = a >= 0 and floor(a / div) or -floor(-a / div)
        acc[n] = a - steps * div
        if steps ~= 0 and ex.turn then ex.turn(n, steps) end
      elseif id >= EX_PUSH and id < EX_PUSH + #EX_ENC_DIV then
        if ex.push then ex.push(id - EX_PUSH + 1, v > 0 and 1 or 0) end
      elseif EX_BTN_CELL[id] then
        cell_event(id, EX_BTN_CELL[id], v > 0)
      elseif v > 0 and id >= EX_DOWN and id <= EX_REDO and ex.nav then
        ex.nav(id)
      end
    end
  end
  return ex
end

-- encoders 1 to 3 are the norns's own (the script's global enc and key);
-- encoder 4 picks the track, as K1+E1 does
local function ex_turn(n, d)
  if n <= 3 then
    if enc then enc(n, d) end
    return
  end
  C.touch_input()
  params:delta("track_sel", d)
  C.page_flash = C.frame + floor(FPS * 0.7)
end

local function ex_push(n, z)
  if n <= 3 then
    if key then key(n, z) end
    return
  end
  local ex = M.ex
  if z ~= 1 or not ex then return end
  C.touch_input()
  ex:set_surface(not ex.surface)
  if ex.surface then
    C.take_say("EXQUIS PADS", "Exquis: the pads are the grid surface")
  else
    C.take_say("EXQUIS KEYS", "Exquis: the pads are its own keyboard")
  end
end

local function ex_nav(id)
  C.touch_input()
  if id == EX_UNDO then C.step_page(-1)
  elseif id == EX_REDO then C.step_page(1)
  elseif id == EX_UP then params:delta("scene_slot", 1)
  elseif id == EX_DOWN then params:delta("scene_slot", -1) end
end

-- the Exquis has left (or four is closing): end what its pads hold
local function ex_release(leave_dev_mode)
  local ex = M.ex
  if not ex then return end
  if leave_dev_mode then ex:shutdown() else ex:drop() end
  -- a key pressed in KEYS will never send its release
  if C.lfo and C.lfo.press_clear then C.lfo.press_clear() end
  ex.key, ex.turn, ex.push, ex.nav = nil, nil, nil, nil
  ex.device.event = nil
  M.ex = nil
end

-- adopt an attached Exquis. Safe to call again: the one in use is kept.
local function ex_connect()
  local dev = ex_find_device()
  if M.ex and M.ex.device == dev then return end
  ex_release(false)
  if not dev then return end
  local ok, cand = pcall(ex_make, dev, not (gg and gg.device))
  if ok and cand then
    cand.key, cand.turn, cand.push, cand.nav = grid_key, ex_turn, ex_push, ex_nav
    M.ex = cand
    print("four: Exquis in Developer Mode, " .. (cand.surface and "PADS" or "KEYS")
      .. " (" .. tostring(dev.name) .. ")")
  else
    print("four: Exquis found but its driver failed; it stays a MIDI keyboard")
  end
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

local pad_on = {}   -- reused: which of the 8 pads are sounding this frame

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
  -- row 2: the state strip. RED = recording, GREEN = playing, ICE BLUE = frozen,
  -- PURPLE = reverse, BLUE = DRY; STOP PULSES red so it reads apart from a
  -- steady recording-red. writes carry the fast blink (matching the header).
  local wblink = (C.frame % 4) < 2
  strip_led(1, pget("rec", 0) == 1, "red", wblink and 15 or 5)
  strip_led(2, pget("tape_rec", 0) == 1, "red", wblink and 15 or 5)
  strip_led(3, pget("tape_reverse", 0) == 1, "purple")
  strip_led(4, pget("pv_freeze", 0) == 1, "ice")
  strip_led(5, pget("tape_freeze", 0) == 1, "ice")
  strip_led(6, pget("pad_input", 0) == 1, "yellow")      -- notes routed to pads
  gg:led(7, 2, 7, "blue")                                -- DRY: an action
  local stopped = pget("stop_all", 0) == 1
  gg:led(8, 2, stopped and (5 + floor(9 * tri(C.frame, 22))) or 2,
    stopped and "red" or nil)                            -- STOP: pulsing red
  -- rows 7-8: one piano octave; the block dims when note input is off so
  -- it's visible why pads are dead. What lights is what the keys DO: the
  -- drone's current pitch in WHITE, or in pad mode every key whose pad
  -- (semitone mod 8) is sounding, in the slice ORANGE
  local en = pget("keys_enable", 1) == 1
  local oct = pget("kb_octave", 0)
  local padmode = pget("pad_input", 0) == 1
  local st_cur = util.round(12 * log(pget("pitch", 1), 2))
  if padmode then
    for k = 0, 7 do pad_on[k] = false end
    for _, i in pairs(C.pad_held) do pad_on[i] = true end
  end
  for x = 1, 8 do
    local w = GRID_WHITE[x] + 12 * oct
    if not en then gg:led(x, 8, 1)
    elseif padmode and pad_on[w % 8] then gg:led(x, 8, 15, "orange")
    elseif not padmode and w == st_cur then gg:led(x, 8, 15, "white")
    elseif x == 1 or x == 8 then gg:led(x, 8, 6)
    else gg:led(x, 8, 4) end
    if GRID_BLACK[x] then
      local b = GRID_BLACK[x] + 12 * oct
      if not en then gg:led(x, 7, 1)
      elseif padmode and pad_on[b % 8] then gg:led(x, 7, 15, "orange")
      elseif not padmode and b == st_cur then gg:led(x, 7, 15, "white")
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
  -- so a playhead wins a shared pad), full only while that deck is AUDIBLE:
  -- the screen's rule, so a stopped or thrown-away deck cannot look playing
  if pget("rec", 0) == 1 and pget("freeze", 0) == 0 then
    gg:led(floor(clamp(C.rec_phase, 0, 0.999) * 8) + 1, 3, 15, "red")
  end
  local eg, tg = C.mix_gains()
  local eng_on = pget("mode", 5) > 1 and eg > 0.001 and C.wave_any
  local tape_on = C.twave_any and tg > 0.001
  gg:led(floor(clamp(C.play_phase, 0, 0.999) * 8) + 1, 3, eng_on and 15 or 4, "white")
  gg:led(floor(clamp(C.tape_phase, 0, 0.999) * 8) + 1, 4, tape_on and 15 or 4, "white")
  -- row 5: mode radio (selected YELLOW) + pitch utilities
  local mode = pget("mode", 5)
  for x = 1, 6 do gg:led(x, 5, x == mode and 15 or 3, x == mode and "yellow" or nil) end
  local en = pget("keys_enable", 1) == 1
  local quant = en and pget("pitch_quant", 0) == 1
  gg:led(7, 5, en and 3 or 1)
  gg:led(8, 5, quant and 15 or (en and 3 or 1), quant and "yellow" or nil)
  -- row 6: the beat repeat. The held division CYAN (a hold), the division
  -- set but not held a dim cyan, the rest barely there
  local on = pget("beat_repeat", 0) == 1
  local div = floor(pget("repeat_div", 3) + 0.5)
  for x = 1, 5 do
    if on and x == div then gg:led(x, 6, 15, "cyan")
    elseif x == div then gg:led(x, 6, 5, "cyan")
    else gg:led(x, 6, 2) end
  end
  -- x6 / x7 step the visuals look (violet, the brighter one lit while AUTO is off),
  -- x8 is a held FLASH on the picture. Brightness follows the look's place in the list.
  local look = floor(pget("vis_look", 1) + 0.5)
  local lv = 3 + floor(9 * (look - 1) / math.max(1, #Mosc_LOOKS - 1))
  gg:led(6, 6, look == 1 and 3 or lv, "purple")
  gg:led(7, 6, look == 1 and 3 or lv, "purple")
  gg:led(8, 6, pget("vis_flash", 0) == 1 and 15 or 4, "white")
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
  gg:led(3, 6, pget("step_run", 0) == 1 and 12 or 4, "green")           -- sequencer run
  gg:led(5, 6, 3)                                                       -- fewer hits
  gg:led(6, 6, 3)                                                       -- more hits
  gg:led(8, 6, pget("pad_input", 0) == 1 and 15 or 5, "yellow")          -- route
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
  -- the orbit: yellow = mode, blinking while the wander runs
  local orb = pget("orbit_on", 0) == 1
  gg:led(6, 6, orb and ((C.frame % 8) < 5 and 15 or 6) or 3, "yellow")
  gg:led(8, 6, sc.safe and 10 or 2, sc.safe and "white" or nil)
end

-- draw surface `s` to the target that `gg` names
local function paint(s)
  gg:all(0)
  draw_spine()
  if s == "pads" then draw_pads_ws()
  elseif s == "scene" then draw_scene_ws()
  else draw_main_ws() end
  gg:refresh()
end

function M.redraw()
  -- a hot-plug asked for a fresh connect (see M.hotplug)
  if M.reconnect_due then
    M.reconnect_due = false
    M.connect()
  end
  if M.ex_due then
    M.ex_due = false
    ex_connect()
  end
  local ex = M.ex
  if not ((gg and gg.device) or ex) then return end
  local s = surface()
  -- CAP/CLR are SCENE-workspace modifiers (row 6). If we've navigated off the
  -- SCENE page they must not linger held — otherwise a page-independent
  -- scene-bank (row 1) tap silently captures/clears instead of recalling.
  if s ~= "scene" then scene_mod.cap, scene_mod.clr = false, false end
  if gg and gg.device then paint(s) end
  -- the Exquis is a second draw target for the same surface. In KEYS its pads
  -- are its own, and the buttons still show the state strip.
  if ex then
    local keep = gg
    gg = ex
    paint(s)
    gg = keep
  end
end

function M.connect()
  gg = nil
  M.have_launchpad = false
  -- prefer a native Launchpad Mini MK3 colour driver over midigrid/native when
  -- no monome grid is attached; on ANY failure fall back — can't brick.
  if no_monome then
    local lp = lp_find_device()
    if lp then
      local ok, cand = pcall(function() return lp_make_backend(lp).connect() end)
      if ok and cand then
        gg = cand
        M.have_launchpad = true
        print("four: Launchpad Mini MK3 colour driver — " .. tostring(lp.name))
      else
        print("four: Mini MK3 found but colour driver failed; using fallback")
      end
    end
  end
  if not gg then gg = grid_mod.connect() end   -- midigrid or native grid
  M.gg = gg
  if gg then
    gg.key = grid_key
    gg.button = lp_button
  end
  ex_connect()
end

-- a MIDI device came or went. A Mini MK3 plugged in after the script loaded
-- takes over from the fallback grid; unplugged, the fallback comes back. A
-- fresh connect also starts a fresh LED diff, so the pads all repaint.
-- `gone`: the device being removed (midi.remove passes it), still listed.
-- The connect itself waits for the next grid frame: norns deletes a leaving
-- device only after midi.remove returns, and midigrid's own search, which
-- cannot be told to skip it, would bind to the Launchpad that is leaving.
-- A leaving Launchpad is dropped at once, so nothing draws to it meanwhile.
function M.hotplug(gone)
  -- the Exquis, with or without a grid. One that left is dropped at once; one
  -- that came is adopted on the next grid frame.
  local exd = ex_find_device(gone)
  if M.ex and M.ex.device ~= exd then ex_release(false) end
  if exd and not M.ex then M.ex_due = true end
  if not no_monome then return end
  local lp = lp_find_device(gone)
  local on_lp = M.have_launchpad and gg and gg.device
  if (lp and on_lp ~= lp) or (not lp and on_lp) then
    if on_lp then
      gg.key, gg.button = nil, nil
      gg, M.gg, M.have_launchpad = nil, nil, false
      -- a repeat pad held on the grid that left will never come up
      M.repeat_drop()
    end
    M.reconnect_due = true
  end
end

function M.cleanup()
  ex_release(true)                               -- Exquis: leave Developer Mode
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
