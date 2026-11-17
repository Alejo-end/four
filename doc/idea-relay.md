# Four Relay

## The idea

**Turn four from four places to play loops into four places a sound can travel.**

A player records a sound on one track, transforms it, then captures that result on
another track without stopping the source. The new take becomes a fresh instrument
voice. Repeat the move and a simple recording can travel through a chain of
transformations, with each stage still available for comparison or another pass.

The musical promise is simple: **keep the source; catch what it became.**

## Why this fits four

Four already has much of the foundation: four independent takes, track-to-track
routing, a processed tape source, a full-mix PRINT action, and take undo. Those are
useful ways to move audio around, but the player still has to understand several
separate mechanisms to turn one track into a new take on another.

Relay would give that behavior one clear performance action. It would capture a
selected track into a selected destination, leave the source playing, and make the
result immediately playable on the destination. The idea is not to add another
general-purpose recorder. It is to make resampling between tracks feel like part of
playing the instrument.

## A short performance

1. Record a voice or instrument onto track 1.
2. Make track 1 grainy, pitch-shifted, filtered, or echoed.
3. Choose track 2 as the destination and pass track 1 into it.
4. Track 1 keeps playing. Track 2 captures the transformed sound and begins looping
   the new take.
5. Change track 2, pass it to track 3, and play the original beside the result.

The result should feel like making a copy of a sound by performing it through the
instrument. No file browser, export step, or stop-and-restart sequence should break
the phrase.

## The core gesture

Relay needs only three decisions: **source, destination, and when to capture**.

- **Source:** one track's audible output. The first version should use a single,
  clearly named tap point in the signal path. Prefer the sound after that track's
  voice and processing, so the captured take matches what the player hears.
- **Destination:** one other track. The destination's current take is protected
  until the capture finishes successfully.
- **Timing:** capture immediately or begin at the next loop boundary. A later
  version could add a bar-length capture, but the first version should not need a
  timing setup to work.

At completion, Relay puts the new take on the destination and starts it in the same
way as an ordinary take. The source remains unchanged and keeps playing. The player
can then audition the two, undo the new take, or pass the result onward.

```text
track 1: original take -> voice -> filter / colour / effects -----> keeps playing
                                                                  \
                                                                   \ relay capture
                                                                    v
track 2: previous take (protected) ---------------------------> new take -> loops
```

The route should be a tap, not a feedback loop. A track cannot relay into itself,
and the capture must not include its own destination output. The source and
destination should be visible before recording starts.

## What makes it feel different

The novelty is in the **musical handoff**. The player does not merely print the
master mix or route one track into another while it plays. They deliberately
transform a phrase, capture that transformation as a new take, and keep both
generations available as playable parts.

That creates a natural way to build an arrangement from one performance:

```text
one phrase -> a stretched loop -> a granular texture -> a printed rhythm
```

The stages can drift apart, use different loop windows, or feed the shared space
effects. Four becomes a small performance ecology: each track is both a voice and a
place to develop a sound.

This is not a claim that resampling itself is new. The distinction would be how
quickly and safely the player can do it on four, without a Grid or a computer, while
the source continues to sound.

## The trust contract

Relay is only useful in performance if it is predictable. These rules are part of
the idea, not polish to postpone:

1. **Never destroy the source.** The source track's audio and settings do not change.
2. **Protect the destination until success.** A failed or cancelled pass leaves its
   previous take intact.
3. **Undo returns the old destination take.** The new take is one reversible action.
4. **Keep the phrase intact.** The default capture begins and ends without clicks;
   optional quantization uses a boundary the player can see or hear.
5. **Prevent accidental feedback.** No self-capture, and no hidden capture of the
   destination's own return.
6. **Make state obvious.** The screen names the source and destination and shows
   whether Relay is armed, recording, finishing, or ready to play.
7. **Respect the device.** A relay pass must not cause audio dropouts in a dense but
   supported setup. If the device cannot complete it, fail safely and say why.

## A small first version

Start with one-way, post-processing capture from one track to another:

- Select a source track and a different destination track.
- Start and stop a pass by hand, with optional start-at-loop-boundary behavior.
- Capture the audible stereo output of the source only.
- On success, install the captured audio as the destination take and start playback.
- Keep the source running and make the destination's previous take undoable.
- Refuse self-capture, a busy destination, or a second overlapping pass with a clear
  on-screen message.

Leave crossfades between multiple sources, automatic chains, tempo-based pass
lengths, per-step routing, and automatic feedback out of the first version. They add
choices before the basic handoff has proved itself.

## How to tell if it works

The test is a short device walkthrough, not a feature checklist:

1. Record a recognizable sound on track 1.
2. Add an audible effect to track 1 and relay it to track 2.
3. Confirm track 1 continues unchanged while track 2 records and then loops.
4. Compare the two tracks, then undo track 2 and hear its previous take return.
5. Repeat with a short loop boundary and a long pass.
6. Try STOP, a cancellation, a full destination, and an attempted self-capture.
7. Repeat the densest supported setup and confirm no new xruns or clicks.

Relay earns its place if a first-time player can do the basic pass without help,
understands which take will be replaced, and immediately wants to pass the result
again. If it needs a page of setup or makes people fear losing a take, it is not the
right signature interaction.

## Recommendation

Treat Relay as a design proposal, not a release commitment. First finish four's
existing sound and usability checks. Then prototype the smallest handoff on the
norns and listen to it in an actual performance. Keep it only if the source-to-new-
take transition feels faster and more musical than using the current PRINT and
track-routing tools separately.
