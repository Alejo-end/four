import sys, numpy as np, soundfile as sf
from scipy.signal import get_window
d, tag = sys.argv[1], sys.argv[2]; sr = 48000
db = lambda x: 20 * np.log10(max(abs(x), 1e-30))
def rd(n): x, _ = sf.read(f'{d}/{tag}_{n}.wav'); return x
def amp(x, f):
    n = len(x); w = np.hanning(n); t = np.arange(n) / sr
    return 2 * abs(np.sum(w * x * np.exp(-2j * np.pi * f * t))) / w.sum()
print(f"==== {tag}")
x = rd('res'); i0 = int(0.1 * sr)
print("a. RESONANCE, stock path (impulse response)")
for k, (cf, r) in enumerate([(1000, .5), (1000, .9), (5000, .5), (5000, .9), (10000, .5), (10000, .9)]):
    h = x[i0 - 64: i0 - 64 + 32768, 2 * k]; H = np.abs(np.fft.rfft(h)); f = np.fft.rfftfreq(len(h), 1 / sr)
    print(f"  cutoff {cf:5d} res {r}: peak {db(H.max()):+5.1f} dB at {f[H.argmax()]:6.0f} Hz")
y, _ = sf.read(f'{d}/{tag}_rectake.wav')
# the take: rec from the start; the click at 1.0 s (plus 4 ms of limiter delay)
y = y if y.ndim == 1 else y[:, 0]; e = np.abs(y); env = np.sqrt(np.convolve(y ** 2, np.ones(240) / 240, 'same'))
base = np.median(env[int(0.5 * sr): int(0.9 * sr)])
seg = env[int(0.95 * sr): int(1.1 * sr)]
print(f"e. RECORD LIMITER: take peak {e.max():.3f}; samples above 0.99: {np.sum(e > 0.99)}; the 200 Hz tone around the click: min {db(seg.min()/base):+.1f} dB")
g = y[int(0.98 * sr): int(1.03 * sr)]; tone = 0.3 * np.sin(2 * np.pi * 200 * (np.arange(len(y)) / sr))
# gain applied: compare the take with the input shifted by the limiter's 4 ms
lag = int(0.004 * sr); src = tone.copy(); c0 = int(1.0 * sr); src[c0: c0 + 48] += 1.5
ratio = []
for i in range(int(0.98 * sr), int(1.03 * sr)):
    j = i - lag
    if abs(src[j]) > 0.05: ratio.append((i, y[i] / src[j]))
r = np.array(ratio); dip = r[r[:, 1] < 0.995]
print(f"   gain below 0.995 for {(dip[:,0].max()-dip[:,0].min())/48:.1f} ms around the click, least gain {db(r[:,1].min()):+.1f} dB" if len(dip) else "   no gain change")
x = rd('colour'); a = sr // 2
print("f, g. COLOUR on a 1 kHz sine: output level against input, harmonics, DC")
for k, (lv, dr, cr) in enumerate([(.25, .25, 0), (.25, .5, 0), (.25, 1, 0), (.5, .25, 0), (.5, 1, 0), (.25, 0, .5), (.25, 0, 1), (.5, 0, 1)]):
    s = x[a: a + 65536, 2 * k]; h1 = amp(s, 1000)
    hs = " ".join(f"H{n} {db(amp(s, 1000 * n) / h1):6.1f}" for n in (2, 3, 5))
    print(f"  in {db(lv):5.1f} dBFS drive {dr:4.2f} crush {cr:3.1f}: level {db(np.std(s)/(lv/np.sqrt(2))):+5.1f} dB, {hs}, DC {np.mean(s):+.5f}")
y = rd('drive5k')[sr // 2: sr // 2 + 65536, 0]
X = np.abs(np.fft.rfft(y * get_window('blackmanharris', len(y)))) ** 2; f = np.fft.rfftfreq(len(y), 1 / sr)
band = f < 16000; odd = (np.abs(f - 5000) < 60) | (np.abs(f - 15000) < 60)
print(f"r. DRIVE 1, a 5 kHz sine at -6 dBFS: energy below 16 kHz that is not an odd harmonic {10 * np.log10(X[band & ~odd].sum() / X[band].sum()):.1f} dB")
x = rd('gedge'); a = sr
print("j. GRAIN in a 12 ms window (a 1 kHz island in a 7 kHz buffer): energy from outside the window")
for k, n in enumerate(['size 0.5 s', 'size 0.01 s', 'size 0.5 s, scan -1', 'size 0.1, 72 ms window']):
    s = x[a:, 2 * k]; i, o = amp(s, 1000), amp(s, 7000)
    print(f"  {n:22s} 7 kHz (outside) {db(o / max(i, 1e-12)):+6.1f} dB re 1 kHz (inside)")
x = rd('rv'); i0 = int(0.1 * sr)
print("o. REVERB, a click: level of the first 0.5 s and T60 (from -5 to -35 dB of the Schroeder curve)")
for k, dc in enumerate([0.8, 2, 7]):
    h = x[i0:, 2 * k]; E = np.cumsum(h[::-1] ** 2)[::-1]; L = 10 * np.log10(E / E[0] + 1e-300)
    t5 = np.argmax(L < -5) / sr; t35 = np.argmax(L < -35) / sr
    print(f"  decay {dc:3.1f} s: level {10*np.log10(np.sum(h[:sr//2]**2)+1e-30):+6.1f} dB, T60 {2*(t35-t5):5.2f} s")
x = rd('shim2')
print("p. SHIMMER 0.95, decay 30, 60 s: RMS dBFS at 5, 15, 30, 59 s, peak, smallest nonzero |x| in the last second")
for k, n in enumerate(['burst, -12 st', 'burst, -7 st', 'burst, +7 st', 'burst, +24 st', '40 Hz 0 dBFS 10 s, 0 st', '40 Hz, +12', 'DC 0.5 10 s, 0 st', 'DC 0.5, +12']):
    y = x[:, 2 * k]; v = [db(np.sqrt(np.mean(y[int(t * sr): int((t + 0.5) * sr)] ** 2))) for t in [5, 15, 30, 59]]
    tail = np.abs(y[-sr:]); nz = tail[tail > 0]
    print(f"  {n:24s} " + " ".join(f"{u:7.1f}" for u in v) + f"  peak {np.abs(y).max():5.2f}  min {nz.min() if len(nz) else 0:.1e}  mean {np.mean(y[-sr:]):+.1e}")
y = rd('dglide')[:, 0]
print("q. DELAY time 0.3 to 0.1 s, a 1 kHz tone: during the glide (1.35 to 1.6 s, the echo's pitch moves)")
s = y[int(1.35 * sr): int(1.35 * sr) + 8192]
w = get_window('blackmanharris', len(s)); X = np.abs(np.fft.rfft(s * w)); f = np.fft.rfftfreq(len(s), 1 / sr)
pk = f[X.argmax()]; m = (np.abs(f - pk) > 200)
side = X.copy(); side[~m] = 0
print(f"  main {pk:6.0f} Hz; the largest component 200 Hz or more away: {db(side.max()/X.max()):+.1f} dB at {f[side.argmax()]:.0f} Hz")
