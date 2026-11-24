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

// A buffer, and the LOOP that PV and WARP read in it (setLoop). Their frames and
// grains reach past the head, so near the loop's point they read what lies
// outside the window: silence, before and after a take. The level fell by 27 dB
// there. Inside a loop a read past the end goes on at the start, and the other
// way round. The splice itself is smoothed: half of its step is added on each
// side and dies over SEAM frames, so there is no click, no hole, and the loop
// keeps its length.
struct Buf {
    const float* data;   // mono
    int frames;
    pos_t lo = 0, span = 0;             // span 0: no loop, the whole buffer wraps
    pos_t safeLo = 0, safeHi = -1;      // a plain read from here to there (-1: frames)
    int seam = 0;
    float half = 0.f;                   // half of the step at the splice
    static const int SEAM = 240;

    void setLoop(pos_t lo_, pos_t span_) {
        if (frames <= 0) return;
        if (lo_ < 0) lo_ = 0;
        if (lo_ > frames - 1) lo_ = frames - 1;
        if (span_ > frames - lo_) span_ = frames - lo_;
        if (span_ < 64) return;
        lo = lo_; span = span_;
        seam = span / 4 < SEAM ? (int)(span / 4) : SEAM;
        half = 0.5f * (data[lo] - data[lo + span - 1]);
        safeLo = lo + seam; safeHi = lo + span - seam;
    }
    inline pos_t hi() const { return safeHi < 0 ? frames : safeHi; }
    inline bool plain(pos_t from, pos_t to) const { return from >= safeLo && to <= hi(); }
    inline float at(pos_t i) const {
        if (i >= safeLo && i < hi()) return data[i];  // the usual case, with no division
        if (frames <= 0) return 0.f;
        if (span <= 0) {
            i %= frames; if (i < 0) i += frames;
            return data[i];
        }
        pos_t k = (i - lo) % span; if (k < 0) k += span;
        float v = data[lo + k];
        if (k < seam) v -= half * fall((float)k / seam);
        else if (k >= span - seam) v += half * fall((float)(span - 1 - k) / seam);
        return v;
    }
    static inline float fall(float u) { return (1.f - u) * (1.f - u) * (1.f + 2.f * u); }
    // the shortest way from a to b, round the loop
    inline pos_t way(pos_t a, pos_t b) const {
        pos_t d = b - a;
        if (span <= 0) return d;
        d %= span;
        if (d < 0) d += span;
        return d > span / 2 ? d - span : d;
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
        if (b.frames > 0 && b.plain(s, end)) {
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
//   * A grain that reaches the loop's end goes on inside the loop. A grain that
//     continues the last one goes on at the start (so speed 1 stays exact). Any
//     other crosses at a moment of its own, next to grains that did not cross
//     yet, and a tone cancels in that overlap. So it goes on `skip` frames past
//     the start, where the wave looks most like the loop's end.
struct Warp {
    static const int MAXG = 10;
    static const int REACH = 480;        // 10 ms each way
    static const int TPL = 512;          // the template, in frames
    static const int DEC = 4;
    struct Grain { pos_t q; int i; int len; float step; bool on; pos_t skip; };   // step: window table places per sample
    Grain g[MAXG];
    int toNext;
    pos_t cont; bool hasCont;
    float gain;
    Resampler rs;
    uint32_t seed;
    float lastCorr;
    pos_t skipLo, skipSpan, skip;        // the place, for the loop it was found in
    static const int XF = 240;           // the crossing, in frames
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

    // where a grain goes on past the loop's end, in frames from its start (0:
    // the start itself, in a loop too short to search)
    pos_t skipOf(const Buf& bl, const Buf& br) {
        if (bl.span < 4 * (2 * REACH + TPL)) return 0;
        if (bl.lo != skipLo || bl.span != skipSpan) {
            skipLo = bl.lo; skipSpan = bl.span;
            pos_t q = search(bl, br, bl.lo + REACH, bl.lo + bl.span - TPL);
            skip = q + TPL - bl.lo;
            if (skip < TPL) skip = TPL;
        }
        return skip;
    }
    // a place past the loop's end, for a grain that skips
    static inline pos_t past(const Buf& b, pos_t p, pos_t sk) {
        return (sk > 0 && p >= b.lo + b.span) ? p - b.span + sk : p;
    }
    inline float grainAt(const Buf& b, pos_t p, pos_t sk) {
        const pos_t end = b.lo + b.span;
        if (p < b.lo || p >= end + b.span - sk || end > b.frames) return b.at(p);
        if (p >= end) return b.data[p - b.span + sk];
        if (p < end - XF) return b.data[p];
        const float u = (float)(p - (end - XF)) * (1.f / XF);
        return b.data[p] + u * (b.data[p - b.span + sk] - b.data[p]);
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
            pos_t q, sk = 0;
            // how far the last grain's continuation is, round the loop's point
            const pos_t ahead = bl.way(head, cont);
            if (hasCont && std::llabs(ahead) <= REACH) q = head + ahead;
            else {
                q = hasCont ? search(bl, br, head, cont) : head;
                if (bl.span > 0) {
                    q = bl.lo + ((q - bl.lo) % bl.span + bl.span) % bl.span;
                    if (q + len > bl.lo + bl.span) sk = skipOf(bl, br);
                }
            }
            for (int j = 0; j < MAXG; j++) if (!g[j].on) {
                g[j].q = q; g[j].i = 0; g[j].len = len; g[j].step = (float)N / len; g[j].on = true; g[j].skip = sk;
                break;
            }
            cont = past(bl, q + hop, sk); hasCont = true;
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
            if (gr.skip > 0) { l += grainAt(bl, p, gr.skip) * w; r += grainAt(br, p, gr.skip) * w; }
            else if (bl.plain(p, p + 1) && br.plain(p, p + 1)) { l += bl.data[p] * w; r += br.data[p] * w; }
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

// GRAIN's cloud: what two stock GrainBuf UGens did (one on the left buffer,
// one on the right, each panned), as one loop. A grain is a PAIR: it reads
// both buffers at the same place and speed under one window, and each side
// has its own equal-power pan. The laws are GrainBuf's own, so the sound is
// the same: the start is the trigger's sample, the read is the 4-point cubic,
// the built-in window is the Hann that a sine recurrence draws, and a window
// buffer is read between its points. What changed is the work: one window and
// one read place for the pair, and four samples at a time with NEON.
#ifdef FOUR_NEON
// the 4-point cubic of four samples at once. t0..t3 each hold ONE sample's
// four taps; they are turned so that each vector holds one tap of all four.
static inline float32x4_t cubic4(float32x4_t t0, float32x4_t t1, float32x4_t t2, float32x4_t t3,
                                 float32x4_t x) {
    const float32x4x2_t p = vtrnq_f32(t0, t1), q = vtrnq_f32(t2, t3);
    const float32x4_t y0 = vcombine_f32(vget_low_f32(p.val[0]), vget_low_f32(q.val[0]));
    const float32x4_t y1 = vcombine_f32(vget_low_f32(p.val[1]), vget_low_f32(q.val[1]));
    const float32x4_t y2 = vcombine_f32(vget_high_f32(p.val[0]), vget_high_f32(q.val[0]));
    const float32x4_t y3 = vcombine_f32(vget_high_f32(p.val[1]), vget_high_f32(q.val[1]));
    const float32x4_t half = vdupq_n_f32(0.5f);
    const float32x4_t c1 = vmulq_f32(half, vsubq_f32(y2, y0));
    const float32x4_t c2 = vsubq_f32(vaddq_f32(vsubq_f32(y0, vmulq_f32(y1, vdupq_n_f32(2.5f))),
                                               vaddq_f32(y2, y2)), vmulq_f32(half, y3));
    const float32x4_t c3 = vaddq_f32(vmulq_f32(half, vsubq_f32(y3, y0)),
                                     vmulq_f32(vsubq_f32(y1, y2), vdupq_n_f32(1.5f)));
    float32x4_t r = vaddq_f32(vmulq_f32(c3, x), c2);
    r = vaddq_f32(vmulq_f32(r, x), c1);
    return vaddq_f32(vmulq_f32(r, x), y1);
}
#endif

struct Grains {
    static const int MAXG = 128;
    struct G {
        double phase, rate;           // the read place and its step, in frames
        double winPos, winInc;        // the place in a window buffer
        double b1, y1, y2;            // the Hann recurrence (doubles: in floats a long
                                      // grain's 2 cos(w) is 2, and the window a ramp)
        float gL1, gL2, gR1, gR2;     // left sample to out 1 and 2, right sample to out 1 and 2
        int left;                     // samples still to make
    };
    G g[MAXG];
    int n;
    float lastTrig;

    void init() { n = 0; lastTrig = 0.f; }

    static inline float cubic(float x, float y0, float y1, float y2, float y3) {
        float c1 = 0.5f * (y2 - y0);
        float c2 = y0 - 2.5f * y1 + 2.f * y2 - 0.5f * y3;
        float c3 = 0.5f * (y3 - y0) + 1.5f * (y1 - y2);
        return ((c3 * x + c2) * x + c1) * x + y1;
    }

    // `count` samples of one grain, added to outL and outR
    void run(G& gr, float* outL, float* outR, int count, const Buf& bl, const Buf& br,
             const float* win, int winFrames) {
        const int frames = bl.frames < br.frames ? bl.frames : br.frames;
        if (frames < 4) { gr.left = 0; return; }
        const double fmax = (double)frames;
        int i = 0;
        float amp[4];
        while (i < count) {
            // the windows of the next four samples (or fewer at the end)
            const int m = count - i < 4 ? count - i : 4;
            for (int k = 0; k < m; k++) {
                if (win) {
                    int wi = (int)gr.winPos;
                    if (wi > winFrames - 1) wi = winFrames - 1;
                    const float wf = (float)(gr.winPos - (double)wi);
                    const float a = win[wi], b = wi + 1 < winFrames ? win[wi + 1] : win[0];
                    amp[k] = a + wf * (b - a);
                    gr.winPos += gr.winInc;
                } else {
                    amp[k] = (float)(gr.y1 * gr.y1);
                    const double y0 = gr.b1 * gr.y1 - gr.y2;
                    gr.y2 = gr.y1; gr.y1 = y0;
                }
            }
            const double last = gr.phase + gr.rate * (m - 1);
            const double lo = gr.phase < last ? gr.phase : last, hi = gr.phase < last ? last : gr.phase;
#ifdef FOUR_NEON
            if (m == 4 && lo >= 1.0 && hi < fmax - 3.0) {
                // all sixteen taps are inside the buffers: no wrap to think of.
                // Each sample's four taps are loaded as one vector (cubic4).
                const float* dl = bl.data - 1; const float* dr = br.data - 1;
                double ph = gr.phase;
                const int i0 = (int)ph; const float f0 = (float)(ph - (double)i0); ph += gr.rate;
                const int i1 = (int)ph; const float f1 = (float)(ph - (double)i1); ph += gr.rate;
                const int i2 = (int)ph; const float f2 = (float)(ph - (double)i2); ph += gr.rate;
                const int i3 = (int)ph; const float f3 = (float)(ph - (double)i3); ph += gr.rate;
                gr.phase = ph;
                const float fx[4] = {f0, f1, f2, f3};
                const float32x4_t x = vld1q_f32(fx), a = vld1q_f32(amp);
                const float32x4_t l = vmulq_f32(a, cubic4(vld1q_f32(dl + i0), vld1q_f32(dl + i1),
                                                          vld1q_f32(dl + i2), vld1q_f32(dl + i3), x));
                const float32x4_t r = vmulq_f32(a, cubic4(vld1q_f32(dr + i0), vld1q_f32(dr + i1),
                                                          vld1q_f32(dr + i2), vld1q_f32(dr + i3), x));
                const float32x4_t g1 = vdupq_n_f32(gr.gL1), g2 = vdupq_n_f32(gr.gL2);
                const float32x4_t g3 = vdupq_n_f32(gr.gR1), g4 = vdupq_n_f32(gr.gR2);
                vst1q_f32(outL + i, vaddq_f32(vld1q_f32(outL + i), vaddq_f32(vmulq_f32(l, g1), vmulq_f32(r, g3))));
                vst1q_f32(outR + i, vaddq_f32(vld1q_f32(outR + i), vaddq_f32(vmulq_f32(l, g2), vmulq_f32(r, g4))));
                i += 4;
                continue;
            }
#endif
            (void)lo; (void)hi;
            for (int k = 0; k < m; k++) {
                // the plain path: any place, with the buffer read as a loop
                double ph = gr.phase;
                if (ph >= fmax) { ph -= fmax * std::floor(ph / fmax); }
                else if (ph < 0) { ph += fmax * std::ceil(-ph / fmax); if (ph >= fmax) ph -= fmax; }
                const int ip = (int)ph;
                const float x = (float)(ph - (double)ip);
                int i0 = ip - 1; if (i0 < 0) i0 += frames;
                int i2 = ip + 1; if (i2 >= frames) i2 -= frames;
                int i3 = i2 + 1; if (i3 >= frames) i3 -= frames;
                const float l = amp[k] * cubic(x, bl.data[i0], bl.data[ip], bl.data[i2], bl.data[i3]);
                const float r = amp[k] * cubic(x, br.data[i0], br.data[ip], br.data[i2], br.data[i3]);
                outL[i + k] += l * gr.gL1 + r * gr.gR1;
                outR[i + k] += l * gr.gL2 + r * gr.gR2;
                gr.phase = ph + gr.rate;
            }
            i += m;
        }
        gr.left -= count;
    }

    // One block. Each input is one value for each sample. win is the window
    // buffer (winFrames long) or null for the Hann. maxG: the most grains at
    // once (a trigger beyond it starts nothing, without a word).
    void process(float* outL, float* outR, int nsmp, const float* trig, const float* dur,
                 const float* rate, const float* pos, const float* panL, const float* panR,
                 const Buf& bl, const Buf& br, const float* win, int winFrames,
                 int maxG, double sr, double rateScale) {
        std::memset(outL, 0, nsmp * sizeof(float));
        std::memset(outR, 0, nsmp * sizeof(float));
        if (maxG > MAXG) maxG = MAXG;
        for (int j = 0; j < n;) {
            const int c = g[j].left < nsmp ? g[j].left : nsmp;
            run(g[j], outL, outR, c, bl, br, win, winFrames);
            if (g[j].left <= 0) g[j] = g[--n]; else j++;
        }
        const double pi = 3.14159265358979323846;
        for (int i = 0; i < nsmp; i++) {
            const float t = trig[i];
            if (t > 0.f && lastTrig <= 0.f && n < maxG && bl.frames >= 4 && br.frames >= 4) {
                G& gr = g[n];
                double counter = (double)dur[i] * sr;
                if (counter < 4.0) counter = 4.0;
                gr.left = (int)counter;
                gr.rate = (double)rate[i] * rateScale;
                gr.phase = (double)pos[i] * (double)bl.frames;
                if (win) { gr.winPos = 0.0; gr.winInc = (double)winFrames / counter; }
                else {
                    const double w = pi / counter;
                    gr.b1 = 2.0 * std::cos(w); gr.y1 = std::sin(w); gr.y2 = 0.0;
                }
                auto pan = [&](float p, float& g1, float& g2) {
                    p = p * 0.5f + 0.5f;
                    if (p < 0.f) p = 0.f; else if (p > 1.f) p = 1.f;
                    g1 = (float)std::cos((double)p * (pi / 2)); g2 = (float)std::sin((double)p * (pi / 2));
                };
                pan(panL[i], gr.gL1, gr.gL2);
                pan(panR[i], gr.gR1, gr.gR2);
                const int c = gr.left < nsmp - i ? gr.left : nsmp - i;
                run(gr, outL + i, outR + i, c, bl, br, win, winFrames);
                if (gr.left > 0) n++;
            }
            lastTrig = t;
        }
    }
};

// A delay line with a filtered, bounded feedback path, for FLANGE and ECHO.
// The stock comb has neither: its feedback is the bare delayed signal, which
// rings thin and metallic. Here the signal that goes back in passes a one-pole
// low-pass (each pass round the loop is a little darker, as on tape) and a
// soft clip, so high feedback sings without running away.
//   read: 4-point Hermite between the samples, so a moving delay does not click
//   clip: s - (4/27) s^3 up to 1.5, flat at 1 beyond: slope 1 at 0, no corner
struct DelayFb {
    float* line; int mask; int w; float lp, back;
    void init(float* mem, int size) {      // size is a power of two
        line = mem; mask = size - 1; w = 0; lp = 0; back = 0;
        std::memset(mem, 0, size * sizeof(float));
    }
    // d: the delay in samples. k: the low-pass coefficient (0..1).
    inline float tick(float in, float d, float fb, float k) {
        line[w] = in + fb * back;
        if (d < 2.f) d = 2.f;
        if (d > (float)(mask - 4)) d = (float)(mask - 4);
        const int di = (int)d;
        const float fr = d - (float)di;            // the read place is w - di - fr
        const float y0 = line[(w - di + 1) & mask], y1 = line[(w - di) & mask];
        const float y2 = line[(w - di - 1) & mask], y3 = line[(w - di - 2) & mask];
        const float c1 = 0.5f * (y2 - y0);
        const float c2 = y0 - 2.5f * y1 + 2.f * y2 - 0.5f * y3;
        const float c3 = 0.5f * (y3 - y0) + 1.5f * (y1 - y2);
        const float y = ((c3 * fr + c2) * fr + c1) * fr + y1;
        lp += k * (y - lp) + 1e-25f;       // (the small term keeps denormals out)
        float s = lp;
        if (s > 1.5f) s = 1.5f; else if (s < -1.5f) s = -1.5f;
        back = s - (4.f / 27.f) * s * s * s;
        w = (w + 1) & mask;
        return y;
    }
};

// THE ROOM (doc/space-plan.md, sections 5 and 12). Stereo in, stereo out, the
// wet sound only.
//   1. The input spreads to 8 channels.
//   2. Four diffusion steps. Each one delays every channel by its own time,
//      flips the sign of some, and mixes all 8 with a Hadamard matrix. Each
//      step turns one echo into 8, so one click is 4096 echoes after the four.
//      Every step is unitary: it changes no energy.
//   3. The late field: 8 delay lines that feed each other through a Householder
//      matrix (unitary). With no loss in the lines the energy is constant, so
//      ALL the decay comes from the loss filters, and it is the decay we set.
//   4. The loss of a line of m samples is 10^(-3 m / (fs T60)) at 0 Hz, and a
//      one-pole low-pass (Jot's form) makes the high frequencies die sooner by
//      the ratio `colour` (T60 at fs/2 against T60 at 0 Hz). The loss in dB is
//      in proportion to m, so every line decays at one rate.
struct Room {
    static const int CH = 8, STEPS = 4;
    static const int DMAX = 4096;        // a diffusion delay, at most (85 ms)
    static const int LMAX = 16384;       // a late line, at most (341 ms)
    // Each buffer gets a gap of its own size after it. Forty buffers that sit
    // exactly 32 kB apart all want the same places in the cache, and the first
    // build took 23% of a norns core for that reason alone.
    static int gap(int k) { return 16 * (3 + (k * 7) % 29); }
    static size_t need() {
        size_t n = 0;
        for (int k = 0; k < STEPS * CH; k++) n += DMAX + gap(k);
        for (int k = 0; k < CH; k++) n += LMAX + gap(40 + k);
        return n;
    }

    float* dbuf[STEPS][CH]; int dlen[STEPS][CH]; float dsign[STEPS][CH];
    float* lbuf[CH]; int llen[CH];
    int dw, lw;                          // write places (one for each kind)
    float b0[CH], b1[CH], a1[CH], zx[CH], zy[CH];   // each line's loss: a first-order shelf
    double fs;

    static inline void hadamard(float* x) {      // 8 in place, scaled to unitary
        for (int h = 1; h < CH; h <<= 1)
            for (int i = 0; i < CH; i += h << 1)
                for (int j = i; j < i + h; j++) {
                    const float a = x[j], c = x[j + h];
                    x[j] = a + c; x[j + h] = a - c;
                }
        for (int i = 0; i < CH; i++) x[i] *= 0.35355339f;      // 1/sqrt(8)
    }

    // mem: need() floats. size: the base time of the diffusion in seconds
    // (0.005 is a middle room) and it scales the late lines too.
    void init(float* mem, double sampleRate, double size) {
        fs = sampleRate; dw = lw = 0;
        std::memset(mem, 0, need() * sizeof(float));
        uint32_t seed = 0x9E3779B9u;
        auto rnd = [&]() { seed ^= seed << 13; seed ^= seed >> 17; seed ^= seed << 5; return (seed & 0xffffff) / 16777216.0; };
        for (int k = 0; k < STEPS; k++) {
            const double span = size * (double)(1 << k) * fs;   // this step's longest delay
            for (int c = 0; c < CH; c++) {
                dbuf[k][c] = mem; mem += DMAX + gap(k * CH + c);
                int n = (int)(span * (c + rnd()) / CH) + 1;      // one in each eighth of the span
                dlen[k][c] = n > DMAX - 1 ? DMAX - 1 : n;
                dsign[k][c] = rnd() < 0.5 ? -1.f : 1.f;
            }
        }
        for (int c = 0; c < CH; c++) {
            lbuf[c] = mem; mem += LMAX + gap(40 + c);
            // 100 ms to 183 ms at the middle size, in equal ratios: no two near
            int n = (int)(fs * 0.100 * std::pow(2.0, (double)c / CH) * (size / 0.005) * 0.7 + 0.3 * fs * 0.100 * std::pow(2.0, (double)c / CH));
            n |= 1;                                              // odd: fewer common factors
            llen[c] = n > LMAX - 1 ? LMAX - 1 : n;
            b0[c] = 1.f; b1[c] = 0.f; a1[c] = 0.f; zx[c] = 0.f; zy[c] = 0.f;
        }
    }

    // decay: T60 at 0 Hz, in seconds (0 or less: no loss at all, for the proof).
    // colour: T60 at the top against T60 at 0 Hz, 1 (bright) down to 0.1 (dark).
    // cross: where the decay is half way between the two, in Hz.
    //
    // A line of m samples must lose 60 dB in T60(f) seconds at EVERY frequency:
    //   |H(f)| = 10^(-3 m / (fs T60(f)))
    // H is G times a first-order shelf from 1 (at 0 Hz) to R (at the top), with
    // its middle, sqrt(R), at `cross` for any R:
    //   H(s) = G (R s + w sqrt(R)) / (s + w sqrt(R))
    // The dB of such a shelf are close to proportional to the dB of R, and the
    // dB of R are proportional to m, so all 8 lines decay at one rate at every
    // frequency (the test reads the largest difference).
    void setDecay(double decay, double colour, double cross = 4000.0) {
        if (colour > 1) colour = 1;
        if (colour < 0.05) colour = 0.05;
        const double t = std::tan(3.14159265358979323846 * cross / fs);
        for (int c = 0; c < CH; c++) {
            if (!(decay > 0)) { b0[c] = 1.f; b1[c] = 0.f; a1[c] = 0.f; continue; }
            const double lg = -3.0 * llen[c] / (fs * decay);     // log10 of the gain at 0 Hz
            const double G = std::pow(10.0, lg), R = std::pow(10.0, lg / colour - lg);
            const double q = t * std::sqrt(R), n = 1.0 / (1.0 + q);
            b0[c] = (float)(G * (R + q) * n); b1[c] = (float)(G * (q - R) * n); a1[c] = (float)((q - 1.0) * n);
        }
    }
    // the designed T60 of line c at frequency f (what a test compares with)
    double designT60(int c, double f) const {
        const double w = 2 * 3.14159265358979323846 * f / fs, cw = std::cos(w);
        const double num = (double)b0[c] * b0[c] + (double)b1[c] * b1[c] + 2.0 * b0[c] * b1[c] * cw;
        const double den = 1.0 + (double)a1[c] * a1[c] + 2.0 * a1[c] * cw;
        return -3.0 * llen[c] / (fs * 0.5 * std::log10(num / den));
    }
    // the energy held in the late lines (the lossless proof reads this)
    double energy() const {
        double e = 0;
        // only what a line still holds: its last llen samples
        for (int c = 0; c < CH; c++)
            for (int i = 1; i <= llen[c]; i++) { const float v = lbuf[c][(lw - i) & (LMAX - 1)]; e += (double)v * v; }
        return e;
    }

    inline void tick(float inL, float inR, float& outL, float& outR) {
        float x[CH];
        // each side to four channels at half level: the energy in is the input's
        for (int c = 0; c < CH; c++) x[c] = ((c & 1) ? inR : inL) * 0.5f;
        for (int k = 0; k < STEPS; k++) {
            for (int c = 0; c < CH; c++) {
                dbuf[k][c][dw] = x[c];
                x[c] = dbuf[k][c][(dw - dlen[k][c]) & (DMAX - 1)] * dsign[k][c];
            }
            hadamard(x);
        }
        float d[CH], sum = 0;
        for (int c = 0; c < CH; c++) {
            const float v = lbuf[c][(lw - llen[c]) & (LMAX - 1)];
            const float y = b0[c] * v + b1[c] * zx[c] - a1[c] * zy[c] + 1e-25f;   // (the small term keeps denormals out)
            zx[c] = v; zy[c] = y;
            d[c] = y; sum += y;
        }
        sum *= 2.f / CH;                                          // Householder: d - (2/8) sum
        float l = 0, r = 0;
        for (int c = 0; c < CH; c++) {
            const float v = x[c] + d[c] - sum;
            lbuf[c][lw] = v;
            // the output is what goes INTO the lines: the diffused sound at
            // once (the room's first build-up) and each return of the field
            if (c & 1) r += v; else l += v;
        }
        outL = l * 0.5f; outR = r * 0.5f;
        dw = (dw + 1) & (DMAX - 1); lw = (lw + 1) & (LMAX - 1);
    }
};

// THE BUCKET BRIGADE (doc/space-plan.md, section 4). A chain of `half` cells
// that a clock of f_c moves one cell for each tick, so the delay is
// half / f_c. Before the chain an anti-alias filter, after it a
// reconstruction filter, both third-order Butterworth low-passes whose corner
// follows the clock: a long delay is a slow clock and a dark sound.
//
// The ticks do not sit on the host's samples, so the two filters are solved
// in continuous time (Holters and Parker, 2018). Each filter is
//   H(s) = w^3 / ((s + w)(s^2 + w s + w^2)) = r1/(s - p1) + r2/(s - p2) + conj
//   p1 = -w, p2 = w(-1/2 + j sqrt(3)/2), r1 = w, r2 = w(-1/2 - j/(2 sqrt(3)))
// and each part's state x obeys x' = p x + u. For an input u held over a time
// D the step is exact:  x <- e^(pD) x + (e^(pD) - 1)/p * u.
//   input filter: u is the host's sample, held for one sample period. At a
//     tick inside the sample the state is advanced to the tick and read.
//   output filter: u is the chain's output, held from tick to tick. It is
//     advanced tick by tick and read at the host's sample.
// So the model has the sampling of the device (images at k f_c +- f) and its
// staircase, and nothing else is approximated but "held between samples".
struct BBD {
    float* ring; int half, w;
    double ph, inc;                    // the place in a tick (0..1), and ticks for each sample
    double ia, ibr, ibi, oa, obr, obi; // the two filters: a real state and a complex one
    double hold;                       // what the chain puts out now
    double om, E1, E2r, E2i;           // the corner (rad/s) and one whole sample's step
    double T1, T2r, T2i;               // one whole tick's step (1/inc samples)
    double fs;

    void init(float* mem, int cells, double sampleRate) {   // cells: a power of two
        ring = mem; half = cells; w = 0; fs = sampleRate;
        std::memset(mem, 0, cells * sizeof(float));
        ph = 0; ia = ibr = ibi = oa = obr = obi = 0; hold = 0;
        om = 0; inc = 0; setClock(12000.0, 0.35);
    }
    // fc: the clock in Hz. ratio: the filters' corner as a share of the clock.
    // The corner stops at 8.4 kHz, so a fast clock folds nothing into hearing.
    void setClock(double fc, double ratio) {
        const double newInc = fc / fs;
        double corner = ratio * fc;
        if (corner > 8400.0) corner = 8400.0;
        const double o = 2 * 3.14159265358979323846 * corner;
        if (o == om && newInc == inc) return;
        inc = newInc;
        if (o != om) {
            om = o;
            const double x = om / fs, m = std::exp(-0.5 * x);
            E1 = m * m; E2r = m * std::cos(0.8660254037844386 * x); E2i = m * std::sin(0.8660254037844386 * x);
        }
        // the step of one whole tick. Every tick after the first in a sample
        // is this long, so tick() computes only the first one's exponentials.
        // At a 43 ms delay the clock makes 4 ticks a sample, and this took
        // 44% off the cost on the Mac with the same output (test_core).
        const double x = (om / fs) * (1.0 / inc), m = std::exp(-0.5 * x);
        T1 = m * m; T2r = m * std::cos(0.8660254037844386 * x); T2i = m * std::sin(0.8660254037844386 * x);
    }
    // one filter, advanced by a step whose exponentials are (e1, e2r + j e2i), input u
    inline void adv(double& a, double& br, double& bi, double e1, double e2r, double e2i, double u) const {
        a = e1 * a + (1.0 - e1) / om * u;
        // (e2 - 1)/p2, with 1/p2 = (-1/2 - j sqrt(3)/2)/w
        const double gr = ((e2r - 1.0) * -0.5 + e2i * 0.8660254037844386) / om;
        const double gi = ((e2r - 1.0) * -0.8660254037844386 + e2i * -0.5) / om;
        const double nr = e2r * br - e2i * bi + gr * u;
        bi = e2r * bi + e2i * br + gi * u; br = nr;
    }
    static inline double read(double om, double a, double br, double bi) {
        return om * (a - br + 0.5773502691896258 * bi);      // r1 x1 + 2 Re(r2 x2)
    }
    inline float tick(float in) {
        // (the small term: in silence the states fall into the denormal range,
        // where each operation on the norns takes a hundred times as long)
        const double u = (double)in + 1e-15;
        const int nt = (int)(ph + inc);
        if (nt == 0) {
            adv(ia, ibr, ibi, E1, E2r, E2i, u);
            adv(oa, obr, obi, E1, E2r, E2i, hold);
            ph += inc;
        } else {
            double P1 = 1, Pr = 1, Pi = 0;                 // the product of the steps so far
            for (int k = 1; k <= nt; k++) {
                // the first tick comes (1 - ph) / inc into the sample, each
                // later one a whole tick after the last (T1, T2 of setClock)
                double e1 = T1, e2r = T2r, e2i = T2i;
                if (k == 1) {
                    const double xD = (om / fs) * ((1.0 - ph) / inc), m = std::exp(-0.5 * xD);
                    e1 = m * m; e2r = m * std::cos(0.8660254037844386 * xD); e2i = m * std::sin(0.8660254037844386 * xD);
                }
                adv(ia, ibr, ibi, e1, e2r, e2i, u);
                adv(oa, obr, obi, e1, e2r, e2i, hold);
                hold = (double)ring[w] + 1e-15;                 // what went in `half` ticks ago
                ring[w] = (float)read(om, ia, ibr, ibi);
                w = (w + 1) & (half - 1);
                P1 *= e1; const double q = Pr * e2r - Pi * e2i; Pi = Pr * e2i + Pi * e2r; Pr = q;
            }
            // the rest of the sample: the whole step divided by the steps taken
            const double e1 = E1 / P1, n2 = Pr * Pr + Pi * Pi;
            const double e2r = (E2r * Pr + E2i * Pi) / n2, e2i = (E2i * Pr - E2r * Pi) / n2;
            adv(ia, ibr, ibi, e1, e2r, e2i, u);
            adv(oa, obr, obi, e1, e2r, e2i, hold);
            ph = ph + inc - nt;
        }
        return (float)read(om, oa, obr, obi);
    }
    // the whole delay in seconds for a clock: the chain, its hold, both filters
    static double seconds(int cells, double fc, double corner) {
        return cells / fc + 0.5 / fc + 2.0 * 2.0 / (2 * 3.14159265358979323846 * corner);
    }
};

// The delay made of it: the clock is set so that an echo lands after `time`
// (the filters' own delay is taken off), and the loop goes back in through a
// 30 Hz high-pass and a soft clip.
//
// AGE (0 to 1) adds what an old unit has around its chip, and at 0 none of it
// runs:
//   a compressor before the chain and an expander after it (the NE570 pair).
//     compressor:  y = x / avg(|y|)     (a 2:1 law in dB)
//     expander:    z = w * avg(|w|)     (a 1:2 law)
//     avg is a one-pole of 10 ms. The compressor's equation holds its own
//     output, and for a one-pole it has an exact answer:
//       c = (1 - k) a[n-1],  a[n] = (c + sqrt(c^2 + 4 k |x|)) / 2,  y = x / a[n]
//     With a clean path between them the pair is an identity. What makes the
//     sound is what sits between them:
//   the chain's noise, added after the compressor. The expander pushes it
//     down in the quiet and lets it rise behind each note.
//   the rails: a clip at the chain's input, exactly linear up to 1 and
//     smooth to 1.5 beyond, which catches the compressor's attacks.
struct BBDDelay {
    BBD chain; double hpx, hpy, back;
    double ca, ea, k;                  // the two averages and their coefficient
    uint32_t seed;
    void init(float* mem, int cells, double sampleRate) {
        chain.init(mem, cells, sampleRate); hpx = hpy = back = 0;
        ca = ea = 1.0; k = 1.0 - std::exp(-1.0 / (0.010 * sampleRate)); seed = 22222u;
    }
    // time in seconds, tone: the corner as a share of the clock (0.2..0.45)
    inline void set(double time, double tone) {
        // cells/fc + 0.5/fc + 2/(pi tone fc) = time, while the corner follows the clock
        double fc = (chain.half + 0.5 + 2.0 / (3.14159265358979323846 * tone)) / time;
        if (tone * fc > 8400.0) {          // the corner stands still: its delay is fixed
            const double rest = time - 2.0 * 2.0 / (2 * 3.14159265358979323846 * 8400.0);
            fc = (chain.half + 0.5) / (rest > 1e-4 ? rest : 1e-4);
        }
        if (fc > 4.0 * chain.fs) fc = 4.0 * chain.fs;
        chain.setClock(fc, tone);
    }
    static inline double rails(double s) {
        const double a = s < 0 ? -s : s;
        if (a <= 1.0) return s;
        const double v = 1.0 + 0.5 * std::tanh((a - 1.0) * 2.0);
        return s < 0 ? -v : v;
    }
    // fb -0.98..0.98, age 0..1
    inline float tick(float in, float fb, float age) {
        double x = (double)in + fb * back;
        if (age > 0.f) {
            const double ax = x < 0 ? -x : x, c = (1.0 - k) * ca;
            ca = 0.5 * (c + std::sqrt(c * c + 4.0 * k * ax));
            if (ca < 0.03) ca = 0.03;                 // the floor: the largest gain is 30 dB
            x = x / ca;
            seed ^= seed << 13; seed ^= seed >> 17; seed ^= seed << 5;
            x += (double)age * 3.2e-4 * ((double)(seed & 0xffffff) / 8388608.0 - 1.0);   // -70 dB at AGE 1
            x = rails(x);
        }
        double y = chain.tick((float)x);
        if (age > 0.f) {
            const double ay = y < 0 ? -y : y;
            ea += k * (ay - ea);
            y *= ea < 0.03 ? 0.03 : ea;
        }
        const double hp = y - hpx + 0.99608 * hpy;           // 30 Hz at 48 kHz
        hpx = y; hpy = hp + 1e-25;
        double s2 = hp;
        if (s2 > 1.5) s2 = 1.5; else if (s2 < -1.5) s2 = -1.5;
        back = s2 - (4.0 / 27.0) * s2 * s2 * s2;
        return (float)y;
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
