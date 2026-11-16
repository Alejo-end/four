# The offline DSP regression check. Run it through check_dsp.sh, which picks a
# Python with numpy, scipy and soundfile.
# usage: python test/dsp/check_dsp.py <work folder>
#
# It renders the review probes of doc/measurements/2026-11-15 (test/dsp/review)
# and test/dsp/engine.scd with the real lib/Engine_Four.sc, reads them with the
# review's own analysis scripts, and checks the numbers:
#   PASS   a target of the checklist in doc/dsp-plan.md, or a fix, holds
#   KNOWN  a row that fails by design today, within its stated margin
#   FAIL   a target missed, or a KNOWN row worse than its margin
#   SKIP   a checklist row that no Mac render measures; the line says where it is tested
# The stock voices always run. With FOUR_PLUGIN_DIR set (a folder with
# FourStretch.scx, from ugen/build_mac.sh) the FourStretch build runs too.
import os, re, subprocess, sys, time
import numpy as np, soundfile as sf

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))
DSP, REV = os.path.join(REPO, 'test', 'dsp'), os.path.join(REPO, 'test', 'dsp', 'review')
WORK = os.path.abspath(sys.argv[1])
PLUG = os.environ.get('FOUR_PLUGIN_DIR')
PY = sys.executable
SR = 48000
count = {'PASS': 0, 'KNOWN': 0, 'FAIL': 0, 'SKIP': 0}

def say(status, build, text):
    count[status] += 1
    print(f"{status:5s} {build:6s} {text}", flush=True)

# a target: value must be at most (or at least) the limit
def target(build, name, v, limit, unit, low=True):
    ok = v <= limit if low else v >= limit
    say('PASS' if ok else 'FAIL', build, f"{name}: {v:.1f} {unit} (limit {'<=' if low else '>='} {limit:g} {unit})")

# a known failure: fails only when it is worse than known by more than margin
def known(build, name, v, known_v, margin, unit, worse_up=True):
    edge = known_v + margin if worse_up else known_v - margin
    bad = v > edge if worse_up else v < edge
    say('FAIL' if bad else 'KNOWN', build,
        f"{name}: {v:.2f} {unit} (known {known_v:g}, fails {'above' if worse_up else 'below'} {edge:g})")

def num(pattern, text, group=1):
    m = re.search(pattern, text, re.M)
    if not m:
        raise RuntimeError(f"no match for {pattern!r}")
    return float(m.group(group))

def analyse(script, folder, tag):
    r = subprocess.run([PY, script, folder, tag], capture_output=True, text=True)
    if r.returncode:
        raise RuntimeError(f"{os.path.basename(script)} failed:\n{r.stderr[-2000:]}")
    return r.stdout

def buffers():
    if not os.path.exists(os.path.join(WORK, 'marker.wav')):
        for s in ['mkbuf.py', os.path.join('review', 'mkbuf_review.py')]:
            subprocess.run([PY, os.path.join(DSP, s)], cwd=WORK, check=True)

# One build: the four probes and engine.scd in parallel, each in its own folder
# (run_probe.sh and run_engine.sh write conf.yaml and their log into it).
JOBS = [('p1', 'probe1.scd'), ('p2', 'probe2.scd'), ('p3', 'probe3.scd'), ('p4', 'probe4.scd'), ('eng', None)]

def render(build):
    env = dict(os.environ)
    if build == 'stock':
        env.pop('FOUR_PLUGIN_DIR', None); env.pop('FOUR_STRETCH', None)
    procs = {}
    for job, probe in JOBS:
        d = os.path.join(WORK, build, job); os.makedirs(d, exist_ok=True)
        # last run's renders go first, so a render that fails cannot pass on old files
        for f in os.listdir(d):
            if not os.path.islink(os.path.join(d, f)) and os.path.isfile(os.path.join(d, f)):
                os.remove(os.path.join(d, f))
        for f in os.listdir(WORK):
            if f.endswith('.wav') and not os.path.exists(os.path.join(d, f)):
                os.symlink(os.path.join(WORK, f), os.path.join(d, f))
        cmd = ([os.path.join(REV, 'run_probe.sh'), d, job, os.path.join(REV, probe)] if probe
               else [os.path.join(DSP, 'run_engine.sh'), d, job])
        procs[job] = (d, subprocess.Popen(cmd, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True))
    out = {}
    for job, (d, p) in procs.items():
        o = p.communicate()[0]
        log = os.path.join(d, 'elog.txt' if job == 'eng' else f'plog_{job}.txt')
        text = open(log, errors='replace').read() if os.path.exists(log) else ''
        out[job] = (d, p.returncode, o, text)
    return out

