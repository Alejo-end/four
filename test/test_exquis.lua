-- test_exquis.lua: the Exquis Developer Mode driver, offline.
--
-- The driver has never run on an Exquis. What this harness holds is what the
-- maker's "Developer Mode MIDI specification" (2025-03-10) says and what the
-- instrument promises: the fold of the 8x8 surface onto 61 hexagons, the SysEx
-- frames (a wrong one is ignored by the hardware, in silence), the two modes,
-- and that a pad's release always closes what its press began.
--
--   lua test/test_exquis.lua        # from the repo root

local T = dofile("test/harness.lua")
local ok = T.ok

-- ---- the fold: pad id -> grid cell ----------------------------------------
local src = io.open("lib/mgrid.lua"):read("a")
local function lift(pat, name)
  local chunk = src:match(pat)
  assert(chunk, "could not lift " .. name .. " out of lib/mgrid.lua")
  return chunk
end
local cell = load("local floor = math.floor\n"
  .. lift("(local EX_ROW_Y = %b{})", "EX_ROW_Y") .. "\n"
  .. lift("(local function ex_cell.-\nend)", "ex_cell") .. "\nreturn ex_cell")()

local function at(id) local x, y = cell(id); return x and (x .. "," .. y) or "none" end
ok(at(0) == "1,2" and at(5) == "6,2", "the bottom row is the state strip, cells 1 to 6")
ok(at(55) == "1,1" and at(50) == "2,1", "the top two rows zigzag from the left: scene 1, scene 2")
ok(at(58) == "7,1" and at(53) == "8,1", "...to scene 7 and scene 8")
ok(at(59) == "none" and at(60) == "none" and at(54) == "none",
  "the three pads at the right end of a pair are spare")
ok(at(11) == "1,6" and at(6) == "2,6", "the pair above the strip is grid row 6")
ok(at(44) == "1,3" and at(39) == "2,3", "the pair under the scenes is grid row 3")
ok(at(-1) == "none" and at(61) == "none", "ids off the pads are rejected")
do
  local seen, dup, n = {}, false, 0
  for id = 0, 60 do
    local x, y = cell(id)
    if x then
      local k = y * 8 + x
      if seen[k] then dup = true end
      seen[k] = true
      n = n + 1
    end
  end
  local whole = true
  for _, y in ipairs({ 1, 3, 4, 5, 6 }) do
    for x = 1, 8 do if not seen[y * 8 + x] then whole = false end end
  end
  ok(not dup, "no two pads share a grid cell")
  ok(whole, "every cell of the scenes and the workspace has a pad")
  ok(n == 46, "46 pads carry the surface (got " .. n .. ")")
end

-- ---- the driver in the real script ----------------------------------------
local env = dofile("test/uisim/env.lua")
-- this harness plugs its own Exquis in: FOUR_EXQUIS does not reach it
local _h = env.install{ dir = "/tmp", scenario = function() end, exquis = false }
include = function(p) return dofile(p .. ".lua") end
math.randomseed(1)
dofile("four.lua")
init()
local CTX
for i = 1, 255 do
  local n, v = debug.getupvalue(key, i)
  if n == nil then break end
  if n == "ctx" then CTX = v end
end
assert(CTX, "could not reach the script's ctx")
local G = CTX.grid

-- the stand-in of test/uisim/env.lua: it speaks bytes, as a port does, and
-- midi.to_msg is norns's own parse. It checks every frame it is sent.
local X = _h.new_exquis()
local exq = X.device
local sent = X.sent
local hex, pad, cc, led = X.hex, X.pad, X.cc, X.led
-- the stand-in's own fold must be the driver's: the mirror depends on it
do
  local same = true
  for id = 0, 60 do
    local x, y = cell(id)
    if (x and (y - 1) * 8 + x or nil) ~= X.cell_of[id] then same = false end
  end
  ok(same, "the stand-in folds the pads as the driver does")
end

