// Probes of the REAL engine's SynthDefs (lib/Engine_Four.sc), rendered offline.
// Run with run_probe.sh <work> <tag> probe.scd. With FOUR_PLUGIN_DIR set the
// engine builds its FourStretch defs.
(
var dir = "BENCH_DIR".getenv, tag = "BENCH_TAG".getenv ? "run";
var s = FakeServer(\fake, NetAddr("127.0.0.1", 57999));
var ctx = (server: s, xg: Group.basicNew(s, 1),
    in_b: [Bus.audio(s, 1), Bus.audio(s, 1)], out_b: Bus.audio(s, 2));
var plug = "FOUR_PLUGIN_DIR".getenv.notNil;
Engine_Four.new(ctx, { arg eng;
    var def = { |n| var d = SynthDescLib.global[n]; d.notNil.if({ d.def.asBytes }) };
    var opts = ServerOptions.new.memSize_(262144).numBuffers_(64);
    var copy = SynthDef(\copy, { |from, to| Out.ar(to, In.ar(from, 2)) });
    var imp = SynthDef(\imp, { |out| Out.ar(out, Impulse.ar(0) ! 2) });
    var noise = SynthDef(\noise, { |out, amp = 0.1| Out.ar(out, [WhiteNoise.ar(amp), WhiteNoise.ar(amp)]) });
    var sine = SynthDef(\sine, { |out, freq = 1000, amp = 0.25| Out.ar(out, SinOsc.ar(freq) * amp ! 2) });
    var burst = SynthDef(\burst, { |out, dur = 0.3|
        Out.ar(out, [WhiteNoise.ar(0.3), WhiteNoise.ar(0.3)] * EnvGen.ar(Env.linen(0.005, dur, 0.005))) });
    var limsrc = SynthDef(\limsrc, { |out|
        var base = (SinOsc.ar(200) * 0.4) + (SinOsc.ar(40) * 0.15) + (SinOsc.ar(100) * 0.15);
        var b = SinOsc.ar(1000) * 0.9 * EnvGen.ar(Env([0, 0, 1, 1, 0], [1.5, 0.005, 0.3, 0.005]));
        Out.ar(out, [base + b, base]) });
    // the erosion head with its place counted in whole frames (the candidate
    // fix; the engine's own law since four's twenty-second change)
    var erodeExact = SynthDef(\erode_exact, {
        arg buf_l, buf_r, gate = 1, pos_start = 0, pos_end = 1,
            erode = 0, wear = 0.5, level = 1, rec = 0, freeze = 0;
        var lo, hi, span, frames, loF, spanF, run, head, idx, env, eff, wearF, rawL, rawR;
        lo = Lag2.ar(K2A.ar(pos_start.min(pos_end)), 0.08);
        hi = Lag2.ar(K2A.ar(pos_start.max(pos_end)), 0.08);
        span = (hi - lo).max(0.001);
        frames = BufFrames.kr(buf_l);
        loF = (lo * frames).round;
        spanF = (span * frames).round.max(64);
        run = (1 - rec) * (1 - freeze) * (level > 0.001);
        head = Phasor.ar(0, run, 0, spanF);
        idx = loF + head;
        env = EnvGen.kr(Env.asr(0.05, 1, 0.05), gate, doneAction: 2);
        eff = erode.clip(0, 1).lag(0.05) * env * run;
        wearF = wear.clip(0, 1).linexp(0, 1, 9000, 1200);
        rawL = BufRd.ar(1, buf_l, idx, 1, 1);
        rawR = BufRd.ar(1, buf_r, idx, 1, 1);
        BufWr.ar((rawL * (1 - eff)) + (LPF.ar(rawL, wearF) * 0.996 * eff), buf_l, idx);
        BufWr.ar((rawR * (1 - eff)) + (LPF.ar(rawR, wearF) * 0.996 * eff), buf_r, idx);
    });
    var jobs, run, std;
    std = [[0.0, [\d_recv, copy.asBytes]], [0.0, [\d_recv, imp.asBytes]], [0.0, [\d_recv, noise.asBytes]],
        [0.0, [\d_recv, sine.asBytes]], [0.0, [\d_recv, burst.asBytes]], [0.0, [\d_recv, limsrc.asBytes]],
        [0.0, [\d_recv, erodeExact.asBytes]]];
    ("COMMANDS " ++ eng.cmdNames.size).postln;
    "FOUR_PLUGIN_DIR".getenv.notNil.if({
        opts.ugenPluginsPath = [Platform.resourceDir +/+ "plugins", "FOUR_PLUGIN_DIR".getenv];
    });
    jobs = [
        // 1. the filter: an impulse through each case (stock branch on the Mac)
        [\filt, 1.0, 16, [],
            [[0.0, [\d_recv, def.(\four_filt_lo)]], [0.0, [\d_recv, def.(\four_filt_hi)]]]
            ++ [[\four_filt_lo, 20000, 0, 0], [\four_filt_lo, 1000, 0, 0], [\four_filt_lo, 1000, 0.9, 0],
                [\four_filt_hi, 1000, 0, 1], [\four_filt_hi, 1000, 0.9, 1], [\four_filt_lo, 1000, 0.5, 2],
                [\four_filt_lo, 1000, 0, 2], [\four_filt_lo, 19000, 0, 0]].collect({ |c, i|
                [[0.001, [\s_new, c[0], 1100 + i, 1, 0, \sbus, 100 + (i * 2), \pbus, i * 2,
                    \cutoff, c[1], \resonance, c[2], \filt_type, c[3]]],
                 [0.1, [\s_new, \imp, 1000 + i, 0, 0, \out, 100 + (i * 2)]]] }).flatten(1)],
        // 2. io: the master limiter (out 0, 1) and the record path (written to files)
        [\lim, 3.6, 2, [[0, 3.6], [1, 3.6]],
            [[0.0, [\d_recv, def.(\four_io)]],
             [0.001, [\s_new, \limsrc, 1000, 0, 0, \out, 60]],
             [0.001, [\s_new, \four_io, 1001, 1, 0, \dub_out, 1000, \in1, 60, \in2, 61, \out, 0, \buf_l, 0, \buf_r, 1,
                \play_bus, 70, \rec_phase_out, 0, \rec_amp_out, 1, \dry_wet, 0, \level, 1,
                \lane_bus, 72, \dly_send, 74, \dly_ret, 76, \rev_send, 78, \rev_ret, 80, \t2_ret, 82,
                \lanes_dly, 84, \lanes_rev, 86, \own_out, 88, \rec_level, 1, \pre_level, 0]],
             [0.5, [\n_set, 1001, \rec, 1]],
             [3.4, [\n_set, 1001, \rec, 0]],
             [3.55, [\b_write, 0, dir +/+ tag ++ "_limrecL.wav", "wav", "float"]],
             [3.55, [\b_write, 1, dir +/+ tag ++ "_limrecR.wav", "wav", "float"]]]],
        // 3. the shimmer loop: [decay, shimmer, pitch], a noise burst at 0.1 s
        [\shim, 30, 12, [],
            [[0.0, [\d_recv, def.(\four_reverb)]], [0.0, [\d_recv, def.(\four_shimmer)]],
             [0.1, [\s_new, \burst, 900, 0, 0, \out, 100]]]
            // the shimmer is a synth of its own after each reverb, as the engine
            // spawns it (none at shimmer 0), on its own feedback pair
            ++ [[30, 0.95, 0], [30, 0.95, 12], [30, 0.95, -12], [2, 0.95, 0], [30, 0, 0], [8, 0.7, 0]].collect({ |c, i|
                [0.01, [\s_new, \four_reverb, 1000 + i, 1, 0, \in_bus, 100, \out_bus, i * 2,
                    \shim_bus, 300 + (i * 2), \shim_on, 1, \rev_decay, c[0]]] })
            ++ [[30, 0.95, 0], [30, 0.95, 12], [30, 0.95, -12], [2, 0.95, 0], [30, 0, 0], [8, 0.7, 0]].collect({ |c, i|
                (c[1] > 0).if({ [0.02, [\s_new, \four_shimmer, 1100 + i, 3, 1000 + i, \in_bus, i * 2,
                    \out_bus, 300 + (i * 2), \shimmer, c[1], \shimmer_pitch, c[2]]] }, { nil }) }).reject(_.isNil)],
        // 4. the room's knobs on a live synth: A is set at 1 s, B is left, C starts at
        // size 2, D starts at size 4 (the knob's top), E at 2.1
        [\rsize, 5, 10, [],
            [[0.0, [\d_recv, def.(\four_reverb)]]]
            ++ [1, 1, 2, 4, 2.1].collect({ |z, i|
                [0.01, [\s_new, \four_reverb, 1000 + i, 1, 0, \in_bus, 100, \out_bus, i * 2,
                    \rev_size, z, \rev_decay, 2]] })
            ++ [[1.0, [\n_set, 1000, \rev_size, 2, \rev_early, 0.1, \rev_moddepth, 1, \rev_modfreq, 9,
                    \rev_low, 0.2, \rev_mid, 0.3, \rev_high, 0.2, \rev_lowcut, 100, \rev_highcut, 10000]]]
            ++ (0..6).collect({ |k| [1.5 + (k * 0.5), [\s_new, \burst, 900 + k, 0, 0, \out, 100, \dur, 0.01]] })],
        // 5. the erosion head: the engine's (bufs 0..3) and the frame count (bufs 4..7),
        // late in the buffer (0.9 to 0.98) and early (0.05 to 0.13)
        [\erode, 12.2, 2, [[0, "long5k.wav"], [1, "long5k.wav"], [2, "long5k.wav"], [3, "long5k.wav"],
                [4, "long5k.wav"], [5, "long5k.wav"], [6, "long5k.wav"], [7, "long5k.wav"]],
            [[0.0, [\d_recv, def.(\four_erode)]],
             [0.01, [\s_new, \four_erode, 1000, 0, 0, \buf_l, 0, \buf_r, 1, \pos_start, 0.9, \pos_end, 0.98, \erode, 1]],
             [0.01, [\s_new, \four_erode, 1001, 0, 0, \buf_l, 2, \buf_r, 3, \pos_start, 0.05, \pos_end, 0.13, \erode, 1]],
             [0.01, [\s_new, \erode_exact, 1002, 0, 0, \buf_l, 4, \buf_r, 5, \pos_start, 0.9, \pos_end, 0.98, \erode, 1]],
             [0.01, [\s_new, \erode_exact, 1003, 0, 0, \buf_l, 6, \buf_r, 7, \pos_start, 0.05, \pos_end, 0.13, \erode, 1]],
             [12.0, [\b_write, 0, dir +/+ tag ++ "_ero_late.wav", "wav", "float"]],
             [12.0, [\b_write, 2, dir +/+ tag ++ "_ero_early.wav", "wav", "float"]],
             [12.0, [\b_write, 4, dir +/+ tag ++ "_erox_late.wav", "wav", "float"]],
             [12.0, [\b_write, 6, dir +/+ tag ++ "_erox_early.wav", "wav", "float"]]]],
        // (6, a mode change, is probe9.scd since the fifty-first change)
        // 7. the effects' gain: [source bus, def, type, amt, rate]
        [\flres, 6, 16, [],
            [[0.0, [\d_recv, def.(\four_fx_flange) ? copy.asBytes]], [0.0, [\d_recv, def.(\four_fx_mod)]],
             [0.0, [\d_recv, def.(\four_fx_reson)]], [0.0, [\d_recv, def.(\four_fx_echo)]],
             [0.001, [\s_new, \noise, 900, 0, 0, \out, 40]],
             [0.001, [\s_new, \sine, 901, 0, 0, \out, 44, \freq, 261.6256, \amp, 0.25]]]
            ++ [[40, \four_fx_flange, 2, 1, 0.5], [40, \four_fx_mod, 2, 1, 0.5], [40, \four_fx_flange, 2, 0, 0.5],
                [44, \four_fx_reson, 4, 1, 0.5], [40, \four_fx_reson, 4, 1, 0.5], [40, \four_fx_echo, 6, 1, 0.5],
                [40, nil, 0, 0, 0], [44, nil, 0, 0, 0]].collect({ |c, i|
                [[0.002, [\s_new, \copy, 1000 + i, 1, 0, \from, c[0], \to, 80 + (i * 2)]]]
                ++ (c[1].notNil and: { plug or: { c[1] != \four_fx_flange } }).if({
                    [[0.003, [\s_new, c[1], 1100 + i, 1, 0, \pbus, 80 + (i * 2), \type, c[2], \amt, c[3], \rate, c[4]]]] }, { [] })
                ++ [[0.004, [\s_new, \copy, 1200 + i, 1, 0, \from, 80 + (i * 2), \to, i * 2]]] }).flatten(1)],
        // 8. the delay's shortest times: a click at 0.5 s, feedback 0
        [\bbd, 1.5, 8, [],
            [[0.0, [\d_recv, def.(\four_delay)]],
             [0.5, [\s_new, \imp, 900, 0, 0, \out, 40]]]
            ++ [0.01, 0.02, 0.043, 0.1].collect({ |t, i|
                [0.01, [\s_new, \four_delay, 1000 + i, 1, 0, \in_bus, 40, \out_bus, i * 2,
                    \delay_time, t, \delay_fb, 0, \delay_mix, 1]] })],
        // 9. GRAIN against PLAY on a noise take, the fold at pitch 2, PLAY at scan 0
        [\grain, 6, 10, [[0, "noiseL60.wav"], [1, "noiseR60.wav"], [2, "long5k.wav"], [3, "long5k.wav"]],
            [[0.0, [\d_recv, def.(\four_grain)]], [0.0, [\d_recv, def.(\four_play)]]]
            ++ [[\four_grain, 0, 1, 1, 0.3], [\four_play, 0, 1, 1, 0.3],
                [\four_grain, 2, 2, 1, 0.3], [\four_play, 2, 2, 1, 0.3], [\four_play, 0, 1, 0, 0.3]].collect({ |c, i|
                [0.001, [\s_new, c[0], 1000 + i, 0, 0, \buf_l, c[1], \buf_r, c[1] + 1,
                    \play_bus, i * 2, \phase_out, 10 + i, \pos_start, c[4], \pos_end, c[4] + 0.2,
                    \pitch, c[2], \scan, c[3], \spread, 0, \level, 1]] })]
    ];
    run = { |i|
        if (i >= jobs.size) { "PROBE_DONE".postln; 0.exit } {
            var name, dur, nch, bufs, msgs, score;
            #name, dur, nch, bufs, msgs = jobs[i];
            score = std ++ bufs.collect({ |b|
                    b[1].isString.if({ [0.0, [\b_allocRead, b[0], dir +/+ b[1]]] },
                        { [0.0, [\b_alloc, b[0], (b[1] * 48000).asInteger, 1]] }) })
                ++ msgs ++ [[dur, [\c_set, 0, 0]]];
            score = score.sort({ |a, b| a[0] < b[0] });
            Score(score).recordNRT(dir +/+ tag ++ "_" ++ name ++ ".osc",
                dir +/+ tag ++ "_" ++ name ++ ".wav",
                sampleRate: 48000, headerFormat: "WAV", sampleFormat: "float",
                options: opts.numOutputBusChannels_(nch),
                duration: dur, action: { ("done " ++ name).postln; run.(i + 1) });
        };
    };
    run.(0);
});
)
