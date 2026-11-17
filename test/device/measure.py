#!/usr/bin/env python3
"""Measure what four costs on a connected norns.

    export NORNS_CTL=<control socket>       # see norns.py
    python3 test/device/measure.py system states pages voices two_server patch soak
    python3 test/device/measure.py budget   # the dense set of gate row 19.27, part by part

Each state settles, then reads over the same window: the main scsynth's average
and peak CPU, xruns, screen frames per second, the system's idle share and the
busiest threads. Results go to doc/measurements/<date>/performance.jsonl.
"""
import json
import os
import re
import sys
import time

sys.path.insert(0, os.path.dirname(__file__))
import audio  # noqa: E402
import gate  # noqa: E402
from gate import OUT, DECKS_OUT, PAGES, opt, record_take, set_mode  # noqa: E402
from norns import Norns, num  # noqa: E402

PATH = os.path.join(OUT, "performance.jsonl")
n = None


def save(kind, name, **data):
    row = {"kind": kind, "name": name, **data}
    with open(PATH, "a") as f:
        f.write(json.dumps(row) + "\n")
    print(json.dumps(row)[:400], flush=True)


def sample(name, kind="state", window=15):
    x0 = n.now()
    frame0 = int(num(n.ctx("c.frame"))) if n.lua("print(type(__ctx))") == "table" else None
    t0 = time.time()
    cpu = n.cpu(window)
    idle, threads = n.threads(4, 6)
    fps = None
    if frame0 is not None:
        fps = round((int(num(n.ctx("c.frame"))) - frame0) / (time.time() - t0), 1)
    temp = n.ssh("vcgencmd measure_temp 2>/dev/null || cat /sys/class/thermal/thermal_zone0/temp").strip()
    save(kind, name, avg=cpu[0], peak=cpu[1], xruns=n.xruns_since(x0), fps=fps, idle=idle,
         threads=[f"{t[0]} {t[1]}" for t in threads], temp=temp)


def system():
    cmd = (
        "uname -a; tr -d '\\0' < /proc/device-tree/model; echo; grep -m1 -E 'Features' /proc/cpuinfo; "
        "cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor; "
        "cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq; cat /proc/cmdline; "
        "free -m | head -2; df -h / | tail -1; jackd --version | head -1; scsynth -v 2>&1 | head -1; "
        "cat ~/version.txt; ps -eLo comm,cls,rtprio,psr --sort=-rtprio | sort -u -k1,3 | grep -E 'jackd|scsynth|crone|sclang|matron' | head -24; "
        "for p in $(pgrep -x scsynth); do taskset -p $p; done; vcgencmd get_throttled 2>/dev/null; ulimit -l; "
        "ls ~/.local/share/SuperCollider/Extensions; which supernova || echo no-supernova"
    )
    text = n.ssh(cmd, timeout=30)
    save("system", "facts", text=text)
    print(text)


def fresh_take(kind="tone"):
    n.load_script()
    n.set("dry_wet", 1)
    record_take(5, kind)
    set_mode("PLAY")
    time.sleep(1)


def states():
    n.lua("norns.script.clear()")
    time.sleep(6)
    n.lua("__ctx = nil")
    cpu = n.cpu(8)
    idle, threads = n.threads(4, 6)
    save("state", "no script", avg=cpu[0], peak=cpu[1], idle=idle, threads=[f"{t[0]} {t[1]}" for t in threads])

    n.load_script()
    sample("four loaded, empty take")
    fresh_take()
    sample("PLAY")
    for mode in ("OFF", "GRAIN", "WARP", "PV"):
        set_mode(mode)
        sample(mode)
    set_mode("PLAY")
    # the sends start at 0 (four, nineteenth change): open track 1's, so the
    # delay and the reverb process the take and not silence
    n.set("fx_rev", 1)
    n.set("rev_mix", 0.4)
    time.sleep(1)
    sample("PLAY + reverb")
    n.set("shimmer", 0.5)
    time.sleep(1)
    sample("PLAY + reverb + shimmer")
    n.set("shimmer", 0)
    n.set("rev_mix", 0)
    n.set("fx_rev", 0)
    n.set("fx_dly", 1)
    n.set("delay_mix", 0.4)
    time.sleep(1)
    sample("PLAY + delay")
    n.set("delay_mix", 0)
    n.set("fx_dly", 0)
    n.set("drive", 0.5)
    sample("PLAY + drive")
    n.set("drive", 0)
    n.set("erode", 0.3)
    sample("PLAY + erosion")
    n.set("erode", 0)
    n.set("beat_repeat", 1)
    time.sleep(1)
    sample("PLAY + beat repeat held")
    n.set("beat_repeat", 0)


