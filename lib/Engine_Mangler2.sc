// Engine_Mangler2.sc — THE ONLY engine file for the `mangler2` norns script.
//
// mangler2 is mangler with FOUR engine tracks. Tracks 2 to 4 are more drones
// (any mode) on the same take, each with its own window, pitch, grain knobs,
// its own filter (\mangler2_strip) and its own level. They join track 1
// after io's filter, so the delay and reverb are shared. Their commands
// are the drone's own names with a `t2_`, `t3_` or `t4_` prefix, plus the
// strip's level, cutoff, resonance and filt_type, and the mode: 26 a track.
// COLOR AND SPACE (the S-4's devices after the filter): every track has its
// own drive and crush (sample rate and bit reduction), and its own send
// amount into the shared delay (fx_dly) and reverb (fx_rev). Both sends
// default to 1, which is the sound from before they existed. Track 1's
// are io's `drive`, `crush`, `fx_dly`, `fx_rev`; the others' are four more
// strip keys, so 30 a track.
// ROUTING (the S-4's sends): `send_<from>_<to>` sends one track's filtered
// output into another track's filter, 12 sends in all. A send arrives one
// block late (InFeedback) and goes through a tanh, so a ring of sends can
// feed back but never runs away. OWN MATERIAL: each track plays its own
// 60s buffer pair; rec_track picks the pair io records into, buf_track the
// pair the buffer commands use. Count: 66 + 3 (crush, fx_dly, fx_rev)
// + 3 x 30 + 12 + 2 = 173.
//
// HARD RULE: exactly one `Engine_Mangler2` class under dust/code (and mangler's `Engine_Mangler` is a different class). A duplicate
// hangs every norns script forever on "LOADING".
//
// Architecture: one persistent `io` synth (input, record head, dry/wet mix,
// resample/regen feedback, FILTER, output) + ONE `mode` drone at a time
// (OFF/GRAIN/WARP/PV/PLAY/CLOUD, spawned/freed by setMode) + a polyphonic voice layer
// + TWO spawn/free FX synths: the delay (updateDelay — alive while delay_mix
// > 0 or the feedback is a near-infinite hold) and the reverb (updateReverb,
// only while rev_mix > 0) + the spawn/free erosion head (updateErode, only
// while erode > 0 in PLAY) + the spawn/release beat repeat (updateRepeat,
// only while the `beat_repeat` command holds a length > 0, placed after io on the
// output bus). Drone and voices Out.ar additively onto play_bus;
// io reads it. Plugin UGens (JPverb, MiClouds, DFM1) are guarded via .asClass
// -> stock fallback so a missing plugin never bricks the load.
//
// DEVICE NOTES: context.in_b is an ARRAY of two mono busses, out_b one stereo
// bus. SC errors land in maiden's SC tab, not matron. Editing this file needs
// SYSTEM > RESTART (sclang recompiles at startup); confirm the command count in
// the load log after.