def first_sound(x, ch, t0=0.5, floor=1e-4):
    y = np.abs(x[int(t0 * SR):, ch]); i = np.argmax(y > floor)
    return i / SR * 1000 if y[i] > floor else float('inf')

def check(build):
    print(f"---- {build}: {'the FourStretch plugin from ' + PLUG if build == 'plugin' else 'the stock voices (no plugin)'}", flush=True)
    t = time.time(); runs = render(build)
    print(f"      rendered in {time.time() - t:.0f} s", flush=True)
    # the engine compiles, with 198 commands and no ERROR, in every run
    for job, (d, rc, o, log) in runs.items():
        c = re.search(r'COMMANDS (\d+)', log)
        ok = rc == 0 and c and int(c.group(1)) == 198 and 'ERROR' not in log
        say('PASS' if ok else 'FAIL', build, f"{job}: compiles, COMMANDS {c.group(1) if c else '?'}, "
            f"{'no ERROR' if 'ERROR' not in log else 'ERROR in the log'}, exit {rc} (needs 198, no ERROR)")
        if not ok:
            print(o[-1500:]); return
    plug_on = 'FourStretch on' in runs['p1'][3]
    say('PASS' if plug_on == (build == 'plugin') else 'FAIL', build,
        f"the engine says FourStretch {'on' if plug_on else 'absent'} (needs {'on' if build == 'plugin' else 'absent'})")
    a1 = analyse(os.path.join(REV, 'an_probe1.py'), runs['p1'][0], 'p1')
    a2 = analyse(os.path.join(REV, 'an_probe2.py'), runs['p2'][0], 'p2')
    a4 = analyse(os.path.join(REV, 'an_probe4.py'), runs['p4'][0], 'p4')
    ae = analyse(os.path.join(DSP, 'an_engine.py'), runs['eng'][0], 'eng')

    # THE FIXES OF THE TWENTY-SECOND CHANGE
    # the first grain (probe3): a pad at density 20 and 4, the drone at 4, all started at 0.5 s
    x, _ = sf.read(os.path.join(runs['p3'][0], 'p3_first.wav'))
    for ch, name, before in [(4, 'GRAIN pad, density 20', 51), (6, 'GRAIN pad, density 4', 251),
                             (8, 'GRAIN drone, density 4', 250)]:
        target(build, f"fix: {name}, first sound after the start (was {before} ms)", first_sound(x, ch), 5, 'ms')
    # a mode change from PLAY into GRAIN (probe2): no 1 ms RMS below -60 dBFS
    gap = re.search(r'below -60 dBFS \(1 ms RMS\) from ([\d.]+) to ([\d.]+) ms', a2)
    say('FAIL' if gap else 'PASS', build, "fix: a mode change into GRAIN at density 20 leaves no hole below -60 dBFS"
        + (f": hole from {gap.group(1)} to {gap.group(2)} ms" if gap else " (was from 20 to 52 ms)"))
    # the erosion head (probe2): erode 1 for 12 s; past 30 s it printed noise
    for p, was in [('0.05', -141), ('0.30', -141), ('0.50', -18), ('0.90', -22)]:
        v = num(rf'window {p}-[\d.]+ \(\s*([\d.]+) s in\).*off-tone\s+([-\d.]+) dB', a2, 2)
        sec = num(rf'window {p}-[\d.]+ \(\s*([\d.]+) s in\)', a2)
        target(build, f"fix: erosion noise under the tone, window {sec:g} s in (was {was} dB, floor -141)", v, -130, 'dB')

    # THE CHECKLIST (doc/dsp-plan.md): the targets that hold
    target(build, "PLAY is the take at pitch 1: 5 kHz tone 54 s in, noise", num(r'PLAY at 54 s, pitch 1\s+tone\s+[-\d.]+ dBFS\s+noise\s+([-\d.]+)', ae), -90, 'dB')
    if build == 'plugin':
        # the shimmer loop is bounded: 0.95, decay 30, every pitch (probe4 p, probe1 3)
        for n in ['burst, -12 st', 'burst, -7 st', 'burst, \\+7 st', 'burst, \\+24 st']:
            v = num(rf'{n}\s+[-\d.]+\s+[-\d.]+\s+[-\d.]+\s+([-\d.]+)\s+peak', a4)
            target(build, f"shimmer 0.95 bounded, {n.replace(chr(92), '')}, RMS at 59 s", v, -100, 'dBFS')
        target(build, "shimmer 0.95 bounded, 40 Hz at 0 dBFS for 10 s, 0 st, RMS at 59 s",
               num(r'40 Hz 0 dBFS 10 s, 0 st\s+[-\d.]+\s+[-\d.]+\s+[-\d.]+\s+([-\d.]+)', a4), -60, 'dBFS')
        target(build, "shimmer 0.95 bounded, a burst at 0 st, RMS at 29 s",
               num(r'decay 30, shim \.95, 0 st(?:\s+[-\d.]+){4}\s+([-\d.]+)', a1), -60, 'dBFS')

    # THE CHECKLIST: the rows that fail by design today, with their margins
    known(build, "the open filter is not the identity: stock RLPF at 20 kHz, level at 10 kHz",
          num(r'LO 20k res 0 \(open\).*10k ([-\d.]+)', a1), -10.1, 1, 'dB', worse_up=False)
    known(build, "GRAIN is not flat at pitch 1: 19 kHz band re 800 Hz, noise take",
          num(r'^\s+GRAIN\s+0\.1k.*19k ([-+\d.]+)', a1), -2.4, 1, 'dB', worse_up=False)
    for into, kv in [('WARP', {'stock': (-23.3, 208), 'plugin': (-28.6, 149)}),
                     ('PV', {'stock': (-85.6, 46), 'plugin': (-27.8, 34)})]:
        m = re.search(rf'to {into}\s+deepest\s+([-+\d.]+) dB at\s+\d+ ms, within 1 dB of its level after\s+(\d+) ms', a1)
        known(build, f"a mode change from PLAY into {into} has a hole: deepest, 5 ms RMS",
              float(m.group(1)), kv[build][0], 6, 'dB', worse_up=False)
        known(build, f"a mode change from PLAY into {into}: back within 1 dB after", float(m.group(2)), kv[build][1], 50, 'ms')
    known(build, "the drive folds in hearing: 5 kHz at -6 dBFS, full drive, not an odd harmonic below 16 kHz",
          num(r'^r\. DRIVE 1.*not an odd harmonic ([-\d.]+) dB', a4), -27.3, 3, 'dB')
    known(build, "the take is not the input: LeakDC on the record arm at 40 Hz",
          num(r'LeakDC on the dry arm: 40 Hz ([-+\d.]+) dB', a1), -2.8, 0.5, 'dB', worse_up=False)
    known(build, "the master limiter moves the image: one-sided burst, shift",
          -num(r'master out 1\.55-1\.75 s:.*image L-R ([-+\d.]+) dB', a1), 3.85, 1, 'dB')
    known(build, "the record limiter moves the image of the take: shift",
          -num(r'the take 1\.05-1\.25 s:.*image ([-+\d.]+) dB', a1), 2.78, 1, 'dB')
    # No step from a moved knob (probe4 s, an_stair.py): a 0.25 Hz sine sent once
    # a frame into track 2's level and a lane filter's cutoff, on two frame
    # clocks, at random phase. Today's lags take each step in 10 to 17 ms and
    # then stand still. Both paths hold no plugin UGen, so the rows run once,
    # in the stock build. A smoother that draws lines between the frames should
    # reach still <= 1%, longest <= 10 ms and ripple <= -45 dB: then these
    # become target rows. (Measured offline, an adaptive glide in a scratch copy
    # of the engine: 0%, 0 ms, -53 to -60 dB. Ramp.kr at 1/15 s: 3 to 4%, 65 ms.)
    if build == 'stock':
        a_s = analyse(os.path.join(REV, 'an_stair.py'), runs['p4'][0], 'p4')
        for clock, hz, kv in [('deadline', '14.9 Hz deadline clock', {'level': (72.0, 56.0, -35.0), 'cutoff': (60.8, 46.7, -34.0)}),
                              ('drift', '13.8 Hz old clock', {'level': (73.9, 60.0, -35.2), 'cutoff': (62.2, 50.7, -33.6)})]:
            for path, (k_still, k_long, k_rip) in kv.items():
                line = rf'^s\. {clock} clock, {path}: still ([\d.]+)% of the time, longest ([\d.]+) ms, ripple above 5 Hz ([-\d.]+) dB'
                known(build, f"a modulated {path} stands still, {hz}: share of the time",
                      num(line, a_s, 1), k_still, 5, '%')
                known(build, f"a modulated {path} stands still, {hz}: longest", num(line, a_s, 2), k_long, 15, 'ms')
                known(build, f"a modulated {path} steps, {hz}: ripple above 5 Hz", num(line, a_s, 3), k_rip, 3, 'dB')
    v = num(r'minus B \(left alone\): ([-\d.]+) dBFS', a1)
    say('KNOWN', build, f"the reverb's 9 knobs on a running synth change nothing: difference {v:.1f} dBFS "
        "(known -300, it cannot get worse; a change shows they act)")
    if build == 'plugin':
        known(build, "the reverb passes DC: DC 0.5 for 10 s, decay 30, shimmer 0.95, peak out",
              num(r'DC 0\.5 10 s, 0 st.*peak\s+([\d.]+)', a4), 3.16, 0.4, '')
    else:
        # FreeVerb (no plugin): the shimmer loop runs away at 0 st. Its level is
        # chaotic (unseeded WhiteNoise, PitchShift's random grains): over seven
        # runs the last RMS lay from -4.2 to +5.0 dBFS and the peak from 4.5 to
        # 9.5. So the row reads the last RMS, known 0 dBFS, with a margin of 10 dB.
        known(build, "the shimmer loop runs away at 0 st (FreeVerb): a burst, RMS at 29 s",
              num(r'decay 30, shim \.95, 0 st(?:\s+[-\d.]+){4}\s+([-\d.]+)', a1), 0, 10, 'dBFS')
        known(build, "the shimmer loop runs away at 0 st (FreeVerb): 40 Hz at 0 dBFS, RMS at 59 s",
              num(r'40 Hz 0 dBFS 10 s, 0 st(?:\s+[-\d.]+){3}\s+([-\d.]+)', a4), 0, 10, 'dBFS')
        known(build, "the reverb passes DC and runs away (FreeVerb): DC 0.5 for 10 s, 0 st, RMS at 59 s",
              num(r'DC 0\.5 10 s, 0 st(?:\s+[-\d.]+){3}\s+([-\d.]+)', a4), 0, 10, 'dBFS')

