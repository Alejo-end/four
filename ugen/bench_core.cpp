// How much of one core each voice takes, and the worst single block.
//   clang++ -O2 -std=c++17 -Iugen/vendor/eurorack -o /tmp/bench_core ugen/bench_core.cpp && /tmp/bench_core
#include "four_core.h"
#include "four_cloud.h"
#include <chrono>
#include <cstdio>
#include <cstring>
#include <new>
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
    {
        // THE ROOM: stereo noise in, 10 s
        std::vector<float> mem(Room::need());
        static Room rm; rm.init(mem.data(), 48000, 0.005); rm.setDecay(2.0, 0.5);
        double worst = 0; float acc = 0, l, r;
        auto t0 = clk::now();
        for (int b = 0; b < 48000 * 10 / 64; b++) {
            auto a = clk::now();
            for (int j = 0; j < 64; j++) { rm.tick(L[(b * 64 + j) % len], R[(b * 64 + j) % len], l, r); acc += l; }
            double us = std::chrono::duration<double, std::micro>(clk::now() - a).count();
            if (us > worst) worst = us;
        }
        double sec = std::chrono::duration<double>(clk::now() - t0).count();
        std::printf("%-28s %11.2f%% %16.0f   (%g)\n", "THE ROOM, stereo", sec / 10 * 100, worst, acc);
    }
    for (double time : {0.2, 0.5, 1.5}) {
        // THE BUCKET BRIGADE delay, one channel, 16384 cells
        std::vector<float> mem(8192);
        static BBDDelay dl; dl.init(mem.data(), 8192, 48000); dl.set(time, 0.35);
        double worst = 0; float acc = 0;
        auto t0 = clk::now();
        for (int b = 0; b < 48000 * 10 / 64; b++) {
            auto a = clk::now();
            for (int j = 0; j < 64; j++) acc += dl.tick(L[(b * 64 + j) % len], 0.5f, 0.5f);
            double us = std::chrono::duration<double, std::micro>(clk::now() - a).count();
            if (us > worst) worst = us;
        }
        double sec = std::chrono::duration<double>(clk::now() - t0).count();
        char name[64]; std::snprintf(name, sizeof name, "BBD delay, mono, %.1f s", time);
        std::printf("%-28s %11.2f%% %16.0f   (clock %.0f Hz, %g)\n", name, sec / 10 * 100, worst, dl.chain.inc * 48000, acc);
    }
    {
        // THE CLOUD (FourCloud): the Clouds core, stereo noise in, 10 s, in
        // each mode, set as the engine sets it at rest (size 0.1 s, density 20)
        std::vector<uint8_t> large(118784), small(65536 - 128);
        alignas(16) static unsigned char mem[sizeof(clouds::GranularProcessor)];
        clouds::FloatFrame in[32], out[32];
        const char* names[] = {"CLOUD, granular", "CLOUD, stretch", "CLOUD, looping delay",
                               "CLOUD, spectral", "CLOUD, granular, low fi"};
        for (int m = 0; m < 5; m++) {
            clouds::GranularProcessor* gp = new (mem) clouds::GranularProcessor;
            std::memset(static_cast<void*>(gp), 0, sizeof(clouds::GranularProcessor));
            gp->Init(large.data(), large.size(), small.data(), small.size());
            gp->set_sample_rate(48000.f); gp->set_num_channels(2); gp->set_low_fidelity(m == 4);
            gp->set_playback_mode((clouds::PlaybackMode)(m < 4 ? m : 0));
            clouds::Parameters* p = gp->mutable_parameters();
            p->pitch = 0; p->position = 0.5f; p->size = 0.247f; p->density = 0.185f; p->texture = 0.5f;
            p->dry_wet = 1; p->stereo_spread = 0.5f; p->reverb = 0; p->feedback = 0; p->freeze = false;
            double worst = 0; float acc = 0;
            auto t0 = clk::now();
            for (int b = 0; b < 48000 * 10 / 64; b++) {
                auto a = clk::now();
                for (int h = 0; h < 2; h++) {           // a block of 64 is two of the core's 32
                    for (int j = 0; j < 32; j++) {
                        in[j].l = L[(b * 64 + h * 32 + j) % len]; in[j].r = R[(b * 64 + h * 32 + j) % len];
                    }
                    gp->Process(in, out, 32); gp->Prepare();
                    acc += out[0].l;
                }
                double us = std::chrono::duration<double, std::micro>(clk::now() - a).count();
                if (us > worst) worst = us;
            }
            double sec = std::chrono::duration<double>(clk::now() - t0).count();
            std::printf("%-28s %11.2f%% %16.0f   (%g)\n", names[m], sec / 10 * 100, worst, acc);
        }
    }
    std::printf("one block is 1333 us\n");
}
