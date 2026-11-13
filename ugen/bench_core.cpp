// How much of one core each voice takes, and the worst single block.
//   clang++ -O2 -std=c++17 -o /tmp/bench_core ugen/bench_core.cpp && /tmp/bench_core
#include "four_core.h"
#include <chrono>
#include <cstdio>
#include <vector>
#include <random>
using namespace four;
typedef std::chrono::steady_clock clk;
int main() {
    int len = 48000 * 60; std::vector<float> L(len), R(len);
    std::mt19937 rng(3); std::normal_distribution<float> nd(0, 0.1f);
    for (int i = 0; i < len; i++) { L[i] = nd(rng); R[i] = nd(rng); }
    Buf bl{L.data(), len}, br{R.data(), len};
    float oL[64], oR[64], pos[64];
    static PV pv; static Warp w;
    struct Case { const char* name; int kind; float pitch; double speed; float rand; };
    Case cases[] = {{"PV, pitch 1, speed 0.5", 0, 1, 0.5, 0}, {"PV, pitch 2, speed 0.5", 0, 2, 0.5, 0},
                    {"PV, pitch 0.5, speed 0.5", 0, 0.5f, 0.5, 0},
                    {"WARP, pitch 1, speed 0.5", 1, 1, 0.5, 0}, {"WARP, pitch 2, speed 0.5", 1, 2, 0.5, 0},
                    {"WARP, pitch 1, rand 0.3", 1, 1, 0.5, 0.3f}};
#ifdef FOUR_FFTW
    plans();
#endif
    tables();   // the plugin builds them when it loads, so they are not part of a block
    std::printf("%-28s %12s %16s\n", "voice", "% of a core", "worst block, us");
    for (auto& c : cases) {
        pv.init(); w.init();
        double p = 500000, worst = 0; int blocks = 48000 * 10 / 64;
        auto t0 = clk::now();
        for (int b = 0; b < blocks; b++) {
            for (int j = 0; j < 64; j++) { pos[j] = (float)std::floor(p + 0.5); p += c.speed; }
            auto a = clk::now();
            if (c.kind == 0) pv.process(oL, oR, 64, pos, c.pitch, bl, br);
            else w.process(oL, oR, 64, pos, c.pitch, 12000, 4, c.rand, bl, br);
            double us = std::chrono::duration<double, std::micro>(clk::now() - a).count();
            if (us > worst) worst = us;
        }
        double sec = std::chrono::duration<double>(clk::now() - t0).count();
        std::printf("%-28s %11.2f%% %16.0f\n", c.name, sec / 10 * 100, worst);
    }
    std::printf("one block is 1333 us\n");
}
