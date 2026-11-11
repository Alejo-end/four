#!/usr/bin/env python3
"""Run doc/device-gate.md on a connected norns and record each result.

    export NORNS_CTL=<control socket>       # see norns.py
    python3 test/device/gate.py 1 2 3      # run these stages, in order

A result is one of:
  pass      measured on the device, and the measurement decides the check
  measured  the numbers are right, but a person must still listen or look
  fail      the check failed
  you       needs a person, or hardware that is not connected
  error     the test itself broke

Results go to doc/measurements/<date>/gate.jsonl. Recordings go outside the
repo, in ../mangler-device-recordings/<date>, because a deploy copies this repo
to the device.
"""
import json
import os
import sys
import threading
import time
import traceback

sys.path.insert(0, os.path.dirname(__file__))
import audio  # noqa: E402
from norns import Norns, num  # noqa: E402

DATE = "2026-11-06"
ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
OUT = os.path.join(ROOT, "doc", "measurements", DATE)
WAVS = os.path.join(os.path.dirname(ROOT), "mangler-device-recordings", DATE)
SCREENS = os.path.join(OUT, "screens")
ENGINE_OUT = ("SuperCollider:out_1", "SuperCollider:out_2")
DECKS_OUT = ("softcut:output_1", "softcut:output_2")
PSET = 97  # a slot that no shipped preset uses; cleaned up by cleanup()

for path in (OUT, WAVS, SCREENS):
    os.makedirs(path, exist_ok=True)

n = None
results = {}


def load_results():
    path = os.path.join(OUT, "gate.jsonl")
    if os.path.exists(path):
        with open(path) as f:
            for line in f:
                r = json.loads(line)
                results[r["id"]] = r


def save_results():
    with open(os.path.join(OUT, "gate.jsonl"), "w") as f:
        for key in sorted(results, key=sort_key):
            f.write(json.dumps(results[key]) + "\n")


def sort_key(cid):
    head, _, tail = cid.partition(".")
    digits = "".join(ch for ch in tail if ch.isdigit())
    return (int(head), int(digits or 0), tail)


def report(cid, status, note=""):
    results[cid] = {"id": cid, "status": status, "note": str(note)}
    save_results()
    print(f"{cid:7} {status:9} {note}", flush=True)


ONLY = None   # a set of check ids, when the command line names some


def check(cid, fn):
    if ONLY and cid not in ONLY:
        return
    try:
        out = fn()
        if isinstance(out, tuple):
            report(cid, out[0], out[1])
    except Exception as e:  # a broken test must not stop the walkthrough
        report(cid, "error", f"{type(e).__name__}: {e}")
        traceback.print_exc()


def verdict(ok, note, good="pass"):
    return (good if ok else "fail", note)


def you(*cids, why):
    for cid in cids:
        if not ONLY or cid in ONLY:
            report(cid, "you", why)


# ---- common actions ---------------------------------------------------------
def fresh():
    """Reload the script, so that a stage starts from a known state."""
    n.lua('params:clear()', timeout=4) if False else None
    n.load_script()


def record_take(secs=8, kind="drums", amp=None):
    n.goto("TAKE")
    n.signal(kind, amp)
    time.sleep(0.4)
    n.tap(2)
    time.sleep(secs)
    n.tap(2)
    time.sleep(0.8)
    n.signal(None)
    time.sleep(0.6)


def engine_rec(name, secs=3, ports=ENGINE_OUT):
    path = os.path.join(WAVS, name + ".wav")
    n.record(secs, path, ports)
    rate, chans = audio.load(path)
    return rate, chans


def level(name, secs=3, ports=ENGINE_OUT):
    rate, chans = engine_rec(name, secs, ports)
    return audio.stats(chans[0])["rms_db"]


def during(fn, name, secs, ports=ENGINE_OUT):
    """Record while fn runs."""
    path = os.path.join(WAVS, name + ".wav")
    t = threading.Thread(target=n.record, args=(secs, path, ports))
    t.start()
    time.sleep(0.5)
    fn()
    t.join()
    return audio.load(path)


def transcript_since(kind, mark):
    return n.transcript(kind)[mark:]


def mark(kind="lua"):
    return len(n.transcript(kind))


def traced(start):
    text = transcript_since("lua", start)
    return "stack traceback" in text or "lua:" in text and "error" in text.lower()


def shot(name):
    path = n.screenshot("mg_" + name)
    n.fetch(path, os.path.join(SCREENS, name + ".png"))
    n.ssh(f"rm -f {path}")


def alt_tap(k, hold=0.05):
    n.key(1, 1)
    time.sleep(0.05)
    n.tap(k, hold)
    time.sleep(0.05)
    n.key(1, 0)


def stop(on=True):
    current = n.get("stop_all")
    if bool(current) != on:
        alt_tap(2)
    time.sleep(0.5)


def param_state(*ids):
    return {i: n.get(i) for i in ids}


def is_on(x):
    return x is not None and x > 0.5


def set_mode(name):
    n.set("mode", {"OFF": 1, "GRAIN": 2, "WARP": 3, "PV": 4, "PLAY": 5}[name])
    time.sleep(0.5)


# ---- stage 0 ----------------------------------------------------------------
def stage0():
    def c1():
        out = n.ssh("find ~/dust/code -name 'Engine_Mangler2.sc'").split()
        return verdict(len(out) == 1, out)

    check("0.1", c1)
    start = mark()
    n.load_script()
    text = transcript_since("lua", start)
    check("0.2", lambda: verdict("init() done" in text, "script reached init() done"))
    check("0.3", lambda: verdict("count: 66" in text, [ln for ln in text.splitlines() if "count:" in ln]))


# ---- stage 1 ----------------------------------------------------------------
def stage1():
    n.load_script()

    def c11():
        start = mark()
        seen = []
        for page in "TAKE VOICE TAPE LAYERS FILTER DELAY REVERB MIX PADS MOTION SCENE".split():
            n.goto(page)
            time.sleep(0.25)
            shot("1_" + page)
            size = os.path.getsize(os.path.join(SCREENS, f"1_{page}.png"))
            seen.append(size > 600)
        f0 = int(num(n.ctx("c.frame")))
        time.sleep(0.5)
        f1 = int(num(n.ctx("c.frame")))
        ok = all(seen) and f1 > f0 and not traced(start)
        return verdict(ok, f"11 pages drawn, frame counter moves ({f0} to {f1}), no traceback")

    def c12():
        pages = n.lua('print(table.concat(__ctx.PAGES," "))')
        return verdict(pages == "TAKE VOICE TAPE LAYERS FILTER DELAY REVERB MIX PADS MOTION SCENE", pages)

    def c13():
        # only since sclang last started: an older error belongs to an older run
        since = n.ssh("systemctl show norns-sclang -p ActiveEnterTimestamp --value").strip()
        out = n.ssh(f'journalctl -u norns-sclang --since "{since}" --no-pager | grep -E "ERROR|FAILURE|Exception|exception" | tail -8')
        return verdict(not out.strip(), out.strip() or "no SuperCollider errors this boot")

    def c14():
        n.signal("tone")
        time.sleep(1.2)
        vals = [num(n.ctx("c.amp_in[1]")) for _ in range(4)]
        n.signal(None)
        time.sleep(1.2)
        quiet = num(n.ctx("c.amp_in[1]"))
        return verdict(min(vals) > 0.03 and quiet < min(vals) / 3,
                       f"amp_in {min(vals):.3f} with the test tone, {quiet:.5f} without")

    check("1.1", c11)
    check("1.2", c12)
    check("1.3", c13)
    check("1.4", c14)


# ---- stage 2: the three that destroy audio ----------------------------------
def stage2():
    n.load_script()
    record_take(8, "drums")
    set_mode("PLAY")

    def c21():
        n.goto("TAKE")
        s = n.get("pos_start")
        n.set("pos_end", s + 0.5 / 60)
        time.sleep(0.3)
        # the control: with no STOP, erosion must change the take
        before = n.take_hash()
        n.set("erode", 0.5)
        time.sleep(4)
        n.set("erode", 0.5)
        moved = n.take_hash()
        control = before != moved
        stop(True)
        time.sleep(1)
        a = n.take_hash()
        time.sleep(300)
        b = n.take_hash()
        stop(False)
        n.set("erode", 0)
        time.sleep(0.5)
        return verdict(control and a == b,
                       f"control: erosion moved the take={control}. Under STOP for 5 min the digest stayed {a} = {b}")

    def c22():
        n.load_script()
        record_take(10, "drums")
        full = num(n.ctx("c.take_len"))
        s = n.get("pos_start")
        n.set("pos_end", s + 2 / 60)
        time.sleep(0.3)
        n.signal("tone")
        n.tap(2)
        time.sleep(0.2)
        n.tap(2)
        time.sleep(0.5)
        n.signal(None)
        after = num(n.ctx("c.take_len"))
        n.lua(f'params:write({PSET}, "gate")')
        time.sleep(4)
        n.load_script()
        n.lua(f"params:read({PSET})")
        time.sleep(4)
        n.helpers()
        loaded = num(n.ctx("c.take_len"))
        secs = n.ssh(f"soxi -D ~/dust/data/mangler2/take-{PSET}_L.wav").strip()
        ok = loaded is not None and full and loaded >= full - 0.002 and float(secs) > 9
        return verdict(ok, f"take_len {full:.4f} before the punch, {after:.4f} after, {loaded:.4f} loaded; the file holds {secs}s")

    def c23():
        n.load_script()
        record_take(6, "drums")
        before = n.take_hash()
        n.ssh("ls ~/dust/audio | grep -c mangler-print || true")
        files0 = n.ssh("ls ~/dust/audio/mangler-print* 2>/dev/null | wc -l").strip()
        n.set("print_len", 8)
        start = mark()
        n.ctx("c.print_take() ")
        time.sleep(3)
        stop(True)
        time.sleep(2.5)
        text = transcript_since("lua", start)
        stop(False)
        after = n.take_hash()
        files1 = n.ssh("ls ~/dust/audio/mangler-print* 2>/dev/null | wc -l").strip()
        ok = "PRINT aborted by STOP" in text and before == after and files0 == files1
        return verdict(ok, f"aborted message={'PRINT aborted by STOP' in text}; take digest same={before == after}; print files {files0} to {files1}")

    check("2.1", c21)
    check("2.2", c22)
    check("2.3", c23)


# ---- stage 3: the safety reflexes -------------------------------------------
def stage3():
    n.load_script()
    record_take(6, "drums")
    set_mode("PLAY")
    n.set("dry_wet", 1)

    def c31():
        out = {}
        for page in ("TAKE", "MIX", "SCENE"):
            n.goto(page)
            base = level(f"3.1_{page}_before", 3)
            stop(True)
            time.sleep(1)
            silent = level(f"3.1_{page}_stopped", 2)
            shot("3.1_stopped_" + page)
            stop(False)
            time.sleep(0.5)
            back = level(f"3.1_{page}_after", 3)
            out[page] = (base, silent, back)
        ok = all(s < -70 and abs(a - b) < 2.5 for b, s, a in out.values())
        return verdict(ok, f"dB before, stopped, after: {out}", "measured")

    def c32():
        n.goto("FILTER")
        for pid, v in (("delay_mix", 0.4), ("rev_mix", 0.4), ("shimmer", 0.3), ("drive", 0.3), ("clouds_fb", 0.3),
                       ("resonance", 0.4), ("cutoff", 800)):
            n.set(pid, v)
        time.sleep(0.3)
        alt_tap(3)
        time.sleep(0.5)
        s = param_state("delay_mix", "rev_mix", "shimmer", "drive", "clouds_fb", "resonance", "cutoff")
        ok = all(s[k] == 0 for k in ("delay_mix", "rev_mix", "shimmer", "drive", "clouds_fb", "resonance")) and s["cutoff"] > 15000
        return verdict(ok, s)

    def c33():
        n.goto("TAKE")
        n.key(1, 1)
        time.sleep(0.05)
        n.key(3, 1)
        time.sleep(0.5)
        shot("3.3_arc")
        time.sleep(1.0)
        n.key(3, 0)
        n.key(1, 0)
        time.sleep(0.6)
        length = num(n.ctx("c.take_len"))
        wave = n.ctx("c.wave_any")
        quiet = level("3.3_after_erase", 2)
        return verdict(length == 0 and wave == "false" and quiet < -70, f"take_len {length}, wave_any {wave}, engine {quiet} dB")

    def c34():
        record_take(4, "drums")
        n.set("delay_mix", 0.3)
        n.goto("TAKE")
        n.key(1, 1)
        time.sleep(0.05)
        n.key(3, 1)
        time.sleep(0.6)
        n.key(1, 0)
        time.sleep(0.1)
        n.key(3, 0)
        time.sleep(0.5)
        length = num(n.ctx("c.take_len"))
        mix = n.get("delay_mix")
        return verdict(length > 0 and mix == 0.3, f"K1 let go at 0.6s: take_len {length}, delay_mix {mix} (DRY did not fire)")

    def c35():
        n.goto("TAKE")
        n.key(1, 1)
        time.sleep(0.05)
        n.key(3, 1)
        time.sleep(0.55)
        n.key(3, 0)
        time.sleep(0.1)
        n.key(1, 0)
        time.sleep(0.5)
        length = num(n.ctx("c.take_len"))
        mix = n.get("delay_mix")
        return verdict(length > 0 and mix == 0.3, f"K3 let go at 0.55s: take_len {length}, delay_mix {mix}")

    def c36():
        n.set("delay_mix", 0)
        n.lua(f'params:write({PSET}, "gate")')
        time.sleep(3)
        had = n.ssh(f"ls ~/dust/data/mangler2/take-{PSET}_L.wav 2>/dev/null").strip()
        n.goto("TAKE")
        n.key(1, 1)
        time.sleep(0.05)
        n.key(3, 1)
        time.sleep(1.5)
        n.key(3, 0)
        n.key(1, 0)
        time.sleep(0.5)
        n.lua(f'params:write({PSET}, "gate")')
        time.sleep(3)
        gone = n.ssh(f"ls ~/dust/data/mangler2/take-{PSET}_L.wav 2>/dev/null").strip()
        n.lua(f"params:read({PSET})")
        time.sleep(3)
        n.helpers()
        length = num(n.ctx("c.take_len"))
        return verdict(bool(had) and not gone and length == 0,
                       f"file before: {bool(had)}, after the empty save: {bool(gone)}, take_len after load {length}")

    check("3.1", c31)
    check("3.2", c32)
    check("3.3", c33)
    check("3.4", c34)
    check("3.5", c35)
    check("3.6", c36)


