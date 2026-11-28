# FourStretch: four's plugin

FourStretch holds the SuperCollider UGens that the stock set cannot give. The
engine uses them when the plugin is on the server. Without it, the engine
builds its stock voices and effects, so four plays either way.

Players do not need to build anything. The repo ships the plugin, and it
installs itself during the SYSTEM > RESTART after `;install`. This page is for
anyone who wants to know what is in it, or to build it.

| UGen | Voice | Method |
|---|---|---|
| `FourPV` | PV | A phase vocoder with locked phases (Laroche and Dolson). Speed and pitch are independent. A held head is a freeze. |
| `FourWarp` | WARP | WSOLA: each grain starts where it continues the last one. |
| `FourRead` | PLAY | A windowed sinc read in place of the cubic. |
| `FourTanh` | every `tanh` of the engine | The same curve to 2e-7, about ten times as fast on the norns. |
| `FourGrain` | GRAIN | The pair of stock `GrainBuf` as one UGen, with the same laws and an exact start place. |
| `FourDelay` | FLANGE, ECHO | A delay with a low-pass and a soft clip in its feedback path. |
| `FourRoom` | the reverb | Four diffusion steps and eight late lines, run a block at a time (`Room::process`). |
| `FourBBD` | the delay | A bucket brigade with its clock, filters and compander. |
| `FourCloud` | CLOUD | Mutable Instruments Clouds, the code of the MiClouds UGen of mi-UGens (`vendor/`). |

At speed 1 and pitch 1 the three stretch voices return the take. PLAY is bit
for bit there, for whole frames. PV and WARP leave a residual under -90 dB
(`test_core.cpp`), which is far below hearing but is not bit for bit.

FourRoom runs `Room::process`, which works a chunk of up to 64 samples at a
time: each of its 40 lines is read and written in one straight run, and on the
norns that takes about half the time of `Room::tick` (2.0% of a core against
4.4% in `bench_core`). `process` gives the same samples as `tick`, bit for bit.
`test_core.cpp` proves it with uneven blocks, with the decay and the colour
moving between blocks, with a line at its longest (96 kHz), and with inputs
that fade into the denormal range. `build_norns.sh` runs the same proof on the
norns, where the vector code turns denormals into 0. Both paths treat an input
under 1e-20 (-400 dB) as 0, so a fading send brings no denormal into the
diffusion. (Cancellation inside the diffusion could still make one in
principle; no signal tried does, and the loss filter's small offset absorbs it
in the late mix.)

## How it installs

The repo ships a binary built on a norns in
`ignore/plugins/<what uname -m prints>/FourStretch.so`. norns compiles
nothing under a folder named `ignore`, so the folder is inert there.

`lib/install_plugin.sh` holds the rule, and two callers run it. The engine
class runs it while sclang starts (`Engine_Four.installPlug`, from
`*initClass`), before sclang boots the server. So the SYSTEM > RESTART that
follows `;install` puts the plugin in place, and the server loads it in the
same start. The log then says
`four: installed the FourStretch plugin at startup`. `lib/mplugin.lua` runs
the script again when four loads, as a fallback, and asks for a restart when
it installs:

| On the norns | What the script does |
|---|---|
| No binary shipped for this machine | Nothing, and says nothing. The stock voices play. |
| A binary shipped, none installed | Copies the `.so` alone into `~/.local/share/SuperCollider/Extensions/FourStretch/`. At four's load it also says `PLUGIN INSTALLED / SYSTEM > RESTART` on the screen and in maiden. |
| The same binary installed | Nothing. |
| A newer shipped binary, other bytes | Replaces the installed one (a copy beside it, then a rename, so a running server keeps the file it has open), and asks for the RESTART. |
| An installed binary newer than the shipped one | Keeps it. |
| A shipped binary for another kind of machine | Nothing: its ELF class and machine must match scsynth's. |

It never writes a class file, and nothing outside `Extensions/FourStretch/`:
an installed mi-UGens stays as it is. The server loads plugins only when it
boots, so a new binary is heard after SYSTEM > RESTART. Until then the engine
keeps to its stock voices: it uses the plugin only when the binary is the one
that was there when sclang started, and says
`four: FourStretch is new since the restart` when it is not.

A Pi with a 64-bit kernel under the 32-bit norns system prints `aarch64`
for `uname -m` and still needs the 32-bit binary. The repo ships the 32-bit
binary under both `armv7l` and `aarch64` (one file to git). The ELF check
keeps it off a server that is really 64-bit.

## Tested on

| System | Status |
|---|---|
| norns shield, Raspberry Pi 4, 32-bit system (`armv7l`) | Built there with g++ 10 on 2026-11-16. Installed by the startup, measured and played. |
| A 64-bit kernel under the 32-bit system (`aarch64`) | Ships the same binary. Not tried yet. |
| Original norns (CM3) or a shield on a Raspberry Pi 3 | Same instruction set, so it is made to load. Not tried yet. |

If the plugin does not load on your norns, four plays its stock voices.
Please report it in a GitHub issue, with the lines that start with `four:`
in maiden's SuperCollider tab.

## Uninstall

To go back to the stock voices, delete
`~/.local/share/SuperCollider/Extensions/FourStretch/` and restart. The next
start installs the shipped plugin again, unless you also delete
`ignore/plugins/` in the script folder.

## Build the binary on the norns

The SuperCollider headers are in `/usr/local/include/SuperCollider`.

