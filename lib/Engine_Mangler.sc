// Engine_Mangler.sc
// THE ONLY engine file for the `mangler` norns script.
//
// STAGE 1 — RECORD + GRANULAR + WINDOW.
// RecordBuf captures the live stereo ADC into two ~60s mono ring buffers
// (GrainBuf reads mono buffers only); GrainBuf granulates a windowed slice
// [pos_start..pos_end]; a Phasor scans the window at `scan` speed and its
// position feeds both the grain readers and the play_phase poll.
// Filter / delay / reverb / time-stretch modes come in later stages.
//
// HARD RULE: there must be exactly one `Engine_Mangler` class under dust/code.
// A duplicate makes every norns script hang forever on "LOADING". Deploy this
// folder with `rsync --delete`.
//
// NB (learned in S0): context.in_b is an ARRAY of two mono busses
// (in_b[0], in_b[1]); out_b is one stereo bus. An error inside alloc means
// the doneCallback never fires and every load hangs on "loading" — errors
// land in maiden's SC tab, not the matron tab.

Engine_Mangler : CroneEngine {
	var <synth;
	var <bufL, <bufR;
	var <phaseBus, <recPhaseBus, <recAmpBus;

	*new { arg context, doneCallback;
		^super.new(context, doneCallback);
	}

	alloc {
		var s = context.server;

		bufL = Buffer.alloc(s, s.sampleRate * 60, 1);
		bufR = Buffer.alloc(s, s.sampleRate * 60, 1);
		phaseBus = Bus.control(s, 1);
		recPhaseBus = Bus.control(s, 1);
		recAmpBus = Bus.control(s, 1);

		SynthDef(\mangler_s1, {
			arg in1, in2, out, buf_l, buf_r, phase_out, rec_phase_out, rec_amp_out,
				level = 1.0, rec = 0, rec_level = 1.0, pre_level = 0.0,
				freeze = 0, dry_wet = 0.5, resample = 0.0,
				pos_start = 0.0, pos_end = 1.0, scan = 1.0, pos_jitter = 0.0,
				size = 0.1, density = 20, pitch = 1.0, spread = 0.5,
				pan = 0.0, grain_level = 1.0;

			var inL, inR, recRun, recL, recR, recPhase, look;
			var lo, hi, span, incr, phase, winPos;
			var trigL, trigR, posL, posR, panL, panR, grains, dry, sig;

			inL = In.ar(in1, 1);
			inR = In.ar(in2, 1);

			// the write head must run BEFORE the readers conceptually: grains
			// read ~250ms behind it so freshly captured audio is immediately
			// available (reading at/ahead of the write point = silence on the
			// first pass through the buffer)
			recRun = rec * (1 - freeze);
			recPhase = Phasor.ar(0, recRun * SampleDur.ir / BufDur.kr(buf_l), 0, 1);
			Out.kr(rec_phase_out, A2K.kr(recPhase));
			look = (0.25 / BufDur.kr(buf_l)) * recRun;

			// playback window [lo..hi] in normalized buffer position;
			// phase sweeps it at `scan` x natural speed (negative = reverse)
			lo = pos_start.min(pos_end);
			hi = pos_start.max(pos_end);
			span = (hi - lo).max(0.001);
			incr = scan * SampleDur.ir / (BufDur.kr(buf_l) * span);
			phase = Phasor.ar(0, incr, 0, 1);
			winPos = lo + (phase * span);
			Out.kr(phase_out, A2K.kr(winPos));

			// grain clouds, one per channel, sharing the window position;
			// per-grain jitter and pan spread are randomized at trigger time
			trigL = Impulse.kr(density);
			trigR = Impulse.kr(density);
			posL = winPos - look + TRand.kr((pos_jitter * span).neg, pos_jitter * span, trigL);
			posR = winPos - look + TRand.kr((pos_jitter * span).neg, pos_jitter * span, trigR);
			panL = (pan + TRand.kr(spread.neg, spread, trigL)).clip(-1, 1);
			panR = (pan + TRand.kr(spread.neg, spread, trigR)).clip(-1, 1);

			grains = GrainBuf.ar(2, trigL, size, buf_l, pitch, posL.wrap(0, 1), 2, panL)
				+ GrainBuf.ar(2, trigR, size, buf_r, pitch, posR.wrap(0, 1), 2, panR);

			dry = [inL, inR];
			sig = (dry * (1 - dry_wet)) + (grains * grain_level * dry_wet);
			sig = sig * Lag.kr(level, 0.05);

			// record head: continuous loop capture (recRun computed above);
			// freeze halts it while playback keeps reading. `resample`
			// crossfades the record source from the live ADC to the engine's
			// own output, so the instrument can re-capture and re-mangle itself.
			recL = (inL * (1 - resample)) + (sig[0] * resample);
			recR = (inR * (1 - resample)) + (sig[1] * resample);
			RecordBuf.ar(recL, buf_l, 0, rec_level, pre_level, recRun, 1);
			RecordBuf.ar(recR, buf_r, 0, rec_level, pre_level, recRun, 1);

			// amplitude of what is actually being written (drives the
			// waveform display; correct under resample/rec_level too)
			Out.kr(rec_amp_out,
				Amplitude.kr(recL.abs.max(recR.abs) * rec_level, 0.01, 0.1));

			Out.ar(out, sig);
		}).add;

		s.sync;

		synth = Synth.new(\mangler_s1, [
			\in1, context.in_b[0].index,
			\in2, context.in_b[1].index,
			\out, context.out_b.index,
			\buf_l, bufL,
			\buf_r, bufR,
			\phase_out, phaseBus,
			\rec_phase_out, recPhaseBus,
			\rec_amp_out, recAmpBus,
		], context.xg);

		// one float command per synth arg; lua param actions call these by id
		[
			\level, \rec, \rec_level, \pre_level, \freeze, \dry_wet, \resample,
			\pos_start, \pos_end, \scan, \pos_jitter,
			\size, \density, \pitch, \spread, \pan, \grain_level,
		].do({ arg name;
			this.addCommand(name, "f", { arg msg;
				synth.set(name, msg[1]);
			});
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
	}

	free {
		synth.free;
		bufL.free;
		bufR.free;
		phaseBus.free;
		recPhaseBus.free;
		recAmpBus.free;
	}
}