def grain():
    """GRAIN's cost depends on how many grains run, so sweep what sets that."""
    fresh_take()
    set_mode("GRAIN")
    for density, size in ((5, 0.1), (20, 0.1), (80, 0.1), (200, 0.1), (200, 0.5)):
        n.set("density", density)
        n.set("size", size)
        time.sleep(1)
        sample(f"GRAIN density {density} size {size}", window=8)
    n.set("density", 20)
    n.set("size", 0.1)
    set_mode("WARP")
    # the param stops at 8 (four.lua), so a 16 measured 8 under the name 16
    for overlaps in (2, 4, 8):
        n.set("warp_overlaps", overlaps)
        time.sleep(1)
        sample(f"WARP overlaps {overlaps}", window=8)


def pages():
    """What each page's drawing costs. The take plays, and nothing else moves."""
    fresh_take()
    for page in PAGES.split():
        n.goto(page)
        time.sleep(1)
        sample(page, kind="page", window=6)


def voices():
    fresh_take()
    n.set("mode", 1)
    time.sleep(1)
    sample("no voice, no drone", kind="voices", window=8)
    for label, typ, count, extra in (
        ("SLICE", 1, 8, {}), ("SLICE", 1, 16, {}), ("SLICE", 1, 32, {}),
        ("GRAIN density 20 size 0.1", 0, 8, {}), ("GRAIN density 20 size 0.1", 0, 16, {}),
        ("GRAIN density 100 size 0.2", 0, 8, {"density": 100, "size": 0.2}),
    ):
        n.set("voices", min(count, 16))
        for k, v in extra.items():
            n.set(k, v)
        n.lua("for i = 0, 7 do __ctx.pad_type[i] = %d end" % typ)
        if count > 16:
            # past the `voices` limit: straight to the engine, to find the ceiling
            n.lua("engine.voices(%d)" % count)
        for i in range(count):
            n.lua("engine.note_on(%d, %f, 1, %d, 0.2, %f)" % (9400 + i, i / count * 0.08, typ, 0.08 / count))
        time.sleep(1.5)
        sample(f"{count} x {label}", kind="voices", window=10)
        for i in range(count):
            n.lua("engine.note_off(%d)" % (9400 + i))
        time.sleep(1.5)
    n.lua("engine.voices(8)")
    n.set("density", 20)
    n.set("size", 0.1)


def record_tape(secs=3, kind="tone", amp=None):
    """Record a pass on the tape with the TAPE keys."""
    n.goto("TAPE")
    n.signal(kind, amp)
    time.sleep(0.2)
    n.tap(2, 0.08)
    time.sleep(secs)
    n.tap(2, 0.08)
    time.sleep(0.5)
    n.signal(None)
    time.sleep(0.3)


def everything():
    """The whole instrument at once: the budget that a real set must fit in."""
    n.load_script()
    n.set("dry_wet", 1)
    record_take(5, "drums")
    record_tape(3, "tone", 0.1)
    set_mode("GRAIN")
    n.set("density", 80)
    n.set("fx_dly", 1)   # track 1's sends: the delay and reverb hear it
    n.set("fx_rev", 1)
    n.set("rev_mix", 0.3)
    n.set("delay_mix", 0.3)
    n.set("shimmer", 0.3)
    n.set("drive", 0.2)
    n.set("cutoff", 4000)
    n.set("resonance", 0.3)
    for i in range(8):
        n.ctx(f"c.pad_trigger({9500 + i}, {i}, 1)")
    time.sleep(2)
    sample("everything: GRAIN, 8 GRAIN pads, reverb, shimmer, delay, filter, tape", kind="budget", window=30)


