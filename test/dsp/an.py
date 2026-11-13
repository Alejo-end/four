import numpy as np, soundfile as sf
from scipy.signal import hilbert, get_window, correlate
sr=48000
db=lambda x:20*np.log10(max(x,1e-12))
def spec(x):
    w=get_window('blackmanharris',len(x)); X=np.abs(np.fft.rfft(x*w))/(w.sum()/2)
    return np.fft.rfftfreq(len(x),1/sr),X
def spurs(x,keep,n=4,guard=30,fmax=24000):
    f,X=spec(x); m=np.ones(len(f),bool)
    for k in keep: m&=np.abs(f-k)>guard
    m&=f<fmax
    P=X**2; tot=P.sum(); al=P[m].sum()
    Xm=np.where(m,X,0); out=[]
    for _ in range(n):
        i=Xm.argmax(); out.append((round(f[i]),round(db(Xm[i]),1))); Xm[np.abs(f-f[i])<guard]=0
    return 10*np.log10(al/tot+1e-30),out
print("== DRIVE (tanh, pre 7): energy that is not an odd harmonic, dB re total; top spurs (Hz, dBFS)")
d,_=sf.read('drive.wav'); d=d[sr//2:sr//2+2*sr]
for i,(f0,name) in enumerate([(5000,'plain'),(5000,'ADAA'),(1318.5,'plain'),(1318.5,'ADAA')]):
    keep=[k*f0 for k in range(1,40,2) if k*f0<24000]
    r,s=spurs(d[:,i],keep); r2,s2=spurs(d[:,i],keep,fmax=16000)
    f,X=spec(d[:,i]); fund=db(X[np.abs(f-f0).argmin()])
    print(f"  {f0:7.1f} {name:5s} fund {fund:6.1f} dBFS  alias {r:6.1f} dB  below16k {r2:6.1f} dB  top {s[:3]}")
print("== READ (BufRd): levels in dBFS, input tone is -6.0")
r,_=sf.read('read.wav'); r=r[sr//4:sr//4+sr]
def lvl(x,f0):
    f,X=spec(x); return db(X[np.abs(f-f0)<20].max())
print(f"  15k at rate 2, cubic: at 18k (the fold) {lvl(r[:,0],18000):.1f}")
print(f"  10k at rate 0.5, cubic: 5k {lvl(r[:,1],5000):.1f}, image at 19k {lvl(r[:,1],19000):.1f}")
print(f"  10k at rate 0.5, linear: 5k {lvl(r[:,2],5000):.1f}, image at 19k {lvl(r[:,2],19000):.1f}")
f1=10000*2**(7/12); a,s=spurs(r[:,3],[f1]); print(f"  10k up 7 st, cubic: true {lvl(r[:,3],f1):.1f}, not-true energy {a:.1f} dB, top {s[:3]}")
print("== LONG BUFFER (60 s, engine window law, cubic): energy off the tone, dB re total")
l,_=sf.read('longread.wav'); l=l[sr//2:sr//2+2*sr]
for i,(f0,name) in enumerate([(5000,'5k at 0.02'),(5000,'5k at 0.5'),(5000,'5k at 0.9'),(1000,'1k at 0.02'),(1000,'1k at 0.9'),(5000*2**(1/12),'5k at 0.9, +1 st')]):
    a,s=spurs(l[:,i],[f0],guard=60); print(f"  {name:18s} tone {lvl(l[:,i],f0):6.1f}  noise {a:6.1f} dB  top {s[:2]}")
print("== CHORUS wet arm: pitch deviation of a 1 kHz sine, semitones")
c,_=sf.read('chorus.wav'); c=c[sr:sr*3-2400]
for i,name in enumerate(['amount 1, rate 1 (6 Hz)','amount 0.5, rate 0.5 (0.77 Hz)']):
    ph=np.unwrap(np.angle(hilbert(c[:,i]))); fi=np.diff(ph)*sr/(2*np.pi); fi=fi[2400:-2400]
    fi=np.convolve(fi,np.ones(48)/48,'same')[100:-100]
    print(f"  {name:32s} {12*np.log2(fi.min()/1000):+.2f} .. {12*np.log2(fi.max()/1000):+.2f}")
print("== WARP1")
w,_=sf.read('warp.wav'); wh,_=sf.read('white.wav'); a=w[sr:3*sr]
cc=lambda x,y:float(np.corrcoef(x,y)[0,1])
print(f"  two Warp1 on the same audio, warp_rand 0.2: L/R correlation {cc(a[:,0],a[:,1]):.2f}")
print(f"  same, warp_rand 0: correlation with the first {cc(a[:,2],a[:,0]):.2f}")
x=w[sr:3*sr,2]; ref=wh[:4*sr]
xc=correlate(x[:sr],ref[:3*sr],'valid'); lag=-(np.abs(xc).argmax()); 
best=np.abs(xc).argmax(); seg=ref[best:best+len(x)]; g=np.dot(x,seg)/np.dot(seg,seg)
print(f"  speed 1, rand 0, white noise: gain {db(abs(g)):.2f} dB, residual after best fit {db(np.std(x-g*seg)/np.std(x)):.1f} dB (0 = unrelated)")
a3,s3=spurs(w[sr//2:sr//2+sr,3],[440]); print(f"  speed 1, 440 Hz sine: level {lvl(w[sr//2:sr//2+sr,3],440):.1f} dBFS (in -6.0), off-tone energy {a3:.1f} dB, top {s3[:3]}")
h=w[sr//2:sr//2+3*sr,4]; a4,s4=spurs(h,[440]); env=np.abs(hilbert(h))[2400:-2400]
print(f"  half speed, 440 Hz sine: level {lvl(h,440):.1f} dBFS, off-tone energy {a4:.1f} dB, envelope min/max {env.min():.3f}/{env.max():.3f}, top {s4[:3]}")
print("== GRAIN level, dB re the buffer RMS (Hann grains, no compensation)")
g,_=sf.read('grain.wav'); g=g[sr:3*sr]; base=np.std(wh)
for i,name in enumerate(['N=8 natural speed','N=8 frozen','N=8 random place','N=2 natural speed','N=2 frozen','N=2 random place']):
    N=8 if i<3 else 2; pred=db(N/2) if i%3==0 else 10*np.log10(3*N/8)
    print(f"  {name:20s} {db(np.std(g[:,i])/base):+6.2f}   predicted {pred:+6.2f}")
print("== RESON comb tuning")
q,_=sf.read('reson.wav'); q=q[:2*sr]
for i,m in enumerate([36,60,84]):
    f0=440*2**((m-69)/12); f,X=spec(q[:,i]); k=np.abs(f-f0).argmin(); k=k-3+X[k-3:k+4].argmax()
    a_,b_,c_=np.log(X[k-1:k+2]); p=0.5*(a_-c_)/(a_-2*b_+c_); fm=(k+p)*sr/len(q)
    # 8th harmonic too
    k8=np.abs(f-8*f0).argmin(); k8=k8-6+X[k8-6:k8+7].argmax(); a_,b_,c_=np.log(X[k8-1:k8+2]); p=0.5*(a_-c_)/(a_-2*b_+c_); f8=(k8+p)*sr/len(q)
    print(f"  midi {m}: target {f0:8.2f} Hz, measured {fm:8.2f} ({1200*np.log2(fm/f0):+.2f} cents); 8th partial {1200*np.log2(f8/(8*f0)):+.2f} cents, level re 1st {db(X[k8]/X[k]):+.1f} dB")
print("== PV path (BufRd -> FFT -> IFFT), 1 kHz sine in the buffer")
p,_=sf.read('pv.wav'); p=p[sr//2:sr//2+sr]
for i,sc in enumerate([1,0.5]):
    f,X=spec(p[:,i]); print(f"  scan {sc}: peak at {f[X.argmax()]:.0f} Hz, {db(X.max()):.1f} dBFS")
