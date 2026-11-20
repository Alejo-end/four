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

-- ---- THE SPECIFICATION, PINNED ---------------------------------------------
-- The one place where the numbers of the maker's specification and of four's
-- layout are written out. The driver names each of them once and hands them
-- out as M.EX (lib/mgrid.lua); the stand-in, the rest of this harness and the
-- device tools read that table. A number that leaves the specification in the
-- driver fails HERE, and nowhere else is there a second copy to forget.
local env = dofile("test/uisim/env.lua")
local P = env.exquis_proto()
local function bytes(t)
  local out = {}
  for i = 1, #t do out[i] = string.format("%02X", t[i]) end
  return table.concat(out, " ")
end
ok(P.name == "exquis", "the driver looks for `exquis` in a device's name")
ok(P.ch == 16, "a zone taken over speaks on channel 16")
ok(P.pads == 61, "61 pads")
ok(bytes(P.setup) == "F0 00 21 7E 7F 00", "the setup frame's head and kind")
ok(bytes(P.led) == "F0 00 21 7E 7F 04", "the LED frame's head and kind")
ok(bytes(P.refresh) == "F0 00 21 7E 7F 03", "the Refresh request's head and kind")
ok(P.eox == 0xF7, "a frame ends as every SysEx does")
ok(P.zones.pads == 0x2B and P.zones.keys == 0x2A and P.zones.off == 0x00,
  "the zone masks: pads 01, encoders 02, Up/Down 08, the other buttons 20")
ok(P.rec == 102 and P.loop == 103 and P.clips == 104 and P.play == 105,
  "Record, Loop, Clips, Play/Stop are 102 to 105")
ok(P.down == 106 and P.up == 107 and P.undo == 108 and P.redo == 109,
  "Down, Up, Undo, Redo are 106 to 109")