def patch():
    """Patch softcut's stereo mix into the engine with JACK, and prove it arrives."""
    n.load_script()
    n.set("dry_wet", 0)
    n.set("mode", 1)
    n.set("cut_source", 0)
    n.set("monitor_level", n.get("monitor_level"))
    time.sleep(0.5)
    record_tape(3, "tone")
    time.sleep(0.5)
    deck = audio.stats(audio.load(gate_rec("patch_softcut", DECKS_OUT))[1][0])
    before = audio.stats(audio.load(gate_rec("patch_engine_before", gate.ENGINE_OUT))[1][0])
    n.ssh("jack_connect softcut:output_1 SuperCollider:in_1; jack_connect softcut:output_2 SuperCollider:in_2")
    time.sleep(1)
    x0 = n.now()
    after = audio.stats(audio.load(gate_rec("patch_engine_after", gate.ENGINE_OUT))[1][0])
    n.set("fx_rev", 1)   # track 1's send: since the 19th change it starts at 0
    n.set("rev_mix", 0.5)
    time.sleep(2)
    wet = audio.stats(audio.load(gate_rec("patch_engine_reverb", gate.ENGINE_OUT))[1][0])
    x1 = n.xruns_since(x0)
    amp = n.ctx("c.amp_in[1]")
    n.ssh("jack_disconnect softcut:output_1 SuperCollider:in_1; jack_disconnect softcut:output_2 SuperCollider:in_2")
    n.set("rev_mix", 0)
    n.set("fx_rev", 0)
    save("patch", "softcut into the engine", deck=deck, engine_before=before, engine_after=after, with_reverb=wet,
         xruns=x1, amp_in_poll=amp)


def gate_rec(name, ports, secs=3):
    path = os.path.join(gate.WAVS, name + ".wav")
    n.record(secs, path, ports)
    return path


SECOND = r"""
~mgB = Server.named[\second] ?? { Server(\second, NetAddr("127.0.0.1", 57130)) };
~mgB.options.numInputBusChannels = 2;
~mgB.options.numOutputBusChannels = 2;
~mgB.options.device = "default:scb";
~mgLoadA = List.new; ~mgLoadB = List.new;
~mgB.waitForBoot {
    var def = { arg srv;
        SynthDef(\mg_load, { arg bus = 100;
            Out.ar(bus, Mix.fill(40, { SinOsc.ar(ExpRand(100, 8000)) * 0.001 }));
        }).send(srv);
    };
    def.value(~mgB); def.value(Crone.server);
    ~mgB.sync; Crone.server.sync;
    "jack_connect scb:out_1 crone:input_5; jack_connect scb:out_2 crone:input_6; jack_connect crone:output_5 scb:in_1; jack_connect crone:output_6 scb:in_2".unixCmd;
    1.wait;
    "SECOND_READY".postln;
};
"""


def thread_cpu(pid, seconds=3):
    """The busiest thread of one process, in percent of one core, and its core."""
    out = n.ssh(f"top -H -b -n 2 -d {seconds} -p {pid} | awk '/^top/{{c++}} c==2' | awk '$1 ~ /^[0-9]+$/' | sort -k9 -rn | head -1", timeout=seconds + 15)
    parts = out.split()
    return float(parts[8]) if len(parts) > 8 else 0.0


def add_load(server, count):
    target = "Crone.server" if server == "A" else "~mgB"
    name = "~mgLoadA" if server == "A" else "~mgLoadB"
    n.sc(f"{count}.do {{ {name}.add(Synth(\\mg_load, [\\bus, 100], {target}.defaultGroup)) }};")