1. Deploy the repo (it carries `ugen/`), then on the norns run
   `~/dust/code/four/ugen/build_norns.sh`. It builds the proof and runs it
   (it must print `all passed`), builds the plugin with FFTW, and copies it
   to `~/dust/code/four/ignore/plugins/$(uname -m)/FourStretch.so`.
2. Restart with the engine ritual: the startup installs the new binary.
3. Load four. The SuperCollider log must say
   `four: FourStretch on` and `four: CLOUD is FourCloud`, and the count must
   stay 198.
4. Copy the binary back into the repo on the Mac and commit it:
   `scp we@norns.local:dust/code/four/ignore/plugins/armv7l/FourStretch.so ignore/plugins/armv7l/`
   (with the folder `uname -m` named). The deploy runs `rsync --delete`,
   which removes a binary the Mac does not have.

The build flags, which `build_norns.sh` uses:
`F="-O2 -std=c++17 -mcpu=cortex-a72 -mfpu=neon-fp-armv8 -mfloat-abi=hard -DFOUR_FFTW -Iugen/vendor/eurorack"`,
the proof `g++ $F -o test_core test_core.cpp -lfftw3f`, and the plugin
`g++ $F -fPIC -shared -fvisibility=hidden -I$H/plugin_interface -I$H/common -I$H/server -o FourStretch.so FourStretch.cpp -lfftw3f`
with `H=/usr/local/include/SuperCollider`.

`-DFOUR_FFTW` makes the transforms come from FFTW, the library that
SuperCollider uses on the norns. It has NEON code and is three times as fast
as our own transform there. Without the switch the core uses its own
transform, which is what the Mac build does. Clouds uses its own transform
either way. Do not add `-O3` or `-ffast-math`: both made the code slower on
the Pi.

To install by hand instead: copy `FourStretch.so` alone to
`~/.local/share/SuperCollider/Extensions/FourStretch/`. Never put a class
file there: `lib/FourStretch.sc` is in the script already, and a second copy
of a class hangs every norns script on LOADING. Install the binary BEFORE
you deploy an engine that uses a new UGen, then restart.

## Prove it on the Mac

```sh
clang++ -O2 -std=c++17 -Iugen/vendor/eurorack -o /tmp/test_core ugen/test_core.cpp && /tmp/test_core
clang++ -O2 -std=c++17 -Iugen/vendor/eurorack -o /tmp/bench_core ugen/bench_core.cpp && /tmp/bench_core
ugen/build_mac.sh /tmp/plug
FOUR_PLUGIN_DIR=/tmp/plug test/dsp/check_dsp.sh <work folder outside the repo>
```

The last command compiles the real engine with the UGens, renders every
voice offline (CLOUD in its four modes among them) and gives one verdict.

## FourCloud and MiClouds

FourCloud is MiClouds under its own name. It takes the same inputs in the
same order (`FourCloud.ar([inL, inR], pit, pos, size, dens, tex, drywet,
in_gain, spread, rvb, fb, freeze, mode, lofi, trig)`), so the engine builds
one CLOUD def for either. Rendered offline against a MiClouds built from the
same commit, with the same input, it gives the same samples in all four modes.

The engine takes, in this order: FourCloud when the plugin on the server
holds it, MiClouds when mi-UGens is installed, else the GRAIN granulator. The
SuperCollider log says which: `four: CLOUD is FourCloud`.

What differs from MiClouds: the core comes from the
real-time memory pool (MiClouds took it from the heap on the audio thread); a
failed start or a block size that is not a multiple of 32 gives silence and a
message (MiClouds left the unit without a calc function); one audio input is
read on both sides (MiClouds wrote past it); `add` is applied.

## Cost

Measured on the norns, with four tracks in one voice. On 2026-11-13, as a
share of the audio thread: PV at pitch 1 takes 49%, WARP 39% and PLAY 36%.
Four PV tracks at pitch 2 took 64% that day. That figure is old: on
2026-11-17 the same four tracks took 35.4% without effects, and on 2026-11-20
the supported set (four PV at pitch 2 with every effect on) took 53.6% to
62.2% over four runs, at the 60% limit. On
2026-11-16, as SuperCollider's average load: four CLOUD tracks take 29.1%,
and 38.7% in SPECTRAL. The figures are in `doc/measurements/`.

## Files

- `four_core.h`: the algorithms, with no SuperCollider in them.
- `four_cloud.h`: the Clouds code of `vendor/` in one piece, with no
  SuperCollider in it.
- `vendor/`: Clouds and stmlib, copied unchanged from mi-UGens.
  `vendor/README.md` names the commit and the licenses.
- `test_core.cpp`: the proof of the core, and a smoke test of the Clouds
  core. It must print `all passed`.
- `bench_core.cpp`: the cost of each voice and its worst block.
- `FourStretch.cpp`: the SuperCollider wrapper.
- `build_mac.sh`: builds `FourStretch.scx` for the Mac bench.
- `build_norns.sh`: builds `FourStretch.so` on the norns and puts it in
  `../ignore/plugins/<arch>/`, where four ships it.
- `../lib/FourStretch.sc`: the classes. This is the only copy.
- `../lib/install_plugin.sh`: installs the shipped binary on the norns.
- `../lib/mplugin.lua`: runs that script again when four loads.
- `../ignore/plugins/`: the shipped binaries, one folder for each machine.

Every build needs `-Iugen/vendor/eurorack` (the Clouds files include each
other from that root). The plugin is built with `-fvisibility=hidden`: the
server sees its entry points only, so the Clouds code in it never binds to
the same code in an installed MiClouds.
