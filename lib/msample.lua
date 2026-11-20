-- msample: AUTOSAMPLE. four plays other gear over MIDI and records what comes
-- back on the line input: every note of a range, one after another, into one
-- new take on the focused track. Each note lands in its own slice, cut on its
-- own attack, and a MIDI keyboard then plays the take as a multisample,
-- polyphonically: a key plays the slice of the nearest sampled note, retuned
-- by the difference (ctx.route_note, ctx.pad_trigger).
--
-- The wiring: a norns MIDI port (SYSTEM > DEVICES > MIDI: a synth on USB, a
-- USB MIDI interface with DIN or TRS jacks, or a shield's own TRS jack) to
-- the gear's MIDI in, and the gear's audio out to four's line input.
--
-- Two ways to space the notes (`as_wait`):
--   TIME   each note is held `as_hold`, then `as_tail` of its release is
--          recorded before the next note.
--   DECAY  each note is held `as_hold`, then the next note waits until the
--          level written falls under `as_floor` for QUIET seconds: the sound
--          has died away. `as_tail` is then the longest wait.
-- A track holds 60 s. A pass that runs out of room ends early with the notes
-- it has, and says so. Where a new take does not start at 0 (an engine older
-- than the forty-ninth change), the room is what is left after the head.
--
-- It runs on the frame clock (M.tick, once a frame), so a note is as long as
-- the frames that hold it: within one frame (67 ms) of what was asked. Where
-- a slice starts does not depend on that. Each cut is the time its note went
-- out, measured from the arm, and the scan after the pass moves it onto the
-- note's own attack. The same scan counts the notes that came back silent,
-- so the pass says when the MIDI or the audio is not wired.
--
-- For the pass the take records the line input alone and starts fresh at the
-- start of the track's buffer: overdub, resample and start on sound go to 0,
-- the source to IN, and all four come back after.

local floor, max, min, abs = math.floor, math.max, math.min, math.abs
local C, pget

-- the first note goes out this long after the arm: the rec gate's 10 ms
-- ramp is open by then
local LEAD = 0.2
-- a cut sits this far before its note went out, so a sound that arrives
-- sooner than the engine starts to write is not cut off. The scan then
-- moves the cut onto the attack.
local EARLY = 0.02
-- and the scan leaves this much room before an attack it found
local ROOM = 0.002
-- DECAY: the level must stay under the floor this long
local QUIET = 0.15
-- the pass ends this far before the end of the track's buffer
local MARGIN = 1

local WAITS = { "TIME", "DECAY" }
local NAMES = { "C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B" }
local function note_name(n) return NAMES[n % 12 + 1] .. (floor(n / 12) - 1) end

local M = { LEAD = LEAD, EARLY = EARLY, QUIET = QUIET, MARGIN = MARGIN }

-- the pass while it runs, else nil
local run

local function int(id, default) return floor(pget(id, default) + 0.5) end

local function now()
  return util.time and util.time() or (C.frame or 0) / C.FPS
end

local function say(msg, detail) C.take_say(msg, detail) end

local function decay_mode() return int("as_wait", 1) == 2 end

-- the notes a pass plays, low to high: from the lowest note to the highest,
-- `as_step` apart (1 is every note)
function M.notes()
  local low, high, step = int("as_low", 48), int("as_high", 72), int("as_step", 1)
  local t = {}
  for note = low, max(low, high), step do t[#t + 1] = note end
  return t
end

-- the seconds a pass takes, the lead included. In DECAY the shortest it can
-- take, since each wait is the sound's own.
function M.length()
  local per = pget("as_hold", 1) + (decay_mode() and QUIET or pget("as_tail", 1))
  return LEAD + #M.notes() * per
end

function M.running() return run ~= nil end

local function note_off(r)
  if r.on then
    r.dev:note_off(r.on, 0, r.ch)
    r.on = nil
  end
end

local function restore(r)
  params:set("pre_level", r.saved[1])
  params:set("resample", r.saved[2])
  params:set("rec_wait", r.saved[3])
  params:set("rec_source", r.saved[4])
end

local function abort(msg, detail)
  local r = run
  run = nil
  note_off(r)
  if pget("rec", 0) == 1 then params:set("rec", 0) end
  restore(r)
  say(msg, detail)
end

-- the scan after the pass: each cut onto its note's attack, and a count of
-- the notes that came back silent. `cuts` is the table the pass put on the
-- pads: when anything replaced it meanwhile (a CHOP, a new take), the scan
-- lands nothing.
local function refine(tmp, cuts, notes)
  local B = C.BUF_SECS
  local out, silent = {}, 0
  local n = #notes
  for k = 1, n do
    local a, b = cuts[k], cuts[k + 1]
    local first, err = C.wav.onset_bounds(tmp, a, b, B, nil, C.task_yield)
    if not first and err ~= "silence" then
      print("four: AUTOSAMPLE could not read the take (" .. tostring(err) .. ")")
      return
    end
    if not first then
      silent = silent + 1
      out[k] = a
    else
      -- an attack inside the slice moves the cut onto it. Sound at the
      -- slice's very start is the last note's release: the cut stays.
      out[k] = max(a, first - ROOM / B)
    end
  end
  out[n + 1] = cuts[n + 1]
  if C.pad_cuts ~= cuts then return end
  C.pad_cuts = out
  if silent == n then
    say("AUTO: NOTHING CAME BACK",
      "AUTOSAMPLE: all " .. n .. " notes are silent. Check the gear's audio into four's "
      .. "input, and its MIDI port and channel")
  elseif silent > 0 then
    say("AUTO: " .. (n - silent) .. " NOTES, " .. silent .. " SILENT",
      "AUTOSAMPLE: " .. silent .. " of " .. n .. " notes are silent (out of the gear's range?)")
  else
    say("AUTO: " .. n .. " NOTES, KEYS PLAY",
      "AUTOSAMPLE: " .. n .. " notes, each cut on its attack")
  end
end

local function finish(t)
  local r = run
  run = nil
  note_off(r)
  params:set("rec", 0)
  restore(r)
  local n = #r.sent
  if n == 0 then
    say("AUTO: NO ROOM", "AUTOSAMPLE: not one note fitted")
    return
  end
  local B = C.BUF_SECS
  local cuts, notes = {}, {}
  for k = 1, n do
    cuts[k] = r.arm + max(0, r.sent[k] - EARLY) / B
    notes[k] = r.notes[k]
  end
  cuts[n + 1] = r.arm + t / B
  -- a take that came round the end of the buffer (an engine older than the
  -- forty-ninth change starts a take where its head is) has no place for cuts
  if cuts[n + 1] > 1 then
    say("AUTO: TAKE WRAPPED", "AUTOSAMPLE: the take crossed the buffer's end, the pads "
      .. "stay even. SYSTEM > RESTART brings the engine that starts a take at 0")
    return
  end
  C.pad_cuts, C.pad_notes = cuts, notes
  -- a multisample plays each slice from its start, at its own pitch (a slice
  -- past the eighth pad is a SLICE voice already, see ctx.pad_trigger)
  for k = 0, min(n, C.pad_n) - 1 do C.pad_type[k], C.pad_pitch[k] = 1, 0 end
  C.pad_edit_sync()
  params:set("pad_input", 1)
  if n < #r.notes then
    say("AUTO: " .. n .. " OF " .. #r.notes .. " FIT", "AUTOSAMPLE: the track was full after "
      .. n .. " of " .. #r.notes .. " notes, up to " .. note_name(notes[n]))
  else
    say("AUTO: " .. n .. " NOTES, KEYS PLAY", "AUTOSAMPLE: " .. n
      .. " notes recorded, pad input on: a MIDI keyboard plays them")
  end
  -- then onto the attacks (the dump runs as a background job)
  if C.scan_take then
    C.scan_take("AUTOSAMPLE", function(tmp) refine(tmp, cuts, notes) end)
  end
end

-- the momentary param: start a pass, or stop the one that runs
function M.start()
  if run then
    abort("AUTO: STOPPED", "AUTOSAMPLE stopped by hand, the take is kept as it is")
    return
  end
  if pget("stop_all", 0) == 1 then
    say("AUTO: STOP IS ON", "AUTOSAMPLE: everything is stopped, start it first")
    return
  end
  if pget("rec", 0) == 1 then
    say("AUTO: REC IS ON", "AUTOSAMPLE: a take is recording, stop it first")
    return
  end
  local port = int("as_port", 1)
  local dev = midi.connect(port)
  if not (dev and dev.device) then
    say("AUTO: NO MIDI ON PORT " .. port, "AUTOSAMPLE: nothing on MIDI port " .. port
      .. " (SYSTEM > DEVICES > MIDI)")
    return
  end
  local notes = M.notes()
  local secs = M.length()
  -- the room is what is left of the buffer after the take's start: 0 where a
  -- new take puts the head at 0 (the forty-ninth change), else the head
  local at = (C.head_resets and C.head_resets()) and 0 or (C.rec_phase or 0)
  local room = (1 - at) * C.BUF_SECS - MARGIN
  if secs > room then
    say(string.format("AUTO: %.0f S, TOO LONG", secs), string.format(
      "AUTOSAMPLE: %d notes take %.1f s, the track has %.1f s. Fewer notes, a larger "
      .. "step or shorter notes", #notes, secs, room))
    return
  end
  -- the gear comes back on the line input: the take's source is IN for the
  -- pass, whatever RELAY left it on
  local saved = { pget("pre_level", 0), pget("resample", 0), pget("rec_wait", 0),
    pget("rec_source", 1) }
  params:set("pre_level", 0)
  params:set("resample", 0)
  params:set("rec_wait", 0)
  params:set("rec_source", 1)
  params:set("rec", 1)
  if pget("rec", 0) ~= 1 then
    -- the arm was refused; its own words stay on the screen. One that waits
    -- for the UNDO copy is called off: a plain take must not start later
    -- in the autosample's place
    if C.arm_waiting then
      C.arm_waiting = false
      say("AUTO: KEEPING UNDO, AGAIN", "AUTOSAMPLE: the UNDO copy is still being written, press again")
    end
    restore({ saved = saved })
    return
  end
  run = {
    dev = dev, ch = int("as_ch", 1), vel = int("as_vel", 100),
    hold = pget("as_hold", 1), tail = pget("as_tail", 1),
    decay = decay_mode(), floor = pget("as_floor", 0.01),
    notes = notes, sent = {}, i = 0, on = nil, off_at = nil, quiet_at = nil,
    track = int("track_sel", 1), arm = C.rec_arm_phase or 0,
    t0 = now(), due = LEAD, saved = saved, room = room,
  }
  say("AUTO: REC " .. #notes .. " NOTES", string.format(
    "AUTOSAMPLE: %d notes, %s to %s, on port %d channel %d, %s, at least %.1f s",
    #notes, note_name(notes[1]), note_name(notes[#notes]), port, run.ch,
    WAITS[run.decay and 2 or 1], secs))
end

-- DECAY: has the last note died away? The level written must stay under the
-- floor for QUIET seconds; `as_tail` after the note off is the longest wait.
local function decayed(r, t)
  if t - r.off_at >= r.tail then return true end
  if (C.rec_amp or 0) >= r.floor then
    r.quiet_at = nil
    return false
  end
  r.quiet_at = r.quiet_at or t
  return t - r.quiet_at >= QUIET
end

-- once a frame
function M.tick()
  local r = run
  if not r then return end
  -- anything else that ends the take ends the pass
  if pget("rec", 0) ~= 1 or pget("stop_all", 0) == 1 or int("track_sel", 1) ~= r.track then
    abort("AUTO: STOPPED", "AUTOSAMPLE stopped: the take was stopped or moved")
    return
  end
  C.take_msg_at = C.frame   -- the progress stays on TAKE's top row
  -- (a hair forward: frames counted in seconds must not miss a due time
  -- by a rounding of the division)
  local t = now() - r.t0 + 1e-6
  local room = r.room
  if t >= room then finish(t); return end
  if r.on then
    if t < r.due then return end
    note_off(r)
    r.off_at, r.quiet_at = t, nil
    r.due = r.due + r.tail
    return
  end
  if r.i > 0 then
    if r.decay then
      if not decayed(r, t) then return end
    elseif t < r.due then
      return
    end
  elseif t < r.due then
    return
  end
  -- the next note, when one is left and its hold fits
  if r.i >= #r.notes or t + r.hold + (r.decay and QUIET or r.tail) > room then
    finish(t)
    return
  end
  r.i = r.i + 1
  local note = r.notes[r.i]
  r.dev:note_on(note, r.vel, r.ch)
  r.on = note
  r.sent[r.i] = t
  r.due = t + r.hold
  say("AUTO " .. r.i .. "/" .. #r.notes .. " " .. note_name(note))
end

-- a key on the multisample: the slice (0-based) whose note is nearest, and
-- the semitones from that note. A tie takes the lower note.
function M.slice_of(note)
  local ns = C.pad_notes
  local best, bd = 0, math.huge
  for j = 1, #ns do
    local d = abs(note - ns[j])
    if d < bd then best, bd = j - 1, d end
  end
  return best, max(-24, min(24, note - ns[best + 1]))
end

function M.cleanup()
  if run then note_off(run) end
  run = nil
end

function M.init(ctx)
  C = ctx
  pget = ctx.pget
end

function M.add_params()
  params:add_group("grp_auto", "take - autosample", 11)
  params:add_binary("as_go", "autosample", "momentary", 0)
  params:set_action("as_go", function(v) if v == 1 then M.start() end end)
  params:add_number("as_port", "autosample midi port", 1, 16, 1)
  params:add_number("as_ch", "autosample channel", 1, 16, 1)
  local function fmt_note(p) local v = p:get(); return note_name(v) .. " (" .. v .. ")" end
  params:add_number("as_low", "lowest note", 0, 127, 48, fmt_note)
  params:add_number("as_high", "highest note", 0, 127, 72, fmt_note)
  params:add_number("as_step", "semitones apart", 1, 24, 1)
  params:add_number("as_vel", "velocity", 1, 127, 100)
  params:add_control("as_hold", "note length",
    controlspec.new(0.05, 10, "lin", 0.05, 1.0, "s"))
  params:add_option("as_wait", "next note after", WAITS, 1)
  params:add_control("as_tail", "release time",
    controlspec.new(0, 10, "lin", 0.05, 1.0, "s"))
  params:add_control("as_floor", "decay floor",
    controlspec.new(0.001, 0.2, "exp", 0, 0.01, ""))
end

return M
