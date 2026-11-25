// Engine_Four.sc — THE ONLY engine file for the `four` norns script.
//
// four is mangler with FOUR engine tracks. Tracks 2 to 4 are more drones
// (any mode) on the same take, each with its own window, pitch, grain knobs,
// its own filter (\four_strip) and its own level. They join track 1
// after io's filter, so the delay and reverb are shared. Their commands
// are the drone's own names with a `t2_`, `t3_` or `t4_` prefix, plus the
// strip's level, cutoff, resonance and filt_type, and the mode: 26 a track.
// COLOR AND SPACE (the S-4's devices after the filter): every track has its
// own drive and crush (sample rate and bit reduction), and its own send
// amount into the shared delay (fx_dly) and reverb (fx_rev). Both sends
// start at 0 (SPACE is two sends since four's nineteenth change). Track 1's
// are io's `drive`, `crush`, `fx_dly`, `fx_rev`; the others' are strip keys.
// ROUTING (the S-4's sends): `send_<from>_<to>` sends one track's filtered
// output into another track's filter, 12 sends in all. A send arrives one
// block late (InFeedback) and goes through a tanh, so a ring of sends can
// feed back but never runs away. OWN MATERIAL: each track plays its own
// 60s buffer pair; rec_track picks the pair io records into (and, with a
// second argument of 1, puts the write head at its start), buf_track the
// pair the buffer commands use. THE EFFECT: every track has two effect slots
// in series after its COLOR (`effect` and `effect2` pick OFF, CHORUS, FLANGE,
// WOBBLE, RESON, RING or ECHO; `_amt` and `_rate` are each slot's knobs).
// Count: 199 (CLAUDE.md has the sum; test/test_control.lua checks it).
//
// HARD RULE: exactly one `Engine_Four` class under dust/code (and mangler's `Engine_Mangler` is a different class). A duplicate
// hangs every norns script forever on "LOADING".
//
// Architecture: one persistent `io` synth (input, record head, dry/wet mix,
// resample/regen feedback, FILTER, output) + ONE `mode` drone at a time
// (OFF/GRAIN/WARP/PV/PLAY/CLOUD, spawned/freed by setMode) + a polyphonic voice layer
// + TWO spawn/free FX synths: the delay (updateDelay — alive while delay_mix
// > 0 or the feedback is a near-infinite hold) and the reverb (updateReverb,
// only while rev_mix > 0) + the spawn/free erosion head (updateErode, only
// while erode > 0 in PLAY) + the spawn/release beat repeat (updateRepeat,
// only while the `beat_repeat` command holds a length > 0, placed after io on the
// output bus). Drone and voices Out.ar additively onto play_bus;
// io reads it. Plugin UGens (DFM1, MiClouds, JPverb and our own FourStretch
// set, FourCloud among it) are guarded via .asClass -> stock fallback so a
// missing plugin never bricks the load. The fallbacks do NOT sound the same (the stock filter, the
// FreeVerb reverb): doc/measurements/2026-11-15/README.md.
//
// DEVICE NOTES: context.in_b is an ARRAY of two mono busses, out_b one stereo
// bus. SC errors land in maiden's SC tab, not matron. Editing this file needs
// SYSTEM > RESTART (sclang recompiles at startup); confirm the command count in
// the load log after.

