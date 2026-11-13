// FourStretch: the SuperCollider face of four_core.h. Two UGens, both stereo,
// both read two mono buffers at a head given in frames:
//   FourPV.ar(bufL, bufR, pos, pitch)
//   FourWarp.ar(bufL, bufR, pos, pitch, windowFrames, overlaps, rand)
//   FourRead.ar(bufL, bufR, pos, frac, ratio)   PLAY's read, a windowed sinc
//   FourTanh.ar(in)                             tanh, about ten times as fast
// The class file is lib/FourStretch.sc. The binary goes in the SuperCollider
// user Extensions folder, in FourStretch/ (see ugen/README.md).
#include "SC_PlugIn.h"
#include "four_core.h"
#include <new>

static InterfaceTable* ft;

struct FourPV : public Unit { four::PV* core; };
struct FourWarp : public Unit { four::Warp* core; };

static inline four::Buf bufOf(Unit* unit, float fbufnum) {
    World* world = unit->mWorld;
    if (!(fbufnum >= 0)) return four::Buf { nullptr, 0 };
    uint32 bufnum = (uint32)fbufnum;
    if (bufnum >= world->mNumSndBufs) return four::Buf { nullptr, 0 };
    SndBuf* b = world->mSndBufs + bufnum;
    if (!b->data || b->channels != 1) return four::Buf { nullptr, 0 };
    return four::Buf { b->data, (int)b->frames };
}

// the head as one value per sample, whatever rate the input runs at
static inline const float* headOf(Unit* unit, int input, float* tmp, int n) {
    if (INRATE(input) == calc_FullRate) return IN(input);
    float v = IN0(input);
    for (int i = 0; i < n; i++) tmp[i] = v;
    return tmp;
}

static void FourPV_next(FourPV* unit, int inNumSamples) {
    float* outL = OUT(0); float* outR = OUT(1);
    four::Buf bl = bufOf(unit, IN0(0)), br = bufOf(unit, IN0(1));
    float tmp[64];
    for (int done = 0; done < inNumSamples; done += 64) {
        int n = sc_min(64, inNumSamples - done);
        const float* pos = INRATE(2) == calc_FullRate ? IN(2) + done : headOf(unit, 2, tmp, n);
        unit->core->process(outL + done, outR + done, n, pos, IN0(3), bl, br);
    }
}

static void FourPV_Ctor(FourPV* unit) {
    unit->core = (four::PV*)RTAlloc(unit->mWorld, sizeof(four::PV));
    if (!unit->core) {
        SETCALC(ft->fClearUnitOutputs);
        ClearUnitOutputs(unit, 1);
        Print("FourPV: no real-time memory\n");
        return;
    }
    unit->core->init();
    SETCALC(FourPV_next);
    OUT0(0) = 0.f; OUT0(1) = 0.f;
}

static void FourPV_Dtor(FourPV* unit) { if (unit->core) RTFree(unit->mWorld, unit->core); }

static void FourWarp_next(FourWarp* unit, int inNumSamples) {
    float* outL = OUT(0); float* outR = OUT(1);
    four::Buf bl = bufOf(unit, IN0(0)), br = bufOf(unit, IN0(1));
    float tmp[64];
    for (int done = 0; done < inNumSamples; done += 64) {
        int n = sc_min(64, inNumSamples - done);
        const float* pos = INRATE(2) == calc_FullRate ? IN(2) + done : headOf(unit, 2, tmp, n);
        unit->core->process(outL + done, outR + done, n, pos, IN0(3), IN0(4), IN0(5), IN0(6), bl, br);
    }
}

static void FourWarp_Ctor(FourWarp* unit) {
    unit->core = (four::Warp*)RTAlloc(unit->mWorld, sizeof(four::Warp));
    if (!unit->core) {
        SETCALC(ft->fClearUnitOutputs);
        ClearUnitOutputs(unit, 1);
        Print("FourWarp: no real-time memory\n");
        return;
    }
    unit->core->init();
    SETCALC(FourWarp_next);
    OUT0(0) = 0.f; OUT0(1) = 0.f;
}

static void FourWarp_Dtor(FourWarp* unit) { if (unit->core) RTFree(unit->mWorld, unit->core); }

struct FourRead : public Unit { four::Kern kn; };

static void FourRead_next(FourRead* unit, int inNumSamples) {
    float* outL = OUT(0); float* outR = OUT(1);
    four::Buf bl = bufOf(unit, IN0(0)), br = bufOf(unit, IN0(1));
    const float* pos = IN(2); const float* frac = IN(3);
    double ratio = IN0(4);
    for (int i = 0; i < inNumSamples; i++) {
        float f = frac[i];
        if (!(f >= 0.f)) f = 0.f;
        if (f >= 1.f) f = 0.999999f;
        four::sincAt(unit->kn, bl, br, (four::pos_t)lrintf(pos[i]), f, ratio, outL[i], outR[i]);
    }
}

static void FourRead_Ctor(FourRead* unit) {
    if (INRATE(2) != calc_FullRate || INRATE(3) != calc_FullRate) {
        SETCALC(ft->fClearUnitOutputs);
        ClearUnitOutputs(unit, 1);
        Print("FourRead: pos and frac must run at audio rate\n");
        return;
    }
    unit->kn.init();
    SETCALC(FourRead_next);
    OUT0(0) = 0.f; OUT0(1) = 0.f;
}

// FourTanh.ar(in): tanh, one channel. See tanhBlock in four_core.h.
struct FourTanh : public Unit {};
static void FourTanh_next(FourTanh* unit, int inNumSamples) {
    four::tanhBlock(IN(0), OUT(0), inNumSamples);
}
static void FourTanh_Ctor(FourTanh* unit) {
    SETCALC(FourTanh_next);
    OUT0(0) = std::tanh(IN0(0));
}

PluginLoad(FourStretch) {
    ft = inTable;
    four::tables();     // built here, off the audio thread
#ifdef FOUR_FFTW
    four::plans();
#endif
    DefineDtorUnit(FourPV);
    DefineDtorUnit(FourWarp);
    DefineSimpleUnit(FourRead);
    DefineSimpleUnit(FourTanh);
}