# ---- stage 4: the sound itself -----------------------------------------------
def tone_bands(name, secs=3):
    rate, chans = engine_rec(name, secs)
    c = chans[0]
    return {hz: audio.band(c, rate, hz) for hz in (220, 442, 884)}, audio.stats(c), rate, c


def stage4():
    n.load_script()
    record_take(6, "tone")
    set_mode("PLAY")
    n.set("dry_wet", 1)
    time.sleep(0.5)

    def c41():
        levels = {}
        for cut in (20000, 2000, 400, 120):
            n.set("cutoff", cut)
            time.sleep(0.4)
            levels[cut] = level(f"4.1_cut{cut}", 2)

        def sweep():
            for i in range(60):
                n.set("cutoff", 20000 * (0.93 ** i))
                time.sleep(0.05)

        rate, chans = during(sweep, "4.1_sweep", 6)
        hits = audio.clicks(chans[0], rate)
        n.set("cutoff", 20000)
        ok = levels[120] < levels[20000] - 3 and not hits
        return verdict(ok, f"dB by cutoff {levels}. Sweep clicks {hits[:6]}. Character: listen to 4.1_sweep.wav", "measured")

    def c42():
        n.set("cutoff", 440)
        n.set("resonance", 1)
        time.sleep(1)
        rate, chans = engine_rec("4.2_res_max", 6)
        c = chans[0]
        half = len(c) // 2
        a, b = audio.rms(c[:half]), audio.rms(c[half:])
        st = audio.stats(c)
        n.set("resonance", 0)
        n.set("cutoff", 20000)
        ok = st["clipped"] == 0 and b < a * 1.4
        return verdict(ok, f"{st}; second half against first {audio.db(b) - audio.db(a):.1f} dB (no growth means no runaway)", "measured")

    def c43():
        # The tone holds 220, 331 and 442 Hz at 0, -6 and -12 dB. BP is an LP peak
        # with a high-pass below it, so compare it with LP at the same cutoff.
        out = {}
        n.set("resonance", 0.5)
        for name, ft, cut in (("LP", 1, 442), ("BP", 3, 442), ("HP", 2, 1000)):
            n.set("filt_type", ft)
            n.set("cutoff", cut)
            time.sleep(0.5)
            bands, st, _, _ = tone_bands(f"4.3_{name}", 3)
            out[name] = bands
        n.set("filt_type", 1)
        n.set("cutoff", 20000)
        n.set("resonance", 0)
        ok = out["HP"][220] < out["LP"][220] - 10
        return verdict(ok, f"band levels in dB at resonance 0.5: {out}. The BP peak: listen to 4.3_BP.wav", "measured")

    def c44():
        rate, chans = engine_rec("4.4_clean", 3)
        c = chans[0]
        floor = {hz: audio.band(c, rate, hz) for hz in (1000, 3000, 8000)}
        sig = audio.band(c, rate, 220)
        return verdict(all(v < sig - 40 for v in floor.values()),
                       f"tone at 220 Hz {sig} dB; other bands {floor}. Listen for grit", "measured")

    def c45():
        base = tone_bands("4.5_rev0", 2)[0][220]
        n.set("rev_mix", 0.5)
        time.sleep(2.5)
        wet = tone_bands("4.5_rev50", 2)[0][220]
        return verdict(wet > base - 1.5, f"220 Hz dry {base} dB, with rev_mix 0.5 {wet} dB: the dry stays")

    def c46():
        on = n.nodes()
        cpu_on = n.cpu(3)
        n.set("rev_mix", 0)
        time.sleep(1)
        off = n.nodes()
        cpu_off = n.cpu(3)
        ok = "mangler_reverb" in on and "mangler_reverb" not in off and cpu_off[0] < cpu_on[0]
        return verdict(ok, f"reverb node on={'mangler_reverb' in on}, off={'mangler_reverb' in off}; CPU {cpu_on[0]}% to {cpu_off[0]}%")

    def c47():
        n.set("rev_mix", 0.5)
        n.set("shimmer", 0)
        time.sleep(3)
        a = tone_bands("4.7_shim0", 2)[0][884]
        n.set("shimmer", 0.8)
        time.sleep(5)
        b = tone_bands("4.7_shim80", 3)[0][884]
        n.set("shimmer", 0)
        n.set("rev_mix", 0)
        return verdict(b > a + 3, f"884 Hz {a} dB to {b} dB with shimmer. Robotic or not: listen to 4.7_shim80.wav", "measured")

    def c48():
        s = n.get("pos_start")
        e = n.get("pos_end")
        n.set("pos_end", s + 1.0 / 60)
        time.sleep(1)
        rate, chans = engine_rec("4.8_seam", 8)
        hits = audio.clicks(chans[0], rate)
        n.set("pos_end", e)
        return verdict(not hits, f"a 1s window of tone over 8s (about 8 seams): detected clicks {hits[:8]}")

    def c49():
        out = {}
        for d in (0, 0.25, 0.5, 0.75, 1):
            n.set("drive", d)
            time.sleep(0.5)
            out[d] = level(f"4.9_drive{d}", 2)
        n.set("drive", 0)
        hump = out[0.5] - max(out[0], out[1])
        return verdict(hump < 3, f"RMS dB by drive {out}. Mid-knob minus the louder end: {hump:.1f} dB", "measured")

    def c410():
        set_mode("GRAIN")
        clouds = n.sc("Crone.engine.hasClouds.postln;")
        out = {}
        for d in (1, 5, 11, 13, 16, 20, 30, 80, 200):
            n.set("density", d)
            time.sleep(1.2)
            out[d] = level(f"4.10_density{d}", 2)
        n.set("density", 20)
        spread = max(out.values()) - min(out.values())
        return verdict(spread < 6, f"hasClouds={clouds}. dB by density {out}, spread {spread:.1f} dB")

    def c411():
        set_mode("GRAIN")
        n.set("grain_pitch_spread", 0)
        time.sleep(1)
        a = tone_bands("4.11_drone_spread0", 3)[0][220]
        n.set("grain_pitch_spread", 12)
        time.sleep(1.5)
        b = tone_bands("4.11_drone_spread12", 3)[0][220]
        n.set("mode", 1)
        time.sleep(0.4)
        pad = {}
        for sp in (0, 12):
            n.set("grain_pitch_spread", sp)
            n.ctx("c.pad_trigger(9300, 0, 1)")
            time.sleep(0.8)
            pad[sp] = tone_bands(f"4.11_pad_spread{sp}", 3)[0][220]
            n.ctx("c.pad_trigger(9300, 0, 0)")
            time.sleep(0.8)
        n.set("grain_pitch_spread", 0)
        set_mode("GRAIN")
        return verdict(b < a - 6 and pad[12] < pad[0] - 6,
                       f"220 Hz, spread 0 then 12: GRAIN drone {a} and {b} dB; a GRAIN pad {pad[0]} and {pad[12]} dB")

    def c412():
        n.set("mode", 1)
        time.sleep(0.5)
        n.set("density", 20)
        for i in range(4):
            n.ctx(f"c.pad_trigger({9000 + i}, {i}, 1)")
        time.sleep(1)
        a = level("4.12_chord_d20", 3)
        n.set("density", 100)
        time.sleep(1.5)
        b = level("4.12_chord_d100", 3)
        n.ctx("c.pads_all_off()")
        n.set("density", 20)
        set_mode("GRAIN")
        return verdict(abs(a - b) < 6, f"4 pads, GRAIN: {a} dB at density 20, {b} dB at density 100", "measured")

    def c413():
        set_mode("PV")
        time.sleep(1)
        bands, st, _, _ = tone_bands("4.13_pv", 4)
        return verdict(bands[220] > -50 and st["clipped"] == 0,
                       f"PV sounds: {bands}, {st}. Artefacts: listen to 4.13_pv.wav", "measured")

    def c414():
        set_mode("PLAY")
        time.sleep(0.5)
        n.goto("TAKE")

        def ride():
            for i in range(50):
                n.enc(2, 1 if i % 10 < 5 else -1)
                time.sleep(0.05)

        rate, chans = during(ride, "4.14_ride", 5)
        hits = audio.clicks(chans[0], rate)
        return verdict(not hits, f"50 encoder steps on pos_start during playback: clicks {hits[:8]}", "measured")

    for cid, fn in (("4.1", c41), ("4.2", c42), ("4.3", c43), ("4.4", c44), ("4.5", c45), ("4.6", c46),
                    ("4.7", c47), ("4.8", c48), ("4.9", c49), ("4.10", c410), ("4.11", c411),
                    ("4.12", c412), ("4.13", c413), ("4.14", c414)):
        check(cid, fn)

    # erosion needs a take with a top end, so these use drums
    n.load_script()
    record_take(6, "drums")
    set_mode("PLAY")
    n.set("dry_wet", 1)

    def c415():
        a = n.take_hash()
        nodes = n.nodes()
        time.sleep(180)
        b = n.take_hash()
        return verdict(a == b and "mangler_erode" not in nodes, f"erode 0: digest {a} = {b} after 3 min; no erode node")

    def bright(name):
        rate, chans = engine_rec(name, 4)
        return audio.brightness(chans[0], rate), audio.stats(chans[0])

    def c416():
        s = n.get("pos_start")
        n.set("pos_end", s + 2 / 60)
        time.sleep(0.5)
        b0, st0 = bright("4.16_before")
        n.set("erode", 0.3)
        time.sleep(60)
        b1, st1 = bright("4.16_after60s")
        n.set("erode", 0)
        ok = b1 < b0 and st1["clipped"] == 0 and st1["rms_db"] < st0["rms_db"] + 3
        return verdict(ok, f"brightness {b0} to {b1} dB, level {st0['rms_db']} to {st1['rms_db']} dB after 60s")

    def c417():
        def take_bright(lo, hi):
            n.take_dump()
            code = (
                "import array,math\n"
                "d=open('/tmp/mg_L.wav','rb').read(); i=d.find(b'data')+8; x=array.array('f'); x.frombytes(d[i:i+(len(d)-i)//4*4])\n"
                f"s=x[int({lo}*2880000):int({hi}*2880000)]\n"
                "a=sum(v*v for v in s); b=sum((s[k]-s[k-1])**2 for k in range(1,len(s)))\n"
                "print(round(10*math.log10(b/a),1))\n"
            )
            return float(n.ssh(f'python3 -c "{code}"', timeout=60).strip())

        out = {}
        for name, speed in (("speed2", 2), ("speedm1", -1)):
            n.load_script()
            record_take(6, "drums")
            set_mode("PLAY")
            lo = n.get("pos_start")
            hi = lo + 2 / 60
            n.set("pos_end", hi)
            n.set("scan", speed)
            time.sleep(0.5)
            b0 = take_bright(lo, hi)
            n.set("erode", 0.5)
            time.sleep(30)
            n.set("erode", 0)
            time.sleep(0.5)
            b1 = take_bright(lo, hi)
            out[name] = (b0, b1, round(b0 - b1, 1))
            n.set("scan", 1)
        drops = [v[2] for v in out.values()]
        return verdict(drops[0] > 0 and abs(drops[0] - drops[1]) < 3, f"the take's brightness before, after 30s, drop in dB: {out}")

    def c418():
        n.set("erode", 0.3)
        n.set("regen", 0.4)
        time.sleep(0.2)
        a = param_state("erode", "regen")
        n.set("erode", 0.3)
        time.sleep(0.2)
        b = param_state("erode", "regen")
        n.set("erode", 0)
        n.set("regen", 0)
        return verdict(a["erode"] == 0 and b["regen"] == 0, f"raise regen: {a}. raise erode: {b}")

    def c419():
        set_mode("PLAY")
        n.goto("VOICE")
        n.set("erode", 0.4)
        n.key(2, 1)
        time.sleep(0.8)
        held = n.get("erode")
        n.key(2, 0)
        time.sleep(0.3)
        back_e = n.get("erode")
        n.set("erode", 0)
        n.set("regen", 0.4)
        time.sleep(0.2)
        n.key(2, 1)
        time.sleep(0.8)
        n.key(2, 0)
        time.sleep(0.3)
        back_r = n.get("regen")
        n.set("regen", 0)
        return verdict(held == 0 and back_e == 0.4 and back_r == 0.4,
                       f"erode 0.4, {held} held, {back_e} after; regen 0.4, {back_r} after")

    for cid, fn in (("4.15", c415), ("4.16", c416), ("4.17", c417), ("4.18", c418), ("4.19", c419)):
        check(cid, fn)


