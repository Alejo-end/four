// Second probes of the REAL engine's SynthDefs. run_probe.sh <work> <tag> probe2.scd
(
var dir = "BENCH_DIR".getenv, tag = "BENCH_TAG".getenv ? "run";
var s = FakeServer(\fake, NetAddr("127.0.0.1", 57999));
var ctx = (server: s, xg: Group.basicNew(s, 1),
    in_b: [Bus.audio(s, 1), Bus.audio(s, 1)], out_b: Bus.audio(s, 2));
Engine_Four.new(ctx, { arg eng;
    var def = { |n| var d = SynthDescLib.global[n]; d.notNil.if({ d.def.asBytes }) };
    var opts = ServerOptions.new.memSize_(262144).numBuffers_(64);
    var imp = SynthDef(\imp, { |out| Out.ar(out, Impulse.ar(0) ! 2) });
    // a candidate stock filter: the RBJ biquads of the core library
    var cand = SynthDef(\cand, { |in, out, cf = 20000, res = 0, hp = 0|
        var sig = In.ar(in, 2), rq = (1 - (res * 0.92)).max(0.05) * 1.4142;
        Out.ar(out, (hp > 0).if(BHiPass.ar(sig, cf, rq), BLowPass.ar(sig, cf, rq))) });
    var jobs, run, std;
    std = [[0.0, [\d_recv, imp.asBytes]], [0.0, [\d_recv, cand.asBytes]]];
    ("COMMANDS " ++ eng.cmdNames.size).postln;
    "FOUR_PLUGIN_DIR".getenv.notNil.if({
        opts.ugenPluginsPath = [Platform.resourceDir +/+ "plugins", "FOUR_PLUGIN_DIR".getenv];
    });
    jobs = [
        // erosion at four places, the engine's head, erode 1 for 12 s
        [\erode2, 12.2, 2, (0..7).collect({ |b| [b, "long5k.wav"] }),
            [[0.0, [\d_recv, def.(\four_erode)]]]
            ++ [0.05, 0.3, 0.5, 0.9].collect({ |p, i|
                [0.01, [\s_new, \four_erode, 1000 + i, 0, 0, \buf_l, i * 2, \buf_r, (i * 2) + 1,
                    \pos_start, p, \pos_end, p + 0.08, \erode, 1]] })
            ++ (0..3).collect({ |i| [12.0, [\b_write, i * 2, dir +/+ tag ++ "_ero2_" ++ i ++ ".wav", "wav", "float"]] })],
        // a mode change into GRAIN at 1 s, and PLAY parked mid-window at 1 s (scan to 0)
        [\gap, 2.0, 4, [[0, "long1k.wav"], [1, "long1k.wav"], [2, "long5k.wav"], [3, "long5k.wav"]],
            [[0.0, [\d_recv, def.(\four_play)]], [0.0, [\d_recv, def.(\four_grain)]],
             [0.001, [\s_new, \four_play, 1000, 0, 0, \buf_l, 0, \buf_r, 1, \play_bus, 0, \phase_out, 10,
                \pos_start, 0.3, \pos_end, 0.4, \level, 1]],
             [1.0, [\n_set, 1000, \gate, 0, \handover, 1]],
             [1.0, [\s_new, \four_grain, 1001, 0, 0, \buf_l, 0, \buf_r, 1, \play_bus, 0, \phase_out, 10,
                \pos_start, 0.3, \pos_end, 0.4, \level, 1]],
             [0.001, [\s_new, \four_play, 1002, 0, 0, \buf_l, 2, \buf_r, 3, \play_bus, 2, \phase_out, 11,
                \pos_start, 0.3, \pos_end, 0.4, \level, 1]],
             [1.0123, [\n_set, 1002, \scan, 0]]]],
        // the candidate stock filter, open and at 1 kHz
        [\cand, 1.0, 8, [],
            [[0.001, [\s_new, \cand, 1100, 1, 0, \in, 100, \out, 0, \cf, 20000]],
             [0.001, [\s_new, \cand, 1101, 1, 0, \in, 102, \out, 2, \cf, 1000]],
             [0.001, [\s_new, \cand, 1102, 1, 0, \in, 104, \out, 4, \cf, 1000, \res, 0.9]],
             [0.001, [\s_new, \cand, 1103, 1, 0, \in, 106, \out, 6, \cf, 19000]]]
            ++ (0..3).collect({ |i| [0.1, [\s_new, \imp, 1000 + i, 0, 0, \out, 100 + (i * 2)]] })]
    ];
    run = { |i|
        if (i >= jobs.size) { "PROBE_DONE".postln; 0.exit } {
            var name, dur, nch, bufs, msgs, score;
            #name, dur, nch, bufs, msgs = jobs[i];
            score = std ++ bufs.collect({ |b| [0.0, [\b_allocRead, b[0], dir +/+ b[1]]] })
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
