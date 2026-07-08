// Engine_Mangler.sc
// THE ONLY engine file for the `mangler` norns script.
//
// STAGE 4 — full instrument: mode-switched playback voice + FILTER/DELAY/
// REVERB on the wet path in the io synth (each FX with its own dry/wet).
// Architecture: one persistent io synth (input, record head, dry/wet mix,
// resample feedback, FX chain, output) + ONE playback (drone) synth at a
// time, spawned/freed by `mode`: OFF(0) / GRAIN(1) / WARP(2) / PV(3), PLUS
// (S8) a polyphonic voice layer that coexists with the drone.
//   GRAIN — GrainBuf clouds (S1 behavior)
//   WARP  — Warp1 time-stretch: `scan` is speed, `pitch` independent
//   PV    — phase-vocoder FFT->PV_MagFreeze->IFFT (`pv_freeze` holds spectrum)
// Playback synths write to play_bus + phase_out; io reads play_bus.
//
// HARD RULE: there must be exactly one `Engine_Mangler` class under dust/code.
// A duplicate makes every norns script hang forever on "LOADING".
//
// S5 GAIN + TONE PASS (on-device gate pending): stock/core UGens only, one
// gate, fingerprint 31 (only `drive` new). grain overlap comp, equal-power
// FX mixes, `drive` tanh stage, master Limiter; interp 2->4, delay-feedback
// LPF, resonance floor 0.05 (mirrored in lib/mpages.lua — keep in sync).
// S6 REVERB (same batch, still fingerprint 31): FreeVerb -> JPverb guarded
// by a build-time .asClass check so a missing sc3-plugins falls back instead
// of bricking.
//
// S7 GRANULAR CHARACTER PASS (gate pending, fingerprint 31 -> 34): GRAIN
// voice de-mechanised, stock UGens only. +3 commands (grain_jitter,
// grain_pitch_spread, grain_shape).
//   * triggers Impulse.kr -> Dust.kr: kills periodic buzz + decorrelates L/R
//   * grain_jitter: per-grain size randomisation (default 0 = identical)
//   * grain_pitch_spread: per-grain detune in SEMITONES (default 0 = identical)
//   * grain_shape: 0 built-in Hann / 1 Welch bell / 2 percussive; two env
//     buffers filled in alloc BEFORE s.sync (DO NOT move that sync).
//
// S8 POLYPHONIC VOICE ENGINE (gate pending, fingerprint 34 -> 40): the
// per-note / per-pad layer scoped 2026-07-02. drone modes untouched; voices
// spawn into playGroup, Out.ar (additive) onto play_bus, so they mix with
// the drone and pass through the io FX chain. +6 commands (note_on,
// note_off, note_one_shot, voices, voice_atk, voice_rel).
//   * TWO voice SynthDefs, allocator picks by per-pad type (THE SWITCH):
//       type 0 -> mangler_voice_grain : S7 grain cloud, fixed at note_pos —
//                 matches the drone sound. reuses size/density/spread/
//                 grain_* from the live playParams so it tracks the drone.
//       type 1 -> mangler_voice_slice : PlayBuf slice from note_pos —
//                 clean/tight, better for kicks & one-shots.
//   * MPC-tight: fresh Synth per note, sounds a control-block (~1.5ms) after
//     press, NOT a loop wrap. Env.asr gated + doneAction 2 frees on release
//     (grain gaps can't premature-free it — env-driven, not silence-driven).
//     one_shot uses a self-terminating internal gate (Trig held `sustain`).
//   * polyphony cap = `voices` param (default 8); at cap, OLDEST voice is
//     release-stolen. held notes tracked by id for note_off; one-shots are
//     fire-and-forget.
//   Lua side (separate, in the script): a PADS page calls
//     engine.note_on(id,pos,pitch,type) / engine.note_off(id) /
//     engine.note_one_shot(pos,pitch,type) / engine.voices(n). type is the
//     per-pad grain/slice toggle. NOT built here.
//
// NB (learned in S0/S1): context.in_b is an ARRAY of two mono busses; out_b
// is one stereo bus. An error inside alloc means doneCallback never fires and
// every load hangs on "loading" — errors land in maiden's SC tab. After
// editing: SYSTEM > RESTART, then check the command count in the load log
// (S8/S9 fingerprint: count 40 — S9 is gain constants only, no new commands).
//
// S9 HEADROOM (gate pending, still fingerprint 40): poly voices summing on
// play_bus were slamming the master limiter into pumping on chords. per-voice
// amp 0.5 -> 0.3 + limiter ceiling 0.98 -> 0.92. no command change.
//
// S10 FULL JPVERB (gate pending, fingerprint 40 -> 50): the reverb block now
// wraps JPverb's ENTIRE attribute set as args (no hardcoding) — +10 commands
// (rev_decay/damp/early/moddepth/modfreq/low/mid/high/lowcut/highcut). Still
// guarded (.asClass) so a missing sc3-plugins -> FreeVerb fallback, no brick.
//
// S11 -> 55 (clouds), S14 stays 55 (PLAY drone adds no command). S15 SHIMMER
// (gate pending, fingerprint 55 -> 58): +3 commands (shimmer/shimmer_pitch/
// shimmer_tone). the reverb gained a pitch-shifted feedback loop; the delay's
// LocalIn/LocalOut MERGED into ONE LocalIn.ar(4) (SC allows one pair) — delay
// on ch 0-1, shimmer on ch 2-3, a single deferred LocalOut. shimmer=0 is
// bit-identical to the old dry reverb (PitchShift still runs, output gated 0).