def fill(server, pid, target):
    """Add sine synths until this server's own audio thread reaches the target."""
    now = thread_cpu(pid)
    while now < target:
        add_load(server, max(1, int((target - now) / 4)))
        time.sleep(0.5)
        now = thread_cpu(pid)
    return now


def audio_tid(pid):
    """The server's audio thread: its only thread at JACK's client priority."""
    out = n.ssh(f"ps -L -o tid=,rtprio= -p {pid}")
    return next(line.split()[0] for line in out.splitlines() if len(line.split()) == 2 and line.split()[1] == "90")


def server_trial(label, second=True, pin=False, targets=(20, 30, 40, 50, 60, 70), hold=20):
    """Load one or two servers in steps. Each server's own thread comes from top."""
    n.load_script()
    n.set("dry_wet", 1)
    record_take(5, "tone")
    record_tape(3, "tone", 0.1)
    set_mode("PLAY")
    n.signal_quit()      # the signal server is a JACK client too; a real set has none
    time.sleep(1.5)
    start = len(n.transcript("sc"))
    n.sc(SECOND)
    end = time.time() + 20
    while "SECOND_READY" not in n.transcript("sc")[start:] and time.time() < end:
        time.sleep(0.3)
    pids = n.ssh("for p in $(pgrep -x scsynth); do echo $p $(tr '\\0' ' ' < /proc/$p/cmdline); done")
    a = next(line.split()[0] for line in pids.splitlines() if "-u 57110" in line)
    b = next(line.split()[0] for line in pids.splitlines() if "-u 57130" in line)
    if not second:
        n.sc("~mgB.quit;")
        time.sleep(1.5)
    if pin:
        n.ssh(f"taskset -cp 2 {audio_tid(a)}; taskset -cp 3 {audio_tid(b)}")
    for target in targets:
        fill("A", a, target)
        if second:
            fill("B", b, target)
        time.sleep(1)
        stamp = n.now()
        jack = n.cpu(hold)
        x = n.xruns_since(stamp)
        ta = thread_cpu(a)
        tb = thread_cpu(b) if second else 0.0
        save("two_server", f"{label}, near {target}%", thread_a=ta, thread_b=tb, jack_avg=jack[0], jack_peak=jack[1],
             xruns=x, seconds=hold, sum=round(ta + tb, 1))
        if x > 100:
            break
    n.sc("~mgLoadA.do(_.free); ~mgLoadB.do(_.free); ~mgLoadA.clear; ~mgLoadB.clear; ~mgB.quit;")
    time.sleep(2)
    n.signal_boot()


def two_server():
    """Does a second scsynth add budget? Three trials answer it.

    Under JACK, scsynth's avgCPU is jack_cpu_load: the load of the whole cycle,
    the same number on both servers. So the trials read each server's own thread
    from top. The xrun count is the verdict.
    """
    server_trial("one server", second=False)
    server_trial("two servers", second=True)
    server_trial("two servers, pinned to cores 2 and 3", second=True, pin=True)


