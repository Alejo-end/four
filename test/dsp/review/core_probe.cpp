// Probes of ugen/four_core.h: cost, the grain read, the drive's aliasing.
// clang++ -O2 -std=c++17 -I<repo>/ugen core_probe.cpp -o core_probe
#include "four_core.h"
#include <chrono>
#include <cstdio>
#include <vector>
#include <random>
#include <complex>
using namespace four;
typedef std::chrono::steady_clock clk;
static const double PI = 3.14159265358979323846, FS = 48000;
static double db(double v) { return 20 * std::log10(std::fabs(v) + 1e-30); }
// level of a frequency in y[a, a+n) (Hann projection)
static double amp(const std::vector<float>& y, int a, int n, double f) {
    double s = 0, c = 0, w = 0;
    for (int i = 0; i < n; i++) { double h = 0.5 - 0.5 * std::cos(2 * PI * i / n); s += h * y[a + i] * std::sin(2 * PI * f * i / FS); c += h * y[a + i] * std::cos(2 * PI * f * i / FS); w += h; }
    return 2 * std::sqrt(s * s + c * c) / w;
}
// power in a third-octave band around fc, by DFT bins of 8192-point Hann frames
static void bands(const std::vector<float>& y, int a, int frames, const double* fc, int nb, double* out) {
    const int M = 8192;
    std::vector<double> P(M / 2 + 1, 0.0);
    for (int fr = 0; fr < frames; fr++) {
        for (int k = 0; k <= M / 2; k += 1) {}
        // a plain DFT is slow: use the Goertzel per band bin instead
    }
    for (int b = 0; b < nb; b++) {
        double lo = fc[b] / std::pow(2.0, 1.0 / 6), hi = fc[b] * std::pow(2.0, 1.0 / 6), e = 0; int cnt = 0;
        for (int fr = 0; fr < frames; fr++) {
            int s0 = a + fr * M;
            for (double f = lo; f < hi; f += FS / M * 2) {
                double w = 2 * PI * f / FS, s1 = 0, s2 = 0, coef = 2 * std::cos(w);
                for (int i = 0; i < M; i++) { double h = 0.5 - 0.5 * std::cos(2 * PI * i / M); double s = y[s0 + i] * h + coef * s1 - s2; s2 = s1; s1 = s; }
                e += s1 * s1 + s2 * s2 - coef * s1 * s2; cnt++;
            }
        }
        out[b] = 10 * std::log10(e / cnt);
    }
}

// THE BUCKET BRIGADE with the steps of whole ticks computed once (a candidate)
struct BBDfast : BBD {
    double S1, S2r, S2i, lastInc = -1;   // one whole tick's step
    inline float tick2(float in) {
        const double u = (double)in + 1e-15;
        const int nt = (int)(ph + inc);
        if (nt == 0) {
            adv(ia, ibr, ibi, E1, E2r, E2i, u); adv(oa, obr, obi, E1, E2r, E2i, hold); ph += inc;
        } else {
            const double x = om / fs;
            if (inc != lastInc) {
                const double D = 1.0 / inc, m = std::exp(-0.5 * x * D);
                S1 = m * m; S2r = m * std::cos(0.8660254037844386 * x * D); S2i = m * std::sin(0.8660254037844386 * x * D);
                lastInc = inc;
            }
            double P1 = 1, Pr = 1, Pi = 0;
            for (int k = 1; k <= nt; k++) {
                double e1, e2r, e2i;
                if (k == 1) {
                    const double D = (1.0 - ph) / inc, m = std::exp(-0.5 * x * D);
                    e1 = m * m; e2r = m * std::cos(0.8660254037844386 * x * D); e2i = m * std::sin(0.8660254037844386 * x * D);
                } else { e1 = S1; e2r = S2r; e2i = S2i; }
                adv(ia, ibr, ibi, e1, e2r, e2i, u); adv(oa, obr, obi, e1, e2r, e2i, hold);
                hold = (double)ring[w] + 1e-15; ring[w] = (float)read(om, ia, ibr, ibi); w = (w + 1) & (half - 1);
                P1 *= e1; const double q = Pr * e2r - Pi * e2i; Pi = Pr * e2i + Pi * e2r; Pr = q;
            }
            const double e1 = E1 / P1, n2 = Pr * Pr + Pi * Pi;
            const double e2r = (E2r * Pr + E2i * Pi) / n2, e2i = (E2i * Pr - E2r * Pi) / n2;
            adv(ia, ibr, ibi, e1, e2r, e2i, u); adv(oa, obr, obi, e1, e2r, e2i, hold);
            ph = ph + inc - nt;
        }
        return (float)read(om, oa, obr, obi);
    }
};