Engine_Mangler : CroneEngine {
    var <ioSynth, <playSynth;
    var <playGroup;
    var <bufL, <bufR;
    var <grainEnv1, <grainEnv2;
    var <playBus;
    var <phaseBus, <recPhaseBus, <recAmpBus;
    var <playParams;
    var <ioKeys;
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

    // ---- S8 voice allocation ------------------------------------------------
    // shared spawn args: buffers, bus, envelope, and the CURRENT drone grain
    // params so a grain-cloud voice tracks the drone's character.
    voiceArgs { arg pos, pitch, oneShot;
        ^[
            \buf_l, bufL, \buf_r, bufR, \play_bus, playBus,
            \note_pos, pos, \note_pitch, pitch,
            \gate, 1, \one_shot, oneShot,
            \amp, voiceParams[\amp],
            \atk, voiceParams[\voice_atk], \rel, voiceParams[\voice_rel],
            \grain_env1, grainEnv1, \grain_env2, grainEnv2,
            \size, playParams[\size], \density, playParams[\density],
            \spread, playParams[\spread],
            \grain_jitter, playParams[\grain_jitter],
            \grain_pitch_spread, playParams[\grain_pitch_spread],
            \grain_shape, playParams[\grain_shape]
        ];
    }

    noteOn { arg id, pos, pitch, type;
        var def, syn;
        // enforce polyphony cap: release-steal the oldest held voice
        (voiceOrder.size >= maxVoices).if({
            var oldId = voiceOrder.removeAt(0);
            var old = activeVoices[oldId];
            old.notNil.if({ old.set(\gate, 0) });
            activeVoices.removeAt(oldId);
        });
        def = (type > 0.5).if({ \mangler_voice_slice }, { \mangler_voice_grain });
        syn = Synth.new(def, this.voiceArgs(pos, pitch, 0), playGroup);
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

    noteOneShot { arg pos, pitch, type;
        var def = (type > 0.5).if({ \mangler_voice_slice }, { \mangler_voice_grain });
        // fire-and-forget: internal gate self-terminates, synth self-frees
        Synth.new(def, this.voiceArgs(pos, pitch, 1), playGroup);
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
        ioKeys = [\level, \rec, \rec_level, \pre_level, \freeze,
            \dry_wet, \resample, \grain_level,
            \filt_type, \cutoff, \resonance, \drive,
            \delay_time, \delay_fb, \delay_mix,
            \rev_size, \rev_mix,
            // S10 full-JPverb attributes
            \rev_decay, \rev_damp, \rev_early, \rev_moddepth, \rev_modfreq,
            \rev_low, \rev_mid, \rev_high, \rev_lowcut, \rev_highcut,
            // S15 shimmer: pitch-shifted reverb feedback
            \shimmer, \shimmer_pitch, \shimmer_tone];

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

        // ---- S11: MiClouds granular drone (mi-UGens). GUARDED TWO WAYS so it
        // can never brick LOADING: the class is resolved via .asClass (the .sc
        // compiles fine without mi-UGens — no literal MiClouds reference), and
        // the whole def is wrapped in `try` so a wrong graph/arg set sets
        // hasClouds=false and falls back to GrainBuf instead of failing alloc.
        // architecture: a BufRd scrubs the recorded window (the same scan/pos
        // Phasor the GrainBuf drone uses) and feeds Clouds; freeze reuses
        // pv_freeze so the STRETCH PVFZ key freezes clouds too.
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
                freeze = 0, dry_wet = 0.5, resample = 0.0, grain_level = 1.0,
                filt_type = 0, cutoff = 20000, resonance = 0, drive = 0.0,
                delay_time = 0.3, delay_fb = 0.3, delay_mix = 0.0,
                rev_size = 1.0, rev_mix = 0.0,
                // S10: JPverb's full attribute set as args (no hardcoding)
                rev_decay = 2.0, rev_damp = 0.3, rev_early = 0.7,
                rev_moddepth = 0.1, rev_modfreq = 2.0,
                rev_low = 1.0, rev_mid = 1.0, rev_high = 1.0,
                rev_lowcut = 500, rev_highcut = 2000,
                // S15 shimmer: pitch-shifted reverb feedback
                shimmer = 0.0, shimmer_pitch = 12.0, shimmer_tone = 4500.0;
            var inL, inR, wet, dry, sig, recRun, recPhase, recL, recR;
            var cf, rq, lp, hp, bp, isLp, isHp, isBp, pre, fbIn, dIn, dOut, rv, jpClass;
            var delayFb, shimFb, revIn, ratio, pitched, shimOut;
            inL = In.ar(in1, 1);
            inR = In.ar(in2, 1);
            // wet = drone + ALL polyphonic voices (they Out.ar-add onto play_bus)
            wet = In.ar(play_bus, 2) * grain_level * 1.5;

            cf = cutoff.clip(20, 20000).lag(0.05);
            rq = (1 - (resonance * 0.92)).max(0.05);
            lp = RLPF.ar(wet, cf, rq);
            hp = RHPF.ar(wet, cf, rq);
            bp = BPF.ar(wet, cf, rq) * (1 + resonance);
            isLp = (filt_type < 0.5);
            isHp = (filt_type > 0.5) * (filt_type < 1.5);
            isBp = (filt_type > 1.5);
            wet = (lp * isLp) + (hp * isHp) + (bp * isBp);

            // S13: drive is a clean->saturated crossfade so drive=0 is a TRUE
            // bypass. it was an always-on tanh that soft-clipped even at 0,
            // colouring a fresh dry recording; now the base sound is exactly
            // the sample, and drive dials the saturation in on top.
            pre = 1 + (drive * 6);
            wet = XFade2.ar(wet, (wet * pre).tanh * pre.sqrt.reciprocal,
                (drive * 2 - 1));

            // S15: ONE feedback bus for BOTH loops. SC allows a single
            // LocalIn/LocalOut pair per SynthDef, so the delay (channels 0-1)
            // and the shimmer recirculation (channels 2-3) share it, and the
            // single LocalOut is DEFERRED to the end of the block (after the
            // shimmer signal exists). delay writeback is computed here.
            fbIn = LocalIn.ar(4);
            dIn = wet + (fbIn[0..1] * delay_fb);
            dOut = DelayC.ar(dIn, 1.0, delay_time.clip(0.01, 1.0).lag(0.2));
            delayFb = LPF.ar(dOut, 3500).softclip;
            wet = (wet * (1 - delay_mix).sqrt) + (dOut * delay_mix.sqrt);

            // S10/S15: FULL JPverb (guarded) wrapped in a SHIMMER feedback
            // loop — the reverb tail, pitched up and band-limited, recirculates
            // into the reverb INPUT, so it climbs in octaves into a pad. gated
            // so shimmer=0 is bit-for-bit the old dry reverb (loop writes 0,
            // revIn==wet). missing plugin -> FreeVerb fallback, no brick.
            shimFb = fbIn[2..3];
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
            // metallic hiss), softclip bounds runaway like the delay's writeback
            ratio = (shimmer_pitch.round(1) / 12.0);
            ratio = (2 ** ratio).clip(0.25, 4);
            pitched = PitchShift.ar(rv, 0.2, ratio, 0, 0.01);
            pitched = LPF.ar(HPF.ar(pitched, 120), shimmer_tone.clip(500, 12000));
            shimOut = (pitched * (shimmer > 0)).softclip;
            wet = (wet * (1 - rev_mix).sqrt) + (rv * rev_mix.sqrt);

            // close BOTH feedback loops with the one allowed LocalOut
            LocalOut.ar(delayFb ++ shimOut);

            dry = [inL, inR];
            sig = (dry * (1 - dry_wet).sqrt) + (wet * dry_wet.sqrt);
            sig = sig * Lag.kr(level, 0.05);
            sig = Limiter.ar(sig, 0.92, 0.01);  // S9: 0.98 -> 0.92 DAC headroom
            recRun = rec * (1 - freeze);
            recPhase = Phasor.ar(0, recRun * SampleDur.ir / BufDur.kr(buf_l), 0, 1);
            Out.kr(rec_phase_out, A2K.kr(recPhase));
            recL = (inL * (1 - resample)) + (sig[0] * resample);
            recR = (inR * (1 - resample)) + (sig[1] * resample);
            RecordBuf.ar(recL, buf_l, 0, rec_level, pre_level, recRun, 1);
            RecordBuf.ar(recR, buf_r, 0, rec_level, pre_level, recRun, 1);
            Out.kr(rec_amp_out,
                Amplitude.kr(recL.abs.max(recR.abs) * rec_level, 0.01, 0.1));
            Out.ar(out, sig);
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
        ], playGroup, \addAfter);

        // every float control as one command; rec/freeze fan out to both synths
        allKeys = (ioKeys ++ playParams.keys.asArray).asSet;
        allKeys.do({ arg name;
            this.addCommand(name, "f", { arg msg;
                var v = msg[1];
                ioKeys.includes(name).if({ ioSynth.set(name, v) });
                playParams.includesKey(name).if({
                    playParams[name] = v;
                    playSynth.notNil.if({ playSynth.set(name, v) });
                });
            });
        });

        this.addCommand(\mode, "i", { arg msg;
            this.setMode(msg[1]);
        });

        // ---- S8 polyphony commands
        this.addCommand(\note_on, "ifff", { arg msg;
            this.noteOn(msg[1], msg[2], msg[3], msg[4]);
        });
        this.addCommand(\note_off, "i", { arg msg;
            this.noteOff(msg[1]);
        });
        this.addCommand(\note_one_shot, "fff", { arg msg;
            this.noteOneShot(msg[1], msg[2], msg[3]);
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
        ioSynth.free;
        playGroup.free;
        bufL.free;
        bufR.free;
        grainEnv1.free;
        grainEnv2.free;
        playBus.free;
        phaseBus.free;
        recPhaseBus.free;
        recAmpBus.free;
    }
}
