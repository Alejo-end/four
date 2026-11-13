// four_core.h: the stretch algorithms of four, with no SuperCollider in them,
// so that a plain test program can prove them (ugen/test_core.cpp).
//
// PV is a phase vocoder with locked phases (Laroche and Dolson, 1999).
//   * Each hop it reads TWO frames of the take: B ends at the head, A ends one
//     hop before it. The phase a partial gained from A to B is what it gains
//     in one hop of output, whatever the head's speed: the head can crawl,
//     stand still (a freeze) or run backward.
//   * Only the PEAKS of the spectrum carry a phase forward. Every other bin
//     keeps its phase relative to its peak, so a partial stays one partial.
//   * Left and right get the SAME rotation, found on their sum, so the stereo
//     image of the take is untouched.
//   * A sudden rise in level resets the rotation to none: the attack is the
//     take's own.
//   * When the head moves one hop per hop (speed 1) A is the last B, every
//     rotation is none, and the output is the take, sample for sample.
// Pitch: both stretches make their sound at pitch 1, reading whole frames of
// the take, and ONE resampler turns the result to the pitch (Resampler: a
// windowed sinc whose cutoff falls as the pitch rises). The stretch runs
// `pitch` samples for each sample of output, so pitch and speed are
// independent, and the take is never read between two frames.
#pragma once
#include <cmath>
#include <cstring>
#include <cstdint>
#include <cstdlib>
#ifdef FOUR_FFTW
#include <fftw3.h>
#endif
#if (defined(__ARM_NEON) || defined(__ARM_NEON__)) && !defined(FOUR_NO_NEON)
#include <arm_neon.h>
#define FOUR_NEON 1
#endif