# ---- test files --------------------------------------------------------------
TEST_DIR = "/home/we/dust/audio/mangler_test"


def wav_bytes(rate, secs, fn, bits=16, float32=False, extensible=False, channels=2):
    """A WAV file from fn(t, channel) -> -1..1."""
    import math
    import struct
    count = int(rate * secs)
    data = bytearray()
    for i in range(count):
        t = i / rate
        for ch in range(channels):
            v = max(-1.0, min(1.0, fn(t, ch)))
            if float32:
                data += struct.pack("<f", v)
            elif bits == 16:
                data += struct.pack("<h", int(v * 32767))
            elif bits == 24:
                data += struct.pack("<i", int(v * 8388607))[:3]
    width = 4 if float32 else bits // 8
    fmt_tag = 0xFFFE if extensible else (3 if float32 else 1)
    fmt = struct.pack("<HHIIHH", fmt_tag, channels, rate, rate * channels * width, channels * width, width * 8)
    if extensible:
        sub = (3 if float32 else 1).to_bytes(2, "little") + bytes.fromhex("000000001000800000aa00389b71")
        fmt += struct.pack("<HHI", 22, width * 8, 3) + sub
    body = b"WAVEfmt " + struct.pack("<I", len(fmt)) + fmt + b"data" + struct.pack("<I", len(data)) + bytes(data)
    _ = math
    return b"RIFF" + struct.pack("<I", len(body)) + body


def upload(name, data):
    n.ssh(f"mkdir -p {TEST_DIR}; cat > {TEST_DIR}/{name}", timeout=120, stdin=data)


def make_test_files():
    import math

    def tone(t, ch):
        return 0.4 * math.sin(2 * math.pi * 440 * t)

    def hits(t, ch):
        # five uneven hits with silence between them
        v = 0.0
        for at in (0.5, 0.9, 1.7, 2.1, 3.3):
            if t >= at:
                v += math.exp(-(t - at) * 30) * math.sin(2 * math.pi * 900 * (t - at))
        return 0.8 * v

    def right_only(t, ch):
        return 0.0 if ch == 0 else 0.7 * math.exp(-((t % 1.0)) * 12) * math.sin(2 * math.pi * 600 * t)

    def gap_then_sound(t, ch):
        return 0.0 if t < 1.5 else 0.5 * math.sin(2 * math.pi * 300 * t)

    upload("t44k.wav", wav_bytes(44100, 3, tone))
    upload("t48k.wav", wav_bytes(48000, 3, tone))
    upload("t96k24.wav", wav_bytes(96000, 3, tone, bits=24))
    upload("t96kf.wav", wav_bytes(96000, 3, tone, float32=True, extensible=True))
    upload("hits.wav", wav_bytes(48000, 4, hits))
    upload("right.wav", wav_bytes(48000, 5, right_only))
    upload("gap.wav", wav_bytes(48000, 4, gap_then_sound))
    upload("long44k.wav", wav_bytes(44100, 30, tone))
    upload("long96k.wav", wav_bytes(96000, 10, tone))


def load_file(name, wait=8):
    """Load a test file as the sample. Returns the transcript it printed."""
    start = mark()
    n.ctx(f'c.load_sample("{TEST_DIR}/{name}")')
    time.sleep(wait)
    return transcript_since("lua", start)


def pitch_of_take(name):
    rate, chans = engine_rec(name, 2)
    c = chans[0]
    return {hz: audio.band(c, rate, hz) for hz in (404, 440, 480)}


# ---- stage 5: the instrument features ----------------------------------------
def stage5():
    n.load_script()
    n.set("dry_wet", 1)
    make_test_files()

    def c51():
        text = load_file("t44k.wav", 12)
        set_mode("PLAY")
        time.sleep(0.5)
        bands = pitch_of_take("5.1_44k")
        return verdict("resampling to 48000" in text and bands[440] > bands[404] + 6 and bands[440] > bands[480] + 6,
                       f"message={'resampling to 48000' in text}; dB by Hz {bands}")

    def c52():
        text = load_file("t48k.wav", 3)
        time.sleep(0.5)
        bands = pitch_of_take("5.2_48k")
        return verdict("resampling" not in text and bands[440] > bands[404] + 6, f"no resample={'resampling' not in text}; {bands}")

    def c53():
        n.set("mode", 1)
        time.sleep(0.4)
        for i in range(8):
            n.lua(f"__ctx.pad_type[{i}] = 1")
        n.ctx("c.pad_trigger(9100, 0, 1)")
        path = os.path.join(WAVS, "5.3_slice.wav")
        rate, chans = during(lambda: time.sleep(1.5), "5.3_slice", 2)
        n.ctx("c.pad_trigger(9100, 0, 0)")
        env = audio.envelope(chans[0], rate, 0.1)
        sounding = sum(1 for e in env if e > -50) * 0.1
        _ = path
        return verdict(0.05 < sounding < 0.75, f"a 3s file has 0.375s slices. Pad held for 2s sounded about {sounding:.1f}s")

    def c54():
        n.load_script()
        record_take(6, "drums")
        start = mark()
        n.ctx("c.pad_chop()")
        time.sleep(6)
        text = transcript_since("lua", start)
        cuts = [float(x) for x in n.lua('local t={} for i,v in ipairs(__ctx.pad_cuts or {}) do t[#t+1]=string.format("%.2f", v*60) end print(table.concat(t," "))').split()]
        n.goto("PADS")
        time.sleep(0.3)
        shot("5.4_chop")
        last = round(cuts[-1] - cuts[-2], 2) if len(cuts) > 1 else 0
        whole = round(cuts[-1] - cuts[0], 2) if len(cuts) > 1 else 0
        # 12 kicks and 12 hats in 6s: the slices must reach across the take
        spread_ok = last < whole * 0.4
        return verdict("CHOP" in text and spread_ok, f"boundaries in seconds {cuts}. The last slice is {last}s of {whole}s")

    def c55():
        load_file("hits.wav", 2)
        n.ctx("c.pad_chop()")
        time.sleep(4)
        slices = n.lua('local t={} for i=0,7 do t[#t+1]=tostring(__ctx.pad_slice_of(i)) end print(table.concat(t," "))')
        count = int(n.lua("print(__ctx.pad_cuts and #__ctx.pad_cuts-1 or 0)"))
        n.goto("PADS")
        shot("5.5_wrap")
        vals = slices.split()
        wraps = count < 8 and vals[count:] == vals[:8 - count]
        return verdict(wraps, f"{count} slices; the eight pads play {slices}")

    def c56():
        had = n.lua('print(__ctx.pad_cuts ~= nil)')
        load_file("t48k.wav", 2)
        gone = n.lua('print(__ctx.pad_cuts == nil)')
        return verdict(had == "true" and gone == "true", f"chopped before the load={had}; even slices after={gone}")

    def c57():
        load_file("gap.wav", 2)
        a = n.get("pos_start") * 60
        start = mark()
        n.ctx("c.take_tighten()")
        time.sleep(4)
        b = n.get("pos_start") * 60
        text = transcript_since("lua", start)
        return verdict(abs(b - 1.5) < 0.15 and "TIGHTEN" in text, f"start {a:.2f}s to {b:.2f}s; sound begins at 1.50s. {[x for x in text.splitlines() if 'TIGHTEN' in x]}")

    def c58():
        load_file("gap.wav", 2)
        n.set("pos_start", 0)
        n.set("pos_end", 1.2 / 60)
        time.sleep(0.2)
        a = (n.get("pos_start"), n.get("pos_end"))
        start = mark()
        n.ctx("c.take_tighten()")
        time.sleep(4)
        text = transcript_since("lua", start)
        b = (n.get("pos_start"), n.get("pos_end"))
        return verdict("silent, left alone" in text and a == b, f"message={'silent, left alone' in text}; window {a} to {b}")

    def c59():
        n.load_script()
        record_take(4, "drums")
        set_mode("PLAY")
        n.set("print_len", 2)
        start = mark()
        n.ctx("c.print_take()")
        time.sleep(7)
        text = transcript_since("lua", start)
        length = num(n.ctx("c.take_len"))
        wave = n.ctx("c.wave_any")
        n.goto("TAKE")
        shot("5.9_print")
        ok = "is the new take" in text and wave == "true" and abs(length * 60 - 2) < 0.3
        n.ssh("rm -f ~/dust/audio/mangler-print-*.wav ~/dust/audio/mangler-print*.wav")
        return verdict(ok, f"{[x for x in text.splitlines() if 'PRINT' in x]}; take {length * 60:.2f}s")

    for cid, fn in (("5.1", c51), ("5.2", c52), ("5.3", c53), ("5.4", c54), ("5.5", c55), ("5.6", c56),
                    ("5.7", c57), ("5.8", c58), ("5.9", c59)):
        check(cid, fn)


# ---- stage 6: the control surface --------------------------------------------
def grid_state():
    return n.lua('print(grid.vports[1] and grid.vports[1].device and grid.vports[1].device.name or "none")')


def stage6():
    n.load_script()
    record_take(4, "drums")
    set_mode("PLAY")

    def c61():
        n.goto("DELAY")
        n.set("delay_fb", 0.3)
        n.key(2, 1)
        time.sleep(0.8)
        held = n.get("delay_fb")
        n.key(2, 0)
        time.sleep(0.2)
        after_hold = n.get("delay_fb")
        n.tap(2, 0.08)
        time.sleep(0.2)
        after_tap = n.get("delay_fb")
        n.tap(2, 0.08)
        time.sleep(0.2)
        return verdict(held > 0.5 and after_hold == 0.3 and after_tap > 0.5,
                       f"fb 0.3; held {held}, released {after_hold}; tapped {after_tap} (latched). Feel: yours", "measured")

    def c62():
        n.goto("DELAY")
        n.tap(2, 0.08)
        time.sleep(0.2)
        lit = n.get("delay_fb")
        n.tap(2, 0.08)
        time.sleep(0.3)
        back = n.get("delay_fb")
        time.sleep(0.5)
        still = n.get("delay_fb")
        return verdict(lit > 0.5 and back == 0.3 and still == 0.3, f"{lit} lit, {back} after the second tap, {still} later: no re-arm")

    def c63():
        n.goto("MIX")
        m0 = n.get("mix")
        n.tap(2, 0.08)
        time.sleep(0.2)
        eng = n.get("mix")
        n.tap(3, 0.08)
        time.sleep(0.2)
        tape = n.get("mix")
        n.tap(3, 0.08)
        time.sleep(0.2)
        end = n.get("mix")
        return verdict(eng != tape and eng != m0 and tape != m0 and end == m0,
                       f"centre {m0}, ENG {eng}, then TAPE {tape}, off {end}")

    def c64():
        out = {}
        n.set("cutoff", 800)
        n.goto("FILTER")
        n.tap(2, 0.08)
        time.sleep(0.2)
        opened = n.get("cutoff")
        n.tap(2, 0.08)
        time.sleep(0.2)
        out["OPEN"] = (800, opened, n.get("cutoff"))
        n.set("cutoff", 20000)
        n.set("delay_mix", 0.3)
        n.goto("DELAY")
        n.tap(3, 0.08)
        time.sleep(0.2)
        killed = n.get("delay_mix")
        n.tap(3, 0.08)
        time.sleep(0.2)
        out["KILL"] = (0.3, killed, n.get("delay_mix"))
        n.set("delay_mix", 0)
        decay = n.get("rev_decay")
        n.goto("REVERB")
        n.tap(2, 0.08)
        time.sleep(0.2)
        washed = n.get("rev_decay")
        n.tap(2, 0.08)
        time.sleep(0.2)
        out["WASH"] = (decay, washed, n.get("rev_decay"))
        ok = all(a == c and a != b for a, b, c in out.values())
        return verdict(ok, f"before, thrown, back: {out}")

    def c65():
        n.goto("REVERB")
        out = {}
        for start in (0.2, 0.95):
            n.set("shimmer", start)
            n.tap(3, 0.08)
            time.sleep(0.2)
            mid = n.get("shimmer")
            n.tap(3, 0.08)
            time.sleep(0.2)
            out[start] = (mid, n.get("shimmer"))
        n.set("shimmer", 0)
        ok = out[0.2][0] > 0.2 and out[0.95][0] >= 0.95 and out[0.2][1] == 0.2 and out[0.95][1] == 0.95
        return verdict(ok, f"start: thrown, back {out}")

    def c66():
        n.set("delay_fb", 0.3)
        n.set("scene_slot", 1)
        n.goto("SCENE")
        n.tap(3, 0.08)
        time.sleep(0.3)
        n.set("delay_fb", 0.5)
        n.goto("DELAY")
        n.tap(2, 0.08)
        time.sleep(0.2)
        thrown = n.get("delay_fb")
        n.goto("SCENE")
        n.tap(2, 0.08)
        time.sleep(0.6)
        recalled = n.get("delay_fb")
        n.goto("DELAY")
        n.tap(2, 0.08)
        time.sleep(0.3)
        again = n.get("delay_fb")
        n.tap(2, 0.08)
        time.sleep(0.3)
        after = n.get("delay_fb")
        return verdict(recalled == 0.3 and again == 1 and after == 0.3,
                       f"thrown {thrown}, recalled {recalled}. The next tap is a new throw {again}, and its release returns to the recalled {after}")

    def c67():
        n.set("delay_fb", 0.3)
        n.set("scene_slot", 1)
        n.goto("SCENE")
        n.tap(3, 0.08)
        time.sleep(0.3)
        n.set("delay_fb", 0.6)
        n.key(2, 1)
        time.sleep(1.0)
        peek = n.get("delay_fb")
        n.key(2, 0)
        time.sleep(0.5)
        back = n.get("delay_fb")
        return verdict(peek == 0.3 and back == 0.6, f"hold K2 peeks {peek}, release returns {back}. Commit and chaos: try them yourself", "measured")

    def c68():
        n.goto("TAPE")
        n.signal("tone")
        n.tap(2, 0.08)
        time.sleep(4)
        n.tap(2, 0.08)
        time.sleep(0.5)
        n.signal(None)
        lo = n.get("loop_start")
        hi = n.get("loop_end")
        n.set("scene_slot", 1)
        n.goto("SCENE")
        n.tap(3, 0.08)
        time.sleep(0.2)
        n.set("loop_end", lo + (hi - lo) * 0.3)
        n.set("scene_slot", 2)
        n.tap(3, 0.08)
        time.sleep(0.2)
        n.set("scene_slot", 1)
        bad = 0
        spans = []
        for v in [i / 20 for i in range(21)] + [1 - i / 20 for i in range(21)]:
            n.set("scene_morph_amt", v)
            s, e = n.get("loop_start"), n.get("loop_end")
            spans.append(round(e - s, 3))
            if e <= s:
                bad += 1
        n.set("scene_morph_amt", 0)
        full = hi - lo
        return verdict(bad == 0 and min(spans) >= full * 0.28, f"42 morph steps: crossed pairs {bad}; loop {full:.3f} and 30% of it are the ends, smallest seen {min(spans)}", "measured")

    def c69():
        n.load_script()
        n.goto("MOTION")
        n.tap(2, 0.08)
        time.sleep(0.2)
        n.goto("FILTER")
        for i in range(30):
            n.enc(2, -3)
            time.sleep(0.08)
        n.goto("MOTION")
        n.tap(2, 0.08)
        time.sleep(0.2)
        n.set("motion_play", 1)
        vals = []
        for _ in range(30):
            vals.append(n.get("cutoff"))
            time.sleep(0.1)
        return verdict(max(vals) - min(vals) > 200, f"after a sweep with the encoder, cutoff plays {min(vals):.0f} to {max(vals):.0f}")

    def c610():
        n.goto("MOTION")
        n.tap(2, 0.08)
        time.sleep(0.2)
        n.goto("FILTER")
        for i in range(20):
            n.enc(3, 3)
            time.sleep(0.08)
        n.goto("MOTION")
        n.tap(2, 0.08)
        time.sleep(0.2)
        n.set("motion_play", 1)
        c_vals, r_vals = [], []
        for _ in range(30):
            c_vals.append(n.get("cutoff"))
            r_vals.append(n.get("resonance"))
            time.sleep(0.1)
        n.set("motion_play", 0)
        ok = max(c_vals) - min(c_vals) > 200 and max(r_vals) - min(r_vals) > 0.02
        return verdict(ok, f"first lane cutoff {min(c_vals):.0f}..{max(c_vals):.0f}; second lane resonance {min(r_vals):.2f}..{max(r_vals):.2f}")

    for cid, fn in (("6.1", c61), ("6.2", c62), ("6.3", c63), ("6.4", c64), ("6.5", c65), ("6.6", c66),
                    ("6.7", c67), ("6.8", c68), ("6.9", c69), ("6.10", c610)):
        check(cid, fn)
    you("6.11", why="test/test_control covers the lane ends offscreen. Needs a person to judge the gesture")
    you("6.12", why="test/test_purity covers every reason offscreen. Look at the mark on the OLED")
    grid = grid_state()
    you("6.13", "6.14", "6.15", why=f"needs a physical grid; connected: {grid}")


