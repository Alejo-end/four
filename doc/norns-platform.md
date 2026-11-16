# norns as a platform: what the device measurements show

> A reference. The measurements here are from mangler, the one-track instrument before
> four. The platform facts and the traps hold for four. Its costs per track are in
> doc/measurements/2026-11-12/ and 2026-11-13/, and the STATUS block of CLAUDE.md has the
> latest numbers.

This page records how a norns runs mangler, what each part costs, and which
traps the device showed. The numbers are from one device on 2026-11-06. The full
tables are in [measurements/2026-11-06/README.md](measurements/2026-11-06/README.md).
To repeat a measurement, see "How to repeat this".

## The device

| Item | Value |
|---|---|
| Board | Raspberry Pi 4 Model B Rev 1.5, 4 cores at 1.5 GHz, 1.85 GB of usable RAM |
| Kernel | Linux 5.10.92, 32-bit (armv7l), `SMP PREEMPT`, CPU governor `performance` |
| norns | release 260102 |
| JACK | jackdmp 1.9.17 (JACK2): `jackd -R -P 95 -d alsa -r 48000 -n 3 -p 128 -S -s` |
| SuperCollider | scsynth 3.13.0-dev. supernova is not installed |
| Audio period | 128 frames at 48 kHz, which is 2.67 ms for each cycle |

## What runs

Five services run under `norns.target`: `norns-jack`, `norns-crone`,
`norns-sclang`, `norns-matron` and `norns-maiden`. These threads do the work:

| Thread | Priority | What it does |
|---|---|---|
| `jackd` | FIFO 95 | Runs the audio cycle and wakes the clients |
| `crone` (2 audio threads) | FIFO 90 | The mixer client, and the softcut client |
| `scsynth` (audio thread) | FIFO 90 | All engine DSP. It is one thread |
| `sclang` | FIFO 1 | Engine commands and polls, not audio |
| `matron` | normal | Lua: the script, the screen, keys and clocks |

## The JACK routing

```
system:capture  --> crone:input_1/2
crone:output_1/2 --> system:playback
crone:output_3/4 --> softcut:input_1/2     softcut:output_1/2 --> crone:input_3/4
crone:output_5/6 --> SuperCollider:in_1/2  SuperCollider:out_1/2 --> crone:input_5/6
```

Any client that runs under the same user can change these connections with
`jack_connect`. No norns system file must change.

## How to read the CPU numbers

The `avgCPU` and `peakCPU` of a server do not measure that server. Under JACK,
they are `jack_cpu_load` (server/scsynth/SC_Jack.cpp in SuperCollider), which is
the load of the whole audio cycle. Two servers therefore read about the same
number.

This has two results:

- With mangler loaded, the number stays near 17% for any light state. That is
  the floor set by crone and softcut. If a cost stays below the floor, this number
  does not show it. So a 17.4% reading does not mean that the engine uses 17.4%.
- To see one server's own cost, read its audio thread with `top -H`.

An early test on this device used `avgCPU` per server. It reported that two
servers carried 125% with no xruns. That result was false, because the second
server never received its load. `doc/changelog.md` records the correction.

## What mangler costs

The load columns show the JACK load and the scsynth audio thread, in percent.

| State | JACK avg | scsynth thread |
|---|---|---|
| No script | 6.0 | not read |
| mangler loaded, take empty | 17.4 | under 4 |
| PLAY, OFF, WARP or PV | 17.3 to 17.7 | 3.5 to 5.2 |
| GRAIN (MiClouds), density 5 to 200 | 17.5 to 17.6 | 6.0 to 8.7 |
| WARP, overlaps 2 to 16 | 17.3 to 17.4 | 4.5 to 6.0 |
| PLAY with reverb | 23.2 | 17.4 |
| PLAY with reverb and shimmer | 23.7 | 17.9 |
| PLAY with delay, drive, erosion or a held repeat | 17.3 to 17.4 | 4.2 to 5.2 |
| 8, 16 and 32 SLICE pads, no drone | 17.4, 17.5, 20.5 | 6.2, 9.0, 14.7 |
| 8 and 16 GRAIN pads, density 20, size 0.1 | 17.7, 25.8 | 11.4, 19.7 |
| 8 GRAIN pads, density 100, size 0.2 | 52.5 | 45.2 |
| All of it (below) | 50 | 43 |

"All of it" is GRAIN at density 80 and 8 GRAIN pads at the same density. It also
has reverb, shimmer, delay, the filter, drive, the tape and both layers. It ran for 30 minutes
with 0 xruns, about 14.4 frames per second, a top temperature of 59.4 C, and no
throttling. The system stayed about 80% idle.

A voice costs about this much on the scsynth thread:

| Voice | Cost of one voice |
|---|---|
| SLICE | 0.3% |
| GRAIN, density 20, size 0.1 | 1.0% |
| GRAIN, density 100, size 0.2 | 5.2% |

The cost of a GRAIN pad comes from its grains. MiClouds, the GRAIN drone, costs
little at any density. The screen costs little too: no page moved the frame rate
below 13.7 frames per second, and the rate is capped at 15.

## The budget

| Load | Result over 20 s |
|---|---|
| One server, thread at 61%, JACK 67% | 0 xruns |
| One server, thread at 71%, JACK 78% | 4 xruns |

