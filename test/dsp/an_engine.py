# Reads <tag>_read.wav and <tag>_fx.wav (from engine.scd) and prints the measures.
# usage: python an_engine.py <work folder> <tag>
import sys, numpy as np, soundfile as sf
from scipy.signal import hilbert, get_window
d, tag = sys.argv[1], sys.argv[2]
sr = 48000
db = lambda x: 20 * np.log10(max(x, 1e-12))
def spec(x):
    w = get_window('blackmanharris', len(x)); X = np.abs(np.fft.rfft(x * w)) / (w.sum() / 2)
    return np.fft.rfftfreq(len(x), 1 / sr), X
def off_tone(x, f0, guard=60):
    f, X = spec(x); m = np.abs(f - f0) > guard; P = X ** 2
    i = np.where(m, X, 0).argmax()
    return 10 * np.log10(P[m].sum() / P.sum() + 1e-30), db(X[np.abs(f - f0) < guard].max()), (round(f[i]), round(db(X[i]), 1))
semi = 2 ** (1 / 12)
r, _ = sf.read(f'{d}/{tag}_read.wav'); r = r[sr // 2: sr // 2 + 2 * sr]
print("READ, a 5 kHz tone in a 60 s buffer: energy off the tone, dB re total")
cases = [('PLAY at 1 s, pitch 1', 5000), ('PLAY at 8 s, pitch 1', 5000), ('PLAY at 54 s, pitch 1', 5000),
         ('PLAY at 8 s, +1 st', 5000 * semi), ('PLAY at 54 s, +1 st', 5000 * semi),
         ('PLAY at 54 s, half speed', 2500), ('PV at 54 s', 5000), ('PLAY at 54 s, reverse', 5000)]
for i, (n, f0) in enumerate(cases):
    a, lv, top = off_tone(r[:, 2 * i], f0)
    print(f"  {n:26s} tone {lv:6.1f} dBFS  noise {a:7.1f} dB  top spur {top}")
x, _ = sf.read(f'{d}/{tag}_fx.wav'); x = x[sr: 4 * sr - 4800]
dry = x[:, 0]
def dev(w):
    ph = np.unwrap(np.angle(hilbert(w))); fi = np.diff(ph) * sr / (2 * np.pi)
    fi = np.convolve(fi, np.ones(96) / 96, 'same')[4800:-4800]
    return 1200 * np.log2(fi.min() / 1000), 1200 * np.log2(fi.max() / 1000)
print("EFFECT, pitch movement of the wet arm on a 1 kHz sine, cents")
for i, (n, a) in enumerate([('CHORUS amount 1, rate 1', 1), ('CHORUS amount .5, rate .5', .5), ('CHORUS amount 1, rate 0', 1)]):
    wet = (x[:, 2 * (i + 1)] - (1 - 0.3 * a) * dry) / (0.7 * a)
    lo, hi = dev(wet); print(f"  {n:28s} {lo:+7.1f} .. {hi:+7.1f}")
for i, n in enumerate(['WOBBLE amount 1, rate 1', 'WOBBLE amount 1, rate 0']):
    lo, hi = dev(x[:, 2 * (i + 4)]); print(f"  {n:28s} {lo:+7.1f} .. {hi:+7.1f}")
print(f"  effect OFF equals the strip input: level {db(np.std(dry) * 2 ** 0.5):.2f} dBFS")
m, _ = sf.read(f'{d}/{tag}_move.wav')
a, lv, top = off_tone(m[int(2.2 * sr): int(3.2 * sr), 0], 5000)
print(f"PLAY after a window move and a scan change: tone {lv:.1f} dBFS, noise {a:.1f} dB, top spur {top}")
import os
if os.path.exists(f'{d}/{tag}_stretch.wav'):
    z, _ = sf.read(f'{d}/{tag}_stretch.wav'); z = z[sr: sr + 2 * sr + 32768]
    print("STRETCH, a 5 kHz tone 54 s in: where the tone lands, its level, the energy off it, the level swing")
    names = ['PV speed 1', 'PV speed 0.5', 'PV speed 0.5, pitch 2', 'PV speed 1, frozen',
             'WARP speed 1', 'WARP speed 0.5', 'WARP speed 0.5, pitch 2', 'WARP speed 0.25']
    for i, n in enumerate(names):
        x = z[:, 2 * i]; f, X = spec(x); f0 = f[X.argmax()]
        a, lv, top = off_tone(x, f0)
        env = np.sqrt(np.convolve(x ** 2, np.ones(480) / 480, 'valid'))[::240]
        sw = db(env.max() / max(env.min(), 1e-9))
        print(f"  {n:24s} {f0:7.0f} Hz  {lv:6.1f} dBFS  off {a:7.1f} dB  swing {sw:5.2f} dB")
if os.path.exists(f'{d}/{tag}_cloud.wav'):
    c, _ = sf.read(f'{d}/{tag}_cloud.wav')
    print("CLOUD, the Clouds voice on a 1 kHz take at -9 dBFS: RMS and peak from 1 to 6 s, values not finite")
    for i, n in enumerate(['GRANULAR', 'STRETCH', 'LOOPING DELAY', 'SPECTRAL', 'GRANULAR, frozen at 2 s']):
        x = c[:, 2 * i: 2 * i + 2]; bad = int((~np.isfinite(x)).sum())
        y = np.nan_to_num(x[sr: 6 * sr], nan=0.0, posinf=0.0, neginf=0.0)
        print(f"  {n:24s} RMS {db(np.sqrt(np.mean(y ** 2))):6.1f} dBFS  peak {np.abs(y).max():5.2f}  not finite {bad}")
