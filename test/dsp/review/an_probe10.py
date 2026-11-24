# Measures probe10: an aligned overdub starts at the read head and loops in
# the window, and a head sync sends the read head to the window's start.
# usage: an_probe10.py <work> <tag>
import sys, numpy as np, soundfile as sf
d, tag = sys.argv[1], sys.argv[2]
SR, BUF = 48000, 4.0
x, sr = sf.read(f'{d}/{tag}_dub.wav')
assert sr == SR and x.shape[1] == 4, (sr, x.shape)
rd, wr, buf = x[:, 0] * BUF, x[:, 1] * BUF, x[int(4.3 * SR):, 3]

def at(ch, t):
    return float(ch[int(t * SR)])

def level(t0, t1, hz=None):
    seg = buf[int(t0 * SR): int(t1 * SR)]
    rms = np.sqrt(np.mean(seg ** 2))
    f = 0.0
    if rms > 1e-5:
        sp = np.abs(np.fft.rfft(seg * np.hanning(len(seg))))
        f = float(np.argmax(sp) * SR / len(seg))
    return 20 * np.log10(max(rms, 1e-12)), f

def edges(t0, t1):
    """where the sound in t0..t1 of the buffer begins and ends, in s"""
    seg = np.abs(buf[int(t0 * SR): int(t1 * SR)])
    on = np.where(seg > 1e-3)[0]
    if len(on) == 0:
        return float('nan'), float('nan')
    return t0 + on[0] / SR, t0 + on[-1] / SR

print(f"READ at 1.369 s: {at(rd, 1.369):.4f} s, WRITE 5 ms after the arm: {at(wr, 1.375):.4f} s")
print(f"WRITE minus READ, 5 ms after the arm: {(at(wr, 1.375) - at(rd, 1.375)) * 1000:.2f} ms")
s0, s1 = edges(1.15, 1.75)
print(f"FIRST pass in the buffer: {s0:.4f} to {s1:.4f} s")
print(f"FIRST pass starts where the head read at the arm: {(s0 - at(rd, 1.37)) * 1000:.2f} ms")
lv, f = level(s0 + 0.02, s1 - 0.02)
print(f"FIRST pass: {f:.0f} Hz at {lv:.1f} dB")
print(f"READ at 2.495 s: {at(rd, 2.495):.4f} s, at 2.515 s: {at(rd, 2.515):.4f} s")
j = np.where(np.abs(np.diff(rd[int(2.4 * SR): int(2.6 * SR)])) > 0.002)[0]  # (K2A slopes a jump over one block)
jt = 2.4 + j[0] / SR if len(j) else float('nan')
print(f"SYNC puts the loop on its command: {(at(rd, 2.52) - 1.02) * 1000:.2f} ms off")
print(f"SYNC jumps {(jt - 2.5) * 1000:.2f} ms after its command, over {len(j)} samples")
# where an untouched head is at 3.52 s: one window (1 s) after the jump
print(f"SYNC in time leaves the head alone: {(at(rd, 3.52) - (at(rd, 2.52) + 0.0)) * 1000:.2f} ms off")
tone = x[:, 2]
d2 = lambda a, b: float(np.max(np.abs(np.diff(tone[int(a * SR): int(b * SR)], 2))))
print(f"SYNC jump over a tone, the largest second difference: {d2(2.49, 2.53):.5f}, steady: {d2(2.1, 2.3):.5f}")
print(f"SYNC in time over a tone: {d2(3.49, 3.53):.5f}")
print(f"SYNC jump over a tone, the level 30 ms after it: {20*np.log10(np.sqrt(np.mean(tone[int(2.53*SR):int(2.56*SR)]**2))/np.sqrt(np.mean(tone[int(2.2*SR):int(2.3*SR)]**2))):.2f} dB")
lv1, f1 = level(1.82, 1.97)
lv2, f2 = level(1.02, 1.08)
lv3, _ = level(2.02, 2.4)
lv4, _ = level(0.0, 0.95)
print(f"SECOND pass before the window's end: {f1:.0f} Hz at {lv1:.1f} dB")
print(f"SECOND pass after the wrap, at the window's start: {f2:.0f} Hz at {lv2:.1f} dB")
print(f"PAST the window's end, 2.02 to 2.4 s: {lv3:.1f} dB")
print(f"BEFORE the window, 0 to 0.95 s (io's own head stood there): {lv4:.1f} dB")
