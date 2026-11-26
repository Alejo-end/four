# 2026-11-25: proposal A on the norns, before and after

The same run on `main` (4f4012a) and on `proposal-a` (the seventy-fifth change, its plugin
built on the norns), over JACK. Both at `count: 199`, with `four: FourStretch on`.

| Measure | Before | After |
|---|---|---|
| A take of 40 Hz and 200 Hz, the 40 Hz against the 200 Hz | -2.7 dB | 0.0 dB |
| A take with DC 0.1 on it, the mean of the output | 0.00002 | -0.00008 |
| The reverb, in points of the scsynth thread (mean of three) | 4.8 | 5.0 |
| The reverb over a tone, below 20 Hz | -81.1 dB | -81.5 dB |
| Two tracks that send into each other, below 20 Hz (peak) | -33.9 dB (-2.9) | -28.7 dB (-2.9) |
| Regen 0.8 under a resonant low-pass of 120 Hz, below 20 Hz after 125 s | -71.6 dB | -45.1 dB |
| The same, the peak after 45, 85 and 125 s | -8.1, -10.4, -12.2 | -7.3, -8.1, -8.8 |

- Regen keeps more low end and more below 20 Hz. The level still falls, so it does not run away.
- The send ring rose by 5 dB below 20 Hz. Its sends keep their filter, so this comes from the
  takes' own low end. It stays 22 dB under the sound.
- Not tried here: a real-time memory failure and its message. On 2026-11-26 the Mac's scsynth
  printed all three, offline (the seventy-ninth change in doc/changelog.md).
