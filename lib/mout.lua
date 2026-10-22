-- mout: the modulation OUTPUT. One source of the instrument's movement, sent
-- to other gear as a MIDI CC, and to crow's output 1 as 0..5 V when a crow is
-- connected. The sources are what already moves on its own: the scene morph
-- (so the orbit and a GLIDE drive the outboard too), the input envelope, and
-- the two LFOs' waves (lib/mlfo.lua), which run even when they move no knob.
--
-- It writes nothing in the instrument. A CC goes out only when its 7-bit value
-- changes, so a still source sends nothing; crow only when the voltage moves
-- by more than a millivolt or so.

local floor = math.floor
local C, pget

local SOURCES = { "OFF", "MORPH", "ENV", "LFO 1", "LFO 2" }

local M = { SOURCES = SOURCES, last_cc = -1, last_v = -1, dev = nil, dev_port = 0 }

-- the source's value now, 0..1, or nil when OFF
function M.value()
  local s = floor(pget("out_src", 1) + 0.5)
  if s == 2 then return pget("scene_morph_amt", 0) end
  local lfo = C.lfo
  if not lfo then return nil end
  if s == 3 then return lfo.env end
  if s == 4 or s == 5 then return lfo.mods[s - 3].out end
  return nil
end

local function device()
  local port = floor(pget("out_midi", 0) + 0.5)
  if port ~= M.dev_port then
    M.dev_port, M.last_cc = port, -1
    M.dev = port > 0 and midi.connect(port) or nil
  end
  return M.dev
end

function M.tick()
  local v = M.value()
  if not v then return end
  v = math.min(math.max(v, 0), 1)
  local dev = device()
  if dev and dev.cc then
    local cc = floor(v * 127 + 0.5)
    if cc ~= M.last_cc then
      M.last_cc = cc
      dev:cc(floor(pget("out_cc", 1) + 0.5), cc, floor(pget("out_ch", 1) + 0.5))
    end
  end
  if pget("out_crow", 0) == 1 and crow and crow.output and crow.connected
      and crow.connected() then
    local volts = v * 5
    if math.abs(volts - M.last_v) > 0.002 then
      M.last_v = volts
      crow.output[1].volts = volts
    end
  end
end

function M.init(ctx)
  C = ctx
  pget = ctx.pget
end

function M.add_params()
  params:add_group("grp_out", "modulation out", 5)
  params:add_option("out_src", "out source", SOURCES, 1)
  params:add_number("out_midi", "out midi port", 0, 16, 0,
    function(p) local v = p:get(); return v == 0 and "OFF" or tostring(v) end)
  params:add_number("out_ch", "out midi channel", 1, 16, 1)
  params:add_number("out_cc", "out cc number", 0, 127, 1)
  params:add_binary("out_crow", "out to crow 1", "toggle", 0)
end

return M
