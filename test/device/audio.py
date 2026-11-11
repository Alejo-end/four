#!/usr/bin/env python3
"""Measure a 16-bit WAV without third-party libraries.

These numbers can show that a sound is absent, clipped, clicking, louder or
darker. They cannot say that it sounds good.

    audio.py file.wav
"""
import array
import math
import sys
import wave


def load(path):
    """Return (sample_rate, channels), each channel an array of floats in -1..1."""
    with wave.open(path, "rb") as w:
        rate, nch, width = w.getframerate(), w.getnchannels(), w.getsampwidth()
        raw = w.readframes(w.getnframes())
    if width != 2:
        raise ValueError(f"expected 16-bit, got {width * 8}-bit")
    data = array.array("h")
    data.frombytes(raw)
    if sys.byteorder == "big":
        data.byteswap()
    return rate, [[s / 32768.0 for s in data[i::nch]] for i in range(nch)]


def db(x):
    return round(20 * math.log10(x), 1) if x > 1e-9 else -180.0


def rms(xs):
    return math.sqrt(sum(s * s for s in xs) / max(len(xs), 1))


def stats(xs):
    peak = max((abs(s) for s in xs), default=0.0)
    return {
        "peak_db": db(peak),
        "rms_db": db(rms(xs)),
        "clipped": sum(1 for s in xs if abs(s) >= 0.9995),
    }


def clicks(xs, rate, ratio=12.0, floor=0.006):
    """Times of breaks in the waveform (seconds), from the second difference.

    A smooth tone has a small second difference at any level. A jump in the
    samples makes one large value, far above the 10ms before it.
    """
    win = int(rate * 0.01)
    d2 = [abs(xs[i] - 2 * xs[i - 1] + xs[i - 2]) for i in range(2, len(xs))]
    found = []
    run = sum(d2[:win])
    for i in range(win, len(d2)):
        local = run / win
        if d2[i] > floor and d2[i] > ratio * max(local, 1e-5):
            if not found or ((i + 2) / rate) - found[-1] > 0.02:
                found.append(round((i + 2) / rate, 3))
        run += d2[i] - d2[i - win]
    return found


def envelope(xs, rate, step=0.1):
    """RMS in dB for each `step` seconds."""
    n = int(rate * step)
    return [db(rms(xs[i:i + n])) for i in range(0, len(xs) - n + 1, n)]


def band(xs, rate, hz):
    """The level at one frequency, from a Goertzel filter over up to 2 seconds."""
    xs = xs[:rate * 2]
    k = 2 * math.cos(2 * math.pi * hz / rate)
    a = b = 0.0
    for s in xs:
        a, b = s + k * a - b, a
    power = a * a + b * b - k * a * b
    return db(2 * math.sqrt(max(power, 0)) / max(len(xs), 1))


def brightness(xs, rate):
    """Spectral tilt: high-pass energy against the total, in dB. Lower is darker."""
    prev = 0.0
    hi = []
    for s in xs:
        hi.append(s - prev)
        prev = s
    return round(db(rms(hi)) - db(rms(xs)), 1)


def correlate(a, b):
    n = min(len(a), len(b))
    if n == 0:
        return 0.0
    ab = sum(a[i] * b[i] for i in range(n))
    aa = sum(s * s for s in a[:n])
    bb = sum(s * s for s in b[:n])
    return round(ab / math.sqrt(aa * bb), 4) if aa > 0 and bb > 0 else 0.0


def report(path):
    rate, chans = load(path)
    out = {"seconds": round(len(chans[0]) / rate, 2)}
    for i, c in enumerate(chans):
        out[f"ch{i + 1}"] = stats(c)
    out["clicks"] = clicks(chans[0], rate)[:20]
    if len(chans) > 1:
        out["lr_corr"] = correlate(chans[0], chans[1])
    return out


if __name__ == "__main__":
    print(report(sys.argv[1]))
