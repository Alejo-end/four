#!/usr/bin/env python3
"""Drive a norns from this computer: the two maiden REPLs, SSH and JACK capture.

Standard library only. No password or key lives here. Before you use the ssh
methods, open a master connection and set NORNS_CTL to its control socket:

    cd <short dir> && ssh -M -S ctl we@norns.local 'sleep 21600' &
    export NORNS_CTL=<short dir>/ctl

Keep that session open. The last SSH logout deletes the JACK sockets
(doc/norns-platform.md), so a session must span a restart and the JACK work.

Command line:
    norns.py lua 'print(params:get("cutoff"))'
    norns.py sc  'Crone.server.avgCPU.postln'
    norns.py status
"""
import base64
import os
import re
import socket
import struct
import subprocess
import sys
import threading
import time

HOST = os.environ.get("NORNS_HOST", "norns.local")
PORTS = {"lua": 5555, "sc": 5556}

# Installed into matron's globals so that a test can read the script's private
# ctx table without a change to the script. It looks through the upvalues of the
# script's global functions.
CTX_HELPER = (
    "function __find_ctx() "
    "for _, f in ipairs({key, enc, redraw, init}) do "
    "for i = 1, 200 do local n, v = debug.getupvalue(f, i); if not n then break end; "
    "if n == 'ctx' then return v end end end end "
    "__ctx = __find_ctx()"
)


class Socket:
    """One WebSocket to a maiden REPL. A thread appends all it receives to self.text."""

    def __init__(self, port):
        self.sock = socket.create_connection((HOST, port), timeout=8)
        key = base64.b64encode(os.urandom(16)).decode()
        self.sock.sendall((
            f"GET / HTTP/1.1\r\nHost: {HOST}:{port}\r\nUpgrade: websocket\r\n"
            f"Connection: Upgrade\r\nSec-WebSocket-Key: {key}\r\n"
            "Sec-WebSocket-Version: 13\r\n"
            "Sec-WebSocket-Protocol: bus.sp.nanomsg.org\r\n\r\n").encode())
        buf = b""
        while b"\r\n\r\n" not in buf:
            data = self.sock.recv(4096)
            if not data:
                raise RuntimeError("handshake closed")
            buf += data
        head, self.buf = buf.split(b"\r\n\r\n", 1)
        if b" 101 " not in head.split(b"\r\n")[0]:
            raise RuntimeError(head.decode(errors="replace"))
        self.text = ""
        self.lock = threading.Lock()
        self.sock.settimeout(0.2)
        threading.Thread(target=self.reader, daemon=True).start()

    def reader(self):
        while True:
            try:
                data = self.sock.recv(65536)
                if not data:
                    return
                self.buf += data
            except socket.timeout:
                pass
            except OSError:
                return
            self.frames()

    def frames(self):
        buf = self.buf
        while len(buf) >= 2:
            n, i = buf[1] & 0x7f, 2
            if n == 126:
                if len(buf) < 4:
                    break
                n, i = struct.unpack(">H", buf[2:4])[0], 4
            elif n == 127:
                if len(buf) < 10:
                    break
                n, i = struct.unpack(">Q", buf[2:10])[0], 10
            if len(buf) < i + n:
                break
            if buf[0] & 0x0f in (0, 1, 2):
                with self.lock:
                    self.text += buf[i:i + n].decode(errors="replace")
            buf = buf[i + n:]
        self.buf = buf

    def send(self, text):
        payload = text.encode()
        mask = os.urandom(4)
        n = len(payload)
        if n < 126:
            head = bytes([0x81, 0x80 | n])
        elif n < 65536:
            head = bytes([0x81, 0x80 | 126]) + struct.pack(">H", n)
        else:
            head = bytes([0x81, 0x80 | 127]) + struct.pack(">Q", n)
        self.sock.sendall(head + mask + bytes(c ^ mask[i % 4] for i, c in enumerate(payload)))