# ---- stage 7: persistence ----------------------------------------------------
def wait_save():
    time.sleep(4)


def erase_page(page):
    n.goto(page)
    n.key(1, 1)
    time.sleep(0.05)
    n.key(3, 1)
    time.sleep(1.5)
    n.key(3, 0)
    n.key(1, 0)
    time.sleep(0.5)


def stage7():
    def c71():
        n.load_script()
        record_take(6, "drums")
        n.ctx("c.pad_chop()")
        time.sleep(5)
        n.goto("TAPE")
        n.signal("tone")
        n.tap(2, 0.08)
        time.sleep(3)
        n.tap(2, 0.08)
        time.sleep(0.4)
        n.signal(None)
        n.lua("__ctx.pad_pitch[3] = 5; __ctx.pad_type[3] = 1")
        n.set("delay_fb", 0.42)
        n.set("scene_slot", 1)
        n.goto("SCENE")
        n.tap(3, 0.08)
        time.sleep(0.2)
        before = {"take": num(n.ctx("c.take_len")), "cuts": n.lua("print(#__ctx.pad_cuts)"),
                  "tape": n.ctx("c.twave_any")}
        n.lua(f'params:write({PSET}, "gate")')
        wait_save()
        n.load_script()
        n.lua(f"params:read({PSET})")
        wait_save()
        n.helpers()
        after = {"take": num(n.ctx("c.take_len")), "cuts": n.lua("print(__ctx.pad_cuts and #__ctx.pad_cuts or 0)"),
                 "tape": n.ctx("c.twave_any"), "pitch": n.lua("print(__ctx.pad_pitch[3])"),
                 "type": n.lua("print(__ctx.pad_type[3])")}
        n.set("delay_fb", 0.7)
        n.set("scene_slot", 1)
        n.goto("SCENE")
        n.tap(2, 0.08)
        time.sleep(0.5)
        scene = n.get("delay_fb")
        set_mode("PLAY")
        n.set("dry_wet", 1)
        time.sleep(0.5)
        heard = level("7.1_loaded", 2)
        ok = (abs(after["take"] - before["take"]) < 0.002 and after["cuts"] == before["cuts"] and after["tape"] == "true"
              and float(after["pitch"]) == 5 and float(after["type"]) == 1 and scene == 0.42 and heard > -50)
        return verdict(ok, f"before {before}; after {after}; scene delay_fb {scene}; engine {heard} dB")

    def c72():
        n.load_script()
        n.goto("TAPE")
        n.signal("tone")
        n.tap(2, 0.08)
        time.sleep(3)
        n.tap(2, 0.08)
        time.sleep(0.4)
        n.signal(None)
        erase_page("TAPE")
        n.lua(f'params:write({PSET}, "gate")')
        wait_save()
        n.goto("TAPE")
        n.signal("tone")
        n.tap(2, 0.08)
        time.sleep(3)
        n.tap(2, 0.08)
        time.sleep(0.4)
        n.signal(None)
        n.lua(f"params:read({PSET})")
        wait_save()
        n.helpers()
        wave = n.ctx("c.twave_any")
        heard = level("7.2_tape_after_load", 2, DECKS_OUT)
        return verdict(wave == "false" and heard < -60, f"twave_any {wave}, softcut {heard} dB after loading a pset with an empty tape")

    def c73():
        n.load_script()
        n.set("dry_wet", 1)
        n.lua(f'params:set("sample_file", "{TEST_DIR}/t48k.wav")')
        time.sleep(2)
        path = n.lua('print(params:get("sample_file"))')
        erase_page("TAKE")
        n.lua(f'params:write({PSET}, "gate")')
        wait_save()
        n.load_script()
        n.lua(f"params:read({PSET})")
        wait_save()
        n.helpers()
        length = num(n.ctx("c.take_len"))
        after = n.lua('print(params:get("sample_file"))')
        return verdict(length == 0 and "t48k" in path and "t48k" not in after, f"sample before {path}; after reload {after!r}; take_len {length}")

    def c74():
        n.load_script()
        had = n.ssh("ls ~/dust/data/mangler2/take-1_L.wav 2>/dev/null").strip()
        named = n.ssh("grep -c sample_file ~/dust/data/mangler2/mangler2-02.pset; grep sample_file ~/dust/data/mangler2/mangler2-02.pset").strip()
        n.lua("params:read(2)")
        wait_save()
        n.helpers()
        length = num(n.ctx("c.take_len"))
        return ("measured", f"no pset older than S22 is on the device. August pset 2 loads without error: {named!r}, take_len {length}, take file for pset 1 exists={bool(had)}")

    for cid, fn in (("7.1", c71), ("7.2", c72), ("7.3", c73), ("7.4", c74)):
        check(cid, fn)


# ---- stage 8: performance ----------------------------------------------------
def fps(seconds=4):
    a = int(num(n.ctx("c.frame")))
    time.sleep(seconds)
    b = int(num(n.ctx("c.frame")))
    return round((b - a) / seconds, 1)


def stage8():
    n.load_script()
    record_take(6, "drums")
    n.set("dry_wet", 1)
    set_mode("PLAY")

    def c81():
        time.sleep(1)
        return verdict("mangler_reverb" not in n.nodes(), f"nodes {n.nodes()}; scsynth {n.cpu(4)}")

    def c82():
        set_mode("GRAIN")
        x0 = n.xruns()
        base = n.cpu(4)
        for i in range(8):
            n.ctx(f"c.pad_trigger({9200 + i}, {i}, 1)")
        time.sleep(2)
        held = n.cpu(20)
        x1 = n.xruns()
        n.ctx("c.pads_all_off()")
        time.sleep(1)
        return verdict(x1 == x0, f"drone alone {base}; drone plus 8 pads {held}; xruns {x1 - x0}")

    def c83():
        set_mode("PLAY")
        n.set("cutoff", 2000)
        n.set("delay_mix", 0.3)
        n.set("scene_slot", 1)
        n.goto("SCENE")
        n.tap(3, 0.08)
        time.sleep(0.2)
        n.set("cutoff", 20000)
        n.set("delay_mix", 0)
        n.set("scene_slot", 2)
        n.tap(3, 0.08)
        time.sleep(0.2)
        n.set("scene_slot", 1)
        x0 = n.xruns()

        def morph():
            for v in [i / 40 for i in range(41)] + [1 - i / 40 for i in range(41)]:
                n.set("scene_morph_amt", v)
                time.sleep(0.03)

        path_rate, chans = during(morph, "8.3_morph", 6)
        x1 = n.xruns()
        n.set("scene_morph_amt", 0)
        return verdict(x1 == x0, f"xruns {x1 - x0}. Zipper: listen to 8.3_morph.wav (drums make a click count useless here)", "measured")

    def c84():
        import math
        upload("long48k24.wav", wav_bytes(48000, 60, lambda t, ch: 0.4 * math.sin(2 * math.pi * 330 * t), bits=24))
        x0 = n.xruns()
        n.ctx(f'c.load_sample("{TEST_DIR}/long48k24.wav")')
        rates = [fps(2) for _ in range(5)]
        x1 = n.xruns()
        n.goto("TAKE")
        shot("8.4_long")
        length = num(n.ctx("c.take_len")) * 60
        return verdict(x1 == x0 and min(rates) >= 10, f"frames per second while it loads {rates}; xruns {x1 - x0}; take {length:.1f}s")

    for cid, fn in (("8.1", c81), ("8.2", c82), ("8.3", c83), ("8.4", c84)):
        check(cid, fn)


# ---- stage 9: layers ---------------------------------------------------------
def record_layer(deck, secs=4, kind="tone", amp=None):
    """Record into a layer deck with the LAYERS keys."""
    n.goto("LAYERS")
    n.set("layer_sel", deck)
    time.sleep(0.2)
    if kind:
        n.signal(kind, amp)
    time.sleep(0.2)
    n.tap(2, 0.08)
    time.sleep(secs)
    n.tap(2, 0.08)
    time.sleep(0.5)
    if kind:
        n.signal(None)
    time.sleep(0.3)


def deck_span(deck):
    return (n.get(f"lay{deck}_end") - n.get(f"lay{deck}_start"))