-- plug it in: adopted on the next grid frame
X.plug()
ok(G.ex == nil, "a plugged-in Exquis waits for the next grid frame")
G.redraw()
ok(G.ex ~= nil and G.ex.device == exq, "...and is adopted there")
ok(G.gg == _h.grid, "the grid stays the grid: the Exquis lives beside it")
ok(G.ex.surface == false, "with a grid attached it starts in KEYS")
ok(hex(sent[1]) == "F0 00 21 7E 7F 00 2A F7",
  "KEYS takes the encoders and the buttons, not the pads (" .. hex(sent[1]) .. ")")
do
  local pads_lit = false
  for _, m in ipairs(sent) do
    if m[6] == 0x04 and m[7] <= 60 then pads_lit = true end
  end
  ok(not pads_lit, "in KEYS no pad LED is written: the pads are the Exquis's own")
  local r, g, b = led(106)
  ok(r and r > 0, "...and the buttons are lit")
end

-- KEYS: a pad is not a grid key, and its notes pass to the note input
params:set("rec", 0)
pad(0, true); pad(0, false)
ok(params:get("rec") == 0, "in KEYS a note on channel 16 is not a pad press")
do
  params:set("keys_enable", 1); params:set("pad_input", 0); params:set("pitch", 1)
  X.play({ 0x91, 72, 90 })
  ok(math.abs(params:get("pitch") - 2) < 0.01, "in KEYS the Exquis plays four: a C above the root is pitch 2")
  X.play({ 0x81, 72, 0 })
  params:set("pitch", 1)
end

-- KEYS: pressure is a modulation source (the PRESS shape of a modulator)
do
  local got
  local real_cutoff = engine.cutoff
  engine.cutoff = function(v) got = v end
  params:set("cutoff", 1000)
  params:set("lfo1_target", 2)                -- cutoff
  params:set("lfo1_shape", 7)                 -- PRESS
  params:set("lfo1_depth", 0.5)
  ok(params:string("lfo1_shape") == "PRESS", "the seventh modulator shape is PRESS")
  _h.run_ticks(3)
  local rest = got
  ok(rest and math.abs(rest - 1000) < 1, "with no key pressed, PRESS leaves the knob where it is")
  X.play({ 0x91, 60, 90 })
  X.play({ 0xD1, 127 })
  X.play({ 0xD2, 40 })
  _h.run_ticks(12)
  local full = got
  ok(full > rest * 4, "a pressed key opens the filter (" .. tostring(full) .. " Hz)")
  ok(math.abs(CTX.lfo.press - 1) < 0.01, "...and the hardest of two keys counts")
  ok(params:get("cutoff") == 1000, "...and the knob itself does not move")
  X.play({ 0xD1, 0 })
  _h.run_ticks(12)
  ok(got < full and got > rest * 1.2, "with that key eased, the lighter key holds it part open")
  X.play({ 0xD2, 127 })
  X.play({ 0x82, 64, 0 })
  _h.run_ticks(20)
  ok(math.abs(got - 1000) < 1, "a key that comes up presses no more, with no last zero sent")
  -- key pressure, from a keyboard that is not MPE
  X.play({ 0xA0, 62, 127 })
  _h.run_ticks(12)
  ok(got > rest * 4, "key pressure (poly aftertouch) counts too")
  -- pressed, and the mode changes: the release will never come
  cc(117, 127); cc(117, 0)
  _h.run_ticks(20)
  ok(math.abs(got - 1000) < 1, "a change to PADS lets go of the pressure")
  cc(117, 127); cc(117, 0)                    -- back to KEYS
  X.play({ 0x81, 60, 0 })
  params:set("lfo1_depth", 0); params:set("lfo1_shape", 1); params:set("lfo1_target", 1)
  _h.run_ticks(2)
  engine.cutoff = real_cutoff
  params:set("pitch", 1)
end

