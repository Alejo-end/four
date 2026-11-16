# four: the documents

Start with the [README](../README.md). This page lists everything else.

## For players

| Document | What it covers |
|---|---|
| [manual.md](manual.md) | The full guide: every page with pictures, the grid, MIDI, saving and troubleshooting. |
| [controls.md](controls.md) | Every key and encoder on every page. Generated from the code. |
| [octatrack-midi.md](octatrack-midi.md) | An Octatrack as a MIDI controller for four. |
| [../data/README.md](../data/README.md) | The MIDI maps that ship with four. |
| [../ugen/README.md](../ugen/README.md) | The FourStretch plugin: what is in it, how it installs, how to build it. |
| [../visuals/README.md](../visuals/README.md) | Live visuals in a browser that follow four over OSC. |

## For developers

| Document | What it covers |
|---|---|
| [../.claude/CLAUDE.md](../.claude/CLAUDE.md) | The working notes: the state of the test device, the hard rules and the lessons. |
| [plan.md](plan.md) | The next work. |
| [changelog.md](changelog.md) | Every change, oldest first. |
| [device-gate.md](device-gate.md) | The walkthrough on the device, stage by stage. |
| [norns-platform.md](norns-platform.md) | What the norns costs, its budgets and its traps. |
| [measurements/](measurements/) | Dated records from the device. |

The checks run with `lua test/check.lua`. The offline DSP check runs with
`test/dsp/check_dsp.sh`. [CLAUDE.md](../.claude/CLAUDE.md) explains both.

## Design references

These are partly built. Each one says at its top what is built.

- [space-plan.md](space-plan.md): the delay, the room, the sends and their screens.
- [dsp-plan.md](dsp-plan.md): the voices and the effects, worked out from the math.
- [engine-map.md](engine-map.md): why the engine has its shape. It was written for the
  engine of mangler, four's one-track predecessor.
- [signal-flow.svg](signal-flow.svg): the signal flow in one picture.

## History

These are kept for their reasoning. Each one has a note at its top.

- [spec.md](spec.md): mangler's spec.
- [redesign.md](redesign.md): mangler's screen redesign.
- [tracks-plan.md](tracks-plan.md) and [layers.md](layers.md): the decks that became
  tracks, and the layer decks that were removed.
- [workflow-standalone.md](workflow-standalone.md) and
  [workflow-grid.md](workflow-grid.md): mangler's walkthroughs.
- [ux-feedback.md](ux-feedback.md): user feedback from July 2026.