namespace four {

// A place in the take or a count of samples. 64 bits on purpose: the norns is
// a 32-bit system, where a `long` wraps after a few hours of samples.
typedef int64_t pos_t;

const int N = 2048;          // frame
const int H = 512;           // hop, N/4: Hann squared sums to 1.5 there
const int NB = N / 2 + 1;
const int STAGES = 8;        // one hop's work, spread over the hop
const int SINC_SPAN = 16;    // the widest half-width of the kernel, in taps
const int KROWS = 256;       // rows of the kernel tables for each tap of offset

struct Tables {
    float win[N];
    float cosT[N / 2], sinT[N / 2];
    uint16_t rev[N / 2];      // for the half-size transform
    // The kernel tables: one row for each offset q/KROWS of the read place
    // past a whole sample, one column for each tap. Two rows side by side are
    // read as one line.
    //   g: window(d) / d for every tap that is 2 samples or more from the read
    //      place (d = tap - place). It is smooth there, so the line between
    //      two rows is right to about 1e-6. The four taps nearer than that
    //      hold 0 here.
    //   w: the window alone for those four near taps (j = -1, 0, 1, 2), which
    //      kernel() divides exactly.
    float g16[KROWS + 1][2 * SINC_SPAN], g8[KROWS + 1][SINC_SPAN];
    float w16[KROWS + 1][4], w8[KROWS + 1][4];
    Tables() {
        const double pi = 3.14159265358979323846;
        for (int i = 0; i < N; i++) win[i] = (float)(0.5 - 0.5 * std::cos(2 * pi * i / N));
        for (int i = 0; i < N / 2; i++) {
            cosT[i] = (float)std::cos(2 * pi * i / N);
            sinT[i] = (float)std::sin(2 * pi * i / N);
        }
        int bits = 0;
        while ((1 << bits) < N / 2) bits++;
        for (int i = 0; i < N / 2; i++) {
            int r = 0;
            for (int b = 0; b < bits; b++) if (i & (1 << b)) r |= 1 << (bits - 1 - b);
            rev[i] = (uint16_t)r;
        }
        const double beta = 9.0;
        auto i0 = [](double v) {
            double s = 1, t = 1;
            for (int k = 1; k < 40; k++) { t *= (v / (2 * k)) * (v / (2 * k)); s += t; }
            return s;
        };
        auto win = [&](double d, int half) {
            d = std::fabs(d) / half;
            return d < 1 ? i0(beta * std::sqrt(1 - d * d)) / i0(beta) : 0.0;
        };
        auto fill = [&](float* g, float* w, int half, double off) {
            for (int k = 0; k < 2 * half; k++) {
                int j = k - half + 1;
                double d = (double)j - off;
                if (j >= -1 && j <= 2) { g[k] = 0.f; w[j + 1] = (float)win(d, half); }
                else g[k] = (float)(win(d, half) / d);
            }
        };
        for (int q = 0; q <= KROWS; q++) {
            fill(g16[q], w16[q], SINC_SPAN, (double)q / KROWS);
            fill(g8[q], w8[q], SINC_SPAN / 2, (double)q / KROWS);
        }
    }
};

inline const Tables& tables() { static Tables t; return t; }

// in-place complex FFT of N/2 points, radix 2, no scaling
inline void cfftHalf(float* re, float* im, bool inverse) {
    const Tables& t = tables();
    const int M = N / 2;
    for (int i = 0; i < M; i++) {
        int j = t.rev[i];
        if (j > i) {
            float a = re[i]; re[i] = re[j]; re[j] = a;
            a = im[i]; im[i] = im[j]; im[j] = a;
        }
    }
    for (int len = 2; len <= M; len <<= 1) {
        int half = len >> 1, step = N / len;
        for (int i = 0; i < M; i += len) {
            for (int k = 0; k < half; k++) {
                float wr = t.cosT[k * step];
                float wi = inverse ? t.sinT[k * step] : -t.sinT[k * step];
                float xr = re[i + k + half] * wr - im[i + k + half] * wi;
                float xi = re[i + k + half] * wi + im[i + k + half] * wr;
                re[i + k + half] = re[i + k] - xr; im[i + k + half] = im[i + k] - xi;
                re[i + k] += xr; im[i + k] += xi;
            }
        }
    }
}

#ifdef FOUR_FFTW
// The norns build: the same two transforms from FFTW, which has NEON code for
// the Pi. It is the library that SuperCollider itself uses there. The plans
// and their arrays are made once, off the audio thread (see tables() in the
// plugin's load). FFTW_ESTIMATE picks the same plan on every start, so the
// output does not change from one boot to the next. All units share them: scsynth runs its units one after the
// other on one thread.
struct Plans {
    float* t; fftwf_complex* f; fftwf_plan fwd, inv;
    Plans() {
        t = fftwf_alloc_real(N); f = fftwf_alloc_complex(NB);
        fwd = fftwf_plan_dft_r2c_1d(N, t, f, FFTW_ESTIMATE);
        inv = fftwf_plan_dft_c2r_1d(N, f, t, FFTW_ESTIMATE);
    }
};
inline Plans& plans() { static Plans p; return p; }

inline void rfft(const float* x, float* re, float* im, float*, float*) {
    Plans& p = plans();
    std::memcpy(p.t, x, N * sizeof(float));
    fftwf_execute(p.fwd);
    for (int k = 0; k < NB; k++) { re[k] = p.f[k][0]; im[k] = p.f[k][1]; }
}

// The inverse: bins 0..N/2 -> x[N], scaled by N/2 (the caller divides).
inline void irfft(const float* re, const float* im, float* x, float*, float*) {
    Plans& p = plans();
    for (int k = 0; k < NB; k++) { p.f[k][0] = re[k]; p.f[k][1] = im[k]; }
    fftwf_execute(p.inv);
    for (int k = 0; k < N; k++) x[k] = 0.5f * p.t[k];
}
#else
// The transform of a REAL frame, through a complex one of half the size: the
// even samples are the real parts and the odd ones the imaginary parts. It is
// the same spectrum as a full-size transform, for half the work.
// x[N] -> bins 0..N/2 in re, im. zr, zi are scratch of N/2.
inline void rfft(const float* x, float* re, float* im, float* zr, float* zi) {
    const Tables& t = tables();
    const int M = N / 2;
    for (int k = 0; k < M; k++) { zr[k] = x[2 * k]; zi[k] = x[2 * k + 1]; }
    cfftHalf(zr, zi, false);
    for (int k = 0; k <= M; k++) {
        int a = k % M, b = (M - k) % M;
        float er = 0.5f * (zr[a] + zr[b]), ei = 0.5f * (zi[a] - zi[b]);     // even part
        float dr = 0.5f * (zr[a] - zr[b]), di = 0.5f * (zi[a] + zi[b]);     // j * odd part
        // odd = d / j = (di, -dr); times e^(-2 pi j k / N) = (c, -s)
        float c = k < M ? t.cosT[k] : -1.f, sn = k < M ? t.sinT[k] : 0.f;
        float orr = di * c - dr * sn, oi = -dr * c - di * sn;
        re[k] = er + orr; im[k] = ei + oi;
    }
}

// The inverse: bins 0..N/2 -> x[N], scaled by N/2 (the caller divides).
inline void irfft(const float* re, const float* im, float* x, float* zr, float* zi) {
    const Tables& t = tables();
    const int M = N / 2;
    for (int k = 0; k < M; k++) {
        int b = M - k;
        float er = 0.5f * (re[k] + re[b]), ei = 0.5f * (im[k] - im[b]);
        float dr = 0.5f * (re[k] - re[b]), di = 0.5f * (im[k] + im[b]);
        // odd = e^(+2 pi j k / N) * d
        float c = t.cosT[k], sn = t.sinT[k];
        float orr = dr * c - di * sn, oi = dr * sn + di * c;
        // Z = even + j * odd
        zr[k] = er - oi; zi[k] = ei + orr;
    }
    cfftHalf(zr, zi, true);
    for (int k = 0; k < M; k++) { x[2 * k] = zr[k]; x[2 * k + 1] = zi[k]; }
}

#endif

struct Buf {
    const float* data;   // mono
    int frames;
    inline float at(pos_t i) const {
        if (i >= 0 && i < frames) return data[i];     // the usual case, with no division
        if (frames <= 0) return 0.f;
        i %= frames; if (i < 0) i += frames;
        return data[i];
    }
};

// The kernel of every pitched read: a sinc with its cutoff at `fc`, under a
// Kaiser window of `half` taps to each side. Tap j (j = -half+1 .. half) sits
// at j - fr from the read place.
//   sinc: sin(x)/x with x = pi fc (j - fr). sin(x) = S[j] cos(phi) - C[j] sin(phi)
//   with phi = pi fc fr, so one sine and one cosine serve all the taps, and the
//   value is exact to a float (no table). S and C change only with the pitch.
//   Close to x = 0 the series 1 - x^2/6 + x^4/120 replaces the division.
struct Kern {
    int half; float fc, theta;
    float S[2 * SINC_SPAN], C[2 * SINC_SPAN];
    void init() { half = 0; fc = 0; theta = 0; }
    inline void set(int h, float f) {
        if (h == half && f == fc) return;
        half = h; fc = f;
        const double th = 3.14159265358979323846 * (double)f;
        theta = (float)th;
        const double s1 = std::sin(th), c1 = std::cos(th);
        double sn = 0, cs = 1;
        for (int j = 0; j <= h; j++) {
            S[j + h - 1] = (float)sn; C[j + h - 1] = (float)cs;
            if (j > 0 && j < h) { S[h - 1 - j] = (float)-sn; C[h - 1 - j] = (float)cs; }
            double t = sn * c1 + cs * s1; cs = cs * c1 - sn * s1; sn = t;
        }
    }
};

// The weights for a read `fr` past a whole sample, in wt[0 .. 2 half - 1].
// Returns their sum (the caller divides by it, so the common factor 1/theta
// is left out of every weight).
inline float kernel(const Kern& kn, float fr, float* wt) {
    const Tables& t = tables();
    const int half = kn.half, n = 2 * half;
    float pos = fr * KROWS;
    int q = (int)pos;
    if (q < 0) q = 0;
    if (q > KROWS - 1) q = KROWS - 1;
    const float f = pos - (float)q;
    const bool wide = half == SINC_SPAN;
    const float* g0 = wide ? t.g16[q] : t.g8[q];
    const float* g1 = wide ? t.g16[q + 1] : t.g8[q + 1];
    const float* w0 = wide ? t.w16[q] : t.w8[q];
    const float* w1 = wide ? t.w16[q + 1] : t.w8[q + 1];
    const float phi = kn.theta * fr;
    const float sp = std::sin(phi), cp = std::cos(phi);
    float wsum;
#ifdef FOUR_NEON
    const float32x4_t vsp = vdupq_n_f32(sp), vcp = vdupq_n_f32(cp), vf = vdupq_n_f32(f);
    float32x4_t sum = vdupq_n_f32(0.f);
    for (int k = 0; k < n; k += 4) {
        float32x4_t num = vsubq_f32(vmulq_f32(vld1q_f32(kn.S + k), vcp), vmulq_f32(vld1q_f32(kn.C + k), vsp));
        float32x4_t a = vld1q_f32(g0 + k);
        float32x4_t g = vaddq_f32(a, vmulq_f32(vf, vsubq_f32(vld1q_f32(g1 + k), a)));
        float32x4_t w = vmulq_f32(num, g);
        vst1q_f32(wt + k, w);
        sum = vaddq_f32(sum, w);
    }
    float32x2_t p2 = vadd_f32(vget_low_f32(sum), vget_high_f32(sum));
    wsum = vget_lane_f32(vpadd_f32(p2, p2), 0);
#else
    wsum = 0;
    for (int k = 0; k < n; k++) {
        float w = (kn.S[k] * cp - kn.C[k] * sp) * (g0[k] + f * (g1[k] - g0[k]));
        wt[k] = w; wsum += w;
    }
#endif
    // the four near taps, each with its own division
    for (int m = 0; m < 4; m++) {
        const int k = half - 2 + m;                 // j = m - 1
        const float d = (float)(m - 1) - fr;
        float v;
        if (std::fabs(d) < 0.02f) {
            float x = kn.theta * d, x2 = x * x;
            v = kn.theta * (1.f - x2 * (1.f / 6.f) + x2 * x2 * (1.f / 120.f));
        } else v = (kn.S[k] * cp - kn.C[k] * sp) / d;
        const float w = v * (w0[m] + f * (w1[m] - w0[m]));
        wt[k] = w; wsum += w;
    }
    return wsum;
}

// the sum of n taps (n is 16 or 32) over two channels
inline void taps(const float* wt, const float* l, const float* r, int n, float& outL, float& outR) {
#ifdef FOUR_NEON
    float32x4_t sl = vdupq_n_f32(0.f), sr = vdupq_n_f32(0.f);
    for (int k = 0; k < n; k += 4) {
        float32x4_t w = vld1q_f32(wt + k);
        sl = vaddq_f32(sl, vmulq_f32(w, vld1q_f32(l + k)));
        sr = vaddq_f32(sr, vmulq_f32(w, vld1q_f32(r + k)));
    }
    float32x2_t a = vadd_f32(vget_low_f32(sl), vget_high_f32(sl));
    float32x2_t b = vadd_f32(vget_low_f32(sr), vget_high_f32(sr));
    outL = vget_lane_f32(vpadd_f32(a, a), 0); outR = vget_lane_f32(vpadd_f32(b, b), 0);
#else
    float a = 0, b = 0;
    for (int k = 0; k < n; k++) { a += wt[k] * l[k]; b += wt[k] * r[k]; }
    outL = a; outR = b;
#endif
}

// The pitch stage. `gen(l, r)` makes the next sample at pitch 1; process()
// reads that stream at `ratio` samples per sample of output. The kernel is a
// Kaiser windowed sinc: 16 taps at or below pitch 1, 32 above it with its
// cutoff at 0.92/ratio, so nothing folds. The weights are normalised. At a
// ratio of exactly 1 the read sits on whole samples and the output IS the
// stream (after a pitch move it slides back onto them within a few ms).
struct Resampler {
    static const int RING = 256;
    float hl[2 * RING], hr[2 * RING];   // each sample is stored twice, RING apart,
                                        // so every run of taps is one straight piece
    pos_t w;            // samples made so far
    pos_t base;         // the read place in the stream: whole samples,
    double frac;        // and the part of a sample past them (0 to 1)
    Kern kn;

