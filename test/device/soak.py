#!/usr/bin/env python3
"""Soak test: a big four-track set on preset 1, a move every 3 minutes,
measured every 30 s (scsynth and matron CPU, avgCPU/peakCPU, Lua memory,
temperature, xruns). Leaves the set running at the end.

    export NORNS_CTL=<short dir>/ctl     # an open master SSH session (norns.py)
    python3 test/device/soak.py 30       # minutes

Reads preset 1 only (never writes a slot). If someone loads a preset by hand
during the run, the numbers after it measure that preset instead.
"""
import sys, os, time, re
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from norns import Norns
MIN = float(sys.argv[1]) if len(sys.argv) > 1 else 30
n = Norns()
n.load_script(wait=60)
print("count", re.findall(r"count: \d+", n.transcript("lua"))[-1:], flush=True)
n.lua("params:read(1)")          # preset 1: four tracks of material
time.sleep(12)
print("preset 1 loaded; take", n.ctx("c.wave_any"), "tracks", [n.ctx(f"c.track_has({t})") for t in (2, 3, 4)], flush=True)
tg = lambda name: int(n.ctx(f'(function() for i,t in ipairs(c.lfo.TARGETS) do if t=="{name}" then return i+1 end end end)()'))
big = {
  "t2_mode": 2, "t2_density": 30, "t2_size": 0.15, "t2_spread": 0.6, "t2_level": 0.8,
  "t3_mode": 6, "t3_level": 0.7, "t3_cutoff": 4000, "t3_resonance": 0.3,
  "t4_mode": 4, "t4_crush": 0.3, "t4_drive": 0.3, "t4_level": 0.6, "t4_scan": 0.3,
  "send_1_2": 0.25, "send_2_3": 0.2, "t3_fx_rev": 0.8,
  "delay_mix": 0.25, "rev_mix": 0.3,
}
for k, v in big.items():
    n.set(k, v); time.sleep(0.2)
for i, (t, trk, d, r) in enumerate([("cutoff", 3, 0.3, 0.2), ("size", 2, 0.4, 0.1), ("crush", 4, 0.3, 0.05), ("pan", 1, 0.5, 0.15)], 1):
    n.set(f"lfo{i}_target", tg(t)); n.set(f"lfo{i}_track", trk); n.set(f"lfo{i}_depth", d); n.set(f"lfo{i}_rate", r)
time.sleep(5)
print("big set on: modes", [n.string(m) for m in ("mode", "t2_mode", "t3_mode", "t4_mode")], flush=True)
start = n.now(); t0 = time.time(); scene = 2; rows = []
mem0 = None
while time.time() - t0 < MIN * 60:
    el = (time.time() - t0) / 60
    # a move every 3 minutes, as in a show: track 1 changes voice (the
    # preset's scenes would switch tracks 2 to 4 off, so no scene recalls)
    if int(el) // 3 + 2 != scene and el > 0.5:
        scene = int(el) // 3 + 2
        m = [2, 6, 3, 5, 4][(scene - 2) % 5]
        n.set("mode", m); n.set("t2_density", [30, 80, 12][scene % 3]); n.set("cutoff", [8000, 2500, 15000][scene % 3])
        print(f"{el:5.1f} min  move: track 1 is {n.string('mode')}", flush=True)
    idle, th = n.threads(3, 8)
    sc = next((c for name, c, _ in th if name == "scsynth"), 0)
    mat = sum(c for name, c, _ in th if name == "matron")
    a, p = n.cpu(2)
    mem = float(n.lua("print(collectgarbage('count'))") or 0)
    mem0 = mem0 or mem
    temp = int(n.ssh("cat /sys/class/thermal/thermal_zone0/temp").strip() or 0) / 1000
    x = n.xruns_since(start)
    rows.append((el, sc, mat, a, p, mem, temp, x))
    print(f"{el:5.1f} min  scsynth {sc:5.1f}%  matron {mat:5.1f}%  avg {a:5.1f} peak {p:5.1f}  lua {mem/1024:6.1f} MB  {temp:4.1f} C  xruns {x}", flush=True)
    time.sleep(max(0, 30 - 7))
print("SUMMARY", flush=True)
sc = [r[1] for r in rows]; pk = [r[4] for r in rows]; tp = [r[6] for r in rows]
print(f"minutes {rows[-1][0]:.1f}  scsynth mean {sum(sc)/len(sc):.1f}% max {max(sc):.1f}%  peakCPU max {max(pk):.1f}  "
      f"temp max {max(tp):.1f} C  lua mem {rows[0][5]/1024:.1f} -> {rows[-1][5]/1024:.1f} MB  xruns {rows[-1][7]}", flush=True)
print("left running on preset 1 with the big set", flush=True)
