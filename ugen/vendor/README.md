# vendor: the Clouds code of FourCloud

`eurorack/` holds the code of Mutable Instruments Clouds and the parts of
stmlib it needs, copied unchanged from mi-UGens by Volker Böhm:

- source: https://github.com/v7b1/mi-UGens, its `eurorack/` folder
- commit: `10f6824f68ad63475f67dfe3fe5016e2d2634f84` (2026-04-10,
  "Merge pull request #23 from dyfer/patch-1")
- files: the sources and headers that its `projects/MiClouds/CMakeLists.txt`
  builds, and the headers they include. Nothing else.

mi-UGens changed the Clouds code for SuperCollider: frames of floats in place
of 16-bit integers, a sample rate that can be set (the module runs at 32 kHz,
the UGen at the server's rate), and a narrower dead zone in the density. Its
comments are marked `vb`. FourCloud builds the same code the same way, so it
sounds the same as MiClouds.

## Licenses

- The Clouds and stmlib code is by Emilie Gillet, under the MIT license. The
  notice is at the top of every file, and in `eurorack/LICENSE.txt` and
  `eurorack/stmlib/LICENSE`. Keep them with the code.
- mi-UGens, and the MiClouds wrapper that `ugen/FourStretch.cpp` follows for
  FourCloud, are by Volker Böhm, under the GNU GPL version 3.
- four is under the GNU GPL version 3 (`LICENSE` at the top of the repo). MIT
  code can be part of a GPL program, so both fit.

## Rules

- Do not edit these files. A fix belongs in `ugen/FourStretch.cpp`, or in a
  new copy from a newer commit with this README updated.
- `ugen/four_cloud.h` includes them in one piece. Every build that includes
  it needs `-I<ugen>/vendor/eurorack`.
- There is no class file here, and there must never be one. The class of
  FourCloud is in `lib/FourStretch.sc`, and its name is not `MiClouds`: a
  second MiClouds class next to an installed mi-UGens would hang every norns
  script on LOADING.
