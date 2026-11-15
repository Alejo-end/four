import sys, numpy as np, soundfile as sf
d, tag = sys.argv[1], sys.argv[2]; sr = 48000
db = lambda x: 20 * np.log10(max(abs(x), 1e-15))
def amp(x, f):
    n = len(x); w = np.hanning(n); t = np.arange(n) / sr
    return 2 * abs(np.sum(w * x * np.exp(-2j * np.pi * f * t))) / w.sum()
print("EROSION by place, erode 1 for 12 s, a region passed 3 times (1.0 to 2.0 s into the window)")
for i, p in enumerate([0.05, 0.3, 0.5, 0.9]):
    y, _ = sf.read(f'{d}/{tag}_ero2_{i}.wav')
    a = int(p * 60 * sr + 1.0 * sr); s = y[a: a + sr]
    w = np.blackman(len(s)); S = np.abs(np.fft.rfft(s * w)) ** 2; f = np.fft.rfftfreq(len(s), 1 / sr)
    m = np.abs(f - 5000) > 60
    print(f"  window {p:.2f}-{p+0.08:.2f} ({p*60:4.1f} s in): tone {db(amp(s, 5000)):6.2f} dBFS, off-tone {10*np.log10(S[m].sum()/S.sum()):6.1f} dB")
x, _ = sf.read(f'{d}/{tag}_gap.wav')
y = x[:, 0]; i0 = sr
nz = np.where(np.abs(y[i0 + 960: i0 + 9600]) > 1e-6)[0]
e = np.sqrt(np.convolve(y ** 2, np.ones(48) / 48, 'same'))
quiet = np.where(e[i0: i0 + 4800] < 0.5 * 10 ** (-60 / 20))[0]
print(f"GRAIN after a mode change at 1 s: the output is below -60 dBFS (1 ms RMS) from {quiet.min()/48:.1f} to {quiet.max()/48:.1f} ms" if len(quiet) else "no gap")
y = x[:, 2]
print(f"PLAY with scan set to 0 mid-window at 1.0123 s: mean of 1.5 to 2 s {np.mean(y[int(1.5*sr):]):+.4f}, std {np.std(y[int(1.5*sr):]):.1e}")
x, _ = sf.read(f'{d}/{tag}_cand.wav'); i0 = int(0.1 * sr)
print("CANDIDATE stock filter (BLowPass, RBJ), impulse response")
for k, n in enumerate(['open 20k', 'LP 1k res 0', 'LP 1k res .9', 'LP 19k']):
    h = x[i0 - 64: i0 - 64 + 32768, 2 * k]; H = np.abs(np.fft.rfft(h)); f = np.fft.rfftfreq(len(h), 1 / sr)
    at = lambda fr: db(H[np.abs(f - fr).argmin()])
    print(f"  {n:13s} peak {db(H.max()):+5.1f} dB at {f[H.argmax()]:5.0f} Hz | " + "  ".join(f"{fr/1000:g}k {at(fr):+.2f}" for fr in [0.5e3, 1e3, 2e3, 5e3, 10e3, 16e3, 19e3]))
