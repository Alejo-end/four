// Probes for the addendum. run_probe.sh <work> <tag> probe4.scd
(
var dir = "BENCH_DIR".getenv, tag = "BENCH_TAG".getenv ? "run";
var s = FakeServer(\fake, NetAddr("127.0.0.1", 57999));
var ctx = (server: s, xg: Group.basicNew(s, 1),
    in_b: [Bus.audio(s, 1), Bus.audio(s, 1)], out_b: Bus.audio(s, 2));
Engine_Four.new(ctx, { arg eng;
    var def = { |n| var d = SynthDescLib.global[n]; d.notNil.if({ d.def.asBytes }) };
    var opts = ServerOptions.new.memSize_(262144).numBuffers_(64);
    var syn = [
        SynthDef(\imp, { |out| Out.ar(out, Impulse.ar(0) ! 2) }),
        SynthDef(\sine, { |out, freq = 1000, amp = 0.25| Out.ar(out, SinOsc.ar(freq) * amp ! 2) }),
        SynthDef(\noise, { |out, amp = 0.1| Out.ar(out, [WhiteNoise.ar(amp), WhiteNoise.ar(amp)]) }),
        SynthDef(\dc, { |out, amp = 0.5, dur = 10| Out.ar(out, DC.ar(amp) * EnvGen.ar(Env.linen(0.01, dur, 0.01)) ! 2) }),
        SynthDef(\lf, { |out, dur = 10| Out.ar(out, SinOsc.ar(40) * EnvGen.ar(Env.linen(0.01, dur, 0.01)) ! 2) }),
        SynthDef(\burst, { |out, amp = 0.3| Out.ar(out, [WhiteNoise.ar(amp), WhiteNoise.ar(amp)] * EnvGen.ar(Env.linen(0.005, 0.3, 0.005))) }),
        SynthDef(\recsrc, { |out| var c = EnvGen.ar(Env([0, 0, 1.5, 1.5, 0], [1.0, 0.0001, 0.001, 0.0001]));
            Out.ar(out, (SinOsc.ar(200) * 0.3) + c ! 2) }),
        SynthDef(\copy, { |from, to| Out.ar(to, In.ar(from, 2)) })
    ];
    var jobs, run, std = syn.collect({ |d| [0.0, [\d_recv, d.asBytes]] });
    // s. THE MODULATED KNOB (doc/dsp-plan.md: "No step from a moved knob").
    // A modulator sends the engine one value a frame. Two frame clocks:
    //   \deadline: a deadline every 1/15 s, each frame 0 to 8 ms late. The
    //     frame loop after its fix. The deadlines are 1/150 longer than
    //     1/15 s (14.9 Hz): on the device the system clock and the audio clock
    //     drift apart, so over minutes the frames pass through every phase of
    //     any 1/15 s clock in the engine. The probe speeds that up, so one run
    //     of 11 s walks the frames once through every phase. (A clock locked
    //     at one phase tests one phase: Ramp.kr at 1/15 s scored 0% still
    //     with that, and stands still with this.)
    //   \drift: the old loop. It slept 1/15 s after 2 to 10 ms of work, and a
    //     value reached scsynth 0 to 3 ms later (13.8 Hz on average).
    // The first frame lands at a random place inside a frame, so no step keeps
    // a phase against an engine block or a synth start. The randomness is
    // seeded: every run sends the same frames.
    // The values are a FREE sine of 0.25 Hz, one step a frame, on two real
    // engine paths at once: track 2's level (0.5, swing 0.3) through
    // \four_lane_out over DC 0.5 (channel 0), and the cutoff of a lane filter
    // (3 kHz times 2 to the power of 1.5 sin) under a 3 kHz tone (channel 2).
    // an_stair.py measures how much of the time the output stands still.
    var modJob = { |name, clock, seed|
        var ts = List.new, msgs;
        thisThread.randSeed = seed;
        (clock == \deadline).if({
            var t0 = 0.5 + (1.0.rand / 15), p = (1 / 15) * (1 + (1 / 150)), k = 0;
            while({ (t0 + (k * p)) < 11.6 }, { ts.add(t0 + (k * p) + 0.008.rand); k = k + 1 });
        }, {
            var t = 0.5 + (1.0.rand / 15);
            while({ t < 11.6 }, { ts.add(t + 0.003.rand); t = t + (1 / 15) + rrand(0.002, 0.010) });
        });
        msgs = [[0.0, [\d_recv, def.(\four_lane_out)]], [0.0, [\d_recv, def.(\four_filt_lo)]],
            [0.001, [\s_new, \dc, 900, 0, 0, \out, 40, \amp, 0.5, \dur, 20]],
            [0.0011, [\s_new, \sine, 901, 0, 0, \out, 44, \freq, 3000, \amp, 0.25]],
            [0.002, [\s_new, \four_lane_out, 1000, 1, 0, \pbus, 40, \out_bus, 0, \own_out, 90,
                \dly_out, 92, \rev_out, 94, \level, 0.5]],
            [0.003, [\s_new, \four_filt_lo, 1001, 1, 0, \sbus, 44, \pbus, 46, \cutoff, 3000, \resonance, 0]],
            [0.004, [\s_new, \copy, 1002, 1, 0, \from, 46, \to, 2]]]
            ++ ts.collect({ |tk, k|
                var ph = 2pi * 0.25 * (k + 1) / 15;
                [[tk, [\n_set, 1000, \level, 0.5 + (0.3 * ph.sin)]],
                 [tk, [\n_set, 1001, \cutoff, 3000 * (2 ** (1.5 * (ph + 1).sin))]]] }).flatten(1);
        [name, 12.0, 4, [], msgs]
    };
    ("COMMANDS " ++ eng.cmdNames.size).postln;
    "FOUR_PLUGIN_DIR".getenv.notNil.if({
        opts.ugenPluginsPath = [Platform.resourceDir +/+ "plugins", "FOUR_PLUGIN_DIR".getenv];
    });
    jobs = [
        // a. resonance on the stock path at three cutoffs
        [\res, 1.0, 12, [],
            [[0.0, [\d_recv, def.(\four_filt_lo)]]]
            ++ [[1000, 0.5], [1000, 0.9], [5000, 0.5], [5000, 0.9], [10000, 0.5], [10000, 0.9]].collect({ |c, i|
                [[0.001, [\s_new, \four_filt_lo, 1100 + i, 1, 0, \sbus, 100 + (i * 2), \pbus, i * 2,
                    \cutoff, c[0], \resonance, c[1]]],
                 [0.1, [\s_new, \imp, 1000 + i, 0, 0, \out, 100 + (i * 2)]]] }).flatten(1)],
        // e. the record limiter on a transient (1 ms at 1.5 over a 200 Hz tone at 0.3)
        [\rectr, 2.0, 2, [[0, 2.0], [1, 2.0]],
            [[0.0, [\d_recv, def.(\four_io)]],
             [0.001, [\s_new, \recsrc, 1000, 0, 0, \out, 60]],
             [0.001, [\s_new, \four_io, 1001, 1, 0, \in1, 60, \in2, 61, \out, 0, \buf_l, 0, \buf_r, 1,
                \play_bus, 70, \rec_phase_out, 0, \rec_amp_out, 1, \dry_wet, 0, \level, 1,
                \lane_bus, 72, \dly_send, 74, \dly_ret, 76, \rev_send, 78, \rev_ret, 80, \t2_ret, 82,
                \lanes_dly, 84, \lanes_rev, 86, \own_out, 88, \rec_level, 1, \pre_level, 0, \rec, 1]],
             [1.9, [\b_write, 0, dir +/+ tag ++ "_rectake.wav", "wav", "float"]]]],
        // f, g. COLOUR: [drive, crush] on a 1 kHz sine at -12 dBFS (0.25) and -6 dBFS (0.5)
        [\colour, 2.0, 16, [],
            [[0.0, [\d_recv, def.(\four_colour)]],
             [0.001, [\s_new, \sine, 900, 0, 0, \out, 40, \amp, 0.25]],
             [0.001, [\s_new, \sine, 901, 0, 0, \out, 44, \amp, 0.5]]]
            ++ [[40, 0.25, 0], [40, 0.5, 0], [40, 1, 0], [44, 0.25, 0], [44, 1, 0], [40, 0, 0.5], [40, 0, 1], [44, 0, 1]].collect({ |c, i|
                [[0.002, [\s_new, \copy, 1000 + i, 1, 0, \from, c[0], \to, 80 + (i * 2)]],
                 [0.003, [\s_new, \four_colour, 1100 + i, 1, 0, \pbus, 80 + (i * 2), \drive, c[1], \crush, c[2]]],
                 [0.004, [\s_new, \copy, 1200 + i, 1, 0, \from, 80 + (i * 2), \to, i * 2]]] }).flatten(1)],
        // r. the drive's aliasing: a 5 kHz sine at -6 dBFS, full drive (a checklist row)
        [\drive5k, 2.0, 2, [],
            [[0.0, [\d_recv, def.(\four_colour)]],
             [0.001, [\s_new, \sine, 900, 0, 0, \out, 40, \freq, 5000, \amp, 0.5]],
             [0.002, [\s_new, \copy, 1000, 1, 0, \from, 40, \to, 80]],
             [0.003, [\s_new, \four_colour, 1100, 1, 0, \pbus, 80, \drive, 1, \crush, 0]],
             [0.004, [\s_new, \copy, 1200, 1, 0, \from, 80, \to, 0]]]],
        // j. GRAIN in a 12 ms window of a 1 kHz island in a 7 kHz buffer: [size, scan]
        [\gedge, 4.0, 8, [[0, "marker.wav"], [1, "marker.wav"]],
            [[0.0, [\d_recv, def.(\four_grain)]]]
            ++ [[0.5, 1], [0.01, 1], [0.5, -1], [0.1, 1]].collect({ |c, i|
                [0.001, [\s_new, \four_grain, 1000 + i, 0, 0, \buf_l, 0, \buf_r, 1, \play_bus, i * 2,
                    \phase_out, 10 + i, \pos_start, 0.4985, \pos_end, (i == 3).if(0.5015, 0.4987), \size, c[0],
                    \scan, c[1], \spread, 0, \level, 1]] })],
        // o. the reverb: level and decay at three decays (a click at 0.1 s)
        [\rv, 12.0, 6, [],
            [[0.0, [\d_recv, def.(\four_reverb)]], [0.1, [\s_new, \imp, 900, 0, 0, \out, 100]]]
            ++ [0.8, 2, 7].collect({ |dc, i|
                [0.01, [\s_new, \four_reverb, 1000 + i, 1, 0, \in_bus, 100, \out_bus, i * 2, \rev_decay, dc]] })],
        // p. shimmer worst case, 60 s: [decay, pitch, source]
        [\shim2, 60, 16, [],
            [[0.0, [\d_recv, def.(\four_reverb)]],
             [0.1, [\s_new, \burst, 900, 0, 0, \out, 100]],
             [0.1, [\s_new, \lf, 901, 0, 0, \out, 104, \dur, 10]],
             [0.1, [\s_new, \dc, 902, 0, 0, \out, 108, \amp, 0.5, \dur, 10]]]
            ++ [[30, -12, 100], [30, -7, 100], [30, 7, 100], [30, 24, 100], [30, 0, 104], [30, 12, 104], [30, 0, 108], [30, 12, 108]].collect({ |c, i|
                [0.01, [\s_new, \four_reverb, 1000 + i, 1, 0, \in_bus, c[2], \out_bus, i * 2,
                    \rev_decay, c[0], \shimmer, 0.95, \shimmer_pitch, c[1]]] })],
        // q. the delay, a 1 kHz tone, time 0.3 s to 0.1 s at 1 s (the engine's 0.2 s lag)
        [\dglide, 3.0, 2, [],
            [[0.0, [\d_recv, def.(\four_delay)]],
             [0.001, [\s_new, \sine, 900, 0, 0, \out, 40, \amp, 0.25]],
             [0.01, [\s_new, \four_delay, 1000, 1, 0, \in_bus, 40, \out_bus, 0, \delay_time, 0.3, \delay_fb, 0, \delay_mix, 1]],
             [1.0, [\n_set, 1000, \delay_time, 0.1]]]],
        // s. the modulated knob, on the two frame clocks (see modJob above)
        modJob.(\mod15, \deadline, 1511),
        modJob.(\mod138, \drift, 1138)
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
