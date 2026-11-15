# Measures the renders of probe.scd. usage: an_probe.py <work> <tag>
import sys, numpy as np, soundfile as sf
d, tag = sys.argv[1], sys.argv[2]
sr = 48000
db = lambda x: 20 * np.log10(max(abs(x), 1e-15))
def rd(n):
    x, _ = sf.read(f'{d}/{tag}_{n}.wav'); return x
def amp(x, f):
    n = len(x); w = np.hanning(n); t = np.arange(n) / sr
    return 2 * abs(np.sum(w * x * np.exp(-2j * np.pi * f * t))) / w.sum()

print(f"==== {tag}")
# 1. the filter, from its impulse response
x = rd('filt'); i0 = int(0.1 * sr)
names = ['LO 20k res 0 (open)', 'LO 1k res 0', 'LO 1k res .9', 'HI 1k res 0', 'HI 1k res .9', 'BP 1k res .5', 'BP 1k res 0', 'LO 19k res 0']
print("1. FILTER (impulse response, dB at the frequency)")
for k, n in enumerate(names):
    h = x[i0 - 64: i0 - 64 + 32768, 2 * k]
    H = np.abs(np.fft.rfft(h)); f = np.fft.rfftfreq(len(h), 1 / sr)
    at = lambda fr: db(H[np.abs(f - fr).argmin()])
    if k in (0, 7):
        print(f"  {n:22s} " + "  ".join(f"{fr/1000:g}k {at(fr):+.2f}" for fr in [100, 1000, 5000, 10000, 16000, 19000, 20000]))
    else:
        pk = f[H.argmax()]
        print(f"  {n:22s} peak {db(H.max()):+5.1f} dB at {pk:5.0f} Hz | " + "  ".join(f"{fr:g} {at(fr):+.1f}" for fr in [125, 250, 500, 1000, 2000, 4000, 8000]))
# 2. the limiters
x = rd('lim')
print("2. LIMITERS, a centred 200 Hz tone; L alone gets a loud 1 kHz burst from 1.5 to 1.8 s")
for (a, b) in [(1.0, 1.4), (1.55, 1.75), (2.2, 2.6)]:
    s = x[int(a * sr): int(b * sr)]
    l, r = amp(s[:, 0], 200), amp(s[:, 1], 200)
    print(f"  master out {a:.2f}-{b:.2f} s: 200 Hz L {db(l):6.2f} R {db(r):6.2f} dBFS, image L-R {db(l) - db(r):+5.2f} dB, peak L {np.abs(s[:,0]).max():.3f}")
rl, _ = sf.read(f'{d}/{tag}_limrecL.wav'); rr, _ = sf.read(f'{d}/{tag}_limrecR.wav')
# the take: rec from 0.5 s, so take time t is render time t + 0.5
for (a, b) in [(0.5, 0.9), (1.05, 1.25)]:
    l, r = amp(rl[int(a * sr): int(b * sr)], 200), amp(rr[int(a * sr): int(b * sr)], 200)
    print(f"  the take {a:.2f}-{b:.2f} s: 200 Hz L {db(l):6.2f} R {db(r):6.2f}, image {db(l) - db(r):+5.2f} dB")
s = rr[int(0.5 * sr): int(0.9 * sr)]
print(f"  the take, LeakDC on the dry arm: 40 Hz {db(amp(s, 40) / 0.15):+.2f} dB, 100 Hz {db(amp(s, 100) / 0.15):+.2f} dB, 200 Hz {db(amp(s, 200) / 0.4):+.2f} dB")
# 3. shimmer
x = rd('shim')
print("3. SHIMMER, burst at 0.1 s: RMS dBFS at 2, 5, 10, 20, 29 s")
for k, n in enumerate(['decay 30, shim .95, 0 st', 'decay 30, shim .95, +12', 'decay 30, shim .95, -12', 'decay 2, shim .95, 0 st', 'decay 30, shim 0', 'decay 8, shim .7, 0 st']):
    v = [db(np.sqrt(np.mean(x[int(t * sr): int((t + 0.5) * sr), 2 * k] ** 2))) for t in [2, 5, 10, 20, 29]]
    pk = np.abs(x[:, 2 * k]).max()
    print(f"  {n:26s} " + " ".join(f"{u:7.1f}" for u in v) + f"   peak {pk:.2f}")
# 4. the room's knobs
x = rd('rsize'); a = int(1.4 * sr)
A, B, C, D, E = [x[a:, 2 * k] for k in range(5)]
print("4. ROOM KNOBS on a live synth (bursts from 1.5 s)")
print(f"  A (size 1, then 2 and seven other knobs at 1 s) minus B (left alone): {db(np.abs(A - B).max())} dBFS peak; B level {db(np.abs(B).max()):.1f}")
print(f"  A minus C (started at size 2): {db(np.sqrt(np.mean((A - C) ** 2)) / np.sqrt(np.mean(C ** 2))):+.1f} dB re C")
print(f"  D (size 4) minus E (size 2.1): {db(np.abs(D - E).max())} dBFS peak")
# 5. erosion
print("5. EROSION, a 5 kHz take, erode 1 for 12 s: energy off the tone in the window, dB")
for n in ['ero_late', 'erox_late', 'ero_early', 'erox_early']:
    y, _ = sf.read(f'{d}/{tag}_{n}.wav')
    lo = 0.9 if 'late' in n else 0.05
    s = y[int((lo + 0.02) * 60 * sr): int((lo + 0.02) * 60 * sr) + 131072]
    w = np.blackman(len(s)); S = np.abs(np.fft.rfft(s * w)) ** 2; f = np.fft.rfftfreq(len(s), 1 / sr)
    m = np.abs(f - 5000) > 60
    print(f"  {n:11s} off-tone {10*np.log10(S[m].sum()/S.sum()):7.1f} dB, tone {db(amp(s, 5000)):.2f} dBFS")
