// Builds the REAL engine's SynthDefs on the Mac and renders them offline.
// Run: BENCH_DIR=<work folder> BENCH_TAG=<name> sclang -l <conf.yaml> engine.scd
(
var dir = "BENCH_DIR".getenv, tag = "BENCH_TAG".getenv ? "run";
var s = FakeServer(\fake, NetAddr("127.0.0.1", 57999));
var ctx = (server: s, xg: Group.basicNew(s, 1),
    in_b: [Bus.audio(s, 1), Bus.audio(s, 1)], out_b: Bus.audio(s, 2));
var semi = 2 ** (1/12);
Engine_Four.new(ctx, { arg eng;
    var def = { |n| SynthDescLib.global[n].def.asBytes };
    var src = SynthDef(\src, { |out| Out.ar(out, SinOsc.ar(1000) * 0.25 ! 2) });
    var jobs, run;
    var opts = ServerOptions.new.memSize_(131072);
    "FOUR_PLUGIN_DIR".getenv.notNil.if({
        opts.ugenPluginsPath = [Platform.resourceDir +/+ "plugins", "FOUR_PLUGIN_DIR".getenv];
    });
    ("COMMANDS " ++ eng.cmdNames.size).postln;
    jobs = [
        [\read, 3.2, 16, [[0, "long5k.wav"], [1, "long5k.wav"]],
            [[0.02, 1, \four_play], [0.13, 1, \four_play], [0.9, 1, \four_play],
             [0.13, semi, \four_play], [0.9, semi, \four_play], [0.9, 0.5, \four_play],
             [0.9, 1, \four_pv], [0.9, -1, \four_play]].collect({ |c, i|
                [0.001, [\s_new, c[2], 1000 + i, 0, 0, \buf_l, 0, \buf_r, 1,
                    \play_bus, i * 2, \phase_out, 100 + i,
                    \pos_start, c[0], \pos_end, c[0] + 0.08,
                    \pitch, c[1].abs, \scan, c[1].sign, \level, 1]] })
            ++ [[0.0, [\d_recv, def.(\four_play)]], [0.0, [\d_recv, def.(\four_pv)]]]],
        // the two stretch voices, 54 s into the buffer: [def, scan, pitch, freeze]
        [\stretch, 4, 16, [[0, "long5k.wav"], [1, "long5k.wav"]],
            [[\four_pv, 1, 1, 0], [\four_pv, 0.5, 1, 0], [\four_pv, 0.5, 2, 0], [\four_pv, 1, 1, 1],
             [\four_warp, 1, 1, 0], [\four_warp, 0.5, 1, 0], [\four_warp, 0.5, 2, 0],
             [\four_warp, 0.25, 1, 0]].collect({ |c, i|
                [0.001, [\s_new, c[0], 1000 + i, 0, 0, \buf_l, 0, \buf_r, 1,
                    \play_bus, i * 2, \phase_out, 100 + i,
                    \pos_start, 0.9, \pos_end, 0.98,
                    \scan, c[1], \pitch, c[2], \pv_freeze, c[3], \level, 1]] })
            ++ [[0.0, [\d_recv, def.(\four_pv)]], [0.0, [\d_recv, def.(\four_warp)]]]],
        // the head after a window move and a scan change: it must settle clean
        [\move, 3.4, 2, [[0, "long5k.wav"], [1, "long5k.wav"]],
            [[0.0, [\d_recv, def.(\four_play)]],
             [0.001, [\s_new, \four_play, 1000, 0, 0, \buf_l, 0, \buf_r, 1, \play_bus, 0,
                \phase_out, 100, \pos_start, 0.5, \pos_end, 0.58, \level, 1]],
             [0.5, [\n_set, 1000, \pos_start, 0.8, \pos_end, 0.95]],
             [1.0, [\n_set, 1000, \scan, 0.5]], [1.3, [\n_set, 1000, \scan, 1]]]],
        // the effect synths work in place on a bus: a copy of the source goes
        // to a bus for each case, the effect acts on it, a tap sends it out
        [\fx, 4, 12, [],
            [[0.0, [\d_recv, src.asBytes]], [0.0, [\d_recv, def.(\four_fx_mod)]],
             [0.0, [\d_recv, SynthDef(\copy, { |from, to| Out.ar(to, In.ar(from, 2)) }).asBytes]],
             [0.001, [\s_new, \src, 900, 0, 0, \out, 40]]]
            ++ [[0, 0.5, 0.5], [1, 1, 1], [1, 0.5, 0.5], [1, 1, 0], [3, 1, 1], [3, 1, 0]].collect({ |c, i|
                [[0.002, [\s_new, \copy, 1000 + i, 1, 0, \from, 40, \to, 80 + (i * 2)]]]
                ++ (c[0] > 0).if({ [[0.003, [\s_new, \four_fx_mod, 1100 + i, 1, 0,
                    \pbus, 80 + (i * 2), \type, c[0], \amt, c[1], \rate, c[2]]]] }, { [] })
                ++ [[0.004, [\s_new, \copy, 1200 + i, 1, 0, \from, 80 + (i * 2), \to, i * 2]]] }).flatten(1)]
    ];
    run = { |i|
        if (i >= jobs.size) { "BENCH_DONE".postln; 0.exit } {
            var name, dur, nch, bufs, msgs, score;
            #name, dur, nch, bufs, msgs = jobs[i];
            score = bufs.collect({ |b| [0.0, [\b_allocRead, b[0], dir +/+ b[1]]] })
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
