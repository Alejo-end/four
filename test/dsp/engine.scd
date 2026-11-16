// Builds the REAL engine's SynthDefs on the Mac and renders them offline.
// Run: BENCH_DIR=<work folder> BENCH_TAG=<name> sclang -l <conf.yaml> engine.scd
(
var dir = "BENCH_DIR".getenv, tag = "BENCH_TAG".getenv ? "run";
var s = FakeServer(\fake, NetAddr("127.0.0.1", 57999));
var ctx = (server: s, xg: Group.basicNew(s, 1),
    in_b: [Bus.audio(s, 1), Bus.audio(s, 1)], out_b: Bus.audio(s, 2));
var semi = 2 ** (1/12);
Engine_Four.new(ctx, { arg eng;
    // nil for a def this build does not have (FLANGE needs the plugin)
    var def = { |n| var d = SynthDescLib.global[n]; d.notNil.if({ d.def.asBytes }) };
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
        ,
        // the plugin's FLANGE and ECHO (only with FOUR_PLUGIN_DIR): white noise
        // through the flanger at four settings, and one click through the echo
        ["FOUR_PLUGIN_DIR".getenv.notNil.if({ \delay }, { \skip }), 6, 10, [],
            [[0.0, [\d_recv, def.(\four_fx_flange) ? src.asBytes]], [0.0, [\d_recv, def.(\four_fx_echo)]],
             [0.0, [\d_recv, SynthDef(\copy, { |from, to| Out.ar(to, In.ar(from, 2)) }).asBytes]],
             [0.0, [\d_recv, SynthDef(\noise, { |out| Out.ar(out, WhiteNoise.ar(0.2) ! 2) }).asBytes]],
             [0.0, [\d_recv, SynthDef(\click, { |out| Out.ar(out, Impulse.ar(0) * 0.5 ! 2) }).asBytes]],
             [0.001, [\s_new, \noise, 900, 0, 0, \out, 40]],
             [0.5, [\s_new, \click, 901, 0, 0, \out, 44]]]
            ++ [[0, 0.5], [0.5, 0.5], [1, 0.5], [1, 0.9]].collect({ |c, i|
                [[0.002, [\s_new, \copy, 1000 + i, 1, 0, \from, 40, \to, 80 + (i * 2)]],
                 [0.003, [\s_new, \four_fx_flange, 1100 + i, 1, 0,
                    \pbus, 80 + (i * 2), \type, 2, \amt, c[0], \rate, c[1]]],
                 [0.004, [\s_new, \copy, 1200 + i, 1, 0, \from, 80 + (i * 2), \to, i * 2]]] }).flatten(1)
            ++ [[0.002, [\s_new, \copy, 1010, 1, 0, \from, 44, \to, 90]],
                [0.003, [\s_new, \four_fx_echo, 1110, 1, 0, \pbus, 90, \type, 6, \amt, 0.7, \rate, 0.5]],
                [0.004, [\s_new, \copy, 1210, 1, 0, \from, 90, \to, 8]]]]
        ,
        // the engine's delay synth (THE BUCKET BRIGADE with the plugin): a noise
        // burst of 20 ms through it at three times, each on its own pair of outs
        ["FOUR_PLUGIN_DIR".getenv.notNil.if({ \bbd }, { \skip }), 8, 6, [],
            [[0.0, [\d_recv, def.(\four_delay)]],
             [0.0, [\d_recv, SynthDef(\burst, { |out| Out.ar(out, WhiteNoise.ar(0.5) * EnvGen.ar(Env.linen(0.001, 0.02, 0.001)) ! 2) }).asBytes]],
             [0.5, [\s_new, \burst, 900, 0, 0, \out, 40]]]
            ++ [0.3, 1.0, 2.0].collect({ |t, i|
                [0.01, [\s_new, \four_delay, 1000 + i, 1, 0, \in_bus, 40, \out_bus, i * 2,
                    \delay_time, t, \delay_fb, 0.6, \delay_mix, 0.5]] })]
        ,
        // THE CLOUD (only with FOUR_PLUGIN_DIR, and only when the engine built
        // its Clouds def): the CLOUD voice on a 1 kHz take in each of the four
        // modes of Clouds, then GRANULAR frozen at 2 s, each on its own pair of outs
        [("FOUR_PLUGIN_DIR".getenv.notNil and: { SynthDescLib.global[\four_clouds].notNil }).if({ \cloud }, { \skip }),
            6, 10, [[0, "long1k.wav"], [1, "long1k.wav"]],
            [[0.0, [\d_recv, def.(\four_clouds)]]]
            ++ [0, 1, 2, 3, 0].collect({ |m, i|
                [0.001, [\s_new, \four_clouds, 1000 + i, 0, 0, \buf_l, 0, \buf_r, 1,
                    \play_bus, i * 2, \phase_out, 100 + i,
                    \pos_start, 0.5, \pos_end, 0.58, \level, 1, \clouds_mode, m]] })
            ++ [[2.0, [\n_set, 1004, \pv_freeze, 1]]]]
    ];
    run = { |i|
        if (i >= jobs.size) { "BENCH_DONE".postln; 0.exit } {
            var name, dur, nch, bufs, msgs, score;
            #name, dur, nch, bufs, msgs = jobs[i];
            (name == \skip).if({ run.(i + 1) }, {
            score = bufs.collect({ |b| [0.0, [\b_allocRead, b[0], dir +/+ b[1]]] })
                ++ msgs ++ [[dur, [\c_set, 0, 0]]];
            score = score.sort({ |a, b| a[0] < b[0] });
            Score(score).recordNRT(dir +/+ tag ++ "_" ++ name ++ ".osc",
                dir +/+ tag ++ "_" ++ name ++ ".wav",
                sampleRate: 48000, headerFormat: "WAV", sampleFormat: "float",
                options: opts.numOutputBusChannels_(nch),
                duration: dur, action: { ("done " ++ name).postln; run.(i + 1) });
            });
        };
    };
    run.(0);
});
)
