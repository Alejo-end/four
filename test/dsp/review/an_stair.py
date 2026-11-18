# Measures probe4's job s, the modulated knob. usage: an_stair.py <work> <tag>
#
# Two engine paths, one value for each 64 sample block:
#   level:  channel 0, DC 0.5 times track 2's level, read at the middle of a block
#   cutoff: channel 2, the amplitude of the 3 kHz tone after the lane filter, from
#           the block's own samples (a block holds exactly four periods)
# Three numbers for each, from 1.5 s to 11 s. None of them can be met by a
# probe that steps in phase with the engine: the frames come at random places.
#   still:   the share of the time the output stands still while the knob is
#            meant to move fast. The reference is the output itself, low-passed
#            at 3 Hz both ways (no delay); "fast" is more than half its top
#            speed, and "still" is less than a quarter of the reference speed.
#   longest: the longest such stand, in ms.
#   ripple:  everything above 5 Hz, in dB against the swing of the reference.
#            A smooth 0.25 Hz sweep has nothing there; a staircase does.
import sys, numpy as np, soundfile as sf
from scipy.signal import butter, sosfiltfilt
d, tag = sys.argv[1], sys.argv[2]
SR, BL = 48000, 64
FB = SR / BL

def level_path(x):
    return x[BL // 2::BL, 0]

def cutoff_path(x):
    n = len(x) // BL
    y = x[:n * BL, 2].reshape(n, BL)
    t = np.arange(BL) / SR
    return 2 * np.hypot(y @ np.cos(2 * np.pi * 3000 * t), y @ np.sin(2 * np.pi * 3000 * t)) / BL

def stairs(y):
    ref = sosfiltfilt(butter(4, 3.0, 'low', fs=FB, output='sos'), y)
    i0, i1 = int(1.5 * FB), int(11.0 * FB)
    sp, rs = np.diff(y)[i0:i1], np.diff(ref)[i0:i1]
    fast = np.abs(rs) > 0.5 * np.abs(rs).max()
    still = fast & (sp * np.sign(rs) < 0.25 * np.abs(rs))
    run = best = 0
    for s in still:
        run = run + 1 if s else 0
        best = max(best, run)
    seg = y[i0:i1] - y[i0:i1].mean()
    w = np.hanning(len(seg))
    Y = np.fft.rfft(seg * w)
    f = np.fft.rfftfreq(len(seg), 1 / FB)
    hf = np.sqrt(2 * np.sum(np.abs(Y[f > 5]) ** 2) / (len(seg) * np.sum(w ** 2)))
    swing = np.sqrt(2) * np.std(ref[i0:i1])
    return 100 * still.sum() / fast.sum(), best / FB * 1000, 20 * np.log10(hf / swing + 1e-12)

print(f"==== {tag}")
for clock, job in [('deadline', 'mod15'), ('drift', 'mod138')]:
    x, _ = sf.read(f'{d}/{tag}_{job}.wav')
    for name, y in [('level', level_path(x)), ('cutoff', cutoff_path(x))]:
        st, lg, rp = stairs(y)
        print(f"s. {clock} clock, {name}: still {st:.1f}% of the time, longest {lg:.1f} ms, "
              f"ripple above 5 Hz {rp:.1f} dB")

# t. a hand on a knob: one write of the level, 0.5 to 0.8 (the DC is 0.5, so
# the output goes from 0.295 to 0.4), 0.3 s after a stream of frames. When is
# it there (within 1% of the step), and where is it after 10 ms?
import os
if os.path.exists(f'{d}/{tag}_hand.wav'):
    x, _ = sf.read(f'{d}/{tag}_hand.wav')
    y = np.abs(x[:, 0])
    i0 = int(2.0 * SR)
    a, b = y[i0 - 480], y[i0 + int(0.4 * SR)]
    done = np.nonzero(np.abs(y[i0:] - b) <= 0.01 * abs(b - a))[0]
    at10 = (y[i0 + 480] - a) / (b - a)
    print(f"t. a hand: one write after a rest lands after {done[0] / SR * 1000:.1f} ms, "
          f"and is {100 * at10:.0f}% of the way after 10 ms (from {a:.3f} to {b:.3f})")
