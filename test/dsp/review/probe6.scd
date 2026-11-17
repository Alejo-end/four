// The effect slot at a change of type. run_probe.sh <work> <tag> probe6.scd
// Gate row 19.12 on the device: six TYPE taps over a tone broke the sound.
// This probe renders the same change offline, with the engine's own effect
// SynthDefs, and an_probe6.py scores BOTH channels.
//
// A lane here is the gate's tone (220, 331 and 442 Hz, the same on both
// channels) on a bus of its own, a group for the slot's synths, and a copy to
// the output. A step follows Engine_Four.laneFx: the same kind is a set of
// `type`. Another kind is ONE bundle that releases the old synth and adds the
// new one at the group's tail. KEEP THIS IN STEP WITH laneFx.
//   _walk.wav   CHORUS at 0.3 s, then the six taps of row 19.12
//   _pairs.wav  lane (a * 7) + b: type a from 0.05 s, type b at 1.5404 s, for
//               every a and b from 0 (OFF) to 6. Lane 49 is the tone alone.
//               At 1.5404 s the tone is near its peak (-0.239) when the
//               block starts, so a line that catches it mid-wave shows.
//   _more.wav   channels 0 and 1: the shared delay (\four_delay) born at
//               1.5404 s under the tone, as updateDelay starts it when the
//               mix leaves 0. Its first echo comes 0.3 s later.
//               channels 2 and 3: a lane's filter at 400 Hz, LP to HP at
//               1.5404 s and HP to BP at 2.0404 s, each ONE bundle that
//               releases the old family and starts the new one (laneFilter).
// From the pairs, an_probe6.py also builds the crossover the two synths would
// make side by side: (a to OFF) + (OFF to b) - the tone. The engine's two
// synths are in SERIES on the bus, so the difference is the series path.
(
var dir = "BENCH_DIR".getenv, tag = "BENCH_TAG".getenv ? "run";
var s = FakeServer(\fake, NetAddr("127.0.0.1", 57999));
var ctx = (server: s, xg: Group.basicNew(s, 1),
    in_b: [Bus.audio(s, 1), Bus.audio(s, 1)], out_b: Bus.audio(s, 2));
Engine_Four.new(ctx, { arg eng;
    var def = { |n| var d = SynthDescLib.global[n]; d.notNil.if({ d.def.asBytes }) };
    var opts = ServerOptions.new.memSize_(262144).numBuffers_(64);
    var syn = [
        SynthDef(\tone3, { |out, amp = 0.1425|
            Out.ar(out, ((SinOsc.ar(220) + SinOsc.ar(331, 0, 0.5) + SinOsc.ar(442, 0, 0.25)) * amp) ! 2) }),
        SynthDef(\copy, { |from, to| Out.ar(to, In.ar(from, 2)) })
    ];
    var kinds = [nil, \four_fx_mod, eng.hasStretch.if({ \four_fx_flange }, { \four_fx_mod }),
        \four_fx_mod, \four_fx_reson, \four_fx_ring, \four_fx_echo];
    var std = syn.collect({ |d| [0.0, [\d_recv, d.asBytes]] })
        ++ (kinds.select(_.notNil).asSet.asArray ++ [\four_delay, \four_filt_lo, \four_filt_hi])
            .collect({ |k| [0.0, [\d_recv, def.(k)]] });
    var nid = 3000;
    // one lane: its messages for the steps [[time, type], ...]
    var lane = { |i, steps|
        var bus = 512 + (i * 2), grp = 100 + i, kind = nil, node = nil;
        [[0.001, [\s_new, \tone3, 1000 + i, 0, 0, \out, bus]],
         [0.002, [\g_new, grp, 1, 0]],
         [0.003, [\s_new, \copy, 2000 + i, 1, 0, \from, bus, \to, i * 2]]]
        ++ steps.collect({ |st|
            var t = st[0], type = st[1], k = kinds[type], out;
            (k == kind).if({
                out = node.notNil.if({ [t, [\n_set, node, \type, type]] });
            }, {
                out = [t];
                node.notNil.if({ out = out.add([\n_set, node, \gate, 0]) });
                k.notNil.if({
                    nid = nid + 1; node = nid;
                    out = out.add([\s_new, k, node, 1, grp, \pbus, bus, \type, type, \amt, 0.5, \rate, 0.5]);
                }, { node = nil });
                kind = k;
                (out.size < 2).if({ out = nil });
            });
            out
        }).select(_.notNil)
    };
    var jobs, run;
    ("COMMANDS " ++ eng.cmdNames.size).postln;
    "FOUR_PLUGIN_DIR".getenv.notNil.if({
        opts.ugenPluginsPath = [Platform.resourceDir +/+ "plugins", "FOUR_PLUGIN_DIR".getenv];
    });
    jobs = [
        [\walk, 5.2, 2,
            lane.(0, [[0.3, 1]] ++ [2, 3, 4, 5, 6, 1].collect({ |ty, k| [1.0037 + (0.6 * k), ty] }))],
        [\pairs, 2.7, 100,
            (0..48).collect({ |i| lane.(i, [[0.05, i.div(7)], [1.5404, i % 7]]) }).flatten(1)
            ++ lane.(49, [])],
        [\more, 2.9, 4, [
            [0.001, [\s_new, \tone3, 1000, 0, 0, \out, 700]],
            [0.002, [\g_new, 100, 1, 0]],
            [0.003, [\s_new, \copy, 2000, 1, 0, \from, 712, \to, 2]],
            [1.5404, [\s_new, \four_delay, 2500, 1, 100, \in_bus, 700, \out_bus, 0]],
            [0.05, [\s_new, \four_filt_lo, 2600, 1, 100, \sbus, 700, \pbus, 712,
                \cutoff, 400, \filt_type, 0]],
            [1.5404, [\n_set, 2600, \gate, 0], [\s_new, \four_filt_hi, 2601, 1, 100,
                \sbus, 700, \pbus, 712, \cutoff, 400, \filt_type, 1]],
            [2.0404, [\n_set, 2601, \gate, 0], [\s_new, \four_filt_lo, 2602, 1, 100,
                \sbus, 700, \pbus, 712, \cutoff, 400, \filt_type, 2]]]]
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