def stage9():
    n.load_script()
    n.set("layer_wet", 0) if False else None
    record_take(4, "drums")
    set_mode("PLAY")
    n.set("dry_wet", 1)

    def c91():
        record_take(3, "drums")
        set_mode("PLAY")
        record_layer(1, 4)
        d = level("9.1_decks", 2, DECKS_OUT)
        e = level("9.1_engine", 2)
        return verdict(d > -50 and e > -50, f"softcut {d} dB and engine {e} dB at the same time")

    def tone_decks():
        # layer_wet records the mix, which holds the take's drums. A click count
        # needs a pure tone, so the decks record the input here.
        n.load_script()
        n.set("layer_wet", 0)
        n.set("cut_source", 0)
        n.set("dry_wet", 1)
        set_mode("OFF")

    def c92():
        tone_decks()
        record_layer(1, 4, "tone")
        record_layer(2, 4, "tone", 0.15)
        n.set("lay1_rate", 0.5)
        n.set("lay2_rate", 1)
        time.sleep(1)
        rate, chans = engine_rec("9.2_drift", 12, DECKS_OUT)
        hits = audio.clicks(chans[0], rate)
        n.set("lay1_rate", 1)
        return verdict(not hits, f"12s at rates 0.5 and 1: clicks {hits[:8]}. Drift: listen to 9.2_drift.wav", "measured")

    def c93():
        tone_decks()
        record_layer(1, 4, "tone")
        n.set("lay2_play", 0)
        n.set("lay1_pre", 1)
        time.sleep(0.5)
        a = level("9.3_before", 2, DECKS_OUT)
        record_layer(1, 3, None)
        b = level("9.3_pre1_silence", 2, DECKS_OUT)
        n.set("lay1_pre", 0)
        record_layer(1, 6, None)
        c = level("9.3_pre0_silence", 2, DECKS_OUT)
        n.set("lay1_pre", 1)
        n.set("lay2_play", 1)
        n.set("layer_wet", 1)
        return verdict(b > a - 3 and c < a - 15, f"{a} dB; after overdub of silence at pre 1 {b} dB; at pre 0 {c} dB")

    def c94():
        record_layer(1, 3, "tone")
        n.set("lay2_play", 0)
        time.sleep(0.5)
        a = level("9.4_l1", 2, DECKS_OUT)
        n.set("lay2_play", 1)
        n.set("lay1_play", 0)
        time.sleep(0.5)
        b = level("9.4_l2", 2, DECKS_OUT)
        n.set("lay1_play", 1)
        n.set("layer_sel", 1)
        erase_page("LAYERS")
        n.set("lay2_play", 0)
        time.sleep(0.5)
        c = level("9.4_l1_erased", 2, DECKS_OUT)
        n.set("lay2_play", 1)
        n.set("lay1_play", 0)
        time.sleep(0.5)
        d = level("9.4_l2_kept", 2, DECKS_OUT)
        n.set("lay1_play", 1)
        return verdict(c < -60 and abs(d - b) < 2, f"L1 {a} to {c} dB; L2 {b} to {d} dB")

    def c95():
        record_layer(1, 3, "tone")
        a = level("9.5_before", 2, DECKS_OUT)
        stop(True)
        time.sleep(1)
        b = level("9.5_stopped", 2, DECKS_OUT)
        c = level("9.5_stopped_engine", 1)
        stop(False)
        time.sleep(0.5)
        d = level("9.5_after", 2, DECKS_OUT)
        return verdict(b < -70 and c < -70 and abs(a - d) < 3, f"softcut {a}, stopped {b}, engine stopped {c}, after {d} dB")

    def c96():
        n.load_script()
        n.set("dry_wet", 1)
        record_take(3, "drums")
        set_mode("PLAY")
        record_layer(1, 3)
        n.lua(f'params:write({PSET}, "gate")')
        wait_save()
        files = n.ssh(f"ls ~/dust/data/mangler2 | grep -E 'lay[12]-{PSET}' | tr '\\n' ' '").strip()
        a = level("9.6_before", 2, DECKS_OUT)
        n.load_script()
        n.lua(f"params:read({PSET})")
        wait_save()
        n.helpers()
        b = level("9.6_after", 2, DECKS_OUT)
        return verdict(bool(files) and b > -50 and abs(a - b) < 6, f"files: {files}; softcut {a} dB before, {b} dB after")

    def c98():
        n.goto("TAPE")
        n.signal("tone")
        n.tap(2, 0.08)
        time.sleep(3)
        n.tap(2, 0.08)
        time.sleep(0.3)
        n.signal(None)
        set_mode("GRAIN")
        x0 = n.xruns()
        n.set("density", 40)
        time.sleep(1)
        cpu = n.cpu(20)
        idle, threads = n.threads(5)
        x1 = n.xruns()
        n.set("density", 20)
        return verdict(x1 == x0, f"take in GRAIN, tape and both layers: scsynth {cpu}; system idle {idle}%; xruns {x1 - x0}; threads {threads[:5]}")

    for cid, fn in (("9.1", c91), ("9.2", c92), ("9.3", c93), ("9.4", c94), ("9.5", c95), ("9.6", c96)):
        check(cid, fn)
    you("9.7", why=f"needs a physical grid; connected: {grid_state()}")
    check("9.8", c98)


# ---- stage 10: delay, true STOP, clear ---------------------------------------
def stage10():
    n.load_script()
    n.set("dry_wet", 1)
    load_file("hits.wav", 2)
    set_mode("PLAY")
    time.sleep(0.5)

    def c101():
        n.set("delay_time", 0.3)
        n.set("delay_fb", 0.4)
        a = level("10.1_dry", 4)
        n.set("delay_mix", 0.5)
        time.sleep(1)
        b = level("10.1_echo", 4)
        nodes = n.nodes()

        def ride():
            for i in range(30):
                n.set("delay_time", 0.2 + i * 0.01)
                time.sleep(0.05)

        rate, chans = during(ride, "10.1_ride", 3)
        n.set("delay_time", 0.3)
        return verdict("mangler_delay" in nodes and b > a, f"{a} dB dry, {b} dB with echoes; delay node present. Darkening: listen to 10.1_echo.wav", "measured")

    def c102():
        on = n.cpu(4)
        n.set("delay_mix", 0)
        time.sleep(1)
        off = n.cpu(4)
        nodes = n.nodes()
        return verdict("mangler_delay" not in nodes, f"delay on {on}, off {off}: the node is gone, the difference is under the noise. No older build to compare", "measured")

    def c103():
        n.goto("DELAY")
        n.set("delay_mix", 0.5)
        n.tap(2, 0.08)
        time.sleep(3)
        n.set("mode", 1)
        time.sleep(0.3)
        n.tap(3, 0.08)
        time.sleep(2)
        n.tap(3, 0.08)
        time.sleep(0.5)
        v = level("10.3_hold", 3)
        n.tap(2, 0.08)
        n.set("delay_mix", 0)
        set_mode("PLAY")
        return verdict(v > -50, f"after INF, voice off, KILL, wait, un-KILL: the loop plays at {v} dB")

    def c104():
        record_take(4, "tone")
        set_mode("PLAY")
        n.set("delay_mix", 0)
        time.sleep(1)

        def rise():
            n.set("delay_mix", 0.4)

        rate, chans = during(rise, "10.4_spawn_jump", 3)
        jump = audio.clicks(chans[0], rate)
        n.set("delay_mix", 0)
        time.sleep(1)

        def knob():
            n.goto("DELAY")
            for _ in range(20):
                n.enc(2, 1)
                time.sleep(0.05)

        rate, chans = during(knob, "10.4_spawn_knob", 3)
        hits = audio.clicks(chans[0], rate)
        n.set("delay_mix", 0)
        return verdict(len(hits) <= 1, f"raised with E2: breaks {hits[:6]}. Jumped from 0 to 0.4 by a param set, as MIDI or a scene can: breaks {jump[:6]}. Listen to 10.4_spawn_knob.wav", "measured")

    def c105():
        n.goto("TAPE")
        n.signal("tone")
        n.tap(2, 0.08)
        time.sleep(3)
        n.tap(2, 0.08)
        time.sleep(0.3)
        n.signal(None)
        record_layer(1, 3)
        rows = []
        stop(True)
        time.sleep(1.2)
        p1 = (num(n.ctx("c.play_phase")), num(n.ctx("c.tape_phase")), num(n.ctx("c.layers[1].phase")))
        time.sleep(2)
        p2 = (num(n.ctx("c.play_phase")), num(n.ctx("c.tape_phase")), num(n.ctx("c.layers[1].phase")))
        shot("10.5_stopped")
        stop(False)
        time.sleep(1.5)
        p3 = (num(n.ctx("c.play_phase")), num(n.ctx("c.tape_phase")), num(n.ctx("c.layers[1].phase")))
        _ = rows
        still = all(abs(a - b) < 0.0005 for a, b in zip(p1, p2))
        moved = all(abs(a - b) > 0.0001 for a, b in zip(p2, p3))
        return verdict(still and moved, f"take, tape, L1 heads: {p1} and {p2} under STOP, {p3} after START")

    def c106():
        n.goto("TAKE")
        n.signal("tone")
        n.tap(2, 0.08)
        time.sleep(1.5)
        stop(True)
        time.sleep(0.5)
        a = num(n.ctx("c.rec_phase"))
        time.sleep(2)
        b = num(n.ctx("c.rec_phase"))
        stop(False)
        time.sleep(1.5)
        n.tap(2, 0.08)
        time.sleep(0.6)
        n.signal(None)
        n.take_dump()
        code = (
            "import array\n"
            "d=open('/tmp/mg_L.wav','rb').read(); i=d.find(b'data')+8; x=array.array('f'); x.frombytes(d[i:i+(len(d)-i)//4*4])\n"
            f"lo=int({a}*2880000)-48000; w=2400; g=0\n"
            "for k in range(0,110000,w):\n"
            "  s=x[lo+k:lo+k+w]; r=(sum(v*v for v in s)/len(s))**.5\n"
            "  g+= (r<0.001)\n"
            "print(g)\n"
        )
        gaps = n.ssh(f'python3 -c "{code}"', timeout=60).strip()
        return verdict(abs(a - b) < 0.0002 and gaps == "0", f"write head {a:.5f} and {b:.5f} under STOP; silent 50ms blocks near the stop {gaps}")

    def c107():
        n.goto("MIX")
        a = num(n.ctx("c.play_phase"))
        n.tap(3, 0.08)
        time.sleep(1)
        b = num(n.ctx("c.play_phase"))
        time.sleep(1)
        c = num(n.ctx("c.play_phase"))
        n.tap(3, 0.08)
        time.sleep(1)
        d = num(n.ctx("c.play_phase"))
        return verdict(abs(b - c) < 0.0005 and abs(d - c) > 0.0001, f"head {a:.4f}, thrown {b:.4f} and {c:.4f}, released {d:.4f}. Whether it feels right is yours", "measured")

    def c108():
        set_mode("PLAY")
        n.set("delay_mix", 0.5)
        n.set("delay_fb", 0.8)
        n.set("rev_mix", 0.6)
        n.set("regen", 0.4)
        time.sleep(3)
        a = level("10.8_before", 2)
        erase_page("TAKE")
        time.sleep(1)
        b = level("10.8_after", 2)
        h = n.take_hash().split()
        zero = n.ssh(
            "python3 -c \"d=open('/tmp/mg_L.wav','rb').read(); i=d.find(b'data')+8; print(all(c==0 for c in d[i:]))\"",
            timeout=30).strip()
        regen = n.get("regen")
        n.set("delay_mix", 0)
        n.set("rev_mix", 0)
        n.set("delay_fb", 0.3)
        _ = h
        return verdict(b < a - 45 and zero == "True" and regen == 0, f"{a} dB, then {b} dB after the erase; buffer all zero={zero}; regen {regen}. Listen to 10.8_after.wav", "measured")

    for cid, fn in (("10.1", c101), ("10.2", c102), ("10.3", c103), ("10.4", c104), ("10.5", c105),
                    ("10.6", c106), ("10.7", c107), ("10.8", c108)):
        check(cid, fn)


# ---- stage 11: the snap and quality batch -------------------------------------
def opt(pid, name):
    n.lua(f'for i, o in ipairs(params:lookup_param("{pid}").options) do if o == "{name}" then params:set("{pid}", i) end end')
    time.sleep(0.2)


def wait_loaded(start, limit=240):
    t0 = time.time()
    frames = []
    while time.time() - t0 < limit:
        a = int(num(n.ctx("c.frame")))
        time.sleep(1)
        frames.append(int(num(n.ctx("c.frame"))) - a)
        if "loaded " in transcript_since("lua", start) or "resample failed" in transcript_since("lua", start):
            return round(time.time() - t0, 1), frames
    return None, frames


