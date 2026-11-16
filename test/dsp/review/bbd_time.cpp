// BBD::tick against the reference of test_core (the per-tick law of before
// 2026-11-15): the time a sample at four clocks, best of five.
// clang++ -O2 -std=c++17 -I../../../ugen -I../../../ugen/vendor/eurorack bbd_time.cpp -o /tmp/bbd_time (from this folder)
#include <cstdio>
#include <chrono>
#include <vector>
#include <random>
#define main test_main
#include "../../../ugen/test_core.cpp"
#undef main
typedef std::chrono::steady_clock clk;
int main() {
    std::vector<float> in(48000); std::mt19937 r(1); std::normal_distribution<float> n(0, 0.1f); for (auto& v : in) v = n(r);
    for (double fc : {191753.0, 81987.0, 27315.0, 8194.0}) {
        double best[2] = {1e9, 1e9};
        for (int rep = 0; rep < 5; rep++) for (int k = 0; k < 2; k++) {
            std::vector<float> m(8192); static BBD a; static RefBBD b; a.init(m.data(), 8192, 48000); b.init(m.data(), 8192, 48000);
            a.setClock(fc, 0.35); b.setClock(fc, 0.35); float acc = 0;
            auto t0 = clk::now();
            for (int i = 0; i < 48000 * 4; i++) acc += k == 0 ? a.tick(in[i % 48000]) : b.tickRef(in[i % 48000]);
            double ns = std::chrono::duration<double, std::nano>(clk::now() - t0).count() / (48000 * 4);
            if (ns < best[k]) best[k] = ns; if (acc == 12345) std::printf("x");
        }
        std::printf("clock %6.0f Hz: before %5.1f ns a sample, now %5.1f ns (%+.0f%%)\n", fc, best[1], best[0], 100 * (best[0] / best[1] - 1));
    }
}
