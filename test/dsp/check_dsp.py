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
def target(build, name, v, limit, unit, low=True, fmt='.1f'):
    ok = v <= limit if low else v >= limit
    say('PASS' if ok else 'FAIL', build, f"{name}: {v:{fmt}} {unit} (limit {'<=' if low else '>='} {limit:g} {unit})")

# a known failure: fails only when it is worse than known by more than margin
def known(build, name, v, known_v, margin, unit, worse_up=True, fmt='.2f'):
    edge = known_v + margin if worse_up else known_v - margin
    bad = v > edge if worse_up else v < edge
    say('FAIL' if bad else 'KNOWN', build,
        f"{name}: {v:{fmt}} {unit} (known {known_v:g}, fails {'above' if worse_up else 'below'} {edge:g})")

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

# One build: the five probes and engine.scd in parallel, each in its own folder
# (run_probe.sh and run_engine.sh write conf.yaml and their log into it).
JOBS = [('p1', 'probe1.scd'), ('p2', 'probe2.scd'), ('p3', 'probe3.scd'), ('p4', 'probe4.scd'),
        ('p6', 'probe6.scd'), ('p7', 'probe7.scd'), ('p8', 'probe8.scd'), ('p9', 'probe9.scd'), ('eng', None)]

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
    # CLOUD is FourCloud exactly when the plugin is there (no mi-UGens on the Mac)
    m = re.search(r'four: CLOUD is (.+)', runs['eng'][3])
    cloud = m.group(1).strip() if m else '?'
    say('PASS' if (cloud == 'FourCloud') == (build == 'plugin') else 'FAIL', build,
        f"the engine says CLOUD is {cloud} (needs {'FourCloud' if build == 'plugin' else 'not FourCloud'})")
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

    # THE EFFECT SLOT AT A CHANGE OF TYPE (the forty-second change, probe6): a new
    # effect synth and the shared delay fill their lines from silence. Gate row
    # 19.12 is the same six taps on the device. Clicks are test/device/audio.py's
    # law, on both channels. The tone is near its peak when each change lands.
    a6 = analyse(os.path.join(REV, 'an_probe6.py'), runs['p6'][0], 'p6')
    target(build, "fix: the six TYPE taps of gate row 19.12 over a tone, clicks on both channels (were 2 to 11)",
           num(r'^WALK clicks (\d+)', a6), 0, '', fmt='.0f')
    target(build, "fix: every change of an effect's type (42 of them), clicks on both channels (were 54 to 73)",
           num(r'^PAIRS clicks (\d+)', a6), 0, '', fmt='.0f')
    target(build, "fix: the largest step after a change of type (was 0.098; the tone alone has 0.0004)",
           num(r'^LARGEST step after a change ([\d.]+)', a6), 0.002, '', fmt='.4f')
    target(build, "fix: the shared delay born under a tone, largest step (was 0.239 without the plugin)",
           num(r'^DELAY born under the tone: largest step ([\d.]+)', a6), 0.002, '', fmt='.4f')
    # A change into WOBBLE crossfaded the tone with a copy of itself 12 ms
    # late, and the two combed: -11 to -17 dB over six runs. Since the
    # fifty-sixth change WOBBLE's delay glides in from 0 and back out (OFF to
    # WOBBLE -15.8 dB, now -4.4). What stays is CHORUS's and FLANGE's own
    # comb, which cuts a steady tone by 9.5 to 10 dB with no change near it,
    # deeper by up to 3 dB while a WOBBLE glides out under it.
    known(build, "a change of type dips where CHORUS and FLANGE comb: deepest 5 ms against the quieter side",
          num(r'^DEEPEST series ([-\d.]+) dB', a6), -12.5, 3, 'dB', worse_up=False, fmt='.1f')
    # The Mac's scsynth (3.14) frees a released synth one control step short of
    # 0, so the filter's 20 ms straight fade ends 1/15 above 0 here. The norns's
    # scsynth (3.13) runs the release to its end: rendered there, this step is
    # 0.0005 (test/device/norns_nrt.sh, doc/measurements/2026-11-17). The row
    # is the Mac's alone.
    known(build, "a filter family swap ends on a step on the Mac's scsynth: LP to HP at 400 Hz under the tone",
          num(r'^FILTER LP to HP at 400 Hz: largest step ([\d.]+)', a6), 0.013, 0.004, '', fmt='.4f')

    # THE DELAY AND THE REVERB LEAVE (the forty-fourth change, probe6's _leave):
    # the mix goes to 0 under a tail, and the engine frees the synth 0.1 s
    # later, when io's return is 100 dB down. A free at once cut the tail.
    for name, was in (('REVERB', '1 click and 0.0204 with the plugin'), ('DELAY', '2 clicks and 0.079 to 0.115')):
        line = rf'^{name} leaves under its tail.*largest step ([\d.]+) at.*clicks (\d+); 0.1 s after the free ([-\d.]+) dB'
        target(build, f"fix: the {name.lower()} leaves under its tail, clicks on both channels (was {was})",
               num(line, a6, 2), 0, '', fmt='.0f')
        target(build, f"fix: the {name.lower()} leaves under its tail, largest step",
               num(line, a6, 1), 0.001, '', fmt='.4f')
        target(build, f"the {name.lower()} is gone 0.1 s after its free: the level then",
               num(line, a6, 3), -120, 'dB')

    # THE AMOUNT KNOB OF EACH EFFECT (the forty-fifth change, probe7). The user
    # on the device: the effects were "a bit too bland". A slot starts at
    # amount 0.5. "Moved" is the mean distance in dB between the spectrum of a
    # phrase through the effect and the phrase alone (an_probe7.py). Before the
    # change CHORUS moved it by 2.3 dB there, FLANGE 2.5, WOBBLE 3.1, ECHO 3.0,
    # and RESON and RING were 3.0 and 4.2 dB under the phrase.
    a7 = analyse(os.path.join(REV, 'an_probe7.py'), runs['p7'][0], 'p7')
    # RESON and RING moved it by 6.4 and 5.3 dB, and part of that was their loss
    # of level: RESON at 0.5 was half of the dry sound and half of the ring, and
    # it now is the whole dry sound with the ring on it. Their rows are a floor,
    # and their fix is the level row below.
    for name, floor, was in (('CHORUS', 3.0, ' (was 2.3 dB)'), ('FLANGE', 2.9, ' (was 2.5 dB)'),
                             ('WOBBLE', 4.0, ' (was 3.1 dB)'), ('RESON', 4.2, ''), ('RING', 4.5, ''),
                             ('ECHO', 3.7, ' (was 3.0 dB)')):
        target(build, f"{name} at the start amount 0.5 moves a phrase{was}",
               num(rf'^MOVED {name} at the start amount 0\.5: ([\d.]+)', a7), floor, 'dB', low=False, fmt='.2f')
    target(build, "no effect moves the phrase at amount 0: the most moved",
           max(num(rf'^MOVED {name} at amount 0: ([\d.]+)', a7) for name in
               ('CHORUS', 'FLANGE', 'WOBBLE', 'RESON', 'RING', 'ECHO')), 0.05, 'dB', fmt='.2f')
    target(build, "no effect at any amount is quieter than the phrase (RING was 4.6 dB under it)",
           num(r'^QUIETEST lane: ([-+\d.]+)', a7), -1, 'dB', low=False)
    target(build, "no effect at any amount is more than 7.5 dB over the phrase",
           num(r'^LOUDEST lane: ([-+\d.]+)', a7), 7.5, 'dB')
    # What a def costs on the norns follows its number of UGens: a control-rate
    # operator there takes about 0.01% of the scsynth thread for each synth. A
    # first version of these laws had nine more in FLANGE and four more in ECHO,
    # and the dense set of gate row 19.27 went from 62.4% to 63.5%. The limits
    # are the counts before the change. RING has one more: the sine's 2.sqrt.
    # The fifty-sixth change grew two defs on purpose: WOBBLE's delay glide
    # in four_fx_mod (85 to 90) and FLANGE's dry glide (31 to 33), about
    # 0.05% of the thread for each slot that holds one.
    for name, limit in (('four_fx_mod', 90), ('four_fx_reson', 41), ('four_fx_ring', 21),
                        ('four_fx_echo', 20 if build == 'plugin' else 28)) + \
                       ((('four_fx_flange', 33),) if build == 'plugin' else ()):
        target(build, f"the UGens of {name} (a law must not grow its def)",
               num(rf'^UGENS {name} (\d+)', runs['p7'][3].replace('\r', '')), limit, '', fmt='.0f')
    if build == 'plugin':
        target(build, "the largest peak of any effect (the phrase alone peaks at 0.35)",
               num(r'^LARGEST peak: ([\d.]+)', a7), 0.75, '', fmt='.2f')
    else:
        # the stock FLANGE is a bare comb with nothing in its loop to bound a peak
        known(build, "the stock FLANGE's comb peaks far over the phrase (the phrase alone peaks at 0.35; was 1.75)",
              num(r'^LARGEST peak: ([\d.]+)', a7), 1.19, 0.15, '')

    # A NEW TAKE STARTS AT THE START OF ITS BUFFER (C4 of the plan, the
    # forty-ninth change, probe8). io's write head stopped where a pass ended
    # and the next pass went on from there. Four passes on a buffer of 4 s: the
    # second and the fourth are new takes, the third is rec alone, as a START
    # after a STOP. Before, the four lay end to end, and 1 of 4 was in place.
    a8 = analyse(os.path.join(REV, 'an_probe8.py'), runs['p8'][0], 'p8')
    target(build, "a new take puts the write head at the start of its buffer: the head 5 ms after (was at 1.013 s)",
           num(r'^HEAD 5 ms after the new take of 2\.0 s: ([\d.]+)', a8), 0.006, 's', fmt='.4f')
    target(build, "...and so does one whose step comes a block before its rec (was at 1.830 s)",
           num(r'^HEAD 5 ms after the new take of 3\.6 s: ([\d.]+)', a8), 0.006, 's', fmt='.4f')
    target(build, "a rec alone goes on from where the head is: the head 5 ms after it, away from 0.513 s",
           abs(num(r'^HEAD 5 ms after the rec alone of 3\.0 s: ([\d.]+)', a8) - 0.513), 0.005, 's', fmt='.4f')
    jumps = re.search(r'^HEAD jumps back at: \[(.*)\] s', a8, re.M).group(1)
    say('PASS' if jumps == '2.0, 3.6' else 'FAIL', build,
        f"the head jumps back at the two new takes and nowhere else: [{jumps}] (needs [2.0, 3.6])")
    target(build, "the four passes lie in the buffer where a new take puts them (was 1 of 4)",
           num(r'^PASSES in their place: (\d) of 4', a8), 4, 'of 4', low=False, fmt='.0f')
    target(build, "the buffer past the first pass stays empty (was -15.9 dB: the next pass lay there)",
           num(r'^BUFFER past the first pass, 1\.1 to 2\.2 s: ([-\d.]+)', a8), -100, 'dB')
    target(build, "the start of a new take in the buffer has no step (a 550 Hz tone alone has 0.0013)",
           num(r'^BUFFER start, largest step in its first 50 ms: ([\d.]+)', a8), 0.002, '', fmt='.4f')
    target(build, "the UGens of four_io (106 before, and one more for the head's trigger)",
           num(r'^UGENS four_io (\d+)', runs['p8'][3].replace('\r', '')), 107, '', fmt='.0f')
    # A CLEAR WITH REGEN RUNNING (the fiftieth change, gate row 10.8, probe8's
    # _clear). The script stops regen a moment after the clear, and io's write
    # fades out over 10 ms into the pair that was just zeroed. The engine
    # zeroes the pair again when that fade is over.
    target(build, "a clear with regen running leaves nothing in the buffer: frames (were 576, 12 ms)",
           num(r'^CLEAR with regen running: frames left in the buffer (\d+)', a8), 0, '', fmt='.0f')

    # A VOICE CHANGE KEEPS ITS SOUND AND ITS PLACE (C2 of the plan, the
    # fifty-first change, probe9). The old drone left in 20 ms at once, and a new
    # WARP, PV or CLOUD drone is silent at first: a hole. The new head also
    # started at the window's start. Each change is read against the old and
    # the new drone alone (an_probe9.py): 0 dB is no hole and no bump.
    a9 = analyse(os.path.join(REV, 'an_probe9.py'), runs['p9'][0], 'p9')
    was = {'stock': ('-85.6', '-31.1'), 'plugin': ('-28.6', '-26.9')}[build]
    for src, i in (('tone', 0), ('phrase', 1)):
        target(build, f"a change among PLAY, WARP and PV over a {src}: the deepest place (was {was[i]} dB)",
               num(rf'^DEEPEST over the {src}, among PLAY, WARP and PV: ([-+\d.]+)', a9), -6, 'dB', low=False)
        target(build, f"...and the highest (two drones must not add up to a bump)",
               num(rf'^HIGHEST over the {src}, among PLAY, WARP and PV: ([-+\d.]+)', a9), 3, 'dB')
        # Grains make holes of their own, so a change into them is read at the
        # change itself. Two streams of grains never match, and this number
        # moves from render to render: 0 to -11 dB over ten of them.
        target(build, f"a change into GRAIN and CLOUD over a {src}: the deepest place at the change"
               + (" (CLOUD was silent for 341 ms)" if build == 'plugin' else ""),
               num(rf'^DEEPEST over the {src}, into GRAIN and CLOUD: ([-+\d.]+)', a9), -12, 'dB', low=False)
        target(build, f"what is heard after a change over a {src} goes on from where it was (the loop went back to its start)",
               num(rf'^PLACE furthest from where it was over the {src}: ([\d.]+)', a9), 2, 'ms')
    # Two copies of a sound cancel when they are out of step: a head placed
    # from sclang was 2 to 5 ms late on the device, and a change from PLAY into
    # PV dipped by 18 dB over a tone. The new drone reads the old head's place
    # itself. Without the plugin WARP is 17 to 25 frames behind its head.
    target(build, "after a change the new drone is in step with the old one, over the phrase: frames out of step",
           num(r'^OUT OF STEP after a change, over the phrase, at most: (\d+)', a9), 1 if build == 'plugin' else 32,
           'frames', fmt='.0f')
    # each drone has five UGens more: they put its head where the old one is.
    # (four_clouds has two more since the fifty-third change: its density and
    # its feedback glide, and they had no lag before.)
    for name, limit in ((('four_grain', 104), ('four_warp', 47), ('four_pv', 48), ('four_play', 60),
                         ('four_clouds', 117)) if build == 'plugin' else
                        (('four_grain', 107), ('four_warp', 42), ('four_pv', 104), ('four_play', 97))):
        target(build, f"the UGens of {name} (five more than before, for the head's start)",
               num(rf'^UGENS {name} (\d+)', runs['p9'][3].replace('\r', '')), limit, '', fmt='.0f')

    # THE CHECKLIST (doc/dsp-plan.md): the targets that hold
    target(build, "PLAY is the take at pitch 1: 5 kHz tone 54 s in, noise", num(r'PLAY at 54 s, pitch 1\s+tone\s+[-\d.]+ dBFS\s+noise\s+([-\d.]+)', ae), -90, 'dB')
    if build == 'plugin':
        # THE CLOUD: FourCloud in each mode of Clouds sounds, and stays finite
        for n in ['GRANULAR', 'STRETCH', 'LOOPING DELAY', 'SPECTRAL', 'GRANULAR, frozen at 2 s']:
            line = rf'^\s+{re.escape(n)}\s+RMS\s+([-\d.]+) dBFS\s+peak\s+([\d.]+)\s+not finite (\d+)'
            target(build, f"CLOUD sounds, {n}: a 1 kHz take at -9 dBFS, RMS from 1 to 6 s", num(line, ae, 1), -40, 'dBFS', low=False)
            target(build, f"CLOUD stays finite, {n}: values not finite", num(line, ae, 3), 0, '')
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
    # (the hole of a mode change into WARP and into PV was known here until the
    # fifty-first change closed it: see the rows of probe9 above)
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
    # clocks, at random phase. Before the fifty-third change each knob had a
    # lag of 20 to 50 ms: it took each step in 10 to 17 ms and then stood
    # still, 61 to 74% of the time, in stands of 47 to 60 ms, with a ripple of
    # -34 to -35 dB above 5 Hz. A knob now glides for a little more than the
    # frame its value took (the engine's glideLaw), so it draws lines between
    # the frames. Both paths hold no plugin UGen, so the rows run once, in the
    # stock build. (Ramp.kr at 1/15 s, an earlier try: 3 to 4%, 65 ms.)
    if build == 'stock':
        a_s = analyse(os.path.join(REV, 'an_stair.py'), runs['p4'][0], 'p4')
        for clock, hz, before in [('deadline', '14.9 Hz deadline clock', {'level': (72.0, 56.0, -35.0), 'cutoff': (60.8, 46.7, -34.0)}),
                                  ('drift', '13.8 Hz old clock', {'level': (73.9, 60.0, -35.2), 'cutoff': (62.2, 50.7, -33.6)})]:
            for path, was in before.items():
                line = rf'^s\. {clock} clock, {path}: still ([\d.]+)% of the time, longest ([\d.]+) ms, ripple above 5 Hz ([-\d.]+) dB'
                target(build, f"a modulated {path} does not stand still, {hz}: share of the time (was {was[0]:g}%)",
                       num(line, a_s, 1), 1, '%')
                target(build, f"a modulated {path} does not stand still, {hz}: longest stand (was {was[1]:g} ms)",
                       num(line, a_s, 2), 10, 'ms')
                target(build, f"a modulated {path} does not step, {hz}: ripple above 5 Hz (was {was[2]:g} dB)",
                       num(line, a_s, 3), -45, 'dB')
    # A hand on a knob: one write after a rest lands as soon as it did (the old
    # lag was within 1% after 20 ms), though a stream of frames went before it.
    if build == 'stock':
        target(build, "one write of a level after a rest lands (was 20.1 ms)",
               num(r'^t\. a hand: one write after a rest lands after ([\d.]+) ms', a_s), 22, 'ms')
    # A knob's glide is one UGen where its lag was one (VarLag for Lag), so
    # the lane's parts and the delay are as they were. The reverb has two
    # more with the plugin and three more without: its decay, its damping and
    # its shimmer had no lag at all. (The Mac has no DFM1 and no JPverb: the
    # filter and the reverb count their stock paths here.)
    for name, limit in (('four_lane_in', 28), ('four_filt_lo', 26), ('four_filt_hi', 14), ('four_colour', 40),
                        ('four_lane_out', 15), ('four_delay', 17 if build == 'plugin' else 21),
                        ('four_reverb', 38 if build == 'plugin' else 33)):
        target(build, f"the UGens of {name} (a glide must not grow a def)",
               num(rf'^UGENS {name} (\d+)', runs['p4'][3].replace('\r', '')), limit, '', fmt='.0f')
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
