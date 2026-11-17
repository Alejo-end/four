# four

four is a live sampler for [norns](https://monome.org/docs/norns/). Record a synth, a drum
machine or any line-level sound onto four stereo tracks. Then loop, stretch, grain and
filter the takes while you play.

The website shows every page on four's real screen:
[alejo-end.github.io/four-site](https://alejo-end.github.io/four-site/).

![A pocket-sized version of the norns shield with four on its screen](doc/four-on-device.png)

*A render of four on a pocket-sized version of the norns shield, built around a Raspberry
Pi Compute Module 4. The device is still in design.*

## What it does

Each track records its own take of up to 60 seconds and loops it. The take then runs
through the track's own chain:

- A voice. PLAY is the take as tape, with varispeed. GRAIN sprays it into a cloud of
  stereo grains. WARP and PV change the speed and keep the pitch. CLOUD is Mutable
  Instruments Clouds.
- A diode ladder filter (low-pass, high-pass or band-pass), then drive and crush.
- Two effect slots: chorus, flanger, wobble, resonator, ring modulator or echo.
- Sends to the other tracks, to a shared bucket brigade delay and to a shared room reverb.

Under the tracks runs a tape loop that records what four plays, or the input alone. PADS
cuts the loop into eight slices, and a step sequencer can play them. SCENE keeps whole
sounds in eight slots and crossfades between two of them. MOTION loops your knob moves,
and four modulators move the sound around where you left the knobs.

Everything sits on the three keys and three encoders of the norns. A grid is optional, and
every parameter maps to MIDI.

## Requirements

- A norns with current software. four is tested on a norns shield with a Raspberry Pi 4.
- A line-level sound on the norns input.
- Optional: a monome grid or a Launchpad Mini MK3. Other Launchpad and APC models work
  through [midigrid](https://github.com/jaggednz/midigrid).
- Optional: a MIDI controller, a USB typing keyboard or a crow.

## Install

In maiden, type this line:

```
;install https://github.com/Alejo-end/four
```

Then do SYSTEM > RESTART and pick four from SELECT. That is all: the restart also installs
four's plugin, and there is nothing to build.

## The plugin

Part of four's sound comes from its own plugin, FourStretch. It is C++ code for
SuperCollider, written for four. It gives WARP and PV their clean time-stretch, CLOUD its
Clouds, and the delay and the reverb their bucket brigade and room.

The plugin installs itself during the restart after the install. When four loads, maiden's
SuperCollider tab says `four: FourStretch on`. If four's screen ever says
`PLUGIN INSTALLED / SYSTEM > RESTART`, for example after an update, do one more restart.

On a norns where the plugin does not fit, four plays simpler stock versions of the same
voices and effects. Everything else works the same. To build the plugin yourself, see
[ugen/README.md](ugen/README.md).

## First minutes

1. On TAKE, press K2, play something, then press K2 again. The take loops.
2. E2 and E3 move the start and the end of the loop.
3. Turn E1 to VOICE and press K3 to step through the voices.
4. Go on to FILTER and EFFECT and turn things up.
5. The delay and the reverb stay silent until a track sends to them. On TRACKS, hold K1,
   turn E2 to D or R and turn E3 up.
6. Hold K1 and turn E1 to pick track 2. Record a second take there.
7. On SCENE, press K3 to capture the sound. Change things, then hold K1 and turn E3 to fade
   back to it.

Two moves work on every page. K1 + K2 stops and starts everything. A tap of K1 + K3 turns
every effect off.

## The pages

![The twelve pages of four](doc/ui/four.png)

TAKE, VOICE, TRACKS, TAPE, FILTER, EFFECT, DELAY, REVERB, MIX, PADS, MOTION and SCENE.
E1 moves between them. The bottom line of the screen names what K2, K3, E2 and E3 do on
each page.

## Documentation

- [The full guide](doc/manual.md): every page with pictures, the grid, MIDI, saving and
  troubleshooting.
- [Every key and knob](doc/controls.md), generated from the code.
- [The plugin](ugen/README.md): what is in it, how it installs and how to build it.
- [An Octatrack as a controller](doc/octatrack-midi.md).
- [MIDI maps](data/README.md) that ship with four.
- [Visuals](visuals/README.md): live visuals in a browser that follow four over OSC.
- [All documents](doc/README.md), including the notes for developers.

## Status and known limits

four is in public beta. It is built, measured and played on one norns: a shield with a
Raspberry Pi 4 and the 32-bit norns system.

- The plugin in this repo is built for that system. It is made to load on other norns too
  (the original norns, a shield on a Raspberry Pi 3, or a norns with a 64-bit kernel), but
  nobody tried it there yet. Where it does not fit, four plays its stock voices.
- SuperCollider gets one processor core on a norns, and the sound drops out above about
  60% load. Four CLOUD tracks take about 30%, or 40% in SPECTRAL mode. Four PV tracks
  pitched up come close to the limit. A track set to OFF costs nothing, but a CLOUD track
  keeps working in silence, so set the tracks you do not use to OFF.

Known issues in this beta:

- Changing an effect's type gives a short dip in the sound.
- A take that runs past the end of its 60-second buffer becomes a full 60-second loop,
  with silence in it. Move its start and end on TAKE with E2 and E3.
- The densest set tried so far went past the CPU limit.

If something does not work, please open an
[issue on GitHub](https://github.com/Alejo-end/four/issues).

## Credits and license

four is free software under the [GNU General Public License v3](LICENSE). You can use it,
change it and share it.

CLOUD is Mutable Instruments Clouds by Emilie Gillet (MIT license), as Volker Böhm ported
it to SuperCollider in mi-UGens (GPL v3). The copied code and its notices are in
[ugen/vendor](ugen/vendor/README.md).
