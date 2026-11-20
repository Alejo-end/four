# Relay: one track's sound becomes another track's take

> Status: a proposal, written 2026-11-17. Built on 2026-11-20 as the fifty-ninth change
> (C13 of doc/signature-workflow.md): TAKE's SOURCE.
> doc/signature-workflow.md adapts it as its change C13, in Phase D.

## The idea

A player records a sound on one track and changes it. Then they capture the result on
another track, and the source does not stop. The new take is a part of its own. Do it
again, and one recording goes through a chain of changes. Each stage stays where it is,
to compare with or to pass on.

The source stays. The new take holds what the source became.

## Why this fits four

four already has most of the parts: four takes, routing from track to track, a processed
tape source, PRINT of the full mix, and the take UNDO. Each one moves audio. But to turn
one track into a new take on another, the player must know several of them.

Relay makes that one action. It captures a chosen track into a chosen destination, leaves
the source playing, and the result plays on the destination at once. It is not one more
recorder. It makes resampling between tracks a part of playing.

## A short performance

1. Record a voice or an instrument onto track 1.
2. Make track 1 grainy, pitch-shifted, filtered or echoed.
3. Choose track 2 as the destination and pass track 1 into it.
4. Track 1 plays on. Track 2 captures the changed sound and loops the new take.
5. Change track 2, pass it to track 3, and play the original beside the result.

The player copies a sound by playing it through the instrument. No file browser, no
export and no stop and restart breaks the phrase.

## The core gesture

Relay needs three decisions: the source, the destination and the moment of capture.

- The source is one track's output, as the player hears it. The first version uses one
  named tap in the signal path, after the track's voice and processing, so the take
  matches what the player hears.
- The destination is one other track. Its take is protected until the capture ends well.
- The timing is at once, or from the next loop boundary. A length in bars can come
  later. The first version needs no timing setup.

At the end, Relay puts the new take on the destination and starts it like any take. The
source does not change and plays on. The player can then compare the two, undo the new
take, or pass the result on.

```text
track 1: original take -> voice -> filter / colour / effects -----> keeps playing
                                                                  \
                                                                   \ relay capture
                                                                    v
track 2: previous take (protected) ---------------------------> new take -> loops
```

The route is a tap, not a feedback loop. A track cannot relay into itself, and the
capture must not hold its own destination's output. The screen shows the source and the
destination before the recording starts.

## What is different

Resampling is not new. Relay adds speed and safety: a player does it on four with no
grid and no computer, while the source plays on. The player changes a phrase, captures
the change as a new take, and keeps both as parts to play.

One performance can grow into an arrangement:

```text
one phrase -> a stretched loop -> a granular texture -> a printed rhythm
```

The stages can drift apart, use different loop windows, and feed the shared delay and
reverb. Each track is a voice, and also a place to work on a sound.

## The trust contract

On stage, a player must be able to predict Relay. These rules are part of the idea.
They are not polish for later.

1. The source is never destroyed. Its audio and its settings do not change.
2. The destination is protected until success. A failed or cancelled pass leaves its
   take as it was.
3. UNDO brings back the destination's old take. The new take is one action, and it can
   be undone.
4. The phrase stays whole. The capture starts and ends without clicks. A quantized
   start uses a boundary that the player can see or hear.
5. No feedback by accident. No track captures itself, and no capture holds the
   destination's own return.
6. The state is plain. The screen names the source and the destination. It says if
   Relay is armed, recording, finishing or ready to play.
7. The device is respected. A pass causes no dropout in a dense supported set. If the
   device cannot finish a pass, the pass fails safely and says why.

## A small first version

One way only, after the processing, from one track to another:

- Select a source track and a different destination track.
- Start and stop a pass by hand. A start at the loop boundary is an option.
- Capture the stereo output of the source only, as it is heard.
- On success, the captured audio becomes the destination's take and plays.
- The source runs on, and the destination's old take can be undone.
- Refuse self-capture, a busy destination and a second pass over the first. Each
  refusal says why on the screen.

Left out of the first version: crossfades between several sources, automatic chains,
pass lengths in tempo, routing by step and automatic feedback. They add choices before
the basic handoff is proven.

## How to tell if it works

The test is a short walkthrough on the device, not a feature list:

1. Record a sound that is easy to recognize on track 1.
2. Add an effect that is easy to hear to track 1, and relay it to track 2.
3. Make sure that track 1 plays on unchanged while track 2 records and then loops.
4. Compare the two tracks. Then undo track 2 and hear its old take come back.
5. Repeat with a short loop boundary and with a long pass.
6. Try STOP, a cancelled pass, a full destination and a self-capture.
7. Repeat on the densest supported set. There must be no new xruns and no clicks.

A first-time player must do the basic pass without help and know which take will be
replaced. If they then want to pass the result on, Relay stays. If Relay needs a page of
setup, or if players fear for a take, it is not the right gesture.

## Recommendation

Relay is a proposal, not a promise for a release. First finish four's open sound and
usability checks. Then build the smallest handoff on the norns and listen to it in a
real performance. If it is not faster and more musical than PRINT and the track routing
used apart, drop it.
