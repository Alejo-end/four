# Measures probe7: what each effect does to a phrase at each amount.
# usage: an_probe7.py <work> <tag>
#
# For each lane, against the phrase alone, from 1 s to the end, both channels:
#   level   RMS of the lane over RMS of the phrase, in dB
#   peak    the largest sample (the phrase alone peaks near 0.5)
#   width   RMS of left minus right over RMS of left plus right, in dB. The
#           phrase is the same on both sides, so alone it has no width.
#   moved   how far the spectrum moved: the mean distance in dB between the
#           lane and the phrase, over every 43 ms frame and every band that
#           sounds in either one (within 60 dB of the loudest). 0 is the phrase
#           itself. A gain of 3 dB and nothing else reads 3. The lane is first
#           moved back by the delay its TYPE has at amount 0, where the lane is
#           a late copy of the phrase and nothing else: WOBBLE is 12 ms late at
#           every amount, and the plugin's FLANGE 1.4 ms. So a late copy reads 0.
# "moved" is one number for "how much you notice the effect". It is not an ear.
import sys, numpy as np, soundfile as sf
from scipy.signal import stft
d, tag = sys.argv[1], sys.argv[2]
SR = 48000
NAMES = ['CHORUS', 'FLANGE', 'WOBBLE', 'RESON', 'RING', 'ECHO']
AMTS = [0, 0.25, 0.5, 0.75, 1]

x, sr = sf.read(f'{d}/{tag}_amt.wav')
assert sr == SR and x.shape[1] == 62, (sr, x.shape)
x = x[SR:]
dry = x[:, 60:62]

def db(v):
    return 20 * np.log10(max(v, 1e-12))

def spec(y):
    _, _, Z = stft(y, fs=SR, nperseg=2048, noverlap=1536, window='hann', boundary=None)
    return 20 * np.log10(np.abs(Z) + 1e-9)

DRY = [spec(dry[:, c]) for c in (0, 1)]

def lag(lane):
    """The delay of a lane behind the phrase, in samples, 0 to 30 ms. Read it
    on a type's lane at amount 0: a lane that is far from the phrase (RING at
    its top) matches it at no delay, and its best match is chance."""
    n = 4 * SR
    a, b = lane[:n, 0], dry[:n, 0]
    f = np.fft.rfft(a, 2 * n) * np.conj(np.fft.rfft(b, 2 * n))
    return int(np.argmax(np.fft.irfft(f)[:int(0.03 * SR)]))

def moved(lane, k=0):
    out = []
    for c in (0, 1):
        W, D = spec(lane[k:, c]), spec(dry[:len(dry) - k, c]) if k else DRY[c]
        floor = max(W.max(), D.max()) - 60
        m = (W > floor) | (D > floor)
        out.append(np.mean(np.abs(np.maximum(W, floor)[m] - np.maximum(D, floor)[m])))
    return float(np.mean(out))

print(f"THE PHRASE alone: RMS {db(np.sqrt(np.mean(dry ** 2))):.1f} dBFS, peak {np.abs(dry).max():.3f}, "
      f"moved against itself {moved(dry):.2f} dB")
print("EACH EFFECT at each amount, rate 0.5: level dB / peak / width dB / moved dB")
rows = {}
for t, name in enumerate(NAMES):
    line = []
    late = lag(x[:, 2 * (t * 5): 2 * (t * 5) + 2])
    for a, amt in enumerate(AMTS):
        lane = x[:, 2 * (t * 5 + a): 2 * (t * 5 + a) + 2]
        lv = db(np.sqrt(np.mean(lane ** 2)) / np.sqrt(np.mean(dry ** 2)))
        pk = np.abs(lane).max()
        side, mid = lane[:, 0] - lane[:, 1], lane[:, 0] + lane[:, 1]
        wd = db(np.sqrt(np.mean(side ** 2)) / max(np.sqrt(np.mean(mid ** 2)), 1e-12))
        mv = moved(lane, late)
        rows[(name, amt)] = (lv, pk, wd, mv)
        line.append(f"{amt:g}: {lv:+5.1f} {pk:.2f} {wd:6.1f} {mv:5.2f}")
    print(f"  {name:7s} " + "  |  ".join(line) + f"  (late by {late / SR * 1000:.1f} ms)")
print()
for name in NAMES:
    print(f"MOVED {name} at the start amount 0.5: {rows[(name, 0.5)][3]:.2f} dB")
for name in NAMES:
    print(f"MOVED {name} at amount 1: {rows[(name, 1)][3]:.2f} dB")
for name in NAMES:
    print(f"MOVED {name} at amount 0: {rows[(name, 0)][3]:.2f} dB")
print(f"LOUDEST lane: {max(v[0] for v in rows.values()):+.1f} dB over the phrase")
print(f"QUIETEST lane: {min(v[0] for v in rows.values()):+.1f} dB under the phrase")
print(f"LARGEST peak: {max(v[1] for v in rows.values()):.3f}")
