# 2026-11-24: stage 21, and what a preset load costs

Stage 21: gate.jsonl and screens/ (the seventy-first change in doc/changelog.md).

Preset loads, with `test/device/preset_load.py`: preset_load_warm.jsonl (the files were
in memory after their first load) and preset_load_cold.jsonl (the memory was emptied
before each load, so the files came from the card). Slots 1 to 12 were read, and their
checksum was the same before and after. `lua_ms` in the warm file is wrong in places: it
read a log line. The cold file is right.

| Case | Warm | Cold |
|---|---|---|
| 12 presets in a row, round 1 (the output was recorded too) | 3 xruns in 12 loads | 4 in 12 |
| the same, rounds 2 and 3 (no recording) | 0 in 24 | 0 in 24 |
| preset 6 in parts over itself: the parameters, the files, one file | 0 in 9 | 0 in 9 |
| preset 6 over four PV tracks (scsynth 32%) | 3, 1, 1 | 1, 2, 1 |
| 30 s of playing with no load | 0 | 0 |

- Over four PV tracks, each of the six loads had an xrun 0.04 to 0.06 s after it started.
  Reading the files cannot explain them: the files alone had none, even from the card.
- The first round's xruns are likely from the recording, not from the load. One of the
  three in the first warm PV load came 1.9 s before its load.
- crone logged no seek error in any load. The main Lua thread was held for about 100 ms
  by a whole load from the card.
- The cause over four PV tracks is not isolated. Each of the four tracks changes voice in
  that load, and the crossfade of one track at a time is meant to spread that cost.