int main() {
    std::mt19937 rng(11); std::normal_distribution<float> nd(0, 0.1f);
    const int len = 48000 * 20;
    std::vector<float> L(len), R(len);
    for (int i = 0; i < len; i++) { L[i] = nd(rng); R[i] = nd(rng); }
    tables();

    std::printf("1. THE BUCKET BRIGADE: cost by TIME (mono, Mac), and a candidate that computes whole ticks once\n");
    for (double t : {0.0428, 0.06, 0.1, 0.3, 1.0, 2.0}) {
        std::vector<float> m1(8192), m2(8192);
        static BBDDelay a; a.init(m1.data(), 8192, FS); a.set(t, 0.35);
        static BBDfast b; b.init(m2.data(), 8192, FS);
        { BBDDelay tmp; std::vector<float> mm(8192); tmp.init(mm.data(), 8192, FS); tmp.set(t, 0.35); b.setClock(tmp.chain.inc * FS, 0.35); }
        const int n = 48000 * 5; float acc = 0;
        auto t0 = clk::now();
        for (int i = 0; i < n; i++) acc += a.chain.tick(L[i % len]);
        double ns1 = std::chrono::duration<double, std::nano>(clk::now() - t0).count() / n;
        t0 = clk::now();
        for (int i = 0; i < n; i++) acc += b.tick2(L[i % len]);
        double ns2 = std::chrono::duration<double, std::nano>(clk::now() - t0).count() / n;
        // the same output? (fresh states, same input)
        std::vector<float> m3(8192), m4(8192); BBD c; BBDfast e; c.init(m3.data(), 8192, FS); e.init(m4.data(), 8192, FS);
        c.setClock(a.chain.inc * FS, 0.35); e.setClock(a.chain.inc * FS, 0.35);
        double worst = 0; for (int i = 0; i < 48000 * 2; i++) { double d = std::fabs((double)c.tick(L[i]) - (double)e.tick2(L[i])); if (d > worst) worst = d; }
        std::printf("  time %.3f s: clock %6.0f Hz, %4.2f ticks a sample: %6.1f ns a sample, candidate %6.1f ns (largest difference %.1e)  %g\n",
                    t, a.chain.inc * FS, a.chain.inc, ns1, ns2, worst, acc * 0);
    }
    std::printf("2. the cost of a start (memory cleared in the audio thread)\n");
    {
        std::vector<float> mem(Room::need()); static Room rm;
        auto t0 = clk::now(); for (int k = 0; k < 50; k++) rm.init(mem.data(), FS, 0.005);
        std::printf("  Room::init, %zu floats: %.0f us (Mac)\n", Room::need(), std::chrono::duration<double, std::micro>(clk::now() - t0).count() / 50);
        std::vector<float> d(65536); DelayFb df;
        t0 = clk::now(); for (int k = 0; k < 200; k++) df.init(d.data(), 65536);
        std::printf("  DelayFb::init, 65536 floats (ECHO, one channel): %.0f us (Mac)\n", std::chrono::duration<double, std::micro>(clk::now() - t0).count() / 200);
    }

    std::printf("3. GRAIN: the read between samples. Noise take, grains of 0.1 s at pitch 1, band level re 1 kHz\n");
    {
        const double fc[] = {1000, 5000, 10000, 16000, 19000};
        auto runG = [&](bool snap, double pitch, const std::vector<float>& bufL, std::vector<float>& out) {
            static Grains g; g.init();
            Buf bl{bufL.data(), (int)bufL.size()};
            const int n = 48000 * 6; out.assign(n, 0.f);
            std::vector<float> o2(64), trig(64), dur(64, 0.1f), rate(64, (float)pitch), pos(64), pl(64, -1.f), pr(64, -1.f);
            std::uniform_real_distribution<double> ud(0.05, 0.9);
            int next = 0;
            for (int i = 0; i + 64 <= n; i += 64) {
                for (int j = 0; j < 64; j++) {
                    trig[j] = (i + j == next) ? 1.f : 0.f;
                    double p = ud(rng);
                    if (snap) p = std::floor(p * bl.frames + 0.5) / bl.frames;   // a whole frame
                    pos[j] = (float)p;
                    if (i + j == next) next += 2400;      // 20 a second: an overlap of 2
                }
                g.process(&out[i], o2.data(), 64, trig.data(), dur.data(), rate.data(), pos.data(), pl.data(), pr.data(), bl, bl, nullptr, 0, 48, FS, 1.0);
            }
        };
        std::vector<float> o;
        double b0[5], b1[5], b2[5];
        bands(L, 48000, 30, fc, 5, b0);
        runG(false, 1.0, L, o); bands(o, 48000, 30, fc, 5, b1);
        runG(true, 1.0, L, o); bands(o, 48000, 30, fc, 5, b2);
        std::printf("  take        "); for (int b = 0; b < 5; b++) std::printf(" %5.0f Hz %+6.2f", fc[b], b0[b] - b0[0]); std::printf("\n");
        std::printf("  GRAIN now   "); for (int b = 0; b < 5; b++) std::printf(" %5.0f Hz %+6.2f", fc[b], (b1[b] - b1[0]) - (b0[b] - b0[0])); std::printf("\n");
        std::printf("  start on a whole frame"); for (int b = 0; b < 5; b++) std::printf(" %5.0f Hz %+6.2f", fc[b], (b2[b] - b2[0]) - (b0[b] - b0[0])); std::printf("\n");
        // the fold: a 15 kHz tone at pitch 2 lands on 18 kHz
        std::vector<float> h(len); for (int i = 0; i < len; i++) h[i] = 0.5f * (float)std::sin(2 * PI * 15000.0 * i / FS);
        runG(false, 2.0, h, o);
        std::printf("  pitch 2, a 15 kHz tone at -6 dBFS: the fold at 18 kHz %6.1f dBFS (PLAY with FourRead: under -60)\n", db(amp(o, 48000, 131072, 18000)));
        for (int i = 0; i < len; i++) h[i] = 0.5f * (float)std::sin(2 * PI * 10000.0 * i / FS);
        runG(false, 0.5, h, o);
        std::printf("  pitch 0.5, a 10 kHz tone: 5 kHz %6.1f dBFS, its image at 19 kHz %6.1f dBFS\n", db(amp(o, 48000, 131072, 5000)), db(amp(o, 48000, 131072, 19000)));
    }

    std::printf("4. DRIVE at full (tanh(7x)/sqrt 7): aliasing, and 2x and 4x oversampling\n");
    {
        // a halfband low-pass for x2 (Kaiser windowed sinc, 63 taps)
        const int T = 63; std::vector<double> hb(T);
        auto i0 = [](double v) { double s = 1, t = 1; for (int k = 1; k < 40; k++) { t *= (v / (2 * k)) * (v / (2 * k)); s += t; } return s; };
        for (int k = 0; k < T; k++) { int j = k - T / 2; double sinc = j == 0 ? 0.5 : std::sin(PI * j / 2) / (PI * j); double r = (double)j / (T / 2); hb[k] = sinc * i0(10 * std::sqrt(std::fmax(0, 1 - r * r))) / i0(10); }
        auto os = [&](const std::vector<float>& x, int factor) {
            // up by `factor` (powers of 2, by halfband stages), tanh, down again
            std::vector<double> y(x.begin(), x.end());
            int stages = factor == 4 ? 2 : factor == 2 ? 1 : 0;
            for (int s = 0; s < stages; s++) {
                std::vector<double> u(y.size() * 2, 0.0), v(y.size() * 2, 0.0);
                for (size_t i = 0; i < y.size(); i++) u[2 * i] = 2 * y[i];
                for (size_t i = T; i < u.size(); i++) { double a = 0; for (int k = 0; k < T; k++) a += hb[k] * u[i - k]; v[i] = a; }
                y.swap(v);
            }
            for (auto& v : y) v = std::tanh(7 * v) / std::sqrt(7.0);
            for (int s = 0; s < stages; s++) {
                std::vector<double> v(y.size(), 0.0);
                for (size_t i = T; i < y.size(); i++) { double a = 0; for (int k = 0; k < T; k++) a += hb[k] * y[i - k]; v[i] = a; }
                std::vector<double> d(y.size() / 2); for (size_t i = 0; i < d.size(); i++) d[i] = v[2 * i];
                y.swap(d);
            }
            return std::vector<float>(y.begin(), y.end());
        };
        for (double f0 : {5000.0, 1318.5}) {
            for (double lv : {0.5, 0.25}) {
                std::vector<float> x(48000 * 2); for (size_t i = 0; i < x.size(); i++) x[i] = (float)(lv * std::sin(2 * PI * f0 * i / FS));
                std::printf("  %6.1f Hz at %4.1f dBFS:", f0, db(lv));
                for (int fac : {1, 2, 4}) {
                    auto y = os(x, fac);
                    // energy that is not an odd harmonic below 24 kHz: project out the harmonics
                    std::vector<double> yy(y.begin() + 4800, y.begin() + 4800 + 65536);
                    double tot = 0; for (double v : yy) tot += v * v; tot /= yy.size();
                    double harm = 0;
                    for (int k = 1; k * f0 < 24000; k += 2) { std::vector<float> z(yy.begin(), yy.end()); double a = amp(z, 0, 65536, k * f0); harm += a * a / 2; }
                    std::printf("   x%d alias %6.1f dB", fac, 10 * std::log10(std::fmax(tot - harm, 1e-30) / tot));
                }
                std::printf("\n");
            }
        }
        // cost: plain tanh against x2 and x4 with two 63-tap halfbands (polyphase: 16 MACs a stage a sample)
        std::vector<float> x(48000 * 4), y(x.size()); for (size_t i = 0; i < x.size(); i++) x[i] = L[i % len];
        auto t0 = clk::now(); tanhBlock(x.data(), y.data(), (int)x.size());
        double nsT = std::chrono::duration<double, std::nano>(clk::now() - t0).count() / x.size();
        std::printf("  cost (Mac, scalar): tanh %.1f ns a sample. A x2 stage adds two tanh and 2 x 32 MACs of a polyphase halfband\n", nsT);
    }
    return 0;
}
