// A voice change keeps its sound and its place (C2 of doc/signature-workflow.md,
// the fifty-first change). run_probe.sh <work> <tag> probe9.scd
// K3 MODE, or a scene that lands, puts another drone on the track. The old one
// left in 20 ms at once, and a new WARP or PV drone is silent while its windows
// and frames fill: a hole. The new head also started at the window's start, so
// the loop jumped back. The engine's swapDrone now holds the old drone until the
// new one sounds (modeFade) and starts the new head at the old one's frame,
// moved by the two drones' delays (modeLat).
// This probe sends what swapDrone sends: KEEP THIS IN STEP WITH IT. It takes
// the place of probe 1's section 6, which sent the old law.
//
// Two takes, each in a buffer pair of 8 s: a 1 kHz tone at -6 dBFS (the take of
// probe 1), and a phrase (a chord of four saws, a kick and a tick, as probe 7).
// A drone's window is 0.05 to 0.45 of its buffer, 3.2 s.
//   _rise.wav    each drone alone, born at 5.0 s over the tone: how long it
//                takes to sound. Pairs: GRAIN, WARP, PV, and CLOUD with the plugin.
//   _change.wav  lane k: an old drone from 4.0 s and the swap at 5.0 s.
//                Channels 3k and 3k+1 are the lane's sound, 3k+2 its head's
//                place (0 to 1 of the buffer). Lanes 0 to 5 are over the tone:
//                PLAY to GRAIN, WARP, PV and CLOUD, then WARP to PLAY and PV to
//                PLAY. Lanes 6 to 11 are the same six over the phrase.
//   _steady.wav  each drone alone since 4.0 s, with no change: what the old
//                and the new sound of a lane are by themselves. Pairs 0 to 4
//                are GRAIN, WARP, PV, PLAY and CLOUD over the tone, pairs 5
//                to 9 the same over the phrase.
(
var dir = "BENCH_DIR".getenv, tag = "BENCH_TAG".getenv ? "run";
var s = FakeServer(\fake, NetAddr("127.0.0.1", 57999));
var ctx = (server: s, xg: Group.basicNew(s, 1),
    in_b: [Bus.audio(s, 1), Bus.audio(s, 1)], out_b: Bus.audio(s, 2));
Engine_Four.new(ctx, { arg eng;
    var def = { |n| var d = SynthDescLib.global[n]; d.notNil.if({ d.def.asBytes }) };
    var opts = ServerOptions.new.memSize_(262144).numBuffers_(64);
    var frames = 384000, lo = 0.05, hi = 0.45, tOld = 4.0, tSwap = 5.0;
    var syn = [
        SynthDef(\phrase_fill, { |buf_l, buf_r|
            var chord = LPF.ar(Mix(Saw.ar([110, 164.81, 220.6, 277.18])) * 0.06, 2500)
                * SinOsc.kr(0.25, -0.5pi).range(0.4, 1);
            var kick = Decay2.ar(Impulse.ar(2), 0.001, 0.15) * SinOsc.ar(60) * 0.35;
            var tick = Decay2.ar(Impulse.ar(4, 0.5), 0.0005, 0.03) * Pulse.ar(3100, 0.3) * 0.12;
            var x = chord + kick + tick;
            RecordBuf.ar(x, buf_l, loop: 0);
            RecordBuf.ar(x, buf_r, loop: 0, doneAction: 2) }),
        SynthDef(\headtap, { |bus, out| Out.ar(out, K2A.ar(In.kr(bus))) })
    ];
    // the modes the engine has: 1 GRAIN, 2 WARP, 3 PV, 4 PLAY, 5 CLOUD
    var names = [nil, \GRAIN, \WARP, \PV, \PLAY, \CLOUD];
    var cloud = eng.droneDef(5) == \four_clouds;
    var drones = [\four_grain, \four_warp, \four_pv, \four_play] ++ cloud.if({ [\four_clouds] }, { [] });
    var std = syn.collect({ |d| [0.0, [\d_recv, d.asBytes]] })
        ++ drones.collect({ |k| [0.0, [\d_recv, def.(k)]] })
        ++ [[0.0, [\b_alloc, 0, frames, 1]], [0.0, [\b_alloc, 1, frames, 1]],
            [0.0, [\b_alloc, 2, frames, 1]], [0.0, [\b_alloc, 3, frames, 1]],
            // 8000 cycles in 8 s: 1 kHz at 0.5
            [0.001, [\b_gen, 0, \sine2, 0, 8000, 0.5]], [0.001, [\b_gen, 1, \sine2, 0, 8000, 0.5]],
            [0.002, [\s_new, \phrase_fill, 900, 0, 0, \buf_l, 2, \buf_r, 3]]];
    // what swapDrone knows: the hold of the mode that comes, and the head's frame
    // (the fade into GRAIN follows the track's grain size: 0.1 s here, the def's own)
    var fade = { |i| eng.respondsTo(\modeFade).if({ eng.modeFade(i, (size: 0.1)) }, { nil }) };
    var lat = { |i| eng.respondsTo(\modeLat).if({ eng.modeLat(i) }, { 0 }) };
    var args = { |buf, bus, kbus| [\buf_l, buf, \buf_r, buf + 1, \play_bus, bus, \phase_out, kbus,
        \pos_start, lo, \pos_end, hi, \level, 1] };
    var nid = 2000;
    // one lane: the drone of mode `from` at tOld, the swap to mode `to` at tSwap
    var lane = { |k, buf, from, to|
        var bus = k * 3, kbus = 20 + k, a = nid + 1, b = nid + 2, hf = fade.(to), h, f, c, head, msgs;
        nid = nid + 2;
        // what the new drone needs to start where the old one is: the
        // engine's headArgs, at a scan and a pitch of 1 (a block of travel,
        // the two drones' delays, less the window's start)
        head = [\hfrom, frames,
            \hlead, 64 - (lat.(from) * 48000) + (lat.(to) * 48000) - (lo * frames),
            \hspan, ((hi - lo) * frames).round];
        msgs = [[0.003, [\s_new, \headtap, 3000 + k, 1, 0, \bus, kbus, \out, bus + 2]],
            [tOld, [\s_new, eng.droneDef(from), a, 0, 0] ++ args.(buf, bus, kbus)]];
        hf.isNil.if({
            // an engine from before: the release and the spawn, and the head at 0
            msgs = msgs ++ [[tSwap, [\n_set, a, \gate, 0, \handover, 1]],
                [tSwap, [\s_new, eng.droneDef(to), b, 0, 0] ++ args.(buf, bus, kbus)]];
        }, {
            // swapDrone's one bundle: the old drone's release with its hold,
            // its fade and its curve, and the new drone at the head of the group
            #h, f, c = hf;
            msgs = msgs ++ [[tSwap,
                [\n_set, a, \gate, 0, \handover, 1, \hold, h, \rel, f, \crv, c],
                [\s_new, eng.droneDef(to), b, 0, 0] ++ args.(buf, bus, kbus) ++ head
                    ++ (h > 0).if({ [] }, { [\att, f, \acrv, c] })]];
        });
        msgs
    };
    var pairs = [[4, 1], [4, 2], [4, 3], [4, 5], [2, 4], [3, 4]];
    var jobs, run;
    ("COMMANDS " ++ eng.cmdNames.size).postln;
    ("CLOUD " ++ eng.droneDef(5)).postln;
    ("FADES " ++ (1..5).collect({ |i| fade.(i) })).postln;
    ("DELAYS " ++ (1..5).collect({ |i| (lat.(i) * 48000).round })).postln;
    drones.do({ |k| ("UGENS " ++ k ++ " " ++ SynthDescLib.global[k].def.children.size).postln });
    "FOUR_PLUGIN_DIR".getenv.notNil.if({
        opts.ugenPluginsPath = [Platform.resourceDir +/+ "plugins", "FOUR_PLUGIN_DIR".getenv];
    });
    jobs = [
        [\rise, 6.5, 8,
            [1, 2, 3, 5].collect({ |m, i|
                [tSwap, [\s_new, eng.droneDef(m), 1000 + i, 0, 0] ++ args.(0, i * 2, 40 + i)] })],
        [\change, 6.5, 36,
            pairs.collect({ |p, k| lane.(k, 0, p[0], p[1]) }).flatten(1)
            ++ pairs.collect({ |p, k| lane.(k + 6, 2, p[0], p[1]) }).flatten(1)],
        [\steady, 6.5, 20,
            [0, 2].collect({ |buf, j| (1..5).collect({ |m, i|
                [tOld, [\s_new, eng.droneDef(m), 1900 + (j * 5) + i, 0, 0]
                    ++ args.(buf, ((j * 5) + i) * 2, 50 + (j * 5) + i)] }) }).flatten(1)]
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
