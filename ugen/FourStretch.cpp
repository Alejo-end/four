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

// FourDelay.ar(in, delay, feedback, damp, maxdelay): see DelayFb in four_core.h.
// delay is in seconds (control rate is ramped over the block), damp in Hz.
struct FourDelay : public Unit { four::DelayFb core; float* mem; float lastD; };
static void FourDelay_next(FourDelay* unit, int inNumSamples) {
    const float* in = IN(0); float* out = OUT(0);
    const float sr = (float)SAMPLERATE;
    const float fb = sc_clip(IN0(2), -0.98f, 0.98f);
    const float k = 1.f - std::exp(-6.2831853f * sc_clip(IN0(3), 20.f, 20000.f) / sr);
    if (INRATE(1) == calc_FullRate) {
        const float* d = IN(1);
        for (int i = 0; i < inNumSamples; i++) out[i] = unit->core.tick(in[i], d[i] * sr, fb, k);
    } else {
        float d = unit->lastD; const float target = IN0(1) * sr;
        const float step = (target - d) / (float)inNumSamples;
        for (int i = 0; i < inNumSamples; i++) { d += step; out[i] = unit->core.tick(in[i], d, fb, k); }
        unit->lastD = target;
    }
}
static void FourDelay_Ctor(FourDelay* unit) {
    int need = (int)(sc_max(IN0(4), 0.001f) * SAMPLERATE) + 8, size = 64;
    while (size < need) size <<= 1;
    unit->mem = (float*)RTAlloc(unit->mWorld, size * sizeof(float));
    if (!unit->mem) { SETCALC(ft->fClearUnitOutputs); ClearUnitOutputs(unit, 1); return; }
    unit->core.init(unit->mem, size);
    unit->lastD = IN0(1) * (float)SAMPLERATE;
    SETCALC(FourDelay_next);
    OUT0(0) = 0.f;
}
static void FourDelay_Dtor(FourDelay* unit) {
    if (unit->mem) RTFree(unit->mWorld, unit->mem);
}

// FourGrain.ar(bufL, bufR, trig, dur, rate, pos, panL, panR, envbuf, maxGrains)
// See Grains in four_core.h. Every input from trig to panR is read at the
// sample of its trigger, whatever rate it runs at.
struct FourGrain : public Unit { four::Grains* core; };
static void FourGrain_next(FourGrain* unit, int inNumSamples) {
    float* outL = OUT(0); float* outR = OUT(1);
    four::Buf bl = bufOf(unit, IN0(0)), br = bufOf(unit, IN0(1));
    float tmp[6][64];
    const float* win = nullptr; int winFrames = 0;
    if (IN0(8) >= 0.f) {
        four::Buf w = bufOf(unit, IN0(8));
        if (w.data && w.frames > 1) { win = w.data; winFrames = w.frames; }
    }
    double scale = 1.0;
    {
        uint32 bn = (uint32)sc_max(IN0(0), 0.f);
        if (bn < unit->mWorld->mNumSndBufs) {
            SndBuf* b = unit->mWorld->mSndBufs + bn;
            if (b->samplerate > 0) scale = b->samplerate / SAMPLERATE;
        }
    }
    for (int done = 0; done < inNumSamples; done += 64) {
        int n = sc_min(64, inNumSamples - done);
        const float* in[6];
        for (int k = 0; k < 6; k++)
            in[k] = INRATE(2 + k) == calc_FullRate ? IN(2 + k) + done : headOf(unit, 2 + k, tmp[k], n);
        unit->core->process(outL + done, outR + done, n, in[0], in[1], in[2], in[3], in[4], in[5],
                            bl, br, win, winFrames, (int)IN0(9), SAMPLERATE, scale);
    }
}
static void FourGrain_Ctor(FourGrain* unit) {
    unit->core = (four::Grains*)RTAlloc(unit->mWorld, sizeof(four::Grains));
    if (!unit->core) { SETCALC(ft->fClearUnitOutputs); ClearUnitOutputs(unit, 1); return; }
    unit->core->init();
    SETCALC(FourGrain_next);
    OUT0(0) = 0.f; OUT0(1) = 0.f;
}
static void FourGrain_Dtor(FourGrain* unit) {
    if (unit->core) RTFree(unit->mWorld, unit->core);
}

// FourRoom.ar(inL, inR, decay, colour, size): see Room in four_core.h. The wet
// sound only. decay is T60 in seconds, colour the share of it that the top
// keeps (1 bright, 0.15 dark), size the base time of the diffusion in seconds.
// size is read when the synth starts.
struct FourRoom : public Unit { four::Room* core; float* mem; float lastDecay, lastColour; };
static void FourRoom_next(FourRoom* unit, int inNumSamples) {
    const float* inL = IN(0); const float* inR = IN(1);
    float* outL = OUT(0); float* outR = OUT(1);
    const float decay = sc_clip(IN0(2), 0.05f, 60.f), colour = sc_clip(IN0(3), 0.05f, 1.f);
    if (decay != unit->lastDecay || colour != unit->lastColour) {
        unit->core->setDecay(decay, colour);
        unit->lastDecay = decay; unit->lastColour = colour;
    }
    for (int i = 0; i < inNumSamples; i++) unit->core->tick(inL[i], inR[i], outL[i], outR[i]);
}
static void FourRoom_Ctor(FourRoom* unit) {
    unit->core = (four::Room*)RTAlloc(unit->mWorld, sizeof(four::Room));
    unit->mem = (float*)RTAlloc(unit->mWorld, four::Room::need() * sizeof(float));
    if (!unit->core || !unit->mem) {
        if (unit->core) RTFree(unit->mWorld, unit->core);
        if (unit->mem) RTFree(unit->mWorld, unit->mem);
        unit->core = nullptr; unit->mem = nullptr;
        SETCALC(ft->fClearUnitOutputs); ClearUnitOutputs(unit, 1);
        Print("FourRoom: no memory for the room\n");
        return;
    }
    unit->core->init(unit->mem, SAMPLERATE, sc_clip(IN0(4), 0.002f, 0.0105f));
    unit->lastDecay = -1.f; unit->lastColour = -1.f;
    SETCALC(FourRoom_next);
    OUT0(0) = 0.f; OUT0(1) = 0.f;
}
static void FourRoom_Dtor(FourRoom* unit) {
    if (unit->core) RTFree(unit->mWorld, unit->core);
    if (unit->mem) RTFree(unit->mWorld, unit->mem);
}

PluginLoad(FourStretch) {
    ft = inTable;
    four::tables();     // built here, off the audio thread
#ifdef FOUR_FFTW
    four::plans();
#endif
    DefineDtorCantAliasUnit(FourPV);
    DefineDtorCantAliasUnit(FourWarp);
    // (CantAlias: an output buffer is never one of the inputs. The cloud clears
    // its outputs before it reads its inputs, which wiped an input that shared one.)
    DefineSimpleCantAliasUnit(FourRead);
    DefineSimpleUnit(FourTanh);
    DefineDtorCantAliasUnit(FourDelay);
    DefineDtorCantAliasUnit(FourGrain);
    DefineDtorCantAliasUnit(FourRoom);
}
