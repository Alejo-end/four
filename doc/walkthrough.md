# The Phase E session: sheets and tools

Phase E of doc/signature-workflow.md (section 6) decides whether four leads with its
loop: record four parts, bend them, keep the sound, fade back to it. People play it, and
this page holds what they need. Print the card for the player and the sheets for the
observer. test/device/session.py measures what the people cannot.

The machine part is done. On 2026-11-20 the current build passed Phase A's rows on the
device: A1 (rows 19.12 and 19.29, no break), A2 (row 19.32, four parts of 20 s, each from
0), A3 (row 19.33, the deepest change -1.4 dB), A4 (row 19.30, no break) and A5 (row 19.34,
still 0.9% of the time). The results are in doc/measurements/2026-11-20/gate.jsonl.

## Before the session

1. Connect a drum machine and a synth to the line input.
2. Open an SSH control session and set `NORNS_CTL` (test/device/norns.py says how). Keep it
   open to the end.
3. Run `python3 test/device/session.py prepare`. It loads a fresh four and checks
   `count: 198`.
4. Use only the supported set: any four voices up to PV at pitch 2.
5. Save only to PSET slot 90.

One person observes and writes. The observer explains nothing until a task ends.

## The card (for the player, and nothing else)

1. E1 all the way left is TAKE. K2 records, K2 stops.
2. Hold K1 and turn E1 for the next track.
3. VOICE, FILTER and EFFECT change the track you are on.
4. E1 all the way right is SCENE. K3 keeps the sound.
5. Hold K1 and turn E3 to fade to the kept sound and back.
6. K1 and K2 together stop everything. Do it again to start.

## Part 1: a first-time player (the observer's sheet)

The player has never seen four, and can know a norns.

| # | Task | Start | End | Wrong presses that cost sound | Help asked |
|---|---|---|---|---|---|
| 1 | Record four parts: drums, a bass line, a chord, a noise | | | | |
| 2 | Change one voice, one filter and one effect, on any tracks | | | | |
| 3 | Keep the sound | | | | |
| 4 | Change two more things | | | | |
| 5 | Fade to the kept sound and back, three times | | | | |
| 6 | Point at the screen: which track records, which tracks play, where is the fade? | | | | |

Before task 5, run `session.py snap`. After task 5, with the fade at 0, run `session.py
home` and write down which knobs the player turned during the fades. After the last task,
run `session.py takes`.

Part 1 passes when all of these are true:

- [ ] Tasks 1 to 5 took 12 minutes or less, with no help.
- [ ] At most two wrong presses cost sound (a STOP, a DRY, a lost take), and the player
      recovered from each without help.
- [ ] At the end all four takes play (`takes`: `all_play` is true). No take was lost or
      replaced by mistake.
- [ ] Back at 0 the fade is home: every id that `home` lists is a knob the hand moved.
- [ ] Task 6 was answered right from the screen alone.
- [ ] The player kept playing after the last task without being asked. For how long: ____

## Part 2: the user, a five-minute set

Free play on the same loop, Relay included. Run `python3 test/device/session.py record 5`
when the set starts. It records the output, reads the scsynth thread every 5 s and scans
the recording for breaks.

Part 2 passes when all of these are true:

- [ ] No break or click heard, and the scan finds no break (`breaks` is empty).
- [ ] The scsynth thread stays under 55% at p95, with no xrun (`passes` is true).
- [ ] "Easy": __ of 5. "Expressive": __ of 5. Both must be 4 or more.
- [ ] One thing to cut: ______________________

## The listening script (the user, one item at a time)

Write each answer here, and copy it to doc/device-gate.md afterwards.

| # | Do | Listen for | Answer |
|---|---|---|---|
| 1 | Fade between two scenes whose effect types differ, slowly across the middle, then rock it there | A click, a gap, or a clean change? The type changes once (above 0.55, back below 0.45) | |
| 2 | Fade a scene with a filter sweep from 200 Hz to 8 kHz | Steps? | |
| 3 | Record a part while the fade is up, then fade home | Does the new take still play, on its own window? | |
| 4 | Fade to a scene with another voice, then K2 to land it | A click at the land? | |
| 5 | K1+K3 (DRY), then K1+K3 again | The same sound as before? | |
| 6 | A full fade in one turn of E3 | Too fast, too slow or right? | |
| 7 | Relay a filtered track into an empty one (TAKE, K1+E3 SOURCE) | Does the copy sound like what you heard? A click where its loop wraps? | |

## The verdict

Phase E passes when Part 1 and Part 2 pass and items 1 to 6 of the listening script are
clean. Only then does four lead with this loop, in the README and in the example presets.
If a first-time player needs help with the fade or loses a take, fix that first. More
features do not come before it.
