# Visuals

Live visuals in a browser that follow four. They were built for live shows with mangler,
four's predecessor, and are not yet tested with four.

The visuals show the live news as old VHS tape, with a reactive look on top. They
react to the norns in two ways: to the sound (an audio cable) and to the state of
the instrument (OSC over Wi-Fi).

## Plug and play

1. Switch on the norns. If it was shut down properly (SYSTEM, SLEEP), it loads four by itself and sends to the computer it remembers. If the power was pulled instead, the norns shows NO SCRIPT: pick four with K3 in the script list (SELECT), and it then sends as before.
2. On the computer, double click `visuals/start.command`. It starts the bridge, keeps the computer awake and opens the page full screen in Brave or Chrome.
3. Run `sh visuals/doctor.command`. Every line must say "ok".
4. Audio: the default input of the computer must be the norns return (System Settings, Sound, Input). The page cannot change it.
5. To stop: `visuals/stop.command`.

The computer and the norns must be on the same Wi-Fi network. If the network is new,
set the norns once: PARAMS, "visuals out (osc)", "osc host" to this computer's name
(`<name>.local`, `doctor.command` prints it) and "osc out" on. The norns writes this to
`dust/data/four/osc.cfg` and sends there from then on. A name is better than a number,
because the norns looks the name up every minute and finds the computer again when the
network gives it a new address. A PSET never changes these settings.

## The news

The picture is a live news stream. It runs all day and night, picture and sound together,
so there is nothing to start or to string together. The page plays DW News. If that
stream stops or freezes for 20 seconds, it moves to France 24 and back. It plays with
sound at once when opened by `start.command`; opened by hand, it is muted until you click it.
`?video=<url>` plays one other address, `?video=none` shows no picture.

For the norns to sample the news, the sound must reach the norns line in: the computer output
into the norns input. The visuals then also react to it through the norns return.

Audio routing, for a mixer or an interface:

1. The news plays on the computer. Send that output to the norns line in.
2. Connect the norns line out to an input of the computer or the interface.
3. Set that input as the default input of the computer.

## What you see

Three layers. The bed is the news worn like tape: low resolution, faded warm colour, a slow
wobble, scanlines, grain and a smear of the last frame, with slow blobs through it. On top
sits a reactive LOOK, and its black is see-through. On top of that is the tape's own display:
PLAY, a counter, the date, the news source, the look, the scene and the mode, and a red REC while the
norns records. A scene change shows FF (a higher scene) or REW (a lower one) for a moment and tears
the picture; a page change shows the page name; a freeze shows PAUSE and shakes the picture. Last, the picture gets the tape's faults: the colours slip apart (more when
the input is loud), a tracking band rolls up and tears the picture, the corners fall into
shadow, and everything breathes on the beat of the norns clock.

## Looks

The nine options of "visuals look" on the norns: AUTO, BARS (grain size and density), FILTER
(cutoff and playhead), SHAPES (scene and morph), RINGS (density and input level), MOSAIC
(the news in coarse blocks), TUNNEL (feedback that falls inwards), WAVES (lines that ripple
with the input) and FACETS (the news as flat shards, like a low-poly model). AUTO picks one by
the page.

The look is a scene param, so each scene remembers its own. A recalled scene brings its look,
and a preset can bring a different look per scene. To set one, recall a scene, set "visuals look", and capture the scene again
on the SCENE page. The order of the names must match `M.LOOKS` in `lib/mosc.lua` and `NAMES`
in `visuals/hydra.js`.

## Grid pads for the visuals

On the main workspace, row 6: x6 steps the look back, x7 steps it forward, x8 held is a FLASH
(the picture tears and brightens while you hold it). The first look, AUTO, lights the two step
pads dim. Row 2 shows the freezes in ice blue and a recording in soft red.

## A second computer (projector)

Start with `LAN=1 sh visuals/start.command`. On the other computer, open
`http://<laptop name>.local:8080` in a browser on the same Wi-Fi. The bridge then listens on the
whole network, so use it only on a network you trust. A page opened this way has no microphone
access (browsers allow that only on the computer itself), but it still reacts to the norns,
because the OSC messages come through the bridge. Without `LAN=1` the bridge stays local.

## An Octatrack (or any MIDI source)

Connect the Octatrack's MIDI OUT to the norns shield's TRS MIDI IN (check Type A or B). Set the
norns clock source to `midi` if the Octatrack should lead the tempo. Everything it sends reaches
the picture, while the parameter "midi to visuals" is on (the default):

A note draws a shape. The track (MIDI channel) picks the column and the note picks the height,
so a pattern across the tracks draws across the screen. A program change types the pattern
name, for example PTN A01 (set PROG CH OUT on the Octatrack, MIDI, CONTROL menu). A CC types its
number and value, a start types PLAY and a stop types STOP. The last event also shows in the
display, above the page name. Nothing is drawn unless an event arrives: the shapes (rings, low-poly
shards, spirals, bursts, lattices, scribbles, one colour per track) and the words come only from
the Octatrack. The MIDI clock is not forwarded.

The same notes also play four (the pads) if "keys enable" is on and the channel
matches. To use the Octatrack for the picture only, set four's "midi channel" to one the
Octatrack does not send on, or switch "keys enable" off.

## What goes out

Every field is one message, /four/<key>, one argument. fields.json lists them. A knob goes
out as 0 to 1 on its own scale. The norns sends a field when it changes, and the whole state
again every two seconds and when you switch on or change the host or port. The rate is the
frame rate of four (15 per second). Hydra smooths between messages.

## If something is wrong

The page shows "NO BRIDGE" or "WAITING FOR THE NORNS" in the middle of the picture when
nothing arrives for four seconds. `doctor.command` says which part is missing.
The bridge log is `/tmp/four-bridge.log`.

## Tests

`node visuals/test_bridge.js` runs a fake norns and a fake page against the bridge.
`lua test/test_control.lua` checks the norns side, including that fields.json lists every field.
