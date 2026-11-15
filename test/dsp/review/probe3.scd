// The first grain: CoinGate and the grain defs. run_probe.sh <work> <tag> probe3.scd
(
var dir = "BENCH_DIR".getenv, tag = "BENCH_TAG".getenv ? "run";
var s = FakeServer(\fake, NetAddr("127.0.0.1", 57999));
var ctx = (server: s, xg: Group.basicNew(s, 1),
    in_b: [Bus.audio(s, 1), Bus.audio(s, 1)], out_b: Bus.audio(s, 2));
Engine_Four.new(ctx, { arg eng;
    var def = { |n| var d = SynthDescLib.global[n]; d.notNil.if({ d.def.asBytes }) };
    var opts = ServerOptions.new.memSize_(262144).numBuffers_(64);
    var gates = SynthDef(\gates, { |out|
        Out.ar(out, [Impulse.ar(20), CoinGate.ar(1, Impulse.ar(20)),
            CoinGate.ar(1, Impulse.ar(20)) + Impulse.ar(0)]) });
    var jobs, run;
    ("COMMANDS " ++ eng.cmdNames.size).postln;
    "FOUR_PLUGIN_DIR".getenv.notNil.if({
        opts.ugenPluginsPath = [Platform.resourceDir +/+ "plugins", "FOUR_PLUGIN_DIR".getenv];
    });
    jobs = [
        [\first, 1.5, 10, [[0, "long1k.wav"], [1, "long1k.wav"]],
            [[0.0, [\d_recv, gates.asBytes]], [0.0, [\d_recv, def.(\four_voice_grain)]],
             [0.0, [\d_recv, def.(\four_grain)]],
             [0.5, [\s_new, \gates, 900, 0, 0, \out, 0]],
             // a pad at density 20 and at 4, and the drone at density 4
             [0.5, [\s_new, \four_voice_grain, 1000, 0, 0, \buf_l, 0, \buf_r, 1, \play_bus, 4,
                \note_pos, 0.3, \density, 20, \amp, 1]],
             [0.5, [\s_new, \four_voice_grain, 1001, 0, 0, \buf_l, 0, \buf_r, 1, \play_bus, 6,
                \note_pos, 0.3, \density, 4, \amp, 1]],
             [0.5, [\s_new, \four_grain, 1002, 0, 0, \buf_l, 0, \buf_r, 1, \play_bus, 8, \phase_out, 10,
                \pos_start, 0.3, \pos_end, 0.4, \density, 4, \level, 1]]]]
    ];
    run = { |i|
        if (i >= jobs.size) { "PROBE_DONE".postln; 0.exit } {
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
