# 2026-11-16: the plugin installs itself, and what CLOUD costs

The norns shield on a Pi 4 (armv7l), with the `fourcloud` branch (the thirty-fifth
change) deployed by rsync. CPU is `Crone.server.avgCPU`, the load of the whole JACK
cycle, averaged over 6 s.

## The install, as a new user meets it

1. `ugen/build_norns.sh` on the norns: the proof printed `all passed`, and the plugin
   went to `ignore/plugins/armv7l/FourStretch.so` (145800 bytes, g++ 10).
2. The plugin of 2026-11-13 moved out of `Extensions/FourStretch/` (kept in
   `~/fourstretch-backup/`), then a RESTART.
3. Load four: `count: 198`, `four: FourStretch absent, WARP and PV are the stock voices`,
   `four: CLOUD is MiClouds` (mi-UGens is installed on this norns), and
   `four: installed the FourStretch plugin for armv7l into ... Do SYSTEM > RESTART to
   hear it.` The installed file has the shipped one's bytes.
4. RESTART, load four: `count: 198`, `four: FourStretch on`, `four: CLOUD is FourCloud`.
   No installer message. No error in the SuperCollider log.

## Each voice on a tone take (track 1)

| Voice | CPU avg | peak | Out | xruns |
|---|---|---|---|---|
| OFF | 10.4% | 10.9% | -92.5 dB | 0 |
| PLAY | 10.5% | 10.8% | -18.8 dB | 0 |
| GRAIN | 10.7% | 11.1% | -20.6 dB | 0 |
| WARP | 10.7% | 11.7% | -18.8 dB | 0 |
| PV | 12.4% | 12.9% | -18.8 dB | 0 |
| CLOUD | 13.1% | 13.5% | -19.0 dB | 0 |

## CLOUD, the delay and silence

| State | CPU avg | peak | xruns |
|---|---|---|---|
| All tracks OFF | 9.8% | 10.0% | 0 |
| Track 1 PLAY | 9.9% | 10.2% | 0 |
| Track 1 CLOUD, granular | 12.2% | 12.7% | 0 |
| Four CLOUD, granular (tracks 2 to 4 empty) | 29.1% | 29.8% | 0 |
| Four CLOUD, spectral | 38.7% | 39.4% | 0 |
| Track 1 PLAY and the delay (send 1, mix 0.4) | 11.3% | 12.1% | 0 |
| The delay on, 20 s after the sound stopped | 10.5% | 11.0% | 0 |

A second run, one track at a time: all OFF 9.7%, track 1 CLOUD (tone) 12.2%, track 2
CLOUD (empty take) 13.6%, track 2 PLAY (empty) 10.1%, tracks 1 and 2 CLOUD 17.7%. A
CLOUD track in silence costs 3.9% against 2.5% for one that sounds, and two cost more
than the sum of one each. The cause is not known: denormals in Clouds' feedback paths,
or the cache with several Clouds buffers. Four in SPECTRAL stays well under the 60% where
the scsynth thread xruns.

Nobody listened. The numbers say that each voice sounds, not how it sounds.

## The startup install (the thirty-sixth change)

The plugin removed from Extensions again, the thirty-sixth change deployed, one
RESTART. The sclang log said `compile done`, then
`four: installed the FourStretch plugin at startup`. Loading four: `count: 198`,
`four: FourStretch on`, `four: CLOUD is FourCloud`, and no installer message. A second
RESTART logged nothing from four. The voices on a tone take: OFF 10.5%, PLAY 10.5%,
GRAIN 10.7%, WARP 10.7%, PV 12.5%, CLOUD 13.0%, all at -18.8 to -20.9 dB out, no xruns.
