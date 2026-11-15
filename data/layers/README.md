# Old presets: NOT supported

These ten presets, their scene files and `layers.pmap.example` belong to the old
`layers` build of mangler (the branch `layers`). four does not support them.

- They set the params of the two layer decks (`lay1_*`, `lay2_*`, `layer_sel`,
  `layer_wet`). four removed the decks in its thirteenth change, and norns drops
  those lines without a word. A preset loaded from here plays without the parts the
  decks held.
- norns does not install them. On a script's first run it copies `data/*.pset`, and
  that pattern does not reach this folder.
- The supported presets are the twelve in `data/` (see `data/README.md`). They play
  the old deck parts on tracks 2 and 3.

They stay here until the user decides about them (doc/plan.md, "Decisions for the
user"). `test/test_control.lua` reads them and allows the removed layer ids here and
nowhere else.
