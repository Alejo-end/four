# FourStretch: the UGens of four

Three SuperCollider UGens that the stock set cannot give. The engine uses them
when the binary is on the server and falls back to its stock voices when it is
not, so the instrument plays either way.

| UGen | Voice | Method |
|---|---|---|
| `FourPV` | PV | A phase vocoder with locked phases (Laroche and Dolson). Speed and pitch are independent. A held head is a freeze. |
| `FourWarp` | WARP | WSOLA: each grain starts where it continues the last one. |
| `FourRead` | PLAY | A windowed sinc read in place of the cubic. |
| `FourTanh` | every `tanh` of the engine | The same curve to 2e-7, about ten times as fast on the norns. |
| `FourGrain` | GRAIN | The pair of stock `GrainBuf` as one UGen, with the same laws and an exact start place. |
| `FourDelay` | FLANGE, ECHO | A delay with a low-pass and a soft clip in its feedback path. |

All three return the take sample for sample at speed 1 and pitch 1.

## Files

- `four_core.h`: the algorithms, with no SuperCollider in them.
- `test_core.cpp`: the proof of the core. It must print `all passed`.
- `bench_core.cpp`: the cost of each voice and its worst block.
- `FourStretch.cpp`: the SuperCollider wrapper.
- `build_mac.sh`: builds `FourStretch.scx` for the Mac bench.
- `../lib/FourStretch.sc`: the classes. This is the only copy.

## Prove it on the Mac

```sh
clang++ -O2 -std=c++17 -o /tmp/test_core ugen/test_core.cpp && /tmp/test_core
ugen/build_mac.sh /tmp/plug
FOUR_PLUGIN_DIR=/tmp/plug test/dsp/run_engine.sh <work folder> ours
python test/dsp/an_engine.py <work folder> ours
```

The last two commands compile the real engine with the UGens and measure it.

## Install on the norns

These steps ran on 2026-11-13. The results are in
`doc/measurements/2026-11-13/fourstretch.md`.

1. Copy `ugen/` to a build folder on the norns, for example `~/fourbuild`.
   The SuperCollider headers are in `/usr/local/include/SuperCollider`.
2. Build and run the proof there. It must print `all passed`:
   `g++ $F -o test_core test_core.cpp -lfftw3f && ./test_core`
   with `F="-O2 -std=c++17 -mcpu=cortex-a72 -mfpu=neon-fp-armv8 -mfloat-abi=hard -DFOUR_FFTW"`.
3. Build the plugin, with `H=/usr/local/include/SuperCollider`:
   `g++ $F -fPIC -shared -I$H/plugin_interface -I$H/common -I$H/server -o FourStretch.so FourStretch.cpp -lfftw3f`
4. Copy `FourStretch.so` to
   `~/.local/share/SuperCollider/Extensions/FourStretch/`. Copy the binary
   only. Do not put a class file there: `lib/FourStretch.sc` is in the script
   already, and a second copy of a class hangs every norns script on LOADING.
   Install the binary BEFORE you deploy an engine that uses a new UGen. A
   class file with an older binary gives `UGen not installed`, and the
   engine makes no sound.
5. Restart with the engine ritual. The SuperCollider log must say
   `four: FourStretch on`, and the count must stay 197.

`-DFOUR_FFTW` makes the transforms come from FFTW, the library that
SuperCollider uses on the norns. It has NEON code and is three times as fast
as our own transform there. Without the switch the core uses its own
transform, which is what the Mac build does. Do not add `-O3` or
`-ffast-math`: both made the code slower on the Pi.

Measured cost with four tracks in one voice: PV at pitch 1 takes 49% of the
audio thread, WARP 39% and PLAY 36%. Four PV tracks at pitch 2 take 64%,
which is over the 60% budget.

To go back to the stock voices, delete the `FourStretch` folder and restart.
