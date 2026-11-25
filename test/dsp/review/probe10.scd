// probe10: AN ALIGNED OVERDUB and A HEAD SYNC (the sixty-seventh change).
// One score, _dub.wav, 4 channels, a buffer of 4 s:
//   A PLAY drone reads the window 0.25 to 0.5 (1.0 to 2.0 s of the buffer)
//   and writes its place on control bus 0: channel 0.
//   io and \four_dub write their place on control bus 1: channel 1.
//   1.37 s: an aligned pass of 440 Hz, as the engine makes one (io's rec
//           stays 0, \four_dub after io). 1.6 s: it ends.
//   2.5 s:  head_sync on the drone (\four_sync), half a window off: it jumps.
//   3.495 s: head_sync again, 5 ms early: the loop is in time, so nothing.
//   Channel 2: a second PLAY drone over a 220 Hz tone in a window of 1 s, with
//   the same two syncs (the seventy-first change: a jump is faded).
//   3.3 s:  a second aligned pass, of 880 Hz, which crosses the window's end.
//   Channel 3, from 4.3 s: the left buffer played back from its start.
// KEEP THIS IN STEP WITH rec_track, updateDub, ioGate and head_sync.
(
var dir = "BENCH_DIR".getenv, tag = "BENCH_TAG".getenv ? "run";
var s = FakeServer(\fake, NetAddr("127.0.0.1", 57998));
var ctx = (server: s, xg: Group.basicNew(s, 1),
    in_b: [Bus.audio(s, 1), Bus.audio(s, 1)], out_b: Bus.audio(s, 2));
Engine_Four.new(ctx, { arg eng;
    var def = { |n| var d = SynthDescLib.global[n]; d.notNil.if({ d.def.asBytes }) };
    var opts = ServerOptions.new.memSize_(262144).numBuffers_(64);
    var syn = [
        SynthDef(\sine, { |out, freq = 440, amp = 0.25| Out.ar(out, SinOsc.ar(freq, 0, amp) ! 2) }),
        SynthDef(\headtap, { |bus, out| Out.ar(out, K2A.ar(In.kr(bus))) }),
        SynthDef(\audtap, { |bus, out| Out.ar(out, In.ar(bus)) }),
        SynthDef(\bufplay, { |buf, out| Out.ar(out, PlayBuf.ar(1, buf, 1, 1, 0, 0)) })
    ];
    var std = syn.collect({ |d| [0.0, [\d_recv, d.asBytes]] })
        ++ [\four_io, \four_play, \four_dub, \four_sync, \four_meter].collect({ |n| [0.0, [\d_recv, def.(n)]] });
    var b = 600, d = 1000, score;
    var dub = { |id, on|
        [[on, [\s_new, \four_dub, id, 3, 1010, \buf_l, 0, \buf_r, 1, \src_bus, d, \from_bus, 0,
                \rec_phase_out, 1, \pos_start, 0.25, \pos_end, 0.5, \rec, 1,
                \rec_level, 1, \pre_level, 0]]]
    };
    var sync = { |id, after, bus, from, sb, buf, t|
        [[t, [\s_new, \four_sync, id, 3, after, \play_bus, bus, \from_bus, from, \sync_bus, sb,
            \buf, buf, \pos_start, 0.25, \pos_end, 0.5, \duck, 1]]]
    };
    ("COMMANDS " ++ eng.cmdNames.size).postln;
    ("UGENS four_dub " ++ SynthDescLib.global[\four_dub].def.children.size).postln;
    ("UGENS four_sync " ++ SynthDescLib.global[\four_sync].def.children.size).postln;
    ("UGENS four_meter " ++ SynthDescLib.global[\four_meter].def.children.size).postln;
    "FOUR_PLUGIN_DIR".getenv.notNil.if({
        opts.ugenPluginsPath = [Platform.resourceDir +/+ "plugins", "FOUR_PLUGIN_DIR".getenv];
    });
    score = std ++ [
        [0.0, [\b_alloc, 0, 192000, 1]], [0.0, [\b_alloc, 1, 192000, 1]],
        [0.0, [\b_alloc, 2, 192000, 1]], [0.0005, [\b_gen, 2, \sine2, 4, 880, 0.25]],
        [0.001, [\s_new, \sine, 1000, 0, 0, \out, b]],
        [0.002, [\s_new, \four_io, 1010, 1, 0, \dub_out, d, \in1, b, \in2, b + 1, \out, 950,
            \buf_l, 0, \buf_r, 1, \play_bus, b + 2, \rec_phase_out, 1, \rec_amp_out, 2,
            \dry_wet, 1, \level, 1, \lane_bus, b + 4, \dly_send, b + 6, \dly_ret, b + 8,
            \rev_send, b + 10, \rev_ret, b + 12, \t2_ret, b + 14, \lanes_dly, b + 16,
            \lanes_rev, b + 18, \own_out, b + 20, \rec, 0]],
        [0.003, [\s_new, \four_play, 1040, 0, 0, \buf_l, 0, \buf_r, 1, \play_bus, 960,
            \phase_out, 0, \pos_start, 0.25, \pos_end, 0.5, \level, 1, \sync, \c6]],
        [0.003, [\s_new, \four_play, 1041, 0, 0, \buf_l, 2, \buf_r, 2, \play_bus, 962,
            \phase_out, 5, \pos_start, 0.25, \pos_end, 0.5, \level, 1, \sync, \c7]],
        [0.004, [\s_new, \audtap, 1022, 1, 0, \bus, 962, \out, 2]],
        [0.004, [\s_new, \headtap, 1020, 1, 0, \bus, 0, \out, 0]],
        [0.004, [\s_new, \headtap, 1021, 1, 0, \bus, 1, \out, 1]],
        [1.6, [\n_set, 1050, \rec, 0]],
        [2.9, [\n_set, 1000, \freq, 880]],
        [3.6, [\n_set, 1051, \rec, 0]],
        // the tracks' meters: the sine on bus b (0.25) and an unwritten bus
        [0.004, [\s_new, \four_meter, 1070, 3, 1010, \ob1, 1900, \ob2, b, \ob3, 1902, \ob4, 1904, \out, 10]],
        [0.005, [\s_new, \headtap, 1071, 1, 0, \bus, 11, \out, 3]],
        [4.1, [\n_free, 1071]],
        [4.2, [\n_free, 1000]],
        [4.3, [\s_new, \bufplay, 1030, 1, 0, \buf, 0, \out, 3]],
        [8.5, [\c_set, 0, 0]]
    ] ++ dub.(1050, 1.37) ++ dub.(1051, 3.3)
        ++ sync.(1060, 1040, 960, 0, 6, 0, 2.5) ++ sync.(1061, 1041, 962, 5, 7, 2, 2.5)
        ++ sync.(1062, 1040, 960, 0, 6, 0, 3.495) ++ sync.(1063, 1041, 962, 5, 7, 2, 3.495);
    score = score.sort({ |a, b| a[0] < b[0] });
    Score(score).recordNRT(dir +/+ tag ++ "_dub.osc", dir +/+ tag ++ "_dub.wav",
        sampleRate: 48000, headerFormat: "WAV", sampleFormat: "float",
        options: opts.numOutputBusChannels_(4), duration: 8.5,
        action: { "done dub".postln; "PROBE_DONE".postln; 0.exit });
});
)