    void init() { std::memset(this, 0, sizeof(Resampler)); kn.init(); }

    template <class Gen>
    inline void make(Gen&& gen) {
        unsigned i = (unsigned)(w & (RING - 1));
        gen(hl[i], hr[i]);
        hl[i + RING] = hl[i]; hr[i + RING] = hr[i];
        w++;
    }

    template <class Gen>
    inline void one(float& outL, float& outR, double ratio, Gen&& gen) {
        if (!(ratio > 0.25)) ratio = 0.25;
        if (ratio > 4.0) ratio = 4.0;
        float fr = (float)frac;
        if (ratio > 0.9999 && ratio < 1.0001) {
            ratio = 1.0;
            if (fr != 0.f) {            // slide onto the whole samples
                if (fr < 0.002f) { frac = 0.0; fr = 0.f; }
                else ratio = 0.998;
            }
        }
        if (ratio == 1.0 && fr == 0.f) {
            while (w <= base) make(gen);
            outL = hl[base & (RING - 1)]; outR = hr[base & (RING - 1)];
            base++;
            return;
        }
        const int half = ratio > 1.0 ? SINC_SPAN : SINC_SPAN / 2;
        kn.set(half, ratio > 1.0 ? (float)(0.92 / ratio) : 1.0f);
        while (w <= base + half) make(gen);
        float wt[2 * SINC_SPAN];
        float wsum = kernel(kn, fr, wt);
        const unsigned first = ((unsigned)(base & (RING - 1)) + RING - half + 1) & (RING - 1);
        float accL, accR;
        taps(wt, hl + first, hr + first, 2 * half, accL, accR);
        float inv = wsum != 0 ? 1.0f / wsum : 0.f;
        outL = accL * inv; outR = accR * inv;
        frac += ratio;
        int whole = (int)frac;
        base += whole; frac -= whole;
    }
};

// PLAY's read: one stereo sample of the take at the place base + fr, for a
// head that moves `ratio` frames per sample. The same kernel as Resampler, on
// the take itself. On a whole frame at pitch 1 or below it is the stored
// sample, bit for bit.
inline void sincAt(Kern& kn, const Buf& bl, const Buf& br, pos_t base, float fr, double ratio,
                   float& outL, float& outR) {
    if (ratio < 0) ratio = -ratio;
    if (ratio > 4.0) ratio = 4.0;
    if (fr == 0.f && ratio <= 1.0001) { outL = bl.at(base); outR = br.at(base); return; }
    const int half = ratio > 1.0001 ? SINC_SPAN : SINC_SPAN / 2;
    kn.set(half, ratio > 1.0001 ? (float)(0.92 / ratio) : 1.0f);
    float wt[2 * SINC_SPAN];
    float wsum = kernel(kn, fr, wt);
    float accL, accR;
    const pos_t first = base - half + 1;
    if (first >= 0 && base + half < bl.frames && base + half < br.frames) {
        taps(wt, bl.data + first, br.data + first, 2 * half, accL, accR);
    } else {
        float tl[2 * SINC_SPAN], tr[2 * SINC_SPAN];
        for (int k = 0; k < 2 * half; k++) { tl[k] = bl.at(first + k); tr[k] = br.at(first + k); }
        taps(wt, tl, tr, 2 * half, accL, accR);
    }
    float inv = wsum != 0 ? 1.0f / wsum : 0.f;
    outL = accL * inv; outR = accR * inv;
}

struct PV {
    float tA[N], tL[N], tR[N];                 // frames in time
    float aRe[NB], aIm[NB], lRe[NB], lIm[NB], rRe[NB], rIm[NB];
    float zr[N / 2], zi[N / 2];                // scratch of the transform
    float pRe[NB], pIm[NB];        // the last output's mid spectrum
    float mag[NB];
    float ola[2][N + H];
    int cnt, stage;
    pos_t P;
    Resampler rs;
    bool primed;
    int sinceReset;
    float lastFlux;

