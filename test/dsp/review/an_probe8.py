# Measures probe8: a new take starts at the start of its buffer.
# usage: an_probe8.py <work> <tag>
#
# Channel 2 is the write head's polled phase (0 to 1 of a buffer of 4 s).
# Channel 3, from 4.3 s, is the left buffer played back from its start.
# The four passes are 220 Hz (0.5 to 1.5 s), 331 Hz (2.0 to 2.5 s, a new take),
# 442 Hz (3.0 to 3.3 s, rec alone) and 550 Hz (3.6 to 3.8 s, a new take).
import sys, numpy as np, soundfile as sf
d, tag = sys.argv[1], sys.argv[2]
SR, BUF = 48000, 4.0
x, sr = sf.read(f'{d}/{tag}_take.wav')
assert sr == SR and x.shape[1] == 4, (sr, x.shape)
ph, buf = x[:, 2], x[int(4.3 * SR):, 3]

def at(t):
    return float(ph[int(t * SR)])

def tone(t0, t1):
    """The loudest frequency and the level of the buffer from t0 to t1 seconds."""
    seg = buf[int(t0 * SR): int(t1 * SR)]
    rms = np.sqrt(np.mean(seg ** 2))
    if rms < 1e-5:
        return 0.0, 20 * np.log10(max(rms, 1e-12))
    f = np.abs(np.fft.rfft(seg * np.hanning(len(seg))))
    return float(np.argmax(f) * SR / len(seg)), 20 * np.log10(rms)

print(f"HEAD before the first pass, at 0.4 s: {at(0.4):.5f}")
print(f"HEAD at the end of the first pass, at 1.9 s: {at(1.9) * BUF:.4f} s")
print(f"HEAD 5 ms after the new take of 2.0 s: {at(2.005) * BUF:.4f} s")
print(f"HEAD at the end of that take, at 2.9 s: {at(2.9) * BUF:.4f} s")
print(f"HEAD 5 ms after the rec alone of 3.0 s: {at(3.005) * BUF:.4f} s")
print(f"HEAD at the end of it, at 3.5 s: {at(3.5) * BUF:.4f} s")
print(f"HEAD 5 ms after the new take of 3.6 s: {at(3.605) * BUF:.4f} s")
print(f"HEAD at the end, at 4.2 s: {at(4.2) * BUF:.4f} s")
# the head never jumps back except at the two new takes
back = np.where(np.diff(ph[: int(4.2 * SR)]) < -1e-6)[0]
times = sorted(set(round(float(i) / SR, 2) for i in back))
print(f"HEAD jumps back at: {times} s")
print("THE BUFFER, where each pass lies (frequency in Hz, level in dB):")
want = [(0.03, 0.18, 550), (0.25, 0.48, 331), (0.55, 0.78, 442), (0.86, 0.99, 220)]
right = 0
for t0, t1, hz in want:
    f, lv = tone(t0, t1)
    okay = abs(f - hz) < 12 and lv > -30
    right += okay
    print(f"  {t0:.2f} to {t1:.2f} s: {f:6.1f} Hz at {lv:6.1f} dB (a new take puts {hz} Hz here)")
f, lv = tone(1.1, 2.2)
print(f"  1.10 to 2.20 s: {f:6.1f} Hz at {lv:6.1f} dB (a new take leaves this empty)")
print(f"PASSES in their place: {right} of 4")
print(f"BUFFER past the first pass, 1.1 to 2.2 s: {lv:.1f} dB")
# the start of the last take in the buffer: no step where the write began
seg = buf[: int(0.05 * SR)]
d2 = np.abs(seg[2:] - 2 * seg[1:-1] + seg[:-2])
print(f"BUFFER start, largest step in its first 50 ms: {d2.max():.4f}")

# A CLEAR WITH REGEN RUNNING (the fiftieth change): what stays in the pair
import os
if os.path.exists(f'{d}/{tag}_clear.wav'):
    c, sr2 = sf.read(f'{d}/{tag}_clear.wav')
    c = c if c.ndim == 1 else c[:, 0]
    left = c[int(2.0 * SR):]
    nz = np.where(np.abs(left) > 0)[0]
    print(f"CLEAR with regen running: frames left in the buffer {len(nz)}"
          + (f", {len(nz) / SR * 1000:.1f} ms from {nz[0] / SR:.4f} s, peak {np.abs(left).max():.4f}" if len(nz) else ""))

