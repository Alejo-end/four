-- minput: chromatic note input — midi note-ons and the usb typing keyboard,
-- both retuning `pitch` relative to the root note.
--
-- note-ons set `pitch` = 2^(semitones/12) relative to root_note: middle C
-- (with the default root) plays the sample as recorded, and the 0.25–4 spec
-- covers ±24 st (notes beyond that clamp to the edges). last-note priority,
-- no envelope — a note retunes the running voice rather than gating one.
-- CC mappings (PMAP) are handled by the system and unaffected by this.

local midi_devices = {}

local C     -- shared ctx, bound at init
local pget, FPS

-- true when vport i holds the device midigrid adopted as the grid: its
-- note-ons are grid pads, not notes. norns dispatches midi to BOTH the
-- device-level handler (which midigrid uses) and the vport-level handler
-- (which we use), so without this filter every pad press would also yank
-- `pitch` to whatever the pad's raw note number maps to.
local function is_grid_vport(i)
  local G = C.grid
  local gg = G.gg
  if not (G.have_midigrid and gg and gg.device) then return false end
  local vp = midi.vports[i]
  local dev = vp and vp.device
  if not dev then return false end
  return dev == gg.device or dev.name == gg.device.name
end

local function midi_event(data, vport)
  if is_grid_vport(vport) then return end
  local msg = midi.to_msg(data)
  if msg.type ~= "note_on" or (msg.vel or 0) == 0 then return end
  if pget("keys_enable", 1) == 0 then return end
  local ch = pget("midi_channel", 0)
  if ch > 0 and msg.ch ~= ch then return end
  params:set("pitch", 2 ^ ((msg.note - pget("root_note", 60)) / 12))
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

local M = {}

function M.init(ctx)
  C = ctx
  pget, FPS = ctx.pget, ctx.FPS
  keyboard.code = function(code, value)
    if value ~= 1 then return end           -- key-down only (2 = autorepeat)
    if norns.menu.status() then return end  -- the menu owns typing (PSET names)
    if pget("keys_enable", 1) == 0 then return end
    if code == "Z" or code == "X" then
      params:delta("kb_octave", code == "X" and 1 or -1)
      C.flash_id, C.flash_until = "kb_octave", C.frame + FPS
    else
      local st = KB_NOTES[code]
      if st then
        params:set("pitch", 2 ^ ((st + 12 * pget("kb_octave", 0)) / 12))
        C.flash_id, C.flash_until = "pitch", C.frame + FPS
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
end

return M