    void init() {
        std::memset(this, 0, sizeof(PV));
        cnt = H;           // the first sample starts a hop
        stage = STAGES;
    }

    // frame of N samples that ENDS at `end` (exclusive), windowed
    void readFrame(const Buf& b, pos_t end, float* re, bool add) {
        const float* w = tables().win;
        pos_t s = end - N;
        if (b.frames > 0 && s >= 0 && s + N <= b.frames) {
            const float* d = b.data + s;
            if (add) for (int i = 0; i < N; i++) re[i] += d[i] * w[i];
            else for (int i = 0; i < N; i++) re[i] = d[i] * w[i];
        } else {
            for (int i = 0; i < N; i++) {
                float v = b.at(s + i) * w[i];
                re[i] = add ? re[i] + v : v;
            }
        }
    }

    void phases() {
        // M = L + R, and the rise in level from A to B
        float flux = 0, base = 1e-9f;
        int k = 0;
#ifdef FOUR_NEON
        // four bins at a time. The square root is sqrt(m) = m * rsqrt(m), with
        // two Newton steps: right to a float's last bits, and the flux only
        // feeds a threshold.
        {
            const float32x4_t tiny = vdupq_n_f32(1e-30f), zero = vdupq_n_f32(0.f);
            float32x4_t vflux = zero, vbase = zero;
            auto root = [&](float32x4_t m) {
                float32x4_t c = vmaxq_f32(m, tiny);
                float32x4_t e = vrsqrteq_f32(c);
                e = vmulq_f32(e, vrsqrtsq_f32(vmulq_f32(c, e), e));
                e = vmulq_f32(e, vrsqrtsq_f32(vmulq_f32(c, e), e));
                return vmulq_f32(m, e);
            };
            for (; k + 4 <= NB; k += 4) {
                float32x4_t mr = vaddq_f32(vld1q_f32(lRe + k), vld1q_f32(rRe + k));
                float32x4_t mi = vaddq_f32(vld1q_f32(lIm + k), vld1q_f32(rIm + k));
                float32x4_t m = vaddq_f32(vmulq_f32(mr, mr), vmulq_f32(mi, mi));
                vst1q_f32(mag + k, m);
                float32x4_t ar = vld1q_f32(aRe + k), ai = vld1q_f32(aIm + k);
                float32x4_t ma = root(vaddq_f32(vmulq_f32(ar, ar), vmulq_f32(ai, ai)));
                vflux = vaddq_f32(vflux, vmaxq_f32(vsubq_f32(root(m), ma), zero));
                vbase = vaddq_f32(vbase, ma);
            }
            float tf[4], tb[4];
            vst1q_f32(tf, vflux); vst1q_f32(tb, vbase);
            flux += tf[0] + tf[1] + tf[2] + tf[3]; base += tb[0] + tb[1] + tb[2] + tb[3];
        }
#endif
        for (; k < NB; k++) {
            float mr = lRe[k] + rRe[k], mi = lIm[k] + rIm[k];
            float m = mr * mr + mi * mi;
            mag[k] = m;
            float ma = std::sqrt(aRe[k] * aRe[k] + aIm[k] * aIm[k]);
            float mb = std::sqrt(m);
            if (mb > ma) flux += mb - ma;
            base += ma;
        }
        lastFlux = flux / base;
        sinceReset++;
        bool reset = !primed || (lastFlux > 1.5f && sinceReset > 3);
        if (reset) {
            primed = true; sinceReset = 0;
            for (int k = 0; k < NB; k++) { pRe[k] = lRe[k] + rRe[k]; pIm[k] = lIm[k] + rIm[k]; }
            return;                       // no rotation: the frame is the take's own
        }
        // peaks, and one rotation for each peak's region
        int lo = 0, peak = -1, next = -1;
        auto findNext = [&](int from) {
            for (int k = from < 2 ? 2 : from; k < NB - 2; k++)
                if (mag[k] > mag[k - 1] && mag[k] > mag[k + 1] && mag[k] > mag[k - 2] && mag[k] > mag[k + 2]) return k;
            return -1;
        };
        peak = findNext(0);
        if (peak < 0) {
            for (int k = 0; k < NB; k++) { pRe[k] = lRe[k] + rRe[k]; pIm[k] = lIm[k] + rIm[k]; }
            return;
        }
        while (peak >= 0) {
            next = findNext(peak + 1);
            int hi = next < 0 ? NB - 1 : (peak + next) / 2;
            // u = unit( prev[peak] * conj(A[peak]) )
            float ur = pRe[peak] * aRe[peak] + pIm[peak] * aIm[peak];
            float ui = pIm[peak] * aRe[peak] - pRe[peak] * aIm[peak];
            float n = std::sqrt(ur * ur + ui * ui);
            if (n < 1e-20f) { ur = 1; ui = 0; } else { ur /= n; ui /= n; }
            if (ur > 0.99999999f || ((ur - 1) * (ur - 1) + ui * ui) < 1e-8f) { ur = 1; ui = 0; }
            for (int k = lo; k <= hi; k++) {
                float mr = lRe[k] + rRe[k], mi = lIm[k] + rIm[k];
                pRe[k] = mr * ur - mi * ui; pIm[k] = mr * ui + mi * ur;
                if (ui != 0) {
                    float x = lRe[k], y = lIm[k];
                    lRe[k] = x * ur - y * ui; lIm[k] = x * ui + y * ur;
                    x = rRe[k]; y = rIm[k];
                    rRe[k] = x * ur - y * ui; rIm[k] = x * ui + y * ur;
                }
            }
            lo = hi + 1;
            peak = next;
        }
        // a real signal: its two end bins are real
        lIm[0] = rIm[0] = 0; lIm[N / 2] = rIm[N / 2] = 0;
    }

