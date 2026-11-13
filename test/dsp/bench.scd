(
var dir = "BENCH_DIR".getenv;
var jobs = List.new, run;
var add = { |name, dur, nch, bufs, fn|
    jobs.add([name, dur, nch, bufs, SynthDef(name, fn)]);
};
var lc = { |v| v.abs + (1 + (v.abs * -2).exp).log };   // ln(2 cosh v)

add.(\drive, 3, 4, [], {
    var out = [5000, 1318.5].collect({ |f|
        var x = SinOsc.ar(f) * 0.9, pre = 7, u, u1, d, flag, y;
        u = x * pre; u1 = Delay1.ar(u); d = u - u1; flag = d.abs < 0.01;
        y = (flag * ((u + u1) * 0.5).tanh) + ((1 - flag) * ((lc.(u) - lc.(u1)) / (d + flag)));
        [u.tanh, y] / pre.sqrt
    }).flatten;
    Out.ar(0, out);
});

add.(\read, 1.5, 4, [[0, "tone15k.wav"], [1, "tone10k.wav"]], {
    var up = Phasor.ar(0, 2, 0, BufFrames.kr(0));
    var dn = Phasor.ar(0, 0.5, 0, BufFrames.kr(1));
    var st = Phasor.ar(0, 2 ** (7/12), 0, BufFrames.kr(1));
    Out.ar(0, [BufRd.ar(1, 0, up, 1, 4), BufRd.ar(1, 1, dn, 1, 4),
        BufRd.ar(1, 1, dn, 1, 2), BufRd.ar(1, 1, st, 1, 4)]);
});

// the engine's own window law on a 60 s buffer, rate 1, early and late
add.(\longread, 3, 6, [[0, "long5k.wav"], [1, "long1k.wav"]], {
    var rd = { |buf, lo, span, rate|
        var incr = rate * SampleDur.ir / (BufDur.kr(buf) * span);
        var phase = Phasor.ar(0, incr, 0, 1);
        BufRd.ar(1, buf, (lo + (phase * span)) * BufFrames.kr(buf), 1, 4)
    };
    Out.ar(0, [rd.(0, 0.02, 0.08, 1), rd.(0, 0.5, 0.08, 1), rd.(0, 0.9, 0.08, 1),
        rd.(1, 0.02, 0.08, 1), rd.(1, 0.9, 0.08, 1), rd.(0, 0.9, 0.08, 2 ** (1/12))]);
});

add.(\chorus, 3, 2, [], {
    var x = SinOsc.ar(1000) * 0.5;
    var top = (0.015 + (0.007 * SinOsc.kr(6))).lag(0.1);
    var mid = (0.015 + (0.0045 * SinOsc.kr(0.1 * (60 ** 0.5)))).lag(0.1);
    Out.ar(0, [CombC.ar(x, 0.05, top, 0), CombC.ar(x, 0.05, mid, 0)]);
});

add.(\warp, 4, 5, [[0, "white.wav"], [1, "tone440.wav"]], {
    var p0 = Line.ar(0, 1, BufDur.kr(0)), p1 = Line.ar(0, 1, BufDur.kr(1));
    var ph = Line.ar(0, 1, BufDur.kr(1) * 2);
    Out.ar(0, [
        Warp1.ar(1, 0, A2K.kr(p0), 1, 0.25, -1, 4, 0.2, 4),
        Warp1.ar(1, 0, A2K.kr(p0), 1, 0.25, -1, 4, 0.2, 4),
        Warp1.ar(1, 0, A2K.kr(p0), 1, 0.25, -1, 4, 0, 4),
        Warp1.ar(1, 1, A2K.kr(p1), 1, 0.25, -1, 4, 0, 4),
        Warp1.ar(1, 1, A2K.kr(ph), 1, 0.25, -1, 4, 0, 4)]);
});

add.(\grain, 3.5, 6, [[0, "white.wav"]], {
    var mk = { |dens, size|
        var trig = Impulse.ar(dens);
        var nat = Line.ar(0.05, 0.05 + (3.5 / BufDur.kr(0)), 3.5);
        [GrainBuf.ar(1, trig, size, 0, 1, nat, 4, 0, -1),
         GrainBuf.ar(1, trig, size, 0, 1, 0.5, 4, 0, -1),
         GrainBuf.ar(1, trig, size, 0, 1, TRand.ar(0.05, 0.9, trig), 4, 0, -1)]
    };
    Out.ar(0, mk.(80, 0.1) ++ mk.(20, 0.1));
});

add.(\reson, 3, 3, [], {
    var imp = Impulse.ar(0);
    Out.ar(0, [36, 60, 84].collect({ |m| CombC.ar(imp, 0.02, m.midicps.reciprocal, 2) }));
});

add.(\pv, 2, 2, [[0, "tone1k.wav"]], {
    var rd = { |rate| BufRd.ar(1, 0, Phasor.ar(0, rate, 0, BufFrames.kr(0)), 1, 4) };
    Out.ar(0, [1, 0.5].collect({ |r| IFFT(PV_MagFreeze(FFT(LocalBuf(2048), rd.(r)), 0)) }));
});

run = { |i|
    if (i >= jobs.size) { "BENCH_DONE".postln; 0.exit } {
        var name, dur, nch, bufs, def, score, opts;
        #name, dur, nch, bufs, def = jobs[i];
        score = [[0.0, [\d_recv, def.asBytes]]]
            ++ bufs.collect({ |b| [0.0, [\b_allocRead, b[0], dir +/+ b[1]]] })
            ++ [[0.001, [\s_new, name, 1000, 0, 0]], [dur, [\c_set, 0, 0]]];
        opts = ServerOptions.new.numOutputBusChannels_(nch).memSize_(65536);
        Score(score).recordNRT(dir +/+ name ++ ".osc", dir +/+ name ++ ".wav",
            sampleRate: 48000, headerFormat: "WAV", sampleFormat: "float",
            options: opts, duration: dur, action: { ("done " ++ name).postln; run.(i + 1) });
    };
};
run.(0);
)
