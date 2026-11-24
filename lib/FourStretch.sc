// The classes of the FourStretch UGens (ugen/FourStretch.cpp). THIS FILE IS
// THE ONLY COPY: the binary in the Extensions folder ships with no class
// file, because a second copy of a class hangs every norns script on LOADING.
// Both are stereo and read two mono buffers at `pos`, a head in FRAMES. `lo`
// and `span` are the loop in frames: their reads wrap in it (0: no loop).

FourPV : MultiOutUGen {
    *ar { arg bufL, bufR, pos, pitch = 1, lo = 0, span = 0;
        ^this.multiNew('audio', bufL, bufR, pos, pitch, lo, span)
    }
    init { arg ... theInputs;
        inputs = theInputs;
        ^this.initOutputs(2, rate)
    }
}

FourWarp : MultiOutUGen {
    *ar { arg bufL, bufR, pos, pitch = 1, windowFrames = 12000, overlaps = 4, rand = 0,
            lo = 0, span = 0;
        ^this.multiNew('audio', bufL, bufR, pos, pitch, windowFrames, overlaps, rand, lo, span)
    }
    init { arg ... theInputs;
        inputs = theInputs;
        ^this.initOutputs(2, rate)
    }
}

// PLAY's read: pos is the whole frame and frac the place after it (both at
// audio rate, from winRead), ratio is how many frames the head moves a sample.
FourRead : MultiOutUGen {
    *ar { arg bufL, bufR, pos, frac, ratio = 1;
        ^this.multiNew('audio', bufL, bufR, pos, frac, ratio)
    }
    init { arg ... theInputs;
        inputs = theInputs;
        ^this.initOutputs(2, rate)
    }
}

// tanh, the same curve as `.tanh` to about 2e-7, at a tenth of the cost on
// the norns. An array of channels gives an array.
FourTanh : UGen {
    *ar { arg in;
        ^this.multiNew('audio', in)
    }
}

// A delay with a low-pass and a soft clip in its feedback path, for FLANGE
// and ECHO. delay is in seconds, damp in Hz, maxdelay is fixed at the start.
FourDelay : UGen {
    *ar { arg in, delay = 0.005, feedback = 0, damp = 6000, maxdelay = 0.05;
        ^this.multiNew('audio', in, delay, feedback, damp, maxdelay)
    }
}

// GRAIN's cloud: a pair of stock GrainBuf (one for each buffer, each panned)
// as one UGen, with the same laws. envbuf -1 is the Hann window.
FourGrain : MultiOutUGen {
    *ar { arg bufL, bufR, trig, dur = 0.1, rate = 1, pos = 0, panL = -1, panR = 1,
            envbuf = -1, maxGrains = 64;
        ^this.multiNew('audio', bufL, bufR, trig, dur, rate, pos, panL, panR, envbuf, maxGrains)
    }
    init { arg ... theInputs;
        inputs = theInputs;
        ^this.initOutputs(2, rate)
    }
}

// THE ROOM: the reverb. Four unitary diffusion steps and eight late lines
// (doc/space-plan.md). The wet sound only. decay is T60 in seconds, colour is
// the share of it that the top keeps (1 bright, 0.15 dark), size is the base
// time of the diffusion in seconds (0.002 to 0.0105), read at the start.
FourRoom : MultiOutUGen {
    *ar { arg inL, inR, decay = 2, colour = 0.6, size = 0.005;
        ^this.multiNew('audio', inL, inR, decay, colour, size)
    }
    init { arg ... theInputs;
        inputs = theInputs;
        ^this.initOutputs(2, rate)
    }
}

// THE BUCKET BRIGADE: the delay (doc/space-plan.md, section 4). One channel,
// with its own feedback loop. time is in seconds, tone is the filters' corner
// as a share of the clock (0.2 to 0.45), age is 0 (clean) to 1 (noise and the
// compander of an old unit).
FourBBD : UGen {
    *ar { arg in, time = 0.3, feedback = 0.3, tone = 0.35, age = 0;
        ^this.multiNew('audio', in, time, feedback, tone, age)
    }
}

// THE CLOUD: Mutable Instruments Clouds (ugen/vendor/), with the inputs of
// the MiClouds UGen of mi-UGens in the same order, so a def calls either one
// with the same arguments. Its own name: a second MiClouds class next to an
// installed mi-UGens would hang every norns script on LOADING.
FourCloud : MultiOutUGen {
    *ar { arg inputArray, pit = 0, pos = 0.5, size = 0.25, dens = 0.4, tex = 0.5, drywet = 0.5,
            in_gain = 1, spread = 0.5, rvb = 0, fb = 0, freeze = 0, mode = 0, lofi = 0, trig = 0,
            mul = 1.0, add = 0.0;
        ^this.multiNewList(['audio', pit, pos, size, dens, tex, drywet, in_gain, spread, rvb, fb,
            freeze, mode, lofi, trig] ++ inputArray.asArray).madd(mul, add)
    }
    checkInputs {
        (inputs.at(14).rate != 'audio').if({
            ^("input is not audio rate: " + inputs.at(14) + inputs.at(14).rate)
        });
        ^this.checkValidInputs
    }
    init { arg ... theInputs;
        inputs = theInputs;
        ^this.initOutputs(2, rate)
    }
}