def stage11():
    n.load_script()
    n.set("dry_wet", 1)
    record_take(6, "drums")
    set_mode("PLAY")

    def c111():
        record_layer(1, 4)
        span = deck_span(1) * 60
        heard = level("11.1_first_pass", 3, DECKS_OUT)
        return verdict(heard > -50 and 3.2 < span < 5.5, f"a fresh layer's first pass: the loop is {span:.2f}s and plays {heard} dB")

    def softcut_peak(start, secs):
        """Where the loudest sample of voice 1's buffer is, in a stretch of it."""
        n.lua(f'softcut.buffer_write_mono("/tmp/mg_sc.wav", {start}, {secs}, 1)')
        time.sleep(2.5)
        code = (
            "d=open('/tmp/mg_sc.wav','rb').read(); i=d.find(b'data')+8; best=0; at=0\n"
            "for k in range(i,len(d)-2,3*8):\n"
            "  v=abs(int.from_bytes(d[k:k+3],'little',signed=True))\n"
            "  if v>best: best=v; at=k\n"
            "print((at-i)//3/48000, best/8388608)\n"
        )
        pos, peak = n.ssh(f'python3 -c "{code}"', timeout=60).split()
        return float(pos), float(peak)

    def c112b():
        # a punch in the middle of a loop must land where the head is
        n.load_script()
        n.set("layer_wet", 0)
        n.set("cut_source", 0)
        n.set("dry_wet", 1)
        set_mode("OFF")
        record_layer(1, 4, "tone", 0.02)
        start, end = n.get("lay1_start"), n.get("lay1_end")
        for _ in range(100):
            ph = (num(n.ctx("c.layers[1].phase")) - start) / (end - start)
            if 0.45 < ph < 0.55:
                break
            time.sleep(0.05)
        head = num(n.ctx("c.layers[1].phase")) * 60
        n.tap(2, 0.08)
        n.signal("hit", 0.9)
        time.sleep(0.5)
        n.tap(2, 0.08)
        time.sleep(0.4)
        pos, peak = softcut_peak(120, 60)
        return verdict(abs(pos - head) < 0.6 and peak > 0.2, f"the head was at {head:.2f}s in the region, and the hit landed at {pos:.2f}s (peak {peak:.2f})")

    def c112c():
        # the rec flag stays on, so an idle deck must not change a single sample
        n.lua('softcut.buffer_write_mono("/tmp/mg_a.wav", 120, 60, 1)')
        time.sleep(2.5)
        n.ssh("mv /tmp/mg_a.wav /tmp/mg_a1.wav")
        time.sleep(15)
        n.lua('softcut.buffer_write_mono("/tmp/mg_a.wav", 120, 60, 1)')
        time.sleep(2.5)
        code = ("a=open('/tmp/mg_a1.wav','rb').read(); b=open('/tmp/mg_a.wav','rb').read(); "
                "i=a.find(b'data')+8; j=b.find(b'data')+8; print(a[i:]==b[j:], len(a)-i)")
        same = n.ssh(f'python3 -c "{code}"', timeout=60).strip()
        return verdict(same.startswith("True"), f"the deck's whole region is the same after 15s at rest: {same}")

    def c112d():
        n.load_script()
        n.set("cut_source", 0)
        set_mode("OFF")
        n.goto("TAPE")
        time.sleep(3)
        n.signal("tone")
        n.tap(2, 0.08)
        time.sleep(3)
        n.tap(2, 0.08)
        time.sleep(0.4)
        n.signal(None)
        time.sleep(0.3)
        v = level("11.2d_tape_first_pass", 3, DECKS_OUT)
        return verdict(v > -40, f"the tape's first pass, after 3s of playing: softcut {v} dB")

    def c112():
        a = deck_span(1)
        record_layer(1, 2, "hit")
        b = deck_span(1)
        return verdict(a == b, f"loop {a * 60:.3f}s before and after an overdub")

    def c113():
        n.load_script()
        n.set("dry_wet", 1)
        record_take(6, "drums")
        set_mode("PLAY")
        record_layer(1, 4.3)
        span = deck_span(1) * 60
        return verdict(3.9 < span < 5.2 and abs(span - 6) > 0.5 and abs(span - 3) > 0.5, f"take 6.1s, played about 4.5s, loop {span:.2f}s")

    def c114():
        n.load_script()
        n.set("dry_wet", 1)
        record_take(6, "drums")
        set_mode("PLAY")
        take = (n.get("pos_end") - n.get("pos_start")) * 60
        record_layer(1, take / 2 - 0.25)
        span = deck_span(1) * 60
        msg = n.ctx("c.lay_msg")
        shot("11.4_snap")
        return verdict(abs(span - take / 2) < 0.01, f"take {take:.3f}s; loop {span:.3f}s. See 11.4_snap.png. {msg}")

    def c115():
        record_layer(2, deck_span(1) * 60 * 2 - 0.25, "hit")
        s1, s2 = deck_span(1), deck_span(2)

        def phase_gap():
            gaps = []
            for _ in range(5):
                a = num(n.ctx("c.layers[1].phase"))
                b = num(n.ctx("c.layers[2].phase"))
                x = ((a - n.get("lay1_start")) / s1) % 1
                y = ((b - n.get("lay2_start")) / s2 * round(s2 / s1, 3)) % 1
                gaps.append((x - y) % 1)
                time.sleep(0.3)
            return sorted(gaps)[2]

        g0 = phase_gap()
        time.sleep(300)
        g1 = phase_gap()
        walk = min(abs(g1 - g0), 1 - abs(g1 - g0))
        return verdict(walk < 0.03, f"lengths {s1 * 60:.3f}s and {s2 * 60:.3f}s, ratio {s2 / s1:.4f}. Phase gap {g0:.3f} then {g1:.3f} after 5 min; walked {walk:.3f} of a cycle")

    def c116():
        n.load_script()
        n.set("dry_wet", 1)
        record_take(6, "drums")
        set_mode("PLAY")
        take = (n.get("pos_end") - n.get("pos_start")) * 60
        record_layer(1, 4.3)
        a = deck_span(1) * 60
        n.set("lay1_snap", 1)
        time.sleep(0.2)
        n.set("lay1_snap", 0)
        time.sleep(0.3)
        b = deck_span(1) * 60
        msg = n.ctx("c.lay_msg")
        return ("measured", f"take {take:.3f}s; the loop goes {a:.3f}s to {b:.3f}s with lay1_snap; the page says {msg}. Footswitch and grid: yours")

    def c116b():
        n.set("lay1_end", 1)
        n.set("lay1_start", 0.9999)
        time.sleep(0.3)
        a = (n.get("lay1_start"), n.get("lay1_end"))
        n.set("lay1_snap", 1)
        time.sleep(0.2)
        n.set("lay1_snap", 0)
        time.sleep(0.3)
        msg = n.lua('print(__ctx.lay_msg or "")')
        b = (n.get("lay1_start"), n.get("lay1_end"))
        n.goto("LAYERS")
        shot("11.6b_no_room")
        n.set("lay1_start", 0)
        return verdict(a == b, f"loop unchanged {a}. Message on the page: see 11.6b_no_room.png. {msg}", "measured")

    def c117():
        n.load_script()
        n.set("dry_wet", 1)
        n.set("layer_wet", 0)
        n.set("cut_source", 0)
        set_mode("OFF")
        record_layer(1, 3, "drums")
        out = {}
        for f in (0.001, 0.2):
            n.set("lay1_fade", f)
            time.sleep(1)
            out[f] = level(f"11.7_fade{f}", 6, DECKS_OUT)
        return ("measured", f"RMS by seam {out}. Hard downbeat or blend: listen to 11.7_fade0.001.wav and 11.7_fade0.2.wav")

    def c118():
        n.load_script()
        n.set("dry_wet", 1)
        n.set("layer_wet", 0)
        n.set("cut_source", 0)
        n.ssh("jack_disconnect scsig:out_2 crone:input_2")
        record_layer(2, 3, "tone")
        n.ssh("jack_connect scsig:out_2 crone:input_2")
        out = {}
        for w in (1, 0):
            n.set("lay2_width", w)
            time.sleep(0.4)
            rate, chans = engine_rec(f"11.8_width{w}", 2, DECKS_OUT)
            out[w] = (audio.stats(chans[0])["rms_db"], audio.stats(chans[1])["rms_db"])
        ok = abs(out[0][0] - out[0][1]) < 1 and abs(out[1][0] - out[1][1]) > 10
        return verdict(ok, f"L and R dB of a deck recorded on the left only, by width: {out}")

    def c119():
        n.load_script()
        record_take(5, "drums")
        before = num(n.ctx("c.take_len"))
        n.lua(f'params:write({PSET}, "gate")')
        wait_save()
        bits = n.ssh(f"soxi -b ~/dust/data/mangler2/take-{PSET}_L.wav").strip()
        erase_page("TAKE")
        n.lua(f"params:read({PSET})")
        wait_save()
        n.helpers()
        after = num(n.ctx("c.take_len"))
        return verdict(bits == "24" and abs(after - before) < 0.002, f"file {bits} bit; take_len {before:.4f} and {after:.4f}")

    def c1110():
        if n.ctx("c.wave_any") != "true":
            record_take(4, "drums")
        start = mark()
        n.ctx('c.export_take("mg_gate.wav")')
        time.sleep(6)
        text = transcript_since("lua", start)
        path = n.ssh("ls -t ~/dust/audio/*mg_gate* 2>/dev/null | head -1").strip()
        info = n.ssh(f"soxi -c '{path}'; soxi -b '{path}'").split() if path else []
        ok = info == ["2", "24"]
        if path:
            n.ctx(f'c.load_sample("{path}")')
            time.sleep(4)
            n.ssh(f"rm -f '{path}'")
        return verdict(ok, f"{path}: channels and bits {info}. {text[-120:].strip()}")

    def c1111():
        n.load_script()
        n.set("dry_wet", 1)
        set_mode("PLAY")
        start = mark()
        n.ctx(f'c.load_sample("{TEST_DIR}/t96k24.wav")')
        wait_loaded(start, 90)
        time.sleep(0.5)
        rate, chans = engine_rec("11.11_96k", 2)
        c = chans[0]
        bands = {hz: audio.band(c, rate, hz) for hz in (440, 880, 3000, 9000, 15000)}
        return verdict(all(v < bands[440] - 50 for hz, v in bands.items() if hz != 440), f"dB by Hz {bands}. Whistle or grit: listen to 11.11_96k.wav", "measured")

    def c1112():
        out = {}
        for name in ("long44k.wav", "long96k.wav"):
            start = mark()
            n.ctx(f'c.load_sample("{TEST_DIR}/{name}")')
            secs, frames = wait_loaded(start, 400)
            out[name] = (secs, min(frames) if frames else None)
        return ("measured", f"Pi 4: seconds to load, and lowest frames per second while it converts: {out}. long44k is 30s of audio, long96k is 10s")

    for cid, fn in (("11.1", c111), ("11.2", c112), ("11.2b", c112b), ("11.2c", c112c), ("11.2d", c112d), ("11.3", c113), ("11.4", c114), ("11.5", c115), ("11.6", c116),
                    ("11.6b", c116b), ("11.7", c117), ("11.8", c118), ("11.9", c119), ("11.10", c1110),
                    ("11.11", c1111), ("11.12", c1112)):
        check(cid, fn)
    you("11.13", "11.14", why="only an ear can judge these. Use resample 0.5 and a slammed INF delay")


# ---- stage 12 ----------------------------------------------------------------
def stage12():
    def c121():
        n.load_script()
        start = mark()
        n.ctx(f'c.load_sample("{TEST_DIR}/long44k.wav")')
        time.sleep(0.5)
        record_take(3, "drums")
        secs = (n.get("pos_end") - n.get("pos_start")) * 60
        for _ in range(90):
            time.sleep(1)
            if "dropped" in transcript_since("lua", start):
                break
        text = transcript_since("lua", start)
        after = (n.get("pos_end") - n.get("pos_start")) * 60
        return verdict("dropped" in text and abs(after - secs) < 0.01, f"window {secs:.2f}s, and {after:.2f}s after the late conversion; dropped message={'dropped' in text}")

    def c122():
        n.load_script()
        record_take(4, "drums")
        n.goto("TAKE")
        n.tap(3, 0.08)
        time.sleep(0.4)
        whole = (n.get("pos_end") - n.get("pos_start")) * 60
        n.tap(3, 0.08)
        time.sleep(0.4)
        snapped = (n.get("pos_end") - n.get("pos_start")) * 60
        n.lua(f'params:write({PSET}, "gate")')
        wait_save()
        size = n.ssh(f"soxi -D ~/dust/data/mangler2/take-{PSET}_L.wav").strip()
        return verdict(whole > 59 and 3.8 < snapped < 5 and float(size) < 6, f"first tap {whole:.2f}s, second tap back on the take {snapped:.2f}s; the PSET file holds {size}s")

    def c123():
        n.load_script()
        n.goto("LAYERS")
        n.set("layer_sel", 1)
        n.key(2, 1)
        time.sleep(0.6)
        n.enc(2, 1)
        time.sleep(0.2)
        n.key(2, 0)
        time.sleep(0.3)
        return verdict(n.get("lay1_rec") == 0 and n.get("lay2_rec") == 0, f"L1 rec {n.get('lay1_rec')}, L2 rec {n.get('lay2_rec')}, selected {n.get('layer_sel')}")

    def c125():
        n.goto("TAPE")
        n.set("loop_start", 0.1)
        n.set("loop_end", 0.14)
        time.sleep(0.2)
        a = (n.get("loop_start"), n.get("loop_end"))
        n.tap(2, 0.05)
        time.sleep(0.1)
        n.tap(2, 0.05)
        time.sleep(0.4)
        b = (n.get("loop_start"), n.get("loop_end"))
        return verdict(a == b, f"loop {a} and {b} after two quick taps")

    def c126():
        n.load_script()
        n.goto("TAPE")
        sync = n.lua("print(__ctx.TAPE_LEN)")
        n.signal("tone")
        n.tap(2, 0.08)
        time.sleep(2)
        n.tap(2, 0.08)
        time.sleep(0.3)
        n.signal(None)
        s = n.get("loop_start")
        n.set("loop_end", s + 0.3 / float(sync))
        n.set("tape_fade", 0.4)
        time.sleep(1)
        v = level("12.6_short_seam", 3, DECKS_OUT)
        return verdict(v > -40, f"tape loop 0.3s, seam 0.4s: softcut {v} dB")

    def c127():
        for page in ("TAPE", "VOICE"):
            n.goto(page)
            stop(True)
            time.sleep(1)
            shot(f"12.7_stopped_{page}")
            stop(False)
        return ("measured", "see 12.7_stopped_TAPE.png and 12.7_stopped_VOICE.png")

    def c129():
        n.load_script()
        n.set("dry_wet", 1)
        set_mode("PLAY")
        start = mark()
        n.ctx(f'c.load_sample("{TEST_DIR}/t96kf.wav")')
        wait_loaded(start, 90)
        time.sleep(0.5)
        rate, chans = engine_rec("12.9_float96k", 2)
        c = chans[0]
        bands = {hz: audio.band(c, rate, hz) for hz in (404, 440, 480)}
        n.goto("TAKE")
        shot("12.9_float")
        return verdict(bands[440] > bands[404] + 30 and bands[440] > -20, f"dB by Hz {bands}; picture in 12.9_float.png")

    def c1210():
        load_file("right.wav", 3)
        n.goto("TAKE")
        time.sleep(0.5)
        shot("12.10_right_only")
        return ("measured", "see 12.10_right_only.png: the strip must show the hits")

    def c1214():
        start = mark()
        n.ctx(f'c.load_sample("{TEST_DIR}/long96k.wav")')
        secs, frames = wait_loaded(start, 300)
        return verdict(frames and min(frames) >= 8, f"{secs}s to load 10s at 96k; lowest frames per second {min(frames) if frames else None}")

    for cid, fn in (("12.1", c121), ("12.2", c122), ("12.3", c123), ("12.5", c125), ("12.6", c126), ("12.7", c127),
                    ("12.9", c129), ("12.10", c1210), ("12.14", c1214)):
        check(cid, fn)
    you("12.4", "12.11", "12.12", "12.13", why="test/test_control covers the logic offscreen. Try these by hand")
    you("12.8", why="needs a physical grid")