The JACK peak reached 84% at the 61% step, so the usable limit for one server's
thread is about 60%. That limit counts xruns, not what you hear: 4 xruns in 20 s
can pass unnoticed. On 2026-11-16 the user played four at 99% and heard it clean.
The meter of that reading is not recorded. Next time, read the scsynth thread in
`top -H`, the JACK load and the xrun count together, and listen, before treating 60%
as a limit. The whole instrument above uses 43%. That leaves room for
about 17 more default GRAIN voices or about 50 SLICE voices. CPU is therefore not
what keeps mangler from eight-voice sampling. The tables above are from before the 106th
change, and `measurements/2026-11-06/performance-before-fixes.jsonl` keeps them. That
change leaves softcut's rec flag on, so the floor with mangler loaded rose from about 17%
to about 21%. The whole instrument stayed at about 50% JACK load.

## A second scsynth

A second scsynth can run from sclang as its own JACK client. It starts and connects
with no change to a system file. These trials ran with mangler in PLAY and a layer
playing, loaded with sine synths. "Thread" is the load on each server's own thread.

| Each thread | JACK avg | xruns (not pinned) | xruns (pinned to cores 2 and 3) |
|---|---|---|---|
| 20% | 49 to 52 | 0 | 0 |
| 30% | 68 to 69 | 1 | 0 |
| 40% | 93 to 98 | 36 | 71 |
| 50% | 70 to 72 | 0 | 0 |
| 60% | 80 to 82 | 8 | 6 |
| 70% | 94 to 96 | 93 | 72 |

The two servers do not behave as simple parallel threads:

- At 20% to 40% on each, the JACK load is about the sum of the two threads. That
  is what one-after-the-other running looks like.
- At 50% on each, the JACK load is much less than the sum, so they run at the same
  time. That is 103% of one thread with 0 xruns over 20 s.
- Pinning each thread to its own core does not remove the bad step at 40%.

- The good result at 50% does not hold. Over 5 minutes at the same load it gave 66
  xruns, about 13 each minute. One server at 43% gave 0 xruns over 30 minutes.

So a second server is not a dependable gain, and its cause is not known. Do not
build on it. To get more voices, make each voice cheaper first.
A second server also needs its own copy of the take, and its output bypasses the
main server's filter and effects.

## softcut into the engine

`jack_connect softcut:output_1 SuperCollider:in_1` and the same for channel 2 send
the deck mix into the engine input. The test showed the deck at -14.7 dB, the
engine at -92.5 dB before the patch and -14.4 dB after it, with 0 xruns. The script
polls report the patched signal as input. It is one stereo mix of all decks, and it
shares the live input's path into the record head.

## Traps

**A large time jump floods sclang.** A Pi has no battery clock. If sclang starts on
a stale clock and Wi-Fi then corrects the time, its poll tasks try to catch up. On
this device, a 70-day jump gave about 24,000 `/poll/value` messages per second
instead of 105. sclang used about 94% of a core, matron about 90%, and the sclang
REPL did not answer. A restart cures it. After a jump, restart and then measure. A
device of our own needs a battery clock, or must wait for the time sync.

**The last SSH logout deletes the JACK sockets.** If user `we` logs out, systemd's
`RemoveIPC` default empties `/dev/shm`. Running audio continues. New JACK clients,
`jack_lsp` and `jack_connect` then fail with "server is not running". A JACK restart
repairs them. For JACK work, open one SSH session, restart the services, and keep
that session open until you finish.

**A softcut write head does not follow a playing read head.** Softcut advances a
voice's write index only while its rec flag is on (`SubHead::poke` in softcut-lib). A
position change or a loop wrap sets it. So with the flag off, a pass writes at the
last set position, not where the head reads. The cure is the common norns idiom:
leave the flag on, and use rec level 0 and pre level 1 as the gate.

**softcut's rec and pre ramp never lands exactly.** With the flag on and any slew, an
idle voice slowly changes its buffer: up to 23 steps of 24 bits in 30 s on this device.
With a slew of 0, the buffer stays identical sample for sample. A hard punch prints a
step, so `Mdeck` ramps a punch and then sets the slew to 0.

**A WAV file's bytes are not its audio.** libsndfile writes a time stamp in a PEAK
chunk, so two dumps of the same buffer differ. Compare the samples.

**MiClouds has a dead zone in its density.** Its density input is silent near 0.5,
with random grains below it and periodic grains above it. mangler stays below it.

**MiClouds reads its pitch when a grain starts.** A noise on that input gives a pitch
spread per grain.

## How to repeat this

The tools are in `test/device/` and need only the Python standard library:

| Tool | What it does |
|---|---|
| `norns.py` | Talks to the maiden REPLs and SSH. It presses keys and turns encoders, reads the script's private `ctx`, records JACK ports and feeds a test signal |
| `audio.py` | Measures a WAV: level, clipping, breaks in the waveform, band levels, brightness |
| `gate.py` | Runs doc/device-gate.md, stage by stage or check by check |
| `measure.py` | Runs the cost, budget, two-server, patch and soak measurements |
| `report.py` | Writes the dated results page |

Open a session first, because the last logout deletes the JACK sockets. The control
socket path must be short, so start from a short directory. Restart the norns
services after the session opens.

```sh
ssh -M -S ctl we@norns.local 'sleep 21600' &
export NORNS_CTL=$PWD/ctl
python3 test/device/gate.py 2 4:4.10,4.14      # stages, or chosen checks
python3 test/device/measure.py states voices
python3 test/device/report.py 2026-11-06
```

Stage 5 uploads the test files to `dust/audio/mangler_test`. Stages 8, 11, 12 and 15
use those files, so run stage 5 first. Recordings go to
`../mangler-device-recordings/`, outside the repo, because a deploy copies the repo
to the device. `gate.py cleanup` removes the test PSET and stops the signal server.

These numbers can show that a sound is absent, clipped, breaking, louder or darker.
They cannot show that it sounds good.