def core():
    # the FourStretch core itself (ugen/four_core.h), no SuperCollider: core_probe2.cpp
    print("---- core: ugen/four_core.h, test/dsp/review/core_probe2.cpp", flush=True)
    exe = os.path.join(WORK, 'core_probe2')
    r = subprocess.run(['clang++', '-O2', '-std=c++17', '-I' + os.path.join(REPO, 'ugen'),
                        os.path.join(REV, 'core_probe2.cpp'), '-o', exe], capture_output=True, text=True)
    if r.returncode:
        say('FAIL', 'core', 'core_probe2.cpp does not compile:\n' + r.stderr[-1500:]); return
    out = subprocess.run([exe], capture_output=True, text=True).stdout
    rows = {}
    for v in ['PLAY', 'PV', 'WARP', 'GRAIN']:
        f = [float(s) for s in re.search(rf'^{v} \(\w+\)\s+(.*)$', out, re.M).group(1).split()]
        rows[v] = dict(zip(['x1.5', 'x2', 'x4', 'x3', 'x0.5', 'x0.25'], f))
    for v in ['PLAY', 'PV', 'WARP']:
        target('core', f"{v} folds nothing at pitch 2: 15 kHz tone, fold at 18 kHz", rows[v]['x2'], -70, 'dBFS')
        target('core', f"{v} no image at pitch 0.5: 10 kHz tone", rows[v]['x0.5'], -70, 'dBFS')
        target('core', f"{v} no image at pitch 0.25: 10 kHz tone", rows[v]['x0.25'], -70, 'dBFS')
        known('core', f"{v} folds at pitch 3: 10 kHz tone", rows[v]['x3'], -37.2, 3, 'dBFS')
        known('core', f"{v} folds at pitch 4: 7.5 kHz tone", rows[v]['x4'], -27.9, 3, 'dBFS')
    known('core', "GRAIN folds at pitch 2: 15 kHz tone", rows['GRAIN']['x2'], -13.4, 3, 'dBFS')

def skips():
    for row, where in [
        ("PV and WARP are the take at speed 1", "ugen/test_core.cpp"),
        ("LP, BP and HP sound alike on both paths", "DFM1 is not on the Mac (sc3-plugins)"),
        ("RESON is in tune", "no shipped probe; it passed in the review"),
        ("The bucket brigade meets its formulas", "ugen/test_core.cpp"),
        ("Cost on the norns", "test/device/measure.py on the device")]:
        say('SKIP', '', f"{row}: {where}")

t0 = time.time()
os.makedirs(WORK, exist_ok=True); buffers()
try:
    check('stock')
    if PLUG:
        check('plugin')
    else:
        print("---- plugin: FOUR_PLUGIN_DIR is not set, the FourStretch build did not run", flush=True)
    core()
except Exception as e:
    say('FAIL', '', f"the check broke: {e}")
skips()
verdict = 'FAIL' if count['FAIL'] else 'PASS'
print(f"VERDICT {verdict}: {count['PASS']} pass, {count['KNOWN']} known, {count['FAIL']} fail, {count['SKIP']} skip; "
      f"builds: stock{', FourStretch' if PLUG else ' only'}; {time.time() - t0:.0f} s")
sys.exit(1 if count['FAIL'] else 0)
