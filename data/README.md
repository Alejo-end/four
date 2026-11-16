# data

On its first run, norns copies the `.pset` files of this folder into
`~/dust/data/four/`. four ships no presets for now. Example presets built on freely
usable sounds are planned.

The folder holds two MIDI maps. Neither one is installed by itself.

| File | What it maps |
|---|---|
| `four.pmap.example` | CC 100 on channel 1 to the master STOP. |
| `octatrack.pmap` | An Octatrack on MIDI channel 16 as a controller. See [doc/octatrack-midi.md](../doc/octatrack-midi.md). |

To use one, copy it to `~/dust/data/four/four.pmap` on the norns and load four again. It
replaces any MIDI mapping that you made in PARAMS with MIDI learn.

A preset or a map names parameters by their id. When a parameter is renamed or removed, a
line that names it does nothing, and norns says nothing. `lua test/test_control.lua`
checks that every id in this folder still exists.
