// A new take starts at the start of its buffer (C4 of doc/signature-workflow.md,
// the forty-ninth change). run_probe.sh <work> <tag> probe8.scd
// io's write head is one for the four tracks. It stopped where a pass ended and
// the next pass went on from there, so a part could cross the end of its 60 s.
// Now Lua steps io's `rec_pass` when it opens a new take (rec_track's second
// argument), and the head goes to 0. This probe drives \four_io as the engine
// does: KEEP THIS IN STEP WITH the rec_track command and the rec action.
//
// One io on a buffer pair of 4 s, a sine at its input, four passes:
//   0.5 to 1.5 s  220 Hz  the first pass: the head starts at 0 with the synth
//   2.0 to 2.5 s  331 Hz  a NEW TAKE: rec_pass steps in the same bundle as rec
//   3.0 to 3.3 s  442 Hz  rec alone, as a START after a STOP: the head goes on
//   3.6 to 3.8 s  550 Hz  a NEW TAKE: rec_pass steps one block before rec
// _take.wav  channels 0 and 1: io's output. Channel 2: the head's polled phase
//            (0 to 1 of the buffer). Channel 3, from 4.3 s: the left buffer
//            played back from its start, so the file shows where each pass is.
// The buffer then holds 550 Hz, 331 Hz, 442 Hz and 220 Hz, in that order, in
// its first 1.01 s. An engine without rec_pass lays the four end to end.
(
var dir = "BENCH_DIR".getenv, tag = "BENCH_TAG".getenv ? "run";
var s = FakeServer(\fake, NetAddr("127.0.0.1", 57999));
var ctx = (server: s, xg: Group.basicNew(s, 1),
    in_b: [Bus.audio(s, 1), Bus.audio(s, 1)], out_b: Bus.audio(s, 2));
Engine_Four.new(ctx, { arg eng;
    var def = { |n| var d = SynthDescLib.global[n]; d.notNil.if({ d.def.asBytes }) };
    var opts = ServerOptions.new.memSize_(262144).numBuffers_(64);
    var syn = [
        SynthDef(\sine, { |out, freq = 220, amp = 0.25| Out.ar(out, SinOsc.ar(freq, 0, amp) ! 2) }),
        SynthDef(\headtap, { |bus, out| Out.ar(out, K2A.ar(In.kr(bus))) }),
        SynthDef(\bufplay, { |buf, out| Out.ar(out, PlayBuf.ar(1, buf, 1, 1, 0, 0)) })
    ];
    var std = syn.collect({ |d| [0.0, [\d_recv, d.asBytes]] }) ++ [[0.0, [\d_recv, def.(\four_io)]]];
    var b = 600, block = 64 / 48000;
    // does this engine's io know rec_pass? An older one ignores the control.
    var has = SynthDescLib.global[\four_io].controlNames.includes(\rec_pass);
    var jobs, run;
    ("COMMANDS " ++ eng.cmdNames.size).postln;
    ("REC PASS " ++ has).postln;
    ("UGENS four_io " ++ SynthDescLib.global[\four_io].def.children.size).postln;
    "FOUR_PLUGIN_DIR".getenv.notNil.if({
        opts.ugenPluginsPath = [Platform.resourceDir +/+ "plugins", "FOUR_PLUGIN_DIR".getenv];
    });
    jobs = [
        [\take, 8.5, 4, [
            [0.0, [\b_alloc, 0, 192000, 1]], [0.0, [\b_alloc, 1, 192000, 1]],
            [0.001, [\s_new, \sine, 1000, 0, 0, \out, b]],
            [0.002, [\s_new, \four_io, 1010, 1, 0, \in1, b, \in2, b + 1, \out, 0, \buf_l, 0, \buf_r, 1,
                \play_bus, b + 2, \rec_phase_out, 0, \rec_amp_out, 1, \dry_wet, 1, \level, 1,
                \lane_bus, b + 4, \dly_send, b + 6, \dly_ret, b + 8, \rev_send, b + 10, \rev_ret, b + 12,
                \t2_ret, b + 14, \lanes_dly, b + 16, \lanes_rev, b + 18, \own_out, b + 20, \rec, 0]],
            [0.003, [\s_new, \headtap, 1020, 1, 0, \bus, 0, \out, 2]],
            [0.5, [\n_set, 1010, \rec, 1]],
            [1.5, [\n_set, 1010, \rec, 0]],
            [1.9, [\n_set, 1000, \freq, 331]],
            [2.0, [\n_set, 1010, \rec_pass, 1], [\n_set, 1010, \rec, 1]],
            [2.5, [\n_set, 1010, \rec, 0]],
            [2.9, [\n_set, 1000, \freq, 442]],
            [3.0, [\n_set, 1010, \rec, 1]],
            [3.3, [\n_set, 1010, \rec, 0]],
            [3.5, [\n_set, 1000, \freq, 550]],
            [3.6, [\n_set, 1010, \rec_pass, 2]],
            [3.6 + block, [\n_set, 1010, \rec, 1]],
            [3.8, [\n_set, 1010, \rec, 0]],
            [4.2, [\n_free, 1000]],
            [4.3, [\s_new, \bufplay, 1030, 1, 0, \buf, 0, \out, 3]]]]
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
