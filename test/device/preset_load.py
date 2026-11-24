#!/usr/bin/env python3
"""What a preset load costs (doc/plan.md, Phase 3): xruns, and holes in the output.

    export NORNS_CTL=<control socket>            # see norns.py
    python3 test/device/preset_load.py [rounds]  # 3 rounds by default
    COLD=1 python3 test/device/preset_load.py    # every load reads the card

It READS slots 1 to 12 and writes none. The partial loads are copies of a slot in
/tmp on the norns with lines left out. It puts pset-last.txt and the system
parameters back, and checksums the slots' files before and after. Results go to
doc/measurements/<date>/preset_load.jsonl.
"""
import json
import os
import re
import sys
import threading
import time

sys.path.insert(0, os.path.dirname(__file__))
import audio  # noqa: E402
from norns import Norns, num  # noqa: E402

DATE = os.environ.get("GATE_DATE") or time.strftime("%Y-%m-%d")
ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
OUT = os.path.join(ROOT, "doc", "measurements", DATE)
WAVS = os.path.join(os.path.dirname(ROOT), "four-device-recordings", DATE)
ROUNDS = int(sys.argv[1]) if len(sys.argv) > 1 else 3
COLD = os.environ.get("COLD") == "1"
SYSTEM = ("output_level", "input_level", "monitor_level", "engine_level", "softcut_level", "tape_level",
          "monitor_mode", "reverb", "compressor", "headphone_gain", "clock_tempo", "clock_source")
FILES = r'"\(sample_file\|lay[0-9]_file\|t[234]_file\)"'
SUMS = ("cd ~/dust/data/four && md5sum four-*.pset scenes-*.lua padlock-*.lua tape-*.wav four.pmap osc.cfg "
        "pset-last.txt | md5sum")
PORTS = ("crone:output_1", "crone:output_2")
for p in (OUT, WAVS):
    os.makedirs(p, exist_ok=True)
n = Norns()
n.helpers()


def save(**row):
    with open(os.path.join(OUT, "preset_load.jsonl"), "a") as f:
        f.write(json.dumps(row) + "\n")
    print(json.dumps(row), flush=True)


def log_since(unit, stamp, pattern):
    """(offset from `stamp`, text) for each line of a unit's log."""
    out = n.ssh(f"journalctl -u {unit} --since @{stamp:.6f} --no-pager -o short-unix | grep -iE '{pattern}'")
    rows = []
    for line in out.splitlines():
        m = re.match(r"([\d.]+) \S+ (.*)", line)
        if m:
            rows.append((round(float(m.group(1)) - stamp, 2), m.group(2)[-70:]))
    return rows


def dead(chans, rate, least=0.002):
    """Runs of exact zeros on both channels between sound: (start, ms)."""
    a, b = chans
    out, run = [], 0
    for i in range(len(a)):
        if a[i] == 0 and b[i] == 0:
            run += 1
        else:
            if run > least * rate and i - run > 0:
                out.append((round((i - run) / rate, 3), round(run / rate * 1000, 1)))
            run = 0
    return out


def load(name, lua, secs=8, wav=False, cold=False):
    """Run `lua` 2 s into a window, and count what the window saw. `cold`: the
    files come from the card, as in a show, and not from the memory."""
    box = {}
    if cold:
        n.ssh("sync; echo 3 | sudo -n tee /proc/sys/vm/drop_caches >/dev/null")
        time.sleep(2)

    def rec():
        box["path"] = os.path.join(WAVS, f"preset_{name}.wav")
        n.record(secs + 2, box["path"], PORTS)

    th = threading.Thread(target=rec) if wav else None
    t0 = float(n.ssh("date +%s.%N"))
    if th:
        th.start()
    time.sleep(2)
    t1 = float(n.ssh("date +%s.%N"))
    if lua:
        # the time the main Lua thread is held by it
        n.lua(f"local t = util.time() {lua} __ms = (util.time() - t) * 1000", timeout=20)
        # (the script logs to the same REPL: read the marked line only)
        ms = num(n.lua('print("@ms " .. __ms)', timeout=20).split("@ms")[-1])
    else:
        ms = None
    time.sleep(secs)
    if th:
        th.join()
    x = log_since("norns-jack", t0, "xrun")
    row = dict(name=name, cold=cold, xruns=len(x), xruns_at=[round(a - (t1 - t0), 2) for a, _ in x][:30],
               lua_ms=ms and round(ms, 1),
               crone=len(log_since("norns-crone", t0, "seek|abort|error")))
    if wav:
        rate, chans = audio.load(box["path"])
        row["dead_ms"] = dead(chans, rate)[:12]
        row["rms_db"] = audio.stats(chans[0])["rms_db"]
    save(**row)
    return row


before = n.ssh(SUMS)
last = n.ssh("cat ~/dust/data/four/pset-last.txt | base64").strip()
keep = {p: n.lua(f'print(params.lookup["{p}"] and params:get("{p}"))').strip() for p in SYSTEM}
try:
    n.load_script()
    load("control_empty", None, 20)
    for r in range(1, ROUNDS + 1):
        for k in range(1, 13):
            load(f"seq_{k:02d}_round{r}", f"params:read({k})", 8, wav=r == 1, cold=COLD)
    n.lua("params:read(6)")
    time.sleep(8)
    load("control_playing", None, 30, wav=True)
    # the load in parts, over preset 6 that plays
    n.ssh(f"grep -v '{FILES}' ~/dust/data/four/four-06.pset > /tmp/p_nofile.pset; "
          f"grep '{FILES}' ~/dust/data/four/four-06.pset > /tmp/p_files.pset; "
          "grep '\"sample_file\"' ~/dust/data/four/four-06.pset > /tmp/p_one.pset")
    for r in range(1, ROUNDS + 1):
        load(f"part_params_round{r}", 'params:read("/tmp/p_nofile.pset")', cold=COLD)
        load(f"part_files_round{r}", 'params:read("/tmp/p_files.pset")', cold=COLD)
        load(f"part_one_file_round{r}", 'params:read("/tmp/p_one.pset")', cold=COLD)
    # the same load with four voices working
    for r in range(1, ROUNDS + 1):
        n.lua('for i, id in ipairs({"mode", "t2_mode", "t3_mode", "t4_mode"}) do params:set(id, 4) end')
        time.sleep(4)
        _, th = n.threads(3, 12)
        sc = max((c for name, c, _ in th if name.startswith("scsynth")), default=None)
        save(name=f"heavy_round{r}_scsynth", percent=sc)
        load(f"heavy_four_PV_06_round{r}", "params:read(6)", 8, wav=r == 1, cold=COLD)
finally:
    n.ssh("rm -f /tmp/p_nofile.pset /tmp/p_files.pset /tmp/p_one.pset")
    n.load_script()
    for p, v in keep.items():
        if v not in ("nil", ""):
            n.lua(f'params:set("{p}", {"-math.huge" if "-inf" in v else v})')
    n.ssh(f"echo {last} | base64 -d > ~/dust/data/four/pset-last.txt")
    save(name="slots_untouched", ok=before == n.ssh(SUMS), xruns_boot=n.xruns())
