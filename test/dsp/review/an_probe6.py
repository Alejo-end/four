# Measures probe6: the effect slot at a change of type. usage: an_probe6.py <work> <tag>
#
# Two laws, the same as test/device/audio.py, on BOTH channels:
#   click  a jump in the samples: one second difference above 0.006 and above
#          12 times the mean of the 10 ms before it (audio.clicks)
#   gap    a 5 ms stretch more than 10 dB under both the 50 ms before it and
#          the 50 ms after it (audio.gaps). A level that steps down and stays
#          down is not a gap.
# For each change it also reads the deepest 5 ms against the quieter of the
# levels before and after, for the engine's crossover (the two synths in
# SERIES on the lane's bus) and for the same two synths side by side, built
# from three lanes: (a to OFF) + (OFF to b) - the tone.
import sys, numpy as np, soundfile as sf
d, tag = sys.argv[1], sys.argv[2]
SR = 48000
NAMES = ['OFF', 'CHORUS', 'FLANGE', 'WOBBLE', 'RESON', 'RING', 'ECHO']
T = 1.5404

def clicks(x, ratio=12.0, floor=0.006):
    d2 = np.abs(x[2:] - 2 * x[1:-1] + x[:-2]); win = int(SR * 0.01)
    c = np.concatenate([[0.0], np.cumsum(d2)])
    local = (c[win:len(d2)] - c[:len(d2) - win]) / win
    hit = np.where((d2[win:] > floor) & (d2[win:] > ratio * np.maximum(local, 1e-5)))[0] + win
    out = []
    for i in hit:
        t = (i + 2) / SR
        if not out or t - out[-1] > 0.02:
            out.append(round(t, 3))
    return out

def gaps(x, depth=10.0, floor=1e-3):
    w5, w50, hop = int(SR * 0.005), int(SR * 0.05), SR // 1000
    c = np.concatenate([[0.0], np.cumsum(x * x)])
    i = np.arange(w50, len(x) - w5 - w50, hop)
    mid = (c[i + w5] - c[i]) / w5
    side = np.minimum(c[i] - c[i - w50], c[i + w5 + w50] - c[i + w5]) / w50
    hit = i[(side > floor * floor) & (mid < side * 10 ** (-depth / 10))]
    out = []
    for k in hit:
        t = k / SR
        if not out or t - out[-1] > 0.05:
            out.append(round(t, 3))
    return out

def rms_db(x):
    return 10 * np.log10(max(np.mean(x * x), 1e-20))

# the deepest 5 ms from the change to 300 ms after it, against the quieter of
# the level before (200 ms) and the level after (500 ms to 1 s later)
def dip(x):
    i0, w5 = int(T * SR), int(SR * 0.005)
    ref = min(rms_db(x[i0 - int(0.2 * SR): i0 - 480]), rms_db(x[i0 + int(0.5 * SR): i0 + SR]))
    c = np.concatenate([[0.0], np.cumsum(x * x)])
    k = np.arange(i0, i0 + int(0.3 * SR), 48)
    return 10 * np.log10(np.maximum((c[k + w5] - c[k]) / w5, 1e-20)).min() - ref

# the largest second difference from the change to 600 ms after it, on either
# channel, and how many ms after the change it lies
def step(y):
    i0 = int(T * SR)
    d2 = np.abs(np.diff(y[i0 - 2: i0 + int(0.6 * SR)], 2, axis=0)).max(axis=1)
    return d2.max(), d2.argmax() / SR * 1000

x, _ = sf.read(f'{d}/{tag}_walk.wav')
wc = [clicks(x[:, ch]) for ch in range(2)]
wg = [gaps(x[:, ch]) for ch in range(2)]
print("THE SIX TAPS of row 19.12 (CHORUS, then FLANGE WOBBLE RESON RING ECHO CHORUS at 1.004 s and each 0.6 s)")
print(f"  clicks  left {wc[0]}  right {wc[1]}")
print(f"  gaps    left {wg[0]}  right {wg[1]}")
print(f"WALK clicks {len(wc[0]) + len(wc[1])} gaps {len(wg[0]) + len(wg[1])}")

x, _ = sf.read(f'{d}/{tag}_pairs.wav')
lane = lambda a, b: x[:, (a * 7 + b) * 2: (a * 7 + b) * 2 + 2]
dry = x[:, 98:100]
i0 = int(T * SR) - 480
nclick = ngap = 0
worst_s, worst_p, worst_d, worst_step = (0, ''), (0, ''), (0, ''), (0, '')
print(f"EVERY CHANGE at {T} s (42 of them), from {i0 / SR:.3f} s on")
print("  change            clicks L R   gaps L R   deepest 5 ms: series  side by side (dB)   largest step, ms after the change: series, side by side")
for a in range(7):
    for b in range(7):
        if a == b:
            continue
        y = lane(a, b)
        ck = [clicks(y[i0:, ch]) for ch in range(2)]
        gp = [gaps(y[i0 - int(0.09 * SR):, ch]) for ch in range(2)]
        nclick += len(ck[0]) + len(ck[1]); ngap += len(gp[0]) + len(gp[1])
        ds = min(dip(lane(a, b)[:, ch]) for ch in range(2))
        par = lane(a, 0) + lane(0, b) - dry
        dp = min(dip(par[:, ch]) for ch in range(2))
        name = f"{NAMES[a]} to {NAMES[b]}"
        worst_s = min(worst_s, (ds, name)); worst_p = min(worst_p, (dp, name))
        worst_d = min(worst_d, (ds - dp, name))
        ss, sp = step(y), step(par)
        worst_step = max(worst_step, (ss[0], name))
        print(f"  {name:17s} {len(ck[0]):5d} {len(ck[1]):2d} {len(gp[0]):7d} {len(gp[1]):2d}"
              f"   {ds:15.1f} {dp:12.1f}          {ss[0]:.4f} at {ss[1]:5.1f}   {sp[0]:.4f} at {sp[1]:5.1f}")
print(f"PAIRS clicks {nclick} gaps {ngap}")
print(f"LARGEST step after a change {worst_step[0]:.4f} ({worst_step[1]}); the tone alone {step(dry)[0]:.4f}")
print(f"DEEPEST series {worst_s[0]:.1f} dB ({worst_s[1]}), side by side {worst_p[0]:.1f} dB ({worst_p[1]}), "
      f"series under side by side by at most {-worst_d[0]:.1f} dB ({worst_d[1]})")

# the shared delay born under the tone, and a filter family swap
x, _ = sf.read(f'{d}/{tag}_more.wav')
def step_at(y, t0, t1):
    d2 = np.abs(np.diff(y[int(t0 * SR) - 2: int(t1 * SR)], 2, axis=0)).max(axis=1)
    return d2.max(), d2.argmax() / SR * 1000
v, ms = step_at(x[:, 0:2], T, T + 1.2)
print(f"DELAY born under the tone: largest step {v:.4f}, {ms:.1f} ms after its start; "
      f"clicks {sum(len(clicks(x[int(T * SR) - 480:, ch])) for ch in range(2))}")
for name, t in [('LP to HP', T), ('HP to BP', T + 0.5)]:
    v, ms = step_at(x[:, 2:4], t, t + 0.3)
    n = sum(len(clicks(x[int(t * SR) - 480: int((t + 0.3) * SR), ch])) for ch in (2, 3))
    print(f"FILTER {name} at 400 Hz: largest step {v:.4f}, {ms:.1f} ms after the change; clicks {n}")
