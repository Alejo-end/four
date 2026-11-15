// The alias table of each FourStretch voice, by pitch.
#include "four_core.h"
#include <cstdio>
#include <vector>
#include <random>
using namespace four;
static const double PI = 3.14159265358979323846, FS = 48000;
static double db(double v) { return 20 * std::log10(std::fabs(v) + 1e-30); }
static double amp(const std::vector<float>& y, int a, int n, double f) {
    double s = 0, c = 0, w = 0;
    for (int i = 0; i < n; i++) { double h = 0.5 - 0.5 * std::cos(2 * PI * i / n); s += h * y[a + i] * std::sin(2 * PI * f * i / FS); c += h * y[a + i] * std::cos(2 * PI * f * i / FS); w += h; }
    return 2 * std::sqrt(s * s + c * c) / w;
}
int main() {
    const int len = 48000 * 8, n = 48000 * 3, a = 48000, m = 65536;
    std::vector<float> o, o2;
    auto tone = [&](double f) { std::vector<float> h(len); for (int i = 0; i < len; i++) h[i] = 0.5f * (float)std::sin(2 * PI * f * i / FS); return h; };
    auto voice = [&](int kind, const std::vector<float>& L, double pitch) {
        Buf b{L.data(), len}; o.assign(n, 0); o2.assign(n, 0);
        std::vector<float> pos(64), trig(64, 0), dur(64, 0.1f), rate(64, (float)pitch), gp(64), pl(64, -1), pr(64, -1);
        static PV pv; static Warp w; static Grains g; pv.init(); w.init(); g.init(); Kern kn; kn.init();
        double p = 100000, whole = 100000, frac = 0; int next = 0;
        std::mt19937 rng(5); std::uniform_real_distribution<double> ud(0.2, 0.7);
        for (int i = 0; i + 64 <= n; i += 64) {
            for (int j = 0; j < 64; j++) { pos[j] = (float)std::floor(p + 0.5); p += 1.0; trig[j] = (i + j == next) ? 1.f : 0.f; if (i + j == next) next += 2400; gp[j] = (float)ud(rng); }
            if (kind == 0) for (int j = 0; j < 64; j++) {   // PLAY: the engine's two-part head at `pitch`
                sincAt(kn, b, b, (pos_t)whole, (float)frac, pitch, o[i + j], o2[i + j]);
                frac += pitch; double f = std::floor(frac); whole += f; frac -= f;
            }
            if (kind == 1) pv.process(&o[i], &o2[i], 64, pos.data(), (float)pitch, b, b);
            if (kind == 2) w.process(&o[i], &o2[i], 64, pos.data(), (float)pitch, 12000, 4, 0, b, b);
            if (kind == 3) g.process(&o[i], &o2[i], 64, trig.data(), dur.data(), rate.data(), gp.data(), pl.data(), pr.data(), b, b, nullptr, 0, 48, FS, 1.0);
        }
    };
    const char* names[] = {"PLAY (FourRead)", "PV (FourPV)", "WARP (FourWarp)", "GRAIN (FourGrain)"};
    std::printf("A -6 dBFS tone read at a pitch. Above 1: the tone is 30 kHz / pitch, so its true place is 30 kHz;\n");
    std::printf("what lands on 18 kHz is the fold. Below 1: a 10 kHz tone, and its largest image. dBFS\n");
    std::printf("%-20s %10s %10s %10s %10s %16s %16s\n", "voice", "x1.5 fold", "x2 fold", "x4 fold", "x3 fold", "x0.5 image", "x0.25 image");
    for (int k = 0; k < 4; k++) {
        double r[6];
        voice(k, tone(20000), 1.5); r[0] = amp(o, a, m, 18000);
        voice(k, tone(15000), 2.0); r[1] = amp(o, a, m, 18000);
        voice(k, tone(7500), 4.0); r[2] = amp(o, a, m, 18000); voice(k, tone(10000), 3.0); r[3] = amp(o, a, m, 18000);
        
        voice(k, tone(10000), 0.5); r[4] = amp(o, a, m, 19000);
        voice(k, tone(10000), 0.25); { double mx = 0; for (double f : {9500.0, 14500.0, 21500.0}) mx = std::fmax(mx, amp(o, a, m, f)); r[5] = mx; }
        std::printf("%-20s %10.1f %10.1f %10.1f %10.1f %16.1f %16.1f\n", names[k], db(r[0]), db(r[1]), db(r[2]), db(r[3]), db(r[4]), db(r[5]));
    }
}
