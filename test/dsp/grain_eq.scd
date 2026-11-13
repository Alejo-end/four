// FourGrain against two stock GrainBuf, on the same deterministic inputs
(
var dir = "BENCH_DIR".getenv;
var opts = ServerOptions.new.memSize_(131072).numOutputBusChannels_(16);
var def, score;
opts.ugenPluginsPath = [Platform.resourceDir +/+ "plugins", "FOUR_PLUGIN_DIR".getenv];
def = SynthDef(\eq, { |bl, br, env|
    // a busy cloud: 60 grains a second, 0.21 s long, the place and the pitch move
    var trig = Impulse.ar(60) + Impulse.ar(13.7, 0.3);
    var dur = 0.21 + (0.1 * LFSaw.ar(0.7));
    var rate = 1.3 + (0.6 * LFSaw.ar(0.31));
    var pos = 0.3 + (0.25 * LFTri.ar(0.11));
    var panL = LFSaw.ar(0.9) * 0.8, panR = LFSaw.ar(1.3) * 0.9;
    // one thing at a time: fixed values, then each input moving alone
    var fx = [0.21, 1.3, 0.3, -0.4, 0.5];
    var mk = { |tr, d, rt, ps, pl, pr, e|
        var x = GrainBuf.ar(2, tr, d, bl, rt, ps, 4, pl, e, 512) + GrainBuf.ar(2, tr, d, br, rt, ps, 4, pr, e, 512);
        var y = FourGrain.ar(bl, br, tr, d, rt, ps, pl, pr, e, 128);
        [x[0], y[0]] };
    var t1 = Impulse.ar(2);
    var c0 = mk.(t1, fx[0], fx[1], fx[2], fx[3], fx[4], -1);
    var c1 = mk.(t1, dur, fx[1], fx[2], fx[3], fx[4], -1);
    var c2 = mk.(t1, fx[0], rate, fx[2], fx[3], fx[4], -1);
    var c3 = mk.(t1, fx[0], fx[1], pos, fx[3], fx[4], -1);
    var c4 = mk.(t1, fx[0], fx[1], fx[2], panL, panR, -1);
    var c5 = mk.(trig, fx[0], fx[1], fx[2], fx[3], fx[4], -1);
    var c6 = mk.(t1, fx[0], fx[1], fx[2], fx[3], fx[4], env);
    var c7 = mk.(t1, fx[0], fx[1], fx[2], fx[3], fx[4], 2);
    Out.ar(0, c0 ++ c1 ++ c2 ++ c3 ++ c4 ++ c5 ++ c6 ++ c7);
});
score = [
    [0.0, [\b_allocRead, 0, dir +/+ "noiseL.wav"]], [0.0, [\b_allocRead, 1, dir +/+ "noiseR.wav"]],
    [0.0, [\b_alloc, 2, 2048, 1]],
    [0.0, [\b_gen, 2, \sine1, 0, 0.5]],          // a half sine as the window buffer
    [0.0, [\d_recv, def.asBytes]],
    [0.1, [\s_new, \eq, 1000, 0, 0, \bl, 0, \br, 1, \env, 2]],
    [6.0, [\c_set, 0, 0]]];
Score(score).recordNRT(dir +/+ "grain_eq.osc", dir +/+ "grain_eq.wav", sampleRate: 48000,
    headerFormat: "WAV", sampleFormat: "float", options: opts, duration: 6.0,
    action: { "EQ_DONE".postln; 0.exit });
)
