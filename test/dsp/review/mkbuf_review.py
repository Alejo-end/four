# The takes the review probes read. Run inside the work folder, after test/dsp/mkbuf.py.
import numpy as np, soundfile as sf
sr = 48000; rng = np.random.default_rng(5)
w = lambda n, x: sf.write(n, x.astype(np.float32), sr, subtype='FLOAT')
w('noiseL60.wav', 0.1 * rng.standard_normal(60 * sr)); w('noiseR60.wav', 0.1 * rng.standard_normal(60 * sr))
t = np.arange(60 * sr) / sr
w('long262.wav', 0.25 * np.sin(2 * np.pi * 261.6256 * t))
# a 1 kHz island from 29.9 to 30.1 s in a 7 kHz buffer: grain overrun shows as 7 kHz
x = 0.25 * np.sin(2 * np.pi * 7000 * t); a, b = int(29.9 * sr), int(30.1 * sr)
x[a:b] = 0.25 * np.sin(2 * np.pi * 1000 * t[a:b]); w('marker.wav', x)