def soak(minutes=30):
    everything()
    x0 = n.now()
    t0 = time.time()
    for i in range(minutes // 5):
        time.sleep(285)
        sample(f"soak minute {(i + 1) * 5}", kind="soak", window=10)
    save("soak", "total", minutes=round((time.time() - t0) / 60, 1), xruns=n.xruns_since(x0))
    n.ctx("c.pads_all_off()")


def hold_two():
    """Is the good result at 50% + 50% stable? Five minutes on the same load."""
    server_trial("two servers held for 5 min", second=True, targets=(50,), hold=300)


def thread_poll(windows=4):
    """The busiest scsynth thread over `windows` windows of 5 s in top -H, and
    the norns CPU poll (Crone.server.avgCPU, the load of the whole JACK cycle)
    read at the end of each window. Returns the mean and the largest of each."""
    threads, polls = [], []
    for _ in range(windows):
        t = gate.sc_thread(5)
        if t is not None:
            threads.append(t)
        reply = n.sc('("MGCPU " ++ Crone.server.avgCPU ++ " " ++ Crone.server.peakCPU).postln;')
        found = re.search(r"MGCPU ([\d.]+) ([\d.]+)", reply)
        if found:
            polls.append(float(found.group(1)))
    mean = lambda xs: round(sum(xs) / len(xs), 1) if xs else None
    return mean(threads), max(threads, default=None), mean(polls), max(polls, default=None)


def budget():
    """The dense set of gate row 19.27, built up one part at a time, so that
    each part's share of the scsynth thread shows (C5 of
    doc/signature-workflow.md). The last state is the one row 19.27 scores.
    Each state also reads the norns CPU poll, to see how far it lies from the
    thread."""
    n.load_script()
    n.set("dry_wet", 1)
    for t, kind, amp in ((1, "drums", None), (2, "tone", None), (3, "tone", 0.12), (4, "drums", 0.25)):
        n.set("track_sel", t)
        time.sleep(0.4)
        record_take(4, kind, amp)
    n.set("track_sel", 1)
    tp = gate.tp

    def every(pid, v):
        for t in range(1, 5):
            n.set(tp(t, pid), v)

    def dense():
        gate.modes("PV", "PV", "GRAIN", "GRAIN")
        for t, vals in ((1, {"pitch": 1.96}), (2, {"pitch": 2.5}),
                        (3, {"density": 200, "size": 0.29}), (4, {"density": 200, "size": 0.5})):
            for pid, v in vals.items():
                n.set(tp(t, pid), v)

    def pv4():
        gate.modes("PV", "PV", "PV", "PV")
        every("pitch", 2)

    def rest():
        for pid, v in (("effect", 1), ("effect2", 1), ("drive", 0), ("fx_dly", 0), ("fx_rev", 0),
                       ("pitch", 1), ("density", 20), ("size", 0.1)):
            every(pid, v)
        for pid in ("delay_mix", "rev_mix", "shimmer"):
            n.set(pid, 0)

    steps = (
        ("all four OFF", lambda: gate.modes("OFF", "OFF", "OFF", "OFF")),
        ("four PLAY", lambda: gate.modes("PLAY", "PLAY", "PLAY", "PLAY")),
        ("four PV at pitch 2, nothing else", pv4),
        ("the dense voices, nothing else", lambda: (every("pitch", 1), dense())),
        ("+ the reverb (mix 0.5, every send 0.5)", lambda: (every("fx_rev", 0.5), n.set("rev_mix", 0.5))),
        ("+ shimmer 0.5", lambda: n.set("shimmer", 0.5)),
        ("+ the delay (mix 0.5, every send 0.5)", lambda: (every("fx_dly", 0.5), n.set("delay_mix", 0.5))),
        ("+ drive 0.5 on every track", lambda: every("drive", 0.5)),
        ("+ FLANGE in every first slot", lambda: every("effect", 3)),
        ("+ ECHO in every second slot: row 19.27's dense set", lambda: every("effect2", 7)),
        ("four PV at pitch 2 with all of it: row 19.27's other set", pv4),
    )
    rest()
    for name, fn in steps:
        fn()
        time.sleep(3)
        x0 = n.now()
        thread, thread_max, poll, poll_max = thread_poll()
        save("budget", name, thread=thread, thread_max=thread_max, poll=poll, poll_max=poll_max,
             xruns=n.xruns_since(x0))
    rest()
    gate.modes("OFF", "PLAY", "OFF", "OFF")


TASKS = dict(budget=budget, hold_two=hold_two, system=system, states=states, grain=grain, pages=pages, voices=voices, everything=everything,
             two_server=two_server, patch=patch, soak=soak)


def main():
    global n
    n = gate.n = Norns()
    n.helpers()
    n.signal_boot()
    for name in sys.argv[1:]:
        print("---", name, flush=True)
        try:
            TASKS[name]()
        except Exception as e:
            save("error", name, error=f"{type(e).__name__}: {e}")
    n.signal(None)


if __name__ == "__main__":
    main()
