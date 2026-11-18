# Measures probe9: a voice change keeps its sound and its place.
# usage: an_probe9.py <work> <tag>
#
# _rise.wav    each drone alone, born at 5.0 s: when its 5 ms RMS first comes
#              within 6 dB, and within 1 dB, of the level it settles at.
# _steady.wav  each drone alone since 4.0 s, with no change.
# _change.wav  lane k: an old drone from 4.0 s, the swap at 5.0 s.
# A change is read against the two drones it joins. At each moment of the
# 600 ms after the swap, the lane's level is set against the quieter of "the
# old drone alone" and "the new drone alone" at that moment (the deepest
# place), and against the louder of the two (the highest). 0 dB is "no hole
# and no bump". The steady lanes carry the new drone's own delay and the
# phrase's own beats, so those are not read as a hole. The level is the RMS
# over 5 ms on the tone and 30 ms on the phrase. With GRAIN or CLOUD in the
# change it is 50 ms and 100 ms, and the search ends 100 ms after the old
# drone has gone: grains make holes of their own, and two streams of them
# never match. The line then gives the stream's own deepest place after that.
# The place: what is heard 50 ms after the swap, against what the old drone
# would play then (0 is the same place). Over the phrase it is also read to
# the frame, half a second after the swap, against PLAY alone: a change adds
# two copies of a sound, and out of step they cancel. A drone's sound lies behind its head
# by the drone's own delay (the engine's modeLat, printed by the probe as
# DELAYS in plog_<tag>.txt), so the place heard is the head less that delay.
import os, re, sys, numpy as np, soundfile as sf
from scipy.signal import correlate
d, tag = sys.argv[1], sys.argv[2]
SR, T = 48000, 5.0
LO, HI, BUF = 0.05, 0.45, 8.0
NAMES = {1: 'GRAIN', 2: 'WARP', 3: 'PV', 4: 'PLAY', 5: 'CLOUD'}
PAIRS = [(4, 1), (4, 2), (4, 3), (4, 5), (2, 4), (3, 4)]

# the delays the probe used, in frames, by mode (none: an engine from before),
# and the old drone's hold and fade by the mode that comes
DELAY = {m: 0 for m in NAMES}
FADE = {}
_log = os.path.join(d, f'plog_{tag}.txt')
if os.path.exists(_log):
    _text = open(_log, errors='replace').read()
    _m = re.search(r'DELAYS \[([^\]]*)\]', _text)
    if _m:
        for _i, _v in enumerate(_m.group(1).split(',')):
            DELAY[_i + 1] = float(_v)
    _m = re.search(r'FADES \[(.*)\]', _text)
    if _m:
        for _i, _v in enumerate(re.findall(r'\[\s*([-\d.e]+),\s*([-\d.e]+)', _m.group(1))):
            FADE[_i + 1] = (float(_v[0]), float(_v[1]))

def db(v):
    return 20 * np.log10(np.maximum(v, 1e-9))

def env(y, ms):
    w = int(ms / 1000 * SR)
    c = np.concatenate([[0.0], np.cumsum(y * y)])
    return np.sqrt((c[w:] - c[:-w]) / w)        # e[i] is the RMS of y[i : i + w]

def loud(a, b):
    return a if np.sum(a * a) >= np.sum(b * b) else b

x, sr = sf.read(f'{d}/{tag}_rise.wav')
assert sr == SR
print("THE RISE of each drone alone, born at 5.0 s over the 1 kHz take (5 ms RMS):")
for i, name in enumerate(['GRAIN', 'WARP', 'PV', 'CLOUD']):
    y = x[:, 2 * i] + 0.0
    if np.abs(y).max() == 0:
        print(f"  {name:5s} absent"); continue
    e = env(y, 5); end = np.median(e[int((T + 1.0) * SR): int((T + 1.4) * SR)])
    seg = e[int(T * SR):]
    first = np.argmax(np.abs(y[int(T * SR):]) > 1e-4) / SR * 1000
    t6 = np.argmax(seg > end * 10 ** (-6 / 20)) / SR * 1000
    print(f"  {name:5s} first sound after {first:5.1f} ms, within 6 dB of its level after {t6:4.0f} ms")

