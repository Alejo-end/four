// The Clouds core in one piece: Mutable Instruments Clouds and the parts of
// stmlib it needs, exactly as mi-UGens builds its MiClouds (vendor/README.md
// says from where). Plain C++ with no SuperCollider in it, so that
// test_core.cpp can run it too. FourStretch.cpp wraps it as FourCloud.
//
// The vendored files include each other from their own root, so every build
// that includes this file needs -I<ugen>/vendor/eurorack.
#ifndef FOUR_CLOUD_H
#define FOUR_CLOUD_H

// stmlib: the portable C++ instead of the module's ARM assembly. MiClouds is
// built with the same switch.
#ifndef TEST
#define TEST
#endif

#include "clouds/dsp/granular_processor.h"

#include "clouds/dsp/granular_processor.cc"
#include "clouds/dsp/correlator.cc"
#include "clouds/dsp/mu_law.cc"
#include "clouds/dsp/pvoc/frame_transformation.cc"
#include "clouds/dsp/pvoc/phase_vocoder.cc"
#include "clouds/dsp/pvoc/stft.cc"
#include "clouds/resources.cc"
#include "stmlib/dsp/atan.cc"
#include "stmlib/dsp/units.cc"
#include "stmlib/utils/random.cc"

#endif