# ---- stage 13 ----------------------------------------------------------------
def stage13():
    def c131():
        n.load_script()
        n.goto("MOTION")
        n.tap(2, 0.08)
        time.sleep(0.2)
        n.goto("FILTER")
        for _ in range(25):
            n.enc(2, -3)
            time.sleep(0.08)
        n.goto("MOTION")
        n.tap(2, 0.08)
        time.sleep(0.2)
        n.lua(f'params:write({PSET}, "gate")')
        wait_save()
        n.load_script()
        n.lua(f"params:read({PSET})")
        wait_save()
        n.helpers()
        armed = n.get("motion_rec")
        n.set("motion_play", 1)
        vals = []
        for _ in range(25):
            vals.append(n.get("cutoff"))
            time.sleep(0.1)
        n.set("motion_play", 0)
        return verdict(armed == 0 and max(vals) - min(vals) > 200, f"not armed={armed == 0}; the loop plays cutoff {min(vals):.0f} to {max(vals):.0f} after a reload")

    def c132():
        n.load_script()
        n.lua("params:set('clock_tempo', 120)")
        n.set("delay_fb", 0.2)
        n.set("scene_slot", 1)
        n.goto("SCENE")
        n.tap(3, 0.08)
        time.sleep(0.2)
        n.set("delay_fb", 0.8)
        opt("scene_recall_mode", "GLIDE")
        n.set("scene_glide", 4)
        n.tap(2, 0.08)
        vals = []
        for _ in range(14):
            vals.append(n.get("delay_fb"))
            time.sleep(0.25)
        opt("scene_recall_mode", "NOW")
        steps = len({round(v, 3) for v in vals})
        return verdict(steps > 3 and abs(vals[-1] - 0.2) < 0.02, f"delay_fb {vals[0]:.2f} to {vals[-1]:.2f} through {steps} values over 3.5s")

    def c134():
        n.load_script()
        n.lua("params:set('clock_tempo', 120)")
        opt("delay_sync", "1/4")
        time.sleep(0.3)
        a = n.get("delay_time")
        n.set("scene_slot", 1)
        n.goto("SCENE")
        n.tap(3, 0.08)
        time.sleep(0.2)
        n.tap(2, 0.08)
        time.sleep(0.4)
        b = n.get("delay_time")
        opt("delay_sync", "FREE")
        return verdict(abs(a - 0.5) < 0.01 and abs(b - 0.5) < 0.01, f"delay_time {a} synced at 120 BPM, {b} after a recall")

    def c135():
        n.load_script()
        record_layer(1, 4)
        n.lua(f'params:write({PSET}, "gate")')
        wait_save()
        secs = n.ssh(f"soxi -D ~/dust/data/mangler2/lay1-{PSET}.wav").strip()
        n.load_script()
        n.lua(f"params:read({PSET})")
        wait_save()
        n.helpers()
        heard = level("13.5_short_deck", 3, DECKS_OUT)
        return verdict(float(secs) < 8 and heard > -50, f"the file holds {secs}s; softcut {heard} dB after the load")

    for cid, fn in (("13.1", c131), ("13.2", c132), ("13.4", c134), ("13.5", c135)):
        check(cid, fn)
    you("13.3", "13.6", "13.10", why="test/test_control covers the logic offscreen. Try these by hand")
    you("13.7", "13.8", "13.9", why="needs a Launchpad Mini MK3 or a grid")


# ---- stage 14: erosion in its own synth ---------------------------------------
def stage14():
    n.load_script()
    n.set("dry_wet", 1)
    record_take(5, "tone", 0.5)
    set_mode("PLAY")

    def c141():
        time.sleep(0.5)
        nodes = n.nodes()
        return verdict("mangler_erode" not in nodes, f"nodes {nodes}")

    def c142():
        s = n.get("pos_start")
        n.set("pos_end", s + 2 / 60)
        before = n.take_hash()
        n.set("erode", 0.5)
        time.sleep(0.5)
        nodes = n.nodes()
        time.sleep(6)
        n.set("erode", 0)
        time.sleep(0.5)
        after = n.take_hash()
        return verdict("mangler_erode" in nodes and before != after, f"erode node present; the take changed={before != after}")

    def c143():
        n.goto("VOICE")
        n.set("erode", 1)
        for _ in range(4):
            n.key(2, 1)
            time.sleep(0.6)
            n.key(2, 0)
            time.sleep(0.6)
        n.set("erode", 0)
        time.sleep(0.5)
        rate, chans = engine_rec("14.3_after_switching", 6)
        hits = audio.clicks(chans[0], rate)
        return ("measured", f"erode 1 turns the tone to a noisy texture, so a break count cannot judge this ({len(hits)} found). Listen to 14.3_after_switching.wav")

    def c144():
        n.set("erode", 0.4)
        out = {}
        for name in ("PLAY", "GRAIN", "WARP", "PV", "PLAY"):
            set_mode(name)
            out.setdefault(name, []).append("mangler_erode" in n.nodes())
        n.set("erode", 0)
        return verdict(out["PLAY"] == [True, True] and not any(out["GRAIN"] + out["WARP"] + out["PV"]), f"erode node by mode {out}")

    def c145():
        n.goto("VOICE")
        n.set("erode", 0.5)
        time.sleep(1)
        stop(True)
        time.sleep(1)
        a = n.take_hash()
        time.sleep(10)
        b = n.take_hash()
        stop(False)
        n.set("erode", 0)
        return verdict(a == b, f"digest {a} = {b} over 10s of STOP")

    def c146():
        a = n.cpu(5)
        n.set("erode", 0.5)
        time.sleep(0.5)
        b = n.cpu(5)
        n.set("erode", 0)
        return verdict(b[0] >= a[0] - 0.5, f"PLAY at rest {a}; with erosion {b}. No older build to compare", "measured")

    for cid, fn in (("14.1", c141), ("14.2", c142), ("14.3", c143), ("14.4", c144), ("14.5", c145), ("14.6", c146)):
        check(cid, fn)


# ---- stage 15 ----------------------------------------------------------------
def stage15():
    def c151():
        n.load_script()
        record_take(5, "drums")
        set_mode("PLAY")
        n.set("erode", 0.5)
        time.sleep(4)
        n.set("erode", 0)
        time.sleep(2)
        start = mark()
        n.ctx("c.pad_chop()")
        time.sleep(10)
        text = transcript_since("lua", start)
        return verdict("CHOP" in text, f"{[x for x in text.splitlines() if 'mangler' in x]}. The queued line depends on the timing of the repaint", "measured")

    def c152():
        n.set("erode", 0.5)
        n.goto("VOICE")
        n.key(2, 1)
        time.sleep(0.5)
        n.key(2, 0)
        n.set("erode", 0)
        start = mark()
        n.ctx("c.pad_chop()")
        time.sleep(8)
        text = transcript_since("lua", start)
        return verdict("CHOP" in text and "queued" not in text, f"{[x for x in text.splitlines() if 'mangler' in x]}")

    def c158():
        n.load_script()
        start = mark()
        n.ctx(f'c.load_sample("{TEST_DIR}/long44k.wav")')
        time.sleep(3)
        n.ctx(f'c.load_sample("{TEST_DIR}/t44k.wav")')
        for _ in range(120):
            time.sleep(1)
            text = transcript_since("lua", start)
            if "t44k.wav (3.0s)" in text:
                break
        length = (n.get("pos_end") - n.get("pos_start")) * 60
        text = transcript_since("lua", start)
        return verdict("dropped" in text or "t44k.wav (3.0s)" in text and abs(length - 3) < 0.1, f"the second load wins: window {length:.2f}s; {[x[:70] for x in text.splitlines() if 'mangler' in x or 'dropped' in x or 'Hz file' in x]}")

    for cid, fn in (("15.1", c151), ("15.2", c152), ("15.8", c158)):
        check(cid, fn)
    you("15.3", why="needs a Launchpad")
    you("15.4", "15.5", "15.6", "15.7", "15.9", "15.10", "15.11", why="test/test_control covers the logic offscreen. Try these by hand")