    void runStage(int s, const Buf& bl, const Buf& br) {
        const float* w = tables().win;
        const float g = (2.0f / 3.0f) / (N / 2);
        switch (s) {
        // never more than one transform in a stage: a stage runs inside one block
        case 0:
            // A ends exactly one hop before B
            readFrame(bl, P - H, tA, false);
            readFrame(br, P - H, tA, true);
            break;
        case 1:
            readFrame(bl, P, tL, false);
            readFrame(br, P, tR, false);
            break;
        case 2: rfft(tA, aRe, aIm, zr, zi); break;
        case 3: rfft(tL, lRe, lIm, zr, zi); break;
        case 4: rfft(tR, rRe, rIm, zr, zi); phases(); break;
        case 5: irfft(lRe, lIm, tL, zr, zi); break;
        case 6: irfft(rRe, rIm, tR, zr, zi); break;
        case 7:
            for (int i = 0; i < N; i++) {
                ola[0][H + i] += tL[i] * w[i] * g;
                ola[1][H + i] += tR[i] * w[i] * g;
            }
            break;
        }
    }

    // one sample at pitch 1. `head` is the head now, in frames.
    inline void tick(float head, const Buf& bl, const Buf& br, float& l, float& r) {
        if (cnt >= H) {
            for (int c = 0; c < 2; c++) {
                std::memmove(ola[c], ola[c] + H, N * sizeof(float));
                std::memset(ola[c] + N, 0, H * sizeof(float));
            }
            cnt = 0; stage = 0;
            P = (pos_t)std::llrint(head);
        }
        while (stage < STAGES && cnt >= stage * (H / STAGES)) runStage(stage++, bl, br);
        l = ola[0][cnt];
        r = ola[1][cnt];
        cnt++;
    }

