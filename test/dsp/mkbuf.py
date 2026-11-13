import numpy as np, soundfile as sf
sr=48000
def w(name,x): sf.write(name,x.astype(np.float32),sr,subtype='FLOAT')
t=np.arange(2*sr)/sr
w('tone15k.wav',0.5*np.sin(2*np.pi*15000*t))
w('tone10k.wav',0.5*np.sin(2*np.pi*10000*t))
w('tone1k.wav',0.5*np.sin(2*np.pi*1000*t))
w('tone440.wav',0.5*np.sin(2*np.pi*440*t))
rng=np.random.default_rng(1)
w('white.wav',0.1*rng.standard_normal(4*sr))
t=np.arange(60*sr)/sr
w('long5k.wav',0.5*np.sin(2*np.pi*5000*t))
w('long1k.wav',0.5*np.sin(2*np.pi*1000*t))
