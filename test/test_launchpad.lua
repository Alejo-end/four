-- test_launchpad.lua — the Launchpad Mini MK3 driver, offline.
--
-- midigrid emulates a MONOCHROME grid, so a launchpad shows every state as
-- shades of one hue. This driver talks to the Mini MK3 directly in Programmer
-- mode with real RGB, which is why the instrument's semantic colours (red =
-- recording, green = playing, purple = destructive) mean anything on it.
--
-- It is device-confirmed but was only ever checked by a throwaway harness. The
-- parts that fail SILENTLY are the ones asserted here: a wrong note number puts
-- a pad in the wrong place, a wrong SysEx frame is simply ignored by the
-- hardware, and picking the DAW port instead of the surface port gives you a
-- grid that lights but never responds.
--
--   lua test/test_launchpad.lua        # from the repo root

local T = dofile("test/harness.lua")
local ok, near = T.ok, T.near

-- lift the pure helpers out of mgrid rather than copying them
local src = io.open("lib/mgrid.lua"):read("a")
local function lift(pat, name)
  local chunk = src:match(pat)
  assert(chunk, "could not lift " .. name .. " out of lib/mgrid.lua")
  return chunk
end
local env = setmetatable({ floor = math.floor, min = math.min, max = math.max },
                         { __index = _G })