# 6. mode change
x = rd('mode')
print("6. MODE CHANGE from PLAY at 1.0 s, 1 kHz take at -6 dBFS: 5 ms RMS")
for k, n in enumerate(['to WARP', 'to PV', 'to GRAIN', 'to PLAY']):
    y = x[:, 2 * k]; win = 240
    e = np.sqrt(np.convolve(y ** 2, np.ones(win) / win, 'same'))
    ref = np.median(e[int(0.6 * sr): int(0.95 * sr)])
    seg = e[int(1.0 * sr): int(1.6 * sr)]
    mn = seg.min(); tmin = seg.argmin() / sr * 1000
    end = np.median(e[int(1.7 * sr): int(1.95 * sr)])
    below = np.where(np.abs(20 * np.log10(np.maximum(seg, 1e-9) / end)) > 1.0)[0]
    rec = (below.max() + 1) / sr * 1000 if len(below) else 0
    print(f"  {n:9s} deepest {db(mn / ref):+6.1f} dB at {tmin:4.0f} ms, within 1 dB of its level after {rec:4.0f} ms, new level {db(end / ref):+5.1f} dB")
# 7. effects' gain
x = rd('flres'); a = 2 * sr
print("7. EFFECT GAIN, amount 1, rate 0.5")
nz = x[a:, 12]; sn = x[a:, 14]
def tf(y, ref):
    from scipy.signal import csd, welch
    f, P = csd(ref, y, fs=sr, nperseg=4096); f, R = welch(ref, fs=sr, nperseg=4096)
    g = np.abs(P) / R; return f, g
for k, n in [(0, 'FLANGE (plugin)'), (1, 'FLANGE (stock comb)'), (5, 'ECHO')]:
    y = x[a:, 2 * k]
    if np.abs(y).max() == 0: print(f"  {n}: (absent)"); continue
    f, g = tf(y, nz)
    print(f"  {n:20s} RMS {db(np.std(y)/np.std(nz)):+5.1f} dB, peak {np.abs(y).max():.2f} (dry peak {np.abs(nz).max():.2f}), largest gain over noise {db(g[1:].max()):+5.1f} dB at {f[1:][g[1:].argmax()]:.0f} Hz")
y = x[a:, 4]
if np.abs(y).max() > 0:
    c = np.correlate(y[:48000], nz[:48000 + 200][100:], 'valid') if False else None
    xc = [np.dot(y[200:20200], nz[200 - L: 20200 - L]) for L in range(0, 120)]
    print(f"  FLANGE amount 0: the output is the dry signal {int(np.argmax(xc))} samples late ({np.argmax(xc)/48:.2f} ms)")
for k, n, ref, rl in [(3, 'RESON on an in-tune C4 tone', sn, 0.25), (4, 'RESON on noise', nz, None)]:
    y = x[a:, 2 * k]
    print(f"  {n:28s} RMS {db(np.std(y)/np.std(ref)):+5.1f} dB, peak {np.abs(y).max():.2f} (dry peak {np.abs(ref).max():.2f})" +
          (f", H3 {db(amp(y[:65536], 3 * 261.6256) / amp(y[:65536], 261.6256)):+.1f} dB re H1" if rl else ""))
# 8. delay times
x = rd('bbd'); i0 = int(0.5 * sr)
print("8. DELAY, a click at 0.5 s: where the first echo lands")
for k, t in enumerate([0.01, 0.02, 0.043, 0.1]):
    y = np.abs(x[i0:, 2 * k]); pk = y.argmax()
    print(f"  delay_time {t:5.3f} s: echo peak at {pk / sr * 1000:6.1f} ms")
# 9. grain
x = rd('grain'); a = sr
print("9. GRAIN at pitch 1 against PLAY, noise take: band level re 800 Hz, dB")
from scipy.signal import welch
for k, n in [(0, 'GRAIN'), (1, 'PLAY')]:
    f, P = welch(x[a:, 2 * k], fs=sr, nperseg=8192)
    band = lambda c: 10 * np.log10(P[(f > c / 2 ** (1 / 6)) & (f < c * 2 ** (1 / 6))].mean())
    print(f"  {n:6s} " + "  ".join(f"{c/1000:g}k {band(c) - band(800):+5.2f}" for c in [100, 1000, 5000, 10000, 16000, 19000]))
for k, n in [(2, 'GRAIN pitch 2'), (3, 'PLAY pitch 2')]:
    y = x[a:, 2 * k]
    print(f"  {n:13s} on a 5 kHz take: 10 kHz {db(amp(y, 10000)):6.1f} dBFS; images: 20 kHz {db(amp(y, 20000)):6.1f}, 14 kHz {db(amp(y, 14000)):6.1f}, 6 kHz {db(amp(y, 6000)):6.1f}")
y = x[a:, 8]
print(f"  PLAY at scan 0: output mean {np.mean(y):+.4f}, std {np.std(y):.2e} (a held sample: DC)")
