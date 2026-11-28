// The proof of four_core.h, with no SuperCollider, and a smoke test of the
// Clouds core of FourCloud (four_cloud.h). Build and run:
//   clang++ -O2 -std=c++17 -Iugen/vendor/eurorack -o /tmp/test_core ugen/test_core.cpp && /tmp/test_core
#include "four_core.h"
#include "four_cloud.h"
#include <algorithm>
#include <functional>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <new>
#include <vector>
#include <random>
using namespace four;
static int fails = 0;
static void expect(bool ok, const char* what, double v) {
    std::printf("  %-58s %10.2f  %s\n", what, v, ok ? "ok" : "FAIL");
    if (!ok) fails++;
}
static double db(double x) { return 20 * std::log10(x > 1e-15 ? x : 1e-15); }
static const double PI = 3.14159265358979323846;

// BBD::tick as it was before 2026-11-15: every tick computes its own step.
// The present tick() computes only the first tick of a sample; this is the
// reference it must equal.
struct RefBBD : BBD {
    float tickRef(float in) {
        const double u = (double)in + 1e-15;
        const int nt = (int)(ph + inc);
        if (nt == 0) {
            adv(ia, ibr, ibi, E1, E2r, E2i, u); adv(oa, obr, obi, E1, E2r, E2i, hold); ph += inc;
        } else {
            double t = 0, P1 = 1, Pr = 1, Pi = 0;
            const double x = om / fs;
            for (int k = 1; k <= nt; k++) {
                const double d = ((double)k - ph) / inc, D = d - t;
                const double m = std::exp(-0.5 * x * D), e1 = m * m;
                const double e2r = m * std::cos(0.8660254037844386 * x * D), e2i = m * std::sin(0.8660254037844386 * x * D);
                adv(ia, ibr, ibi, e1, e2r, e2i, u); adv(oa, obr, obi, e1, e2r, e2i, hold);
                hold = (double)ring[w] + 1e-15; ring[w] = (float)read(om, ia, ibr, ibi); w = (w + 1) & (half - 1);
                P1 *= e1; const double q = Pr * e2r - Pi * e2i; Pi = Pr * e2i + Pi * e2r; Pr = q;
                t = d;
            }
            const double e1 = E1 / P1, n2 = Pr * Pr + Pi * Pi;
            const double e2r = (E2r * Pr + E2i * Pi) / n2, e2i = (E2i * Pr - E2r * Pi) / n2;
            adv(ia, ibr, ibi, e1, e2r, e2i, u); adv(oa, obr, obi, e1, e2r, e2i, hold);
            ph = ph + inc - nt;
        }
        return (float)read(om, oa, obr, obi);
    }
};

// runs the PV: head from p0 at `speed` frames per sample, block 64
static void run(const std::vector<float>& L, const std::vector<float>& R, double p0, double speed,
                float pitch, int n, std::vector<float>& oL, std::vector<float>& oR) {
    static PV pv; pv.init();
    Buf bl{L.data(), (int)L.size()}, br{R.data(), (int)R.size()};
    oL.assign(n, 0); oR.assign(n, 0);
    std::vector<float> pos(64);
    double p = p0;
    for (int i = 0; i + 64 <= n; i += 64) {
        for (int j = 0; j < 64; j++) { pos[j] = (float)std::floor(p + 0.5); p += speed; }
        pv.process(&oL[i], &oR[i], 64, pos.data(), pitch, bl, br);
    }
}
// level of the bin at f and of everything else, by projection on a Hann window
static void tone(const std::vector<float>& x, int a, int b, double f, double sr, double& lv, double& off) {
    double sr_ = 0, si = 0, e = 0, wsum = 0, w2 = 0;
    int n = b - a;
    for (int i = 0; i < n; i++) {
        double w = 0.5 - 0.5 * std::cos(2 * PI * i / n);
        double v = x[a + i] * w;
        sr_ += v * std::cos(2 * PI * f * i / sr); si += v * std::sin(2 * PI * f * i / sr);
        e += v * v; wsum += w; w2 += w * w;
    }
    double amp = 2 * std::sqrt(sr_ * sr_ + si * si) / wsum;
    double toneE = amp * amp / 2 * w2;
    lv = db(amp); off = 10 * std::log10(std::fmax(e - toneE, 1e-30) / e);
}

// THE CLOUD: the Clouds core run the way FourCloud runs it (FourStretch.cpp):
// constructed then zeroed, the same two buffers, the core at 48 kHz, and
// Process then Prepare on each block of 32 frames. The settings are the
// engine's CLOUD at rest: size 0.1 s, density 20, texture 0.5, all wet.
struct CloudRun {
    std::vector<uint8_t> large = std::vector<uint8_t>(118784), small = std::vector<uint8_t>(65536 - 128);
    alignas(16) unsigned char mem[sizeof(clouds::GranularProcessor)];
    clouds::GranularProcessor* gp = nullptr;
    clouds::FloatFrame in[32], out[32];
    void init() {
        gp = new (mem) clouds::GranularProcessor;
        std::memset(static_cast<void*>(gp), 0, sizeof(clouds::GranularProcessor));
        gp->Init(large.data(), large.size(), small.data(), small.size());
        gp->set_sample_rate(48000.f);
        gp->set_num_channels(2);
        gp->set_low_fidelity(false);
        gp->set_playback_mode(clouds::PLAYBACK_MODE_GRANULAR);
        clouds::Parameters* p = gp->mutable_parameters();
        p->pitch = 0.f; p->position = 0.5f; p->size = 0.247f; p->density = 0.185f;
        p->texture = 0.5f; p->dry_wet = 1.f; p->stereo_spread = 0.5f;
        p->reverb = 0.f; p->feedback = 0.f; p->freeze = false; p->trigger = false;
    }
    void block(const float* l, const float* r, float* oL, float* oR) {
        for (int i = 0; i < 32; i++) { in[i].l = l[i]; in[i].r = r[i]; }
        gp->Process(in, out, 32);
        gp->Prepare();
        for (int i = 0; i < 32; i++) { oL[i] = out[i].l; oR[i] = out[i].r; }
    }
};

