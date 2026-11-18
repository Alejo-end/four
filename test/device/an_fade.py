# How much of a sweep does a recorded tone's level stand still?
# usage: an_fade.py <recording.wav>     (needs numpy, scipy and soundfile)
# The device's twin of test/dsp/review/an_stair.py, for gate row 19.34: a
# modulator moves a knob once a frame under a steady tone, and the engine's
# output is recorded. The level of the tone is read 750 times a second (four
# periods of the tone wide, then low-passed at 40 Hz: a recording's level
# has a fine ripple that a render's has not), and set against itself
# low-passed at 3 Hz:
#   still    the share of the time the level stands still while it is meant
#            to move fast (more than half its top speed)
#   longest  the longest such stand, in ms
#   ripple   everything above 5 Hz, in dB against the swing
#   frames   the strongest line from 12 to 18 Hz, where the script's frames
#            are (15 a second), in dB against the swing
import sys
import numpy as np
import soundfile as sf
from scipy.signal import butter, sosfiltfilt

x, sr = sf.read(sys.argv[1])
x = x[:, 0] if x.ndim > 1 else x
BL = 64
FB = sr / BL
spec = np.abs(np.fft.rfft(x * np.hanning(len(x))))
f0 = np.fft.rfftfreq(len(x), 1 / sr)[np.argmax(spec[20:]) + 20]
t = np.arange(len(x)) / sr
z = x * np.exp(-2j * np.pi * f0 * t)
w = int(round(4 * sr / f0))
c = np.cumsum(np.concatenate([[0], z]))
y = 2 * np.abs((c[w:] - c[:-w]) / w)[::BL]
y = sosfiltfilt(butter(4, 40.0, 'low', fs=FB, output='sos'), y)
ref = sosfiltfilt(butter(4, 3.0, 'low', fs=FB, output='sos'), y)
i0, i1 = int(0.7 * FB), len(y) - int(0.7 * FB)
sp, rs = np.diff(y)[i0:i1], np.diff(ref)[i0:i1]
fast = np.abs(rs) > 0.5 * np.abs(rs).max()
still = fast & (sp * np.sign(rs) < 0.25 * np.abs(rs))
run = best = 0
for s in still:
    run = run + 1 if s else 0
    best = max(best, run)
seg = y[i0:i1] - y[i0:i1].mean()
win = np.hanning(len(seg))
Y = np.fft.rfft(seg * win)
f = np.fft.rfftfreq(len(seg), 1 / FB)
hf = np.sqrt(2 * np.sum(np.abs(Y[f > 5]) ** 2) / (len(seg) * np.sum(win ** 2)))
swing = np.sqrt(2) * np.std(ref[i0:i1])
print(f"FADE tone {f0:.1f} Hz, swing {20 * np.log10(ref[i0:i1].max() / max(ref[i0:i1].min(), 1e-9)):.1f} dB: "
      f"still {100 * still.sum() / max(fast.sum(), 1):.1f}% of the time, longest {best / FB * 1000:.1f} ms, "
      f"ripple above 5 Hz {20 * np.log10(hf / swing + 1e-12):.1f} dB, "
      f"the frames' line {20 * np.log10(2 * np.abs(Y[(f > 12) & (f < 18)]).max() / (np.sum(win) * swing) + 1e-12):.1f} dB")
