# COLOR, SPACE and modulators per track (mangler2, ninth change)

Device: norns shield, Pi 4. 2026-11-12, after a RESTART of the four services.

- sclang: `compile done`, no errors. maiden: `count: 173`.
- Worst case: all four tracks in GRAIN. Each track has drive 0.5 and crush 0.4 to
  0.5, and tracks 2 to 4 have resonance 0.6 at 3 kHz with a reverb send of 0.5.
  The delay mix is 0.4, the reverb mix 0.4 and shimmer 0.3, with two sends between
  tracks. Four modulators run, one on the cutoff of each track.
- Each modulator moves its own track's knob: `cutoff`, `t2_cutoff`, `t3_cutoff`,
  `t4_cutoff`.
- scsynth thread (`top -H`, 10 samples): 44.5 to 45%. `peakCPU` (whole JACK
  cycle): 48%.
- xruns over 60 s at steady state: 0. One xrun came while the four GRAIN drones and
  the FX synths were spawned within about 2 s.
- For comparison, the same four GRAIN tracks with FX and sends but without COLOR
  (four-tracks.md) took 48%. Drive and crush on every track add no cost that the
  measurement can see.

Nobody has listened yet. Not checked: that the FX sends of tracks 2 to 4
reach the delay and the reverb. That needs ears or a JACK capture.