    // pos: the head, in frames, one value per sample. pitch: the ratio.
    void process(float* outL, float* outR, int n, const float* pos, float pitch,
                 const Buf& bl, const Buf& br) {
        for (int i = 0; i < n; i++) {
            float head = pos[i];
            rs.one(outL[i], outR[i], (double)pitch,
                   [&](float& l, float& r) { tick(head, bl, br, l, r); });
        }
    }
};

// WARP is WSOLA: a stretch in the time domain.
//   * Grains are Hann windows at a hop of L/k (k = 2..8). Those windows sum to
//     a constant, so the level needs no law.
//   * Each new grain is due at the head. The grain before it would go on at
//     `cont` (where it began, plus one hop). If cont is within `reach` of the
//     head, the new grain starts THERE: it continues the last one exactly.
//     Otherwise the grain starts at the place near the head that looks most
//     like cont (the highest normalised correlation, on left plus right).
//   * So at speed 1 every grain continues the last, and the output is the
//     take, sample for sample. At other speeds the grains meet in phase.
//   * Both channels share every start, so the stereo image is the take's.
struct Warp {
    static const int MAXG = 10;
    static const int REACH = 480;        // 10 ms each way
    static const int TPL = 512;          // the template, in frames
    static const int DEC = 4;
    struct Grain { pos_t q; int i; int len; float step; bool on; };   // step: window table places per sample
    Grain g[MAXG];
    int toNext;
    pos_t cont; bool hasCont;
    float gain;
    Resampler rs;
    uint32_t seed;
    float lastCorr;
    float seg[(2 * REACH + TPL) / DEC + 4], tpl[TPL / DEC + 4];

