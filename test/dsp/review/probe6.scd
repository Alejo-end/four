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
//   _leave.wav  the reverb and the delay LEAVE (the forty-fourth change). io
//               plays a 1 s burst of the tone into each, and at 1.5404 s, under
//               the tail, the mix goes to 0. The engine frees the synth
//               `spaceWait` seconds later (updateReverb, updateDelay): KEEP THIS
//               IN STEP WITH THEM. An engine without spaceWait freed at once.
//               channels 0 and 1: the reverb. channels 2 and 3: the delay.
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
        SynthDef(\copy, { |from, to| Out.ar(to, In.ar(from, 2)) }),
        SynthDef(\burst3, { |out, amp = 0.1425|
            Out.ar(out, ((SinOsc.ar(220) + SinOsc.ar(331, 0, 0.5) + SinOsc.ar(442, 0, 0.25)) * amp
                * EnvGen.ar(Env.linen(0.005, 1.0, 0.005))) ! 2) })
    ];
    // how long the engine waits before it frees the delay or the reverb
    var wait = eng.respondsTo(\spaceWait).if({ eng.spaceWait }, { 0 });
    // io on buses of its own from `b`, wet only, with its output on `out`
    var io = { |id, b, out, more|
        [0.002, [\s_new, \four_io, id, 1, 0, \dub_out, 1000, \in1, b, \in2, b + 1, \out, out, \buf_l, 0, \buf_r, 1,
            \play_bus, b + 2, \rec_phase_out, 0, \rec_amp_out, 1, \dry_wet, 1, \level, 1,
            \lane_bus, b + 4, \dly_send, b + 6, \dly_ret, b + 8, \rev_send, b + 10, \rev_ret, b + 12,
            \t2_ret, b + 14, \lanes_dly, b + 16, \lanes_rev, b + 18, \own_out, b + 20, \rec, 0] ++ more]
    };
    // the mix to 0 at t, and the free `wait` later (one bundle when wait is 0)
    var leave = { |t, ioId, key, node|
        (wait > 0).if({ [[t, [\n_set, ioId, key, 0]], [t + wait, [\n_free, node]]] },
            { [[t, [\n_set, ioId, key, 0], [\n_free, node]]] })
    };
    // the engine's own table of the effect types' defs (fxKind)
    var kinds = (0..6).collect({ |t| eng.fxKind(t) });
    var std = syn.collect({ |d| [0.0, [\d_recv, d.asBytes]] })
        ++ (kinds.select(_.notNil).asSet.asArray
            ++ [\four_delay, \four_filt_lo, \four_filt_hi, \four_io, \four_reverb])
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
    ("SPACE WAIT " ++ wait).postln;
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
                \sbus, 700, \pbus, 712, \cutoff, 400, \filt_type, 2]]]],
        [\leave, 2.4, 4, [
            [0.0, [\b_alloc, 0, 96000, 1]], [0.0, [\b_alloc, 1, 96000, 1]],
            [0.05, [\s_new, \burst3, 1000, 0, 0, \out, 604]],
            [0.05, [\s_new, \burst3, 1001, 0, 0, \out, 644]],
            io.(1010, 600, 0, [\fx_rev, 1, \rev_mix, 0.5]),
            [0.003, [\s_new, \four_reverb, 1100, 3, 1010, \in_bus, 610, \out_bus, 612, \rev_decay, 4]],
            io.(1011, 640, 2, [\fx_dly, 1, \delay_mix, 0.5]),
            [0.003, [\s_new, \four_delay, 1101, 3, 1011, \in_bus, 646, \out_bus, 648,
                \delay_time, 0.3, \delay_fb, 0.6, \delay_mix, 0.5]]]
            ++ leave.(1.5404, 1010, \rev_mix, 1100) ++ leave.(1.5404, 1011, \delay_mix, 1101)]
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
