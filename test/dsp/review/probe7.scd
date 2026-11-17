// What each effect does to a sound at each AMOUNT. run_probe.sh <work> <tag> probe7.scd
// The user, 2026-11-17, on the device: the effects are "a bit too bland", and
// they asked for more punch. This probe puts a number on it, with the engine's
// own effect SynthDefs, so that a change of a law shows before the device.
//
// A lane is one phrase on a bus of its own, the slot's synth in a group after
// it, and a copy to the output. The phrase has no noise in it, so every lane
// hears the same sound: a chord of four saws under a slow swell, a kick at
// 2 Hz and a tick at 4 Hz. RATE stays at 0.5, where a new slot starts.
//   _amt.wav   lane (t * 5) + a: type t + 1 (CHORUS, FLANGE, WOBBLE, RESON,
//              RING, ECHO) at amount 0, 0.25, 0.5, 0.75 and 1. Lane 30 is the
//              phrase alone. A slot starts at amount 0.5.
// an_probe7.py reads, for each lane against the phrase: the level, the peak,
// the width, and how far the spectrum moved.
// The log also holds the number of UGens of each effect def (UGENS <def> <n>).
// On the norns a control-rate operator costs about 0.01% of the scsynth thread
// for each synth, so a law must not grow its def. check_dsp.py holds the counts.
(
var dir = "BENCH_DIR".getenv, tag = "BENCH_TAG".getenv ? "run";
var s = FakeServer(\fake, NetAddr("127.0.0.1", 57999));
var ctx = (server: s, xg: Group.basicNew(s, 1),
    in_b: [Bus.audio(s, 1), Bus.audio(s, 1)], out_b: Bus.audio(s, 2));
Engine_Four.new(ctx, { arg eng;
    var def = { |n| var d = SynthDescLib.global[n]; d.notNil.if({ d.def.asBytes }) };
    var opts = ServerOptions.new.memSize_(262144).numBuffers_(64);
    var syn = [
        SynthDef(\phrase, { |out|
            var chord = LPF.ar(Mix(Saw.ar([110, 164.81, 220.6, 277.18])) * 0.06, 2500)
                * SinOsc.kr(0.25, -0.5pi).range(0.4, 1);
            var kick = Decay2.ar(Impulse.ar(2), 0.001, 0.15) * SinOsc.ar(60) * 0.35;
            var tick = Decay2.ar(Impulse.ar(4, 0.5), 0.0005, 0.03) * Pulse.ar(3100, 0.3) * 0.12;
            Out.ar(out, (chord + kick + tick) ! 2) }),
        SynthDef(\copy, { |from, to| Out.ar(to, In.ar(from, 2)) })
    ];
    var kinds = [nil, \four_fx_mod, eng.hasStretch.if({ \four_fx_flange }, { \four_fx_mod }),
        \four_fx_mod, \four_fx_reson, \four_fx_ring, \four_fx_echo];
    var std = syn.collect({ |d| [0.0, [\d_recv, d.asBytes]] })
        ++ kinds.select(_.notNil).asSet.asArray.collect({ |k| [0.0, [\d_recv, def.(k)]] });
    var amts = [0, 0.25, 0.5, 0.75, 1];
    var lane = { |i, type, amt|
        var bus = 512 + (i * 2), grp = 100 + i;
        [[0.001, [\s_new, \phrase, 1000 + i, 0, 0, \out, bus]],
         [0.002, [\g_new, grp, 1, 0]],
         [0.003, [\s_new, \copy, 2000 + i, 1, 0, \from, bus, \to, i * 2]]]
        ++ type.notNil.if({
            [[0.004, [\s_new, kinds[type], 3000 + i, 1, grp,
                \pbus, bus, \type, type, \amt, amt, \rate, 0.5]]] }, { [] })
    };
    var jobs, run;
    ("COMMANDS " ++ eng.cmdNames.size).postln;
    // what each def costs in UGens: on the norns every one of them counts
    kinds.select(_.notNil).asSet.asArray.sort.do({ |k|
        ("UGENS " ++ k ++ " " ++ SynthDescLib.global[k].def.children.size).postln;
    });
    "FOUR_PLUGIN_DIR".getenv.notNil.if({
        opts.ugenPluginsPath = [Platform.resourceDir +/+ "plugins", "FOUR_PLUGIN_DIR".getenv];
    });
    jobs = [
        [\amt, 9.0, 62,
            (0..29).collect({ |i| lane.(i, i.div(5) + 1, amts[i % 5]) }).flatten(1)
            ++ lane.(30, nil, 0)]
    ];
    run = { |i|
        if (i >= jobs.size) { "PROBE_DONE".postln; 0.exit } {
            var name, dur, nch, msgs, score;
            #name, dur, nch, msgs = jobs[i];
            score = std ++ msgs ++ [[dur, [\c_set, 0, 0]]];
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
