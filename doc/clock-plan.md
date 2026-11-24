# four: the clock, the record head and the input (plan of 2026-11-21)

STATE (2026-11-24): changes 67 to 70 are built and on the device (`count: 199`).
Stage 21 was measured there. It found that a head sync clicked, and the
seventy-first change fixed it. Nobody has heard any of it. Next: rows 21.1,
21.4 and 21.7 by ear.

This plan answers items 31 to 35 of doc/ux-feedback.md, the user's notes of
2026-11-21. It is the order of work for the sixty-seventh to the seventieth
change. Read CLAUDE.md first: the deploy ritual, the hard rules and the lessons.

The user's words, in short: a motion pass must start at the first move. The
tempo must be visible, settable and able to follow MIDI clock. The loops of the
tracks must fit each other on the clock. The record head must be visible, and
aligned with the play head by default. The path of the input must be explained.

## What the code does today

- Motion: the sixtieth change already cuts the wait before the first move of a
  first pass, and a double tap of K1 arms from any page. Nothing to build. The
  manual says it more plainly (change 70).
- The clock is the norns system clock: PARAMS > CLOCK holds the tempo and the
  source (internal, MIDI, link, crow). No page of four shows the tempo.
- `win_beats` sets the focused track's window to a whole number of beats, and
  `motion_bars` sets a pass's length in bars. Nothing puts a start on a bar line:
  a take starts at the press, a read head runs free, and a motion loop starts at
  its close. Two loops of one bar drift apart.
- An overdub writes where the one write head stopped. That place has nothing to
  do with the place the focused track plays.
- The input reaches the output by two paths: the norns MONITOR (outside any
  script) and four's `dry_wet` (0.5 at the start, with no filter, effect or send
  on it). Both together play the input twice, 6 ms apart.

## Change 67: the engine (count 198 to 199, a RESTART)

1. ALIGNED OVERDUB. `rec_track`'s second argument gets a third value: 0 goes on
   from the write head, 1 opens a new take at 0 (as now), 2 is an aligned
   overdub. For 2, io stops its own write for the pass (`dub`). A small synth
   `\four_dub` writes instead, after io, while `rec` is up. It reads io's record
   signal from a bus. It starts where the track's read head is, one block
   ahead. It reads that place from the track's phase bus on the server, at its
   first block. It loops inside the track's window, on the read head's law
   (winBounds, frames, the two-part start). It frees itself 10 ms after `rec`
   falls. So nothing writes the buffer while no pass runs: a parked writer can
   put one old sample back into a clear or a file. A STOP releases it, and START
   makes a new one at the read head. The window, `rec_level`, `pre_level` and
   `freeze` reach it while it lives. Its place goes out on the `rec_phase` poll
   (ReplaceOut after io). An old engine reads 2 as 1. So if the engine has
   `head_sync` (below), the script sends 2.
2. `head_sync` ("i", the track 1 to 4): the track's read head goes to its
   window's start, on the server. Each drone def takes a plain control `sync`,
   and its step (HPZ1) resets the two Phasors of winRead. A new drone is made
   with the current count, so it does not jump at its start. This is the one new
   command: `count: 199`.
3. Proof offline: test/dsp/check_dsp.sh (count 199, the UGen counts), and a
   probe that renders an aligned overdub and a head sync and reads where they
   land. On the device: the deploy ritual, then gate rows (change 70).

## Change 68: the record head (Lua)

1. `rec_align` (PARAMS > take - record: ALIGN or FREE, ALIGN at the start). An
   overdub (overdub above 0) with ALIGN sends `rec_track(n, 2)`. A new take is
   unchanged.
2. At its stop, an aligned pass leaves the window as it is. It never counts as
   a wrap, and it never ends a ONE-SHOT track. Its seconds count by the frame.
3. While no pass runs, TAKE shows where the next pass writes: a small mark
   under the wave. For a new take, the mark is at the buffer's start. For an
   aligned overdub, it is at the play head. For a free overdub, it is at the
   write head.

## Change 69: the clock (Lua)

1. `ctx.beats()`: the clock's beats (`clock.get_beats`), and in the offscreen
   norns a count from the frames.
2. LOCKED TRACKS. If the window lock (`win_beats`) or a take on the clock sets
   a track's window to a whole number of beats, the track is locked. The lock
   remembers the beats and the tempo. A tempo change sets the window's length
   again on every locked track (it was the focused track only). A window whose
   length a hand, a scene or SNAP changed is not locked after that.
3. LOOP SYNC (`loop_sync`, ON at the start). One clock coroutine wakes on every
   beat. A locked track whose length is L beats gets `head_sync` on every beat
   that is a multiple of L. So all locked tracks start together on the bar, and
   a loop that drifted is put back each time round.
4. TAKES ON THE CLOCK (`rec_sync`: FREE, BEAT or BAR, FREE at the start). A
   new take waits for the next line (`REC ON BAR`). A stop also waits for the
   next line (`STOP ON BAR`). So the take is whole beats or bars, recorded to
   the sample. A second press while it waits calls the wait off (start) or stops at
   once (stop). The take's track is then locked. Start on sound does not apply
   to a take on the clock. Overdubs do not wait.
5. MOTION ON THE CLOCK. With PASS in bars, a first pass counts from the bar
   line before its first move, so a move keeps its place in the bar, and it
   closes on the bar. While it plays, each loop's start is put back on the
   clock (with `motion_len` at AUTO).

## Change 70: the screen and the documents (Lua, documents)

1. The tempo: SCENE shows `120 BPM` and the clock's source, and K1+E2 sets the
   tempo (`clock_tempo`). If the source is MIDI or link, it says `TEMPO FROM
   MIDI` and does not move. TAKE shows the tempo while a lock or `rec_sync` is
   on. (MOTION does not show it: its PASS names the bars.)
2. The input: K1 held on MIX shows the two paths of the input, and K1+E2 is
   MONITOR (`monitor_level`, the norns's own), K1+E3 is DRY/WET. The input gain
   (`input_level`) moves to PARAMS > LEVELS, where norns has it.
3. doc/manual.md: the input's paths, the clock (where the tempo is, MIDI clock
   in PARAMS > CLOCK > source, what follows it), the record head and ALIGN, and
   the first move of a motion pass. doc/controls.md regenerated. If a key
   changed, the README too. doc/device-gate.md: rows for the aligned overdub, the head sync, a
   take on the clock and a motion pass on the clock. CLAUDE.md's STATUS and
   doc/changelog.md for each change.

## Order and checks

Engine first (it needs the RESTART), then 68, 69, 70. After each: `lua
test/check.lua` with LUA53, and after 67 `test/dsp/check_dsp.sh`. New tests in
test_control: the classification of the new params, the aligned arm, the
window kept, the lock and its loss, the beat handler (head syncs, a waiting
start and stop), the motion pass's origin. test_screen: the mark under TAKE.

## What only the device can say

- that an aligned overdub lands on the beat it was played on (the round trip of
  the audio adds a few ms, and this plan does not compensate it)
- that a head sync on a loop that has not drifted is not heard, and how loud one
  that drifted is (PLAY's seam fade covers the start, not the jump)
- that the MIDI clock from another device keeps the four tracks in time