    void init() { std::memset(this, 0, sizeof(Warp)); seed = 2463534242u; }
    float rnd() { seed ^= seed << 13; seed ^= seed >> 17; seed ^= seed << 5; return (float)(seed & 0xffffff) / 8388608.0f - 1.0f; }

    static inline float mid(const Buf& l, const Buf& r, pos_t i) { return l.at(i) + r.at(i); }

    pos_t search(const Buf& bl, const Buf& br, pos_t t0, pos_t c0) {
        const int nt = TPL / DEC, ns = (2 * REACH + TPL) / DEC;
        for (int i = 0; i < nt; i++) {
            float a = 0; for (int d = 0; d < DEC; d++) a += mid(bl, br, c0 + i * DEC + d);
            tpl[i] = a;
        }
        for (int i = 0; i < ns; i++) {
            float a = 0; for (int d = 0; d < DEC; d++) a += mid(bl, br, t0 - REACH + i * DEC + d);
            seg[i] = a;
        }
        int best = REACH / DEC; float bestV = -2;
        float e = 1e-12f;
        for (int i = 0; i < nt; i++) e += seg[i] * seg[i];
        for (int lag = 0; lag <= 2 * REACH / DEC; lag++) {
            float x = 0;
            for (int i = 0; i < nt; i++) x += tpl[i] * seg[lag + i];
            float v = x / std::sqrt(e);
            if (v > bestV) { bestV = v; best = lag; }
            e += seg[lag + nt] * seg[lag + nt] - seg[lag] * seg[lag];
            if (e < 1e-12f) e = 1e-12f;
        }
        // refine at the full rate, 3 frames each way
        pos_t coarse = t0 - REACH + (pos_t)best * DEC, fine = coarse; float fineV = -1e30f;
        for (pos_t cand = coarse - 3; cand <= coarse + 3; cand++) {
            float x = 0, en = 1e-12f;
            for (int i = 0; i < TPL; i += 2) { float m = mid(bl, br, cand + i); x += m * mid(bl, br, c0 + i); en += m * m; }
            float v = x / std::sqrt(en);
            if (v > fineV) { fineV = v; fine = cand; }
        }
        lastCorr = bestV;
        return fine;
    }

    // one sample at pitch 1
    inline void tick(float headF, float windowFrames, float overlaps, float rand,
                     const Buf& bl, const Buf& br, float& outL, float& outR) {
        const Tables& t = tables();
        if (toNext <= 0) {
            int k = (int)(overlaps + 0.5f); if (k < 2) k = 2; if (k > 8) k = 8;
            int hop = (int)(windowFrames / k + 0.5f); if (hop < 64) hop = 64; if (hop > 24000) hop = 24000;
            int len = hop * k;
            pos_t head = (pos_t)std::llrint(headF);
            if (rand > 0) head += (pos_t)std::floor(rnd() * rand * len);
            pos_t q;
            if (hasCont && std::llabs(cont - head) <= REACH) q = cont;
            else if (hasCont) q = search(bl, br, head, cont);
            else q = head;
            for (int j = 0; j < MAXG; j++) if (!g[j].on) {
                g[j].q = q; g[j].i = 0; g[j].len = len; g[j].step = (float)N / len; g[j].on = true;
                break;
            }
            cont = q + hop; hasCont = true;
            toNext = hop;
            gain = 2.0f / k;
        }
        float l = 0, r = 0;
        for (int j = 0; j < MAXG; j++) {
            Grain& gr = g[j];
            if (!gr.on) continue;
            float wp = (float)gr.i * gr.step;
            int wi = (int)wp; float wf = wp - wi;
            float w = t.win[wi] + ((wi + 1 < N ? t.win[wi + 1] : 0.f) - t.win[wi]) * wf;
            pos_t p = gr.q + gr.i;
            if (p >= 0 && p < bl.frames && p < br.frames) { l += bl.data[p] * w; r += br.data[p] * w; }
            else { l += bl.at(p) * w; r += br.at(p) * w; }
            if (++gr.i >= gr.len) gr.on = false;
        }
        outL = l * gain; outR = r * gain;
        toNext--;
    }

