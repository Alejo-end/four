// Engine_Mangler.sc
// THE ONLY engine file for the `mangler` norns script.
//
// STAGE 4 — full instrument: mode-switched playback voice + FILTER/DELAY/
// REVERB on the wet path in the io synth (each FX with its own dry/wet).
// Architecture: one persistent io synth (input, record head, dry/wet mix,
// resample feedback, FX chain, output) + ONE playback synth at a time,
// spawned/freed by the `mode` command: OFF(0) / GRAIN(1) / WARP(2) / PV(3).
//   GRAIN — GrainBuf clouds (S1 behavior)
//   WARP  — Warp1 time-stretch: window scan speed (`scan`) is playback
//           speed, `pitch` (freqScale) is independent
//   PV    — phase-vocoder via FFT->PV_MagFreeze->IFFT (`pv_freeze` holds
//           the spectrum); scan drives the reader
// Playback synths write to play_bus + phase_out; io reads play_bus.
//
// HARD RULE: there must be exactly one `Engine_Mangler` class under dust/code.
// A duplicate makes every norns script hang forever on "LOADING".
//
// NB (learned in S0/S1): context.in_b is an ARRAY of two mono busses;
// out_b is one stereo bus. An error inside alloc means the doneCallback
// never fires and every load hangs on "loading" — errors land in maiden's
// SC tab. After editing this file: SYSTEM > RESTART, then check the
// command count in the load log (S4 fingerprint: count 30).

