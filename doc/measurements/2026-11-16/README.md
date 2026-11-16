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

The numbers say that each voice sounds, not how it sounds. After these runs the user
listened to four on this device and said "it sounds nice".

## The startup install (the thirty-sixth change)

The plugin removed from Extensions again, the thirty-sixth change deployed, one
RESTART. The sclang log said `compile done`, then
`four: installed the FourStretch plugin at startup`. Loading four: `count: 198`,
`four: FourStretch on`, `four: CLOUD is FourCloud`, and no installer message. A second
RESTART logged nothing from four. The voices on a tone take: OFF 10.5%, PLAY 10.5%,
GRAIN 10.7%, WARP 10.7%, PV 12.5%, CLOUD 13.0%, all at -18.8 to -20.9 dB out, no xruns.

## The walkthrough's stage 19, and a bug it found (the fortieth change)

The norns had booted on a stale clock (sclang started at 19:17, the clock then
said 20:26), so the services were restarted before any measurement. Then
`python3 test/device/gate.py 19`. The results are in `gate.jsonl`.

19.21 failed: with `dly_rev` at 1, nothing rang on once track 2 stopped. A probe
on the buses showed that track 2's sends reached `tDlyBus` and `tRevBus`, but
nothing reached the delay or the reverb, and io's `t_dly` read 0. SuperCollider
makes an argument named `t_...` a trigger control, which falls to 0 after one
block, so io read bus 0. Tracks 2 to 4 never reached the delay or the reverb.
The arguments are now `lanes_dly` and `lanes_rev`, and test_control rejects any
engine argument named `t_`, `a_` or `i_`.

Track 2 on a tone take, delay 0.25 s, feedback 0.5, mix 0.8, then track 2 stops:

| Track 2 sends | Before the fix: playing, tail | After: playing, tail |
|---|---|---|
| none | -18.9, -92.5 dB | -18.9, -92.5 dB |
| delay | -18.9, -92.5 dB | -15.5, -30.3 dB |
| delay, and `dly_rev` 1 with reverb mix 0.6 | -18.9, -92.5 dB | -15.8, -31.9 dB |
| reverb | -18.9, -92.5 dB | -19.9, -56.8 dB |

After the fix, 19.21 passes: -92.5 dB with `dly_rev` 0, -47.3 dB with 1.

Two checks misread the device and were fixed in gate.py:

- 19.7 and 19.8 counted four filters. A strip of tracks 2 to 4 pauses while its
  track is OFF, and the node tree does not list the synths of a paused group (the
  same node ids come back when the track plays). Two filters is right there.
- 19.14 compared bands that PLAY does not hold: 884 Hz at -135 and -145 dB. A band
  under -80 dB now counts only when a voice puts sound into it. Then WARP and PV
  differ from PLAY by 0.0 dB.

Still open from the stage:

- 19.12: six TYPE taps over a tone gave breaks at 1.1, 3.4 and 3.9 s. Listen to
  `19.12_type_steps.wav` in `four-device-recordings/2026-11-16`.
- 19.27: the busiest scsynth thread, 60 s each: four PV at pitch 2 56.6%, the
  dense set 64.1% (over the 60% budget), no xruns in either. On 2026-11-13 they
  were 53.0% and 57.3%.
- The JACK log counted 161 xruns this boot, over many restarts and engine loads.
  The heavy states above had none.
- 19.17, the scsynth thread with four tracks at pitch 1: PLAY 10.6%, WARP 12.9%,
  PV 21.3%, GRAIN 13.0%. 19.25, track 2 with both sends open: none 5.6%, delay
  8.4%, reverb 10.8%, both 13.5%.
- 19.15: a grain's first sound comes 3.6 ms after a mode change and 13.0 ms after
  a pad (about 250 ms before the twenty-second change).

The screens: `screens/19.22_REVERB_no_send_settled.png` shows the dim squares
under `NO SEND - TRACKS K1`, and `screens/19.22_REVERB_send_settled.png` the bright
squares with the line from track 2's corner. The text covers the top edge of the
outer square. The first 19.22 shots caught the page name over the picture.

## The frame clock (phase 0, step 7)

Tracks 1 to 3 in PLAY, GRAIN and PLAY, on VOICE, for 60 s, with `redraw` timed
from the REPL:

| Frames | Period mean | p50 | p95 | max | Later than 1.5 periods | redraw p50 | p95 | max |
|---|---|---|---|---|---|---|---|---|
| 901 in 60.00 s | 66.67 ms | 66.85 ms | 67.59 ms | 79.64 ms | 0 | 2.00 ms | 11.45 ms | 14.65 ms |

The frames come at 15 a second, and redraw leaves matron most of each frame. The
sum of `ctx.frame_dt` over the run is 60.07 s, so a FREE modulator keeps its rate.
