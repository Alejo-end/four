// Engine_Mangler.sc — THE ONLY engine file for the `mangler` norns script.
//
// HARD RULE: exactly one `Engine_Mangler` class under dust/code. A duplicate
// hangs every norns script forever on "LOADING".
//
// Architecture: one persistent `io` synth (input, record head, dry/wet mix,
// resample/regen feedback, FILTER/DELAY, output) + ONE `mode` drone at a time
// (OFF/GRAIN/WARP/PV/PLAY, spawned/freed by setMode) + a polyphonic voice layer
// + a spawn/free reverb synth (updateReverb, only while rev_mix > 0). Drone and
// voices Out.ar additively onto play_bus; io reads it. Plugin UGens (JPverb,
// MiClouds, DFM1) are guarded via .asClass -> stock fallback so a missing
// plugin never bricks the load.
//
// DEVICE NOTES: context.in_b is an ARRAY of two mono busses, out_b one stereo
// bus. SC errors land in maiden's SC tab, not matron. Editing this file needs
// SYSTEM > RESTART (sclang recompiles at startup); confirm the command count in
// the load log after.

Engine_Mangler : CroneEngine {
    var <ioSynth, <playSynth;
    var <playGroup;
    var <bufL, <bufR;
    var <grainEnv1, <grainEnv2;
    var <playBus;
    var <phaseBus, <recPhaseBus, <recAmpBus;
    var <playParams;
    var <ioKeys;
    // reverb+shimmer spawn/free synth: freed at rev_mix==0. send/return busses
    // + last-known reverb params (handed over when the synth is spawned).
    var <revSynth, <revSendBus, <revRetBus, <revParams;
    // S8 polyphonic voice layer
    var <activeVoices, <voiceOrder, <voiceParams, <maxVoices;
    // S11: true when the MiClouds def compiled (mi-UGens present) — GRAIN mode
    // then uses the Clouds granular voice instead of the GrainBuf fallback
    var <hasClouds;

    *new { arg context, doneCallback;
        ^super.new(context, doneCallback);
    }

    setMode { arg i;
        playSynth.notNil.if({ playSynth.free; playSynth = nil });
        (i > 0).if({
            var def;
            // 1=GRAIN 2=WARP 3=PV 4=PLAY (0=OFF). GRAIN -> MiClouds when
            // available, else GrainBuf. PLAY is the clean straight loop.
            (i == 4).if({
                def = \mangler_play;
            }, {
                ((i == 1) and: { hasClouds }).if({
                    def = \mangler_clouds;
                }, {
                    def = [\mangler_grain, \mangler_warp, \mangler_pv].at(i - 1);
                });
            });
            playSynth = Synth.new(def, [
                \buf_l, bufL, \buf_r, bufR,
                \play_bus, playBus, \phase_out, phaseBus,
                \grain_env1, grainEnv1, \grain_env2, grainEnv2,
            ] ++ playParams.getPairs, playGroup);
        });
    }

    // spawn/free the reverb synth on rev_mix. placed AFTER ioSynth (reads io's
    // fresh send this block; io reads the return via InFeedback next block).
    updateReverb { arg mix;
        (mix > 0).if({
            revSynth.isNil.if({
                revSynth = Synth.new(\mangler_reverb, [
                    \in_bus, revSendBus, \out_bus, revRetBus,
                ] ++ revParams.getPairs, ioSynth, \addAfter);
            });
        }, {
            revSynth.notNil.if({ revSynth.free; revSynth = nil });
        });
    }

    // ---- S8 voice allocation ------------------------------------------------
    // shared spawn args: buffers, bus, envelope, and the CURRENT drone grain
    // params so a grain-cloud voice tracks the drone's character.
    voiceArgs { arg pos, pitch, oneShot, amp;
        ^[
            \buf_l, bufL, \buf_r, bufR, \play_bus, playBus,
            \note_pos, pos, \note_pitch, pitch,
            \gate, 1, \one_shot, oneShot,
            \amp, amp ? voiceParams[\amp],   // per-note level (nil -> the default)
            \atk, voiceParams[\voice_atk], \rel, voiceParams[\voice_rel],
            \grain_env1, grainEnv1, \grain_env2, grainEnv2,
            \size, playParams[\size], \density, playParams[\density],
            \spread, playParams[\spread],
            \grain_jitter, playParams[\grain_jitter],
            \grain_pitch_spread, playParams[\grain_pitch_spread],
            \grain_shape, playParams[\grain_shape]
        ];
    }

    noteOn { arg id, pos, pitch, type, amp;
        var def, syn;
        // enforce polyphony cap: release-steal the oldest held voice
        (voiceOrder.size >= maxVoices).if({
            var oldId = voiceOrder.removeAt(0);
            var old = activeVoices[oldId];
            old.notNil.if({ old.set(\gate, 0) });
            activeVoices.removeAt(oldId);
        });
        def = (type > 0.5).if({ \mangler_voice_slice }, { \mangler_voice_grain });
        syn = Synth.new(def, this.voiceArgs(pos, pitch, 0, amp), playGroup);
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

    noteOneShot { arg pos, pitch, type, amp;
        var def = (type > 0.5).if({ \mangler_voice_slice }, { \mangler_voice_grain });
        // fire-and-forget: internal gate self-terminates, synth self-frees
        Synth.new(def, this.voiceArgs(pos, pitch, 1, amp), playGroup);
    }

    alloc {
        var s = context.server;
        var allKeys;

        bufL = Buffer.alloc(s, s.sampleRate * 60, 1);
        bufR = Buffer.alloc(s, s.sampleRate * 60, 1);

        // grain envelope buffers (S7). shape 0 uses built-in Hann (envbufnum
        // -1) and never touches these. filled BEFORE the s.sync below so
        // they're ready when the first GRAIN synth spawns.
        grainEnv1 = Buffer.alloc(s, 2048, 1);
        grainEnv2 = Buffer.alloc(s, 2048, 1);
        grainEnv1.loadCollection(Env([0, 1, 0], [0.5, 0.5], \welch).asSignal(2048));
        grainEnv2.loadCollection(Env([0, 1, 0], [0.02, 0.98], [4, -4]).asSignal(2048));

        playBus = Bus.audio(s, 2);
        // reverb send/return busses (each 2ch)
        revSendBus = Bus.audio(s, 2);
        revRetBus = Bus.audio(s, 2);
        phaseBus = Bus.control(s, 1);
        recPhaseBus = Bus.control(s, 1);
        recAmpBus = Bus.control(s, 1);

        // S8 voice state
        maxVoices = 8;
        activeVoices = Dictionary.new;
        voiceOrder = List.new;
        // S9 headroom: per-voice amp 0.5 -> 0.3 so a chord of poly voices
        // summing on play_bus doesn't slam the master limiter (the S8 clip).
        voiceParams = Dictionary[\amp -> 0.3, \voice_atk -> 0.005, \voice_rel -> 0.6];

        // last-known drone values, handed to a freshly spawned mode synth
        playParams = Dictionary[
            \rec -> 0, \freeze -> 0,
            \pos_start -> 0.0, \pos_end -> 1.0, \scan -> 1.0, \pos_jitter -> 0.0,
            \size -> 0.1, \density -> 20, \pitch -> 1.0, \spread -> 0.5, \pan -> 0.0,
            \grain_jitter -> 0.0, \grain_pitch_spread -> 0.0, \grain_shape -> 0,
            \warp_window -> 0.25, \warp_overlaps -> 4, \warp_rand -> 0.0, \pv_freeze -> 0,
            // S11 MiClouds granular controls (also passed to the fallback defs,
            // which simply ignore them)
            \clouds_pos -> 0.5, \clouds_tex -> 0.5, \clouds_fb -> 0.0,
            \clouds_mode -> 0, \clouds_lofi -> 0.0
        ];
        // reverb params live in revParams (routed to \mangler_reverb); io keeps
        // only rev_mix. (ioKeys U revParams) is the old ioKeys -> same commands.
        ioKeys = [\level, \rec, \rec_level, \pre_level, \freeze,
            \dry_wet, \resample, \regen, \grain_level,
            \filt_type, \cutoff, \resonance, \drive,
            \delay_time, \delay_fb, \delay_mix,
            \rev_mix];
        revParams = Dictionary[
            \rev_size -> 1.0, \rev_decay -> 2.0, \rev_damp -> 0.3, \rev_early -> 0.7,
            \rev_moddepth -> 0.1, \rev_modfreq -> 2.0,
            \rev_low -> 1.0, \rev_mid -> 1.0, \rev_high -> 1.0,
            \rev_lowcut -> 500, \rev_highcut -> 2000,
            \shimmer -> 0.0, \shimmer_pitch -> 12.0, \shimmer_tone -> 4500.0
        ];

        // ---- drone playback defs: ONE runs at a time. all share the full
        // arg set (unused args ignored) so spawn/set stays uniform.

        SynthDef(\mangler_grain, {
            arg buf_l, buf_r, play_bus, phase_out, rec = 0, freeze = 0,
                pos_start = 0, pos_end = 1, scan = 1, pos_jitter = 0,
                size = 0.1, density = 20, pitch = 1, spread = 0.5, pan = 0,
                grain_jitter = 0, grain_pitch_spread = 0, grain_shape = 0,
                grain_env1 = -1, grain_env2 = -1,
                clouds_pos = 0.5, clouds_tex = 0.5, clouds_fb = 0, clouds_mode = 0,
                clouds_lofi = 0,
                warp_window = 0.25, warp_overlaps = 4, warp_rand = 0, pv_freeze = 0;
            var lo, hi, span, incr, phase, winPos, look;
            var trigL, trigR, posL, posR, panL, panR, sig, comp;
            var durL, durR, pchL, pchR, envSel;
            lo = pos_start.min(pos_end);
            hi = pos_start.max(pos_end);
            span = (hi - lo).max(0.001);
            incr = scan * SampleDur.ir / (BufDur.kr(buf_l) * span);
            phase = Phasor.ar(0, incr, 0, 1);
            winPos = lo + (phase * span);
            Out.kr(phase_out, A2K.kr(winPos));
            look = (0.25 / BufDur.kr(buf_l)) * rec * (1 - freeze);
            // S7: Dust (Poisson) instead of Impulse (periodic).
            trigL = Dust.kr(density);
            trigR = Dust.kr(density);
            posL = winPos - look + TRand.kr((pos_jitter * span).neg, pos_jitter * span, trigL);
            posR = winPos - look + TRand.kr((pos_jitter * span).neg, pos_jitter * span, trigR);
            panL = (pan + TRand.kr(spread.neg, spread, trigL)).clip(-1, 1);
            panR = (pan + TRand.kr(spread.neg, spread, trigR)).clip(-1, 1);
            durL = (size * (1 + TRand.kr(grain_jitter.neg, grain_jitter, trigL))).max(0.001);
            durR = (size * (1 + TRand.kr(grain_jitter.neg, grain_jitter, trigR))).max(0.001);
            pchL = pitch * (TRand.kr(grain_pitch_spread.neg, grain_pitch_spread, trigL) / 12).midiratio;
            pchR = pitch * (TRand.kr(grain_pitch_spread.neg, grain_pitch_spread, trigR) / 12).midiratio;
            envSel = Select.kr(grain_shape.clip(0, 2), [-1, grain_env1, grain_env2]);
            comp = (density * size).clip(0.25, 1).sqrt.reciprocal;
            sig = (GrainBuf.ar(2, trigL, durL, buf_l, pchL, posL.wrap(0, 1), 4, panL, envSel)
                + GrainBuf.ar(2, trigR, durR, buf_r, pchR, posR.wrap(0, 1), 4, panR, envSel)) * comp;
            Out.ar(play_bus, sig);
        }).add;

        SynthDef(\mangler_warp, {
            arg buf_l, buf_r, play_bus, phase_out, rec = 0, freeze = 0,
                pos_start = 0, pos_end = 1, scan = 1, pos_jitter = 0,
                size = 0.1, density = 20, pitch = 1, spread = 0.5, pan = 0,
                grain_jitter = 0, grain_pitch_spread = 0, grain_shape = 0,
                grain_env1 = -1, grain_env2 = -1,
                clouds_pos = 0.5, clouds_tex = 0.5, clouds_fb = 0, clouds_mode = 0,
                clouds_lofi = 0,
                warp_window = 0.25, warp_overlaps = 4, warp_rand = 0, pv_freeze = 0;
            var lo, hi, span, incr, phase, winPos, ptr, l, r, sig;
            lo = pos_start.min(pos_end);
            hi = pos_start.max(pos_end);
            span = (hi - lo).max(0.001);
            incr = scan * SampleDur.ir / (BufDur.kr(buf_l) * span);
            phase = Phasor.ar(0, incr, 0, 1);
            winPos = lo + (phase * span);
            Out.kr(phase_out, A2K.kr(winPos));
            ptr = A2K.kr(winPos);
            l = Warp1.ar(1, buf_l, ptr, pitch, warp_window, -1, warp_overlaps, warp_rand, 4);
            r = Warp1.ar(1, buf_r, ptr, pitch, warp_window, -1, warp_overlaps, warp_rand, 4);
            sig = Balance2.ar(l, r, pan);
            Out.ar(play_bus, sig);
        }).add;

        SynthDef(\mangler_pv, {
            arg buf_l, buf_r, play_bus, phase_out, rec = 0, freeze = 0,
                pos_start = 0, pos_end = 1, scan = 1, pos_jitter = 0,
                size = 0.1, density = 20, pitch = 1, spread = 0.5, pan = 0,
                grain_jitter = 0, grain_pitch_spread = 0, grain_shape = 0,
                grain_env1 = -1, grain_env2 = -1,
                clouds_pos = 0.5, clouds_tex = 0.5, clouds_fb = 0, clouds_mode = 0,
                clouds_lofi = 0,
                warp_window = 0.25, warp_overlaps = 4, warp_rand = 0, pv_freeze = 0;
            var lo, hi, span, incr, phase, winPos, sigL, sigR, chainL, chainR, l, r, sig;
            lo = pos_start.min(pos_end);
            hi = pos_start.max(pos_end);
            span = (hi - lo).max(0.001);
            incr = scan * SampleDur.ir / (BufDur.kr(buf_l) * span);
            phase = Phasor.ar(0, incr, 0, 1);
            winPos = lo + (phase * span);
            Out.kr(phase_out, A2K.kr(winPos));
            sigL = BufRd.ar(1, buf_l, winPos * BufFrames.kr(buf_l), 1, 2);
            sigR = BufRd.ar(1, buf_r, winPos * BufFrames.kr(buf_r), 1, 2);
            chainL = FFT(LocalBuf(2048), sigL);
            chainR = FFT(LocalBuf(2048), sigR);
            chainL = PV_MagFreeze(chainL, pv_freeze);
            chainR = PV_MagFreeze(chainR, pv_freeze);
            l = IFFT(chainL);
            r = IFFT(chainR);
            sig = Balance2.ar(l, r, pan);
            Out.ar(play_bus, sig);
        }).add;

        // ---- S14: CLEAN PLAY drone — a straight loop of the window, the EXACT
        // recorded sample (no granulation/stretch/spectral). this is the
        // default mode so a fresh take plays back untouched; GRAIN/WARP/PV are
        // switched on when you want them. scan sets loop speed, pitch resamples
        // it (varispeed, like a sampler/tape). all core UGens — can't brick.
        SynthDef(\mangler_play, {
            arg buf_l, buf_r, play_bus, phase_out, rec = 0, freeze = 0,
                pos_start = 0, pos_end = 1, scan = 1, pos_jitter = 0,
                size = 0.1, density = 20, pitch = 1, spread = 0.5, pan = 0,
                grain_jitter = 0, grain_pitch_spread = 0, grain_shape = 0,
                grain_env1 = -1, grain_env2 = -1,
                clouds_pos = 0.5, clouds_tex = 0.5, clouds_fb = 0, clouds_mode = 0,
                clouds_lofi = 0,
                warp_window = 0.25, warp_overlaps = 4, warp_rand = 0, pv_freeze = 0;
            var lo, hi, span, incr, phase, winPos, sigL, sigR, sig;
            lo = pos_start.min(pos_end);
            hi = pos_start.max(pos_end);
            span = (hi - lo).max(0.001);
            incr = scan * pitch * SampleDur.ir / (BufDur.kr(buf_l) * span);
            phase = Phasor.ar(0, incr, 0, 1);
            winPos = lo + (phase * span);
            Out.kr(phase_out, A2K.kr(winPos));
            sigL = BufRd.ar(1, buf_l, winPos * BufFrames.kr(buf_l), 1, 4);
            sigR = BufRd.ar(1, buf_r, winPos * BufFrames.kr(buf_r), 1, 4);
            sig = Balance2.ar(sigL, sigR, pan);
            Out.ar(play_bus, sig);
        }).add;

        // MiClouds granular drone (mi-UGens), guarded two ways: .asClass (no
        // literal reference) + a try around the def -> falls back to GrainBuf if
        // absent/broken. a BufRd scrubs the window into Clouds; pv_freeze doubles
        // as the clouds freeze.
        hasClouds = false;
        "MiClouds".asSymbol.asClass.notNil.if({
            try {
                var cc = "MiClouds".asSymbol.asClass;
                SynthDef(\mangler_clouds, {
                    arg buf_l, buf_r, play_bus, phase_out, rec = 0, freeze = 0,
                        pos_start = 0, pos_end = 1, scan = 1, pos_jitter = 0,
                        size = 0.1, density = 20, pitch = 1, spread = 0.5, pan = 0,
                        grain_jitter = 0, grain_pitch_spread = 0, grain_shape = 0,
                        grain_env1 = -1, grain_env2 = -1,
                        clouds_pos = 0.5, clouds_tex = 0.5, clouds_fb = 0,
                        clouds_mode = 0, clouds_lofi = 0,
                        warp_window = 0.25, warp_overlaps = 4, warp_rand = 0,
                        pv_freeze = 0;
                    var lo, hi, span, incr, phase, winPos, srcL, srcR, sig;
                    lo = pos_start.min(pos_end);
                    hi = pos_start.max(pos_end);
                    span = (hi - lo).max(0.001);
                    incr = scan * SampleDur.ir / (BufDur.kr(buf_l) * span);
                    phase = Phasor.ar(0, incr, 0, 1);
                    winPos = lo + (phase * span);
                    Out.kr(phase_out, A2K.kr(winPos));
                    srcL = BufRd.ar(1, buf_l, winPos * BufFrames.kr(buf_l), 1, 4);
                    srcR = BufRd.ar(1, buf_r, winPos * BufFrames.kr(buf_r), 1, 4);
                    // POSITIONAL args (keyword args don't survive perform on a
                    // var-held class): in, pit, pos, size, dens, tex, drywet,
                    // in_gain, spread, rvb, fb, freeze, mode, lofi. our size/
                    // density/pitch remap to Clouds' 0..1 / semitone ranges.
                    sig = cc.ar([srcL, srcR],
                        pitch.max(0.01).log2 * 12,
                        clouds_pos,
                        size.linlin(0.01, 0.5, 0.1, 0.9),
                        density.explin(1, 200, 0.05, 0.95),
                        clouds_tex, 1.0, 1.0, spread, 0.0, clouds_fb,
                        pv_freeze, clouds_mode, clouds_lofi);
                    Out.ar(play_bus, sig);
                }).add;
                hasClouds = true;
            } { arg err;
                hasClouds = false;
                ("mangler: MiClouds def failed — using GrainBuf. "
                    ++ err.errorString).postln;
            };
        });

        // ---- S8 polyphonic voices: ONE note each, spawned per press. both
        // defs share the arg set; each frees itself. THE PER-PAD SWITCH is
        // which def the allocator spawns (grain cloud vs clean slice).

        // helper: effective gate. held -> external `gate`; one-shot -> an
        // internal gate held high for `sustain` then released, so the asr
        // env's doneAction:2 frees the synth. env-driven free means sparse
        // grain gaps never premature-free a held voice.
        SynthDef(\mangler_voice_grain, {
            arg buf_l, buf_r, play_bus,
                gate = 1, one_shot = 0, sustain = 0.05,
                note_pos = 0, note_pitch = 1, amp = 0.5, pan = 0,
                atk = 0.005, rel = 0.6,
                size = 0.1, density = 20, spread = 0.5,
                grain_jitter = 0, grain_pitch_spread = 0, grain_shape = 0,
                grain_env1 = -1, grain_env2 = -1;
            var trigL, trigR, durL, durR, pchL, pchR, envSel, cloud, eGate, env, sig;
            trigL = Dust.kr(density);
            trigR = Dust.kr(density);
            durL = (size * (1 + TRand.kr(grain_jitter.neg, grain_jitter, trigL))).max(0.001);
            durR = (size * (1 + TRand.kr(grain_jitter.neg, grain_jitter, trigR))).max(0.001);
            pchL = note_pitch * (TRand.kr(grain_pitch_spread.neg, grain_pitch_spread, trigL) / 12).midiratio;
            pchR = note_pitch * (TRand.kr(grain_pitch_spread.neg, grain_pitch_spread, trigR) / 12).midiratio;
            envSel = Select.kr(grain_shape.clip(0, 2), [-1, grain_env1, grain_env2]);
            cloud = (GrainBuf.ar(2, trigL, durL, buf_l, pchL, note_pos.wrap(0, 1), 4,
                    TRand.kr(spread.neg, spread, trigL), envSel)
                + GrainBuf.ar(2, trigR, durR, buf_r, pchR, note_pos.wrap(0, 1), 4,
                    TRand.kr(spread.neg, spread, trigR), envSel)) * 0.5;
            eGate = Select.kr(one_shot, [gate, Trig.kr(Impulse.kr(0), sustain)]);
            env = EnvGen.ar(Env.asr(atk, 1, rel), eGate, doneAction: 2);
            sig = Balance2.ar(cloud[0], cloud[1], pan) * env * amp;
            Out.ar(play_bus, sig);
        }).add;

        SynthDef(\mangler_voice_slice, {
            arg buf_l, buf_r, play_bus,
                gate = 1, one_shot = 0, sustain = 0.05,
                note_pos = 0, note_pitch = 1, amp = 0.5, pan = 0,
                atk = 0.005, rel = 0.6,
                size = 0.1, density = 20, spread = 0.5,
                grain_jitter = 0, grain_pitch_spread = 0, grain_shape = 0,
                grain_env1 = -1, grain_env2 = -1;
            var l, r, eGate, env, sig;
            // clean, tight read from the slice point; no loop, no doneAction
            // here (env owns the lifetime)
            l = PlayBuf.ar(1, buf_l, note_pitch * BufRateScale.kr(buf_l), 1,
                note_pos * BufFrames.kr(buf_l), 0, 0);
            r = PlayBuf.ar(1, buf_r, note_pitch * BufRateScale.kr(buf_r), 1,
                note_pos * BufFrames.kr(buf_r), 0, 0);
            eGate = Select.kr(one_shot, [gate, Trig.kr(Impulse.kr(0), sustain)]);
            env = EnvGen.ar(Env.asr(atk, 1, rel), eGate, doneAction: 2);
            sig = Balance2.ar(l, r, pan) * env * amp;
            Out.ar(play_bus, sig);
        }).add;

        // ---- io: input, record head (with resample feedback), dry/wet, out

        SynthDef(\mangler_io, {
            arg in1, in2, out, buf_l, buf_r, play_bus, rec_phase_out, rec_amp_out,
                level = 1.0, rec = 0, rec_level = 1.0, pre_level = 0.0,
                freeze = 0, dry_wet = 0.5, resample = 0.0, regen = 0.0,
                grain_level = 1.0,
                filt_type = 0, cutoff = 20000, resonance = 0, drive = 0.0,
                delay_time = 0.3, delay_fb = 0.3, delay_mix = 0.0,
                // reverb runs in \mangler_reverb; io keeps the return mix + buses
                rev_mix = 0.0, rev_send = 0, rev_ret = 0;
            var inL, inR, wet, dry, sig, recRun, recPhase, recL, recR;
            var cf, res, pre, fbIn, dIn, dOut, delayFb, rvRet, dfmClass, mmFilter;
            var regenRun, runW, srcL, srcR, recLvl, preLvl;
            inL = In.ar(in1, 1);
            inR = In.ar(in2, 1);
            // wet = drone + ALL polyphonic voices (they Out.ar-add onto play_bus)
            wet = In.ar(play_bus, 2) * grain_level * 1.5;

            // DFM1 diode-ladder filter, guarded -> stock RLPF/RHPF/BPF fallback
            // if sc3-plugins is absent. One DFM1: LP for LP+BP, HP for HP; BP
            // high-passes the resonant LP peak into a band. filt_type 0=LP 1=HP 2=BP.
            cf = cutoff.clip(20, 20000).lag(0.05);
            // clip below DFM1's self-oscillation onset (~0.95) so max resonance
            // is very resonant but STABLE; raise toward 0.95 to let it self-osc.
            res = resonance.clip(0, 0.9);
            mmFilter = {
                var rq = (1 - (resonance * 0.92)).max(0.05);
                (RLPF.ar(wet, cf, rq) * (filt_type < 0.5))
                    + (RHPF.ar(wet, cf, rq) * ((filt_type > 0.5) * (filt_type < 1.5)))
                    + (BPF.ar(wet, cf, rq) * (1 + resonance) * (filt_type > 1.5))
            };
            dfmClass = "DFM1".asSymbol.asClass;
            wet = dfmClass.notNil.if({
                try {
                    // in, freq, res, inputgain, type(0=LP 1=HP), noiselevel
                    var d = dfmClass.ar(wet, cf, res, 1,
                        (filt_type > 0.5) * (filt_type < 1.5), 0);
                    Select.ar(filt_type > 1.5, [d, HPF.ar(d, (cf * 0.5).clip(20, 20000))])
                } { |e| mmFilter.value }
            }, { mmFilter.value });

            // S13: drive is a clean->saturated crossfade so drive=0 is a TRUE
            // bypass. it was an always-on tanh that soft-clipped even at 0,
            // colouring a fresh dry recording; now the base sound is exactly
            // the sample, and drive dials the saturation in on top.
            pre = 1 + (drive * 6);
            wet = XFade2.ar(wet, (wet * pre).tanh * pre.sqrt.reciprocal,
                (drive * 2 - 1));

            // delay feedback loop (own LocalIn/LocalOut(2); the shimmer loop
            // moved into the reverb synth).
            fbIn = LocalIn.ar(2);
            dIn = wet + (fbIn * delay_fb);
            dOut = DelayC.ar(dIn, 1.0, delay_time.clip(0.01, 1.0).lag(0.2));
            delayFb = LPF.ar(dOut, 3500).softclip;
            wet = (wet * (1 - delay_mix).sqrt) + (dOut * delay_mix.sqrt);
            LocalOut.ar(delayFb);

            // reverb + shimmer run in a spawn/free synth (\mangler_reverb, only
            // while rev_mix > 0). io sends the post-delay wet and reads the tail
            // back via InFeedback (1-block delay across the node boundary). At
            // rev_mix=0 the synth is gone, the return reads 0, output unchanged.
            Out.ar(rev_send, wet);
            rvRet = InFeedback.ar(rev_ret, 2);
            wet = (wet * (1 - rev_mix).sqrt) + (rvRet * rev_mix.sqrt);

            dry = [inL, inR];
            sig = (dry * (1 - dry_wet).sqrt) + (wet * dry_wet.sqrt);
            sig = sig * Lag.kr(level, 0.05);
            sig = Limiter.ar(sig, 0.92, 0.01);  // S9: 0.98 -> 0.92 DAC headroom
            recRun = rec * (1 - freeze);
            recPhase = Phasor.ar(0, recRun * SampleDur.ir / BufDur.kr(buf_l), 0, 1);
            Out.kr(rec_phase_out, A2K.kr(recPhase));
            recL = (inL * (1 - resample)) + (sig[0] * resample);
            recR = (inR * (1 - resample)) + (sig[1] * resample);
            // regen: run the record head continuously and crossfade the OUTPUT
            // back into the buffer (self-mangle). BOUNDED (convex crossfade +
            // LeakDC + master Limiter); bit-identical to no-regen at regen=0.
            // manual rec and freeze both suspend it.
            regenRun = (regen > 0) * (1 - rec) * (1 - freeze);
            runW = recRun.max(regenRun);
            srcL = (recL * (1 - regenRun)) + (LeakDC.ar(sig[0]) * regenRun);
            srcR = (recR * (1 - regenRun)) + (LeakDC.ar(sig[1]) * regenRun);
            // record-safety limiter: transparent below 0.99, stops a hot take
            // hard-clipping into the buffer.
            srcL = Limiter.ar(srcL, 0.99, 0.002);
            srcR = Limiter.ar(srcR, 0.99, 0.002);
            recLvl = (rec_level * (1 - regenRun)) + (regen * regenRun);
            preLvl = (pre_level * (1 - regenRun)) + ((1 - regen) * regenRun);
            RecordBuf.ar(srcL, buf_l, 0, recLvl, preLvl, runW, 1);
            RecordBuf.ar(srcR, buf_r, 0, recLvl, preLvl, runW, 1);
            Out.kr(rec_amp_out,
                Amplitude.kr(recL.abs.max(recR.abs) * rec_level, 0.01, 0.1));
            Out.ar(out, sig);
        }).add;

        // reverb + shimmer synth (spawned by updateReverb while rev_mix > 0).
        // reads io's post-delay wet, returns the JPverb tail; shimmer recirculates
        // through this synth's own LocalIn/LocalOut. JPverb guarded -> FreeVerb.
        SynthDef(\mangler_reverb, {
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
                // in, t60, damp, size, earlyDiff, modDepth, modFreq,
                // low, mid, high, lowcut, highcut
                jpClass.ar(revIn.sum * 0.5, rev_decay, rev_damp, rev_size,
                    rev_early, rev_moddepth, rev_modfreq,
                    rev_low, rev_mid, rev_high, rev_lowcut, rev_highcut)
            }, {
                var rs = rev_decay.linlin(0.1, 30, 0.1, 0.97);
                [FreeVerb.ar(revIn[0], 1.0, rs, rev_damp),
                    FreeVerb.ar(revIn[1], 1.0, rs, rev_damp)] * 2
            });
            // pitch the tail (semitones -> ratio), band-limit so the octave
            // stack stays a halo (HPF kills DC/rumble build-up, LPF tames the
            // metallic hiss), softclip bounds runaway. STEREO shimmer — a
            // PitchShift per channel — for a wide halo.
            ratio = (shimmer_pitch.round(1) / 12.0);
            ratio = (2 ** ratio).clip(0.25, 4);
            pitched = PitchShift.ar(rv, 0.2, ratio, 0, 0.01);
            pitched = LPF.ar(HPF.ar(pitched, 120), shimmer_tone.clip(500, 12000));
            shimOut = (pitched * (shimmer > 0)).softclip;
            LocalOut.ar(shimOut);
            Out.ar(out_bus, rv);
        }).add;

        s.sync;

        // playback group first, io after it, so io reads play_bus in-block.
        // polyphonic voices also spawn into playGroup (before io) -> they add
        // onto play_bus and pass through the io FX chain like the drone.
        playGroup = Group.new(context.xg);
        ioSynth = Synth.new(\mangler_io, [
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
        ], playGroup, \addAfter);

        // every float control as one command; rec/freeze fan out to both synths;
        // revParams route to \mangler_reverb; rev_mix also spawns/frees it.
        allKeys = (ioKeys ++ playParams.keys.asArray ++ revParams.keys.asArray).asSet;
        allKeys.do({ arg name;
            this.addCommand(name, "f", { arg msg;
                var v = msg[1];
                ioKeys.includes(name).if({ ioSynth.set(name, v) });
                revParams.includesKey(name).if({
                    revParams[name] = v;
                    revSynth.notNil.if({ revSynth.set(name, v) });
                });
                playParams.includesKey(name).if({
                    playParams[name] = v;
                    playSynth.notNil.if({ playSynth.set(name, v) });
                });
                (name == \rev_mix).if({ this.updateReverb(v) });
            });
        });

        this.addCommand(\mode, "i", { arg msg;
            this.setMode(msg[1]);
        });

        // ---- S8 polyphony commands. note_on/one_shot gained a trailing AMP
        // (per-note level) — an ARITY change, NOT a new command, so the
        // fingerprint COUNT is unchanged. amp nil (an old 4-arg caller) -> the
        // voiceParams default, so it degrades cleanly both ways.
        this.addCommand(\note_on, "iffff", { arg msg;
            this.noteOn(msg[1], msg[2], msg[3], msg[4], msg[5]);
        });
        this.addCommand(\note_off, "i", { arg msg;
            this.noteOff(msg[1]);
        });
        this.addCommand(\note_one_shot, "ffff", { arg msg;
            this.noteOneShot(msg[1], msg[2], msg[3], msg[4]);
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
            bufL.zero;
            bufR.zero;
            "mangler: engine buffer cleared".postln;
        });

        // load any wav/aiff into the buffer. no SR conversion — a 44.1k file at
        // the 48k server plays ~9% fast (a varispeed).
        this.addCommand(\read_file, "s", { arg msg;
            var path = msg[1].asString;
            var sf = SoundFile.new;
            sf.openRead(path).if({
                var nch = sf.numChannels;
                var frames = sf.numFrames.min(s.sampleRate * 60);
                sf.close;
                bufL.zero;
                bufR.zero;
                bufL.readChannel(path, 0, frames, 0, false, [0]);
                // a mono file feeds BOTH sides from channel 0
                bufR.readChannel(path, 0, frames, 0, false, [(nch - 1).min(1)]);
                ("mangler: loaded " ++ path ++ " — " ++ frames ++ " frames, "
                    ++ nch ++ "ch").postln;
            }, {
                ("mangler: CANNOT READ " ++ path).postln;
            });
        });

        // persist the live take across PSET save/load: write bufL/bufR to a
        // private L/R pair (16-bit wav, async /b_write, bounded, core UGens).
        // numFrames bounds the write to the take from frame 0; n <= 0 = whole buffer.
        this.addCommand(\write_take, "si", { arg msg;
            var stem = msg[1].asString;
            var n = (msg.size > 2).if({ msg[2].asInteger }, { -1 });
            if(n <= 0, { n = -1 });
            bufL.write(stem ++ "_L.wav", "wav", "int16", n);
            bufR.write(stem ++ "_R.wav", "wav", "int16", n);
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
                var frames = sf.numFrames.min(s.sampleRate * 60);
                sf.close;
                bufL.zero;
                bufR.zero;
                bufL.readChannel(pathL, 0, frames, 0, false, [0]);
                bufR.readChannel(pathR, 0, frames, 0, false, [0]);
                ("mangler: restored take " ++ stem ++ " — "
                    ++ frames ++ " frames").postln;
            }, {
                ("mangler: CANNOT READ take " ++ stem).postln;
            });
        });

        this.addPoll(\play_phase, {
            phaseBus.getSynchronous;
        });
        this.addPoll(\rec_phase, {
            recPhaseBus.getSynchronous;
        });
        this.addPoll(\rec_amp, {
            recAmpBus.getSynchronous;
        });

        // start in GRAIN so the instrument behaves like S1 out of the box
        this.setMode(1);
    }

    free {
        activeVoices.notNil.if({ activeVoices.do({ arg v; v.notNil.if({ v.free }) }) });
        playSynth.notNil.if({ playSynth.free });
        revSynth.notNil.if({ revSynth.free });
        ioSynth.free;
        playGroup.free;
        bufL.free;
        bufR.free;
        grainEnv1.free;
        grainEnv2.free;
        playBus.free;
        revSendBus.free;
        revRetBus.free;
        phaseBus.free;
        recPhaseBus.free;
        recAmpBus.free;
    }
}