ok(P.enc == 110 and P.push == 114 and #P.enc_div == 4, "four encoders from 110, their pushes from 114")
ok(P.enc_mid == 64, "an encoder sends 64 plus its ticks")
ok(P.lit_lo == 102 and P.lit_hi == 113, "the lights the driver writes beside the pads: 102 to 113")
ok(table.concat(P.enc_div, " ") == "3 1 1 3", "encoders 1 and 4 need three ticks a step")
do
  local c = P.btn_cell
  ok(c[P.rec] == 9 and c[P.loop] == 10 and c[P.clips] == 15 and c[P.play] == 16,
    "the four strip buttons are cells 1, 2, 7 and 8 of grid row 2")
end

-- the fold: pad id -> grid cell
local cell = P.cell
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
-- ---- from here on, no number of the protocol: P, and pads by their cell ----

-- ---- the driver in the real script ----------------------------------------
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
local hex, pad, led = X.hex, X.pad, X.led
-- a pad by the grid cell it carries, and the cells this harness presses
local PAD = X.pad_at
local REC_PAD, SCENE1, SCENE2 = PAD(1, 2), PAD(1, 1), PAD(2, 1)
local MODE_PV = PAD(4, 5)           -- TAKE's mode radio, the fourth mode
local REPEAT = PAD(1, 6)            -- TAKE's beat repeat, a held pad
local ANY_PAD = PAD(1, 3)
local MODE_PUSH = #P.enc_div        -- the last encoder's push changes the mode
local function slot() return math.floor(params:get("scene_slot") + 0.5) end
local ROOT = params:get("root_note")
local OCTAVE = 12

-- plug it in: adopted on the next grid frame
X.plug()
ok(G.ex == nil, "a plugged-in Exquis waits for the next grid frame")
G.redraw()
ok(G.ex ~= nil and G.ex.device == exq, "...and is adopted there")
ok(G.gg == _h.grid, "the grid stays the grid: the Exquis lives beside it")
ok(G.ex.surface == false, "with a grid attached it starts in KEYS")
ok(hex(sent[1]) == X.setup_hex("keys"),
  "KEYS takes the encoders and the buttons, not the pads (" .. hex(sent[1]) .. ")")
do
  local pads_lit = false
  for id = 0, P.pads - 1 do if led(id) then pads_lit = true end end
  ok(not pads_lit, "in KEYS no pad LED is written: the pads are the Exquis's own")
  local r, g, b = led(P.down)
  ok(r and r > 0, "...and the buttons are lit")
end

-- KEYS: a pad is not a grid key, and its notes pass to the note input
params:set("rec", 0)
pad(REC_PAD, true); pad(REC_PAD, false)
ok(params:get("rec") == 0, "in KEYS a note on channel 16 is not a pad press")
do
  params:set("keys_enable", 1); params:set("pad_input", 0); params:set("pitch", 1)
  X.note(2, ROOT + OCTAVE, 0.7)
  ok(math.abs(params:get("pitch") - 2) < 0.01, "in KEYS the Exquis plays four: an octave above the root is pitch 2")
  X.note_off(2, ROOT + OCTAVE)
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
  X.note(2, ROOT, 0.7)
  X.pressure(2, 1)
  X.pressure(3, 0.3)
  _h.run_ticks(12)
  local full = got
  ok(full > rest * 4, "a pressed key opens the filter (" .. tostring(full) .. " Hz)")
  ok(math.abs(CTX.lfo.press - 1) < 0.01, "...and the hardest of two keys counts")
  ok(params:get("cutoff") == 1000, "...and the knob itself does not move")
  X.pressure(2, 0)
  _h.run_ticks(12)
  ok(got < full and got > rest * 1.2, "with that key eased, the lighter key holds it part open")
  X.pressure(3, 1)
  X.note_off(3, ROOT + 4)
  _h.run_ticks(20)
  ok(math.abs(got - 1000) < 1, "a key that comes up presses no more, with no last zero sent")
  -- key pressure, from a keyboard that is not MPE
  X.key_pressure(1, ROOT + 2, 1)
  _h.run_ticks(12)
  ok(got > rest * 4, "key pressure (poly aftertouch) counts too")
  -- pressed, and the mode changes: the release will never come
  X.push(MODE_PUSH)
  _h.run_ticks(20)
  ok(math.abs(got - 1000) < 1, "a change to PADS lets go of the pressure")
  X.push(MODE_PUSH)                           -- back to KEYS
  X.note_off(2, ROOT)
  params:set("lfo1_depth", 0); params:set("lfo1_shape", 1); params:set("lfo1_target", 1)
  _h.run_ticks(2)
  engine.cutoff = real_cutoff
  params:set("pitch", 1)
end

-- the push of encoder 4: PADS
local n0 = #sent
X.push(MODE_PUSH)
ok(G.ex.surface == true, "the push of encoder 4 changes to PADS")
ok(hex(sent[n0 + 1]) == X.setup_hex("pads"), "...and takes the pads over")
G.redraw()
do
  local m
  for i = n0 + 2, #sent do if X.paints_all(sent[i]) then m = sent[i] end end
  ok(m and m[#m] == P.eox, "the first PADS frame paints every pad in one SysEx")
  local over = false
  for i = 2, #m - 1 do if m[i] > X.MAX then over = true end end
  ok(not over, "...with every data byte a data byte")
end
do
  params:set("pitch", 1)
  pad(ANY_PAD, true); pad(ANY_PAD, false)
  ok(params:get("pitch") == 1, "in PADS the Exquis's notes do not reach the note input")
end

-- pads and buttons are grid cells
params:set("rec", 0)
pad(REC_PAD, true); pad(REC_PAD, false)
ok(params:get("rec") == 1, "the first pad of the bottom row is rec")
G.redraw()
do
  local r, g, b = led(REC_PAD)
  ok(r and r > g and r > b, "...and it lights red")
  local r2, g2, b2 = led(P.rec)
  ok(r2 == r and g2 == g and b2 == b, "the Record button shows the same cell")
end
X.press(P.rec)
ok(params:get("rec") == 0, "the Record button is rec too")
params:set("stop_all", 0)
X.press(P.play)
ok(params:get("stop_all") == 1, "Play/Stop is STOP")
params:set("stop_all", 0)
params:set("scene_slot", 1)
pad(SCENE2, true); pad(SCENE2, false)
ok(slot() == 2, "the second pad of the top zigzag is scene 2")
params:set("scene_slot", 1)
T.goto_page("TAKE")
params:set("mode", 1)
pad(MODE_PV, true); pad(MODE_PV, false)
ok(params:get("mode") == 4, "the mode radio is on the fourth pair (got " .. params:get("mode") .. ")")

-- the buttons and the encoders
local p0 = CTX.page
X.press(P.redo)
ok(CTX.page == p0 + 1, "Redo steps to the next page")
X.press(P.undo)
ok(CTX.page == p0, "...and Undo back")
params:set("scene_slot", 3)
X.press(P.up)
ok(slot() == 4, "Up steps the scene slot")
X.btn(P.down, true)
ok(slot() == 3, "...and Down back")
params:set("scene_slot", 1)
for _ = 1, P.enc_div[1] - 1 do X.turn(1, 1) end
ok(CTX.page == p0, "encoder 1 needs more than one tick for a page")
X.turn(1, 1)
ok(CTX.page == p0 + 1, "...and the last one steps it, as E1 does")
X.turn(1, -P.enc_div[1])
ok(CTX.page == p0, "a turn of as many ticks back steps back")
do
  local calls = {}
  local real_enc, real_key = enc, key
  enc = function(n, d) calls[#calls + 1] = "e" .. n .. ":" .. d end
  key = function(n, z) calls[#calls + 1] = "k" .. n .. ":" .. z end
  X.turn(2, 2); X.turn(3, -1); X.push(2); X.btn(P.push + 2, true)
  enc, key = real_enc, real_key
  ok(table.concat(calls, " ") == "e2:2 e3:-1 k2:1 k2:0 k3:1",
    "encoders 2 and 3 are E2 and E3, their pushes K2 and K3 (" .. table.concat(calls, " ") .. ")")
  key(3, 0)
end
params:set("track_sel", 1)
X.turn(#P.enc_div, P.enc_div[#P.enc_div])
ok(params:get("track_sel") == 2, "encoder 4 picks the track")
params:set("track_sel", 1)

-- the Exquis asks for a repaint (its settings menu closed)
G.redraw()
local n1 = #sent
G.redraw()
do                                        -- in pieces, as a port may deliver it
  local cut = #P.refresh // 2
  X.raw({ table.unpack(P.refresh, 1, cut) })
  X.raw({ table.unpack(P.refresh, cut + 1) })
  X.raw({ 0, P.eox })
end
local n2 = #sent
G.redraw()
do
  local full = false
  for i = n2 + 1, #sent do
    if X.paints_all(sent[i]) then full = true end
  end
  ok(full, "a Refresh from the Exquis repaints every pad")
end

-- a held pad and a mode change: the release never comes, so the driver ends it
params:set("beat_repeat", 0)
T.goto_page("TAKE")
pad(REPEAT, true)
ok(params:get("beat_repeat") == 1, "a held pad of the lowest pair holds the beat repeat")
X.push(MODE_PUSH)                   -- to KEYS under the finger
ok(G.ex.surface == false and params:get("beat_repeat") == 0,
  "a change to KEYS ends what the pads held")
pad(REPEAT, false)
ok(params:get("beat_repeat") == 0, "...and the late release does nothing")
X.push(MODE_PUSH)                   -- back to PADS

-- unplugged under a held pad
pad(REPEAT, true)
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
ok(hex(sent[#sent]) == X.setup_hex("off"), "cleanup leaves Developer Mode")
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
  ok(hex(sent[n4 + 1]) == X.setup_hex("pads"), "...and takes the pads over at once")
  G.redraw()
  local r = led(SCENE1)
  ok(r ~= nil, "...and the pads are painted with no grid to paint")
  params:set("rec", 0)
  pad(REC_PAD, true); pad(REC_PAD, false)
  ok(params:get("rec") == 1, "...and they play: the first pad of the bottom row is rec")
  params:set("rec", 0)
  -- a running status or a stray byte must not throw in the handler
  -- what a port can deliver beside the controls: clock, active sensing, an
  -- empty SysEx, a SysEx in pieces. Down norns's road, to both handlers.
  local CLOCK, SENSING, SYSEX = 0xF8, 0xFE, 0xF0      -- MIDI's own status bytes
  local function strays()
    X.raw({ CLOCK }); X.raw({ SENSING }); X.raw({ SYSEX, P.eox })
    X.raw({ table.unpack(P.setup, 1, 3) }); X.raw({ table.unpack(P.setup, 4) }); X.raw({ 0, P.eox })
  end
  local fine, why = pcall(function()
    strays()
  end)
  ok(fine, "stray messages throw in neither handler (" .. tostring(why) .. ")")
  -- a message cut short never comes from a port, and norns's to_msg throws on
  -- one. The driver's own handler still must not.
  fine, why = pcall(function()
    exq.event({})
    exq.event({ X.msg_pad(ANY_PAD, true)[1] })
    exq.event({ table.unpack(X.msg_cc(P.enc, P.enc_mid), 1, 2) })
  end)
  ok(fine, "a message cut short does not throw in the driver (" .. tostring(why) .. ")")
  -- the same strays in KEYS, where the note input does not turn the port away
  X.push(MODE_PUSH)
  ok(G.ex.surface == false, "to KEYS, alone")
  fine, why = pcall(function()
    strays()
  end)
  ok(fine, "...nor in KEYS (" .. tostring(why) .. ")")
  -- a pad's note in PADS reaches the note input too, which must not play it
  X.push(MODE_PUSH)
  params:set("keys_enable", 1); params:set("pitch", 1)
  pad(ANY_PAD, true); pad(ANY_PAD, false)
  ok(params:get("pitch") == 1, "a pad pressed in PADS is not also a played note")
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
  ok(count > 0, "norns.py holds the Exquis snippets")
  __ctx = CTX
  local real_print = print
  local function repl(code)
    local out
    -- the script logs through the same print: only the marked line is the
    -- answer, as in norns.py's exquis_ask
    print = function(v)
      local a = tostring(v):match("^@exq (.*)$")
      if a then out = a end
    end
    local fn, err = load(code)
    local okr, e2 = pcall(fn or error, err)
    print = real_print
    assert(fn and okr, "a device snippet does not run: " .. tostring(err or e2))
    assert(out, "a device snippet printed no marked answer")
    return out
  end
  do
    local marks = 0
    for _ in block:gmatch('print%("@exq ') do marks = marks + 1 end
    ok(marks == count, "every snippet prints its answer behind the mark (" .. marks .. " of " .. count .. ")")
  end
  for name, code in pairs(LUA) do
    ok(not code:find("%-%-"), "the snippet `" .. name .. "` holds no comment (a REPL line is one line)")
  end

  ok(repl(LUA.status) == "|nil|none|true", "status with no Exquis: no name, no mode, a grid ("
    .. tostring(repl(LUA.status)) .. ")")
  -- byte tables as norns.py's exquis_bytes writes them into the snippet
  local function rows(...)
    local out = {}
    for i, m in ipairs({ ... }) do out[i] = "{" .. table.concat(m, ", ") .. "}" end
    return "local BYTES = {" .. table.concat(out, ", ") .. "} "
  end
  local redo_down, redo_up = X.msg_cc(P.redo, X.MAX), X.msg_cc(P.redo, 0)
  ok(repl(rows(redo_down) .. LUA.bytes) == "0", "bytes with no Exquis deliver nothing")

  -- proto: the driver's table, as the tools read it. Every number that the
  -- tools use comes back as the driver has it.
  do
    local got = {}
    for item in repl(LUA.proto):gmatch("[^;]+") do
      local k, v = item:match("^([%w_]+)=(.*)$")
      got[k] = v
    end
    local same = true
    for k, v in pairs(P) do
      if (type(v) == "number" or type(v) == "string") and got[k] ~= tostring(v) then same = false end
    end
    for mode, mask in pairs(P.zones) do
      if got["zone_" .. mode] ~= tostring(mask) then same = false end
    end
    ok(same, "proto hands over every number of the driver's table")
    ok(got.enc_div == table.concat(P.enc_div, ","), "...the encoders' ticks")
    local cells, n = true, 0
    for id, x, y in got.cells:gmatch("(%d+):(%d+)%.(%d+)") do
      local cx, cy = P.cell(tonumber(id))
      if cx ~= tonumber(x) or cy ~= tonumber(y) then cells = false end
      n = n + 1
    end
    local carried = 0
    for _ in pairs(X.cell_of) do carried = carried + 1 end
    ok(cells and n == carried, "...and the fold, pad by pad (" .. n .. " pads)")
  end
  X.plug()
  G.redraw()
  ok(repl(LUA.status) == exq.name .. "|" .. exq.name .. "|KEYS|true", "status with one: its name, KEYS, a grid")
  T.goto_page("TAKE")
  local p1 = CTX.page
  ok(repl(rows(redo_down, redo_up) .. LUA.bytes) == "2" and CTX.page == p1 + 1,
    "bytes reach the driver: Redo steps the page")
  T.goto_page("TAKE")

  ok(repl("local WANT = true " .. LUA.surface) == "PADS" and G.ex.surface == true, "surface sets PADS")
  G.redraw()
  -- the tap: every message is logged, and the driver still gets it
  ok(repl(LUA.tap_on) == "true", "the tap goes in")
  ok(repl(LUA.tap_on) == "true" and repl(LUA.tap_read) == "", "...once, and starts empty")
  params:set("scene_slot", 1)
  pad(SCENE2, true); pad(SCENE2, false); X.turn(1, 1)
  ok(slot() == 2, "under the tap the driver still plays")
  ok(repl(LUA.tap_read) == table.concat({ hex(X.msg_pad(SCENE2, true)), hex(X.msg_pad(SCENE2, false)),
      hex(X.msg_cc(P.enc, P.enc_mid + 1)) }, ";"), "the tap reads what was sent, as hex")
  ok(repl(LUA.tap_read) == "", "...and a read empties it")
  ok(repl(LUA.tap_off) == "off", "the tap comes out")
  params:set("scene_slot", 1)
  pad(SCENE2, true); pad(SCENE2, false)
  ok(slot() == 2, "...and the driver's handler is back")
  params:set("scene_slot", 1)
  X.turn(1, -1)
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
  local function sweep(id) return repl("local ID, LEVEL = " .. id .. ", " .. X.MAX .. " " .. LUA.sweep) end
  ok(sweep(0) == "true" and sweep(1) == "true",
    "the sweep runs")
  ok(#sent == n5 + 2, "...one frame a pad")
  do
    local r0 = led(0)
    local r1, g1, b1 = led(1)
    ok(r0 == 0 and r1 == X.MAX and g1 == X.MAX and b1 == X.MAX, "...the pad before goes dark, this one white")
  end
  ok(repl(LUA.repaint) == "true", "repaint asks the driver for every LED")
  local n6 = #sent
  G.redraw()
  ok(#sent > n6 and X.paints_all(sent[n6 + 1]), "...and the next frame paints every pad")
  ok(repl("local WANT = false " .. LUA.surface) == "KEYS", "surface sets KEYS again")
  G.cleanup()
  X.unplug()
  __ctx = nil
end

T.report("exquis harness OK")
