// The classes of the FourStretch UGens (ugen/FourStretch.cpp). THIS FILE IS
// THE ONLY COPY: the binary in the Extensions folder ships with no class
// file, because a second copy of a class hangs every norns script on LOADING.
// Both are stereo and read two mono buffers at `pos`, a head in FRAMES.

FourPV : MultiOutUGen {
    *ar { arg bufL, bufR, pos, pitch = 1;
        ^this.multiNew('audio', bufL, bufR, pos, pitch)
    }
    init { arg ... theInputs;
        inputs = theInputs;
        ^this.initOutputs(2, rate)
    }
}

FourWarp : MultiOutUGen {
    *ar { arg bufL, bufR, pos, pitch = 1, windowFrames = 12000, overlaps = 4, rand = 0;
        ^this.multiNew('audio', bufL, bufR, pos, pitch, windowFrames, overlaps, rand)
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
