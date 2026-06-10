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
		// trivial stereo pass-through: ADC bus -> level -> crone output bus.
		SynthDef(\mangler_io, {
			arg in, out, level = 1.0, lag = 0.05;
			var sig;
			sig = In.ar(in, 2);
			sig = sig * Lag.kr(level, lag);
			Out.ar(out, sig);
		}).add;

		context.server.sync;

		synth = Synth.new(\mangler_io, [
			\in, context.in_b.index,
			\out, context.out_b.index,
		], context.xg);

		// one no-op command, proves the lua -> engine channel before any DSP.
		this.addCommand("noop", "f", { arg msg; });
	}

	free {
		synth.free;
	}
}