-- the push of encoder 4: PADS
local n0 = #sent
cc(117, 127); cc(117, 0)
ok(G.ex.surface == true, "the push of encoder 4 changes to PADS")
ok(hex(sent[n0 + 1]) == "F0 00 21 7E 7F 00 2B F7", "...and takes the pads over")
G.redraw()
do
  local m
  for i = n0 + 2, #sent do if sent[i][6] == 0x04 and sent[i][7] == 0 then m = sent[i] end end
  ok(m and #m == 7 + 61 * 4 + 1 and m[#m] == 0xF7,
    "the first PADS frame paints all 61 pads in one SysEx")
  local over = false
  for i = 8, #m - 1 do if m[i] > 127 then over = true end end
  ok(not over, "...with every data byte in 0 to 127")
end
do
  params:set("pitch", 1)
  X.play({ 0x9F, 44, 127 })
  ok(params:get("pitch") == 1, "in PADS the Exquis's notes do not reach the note input")
end

-- pads and buttons are grid cells
params:set("rec", 0)
pad(0, true); pad(0, false)
ok(params:get("rec") == 1, "the first pad of the bottom row is rec")
G.redraw()
do
  local r, g, b = led(0)
  ok(r and r > g and r > b, "...and it lights red")
  local r2, g2, b2 = led(102)
  ok(r2 == r and g2 == g and b2 == b, "the Record button shows the same cell")
end
cc(102, 127); cc(102, 0)
ok(params:get("rec") == 0, "the Record button is rec too")
params:set("stop_all", 0)
cc(105, 127); cc(105, 0)
ok(params:get("stop_all") == 1, "Play/Stop is STOP")
params:set("stop_all", 0)
params:set("scene_slot", 1)
pad(50, true); pad(50, false)
ok(math.floor(params:get("scene_slot") + 0.5) == 2, "the second pad of the top zigzag is scene 2")
params:set("scene_slot", 1)
T.goto_page("TAKE")
params:set("mode", 1)
pad(18, true); pad(18, false)       -- rows 4+3 are grid row 5: cell 4 is PV
ok(params:get("mode") == 4, "the mode radio is on the fourth pair (got " .. params:get("mode") .. ")")

