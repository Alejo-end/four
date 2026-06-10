// Engine_Mangler.sc
// THE ONLY engine file for the `mangler` norns script.
//
// STAGE 0 — loadable skeleton. This engine does NOTHING yet but pass audio
// through, on purpose: it proves the script loads with no LOADING hang and
// that the SC command channel works, before any DSP is written. The real
// signal chain (granular / time-stretch / filter / delay / reverb) is brought
// up one stage at a time on hardware — see SPEC/spec.md.
//
// HARD RULE: there must be exactly one `Engine_Mangler` class under dust/code.
// A duplicate makes every norns script hang forever on "LOADING". Deploy this
// folder with `rsync --delete`.

Engine_Mangler : CroneEngine {
	var <synth;

	*new { arg context, doneCallback;
		^super.new(context, doneCallback);
	}

	alloc {
		// trivial stereo pass-through: ADC busses -> level -> crone output bus.
		// NB: context.in_b is an ARRAY of two mono busses (in_b[0], in_b[1]);
		// out_b is one stereo bus. Calling .index on the array kills alloc,
		// the doneCallback never fires, and the script hangs on "loading".
		SynthDef(\mangler_io, {
			arg in1, in2, out, level = 1.0, lag = 0.05;
			var sig;
			sig = [In.ar(in1, 1), In.ar(in2, 1)];
			sig = sig * Lag.kr(level, lag);
			Out.ar(out, sig);
		}).add;

		context.server.sync;

		synth = Synth.new(\mangler_io, [
			\in1, context.in_b[0].index,
			\in2, context.in_b[1].index,
			\out, context.out_b.index,
		], context.xg);

		// one no-op command, proves the lua -> engine channel before any DSP.
		this.addCommand("noop", "f", { arg msg; });
	}

	free {
		synth.free;
	}
}