    void process(float* outL, float* outR, int n, const float* pos, float pitch,
                 float windowFrames, float overlaps, float rand,
                 const Buf& bl, const Buf& br) {
        for (int i = 0; i < n; i++) {
            float head = pos[i];
            rs.one(outL[i], outR[i], (double)pitch, [&](float& l, float& r) {
                tick(head, windowFrames, overlaps, rand, bl, br, l, r);
            });
        }
    }
};

// tanh for a block of samples. The C library's tanhf takes about 130 cycles
// for each sample on the norns, and the engine calls it on 28 channels. This
// one is the same curve to about 2e-7 (below the last bit of 24-bit audio):
//   below 0.625: x + x^3 P(x^2), the series of the Cephes library
//   above:       1 - 2 / (e^(2|x|) + 1), with the sign of x
inline void tanhBlock(const float* in, float* out, int n) {
    int i = 0;
#ifdef FOUR_NEON
    const float32x4_t one = vdupq_n_f32(1.f), two = vdupq_n_f32(2.f);
    for (; i + 4 <= n; i += 4) {
        float32x4_t x = vld1q_f32(in + i);
        float32x4_t ax = vabsq_f32(x);
        // the small branch
        float32x4_t z = vmulq_f32(x, x);
        float32x4_t p = vdupq_n_f32(-5.70498872745e-3f);
        p = vaddq_f32(vmulq_f32(p, z), vdupq_n_f32(2.06390887954e-2f));
        p = vaddq_f32(vmulq_f32(p, z), vdupq_n_f32(-5.37397155531e-2f));
        p = vaddq_f32(vmulq_f32(p, z), vdupq_n_f32(1.33314422036e-1f));
        p = vaddq_f32(vmulq_f32(p, z), vdupq_n_f32(-3.33332819422e-1f));
        float32x4_t small = vaddq_f32(vmulq_f32(vmulq_f32(p, z), x), x);
        // the large branch: e = exp(t), t = 2|x| (held to 20, where tanh is 1)
        float32x4_t t = vminq_f32(vaddq_f32(ax, ax), vdupq_n_f32(20.f));
        int32x4_t k = vcvtq_s32_f32(vaddq_f32(vmulq_n_f32(t, 1.44269504088896341f), vdupq_n_f32(0.5f)));
        float32x4_t fk = vcvtq_f32_s32(k);
        float32x4_t r = vsubq_f32(t, vmulq_n_f32(fk, 0.693359375f));
        r = vsubq_f32(r, vmulq_n_f32(fk, -2.12194440e-4f));
        float32x4_t q = vdupq_n_f32(1.9875691500e-4f);
        q = vaddq_f32(vmulq_f32(q, r), vdupq_n_f32(1.3981999507e-3f));
        q = vaddq_f32(vmulq_f32(q, r), vdupq_n_f32(8.3334519073e-3f));
        q = vaddq_f32(vmulq_f32(q, r), vdupq_n_f32(4.1665795894e-2f));
        q = vaddq_f32(vmulq_f32(q, r), vdupq_n_f32(1.6666665459e-1f));
        q = vaddq_f32(vmulq_f32(q, r), vdupq_n_f32(5.0000001201e-1f));
        float32x4_t e = vaddq_f32(vaddq_f32(vmulq_f32(q, vmulq_f32(r, r)), r), one);
        e = vmulq_f32(e, vreinterpretq_f32_s32(vshlq_n_s32(vaddq_s32(k, vdupq_n_s32(127)), 23)));
        float32x4_t d = vaddq_f32(e, one);
        float32x4_t rc = vrecpeq_f32(d);
        rc = vmulq_f32(rc, vrecpsq_f32(d, rc));
        rc = vmulq_f32(rc, vrecpsq_f32(d, rc));
        float32x4_t big = vsubq_f32(one, vmulq_f32(two, rc));
        // the sign of x on the large branch
        const uint32x4_t sign = vandq_u32(vreinterpretq_u32_f32(x), vdupq_n_u32(0x80000000u));
        big = vreinterpretq_f32_u32(vorrq_u32(vreinterpretq_u32_f32(big), sign));
        vst1q_f32(out + i, vbslq_f32(vcltq_f32(ax, vdupq_n_f32(0.625f)), small, big));
    }
#endif
    for (; i < n; i++) out[i] = std::tanh(in[i]);
}

} // namespace four