Engine_Four : CroneEngine {
    var <ioSynth, <playSynth;
    var <playGroup;
    var <bufL, <bufR;
    // OWN MATERIAL PER TRACK (the S-4 way): four buffer pairs, one per track.
    // bufL/bufR are track 1's. recIdx is the pair io records into (rec_track),
    // opIdx the pair clear, read_file, write_take, read_take and the pad
    // voices act on (buf_track); the Lua side sets both to the focused track
    // and moves opIdx alone to save or restore the other tracks.
    var <bufLs, <bufRs, <recIdx = 0, <opIdx = 0;
    // recPass counts the passes that began at the start of their buffer
    // (rec_track's second argument). io's write head goes to 0 when it steps.
    var <recPass = 0;
    // AN ALIGNED OVERDUB (rec_track's second argument 2, the sixty-seventh
    // change): dubOn says the passes go to \four_dub, which starts at the
    // track's read head and loops in its window. dubSynth lives only while a
    // pass runs. dubBus carries io's record signal to it, and dubVals holds
    // the knobs it takes when it is made.
    var dubOn = false, dubSynth, dubBus, dubVals;
    // bufGen counts, for each pair, the commands that put material in it or
    // cleared it. A clear zeroes the pair again a moment later (clearWait),
    // and only if nothing else came to that pair since.
    var bufGen;
    // A VOICE CHANGE (swapDrone): for each track, the drone that still sounds
    // under the one that took over, and a count for the last change to win.
    var leaving, leaveGen;
    // ...and, for whenFree: when the hold in progress ends, and a count for
    // each track that lets its last request win.
    var swapUntil = 0, modeGen;
    // A KNOB'S GLIDE (gset): when each command last came, and for each
    // control that glides the name of its time control.
    var glideAt, glideKeys;
    var <grainEnv1, <grainEnv2;
    var <playBus;
    var <phaseBus, <recPhaseBus, <recAmpBus;
    var <meterBus, <meterSynth;   // each track's level after its lane (\four_meter)
    var <syncBus;   // four: what each track's drone reads as `sync` (head_sync)
    var <playParams;
    var <ioKeys;
    // reverb+shimmer spawn/free synth: freed once rev_mix is 0 (spaceWait
    // later). send/return busses + last-known reverb params (handed over when
    // the synth is spawned). revGen counts the calls of updateReverb, so a
    // free that waits knows if the mix moved again.
    var <revSynth, <revSendBus, <revRetBus, <revParams, <revMixV, revGen = 0;
    // delay spawn/free synth, same shape: its regeneration loop lives inside
    // it, so freeing it is what flushes the line (which is what \clear wants)
    var <delaySynth, <dlySendBus, <dlyRetBus, <delayParams, dlyGen = 0;
    // erosion spawn/free synth, alive only while erode > 0 in PLAY mode (so
    // at rest nothing writes the take). it reads eroKeys out of playParams;
    // modeV is the mode setMode last switched to (4 = PLAY).
    var <eroSynth, <eroKeys, <modeV;
    // beat repeat spawn/release synth, alive only while held. THREE capture
    // buffers, used in turn: a repeat re-struck while the last one (or two,
    // on a fast spin of the division) fades out captures into one that no
    // fading synth still reads.
    var <repSynth, <repBufs, <repIdx;
    // polyphonic voice layer
    var <activeVoices, <voiceOrder, <voiceParams, <maxVoices;
    // true when a Clouds def compiled (FourCloud from the plugin, or MiClouds
    // from mi-UGens): CLOUD mode then uses the Clouds voice, else the GRAIN
    // granulator
    var <hasClouds;
    // tracks 2 to 4: one Event each (keys n, synth, params, strip,
    // stripParams, bus, phase), the shared return they all add into, and the
    // four tracks' post-filter outputs the sends read (outBuses[0] = track 1)
    var <extra, <tRetBus, <outBuses, <stripKeys;
    // what tracks 2 to 4 send into the delay and the reverb (fx_dly, fx_rev),
    // added by io to track 1's own sends
    var <tDlyBus, <tRevBus;
    // the send levels, sendV[from][to] (1-based), for updateStrip
    var <sendV;
    // one LANE for each track: what its sound passes between its voice and
    // the mix. A lane is a group of small synths, and only the ones that are
    // HEARD exist: one filter family, the colour while drive or crush is up,
    // and an effect synth for each slot that is on. See buildLane.
    var <lanes;
    // true when the FourStretch plugin is there: FLANGE and ECHO then have
    // their own synths (laneFx)
    var <hasStretch;
    // THE PLUGIN AS THE SERVER LOADED IT: [path, mtime] of the FourStretch
    // binary when sclang started, nil when there was none. scsynth loads its
    // plugins once, when sclang boots it right after its own start, so this is
    // the binary the server runs. four can also install or replace its own
    // plugin (lib/mplugin.lua) under a running server; until SYSTEM > RESTART
    // the engine must not name a UGen the server lacks. A def that names one
    // does not load, and every def names FourTanh: the instrument would be silent.
    classvar <bootPlug;

    // The shipped plugin goes into place first, while sclang compiles its
    // classes and before StartUp boots the server: the RESTART that follows
    // `;install` then brings the plugin in, with no second restart. It runs at
    // every sclang start, for every script, so it must stay quick and quiet.
    // A failure here costs nothing: four's load tries again (lib/mplugin.lua).
    *initClass {
        try { this.installPlug };
        StartUp.add({ try { bootPlug = this.plugStamp } });
    }

    // lib/install_plugin.sh holds the rule. With no arch given it asks uname,
    // and it acts on Linux only, so the Mac bench never writes Extensions.
    *installPlug {
        var dir = this.filenameSymbol.asString.dirname.dirname, said;
        said = ["sh", (dir +/+ "lib/install_plugin.sh").shellQuote,
            ("HOME".getenv ? "").shellQuote, dir.shellQuote, "''",
            "/usr/local/bin/scsynth", "/usr/bin/scsynth", "2>/dev/null"].join(" ").unixCmdGetStdOut;
        said.find("installed").notNil.if({
            "four: installed the FourStretch plugin at startup".postln });
        said.find("failed").notNil.if({
            "four: could not install the FourStretch plugin at startup".postln });
    }

    // the FourStretch binary: in FOUR_PLUGIN_DIR on the Mac bench (test/dsp),
    // else in the user Extensions folder. nil when there is none.
    *plugBinary {
        ["FOUR_PLUGIN_DIR".getenv, Platform.userExtensionDir +/+ "FourStretch"].do({ arg d;
            d.notNil.if({
                ["FourStretch.so", "FourStretch.scx"].do({ arg f;
                    File.exists(d +/+ f).if({ ^d +/+ f });
                });
            });
        });
        ^nil
    }

    *plugStamp {
        var p = this.plugBinary;
        ^p.notNil.if({ [p, File.mtime(p)] })
    }

    // whether the binary holds the UGen `name`: a UGen's name is a string in
    // the binary that defines it. A binary built before the UGen was added
    // does not hold it. false when the file cannot be read.
    *plugHas { arg name;
        var p = this.plugBinary, s;
        p.isNil.if({ ^false });
        ^{
            File.use(p, "rb", { arg f; s = String.newClear(f.length); f.read(s) });
            s.find(name).notNil
        }.try({ false })
    }

    *new { arg context, doneCallback;
        ^super.new(context, doneCallback);
    }

    // the drone def for mode i (1=GRAIN 2=WARP 3=PV 4=PLAY 5=CLOUD). GRAIN is
    // the granulator that reads the window itself (\four_grain). CLOUD
    // is Clouds on the playing window (it was GRAIN until four's tenth
    // change): FourCloud, else MiClouds, else the granulator.
    // PLAY is the clean straight loop.
    droneDef { arg i;
        (i == 4).if({ ^\four_play });
        (i == 5).if({ ^hasClouds.if({ \four_clouds }, { \four_grain }) });
        ^[\four_grain, \four_warp, \four_pv].at(i - 1);
    }

    // an extra track's mode: the same release law as setMode. It shares the
    // take's level, rec and freeze (STOP halts it too), and has no erosion.
    // a strip runs only while its track plays or a send feeds it. Measured
    // on the device: three strips always on cost about 18% of the engine
    // thread with every extra track OFF. The pause waits 100ms, so a
    // drone's 20ms release and the filter's tail are heard to the end.
    updateStrip { arg tr;
        var want = (tr[\mode] ? 0) > 0;
        (1..4).do({ arg from;
            (from != tr[\n]).if({
                ((sendV[from - 1][tr[\n] - 1] ? 0) > 0).if({ want = true });
            });
        });
        want.if({
            tr[\strip].run(true);
        }, {
            SystemClock.sched(0.1, {
                var still = (tr[\mode] ? 0) <= 0;
                (1..4).do({ arg from;
                    (from != tr[\n]).if({
                        ((sendV[from - 1][tr[\n] - 1] ? 0) > 0).if({ still = false });
                    });
                });
                still.if({ tr[\strip].run(false) });
                nil
            });
        });
    }

    // ---- the lanes
    // A lane is a group. In order: the in synth (S bus), the filter group
    // (S to P), the colour group, the two effect groups (in place on P), and
    // for tracks 2 to 4 the out synth. lane[\p] holds its last values.
    buildLane { arg i, inBus, outArgs;
        var s = context.server;
        var lane = (p: Dictionary[\cutoff -> 20000, \resonance -> 0.0, \filt_type -> 0,
                \drive -> 0.0, \crush -> 0.0,
                \effect -> 0, \effect_amt -> 0.5, \effect_rate -> 0.5,
                \effect2 -> 0, \effect2_amt -> 0.5, \effect2_rate -> 0.5],
            sBus: Bus.audio(s, 2), pBus: Bus.audio(s, 2),
            fx: [nil, nil], fxKind: [nil, nil]);
        lane[\group] = Group.new(playGroup, \addToTail);
        lane[\in] = Synth.new(\four_lane_in, [
            \in_bus, inBus, \sbus, lane[\sBus],
            \ob1, outBuses[0], \ob2, outBuses[1], \ob3, outBuses[2], \ob4, outBuses[3],
        ], lane[\group], \addToTail);
        lane[\gFilt] = Group.new(lane[\group], \addToTail);
        lane[\gCol] = Group.new(lane[\group], \addToTail);
        lane[\gFx] = [Group.new(lane[\group], \addToTail), Group.new(lane[\group], \addToTail)];
        outArgs.notNil.if({
            lane[\out] = Synth.new(\four_lane_out, [\pbus, lane[\pBus]] ++ outArgs,
                lane[\group], \addToTail);
        });
        lanes[i] = lane;
        this.laneFilter(lane);
    }

    // the filter family that is heard: LO for LP and BP, HI for HP. A change
    // of family releases the old synth and starts the new one in ONE bundle,
    // so their two 20ms ramps cross exactly.
    laneFilter { arg lane;
        var want = ((lane[\p][\filt_type] ? 0).round == 1).if({ \four_filt_hi }, { \four_filt_lo });
        (lane[\filtKind] != want).if({
            context.server.makeBundle(nil, {
                lane[\filt].notNil.if({ lane[\filt].set(\gate, 0) });
                lane[\filt] = Synth.new(want, [
                    \sbus, lane[\sBus], \pbus, lane[\pBus],
                    \cutoff, lane[\p][\cutoff], \resonance, lane[\p][\resonance],
                    \filt_type, lane[\p][\filt_type],
                ], lane[\gFilt], \addToTail);
            });
            lane[\filtKind] = want;
        });
    }

    // the colour synth exists while drive or crush is up. It starts at 0 and
    // is set in the same bundle, so its lags ramp from the bypass. It goes
    // 300ms after both are back at 0, when the lags are down.
    laneColour { arg lane;
        var on = ((lane[\p][\drive] ? 0) > 0) or: { (lane[\p][\crush] ? 0) > 0 };
        on.if({
            lane[\col].isNil.if({
                context.server.makeBundle(nil, {
                    lane[\col] = Synth.new(\four_colour, [\pbus, lane[\pBus]],
                        lane[\gCol], \addToTail);
                    lane[\col].set(\drive, lane[\p][\drive], \crush, lane[\p][\crush]);
                });
            });
        }, {
            lane[\col].notNil.if({
                SystemClock.sched(0.3, {
                    var still = (((lane[\p][\drive] ? 0) > 0) or: { (lane[\p][\crush] ? 0) > 0 }).not;
                    (still and: { lane[\col].notNil }).if({
                        lane[\col].free;
                        lane[\col] = nil;
                    });
                    nil
                });
            });
        });
    }

    // an effect slot (0 or 1): the synth of the type's kind, or none for OFF
    laneFx { arg lane, slot;
        var pre = (slot == 0).if({ "effect" }, { "effect2" });
        var type = (lane[\p][pre.asSymbol] ? 0).round.asInteger.clip(0, 6);
        var kind = [nil, \four_fx_mod, hasStretch.if({ \four_fx_flange }, { \four_fx_mod }),
            \four_fx_mod, \four_fx_reson, \four_fx_ring, \four_fx_echo].at(type);
        (kind == lane[\fxKind][slot]).if({
            lane[\fx][slot].notNil.if({ lane[\fx][slot].set(\type, type) });
        }, {
            context.server.makeBundle(nil, {
                lane[\fx][slot].notNil.if({ lane[\fx][slot].set(\gate, 0) });
                lane[\fx][slot] = kind.notNil.if({
                    Synth.new(kind, [\pbus, lane[\pBus], \type, type,
                        \amt, lane[\p][(pre ++ "_amt").asSymbol],
                        \rate, lane[\p][(pre ++ "_rate").asSymbol],
                    ], lane[\gFx][slot], \addToTail)
                });
            });
            lane[\fxKind][slot] = kind;
        });
    }

    // one value of a lane, by its command name. `t` is the glide time of
    // the write (glideT).
    laneSet { arg i, name, v, t;
        var lane = lanes[i];
        lane[\p][name] = v;
        name.switch(
            \filt_type, { lane[\gFilt].set(name, v); this.laneFilter(lane) },
            \drive, { this.laneColour(lane); this.gset(lane[\gCol], name, v, t) },
            \crush, { this.laneColour(lane); this.gset(lane[\gCol], name, v, t) },
            \effect, { this.laneFx(lane, 0) },
            \effect_amt, { this.gset(lane[\gFx][0], \amt, v, t) },
            \effect_rate, { this.gset(lane[\gFx][0], \rate, v, t) },
            \effect2, { this.laneFx(lane, 1) },
            \effect2_amt, { this.gset(lane[\gFx][1], \amt, v, t) },
            \effect2_rate, { this.gset(lane[\gFx][1], \rate, v, t) },
            \grain_level, { this.gset(lane[\in], \pre_gain, v, t) },
            // cutoff, resonance, and the out synth's level, fx_dly, fx_rev
            { this.gset(lane[\group], name, v, t) }
        );
    }

    // track i (0 to 3): its drone values, and the bus its read head writes
    trackParams { arg i; ^(i == 0).if({ playParams }, { extra[i - 1][\params] }) }
    // track i's `sync` control is mapped to its bus, which \four_sync writes
    syncMap { arg i; ^("c" ++ (syncBus.index + i)).asSymbol }
    trackPhase { arg i; ^(i == 0).if({ phaseBus }, { extra[i - 1][\phase] }) }

    // AN ALIGNED OVERDUB: \four_dub runs while `rec` is up and the passes
    // are aligned (rec_track 2). A rec that falls releases it, and it frees
    // itself 10 ms later. A STOP sends rec 0 and START rec 1, so START makes
    // a new one, at the read head.
    updateDub { arg rec;
        var p;
        (dubOn and: { rec > 0 }).if({
            dubSynth.isNil.if({
                p = this.trackParams(recIdx);
                dubSynth = Synth.new(\four_dub, [
                    \buf_l, bufLs[recIdx], \buf_r, bufRs[recIdx],
                    \src_bus, dubBus, \from_bus, this.trackPhase(recIdx),
                    \rec_phase_out, recPhaseBus,
                    \pos_start, p[\pos_start] ? 0, \pos_end, p[\pos_end] ? 1,
                ] ++ dubVals.getPairs, ioSynth, \addAfter);
            });
        }, {
            dubSynth.notNil.if({ dubSynth.set(\rec, 0); dubSynth = nil });
        });
    }

    // io's two writes, rec and regen. While the passes are aligned io's rec
    // stays 0, so io writes nothing for a pass and \four_dub writes it. A
    // pass always holds regen (io's regenRun has (1 - rec)), so regen is 0
    // in io while an aligned pass runs. (A first version kept io's rec up
    // with rec_level 0 and pre_level 1: their 10 ms lags printed the pass
    // at -66 dB where io's head stood, probe10.)
    ioGate {
        var rec = dubVals[\rec], regen = dubVals[\regen];
        ioSynth.set(\rec, dubOn.if({ 0 }, { rec }),
            \regen, (dubOn and: { rec > 0 }).if({ 0 }, { regen }));
    }

    // a window edge of track i moved: the aligned overdub follows it
    dubWindow { arg i, name, v;
        (dubSynth.notNil and: { i == recIdx }).if({ dubSynth.set(name, v) });
    }

    setModeN { arg tr, i;
        this.whenFree(tr[\n], tr[\synth].notNil and: { i > 0 }, {
            tr[\synth] = this.swapDrone(tr[\n], tr[\synth], tr[\mode] ? 0, i, [
                \buf_l, bufLs[tr[\n] - 1], \buf_r, bufRs[tr[\n] - 1],
                \play_bus, tr[\bus], \phase_out, tr[\phase],
                \sync, this.syncMap(tr[\n] - 1),
                \grain_env1, grainEnv1, \grain_env2, grainEnv2,
                \level, playParams[\level], \rec, playParams[\rec],
                \freeze, playParams[\freeze],
            ] ++ tr[\params].getPairs, tr[\params], bufLs[tr[\n] - 1]);
            tr[\mode] = i;
            this.updateStrip(tr);
        });
    }

    setMode { arg i;
        this.whenFree(1, playSynth.notNil and: { i > 0 }, {
            var from = modeV ? 0;
            modeV = i;
            playSynth = this.swapDrone(1, playSynth, from, i, [
                \buf_l, bufL, \buf_r, bufR,
                \play_bus, playBus, \phase_out, phaseBus,
                \sync, this.syncMap(0),
                \grain_env1, grainEnv1, \grain_env2, grainEnv2,
            ] ++ playParams.getPairs, playParams, bufL);
            this.updateErode;
        });
    }

    // A KNOB'S GLIDE (C6 of doc/signature-workflow.md, the fifty-third
    // change). The time a value takes to its new place, from the time `dt`
    // since the same command last came.
    // A modulator, a motion lane and the fade write once a frame, 67ms
    // apart. A value that comes at that pace glides for a little more than
    // the frame it took, so it is still on its way when the next one comes:
    // the knob draws lines between the frames and never stands still. Any
    // other write lands in 20ms, in a straight line. That is when a hand's
    // turn and a key landed before (the old lags were at 99% after 20 to
    // 33ms), though the line is at half its way after 10ms where a lag was
    // at 75 to 90%.
    // The window is 55 to 90ms. The script's frames are 67ms apart, and
    // late by a few ms at most (measured on the device, 2026-11-16).
    glideLaw { arg dt;
        ^((dt > 0.055) and: { dt < 0.09 }).if({ (dt * 1.2).clip(0.075, 0.11) }, { 0.02 })
    }

    // the glide time of this write of the command `cmd`
    glideT { arg cmd;
        var now = Main.elapsedTime, dt = now - (glideAt[cmd] ? 0);
        glideAt[cmd] = now;
        ^this.glideLaw(dt)
    }

    // set a control, and its glide time with it when it has one (`gl` in
    // the defs). `t` is the write's glideT, nil for a write that no command
    // made. A node that does not have the control ignores the pair.
    gset { arg target, name, v, t;
        var k = glideKeys[name];
        k.isNil.if({ target.set(name, v) }, { target.set(name, v, k, t ? 0.02) });
    }

    // HOW THE DRONE THAT LEAVES GOES, by the mode that comes (0 OFF, 1 GRAIN,
    // 2 WARP, 3 PV, 4 PLAY, 5 CLOUD): [hold, fade, curve]. It stays whole for
    // `hold` seconds, then fades over `fade` on that curve (0 is a straight
    // line). A new drone is not there at once. Measured alone, over a tone,
    // with the plugin (test/dsp/review/probe9.scd):
    //   GRAIN comes up over half of its first grain: 50ms at a size of 0.1s
    //   WARP  rises in a line from 30ms to 175ms, as its windows fill
    //   PV    is silent for 13ms and up at 35ms, its first frame
    //   CLOUD is silent for 341ms (Clouds' own buffer), then there at once
    //   PLAY  is there in 10ms, on the curve of every drone's own start
    // Each row lays the old drone's fade over that rise, so the two add up to
    // one level. Into GRAIN the fade is half of the track's grain size.
    // Into PLAY the two cross in a straight line over 20ms: the new PLAY
    // comes in over the same time and on the same curve (swapDrone sets its
    // `att` and `acrv`), and the two are in step, so they add up to one
    // sound. The line is there for this: the hold is a stage of the old
    // drone's envelope, and with a hold of 0 the stage still takes a block,
    // so the old drone starts to go late. On a line a block is 7%. On the
    // 10ms start every drone has, which is fast at first, the cross read
    // +1.6dB on the Mac's scsynth and +3.2dB on the norns's. On the line
    // it reads +0.5 and +1.2dB.
    // The old law was 20ms for all: a hole of 149ms into WARP, 34ms into PV
    // and 341ms into CLOUD. Without the plugin WARP rises sooner and PV
    // comes later.
    modeFade { arg i, params;
        var grain = [0.005, ((params[\size] ? 0.1) * 0.5).clip(0.03, 0.4), 0];
        (i == 1).if({ ^grain });
        (i == 5).if({ ^hasClouds.if({ [0.335, 0.02, 0] }, { grain }) });
        ^hasStretch.if({
            [[0, 0.02, -4], grain, [0.025, 0.14, 0], [0.012, 0.024, 0], [0, 0.02, 0]]
        }, {
            [[0, 0.02, -4], grain, [0.02, 0.12, 0], [0.033, 0.014, 0], [0, 0.02, 0]]
        }).at(i) ? [0, 0.02, -4]
    }

    // HOW FAR A DRONE'S SOUND LIES BEHIND ITS HEAD, in seconds. PV plays what
    // its head read 2560 frames ago with the plugin (1984 without), and
    // Clouds what it took in 16347 frames ago. PLAY, WARP and GRAIN play what
    // the head reads now. Measured: each drone alone against PLAY, from the
    // same start (probe9's _steady). A new drone starts its head ahead by
    // its own delay, and behind by the delay of the one that leaves, so what
    // is HEARD goes on from the same place. A change from PLAY into PV over a
    // tone then adds two sounds in step. Without this they were a third of a
    // cycle apart at 1kHz, and cancelled for 10ms.
    modeLat { arg i;
        (i == 3).if({ ^hasStretch.if({ 2560 }, { 1984 }) / 48000 });
        (i == 5).if({ ^hasClouds.if({ 16347 / 48000 }, { 0 }) });
        ^0
    }

    // ONE HOLD AT A TIME. A change from one drone to another runs `func` when
    // no drone still waits to leave, on any track. A scene that lands can
    // change four voices in one frame: with a hold for each, eight drones
    // sounded together, and the dense set has no room for that. The changes
    // now follow one another. The last request for a track is the one that
    // runs. A change that doubles nothing (from OFF, or into OFF) runs at once.
    whenFree { arg n, doubles, func;
        var gen, try;
        modeGen[n - 1] = modeGen[n - 1] + 1;
        gen = modeGen[n - 1];
        try = {
            var wait = doubles.if({ swapUntil - Main.elapsedTime }, { 0 });
            (modeGen[n - 1] == gen).if({
                (wait > 0.001).if({
                    SystemClock.sched(wait, { try.value; nil });
                }, { func.value });
            });
        };
        try.value;
    }

    // what a drone that takes over needs to start where the old one is
    // (hfrom, hlead and hspan of winRead): the buffer's frames, the frames to
    // add, the window's frames. The bus the new drone reads holds the old
    // head's place one block ago. Add the travel of that block and the new
    // drone's own delay, take off the old one's delay (modeLat) and the
    // window's start. A head moves at `scan` frames a frame, and PLAY's at
    // `scan` times `pitch`.
    headArgs { arg params, buf, from, to;
        var a = params[\pos_start] ? 0, b = params[\pos_end] ? 1;
        var frames = buf.numFrames;
        var scan = params[\scan] ? 1, pitch = params[\pitch] ? 1;
        var rate = { arg m; scan * (m == 4).if({ pitch }, { 1 }) };
        var lat = { arg m; this.modeLat(m) * buf.sampleRate * rate.(m) };
        ^[\hfrom, frames,
            \hlead, (playGroup.server.options.blockSize * rate.(from)) - lat.(from) + lat.(to)
                - (a.min(b) * frames),
            \hspan, ((a - b).abs.max(0.001) * frames).round.max(64)]
    }

    // A VOICE CHANGE KEEPS ITS SOUND AND ITS PLACE (C2 of
    // doc/signature-workflow.md, the fifty-first change). Track n's drone
    // `old` (of mode `from`) gives way to one of mode i. The answer is the
    // new synth, nil for OFF. All of it is ONE BUNDLE, so it happens in one
    // block:
    //   the old drone stops writing the phase bus (`handover`), so the
    //   screen follows one head
    //   ITS PLACE: the new head starts where the old one is (headArgs), and
    //   the loop goes on from where it was. From OFF it starts at the
    //   window's start.
    //   ITS SOUND: the old drone is released with a hold, a fade and a curve
    //   (modeFade), under the rise of the new one. With no hold (into PLAY)
    //   the new drone comes in over the same time, on the same curve.
    // Into OFF the drone is released as before: it writes the bus to its
    // end, so the bus holds the last place. A drone that still waits to
    // leave is sent away in 20ms (a gate under -1 does that).
    swapDrone { arg n, old, from, i, args, params, buf;
        var new, hold, fade, crv, gen, was = leaving[n - 1];
        leaveGen[n - 1] = leaveGen[n - 1] + 1;
        gen = leaveGen[n - 1];
        (i > 0).not.if({
            was.notNil.if({ was.set(\gate, -1.02); leaving[n - 1] = nil });
            old.notNil.if({ old.set(\gate, 0, \handover, 0) });
            ^nil
        });
        old.isNil.if({ ^Synth.new(this.droneDef(i), args, playGroup) });
        #hold, fade, crv = this.modeFade(i, params);
        playGroup.server.makeBundle(nil, {
            old.set(\gate, 0, \handover, 1, \hold, hold, \rel, fade, \crv, crv);
            new = Synth.new(this.droneDef(i),
                args ++ this.headArgs(params, buf, from, i)
                    ++ (hold > 0).if({ [] }, { [\att, fade, \acrv, crv] }), playGroup);
        });
        // (whenFree reads swapUntil: no other change doubles a drone before then)
        swapUntil = Main.elapsedTime + hold + fade;
        leaving[n - 1] = old;
        // (it frees itself then. A little before, so that a change into OFF
        // never sends a gate to a node that has just gone)
        SystemClock.sched((hold + fade - 0.01).max(0), {
            (leaveGen[n - 1] == gen).if({ leaving[n - 1] = nil });
            nil
        });
        ^new
    }

    // How long the delay and the reverb live on once their mix is 0. io plays
    // a return at its mix through a 30ms lag, so 0.1s later the return is
    // 100dB down and the free cuts nothing that sounds. A free at once cut
    // the tail at its full level: a click (test/dsp/review/probe6.scd, gate
    // row 19.30). A mix that comes back inside the wait keeps the synth.
    spaceWait { ^0.1 }

    // How long after a clear the pair is zeroed a second time. A write that
    // ran at the clear (regen, or a take) fades out over 10 ms in io, and the
    // script stops regen a moment after the clear: that fade wrote into the
    // pair that was just zeroed. On the device 6.7 ms of sound stayed in an
    // erased buffer, where regen's head stood (gate row 10.8, the fiftieth
    // change).
    clearWait { ^0.06 }

    // spawn/free the reverb synth on rev_mix. placed AFTER ioSynth (reads io's
    // fresh send this block; io reads the return via InFeedback next block).
    updateReverb { arg mix;
        var gen;
        revGen = revGen + 1;
        gen = revGen;
        (mix > 0).if({
            revSynth.isNil.if({
                revSynth = Synth.new(\four_reverb, [
                    \in_bus, revSendBus, \out_bus, revRetBus,
                ] ++ revParams.getPairs, ioSynth, \addAfter);
            });
        }, {
            revSynth.notNil.if({
                SystemClock.sched(this.spaceWait, {
                    // look again: only if nothing moved the mix since
                    ((gen == revGen) and: { revSynth.notNil }).if({
                        revSynth.free;
                        revSynth = nil;
                    });
                    nil
                });
            });
        });
    }

    // spawn/free the delay synth: alive while the mix is up, OR while the
    // feedback is a near-infinite hold with the mix down — the dub gesture
    // (INF, then KILL) parks a spinning loop at mix 0 and expects it back on
    // un-KILL; freeing at plain mix 0 would discard exactly that tail. a
    // low-feedback tail dies by itself in a few repeats, so only the high-fb
    // hold is kept alive. (delay_fb arrives CURVED from Lua: 0.9 here is
    // ~0.87 on the knob; the INF throw sends 0.98.) in the DEFAULT state
    // (mix 0, fb ~0.48) the synth is gone and the delay costs nothing.
    // It leaves like the reverb: spaceWait after the last call that did not
    // want it, and only if no call came since.
    updateDelay {
        var want = (delayParams[\delay_mix] > 0) or: { delayParams[\delay_fb] > 0.9 };
        var gen;
        dlyGen = dlyGen + 1;
        gen = dlyGen;
        want.if({
            delaySynth.isNil.if({
                delaySynth = Synth.new(\four_delay, [
                    \in_bus, dlySendBus, \out_bus, dlyRetBus,
                ] ++ delayParams.getPairs, ioSynth, \addAfter);
            });
        }, {
            delaySynth.notNil.if({
                SystemClock.sched(this.spaceWait, {
                    ((gen == dlyGen) and: { delaySynth.notNil }).if({
                        delaySynth.free;
                        delaySynth = nil;
                    });
                    nil
                });
            });
        });
    }

    // spawn/release the erosion head: alive only while erode > 0 in PLAY.
    // a RELEASE, not a free: the synth fades its write out over 50ms and
    // frees itself, so stopping never prints a step into the take.
    updateErode {
        var args;
        ((modeV == 4) and: { playParams[\erode] > 0 }).if({
            eroSynth.isNil.if({
                args = [\buf_l, bufL, \buf_r, bufR];
                eroKeys.do({ arg k; args = args ++ [k, playParams[k]] });
                eroSynth = Synth.new(\four_erode, args, playGroup, \addToHead);
            });
        }, {
            eroSynth.notNil.if({ eroSynth.set(\gate, 0); eroSynth = nil });
        });
    }

    // spawn/release the beat repeat. A new length (a roll to a shorter
    // division) RE-CAPTURES: the old synth fades out over 10ms while the new
    // one, placed before it, starts from the live output, so the old one's
    // crossfade lands on the new one's sound. len <= 0 releases it.
    updateRepeat { arg len;
        repSynth.notNil.if({ repSynth.set(\gate, 0); repSynth = nil });
        (len > 0).if({
            repIdx = (repIdx + 1) % 3;
            repSynth = Synth.new(\four_repeat, [
                \out, context.out_b.index, \buf, repBufs[repIdx], \len, len.min(2),
            ], ioSynth, \addAfter);
        });
    }

    // ---- voice allocation ---------------------------------------------------
    // shared spawn args: buffers, bus, envelope, and the CURRENT drone grain
    // params so a grain-cloud voice tracks the drone's character.
    voiceArgs { arg pos, pitch, oneShot, amp, len;
        ^[
            \buf_l, bufLs[opIdx], \buf_r, bufRs[opIdx], \play_bus, playBus,
            \note_pos, pos, \note_pitch, pitch,
            // how long the slice IS, as a fraction of the buffer. nil (an old
            // caller) -> 0 -> unbounded, the previous behaviour.
            \note_len, len ? 0,
            \gate, 1, \one_shot, oneShot,
            \amp, amp ? voiceParams[\amp],   // per-note level (nil -> the default)
            \pan, playParams[\pan],          // voices track the drone's pan too
            \atk, voiceParams[\voice_atk], \rel, voiceParams[\voice_rel],
            \grain_env1, grainEnv1, \grain_env2, grainEnv2,
            \size, playParams[\size], \density, playParams[\density],
            \spread, playParams[\spread],
            \grain_jitter, playParams[\grain_jitter],
            \grain_pitch_spread, playParams[\grain_pitch_spread],
            \grain_shape, playParams[\grain_shape]
        ];
    }

    noteOn { arg id, pos, pitch, type, amp, len;
        var def, syn;
        // enforce polyphony cap: release-steal oldest voices until under it.
        // a while (not one steal per press): `voices` can be LOWERED below the
        // held count mid-performance, and a single steal never converges.
        while({ voiceOrder.size >= maxVoices }, {
            var oldId = voiceOrder.removeAt(0);
            var old = activeVoices[oldId];
            old.notNil.if({ old.set(\gate, 0) });
            activeVoices.removeAt(oldId);
        });
        def = (type > 0.5).if({ \four_voice_slice }, { \four_voice_grain });
        syn = Synth.new(def, this.voiceArgs(pos, pitch, 0, amp, len), playGroup);
        activeVoices[id] = syn;
        voiceOrder = voiceOrder.add(id);
    }

    noteOff { arg id;
        var v = activeVoices[id];
        v.notNil.if({
            v.set(\gate, 0);          // release; env doneAction 2 frees it
            activeVoices.removeAt(id);
            voiceOrder.remove(id);
        });
    }

    noteOneShot { arg pos, pitch, type, amp, len;
        var def = (type > 0.5).if({ \four_voice_slice }, { \four_voice_grain });
        // fire-and-forget: internal gate self-terminates, synth self-frees
        Synth.new(def, this.voiceArgs(pos, pitch, 1, amp, len), playGroup);
    }

    alloc {
        var s = context.server;
        var allKeys;
        var winBounds, winRead, exactRd, drEnv, seam, colour, fxSlot, gl;
        var stretchOn, pvClass, warpClass, readClass, tanhClass, delayClass, grainClass, roomClass, bbdClass, th, dfmTrim;
        var grainCap, plugNow, plugLoaded, cloudDef, cloudName;
        // THE RECORD BUFFER LENGTH. The Lua side mirrors this as ctx.BUF_SECS
        // (it cannot read it off the server) and derives every window edge,
        // pad slice and waveform position from it — change it here and there
        // together, or positions drift with no error anywhere.
        var bufSecs = 60;

        bufGen = Array.fill(4, 0);
        dubVals = Dictionary[\rec_level -> 1.0, \pre_level -> 0.0, \freeze -> 0,
            \rec -> 0, \regen -> 0.0];
        leaving = Array.newClear(4);
        leaveGen = Array.fill(4, 0);
        modeGen = Array.fill(4, 0);
        glideAt = IdentityDictionary.new;
        glideKeys = IdentityDictionary.new;
        [\scan, \pitch, \pan, \density, \clouds_fb, \drive, \crush, \amt, \rate,
            \pre_gain, \snd1, \snd2, \snd3, \snd4, \cutoff, \resonance,
            \level, \fx_dly, \fx_rev, \dly_rev, \delay_mix, \rev_mix, \dry_wet,
            \delay_fb, \rev_decay, \rev_damp, \shimmer].do({ arg k;
            glideKeys[k] = (k ++ "_t").asSymbol;
        });
        bufLs = Array.fill(4, { Buffer.alloc(s, s.sampleRate * bufSecs, 1) });
        bufRs = Array.fill(4, { Buffer.alloc(s, s.sampleRate * bufSecs, 1) });
        bufL = bufLs[0];
        bufR = bufRs[0];

        // grain envelope buffers. shape 0 uses built-in Hann (envbufnum
        // -1) and never touches these. filled BEFORE the s.sync below so
        // they're ready when the first GRAIN synth spawns.
        grainEnv1 = Buffer.alloc(s, 2048, 1);
        grainEnv2 = Buffer.alloc(s, 2048, 1);
        grainEnv1.loadCollection(Env([0, 1, 0], [0.5, 0.5], \welch).asSignal(2048));
        grainEnv2.loadCollection(Env([0, 1, 0], [0.02, 0.98], [4, -4]).asSignal(2048));

        playBus = Bus.audio(s, 2);
        // reverb + delay send/return busses (each 2ch)
        revSendBus = Bus.audio(s, 2);
        revRetBus = Bus.audio(s, 2);
        dlySendBus = Bus.audio(s, 2);
        dlyRetBus = Bus.audio(s, 2);
        phaseBus = Bus.control(s, 1);
        syncBus = Bus.control(s, 4);
        meterBus = Bus.control(s, 4);
        tRetBus = Bus.audio(s, 2);
        tDlyBus = Bus.audio(s, 2);
        tRevBus = Bus.audio(s, 2);
        outBuses = Array.fill(4, { Bus.audio(s, 2) });
        recPhaseBus = Bus.control(s, 1);
        recAmpBus = Bus.control(s, 1);
        dubBus = Bus.audio(s, 2);
        // the beat repeat's three capture buffers: 2s of stereo each (a half
        // note down to 60 BPM), allocated once, never per repeat (2.3 MB)
        repBufs = Array.fill(3, { Buffer.alloc(s, (s.sampleRate * 2).asInteger, 2) });
        repIdx = 0;

        // voice state
        maxVoices = 8;
        activeVoices = Dictionary.new;
        voiceOrder = List.new;
        // headroom: per-voice amp 0.3 so a chord of poly voices summing
        // on play_bus doesn't slam the master limiter.
        voiceParams = Dictionary[\amp -> 0.3, \voice_atk -> 0.005, \voice_rel -> 0.6];

        // last-known drone values, handed to a freshly spawned mode synth
        playParams = Dictionary[
            // level/rec/freeze sit in ioKeys too, so ONE command fans out to
            // both synths (no new command, the fingerprint is unchanged). the
            // drone doesn't apply level to its output — io does — it only needs
            // to know whether the deck is audible, to freeze its read head.
            \level -> 1.0, \rec -> 0, \freeze -> 0,
            \pos_start -> 0.0, \pos_end -> 1.0, \scan -> 1.0, \pos_jitter -> 0.0,
            \size -> 0.1, \density -> 20, \pitch -> 1.0, \spread -> 0.5, \pan -> 0.0,
            \grain_jitter -> 0.0, \grain_pitch_spread -> 0.0, \grain_shape -> 0,
            \warp_window -> 0.25, \warp_overlaps -> 4, \warp_rand -> 0.0, \pv_freeze -> 0,
            // MiClouds granular controls (also passed to the fallback defs,
            // which simply ignore them)
            \clouds_pos -> 0.5, \clouds_tex -> 0.5, \clouds_fb -> 0.0,
            \clouds_mode -> 0, \clouds_lofi -> 0.0,
            // erosion: read by \four_erode (eroKeys below); every drone
            // def takes and ignores them
            \erode -> 0.0, \wear -> 0.5
        ];
        // the playParams the erosion head reads: its window, its two knobs,
        // and the three gates that pause it
        eroKeys = [\pos_start, \pos_end, \erode, \wear, \level, \rec, \freeze];
        // tracks 2 to 4: each owns every playParam but the three it shares
        // with the take (level, rec, freeze) and the erosion pair, and a
        // strip with these four (its commands: `t<n>_level` ...)
        stripKeys = [\level, \cutoff, \resonance, \filt_type,
            \drive, \crush, \fx_dly, \fx_rev,
            \effect, \effect_amt, \effect_rate,
            \effect2, \effect2_amt, \effect2_rate];
        extra = [2, 3, 4].collect({ arg n;
            var e = (n: n, bus: Bus.audio(s, 2), phase: Bus.control(s, 1),
                params: Dictionary.new,
                stripParams: Dictionary[\level -> 1.0, \cutoff -> 20000,
                    \resonance -> 0.0, \filt_type -> 0,
                    \drive -> 0.0, \crush -> 0.0, \fx_dly -> 0.0, \fx_rev -> 0.0,
                    \effect -> 0, \effect_amt -> 0.5, \effect_rate -> 0.5,
                    \effect2 -> 0, \effect2_amt -> 0.5, \effect2_rate -> 0.5]);
            playParams.keysValuesDo({ arg k, v;
                [\level, \rec, \freeze, \erode, \wear].includes(k).not.if({
                    e[\params][k] = v;
                });
            });
            e
        });
        // reverb params live in revParams (routed to \four_reverb) and the
        // delay's in delayParams (routed to \four_delay); io keeps the two
        // MIX knobs it needs for its own crossfade/add. (ioKeys U revParams U
        // delayParams) is the original ioKeys -> the command set is unchanged.
        ioKeys = [\level, \rec, \rec_level, \pre_level, \freeze,
            \dry_wet, \resample, \regen, \grain_level,
            \filt_type, \cutoff, \resonance, \drive, \crush,
            \effect, \effect_amt, \effect_rate,
            \effect2, \effect2_amt, \effect2_rate,
            \delay_mix, \fx_dly, \dly_rev,
            \rev_mix, \fx_rev];
        revParams = Dictionary[
            \rev_size -> 1.0, \rev_decay -> 2.0, \rev_damp -> 0.3, \rev_early -> 0.7,
            \rev_moddepth -> 0.1, \rev_modfreq -> 2.0,
            \rev_low -> 1.0, \rev_mid -> 1.0, \rev_high -> 1.0,
            \rev_lowcut -> 500, \rev_highcut -> 2000,
            \shimmer -> 0.0, \shimmer_pitch -> 12.0, \shimmer_tone -> 4500.0
        ];
        revMixV = 0;
        // delay_mix sits in BOTH ioKeys (io's crossfade) and here (the
        // spawn/free gate + a handover value for a fresh synth's unused arg)
        delayParams = Dictionary[
            \delay_time -> 0.3, \delay_fb -> 0.3, \delay_mix -> 0.0
        ];

        // ---- drone playback defs: ONE runs at a time. all share the full
        // arg set (unused args ignored) so spawn/set stays uniform.
        // winRead = the window-position law, defined ONCE for all five defs
        // (a plain build-time function — each call emits the same UGens
        // inline, so the compiled graphs are unchanged; before this the same
        // 7 lines were copy-pasted five times and had already drifted once).
        // window edges + scan are smoothed: pos_start/pos_end are
        // PERFORMANCE encoders (TAKE E2/E3) and an unsmoothed edge move
        // jumped the read head with a click per detent. pitchMul folds
        // varispeed into the phase rate (only \four_play passes it).
        // `run` is the deck LEVEL (every def passes it): a SILENCED engine
        // deck freezes its read head, so STOP truly halts — the on-screen
        // head stops sweeping and START resumes from the exact spot. this is
        // the same "silent deck = stopped deck" law the erosion and regen
        // write heads already follow, and like them it also engages when the
        // MIX is thrown fully to tape (level lands at exact 0 there too) —
        // a fully-thrown-away deck pauses rather than spinning unheard.
        // gl = A KNOB'S GLIDE (C6 of doc/signature-workflow.md, the
        // fifty-third change): a straight line from where the value is to
        // where it goes, over the time `t`. The time is a control of its own,
        // `<name>_t`, and every write of the value sends it too (gset): 20ms
        // for a hand, and a little more than a frame for a value that comes
        // once a frame (glideLaw). Before, each knob had a Lag of 20 to 50ms:
        // a modulator, a motion lane and the fade write once a frame (67ms),
        // so the value moved for a third of each frame and stood still for
        // the rest. Measured (test/dsp/review/probe4.scd, job s): still 61 to
        // 74% of the time, in stands of 47 to 60ms.
        // VarLag with warp 1 is one UGen, as Lag was, so no def grows. It
        // reads its time when its value changes. A change of the time alone
        // does nothing to a value at rest (tried on both scsynths).
        gl = { arg x, t; VarLag.kr(x, t, warp: 1) };
        // winBounds = the window's sorted, smoothed edges as [lo, span],
        // shared by winRead and the erosion head.
        winBounds = { arg pos_start, pos_end;
            var lo, hi, span;
            // AUDIO rate, two-pole: a control-rate lag moved the read head in one
            // step per block, and each step broke the waveform. The device
            // measured a click on every E2 detent over a sustained tone. Lag2
            // starts at zero speed, so an edge move bends the sound briefly
            // instead of kinking it.
            lo = Lag2.ar(K2A.ar(pos_start.min(pos_end)), 0.08);
            hi = Lag2.ar(K2A.ar(pos_start.max(pos_end)), 0.08);
            span = (hi - lo).max(0.001);
            [lo, span];
        };
        // `run` goes through the SAME glide io puts on `level` (gl, with the
        // level's own time, `run_t`): the head stops only once io's fade is
        // down. On the raw level it stopped first, and the fade then played
        // one held sample (a thump).
        // `quiet` 1 (a drone fading out under the next one) stops writing
        // the phase bus, so the screen follows the new drone alone.
        // drEnv is the drone's own 10ms in, 20ms out, which frees it. A drone
        // that leaves under a new one stays whole for `hold`, then goes over
        // `rel` on the curve `crv` (-4 is the curve of Env.asr: fast at
        // first). swapDrone sets the three with the release, so the wait
        // runs on the server, in step with the new drone to the sample.
        // `att` and `acrv` are the time and the curve in: a PLAY drone that
        // takes over comes in as the old one goes (swapDrone).
        // WHERE THE HEAD STARTS (C2 of doc/signature-workflow.md, the
        // fifty-first change). A drone that takes over from another starts
        // where that one is, to the sample: it reads the phase bus itself, at
        // its first block. The bus holds the place the old drone wrote one
        // block ago (0 to 1 of the buffer). `hfrom` is the buffer's frames,
        // `hlead` what to add in frames (one block of travel, the two
        // drones' delays, less the window's start), `hspan` the window's
        // frames. With hfrom 0, hlead 0 and hspan 1 the head starts at 0, as
        // a drone from OFF does. The place is rounded to a whole frame: the
        // read below needs (whole - frac) to be a whole number, and a head
        // that starts half a frame off flips between two frames at random.
        // sclang cannot do this sum: a place it reads is already old when
        // the server makes the synth, by another time at each change, and
        // two copies of a sound that are out of step cancel while they cross.
        // The first build sent the place as a number: offline it read fine,
        // and on the device a change from PLAY into PV dipped by 18dB over a
        // tone.
        // A Phasor takes its first place from its `start` when it is built,
        // and reads `start` again only to wrap. Trig.kr gives the place for
        // the first block and 0 after it, so the head begins there and then
        // loops from 0. Tried on both scsynths (the norns's 3.13 and the
        // Mac's 3.14): a trigger-rate control and `Impulse.kr(0) * x` start
        // the head at the wrong place on the norns, and a control set back to
        // 0 in the bundle of the spawn starts it at 0, because a synth's
        // UGens are built at its first block, after the whole bundle.
        winRead = { arg pos_start, pos_end, scan, buf, phase_out, pitchMul = 1, run = 1, quiet = 0,
                hfrom = 0, hlead = 0, hspan = 1, scan_t = 0.02, run_t = 0.02, sync = 0;
            var lo, span, frames, loF, spanF, rate, whole, frac, phase, winPos;
            #lo, span = winBounds.(pos_start, pos_end);
            // THE HEAD COUNTS IN FRAMES, in two parts. It was one float from
            // 0 to 1 across the 60s buffer: a float has 24 bits and the
            // buffer has 2.88 million frames, so the head landed up to a
            // quarter frame off on every sample. Measured (test/dsp): a 5kHz
            // tone 54s into the buffer read with noise at -38dB at pitch 1
            // and -25dB a semitone up. `whole` runs over the window in
            // frames, `frac` over one frame; both add the same rate into a
            // 64-bit state, so (whole - frac) is a whole number that a float
            // holds exactly, and frac keeps the place between two frames to
            // 24 bits anywhere in the buffer. At a rate of 1 frac stays 0.
            frames = BufFrames.kr(buf);
            loF = (lo * frames).round;
            spanF = (span * frames).round.max(64);
            rate = gl.(scan, scan_t) * pitchMul * (gl.(run, run_t) > 0.001)
                * BufRateScale.kr(buf);
            // HEAD SYNC (the sixty-seventh change): `sync` going above 0
            // sends the head to the window's start. It is mapped to a control
            // bus that \four_sync pulses (the seventy-first change). A plain
            // control (never t_, see CLAUDE.md), straight into the Phasors:
            // no UGen more. The bus is 0 at rest, so a drone does not jump
            // at its start. The head lands 384 frames (8 ms) into the window:
            // the time \four_sync takes to fade out and jump, so the loop is
            // in time and not 8 ms late.
            whole = Phasor.ar(sync, rate,
                Trig.kr(((In.kr(phase_out) * hfrom) + hlead).round % hspan, 0), spanF, 384);
            frac = Phasor.ar(sync, rate, 0, 1);
            phase = (whole / spanF).clip(0, 1);
            winPos = lo + (phase * span);
            Out.kr(phase_out, A2K.kr(winPos) * (1 - quiet));
            [winPos, phase, span, loF + (whole - frac).round, frac, loF, spanF];
        };
        // the read for winRead's two-part head: four plain reads at whole
        // frames and the cubic between them (BufRd's own, the same curve).
        // With frac 0 it returns the stored sample, bit for bit.
        exactRd = { arg buf, idx, frac;
            var ym1, y0, y1, y2, c1, c2, c3;
            ym1 = BufRd.ar(1, buf, idx - 1, 1, 1);
            y0 = BufRd.ar(1, buf, idx, 1, 1);
            y1 = BufRd.ar(1, buf, idx + 1, 1, 1);
            y2 = BufRd.ar(1, buf, idx + 2, 1, 1);
            c1 = 0.5 * (y1 - ym1);
            c2 = ym1 - (2.5 * y0) + (2 * y1) - (0.5 * y2);
            c3 = (0.5 * (y2 - ym1)) + (1.5 * (y0 - y1));
            (((((c3 * frac) + c2) * frac) + c1) * frac) + y0
        };
        drEnv = { arg gate, hold = 0, rel = 0.02, crv = -4, att = 0.01, acrv = -4;
            EnvGen.kr(Env([0, 1, 1, 0], [att, hold, rel], [acrv, 0, crv], 1), gate, doneAction: 2)
        };
        // the loop seam fade PLAY has always had (~5ms, buffer-time referenced)
        seam = { arg phase, span, buf;
            (phase.min(1 - phase) * span * BufDur.kr(buf) / 0.005).clip(0, 1)
        };

        // GRAIN: the granulator. It reads the track's window itself, the way
        // the S-4's granular device reads its sample. One stream of STEREO
        // grains: each trigger starts a grain in the left buffer and one in
        // the right at the same time, place, length and pitch, so the take
        // keeps its stereo image. (Two independent mono clouds smeared the
        // image, and at spread 0 folded it to mono.)
        //   spread: 0 = left grains left and right grains right (the take as
        //     recorded); 1 = each pair thrown to one random place.
        //   pos_jitter (SPRAY): each grain lands up to that much of the
        //     window away from the head. Every grain is also scattered by at
        //     least a quarter of its own length: grains that all start on
        //     the same sample comb-filter into a buzz at the density.
        //   a grain is CENTRED on its place (it reads half before, half
        //     after), and its START stays inside the window. A grain no
        //     longer than the window stays inside it. A longer one (size 0.5s
        //     in a 12ms window) reads on past the window's end: measured, the
        //     sound from outside came out 8.6 dB louder than the window's own
        //     (doc/measurements/2026-11-15).
        //   pv_freeze holds the head where it is while grains keep coming.
        // FourStretch (ugen/): our own UGens for the two stretch voices. WARP
        // is WSOLA and PV is a phase vocoder with locked phases; both return
        // the take sample for sample at speed 1 (ugen/test_core.cpp proves
        // it). The class is lib/FourStretch.sc, so it is always there; what
        // can be missing is the BINARY on the server, and a def that names a
        // UGen the server lacks does not load. So look for the file. Absent:
        // the stock voices below (Warp1, and the FFT that only freezes).
        pvClass = "FourPV".asSymbol.asClass;
        warpClass = "FourWarp".asSymbol.asClass;
        readClass = "FourRead".asSymbol.asClass;
        tanhClass = "FourTanh".asSymbol.asClass;
        delayClass = "FourDelay".asSymbol.asClass;
        grainClass = "FourGrain".asSymbol.asClass;
        roomClass = "FourRoom".asSymbol.asClass;
        bbdClass = "FourBBD".asSymbol.asClass;
        // The binary must also be the one the server loaded at its boot
        // (bootPlug): one installed or replaced since then waits for a
        // RESTART. FOUR_STRETCH (the Mac bench, test/dsp) says the server has it.
        plugNow = this.class.plugStamp;
        plugLoaded = "FOUR_STRETCH".getenv.notNil
            or: { plugNow.notNil and: { plugNow == bootPlug } };
        stretchOn = pvClass.notNil and: { warpClass.notNil } and: { readClass.notNil }
            and: { tanhClass.notNil } and: { delayClass.notNil }
            and: { grainClass.notNil } and: { roomClass.notNil } and: { bbdClass.notNil }
            and: { plugLoaded };
        (plugNow.notNil and: { plugLoaded.not }).if({
            "four: FourStretch is new since the restart, SYSTEM > RESTART to use it".postln;
        });
        ("four: FourStretch " ++ stretchOn.if({ "on" },
            { "absent, WARP and PV are the stock voices" })).postln;
        // tanh, for every def below. The C library's tanh costs 0.4% of the
        // audio thread for each channel on the norns, and the engine has 28
        // of them. FourTanh is the same curve to 2e-7 at a tenth of the cost.
        th = { arg x; stretchOn.if({ tanhClass.ar(x) }, { x.tanh }) };
        hasStretch = stretchOn;
        // how many grain pairs a cloud holds, and where its level law stops.
        // A stock pair (two GrainBuf) costs 0.27% of the audio thread on
        // the norns, and four clouds of 64 ran the engine to 100%. FourGrain
        // is the same law at 0.17% a pair, and it drops a grain beyond the
        // cap without a word (GrainBuf posts "Too many grains!" each time).
        // Four full clouds must fit the budget: 48 pairs with the plugin,
        // 32 without it.
        grainCap = stretchOn.if({ 48 }, { 32 });
        // DFM1's makeup. At inputgain 0.5 the filter itself passes a tone
        // 1.0dB LOUDER than it came in (measured on the device, low-pass and
        // high-pass, any cutoff). The makeup was x2, so every track left its
        // filter 7dB hot, and three or four tracks sat in the master limiter
        // all the time (crest factor 7dB, down from 11.6). 0.891 is -1.0dB:
        // a track now leaves the filter at the level of its take.
        dfmTrim = 0.891;

        SynthDef(\four_grain, {
            arg buf_l, buf_r, play_bus, phase_out, rec = 0, freeze = 0,
                pos_start = 0, pos_end = 1, scan = 1, pos_jitter = 0,
                size = 0.1, density = 20, pitch = 1, spread = 0.5, pan = 0,
                grain_jitter = 0, grain_pitch_spread = 0, grain_shape = 0,
                grain_env1 = -1, grain_env2 = -1,
                clouds_pos = 0.5, clouds_tex = 0.5, clouds_fb = 0, clouds_mode = 0,
                clouds_lofi = 0,
                warp_window = 0.25, warp_overlaps = 4, warp_rand = 0, pv_freeze = 0,
                erode = 0, wear = 0.5, level = 1, gate = 1, handover = 0,
                hfrom = 0, hlead = 0, hspan = 1, sync = 0, hold = 0, rel = 0.02, crv = -4, att = 0.01, acrv = -4,
                scan_t = 0.02, pitch_t = 0.02, pan_t = 0.02, density_t = 0.02, clouds_fb_t = 0.02,
                level_t = 0.02;
            var winPos, phase, span, lo, look, bufDur, trig, dur, pch, readLen;
            var off, pos, r, wid, panL, panR, envSel, comp, sig;
            #winPos, phase, span = winRead.(pos_start, pos_end, scan * (1 - pv_freeze),
                buf_l, phase_out, 1, level, handover, hfrom, hlead, hspan, scan_t, level_t, sync);
            lo = winPos - (phase * span);
            bufDur = BufDur.kr(buf_l);
            // while recording, read a quarter second behind the record head
            look = (0.25 / bufDur) * rec * (1 - freeze);
            // the TIMING, AUDIO rate (kr onsets fall on the control block):
            // grain_jitter 0 is a regular stream, and Hann grains at an
            // overlap of 2 or more then add up to a steady level. 1 is
            // Poisson (Dust), the old law: measured on the device at the
            // default size and density, 18% of the sound fell below -50 dB
            // between clumps. In between, the regular stream is thinned and
            // Dust makes up the rest, so the mean rate stays the density.
            // The same knob varies the length. Every per-grain random is ar
            // on the same trigger.
            // `Impulse.ar(0)` is the first grain, at the first sample. CoinGate
            // takes its input's first value as the trigger it last saw, so it
            // never passed Impulse's first impulse: the first grain came one
            // period late. Measured: silence for 31ms after a mode change into
            // GRAIN at density 20, and 250ms at density 4.
            trig = CoinGate.ar(1 - grain_jitter.clip(0, 1), Impulse.ar(density))
                + Dust.ar(density * grain_jitter.clip(0, 1)) + Impulse.ar(0);
            dur = (size * (1 + TRand.ar(grain_jitter.neg, grain_jitter, trig))).max(0.005);
            // midiratio is already 2^(st/12): no /12 before it
            pch = pitch * TRand.ar(grain_pitch_spread.neg, grain_pitch_spread, trig).midiratio;
            readLen = (dur * pch / bufDur).min(span);
            off = TRand.ar(-1, 1, trig) * ((pos_jitter * span) + (size * 0.25 / bufDur));
            pos = winPos - look + off - (readLen * 0.5);
            pos = lo + (pos - lo).wrap(0, span).clip(0, (span - readLen).max(0));
            r = TRand.ar(spread.neg, spread, trig);
            wid = 1 - spread;
            panL = (pan - wid + r).clip(-1, 1);
            panR = (pan + wid + r).clip(-1, 1);
            envSel = Select.kr(grain_shape.clip(0, 2), [-1, grain_env1, grain_env2]);
            // equal loudness across density x size (boost below unity
            // overlap, up to 2x; attenuate above it as 1/sqrt(overlap), to
            // -17dB at an overlap of 48 (grainCap): capped at 16, a dense cloud measured
            // 4 dB above PLAY on the device),
            // and over spread: a pair thrown to one place sums its two
            // channels, so the top of spread is 3dB down. x0.8: grain
            // pairs overlap coherently, so they peak harder than PLAY; on the
            // device the default cloud came out 1.3 dB above PLAY with the
            // limiter at work in 2% of it, and 9% when dense
            comp = (density * size).clip(0.25, grainCap).sqrt.reciprocal
                * (1 + spread.squared).sqrt.reciprocal * 0.8;
            // FourGrain is the pair of GrainBuf as one UGen, measured against
            // them: the same samples to -139dB once the start place is
            // rounded the way GrainBuf rounds it (ours keeps it exact).
            sig = stretchOn.if({
                grainClass.ar(buf_l, buf_r, trig, dur, pch, pos, panL, panR, envSel, 48)
            }, {
                GrainBuf.ar(2, trig, dur, buf_l, pch, pos, 4, panL, envSel, 32)
                    + GrainBuf.ar(2, trig, dur, buf_r, pch, pos, 4, panR, envSel, 32)
            }) * comp;
            Out.ar(play_bus, sig * drEnv.(gate, hold, rel, crv, att, acrv));
        }).add;

        SynthDef(\four_warp, {
            arg buf_l, buf_r, play_bus, phase_out, rec = 0, freeze = 0,
                pos_start = 0, pos_end = 1, scan = 1, pos_jitter = 0,
                size = 0.1, density = 20, pitch = 1, spread = 0.5, pan = 0,
                grain_jitter = 0, grain_pitch_spread = 0, grain_shape = 0,
                grain_env1 = -1, grain_env2 = -1,
                clouds_pos = 0.5, clouds_tex = 0.5, clouds_fb = 0, clouds_mode = 0,
                clouds_lofi = 0,
                warp_window = 0.25, warp_overlaps = 4, warp_rand = 0, pv_freeze = 0,
                erode = 0, wear = 0.5, level = 1, gate = 1, handover = 0,
                hfrom = 0, hlead = 0, hspan = 1, sync = 0, hold = 0, rel = 0.02, crv = -4, att = 0.01, acrv = -4,
                scan_t = 0.02, pitch_t = 0.02, pan_t = 0.02, density_t = 0.02, clouds_fb_t = 0.02,
                level_t = 0.02;
            var winPos, phase, span, idx, frac, loF, spanF, ptr, l, r, sig;
            #winPos, phase, span, idx, frac, loF, spanF = winRead.(pos_start, pos_end, scan, buf_l, phase_out, 1, level, handover, hfrom, hlead, hspan, scan_t, level_t, sync);
            stretchOn.if({
                // bufL, bufR, the head in frames, pitch, window in frames,
                // overlaps, rand, the loop (positional: see the MiClouds call)
                sig = warpClass.ar(buf_l, buf_r, idx, pitch,
                    warp_window * SampleRate.ir, warp_overlaps, warp_rand, loF, spanF);
                l = sig[0];
                r = sig[1];
            }, {
                ptr = A2K.kr(winPos);
                l = Warp1.ar(1, buf_l, ptr, pitch, warp_window, -1, warp_overlaps, warp_rand, 4);
                r = Warp1.ar(1, buf_r, ptr, pitch, warp_window, -1, warp_overlaps, warp_rand, 4);
            });
            sig = Balance2.ar(l, r, gl.(pan, pan_t));
            Out.ar(play_bus, sig * drEnv.(gate, hold, rel, crv, att, acrv));
        }).add;

        SynthDef(\four_pv, {
            arg buf_l, buf_r, play_bus, phase_out, rec = 0, freeze = 0,
                pos_start = 0, pos_end = 1, scan = 1, pos_jitter = 0,
                size = 0.1, density = 20, pitch = 1, spread = 0.5, pan = 0,
                grain_jitter = 0, grain_pitch_spread = 0, grain_shape = 0,
                grain_env1 = -1, grain_env2 = -1,
                clouds_pos = 0.5, clouds_tex = 0.5, clouds_fb = 0, clouds_mode = 0,
                clouds_lofi = 0,
                warp_window = 0.25, warp_overlaps = 4, warp_rand = 0, pv_freeze = 0,
                erode = 0, wear = 0.5, level = 1, gate = 1, handover = 0,
                hfrom = 0, hlead = 0, hspan = 1, sync = 0, hold = 0, rel = 0.02, crv = -4, att = 0.01, acrv = -4,
                scan_t = 0.02, pitch_t = 0.02, pan_t = 0.02, density_t = 0.02, clouds_fb_t = 0.02,
                level_t = 0.02;
            var winPos, phase, span, idx, frac, loF, spanF, sigL, sigR, chainL, chainR, l, r, sig, edge;
            // with FourStretch, FRZ holds the head (GRAIN's law) and the
            // vocoder sustains what is under it; pitch is its own knob
            #winPos, phase, span, idx, frac, loF, spanF = winRead.(pos_start, pos_end,
                stretchOn.if({ scan * (1 - pv_freeze) }, { scan }),
                buf_l, phase_out, 1, level, handover, hfrom, hlead, hspan, scan_t, level_t, sync);
            // cubic interp like every other read path — PV magnifies linear-
            // interp images: MagFreeze sustains whatever aliasing lands in the FFT
            // the seam fade before the FFT: a wrap click fed to MagFreeze
            // is held as a steady hiss
            stretchOn.if({
                // no seam fade: the frames wrap inside the loop, and the
                // plugin smooths the splice (Buf in ugen/four_core.h)
                sig = pvClass.ar(buf_l, buf_r, idx, gl.(pitch, pitch_t), loF, spanF);
                l = sig[0];
                r = sig[1];
            }, {
                edge = seam.(phase, span, buf_l);
                sigL = exactRd.(buf_l, idx, frac) * edge;
                sigR = exactRd.(buf_r, idx, frac) * edge;
                chainL = FFT(LocalBuf(2048), sigL);
                chainR = FFT(LocalBuf(2048), sigR);
                chainL = PV_MagFreeze(chainL, pv_freeze);
                chainR = PV_MagFreeze(chainR, pv_freeze);
                l = IFFT(chainL);
                r = IFFT(chainR);
            });
            sig = Balance2.ar(l, r, gl.(pan, pan_t));
            Out.ar(play_bus, sig * drEnv.(gate, hold, rel, crv, att, acrv));
        }).add;

        // ---- CLEAN PLAY drone — a straight loop of the window, the EXACT
        // recorded sample (no granulation/stretch/spectral). this is the
        // default mode so a fresh take plays back untouched; GRAIN/WARP/PV are
        // switched on when you want them. scan sets loop speed, pitch resamples
        // it (varispeed, like a sampler/tape). all core UGens — can't brick.
        SynthDef(\four_play, {
            arg buf_l, buf_r, play_bus, phase_out, rec = 0, freeze = 0,
                pos_start = 0, pos_end = 1, scan = 1, pos_jitter = 0,
                size = 0.1, density = 20, pitch = 1, spread = 0.5, pan = 0,
                grain_jitter = 0, grain_pitch_spread = 0, grain_shape = 0,
                grain_env1 = -1, grain_env2 = -1,
                clouds_pos = 0.5, clouds_tex = 0.5, clouds_fb = 0, clouds_mode = 0,
                clouds_lofi = 0,
                warp_window = 0.25, warp_overlaps = 4, warp_rand = 0, pv_freeze = 0,
                erode = 0, wear = 0.5, level = 1, gate = 1, handover = 0,
                hfrom = 0, hlead = 0, hspan = 1, sync = 0, hold = 0, rel = 0.02, crv = -4, att = 0.01, acrv = -4,
                scan_t = 0.02, pitch_t = 0.02, pan_t = 0.02, density_t = 0.02, clouds_fb_t = 0.02,
                level_t = 0.02;
            var winPos, phase, span, idx, frac, sigL, sigR, edge, sig;
            #winPos, phase, span, idx, frac = winRead.(pos_start, pos_end, scan, buf_l, phase_out, gl.(pitch, pitch_t), level, handover, hfrom, hlead, hspan, scan_t, level_t, sync);
            stretchOn.if({
                // a windowed sinc in place of the cubic: nothing folds above
                // pitch 1 and the images sit below -70dB. On a whole frame
                // (pitch 1) it is the stored sample, like exactRd.
                sig = readClass.ar(buf_l, buf_r, idx, frac,
                    (gl.(scan, scan_t) * gl.(pitch, pitch_t)).abs);
                sigL = sig[0];
                sigR = sig[1];
            }, {
                sigL = exactRd.(buf_l, idx, frac);
                sigR = exactRd.(buf_r, idx, frac);
            });
            // ~5ms edge fade at the loop seam (buffer-time referenced, shrinks
            // with rate): the rec-stop window almost never lands on a zero
            // crossing, so the bare loop CLICKED every pass — the one blemish
            // on "the exact recorded sample". the body of the take is untouched.
            edge = seam.(phase, span, buf_l);
            sig = Balance2.ar(sigL, sigR, gl.(pan, pan_t)) * edge;
            Out.ar(play_bus, sig * drEnv.(gate, hold, rel, crv, att, acrv));
        }).add;

        // ---- EROSION: the window rewriting itself, in its own synth
        // (updateErode spawns it while erode > 0 in PLAY mode). it runs on
        // its OWN head at a constant one pass per window length regardless
        // of playback speed or direction: aging is uniform and predictable,
        // no samples are skipped at high rates, and varispeed does not change
        // the wear character. a NON-interpolating read fetches the exact
        // stored sample and a slightly darkened, slightly quieter copy is
        // written back in its place. manual rec and freeze pause the head,
        // and so does a silenced engine deck (STOP / mix thrown fully to tape
        // -> level ~0): a stopped instrument left with erode up would
        // otherwise grind the take away with nobody listening, the same trap
        // the regen head guards against. the head HOLDS its place while
        // paused, so every part of the window ages at the same rate (and the
        // Lua pass counter, which pauses on the same three, stays true). the
        // Lua layer interlocks erode against regen so two free-running write
        // heads never fight over the buffer. `gate` fades the write in and
        // out over 50ms and frees the synth: a write that began or ended at
        // full strength would print a step into the take.
        SynthDef(\four_erode, {
            arg buf_l, buf_r, gate = 1, pos_start = 0, pos_end = 1,
                erode = 0, wear = 0.5, level = 1, rec = 0, freeze = 0;
            var lo, span, run, head, idx, env, eff, wearF, rawL, rawR, frames;
            #lo, span = winBounds.(pos_start, pos_end);
            run = (1 - rec) * (1 - freeze) * (level > 0.001);
            // THE HEAD COUNTS IN WHOLE FRAMES, one a sample (winRead's law).
            // It was a float from 0 to 1 times the frames: past the middle of
            // the 60s buffer a float lands up to 0.17 frame off, so the head
            // read and wrote some frames twice and skipped others, and the
            // low-pass saw a jittered signal. Measured on a 5kHz take, erode 1
            // for 12s: noise 18dB under the tone at 30s in, 22dB under it at
            // 54s in. Counted in frames: -141dB at every place.
            frames = BufFrames.kr(buf_l);
            head = Phasor.ar(0, run, 0, (span * frames).round.max(64));
            idx = (lo * frames).round + head;
            env = EnvGen.kr(Env.asr(0.05, 1, 0.05), gate, doneAction: 2);
            eff = erode.clip(0, 1).lag(0.05) * env * run;
            wearF = wear.clip(0, 1).linexp(0, 1, 9000, 1200);
            rawL = BufRd.ar(1, buf_l, idx, 1, 1);
            rawR = BufRd.ar(1, buf_r, idx, 1, 1);
            BufWr.ar((rawL * (1 - eff)) + (LPF.ar(rawL, wearF) * 0.996 * eff),
                buf_l, idx);
            BufWr.ar((rawR * (1 - eff)) + (LPF.ar(rawR, wearF) * 0.996 * eff),
                buf_r, idx);
        }).add;

        // THE CLOUD: Mutable Instruments Clouds on the playing window, from
        // the first of these that is there: FourCloud (four's own plugin,
        // ugen/vendor/), MiClouds (mi-UGens), else CLOUD plays the GRAIN
        // granulator. FourCloud takes the inputs of MiClouds in the same
        // order, so one def serves both. Each is guarded two ways: .asClass
        // (no literal reference) and a try around the def. FourCloud also
        // needs a binary that holds it: one built before it does not, and a
        // def that names it would load nowhere. a BufRd scrubs the window
        // into Clouds; pv_freeze doubles as the clouds freeze.
        cloudDef = { arg cc;
            SynthDef(\four_clouds, {
                arg buf_l, buf_r, play_bus, phase_out, rec = 0, freeze = 0,
                    pos_start = 0, pos_end = 1, scan = 1, pos_jitter = 0,
                    size = 0.1, density = 20, pitch = 1, spread = 0.5, pan = 0,
                    grain_jitter = 0, grain_pitch_spread = 0, grain_shape = 0,
                    grain_env1 = -1, grain_env2 = -1,
                    clouds_pos = 0.5, clouds_tex = 0.5, clouds_fb = 0,
                    clouds_mode = 0, clouds_lofi = 0,
                    warp_window = 0.25, warp_overlaps = 4, warp_rand = 0,
                    pv_freeze = 0, erode = 0, wear = 0.5, level = 1, gate = 1, handover = 0,
                hfrom = 0, hlead = 0, hspan = 1, sync = 0, hold = 0, rel = 0.02, crv = -4, att = 0.01, acrv = -4,
                scan_t = 0.02, pitch_t = 0.02, pan_t = 0.02, density_t = 0.02, clouds_fb_t = 0.02,
                level_t = 0.02;
                var winPos, phase, span, idx, frac, srcL, srcR, sig, dens, edge;
                #winPos, phase, span, idx, frac = winRead.(pos_start, pos_end, scan, buf_l, phase_out, 1, level, handover, hfrom, hlead, hspan, scan_t, level_t, sync);
                // Clouds' density is silent at 0.5: below it grains are
                // random, above it periodic. Mapping 1..200 across 0.5 made
                // density 13 to 16 silent and the default 20 about 20 dB
                // down. Stay on the random side (the drone's Dust law), and
                // lift the sparse end by the level the device measured.
                // (the density glides: the level law below spans 14dB, and
                // a step of it was a step of the level)
                dens = gl.(density, density_t).explin(1, 200, 0.36, 0.05);
                edge = seam.(phase, span, buf_l);
                srcL = exactRd.(buf_l, idx, frac) * edge;
                srcR = exactRd.(buf_r, idx, frac) * edge;
                // POSITIONAL args (keyword args don't survive perform on a
                // var-held class): in, pit, pos, size, dens, tex, drywet,
                // in_gain, spread, rvb, fb, freeze, mode, lofi. our size/
                // density/pitch remap to Clouds' 0..1 / semitone ranges.
                sig = cc.ar([srcL, srcR],
                    // Clouds reads its pitch when a grain starts, so a noise
                    // here is a pitch spread per grain, as in the GrainBuf drone
                    (pitch.max(0.01).log2 * 12) + LFNoise0.kr(density.clip(4, 30), grain_pitch_spread),
                    clouds_pos,
                    size.linlin(0.01, 0.5, 0.1, 0.9),
                    dens,
                    clouds_tex, 1.0, 1.0, spread, 0.0, gl.(clouds_fb, clouds_fb_t),
                    pv_freeze, clouds_mode, clouds_lofi);
                // x0.5: measured on the device, Clouds at the default
                // density came out 6 dB above PLAY on the same take, so
                // a mode change jumped in level
                sig = sig * (((dens - 0.05) / 0.31).squared * 14).dbamp * 0.5;
                Out.ar(play_bus, sig * drEnv.(gate, hold, rel, crv, att, acrv));
            }).add;
        };
        [["FourCloud", stretchOn and: { this.class.plugHas("FourCloud") }],
         ["MiClouds", true]].do({ arg c;
            var cc = c[0].asSymbol.asClass;
            (cloudName.isNil and: { c[1] } and: { cc.notNil }).if({
                try {
                    cloudDef.(cc);
                    cloudName = c[0];
                } { arg err;
                    ("four: the " ++ c[0] ++ " def failed. " ++ err.errorString).postln;
                };
            });
        });
        hasClouds = cloudName.notNil;
        ("four: CLOUD is " ++ (cloudName ? "the GRAIN granulator, no Clouds")).postln;

        // ---- polyphonic voices: ONE note each, spawned per press. both
        // defs share the arg set; each frees itself. THE PER-PAD SWITCH is
        // which def the allocator spawns (grain cloud vs clean slice).

        // helper: effective gate. held -> external `gate`; one-shot -> an
        // internal gate held high for `sustain` then released, so the asr
        // env's doneAction:2 frees the synth. env-driven free means sparse
        // grain gaps never premature-free a held voice.
        SynthDef(\four_voice_grain, {
            arg buf_l, buf_r, play_bus,
                gate = 1, one_shot = 0, sustain = 0.05,
                note_pos = 0, note_pitch = 1, amp = 0.5, pan = 0,
                atk = 0.005, rel = 0.6,
                size = 0.1, density = 20, spread = 0.5,
                grain_jitter = 0, grain_pitch_spread = 0, grain_shape = 0,
                grain_env1 = -1, grain_env2 = -1, note_len = 0;
            var trig, dur, pch, off, pos, r, wid, envSel, cloud, eGate, env, sig;
            var comp, bufDur, reach;
            // the drone's laws, one stream of stereo grain pairs: sample
            // accurate onsets (regular to Poisson on grain_jitter), per-grain
            // randoms on the same trigger. Impulse.ar(0) is the first grain, at
            // the press: CoinGate never passes its input's first impulse (see
            // \four_grain), and a pad sounded 51ms after the press at density
            // 20 and 251ms after it at density 4.
            trig = CoinGate.ar(1 - grain_jitter.clip(0, 1), Impulse.ar(density))
                + Dust.ar(density * grain_jitter.clip(0, 1)) + Impulse.ar(0);
            bufDur = BufDur.kr(buf_l);
            dur = (size * (1 + TRand.ar(grain_jitter.neg, grain_jitter, trig))).max(0.005);
            pch = note_pitch * TRand.ar(grain_pitch_spread.neg, grain_pitch_spread, trig).midiratio;
            // SCATTER: grains that all start on the pad's sample comb-filter
            // into a static buzz. Each starts up to half a grain after it,
            // and inside the slice (note_len, a buffer fraction; 0 = no limit)
            reach = (size * 0.5 / bufDur).min(Select.kr(note_len > 0, [1.0, note_len * 0.5]));
            off = TRand.ar(0, 1, trig) * reach;
            pos = (note_pos + off).wrap(0, 1);
            r = TRand.ar(spread.neg, spread, trig);
            wid = 1 - spread;
            envSel = Select.kr(grain_shape.clip(0, 2), [-1, grain_env1, grain_env2]);
            // the drone's loudness law, halved for a chord of pads
            comp = (density * size).clip(0.25, 64).sqrt.reciprocal * 0.5
                * (1 + spread.squared).sqrt.reciprocal;
            cloud = (GrainBuf.ar(2, trig, dur, buf_l, pch, pos, 4, (r - wid).clip(-1, 1), envSel)
                + GrainBuf.ar(2, trig, dur, buf_r, pch, pos, 4, (r + wid).clip(-1, 1), envSel)) * comp;
            eGate = Select.kr(one_shot, [gate, Trig.kr(Impulse.kr(0), sustain)]);
            env = EnvGen.ar(Env.asr(atk, 1, rel), eGate, doneAction: 2);
            sig = Balance2.ar(cloud[0], cloud[1], pan) * env * amp;
            Out.ar(play_bus, sig);
        }).add;

        SynthDef(\four_voice_slice, {
            arg buf_l, buf_r, play_bus,
                gate = 1, one_shot = 0, sustain = 0.05,
                note_pos = 0, note_pitch = 1, amp = 0.5, pan = 0,
                atk = 0.005, rel = 0.6,
                size = 0.1, density = 20, spread = 0.5,
                grain_jitter = 0, grain_pitch_spread = 0, grain_shape = 0,
                grain_env1 = -1, grain_env2 = -1, note_len = 0;
            var l, r, eGate, env, sig, slLen, slDur, slEnv;
            // clean, tight read from the slice point; no loop, no doneAction
            // here (env owns the lifetime)
            l = PlayBuf.ar(1, buf_l, note_pitch * BufRateScale.kr(buf_l), 1,
                note_pos * BufFrames.kr(buf_l), 0, 0);
            r = PlayBuf.ar(1, buf_r, note_pitch * BufRateScale.kr(buf_r), 1,
                note_pos * BufFrames.kr(buf_r), 0, 0);
            // THE SLICE HAS AN END. Given only a start, PlayBuf ran on through
            // the whole 60s buffer — so a pad played its slice and then
            // everything after it, while the PADS page drew eight bounded
            // cells. The picture and the sound disagreed on every held pad.
            // note_len is the slice length as a buffer fraction; 0 (an old
            // caller, or a deliberate "to the end") keeps the previous
            // behaviour. Pitch scales how long the slice takes to play.
            slLen = Select.kr(note_len > 0, [1.0, note_len]);
            slDur = (slLen * BufDur.kr(buf_l) / note_pitch.abs.max(0.01)).clip(0.002, 60);
            // ~3ms out so the boundary closes without a click
            slEnv = EnvGen.kr(Env([1, 1, 0], [(slDur - 0.003).max(0.001), 0.003]));
            eGate = Select.kr(one_shot, [gate, Trig.kr(Impulse.kr(0), sustain)]);
            env = EnvGen.ar(Env.asr(atk, 1, rel), eGate, doneAction: 2);
            sig = Balance2.ar(l, r, pan) * env * amp * slEnv;
            Out.ar(play_bus, sig);
        }).add;

        // ---- the lanes' parts (see buildLane): every track has the same
        // filter, colour and effects between its voice and the mix.
        // COLOR, one law for every track (a build-time function: each def
        // inlines the same UGens). DRIVE is a clean to saturated crossfade,
        // so drive 0 is a true bypass (LINEAR, not equal power: the two arms
        // are the same signal, and XFade2 summed them to a +3dB hump at mid
        // knob). CRUSH holds each sample for longer (the rate falls 32 times
        // at the top) and rounds it to fewer bits (16 down to 4). It fades in
        // over the first tenth of the knob, so crush 0 is a true bypass and
        // the rest of the knob is all crushed.
        colour = { arg sig, drive, crush, drive_t, crush_t;
            var pre, xf, rate, steps, cr;
            drive = gl.(drive, drive_t);
            pre = 1 + (drive * 6);
            sig = LinXFade2.ar(sig, th.value(sig * pre) * pre.sqrt.reciprocal,
                (drive * 2 - 1));
            crush = gl.(crush, crush_t);
            rate = SampleRate.ir * (0.5 ** (crush * 5));
            steps = 2 ** (16 - (crush * 12));
            cr = (Latch.ar(sig, Impulse.ar(rate)) * steps).round / steps;
            xf = (crush * 10).clip(0, 1);
            LinXFade2.ar(sig, cr, (xf * 2 - 1))
        };

        // THE EFFECT, one slot for every track (a build-time function, like
        // `colour`). type 0 is OFF, and then every weight is 0 and the output
        // is the input, sample for sample. A type change is a 50ms crossfade.
        //   1 CHORUS  a 15ms delay that an LFO moves, beside the dry signal.
        //             amt is depth and mix, rate is the LFO speed (0.1 to 6Hz)
        //   2 FLANGE  a 0.5 to 6.5ms sweep with feedback. amt is feedback and
        //             mix, rate is the sweep speed (0.05 to 5Hz)
        //   3 WOBBLE  the delayed signal alone, its time drifting like a worn
        //             tape (wow and flutter). amt is the drift depth, rate
        //             its speed. amt 0 is the signal 12ms late, unchanged
        //   4 RESON   a comb tuned to a note. rate is the note (C2 to C6, in
        //             semitones), amt is how long it rings and the mix
        //   5 RING    the signal times a sine. rate is its frequency (20Hz
        //             to 4kHz), amt is the mix
        //   6 ECHO    a delay of the track's own. rate is the time (30ms to
        //             1.2s), amt is the feedback and the echo level
        // Types 1 to 3 share ONE comb pair (they are all a moving delay), so
        // a change between them glides the delay time for 100ms. A track has
        // TWO slots in series (effect, effect2), and a slot that is OFF has
        // no synth and costs nothing.
        // The three effect synths. Each reads the lane's bus, and XOut puts
        // its sound back over a 50ms fade (in at the start, out at the
        // release), so a type change is a crossfade. The fade is an S curve
        // (\sin), flat at both ends. The Mac's scsynth (3.14) frees a released
        // synth one control step short of 0: on a straight line that step was
        // 1.4% of the effect, and the S curve leaves 0.05%. The norns's (3.13)
        // runs the release to its end.
        //   \four_fx_mod    CHORUS, FLANGE, WOBBLE (type 1 to 3): one comb
        //                   pair, so a change between them glides for 100ms
        //   \four_fx_reson  RESON     \four_fx_ring  RING
        // A NEW SYNTH'S LINES FILL FROM SILENCE: it reads the bus through a
        // 10ms fade-in. A line is born empty under a playing sound. Without
        // the fade it caught the sound mid-wave, and that edge came out one
        // line length later as a step: 12ms after a tap into WOBBLE, 15ms
        // into CHORUS, 190ms into ECHO, and RESON rang with it for 200ms
        // (gate row 19.12 on the device, test/dsp/review/probe6.scd offline).
        // The fade is an AUDIO RATE envelope, and not Line.kr: the norns's
        // scsynth (3.13) holds Line.kr's first step for its whole first
        // block, so the line still caught 14% of the edge (gate row 19.29).
        // A SLOT WHOSE SOUND IS A LATE COPY HOLDS ITS RELEASE (the fifty-sixth
        // change). WOBBLE is the sound 12ms late, and plugin FLANGE's dry side
        // 1.41ms late. A crossfade of the sound with its own late copy combs:
        // where the two are in opposite phase they cancel, and a change into
        // WOBBLE dipped by 11 to 17 dB for 10 to 20ms (gate row 19.12). So
        // their delay starts at 0 and glides to its place (`ramp`, given to
        // the effect with the gate), and at the release it glides back to 0
        // while the slot still sounds whole. `hold` is that glide's time, a
        // function of the type: the 50ms fade out starts after it.
        // Without `hold` the envelope is the plain one, as before.
        fxSlot = { arg name, func, hold;
            SynthDef(name, {
                arg pbus, type = 1, amt = 0.5, rate = 0.5, gate = 1, amt_t = 0.02, rate_t = 0.02;
                var env = hold.isNil.if({
                    EnvGen.kr(Env.asr(0.05, 1, 0.05, \sin), gate, doneAction: 2)
                }, {
                    EnvGen.kr(Env([0, 1, 1, 0], [0.05, hold.value(type), 0.05], \sin, 1),
                        gate, doneAction: 2)
                });
                var sig = In.ar(pbus, 2) * EnvGen.ar(Env([0, 1], [0.01], \sin));
                XOut.ar(pbus, env, func.value(sig, type,
                    gl.(amt.clip(0, 1), amt_t), gl.(rate.clip(0, 1), rate_t), gate));
            }).add;
        };
        fxSlot.value(\four_fx_mod, { arg sig, type, a, r, gate;
            var idx, lfoCh, lfoFl, wow, flut, flw, dt, decay, comb, dryG, wetG;
            var chF, chD, wowF, wowD, flF, flD, p, flN, ramp;
            idx = (type - 1).clip(0, 2);
            // THE AMOUNT KNOB RISES FAST AT FIRST (the forty-fifth change).
            // The user on the device, 2026-11-17: the effects were "a bit too
            // bland". Measured (test/dsp/review/probe7.scd), CHORUS and FLANGE
            // moved the sound least at 0.5, where a slot starts, and RESON
            // and RING were 3 to 4 dB under the dry sound there. `p` is the
            // knob on a curve, its square root: 0.71 at its middle, 1 at its top.
            // EVERY LAW HERE COSTS NO MORE UGENS THAN THE ONE IT REPLACED. On
            // the norns a control-rate operator costs about 0.01% of the
            // scsynth thread for each synth: a first version with nine more of
            // them in FLANGE and four in ECHO took the dense set of gate row
            // 19.27 from 62.4% to 63.5%. probe7 counts each def's UGens.
            p = a.sqrt;
            // DEPTH IS SET AS PITCH, not as time. A delay that moves by
            // D*sin(2pi*f*t) bends the pitch by the ratio 2pi*f*D at its
            // peak, so a fixed depth in time grew with the rate: measured,
            // CHORUS reached -456 to +361 cents at the top of both knobs and
            // WOBBLE +-140. D = (2^(cents/1200) - 1) / (2pi*f) holds the
            // bend whatever the rate, up to the room the delay line has.
            // CHORUS 8 to 50 cents. WOBBLE's wow reaches 50 cents at the
            // knob's middle and 100 at its top, and its flutter 15 and 30.
            chF = 0.1 * (60 ** r);
            chD = (((2 ** ((8 + (42 * a)) / 1200)) - 1) / (2pi * chF)).min(0.012);
            wowF = 0.3 * (6 ** r);
            wowD = ((a * (2 * ((2 ** (50 / 1200)) - 1))) / (2pi * wowF)).min(0.010);
            flF = 6 * (2 ** r);
            flD = (a * (2 * ((2 ** (15 / 1200)) - 1))) / (2pi * flF);
            lfoCh = SinOsc.kr(chF, [0, 0.5pi]);
            lfoFl = SinOsc.kr(0.05 * (100 ** r), [0, 0.25pi]);
            wow = (SinOsc.kr(wowF, [0, 0.3]) * 0.7)
                + (LFNoise2.kr(0.5 * (6 ** r)) * 0.3);
            flut = SinOsc.kr(flF);
            flw = flD * flut;
            // WOBBLE's delay glides in from 0 over 0.65s, and back out at the
            // release (fxSlot's `hold`, below). The sine curve's steepest
            // place bends the pitch by 50 cents, the wow's own reach at the
            // knob's middle. CHORUS and FLANGE keep their dry sound on time,
            // so their delay does not glide: a sweep would be a flange.
            // A comb with no decay has no feedback at any delay, 0 included.
            ramp = EnvGen.kr(Env([0, 1, 0], [0.65, 0.65], \sin, 1), gate);
            dt = 2.collect({ arg ch;
                Select.kr(idx, [
                    0.015 + (chD * lfoCh[ch]),
                    0.0035 + (0.003 * lfoFl[ch]),
                    (0.012 + (wowD * wow[ch]) + flw) * ramp
                ]).lag(0.1)
            });
            // the stock FLANGE's level: the comb's ring adds to the sound, and
            // without this its top came out 6 dB over the dry sound
            flN = (1 + (1.2 * p)).reciprocal;
            decay = Select.kr(idx, [DC.kr(0), p * 0.12, DC.kr(0)]).lag(0.05);
            dryG = Select.kr(idx, [1 - (0.25 * p), flN, DC.kr(0)]).lag(0.05);
            wetG = Select.kr(idx, [0.9 * p, p * flN, DC.kr(1)]).lag(0.05);
            comb = 2.collect({ arg ch; CombC.ar(sig[ch], 0.05, dt[ch], decay) });
            (sig * dryG) + (comb * wetG)
        }, { arg type; (type > 2.5) * 0.65 });
        // RESON: the gain law holds a long ring near the level of a short
        // one, and the tanh bounds a peak. The power is 0.25: at 0.5 (the
        // exact law for noise) music came out about 8dB under the other
        // effects on the device.
        // THE DRY SOUND STAYS WHOLE UP TO THE KNOB'S MIDDLE, and the ring is
        // added to it. Above the middle the dry sound leaves, and the top is
        // the ring alone. On a straight crossfade the middle was half of
        // each: 3 dB under the dry sound on a chord, and 7 dB on a tone that
        // is off the resonator's note (gate row 19.11 on the device), where
        // the ring is weak. The ring's level is `a * (3.26 - (2.21 * a))`:
        // 0.68 at a quarter of the knob, 1.08 at its middle, 1.05 at its top,
        // where the long ring is loud by itself.
        // One gain serves both sides: their notes are 0.3% apart.
        fxSlot.value(\four_fx_reson, { arg sig, type, a, r;
            var note, rdt, rdec, fb, gain, res;
            note = (36 + (r * 48)).round(1).midicps;
            rdt = [note, note * 1.003].reciprocal;
            rdec = 0.05 + (a * a * 3);
            fb = 0.001 ** (rdt[0] / rdec);
            gain = ((1 - fb.squared) ** 0.25) * (a * (3.26 - (2.21 * a)));
            res = 2.collect({ arg ch;
                th.value(CombC.ar(sig[ch], 0.02, rdt[ch].lag(0.05), rdec) * gain)
            });
            (sig * (2 - (2 * a)).min(1)) + res
        });
        // RING: a product with a sine has half the power of the sound, so the
        // sine is 3 dB louder (2.sqrt), and the two cross at equal power. On
        // a straight crossfade the knob's middle was 4 dB under the dry sound.
        fxSlot.value(\four_fx_ring, { arg sig, type, a, r;
            XFade2.ar(sig, sig * SinOsc.ar(20 * (200 ** r), 0, 2.sqrt), (a * 2 - 1))
        });
        // FLANGE with the plugin (without it, type 2 of \four_fx_mod). The
        // first one sounded harsh, for three reasons, and each has its answer:
        //   the sweep moved evenly in TIME, so it raced through the top. It
        //     now moves evenly in PITCH: 0.25ms to 8ms on an exponential law
        //   the feedback was the bare comb. It now passes a 5kHz low-pass and
        //     a soft clip (FourDelay), so the resonance is round, not metallic
        //   it never reached zero. The dry signal is now 1.41ms late, the
        //     middle of the sweep, so the wet one passes THROUGH it: the
        //     notches run up out of hearing and come back, as on two tapes
        // amt is the feedback and the mix, rate is the sweep speed. Both rise
        // fast at first (the forty-fifth change): at the knob's middle the
        // wet sound is at 0.71 of the dry one and the feedback at 0.64. The
        // gain holds the level: the loop's ring adds to the sound, and the
        // top came out 7 dB over a chord.
        // Its dry side glides from on time to 1.41ms late over 0.2s, and
        // back at the release (fxSlot's `hold`): 19 cents at the steepest.
        stretchOn.if({ fxSlot.value(\four_fx_flange, { arg sig, type, a, r, gate;
            var ramp = EnvGen.kr(Env([0, 1, 0], [0.2, 0.2], \sin, 1), gate);
            var lfo = SinOsc.kr(0.05 * (100 ** r), [0, 0.25pi]);
            var d = 0.0014142 * (5.657 ** lfo);
            var p = a.sqrt;
            var fb = p * 0.9;
            var wet = 2.collect({ arg ch;
                delayClass.ar(sig[ch], d[ch], fb, 5000, 0.02) });
            (DelayC.ar(sig, 0.002, 0.0014142 * ramp) + (wet * p)) * (1 - (0.55 * a))
        }, 0.2) });
        // ECHO: a delay of the track's own, 30ms to 1.2s. rate is the time
        // (it glides like tape when turned), amt is the feedback and the
        // level of the echoes. The loop darkens and saturates softly. Both
        // rise fast at first (the forty-fifth change): at the knob's middle
        // the echoes are at 0.71 of the sound and the feedback at 0.57. The
        // top is where it was: the echoes at the level of the sound, and the
        // feedback at 0.8.
        fxSlot.value(\four_fx_echo, { arg sig, type, a, r;
            var t = (0.03 * (40 ** r)).lag(0.3);
            var p = a.sqrt;
            var fb = p * 0.8;
            var wet = stretchOn.if({
                2.collect({ arg ch; delayClass.ar(sig[ch], t, fb, 3500, 1.3) })
            }, {
                // stock: a comb. Its decay is the time for the same feedback
                // to fall by 60dB
                2.collect({ arg ch; CombC.ar(sig[ch], 1.3, t,
                    t * (0.001.log / fb.max(0.001).log)) })
            });
            sig + (wet * p)
        });

        // ---- the lane's other synths
        // in: the track's voice (pre_gain is track 1's grain_level) and the
        // sends from the other tracks, a block late and bounded by a tanh.
        // 2.sqrt is the exact inverse of Balance2's -3dB centre in the play
        // defs, so PLAY at pan 0 is the take at unity.
        SynthDef(\four_lane_in, {
            arg in_bus, sbus, pre_gain = 1.0,
                snd1 = 0, snd2 = 0, snd3 = 0, snd4 = 0,
                ob1 = 0, ob2 = 0, ob3 = 0, ob4 = 0,
                pre_gain_t = 0.02, snd1_t = 0.02, snd2_t = 0.02, snd3_t = 0.02, snd4_t = 0.02;
            var sendIn = (InFeedback.ar(ob1, 2) * gl.(snd1, snd1_t))
                + (InFeedback.ar(ob2, 2) * gl.(snd2, snd2_t))
                + (InFeedback.ar(ob3, 2) * gl.(snd3, snd3_t))
                + (InFeedback.ar(ob4, 2) * gl.(snd4, snd4_t));
            Out.ar(sbus, (In.ar(in_bus, 2) * gl.(pre_gain, pre_gain_t) * 2.sqrt)
                + th.value(LeakDC.ar(sendIn)));
        }).add;
        // the filter, as two families: LO is the low-pass ladder (LP, and BP
        // as its peak high-passed), HI is the high-pass ladder. Only the one
        // that is heard runs. A change of family is a 20ms crossfade between
        // two synths (linear, so the two add up to 1); LP to BP glides inside
        // LO. DFM1 is guarded: stock filters when sc3-plugins is absent.
        // inputgain 0.5: DFM1 is a NONLINEAR diode model, and at unity input
        // gain it saturated constantly. dfmTrim brings its output to unity.
        // The resonance stays under DFM1's self-oscillation (about 0.95).
        // OPEN IS NOT A BYPASS. The synth runs at 20kHz too. DFM1's source
        // (sc3-plugins, Dfm1.cpp) puts every sample through z - z^3/3: a
        // third harmonic 37dB under a -6dBFS tone, 24dB under a 0dBFS one.
        // The stock path is worse: RLPF at 20kHz and resonance 0 is 10dB down
        // at 10kHz and 21dB down at 19kHz (measured offline). DFM1's HP is 6dB
        // an octave, RHPF's 12. doc/measurements/2026-11-15/README.md.
        [\four_filt_lo, \four_filt_hi].do({ arg name, hi;
            SynthDef(name, {
                arg sbus, pbus, cutoff = 20000, resonance = 0, filt_type = 0, gate = 1,
                    cutoff_t = 0.02, resonance_t = 0.02;
                var env = EnvGen.kr(Env.asr(0.02, 1, 0.02, \lin), gate, doneAction: 2);
                var sig = In.ar(sbus, 2);
                var cf = gl.(cutoff.clip(20, 20000), cutoff_t);
                var res = gl.(resonance, resonance_t);
                var wBp = Lag.kr(filt_type > 1.5, 0.02);
                var dfmClass = "DFM1".asSymbol.asClass;
                var stock = {
                    var rq = (1 - (res * 0.92)).max(0.05);
                    (hi == 1).if({ RHPF.ar(sig, cf, rq) }, {
                        (RLPF.ar(sig, cf, rq) * (1 - wBp))
                            + (BPF.ar(sig, cf, rq) * (1 + res) * wBp)
                    })
                };
                var out = dfmClass.notNil.if({
                    try {
                        // in, freq, res, inputgain, type(0=LP 1=HP), noiselevel
                        var f = dfmClass.ar(sig, cf, res.clip(0, 0.9), 0.5, hi, 0) * dfmTrim;
                        (hi == 1).if({ f }, {
                            (f * (1 - wBp))
                                + (HPF.ar(f, (cf * 0.5).clip(20, 20000)) * wBp)
                        })
                    } { |e| stock.value }
                }, { stock.value });
                Out.ar(pbus, out * env);
            }).add;
        });
        // COLOR, in place. It exists only while drive or crush is up: at 0
        // both are an exact bypass, so it comes and goes with no fade.
        SynthDef(\four_colour, {
            arg pbus, drive = 0, crush = 0, drive_t = 0.02, crush_t = 0.02;
            ReplaceOut.ar(pbus, colour.value(In.ar(pbus, 2), drive, crush, drive_t, crush_t));
        }).add;
        // out (tracks 2 to 4): the level, and where the track goes
        SynthDef(\four_lane_out, {
            arg pbus, out_bus, own_out, level = 1.0, fx_dly = 0, fx_rev = 0,
                dly_out = 0, rev_out = 0, level_t = 0.02, fx_dly_t = 0.02, fx_rev_t = 0.02;
            var sig = In.ar(pbus, 2) * gl.(level, level_t);
            Out.ar(own_out, sig);     // what the other tracks' sends read
            Out.ar(out_bus, sig);
            Out.ar(dly_out, sig * gl.(fx_dly, fx_dly_t));
            Out.ar(rev_out, sig * gl.(fx_rev, fx_rev_t));
        }).add;

        // ---- io: input, record head (with resample feedback), dry/wet, out

        SynthDef(\four_io, {
            arg in1, in2, out, buf_l, buf_r, play_bus, rec_phase_out, rec_amp_out,
                level = 1.0, rec = 0, rec_pass = 0, rec_level = 1.0, pre_level = 0.0,
                freeze = 0, dry_wet = 0.5, resample = 0.0, regen = 0.0,
                grain_level = 1.0,
                filt_type = 0, cutoff = 20000, resonance = 0, drive = 0.0,
                // track 1's COLOR (crush) and SPACE (its sends into the delay
                // and the reverb); lanes_dly and lanes_rev carry the other tracks'.
                // NEVER name an argument t_...: SuperCollider makes it a trigger
                // control, which falls to 0 after one block. These two were t_dly
                // and t_rev, so io read bus 0 and tracks 2 to 4 never reached the
                // delay or the reverb (found on the device, 2026-11-16).
                crush = 0.0, fx_dly = 0.0, fx_rev = 0.0, lanes_dly = 0, lanes_rev = 0, dly_rev = 0.0,
                // track 1's EFFECT: its type and its two knobs
                effect = 0, effect_amt = 0.5, effect_rate = 0.5,
                // delay + reverb run in their own spawn/free synths; io keeps
                // only the mix knobs and the send/return buses
                delay_mix = 0.0, dly_send = 0, dly_ret = 0,
                rev_mix = 0.0, rev_send = 0, rev_ret = 0, t2_ret = 0,
                // routing: the sends into track 1, and where track 1's
                // filtered output goes for the others to read
                snd2 = 0, snd3 = 0, snd4 = 0, ob2 = 0, ob3 = 0, ob4 = 0, own_out = 0,
                lane_bus = 0,
                // RELAY (C13 of doc/signature-workflow.md): what a take
                // records from. 0 the line input, 1 track 1 after its lane,
                // 2 the bus `src_bus` (track 2, 3 or 4 after its lane), 3 the
                // mix before the limiter. rec_track sets both.
                rec_src = 0, src_bus = 0,
                // an aligned overdub: \four_dub writes the pass from here,
                // and io's own rec stays 0 (ioGate)
                dub_out = 0,
                // the glide times of io's own knobs (gl)
                level_t = 0.02, dry_wet_t = 0.02, delay_mix_t = 0.02, rev_mix_t = 0.02,
                fx_dly_t = 0.02, fx_rev_t = 0.02, dly_rev_t = 0.02;
            var inL, inR, wet, dry, sig, preLim, recRun, recPhase, recL, recR;
            var cf, res, dlyRet, rvRet, dfmClass, mmFilter;
            var regenRun, runW, srcL, srcR, recLvl, preLvl, recG, regG, wLp, wHp, wBp;
            var newPass;
            var sendIn, others, revIn, dm, own, tap, srcK, baseL, baseR;
            inL = In.ar(in1, 1);
            inR = In.ar(in2, 1);
            // wet is track 1 after its lane (the drone and the polyphonic
            // voices, its filter, colour and effects): see buildLane
            wet = In.ar(lane_bus, 2);
            own = wet;                // track 1 alone, for a relay from it
            Out.ar(own_out, wet);     // track 1, filtered and coloured, for the sends
            // tracks 2 to 4 join here, after their own filter and colour
            others = In.ar(t2_ret, 2);

            // the delay runs in \four_delay (spawn/free: alive while
            // delay_mix > 0 or the feedback is a near-infinite hold). SPACE:
            // what goes in is each track's own send (fx_dly, 0 at the start).
            // The echo comes back through InFeedback, one block late; the
            // delay synth's line is one block short to pay for it. delay_mix
            // is the level of the echoes (squared in Lua, so .sqrt makes it
            // linear in the knob), lagged so a CC step does not zipper. At
            // rest the synth is gone and the return reads 0.
            dm = gl.(delay_mix, delay_mix_t);
            Out.ar(dly_send, (wet * gl.(fx_dly, fx_dly_t)) + In.ar(lanes_dly, 2));
            dlyRet = InFeedback.ar(dly_ret, 2) * dm.sqrt;

            // SPACE is two SENDS (doc/space-plan.md, section 3). A track goes
            // to the delay by its fx_dly and to the reverb by its fx_rev, both
            // 0 at the start, and the two returns are ADDED to the dry sum.
            // The dry sum never ducks: delay_mix is the level of the echoes,
            // as rev_mix is the level of the tail. (Before, the delay was a
            // crossfade that lowered the dry sound, and each track sent
            // everything.) dly_rev sends the echoes into the reverb.
            revIn = (wet * gl.(fx_rev, fx_rev_t)) + In.ar(lanes_rev, 2)
                + (dlyRet * gl.(dly_rev, dly_rev_t));
            Out.ar(rev_send, revIn);
            wet = wet + others + dlyRet;
            rvRet = InFeedback.ar(rev_ret, 2);
            // SEND-style (OT-like): the direct sound stays at full level and
            // rev_mix only scales how much tail is ADDED. Lua squares the
            // knob, so .sqrt makes the tail gain linear in it.
            rev_mix = gl.(rev_mix, rev_mix_t);
            wet = wet + (rvRet * rev_mix.sqrt);

            dry = [inL, inR];
            dry_wet = gl.(dry_wet, dry_wet_t);
            sig = (dry * (1 - dry_wet).sqrt) + (wet * dry_wet.sqrt);
            sig = sig * gl.(level, level_t);
            // What gets RECORDED is tapped here, before the master limiter.
            // The limiter delays its output by twice its lookahead (6 ms
            // here; it was 20 ms). `resample` mixes the input with the output, so with
            // the old tap that mix was the signal plus a 10 ms copy of itself:
            // a hollow, phasey colour, printed into the buffer for good.
            // Nothing is less safe for taking it from here. The 0.99 limiter
            // further down still catches anything hot before it reaches the
            // buffer, and the two regen record levels still add up to 1.
            preLim = sig;
            // DAC headroom. Lookahead 3ms, so the output is 6ms late: at
            // 0.01 the whole output, dry monitor included, came 20ms late,
            // and with the norns monitor up the input was heard twice.
            sig = Limiter.ar(sig, 0.92, 0.003);
            recRun = rec * (1 - freeze);
            // regen: run the record head continuously and crossfade the OUTPUT
            // back into the buffer (self-mangle). BOUNDED (convex crossfade +
            // LeakDC + master Limiter); bit-identical to no-regen at regen=0.
            // manual rec and freeze both suspend it. a CHOKED engine deck
            // (STOP / mix thrown fully to tape -> level ~0) PAUSES it — else a
            // stopped minute of regen crossfades SILENCE over the whole take.
            regenRun = (regen > 0) * (1 - rec) * (1 - freeze) * (level > 0.001);
            // recG and regG are the two writes' gates, ramped linearly over
            // 10ms (Slew reaches 0 exactly). The head keeps running until the
            // ramp is down, so a punch-out, a punch-in and a regen start fade
            // the write instead of printing a step into the take. Each ramp
            // starts from rec 0, pre 1: a write that does nothing.
            recG = Slew.kr(recRun, 100, 100);
            regG = Slew.kr(regenRun, 100, 100);
            runW = recRun.max(regenRun).max(recG > 0).max(regG > 0);
            // the polled write-head phase advances with the SAME run signal
            // RecordBuf gets (rec OR regen): driven by rec alone, a regen pass
            // walked the real head while rec_phase stayed parked, so the next
            // take's window snapped to stale positions.
            // EACH PART STARTS AT THE START OF ITS OWN BUFFER (C4 of
            // doc/signature-workflow.md, the forty-ninth change). The head
            // stopped where a pass ended and the next pass went on from
            // there, on any track: four parts of 20 s did not fit, and the one
            // that crossed the end became a 60 s loop with silence in it.
            // rec_pass steps up by 1 when Lua opens a new take (rec_track's
            // second argument), and that step is the trigger: the polled
            // phase and both RecordBufs go to 0 in the same block. A STOP and
            // START, an overdub and a regen never step it, so they go on from
            // where the head is. (rec_pass is a plain control: a t_ argument
            // falls to 0 after one block, and test_control rejects the name.)
            newPass = HPZ1.kr(rec_pass);
            recPhase = Phasor.ar(newPass, runW * SampleDur.ir / BufDur.kr(buf_l), 0, 1);
            Out.kr(rec_phase_out, A2K.kr(recPhase));
            // LeakDC on the take's dry arm: a line input with DC offset would
            // print it into the buffer and eat limiter headroom. (the regen
            // arm below already has its own; the monitor path stays untouched.)
            // resample is lagged because a step in THIS blend gets printed
            // permanently into the take, not just heard once.
            resample = resample.lag(0.02);
            // the take's source (RELAY). A track's bus holds it after its
            // filter, colour, effects and level, before its sends: the copy
            // does not hold the shared delay and reverb. The source only
            // changes at an arm, while the rec gate is shut.
            tap = In.ar(src_bus, 2);
            srcK = rec_src.round.clip(0, 3);
            baseL = Select.ar(srcK, [LeakDC.ar(inL), own[0], tap[0], preLim[0]]);
            baseR = Select.ar(srcK, [LeakDC.ar(inR), own[1], tap[1], preLim[1]]);
            recL = (baseL * (1 - resample)) + (preLim[0] * resample);
            recR = (baseR * (1 - resample)) + (preLim[1] * resample);
            srcL = (recL * (1 - regG)) + (LeakDC.ar(preLim[0]) * regG);
            srcR = (recR * (1 - regG)) + (LeakDC.ar(preLim[1]) * regG);
            // record-safety limiter: transparent below 0.99, stops a hot take
            // hard-clipping into the buffer.
            srcL = Limiter.ar(srcL, 0.99, 0.002);
            srcR = Limiter.ar(srcR, 0.99, 0.002);
            // the knobs keep their ~10ms lag, so a mid-take move of
            // rec_level, pre_level or regen does not print a step either.
            // With both gates at 0 this is rec 0, pre 1. The gates never sum
            // past 1 (a rec to regen hand-over crosses them), so pre stays >= 0.
            recLvl = (Lag.kr(rec_level, 0.01) * recG) + (Lag.kr(regen, 0.01) * regG);
            preLvl = 1 - (recG * (1 - Lag.kr(pre_level, 0.01)))
                - (regG * Lag.kr(regen, 0.01));
            RecordBuf.ar(srcL, buf_l, 0, recLvl, preLvl, runW, 1, newPass);
            RecordBuf.ar(srcR, buf_r, 0, recLvl, preLvl, runW, 1, newPass);
            Out.kr(rec_amp_out,
                Amplitude.kr(recL.abs.max(recR.abs) * rec_level, 0.01, 0.1));
            // the record signal, for \four_dub (an aligned overdub)
            Out.ar(dub_out, [srcL, srcR]);
            Out.ar(out, sig);
        }).add;

        // ---- AN ALIGNED OVERDUB (the sixty-seventh change). io's write head
        // is one for the four tracks, and an overdub went on from where the
        // last pass stopped: not where the track plays. This synth writes the
        // pass instead of io (io's `dub` holds its own write shut). It starts
        // where the track's read head is and loops inside the track's window,
        // on the read head's own law: winBounds, whole frames, and the place
        // for the first block only (Trig.kr, as winRead does). The head reads
        // the phase bus on the server at its first block: what sclang reads
        // is already old (CLAUDE.md, the lessons). The bus holds where the
        // drone was one block ago, so the write starts one block ahead.
        // It lives only while `rec` is up and frees itself 10 ms after it
        // falls: a writer that stays parked writes back what it read, and that
        // can put one old sample back into a clear or a file that loads.
        // At speed 1 in PLAY the two heads stay together. Another speed or
        // voice reads at its own pace, and the write goes on at speed 1.
        SynthDef(\four_dub, {
            arg buf_l, buf_r, src_bus, from_bus, rec_phase_out,
                pos_start = 0, pos_end = 1, rec = 1, freeze = 0,
                rec_level = 1.0, pre_level = 0.0;
            var lo, span, frames, loF, spanF, env, fz, w, run, whole, idx, src;
            var oldL, oldR, recLvl, preLvl;
            #lo, span = winBounds.(pos_start, pos_end);
            frames = BufFrames.kr(buf_l);
            loF = (lo * frames).round;
            spanF = (span * frames).round.max(64);
            // 10 ms in and out, straight, like io's rec gate
            env = EnvGen.ar(Env([0, 1, 0], [0.01, 0.01], 0, 1), rec, doneAction: 2);
            fz = Slew.ar(K2A.ar(1 - freeze), 100, 100);
            w = env * fz;
            run = w > 0;
            whole = Phasor.ar(0, run,
                Trig.kr((((In.kr(from_bus) * frames).round + BlockSize.ir) - loF) % spanF, 0),
                spanF);
            idx = loF + whole;
            src = In.ar(src_bus, 2);
            recLvl = Lag.kr(rec_level, 0.01) * w;
            preLvl = 1 - (w * (1 - Lag.kr(pre_level, 0.01)));
            oldL = BufRd.ar(1, buf_l, idx, 1, 1);
            oldR = BufRd.ar(1, buf_r, idx, 1, 1);
            BufWr.ar((src[0] * recLvl) + (oldL * preLvl), buf_l, idx, 1);
            BufWr.ar((src[1] * recLvl) + (oldR * preLvl), buf_r, idx, 1);
            ReplaceOut.kr(rec_phase_out, A2K.kr(idx / frames));
        }).add;

        // ---- THE TRACKS' METERS (the seventy-fourth change, doc/mix-plan.md):
        // how loud each track is after its lane and its level, the louder
        // side, as four polls. A paused strip writes no bus, and reads 0.
        SynthDef(\four_meter, {
            arg ob1 = 0, ob2 = 0, ob3 = 0, ob4 = 0, out = 0;
            Out.kr(out, [ob1, ob2, ob3, ob4].collect({ arg b;
                var x = In.ar(b, 2).abs;
                // Amplitude.ar, not .kr: on an audio input .kr counts its times
                // in blocks and steps them by samples, so 0.3 s was 5 ms and the
                // polls (15 a second) missed the hits. 1.5 s is 40 dB a second.
                A2K.kr(Amplitude.ar(x[0].max(x[1]), 0.005, 1.5))
            }));
        }).add;

        // ---- A HEAD SYNC (the sixty-seventh change, and the seventy-first,
        // which put it in a synth of its own). One runs for 18 ms at each
        // head_sync, right after the track's drone, and frees itself.
        // A LOOP THAT IS IN TIME IS LEFT ALONE. The command arrives a few ms
        // early or late at each beat (JACK's period, sclang, the network of
        // clocks), so a jump every time round moved the head by that much and
        // broke the wave: a step of 0.055 over a tone of -19 dB in PLAY, at
        // three of six restarts (gate row 21.4). The head's place is read
        // here, on the server, at the first block. Nearer than 10 ms to where
        // it must be: nothing happens. Further (a loop that drifted, a new
        // window, a tempo move): it jumps.
        // THE JUMP IS FADED in PLAY (`duck`): 5 ms out, the jump, 5 ms in.
        // The other voices' windows overlap, so a jump is smooth already:
        // they get the same wait and no fade. The jump comes 8 ms after the
        // command, and winRead lands the head 8 ms into the window.
        SynthDef(\four_sync, {
            arg play_bus, from_bus, sync_bus, buf, pos_start = 0, pos_end = 1, duck = 0;
            var fade = 0.005, lead, hold, dur, len, err, t, env;
            // a synth that frees itself at its first block still plays that
            // block: the fade waits two, or a sync in time prints a step
            lead = ControlDur.ir * 2;
            hold = ControlDur.ir * 4;
            dur = BufDur.kr(buf);
            len = ((pos_end - pos_start).abs * dur).max(0.01);
            err = ((((In.kr(from_bus) - pos_start.min(pos_end)) * dur) + (len * 0.5)) % len)
                - (len * 0.5);
            FreeSelf.kr(Impulse.kr(0) * (err.abs < 0.01));
            t = Sweep.kr(0, 1) - lead;
            ReplaceOut.kr(sync_bus, (t >= fade) * (t < (fade + (ControlDur.ir * 2.5))));
            env = EnvGen.ar(Env([1, 1, 1 - duck, 1 - duck, 1], [lead, fade, hold, 0.005]), doneAction: 2);
            ReplaceOut.ar(play_bus, In.ar(play_bus, 2) * env);
        }).add;

        // ---- BEAT REPEAT, in its own spawn/release synth (updateRepeat).
        // Placed after io, it reads io's finished output off the engine's out
        // bus and REPLACES it. On spawn it passes the output through while it
        // captures the first `len` seconds, then plays that slice in a loop
        // until released. The first pass sends the live input itself, not a
        // read of what is being written, so it never depends on the order the
        // server runs the write and the read in. A 3ms fade at every loop point
        // (and at the first pass's end) keeps the repeats from clicking; `gate`
        // crossfades in over 5ms and back to the live output over 10ms, then
        // frees the synth. It sits after the record tap, so resample, regen
        // and PRINT never record it: a performance effect on what you hear.
        SynthDef(\four_repeat, {
            arg out, buf, len = 0.25, gate = 1;
            var src, l, frames, firstK, first, phase, fade, rep, env;
            src = In.ar(out, 2);
            l = len.clip(0.01, 2);
            frames = (l * SampleRate.ir).max(64);
            // the capture runs two blocks PAST the slice: a kr Sweep reads
            // a block ahead, and stopping at l exactly left the last frames
            // of the loop holding an older capture (a tick in every fade).
            // Writing past `frames` is harmless; the loop never reads it.
            firstK = Sweep.kr(0, 1) < (l + (2 * ControlDur.ir));
            first = Sweep.ar(0, 1) < l;
            RecordBuf.ar(src, buf, 0, 1, 0, firstK, 0);
            phase = Phasor.ar(0, 1, 0, frames);
            fade = (phase.min(frames - phase)
                / (frames * 0.25).min(SampleRate.ir * 0.003)).clip(0, 1);
            rep = Select.ar(first, [BufRd.ar(2, buf, phase, 1, 2), src]) * fade;
            env = EnvGen.kr(Env.asr(0.005, 1, 0.01), gate, doneAction: 2);
            ReplaceOut.ar(out, (src * (1 - env)) + (rep * env));
        }).add;

        // delay synth (spawned by updateDelay). reads the tracks' delay sends,
        // returns the 100%-wet echo; io adds it to the dry sum. the regeneration
        // loop lives HERE (this def's own LocalIn/LocalOut pair), so freeing
        // the synth is what flushes the line — \clear leans on exactly that.
        // all core UGens. delay_mix is accepted and unused: the generic
        // command handler sets every delayParams key on the live synth, and
        // an unknown control name would be a server complaint per knob move.
        SynthDef(\four_delay, {
            arg in_bus, out_bus, delay_time = 0.3, delay_fb = 0.3, delay_mix = 0, delay_fb_t = 0.02;
            var sig, fbIn, dIn, dOut;
            // the line fills from silence, like an effect slot's (fxSlot):
            // the synth is born under a playing send, and the first echo
            // came back with a step at its head (gate row 10.4)
            sig = In.ar(in_bus, 2) * EnvGen.ar(Env([0, 1], [0.01], \sin));
            delay_fb = gl.(delay_fb, delay_fb_t);   // CC steps zipper without this
            // With the plugin the delay is THE BUCKET BRIGADE (FourBBD,
            // doc/space-plan.md): a chain of 8192 cells and a clock. TIME
            // moves the clock, so a turn bends the pitch as before, and a long
            // time is a slow clock and a dark echo: the corner is 5.7 kHz at
            // 0.5 s, 2.9 kHz at 1 s and 1.4 kHz at 2 s. Its loop is inside
            // it, so the echoes carry no block of delay. Only io's read of
            // the return is one block late, and the time is that much short.
            // The least time is 43 ms. AGE is fixed at 0.25 until SPACE has a
            // knob for it: a little noise that rises behind each note.
            stretchOn.if({
                dOut = 2.collect({ arg ch;
                    bbdClass.ar(sig[ch], delay_time.clip(0.01, 2.0).lag(0.2) - ControlDur.ir,
                        delay_fb, 0.35, 0.25)
                });
            }, {
            fbIn = LocalIn.ar(2);
            dIn = sig + (fbIn * delay_fb);
            // 2s line: a half-note sync below 120 BPM needs more than 1s,
            // and the extra second costs ~0.75 MB of server memory
            // minus one block: LocalIn hands each repeat back one block late,
            // and io reads the return one block late, so the line itself is
            // one block short. Every echo, the first included, lands on time.
            // (Without it a synced delay drifted 1.33ms per repeat.)
            dOut = DelayC.ar(dIn, 2.0,
                delay_time.clip(0.01, 2.0).lag(0.2) - ControlDur.ir);
            // tanh, not softclip, for the signal that goes back round the
            // loop. softclip bends sharply at the point it starts limiting,
            // and every repeat bends it again, so the distortion piles up
            // scratchy. tanh curves smoothly and still stops at +-1.
            // WHAT IT COSTS, measured: softclip leaves anything under 0.5
            // completely untouched, tanh does not. A repeat at level 0.5 comes
            // back 0.86 dB quieter each pass instead of 0.18 dB, so a hold
            // that used to sit still now fades about 10 dB over a dozen
            // repeats. Quiet repeats are unaffected. If the infinite hold
            // needs to sustain rather than fade, put softclip back here.
            LocalOut.ar(th.value(LPF.ar(dOut, 3500)));
            });
            Out.ar(out_bus, dOut);
        }).add;

        // reverb + shimmer synth (spawned by updateReverb while rev_mix > 0).
        // reads the tracks' reverb sends (and dly_rev's echoes), returns the
        // tail; shimmer recirculates through this synth's own LocalIn/LocalOut.
        // THREE reverbs, by what is installed: FourRoom (the plugin), else
        // JPverb (sc3-plugins), else FreeVerb. They differ. Measured offline
        // at decays of 0.8, 2 and 7s: the room's T60 is 0.67, 1.79 and 5.79s,
        // FreeVerb's 0.59, 0.61 and 0.75s, and FreeVerb is 3.3dB louder.
        // FreeVerb with shimmer at 0 semitones and a long decay runs away to
        // a full-scale drone (peak 4.8); the room does not.
        SynthDef(\four_reverb, {
            arg in_bus, out_bus,
                rev_size = 1.0, rev_decay = 2.0, rev_damp = 0.3, rev_early = 0.7,
                rev_moddepth = 0.1, rev_modfreq = 2.0,
                rev_low = 1.0, rev_mid = 1.0, rev_high = 1.0,
                rev_lowcut = 500, rev_highcut = 2000,
                shimmer = 0.0, shimmer_pitch = 12.0, shimmer_tone = 4500.0,
                rev_decay_t = 0.02, rev_damp_t = 0.02, shimmer_t = 0.02;
            var wet, fbIn, shimFb, revIn, rv, jpClass, ratio, pitched, shimOut;
            var roomGain;
            // the three that a fade moves by ear glide (gl). They had no lag,
            // so the decay, the damping and the shimmer's gain moved in steps.
            rev_decay = gl.(rev_decay, rev_decay_t);
            rev_damp = gl.(rev_damp, rev_damp_t);
            shimmer = gl.(shimmer.clip(0, 0.95), shimmer_t);
            wet = In.ar(in_bus, 2);                 // io's post-delay wet send
            // shimmer feedback: the pitched tail recirculates into the reverb
            // INPUT so it climbs in octaves. shimmer=0 -> shimOut 0 -> revIn==wet.
            fbIn = LocalIn.ar(2);
            shimFb = fbIn;
            revIn = wet + (shimFb * shimmer);
            jpClass = "JPverb".asSymbol.asClass;
            // With the plugin the reverb is THE ROOM (doc/space-plan.md): four
            // unitary diffusion steps and eight late lines. It takes 4% of
            // the audio thread where JPverb took 13.5%. rev_decay is its T60.
            // rev_damp makes it dark: the top keeps 1 down to 0.15 of the
            // decay. rev_size is the base time of the diffusion, read ONLY when
            // the synth starts, and only from 0.4 to 2.1 (the knob goes to 5).
            // A turn of SIZE while the room plays does nothing, and neither do
            // rev_early, rev_moddepth, rev_modfreq, rev_low, rev_mid,
            // rev_high, rev_lowcut and rev_highcut (a null test: bit for bit).
            // Its level is set against JPverb's, measured on the device with
            // the same pink noise at decays of 0.8, 2 and 7 s. The room alone
            // rose 4.9 dB over that range and JPverb 2.0 dB, so the return
            // falls gently with the decay. With this law the two are within
            // 0.7 dB of each other at all three, and a preset keeps its balance.
            roomGain = 0.71 * (rev_decay.max(0.1) ** -0.15);
            rv = stretchOn.if({
                roomClass.ar(revIn[0], revIn[1], rev_decay,
                    1 - (0.85 * rev_damp.clip(0, 1)),
                    (0.005 * rev_size).clip(0.002, 0.0105)) * roomGain
            }, { jpClass.notNil.if({
                // in (STEREO pair — the mono .sum collapsed the grain field's
                // pan/spread and the stereo shimmer out of the tail; array-in
                // via perform works, the MiClouds call is the precedent),
                // t60, damp, size, earlyDiff, modDepth, modFreq,
                // low, mid, high, lowcut, highcut
                jpClass.ar(revIn * 0.5, rev_decay, rev_damp, rev_size,
                    rev_early, rev_moddepth, rev_modfreq,
                    rev_low, rev_mid, rev_high, rev_lowcut, rev_highcut)
            }, {
                var rs = rev_decay.linlin(0.1, 30, 0.1, 0.97);
                [FreeVerb.ar(revIn[0], 1.0, rs, rev_damp),
                    FreeVerb.ar(revIn[1], 1.0, rs, rev_damp)] * 2
            }) });
            // pitch the tail (semitones -> ratio), band-limit so the octave
            // stack stays a halo (HPF kills DC/rumble build-up, LPF tames the
            // metallic hiss), the saturator bounds runaway. STEREO shimmer, a
            // PitchShift per channel, for a wide halo.
            ratio = (shimmer_pitch.round(1) / 12.0);
            ratio = (2 ** ratio).clip(0.25, 4);
            // pitchDispersion 0.02 (was 0): SC's own docs — uniform grain
            // placement at a fixed ratio combs; a whisper of dispersion
            // softens the robotic edge at the octave-up default.
            pitched = PitchShift.ar(rv, 0.2, ratio, 0.02, 0.01);
            pitched = LPF.ar(HPF.ar(pitched, 120), shimmer_tone.clip(500, 12000));
            // tanh for the same reason as the delay loop: this recirculates,
            // and a halo is the last place that wants a hard knee in it.
            shimOut = th.value(pitched * (shimmer > 0));
            LocalOut.ar(shimOut);
            Out.ar(out_bus, rv);
        }).add;

        s.sync;

        // playback group first, io after it, so io reads play_bus in-block.
        // polyphonic voices also spawn into playGroup (before io) -> they add
        // onto play_bus and pass through the io FX chain like the drone.
        playGroup = Group.new(context.xg);
        sendV = Array.fill(4, { Array.fill(4, 0) });
        // the four lanes, in playGroup's tail: after every drone and voice
        // (they are added at its head), before io. Track 1's lane has no out
        // synth: io reads its bus. A lane of tracks 2 to 4 is that track's
        // `strip`, and it starts paused: no extra track plays yet.
        lanes = Array.newClear(4);
        this.buildLane(0, playBus, nil);
        extra.do({ arg tr;
            this.buildLane(tr[\n] - 1, tr[\bus], [
                \out_bus, tRetBus, \own_out, outBuses[tr[\n] - 1],
                \dly_out, tDlyBus, \rev_out, tRevBus]);
            lanes[tr[\n] - 1][\p] = tr[\stripParams];
            tr[\strip] = lanes[tr[\n] - 1][\group];
            tr[\mode] = 0;
        });
        // (the run message follows its /g_new in order, no sync needed)
        extra.do({ arg tr; tr[\strip].run(false) });
        ioSynth = Synth.new(\four_io, [
            \in1, context.in_b[0].index,
            \in2, context.in_b[1].index,
            \out, context.out_b.index,
            \buf_l, bufL,
            \buf_r, bufR,
            \play_bus, playBus,
            \rec_phase_out, recPhaseBus,
            \rec_amp_out, recAmpBus,
            \dub_out, dubBus,
            \rev_send, revSendBus,
            \rev_ret, revRetBus,
            \dly_send, dlySendBus,
            \dly_ret, dlyRetBus,
            \t2_ret, tRetBus,
            \lanes_dly, tDlyBus, \lanes_rev, tRevBus,
            \own_out, outBuses[0],
            \lane_bus, lanes[0][\pBus],
        ], playGroup, \addAfter);
        meterSynth = Synth.new(\four_meter, [
            \ob1, outBuses[0], \ob2, outBuses[1], \ob3, outBuses[2], \ob4, outBuses[3],
            \out, meterBus
        ], ioSynth, \addAfter);

        // every float control as one command; rec/freeze/level fan out to both
        // synths; revParams route to \four_reverb and delayParams to
        // \four_delay; eroKeys also reach \four_erode; the mix/fb knobs
        // and erode also spawn/free their synths.
        allKeys = (ioKeys ++ playParams.keys.asArray ++ revParams.keys.asArray
            ++ delayParams.keys.asArray).asSet;
        allKeys.do({ arg name;
            this.addCommand(name, "f", { arg msg;
                var v = msg[1], t = this.glideT(name);
                ioKeys.includes(name).if({
                    // (rec and regen reach io through ioGate: an aligned pass
                    // is not io's)
                    ((name == \rec) or: { name == \regen }).if({
                        dubVals[name] = v;
                        this.ioGate;
                    }, {
                        this.gset(ioSynth, name, v, t);
                    });
                    // track 1's lane takes its own (the names io also has,
                    // level, fx_dly and fx_rev, are io's alone)
                    [\level, \fx_dly, \fx_rev].includes(name).not.if({
                        this.laneSet(0, name, v, t);
                    });
                });
                revParams.includesKey(name).if({
                    revParams[name] = v;
                    revSynth.notNil.if({ this.gset(revSynth, name, v, t) });
                });
                delayParams.includesKey(name).if({
                    delayParams[name] = v;
                    delaySynth.notNil.if({ this.gset(delaySynth, name, v, t) });
                });
                playParams.includesKey(name).if({
                    playParams[name] = v;
                    playSynth.notNil.if({ this.gset(playSynth, name, v, t) });
                    // the three the other tracks' drones share with the take
                    [\level, \rec, \freeze].includes(name).if({
                        extra.do({ arg tr;
                            tr[\synth].notNil.if({ this.gset(tr[\synth], name, v, t) });
                        });
                    });
                    (eroSynth.notNil and: { eroKeys.includes(name) }).if({
                        eroSynth.set(name, v);
                    });
                });
                // the aligned overdub's knobs, its life and track 1's window
                dubVals.includesKey(name).if({
                    dubVals[name] = v;
                    dubSynth.notNil.if({ dubSynth.set(name, v) });
                });
                (name == \rec).if({ this.updateDub(v) });
                ((name == \pos_start) or: { name == \pos_end }).if({
                    this.dubWindow(0, name, v);
                });
                (name == \erode).if({ this.updateErode });
                ((name == \delay_mix) or: { name == \delay_fb }).if({
                    this.updateDelay;
                });
                (name == \rev_mix).if({ revMixV = v; this.updateReverb(v) });
            });
        });

        this.addCommand(\mode, "i", { arg msg;
            this.setMode(msg[1]);
        });

        // own material per track: which pair io records into (and regen and
        // PRINT write), and which pair the buffer commands and pads act on
        // The second argument: 1 opens a new take, and io's write head
        // goes to the start of that pair (rec_pass, in \four_io). The format
        // is "ii" since the forty-ninth change: an arity change does not
        // move the command count, so the script reads the format to tell an
        // old engine (four.lua, head_resets).
        // The third argument, since the fifty-ninth change ("iii"), is the
        // take's SOURCE (RELAY): 0 the line input, 1 to 4 a track after its
        // lane, 5 the mix. io's rec_src and src_bus follow it.
        // The second argument 2 (the sixty-seventh change) is an ALIGNED
        // overdub: the passes go to \four_dub (updateDub), which starts at
        // the track's read head and loops in its window. An older engine
        // reads 2 as 1, so the script sends 2 only to an engine that has
        // head_sync, the command that came with it.
        this.addCommand(\rec_track, "iii", { arg msg;
            var src = (msg[3] ? 0).asInteger.clip(0, 5);
            var how = (msg[2] ? 0).asInteger;
            recIdx = msg[1].asInteger.clip(0, 3);
            ioSynth.set(\rec_src, [0, 1, 2, 2, 2, 3].at(src),
                \src_bus, ((src >= 2) and: { src <= 4 }).if({ outBuses[src - 1].index }, { 0 }));
            // (a pass that still runs ends here: the next one is set up)
            this.updateDub(0);
            dubOn = how == 2;
            this.ioGate;
            (how == 1).if({
                recPass = recPass + 1;
                bufGen[recIdx] = bufGen[recIdx] + 1;   // a new take: see clearWait
                ioSynth.set(\buf_l, bufLs[recIdx], \buf_r, bufRs[recIdx], \rec_pass, recPass);
            }, {
                ioSynth.set(\buf_l, bufLs[recIdx], \buf_r, bufRs[recIdx]);
            });
        });
        this.addCommand(\buf_track, "i", { arg msg;
            opIdx = msg[1].asInteger.clip(0, 3);
        });
        // HEAD SYNC (the sixty-seventh change): track 1 to 4's read head goes
        // to its window's start. The script sends it on the clock, so the
        // loops of the locked tracks start together (doc/clock-plan.md).
        // \four_sync decides on the server (the seventy-first change).
        this.addCommand(\head_sync, "i", { arg msg;
            var i = (msg[1].asInteger - 1).clip(0, 3);
            var syn = (i == 0).if({ playSynth }, { extra[i - 1][\synth] });
            var mode = (i == 0).if({ modeV }, { extra[i - 1][\mode] ? 0 });
            var p = this.trackParams(i);
            syn.notNil.if({
                Synth.new(\four_sync, [
                    \play_bus, (i == 0).if({ playBus }, { extra[i - 1][\bus] }),
                    \from_bus, this.trackPhase(i), \sync_bus, syncBus.index + i,
                    \buf, bufLs[i],
                    \pos_start, p[\pos_start] ? 0, \pos_end, p[\pos_end] ? 1,
                    \duck, (mode == 4).binaryValue
                ], syn, \addAfter);
            });
        });

        // ---- tracks 2 to 4: `t<n>_<drone arg>` for each of its drone
        // values, `t<n>_<strip key>` for its strip, and `t<n>_mode`
        extra.do({ arg tr;
            var pre = "t" ++ tr[\n] ++ "_";
            tr[\params].keys.do({ arg k;
                var cmd = (pre ++ k).asSymbol;
                this.addCommand(cmd, "f", { arg msg;
                    var t = this.glideT(cmd);
                    tr[\params][k] = msg[1];
                    tr[\synth].notNil.if({ this.gset(tr[\synth], k, msg[1], t) });
                    ((k == \pos_start) or: { k == \pos_end }).if({
                        this.dubWindow(tr[\n] - 1, k, msg[1]);
                    });
                });
            });
            stripKeys.do({ arg k;
                var cmd = (pre ++ k).asSymbol;
                this.addCommand(cmd, "f", { arg msg;
                    this.laneSet(tr[\n] - 1, k, msg[1], this.glideT(cmd));
                });
            });
            this.addCommand((pre ++ "mode").asSymbol, "i", { arg msg;
                this.setModeN(tr, msg[1]);
            });
        });
        // ---- routing: send_<from>_<to>, each to the receiving track's synth
        // (track 1's is io) as its snd<from>
        (1..4).do({ arg from;
            (1..4).do({ arg to;
                (from != to).if({
                    var cmd = ("send_" ++ from ++ "_" ++ to).asSymbol;
                    this.addCommand(cmd, "f", { arg msg;
                        var key = ("snd" ++ from).asSymbol;
                        sendV[from - 1][to - 1] = msg[1];
                        this.gset(lanes[to - 1][\in], key, msg[1], this.glideT(cmd));
                        (to > 1).if({ this.updateStrip(extra[to - 2]) });
                    });
                });
            });
        });

        // ---- polyphony commands. note_on/one_shot gained a trailing AMP
        // (per-note level) — an ARITY change, NOT a new command, so the
        // fingerprint COUNT is unchanged. amp nil (an old 4-arg caller) -> the
        // voiceParams default, so it degrades cleanly both ways.
        this.addCommand(\note_on, "ifffff", { arg msg;
            this.noteOn(msg[1], msg[2], msg[3], msg[4], msg[5], msg[6]);
        });
        this.addCommand(\note_off, "i", { arg msg;
            this.noteOff(msg[1]);
        });
        this.addCommand(\note_one_shot, "fffff", { arg msg;
            this.noteOneShot(msg[1], msg[2], msg[3], msg[4], msg[5]);
        });
        // the beat repeat: the slice length in seconds, 0 = release. The 66th
        // command (the count moved from 65). Not `repeat`: that is a Lua
        // keyword, and `engine.repeat` would not even parse.
        this.addCommand(\beat_repeat, "f", { arg msg;
            this.updateRepeat(msg[1]);
        });
        this.addCommand(\voices, "i", { arg msg;
            maxVoices = msg[1].max(1);
        });
        this.addCommand(\voice_atk, "f", { arg msg;
            voiceParams[\voice_atk] = msg[1];
        });
        this.addCommand(\voice_rel, "f", { arg msg;
            voiceParams[\voice_rel] = msg[1];
        });

        // clear/load act on the SAME bufL/bufR the synths hold (Buffer:zero and
        // instance readChannel into the existing buffer) — no bufnum ever changes.
        this.addCommand(\clear, "", { arg msg;
            var idx = opIdx, gen;
            bufGen[idx] = bufGen[idx] + 1;
            gen = bufGen[idx];
            bufLs[idx].zero;
            bufRs[idx].zero;
            // ...and once more when a write that was running has faded out
            // (clearWait), unless a file, a take or another clear came to
            // this pair since
            SystemClock.sched(this.clearWait, {
                (bufGen[idx] == gen).if({
                    bufLs[idx].zero;
                    bufRs[idx].zero;
                });
                nil
            });
            // a clear must be SILENCE: the delay line and the reverb/shimmer
            // recirculation still ring with the erased material. their state
            // lives inside the spawn/free synths, so a free + respawn IS the
            // flush (the update methods re-spawn only if the mixes want them).
            // (at once, not after spaceWait: the count stops a free that waits)
            dlyGen = dlyGen + 1;
            revGen = revGen + 1;
            delaySynth.notNil.if({ delaySynth.free; delaySynth = nil });
            revSynth.notNil.if({ revSynth.free; revSynth = nil });
            // ...and a held repeat would go on playing the erased sound
            this.updateRepeat(0);
            // the zero runs in the background: an effect spawned before it lands
            // takes in the last of the take and echoes it (-54 dB on the device)
            fork {
                s.sync;
                this.updateDelay;
                this.updateReverb(revMixV);
            };
            "four: engine buffer cleared".postln;
        });

        // load any wav/aiff into the buffer. no SR conversion — a 44.1k file at
        // the 48k server plays ~9% fast (a varispeed).
        this.addCommand(\read_file, "s", { arg msg;
            var path = msg[1].asString;
            var sf = SoundFile.new;
            sf.openRead(path).if({
                var nch = sf.numChannels;
                var frames = sf.numFrames.min(s.sampleRate * bufSecs);
                var bl = bufLs[opIdx], br = bufRs[opIdx];
                sf.close;
                bufGen[opIdx] = bufGen[opIdx] + 1;   // a clear's second zero must not land on this
                bl.zero;
                br.zero;
                bl.readChannel(path, 0, frames, 0, false, [0]);
                // a mono file feeds BOTH sides from channel 0
                br.readChannel(path, 0, frames, 0, false, [(nch - 1).min(1)]);
                ("four: loaded " ++ path ++ " — " ++ frames ++ " frames, "
                    ++ nch ++ "ch").postln;
            }, {
                ("four: CANNOT READ " ++ path).postln;
            });
        });

        // persist the live take across PSET save/load: write bufL/bufR to a
        // private L/R pair (24-bit wav, async /b_write, bounded, core UGens).
        // numFrames bounds the write to the take from frame 0; n <= 0 = whole buffer.
        //
        // 24, not 16: the buffer itself is 32-bit float, and every save/load
        // round trip through a 16-bit file quantised the take again. This is
        // also what the EXPORT is built on, so a bounced wav carries the depth
        // too. The lua reader already decodes 16/24/32.
        // IF YOU CHANGE THIS FORMAT, change `ctx.TAKE_BYTES` in four.lua
        // to match. The export works out how big these files should be from
        // that number and waits for them to get there. Set too low, it stops
        // waiting early and hands on a file that is still being written.
        this.addCommand(\write_take, "si", { arg msg;
            var stem = msg[1].asString;
            var n = (msg.size > 2).if({ msg[2].asInteger }, { -1 });
            if(n <= 0, { n = -1 });
            bufLs[opIdx].write(stem ++ "_L.wav", "wav", "int24", n);
            bufRs[opIdx].write(stem ++ "_R.wav", "wav", "int24", n);
            ("four: wrote take " ++ stem ++ " ("
                ++ (n < 0).if("full", { n.asString ++ " frames" }) ++ ")").postln;
        });

        // read the pair back into the SAME bufL/bufR (readChannel into an
        // existing buffer — no bufnum change, nothing respawns). The Lua side
        // only calls this when the _L file exists; both halves are the same
        // length because write_take always writes them together.
        this.addCommand(\read_take, "s", { arg msg;
            var stem = msg[1].asString;
            var pathL = stem ++ "_L.wav";
            var pathR = stem ++ "_R.wav";
            var sf = SoundFile.new;
            sf.openRead(pathL).if({
                var frames = sf.numFrames.min(s.sampleRate * bufSecs);
                var bl = bufLs[opIdx], br = bufRs[opIdx];
                sf.close;
                bufGen[opIdx] = bufGen[opIdx] + 1;   // a clear's second zero must not land on this
                bl.zero;
                br.zero;
                bl.readChannel(pathL, 0, frames, 0, false, [0]);
                br.readChannel(pathR, 0, frames, 0, false, [0]);
                ("four: restored take " ++ stem ++ " — "
                    ++ frames ++ " frames").postln;
            }, {
                ("four: CANNOT READ take " ++ stem).postln;
            });
        });

        this.addPoll(\play_phase, {
            phaseBus.getSynchronous;
        });
        // the other tracks' read heads (polls are not commands)
        extra.do({ arg tr;
            this.addPoll(("play_phase" ++ tr[\n]).asSymbol, {
                tr[\phase].getSynchronous;
            });
        });
        4.do({ arg i;
            var bus = Bus.new(\control, meterBus.index + i, 1, meterBus.server);
            this.addPoll(("amp_t" ++ (i + 1)).asSymbol, { bus.getSynchronous });
        });
        this.addPoll(\rec_phase, {
            recPhaseBus.getSynchronous;
        });
        this.addPoll(\rec_amp, {
            recAmpBus.getSynchronous;
        });

        // start in GRAIN; the Lua defaults switch it to clean PLAY at load
        this.setMode(1);
    }

    free {
        activeVoices.notNil.if({ activeVoices.do({ arg v; v.notNil.if({ v.free }) }) });
        playSynth.notNil.if({ playSynth.free });
        extra.notNil.if({ extra.do({ arg tr;
            tr[\synth].notNil.if({ tr[\synth].free });
            tr[\strip].notNil.if({ tr[\strip].free });   // the lane group, with all in it
        }) });
        // (the counts stop a free that still waits from freeing a node twice)
        revGen = revGen + 1;
        dlyGen = dlyGen + 1;
        // (...and a clear's second zero from landing on a freed pair)
        bufGen.notNil.if({ bufGen = bufGen + 1 });
        // (...and a drone that still waits to leave is freed here, not later)
        leaveGen.notNil.if({ leaveGen = leaveGen + 1 });
        modeGen.notNil.if({ modeGen = modeGen + 1 });
        leaving.notNil.if({ leaving.do({ arg x; x.notNil.if({ x.free }) }) });
        revSynth.notNil.if({ revSynth.free });
        delaySynth.notNil.if({ delaySynth.free });
        eroSynth.notNil.if({ eroSynth.free });
        repSynth.notNil.if({ repSynth.free });
        dubSynth.notNil.if({ dubSynth.free });
        repBufs.notNil.if({ repBufs.do({ arg b; b.free }) });
        ioSynth.free;
        playGroup.free;
        bufLs.notNil.if({ bufLs.do({ arg b; b.free }) });
        bufRs.notNil.if({ bufRs.do({ arg b; b.free }) });
        grainEnv1.free;
        grainEnv2.free;
        playBus.free;
        revSendBus.free;
        revRetBus.free;
        dlySendBus.free;
        dlyRetBus.free;
        phaseBus.free;
        syncBus.free;
        meterSynth.notNil.if({ meterSynth.free });
        meterBus.free;
        extra.notNil.if({ extra.do({ arg tr; tr[\bus].free; tr[\phase].free }) });
        tRetBus.free;
        tDlyBus.free;
        tRevBus.free;
        outBuses.do({ arg b; b.free });
        lanes.notNil.if({ lanes.do({ arg l; l.notNil.if({ l[\sBus].free; l[\pBus].free }) }) });
        recPhaseBus.free;
        recAmpBus.free;
        dubBus.notNil.if({ dubBus.free });
    }
}
