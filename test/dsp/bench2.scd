(
var dir = "BENCH_DIR".getenv;
var def = SynthDef(\fix, {
    var fr = BufFrames.kr(0), st = (0.9 * fr).round, en = (0.98 * fr).round, st2 = (0.13 * fr).round;
    var semi = 2 ** (1/12);
    var eng = { |lo, span, rate|
        var phase = Phasor.ar(0, rate * SampleDur.ir / (BufDur.kr(0) * span), 0, 1);
        BufRd.ar(1, 0, (lo + (phase * span)) * fr, 1, 4) };
    Out.ar(0, [
        BufRd.ar(1, 0, Phasor.ar(0, 1, st, en), 1, 4),
        BufRd.ar(1, 0, Phasor.ar(0, semi, st, en), 1, 4),
        PlayBuf.ar(1, 0, 1, 1, st),
        PlayBuf.ar(1, 0, semi, 1, st),
        eng.(0.13, 0.08, 1),
        eng.(0.13, 0.08, semi),
        BufRd.ar(1, 0, Phasor.ar(0, semi, st2, st2 + 200000), 1, 4)
    ]);
});
Score([[0.0, [\d_recv, def.asBytes]], [0.0, [\b_allocRead, 0, dir +/+ "long5k.wav"]],
    [0.001, [\s_new, \fix, 1000, 0, 0]], [3, [\c_set, 0, 0]]]).recordNRT(dir +/+ "fix.osc", dir +/+ "fix.wav",
    sampleRate: 48000, headerFormat: "WAV", sampleFormat: "float",
    options: ServerOptions.new.numOutputBusChannels_(7), duration: 3, action: { "BENCH_DONE".postln; 0.exit });
)
