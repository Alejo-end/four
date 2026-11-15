// the delay synth, deterministic input: a click and a sine, three times, feedback 0.6
(
var dir = "BENCH_DIR".getenv, tag = "BENCH_TAG".getenv ? "run";
var s = FakeServer(\fake, NetAddr("127.0.0.1", 57999));
var ctx = (server: s, xg: Group.basicNew(s, 1), in_b: [Bus.audio(s, 1), Bus.audio(s, 1)], out_b: Bus.audio(s, 2));
Engine_Four.new(ctx, { arg eng;
    var def = { |n| var d = SynthDescLib.global[n]; d.notNil.if({ d.def.asBytes }) };
    var opts = ServerOptions.new.memSize_(262144).numOutputBusChannels_(8);
    var src = SynthDef(\src, { |out| Out.ar(out, (SinOsc.ar(330) * 0.2 * EnvGen.ar(Env.linen(0.01, 0.3, 0.01))) + Impulse.ar(0) ! 2) });
    opts.ugenPluginsPath = [Platform.resourceDir +/+ "plugins", "FOUR_PLUGIN_DIR".getenv];
    Score([[0.0, [\d_recv, def.(\four_delay)]], [0.0, [\d_recv, src.asBytes]], [0.5, [\s_new, \src, 900, 0, 0, \out, 40]]]
        ++ [0.043, 0.1, 0.3, 1.0].collect({ |t, i| [0.01, [\s_new, \four_delay, 1000 + i, 1, 0, \in_bus, 40, \out_bus, i * 2,
            \delay_time, t, \delay_fb, 0.6, \delay_mix, 1]] })
        ++ [[1.0, [\n_set, 1000, \delay_time, 0.2]], [4.0, [\c_set, 0, 0]]]).recordNRT(
        dir +/+ tag ++ "_d.osc", dir +/+ tag ++ "_d.wav", sampleRate: 48000, headerFormat: "WAV", sampleFormat: "float",
        options: opts, duration: 4.0, action: { "PROBE_DONE".postln; 0.exit });
});
)