st, sr = sf.read(f'{d}/{tag}_steady.wav')
x, sr = sf.read(f'{d}/{tag}_change.wav')
assert sr == SR and x.shape[1] == 36 and st.shape[1] == 20, (x.shape, st.shape)
print("THE CHANGE at 5.0 s, against the old and the new drone alone: deepest / highest / the place heard")
out = {}
steps = []
for k in range(12):
    j = 0 if k < 6 else 1
    src = 'tone' if j == 0 else 'phrase'
    a, b = PAIRS[k % 6]
    name = f"{NAMES[a]} to {NAMES[b]}"
    y = loud(x[:, 3 * k], x[:, 3 * k + 1]); ph = x[:, 3 * k + 2]
    old = loud(st[:, 2 * (j * 5 + a - 1)], st[:, 2 * (j * 5 + a - 1) + 1])
    new = loud(st[:, 2 * (j * 5 + b - 1)], st[:, 2 * (j * 5 + b - 1) + 1])
    if np.abs(y[int((T + 0.5) * SR):]).max() == 0 or np.abs(new).max() == 0:
        print(f"  {src:6s} {name:13s} absent"); continue
    grains = 1 in (a, b) or 5 in (a, b)
    ms = (50 if grains else 5) if j == 0 else (100 if grains else 30)
    e, eo, en = env(y, ms), env(old, ms), env(new, ms)
    gone = FADE.get(b, (0, 0.02))[0] + FADE.get(b, (0, 0.02))[1]
    i0, i1 = int(T * SR), int((T + (gone + 0.1 if grains else 0.6)) * SR)
    floor = 10 ** (-60 / 20) * max(eo.max(), en.max())
    low_all = np.maximum(np.minimum(eo, en), floor)
    lowr, uppr = low_all[i0:i1], np.maximum(np.maximum(eo, en)[i0:i1], floor)
    seg = e[i0:i1]
    deep = db(seg / lowr); high = db(seg / uppr)
    own = db(e[i1: int((T + 1.4) * SR)] / low_all[i1: int((T + 1.4) * SR)]).min() if grains else None
    was, now = ph[int((T - 0.010) * SR)], ph[int((T + 0.050) * SR)]
    span = (HI - LO) * BUF
    heard = (now * BUF - DELAY[b] / SR) - (was * BUF - DELAY[a] / SR)
    moved = (heard - 0.060 + span / 2) % span - span / 2
    # ...and to the sample, over the phrase: the lane half a second after the
    # swap against PLAY alone. In step, a change adds two copies of a sound.
    # A drone with a delay is heard that far behind PLAY alone, before the
    # change and after it: the number is what is left over.
    step = None
    if j == 1 and not grains or (j == 1 and 5 in (a, b) and DELAY[5] > 0 and 1 not in (a, b)):
        ref = loud(st[:, 2 * (5 + 4 - 1)], st[:, 2 * (5 + 4 - 1) + 1])
        i2, n2, R = int((T + 0.45) * SR), int(0.4 * SR), 4800
        c = correlate(y[i2: i2 + n2], ref[i2 - R: i2 + n2 + R], mode='valid')
        step = int(R - np.argmax(c) + DELAY[a])
    out[(src, name)] = (deep.min(), high.max(), moved, grains)
    print(f"  {src:6s} {name:13s} deepest {deep.min():+6.1f} dB at {deep.argmin() / SR * 1000:4.0f} ms, "
          f"highest {high.max():+5.1f} dB at {high.argmax() / SR * 1000:4.0f} ms ({ms} ms RMS), "
          f"what is heard {moved * 1000:+7.1f} ms from its place"
          + (f"; the stream's own deepest after it {own:+.1f} dB" if own is not None else "")
          + (f"; {step:+d} frames out of step" if step is not None else ""))
    if step is not None:
        steps.append(abs(step))
for src in ('tone', 'phrase'):
    rows = {n: v for (s_, n), v in out.items() if s_ == src}
    if not rows:
        continue
    steady = [v for v in rows.values() if not v[3]]
    grains = [v for v in rows.values() if v[3]]
    print(f"DEEPEST over the {src}, among PLAY, WARP and PV: {min(v[0] for v in steady):+.1f} dB")
    print(f"HIGHEST over the {src}, among PLAY, WARP and PV: {max(v[1] for v in steady):+.1f} dB")
    if grains:
        print(f"DEEPEST over the {src}, into GRAIN and CLOUD: {min(v[0] for v in grains):+.1f} dB")
        print(f"HIGHEST over the {src}, into GRAIN and CLOUD: {max(v[1] for v in grains):+.1f} dB")
    print(f"PLACE furthest from where it was over the {src}: {max(abs(v[2]) for v in rows.values()) * 1000:.1f} ms")
if steps:
    print(f"OUT OF STEP after a change, over the phrase, at most: {max(steps)} frames")
