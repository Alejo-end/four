#!/usr/bin/env python3
"""The Phase E session on a connected norns (doc/signature-workflow.md, section 6;
the sheets are doc/walkthrough.md). It measures what the people cannot.

    export NORNS_CTL=<control socket>        # see norns.py
    python3 test/device/session.py prepare   # a fresh script, count 198, the takes empty
    python3 test/device/session.py snap      # before the player's first fade (Part 1, task 5)
    python3 test/device/session.py home      # after the fade is back at 0: the ids off the origin
    python3 test/device/session.py takes     # Part 1's end: every track's take, and whether it plays
    python3 test/device/session.py record 5  # Part 2: record the output for 5 minutes, read the
                                             # scsynth thread every 5 s, then scan the recording

Results go to doc/measurements/<date>/session.jsonl; the recording goes outside the repo,
to ../four-device-recordings/<date>/ (a deploy copies the repo to the norns).
It writes no PSET. It never touches slots 1 to 12.
"""
import json
import os
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
SNAP = os.path.join(WAVS, "session_fade_origin.json")
for p in (OUT, WAVS):
    os.makedirs(p, exist_ok=True)


def save(name, **data):
    row = {"name": name, "at": time.strftime("%H:%M:%S"), **data}
    with open(os.path.join(OUT, "session.jsonl"), "a") as f:
        f.write(json.dumps(row) + "\n")
    print(json.dumps(row, indent=1))


# the ids a fade moves, read in one reply: "id=value" lines
MORPH_IDS_LUA = """
local ids = __ctx.scene.SCENE_MORPH_IDS or {}
local out = {}
for i = 1, #ids do
  local id = ids[i]
  if params.lookup[id] then out[#out + 1] = id .. "=" .. string.format("%.9g", params:get(id)) end
end
print(table.concat(out, " "))
"""


def morph_values(n):
    text = n.lua(MORPH_IDS_LUA, timeout=10)
    vals = {}
    for part in text.split():
        if "=" in part:
            k, v = part.split("=", 1)
            try:
                vals[k] = float(v)
            except ValueError:
                pass
    return vals


def prepare(n):
    start = len(n.transcript("lua"))
    n.load_script()
    text = n.transcript("lua")[start:]
    count = [ln.strip() for ln in text.splitlines() if "count:" in ln][:1]
    save("prepare", count=count, ok=bool(count and "198" in count[0]),
         note="A fresh script. Put the supported set's gear at the input: a drum machine and a synth.")


def snap(n):
    vals = morph_values(n)
    with open(SNAP, "w") as f:
        json.dump(vals, f)
    save("snap", ids=len(vals), fade=num(n.lua('print(params:get("scene_morph_amt"))')))


def home(n):
    if not os.path.exists(SNAP):
        print("no snapshot: run `session.py snap` before the first fade")
        sys.exit(2)
    with open(SNAP) as f:
        before = json.load(f)
    now = morph_values(n)
    amt = num(n.lua('print(params:get("scene_morph_amt"))'))
    off = {k: (before[k], now.get(k)) for k in before if now.get(k) is not None
           and abs(now[k] - before[k]) > 1e-6 * max(1.0, abs(before[k]))}
    save("home", fade=amt, ids=len(before), off_origin=off,
         note="Pass: the fade is at 0, and every id off the origin is one the player's hand moved (C7).")


def takes(n):
    out = n.lua("""
local t = {}
for k = 1, 4 do
  local any, len = __ctx.take_of(k)
  local mode = params:get(__ctx.MODE_ID[k])
  t[#t + 1] = k .. ":" .. tostring(any) .. ":" .. string.format("%.2f", (len or 0) * __ctx.BUF_SECS) .. ":" .. mode
end
print(table.concat(t, " "))
""")
    rows = {}
    for part in out.split():
        k, any_, secs, mode = part.split(":")
        rows[int(k)] = {"has_take": any_ == "true", "take_s": float(secs), "mode": int(float(mode)),
                        "plays": any_ == "true" and int(float(mode)) != 1}
    save("takes", tracks=rows, all_play=all(r["plays"] for r in rows.values()))


def record(n, minutes):
    secs = int(minutes * 60)
    local = os.path.join(WAVS, time.strftime("session_%H%M%S.wav"))
    x0 = n.now()
    loads, done = [], threading.Event()

    def sample():
        while not done.is_set():
            _, rows = n.threads(4, 6)
            sc = [cpu for name, cpu, _ in rows if name.startswith("scsynth")]
            if sc:
                loads.append(max(sc))
    th = threading.Thread(target=sample, daemon=True)
    th.start()
    print(f"recording {secs} s of the output to {local} ...", flush=True)
    n.record(secs, local)
    done.set()
    th.join(timeout=15)
    xr = n.xruns_since(x0)
    rate, chans = audio.load(local)
    hits = audio.breaks(chans, rate)
    holes = [audio.gaps(c, rate) for c in chans]
    srt = sorted(loads)
    p95 = srt[int(0.95 * (len(srt) - 1))] if srt else None
    save("record", file=local, seconds=secs, scsynth_p95=p95, scsynth_max=max(loads) if loads else None,
         reads=len(loads), xruns=xr, breaks=hits[:20], holes_left=holes[0][:20], holes_right=holes[1][:20],
         passes=bool(p95 is not None and p95 < 55 and xr == 0 and not hits),
         note="Pass (Part 2): the thread under 55% at p95, no xrun, no break. Holes are listed: "
              "CHORUS and FLANGE make holes by themselves, so listen to each one.")


def main():
    if len(sys.argv) < 2 or sys.argv[1] not in ("prepare", "snap", "home", "takes", "record"):
        print(__doc__)
        sys.exit(2)
    n = Norns()
    if sys.argv[1] != "prepare":
        n.helpers()
    cmd = sys.argv[1]
    if cmd == "record":
        record(n, float(sys.argv[2]) if len(sys.argv) > 2 else 5)
    else:
        {"prepare": prepare, "snap": snap, "home": home, "takes": takes}[cmd](n)


if __name__ == "__main__":
    main()