Engine_Mangler2 : CroneEngine {
    var <ioSynth, <playSynth;
    var <playGroup;
    var <bufL, <bufR;
    // OWN MATERIAL PER TRACK (the S-4 way): four buffer pairs, one per track.
    // bufL/bufR are track 1's. recIdx is the pair io records into (rec_track),
    // opIdx the pair clear, read_file, write_take, read_take and the pad
    // voices act on (buf_track); the Lua side sets both to the focused track
    // and moves opIdx alone to save or restore the other tracks.
    var <bufLs, <bufRs, <recIdx = 0, <opIdx = 0;
    var <grainEnv1, <grainEnv2;
    var <playBus;
    var <phaseBus, <recPhaseBus, <recAmpBus;
    var <playParams;
    var <ioKeys;
    // reverb+shimmer spawn/free synth: freed at rev_mix==0. send/return busses
    // + last-known reverb params (handed over when the synth is spawned).
    var <revSynth, <revSendBus, <revRetBus, <revParams, <revMixV;
    // delay spawn/free synth, same shape: its regeneration loop lives inside
    // it, so freeing it is what flushes the line (which is what \clear wants)
    var <delaySynth, <dlySendBus, <dlyRetBus, <delayParams;
    // erosion spawn/free synth, alive only while erode > 0 in PLAY mode (so
    // at rest nothing writes the take). it reads eroKeys out of playParams;
    // modeV is the mode setMode last switched to (4 = PLAY).
    var <eroSynth, <eroKeys, <modeV;
    // beat repeat spawn/release synth, alive only while held. THREE capture
    // buffers, used in turn: a repeat re-struck while the last one (or two,
    // on a fast spin of the division) fades out captures into one that no
    // fading synth still reads.
    var <repSynth, <repBufs, <repIdx;
    // polyphonic voice layer
    var <activeVoices, <voiceOrder, <voiceParams, <maxVoices;
    // true when the MiClouds def compiled (mi-UGens present): CLOUD mode
    // then uses the Clouds voice, else the GRAIN granulator
    var <hasClouds;
    // tracks 2 to 4: one Event each (keys n, synth, params, strip,
    // stripParams, bus, phase), the shared return they all add into, and the
    // four tracks' post-filter outputs the sends read (outBuses[0] = track 1)
    var <extra, <tRetBus, <outBuses, <stripKeys;
    // what tracks 2 to 4 send into the delay and the reverb (fx_dly, fx_rev),
    // added by io to track 1's own sends
    var <tDlyBus, <tRevBus;
    // the send levels, sendV[from][to] (1-based), for updateStrip
    var <sendV;

    *new { arg context, doneCallback;
        ^super.new(context, doneCallback);
    }

    // the drone def for mode i (1=GRAIN 2=WARP 3=PV 4=PLAY 5=CLOUD). GRAIN is
    // the granulator that reads the window itself (\mangler2_grain). CLOUD
    // is MiClouds on the playing window (it was GRAIN until mangler2's tenth
    // change), and falls back to the granulator when mi-UGens are absent.
    // PLAY is the clean straight loop.
    droneDef { arg i;
        (i == 4).if({ ^\mangler2_play });
        (i == 5).if({ ^hasClouds.if({ \mangler2_clouds }, { \mangler2_grain }) });
        ^[\mangler2_grain, \mangler2_warp, \mangler2_pv].at(i - 1);
    }

    // an extra track's mode: the same release law as setMode. It shares the
    // take's level, rec and freeze (STOP halts it too), and has no erosion.
    // a strip runs only while its track plays or a send feeds it. Measured
    // on the device: three strips always on cost about 18% of the engine
    // thread with every extra track OFF. The pause waits 100ms, so a
    // drone's 20ms release and the filter's tail are heard to the end.
    updateStrip { arg tr;
        var want = (tr[\mode] ? 0) > 0;
        (1..4).do({ arg from;
            (from != tr[\n]).if({
                ((sendV[from - 1][tr[\n] - 1] ? 0) > 0).if({ want = true });
            });
        });
        want.if({
            tr[\strip].run(true);
        }, {
            SystemClock.sched(0.1, {
                var still = (tr[\mode] ? 0) <= 0;
                (1..4).do({ arg from;
                    (from != tr[\n]).if({
                        ((sendV[from - 1][tr[\n] - 1] ? 0) > 0).if({ still = false });
                    });
                });
                still.if({ tr[\strip].run(false) });
                nil
            });
        });
    }

    setModeN { arg tr, i;
        tr[\synth].notNil.if({
            tr[\synth].set(\gate, 0, \handover, if(i > 0, 1, 0));
            tr[\synth] = nil;
        });
        (i > 0).if({
            tr[\synth] = Synth.new(this.droneDef(i), [
                \buf_l, bufLs[tr[\n] - 1], \buf_r, bufRs[tr[\n] - 1],
                \play_bus, tr[\bus], \phase_out, tr[\phase],
                \grain_env1, grainEnv1, \grain_env2, grainEnv2,
                \level, playParams[\level], \rec, playParams[\rec],
                \freeze, playParams[\freeze],
            ] ++ tr[\params].getPairs, playGroup);
        });
        tr[\mode] = i;
        this.updateStrip(tr);
    }

    setMode { arg i;
        // a RELEASE, not a free: the old drone fades out over 20ms while the
        // new one fades in, so a mode change no longer cuts the wave mid-cycle.
        // The two overlap for 20ms only (the one-scsynth-core budget).
        // `handover` 1 when a new drone follows: the old one then stops
        // writing the phase bus. Into OFF it keeps writing to the end, so
        // the bus holds the last position, as it did before.
        playSynth.notNil.if({
            playSynth.set(\gate, 0, \handover, if(i > 0, 1, 0));
            playSynth = nil;
        });
        modeV = i;
        (i > 0).if({
            playSynth = Synth.new(this.droneDef(i), [
                \buf_l, bufL, \buf_r, bufR,
                \play_bus, playBus, \phase_out, phaseBus,
                \grain_env1, grainEnv1, \grain_env2, grainEnv2,
            ] ++ playParams.getPairs, playGroup);
        });
        this.updateErode;
    }

    // spawn/free the reverb synth on rev_mix. placed AFTER ioSynth (reads io's
    // fresh send this block; io reads the return via InFeedback next block).
    updateReverb { arg mix;
        (mix > 0).if({
            revSynth.isNil.if({
                revSynth = Synth.new(\mangler2_reverb, [
                    \in_bus, revSendBus, \out_bus, revRetBus,
                ] ++ revParams.getPairs, ioSynth, \addAfter);
            });
        }, {
            revSynth.notNil.if({ revSynth.free; revSynth = nil });
        });
    }

    // spawn/free the delay synth: alive while the mix is up, OR while the
    // feedback is a near-infinite hold with the mix down — the dub gesture
    // (INF, then KILL) parks a spinning loop at mix 0 and expects it back on
    // un-KILL; freeing at plain mix 0 would discard exactly that tail. a
    // low-feedback tail dies by itself in a few repeats, so only the high-fb
    // hold is kept alive. (delay_fb arrives CURVED from Lua: 0.9 here is
    // ~0.87 on the knob; the INF throw sends 0.98.) in the DEFAULT state
    // (mix 0, fb ~0.48) the synth is gone and the delay costs nothing.
    updateDelay {
        var want = (delayParams[\delay_mix] > 0) or: { delayParams[\delay_fb] > 0.9 };
        want.if({
            delaySynth.isNil.if({
                delaySynth = Synth.new(\mangler2_delay, [
                    \in_bus, dlySendBus, \out_bus, dlyRetBus,
                ] ++ delayParams.getPairs, ioSynth, \addAfter);
            });
        }, {
            delaySynth.notNil.if({ delaySynth.free; delaySynth = nil });
        });
    }

    // spawn/release the erosion head: alive only while erode > 0 in PLAY.
    // a RELEASE, not a free: the synth fades its write out over 50ms and
    // frees itself, so stopping never prints a step into the take.
    updateErode {
        var args;
        ((modeV == 4) and: { playParams[\erode] > 0 }).if({
            eroSynth.isNil.if({
                args = [\buf_l, bufL, \buf_r, bufR];
                eroKeys.do({ arg k; args = args ++ [k, playParams[k]] });
                eroSynth = Synth.new(\mangler2_erode, args, playGroup, \addToHead);
            });
        }, {
            eroSynth.notNil.if({ eroSynth.set(\gate, 0); eroSynth = nil });
        });
    }

    // spawn/release the beat repeat. A new length (a roll to a shorter
    // division) RE-CAPTURES: the old synth fades out over 10ms while the new
    // one, placed before it, starts from the live output, so the old one's
    // crossfade lands on the new one's sound. len <= 0 releases it.
    updateRepeat { arg len;
        repSynth.notNil.if({ repSynth.set(\gate, 0); repSynth = nil });
        (len > 0).if({
            repIdx = (repIdx + 1) % 3;
            repSynth = Synth.new(\mangler2_repeat, [
                \out, context.out_b.index, \buf, repBufs[repIdx], \len, len.min(2),
            ], ioSynth, \addAfter);
        });
    }

    // ---- voice allocation ---------------------------------------------------
    // shared spawn args: buffers, bus, envelope, and the CURRENT drone grain
    // params so a grain-cloud voice tracks the drone's character.
    voiceArgs { arg pos, pitch, oneShot, amp, len;
        ^[
            \buf_l, bufLs[opIdx], \buf_r, bufRs[opIdx], \play_bus, playBus,
            \note_pos, pos, \note_pitch, pitch,
            // how long the slice IS, as a fraction of the buffer. nil (an old
            // caller) -> 0 -> unbounded, the previous behaviour.
            \note_len, len ? 0,
            \gate, 1, \one_shot, oneShot,
            \amp, amp ? voiceParams[\amp],   // per-note level (nil -> the default)
            \pan, playParams[\pan],          // voices track the drone's pan too
            \atk, voiceParams[\voice_atk], \rel, voiceParams[\voice_rel],
            \grain_env1, grainEnv1, \grain_env2, grainEnv2,
            \size, playParams[\size], \density, playParams[\density],
            \spread, playParams[\spread],
            \grain_jitter, playParams[\grain_jitter],
            \grain_pitch_spread, playParams[\grain_pitch_spread],
            \grain_shape, playParams[\grain_shape]
        ];
    }

    noteOn { arg id, pos, pitch, type, amp, len;
        var def, syn;
        // enforce polyphony cap: release-steal oldest voices until under it.
        // a while (not one steal per press): `voices` can be LOWERED below the
        // held count mid-performance, and a single steal never converges.
        while({ voiceOrder.size >= maxVoices }, {
            var oldId = voiceOrder.removeAt(0);
            var old = activeVoices[oldId];
            old.notNil.if({ old.set(\gate, 0) });
            activeVoices.removeAt(oldId);
        });
        def = (type > 0.5).if({ \mangler2_voice_slice }, { \mangler2_voice_grain });
        syn = Synth.new(def, this.voiceArgs(pos, pitch, 0, amp, len), playGroup);
        activeVoices[id] = syn;
        voiceOrder = voiceOrder.add(id);
    }

    noteOff { arg id;
        var v = activeVoices[id];
        v.notNil.if({
            v.set(\gate, 0);          // release; env doneAction 2 frees it
            activeVoices.removeAt(id);
            voiceOrder.remove(id);
        });
    }

    noteOneShot { arg pos, pitch, type, amp, len;
        var def = (type > 0.5).if({ \mangler2_voice_slice }, { \mangler2_voice_grain });
        // fire-and-forget: internal gate self-terminates, synth self-frees
        Synth.new(def, this.voiceArgs(pos, pitch, 1, amp, len), playGroup);
    }

    alloc {
        var s = context.server;
        var allKeys;
        var winBounds, winRead, drEnv, seam, colour;
        // THE RECORD BUFFER LENGTH. The Lua side mirrors this as ctx.BUF_SECS
        // (it cannot read it off the server) and derives every window edge,
        // pad slice and waveform position from it — change it here and there
        // together, or positions drift with no error anywhere.
        var bufSecs = 60;

        bufLs = Array.fill(4, { Buffer.alloc(s, s.sampleRate * bufSecs, 1) });
        bufRs = Array.fill(4, { Buffer.alloc(s, s.sampleRate * bufSecs, 1) });
        bufL = bufLs[0];
        bufR = bufRs[0];

        // grain envelope buffers. shape 0 uses built-in Hann (envbufnum
        // -1) and never touches these. filled BEFORE the s.sync below so
        // they're ready when the first GRAIN synth spawns.
        grainEnv1 = Buffer.alloc(s, 2048, 1);
        grainEnv2 = Buffer.alloc(s, 2048, 1);
        grainEnv1.loadCollection(Env([0, 1, 0], [0.5, 0.5], \welch).asSignal(2048));
        grainEnv2.loadCollection(Env([0, 1, 0], [0.02, 0.98], [4, -4]).asSignal(2048));

        playBus = Bus.audio(s, 2);
        // reverb + delay send/return busses (each 2ch)
        revSendBus = Bus.audio(s, 2);
        revRetBus = Bus.audio(s, 2);
        dlySendBus = Bus.audio(s, 2);
        dlyRetBus = Bus.audio(s, 2);
        phaseBus = Bus.control(s, 1);
        tRetBus = Bus.audio(s, 2);
        tDlyBus = Bus.audio(s, 2);
        tRevBus = Bus.audio(s, 2);
        outBuses = Array.fill(4, { Bus.audio(s, 2) });
        recPhaseBus = Bus.control(s, 1);
        recAmpBus = Bus.control(s, 1);
        // the beat repeat's three capture buffers: 2s of stereo each (a half
        // note down to 60 BPM), allocated once, never per repeat (2.3 MB)
        repBufs = Array.fill(3, { Buffer.alloc(s, (s.sampleRate * 2).asInteger, 2) });
        repIdx = 0;

        // voice state
        maxVoices = 8;
        activeVoices = Dictionary.new;
        voiceOrder = List.new;
        // headroom: per-voice amp 0.3 so a chord of poly voices summing
        // on play_bus doesn't slam the master limiter.
        voiceParams = Dictionary[\amp -> 0.3, \voice_atk -> 0.005, \voice_rel -> 0.6];

        // last-known drone values, handed to a freshly spawned mode synth
        playParams = Dictionary[
            // level/rec/freeze sit in ioKeys too, so ONE command fans out to
            // both synths (no new command, the fingerprint is unchanged). the
            // drone doesn't apply level to its output — io does — it only needs
            // to know whether the deck is audible, to freeze its read head.
            \level -> 1.0, \rec -> 0, \freeze -> 0,
            \pos_start -> 0.0, \pos_end -> 1.0, \scan -> 1.0, \pos_jitter -> 0.0,
            \size -> 0.1, \density -> 20, \pitch -> 1.0, \spread -> 0.5, \pan -> 0.0,
            \grain_jitter -> 0.0, \grain_pitch_spread -> 0.0, \grain_shape -> 0,
            \warp_window -> 0.25, \warp_overlaps -> 4, \warp_rand -> 0.0, \pv_freeze -> 0,
            // MiClouds granular controls (also passed to the fallback defs,
            // which simply ignore them)
            \clouds_pos -> 0.5, \clouds_tex -> 0.5, \clouds_fb -> 0.0,
            \clouds_mode -> 0, \clouds_lofi -> 0.0,
            // erosion: read by \mangler2_erode (eroKeys below); every drone
            // def takes and ignores them
            \erode -> 0.0, \wear -> 0.5
        ];
        // the playParams the erosion head reads: its window, its two knobs,
        // and the three gates that pause it
        eroKeys = [\pos_start, \pos_end, \erode, \wear, \level, \rec, \freeze];
        // tracks 2 to 4: each owns every playParam but the three it shares
        // with the take (level, rec, freeze) and the erosion pair, and a
        // strip with these four (its commands: `t<n>_level` ...)
        stripKeys = [\level, \cutoff, \resonance, \filt_type,
            \drive, \crush, \fx_dly, \fx_rev];
        extra = [2, 3, 4].collect({ arg n;
            var e = (n: n, bus: Bus.audio(s, 2), phase: Bus.control(s, 1),
                params: Dictionary.new,
                stripParams: Dictionary[\level -> 1.0, \cutoff -> 20000,
                    \resonance -> 0.0, \filt_type -> 0,
                    \drive -> 0.0, \crush -> 0.0, \fx_dly -> 1.0, \fx_rev -> 1.0]);
            playParams.keysValuesDo({ arg k, v;
                [\level, \rec, \freeze, \erode, \wear].includes(k).not.if({
                    e[\params][k] = v;
                });
            });
            e
        });
        // reverb params live in revParams (routed to \mangler2_reverb) and the
        // delay's in delayParams (routed to \mangler2_delay); io keeps the two
        // MIX knobs it needs for its own crossfade/add. (ioKeys U revParams U
        // delayParams) is the original ioKeys -> the command set is unchanged.
        ioKeys = [\level, \rec, \rec_level, \pre_level, \freeze,
            \dry_wet, \resample, \regen, \grain_level,
            \filt_type, \cutoff, \resonance, \drive, \crush,
            \delay_mix, \fx_dly,
            \rev_mix, \fx_rev];
        revParams = Dictionary[
            \rev_size -> 1.0, \rev_decay -> 2.0, \rev_damp -> 0.3, \rev_early -> 0.7,
            \rev_moddepth -> 0.1, \rev_modfreq -> 2.0,
            \rev_low -> 1.0, \rev_mid -> 1.0, \rev_high -> 1.0,
            \rev_lowcut -> 500, \rev_highcut -> 2000,
            \shimmer -> 0.0, \shimmer_pitch -> 12.0, \shimmer_tone -> 4500.0
        ];
        revMixV = 0;
        // delay_mix sits in BOTH ioKeys (io's crossfade) and here (the
        // spawn/free gate + a handover value for a fresh synth's unused arg)
        delayParams = Dictionary[
            \delay_time -> 0.3, \delay_fb -> 0.3, \delay_mix -> 0.0
        ];

        // ---- drone playback defs: ONE runs at a time. all share the full
        // arg set (unused args ignored) so spawn/set stays uniform.
        // winRead = the window-position law, defined ONCE for all five defs
        // (a plain build-time function — each call emits the same UGens
        // inline, so the compiled graphs are unchanged; before this the same
        // 7 lines were copy-pasted five times and had already drifted once).
        // window edges + scan are smoothed: pos_start/pos_end are
        // PERFORMANCE encoders (TAKE E2/E3) and an unsmoothed edge move
        // jumped the read head with a click per detent. pitchMul folds
        // varispeed into the phase rate (only \mangler2_play passes it).
        // `run` is the deck LEVEL (every def passes it): a SILENCED engine
        // deck freezes its read head, so STOP truly halts — the on-screen
        // head stops sweeping and START resumes from the exact spot. this is
        // the same "silent deck = stopped deck" law the erosion and regen
        // write heads already follow, and like them it also engages when the
        // MIX is thrown fully to tape (level lands at exact 0 there too) —
        // a fully-thrown-away deck pauses rather than spinning unheard.
        // winBounds = the window's sorted, smoothed edges as [lo, span],
        // shared by winRead and the erosion head.
        winBounds = { arg pos_start, pos_end;
            var lo, hi, span;
            // AUDIO rate, two-pole: a control-rate lag moved the read head in one
            // step per block, and each step broke the waveform. The device
            // measured a click on every E2 detent over a sustained tone. Lag2
            // starts at zero speed, so an edge move bends the sound briefly
            // instead of kinking it.
            lo = Lag2.ar(K2A.ar(pos_start.min(pos_end)), 0.08);
            hi = Lag2.ar(K2A.ar(pos_start.max(pos_end)), 0.08);
            span = (hi - lo).max(0.001);
            [lo, span];
        };
        // `run` goes through the SAME 50ms Lag io puts on `level`: the head
        // stops only once io's fade is down at -60dB. On the raw level it
        // stopped first, and the fade then played one held sample (a thump).
        // `quiet` 1 (a drone fading out under the next one) stops writing
        // the phase bus, so the screen follows the new drone alone.
        // drEnv is the drone's own 10ms in, 20ms out, which frees it.
        winRead = { arg pos_start, pos_end, scan, buf, phase_out, pitchMul = 1, run = 1, quiet = 0;
            var lo, span, incr, phase, winPos;
            #lo, span = winBounds.(pos_start, pos_end);
            incr = Lag.kr(scan, 0.02) * pitchMul * (Lag.kr(run, 0.05) > 0.001)
                * SampleDur.ir / (BufDur.kr(buf) * span);
            phase = Phasor.ar(0, incr, 0, 1);
            winPos = lo + (phase * span);
            Out.kr(phase_out, A2K.kr(winPos) * (1 - quiet));
            [winPos, phase, span];
        };
        drEnv = { arg gate; EnvGen.kr(Env.asr(0.01, 1, 0.02), gate, doneAction: 2) };
        // the loop seam fade PLAY has always had (~5ms, buffer-time referenced)
        seam = { arg phase, span, buf;
            (phase.min(1 - phase) * span * BufDur.kr(buf) / 0.005).clip(0, 1)
        };

        // GRAIN: the granulator. It reads the track's window itself, the way
        // the S-4's granular device reads its sample. One stream of STEREO
        // grains: each trigger starts a grain in the left buffer and one in
        // the right at the same time, place, length and pitch, so the take
        // keeps its stereo image. (Two independent mono clouds smeared the
        // image, and at spread 0 folded it to mono.)
        //   spread: 0 = left grains left and right grains right (the take as
        //     recorded); 1 = each pair thrown to one random place.
        //   pos_jitter (SPRAY): each grain lands up to that much of the
        //     window away from the head. Every grain is also scattered by at
        //     least a quarter of its own length: grains that all start on
        //     the same sample comb-filter into a buzz at the density.
        //   a grain is CENTRED on its place (it reads half before, half
        //     after), and the whole grain stays inside the window: it never
        //     reads the empty buffer past the take.
        //   pv_freeze holds the head where it is while grains keep coming.
        SynthDef(\mangler2_grain, {
            arg buf_l, buf_r, play_bus, phase_out, rec = 0, freeze = 0,
                pos_start = 0, pos_end = 1, scan = 1, pos_jitter = 0,
                size = 0.1, density = 20, pitch = 1, spread = 0.5, pan = 0,
                grain_jitter = 0, grain_pitch_spread = 0, grain_shape = 0,
                grain_env1 = -1, grain_env2 = -1,
                clouds_pos = 0.5, clouds_tex = 0.5, clouds_fb = 0, clouds_mode = 0,
                clouds_lofi = 0,
                warp_window = 0.25, warp_overlaps = 4, warp_rand = 0, pv_freeze = 0,
                erode = 0, wear = 0.5, level = 1, gate = 1, handover = 0;
            var winPos, phase, span, lo, look, bufDur, trig, dur, pch, readLen;
            var off, pos, r, wid, panL, panR, envSel, comp, sig;
            #winPos, phase, span = winRead.(pos_start, pos_end, scan * (1 - pv_freeze),
                buf_l, phase_out, 1, level, handover);
            lo = winPos - (phase * span);
            bufDur = BufDur.kr(buf_l);
            // while recording, read a quarter second behind the record head
            look = (0.25 / bufDur) * rec * (1 - freeze);
            // the TIMING, AUDIO rate (kr onsets fall on the control block):
            // grain_jitter 0 is a regular stream, and Hann grains at an
            // overlap of 2 or more then add up to a steady level. 1 is
            // Poisson (Dust), the old law: measured on the device at the
            // default size and density, 18% of the sound fell below -50 dB
            // between clumps. In between, the regular stream is thinned and
            // Dust makes up the rest, so the mean rate stays the density.
            // The same knob varies the length. Every per-grain random is ar
            // on the same trigger.
            trig = CoinGate.ar(1 - grain_jitter.clip(0, 1), Impulse.ar(density))
                + Dust.ar(density * grain_jitter.clip(0, 1));
            dur = (size * (1 + TRand.ar(grain_jitter.neg, grain_jitter, trig))).max(0.005);
            // midiratio is already 2^(st/12): no /12 before it
            pch = pitch * TRand.ar(grain_pitch_spread.neg, grain_pitch_spread, trig).midiratio;
            readLen = (dur * pch / bufDur).min(span);
            off = TRand.ar(-1, 1, trig) * ((pos_jitter * span) + (size * 0.25 / bufDur));
            pos = winPos - look + off - (readLen * 0.5);
            pos = lo + (pos - lo).wrap(0, span).clip(0, (span - readLen).max(0));
            r = TRand.ar(spread.neg, spread, trig);
            wid = 1 - spread;
            panL = (pan - wid + r).clip(-1, 1);
            panR = (pan + wid + r).clip(-1, 1);
            envSel = Select.kr(grain_shape.clip(0, 2), [-1, grain_env1, grain_env2]);
            // equal loudness across density x size (boost below unity
            // overlap, up to 2x; attenuate above it as 1/sqrt(overlap), to
            // -18dB at an overlap of 64: capped at 16, a dense cloud measured
            // 4 dB above PLAY on the device),
            // and over spread: a pair thrown to one place sums its two
            // channels, so the top of spread is 3dB down. x0.8: grain
            // pairs overlap coherently, so they peak harder than PLAY; on the
            // device the default cloud came out 1.3 dB above PLAY with the
            // limiter at work in 2% of it, and 9% when dense
            comp = (density * size).clip(0.25, 64).sqrt.reciprocal
                * (1 + spread.squared).sqrt.reciprocal * 0.8;
            sig = (GrainBuf.ar(2, trig, dur, buf_l, pch, pos, 4, panL, envSel)
                + GrainBuf.ar(2, trig, dur, buf_r, pch, pos, 4, panR, envSel)) * comp;
            Out.ar(play_bus, sig * drEnv.(gate));
        }).add;

        SynthDef(\mangler2_warp, {
            arg buf_l, buf_r, play_bus, phase_out, rec = 0, freeze = 0,
                pos_start = 0, pos_end = 1, scan = 1, pos_jitter = 0,
                size = 0.1, density = 20, pitch = 1, spread = 0.5, pan = 0,
                grain_jitter = 0, grain_pitch_spread = 0, grain_shape = 0,
                grain_env1 = -1, grain_env2 = -1,
                clouds_pos = 0.5, clouds_tex = 0.5, clouds_fb = 0, clouds_mode = 0,
                clouds_lofi = 0,
                warp_window = 0.25, warp_overlaps = 4, warp_rand = 0, pv_freeze = 0,
                erode = 0, wear = 0.5, level = 1, gate = 1, handover = 0;
            var winPos, phase, span, ptr, l, r, sig;
            #winPos, phase, span = winRead.(pos_start, pos_end, scan, buf_l, phase_out, 1, level, handover);
            ptr = A2K.kr(winPos);
            l = Warp1.ar(1, buf_l, ptr, pitch, warp_window, -1, warp_overlaps, warp_rand, 4);
            r = Warp1.ar(1, buf_r, ptr, pitch, warp_window, -1, warp_overlaps, warp_rand, 4);
            sig = Balance2.ar(l, r, pan.lag(0.03));
            Out.ar(play_bus, sig * drEnv.(gate));
        }).add;

        SynthDef(\mangler2_pv, {
            arg buf_l, buf_r, play_bus, phase_out, rec = 0, freeze = 0,
                pos_start = 0, pos_end = 1, scan = 1, pos_jitter = 0,
                size = 0.1, density = 20, pitch = 1, spread = 0.5, pan = 0,
                grain_jitter = 0, grain_pitch_spread = 0, grain_shape = 0,
                grain_env1 = -1, grain_env2 = -1,
                clouds_pos = 0.5, clouds_tex = 0.5, clouds_fb = 0, clouds_mode = 0,
                clouds_lofi = 0,
                warp_window = 0.25, warp_overlaps = 4, warp_rand = 0, pv_freeze = 0,
                erode = 0, wear = 0.5, level = 1, gate = 1, handover = 0;
            var winPos, phase, span, sigL, sigR, chainL, chainR, l, r, sig, edge;
            #winPos, phase, span = winRead.(pos_start, pos_end, scan, buf_l, phase_out, 1, level, handover);
            // cubic interp like every other read path — PV magnifies linear-
            // interp images: MagFreeze sustains whatever aliasing lands in the FFT
            // the seam fade before the FFT: a wrap click fed to MagFreeze
            // is held as a steady hiss
            edge = seam.(phase, span, buf_l);
            sigL = BufRd.ar(1, buf_l, winPos * BufFrames.kr(buf_l), 1, 4) * edge;
            sigR = BufRd.ar(1, buf_r, winPos * BufFrames.kr(buf_r), 1, 4) * edge;
            chainL = FFT(LocalBuf(2048), sigL);
            chainR = FFT(LocalBuf(2048), sigR);
            chainL = PV_MagFreeze(chainL, pv_freeze);
            chainR = PV_MagFreeze(chainR, pv_freeze);
            l = IFFT(chainL);
            r = IFFT(chainR);
            sig = Balance2.ar(l, r, pan.lag(0.03));
            Out.ar(play_bus, sig * drEnv.(gate));
        }).add;

        // ---- CLEAN PLAY drone — a straight loop of the window, the EXACT
        // recorded sample (no granulation/stretch/spectral). this is the
        // default mode so a fresh take plays back untouched; GRAIN/WARP/PV are
        // switched on when you want them. scan sets loop speed, pitch resamples
        // it (varispeed, like a sampler/tape). all core UGens — can't brick.
        SynthDef(\mangler2_play, {
            arg buf_l, buf_r, play_bus, phase_out, rec = 0, freeze = 0,
                pos_start = 0, pos_end = 1, scan = 1, pos_jitter = 0,
                size = 0.1, density = 20, pitch = 1, spread = 0.5, pan = 0,
                grain_jitter = 0, grain_pitch_spread = 0, grain_shape = 0,
                grain_env1 = -1, grain_env2 = -1,
                clouds_pos = 0.5, clouds_tex = 0.5, clouds_fb = 0, clouds_mode = 0,
                clouds_lofi = 0,
                warp_window = 0.25, warp_overlaps = 4, warp_rand = 0, pv_freeze = 0,
                erode = 0, wear = 0.5, level = 1, gate = 1, handover = 0;
            var winPos, phase, span, sigL, sigR, edge, sig;
            #winPos, phase, span = winRead.(pos_start, pos_end, scan, buf_l, phase_out, pitch.lag(0.05), level, handover);
            sigL = BufRd.ar(1, buf_l, winPos * BufFrames.kr(buf_l), 1, 4);
            sigR = BufRd.ar(1, buf_r, winPos * BufFrames.kr(buf_r), 1, 4);
            // ~5ms edge fade at the loop seam (buffer-time referenced, shrinks
            // with rate): the rec-stop window almost never lands on a zero
            // crossing, so the bare loop CLICKED every pass — the one blemish
            // on "the exact recorded sample". the body of the take is untouched.
            edge = seam.(phase, span, buf_l);
            sig = Balance2.ar(sigL, sigR, pan.lag(0.03)) * edge;
            Out.ar(play_bus, sig * drEnv.(gate));
        }).add;

        // ---- EROSION: the window rewriting itself, in its own synth
        // (updateErode spawns it while erode > 0 in PLAY mode). it runs on
        // its OWN head at a constant one pass per window length regardless
        // of playback speed or direction: aging is uniform and predictable,
        // no samples are skipped at high rates, and varispeed does not change
        // the wear character. a NON-interpolating read fetches the exact
        // stored sample and a slightly darkened, slightly quieter copy is
        // written back in its place. manual rec and freeze pause the head,
        // and so does a silenced engine deck (STOP / mix thrown fully to tape
        // -> level ~0): a stopped instrument left with erode up would
        // otherwise grind the take away with nobody listening, the same trap
        // the regen head guards against. the head HOLDS its place while
        // paused, so every part of the window ages at the same rate (and the
        // Lua pass counter, which pauses on the same three, stays true). the
        // Lua layer interlocks erode against regen so two free-running write
        // heads never fight over the buffer. `gate` fades the write in and
        // out over 50ms and frees the synth: a write that began or ended at
        // full strength would print a step into the take.
        SynthDef(\mangler2_erode, {
            arg buf_l, buf_r, gate = 1, pos_start = 0, pos_end = 1,
                erode = 0, wear = 0.5, level = 1, rec = 0, freeze = 0;
            var lo, span, run, head, idx, env, eff, wearF, rawL, rawR;
            #lo, span = winBounds.(pos_start, pos_end);
            run = (1 - rec) * (1 - freeze) * (level > 0.001);
            head = Phasor.ar(0, run * SampleDur.ir / (BufDur.kr(buf_l) * span), 0, 1);
            idx = (lo + (head * span)) * BufFrames.kr(buf_l);
            env = EnvGen.kr(Env.asr(0.05, 1, 0.05), gate, doneAction: 2);
            eff = erode.clip(0, 1).lag(0.05) * env * run;
            wearF = wear.clip(0, 1).linexp(0, 1, 9000, 1200);
            rawL = BufRd.ar(1, buf_l, idx, 1, 1);
            rawR = BufRd.ar(1, buf_r, idx, 1, 1);
            BufWr.ar((rawL * (1 - eff)) + (LPF.ar(rawL, wearF) * 0.996 * eff),
                buf_l, idx);
            BufWr.ar((rawR * (1 - eff)) + (LPF.ar(rawR, wearF) * 0.996 * eff),
                buf_r, idx);
        }).add;

        // MiClouds granular drone (mi-UGens), guarded two ways: .asClass (no
        // literal reference) + a try around the def -> falls back to GrainBuf if
        // absent/broken. a BufRd scrubs the window into Clouds; pv_freeze doubles
        // as the clouds freeze.
        hasClouds = false;
        "MiClouds".asSymbol.asClass.notNil.if({
            try {
                var cc = "MiClouds".asSymbol.asClass;
                SynthDef(\mangler2_clouds, {
                    arg buf_l, buf_r, play_bus, phase_out, rec = 0, freeze = 0,
                        pos_start = 0, pos_end = 1, scan = 1, pos_jitter = 0,
                        size = 0.1, density = 20, pitch = 1, spread = 0.5, pan = 0,
                        grain_jitter = 0, grain_pitch_spread = 0, grain_shape = 0,
                        grain_env1 = -1, grain_env2 = -1,
                        clouds_pos = 0.5, clouds_tex = 0.5, clouds_fb = 0,
                        clouds_mode = 0, clouds_lofi = 0,
                        warp_window = 0.25, warp_overlaps = 4, warp_rand = 0,
                        pv_freeze = 0, erode = 0, wear = 0.5, level = 1, gate = 1, handover = 0;
                    var winPos, phase, span, srcL, srcR, sig, dens, edge;
                    #winPos, phase, span = winRead.(pos_start, pos_end, scan, buf_l, phase_out, 1, level, handover);
                    // Clouds' density is silent at 0.5: below it grains are
                    // random, above it periodic. Mapping 1..200 across 0.5 made
                    // density 13 to 16 silent and the default 20 about 20 dB
                    // down. Stay on the random side (the drone's Dust law), and
                    // lift the sparse end by the level the device measured.
                    dens = density.explin(1, 200, 0.36, 0.05);
                    edge = seam.(phase, span, buf_l);
                    srcL = BufRd.ar(1, buf_l, winPos * BufFrames.kr(buf_l), 1, 4) * edge;
                    srcR = BufRd.ar(1, buf_r, winPos * BufFrames.kr(buf_r), 1, 4) * edge;
                    // POSITIONAL args (keyword args don't survive perform on a
                    // var-held class): in, pit, pos, size, dens, tex, drywet,
                    // in_gain, spread, rvb, fb, freeze, mode, lofi. our size/
                    // density/pitch remap to Clouds' 0..1 / semitone ranges.
                    sig = cc.ar([srcL, srcR],
                        // Clouds reads its pitch when a grain starts, so a noise
                        // here is a pitch spread per grain, as in the GrainBuf drone
                        (pitch.max(0.01).log2 * 12) + LFNoise0.kr(density.clip(4, 30), grain_pitch_spread),
                        clouds_pos,
                        size.linlin(0.01, 0.5, 0.1, 0.9),
                        dens,
                        clouds_tex, 1.0, 1.0, spread, 0.0, clouds_fb,
                        pv_freeze, clouds_mode, clouds_lofi);
                    // x0.5: measured on the device, Clouds at the default
                    // density came out 6 dB above PLAY on the same take, so
                    // a mode change jumped in level
                    sig = sig * (((dens - 0.05) / 0.31).squared * 14).dbamp * 0.5;
                    Out.ar(play_bus, sig * drEnv.(gate));
                }).add;
                hasClouds = true;
            } { arg err;
                hasClouds = false;
                ("mangler: MiClouds def failed — using GrainBuf. "
                    ++ err.errorString).postln;
            };
        });

        // ---- polyphonic voices: ONE note each, spawned per press. both
        // defs share the arg set; each frees itself. THE PER-PAD SWITCH is
        // which def the allocator spawns (grain cloud vs clean slice).

        // helper: effective gate. held -> external `gate`; one-shot -> an
        // internal gate held high for `sustain` then released, so the asr
        // env's doneAction:2 frees the synth. env-driven free means sparse
        // grain gaps never premature-free a held voice.
        SynthDef(\mangler2_voice_grain, {
            arg buf_l, buf_r, play_bus,
                gate = 1, one_shot = 0, sustain = 0.05,
                note_pos = 0, note_pitch = 1, amp = 0.5, pan = 0,
                atk = 0.005, rel = 0.6,
                size = 0.1, density = 20, spread = 0.5,
                grain_jitter = 0, grain_pitch_spread = 0, grain_shape = 0,
                grain_env1 = -1, grain_env2 = -1, note_len = 0;
            var trig, dur, pch, off, pos, r, wid, envSel, cloud, eGate, env, sig;
            var comp, bufDur, reach;
            // the drone's laws, one stream of stereo grain pairs: sample
            // accurate onsets (regular to Poisson on grain_jitter), per-grain
            // randoms on the same trigger
            trig = CoinGate.ar(1 - grain_jitter.clip(0, 1), Impulse.ar(density))
                + Dust.ar(density * grain_jitter.clip(0, 1));
            bufDur = BufDur.kr(buf_l);
            dur = (size * (1 + TRand.ar(grain_jitter.neg, grain_jitter, trig))).max(0.005);
            pch = note_pitch * TRand.ar(grain_pitch_spread.neg, grain_pitch_spread, trig).midiratio;
            // SCATTER: grains that all start on the pad's sample comb-filter
            // into a static buzz. Each starts up to half a grain after it,
            // and inside the slice (note_len, a buffer fraction; 0 = no limit)
            reach = (size * 0.5 / bufDur).min(Select.kr(note_len > 0, [1.0, note_len * 0.5]));
            off = TRand.ar(0, 1, trig) * reach;
            pos = (note_pos + off).wrap(0, 1);
            r = TRand.ar(spread.neg, spread, trig);
            wid = 1 - spread;
            envSel = Select.kr(grain_shape.clip(0, 2), [-1, grain_env1, grain_env2]);
            // the drone's loudness law, halved for a chord of pads
            comp = (density * size).clip(0.25, 64).sqrt.reciprocal * 0.5
                * (1 + spread.squared).sqrt.reciprocal;
            cloud = (GrainBuf.ar(2, trig, dur, buf_l, pch, pos, 4, (r - wid).clip(-1, 1), envSel)
                + GrainBuf.ar(2, trig, dur, buf_r, pch, pos, 4, (r + wid).clip(-1, 1), envSel)) * comp;
            eGate = Select.kr(one_shot, [gate, Trig.kr(Impulse.kr(0), sustain)]);
            env = EnvGen.ar(Env.asr(atk, 1, rel), eGate, doneAction: 2);
            sig = Balance2.ar(cloud[0], cloud[1], pan) * env * amp;
            Out.ar(play_bus, sig);
        }).add;

        SynthDef(\mangler2_voice_slice, {
            arg buf_l, buf_r, play_bus,
                gate = 1, one_shot = 0, sustain = 0.05,
                note_pos = 0, note_pitch = 1, amp = 0.5, pan = 0,
                atk = 0.005, rel = 0.6,
                size = 0.1, density = 20, spread = 0.5,
                grain_jitter = 0, grain_pitch_spread = 0, grain_shape = 0,
                grain_env1 = -1, grain_env2 = -1, note_len = 0;
            var l, r, eGate, env, sig, slLen, slDur, slEnv;
            // clean, tight read from the slice point; no loop, no doneAction
            // here (env owns the lifetime)
            l = PlayBuf.ar(1, buf_l, note_pitch * BufRateScale.kr(buf_l), 1,
                note_pos * BufFrames.kr(buf_l), 0, 0);
            r = PlayBuf.ar(1, buf_r, note_pitch * BufRateScale.kr(buf_r), 1,
                note_pos * BufFrames.kr(buf_r), 0, 0);
            // THE SLICE HAS AN END. Given only a start, PlayBuf ran on through
            // the whole 60s buffer — so a pad played its slice and then
            // everything after it, while the PADS page drew eight bounded
            // cells. The picture and the sound disagreed on every held pad.
            // note_len is the slice length as a buffer fraction; 0 (an old
            // caller, or a deliberate "to the end") keeps the previous
            // behaviour. Pitch scales how long the slice takes to play.
            slLen = Select.kr(note_len > 0, [1.0, note_len]);
            slDur = (slLen * BufDur.kr(buf_l) / note_pitch.abs.max(0.01)).clip(0.002, 60);
            // ~3ms out so the boundary closes without a click
            slEnv = EnvGen.kr(Env([1, 1, 0], [(slDur - 0.003).max(0.001), 0.003]));
            eGate = Select.kr(one_shot, [gate, Trig.kr(Impulse.kr(0), sustain)]);
            env = EnvGen.ar(Env.asr(atk, 1, rel), eGate, doneAction: 2);
            sig = Balance2.ar(l, r, pan) * env * amp * slEnv;
            Out.ar(play_bus, sig);
        }).add;

        // ---- track 2's strip: its filter and its level, in playGroup's tail
        // (after the drones, before io). The filter is io's, the same two
        // DFM1s and the same 20ms type crossfade. 2.sqrt is io's Balance2
        // makeup, so the two tracks sit at the same level.
        // COLOR, one law for every track (a build-time function: each def
        // inlines the same UGens). DRIVE is a clean to saturated crossfade,
        // so drive 0 is a true bypass (LINEAR, not equal power: the two arms
        // are the same signal, and XFade2 summed them to a +3dB hump at mid
        // knob). CRUSH holds each sample for longer (the rate falls 32 times
        // at the top) and rounds it to fewer bits (16 down to 4). It fades in
        // over the first tenth of the knob, so crush 0 is a true bypass and
        // the rest of the knob is all crushed.
        colour = { arg sig, drive, crush;
            var pre, xf, rate, steps, cr;
            drive = drive.lag(0.03);
            pre = 1 + (drive * 6);
            sig = LinXFade2.ar(sig, (sig * pre).tanh * pre.sqrt.reciprocal,
                (drive * 2 - 1));
            crush = crush.lag(0.05);
            rate = SampleRate.ir * (0.5 ** (crush * 5));
            steps = 2 ** (16 - (crush * 12));
            cr = (Latch.ar(sig, Impulse.ar(rate)) * steps).round / steps;
            xf = (crush * 10).clip(0, 1);
            LinXFade2.ar(sig, cr, (xf * 2 - 1))
        };

        SynthDef(\mangler2_strip, {
            arg in_bus, out_bus, own_out, level = 1.0, cutoff = 20000,
                resonance = 0, filt_type = 0,
                // COLOR and SPACE: its drive and crush, and how much of it
                // goes into the shared delay and reverb (dly_out, rev_out)
                drive = 0, crush = 0, fx_dly = 1, fx_rev = 1, dly_out = 0, rev_out = 0,
                // the sends INTO this track: snd<m> from track m (its own
                // stays 0), read from ob<m>, a block late
                snd1 = 0, snd2 = 0, snd3 = 0, snd4 = 0,
                ob1 = 0, ob2 = 0, ob3 = 0, ob4 = 0;
            var sig, cf, res, wLp, wHp, wBp, dfmClass, sendIn;
            sendIn = (InFeedback.ar(ob1, 2) * snd1.lag(0.03))
                + (InFeedback.ar(ob2, 2) * snd2.lag(0.03))
                + (InFeedback.ar(ob3, 2) * snd3.lag(0.03))
                + (InFeedback.ar(ob4, 2) * snd4.lag(0.03));
            sig = (In.ar(in_bus, 2) * 2.sqrt) + LeakDC.ar(sendIn).tanh;
            cf = cutoff.clip(20, 20000).lag(0.05);
            res = resonance.lag(0.05);
            wLp = Lag.kr(filt_type < 0.5, 0.02);
            wHp = Lag.kr((filt_type > 0.5) * (filt_type < 1.5), 0.02);
            wBp = Lag.kr(filt_type > 1.5, 0.02);
            dfmClass = "DFM1".asSymbol.asClass;
            sig = dfmClass.notNil.if({
                try {
                    var lp = dfmClass.ar(sig, cf, res.clip(0, 0.9), 0.5, 0, 0) * 2;
                    var hp = dfmClass.ar(sig, cf, res.clip(0, 0.9), 0.5, 1, 0) * 2;
                    (lp * wLp) + (hp * wHp)
                        + (HPF.ar(lp, (cf * 0.5).clip(20, 20000)) * wBp)
                } { |e|
                    var rq = (1 - (res * 0.92)).max(0.05);
                    (RLPF.ar(sig, cf, rq) * wLp) + (RHPF.ar(sig, cf, rq) * wHp)
                        + (BPF.ar(sig, cf, rq) * (1 + res) * wBp)
                }
            }, {
                var rq = (1 - (res * 0.92)).max(0.05);
                (RLPF.ar(sig, cf, rq) * wLp) + (RHPF.ar(sig, cf, rq) * wHp)
                    + (BPF.ar(sig, cf, rq) * (1 + res) * wBp)
            });
            sig = colour.value(sig, drive, crush);
            sig = sig * level.lag(0.03);
            Out.ar(own_out, sig);     // what the other tracks' sends read
            Out.ar(out_bus, sig);
            Out.ar(dly_out, sig * fx_dly.lag(0.03));
            Out.ar(rev_out, sig * fx_rev.lag(0.03));
        }).add;

        // ---- io: input, record head (with resample feedback), dry/wet, out

        SynthDef(\mangler2_io, {
            arg in1, in2, out, buf_l, buf_r, play_bus, rec_phase_out, rec_amp_out,
                level = 1.0, rec = 0, rec_level = 1.0, pre_level = 0.0,
                freeze = 0, dry_wet = 0.5, resample = 0.0, regen = 0.0,
                grain_level = 1.0,
                filt_type = 0, cutoff = 20000, resonance = 0, drive = 0.0,
                // track 1's COLOR (crush) and SPACE (its sends into the delay
                // and the reverb); t_dly and t_rev carry the other tracks'
                crush = 0.0, fx_dly = 1.0, fx_rev = 1.0, t_dly = 0, t_rev = 0,
                // delay + reverb run in their own spawn/free synths; io keeps
                // only the mix knobs and the send/return buses
                delay_mix = 0.0, dly_send = 0, dly_ret = 0,
                rev_mix = 0.0, rev_send = 0, rev_ret = 0, t2_ret = 0,
                // routing: the sends into track 1, and where track 1's
                // filtered output goes for the others to read
                snd2 = 0, snd3 = 0, snd4 = 0, ob2 = 0, ob3 = 0, ob4 = 0, own_out = 0;
            var inL, inR, wet, dry, sig, preLim, recRun, recPhase, recL, recR;
            var cf, res, dlyRet, rvRet, dfmClass, mmFilter;
            var regenRun, runW, srcL, srcR, recLvl, preLvl, recG, regG, wLp, wHp, wBp;
            var sendIn, others, revIn, dm;
            inL = In.ar(in1, 1);
            inR = In.ar(in2, 1);
            // wet = drone + ALL polyphonic voices (they Out.ar-add onto play_bus)
            // 2.sqrt (not 1.5): the exact inverse of Balance2's -3dB centre
            // gain in the play defs — PLAY at pan 0 with no FX now lands at
            // EXACT unity vs the raw take (the "exact recorded sample"
            // claim, previously +0.5dB into the limiter).
            wet = In.ar(play_bus, 2) * grain_level.lag(0.03) * 2.sqrt;
            // the sends into track 1 (a block late, bounded by a tanh)
            sendIn = (InFeedback.ar(ob2, 2) * snd2.lag(0.03))
                + (InFeedback.ar(ob3, 2) * snd3.lag(0.03))
                + (InFeedback.ar(ob4, 2) * snd4.lag(0.03));
            wet = wet + LeakDC.ar(sendIn).tanh;

            // DFM1 diode-ladder filter, guarded -> stock RLPF/RHPF/BPF fallback
            // if sc3-plugins is absent. Two DFM1s: LP for LP+BP, HP for HP; BP
            // high-passes the resonant LP peak into a band. filt_type 0=LP 1=HP 2=BP.
            cf = cutoff.clip(20, 20000).lag(0.05);
            // lag the resonance like cutoff: a stepped CC/encoder jump on a
            // near-self-oscillating filter is the file's likeliest pop source.
            // (reassigning the arg means the fallback's rq law below gets the
            // same smoothing for free.)
            resonance = resonance.lag(0.05);
            // clip below DFM1's self-oscillation onset (~0.95) so max resonance
            // is very resonant but STABLE; raise toward 0.95 to let it self-osc.
            res = resonance.clip(0, 0.9);
            // a TYPE change is a 20ms CROSSFADE: every type runs all the
            // time and these weights glide. Lag is linear in its input, so
            // the three still add up to 1 mid-glide. A switched type popped,
            // because the output and the ladder's state both jumped. The
            // cost is a second DFM1, always on (CPU sat near 30%).
            wLp = Lag.kr(filt_type < 0.5, 0.02);
            wHp = Lag.kr((filt_type > 0.5) * (filt_type < 1.5), 0.02);
            wBp = Lag.kr(filt_type > 1.5, 0.02);
            mmFilter = {
                var rq = (1 - (resonance * 0.92)).max(0.05);
                (RLPF.ar(wet, cf, rq) * wLp)
                    + (RHPF.ar(wet, cf, rq) * wHp)
                    + (BPF.ar(wet, cf, rq) * (1 + resonance) * wBp)
            };
            dfmClass = "DFM1".asSymbol.asClass;
            wet = dfmClass.notNil.if({
                try {
                    // in, freq, res, inputgain, type(0=LP 1=HP), noiselevel.
                    // inputgain 0.5 + x2 makeup: DFM1 is a NONLINEAR diode
                    // model, and the wet path arrives with a fixed 1.5x
                    // loudness makeup — at unity input gain it saturated
                    // constantly ("the engine sounds noisy"), which the old
                    // LINEAR biquads never did. half in / double out keeps
                    // the loudness and stays clean until `drive` asks for
                    // dirt. the 0.5/2 pair is the device-tunable knob here.
                    // two ladders, LP and HP; BP is the LP peak high-passed
                    var lp = dfmClass.ar(wet, cf, res, 0.5, 0, 0) * 2;
                    var hp = dfmClass.ar(wet, cf, res, 0.5, 1, 0) * 2;
                    (lp * wLp) + (hp * wHp)
                        + (HPF.ar(lp, (cf * 0.5).clip(20, 20000)) * wBp)
                } { |e| mmFilter.value }
            }, { mmFilter.value });
            // COLOR: track 1's drive and crush, after its filter. The other
            // tracks have their own in their strips (the drive was shared,
            // after the join, before each track had one).
            wet = colour.value(wet, drive, crush);
            Out.ar(own_out, wet);     // track 1, filtered and coloured, for the sends
            // tracks 2 to 4 join here, after their own filter and colour
            others = In.ar(t2_ret, 2);

            // the delay runs in \mangler2_delay (spawn/free: alive while
            // delay_mix > 0 or the feedback is a near-infinite hold). SPACE:
            // what goes in is each track's own send (fx_dly, 1 by default,
            // which is everything, as before). The echo comes back through
            // InFeedback, one block late; the delay synth's line is one block
            // short to pay for it. The mix law stays the equal-power
            // CROSSFADE (a dub throw wants the direct to duck), lagged so a
            // CC step does not zipper. At rest the synth is gone and the
            // return reads 0.
            dm = delay_mix.lag(0.03);
            Out.ar(dly_send, (wet * fx_dly.lag(0.03)) + In.ar(t_dly, 2));
            dlyRet = InFeedback.ar(dly_ret, 2);

            // reverb + shimmer run in a spawn/free synth (\mangler2_reverb, only
            // while rev_mix > 0). It gets each track's own reverb send through
            // the delay's crossfade (so at fx_rev 1 it is the post-delay wet,
            // as before), and the tail comes back one block late.
            revIn = (((wet * fx_rev.lag(0.03)) + In.ar(t_rev, 2)) * (1 - dm).sqrt)
                + (dlyRet * dm.sqrt);
            Out.ar(rev_send, revIn);
            wet = ((wet + others) * (1 - dm).sqrt) + (dlyRet * dm.sqrt);
            rvRet = InFeedback.ar(rev_ret, 2);
            // SEND-style (OT-like): the direct sound stays at full level and
            // rev_mix only scales how much tail is ADDED. Lua squares the
            // knob, so .sqrt makes the tail gain linear in it.
            rev_mix = rev_mix.lag(0.03);
            wet = wet + (rvRet * rev_mix.sqrt);

            dry = [inL, inR];
            dry_wet = dry_wet.lag(0.03);
            sig = (dry * (1 - dry_wet).sqrt) + (wet * dry_wet.sqrt);
            sig = sig * Lag.kr(level, 0.05);
            // What gets RECORDED is tapped here, before the master limiter.
            // The limiter delays its output by twice its lookahead (6 ms
            // here; it was 20 ms). `resample` mixes the input with the output, so with
            // the old tap that mix was the signal plus a 10 ms copy of itself:
            // a hollow, phasey colour, printed into the buffer for good.
            // Nothing is less safe for taking it from here. The 0.99 limiter
            // further down still catches anything hot before it reaches the
            // buffer, and the two regen record levels still add up to 1.
            preLim = sig;
            // DAC headroom. Lookahead 3ms, so the output is 6ms late: at
            // 0.01 the whole output, dry monitor included, came 20ms late,
            // and with the norns monitor up the input was heard twice.
            sig = Limiter.ar(sig, 0.92, 0.003);
            recRun = rec * (1 - freeze);
            // regen: run the record head continuously and crossfade the OUTPUT
            // back into the buffer (self-mangle). BOUNDED (convex crossfade +
            // LeakDC + master Limiter); bit-identical to no-regen at regen=0.
            // manual rec and freeze both suspend it. a CHOKED engine deck
            // (STOP / mix thrown fully to tape -> level ~0) PAUSES it — else a
            // stopped minute of regen crossfades SILENCE over the whole take.
            regenRun = (regen > 0) * (1 - rec) * (1 - freeze) * (level > 0.001);
            // recG and regG are the two writes' gates, ramped linearly over
            // 10ms (Slew reaches 0 exactly). The head keeps running until the
            // ramp is down, so a punch-out, a punch-in and a regen start fade
            // the write instead of printing a step into the take. Each ramp
            // starts from rec 0, pre 1: a write that does nothing.
            recG = Slew.kr(recRun, 100, 100);
            regG = Slew.kr(regenRun, 100, 100);
            runW = recRun.max(regenRun).max(recG > 0).max(regG > 0);
            // the polled write-head phase advances with the SAME run signal
            // RecordBuf gets (rec OR regen): driven by rec alone, a regen pass
            // walked the real head while rec_phase stayed parked, so the next
            // take's window snapped to stale positions.
            recPhase = Phasor.ar(0, runW * SampleDur.ir / BufDur.kr(buf_l), 0, 1);
            Out.kr(rec_phase_out, A2K.kr(recPhase));
            // LeakDC on the take's dry arm: a line input with DC offset would
            // print it into the buffer and eat limiter headroom. (the regen
            // arm below already has its own; the monitor path stays untouched.)
            // resample is lagged because a step in THIS blend gets printed
            // permanently into the take, not just heard once.
            resample = resample.lag(0.02);
            recL = (LeakDC.ar(inL) * (1 - resample)) + (preLim[0] * resample);
            recR = (LeakDC.ar(inR) * (1 - resample)) + (preLim[1] * resample);
            srcL = (recL * (1 - regG)) + (LeakDC.ar(preLim[0]) * regG);
            srcR = (recR * (1 - regG)) + (LeakDC.ar(preLim[1]) * regG);
            // record-safety limiter: transparent below 0.99, stops a hot take
            // hard-clipping into the buffer.
            srcL = Limiter.ar(srcL, 0.99, 0.002);
            srcR = Limiter.ar(srcR, 0.99, 0.002);
            // the knobs keep their ~10ms lag, so a mid-take move of
            // rec_level, pre_level or regen does not print a step either.
            // With both gates at 0 this is rec 0, pre 1. The gates never sum
            // past 1 (a rec to regen hand-over crosses them), so pre stays >= 0.
            recLvl = (Lag.kr(rec_level, 0.01) * recG) + (Lag.kr(regen, 0.01) * regG);
            preLvl = 1 - (recG * (1 - Lag.kr(pre_level, 0.01)))
                - (regG * Lag.kr(regen, 0.01));
            RecordBuf.ar(srcL, buf_l, 0, recLvl, preLvl, runW, 1);
            RecordBuf.ar(srcR, buf_r, 0, recLvl, preLvl, runW, 1);
            Out.kr(rec_amp_out,
                Amplitude.kr(recL.abs.max(recR.abs) * rec_level, 0.01, 0.1));
            Out.ar(out, sig);
        }).add;

        // ---- BEAT REPEAT, in its own spawn/release synth (updateRepeat).
        // Placed after io, it reads io's finished output off the engine's out
        // bus and REPLACES it. On spawn it passes the output through while it
        // captures the first `len` seconds, then plays that slice in a loop
        // until released. The first pass sends the live input itself, not a
        // read of what is being written, so it never depends on the order the
        // server runs the write and the read in. A 3ms fade at every loop point
        // (and at the first pass's end) keeps the repeats from clicking; `gate`
        // crossfades in over 5ms and back to the live output over 10ms, then
        // frees the synth. It sits after the record tap, so resample, regen
        // and PRINT never record it: a performance effect on what you hear.
        SynthDef(\mangler2_repeat, {
            arg out, buf, len = 0.25, gate = 1;
            var src, l, frames, firstK, first, phase, fade, rep, env;
            src = In.ar(out, 2);
            l = len.clip(0.01, 2);
            frames = (l * SampleRate.ir).max(64);
            // the capture runs two blocks PAST the slice: a kr Sweep reads
            // a block ahead, and stopping at l exactly left the last frames
            // of the loop holding an older capture (a tick in every fade).
            // Writing past `frames` is harmless; the loop never reads it.
            firstK = Sweep.kr(0, 1) < (l + (2 * ControlDur.ir));
            first = Sweep.ar(0, 1) < l;
            RecordBuf.ar(src, buf, 0, 1, 0, firstK, 0);
            phase = Phasor.ar(0, 1, 0, frames);
            fade = (phase.min(frames - phase)
                / (frames * 0.25).min(SampleRate.ir * 0.003)).clip(0, 1);
            rep = Select.ar(first, [BufRd.ar(2, buf, phase, 1, 2), src]) * fade;
            env = EnvGen.kr(Env.asr(0.005, 1, 0.01), gate, doneAction: 2);
            ReplaceOut.ar(out, (src * (1 - env)) + (rep * env));
        }).add;

        // delay synth (spawned by updateDelay). reads io's post-drive wet,
        // returns the 100%-wet echo; io does the crossfade. the regeneration
        // loop lives HERE (this def's own LocalIn/LocalOut pair), so freeing
        // the synth is what flushes the line — \clear leans on exactly that.
        // all core UGens. delay_mix is accepted and unused: the generic
        // command handler sets every delayParams key on the live synth, and
        // an unknown control name would be a server complaint per knob move.
        SynthDef(\mangler2_delay, {
            arg in_bus, out_bus, delay_time = 0.3, delay_fb = 0.3, delay_mix = 0;
            var sig, fbIn, dIn, dOut;
            sig = In.ar(in_bus, 2);
            delay_fb = delay_fb.lag(0.03);   // CC steps zipper without this
            fbIn = LocalIn.ar(2);
            dIn = sig + (fbIn * delay_fb);
            // 2s line: a half-note sync below 120 BPM needs more than 1s,
            // and the extra second costs ~0.75 MB of server memory
            // minus one block: LocalIn hands each repeat back one block late,
            // and io reads the return one block late, so the line itself is
            // one block short. Every echo, the first included, lands on time.
            // (Without it a synced delay drifted 1.33ms per repeat.)
            dOut = DelayC.ar(dIn, 2.0,
                delay_time.clip(0.01, 2.0).lag(0.2) - ControlDur.ir);
            // tanh, not softclip, for the signal that goes back round the
            // loop. softclip bends sharply at the point it starts limiting,
            // and every repeat bends it again, so the distortion piles up
            // scratchy. tanh curves smoothly and still stops at +-1.
            // WHAT IT COSTS, measured: softclip leaves anything under 0.5
            // completely untouched, tanh does not. A repeat at level 0.5 comes
            // back 0.86 dB quieter each pass instead of 0.18 dB, so a hold
            // that used to sit still now fades about 10 dB over a dozen
            // repeats. Quiet repeats are unaffected. If the infinite hold
            // needs to sustain rather than fade, put softclip back here.
            LocalOut.ar(LPF.ar(dOut, 3500).tanh);
            Out.ar(out_bus, dOut);
        }).add;

        // reverb + shimmer synth (spawned by updateReverb while rev_mix > 0).
        // reads io's post-delay wet, returns the JPverb tail; shimmer recirculates
        // through this synth's own LocalIn/LocalOut. JPverb guarded -> FreeVerb.
        SynthDef(\mangler2_reverb, {
            arg in_bus, out_bus,
                rev_size = 1.0, rev_decay = 2.0, rev_damp = 0.3, rev_early = 0.7,
                rev_moddepth = 0.1, rev_modfreq = 2.0,
                rev_low = 1.0, rev_mid = 1.0, rev_high = 1.0,
                rev_lowcut = 500, rev_highcut = 2000,
                shimmer = 0.0, shimmer_pitch = 12.0, shimmer_tone = 4500.0;
            var wet, fbIn, shimFb, revIn, rv, jpClass, ratio, pitched, shimOut;
            wet = In.ar(in_bus, 2);                 // io's post-delay wet send
            // shimmer feedback: the pitched tail recirculates into the reverb
            // INPUT so it climbs in octaves. shimmer=0 -> shimOut 0 -> revIn==wet.
            fbIn = LocalIn.ar(2);
            shimFb = fbIn;
            revIn = wet + (shimFb * shimmer.clip(0, 0.95));
            jpClass = "JPverb".asSymbol.asClass;
            rv = jpClass.notNil.if({
                // in (STEREO pair — the mono .sum collapsed the grain field's
                // pan/spread and the stereo shimmer out of the tail; array-in
                // via perform works, the MiClouds call is the precedent),
                // t60, damp, size, earlyDiff, modDepth, modFreq,
                // low, mid, high, lowcut, highcut
                jpClass.ar(revIn * 0.5, rev_decay, rev_damp, rev_size,
                    rev_early, rev_moddepth, rev_modfreq,
                    rev_low, rev_mid, rev_high, rev_lowcut, rev_highcut)
            }, {
                var rs = rev_decay.linlin(0.1, 30, 0.1, 0.97);
                [FreeVerb.ar(revIn[0], 1.0, rs, rev_damp),
                    FreeVerb.ar(revIn[1], 1.0, rs, rev_damp)] * 2
            });
            // pitch the tail (semitones -> ratio), band-limit so the octave
            // stack stays a halo (HPF kills DC/rumble build-up, LPF tames the
            // metallic hiss), the saturator bounds runaway. STEREO shimmer, a
            // PitchShift per channel, for a wide halo.
            ratio = (shimmer_pitch.round(1) / 12.0);
            ratio = (2 ** ratio).clip(0.25, 4);
            // pitchDispersion 0.02 (was 0): SC's own docs — uniform grain
            // placement at a fixed ratio combs; a whisper of dispersion
            // softens the robotic edge at the octave-up default.
            pitched = PitchShift.ar(rv, 0.2, ratio, 0.02, 0.01);
            pitched = LPF.ar(HPF.ar(pitched, 120), shimmer_tone.clip(500, 12000));
            // tanh for the same reason as the delay loop: this recirculates,
            // and a halo is the last place that wants a hard knee in it.
            shimOut = (pitched * (shimmer > 0)).tanh;
            LocalOut.ar(shimOut);
            Out.ar(out_bus, rv);
        }).add;

        s.sync;

        // playback group first, io after it, so io reads play_bus in-block.
        // polyphonic voices also spawn into playGroup (before io) -> they add
        // onto play_bus and pass through the io FX chain like the drone.
        playGroup = Group.new(context.xg);
        sendV = Array.fill(4, { Array.fill(4, 0) });
        extra.do({ arg tr;
            tr[\strip] = Synth.new(\mangler2_strip, [
                \in_bus, tr[\bus], \out_bus, tRetBus,
                \own_out, outBuses[tr[\n] - 1],
                \dly_out, tDlyBus, \rev_out, tRevBus,
                \ob1, outBuses[0], \ob2, outBuses[1], \ob3, outBuses[2], \ob4, outBuses[3],
            ] ++ tr[\stripParams].getPairs, playGroup, \addToTail);
            tr[\mode] = 0;
        });
        // every strip starts paused: no extra track plays and nothing is sent
        // (the run message follows its /s_new in order, no sync needed)
        extra.do({ arg tr; tr[\strip].run(false) });
        ioSynth = Synth.new(\mangler2_io, [
            \in1, context.in_b[0].index,
            \in2, context.in_b[1].index,
            \out, context.out_b.index,
            \buf_l, bufL,
            \buf_r, bufR,
            \play_bus, playBus,
            \rec_phase_out, recPhaseBus,
            \rec_amp_out, recAmpBus,
            \rev_send, revSendBus,
            \rev_ret, revRetBus,
            \dly_send, dlySendBus,
            \dly_ret, dlyRetBus,
            \t2_ret, tRetBus,
            \t_dly, tDlyBus, \t_rev, tRevBus,
            \own_out, outBuses[0],
            \ob2, outBuses[1], \ob3, outBuses[2], \ob4, outBuses[3],
        ], playGroup, \addAfter);

        // every float control as one command; rec/freeze/level fan out to both
        // synths; revParams route to \mangler2_reverb and delayParams to
        // \mangler2_delay; eroKeys also reach \mangler2_erode; the mix/fb knobs
        // and erode also spawn/free their synths.
        allKeys = (ioKeys ++ playParams.keys.asArray ++ revParams.keys.asArray
            ++ delayParams.keys.asArray).asSet;
        allKeys.do({ arg name;
            this.addCommand(name, "f", { arg msg;
                var v = msg[1];
                ioKeys.includes(name).if({ ioSynth.set(name, v) });
                revParams.includesKey(name).if({
                    revParams[name] = v;
                    revSynth.notNil.if({ revSynth.set(name, v) });
                });
                delayParams.includesKey(name).if({
                    delayParams[name] = v;
                    delaySynth.notNil.if({ delaySynth.set(name, v) });
                });
                playParams.includesKey(name).if({
                    playParams[name] = v;
                    playSynth.notNil.if({ playSynth.set(name, v) });
                    // the three the other tracks' drones share with the take
                    [\level, \rec, \freeze].includes(name).if({
                        extra.do({ arg tr;
                            tr[\synth].notNil.if({ tr[\synth].set(name, v) });
                        });
                    });
                    (eroSynth.notNil and: { eroKeys.includes(name) }).if({
                        eroSynth.set(name, v);
                    });
                });
                (name == \erode).if({ this.updateErode });
                ((name == \delay_mix) or: { name == \delay_fb }).if({
                    this.updateDelay;
                });
                (name == \rev_mix).if({ revMixV = v; this.updateReverb(v) });
            });
        });

        this.addCommand(\mode, "i", { arg msg;
            this.setMode(msg[1]);
        });

        // own material per track: which pair io records into (and regen and
        // PRINT write), and which pair the buffer commands and pads act on
        this.addCommand(\rec_track, "i", { arg msg;
            recIdx = msg[1].asInteger.clip(0, 3);
            ioSynth.set(\buf_l, bufLs[recIdx], \buf_r, bufRs[recIdx]);
        });
        this.addCommand(\buf_track, "i", { arg msg;
            opIdx = msg[1].asInteger.clip(0, 3);
        });

        // ---- tracks 2 to 4: `t<n>_<drone arg>` for each of its drone
        // values, `t<n>_<strip key>` for its strip, and `t<n>_mode`
        extra.do({ arg tr;
            var pre = "t" ++ tr[\n] ++ "_";
            tr[\params].keys.do({ arg k;
                this.addCommand((pre ++ k).asSymbol, "f", { arg msg;
                    tr[\params][k] = msg[1];
                    tr[\synth].notNil.if({ tr[\synth].set(k, msg[1]) });
                });
            });
            stripKeys.do({ arg k;
                this.addCommand((pre ++ k).asSymbol, "f", { arg msg;
                    tr[\stripParams][k] = msg[1];
                    tr[\strip].set(k, msg[1]);
                });
            });
            this.addCommand((pre ++ "mode").asSymbol, "i", { arg msg;
                this.setModeN(tr, msg[1]);
            });
        });
        // ---- routing: send_<from>_<to>, each to the receiving track's synth
        // (track 1's is io) as its snd<from>
        (1..4).do({ arg from;
            (1..4).do({ arg to;
                (from != to).if({
                    this.addCommand(("send_" ++ from ++ "_" ++ to).asSymbol, "f", { arg msg;
                        var key = ("snd" ++ from).asSymbol;
                        sendV[from - 1][to - 1] = msg[1];
                        (to == 1).if({ ioSynth.set(key, msg[1]) }, {
                            extra[to - 2][\strip].set(key, msg[1]);
                            this.updateStrip(extra[to - 2]);
                        });
                    });
                });
            });
        });

        // ---- polyphony commands. note_on/one_shot gained a trailing AMP
        // (per-note level) — an ARITY change, NOT a new command, so the
        // fingerprint COUNT is unchanged. amp nil (an old 4-arg caller) -> the
        // voiceParams default, so it degrades cleanly both ways.
        this.addCommand(\note_on, "ifffff", { arg msg;
            this.noteOn(msg[1], msg[2], msg[3], msg[4], msg[5], msg[6]);
        });
        this.addCommand(\note_off, "i", { arg msg;
            this.noteOff(msg[1]);
        });
        this.addCommand(\note_one_shot, "fffff", { arg msg;
            this.noteOneShot(msg[1], msg[2], msg[3], msg[4], msg[5]);
        });
        // the beat repeat: the slice length in seconds, 0 = release. The 66th
        // command (the count moved from 65). Not `repeat`: that is a Lua
        // keyword, and `engine.repeat` would not even parse.
        this.addCommand(\beat_repeat, "f", { arg msg;
            this.updateRepeat(msg[1]);
        });
        this.addCommand(\voices, "i", { arg msg;
            maxVoices = msg[1].max(1);
        });
        this.addCommand(\voice_atk, "f", { arg msg;
            voiceParams[\voice_atk] = msg[1];
        });
        this.addCommand(\voice_rel, "f", { arg msg;
            voiceParams[\voice_rel] = msg[1];
        });

        // clear/load act on the SAME bufL/bufR the synths hold (Buffer:zero and
        // instance readChannel into the existing buffer) — no bufnum ever changes.
        this.addCommand(\clear, "", { arg msg;
            bufLs[opIdx].zero;
            bufRs[opIdx].zero;
            // a clear must be SILENCE: the delay line and the reverb/shimmer
            // recirculation still ring with the erased material. their state
            // lives inside the spawn/free synths, so a free + respawn IS the
            // flush (the update methods re-spawn only if the mixes want them).
            delaySynth.notNil.if({ delaySynth.free; delaySynth = nil });
            revSynth.notNil.if({ revSynth.free; revSynth = nil });
            // ...and a held repeat would go on playing the erased sound
            this.updateRepeat(0);
            // the zero runs in the background: an effect spawned before it lands
            // takes in the last of the take and echoes it (-54 dB on the device)
            fork {
                s.sync;
                this.updateDelay;
                this.updateReverb(revMixV);
            };
            "mangler: engine buffer cleared".postln;
        });

        // load any wav/aiff into the buffer. no SR conversion — a 44.1k file at
        // the 48k server plays ~9% fast (a varispeed).
        this.addCommand(\read_file, "s", { arg msg;
            var path = msg[1].asString;
            var sf = SoundFile.new;
            sf.openRead(path).if({
                var nch = sf.numChannels;
                var frames = sf.numFrames.min(s.sampleRate * bufSecs);
                var bl = bufLs[opIdx], br = bufRs[opIdx];
                sf.close;
                bl.zero;
                br.zero;
                bl.readChannel(path, 0, frames, 0, false, [0]);
                // a mono file feeds BOTH sides from channel 0
                br.readChannel(path, 0, frames, 0, false, [(nch - 1).min(1)]);
                ("mangler: loaded " ++ path ++ " — " ++ frames ++ " frames, "
                    ++ nch ++ "ch").postln;
            }, {
                ("mangler: CANNOT READ " ++ path).postln;
            });
        });

        // persist the live take across PSET save/load: write bufL/bufR to a
        // private L/R pair (24-bit wav, async /b_write, bounded, core UGens).
        // numFrames bounds the write to the take from frame 0; n <= 0 = whole buffer.
        //
        // 24, not 16: the buffer itself is 32-bit float, and every save/load
        // round trip through a 16-bit file quantised the take again. This is
        // also what the EXPORT is built on, so a bounced wav carries the depth
        // too. The lua reader already decodes 16/24/32.
        // IF YOU CHANGE THIS FORMAT, change `ctx.TAKE_BYTES` in mangler2.lua
        // to match. The export works out how big these files should be from
        // that number and waits for them to get there. Set too low, it stops
        // waiting early and hands on a file that is still being written.
        this.addCommand(\write_take, "si", { arg msg;
            var stem = msg[1].asString;
            var n = (msg.size > 2).if({ msg[2].asInteger }, { -1 });
            if(n <= 0, { n = -1 });
            bufLs[opIdx].write(stem ++ "_L.wav", "wav", "int24", n);
            bufRs[opIdx].write(stem ++ "_R.wav", "wav", "int24", n);
            ("mangler: wrote take " ++ stem ++ " ("
                ++ (n < 0).if("full", { n.asString ++ " frames" }) ++ ")").postln;
        });

        // read the pair back into the SAME bufL/bufR (readChannel into an
        // existing buffer — no bufnum change, nothing respawns). The Lua side
        // only calls this when the _L file exists; both halves are the same
        // length because write_take always writes them together.
        this.addCommand(\read_take, "s", { arg msg;
            var stem = msg[1].asString;
            var pathL = stem ++ "_L.wav";
            var pathR = stem ++ "_R.wav";
            var sf = SoundFile.new;
            sf.openRead(pathL).if({
                var frames = sf.numFrames.min(s.sampleRate * bufSecs);
                var bl = bufLs[opIdx], br = bufRs[opIdx];
                sf.close;
                bl.zero;
                br.zero;
                bl.readChannel(pathL, 0, frames, 0, false, [0]);
                br.readChannel(pathR, 0, frames, 0, false, [0]);
                ("mangler: restored take " ++ stem ++ " — "
                    ++ frames ++ " frames").postln;
            }, {
                ("mangler: CANNOT READ take " ++ stem).postln;
            });
        });

        this.addPoll(\play_phase, {
            phaseBus.getSynchronous;
        });
        // the other tracks' read heads (polls are not commands)
        extra.do({ arg tr;
            this.addPoll(("play_phase" ++ tr[\n]).asSymbol, {
                tr[\phase].getSynchronous;
            });
        });
        this.addPoll(\rec_phase, {
            recPhaseBus.getSynchronous;
        });
        this.addPoll(\rec_amp, {
            recAmpBus.getSynchronous;
        });

        // start in GRAIN; the Lua defaults switch it to clean PLAY at load
        this.setMode(1);
    }

    free {
        activeVoices.notNil.if({ activeVoices.do({ arg v; v.notNil.if({ v.free }) }) });
        playSynth.notNil.if({ playSynth.free });
        extra.notNil.if({ extra.do({ arg tr;
            tr[\synth].notNil.if({ tr[\synth].free });
            tr[\strip].notNil.if({ tr[\strip].free });
        }) });
        revSynth.notNil.if({ revSynth.free });
        delaySynth.notNil.if({ delaySynth.free });
        eroSynth.notNil.if({ eroSynth.free });
        repSynth.notNil.if({ repSynth.free });
        repBufs.notNil.if({ repBufs.do({ arg b; b.free }) });
        ioSynth.free;
        playGroup.free;
        bufLs.notNil.if({ bufLs.do({ arg b; b.free }) });
        bufRs.notNil.if({ bufRs.do({ arg b; b.free }) });
        grainEnv1.free;
        grainEnv2.free;
        playBus.free;
        revSendBus.free;
        revRetBus.free;
        dlySendBus.free;
        dlyRetBus.free;
        phaseBus.free;
        extra.notNil.if({ extra.do({ arg tr; tr[\bus].free; tr[\phase].free }) });
        tRetBus.free;
        tDlyBus.free;
        tRevBus.free;
        outBuses.do({ arg b; b.free });
        recPhaseBus.free;
        recAmpBus.free;
    }
}