class Norns:
    def __init__(self, log=None):
        self.socks = {k: Socket(p) for k, p in PORTS.items()}
        self.marks = 0
        self.log = log

    # ---- the REPLs ---------------------------------------------------------
    def _ask(self, kind, code, tail, timeout):
        s = self.socks[kind]
        self.marks += 1
        mark = f"@@{self.marks}@@"
        with s.lock:
            start = len(s.text)
        s.send(code + tail)
        s.send((f'print("{mark}")\n' if kind == "lua" else f'"{mark}".postln;\n\x1b'))
        end = time.time() + timeout
        while time.time() < end:
            with s.lock:
                part = s.text[start:]
            # sclang echoes nothing of the code, so the first mark is the print.
            if mark in part:
                out = part.split(mark)[0]
                return re.sub(r"(<ok>|sc3>|-> .*)\s*", "", out).strip() if kind == "lua" else out.strip()
            time.sleep(0.02)
        with s.lock:
            part = s.text[start:]
        raise TimeoutError(f"{kind} REPL gave no reply in {timeout}s: {code[:80]!r} partial={part[:200]!r}")

    def lua(self, code, timeout=6):
        return self._ask("lua", " ".join(code.split("\n")), "\n", timeout)

    def sc(self, code, timeout=6):
        return self._ask("sc", code, "\n\x1b", timeout)

    def transcript(self, kind):
        with self.socks[kind].lock:
            return self.socks[kind].text

    # ---- the script --------------------------------------------------------
    def load_script(self, wait=25):
        # look only at text after this load: an older "init() done" in the same
        # connection would hand back the previous instance's ctx
        start = len(self.transcript("lua"))
        out = self.lua('norns.script.load("code/four/four.lua")', timeout=5)
        end = time.time() + wait
        while time.time() < end:
            if "init() done" in self.transcript("lua")[start:]:
                break
            time.sleep(0.2)
        else:
            raise TimeoutError("the script did not reach init() done")
        time.sleep(1.5)
        self.helpers()
        return out

    def helpers(self):
        self.lua(CTX_HELPER)
        return self.lua("print(type(__ctx))") == "table"

    def get(self, pid):
        return num(self.lua(f'print(params:get("{pid}"))'))

    def string(self, pid):
        return self.lua(f'print(params:string("{pid}"))')

    def set(self, pid, value):
        self.lua(f'params:set("{pid}", {value})')

    def ctx(self, expr):
        """Print an expression in which `c` is the script's ctx."""
        return self.lua(f"local c = __ctx; print({expr})")

    def key(self, n, z):
        self.lua(f"key({n}, {z})")

    def tap(self, n, hold=0.05):
        self.key(n, 1)
        time.sleep(hold)
        self.key(n, 0)

    def enc(self, n, d):
        self.lua(f"enc({n}, {d})")

    def goto(self, name):
        """Go to the named page with E1, as a player does."""
        for _ in range(14):
            page = self.ctx("c.PAGES[c.page]")
            if page == name:
                return True
            self.enc(1, 1 if self.page_index(name) > self.page_index(page) else -1)
            time.sleep(0.03)
        return False

    def page_index(self, name):
        return int(self.lua(
            f'for i, p in ipairs(__ctx.PAGES) do if p == "{name}" then print(i) end end'))

    def screenshot(self, name):
        """Save the OLED as a PNG. Returns the path on the device."""
        self.lua(f'screen.export_screenshot("{name}")')
        time.sleep(0.4)
        return f"/home/we/dust/data/four/{name}.png"

    # ---- ssh and JACK ------------------------------------------------------
    def ssh(self, cmd, timeout=60, stdin=None):
        ctl = os.environ.get("NORNS_CTL")
        if not ctl:
            raise RuntimeError("set NORNS_CTL to the control socket of an open session")
        run = subprocess.run(
            ["ssh", "-S", os.path.basename(ctl), f"we@{HOST}", cmd],
            cwd=os.path.dirname(ctl) or ".", capture_output=True, text=stdin is None and True,
            timeout=timeout, input=stdin)
        return run.stdout if isinstance(run.stdout, str) else run.stdout.decode(errors="replace")

    def fetch(self, remote, local):
        ctl = os.environ["NORNS_CTL"]
        data = subprocess.run(
            ["ssh", "-S", os.path.basename(ctl), f"we@{HOST}", f"cat {remote}"],
            cwd=os.path.dirname(ctl) or ".", capture_output=True, timeout=120).stdout
        with open(local, "wb") as f:
            f.write(data)
        return len(data)

    def xruns(self):
        out = self.ssh("journalctl -u norns-jack -b --no-pager | grep -c XRun")
        return int(out.strip() or 0)

    def now(self):
        """The device's clock, for xruns_since. A count of the whole journal can
        fall when journald rotates, so a long test must count from a time."""
        return self.ssh("date '+%Y-%m-%d %H:%M:%S'").strip()

    def xruns_since(self, stamp):
        out = self.ssh(f'journalctl -u norns-jack --since "{stamp}" --no-pager | grep -c XRun')
        return int(out.strip() or 0)

    def record(self, seconds, local, ports=("crone:output_1", "crone:output_2")):
        """Record JACK ports to a 16-bit WAV on this computer."""
        remote = "/tmp/mg_rec.wav"
        self.ssh(f"rm -f {remote}; jack_rec -f {remote} -d {seconds} -b 16 {' '.join(ports)} >/dev/null 2>&1",
                 timeout=seconds + 30)
        return self.fetch(remote, local)

    def threads(self, seconds=5, count=12):
        """The busiest threads over `seconds`, with the core each one sits on."""
        out = self.ssh(
            f"top -H -b -n 2 -d {seconds} -o %CPU | awk '/^top/{{c++}} c==2' ",
            timeout=seconds + 15)
        rows = []
        idle = None
        for line in out.splitlines():
            if line.startswith("%Cpu"):
                match = re.search(r"([\d.]+) id", line)
                idle = float(match.group(1)) if match else None
            parts = line.split()
            if len(parts) >= 12 and parts[0].isdigit():
                rows.append((parts[11], float(parts[8]), parts[2]))
        return idle, rows[:count]

    # ---- the second scsynth, used here as a signal source ------------------
    def signal_boot(self):
        """Boot a private scsynth that feeds crone:input_1/2 as if it were the line input."""
        code = r'''
~sg = Server.named[\scsig] ?? { Server(\scsig, NetAddr("127.0.0.1", 57131)) };
~sg.options.numInputBusChannels = 0;
~sg.options.numOutputBusChannels = 2;
~sg.options.device = "default:scsig";
~sg.waitForBoot {
    SynthDef(\sig_drums, { arg amp = 0.5;
        var k = Decay2.ar(Impulse.ar(2), 0.001, 0.18) * SinOsc.ar(70);
        var h = Decay2.ar(Impulse.ar(4, 0.5), 0.0005, 0.04) * PinkNoise.ar;
        var s = (k + (h * 0.5)) * amp;
        Out.ar(0, [s, s]);
    }).send(~sg);
    SynthDef(\sig_tone, { arg amp = 0.25;
        var s = (SinOsc.ar(220) + SinOsc.ar(331, 0, 0.5) + SinOsc.ar(442, 0, 0.25)) * amp * 0.57;
        Out.ar(0, [s, s]);
    }).send(~sg);
    SynthDef(\sig_hit, { arg amp = 0.7;
        var s = Decay2.ar(Impulse.ar(0), 0.0005, 0.12) * WhiteNoise.ar * amp;
        Line.kr(0, 1, 0.6, doneAction: 2);
        Out.ar(0, [s, s]);
    }).send(~sg);
    ~sg.sync;
    "jack_connect scsig:out_1 crone:input_1".unixCmd;
    "jack_connect scsig:out_2 crone:input_2".unixCmd;
    1.wait;
    "SIG_READY".postln;
};
'''
        self.sc(code)
        end = time.time() + 15
        while time.time() < end:
            if "SIG_READY" in self.transcript("sc"):
                return True
            time.sleep(0.2)
        return False

    def signal(self, kind=None, amp=None):
        """Start a signal, or stop it with kind=None."""
        code = "~sigNode !? { ~sigNode.free; ~sigNode = nil };"
        if kind == "hit":
            code += f'Synth(\\sig_hit, [\\amp, {amp or 0.7}], ~sg.defaultGroup);'
        elif kind:
            code += f'~sigNode = Synth(\\sig_{kind}, [\\amp, {amp or (0.5 if kind == "drums" else 0.25)}], ~sg.defaultGroup);'
        self.sc(code)

    def signal_quit(self):
        self.sc("~sg !? { ~sg.quit };")

    # ---- engine state ------------------------------------------------------
    def cpu(self, samples=5):
        """Main scsynth average and peak CPU over `samples` seconds."""
        avg, peak = 0.0, 0.0
        for _ in range(samples):
            time.sleep(1)
            # the script's own posts can land in this reply, so find the pair
            reply = self.sc('("MGCPU " ++ Crone.server.avgCPU ++ " " ++ Crone.server.peakCPU).postln;')
            a, p = re.search(r"MGCPU ([\d.]+) ([\d.]+)", reply).groups()
            avg += float(a)
            peak = max(peak, float(p))
        return round(avg / samples, 1), round(peak, 1)

    def nodes(self):
        """Names of the synths running on the main server."""
        self.sc("Crone.server.queryAllNodes(false);")
        time.sleep(0.5)
        tail = self.transcript("sc")[-4000:]
        tree = tail[tail.rfind("NODE TREE"):] if "NODE TREE" in tail else ""
        return re.findall(r"\d+ (four_\w+)", tree)

    def take_dump(self, stem="/tmp/mg"):
        """Write the take's two buffers to float WAVs on the device, and wait for them.

        The server writes in the background, so a file is complete only when
        its size is the full 60s and has stopped growing.
        """
        self.ssh(f"rm -f {stem}_L.wav {stem}_R.wav")
        self.sc(
            f'Crone.engine.bufL.write("{stem}_L.wav", "wav", "float"); '
            f'Crone.engine.bufR.write("{stem}_R.wav", "wav", "float");',
            timeout=10)
        last = None
        for _ in range(120):
            time.sleep(0.5)
            sizes = self.ssh(f"stat -c %s {stem}_L.wav {stem}_R.wav 2>/dev/null | tr '\\n' ' '").strip()
            parts = sizes.split()
            if len(parts) == 2 and sizes == last and min(int(p) for p in parts) >= 11520000:
                return True
            last = sizes
        raise RuntimeError(f"the take dump did not finish: {last}")

    def take_hash(self):
        """A digest of the take's two buffers, read on the device."""
        self.take_dump()
        # hash the samples only: libsndfile puts a timestamp in a PEAK chunk, so
        # two dumps of the same audio have different file bytes
        code = (
            "import hashlib\n"
            "for p in ('/tmp/mg_L.wav','/tmp/mg_R.wav'):\n"
            "  d=open(p,'rb').read(); i=d.find(b'data')+8; print(hashlib.sha1(d[i:]).hexdigest()[:12], end=' ')\n"
        )
        return self.ssh(f"python3 -c \"{code}\"", timeout=30).strip()

    def take_diff(self, a="/tmp/mg_a", b="/tmp/mg_b"):
        """Where two dumps of the left buffer differ: count, first and last second, largest change."""
        code = (
            "import array,sys\n"
            f"def rd(p):\n  d=open(p,'rb').read(); i=d.find(b'data')+8; x=array.array('f'); x.frombytes(d[i:i+(len(d)-i)//4*4]); return x\n"
            f"a=rd('{a}_L.wav'); b=rd('{b}_L.wav'); idx=[i for i in range(min(len(a),len(b))) if a[i]!=b[i]]\n"
            "print(len(idx), round(idx[0]/48000,3) if idx else None, round(idx[-1]/48000,3) if idx else None, max((abs(a[i]-b[i]) for i in idx), default=0))\n"
        )
        return self.ssh(f"python3 -c \"{code}\"", timeout=60).strip()


def num(text):
    match = re.search(r"-?\d+\.?\d*(?:[eE][-+]?\d+)?", text or "")
    return float(match.group(0)) if match else None


if __name__ == "__main__":
    n = Norns()
    if sys.argv[1] == "status":
        print(n.lua('print("script", norns.state.name, "engine", engine.name, "params", params.count)'))
        print("scsynth avg/peak", n.cpu(3))
        print("xruns this boot", n.xruns())
    else:
        print({"lua": n.lua, "sc": n.sc}[sys.argv[1]](sys.argv[2]))
