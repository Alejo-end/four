-- mangler
-- live stereo sample-mangling instrument for external gear
-- (synth, drum machine, anything line-level)
--
-- 3 keys + 3 encoders. every parameter is MIDI-mappable (PARAMS menu).
--
-- E1 : page select
-- E2 : primary param   (hold K1 -> alt param)
-- E3 : secondary param (hold K1 -> alt param)
-- K1 : alt / shift modifier (hold)
-- K2 : primary action
-- K3 : secondary action
--
-- STAGE 0 — loadable skeleton. Only the MIX page is wired; later pages are
-- placeholders brought up one stage at a time on hardware. See SPEC/spec.md.

engine.name = "Mangler"

local sc = require "softcut"  -- reserved for STAGE 3 (tape); unused at S0

-- ============================================================================
-- state
-- ============================================================================

local PAGES = {
  "MIX", "REC", "WINDOW", "GRAIN", "STRETCH", "TAPE", "FILTER", "DELAY", "REVERB",
}
local page = 1
local alt = false          -- K1 held
local held = {}            -- held[n] = true while key n is down (global, page-independent)

-- which params each page's encoders address: { e2, e2_alt, e3, e3_alt }.
-- nil entries draw as "--" until the owning stage wires them.
local ENC_MAP = {
  MIX     = { "mix", "out_level", "sc_level", "tape_level" },
  REC     = { nil, nil, nil, nil },
  WINDOW  = { nil, nil, nil, nil },
  GRAIN   = { nil, nil, nil, nil },
  STRETCH = { nil, nil, nil, nil },
  TAPE    = { nil, nil, nil, nil },
  FILTER  = { nil, nil, nil, nil },
  DELAY   = { nil, nil, nil, nil },
  REVERB  = { nil, nil, nil, nil },
}

local screen_dirty = true
local redraw_clock

-- ============================================================================
-- helpers
-- ============================================================================

local function clamp(x, lo, hi)
  if x < lo then return lo elseif x > hi then return hi else return x end
end

-- the param id addressed by encoder n (2 or 3) on the current page, alt-aware.
local function enc_param(n)
  local m = ENC_MAP[PAGES[page]]
  if not m then return nil end
  if n == 2 then return alt and m[2] or m[1]
  elseif n == 3 then return alt and m[4] or m[3] end
  return nil
end

-- ============================================================================
-- params  (single source of truth: keys, encoders, and MIDI all drive these)
-- ============================================================================

local function init_params()
  params:add_separator("mangler")

  params:add_group("mix", 4)
  params:add_control("mix", "mix (sc <> tape)",
    controlspec.new(0, 1, "lin", 0, 0.5, ""))
  params:add_control("out_level", "out level",
    controlspec.new(0, 1.5, "lin", 0, 1.0, ""))
  params:add_control("sc_level", "sc level",
    controlspec.new(0, 1, "lin", 0, 1.0, ""))
  params:add_control("tape_level", "tape level",
    controlspec.new(0, 1, "lin", 0, 1.0, ""))

  -- later stages add their own groups (rec / window / grain / stretch /
  -- tape / filter / delay / reverb) here, each value a real param so it is
  -- MIDI-mappable via PMAP.

  params:bang()
end

-- ============================================================================
-- gestures
-- ============================================================================
-- a momentary hold writes held[n] in key(); when the key is released we close
-- the gesture here, page-independently, so a release on a different page still
-- ends what was started. STAGE 0 has no gestures yet.

local function gesture_release(n)
  -- no-op at S0; later stages close held actions (stutter, reverse, ...) here.
end

-- ============================================================================
-- norns callbacks
-- ============================================================================

function init()
  init_params()

  redraw_clock = clock.run(function()
    while true do
      clock.sleep(1 / 30)
      if screen_dirty then
        redraw()
        screen_dirty = false
      end
    end
  end)
end

function cleanup()
  if redraw_clock then clock.cancel(redraw_clock) end
end

function enc(n, d)
  if n == 1 then
    page = clamp(page + d, 1, #PAGES)
    screen_dirty = true
    return
  end
  local id = enc_param(n)
  if id then params:delta(id, d) end
  screen_dirty = true
end

function key(n, z)
  if n == 1 then
    alt = (z == 1)
    screen_dirty = true
    return
  end
  held[n] = (z == 1)
  if z == 0 then gesture_release(n) end
  -- STAGE 0: actions (K2/K3) are wired per page by later stages; they will
  -- drive params:set/delta so MIDI and keys stay in lockstep.
  screen_dirty = true
end

-- ============================================================================
-- screen
-- ============================================================================

local function enc_cell(x, n)
  local id = enc_param(n)
  screen.move(x, 30)
  if id then
    screen.level(15)
    screen.text(params:get_name(id))
    screen.move(x, 42)
    screen.level(6)
    screen.text(params:string(id))
  else
    screen.level(3)
    screen.text("--")
  end
end

function redraw()
  screen.clear()

  -- top strip: page name + alt indicator
  screen.level(15)
  screen.move(0, 8)
  screen.text(PAGES[page])
  if alt then
    screen.level(15)
    screen.move(128, 8)
    screen.text_right("ALT")
  end
  screen.level(2)
  screen.move(0, 11)
  screen.line(128, 11)
  screen.stroke()

  -- body: the two encoder cells for this page
  enc_cell(0, 2)
  enc_cell(66, 3)

  -- footer: page position
  screen.level(3)
  screen.move(128, 62)
  screen.text_right(page .. "/" .. #PAGES)

  screen.update()
end
