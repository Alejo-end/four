-- minput: chromatic note input — midi notes and the usb typing keyboard.
--
-- every note goes through ctx.route_note, which sends it one of two ways:
--   pad input OFF  the note retunes the drone: `pitch` = 2^(semitones/12)
--                  relative to root_note (middle C with the default root plays
--                  the sample as recorded; the 0.25-4 spec covers ±24 st).
--                  last-note priority, so the release is ignored.
--   pad input ON   the note gates a polyphonic PADS voice (note mod 8), held
--                  until its release.
-- CC mappings (PMAP) are handled by the system and unaffected by this.

local midi_devices = {}

local C     -- shared ctx, bound at init
local pget, ptoggle, FPS

-- true when vport i holds the device the grid layer adopted (midigrid, OR the
-- native Launchpad Mini MK3 colour driver): its note-ons are grid pads, not
-- notes. norns dispatches midi to BOTH the device-level handler (which those
-- use) and the vport-level handler (which we use), so without this filter every
-- pad press would also yank `pitch` to whatever the pad's raw note maps to.
local function is_grid_vport(i)
  local G = C.grid
  local gg = G.gg
  if not ((G.midigrid_loaded or G.have_launchpad) and gg and gg.device) then return false end
  local vp = midi.vports[i]
  local dev = vp and vp.device
  if not dev then return false end
  return dev == gg.device or dev.name == gg.device.name
end

local function midi_event(data, vport)
  if is_grid_vport(vport) then return end
  local msg = midi.to_msg(data)
  -- the picture hears every port (an Octatrack on the TRS input, for one)
  if C.osc and C.osc.midi_in then C.osc.midi_in(msg, vport) end
  -- a mapped CC is a hand on the instrument too (idle dim); notes count
  -- through route_note. clock and other system messages do not.
  if msg.type == "cc" then C.touch_input() end
  -- both edges: note-on gates a voice / retunes the drone, note-off releases
  -- a voice (the drone is last-note, so it ignores the release)
  local z, note
  if msg.type == "note_on" and (msg.vel or 0) > 0 then
    z, note = 1, msg.note
  elseif msg.type == "note_off" or (msg.type == "note_on" and (msg.vel or 0) == 0) then
    z, note = 0, msg.note
  else
    return
  end
  -- the gates apply to PRESSES only: a release belongs to the press that
  -- opened it, so keys_enable going off (or the channel changing) mid-hold
  -- must never swallow a note-off and strand a pad voice — the same trap the
  -- typing keyboard guards below. a release for a note we never opened is a
  -- no-op inside route_note/pad_trigger.
  if z == 1 then
    if pget("keys_enable", 1) == 0 then return end
    local ch = pget("midi_channel", 0)
    if ch > 0 and msg.ch ~= ch then return end
  end
  -- route_note decides drone vs pad from `pad_input`; id offset by 1000 so
  -- MIDI voice ids never collide with grid/screen pad ids
  C.route_note(1000 + note, 2 ^ ((note - pget("root_note", 60)) / 12), note, z)
end

-- USB typing keyboard: ableton-style musical typing. the A-row is the white
-- keys, the W-row the black keys — A plays the sample as recorded, and Z/X
-- shift the octave (kb_octave). semitone offsets are root-relative, so the
-- root_note param only concerns MIDI (which sends absolute note numbers).
local KB_NOTES = {
  A = 0, W = 1, S = 2, E = 3, D = 4, F = 5, T = 6, G = 7, Y = 8,
  H = 9, U = 10, J = 11, K = 12, O = 13, L = 14, P = 15,
  SEMICOLON = 16, APOSTROPHE = 17,
}

-- key code -> the semitone it was pressed AT, while held. the id a voice is
-- opened with must be keyed on the physical KEY, not the note, or an octave
-- shift mid-hold would compute a different id at release and strand the voice
-- (the grid keys on the pad coordinate for the same reason).
local kb_held = {}

local M = {}

function M.init(ctx)
  C = ctx
  pget, ptoggle, FPS = ctx.pget, ctx.ptoggle, ctx.FPS
  keyboard.code = function(code, value)
    if value == 2 then return end           -- autorepeat: a held key is not a new press
    -- a release belongs to the press that opened it: if this key started a
    -- voice, close it whatever the gates say NOW. the menu opening or
    -- keys_enable going off mid-hold must never leave a note sounding.
    if value == 0 then
      local st = kb_held[code]
      if st then
        kb_held[code] = nil
        local semi = st + 12 * pget("kb_octave", 0)
        C.route_note(3000 + st, 2 ^ (semi / 12), semi, 0)
      end
      return
    end
    if norns.menu.status() then return end  -- the menu owns typing (PSET names)
    -- SPACE = master stop/start, ableton muscle memory. it's transport, not
    -- note input, so it works even with keys_enable off
    if code == "SPACE" then
      C.touch_input()
      ptoggle("stop_all")
      return
    end
    if pget("keys_enable", 1) == 0 then return end
    if code == "Z" or code == "X" then
      C.touch_input()
      params:delta("kb_octave", code == "X" and 1 or -1)
    else
      local st = KB_NOTES[code]
      if st then
        local semi = st + 12 * pget("kb_octave", 0)
        -- both edges, like the grid: route_note plays pad (semi mod 8) as a
        -- polyphonic voice in pad mode, or retunes the mono drone (which
        -- ignores the release) otherwise. ids 3000+ keep typing-keyboard
        -- voices clear of MIDI (1000+), grid (2000+ note / 2600+ slice), the
        -- screen bank (0..8) and the sequencer (4000).
        kb_held[code] = st
        C.route_note(3000 + st, 2 ^ (semi / 12), semi, 1)
        -- in pad mode `pitch` doesn't move, so don't swell a value that isn't
        -- changing — the pad cell lighting is the feedback there
        if pget("pad_input", 0) == 0 then
          C.flash_id, C.flash_until = "pitch", C.frame + FPS
        end
      end
    end
  end
end

function M.init_midi()
  -- connect every vport: any keyboard works, including ones plugged in later
  for i = 1, #midi.vports do
    midi_devices[i] = midi.connect(i)
    midi_devices[i].event = function(data) midi_event(data, i) end
  end
end

function M.cleanup()
  for _, d in ipairs(midi_devices) do d.event = nil end
  keyboard.code = nil
  kb_held = {}   -- the voices themselves are released by ctx.pads_all_off()
end

return M
