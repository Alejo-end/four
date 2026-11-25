// FourStretch: the SuperCollider face of four_core.h. Two UGens, both stereo,
// both read two mono buffers at a head given in frames:
//   FourPV.ar(bufL, bufR, pos, pitch, lo, span)
//   FourWarp.ar(bufL, bufR, pos, pitch, windowFrames, overlaps, rand, lo, span)
// lo and span are the loop, in frames (0: the whole buffer). An older binary does
// not read these two, and a graph without them plays as it did.
//   FourRead.ar(bufL, bufR, pos, frac, ratio)   PLAY's read, a windowed sinc
//   FourTanh.ar(in)                             tanh, about ten times as fast
//   FourCloud.ar([inL, inR], pit, pos, ...)     Mutable Instruments Clouds
// The class file is lib/FourStretch.sc. The binary goes in the SuperCollider
// user Extensions folder, in FourStretch/ (see ugen/README.md). Build it with
// -I<ugen>/vendor/eurorack (four_cloud.h says why).
#include "SC_PlugIn.h"
#include "four_core.h"
#include "four_cloud.h"
#include <new>
#include <cstring>

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

// the loop, from two inputs that an older graph does not have
static inline void loopOf(Unit* unit, int input, four::Buf& a, four::Buf& b) {
    if ((int)unit->mNumInputs < input + 2) return;
    const float lo = IN0(input), span = IN0(input + 1);
    if (!(span >= 1.f) || !(lo >= 0.f)) return;
    a.setLoop((four::pos_t)lrintf(lo), (four::pos_t)lrintf(span));
    b.setLoop((four::pos_t)lrintf(lo), (four::pos_t)lrintf(span));
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
    loopOf(unit, 4, bl, br);
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
    loopOf(unit, 7, bl, br);
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
    if (!unit->mem) {
        SETCALC(ft->fClearUnitOutputs); ClearUnitOutputs(unit, 1);
        Print("FourDelay: no real-time memory for %lu bytes\n", (unsigned long)(size * sizeof(float)));
        return;
    }
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
    if (!unit->core) {
        SETCALC(ft->fClearUnitOutputs); ClearUnitOutputs(unit, 1);
        Print("FourGrain: no real-time memory for %lu bytes\n", (unsigned long)(sizeof(four::Grains)));
        return;
    }
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

// FourBBD.ar(in, time, feedback, tone, age): the bucket brigade delay, one
// channel. See BBD and BBDDelay in four_core.h. time is in seconds (43 ms at
// the least), tone is the filters' corner as a share of the clock (0.2 to
// 0.45), age is 0 (clean) to 1 (an old unit: noise and the compander).
struct FourBBD : public Unit { four::BBDDelay core; float* mem; float lastTime, lastTone; };
static void FourBBD_next(FourBBD* unit, int inNumSamples) {
    const float* in = IN(0); float* out = OUT(0);
    const float time = sc_clip(IN0(1), 0.02f, 3.f), tone = sc_clip(IN0(3), 0.2f, 0.45f);
    const float fb = sc_clip(IN0(2), -0.98f, 0.98f), age = sc_clip(IN0(4), 0.f, 1.f);
    if (time != unit->lastTime || tone != unit->lastTone) {
        unit->core.set(time, tone);                  // once for each block: the clock glides in steps of 1.3 ms
        unit->lastTime = time; unit->lastTone = tone;
    }
    for (int i = 0; i < inNumSamples; i++) out[i] = unit->core.tick(in[i], fb, age);
}
static void FourBBD_Ctor(FourBBD* unit) {
    unit->mem = (float*)RTAlloc(unit->mWorld, 8192 * sizeof(float));
    if (!unit->mem) {
        SETCALC(ft->fClearUnitOutputs); ClearUnitOutputs(unit, 1);
        Print("FourBBD: no real-time memory for %lu bytes\n", (unsigned long)(8192 * sizeof(float)));
        return;
    }
    unit->core.init(unit->mem, 8192, SAMPLERATE);
    unit->lastTime = -1.f; unit->lastTone = -1.f;
    SETCALC(FourBBD_next);
    OUT0(0) = 0.f;
}
static void FourBBD_Dtor(FourBBD* unit) {
    if (unit->mem) RTFree(unit->mWorld, unit->mem);
}

// FourCloud.ar(inputArray, pit, pos, size, dens, tex, drywet, in_gain, spread,
// rvb, fb, freeze, mode, lofi, trig): Mutable Instruments Clouds (Emilie
// Gillet, MIT), run the way the MiClouds UGen of mi-UGens runs it (Volker
// Böhm, 2020, GPL-3.0; this wrapper follows his MiClouds.cpp line for line).
// The same inputs in the same order, the same smoothing, the same 32-sample
// blocks, the same 48 kHz core. Its own name: a second MiClouds class next to
// an installed mi-UGens would hang every norns script.
// What differs from MiClouds, none of it heard: the core and its buffers come
// from the real-time pool (MiClouds took the core from the heap); a failed
// start or a block size that is not a multiple of 32 gives silence and a
// message (MiClouds left the unit without a calc function); one audio input
// is read on both sides (MiClouds wrote past it).
namespace cloud {
const int kBlock = 32;            // the core's block (clouds::kMaxBlockSize)
const int kArgs = 14;             // the inputs before the audio
const int kLarge = 118784;        // the core's two buffers, as MiClouds sizes them
const int kSmall = 65536 - 128;
enum { PITCH, POSITION, SIZE, DENSITY, TEXTURE, DRYWET, COUNT };
}

struct FourCloud : public Unit {
    clouds::GranularProcessor* gp;
    uint8_t* large;
    uint8_t* small;
    float smoothed[cloud::COUNT];
    bool previousTrig;
    clouds::FloatFrame in[cloud::kBlock];
    clouds::FloatFrame out[cloud::kBlock];
};

static void FourCloud_next(FourCloud* unit, int inNumSamples) {
    using namespace cloud;
    float pitch = IN0(0);
    float inGain = IN0(6), spread = IN0(7), reverb = IN0(8), fb = IN0(9);
    const bool freeze = IN0(10) > 0.f;
    int mode = (int)IN0(11);
    const bool lofi = IN0(12) > 0.f;
    const float* trigIn = IN(13);
    float* outL = OUT(0);
    float* outR = OUT(1);
    const float* inL = IN(kArgs);
    const float* inR = unit->mNumInputs > kArgs + 1 ? IN(kArgs + 1) : inL;
    float* sm = unit->smoothed;
    const float coef = 0.1f;
    clouds::GranularProcessor* gp = unit->gp;
    clouds::Parameters* p = gp->mutable_parameters();

    pitch = sc_clip(pitch, -48.f, 48.f);
    sm[PITCH] += coef * (pitch - sm[PITCH]);
    p->pitch = sm[PITCH];
    for (int i = 1; i < COUNT; ++i) {
        const float v = sc_clip(IN0(i), 0.f, 1.f);
        sm[i] += coef * (v - sm[i]);
    }
    p->position = sm[POSITION];
    p->size = sm[SIZE];
    p->density = sm[DENSITY];
    p->texture = sm[TEXTURE];
    p->dry_wet = sm[DRYWET];

    inGain = sc_clip(inGain, 0.125f, 8.f);
    p->stereo_spread = sc_clip(spread, 0.f, 1.f);
    p->reverb = sc_clip(reverb, 0.f, 1.f);
    p->feedback = sc_clip(fb, 0.f, 1.f);
    mode = sc_clip(mode, 0, 3);
    gp->set_low_fidelity(lofi);
    gp->set_freeze(freeze);
    gp->set_playback_mode(static_cast<clouds::PlaybackMode>(mode));

    const int trigRate = INRATE(13);
    for (int count = 0; count < inNumSamples; count += kBlock) {
        for (int i = 0; i < kBlock; ++i) {
            unit->in[i].l = inL[i + count] * inGain;
            unit->in[i].r = inR[i + count] * inGain;
        }
        bool trigger = false;
        if (trigRate == calc_BufRate) {
            trigger = trigIn[0] > 0.f;
        } else if (trigRate == calc_FullRate) {
            float sum = 0.f;
            for (int i = 0; i < kBlock; ++i) sum += trigIn[i + count];
            trigger = sum > 0.f;
        }
        p->trigger = trigger && !unit->previousTrig;
        unit->previousTrig = trigger;
        gp->Process(unit->in, unit->out, kBlock);
        gp->Prepare();
        p->trigger = false;
        for (int i = 0; i < kBlock; ++i) {
            outL[i + count] = unit->out[i].l;
            outR[i + count] = unit->out[i].r;
        }
    }
}

static void FourCloud_Dtor(FourCloud* unit) {
    if (unit->gp) {
        unit->gp->~GranularProcessor();
        RTFree(unit->mWorld, unit->gp);
    }
    if (unit->large) RTFree(unit->mWorld, unit->large);
    if (unit->small) RTFree(unit->mWorld, unit->small);
}

static void FourCloud_Ctor(FourCloud* unit) {
    using namespace cloud;
    unit->gp = nullptr; unit->large = nullptr; unit->small = nullptr;
    const char* why = nullptr;
    if (BUFLENGTH < kBlock || BUFLENGTH % kBlock) why = "the block size must be a multiple of 32";
    else if (unit->mNumInputs <= kArgs) why = "no audio input";
    if (!why) {
        unit->large = (uint8_t*)RTAlloc(unit->mWorld, kLarge);
        unit->small = (uint8_t*)RTAlloc(unit->mWorld, kSmall);
        void* mem = RTAlloc(unit->mWorld, sizeof(clouds::GranularProcessor));
        if (mem) {
            // as MiClouds: construct, then zero. Init() sets only some of the
            // members and relies on the rest starting at zero.
            unit->gp = new (mem) clouds::GranularProcessor;
            std::memset(static_cast<void*>(unit->gp), 0, sizeof(clouds::GranularProcessor));
        }
        if (!unit->large || !unit->small || !unit->gp) why = "no real-time memory";
    }
    if (why) {
        FourCloud_Dtor(unit);
        unit->gp = nullptr; unit->large = nullptr; unit->small = nullptr;
        Print("FourCloud: %s\n", why);
        SETCALC(ft->fClearUnitOutputs);
        ClearUnitOutputs(unit, 1);
        return;
    }
    clouds::GranularProcessor* gp = unit->gp;
    gp->Init(unit->large, kLarge, unit->small, kSmall);
    gp->set_sample_rate(SAMPLERATE);
    gp->set_num_channels(2);
    gp->set_low_fidelity(false);
    gp->set_playback_mode(clouds::PLAYBACK_MODE_GRANULAR);
    float* sm = unit->smoothed;
    sm[PITCH] = 0.f; sm[POSITION] = 0.f; sm[SIZE] = 0.5f;
    sm[DENSITY] = 0.1f; sm[TEXTURE] = 0.5f; sm[DRYWET] = 1.f;
    clouds::Parameters* p = gp->mutable_parameters();
    p->stereo_spread = 0.5f;
    p->reverb = 0.f;
    p->feedback = 0.f;
    p->freeze = false;
    unit->previousTrig = false;
    SETCALC(FourCloud_next);
    ClearUnitOutputs(unit, 1);
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
    DefineDtorCantAliasUnit(FourBBD);
    DefineDtorCantAliasUnit(FourCloud);
}
