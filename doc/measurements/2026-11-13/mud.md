# Is the script dull? (2026-11-13)

Device: norns shield, Pi 4. White noise from a second scsynth into `crone:input_1/2`,
recorded as a take, then played by each voice with every knob at its default
(cutoff 20 kHz, no drive, no effect, dry/wet at wet). 5 s captures, compared with the
source in third-octave bands. Values are dB against the source, set to 0 at 800 Hz.

| Path | 100 Hz | 400 Hz | 1.6 kHz | 5 kHz | 10 kHz | 16 kHz | 19 kHz |
|---|---|---|---|---|---|---|---|
| Monitor (input to output) | -0.1 | +0.6 | +0.4 | 0.0 | 0.0 | +0.1 | +0.1 |
| PLAY | -1.3 | +0.1 | +0.2 | -0.2 | 0.0 | 0.0 | -0.1 |
| PV | -0.6 | -0.1 | +0.1 | -0.2 | 0.0 | -0.1 | -0.1 |
| WARP | -0.5 | -0.2 | +0.1 | -0.2 | 0.0 | -0.1 | -0.1 |
| GRAIN | -0.5 | -0.1 | +0.2 | -0.2 | -0.4 | -1.6 | -2.4 |

The bands under 200 Hz hold few points, so they are good to about 1 dB.

Result: one track is flat. PLAY, PV and WARP lose nothing up to 19 kHz. GRAIN loses
2.4 dB at 19 kHz. The script does not filter the sound dull.

## The level

One PLAY track leaves the engine 6.9 dB louder than the input that made the take.
The master limiter sits at 0.92 inside the engine, after that gain.

Preset 1, tracks switched to PLAY one after the other, 8 s of `SuperCollider:out_1`:

| Tracks | RMS | Peak | Crest | Samples above 0.85 |
|---|---|---|---|---|
| 1 | -13.4 dBFS | -1.8 dBFS | 11.6 dB | 0.00% |
| 2 | -10.4 | -0.7 | 9.7 | 0.35% |
| 3 | -7.5 | -0.7 | 6.8 | 2.69% |
| 4 | -8.5 | -0.7 | 7.8 | 1.62% |

One track just clears the limiter. With three or four tracks the limiter holds the
peaks down by about 4 to 6 dB all the time. Its lookahead is 3 ms, so it follows the
waveform of the bass and bends everything else with it. That is the likely source of
the muddy sound with four tracks. It is a level problem, not a filter problem.

## The cause and the repair (four, tenth change)

The 7 dB came from the filter. DFM1 at input gain 0.5 passes a 1 kHz tone 1.0 dB
louder than it came in (low-pass and high-pass, any cutoff). The engine then doubled
it. The makeup is now 0.891 (-1.0 dB).

White noise, one PLAY track: engine in -24.7 dBFS, engine out -24.7 dBFS.

Preset 1 after the repair:

| Tracks | RMS | Peak | Crest | Samples above 0.85 |
|---|---|---|---|---|
| 1 | -20.1 dBFS | -8.7 dBFS | 11.4 dB | 0.00% |
| 2 | -17.3 | -5.5 | 11.8 | 0.00% |
| 3 | -13.9 | -3.0 | 10.9 | 0.00% |
| 4 | -14.8 | -2.7 | 12.1 | 0.00% |

Four tracks keep the crest factor of one, and the limiter does not act.