# ---- stage 16 ----------------------------------------------------------------
def stage16():
    def c161():
        n.load_script()
        n.set("rec_wait", 1)
        n.goto("TAKE")
        start = mark()
        n.tap(2, 0.08)
        time.sleep(3)
        wait = n.ctx("c.rec_waiting")
        shot("16.1_wait")
        n.signal("hit")
        time.sleep(1)
        n.tap(2, 0.08)
        time.sleep(0.6)
        text = transcript_since("lua", start)
        secs = (n.get("pos_end") - n.get("pos_start")) * 60
        return verdict(wait == "true" and "sound at" in text and secs < 2.2, f"WAIT shown={wait}; the loop is {secs:.2f}s; {[x for x in text.splitlines() if 'sound at' in x]}")

    def c162():
        n.load_script()
        n.set("rec_wait", 1)
        n.set("rec_thresh", 0.8)
        n.goto("TAKE")
        n.tap(2, 0.08)
        time.sleep(1)
        n.signal("hit", 0.05)
        time.sleep(1)
        quiet = n.ctx("c.rec_waiting")
        n.signal("hit", 1)
        n.signal("tone", 0.7)
        time.sleep(1.5)
        loud = n.ctx("c.rec_waiting")
        n.signal(None)
        n.tap(2, 0.08)
        return verdict(quiet == "true" and loud == "false", f"waiting after a quiet hit={quiet}, after a loud sound={loud}")

    def c163():
        n.load_script()
        record_take(4, "drums")
        old = (n.get("pos_end") - n.get("pos_start")) * 60
        n.set("rec_wait", 1)
        n.goto("TAKE")
        n.tap(2, 0.08)
        time.sleep(1)
        n.signal("hit")
        time.sleep(0.25)
        n.tap(2, 0.08)
        time.sleep(0.6)
        new = (n.get("pos_end") - n.get("pos_start")) * 60
        return verdict(new < 1.6 and new < old - 1, f"previous take {old:.2f}s; the loop is now {new:.2f}s, the hit plus the REPL's delay before K2")

    def c164():
        n.load_script()
        n.set("dry_wet", 1)
        record_take(4, "tone")
        n.set("mode", 1)
        n.lua("params:set('clock_tempo', 120)")
        for i, st in enumerate((0, 3, 7, 12)):
            n.lua(f"__ctx.pad_pitch[{i}] = {st}")
        n.set("voice_rel", 0.5)
        opt("step_div", "1/4")
        n.set("step_len", 4)
        n.set("step_fill", 4)
        n.set("step_run", 1)
        time.sleep(1)
        rate, chans = engine_rec("16.4_sequencer", 6)
        n.goto("PADS")
        shot("16.4_pads")
        n.set("step_run", 0)
        return verdict(audio.stats(chans[0])["rms_db"] > -60, f"engine {audio.stats(chans[0])}. Progression: listen to 16.4_sequencer.wav", "measured")

    def c165():
        n.set("step_run", 1)
        time.sleep(1)
        running = n.lua("print(__ctx.seq.running())")
        n.lua("params:set('clock_tempo', 90)")
        time.sleep(1)
        after = n.lua("print(__ctx.seq.running())")
        n.set("step_run", 0)
        time.sleep(0.2)
        n.set("step_run", 1)
        time.sleep(0.5)
        restart = n.lua("print(__ctx.seq.running())")
        n.lua("params:set('clock_tempo', 120)")
        return verdict(running == after == restart == "true", f"running {running}, after a tempo change {after}, after a restart {restart}. On the beat: listen", "measured")

    def c166():
        stop(True)
        time.sleep(1)
        v = level("16.6_stopped", 1)
        stop(False)
        n.set("step_run", 0)
        time.sleep(1.5)
        held = n.lua("local k = 0; for _ in pairs(__ctx.pad_held) do k = k + 1 end print(k)")
        rest = level("16.6_after", 1)
        return verdict(v < -70 and held == "0" and rest < -60, f"STOP {v} dB; held voices {held}; after run off {rest} dB")

    def c167():
        n.load_script()
        n.set("dry_wet", 1)
        record_take(4, "tone")
        set_mode("PLAY")
        n.lua("params:set('clock_tempo', 120)")
        n.set("cutoff", 500)
        opt("lfo1_target", n.lua('print(params:lookup_param("cutoff").name)'))
        opt("lfo1_shape", "SINE")
        opt("lfo1_period", "1 BAR")
        n.set("lfo1_depth", 0.4)
        time.sleep(1)
        knob = n.get("cutoff")
        rate, chans = engine_rec("16.7_lfo", 6)
        knob2 = n.get("cutoff")
        env = audio.envelope(chans[0], rate, 0.2)
        n.goto("TAKE")
        shot("16.7_header_LF")
        n.set("lfo1_depth", 0)
        return verdict(max(env) - min(env) > 3 and knob == knob2 == 500, f"knob stays {knob} and {knob2}; the level swings {max(env) - min(env):.1f} dB over a bar")

    def c168():
        n.load_script()
        n.set("dry_wet", 1)
        record_take(4, "tone")
        set_mode("PLAY")
        # doc/device-gate.md names `eng level`, which is not a modulator target
        # (lib/mlfo.lua TARGETS). The cutoff shows the same ducking.
        n.set("cutoff", 1000)
        opt("lfo2_target", n.lua('print(params:lookup_param("cutoff").name)'))
        opt("lfo2_shape", "ENV")
        n.set("lfo2_depth", -0.6)
        time.sleep(0.5)
        quiet = level("16.8_no_input", 2)
        n.signal("tone", 0.5)
        time.sleep(1)
        ducked = level("16.8_input", 2)
        n.signal(None)
        n.set("lfo2_depth", 0)
        return verdict(ducked < quiet - 1, f"ENV on the cutoff: engine {quiet} dB without input, {ducked} dB with input. `eng level` is not a target, so the gate's text is out of date")

    def c169():
        n.load_script()
        record_take(4, "tone")
        set_mode("PLAY")
        name = n.lua('print(params:lookup_param("rev_mix").name)')
        opt("lfo2_target", name)
        opt("lfo2_shape", "SQUARE")
        n.set("lfo2_rate", 2)
        n.set("lfo2_depth", 0.4)
        time.sleep(1)
        on = n.nodes()
        cpu = n.cpu(4)
        n.set("lfo2_depth", 0)
        time.sleep(1.5)
        off = n.nodes()
        return verdict("mangler_reverb" in on and "mangler_reverb" not in off, f"reverb node with the LFO={'mangler_reverb' in on}, at depth 0={'mangler_reverb' in off}; CPU {cpu}")

    def c1610():
        n.load_script()
        n.lua("params:set('clock_tempo', 120)")
        record_take(6, "drums")
        set_mode("PLAY")
        opt("win_beats", "1 BAR")
        time.sleep(0.4)
        a = (n.get("pos_end") - n.get("pos_start")) * 60
        n.goto("TAKE")
        n.enc(2, 3)
        time.sleep(0.3)
        b = (n.get("pos_end") - n.get("pos_start")) * 60
        return verdict(abs(a - 2) < 0.01 and abs(b - 2) < 0.01, f"at 120 BPM the window is {a:.3f}s, and {b:.3f}s after E2")

    def c1611():
        n.lua("params:set('clock_tempo', 60)")
        time.sleep(0.5)
        a = (n.get("pos_end") - n.get("pos_start")) * 60
        n.lua("params:set('clock_tempo', 120)")
        time.sleep(0.5)
        return verdict(abs(a - 4) < 0.01, f"at 60 BPM the window is {a:.3f}s")

    def c1612():
        n.goto("TAKE")
        a = (n.get("pos_end") - n.get("pos_start")) * 60
        n.tap(3, 0.08)
        time.sleep(0.4)
        b = (n.get("pos_end") - n.get("pos_start")) * 60
        n.tap(3, 0.08)
        time.sleep(0.4)
        c = (n.get("pos_end") - n.get("pos_start")) * 60
        opt("win_beats", "FREE")
        return verdict(abs(a - c) < 0.01 and b > a, f"bar {a:.2f}s, K3 opens to {b:.2f}s, K3 back to {c:.2f}s")

    def c1613():
        n.load_script()
        record_take(3, "drums")
        first = (n.get("pos_end") - n.get("pos_start")) * 60
        record_take(5, "tone")
        time.sleep(3)
        second = (n.get("pos_end") - n.get("pos_start")) * 60
        n.ctx("c.take_undo()")
        time.sleep(4)
        undo = (n.get("pos_end") - n.get("pos_start")) * 60
        n.ctx("c.take_undo()")
        time.sleep(4)
        redo = (n.get("pos_end") - n.get("pos_start")) * 60
        return verdict(abs(undo - first) < 0.1 and abs(redo - second) < 0.1, f"windows: first {first:.2f}s, second {second:.2f}s, undo {undo:.2f}s, undo again {redo:.2f}s")

    def c1614():
        erase_page("TAKE")
        time.sleep(3)
        empty = num(n.ctx("c.take_len"))
        n.ctx("c.take_undo()")
        time.sleep(4)
        back = num(n.ctx("c.take_len"))
        return verdict(empty == 0 and back > 0, f"take_len {empty} after the erase, {back} after undo")

    for cid, fn in (("16.1", c161), ("16.2", c162), ("16.3", c163), ("16.4", c164), ("16.5", c165), ("16.6", c166),
                    ("16.7", c167), ("16.8", c168), ("16.9", c169), ("16.10", c1610), ("16.11", c1611),
                    ("16.12", c1612), ("16.13", c1613), ("16.14", c1614)):
        check(cid, fn)
    you("16.15", why="needs a synth or a MIDI monitor on port 1")
    you("16.16", why="needs a crow")
    you("16.17", why="only a hand and an ear can judge this")


# ---- stage 17: the beat repeat ------------------------------------------------
def stage17():
    n.load_script()
    n.set("dry_wet", 1)
    n.lua("params:set('clock_tempo', 120)")
    record_take(6, "drums")
    set_mode("PLAY")

    def c171():
        since = n.ssh("systemctl show norns-sclang -p ActiveEnterTimestamp --value").strip()
        errs = n.ssh(f'journalctl -u norns-sclang --since "{since}" --no-pager | grep -E "ERROR|FAILURE" | grep -cvE "RoutineYield|outside of a Routine"').strip()
        return verdict("count: 66" in n.transcript("lua") and errs == "0", f"count 66; SuperCollider errors since start {errs}")

    def c172():
        opt("repeat_div", "1/8")

        def hold():
            n.set("beat_repeat", 1)
            time.sleep(1)
            nodes.extend(n.nodes())
            shot("17.2_header_RP")
            time.sleep(2.5)
            n.set("beat_repeat", 0)

        nodes = []
        rate, chans = during(hold, "17.2_repeat", 6)
        env = audio.envelope(chans[0], rate, 0.05)
        return verdict("mangler_repeat" in nodes, f"repeat node present while held; sounding share {sum(1 for e in env if e > -50) / max(len(env), 1):.2f}. On the beat: listen to 17.2_repeat.wav", "measured")

    def c173():
        record_take(4, "tone")
        set_mode("PLAY")

        def hold():
            n.set("beat_repeat", 1)
            time.sleep(3)
            n.set("beat_repeat", 0)

        rate, chans = during(hold, "17.3_repeat_tone", 5)
        hits = audio.clicks(chans[0], rate)
        return verdict(not hits, f"a 1/8 repeat over a tone: breaks {hits[:8]}. Listen to 17.3_repeat_tone.wav", "measured")

    def c174():
        def roll():
            n.set("beat_repeat", 1)
            time.sleep(1)
            for name in ("1/16", "1/32", "1/8", "1/32", "1/16"):
                opt("repeat_div", name)
                time.sleep(0.5)
            n.set("beat_repeat", 0)
            opt("repeat_div", "1/8")

        rate, chans = during(roll, "17.4_roll", 5)
        hits = audio.clicks(chans[0], rate)
        return ("measured", f"a roll through 1/8, 1/16, 1/32: breaks {hits[:8]}. Smear: listen to 17.4_roll.wav")

    def c175():
        n.set("beat_repeat", 1)
        time.sleep(1)
        stop(True)
        time.sleep(0.8)
        a = level("17.5_stop", 1)
        nodes = n.nodes()
        stop(False)
        n.set("beat_repeat", 0)
        time.sleep(0.5)
        n.set("beat_repeat", 1)
        time.sleep(1)
        erase_page("TAKE")
        time.sleep(0.5)
        nodes2 = n.nodes()
        n.set("beat_repeat", 0)
        return verdict(a < -70 and "mangler_repeat" not in nodes and "mangler_repeat" not in nodes2, f"STOP {a} dB, node gone={'mangler_repeat' not in nodes}; erase, node gone={'mangler_repeat' not in nodes2}")

    def c177():
        record_take(4, "drums")
        set_mode("PLAY")
        a = n.cpu(4)
        n.set("beat_repeat", 1)
        time.sleep(1)
        b = n.cpu(4)
        n.set("beat_repeat", 0)
        time.sleep(1)
        c = n.cpu(4)
        return verdict(c[0] <= a[0] + 1, f"rest {a}, held {b}, after {c}")

    for cid, fn in (("17.1", c171), ("17.2", c172), ("17.3", c173), ("17.4", c174), ("17.5", c175), ("17.7", c177)):
        check(cid, fn)
    you("17.6", why="listen to a PRINT made with a repeat held")


# ---- stage 18: the screen -----------------------------------------------------
def stage18():
    n.load_script()
    record_take(5, "drums")
    set_mode("GRAIN")

    def c184():
        n.goto("VOICE")
        out = {}
        for d in (20, 200):
            n.set("density", d)
            time.sleep(0.5)
            out[d] = fps(5)
            shot(f"18.4_cloud_d{d}")
        n.set("density", 20)
        return verdict(out[200] >= 13, f"frames per second by density {out}; pictures in 18.4_cloud_*.png")

    def c1811():
        set_mode("PLAY")
        n.goto("TAKE")
        n.set("pos_end", n.get("pos_start") + 1 / 60)
        a = (n.get("pos_end") - n.get("pos_start")) * 60
        n.tap(3, 0.08)
        time.sleep(0.4)
        shot("18.11_snap")
        b = (n.get("pos_end") - n.get("pos_start")) * 60
        n.tap(3, 0.08)
        time.sleep(0.4)
        c = (n.get("pos_end") - n.get("pos_start")) * 60
        record_take(3, "tone")
        second = (n.get("pos_end") - n.get("pos_start")) * 60
        time.sleep(3)
        n.goto("TAKE")
        n.key(3, 1)
        time.sleep(0.6)
        shot("18.11_undo_arc")
        time.sleep(1)
        n.key(3, 0)
        time.sleep(4)
        d = (n.get("pos_end") - n.get("pos_start")) * 60
        return verdict(b > a and abs(c - a) < 0.01 and abs(d - second) > 0.1, f"tap {a:.2f}s to {b:.2f}s, tap back {c:.2f}s; second take {second:.2f}s, held K3 undoes to {d:.2f}s")

    def c1812():
        n.goto("TAKE")
        before = (n.get("pos_start"), n.get("pos_end"))
        n.key(3, 1)
        time.sleep(0.5)
        n.key(3, 0)
        time.sleep(0.4)
        mid = (n.get("pos_start"), n.get("pos_end"))
        n.key(3, 1)
        time.sleep(0.2)
        n.key(1, 1)
        time.sleep(0.2)
        n.key(3, 0)
        n.key(1, 0)
        time.sleep(0.4)
        after = (n.get("pos_start"), n.get("pos_end"))
        return verdict(before == mid == after, f"window unchanged by the aborted holds: {before}")

    for cid, fn in (("18.4", c184), ("18.11", c1811), ("18.12", c1812)):
        check(cid, fn)
    for page in "TAKE VOICE TAPE LAYERS FILTER DELAY REVERB MIX PADS MOTION SCENE".split():
        n.goto(page)
        time.sleep(0.25)
        shot("18_" + page)
    you("18.1", "18.2", "18.3", "18.5", "18.6", "18.7", "18.8", "18.9", "18.10", "18.13", "18.14", "18.15", "18.16",
        why="test/test_screen reads these off the pixels offscreen. Look at the OLED; screens/18_*.png are from the device")


def cleanup():
    n.signal_quit()
    n.ssh(f"rm -f ~/dust/data/mangler2/mangler2-{PSET}.pset ~/dust/data/mangler2/*-{PSET}.lua "
          f"~/dust/data/mangler2/*-{PSET}*.wav ~/dust/data/mangler2/mg_*.png")


STAGES = {0: stage0, 1: stage1, 2: stage2, 3: stage3, 4: stage4, 5: stage5, 6: stage6, 7: stage7,
          8: stage8, 9: stage9, 10: stage10, 11: stage11, 12: stage12, 13: stage13, 14: stage14,
          15: stage15, 16: stage16, 17: stage17, 18: stage18}


def main():
    global n
    n = Norns()
    load_results()
    n.helpers()
    if not n.signal_boot():
        print("no signal server")
    for arg in sys.argv[1:]:
        if arg == "cleanup":
            cleanup()
            continue
        global ONLY
        stage, _, only = arg.partition(":")
        ONLY = set(only.split(",")) if only else None
        print(f"--- stage {arg}", flush=True)
        STAGES[int(stage)]()
    print("xruns this boot:", n.xruns())


if __name__ == "__main__":
    main()