local helpers = table.concat({
  lift("(local LP_HUE = %b{})", "LP_HUE"),
  lift("(local LP_HUE_ID = %b{})", "LP_HUE_ID"),
  lift("(local LP_RGB = %b{})", "LP_RGB"),
  lift("(local function lp_note.-\nend)", "lp_note"),
  lift("(local function lp_xy.-\nend)", "lp_xy"),
  lift("(local function lp_find_device.-\nend)", "lp_find_device"),
}, "\n")
-- NB the explicit newline: Lua discards the first one after [[, so without it
-- the lifted chunk's final `end` runs straight into `return`
local H = load(helpers .. "\n" .. [[
return { note = lp_note, xy = lp_xy, find = lp_find_device,
         HUE = LP_HUE, ID = LP_HUE_ID, RGB = LP_RGB }
]], "lp", "t", env)()

-- ---- pad geometry ---------------------------------------------------------
-- Programmer mode numbers pads 10*row+col with row 1 at the BOTTOM, and the
-- grid's y=1 is the TOP. Getting this backwards flips the whole surface, and
-- nothing errors — the pads just light in the wrong places.
ok(H.note(1, 8) == 11, "bottom-left pad is note 11")
ok(H.note(8, 1) == 88, "top-right pad is note 88")
ok(H.note(1, 1) == 81, "top-left pad is note 81")
ok(H.note(8, 8) == 18, "bottom-right pad is note 18")

local round = true
for y = 1, 8 do
  for x = 1, 8 do
    local rx, ry = H.xy(H.note(x, y))
    if rx ~= x or ry ~= y then round = false end
  end
end
ok(round, "every pad round-trips through note and back")
ok(H.xy(9) == nil and H.xy(89) == nil, "notes off the 8x8 grid are rejected")
ok(H.xy(19) == nil, "...including the side column")

-- ---- the semantic palette -------------------------------------------------
-- These names are the instrument's colour language: the same hue means the same
-- thing on every page. A missing one silently falls back to brightness-only.
for _, name in ipairs({ "red", "green", "blue", "white", "yellow",
                        "orange", "cyan", "purple", "teal" }) do
  local idx = H.ID[name]
  ok(type(idx) == "number", "the palette names " .. name)
  ok(type(H.HUE[idx]) == "table" and #H.HUE[idx] == 3,
    "..." .. name .. " has an RGB triple")
end
local seen, dup = {}, false
for name, idx in pairs(H.ID) do
  if seen[idx] then dup = true end
  seen[idx] = name
end
ok(not dup, "every hue has its own index (a collision would merge two meanings)")
local over = false
for _, c in ipairs(H.HUE) do
  for i = 1, 3 do if c[i] > 127 then over = true end end
end
ok(not over, "no hue component exceeds 127 (SysEx data bytes are 7-bit)")

-- the brightness ramp must be monotone, or a dim pad can look brighter than a lit one
local mono = true
for l = 1, 15 do
  local a, b = H.RGB[l - 1], H.RGB[l]
  if not (a and b) then mono = false
  elseif (b[1] + b[2] + b[3]) < (a[1] + a[2] + a[3]) then mono = false end
end
ok(mono, "the brightness ramp never goes backwards")
ok(H.RGB[0][1] == 0 and H.RGB[0][2] == 0 and H.RGB[0][3] == 0, "level 0 is off")
local maxc = 0
for l = 0, 15 do
  for i = 1, 3 do maxc = math.max(maxc, H.RGB[l][i]) end
end
ok(maxc <= 127, "no colour component exceeds 127 (SysEx data bytes are 7-bit)")

-- ---- picking the right port ----------------------------------------------
-- The Mini MK3 presents two USB ports. The DAW port lights but does not report
-- pad presses, so choosing it gives a grid that looks alive and does nothing.
local function find(names)
  local devs = {}
  for i, n in ipairs(names) do devs[i] = { name = n } end
  midi = { devices = devs }
  return H.find()
end
-- REAL ALSA names, not tidied ones: they carry a client:port suffix, and the
-- digits in it match the same "is this the second interface?" heuristic the
-- port choice uses. With clean names the DAW exclusion looks redundant; with
-- real ones it is the only thing keeping you off the port that never reports
-- a pad press.
local d = find({ "Launchpad Mini MK3:Launchpad Mini MK3 LPMiniMK3 DAW In 28:0",
                 "Launchpad Mini MK3:Launchpad Mini MK3 LPMiniMK3 MIDI In 28:1" })
ok(d and d.name:find("MIDI In"), "a DAW port whose ALSA name contains digits is still refused")
d = find({ "Launchpad Mini MK3 LPMiniMK3 DAW In",
                 "Launchpad Mini MK3 LPMiniMK3 MIDI In" })
ok(d and d.name:find("MIDI"), "the MIDI/surface port is preferred over DAW")
d = find({ "Launchpad Mini MK3 LPMiniMK3 MIDI In",
           "Launchpad Mini MK3 LPMiniMK3 DAW In" })
ok(d and d.name:find("MIDI"), "...whichever order they are enumerated in")
ok(find({ "nanoKONTROL2", "Arturia KeyStep" }) == nil,
  "an unrelated controller is not mistaken for a launchpad")
ok(find({}) == nil, "no devices at all is handled")
-- a DAW-only port is REFUSED. It lights but never reports pad presses, so
-- falling back to midigrid gives a grid that works; taking it would give one
-- that looks alive and does nothing.
midi = { devices = { { name = "Launchpad Mini MK3 LPMiniMK3 DAW In" } } }
ok(H.find() == nil, "a DAW-only port is refused rather than half-working")

-- ---- the SysEx frame ------------------------------------------------------
-- A malformed frame is IGNORED by the hardware: no error, no light, nothing to
-- debug. The header and terminator are asserted against Novation's documented
-- Programmer's Reference.
local hdr = src:match("local LP_RGB_HDR = (%b{})")
ok(hdr ~= nil, "the RGB header is defined")
local bytes = {}
for n in (hdr or ""):gmatch("0x(%x+)") do bytes[#bytes + 1] = tonumber(n, 16) end
local expect = { 0xF0, 0x00, 0x20, 0x29, 0x02, 0x0D, 0x03 }
local same = #bytes == #expect
for i = 1, #expect do if bytes[i] ~= expect[i] then same = false end end
ok(same, "the RGB SysEx header is F0 00 20 29 02 0D 03 (Novation's)")
ok(src:find("0xF7", 1, true) ~= nil, "frames are terminated with F7")
ok(src:find("LP_PROG", 1, true) ~= nil, "Programmer mode is entered on connect")
ok(src:find("LP_LIVE", 1, true) ~= nil, "...and Live mode restored on cleanup")

T.report("launchpad harness OK")