Engine_Mangler : CroneEngine {
	var <ioSynth, <playSynth;
	var <playGroup;
	var <bufL, <bufR;
	var <playBus;
	var <phaseBus, <recPhaseBus, <recAmpBus;
	var <playParams;
	var <ioKeys;

	*new { arg context, doneCallback;
		^super.new(context, doneCallback);
	}

	setMode { arg i;
		playSynth.notNil.if({ playSynth.free; playSynth = nil });
		(i > 0).if({
			var def = [\mangler_grain, \mangler_warp, \mangler_pv].at(i - 1);
			playSynth = Synth.new(def, [
				\buf_l, bufL, \buf_r, bufR,
				\play_bus, playBus, \phase_out, phaseBus,
			] ++ playParams.getPairs, playGroup);
		});
	}

	alloc {
		var s = context.server;
		var allKeys;

		bufL = Buffer.alloc(s, s.sampleRate * 60, 1);
		bufR = Buffer.alloc(s, s.sampleRate * 60, 1);
		playBus = Bus.audio(s, 2);
		phaseBus = Bus.control(s, 1);
		recPhaseBus = Bus.control(s, 1);
		recAmpBus = Bus.control(s, 1);

		// last-known playback values, handed to a freshly spawned mode synth
		playParams = Dictionary[
			\rec -> 0, \freeze -> 0,
			\pos_start -> 0.0, \pos_end -> 1.0, \scan -> 1.0, \pos_jitter -> 0.0,
			\size -> 0.1, \density -> 20, \pitch -> 1.0, \spread -> 0.5, \pan -> 0.0,
			\warp_window -> 0.25, \warp_overlaps -> 4, \warp_rand -> 0.0, \pv_freeze -> 0
		];
		ioKeys = [\level, \rec, \rec_level, \pre_level, \freeze,
			\dry_wet, \resample, \grain_level,
			\filt_type, \cutoff, \resonance,
			\delay_time, \delay_fb, \delay_mix,
			\rev_size, \rev_mix];

		// ---- playback defs: ONE runs at a time. all share the full arg set
		// (unused args are simply ignored) so spawn/set logic stays uniform.

		SynthDef(\mangler_grain, {
			arg buf_l, buf_r, play_bus, phase_out, rec = 0, freeze = 0,
				pos_start = 0, pos_end = 1, scan = 1, pos_jitter = 0,
				size = 0.1, density = 20, pitch = 1, spread = 0.5, pan = 0,
				warp_window = 0.25, warp_overlaps = 4, warp_rand = 0, pv_freeze = 0;
			var lo, hi, span, incr, phase, winPos, look;
			var trigL, trigR, posL, posR, panL, panR, sig;
			lo = pos_start.min(pos_end);
			hi = pos_start.max(pos_end);
			span = (hi - lo).max(0.001);
			incr = scan * SampleDur.ir / (BufDur.kr(buf_l) * span);
			phase = Phasor.ar(0, incr, 0, 1);
			winPos = lo + (phase * span);
			Out.kr(phase_out, A2K.kr(winPos));
			// while capturing, read just behind the write head: at/ahead of
			// it is silence on the first pass
			look = (0.25 / BufDur.kr(buf_l)) * rec * (1 - freeze);
			trigL = Impulse.kr(density);
			trigR = Impulse.kr(density);
			posL = winPos - look + TRand.kr((pos_jitter * span).neg, pos_jitter * span, trigL);
			posR = winPos - look + TRand.kr((pos_jitter * span).neg, pos_jitter * span, trigR);
			panL = (pan + TRand.kr(spread.neg, spread, trigL)).clip(-1, 1);
			panR = (pan + TRand.kr(spread.neg, spread, trigR)).clip(-1, 1);
			sig = GrainBuf.ar(2, trigL, size, buf_l, pitch, posL.wrap(0, 1), 2, panL)
				+ GrainBuf.ar(2, trigR, size, buf_r, pitch, posR.wrap(0, 1), 2, panR);
			Out.ar(play_bus, sig);
		}).add;

		SynthDef(\mangler_warp, {
			arg buf_l, buf_r, play_bus, phase_out, rec = 0, freeze = 0,
				pos_start = 0, pos_end = 1, scan = 1, pos_jitter = 0,
				size = 0.1, density = 20, pitch = 1, spread = 0.5, pan = 0,
				warp_window = 0.25, warp_overlaps = 4, warp_rand = 0, pv_freeze = 0;
			var lo, hi, span, incr, phase, winPos, ptr, l, r, sig;
			lo = pos_start.min(pos_end);
			hi = pos_start.max(pos_end);
			span = (hi - lo).max(0.001);
			// pointer speed = time-stretch; scan 0 freezes on a slice,
			// pitch (freqScale) stays independent
			incr = scan * SampleDur.ir / (BufDur.kr(buf_l) * span);
			phase = Phasor.ar(0, incr, 0, 1);
			winPos = lo + (phase * span);
			Out.kr(phase_out, A2K.kr(winPos));
			ptr = A2K.kr(winPos);
			l = Warp1.ar(1, buf_l, ptr, pitch, warp_window, -1, warp_overlaps, warp_rand, 2);
			r = Warp1.ar(1, buf_r, ptr, pitch, warp_window, -1, warp_overlaps, warp_rand, 2);
			sig = Balance2.ar(l, r, pan);
			Out.ar(play_bus, sig);
		}).add;

		SynthDef(\mangler_pv, {
			arg buf_l, buf_r, play_bus, phase_out, rec = 0, freeze = 0,
				pos_start = 0, pos_end = 1, scan = 1, pos_jitter = 0,
				size = 0.1, density = 20, pitch = 1, spread = 0.5, pan = 0,
				warp_window = 0.25, warp_overlaps = 4, warp_rand = 0, pv_freeze = 0;
			var lo, hi, span, incr, phase, winPos, sigL, sigR, chainL, chainR, l, r, sig;
			lo = pos_start.min(pos_end);
			hi = pos_start.max(pos_end);
			span = (hi - lo).max(0.001);
			incr = scan * SampleDur.ir / (BufDur.kr(buf_l) * span);
			phase = Phasor.ar(0, incr, 0, 1);
			winPos = lo + (phase * span);
			Out.kr(phase_out, A2K.kr(winPos));
			sigL = BufRd.ar(1, buf_l, winPos * BufFrames.kr(buf_l), 1, 2);
			sigR = BufRd.ar(1, buf_r, winPos * BufFrames.kr(buf_r), 1, 2);
			chainL = FFT(LocalBuf(2048), sigL);
			chainR = FFT(LocalBuf(2048), sigR);
			chainL = PV_MagFreeze(chainL, pv_freeze);
			chainR = PV_MagFreeze(chainR, pv_freeze);
			l = IFFT(chainL);
			r = IFFT(chainR);
			sig = Balance2.ar(l, r, pan);
			Out.ar(play_bus, sig);
		}).add;

		// ---- io: input, record head (with resample feedback), dry/wet, out

		SynthDef(\mangler_io, {
			arg in1, in2, out, buf_l, buf_r, play_bus, rec_phase_out, rec_amp_out,
				level = 1.0, rec = 0, rec_level = 1.0, pre_level = 0.0,
				freeze = 0, dry_wet = 0.5, resample = 0.0, grain_level = 1.0,
				filt_type = 0, cutoff = 20000, resonance = 0,
				delay_time = 0.3, delay_fb = 0.3, delay_mix = 0.0,
				rev_size = 0.5, rev_mix = 0.0;
			var inL, inR, wet, dry, sig, recRun, recPhase, recL, recR;
			var cf, rq, lp, hp, bp, isLp, isHp, isBp, fbIn, dIn, dOut, rv;
			inL = In.ar(in1, 1);
			inR = In.ar(in2, 1);
			// 1.5x makeup: grain envelopes lose energy vs the source
			wet = In.ar(play_bus, 2) * grain_level * 1.5;

			// FILTER: lp/hp/bp on the wet path; arithmetic select keeps
			// multichannel expansion simple, and filters are cheap
			cf = cutoff.clip(20, 20000).lag(0.05);
			rq = (1 - (resonance * 0.85)).max(0.1);
			lp = RLPF.ar(wet, cf, rq);
			hp = RHPF.ar(wet, cf, rq);
			bp = BPF.ar(wet, cf, rq) * (1 + resonance);
			isLp = (filt_type < 0.5);
			isHp = (filt_type > 0.5) * (filt_type < 1.5);
			isBp = (filt_type > 1.5);
			wet = (lp * isLp) + (hp * isHp) + (bp * isBp);

			// DELAY: feedback loop, soft-clipped so it builds without blowing
			// up; own dry/wet
			fbIn = LocalIn.ar(2);
			dIn = wet + (fbIn * delay_fb);
			dOut = DelayC.ar(dIn, 1.0, delay_time.clip(0.01, 1.0).lag(0.2));
			LocalOut.ar(dOut.softclip);
			wet = (wet * (1 - delay_mix)) + (dOut * delay_mix);

			// REVERB: FreeVerb per channel (cheap), own dry/wet
			rv = [
				FreeVerb.ar(wet[0], 1.0, rev_size, 0.5),
				FreeVerb.ar(wet[1], 1.0, rev_size, 0.5)
			];
			wet = (wet * (1 - rev_mix)) + (rv * rev_mix);

			dry = [inL, inR];
			// equal-power crossfade: linear lost 6dB at the center
			sig = (dry * (1 - dry_wet).sqrt) + (wet * dry_wet.sqrt);
			sig = sig * Lag.kr(level, 0.05);
			recRun = rec * (1 - freeze);
			recPhase = Phasor.ar(0, recRun * SampleDur.ir / BufDur.kr(buf_l), 0, 1);
			Out.kr(rec_phase_out, A2K.kr(recPhase));
			recL = (inL * (1 - resample)) + (sig[0] * resample);
			recR = (inR * (1 - resample)) + (sig[1] * resample);
			RecordBuf.ar(recL, buf_l, 0, rec_level, pre_level, recRun, 1);
			RecordBuf.ar(recR, buf_r, 0, rec_level, pre_level, recRun, 1);
			Out.kr(rec_amp_out,
				Amplitude.kr(recL.abs.max(recR.abs) * rec_level, 0.01, 0.1));
			Out.ar(out, sig);
		}).add;

		s.sync;

		// playback group first, io after it, so io reads play_bus in-block
		playGroup = Group.new(context.xg);
		ioSynth = Synth.new(\mangler_io, [
			\in1, context.in_b[0].index,
			\in2, context.in_b[1].index,
			\out, context.out_b.index,
			\buf_l, bufL,
			\buf_r, bufR,
			\play_bus, playBus,
			\rec_phase_out, recPhaseBus,
			\rec_amp_out, recAmpBus,
		], playGroup, \addAfter);

		// every float control as one command; rec/freeze fan out to both synths
		allKeys = (ioKeys ++ playParams.keys.asArray).asSet;
		allKeys.do({ arg name;
			this.addCommand(name, "f", { arg msg;
				var v = msg[1];
				ioKeys.includes(name).if({ ioSynth.set(name, v) });
				playParams.includesKey(name).if({
					playParams[name] = v;
					playSynth.notNil.if({ playSynth.set(name, v) });
				});
			});
		});

		this.addCommand(\mode, "i", { arg msg;
			this.setMode(msg[1]);
		});

		this.addPoll(\play_phase, {
			phaseBus.getSynchronous;
		});
		this.addPoll(\rec_phase, {
			recPhaseBus.getSynchronous;
		});
		this.addPoll(\rec_amp, {
			recAmpBus.getSynchronous;
		});

		// start in GRAIN so the instrument behaves like S1 out of the box
		this.setMode(1);
	}

	free {
		playSynth.notNil.if({ playSynth.free });
		ioSynth.free;
		playGroup.free;
		bufL.free;
		bufR.free;
		playBus.free;
		phaseBus.free;
		recPhaseBus.free;
		recAmpBus.free;
	}
}