// runs a cloud for `secs`: a 1 kHz sine at 0.25 (-12 dBFS) in until `until`
// seconds, silence after it. `at` changes the settings at a time. Reports
// whether every value was finite, how many were subnormal, the RMS of
// [a0, a1) and [b0, b1) in dBFS, the peak, and the mean cost of a block in
// [a0, a1) and in [b0, b1).
struct CloudReport { bool finite; long subnormal; double levA, levB, peak, costA, costB; };
template <typename F>
static CloudReport cloudRun(CloudRun& c, double secs, double until, double a0, double a1,
                            double b0, double b1, F at) {
    typedef std::chrono::steady_clock clk;
    const double sr = 48000;
    CloudReport r{true, 0, 0, 0, 0, 0, 0};
    double eA = 0, eB = 0, tA = 0, tB = 0; long nA = 0, nB = 0, kA = 0, kB = 0;
    float l[32], rr[32], oL[32], oR[32];
    const long n = (long)(secs * sr);
    for (long i = 0; i + 32 <= n; i += 32) {
        const double t = i / sr;
        at(c, t);
        for (int j = 0; j < 32; j++) {
            const double ph = 2 * PI * 1000.0 * (double)(i + j) / sr;
            l[j] = t < until ? 0.25f * (float)std::sin(ph) : 0.f;
            rr[j] = t < until ? 0.25f * (float)std::sin(ph + 1.0) : 0.f;
        }
        const auto t0 = clk::now();
        c.block(l, rr, oL, oR);
        const double cost = std::chrono::duration<double>(clk::now() - t0).count();
        for (int j = 0; j < 32; j++) {
            for (float y : {oL[j], oR[j]}) {
                if (!std::isfinite(y)) r.finite = false;
                if (std::fpclassify(y) == FP_SUBNORMAL) r.subnormal++;
                if (std::fabs(y) > r.peak) r.peak = std::fabs(y);
                if (t >= a0 && t < a1) { eA += (double)y * y; nA++; }
                if (t >= b0 && t < b1) { eB += (double)y * y; nB++; }
            }
        }
        if (t >= a0 && t < a1) { tA += cost; kA++; }
        if (t >= b0 && t < b1) { tB += cost; kB++; }
    }
    r.levA = 10 * std::log10(eA / (nA ? nA : 1) + 1e-30);
    r.levB = 10 * std::log10(eB / (nB ? nB : 1) + 1e-30);
    r.costA = tA / (kA ? kA : 1); r.costB = tB / (kB ? kB : 1);
    return r;
}