-- the buttons and the encoders
local p0 = CTX.page
cc(109, 127); cc(109, 0)
ok(CTX.page == p0 + 1, "Redo steps to the next page")
cc(108, 127); cc(108, 0)
ok(CTX.page == p0, "...and Undo back")
params:set("scene_slot", 3)
cc(107, 127); cc(107, 0)
ok(math.floor(params:get("scene_slot") + 0.5) == 4, "Up steps the scene slot")
cc(106, 127)
ok(math.floor(params:get("scene_slot") + 0.5) == 3, "...and Down back")
params:set("scene_slot", 1)
cc(110, 65); cc(110, 65)
ok(CTX.page == p0, "encoder 1 needs three ticks for a page")
cc(110, 65)
ok(CTX.page == p0 + 1, "...and the third one steps it, as E1 does")
cc(110, 61)
ok(CTX.page == p0, "a turn of three ticks back steps back")
do
  local calls = {}
  local real_enc, real_key = enc, key
  enc = function(n, d) calls[#calls + 1] = "e" .. n .. ":" .. d end
  key = function(n, z) calls[#calls + 1] = "k" .. n .. ":" .. z end
  cc(111, 66); cc(112, 63); cc(115, 127); cc(115, 0); cc(116, 127)
  enc, key = real_enc, real_key
  ok(table.concat(calls, " ") == "e2:2 e3:-1 k2:1 k2:0 k3:1",
    "encoders 2 and 3 are E2 and E3, their pushes K2 and K3 (" .. table.concat(calls, " ") .. ")")
  key(3, 0)
end
params:set("track_sel", 1)
cc(113, 67)
ok(params:get("track_sel") == 2, "encoder 4 picks the track")
params:set("track_sel", 1)

-- the Exquis asks for a repaint (its settings menu closed)
G.redraw()
local n1 = #sent
G.redraw()
X.raw({ 0xF0, 0x00, 0x21 })               -- in pieces, as a port may deliver it
X.raw({ 0x7E, 0x7F, 0x03 })
X.raw({ 0x02, 0xF7 })
local n2 = #sent
G.redraw()
do
  local full = false
  for i = n2 + 1, #sent do
    if sent[i][6] == 0x04 and sent[i][7] == 0 and #sent[i] == 7 + 61 * 4 + 1 then full = true end
  end
  ok(full, "a Refresh from the Exquis repaints every pad")
end

-- a held pad and a mode change: the release never comes, so the driver ends it
params:set("beat_repeat", 0)
T.goto_page("TAKE")
pad(11, true)                       -- grid row 6, cell 1: the beat repeat, held
ok(params:get("beat_repeat") == 1, "a held pad of the lowest pair holds the beat repeat")
cc(117, 127); cc(117, 0)            -- to KEYS under the finger
ok(G.ex.surface == false and params:get("beat_repeat") == 0,
  "a change to KEYS ends what the pads held")
pad(11, false)
ok(params:get("beat_repeat") == 0, "...and the late release does nothing")
cc(117, 127); cc(117, 0)            -- back to PADS

-- unplugged under a held pad
pad(11, true)
ok(params:get("beat_repeat") == 1, "held again")
local n3 = #sent
X.unplug()
ok(G.ex == nil and params:get("beat_repeat") == 0,
  "unplugged, the Exquis is dropped at once and its held pad is released")
ok(exq.event == nil, "...and its event handler is gone")
G.redraw()
ok(#sent == n3, "...and nothing is sent to it after it left")

-- cleanup leaves Developer Mode
X.plug()
G.redraw()
ok(G.ex ~= nil, "plugged in again, it is adopted again")
G.cleanup()
ok(hex(sent[#sent]) == "F0 00 21 7E 7F 00 00 F7", "cleanup leaves Developer Mode")
ok(G.ex == nil and exq.event == nil, "...and lets the device go")
ok(X.mode() == "off", "...which the Exquis reads as its own mode again")

-- alone, with no grid: the pads are the only surface, so it starts in PADS
do
  local dev = _h.grid.device
  _h.grid.device = nil
  local n4 = #sent
  X.plug()
  G.redraw()
  ok(G.ex ~= nil and G.ex.surface == true, "with no grid attached it starts in PADS")
  ok(hex(sent[n4 + 1]) == "F0 00 21 7E 7F 00 2B F7", "...and takes the pads over at once")
  G.redraw()
  local r = led(55)
  ok(r ~= nil, "...and the pads are painted with no grid to paint")
  params:set("rec", 0)
  pad(0, true); pad(0, false)
  ok(params:get("rec") == 1, "...and they play: the first pad of the bottom row is rec")
  params:set("rec", 0)
  -- a running status or a stray byte must not throw in the handler
  local fine = pcall(function()
    X.raw({}); X.raw({ 0xF8 }); X.raw({ 0x9F }); X.raw({ 0xBF, 110 }); X.raw({ 0xF0, 0xF7 })
  end)
  ok(fine, "short and stray messages do not throw in the handler")
  G.cleanup()
  X.unplug()
  _h.grid.device = dev
end

-- ---- the device tools' own Lua --------------------------------------------
-- test/device/norns.py sends these to the norns's REPL (gate.py stage 20,
-- exquis.py). Lifted out of that file and run here, in the offscreen script,
-- as the REPL would: one line, `__ctx` a global.
do
  local py = io.open("test/device/norns.py"):read("a")
  local block = py:match("EXQUIS_LUA = (%b{})")
  assert(block, "could not find EXQUIS_LUA in test/device/norns.py")
  local LUA, count = {}, 0
  for name, code in block:gmatch('"([%w_]+)": """(.-)"""') do
    LUA[name] = code:gsub("\n", " ")
    count = count + 1
  end
  ok(count == 8, "norns.py holds eight Exquis snippets (got " .. count .. ")")
  __ctx = CTX
  local real_print = print
  local function repl(code)
    local out
    print = function(v) out = tostring(v) end
    local fn, err = load(code)
    local okr, e2 = pcall(fn or error, err)
    print = real_print
    assert(fn and okr, "a device snippet does not run: " .. tostring(err or e2))
    return out
  end
  for name, code in pairs(LUA) do
    ok(not code:find("%-%-"), "the snippet `" .. name .. "` holds no comment (a REPL line is one line)")
  end

  ok(repl(LUA.status) == "|nil|none|true", "status with no Exquis: no name, no mode, a grid ("
    .. tostring(repl(LUA.status)) .. ")")
  ok(repl("local BYTES = {{0xBF, 109, 127}} " .. LUA.bytes) == "0", "bytes with no Exquis deliver nothing")
  X.plug()
  G.redraw()
  ok(repl(LUA.status) == "Exquis MIDI 1|Exquis MIDI 1|KEYS|true", "status with one: its name, KEYS, a grid")
  T.goto_page("TAKE")
  local p1 = CTX.page
  ok(repl("local BYTES = {{191, 109, 127}, {191, 109, 0}} " .. LUA.bytes) == "2" and CTX.page == p1 + 1,
    "bytes reach the driver: Redo steps the page")
  T.goto_page("TAKE")

  ok(repl("local WANT = true " .. LUA.surface) == "PADS" and G.ex.surface == true, "surface sets PADS")
  G.redraw()
  -- the tap: every message is logged, and the driver still gets it
  ok(repl(LUA.tap_on) == "true", "the tap goes in")
  ok(repl(LUA.tap_on) == "true" and repl(LUA.tap_read) == "", "...once, and starts empty")
  params:set("scene_slot", 1)
  pad(50, true); pad(50, false); cc(110, 65)
  ok(math.floor(params:get("scene_slot") + 0.5) == 2, "under the tap the driver still plays")
  ok(repl(LUA.tap_read) == "9F 32 7F;8F 32 00;BF 6E 41", "the tap reads what was sent, as hex")
  ok(repl(LUA.tap_read) == "", "...and a read empties it")
  ok(repl(LUA.tap_off) == "off", "the tap comes out")
  params:set("scene_slot", 1)
  pad(50, true); pad(50, false)
  ok(math.floor(params:get("scene_slot") + 0.5) == 2, "...and the driver's handler is back")
  params:set("scene_slot", 1)
  cc(110, 63)
  -- a tap left in when the Exquis goes: nothing of it stays on the device
  repl(LUA.tap_on)
  X.unplug()
  ok(exq.event == nil, "an Exquis unplugged under the tap is let go whole")
  ok(repl(LUA.tap_off) == "off" and exq.event == nil, "...and the tap's end does not put a handler back")
  X.plug()
  G.redraw()
  repl("local WANT = true " .. LUA.surface)
  G.redraw()

  -- the sweep: one pad white, the last one dark, then the driver's own picture
  local n5 = #sent
  ok(repl("local ID = 0 " .. LUA.sweep) == "true" and repl("local ID = 1 " .. LUA.sweep) == "true",
    "the sweep runs")
  ok(#sent == n5 + 2, "...one frame a pad")
  do
    local r0 = led(0)
    local r1, g1, b1 = led(1)
    ok(r0 == 0 and r1 == 127 and g1 == 127 and b1 == 127, "...the pad before goes dark, this one white")
  end
  ok(repl(LUA.repaint) == "true", "repaint asks the driver for every LED")
  local n6 = #sent
  G.redraw()
  ok(#sent > n6 and #sent[n6 + 1] == 7 + 61 * 4 + 1, "...and the next frame paints all 61 pads")
  ok(repl("local WANT = false " .. LUA.surface) == "KEYS", "surface sets KEYS again")
  G.cleanup()
  X.unplug()
  __ctx = nil
end

T.report("exquis harness OK")
