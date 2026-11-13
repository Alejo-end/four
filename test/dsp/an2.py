import numpy as np, soundfile as sf
exec(open('an.py').read().split('print("== DRIVE')[0])
l,_=sf.read('fix.wav'); l=l[sr//2:sr//2+2*sr]
names=['frame Phasor at 0.9, rate 1','frame Phasor at 0.9, +1 st','PlayBuf at 0.9, rate 1','PlayBuf at 0.9, +1 st','engine law at 0.13 (8 s in), rate 1','engine law at 0.13, +1 st','frame Phasor at 0.13, +1 st']
for i,n in enumerate(names):
    f0=5000*(2**(1/12) if '+1' in n else 1)
    a,s=spurs(l[:,i],[f0],guard=60); f,X=spec(l[:,i]); print(f"  {n:38s} noise {a:6.1f} dB  top {s[:1]}")