int main() {
    const double sr = 48000;
    std::mt19937 rng(7); std::normal_distribution<float> nd(0, 0.1f);
    int len = 48000 * 6;
    std::vector<float> nL(len), nR(len), sL(len), sR(len), oL, oR;
    for (int i = 0; i < len; i++) {
        nL[i] = nd(rng); nR[i] = nd(rng);
        sL[i] = 0.5f * (float)std::sin(2 * PI * 1000.0 * i / sr);
        sR[i] = 0.25f * (float)std::sin(2 * PI * 1000.0 * i / sr + 1.0);
    }
    std::printf("PV core\n");
    {   // 1. identity at speed 1, on stereo noise
        int n = 48000 * 2; run(nL, nR, 20000, 1.0, 1.0f, n, oL, oR);
        int delay = N + H; double err = 0, ref = 0;
        for (int i = 8192; i < n - 64; i++) {
            pos_t src = 20000 + (i - delay);
            double d = oL[i] - nL[src], d2 = oR[i] - nR[src];
            err += d * d + d2 * d2; ref += nL[src] * nL[src] + nR[src] * nR[src];
        }
        expect(db(std::sqrt(err / ref)) < -90, "speed 1: residual against the take, dB", db(std::sqrt(err / ref)));
    }
    for (double sp : {0.5, 0.25, 0.0, -1.0, 2.0}) {   // 2. a sine stays one sine
        int n = 48000 * 2; run(sL, sR, 100000, sp, 1.0f, n, oL, oR);
        double lv, off; tone(oL, 24000, 24000 + 65536, 1000, sr, lv, off);
        char what[96]; std::snprintf(what, 96, "speed %.2f: 1 kHz sine, energy off the tone, dB", sp);
        expect(off < -50, what, off);
        std::snprintf(what, 96, "speed %.2f: level, dBFS (the take is -6.02)", sp);
        expect(std::fabs(lv + 6.02) < 0.5, what, lv);
        // the stereo image: level and phase of R against L
        double a = 0, b = 0, c = 0, d = 0;
        for (int i = 24000; i < 24000 + 48000; i++) {
            double ph = 2 * PI * 1000.0 * i / sr;
            a += oL[i] * std::cos(ph); b += oL[i] * std::sin(ph);
            c += oR[i] * std::cos(ph); d += oR[i] * std::sin(ph);
        }
        double dphi = std::atan2(c, d) - std::atan2(a, b);
        while (dphi > PI) dphi -= 2 * PI; while (dphi < -PI) dphi += 2 * PI;
        std::snprintf(what, 96, "speed %.2f: phase of R against L, rad (the take is 1.0)", sp);
        expect(std::fabs(dphi - 1.0) < 0.02, what, dphi);
    }
    for (double pr : {2.0, 1.4983, 0.5}) {   // 3. pitch, independent of speed
        int n = 48000 * 2; run(sL, sR, 100000, 0.5, (float)pr, n, oL, oR);
        double lv, off; tone(oL, 24000, 24000 + 65536, 1000 * pr, sr, lv, off);
        char what[96]; std::snprintf(what, 96, "pitch %.3f at speed 0.5: energy off the tone, dB", pr);
        expect(off < -50, what, off);
        std::snprintf(what, 96, "pitch %.3f at speed 0.5: level, dBFS", pr);
        expect(std::fabs(lv + 6.02) < 0.5, what, lv);
    }
    {   // 4. no fold: 15 kHz at pitch 2 must vanish, not land on 18 kHz
        std::vector<float> h(len);
        for (int i = 0; i < len; i++) h[i] = 0.5f * (float)std::sin(2 * PI * 15000.0 * i / sr);
        int n = 48000 * 2; run(h, h, 100000, 1.0, 2.0f, n, oL, oR);
        double lv, off; tone(oL, 24000, 24000 + 65536, 18000, sr, lv, off);
        expect(lv < -60, "pitch 2: a 15 kHz tone folded to 18 kHz, dBFS", lv);
        for (int i = 0; i < len; i++) h[i] = 0.5f * (float)std::sin(2 * PI * 10000.0 * i / sr);
        run(h, h, 100000, 1.0, 0.5f, n, oL, oR);
        tone(oL, 24000, 24000 + 65536, 19000, sr, lv, off);
        expect(lv < -70, "pitch 0.5: the image of a 10 kHz tone at 19 kHz, dBFS", lv);
    }
    {   // 5. an attack stays sharp at speed 0.25
        std::vector<float> c(len, 0.f);
        for (int i = 0; i < 4800; i++) c[150000 + i] = nd(rng) * 5 * std::exp(-i / 800.0f);
        int n = 48000 * 2; run(c, c, 150000 - 12000, 0.25, 1.0f, n, oL, oR);
        // the head reaches the attack after 12000/0.25 samples, plus the delay
        int at = 48000 + N + H; double pre = 0, post = 0;
        for (int i = at - 2400; i < at - 600; i++) pre += oL[i] * oL[i];
        for (int i = at; i < at + 1800; i++) post += oL[i] * oL[i];
        expect(10 * std::log10((pre + 1e-12) / (post + 1e-12)) < -30, "speed 0.25: energy before the attack against after, dB",
               10 * std::log10((pre + 1e-12) / (post + 1e-12)));
    }


    // THE LOOP'S POINT: a take of 1.2 s with silence around it, as a fresh take
    // has. The frames and the grains must wrap in the loop: no hole, no click.
    std::printf("the loop\n");
    {
        const pos_t lo = 30000, span = 57600 + 37;
        std::vector<float> tL(200000, 0.f), tR(200000, 0.f), zL(200000, 0.f), zR(200000, 0.f);
        for (pos_t i = 0; i < span; i++) {
            tL[lo + i] = 0.25f * (float)std::sin(2 * PI * 441.7 * i / 48000); tR[lo + i] = 0.6f * tL[lo + i];
            zL[lo + i] = nL[20000 + i]; zR[lo + i] = nR[20000 + i];
        }
        auto runL = [&](int kind, const std::vector<float>& L, const std::vector<float>& R, double speed,
                        float pitch, bool loop, int n) {
            static PV pv; static Warp w; pv.init(); w.init();
            std::vector<float> a(n, 0), b(n, 0), pos(64); double p = 0;
            for (int i = 0; i + 64 <= n; i += 64) {
                Buf bl{L.data(), (int)L.size()}, br{R.data(), (int)R.size()};
                if (loop) { bl.setLoop(lo, span); br.setLoop(lo, span); }
                for (int j = 0; j < 64; j++) {
                    pos[j] = (float)(lo + (pos_t)std::floor(p));
                    p += speed; if (p >= span) p -= span; if (p < 0) p += span;
                }
                if (kind == 0) pv.process(&a[i], &b[i], 64, pos.data(), pitch, bl, br);
                else w.process(&a[i], &b[i], 64, pos.data(), pitch, 12000, 4, 0.f, bl, br);
            }
            return a;
        };
        for (int mat = 0; mat < 2; mat++) for (int kind = 0; kind < 2; kind++) for (double sp : {1.0, 0.5, -1.0, 1.7}) for (float pi : {1.f, 2.f}) {
            for (int loop = 0; loop < 2; loop++) {
                int n = 48000 * 8; auto o = mat ? runL(kind, zL, zR, sp, pi, loop, n) : runL(kind, tL, tR, sp, pi, loop, n);
                std::vector<double> lv; double d2 = 0;
                for (int c = 48000; c + 960 < n - 960; c += 240) {
                    double e = 0; for (int i = 0; i < 960; i++) e += o[c + i] * o[c + i];
                    lv.push_back(std::sqrt(e / 960));
                }
                for (int i = 48000; i < n - 1000; i++) d2 = std::fmax(d2, std::fabs(o[i] - 2 * o[i - 1] + o[i - 2]));
                std::vector<double> sorted = lv; std::sort(sorted.begin(), sorted.end());
                double dip = db(sorted.front() / sorted[sorted.size() / 2]);
                int wide = 0; for (double v : lv) if (db(v / sorted[sorted.size() / 2]) < -6) wide++;
                double turns = std::fmax(1.0, (n - 48000) * std::fabs(sp) / span);
                char what[96]; std::snprintf(what, 96, "%s %s %.1f pitch %.0f%s: deepest 20 ms, dB", mat ? "noise" : "tone", kind ? "WARP" : "PV",
                    sp, pi, loop ? "" : " (no loop)");
                if (loop) expect(dip > (kind && !mat ? -9 : -3), what, dip); else std::printf("  %-58s %10.2f\n", what, dip);
                std::printf("     second difference x1000 %.2f, under -6 dB %.1f ms a turn\n", d2 * 1000, wide * 5 / turns);
            }
        }
        // a short loop under a long grain, and a window that moves: no click
        {
            auto worst = [&](int how) {
                static Warp w; w.init();
                const int n = 48000 * 8; double p = 0, d2 = 0; float y1 = 0, y2 = 0;
                std::vector<float> tone(400000), a(64), b(64), pos(64);
                for (size_t i = 0; i < tone.size(); i++) tone[i] = 0.25f * (float)std::sin(2 * PI * 441.7 * i / 48000);
                for (int i = 0; i + 64 <= n; i += 64) {
                    double f = (double)i / n;
                    pos_t l = 20000, sp = 6037;
                    if (how == 1) { l = 20000 + (pos_t)(f * 100000); sp = 120000; }
                    if (how == 2) sp = 200000 - (pos_t)(f * 100000);
                    Buf bl{tone.data(), (int)tone.size()}, br{tone.data(), (int)tone.size()};
                    bl.setLoop(l, sp); br.setLoop(l, sp);
                    for (int j = 0; j < 64; j++) { pos[j] = (float)(l + (pos_t)p); p += 0.7; if (p >= sp) p -= sp; }
                    w.process(a.data(), b.data(), 64, pos.data(), 1.f, 12000, 4, 0.f, bl, br);
                    for (int j = 0; j < 64; j++) {
                        if (i > 24000) d2 = std::fmax(d2, std::fabs(a[j] - 2 * y1 + y2));
                        y2 = y1; y1 = a[j];
                    }
                }
                return d2 * 1000;
            };
            const char* what[] = {"WARP in a loop of 126 ms: second difference, x1000",
                "WARP, the start moves: second difference, x1000", "WARP, the end moves: second difference, x1000"};
            for (int h = 0; h < 3; h++) { double v = worst(h); expect(v < 10, what[h], v); }
        }
        // a new take in the same loop: the splice is found again
        {
            static Warp w; w.init();
            const pos_t lo2 = 20000, sp2 = 48000; std::vector<float> tone(100000), a(64), b(64), pos(64);
            std::vector<double> lv; double p = 0, e = 0;
            auto fill = [&](double f) { for (size_t i = 0; i < tone.size(); i++) tone[i] = 0.25f * (float)std::sin(2 * PI * f * i / 48000); };
            fill(1000);
            for (int i = 0; i + 64 <= 48000 * 16; i += 64) {
                if (i == 64 * 4500) fill(441.7);
                Buf bl{tone.data(), (int)tone.size()}, br{tone.data(), (int)tone.size()};
                bl.setLoop(lo2, sp2); br.setLoop(lo2, sp2);
                for (int j = 0; j < 64; j++) { pos[j] = (float)(lo2 + (pos_t)p); p += 0.7; if (p >= sp2) p -= sp2; }
                w.process(a.data(), b.data(), 64, pos.data(), 1.f, 12000, 4, 0.f, bl, br);
                for (int j = 0; j < 64; j++) e += a[j] * a[j];
                if ((i / 64) % 15 == 14) { if (i > 48000 * 10) lv.push_back(std::sqrt(e / 960)); e = 0; }
            }
            std::sort(lv.begin(), lv.end());
            double dip = db(lv.front() / lv[lv.size() / 2]);
            expect(dip > -2, "WARP, a new take in the same loop: deepest 20 ms, dB", dip);
        }
        // speed 1 returns the looped take, sample for sample, off the splice
        for (int kind = 0; kind < 2; kind++) {
            int n = 48000 * 6; auto o = runL(kind, zL, zR, 1.0, 1.f, true, n);
            double best = 1e30; int at = 0;
            for (int lag = -100; lag <= 4096; lag++) {
                double e = 0; for (int i = 100000; i < 101000; i++) { double d = o[i] - zL[lo + (((pos_t)i - lag) % span + span) % span]; e += d * d; }
                if (e < best) { best = e; at = lag; }
            }
            double err = 0, ref = 1e-12; int used = 0;
            for (int i = 100000; i < n - 64; i++) {
                pos_t q = (((pos_t)i - at) % span + span) % span;
                if (q < 241 || q > span - 241) continue;
                double d = o[i] - zL[lo + q]; err += d * d; ref += zL[lo + q] * zL[lo + q]; used++;
            }
            expect(db(std::sqrt(err / ref)) < -90, kind ? "WARP speed 1: the looped take, dB" : "PV speed 1: the looped take, dB", db(std::sqrt(err / ref)));
        }
    }

    std::printf("WARP core\n");
    auto runW = [&](const std::vector<float>& L, const std::vector<float>& R, double p0, double speed,
                    float pitch, float win, float ov, int n) {
        static Warp w; w.init();
        Buf bl{L.data(), (int)L.size()}, br{R.data(), (int)R.size()};
        oL.assign(n, 0); oR.assign(n, 0);
        std::vector<float> pos(64); double p = p0;
        for (int i = 0; i + 64 <= n; i += 64) {
            for (int j = 0; j < 64; j++) { pos[j] = (float)std::floor(p + 0.5); p += speed; }
            w.process(&oL[i], &oR[i], 64, pos.data(), pitch, win, ov, 0.f, bl, br);
        }
    };
    {   // identity at speed 1
        int n = 48000 * 2; runW(nL, nR, 20000, 1.0, 1.0f, 12000, 4, n);
        double err = 0, ref = 0;
        for (int i = 24000; i < n - 64; i++) {
            pos_t src = 20000 + i;
            double d = oL[i] - nL[src], d2 = oR[i] - nR[src];
            err += d * d + d2 * d2; ref += nL[src] * nL[src] + nR[src] * nR[src];
        }
        expect(db(std::sqrt(err / ref)) < -90, "speed 1: residual against the take, dB", db(std::sqrt(err / ref)));
    }
    // a harmonic tone with a 220 Hz period: the hard case for a blind overlap
    std::vector<float> hL(len), hR(len);
    for (int i = 0; i < len; i++) {
        double v = 0; for (int h = 1; h <= 20; h++) v += std::sin(2 * PI * 220.0 * h * i / sr + h) / h;
        hL[i] = (float)(0.2 * v); hR[i] = (float)(0.1 * v);
    }
    for (double sp : {0.5, 0.25, 2.0, 0.0}) {
        int n = 48000 * 3; runW(hL, hR, 100000, sp, 1.0f, 12000, 4, n);
        // the level of the tone must hold still: RMS over 20 ms steps
        double mn = 1e9, mx = 0;
        for (int a = 48000; a + 960 < n - 960; a += 960) {
            double e = 0; for (int i = 0; i < 960; i++) e += oL[a + i] * oL[a + i];
            e = std::sqrt(e / 960); if (e < mn) mn = e; if (e > mx) mx = e;
        }
        char what[96]; std::snprintf(what, 96, "speed %.2f: harmonic tone, level swing, dB", sp);
        expect(db(mx / mn) < 1.0, what, db(mx / mn));
        double a = 0, b = 0; for (int i = 48000; i < n - 960; i++) { a += oL[i] * oL[i]; b += oR[i] * oR[i]; }
        std::snprintf(what, 96, "speed %.2f: level of R against L, dB (the take is -6.02)", sp);
        expect(std::fabs(db(std::sqrt(b / a)) + 6.02) < 0.05, what, db(std::sqrt(b / a)));
    }
    {   // pitch, at speed 0.5: 1 kHz up a fifth
        int n = 48000 * 2; runW(sL, sR, 100000, 0.5, 1.4983f, 12000, 4, n);
        double lv, off; tone(oL, 24000, 24000 + 65536, 1498.3, sr, lv, off);
        expect(off < -40, "pitch 1.498 at speed 0.5: energy off the tone, dB", off);
        expect(std::fabs(lv + 6.02) < 0.5, "pitch 1.498 at speed 0.5: level, dBFS", lv);
    }

    std::printf("PLAY read\n");
    auto runR = [&](const std::vector<float>& L, double p0, double ratio, int n) {
        Buf bl{L.data(), (int)L.size()};
        oL.assign(n, 0); oR.assign(n, 0);
        double whole = p0, frac = 0;        // the engine's two-part head
        Kern kn; kn.init();
        for (int i = 0; i < n; i++) {
            sincAt(kn, bl, bl, (pos_t)whole, (float)frac, ratio, oL[i], oR[i]);
            frac += ratio; double f = std::floor(frac); whole += f; frac -= f;
        }
    };
    {
        std::vector<float> h(len);
        int n = 48000 * 2; runR(nL, 2600000 % len, 1.0, n);
        double err = 0; for (int i = 0; i < n; i++) err += std::fabs(oL[i] - nL[(2600000 % len) + i]);
        expect(err == 0, "pitch 1: the sum of all differences from the take", err);
        double lv, off;
        for (int i = 0; i < len; i++) h[i] = 0.5f * (float)std::sin(2 * PI * 15000.0 * i / sr);
        runR(h, 100000, 2.0, n); tone(oL, 24000, 24000 + 65536, 18000, sr, lv, off);
        expect(lv < -60, "pitch 2: a 15 kHz tone folded to 18 kHz, dBFS", lv);
        for (int i = 0; i < len; i++) h[i] = 0.5f * (float)std::sin(2 * PI * 10000.0 * i / sr);
        runR(h, 100000, 0.5, n); tone(oL, 24000, 24000 + 65536, 19000, sr, lv, off);
        expect(lv < -70, "pitch 0.5: the image of a 10 kHz tone at 19 kHz, dBFS", lv);
        for (int i = 0; i < len; i++) h[i] = 0.5f * (float)std::sin(2 * PI * 5000.0 * i / sr);
        double semi = std::pow(2.0, 1.0 / 12);
        runR(h, 100000, semi, n); tone(oL, 24000, 24000 + 65536, 5000 * semi, sr, lv, off);
        expect(off < -70, "plus 1 semitone: 5 kHz tone, energy off the tone, dB", off);
        expect(std::fabs(lv + 6.02) < 0.1, "plus 1 semitone: level, dBFS", lv);
    }
    std::printf("tanh\n");
    {
        // every value from -12 to 12 in steps of 1e-4, and the small ones
        std::vector<float> x, y;
        for (int i = -120000; i <= 120000; i++) x.push_back(i * 1e-4f);
        for (int i = -4000; i <= 4000; i++) x.push_back(i * 1e-7f);
        x.push_back(100.f); x.push_back(-100.f); x.push_back(0.f);
        while (x.size() % 4) x.push_back(0.f);
        y.assign(x.size(), 0.f);
        tanhBlock(x.data(), y.data(), (int)x.size());
        double worst = 0, worstRel = 0;
        for (size_t i = 0; i < x.size(); i++) {
            double ref = std::tanh((double)x[i]), e = std::fabs((double)y[i] - ref);
            if (e > worst) worst = e;
            if (std::fabs(ref) > 1e-30 && e / std::fabs(ref) > worstRel) worstRel = e / std::fabs(ref);
        }
        expect(worst < 3e-7, "the largest difference from tanh, dB", 20 * std::log10(worst + 1e-30));
        expect(worstRel < 3e-7, "the largest difference relative to the value, dB", 20 * std::log10(worstRel + 1e-30));
        std::vector<float> z = x;
        tanhBlock(z.data(), z.data(), (int)z.size());      // in place, as SuperCollider calls it
        bool same = true;
        for (size_t i = 0; i < x.size(); i++) if (z[i] != y[i]) same = false;
        expect(same, "in place gives the same samples", same ? 1 : 0);
    }
    std::printf("THE ROOM\n");
    {
        std::vector<float> mem(Room::need());
        static Room rm;
        // 1. lossless: no loss in the lines, one click, and the energy stays
        rm.init(mem.data(), 48000, 0.005); rm.setDecay(0, 1);
        float l, r;
        for (int i = 0; i < 48000; i++) rm.tick(i == 0 ? 1.f : 0.f, i == 0 ? 0.5f : 0.f, l, r);
        const double e1 = rm.energy();
        for (int i = 0; i < 48000 * 10; i++) rm.tick(0, 0, l, r);
        const double e2 = rm.energy();
        expect(std::fabs(10 * std::log10(e2 / e1)) < 0.01, "no loss set: energy after 10 s against 1 s, dB", 10 * std::log10(e2 / e1));
        expect(std::fabs(10 * std::log10(e1 / 1.25)) < 0.01, "...and it is the click's own energy, dB", 10 * std::log10(e1 / 1.25));
        // 2. the decay: T60 2 s, the highs at half of it
        rm.init(mem.data(), 48000, 0.005); rm.setDecay(2.0, 0.5);
        const int n = 48000 * 5;
        std::vector<float> hL(n), hR(n);
        for (int i = 0; i < n; i++) rm.tick(i == 0 ? 1.f : 0.f, i == 0 ? 1.f : 0.f, hL[i], hR[i]);
        double spread = 0;
        for (int c = 1; c < Room::CH; c++) spread = std::fmax(spread, std::fabs(rm.designT60(c, 2000) / rm.designT60(0, 2000) - 1));
        expect(spread < 0.05, "designed T60 at 2 kHz: largest difference between lines", spread);
        for (double f : {500.0, 4000.0, 10000.0}) {
            double sp = 0;
            for (int c = 1; c < Room::CH; c++) sp = std::fmax(sp, std::fabs(rm.designT60(c, f) / rm.designT60(0, f) - 1));
            char name[80]; std::snprintf(name, sizeof name, "...and at %5.0f Hz", f);
            expect(sp < 0.05, name, sp);
        }
        expect(std::fabs(rm.designT60(0, 0.001) - 2.0) < 0.01, "designed T60 at 0 Hz, s", rm.designT60(0, 0.001));
        expect(std::fabs(rm.designT60(0, 23999) - 1.0) < 0.05, "designed T60 at the top, s", rm.designT60(0, 23999));
        for (double f : {500.0, 1000.0, 4000.0, 10000.0}) {
            // one band (a two-pole resonator, twice), then Schroeder's sum from the end
            const double w = 2 * PI * f / 48000, rr = 1 - PI * (f / 12) / 48000;      // a band a twelfth of f wide
            const double a1 = 2 * rr * std::cos(w), a2 = -rr * rr;
            // both outputs: two views of the same field, so their mean is steadier
            double t60 = 0;
            for (const std::vector<float>* hh : {&hL, &hR}) {
                std::vector<double> z(n);
                double y1 = 0, y2 = 0, z1 = 0, z2 = 0;
                for (int i = 0; i < n; i++) {
                    const double v = (*hh)[i] + a1 * y1 + a2 * y2; y2 = y1; y1 = v;
                    const double u = v + a1 * z1 + a2 * z2; z2 = z1; z1 = u; z[i] = u * u;
                }
                for (int i = n - 2; i >= 0; i--) z[i] += z[i + 1];
                auto at = [&](double db) { for (int i = 0; i < n; i++) if (10 * std::log10(z[i] / z[0] + 1e-300) < db) return (double)i / 48000; return 1e9; };
                // the late slope, -20 to -50 dB. (The first 20 dB fall more slowly at
                // the top: the build-up of the four steps has no loss in it. Measured:
                // the late slope is within 1% of the design from 1 kHz to 16 kHz.)
                t60 += (at(-50) - at(-20));
            }
            const double want = rm.designT60(0, f);
            char name[96]; std::snprintf(name, sizeof name, "T60 in the band at %5.0f Hz against the design (%.2f s), ratio", f, want);
            expect(std::fabs(t60 / want - 1) < 0.05, name, t60 / want);
        }
        // 3. density: the share of samples beyond one standard deviation, against a normal 0.3173
        auto ned = [&](double t) {
            const int c0 = (int)(t * 48000), hw = 480; double m2 = 0; int out = 0;
            for (int i = c0 - hw; i < c0 + hw; i++) m2 += (double)hL[i] * hL[i];
            const double sd = std::sqrt(m2 / (2 * hw));
            for (int i = c0 - hw; i < c0 + hw; i++) if (std::fabs(hL[i]) > sd) out++;
            return out / (2.0 * hw) / 0.3173;
        };
        expect(ned(0.08) > 0.9, "echo density 80 ms after the click (1 is a normal density)", ned(0.08));
        // (above 1: the echoes of the four steps all have one size, so more than a
        // normal share of them stands beyond one deviation)
        expect(ned(0.04) > 0.3, "echo density 40 ms after the click (the field is still building)", ned(0.04));
        // 4. the two sides are not copies, and nothing is left standing
        double sl = 0, sr = 0, slr = 0;
        for (int i = 9600; i < 48000; i++) { sl += (double)hL[i] * hL[i]; sr += (double)hR[i] * hR[i]; slr += (double)hL[i] * hR[i]; }
        expect(std::fabs(slr / std::sqrt(sl * sr)) < 0.1, "left against right, 0.2 s to 1 s: correlation", slr / std::sqrt(sl * sr));
        expect(std::fabs(10 * std::log10(sl / sr)) < 1.0, "left against right: level, dB", 10 * std::log10(sl / sr));
        bool fin = true; float peak = 0;
        for (int i = 0; i < 48000 * 60; i++) { rm.tick(0, 0, l, r); if (!std::isfinite(l) || !std::isfinite(r)) fin = false; if (i > 48000 * 50 && std::fabs(l) > peak) peak = std::fabs(l); }
        expect(fin && peak < 1e-9f, "60 s of silence: all values finite, and the last 10 s under 1e-9", peak);
        // 5. process() is tick() a block at a time, bit for bit. One runner for
        // every case: blocks of uneven length (1 to 200 samples, so a chunk
        // splits), and at random blocks the decay, the colour or both move,
        // back and forth, as FourRoom_next moves them at a knob's turn.
        std::vector<float> mem2(Room::need());
        static Room rb;
        std::mt19937 rng(11); std::normal_distribution<float> nd(0, 0.3f);
        std::uniform_int_distribution<int> len(1, 200), pick(0, 7);
        // returns the samples that differ; `gen` makes the input
        auto same = [&](double fs, double size, double decay, double colour, long n,
                        const std::function<float(long)>& gen, bool move) {
            rm.init(mem.data(), fs, size); rb.init(mem2.data(), fs, size);
            rm.setDecay(decay, colour); rb.setDecay(decay, colour);
            float iL[200], iR[200], pL[200], pR[200];
            long diff = 0;
            for (long done = 0; done < n;) {
                const int b = len(rng);
                for (int i = 0; i < b; i++) { iL[i] = gen(done + i); iR[i] = gen(done + i + 7); }
                if (move) {
                    const int w = pick(rng);       // 0: decay, 1: colour, 2: both, else none
                    double d2 = decay, c2 = colour;
                    if (w == 0 || w == 2) d2 = (done / 4800) % 2 ? decay * 0.5 : decay;
                    if (w == 1 || w == 2) c2 = (done / 9600) % 2 ? 0.2 : colour;
                    if (w <= 2) { rm.setDecay(d2, c2); rb.setDecay(d2, c2); }
                }
                rb.process(iL, iR, pL, pR, b);
                for (int i = 0; i < b; i++) {
                    float l2, r2; rm.tick(iL[i], iR[i], l2, r2);
                    if (l2 != pL[i] || r2 != pR[i]) diff++;
                }
                done += b;
            }
            return diff;
        };
        auto noise = [&](long) { return nd(rng); };
        long diff = 0, total = 0;
        for (double size : {0.002, 0.005, 0.0105})
            for (double decay : {0.0, 2.0, 12.0}) { diff += same(48000, size, decay, 0.5, 48000 * 4, noise, true); total += 48000 * 4; }
        char pname[96]; std::snprintf(pname, sizeof pname, "process() against tick(), %ld samples, knobs moving: samples that differ", total);
        expect(diff == 0, pname, (double)diff);
        // a line at its longest (dlen = DMAX - 1, so the ring has 1 sample of
        // room): 96 kHz at the largest size. A chunk is still 64 samples.
        rb.init(mem2.data(), 96000, 0.0105);
        int longest = 0;
        for (int k = 0; k < Room::STEPS; k++) for (int c = 0; c < Room::CH; c++) longest = std::max(longest, rb.dlen[k][c]);
        expect(longest == Room::DMAX - 1, "96 kHz, size 0.0105: the longest diffusion line is DMAX - 1", longest);
        expect(rb.cmax == Room::CHUNK, "...and the chunk is still CHUNK samples", rb.cmax);
        diff = same(96000, 0.0105, 2.0, 0.5, 96000 * 2, noise, true);
        expect(diff == 0, "...and process() is tick(): samples that differ", (double)diff);
        // the floor: below 1e-20 the input is 0, at it and above it is kept
        expect(Room::floorIn(9.9e-21f) == 0.f && Room::floorIn(-9.9e-21f) == 0.f && Room::floorIn(1e-39f) == 0.f,
               "the input floor: 9.9e-21, -9.9e-21 and a denormal read 0", 0);
        expect(Room::floorIn(1e-20f) == 1e-20f && Room::floorIn(-0.25f) == -0.25f, "...and 1e-20 and -0.25 pass unchanged", 0);
        // a send that fades into the denormal range, and denormals mixed into
        // noise: the same in both paths (on the norns this is the NEON case),
        // and nothing in the room's output is a denormal
        auto fade = [&](long i) { return (float)(0.5 * std::exp(-i / 600.0)) * nd(rng); };
        auto mixed = [&](long i) { const long k = i % 5; return k == 0 ? 1e-39f : k == 1 ? -3e-42f : k == 2 ? 2e-21f : k == 3 ? 1e-20f : nd(rng); };
        diff = same(48000, 0.005, 2.0, 0.5, 48000 * 3, fade, false);
        expect(diff == 0, "a send fading to 1e-45 and below: samples that differ", (double)diff);
        diff = same(48000, 0.005, 2.0, 0.5, 48000 * 2, mixed, true);
        expect(diff == 0, "denormals and tiny values among the noise: samples that differ", (double)diff);
        // the case the floor decides: no loss (decay 0), denormal noise into an
        // empty room. The first return has y exactly 0, so a row value shows in
        // the output. On the norns (NEON flushes, the scalar code does not)
        // this fails without floorIn; on the Mac it passes either way.
        auto tinyNoise = [&](long) { return nd(rng) * 1e-38f; };
        diff = same(48000, 0.005, 0.0, 0.5, 48000, tinyNoise, false);
        expect(diff == 0, "no loss, denormal noise into an empty room: samples that differ", (double)diff);
        // the chunk rule: a late line shorter than CHUNK (500 Hz: llen is 29 to
        // 53) cuts the chunk to it, and process() is still tick()
        rb.init(mem2.data(), 500, 0.002);
        int shortest = Room::LMAX;
        for (int c = 0; c < Room::CH; c++) shortest = std::min(shortest, rb.llen[c]);
        expect(rb.cmax == shortest && shortest < Room::CHUNK, "500 Hz: the chunk is the shortest late line", rb.cmax);
        diff = same(500, 0.002, 2.0, 0.5, 4000, noise, true);
        expect(diff == 0, "...and process() is tick(): samples that differ", (double)diff);
        {
            rb.init(mem2.data(), 48000, 0.005); rb.setDecay(2.0, 0.5);
            float iL[64], iR[64], pL[64], pR[64]; long den = 0;
            for (long b = 0; b < 48000 * 3 / 64; b++) {
                for (int i = 0; i < 64; i++) { iL[i] = fade(b * 64 + i); iR[i] = fade(b * 64 + i + 3); }
                rb.process(iL, iR, pL, pR, 64);
                for (int i = 0; i < 64; i++) if (std::fpclassify(pL[i]) == FP_SUBNORMAL || std::fpclassify(pR[i]) == FP_SUBNORMAL) den++;
            }
            expect(den == 0, "...and the room's output holds no denormal", (double)den);
        }
    }
    std::printf("THE BUCKET BRIGADE\n");
    {
        std::vector<float> mem(8192);
        static BBD bb;
        const double fs = 48000, fc = 12000, ratio = 0.35, corner = ratio * fc;
        auto H = [&](double f) { return 1.0 / std::sqrt(1.0 + std::pow(f / corner, 6)); };
        auto sinc = [&](double x) { return x == 0 ? 1.0 : std::sin(PI * x) / (PI * x); };
        // the level of the component at `f` in a run with a tone at f0
        auto level = [&](double f0, double f) {
            bb.init(mem.data(), 4096, fs); bb.setClock(fc, ratio);
            const int n = 48000 * 3; double a = 0, b = 0; int cnt = 0;
            for (int i = 0; i < n; i++) {
                const float y = bb.tick(0.5f * (float)std::sin(2 * PI * f0 * i / fs));
                if (i >= 48000) { const double hw = 0.5 - 0.5 * std::cos(2 * PI * (i - 48000) / (n - 48000)); a += hw * y * std::cos(2 * PI * f * i / fs); b += hw * y * std::sin(2 * PI * f * i / fs); cnt++; }
            }
            return 20 * std::log10(2 * std::sqrt(a * a + b * b) / (0.5 * cnt) / 0.5 + 1e-30);
        };
        for (double f0 : {300.0, 1500.0, 3000.0, 4200.0}) {
            const double got = level(f0, f0);
            const double want = 20 * std::log10(H(f0) * sinc(f0 / fc) * H(f0) * sinc(f0 / fs));
            char name[96]; std::snprintf(name, sizeof name, "clock 12 kHz: a tone at %4.0f Hz against H sinc H sinc (%.2f dB), difference", f0, want);
            expect(std::fabs(got - want) < 0.2, name, got - want);
        }
        {
            const double f0 = 3000, fi = fc - f0;
            const double got = level(f0, fi) - level(f0, f0);
            const double want = 20 * std::log10((f0 / fi) * (H(fi) / H(f0)) * (sinc(fi / fs) / sinc(f0 / fs)));
            expect(std::fabs(got - want) < 0.5, "the image at 9 kHz of a 3 kHz tone against the formula, dB", got - want);
            expect(want > -60, "(that image, against the tone, dB)", want);
            // nothing else: a place that is neither the tone nor an image
            expect(level(f0, 5000.0) - level(f0, f0) < -70, "a 3 kHz tone: the level at 5 kHz, where nothing belongs, dB", level(f0, 5000.0) - level(f0, f0));
        }
        {
            // the time: the phase of a 100 Hz tone against the delay the model states
            bb.init(mem.data(), 4096, fs); bb.setClock(fc, ratio);
            const int n = 48000 * 3; double a = 0, b = 0;
            for (int i = 0; i < n; i++) {
                const float y = bb.tick((float)std::sin(2 * PI * 100.0 * i / fs));
                if (i >= 48000) { a += y * std::cos(2 * PI * 100.0 * i / fs); b += y * std::sin(2 * PI * 100.0 * i / fs); }
            }
            double lag = std::atan2(-a, b) / (2 * PI * 100.0);           // seconds, modulo 10 ms
            // (the host's sample is held for one period, which is half a sample of
            // delay, and tick() returns the state at the END of that period, which
            // takes a whole sample off: half a sample less in all)
            const double want = BBD::seconds(4096, fc, corner) - 0.5 / fs;
            double diff = lag - std::fmod(want, 0.01);
            while (diff > 0.005) diff -= 0.01; while (diff < -0.005) diff += 0.01;
            expect(std::fabs(diff) < 0.1 / fc, "the delay against chain + hold + filters, in clock periods", diff * fc);
        }
        {
            // the whole-tick step computed once in setClock: the same output as
            // the reference that computes every tick, at a slow clock, a fast one
            // (4 ticks a sample, the 43 ms floor) and across clock changes
            std::vector<float> ma(8192), mb(8192);
            static BBD fa; static RefBBD fb;
            fa.init(ma.data(), 4096, fs); fb.init(mb.data(), 4096, fs);
            double worst = 0, peak = 0;
            const double clocks[] = {4100.0, 27300.0, 82000.0, 191800.0, 61234.5};
            for (int s = 0; s < 5; s++) {
                fa.setClock(clocks[s], 0.35); fb.setClock(clocks[s], 0.35);
                for (int i = 0; i < 48000; i++) {
                    const float in = 0.5f * (float)std::sin(2 * PI * 440.0 * i / fs) + nd(rng);
                    const float a = fa.tick(in), b = fb.tickRef(in);
                    worst = std::fmax(worst, std::fabs((double)a - b)); peak = std::fmax(peak, std::fabs((double)b));
                }
            }
            expect(worst < 1e-6 && peak > 0.1, "one step for each whole tick: largest difference from the reference, dB",
                   20 * std::log10(worst + 1e-30));
        }
        {
            // the delay as a whole: an echo lands on its time, and a loop at 0.98 falls
            static BBDDelay dl; std::vector<float> m2(8192);
            dl.init(m2.data(), 8192, fs); dl.set(0.5, 0.35);
            const int n = 48000 * 30; double e1 = 0, e2 = 0; int first = -1; bool fin = true;
            for (int i = 0; i < n; i++) {
                const float in = i < 4800 ? 0.5f * (float)std::sin(2 * PI * 220.0 * i / fs) * (float)std::sin(PI * i / 4800.0) : 0.f;
                const float y = dl.tick(in, 0.98f, 0.f);
                if (!std::isfinite(y)) fin = false;
                if (first < 0 && std::fabs(y) > 0.05f) first = i;
                if (i >= 48000 * 2 && i < 48000 * 4) e1 += (double)y * y;
                if (i >= 48000 * 28) e2 += (double)y * y;
            }
            // (the burst's 0.05 level comes about 0.25 ms after its start)
            expect(std::fabs(first / fs - 0.5) < 0.004, "TIME 0.5 s: the first echo arrives at, s", first / fs);
            expect(fin && e2 < e1 && e2 > 0, "feedback 0.98 for 30 s: the last 2 s against seconds 2 to 4, dB", 10 * std::log10(e2 / e1 + 1e-30));
            for (int i = 0; i < 48000 * 60; i++) { const float y = dl.tick(0, 0.5f, 0.f); if (!std::isfinite(y)) fin = false; }
            expect(fin, "60 s of silence: every value finite", fin ? 1 : 0);
        }
        {
            // AGE: the pair around the chain. At rest a low tone comes out at its own level.
            static BBDDelay dl; std::vector<float> m2(8192);
            auto tone = [&](float amp, float age) {
                dl.init(m2.data(), 8192, fs); dl.set(0.2, 0.35);
                const int n = 48000 * 4; double a = 0, b = 0; int cnt = 0;
                for (int i = 0; i < n; i++) {
                    const float y = dl.tick(amp * (float)std::sin(2 * PI * 200.0 * i / fs), 0.f, age);
                    if (i >= 48000 * 2) { a += y * std::cos(2 * PI * 200.0 * i / fs); b += y * std::sin(2 * PI * 200.0 * i / fs); cnt++; }
                }
                return 20 * std::log10(2 * std::sqrt(a * a + b * b) / cnt / amp + 1e-30);
            };
            const double clean = tone(0.25f, 0.f);
            expect(std::fabs(tone(0.25f, 1e-6f) - clean) < 0.1, "AGE on, a 200 Hz tone at 0.25: level against AGE off, dB", tone(0.25f, 1e-6f) - clean);
            expect(std::fabs(tone(0.05f, 1e-6f) - tone(0.05f, 0.f)) < 0.1, "...and at 0.05", tone(0.05f, 1e-6f) - tone(0.05f, 0.f));
            // the noise: quiet at rest, and louder behind a note
            dl.init(m2.data(), 8192, fs); dl.set(0.2, 0.35);
            double rest = 0, behind = 0; bool fin = true;
            for (int i = 0; i < 48000 * 4; i++) { const float y = dl.tick(0, 0.f, 1.f); if (!std::isfinite(y)) fin = false; if (i >= 48000 * 3) rest += (double)y * y; }
            for (int i = 0; i < 48000 * 2; i++) {
                // a 60 Hz tone: the noise is read above 2 kHz, where the tone has nothing
                const float y = dl.tick(0.5f * (float)std::sin(2 * PI * 60.0 * i / fs), 0.f, 1.f);
                static double h1 = 0, h2 = 0, px = 0, py = 0;
                const double q = 0.77;                       // two one-pole high-passes near 2 kHz
                const double a1v = q * (h1 + y - px); px = y; h1 = a1v;
                const double a2v = q * (h2 + a1v - py); py = a1v; h2 = a2v;
                if (i >= 48000) behind += a2v * a2v;
                if (!std::isfinite(y)) fin = false;
            }
            const double restDb = 10 * std::log10(rest / 48000 + 1e-30), behindDb = 10 * std::log10(behind / 48000 + 1e-30);
            expect(fin && restDb < -110, "AGE 1, silence in: the noise at the output, dBFS", restDb);
            expect(behindDb > restDb + 20 && behindDb < -55, "AGE 1, behind a loud note: the noise above 2 kHz, dBFS", behindDb);
        }
    }
    std::printf("CLOUD core (Clouds, vendor/, as FourCloud runs it)\n");
    {
        static CloudRun c;
        auto none = [](CloudRun&, double) {};
        // GRANULAR: 3 s of the sine, then 27 s of silence. The silent tail
        // must cost what the sound cost: a state that decays into the
        // subnormal range costs many times more on a CPU without flush to zero.
        c.init();
        CloudReport g = cloudRun(c, 30, 3, 1, 3, 25, 30, none);
        expect(g.finite, "GRANULAR, 30 s: every value finite", g.finite ? 1 : 0);
        expect(g.levA > -40, "GRANULAR, a sine at -12 dBFS in: level out, dBFS", g.levA);
        expect(g.levB < -120, "GRANULAR, 22 s after the sine ends: level out, dBFS", g.levB);
        expect(g.subnormal == 0, "GRANULAR, 30 s: subnormal values out", (double)g.subnormal);
        expect(g.costB < 3 * g.costA, "GRANULAR, silence against sound: cost of a block, ratio", g.costB / g.costA);
        // FREEZE: the held buffer goes on sounding after the input stops
        c.init();
        CloudReport f = cloudRun(c, 8, 2, 0.5, 2, 5, 8, [](CloudRun& cr, double t) {
            cr.gp->mutable_parameters()->freeze = t >= 1.5;
        });
        expect(f.finite && f.levB > -40, "FREEZE at 1.5 s, silent from 2 s: level at 5 to 8 s, dBFS", f.levB);
        // the other modes and the low fidelity: they sound and stay finite
        const char* names[] = {"STRETCH", "LOOPING DELAY", "SPECTRAL", "GRANULAR, low fidelity"};
        for (int m = 0; m < 4; m++) {
            c.init();
            CloudReport r = cloudRun(c, 4, 4, 1.5, 4, 3.9, 4, [m](CloudRun& cr, double) {
                cr.gp->set_playback_mode((clouds::PlaybackMode)(m < 3 ? m + 1 : 0));
                cr.gp->set_low_fidelity(m == 3);
            });
            char what[96]; std::snprintf(what, 96, "%s, the sine in: level out, dBFS", names[m]);
            expect(r.finite && r.levA > -40, what, r.levA);
        }
        // the loop at its hottest: feedback 1 and reverb 1 on the sine for
        // 20 s. It must stay finite and bounded.
        c.init();
        CloudReport h = cloudRun(c, 20, 20, 1, 20, 19, 20, [](CloudRun& cr, double) {
            cr.gp->mutable_parameters()->feedback = 1.f;
            cr.gp->mutable_parameters()->reverb = 1.f;
        });
        expect(h.finite && h.peak < 2, "feedback 1, reverb 1, 20 s of the sine: peak out", h.peak);
    }
    std::printf(fails ? "\n%d FAILED\n" : "\nall passed\n", fails);
    return fails ? 1 : 0;
}
