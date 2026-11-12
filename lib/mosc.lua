-- mosc: the visuals link. The instrument's state goes out as OSC (UDP, over
-- Wi-Fi) to a computer running visuals/bridge.js, which hands it to Hydra.
-- MIDI stays in lib/mout.lua: one CC carries one 7-bit value, this carries all
-- of the fields below at full precision.
--
-- It writes nothing in the instrument. Every field is its own message,
-- /mangler/<key> with one argument, sent only when its value changed. A new
-- address, port or switch-on, and a refresh every two seconds, send every
-- field again: UDP drops packets, and a visual that starts late must still
-- learn the state. A param field goes out normalised 0..1 through its own
-- controlspec, so the filter cutoff is a position on the knob, not a number
-- of Hz. Floats are rounded to 3 decimals. The tick runs at the frame rate
-- (15 Hz); the browser smooths between messages.

local floor = math.floor

local C, pget

local REFRESH = 2          -- seconds between full resends
local FIELDS = {}          -- { key, path, id | read, norm, last }

local function add(key, id_or_fn, norm)
  local f = { key = key, path = "/mangler/" .. key, norm = norm }
  if type(id_or_fn) == "string" then f.id = id_or_fn else f.read = id_or_fn end
  FIELDS[#FIELDS + 1] = f
end

-- the fields. A string is a param id (read through pget, normalised when
-- `true`), a function reads anything else. The key is the OSC address.
add("page", function() return C.page end)
add("page_name", function() return C.PAGES[C.page] or "" end)
add("scene", "scene_slot")
add("look", "vis_look")
add("flash", "vis_flash")
add("mode", "mode")
add("rec", "rec")
add("freeze", "freeze")
add("env", function() return C.lfo and C.lfo.env or 0 end)
add("lfo1", function() return C.lfo and C.lfo.mods[1].out or 0 end)
add("lfo2", function() return C.lfo and C.lfo.mods[2].out or 0 end)
add("morph", "scene_morph_amt")
add("in_l", function() return C.amp_in[1] end)
add("in_r", function() return C.amp_in[2] end)
add("out_l", function() return C.amp_out[1] end)
add("out_r", function() return C.amp_out[2] end)
add("beat", function()
  local b = clock and clock.get_beats and clock.get_beats()
  return b and (b % 1) or 0
end)
add("tempo", function() return C.tempo() end)
add("play", function() return C.play_phase end)
add("rec_phase", function() return C.rec_phase end)
add("win_start", "pos_start")
add("win_end", "pos_end")
add("size", "size", true)
add("density", "density", true)
add("spread", "spread", true)
add("jitter", "grain_jitter", true)
add("pitch", "pitch", true)
add("cutoff", "cutoff", true)
add("resonance", "resonance", true)
add("drive", "drive", true)
add("dry_wet", "dry_wet", true)
add("delay_mix", "delay_mix", true)
add("rev_mix", "rev_mix", true)
-- track 2 (mangler2): on = switched on and audible, then its own head,
-- window and knobs, so the visuals can give it a layer of its own
add("t2_on", function()
  return (pget("t2_mode", 1) ~= 1 and pget("t2_level", 1) > 0.001) and 1 or 0
end)
add("t2_mode", "t2_mode")
add("t2_level", "t2_level")
add("t2_play", function() return C.play_phase2 or 0 end)
add("t2_win_start", "t2_pos_start")
add("t2_win_end", "t2_pos_end")
add("t2_size", "t2_size", true)
add("t2_density", "t2_density", true)
add("t2_pitch", "t2_pitch", true)
add("t2_cutoff", "t2_cutoff", true)

local M = { FIELDS = FIELDS, on = false, host = nil, port = nil, errors = 0 }

-- A host given as a name (the computer's name.local) is resolved here, once a
-- minute, and the number is what osc.send gets. osc.send looks a name up on
-- every message, which would be 100 lookups a second on the frame clock. A
-- name that cannot be resolved keeps the last number. A computer whose
-- address changed overnight is found again within a minute.
local RESOLVE_EVERY = 60   -- seconds
local resolved, resolved_name, resolved_at = nil, nil, -1e9

local function is_number_host(h)
  return h:match("^%d+%.%d+%.%d+%.%d+$") ~= nil
end

local function resolve(h)
  if is_number_host(h) then return h end
  local now = C.frame / C.FPS
  if resolved_name == h and now - resolved_at < RESOLVE_EVERY then return resolved end
  resolved_name, resolved_at = h, now
  local ok, p = pcall(io.popen, "getent ahostsv4 '" .. h:gsub("[^%w%.%-_]", "") .. "' 2>/dev/null")
  if ok and p then
    local line = p:read("l")
    p:close()
    local ip = line and line:match("^(%d+%.%d+%.%d+%.%d+)")
    if ip then
      if ip ~= resolved then print("mangler: osc host " .. h .. " is " .. ip) end
      resolved = ip
    end
  end
  return resolved
end
M.resolve = resolve

local dest = { "", 0 }     -- handed to osc.send; rebuilt in place on a change
local one = { 0 }          -- the argument list, reused for every message

local function value(f)
  local v
  if f.id then
    v = pget(f.id, 0)
    if f.norm then
      local p = params:lookup_param(f.id)
      local cs = p and p.controlspec
      if cs and cs.unmap then v = cs:unmap(v) end
    end
  else
    v = f.read()
  end
  if type(v) == "number" and v ~= floor(v) then v = floor(v * 1000 + 0.5) / 1000 end
  return v
end

function M.tick()
  if pget("osc_on", 0) ~= 1 or not (osc and osc.send) then
    M.on = false
    return
  end
  local name = params:get("osc_host")
  local port = floor(pget("osc_port", 9000) + 0.5)
  local host = name ~= nil and name ~= "" and resolve(name) or nil
  if host == nil then M.on = false; return end
  local full = not M.on or host ~= M.host or port ~= M.port
    or C.frame % (REFRESH * C.FPS) == 0
  if host ~= M.host or port ~= M.port then
    M.host, M.port = host, port
    dest[1], dest[2] = host, port
  end
  M.on = true
  sent_ev = 0
  for i = 1, #FIELDS do
    local f = FIELDS[i]
    local v = value(f)
    if full or v ~= f.last then
      f.last = v
      one[1] = v
      if not pcall(osc.send, dest, f.path, one) then
        M.errors = M.errors + 1
        if M.errors == 1 then print("mangler: osc send failed to " .. host .. ":" .. port) end
      end
    end
  end
end

function M.init(ctx)
  C = ctx
  pget = ctx.pget
end

-- MIDI events for the picture (an Octatrack on the TRS MIDI input, or any
-- other MIDI source). lib/minput.lua hands every message of every port here.
-- A note, a CC, a program change and the transport go out at once as
-- /mangler/ev/<name> with integer arguments, so a hit lands on the beat
-- instead of waiting for the next frame. A CC that did not change is not
-- sent again. At most EVENT_CAP events leave per frame, so a knob sweep or a
-- busy pattern cannot flood the Wi-Fi. Clock messages are never forwarded.
local EVENT_CAP = 24
local sent_ev = 0
local last_cc = {}
local evargs = { 0, 0, 0 }
local evrun = { 0 }

local function ev_send(name, args)
  if sent_ev >= EVENT_CAP then return end
  sent_ev = sent_ev + 1
  if not pcall(osc.send, dest, "/mangler/ev/" .. name, args) then
    M.errors = M.errors + 1
  end
end

function M.midi_in(msg, vport)
  if not (M.on and osc and osc.send) or pget("vis_midi", 1) ~= 1 then return end
  local t = msg.type
  if t == "note_on" and (msg.vel or 0) > 0 then
    evargs[1], evargs[2], evargs[3] = msg.ch or 1, msg.note or 0, msg.vel or 0
    ev_send("note", evargs)
  elseif t == "cc" then
    local key = (msg.ch or 1) * 128 + (msg.cc or 0)
    if last_cc[key] == msg.val then return end
    last_cc[key] = msg.val
    evargs[1], evargs[2], evargs[3] = msg.ch or 1, msg.cc or 0, msg.val or 0
    ev_send("cc", evargs)
  elseif t == "program_change" then
    evargs[1], evargs[2], evargs[3] = msg.ch or 1, msg.val or 0, 0
    ev_send("pc", evargs)
  elseif t == "start" or t == "continue" or t == "stop" then
    evrun[1] = t == "stop" and 0 or 1
    ev_send("run", evrun)
  end
end

-- the look the visuals show. Option 1 lets the visuals pick one by the page.
-- The order is mirrored by NAMES in visuals/hydra.js. It is a scene param
-- (lib/mscenes.lua), so a scene or a preset can bring its own look.
M.LOOKS = { "AUTO", "BARS", "FILTER", "SHAPES", "RINGS", "MOSAIC", "TUNNEL", "WAVES", "FACETS" }

-- The three connection params are remembered in a small file, so a norns that
-- is switched on tomorrow sends to the same computer with no setup. A pset
-- does not carry them: they are about this room, not about a sound.
local function cfg_path()
  return (_path and _path.data or "/home/we/dust/data/") .. "mangler/osc.cfg"
end

local loading, reading = false, false
local function cfg_save()
  if loading or reading then return end
  local f = io.open(cfg_path(), "w")
  if not f then return end
  f:write(string.format("%d\n%s\n%d\n", pget("osc_on", 0), params:get("osc_host") or "",
    floor(pget("osc_port", 9000) + 0.5)))
  f:close()
end

local function cfg_load()
  local f = io.open(cfg_path(), "r")
  if not f then return end
  local on, host, port = f:read("n"), nil, nil
  f:read("l"); host = f:read("l"); port = f:read("n")
  f:close()
  loading = true
  if host and host ~= "" then params:set("osc_host", host) end
  if port then params:set("osc_port", port) end
  if on then params:set("osc_on", on) end
  loading = false
end

M.cfg_reload = cfg_load   -- after a PSET read, which would put the old values back

function M.add_params()
  params:add_group("grp_osc", "visuals out (osc)", 6)
  params:add_option("vis_look", "visuals look", M.LOOKS, 1)
  params:add_binary("vis_flash", "visuals flash", "momentary", 0)   -- a hit on the picture, held
  params:add_binary("vis_midi", "midi to visuals", "toggle", 1)   -- notes, CCs, program changes, transport
  params:add_binary("osc_on", "osc out", "toggle", 0)
  params:add_text("osc_host", "osc host (ip or name.local)", "192.168.1.100")
  params:add_number("osc_port", "osc port", 1, 65535, 9000)
  for _, id in ipairs({ "osc_on", "osc_host", "osc_port" }) do params:set_action(id, cfg_save) end
  -- a PSET read puts its own values in these params (one saved after this
  -- change carries them): while it runs, nothing is written to the file, and
  -- the action_read hook restores the file's values afterwards
  local read = params.read
  if read then
    params.read = function(self, ...)
      reading = true
      local ok, err = pcall(read, self, ...)
      reading = false
      if not ok then error(err, 0) end
    end
  end
  cfg_load()
end

return M
